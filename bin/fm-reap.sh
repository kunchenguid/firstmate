#!/usr/bin/env bash
# fm-reap.sh - close finished workers so no crewmate or scout outlives its task.
#
# Usage:
#   fm-reap.sh list    every recorded crewmate and scout with its reap verdict
#   fm-reap.sh check   the watcher check (state/reaper.check.sh): one line when
#                      the set of due workers or the last run's outcome changes
#   fm-reap.sh run     tear down every due worker now, printing closed/kept
#   fm-reap.sh arm     write state/reaper.check.sh and bind it with
#                      bin/fm-check-register.sh (bootstrap arms it every start
#                      while config/reaper exists)
#   fm-reap.sh sweep-state [--apply] [--verbose]
#                      remove provably stale runtime leftovers from this home's
#                      top-level state folder. Without --apply it is a read-only
#                      dry run that prints the same counts by kind; --verbose
#                      also prints one line per entry. It never runs on its own.
#
# Due: a ship or scout task recorded in state/<id>.meta whose newest lifecycle
#   status (working, needs-decision, blocked, paused, done, failed) is done,
#   FM_REAP_DONE_SECS (default 7200) after that done line, or, while a Lavish
#   board is registered for the task (a state/procevent/*.source naming it as
#   owner_task), FM_REAP_BOARD_SECS (default 86400) after the later of that
#   line and the board's newest captured round. The done line's [at=<epoch>]
#   stamp is the clock; a line without one uses the status file's mtime.
#   Second mates are persistent homes and are never due; failed, blocked, and
#   waiting tasks are left for firstmate.
#   A lane that never wrote done is also due once it has finished its work and
#   is only holding capacity: its newest lifecycle line is working or paused,
#   its milestones show a passed gate-end with no gate-start or gate-obsolete
#   after it and a pr-created (PR ready) or merge, and its status file has been
#   quiet for FM_REAP_IDLE_SECS (default 7200; the board grace above applies
#   while a Lavish board is registered). Its verdict reads
#   `due gate passed, PR ready|merged, idle <n>h`. A malformed or unreadable
#   milestone record means not due. Teardown stays the only judge of landed
#   work, so due here never discards anything: an unlanded lane is kept.
#   Merged fast path: a lane whose milestones show a merge and whose recorded
#   worktree is clean (a local git status, no network) is due at once - done
#   without waiting FM_REAP_DONE_SECS, a finished-but-working lane without
#   waiting FM_REAP_IDLE_SECS - because its PR landed and nothing local can
#   follow; a dirty or missing worktree falls back to the waits above, where
#   teardown names what it refuses to discard. A registered board keeps its
#   grace here too. The verdict reads `due done <n>h ago, PR merged, worktree
#   clean` or `due gate passed, PR merged, worktree clean`.
#
# Mode: config/reaper holds `shadow` or `enforce`; without the file the reaper
#   is off and its check prints nothing. Roll out with a shadow week first.
#   shadow reports the due workers in one check line and closes nothing.
#   enforce starts `run` in the background and reports its outcome on the next
#   check. `run` calls bin/fm-teardown.sh <id> without --force, so a worker
#   whose work has not landed is kept, never discarded (AGENTS.md hard rule 3),
#   and a task the captain still holds keeps its backlog call; each kept
#   worker is named with teardown's own reason. FM_REAP_TEARDOWN replaces the
#   teardown command for tests only.
#
# Enforce report backoff: a kept worker stays due for as long as its work has
#   not landed, so `run` rewrites the same `kept` line on every check pass; the
#   report prints an unchanged kept line once, then again only after an
#   exponentially growing delay - FM_REAP_REPEAT_BASE_SECS (default 3600)
#   doubling per repeat, capped at FM_REAP_REPEAT_CAP_SECS (default 86400, the
#   daily reminder) - and at once when the line changes (a new teardown
#   reason, or the same worker closed: `closed` lines always print). The run
#   still happens on every check; only the report backs off. The ledger is
#   state/.reaper-repeat, one "<cksum> <last-print-epoch> <repeats> <line>" row per
#   known kept line, pruned to the lines the latest run log still names; any
#   ledger problem fails open (the line prints).
#
# sweep-state considers only the three families below; anything else in state/,
#   including task records, wake queues, .seen-* dedup records, inboxes and
#   handled records, teardown and landing protection records, and lock links, is
#   never a candidate. Any doubt keeps the entry.
#   lock-owner-*: a state/*.lock[.steal].owner.* directory minted by
#     bin/fm-wake-lib.sh that no state/ symlink names, older than
#     FM_REAP_LOCK_AGE_SECS (default 86400), holding only that lock's known
#     record files plus stray links whose targets are gone. Its recorded pid
#     must be dead by fm_lock_holder_alive (lock-owner-dead-pid), or the record
#     must be gone (lock-owner-released): an acquirer writes it before publishing
#     and a release deletes it, so a directory without one has been released. A
#     released owner survives when a losing acquirer's `ln -s` followed the lock
#     link and left a stray link inside it, which fails the holder's rmdir.
#   window-marker: a watcher per-window marker (bin/fm-watch.sh window_key) older
#     than FM_REAP_MARKER_AGE_SECS (default 604800) whose window, terminal, or
#     thread no state/*.meta or *.meta-prior record names and no state/.wake-queue
#     row mentions. Teardown deletes a closed task's record and the watcher only
#     reads markers of recorded windows, so no process can read such a marker;
#     pane existence is not probed because an unrecorded pane has no reader. An
#     unreadable record or queue refuses the whole sweep before anything changes.
#   home-summary-temp: a state/.home-summary{.json,-error}.XXXXXX scratch file a
#     killed refresh left, older than FM_REAP_MARKER_AGE_SECS, far past the
#     refresh's own bounded deadline.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
DONE_SECS=${FM_REAP_DONE_SECS:-7200}
IDLE_SECS=${FM_REAP_IDLE_SECS:-7200}
BOARD_SECS=${FM_REAP_BOARD_SECS:-86400}
TEARDOWN=${FM_REAP_TEARDOWN:-$SCRIPT_DIR/fm-teardown.sh}
SWEEP_LOCK_AGE=${FM_REAP_LOCK_AGE_SECS:-86400}
SWEEP_MARKER_AGE=${FM_REAP_MARKER_AGE_SECS:-604800}
REPEAT_BASE=${FM_REAP_REPEAT_BASE_SECS:-3600}
REPEAT_CAP=${FM_REAP_REPEAT_CAP_SECS:-86400}

