#!/usr/bin/env bash
# fm-relay-conn.sh - the ONE approved way to pair with, audit, and unpair a relay
# task host.
#
# Usage:
#   fm-relay-conn.sh deploy <host>        install the verb entry point + host config
#   fm-relay-conn.sh deploy-local <host>  same, run ON THE HOST ITSELF (no SSH)
#   fm-relay-conn.sh up <host>            pair the way this host's record allows
#   fm-relay-conn.sh ensure <host>        reuse a healthy link, else pair once
#   fm-relay-conn.sh audit <host>         grant assertion + reachability
#   fm-relay-conn.sh down <host>          revoke this caller's connection
#   fm-relay-conn.sh tighten-local <policy>  run ON A TARGET to bind every grant
#                                            to <policy> and drop full access
#
# `deploy-local` exists because a laptop task host has no inbound SSH, so the
# control machine cannot push anything to it. The machine's own operator runs
# this instead, reading the same host record and writing the same files, so there
# is one definition of what a deployed host looks like rather than two.
#
# Host records come from <home>/config/relay-hosts.json; docs/configuration.md
# owns that schema and docs/relay-host.md owns the measured behaviour below.
#
# Why `up` is transactional, and why the assertion is universal.
# `bifrost remote conn up` does not reuse or overwrite an existing grant: it ADDS
# a new one bound to the built-in `ssh-key-full-access` policy (arbitrary command
# execution, stdin and interactive on, whole-filesystem read/write) and leaves the
# previously tightened grant sitting in the list looking perfectly correct.
# Reproduced 2026-08-01 on 0.0.167 -> 0.0.165: after a second `up`, grant count
# went 1 -> 2 and a plain `id` executed again on the target. So:
#   - an audit that inspects "our" grant PASSES on a wide-open machine, and the
#     only sound question is whether ANY grant binds ssh-key-full-access;
#   - that question can only be answered on the TARGET, because `conn down --all`
#     on the caller revokes only the connection the caller saved;
#   - therefore the narrow `up` pairs, tightens on the target, re-reads, and
#     unpairs itself rather than leave a full-access grant behind on any failure
#     path.
# The window between pairing and tightening cannot be closed from outside
# Bifrost: `ssh-key create` still has no --roots/--ops/--shell-policy on 0.0.167.
#
# Tightening runs over the ordinary out-of-band SSH channel, never over the relay.
# That is deliberate: the verb table exposes no grant management at all, so a
# paired caller can never widen its own authorization through the channel it was
# granted. A host with no SSH route therefore cannot be tightened from here, and
# the narrow path refuses rather than reporting a pairing it could not secure.
#
# THE ONE EXCEPTION, AND WHAT IT IS NOT.
# A host record carrying `"trusted_full_access": true` is the captain declaring,
# per peer, that this home may KEEP the grant `conn up` creates. That declaration
# and nothing else selects the mode: not `fleet`, not `gui`, not the hostname,
# and not "this record has no ssh route" - inferring trust from an absent route
# would silently promote every laptop host, which is precisely backwards. A host
# without the field is narrow, and every refusal above still applies to it
# unchanged, including the universal ssh-key-full-access assertion.
# What the trusted mode buys is a no-inbound-SSH machine that this side can
# re-pair on its own, with no second operator standing at that machine's keyboard
# to run `tighten-local`. What it costs is stated where the field is documented:
# that peer holds a standing authorization equivalent to this user's shell on it.
#
# `ensure` is the idempotent form, and the reason it exists is that the grant
# session bifrost hands out expires in 24 hours (docs/relay-host.md). A link that
# has simply timed out looks identical to a machine that was never paired, and
# repairing it by hand is what the trusted mode is meant to remove. So: ask the
# channel first, pair ONLY when it does not answer, and never pair a second time
# just because a session started.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

usage() {
  sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
  printf '\nEvery mode above, and why each refusal is where it is, is in this file'"'"'s\nheader; docs/relay-host.md owns the measured behaviour behind them.\n'
}

