#!/usr/bin/env bash
# fm-decision-tier-lib.sh - the decision-tiering classifier and the
# default-with-veto timeout mechanism (fleet engineering plan workstream 1,
# "widen the judgment channel" - data/fleet-engineering-plan.html).
#
# Sourced, never executed. Every function is pure with respect to the system
# clock: any function that needs "now" takes it as an explicit epoch-seconds
# argument rather than calling `date` itself, so the whole library is
# deterministic and testable. bin/fm-decision-tier.sh is the CLI that supplies
# the real clock (with a --now override) around this library.
#
# NOT WIRED IN. This is a standalone building block. Nothing in firstmate's
# live escalation path (AGENTS.md sections 7-9) calls into this library yet.
# Turning it on - having firstmate's own escalation logic actually consult
# fm_decision_tier_classify before deciding whether to act, batch, or
# escalate - is a captain decision (the plan's workstream 1 says so
# explicitly: delegating real decision authority cannot be self-granted).
#
# This library owns THREE contracts:
#
#   1. THE CLASSIFICATION TABLE (fm_decision_tier_classify) - the single owner
#      of category -> tier. Three tiers, matching AGENTS.md's own vocabulary:
#        auto         - consistent with precedent; act and log, no captain
#                        involvement at all.
#        default-veto - a recommendation and a default are stated; the action
#                        proceeds unless the captain objects inside a stated
#                        window (AGENTS.md's "default-with-veto").
#        hard-stop    - merges, destructive or irreversible actions, scope
#                        expansion, client-facing semantics, credentials, and
#                        outward-facing actions. Always escalates.
#      An unrecognized category classifies hard-stop: the table fails closed,
#      never open, on anything it does not recognize. Extend the taxonomy by
#      adding the new category token to the matching case arm below - that
#      one edit is the whole extension point; no other function in this file
#      encodes tier assignment.
#
#   2. THE DECISION RECORD - the one shape every event in a decision's history
#      is written as, a 9-field TAB-separated line:
#          <epoch>\t<id>\t<category>\t<tier>\t<event>\t<window>\t<recommendation>\t<default_action>\t<note>
#      `event` is one of:
#        opened    - a default-veto decision's recommendation, default action,
#                    and window were stated (fm_decision_tier_open_default).
#        vetoed    - the captain objected before the window elapsed
#                    (fm_decision_tier_veto).
#        acted     - an auto-tier decision was acted on and logged
#                    (fm_decision_tier_log_auto).
#        escalated - a hard-stop decision reached the captain
#                    (fm_decision_tier_log_hard_stop).
#      `window`, `recommendation`, and `default_action` are populated only on
#      `opened` records; every other event leaves them empty. Fields are
#      TAB/newline-scrubbed on construction so a record can never desync into
#      more than nine columns.
#
#   3. STATUS DERIVATION (fm_decision_tier_status) - the single-owner
#      "expires into action" rule for a default-veto decision, purely a
#      function of its opened record and the supplied now:
#        vetoed  - a vetoed record exists for this id (wins regardless of the
#                  window).
#        expired - now - opened_epoch >= window, no veto: the default action
#                  is cleared to run.
#        pending - still inside the window, no veto yet.
#        unknown - no opened record exists for this id.
#      This is what makes a tier-2 decision "carry a stated default that
#      expires into action rather than blocking indefinitely": nothing has to
#      poll or remind anyone. The status is recomputable at any later time
#      from the log alone.
#
# fm_decision_tier_report aggregates a whole log into counters, including
# escalation_count (hard-stop decisions - the only tier that unconditionally
# reaches the captain), so a session's escalation count is a reported,
# measurable quantity rather than a felt impression.
#
# The `log_auto` / `log_hard_stop` / `open_default` / `veto` mutators all
# refuse (return 1, message on stderr) rather than silently mis-tiering:
# logging a category as auto when it classifies default-veto or hard-stop is
# refused, opening a default-veto record for a hard-stop category is refused,
# opening a default-veto record with an empty recommendation or default
# action is refused (the tier's whole contract is a stated recommendation and
# an executable default), reusing an id that already has any record in the
# log is refused for every one of log_auto/log_hard_stop/open_default (a
# reused id would let status/report collapse two unrelated decisions into
# one), and vetoing a decision that is not currently pending (already vetoed
# or already expired) is refused. Every one of those refusals is a real,
# mutation-provable guard - see tests/fm-decision-tier-lib.test.sh.
set -u

