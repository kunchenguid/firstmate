#!/usr/bin/env bash
# tests/fm-wake-drain-pass-equivalence.test.sh - the drain's cheap passes must
# print exactly what the slow ones printed. The wake drain walks every status
# file's cursor row, every unread line, every goal owner stream, and the held
# calls' deadline defaults on each wake; on a large fleet those walks took most
# of a minute, so each was made incremental: the status-presentation manifest is
# parsed once per loop owner and compared byte for byte on every lookup, the
# unread-surface test takes a line's verb without forking, the cursor path needs
# no dirname/basename, the goal fold greps a stream down to its goal and landing
# lines and finds a merged task by lookup. This file pins each against the
# unoptimized original, frozen below as the reference (never sourced from the
# code under test), over the shapes the originals treat specially: duplicate and
# malformed manifest rows, rows that fail only after the one asked for,
# identity and size drift, a manifest rewritten between lookups, and goal
# streams whose landing lines repeat a task. Cost bounds live next to the
# behavior: a cursor lookup must not re-read the manifest per call once primed.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-wake-drain-pass-equivalence)

# --- frozen reference: the passes as they were before they were made cheap ----
ref_cursor_offset() {  # <status-file>
  local f=$1 state task manifest data row_task offset ident backstop extra cur_ident size legacy
  [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || return 1
  state=${f%/*}
  task=${f##*/}; task=${task%.status}
  manifest="$state/.status-presentation-cursor"
  if [ -e "$manifest" ] || [ -L "$manifest" ]; then
    [ -f "$manifest" ] && [ -r "$manifest" ] && [ ! -L "$manifest" ] || return 1
    data=$(LC_ALL=C command cat "$manifest" 2>/dev/null) || return 1
    offset=
    while IFS=$(printf '\t') read -r row_task ident legacy backstop extra; do
      [ -n "$row_task" ] || continue
      [ -z "$extra" ] || return 1
      case "$legacy:$backstop" in *[!0-9:]*) return 1 ;; esac
      [ -n "$legacy" ] && [ -n "$ident" ] || return 1
      if [ "$row_task" = "$task" ]; then
        [ -z "$offset" ] || return 1
        offset=$legacy
        cur_ident=$ident
      fi
    done <<EOF
$data
EOF
    if [ -z "$offset" ]; then
      printf '0'
      return 0
    fi
    ident=$cur_ident
  else
    legacy=$(ref_cursor_path "$f")
    if [ -e "$legacy" ] || [ -L "$legacy" ]; then
      status_open_decisions_cursor_offset "$f"
      return
    fi
    offset=0
    ident=$(_fm_open_decisions_file_ident "$f") || return 1
  fi
  _fm_status_read_ident_size "$f" || return 1
  cur_ident=$_FM_STAT_IDENTITY size=${_FM_STAT_SIZE//[[:space:]]/}
  case "$size:$offset" in *[!0-9:]*) return 1 ;; esac
  if [ "$ident" != "$cur_ident" ] || [ "$offset" -gt "$size" ]; then offset=0; fi
  printf '%s' "$offset"
}

ref_backstop_offset() {  # <status-file>
  local f=$1 state task manifest data row_task ident presented row_backstop backstop extra current size
  [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || return 1
  state=${f%/*}
  task=${f##*/}; task=${task%.status}
  manifest="$state/.status-presentation-cursor"
  [ -e "$manifest" ] || { printf '0'; return 0; }
  [ -f "$manifest" ] && [ -r "$manifest" ] && [ ! -L "$manifest" ] || return 1
  data=$(LC_ALL=C command cat "$manifest" 2>/dev/null) || return 1
  backstop=0
  while IFS=$(printf '\t') read -r row_task ident presented row_backstop extra; do
    [ -n "$row_task" ] || continue
    [ -z "$extra" ] || return 1
    case "$presented:$row_backstop" in *[!0-9:]*) return 1 ;; esac
    [ -n "$presented" ] && [ -n "$ident" ] || return 1
    if [ "$row_task" = "$task" ]; then
      _fm_status_read_ident_size "$f" || return 1
      current=$_FM_STAT_IDENTITY size=${_FM_STAT_SIZE//[[:space:]]/}
      case "$size" in ''|*[!0-9]*) return 1 ;; esac
      [ "$ident" = "$current" ] || { printf '0'; return 0; }
      backstop=${row_backstop:-0}
      [ "$backstop" -le "$size" ] || backstop=0
      printf '%s' "$backstop"
      return 0
    fi
  done <<EOF
$data
EOF
  printf '0'
}

