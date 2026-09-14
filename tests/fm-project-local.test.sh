#!/usr/bin/env bash
# Behavior tests for bin/fm-project-local.sh.
#
# The point of the store is that material a worker must read never becomes a
# commit, so the assertions drive real git: material is staged into a real
# worktree and then `git add -A` has to leave nothing staged. An instruction in
# a brief cannot be tested; this can.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-project-local)

git_q() { git -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' "$@"; }

make_world() {  # <name>
  local name=$1 world="$TMP_ROOT/$1"
  mkdir -p "$world/home/data" "$world/material-src"
  git_q init -q "$world/copy"
  printf '# %s\n' "$name" >"$world/copy/README.md"
  git_q -C "$world/copy" add README.md
  git_q -C "$world/copy" commit -qm initial
  printf '%s\n' "$world"
}

local_cmd() {  # <world> <args...>
  local world=$1
  shift
  FM_HOME="$world/home" "$ROOT/bin/fm-project-local.sh" "$@" 2>&1
}

# Push every mtime in a fixture well into the past, so "nothing changed
# recently" is a fact about the fixture rather than a race with the suite.
age_tree() {  # <dir>
  find "$1" -exec touch -t 202001010000.00 {} + 2>/dev/null || true
}

# The canonical home is shared: the captain works in it while a sync reads it,
# so a file can be caught mid-write. The sync still succeeds - the store is a
# private cache and re-running is free - but it must say so.
test_sync_reports_a_home_that_was_being_worked_while_it_was_read() {
  local world out
  world=$(make_world concurrent)
  mkdir -p "$world/home/config/project-sources" "$world/home/data/project-local/demo"
  git_q init -q "$world/canonical"
  printf 'x\n' >"$world/canonical/README.md"
  git_q -C "$world/canonical" add README.md
  git_q -C "$world/canonical" commit -qm initial
  printf 'operational context\n' >"$world/canonical/CLAUDE.md"
  FM_HOME="$world/home" "$ROOT/bin/fm-project-memory.sh" source set demo "$world/canonical" --canonical source >/dev/null ||
    fail "source set failed"
  printf 'CLAUDE.md\n' >"$world/home/data/project-local/demo/manifest"

  out=$(local_cmd "$world" sync demo) || fail "sync failed while the home was in use: $out"
  assert_contains "$out" "synced:" "the sync did not complete"
  assert_contains "$out" "was being worked in while this copy was taken" \
    "the sync said nothing about reading a folder someone was writing"

  age_tree "$world/canonical"
  out=$(local_cmd "$world" sync demo) || fail "sync failed on a quiet home: $out"
  assert_not_contains "$out" "was being worked in while this copy was taken" \
    "a quiet home still produced a concurrency warning"
  pass "fm-project-local.sh: sync reports a home that was being worked while it was read"
}

# A failed activity check is not an observation. When the check itself cannot
# run, sync says the answer is unknown rather than claiming it saw someone
# working in the folder.
test_sync_says_when_activity_could_not_be_determined() {
  local world out
  world=$(make_world undetermined)
  mkdir -p "$world/home/config/project-sources" "$world/home/data/project-local/demo"
  git_q init -q "$world/canonical"
  printf 'x\n' >"$world/canonical/README.md"
  git_q -C "$world/canonical" add README.md
  git_q -C "$world/canonical" commit -qm initial
  printf 'operational context\n' >"$world/canonical/CLAUDE.md"
  FM_HOME="$world/home" "$ROOT/bin/fm-project-memory.sh" source set demo "$world/canonical" --canonical source >/dev/null ||
    fail "source set failed"
  printf 'CLAUDE.md\n' >"$world/home/data/project-local/demo/manifest"
  age_tree "$world/canonical"

  # The activity check needs a scratch file; a scratch directory that does not
  # exist makes it fail outright without touching the sync's own copying.
  out=$(FM_HOME="$world/home" TMPDIR="$world/no-such-dir" "$ROOT/bin/fm-project-local.sh" sync demo 2>&1) ||
    fail "sync failed when the activity check could not run: $out"
  assert_contains "$out" "synced:" "the sync did not complete"
  assert_contains "$out" "could not determine whether" "a failed activity check was not reported as unknown"
  assert_not_contains "$out" "was being worked in while this copy was taken" \
    "a failed activity check was reported as activity observed"
  pass "fm-project-local.sh: sync says when activity could not be determined"
}

test_staged_material_is_readable_and_cannot_be_committed() {
  local world out staged
  world=$(make_world stage)
  printf 'the fuller operational context\n' >"$world/material-src/CLAUDE.md"
  mkdir -p "$world/material-src/notes"
  printf 'a finding nobody committed\n' >"$world/material-src/notes/audit.md"
  # A README the captain never committed is ordinary knowledge material, so the
  # staged copy has to carry his file rather than anything of firstmate's own.
  printf 'CLIENT NOTES that must reach the worker\n' >"$world/material-src/README.md"
  local_cmd "$world" add demo "$world/material-src/CLAUDE.md" >/dev/null || fail "add failed"
  local_cmd "$world" add demo "$world/material-src/README.md" >/dev/null || fail "add of a README failed"
  local_cmd "$world" add demo "$world/material-src/notes" >/dev/null || fail "add of a directory failed"
  out=$(local_cmd "$world" stage demo "$world/copy") || fail "stage failed: $out"

  staged="$world/copy/.fm-local"
  assert_present "$staged/CLAUDE.md" "staged material is missing from the task copy"
  assert_present "$staged/notes/audit.md" "staged directory material is missing from the task copy"
  assert_grep "the fuller operational context" "$staged/CLAUDE.md" "staged material is not readable"
  assert_grep "CLIENT NOTES that must reach the worker" "$staged/README.md" \
    "the staged copy lost the captain's own README"

  out=$(git_q -C "$world/copy" status --porcelain --untracked-files=all)
  [ -z "$out" ] || fail "git can see the staged material: $out"
  git_q -C "$world/copy" add -A
  out=$(git_q -C "$world/copy" diff --cached --name-only)
  [ -z "$out" ] || fail "git add -A staged local material for commit: $out"
  pass "fm-project-local.sh: staged material is readable and invisible to git"
}

test_stage_refuses_when_the_project_tracks_the_destination() {
  local world out rc
  world=$(make_world tracked)
  mkdir -p "$world/copy/.fm-local"
  printf 'committed\n' >"$world/copy/.fm-local/real.txt"
  git_q -C "$world/copy" add -f .fm-local/real.txt
  git_q -C "$world/copy" commit -qm "project tracks the path"
  printf 'material\n' >"$world/material-src/note.md"
  local_cmd "$world" add demo "$world/material-src/note.md" >/dev/null || fail "add failed"
  out=$(local_cmd "$world" stage demo "$world/copy") && rc=0 || rc=$?
  expect_code 1 "$rc" "staging over a tracked path was accepted"
  assert_contains "$out" "tracks" "the refusal did not name the tracked path"
  assert_grep "committed" "$world/copy/.fm-local/real.txt" "the refused stage clobbered the project's own file"
  pass "fm-project-local.sh: staging over a tracked path is refused"
}

test_an_empty_store_stages_nothing() {
  local world out
  world=$(make_world empty)
  out=$(local_cmd "$world" stage demo "$world/copy") || fail "staging an empty store failed: $out"
  assert_absent "$world/copy/.fm-local" "an empty store still created a staged directory"
  pass "fm-project-local.sh: an empty store stages nothing and succeeds"
}

test_sync_pulls_the_manifest_from_the_canonical_home_without_writing_to_it() {
  local world out before after
  world=$(make_world sync)
  mkdir -p "$world/home/config/project-sources" "$world/home/projects"
  git_q init -q "$world/canonical"
  printf 'x\n' >"$world/canonical/README.md"
  git_q -C "$world/canonical" add README.md
  git_q -C "$world/canonical" commit -qm initial
  printf 'operational context\n' >"$world/canonical/CLAUDE.md"
  mkdir -p "$world/canonical/herramientas"
  printf 'tool\n' >"$world/canonical/herramientas/replay.py"
  FM_HOME="$world/home" "$ROOT/bin/fm-project-memory.sh" source set demo "$world/canonical" --canonical source >/dev/null ||
    fail "source set failed"
  mkdir -p "$world/home/data/project-local/demo"
  printf '# what the workers need\nCLAUDE.md\nherramientas\n' >"$world/home/data/project-local/demo/manifest"

  before=$(cd "$world/canonical" && find . -print | LC_ALL=C sort)
  out=$(local_cmd "$world" sync demo) || fail "sync failed: $out"
  after=$(cd "$world/canonical" && find . -print | LC_ALL=C sort)
  [ "$before" = "$after" ] || fail "sync modified the canonical home"

  out=$(local_cmd "$world" list demo)
  assert_contains "$out" "CLAUDE.md" "sync did not pull the manifest file"
  assert_contains "$out" "herramientas/replay.py" "sync did not pull the manifest directory"
  pass "fm-project-local.sh: sync pulls the manifest and leaves the canonical home alone"
}

test_sync_refuses_an_escaping_manifest_path() {
  local world out rc
  world=$(make_world escape)
  mkdir -p "$world/home/config/project-sources" "$world/home/data/project-local/demo"
  git_q init -q "$world/canonical"
  printf 'x\n' >"$world/canonical/README.md"
  git_q -C "$world/canonical" add README.md
  git_q -C "$world/canonical" commit -qm initial
  FM_HOME="$world/home" "$ROOT/bin/fm-project-memory.sh" source set demo "$world/canonical" --canonical source >/dev/null ||
    fail "source set failed"
  printf '../outside.md\n' >"$world/home/data/project-local/demo/manifest"
  out=$(local_cmd "$world" sync demo) && rc=0 || rc=$?
  expect_code 1 "$rc" "a manifest path escaping the project was accepted"
  assert_contains "$out" "safe relative path" "the refusal did not name the cause"
  pass "fm-project-local.sh: a manifest path that escapes the project is refused"
}

test_a_symlink_never_enters_the_store() {
  local world out rc
  world=$(make_world symlink)
  printf 'real\n' >"$world/material-src/real.md"
  ln -s "$world/material-src/real.md" "$world/material-src/link.md"
  out=$(local_cmd "$world" add demo "$world/material-src/link.md") && rc=0 || rc=$?
  expect_code 1 "$rc" "a symlink was accepted into the store"
  assert_contains "$out" "symlink" "the refusal did not name the symlink"
  pass "fm-project-local.sh: a symlink is refused rather than stored"
}

# A symlink nested inside an added directory must be refused BEFORE the tree is
# copied: a refusal that left the symlink in the store would make every later
# stage - and with it every spawn of the project - fail until someone cleaned
# the store by hand. herramientas/ with a Python venv inside is the real case.
test_a_nested_symlink_is_refused_before_it_poisons_the_store() {
  local world out rc
  world=$(make_world nested)
  mkdir -p "$world/material-src/tools/venv/bin"
  printf 'tool\n' >"$world/material-src/tools/replay.py"
  printf 'interp\n' >"$world/material-src/tools/venv/bin/python3"
  ln -s python3 "$world/material-src/tools/venv/bin/python"
  out=$(local_cmd "$world" add demo "$world/material-src/tools") && rc=0 || rc=$?
  expect_code 1 "$rc" "a directory holding a nested symlink was accepted into the store"
  assert_contains "$out" "symlink" "the refusal did not name the symlink"
  [ -z "$(find "$world/home/data/project-local" -type l 2>/dev/null)" ] ||
    fail "the refused add left a symlink in the store"
  out=$(local_cmd "$world" list demo)
  assert_not_contains "$out" "tools/replay.py" "the refused add still copied the directory into the store"
  out=$(local_cmd "$world" stage demo "$world/copy") || fail "a later stage failed after the refused add: $out"
  pass "fm-project-local.sh: a nested symlink is refused before anything enters the store"
}

# A directory holding a symlink is not transportable - herramientas/ with a
# Python venv inside is the real case - but it must not take the rest of the
# manifest down with it: everything listed after it still has to reach the
# worker, and the store must stay clean enough to stage.
test_sync_skips_a_manifest_directory_holding_a_symlink_and_carries_the_rest() {
  local world out rc
  world=$(make_world nestedsync)
  mkdir -p "$world/home/config/project-sources" "$world/home/data/project-local/demo"
  git_q init -q "$world/canonical"
  printf 'x\n' >"$world/canonical/README.md"
  git_q -C "$world/canonical" add README.md
  git_q -C "$world/canonical" commit -qm initial
  mkdir -p "$world/canonical/herramientas/venv/bin" "$world/canonical/docs"
  printf 'tool\n' >"$world/canonical/herramientas/replay.py"
  printf 'interp\n' >"$world/canonical/herramientas/venv/bin/python3"
  ln -s python3 "$world/canonical/herramientas/venv/bin/python"
  printf 'the production audit\n' >"$world/canonical/docs/audit.md"
  FM_HOME="$world/home" "$ROOT/bin/fm-project-memory.sh" source set demo "$world/canonical" --canonical source >/dev/null ||
    fail "source set failed"
  printf 'herramientas\ndocs\n' >"$world/home/data/project-local/demo/manifest"
  out=$(local_cmd "$world" sync demo) && rc=0 || rc=$?
  expect_code 0 "$rc" "one untransportable manifest path killed the whole sync"
  assert_contains "$out" "herramientas did not travel" "the skip did not name the manifest path"
  assert_contains "$out" "symlink" "the skip did not name the symlink it found"
  [ -z "$(find "$world/home/data/project-local" -type l 2>/dev/null)" ] ||
    fail "the skipped path still left a symlink in the store"
  out=$(local_cmd "$world" list demo)
  assert_not_contains "$out" "herramientas" "the directory holding a symlink was copied anyway"
  assert_contains "$out" "docs/audit.md" "a clean path listed after the skipped one never reached the store"
  out=$(local_cmd "$world" stage demo "$world/copy") || fail "a later stage failed after the skip: $out"
  assert_present "$world/copy/.fm-local/docs/audit.md" "the staged copy is missing the material that could travel"
  pass "fm-project-local.sh: sync skips a directory holding a symlink and carries the rest of the manifest"
}

# A path sync cannot refresh keeps the copy an earlier run took - for a project
# whose knowledge lives outside git, that copy can be the last one left, so
# deleting it is not firstmate's call. What the worker must never get is that
# copy presented as the project's current material: `.fm-unverified.md` staged
# beside it is the mark that says which paths those are and since when.
test_a_path_sync_could_not_refresh_reaches_the_worker_marked_unverified() {
  local world out rc note today
  world=$(make_world stale)
  today=$(date -u +%Y-%m-%d)
  mkdir -p "$world/home/config/project-sources" "$world/home/data/project-local/demo"
  git_q init -q "$world/canonical"
  printf 'x\n' >"$world/canonical/README.md"
  git_q -C "$world/canonical" add README.md
  git_q -C "$world/canonical" commit -qm initial
  mkdir -p "$world/canonical/herramientas" "$world/canonical/docs"
  printf 'tool v1\n' >"$world/canonical/herramientas/replay.py"
  printf 'the deposit refund policy\n' >"$world/canonical/docs/policy.md"
  FM_HOME="$world/home" "$ROOT/bin/fm-project-memory.sh" source set demo "$world/canonical" --canonical source >/dev/null ||
    fail "source set failed"
  printf 'herramientas\ndocs\n' >"$world/home/data/project-local/demo/manifest"
  out=$(local_cmd "$world" sync demo) || fail "the first sync failed: $out"
  assert_contains "$out" "2 paths updated" "the first sync did not carry both manifest paths"

  # `python -m venv` inside herramientas/ after a clean sync, and docs/ gone.
  mkdir -p "$world/canonical/herramientas/venv/bin"
  printf 'interp\n' >"$world/canonical/herramientas/venv/bin/python3"
  ln -s python3 "$world/canonical/herramientas/venv/bin/python"
  printf 'tool v2 CORRECTED\n' >"$world/canonical/herramientas/replay.py"
  rm -rf "$world/canonical/docs"

  out=$(local_cmd "$world" sync demo) && rc=0 || rc=$?
  expect_code 0 "$rc" "a sync that could refresh nothing failed outright"
  assert_contains "$out" "0 paths updated, 2 kept from an earlier sync and marked UNVERIFIED" \
    "the counts still read as though nothing reached the worker"
  assert_contains "$out" "was not updated" "the sync did not say the path stayed at its earlier copy"
  assert_grep "tool v1" "$world/home/data/project-local/demo/material/herramientas/replay.py" \
    "the sync deleted material it could not refresh"
  assert_present "$world/home/data/project-local/demo/material/docs/policy.md" \
    "a path gone from the home lost the last copy of its material"

  out=$(local_cmd "$world" stage demo "$world/copy") || fail "stage failed: $out"
  note="$world/copy/.fm-local/.fm-unverified.md"
  assert_present "$world/copy/.fm-local/herramientas/replay.py" "the kept copy never reached the worker"
  assert_present "$note" "the worker got an unrefreshed copy with nothing marking it"
  assert_grep "herramientas" "$note" "the mark did not name the untransportable path"
  assert_grep "docs" "$note" "the mark did not name the path absent from the home"
  assert_grep "UNVERIFIED since $today" "$note" "the mark did not say since when the copy stopped being confirmable"
  out=$(git_q -C "$world/copy" status --porcelain --untracked-files=all)
  [ -z "$out" ] || fail "git can see the staged material: $out"

  # Once the home can be read again, the mark goes with the refresh.
  rm -rf "$world/canonical/herramientas/venv"
  mkdir -p "$world/canonical/docs"
  printf 'the deposit refund policy\n' >"$world/canonical/docs/policy.md"
  out=$(local_cmd "$world" sync demo) || fail "the third sync failed: $out"
  assert_contains "$out" "2 paths updated" "the paths that became readable again were not refreshed"
  out=$(local_cmd "$world" stage demo "$world/copy") || fail "the later stage failed: $out"
  assert_absent "$note" "a refreshed path is still marked unverified"
  assert_grep "tool v2 CORRECTED" "$world/copy/.fm-local/herramientas/replay.py" \
    "the refreshed copy did not reach the worker"
  pass "fm-project-local.sh: a path sync could not refresh reaches the worker marked unverified"
}

# The date is the whole point of the mark: it says since when this copy stopped
# being confirmable. Why it cannot be refreshed can change - the folder comes
# back but now carries a venv, or `find` names a different symlink after a `pip
# install` - while the copy stays the one taken on day zero, and the worker
# must not be told it went stale today.
test_the_unverified_date_survives_a_change_of_reason() {
  local world out record note
  world=$(make_world stalereason)
  mkdir -p "$world/home/config/project-sources" "$world/home/data/project-local/demo"
  git_q init -q "$world/canonical"
  printf 'x\n' >"$world/canonical/README.md"
  git_q -C "$world/canonical" add README.md
  git_q -C "$world/canonical" commit -qm initial
  mkdir -p "$world/canonical/herramientas"
  printf 'tool v1\n' >"$world/canonical/herramientas/replay.py"
  FM_HOME="$world/home" "$ROOT/bin/fm-project-memory.sh" source set demo "$world/canonical" --canonical source >/dev/null ||
    fail "source set failed"
  printf 'herramientas\n' >"$world/home/data/project-local/demo/manifest"
  local_cmd "$world" sync demo >/dev/null || fail "the first sync failed"

  # Day zero: the captain renames the folder away.
  mv "$world/canonical/herramientas" "$world/canonical/herramientas-old"
  local_cmd "$world" sync demo >/dev/null || fail "the sync over an absent path failed"
  # The store's own record is what carries that date forward; age it, since one
  # test run cannot span two days.
  record="$world/home/data/project-local/demo/unverified"
  assert_present "$record" "the sync recorded nothing about the path it could not refresh"
  awk -F'\t' -v OFS='\t' '{ $2 = "2026-01-05"; print }' "$record" >"$record.aged" &&
    mv "$record.aged" "$record" || fail "could not age the record"

  # Later: the folder is back, but now a venv lives inside it, so the reason
  # changes while the store still holds the copy from day zero.
  mv "$world/canonical/herramientas-old" "$world/canonical/herramientas"
  mkdir -p "$world/canonical/herramientas/venv/bin"
  printf 'interp\n' >"$world/canonical/herramientas/venv/bin/python3"
  ln -s python3 "$world/canonical/herramientas/venv/bin/python"
  out=$(local_cmd "$world" sync demo) || fail "the third sync failed: $out"
  assert_contains "$out" "not transportable" "the run did not report the new reason"

  out=$(local_cmd "$world" stage demo "$world/copy") || fail "stage failed: $out"
  note="$world/copy/.fm-local/.fm-unverified.md"
  assert_grep "UNVERIFIED since 2026-01-05" "$note" \
    "the mark restarted its date because the reason changed, over a copy that never got any newer"
  assert_grep "not transportable" "$note" "the mark did not carry the reason from this run"
  pass "fm-project-local.sh: the unverified date survives a change of reason"
}

# A manifest path that was a directory last sync and is a file now: copying
# without clearing the destination first lands the file INSIDE the stale
# directory, and the run reports the path as updated while the worker reads
# material from months ago as the project's current state.
test_a_path_that_became_a_file_replaces_the_directory_it_used_to_be() {
  local world out
  world=$(make_world reshaped)
  mkdir -p "$world/home/config/project-sources" "$world/home/data/project-local/demo"
  git_q init -q "$world/canonical"
  printf 'x\n' >"$world/canonical/README.md"
  git_q -C "$world/canonical" add README.md
  git_q -C "$world/canonical" commit -qm initial
  mkdir -p "$world/canonical/herramientas"
  printf 'the old helper\n' >"$world/canonical/herramientas/replay.py"
  FM_HOME="$world/home" "$ROOT/bin/fm-project-memory.sh" source set demo "$world/canonical" --canonical source >/dev/null ||
    fail "source set failed"
  printf 'herramientas\n' >"$world/home/data/project-local/demo/manifest"
  local_cmd "$world" sync demo >/dev/null || fail "the first sync failed"
  assert_present "$world/home/data/project-local/demo/material/herramientas/replay.py" \
    "the first sync did not carry the directory"

  rm -rf "$world/canonical/herramientas"
  printf 'the whole toolbox collapsed into one script\n' >"$world/canonical/herramientas"
  out=$(local_cmd "$world" sync demo) || fail "the second sync failed: $out"
  assert_contains "$out" "1 paths updated" "the reshaped path was not reported as updated"
  [ -f "$world/home/data/project-local/demo/material/herramientas" ] ||
    fail "the store still holds a directory where the home now has a file"
  assert_grep "collapsed into one script" "$world/home/data/project-local/demo/material/herramientas" \
    "the store did not take the file the home now has"

  out=$(local_cmd "$world" stage demo "$world/copy") || fail "stage failed: $out"
  assert_absent "$world/copy/.fm-local/herramientas/replay.py" \
    "the worker still receives the material the home replaced"
  assert_grep "collapsed into one script" "$world/copy/.fm-local/herramientas" \
    "the worker did not receive what the home holds now"
  pass "fm-project-local.sh: a path that became a file replaces the directory it used to be"
}

# The copy in the store can be the last one left of the captain's material, so a
# read of his home that fails - a OneDrive placeholder that will not hydrate, a
# file Windows has open - must leave it standing. A failed sync that emptied the
# store would destroy exactly what this capability exists to preserve.
test_a_failed_copy_leaves_the_stores_own_copy_standing() {
  local world out
  world=$(make_world failedcopy)
  mkdir -p "$world/home/config/project-sources" "$world/home/data/project-local/demo"
  git_q init -q "$world/canonical"
  printf 'x\n' >"$world/canonical/README.md"
  git_q -C "$world/canonical" add README.md
  git_q -C "$world/canonical" commit -qm initial
  printf 'the only surviving copy of the audit\n' >"$world/canonical/audit.md"
  FM_HOME="$world/home" "$ROOT/bin/fm-project-memory.sh" source set demo "$world/canonical" --canonical source >/dev/null ||
    fail "source set failed"
  printf 'audit.md\n' >"$world/home/data/project-local/demo/manifest"
  local_cmd "$world" sync demo >/dev/null || fail "the first sync failed"

  chmod 000 "$world/canonical/audit.md"
  out=$(local_cmd "$world" sync demo) || fail "a sync that could not read the home failed outright: $out"
  chmod 644 "$world/canonical/audit.md"
  assert_grep "the only surviving copy of the audit" "$world/home/data/project-local/demo/material/audit.md" \
    "a failed copy destroyed the copy the store already had"
  assert_contains "$out" "0 paths updated, 1 kept from an earlier sync and marked UNVERIFIED" \
    "the unreadable path was counted as updated"
  out=$(local_cmd "$world" stage demo "$world/copy") || fail "stage failed: $out"
  assert_grep "the only surviving copy of the audit" "$world/copy/.fm-local/audit.md" \
    "the kept copy never reached the worker"
  assert_grep "audit.md" "$world/copy/.fm-local/.fm-unverified.md" \
    "the kept copy reached the worker without a mark"
  pass "fm-project-local.sh: a failed copy leaves the store's own copy standing"
}

# tar reports the extractor's status, and an extractor happily succeeds over a
# truncated stream, so a directory the home could only be read halfway would be
# counted as updated and handed to the worker as the project's current material.
test_a_directory_read_only_halfway_is_never_counted_as_updated() {
  local world out
  world=$(make_world partialtree)
  mkdir -p "$world/home/config/project-sources" "$world/home/data/project-local/demo"
  git_q init -q "$world/canonical"
  printf 'x\n' >"$world/canonical/README.md"
  git_q -C "$world/canonical" add README.md
  git_q -C "$world/canonical" commit -qm initial
  mkdir -p "$world/canonical/herramientas"
  printf 'the replay tool\n' >"$world/canonical/herramientas/replay.py"
  printf 'the production audit of 500 conversations\n' >"$world/canonical/herramientas/audit.md"
  FM_HOME="$world/home" "$ROOT/bin/fm-project-memory.sh" source set demo "$world/canonical" --canonical source >/dev/null ||
    fail "source set failed"
  printf 'herramientas\n' >"$world/home/data/project-local/demo/manifest"
  local_cmd "$world" sync demo >/dev/null || fail "the first sync failed"

  chmod 000 "$world/canonical/herramientas/audit.md"
  out=$(local_cmd "$world" sync demo) || fail "the sync over a partly unreadable directory failed outright: $out"
  chmod 644 "$world/canonical/herramientas/audit.md"
  assert_contains "$out" "0 paths updated, 1 kept from an earlier sync and marked UNVERIFIED" \
    "a directory read only halfway was reported as updated"
  assert_grep "the production audit of 500 conversations" \
    "$world/home/data/project-local/demo/material/herramientas/audit.md" \
    "the half-read copy replaced the whole one the store already had"
  out=$(local_cmd "$world" stage demo "$world/copy") || fail "stage failed: $out"
  assert_present "$world/copy/.fm-local/herramientas/audit.md" "the worker received a store missing the audit"
  assert_grep "herramientas" "$world/copy/.fm-local/.fm-unverified.md" \
    "the worker was handed the kept copy as though it were current"
  pass "fm-project-local.sh: a directory read only halfway is never counted as updated"
}

# What one manifest path could not finish copying must never end up filed under
# the next one. A read-only directory in the captain's home makes the cleanup of
# a failed copy fail too, and a shared staging area would then hand the leftover
# to whatever path came next - wrong material under a name the worker trusts,
# with no error anywhere.
# Staging reads the store while a `sync` of the same project may be replacing
# it, so the read can end early. tar's extractor reports success over a
# truncated stream, so only the producer's status says whether the whole store
# travelled - and a worker handed a subset of a source-canonical project's
# material would read it as the whole of it, unmarked.
test_a_store_read_only_halfway_never_reaches_the_worker() {
  local world out rc material
  world=$(make_world partialstage)
  material="$world/home/data/project-local/demo/material"
  mkdir -p "$material/locked"
  printf 'the production audit that must travel\n' >"$material/audit.md"
  printf 'more of the captain material\n' >"$material/locked/notes.md"
  chmod 000 "$material/locked"
  out=$(local_cmd "$world" stage demo "$world/copy") && rc=0 || rc=$?
  chmod 755 "$material/locked"
  expect_code 1 "$rc" "a store that could only be read halfway was staged as though it were whole"
  assert_contains "$out" "in full" "the refusal did not say the store could not be read whole"
  assert_absent "$world/copy/.fm-local" "the refused stage left a partial copy for the worker"
  pass "fm-project-local.sh: a store read only halfway never reaches the worker"
}

# The other half of the same guard. The test above ends with the reader
# succeeding, so the pipeline's own status is zero and nothing stops the check
# from running; when the READER is the one that fails, a bare pipeline under
# `set -e` ends the script on that line instead, and neither the cleanup nor the
# explanation ever runs. Injecting a failing extractor is the only way to hold
# that branch open.
test_a_write_that_fails_halfway_leaves_no_partial_copy_and_says_why() {
  local world out rc fake realtar
  world=$(make_world partialwrite)
  mkdir -p "$world/home/data/project-local/demo/material"
  printf 'the production audit that must travel\n' \
    >"$world/home/data/project-local/demo/material/audit.md"
  fake="$world/fakebin"
  mkdir -p "$fake"
  realtar=$(command -v tar)
  cat >"$fake/tar" <<EOF
#!/usr/bin/env bash
case \$1 in
  xf)
    cat >/dev/null
    echo "tar: Unexpected EOF in archive" >&2
    exit 2
    ;;
esac
exec "$realtar" "\$@"
EOF
  chmod +x "$fake/tar"
  out=$(PATH="$fake:$PATH" FM_HOME="$world/home" "$ROOT/bin/fm-project-local.sh" \
    stage demo "$world/copy" 2>&1) && rc=0 || rc=$?
  expect_code 1 "$rc" "a store that could not be written in full was staged as though it were whole"
  assert_contains "$out" "in full" "the refusal did not explain what went wrong, only tar's own error"
  assert_absent "$world/copy/.fm-local" "the refused stage left a partial copy for the worker"
  pass "fm-project-local.sh: a write that fails halfway leaves no partial copy and says why"
}

