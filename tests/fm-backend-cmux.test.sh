#!/usr/bin/env bash
# tests/fm-backend-cmux.test.sh - fake-cmux-CLI unit tests for the experimental
# cmux session-provider adapter.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the cmux adapter)"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-backend-cmux-tests)

make_cmux_fakebin() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/cmux" <<'SH'
#!/usr/bin/env bash
set -u
LOG="${FM_CMUX_LOG:?}"
STATE="${FM_CMUX_FAKE_STATE:?}"
mkdir -p "$STATE"
DB="$STATE/workspaces.tsv"
COUNT="$STATE/count"
[ -f "$DB" ] || : > "$DB"
if [ -n "${FM_CMUX_INITIAL_WORKSPACES:-}" ] && [ ! -f "$STATE/initialized" ]; then
  printf '%s\n' "$FM_CMUX_INITIAL_WORKSPACES" > "$DB"
  : > "$STATE/initialized"
fi
{
  printf 'CMUX'
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$LOG"

json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

emit_tree() {
  printf '{"windows":[{"workspaces":['
  first=1
  while IFS='|' read -r label workspace surface; do
    [ -n "$label" ] || continue
    [ "$first" -eq 1 ] || printf ','
    first=0
    printf '{"title":"%s","ref":"%s","panes":[{"surfaces":[{"ref":"%s","type":"terminal"}]}]}' \
      "$(json_escape "$label")" "$(json_escape "$workspace")" "$(json_escape "$surface")"
  done < "$DB"
  printf ']}]}'
}

case "${1:-}" in
  version)
    printf 'cmux 0.64.17 (fake)\n'
    exit 0
    ;;
  tree)
    emit_tree
    exit 0
    ;;
  workspace)
    case "${2:-}" in
      create)
        name= cwd=
        shift 2
        while [ $# -gt 0 ]; do
          case "$1" in
            --name) name=$2; shift 2 ;;
            --cwd) cwd=$2; shift 2 ;;
            --focus) shift 2 ;;
            *) shift ;;
          esac
        done
        n=$(( $(cat "$COUNT" 2>/dev/null || echo 40) + 1 ))
        echo "$n" > "$COUNT"
        workspace="workspace:$n"
        surface="surface:$((n + 100))"
        printf '%s|%s|%s\n' "$name" "$workspace" "$surface" >> "$DB"
        printf 'OK %s\n' "$workspace"
        exit 0
        ;;
      close)
        target=${3:-}
        tmp="$DB.tmp"
        awk -F'|' -v target="$target" '$2 != target {print}' "$DB" > "$tmp" && mv "$tmp" "$DB"
        printf 'OK %s\n' "$target"
        exit 0
        ;;
    esac
    ;;
  read-screen)
    printf '%s\n' "${FM_CMUX_READ_SCREEN:-fake screen}"
    exit 0
    ;;
  send|send-key)
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fb/cmux"
  printf '%s\n' "$fb"
}

with_cmux_backend() {  # <dir> <script>
  local dir=$1 script=$2 fb
  fb=$(make_cmux_fakebin "$dir")
  PATH="$fb:$PATH" FM_CMUX_LOG="$dir/log" FM_CMUX_FAKE_STATE="$dir/state" \
    bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source cmux; eval "$1"' "$ROOT" "$script"
}

test_dispatch_accepts_cmux() {
  . "$ROOT/bin/fm-backend.sh"
  fm_backend_validate cmux 2>/dev/null || fail "fm_backend_validate should accept cmux"
  fm_backend_validate_spawn cmux 2>/dev/null || fail "fm_backend_validate_spawn should accept cmux"
  [ "$(fm_backend_busy_state cmux 'workspace:1/surface:2')" = unknown ] \
    || fail "fm_backend_busy_state should report unknown for cmux"
  pass "fm-backend dispatch: cmux is known, spawn-supported, and has unknown native busy state"
}