usage() { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; }
fail() { printf 'fm-reap: %s\n' "$1" >&2; exit 2; }
case "$DONE_SECS$BOARD_SECS$IDLE_SECS" in *[!0-9]*) fail 'FM_REAP_DONE_SECS, FM_REAP_BOARD_SECS and FM_REAP_IDLE_SECS must be whole seconds' ;; esac
case "$SWEEP_LOCK_AGE" in '' | *[!0-9]*) fail 'FM_REAP_LOCK_AGE_SECS must be whole seconds' ;; esac
case "$SWEEP_MARKER_AGE" in '' | *[!0-9]*) fail 'FM_REAP_MARKER_AGE_SECS must be whole seconds' ;; esac
case "$REPEAT_BASE" in '' | *[!0-9]*) fail 'FM_REAP_REPEAT_BASE_SECS must be whole seconds' ;; esac
case "$REPEAT_CAP" in '' | *[!0-9]*) fail 'FM_REAP_REPEAT_CAP_SECS must be whole seconds' ;; esac
[ "$REPEAT_BASE" -ge 1 ] || fail 'FM_REAP_REPEAT_BASE_SECS must be at least 1'
[ "$REPEAT_CAP" -ge "$REPEAT_BASE" ] || fail 'FM_REAP_REPEAT_CAP_SECS must be at least FM_REAP_REPEAT_BASE_SECS'

mode() {
  local m=off
  [ ! -f "$CONFIG/reaper" ] || read -r m < "$CONFIG/reaper" || true
  case "$m" in off) printf off ;; enforce) printf enforce ;; *) printf shadow ;; esac
}

