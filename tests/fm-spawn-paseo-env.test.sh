#!/usr/bin/env bash
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-paseo-env)
HOME_DIR="$TMP_ROOT/home"
PROJ_DIR="$TMP_ROOT/project"
WT_DIR="$TMP_ROOT/project-worktree"
FAKEBIN_DIR=$(fm_test_make_spawn_fakebin "$TMP_ROOT/fake" codex)
PASEO_ARGS="$TMP_ROOT/paseo-args"
ID=paseo-env-test

fm_test_spawn_home "$HOME_DIR" codex
fm_git_worktree "$PROJ_DIR" "$WT_DIR" paseo-env-test
fm_test_spawn_brief "$HOME_DIR" "$ID"
printf '%s\n' 'FM_TEST_SET' 'FM_TEST_EMPTY' 'FM_TEST_UNSET' > "$HOME_DIR/config/launch-env-allowlist"
cat > "$FAKEBIN_DIR/paseo" <<'SH'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "daemon status") exit 0 ;;
  "run --background")
    printf '%s\n' "$@" >> "$FM_TEST_PASEO_ARGS"
    if [ -n "${FM_TEST_PASEO_ABORT_MODE:-}" ]; then
      printf 'running\n' > "$FM_TEST_PASEO_STATUS"
      case "${FM_TEST_PASEO_ABORT_MODE:-}" in
        dirty) : > "$FM_TEST_PASEO_WT/.paseo-uncommitted" ;;
        ignored) : > "$FM_TEST_PASEO_WT/.env" ;;
      esac
      : > "$FM_TEST_PASEO_TASK_TMP"
      printf '{"agentId":"%s","workspaceId":"%s","worktreePath":"%s"}\n' \
        "$FM_TEST_PASEO_AGENT" "$FM_TEST_PASEO_WORKSPACE" "$FM_TEST_PASEO_WT"
    else
      printf '{"agentId":"agent-paseo-env","workspaceId":"workspace-paseo-env","worktreePath":"%s"}\n' "$FM_TEST_PASEO_WT"
    fi
    ;;
  stop\ *)
    printf 'stop|%s\n' "$*" >> "$FM_TEST_PASEO_ARGS"
    [ "${FM_TEST_PASEO_STOP_FAIL:-0}" = 1 ] && exit 1
    printf 'closed\n' > "$FM_TEST_PASEO_STATUS"
    ;;
  archive\ *)
    printf 'archive|%s\n' "$*" >> "$FM_TEST_PASEO_ARGS"
    [ "${FM_TEST_PASEO_ARCHIVE_FAIL:-0}" = 1 ] && exit 1
    printf 'archived\n' > "$FM_TEST_PASEO_STATUS"
    ;;
  "workspace archive")
    printf 'workspace_archive|%s\n' "$*" >> "$FM_TEST_PASEO_ARGS"
    [ "${FM_TEST_PASEO_WORKSPACE_ARCHIVE_FAIL:-0}" = 1 ] && exit 1
    ;;
  inspect\ *) printf '{"status":"%s"}\n' "$(cat "$FM_TEST_PASEO_STATUS")" ;;
  *) exit 1 ;;
esac
SH
chmod +x "$FAKEBIN_DIR/paseo"

unset FM_TEST_UNSET
out=$(BASH_COMPAT=3.2 FM_TEST_SET=present FM_TEST_EMPTY='' \
  FM_TEST_PASEO_ARGS="$PASEO_ARGS" FM_TEST_PASEO_WT="$WT_DIR" \
  fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
  "$ID" "$PROJ_DIR" --mode no-mistakes --yolo off --backend paseo --harness codex)