test_a_failed_copy_never_leaks_into_the_next_manifest_path() {
  local world out
  world=$(make_world crosstalk)
  mkdir -p "$world/home/config/project-sources" "$world/home/data/project-local/demo"
  git_q init -q "$world/canonical"
  printf 'x\n' >"$world/canonical/README.md"
  git_q -C "$world/canonical" add README.md
  git_q -C "$world/canonical" commit -qm initial
  mkdir -p "$world/canonical/herramientas/locked" "$world/canonical/informes"
  printf 'the replay tool\n' >"$world/canonical/herramientas/replay.py"
  printf 'the production audit\n' >"$world/canonical/herramientas/audit.md"
  printf 'material that belongs under herramientas\n' >"$world/canonical/herramientas/locked/leak.txt"
  printf 'the bug findings\n' >"$world/canonical/informes/bugs.md"
  FM_HOME="$world/home" "$ROOT/bin/fm-project-memory.sh" source set demo "$world/canonical" --canonical source >/dev/null ||
    fail "source set failed"
  printf 'herramientas\ninformes\n' >"$world/home/data/project-local/demo/manifest"
  local_cmd "$world" sync demo >/dev/null || fail "the first sync failed"

  chmod 000 "$world/canonical/herramientas/audit.md"
  chmod 555 "$world/canonical/herramientas/locked"
  out=$(local_cmd "$world" sync demo) || fail "the sync failed outright: $out"
  chmod 755 "$world/canonical/herramientas/locked"
  chmod 644 "$world/canonical/herramientas/audit.md"

  assert_absent "$world/home/data/project-local/demo/material/informes/locked" \
    "material from one manifest path was filed under the next one"
  assert_grep "the bug findings" "$world/home/data/project-local/demo/material/informes/bugs.md" \
    "the clean manifest path did not reach the store"
  out=$(local_cmd "$world" stage demo "$world/copy") || fail "stage failed: $out"
  assert_absent "$world/copy/.fm-local/informes/locked" "the worker received material filed under the wrong path"
  pass "fm-project-local.sh: a failed copy never leaks into the next manifest path"
}

