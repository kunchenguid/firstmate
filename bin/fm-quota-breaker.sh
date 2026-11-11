#!/usr/bin/env bash
# fm-quota-breaker.sh - quota circuit breaker: notice a live worker stalled on a
# hard provider quota or rate-limit refusal and wake its firstmate to relaunch
# it on the next candidate of the same dispatch group.
#
# Usage: fm-quota-breaker.sh scan
#        fm-quota-breaker.sh classify     (reads a captured pane on stdin)
#
# WHY. A worker whose provider refuses with a hard quota error does not fail:
# its harness retries, gives up, and sits idle with the error on screen, and
# nothing reports it until someone looks. A run of those cost hours of lanes.
# The relaunch decision itself stays with firstmate, because choosing the next
# candidate is the quota-array-dispatch procedure (its "Quota circuit breaker"
# section); this script only turns the stall into a typed notification.
#
# THE GATE (config/quota-breaker). Absent means off. A present file enables the
# breaker; its optional lines are
#   rate-limit-repeats=<n>  rate-limit refusals in one pane tail that trip the
#                           breaker (5)
#   realert-seconds=<n>     minimum time before the same refusal on the same
#                           worker incarnation is reported again (3600)
# Blank lines and lines starting with # are ignored; an unusable value keeps
# its default. docs/configuration.md "Quota circuit breaker" owns the
# operator-facing description.
#
# `scan` (run by bin/fm-watch.sh on its check sweep when the gate exists) reads
# the last 60 rows of every local ship and scout endpoint in this home and
# classifies them. Each tripped worker prints one line:
#   quota-breaker <task-id> <class> harness=<h> model=<m>: <matched row>
# which the watcher queues as one `check: quota-breaker` notification each.
# state/<task-id>.quota-breaker remembers the last report (class, spawn
# generation, time), so one stall is reported once per realert window and a
# relaunched incarnation that hits the same wall is reported afresh.
#
# `classify` prints `<class><TAB><matched row>` for a pane tail on stdin, or
# nothing. Classes and their verbatim provider signatures (the pane renders the
# provider's own error text, so these match what Pi, Claude Code, Codex, and
# Antigravity print):
#   zai-1308            Z.AI 5-hour cap: `"code":"1308"` / `Usage limit reached
#                       for 5 hour`
#   zai-1310            Z.AI weekly/monthly cap: `"code":"1310"` /
#                       `Weekly/Monthly Limit Exhausted`
#   antigravity-429     Antigravity quota: `Quota reached. Please wait ...` /
#                       `Quota reached. Next: switch models`, or a Gemini
#                       `RESOURCE_EXHAUSTED` 429
#   codex-usage-limit   `The usage limit has been reached` (Pi's Codex provider)
#                       / `You've hit your usage limit` (Codex CLI)
#   claude-usage-limit  `Claude usage limit reached` / `5-hour limit reached` /
#                       `You've hit your limit`
#   zai-1302            Z.AI request rate limit `"code":"1302"` / `Rate limit
#                       reached for requests`, only when it repeats at least
#                       rate-limit-repeats times in the tail: one is a retry the
#                       harness absorbs, a run is a wedge
# A hard class counts only within the bottom 15 non-blank rows, so a refusal
# the worker already recovered from and scrolled past does not trip it.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

RATE_REPEATS=5
REALERT=3600

# breaker_hard_match <rows> <class> <ere>: print "<class>\t<row>" for the last
# row matching <ere>, or fail.
breaker_hard_match() {
  local row
  row=$(printf '%s\n' "$1" | grep -E -- "$3" | tail -n 1) || return 1
  [ -n "$row" ] || return 1
  printf '%s\t%s\n' "$2" "$(printf '%s' "$row" | sed 's/^[[:space:]]*//' | cut -c1-200)"
}

