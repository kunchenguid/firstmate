#!/usr/bin/env bash
# tests/fm-remote-secondmate-omp.test.sh - an omp remote secondmate passes every
# gate that decides remote placement and retires cleanly:
#
#   A) bin/fm-remote-secondmate-control.sh launch accepts omp and drives the
#      ordinary host-local secondmate spawn onto the Herdr fm-remote session,
#      recording harness=omp and the pinned model in the endpoint metadata.
#   B) The relaunch verb accepts omp and reaches the ordinary control plane's own
#      pre-stop checkpoint, proving its harness gate passed.
#   C) bin/fm-spawn.sh's parent-side remote secondmate gate accepts omp and
#      proceeds to the remote transport hop.
#   D) Host-local retirement succeeds even though the busy records omp arms live
#      in the route state inside the home that retirement removes.
#
# The Herdr endpoint is the stateful fixture in tests/remote-herdr-fixture.sh
# and omp is a fake that answers `models --json`, so no vendor tool is needed;
# tests/fm-omp-harness.test.sh owns the omp launch contract itself.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/remote-herdr-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/remote-herdr-fixture.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-remote-secondmate-omp)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
BASE_PATH=/usr/bin:/bin:/usr/sbin:/sbin

FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
install_remote_herdr_fixture "$FAKEBIN-root" "$TMP_ROOT/herdr.state" "$TMP_ROOT/herdr.log" \
  "$TMP_ROOT/herdr-send-fail" "$TMP_ROOT/herdr.sock"
mv "$FAKEBIN-root/bin/herdr" "$FAKEBIN/herdr"
rmdir "$FAKEBIN-root/bin" "$FAKEBIN-root"
ln -sf "$(command -v git)" "$FAKEBIN/git"
ln -sf "$(command -v jq)" "$FAKEBIN/jq"
ln -sf "$(command -v node)" "$FAKEBIN/node"
cat > "$FAKEBIN/omp" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" != models ] || printf '%s\n' '{"models":[{"provider":"anthropic","id":"claude-test","selector":"anthropic/claude-test"}]}'
exit 0
SH
chmod +x "$FAKEBIN/omp"

SSH_LOG="$TMP_ROOT/ssh-hops.log"
cat > "$FAKEBIN/fake-ssh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$SSH_LOG"
exit 255
SH
chmod +x "$FAKEBIN/fake-ssh"

ID=sm-omp
HOME_DIR="$TMP_ROOT/home-$ID"
mkdir -p "$HOME_DIR/bin" "$HOME_DIR/data"
printf '# Firstmate\n' > "$HOME_DIR/AGENTS.md"
printf '%s\n' "$ID" > "$HOME_DIR/.fm-secondmate-home"
printf '# Charter\n\nStand by until steering arrives.\n' > "$HOME_DIR/data/charter.md"
git -C "$HOME_DIR" init -q

ctl() {
  PATH="$FAKEBIN:$BASE_PATH" TMUX='' FM_GATE_REFUSE_BYPASS=1 FM_SPAWN_NO_GUARD=1 \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
    "$ROOT/bin/fm-remote-secondmate-control.sh" "$@"
}

# --- A) host-local launch -----------------------------------------------------

ctl launch "$ID" omp anthropic/claude-test high herdr > "$TMP_ROOT/launch.out" 2> "$TMP_ROOT/launch.err"
expect_code 0 "$?" "host-local remote secondmate launch on omp failed"$'\n'"$(cat "$TMP_ROOT/launch.err")"
assert_grep 'harness=omp' "$TMP_ROOT/launch.out" "the printed route lost the omp harness"
assert_grep 'target=fm-remote:' "$TMP_ROOT/launch.out" "the omp endpoint target is outside fm-remote"
META="$HOME_DIR/state/parent-route/$ID.meta"
assert_grep 'harness=omp' "$META" "endpoint metadata did not record the omp harness"
assert_grep 'model=anthropic/claude-test' "$META" "endpoint metadata lost the pinned omp model"
assert_grep 'effort=high' "$META" "endpoint metadata lost the pinned omp effort"
assert_grep 'herdr_session=fm-remote' "$META" "endpoint metadata did not record the fm-remote session"
[ "$(ctl state "$ID")" = alive ] || fail "the omp endpoint did not read alive from its host-local route"
pass "A host-local launch accepts omp and records the fm-remote Herdr endpoint"

# --- B) host-local relaunch ---------------------------------------------------

cp "$META" "$TMP_ROOT/meta-before-relaunch"
mkdir -p "$TMP_ROOT/not-a-checkout"
sed "s|^worktree=.*|worktree=$TMP_ROOT/not-a-checkout|" "$TMP_ROOT/meta-before-relaunch" > "$META"
if ctl relaunch "$ID" omp - - > "$TMP_ROOT/relaunch.out" 2>&1; then
  fail "relaunch with an unaccountable checkout should refuse in the control plane"
fi
assert_grep 'refusing to relaunch without a checkout whose unlanded work can be accounted for' \
  "$TMP_ROOT/relaunch.out" "an omp relaunch did not reach the control plane's own pre-stop checkpoint"
cp "$TMP_ROOT/meta-before-relaunch" "$META"
pass "B host-local relaunch accepts omp and reaches the control plane"

# --- C) parent-side remote spawn ----------------------------------------------

PARENT="$TMP_ROOT/parent"
mkdir -p "$PARENT/data" "$PARENT/state" "$PARENT/config" "$PARENT/projects"
cat > "$PARENT/data/secondmates.md" <<EOF
- $ID - Remote omp mate (host: remote-host; root: $ROOT; home: $HOME_DIR; scope: remote omp verification; projects: none; added 2026-10-28)
EOF
PATH="$FAKEBIN:$BASE_PATH" TMUX='' FM_GATE_REFUSE_BYPASS=1 FM_SPAWN_NO_GUARD=1 \
  FM_HOME="$PARENT" FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$PARENT/state" FM_DATA_OVERRIDE="$PARENT/data" \
  FM_PROJECTS_OVERRIDE="$PARENT/projects" FM_CONFIG_OVERRIDE="$PARENT/config" \
  FM_SSH_BIN="$FAKEBIN/fake-ssh" HOME="$TMP_ROOT/parent-user-home" \
  "$ROOT/bin/fm-spawn.sh" "$ID" --secondmate --harness omp > "$TMP_ROOT/spawn.out" 2> "$TMP_ROOT/spawn.err" \
  && fail "the parent-side spawn should surface the unreachable remote transport"
assert_grep 'readiness could not be confirmed; preserved route' "$TMP_ROOT/spawn.err" \
  "the omp remote spawn did not pass the harness gate to the transport hop"$'\n'"$(cat "$TMP_ROOT/spawn.err")"
[ -s "$SSH_LOG" ] || fail "the omp remote spawn never reached the remote transport hop"
pass "C the parent-side remote spawn gate accepts omp"

# --- D) host-local retirement -------------------------------------------------

# omp arms the busy contract, so its busy records live in the route state inside
# the home that retirement removes.
[ -f "$HOME_DIR/state/parent-route/$ID.busy-gen" ] || fail "the omp launch armed no busy generation to retire"
ctl retire "$ID" > "$TMP_ROOT/retire.out" 2>&1
expect_code 0 "$?" "host-local retirement of an omp mate failed"$'\n'"$(cat "$TMP_ROOT/retire.out")"
assert_absent "$HOME_DIR" "retirement left the omp mate's home behind"
pass "D host-local retirement removes an omp mate's home and succeeds"

echo "ALL TESTS PASSED"
