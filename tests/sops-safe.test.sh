#!/usr/bin/env bash
# Behavior tests for skills/sops-age/scripts/sops-safe.sh using synthetic fixtures.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HELPER="$ROOT/skills/sops-age/scripts/sops-safe.sh"
TMP_ROOT=$(fm_test_tmproot sops-safe-tests)

chmod +x "$HELPER"

make_fake_sops_age() {
  local dir=$1 sops_mode=${2:-ready} age_mode=${3:-ready}
  local fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/sops" <<'SH'
#!/usr/bin/env bash
MODE="${FM_FAKE_SOPS_MODE:-ready}"
DECRYPT_REQUESTED=0
for ARG in "$@"; do
  case "$ARG" in
    -d|--decrypt|decrypt) DECRYPT_REQUESTED=1 ;;
  esac
done
if [ "$DECRYPT_REQUESTED" -eq 1 ]; then
  if [ -n "${SOPS_AGE_KEY:-}${SOPS_AGE_KEY_FILE:-}" ] || [ -n "${FM_FAKE_BWS_INJECTED:-}" ]; then
    if [ -n "${FM_FAKE_DECRYPT_MARKER:-}" ]; then
      : > "$FM_FAKE_DECRYPT_MARKER"
    fi
    printf 'password: super-secret-value\n'
    exit 0
  fi
  printf 'sops: failed to decrypt\n' >&2
  exit 1
fi
case "${1:-}" in
  --version)
    case "$MODE" in
      absent) exit 127 ;;
      broken) exit 1 ;;
      *) printf 'sops 3.9.0\n'; exit 0 ;;
    esac
    ;;
  edit)
    exit 0
    ;;
esac
printf 'unhandled sops fake: %s\n' "$*" >&2
exit 1
SH
  cat > "$fakebin/age" <<'SH'
#!/usr/bin/env bash
MODE="${FM_FAKE_AGE_MODE:-ready}"
case "${1:-}" in
  --version)
    case "$MODE" in
      absent) exit 127 ;;
      broken) exit 1 ;;
      *) printf 'age 1.2.0\n'; exit 0 ;;
    esac
    ;;
esac
printf 'unhandled age fake: %s\n' "$*" >&2
exit 1
SH
  chmod +x "$fakebin/sops" "$fakebin/age"
  printf '%s\n' "$fakebin"
}

make_fake_bws_run() {
  local dir=$1
  local fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/bws" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  run)
    shift
    [ "${1:-}" = --project-id ] || exit 1
    shift 2
    [ "${1:-}" = -- ] || exit 1
    shift
    FM_FAKE_BWS_INJECTED=1 SOPS_AGE_KEY_FILE=/dev/null "$@"
    ;;
  *)
    printf 'unhandled bws fake: %s\n' "$*" >&2
    exit 1
    ;;
esac
SH
  chmod +x "$fakebin/bws"
  printf '%s\n' "$fakebin"
}

run_with_fake_tools() {
  local sops_mode=$1 age_mode=$2
  shift 2
  local case_dir isolated_home fakebin
  case_dir="$TMP_ROOT/tools-${sops_mode}-${age_mode}-${RANDOM}"
  isolated_home="$case_dir/home"
  mkdir -p "$isolated_home"
  fakebin=$(make_fake_sops_age "$case_dir" "$sops_mode" "$age_mode")
  env -u SOPS_AGE_KEY -u SOPS_AGE_KEY_FILE -u FM_FAKE_BWS_INJECTED \
    HOME="$isolated_home" FM_FAKE_SOPS_MODE="$sops_mode" FM_FAKE_AGE_MODE="$age_mode" \
    PATH="$fakebin:/usr/bin:/bin" "$@"
}

test_probe_ready() {
  local out
  out=$(run_with_fake_tools ready ready "$HELPER" probe)
  assert_contains "$out" 'status=ready' 'ready install should report ready'
  assert_contains "$out" 'sops_version=3.9.0' 'ready install should report sops version'
  assert_contains "$out" 'age_version=1.2.0' 'ready install should report age version'
  pass 'probe reports ready when both tools are present'
}

test_probe_sops_absent() {
  local case_dir out
  case_dir="$TMP_ROOT/sops-missing"
  make_fake_sops_age "$case_dir" absent ready >/dev/null
  rm -f "$case_dir/fakebin/sops"
  out=$(env -u SOPS_AGE_KEY -u SOPS_AGE_KEY_FILE PATH="$case_dir/fakebin:/usr/bin:/bin" "$HELPER" probe)
  assert_contains "$out" 'status=sops_absent' 'missing sops should report sops_absent'
  pass 'probe classifies absent sops'
}

