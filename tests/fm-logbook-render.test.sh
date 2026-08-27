#!/usr/bin/env bash
# Behavior tests for the self-contained /logbook renderer under a Luxe-like
# opaque sandbox that refuses every fetch.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HELPER="$ROOT/.agents/skills/logbook/logbook.mjs"
HARNESS="$ROOT/tests/assets/logbook-render-harness.mjs"
TMP_ROOT=$(fm_test_tmproot fm-logbook-render)

command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }

make_mission() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data"
  FM_HOME="$home" node "$HELPER" start --mission "Rendered mission" >/dev/null \
    || fail "could not create the rendered mission fixture"
  printf '%s\n' "$home"
}

page_for() { find "$1/data/logbook/missions" -name index.html -type f -print | head -1; }
render() { node "$HARNESS" "$@"; }

test_page_renders_without_sibling_access() {
  local home page out
  home=$(make_mission complete-page)
  page=$(page_for "$home")
  out=$(render "$page") || fail "valid page did not render"
  printf '%s' "$out" | jq -e '
    .title == "Rendered mission"
      and .status == "Active"
      and (.updated | startswith("Updated "))
      and (.age | length > 0)
      and [.snapshot[].step] == ["done", "now", "next"]
      and .gatesMeta == "1 of 3 gates complete"
      and (.gateTitles | length) == 3
      and .milestoneTitles == ["Mission started"]
      and .notice == ""
      and .fetches == 0
  ' >/dev/null || fail "self-contained page omitted progress or attempted a sandboxed sibling fetch: $out"
  case "$out" in *%*) fail "rendered page exposed a fake percentage" ;; esac
  pass "Luxe-like opaque rendering succeeds without any sibling-resource request"
}

test_missing_and_malformed_embedded_data_show_stale_state() {
  local home page missing malformed semantic reordered out
  home=$(make_mission stale-page)
  page=$(page_for "$home")
  missing="$home/missing.html"
  malformed="$home/malformed.html"
  semantic="$home/semantic-malformed.html"
  reordered="$home/reordered.html"
  perl -0777 -pe 's|<script id="firstmate-logbook-data" type="application/json">.*?</script>||s' "$page" > "$missing"
  out=$(render "$missing") || fail "missing-data shell did not remain usable"
  printf '%s' "$out" | jq -e '
    .status == "Data stale"
      and (.notice | contains("Progress data is unavailable or stale"))
      and (.notice | contains("embedded progress data is missing"))
  ' >/dev/null || fail "missing embedded data did not show the explicit stale state: $out"

  perl -0777 -pe 's|(<script id="firstmate-logbook-data" type="application/json">).*?(</script>)|$1\n{bad-json\n$2|s' "$page" > "$malformed"
  out=$(render "$malformed") || fail "malformed-data shell did not remain usable"
  printf '%s' "$out" | jq -e '
    .status == "Data stale"
      and (.notice | contains("Progress data is unavailable or stale"))
  ' >/dev/null || fail "malformed embedded data did not show the explicit stale state: $out"

  node - "$page" "$semantic" <<'NODE'
const fs = require("fs");
const [source, destination] = process.argv.slice(2);
fs.writeFileSync(destination, fs.readFileSync(source, "utf8").replace('"state": "passed"', '"state": "invented"'));
NODE
  out=$(render "$semantic") || fail "semantically malformed-data shell did not remain usable"
  printf '%s' "$out" | jq -e '
    .status == "Data stale"
      and (.notice | contains("Progress data is unavailable or stale"))
      and (.notice | contains("invalid completion gates"))
  ' >/dev/null || fail "semantically malformed embedded data did not show the explicit stale state: $out"

  node - "$page" "$reordered" <<'NODE'
const fs = require("fs");
const [source, destination] = process.argv.slice(2);
const html = fs.readFileSync(source, "utf8");
const match = html.match(/(<script id="firstmate-logbook-data" type="application\/json">\n)([\s\S]*?)(\n<\/script>)/);
const payload = JSON.parse(match[2]);
payload.milestones.push({...payload.milestones[0], id: "20200101T000000Z", fingerprint: "a".repeat(64), at: "2020-01-01T00:00:00.000Z"});
[payload.milestones[0], payload.milestones[1]] = [payload.milestones[1], payload.milestones[0]];
fs.writeFileSync(destination, `${html.slice(0, match.index)}${match[1]}${JSON.stringify(payload, null, 2)}${match[3]}${html.slice(match.index + match[0].length)}`);
NODE
  out=$(render "$reordered") || fail "reordered-data shell did not remain usable"
  printf '%s' "$out" | jq -e '
    .status == "Data stale"
      and (.notice | contains("invalid milestone history"))
  ' >/dev/null || fail "reordered milestones did not show the explicit stale state: $out"
  pass "missing and malformed embedded data leave a usable shell with a visible stale warning"
}

