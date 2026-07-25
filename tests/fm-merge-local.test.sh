#!/usr/bin/env bash
# Tests for bin/fm-merge-local.sh's working-tree collision guard: the approved
# local-only landing path must refuse only where the fast-forward could actually
# destroy uncommitted operator work, never on uncommitted entries it provably
# cannot touch. A blanket "dirty tree refuses" check is self-deadlocking - it
# blocks the very commit that would settle those entries - so precision here is
# what keeps the guard usable, and refusing every genuine collision is what keeps
# it safe.
#
# Matrix:
#   refuses  (a) modified path the fast-forward changes
#   refuses  (b) modified path the fast-forward removes
#   refuses  (c) untracked file at a path the fast-forward adds (name with spaces)
#   refuses  (d) untracked file nested inside an otherwise untracked directory,
#                which a collapsed status listing would hide
#   refuses  (e) untracked file sitting where the fast-forward needs a directory
#   refuses  (f) untracked files under a path the fast-forward replaces with a file
#   refuses  (g) either endpoint of a staged rename that the fast-forward removes
#   refuses  (h) both endpoints of an INCOMING rename, whose diff record orders
#                old-then-new, the reverse of git status
#   refuses  (i) the destination of an INCOMING copy, when the project has asked
#                git for copy detection
#   refuses  (j) an unresolved merge conflict (state it cannot classify)
#   refuses  (k) a merge left in progress with its resolution staged, in a linked
#                worktree, where the git dir is not <project>/.git
#   refuses  (l) a cherry-pick left in progress with its resolution staged
#   refuses  (m) an unrecognized git status code
#   proceeds (n) untracked file at a path the fast-forward never touches
#   proceeds (o) modified path the fast-forward never touches
#   proceeds (p) ignored file, even at a path the fast-forward adds
#   proceeds (q) clean tree
#   proceeds (r) a staged rename at paths the fast-forward never touches, proving
#                the rename's second NUL field is consumed and not misread as the
#                next record's status code
#   regression (s) the observed deadlock: two untracked operator files plus one
#                modified tracked pointer that the incoming commit removes from
#                the index. It must refuse, naming only the pointer, and must
#                merge once that single path is settled - the cure can no longer
#                be locked behind the symptom.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

MERGE_LOCAL="$ROOT/bin/fm-merge-local.sh"
TMP_ROOT=$(fm_test_tmproot fm-merge-local-tests)
TASK_ID=local-1
BRANCH="fm/$TASK_ID"
REAL_GIT=$(command -v git)

# A local-only task whose project is a one-commit repo on main, with the task
# branch checked out for the caller to build the incoming commits on. Echoes the
# case dir; "$case_dir/project" is the project checkout fm-merge-local writes to.
#
# layout=worktree instead makes that project checkout a LINKED worktree of a repo
# beside it, so its .git is a pointer file and its git dir is not
# "$proj/.git" - the layout where a hardcoded git-dir path silently never fires.
make_case() {
  local name=$1 layout=${2:-plain} case_dir proj repo
  case_dir="$TMP_ROOT/$name"
  proj="$case_dir/project"
  repo="$proj"
  if [ "$layout" = worktree ]; then
    repo="$case_dir/repo"
  fi
  mkdir -p "$case_dir/state" "$repo/docs"
  git -C "$repo" init -q
  # Set the default branch without relying on `git init -b` (git 2.28+).
  git -C "$repo" symbolic-ref HEAD refs/heads/main
  git -C "$repo" config user.name 'Firstmate Tests'
  git -C "$repo" config user.email 'tests@example.invalid'
  printf 'tracked\n' > "$repo/tracked.txt"
  printf 'pointer\n' > "$repo/runtime-pointer.json"
  printf 'long enough contents to pair as a rename\n' > "$repo/docs/notes.md"
  printf 'ignored-*\n' > "$repo/.gitignore"
  git -C "$repo" add -A
  git -C "$repo" commit -qm base
  if [ "$layout" = worktree ]; then
    # Park the repo's own worktree on a branch nobody else wants, so main is free
    # to be checked out in the linked worktree the merge actually targets.
    git -C "$repo" checkout -q -b scratch
    git -C "$repo" worktree add -q "$proj" main
  fi
  fm_write_meta "$case_dir/state/$TASK_ID.meta" \
    "window=fm-$TASK_ID" \
    "worktree=$case_dir/wt" \
    "project=$proj" \
    "kind=ship" \
    "mode=local-only"
  # Keep the shared watcher-liveness banner quiet: this suite exercises the merge
  # guard, not supervision staleness.
  touch "$case_dir/state/.last-watcher-beat"
  git -C "$proj" checkout -q -b "$BRANCH"
  printf '%s\n' "$case_dir"
}

