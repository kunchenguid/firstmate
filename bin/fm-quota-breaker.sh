#!/usr/bin/env bash
# fm-quota-breaker.sh - quota circuit breaker: notice a live worker stalled on a
# hard provider quota or rate-limit refusal and wake its firstmate to relaunch
# it on the next candidate of the same dispatch group.
#
# Usage: fm-quota-breaker.sh scan [--durable]
#        fm-quota-breaker.sh ack <task-id> <class> <epoch> <spawn-gen>
#        fm-quota-breaker.sh classify     (reads a captured pane on stdin)
#
# WHY. A worker whose provider refuses with a hard quota error does not fail:
# its harness retries, gives up, and sits idle with the error on screen, and
# nothing reports it until someone looks. A run of those cost hours of lanes.
# The relaunch decision itself stays with firstmate, because choosing the next
# candidate is the quota-array-dispatch procedure (its "Quota circuit breaker"
# section); this script only turns the stall into a typed notification. The wake
# carries the task's brief path so firstmate can re-resolve its original group
# and exclude the tripped candidate without persisting another group identity.
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
#   quota-breaker <task-id> <class> harness=<h> model=<m> brief=<path>: <matched row>
# The waking firstmate re-resolves that brief against crew-dispatch.json as at
# intake, keeping the replacement inside the task's original dispatch group.
# which the watcher queues as one `check: quota-breaker` notification each.
# state/<task-id>.quota-breaker remembers the last acknowledged report (class,
# spawn generation, time), so one stall is reported once per realert window and
# a relaunched incarnation that hits the same wall is reported afresh.
# In `scan --durable` mode, state/<task-id>.quota-breaker.pending is written
# before output; the watcher acknowledges it only after the wake queue append,
# so a failed append remains retryable instead of consuming the realert window.
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

breaker_refusal_is_current() {
  local rows=$1 ere=$2 line found=0
  while IFS= read -r line || [ -n "$line" ]; do
    if printf '%s\n' "$line" | grep -qE -- "$ere"; then
      found=1
    else
      # A recovery after an older refusal must not hide a later refusal. Keep
      # only the verdict for the last pane row, rather than returning at the
      # first progress row after any earlier match.
      found=0
    fi
  done <<< "$rows"
  [ "$found" -eq 1 ]
}

# fm_quota_breaker_classify [repeats]: stdin pane tail -> "<class>\t<row>".
fm_quota_breaker_classify() {
  local repeats=${1:-5} tail content row count
  tail=$(cat)
  content=$(printf '%s\n' "$tail" \
    | grep -v '^[[:space:]]*$' \
    | grep -Ev '^[[:space:]]*([─━╭╰│❯›⟩→❭>$%#?]|~/|/|[0-9]+(\.[0-9]+)?%/|\(auto\))' \
    | tail -n 15 || true)
  if breaker_refusal_is_current "$content" '\\?"code\\?"[[:space:]]*:[[:space:]]*\\?"1308\\?"|Usage limit reached for 5 hour'; then
    breaker_hard_match "$content" zai-1308 '\\?"code\\?"[[:space:]]*:[[:space:]]*\\?"1308\\?"|Usage limit reached for 5 hour'
    return 0
  fi
  if breaker_refusal_is_current "$content" '\\?"code\\?"[[:space:]]*:[[:space:]]*\\?"1310\\?"|Weekly/Monthly Limit Exhausted'; then
    breaker_hard_match "$content" zai-1310 '\\?"code\\?"[[:space:]]*:[[:space:]]*\\?"1310\\?"|Weekly/Monthly Limit Exhausted'
    return 0
  fi
  if breaker_refusal_is_current "$content" 'Quota reached\. (Please wait|Next: switch models)|RESOURCE_EXHAUSTED'; then
    breaker_hard_match "$content" antigravity-429 'Quota reached\. (Please wait|Next: switch models)|RESOURCE_EXHAUSTED'
    return 0
  fi
  if breaker_refusal_is_current "$content" "The usage limit has been reached|You've hit your usage limit"; then
    breaker_hard_match "$content" codex-usage-limit "The usage limit has been reached|You've hit your usage limit"
    return 0
  fi
  if breaker_refusal_is_current "$content" "Claude (AI )?usage limit reached|5-hour limit reached|You've hit your limit"; then
    breaker_hard_match "$content" claude-usage-limit "Claude (AI )?usage limit reached|5-hour limit reached|You've hit your limit"
    return 0
  fi
  count=$(printf '%s\n' "$content" | grep -cE '\\?"code\\?"[[:space:]]*:[[:space:]]*\\?"1302\\?"|Rate limit reached for requests')
  if [ "${count:-0}" -ge "$repeats" ] \
    && breaker_refusal_is_current "$content" '\\?"code\\?"[[:space:]]*:[[:space:]]*\\?"1302\\?"|Rate limit reached for requests'; then
    row=$(printf '%s\n' "$content" | grep -E 'Rate limit reached for requests|"1302"' | tail -n 1)
    printf '%s\t%s (x%s)\n' zai-1302 "$(printf '%s' "$row" | sed 's/^[[:space:]]*//' | cut -c1-160)" "$count"
  fi
  return 0
}