# The deployed host config. ONE definition, written by both deploy paths, so a
# host pushed from the control machine and a host installed by its own operator
# cannot end up describing themselves differently.
# control-root/verbs/fmr-verb.sh owns what each key means.
host_config_text() {
  printf 'FM_ROOT=%s\n' "$FM_RELAY_HOST_ROOT"
  printf 'FM_HOME=%s\n' "$FM_RELAY_HOST_HOME"
  printf 'HOME_DIR=%s\n' "$FM_RELAY_HOST_DIR"
  printf 'PATH=%s\n' "$FM_RELAY_HOST_PATH"
  printf 'PROJECTS=%s\n' "$FM_RELAY_HOST_HOME/projects"
  printf 'FLEET_ROOT=%s\n' "$FM_RELAY_FLEET_ROOT"
  printf 'LANG=%s\n' "$FM_RELAY_HOST_LANG"
  if fm_relay_host_is_gui; then
    printf 'GUI=1\n'
    printf 'HOST_SESSION=%s\n' "$FM_RELAY_HOST_SESSION"
    [ -z "$FM_RELAY_TMUX_SOCKET" ] || printf 'TMUX_SOCKET=%s\n' "$FM_RELAY_TMUX_SOCKET"
  fi
}

# What a deployed control root contains. A GUI host additionally needs the
# preflight library and the desktop host-session manager; a non-GUI host gets
# neither, so a Phase 1 host is byte-identical to what it was before GUI hosts
# existed and needs no redeploy.
deploy_files() {
  printf 'verbs/fmr-verb.sh\n'
  if fm_relay_host_is_gui; then
    printf 'fmr-gui-lib.sh\n'
    printf 'fmr-host-session.sh\n'
  fi
}

# shellcheck source=bin/fm-relay-lib.sh
. "$SCRIPT_DIR/fm-relay-lib.sh"

POLICY_ID=fm-relay-verbs
PROFILE_ID=fm-relay-profile

CMD=${1:-}
case "$CMD" in
  -h|--help|'') usage; exit 0 ;;
esac
shift || true

# Run one command on the host's ordinary SSH route. Fails loudly when the host
# record declares none, naming what could not be done.
#
# The host record's `path` is prepended deliberately: a non-interactive SSH shell
# on a Linux box does not carry ~/.local/bin, so a bare `bifrost` is
# "command not found" there even though the same binary runs fine for the logged-in
# operator. That is the same PATH trap the deployed verb solves from its own
# config, and it has to be solved here too because this path never goes through
# the verb.
host_ssh() {  # <what> <command-string>
  local what=$1 cmd=$2
  if [ -z "$FM_RELAY_SSH" ]; then
    echo "error: relay host '$FM_RELAY_HOST' has no ssh route, so this caller cannot $what" >&2
    echo "Run this ON $FM_RELAY_HOST instead: bin/fm-relay-conn.sh tighten-local $POLICY_ID" >&2
    return 1
  fi
  ssh -o BatchMode=yes -o ConnectTimeout=15 "$FM_RELAY_SSH" \
    "PATH=$FM_RELAY_HOST_PATH:\$PATH; $cmd"
}

# Feed a script to the host's shell on stdin instead of quoting it into an
# argument. Anything longer than one command becomes unreadable, and therefore
# unreviewable, when it has to survive two levels of shell quoting.
host_script() {  # <what> [arg...] < script
  local what=$1; shift
  if [ -z "$FM_RELAY_SSH" ]; then
    echo "error: relay host '$FM_RELAY_HOST' has no ssh route, so this caller cannot $what" >&2
    echo "Run this ON $FM_RELAY_HOST instead: bin/fm-relay-conn.sh tighten-local $POLICY_ID" >&2
    return 1
  fi
  ssh -o BatchMode=yes -o ConnectTimeout=30 "$FM_RELAY_SSH" \
    "PATH=$FM_RELAY_HOST_PATH:\$PATH; bash -s -- $*"
}

unpair_and_fail() {  # <reason>
  echo "REFUSED: $1" >&2
  echo "Unpairing rather than leaving an untightened authorization on $FM_RELAY_HOST." >&2
  "$(fm_relay_bifrost)" remote conn down --all >/dev/null 2>&1 || true
  exit 1
}

host_bifrost() {
  printf '%s' "${FM_RELAY_HOST_BIFROST:-bifrost}"
}

# --- pairing ------------------------------------------------------------------
#
# Two modes, one entry point. `up` and `ensure` both go through pair_for_record
# so there is exactly one place that decides how a given host may be paired, and
# a host record cannot mean one thing to a hand-run command and another to the
# startup sweep.

