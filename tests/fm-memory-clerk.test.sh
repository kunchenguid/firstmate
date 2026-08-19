#!/usr/bin/env bash
# Behavioral coverage for /memory-clerk's durable-input allowlist, targeted
# report reads, bounded proposal publisher, provenance, and ownership rules.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CLERK="$ROOT/bin/fm-memory-clerk.sh"
TMP_ROOT=$(fm_test_tmproot fm-memory-clerk)
PASS_DATE=2026-08-04

run_inventory() {  # <home> [extra args...]
  local home=$1
  shift
  FM_HOME="$home" "$CLERK" inventory --date "$PASS_DATE" "$@"
}

source_field() {  # <inventory-file> <pointer> <field>
  python3 - "$1" "$2" "$3" <<'PY'
import json
import sys

path, pointer, field = sys.argv[1:]
data = json.load(open(path, encoding="utf-8"))
for source in data["sources"]:
    if source["pointer"] == pointer:
        value = source.get(field)
        if value is None:
            print("-")
        else:
            print(value)
        raise SystemExit(0)
raise SystemExit(3)
PY
}

write_payload() {  # <path> <items-json> [coverage-note]
  local path=$1 items=$2 note=${3:-Synthetic bounded pass.}
  python3 - "$path" "$items" "$note" <<'PY'
import json
import sys

path, items, note = sys.argv[1:]
with open(path, "w", encoding="utf-8") as handle:
    json.dump({"items": json.loads(items), "coverage_notes": [note]}, handle)
    handle.write("\n")
PY
}

item_json() {  # <key> <dest> <source> <digest> <scope> <class> <disposition> <proposal>
  python3 - "$@" <<'PY'
import json
import sys

key, destination, source, digest, scope, classification, disposition, proposal = sys.argv[1:]
print(json.dumps({
    "key": key,
    "destination_owner": destination,
    "source_pointer": source,
    "source_digest": digest,
    "date": "2026-08-04",
    "home_scope": scope,
    "classification": classification,
    "rationale": "The allowlisted source supports a bounded curation recommendation.",
    "disposition": disposition,
    "review_by": "2026-09-03",
    "proposal": proposal,
}, separators=(",", ":")))
PY
}

run_write() {  # <home> <payload> [extra args...]
  local home=$1 payload=$2
  shift 2
  FM_HOME="$home" "$CLERK" write --date "$PASS_DATE" "$@" < "$payload"
}

expect_failure() {  # <expected> <command...>
  local expected=$1 out rc
  shift
  set +e
  out=$("$@" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "expected memory-clerk refusal containing: $expected"
  assert_contains "$out" "$expected" "memory-clerk refusal was not specific"
}

make_primary_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state" "$home/projects/sample"
  printf '%s\n' "$home"
}

test_inventory_reads_only_allowlisted_durable_records() {
  local home inventory targeted pointers
  home=$(make_primary_home allowlist)
  cat > "$home/data/captain.md" <<'EOF'
# Captain

- Prefer direct bounded workflows.
EOF
  cat > "$home/data/captain-shared.md" <<'EOF'
# Shared captain preferences

- Keep cross-home preferences primary-owned.
EOF
  cat > "$home/data/learnings.md" <<'EOF'
# Learnings

- Project documentation pointer: docs/memory.md.
EOF
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] route-decision - Choose a bounded route (kind: captain-hold) (hold: captain: route pending)

## Done
EOF
  cat > "$home/data/done-archive.md" <<'EOF'
