#!/usr/bin/env bash
# Behavior tests for the standalone First Mate Lite public interface.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-lite)
LITE_HOME="$TMP_ROOT/home"
XDG_DATA_HOME="$TMP_ROOT/xdg"
FULL_HOME="$TMP_ROOT/full-firstmate-home"
INSTALL_DIR="$LITE_HOME/.local/bin"
SOURCE_REPO="$TMP_ROOT/storefront"
REMOTE_SOURCE="$TMP_ROOT/payments-source"
REMOTE_BARE="$TMP_ROOT/payments.git"
TREEHOUSE_CALLED="$TMP_ROOT/treehouse-called"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")

mkdir -p "$LITE_HOME" "$XDG_DATA_HOME" "$FULL_HOME"
printf 'full firstmate sentinel\n' > "$FULL_HOME/sentinel"
cat > "$FAKEBIN/treehouse" <<EOF
#!/usr/bin/env bash
touch '$TREEHOUSE_CALLED'
exit 97
EOF
chmod +x "$FAKEBIN/treehouse"

export HOME="$LITE_HOME"
export XDG_DATA_HOME
export FM_HOME="$FULL_HOME"
export PATH="$FAKEBIN:$INSTALL_DIR:$PATH"
fm_git_identity

test_install() {
  local count out
  out=$("$ROOT/bin/fm-lite-install.sh") \
    || fail "fm-lite installer failed: $out"
  assert_contains "$out" "Installed fm-lite to $INSTALL_DIR/fm-lite" \
    "installer did not report the installed executable"
  assert_present "$INSTALL_DIR/fm-lite" "installer did not create fm-lite"
  [ -x "$INSTALL_DIR/fm-lite" ] || fail "installed fm-lite is not executable"
  count=$(find "$INSTALL_DIR" -type f | wc -l | tr -d ' ')
  [ "$count" = 1 ] || fail "installer should install one file, found $count"
  pass "fm-lite installs as one standalone executable"
}

test_projects() {
  local out registered managed registry_lines
  fm_git_init_commit "$SOURCE_REPO"
  fm_git_init_commit "$REMOTE_SOURCE"
  git clone --quiet --bare "$REMOTE_SOURCE" "$REMOTE_BARE"

  out=$(fm-lite project storefront "$SOURCE_REPO") \
    || fail "could not register existing repository: $out"
  registered=$(fm-lite project storefront) \
    || fail "could not resolve existing registered repository"
  [ "$registered" = "$(cd "$SOURCE_REPO" && pwd -P)" ] \
    || fail "project lookup returned '$registered'"

  fm-lite project payments "file://$REMOTE_BARE" >/dev/null \
    || fail "could not register URL-cloned repository"
  managed=$(fm-lite project payments) \
    || fail "could not resolve URL-cloned repository"
  [ "$managed" = "$XDG_DATA_HOME/firstmate-lite/projects/payments" ] \
    || fail "managed clone used unexpected path '$managed'"
  git -C "$managed" rev-parse HEAD >/dev/null 2>&1 \
    || fail "managed project is not a usable clone"

  registry_lines=$(wc -l < "$XDG_DATA_HOME/firstmate-lite/projects.tsv" | tr -d ' ')
  [ "$registry_lines" = 2 ] || fail "multi-repo registry has $registry_lines entries"
  pass "fm-lite registers existing and URL-cloned repositories in XDG data"
}

test_new_task() {
  local task_dir top branch context
  task_dir=$(fm-lite new storefront improve-checkout) \
    || fail "could not create task worktree"
  top=$(git -C "$task_dir" rev-parse --show-toplevel) \
    || fail "task directory is not a Git worktree"
  [ "$top" = "$task_dir" ] || fail "task top-level '$top' differs from '$task_dir'"
  [ "$top" != "$(cd "$SOURCE_REPO" && pwd -P)" ] \
    || fail "task was created in the registered primary checkout"
  branch=$(git -C "$task_dir" branch --show-current)
  [ "$branch" = feature/improve-checkout ] \
    || fail "task uses unexpected branch '$branch'"

  context="$task_dir/.firstmate/tasks/improve-checkout"
  assert_present "$context/brief.md" "task brief was not generated"
  assert_present "$context/decisions.md" "decision record was not generated"
  assert_present "$context/verification.md" "verification record was not generated"
  assert_grep '## Task description' "$context/brief.md" "brief lacks task description"
  assert_grep '## Acceptance criteria' "$context/brief.md" "brief lacks acceptance criteria"
  assert_grep '## Constraints' "$context/brief.md" "brief lacks constraints"
  assert_grep '## Delivery definition' "$context/brief.md" "brief lacks delivery definition"
  assert_no_grep 'supervision' "$context/brief.md" "Lite brief contains supervision prose"
  assert_no_grep 'watcher' "$context/brief.md" "Lite brief contains watcher prose"
  assert_no_grep 'status report' "$context/brief.md" "Lite brief contains status-report prose"
  assert_no_grep 'crewmate lifecycle' "$context/brief.md" "Lite brief contains lifecycle prose"
  printf '%s\n' "$task_dir" > "$TMP_ROOT/task-dir"
  pass "fm-lite creates an isolated worktree and complete task context"
}

