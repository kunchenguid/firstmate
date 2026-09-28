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
PASEO_WORKSPACES="$TMP_ROOT/paseo-workspaces.tsv"
PASEO_WORKTREE_ROOT="$TMP_ROOT/paseo-worktrees"
PASEO_RUN_COUNT="$TMP_ROOT/paseo-run-count"
mkdir -p "$PASEO_WORKTREE_ROOT"
: >"$PASEO_WORKSPACES"
printf '0\n' >"$PASEO_RUN_COUNT"
ID=paseo-env-test

fm_test_spawn_home "$HOME_DIR" codex
fm_git_worktree "$PROJ_DIR" "$WT_DIR" paseo-env-test
fm_test_spawn_brief "$HOME_DIR" "$ID"
printf '%s\n' 'FM_TEST_SET' 'FM_TEST_EMPTY' 'FM_TEST_UNSET' > "$HOME_DIR/config/launch-env-allowlist"
cat > "$FAKEBIN_DIR/paseo" <<'SH'
#!/usr/bin/env bash
printf 'agent=%s workspace=%s|%s\n' "${PASEO_AGENT_ID-unset}" "${PASEO_WORKSPACE_ID-unset}" "$*" >> "$FM_TEST_PASEO_ARGS"
case "$*" in
  "daemon status") exit 0 ;;
  "project ls --json")
    project_name=$(basename "$FM_TEST_PASEO_SOURCE")
    jq -nc --arg path "$FM_TEST_PASEO_SOURCE" --arg name "$project_name" '[{projectId:"test-project",name:$name,path:$path}]'
    ;;
  "workspace ls --json")
    printf '['
    separator=
    while IFS=$'\t' read -r id project isolation path; do
      [ -n "$id" ] || continue
      printf '%s' "$separator"
      jq -nc --arg id "$id" --arg project "$project" --arg isolation "$isolation" --arg path "$path" \
        '{workspaceId:$id,project:$project,isolation:$isolation,cwd:$path}'
      separator=,
    done < "$FM_TEST_PASEO_WORKSPACES_FILE"
    printf ']\n'
    ;;
  workspace\ create\ *)
    source=
    slug=
    base=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --path) source=$2; shift 2 ;;
        --new-branch) slug=$2; shift 2 ;;
        --base) base=$2; shift 2 ;;
        *) shift ;;
      esac
    done
    project_name=$(basename "$source")
    workspace_id=${FM_TEST_PASEO_WORKSPACE:-wks-$slug}
    worktree="$FM_TEST_PASEO_WORKTREE_ROOT/$slug"
    git -C "$source" worktree add -q -b "$slug" "$worktree" "$base" || exit 1
    printf '%s\t%s\tworktree\t%s\n' "$workspace_id" "$project_name" "$worktree" >> "$FM_TEST_PASEO_WORKSPACES_FILE"
    printf 'Created workspace %s\n' "$workspace_id"
    jq -nc --arg id "$workspace_id" --arg path "$worktree" '{workspaceId:$id,cwd:$path}'
    ;;
  "run "*)
    printf '%s\n' "$@" >> "$FM_TEST_PASEO_ARGS"
    workspace_id=
    task_id=
    previous=
    while [ "$#" -gt 0 ]; do
      if [ "$previous" = --workspace ]; then workspace_id=$1; fi
      case "$1" in fm-task=*) task_id=${1#fm-task=} ;; esac
      previous=$1
      shift
    done
    worktree=$(awk -F '\t' -v id="$workspace_id" '$1 == id {print $4}' "$FM_TEST_PASEO_WORKSPACES_FILE" | tail -n 1)
    run_count=$(cat "$FM_TEST_PASEO_RUN_COUNT")
    run_count=$((run_count + 1))
    printf '%s\n' "$run_count" > "$FM_TEST_PASEO_RUN_COUNT"
    agent=${FM_TEST_PASEO_AGENT:-agent-$task_id-$run_count}
    printf 'response Using workspace %s\n' "$workspace_id" >> "$FM_TEST_PASEO_ARGS"
    if [ -n "${FM_TEST_PASEO_ABORT_MODE:-}" ]; then
      printf 'running\n' > "$FM_TEST_PASEO_STATUS"
      case "$FM_TEST_PASEO_ABORT_MODE" in
        dirty) : > "$worktree/.paseo-uncommitted" ;;
        ignored) : > "$worktree/.env" ;;
      esac
      : > "$FM_TEST_PASEO_TASK_TMP"
    else
      printf 'running\n' > "$FM_TEST_PASEO_STATUS"
    fi
    printf 'Using workspace %s\n' "$workspace_id"
    printf '{"agentId":"%s","cwd":"%s"}\n' "$agent" "$worktree"
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
  "workspace archive "*)
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
  FM_TEST_PASEO_ARGS="$PASEO_ARGS" FM_TEST_PASEO_SOURCE="$PROJ_DIR" \
  FM_TEST_PASEO_WORKSPACES_FILE="$PASEO_WORKSPACES" FM_TEST_PASEO_WORKTREE_ROOT="$PASEO_WORKTREE_ROOT" \
  FM_TEST_PASEO_RUN_COUNT="$PASEO_RUN_COUNT" FM_TEST_PASEO_STATUS="$TMP_ROOT/paseo-status" \
  fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
  "$ID" "$PROJ_DIR" --mode no-mistakes --yolo off --backend paseo --harness codex)