status=$?
expect_code 0 "$status" "Paseo spawn in Bash 3.2 compatibility mode should succeed: $out"
assert_grep 'FM_TEST_SET=present' "$PASEO_ARGS" "Paseo did not receive a set allowlisted value"
assert_grep 'FM_TEST_EMPTY=' "$PASEO_ARGS" "Paseo did not receive an empty-but-set allowlisted value"
assert_no_grep 'FM_TEST_UNSET=' "$PASEO_ARGS" "Paseo received an unset allowlisted value"
assert_grep "paseo_agent_id=agent-paseo-env" "$HOME_DIR/state/$ID.meta" "successful Paseo spawn did not publish its agent identity"

run_abort_case() {
  local label=$1 worktree_kind=$2
  local id home project worktree returned_worktree agent workspace task_tmp status_file out status
  local stop_fail=0 archive_fail=0 workspace_archive_fail=0
  id="paseo-abort-$label-$$-$RANDOM"
  home="$TMP_ROOT/$id-home"
  project="$TMP_ROOT/$id-project"
  worktree="$TMP_ROOT/$id-worktree"
  returned_worktree=$worktree
  agent="agent-$id"
  workspace="workspace-$id"
  task_tmp="/tmp/fm-$id"
  status_file="$TMP_ROOT/$id-paseo-status"
  case "$label" in
    stop-failed) stop_fail=1 ;;
    archive-failed) archive_fail=1 ;;
    workspace-archive-failed) workspace_archive_fail=1 ;;
  esac
  printf '%s\n' "$task_tmp" >> "$FM_TEST_CLEANUP_REGISTRY"
  fm_test_spawn_home "$home" codex
  fm_git_worktree "$project" "$worktree" "$id"
  if [ "$label" = ignored ]; then
    printf '%s\n' '.env' > "$worktree/.gitignore"
    git -C "$worktree" add .gitignore
    git -C "$worktree" -c user.name=Firstmate -c user.email=tests@invalid commit --quiet -m 'ignore test env'
  fi
  fm_test_spawn_brief "$home" "$id"
  if [ "$worktree_kind" = uninspectable ]; then
    returned_worktree="$TMP_ROOT/$id-non-git"
    mkdir -p "$returned_worktree"
  fi

  out=$(FM_TEST_PASEO_ABORT_MODE="$label" \
    FM_TEST_PASEO_ARGS="$PASEO_ARGS" \
    FM_TEST_PASEO_STATUS="$status_file" \
    FM_TEST_PASEO_WT="$returned_worktree" \
    FM_TEST_PASEO_AGENT="$agent" \
    FM_TEST_PASEO_WORKSPACE="$workspace" \
    FM_TEST_PASEO_TASK_TMP="$task_tmp" \
    FM_TEST_PASEO_STOP_FAIL="$stop_fail" \
    FM_TEST_PASEO_ARCHIVE_FAIL="$archive_fail" \
    FM_TEST_PASEO_WORKSPACE_ARCHIVE_FAIL="$workspace_archive_fail" \
    fm_test_run_spawn "$home" "$worktree" "$FAKEBIN_DIR" \
      "$id" "$project" --mode no-mistakes --yolo off --backend paseo --harness codex)
  status=$?
  expect_code 1 "$status" "forced post-return setup failure must abort $label spawn"
  assert_grep "fm-$id" "$PASEO_ARGS" "Paseo run did not create $label task"
  assert_present "$task_tmp" "forced task temporary directory failure did not occur"

  case "$label" in
    dirty)
      assert_contains "$out" "agent $agent and workspace $workspace" "dirty abort did not report both Paseo identities"
      assert_contains "$out" 'uncommitted, untracked, or ignored files' "dirty abort did not explain why the workspace was retained"
      assert_present "$worktree/.paseo-uncommitted" "dirty abort removed the worktree change"
      assert_no_grep "archive|archive $agent" "$PASEO_ARGS" "dirty abort archived the Paseo agent"
      assert_no_grep "workspace_archive|workspace archive $workspace" "$PASEO_ARGS" "dirty abort archived the Paseo workspace"
      ;;
    ignored)
      assert_contains "$out" "agent $agent and workspace $workspace" "ignored-file abort did not report both Paseo identities"
      assert_contains "$out" 'uncommitted, untracked, or ignored files' "ignored-file abort did not explain why the workspace was retained"
      assert_present "$worktree/.env" "ignored-file abort removed the ignored worktree file"
      status=$(git -C "$worktree" status --porcelain --untracked-files=all)
      assert_equals '' "$status" "ignored-file fixture should appear clean to ordinary Git status"
      status=$(git -C "$worktree" status --porcelain --untracked-files=all --ignored)
      assert_contains "$status" '!! .env' "ignored-file fixture was not reported by Git's ignored status"
      assert_no_grep "archive|archive $agent" "$PASEO_ARGS" "ignored-file abort archived the Paseo agent"
      assert_no_grep "workspace_archive|workspace archive $workspace" "$PASEO_ARGS" "ignored-file abort archived the Paseo workspace"
      ;;
    uninspectable)
      assert_contains "$out" "agent $agent and workspace $workspace" "uninspectable abort did not report both Paseo identities"
      assert_contains "$out" 'worktree status could not be inspected' "uninspectable abort did not explain why the workspace was retained"
      assert_no_grep "archive|archive $agent" "$PASEO_ARGS" "uninspectable abort archived the Paseo agent"
      assert_no_grep "workspace_archive|workspace archive $workspace" "$PASEO_ARGS" "uninspectable abort archived the Paseo workspace"
      ;;
    stop-failed)
      assert_contains "$out" "agent $agent and workspace $workspace" "unconfirmed stop did not report both Paseo identities"
      assert_contains "$out" 'agent stop could not be confirmed' "unconfirmed stop did not explain why the workspace was retained"
      assert_grep "stop|stop $agent" "$PASEO_ARGS" "abort cleanup did not try to stop the running Paseo agent"
      assert_no_grep "archive|archive $agent" "$PASEO_ARGS" "abort cleanup archived an agent whose stop could not be confirmed"
      ;;
    archive-failed)
      assert_contains "$out" "agent $agent and workspace $workspace" "archive failure did not report both Paseo identities"
      assert_contains "$out" 'archiving could not be confirmed' "archive failure did not explain why the workspace was retained"
      assert_grep "stop|stop $agent" "$PASEO_ARGS" "archive failure path did not stop the Paseo agent first"
      assert_grep "archive|archive $agent" "$PASEO_ARGS" "archive failure path did not attempt to archive the Paseo agent"
      assert_no_grep "workspace_archive|workspace archive $workspace" "$PASEO_ARGS" "agent archive failure still archived the Paseo workspace"
      ;;
    workspace-archive-failed)
      assert_contains "$out" "agent $agent and workspace $workspace" "workspace archive failure did not report both Paseo identities"
      assert_contains "$out" 'archiving could not be confirmed' "workspace archive failure did not explain why cleanup was incomplete"
      assert_grep "archive|archive $agent" "$PASEO_ARGS" "workspace archive failure path did not archive the agent"
      assert_grep "workspace_archive|workspace archive $workspace" "$PASEO_ARGS" "workspace archive failure path did not attempt workspace archival"
      ;;
    clean)
      assert_grep "stop|stop $agent" "$PASEO_ARGS" "clean worktree abort did not stop the Paseo agent"
      assert_grep "archive|archive $agent" "$PASEO_ARGS" "clean worktree abort did not archive the Paseo agent"
      assert_grep "workspace_archive|workspace archive $workspace" "$PASEO_ARGS" "clean worktree abort did not archive the Paseo workspace"
      ;;
  esac
}

run_abort_case dirty git
run_abort_case ignored git
run_abort_case uninspectable uninspectable
run_abort_case stop-failed git
run_abort_case archive-failed git
run_abort_case workspace-archive-failed git
run_abort_case clean git
pass "Paseo environment forwarding and abort cleanup preserve workspaces safely"
