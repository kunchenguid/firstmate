#!/usr/bin/env bash
# Behavior tests for project capacity admission: a project that declares how
# many workers it admits at once on this machine never gets a fresh worker
# launched beyond that number (bin/fm-project-capacity-lib.sh owns the
# contract; bin/fm-spawn.sh runs the check).
#
# Every case drives the real bin/fm-spawn.sh against a real project clone with
# an origin, fake tmux and treehouse binaries that log every call, and a real
# markdown backlog when tasks-axi is installed. A deferred spawn is judged by
# what it left behind - no task record, no rendered launch brief, no endpoint,
# no worktree allocation, and a backlog item still queued - never by wording
# alone.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

unset TASKS_AXI_BACKEND || :

SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-project-capacity)
DEFER_EXIT=75
HAVE_TASKS_AXI=0
command -v tasks-axi >/dev/null 2>&1 && HAVE_TASKS_AXI=1

# --- fixture ----------------------------------------------------------------

write_brief() {  # <home> <id>
  mkdir -p "$1/data/$2"
  cat > "$1/data/$2/brief.md" <<EOF
# Task
## Captain's intent
Run the project's heavy suite for $2.

## Firstmate spec
Exercise project capacity admission.

# Definition of done
Delivery contract: mode=no-mistakes
EOF
}

# A Firstmate home with its own backlog (when tasks-axi is installed) and a
# brief for every named task.
make_home() {  # <home> [task-id...]
  local home=$1 id
  shift
  mkdir -p "$home/state" "$home/config" "$home/data" "$home/projects"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' codex > "$home/config/crew-harness"
  if [ "$HAVE_TASKS_AXI" = 1 ]; then
    printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' \
      > "$home/data/backlog.md"
    cat > "$home/.tasks.toml" <<'EOF'
backend = "markdown"

[markdown]
path = "data/backlog.md"
EOF
  fi
  for id in "$@"; do
    write_brief "$home" "$id"
    add_item "$home" "$id"
  done
}

# A case: one home, a project clone with an origin, and fake tmux/treehouse
# that record every call so a deferral can be proved to have created nothing.
make_case() {  # <name> [task-id...]
  local name=$1 case_dir fakebin
  shift
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir"
  fakebin=$(fm_fakebin "$case_dir")
  : > "$case_dir/calls.log"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_CALL_LOG"
case "$*" in
  *"#{pane_current_path}"*)
    # A spawn that is told to hold waits here, after its capacity check and
    # while it still holds the project lock, until the test releases it.
    if [ -n "${FM_FAKE_HOLD:-}" ]; then
      : > "$FM_FAKE_HOLD.reached"
      i=0
      while [ ! -f "$FM_FAKE_HOLD.release" ]; do
        i=$((i + 1))
        [ "$i" -lt 400 ] || exit 1
        sleep 0.05
      done
    fi
    printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    exit 0
    ;;
esac
case "${1:-}" in display-message) printf 'firstmate\n' ;; esac
exit 0
SH
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf 'treehouse %s\n' "$*" >> "$FM_FAKE_CALL_LOG"
# A spawn leases the worktree its pane then reports.
for arg in "$@"; do
  [ "$arg" != --lease ] || { printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0; }
done
exit 0
SH
  chmod +x "$fakebin/tmux" "$fakebin/treehouse"
  fm_fake_exit0 "$fakebin" gh gh-axi no-mistakes
  fm_git_init_commit "$case_dir/project"
  fm_git_add_origin "$case_dir/project" "$case_dir/project.origin.git"
  fm_git_init_commit "$case_dir/other-project"
  fm_git_add_origin "$case_dir/other-project" "$case_dir/other-project.origin.git"
  make_home "$case_dir/home" "$@"
  printf '%s\n' "$case_dir"
}

add_item() {  # <home> <id>
  [ "$HAVE_TASKS_AXI" = 1 ] || return 0
  tasks-axi add "$2" "item for $2" --kind ship --file "$1/data/backlog.md" >/dev/null
}

