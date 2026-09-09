#!/usr/bin/env bash
# Behavior tests for bin/fm-project-memory.sh.
#
# The load-bearing guarantee is that scanning a source checkout leaves it byte
# for byte as it was: that directory is the captain's live working state and
# routinely holds uncommitted work, so the read-only property is asserted
# against a real repository rather than inferred from the script's source.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-project-memory)

git_q() { git -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' "$@"; }

# A home with a project clone and a separate source checkout that shares its
# history, which is the real shape: the same commit on both sides with the
# knowledge sitting outside git on one of them.
make_world() {  # <name>
  local name=$1 world="$TMP_ROOT/$1"
  mkdir -p "$world/home/config" "$world/home/data" "$world/home/projects"
  git_q init -q --bare "$world/upstream.git"
  git_q -C "$world/upstream.git" symbolic-ref HEAD refs/heads/main
  git_q init -q "$world/source"
  printf '# %s\n' "$name" >"$world/source/README.md"
  git_q -C "$world/source" add README.md
  git_q -C "$world/source" commit -qm initial
  git_q -C "$world/source" branch -M main
  git_q -C "$world/source" remote add origin "$world/upstream.git"
  git_q -C "$world/source" push -q -u origin main
  git_q clone -q "$world/upstream.git" "$world/home/projects/demo"
  printf '%s\n' "$world"
}

# Publish the source checkout's current main, so a fixture's setup commits are
# not themselves reported as work that never reached a remote.
publish() {  # <world>
  git_q -C "$1/source" push -q origin main
}

run_scan() {  # <world> [extra args...]
  local world=$1
  shift
  FM_HOME="$world/home" "$ROOT/bin/fm-project-memory.sh" scan demo "$@" 2>&1
}

# Portable mtime, the same Linux/macOS split bin/fm-supervision-lib.sh handles.
mtime_of() {  # <path>
  if [ "$(uname)" = Darwin ]; then
    /usr/bin/stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

# A fingerprint of everything the scan could plausibly disturb: every path in
# the working tree with its size, and every loose file in .git with its size and
# timestamp, so an index refresh the scan should never cause would show up here.
fingerprint() {  # <dir>
  (cd "$1" && find . -print 2>/dev/null | LC_ALL=C sort | while IFS= read -r entry; do
    if [ -f "$entry" ] && [ ! -L "$entry" ]; then
      printf '%s f %s\n' "$entry" "$(wc -c <"$entry" | tr -d ' ')"
    else
      printf '%s other\n' "$entry"
    fi
  done)
  find "$1/.git" -maxdepth 1 -type f -print 2>/dev/null | LC_ALL=C sort | while IFS= read -r entry; do
    printf '%s %s %s\n' "${entry#"$1"/}" "$(wc -c <"$entry" | tr -d ' ')" "$(mtime_of "$entry")"
  done
}

# A source-canonical home is a folder the captain works in while firstmate has
# work going there, so "is anyone in there right now" has to be answerable
# before anything writes. Two independent signals, either one enough.
# Push every mtime in a fixture well into the past, so "nothing changed
# recently" is a fact about the fixture rather than a race with how fast the
# suite runs.
age_tree() {  # <dir>
  find "$1" -exec touch -t 202001010000.00 {} + 2>/dev/null || true
}

test_activity_reports_a_folder_nobody_is_touching_as_quiet() {
  local world out rc
  world=$(make_world quiet)
  age_tree "$world/source"
  out=$(FM_HOME="$world/home" "$ROOT/bin/fm-project-memory.sh" activity --home "$world/source" --window 1 2>&1) && rc=0 || rc=$?
  expect_code 0 "$rc" "a folder nobody touched did not read as quiet"
  assert_contains "$out" "ACTIVITY: quiet" "the report did not say the folder was quiet"
  assert_contains "$out" "GIT_OPERATION: none" "the report did not clear the git signal"
  pass "fm-project-memory.sh: a folder nobody is touching reads as quiet"
}

test_activity_reports_a_recent_write_as_active() {
  local world out rc
  world=$(make_world busy)
  age_tree "$world/source"
  mkdir -p "$world/source/active/repro_weekday"
  printf 'his own test run\n' >"$world/source/active/repro_weekday/out.json"
  out=$(FM_HOME="$world/home" "$ROOT/bin/fm-project-memory.sh" activity --home "$world/source" 2>&1) && rc=0 || rc=$?
  expect_code 3 "$rc" "a folder someone just wrote in did not read as active"
  assert_contains "$out" "ACTIVITY: active" "the report did not say the folder was in use"
  assert_contains "$out" "active/repro_weekday/out.json" "the report did not name what it saw change"
  pass "fm-project-memory.sh: a recent write reads as active and names the file"
}

test_activity_reports_a_git_operation_in_flight() {
  local world out rc gitdir
  world=$(make_world inflight)
  gitdir=$(git -C "$world/source" rev-parse --absolute-git-dir)
  : >"$gitdir/index.lock"
  out=$(FM_HOME="$world/home" "$ROOT/bin/fm-project-memory.sh" activity --home "$world/source" --window 1 --git-only 2>&1) && rc=0 || rc=$?
  expect_code 3 "$rc" "a git operation in flight did not read as active"
  assert_contains "$out" "GIT_OPERATION: index-lock" "the in-flight git operation was not named"
  rm -f "$gitdir/index.lock"
  out=$(FM_HOME="$world/home" "$ROOT/bin/fm-project-memory.sh" activity --home "$world/source" --window 1 --git-only 2>&1) && rc=0 || rc=$?
  expect_code 0 "$rc" "the git-only signal stayed active after the operation ended"
  pass "fm-project-memory.sh: an in-flight git operation reads as active on its own"
}

test_scan_never_writes_to_the_source_checkout() {
  local world before after out
  world=$(make_world readonly)
  printf 'analysis\n' >"$world/source/docs-note.md"
  mkdir -p "$world/source/scratchdir"
  printf 'x\n' >"$world/source/scratchdir/thing.txt"
  printf 'edited\n' >>"$world/source/README.md"
  before=$(fingerprint "$world/source")
  out=$(run_scan "$world" --source "$world/source")
  after=$(fingerprint "$world/source")
  [ "$before" = "$after" ] || fail "scan modified the source checkout"$'\n'"$out"
  assert_absent "$world/source/.git/index.lock" "scan left an index lock in the source checkout"
  pass "fm-project-memory.sh: scan leaves the source checkout byte-identical"
}

test_scan_reports_uncommitted_knowledge_and_excluded_agent_memory() {
  local world out
  world=$(make_world findings)
  printf 'audit of 500 conversations\n' >"$world/source/AGENTS.md"
  mkdir -p "$world/source/docs"
  printf 'findings\n' >"$world/source/docs/audit.md"
  printf 'CLAUDE.md\n.claude/\nherramientas/\n' >"$world/source/.gitignore"
  git_q -C "$world/source" add .gitignore
  git_q -C "$world/source" commit -qm ignore
  publish "$world"
  printf 'the fuller operational context\n' >"$world/source/CLAUDE.md"
  mkdir -p "$world/source/.claude" "$world/source/herramientas"
  printf '{}\n' >"$world/source/.claude/settings.json"
  printf 'tool\n' >"$world/source/herramientas/replay.py"
  out=$(run_scan "$world" --source "$world/source")
  assert_contains "$out" "AGENTS.md" "uncommitted AGENTS.md was not reported"
  assert_contains "$out" "docs/" "the uncommitted knowledge directory was not reported"
  assert_contains "$out" "CLAUDE.md (excluded by" "excluded agent memory was not reported"
  assert_contains "$out" ".claude/ (excluded by" "excluded agent-memory directory was not reported"
  assert_contains "$out" "herramientas/" "ignored directory holding material was not reported"
  assert_contains "$out" "VERDICT: divergent - knowledge did not travel" "a real knowledge gap did not read as divergent"
  pass "fm-project-memory.sh: scan reports uncommitted knowledge and excluded agent memory"
}

test_scan_reports_a_clean_project_as_parity() {
  local world out
  world=$(make_world clean)
  mkdir -p "$world/source/media"
  printf 'binary-ish\n' >"$world/source/media/clip.bin"
  printf 'media/\n' >"$world/source/.gitignore"
  git_q -C "$world/source" add .gitignore
  git_q -C "$world/source" commit -qm ignore
  publish "$world"
  out=$(run_scan "$world" --source "$world/source")
  assert_contains "$out" "VERDICT: parity" "a project whose knowledge travelled did not read as parity"
  assert_contains "$out" "media/" "ignored working material was not listed for context"
  pass "fm-project-memory.sh: working material alone reads as parity, not as a gap"
}

test_scratch_is_counted_but_never_listed() {
  local world out
  world=$(make_world scratch)
  mkdir -p "$world/source/node_modules/pkg"
  printf 'x\n' >"$world/source/node_modules/pkg/index.js"
  printf 'noise\n' >"$world/source/run.log"
  out=$(run_scan "$world" --source "$world/source")
  assert_not_contains "$out" "run.log" "scratch was listed in the report"
  assert_contains "$out" "SCRATCH_IGNORED_FROM_REPORT: " "scratch was not counted"
  pass "fm-project-memory.sh: scratch is counted and never listed"
}

test_unpushed_commits_are_reported() {
  local world out
  world=$(make_world unpushed)
  printf 'more\n' >>"$world/source/README.md"
  git_q -C "$world/source" commit -qam "local only work"
  out=$(run_scan "$world" --source "$world/source")
  assert_contains "$out" "UNPUSHED_COMMITS: 1" "a commit that reached no remote was not reported"
  assert_contains "$out" "local only work" "the unpushed commit subject was not listed"
  pass "fm-project-memory.sh: commits that reached no remote are reported"
}

test_source_canonical_divergence_is_not_reported_as_a_leak() {
  local world out
  world=$(make_world canonical)
  printf 'knowledge\n' >"$world/source/notes.md"
  out=$(run_scan "$world" --source "$world/source" --canonical source)
  assert_contains "$out" "HOME_KIND: source" "the recorded knowledge home was not reported"
  assert_contains "$out" "VERDICT: source-canonical" "a source-canonical project read as an ordinary leak"
  assert_not_contains "$out" "VERDICT: divergent" "a source-canonical project was reported as divergent"
  pass "fm-project-memory.sh: a source-canonical project's divergence is not a leak"
}

test_absent_source_record_is_a_normal_reported_state() {
  local world out rc
  world=$(make_world norecord)
  out=$(run_scan "$world")
  rc=$?
  expect_code 0 "$rc" "an absent source record failed instead of reporting"
  assert_contains "$out" "SOURCE: none recorded" "an absent source record was not reported as such"
  assert_contains "$out" "VERDICT: unknown" "an absent source record did not read as unknown"
  pass "fm-project-memory.sh: an absent source record is reported, not an error"
}

test_source_record_round_trips_and_home_resolves() {
  local world out
  world=$(make_world record)
  out=$(FM_HOME="$world/home" "$ROOT/bin/fm-project-memory.sh" source set demo "$world/source" --canonical source 2>&1) ||
    fail "source set failed: $out"
  out=$(FM_HOME="$world/home" "$ROOT/bin/fm-project-memory.sh" source get demo 2>&1)
  assert_contains "$out" "canonical=source" "the recorded knowledge home did not round-trip"
  out=$(FM_HOME="$world/home" "$ROOT/bin/fm-project-memory.sh" home demo 2>&1)
  [ "$out" = "$(cd "$world/source" && pwd -P)" ] ||
    fail "home did not resolve to the canonical source checkout: $out"
  out=$(FM_HOME="$world/home" "$ROOT/bin/fm-project-memory.sh" source set demo "$world/source" 2>&1)
  out=$(FM_HOME="$world/home" "$ROOT/bin/fm-project-memory.sh" home demo 2>&1)
  [ "$out" = "$(cd "$world/home/projects/demo" && pwd -P)" ] ||
    fail "home did not fall back to the clone for a repo-canonical project: $out"
  pass "fm-project-memory.sh: the source record round-trips and home resolves both kinds"
}

test_source_set_refuses_the_homes_own_clone() {
  local world out rc
  world=$(make_world refuse)
  out=$(FM_HOME="$world/home" "$ROOT/bin/fm-project-memory.sh" source set demo "$world/home/projects/demo" 2>&1) && rc=0 || rc=$?
  expect_code 1 "$rc" "recording this home's own clone as the source checkout was accepted"
  assert_contains "$out" "own clone" "the refusal did not name the cause"
  pass "fm-project-memory.sh: this home's own clone is refused as a source checkout"
}

test_scan_is_bounded_by_limit() {
  local world out
  world=$(make_world bounded)
  mkdir -p "$world/source/docs"
  printf 'index\n' >"$world/source/docs/index.md"
  git_q -C "$world/source" add docs/index.md
  git_q -C "$world/source" commit -qm docs
  publish "$world"
  local i=0
  while [ "$i" -lt 12 ]; do
    printf 'note %s\n' "$i" >"$world/source/docs/note-$i.md"
    i=$((i + 1))
  done
  out=$(run_scan "$world" --source "$world/source" --limit 3)
  assert_contains "$out" "UNCOMMITTED_KNOWLEDGE: 12" "the complete count was not reported"
  assert_contains "$out" "... and 9 more" "the listing was not bounded by --limit"
  pass "fm-project-memory.sh: counts stay complete while listings stay bounded"
}

test_scan_never_writes_to_the_source_checkout
test_scan_reports_uncommitted_knowledge_and_excluded_agent_memory
test_scan_reports_a_clean_project_as_parity
test_scratch_is_counted_but_never_listed
test_unpushed_commits_are_reported
test_source_canonical_divergence_is_not_reported_as_a_leak
test_absent_source_record_is_a_normal_reported_state
test_source_record_round_trips_and_home_resolves
test_source_set_refuses_the_homes_own_clone
test_scan_is_bounded_by_limit
test_activity_reports_a_folder_nobody_is_touching_as_quiet
test_activity_reports_a_recent_write_as_active
test_activity_reports_a_git_operation_in_flight
