#!/usr/bin/env bash
# tests/fm-backend-autodetect-smoke.test.sh - real herdr smoke test for runtime
# backend AUTO-DETECTION (bin/fm-backend.sh's fm_backend_detect, wired into
# fm_backend_name between config/backend and the tmux default).
#
# Unlike tests/fm-backend-herdr.test.sh (fake herdr CLI) and
# tests/fm-backend-herdr-smoke.test.sh (real herdr, adapter primitives called
# directly), this suite drives the REAL bin/fm-spawn.sh and bin/fm-teardown.sh
# end to end, because auto-detection is a fm-spawn-TIME decision, not an
# adapter primitive - it has to be proven where fm_backend_name is actually
# called. The real spawn runs in a helper-provisioned, per-run named Herdr lab
# session, with a scratch FM_HOME and scratch local-only project. Concurrent
# copies therefore never share the default session or a workspace namespace.
#
# The complementary "tmux nested inside herdr resolves to tmux, silently" case
# is covered as a fast, deterministic fake-tmux fm-spawn.sh test in
# tests/fm-backend.test.sh (test_spawn_autodetect_nesting_resolves_tmux_silently).
# Reproducing a genuinely nested real-tmux-inside-real-herdr pane here would
# need a live attached tmux client, which a background test script cannot
# manufacture; the selection LOGIC for that case is already exercised for real
# by fm_backend_detect's own unit coverage plus that fake-tmux fm-spawn test.
#
# Safety (2026-07-02 incident): every test-owned Herdr operation goes through
# bin/fm-herdr-lab.sh, which appends the named session flag and verifies the
# default fleet session is unchanged after teardown. Never replace the helper
# with an ambient HERDR_SESSION-only command.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
assert_contains_local() {  # <haystack> <needle> <msg>
  case "$1" in
    *"$2"*) : ;;
    *) fail "$3"$'\n'"--- got ---"$'\n'"$1" ;;
  esac
}

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }
command -v treehouse >/dev/null 2>&1 || { echo "skip: treehouse not found (required by fm-spawn.sh)"; exit 0; }

export FM_GATE_REFUSE_BYPASS=1

# TMP_ROOT is physically resolved (mktemp -d "$(pwd -P)"-relative) to keep this
# real-herdr smoke fixture free of unrelated OS symlink noise.
# The old fm-spawn bug that originally motivated this fixture shape was fixed in
# fm-spawn-symlink-guard-s8: fm-spawn.sh now normalizes PROJ_ABS and observed
# backend cwd reads before the worktree-discovery comparison.
# The dedicated regression is
# tests/fm-backend.test.sh:test_spawn_symlinked_project_prefix_avoids_false_refusal.
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-backend-autodetect-smoke.XXXXXX")
HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fm-autodetect-smoke-concurrency-h3) || {
  rm -rf "$TMP_ROOT"
  fail "could not generate an isolated Herdr lab session name"
}
export HERDR_SESSION="$HERDR_LAB_SESSION"
ID="autodetectsmoke1"
WT=
cleanup_all() {
  local cleanup_status=0
  [ -n "$WT" ] && command -v treehouse >/dev/null 2>&1 && treehouse return --force "$WT" >/dev/null 2>&1
  "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || cleanup_status=$?
  rm -rf "$TMP_ROOT"
  return "$cleanup_status"
}
on_exit() {
  local status=$?
  cleanup_all || status=$?
  trap - EXIT
  exit "$status"
}
trap on_exit EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" || fail "could not provision isolated Herdr lab session"

# --- scratch world: FM_HOME with NO backend config, one throwaway project ---

STATE="$TMP_ROOT/state"; DATA="$TMP_ROOT/data"; CONFIG="$TMP_ROOT/config"
mkdir -p "$STATE" "$DATA/$ID" "$CONFIG"
printf 'trivial autodetect-smoke brief: nothing to do.\n' > "$DATA/$ID/brief.md"

PROJ="$TMP_ROOT/scratch-project"
mkdir -p "$PROJ"
git -C "$PROJ" init -q
printf '# scratch\n' > "$PROJ/README.md"
git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial

# --- spawn with NO explicit backend config; HERDR_ENV=1 is the only marker --

OUT_FILE="$TMP_ROOT/spawn.out"; ERR_FILE="$TMP_ROOT/spawn.err"
env -u TMUX -u FM_BACKEND PATH="$PATH" HERDR_ENV=1 \
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
  FM_CONFIG_OVERRIDE="$CONFIG" FM_PROJECTS_OVERRIDE="$TMP_ROOT/unused-projects" \
  FM_SPAWN_NO_GUARD=1 \
  "$ROOT/bin/fm-spawn.sh" "$ID" "$PROJ" "sh -c 'echo autodetect-smoke-ok'" \
  >"$OUT_FILE" 2>"$ERR_FILE"