ref_unread_surface() {  # <status-line>
  local line=$1 verb key note resolve held prefix
  [ -n "$line" ] || return 1
  verb=$(status_line_verb "$line")
  [ "$verb" = note ] && return 0
  resolve=${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}
  held=${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}
  case "$verb" in
    "$resolve"|"$held") ;;
    *) return 1 ;;
  esac
  key=$(_fm_decision_key "$line") || return 1
  note=$(status_line_note "$line")
  for prefix in ${FM_CLASSIFY_RESERVED_KEY_PREFIXES:-$FM_CLASSIFY_RESERVED_KEY_PREFIXES_DEFAULT}; do
    case "$key" in
      "$prefix"*)
        _fm_decision_key_transition_allowed "$key" "$note"
        return
        ;;
    esac
  done
  return 1
}

ref_cursor_path() {  # <status-file>
  local f=$1 dir base
  dir=${FM_OPEN_DECISIONS_CURSOR_DIR:-$(dirname "$f")}
  base=$(basename "$f")
  printf '%s/.%s.open-decisions-cursor' "$dir" "${base%.status}"
}

new_state() {  # <name> -> state dir with status files a, b, c
  local d="$TMP_ROOT/$1/state"
  mkdir -p "$d"
  printf 'alpha line one\nalpha line two\n' > "$d/a.status"
  printf 'beta line one\n' > "$d/b.status"
  printf 'gamma one\ngamma two\ngamma three\n' > "$d/c.status"
  printf '%s' "$d"
}

ident_of() {  # <status-file>
  _fm_status_read_ident_size "$1" || fail "could not read identity of $1"
  printf '%s' "$_FM_STAT_IDENTITY"
}

# Compare one task's cursor and backstop lookups, new against reference.
compare_lookup() {  # <label> <state> <task>
  local label=$1 state=$2 task=$3 f n_out n_rc r_out r_rc
  f="$state/$task.status"
  n_out=$(status_presentation_cursor_offset "$f" 2>/dev/null); n_rc=$?
  r_out=$(ref_cursor_offset "$f" 2>/dev/null); r_rc=$?
  [ "$n_rc:$n_out" = "$r_rc:$r_out" ] \
    || fail "$label: cursor offset for $task is rc=$n_rc out='$n_out', the original gave rc=$r_rc out='$r_out'"
  n_out=$(status_outcome_backstop_cursor_offset "$f" 2>/dev/null); n_rc=$?
  r_out=$(ref_backstop_offset "$f" 2>/dev/null); r_rc=$?
  [ "$n_rc:$n_out" = "$r_rc:$r_out" ] \
    || fail "$label: backstop offset for $task is rc=$n_rc out='$n_out', the original gave rc=$r_rc out='$r_out'"
}

# Every task, cold and then with the manifest primed in this shell.
compare_all() {  # <label> <state>
  local label=$1 state=$2 task
  for task in a b c missing; do
    [ -e "$state/$task.status" ] || printf 'delta\n' > "$state/$task.status"
    compare_lookup "$label (cold)" "$state" "$task"
  done
  _fm_cursor_manifest_prime "$state"
  for task in a b c missing; do
    compare_lookup "$label (primed)" "$state" "$task"
  done
}

