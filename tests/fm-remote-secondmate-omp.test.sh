#!/usr/bin/env bash
# tests/fm-remote-secondmate-omp.test.sh - omp (Oh My Pi) is a VERIFIED remote
# secondmate harness on every gate that decides remote placement:
#
#   A) Host-local launch. bin/fm-remote-secondmate-control.sh launch accepts omp
#      and drives the ordinary host-local secondmate spawn onto the Herdr
#      fm-remote session, recording harness=omp in both the printed route and
#      the endpoint metadata. Before omp was verified this verb died with
#      "unverified remote secondmate harness: omp".
#   B) Host-local relaunch. The relaunch verb accepts omp and reaches the
#      ORDINARY control plane's own pre-stop checkpoint (an unaccountable
#      checkout refuses there), proving the harness gate passed; an unverified
#      harness still dies at the verb's own gate.
#   C) Parent-side ordinary remote spawn. bin/fm-spawn.sh's remote secondmate
#      validation accepts an explicit --harness omp and proceeds to the remote
#      transport hop; an unverified harness is refused BEFORE any ssh hop with
#      "requires a verified harness adapter".
#
# The Herdr endpoint is the repo's stateful fake (tests/remote-herdr-fixture.sh)
# and omp is a fake that answers `models --json`, so the launch contracts run
# with no vendor tools installed; the vendor-behavior contracts themselves are
# owned by tests/fm-omp-harness.test.sh and the opt-in live guards.
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

# The stateful fake Herdr CLI plus a fake omp, a counting fake ssh, and the real
# git/jq/node the spawn needs. Nothing here touches the runner's own sessions.
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
case "$1" in
  models)
    printf '%s\n' '{"models":[{"provider":"openai-codex","id":"gpt-6-astra","selector":"openai-codex/gpt-6-astra"}]}'
    ;;
esac
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

# A seeded secondmate home: the identity marker, AGENTS.md, bin/, and a charter
# (the launch brief a secondmate receives).
ID=sm-omp
HOME_DIR="$TMP_ROOT/home-$ID"
mkdir -p "$HOME_DIR/bin" "$HOME_DIR/data"
printf '# Firstmate\n' > "$HOME_DIR/AGENTS.md"
printf '%s\n' "$ID" > "$HOME_DIR/.fm-secondmate-home"
printf '# Charter\n\nStand by until steering arrives.\n' > "$HOME_DIR/data/charter.md"

ctl() { # <args...> -> runs the real control script host-locally
  PATH="$FAKEBIN:$BASE_PATH" TMUX='' \
    FM_GATE_REFUSE_BYPASS=1 FM_SPAWN_NO_GUARD=1 \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
    "$ROOT/bin/fm-remote-secondmate-control.sh" "$@"
}

# --- A) host-local launch accepts omp ----------------------------------------

LAUNCH_OUT="$TMP_ROOT/launch.out"
LAUNCH_ERR="$TMP_ROOT/launch.err"
ctl launch "$ID" omp openai-codex/gpt-6-astra - herdr > "$LAUNCH_OUT" 2> "$LAUNCH_ERR"
expect_code 0 "$?" "host-local remote-secondmate launch on omp failed"$'\n'"$(cat "$LAUNCH_ERR")"
assert_contains "$(cat "$LAUNCH_OUT")" 'backend=herdr' \
  "the omp launch did not report the herdr backend"
assert_contains "$(cat "$LAUNCH_OUT")" 'herdr_session=fm-remote' \
  "the omp launch did not report the dedicated fm-remote session"
assert_contains "$(cat "$LAUNCH_OUT")" 'harness=omp' \
  "the printed route lost the omp harness"
assert_grep 'target=fm-remote:' "$LAUNCH_OUT" "the omp endpoint target is outside fm-remote"
META="$HOME_DIR/state/parent-route/$ID.meta"
assert_grep 'harness=omp' "$META" "endpoint metadata did not record the omp harness"
assert_grep 'model=openai-codex/gpt-6-astra' "$META" \
  "endpoint metadata did not thread the pinned model through the omp launch"
assert_grep 'backend=herdr' "$META" "endpoint metadata did not record the herdr backend"
assert_grep 'herdr_session=fm-remote' "$META" \
  "endpoint metadata did not record the fm-remote session"
assert_grep 'session fm-remote' "$TMP_ROOT/herdr.log" \
  "the launch did not address the fm-remote Herdr session"
assert_no_grep 'session default' "$TMP_ROOT/herdr.log" \
  "the omp launch touched the interactive default session"
[ "$(PATH="$FAKEBIN:$BASE_PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
     "$ROOT/bin/fm-remote-secondmate-control.sh" state "$ID")" = alive ] \
  || fail "the omp endpoint did not project alive from its host-local route"
pass "A1 host-local launch accepts omp and records the fm-remote Herdr endpoint"

# --- B) relaunch accepts omp; unverified harnesses still refuse --------------

cp "$META" "$TMP_ROOT/meta-before-relaunch-gate"
mkdir -p "$TMP_ROOT/not-a-checkout"
sed "s|^worktree=.*|worktree=$TMP_ROOT/not-a-checkout|" "$TMP_ROOT/meta-before-relaunch-gate" > "$META"
RELAUNCH_OUT="$TMP_ROOT/relaunch-omp.out"
if ctl relaunch "$ID" omp - - > "$RELAUNCH_OUT" 2>&1; then
  fail "relaunch with an unaccountable checkout should refuse in the control plane"
