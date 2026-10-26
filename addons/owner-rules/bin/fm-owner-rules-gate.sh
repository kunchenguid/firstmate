#!/usr/bin/env bash
# fm-owner-rules-gate.sh <task-id> <worktree|-> <head|-> <pr-url|-> - the merge-gate half of owner-rules.
# config/merge-gate runs this first, with the gate args and FM_HOME set. It refuses (exit 1, one line naming
# the PR) a merge with no passed-proof receipt: no sealed clean done-done run at the merge head in the task's
# folder, or no checks-lint `pass` row (data/checks-gate.log) for the PR at the merge head. A merge whose
# Checks block declares `screen: none` opens with one line saying it takes the text-only Evidence card path, so
# no capture is demanded of it, and it still needs that sealed receipt for the card. PR merges also require their
# passed-proof Evidence card on the fleet board. Every refusal names the command that clears it. A no-op when
# config/owner-rules is absent. Reuses merge-card's own checks.
set -u
[ "$#" -eq 4 ] || { echo "usage: fm-owner-rules-gate.sh <task-id> <worktree|-> <head|-> <pr-url|->" >&2; exit 2; }
[ -n "${FM_HOME:-}" ] && [ -e "$FM_HOME/config/owner-rules" ] || exit 0
mc=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../merge-card" && pwd -P)/merge-card
what=$4; [ "$4" != - ] || what="local merge $3"
none=0
"$mc" screen-none "$1" "$4" && none=1
# The top line: a screen-free merge is on the text-only card path, and no capture is asked for.
[ "$none" -eq 0 ] || echo "owner-rules: $what declares screen: none, so it takes the text-only Evidence card path; no capture is needed"
# canary_enforced: 0 when this home is in the canary rollout (or no canary file exists) and no active UTC waiver
# covers it. The screen-free receipt refusal honors it; the other refusals are not canary-gated.
canary_enforced() {
  local canary=$FM_HOME/config/owner-rules-canary waiver=$FM_HOME/config/owner-rules-canary-waiver expires
  [ ! -r "$canary" ] || grep -Fqx -- "$FM_HOME" "$canary" || return 1
  if [ -r "$waiver" ]; then
    IFS= read -r expires < "$waiver"
    if [[ $expires =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}Z$ ]] && [[ $(date -u +%Y-%m-%dT%H:%MZ) < $expires ]]; then return 1; fi
  fi
  return 0
}
# The receipt is a sealed clean done-done run at the merge head; a screen-free merge needs it for its text card too.
if [ "$3" != - ] && ! "$mc" receipt "$1" "$3"; then
  # A screen-free merge keeps today's skip on a home the canary has not reached yet.
  if [ "$none" -eq 0 ] || canary_enforced; then
    if [ "$2" = - ]; then
      hint="done-done run -- <the command that proves it> in the copy at $3"
    else
      hint="cd '$2' && done-done run -- <the command that proves it>"
    fi
    echo "owner-rules: no passed-proof receipt for $what: seal a clean done-done run at $3 with: $hint"
    exit 1
  fi
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
  echo "owner-rules: no checks-lint PASS for $src at $3; run FM_HOME=$FM_HOME $lint $src $FM_HOME/data/$1 then merge again"
  exit 1
}
# Local merges retain the existing receipt/lint behavior; only PRs have board keys.
[ "$4" != - ] || exit 0
# Canary config lists exact FM_HOME paths; without it every home keeps today's gate behavior.
canary_enforced || exit 0
board=${FM_FLEET_BOARD:-}
if [ -z "$board" ] && [ -r "$FM_HOME/config/fleet-board" ]; then
  IFS= read -r board < "$FM_HOME/config/fleet-board"
fi
main_home=${FM_MAIN_HOME:-$HOME/firstmate}
if [ -z "$board" ] && [ -r "$main_home/config/fleet-board" ]; then
  IFS= read -r board < "$main_home/config/fleet-board"
fi
if [ -z "$board" ]; then
  echo "owner-rules: fleet board is not configured for $what (set FM_FLEET_BOARD, or write its path with: echo <board.json> > $FM_HOME/config/fleet-board; the main home's $main_home/config/fleet-board is the fallback)"
  exit 1
fi
if [ ! -r "$board" ] || ! jq -e '.items | type == "array"' "$board" >/dev/null 2>&1; then
  echo "owner-rules: cannot read fleet board $board for $what: set FM_FLEET_BOARD or $FM_HOME/config/fleet-board to a board.json holding {\"items\": [...]}"
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
    echo "owner-rules: could not post the text-only Evidence card for $what (merge-card exit $rc); its own line above names the step it needs"
    exit 1
  }
  jq -e --arg k "$key" --arg h "$3" 'any(.items[]?; (.key == $k or (.key | startswith($k + "-"))) and .kind == "evidence" and ((.run.commit? // .evidence.commit?) == $h) and ((.run.commit? == null) or .run.commit == $h) and ((.evidence.commit? == null) or .evidence.commit == $h))' "$board" >/dev/null && exit 0
fi
echo "owner-rules: no passed-proof Evidence card for $what; post it with: FM_HOME=$FM_HOME $mc post --board $board $1 $2 $3 $4"
exit 1
