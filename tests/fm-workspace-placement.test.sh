#!/usr/bin/env bash
# tests/fm-workspace-placement.test.sh - behavioral coverage for host and Docker
# Sandbox workspace-placement adapters using a hermetic fake sbx CLI.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-workspace-placement.sh
. "$ROOT/bin/fm-workspace-placement.sh"

TMP_ROOT=$(fm_test_tmproot fm-workspace-placement)
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fake")
SBX_STATE="$TMP_ROOT/sbx.state"
SBX_LOG="$TMP_ROOT/sbx.log"
: > "$SBX_STATE"
: > "$SBX_LOG"
export SBX_STATE SBX_LOG

cat > "$FAKEBIN/sbx" <<'SBX'
#!/usr/bin/env bash
set -u

log_argv() {
  local arg
  printf '%s' "$1" >> "$SBX_LOG"
  shift
  for arg in "$@"; do
    printf '\t%s' "$arg" >> "$SBX_LOG"
  done
  printf '\n' >> "$SBX_LOG"
}

remove_selector() {
  local selector=$1 id name agent workspace tmp="${SBX_STATE}.tmp.$$"
  : > "$tmp"
  while IFS=$'\t' read -r id name agent workspace || [ -n "$id" ]; do
    [ "$id" = "$selector" ] || [ "$name" = "$selector" ] || \
      printf '%s\t%s\t%s\t%s\n' "$id" "$name" "$agent" "$workspace" >> "$tmp"
  done < "$SBX_STATE"
  mv "$tmp" "$SBX_STATE"
}

json_state() {
  local id name agent workspace
  case "${SBX_JSON_SHAPE:-array}" in
    scalar) printf '%s\n' '"unexpected"'; return 0 ;;
    unknown-wrapper) printf '%s\n' '{"unknown":[]}'; return 0 ;;
    null-wrapper) printf '%s\n' '{"sandboxes":null}'; return 0 ;;
    multiple-wrappers) printf '%s\n' '{"sandboxes":[],"items":[]}'; return 0 ;;
    multiple-documents)
      printf '%s\n%s\n' '[{"id":"id-valid","name":"valid","agent":"codex","workspace":""}]' '[]'
      return 0
      ;;
    member-scalar) printf '%s\n' '[{"id":"id-valid","name":"valid","agent":"codex","workspace":""},"bad"]'; return 0 ;;
    member-missing-id) printf '%s\n' '[{"name":"missing-id","agent":"codex","workspace":""}]'; return 0 ;;
    member-invalid-id) printf '%s\n' '[{"id":42,"name":"invalid-id","agent":"codex","workspace":""}]'; return 0 ;;
    member-invalid-agent) printf '%s\n' '[{"id":"id-invalid-agent","name":"invalid-agent","agent":null,"workspace":""}]'; return 0 ;;
  esac
  while IFS=$'\t' read -r id name agent workspace || [ -n "$id" ]; do
    [ -n "$id" ] || continue
    jq -cn --arg id "$id" --arg name "$name" --arg agent "$agent" --arg workspace "$workspace" \
      '{id:$id,name:$name,agent:$agent,workspace:$workspace}'
  done < "$SBX_STATE" | jq -s .
}

