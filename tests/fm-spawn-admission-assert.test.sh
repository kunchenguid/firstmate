#!/usr/bin/env bash
# Story fmops-07 §1 / plan §2.4: bin/fm-spawn.sh belt-and-suspenders
# admission assert. A hand-planted backlog row without a [<epic>] title tag
# and without a `parent:<epic>` edge is refused at spawn time. A normal
# fork-engine-seeded row (either signal present) spawns unchanged. Secondmate
# spawns skip the check because a secondmate is not a backlog item.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-admission)

# The assert function is defined in-flight inside fm-spawn.sh. To exercise it
# in isolation without spawning a real crewmate (which requires a full harness
# and worktree), source only the function definition into this test.
extract_admission_function() {
  awk '
    /^fm_spawn_assert_admission\(\) \{/ { flag=1 }
    flag { print }
    flag && /^\}$/ { exit }
  ' "$ROOT/bin/fm-spawn.sh"
}

# Isolate the function under a fixture FM_HOME and a KIND var.
run_assert() {  # <home> <kind> <id>
  local home=$1 kind=$2 id=$3
  FM_HOME="$home" KIND="$kind" bash -c "$(extract_admission_function); fm_spawn_assert_admission \"$id\"" 2>&1
}

make_backlog() {  # <home> <line...>
  local home=$1
  shift
  mkdir -p "$home/data"
  {
    printf '## In flight\n\n## Queued\n'
    for line in "$@"; do
      printf '%s\n' "$line"
    done
    printf '\n## Done\n'
  } > "$home/data/backlog.md"
}

# --- fork-engine seed accepts -----------------------------------------------

test_parent_edge_accepted() {
  local home="$TMP_ROOT/parent-edge"
  make_backlog "$home" \
    '- [ ] fmops-07-firstmate-integration - [fmops] task (repo: firstmate) (kind: ship) (since 2026-08-24) parent: fmops'
  local rc=0
  run_assert "$home" ship fmops-07-firstmate-integration >/dev/null || rc=$?
  [ "$rc" = 0 ] || fail "parent-edge row was refused: rc=$rc"
  pass "parent:<epic> edge in the row is accepted"
}

test_title_tag_accepted() {
  local home="$TMP_ROOT/title-tag"
  make_backlog "$home" \
    '- [ ] fmops-07 - [fmops] task (repo: firstmate) (kind: ship) (since 2026-08-24)'
  local rc=0
  run_assert "$home" ship fmops-07 >/dev/null || rc=$?
  [ "$rc" = 0 ] || fail "title-tag row was refused: rc=$rc"
  pass "[<epic>] title tag is accepted"
}

test_orphan_row_refused() {
  local home="$TMP_ROOT/orphan"
  make_backlog "$home" \
    '- [ ] fmops-07 - bare title with no tag and no edge (repo: firstmate)'
  local out rc=0
  out=$(run_assert "$home" ship fmops-07) || rc=$?
  [ "$rc" -ne 0 ] || fail "orphan row was not refused"
  case "$out" in
    *"backlog orphan"*) : ;;
    *) fail "refusal message missing 'backlog orphan': $out" ;;
  esac
  pass "orphan row without [<epic>] or parent: is refused with a clear message"
}

test_secondmate_skips_check() {
  local home="$TMP_ROOT/secondmate"
  make_backlog "$home" \
    '- [ ] mate-1 - bare (repo: firstmate)'
  local rc=0
  run_assert "$home" secondmate mate-1 >/dev/null || rc=$?
  [ "$rc" = 0 ] || fail "secondmate spawn was refused for missing membership: rc=$rc"
  pass "secondmate spawn skips the admission check"
}

test_missing_backlog_is_silent() {
  local home="$TMP_ROOT/no-backlog"
  mkdir -p "$home/data"
  local rc=0
  run_assert "$home" ship anything >/dev/null || rc=$?
  [ "$rc" = 0 ] || fail "missing backlog broke the assert"
  pass "missing backlog is not this check's job to fail"
}

test_id_absent_is_silent() {
  local home="$TMP_ROOT/id-absent"
  make_backlog "$home"
  local rc=0
  run_assert "$home" ship not-listed >/dev/null || rc=$?
  [ "$rc" = 0 ] || fail "id absent from backlog broke the assert"
  pass "an id absent from the backlog is not refused here (spawn fails elsewhere)"
}

# URL brackets in the tail must not spoof a title-tag.
test_url_bracket_does_not_spoof_tag() {
  local home="$TMP_ROOT/url-bracket"
  make_backlog "$home" \
    '- [ ] fmops-07 - bare title (repo: firstmate) https://example.com/[foo]'
  local rc=0
  run_assert "$home" ship fmops-07 >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "a URL-bracket in the tail spoofed the title-tag check"
  pass "URL brackets in tail metadata do not spoof the tag check"
}

test_parent_edge_accepted
test_title_tag_accepted
test_orphan_row_refused
test_secondmate_skips_check
test_missing_backlog_is_silent
test_id_absent_is_silent
test_url_bracket_does_not_spoof_tag