FM_DECISION_TIER_FIELD_SEP=$'\t'

# --- validation helpers ------------------------------------------------------

fm_decision_tier_require_nonempty() {  # <label> <value>
  if [ -z "${2:-}" ]; then
    printf 'fm-decision-tier-lib: %s must not be empty\n' "$1" >&2
    return 1
  fi
}

fm_decision_tier_require_int() {  # <label> <value>
  case "${2:-}" in
    ''|*[!0-9]*)
      printf 'fm-decision-tier-lib: %s must be a non-negative integer: %s\n' "$1" "${2:-}" >&2
      return 1
      ;;
  esac
}

# fm_decision_tier_require_unused_id: refuses an id that already has any
# record in the log. Every mutator that OPENS a new decision's lifecycle
# (log_auto, log_hard_stop, open_default) must call this before writing, so
# an id never carries more than one lifecycle - a reused id would otherwise
# let status/report collapse an unrelated later opening together with an
# earlier acted/escalated/opened record.
fm_decision_tier_require_unused_id() {  # <log_file> <id>
  local log=$1 id=$2
  if [ -n "$(fm_decision_tier_find_records "$log" "$id")" ]; then
    printf 'fm-decision-tier-lib: id %s already has a decision recorded; ids must not be reused\n' "$id" >&2
    return 1
  fi
}

# --- 1. the classification table ---------------------------------------------

# fm_decision_tier_classify: THE single-owner category -> tier table.
# Prints exactly one of auto|default-veto|hard-stop. Never fails.
fm_decision_tier_classify() {  # <category>
  case "${1:-}" in
    precedent-match|sibling-answer-reuse|measurement-refuted-revert|\
    stale-comment-correction|followup-routing)
      printf 'auto'
      ;;
    two-option-tradeoff|scope-narrowing|risk-tradeoff-reversible|process-default)
      printf 'default-veto'
      ;;
    merge|destructive|irreversible|scope-expansion|client-facing|\
    credential|outward-facing|security-sensitive)
      printf 'hard-stop'
      ;;
    *)
      # Fail closed: an unrecognized category always escalates rather than
      # silently acting or silently proceeding on a stated default.
      printf 'hard-stop'
      ;;
  esac
}

fm_decision_tier_tiers() {
  printf 'auto\ndefault-veto\nhard-stop\n'
}

# fm_decision_tier_known_categories: the category VOCABULARY only, not the
# tier mapping (that stays owned solely by fm_decision_tier_classify above).
fm_decision_tier_known_categories() {
  cat <<'EOF'
precedent-match
sibling-answer-reuse
measurement-refuted-revert
stale-comment-correction
followup-routing
two-option-tradeoff
scope-narrowing
risk-tradeoff-reversible
process-default
merge
destructive
irreversible
scope-expansion
client-facing
credential
outward-facing
security-sensitive
EOF
}

# fm_decision_tier_categories_for: known categories filtered to one tier,
# derived by calling fm_decision_tier_classify on each - never a second table.
fm_decision_tier_categories_for() {  # <tier>
  local want=$1 c
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    [ "$(fm_decision_tier_classify "$c")" = "$want" ] && printf '%s\n' "$c"
  done < <(fm_decision_tier_known_categories)
  return 0
}

# --- 2. the decision record ---------------------------------------------------

fm_decision_tier_clean_field() {
  printf '%s' "${1:-}" | LC_ALL=C tr '\t\r\n' '   '
}

fm_decision_tier_record() {  # <epoch> <id> <category> <tier> <event> <window> <recommendation> <default_action> <note>
  local epoch id category tier event window rec default_action note
  epoch=$(fm_decision_tier_clean_field "${1:-}")
  id=$(fm_decision_tier_clean_field "${2:-}")
  category=$(fm_decision_tier_clean_field "${3:-}")
  tier=$(fm_decision_tier_clean_field "${4:-}")
  event=$(fm_decision_tier_clean_field "${5:-}")
  window=$(fm_decision_tier_clean_field "${6:-}")
  rec=$(fm_decision_tier_clean_field "${7:-}")
  default_action=$(fm_decision_tier_clean_field "${8:-}")
  note=$(fm_decision_tier_clean_field "${9:-}")
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
    "$epoch" "$id" "$category" "$tier" "$event" "$window" "$rec" "$default_action" "$note"
}