[ "$#" -gt 0 ] || exit 2
log_argv "$@"
case "$1" in
  ls)
    case "${2:-}" in
      --json) json_state ;;
      --quiet) cut -f2 "$SBX_STATE" ;;
      *) exit 2 ;;
    esac
    ;;
  create)
    shift
    [ "${1:-}" = '--name' ] || exit 2
    name=${2:-}
    shift 2
    while [ "${1:-}" = '--kit' ]; do
      [ "$#" -ge 2 ] || exit 2
      shift 2
    done
    if [ "${1:-}" = '--clone' ]; then
      shift
    fi
    [ -n "${name:-}" ] || exit 2
    workspace=${2:-}
    printf 'id-%s\t%s\tcodex\t%s\n' "$name" "$name" "$workspace" >> "$SBX_STATE"
    if [ "${SBX_FAIL_CREATE_AFTER_RECORD:-0}" = '1' ]; then
      exit 1
    fi
    ;;
  exec)
    shift
    name=${1:-}
    shift
    if [ "${1:-}" = 'pwd' ] && [ "${SBX_FAIL_EXEC_PWD:-0}" = '1' ]; then
      exit 1
    fi
    if [ "${1:-}" = 'pwd' ]; then
      printf '%s\n' "${SBX_CLONE_CWD:-/sandbox/discovered}"
    fi
    ;;
  stop)
    [ "${SBX_FAIL_STOP_ID:-}" != "${2:-}" ] || exit 1
    ;;
  rm)
    if [ "${2:-}" = '--force' ]; then
      name=${3:-}
    else
      name=${2:-}
    fi
    [ -n "${name:-}" ] || exit 2
    remove_selector "$name"
    ;;
  *)
    exit 2
    ;;
esac
SBX
chmod +x "$FAKEBIN/sbx"

assert_argv() {
  local label=$1 expected_count=$2 actual_count=$3 i
  shift 3
  [ "$expected_count" -eq "$actual_count" ] || fail "$label: expected $expected_count argv entries, got $actual_count"
  for ((i = 0; i < expected_count; i++)); do
    [ "${1:-}" = "${FM_WORKSPACE_PLACEMENT_LAUNCH[$i]}" ] || \
      fail "$label: argv[$i] differs (expected '${1:-}', got '${FM_WORKSPACE_PLACEMENT_LAUNCH[$i]}')"
    shift
  done
}

workspace_real="$TMP_ROOT/selected"
additional_real="$TMP_ROOT/additional"
mkdir -p "$workspace_real" "$additional_real"
ln -s "$workspace_real" "$TMP_ROOT/selected-link"
ln -s "$additional_real" "$TMP_ROOT/additional-link"
printf 'parent\n' > "$workspace_real/parent.txt"

fm_workspace_placement_prepare host direct host-task "$workspace_real" || fail 'host direct prepare refused'
[ "$FM_WORKSPACE_PLACEMENT_HANDLE" = "host:$workspace_real" ] || fail 'host direct handle changed'
[ "$FM_WORKSPACE_PLACEMENT_WORKSPACE" = "$workspace_real" ] || fail 'host direct workspace changed'
[ "$FM_WORKSPACE_PLACEMENT_CWD" = "$workspace_real" ] || fail 'host direct cwd changed'
[ "$FM_WORKSPACE_PLACEMENT_ISOLATED" = 'no' ] || fail 'host direct claimed isolation'
fm_workspace_placement_wrap_launch host "$FM_WORKSPACE_PLACEMENT_HANDLE" "$workspace_real" \
  'command with spaces' 'arg with spaces' '--flag=value' || fail 'host launch wrapper refused'
assert_argv 'host launch wrapper' 3 "${#FM_WORKSPACE_PLACEMENT_LAUNCH[@]}" \
  'command with spaces' 'arg with spaces' '--flag=value'
pass 'host direct placement retains result and command argv'

ORIGINAL_PATH=$PATH
if (
# shellcheck disable=SC2123 # Intentional subshell-only PATH override proves sbx is absent.
  PATH="$TMP_ROOT/no-sbx"
  export PATH
  fm_workspace_placement_check docker-sandbox
); then
  fail 'Docker Sandbox check accepted a missing sbx tool'
fi
pass 'Docker Sandbox check refuses when sbx is missing'
PATH="$FAKEBIN:$ORIGINAL_PATH"; export PATH

: > "$SBX_STATE"
: > "$SBX_LOG"
fm_workspace_placement_prepare docker-sandbox direct direct.task "$TMP_ROOT/selected-link" official-agent \
  "$TMP_ROOT/additional-link" || fail 'Docker direct prepare refused'