row_state() {  # <home> <id>
  tasks-axi show "$2" --file "$1/data/backlog.md" 2>/dev/null |
    sed -n 's/^  state: *//p' | head -1
}

declare_capacity() {  # <home> <line>...
  local home=$1
  shift
  printf '%s\n' "$@" > "$home/config/project-capacity"
}

# A live worker already on a project: the record shape bin/fm-spawn.sh
# publishes, with its backlog item In flight so cleanup can close it.
write_live() {  # <home> <id> <project-dir> [extra-line...]
  local home=$1 id=$2 project=$3
  shift 3
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$home/absent-worktree-$id" \
    "project=$project" \
    "harness=codex" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off" \
    "spawn_gen=s-$id" \
    "$@"
  if [ "$HAVE_TASKS_AXI" = 1 ]; then
    add_item "$home" "$id"
    tasks-axi start "$id" --file "$home/data/backlog.md" >/dev/null
  fi
}

# One isolated worktree per spawn, so every admitted launch has its own copy.
new_worktree() {  # <case-dir> <name>
  git -C "$1/project" worktree add --quiet -b "wt-$2" "$1/wt-$2"
  printf '%s\n' "$1/wt-$2"
}

run_spawn() {  # <case-dir> <home> <pane-path> <args...>
  local case_dir=$1 home=$2 pane=$3
  shift 3
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_BACKEND=tmux \
    FM_FAKE_PANE_PATH="$pane" FM_FAKE_CALL_LOG="$case_dir/calls.log" \
    PATH="$case_dir/fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

spawn_ship() {  # <case-dir> <id> [pane-path]
  local case_dir=$1 id=$2 pane=${3:-}
  [ -n "$pane" ] || pane=$(new_worktree "$case_dir" "$id")
  run_spawn "$case_dir" "$case_dir/home" "$pane" "$id" "$case_dir/project" --mode no-mistakes --yolo off
}

# Everything a deferred spawn must not have created for <id>; <worktrees-before>
# is worktree_list taken before the spawn.
assert_nothing_created() {  # <case-dir> <home> <id> <calls-before> <worktrees-before>
  local case_dir=$1 home=$2 id=$3 before=$4 worktrees=$5 after
  assert_absent "$home/state/$id.meta" "a deferred spawn published a task record for $id"
  assert_absent "$home/data/$id/launch-brief.md" "a deferred spawn rendered a launch brief for $id"
  after=$(call_count "$case_dir")
  [ "$after" -eq "$before" ] ||
    fail "a deferred spawn touched the terminal or worktree pool for $id: $(tail -n +"$((before + 1))" "$case_dir/calls.log")"
  assert_equals "$worktrees" "$(worktree_list "$case_dir")" "a deferred spawn left a git worktree for $id"
  if [ "$HAVE_TASKS_AXI" = 1 ]; then
    [ "$(row_state "$home" "$id")" = queued ] ||
      fail "a deferred spawn moved $id's backlog item: $(row_state "$home" "$id")"
  fi
}

call_count() { wc -l < "$1/calls.log" | tr -d ' '; }

worktree_list() { git -C "$1/project" worktree list --porcelain; }

# --- cases ------------------------------------------------------------------

# The reported incident's shape before any declaration: the project is already
# busy, and nothing caps a further launch. Absent a declaration that stays true.
test_undeclared_capacity_keeps_dispatch_uncapped() {
  local case_dir home out rc=0
  case_dir=$(make_case undeclared task-c)
  home="$case_dir/home"
  write_live "$home" live-a "$case_dir/project"
  write_live "$home" live-b "$case_dir/project"
  out=$(spawn_ship "$case_dir" task-c) || rc=$?
  expect_code 0 "$rc" "an undeclared project refused a spawn: $out"
  assert_contains "$out" "spawned task-c" "an undeclared project did not launch the worker"
  assert_present "$home/state/task-c.meta" "an undeclared project's spawn published no record"
  pass "a project with no declared capacity keeps today's uncapped dispatch"
}

test_available_capacity_admits_the_worker() {
  local case_dir home out rc=0
  case_dir=$(make_case available task-c)
  home="$case_dir/home"
  declare_capacity "$home" "# heavy suite serves two workers" "project 2" "other-project 1"
  write_live "$home" live-a "$case_dir/project"
  out=$(spawn_ship "$case_dir" task-c) || rc=$?
  expect_code 0 "$rc" "a spawn with a free place was refused: $out"
  assert_contains "$out" "spawned task-c" "a spawn with a free place did not launch"
  assert_not_contains "$out" "deferred:" "a spawn with a free place reported a deferral"
  if [ "$HAVE_TASKS_AXI" = 1 ]; then
    [ "$(row_state "$home" task-c)" = in_flight ] || fail "an admitted spawn did not move its item In flight"
  fi
  pass "a spawn is admitted while its project still has a free place"
}

test_exhausted_capacity_defers_without_leaving_anything_behind() {
  local case_dir home out rc=0 before worktrees
  case_dir=$(make_case exhausted task-c)
  home="$case_dir/home"
  declare_capacity "$home" "project 2"
  write_live "$home" live-a "$case_dir/project"
  write_live "$home" live-b "$case_dir/project"
  before=$(call_count "$case_dir")
  worktrees=$(worktree_list "$case_dir")
  out=$(spawn_ship "$case_dir" task-c "$case_dir/unused") || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "a spawn beyond capacity was not deferred: $out"
  assert_contains "$out" "deferred: project project admits 2 worker(s) at once on this machine ($home/config/project-capacity) and 2 already hold a place (live-a, live-b)" \
    "the deferral did not name the capacity and its holders"
  assert_contains "$out" "task task-c was not launched and its backlog item stays queued" \
    "the deferral did not say the task stays queued"
  assert_nothing_created "$case_dir" "$home" task-c "$before" "$worktrees"
  pass "a spawn beyond capacity is deferred before any record, brief, endpoint, worktree, or backlog move exists"
}

# The capacity is the last field, so a project whose clone directory name holds
# spaces can be declared. An indented '#' line is still a comment.
test_spaced_project_name_is_declared() {
  local case_dir home spaced out rc=0
  case_dir=$(make_case spaced task-c)
  home="$case_dir/home"
  spaced="$case_dir/my  heavy project"
  git clone -q "$(git -C "$case_dir/project" remote get-url origin)" "$spaced"
  declare_capacity "$home" "   # my  heavy project 9" "my  heavy project 1" "project 5"
  write_live "$home" live-a "$spaced"
  out=$(run_spawn "$case_dir" "$home" "$case_dir/unused" task-c "$spaced" --mode no-mistakes --yolo off) || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "a project whose name holds spaces was not capped by its declaration: $out"
  assert_contains "$out" "deferred: project my  heavy project admits 1 worker(s) at once" \
    "the deferral did not use the spaced project's declared capacity"
  assert_absent "$home/state/task-c.meta" "the deferred spaced-name spawn published a record"
  pass "a project name with spaces is declared by taking the capacity from the last field"
}

# A clone directory may be named with a leading '#'. That name is declared when
# the '#' is written against the rest of the name and the line ends with the
# capacity. A '#' followed by whitespace stays a comment even when the line
# ends with a number, and a '#' note that is not a capacity stays a comment.
test_hash_prefixed_project_name_is_declared() {
  local case_dir home hashed spaced out rc=0 wt
  case_dir=$(make_case hash-name task-c task-d)
  home="$case_dir/home"
  hashed="$case_dir/#hash-project"
  spaced="$case_dir/# serves"
  git clone -q "$(git -C "$case_dir/project" remote get-url origin)" "$hashed"
  git clone -q "$(git -C "$case_dir/other-project" remote get-url origin)" "$spaced"
  declare_capacity "$home" "# serves 2" "#not-a-capacity" "#hash-project 1"
  write_live "$home" live-a "$hashed"
  out=$(run_spawn "$case_dir" "$home" "$case_dir/unused" task-c "$hashed" --mode no-mistakes --yolo off) || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "a project whose name begins with # was not capped by its declaration: $out"
  assert_contains "$out" "deferred: project #hash-project admits 1 worker(s) at once" \
    "the deferral did not use the hash-prefixed project's declared capacity"
  assert_absent "$home/state/task-c.meta" "the deferred hash-prefixed spawn published a record"

  write_live "$home" live-b "$spaced"
  write_live "$home" live-c "$spaced"
  git -C "$spaced" worktree add --quiet -b wt-d "$case_dir/wt-d"
  wt="$case_dir/wt-d"
  rc=0
  out=$(run_spawn "$case_dir" "$home" "$wt" task-d "$spaced" --mode no-mistakes --yolo off) || rc=$?
  expect_code 0 "$rc" "a '#' comment that ends with a number was read as a capacity: $out"
  assert_contains "$out" "spawned task-d" "a project whose declaration line is a comment did not stay uncapped"
  pass "a project name beginning with # is declared, and a # comment stays a comment"
}

# A home reached through a symlink is still one home: its workers hold one
# place each, not one per spelling of its state directory.
test_symlinked_home_counts_each_worker_once() {
  local case_dir home out rc=0
  case_dir=$(make_case symlinked-home task-c)
  home="$case_dir/home"
  ln -s "$home" "$case_dir/home-link"
  declare_capacity "$home" "project 2"
  write_live "$home" live-a "$case_dir/project"
  out=$(run_spawn "$case_dir" "$case_dir/home-link" "$(new_worktree "$case_dir" task-c)" \
    task-c "$case_dir/project" --mode no-mistakes --yolo off) || rc=$?
  expect_code 0 "$rc" "a spawn through a symlinked home counted its own worker twice: $out"
  assert_contains "$out" "spawned task-c" "a spawn through a symlinked home did not launch"
  pass "a home reached through a symlink counts each of its workers once"
}

# A fresh spawn that restarts an existing task id replaces that task's own
# record, so the record does not hold a place against it. Any other task on the
# project still sees that record as a holder.
test_restart_does_not_count_its_own_record() {
  local case_dir home out rc=0
  case_dir=$(make_case restart task-c task-d)
  home="$case_dir/home"
  declare_capacity "$home" "project 1"
  fm_write_meta "$home/state/task-c.meta" \
    "window=firstmate:fm-task-c" \
    "project=$case_dir/project" \
    "kind=ship"
  out=$(spawn_ship "$case_dir" task-c) || rc=$?
  assert_not_contains "$out" "deferred:" "a restart was deferred by its own record"
  [ "$rc" -ne "$DEFER_EXIT" ] || fail "a restart exited with the deferral code: $out"
  rc=0
  out=$(spawn_ship "$case_dir" task-d "$case_dir/unused") || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "another task ignored the restarted task's place: $out"
  assert_contains "$out" "1 already hold a place (task-c)" "another task did not count the restarted task"
  pass "a restart of a task id does not count that task's own record"
}

# A place frees when a worker records its ready PR and when a task is cleaned
# up; each release admits exactly one more worker.
test_release_frees_a_place() {
  local case_dir home out rc=0
  case_dir=$(make_case release task-c task-d)
  home="$case_dir/home"
  declare_capacity "$home" "project 2"
  write_live "$home" live-a "$case_dir/project"
  write_live "$home" live-b "$case_dir/project"
  out=$(spawn_ship "$case_dir" task-c "$case_dir/unused") || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "the full project admitted a worker: $out"

  # PR handoff: the line bin/fm-pr-check.sh records for a ready PR.
  printf 'pr=%s\n' "https://github.com/o/r/pull/7" >> "$home/state/live-a.meta"
  rc=0
  out=$(spawn_ship "$case_dir" task-c) || rc=$?
  expect_code 0 "$rc" "a recorded PR handoff did not free a place: $out"
  rc=0
  out=$(spawn_ship "$case_dir" task-d "$case_dir/unused") || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "one freed place admitted two workers: $out"
  assert_contains "$out" "2 already hold a place (live-b, task-c)" "the new worker did not take the freed place"

  # Cleanup: the real teardown removes the record, which frees its place.
  rc=0
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_FAKE_CALL_LOG="$case_dir/calls.log" PATH="$case_dir/fakebin:$PATH" \
    "$TEARDOWN" live-b 2>&1) || rc=$?
  expect_code 0 "$rc" "cleanup of a live worker failed: $out"
  assert_absent "$home/state/live-b.meta" "cleanup left the worker's record"
  rc=0
  out=$(spawn_ship "$case_dir" task-d) || rc=$?
  expect_code 0 "$rc" "cleanup did not free a place: $out"
  pass "a recorded PR handoff or a cleanup each frees exactly one place"
}