# fm_quota_breaker_classify [repeats]: stdin pane tail -> "<class>\t<row>".
fm_quota_breaker_classify() {
  local repeats=${1:-5} tail bottom row count
  tail=$(cat)
  bottom=$(printf '%s\n' "$tail" | grep -v '^[[:space:]]*$' | tail -n 15)
  breaker_hard_match "$bottom" zai-1308 '\\?"code\\?"[[:space:]]*:[[:space:]]*\\?"1308\\?"|Usage limit reached for 5 hour' && return 0
  breaker_hard_match "$bottom" zai-1310 '\\?"code\\?"[[:space:]]*:[[:space:]]*\\?"1310\\?"|Weekly/Monthly Limit Exhausted' && return 0
  breaker_hard_match "$bottom" antigravity-429 'Quota reached\. (Please wait|Next: switch models)|RESOURCE_EXHAUSTED' && return 0
  breaker_hard_match "$bottom" codex-usage-limit "The usage limit has been reached|You've hit your usage limit" && return 0
  breaker_hard_match "$bottom" claude-usage-limit "Claude (AI )?usage limit reached|5-hour limit reached|You've hit your limit" && return 0
  count=$(printf '%s\n' "$bottom" | grep -cE '\\?"code\\?"[[:space:]]*:[[:space:]]*\\?"1302\\?"|Rate limit reached for requests')
  if [ "${count:-0}" -ge "$repeats" ]; then
    row=$(printf '%s\n' "$bottom" | grep -E 'Rate limit reached for requests|"1302"' | tail -n 1)
    printf '%s\t%s (x%s)\n' zai-1302 "$(printf '%s' "$row" | sed 's/^[[:space:]]*//' | cut -c1-160)" "$count"
  fi
  return 0
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  classify) fm_quota_breaker_classify "${2:-$RATE_REPEATS}"; exit 0 ;;
  scan) ;;
  *) usage >&2; exit 2 ;;
esac

if [ -z "${FM_HOME:-}" ] || [ ! -d "$FM_HOME" ]; then
  echo "error: FM_HOME is not set to a firstmate home; fm-quota-breaker refuses to guess one" >&2
  exit 1
fi
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
[ -d "$STATE" ] || { echo "error: state dir '$STATE' is missing" >&2; exit 1; }
[ -f "$CONFIG/quota-breaker" ] || exit 0
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in ''|'#'*) continue ;; esac
  value=${line#*=}
  case "$value" in '' | 0* | *[!0-9]*) continue ;; esac
  case "${line%%=*}" in
    rate-limit-repeats) RATE_REPEATS=$value ;;
    realert-seconds) REALERT=$value ;;
  esac
done < "$CONFIG/quota-breaker"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

now=$(date +%s)
for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] || continue
  id=$(basename "$meta" .meta)
  case "$(fm_meta_get "$meta" kind)" in
    ''|ship|scout) ;;
    *) continue ;;
  esac
  case "$(grep -v '^[[:space:]]*$' "$STATE/$id.status" 2>/dev/null | tail -n 1)" in
    'done '*|'done['*|'failed '*|'failed['*) continue ;;
  esac
  [ -z "$(fm_meta_get "$meta" remote_host)" ] || continue
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  [ -n "$target" ] || continue
  case "$(fm_backend_agent_state "$backend" "$target" 2>/dev/null)" in
    alive|unverified) ;;
    *) continue ;;
  esac
  tail=$(fm_backend_capture "$backend" "$target" 60 2>/dev/null) || continue
  verdict=$(printf '%s\n' "$tail" | fm_quota_breaker_classify "$RATE_REPEATS")
  [ -n "$verdict" ] || continue
  class=${verdict%%$'\t'*}
  row=${verdict#*$'\t'}
  gen=$(fm_meta_get "$meta" spawn_gen)
  record="$STATE/$id.quota-breaker"
  if [ -f "$record" ] \
     && [ "$(sed -n 's/^class=//p' "$record")" = "$class" ] \
     && [ "$(sed -n 's/^spawn_gen=//p' "$record")" = "$gen" ]; then
    last=$(sed -n 's/^epoch=//p' "$record")
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
    [ $((now - last)) -ge "$REALERT" ] || continue
  fi
  printf 'class=%s\nspawn_gen=%s\nepoch=%s\n' "$class" "$gen" "$now" > "$record" || continue
  printf 'quota-breaker %s %s harness=%s model=%s: %s\n' "$id" "$class" \
    "$(fm_meta_get "$meta" harness)" "$(fm_meta_get "$meta" model)" "$row"
done
exit 0