test_cursor_lookups_match_the_original_over_manifest_shapes() {
  local state ida idb idc n
  state=$(new_state manifest-shapes)
  ida=$(ident_of "$state/a.status"); idb=$(ident_of "$state/b.status"); idc=$(ident_of "$state/c.status")

  # Name each manifest shape once; the same files back every shape.
  write_manifest() { printf '%b' "$1" > "$state/.status-presentation-cursor"; }
  n=0
  while IFS= read -r shape; do
    n=$((n + 1))
    case "$shape" in
      valid) write_manifest "a\t$ida\t5\t0\nb\t$idb\t3\t2\nc\t$idc\t0\t0\n" ;;
      beyond-size) write_manifest "a\t$ida\t9999\t8888\nb\t$idb\t3\t9999\nc\t$idc\t10\t0\n" ;;
      identity-drift) write_manifest "a\tstrong:0:0:other\t5\t3\nb\t$idb\t3\t1\nc\tweak:1:1\t2\t1\n" ;;
      duplicate-row) write_manifest "a\t$ida\t5\t1\nb\t$idb\t3\t0\na\t$ida\t7\t2\n" ;;
      malformed-before) write_manifest "x\t$ida\tnope\t0\na\t$ida\t5\t1\nb\t$idb\t3\t0\n" ;;
      malformed-after) write_manifest "a\t$ida\t5\t1\nb\t$idb\t3\t0\nx\t$ida\tnope\t0\n" ;;
      malformed-middle) write_manifest "a\t$ida\t5\t1\nx\t$idb\t3\tbad\nb\t$idb\t3\t0\nc\t$idc\t1\t1\n" ;;
      extra-field) write_manifest "a\t$ida\t5\t1\textra\nb\t$idb\t3\t0\n" ;;
      empty-backstop) write_manifest "a\t$ida\t5\t\nb\t$idb\t3\nc\t$idc\t2\t1\n" ;;
      missing-ident) write_manifest "a\t5\t1\nb\t$idb\t3\t0\n" ;;
      leading-tab) write_manifest "\ta\t$ida\t5\t1\nb\t$idb\t3\t0\n" ;;
      blank-lines) write_manifest "\n\na\t$ida\t5\t1\n\n\nb\t$idb\t3\t0\n\n" ;;
      no-trailing-newline) write_manifest "a\t$ida\t5\t1\nb\t$idb\t3\t0" ;;
      empty-file) write_manifest "" ;;
      only-newline) write_manifest "\n" ;;
      offset-leading-zero) write_manifest "a\t$ida\t007\t001\nb\t$idb\t03\t0\n" ;;
      *) fail "unknown shape $shape" ;;
    esac
    compare_all "manifest shape $shape" "$state"
  done <<'SHAPES'
valid
beyond-size
identity-drift
duplicate-row
malformed-before
malformed-after
malformed-middle
extra-field
empty-backstop
missing-ident
leading-tab
blank-lines
no-trailing-newline
empty-file
only-newline
offset-leading-zero
SHAPES
  [ "$n" -eq 16 ] || fail "shape loop ran $n times"

  # No manifest at all: the legacy per-task cursor path, and an unreadable one.
  rm -f "$state/.status-presentation-cursor"
  compare_all "no manifest" "$state"
  mkdir "$state/.status-presentation-cursor"
  compare_all "manifest is a directory" "$state"
  rmdir "$state/.status-presentation-cursor"
  ln -s "$state/a.status" "$state/.status-presentation-cursor"
  compare_all "manifest is a symlink" "$state"
  rm -f "$state/.status-presentation-cursor"
  pass "cursor and backstop lookups match the original for every manifest shape, cold and primed"
}