# Only workers on the same project identity hold places: a secondmate record, a
# record for another project, and a scout on another project are ignored, while
# a scout and a legacy record without kind= on this project count.
test_occupancy_counts_only_this_projects_workers() {
  local case_dir home out rc=0
  case_dir=$(make_case occupancy task-c)
  home="$case_dir/home"
  declare_capacity "$home" "project 3"
  write_live "$home" scout-a "$case_dir/project"
  sed -i.bak 's/^kind=ship$/kind=scout/' "$home/state/scout-a.meta" && rm -f "$home/state/scout-a.meta.bak"
  fm_write_meta "$home/state/legacy-b.meta" "window=firstmate:fm-legacy-b" "project=$case_dir/project"
  write_live "$home" other-c "$case_dir/other-project"
  fm_write_meta "$home/state/mate-d.meta" "window=remote:mate-d" "project=$case_dir/project" "kind=secondmate"
  out=$(spawn_ship "$case_dir" task-c) || rc=$?
  expect_code 0 "$rc" "records outside this project's workers took a place: $out"
  rc=0
  write_brief "$home" task-e
  add_item "$home" task-e
  out=$(spawn_ship "$case_dir" task-e "$case_dir/unused") || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "the third worker on the project was not counted: $out"
  assert_contains "$out" "3 already hold a place (legacy-b, scout-a, task-c)" \
    "occupancy counted the wrong records"
  pass "only this project's ship and scout records hold places"
}

