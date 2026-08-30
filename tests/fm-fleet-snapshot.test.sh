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
  segment='aaaaaaaaaaaaaaaaaaaa'
  seg_len=$(( ${#segment} + 1 ))
  path_max=$(getconf PATH_MAX 2>/dev/null || true)
  [ -n "$path_max" ] || path_max=1024
  if [ "$(uname -s)" = Darwin ] && [ "$path_max" -gt 1024 ]; then
    path_max=1024
  fi
  max_segments=70
  while [ "$max_segments" -gt 0 ] \
    && [ $(( ${#data_path} + max_segments * seg_len + 220 )) -gt "$path_max" ]; do
    max_segments=$((max_segments - 1))
  done
  [ "$max_segments" -gt 0 ] || fail "could not fit snapshot path depth under PATH_MAX"
  i=0
  while [ "$i" -lt "$max_segments" ]; do
    data_path="$data_path/$segment"
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

test_large_backlog_end_to_end_snapshot() {
  local home arg_max payload_bytes backlog
  home="$TMP_ROOT/large-backlog"
  mkdir -p "$home"/{config,data,projects,state}
  arg_max=$(getconf ARG_MAX 2>/dev/null || printf '1048576')
  payload_bytes=$((arg_max + 262144))
  backlog="$home/data/backlog.md"
  {
    printf '%s\n- [ ] oversized - ' '## Queued'
    dd if=/dev/zero bs=1 count="$payload_bytes" 2>/dev/null | tr '\0' x
    printf '%s\n\n## Done\n' ' (repo: firstmate) (kind: ship)'
  } > "$backlog"

  FM_HOME="$home" "$SNAPSHOT" --local-json > "$home/snapshot.json" \
    || fail "end-to-end snapshot should survive a backlog payload above ARG_MAX"
  jq -e '
    .schema == "fm-fleet-snapshot.v1"
      and .backlog.present == true
      and (.backlog.records | length) == 1
      and .backlog.records[0].id == "oversized"
  ' "$home/snapshot.json" >/dev/null \
    || fail "large backlog snapshot did not emit the expected valid JSON"
  pass "large backlog is transported through the complete local snapshot pipeline"
}

test_large_status_event_end_to_end_snapshot() {
  local home arg_max payload_bytes status
  home="$TMP_ROOT/large-status-event"
  mkdir -p "$home"/{config,data,projects,state}
  fm_write_meta "$home/state/oversized.meta" \
    "project=firstmate" \
    "kind=ship" \
    "mode=ship" \
    "yolo=off"
  arg_max=$(getconf ARG_MAX 2>/dev/null || printf '1048576')
  payload_bytes=$((arg_max + 262144))
  status="$home/state/oversized.status"
  {
    printf 'working: '
    dd if=/dev/zero bs=1 count="$payload_bytes" 2>/dev/null | tr '\0' x
    printf '\n'
  } > "$status"

  FM_HOME="$home" "$SNAPSHOT" --local-json > "$home/snapshot.json" \
    || fail "end-to-end snapshot should survive a status event above ARG_MAX"
  jq -e --argjson expected "$payload_bytes" '
    .schema == "fm-fleet-snapshot.v1"
      and (.tasks | length) == 1
      and .tasks[0].id == "oversized"
      and (.tasks[0].paths.status_log.last_event.raw | length) == ($expected + 9)
      and .tasks[0].hints.last_event_text == .tasks[0].paths.status_log.last_event.raw
  ' "$home/snapshot.json" >/dev/null \
    || fail "large status event snapshot did not preserve the expected JSON meaning"
  pass "large status event is transported through the complete local snapshot pipeline"
}

test_large_metadata_end_to_end_snapshot() {
  local home arg_max payload_bytes meta
  home="$TMP_ROOT/large-metadata"
  mkdir -p "$home"/{config,data,projects,state}
  arg_max=$(getconf ARG_MAX 2>/dev/null || printf '1048576')
  payload_bytes=$((arg_max + 262144))
  meta="$home/state/oversized.meta"
  {
    printf 'project='
    dd if=/dev/zero bs=1 count="$payload_bytes" 2>/dev/null | tr '\0' x
    printf '\nkind=ship\nmode=ship\nyolo=off\n'
  } > "$meta"

  FM_HOME="$home" "$SNAPSHOT" --local-json > "$home/snapshot.json" \
    || fail "end-to-end snapshot should survive metadata above ARG_MAX"
  jq -e --argjson expected "$payload_bytes" '
    .schema == "fm-fleet-snapshot.v1"
      and (.tasks | length) == 1
      and .tasks[0].id == "oversized"
      and (.tasks[0].project | length) == $expected
  ' "$home/snapshot.json" >/dev/null \
    || fail "large metadata snapshot did not preserve the expected JSON meaning"
  pass "large metadata is transported through the complete local snapshot pipeline"
}

test_large_remote_secondmate_metadata_degrades_cleanly() {
  local home fakebin arg_max payload_bytes meta
  home="$TMP_ROOT/large-remote-secondmate-metadata"
  fakebin="$home/fakebin"
  mkdir -p "$home"/{config,data,projects,state} "$fakebin"
  arg_max=$(getconf ARG_MAX 2>/dev/null || printf '1048576')
  payload_bytes=$((arg_max + 262144))
  meta="$home/state/oversized.meta"
  {
    printf 'kind=secondmate\nmode=secondmate\nyolo=off\nremote_host=unavailable.example\nremote_root=/tmp\nhome=/'
    dd if=/dev/zero bs=1 count="$payload_bytes" 2>/dev/null | tr '\0' x
    printf '\n'
  } > "$meta"
  {
    printf '%s' '- oversized - remote route (host: unavailable.example; root: /tmp; home: /'
    dd if=/dev/zero bs=1 count="$payload_bytes" 2>/dev/null | tr '\0' x
    printf '; scope: testing; projects: firstmate; added 2026-08-26)\n'
  } > "$home/data/secondmates.md"
  printf 'working: remote route unavailable\n' > "$home/state/oversized.status"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fakebin/ssh"
  chmod +x "$fakebin/ssh"

  PATH="$fakebin:$PATH" FM_HOME="$home" FM_SNAPSHOT_REGISTRY_BYTES=$((payload_bytes + 4096)) \
    "$SNAPSHOT" --json > "$home/snapshot.json" \
    || fail "snapshot should degrade an unavailable secondmate with metadata above ARG_MAX"
  jq -e --argjson expected "$payload_bytes" '
    .schema == "fm-fleet-snapshot.v1"
      and (.secondmate_current.records | length) == 1
      and .secondmate_current.records[0].id == "oversized"
      and (.secondmate_current.records[0].home | length) == ($expected + 1)
      and .secondmate_current.records[0].remote == true
      and .secondmate_current.records[0].current.state == "unknown"
      and .secondmate_current.records[0].provenance.selected == "parent-event-fallback"
  ' "$home/snapshot.json" >/dev/null \
    || fail "large remote secondmate metadata did not preserve degraded snapshot semantics"
  pass "large remote secondmate metadata preserves degraded snapshot output"
}

test_status_event_staging_failure_fails_snapshot() {
  local home fakebin err rc real_mktemp
  home="$TMP_ROOT/status-staging-failure/home"
  fakebin="$TMP_ROOT/status-staging-failure/fakebin"
  err="$TMP_ROOT/status-staging-failure/stderr"
  real_mktemp=$(command -v mktemp)
  mkdir -p "$home"/{config,data,projects,state} "$fakebin"
  fm_write_meta "$home/state/task.meta" \
    "project=firstmate" \
    "kind=ship" \
    "mode=ship" \
    "yolo=off"
  printf 'working: still running\n' > "$home/state/task.status"
  sed "s|@REAL_MKTEMP@|$real_mktemp|" > "$fakebin/mktemp" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *fm-fleet-snapshot.status-event.*) exit 73 ;;
esac
exec "@REAL_MKTEMP@" "$@"
EOF
  chmod +x "$fakebin/mktemp"

  set +e
  PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --local-json >/dev/null 2> "$err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "status staging failure should fail the snapshot"
  assert_contains "$(cat "$err")" "fm-fleet-snapshot: task snapshot failed" \
    "status staging failure should propagate through task assembly"
  pass "status event staging failures fail the snapshot"
}

test_reconciliation_staging_failure_fails_snapshot() {
  local home secondmate fakebin err rc real_mktemp
  home="$TMP_ROOT/reconciliation-staging-failure/home"
  secondmate="$TMP_ROOT/reconciliation-staging-failure/secondmate"
  fakebin="$TMP_ROOT/reconciliation-staging-failure/fakebin"
  err="$TMP_ROOT/reconciliation-staging-failure/stderr"
  real_mktemp=$(command -v mktemp)
  mkdir -p "$home"/{config,data,projects,state} \
    "$secondmate"/{bin,config,data,projects,state} "$fakebin"
  printf 'mate\n' > "$secondmate/.fm-secondmate-home"
  : > "$secondmate/AGENTS.md"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$secondmate/data/backlog.md"
  printf '%s\n' \
    "- mate - delegated work (home: $secondmate; scope: testing; projects: firstmate; added 2026-08-26)" \
    > "$home/data/secondmates.md"
  fm_write_secondmate_meta "$home/state/mate.meta" "$secondmate"
  printf 'working: delegated work\n' > "$home/state/mate.status"
  FM_HOME="$home" "$SNAPSHOT" --json > "$home/baseline.json" \
    || fail "reconciliation failure fixture should produce a baseline snapshot"
  jq -e '.secondmate_current.records[0].provenance.selected == "structured-home"' \
    "$home/baseline.json" >/dev/null \
    || fail "reconciliation failure fixture should reach structured secondmate aggregation"
  sed "s|@REAL_MKTEMP@|$real_mktemp|" > "$fakebin/mktemp" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *fm-fleet-snapshot.reconciliation.*) exit 73 ;;
esac
exec "@REAL_MKTEMP@" "$@"
EOF
  chmod +x "$fakebin/mktemp"

  set +e
  PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json >/dev/null 2> "$err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "reconciliation staging failure should fail the snapshot"
  assert_contains "$(cat "$err")" "fm-fleet-snapshot: registered secondmate aggregation failed" \
    "reconciliation staging failure should propagate through secondmate aggregation"
  pass "reconciliation staging failures fail the snapshot"
}

test_snapshot_assembly_preserves_jq_failure() {
  local home fakebin staging rc
  home="$TMP_ROOT/jq-failure/home"
  fakebin="$TMP_ROOT/jq-failure/fakebin"
  staging="$TMP_ROOT/jq-failure/tmp"
  mkdir -p "$home"/{config,data,projects,state} "$fakebin" "$staging"
  sed "s|@REAL_JQ@|$REAL_JQ|" > "$fakebin/jq" <<'EOF'
#!/usr/bin/env bash
slurpfiles=0
for arg in "$@"; do
  if [ "$arg" = --slurpfile ]; then
    slurpfiles=$((slurpfiles + 1))
  fi
done
[ "$slurpfiles" -lt 6 ] || exit 42
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
test_large_backlog_end_to_end_snapshot
test_large_status_event_end_to_end_snapshot
test_large_metadata_end_to_end_snapshot
test_large_remote_secondmate_metadata_degrades_cleanly
test_status_event_staging_failure_fails_snapshot
test_reconciliation_staging_failure_fails_snapshot
test_snapshot_assembly_preserves_jq_failure