meta_get() { awk -F= -v k="$2" '$1 == k { v = substr($0, length(k) + 2) } END { print v }' "$1" 2>/dev/null; }

# <status-file> -> "<state> <epoch>" of the newest lifecycle line, or nothing.
lifecycle() {
  [ -f "$1" ] || return 0
  awk -v mtime="$(stat -c %Y "$1" 2>/dev/null || printf 0)" '
    { s = $1; sub(/[^a-z-].*$/, "", s) }
    s == "working" || s == "needs-decision" || s == "blocked" || s == "paused" || s == "done" || s == "failed" {
      last = s; at = mtime
      if (match($0, /\[at=[0-9]+\]/)) at = substr($0, RSTART + 4, RLENGTH - 5)
    }
    END { if (last != "") print last, at }' "$1"
}

# <task-id> -> epoch of the newest captured board round, 0 when none; rc 1
# when no board is registered for the task.
board_last() {
  local id=$1 src base newest=0 f t found=1
  for src in "$STATE"/procevent/*.source; do
    [ -f "$src" ] || continue
    [ "$(meta_get "$src" owner_task)" = "$id" ] || continue
    found=0
    base=$(basename -- "$src" .source)
    for f in "$STATE/procevent-inbox/$base".*.result; do
      [ -f "$f" ] || continue
      t=$(stat -c %Y "$f" 2>/dev/null || printf 0)
      [ "$t" -le "$newest" ] || newest=$t
    done
  done
  printf '%s\n' "$newest"
  return "$found"
}

# <task-id> -> "gate passed, PR <ready|merged>" when the lane's milestones show
# finished, landed-or-landable work: a passed gate-end that no later gate-start or
# gate-obsolete supersedes, plus a pr-created or merge. Nothing (rc 1) otherwise,
# including when the milestone stream is unreadable or malformed.
finished_work() {
  local id=$1 recs
  recs=$("$SCRIPT_DIR/fm-task-milestones.sh" records "$STATE/$id.status" 2>/dev/null) || return 1
  printf '%s\n' "$recs" | awk -F'\t' '
    $1 == "gate-end" && $7 == "passed" && $2 > passed { passed = $2 }
    $1 == "gate-start" || $1 == "gate-obsolete" { if ($2 > restart) restart = $2 }
    $1 == "pr-created" { pr = 1 }
    $1 == "merge" { merged = 1 }
    END {
      if (passed == 0 || restart > passed || !(pr || merged)) exit 1
      printf "gate passed, PR %s", merged ? "merged" : "ready"
    }'
}

# <task-id> -> 0 when the lane's milestones record a merge; 1 otherwise,
# including an unreadable or malformed milestone stream.
merged() {
  "$SCRIPT_DIR/fm-task-milestones.sh" records "$STATE/$1.status" 2>/dev/null \
    | awk -F'\t' '$1 == "merge" { found = 1 } END { exit found ? 0 : 1 }'
}

# <task-id> -> 0 when the task's recorded worktree is clean: no staged,
# tracked, or untracked change. 1 when it is dirty, missing, or unreadable,
# which reads as not clean so the lane keeps its ordinary waits and teardown
# stays the only judge of landed work. A local git status only, no network.
worktree_clean() {
  local wt out
  wt=$(meta_get "$STATE/$1.meta" worktree)
  [ -n "$wt" ] && [ -d "$wt" ] || return 1
  out=$(git -C "$wt" status --porcelain --untracked-files=all 2>/dev/null) || return 1
  [ -z "$out" ]
}

# One line per recorded crewmate/scout: <id> <verdict> <detail>.
verdicts() {
  local meta id kind lc state at now board last clock ttl age
  now=$(date +%s)
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=$(basename -- "$meta" .meta)
    kind=$(meta_get "$meta" kind)
    case "${kind:-ship}" in ship | scout) ;; *) continue ;; esac
    lc=$(lifecycle "$STATE/$id.status")
    state=${lc%% *}
    at=${lc##* }
    if [ "$state" != "done" ]; then
      case "$state" in working | paused) ;; *)
        printf '%s active %s\n' "$id" "${state:-no-status}"
        continue
        ;;
      esac
      # Not done, but finished: gate passed and PR ready or merged, then quiet.
      if work=$(finished_work "$id"); then
        clock=$(stat -c %Y "$STATE/$id.status" 2>/dev/null || printf 0)
        [ "$clock" -ge "$at" ] || clock=$at
        ttl=$IDLE_SECS
        if last=$(board_last "$id"); then
          ttl=$BOARD_SECS
          [ "$last" -le "$clock" ] || clock=$last
          board=" board"
        else
          board=
        fi
        age=$(( now - clock ))
        if [ "$age" -ge "$ttl" ]; then
          printf '%s due %s, idle %sh%s\n' "$id" "$work" "$(( age / 3600 ))" "$board"
          continue
        fi
        if [ -z "$board" ] && merged "$id" && worktree_clean "$id"; then
          printf '%s due gate passed, PR merged, worktree clean\n' "$id"
          continue
        fi
      fi
      printf '%s active %s\n' "$id" "${state:-no-status}"
      continue
    fi
    clock=$at
    ttl=$DONE_SECS
    if last=$(board_last "$id"); then
      ttl=$BOARD_SECS
      [ "$last" -le "$clock" ] || clock=$last
      board=" board"
    else
      board=
    fi
    age=$(( now - clock ))
    if [ "$age" -ge "$ttl" ]; then
      printf '%s due done %sh ago%s\n' "$id" "$(( age / 3600 ))" "$board"
    elif [ -z "$board" ] && merged "$id" && worktree_clean "$id"; then
      printf '%s due done %sm ago, PR merged, worktree clean\n' "$id" "$(( age / 60 ))"
    else
      printf '%s waiting done %sm ago%s, closes in %sm\n' "$id" "$(( age / 60 ))" "$board" "$(( (ttl - age + 59) / 60 ))"
    fi
  done
}

cmd_run() {
  local lock="$STATE/.reaper-run.lock" id rest out
  mkdir "$lock" 2>/dev/null || { printf 'reap: a run is already in progress\n'; return 0; }
  # shellcheck disable=SC2064 # expand the lock path now
  trap "rmdir -- $(printf '%q' "$lock") 2>/dev/null" EXIT
  while read -r id rest; do
    case "$rest" in due*) ;; *) continue ;; esac
    if out=$(FM_HOME="$FM_HOME" "$TEARDOWN" "$id" < /dev/null 2>&1); then
      printf 'closed %s (%s)\n' "$id" "${rest#due }"
    else
      printf 'kept %s: %s\n' "$id" "$(printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | tail -n 1 | cut -c1-200)"
    fi
  done < <(verdicts)
}

# Filter a settled run log using the enforce-report schedule in the header.
# Compare the complete line as well as its checksum so collisions cannot hide
# a changed reason. Invalid state fails open; atomic replacement prevents a
# partial ledger from being mistaken for a successful report.
report_repeat_lines() {  # <run-log>
  local now hash last repeats delay k row newkeep='' allowed='' line ledger rhash rlast rrep rline staged
  now=$(date +%s) || { command cat -- "$1"; return 0; }
  ledger=$(command cat "$STATE/.reaper-repeat" 2>/dev/null) || ledger=
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in 'kept '*) ;; *)
      allowed="${allowed:+$allowed$'\n'}$line"
      continue
      ;;
    esac
    hash=$(printf '%s' "$line" | cksum)
    hash=${hash%% *}
    last=0 repeats=0
    while IFS=' ' read -r rhash rlast rrep rline; do
      [ -n "${rhash:-}" ] || continue
      [ "$rhash" = "$hash" ] && [ "$rline" = "$line" ] || continue
      case "$rlast" in '' | *[!0-9]* | ???????????*) continue ;; esac
      case "$rrep" in '' | *[!0-9]* | ??????*) continue ;; esac
      last=$((10#$rlast)) repeats=$((10#$rrep))
      break
    done <<EOF
$ledger
EOF
    row="$hash $last $repeats $line"
    if [ "$repeats" -eq 0 ] || [ "$now" -lt "$last" ]; then
      allowed="${allowed:+$allowed$'\n'}$line"
      row="$hash $now 1 $line"
    else
      # next allowed delay: base doubling per prior repeat, capped
      delay=$REPEAT_BASE k=$((repeats - 1))
      while [ "$k" -gt 0 ] && [ "$delay" -lt "$REPEAT_CAP" ]; do
        delay=$((delay * 2)) k=$((k - 1))
      done
      [ "$delay" -le "$REPEAT_CAP" ] || delay=$REPEAT_CAP
      if [ $(( now - last )) -ge "$delay" ]; then
        allowed="${allowed:+$allowed$'\n'}$line"
        row="$hash $now $((repeats + 1)) $line"
      fi
    fi
    newkeep="${newkeep:+$newkeep$'\n'}$row"
  done < "$1"
  # Best effort: a failed ledger write only means the backoff restarts.
  if staged=$(umask 077; mktemp "$STATE/.reaper-repeat.XXXXXX"); then
    if printf '%s\n' "$newkeep" > "$staged" && mv -f -- "$staged" "$STATE/.reaper-repeat"; then :
    else rm -f -- "$staged"; fi
  fi
  printf '%s' "$allowed"
}

cmd_check() {
  local due mark="$STATE/.reaper-due" log="$STATE/reaper-run.log" reported="$STATE/.reaper-reported" m out
  m=$(mode)
  [ "$m" != off ] || return 0
  due=$(verdicts | awk '$2 == "due" { $2 = ""; sub(/  /, " "); print }' | LC_ALL=C sort)
  if [ "$m" = enforce ]; then
    if [ -f "$log" ] && [ "$log" -nt "$reported" ] && [ ! -d "$STATE/.reaper-run.lock" ]; then
      if [ -s "$log" ]; then
        out=$(report_repeat_lines "$log")
        [ -z "$out" ] || printf 'reap: %s\n' "$(printf '%s\n' "$out" | paste -sd';' | sed 's/;/; /g')"
      fi
      : > "$reported"
    fi
    if [ -n "$due" ] && [ ! -d "$STATE/.reaper-run.lock" ]; then
      ( setsid "$0" run > "$log" 2>&1 < /dev/null & ) 2>/dev/null
    fi
    return 0
  fi
  if [ "$due" != "$(cat "$mark" 2>/dev/null)" ]; then
    printf '%s\n' "$due" > "$mark"
    [ -z "$due" ] || printf 'reap (shadow, nothing closed): %s finished worker(s) past their close time: %s. Close each with bin/fm-teardown.sh <id>, or write enforce to config/reaper.\n' \
      "$(printf '%s\n' "$due" | wc -l)" "$(printf '%s\n' "$due" | paste -sd';' | sed 's/;/; /g')"
  fi
}

cmd_arm() {
  local staged
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || fail 'state directory unavailable'
  staged=$(umask 077; mktemp "$STATE/.reaper-check.XXXXXX") || fail 'could not stage the check'
  printf '%s\n' '#!/usr/bin/env bash' \
    "export FM_HOME=$(printf '%q' "$FM_HOME")" \
    "export FM_STATE_OVERRIDE=$(printf '%q' "$STATE")" \
    "export FM_DATA_OVERRIDE=$(printf '%q' "$DATA")" \
    "export FM_CONFIG_OVERRIDE=$(printf '%q' "$CONFIG")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-reap.sh") check" > "$staged"
  chmod 700 "$staged"
  mv -f -- "$staged" "$STATE/reaper.check.sh" || fail 'could not write state/reaper.check.sh'
  "$SCRIPT_DIR/fm-check-register.sh" reaper
}

# True when <path> is provably at least <min-age> seconds old. fm_path_age reads
# an unreadable path as very old, so this reads the mtime itself and fails closed.
sweep_old_enough() {  # <path> <min-age>
  local mtime
  mtime=$(fm_path_mtime "$1") || return 1
  case "$mtime" in '' | *[!0-9]*) return 1 ;; esac
  [ $(( SWEEP_NOW - mtime )) -ge "$2" ]
}

# Every record's endpoint names, in marker-key form, between spaces. Reading
# every backend's endpoint field keeps this a superset of the watcher's windows.
sweep_recorded_keys() {
  local meta field value
  for meta in "$STATE"/*.meta "$STATE"/*.meta-prior; do
    [ -e "$meta" ] || [ -L "$meta" ] || continue
    [ -f "$meta" ] && [ -r "$meta" ] || fail "unreadable task record $meta; nothing changed"
    for field in window terminal t3_thread_id; do
      value=$(meta_get "$meta" "$field")
      [ -z "$value" ] || printf ' %s ' "$(printf '%s' "$value" | tr ':/.' '___')"
    done
  done
}

# The names every top-level state symlink targets, between spaces. A lock link or
# steal link naming an owner keeps it; fm_lock_reap_dead_link owns that takeover.
sweep_linked_names() {
  local entry target
  for entry in "$STATE"/.* "$STATE"/*; do
    [ -L "$entry" ] || continue
    target=$(readlink "$entry") || continue
    printf ' %s ' "${target##*/}"
  done
}

