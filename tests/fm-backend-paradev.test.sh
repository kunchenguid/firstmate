#!/usr/bin/env bash
# tests/fm-backend-paradev.test.sh - fake-superset-CLI unit tests for the
# Paradev adapter in bin/backends/paradev.sh and the fm-spawn.sh,
# fm-peek.sh, fm-send.sh, fm-crew-state.sh, and fm-teardown.sh paths that
# route through it.
#
# The fake CLI answers by command key (`<group>-<verb>`, e.g.
# `terminals-read`) rather than by global call order, so a case only has to
# script the calls it cares about: `$RESP/<key>.<n>.out|.exit|.err` answers the
# n-th call of that key, `$RESP/<key>.out|.exit|.err` answers every other call,
# and an unscripted key prints `{}` and exits 0. Every call is logged with its
# arguments separated by \x1f.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-backend-paradev-tests)
# A claude spawn writes workspace trust into the launching user's own store,
# resolved as ${CLAUDE_CONFIG_DIR:-${HOME:-}}, so the value is pinned EMPTY
# beside a throwaway HOME and never reaches the developer's real store.
SPAWN_HOME="$TMP_ROOT/user-home"
mkdir -p "$SPAWN_HOME"

WS=11111111-2222-4333-8444-555555555555
TERM_ID=66666666-7777-4888-8999-aaaaaaaaaaaa
PROJECT_ID=bbbbbbbb-cccc-4ddd-8eee-ffffffffffff
SEP=$'\x1f'

write_spawn_brief() {  # <data-dir> <id>
  local data=$1 id=$2
  cat > "$data/$id/brief.md" <<'EOF'
# Task
## Captain's intent
Exercise Paradev dispatch.

## Firstmate spec
Verify the Paradev lifecycle behavior under test.
EOF
}