# commit_in <proj> <message> [path...]: stage the named paths (or everything when
# none are named) and commit. Explicit paths matter for a case that has already
# staged a `git rm --cached` removal, which `add -A` would undo.
commit_in() {
  local proj=$1 msg=$2
  shift 2
  if [ "$#" -gt 0 ]; then
    git -C "$proj" add -- "$@"
  else
    git -C "$proj" add -A
  fi
  git -C "$proj" commit -qm "$msg"
}

run_merge_local() {
  local case_dir=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  PATH="${FM_TEST_PATH_PREFIX:-}${FM_TEST_PATH_PREFIX:+:}$PATH" \
    "$MERGE_LOCAL" "$TASK_ID" "$@"
}

# Run the merge and capture its streams; echoes nothing, sets RC.
attempt_merge() {
  local case_dir=$1
  set +e
  run_merge_local "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  RC=$?
  set -e
}

assert_merged() {
  local proj=$1 label=$2
  [ "$(git -C "$proj" rev-parse main)" = "$(git -C "$proj" rev-parse "$BRANCH")" ] \
    || fail "$label: expected main to be fast-forwarded to $BRANCH"
}

assert_not_merged() {
  local proj=$1 label=$2
  [ "$(git -C "$proj" rev-parse main)" != "$(git -C "$proj" rev-parse "$BRANCH")" ] \
    || fail "$label: main was merged despite a refusal"
}

# --- refuses ----------------------------------------------------------------

test_refuses_modified_path_the_merge_changes() {
  local case_dir proj
  case_dir=$(make_case refuse-modified-changed)
  proj="$case_dir/project"
  printf 'incoming\n' > "$proj/tracked.txt"
  commit_in "$proj" 'change tracked.txt'
  git -C "$proj" checkout -q main
  printf 'operator edit\n' > "$proj/tracked.txt"

  attempt_merge "$case_dir"

  expect_code 1 "$RC" "refuse-modified-changed: expected a refusal"
  assert_grep 'tracked.txt - uncommitted changes here, and this merge changes it' \
    "$case_dir/stderr" "refuse-modified-changed: refusal did not name the colliding path and action"
  assert_not_merged "$proj" refuse-modified-changed
  assert_grep 'operator edit' "$proj/tracked.txt" \
    "refuse-modified-changed: the operator's uncommitted edit was not preserved"
  pass "fm-merge-local refuses a modified path the fast-forward changes"
}

test_refuses_modified_path_the_merge_removes() {
  local case_dir proj
  case_dir=$(make_case refuse-modified-removed)
  proj="$case_dir/project"
  git -C "$proj" rm -q docs/notes.md
  commit_in "$proj" 'remove docs/notes.md'
  git -C "$proj" checkout -q main
  printf 'operator edit\n' >> "$proj/docs/notes.md"

  attempt_merge "$case_dir"

  expect_code 1 "$RC" "refuse-modified-removed: expected a refusal"
  assert_grep 'docs/notes.md - uncommitted changes here, and this merge removes it' \
    "$case_dir/stderr" "refuse-modified-removed: refusal did not report the incoming deletion"
  assert_not_merged "$proj" refuse-modified-removed
  assert_grep 'operator edit' "$proj/docs/notes.md" \
    "refuse-modified-removed: the operator's uncommitted edit was not preserved"
  pass "fm-merge-local refuses a modified path the fast-forward removes"
}

