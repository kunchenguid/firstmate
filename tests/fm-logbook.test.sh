#!/usr/bin/env bash
# Behavior tests for the /logbook helper's public command interface.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HELPER="$ROOT/.agents/skills/logbook/logbook.mjs"
TMP_ROOT=$(fm_test_tmproot fm-logbook)

command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }

run_logbook() {  # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" node "$HELPER" "$@"
}

make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state"
  printf '%s\n' "$home"
}

file_mode() { stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"; }
file_inode() { stat -f '%i' "$1" 2>/dev/null || stat -c '%i' "$1"; }
page_for() { find "$1/data/logbook/missions" -name index.html -type f -print | head -1; }

extract_payload() {  # <page>
  node - "$1" <<'NODE'
const fs = require("fs");
const html = fs.readFileSync(process.argv[2], "utf8");
const match = html.match(/<script id="firstmate-logbook-data" type="application\/json">\n([\s\S]*?)\n<\/script>/);
if (!match) process.exit(1);
process.stdout.write(match[1] + "\n");
NODE
}

shell_hash() {  # <page>
  perl -0777 -pe 's/<!-- FIRSTMATE_LOGBOOK_PAYLOAD_BEGIN -->.*?<!-- FIRSTMATE_LOGBOOK_PAYLOAD_END -->/<PAYLOAD>/s' "$1" \
    | shasum -a 256 | awk '{print $1}'
}

write_stage_update() {
  cat > "$1" <<JSON
{
  "kind": "stage-change",
  "title": "$2",
  "summary": "The mission moved to a proven new stage.",
  "snapshot": {
    "done": "$3",
    "now": "The next bounded stage is active.",
    "next": "Verify the bounded result."
  },
  "gates": [
    {
      "id": "mission-outcome",
      "label": "Mission outcome achieved",
      "state": "$4",
      "evidence": [{"label": "Result", "value": "Bounded stage evidence"}]
    }
  ],
  "evidence": [{"label": "Result", "value": "Bounded stage evidence"}]
}
JSON
}

test_safe_creation_and_atomic_embedded_update() {
  local home out page registration before_shell before_inode after_inode update
  home=$(make_home safe-create)
  out=$(run_logbook "$home" start --mission "Release mission") || fail "safe mission creation failed"
  page=$(page_for "$home")
  registration="$home/data/logbook/active.json"
  assert_present "$page" "start did not create the self-contained HTML page"
  assert_present "$registration" "start did not create the active registration"
  [ "$(find "$(dirname "$page")" -type f | wc -l | tr -d ' ')" = 1 ] \
    || fail "mission directory contains a sibling payload instead of one self-contained page"
  assert_contains "$out" "created: " "start did not report the page it created"
  [ "$(printf '%s\n' "$out" | awk '/^created: / {sub(/^created: /, ""); print}')" -ef "$page" ] \
    || fail "start reported a different page from the one it created"
  [ "$(file_mode "$page")" = 600 ] || fail "page mode is not private"
  [ "$(file_mode "$registration")" = 600 ] || fail "registration mode is not private"
  jq -e --arg page "${page#"$home/"}" '
    .schema == "firstmate-logbook-active.v1" and .page == $page and (has("payload") | not)
  ' "$registration" >/dev/null || fail "registration does not carry exactly one confined page path"
  extract_payload "$page" | jq -e '.schema == "firstmate-logbook.v1" and .mission.title == "Release mission"' >/dev/null \
    || fail "page does not carry a valid embedded mission payload"

  before_shell=$(shell_hash "$page")
  before_inode=$(file_inode "$page")
  update="$home/update.json"
  write_stage_update "$update" "Implementation stage complete" "The bounded implementation stage is complete." active
  run_logbook "$home" update --mission "Release mission" --input "$update" >/dev/null \
    || fail "valid update failed"
  after_inode=$(file_inode "$page")
  [ "$before_inode" != "$after_inode" ] || fail "update rewrote the page in place instead of replacing it atomically"
  [ "$(shell_hash "$page")" = "$before_shell" ] || fail "update changed bytes outside the delimited payload block"
  [ -z "$(find "$(dirname "$page")" -name '*.tmp' -print)" ] || fail "atomic update left a staged file behind"
  extract_payload "$page" | jq -e '
    .snapshot.done == "The bounded implementation stage is complete." and (.milestones | length) == 2
  ' >/dev/null || fail "valid update did not publish the new embedded snapshot and milestone"
  pass "start creates one private page and update atomically changes only its delimited payload"
}

test_malformed_and_invalid_updates_preserve_current_page() {
  local home page before out rc bad
  home=$(make_home malformed)
  run_logbook "$home" start --mission "Validation mission" >/dev/null || fail "fixture start failed"
  page=$(page_for "$home")
  before=$(shasum -a 256 "$page" | awk '{print $1}')
  bad="$home/bad.json"
  printf '{not-json\n' > "$bad"
  set +e
  out=$(run_logbook "$home" update --mission "Validation mission" --input "$bad" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "malformed JSON was accepted"
  assert_contains "$out" "not valid JSON" "malformed refusal did not explain the problem"
  [ "$(shasum -a 256 "$page" | awk '{print $1}')" = "$before" ] || fail "malformed JSON changed the page"

  cat > "$bad" <<'JSON'
{
  "kind": "verification",
  "title": "Nearly 90% complete",
  "summary": "This is an unsupported progress claim.",
  "snapshot": {"done": "Some work", "now": "More work", "next": "Finish"},
  "evidence": [{"label": "Guess", "value": "90%"}]
}
JSON
  set +e
  out=$(run_logbook "$home" update --mission "Validation mission" --input "$bad" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "an unsupported percentage was accepted"
  assert_contains "$out" "unsupported progress claim" "percentage refusal did not name the safety boundary"
  [ "$(shasum -a 256 "$page" | awk '{print $1}')" = "$before" ] || fail "rejected percentage changed the page"
  pass "malformed JSON and fake progress claims refuse without touching the page"
}

test_milestones_are_retained_newest_first() {
  local home page update first_id second_id
  home=$(make_home retention)
  run_logbook "$home" start --mission "Retention mission" >/dev/null || fail "fixture start failed"
  page=$(page_for "$home")
  first_id=$(extract_payload "$page" | jq -r '.milestones[0].id')
  update="$home/update.json"
  write_stage_update "$update" "First stage complete" "The first bounded stage is complete." active
  run_logbook "$home" update --mission "Retention mission" --input "$update" >/dev/null || fail "first update failed"
  write_stage_update "$update" "Second stage complete" "The second bounded stage is complete." active
  run_logbook "$home" update --mission "Retention mission" --input "$update" >/dev/null || fail "second update failed"
  second_id=$(extract_payload "$page" | jq -r '.milestones[0].id')
  [ "$second_id" != "$first_id" ] || fail "new update reused the initial milestone id"
  extract_payload "$page" | jq -e --arg first "$first_id" '
    (.milestones | length) == 3
      and .milestones[0].title == "Second stage complete"
      and .milestones[1].title == "First stage complete"
      and .milestones[2].id == $first
  ' >/dev/null || fail "newest-first update dropped or reordered milestone history"
  pass "meaningful updates retain all embedded milestone history newest first"
}

test_large_retained_history_remains_readable_and_mutable() {
  local home page update
  home=$(make_home large-history)
  run_logbook "$home" start --mission "Large history mission" >/dev/null || fail "fixture start failed"
  page=$(page_for "$home")
  node - "$page" <<'NODE'
const crypto = require("crypto");
const fs = require("fs");
const page = process.argv[2];
const html = fs.readFileSync(page, "utf8");
const match = html.match(/(<script id="firstmate-logbook-data" type="application\/json">\n)([\s\S]*?)(\n<\/script>)/);
const payload = JSON.parse(match[2]);
const latest = Date.now();
payload.milestones = Array.from({ length: 1800 }, (_, index) => {
  const at = new Date(latest - index * 1000).toISOString();
  return {
    id: at.replace(/[-:]/g, "").replace(".000", ""),
    at,
    kind: "verification",
    title: "Retained evidence",
    summary: "Retained mission evidence. ".repeat(20),
    evidence: [{ label: "Evidence", value: "Retained detail ".repeat(60) }],
    fingerprint: crypto.createHash("sha256").update(String(index)).digest("hex"),
  };
});
fs.writeFileSync(page, `${html.slice(0, match.index)}${match[1]}${JSON.stringify(payload, null, 2)}${match[3]}${html.slice(match.index + match[0].length)}`);
NODE
  [ "$(wc -c < "$page" | tr -d ' ')" -gt $((2 * 1024 * 1024)) ] || fail "large-history fixture did not exceed two MiB"
  run_logbook "$home" active | grep -q '^active: Large history mission$' || fail "active could not read retained history larger than two MiB"
  update="$home/update.json"
  write_stage_update "$update" "Large history advanced" "The retained history accepted a new stage." active
  run_logbook "$home" update --mission "Large history mission" --input "$update" >/dev/null || fail "update could not read retained history larger than two MiB"
  extract_payload "$page" | jq -e '(.milestones | length) == 1801 and .milestones[0].title == "Large history advanced"' >/dev/null \
    || fail "large retained history did not preserve its new update"
  pass "retained history larger than two MiB remains readable and mutable"
}

test_path_like_mission_is_confined() {
  local home out page resolved_home resolved_page
  home=$(make_home confinement)
  out=$(run_logbook "$home" start --mission "../../outside mission") || fail "safe slugging rejected a path-like title"
  page=$(printf '%s\n' "$out" | awk '/^created: / {sub(/^created: /, ""); print}')
  resolved_home=$(cd "$home" && pwd -P)
  resolved_page=$(cd "$(dirname "$page")" && printf '%s/%s\n' "$(pwd -P)" "$(basename "$page")")
  case "$resolved_page" in
    "$resolved_home"/data/logbook/missions/*/index.html) ;;
    *) fail "path-like mission escaped the private logbook root: $resolved_page" ;;
  esac
  [ ! -e "$TMP_ROOT/outside mission" ] || fail "path-like mission created an outside file"
  pass "mission text cannot escape the private logbook path"
}

test_symlinked_mission_directory_is_refused() {
  local home page dir outside update before out rc
  home=$(make_home symlink-confinement)
  run_logbook "$home" start --mission "Symlink mission" >/dev/null || fail "fixture start failed"
  page=$(page_for "$home")
  dir=$(dirname "$page")
  outside="$TMP_ROOT/outside-mission"
  mkdir "$outside"
  mv "$dir/index.html" "$outside/index.html"
  rmdir "$dir"
  ln -s "$outside" "$dir"
  update="$home/update.json"
  write_stage_update "$update" "Unsafe stage" "The confined page must remain unchanged." active
  before=$(shasum -a 256 "$outside/index.html" | awk '{print $1}')
  set +e
  out=$(run_logbook "$home" update --mission "Symlink mission" --input "$update" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "symlinked mission directory was accepted"
  assert_contains "$out" "unsafe directory component" "symlink refusal did not name the unsafe path"
  [ "$(shasum -a 256 "$outside/index.html" | awk '{print $1}')" = "$before" ] || fail "symlinked path changed an outside page"
  pass "intermediate symlinks cannot escape the logbook root"
}

test_one_live_writer_refuses_a_competing_update() {
  local home page before update lock out rc
  home=$(make_home writer)
  run_logbook "$home" start --mission "Writer mission" >/dev/null || fail "fixture start failed"
  page=$(page_for "$home")
  before=$(shasum -a 256 "$page" | awk '{print $1}')
  update="$home/update.json"
  write_stage_update "$update" "Competing stage" "A competing stage finished." active
  lock="$home/data/logbook/.writer.lock"
  mkdir "$lock"
  run_logbook "$home" update --mission "Writer mission" --input "$update" >/dev/null \
    || fail "an ownerless interrupted lock was not recovered"
  [ ! -e "$lock" ] || fail "recovered ownerless lock was not released"
  before=$(shasum -a 256 "$page" | awk '{print $1}')
  mkdir "$lock"
  printf '{}\n' > "$lock/owner.json"
  set +e
  out=$(run_logbook "$home" update --mission "Writer mission" --input "$update" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a writer with an invalid owner record was displaced"
  assert_contains "$out" "ownership is indeterminate" "invalid owner refusal did not name the conflict"
  [ "$(shasum -a 256 "$page" | awk '{print $1}')" = "$before" ] || fail "invalid owner record changed the page"
  printf '{"token":"0123456789abcdef0123456789abcdef","pid":%s,"claimed_at":"2026-08-27T00:00:00Z"}\n' "$$" > "$lock/owner.json"
  set +e
  out=$(run_logbook "$home" update --mission "Writer mission" --input "$update" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a competing live writer was accepted"
  assert_contains "$out" "another logbook writer is active" "writer refusal did not name the conflict"
  [ "$(shasum -a 256 "$page" | awk '{print $1}')" = "$before" ] || fail "competing writer changed the page"
  rm -rf "$lock"
  pass "ownerless interrupted locks recover while live writers retain ownership"
}

test_start_recovers_an_unregistered_active_page() {
  local home helper out page registration
  home=$(make_home start-recovery)
  helper="$home/fail-active-publication.sh"
  cat > "$helper" <<'SH'
#!/usr/bin/env bash
if [ "$2" = publish ] && [ "$4" = data/logbook/active.json ]; then
  exit 1
fi
exec python3 "$@"
SH
  chmod 700 "$helper"
  set +e
  out=$(FM_LOGBOOK_PYTHON="$helper" run_logbook "$home" start --mission "Interrupted start mission" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "fixture start unexpectedly published its registration"
  page=$(page_for "$home")
  registration="$home/data/logbook/active.json"
  assert_present "$page" "interrupted start did not publish its page"
  assert_absent "$registration" "interrupted start unexpectedly left a registration"
  out=$(run_logbook "$home" start --mission "Interrupted start mission") || fail "retry did not recover the unregistered active page"
  assert_contains "$out" "resumed: " "recovered start did not report the existing page"
  assert_present "$registration" "recovered start did not restore the active registration"
  jq -e --arg page "${page#"$home/"}" '.page == $page' "$registration" >/dev/null \
    || fail "recovered start registered a different page"
  run_logbook "$home" active | grep -q '^active: Interrupted start mission$' || fail "recovered start did not restore an active mission"
  pass "start retries register an already-published active page"
}

test_vanished_writer_lock_retries_claim() {
  local home helper page
  home=$(make_home vanished-writer)
  helper="$home/vanish-first-claim.sh"
  cat > "$helper" <<'SH'
#!/usr/bin/env bash
if [ "$2" = claim ] && [ ! -e "$3/claim-was-contended" ]; then
  touch "$3/claim-was-contended"
  exit 17
fi
exec python3 "$@"
SH
  chmod 700 "$helper"
  FM_LOGBOOK_PYTHON="$helper" run_logbook "$home" start --mission "Vanished writer mission" >/dev/null \
    || fail "start did not retry a vanished writer lock"
  page=$(page_for "$home")
  assert_present "$page" "retried writer claim did not create its mission page"
  pass "a vanished writer lock retries the atomic claim"
}

test_duplicate_update_is_refused() {
  local home page update before out rc
  home=$(make_home duplicate)
  run_logbook "$home" start --mission "Duplicate mission" >/dev/null || fail "fixture start failed"
  page=$(page_for "$home")
  update="$home/update.json"
  write_stage_update "$update" "Accepted stage" "The qualifying stage is complete." active
  run_logbook "$home" update --mission "Duplicate mission" --input "$update" >/dev/null || fail "first update failed"
  before=$(shasum -a 256 "$page" | awk '{print $1}')
  set +e
  out=$(run_logbook "$home" update --mission "Duplicate mission" --input "$update" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "duplicate update was accepted"
  assert_contains "$out" "duplicate logbook update refused" "duplicate refusal did not explain the conflict"
  [ "$(shasum -a 256 "$page" | awk '{print $1}')" = "$before" ] || fail "duplicate update changed the page"
  pass "duplicate qualifying updates are refused before publication"
}

test_non_immediate_duplicate_update_is_refused() {
  local home page first second before out rc
  home=$(make_home non-immediate-duplicate)
  run_logbook "$home" start --mission "History duplicate mission" >/dev/null || fail "fixture start failed"
  page=$(page_for "$home")
  first="$home/first.json"
  second="$home/second.json"
  write_stage_update "$first" "First accepted stage" "The first qualifying stage is complete." active
  write_stage_update "$second" "Second accepted stage" "The second qualifying stage is complete." active
  run_logbook "$home" update --mission "History duplicate mission" --input "$first" >/dev/null || fail "first update failed"
  run_logbook "$home" update --mission "History duplicate mission" --input "$second" >/dev/null || fail "second update failed"
  before=$(shasum -a 256 "$page" | awk '{print $1}')
  set +e
  out=$(run_logbook "$home" update --mission "History duplicate mission" --input "$first" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "non-immediate duplicate update was accepted"
  assert_contains "$out" "duplicate logbook update refused" "history duplicate refusal did not explain the conflict"
  [ "$(shasum -a 256 "$page" | awk '{print $1}')" = "$before" ] || fail "history duplicate changed the page"
  pass "retained milestone fingerprints refuse non-immediate duplicates"
}

test_reordered_milestones_are_refused() {
  local home page update before out rc
  home=$(make_home malformed-history)
  run_logbook "$home" start --mission "History validation mission" >/dev/null || fail "fixture start failed"
  page=$(page_for "$home")
  update="$home/update.json"
  write_stage_update "$update" "Later stage" "The later stage is complete." active
  run_logbook "$home" update --mission "History validation mission" --input "$update" >/dev/null || fail "fixture update failed"
  node - "$page" <<'NODE'
const fs = require("fs");
const page = process.argv[2];
const html = fs.readFileSync(page, "utf8");
const match = html.match(/(<script id="firstmate-logbook-data" type="application\/json">\n)([\s\S]*?)(\n<\/script>)/);
const payload = JSON.parse(match[2]);
[payload.milestones[0], payload.milestones[1]] = [payload.milestones[1], payload.milestones[0]];
fs.writeFileSync(page, `${html.slice(0, match.index)}${match[1]}${JSON.stringify(payload, null, 2)}${match[3]}${html.slice(match.index + match[0].length)}`);
NODE
  before=$(shasum -a 256 "$page" | awk '{print $1}')
  set +e
  out=$(run_logbook "$home" update --mission "History validation mission" --input "$update" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "reordered milestones were accepted"
  assert_contains "$out" "not newest first" "reordered milestone refusal did not name the invariant"
  [ "$(shasum -a 256 "$page" | awk '{print $1}')" = "$before" ] || fail "malformed history was republished"
  pass "malformed milestone ordering is refused before publication"
}

test_completed_close_records_outcome_and_preserves_page() {
  local home page input
  home=$(make_home close)
  run_logbook "$home" start --mission "Closing mission" >/dev/null || fail "fixture start failed"
  page=$(page_for "$home")
  input="$home/close.json"
  cat > "$input" <<'JSON'
{
  "kind": "close",
  "title": "Mission completed",
  "summary": "The accepted outcome is finished and verified.",
  "snapshot": {
    "done": "The mission outcome is complete.",
    "now": "The durable result is available.",
    "next": "No further mission work is planned."
  },
  "gates": [
    {"id": "mission-start", "label": "Mission started", "state": "passed", "evidence": [{"label": "Mission", "value": "Closing mission"}]},
    {"id": "mission-outcome", "label": "Mission outcome achieved", "state": "passed", "evidence": [{"label": "Result", "value": "Accepted outcome"}]},
    {"id": "verification", "label": "Outcome verified", "state": "passed", "evidence": [{"label": "Test", "value": "Focused suite passed"}]}
  ],
  "outcome": "completed",
  "final_outcome": "The accepted outcome is available with passing evidence.",
  "evidence": [{"label": "Test", "value": "Focused suite passed"}]
}
JSON
  run_logbook "$home" close --mission "Closing mission" --input "$input" >/dev/null || fail "completed close failed"
  assert_present "$page" "close deleted the durable page"
  assert_absent "$home/data/logbook/active.json" "close left the mission registered active"
  extract_payload "$page" | jq -e '.status == "closed" and .outcome == "completed" and .milestones[0].kind == "close"' >/dev/null \
    || fail "close did not publish its embedded final outcome"
  pass "close records the final outcome, preserves the page, and retires active registration"
}

test_close_recovers_a_closed_page_with_stale_registration() {
  local home page input helper out rc
  home=$(make_home close-recovery)
  run_logbook "$home" start --mission "Interrupted close mission" >/dev/null || fail "fixture start failed"
  page=$(page_for "$home")
  input="$home/close.json"
  cat > "$input" <<'JSON'
{
  "kind": "close",
  "title": "Mission completed",
  "summary": "The accepted outcome is finished and verified.",
  "snapshot": {
    "done": "The mission outcome is complete.",
    "now": "The durable result is available.",
    "next": "No further mission work is planned."
  },
  "gates": [
    {"id": "mission-start", "label": "Mission started", "state": "passed", "evidence": [{"label": "Mission", "value": "Interrupted close mission"}]},
    {"id": "mission-outcome", "label": "Mission outcome achieved", "state": "passed", "evidence": [{"label": "Result", "value": "Accepted outcome"}]},
    {"id": "verification", "label": "Outcome verified", "state": "passed", "evidence": [{"label": "Test", "value": "Focused suite passed"}]}
  ],
  "outcome": "completed",
  "final_outcome": "The accepted outcome is available with passing evidence.",
  "evidence": [{"label": "Test", "value": "Focused suite passed"}]
}
JSON
  helper="$home/fail-active-removal.sh"
  cat > "$helper" <<'SH'
#!/usr/bin/env bash
if [ "$2" = remove ] && [ "$4" = data/logbook/active.json ]; then
  exit 1
fi
exec python3 "$@"
SH
  chmod 700 "$helper"
  set +e
  out=$(FM_LOGBOOK_PYTHON="$helper" run_logbook "$home" close --mission "Interrupted close mission" --input "$input" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "fixture close unexpectedly removed its active registration"
  assert_present "$home/data/logbook/active.json" "interrupted close did not retain the active registration"
  extract_payload "$page" | jq -e '.status == "closed"' >/dev/null || fail "interrupted close did not publish the closed page"
  run_logbook "$home" close --mission "Interrupted close mission" --input "$input" >/dev/null || fail "retry did not recover the stale active registration"
  assert_absent "$home/data/logbook/active.json" "recovered close left the stale active registration"
  pass "close retries retire a stale registration after page publication"
}

test_safe_creation_and_atomic_embedded_update
test_malformed_and_invalid_updates_preserve_current_page
test_milestones_are_retained_newest_first
test_large_retained_history_remains_readable_and_mutable
test_path_like_mission_is_confined
test_symlinked_mission_directory_is_refused
test_one_live_writer_refuses_a_competing_update
test_start_recovers_an_unregistered_active_page
test_vanished_writer_lock_retries_claim
test_duplicate_update_is_refused
test_non_immediate_duplicate_update_is_refused
test_reordered_milestones_are_refused
test_completed_close_records_outcome_and_preserves_page
test_close_recovers_a_closed_page_with_stale_registration