## Done archive
- [x] sample-report - Completed report data/sample-report/report.md (kind: scout) (reported 2026-08-03)
EOF
  mkdir -p "$home/data/sample-report"
  printf '# Targeted report\n\nTARGETED_REPORT_BODY_CANARY\n' > "$home/data/sample-report/report.md"

  printf 'FORBIDDEN_ENV_CANARY\n' > "$home/.env"
  printf 'FORBIDDEN_PRIVATE_DATA_CANARY\n' > "$home/data/private-notes.md"
  printf 'FORBIDDEN_SESSION_CANARY\n' > "$home/data/session.jsonl"
  printf 'FORBIDDEN_STATE_CANARY\n' > "$home/state/task.status"
  printf 'FORBIDDEN_PROJECT_CANARY\n' > "$home/projects/sample/secret.txt"

  inventory="$home/inventory.json"
  run_inventory "$home" > "$inventory" || fail "allowlisted inventory failed"
  pointers=$(python3 - "$inventory" <<'PY'
import json
import sys
print("\n".join(source["pointer"] for source in json.load(open(sys.argv[1]))["sources"]))
PY
)
  [ "$pointers" = $'data/captain.md\ndata/captain-shared.md\ndata/learnings.md\ndata/backlog.md\ndata/done-archive.md' ] \
    || fail "automatic inventory exposed a path outside the exact allowlist: $pointers"
  assert_contains "$(<"$inventory")" "docs/memory.md" \
    "project-documentation pointer was not considered through its allowlisted source"
  assert_contains "$(<"$inventory")" "data/sample-report/report.md" \
    "completed report pointer was not considered through structured records"
  assert_contains "$(<"$inventory")" "route pending" \
    "structured decision state was not included"
  assert_not_contains "$(<"$inventory")" "TARGETED_REPORT_BODY_CANARY" \
    "plain inventory swept a report body without an explicit target"
  assert_not_contains "$(<"$inventory")" "FORBIDDEN_" \
    "plain inventory exposed an unallowlisted private source"

  targeted="$home/targeted.json"
  run_inventory "$home" --report data/sample-report/report.md > "$targeted" \
    || fail "explicit targeted report inventory failed"
  assert_contains "$(<"$targeted")" "TARGETED_REPORT_BODY_CANARY" \
    "explicit targeted report body was not included"
  [ "$(source_field "$targeted" data/sample-report/report.md kind)" = explicit-targeted-report ] \
    || fail "targeted report provenance kind was not explicit"
  pass "inventory reads only the exact durable allowlist and explicit targeted report bodies"
}

test_missing_and_bounded_inputs_preserve_visible_status() {
  local home inventory oversized total
  home="$TMP_ROOT/missing"
  mkdir -p "$home"
  inventory="$home/missing.json"
  run_inventory "$home" > "$inventory" || fail "all-absent inventory failed"
  for pointer in data/captain.md data/captain-shared.md data/learnings.md data/backlog.md data/done-archive.md; do
    [ "$(source_field "$inventory" "$pointer" status)" = absent ] \
      || fail "missing $pointer did not preserve absent semantics"
  done
  [ ! -e "$home/data" ] || fail "read-only inventory created the absent data directory"

  mkdir -p "$home/data"
  python3 - "$home/data/captain.md" <<'PY'
import sys
open(sys.argv[1], "wb").write(b"a" * 24001)
PY
  oversized="$home/oversized.json"
  run_inventory "$home" > "$oversized" || fail "oversized source inventory failed"
  [ "$(source_field "$oversized" data/captain.md status)" = omitted-source-limit ] \
    || fail "oversized source was not omitted whole"
  [ "$(source_field "$oversized" data/captain.md sha256)" = - ] \
    || fail "oversized source received false included provenance"

  python3 - "$home/data/captain.md" "$home/data/captain-shared.md" "$home/data/learnings.md" <<'PY'
import sys
for index, path in enumerate(sys.argv[1:]):
    open(path, "wb").write(bytes([65 + index]) * 23000)
PY
  total="$home/total.json"
  run_inventory "$home" > "$total" || fail "aggregate-bounded inventory failed"
  [ "$(source_field "$total" data/learnings.md status)" = omitted-total-limit ] \
    || fail "aggregate limit did not omit the first source that would exceed it"
  pass "missing inputs stay absent and over-limit inputs are omitted without partial reads"
}