test_manual_refresh_reloads_same_page_and_reads_new_payload() {
  local home page before update after refresh
  home=$(make_mission refresh)
  page=$(page_for "$home")
  before=$(render "$page") || fail "initial page did not render"
  update="$home/update.json"
  cat > "$update" <<'JSON'
{
  "kind": "verification",
  "title": "Refresh proof passed",
  "summary": "The same Luxe page can reload newly embedded progress.",
  "snapshot": {
    "done": "The refresh proof is complete.",
    "now": "The validated result is visible.",
    "next": "Continue with the next mission gate."
  },
  "gates": [
    {
      "id": "verification",
      "label": "Outcome verified",
      "state": "passed",
      "evidence": [{"label": "Browser", "value": "Same-page reload evidence"}]
    }
  ],
  "evidence": [{"label": "Browser", "value": "Same-page reload evidence"}]
}
JSON
  FM_HOME="$home" node "$HELPER" update --mission "Rendered mission" --input "$update" >/dev/null \
    || fail "could not publish the refreshed page"
  refresh=$(render "$page" --refresh) || fail "manual refresh action did not run"
  after=$(render "$page") || fail "reloaded page did not render"
  printf '%s' "$before" | jq -e '.snapshot[0].text == "The mission and its reporting page are established."' >/dev/null \
    || fail "initial page did not carry its initial snapshot"
  printf '%s' "$refresh" | jq -e '
    .reloads == 1 and .fetches == 0 and (.refreshHref | contains("?refresh="))
  ' >/dev/null || fail "Refresh progress did not cache-bust the same page without a sibling fetch: $refresh"
  printf '%s' "$after" | jq -e '
    .snapshot[0].text == "The refresh proof is complete."
      and .milestoneTitles[0] == "Refresh proof passed"
      and (.milestoneTitles | length) == 2
  ' >/dev/null || fail "reloaded page did not read the newly embedded payload: $after"
  pass "manual refresh reloads the existing page and shows the atomically embedded update"
}

test_payload_text_is_rendered_as_text() {
  local home page update out
  home=$(make_mission text-safety)
  page=$(page_for "$home")
  update="$home/update.json"
  cat > "$update" <<'JSON'
{
  "kind": "stage-change",
  "title": "Literal <b>markup</b> recorded",
  "summary": "The renderer must show literal markup characters.",
  "snapshot": {
    "done": "Literal <img src=x> text is retained.",
    "now": "The safe renderer is active.",
    "next": "Verify exact text output."
  },
  "evidence": [{"label": "Literal", "value": "</script><b>not markup</b>"}]
}
JSON
  FM_HOME="$home" node "$HELPER" update --mission "Rendered mission" --input "$update" >/dev/null \
    || fail "safe literal-text update was refused"
  out=$(render "$page") || fail "literal-text page did not render"
  printf '%s' "$out" | jq -e '
    .snapshot[0].text == "Literal <img src=x> text is retained."
      and .milestoneTitles[0] == "Literal <b>markup</b> recorded"
  ' >/dev/null || fail "payload markup characters were not retained as literal text: $out"
  pass "embedded captain values render as text rather than browser markup"
}

test_page_renders_without_sibling_access
test_missing_and_malformed_embedded_data_show_stale_state
test_manual_refresh_reloads_same_page_and_reads_new_payload
test_payload_text_is_rendered_as_text
