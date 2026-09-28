#!/usr/bin/env bash
# Portable contract tests for the Paseo adapter.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-backend-paseo-tests)
FB="$TMP_ROOT/bin"
mkdir -p "$FB"
STATUS="$TMP_ROOT/status"
printf 'running\n' >"$STATUS"
LOG="$TMP_ROOT/log"
PROJECTS="$TMP_ROOT/projects.json"
WORKSPACES="$TMP_ROOT/workspaces.tsv"
SOURCE="$TMP_ROOT/source"
EXISTING_WT="$TMP_ROOT/existing-worktree"
WORKTREE_ROOT="$TMP_ROOT/task-worktrees"
mkdir -p "$SOURCE"
mkdir -p "$WORKTREE_ROOT"
git -C "$SOURCE" init -q
git -C "$SOURCE" config user.email test@example.com
git -C "$SOURCE" config user.name test
printf 'base\n' >"$SOURCE/file"
git -C "$SOURCE" add file
git -C "$SOURCE" commit -qm base
git -C "$SOURCE" branch -M main
git -C "$SOURCE" checkout -qb feature
jq -n --arg path "$SOURCE" '[{projectId:"project-main",name:"firstmate",path:$path}]' >"$PROJECTS"
git -C "$SOURCE" worktree add -q -b existing-task "$EXISTING_WT" main
printf 'wks-existing\tfirstmate\tworktree\t%s\n' "$EXISTING_WT" >"$WORKSPACES"

cat > "$FB/paseo" <<'SH'
#!/usr/bin/env bash
printf 'agent=%s workspace=%s|%s\n' "${PASEO_AGENT_ID-unset}" "${PASEO_WORKSPACE_ID-unset}" "$*" >> "$FM_PASEO_LOG"
case "$*" in
  "daemon status") exit 0 ;;
  "provider diagnostic claude --json")
    case "${FM_PASEO_CLAUDE_DIAGNOSTIC:-failed}" in
      available) printf '%s\n' '{"provider":"claude","diagnostic":"Status: Ready\n"}' ;;
      unavailable) printf '%s\n' '{"provider":"claude","diagnostic":"Status: Unavailable\n"}' ;;
      empty) printf '%s\n' '{}' ;;
      unknown) printf '%s\n' '{"provider":"claude","diagnostic":"Status: Unknown\n"}' ;;
      json-disabled) printf '%s\n' '{"provider":"claude","enabled":false,"diagnostic":"Status: Ready\n"}' ;;
      *) exit 1 ;;
    esac
    ;;
  "provider ls --json")
    if [ "${FM_PASEO_CLAUDE_DIAGNOSTIC:-failed}" = available ]; then
      printf '%s\n' '[{"provider":"claude","status":"available","enabled":"Enabled"}]'
    else
      printf '%s\n' '[{"provider":"claude","status":"unavailable","enabled":"Disabled"}]'
    fi
    ;;
  "project ls --json") cat "$FM_PASEO_PROJECTS_JSON" ;;
  "workspace ls --json")
    printf '['
    separator=
    while IFS=$'\t' read -r id project isolation path; do
      [ -n "$id" ] || continue
      printf '%s' "$separator"
      jq -nc --arg id "$id" --arg project "$project" --arg isolation "$isolation" --arg path "$path" \
        '{workspaceId:$id,project:$project,isolation:$isolation,cwd:$path}'
      separator=,
    done < "$FM_PASEO_WORKSPACES_FILE"
    printf ']\n'
    ;;
  "inspect "*) printf '{"status":"%s"}\n' "$(cat "$FM_PASEO_STATUS")" ;;
  logs\ *)
    [ "${FM_PASEO_LOGS_FAIL:-0}" = 1 ] && exit 1
    [ "${FM_PASEO_LOGS_EMPTY:-0}" = 1 ] && exit 0 || printf 'Paseo transcript: timeline\n'
    ;;
  send\ *)
    [ "${FM_PASEO_SEND_FAIL:-0}" = 1 ] && exit 1
    printf 'accepted by paseo\n'
    ;;
  stop\ *) printf 'stopped\n' >> "$FM_PASEO_LOG"; printf 'idle\n' >"$FM_PASEO_STATUS" ;;
  archive\ *) printf 'archived\n' >> "$FM_PASEO_LOG"; printf 'archived\n' >"$FM_PASEO_STATUS" ;;
  workspace\ archive\ *) printf 'workspace-archived\n' >> "$FM_PASEO_LOG" ;;
  workspace\ create\ *)
    source=
    project_id=
    slug=
    base=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --path) source=$2; shift 2 ;;
        --project) project_id=$2; shift 2 ;;
        --new-branch) slug=$2; shift 2 ;;
        --base) base=$2; shift 2 ;;
        *) shift ;;
      esac
    done
    project_name=$(jq -r --arg id "$project_id" '.[] | select(.projectId == $id) | .name' "$FM_PASEO_PROJECTS_JSON" | head -n 1)
    id="wks-$slug"
    path="$FM_PASEO_WORKTREE_ROOT/$slug"
    git -C "$source" worktree add -q -b "$slug" "$path" "$base" || exit 1
    printf '%s\t%s\tworktree\t%s\n' "$id" "$project_name" "$path" >> "$FM_PASEO_WORKSPACES_FILE"
    printf 'Created workspace %s\n' "$id"
    jq -nc --arg id "$id" --arg path "$path" '{workspaceId:$id,cwd:$path}'
    ;;
  "run "*)
    if [ "${FM_PASEO_RUN_FAIL:-0}" = 1 ]; then
      workspace_id=
      previous=
      while [ "$#" -gt 0 ]; do
        if [ "$previous" = --workspace ]; then workspace_id=$1; fi
        previous=$1
        shift
      done
      printf 'Using workspace %s\nPaseo run failed after workspace selection\n' "$workspace_id"
      exit 1
    fi
    workspace_id=
    previous=
    while [ "$#" -gt 0 ]; do
      if [ "$previous" = --workspace ]; then workspace_id=$1; fi
      previous=$1
      shift
    done
    workspace_path=$(awk -F '\t' -v id="$workspace_id" '$1 == id {print $4}' "$FM_PASEO_WORKSPACES_FILE" | tail -n 1)
    printf 'Using workspace %s\n' "$workspace_id"
    printf '{"agentId":"agent-test","cwd":"%s"}\n' "$workspace_path"
    ;;