fi
assert_contains "$(cat "$RELAUNCH_OUT")" 'refusing to relaunch without a checkout whose unlanded work can be accounted for' \
  "an omp relaunch did not reach the control plane's own pre-stop checkpoint"
REL_BOGUS="$TMP_ROOT/relaunch-bogus.out"
if ctl relaunch "$ID" notaharness - - > "$REL_BOGUS" 2>&1; then
  fail "an unverified harness should refuse a remote restart"
fi
assert_contains "$(cat "$REL_BOGUS")" 'unverified remote secondmate harness' \
  "the relaunch verb's unverified-harness guard did not fire"
cp "$TMP_ROOT/meta-before-relaunch-gate" "$META"
pass "B1 relaunch accepts omp and reaches the control plane; unverified harnesses still refuse"

# --- refusals the omp addition must not weaken --------------------------------

REF_OUT="$TMP_ROOT/launch-bogus.out"
if ctl launch "$ID" notaharness - - herdr > "$REF_OUT" 2>&1; then
  fail "an unverified harness should refuse a host-local launch"
fi
assert_contains "$(cat "$REF_OUT")" 'unverified remote secondmate harness: notaharness' \
  "the launch verb's unverified-harness guard did not name the rejected harness"
EFF_OUT="$TMP_ROOT/launch-bad-effort.out"
if ctl launch "$ID" omp - bogus herdr > "$EFF_OUT" 2>&1; then
  fail "an invalid effort should refuse a host-local launch"
fi
assert_contains "$(cat "$EFF_OUT")" 'invalid remote secondmate effort: bogus' \
  "the launch verb accepted an invalid effort for omp"
pass "B2 the unverified-harness and effort guards hold after the omp addition"

# --- C) parent-side remote spawn validation -----------------------------------

PARENT="$TMP_ROOT/parent"
mkdir -p "$PARENT/data" "$PARENT/state" "$PARENT/config" "$PARENT/projects"
cat > "$PARENT/data/secondmates.md" <<EOF
- $ID - Remote omp mate (host: remote-mac; root: $ROOT; home: $HOME_DIR; scope: remote omp verification; projects: none; added 2026-09-17)
EOF
: > "$SSH_LOG"
SPAWN_OUT="$TMP_ROOT/spawn-omp.out"
SPAWN_ERR="$TMP_ROOT/spawn-omp.err"
PATH="$FAKEBIN:$BASE_PATH" TMUX='' \
  FM_GATE_REFUSE_BYPASS=1 FM_SPAWN_NO_GUARD=1 \
  FM_HOME="$PARENT" FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$PARENT/state" FM_DATA_OVERRIDE="$PARENT/data" \
  FM_PROJECTS_OVERRIDE="$PARENT/projects" FM_CONFIG_OVERRIDE="$PARENT/config" \
  FM_SSH_BIN="$FAKEBIN/fake-ssh" HOME="$TMP_ROOT/parent-user-home" \
  "$ROOT/bin/fm-spawn.sh" "$ID" --secondmate --harness omp > "$SPAWN_OUT" 2> "$SPAWN_ERR"
SPAWN_RC=$?
[ "$SPAWN_RC" -ne 0 ] || fail "the parent-side spawn should surface the unreachable remote transport"
assert_contains "$(cat "$SPAWN_ERR")" 'readiness could not be confirmed; preserved route' \
  "the omp remote spawn did not proceed past the harness gate to the transport hop"$'\n'"$(cat "$SPAWN_ERR")"
[ -s "$SSH_LOG" ] || fail "the omp remote spawn never reached the remote transport hop"
HOPS_OMP=$(wc -l < "$SSH_LOG" | tr -d ' ')

: > "$SSH_LOG"
PATH="$FAKEBIN:$BASE_PATH" TMUX='' \
  FM_GATE_REFUSE_BYPASS=1 FM_SPAWN_NO_GUARD=1 \
  FM_HOME="$PARENT" FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$PARENT/state" FM_DATA_OVERRIDE="$PARENT/data" \
  FM_PROJECTS_OVERRIDE="$PARENT/projects" FM_CONFIG_OVERRIDE="$PARENT/config" \
  FM_SSH_BIN="$FAKEBIN/fake-ssh" HOME="$TMP_ROOT/parent-user-home" \
  "$ROOT/bin/fm-spawn.sh" "$ID" --secondmate --harness notaharness > "$TMP_ROOT/spawn-bogus.out" 2> "$TMP_ROOT/spawn-bogus.err"
SPAWN_BOGUS_RC=$?
expect_code 1 "$SPAWN_BOGUS_RC" "an unverified harness should fail the parent-side spawn with the gate refusal"
assert_contains "$(cat "$TMP_ROOT/spawn-bogus.err")" 'requires a verified harness adapter, not a raw launch command: notaharness' \
  "the parent-side gate did not name the rejected harness"
[ "$(wc -l < "$SSH_LOG" | tr -d ' ')" -eq 0 ] \
  || fail "an unverified harness reached the remote transport before the gate refused"
[ "$HOPS_OMP" -ge 1 ] || fail "the omp leg recorded no transport hops ($HOPS_OMP)"
pass "C1 the parent-side remote spawn gate accepts omp and still refuses unverified harnesses before any hop"

echo "ALL TESTS PASSED"