# Capacity belongs to the machine: a local secondmate home's workers on a
# separate clone of the same origin count, the declaration comes from the root
# home even when the secondmate spawns, and a remote home's workers never count.
test_capacity_is_shared_by_every_local_home() {
  local case_dir root mate out rc=0 mate_project
  case_dir=$(make_case machine)
  root="$case_dir/home"
  mate="$case_dir/mate"
  make_home "$mate" task-m
  mate_project="$mate/projects/project"
  git clone -q "$(git -C "$case_dir/project" remote get-url origin)" "$mate_project"
  printf '%s\n' schema=fm-secondmate-parent.v1 route=local "parent_home=$root" > "$mate/.fm-secondmate-parent"
  printf -- '- mate - a local mate (home: %s; scope: project work; projects: project; added 2026-09-01)\n' "$mate" \
    > "$root/data/secondmates.md"
  printf -- '- far - a remote mate (host: far.example; root: /srv/fm; home: %s/remote-home; scope: other; projects: project; added 2026-09-01)\n' "$case_dir" \
    >> "$root/data/secondmates.md"
  mkdir -p "$case_dir/remote-home/state"
  fm_write_meta "$case_dir/remote-home/state/far-x.meta" "window=w" "project=$case_dir/project" "kind=ship"
  declare_capacity "$root" "project 1"
  write_live "$root" live-a "$case_dir/project"
  git -C "$mate_project" worktree add --quiet -b wt-m "$case_dir/wt-m"
  out=$(run_spawn "$case_dir" "$mate" "$case_dir/wt-m" task-m "$mate_project" --mode no-mistakes --yolo off) || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "a local secondmate launched past the machine's capacity: $out"
  assert_contains "$out" "admits 1 worker(s) at once on this machine ($root/config/project-capacity) and 1 already hold a place (live-a in $root)" \
    "the secondmate did not count the root home's worker against the root's declaration"
  assert_absent "$mate/state/task-m.meta" "the deferred secondmate spawn published a record"
  printf 'pr=%s\n' "https://github.com/o/r/pull/8" >> "$root/state/live-a.meta"
  rc=0
  out=$(run_spawn "$case_dir" "$mate" "$case_dir/wt-m" task-m "$mate_project" --mode no-mistakes --yolo off) || rc=$?
  expect_code 0 "$rc" "the remote home's worker, or a handed-off one, took the machine's place: $out"
  pass "every local home shares one declared capacity per project origin, and remote homes do not count"
}