selected_canonical=$(CDPATH='' cd "$workspace_real" && pwd -P)
additional_canonical=$(CDPATH='' cd "$additional_real" && pwd -P)
[ "$FM_WORKSPACE_PLACEMENT_HANDLE" = 'docker-sandbox:direct.task:fm-direct.task:id-fm-direct.task' ] || fail 'Docker direct handle did not bind the provider identity'
[ "$FM_WORKSPACE_PLACEMENT_WORKSPACE" = "$selected_canonical" ] || fail 'Docker direct workspace was not canonical'
[ "$FM_WORKSPACE_PLACEMENT_CWD" = "$selected_canonical" ] || fail 'Docker direct cwd was not canonical'
[ "$FM_WORKSPACE_PLACEMENT_ISOLATED" = 'yes' ] || fail 'Docker direct did not claim isolation'
[ -z "$FM_WORKSPACE_PLACEMENT_PENDING_NAME" ] || fail 'successful Docker direct prepare retained a pending provider name'
assert_grep $'create\t--name\tfm-direct.task\tofficial-agent\t'"$selected_canonical"$'\t'"$additional_canonical" "$SBX_LOG" \
  'Docker direct did not pass official preset and canonical selected/additional workspaces'
fm_workspace_placement_wrap_launch docker-sandbox "$FM_WORKSPACE_PLACEMENT_HANDLE" \
  '/workspace/discovered' 'agent command' 'argument with spaces' || fail 'Docker launch wrapper refused'
assert_argv 'Docker launch wrapper' 8 "${#FM_WORKSPACE_PLACEMENT_LAUNCH[@]}" \
  sbx exec -it -w '/workspace/discovered' fm-direct.task 'agent command' 'argument with spaces'
pass 'Docker direct placement mounts canonical workspaces and wraps exact sbx argv'

: > "$SBX_STATE"
: > "$SBX_LOG"
fm_workspace_placement_prepare docker-sandbox direct kit.task "$TMP_ROOT/selected-link" official-agent '' \
  'kit ref with spaces' kit.two || fail 'Docker direct kit prepare refused'
assert_grep $'create\t--name\tfm-kit.task\t--kit\tkit ref with spaces\t--kit\tkit.two\tofficial-agent\t'"$selected_canonical" "$SBX_LOG" \
  'Docker direct did not preserve repeatable kit refs when no additional workspace was supplied'
pass 'Docker direct accepts zero or more explicit kit refs without shell splitting'

for shape in scalar unknown-wrapper null-wrapper multiple-wrappers multiple-documents; do
  export SBX_JSON_SHAPE=$shape
  : > "$SBX_LOG"
  if fm_workspace_placement_inspect docker-sandbox docker-sandbox:malformed:fm-malformed:id-fm-malformed; then
    fail "malformed Docker inventory shape '$shape' was treated as an absent or valid sandbox"
  fi
  if fm_workspace_placement_docker_sandbox_snapshot_ids >/dev/null 2>&1; then
    fail "malformed Docker inventory shape '$shape' was accepted by the identity snapshot"
  fi
  if fm_workspace_placement_prepare docker-sandbox direct malformed.task "$workspace_real" official-agent; then
    fail "malformed Docker inventory shape '$shape' allowed provider creation"
  fi
  assert_no_grep $'create\t' "$SBX_LOG" "malformed Docker inventory shape '$shape' allowed creation"
done
unset SBX_JSON_SHAPE
pass 'Docker inventory rejects scalar and unsupported wrapper shapes without treating them as absence'

for shape in member-scalar member-missing-id member-invalid-id member-invalid-agent; do
  export SBX_JSON_SHAPE=$shape
  : > "$SBX_LOG"
  if fm_workspace_placement_inspect docker-sandbox docker-sandbox:malformed-member:fm-malformed-member:id-fm-malformed-member; then
    fail "malformed Docker inventory member '$shape' was treated as a valid or absent sandbox"
  fi
  if fm_workspace_placement_docker_sandbox_snapshot_ids >/dev/null 2>&1; then
    fail "malformed Docker inventory member '$shape' was accepted by the identity snapshot"
  fi
  if fm_workspace_placement_prepare docker-sandbox direct malformed-member.task "$workspace_real" official-agent; then
    fail "malformed Docker inventory member '$shape' allowed provider creation"
  fi
  assert_no_grep $'create\t' "$SBX_LOG" "malformed Docker inventory member '$shape' allowed creation"