test_staged_material_is_removed_and_refused_when_git_can_still_see_it() {
  local world out rc
  world=$(make_world visible)
  printf 'material\n' >"$world/material-src/note.md"
  local_cmd "$world" add demo "$world/material-src/note.md" >/dev/null || fail "add failed"
  # A project that force-includes the staged path defeats the exclude entry, so
  # the post-stage verification is the only thing standing between the worker
  # and a commit of this material.
  printf '!.fm-local/\n!.fm-local/**\n' >"$world/copy/.gitignore"
  git_q -C "$world/copy" add .gitignore
  git_q -C "$world/copy" commit -qm "force-include the staged path"
  out=$(local_cmd "$world" stage demo "$world/copy") && rc=0 || rc=$?
  expect_code 1 "$rc" "staging succeeded while git could still see the material"
  assert_absent "$world/copy/.fm-local" "the refused stage left committable material behind"
  pass "fm-project-local.sh: material git can still see is removed and the stage refused"
}

test_stage_is_a_no_op_for_a_project_name_no_store_can_address() {
  local world out rc
  world=$(make_world oddname)
  out=$(local_cmd "$world" stage "odd name/with slash" "$world/copy") && rc=0 || rc=$?
  expect_code 0 "$rc" "a project whose name no store can address failed its spawn-time stage"
  assert_absent "$world/copy/.fm-local" "an unaddressable project name still staged something"
  pass "fm-project-local.sh: staging is a no-op for a project name no store can address"
}

