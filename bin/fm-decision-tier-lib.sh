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
# opening a default-veto record with a recommendation or default action that
# is empty OR consists solely of whitespace/control characters is refused
# (the tier's whole contract is a stated recommendation and an executable
# default - whitespace or an unprintable control byte is not one), reusing
# an id that already has any record in the log is
# refused for every one of log_auto/log_hard_stop/open_default (a reused id
# would let status/report collapse two unrelated decisions into one), and
# vetoing a decision that is not currently pending (already vetoed or already
# expired) is refused. The reused-id check and the record it guards are
# performed while holding a lock on the log file (fm_decision_tier_lock_*),
# so two processes racing to open the same id are serialized rather than both
# passing the uniqueness check before either has written. Every one of those
# refusals is a real, mutation-provable guard - see
# tests/fm-decision-tier-lib.test.sh.
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

# fm_decision_tier_require_meaningful: refuses a value that is empty OR
# normalizes to nothing but whitespace/control characters once stripped.
# require_nonempty alone lets a value through that is technically non-empty
# but carries no content: all spaces, a lone TAB/newline that the record
# builder turns into spaces, or a non-whitespace control byte (e.g. $'\x01')
# that fm_decision_tier_clean_field does not touch and that persists verbatim
# - every one of those is a case where a default-veto record would be
# persisted with no stated recommendation or executable default despite
# passing validation. Stripping both [:space:] and [:cntrl:] catches all
# three: only printable, non-whitespace content counts as meaningful.
fm_decision_tier_require_meaningful() {  # <label> <value>
  local label=$1 value=${2:-} stripped
  stripped=$(printf '%s' "$value" | LC_ALL=C tr -d '[:space:][:cntrl:]')
  if [ -z "$stripped" ]; then
    printf 'fm-decision-tier-lib: %s must contain meaningful (printable, non-whitespace) content\n' "$label" >&2
    return 1
  fi
}

# fm_decision_tier_lock_acquire / _release: a minimal mutex around the
# check-and-append sequence that opens a decision's lifecycle
# (require_unused_id followed by the log write). The lock is a symlink
# whose target is "<holder_pid>:<holder_start_time>", created with `ln -s`:
# symlink creation is a single atomic syscall, so the lock's existence and
# its holder's identity are established in the exact same instant - there
# is no window where the lock exists but its holder is not yet readable
# (unlike a two-step mkdir-then-write-pid-file scheme, where a holder
# killed between the two steps would leave a lock no contender could ever
# identify as abandoned).
#
# A holder that dies (killed, crashes, or the append itself fails) before
# releasing leaves the symlink behind with nothing left to remove it -
# every later writer would then retry `ln -s` forever. To recover from
# that, a contender that fails to `ln -s` calls fm_decision_tier_lock_is_stale,
# which treats the lock as abandoned - and breaks it before retrying -
# whenever any of these hold: the lock isn't a valid PID:start-time symlink
# at all (e.g. a leftover/corrupt artifact), the recorded PID is no longer
# alive (`kill -0` fails), or the recorded PID IS alive but its current
# process-start time no longer matches what was recorded when the lock was
# created.
#
# That last case is the one a bare `kill -0 <recorded_pid>` cannot catch:
# PIDs are recycled by the OS, so a holder that dies and is later reused
# for an unrelated, still-running process would make `kill -0` succeed
# forever, wedging every subsequent writer on a lock nobody is actually
# holding. Recording the holder's process-start time (`ps -o lstart=`)
# alongside its PID closes that gap - an unrelated process handed the same
# recycled PID essentially never has the exact same start time as the
# original holder, so the mismatch outs it as an impostor rather than a
# still-legitimate lock.
#
# A plain DIRECTORY left at the lock path (e.g. by the earlier mkdir-based
# locking scheme this replaced) needs its own check ahead of the `ln -s`
# attempt: unlike a file or symlink, `ln -s target dir` does not fail when
# `dir` already exists as a directory - it silently creates the link INSIDE
# that directory instead, so the loop would never even notice the stale
# directory, let alone break it. The `[ -e ... ] && [ ! -L ... ]` check below
# catches that case directly (a symlink also passes `-e` when its target is
# a directory, so `-L` is checked first to exclude a legitimate lock) and
# routes it through fm_decision_tier_lock_break, same as a stale symlink.
#
# Breaking (removing) whatever currently sits at the lock path is never done
# directly in this loop - it always goes through fm_decision_tier_lock_break,
# which serializes breakers behind their own mkdir-based mutex. Without that,
# two contenders can both observe the same abandoned lock as stale and both
# act on it: one removes it and creates its own fresh lock, and the other -
# having already decided the *original* lock was stale before the first one
# acted - then removes whatever now sits at the path, destroying the first
# contender's brand-new legitimate lock out from under it. Both then believe
# they hold the lock exclusively. Routing every removal through a single
# mkdir-guarded critical section (mkdir is an atomic test-and-set, unlike a
# bare rm racing a bare ln -s) means only one breaker ever inspects-and-acts
# at a time, and it re-confirms staleness after acquiring the mutex in case
# another breaker already replaced the lock while this one was waiting.
fm_decision_tier_lock_acquire() {  # <log_file>
  local log=$1
  local lockdir="$log.lock" dir start
  dir=$(dirname "$log")
  [ -d "$dir" ] || mkdir -p "$dir" || return 1
  start=$(fm_decision_tier_pid_start_time "$$")
  while :; do
    if [ ! -e "$lockdir" ] && ln -s "$$:$start" "$lockdir" 2>/dev/null; then
      break
    fi
    fm_decision_tier_lock_break "$lockdir"
    sleep 0.05
  done
}