test_primed_manifest_is_never_stale() {
  local state ida idb out
  state=$(new_state stale-cache)
  ida=$(ident_of "$state/a.status"); idb=$(ident_of "$state/b.status")
  printf 'a\t%s\t5\t1\nb\t%s\t3\t0\n' "$ida" "$idb" > "$state/.status-presentation-cursor"
  _fm_cursor_manifest_prime "$state"
  out=$(status_presentation_cursor_offset "$state/a.status")
  assert_equals 5 "$out" "primed offset"
  # Rewritten in place with the same length, then replaced by rename, then
  # emptied, with no prime in between: each lookup must see the new bytes.
  printf 'a\t%s\t6\t1\nb\t%s\t3\t0\n' "$ida" "$idb" > "$state/.status-presentation-cursor"
  out=$(status_presentation_cursor_offset "$state/a.status")
  assert_equals 6 "$out" "same-length rewrite"
  printf 'a\t%s\t14\t4\nb\t%s\t3\t0\n' "$ida" "$idb" > "$state/.status-presentation-cursor.new"
  mv "$state/.status-presentation-cursor.new" "$state/.status-presentation-cursor"
  out=$(status_presentation_cursor_offset "$state/a.status")
  assert_equals 14 "$out" "renamed replacement"
  out=$(status_outcome_backstop_cursor_offset "$state/a.status")
  assert_equals 4 "$out" "backstop follows the replacement"
  : > "$state/.status-presentation-cursor"
  out=$(status_presentation_cursor_offset "$state/a.status")
  assert_equals 0 "$out" "emptied manifest reads as no row"
  printf 'a\t%s\tnope\t1\n' "$ida" > "$state/.status-presentation-cursor"
  if status_presentation_cursor_offset "$state/a.status" >/dev/null 2>&1; then
    fail "a malformed manifest written after priming was still served from the cache"
  fi
  pass "a primed manifest is re-read whenever its bytes change"
}

test_primed_lookups_cost_less_than_re_walking_the_manifest() {
  local state ida i n=40 t0 t1 t2 new_ms ref_ms out ref_out
  state=$(new_state primed-cost)
  ida=$(ident_of "$state/a.status")
  {
    i=0
    while [ "$i" -lt 1500 ]; do
      printf 'filler-task-%s\tstrong:1:%s:t\t%s\t0\n' "$i" "$i" "$i"
      i=$((i + 1))
    done
    printf 'a\t%s\t5\t1\n' "$ida"
  } > "$state/.status-presentation-cursor"
  _fm_cursor_manifest_prime "$state"
  t0=$(date +%s%N)
  for _ in $(seq 1 "$n"); do out=$(status_presentation_cursor_offset "$state/a.status") || fail "new lookup failed"; done
  t1=$(date +%s%N)
  for _ in $(seq 1 "$n"); do ref_out=$(ref_cursor_offset "$state/a.status") || fail "reference lookup failed"; done
  t2=$(date +%s%N)
  assert_equals "$ref_out" "$out" "lookup answer over a large manifest"
  new_ms=$(( (t1 - t0) / 1000000 )); ref_ms=$(( (t2 - t1) / 1000000 ))
  [ $((new_ms * 2)) -lt "$ref_ms" ] \
    || fail "$n primed lookups took ${new_ms} ms against ${ref_ms} ms for re-walking the manifest each time; the cache saved too little"
  pass "primed lookups over a 1500-row manifest cost under half of re-walking it (${new_ms} ms against ${ref_ms} ms for $n lookups)"
}

test_cursor_path_matches_dirname_and_basename() {
  local path got want
  for path in \
    /a/b/task.status /state/task.status relative/dir/task.status task.status ./task.status \
    /task.status a//b.status /a/b/ /a/b.status/ '/with space/it.status' /a/.hidden.status \
    /a/task.with.dots.status '' / // ; do
    got=$(_fm_open_decisions_cursor_path "$path")
    want=$(ref_cursor_path "$path")
    [ "$got" = "$want" ] || fail "cursor path for '$path' is '$got', the original gave '$want'"
  done
  FM_OPEN_DECISIONS_CURSOR_DIR=/custom/dir
  got=$(_fm_open_decisions_cursor_path /a/b/task.status)
  want=$(ref_cursor_path /a/b/task.status)
  unset FM_OPEN_DECISIONS_CURSOR_DIR
  [ "$got" = "$want" ] || fail "cursor path under a cursor dir override is '$got', the original gave '$want'"
  pass "the cursor path equals dirname/basename for plain and unusual paths"
}