done
unset SBX_JSON_SHAPE
pass 'Docker inventory rejects malformed members without dropping live identities'

: > "$SBX_STATE"
: > "$SBX_LOG"
export SBX_FAIL_CREATE_AFTER_RECORD=1
if fm_workspace_placement_prepare docker-sandbox direct partial.task "$workspace_real" official-agent; then
  fail 'Docker create failure unexpectedly published a partial placement'
fi
unset SBX_FAIL_CREATE_AFTER_RECORD
assert_grep 'fm-partial.task' "$SBX_STATE" 'Docker create failure discarded the unresolved provider state'
assert_no_grep $'stop\tid-fm-partial.task' "$SBX_LOG" 'Docker create failure removed before proving ownership'
assert_no_grep $'rm\t--force\tid-fm-partial.task' "$SBX_LOG" 'Docker create failure removed before proving ownership'
[ "$FM_WORKSPACE_PLACEMENT_PENDING_NAME" = 'fm-partial.task' ] || fail 'Docker create failure lost its unresolved name'
pass 'Docker create failure retains unresolved provider ownership safely'

printf 'id-fm-collision\tfm-collision\tcodex\t\nid-other\tother\tcodex\t\n' > "$SBX_STATE"
: > "$SBX_LOG"
if fm_workspace_placement_prepare docker-sandbox direct collision "$workspace_real" official-agent; then
  fail 'existing Docker Sandbox name collision was adopted'
fi
assert_no_grep $'create\t' "$SBX_LOG" 'name collision attempted create'
assert_grep $'ls\t--json' "$SBX_LOG" 'name collision did not inspect provider identities'
pass 'existing Docker Sandbox name refuses without create'

printf 'id-fm-duplicate\tfm-duplicate\tcodex\t\nid-fm-duplicate-2\tfm-duplicate\tcodex\t\n' > "$SBX_STATE"
: > "$SBX_LOG"
if fm_workspace_placement_prepare docker-sandbox direct duplicate "$workspace_real" official-agent; then
  fail 'ambiguous Docker Sandbox identity was accepted'
fi
assert_no_grep $'create\t' "$SBX_LOG" 'ambiguous identity attempted create'
pass 'ambiguous Docker Sandbox identity fails closed without create'

: > "$SBX_LOG"
printf 'id-fm-inspect\tfm-inspect\tcodex\t\n' > "$SBX_STATE"
fm_workspace_placement_inspect docker-sandbox docker-sandbox:inspect:fm-inspect:id-fm-inspect || fail 'present handle inspect refused'
[ "$FM_WORKSPACE_PLACEMENT_PRESENT" = '1' ] || fail 'present handle was not reported present'
: > "$SBX_STATE"
if fm_workspace_placement_inspect docker-sandbox docker-sandbox:inspect:fm-inspect:id-fm-inspect; then
  fail 'absent handle inspect unexpectedly succeeded'
fi
[ "$FM_WORKSPACE_PLACEMENT_PRESENT" = '0' ] || fail 'absent handle was not reported absent'
pass 'Docker inspect reports exact handle presence and absence'

printf 'id-fm-release\tfm-release\tcodex\t\nid-other\tother\tcodex\t\n' > "$SBX_STATE"
: > "$SBX_LOG"
fm_workspace_placement_release docker-sandbox docker-sandbox:release:fm-release:id-fm-release force || fail 'forced Docker release refused'
assert_grep $'stop\tid-fm-release' "$SBX_LOG" 'release did not stop exact provider identity'
assert_grep $'rm\t--force\tid-fm-release' "$SBX_LOG" 'release did not propagate force to provider identity'
assert_no_grep $'stop\tid-other' "$SBX_LOG" 'release stopped an unrelated sandbox'
assert_no_grep $'rm\t--force\tid-other' "$SBX_LOG" 'release removed an unrelated sandbox'
assert_grep 'other' "$SBX_STATE" 'release removed an unrelated sandbox from state'
assert_no_grep 'fm-release' "$SBX_STATE" 'release left the released sandbox in state'
pass 'Docker release stops and removes only the exact provider identity'