test_unsafe_and_unallowlisted_paths_are_refused() {
  local home outside
  home=$(make_primary_home unsafe-inputs)
  outside="$TMP_ROOT/outside-secret"
  printf 'OUTSIDE_SECRET_UNCHANGED\n' > "$outside"

  expect_failure 'targeted report must match data/<privacy-safe-id>/report.md' \
    env FM_HOME="$home" "$CLERK" inventory --date "$PASS_DATE" --report ../outside-secret
  expect_failure 'targeted report must match data/<privacy-safe-id>/report.md' \
    env FM_HOME="$home" "$CLERK" inventory --date "$PASS_DATE" --report data/x/transcript.jsonl
  expect_failure 'targeted report must match data/<privacy-safe-id>/report.md' \
    env FM_HOME="$home" "$CLERK" inventory --date "$PASS_DATE" --report projects/sample/README.md
  expect_failure 'at most 3 targeted reports may be read' \
    env FM_HOME="$home" "$CLERK" inventory --date "$PASS_DATE" \
      --report data/a/report.md --report data/b/report.md --report data/c/report.md --report data/d/report.md

  ln -s "$outside" "$home/data/captain.md"
  expect_failure 'source is not an ordinary regular file' \
    env FM_HOME="$home" "$CLERK" inventory --date "$PASS_DATE"
  [ "$(<"$outside")" = OUTSIDE_SECRET_UNCHANGED ] || fail "symlink refusal changed its target"

  rm "$home/data/captain.md"
  ln "$outside" "$home/data/captain.md"
  expect_failure 'source is hardlinked' \
    env FM_HOME="$home" "$CLERK" inventory --date "$PASS_DATE"
  [ "$(<"$outside")" = OUTSIDE_SECRET_UNCHANGED ] || fail "hardlink refusal changed its source"

  rm "$home/data/captain.md"
  printf 'not a directory\n' > "$home/data/report-parent"
  expect_failure 'source parent is not a directory' \
    env FM_HOME="$home" "$CLERK" inventory --date "$PASS_DATE" \
      --report data/report-parent/report.md
  pass "unsafe paths, report sweeps, project files, symlinks, and hardlinks are refused"
}

test_proposal_shape_provenance_and_output_budget() {
  local home inventory digest item payload artifact output before oversized_items invalid
  home=$(make_primary_home proposal)
  printf '# Learnings\n\n- Duplicate fact.\n' > "$home/data/learnings.md"
  inventory="$home/inventory.json"
  run_inventory "$home" > "$inventory" || fail "proposal inventory failed"
  digest=$(source_field "$inventory" data/learnings.md sha256)
  item=$(item_json duplicate-learning data/learnings.md data/learnings.md "$digest" \
    primary:this-home duplicate stow-candidate 'Prune the duplicate and retain one concise current learning.')
  payload="$home/payload.json"
  write_payload "$payload" "[$item]"
  output=$(printf '%s' "$(<"$payload")" | FM_HOME="$home" "$CLERK" write --date "$PASS_DATE") \
    || fail "valid piped proposal write failed"
  [ "$output" = data/memory-clerk/proposal-2026-08-04.md ] \
    || fail "proposal publisher returned an unexpected artifact path: $output"
  artifact="$home/$output"
  assert_present "$artifact" "proposal artifact was not published"
  [ "$(wc -c < "$artifact" | tr -d '[:space:]')" -le 12000 ] \
    || fail "proposal artifact exceeded its public output budget"
  [ "$(stat -c %a "$artifact")" = 600 ] || fail "proposal artifact is not private mode 0600"
  assert_grep "Source pointer: \`data/learnings.md\`" "$artifact" "proposal lost source provenance"
  assert_grep "Source digest: \`$digest\`" "$artifact" "proposal lost source digest provenance"
  assert_grep "Classification: \`duplicate\`" "$artifact" "proposal lost classification"
  assert_grep 'Canonical owners must apply accepted changes' "$artifact" \
    "proposal did not preserve canonical owner authority"

  before=$(shasum -a 256 "$artifact" | awk '{print $1}')
  printf '# Learnings\n\n- Source changed after inventory.\n' > "$home/data/learnings.md"
  expect_failure 'source_digest does not match the current source' \
    run_write "$home" "$payload"
  [ "$(shasum -a 256 "$artifact" | awk '{print $1}')" = "$before" ] \
    || fail "failed provenance validation replaced the prior proposal"

  # Restore the source and make 24 individually unique maximum-sized items.
  printf '# Learnings\n\n- Duplicate fact.\n' > "$home/data/learnings.md"
  oversized_items=$(python3 - "$digest" <<'PY'
import json
import sys

digest = sys.argv[1]
items = []
for index in range(24):
    items.append({
        "key": f"bounded-{index}",
        "destination_owner": "data/learnings.md",
        "source_pointer": "data/learnings.md",
        "source_digest": digest,
        "date": "2026-08-04",
        "home_scope": "primary:this-home",
        "classification": "new",
        "rationale": "R" * 300,
        "disposition": "stow-candidate",
        "review_by": "2026-09-03",
        "proposal": ("P" * 490) + f"-{index}",
    })
print(json.dumps(items, separators=(",", ":")))
PY
)
  invalid="$home/oversized-payload.json"
  write_payload "$invalid" "$oversized_items"
  expect_failure 'rendered proposal exceeds 12000 bytes' run_write "$home" "$invalid"
  [ "$(shasum -a 256 "$artifact" | awk '{print $1}')" = "$before" ] \
    || fail "over-budget proposal replaced the prior bounded artifact"
  pass "proposal publication enforces private shape, fresh provenance, atomic refusal, and output budget"
}