test_unread_surface_matches_the_original() {
  local line n=0 got want
  while IFS= read -r line; do
    n=$((n + 1))
    status_line_is_unread_surface "$line"; got=$?
    ref_unread_surface "$line"; want=$?
    [ "$got" -eq "$want" ] || fail "unread-surface verdict for '$line' is $got, the original gave $want"
  done <<'LINES'
note: plain informational line
note [key=anything]: keyed note
note [at=1794000000]: stamped note
  note: indented note
Note: capitalised verb
working [at=1794000000]: routine
done [at=1794000000]: finished
done [key=merged-task]: merged
needs-decision [key=default]: a question
blocked: stuck
paused [at=1]: waiting
resolved [key=pending-reply-1]: pending-reply-1: answered
resolved [key=pending-reply-1]: unrelated words
resolved [key=other-key]: pending-reply-1: not a reserved key
resolved: no key at all
resolved [key=imposed-hold-3]: imposed-hold-3: released
captain-held [key=pending-reply-2]: pending-reply-2: held
captain-held [key=imposed-hold-1]: no matching prefix in the note
captain-held [key=plain]: plain key
resolved [key=bad key!]: broken slug
note [corr=abc]: note behind a correlation tag
resolved [corr=abc] [key=pending-reply-9]: pending-reply-9: tagged
corr=abc note: unbracketed correlation token
working: note: colon in the note
no colon prose that mentions note
note
resolved
:
[key=pending-reply-4]: pending-reply-4: bare key
working: resolved the thing in the note body
done: see the notes in the report
blocked: captain-held earlier, still note-worthy
notes: plural word is not the verb
resolvedx [key=pending-reply-1]: pending-reply-1: near-miss verb
LINES
  [ "$n" -ge 25 ] || fail "only $n lines compared"
  status_line_is_unread_surface ''; got=$?
  ref_unread_surface ''; want=$?
  [ "$got" -eq "$want" ] || fail "empty line verdict differs"
  FM_CLASSIFY_RESOLVE_VERB=settled FM_CLASSIFY_CAPTAIN_HELD_VERB=parked
  export FM_CLASSIFY_RESOLVE_VERB FM_CLASSIFY_CAPTAIN_HELD_VERB
  for line in 'settled [key=pending-reply-1]: pending-reply-1: x' 'parked [key=imposed-hold-1]: imposed-hold-1: y' 'resolved [key=pending-reply-1]: pending-reply-1: z'; do
    status_line_is_unread_surface "$line"; got=$?
    ref_unread_surface "$line"; want=$?
    [ "$got" -eq "$want" ] || fail "overridden verb verdict for '$line' is $got, the original gave $want"
  done
  unset FM_CLASSIFY_RESOLVE_VERB FM_CLASSIFY_CAPTAIN_HELD_VERB
  pass "the unread-surface verdict equals the original for every verb shape"
}

# --- goal fold -----------------------------------------------------------------

# The goal fold's two stream-reading functions as they were: every line of the
# owner stream through both parsers, and a linear walk to find a merged task.
# shellcheck disable=SC2329 # Installed over the live ones by run_goal_fold.
ref_goal_fold_stream() {  # <state> <data> <owner> <id> <now>
  local state=$1 data=$2 owner=$3 id=$4 now=$5 path line rc
  path=$(_fm_goal_owner_stream "$state" "$data" "$owner") || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in *[![:space:]]*) ;; *) continue ;; esac
    _fm_goal_fold_goal_line "$line" "$id" "$now" "$owner"
    rc=$?
    [ "$rc" -ne 1 ] || FM_GOAL_FOLD_IGNORED=$((FM_GOAL_FOLD_IGNORED + 1))
    ref_goal_fold_landing_line "$line"
  done < "$path"
  return 0
}