# True when an owner directory holds only what its lock protocol writes, and each
# stray link names a target that is gone. Anything else is not provably ours.
sweep_owner_contents_known() {  # <owner-dir>
  local owner=$1 entry name
  for entry in "$owner"/* "$owner"/.[!.]* "$owner"/..?*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    name=${entry##*/}
    if [ -L "$entry" ]; then
      case "$name" in *.owner.*) ;; *) return 1 ;; esac
      [ ! -e "$entry" ] || return 1
      continue
    fi
    [ -f "$entry" ] || return 1
    case "$name" in
      pid | pid.tmp.* | fm-home | pid-identity | pid-start | role | watcher-path) ;;
      *) return 1 ;;
    esac
  done
}

# <owner-dir> -> "<removable|kept> <kind>".
sweep_owner_verdict() {
  local owner=$1 name=${1##*/} pid
  case "$name" in *.reaped.*) printf 'kept lock-owner-reap-election\n'; return ;; esac
  case "$SWEEP_LINKED" in *" $name "*) printf 'kept lock-owner-linked\n'; return ;; esac
  if ! sweep_old_enough "$owner" "$SWEEP_LOCK_AGE"; then
    printf 'kept lock-owner-young\n'
    return
  fi
  if ! sweep_owner_contents_known "$owner"; then
    printf 'kept lock-owner-unknown-contents\n'
    return
  fi
  if [ ! -e "$owner/pid" ]; then
    printf 'removable lock-owner-released\n'
    return
  fi
  pid=$(cat "$owner/pid" 2>/dev/null) || pid=
  case "$pid" in
    '' | *[!0-9]*) printf 'kept lock-owner-unknown-contents\n' ;;
    *)
      if fm_lock_holder_alive "$owner" "$pid"; then
        printf 'kept lock-owner-live-pid\n'
      else
        printf 'removable lock-owner-dead-pid\n'
      fi
      ;;
  esac
}

