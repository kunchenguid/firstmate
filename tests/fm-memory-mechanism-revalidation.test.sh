#!/usr/bin/env bash
# Tests the mechanism-change re-validation trigger for startup memory.
#
# Memory entries are falsified by a mechanism moving, not by elapsed time. The
# stow skill's aging clock re-validates an entry 30 days after its last
# reinforcement, so an entry that goes false two days after it was admitted is
# carried forward as reinforced fact for the rest of that clock.
#
# These fixtures reconstruct two real falsifications from 2026-08-20, both
# correct when written and both overtaken inside 48 hours:
#
#   A. "the agy ladder keeps the captain's reserve protected while a worker
#      runs" - falsified by a change to the ladder enforcement path.
#   B. "an exiting agent returns its worktree to the pool, so a later relaunch
#      refuses" - falsified because the control path releases no pool slot.
#
# The test asserts three things:
#   1. The 30-day aging clock does NOT fire on either entry (both are days old,
#      not months), so the time-based tier cannot reach them.
#   2. The pre-existing coarse notice is "bin" for both, identical to any other
#      tooling change, so it cannot single out which entry is due.
#   3. The changed-FILES notice names each entry's cited path verbatim, so the
#      trigger selects exactly the two falsified entries and leaves a control
#      entry citing an unchanged file alone.
#
# It also pins the local derivation the stow skill offers a home whose notice
# names no paths: after a fast-forward, HEAD@{1} is the pre-update commit.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

UPDATE="$ROOT/bin/fm-update.sh"

# The stow skill's aging tier: an entry is stale at or beyond this many days
# since its last-reinforced date.
AGING_CLOCK_DAYS=30

fm_git_identity fmtest fmtest@example.com

TMP_ROOT=$(fm_test_tmproot fm-memory-mechanism-revalidation)

# Age in whole days of a <!--a:YYYY-MM-DD--> marker, relative to today.
marker_age_days() {
  local entry stamp
  entry=$1
  stamp=${entry#*<!--a:}
  stamp=${stamp%%-->*}
  python3 - "$stamp" <<'PY'
import datetime, sys
d = datetime.date.fromisoformat(sys.argv[1])
print((datetime.date.today() - d).days)
PY
}

today() { date +%Y-%m-%d; }

# A world whose watched instruction surface carries the two scripts the fixture
# memory entries cite, plus one the fixtures do not.
new_world() {
  local w=$1
  mkdir -p "$w/home/state" "$w/home/data"
  touch "$w/home/state/.last-watcher-beat"

  git init -q --bare "$w/origin.git"
  git -C "$w/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$w/origin.git" "$w/seed" 2>/dev/null

  printf 'v1\n' > "$w/seed/AGENTS.md"
  mkdir -p "$w/seed/bin" "$w/seed/.agents/skills"
  printf 'reserve_is_protected_while_running\n' > "$w/seed/bin/fm-agy-ladder.sh"
  printf 'exit_returns_worktree_to_pool\n' > "$w/seed/bin/fm-control.sh"
  printf 'unrelated\n' > "$w/seed/bin/fm-brief.sh"
  printf 's1\n' > "$w/seed/.agents/skills/note.md"
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm c1
  git -C "$w/seed" push -q origin main

  git clone -q "$w/origin.git" "$w/main"
  git -C "$w/main" remote set-head origin main >/dev/null 2>&1 || true

  git -C "$w/main" worktree add -q --detach "$w/sm1" main
  {
    printf 'window=main:fm-sm1\n'
    printf 'kind=secondmate\n'
    printf 'home=%s/sm1\n' "$w"
  } > "$w/home/state/sm1.meta"
  printf 'sm1\n' > "$w/sm1/.fm-secondmate-home"
}

# The mechanism moves: both cited scripts change, the third does not.
move_the_mechanism() {
  local w=$1
  git -C "$w/seed" pull -q origin main >/dev/null 2>&1 || true
  printf 'reserve_is_drained_to_zero_while_running\n' > "$w/seed/bin/fm-agy-ladder.sh"
  printf 'exit_releases_no_pool_slot\n' > "$w/seed/bin/fm-control.sh"
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm "move both mechanisms"
  git -C "$w/seed" push -q origin main
}

test_mechanism_change_trigger() {
  local w out stamp entry_a entry_b entry_c control_age files age_a age_b
  w="$TMP_ROOT/fixtures"
  mkdir -p "$w"
  new_world "$w"

  # Two falsified entries and one control, all reinforced TODAY: nothing here is
  # old, which is exactly why a time-based tier cannot reach them.
  stamp=$(today)
  entry_a="- The agy ladder keeps the captain's reserve protected while a worker runs (bin/fm-agy-ladder.sh). <!--a:$stamp-->"
  entry_b="- An exiting agent returns its worktree to the pool, so a later relaunch refuses (bin/fm-control.sh). <!--a:$stamp-->"
  entry_c="- Briefs are scaffolded, never hand-written (bin/fm-brief.sh). <!--a:$stamp-->"
  printf '%s\n%s\n%s\n' "$entry_a" "$entry_b" "$entry_c" > "$w/home/data/learnings.md"

  move_the_mechanism "$w"
  out=$(FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" "$UPDATE" 2>/dev/null)

  # 1. The 30-day aging clock does not fire on either falsified entry.
  age_a=$(marker_age_days "$entry_a")
  age_b=$(marker_age_days "$entry_b")
  if [ "$age_a" -ge "$AGING_CLOCK_DAYS" ] || [ "$age_b" -ge "$AGING_CLOCK_DAYS" ]; then
    fail "fixtures must be inside the aging clock (got ${age_a}d and ${age_b}d)"
  fi
  pass "the 30-day aging clock does not fire: fixture A is ${age_a}d old, fixture B is ${age_b}d old"

  # 2. The coarse surface notice cannot single either entry out.
  assert_contains "$out" "firstmate-changed-surface: bin" \
    "the coarse notice is just 'bin' - identical for any tooling change"
  assert_not_contains "$out" "firstmate-changed-surface: bin/fm-control.sh" \
    "the coarse notice never reaches file granularity"

  # 3. The changed-FILES notice names each falsified entry's cited path.
  files=$(printf '%s\n' "$out" | sed -n 's/^firstmate-changed-files: //p')
  [ -n "$files" ] || fail "fm-update.sh emitted no firstmate-changed-files line"
  printf 'changed-files notice: %s\n' "$files" >&2

  case ",$files," in
    *,bin/fm-agy-ladder.sh,*) ;;
    *) fail "changed-files notice omits fixture A's cited path: $files" ;;
  esac
  case ",$files," in
    *,bin/fm-control.sh,*) ;;
    *) fail "changed-files notice omits fixture B's cited path: $files" ;;
  esac
  pass "the changed-files notice names both falsified entries' cited paths"

  # The trigger is precise: the control entry cites a path that did not move.
  case ",$files," in
    *,bin/fm-brief.sh,*) fail "changed-files notice names an unchanged path: $files" ;;
  esac
  control_age=$(marker_age_days "$entry_c")
  pass "the control entry (${control_age}d old, cites bin/fm-brief.sh) is not selected"

  # The same detail reaches the secondmate nudge, which is what let a home check
  # its own holdings instead of only the entries the sender knew to mention.
  assert_contains "$out" "nudge-files fm-sm1: " "the nudge carries the changed files"
  files=$(printf '%s\n' "$out" | sed -n 's/^nudge-files fm-sm1: //p')
  case ",$files," in
    *,bin/fm-agy-ladder.sh,*) ;;
    *) fail "nudge-files omits fixture A's cited path: $files" ;;
  esac
  case ",$files," in
    *,bin/fm-control.sh,*) ;;
    *) fail "nudge-files omits fixture B's cited path: $files" ;;
  esac
  pass "the secondmate nudge carries the same checkable file list"
}