ACTION=${1:-}
DURABLE=0
case "$ACTION" in
  -h|--help) usage; exit 0 ;;
  classify) fm_quota_breaker_classify "${2:-$RATE_REPEATS}"; exit 0 ;;
  scan)
    [ "${2:-}" = --durable ] && DURABLE=1
    [ "$#" -le 2 ] || { usage >&2; exit 2; }
    ;;
  ack)
    [ "$#" -eq 5 ] || { usage >&2; exit 2; }
    ACK_ID=$2 ACK_CLASS=$3 ACK_EPOCH=$4 ACK_GEN=$5
    ;;
  *) usage >&2; exit 2 ;;
esac

if [ -z "${FM_HOME:-}" ] || [ ! -d "$FM_HOME" ]; then
  echo "error: FM_HOME is not set to a firstmate home; fm-quota-breaker refuses to guess one" >&2
  exit 1
fi
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
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
# shellcheck source=bin/fm-busy-lib.sh
. "$SCRIPT_DIR/fm-busy-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

if [ "$ACTION" = ack ]; then
  pending_record="$STATE/$ACK_ID.quota-breaker.pending"
  breaker_lock="$STATE/.quota-breaker-$ACK_ID.lock"
  fm_lock_try_acquire "$breaker_lock" || exit 0
  if [ -f "$pending_record" ] \
    && [ "$(sed -n 's/^class=//p' "$pending_record")" = "$ACK_CLASS" ] \
    && [ "$(sed -n 's/^spawn_gen=//p' "$pending_record")" = "$ACK_GEN" ] \
    && [ "$(sed -n 's/^epoch=//p' "$pending_record")" = "$ACK_EPOCH" ]; then
    ack_tmp=$(mktemp "$STATE/.$ACK_ID.quota-breaker.XXXXXX") || {
      fm_lock_release "$breaker_lock"
      exit 1
    }
    if ! printf 'class=%s\nspawn_gen=%s\nepoch=%s\npending=0\n' \
      "$ACK_CLASS" "$ACK_GEN" "$ACK_EPOCH" > "$ack_tmp" \
      || ! mv -f -- "$ack_tmp" "$STATE/$ACK_ID.quota-breaker"; then
      rm -f -- "$ack_tmp"
      fm_lock_release "$breaker_lock"
      exit 1
    fi
    rm -f -- "$pending_record" || {
      fm_lock_release "$breaker_lock"
      exit 1
    }
  fi
  fm_lock_release "$breaker_lock"
  exit 0
fi

