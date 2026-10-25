#!/usr/bin/env bash
# fm-owner-rules-gate.sh <task-id> <worktree|-> <head|-> <pr-url|-> - the merge-gate half of owner-rules.
# config/merge-gate runs this first, with the gate args and FM_HOME set. It refuses (exit 1, one line naming
# the PR) a merge with no passed-proof receipt: no sealed clean done-done run at the merge head in the task's
# folder, or no checks-lint `pass` row (data/checks-gate.log) for the PR at the merge head. `screen: none` exempts
# the receipt only. PR merges also require their passed-proof Evidence card on the fleet board. A no-op when config/owner-rules is absent. Reuses merge-card's own checks.
set -u
[ "$#" -eq 4 ] || { echo "usage: fm-owner-rules-gate.sh <task-id> <worktree|-> <head|-> <pr-url|->" >&2; exit 2; }
[ -n "${FM_HOME:-}" ] && [ -e "$FM_HOME/config/owner-rules" ] || exit 0
mc=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../merge-card" && pwd -P)/merge-card
what=$4; [ "$4" != - ] || what="local merge $3"
none=0
"$mc" screen-none "$1" "$4" && none=1
if [ "$none" -eq 0 ] && ! { [ "$3" != - ] && "$mc" receipt "$1" "$3"; }; then
  echo "owner-rules: no passed-proof receipt for $what; run the done-done check and post the evidence to the sign-off Evidence tab first"
  exit 1
fi
# Lint: a `pass` row in the checks-gate log for this PR url at this head (read, never rerun). A local merge's rows
# name the report file and carry head `-`, so they match on the task's own folder instead.
awk -F'\t' -v pr="$4" -v head="$3" -v task="$1" '
  $4 != "pass" { next }
  pr != "-" { if ($2 == pr && $3 == head) f = 1; next }
  $3 == head || ($3 == "-" && $2 !~ /^https?:/ && $2 ~ ("/" task "/[^/]*$")) { f = 1 }
  END { exit !f }' "$FM_HOME/data/checks-gate.log" 2>/dev/null || {
  src=$4; [ "$4" != - ] || src="<report file>"
  lint=${FM_CHECKS_LINT:-${XDG_DATA_HOME:-$HOME/.local/share}/fm-merge-on-green/checks-lint.sh}
  [ -x "$lint" ] || lint=${FM_MAIN_HOME:-$HOME/firstmate}/config/fm-checks-lint.sh
  echo "owner-rules: no checks-lint PASS for $src at $3; run FM_HOME=$FM_HOME $lint $src <evidence folder> first"
  exit 1
}
# Local merges retain the existing receipt/lint behavior; only PRs have board keys.
[ "$4" != - ] || exit 0
# Canary config lists exact FM_HOME paths; without it every home keeps today's gate behavior.
canary=$FM_HOME/config/owner-rules-canary
if [ -r "$canary" ] && ! grep -Fqx -- "$FM_HOME" "$canary"; then exit 0; fi
# An explicitly dated UTC expiry permits a canary home to self-waive this new refusal until then.
waiver=$FM_HOME/config/owner-rules-canary-waiver
if [ -r "$waiver" ]; then
  IFS= read -r expires < "$waiver"
  if [[ $expires =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}Z$ ]] && [[ $(date -u +%Y-%m-%dT%H:%MZ) < $expires ]]; then exit 0; fi
fi
board=${FM_FLEET_BOARD:-}
if [ -z "$board" ] && [ -r "$FM_HOME/config/fleet-board" ]; then
  IFS= read -r board < "$FM_HOME/config/fleet-board"
fi
main_home=${FM_MAIN_HOME:-$HOME/firstmate}
if [ -z "$board" ] && [ -r "$main_home/config/fleet-board" ]; then
  IFS= read -r board < "$main_home/config/fleet-board"
fi
if [ -z "$board" ]; then
  echo "owner-rules: fleet board is not configured (set FM_FLEET_BOARD or $FM_HOME/config/fleet-board or $main_home/config/fleet-board) for $what"
  exit 1
fi
if [ ! -r "$board" ] || ! jq -e '.items | type == "array"' "$board" >/dev/null 2>&1; then
  echo "owner-rules: cannot read fleet board $board for $what"
  exit 1
fi
key=merge-$(printf '%s' "${4#*://}" | sed 's|^[^/]*/||' | tr -c 'A-Za-z0-9._-' -)
key=${key:0:128}
if jq -e --arg k "$key" --arg h "$3" 'any(.items[]?; (.key == $k or (.key | startswith($k + "-"))) and .kind == "evidence" and ((.run.commit? // .evidence.commit?) == $h) and ((.run.commit? == null) or .run.commit == $h) and ((.evidence.commit? == null) or .evidence.commit == $h))' "$board" >/dev/null; then
  exit 0
fi
if [ "$none" -eq 1 ] && "$mc" receipt "$1" "$3"; then
  timeout 15 "$mc" post --board "$board" "$1" "$2" "$3" "$4" || {
    rc=$?
    echo "owner-rules: could not post Evidence card for $what (merge-card exit $rc)"
    exit 1
  }
  jq -e --arg k "$key" --arg h "$3" 'any(.items[]?; (.key == $k or (.key | startswith($k + "-"))) and .kind == "evidence" and ((.run.commit? // .evidence.commit?) == $h) and ((.run.commit? == null) or .run.commit == $h) and ((.evidence.commit? == null) or .evidence.commit == $h))' "$board" >/dev/null && exit 0
fi
echo "owner-rules: no passed-proof Evidence card for $what; run FM_HOME=$FM_HOME $mc post --board $board $1 $2 $3 $4"
exit 1