status=$?
[ "$status" -eq 0 ] || fail "fm-spawn.sh did not succeed auto-detecting herdr"$'\n'"--- stdout ---"$'\n'"$(cat "$OUT_FILE")"$'\n'"--- stderr ---"$'\n'"$(cat "$ERR_FILE")"

assert_contains_local "$(cat "$ERR_FILE")" "NOTICE" \
  "fm-spawn.sh did not print the auto-detect notice to stderr when selecting herdr"
assert_contains_local "$(cat "$ERR_FILE")" "EXPERIMENTAL herdr backend" \
  "fm-spawn.sh's auto-detect notice did not flag herdr as experimental"
pass "real herdr: fm-spawn.sh auto-detects herdr from HERDR_ENV=1 (no explicit config) and prints the loud notice"

META="$STATE/$ID.meta"
[ -f "$META" ] || fail "fm-spawn.sh did not write a meta file for $ID"
assert_contains_local "$(cat "$META")" "backend=herdr" \
  "auto-detected spawn did not record backend=herdr in meta"
assert_contains_local "$(cat "$META")" "herdr_session=$HERDR_LAB_SESSION" \
  "auto-detected spawn did not record the isolated herdr_session in meta"

WORKSPACE=$(grep '^herdr_workspace_id=' "$META" | cut -d= -f2-)
[ -n "$WORKSPACE" ] || fail "auto-detected spawn meta is missing herdr_workspace_id"

TAB=$(grep '^herdr_tab_id=' "$META" | cut -d= -f2-)
[ -n "$TAB" ] || fail "auto-detected spawn meta is missing herdr_tab_id"

WT=$(grep '^worktree=' "$META" | cut -d= -f2-)
if [ -z "$WT" ] || [ ! -d "$WT" ]; then
  fail "auto-detected spawn did not report a real worktree path"
fi

PANE=$(grep '^herdr_pane_id=' "$META" | cut -d= -f2-)
[ -n "$PANE" ] || fail "auto-detected spawn meta is missing herdr_pane_id"
pass "real herdr: auto-detected spawn records backend=herdr and herdr_session/workspace/tab/pane fields in meta"

# --- confirm the trivial launch command actually ran in the herdr pane ------

sleep 1
CAPTURED=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane read "$PANE" --source recent --lines 200) || \
  fail "capture failed on the auto-detected herdr pane"
CAPTURED=$(printf '%s\n' "$CAPTURED" | tail -n 30)
case "$CAPTURED" in
  *autodetect-smoke-ok*) : ;;
  *) fail "the raw launch command did not run in the auto-detected herdr pane"$'\n'"$CAPTURED" ;;
esac
pass "real herdr: the auto-detected spawn's launch command actually ran in the herdr pane"

# --- teardown completes the trivial spawn/teardown cycle --------------------

TEARDOWN_OUT="$TMP_ROOT/teardown.out"
FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
  FM_CONFIG_OVERRIDE="$CONFIG" \
  "$ROOT/bin/fm-teardown.sh" "$ID" >"$TEARDOWN_OUT" 2>&1
status=$?
[ "$status" -eq 0 ] || fail "fm-teardown.sh failed for the auto-detected herdr task"$'\n'"$(cat "$TEARDOWN_OUT")"
[ -f "$META" ] && fail "fm-teardown.sh did not remove $META"
if "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane get "$PANE" >/dev/null 2>&1; then
  fail "fm-teardown.sh did not close the auto-detected herdr pane"
fi
WT=
pass "real herdr: teardown completes the auto-detected spawn/teardown cycle (meta cleared, pane closed)"

# --- nested secondmate-watcher environment cannot claim another server -----

