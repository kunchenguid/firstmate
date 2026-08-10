#!/usr/bin/env bash
# Real named-session proof that pre-update Herdr metadata can be bound only to
# its exact live endpoint, while a duplicate task label remains refused.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

# This suite drives the real bin/fm-herdr-endpoint-bind.sh but sources neither
# tests/lib.sh nor tests/herdr-test-safety.sh, so take the same documented
# test-harness exemption they do: firstmate's own no-mistakes run executes the
# suite from a gate worktree, which is exactly what the binder's
# fm_refuse_if_gate_agent backstop refuses (bin/fm-gate-refuse-lib.sh).
export FM_GATE_REFUSE_BYPASS=1

fail() {
  printf 'not ok - %s\n' "$1" >&2
  rm -rf "$TMP_ROOT"
  exit 1
}

command -v herdr >/dev/null 2>&1 || { echo 'skip: herdr not found'; exit 0; }
command -v jq >/dev/null 2>&1 || { echo 'skip: jq not found'; exit 0; }
[ -x "$HERDR_LAB_HELPER" ] || { echo "skip: Herdr lab helper not executable at $HERDR_LAB_HELPER"; exit 0; }

REAL_HERDR=$(command -v herdr)
HERDR_ORIGINAL_PATH=$PATH
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-herdr-endpoint-bind-e2e.XXXXXX")
FAKEBIN="$TMP_ROOT/fakebin"
HOME_DIR="$TMP_ROOT/home"
WORKTREE="$TMP_ROOT/worktree"
mkdir -p "$FAKEBIN" "$HOME_DIR/state" "$WORKTREE"

HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fix-watcher-turn-reap)
export HERDR_LAB_HELPER HERDR_LAB_SESSION REAL_HERDR HERDR_ORIGINAL_PATH
trap '"$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION"' EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" || fail 'could not provision the guarded Herdr lab'