# A local home's state directory or task record that cannot be read could hide a
# holder, so admission refuses instead of counting without it.
test_unreadable_holders_refuse_admission() {
  local case_dir root mate out rc=0
  if [ "$(id -u)" = 0 ]; then
    printf 'ok - skipped the unreadable-holder case (root reads files regardless of mode)\n'
    return 0
  fi
  case_dir=$(make_case unreadable-holders task-c)
  root="$case_dir/home"
  mate="$case_dir/mate"
  make_home "$mate"
  printf '%s\n' schema=fm-secondmate-parent.v1 route=local "parent_home=$root" > "$mate/.fm-secondmate-parent"
  printf -- '- mate - a local mate (home: %s; scope: project work; projects: project; added 2026-09-01)\n' "$mate" \
    > "$root/data/secondmates.md"
  declare_capacity "$root" "project 2"

  write_live "$root" live-a "$case_dir/project"
  chmod 000 "$root/state/live-a.meta"
  out=$(spawn_ship "$case_dir" task-c "$case_dir/unused") || rc=$?
  chmod 600 "$root/state/live-a.meta"
  expect_code 1 "$rc" "an unreadable task record did not refuse admission: $out"
  assert_contains "$out" "task record $root/state/live-a.meta cannot be read" \
    "the refusal did not name the unreadable task record"
  assert_absent "$root/state/task-c.meta" "a spawn published past an unreadable task record"

  chmod 000 "$mate/state"
  rc=0
  out=$(spawn_ship "$case_dir" task-c "$case_dir/unused") || rc=$?
  chmod 755 "$mate/state"
  expect_code 1 "$rc" "an unreadable local state directory did not refuse admission: $out"
  assert_contains "$out" "local Firstmate state directory $mate/state cannot be read" \
    "the refusal did not name the unreadable state directory"
  assert_absent "$root/state/task-c.meta" "a spawn published past an unreadable state directory"

  rc=0
  out=$(spawn_ship "$case_dir" task-c) || rc=$?
  expect_code 0 "$rc" "a readable machine did not admit the worker: $out"
  pass "an unreadable state directory or task record refuses admission rather than undercounting"
}