test_a_reused_copy_never_keeps_the_previous_tasks_material() {
  local world out
  world=$(make_world reused)
  printf 'first task material\n' >"$world/material-src/first.md"
  local_cmd "$world" add demo "$world/material-src/first.md" >/dev/null || fail "add failed"
  local_cmd "$world" stage demo "$world/copy" >/dev/null || fail "first stage failed"
  assert_present "$world/copy/.fm-local/first.md" "the first stage did not land"

  local_cmd "$world" remove demo first.md >/dev/null || fail "remove failed"
  out=$(local_cmd "$world" stage demo "$world/copy") || fail "second stage failed: $out"
  assert_absent "$world/copy/.fm-local" "a reused copy kept the previous task's material"
  pass "fm-project-local.sh: a reused copy never keeps the previous task's material"
}

test_staged_material_is_readable_and_cannot_be_committed
test_stage_refuses_when_the_project_tracks_the_destination
test_an_empty_store_stages_nothing
test_sync_pulls_the_manifest_from_the_canonical_home_without_writing_to_it
test_sync_refuses_an_escaping_manifest_path
test_a_symlink_never_enters_the_store
test_a_nested_symlink_is_refused_before_it_poisons_the_store
test_sync_skips_a_manifest_directory_holding_a_symlink_and_carries_the_rest
test_a_path_sync_could_not_refresh_reaches_the_worker_marked_unverified
test_the_unverified_date_survives_a_change_of_reason
test_a_path_that_became_a_file_replaces_the_directory_it_used_to_be
test_a_failed_copy_leaves_the_stores_own_copy_standing
test_a_directory_read_only_halfway_is_never_counted_as_updated
test_a_failed_copy_never_leaks_into_the_next_manifest_path
test_a_store_read_only_halfway_never_reaches_the_worker
test_a_write_that_fails_halfway_leaves_no_partial_copy_and_says_why
test_staged_material_is_removed_and_refused_when_git_can_still_see_it
test_a_reused_copy_never_keeps_the_previous_tasks_material
test_stage_is_a_no_op_for_a_project_name_no_store_can_address
test_sync_reports_a_home_that_was_being_worked_while_it_was_read
test_sync_says_when_activity_could_not_be_determined
