#!/usr/bin/env bash
# Isolated real-Herdr acceptance for host-root spawn, completion, decision inventory, and teardown.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-herdr-host-root-e2e.XXXXXX")
SESSION="fm-lab-host-root-e2e-$$"
ID=host-root-e2e
WT=
EVIDENCE_FILE=

if [ -n "${FM_TEST_EVIDENCE_DIR:-}" ]; then
  mkdir -p "$FM_TEST_EVIDENCE_DIR"
  EVIDENCE_FILE="$FM_TEST_EVIDENCE_DIR/native-herdr-host-root-e2e.txt"
fi

cleanup() {
  [ -z "$WT" ] || treehouse return --force "$WT" >/dev/null 2>&1 || true
  herdr_safe_stop_and_delete "$SESSION" >/dev/null 2>&1 || true
  rm -rf "$TMP_ROOT"
}
fail() {
  printf 'not ok - %s\n' "$1" >&2
  cleanup
  exit 1
}
assert_line() {
  grep -Fx -- "$2" "$1" >/dev/null 2>&1 || fail "$3"
}

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v treehouse >/dev/null 2>&1 || { echo "skip: treehouse not found"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane
export HERDR_SESSION="$SESSION"
export FM_HERDR_LAB_STATE_DIR="$TMP_ROOT/lab-state"
trap cleanup EXIT
fm_herdr_lab_prepare "$SESSION" || fail "could not prepare isolated Herdr lab"

make_repo() {
  local dir=$1
  shift
  mkdir -p "$dir"
  git -C "$dir" init -q
  "$@" "$dir"
  git -C "$dir" add .
  git -C "$dir" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  git clone -q --bare "$dir" "$dir.origin.git"
  git -C "$dir" remote add origin "$dir.origin.git"
}
make_host() {
  printf 'host instructions\n' > "$1/AGENTS.md"
}
make_target() {
  printf 'target instructions\n' > "$1/AGENTS.md"
  printf 'target\n' > "$1/README.md"
}

HOST="$TMP_ROOT/host"
PROJECT="$TMP_ROOT/target"
HOME_ROOT="$TMP_ROOT/home"
FAKEBIN="$TMP_ROOT/fakebin"
OBS="$HOME_ROOT/worker-observation"
make_repo "$HOST" make_host
make_repo "$PROJECT" make_target
mkdir -p "$HOME_ROOT/data" "$HOME_ROOT/state" "$HOME_ROOT/config" "$FAKEBIN"

cat > "$FAKEBIN/codex" <<'SH'
#!/usr/bin/env bash
set -u
{
  printf 'cwd=%s\n' "$(pwd -P)"
  printf 'host=%s\n' "$FM_HOST_ROOT"
  printf 'target=%s\n' "$FM_TARGET_WORKTREE"
  target_top=$(git rev-parse --show-toplevel)
  printf 'target_top=%s\n' "$(cd "$target_top" && pwd -P)"
  printf 'target_instructions=%s\n' "$(cat ./AGENTS.md)"
} > "$FM_HOME/worker-observation"
printf 'worker edit\n' > "$FM_TARGET_WORKTREE/worker-edit.txt"
mkdir -p "$FM_HOME/data/host-root-e2e"
printf '# Real Herdr host-root report\n' > "$FM_HOME/data/host-root-e2e/report.md"
printf 'done: real Herdr host-root worker completed\n' >> "$FM_HOME/state/host-root-e2e.status"
touch "$FM_HOME/state/host-root-e2e.turn-ended"
SH
chmod +x "$FAKEBIN/codex"

(cd "$HOST" && FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_ROOT" FM_HOST_ROOT="$HOST" \
  "$ROOT/bin/fm-brief.sh" "$ID" "$(basename "$PROJECT")" --scout >/dev/null) \
  || fail "could not create host-root brief"

SPAWN_OUT="$TMP_ROOT/spawn.out"
(cd "$HOST" && PATH="$FAKEBIN:$PATH" FM_SPAWN_NO_GUARD=1 \
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_ROOT" FM_HOST_ROOT="$HOST" \
  "$ROOT/bin/fm-spawn.sh" "$ID" "$PROJECT" --harness codex --backend herdr --scout \
  > "$SPAWN_OUT" 2>&1) || fail "real Herdr host-root spawn failed: $(cat "$SPAWN_OUT")"

for _ in $(seq 1 100); do
  [ -s "$OBS" ] && [ -e "$HOME_ROOT/state/$ID.turn-ended" ] && break
  sleep 0.1
done
[ -s "$OBS" ] || fail "worker did not publish host-root observations"
[ -e "$HOME_ROOT/state/$ID.turn-ended" ] || fail "worker completion lifecycle signal was absent"
assert_line "$HOME_ROOT/state/$ID.status" "done: real Herdr host-root worker completed" \
  "worker completion status signal was absent"

META="$HOME_ROOT/state/$ID.meta"
[ -f "$META" ] || fail "spawn did not publish task metadata"
WT=$(sed -n 's/^worktree=//p' "$META")
PANE=$(sed -n 's/^herdr_pane_id=//p' "$META")
[ -n "$WT" ] && [ -d "$WT" ] || fail "spawn did not retain an isolated target worktree"
[ -n "$PANE" ] || fail "spawn did not record the Herdr pane"
HOST_REAL=$(cd "$HOST" && pwd -P)
WT_REAL=$(cd "$WT" && pwd -P)
assert_line "$OBS" "cwd=$WT_REAL" "worker cwd was not the isolated target worktree"
assert_line "$OBS" "host=$HOST_REAL" "worker FM_HOST_ROOT was incorrect"
assert_line "$OBS" "target=$WT_REAL" "worker FM_TARGET_WORKTREE was incorrect"
assert_line "$OBS" "target_top=$WT_REAL" "worker target was not the isolated Git root"
assert_line "$OBS" "target_instructions=target instructions" "worker did not load target instructions from its cwd"
assert_line "$META" "backend=herdr" "metadata did not retain the Herdr backend"
assert_line "$META" "host_root=$HOST_REAL" "metadata did not retain host authority"
[ -z "$(git -C "$HOST" status --short)" ] || fail "worker changed the host repository"
[ -z "$(git -C "$PROJECT" status --short)" ] || fail "worker changed the target primary checkout"
[ -f "$WT/worker-edit.txt" ] || fail "worker edit did not stay in the target worktree"
[ ! -e "$HOME_ROOT/state/$ID.herdr-launch.sh" ] || fail "native Windows Herdr launcher did not delete itself"
if [ -n "$EVIDENCE_FILE" ]; then
  {
    printf 'Native Herdr host-root worker observation\n'
    cat "$OBS"
    printf 'completion=%s\n' "$(tail -n 1 "$HOME_ROOT/state/$ID.status")"
    printf 'backend=%s\n' "$(sed -n 's/^backend=//p' "$META")"
    printf 'host_checkout_clean=%s\n' "$(test -z "$(git -C "$HOST" status --short)" && echo yes || echo no)"
    printf 'target_primary_clean=%s\n' "$(test -z "$(git -C "$PROJECT" status --short)" && echo yes || echo no)"
    printf 'worker_edit_in_isolated_worktree=yes\n'
    printf 'native_windows_launcher_self_deleted=yes\n'
  } > "$EVIDENCE_FILE"
fi
STATE_OUT=$(cd "$HOST" && FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_ROOT" FM_HOST_ROOT="$HOST_REAL" \
  "$ROOT/bin/fm-crew-state.sh" "$ID")
[ "$STATE_OUT" = "state: unknown · source: pane · harness state unavailable (unknown codex-unverified)" ] \
  || fail "Codex completion signal bypassed semantic busy-state uncertainty: $STATE_OUT"

(cd "$HOST" && PATH="$FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_ROOT" FM_HOST_ROOT="$HOST_REAL" \
  "$ROOT/bin/fm-decision-hold.sh" complete "$ID" --none >/dev/null) \
  || fail "real Herdr host-root decision inventory failed"

TEARDOWN_OUT="$TMP_ROOT/teardown.out"
(cd "$HOST" && FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_ROOT" FM_HOST_ROOT="$HOST_REAL" \
  "$ROOT/bin/fm-teardown.sh" "$ID" > "$TEARDOWN_OUT" 2>&1) \
  || fail "real Herdr host-root teardown failed: $(cat "$TEARDOWN_OUT")"
[ ! -e "$META" ] || fail "teardown retained task metadata"
[ ! -f "$WT/worker-edit.txt" ] || fail "teardown retained target edits"
TREEHOUSE_OUT=$(cd "$PROJECT" && treehouse status 2>/dev/null)
printf '%s\n' "$TREEHOUSE_OUT" | awk '$2 == "available" { found = 1 } END { exit !found }' \
  || fail "teardown did not return the target worktree: $TREEHOUSE_OUT"
if herdr pane get "$PANE" --session "$SESSION" >/dev/null 2>&1; then
  fail "teardown retained the Herdr pane"
fi
if [ -n "$EVIDENCE_FILE" ]; then
  {
    printf 'metadata_after_teardown=absent\n'
    printf 'worker_edit_after_teardown=absent\n'
    printf 'herdr_pane_after_teardown=absent\n'
    printf 'treehouse_worktree_available_after_teardown=yes\n'
  } >> "$EVIDENCE_FILE"
fi
WT=
[ -z "$(git -C "$HOST" status --short)" ] || fail "teardown changed the host repository"
[ -z "$(git -C "$PROJECT" status --short)" ] || fail "teardown changed the target primary checkout"

herdr_safe_stop_and_delete "$SESSION" >/dev/null || fail "isolated Herdr lab teardown failed"
trap - EXIT
rm -rf "$TMP_ROOT"
printf 'ok - real Herdr host-root spawn, completion, decision inventory, and teardown\n'
