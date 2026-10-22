#!/usr/bin/env bash
# tests/fm-remote-doctor-rex.test.sh - bin/fm-remote-doctor.sh --backend rex:
# a remote second mate on Rex needs the rex CLI (on PATH or in the app bundle)
# and a running Rex server that passes the adapter's version gate, and never
# the Herdr launch agent or server. Firstmate never starts a Rex server, so a
# missing or too-old one is a human gap. A fake rex CLI stands in for the app.
set -u

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (the rex adapter parses its JSON)"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-remote-doctor-rex)
trap 'fm_test_cleanup || true' EXIT
TOOLS="$TMP_ROOT/tools"
mkdir -p "$TOOLS"
for tool in git jq; do ln -sf "$(command -v "$tool")" "$TOOLS/$tool"; done
BASE_PATH="$TOOLS:/usr/bin:/bin:/usr/sbin:/sbin"

# fake_rex <dir> <api-revision|down>: a rex CLI whose default server answers
# with <api-revision>, or no server at all.
fake_rex() {
  mkdir -p "$1"
  cat >"$1/rex" <<SH
#!/usr/bin/env bash
[ "$2" != down ] || exit 4
while [ "\$#" -gt 0 ]; do
  case "\$1" in -S) shift 2 ;; --autostart=*) shift ;; *) break ;; esac
done
case "\$1 \${2:-}" in
  'server status') printf '{"endpoint":"unix:///fake/rex.sock","api_revision":$2,"instance_id":"inst-1"}\n' ;;
  'api list') printf '%s\n' block.close session.new_window session.set_block_label com.superlogical.terminal.process com.superlogical.terminal.format ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$1/rex"
}

doctor() { # <path-prefix> <bundle-bin> <args...>
  local prefix=$1 bundle=$2
  shift 2
  set +e
  DOCTOR_OUT=$(
    env -u REX_SESSION -u REX_BLOCK -u REX_CLIENT -u REX_SERVER -u REX_BIN_DIR -u FM_REX_SERVER \
      HOME="$TMP_ROOT/home" FM_HOME="$TMP_ROOT/home" PATH="$prefix:$BASE_PATH" \
      FM_BACKEND_REX_BUNDLE_BIN="$bundle" FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux FM_REMOTE_JOB_ACTIVE=1 \
      "$ROOT/bin/fm-remote-doctor.sh" "$@" 2>&1
  )
  DOCTOR_RC=$?
  set -e
}
mkdir -p "$TMP_ROOT/home"

fake_rex "$TMP_ROOT/path-rex" 5
doctor "$TMP_ROOT/path-rex" /nonexistent --backend rex
assert_contains "$DOCTOR_OUT" "check rex=ok: $TMP_ROOT/path-rex/rex" "a rex CLI on PATH was not detected"
assert_contains "$DOCTOR_OUT" 'check rex-server=ok: unix:///fake/rex.sock' "a running API 5 server was not accepted"
assert_contains "$DOCTOR_OUT" "required rex=$TMP_ROOT/path-rex/rex" "rex was not reported as a required tool"
assert_not_contains "$DOCTOR_OUT" 'check herdr' "the rex backend must not check Herdr"
assert_not_contains "$DOCTOR_OUT" 'check launchagent' "the rex backend must not check the Herdr launch agent"
assert_not_contains "$DOCTOR_OUT" 'required herdr' "the rex backend must not require herdr"
pass "doctor --backend rex accepts a rex CLI on PATH and a server at API revision 5, with no Herdr checks"

fake_rex "$TMP_ROOT/bundle" 5
doctor "$TMP_ROOT/empty" "$TMP_ROOT/bundle/rex" --backend rex
assert_contains "$DOCTOR_OUT" "check rex=ok: $TMP_ROOT/bundle/rex" "the app bundle's rex CLI was not found off PATH"
assert_contains "$DOCTOR_OUT" "required rex=$TMP_ROOT/bundle/rex" "the bundle rex was not reported as the required tool"
pass "doctor --backend rex finds the rex CLI inside the app bundle when PATH lacks it"

fake_rex "$TMP_ROOT/old-rex" 3
doctor "$TMP_ROOT/old-rex" /nonexistent --backend rex
assert_contains "$DOCTOR_OUT" 'check rex-server=human:' "a server below the API floor was not a human gap"
[ "$DOCTOR_RC" -ne 0 ] || fail "a too-old Rex server was reported ready"

fake_rex "$TMP_ROOT/down-rex" down
doctor "$TMP_ROOT/down-rex" /nonexistent --fix --backend rex
assert_contains "$DOCTOR_OUT" 'check rex-server=human:' "a missing Rex server was not a human gap"
assert_contains "$DOCTOR_OUT" 'Firstmate never starts a Rex server' "the gap should say Firstmate never starts the server"
assert_not_contains "$DOCTOR_OUT" 'fix rex-server' "--fix must never try to start a Rex server"

doctor "$TMP_ROOT/empty" /nonexistent --backend rex
assert_contains "$DOCTOR_OUT" 'check rex=human:' "a missing rex CLI was not a human gap"
assert_contains "$DOCTOR_OUT" 'required rex=MISSING' "a missing rex CLI was not a missing required tool"
pass "doctor --backend rex leaves an old, missing, or unreachable Rex to a human, even under --fix"

doctor "$TMP_ROOT/path-rex" /nonexistent --backend tmux
[ "$DOCTOR_RC" -eq 2 ] || fail "an unsupported backend should be a usage error, got $DOCTOR_RC"
pass "doctor refuses a backend other than herdr or rex"