# The stow skill tells a home whose notice names no paths to derive the changed
# surface locally from HEAD@{1}. Pin that: a fast-forward leaves the pre-update
# commit there, in the secondmate's own detached-HEAD home.
test_local_derivation_from_reflog() {
  local w derived
  w="$TMP_ROOT/derivation"
  mkdir -p "$w"
  new_world "$w"
  move_the_mechanism "$w"
  FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" "$UPDATE" >/dev/null 2>&1

  derived=$(git -C "$w/sm1" diff --name-only 'HEAD@{1}' HEAD | sort | tr '\n' ',')
  [ "$derived" = "bin/fm-agy-ladder.sh,bin/fm-control.sh," ] \
    || fail "HEAD@{1} derivation returned '$derived'"
  pass "a home with an unnamed notice recovers the same surface from HEAD@{1}"
}

# The list is capped so a nudge stays one sendable line, and says so rather than
# silently truncating: the range line then recovers the full set.
test_cap_is_visible_and_recoverable() {
  local w out files range i
  w="$TMP_ROOT/cap"
  mkdir -p "$w"
  new_world "$w"
  git -C "$w/seed" pull -q origin main >/dev/null 2>&1 || true
  for i in 1 2 3 4 5; do
    printf 'moved\n' > "$w/seed/bin/fm-extra-$i.sh"
  done
  printf 'moved\n' > "$w/seed/bin/fm-control.sh"
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm "move six files"
  git -C "$w/seed" push -q origin main

  out=$(FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" FM_FF_CHANGED_FILES_CAP=3 "$UPDATE" 2>/dev/null)
  files=$(printf '%s\n' "$out" | sed -n 's/^firstmate-changed-files: //p')
  range=$(printf '%s\n' "$out" | sed -n 's/^firstmate-changed-range: //p')
  printf 'capped notice: %s (range %s)\n' "$files" "$range" >&2
  case "$files" in
    *,+3-more) ;;
    *) fail "capped list must end in a +N-more element, got: $files" ;;
  esac
  case "$range" in
    *..*) ;;
    *) fail "a truncated list must report a range that recovers it, got: $range" ;;
  esac
  pass "a truncated list says how many it dropped and reports the range that recovers them"
}

test_mechanism_change_trigger
test_local_derivation_from_reflog
test_cap_is_visible_and_recoverable

echo "# all fm-memory-mechanism-revalidation tests passed"