# Two spawns racing for the last place: the one holding the project lock
# publishes, the other cannot publish while it waits and is deferred afterwards.
test_concurrent_spawns_cannot_both_take_the_last_place() {
  local case_dir home out rc=0 hold i wt
  case_dir=$(make_case concurrent task-a task-b)
  home="$case_dir/home"
  declare_capacity "$home" "project 1"
  hold="$case_dir/hold"
  wt=$(new_worktree "$case_dir" task-a)
  FM_FAKE_HOLD="$hold" spawn_ship "$case_dir" task-a "$wt" > "$case_dir/a.out" 2>&1 &
  i=0
  while [ ! -f "$hold.reached" ]; do
    i=$((i + 1))
    [ "$i" -lt 400 ] || fail "the first spawn never reached its launch: $(cat "$case_dir/a.out")"
    sleep 0.05
  done
  out=$(spawn_ship "$case_dir" task-b "$case_dir/unused") || rc=$?
  [ "$rc" -ne 0 ] || fail "a concurrent spawn launched while the last place was being taken: $out"
  assert_absent "$home/state/task-b.meta" "a concurrent spawn published past the last place"
  : > "$hold.release"
  wait || true
  assert_contains "$(cat "$case_dir/a.out")" "spawned task-a" "the lock-holding spawn did not finish"
  rc=0
  out=$(spawn_ship "$case_dir" task-b "$case_dir/unused") || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "the retried spawn was not deferred once the place was taken: $out"
  assert_absent "$home/state/task-b.meta" "the retried spawn published past capacity"
  pass "concurrent spawns can never both take the last place"
}

