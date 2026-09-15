#!/usr/bin/env bash
# Behavior tests for fm-commit-trailer-lib.sh: a task worktree refuses agent
# attribution trailers, keeps a human co-author, chains the project's own
# commit-msg hook instead of replacing it, leaves the repository's other
# checkouts alone, and leaves no hook behind after removal.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-commit-trailer-lib.sh
. "$ROOT/bin/fm-commit-trailer-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-commit-trailer)

AGENT_MESSAGE='feat: thing

Body line.

Co-Authored-By: Jane Human <jane@example.com>
Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_abc'

# Build the shape bin/fm-spawn.sh launches into: a project repository plus a
# separate linked worktree the worker commits in, and a firstmate state
# directory holding the per-task hook directory.
make_world() {  # <name>
  local name=$1 world
  world="$TMP_ROOT/$name"
  mkdir -p "$world/state"
  git init -q "$world/repo"
  git -C "$world/repo" config user.email crew@example.com
  git -C "$world/repo" config user.name Crew
  printf 'seed\n' > "$world/repo/seed.txt"
  git -C "$world/repo" add seed.txt
  git -C "$world/repo" commit -qm 'chore: seed'
  git -C "$world/repo" worktree add -q "$world/wt" -b task
  git -C "$world/wt" config user.email crew@example.com
  git -C "$world/wt" config user.name Crew
  printf '%s\n' "$world"
}

commit_in() {  # <worktree> <file> <message>
  local wt=$1 file=$2 message=$3
  printf 'content\n' > "$wt/$file"
  git -C "$wt" add "$file" || return 1
  printf '%s\n' "$message" | git -C "$wt" commit -q -F - || return 1
}

landed_message() {  # <worktree>
  git -C "$1" log -1 --format=%B
}

test_agent_trailers_stripped_human_kept() {
  local world message
  world=$(make_world strip)
  fm_commit_trailer_hook_install "$world/wt" "$world/state/task.githooks" \
    || fail "install refused a plain task worktree"
  commit_in "$world/wt" a.txt "$AGENT_MESSAGE" || fail "commit under the hook failed"
  message=$(landed_message "$world/wt")
  case "$message" in
    *Claude*) fail "landed message still names an agent"$'\n'"$message" ;;
  esac
  case "$message" in
    *'Co-Authored-By: Jane Human <jane@example.com>'*) ;;
    *) fail "the human co-author did not survive"$'\n'"$message" ;;
  esac
  case "$message" in
    'feat: thing'*) ;;
    *) fail "the subject line was rewritten"$'\n'"$message" ;;
  esac
  case "$message" in
    *'Body line.'*) ;;
    *) fail "the message body was lost"$'\n'"$message" ;;
  esac
  pass "agent trailers are stripped and a human co-author survives"
}

test_lowercase_and_other_agents_stripped() {
  local world message
  world=$(make_world agents)
  fm_commit_trailer_hook_install "$world/wt" "$world/state/task.githooks" \
    || fail "install refused a plain task worktree"
  commit_in "$world/wt" a.txt 'fix: y

co-authored-by: Codex <noreply@openai.com>
Co-authored-by: Cursor Agent <agent@cursor.com>
Codex-Session: https://example.invalid/s
Co-Authored-By: Rene Descartes <rene@example.com>' || fail "commit under the hook failed"
  message=$(landed_message "$world/wt")
  case "$message" in
    *[Cc]odex* | *[Cc]ursor*) fail "another agent's attribution survived"$'\n'"$message" ;;
  esac
  case "$message" in
    *'Rene Descartes'*) ;;
    *) fail "the human co-author did not survive"$'\n'"$message" ;;
  esac
  pass "every listed agent product is stripped, case-insensitively"
}

test_repository_hook_still_runs() {
  local world common message status
  world=$(make_world chain)
  common=$(git -C "$world/wt" rev-parse --path-format=absolute --git-common-dir)
  mkdir -p "$common/hooks"
  cat > "$common/hooks/commit-msg" <<'HOOK'
#!/usr/bin/env bash
grep -q 'REQUIRED-TOKEN' "$1" || exit 1
printf '%s\n' "$(cat "$1")" > "$1"
printf 'project-hook-ran\n' >> "$1"
HOOK
  chmod 0755 "$common/hooks/commit-msg"
  fm_commit_trailer_hook_install "$world/wt" "$world/state/task.githooks" \
    || fail "install refused a worktree with a repository hook"

  status=0
  commit_in "$world/wt" a.txt 'fix: no token here' >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail "the project hook's refusal did not stop the commit"

  commit_in "$world/wt" b.txt 'fix: REQUIRED-TOKEN

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>' || fail "commit under both hooks failed"
  message=$(landed_message "$world/wt")
  case "$message" in
    *project-hook-ran*) ;;
    *) fail "the project's own commit-msg hook did not run"$'\n'"$message" ;;
  esac
  case "$message" in
    *Claude*) fail "the agent trailer survived the chained hook"$'\n'"$message" ;;
  esac
  pass "an inherited repository hook still runs and still gates the commit"
}