test_probe_age_absent() {
  local case_dir out
  case_dir="$TMP_ROOT/age-missing"
  make_fake_sops_age "$case_dir" ready absent >/dev/null
  rm -f "$case_dir/fakebin/age"
  out=$(env HOME="$TMP_ROOT/age-missing/home" PATH="$case_dir/fakebin:/usr/bin:/bin" "$HELPER" probe)
  assert_contains "$out" 'status=age_absent' 'missing age should report age_absent'
  pass 'probe classifies absent age'
}

test_detect_age_identity_absent() {
  local rc=0 out
  set +e
  out=$(env -u SOPS_AGE_KEY -u SOPS_AGE_KEY_FILE "$HELPER" detect-age-identity)
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "absent identity should exit 1, got $rc"
  assert_contains "$out" 'age_identity_present=no' 'absent identity should report no'
  assert_not_contains "$out" 'AGE-SECRET-KEY' 'detect must never print keys'
  pass 'detect-age-identity reports absent without leaking keys'
}

test_detect_age_identity_env() {
  local out rc=0
  set +e
  out=$(env SOPS_AGE_KEY='AGE-SECRET-KEY-TESTKEYTESTKEYTESTKEYTESTKEYTESTKEYTEST' \
    "$HELPER" detect-age-identity)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "env identity should exit 0, got $rc"
  assert_contains "$out" 'age_identity_present=yes' 'env identity should report yes'
  assert_contains "$out" 'source=env' 'env identity should report source env'
  assert_not_contains "$out" 'TESTKEY' 'detect must never print key material'
  pass 'detect-age-identity detects SOPS_AGE_KEY without echoing it'
}

test_detect_age_identity_file() {
  local key_file out rc=0
  key_file="$TMP_ROOT/test-age-key.txt"
  printf 'AGE-SECRET-KEY-TESTKEYTESTKEYTESTKEYTESTKEYTESTKEYTEST\n' > "$key_file"
  chmod 600 "$key_file"
  set +e
  out=$(env -u SOPS_AGE_KEY SOPS_AGE_KEY_FILE="$key_file" "$HELPER" detect-age-identity)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "file identity should exit 0, got $rc"
  assert_contains "$out" 'source=file' 'file identity should report source file'
  assert_not_contains "$out" 'TESTKEY' 'detect must never print key material'
  pass 'detect-age-identity detects SOPS_AGE_KEY_FILE without echoing it'
}

test_with_age_key_refuses_key_in_args() {
  local key_file rc=0
  key_file="$TMP_ROOT/refuse-key-args.txt"
  printf 'AGE-SECRET-KEY-TESTKEYTESTKEYTESTKEYTESTKEYTESTKEYTEST\n' > "$key_file"
  chmod 600 "$key_file"
  set +e
  "$HELPER" with-age-key file "$key_file" -- sops --decrypt \
    'AGE-SECRET-KEY-ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890AB' >/dev/null 2>"$TMP_ROOT/key-arg.err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "key in args should exit 2, got $rc"
  assert_contains "$(<"$TMP_ROOT/key-arg.err")" 'refusing command with age private key' \
    'with-age-key should refuse key material in arguments'
  pass 'with-age-key refuses age private keys in command arguments'
}

test_with_age_key_file_mode() {
  local key_file marker case_dir fakebin out
  key_file="$TMP_ROOT/with-key-file.txt"
  printf 'AGE-SECRET-KEY-TESTKEYTESTKEYTESTKEYTESTKEYTESTKEYTEST\n' > "$key_file"
  chmod 600 "$key_file"
  case_dir="$TMP_ROOT/with-file-mode"
  marker="$case_dir/decrypted"
  fakebin=$(make_fake_sops_age "$case_dir" ready ready)
  out=$(env -u SOPS_AGE_KEY -u SOPS_AGE_KEY_FILE SOPS_AGE_KEY_FILE=should-be-cleared \
    FM_FAKE_DECRYPT_MARKER="$marker" PATH="$fakebin:/usr/bin:/bin" \
    "$HELPER" with-age-key file "$key_file" -- sops --decrypt secret.enc.yaml)
  [ -f "$marker" ] || fail 'with-age-key file should run child with identity'
  [ -z "$out" ] || fail 'with-age-key file must suppress decrypted stdout'
  pass 'with-age-key file mode injects identity for child command'
}

