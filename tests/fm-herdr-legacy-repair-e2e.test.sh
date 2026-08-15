#!/usr/bin/env bash
# Real-Herdr E2E for bin/fm-herdr-legacy-repair.sh: a synthetic legacy record
# pointing at a real pane in a guarded named non-default lab session is
# refused while its recorded topology mismatches, repaired exactly once when
# every evidence check agrees, idempotent on rerun, and never mutates the
# pane. Lab teardown's tripwire verifies the default fleet session stayed
# byte-identical throughout.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo 'skip: herdr not found'; exit 0; }
command -v jq >/dev/null 2>&1 || { echo 'skip: jq not found'; exit 0; }
[ -x "$HERDR_LAB_HELPER" ] || { echo "skip: Herdr lab helper not executable at $HERDR_LAB_HELPER"; exit 0; }

REAL_HERDR=$(command -v herdr)
HERDR_ORIGINAL_PATH=$PATH
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-herdr-legacy-repair-e2e.XXXXXX")
FAKEBIN="$TMP_ROOT/fakebin"
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$FAKEBIN" "$HOME_DIR/state"

HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fm-herdr-legacy-repair-e2e)
export HERDR_LAB_HELPER HERDR_LAB_SESSION REAL_HERDR HERDR_ORIGINAL_PATH
cleanup() {
  local status=$?
  env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || status=1
  rm -rf "$TMP_ROOT"
  exit "$status"
}
trap cleanup EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"

# Keep the lab helper as the only CLI transport. Production adapter calls have
# already appended the exact session; this shim strips that pair, refuses every
# other caller-supplied session, and delegates the command to helper run.
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
exec env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"
SH
chmod +x "$FAKEBIN/herdr"
export PATH="$FAKEBIN:$PATH"

# A real landed git triad: origin, project clone, and a clean worktree clone
# sitting on the pushed default branch.
git init -q --bare "$TMP_ROOT/origin.git"
git clone -q "$TMP_ROOT/origin.git" "$TMP_ROOT/project" 2>/dev/null
( cd "$TMP_ROOT/project" \
  && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init \
  && git push -q origin HEAD:main && git checkout -q main ) 2>/dev/null
git clone -q "$TMP_ROOT/origin.git" "$TMP_ROOT/worktree" 2>/dev/null
( cd "$TMP_ROOT/worktree" && git checkout -q main ) 2>/dev/null

ID=legacy-e2e-task
# One real workspace and one real fm-<id> tab whose pane holds an agent-less
# shell at the project cwd - the exact restored-husk shape a legacy record
# points at.
WS_OUT=$(herdr workspace create --cwd "$TMP_ROOT/project" --label fm-e2e-home --no-focus --session "$HERDR_LAB_SESSION")
WSID=$(printf '%s' "$WS_OUT" | jq -r '.result.workspace.workspace_id // empty')
[ -n "$WSID" ] || fail "could not create a lab workspace: $WS_OUT"
TAB_OUT=$(herdr tab create --workspace "$WSID" --cwd "$TMP_ROOT/project" --label "fm-$ID" --no-focus --session "$HERDR_LAB_SESSION")
TABID=$(printf '%s' "$TAB_OUT" | jq -r '.result.tab.tab_id // empty')
PANEID=$(printf '%s' "$TAB_OUT" | jq -r '.result.root_pane.pane_id // empty')
[ -n "$TABID" ] && [ -n "$PANEID" ] || fail "could not create a lab task tab: $TAB_OUT"

write_meta() {  # <tab-id>
  cat > "$HOME_DIR/state/$ID.meta" <<EOF
window=$HERDR_LAB_SESSION:$PANEID
worktree=$TMP_ROOT/worktree
project=$TMP_ROOT/project
harness=claude
kind=ship
mode=no-mistakes
backend=herdr
herdr_session=$HERDR_LAB_SESSION
herdr_workspace_id=$WSID
herdr_tab_id=$1
herdr_pane_id=$PANEID
EOF
}

pane_present() {
  herdr pane get "$PANEID" --session "$HERDR_LAB_SESSION" 2>/dev/null \
    | jq -e --arg pane "$PANEID" '.result.pane.pane_id == $pane' >/dev/null 2>&1
}

run_repair() {
  FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-herdr-legacy-repair.sh" "$ID"
}

# 1. A mismatched recorded tab refuses and mutates nothing.
write_meta "$TABID-wrong"
rc=0
run_repair > "$TMP_ROOT/out1" 2> "$TMP_ROOT/err1" || rc=$?
[ "$rc" -ne 0 ] || fail "mismatched recorded tab was repaired: $(cat "$TMP_ROOT/out1")"
grep -q 'REFUSED' "$TMP_ROOT/err1" || fail "mismatch refusal missing a diagnostic"
grep -q '^endpoint_task_id=' "$HOME_DIR/state/$ID.meta" && fail "mismatch refusal wrote a binding"
pane_present || fail "mismatch refusal disturbed the live pane"
pass "a live-topology mismatch refuses before any change against real Herdr"

# 2. The exact record repairs once, against real live evidence.
write_meta "$TABID"
run_repair > "$TMP_ROOT/out2" 2> "$TMP_ROOT/err2" || fail "provable legacy record refused: $(cat "$TMP_ROOT/err2")"
grep -q '^repaired:' "$TMP_ROOT/out2" || fail "repair outcome missing: $(cat "$TMP_ROOT/out2")"
[ "$(grep -c '^endpoint_task_id=' "$HOME_DIR/state/$ID.meta")" -eq 1 ] \
  || fail "repair did not add exactly one binding"
[ "$(grep '^endpoint_task_id=' "$HOME_DIR/state/$ID.meta")" = "endpoint_task_id=$ID" ] \
  || fail "repair bound the wrong task"
pane_present || fail "repair mutated the live pane"
pass "a fully provable legacy record repairs exactly once against real Herdr evidence"

# 3. Idempotent rerun.
cp "$HOME_DIR/state/$ID.meta" "$TMP_ROOT/meta.repaired"
run_repair > "$TMP_ROOT/out3" 2> "$TMP_ROOT/err3" || fail "idempotent rerun failed: $(cat "$TMP_ROOT/err3")"
grep -q '^already-bound:' "$TMP_ROOT/out3" || fail "rerun did not report already-bound"
cmp -s "$TMP_ROOT/meta.repaired" "$HOME_DIR/state/$ID.meta" || fail "rerun changed the repaired record"
pane_present || fail "rerun disturbed the live pane"
pass "the repair reruns as a no-op with the pane untouched"

printf 'all fm-herdr-legacy-repair-e2e tests passed\n'