status=$?
expect_code 0 "$status" "Paseo spawn in Bash 3.2 compatibility mode should succeed: $out"
assert_grep 'FM_TEST_SET=present' "$PASEO_ARGS" "Paseo did not receive a set allowlisted value"
assert_grep 'FM_TEST_EMPTY=' "$PASEO_ARGS" "Paseo did not receive an empty-but-set allowlisted value"
assert_no_grep 'FM_TEST_UNSET=' "$PASEO_ARGS" "Paseo received an unset allowlisted value"
assert_grep "paseo_agent_id=agent-$ID-1" "$HOME_DIR/state/$ID.meta" "successful Paseo spawn did not publish its agent identity"
initial_workspace=$(sed -n 's/^paseo_workspace_id=//p' "$HOME_DIR/state/$ID.meta")
initial_worktree=$(sed -n 's/^worktree=//p' "$HOME_DIR/state/$ID.meta")
assert_grep "paseo_workspace_id=$initial_workspace" "$HOME_DIR/state/$ID.meta" "successful Paseo spawn did not publish its workspace identity"
assert_grep "worktree=$initial_worktree" "$HOME_DIR/state/$ID.meta" "successful Paseo spawn did not publish its worktree identity"
assert_grep "Using workspace $initial_workspace" "$PASEO_ARGS" "Paseo fake did not exercise workspace text without a workspaceId JSON field"
assert_grep "--label fm-task=$ID --label fm-home=" "$PASEO_ARGS" "Paseo spawn did not publish unique task labels"
printf 'closed\n' > "$TMP_ROOT/paseo-status"
out=$(FM_TEST_PASEO_ARGS="$PASEO_ARGS" FM_TEST_PASEO_SOURCE="$PROJ_DIR" \
  FM_TEST_PASEO_WORKSPACES_FILE="$PASEO_WORKSPACES" FM_TEST_PASEO_WORKTREE_ROOT="$PASEO_WORKTREE_ROOT" \
  FM_TEST_PASEO_RUN_COUNT="$PASEO_RUN_COUNT" FM_TEST_PASEO_STATUS="$TMP_ROOT/paseo-status" \
  fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" --relaunch "$ID")
status=$?
expect_code 0 "$status" "Paseo relaunch should reuse the validated workspace and worktree: $out"
assert_grep "paseo_agent_id=agent-$ID-2" "$HOME_DIR/state/$ID.meta" "Paseo relaunch did not publish its replacement agent"
assert_grep "paseo_workspace_id=$initial_workspace" "$HOME_DIR/state/$ID.meta" "Paseo relaunch did not retain the validated workspace identity"
assert_grep "worktree=$initial_worktree" "$HOME_DIR/state/$ID.meta" "Paseo relaunch did not retain the validated worktree identity"
assert_equals 1 "$(grep -c 'workspace create' "$PASEO_ARGS")" "Paseo relaunch created another workspace"
assert_equals 2 "$(grep -c 'run --background' "$PASEO_ARGS")" "Paseo relaunch did not publish a second agent"

run_abort_case() {
  local label=$1
  local id home project worktree task_worktree agent workspace task_tmp status_file out status
  local stop_fail=0 archive_fail=0 workspace_archive_fail=0
  id="paseo-abort-$label-$$-$RANDOM"
  home="$TMP_ROOT/$id-home"
  project="$TMP_ROOT/$id-project"
  worktree="$TMP_ROOT/$id-worktree"
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
    printf '%s\n' '.env' > "$project/.gitignore"
    git -C "$project" add .gitignore
    git -C "$project" -c user.name=Firstmate -c user.email=tests@invalid commit --quiet -m 'ignore test env'
  fi
  fm_test_spawn_brief "$home" "$id"

  out=$(FM_TEST_PASEO_ABORT_MODE="$label" \
    FM_TEST_PASEO_ARGS="$PASEO_ARGS" \
    FM_TEST_PASEO_SOURCE="$project" \
    FM_TEST_PASEO_WORKSPACES_FILE="$PASEO_WORKSPACES" \
    FM_TEST_PASEO_WORKTREE_ROOT="$PASEO_WORKTREE_ROOT" \
    FM_TEST_PASEO_RUN_COUNT="$PASEO_RUN_COUNT" \
    FM_TEST_PASEO_STATUS="$status_file" \
    FM_TEST_PASEO_AGENT="$agent" \
    FM_TEST_PASEO_WORKSPACE="$workspace" \
    FM_TEST_PASEO_TASK_TMP="$task_tmp" \
    FM_TEST_PASEO_STOP_FAIL="$stop_fail" \
    FM_TEST_PASEO_ARCHIVE_FAIL="$archive_fail" \
    FM_TEST_PASEO_WORKSPACE_ARCHIVE_FAIL="$workspace_archive_fail" \
    fm_test_run_spawn "$home" "$worktree" "$FAKEBIN_DIR" \
      "$id" "$project" --mode no-mistakes --yolo off --backend paseo --harness codex)
  status=$?
  task_worktree=$(awk -F '\t' -v id="$workspace" '$1 == id {print $4}' "$PASEO_WORKSPACES" | tail -n 1)
  expect_code 1 "$status" "forced post-return setup failure must abort $label spawn"
  assert_grep "fm-$id" "$PASEO_ARGS" "Paseo run did not create $label task"
  assert_present "$task_tmp" "forced task temporary directory failure did not occur"

  case "$label" in
    dirty)
      assert_contains "$out" "agent $agent and workspace $workspace" "dirty abort did not report both Paseo identities"
      assert_contains "$out" 'uncommitted, untracked, or ignored files' "dirty abort did not explain why the workspace was retained"
      assert_present "$task_worktree/.paseo-uncommitted" "dirty abort removed the worktree change"
      assert_no_grep "archive|archive $agent" "$PASEO_ARGS" "dirty abort archived the Paseo agent"
      assert_no_grep "workspace_archive|workspace archive $workspace" "$PASEO_ARGS" "dirty abort archived the Paseo workspace"
      ;;
    ignored)
      assert_contains "$out" "agent $agent and workspace $workspace" "ignored-file abort did not report both Paseo identities"
      assert_contains "$out" 'uncommitted, untracked, or ignored files' "ignored-file abort did not explain why the workspace was retained"
      assert_present "$task_worktree/.env" "ignored-file abort removed the ignored worktree file"
      status=$(git -C "$task_worktree" status --porcelain --untracked-files=all)
      assert_equals '' "$status" "ignored-file fixture should appear clean to ordinary Git status"
      status=$(git -C "$task_worktree" status --porcelain --untracked-files=all --ignored)
      assert_contains "$status" '!! .env' "ignored-file fixture was not reported by Git's ignored status"
      assert_no_grep "archive|archive $agent" "$PASEO_ARGS" "ignored-file abort archived the Paseo agent"
      assert_no_grep "workspace_archive|workspace archive $workspace" "$PASEO_ARGS" "ignored-file abort archived the Paseo workspace"
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

run_abort_case dirty
run_abort_case ignored
run_abort_case stop-failed
run_abort_case archive-failed
run_abort_case workspace-archive-failed
run_abort_case clean
pass "Paseo environment forwarding and abort cleanup preserve workspaces safely"