require_key() {  # <what-for>
  [ -n "$FM_RELAY_KEY" ] || {
    echo "error: relay host '$FM_RELAY_HOST' declares no key file to $1 with" >&2
    return 1
  }
  [ -f "$FM_RELAY_KEY" ] || {
    echo "error: the key file $FM_RELAY_KEY for relay host '$FM_RELAY_HOST' is missing" >&2
    echo "Export a fresh device key on $FM_RELAY_HOST and copy it there out of band," >&2
    echo "never over the relay being established; then re-run this command." >&2
    return 1
  }
}

# The key check lives HERE, in the one place the key is actually used, so no
# pairing path can be added later that forgets it.
conn_up() {
  require_key "pair"
  "$(fm_relay_bifrost)" remote conn up --ssh-key "$FM_RELAY_KEY" \
    --label "fm-$FM_RELAY_HOST-caller"
}

# The narrow path, unchanged: pair, tighten on the target FIRST, then re-read and
# assert. Any failure below unpairs rather than leaving a full-access grant alive.
pair_narrow() {
  local tighten_out grants
  # Refuse to pair at all when this caller has no way to secure the result.
  [ -n "$FM_RELAY_SSH" ] || host_ssh "pair with it" true
  conn_up
  tighten_out=$(host_script "tighten the grant it just created" "$POLICY_ID" \
    < "$FM_ROOT/control-root/tighten-grants.sh") \
    || unpair_and_fail "could not tighten the authorization on $FM_RELAY_HOST"
  printf '%s\n' "$tighten_out" | sed -n '/^tighten /p'
  grants=$(host_script "read back the target's grants" list \
    < "$FM_ROOT/control-root/tighten-grants.sh") \
    || unpair_and_fail "could not read back the authorizations on $FM_RELAY_HOST"
  if ! fm_relay_audit_grants_text "$grants"; then
    printf '%s\n' "$grants" >&2
    unpair_and_fail "$FM_RELAY_HOST still has an authorization bound to ssh-key-full-access after tightening"
  fi
  printf '%s\n' "$grants"
  echo "paired: $FM_RELAY_HOST (no grant binds ssh-key-full-access)"
}

# The captain-trusted path. No tighten step, because keeping that grant is the
# whole declaration - so the assertion that the narrow path gets for free from
# reading the target's grants back has to be replaced by something. It is
# replaced by the only question this side can answer without SSH and the only one
# that matters operationally: does the verb channel now answer. A pairing that
# does not is unpaired rather than reported as a success, which keeps the
# transactional discipline the narrow path established.
pair_trusted() {
  conn_up
  if ! fm_relay_exec ping >/dev/null 2>&1; then
    unpair_and_fail "paired with $FM_RELAY_HOST but its verb channel still does not answer: ${FM_RELAY_ERR%%$'\n'*}"
  fi
  printf '%s\n' "$FM_RELAY_OUT"
  printf 'paired: %s - full-access authorization RETAINED, because this home'"'"'s record for\n' "$FM_RELAY_HOST"
  printf 'it carries trusted_full_access. That peer now holds a standing authorization\n'
  printf 'equivalent to this user'"'"'s shell on it until the grant session expires.\n'
}

pair_for_record() {
  if fm_relay_host_trusts_full_access; then
    pair_trusted
  else
    pair_narrow
  fi
}

# A GUI host's desktop session is the one thing this side cannot restore for it:
# it must be started from that machine's own desktop, and control-root/fmr-gui-lib.sh
# owns why a launchd job is not an alternative. So report it precisely instead of
# leaving it to be discovered by a dispatch that gets held. The verb's own refusal
# text already names the exact command, so this relays it rather than composing a
# second copy that could drift from what the host actually wants.
gui_setup_note() {
  fm_relay_host_is_gui || return 0
  fm_relay_exec preflight >/dev/null 2>&1 && return 0
  printf 'SETUP NEEDED ON %s: %s\n' "$FM_RELAY_HOST" \
    "$(printf '%s' "${FM_RELAY_ERR%%$'\n'*}" | sed 's/^ERR [a-z]* //')"
}

