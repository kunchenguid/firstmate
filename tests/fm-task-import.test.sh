#!/usr/bin/env bash
# Explicit legacy import through the existing fleet snapshot aggregation.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-task-import)
HOME_DIR="$TMP_ROOT/home"
LEGACY="$TMP_ROOT/legacy"
mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config" "$LEGACY/data"
BACKLOG="$LEGACY/data/backlog.md"
ARCHIVE="$LEGACY/data/done-archive.md"
printf '## In flight\n\n## Queued\n\n## Done\n' >"$BACKLOG"
printf 'backend = "markdown"\n\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 1\n' >"$LEGACY/.tasks.toml"

tx() { (cd "$LEGACY" && tasks-axi "$@"); }
tx add active "Imported active goal https://example.com/evidence/42" --kind ship --body "Imported active body" --start >/dev/null
tx add queued "Imported queued goal" --kind scout --body "Imported queued body" >/dev/null
tx add done-old "Imported archived goal" --kind ship --body "Archived body" --start >/dev/null
tx 'done' done-old >/dev/null
tx add done-current "Imported done goal" --kind scout --body "Done body" --start >/dev/null
tx 'done' done-current >/dev/null
tx hold queued --reason "Wait for captain" --kind captain --until 2026-12-01 >/dev/null
tx block active --by queued >/dev/null
tx update active --pr https://github.com/example/repo/pull/7 >/dev/null
legacy_body='Imported active body

<!-- firstmate-progress:v1 -->
acceptance: "Imported acceptance"
current_state: "Imported current state"
remaining_gap: "Imported remaining gap"
next_step: "Imported next step"
<!-- /firstmate-progress -->'
tx update active --body "$legacy_body" >/dev/null

backlog_hash=$(sha256sum "$BACKLOG" | awk '{print $1}')
archive_hash=$(sha256sum "$ARCHIVE" | awk '{print $1}')
FM_HOME="$HOME_DIR" "$ROOT/bin/fm-task-import.sh" --backlog "$BACKLOG" --archive "$ARCHIVE" >/dev/null \
  || fail "legacy import failed"
assert_equals "$backlog_hash" "$(sha256sum "$BACKLOG" | awk '{print $1}')" "import rewrote the legacy backlog"
assert_equals "$archive_hash" "$(sha256sum "$ARCHIVE" | awk '{print $1}')" "import rewrote the legacy archive"

inventory=$(python3 "$ROOT/bin/fm-task-record.py" --data "$HOME_DIR/data" inventory) || fail "imported inventory read failed"
assert_equals 4 "$(printf '%s' "$inventory" | jq '.tasks|length')" "import dropped a legacy task"
printf '%s' "$inventory" | jq -e '
  any(.tasks[];.id=="active" and .state=="in_flight" and .blocked_by==["queued"] and
    .links.pr=="https://github.com/example/repo/pull/7" and
    .links.artifact_1=="https://example.com/evidence/42" and
    .progress.acceptance=="Imported acceptance" and .progress.next_step=="Imported next step") and
  any(.tasks[];.id=="queued" and .state=="queued" and .hold.kind=="captain" and .hold.until=="2026-12-01") and
  any(.tasks[];.id=="done-current" and .state=="done") and
  any(.tasks[];.id=="done-old" and .state=="archived")' >/dev/null \
  || fail "import did not preserve task business, progress, terminal, hold, dependency, or artifact facts"

before=$(find "$HOME_DIR/data" -name task.json -type f -print0 | sort -z | xargs -0 sha256sum)
FM_HOME="$HOME_DIR" "$ROOT/bin/fm-task-import.sh" --backlog "$BACKLOG" --archive "$ARCHIVE" >/dev/null \
  || fail "idempotent legacy import failed"
assert_equals "$before" "$(find "$HOME_DIR/data" -name task.json -type f -print0 | sort -z | xargs -0 sha256sum)" \
  "idempotent import rewrote canonical task records"

PARTIAL="$TMP_ROOT/partial"
mkdir -p "$PARTIAL/data" "$PARTIAL/state" "$PARTIAL/config"
cp "$BACKLOG" "$PARTIAL/data/backlog.md"
FM_DATA_OVERRIDE="$PARTIAL/data" "$ROOT/bin/fm-tasks-axi.sh" add active "Canonical active goal" --kind ship --start >/dev/null
partial_snapshot=$(FM_HOME="$PARTIAL" "$ROOT/bin/fm-fleet-snapshot.sh" --json) || fail "partial migration snapshot failed"
printf '%s' "$partial_snapshot" | jq -e '
  (.backlog.records | map(select(.structured) | .id) | unique) == ["active","done-current","queued"] and
  ([.backlog.records[] | select(.id=="active")] | length) == 1 and
  any(.backlog.records[];.id=="active" and .title=="Canonical active goal")' >/dev/null \
  || fail "partial migration hid an unimported legacy row or let legacy override canonical identity"

snapshot=$(FM_HOME="$HOME_DIR" "$ROOT/bin/fm-fleet-snapshot.sh" --json) || fail "canonical import snapshot failed"
printf '%s' "$snapshot" | jq -e '
  any(.backlog.records[];.id=="queued" and .hold_bucket=="dated" and .captain_actionable==false) and
  any(.backlog.records[];.id=="active" and .unresolved_blocker_ids==["queued"])' >/dev/null \
  || fail "canonical snapshot lost deferred captain-hold or unresolved-dependency classification"

pass "legacy task import preserves full inventory and business facts without rewriting retained sources"