esac
exit 0
SH
chmod +x "$FB/paseo"
export PATH="$FB:$PATH" FM_PASEO_LOG="$LOG" FM_PASEO_STATUS="$STATUS"
export FM_PASEO_PROJECTS_JSON="$PROJECTS" FM_PASEO_WORKSPACES_FILE="$WORKSPACES" FM_PASEO_WORKTREE_ROOT="$WORKTREE_ROOT"
# shellcheck source=bin/fm-backend.sh
. "$(dirname "${BASH_SOURCE[0]}")/../bin/fm-backend.sh"
fm_backend_source paseo

assert_contains "$(fm_backend_paseo_provider codex)" codex "Codex maps to Paseo"
if fm_backend_paseo_provider claude >/dev/null 2>&1; then fail "disabled Claude provider was accepted"; fi
export FM_PASEO_CLAUDE_DIAGNOSTIC=unavailable
if fm_backend_paseo_provider claude >/dev/null 2>&1; then fail "semantically unavailable Claude provider was accepted"; fi
for diagnostic in empty unknown json-disabled; do
  export FM_PASEO_CLAUDE_DIAGNOSTIC=$diagnostic
  if fm_backend_paseo_provider claude >/dev/null 2>&1; then fail "$diagnostic Claude diagnostic was accepted"; fi
done
export FM_PASEO_CLAUDE_DIAGNOSTIC=available
assert_contains "$(fm_backend_paseo_provider claude)" claude "available Claude provider maps to Paseo"
if fm_backend_paseo_provider muse >/dev/null 2>"$TMP_ROOT/provider-error"; then fail "unsupported Muse provider was accepted"; fi
assert_contains "$(cat "$TMP_ROOT/provider-error")" muse "unsupported provider refusal names the harness"
assert_contains "$(fm_backend_paseo_agent_state agent-test)" unverified "Paseo liveness stays unverified"
assert_contains "$(fm_backend_paseo_busy_state agent-test)" busy "Paseo running status is busy"
printf 'error\n' >"$STATUS"
assert_contains "$(fm_backend_paseo_busy_state agent-test)" unknown "Paseo error status is not healthy idle"
printf 'running\n' >"$STATUS"
assert_contains "$(fm_backend_paseo_capture agent-test 4)" timeline "Paseo capture retains timeline logs"
if fm_backend_paseo_capture agent-test 4 | grep -q 'Paseo status'; then fail "Paseo status leaked into diagnostics"; fi
export FM_PASEO_LOGS_EMPTY=1
[ -z "$(fm_backend_paseo_capture agent-test 4)" ] || fail "valid empty Paseo logs should remain empty"
export FM_PASEO_LOGS_FAIL=1
if fm_backend_paseo_capture agent-test 4 >/dev/null 2>&1; then fail "failed Paseo logs command was treated as empty success"; fi
unset FM_PASEO_LOGS_EMPTY FM_PASEO_LOGS_FAIL
if [ -n "$(fm_backend_paseo_send_text_submit agent-test hello)" ]; then fail "Paseo send leaked provider output as a verdict"; fi
export FM_PASEO_SEND_FAIL=1
if fm_backend_paseo_send_text_submit agent-test hello >/dev/null 2>&1; then fail "failed Paseo send was treated as success"; fi
unset FM_PASEO_SEND_FAIL
if fm_backend_paseo_terminal_proof agent-test; then fail "idle Paseo status was treated as terminal proof"; fi
if fm_backend_paseo_stop_status_proof agent-test 1 0.01; then fail "idle Paseo status was treated as a successful stop proof"; fi
printf 'closed\n' >"$STATUS"
fm_backend_paseo_terminal_proof agent-test || fail "closed Paseo status did not prove the endpoint terminal"
printf 'idle\n' >"$STATUS"
fm_backend_paseo_archive_agent agent-test
assert_contains "$(fm_backend_paseo_busy_state agent-test)" idle "Paseo archive leaves a native terminal status"