test_refuses_untracked_file_at_an_added_path() {
  local case_dir proj
  case_dir=$(make_case refuse-untracked-added)
  proj="$case_dir/project"
  printf 'theirs\n' > "$proj/docs/Knowledge Graphs.pdf"
  commit_in "$proj" 'add a document'
  git -C "$proj" checkout -q main
  printf 'the operators own copy\n' > "$proj/docs/Knowledge Graphs.pdf"

  attempt_merge "$case_dir"

  expect_code 1 "$RC" "refuse-untracked-added: expected a refusal"
  assert_grep 'docs/Knowledge Graphs.pdf - untracked file here, and this merge creates a file at that path' \
    "$case_dir/stderr" "refuse-untracked-added: refusal did not name the spaced untracked path"
  assert_not_merged "$proj" refuse-untracked-added
  assert_grep 'the operators own copy' "$proj/docs/Knowledge Graphs.pdf" \
    "refuse-untracked-added: the operator's untracked file was overwritten"
  pass "fm-merge-local refuses an untracked file at a path the fast-forward adds"
}

test_refuses_untracked_file_inside_an_untracked_directory() {
  local case_dir proj
  case_dir=$(make_case refuse-untracked-in-new-dir)
  proj="$case_dir/project"
  mkdir -p "$proj/reports"
  printf 'theirs\n' > "$proj/reports/Quarterly Review.pdf"
  commit_in "$proj" 'add a report in a new directory'
  git -C "$proj" checkout -q main
  # The whole directory is untracked here. git status collapses that to
  # "reports/" unless untracked files are listed individually, which would hide
  # the collision at the nested path the fast-forward actually adds.
  mkdir -p "$proj/reports"
  printf 'the operators own copy\n' > "$proj/reports/Quarterly Review.pdf"

  attempt_merge "$case_dir"

  expect_code 1 "$RC" "refuse-untracked-in-new-dir: expected a refusal"
  assert_grep 'reports/Quarterly Review.pdf - untracked file here, and this merge creates a file at that path' \
    "$case_dir/stderr" "refuse-untracked-in-new-dir: the collapsed untracked directory hid the nested collision"
  assert_not_merged "$proj" refuse-untracked-in-new-dir
  assert_grep 'the operators own copy' "$proj/reports/Quarterly Review.pdf" \
    "refuse-untracked-in-new-dir: the operator's untracked file was overwritten"
  pass "fm-merge-local sees an untracked file nested inside an otherwise untracked directory"
}

test_refuses_untracked_file_where_the_merge_needs_a_directory() {
  local case_dir proj
  case_dir=$(make_case refuse-untracked-file-vs-dir)
  proj="$case_dir/project"
  mkdir -p "$proj/reports"
  printf 'theirs\n' > "$proj/reports/Quarterly Review.pdf"
  commit_in "$proj" 'add a report in a new directory'
  git -C "$proj" checkout -q main
  # An untracked FILE sitting at a leading component of the incoming path. No
  # exact path matches, but the two cannot both exist, and git refuses.
  printf 'the operators own notes\n' > "$proj/reports"

  attempt_merge "$case_dir"

  expect_code 1 "$RC" "refuse-untracked-file-vs-dir: expected a refusal"
  assert_grep "reports - untracked file here, and this merge needs that path to be a directory to create 'reports/Quarterly Review.pdf'" \
    "$case_dir/stderr" "refuse-untracked-file-vs-dir: the file-where-a-directory-is-needed collision was not named"
  assert_not_merged "$proj" refuse-untracked-file-vs-dir
  assert_grep 'the operators own notes' "$proj/reports" \
    "refuse-untracked-file-vs-dir: the operator's untracked file was disturbed"
  pass "fm-merge-local names an untracked file sitting where the fast-forward needs a directory"
}

