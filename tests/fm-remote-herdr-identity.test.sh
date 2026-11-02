#!/usr/bin/env bash
# tests/fm-remote-herdr-identity.test.sh - a second Firstmate code root on one
# remote account launches its remote second mates into its own Herdr session,
# the same session bin/fm-remote-doctor.sh prepares for it, never into the
# primary root's shared fm-remote service.
#
#   A) With the account's primary service owned by another root, the real
#      host-local launch records, routes, and reads its endpoint in
#      fm-remote-<root-id>, where <root-id> is the first 16 hex digits of the
#      SHA-256 of the code root path (docs/remote-secondmates.md).
#   B) That root refuses an endpoint recorded in the primary fm-remote session.
#   C) The owning root keeps the primary fm-remote session.
#   D) The parent accepts exactly the session names a remote host can report.
#
# The Herdr endpoint is the stateful fixture in tests/remote-herdr-fixture.sh,
# and omp is a fake that answers `models --json`, so no vendor tool is needed.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/remote-herdr-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/remote-herdr-fixture.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-remote-herdr-identity)
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

seed_home() { # <id> -> prints the seeded secondmate home
  local id=$1 home="$TMP_ROOT/home-$1"
  mkdir -p "$home/bin" "$home/data"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  printf '# Charter\n\nStand by until steering arrives.\n' > "$home/data/charter.md"
  git -C "$home" init -q
  printf '%s\n' "$home"
}

ctl() { # <account-home> <secondmate-home> <control-args...>
  local account=$1 home=$2
  shift 2
  PATH="$FAKEBIN:$BASE_PATH" TMUX='' FM_GATE_REFUSE_BYPASS=1 FM_SPAWN_NO_GUARD=1 \
    HOME="$account" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    "$ROOT/bin/fm-remote-secondmate-control.sh" "$@"
}

ROOT_ID=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.argv[1].encode()).hexdigest()[:16])' "$ROOT")
SECOND_SESSION="fm-remote-$ROOT_ID"

# --- A) a second root launches into its own session ---------------------------

SHARED_ACCOUNT="$TMP_ROOT/shared-account"
mkdir -p "$SHARED_ACCOUNT/.firstmate"
printf '%s\n' "$TMP_ROOT/primary-root" > "$SHARED_ACCOUNT/.firstmate/remote-herdr-owner"
ID=sm-second
HOME_DIR=$(seed_home "$ID")
ctl "$SHARED_ACCOUNT" "$HOME_DIR" launch "$ID" omp anthropic/claude-test high herdr \
  > "$TMP_ROOT/launch.out" 2> "$TMP_ROOT/launch.err"
expect_code 0 "$?" "a second root's host-local launch failed"$'\n'"$(cat "$TMP_ROOT/launch.err")"
META="$HOME_DIR/state/parent-route/$ID.meta"
[ "$(sed -n 's/^herdr_session=//p' "$TMP_ROOT/launch.out")" = "$SECOND_SESSION" ] \
  || fail "the second root's route did not report its own session $SECOND_SESSION"$'\n'"$(cat "$TMP_ROOT/launch.out")"
case "$(sed -n 's/^target=//p' "$TMP_ROOT/launch.out")" in
  "$SECOND_SESSION":?*) ;;
  *) fail "the second root's endpoint target is outside $SECOND_SESSION" ;;
esac
[ "$(sed -n 's/^herdr_session=//p' "$META")" = "$SECOND_SESSION" ] \
  || fail "the second root's endpoint metadata entered another session"
[ "$(ctl "$SHARED_ACCOUNT" "$HOME_DIR" state "$ID")" = alive ] \
  || fail "the second root's endpoint did not read alive through its own session"
pass "A a second code root launches, routes, and reads its mate in its own Herdr session"

# --- B) that root refuses an endpoint in the primary session ------------------

cp "$META" "$TMP_ROOT/meta.own"
sed -e "s|^herdr_session=.*|herdr_session=fm-remote|" \
  -e "s|^window=$SECOND_SESSION:|window=fm-remote:|" "$TMP_ROOT/meta.own" > "$META"
if ctl "$SHARED_ACCOUNT" "$HOME_DIR" route "$ID" > "$TMP_ROOT/route.out" 2>&1; then
  fail "a second root accepted an endpoint in the primary fm-remote session"
fi
assert_grep "expected '$SECOND_SESSION'" "$TMP_ROOT/route.out" \
  "the refusal did not name the second root's own session"$'\n'"$(cat "$TMP_ROOT/route.out")"
cp "$TMP_ROOT/meta.own" "$META"
pass "B a second code root refuses an endpoint in the primary session"

# --- C) the owning root keeps fm-remote ----------------------------------------

OWNER_ACCOUNT="$TMP_ROOT/owner-account"
mkdir -p "$OWNER_ACCOUNT/.firstmate"
printf '%s\n' "$ROOT" > "$OWNER_ACCOUNT/.firstmate/remote-herdr-owner"
OWNER_ID=sm-owner
OWNER_HOME=$(seed_home "$OWNER_ID")
ctl "$OWNER_ACCOUNT" "$OWNER_HOME" launch "$OWNER_ID" omp anthropic/claude-test high herdr \
  > "$TMP_ROOT/owner-launch.out" 2> "$TMP_ROOT/owner-launch.err"
expect_code 0 "$?" "the owning root's host-local launch failed"$'\n'"$(cat "$TMP_ROOT/owner-launch.err")"
[ "$(sed -n 's/^herdr_session=//p' "$TMP_ROOT/owner-launch.out")" = fm-remote ] \
  || fail "the owning root left the primary fm-remote session"
pass "C the owning code root keeps the primary fm-remote session"

# --- D) the parent's accepted session names ------------------------------------

session_valid() {
  bash -c '. "$1/bin/fm-remote-herdr-identity-lib.sh"; fm_remote_herdr_session_name_valid "$2"' _ "$ROOT" "$1"
}
session_valid fm-remote || fail "the parent refused the primary fm-remote session"
session_valid "$SECOND_SESSION" || fail "the parent refused a code-root-derived session"
for bad in default fm-remote- "fm-remote-${ROOT_ID:0:15}" "fm-remote-${ROOT_ID}0" fm-remote-0123456789ABCDEF "x$SECOND_SESSION"; do
  if session_valid "$bad"; then fail "the parent accepted foreign Herdr session '$bad'"; fi
done
pass "D the parent accepts only the primary or a code-root-derived session"

echo "ALL TESTS PASSED"