test_configured_hooks_path_is_chained_not_replaced() {
  local world message
  world=$(make_world hookspath)
  mkdir -p "$world/repo/.projecthooks"
  cat > "$world/repo/.projecthooks/commit-msg" <<'HOOK'
#!/usr/bin/env bash
printf 'configured-hook-ran\n' >> "$1"
HOOK
  chmod 0755 "$world/repo/.projecthooks/commit-msg"
  git -C "$world/repo" config core.hooksPath "$world/repo/.projecthooks"
  fm_commit_trailer_hook_install "$world/wt" "$world/state/task.githooks" \
    || fail "install refused a worktree with a configured hooks path"
  commit_in "$world/wt" a.txt "$AGENT_MESSAGE" || fail "commit under the hook failed"
  message=$(landed_message "$world/wt")
  case "$message" in
    *configured-hook-ran*) ;;
    *) fail "the configured hooks path was replaced instead of chained"$'\n'"$message" ;;
  esac
  case "$message" in
    *Claude*) fail "the agent trailer survived"$'\n'"$message" ;;
  esac
  [ "$(git -C "$world/repo" config --get core.hooksPath)" = "$world/repo/.projecthooks" ] \
    || fail "the repository's shared hooks path was rewritten"
  pass "a configured hooks path is chained, never replaced"
}

test_other_checkouts_are_untouched() {
  local world message
  world=$(make_world scope)
  fm_commit_trailer_hook_install "$world/wt" "$world/state/task.githooks" \
    || fail "install refused a plain task worktree"
  commit_in "$world/repo" a.txt "$AGENT_MESSAGE" || fail "commit in the primary checkout failed"
  message=$(landed_message "$world/repo")
  case "$message" in
    *'Claude Opus 5'*) ;;
    *) fail "the task hook reached the primary checkout"$'\n'"$message" ;;
  esac
  pass "the hook binds only the task worktree, not the rest of the repository"
}

test_removal_leaves_no_hook_behind() {
  local world message
  world=$(make_world remove)
  fm_commit_trailer_hook_install "$world/wt" "$world/state/task.githooks" \
    || fail "install refused a plain task worktree"
  commit_in "$world/wt" a.txt "$AGENT_MESSAGE" || fail "commit under the hook failed"
  fm_commit_trailer_hook_remove "$world/wt" "$world/state/task.githooks" \
    || fail "removal reported failure"
  [ ! -e "$world/state/task.githooks" ] || fail "the hook directory survived removal"
  [ -z "$(git -C "$world/wt" config --get core.hooksPath 2>/dev/null)" ] \
    || fail "the worktree still points at a hooks path after removal"
  commit_in "$world/wt" b.txt "$AGENT_MESSAGE" || fail "commit after removal failed"
  message=$(landed_message "$world/wt")
  case "$message" in
    *'Claude Opus 5'*) ;;
    *) fail "a hook still rewrote the message after removal"$'\n'"$message" ;;
  esac
  pass "removal leaves no hook and no hooks path behind"
}

test_removal_restores_a_preexisting_worktree_hooks_path() {
  local world
  world=$(make_world restore)
  git -C "$world/wt" config extensions.worktreeConfig true
  git -C "$world/wt" config --worktree core.hooksPath "$world/repo/.projecthooks"
  fm_commit_trailer_hook_install "$world/wt" "$world/state/task.githooks" \
    || fail "install refused a worktree with its own hooks path"
  [ "$(git -C "$world/wt" config --get core.hooksPath)" = "$world/state/task.githooks" ] \
    || fail "install did not take effect"
  fm_commit_trailer_hook_remove "$world/wt" "$world/state/task.githooks" \
    || fail "removal reported failure"
  [ "$(git -C "$world/wt" config --get core.hooksPath)" = "$world/repo/.projecthooks" ] \
    || fail "removal did not restore the worktree's own hooks path"
  pass "removal restores a hooks path the worktree already had"
}

test_reinstall_is_idempotent() {
  local world message
  world=$(make_world reinstall)
  fm_commit_trailer_hook_install "$world/wt" "$world/state/task.githooks" \
    || fail "first install refused a plain task worktree"
  fm_commit_trailer_hook_install "$world/wt" "$world/state/task.githooks" \
    || fail "second install refused a worktree it already owns"
  commit_in "$world/wt" a.txt "$AGENT_MESSAGE" || fail "commit under the reinstalled hook failed"
  message=$(landed_message "$world/wt")
  case "$message" in
    *Claude*) fail "the reinstalled hook stopped stripping"$'\n'"$message" ;;
  esac
  fm_commit_trailer_hook_remove "$world/wt" "$world/state/task.githooks" \
    || fail "removal after reinstall reported failure"
  [ -z "$(git -C "$world/wt" config --get core.hooksPath 2>/dev/null)" ] \
    || fail "a reinstalled hook left its hooks path behind"
  pass "reinstall is idempotent and still removable"
}

test_install_refuses_a_non_worktree() {
  local world status
  world=$(make_world nonrepo)
  mkdir -p "$world/plain"
  status=0
  fm_commit_trailer_hook_install "$world/plain" "$world/state/task.githooks" >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail "install accepted a directory that is not a git worktree"
  [ ! -e "$world/state/task.githooks" ] || fail "a refused install still wrote a hook directory"
  pass "install refuses a path that is not a git worktree"
}

test_agent_trailers_stripped_human_kept
test_lowercase_and_other_agents_stripped
test_repository_hook_still_runs
test_configured_hooks_path_is_chained_not_replaced
test_other_checkouts_are_untouched
test_removal_leaves_no_hook_behind
test_removal_restores_a_preexisting_worktree_hooks_path
test_reinstall_is_idempotent
test_install_refuses_a_non_worktree
