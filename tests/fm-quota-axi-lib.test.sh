#!/usr/bin/env bash
# Behavior tests for the quota-axi compatibility floor used by bootstrap.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/bin/fm-quota-axi-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-quota-axi-lib)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")

write_quota_axi() {
  local version=$1
  cat > "$FAKEBIN/quota-axi" <<EOF
#!/usr/bin/env bash
printf '%s\\n' '$version'
EOF
  chmod 0755 "$FAKEBIN/quota-axi"
}

run_compatibility_check() {
  PATH="$FAKEBIN:/usr/bin:/bin" bash -c '. "$1"; fm_quota_axi_compatible' _ "$LIB"
}

test_exact_floor_is_compatible() {
  write_quota_axi 'quota-axi 0.1.29'
  run_compatibility_check || fail "the pinned minimum quota-axi version was rejected"
  pass "exact quota-axi compatibility floor is accepted"
}

test_older_version_is_incompatible() {
  write_quota_axi 'quota-axi 0.1.16'
  if run_compatibility_check; then
    fail "an older quota-axi version was accepted"
  fi
  pass "older quota-axi version is rejected"
}

test_unparseable_version_is_incompatible() {
  write_quota_axi 'development build'
  if run_compatibility_check; then
    fail "an unparseable quota-axi version was accepted"
  fi
  pass "unparseable quota-axi version is rejected"
}

test_exact_floor_is_compatible
test_older_version_is_incompatible
test_unparseable_version_is_incompatible
