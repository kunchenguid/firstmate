#!/usr/bin/env bash
# Regression coverage for fm-spawn's post-allocation Git common-directory
# ownership check.
#
# A shared Treehouse pool can contain slots from two clones of the same remote.
# The requested project path therefore cannot identify the clone family of the
# allocated worktree. This test drives the real spawn path with a deliberately
# mixed allocation and proves rejection happens before launch without changing
# any Git or filesystem state in the foreign slot.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-common-dir)

make_mixed_fakebin() {  # <dir>
  local fakebin
  fakebin=$(fm_fakebin "$1")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
if [ -n "${FM_FAKE_SEND_LOG:-}" ] && [ "${1:-}" = send-keys ]; then
  {
    printf 'tmux'
    for arg in "$@"; do printf '\x1f%s' "$arg"; done
    printf '\n'
  } >> "$FM_FAKE_SEND_LOG"
fi
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|set-window-option|send-keys|kill-window) exit 0 ;;
  new-window) printf '@mixed\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

snapshot_mixed_slot() {  # <slot> <foreign-clone>
  local slot=$1 foreign=$2 index
  index=$(git -C "$slot" rev-parse --git-path index)
  {
    printf '%s\n' '--- branch ---'
    git -C "$slot" symbolic-ref HEAD
    printf '%s\n' '--- HEAD ---'
    git -C "$slot" rev-parse HEAD
    printf '%s\n' '--- semantic index tree ---'
    git -C "$slot" write-tree
    printf '%s\n' '--- index bytes ---'
    git hash-object --no-filters "$index"
    printf '%s\n' '--- tracked file bytes ---'
    git hash-object --no-filters \
      "$slot/tracked-staged.txt" "$slot/tracked-unstaged.txt"
    printf '%s\n' '--- untracked and ignored file bytes ---'
    git hash-object --no-filters \
      "$slot/untracked-preserve.txt" "$slot/ignored-preserve.txt"
    printf '%s\n' '--- status including ignored paths ---'
    GIT_OPTIONAL_LOCKS=0 git -C "$slot" -c core.quotePath=false \
      status --porcelain=v2 --branch --untracked-files=all --ignored=matching
    printf '%s\n' '--- staged diff ---'
    GIT_OPTIONAL_LOCKS=0 git -C "$slot" diff --cached --binary
    printf '%s\n' '--- unstaged diff ---'
    GIT_OPTIONAL_LOCKS=0 git -C "$slot" diff --binary
    printf '%s\n' '--- worktree registry ---'
    GIT_OPTIONAL_LOCKS=0 git -C "$foreign" worktree list --porcelain
    printf '%s\n' '--- refs ---'
    GIT_OPTIONAL_LOCKS=0 git -C "$foreign" for-each-ref \
      --format='%(refname)%09%(objectname)%09%(symref)'
    printf '%s\n' '--- worktree git pointer ---'
    cat "$slot/.git"
  }
}

