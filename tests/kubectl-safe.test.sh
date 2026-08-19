#!/usr/bin/env bash
# Behavior tests for skills/kubectl-ops/scripts/kubectl-safe.sh using synthetic kubectl fixtures.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HELPER="$ROOT/skills/kubectl-ops/scripts/kubectl-safe.sh"
TMP_ROOT=$(fm_test_tmproot kubectl-safe-tests)

make_fake_kubectl() {
  local dir=$1 mode=${2:-ready}
  local fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/kubectl" <<'SH'
#!/usr/bin/env bash
MODE="${FM_FAKE_KUBECTL_MODE:-ready}"
case "${1:-}" in
  version)
    if [ "$MODE" = broken_version ]; then
      exit 1
    fi
    if [ "${2:-}" = --client ] && [ "${3:-}" = --output=yaml ]; then
      printf '%s\n' 'clientVersion:
  gitVersion: v1.30.0'
      exit 0
    fi
    printf 'Client Version: v1.30.0\n'
    exit 0
    ;;
  config)
    if [ "${2:-}" = current-context ]; then
      case "$MODE" in
        no_context) exit 1 ;;
        wrong_context) printf 'other-context\n'; exit 0 ;;
        api_error) exit 1 ;;
        *) printf 'expected-context\n'; exit 0 ;;
      esac
    fi
    ;;
  get)
    if [ "${2:-}" = namespace ]; then
      case "$MODE" in
        missing_namespace)
          printf 'Error from server (NotFound): namespaces "%s" not found\n' "${3:-}" >&2
          exit 1
          ;;
        api_error)
          printf 'Error: connection refused\n' >&2
          exit 1
          ;;
        *)
          printf 'namespace/%s\n' "${3:-}"
          exit 0
          ;;
      esac
    fi
    ;;
esac
printf 'unhandled kubectl fake: %s\n' "$*" >&2
exit 1
SH
  chmod +x "$fakebin/kubectl"
  printf '%s\n' "$fakebin"
}

run_with_fake() {
  local mode=$1
  shift
  local fakebin case_dir
  case_dir="$TMP_ROOT/$mode-${RANDOM}"
  mkdir -p "$case_dir"
  fakebin=$(make_fake_kubectl "$case_dir" "$mode")
  env FM_FAKE_KUBECTL_MODE="$mode" PATH="$fakebin:$PATH" "$@"
}

test_probe_absent() {
  local out case_dir fakebin
  case_dir="$TMP_ROOT/absent-${RANDOM}"
  mkdir -p "$case_dir"
  fakebin=$(fm_fakebin "$case_dir")
  out=$(env PATH="$fakebin" "$BASH" "$HELPER" probe)
  assert_contains "$out" 'status=unavailable' 'absent kubectl should report unavailable'
  assert_contains "$out" 'version=none' 'absent kubectl should report version none'
  pass 'probe classifies absent kubectl'
}

test_probe_ready() {
  local out
  out=$(run_with_fake ready "$HELPER" probe)
  assert_contains "$out" 'status=ready' 'ready kubectl should report ready'
  assert_contains "$out" 'current_context=expected-context' 'ready kubectl should report context'
  pass 'probe reports ready kubectl with context'
}

test_probe_no_context() {
  local out
  out=$(run_with_fake no_context "$HELPER" probe)
  assert_contains "$out" 'status=no_context' 'missing context should report no_context'
  pass 'probe classifies missing current context'
}

test_verify_context_match() {
  run_with_fake ready "$HELPER" verify-context expected-context
  pass 'verify-context accepts matching context'
}

test_verify_context_mismatch() {
  local rc=0
  set +e
  run_with_fake wrong_context "$HELPER" verify-context expected-context >/dev/null 2>"$TMP_ROOT/ctx.err"
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "context mismatch should exit 1, got $rc"
  assert_contains "$(<"$TMP_ROOT/ctx.err")" 'context mismatch' 'mismatch should explain failure'
  pass 'verify-context refuses unexpected context'
}

test_verify_namespace_present() {
  run_with_fake ready "$HELPER" verify-namespace app-ns
  pass 'verify-namespace accepts existing namespace'
}