fm_decision_tier_field() {  # <record> <n>
  printf '%s' "$1" | cut -d"$FM_DECISION_TIER_FIELD_SEP" -f"$2"
}

fm_decision_tier_epoch()          { fm_decision_tier_field "$1" 1; }
fm_decision_tier_id()             { fm_decision_tier_field "$1" 2; }
fm_decision_tier_category()       { fm_decision_tier_field "$1" 3; }
fm_decision_tier_tier()           { fm_decision_tier_field "$1" 4; }
fm_decision_tier_event()          { fm_decision_tier_field "$1" 5; }
fm_decision_tier_window()         { fm_decision_tier_field "$1" 6; }
fm_decision_tier_recommendation() { fm_decision_tier_field "$1" 7; }
fm_decision_tier_default_action() { fm_decision_tier_field "$1" 8; }
fm_decision_tier_note()           { fm_decision_tier_field "$1" 9; }

fm_decision_tier_log() {  # <log_file> <record>
  local log=$1 rec=$2 dir
  dir=$(dirname "$log")
  [ -d "$dir" ] || mkdir -p "$dir" || return 1
  printf '%s\n' "$rec" >> "$log"
}

# fm_decision_tier_find_records: every record for one id, in file order.
fm_decision_tier_find_records() {  # <log_file> <id>
  local log=$1 id=$2 line
  [ -f "$log" ] || return 0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [ "$(fm_decision_tier_id "$line")" = "$id" ] && printf '%s\n' "$line"
  done < "$log"
  return 0
}

# --- mutators: each refuses when the category's own tier disagrees ----------

fm_decision_tier_log_auto() {  # <log_file> <epoch> <id> <category> <note>
  local log=$1 now=$2 id=$3 category=$4 note=${5:-} tier
  fm_decision_tier_require_nonempty log_file "$log" || return 1
  fm_decision_tier_require_int epoch "$now" || return 1
  fm_decision_tier_require_nonempty id "$id" || return 1
  fm_decision_tier_require_unused_id "$log" "$id" || return 1
  tier=$(fm_decision_tier_classify "$category")
  if [ "$tier" != auto ]; then
    printf 'fm-decision-tier-lib: category %s classifies %s, not auto; refusing\n' "$category" "$tier" >&2
    return 1
  fi
  fm_decision_tier_log "$log" "$(fm_decision_tier_record "$now" "$id" "$category" "$tier" acted "" "" "" "$note")"
}

fm_decision_tier_log_hard_stop() {  # <log_file> <epoch> <id> <category> <note>
  local log=$1 now=$2 id=$3 category=$4 note=${5:-} tier
  fm_decision_tier_require_nonempty log_file "$log" || return 1
  fm_decision_tier_require_int epoch "$now" || return 1
  fm_decision_tier_require_nonempty id "$id" || return 1
  fm_decision_tier_require_unused_id "$log" "$id" || return 1
  tier=$(fm_decision_tier_classify "$category")
  if [ "$tier" != hard-stop ]; then
    printf 'fm-decision-tier-lib: category %s classifies %s, not hard-stop; refusing\n' "$category" "$tier" >&2
    return 1
  fi
  fm_decision_tier_log "$log" "$(fm_decision_tier_record "$now" "$id" "$category" "$tier" escalated "" "" "" "$note")"
}

fm_decision_tier_open_default() {  # <log_file> <epoch> <id> <category> <recommendation> <default_action> <window_seconds>
  local log=$1 now=$2 id=$3 category=$4 recommendation=${5:-} default_action=${6:-} window=$7 tier
  fm_decision_tier_require_nonempty log_file "$log" || return 1
  fm_decision_tier_require_int epoch "$now" || return 1
  fm_decision_tier_require_nonempty id "$id" || return 1
  fm_decision_tier_require_unused_id "$log" "$id" || return 1
  fm_decision_tier_require_nonempty recommendation "$recommendation" || return 1
  fm_decision_tier_require_nonempty default_action "$default_action" || return 1
  fm_decision_tier_require_int window_seconds "$window" || return 1
  if [ "$window" -eq 0 ]; then
    printf 'fm-decision-tier-lib: window_seconds must be greater than zero (a zero window never lets the captain veto)\n' >&2
    return 1
  fi
  tier=$(fm_decision_tier_classify "$category")
  if [ "$tier" != default-veto ]; then
    printf 'fm-decision-tier-lib: category %s classifies %s, not default-veto; refusing to open a timed default for it\n' "$category" "$tier" >&2
    return 1
  fi
  fm_decision_tier_log "$log" "$(fm_decision_tier_record "$now" "$id" "$category" "$tier" opened "$window" "$recommendation" "$default_action" "")"
}

