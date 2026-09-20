#!/usr/bin/env bash
# tests/idle-compact-helpers.sh - shared fixtures for the idle-compact test
# suite, split across tests/fm-idle-compact-*.test.sh (bin/fm-idle-compact.sh)
# because the single combined file's extended-analysis ShellCheck pass could
# take minutes under memory/CPU contention. Generic reporters/assertions come
# from lib.sh, pulled in below by each consuming file (not here, to match this
# repo's existing shared-fixture convention - see tests/wake-helpers.sh).

new_dir() {  # <name> -> echoes a fresh <TMP_ROOT>/<name>/state dir (created)
  local d="$TMP_ROOT/$1"
  mkdir -p "$d/state" "$d/config" "$d/data"
  printf '%s' "$d"
}

write_task_meta() {  # <state> <task> [harness] [kind] [window]
  local state=$1 task=$2 harness=${3:-claude} kind=${4:-ship} window=${5:-}
  window=${window:-fake:w-$task}
  fm_write_meta "$state/$task.meta" \
    "window=$window" \
    "backend=tmux" \
    "harness=$harness" \
    "kind=$kind"
}

# Appends <line> to the task's status log and backdates the file <seconds-ago>.
# The spawn record is backdated with it: fm-spawn.sh writes state/<id>.meta once,
# at spawn, so in production a crew's own status appends always come LATER, and
# the idle-duration basis (newest of meta/status/turn-ended) would otherwise read
# a fixture's just-written meta as activity a real fleet never has.
touch_status() {  # <state> <task> <seconds-ago> [line]
  local state=$1 task=$2 ago=$3 line=${4:-done: fixture} f now
  f="$state/$task.status"
  printf '%s\n' "$line" > "$f"
  now=$(date +%s)
  touch -d "@$((now - ago))" "$f"
  [ -e "$state/$task.meta" ] && touch -d "@$((now - ago))" "$state/$task.meta"
  return 0
}

# Backdates an existing file by <seconds-ago>, for aging a marker/turn-ended
# fixture the same way touch_status ages a status log.
backdate() {  # <file> <seconds-ago>
  local now
  now=$(date +%s)
  touch -d "@$(( now - $2 ))" "$1"
}

# write_crew_state_stub <dir> <line> -> echoes an executable path that always
# prints <line> to stdout, ignoring its arguments/environment. Used as
# FM_IDLE_COMPACT_CREW_STATE_BIN, which fm_idle_compact_eligible reads at
# CALL time (a plain global, not fixed at source time), so reassigning it
# per test is sufficient - no need to re-source the library.
write_crew_state_stub() {  # <dir> <line>
  local dir=$1 line=$2 f outfile
  f="$dir/fake-crew-state.sh"
  outfile="$dir/fake-crew-state.out"
  printf '%s\n' "$line" > "$outfile"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'cat %s\n' "$(printf '%q' "$outfile")"
  } > "$f"
  chmod +x "$f"
  printf '%s' "$f"
}

# fm_busy_classify/fm_backend_composer_state are stubbed idle+empty (safe
# throughout) unless a test says otherwise; fm_idle_compact_send is stubbed
# to record calls to a log file, decoupling the state machine from
# bin/fm-send.sh's own real delivery mechanics (separately owned/tested).
stub_always_safe() {
  # shellcheck disable=SC2329  # invoked indirectly by the state-machine functions under test
  fm_busy_classify() { printf 'idle claude-hook'; }
  # shellcheck disable=SC2329  # invoked indirectly by the state-machine functions under test
  fm_backend_composer_state() { printf 'empty'; }
}

stub_recording_send() {  # <logfile>
  local log=$1
  # shellcheck disable=SC2317  # invoked indirectly by the state-machine functions under test
  fm_idle_compact_send() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$log"; return 0; }
}

# Arranges a phase=done marker whose signatures match reality (so the episode is
# a no-op) over a status log that still declares the compaction pause, aged
# <marker-age> seconds. Echoes the marker path. An optional <settle-epoch>
# reproduces the field the real settling->done transition now persists
# (fm_idle_compact_advance_settling), so a test can construct a SECOND
# episode's marker distinguishable from an earlier episode's inbox records;
# omitted, the marker carries no settle_epoch at all, matching a legacy marker.
arrange_done_declaring_pause() {  # <dir> <task> <marker-age> [settle-epoch]
  local dir=$1 task=$2 age=$3 settle_epoch=${4:-} marker
  write_task_meta "$dir/state" "$task"
  touch_status "$dir/state" "$task" 3600 \
    'paused: awaiting compaction before validation (commit 3985d693a, 1292 changed lines, over-cap accepted)'
  fm_idle_compact_task_context "$dir/state" "$task"
  marker=$(fm_idle_compact_marker_path "$dir/state" "$task")
  if [ -n "$settle_epoch" ]; then
    fm_idle_compact_marker_write "$marker" phase=done \
      "status_sig=$(fm_idle_compact_status_sig "$dir/state" "$task")" \
      "pane_sig=$(fm_idle_compact_pane_sig "$FM_IDLE_COMPACT_BACKEND" "$FM_IDLE_COMPACT_TARGET" "$FM_IDLE_COMPACT_LABEL")" \
      "settle_epoch=$settle_epoch"
  else
    fm_idle_compact_marker_write "$marker" phase=done \
      "status_sig=$(fm_idle_compact_status_sig "$dir/state" "$task")" \
      "pane_sig=$(fm_idle_compact_pane_sig "$FM_IDLE_COMPACT_BACKEND" "$FM_IDLE_COMPACT_TARGET" "$FM_IDLE_COMPACT_LABEL")"
  fi
  backdate "$marker" "$age"
  printf '%s' "$marker"
}

# Marks <file>'s .seen-* suppressor as holding <sig>, i.e. "every byte in this
# file was already surfaced or deliberately absorbed" - the provenance state
# the absorption requires, through the production signature owner.
prime_seen() {  # <state> <file> <sig>
  printf '%s' "$3" > "$(fm_wake_signal_seen_path "$1" "$2")"
}

# Sets <file>'s mtime to an exact epoch, so a fixture can order two distinct
# turn-ends without sleeping through the signature's one-second resolution.
set_mtime_epoch() {  # <file> <epoch>
  touch -d "@$2" "$1"
}

# An in-flight save-sent episode whose induced save turn has just completed.
# Echoes the marker path.
arm_induced_turn() {  # <state> <task> <turn-ended-epoch>
  local state=$1 task=$2 epoch=$3 marker
  marker=$(fm_idle_compact_marker_path "$state" "$task")
  fm_idle_compact_marker_write "$marker" phase=save-sent \
    "sent_epoch=$(date +%s)" "baseline_turnended="
  prime_seen "$state" "$state/$task.turn-ended" ""
  : > "$state/$task.turn-ended"
  set_mtime_epoch "$state/$task.turn-ended" "$epoch"
  printf '%s' "$marker"
}