case "$CMD" in

  deploy)
    HOST=${1:?usage: fm-relay-conn.sh deploy <host>}
    fm_relay_host_load "$FM_HOME" "$HOST"
    for rel in $(deploy_files); do
      [ -f "$FM_ROOT/control-root/$rel" ] \
        || { echo "error: missing $FM_ROOT/control-root/$rel" >&2; exit 1; }
    done
    TMP_CFG=$(mktemp)
    trap 'rm -f "$TMP_CFG"' EXIT
    host_config_text > "$TMP_CFG"
    host_ssh "deploy the verb entry point" \
      "mkdir -p '$FM_RELAY_CONTROL_ROOT/verbs' '$FM_RELAY_CONTROL_ROOT/tasks' '$FM_RELAY_FLEET_ROOT/tasks'"
    for rel in $(deploy_files); do
      scp -o BatchMode=yes -q "$FM_ROOT/control-root/$rel" "$FM_RELAY_SSH:$FM_RELAY_CONTROL_ROOT/$rel"
    done
    scp -o BatchMode=yes -q "$TMP_CFG" "$FM_RELAY_SSH:$FM_RELAY_CONTROL_ROOT/config"
    host_ssh "set verb permissions" \
      "chmod 755 '$FM_RELAY_CONTROL_ROOT/verbs/fmr-verb.sh'; chmod 600 '$FM_RELAY_CONTROL_ROOT/config'"
    if fm_relay_host_is_gui; then
      host_ssh "set host-session manager permissions" \
        "chmod 755 '$FM_RELAY_CONTROL_ROOT/fmr-host-session.sh'; chmod 644 '$FM_RELAY_CONTROL_ROOT/fmr-gui-lib.sh'"
    fi
    echo "deployed: $FM_RELAY_HOST verbs + config"
    ;;

  deploy-local)
    # Run ON the task host. Same host record, same files, same config text as the
    # SSH path above - this only replaces the transport, because a laptop host
    # has no inbound SSH for the control machine to push over.
    HOST=${1:?usage: fm-relay-conn.sh deploy-local <host>}
    fm_relay_host_load "$FM_HOME" "$HOST"
    for rel in $(deploy_files); do
      [ -f "$FM_ROOT/control-root/$rel" ] \
        || { echo "error: missing $FM_ROOT/control-root/$rel" >&2; exit 1; }
    done
    mkdir -p "$FM_RELAY_CONTROL_ROOT/verbs" "$FM_RELAY_CONTROL_ROOT/tasks" \
      "$FM_RELAY_FLEET_ROOT/tasks"
    for rel in $(deploy_files); do
      cp "$FM_ROOT/control-root/$rel" "$FM_RELAY_CONTROL_ROOT/$rel"
    done
    host_config_text > "$FM_RELAY_CONTROL_ROOT/config"
    chmod 755 "$FM_RELAY_CONTROL_ROOT/verbs/fmr-verb.sh"
    chmod 600 "$FM_RELAY_CONTROL_ROOT/config"
    if fm_relay_host_is_gui; then
      chmod 755 "$FM_RELAY_CONTROL_ROOT/fmr-host-session.sh"
      chmod 644 "$FM_RELAY_CONTROL_ROOT/fmr-gui-lib.sh"
      printf 'deployed locally: %s. Start its desktop host session from a terminal window on this machine:\n' "$FM_RELAY_HOST"
      printf '  %s/fmr-host-session.sh start\n' "$FM_RELAY_CONTROL_ROOT"
    else
      echo "deployed locally: $FM_RELAY_HOST verbs + config"
    fi
    ;;

  up)
    HOST=${1:?usage: fm-relay-conn.sh up <host>}
    fm_relay_host_load "$FM_HOME" "$HOST"
    pair_for_record
    gui_setup_note
    ;;

  ensure)
    # Idempotent reconnect. The healthy case must cost one ping and must create
    # nothing: a session start that re-paired every time would add a fresh grant
    # to the peer on every restart (measured: `conn up` ADDS, it does not reuse),
    # which is the accumulation this command exists to avoid rather than cause.
    HOST=${1:?usage: fm-relay-conn.sh ensure <host>}
    fm_relay_host_load "$FM_HOME" "$HOST"
    if fm_relay_exec ping >/dev/null 2>&1; then
      printf 'connected: %s %s\n' "$HOST" "${FM_RELAY_OUT%%$'\n'*}"
      gui_setup_note
      exit 0
    fi
    # The channel is down. Whether this side can bring it back on its own is a
    # property of the host record, and saying which one is missing is the whole
    # value of this branch: "cannot reconnect" without the reason sends someone
    # to the wrong machine.
    if fm_relay_host_trusts_full_access; then
      pair_trusted
      gui_setup_note
      printf 'reconnected: %s re-paired on its own key; full-access authorization retained by explicit trust\n' "$HOST"
      exit 0
    fi
    if [ -n "$FM_RELAY_SSH" ]; then
      pair_narrow
      gui_setup_note
      printf 'reconnected: %s re-paired and tightened over its ssh route\n' "$HOST"
      exit 0
    fi
    # Narrow, and no SSH route: the two-operator ceremony is the only way, and
    # it needs someone at that machine. Report that rather than half-pairing.
    cat >&2 <<EOF