test_contradiction_supersession_and_dedup_rules() {
  local home inventory digest contradiction supersession payload artifact bad duplicate
  home=$(make_primary_home classifications)
  printf '# Captain\n\n- Prefer route A.\n- Newer record prefers route B.\n' > "$home/data/captain.md"
  inventory="$home/inventory.json"
  run_inventory "$home" > "$inventory" || fail "classification inventory failed"
  digest=$(source_field "$inventory" data/captain.md sha256)
  contradiction=$(item_json route-conflict data/captain.md data/captain.md "$digest" \
    primary:this-home contradiction review-required 'Review which route remains the current preference before rewriting either statement.')
  supersession=$(item_json old-route data/captain.md data/captain.md "$digest" \
    primary:this-home supersession stow-candidate 'Replace the explicitly superseded route statement with one current rule after review.')
  payload="$home/classifications.json"
  write_payload "$payload" "[$contradiction,$supersession]"
  run_write "$home" "$payload" >/dev/null || fail "valid contradiction and supersession proposal failed"
  artifact="$home/data/memory-clerk/proposal-$PASS_DATE.md"
  assert_grep "Classification: \`contradiction\`" "$artifact" "contradiction classification was lost"
  assert_grep "Disposition: \`review-required\`" "$artifact" "contradiction was not held for review"
  assert_grep "Classification: \`supersession\`" "$artifact" "supersession classification was lost"

  bad=$(item_json bad-conflict data/captain.md data/captain.md "$digest" \
    primary:this-home contradiction stow-candidate 'Silently pick one side of the conflict.')
  write_payload "$home/bad.json" "[$bad]"
  expect_failure 'contradictions require review-required' run_write "$home" "$home/bad.json"

  duplicate=$(item_json duplicate-key-two data/captain.md data/captain.md "$digest" \
    primary:this-home contradiction review-required 'Review which route remains the current preference before rewriting either statement.')
  write_payload "$home/duplicate.json" "[$contradiction,$duplicate]"
  expect_failure 'duplicates an existing destination/source/proposal tuple' \
    run_write "$home" "$home/duplicate.json"
  pass "contradictions require review, supersession stays explicit, and duplicate proposals are refused"
}