NESTED_HOME="$TMP_ROOT/nested-secondmate-home"
NESTED_FAKEBIN="$TMP_ROOT/nested-fakebin"
NESTED_LOG="$TMP_ROOT/nested-herdr.log"
NESTED_ENV_OUT="$TMP_ROOT/nested-env.out"
NESTED_RESULT="$TMP_ROOT/nested-result.out"
NESTED_STATUS="$TMP_ROOT/nested-status.out"
NESTED_PROBE="$TMP_ROOT/nested-probe.sh"
mkdir -p "$NESTED_HOME" "$NESTED_FAKEBIN"
printf 'nested-sm\n' > "$NESTED_HOME/.fm-secondmate-home"
cat > "$NESTED_FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
{
  printf 'HERDR_SESSION=%s' "${HERDR_SESSION:-}"
  for arg in "$@"; do
    printf '\037%s' "$arg"
  done
  printf '\n'
} >> "${FM_NESTED_LOG:?}"
printf '{"server":{"running":false}}\n'
SH
chmod +x "$NESTED_FAKEBIN/herdr"
cat > "$NESTED_PROBE" <<'SH'
#!/usr/bin/env bash
set -u
{
  printf 'FM_HOME=%s\n' "${FM_HOME:-}"
  printf 'HERDR_ENV=%s\n' "${HERDR_ENV:-}"
  printf 'HERDR_SESSION=%s\n' "${HERDR_SESSION:-}"
  printf 'HERDR_PANE_ID=%s\n' "${HERDR_PANE_ID:-}"
  printf 'HERDR_WORKSPACE_ID=%s\n' "${HERDR_WORKSPACE_ID:-}"
  printf 'HERDR_SOCKET_PATH=%s\n' "${HERDR_SOCKET_PATH:-}"
} > "${FM_NESTED_ENV_OUT:?}"
PATH="${FM_NESTED_FAKEBIN:?}:$PATH" FM_NESTED_LOG="${FM_NESTED_LOG:?}" \
  bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_server_ensure "${HERDR_SESSION:-default}"' \
    "${FM_NESTED_ROOT:?}" > "${FM_NESTED_RESULT:?}" 2>&1
printf '%s\n' "$?" > "${FM_NESTED_STATUS:?}"
SH
chmod +x "$NESTED_PROBE"

NESTED_CREATE=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" \
  workspace create --cwd "$ROOT" --label nested-single-server-guard --no-focus) || \
  fail "could not create the isolated nested-server guard pane"
NESTED_PANE=$(printf '%s' "$NESTED_CREATE" | jq -r '.result.root_pane.pane_id // empty')
[ -n "$NESTED_PANE" ] || fail "nested-server guard fixture did not return a pane id"
sleep 1
printf -v NESTED_COMMAND \
  'FM_HOME=%q FM_NESTED_ROOT=%q FM_NESTED_FAKEBIN=%q FM_NESTED_LOG=%q FM_NESTED_ENV_OUT=%q FM_NESTED_RESULT=%q FM_NESTED_STATUS=%q %q' \
  "$NESTED_HOME" "$ROOT" "$NESTED_FAKEBIN" "$NESTED_LOG" "$NESTED_ENV_OUT" \
  "$NESTED_RESULT" "$NESTED_STATUS" "$NESTED_PROBE"
"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane run "$NESTED_PANE" "$NESTED_COMMAND" || \
  fail "could not run the nested-server guard probe inside the isolated Herdr pane"
for _ in $(seq 1 100); do
  [ -s "$NESTED_STATUS" ] && break
  sleep 0.1
done
[ -s "$NESTED_STATUS" ] || fail "nested-server guard probe did not finish"
[ "$(cat "$NESTED_STATUS")" -ne 0 ] || \
  fail "nested-server guard probe accepted a competing server start"
assert_contains_local "$(cat "$NESTED_ENV_OUT")" "FM_HOME=$NESTED_HOME" \
  "nested probe did not carry the secondmate watcher's home"
assert_contains_local "$(cat "$NESTED_ENV_OUT")" "HERDR_ENV=1" \
  "real Herdr pane did not supply the nested-runtime marker"
assert_contains_local "$(cat "$NESTED_ENV_OUT")" "HERDR_SESSION=$HERDR_LAB_SESSION" \
  "real Herdr pane did not inherit its exact named session"
assert_contains_local "$(cat "$NESTED_ENV_OUT")" "HERDR_PANE_ID=$NESTED_PANE" \
  "real Herdr pane did not inherit its exact pane identity"
assert_contains_local "$(cat "$NESTED_RESULT")" "refusing to start a competing server" \
  "nested-server guard did not return its actionable refusal"
assert_contains_local "$(cat "$NESTED_LOG")" $'\037status\037--json\037--session\037'"$HERDR_LAB_SESSION" \
  "nested-server guard did not check the exact inherited named session"
case "$(cat "$NESTED_LOG")" in
  *$'\037server'*) fail "nested-server guard invoked a competing server after the scoped status miss" ;;
esac
pass "real herdr: a secondmate-watcher-shaped process inside a named lab pane refuses a competing same-socket server start"

if ! cleanup_all; then
  trap - EXIT
  fail "isolated Herdr lab teardown failed or the default fleet session changed"
fi
trap - EXIT
pass "real herdr: isolated lab session removed and default fleet session unchanged"