: > "$SBX_STATE"
: > "$SBX_LOG"
printf 'parent\n' > "$workspace_real/parent.txt"
source_before=$(cat "$workspace_real/parent.txt")
export SBX_CLONE_CWD=/clone/discovered
unset SBX_FAIL_EXEC_PWD
fm_workspace_placement_prepare docker-sandbox clone clone.task "$workspace_real" official-agent || fail 'clone prepare refused'
[ "$FM_WORKSPACE_PLACEMENT_HANDLE" = 'docker-sandbox:clone.task:fm-clone.task:id-fm-clone.task' ] || fail 'clone handle did not bind the provider identity'
[ "$FM_WORKSPACE_PLACEMENT_CWD" = '/clone/discovered' ] || fail 'clone did not record discovered cwd'
[ -z "$FM_WORKSPACE_PLACEMENT_PENDING_NAME" ] || fail 'successful Docker clone prepare retained a pending provider name'
[ "$(cat "$workspace_real/parent.txt")" = "$source_before" ] || fail 'clone modified parent source contents'
assert_grep $'create\t--name\tfm-clone.task\t--clone\tofficial-agent\t'"$selected_canonical" "$SBX_LOG" \
  'clone did not pass the parent source to sbx create'
assert_grep $'exec\tfm-clone.task\tpwd' "$SBX_LOG" 'clone did not discover cwd with sbx exec'
pass 'clone success records discovered cwd without modifying parent source'

printf 'id-survivor\tsurvivor\tcodex\t\n' > "$SBX_STATE"
: > "$SBX_LOG"
export SBX_FAIL_EXEC_PWD=1
if fm_workspace_placement_prepare docker-sandbox clone failed.task "$workspace_real" official-agent; then
  fail 'clone cwd failure unexpectedly published a placement'
fi
unset SBX_FAIL_EXEC_PWD
assert_grep 'survivor' "$SBX_STATE" 'clone cwd failure removed an unrelated sandbox'
assert_no_grep 'fm-failed.task' "$SBX_STATE" 'clone cwd failure left unpublished sandbox'
assert_grep $'stop\tid-fm-failed.task' "$SBX_LOG" 'clone cwd failure did not stop unpublished sandbox'
assert_grep $'rm\t--force\tid-fm-failed.task' "$SBX_LOG" 'clone cwd failure did not remove unpublished sandbox'
[ "$FM_WORKSPACE_PLACEMENT_ACQUIRED_HANDLE" = 'docker-sandbox:failed.task:fm-failed.task:id-fm-failed.task' ] || fail 'clone cwd failure lost the exact acquired placement handle'
assert_no_grep $'stop\tsurvivor' "$SBX_LOG" 'clone cwd failure stopped unrelated sandbox'
assert_no_grep $'rm\tsurvivor' "$SBX_LOG" 'clone cwd failure removed unrelated sandbox'
pass 'clone cwd failure cleans only its unpublished name'

: > "$SBX_STATE"
: > "$SBX_LOG"
if fm_workspace_placement_prepare docker-sandbox direct 'bad/task' "$workspace_real" official-agent; then
  fail 'invalid task ID was accepted'
fi
if fm_workspace_placement_inspect docker-sandbox 'docker-sandbox:task:wrong-name'; then
  fail 'invalid handle was accepted'
fi
if fm_workspace_placement_check unknown-placement; then
  fail 'unknown placement was accepted'
fi
assert_no_grep $'create\t' "$SBX_LOG" 'invalid inputs invoked sandbox creation'
pass 'invalid task ID, handle, and unknown placement are refused'

echo 'ALL TESTS PASSED'