# shellcheck disable=SC2329 # Installed over the live ones by run_goal_fold.
ref_goal_fold_landing_line() {  # <line>
  local line=$1 key='' at_epoch token head rest verb i
  case "$line" in *:*) head=${line%%:*} ;; *) return 0 ;; esac
  status_line_verb "$line" verb
  [ "$verb" = "done" ] || return 0
  rest=${head#done }
  while :; do
    rest=${rest#"${rest%%[![:space:]]*}"}
    [ -n "$rest" ] || break
    token=${rest%%[[:space:]]*}
    rest=${rest#"$token"}
    case "$token" in
      '[key=merged-'*)
        [ -z "$key" ] || return 0
        key=${token#'[key=merged-'}; key=${key%\]}
        ;;
    esac
  done
  [ -n "$key" ] || return 0
  fm_goal_id_valid "$key" || return 0
  _fm_status_at_epoch "$line" at_epoch || return 0
  case "$at_epoch" in ''|*[!0-9]*) return 0 ;; esac
  [ "$at_epoch" -le $((_FM_GOAL_FOLD_NOW + _FM_GOAL_MARK_FUTURE_TOLERANCE)) ] || return 0
  i=0
  while [ "$i" -lt "${#FM_GOAL_MERGED_TASKS[@]}" ]; do
    if [ "${FM_GOAL_MERGED_TASKS[$i]}" = "$key" ]; then
      [ "$at_epoch" -le "${FM_GOAL_MERGED_ATS[i]}" ] || FM_GOAL_MERGED_ATS[i]=$at_epoch
      return 0
    fi
    i=$((i + 1))
  done
  FM_GOAL_MERGED_TASKS[${#FM_GOAL_MERGED_TASKS[@]}]=$key
  FM_GOAL_MERGED_ATS[${#FM_GOAL_MERGED_ATS[@]}]=$at_epoch
  return 0
}

# Fold goal G1 over a fixture and print everything the fold derived. With <ref>
# set, the frozen stream and landing functions replace the live ones.
run_goal_fold() {  # <home> <ref|live>
  local home=$1 mode=$2
  FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    bash -c '
      . "$1/bin/fm-goal.sh"
      if [ "$3" = ref ]; then
        eval "$(declare -f ref_goal_fold_stream | sed "1s/^ref_goal_fold_stream/_fm_goal_fold_stream/")"
        eval "$(declare -f ref_goal_fold_landing_line | sed "1s/^ref_goal_fold_landing_line/_fm_goal_fold_landing_line/")"
      fi
      _fm_goal_open_record G1 "$2/state" >/dev/null 2>&1 || exit 3
      fm_goal_fold G1 "$2/state" "$2/data" 1800000000
      printf "ignored=%s last=%s/%s\n" "$FM_GOAL_FOLD_IGNORED" "$FM_GOAL_FOLD_LAST_AT" "$FM_GOAL_FOLD_LAST_OWNER"
      printf "states=%s\n" "${FM_GOAL_M_STATES[*]-}"
      printf "ats=%s\n" "${FM_GOAL_M_ATS[*]-}"
      printf "tasks=%s\n" "${FM_GOAL_M_TASKS[*]-}"
      printf "unplanned=%s\n" "${FM_GOAL_UNPLANNED_IDS[*]-}"
      printf "merged=%s\n" "${FM_GOAL_MERGED_TASKS[*]-}"
      printf "merged_at=%s\n" "${FM_GOAL_MERGED_ATS[*]-}"
    ' _ "$ROOT" "$home" "$mode" 2>&1
}

goal_home() {  # <name> -> home with an active goal G1 owning items a, b, c on terp
  local h="$TMP_ROOT/$1"
  mkdir -p "$h/state" "$h/data"
  printf '%s\n' \
    'item [id=a] [owner=terp] [task=child]: first step' \
    'item [id=b] [owner=terp] [task=my_task.v-2]: second step' \
    'item [id=c] [owner=archived] [task=old]: archived owner' > "$h/items"
  FM_ROOT_OVERRIDE="$h" FM_HOME="$h" FM_STATE_OVERRIDE="$h/state" FM_DATA_OVERRIDE="$h/data" \
    bash "$ROOT/bin/fm-goal.sh" start G1 --title 'Equivalence goal' --done-when 'identical folds' \
    --named-by 'prove the fold' --plan plan.md --items-file "$h/items" >/dev/null \
    || fail "could not start the fixture goal"
  printf '%s' "$h"
}

test_goal_fold_matches_the_original_over_a_mixed_stream() {
  local h s i live ref
  h=$(goal_home goal-mixed)
  s="$h/state/terp.status"
  {
    printf '\n   \n'
    printf 'goal [goal=G1] [item=a] [state=running] [at=1799000000]: started\n'
    printf 'goal [goal=G1] [item=b] [state=blocked] [at=1799000001]: waiting\n'
    printf 'goal [goal=G2] [item=a] [state=done] [at=1799000002]: another goal\n'
    printf 'goal [goal=G1] [item=nope] [state=running] [at=1799000003]: unplanned item\n'
    printf 'goal [goal=G1] [item=a] [state=bogus] [at=1799000004]: bad state\n'
    printf 'goal [goal=G1] [item=a]: no state, no at\n'
    printf 'goal broken line without brackets: x\n'
    printf 'goal\n'
    printf 'goalpost [goal=G1] [item=a] [state=done] [at=1799000005]: not the goal verb\n'
    printf '  goal [goal=G1] [item=a] [state=done] [at=1799000006]: indented, not the goal verb\n'
    printf 'goal\t[goal=G1] [item=a] [state=done] [at=1799000007]: tab after the verb\n'
    printf 'goal [goal=G1] [item=b] [state=running] [at=1799000008]: newer mark wins\n'
    # Landings: first, repeats with older and newer epochs, odd keys that must
    # stay distinct, and lines that only look like landings.
    printf 'done [key=merged-child] [at=1799000100]: merged child\n'
    printf 'done [key=merged-child] [at=1799000050]: older repeat\n'
    printf 'done [key=merged-child] [at=1799000200]: newer repeat\n'
    printf 'done [key=merged-a-b] [at=1799000101]: dash\n'
    printf 'done [key=merged-a_b] [at=1799000102]: underscore\n'
    printf 'done [key=merged-a.b] [at=1799000103]: dot\n'
    printf 'done [key=merged-a_2db] [at=1799000104]: escape-shaped key\n'
    printf 'done [key=merged-a_5f2db] [at=1799000105]: escape of the escape\n'
    printf 'done [key=merged-my_task.v-2] [at=1799000106]: merged b\n'
    printf 'done [key=merged-A-B] [at=1799000107]: case differs\n'
    printf 'done [key=merged-two] [key=merged-three] [at=1799000108]: two tokens\n'
    printf 'done [key=merged-no-time]: no stamp\n'
    printf 'done [key=merged-future] [at=9999999999]: far future\n'
    printf 'done [key=merged-bad/slash] [at=1799000109]: invalid id\n'
    printf 'done [key=merged-] [at=1799000110]: empty key\n'
    printf 'working [key=merged-working] [at=1799000111]: wrong verb\n'
    printf 'done: prose mentioning [key=merged-prose] [at=1799000112] after the colon\n'
    printf 'note: done [key=merged-note] [at=1799000113]\n'
    printf 'merged [key=merged-x] [at=1799000114]: not done\n'
    printf 'ordinary working line with no key\n'
    i=0
    while [ "$i" -lt 400 ]; do
      printf 'done [key=merged-bulk-%s] [at=%s]: bulk landing\n' "$i" "$((1799000300 + i))"
      printf 'working [at=%s]: filler between landings\n' "$((1799000300 + i))"
      i=$((i + 1))
    done
    printf 'done [key=merged-bulk-7] [at=1799999999]: repeat of a bulk key\n'
    printf 'goal [goal=G1] [item=a] [state=done] [at=1799999000]: last line has no newline'
  } > "$s"
  mkdir -p "$h/data/archived"
  {
    printf 'goal [goal=G1] [item=c] [state=done] [at=1799000020]: archived mark\n'
    printf 'done [key=merged-old] [at=1799000021]: archived landing\n'
  } > "$h/data/archived/status.log"
  live=$(run_goal_fold "$h" live); ref=$(run_goal_fold "$h" ref)
  [ -n "$live" ] || fail "the live fold printed nothing"
  [ "$live" = "$ref" ] || fail "the goal fold differs from the original:
live: $live
ref:  $ref"
  case "$live" in *'ignored=0 '*) fail "the fixture ignored no goal line: $live" ;; esac
  case "$live" in *merged-bulk-399*|*bulk-399*) ;; *) fail "the bulk landings were not folded: $live" ;; esac
  case "$live" in *' a_2db '*) ;; *) fail "the escape-shaped key is missing from the merged list: $live" ;; esac
  pass "the goal fold equals the original over goal marks, repeated landings, look-alike keys and an archived owner"
}