# Longest prefix first, so .stale-since-<key> never reads as .stale-<since-key>.
sweep_window_key() {  # <marker-name>
  local family
  for family in wedge-terminal-queued wedge-rollback-failed model-stream-episode \
    wedge-escalations validating-resurfaced paused-resurfaced paused-rechecked \
    writing-resurfaced waiting-resurfaced wedge-permanent validating-since \
    guard-deferrals dead-reported writing-since churn-since stale-since \
    paused stale count hash; do
    case "$1" in
      ".$family-"?*) printf '%s' "${1#".$family-"}"; return 0 ;;
    esac
  done
  return 1
}

sweep_marker_verdict() {  # <path> <key>
  case "$SWEEP_RECORDED" in *" $2 "*) printf 'kept window-marker-recorded-task\n'; return ;; esac
  case "$SWEEP_QUEUE" in *"$2"*) printf 'kept window-marker-queued-wake\n'; return ;; esac
  if sweep_old_enough "$1" "$SWEEP_MARKER_AGE"; then
    printf 'removable window-marker\n'
  else
    printf 'kept window-marker-young\n'
  fi
}

# One line per candidate: <removable|kept> <kind> <path>.
sweep_candidates() {
  local entry name key
  for entry in "$STATE"/.*.lock.owner.* "$STATE"/.*.lock.steal.owner.* "$STATE"/*.lock.owner.* "$STATE"/*.lock.steal.owner.*; do
    [ -d "$entry" ] && [ ! -L "$entry" ] || continue
    printf '%s %s\n' "$(sweep_owner_verdict "$entry")" "$entry"
  done
  for entry in "$STATE"/.*; do
    [ -f "$entry" ] && [ ! -L "$entry" ] || continue
    name=${entry##*/}
    case "$name" in
      .home-summary.json.?????? | .home-summary-error.??????)
        if sweep_old_enough "$entry" "$SWEEP_MARKER_AGE"; then
          printf 'removable home-summary-temp %s\n' "$entry"
        else
          printf 'kept home-summary-temp-young %s\n' "$entry"
        fi
        continue
        ;;
    esac
    key=$(sweep_window_key "$name") || continue
    printf '%s %s\n' "$(sweep_marker_verdict "$entry" "$key")" "$entry"
  done
}

