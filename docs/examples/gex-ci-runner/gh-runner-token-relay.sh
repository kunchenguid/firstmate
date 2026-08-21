#!/usr/bin/env bash
# Mint short-lived GitHub Actions registration tokens and relay them to gex44.
#
# WHY THIS EXISTS: gex holds no durable GitHub credential - no PAT, no App key.
# It only ever holds a registration token that dies within the hour, so a
# compromise of gex yields a secret that expires on its own and can register
# runners on allowlisted private repos only.
#
# WHY THIS DIRECTION: gex cannot reach this laptop (behind NAT, no sshd, no
# mesh), so the laptop pushes. A registration token is reusable for its full
# hour (measured 21.08.2026: two runners registered from one token), so a
# push every 30 minutes keeps gex continuously able to register.
#
# WHAT HAPPENS WHEN THE LAPTOP SLEEPS: already-registered runners keep serving
# (an idle runner needs no token), and the cached token stays usable for up to
# an hour. After that, registrations stop and jobs queue on GitHub until the
# laptop returns; nothing fails. No workflow in this fleet self-triggers, and
# every push originates from this laptop, so the realistic exposure is a push
# from another machine while this one is asleep.
#
# Uses /usr/bin/gh, not gh-axi: the wrapper lives on a session-scoped fnm path
# that does not exist for a systemd timer.
set -euo pipefail

GH=${GH_BIN:-/usr/bin/gh}
SSH_TARGET=${GEX_SSH_TARGET:-gex}
OWNER=${GH_OWNER:-swippipp}
CONF_DIR=${GH_RUNNER_CONF_DIR:-/etc/gh-runner}

log() { printf '%s relay: %s\n' "$(date -Is)" "$*" >&2; }

if ! repos=$(ssh -o BatchMode=yes -o ConnectTimeout=15 "$SSH_TARGET" "cat $CONF_DIR/repos" 2>/dev/null); then
  log "cannot read the allowlist on $SSH_TARGET; will retry next tick"
  exit 0
fi

rc=0
while read -r repo; do
  [ -n "$repo" ] || continue
  case "$repo" in \#*) continue ;; esac

  # A self-hosted runner on a public repo would execute pull-request code from
  # strangers. This is the mint-time half of that guard; supervise.sh on gex
  # holds the other half.
  visibility=$("$GH" api "repos/$OWNER/$repo" --jq '.private' 2>/dev/null || echo unknown)
  if [ "$visibility" != "true" ]; then
    log "REFUSING $repo: not confirmed private (got '$visibility')"
    rc=1
    continue
  fi

  if ! payload=$("$GH" api -X POST "repos/$OWNER/$repo/actions/runners/registration-token" \
        --jq '"\(.token)\n\(.expires_at)"' 2>/dev/null); then
    log "could not mint a token for $repo"
    rc=1
    continue
  fi

  # Atomic install with least privilege: root owns it, ghrunner may read it.
  if ! printf '%s\n' "$payload" | ssh -o BatchMode=yes -o ConnectTimeout=15 "$SSH_TARGET" \
        "umask 027 && cat > $CONF_DIR/token-$repo.new \
         && chown root:ghrunner $CONF_DIR/token-$repo.new \
         && chmod 0640 $CONF_DIR/token-$repo.new \
         && mv $CONF_DIR/token-$repo.new $CONF_DIR/token-$repo"; then
    log "could not deliver the token for $repo"
    rc=1
    continue
  fi
done <<< "$repos"

exit "$rc"
