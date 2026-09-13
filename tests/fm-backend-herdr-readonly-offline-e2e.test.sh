#!/usr/bin/env bash
# Real-Herdr regression for read-only fleet polling against a stopped session.
#
# Magistrate repeatedly invokes bin/fm-fleet-snapshot.sh --json through its
# Firstmate client.
# Before this regression was fixed, that read reached capture readiness, which
# called the mutation-ready server ensure and restored an offline Herdr session.
# This test runs crew state and the repeated snapshot sequence against a real,
# stopped, non-default lab and proves that no server, workspace, tab, or pane is
# created.
# It then drives one explicit Firstmate container mutation and proves that path
# still starts the same named server.
#
# Every real Herdr command is routed through bin/fm-herdr-lab.sh.
# The PATH wrapper only removes Firstmate's already-validated trailing session
# flag and maps the product's explicit server-start request to the helper's
# guarded provision action.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
[ -x "$HERDR_LAB_HELPER" ] || { echo "skip: Herdr lab helper not executable at $HERDR_LAB_HELPER"; exit 0; }

# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"

HERDR_ORIGINAL_PATH=$PATH
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name firstmate-herdr-readonly-probe-p1) \
  || fail "could not generate an isolated Herdr lab name"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-herdr-readonly-offline.XXXXXX") \
  || fail "could not create temporary test root"

cleanup_all() {
  local status=$?
  env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" >/dev/null 2>&1 \
    || { [ "$status" -ne 0 ] || status=1; }
  rm -rf "$TMP_ROOT"
  trap - EXIT
  exit "$status"
}
trap cleanup_all EXIT

export HERDR_LAB_HELPER HERDR_LAB_SESSION HERDR_ORIGINAL_PATH

env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" \
  || fail "could not provision the isolated Herdr lab"
lab() {
  env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"
}
wait_lab_running() {  # <true|false>
  local expected=$1 attempt=0 running
  while [ "$attempt" -lt 100 ]; do
    running=$(lab status --json 2>/dev/null | jq -r '
      if .server.running == true then "true"
      elif .server.running == false then "false"
      else "unknown"
      end
    ')
    [ "$running" = "$expected" ] && return 0
    sleep 0.1
    attempt=$((attempt + 1))
  done
  return 1
}

mkdir -p "$TMP_ROOT/setup-cwd" "$TMP_ROOT/worktree" "$TMP_ROOT/mutation-cwd"
setup=$(lab workspace create --label fm-readonly-offline-fixture --cwd "$TMP_ROOT/setup-cwd" --no-focus) \
  || fail "could not create the lab fixture workspace"
SETUP_WORKSPACE=$(printf '%s' "$setup" | jq -r '.result.workspace.workspace_id // empty')
SETUP_TAB=$(printf '%s' "$setup" | jq -r '.result.tab.tab_id // empty')
SETUP_PANE=$(printf '%s' "$setup" | jq -r '.result.root_pane.pane_id // empty')
[ -n "$SETUP_WORKSPACE" ] && [ -n "$SETUP_TAB" ] && [ -n "$SETUP_PANE" ] \
  || fail "fixture workspace creation returned incomplete ids: $setup"

# Give crew-state a real local branch so unrelated repository checks remain
# representative without reaching any project outside this temporary root.
git -C "$TMP_ROOT/worktree" init -q
git -C "$TMP_ROOT/worktree" config user.email test@example.invalid
git -C "$TMP_ROOT/worktree" config user.name "Firstmate Test"
printf 'fixture\n' > "$TMP_ROOT/worktree/README"
git -C "$TMP_ROOT/worktree" add README
git -C "$TMP_ROOT/worktree" commit -qm fixture
git -C "$TMP_ROOT/worktree" branch -M fm/read-only-probe

HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config" "$HOME_DIR/projects"
cat > "$HOME_DIR/state/probe.meta" <<EOF
kind=ship
project=firstmate
worktree=$TMP_ROOT/worktree
backend=herdr
harness=pi
window=$HERDR_LAB_SESSION:$SETUP_PANE
herdr_session=$HERDR_LAB_SESSION
herdr_workspace_id=$SETUP_WORKSPACE
herdr_tab_id=$SETUP_TAB
herdr_pane_id=$SETUP_PANE
EOF

FAKEBIN="$TMP_ROOT/fakebin"
HERDR_CALL_LOG="$TMP_ROOT/herdr-calls.log"
mkdir -p "$FAKEBIN"
: > "$HERDR_CALL_LOG"
export HERDR_CALL_LOG

# Log every adapter call and route it back through the guarded lab helper.
# A product server start is itself the behavior under test, so it is logged and
# translated to helper provision rather than executed as a raw lifecycle call.
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
{
  first=1
  for arg in "$@"; do
    [ "$first" -eq 0 ] && printf '\t'
    printf '%s' "$arg"
    first=0
  done
  printf '\n'
} >> "${HERDR_CALL_LOG:?}"
args=("$@")
clean=()
i=0
while [ "$i" -lt "${#args[@]}" ]; do
  case "${args[$i]}" in
    --session)
      i=$((i + 1))
      [ "$i" -lt "${#args[@]}" ] || { echo "test wrapper: missing session value" >&2; exit 98; }
      [ "${args[$i]}" = "${HERDR_LAB_SESSION:?}" ] \
        || { echo "test wrapper: wrong session ${args[$i]}" >&2; exit 97; }
      ;;
    --session=*)
      echo "test wrapper: unexpected inline session flag" >&2
      exit 96
      ;;
    *) clean+=("${args[$i]}") ;;
  esac
  i=$((i + 1))