# --- 3. status derivation -----------------------------------------------------

fm_decision_tier_status() {  # <log_file> <id> <epoch> -> pending|vetoed|expired|unknown
  local log=$1 id=$2 now=$3 opened_rec="" vetoed=0 line opened_epoch window
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$(fm_decision_tier_event "$line")" in
      opened) opened_rec=$line ;;
      vetoed) vetoed=1 ;;
    esac
  done < <(fm_decision_tier_find_records "$log" "$id")
  if [ -z "$opened_rec" ]; then
    printf 'unknown'
    return 0
  fi
  if [ "$vetoed" -eq 1 ]; then
    printf 'vetoed'
    return 0
  fi
  opened_epoch=$(fm_decision_tier_epoch "$opened_rec")
  window=$(fm_decision_tier_window "$opened_rec")
  if [ $((now - opened_epoch)) -ge "$window" ]; then
    printf 'expired'
  else
    printf 'pending'
  fi
}

fm_decision_tier_veto() {  # <log_file> <epoch> <id> <note>
  local log=$1 now=$2 id=$3 note=${4:-} status line opened_rec=""
  fm_decision_tier_require_nonempty log_file "$log" || return 1
  fm_decision_tier_require_int epoch "$now" || return 1
  fm_decision_tier_require_nonempty id "$id" || return 1
  status=$(fm_decision_tier_status "$log" "$id" "$now")
  if [ "$status" != pending ]; then
    printf 'fm-decision-tier-lib: cannot veto id %s: status is %s, not pending\n' "$id" "$status" >&2
    return 1
  fi
  while IFS= read -r line; do
    [ "$(fm_decision_tier_event "$line")" = opened ] && opened_rec=$line
  done < <(fm_decision_tier_find_records "$log" "$id")
  fm_decision_tier_log "$log" "$(fm_decision_tier_record "$now" "$id" \
    "$(fm_decision_tier_category "$opened_rec")" "$(fm_decision_tier_tier "$opened_rec")" \
    vetoed "" "" "" "$note")"
}

# --- reporting ----------------------------------------------------------------

# fm_decision_tier_report: aggregate a whole log into `key=value` counter
# lines. escalation_count is the hard-stop count - the only tier that
# unconditionally reaches the captain - so a session's escalation count is
# read off this report rather than felt.
fm_decision_tier_report() {  # <log_file> <epoch>
  local log=$1 now=$2
  local total=0 auto=0 hard_stop=0 pending=0 expired=0 vetoed=0
  local id status has_acted has_escalated line
  if [ -f "$log" ]; then
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      has_acted=0
      has_escalated=0
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        case "$(fm_decision_tier_event "$line")" in
          acted) has_acted=1 ;;
          escalated) has_escalated=1 ;;
        esac
      done < <(fm_decision_tier_find_records "$log" "$id")
      if [ "$has_acted" -eq 1 ]; then
        auto=$((auto + 1))
      elif [ "$has_escalated" -eq 1 ]; then
        hard_stop=$((hard_stop + 1))
      else
        status=$(fm_decision_tier_status "$log" "$id" "$now")
        case "$status" in
          pending) pending=$((pending + 1)) ;;
          expired) expired=$((expired + 1)) ;;
          vetoed) vetoed=$((vetoed + 1)) ;;
        esac
      fi
      total=$((total + 1))
    done < <(cut -d"$FM_DECISION_TIER_FIELD_SEP" -f2 "$log" | LC_ALL=C sort -u)
  fi
  printf 'total=%d\n' "$total"
  printf 'auto=%d\n' "$auto"
  printf 'default_pending=%d\n' "$pending"
  printf 'default_expired=%d\n' "$expired"
  printf 'default_vetoed=%d\n' "$vetoed"
  printf 'hard_stop=%d\n' "$hard_stop"
  printf 'escalation_count=%d\n' "$hard_stop"
}