# Production adapter calls already carry the exact trailing session pair.
# Strip only that pair and delegate every real operation to the guarded helper.
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
args=("$@")
last=$((${#args[@]} - 1))
flag=$((last - 1))
if [ "${#args[@]}" -ge 2 ] \
  && [ "${args[$flag]}" = --session ] \
  && [ "${args[$last]}" = "$HERDR_LAB_SESSION" ]; then
  unset "args[$last]" "args[$flag]"
fi
set -- "${args[@]}"
for arg in "$@"; do
  case "$arg" in --session|--session=*) exit 9 ;; esac
done
if [ "${1:-}" = --version ]; then
  exec env PATH="$HERDR_ORIGINAL_PATH" "$REAL_HERDR" "$@" --session "$HERDR_LAB_SESSION"
fi
exec env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"
SH
chmod +x "$FAKEBIN/herdr"

lab() {
  env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"
}

WORKSPACE_OUT=$(lab workspace create --cwd "$WORKTREE" --label endpoint-binding --no-focus) \
  || fail 'could not create the binding workspace'
WORKSPACE=$(printf '%s' "$WORKSPACE_OUT" | jq -er '.result.workspace.workspace_id') \
  || fail 'could not read the binding workspace id'

ID=legacy-herdr
TAB_OUT=$(lab tab create --workspace "$WORKSPACE" --cwd "$WORKTREE" --label "fm-$ID" --no-focus) \
  || fail 'could not create the exact legacy endpoint'
TAB=$(printf '%s' "$TAB_OUT" | jq -er '.result.tab.tab_id') \
  || fail 'could not read the exact legacy tab id'
PANE=$(printf '%s' "$TAB_OUT" | jq -er '.result.root_pane.pane_id') \
  || fail 'could not read the exact legacy pane id'
{
  printf 'project=fixture\n'
  printf 'worktree=%s\n' "$WORKTREE"
  printf 'window=%s:%s\n' "$HERDR_LAB_SESSION" "$PANE"
  printf 'backend=herdr\n'
  printf 'herdr_session=%s\n' "$HERDR_LAB_SESSION"
  printf 'herdr_workspace_id=%s\n' "$WORKSPACE"
  printf 'herdr_tab_id=%s\n' "$TAB"
  printf 'herdr_pane_id=%s\n' "$PANE"
} > "$HOME_DIR/state/$ID.meta"

FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" \
  "$ROOT/bin/fm-herdr-endpoint-bind.sh" "$ID" \
  || fail 'exact live legacy endpoint did not bind'
[ "$(grep -c '^endpoint_task_id=legacy-herdr$' "$HOME_DIR/state/$ID.meta")" = 1 ] \
  || fail 'exact live legacy endpoint did not publish one binding'

NL_ID=legacy-no-newline
NL_OUT=$(lab tab create --workspace "$WORKSPACE" --cwd "$WORKTREE" --label "fm-$NL_ID" --no-focus) \
  || fail 'could not create the unterminated-metadata endpoint'
NL_TAB=$(printf '%s' "$NL_OUT" | jq -er '.result.tab.tab_id') \
  || fail 'could not read the unterminated-metadata tab id'
NL_PANE=$(printf '%s' "$NL_OUT" | jq -er '.result.root_pane.pane_id') \
  || fail 'could not read the unterminated-metadata pane id'
{
  printf 'project=fixture\n'
  printf 'worktree=%s\n' "$WORKTREE"
  printf 'window=%s:%s\n' "$HERDR_LAB_SESSION" "$NL_PANE"
  printf 'backend=herdr\n'
  printf 'herdr_session=%s\n' "$HERDR_LAB_SESSION"
  printf 'herdr_workspace_id=%s\n' "$WORKSPACE"
  printf 'herdr_tab_id=%s\n' "$NL_TAB"
  printf 'herdr_pane_id=%s' "$NL_PANE"
} > "$HOME_DIR/state/$NL_ID.meta"

FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" \
  "$ROOT/bin/fm-herdr-endpoint-bind.sh" "$NL_ID" \
  || fail 'legacy metadata without a trailing newline did not bind'
[ "$(grep -c '^endpoint_task_id=legacy-no-newline$' "$HOME_DIR/state/$NL_ID.meta")" = 1 ] \
  || fail 'unterminated legacy metadata did not publish one standalone binding'
[ "$(grep -c "^herdr_pane_id=$NL_PANE\$" "$HOME_DIR/state/$NL_ID.meta")" = 1 ] \
  || fail 'unterminated legacy metadata fused its last key with the new binding'

DUP_ID=legacy-duplicate
DUP_ONE=$(lab tab create --workspace "$WORKSPACE" --cwd "$WORKTREE" --label "fm-$DUP_ID" --no-focus) \
  || fail 'could not create the duplicate-label control endpoint'
lab tab create --workspace "$WORKSPACE" --cwd "$WORKTREE" --label "fm-$DUP_ID" --no-focus >/dev/null \
  || fail 'could not create the duplicate-label neighbor'
DUP_TAB=$(printf '%s' "$DUP_ONE" | jq -er '.result.tab.tab_id') \
  || fail 'could not read the duplicate control tab id'
DUP_PANE=$(printf '%s' "$DUP_ONE" | jq -er '.result.root_pane.pane_id') \
  || fail 'could not read the duplicate control pane id'
{
  printf 'project=fixture\n'
  printf 'worktree=%s\n' "$WORKTREE"
  printf 'window=%s:%s\n' "$HERDR_LAB_SESSION" "$DUP_PANE"
  printf 'backend=herdr\n'
  printf 'herdr_session=%s\n' "$HERDR_LAB_SESSION"
  printf 'herdr_workspace_id=%s\n' "$WORKSPACE"
  printf 'herdr_tab_id=%s\n' "$DUP_TAB"
  printf 'herdr_pane_id=%s\n' "$DUP_PANE"
} > "$HOME_DIR/state/$DUP_ID.meta"

if FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" \
  "$ROOT/bin/fm-herdr-endpoint-bind.sh" "$DUP_ID" >"$TMP_ROOT/duplicate.out" 2>"$TMP_ROOT/duplicate.err"; then
  fail 'duplicate task labels incorrectly authorized a binding'
fi
grep -F "live Herdr endpoint does not exactly match task $DUP_ID topology, label, and worktree" \
  "$TMP_ROOT/duplicate.err" >/dev/null \
  || fail "duplicate task label case refused for another reason: $(cat "$TMP_ROOT/duplicate.err")"
! grep -q '^endpoint_task_id=' "$HOME_DIR/state/$DUP_ID.meta" \
  || fail 'duplicate task label refusal changed legacy metadata'

rm -rf "$TMP_ROOT"
printf 'ok - real guarded Herdr lab bound one exact legacy endpoint and refused a duplicate task label without metadata mutation\n'