test_mixed_clone_family_is_refused_unchanged_before_launch() {
  local case_dir seed origin project foreign slot home fakebin id send_log
  local project_common slot_common before after out status
  case_dir="$TMP_ROOT/mixed-family"
  seed="$case_dir/seed"
  origin="$case_dir/origin.git"
  project="$case_dir/requested-project"
  foreign="$case_dir/foreign-clone"
  slot="$case_dir/mixed-slot"
  home="$case_dir/home"
  id='mixed-common-dir-z1'
  send_log="$case_dir/send.log"

  fm_git_identity
  git init --quiet -b main "$seed"
  cat > "$seed/.gitignore" <<'EOF'
ignored-preserve.txt
EOF
  printf 'committed staged file\n' > "$seed/tracked-staged.txt"
  printf 'committed unstaged file\n' > "$seed/tracked-unstaged.txt"
  git -C "$seed" add .gitignore tracked-staged.txt tracked-unstaged.txt
  git -C "$seed" commit --quiet -m initial
  git clone --quiet --bare "$seed" "$origin"
  git clone --quiet "file://$origin" "$project"
  git clone --quiet "file://$origin" "$foreign"
  printf 'stashed local evidence\n' >> "$foreign/tracked-staged.txt"
  git -C "$foreign" stash push --quiet -m preserved-stash -- tracked-staged.txt
  git -C "$foreign" tag -a preserved-tag -m preserved-tag HEAD
  git -C "$foreign" update-ref refs/firstmate/preserved-custom HEAD
  git -C "$foreign" worktree add --quiet -b fm/mixed-slot "$slot" HEAD

  printf 'staged local change\n' > "$slot/tracked-staged.txt"
  git -C "$slot" add tracked-staged.txt
  printf 'unstaged local change\n' > "$slot/tracked-unstaged.txt"
  printf 'untracked local evidence\n' > "$slot/untracked-preserve.txt"
  printf 'ignored private evidence\n' > "$slot/ignored-preserve.txt"

  fm_test_spawn_home "$home" codex
  fm_test_spawn_brief "$home" "$id" 'Delivery contract: mode=no-mistakes'
  fakebin=$(make_mixed_fakebin "$case_dir/fake")
  : > "$send_log"

  project_common=$(git -C "$project" rev-parse --path-format=absolute --git-common-dir)
  slot_common=$(git -C "$slot" rev-parse --path-format=absolute --git-common-dir)
  [ "$project_common" != "$slot_common" ] \
    || fail "mixed fixture did not create two distinct Git common directories"

  before="$case_dir/before.snapshot"
  after="$case_dir/after.snapshot"
  snapshot_mixed_slot "$slot" "$foreign" > "$before"
  assert_contains "$(cat "$before")" 'refs/stash' \
    "mixed fixture did not seed a stash ref"
  assert_contains "$(cat "$before")" 'refs/tags/preserved-tag' \
    "mixed fixture did not seed a tag ref"
  assert_contains "$(cat "$before")" 'refs/firstmate/preserved-custom' \
    "mixed fixture did not seed a custom ref"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 TMUX='fake,1,0' FM_FAKE_PANE_PATH="$slot" \
    FM_FAKE_SEND_LOG="$send_log" PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$project" --mode no-mistakes --yolo off 2>&1)
  status=$?

  [ "$status" -ne 0 ] || fail "spawn accepted a worktree from a foreign clone family"
  assert_contains "$out" 'Git common-directory mismatch' \
    "spawn did not identify the clone-family mismatch"
  assert_contains "$out" "$project_common" \
    "spawn did not report the requested project's absolute Git common directory"
  assert_contains "$out" "$slot_common" \
    "spawn did not report the allocated worktree's absolute Git common directory"
  assert_contains "$out" 'preserved in place' \
    "spawn did not explain that the unsafe allocation was retained"
  assert_contains "$out" 'do not force-return, clean, reset, or remove this allocation' \
    "spawn did not provide the non-destructive recovery boundary"

  snapshot_mixed_slot "$slot" "$foreign" > "$after"
  cmp -s "$before" "$after" \
    || fail "mismatch rejection changed branch, HEAD, index, files, refs, status, or worktree registration"
  assert_contains "$(cat "$send_log")" 'treehouse get' \
    "fixture did not exercise the post-Treehouse-allocation path"
  assert_not_contains "$(cat "$send_log")" 'treehouse return' \
    "mismatch rejection attempted to return the allocation"
  assert_not_contains "$(cat "$send_log")" 'codex' \
    "mismatch rejection handed a worker launch command to the endpoint"
  assert_absent "$home/state/$id.meta" \
    "mismatch rejection published task metadata despite refusing before launch"

  pass "fm-spawn rejects a mixed clone-family allocation before launch and preserves all slot state"
}

test_mixed_clone_family_is_refused_unchanged_before_launch

echo '# all fm-spawn common-directory tests passed'