make_superset_fakebin() {  # <dir> -> echoes fakebin dir
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/superset" <<'SH'
#!/usr/bin/env bash
set -u
LOG="${FM_PARADEV_LOG:?}"
RESP="${FM_PARADEV_RESPONSES:?}"
{
  printf 'superset'
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$LOG"
key="${1:-}-${2:-}"
count_file="$RESP/.count-$key"
n=$(( $(cat "$count_file" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$count_file"
for base in "$RESP/$key.$n" "$RESP/$key"; do
  if [ -f "$base.out" ] || [ -f "$base.exit" ] || [ -f "$base.err" ]; then
    [ ! -f "$base.err" ] || cat "$base.err" >&2
    [ ! -f "$base.out" ] || cat "$base.out"
    exit "$(cat "$base.exit" 2>/dev/null || echo 0)"
  fi
done
printf '{}\n'
exit 0
SH
  chmod +x "$fb/superset"
  printf '%s\n' "$fb"
}

paradev_case() {  # <name> -> sets CASE_DIR LOG RESP FB
  CASE_DIR="$TMP_ROOT/$1"
  mkdir -p "$CASE_DIR/responses"
  LOG="$CASE_DIR/log"
  RESP="$CASE_DIR/responses"
  : > "$LOG"
  FB=$(make_superset_fakebin "$CASE_DIR")
}

respond() {  # <key> <json> ; answers every call of <key>
  printf '%s\n' "$2" > "$RESP/$1.out"
}

respond_nth() {  # <key> <n> <json>
  printf '%s\n' "$3" > "$RESP/$1.$2.out"
}

respond_error() {  # <key> <message> [n]
  local base="$RESP/$1"
  [ -z "${3:-}" ] || base="$RESP/$1.$3"
  printf 'Error: %s\n' "$2" > "$base.err"
  printf '1\n' > "$base.exit"
}

neutral_fm_root() {  # <dir> -> echoes a minimal root with a quiet guard
  local root="$1/root"
  mkdir -p "$root/bin"
  cat > "$root/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$root/bin/fm-guard.sh"
  printf '%s\n' "$root"
}

# adapter <bash-snippet> : run a snippet with bin/backends/paradev.sh sourced
# and the fake CLI first on PATH.
adapter() {
  PATH="$FB:$PATH" FM_PARADEV_LOG="$LOG" FM_PARADEV_RESPONSES="$RESP" \
    bash -c '. "$0/bin/backends/paradev.sh"; eval "$1"' "$ROOT" "$1"
}

log_has() {  # <needle> <message>
  assert_contains "$(cat "$LOG")" "$1" "$2"
}

log_lacks() {  # <needle> <message>
  assert_not_contains "$(cat "$LOG")" "$1" "$2"
}

ws_row() {  # <id> <path> [archivedAt-json]
  printf '{"id":"%s","projectId":"%s","name":"fm-x","branch":"fm/x","type":"worktree","tags":"firstmate","worktreePath":"%s","worktreeExists":true,"archivedAt":%s}' \
    "$1" "$PROJECT_ID" "$2" "${3:-null}"
}

projects_json() {  # <path>
  printf '[{"name":"proj","repo":"-","path":"%s","id":"%s"}]' "$1" "$PROJECT_ID"
}

composer_empty_json() {
  printf '{"terminalId":"%s","cols":80,"rows":3,"text":"────────────────\\n❯ \\n────────────────"}' "$TERM_ID"
}

# --- adapter primitives -------------------------------------------------------

test_runtime_check_probes_a_real_call_not_status() {
  local out
  paradev_case runtime-ok
  respond projects-list '[]'
  out=$(adapter 'fm_backend_paradev_runtime_check' 2>&1)
  expect_code 0 $? "runtime_check should accept a readable project list"$'\n'"$out"
  log_has "superset${SEP}projects${SEP}list${SEP}--local${SEP}--json" \
    "runtime_check did not probe projects list --local --json"
  log_lacks "superset${SEP}status" \
    "runtime_check must not trust superset status (it reports running:false while the host works)"
  pass "fm_backend_paradev_runtime_check: probes a real cheap call, never superset status"
}

test_runtime_check_refuses_unreachable_host() {
  local out status
  paradev_case runtime-down
  respond_error projects-list "Host service is not running"
  out=$(adapter 'fm_backend_paradev_runtime_check' 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "runtime_check should refuse when the host call fails"
  assert_contains "$out" "backend=paradev" "runtime_check refusal should name the backend"
  assert_contains "$out" "Host service is not running" "runtime_check should surface the CLI error"
  # shellcheck disable=SC2016 # the snippet expands its variables inside the adapter shell.
  out=$(adapter 'printf "not json" > "$FM_PARADEV_RESPONSES/projects-list.out"; rm -f "$FM_PARADEV_RESPONSES/projects-list.exit" "$FM_PARADEV_RESPONSES/projects-list.err"; fm_backend_paradev_runtime_check' 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "runtime_check should refuse a project list that is not a JSON array"
  pass "fm_backend_paradev_runtime_check: refuses when the host cannot answer"
}

test_tool_check_names_missing_superset_and_jq() {
  local out status emptybin
  paradev_case tools-missing
  emptybin="$CASE_DIR/emptybin"
  mkdir -p "$emptybin"
  out=$(PATH="$emptybin:/usr/bin:/bin" bash -c 'PATH=$1; . "$0/bin/backends/paradev.sh"; fm_backend_paradev_tool_check' "$ROOT" "$emptybin" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "tool_check should fail without superset"
  assert_contains "$out" "'superset' CLI is not installed" "tool_check should name the missing superset CLI"
  pass "fm_backend_paradev_tool_check: names a missing superset CLI"
}

test_project_id_resolves_by_canonical_path() {
  local proj out
  paradev_case project-id
  proj="$CASE_DIR/proj"
  mkdir -p "$proj"
  respond projects-list "[{\"name\":\"other\",\"repo\":\"-\",\"path\":\"/elsewhere\",\"id\":\"other-id\"},$(projects_json "$(cd "$proj" && pwd -P)" | sed 's/^\[//; s/\]$//')]"
  out=$(adapter "fm_backend_paradev_project_id '$proj/.'")
  expect_code 0 $? "project_id should resolve a registered path"
  [ "$out" = "$PROJECT_ID" ] || fail "project_id should print the matching project id, got '$out'"
  pass "fm_backend_paradev_project_id: matches the canonical project path"
}

test_project_id_refuses_unregistered_and_ambiguous_paths() {
  local proj out status real
  paradev_case project-id-refusals
  proj="$CASE_DIR/proj"
  mkdir -p "$proj"
  real=$(cd "$proj" && pwd -P)
  respond_nth projects-list 1 '[{"name":"other","repo":"-","path":"/elsewhere","id":"other-id"}]'
  out=$(adapter "fm_backend_paradev_project_id '$proj'" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "project_id should refuse a path Paradev does not know"
  assert_contains "$out" "is not a Paradev project on this host" "unregistered refusal should explain the requirement"
  assert_contains "$out" "superset projects create" "unregistered refusal should name the registration command"
  respond_nth projects-list 2 "[{\"path\":\"$real\",\"id\":\"a\"},{\"path\":\"$real\",\"id\":\"b\"}]"
  out=$(adapter "fm_backend_paradev_project_id '$proj'" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "project_id should refuse two projects on one path"
  assert_contains "$out" "more than one Paradev project" "ambiguous refusal should say why"
  log_lacks "superset${SEP}projects${SEP}create" "project_id must never register a project itself"
  pass "fm_backend_paradev_project_id: refuses unregistered and ambiguous paths, never registers"
}

test_worktree_create_tags_and_reads_back_path() {
  local out
  paradev_case wt-create
  respond workspaces-create "{\"workspace\":{\"id\":\"$WS\",\"name\":\"fm-t\",\"branch\":\"fm/t\",\"type\":\"worktree\",\"tags\":null},\"terminals\":[],\"agents\":[],\"alreadyExists\":false}"
  respond workspaces-get "$(ws_row "$WS" /paradev/wt/fm-t)"
  out=$(adapter "fm_backend_paradev_worktree_create '$PROJECT_ID' fm-t fm/t ''")
  expect_code 0 $? "worktree_create should succeed"
  [ "$out" = "$WS"$'\t'"/paradev/wt/fm-t" ] || fail "worktree_create should print id<TAB>path, got '$out'"
  log_has "superset${SEP}workspaces${SEP}create${SEP}--local${SEP}--project${SEP}$PROJECT_ID${SEP}--name${SEP}fm-t${SEP}--branch${SEP}fm/t${SEP}--skip-branch-prefix${SEP}--tag${SEP}firstmate${SEP}--json" \
    "worktree_create did not create a firstmate-tagged workspace on the exact branch"
  log_lacks "${SEP}--agent" "worktree_create must not ask Paradev to launch an agent"
  log_lacks "${SEP}--base-branch" "worktree_create must not pass an empty base branch"
  log_has "superset${SEP}workspaces${SEP}get${SEP}$WS${SEP}--local${SEP}--json" \
    "worktree_create did not read the worktree path back by the created id"
  pass "fm_backend_paradev_worktree_create: one firstmate tag, exact branch, path read back by id"
}

test_worktree_create_passes_base_branch() {
  paradev_case wt-create-base
  respond workspaces-create "{\"workspace\":{\"id\":\"$WS\"},\"alreadyExists\":false}"
  respond workspaces-get "$(ws_row "$WS" /paradev/wt/fm-t)"
  adapter "fm_backend_paradev_worktree_create '$PROJECT_ID' fm-t fm/t release/2" >/dev/null
  expect_code 0 $? "worktree_create with a base branch should succeed"
  log_has "${SEP}--base-branch${SEP}release/2${SEP}" "worktree_create did not pass --base-branch"
  pass "fm_backend_paradev_worktree_create: passes a recorded base branch"
}

test_worktree_create_refuses_an_existing_workspace() {
  local out status
  paradev_case wt-create-exists
  respond workspaces-create "{\"workspace\":{\"id\":\"$WS\"},\"alreadyExists\":true}"
  out=$(adapter "fm_backend_paradev_worktree_create '$PROJECT_ID' fm-t fm/t ''" 2>&1)
  status=$?
  [ "$status" -eq 1 ] || fail "worktree_create should refuse with 1 when Paradev reused an existing workspace, got $status"
  assert_contains "$out" "already exists" "existing-workspace refusal should say so"
  log_lacks "superset${SEP}workspaces${SEP}archive" "a workspace Firstmate did not create must never be archived"
  pass "fm_backend_paradev_worktree_create: refuses to adopt an existing workspace and never archives it"
}

test_worktree_create_archives_when_path_unreadable() {
  local out status
  paradev_case wt-create-nopath
  respond workspaces-create "{\"workspace\":{\"id\":\"$WS\"},\"alreadyExists\":false}"
  respond workspaces-get "{\"id\":\"$WS\",\"worktreePath\":null}"
  respond workspaces-archive "{\"deleted\":[\"$WS\"],\"notFound\":[],\"failed\":[],\"warnings\":[]}"
  out=$(adapter "fm_backend_paradev_worktree_create '$PROJECT_ID' fm-t fm/t ''" 2>&1)
  status=$?
  [ "$status" -eq 1 ] || fail "worktree_create should return 1 after archiving a pathless workspace, got $status"
  assert_contains "$out" "did not return a worktree path" "pathless refusal should explain"
  log_has "superset${SEP}workspaces${SEP}archive${SEP}$WS${SEP}--local${SEP}--json" \
    "worktree_create did not archive the workspace it just created"
  pass "fm_backend_paradev_worktree_create: archives its own pathless workspace"
}

test_worktree_create_reports_partial_when_archive_fails() {
  local out status
  paradev_case wt-create-nopath-leak
  respond workspaces-create "{\"workspace\":{\"id\":\"$WS\"},\"alreadyExists\":false}"
  respond_error workspaces-get "boom"
  respond workspaces-archive "{\"deleted\":[],\"notFound\":[],\"failed\":[\"$WS\"],\"warnings\":[]}"
  out=$(adapter "fm_backend_paradev_worktree_create '$PROJECT_ID' fm-t fm/t ''" 2>/dev/null)
  status=$?
  [ "$status" -eq 2 ] || fail "worktree_create should return 2 when its own cleanup failed, got $status"
  [ "$out" = "$WS"$'\t' ] || fail "partial result should carry the created id and an empty path, got '$out'"
  pass "fm_backend_paradev_worktree_create: returns 2 with the created id when cleanup fails"
}

test_terminal_create_returns_composite_target() {
  local out status
  paradev_case term-create
  respond terminals-create "{\"terminalId\":\"$TERM_ID\",\"status\":\"active\"}"
  out=$(adapter "fm_backend_paradev_terminal_create '$WS'")
  expect_code 0 $? "terminal_create should succeed"
  [ "$out" = "$WS:$TERM_ID" ] || fail "terminal_create should print <workspace>:<terminal>, got '$out'"
  log_has "superset${SEP}terminals${SEP}create${SEP}--local${SEP}--workspace${SEP}$WS${SEP}--json" \
    "terminal_create did not open a plain shell terminal in the workspace"
  log_lacks "${SEP}--command" "terminal_create must open an interactive shell"
  respond terminals-create '{"status":"active"}'
  out=$(adapter "fm_backend_paradev_terminal_create '$WS'" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "terminal_create should refuse a reply without terminalId"
  pass "fm_backend_paradev_terminal_create: returns workspace:terminal, refuses a reply without an id"
}

test_capture_reads_screen_text() {
  local out
  paradev_case capture
  respond terminals-read "{\"terminalId\":\"$TERM_ID\",\"cols\":80,\"rows\":3,\"text\":\"line one\\nline two\"}"
  out=$(adapter "fm_backend_paradev_capture '$WS:$TERM_ID' 40")
  [ "$out" = $'line one\nline two' ] || fail "capture should print .text, got '$out'"
  log_has "superset${SEP}terminals${SEP}read${SEP}--local${SEP}--workspace${SEP}$WS${SEP}--terminal${SEP}$TERM_ID${SEP}--max-lines${SEP}40${SEP}--json" \
    "capture did not read the recorded workspace and terminal"
  pass "fm_backend_paradev_capture: reads .text for the recorded workspace and terminal"
}

test_capture_fails_closed_on_cli_error_and_bad_target() {
  local out status
  paradev_case capture-error
  respond_error terminals-read "Terminal session $TERM_ID has ended"
  out=$(adapter "fm_backend_paradev_capture '$WS:$TERM_ID' 5" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "capture should fail on a CLI error"
  assert_contains "$out" "has ended" "capture should surface the CLI error"
  out=$(adapter "fm_backend_paradev_capture 'no-colon-target' 5" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "capture should refuse a target without workspace:terminal"
  assert_contains "$out" "malformed Paradev target" "bad target refusal should say so"
  [ "$(grep -c 'no-colon-target' "$LOG")" -eq 0 ] || fail "a malformed target must never reach the CLI"
  pass "fm_backend_paradev_capture: fails closed on CLI errors and malformed targets"
}

test_send_key_maps_shared_names() {
  paradev_case send-key
  respond terminals-send "{\"terminalId\":\"$TERM_ID\",\"keys\":1}"
  adapter "fm_backend_paradev_send_key '$WS:$TERM_ID' Enter && fm_backend_paradev_send_key '$WS:$TERM_ID' Escape && fm_backend_paradev_send_key '$WS:$TERM_ID' C-c && fm_backend_paradev_send_key '$WS:$TERM_ID' C-u"
  expect_code 0 $? "send_key should accept Enter, Escape, C-c, C-u"
  for k in enter esc ctrl+c ctrl+u; do
    log_has "superset${SEP}terminals${SEP}send${SEP}--local${SEP}--workspace${SEP}$WS${SEP}--terminal${SEP}$TERM_ID${SEP}--keys${SEP}$k${SEP}--json" \
      "send_key did not map to --keys $k"
  done
  pass "fm_backend_paradev_send_key: Enter/Escape/C-c/C-u map to Paradev key names"
}

test_send_key_refuses_unknown_key() {
  local out status
  paradev_case send-key-unknown
  out=$(adapter "fm_backend_paradev_send_key '$WS:$TERM_ID' F13" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "send_key should refuse an unsupported key"
  assert_contains "$out" "unsupported Paradev key 'F13'" "unsupported key refusal should name the key"
  [ ! -s "$LOG" ] || fail "an unsupported key must not reach the CLI"
  pass "fm_backend_paradev_send_key: refuses unsupported keys before any CLI call"
}

test_send_literal_and_line() {
  paradev_case send-text
  respond terminals-send "{\"terminalId\":\"$TERM_ID\",\"submitted\":false}"
  adapter "fm_backend_paradev_send_literal '$WS:$TERM_ID' 'typed only' && fm_backend_paradev_send_text_line '$WS:$TERM_ID' 'cd -- /x'"
  expect_code 0 $? "send_literal and send_text_line should succeed"
  log_has "superset${SEP}terminals${SEP}send${SEP}--local${SEP}--workspace${SEP}$WS${SEP}--terminal${SEP}$TERM_ID${SEP}--text=typed only${SEP}--no-submit${SEP}--json" \
    "send_literal did not stage text without submitting"
  log_has "superset${SEP}terminals${SEP}send${SEP}--local${SEP}--workspace${SEP}$WS${SEP}--terminal${SEP}$TERM_ID${SEP}--text=cd -- /x${SEP}--json" \
    "send_text_line did not submit the line"
  [ "$(grep -c "cd -- /x${SEP}--no-submit" "$LOG")" -eq 0 ] || fail "send_text_line must submit, not stage"
  # The CLI reads a separate value that starts with a dash as the next option
  # ("Option --text requires a value"), so the value rides in --text=<value>.
  adapter "fm_backend_paradev_send_literal '$WS:$TERM_ID' '--dash leading' && fm_backend_paradev_send_text_line '$WS:$TERM_ID' '-n x'"
  expect_code 0 $? "dash-leading text should still be sent"
  log_has "${SEP}--text=--dash leading${SEP}--no-submit${SEP}" "dash-leading literal text must ride in --text=<value>"
  log_has "${SEP}--text=-n x${SEP}--json" "dash-leading line text must ride in --text=<value>"
  pass "fm_backend_paradev_send_literal/_send_text_line: stage vs submit"
}

test_send_text_submit_confirms_empty_composer() {
  local out
  paradev_case submit
  respond terminals-send "{\"terminalId\":\"$TERM_ID\",\"submitted\":false}"
  respond terminals-read "$(composer_empty_json)"
  out=$(adapter "fm_backend_paradev_send_text_submit '$WS:$TERM_ID' 'hello captain' 3 0.01 0.01")
  [ "$out" = empty ] || fail "send_text_submit should confirm an empty composer, got '$out'"
  log_has "${SEP}--text=hello captain${SEP}--no-submit${SEP}" "send_text_submit did not type the text once without submitting"
  log_has "${SEP}--keys${SEP}enter${SEP}" "send_text_submit did not press Enter"
  pass "fm_backend_paradev_send_text_submit: types once, presses Enter, confirms through the shared composer classifier"
}

test_send_text_submit_retries_enter_while_pending() {
  local out enters
  paradev_case submit-retry
  respond terminals-send "{\"terminalId\":\"$TERM_ID\",\"submitted\":false}"
  respond_nth terminals-read 1 "{\"terminalId\":\"$TERM_ID\",\"text\":\"╭─────────────────╮\\n│ > hello captain │\\n╰─────────────────╯\"}"
  respond terminals-read "$(composer_empty_json)"
  out=$(adapter "fm_backend_paradev_send_text_submit '$WS:$TERM_ID' 'hello captain' 3 0.01 0.01")
  [ "$out" = empty ] || fail "send_text_submit should retry Enter until the composer clears, got '$out'"
  enters=$(grep -c "${SEP}--keys${SEP}enter${SEP}" "$LOG")
  [ "$enters" -eq 2 ] || fail "send_text_submit should press Enter twice, got $enters"
  [ "$(grep -c "${SEP}--text=hello captain${SEP}" "$LOG")" -eq 1 ] || fail "send_text_submit must type the text exactly once"
  pass "fm_backend_paradev_send_text_submit: retries Enter only, never retypes"
}

test_send_text_submit_reports_send_failed() {
  local out
  paradev_case submit-fail
  respond_error terminals-send "Workspace not found on host h: $WS"
  out=$(adapter "fm_backend_paradev_send_text_submit '$WS:$TERM_ID' 'hello' 1 0.01 0.01" 2>/dev/null)
  [ "$out" = send-failed ] || fail "a failed send should report send-failed, got '$out'"
  pass "fm_backend_paradev_send_text_submit: reports send-failed on a CLI error"
}

test_composer_state_bare_shell_is_unknown() {
  local out
  paradev_case composer-shell
  respond terminals-read "{\"terminalId\":\"$TERM_ID\",\"text\":\"some output\\nuser@mac proj % \"}"
  out=$(adapter "fm_backend_paradev_composer_state '$WS:$TERM_ID'")
  [ "$out" = unknown ] || fail "a bare shell prompt must read unknown, never empty, got '$out'"
  pass "fm_backend_paradev_composer_state: a dead shell is unknown (unsafe for injection)"
}

test_kill_closes_and_proves_absence() {
  paradev_case kill-ok
  respond terminals-close "{\"terminalId\":\"$TERM_ID\",\"status\":\"disposed\"}"
  respond terminals-list '{"sessions":[]}'
  adapter "fm_backend_paradev_kill '$WS:$TERM_ID'"
  expect_code 0 $? "kill should succeed once the terminal is absent from the inventory"
  log_has "superset${SEP}terminals${SEP}close${SEP}--local${SEP}--workspace${SEP}$WS${SEP}--terminal${SEP}$TERM_ID${SEP}--json" \
    "kill did not close the recorded terminal"
  log_has "superset${SEP}terminals${SEP}list${SEP}--local${SEP}--workspace${SEP}$WS${SEP}--json" \
    "kill did not re-read the terminal inventory"
  pass "fm_backend_paradev_kill: closes and proves the terminal absent"
}

test_kill_refuses_when_terminal_survives_or_inventory_unreadable() {
  local status
  paradev_case kill-survives
  respond terminals-close "{\"terminalId\":\"$TERM_ID\",\"status\":\"disposed\"}"
  respond terminals-list "{\"sessions\":[{\"terminalId\":\"$TERM_ID\",\"workspaceId\":\"$WS\",\"exited\":false}]}"
  adapter "fm_backend_paradev_kill '$WS:$TERM_ID'" 2>/dev/null
  status=$?
  [ "$status" -ne 0 ] || fail "kill must fail while the terminal is still listed"
  paradev_case kill-unreadable
  respond_error terminals-close "socket hang up"
  respond_error terminals-list "socket hang up"
  adapter "fm_backend_paradev_kill '$WS:$TERM_ID'" 2>/dev/null
  status=$?
  [ "$status" -ne 0 ] || fail "kill must fail when the inventory cannot be read"
  pass "fm_backend_paradev_kill: refuses while the terminal survives or cannot be proven gone"
}

test_kill_treats_gone_workspace_as_gone() {
  paradev_case kill-gone
  respond_error terminals-close "Workspace not found on host h: $WS"
  respond_error terminals-list "Workspace not found on host h: $WS"
  adapter "fm_backend_paradev_kill '$WS:$TERM_ID'"
  expect_code 0 $? "kill should succeed silently when the workspace is already gone"
  pass "fm_backend_paradev_kill: an already-gone workspace is a quiet success"
}

test_kill_fails_without_cli() {
  local out status emptybin
  paradev_case kill-nocli
  emptybin="$CASE_DIR/emptybin"
  mkdir -p "$emptybin"
  out=$(bash -c 'PATH=$1; . "$0/bin/backends/paradev.sh"; fm_backend_paradev_kill "$2"' "$ROOT" "$emptybin" "$WS:$TERM_ID" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "kill must not report success when the CLI is missing"
  pass "fm_backend_paradev_kill: a missing CLI is a failed close, not a gone endpoint"
}

test_remove_worktree_archives_exact_id() {
  local out status
  paradev_case remove-ok
  respond workspaces-archive "{\"deleted\":[\"$WS\"],\"notFound\":[],\"failed\":[],\"warnings\":[]}"
  adapter "fm_backend_paradev_remove_worktree '$WS'"
  expect_code 0 $? "remove_worktree should succeed when Paradev reports the id deleted"
  log_has "superset${SEP}workspaces${SEP}archive${SEP}$WS${SEP}--local${SEP}--json" "remove_worktree did not archive the exact id"
  paradev_case remove-failed
  respond workspaces-archive "{\"deleted\":[],\"notFound\":[],\"failed\":[\"$WS\"],\"warnings\":[]}"
  out=$(adapter "fm_backend_paradev_remove_worktree '$WS'" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "remove_worktree must fail when Paradev reports the archive failed"
  paradev_case remove-empty
  out=$(adapter "fm_backend_paradev_remove_worktree ''" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "remove_worktree must refuse an empty id"
  [ ! -s "$LOG" ] || fail "an empty id must never reach workspaces archive"
  pass "fm_backend_paradev_remove_worktree: archives only the exact recorded id and checks the result"
}

test_worktree_path_resolves_live_workspace_only() {
  local out status
  paradev_case path-ok
  respond workspaces-get "$(ws_row "$WS" /paradev/wt/fm-t)"
  out=$(adapter "fm_backend_paradev_worktree_path '$WS'")
  [ "$out" = /paradev/wt/fm-t ] || fail "worktree_path should print worktreePath, got '$out'"
  paradev_case path-archived
  respond workspaces-get "$(ws_row "$WS" /paradev/wt/fm-t '"2026-11-13T00:00:00Z"')"
  out=$(adapter "fm_backend_paradev_worktree_path '$WS'" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "worktree_path must refuse an archived workspace"
  paradev_case path-other-id
  respond workspaces-get "$(ws_row other-workspace /paradev/wt/fm-t)"
  out=$(adapter "fm_backend_paradev_worktree_path '$WS'" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "worktree_path must refuse a reply for a different workspace id"
  pass "fm_backend_paradev_worktree_path: resolves only the exact live workspace"
}

test_busy_state_maps_native_agent_state() {
  local state out
  for state in working:busy idle:idle blocked:blocked starting:unknown exited:unknown none:unknown; do
    paradev_case "busy-${state%%:*}"
    respond agents-explain "{\"terminalId\":\"$TERM_ID\",\"state\":\"${state%%:*}\"}"
    out=$(adapter "fm_backend_paradev_busy_state '$WS:$TERM_ID'")
    [ "$out" = "${state#*:}" ] || fail "native state ${state%%:*} should map to ${state#*:}, got '$out'"
  done
  log_has "superset${SEP}agents${SEP}explain${SEP}--local${SEP}--workspace${SEP}$WS${SEP}--terminal${SEP}$TERM_ID${SEP}--json" \
    "busy_state did not ask agents explain for the recorded terminal"
  paradev_case busy-error
  respond_error agents-explain "Workspace not found on host h: $WS"
  out=$(adapter "fm_backend_paradev_busy_state '$WS:$TERM_ID'" 2>/dev/null)
  [ "$out" = unknown ] || fail "a failed explain must read unknown, got '$out'"
  pass "fm_backend_paradev_busy_state: working=busy, idle, blocked; everything else unknown"
}

test_target_ready_requires_live_listed_terminal() {
  local status
  paradev_case ready-ok
  respond terminals-list "{\"sessions\":[{\"terminalId\":\"$TERM_ID\",\"workspaceId\":\"$WS\",\"exited\":false}]}"
  adapter "fm_backend_paradev_target_ready '$WS:$TERM_ID'"
  expect_code 0 $? "target_ready should accept a listed live terminal"
  paradev_case ready-absent
  respond terminals-list '{"sessions":[]}'
  adapter "fm_backend_paradev_target_ready '$WS:$TERM_ID'"
  status=$?
  [ "$status" -ne 0 ] || fail "target_ready must reject an absent terminal"
  paradev_case ready-exited
  respond terminals-list "{\"sessions\":[{\"terminalId\":\"$TERM_ID\",\"workspaceId\":\"$WS\",\"exited\":true}]}"
  adapter "fm_backend_paradev_target_ready '$WS:$TERM_ID'"
  status=$?
  [ "$status" -ne 0 ] || fail "target_ready must reject an exited terminal"
  pass "fm_backend_paradev_target_ready: only a listed, unexited terminal is ready"
}

test_dispatcher_sources_paradev_and_routes_primitives() {
  local out
  paradev_case dispatch
  respond terminals-read "{\"terminalId\":\"$TERM_ID\",\"text\":\"via dispatch\"}"
  respond terminals-list "{\"sessions\":[{\"terminalId\":\"$TERM_ID\",\"exited\":false}]}"
  respond agents-explain '{"state":"working"}'
  out=$( PATH="$FB:$PATH" FM_PARADEV_LOG="$LOG" FM_PARADEV_RESPONSES="$RESP" \
    bash -c '. "$0/bin/fm-backend.sh"; fm_backend_validate_spawn paradev && fm_backend_capture paradev "$1" 9 && fm_backend_target_exists paradev "$1" && printf " %s" "$(fm_backend_busy_state paradev "$1")"' "$ROOT" "$WS:$TERM_ID" )
  [ "$out" = "via dispatch busy" ] || fail "dispatcher should route capture, target_exists and busy_state to the Paradev adapter, got '$out'"
  pass "fm-backend dispatcher: accepts paradev and routes primitives through bin/backends/paradev.sh"
}

# --- spawn --------------------------------------------------------------------

spawn_paradev() {  # <id> <proj> <state> <data> <config> [extra args...]
  local id=$1 proj=$2 state=$3 data=$4 config=$5
  shift 5
  HOME="$SPAWN_HOME" CLAUDE_CONFIG_DIR='' PATH="$FB:$PATH" FM_PARADEV_LOG="$LOG" FM_PARADEV_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/unused-projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude "$@" 2>&1
}

spawn_fixture() {  # <id> <label> -> sets PROJ WT DATA STATE CONFIG; WT is a linked worktree
  PROJ="$TMP_ROOT/$2-project"
  WT="$TMP_ROOT/$2-wt"
  DATA="$TMP_ROOT/$2-data"
  STATE="$TMP_ROOT/$2-state"
  CONFIG="$TMP_ROOT/$2-config"
  fm_git_worktree "$PROJ" "$WT" "fm/$1"
  mkdir -p "$DATA/$1" "$STATE" "$CONFIG"
  write_spawn_brief "$DATA" "$1"
  touch "$STATE/.last-watcher-beat"
  paradev_case "$2"
  respond projects-list "$(projects_json "$(cd "$PROJ" && pwd -P)")"
}

test_spawn_writes_paradev_metadata_and_launches_harness() {
  local id out staged launch
  id="pdspawnz1"
  spawn_fixture "$id" spawn
  respond workspaces-create "{\"workspace\":{\"id\":\"$WS\"},\"terminals\":[],\"agents\":[],\"alreadyExists\":false}"
  respond workspaces-get "$(ws_row "$WS" "$WT")"
  respond terminals-create "{\"terminalId\":\"$TERM_ID\",\"status\":\"active\"}"
  respond terminals-send "{\"terminalId\":\"$TERM_ID\",\"submitted\":true}"
  out=$(spawn_paradev "$id" "$PROJ" "$STATE" "$DATA" "$CONFIG" --mode no-mistakes --yolo off --backend paradev)
  expect_code 0 $? "fm-spawn.sh --backend paradev should succeed with the fake CLI"$'\n'"$out"
  assert_contains "$out" "spawned $id harness=claude kind=ship mode=no-mistakes yolo=off window=fm-$id worktree=$WT" \
    "spawn output missing the Paradev window/worktree summary"
  assert_grep "backend=paradev" "$STATE/$id.meta" "meta missing backend=paradev"
  assert_grep "window=fm-$id" "$STATE/$id.meta" "meta missing the stable window alias"
  assert_grep "endpoint_task_id=$id" "$STATE/$id.meta" "meta missing the endpoint task binding"
  assert_grep "terminal=$WS:$TERM_ID" "$STATE/$id.meta" "meta missing terminal=<workspace>:<terminal>"
  assert_grep "paradev_workspace_id=$WS" "$STATE/$id.meta" "meta missing paradev_workspace_id"
  assert_grep "paradev_project_id=$PROJECT_ID" "$STATE/$id.meta" "meta missing paradev_project_id"
  assert_grep "worktree=$WT" "$STATE/$id.meta" "meta missing the worktree path"
  log_has "${SEP}--branch${SEP}fm/$id${SEP}--skip-branch-prefix${SEP}--tag${SEP}firstmate${SEP}" \
    "spawn did not create the workspace on the ship branch with the firstmate tag"
  log_has "superset${SEP}terminals${SEP}send${SEP}--local${SEP}--workspace${SEP}$WS${SEP}--terminal${SEP}$TERM_ID${SEP}--text=cd -- '$WT'${SEP}--json" \
    "spawn did not move the shell into the recorded worktree"
  staged=$(tr '\037' '\n' < "$LOG" | sed -n "s/^--text=\. '\([^']*\)'$/\1/p" | tail -1)
  [ -n "$staged" ] && [ -f "$staged" ] || fail "spawn did not send Paradev a readable staged launch command"
  launch=$(cat "$staged")
  assert_contains "$launch" "claude --dangerously-skip-permissions" "the staged launch did not select the Claude harness"
  log_lacks "superset${SEP}agents${SEP}create" "spawn must launch the harness itself, not through agents create"
  log_lacks "superset${SEP}workspaces${SEP}list" "spawn must never enumerate workspaces by tag"
  rm -rf "/tmp/fm-$id" "$(dirname "$staged")"
  pass "fm-spawn.sh --backend paradev: creates a tagged workspace, records ids, launches the harness in it"
}

test_spawn_refuses_paradev_secondmate_before_home_mutation() {
  local home subhome id out status
  id="pdsmz1"
  home="$TMP_ROOT/secondmate-refusal-home"
  subhome="$TMP_ROOT/secondmate-refusal-subhome"
  mkdir -p "$home/data" "$home/state" "$home/config" "$subhome/bin" "$subhome/data" "$subhome/state" "$subhome/projects"
  printf '%s\n' "$id" > "$subhome/.fm-secondmate-home"
  printf 'firstmate\n' > "$subhome/AGENTS.md"
  printf 'claude\n' > "$home/config/crew-harness"
  touch "$home/state/.last-watcher-beat"
  paradev_case secondmate-refusal
  out=$( PATH="$FB:$PATH" FM_PARADEV_LOG="$LOG" FM_PARADEV_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$subhome" claude --backend paradev --secondmate 2>&1 )
  status=$?
  [ "$status" -ne 0 ] || fail "backend=paradev --secondmate should be refused"
  assert_contains "$out" "backend=paradev does not support --secondmate spawns yet" "paradev secondmate refusal should happen at backend selection"
  assert_absent "$subhome/config/crew-harness" "the refusal must not propagate inherited material into the secondmate home"
  [ ! -s "$LOG" ] || fail "a refused secondmate spawn must not call the Paradev CLI"
  pass "fm-spawn.sh --backend paradev --secondmate: refuses before any mutation"
}

test_spawn_refuses_paradev_when_host_unreachable() {
  local id out status
  id="pdhostz2"
  spawn_fixture "$id" host-down
  rm -f "$RESP/projects-list.out"
  respond_error projects-list "Host service is not running"
  out=$(spawn_paradev "$id" "$PROJ" "$STATE" "$DATA" "$CONFIG" --mode no-mistakes --yolo off --backend paradev)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn should refuse when the Paradev host cannot answer"
  assert_contains "$out" "Host service is not running" "host refusal should surface the CLI error"
  assert_absent "$STATE/$id.meta" "a host refusal must not record metadata"
  log_lacks "superset${SEP}workspaces${SEP}create" "spawn must refuse before creating a workspace"
  pass "fm-spawn.sh --backend paradev: refuses before mutation when the host is unreachable"
}

test_spawn_refuses_unregistered_paradev_project() {
  local id out status
  id="pdunregz3"
  spawn_fixture "$id" unregistered
  respond projects-list '[{"name":"other","repo":"-","path":"/elsewhere","id":"other-id"}]'
  out=$(spawn_paradev "$id" "$PROJ" "$STATE" "$DATA" "$CONFIG" --mode no-mistakes --yolo off --backend paradev)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn should refuse a project Paradev does not know"
  assert_contains "$out" "is not a Paradev project on this host" "unregistered refusal should explain"
  assert_absent "$STATE/$id.meta" "an unregistered refusal must not record metadata"
  log_lacks "superset${SEP}workspaces${SEP}create" "spawn must refuse before creating a workspace"
  pass "fm-spawn.sh --backend paradev: refuses an unregistered project before any mutation"
}

test_spawn_refuses_paradev_nonisolated_worktree() {
  local id out status
  id="pdbadwtz4"
  spawn_fixture "$id" bad-wt
  respond workspaces-create "{\"workspace\":{\"id\":\"$WS\"},\"alreadyExists\":false}"
  respond workspaces-get "$(ws_row "$WS" "$PROJ")"
  respond workspaces-archive "{\"deleted\":[\"$WS\"],\"notFound\":[],\"failed\":[],\"warnings\":[]}"
  out=$(spawn_paradev "$id" "$PROJ" "$STATE" "$DATA" "$CONFIG" --mode no-mistakes --yolo off --backend paradev)
  status=$?
  expect_code 1 "$status" "spawn should refuse a primary-checkout worktree"
  assert_contains "$out" "paradev workspaces create did not yield an isolated worktree" "spawn should reuse the isolated-worktree guard"
  assert_absent "$STATE/$id.meta" "an aborted spawn must not record metadata"
  log_lacks "superset${SEP}terminals${SEP}create" "spawn should validate the worktree before opening a terminal"
  log_has "superset${SEP}workspaces${SEP}archive${SEP}$WS${SEP}--local${SEP}--json" "spawn should archive the workspace it created"
  pass "fm-spawn.sh --backend paradev: refuses a non-isolated worktree and archives its own workspace"
}

test_spawn_archives_workspace_when_terminal_create_fails() {
  local id out status
  id="pdtermfailz5"
  spawn_fixture "$id" term-fail
  respond workspaces-create "{\"workspace\":{\"id\":\"$WS\"},\"alreadyExists\":false}"
  respond workspaces-get "$(ws_row "$WS" "$WT")"
  respond_error terminals-create "boom"
  respond workspaces-archive "{\"deleted\":[\"$WS\"],\"notFound\":[],\"failed\":[],\"warnings\":[]}"
  out=$(spawn_paradev "$id" "$PROJ" "$STATE" "$DATA" "$CONFIG" --mode no-mistakes --yolo off --backend paradev)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn should fail when the terminal cannot be opened"
  assert_absent "$STATE/$id.meta" "a cleaned-up abort must not record metadata"
  log_has "superset${SEP}workspaces${SEP}archive${SEP}$WS${SEP}--local${SEP}--json" "spawn should archive the workspace after a terminal failure"
  log_lacks "superset${SEP}terminals${SEP}close" "no terminal id was recorded, so none may be closed"
  pass "fm-spawn.sh --backend paradev: archives the workspace when the terminal cannot be opened"
}

test_spawn_preserves_paradev_metadata_when_abort_cleanup_fails() {
  local id out status
  id="pdleakz6"
  spawn_fixture "$id" cleanup-fail
  respond workspaces-create "{\"workspace\":{\"id\":\"$WS\"},\"alreadyExists\":false}"
  respond workspaces-get "$(ws_row "$WS" "$WT")"
  respond_error terminals-create "boom"
  respond workspaces-archive "{\"deleted\":[],\"notFound\":[],\"failed\":[\"$WS\"],\"warnings\":[]}"
  out=$(spawn_paradev "$id" "$PROJ" "$STATE" "$DATA" "$CONFIG" --mode no-mistakes --yolo off --backend paradev)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn should fail when the terminal and the cleanup both fail"
  assert_present "$STATE/$id.meta" "a failed abort cleanup must preserve a recovery record"
  assert_grep "cleanup_recovery=paradev" "$STATE/$id.meta" "recovery record missing cleanup_recovery=paradev"
  assert_grep "backend=paradev" "$STATE/$id.meta" "recovery record missing backend=paradev"
  assert_grep "paradev_workspace_id=$WS" "$STATE/$id.meta" "recovery record missing the workspace id"
  assert_grep "paradev_project_id=$PROJECT_ID" "$STATE/$id.meta" "recovery record missing the project id"
  assert_no_grep "terminal=" "$STATE/$id.meta" "recovery record must not invent a terminal"
  pass "fm-spawn.sh --backend paradev: preserves a recovery record when abort cleanup fails"
}

test_spawn_releases_paradev_resources_when_metadata_write_fails() {
  local id out status
  id="pdmetafailz7"
  spawn_fixture "$id" meta-fail
  rm -f "$STATE/.last-watcher-beat"
  mkdir -p "$STATE/$id.meta"
  respond workspaces-create "{\"workspace\":{\"id\":\"$WS\"},\"alreadyExists\":false}"
  respond workspaces-get "$(ws_row "$WS" "$WT")"
  respond terminals-create "{\"terminalId\":\"$TERM_ID\",\"status\":\"active\"}"
  respond terminals-send "{\"terminalId\":\"$TERM_ID\",\"submitted\":true}"
  respond terminals-close "{\"terminalId\":\"$TERM_ID\",\"status\":\"disposed\"}"
  respond terminals-list '{"sessions":[]}'
  respond workspaces-archive "{\"deleted\":[\"$WS\"],\"notFound\":[],\"failed\":[],\"warnings\":[]}"
  out=$(spawn_paradev "$id" "$PROJ" "$STATE" "$DATA" "$CONFIG" --mode no-mistakes --yolo off --backend paradev)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn should fail when metadata cannot be written"
  assert_contains "$out" "task record for $id could not be published" "spawn should report the publication failure"
  log_has "superset${SEP}terminals${SEP}close${SEP}--local${SEP}--workspace${SEP}$WS${SEP}--terminal${SEP}$TERM_ID${SEP}--json" \
    "spawn should close the terminal it opened on a later abort"
  log_has "superset${SEP}workspaces${SEP}archive${SEP}$WS${SEP}--local${SEP}--json" "spawn should archive the workspace on a later abort"
  [ ! -f "$STATE/$id.meta" ] || fail "a metadata-write abort must not publish a regular record"
  pass "fm-spawn.sh --backend paradev: releases terminal and workspace on later aborts"
}

# --- peek / send / crew-state -------------------------------------------------

paradev_meta() {  # <meta> <id> <wt> <proj> <kind> [extra...]
  local meta=$1 id=$2 wt=$3 proj=$4 kind=$5
  shift 5
  fm_write_meta "$meta" \
    "window=fm-$id" "endpoint_task_id=$id" "terminal=$WS:$TERM_ID" "worktree=$wt" "project=$proj" \
    "harness=claude" "kind=$kind" "mode=no-mistakes" "yolo=off" \
    "backend=paradev" "paradev_workspace_id=$WS" "paradev_project_id=$PROJECT_ID" "$@"
}

test_peek_send_and_crew_state_route_through_paradev_meta() {
  local wt state id out neutral record body
  id="pdioz8"
  wt="$TMP_ROOT/io-wt"
  fm_git_init_commit "$wt"
  state="$TMP_ROOT/io-state"; mkdir -p "$state"
  paradev_meta "$state/$id.meta" "$id" "$wt" "$wt" scout
  touch "$state/.last-watcher-beat"
  paradev_case io
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  respond terminals-read "{\"terminalId\":\"$TERM_ID\",\"text\":\"ready\"}"
  out=$( PATH="$FB:$PATH" FM_PARADEV_LOG="$LOG" FM_PARADEV_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-peek.sh" "fm-$id" 10 )
  [ "$out" = ready ] || fail "fm-peek should read through Paradev metadata, got '$out'"
  respond terminals-send "{\"terminalId\":\"$TERM_ID\",\"submitted\":false}"
  respond terminals-read "$(composer_empty_json)"
  PATH="$FB:$PATH" FM_PARADEV_LOG="$LOG" FM_PARADEV_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_HOME="$neutral" FM_STATE_OVERRIDE="$state" FM_SEND_SETTLE=0 \
    "$ROOT/bin/fm-send.sh" "fm-$id" "hello paradev"
  respond terminals-list "{\"sessions\":[{\"terminalId\":\"$TERM_ID\",\"exited\":false}]}"
  respond agents-explain '{"state":"idle"}'
  out=$( PATH="$FB:$PATH" FM_PARADEV_LOG="$LOG" FM_PARADEV_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-crew-state.sh" "$id" )
  assert_contains "$out" "state: " "crew-state should report a state for a Paradev task"
  log_has "superset${SEP}terminals${SEP}read${SEP}--local${SEP}--workspace${SEP}$WS${SEP}--terminal${SEP}$TERM_ID" \
    "peek did not read the recorded workspace and terminal"
  log_lacks "${SEP}--terminal${SEP}fm-$id${SEP}" "the stable window alias must never be used as a terminal id"
  record="$state/$id.inbox/001.msg"
  [ -f "$record" ] || fail "send did not enqueue through the task inbox"
  body=$(bash -c '. "$1"; fm_task_inbox_body "$2"' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$record")
  [ "$body" = "hello paradev" ] || fail "the task inbox did not preserve the send body, got '$body'"
  log_lacks "${SEP}--text=hello paradev${SEP}" "send typed the payload instead of recording it"
  log_has "superset${SEP}terminals${SEP}send${SEP}--local${SEP}--workspace${SEP}$WS${SEP}--terminal${SEP}$TERM_ID${SEP}--text=: Firstmate instruction waiting:" \
    "send did not ring the inbox doorbell through the recorded terminal"
  log_lacks "superset${SEP}workspaces${SEP}list" "peek/send/crew-state must never enumerate workspaces by tag"
  pass "fm-peek/fm-send/fm-crew-state route through backend=paradev metadata and its durable inbox"
}

# --- teardown -----------------------------------------------------------------

teardown_paradev() {  # <id> <state> <data> <config> [args...]
  local id=$1 state=$2 data=$3 config=$4 neutral
  shift 4
  neutral=$(neutral_fm_root "$CASE_DIR/neutral")
  PATH="$FB:$PATH" FM_PARADEV_LOG="$LOG" FM_PARADEV_RESPONSES="$RESP" \
    FM_ROOT_OVERRIDE="$neutral" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-teardown.sh" "$id" "$@" 2>&1
}

teardown_fixture() {  # <id> <label> <kind> -> sets PROJ WT DATA STATE CONFIG
  PROJ="$TMP_ROOT/$2-project"
  WT="$TMP_ROOT/$2-wt"
  DATA="$TMP_ROOT/$2-data"
  STATE="$TMP_ROOT/$2-state"
  CONFIG="$TMP_ROOT/$2-config"
  fm_git_worktree "$PROJ" "$WT" "fm/$1"
  mkdir -p "$DATA/$1" "$STATE" "$CONFIG"
  [ "$3" != scout ] || printf 'report\n' > "$DATA/$1/report.md"
  touch "$STATE/.last-watcher-beat"
  paradev_meta "$STATE/$1.meta" "$1" "$WT" "$PROJ" "$3" "decisions_reviewed=1" "decision_keys="
  paradev_case "$2"
  respond terminals-close "{\"terminalId\":\"$TERM_ID\",\"status\":\"disposed\"}"
  respond terminals-list '{"sessions":[]}'
  respond workspaces-archive "{\"deleted\":[\"$WS\"],\"notFound\":[],\"failed\":[],\"warnings\":[]}"
}

test_scout_teardown_closes_terminal_and_archives_recorded_workspace() {
  local id out rc
  id="pdscoutz1"
  teardown_fixture "$id" scout-teardown scout
  respond workspaces-get "$(ws_row "$WS" "$WT")"
  out=$(teardown_paradev "$id" "$STATE" "$DATA" "$CONFIG")
  rc=$?
  expect_code 0 "$rc" "Paradev scout teardown should succeed once the report exists"$'\n'"$out"
  log_has "superset${SEP}workspaces${SEP}get${SEP}$WS${SEP}--local${SEP}--json" "teardown did not resolve the recorded workspace id"
  log_has "superset${SEP}terminals${SEP}close${SEP}--local${SEP}--workspace${SEP}$WS${SEP}--terminal${SEP}$TERM_ID${SEP}--json" \
    "teardown did not close the recorded terminal"
  log_has "superset${SEP}workspaces${SEP}archive${SEP}$WS${SEP}--local${SEP}--json" "teardown did not archive the recorded workspace"
  log_lacks "superset${SEP}workspaces${SEP}list" "teardown must never find its workspace by tag"
  assert_absent "$STATE/$id.meta" "teardown should remove the task record"
  pass "fm-teardown.sh backend=paradev: scout gate, then close and archive by recorded id"
}

test_teardown_refuses_paradev_id_path_mismatch() {
  local id out rc other
  id="pdmismatchz2"
  teardown_fixture "$id" mismatch scout
  other="$TMP_ROOT/mismatch-other-wt"
  git -C "$PROJ" worktree add --quiet -b "fm/$id-other" "$other"
  respond workspaces-get "$(ws_row "$WS" "$other")"
  out=$(teardown_paradev "$id" "$STATE" "$DATA" "$CONFIG")
  rc=$?
  [ "$rc" -ne 0 ] || fail "teardown should refuse when the workspace resolves to another path"
  assert_contains "$out" "not inspected worktree" "the mismatch refusal should name the mismatch"
  assert_contains "$out" "Paradev" "the mismatch refusal should name Paradev"
  log_lacks "superset${SEP}terminals${SEP}close" "a refused teardown must not close terminals"
  log_lacks "superset${SEP}workspaces${SEP}archive" "a refused teardown must not archive"
  assert_present "$STATE/$id.meta" "a refused teardown should preserve the record"
  pass "fm-teardown.sh backend=paradev: refuses an id/path mismatch before any close or archive"
}

test_ship_teardown_refuses_unlanded_work_before_archive() {
  local id out rc
  id="pdunlandedz3"
  teardown_fixture "$id" unlanded ship
  respond workspaces-get "$(ws_row "$WS" "$WT")"
  printf 'uncommitted\n' > "$WT/scratch.txt"
  out=$(teardown_paradev "$id" "$STATE" "$DATA" "$CONFIG")
  rc=$?
  [ "$rc" -ne 0 ] || fail "ship teardown must refuse a worktree with uncommitted work"
  assert_contains "$out" "REFUSED: worktree $WT has uncommitted changes." "the refusal should come from Firstmate's landing checks"
  assert_present "$WT/scratch.txt" "the uncommitted file must survive a refused teardown"
  log_lacks "superset${SEP}workspaces${SEP}archive" "unlanded work must never be archived"
  log_lacks "superset${SEP}terminals${SEP}close" "a refused teardown must not close the terminal"
  assert_present "$STATE/$id.meta" "a refused teardown should preserve the record"
  pass "fm-teardown.sh backend=paradev: Firstmate's landing checks run before archive and refuse unlanded work"
}

test_ship_teardown_archives_when_landed_and_ids_match() {
  local id out rc
  id="pdlandedz4"
  teardown_fixture "$id" landed ship
  sed -i.bak 's/^mode=no-mistakes$/mode=local-only/' "$STATE/$id.meta" && rm -f "$STATE/$id.meta.bak"
  respond workspaces-get "$(ws_row "$WS" "$WT")"
  out=$(teardown_paradev "$id" "$STATE" "$DATA" "$CONFIG")
  rc=$?
  expect_code 0 "$rc" "a landed Paradev ship should tear down"$'\n'"$out"
  log_has "superset${SEP}workspaces${SEP}archive${SEP}$WS${SEP}--local${SEP}--json" "landed ship teardown did not archive the workspace"
  assert_absent "$STATE/$id.meta" "teardown should remove the task record"
  pass "fm-teardown.sh backend=paradev: a landed ship with matching ids archives its workspace"
}

test_ship_teardown_refuses_missing_worktree_path() {
  local id out rc
  id="pdnopathz5"
  teardown_fixture "$id" no-path ship
  rm -rf "$WT"
  git -C "$PROJ" worktree prune
  out=$(teardown_paradev "$id" "$STATE" "$DATA" "$CONFIG")
  rc=$?
  [ "$rc" -ne 0 ] || fail "ship teardown must refuse without an inspectable worktree"
  assert_contains "$out" "Paradev ship task $id has no inspectable git worktree" "the refusal should explain the requirement"
  [ ! -s "$LOG" ] || fail "a refused ship teardown must not call the Paradev CLI"
  pass "fm-teardown.sh backend=paradev: ship teardown fails closed without an inspectable worktree"
}

test_teardown_refuses_missing_paradev_workspace_id() {
  local id out rc
  id="pdnoidz6"
  teardown_fixture "$id" no-id scout
  grep -v '^paradev_workspace_id=' "$STATE/$id.meta" > "$STATE/$id.meta.new" && mv "$STATE/$id.meta.new" "$STATE/$id.meta"
  out=$(teardown_paradev "$id" "$STATE" "$DATA" "$CONFIG")
  rc=$?
  [ "$rc" -ne 0 ] || fail "teardown must refuse a record without paradev_workspace_id"
  assert_contains "$out" "paradev_workspace_id" "the refusal should name the missing key"
  [ ! -s "$LOG" ] || fail "a refused teardown must not call the Paradev CLI"
  pass "fm-teardown.sh backend=paradev: refuses a record with no recorded workspace id"
}

test_teardown_refuses_terminal_from_another_workspace() {
  local id out rc
  id="pdcrossz7"
  teardown_fixture "$id" cross scout
  sed -i.bak "s/^terminal=.*/terminal=99999999-0000-4000-8000-000000000000:$TERM_ID/" "$STATE/$id.meta" && rm -f "$STATE/$id.meta.bak"
  out=$(teardown_paradev "$id" "$STATE" "$DATA" "$CONFIG")
  rc=$?
  [ "$rc" -ne 0 ] || fail "teardown must refuse a terminal that names another workspace"
  assert_contains "$out" "Paradev endpoint metadata for task $id is malformed or inconsistent" "the refusal should name the inconsistency"
  [ ! -s "$LOG" ] || fail "a refused teardown must not call the Paradev CLI"
  pass "fm-teardown.sh backend=paradev: terminal= must belong to the recorded workspace"
}

test_teardown_preserves_record_when_archive_fails() {
  local id out rc
  id="pdarchfailz8"
  teardown_fixture "$id" archive-fail scout
  respond workspaces-get "$(ws_row "$WS" "$WT")"
  respond workspaces-archive "{\"deleted\":[],\"notFound\":[],\"failed\":[\"$WS\"],\"warnings\":[]}"
  out=$(teardown_paradev "$id" "$STATE" "$DATA" "$CONFIG")
  rc=$?
  [ "$rc" -ne 0 ] || fail "teardown should fail when the archive fails"
  assert_present "$STATE/$id.meta" "a failed archive must preserve the task record"
  pass "fm-teardown.sh backend=paradev: a failed archive preserves the record"
}

# A spawn that failed before any terminal existed and could not archive its
# workspace leaves a cleanup_recovery=paradev record with no terminal=.
recovery_fixture() {  # <id> <label> -> sets PROJ WT DATA STATE CONFIG
  PROJ="$TMP_ROOT/$2-project"
  WT="$TMP_ROOT/$2-wt"
  DATA="$TMP_ROOT/$2-data"
  STATE="$TMP_ROOT/$2-state"
  CONFIG="$TMP_ROOT/$2-config"
  fm_git_worktree "$PROJ" "$WT" "fm/$1"
  mkdir -p "$DATA/$1" "$STATE" "$CONFIG"
  touch "$STATE/.last-watcher-beat"
  fm_write_meta "$STATE/$1.meta" \
    "window=fm-$1" "endpoint_task_id=$1" "cleanup_recovery=paradev" "worktree=$WT" "project=$PROJ" \
    "harness=claude" "kind=ship" "mode=local-only" "yolo=off" "branch=fm/$1" \
    "backend=paradev" "paradev_workspace_id=$WS" "paradev_project_id=$PROJECT_ID"
  paradev_case "$2"
  respond workspaces-archive "{\"deleted\":[\"$WS\"],\"notFound\":[],\"failed\":[],\"warnings\":[]}"
}

test_spawn_recovery_record_without_terminal_tears_down() {
  local id out rc
  id="pdrecoverz9"
  spawn_fixture "$id" recover-spawn
  respond workspaces-create "{\"workspace\":{\"id\":\"$WS\"},\"alreadyExists\":false}"
  respond workspaces-get "$(ws_row "$WS" "$WT")"
  respond_error terminals-create "boom"
  respond workspaces-archive "{\"deleted\":[],\"notFound\":[],\"failed\":[\"$WS\"],\"warnings\":[]}"
  spawn_paradev "$id" "$PROJ" "$STATE" "$DATA" "$CONFIG" --mode local-only --yolo off --backend paradev >/dev/null
  assert_grep "cleanup_recovery=paradev" "$STATE/$id.meta" "the failed spawn should leave a recovery record"
  assert_no_grep "terminal=" "$STATE/$id.meta" "the recovery record should carry no terminal"
  : > "$LOG"
  respond workspaces-archive "{\"deleted\":[\"$WS\"],\"notFound\":[],\"failed\":[],\"warnings\":[]}"
  out=$(teardown_paradev "$id" "$STATE" "$DATA" "$CONFIG")
  rc=$?
  expect_code 0 "$rc" "rerunning teardown on a terminal-less recovery record should release the workspace"$'\n'"$out"
  log_has "superset${SEP}workspaces${SEP}get${SEP}$WS${SEP}--local${SEP}--json" "recovery teardown did not prove the recorded workspace path"
  log_has "superset${SEP}workspaces${SEP}archive${SEP}$WS${SEP}--local${SEP}--json" "recovery teardown did not archive the recorded workspace"
  log_lacks "superset${SEP}terminals${SEP}close" "a record with no terminal has nothing to close"
  assert_absent "$STATE/$id.meta" "recovery teardown should remove the record"
  pass "fm-teardown.sh backend=paradev: a terminal-less spawn recovery record tears down after the id/path gate"
}

test_recovery_record_without_terminal_refuses_unsafe_release() {
  local id out rc other
  id="pdrecmismatchz1"
  recovery_fixture "$id" rec-mismatch
  other="$TMP_ROOT/rec-mismatch-other-wt"
  git -C "$PROJ" worktree add --quiet -b "fm/$id-other" "$other"
  respond workspaces-get "$(ws_row "$WS" "$other")"
  out=$(teardown_paradev "$id" "$STATE" "$DATA" "$CONFIG")
  rc=$?
  [ "$rc" -ne 0 ] || fail "recovery teardown must refuse an id/path mismatch"
  assert_contains "$out" "not inspected worktree" "the mismatch refusal should name the mismatch"
  log_lacks "superset${SEP}workspaces${SEP}archive" "a mismatched recovery record must not archive"
  assert_present "$STATE/$id.meta" "a refused recovery teardown should keep the record"

  id="pdrecunreadz2"
  recovery_fixture "$id" rec-unread
  respond_error workspaces-get "host unreachable"
  out=$(teardown_paradev "$id" "$STATE" "$DATA" "$CONFIG")
  rc=$?
  [ "$rc" -ne 0 ] || fail "recovery teardown must refuse an unreadable workspace identity"
  log_lacks "superset${SEP}workspaces${SEP}archive" "an unreadable identity must not archive"
  assert_present "$STATE/$id.meta" "a refused recovery teardown should keep the record"

  id="pdrecdirtyz3"
  recovery_fixture "$id" rec-dirty
  respond workspaces-get "$(ws_row "$WS" "$WT")"
  printf 'uncommitted\n' > "$WT/scratch.txt"
  out=$(teardown_paradev "$id" "$STATE" "$DATA" "$CONFIG")
  rc=$?
  [ "$rc" -ne 0 ] || fail "recovery teardown must refuse unlanded work"
  assert_contains "$out" "worktree $WT has work not yet merged" "the refusal should come from the landing checks"
  assert_present "$WT/scratch.txt" "unlanded work must survive a refused recovery teardown"
  log_lacks "superset${SEP}workspaces${SEP}archive" "unlanded work must never be archived"
  assert_present "$STATE/$id.meta" "a refused recovery teardown should keep the record"

  id="pdnotermz4"
  recovery_fixture "$id" no-term-ordinary
  grep -v '^cleanup_recovery=' "$STATE/$id.meta" > "$STATE/$id.meta.new" && mv "$STATE/$id.meta.new" "$STATE/$id.meta"
  respond workspaces-get "$(ws_row "$WS" "$WT")"
  out=$(teardown_paradev "$id" "$STATE" "$DATA" "$CONFIG")
  rc=$?
  [ "$rc" -ne 0 ] || fail "an ordinary record without terminal= must still refuse"
  assert_contains "$out" "missing terminal" "the ordinary refusal should name the missing terminal"
  [ ! -s "$LOG" ] || fail "an ordinary terminal-less refusal must not call the Paradev CLI"
  assert_present "$STATE/$id.meta" "an ordinary terminal-less refusal should keep the record"
  pass "fm-teardown.sh backend=paradev: a terminal-less recovery record keeps the id/path and landing gates; ordinary records still refuse"
}

if [ -n "${FM_TEST_ONLY:-}" ]; then
  "$FM_TEST_ONLY"
  exit 0
fi

test_runtime_check_probes_a_real_call_not_status
test_runtime_check_refuses_unreachable_host
test_tool_check_names_missing_superset_and_jq
test_project_id_resolves_by_canonical_path
test_project_id_refuses_unregistered_and_ambiguous_paths
test_worktree_create_tags_and_reads_back_path
test_worktree_create_passes_base_branch
test_worktree_create_refuses_an_existing_workspace
test_worktree_create_archives_when_path_unreadable
test_worktree_create_reports_partial_when_archive_fails
test_terminal_create_returns_composite_target
test_capture_reads_screen_text
test_capture_fails_closed_on_cli_error_and_bad_target
test_send_key_maps_shared_names
test_send_key_refuses_unknown_key
test_send_literal_and_line
test_send_text_submit_confirms_empty_composer
test_send_text_submit_retries_enter_while_pending
test_send_text_submit_reports_send_failed
test_composer_state_bare_shell_is_unknown
test_kill_closes_and_proves_absence
test_kill_refuses_when_terminal_survives_or_inventory_unreadable
test_kill_treats_gone_workspace_as_gone
test_kill_fails_without_cli
test_remove_worktree_archives_exact_id
test_worktree_path_resolves_live_workspace_only
test_busy_state_maps_native_agent_state
test_target_ready_requires_live_listed_terminal
test_dispatcher_sources_paradev_and_routes_primitives
test_spawn_writes_paradev_metadata_and_launches_harness
test_spawn_refuses_paradev_secondmate_before_home_mutation
test_spawn_refuses_paradev_when_host_unreachable
test_spawn_refuses_unregistered_paradev_project
test_spawn_refuses_paradev_nonisolated_worktree
test_spawn_archives_workspace_when_terminal_create_fails
test_spawn_preserves_paradev_metadata_when_abort_cleanup_fails
test_spawn_releases_paradev_resources_when_metadata_write_fails
test_peek_send_and_crew_state_route_through_paradev_meta
test_scout_teardown_closes_terminal_and_archives_recorded_workspace
test_teardown_refuses_paradev_id_path_mismatch
test_ship_teardown_refuses_unlanded_work_before_archive
test_ship_teardown_archives_when_landed_and_ids_match
test_ship_teardown_refuses_missing_worktree_path
test_teardown_refuses_missing_paradev_workspace_id
test_teardown_refuses_terminal_from_another_workspace
test_teardown_preserves_record_when_archive_fails
test_spawn_recovery_record_without_terminal_tears_down
test_recovery_record_without_terminal_refuses_unsafe_release