# fm_decision_tier_lock_break: the only place that ever removes whatever
# currently sits at <lockdir>. Guarded by its own mkdir-based mutex so
# concurrent contenders can never both act on the same abandoned artifact
# (see fm_decision_tier_lock_acquire above for why that matters). A losing
# contender that fails to grab the mutex returns immediately without
# touching anything - the winner's inspection-and-removal is the only one
# that runs, and the loser just retries fm_decision_tier_lock_acquire's loop.
#
# A leftover DIRECTORY is only ever removed via `rmdir`, which succeeds
# solely when the directory is empty. That is exactly the shape the retired
# mkdir-based locking scheme could abandon (a holder that died right after
# `mkdir` and before writing anything into it). A directory that is NOT
# empty is left alone rather than recursively deleted: this library has no
# way to prove an arbitrary non-empty directory sitting at a lock path is an
# abandoned lock artifact rather than someone else's real data, so it
# refuses to guess and keeps the caller waiting instead of destroying it. A
# leftover artifact that is neither a symlink nor a directory (e.g. a plain
# file - not a shape any lock implementation here has ever written, only a
# corrupt/foreign one) carries no such ambiguity and is removed with `rm -f`.
fm_decision_tier_lock_break() {  # <lockdir>
  local lockdir=$1
  local mutex="$lockdir.break"
  mkdir "$mutex" 2>/dev/null || return 0
  if [ -L "$lockdir" ]; then
    fm_decision_tier_lock_is_stale "$lockdir" && rm -f "$lockdir" 2>/dev/null
  elif [ -d "$lockdir" ]; then
    rmdir "$lockdir" 2>/dev/null
  elif [ -e "$lockdir" ]; then
    rm -f "$lockdir" 2>/dev/null
  fi
  rmdir "$mutex" 2>/dev/null
}

# fm_decision_tier_pid_start_time: prints the process-start timestamp
# (`ps -o lstart=`) for a still-living <pid>, or an empty string if no
# process with that PID currently exists. `lstart` is supported by both
# GNU/Linux and BSD/macOS `ps`, so this is portable across the platforms
# this library runs on. Whitespace is collapsed so the result compares
# reliably regardless of column-padding differences between `ps`
# implementations.
fm_decision_tier_pid_start_time() {  # <pid>
  ps -o lstart= -p "$1" 2>/dev/null | LC_ALL=C tr -s '[:space:]' ' ' | sed -e 's/^ //' -e 's/ $//'
}