test_verify_namespace_missing() {
  local rc=0
  set +e
  run_with_fake missing_namespace "$HELPER" verify-namespace missing-ns >/dev/null 2>"$TMP_ROOT/ns.err"
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "missing namespace should exit 1, got $rc"
  assert_contains "$(<"$TMP_ROOT/ns.err")" 'namespace not found' 'missing namespace should explain failure'
  pass 'verify-namespace refuses missing namespace'
}

test_verify_namespace_api_error() {
  local rc=0
  set +e
  run_with_fake api_error "$HELPER" verify-namespace app-ns >/dev/null
  rc=$?
  set -e
  [ "$rc" -eq 3 ] || fail "api error should exit 3, got $rc"
  pass 'verify-namespace preserves kubectl failures'
}

test_redact_secret_json() {
  local out
  out=$(printf '%s\n' '{"kind":"Secret","data":{"token":"c2VjcmV0"},"stringData":{"plain":"value"}}' \
    | "$HELPER" redact-json)
  assert_contains "$out" '[REDACTED]' 'redact-json should replace secret fields'
  assert_not_contains "$out" 'c2VjcmV0' 'redact-json must not leak data values'
  assert_not_contains "$out" 'value' 'redact-json must not leak stringData values'
  pass 'redact-json redacts Secret data and stringData'
}

test_cp_check_nonempty_and_checksum() {
  local src dest out
  src="$TMP_ROOT/cp-src.bin"
  dest="$TMP_ROOT/cp-dest.bin"
  printf 'backup-bytes' >"$src"
  cp "$src" "$dest"
  out=$("$HELPER" cp-check "$src" "$dest")
  assert_contains "$out" 'checksum=' 'cp-check should print checksum'
  assert_contains "$out" 'bytes=' 'cp-check should print byte count'
  pass 'cp-check accepts matching non-empty transfer'
}

test_cp_check_empty_source() {
  local rc=0 src dest
  src="$TMP_ROOT/empty-src.bin"
  dest="$TMP_ROOT/empty-dest.bin"
  : >"$src"
  touch "$dest"
  set +e
  "$HELPER" cp-check "$src" "$dest" >/dev/null 2>"$TMP_ROOT/cp-empty.err"
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "empty source should exit 1, got $rc"
  assert_contains "$(<"$TMP_ROOT/cp-empty.err")" 'source is empty' 'empty source should explain failure'
  pass 'cp-check refuses empty source files'
}

test_cp_check_checksum_mismatch() {
  local rc=0 src dest
  src="$TMP_ROOT/mismatch-src.bin"
  dest="$TMP_ROOT/mismatch-dest.bin"
  printf 'left' >"$src"
  printf 'right' >"$dest"
  set +e
  "$HELPER" cp-check "$src" "$dest" >/dev/null 2>"$TMP_ROOT/cp-mismatch.err"
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "checksum mismatch should exit 1, got $rc"
  assert_contains "$(<"$TMP_ROOT/cp-mismatch.err")" 'checksum mismatch' 'mismatch should explain failure'
  pass 'cp-check refuses checksum mismatch'
}

test_has_dry_run_present() {
  "$HELPER" has-dry-run -- kubectl apply --dry-run=client -f manifest.yaml
  pass 'has-dry-run accepts dry-run client apply'
}

test_has_dry_run_missing() {
  local rc=0
  set +e
  "$HELPER" has-dry-run -- kubectl apply -f manifest.yaml >/dev/null 2>"$TMP_ROOT/dry.err"
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "missing dry-run should exit 1, got $rc"
  assert_contains "$(<"$TMP_ROOT/dry.err")" 'lacks --dry-run' 'missing dry-run should explain failure'
  pass 'has-dry-run refuses apply without dry-run'
}

test_probe_absent
test_probe_ready
test_probe_no_context
test_verify_context_match
test_verify_context_mismatch
test_verify_namespace_present
test_verify_namespace_missing
test_verify_namespace_api_error
test_redact_secret_json
test_cp_check_nonempty_and_checksum
test_cp_check_empty_source
test_cp_check_checksum_mismatch
test_has_dry_run_present
test_has_dry_run_missing