# A spawn that fails after admission removes nothing it did not create and
# leaves no record, so it holds no place afterwards.
test_failed_spawn_after_admission_holds_no_place() {
  local case_dir home out rc=0
  case_dir=$(make_case failed task-a task-b)
  home="$case_dir/home"
  declare_capacity "$home" "project 1"
  printf '%s\n' '# Task' "## Captain's intent" '{TASK}' '' '## Firstmate spec' 'x' > "$home/data/task-a/brief.md"
  out=$(spawn_ship "$case_dir" task-a "$case_dir/unused") || rc=$?
  [ "$rc" -ne 0 ] && [ "$rc" -ne "$DEFER_EXIT" ] || fail "an invalid brief did not fail after admission (exit $rc): $out"
  assert_contains "$out" "still contains {TASK}" "the spawn did not fail where expected"
  assert_absent "$home/state/task-a.meta" "the failed spawn left a record"
  rc=0
  out=$(spawn_ship "$case_dir" task-b) || rc=$?
  expect_code 0 "$rc" "a failed spawn kept holding the only place: $out"
  pass "a spawn that fails after admission leaves no record and holds no place"
}

test_unreadable_declaration_refuses_every_spawn() {
  local case_dir home out rc label body before worktrees
  case_dir=$(make_case unreadable task-c)
  home="$case_dir/home"
  while IFS='|' read -r label body; do
    [ -n "$label" ] || continue
    printf '%b' "$body" > "$home/config/project-capacity"
    before=$(call_count "$case_dir")
    worktrees=$(worktree_list "$case_dir")
    rc=0
    out=$(spawn_ship "$case_dir" task-c "$case_dir/unused") || rc=$?
    expect_code 1 "$rc" "$label: an unreadable declaration did not refuse: $out"
    assert_contains "$out" "the project capacity declaration is unreadable" "$label: the refusal did not name the declaration"
    assert_nothing_created "$case_dir" "$home" task-c "$before" "$worktrees"
  done <<'ROWS'
missing capacity|project\n
zero capacity|project 0\n
non-numeric capacity|other-project two\n
trailing text|project 2 # suite\n
named twice|project 2\nproject 3\n
ROWS
  rm -f "$home/config/project-capacity"
  mkdir "$home/config/project-capacity"
  rc=0
  out=$(spawn_ship "$case_dir" task-c "$case_dir/unused") || rc=$?
  expect_code 1 "$rc" "a declaration that is not a file did not refuse: $out"
  pass "an unreadable declaration refuses every fresh spawn rather than guessing the limit"
}

test_batch_reports_a_deferred_pair() {
  local case_dir home out rc=0
  case_dir=$(make_case batch task-c)
  home="$case_dir/home"
  declare_capacity "$home" "project 1"
  write_live "$home" live-a "$case_dir/project"
  out=$(run_spawn "$case_dir" "$home" "$case_dir/unused" "task-c=$case_dir/project" --mode no-mistakes --yolo off) || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "a batch whose only pair was deferred did not exit with the deferral status: $out"
  assert_contains "$out" "batch: DEFERRED task-c ($case_dir/project) - its project is at capacity, so it stays queued" \
    "the batch did not report the deferral"
  assert_not_contains "$out" "batch: FAILED" "the batch reported a deferral as a failure"
  pass "a batch reports a capacity deferral as deferred, not failed"
}

# Orca owns its own worktrees and never takes the Treehouse allocation lock, so
# a declared capacity is what makes an Orca spawn take the shared project lock,
# even from an uncapped clone of a capped origin whose worker would still hold a
# place: it refuses while another holder has it, and defers at capacity before
# asking Orca for anything but its runtime status.
test_orca_spawn_is_admitted_under_the_shared_project_lock() {
  local case_dir home out out2 rc=0 rc2 holder i
  command -v node >/dev/null 2>&1 || {
    printf 'ok - skipped the Orca capacity case (node, which the Orca status check needs, is not installed)\n'
    return 0
  }
  case_dir=$(make_case orca task-o)
  home="$case_dir/home"
  cat > "$case_dir/fakebin/orca" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = status ]; then
  printf '{"ok":true,"result":{"runtime":{"reachable":true,"state":"ready"}}}\n'
  exit 0