test_secondmate_never_reads_or_locally_owns_shared_captain_memory() {
  local home inventory digest item payload bad
  home="$TMP_ROOT/secondmate"
  mkdir -p "$home/data"
  printf 'sample-mate\n' > "$home/.fm-secondmate-home"
  printf '# Captain\n\n- A shared preference candidate was discovered locally.\n' > "$home/data/captain.md"
  printf 'PRIMARY_OWNED_SHARED_SECRET_CANARY\n' > "$home/data/captain-shared.md"
  inventory="$home/inventory.json"
  run_inventory "$home" > "$inventory" || fail "secondmate inventory failed"
  [ "$(source_field "$inventory" data/captain-shared.md status)" = excluded-primary-owned ] \
    || fail "secondmate inventory did not exclude primary-owned shared memory"
  assert_not_contains "$(<"$inventory")" PRIMARY_OWNED_SHARED_SECRET_CANARY \
    "secondmate inventory read inherited shared-captain bytes"
  digest=$(source_field "$inventory" data/captain.md sha256)
  item=$(item_json route-shared 'primary data/captain-shared.md' data/captain.md "$digest" \
    primary:via-main-firstmate new route-candidate 'Route this candidate to the main firstmate for primary-owned review.')
  payload="$home/route.json"
  write_payload "$payload" "[$item]"
  run_write "$home" "$payload" >/dev/null || fail "secondmate-to-primary routing proposal failed"

  bad=$(item_json local-shared 'primary data/captain-shared.md' data/captain.md "$digest" \
    secondmate:this-home new stow-candidate 'Rewrite inherited shared memory locally.')
  write_payload "$home/local.json" "[$bad]"
  expect_failure 'secondmates must route shared-captain proposals through the main firstmate' \
    run_write "$home" "$home/local.json"
  [ "$(<"$home/data/captain-shared.md")" = PRIMARY_OWNED_SHARED_SECRET_CANARY ] \
    || fail "proposal workflow changed primary-owned shared memory"
  pass "secondmates exclude inherited shared bytes and can only route shared proposals to the primary"
}

test_zero_item_restart_artifact_and_unsafe_destination_refusal() {
  local home payload artifact outside
  home="$TMP_ROOT/zero-items"
  mkdir -p "$home"
  write_payload "$home/empty.json" '[]' 'All optional canonical records were absent.'
  run_write "$home" "$home/empty.json" >/dev/null || fail "zero-item proposal failed"
  artifact="$home/data/memory-clerk/proposal-$PASS_DATE.md"
  assert_present "$artifact" "zero-item durable proposal was not written"
  assert_grep 'No canonical changes are proposed by this pass.' "$artifact" \
    "zero-item proposal did not state its outcome"
  for file in captain.md captain-shared.md learnings.md backlog.md done-archive.md; do
    assert_absent "$home/data/$file" "zero-item proposal manufactured absent canonical file $file"
  done

  home="$TMP_ROOT/unsafe-output"
  mkdir -p "$home/data"
  outside="$TMP_ROOT/outside-output"
  mkdir -p "$outside"
  printf 'sentinel\n' > "$outside/sentinel"
  ln -s "$outside" "$home/data/memory-clerk"
  write_payload "$home/empty.json" '[]'
  expect_failure 'path is not an ordinary directory' run_write "$home" "$home/empty.json"
  [ "$(<"$outside/sentinel")" = sentinel ] || fail "unsafe output refusal changed the external directory"
  assert_absent "$outside/proposal-$PASS_DATE.md" "unsafe output path escaped the home"
  pass "proposal artifacts survive restarts without creating canonical files and unsafe outputs are refused"
}

test_inventory_reads_only_allowlisted_durable_records
test_missing_and_bounded_inputs_preserve_visible_status
test_unsafe_and_unallowlisted_paths_are_refused
test_proposal_shape_provenance_and_output_budget
test_contradiction_supersession_and_dedup_rules
test_secondmate_never_reads_or_locally_owns_shared_captain_memory
test_zero_item_restart_artifact_and_unsafe_destination_refusal

echo '# all fm-memory-clerk tests passed'