test_with_age_key_bws_mode() {
  local marker case_dir fakebin bwsbin out
  case_dir="$TMP_ROOT/with-bws-mode"
  marker="$case_dir/decrypted"
  fakebin=$(make_fake_sops_age "$case_dir" ready ready)
  bwsbin=$(make_fake_bws_run "$case_dir")
  out=$(env -u SOPS_AGE_KEY -u SOPS_AGE_KEY_FILE FM_FAKE_DECRYPT_MARKER="$marker" \
    PATH="$bwsbin:$case_dir/fakebin:/usr/bin:/bin" \
    "$HELPER" with-age-key bws proj-1 -- sops -d secret.enc.yaml)
  [ -f "$marker" ] || fail 'with-age-key bws should run child through bws run'
  [ -z "$out" ] || fail 'with-age-key bws must suppress decrypted stdout'
  pass 'with-age-key bws mode delegates to bws run'
}

test_with_age_key_refuses_indirect_commands() {
  local key_file case_dir fakebin rc=0 out
  key_file="$TMP_ROOT/refuse-indirect.txt"
  printf 'AGE-SECRET-KEY-TESTKEYTESTKEYTESTKEYTESTKEYTESTKEYTEST\n' > "$key_file"
  chmod 600 "$key_file"
  case_dir="$TMP_ROOT/refuse-indirect"
  fakebin=$(make_fake_sops_age "$case_dir" ready ready)
  set +e
  out=$(env -u SOPS_AGE_KEY -u SOPS_AGE_KEY_FILE PATH="$fakebin:/usr/bin:/bin" \
    "$HELPER" with-age-key file "$key_file" -- env sops --decrypt secret.enc.yaml 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "indirect decrypt should exit 2, got $rc"
  assert_not_contains "$out" 'super-secret-value' 'refused indirect decrypt must not print plaintext'
  assert_contains "$out" 'accepts direct sops' 'indirect decrypt should explain the direct-command boundary'
  pass 'with-age-key refuses indirect decrypt commands'
}

test_with_age_key_refuses_conflicting_operations() {
  local key_file case_dir fakebin rc=0 out
  key_file="$TMP_ROOT/refuse-conflicting.txt"
  printf 'AGE-SECRET-KEY-TESTKEYTESTKEYTESTKEYTESTKEYTESTKEYTEST\n' > "$key_file"
  chmod 600 "$key_file"
  case_dir="$TMP_ROOT/refuse-conflicting"
  fakebin=$(make_fake_sops_age "$case_dir" ready ready)
  set +e
  out=$(env -u SOPS_AGE_KEY -u SOPS_AGE_KEY_FILE PATH="$fakebin:/usr/bin:/bin" \
    "$HELPER" with-age-key file "$key_file" -- sops encrypt --decrypt 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "conflicting operations should exit 2, got $rc"
  assert_not_contains "$out" 'super-secret-value' 'refused conflicting operations must not print plaintext'
  pass 'with-age-key refuses conflicting operation tokens'
}

test_with_age_key_unsets_identity_after() {
  local key_file rc=0
  key_file="$TMP_ROOT/unset-after.txt"
  printf 'AGE-SECRET-KEY-TESTKEYTESTKEYTESTKEYTESTKEYTESTKEYTEST\n' > "$key_file"
  chmod 600 "$key_file"
  case_dir="$TMP_ROOT/unset-after"
  make_fake_sops_age "$case_dir" ready ready >/dev/null
  env -u SOPS_AGE_KEY -u SOPS_AGE_KEY_FILE PATH="$case_dir/fakebin:/usr/bin:/bin" \
    "$HELPER" with-age-key file "$key_file" -- sops edit secret.enc.yaml
  set +e
  env -u SOPS_AGE_KEY -u SOPS_AGE_KEY_FILE "$HELPER" detect-age-identity >/dev/null
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail 'parent shell should have no age identity after with-age-key completes'
  pass 'with-age-key does not leave age identity in the parent shell'
}

test_probe_ready
test_probe_sops_absent
test_probe_age_absent
test_detect_age_identity_absent
test_detect_age_identity_env
test_detect_age_identity_file
test_with_age_key_refuses_key_in_args
test_with_age_key_file_mode
test_with_age_key_bws_mode
test_with_age_key_refuses_indirect_commands
test_with_age_key_refuses_conflicting_operations
test_with_age_key_unsets_identity_after