test_refuses_untracked_files_under_a_path_the_merge_turns_into_a_file() {
  local case_dir proj
  case_dir=$(make_case refuse-untracked-dir-vs-file)
  proj="$case_dir/project"
  printf 'theirs\n' > "$proj/notes"
  commit_in "$proj" 'add a notes file'
  git -C "$proj" checkout -q main
  # The mirror shape: the operator's untracked files live UNDER a path the
  # fast-forward replaces with a blob.
  mkdir -p "$proj/notes"
  printf 'operator draft\n' > "$proj/notes/draft.md"

  attempt_merge "$case_dir"

  expect_code 1 "$RC" "refuse-untracked-dir-vs-file: expected a refusal"
  assert_grep "notes/draft.md - untracked file here, and this merge creates a file at 'notes', replacing the directory holding it" \
    "$case_dir/stderr" "refuse-untracked-dir-vs-file: the directory-where-a-file-is-created collision was not named"
  assert_not_merged "$proj" refuse-untracked-dir-vs-file
  assert_grep 'operator draft' "$proj/notes/draft.md" \
    "refuse-untracked-dir-vs-file: the operator's untracked file was disturbed"
  pass "fm-merge-local names untracked files under a path the fast-forward replaces with a file"
}

test_refuses_rename_endpoint_the_merge_removes() {
  local case_dir proj
  case_dir=$(make_case refuse-rename-endpoint)
  proj="$case_dir/project"
  git -C "$proj" rm -q docs/notes.md
  commit_in "$proj" 'remove docs/notes.md'
  git -C "$proj" checkout -q main
  # A staged rename makes BOTH endpoints uncommitted. The fast-forward removes
  # the source, so the operator's staged rename is at risk.
  git -C "$proj" mv docs/notes.md 'docs/renamed notes.md'

  attempt_merge "$case_dir"

  expect_code 1 "$RC" "refuse-rename-endpoint: expected a refusal"
  assert_grep 'docs/notes.md - uncommitted changes here, and this merge removes it' \
    "$case_dir/stderr" "refuse-rename-endpoint: the rename's source endpoint was not treated as uncommitted"
  assert_not_merged "$proj" refuse-rename-endpoint
  pass "fm-merge-local refuses when a staged rename's endpoint is removed by the fast-forward"
}

test_refuses_both_endpoints_of_an_incoming_rename() {
  local case_dir proj
  case_dir=$(make_case refuse-incoming-rename)
  proj="$case_dir/project"
  # Rename detection is on by default, so an incoming rename arrives as a single
  # R record whose two path fields are old-then-new - the REVERSE of the
  # new-then-old order git status uses. Both endpoints are dirty here, so the
  # refusal must name the source as removed and the destination as created; if
  # the reader's old/new assumption were inverted, both assertions flip.
  git -C "$proj" mv docs/notes.md 'docs/crewmate notes.md'
  commit_in "$proj" 'rename docs/notes.md'
  git -C "$proj" checkout -q main
  printf 'operator edit\n' >> "$proj/docs/notes.md"
  printf 'the operators own copy\n' > "$proj/docs/crewmate notes.md"

  attempt_merge "$case_dir"

  expect_code 1 "$RC" "refuse-incoming-rename: expected a refusal"
  assert_grep 'docs/notes.md - uncommitted changes here, and this merge removes it' \
    "$case_dir/stderr" "refuse-incoming-rename: the incoming rename's source was not reported as removed"
  assert_grep 'docs/crewmate notes.md - untracked file here, and this merge creates a file at that path' \
    "$case_dir/stderr" "refuse-incoming-rename: the incoming rename's destination was not reported as created"
  assert_not_merged "$proj" refuse-incoming-rename
  assert_grep 'the operators own copy' "$proj/docs/crewmate notes.md" \
    "refuse-incoming-rename: the operator's untracked file was overwritten"
  pass "fm-merge-local reads an incoming rename's endpoints in the incoming diff's own field order"
}