test_cleanup_refusals() {
  local task_dir exclude_file ignored_file out rc
  task_dir=$(cat "$TMP_ROOT/task-dir")

  set +e
  out=$(fm-lite clean storefront improve-checkout 2>&1); rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "cleanup accepted untracked task context"
  assert_contains "$out" "uncommitted, untracked, or ignored files" \
    "dirty cleanup refusal did not explain the unsafe state"

  printf '\n- [x] Checkout copy is updated.\n' \
    >> "$task_dir/.firstmate/tasks/improve-checkout/brief.md"
  printf '\n| Keep context in the feature branch | Preserve review history | 2026-08-20 |\n' \
    >> "$task_dir/.firstmate/tasks/improve-checkout/decisions.md"
  printf '%s\n' '' "- \`git diff --check\` passed." \
    >> "$task_dir/.firstmate/tasks/improve-checkout/verification.md"
  printf '\nImplemented checkout copy.\n' >> "$task_dir/README.md"
  git -C "$task_dir" add README.md .firstmate
  git -C "$task_dir" commit -qm 'improve checkout'

  set +e
  out=$(fm-lite clean storefront improve-checkout 2>&1); rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "cleanup accepted an unmerged task branch"
  assert_contains "$out" "is not contained in the registered clone's HEAD" \
    "unmerged cleanup refusal did not explain the unsafe state"
  assert_present "$task_dir" "refused cleanup removed the task worktree"

  git -C "$SOURCE_REPO" merge --ff-only feature/improve-checkout >/dev/null \
    || fail "could not prepare the ignored-file cleanup refusal"
  ignored_file="$task_dir/local-build.cache"
  exclude_file=$(git -C "$task_dir" rev-parse --git-path info/exclude)
  printf 'local build output\n' > "$ignored_file"
  printf 'local-build.cache\n' >> "$exclude_file"
  set +e
  out=$(fm-lite clean storefront improve-checkout 2>&1); rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "cleanup accepted an ignored task artifact"
  assert_contains "$out" "uncommitted, untracked, or ignored files" \
    "ignored-file cleanup refusal did not explain the unsafe state"
  assert_present "$ignored_file" "refused cleanup deleted an ignored task artifact"
  rm "$ignored_file"
  pass "fm-lite cleanup refuses dirty, ignored, and unmerged task work"
}

test_merge_and_clean() {
  local task_dir context tracked
  task_dir=$(cat "$TMP_ROOT/task-dir")
  context="$SOURCE_REPO/.firstmate/tasks/improve-checkout"
  assert_present "$context/brief.md" "merged branch lost its task brief"
  assert_present "$context/decisions.md" "merged branch lost its decisions"
  assert_present "$context/verification.md" "merged branch lost its verification"
  tracked=$(git -C "$SOURCE_REPO" ls-files '.firstmate/tasks/improve-checkout/*' | wc -l | tr -d ' ')
  [ "$tracked" = 3 ] || fail "merged branch tracks $tracked context files instead of 3"

  fm-lite clean storefront improve-checkout \
    || fail "cleanup rejected merged, clean task work"
  assert_absent "$task_dir" "cleanup left the task worktree on disk"
  git -C "$SOURCE_REPO" show-ref --verify --quiet refs/heads/feature/improve-checkout \
    && fail "cleanup left the merged local feature branch"
  assert_grep 'full firstmate sentinel' "$FULL_HOME/sentinel" \
    "Lite modified the full Firstmate home"
  assert_absent "$TREEHOUSE_CALLED" "Lite invoked treehouse"
  pass "fm-lite carries context through the feature merge and cleans safely"
}

test_command_surface() {
  local help out rc usages
  help=$(fm-lite --help) || fail "fm-lite --help failed"
  usages=$(printf '%s\n' "$help" | grep -Ec '^  fm-lite (project|new|clean)')
  [ "$usages" = 3 ] || fail "help exposes $usages command families instead of 3"

  set +e
  out=$(fm-lite list 2>&1); rc=$?
  set -e
  expect_code 1 "$rc" "unknown command should fail"
  assert_contains "$out" "expected project, new, or clean" \
    "unknown command error does not name the complete command surface"

  set +e
  out=$(fm-lite new storefront '../escape' 2>&1); rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "invalid task name was accepted"
  assert_contains "$out" "must start with an ASCII letter or digit" \
    "invalid task name failure was unclear"
  pass "fm-lite validates its intentionally small command surface"
}

test_install
test_projects
test_new_task
test_cleanup_refusals
test_merge_and_clean
test_command_surface

printf '# all fm-lite tests passed\n'