# fm_decision_tier_lock_is_stale: true (exit 0) if the lock symlink at
# <lockdir> was left by a holder that is no longer the process the lock
# was created for - the symlink isn't a valid "<pid>:<start_time>" target,
# the recorded PID is dead, or the recorded PID is alive but its current
# start time no longer matches the recorded one (the PID was reused by an
# unrelated process since the lock was created). Only when the recorded PID
# is alive AND its start time still matches is the lock still legitimately
# held (exit 1).
fm_decision_tier_lock_is_stale() {  # <lockdir>
  local lockdir=$1 holder holder_pid holder_start current_start
  holder=$(readlink "$lockdir" 2>/dev/null) || return 0
  [ -n "$holder" ] || return 0
  holder_pid=${holder%%:*}
  holder_start=${holder#*:}
  [ -n "$holder_pid" ] || return 0
  kill -0 "$holder_pid" 2>/dev/null || return 0
  current_start=$(fm_decision_tier_pid_start_time "$holder_pid")
  [ -n "$current_start" ] && [ "$current_start" = "$holder_start" ] && return 1
  return 0
}

fm_decision_tier_lock_release() {  # <log_file>
  rm -f "$1.lock" 2>/dev/null || true
}

# fm_decision_tier_require_unused_id: refuses an id that already has any
# record in the log. Every mutator that OPENS a new decision's lifecycle
# (log_auto, log_hard_stop, open_default) must call this before writing, so
# an id never carries more than one lifecycle - a reused id would otherwise
# let status/report collapse an unrelated later opening together with an
# earlier acted/escalated/opened record.
#
# Callers must pass an id already run through fm_decision_tier_clean_field
# (every mutator below normalizes its id argument before calling this) -
# stored ids are always the normalized form fm_decision_tier_record wrote,
# so comparing this function's raw input against them would let two ids
# that only differ by a TAB/CR/LF-vs-space both pass as "unused" and then
# collide once normalized on write.
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
# The id is run through the same TAB/CR/LF scrub fm_decision_tier_record
# applies before storing it, so this always compares against the id in the
# form it was actually persisted in - an id that differs from a stored one
# only by a TAB/CR/LF-vs-space substitution collides with it here instead of
# looking unused and then colliding silently once written.
fm_decision_tier_find_records() {  # <log_file> <id>
  local log=$1 id line
  id=$(fm_decision_tier_clean_field "${2:-}")
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
  fm_decision_tier_lock_acquire "$log" || return 1
  if ! fm_decision_tier_require_unused_id "$log" "$id"; then
    fm_decision_tier_lock_release "$log"
    return 1
  fi
  tier=$(fm_decision_tier_classify "$category")
  if [ "$tier" != auto ]; then
    printf 'fm-decision-tier-lib: category %s classifies %s, not auto; refusing\n' "$category" "$tier" >&2
    fm_decision_tier_lock_release "$log"
    return 1
  fi
  fm_decision_tier_log "$log" "$(fm_decision_tier_record "$now" "$id" "$category" "$tier" acted "" "" "" "$note")"
  fm_decision_tier_lock_release "$log"
}

fm_decision_tier_log_hard_stop() {  # <log_file> <epoch> <id> <category> <note>
  local log=$1 now=$2 id=$3 category=$4 note=${5:-} tier
  fm_decision_tier_require_nonempty log_file "$log" || return 1
  fm_decision_tier_require_int epoch "$now" || return 1
  fm_decision_tier_require_nonempty id "$id" || return 1
  fm_decision_tier_lock_acquire "$log" || return 1
  if ! fm_decision_tier_require_unused_id "$log" "$id"; then
    fm_decision_tier_lock_release "$log"
    return 1
  fi
  tier=$(fm_decision_tier_classify "$category")
  if [ "$tier" != hard-stop ]; then
    printf 'fm-decision-tier-lib: category %s classifies %s, not hard-stop; refusing\n' "$category" "$tier" >&2
    fm_decision_tier_lock_release "$log"
    return 1
  fi
  fm_decision_tier_log "$log" "$(fm_decision_tier_record "$now" "$id" "$category" "$tier" escalated "" "" "" "$note")"
  fm_decision_tier_lock_release "$log"
}

fm_decision_tier_open_default() {  # <log_file> <epoch> <id> <category> <recommendation> <default_action> <window_seconds>
  local log=$1 now=$2 id=$3 category=$4 recommendation=${5:-} default_action=${6:-} window=$7 tier
  fm_decision_tier_require_nonempty log_file "$log" || return 1
  fm_decision_tier_require_int epoch "$now" || return 1
  fm_decision_tier_require_nonempty id "$id" || return 1
  fm_decision_tier_require_meaningful recommendation "$recommendation" || return 1
  fm_decision_tier_require_meaningful default_action "$default_action" || return 1
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
  fm_decision_tier_lock_acquire "$log" || return 1
  if ! fm_decision_tier_require_unused_id "$log" "$id"; then
    fm_decision_tier_lock_release "$log"
    return 1
  fi
  fm_decision_tier_log "$log" "$(fm_decision_tier_record "$now" "$id" "$category" "$tier" opened "$window" "$recommendation" "$default_action" "")"
  fm_decision_tier_lock_release "$log"
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