test_create_task_creates_workspace_and_parses_surface() {
  local dir out
  dir="$TMP_ROOT/create"; mkdir -p "$dir"
  out=$(with_cmux_backend "$dir" 'fm_backend_cmux_create_task cmux fm-new /tmp/project') \
    || fail "create_task should succeed"
  [ "$out" = "workspace:41 surface:141" ] || fail "create_task returned '$out'"
  assert_contains "$(cat "$dir/log")" $'\x1f''workspace'$'\x1f''create'$'\x1f''--name'$'\x1f''fm-new'$'\x1f''--cwd'$'\x1f''/tmp/project' \
    "create_task did not call cmux workspace create with name/cwd"
  pass "fm_backend_cmux_create_task: creates a workspace and returns workspace/surface refs"
}

test_create_task_refuses_duplicate_workspace_label() {
  local dir out status
  dir="$TMP_ROOT/duplicate"; mkdir -p "$dir"
  out=$(FM_CMUX_INITIAL_WORKSPACES='fm-dupe|workspace:7|surface:8' with_cmux_backend "$dir" 'fm_backend_cmux_create_task cmux fm-dupe /tmp/project' 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "create_task should refuse duplicate workspace labels"
  assert_contains "$out" "already exists" "duplicate refusal did not name the conflict"
  pass "fm_backend_cmux_create_task: refuses a duplicate workspace label"
}

test_capture_send_key_and_kill_route_to_cmux() {
  local dir out log
  dir="$TMP_ROOT/ops"; mkdir -p "$dir"
  out=$(FM_CMUX_INITIAL_WORKSPACES='fm-task|workspace:7|surface:8' \
    with_cmux_backend "$dir" 'fm_backend_cmux_capture workspace:7/surface:8 12 fm-task') \
    || fail "capture should succeed against a recorded workspace/surface"
  [ "$out" = "fake screen" ] || fail "capture returned '$out'"
  FM_CMUX_INITIAL_WORKSPACES='fm-task|workspace:7|surface:8' \
    with_cmux_backend "$dir" 'fm_backend_cmux_send_literal workspace:7/surface:8 "hello" fm-task; fm_backend_cmux_send_key workspace:7/surface:8 Enter fm-task; fm_backend_cmux_kill workspace:7/surface:8' \
    || fail "send/key/kill should succeed"
  log=$(cat "$dir/log")
  assert_contains "$log" $'\x1f''read-screen'$'\x1f''--workspace'$'\x1f''workspace:7'$'\x1f''--surface'$'\x1f''surface:8' \
    "capture did not target the workspace/surface"
  assert_contains "$log" $'\x1f''send'$'\x1f''--workspace'$'\x1f''workspace:7'$'\x1f''--surface'$'\x1f''surface:8' \
    "send_literal did not target the workspace/surface"
  assert_contains "$log" $'\x1f''send-key'$'\x1f''--workspace'$'\x1f''workspace:7'$'\x1f''--surface'$'\x1f''surface:8'$'\x1f''--'$'\x1f''enter' \
    "send_key did not normalize Enter to cmux's key name"
  assert_contains "$log" $'\x1f''workspace'$'\x1f''close'$'\x1f''workspace:7' \
    "kill did not close the workspace"
  pass "cmux operations: capture, send, key, and kill route to the recorded workspace/surface"
}

test_current_path_reads_marker_block() {
  local dir out markers
  dir="$TMP_ROOT/current-path"; mkdir -p "$dir"
  markers=$'__FM_CMUX_CWD_BEGIN__\n/tmp/fm-worktree\n__FM_CMUX_CWD_END__'
  out=$(FM_CMUX_INITIAL_WORKSPACES='fm-task|workspace:7|surface:8' FM_CMUX_READ_SCREEN="$markers" \
    with_cmux_backend "$dir" 'fm_backend_cmux_current_path workspace:7/surface:8 fm-task') \
    || fail "current_path should not fail"
  [ "$out" = "/tmp/fm-worktree" ] || fail "current_path returned '$out'"
  pass "fm_backend_cmux_current_path: active pwd probe reads the marker block"
}

test_dispatch_accepts_cmux
test_create_task_creates_workspace_and_parses_surface
test_create_task_refuses_duplicate_workspace_label
test_capture_send_key_and_kill_route_to_cmux
test_current_path_reads_marker_block