test_refuses_untracked_file_at_an_incoming_copy_destination() {
  local case_dir proj
  case_dir=$(make_case refuse-incoming-copy)
  proj="$case_dir/project"
  # Copy detection is off unless the project asks for it, and then a C record
  # arrives source-first like R. Only the destination is created, so only it can
  # collide - an inverted reader would name the untouched source instead.
  git -C "$proj" config diff.renames copies
  cp "$proj/docs/notes.md" "$proj/docs/notes copy.md"
  printf 'crewmate line\n' >> "$proj/docs/notes.md"
  commit_in "$proj" 'copy docs/notes.md'
  git -C "$proj" checkout -q main
  printf 'the operators own copy\n' > "$proj/docs/notes copy.md"

  attempt_merge "$case_dir"

  expect_code 1 "$RC" "refuse-incoming-copy: expected a refusal"
  assert_grep 'docs/notes copy.md - untracked file here, and this merge creates a file at that path' \
    "$case_dir/stderr" "refuse-incoming-copy: the incoming copy's destination was not reported as created"
  assert_not_merged "$proj" refuse-incoming-copy
  assert_grep 'the operators own copy' "$proj/docs/notes copy.md" \
    "refuse-incoming-copy: the operator's untracked file was overwritten"
  pass "fm-merge-local reads an incoming copy's destination from the incoming diff"
}

test_refuses_unresolved_conflict() {
  local case_dir proj
  case_dir=$(make_case refuse-unresolved-conflict)
  proj="$case_dir/project"
  git -C "$proj" checkout -q main
  printf 'base\n' > "$proj/conflict.txt"
  commit_in "$proj" 'add conflict.txt'
  git -C "$proj" branch sideline
  printf 'main side\n' > "$proj/conflict.txt"
  commit_in "$proj" 'main side'
  git -C "$proj" checkout -q sideline
  printf 'other side\n' > "$proj/conflict.txt"
  commit_in "$proj" 'other side'
  git -C "$proj" checkout -q main
  # Rebuild the task branch on top of main so the fast-forward itself stays valid
  # and the conflict is the only thing the guard can object to.
  git -C "$proj" branch -f "$BRANCH" main
  git -C "$proj" checkout -q "$BRANCH"
  printf 'incoming\n' > "$proj/tracked.txt"
  commit_in "$proj" 'change tracked.txt'
  git -C "$proj" checkout -q main
  git -C "$proj" merge sideline >/dev/null 2>&1 \
    && fail "refuse-unresolved-conflict: fixture merge was expected to conflict"

  attempt_merge "$case_dir"

  expect_code 1 "$RC" "refuse-unresolved-conflict: expected a refusal"
  assert_grep 'cannot classify the state of' "$case_dir/stderr" \
    "refuse-unresolved-conflict: refusal was not the unclassifiable-state refusal"
  assert_grep "unresolved merge conflict at 'conflict.txt'" "$case_dir/stderr" \
    "refuse-unresolved-conflict: refusal did not name the conflicted path"
  assert_not_merged "$proj" refuse-unresolved-conflict
  pass "fm-merge-local refuses an unresolved merge conflict rather than classifying it as ordinary dirt"
}

# Build a conflicting `sideline` branch and rebuild the task branch on top of the
# advanced main, so the fast-forward itself stays valid and the half-finished
# operation is the only thing the guard can object to. The incoming commit only
# touches tracked.txt, which no resolution below goes near - so nothing but the
# in-progress sentinel can produce a refusal.
prepare_conflicting_sideline() {
  local proj=$1
  git -C "$proj" checkout -q main
  git -C "$proj" branch sideline
  printf 'main side\n' >> "$proj/docs/notes.md"
  commit_in "$proj" 'main side'
  git -C "$proj" checkout -q sideline
  printf 'other side\n' >> "$proj/docs/notes.md"
  commit_in "$proj" 'other side'
  git -C "$proj" checkout -q main
  git -C "$proj" branch -f "$BRANCH" main
  git -C "$proj" checkout -q "$BRANCH"
  printf 'incoming\n' > "$proj/tracked.txt"
  commit_in "$proj" 'change tracked.txt'
  git -C "$proj" checkout -q main
}