test_goal_fold_survives_reuse_between_goals() {
  local h live ref
  h=$(goal_home goal-reuse)
  {
    printf 'done [key=merged-child] [at=1799000100]: first goal landing\n'
    printf 'done [key=merged-my_task.v-2] [at=1799000101]: other\n'
  } > "$h/state/terp.status"
  # One shell folds twice: the second fold must not see the first one's tasks.
  live=$(FM_ROOT_OVERRIDE="$h" FM_HOME="$h" FM_STATE_OVERRIDE="$h/state" FM_DATA_OVERRIDE="$h/data" \
    bash -c '
      . "$1/bin/fm-goal.sh"
      _fm_goal_open_record G1 "$2/state" >/dev/null 2>&1 || exit 3
      fm_goal_fold G1 "$2/state" "$2/data" 1800000000
      printf "first=%s\n" "${FM_GOAL_MERGED_TASKS[*]-}"
      : > "$2/state/terp.status"
      printf "done [key=merged-fresh] [at=1799000200]: later\n" > "$2/state/terp.status"
      fm_goal_fold G1 "$2/state" "$2/data" 1800000000
      printf "second=%s at=%s\n" "${FM_GOAL_MERGED_TASKS[*]-}" "${FM_GOAL_MERGED_ATS[*]-}"
      printf "done [key=merged-child] [at=1799000300]: back again\n" >> "$2/state/terp.status"
      fm_goal_fold G1 "$2/state" "$2/data" 1800000000
      printf "third=%s at=%s\n" "${FM_GOAL_MERGED_TASKS[*]-}" "${FM_GOAL_MERGED_ATS[*]-}"
    ' _ "$ROOT" "$h" 2>&1) || fail "the double fold failed: $live"
  ref=$(printf '%s\n' 'first=child my_task.v-2' 'second=fresh at=1799000200' 'third=fresh child at=1799000200 1799000300')
  [ "$live" = "$ref" ] || fail "a second fold leaked state from the first:
got:  $live
want: $ref"
  pass "refolding in one shell starts from an empty merged-task set"
}

test_goal_brief_is_unchanged_and_fast_over_a_long_stream() {
  local h out start end
  h=$(goal_home goal-brief)
  {
    printf 'goal [goal=G1] [item=a] [state=running] [at=%s]: working\n' "$(date +%s)"
    i=0
    while [ "$i" -lt 1500 ]; do
      printf 'working [at=%s]: filler\ndone [key=merged-bulk-%s] [at=%s]: landing\n' "$((1799000000 + i))" "$i" "$((1799000000 + i))"
      i=$((i + 1))
    done
  } > "$h/state/terp.status"
  start=$(date +%s)
  out=$(FM_ROOT_OVERRIDE="$h" FM_HOME="$h" FM_STATE_OVERRIDE="$h/state" FM_DATA_OVERRIDE="$h/data" \
    bash "$ROOT/bin/fm-goal.sh" brief 2>&1) || fail "the goal brief failed: $out"
  end=$(date +%s)
  case "$out" in *'GOAL G1'*|*'goal G1'*|*'G1'*) ;; *) fail "the brief does not show the goal: $out" ;; esac
  case "$out" in *'GOAL DUTY'*) ;; *) fail "the brief lost its duty line: $out" ;; esac
  [ $((end - start)) -le 30 ] || fail "a 3000-line owner stream took $((end - start)) s to brief"
  pass "the goal brief over a long owner stream keeps its shape and stays cheap"
}

test_cursor_lookups_match_the_original_over_manifest_shapes
test_primed_manifest_is_never_stale
test_primed_lookups_cost_less_than_re_walking_the_manifest
test_cursor_path_matches_dirname_and_basename
test_unread_surface_matches_the_original
test_goal_fold_matches_the_original_over_a_mixed_stream
test_goal_fold_survives_reuse_between_goals
test_goal_brief_is_unchanged_and_fast_over_a_long_stream