error: relay host '$HOST' is not answering and this machine cannot restore it alone.
It has no ssh route, so nothing here can tighten the authorization a pairing would
create, and its record does not carry trusted_full_access, so nothing here may keep
one either. Two steps, in this order:
  here:      bifrost remote conn up --ssh-key ${FM_RELAY_KEY:-<that host key file>}
  on $HOST:  $FM_ROOT/bin/fm-relay-conn.sh tighten-local $POLICY_ID
Or, if the captain has decided this pairing may keep its full-access grant, add
"trusted_full_access": true to that host's record and re-run this command.
EOF
    exit 1
    ;;

  down)
    HOST=${1:?usage: fm-relay-conn.sh down <host>}
    fm_relay_host_load "$FM_HOME" "$HOST"
    "$(fm_relay_bifrost)" remote conn down --all
    echo "unpaired: $HOST (caller side). Revoke the key on the target itself to clear its grants."
    ;;

  audit)
    HOST=${1:?usage: fm-relay-conn.sh audit <host>}
    fm_relay_host_load "$FM_HOME" "$HOST"
    rc=0
    if "$(fm_relay_bifrost)" sync status 2>/dev/null | grep -q '^Authorized: true'; then
      echo "RELAY_SYNC: caller authorized"
    else
      echo "RELAY_SYNC: caller is NOT authorized to the relay; cross-machine dispatch is unavailable"
      rc=1
    fi
    if fm_relay_exec ping >/dev/null 2>&1; then
      echo "RELAY_PING: $HOST $FM_RELAY_OUT"
      NOTE=$(gui_setup_note)
      [ -z "$NOTE" ] || { printf '%s\n' "$NOTE"; rc=1; }
    else
      echo "RELAY_PING: $HOST unreachable through the verb channel: ${FM_RELAY_ERR%%$'\n'*}"
      rc=1
    fi
    if fm_relay_host_trusts_full_access; then
      # Not a weaker audit: the same universal question, answered by the record
      # instead of asked of the machine. Reporting the configured state as a
      # fault would train the reader to ignore the line that matters.
      echo "RELAY_GRANT: $HOST keeps its full-access authorization by explicit captain trust (trusted_full_access in this home's record for it)"
      exit "$rc"
    fi
    if GRANTS=$(host_ssh "audit the target's grants" "$(host_bifrost) setting grant list" 2>/dev/null); then
      if fm_relay_audit_grants_text "$GRANTS"; then
        echo "RELAY_GRANT: $HOST clean (no grant binds ssh-key-full-access)"
      else
        echo "RELAY_GRANT: $HOST has a FULL-ACCESS grant; re-run bin/fm-relay-conn.sh up $HOST"
        rc=1
      fi
    else
      echo "RELAY_GRANT: $HOST grants could not be read from here; audit them on that machine"
      rc=1
    fi
    exit "$rc"
    ;;

  tighten-local)
    # Run this ON a target machine that no caller can reach by SSH. Same script
    # the paired caller pipes over, so there is one owner of the procedure.
    POLICY=${1:-$POLICY_ID}
    B=$(fm_relay_bifrost)
    "$B" setting shell list | grep -q "$PROFILE_ID" \
      || { echo "error: shell profile $PROFILE_ID is not installed on this machine" >&2; exit 1; }
    BIFROST_BIN="$B" bash "$FM_ROOT/control-root/tighten-grants.sh" "$POLICY" || true
    GRANTS=$("$B" setting grant list)
    printf '%s\n' "$GRANTS"
    if fm_relay_audit_grants_text "$GRANTS"; then
      echo "clean: no grant binds ssh-key-full-access"
    else
      echo "REFUSED: a grant still binds ssh-key-full-access" >&2
      exit 1
    fi
    ;;

  *)
    usage
    exit 2
    ;;
esac