test_refuses_in_progress_merge_in_a_linked_worktree() {
  local case_dir proj
  case_dir=$(make_case refuse-in-progress-merge worktree)
  proj="$case_dir/project"
  prepare_conflicting_sideline "$proj"
  git -C "$proj" merge sideline >/dev/null 2>&1 \
    && fail "refuse-in-progress-merge: fixture merge was expected to conflict"
  # Staging the resolution without committing hides the merge from git status:
  # the entry becomes a plain 'M ', so only MERGE_HEAD still says an operation is
  # open - and in this linked worktree it does not live at "$proj/.git".
  git -C "$proj" add docs/notes.md
  assert_absent "$proj/.git/MERGE_HEAD" \
    "refuse-in-progress-merge: fixture is not a linked worktree, so it cannot pin git-dir resolution"

  attempt_merge "$case_dir"

  expect_code 1 "$RC" "refuse-in-progress-merge: expected a refusal"
  assert_grep 'cannot classify the state of' "$case_dir/stderr" \
    "refuse-in-progress-merge: refusal was not the unclassifiable-state refusal"
  assert_grep 'a merge is in progress here' "$case_dir/stderr" \
    "refuse-in-progress-merge: refusal did not name the half-finished merge"
  assert_grep 'git merge --abort' "$case_dir/stderr" \
    "refuse-in-progress-merge: refusal was not actionable"
  assert_not_merged "$proj" refuse-in-progress-merge
  pass "fm-merge-local refuses a merge left in progress, including in a linked worktree"
}

test_refuses_in_progress_cherry_pick() {
  local case_dir proj
  case_dir=$(make_case refuse-in-progress-cherry-pick)
  proj="$case_dir/project"
  prepare_conflicting_sideline "$proj"
  git -C "$proj" cherry-pick sideline >/dev/null 2>&1 \
    && fail "refuse-in-progress-cherry-pick: fixture cherry-pick was expected to conflict"
  git -C "$proj" add docs/notes.md

  attempt_merge "$case_dir"

  expect_code 1 "$RC" "refuse-in-progress-cherry-pick: expected a refusal"
  assert_grep 'a cherry-pick is in progress here' "$case_dir/stderr" \
    "refuse-in-progress-cherry-pick: refusal did not name the half-finished cherry-pick"
  assert_not_merged "$proj" refuse-in-progress-cherry-pick
  pass "fm-merge-local refuses a cherry-pick left in progress, not just a merge"
}

test_refuses_unrecognized_status_code() {
  local case_dir proj fakebin stderr
  case_dir=$(make_case refuse-unknown-code)
  proj="$case_dir/project"
  printf 'incoming\n' > "$proj/tracked.txt"
  commit_in "$proj" 'change tracked.txt'
  git -C "$proj" checkout -q main

  # git never emits an unknown status code, so shim just that one call. Every
  # other git invocation passes straight through to the real binary.
  fakebin=$(fm_fakebin "$case_dir")
  cat > "$fakebin/git" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do
  if [ "\$arg" = --porcelain=v1 ]; then
    printf 'XY strange.txt\0'
    exit 0
  fi
done
exec $REAL_GIT "\$@"
SH
  chmod +x "$fakebin/git"

  FM_TEST_PATH_PREFIX="$fakebin" attempt_merge "$case_dir"

  expect_code 1 "$RC" "refuse-unknown-code: expected a refusal"
  assert_grep "unrecognized git status code 'XY' at 'strange.txt'" "$case_dir/stderr" \
    "refuse-unknown-code: refusal did not report the unrecognized status code"
  assert_not_merged "$proj" refuse-unknown-code
  stderr=$(cat "$case_dir/stderr")
  assert_not_contains "$stderr" 'merged fm/' \
    "refuse-unknown-code: an unclassifiable status must not report a merge"
  pass "fm-merge-local refuses an unrecognized git status code instead of guessing"
}