sweep_remove() {  # <kind> <path>
  local link
  case "$1" in
    lock-owner-*)
      for link in "$2"/.*.owner.* "$2"/*.owner.*; do
        [ ! -L "$link" ] || rm -f -- "$link" || return 1
      done
      fm_lock_clean_known_files "$2"
      rmdir -- "$2" 2>/dev/null
      ;;
    *) rm -f -- "$2" ;;
  esac
}

cmd_sweep_state() {
  local apply=0 verbose=0 arg verdict kind path
  for arg in "$@"; do
    case "$arg" in
      --apply) apply=1 ;;
      --verbose) verbose=1 ;;
      *) fail "sweep-state: unknown argument $arg; nothing changed" ;;
    esac
  done
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || fail 'state directory unavailable'
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  SWEEP_NOW=$(date +%s)
  SWEEP_RECORDED=$(sweep_recorded_keys) || exit 2
  SWEEP_LINKED=$(sweep_linked_names)
  SWEEP_QUEUE=
  if [ -e "$STATE/.wake-queue" ] || [ -L "$STATE/.wake-queue" ]; then
    SWEEP_QUEUE=$(tr ':/.' '___' < "$STATE/.wake-queue") || fail 'unreadable state/.wake-queue; nothing changed'
  fi
  printf 'sweep-state: %s state=%s lock-age=%ss marker-age=%ss\n' \
    "$([ "$apply" -eq 1 ] && printf apply || printf dry-run)" "$STATE" "$SWEEP_LOCK_AGE" "$SWEEP_MARKER_AGE"
  while read -r verdict kind path; do
    if [ "$verdict" = removable ]; then
      verdict=would-remove
      if [ "$apply" -eq 1 ]; then
        if sweep_remove "$kind" "$path"; then verdict=removed; else verdict=failed; fi
      fi
    fi
    printf '%s %s %s\n' "$verdict" "$kind" "$path"
  done < <(sweep_candidates) | awk -v verbose="$verbose" '
    verbose { print }
    { n[$1 " " $2]++; t[$1]++ }
    END {
      fflush()
      cmd = "LC_ALL=C sort"
      for (k in n) print k, n[k] | cmd
      close(cmd)
      printf "total would-remove=%d removed=%d failed=%d kept=%d\n", t["would-remove"], t["removed"], t["failed"], t["kept"]
      exit t["failed"] > 0
    }'
}

case "${1:-}" in
  list) verdicts ;;
  check) cmd_check ;;
  run) cmd_run ;;
  arm) cmd_arm ;;
  sweep-state) shift; cmd_sweep_state "$@" ;;
  -h | --help) usage ;;
  *) usage >&2; exit 2 ;;
esac
