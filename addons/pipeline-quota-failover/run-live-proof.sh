#!/usr/bin/env bash
# run-live-proof.sh: the pipeline's review, test and fix calls recover from a Claude account limit on the one allowed
# route. Each call goes through this checkout's wrapper with no-mistakes' argv shape, on the default chain (Claude Haiku
# through claude-bridge) and a throwaway config/account-pool: the real claude-accounts-pick and accounts, with rests in
# a throwaway pool state folder. The first account a call lands on is limited by a pi shim (claude-bridge's own limit
# text); the next account's answer is real Haiku through the real pi and bridge. No paid route exists
# in the chain. Captures name account ids only, never a folder or a credential.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd -P)
evidence=${DONE_DONE_EVIDENCE_ROOT:?}
real_pi=${PI_QUOTA_FAILOVER_REAL_PI:-$(command -v pi)}
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$evidence" "$work/home/state" "$work/pool" "$work/cwd"
pick="$repo/claude-accounts/bin/claude-accounts-pick"
printf 'command=%s\nstate=%s\n' "$pick" "$work/pool" >"$work/account-pool"
# The controlled limit, as a real one looks to the pool: the first account a role's call lands on answers
# claude-bridge's own limit text, and the pool's reading then shows that account spent until a future reset, as the
# quota reader shows after a real limit. Every other call is real pi.
cat >"$work/pi" <<'SHIM'
#!/usr/bin/env bash
[ "${1:-}" = list ] || [ -s "$LIMITED" ] || printf '%s' "${CLAUDE_CONFIG_DIR:-}" >"$LIMITED"
if [ "${1:-}" != list ] && [ "${CLAUDE_CONFIG_DIR:-}" = "$(cat "$LIMITED")" ]; then
  cat >/dev/null
  jq --arg f "$CLAUDE_CONFIG_DIR" --argjson now "$(date +%s)" --arg at "$(date -u -d '+3 hours' +%FT%TZ)" \
    '.generated_at = $now | .accounts |= map(if .folder == $f then .five_hour = {left: 0, resets_at: $at} else . end)' \
    "$READING" >"$READING.new" && mv "$READING.new" "$READING"
  printf '%s\n' '{"type":"message_end","stopReason":"error","errorMessage":"Claude rate limit (five_hour) resets in 3h: You are out of usage"}'
  exit 0
fi
exec "$REAL_PI" "$@"
SHIM
chmod +x "$work/pi"
# The pool reads only its own state folder (no FM_HOME): a real reading taken once, refreshed for each role.
FM_HOME=$work/home "$repo/claude-accounts/bin/claude-accounts-quota.sh" >/dev/null
unset FM_HOME
export REAL_PI=$real_pi LIMITED=$work/limited READING=$work/pool/claude-accounts.json PI_QUOTA_FAILOVER_REAL_PI=$work/pi \
  PI_QUOTA_FAILOVER_ACCOUNT_POOL=$work/account-pool PI_QUOTA_FAILOVER_LOG=$evidence/wrapper.log PI_QUOTA_FAILOVER_PROBE=0 \
  PI_QUOTA_FAILOVER_GATE=
: >"$evidence/wrapper.log"
fails=0 n=0
for role in review test fix; do
  rm -rf "$work/pool/claude-accounts-rested" # each role starts with every account back, so each shows the move
  : >"$work/limited"
  jq --argjson now "$(date +%s)" '.generated_at = $now | .accounts[].read_at = $now' "$work/home/state/claude-accounts.json" >"$READING"
  case $role in
    review) prompt='You are the review step of a code pipeline. Review this one-line change: "- x = 1\n+ x = 2". Reply with exactly one line that starts with REVIEW-OK.' ;;
    test) prompt='You are the test step of a code pipeline. The tests printed "3 passed". Reply with exactly one line that starts with TEST-OK.' ;;
    fix) prompt='You are the fix step of a code pipeline. The review asked to rename x to count. Reply with exactly one line that starts with FIX-OK.' ;;
  esac
  marker=$(tr '[:lower:]' '[:upper:]' <<<"$role")-OK
  set +e
  out=$(cd "$work/cwd" && printf '%s' "$prompt" | "$repo/pipeline-quota-failover/pi-quota-failover" \
    --model claude-bridge/claude-haiku-5-5 --mode json --no-session 2>>"$evidence/$role.stderr.txt")
  rc=$?
  set -e
  answer=$(grep -o "${marker}[^\"\\\\]*" <<<"$out" | head -n 1) || true
  move=$(grep -oE 'quota-error on account [^ ]* .*next id=[^ ]*' "$evidence/wrapper.log" | tail -n 1 | sed 's/ in [0-9]*ms (.*);/;/')
  printf '%s: exit %s; %s; answer: %s\n' "$role" "$rc" "${move:-no account move}" "${answer:-none}" | tee -a "$evidence/roles.txt"
  n=$((n + 1))
  [ "$rc" = 0 ] && [ -n "$answer" ] && [ "$(grep -cE 'quota-error on account .*next id=' "$evidence/wrapper.log")" = "$n" ] ||
    fails=$((fails + 1))
done
sed -i "s|$HOME|~|g" "$evidence"/*.txt "$evidence/wrapper.log"
jq -n --arg v "$(git -C "$repo" rev-parse --short HEAD)" --rawfile roles "$evidence/roles.txt" '{target: {version: $v},
  start: "the pipeline wrapper on its default route, Claude Haiku through claude-bridge, with the real Claude account pool",
  steps: ["send a review prompt, a test prompt and a fix prompt the way the pipeline calls pi",
    "each call first lands on an account that answers a Claude rate limit"],
  result: ("each role moved to the next account on the same route and answered on Claude Haiku: " + $roles)}' >"$evidence/steps.json"
[ "$fails" = 0 ] || { echo "FAIL: $fails role(s) did not recover" | tee -a "$evidence/roles.txt"; exit 1; }
echo "PASS: review, test and fix each moved off a limited account and answered on Claude Haiku" | tee -a "$evidence/roles.txt"