# --- proceeds ---------------------------------------------------------------

test_proceeds_on_untracked_file_the_merge_never_touches() {
  local case_dir proj
  case_dir=$(make_case proceed-untracked-untouched)
  proj="$case_dir/project"
  printf 'incoming\n' > "$proj/tracked.txt"
  commit_in "$proj" 'change tracked.txt'
  git -C "$proj" checkout -q main
  printf 'the operators own copy\n' > "$proj/docs/Knowledge Graphs.pdf"

  attempt_merge "$case_dir"

  expect_code 0 "$RC" "proceed-untracked-untouched: expected the merge to proceed"
  assert_merged "$proj" proceed-untracked-untouched
  assert_grep 'the operators own copy' "$proj/docs/Knowledge Graphs.pdf" \
    "proceed-untracked-untouched: the untracked file was disturbed"
  pass "fm-merge-local proceeds past an untracked file the fast-forward never touches"
}

test_proceeds_on_modified_path_the_merge_never_touches() {
  local case_dir proj
  case_dir=$(make_case proceed-modified-untouched)
  proj="$case_dir/project"
  printf 'incoming\n' > "$proj/tracked.txt"
  commit_in "$proj" 'change tracked.txt'
  git -C "$proj" checkout -q main
  printf 'operator edit\n' >> "$proj/docs/notes.md"

  attempt_merge "$case_dir"

  expect_code 0 "$RC" "proceed-modified-untouched: expected the merge to proceed"
  assert_merged "$proj" proceed-modified-untouched
  assert_grep 'operator edit' "$proj/docs/notes.md" \
    "proceed-modified-untouched: the uncommitted edit was not preserved through the merge"
  pass "fm-merge-local proceeds past a modified path the fast-forward never touches"
}

test_proceeds_on_ignored_file() {
  local case_dir proj
  case_dir=$(make_case proceed-ignored)
  proj="$case_dir/project"
  # The incoming commit adds a path the project ignores, so this proves the guard
  # excludes ignored paths outright rather than merely finding them untouched.
  printf 'theirs\n' > "$proj/ignored-artifact.bin"
  git -C "$proj" add -f ignored-artifact.bin
  git -C "$proj" commit -qm 'track an otherwise-ignored artifact'
  git -C "$proj" checkout -q main
  printf 'local build output\n' > "$proj/ignored-artifact.bin"

  attempt_merge "$case_dir"

  expect_code 0 "$RC" "proceed-ignored: expected the merge to proceed"
  assert_merged "$proj" proceed-ignored
  pass "fm-merge-local proceeds past an ignored file, matching git's own handling"
}

test_proceeds_on_clean_tree() {
  local case_dir proj
  case_dir=$(make_case proceed-clean)
  proj="$case_dir/project"
  printf 'incoming\n' > "$proj/tracked.txt"
  commit_in "$proj" 'change tracked.txt'
  git -C "$proj" checkout -q main

  attempt_merge "$case_dir"

  expect_code 0 "$RC" "proceed-clean: expected the merge to proceed"
  assert_merged "$proj" proceed-clean
  assert_grep 'merged fm/' "$case_dir/stdout" "proceed-clean: no merge outcome was reported"
  pass "fm-merge-local proceeds on a clean tree"
}

