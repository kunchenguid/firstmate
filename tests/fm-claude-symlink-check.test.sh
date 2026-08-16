#!/usr/bin/env bash
# Behavior tests for bin/fm-claude-symlink-check.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-claude-symlink-check)

# fixture_repo <dir>: a repo on "main" whose CLAUDE.md is a correct symlink to
# AGENTS.md.
fixture_repo() {
  local repo=$1
  mkdir -p "$repo"
  git -C "$repo" init -q
  printf '# agents\n' > "$repo/AGENTS.md"
  git -C "$repo" add AGENTS.md
  ( cd "$repo" && ln -s AGENTS.md CLAUDE.md )
  git -C "$repo" add CLAUDE.md
  git -C "$repo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  git -C "$repo" branch -M main
}

test_matching_symlink_passes() {
  local repo out rc
  repo="$TMP_ROOT/matching"
  fixture_repo "$repo"
  out=$("$ROOT/bin/fm-claude-symlink-check.sh" "$repo" main 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || fail "expected exit 0 for a matching symlink, got $rc: $out"
  assert_contains "$out" "ok:" "matching symlink did not report ok"
  pass "fm-claude-symlink-check.sh: matching CLAUDE.md symlink passes"
}

test_regular_file_fails_with_recovery_commands() {
  local repo out rc
  repo="$TMP_ROOT/regular-file"
  fixture_repo "$repo"
  rm "$repo/CLAUDE.md"
  printf 'stale content\n' > "$repo/CLAUDE.md"
  out=$("$ROOT/bin/fm-claude-symlink-check.sh" "$repo" main 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "expected a non-zero exit when CLAUDE.md is a regular file"
  assert_contains "$out" "error:" "regular-file breakage did not report an error"
  assert_contains "$out" "regular file" "error did not name the actual problem"
  assert_contains "$out" "checkout 'main' -- 'CLAUDE.md'" "error did not include the git checkout recovery command"
  assert_contains "$out" "ln -sfn -- 'AGENTS.md'" "error did not include the ln -sfn recovery command"
  pass "fm-claude-symlink-check.sh: CLAUDE.md demoted to a regular file fails with recovery commands"
}

test_missing_claude_md_fails() {
  local repo out rc
  repo="$TMP_ROOT/missing"
  fixture_repo "$repo"
  rm "$repo/CLAUDE.md"
  out=$("$ROOT/bin/fm-claude-symlink-check.sh" "$repo" main 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "expected a non-zero exit when CLAUDE.md is missing"
  assert_contains "$out" "error:" "missing CLAUDE.md did not report an error"
  assert_contains "$out" "missing" "error did not describe the file as missing"
  pass "fm-claude-symlink-check.sh: missing CLAUDE.md fails"
}

test_wrong_symlink_target_fails() {
  local repo out rc
  repo="$TMP_ROOT/wrong-target"
  fixture_repo "$repo"
  rm "$repo/CLAUDE.md"
  ( cd "$repo" && ln -s WRONG.md CLAUDE.md )
  out=$("$ROOT/bin/fm-claude-symlink-check.sh" "$repo" main 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "expected a non-zero exit for a symlink pointing at the wrong target"
  assert_contains "$out" "error:" "wrong-target symlink did not report an error"
  assert_contains "$out" "WRONG.md" "error did not name the actual (wrong) target"
  pass "fm-claude-symlink-check.sh: symlink pointing at the wrong target fails"
}

test_dangling_symlink_fails() {
  local repo out rc
  repo="$TMP_ROOT/dangling"
  fixture_repo "$repo"
  rm "$repo/AGENTS.md"
  out=$("$ROOT/bin/fm-claude-symlink-check.sh" "$repo" main 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "expected a non-zero exit when CLAUDE.md dangles, got: $out"
  assert_contains "$out" "dangling symlink" "dangling CLAUDE.md was not reported as dangling"
  assert_contains "$out" "checkout 'main' -- 'AGENTS.md'" "error did not include the target-restore command"
  pass "fm-claude-symlink-check.sh: dangling CLAUDE.md symlink fails"
}

test_runs_from_a_subdirectory() {
  local repo out rc
  repo="$TMP_ROOT/subdir"
  fixture_repo "$repo"
  mkdir -p "$repo/pkg"
  rm "$repo/CLAUDE.md"
  printf 'stale content\n' > "$repo/CLAUDE.md"
  out=$("$ROOT/bin/fm-claude-symlink-check.sh" "$repo/pkg" main 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "expected a non-zero exit when run from a subdirectory of a broken repo, got: $out"
  assert_contains "$out" "regular file" "subdirectory invocation did not detect the root CLAUDE.md breakage"
  pass "fm-claude-symlink-check.sh: run from a subdirectory it still checks the repo root"
}

test_unknown_base_ref_errors() {
  local repo out rc
  repo="$TMP_ROOT/bogus-base"
  fixture_repo "$repo"
  out=$("$ROOT/bin/fm-claude-symlink-check.sh" "$repo" no-such-ref 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "expected a non-zero exit for an unresolvable base ref, got: $out"
  assert_contains "$out" "error:" "unresolvable base ref did not report an error"
  assert_contains "$out" "no-such-ref" "error did not name the unresolvable ref"
  pass "fm-claude-symlink-check.sh: an unresolvable base ref errors instead of skipping"
}

test_uncommitted_restore_still_fails() {
  local repo out rc
  repo="$TMP_ROOT/uncommitted-restore"
  fixture_repo "$repo"
  git -C "$repo" checkout -q -b fm/worker
  rm "$repo/CLAUDE.md"
  printf 'stale content\n' > "$repo/CLAUDE.md"
  git -C "$repo" add CLAUDE.md
  git -C "$repo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm demote

  git -C "$repo" checkout main -- CLAUDE.md
  out=$("$ROOT/bin/fm-claude-symlink-check.sh" "$repo" main 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "expected a non-zero exit while the branch tip still carries the broken CLAUDE.md, got: $out"
  assert_contains "$out" "branch tip" "error did not point at the branch tip"
  assert_contains "$out" "Commit the restored symlink" "error did not tell the worker to commit the restore"

  git -C "$repo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm restore
  out=$("$ROOT/bin/fm-claude-symlink-check.sh" "$repo" main 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || fail "expected exit 0 once the restored symlink is committed, got $rc: $out"
  assert_contains "$out" "ok:" "committed restore did not report ok"
  pass "fm-claude-symlink-check.sh: a restore only passes once it is committed"
}

# assert_branch_tip_recovery <label> <tip> <restore>: break the branch tip the way
# <tip> says (demote = tip carries a regular file, drop = tip lost the file), fix
# the working tree the way <restore> says (checkout = the guard's git checkout
# hint, ln = its ln -sfn hint), then run the exact command the guard prints and
# hold it to both invariants: it has to succeed, and it must commit CLAUDE.md
# alone while unrelated staged work stays staged.
assert_branch_tip_recovery() {
  local label=$1 tip=$2 restore=$3 repo out rc cmd committed staged
  repo="$TMP_ROOT/recovery-$label"
  fixture_repo "$repo"
  git -C "$repo" checkout -q -b fm/worker
  if [ "$tip" = demote ]; then
    rm "$repo/CLAUDE.md"
    printf 'stale content\n' > "$repo/CLAUDE.md"
    git -C "$repo" add CLAUDE.md
    git -C "$repo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm demote
  else
    git -C "$repo" rm -q CLAUDE.md
    git -C "$repo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm drop
  fi

  printf 'unrelated work in progress\n' > "$repo/feature.txt"
  git -C "$repo" add feature.txt
  if [ "$restore" = checkout ]; then
    git -C "$repo" checkout main -- CLAUDE.md
  else
    ( cd "$repo" && ln -sfn AGENTS.md CLAUDE.md )
  fi

  out=$("$ROOT/bin/fm-claude-symlink-check.sh" "$repo" main 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "$label: expected a non-zero exit while the branch tip is still broken, got: $out"
  cmd=$(printf '%s\n' "$out" | sed -n 's/^Commit the restored symlink: //p')
  [ -n "$cmd" ] || fail "$label: no branch-tip recovery command was printed: $out"

  # shellcheck disable=SC2030,SC2031 # Git identity is intentionally scoped to this recovery subshell.
  (
    export GIT_AUTHOR_NAME='Firstmate Tests' GIT_AUTHOR_EMAIL='tests@example.invalid'
    export GIT_COMMITTER_NAME=$GIT_AUTHOR_NAME GIT_COMMITTER_EMAIL=$GIT_AUTHOR_EMAIL
    eval "$cmd"
  ) >/dev/null 2>&1 || fail "$label: the printed recovery command failed: $cmd"

  committed=$(git -C "$repo" show --name-only --format= HEAD)
  assert_contains "$committed" "CLAUDE.md" "$label: the recovery commit did not restore CLAUDE.md"
  case "$committed" in
    *feature.txt*) fail "$label: the recovery command swept unrelated staged work into its commit: $committed" ;;
  esac
  staged=$(git -C "$repo" diff --cached --name-only)
  assert_contains "$staged" "feature.txt" "$label: the recovery command consumed unrelated staged work instead of leaving it staged"

  out=$("$ROOT/bin/fm-claude-symlink-check.sh" "$repo" main 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || fail "$label: expected exit 0 after running the printed recovery command, got $rc: $out"
}

test_branch_tip_recovery_command_works_from_every_restore_path() {
  assert_branch_tip_recovery demoted-tip-checkout-restore demote checkout
  assert_branch_tip_recovery demoted-tip-symlink-restore demote ln
  assert_branch_tip_recovery dropped-tip-checkout-restore drop checkout
  assert_branch_tip_recovery dropped-tip-symlink-restore drop ln
  assert_branch_tip_recovery "quoted-'dir" demote checkout
  pass "fm-claude-symlink-check.sh: the printed recovery command commits only CLAUDE.md from every restore path"
}

test_branch_tip_dropping_claude_md_fails() {
  local repo out rc
  repo="$TMP_ROOT/tip-drops-file"
  fixture_repo "$repo"
  git -C "$repo" checkout -q -b fm/worker
  git -C "$repo" rm -q CLAUDE.md
  git -C "$repo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm drop
  ( cd "$repo" && ln -s AGENTS.md CLAUDE.md )
  out=$("$ROOT/bin/fm-claude-symlink-check.sh" "$repo" main 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "expected a non-zero exit when the branch tip drops CLAUDE.md, got: $out"
  assert_contains "$out" "drops CLAUDE.md entirely" "error did not describe the dropped file"
  pass "fm-claude-symlink-check.sh: a branch tip that dropped CLAUDE.md fails"
}

test_branch_tip_missing_target_fails() {
  local repo out rc cmd
  repo="$TMP_ROOT/tip-missing-target"
  fixture_repo "$repo"
  git -C "$repo" checkout -q -b fm/worker
  git -C "$repo" rm -q AGENTS.md
  git -C "$repo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm drop-target
  printf '# agents\n' > "$repo/AGENTS.md"
  git -C "$repo" add AGENTS.md
  out=$("$ROOT/bin/fm-claude-symlink-check.sh" "$repo" main 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "expected a non-zero exit when the branch tip drops the symlink target, got: $out"
  assert_contains "$out" "branch tip" "missing branch-tip target was not reported"
  assert_contains "$out" "expected target" "missing branch-tip target was not named"
  cmd=$(printf '%s\n' "$out" | sed -n 's/^Commit the restored symlink: //p')
  [ -n "$cmd" ] || fail "missing-target branch tip did not print a recovery commit command: $out"
  assert_contains "$cmd" "'AGENTS.md'" "branch-tip recovery did not include the missing target"
  # shellcheck disable=SC2030,SC2031 # Git identity is intentionally scoped to this recovery subshell.
  (
    export GIT_AUTHOR_NAME='Firstmate Tests' GIT_AUTHOR_EMAIL='tests@example.invalid'
    export GIT_COMMITTER_NAME=$GIT_AUTHOR_NAME GIT_COMMITTER_EMAIL=$GIT_AUTHOR_EMAIL
    eval "$cmd"
  ) >/dev/null 2>&1 || fail "missing-target recovery command failed: $cmd"
  out=$("$ROOT/bin/fm-claude-symlink-check.sh" "$repo" main 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || fail "expected exit 0 after restoring and committing the target, got $rc: $out"
  pass "fm-claude-symlink-check.sh: branch tips must retain the regular symlink target"
}

test_branch_tip_recovery_force_adds_ignored_target() {
  local repo out rc cmd
  repo="$TMP_ROOT/recovery-ignored-target"
  fixture_repo "$repo"
  git -C "$repo" checkout -q -b fm/worker
  printf 'AGENTS.md\nCLAUDE.md\n' > "$repo/.gitignore"
  git -C "$repo" add .gitignore
  git -C "$repo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm ignore-target
  git -C "$repo" rm -q AGENTS.md
  git -C "$repo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm drop-target
  printf '# restored agents\n' > "$repo/AGENTS.md"
  out=$("$ROOT/bin/fm-claude-symlink-check.sh" "$repo" main 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "expected a non-zero exit while the branch tip omits an ignored target"
  cmd=$(printf '%s\n' "$out" | sed -n 's/^Commit the restored symlink: //p')
  [ -n "$cmd" ] || fail "ignored-target recovery did not print a commit command: $out"
  assert_contains "$cmd" "--literal-pathspecs add -f -- 'CLAUDE.md'" \
    "ignored-target recovery did not force-add the known CLAUDE.md path"
  assert_contains "$cmd" "--literal-pathspecs add -f -- 'AGENTS.md'" \
    "ignored-target recovery did not force-add the known target"
  # shellcheck disable=SC2030,SC2031 # Git identity is intentionally scoped to this recovery subshell.
  (
    export GIT_AUTHOR_NAME='Firstmate Tests' GIT_AUTHOR_EMAIL='tests@example.invalid'
    export GIT_COMMITTER_NAME=$GIT_AUTHOR_NAME GIT_COMMITTER_EMAIL=$GIT_AUTHOR_EMAIL
    eval "$cmd"
  ) >/dev/null 2>&1 || fail "ignored-target recovery command failed: $cmd"
  out=$("$ROOT/bin/fm-claude-symlink-check.sh" "$repo" main 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || fail "expected exit 0 after ignored-target recovery, got $rc: $out"
  pass "fm-claude-symlink-check.sh: branch-tip recovery force-adds an ignored target"
}

test_branch_tip_recovery_preserves_target_work() {
  local repo out rc cmd committed staged
  repo="$TMP_ROOT/recovery-preserves-target-work"
  fixture_repo "$repo"
  git -C "$repo" checkout -q -b fm/worker
  rm "$repo/CLAUDE.md"
  printf 'stale content\n' > "$repo/CLAUDE.md"
  git -C "$repo" add CLAUDE.md
  git -C "$repo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm demote

  git -C "$repo" checkout main -- CLAUDE.md
  printf '# target work in progress\n' > "$repo/AGENTS.md"
  git -C "$repo" add AGENTS.md
  out=$("$ROOT/bin/fm-claude-symlink-check.sh" "$repo" main 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "expected a non-zero exit while the branch tip is demoted, got: $out"
  cmd=$(printf '%s\n' "$out" | sed -n 's/^Commit the restored symlink: //p')
  [ -n "$cmd" ] || fail "target-work recovery did not print a commit command: $out"
  assert_not_contains "$cmd" "'AGENTS.md'" "target-work recovery would include an already committed target"
  # shellcheck disable=SC2030,SC2031 # Git identity is intentionally scoped to this recovery subshell.
  (
    export GIT_AUTHOR_NAME='Firstmate Tests' GIT_AUTHOR_EMAIL='tests@example.invalid'
    export GIT_COMMITTER_NAME=$GIT_AUTHOR_NAME GIT_COMMITTER_EMAIL=$GIT_AUTHOR_EMAIL
    eval "$cmd"
  ) >/dev/null 2>&1 || fail "target-work recovery command failed: $cmd"
  committed=$(git -C "$repo" show --name-only --format= HEAD)
  case "$committed" in
    *AGENTS.md*) fail "target-work recovery swept target work into its commit: $committed" ;;
  esac
  staged=$(git -C "$repo" diff --cached --name-only)
  assert_contains "$staged" "AGENTS.md" "target-work recovery consumed the staged target work"
  out=$("$ROOT/bin/fm-claude-symlink-check.sh" "$repo" main 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || fail "expected exit 0 after target-work recovery, got $rc: $out"
  pass "fm-claude-symlink-check.sh: branch-tip recovery preserves target work"
}

test_branch_tip_recovery_restores_missing_target_for_regular_claude() {
  local repo out rc cmd
  repo="$TMP_ROOT/recovery-missing-target-regular-claude"
  fixture_repo "$repo"
  git -C "$repo" checkout -q -b fm/worker
  git -C "$repo" rm -q -- AGENTS.md CLAUDE.md
  printf 'stale content\n' > "$repo/CLAUDE.md"
  git -C "$repo" add CLAUDE.md
  git -C "$repo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm demote-without-target

  printf '# agents restored\n' > "$repo/AGENTS.md"
  rm "$repo/CLAUDE.md"
  ( cd "$repo" && ln -s AGENTS.md CLAUDE.md )
  out=$("$ROOT/bin/fm-claude-symlink-check.sh" "$repo" main 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "expected a non-zero exit for a demoted CLAUDE.md with a missing branch-tip target"
  cmd=$(printf '%s\n' "$out" | sed -n 's/^Commit the restored symlink: //p')
  [ -n "$cmd" ] || fail "missing-target regular-CLAUDE recovery did not print a commit command: $out"
  assert_contains "$cmd" "'AGENTS.md'" "missing-target regular-CLAUDE recovery omitted the target"
  # shellcheck disable=SC2030,SC2031 # Git identity is intentionally scoped to this recovery subshell.
  (
    export GIT_AUTHOR_NAME='Firstmate Tests' GIT_AUTHOR_EMAIL='tests@example.invalid'
    export GIT_COMMITTER_NAME=$GIT_AUTHOR_NAME GIT_COMMITTER_EMAIL=$GIT_AUTHOR_EMAIL
    eval "$cmd"
  ) >/dev/null 2>&1 || fail "missing-target regular-CLAUDE recovery command failed: $cmd"
  out=$("$ROOT/bin/fm-claude-symlink-check.sh" "$repo" main 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || fail "expected exit 0 after missing-target regular-CLAUDE recovery, got $rc: $out"
  pass "fm-claude-symlink-check.sh: recovery restores a missing target with a regular branch-tip CLAUDE.md"
}

test_worktree_target_must_be_regular_file() {
  local repo out rc
  repo="$TMP_ROOT/target-directory"
  fixture_repo "$repo"
  rm "$repo/AGENTS.md"
  mkdir "$repo/AGENTS.md"
  out=$("$ROOT/bin/fm-claude-symlink-check.sh" "$repo" main 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "expected a non-zero exit when the symlink target is a directory"
  assert_contains "$out" "regular non-symlink file" "directory target was not rejected"

  repo="$TMP_ROOT/target-symlink"
  fixture_repo "$repo"
  rm "$repo/AGENTS.md"
  printf '# other\n' > "$repo/OTHER.md"
  ln -s OTHER.md "$repo/AGENTS.md"
  out=$("$ROOT/bin/fm-claude-symlink-check.sh" "$repo" main 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "expected a non-zero exit when the symlink target is another symlink"
  assert_contains "$out" "regular non-symlink file" "symlink target was not rejected"
  pass "fm-claude-symlink-check.sh: the worktree target must be a regular non-symlink file"
}

test_index_rejects_staged_claude_deletion() {
  local repo out rc
  repo="$TMP_ROOT/index-claude-deletion"
  fixture_repo "$repo"
  git -C "$repo" rm --cached -q CLAUDE.md
  out=$("$ROOT/bin/fm-claude-symlink-check.sh" "$repo" main 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "expected a non-zero exit when CLAUDE.md is deleted from the index"
  assert_contains "$out" "index" "staged CLAUDE.md deletion was not reported as an index problem"
  pass "fm-claude-symlink-check.sh: staged CLAUDE.md deletion fails"
}

test_index_rejects_staged_target_deletion() {
  local repo out rc
  repo="$TMP_ROOT/index-target-deletion"
  fixture_repo "$repo"
  git -C "$repo" rm --cached -q AGENTS.md
  out=$("$ROOT/bin/fm-claude-symlink-check.sh" "$repo" main 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "expected a non-zero exit when the symlink target is deleted from the index"
  assert_contains "$out" "target" "staged target deletion was not reported"
  assert_contains "$out" "index" "staged target deletion was not reported as an index problem"
  pass "fm-claude-symlink-check.sh: staged symlink-target deletion fails"
}

test_index_target_recovery_preserves_worktree_edits() {
  local repo out rc cmd
  repo="$TMP_ROOT/index-target-recovery"
  fixture_repo "$repo"
  git -C "$repo" rm --cached -q AGENTS.md
  printf '# edited target\n' > "$repo/AGENTS.md"
  out=$("$ROOT/bin/fm-claude-symlink-check.sh" "$repo" main 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "expected a non-zero exit when the target is missing from the index"
  cmd=$(printf '%s\n' "$out" | sed -n 's/^Stage the target in the index: //p')
  [ -n "$cmd" ] || fail "index-target recovery did not print a staging command: $out"
  assert_contains "$cmd" "--literal-pathspecs add -f -- 'AGENTS.md'" \
    "index-target recovery did not use a literal git add"
  eval "$cmd" >/dev/null 2>&1 || fail "index-target staging command failed: $cmd"
  [ "$(cat "$repo/AGENTS.md")" = '# edited target' ] || fail "index-target recovery overwrote worktree edits"
  out=$("$ROOT/bin/fm-claude-symlink-check.sh" "$repo" main 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || fail "expected exit 0 after staging the edited target, got $rc: $out"
  pass "fm-claude-symlink-check.sh: index-target recovery preserves worktree edits"
}

test_index_rejects_intent_to_add_target() {
  local repo out rc cmd objects_before objects_after
  repo="$TMP_ROOT/index-intent-to-add"
  fixture_repo "$repo"
  git -C "$repo" rm --cached -q AGENTS.md
  git -C "$repo" add -N AGENTS.md
  objects_before=$(git -C "$repo" count-objects -v | awk -F': ' '$1 == "count" {print $2}')
  out=$("$ROOT/bin/fm-claude-symlink-check.sh" "$repo" main 2>&1)
  rc=$?
  objects_after=$(git -C "$repo" count-objects -v | awk -F': ' '$1 == "count" {print $2}')
  [ "$rc" -ne 0 ] || fail "expected a non-zero exit for an intent-to-add target"
  [ "$objects_before" = "$objects_after" ] || fail "intent-to-add check mutated the object database"
  assert_contains "$out" "only intent-to-add in the index" \
    "intent-to-add target was not rejected"
  cmd=$(printf '%s\n' "$out" | sed -n 's/^Stage the target in the index: //p')
  [ -n "$cmd" ] || fail "intent-to-add target did not print a staging command: $out"
  eval "$cmd" >/dev/null 2>&1 || fail "intent-to-add recovery command failed: $cmd"
  out=$("$ROOT/bin/fm-claude-symlink-check.sh" "$repo" main 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || fail "expected exit 0 after replacing the intent-to-add entry, got $rc: $out"
  pass "fm-claude-symlink-check.sh: intent-to-add targets fail closed"
}

test_recovery_commands_quote_repository_operands() {
  local repo base target out rc checkout_cmd ln_cmd
  repo="$TMP_ROOT/recovery-special-'dir"
  base='base;touch'
  target='AGENTS;touch'
  mkdir -p "$repo"
  git -C "$repo" init -q
  printf '# agents\n' > "$repo/$target"
  ( cd "$repo" && ln -s "$target" CLAUDE.md )
  git -C "$repo" add -- "$target" CLAUDE.md
  git -C "$repo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  git -C "$repo" branch -M main
  git -C "$repo" branch "$base"
  git -C "$repo" checkout -q -b fm/worker

  rm "$repo/CLAUDE.md"
  printf 'stale content\n' > "$repo/CLAUDE.md"
  out=$("$ROOT/bin/fm-claude-symlink-check.sh" "$repo" "$base" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "expected a non-zero exit for special recovery operands"
  checkout_cmd=$(printf '%s\n' "$out" | sed -n 's/^Restore it: //; s/   (or:.*$//p')
  [ -n "$checkout_cmd" ] || fail "special-operand check did not print a checkout recovery command: $out"
  eval "$checkout_cmd" >/dev/null 2>&1 || fail "quoted checkout recovery command failed: $checkout_cmd"
  [ -L "$repo/CLAUDE.md" ] || fail "quoted checkout recovery command did not restore the symlink"

  rm "$repo/CLAUDE.md"
  printf 'stale content\n' > "$repo/CLAUDE.md"
  out=$("$ROOT/bin/fm-claude-symlink-check.sh" "$repo" "$base" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "expected a non-zero exit for special symlink recovery operands"
  ln_cmd=$(printf '%s\n' "$out" | sed -n 's/^Restore it: .*   (or: //; s/)$//p')
  [ -n "$ln_cmd" ] || fail "special-operand check did not print an ln recovery command: $out"
  eval "$ln_cmd" >/dev/null 2>&1 || fail "quoted ln recovery command failed: $ln_cmd"
  [ -L "$repo/CLAUDE.md" ] || fail "quoted ln recovery command did not restore the symlink"
  [ "$(readlink "$repo/CLAUDE.md")" = "$target" ] || fail "quoted ln recovery command changed the symlink target"
  pass "fm-claude-symlink-check.sh: recovery commands quote every repository-controlled operand"
}

test_recovery_target_pathspecs_are_literal() {
  local repo target decoy out rc cmd committed
  repo="$TMP_ROOT/recovery-literal-pathspec"
  target='AGENTS*.md'
  decoy='AGENTS-other.md'
  mkdir -p "$repo"
  git -C "$repo" init -q
  printf '# agents\n' > "$repo/$target"
  printf '# decoy\n' > "$repo/$decoy"
  ( cd "$repo" && ln -s "$target" CLAUDE.md )
  git -C "$repo" --literal-pathspecs add -- "$target" "$decoy" CLAUDE.md
  git -C "$repo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  git -C "$repo" branch -M main
  git -C "$repo" checkout -q -b fm/worker

  git -C "$repo" --literal-pathspecs rm -q -- "$target"
  git -C "$repo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm drop-target
  printf '# agents restored\n' > "$repo/$target"
  git -C "$repo" --literal-pathspecs add -- "$target"
  printf 'working copy\n' > "$repo/$decoy"
  out=$("$ROOT/bin/fm-claude-symlink-check.sh" "$repo" main 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "expected a branch-tip failure for the missing wildcard target"
  cmd=$(printf '%s\n' "$out" | sed -n 's/^Commit the restored symlink: //p')
  [ -n "$cmd" ] || fail "missing wildcard target did not print a commit recovery command: $out"
  # shellcheck disable=SC2030,SC2031 # Git identity is intentionally scoped to this recovery subshell.
  (
    export GIT_AUTHOR_NAME='Firstmate Tests' GIT_AUTHOR_EMAIL='tests@example.invalid'
    export GIT_COMMITTER_NAME=$GIT_AUTHOR_NAME GIT_COMMITTER_EMAIL=$GIT_AUTHOR_EMAIL
    eval "$cmd"
  ) >/dev/null 2>&1 || fail "literal-pathspec commit recovery command failed: $cmd"
  committed=$(git -C "$repo" show --name-only --format= HEAD)
  case "$committed" in
    *"$decoy"*) fail "literal-pathspec commit recovery swept in the decoy: $committed" ;;
  esac
  [ "$(cat "$repo/$decoy")" = 'working copy' ] || fail "literal-pathspec commit recovery changed the decoy"

  rm "$repo/$target"
  printf 'working copy after restore\n' > "$repo/$decoy"
  out=$("$ROOT/bin/fm-claude-symlink-check.sh" "$repo" main 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "expected a worktree failure for the missing wildcard target"
  cmd=$(printf '%s\n' "$out" | sed -n 's/^Restore the target: //p')
  [ -n "$cmd" ] || fail "missing wildcard target did not print a target recovery command: $out"
  eval "$cmd" >/dev/null 2>&1 || fail "literal-pathspec checkout recovery command failed: $cmd"
  [ "$(cat "$repo/$decoy")" = 'working copy after restore' ] || fail "literal-pathspec checkout recovery changed the decoy"
  pass "fm-claude-symlink-check.sh: generated Git recovery commands use literal target pathspecs"
}

test_repo_without_symlink_policy_skips() {
  local repo out rc
  repo="$TMP_ROOT/no-policy"
  mkdir -p "$repo"
  git -C "$repo" init -q
  printf '# claude\n' > "$repo/CLAUDE.md"
  git -C "$repo" add CLAUDE.md
  git -C "$repo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  git -C "$repo" branch -M main
  out=$("$ROOT/bin/fm-claude-symlink-check.sh" "$repo" main 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || fail "expected exit 0 for a repo without a CLAUDE.md symlink policy, got $rc: $out"
  [ -z "$out" ] || fail "repo without a symlink policy was not silent: $out"
  pass "fm-claude-symlink-check.sh: repo without a CLAUDE.md symlink policy skips silently"
}

test_repo_without_claude_md_at_all_skips() {
  local repo out rc
  repo="$TMP_ROOT/no-claude-file"
  fm_git_init_commit "$repo"
  git -C "$repo" branch -M main
  out=$("$ROOT/bin/fm-claude-symlink-check.sh" "$repo" main 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || fail "expected exit 0 for a repo with no CLAUDE.md at all, got $rc: $out"
  [ -z "$out" ] || fail "repo without any CLAUDE.md was not silent: $out"
  pass "fm-claude-symlink-check.sh: repo with no CLAUDE.md at all skips silently"
}

test_auto_detects_origin_default_branch() {
  local repo bare out rc
  repo="$TMP_ROOT/auto-detect-src"
  bare="$TMP_ROOT/auto-detect-bare"
  fixture_repo "$repo"
  fm_git_add_origin "$repo" "$bare"
  git -C "$repo" fetch --quiet origin
  git -C "$repo" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  rm "$repo/CLAUDE.md"
  printf 'stale content\n' > "$repo/CLAUDE.md"
  out=$("$ROOT/bin/fm-claude-symlink-check.sh" "$repo" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "expected a non-zero exit with auto-detected origin/main base, got: $out"
  assert_contains "$out" "origin/main" "auto-detected base was not origin/main"
  pass "fm-claude-symlink-check.sh: auto-detects the origin default branch when no base-ref is given"
}

test_dangling_origin_head_falls_back_to_available_default() {
  local repo bare out rc
  repo="$TMP_ROOT/dangling-origin-head"
  bare="$TMP_ROOT/dangling-origin-head-bare"
  fixture_repo "$repo"
  fm_git_add_origin "$repo" "$bare"
  git -C "$repo" fetch --quiet origin
  git -C "$repo" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/stale
  rm "$repo/CLAUDE.md"
  printf 'stale content\n' > "$repo/CLAUDE.md"
  out=$("$ROOT/bin/fm-claude-symlink-check.sh" "$repo" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "expected a non-zero exit after falling back from a dangling origin/HEAD"
  assert_contains "$out" "origin/main" "dangling origin/HEAD did not fall back to origin/main"
  pass "fm-claude-symlink-check.sh: a dangling origin/HEAD falls back to an available default"
}

test_matching_symlink_passes
test_regular_file_fails_with_recovery_commands
test_missing_claude_md_fails
test_wrong_symlink_target_fails
test_dangling_symlink_fails
test_runs_from_a_subdirectory
test_unknown_base_ref_errors
test_uncommitted_restore_still_fails
test_branch_tip_recovery_command_works_from_every_restore_path
test_branch_tip_dropping_claude_md_fails
test_branch_tip_missing_target_fails
test_branch_tip_recovery_force_adds_ignored_target
test_branch_tip_recovery_preserves_target_work
test_branch_tip_recovery_restores_missing_target_for_regular_claude
test_worktree_target_must_be_regular_file
test_index_rejects_staged_claude_deletion
test_index_rejects_staged_target_deletion
test_index_target_recovery_preserves_worktree_edits
test_index_rejects_intent_to_add_target
test_recovery_commands_quote_repository_operands
test_recovery_target_pathspecs_are_literal
test_repo_without_symlink_policy_skips
test_repo_without_claude_md_at_all_skips
test_auto_detects_origin_default_branch
test_dangling_origin_head_falls_back_to_available_default