export PASEO_AGENT_ID=parent-agent PASEO_WORKSPACE_ID=parent-workspace
fm_backend_paseo_create_task task-test "$SOURCE" "$PWD/README.md" codex default default home-tag wks-existing "$EXISTING_WT" A=1 B=2 >/dev/null
assert_contains "$(cat "$LOG")" '--workspace wks-existing' "Paseo relaunch targets its validated workspace"
assert_contains "$(cat "$LOG")" 'agent=unset workspace=unset|run' "Paseo workers are independent roots without the caller workspace"
assert_contains "$(cat "$LOG")" '--env A=1 --env B=2' "Paseo preserves repeated env values"
assert_not_contains "$(cat "$LOG")" 'BASH_ENV=' "Paseo does not rely on a shell environment file"
assert_not_contains "$(cat "$LOG")" '--mode auto-review' "Codex does not receive a forced review mode"
assert_contains "$(fm_backend_paseo_create_task opencode-test "$SOURCE" "$PWD/README.md" opencode default default home-tag wks-existing "$EXISTING_WT")" $'agent-test\twks-existing\t' \
  "Paseo retains validated workspace identity when run output only says Using workspace"
assert_contains "$(cat "$LOG")" '--mode build' "OpenCode retains its build mode"

if FM_PASEO_RUN_FAIL=1 fm_backend_paseo_create_task partial-run "$SOURCE" "$PWD/README.md" codex default default home-tag '' '' >/dev/null 2>"$TMP_ROOT/run-failure"; then
  fail "Paseo run failure after workspace creation was accepted"
fi
assert_contains "$(cat "$TMP_ROOT/run-failure")" 'workspace wks-fm-home-tag-partial-run' "Paseo run failure did not identify its created workspace"
assert_not_contains "$(cat "$LOG")" 'workspace archive wks-fm-home-tag-partial-run' "Paseo auto-archived a partially created workspace"

fm_backend_paseo_create_task fresh-a "$SOURCE" "$PWD/README.md" codex gpt-6-luna high home-tag '' '' >/dev/null
fm_backend_paseo_create_task fresh-b "$SOURCE" "$PWD/README.md" codex gpt-6-luna high home-tag '' '' >/dev/null
fresh_a_line=$(grep '|workspace create ' "$LOG" | grep 'fm-home-tag-fresh-a' | tail -n 1)
fresh_b_line=$(grep '|workspace create ' "$LOG" | grep 'fm-home-tag-fresh-b' | tail -n 1)
assert_contains "$fresh_a_line" '--project project-main' "fresh Paseo task was not placed under the existing project"
assert_contains "$fresh_a_line" "--path $SOURCE" "fresh Paseo task did not use the registered source path"
assert_contains "$fresh_a_line" '--mode branch-off --new-branch fm-home-tag-fresh-a --base main --worktree-slug fm-home-tag-fresh-a --json' \
  "fresh Paseo task did not receive its unique isolated branch and workspace slug"
assert_contains "$fresh_b_line" '--new-branch fm-home-tag-fresh-b' "second task did not receive its own branch"
assert_contains "$(grep '|run ' "$LOG" | grep 'fm-task=fresh-a' | tail -n 1)" '--label fm-task=fresh-a --label fm-home=home-tag' \
  "fresh Paseo task did not receive unique task and home labels"
assert_contains "$(grep '|run ' "$LOG" | grep 'fm-task=fresh-a' | tail -n 1)" '--title fm-home-tag-fresh-a' \
  "fresh Paseo agent did not receive a unique title"
assert_not_contains "$(cat "$LOG")" 'project create' "Paseo adapter created a per-task project"
assert_not_contains "$(cat "$LOG")" '--new-workspace' "Paseo adapter used the project-creating run shortcut"
assert_not_contains "$fresh_a_line" 'parent-workspace' "Paseo fresh spawn inherited the ambient caller workspace"