test_proceeds_past_untouched_staged_rename() {
  local case_dir proj
  case_dir=$(make_case proceed-rename-untouched)
  proj="$case_dir/project"
  printf 'incoming\n' > "$proj/tracked.txt"
  commit_in "$proj" 'change tracked.txt'
  git -C "$proj" checkout -q main
  # A rename entry carries a second NUL field. If it were not consumed, the old
  # path would be misread as the next record's status code and the untracked file
  # after it would go unclassified - so this case also guards the parser.
  git -C "$proj" mv docs/notes.md 'docs/renamed notes.md'
  printf 'zz\n' > "$proj/zz untracked.txt"

  attempt_merge "$case_dir"

  expect_code 0 "$RC" "proceed-rename-untouched: expected the merge to proceed"
  assert_merged "$proj" proceed-rename-untouched
  assert_present "$proj/docs/renamed notes.md" \
    "proceed-rename-untouched: the staged rename was not preserved through the merge"
  pass "fm-merge-local parses a rename's second path field and proceeds when neither endpoint collides"
}

# --- regression -------------------------------------------------------------

test_regression_untracked_documents_plus_removed_pointer() {
  local case_dir proj stderr
  case_dir=$(make_case regression-deadlock)
  proj="$case_dir/project"
  # The commit that settles all three uncommitted entries: ignore rules plus one
  # index removal of the machine-local pointer.
  git -C "$proj" rm -q --cached runtime-pointer.json
  printf 'ignored-*\nruntime-pointer.json\n' > "$proj/.gitignore"
  commit_in "$proj" 'ignore local artifacts and drop the runtime pointer' .gitignore
  git -C "$proj" checkout -q main

  printf 'operator copy\n' > "$proj/docs/Knowledge Graphs.pdf"
  printf 'operator copy\n' > "$proj/docs/Second Paper.pdf"
  printf 'machine local drift\n' >> "$proj/runtime-pointer.json"

  attempt_merge "$case_dir"

  expect_code 1 "$RC" "regression-deadlock: the removed-and-modified pointer must still refuse"
  assert_grep 'runtime-pointer.json - uncommitted changes here, and this merge removes it' \
    "$case_dir/stderr" "regression-deadlock: refusal did not identify the one genuinely colliding path"
  stderr=$(cat "$case_dir/stderr")
  assert_not_contains "$stderr" 'Knowledge Graphs.pdf' \
    "regression-deadlock: an untracked document the merge never touches was reported as a collision"
  assert_not_contains "$stderr" 'Second Paper.pdf' \
    "regression-deadlock: an untracked document the merge never touches was reported as a collision"
  assert_not_merged "$proj" regression-deadlock

  # Settling that single named path is now enough: the commit that cures the
  # uncommitted entries is no longer locked behind them.
  git -C "$proj" checkout -- runtime-pointer.json
  attempt_merge "$case_dir"

  expect_code 0 "$RC" "regression-deadlock: the merge must land once the named path is settled"
  assert_merged "$proj" regression-deadlock
  assert_present "$proj/docs/Knowledge Graphs.pdf" \
    "regression-deadlock: the operator's untracked document was removed by the merge"
  assert_present "$proj/docs/Second Paper.pdf" \
    "regression-deadlock: the operator's untracked document was removed by the merge"
  pass "fm-merge-local names only the colliding path and lands once that path is settled"
}

test_refuses_modified_path_the_merge_changes
test_refuses_modified_path_the_merge_removes
test_refuses_untracked_file_at_an_added_path
test_refuses_untracked_file_inside_an_untracked_directory
test_refuses_untracked_file_where_the_merge_needs_a_directory
test_refuses_untracked_files_under_a_path_the_merge_turns_into_a_file
test_refuses_rename_endpoint_the_merge_removes
test_refuses_both_endpoints_of_an_incoming_rename
test_refuses_untracked_file_at_an_incoming_copy_destination
test_refuses_unresolved_conflict
test_refuses_in_progress_merge_in_a_linked_worktree
test_refuses_in_progress_cherry_pick
test_refuses_unrecognized_status_code
test_proceeds_on_untracked_file_the_merge_never_touches
test_proceeds_on_modified_path_the_merge_never_touches
test_proceeds_on_ignored_file
test_proceeds_on_clean_tree
test_proceeds_past_untouched_staged_rename
test_regression_untracked_documents_plus_removed_pointer
