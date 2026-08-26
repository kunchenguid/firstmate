#!/usr/bin/env bash
# Characterization tests for the read-only structured fleet snapshot.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SNAPSHOT="$ROOT/bin/fm-fleet-snapshot.sh"
TMP_ROOT=$(fm_test_tmproot fm-fleet-snapshot-contract)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
REAL_JQ=$(command -v jq)

test_empty_local_snapshot_contract() {
  local home out
  home="$TMP_ROOT/home"
  mkdir -p "$home"/{config,data,projects,state}

  out=$(FM_HOME="$home" "$SNAPSHOT" --local-json) \
    || fail "empty local snapshot should succeed"
  printf '%s' "$out" | jq -e '
    .schema == "fm-fleet-snapshot.v1"
      and .backlog.present == false
      and (.tasks | length) == 0
      and .secondmate_current.collection == "skipped-local-only"
  ' >/dev/null || fail "empty local snapshot contract changed: $out"
  pass "empty local snapshot preserves the stable schema and absence markers"
}

test_invalid_mode_fails_closed() {
  local home err rc
  home="$TMP_ROOT/invalid"
  mkdir -p "$home"
  err="$TMP_ROOT/invalid.err"
  set +e
  FM_HOME="$home" "$SNAPSHOT" --not-a-mode 2>"$err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "invalid snapshot mode should exit 2, got $rc"
  assert_contains "$(cat "$err")" "usage: fm-fleet-snapshot.sh --json" \
    "invalid snapshot mode should print usage"
  pass "invalid snapshot mode is rejected with usage"
}

test_large_snapshot_assembly_does_not_use_argv() {
  local home out arg_max payload_bytes report_count i report_id data_path
  home="$TMP_ROOT/large-assembly"
  mkdir -p "$home"/{config,data,projects,state}
  arg_max=$(getconf ARG_MAX 2>/dev/null || printf '1048576')
  payload_bytes=$((arg_max + 262144))
  report_count=$(((payload_bytes / 1800) + 1))
  data_path="$home/data"
  i=0
  while [ "$i" -lt 70 ]; do
    data_path="$data_path/aaaaaaaaaaaaaaaaaaaa"
    i=$((i + 1))
  done
  mkdir -p "$data_path"
  i=0
  while [ "$i" -lt "$report_count" ]; do
    report_id=$(printf 'r%0199d' "$i")
    mkdir -p "$data_path/$report_id"
    : > "$data_path/$report_id/report.md"
    i=$((i + 1))
  done

  FM_HOME="$home" FM_DATA_OVERRIDE="$data_path" "$SNAPSHOT" --local-json > "$home/snapshot.json" \
    || fail "snapshot assembly should survive a payload above ARG_MAX"
  jq -e --argjson expected "$report_count" '
    .schema == "fm-fleet-snapshot.v1"
      and (.scout_reports | length) == $expected
  ' "$home/snapshot.json" >/dev/null \
    || fail "large snapshot assembly did not emit the expected valid JSON"
  pass "large snapshot assembly transports JSON without argv limits"
}

test_snapshot_assembly_preserves_jq_failure() {
  local home fakebin staging rc
  home="$TMP_ROOT/jq-failure/home"
  fakebin="$TMP_ROOT/jq-failure/fakebin"
  staging="$TMP_ROOT/jq-failure/tmp"
  mkdir -p "$home"/{config,data,projects,state} "$fakebin" "$staging"
  sed "s|@REAL_JQ@|$REAL_JQ|" > "$fakebin/jq" <<'EOF'
#!/usr/bin/env bash
for arg in "$@"; do
  if [ "$arg" = --slurpfile ]; then
    exit 42
  fi
done
exec "@REAL_JQ@" "$@"
EOF
  chmod +x "$fakebin/jq"

  set +e
  TMPDIR="$staging" PATH="$fakebin:$PATH" FM_HOME="$home" \
    "$SNAPSHOT" --local-json >/dev/null
  rc=$?
  set -e
  [ "$rc" -eq 42 ] || fail "snapshot assembly should preserve jq exit 42, got $rc"
  if find "$staging" -mindepth 1 -print -quit | grep -q .; then
    fail "failed snapshot assembly should remove its staged payload"
  fi
  pass "snapshot assembly preserves jq failures and cleans staged payloads"
}

test_empty_local_snapshot_contract
test_invalid_mode_fails_closed
test_large_snapshot_assembly_does_not_use_argv
test_snapshot_assembly_preserves_jq_failure