cp "$PROJECTS" "$TMP_ROOT/projects-saved.json"
printf '[]\n' >"$PROJECTS"
if fm_backend_paseo_create_task no-project "$SOURCE" "$PWD/README.md" codex default default home-tag '' '' >/dev/null 2>"$TMP_ROOT/no-project"; then
  fail "Paseo created a task without a registered source project"
fi
assert_contains "$(cat "$TMP_ROOT/no-project")" 'no registered Paseo project' "missing project refusal did not explain the identity problem"
printf '[{"projectId":"project-main","name":"firstmate","path":"%s"},{"projectId":"project-duplicate","name":"firstmate-copy","path":"%s"}]\n' "$SOURCE" "$SOURCE" >"$PROJECTS"
if fm_backend_paseo_create_task duplicate-project "$SOURCE" "$PWD/README.md" codex default default home-tag '' '' >/dev/null 2>"$TMP_ROOT/duplicate-project"; then
  fail "Paseo reused an ambiguous project path"
fi
assert_contains "$(cat "$TMP_ROOT/duplicate-project")" '2 Paseo projects match' "ambiguous project refusal did not explain the collision"
mv "$TMP_ROOT/projects-saved.json" "$PROJECTS"

git -C "$SOURCE" worktree add -q -b wrong-project "$TMP_ROOT/wrong-project-worktree" main
printf 'wks-wrong-project\tother-project\tworktree\t%s\n' "$TMP_ROOT/wrong-project-worktree" >>"$WORKSPACES"
if fm_backend_paseo_create_task wrong-project "$SOURCE" "$PWD/README.md" codex default default home-tag wks-wrong-project "$TMP_ROOT/wrong-project-worktree" >/dev/null 2>"$TMP_ROOT/wrong-project"; then
  fail "Paseo reused a workspace attached to another project"
fi
assert_contains "$(cat "$TMP_ROOT/wrong-project")" 'not the registered source project' "wrong-project workspace refusal did not name the project mismatch"
assert_not_contains "$(tail -n 8 "$LOG")" 'run --background --workspace wks-wrong-project' "Paseo ran inside a workspace with the wrong project identity"

printf 'wks-local\tfirstmate\tlocal\t%s\n' "$SOURCE" >>"$WORKSPACES"
if fm_backend_paseo_create_task unsafe-local "$SOURCE" "$PWD/README.md" codex default default home-tag wks-local "$EXISTING_WT" >/dev/null 2>"$TMP_ROOT/unsafe-local"; then
  fail "Paseo reused a local workspace for an isolated task"
fi
assert_contains "$(cat "$TMP_ROOT/unsafe-local")" 'is not a worktree workspace' "unsafe workspace refusal did not name isolation"

MISMATCH_WT="$TMP_ROOT/mismatched-recorded-worktree"
git -C "$SOURCE" worktree add -q -b mismatched-recorded-worktree "$MISMATCH_WT" main
runs_before=$(grep -c '|run ' "$LOG" || true)
if fm_backend_paseo_create_task mismatched-worktree "$SOURCE" "$PWD/README.md" codex default default home-tag wks-existing "$MISMATCH_WT" >/dev/null 2>"$TMP_ROOT/mismatched-worktree"; then
  fail "Paseo reused a workspace with a different recorded worktree path"
fi
assert_contains "$(cat "$TMP_ROOT/mismatched-worktree")" 'not its recorded worktree' "worktree mismatch refusal did not explain the identity conflict"
assert_equals "$runs_before" "$(grep -c '|run ' "$LOG" || true)" "Paseo ran after the recorded worktree path mismatch"

unset PASEO_AGENT_ID PASEO_WORKSPACE_ID
fm_backend_paseo_kill agent-test wks-existing
agent_archive_line=$(grep -n 'archive agent-test' "$LOG" | tail -n 1 | cut -d: -f1)
workspace_archive_line=$(grep -n 'workspace archive wks-existing' "$LOG" | tail -n 1 | cut -d: -f1)
[ -n "$agent_archive_line" ] && [ -n "$workspace_archive_line" ] && [ "$agent_archive_line" -lt "$workspace_archive_line" ] \
  || fail "Paseo kill must archive the agent before its task workspace"
if fm_backend_paseo_send_key agent-test Escape >/dev/null 2>&1; then fail "unsupported Paseo key was accepted"; fi
fm_backend_paseo_send_key agent-test C-c >/dev/null
assert_contains "$(cat "$LOG")" agent-test "Paseo control calls reached the stub"
pass "Paseo project grouping, task-isolated workspaces, relaunch identity, provider, status, and control contracts"
