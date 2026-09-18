#!/usr/bin/env bash
# tests/fm-backend-paseo.test.sh - fake-paseo-CLI unit tests for the Paseo
# session-provider adapter (bin/backends/paseo.sh), verified against the real
# Paseo 0.8.0 CLI/daemon (docs/paseo-backend.md). Mirrors
# tests/fm-backend-cmux.test.sh's fakebin/command-log convention: a small,
# LOG-based, canned-response fake `paseo` + real `jq` (jq is a real required
# tool for this backend, not faked). The real-binary smoke test lives in
# tests/fm-backend-paseo-smoke.test.sh, gated on the paseo binary and daemon
# actually being installed and reachable.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the paseo adapter)"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-backend-paseo-tests)

# make_paseo_fakebin: a `paseo` stub that logs every invocation (one line,
# unit-separated args, to $FM_PASEO_LOG) and returns the canned response for
# that call read from $FM_PASEO_RESPONSES/<n>.out, consumed IN ORDER (call 1
# reads 1.out, call 2 reads 2.out, ...), mirroring
# tests/fm-backend-cmux.test.sh's make_cmux_fakebin. A missing response file
# means "succeed with empty stdout" (send-keys and terminal kill are silent
# on success on the real CLI). `-v` and
# `status` are handled specially (not call-counted, not consuming the
# ordered response queue) since fm_backend_paseo_version_check/
# fm_backend_paseo_daemon_state are called at points a test may not want to
# hand-count.
make_paseo_fakebin() { # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat >"$fb/paseo" <<'SH'
#!/usr/bin/env bash
set -u
LOG="${FM_PASEO_LOG:?}"
RESP="${FM_PASEO_RESPONSES:?}"
COUNT_FILE="$RESP/.count"
{
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >>"$LOG"

if [ "${1:-}" = -v ]; then
  printf '%s\n' "${FM_PASEO_FAKE_VERSION:-0.8.0}"
  exit 0
fi
if [ "${1:-}" = status ]; then
  printf '%s\n' "${FM_PASEO_FAKE_STATUS:-{\"localDaemon\":\"running\",\"connectedDaemon\":\"reachable\"}}"
  exit "${FM_PASEO_FAKE_STATUS_EXIT:-0}"
fi

next=$(($(cat "$COUNT_FILE" 2>/dev/null || echo 0) + 1))
n=$next
echo "$n" >"$COUNT_FILE"
if [ -f "$RESP/$n.exit" ]; then
  exit "$(cat "$RESP/$n.exit")"
fi
[ -f "$RESP/$n.out" ] && cat "$RESP/$n.out"
exit 0
SH
  chmod +x "$fb/paseo"
  printf '%s\n' "$fb"
}

paseo_terminal_ls_response() { # <dir> <n> <id1> <workspaceId1> <name1> [<id2> <workspaceId2> <name2> ...]
  local dir=$1 n=$2 json first=1
  shift 2
  json='['
  while [ $# -ge 3 ]; do
    [ "$first" -eq 1 ] || json="$json,"
    json="$json{\"id\":\"$1\",\"workspaceId\":\"$2\",\"name\":\"$3\"}"
    first=0
    shift 3
  done
  json="$json]"
  printf '%s' "$json" >"$dir/responses/$n.out"
}

paseo_terminal_ls_empty_response() { # <dir> <n>
  printf '[]' >"$1/responses/$2.out"
}

paseo_capture_response() { # <dir> <n> <terminal-id> <text>
  jq -n --arg id "$3" --arg t "$4" '{terminalId:$id, lines:($t | split("\n")), totalLines:($t | split("\n") | length)}' >"$1/responses/$2.out"
}

paseo_expected_root_hash() { # <root>
  local root real
  root=$1
  real=$(cd "$root" && pwd -P) || return 1
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$real" | shasum -a 256 | awk '{print substr($1,1,8)}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$real" | sha256sum | awk '{print substr($1,1,8)}'
  else
    printf '%s' "$real" | cksum | awk '{printf "%08x", $1}'
  fi
}

paseo_expected_home_label() { # [home] [root]
  local home=${1:-$ROOT} root=${2:-$ROOT} marker id prefix
  marker="$home/.fm-secondmate-home"
  if [ -f "$marker" ]; then
    id=$(tr -d '[:space:]' <"$marker" 2>/dev/null)
    if [ -n "$id" ]; then
      prefix="2ndmate-$id"
    else
      prefix="firstmate"
    fi
  else
    prefix="firstmate"
  fi
  printf '%s-%s' "$prefix" "$(paseo_expected_root_hash "$root")"
}

paseo_expected_scoped_name() { # <fm-task-label> [home] [root]
  local label=$1 home=${2:-$ROOT} root=${3:-$ROOT} rest
  case "$label" in
  fm-*) rest=${label#fm-} ;;
  *) rest=$label ;;
  esac
  printf 'fm-%s-%s' "$(paseo_expected_home_label "$home" "$root")" "$rest"
}

paseo_assert_call_order() {
  local log=$1 before=$2 after=$3 msg=$4 before_line after_line
  before_line=$(grep -anF -- "$before" "$log" | head -1 | cut -d: -f1)
  after_line=$(grep -anF -- "$after" "$log" | head -1 | cut -d: -f1)
  [ -n "$before_line" ] || fail "$msg (missing before call: '$before')"
  [ -n "$after_line" ] || fail "$msg (missing after call: '$after')"
  [ "$before_line" -lt "$after_line" ] || fail "$msg"
}

# --- version_check / tool_check ----------------------------------------------

test_version_check_accepts_current_version() {
  local dir fb status
  dir="$TMP_ROOT/version-ok"
  mkdir -p "$dir/responses"
  fb=$(make_paseo_fakebin "$dir")
  PATH="$fb:$PATH" FM_PASEO_LOG="$dir/log" FM_PASEO_RESPONSES="$dir/responses" FM_PASEO_FAKE_VERSION=0.8.0 \
    bash -c '. "$0/bin/backends/paseo.sh"; fm_backend_paseo_version_check' "$ROOT"
  status=$?
  expect_code 0 "$status" "version_check should accept 0.8.0 (the verified minimum)"
  pass "fm_backend_paseo_version_check: accepts the verified minimum (0.8.0)"
}

test_version_check_accepts_newer_version() {
  local dir fb status
  dir="$TMP_ROOT/version-newer"
  mkdir -p "$dir/responses"
  fb=$(make_paseo_fakebin "$dir")
  PATH="$fb:$PATH" FM_PASEO_LOG="$dir/log" FM_PASEO_RESPONSES="$dir/responses" FM_PASEO_FAKE_VERSION=0.9.2 \
    bash -c '. "$0/bin/backends/paseo.sh"; fm_backend_paseo_version_check' "$ROOT"
  status=$?
  expect_code 0 "$status" "version_check should accept a newer minor (0.9.2)"
  pass "fm_backend_paseo_version_check: accepts a newer version (0.9.2)"
}

test_version_check_refuses_old_version() {
  local dir fb out status
  dir="$TMP_ROOT/version-old"
  mkdir -p "$dir/responses"
  fb=$(make_paseo_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_PASEO_LOG="$dir/log" FM_PASEO_RESPONSES="$dir/responses" FM_PASEO_FAKE_VERSION=0.7.0 \
    bash -c '. "$0/bin/backends/paseo.sh"; fm_backend_paseo_version_check' "$ROOT" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "version_check should refuse 0.7.0 (below the 0.8 minimum)"
  assert_contains "$out" "0.7.0" "version_check error did not name the rejected version"
  pass "fm_backend_paseo_version_check: refuses an old version loudly"
}

test_version_check_refuses_missing_paseo() {
  local dir out status
  dir="$TMP_ROOT/version-missing"
  mkdir -p "$dir/empty-fakebin"
  out=$(PATH="$dir/empty-fakebin:/usr/bin:/bin" FM_BACKEND_PASEO_BUNDLE_BIN="$dir/no-such-paseo" \
    bash -c '. "$0/bin/backends/paseo.sh"; fm_backend_paseo_version_check' "$ROOT" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "version_check should refuse when paseo is not installed"
  assert_contains "$out" "not found" "version_check did not report paseo as missing"
  pass "fm_backend_paseo_version_check: refuses loudly when paseo is not found on PATH or at the bundle path"
}

# --- target parsing -----------------------------------------------------------

test_parse_target() {
  (. "$ROOT/bin/backends/paseo.sh"
    fm_backend_paseo_parse_target "aaaaaaaa-0000-0000-0000-000000000000:wks_bbbbbbbbbbbbbbbb" || exit 1
    [ "$FM_BACKEND_PASEO_TERMINAL" = "aaaaaaaa-0000-0000-0000-000000000000" ] || {
      echo "terminal mismatch: $FM_BACKEND_PASEO_TERMINAL" >&2
      exit 1
    }
    [ "$FM_BACKEND_PASEO_WORKSPACE" = "wks_bbbbbbbbbbbbbbbb" ] || {
      echo "workspace mismatch: $FM_BACKEND_PASEO_WORKSPACE" >&2
      exit 1
    }) || fail "fm_backend_paseo_parse_target did not split terminal:workspace correctly"
  pass "fm_backend_paseo_parse_target: splits '<terminal_id>:<workspace_id>' on the first colon"
}

test_scoped_name_uses_primary_home_label() {
  local dir out expected
  dir="$TMP_ROOT/scoped-name-primary"
  mkdir -p "$dir"
  expected=$(paseo_expected_scoped_name fm-task1 "$dir")
  out=$(FM_HOME="$dir" bash -c '. "$0/bin/backends/paseo.sh"; fm_backend_paseo_scoped_name fm-task1' "$ROOT")
  [ "$out" = "$expected" ] || fail "primary scoped name should be $expected, got '$out'"
  pass "fm_backend_paseo_scoped_name: scopes a primary task name with firstmate plus root hash"
}

test_scoped_name_uses_secondmate_home_label() {
  local dir out expected
  dir="$TMP_ROOT/scoped-name-secondmate"
  mkdir -p "$dir"
  printf 'sm-one\n' >"$dir/.fm-secondmate-home"
  expected=$(paseo_expected_scoped_name fm-task1 "$dir")
  out=$(FM_HOME="$dir" bash -c '. "$0/bin/backends/paseo.sh"; fm_backend_paseo_scoped_name fm-task1' "$ROOT")
  [ "$out" = "$expected" ] || fail "secondmate scoped name should be $expected, got '$out'"
  pass "fm_backend_paseo_scoped_name: scopes a secondmate task name with the home marker plus root hash"
}

# --- dispatch wiring (fm-backend.sh) ------------------------------------------

test_dispatch_routes_paseo_backend() {
  fm_backend_validate paseo 2>/dev/null || fail "fm_backend_validate should accept paseo"
  pass "fm_backend_validate: paseo is a known backend"
}

test_dispatch_busy_state_unknown_for_paseo() {
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-backend.sh"
  [ "$(fm_backend_busy_state paseo 'aaaaaaaa-0000-0000-0000-000000000000:wks_bbbbbbbbbbbbbbbb')" = unknown ] \
    || fail "fm_backend_busy_state should report unknown for paseo (no native agent-state primitive)"
  pass "fm_backend_busy_state: paseo (no native primitive) always reports unknown, same as tmux/zellij/orca/cmux"
}

test_dispatch_composer_state_routes_paseo() {
  local dir fb out target
  dir="$TMP_ROOT/dispatch-composer"
  mkdir -p "$dir/responses"
  target="aaaaaaaa-0000-0000-0000-000000000000:wks_bbbbbbbbbbbbbbbb"
  paseo_terminal_ls_response "$dir" 1 "aaaaaaaa-0000-0000-0000-000000000000" "wks_bbbbbbbbbbbbbbbb" "some-name"
  paseo_capture_response "$dir" 2 "aaaaaaaa-0000-0000-0000-000000000000" $'  ╭────────────────────────╮\n  │ ❯ hello captain        │\n  ╰──────── Composer ──────╯'
  fb=$(make_paseo_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_PASEO_LOG="$dir/log" FM_PASEO_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/fm-backend.sh"; fm_backend_composer_state paseo "$1"' "$ROOT" "$target")
  [ "$out" = pending ] || fail "fm_backend_composer_state should route paseo to its classifier, got '$out'"
  pass "fm_backend_composer_state: routes paseo to the paseo composer classifier"
}

# --- daemon_state / ensure_running --------------------------------------------

test_daemon_state_ok() {
  local dir fb out
  dir="$TMP_ROOT/daemon-ok"
  mkdir -p "$dir/responses"
  fb=$(make_paseo_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_PASEO_LOG="$dir/log" FM_PASEO_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/paseo.sh"; fm_backend_paseo_daemon_state' "$ROOT")
  [ "$out" = ok ] || fail "daemon_state should report ok when both fields are healthy, got '$out'"
  pass "fm_backend_paseo_daemon_state: reports 'ok' when localDaemon=running and connectedDaemon=reachable"
}

test_daemon_state_down_on_unreachable() {
  local dir fb out
  dir="$TMP_ROOT/daemon-down"
  mkdir -p "$dir/responses"
  fb=$(make_paseo_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_PASEO_LOG="$dir/log" FM_PASEO_RESPONSES="$dir/responses" FM_PASEO_FAKE_STATUS_EXIT=1 \
    bash -c '. "$0/bin/backends/paseo.sh"; fm_backend_paseo_daemon_state' "$ROOT")
  [ "$out" = down ] || fail "daemon_state should report down when the status call fails, got '$out'"
  pass "fm_backend_paseo_daemon_state: reports 'down' when 'paseo status' fails"
}

test_ensure_running_returns_immediately_when_already_ok() {
  local dir fb status
  dir="$TMP_ROOT/ensure-ok"
  mkdir -p "$dir/responses"
  fb=$(make_paseo_fakebin "$dir")
  cat >"$fb/paseo-start-marker.sh" <<'SH'
#!/usr/bin/env bash
echo "start should not be called when paseo is already reachable" >&2
exit 1
SH
  chmod +x "$fb/paseo-start-marker.sh"
  PATH="$fb:$PATH" FM_PASEO_LOG="$dir/log" FM_PASEO_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/paseo.sh"; fm_backend_paseo_ensure_running' "$ROOT"
  status=$?
  expect_code 0 "$status" "ensure_running should succeed immediately when already reachable"
  assert_not_contains "$(cat "$dir/log")" $'\x1f''start' \
    "ensure_running should not call 'paseo start' when already reachable"
  pass "fm_backend_paseo_ensure_running: returns immediately when paseo is already reachable"
}

# --- create_task: duplicate refusal, id resolution ---------------------------

test_create_task_refuses_duplicate_name() {
  local dir fb out status name
  dir="$TMP_ROOT/dup-task"
  mkdir -p "$dir/responses"
  name=$(paseo_expected_scoped_name fm-dup1)
  paseo_terminal_ls_response "$dir" 1 "eeeeeeee-0000-0000-0000-000000000000" "wks_existing00000000" "$name"
  fb=$(make_paseo_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_PASEO_LOG="$dir/log" FM_PASEO_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/paseo.sh"; fm_backend_paseo_create_task fm-dup1 /tmp/proj' "$ROOT" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "create_task should refuse an existing terminal name (paseo itself does not enforce uniqueness)"
  assert_contains "$out" "already exists" "create_task did not report the duplicate name"
  pass "fm_backend_paseo_create_task: refuses a duplicate terminal name (paseo's own terminal create has no uniqueness check)"
}

test_create_task_creates_and_parses_ids() {
  local dir fb out name
  dir="$TMP_ROOT/create-task"
  mkdir -p "$dir/responses"
  name=$(paseo_expected_scoped_name fm-newtask)
  # 1: terminal ls --all --json (pre-create duplicate check) -> no match
  printf '[]' >"$dir/responses/1.out"
  # 2: workspace ls --json (adopt the shared per-project workspace) -> none yet
  printf '[]' >"$dir/responses/2.out"
  # 3: workspace create --path <dir> --isolation local --title firstmate --json -> workspaceId
  jq -n '{workspaceId:"wks_bbbbbbbbbbbbbbbb"}' >"$dir/responses/3.out"
  # 4: terminal create --workspace <id> --cwd <dir> --name <name> --json -> id
  jq -n '{id:"cccccccc-2222-2222-2222-222222222222"}' >"$dir/responses/4.out"
  fb=$(make_paseo_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_PASEO_LOG="$dir/log" FM_PASEO_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/paseo.sh"; fm_backend_paseo_create_task fm-newtask /tmp/proj' "$ROOT")
  [ "$out" = "cccccccc-2222-2222-2222-222222222222 wks_bbbbbbbbbbbbbbbb" ] \
    || fail "create_task should echo '<terminal_id> <workspace_id>', got '$out'"
  assert_contains "$(cat "$dir/log")" $'\x1f''workspace'$'\x1f''create'$'\x1f''--path'$'\x1f''/tmp/proj'$'\x1f''--isolation'$'\x1f''local'$'\x1f''--title'$'\x1f''firstmate' \
    "create_task did not create the shared workspace with the right path and label"
  assert_contains "$(cat "$dir/log")" $'\x1f''terminal'$'\x1f''create'$'\x1f''--workspace'$'\x1f''wks_bbbbbbbbbbbbbbbb'$'\x1f''--cwd'$'\x1f''/tmp/proj'$'\x1f''--name'$'\x1f'"$name" \
    "create_task did not call terminal create with the right workspace/cwd/name"
  case "$(cat "$dir/log")" in
  *$'\x1f''project'$'\x1f'*) fail "create_task must never run a 'paseo project' command (Paseo registers the project by path)" ;;
  esac
  pass "fm_backend_paseo_create_task: creates the shared workspace once plus a terminal tab and parses terminal_id/workspace_id"
}

test_create_task_adopts_existing_shared_workspace() {
  local dir fb out name
  dir="$TMP_ROOT/create-task-adopt"
  mkdir -p "$dir/responses"
  name=$(paseo_expected_scoped_name fm-second)
  # 1: terminal ls --all --json (pre-create duplicate check) -> a sibling task, different name
  paseo_terminal_ls_response "$dir" 1 "aaaaaaaa-0000-0000-0000-000000000000" "wks_bbbbbbbbbbbbbbbb" "$(paseo_expected_scoped_name fm-first)"
  # 2: workspace ls --json -> another project's firstmate workspace, an unrelated
  #    workspace on this project, then this project's firstmate workspace
  jq -n '[{workspaceId:"wks_other000000000000",name:"firstmate",cwd:"/tmp/other"},
          {workspaceId:"wks_human00000000000",name:"Evidence Room",cwd:"/tmp/proj"},
          {workspaceId:"wks_bbbbbbbbbbbbbbbb",name:"firstmate",cwd:"/tmp/proj"}]' >"$dir/responses/2.out"
  # 3: terminal create -> id (no workspace create must happen)
  jq -n '{id:"dddddddd-3333-3333-3333-333333333333"}' >"$dir/responses/3.out"
  fb=$(make_paseo_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_PASEO_LOG="$dir/log" FM_PASEO_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/paseo.sh"; fm_backend_paseo_create_task fm-second /tmp/proj' "$ROOT")
  [ "$out" = "dddddddd-3333-3333-3333-333333333333 wks_bbbbbbbbbbbbbbbb" ] \
    || fail "create_task should reuse this project's firstmate workspace, got '$out'"
  case "$(cat "$dir/log")" in
  *$'\x1f''workspace'$'\x1f''create'$'\x1f'*) fail "create_task must not create a second workspace when the project's firstmate workspace is live" ;;
  esac
  assert_contains "$(cat "$dir/log")" $'\x1f''terminal'$'\x1f''create'$'\x1f''--workspace'$'\x1f''wks_bbbbbbbbbbbbbbbb'$'\x1f''--cwd'$'\x1f''/tmp/proj'$'\x1f''--name'$'\x1f'"$name" \
    "create_task did not open the new tab inside the adopted workspace"
  pass "fm_backend_paseo_create_task: adopts the project's live firstmate workspace by cwd+label and adds a tab (never a second workspace)"
}

# Paseo's `workspace ls` reports cwd normalized (no doubled slash) but not
# symlink-resolved, so adoption must match the raw, logical, and physical path.
test_workspace_ensure_adopts_logical_and_physical_cwd() {
  local dir fb real link physical out
  dir="$TMP_ROOT/ws-adopt-paths"
  real="$dir/real-proj"
  link="$dir/link-proj"
  mkdir -p "$dir/responses" "$real"
  ln -s "$real" "$link"
  physical=$(cd "$real" && pwd -P)
  fb=$(make_paseo_fakebin "$dir")

  jq -n --arg cwd "$physical" '[{workspaceId:"wks_physical0000000",name:"firstmate",cwd:$cwd}]' >"$dir/responses/1.out"
  out=$(PATH="$fb:$PATH" FM_PASEO_LOG="$dir/log" FM_PASEO_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/paseo.sh"; fm_backend_paseo_workspace_ensure "$1"' "$ROOT" "$link")
  [ "$out" = wks_physical0000000 ] || fail "workspace_ensure should adopt a workspace listed under the symlink-resolved path, got '$out'"

  rm -f "$dir/responses/.count"
  jq -n --arg cwd "$link" '[{workspaceId:"wks_logical00000000",name:"firstmate",cwd:$cwd}]' >"$dir/responses/1.out"
  out=$(PATH="$fb:$PATH" FM_PASEO_LOG="$dir/log" FM_PASEO_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/paseo.sh"; fm_backend_paseo_workspace_ensure "$1"' "$ROOT" "$dir//link-proj")
  [ "$out" = wks_logical00000000 ] || fail "workspace_ensure should adopt a workspace listed under the logical (slash-normalized) path, got '$out'"

  case "$(cat "$dir/log")" in
  *$'\x1f''workspace'$'\x1f''create'$'\x1f'*) fail "workspace_ensure must adopt, never create, when a path spelling matches" ;;
  esac
  pass "fm_backend_paseo_workspace_ensure: adopts the shared workspace by its physical or slash-normalized logical cwd"
}

# When firstmate runs inside a Paseo agent the CLI prints an Electron warning
# on stderr before its JSON; parsed calls must keep it out of stdout and relay
# it only when the call fails.
test_cli_json_keeps_stderr_out_of_parsed_output() {
  local dir out status
  dir="$TMP_ROOT/cli-json-stderr"
  mkdir -p "$dir/fakebin"
  cat >"$dir/fakebin/paseo" <<'SH'
#!/bin/sh
echo "Electron warning: fake" >&2
printf '{"workspaceId":"wks_bbbbbbbbbbbbbbbb"}\n'
exit "${FM_PASEO_FAKE_EXIT:-0}"
SH
  chmod +x "$dir/fakebin/paseo"

  out=$(PATH="$dir/fakebin:$PATH" bash -c '. "$0/bin/backends/paseo.sh"; fm_backend_paseo_cli_json workspace create --json' "$ROOT" 2>"$dir/err")
  status=$?
  expect_code 0 "$status" "cli_json should succeed when the CLI does"
  [ "$out" = '{"workspaceId":"wks_bbbbbbbbbbbbbbbb"}' ] || fail "cli_json stdout must be the CLI's JSON alone, got '$out'"
  [ -s "$dir/err" ] && fail "cli_json must not relay the CLI's stderr on success"$'\n'"$(cat "$dir/err")"

  out=$(PATH="$dir/fakebin:$PATH" FM_PASEO_FAKE_EXIT=7 bash -c '. "$0/bin/backends/paseo.sh"; fm_backend_paseo_cli_json workspace create --json' "$ROOT" 2>"$dir/err")
  status=$?
  expect_code 7 "$status" "cli_json should propagate the CLI's failure status"
  assert_contains "$(cat "$dir/err")" "Electron warning: fake" "cli_json should relay the CLI's stderr when the call fails"
  pass "fm_backend_paseo_cli_json: keeps stderr out of parsed JSON and relays it only on failure"
}

test_workspace_label_uses_secondmate_prefix() {
  local home out
  home="$TMP_ROOT/label-2ndmate"
  mkdir -p "$home"
  printf 'abc12\n' >"$home/.fm-secondmate-home"
  out=$(FM_HOME="$home" bash -c '. "$0/bin/backends/paseo.sh"; fm_backend_paseo_workspace_label' "$ROOT")
  [ "$out" = "2ndmate-abc12" ] || fail "workspace label should be '2ndmate-abc12' for a secondmate home, got '$out'"
  out=$(bash -c '. "$0/bin/backends/paseo.sh"; fm_backend_paseo_workspace_label' "$ROOT")
  [ "$out" = firstmate ] || fail "workspace label should be 'firstmate' for the primary home, got '$out'"
  pass "fm_backend_paseo_workspace_label: 'firstmate' for the primary home, '2ndmate-<id>' for a secondmate home (no path hash)"
}

# --- target_ready / capture ---------------------------------------------------

test_target_ready_fails_when_target_absent() {
  local dir fb status
  dir="$TMP_ROOT/ready-absent"
  mkdir -p "$dir/responses"
  paseo_terminal_ls_empty_response "$dir" 1
  fb=$(make_paseo_fakebin "$dir")
  PATH="$fb:$PATH" FM_PASEO_LOG="$dir/log" FM_PASEO_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/paseo.sh"; fm_backend_paseo_target_ready "aaaaaaaa-0000-0000-0000-000000000000:wks_bbbbbbbbbbbbbbbb"' "$ROOT"
  status=$?
  [ "$status" -ne 0 ] || fail "target_ready should fail when the recorded terminal id is not in the live inventory and no expected label is given"
  pass "fm_backend_paseo_target_ready: fails when the terminal is not found and no expected label is given"
}

test_target_ready_checks_expected_label() {
  local dir fb name
  dir="$TMP_ROOT/ready-label-ok"
  mkdir -p "$dir/responses"
  name=$(paseo_expected_scoped_name fm-label)
  paseo_terminal_ls_response "$dir" 1 "aaaaaaaa-0000-0000-0000-000000000000" "wks_bbbbbbbbbbbbbbbb" "$name"
  fb=$(make_paseo_fakebin "$dir")
  PATH="$fb:$PATH" FM_PASEO_LOG="$dir/log" FM_PASEO_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/paseo.sh"; fm_backend_paseo_target_ready "aaaaaaaa-0000-0000-0000-000000000000:wks_bbbbbbbbbbbbbbbb" fm-label' "$ROOT"
  expect_code 0 $? "target_ready should succeed when the terminal name matches the expected label"
  pass "fm_backend_paseo_target_ready: verifies the live terminal name against the expected label"
}

test_target_ready_rejects_label_mismatch() {
  local dir fb status
  dir="$TMP_ROOT/ready-label-mismatch"
  mkdir -p "$dir/responses"
  paseo_terminal_ls_response "$dir" 1 "aaaaaaaa-0000-0000-0000-000000000000" "wks_bbbbbbbbbbbbbbbb" "not-the-task"
  fb=$(make_paseo_fakebin "$dir")
  PATH="$fb:$PATH" FM_PASEO_LOG="$dir/log" FM_PASEO_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/paseo.sh"; fm_backend_paseo_target_ready "aaaaaaaa-0000-0000-0000-000000000000:wks_bbbbbbbbbbbbbbbb" fm-label' "$ROOT"
  status=$?
  [ "$status" -ne 0 ] || fail "target_ready should reject a terminal id reused under a different name"
  pass "fm_backend_paseo_target_ready: rejects a terminal id reused under a different name"
}

test_target_ready_recovers_stale_id_by_name() {
  local dir fb name
  dir="$TMP_ROOT/ready-recover"
  mkdir -p "$dir/responses"
  name=$(paseo_expected_scoped_name fm-label)
  # 1: terminal ls --all --json -> the recorded (stale) id is absent entirely
  paseo_terminal_ls_response "$dir" 1 "zzzzzzzz-0000-0000-0000-000000000000" "wks_unrelated0000000" "unrelated"
  # 2: terminal_id_for_name lookup -> terminal ls --all --json (matches by name)
  paseo_terminal_ls_response "$dir" 2 "dddddddd-3333-3333-3333-333333333333" "wks_cccccccccccccccc" "$name"
  # 3: terminal_entry(refreshed id) -> terminal ls --all --json
  paseo_terminal_ls_response "$dir" 3 "dddddddd-3333-3333-3333-333333333333" "wks_cccccccccccccccc" "$name"
  fb=$(make_paseo_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_PASEO_LOG="$dir/log" FM_PASEO_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/paseo.sh"
      fm_backend_paseo_target_ready "aaaaaaaa-0000-0000-0000-000000000000:wks_stale00000000000" fm-label || exit 1
      printf "%s %s" "$FM_BACKEND_PASEO_TERMINAL" "$FM_BACKEND_PASEO_WORKSPACE"' "$ROOT")
  [ "$out" = "dddddddd-3333-3333-3333-333333333333 wks_cccccccccccccccc" ] \
    || fail "target_ready should recover the refreshed terminal/workspace ids by name, got '$out'"
  pass "fm_backend_paseo_target_ready: recovers a stale terminal id by home-scoped NAME, never by title"
}

test_capture_trims_locally() {
  local dir fb out
  dir="$TMP_ROOT/capture"
  mkdir -p "$dir/responses"
  paseo_terminal_ls_response "$dir" 1 "aaaaaaaa-0000-0000-0000-000000000000" "wks_bbbbbbbbbbbbbbbb" "some-name"
  paseo_capture_response "$dir" 2 "aaaaaaaa-0000-0000-0000-000000000000" $'line one\nline two\nline three\nline four'
  fb=$(make_paseo_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_PASEO_LOG="$dir/log" FM_PASEO_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/paseo.sh"; fm_backend_paseo_capture "aaaaaaaa-0000-0000-0000-000000000000:wks_bbbbbbbbbbbbbbbb" 2' "$ROOT")
  [ "$out" = $'line three\nline four' ] || fail "capture should trim to the last N lines locally, got '$out'"
  paseo_assert_call_order "$dir/log" $'\x1f''terminal'$'\x1f''ls' $'\x1f''terminal'$'\x1f''capture' \
    "capture did not verify readiness before the actual read"
  pass "fm_backend_paseo_capture: fetches the whole scrollback and trims to N lines locally"
}

test_capture_fails_when_target_not_ready() {
  local dir fb status
  dir="$TMP_ROOT/capture-not-ready"
  mkdir -p "$dir/responses"
  paseo_terminal_ls_empty_response "$dir" 1
  fb=$(make_paseo_fakebin "$dir")
  PATH="$fb:$PATH" FM_PASEO_LOG="$dir/log" FM_PASEO_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/paseo.sh"; fm_backend_paseo_capture "aaaaaaaa-0000-0000-0000-000000000000:wks_bbbbbbbbbbbbbbbb" 5' "$ROOT"
  status=$?
  [ "$status" -ne 0 ] || fail "capture should fail when the target is not ready"
  assert_not_contains "$(cat "$dir/log")" $'\x1f''terminal'$'\x1f''capture' \
    "capture should not fetch after readiness fails"
  pass "fm_backend_paseo_capture: fails when the target terminal is absent"
}

# --- send_key / send_literal --------------------------------------------------

test_send_key_passes_key_through_to_recorded_terminal() {
  local dir fb
  dir="$TMP_ROOT/sendkey"
  mkdir -p "$dir/responses"
  paseo_terminal_ls_response "$dir" 1 "aaaaaaaa-0000-0000-0000-000000000000" "wks_bbbbbbbbbbbbbbbb" "some-name"
  fb=$(make_paseo_fakebin "$dir")
  PATH="$fb:$PATH" FM_PASEO_LOG="$dir/log" FM_PASEO_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/paseo.sh"; fm_backend_paseo_send_key "aaaaaaaa-0000-0000-0000-000000000000:wks_bbbbbbbbbbbbbbbb" Escape' "$ROOT"
  expect_code 0 $? "send_key should succeed"
  assert_contains "$(cat "$dir/log")" $'\x1f''terminal'$'\x1f''send-keys'$'\x1f''aaaaaaaa-0000-0000-0000-000000000000'$'\x1f''Escape' \
    "send_key did not pass Escape through unchanged to the recorded terminal id"
  pass "fm_backend_paseo_send_key: passes the key through unchanged to the recorded terminal id"
}

# Paseo 0.8.0 has no C-u token and types any unknown key name as literal text,
# so C-u must arrive as the raw 0x15 byte and an unlisted key must be refused.
test_send_key_delivers_cu_as_raw_byte_and_refuses_unknown_keys() {
  local dir fb out status
  dir="$TMP_ROOT/sendkey-cu"
  mkdir -p "$dir/responses"
  paseo_terminal_ls_response "$dir" 1 "aaaaaaaa-0000-0000-0000-000000000000" "wks_bbbbbbbbbbbbbbbb" "some-name"
  fb=$(make_paseo_fakebin "$dir")
  PATH="$fb:$PATH" FM_PASEO_LOG="$dir/log" FM_PASEO_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/paseo.sh"; fm_backend_paseo_send_key "aaaaaaaa-0000-0000-0000-000000000000:wks_bbbbbbbbbbbbbbbb" C-u' "$ROOT"
  expect_code 0 $? "send_key C-u should succeed"
  assert_contains "$(cat "$dir/log")" $'\x1f''terminal'$'\x1f''send-keys'$'\x1f''aaaaaaaa-0000-0000-0000-000000000000'$'\x1f''-l'$'\x1f''--'$'\x1f'$'\x15' \
    "send_key C-u did not send the raw 0x15 byte through send-keys -l"
  case "$(cat "$dir/log")" in
  *$'\x1f''C-u'*) fail "send_key C-u must never pass the literal 'C-u' name to paseo (it would be typed as text)" ;;
  esac

  : >"$dir/log"
  out=$(PATH="$fb:$PATH" FM_PASEO_LOG="$dir/log" FM_PASEO_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/paseo.sh"; fm_backend_paseo_send_key "aaaaaaaa-0000-0000-0000-000000000000:wks_bbbbbbbbbbbbbbbb" C-k' "$ROOT" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "send_key should refuse a key outside paseo's token set"
  assert_contains "$out" "unsupported paseo key 'C-k'" "send_key refusal did not name the unsupported key"
  [ -s "$dir/log" ] && fail "send_key must not call paseo for an unsupported key"$'\n'"$(cat "$dir/log")"
  pass "fm_backend_paseo_send_key: C-u goes as the raw 0x15 byte via -l; keys outside paseo's token set are refused, never typed"
}

test_send_literal_uses_separator_for_option_shaped_text() {
  local dir fb
  dir="$TMP_ROOT/sendliteral"
  mkdir -p "$dir/responses"
  paseo_terminal_ls_response "$dir" 1 "aaaaaaaa-0000-0000-0000-000000000000" "wks_bbbbbbbbbbbbbbbb" "some-name"
  fb=$(make_paseo_fakebin "$dir")
  PATH="$fb:$PATH" FM_PASEO_LOG="$dir/log" FM_PASEO_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/paseo.sh"; fm_backend_paseo_send_literal "aaaaaaaa-0000-0000-0000-000000000000:wks_bbbbbbbbbbbbbbbb" "--help"' "$ROOT"
  expect_code 0 $? "send_literal should succeed"
  assert_contains "$(cat "$dir/log")" $'\x1f''terminal'$'\x1f''send-keys'$'\x1f''aaaaaaaa-0000-0000-0000-000000000000'$'\x1f''-l'$'\x1f''--'$'\x1f''--help' \
    "send_literal did not call send-keys -l with a -- separator before the literal payload"
  pass "fm_backend_paseo_send_literal: calls send-keys -l with a -- separator before the literal payload"
}

test_send_text_line_composes_literal_and_enter() {
  local dir fb
  dir="$TMP_ROOT/sendline"
  mkdir -p "$dir/responses"
  # 1: terminal ls (target_ready via send_literal)
  # 2: send-keys -l (literal text)
  # 3: terminal ls (target_ready via send_key Enter)
  # 4: send-keys Enter
  paseo_terminal_ls_response "$dir" 1 "aaaaaaaa-0000-0000-0000-000000000000" "wks_bbbbbbbbbbbbbbbb" "some-name"
  paseo_terminal_ls_response "$dir" 3 "aaaaaaaa-0000-0000-0000-000000000000" "wks_bbbbbbbbbbbbbbbb" "some-name"
  fb=$(make_paseo_fakebin "$dir")
  PATH="$fb:$PATH" FM_PASEO_LOG="$dir/log" FM_PASEO_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/paseo.sh"; fm_backend_paseo_send_text_line "aaaaaaaa-0000-0000-0000-000000000000:wks_bbbbbbbbbbbbbbbb" "echo hi"' "$ROOT"
  expect_code 0 $? "send_text_line should succeed"
  assert_contains "$(cat "$dir/log")" $'\x1f''terminal'$'\x1f''send-keys'$'\x1f''aaaaaaaa-0000-0000-0000-000000000000'$'\x1f''-l'$'\x1f''--'$'\x1f''echo hi' \
    "send_text_line did not send the literal text"
  assert_contains "$(cat "$dir/log")" $'\x1f''terminal'$'\x1f''send-keys'$'\x1f''aaaaaaaa-0000-0000-0000-000000000000'$'\x1f''Enter' \
    "send_text_line did not submit with Enter"
  pass "fm_backend_paseo_send_text_line: sends literal text then submits with Enter"
}

# --- current_path: pwd-marker probe (cwd is creation-time-frozen) ------------

test_current_path_probes_with_marker() {
  local dir fb out
  # Verified real-paseo pitfall (docs/paseo-backend.md finding #3): the
  # terminal's cwd field is frozen at creation time, never following a
  # foreground subshell (e.g. treehouse get) - so current_path actively
  # prints a marked cwd line and reads only that marker from the capture.
  dir="$TMP_ROOT/cwd"
  mkdir -p "$dir/responses"
  # 1: terminal ls (current_path's own target_ready)
  # 2: terminal ls (target_ready via send_literal)
  # 3: send-keys -l (literal probe text)
  # 4: terminal ls (target_ready via send_key Enter)
  # 5: send-keys Enter
  # 6: terminal ls (target_ready via capture)
  # 7: terminal capture --json (actual fetch)
  paseo_terminal_ls_response "$dir" 1 "aaaaaaaa-0000-0000-0000-000000000000" "wks_bbbbbbbbbbbbbbbb" "some-name"
  paseo_terminal_ls_response "$dir" 2 "aaaaaaaa-0000-0000-0000-000000000000" "wks_bbbbbbbbbbbbbbbb" "some-name"
  paseo_terminal_ls_response "$dir" 4 "aaaaaaaa-0000-0000-0000-000000000000" "wks_bbbbbbbbbbbbbbbb" "some-name"
  paseo_terminal_ls_response "$dir" 6 "aaaaaaaa-0000-0000-0000-000000000000" "wks_bbbbbbbbbbbbbbbb" "some-name"
  paseo_capture_response "$dir" 7 "aaaaaaaa-0000-0000-0000-000000000000" \
    $'/tmp/proj\n❯ printf marker\n__FM_PASEO_CWD_BEGIN__\n/home/fixture/.treehouse/fake-worktree\n__FM_PASEO_CWD_END__\n/home/fixture/.treehouse/fake-worktree ❯'
  fb=$(make_paseo_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_PASEO_LOG="$dir/log" FM_PASEO_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/paseo.sh"; fm_backend_paseo_current_path "aaaaaaaa-0000-0000-0000-000000000000:wks_bbbbbbbbbbbbbbbb"' "$ROOT")
  [ "$out" = "/home/fixture/.treehouse/fake-worktree" ] || fail "current_path should read only the marked cwd line, got '$out'"
  assert_contains "$(cat "$dir/log")" "__FM_PASEO_CWD_BEGIN__" "current_path did not send the cwd begin marker"
  assert_contains "$(cat "$dir/log")" "pwd" "current_path did not send the pwd probe"
  assert_contains "$(cat "$dir/log")" $'\x1f''terminal'$'\x1f''send-keys'$'\x1f''aaaaaaaa-0000-0000-0000-000000000000'$'\x1f''Enter' \
    "current_path did not submit the cwd probe with Enter"
  pass "fm_backend_paseo_current_path: actively probes with marked begin/end lines (creation-time-frozen cwd)"
}

# --- composer_state -----------------------------------------------------------

test_composer_state_bare_prompt_is_empty() {
  local dir fb out
  dir="$TMP_ROOT/composer-bare"
  mkdir -p "$dir/responses"
  paseo_terminal_ls_response "$dir" 1 "aaaaaaaa-0000-0000-0000-000000000000" "wks_bbbbbbbbbbbbbbbb" "some-name"
  paseo_capture_response "$dir" 2 "aaaaaaaa-0000-0000-0000-000000000000" $'\342\235\257'
  fb=$(make_paseo_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_PASEO_LOG="$dir/log" FM_PASEO_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/paseo.sh"; fm_backend_paseo_composer_state "aaaaaaaa-0000-0000-0000-000000000000:wks_bbbbbbbbbbbbbbbb"' "$ROOT")
  [ "$out" = empty ] || fail "a bare prompt glyph should read as empty, got '$out'"
  pass "fm_backend_paseo_composer_state: a bare '❯' composer row reads empty"
}

test_composer_state_real_text_is_pending() {
  local dir fb out
  dir="$TMP_ROOT/composer-pending"
  mkdir -p "$dir/responses"
  paseo_terminal_ls_response "$dir" 1 "aaaaaaaa-0000-0000-0000-000000000000" "wks_bbbbbbbbbbbbbbbb" "some-name"
  paseo_capture_response "$dir" 2 "aaaaaaaa-0000-0000-0000-000000000000" $'  ╭────────────────────────╮\n  │ ❯ hello captain        │\n  ╰──────── Composer ──────╯'
  fb=$(make_paseo_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_PASEO_LOG="$dir/log" FM_PASEO_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/paseo.sh"; fm_backend_paseo_composer_state "aaaaaaaa-0000-0000-0000-000000000000:wks_bbbbbbbbbbbbbbbb"' "$ROOT")
  [ "$out" = pending ] || fail "real unsubmitted text should read as pending, got '$out'"
  pass "fm_backend_paseo_composer_state: real composer text reads pending"
}

test_composer_state_unknown_on_capture_failure() {
  local dir fb out status
  dir="$TMP_ROOT/composer-capture-fail"
  mkdir -p "$dir/responses"
  printf '1\n' >"$dir/responses/1.exit"
  fb=$(make_paseo_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_PASEO_LOG="$dir/log" FM_PASEO_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/paseo.sh"; fm_backend_paseo_composer_state "aaaaaaaa-0000-0000-0000-000000000000:wks_bbbbbbbbbbbbbbbb"' "$ROOT")
  status=$?
  [ "$status" -eq 0 ] || fail "composer_state should not itself fail the caller"
  [ "$out" = unknown ] || fail "an unreadable terminal should read as unknown, got '$out'"
  pass "fm_backend_paseo_composer_state: reports unknown when the terminal cannot be captured"
}

# --- send_text_submit: verify-and-retry loop ----------------------------------

test_send_text_submit_detects_landed_send() {
  local dir fb out
  dir="$TMP_ROOT/submit-ok"
  mkdir -p "$dir/responses"
  # 1: terminal ls (target_ready via send_literal)
  # 2: send-keys -l (literal text)
  # 3: terminal ls (target_ready via send_key Enter)
  # 4: send-keys Enter
  # 5: terminal ls (target_ready via composer_state's capture)
  # 6: terminal capture --json -> composer reads empty (submitted)
  paseo_terminal_ls_response "$dir" 1 "aaaaaaaa-0000-0000-0000-000000000000" "wks_bbbbbbbbbbbbbbbb" "some-name"
  paseo_terminal_ls_response "$dir" 3 "aaaaaaaa-0000-0000-0000-000000000000" "wks_bbbbbbbbbbbbbbbb" "some-name"
  paseo_terminal_ls_response "$dir" 5 "aaaaaaaa-0000-0000-0000-000000000000" "wks_bbbbbbbbbbbbbbbb" "some-name"
  paseo_capture_response "$dir" 6 "aaaaaaaa-0000-0000-0000-000000000000" $'\342\235\257'
  fb=$(make_paseo_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_PASEO_LOG="$dir/log" FM_PASEO_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/paseo.sh"; fm_backend_paseo_send_text_submit "aaaaaaaa-0000-0000-0000-000000000000:wks_bbbbbbbbbbbbbbbb" "hello captain" 3 0.01 0.01' "$ROOT")
  [ "$out" = empty ] || fail "send_text_submit should report empty (submitted) once the composer row reads empty, got '$out'"
  enter_count=$(grep -c $'\x1f''terminal'$'\x1f''send-keys'$'\x1f''aaaaaaaa-0000-0000-0000-000000000000'$'\x1f''Enter' "$dir/log")
  [ "$enter_count" -eq 1 ] || fail "send_text_submit should not need a second Enter for a plain message, sent $enter_count Enter(s)"
  pass "fm_backend_paseo_send_text_submit: reports 'empty' once the composer row reads empty after one Enter"
}

test_send_text_submit_send_failed_when_target_absent() {
  local dir fb out
  dir="$TMP_ROOT/submit-no-target"
  mkdir -p "$dir/responses"
  printf '1\n' >"$dir/responses/1.exit"
  fb=$(make_paseo_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_PASEO_LOG="$dir/log" FM_PASEO_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/paseo.sh"; fm_backend_paseo_send_text_submit "aaaaaaaa-0000-0000-0000-000000000000:wks_bbbbbbbbbbbbbbbb" "x" 2 0.01 0.01' "$ROOT")
  [ "$out" = send-failed ] || fail "send_text_submit should report send-failed when the target is absent, got '$out'"
  pass "fm_backend_paseo_send_text_submit: reports 'send-failed' when the target terminal is absent"
}

# --- kill: best-effort whole-endpoint reclaim ---------------------------------

test_kill_closes_terminal_and_keeps_workspace() {
  local dir fb
  dir="$TMP_ROOT/kill"
  mkdir -p "$dir/responses"
  fb=$(make_paseo_fakebin "$dir")
  PATH="$fb:$PATH" FM_PASEO_LOG="$dir/log" FM_PASEO_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/paseo.sh"; fm_backend_paseo_kill "aaaaaaaa-0000-0000-0000-000000000000:wks_bbbbbbbbbbbbbbbb"' "$ROOT"
  assert_contains "$(cat "$dir/log")" $'\x1f''terminal'$'\x1f''kill'$'\x1f''aaaaaaaa-0000-0000-0000-000000000000' \
    "kill did not close the terminal"
  case "$(cat "$dir/log")" in
  *$'\x1f''workspace'$'\x1f''archive'$'\x1f'*) fail "kill must not archive the shared per-project workspace (sibling task tabs live in it)" ;;
  esac
  pass "fm_backend_paseo_kill: closes only the task's terminal tab and leaves the shared workspace alive"
}

test_kill_is_best_effort_when_terminal_kill_fails() {
  local dir fb status
  dir="$TMP_ROOT/kill-fail"
  mkdir -p "$dir/responses"
  printf '1\n' >"$dir/responses/1.exit"
  fb=$(make_paseo_fakebin "$dir")
  PATH="$fb:$PATH" FM_PASEO_LOG="$dir/log" FM_PASEO_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/paseo.sh"; fm_backend_paseo_kill "aaaaaaaa-0000-0000-0000-000000000000:wks_bbbbbbbbbbbbbbbb"' "$ROOT"
  status=$?
  expect_code 0 "$status" "kill must stay best-effort (never fail) even when terminal kill fails"
  pass "fm_backend_paseo_kill: never fails even when terminal kill fails"
}

# --- list_live: name-based orphan discovery -----------------------------------

test_list_live_filters_by_name_prefix() {
  local dir fb out name other_name other_root
  dir="$TMP_ROOT/list-live"
  mkdir -p "$dir/responses"
  other_root="$dir/other-root"
  mkdir -p "$other_root"
  name=$(paseo_expected_scoped_name fm-task1)
  other_name=$(paseo_expected_scoped_name fm-task2 "$ROOT" "$other_root")
  paseo_terminal_ls_response "$dir" 1 \
    "aaaaaaaa-0000-0000-0000-000000000000" "wks_bbbbbbbbbbbbbbbb" "$name" \
    "dddddddd-8888-8888-8888-888888888888" "wks_ffffffffffffffff" "$other_name" \
    "cccccccc-9999-9999-9999-999999999999" "wks_gggggggggggggggg" "zsh"
  fb=$(make_paseo_fakebin "$dir")
  out=$(PATH="$fb:$PATH" FM_PASEO_LOG="$dir/log" FM_PASEO_RESPONSES="$dir/responses" \
    bash -c '. "$0/bin/backends/paseo.sh"; fm_backend_paseo_list_live' "$ROOT")
  [ "$out" = $'aaaaaaaa-0000-0000-0000-000000000000:wks_bbbbbbbbbbbbbbbb\tfm-task1' ] \
    || fail "list_live should list only the in-home task terminal with its plain label, got '$out'"
  pass "fm_backend_paseo_list_live: lists only this home's scoped task terminals using plain fm-<id> labels"
}

# --- fm-spawn.sh: --secondmate refuses an explicit backend=paseo --------------

# paseo_secondmate_spawn: run fm-spawn.sh --secondmate inside an ambient Paseo
# agent environment (PASEO_AGENT_ID set, every other runtime marker cleared,
# uname faked non-Darwin so no cmux fallback fires), varying only FM_BACKEND,
# the config dir, and extra flags.
paseo_secondmate_spawn() { # <dir> <config-dir> <FM_BACKEND-value> [fm-spawn args...]
  local dir=$1 config=$2 backend=$3
  shift 3
  (unset TMUX HERDR_ENV CMUX_WORKSPACE_ID __CFBundleIdentifier
    PATH="$dir/fakebin:$PATH" PASEO_AGENT_ID=fm-test-agent FM_BACKEND="$backend" \
      FM_STATE_OVERRIDE="$dir/state" FM_DATA_OVERRIDE="$dir/data" FM_CONFIG_OVERRIDE="$config" \
      FM_PROJECTS_OVERRIDE="$dir/projects" "$ROOT/bin/fm-spawn.sh" sm-paseo-test --secondmate "$@" 2>&1)
}

test_secondmate_spawn_refuses_explicit_paseo_only() {
  local dir out
  dir="$TMP_ROOT/secondmate-refuse"
  mkdir -p "$dir/state" "$dir/data" "$dir/config" "$dir/config-paseo" "$dir/projects" "$dir/fakebin"
  printf 'paseo\n' >"$dir/config-paseo/backend"
  printf '#!/bin/sh\necho Linux\n' >"$dir/fakebin/uname"
  chmod +x "$dir/fakebin/uname"

  out=$(paseo_secondmate_spawn "$dir" "$dir/config" '' --backend paseo)
  assert_contains "$out" "backend=paseo does not support --secondmate" "fm-spawn.sh did not refuse --secondmate with --backend paseo"
  out=$(paseo_secondmate_spawn "$dir" "$dir/config" paseo)
  assert_contains "$out" "backend=paseo does not support --secondmate" "fm-spawn.sh did not refuse --secondmate with FM_BACKEND=paseo"
  out=$(paseo_secondmate_spawn "$dir" "$dir/config-paseo" '')
  assert_contains "$out" "backend=paseo does not support --secondmate" "fm-spawn.sh did not refuse --secondmate with config/backend=paseo"

  out=$(paseo_secondmate_spawn "$dir" "$dir/config" '')
  assert_not_contains "$out" "does not support --secondmate" \
    "an auto-detected paseo must fall back to tmux for --secondmate instead of refusing"
  assert_contains "$out" "no firstmate home supplied" \
    "the auto-detected --secondmate spawn should continue past backend selection to the home check"
  pass "fm-spawn.sh: an explicit paseo refuses --secondmate (mirrors cmux/Orca) while an auto-detected paseo falls back to tmux"
}

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"

test_version_check_accepts_current_version
test_version_check_accepts_newer_version
test_version_check_refuses_old_version
test_version_check_refuses_missing_paseo
test_parse_target
test_scoped_name_uses_primary_home_label
test_scoped_name_uses_secondmate_home_label
test_dispatch_routes_paseo_backend
test_dispatch_busy_state_unknown_for_paseo
test_dispatch_composer_state_routes_paseo
test_daemon_state_ok
test_daemon_state_down_on_unreachable
test_ensure_running_returns_immediately_when_already_ok
test_create_task_refuses_duplicate_name
test_create_task_creates_and_parses_ids
test_create_task_adopts_existing_shared_workspace
test_workspace_ensure_adopts_logical_and_physical_cwd
test_cli_json_keeps_stderr_out_of_parsed_output
test_workspace_label_uses_secondmate_prefix
test_target_ready_fails_when_target_absent
test_target_ready_checks_expected_label
test_target_ready_rejects_label_mismatch
test_target_ready_recovers_stale_id_by_name
test_capture_trims_locally
test_capture_fails_when_target_not_ready
test_send_key_passes_key_through_to_recorded_terminal
test_send_key_delivers_cu_as_raw_byte_and_refuses_unknown_keys
test_send_literal_uses_separator_for_option_shaped_text
test_send_text_line_composes_literal_and_enter
test_current_path_probes_with_marker
test_composer_state_bare_prompt_is_empty
test_composer_state_real_text_is_pending
test_composer_state_unknown_on_capture_failure
test_send_text_submit_detects_landed_send
test_send_text_submit_send_failed_when_target_absent
test_kill_closes_terminal_and_keeps_workspace
test_kill_is_best_effort_when_terminal_kill_fails
test_list_live_filters_by_name_prefix
test_secondmate_spawn_refuses_explicit_paseo_only