breaker_release_locks() {
  [ -z "${BREAKER_META_LOCK:-}" ] || fm_lock_release "$BREAKER_META_LOCK"
  [ -z "${BREAKER_TASK_LOCK:-}" ] || fm_lock_release "$BREAKER_TASK_LOCK"
  BREAKER_META_LOCK=
  BREAKER_TASK_LOCK=
}

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
  pre_gen=$(fm_meta_get "$meta" spawn_gen)
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  [ -n "$target" ] || continue
  case "$(fm_backend_agent_state "$backend" "$target" 2>/dev/null)" in
    alive) ;;
    *) continue ;;
  esac
  tail=$(fm_backend_capture "$backend" "$target" 60 2>/dev/null) || continue
  case "$(fm_busy_classify_meta "$meta" "$id" "$STATE" "$tail")" in
    busy\ *) continue ;;
  esac
  verdict=$(printf '%s\n' "$tail" | fm_quota_breaker_classify "$RATE_REPEATS")
  [ -n "$verdict" ] || continue
  class=${verdict%%$'\t'*}
  row=${verdict#*$'\t'}
  record="$STATE/$id.quota-breaker"
  breaker_lock="$STATE/.quota-breaker-$id.lock"
  BREAKER_TASK_LOCK=$breaker_lock
  BREAKER_META_LOCK=
  fm_lock_try_acquire "$BREAKER_TASK_LOCK" || {
    BREAKER_TASK_LOCK=
    continue
  }
  # The pane capture happened before this point. Hold the task's authoritative
  # metadata lock while rechecking its incarnation and publishing the breaker
  # record, so a concurrent relaunch cannot make an old refusal look current.
  BREAKER_META_LOCK=$(fm_meta_lock_path "$meta" 2>/dev/null) || {
    breaker_release_locks
    continue
  }
  fm_lock_try_acquire "$BREAKER_META_LOCK" || {
    breaker_release_locks
    continue
  }
  if [ ! -f "$meta" ]; then
    breaker_release_locks
    continue
  fi
  case "$(grep -v '^[[:space:]]*$' "$STATE/$id.status" 2>/dev/null | tail -n 1)" in
    'done '*|'done['*|'failed '*|'failed['*)
      breaker_release_locks
      continue
      ;;
  esac
  gen=$(fm_meta_get "$meta" spawn_gen)
  [ "$gen" = "$pre_gen" ] || {
    breaker_release_locks
    continue
  }
  pending_record="$STATE/$id.quota-breaker.pending"
  pending_epoch=
  pending_exists=0
  if [ "$DURABLE" = 1 ] \
    && [ -f "$pending_record" ] \
    && [ "$(sed -n 's/^class=//p' "$pending_record")" = "$class" ] \
    && [ "$(sed -n 's/^spawn_gen=//p' "$pending_record")" = "$gen" ]; then
    pending_exists=1
    pending_epoch=$(sed -n 's/^epoch=//p' "$pending_record")
  fi
  if [ -f "$record" ] \
     && [ "$(sed -n 's/^class=//p' "$record")" = "$class" ] \
     && [ "$(sed -n 's/^spawn_gen=//p' "$record")" = "$gen" ]; then
    last=$(sed -n 's/^epoch=//p' "$record")
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
    if [ "$pending_exists" = 0 ] && [ $((now - last)) -lt "$REALERT" ]; then
      breaker_release_locks
      continue
    fi
  fi
  if [ "$DURABLE" = 1 ]; then
    if [ "$pending_exists" = 0 ]; then
      pending_epoch=$now
      pending_tmp=$(mktemp "$STATE/.$id.quota-breaker.pending.XXXXXX") || {
        breaker_release_locks
        continue
      }
      if ! printf 'class=%s\nspawn_gen=%s\nepoch=%s\n' "$class" "$gen" "$pending_epoch" > "$pending_tmp" \
        || ! mv -f -- "$pending_tmp" "$pending_record"; then
        rm -f -- "$pending_tmp"
        breaker_release_locks
        continue
      fi
    fi
  else
    breaker_tmp=$(mktemp "$STATE/.$id.quota-breaker.XXXXXX") || {
      breaker_release_locks
      continue
    }
    if ! printf 'class=%s\nspawn_gen=%s\nepoch=%s\npending=0\n' "$class" "$gen" "$now" > "$breaker_tmp" \
      || ! mv -f -- "$breaker_tmp" "$record"; then
      rm -f -- "$breaker_tmp"
      breaker_release_locks
      continue
    fi
  fi
  if [ "$DURABLE" = 1 ]; then
    printf 'quota-breaker %s %s harness=%s model=%s brief=%s: %s [quota-breaker-epoch=%s generation=%s]\n' "$id" "$class" \
      "$(fm_meta_get "$meta" harness)" "$(fm_meta_get "$meta" model)" "$DATA/$id/brief.md" "$row" "$pending_epoch" "$gen"
  else
    printf 'quota-breaker %s %s harness=%s model=%s brief=%s: %s\n' "$id" "$class" \
      "$(fm_meta_get "$meta" harness)" "$(fm_meta_get "$meta" model)" "$DATA/$id/brief.md" "$row"
  fi
  breaker_release_locks
done
exit 0