fi
printf 'orca %s\n' "$*" >> "$FM_FAKE_CALL_LOG"
exit 1
SH
  chmod +x "$case_dir/fakebin/orca"
  git clone -q "$(git -C "$case_dir/project" remote get-url origin)" "$case_dir/project-2"
  declare_capacity "$home" "project 1"

  # shellcheck disable=SC2016 # expanded by the holder's own shell
  FM_HOME="$home" FM_STATE_OVERRIDE='' bash -c '
    . "$1/bin/fm-wake-lib.sh"
    lock=$(fm_treehouse_project_lock_path "$2") || exit 1
    fm_lock_try_acquire "$lock" || exit 1
    : > "$3.held"
    while [ ! -f "$3.release" ]; do sleep 0.05; done
    fm_lock_release "$lock"
  ' _ "$ROOT" "$case_dir/project" "$case_dir/holder" &
  holder=$!
  i=0
  while [ ! -f "$case_dir/holder.held" ]; do
    i=$((i + 1))
    [ "$i" -lt 200 ] || fail "the lock holder never took the project lock"
    sleep 0.05
  done
  out=$(run_spawn "$case_dir" "$home" "$case_dir/unused" task-o "$case_dir/project" \
    --backend orca --mode no-mistakes --yolo off) || rc=$?
  rc2=0
  out2=$(run_spawn "$case_dir" "$home" "$case_dir/unused" task-o "$case_dir/project-2" \
    --backend orca --mode no-mistakes --yolo off) || rc2=$?
  : > "$case_dir/holder.release"
  wait "$holder" || true
  expect_code 1 "$rc" "an Orca spawn ignored a held project lock: $out"
  assert_contains "$out" "another spawn or cleanup holds the shared project lock for $case_dir/project; refusing to race its capacity admission" \
    "the Orca spawn did not refuse on the shared project lock"
  expect_code 1 "$rc2" "an Orca spawn from an uncapped same-origin clone ignored the held project lock: $out2"
  assert_contains "$out2" "another spawn or cleanup holds the shared project lock for $case_dir/project-2" \
    "the uncapped same-origin clone's Orca spawn did not refuse on the shared project lock"
  assert_absent "$home/state/task-o.meta" "the uncapped clone's Orca spawn published a record while the lock was held"
  assert_no_grep "orca " "$case_dir/calls.log" "the Orca spawn asked Orca for more than its runtime status"

  write_live "$home" live-a "$case_dir/project"
  rc=0
  out=$(run_spawn "$case_dir" "$home" "$case_dir/unused" task-o "$case_dir/project" \
    --backend orca --mode no-mistakes --yolo off) || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "an Orca spawn beyond capacity was not deferred: $out"
  assert_absent "$home/state/task-o.meta" "the deferred Orca spawn published a record"
  assert_no_grep "orca " "$case_dir/calls.log" "the deferred Orca spawn created an Orca worktree"
  pass "an Orca spawn takes the shared project lock whenever a same-origin clone is capped and defers before creating anything"
}

test_undeclared_capacity_keeps_dispatch_uncapped
test_available_capacity_admits_the_worker
test_exhausted_capacity_defers_without_leaving_anything_behind
test_spaced_project_name_is_declared
test_hash_prefixed_project_name_is_declared
test_symlinked_home_counts_each_worker_once
test_release_frees_a_place
test_restart_does_not_count_its_own_record
test_occupancy_counts_only_this_projects_workers
test_capacity_is_shared_by_every_local_home
test_unreadable_holders_refuse_admission
test_concurrent_spawns_cannot_both_take_the_last_place
test_failed_spawn_after_admission_holds_no_place
test_unreadable_declaration_refuses_every_spawn
test_batch_reports_a_deferred_pair
test_orca_spawn_is_admitted_under_the_shared_project_lock