done
if [ "${clean[0]:-}" = server ]; then
  exec env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"
fi
exec env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "${clean[@]}"
SH
cat > "$FAKEBIN/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$FAKEBIN/herdr" "$FAKEBIN/no-mistakes"

product_env=(
  env
  -u HERDR_ENV
  -u HERDR_PANE_ID
  -u HERDR_SOCKET_PATH
  -u HERDR_TAB_ID
  -u HERDR_WORKSPACE_ID
  PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH"
  FM_HOME="$HOME_DIR"
  FM_BACKEND=herdr
  HERDR_SESSION="$HERDR_LAB_SESSION"
  HERDR_LAB_SESSION="$HERDR_LAB_SESSION"
  HERDR_LAB_HELPER="$HERDR_LAB_HELPER"
  HERDR_ORIGINAL_PATH="$HERDR_ORIGINAL_PATH"
  HERDR_CALL_LOG="$HERDR_CALL_LOG"
  FM_BACKEND_HERDR_OBSERVE_TIMEOUT=2
)

assert_no_product_mutation() {
  local mutations
  mutations=$(awk -F '\t' '
    $1 == "status" ||
    ($1 == "session" && $2 == "list") ||
    ($1 == "workspace" && $2 == "list") ||
    ($1 == "tab" && ($2 == "list" || $2 == "get")) ||
    ($1 == "pane" && ($2 == "get" || $2 == "list" || $2 == "read" || $2 == "process-info")) ||
    ($1 == "agent" && $2 == "get") ||
    ($1 == "api" && $2 == "schema") {
      next
    }
    { print }
  ' "$HERDR_CALL_LOG")
  [ -z "$mutations" ] || fail "read-only polling invoked Herdr mutation commands: $mutations"
}

# The lab must be stopped before the first product observation.
env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" stop "$HERDR_LAB_SESSION" >/dev/null \
  || fail "could not stop the isolated Herdr lab before polling"
wait_lab_running false || fail "the isolated Herdr lab did not stop before polling"
: > "$HERDR_CALL_LOG"

crew_out=$(fm_run_timed 12 "${product_env[@]}" "$ROOT/bin/fm-crew-state.sh" probe 2>&1) \
  || fail "crew-state did not return within its bound: $crew_out"
printf '%s' "$crew_out" | grep -Fq 'state: unknown' \
  || fail "crew-state did not report a conservative unknown result while Herdr was offline: $crew_out"
pass "crew-state returns promptly and reports the stopped Herdr endpoint unavailable"

# This is the executable API and repeated call shape Magistrate's activity
# reconciliation uses through FirstmateClient.
for poll in 1 2 3; do
  snapshot=$(fm_run_timed 15 "${product_env[@]}" "$ROOT/bin/fm-fleet-snapshot.sh" --json) \
    || fail "fleet snapshot poll $poll did not return within its bound"
  printf '%s' "$snapshot" | jq -e --arg id probe '
    .schema == "fm-fleet-snapshot.v1"
    and (.tasks[] | select(.id == $id)
      | .backend == "herdr"
        and .endpoint.exists == false
        and .current_state.state == "unknown")
  ' >/dev/null || fail "fleet snapshot poll $poll returned an untruthful offline task row: $snapshot"
done
assert_no_product_mutation
running=$(lab status --json | jq -r '
  if .server.running == true then "true"
  elif .server.running == false then "false"
  else "unknown"
  end
')
[ "$running" = false ] || fail "read-only polling started the stopped Herdr server"
pass "three Gateway-style fleet reconciliations leave the real named Herdr server stopped"

# Restart only through the lab helper to inspect the persisted layout.
# The exact pre-poll ids must be the complete restored layout, proving the
# observations created no workspace, tab, or pane while the server was offline.
env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" \
  || fail "could not re-provision the lab for layout verification"
workspaces=$(lab workspace list) || fail "could not inspect restored workspaces"
tabs=$(lab tab list --workspace "$SETUP_WORKSPACE") || fail "could not inspect restored tabs"
panes=$(lab pane list --workspace "$SETUP_WORKSPACE") || fail "could not inspect restored panes"
printf '%s' "$workspaces" | jq -e --arg id "$SETUP_WORKSPACE" '
  (.result.workspaces | length) == 1
  and .result.workspaces[0].workspace_id == $id
' >/dev/null || fail "read-only polling changed the persisted workspace layout: $workspaces"
printf '%s' "$tabs" | jq -e --arg id "$SETUP_TAB" '
  (.result.tabs | length) == 1
  and .result.tabs[0].tab_id == $id
' >/dev/null || fail "read-only polling changed the persisted tab layout: $tabs"
printf '%s' "$panes" | jq -e --arg id "$SETUP_PANE" '
  (.result.panes | length) == 1
  and .result.panes[0].pane_id == $id
' >/dev/null || fail "read-only polling changed the persisted pane layout: $panes"
pass "read-only polling creates no Herdr workspace, tab, or pane"

# Explicit container creation remains mutation-ready and must still start the
# stopped server before creating or adopting its home workspace.
env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" stop "$HERDR_LAB_SESSION" >/dev/null \
  || fail "could not stop the lab before the explicit mutation proof"
wait_lab_running false || fail "the isolated Herdr lab did not stop before the mutation proof"
: > "$HERDR_CALL_LOG"
# shellcheck disable=SC2016 # The child shell expands its positional parameters.
mutation_out=$(fm_run_timed 30 "${product_env[@]}" bash -c '
  . "$1/bin/fm-backend.sh"
  fm_backend_source herdr
  fm_backend_herdr_container_ensure "$2"
' _ "$ROOT" "$TMP_ROOT/mutation-cwd") \
  || fail "explicit Herdr container mutation failed: $mutation_out"
case "$mutation_out" in
  "$HERDR_LAB_SESSION":*) ;;
  *) fail "container mutation returned an unexpected target: $mutation_out" ;;
esac
awk -F '\t' '$1 == "server" { found=1 } END { exit(found ? 0 : 1) }' "$HERDR_CALL_LOG" \
  || fail "explicit container mutation did not request a named Herdr server start"
awk -F '\t' '$1 == "workspace" && $2 == "create" { found=1 } END { exit(found ? 0 : 1) }' "$HERDR_CALL_LOG" \
  || fail "explicit container mutation did not create the missing home workspace"
running=$(lab status --json | jq -r '
  if .server.running == true then "true"
  elif .server.running == false then "false"
  else "unknown"
  end
')
[ "$running" = true ] || fail "explicit container mutation did not leave the named Herdr server running"
pass "explicit Firstmate container creation still starts the stopped named Herdr server"
