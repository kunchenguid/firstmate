#!/usr/bin/env bash
# Real-browser responsive, keyboard, selection, and failure-state tests for Project Cockpit.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROJECTOR="$ROOT/bin/fm-project-cockpit-snapshot.sh"
BOARD="$ROOT/bin/fm-project-cockpit-board.sh"
FIXTURES="$ROOT/tests/fixtures/project-cockpit"
TMP_ROOT=$(fm_test_tmproot fm-project-cockpit-render)
SESSION="fm-cockpit-${BASHPID:-$$}"
export CHROME_DEVTOOLS_AXI_SESSION=$SESSION
export CHROME_DEVTOOLS_AXI_CHROME_ARGS="--disable-background-networking --disable-component-update --no-first-run"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v chrome-devtools-axi >/dev/null 2>&1 || { echo "skip: chrome-devtools-axi not found"; exit 0; }

cleanup_browser() { chrome-devtools-axi stop >/dev/null 2>&1 || true; }
trap cleanup_browser EXIT HUP INT TERM
cleanup_browser

model() {  # <fixture> <output> <observed-at>
  "$PROJECTOR" --from-snapshot "$FIXTURES/$1" --observed-at "$3" > "$2"
}

assert_eval() {  # <javascript> <expected-fragment> <failure>
  local out
  out=$(chrome-devtools-axi eval "$1") || fail "$3: $out"
  assert_contains "$out" "$2" "$3: $out"
}

states=$TMP_ROOT/states.json
replacement=$TMP_ROOT/replacement.json
empty=$TMP_ROOT/empty.json
invalid=$TMP_ROOT/invalid.json
partial=$TMP_ROOT/partial.json
home=$TMP_ROOT/home
model states.json "$states" 2026-09-15T12:01:00Z
model replacement.json "$replacement" 2026-09-15T12:06:00Z
model empty.json "$empty" 2026-09-15T12:01:00Z
jq '.main_inventory.valid=false | .main_inventory.reason="inventory fixture invalid"' "$FIXTURES/empty.json" \
  | "$PROJECTOR" --from-snapshot - --observed-at 2026-09-15T12:01:00Z > "$invalid"
jq '.secondmate_current.truncated=true | .secondmate_landed.partial=["mate"]' "$FIXTURES/states.json" \
  | "$PROJECTOR" --from-snapshot - --observed-at 2026-09-15T12:10:01Z > "$partial"
FM_HOME="$home" "$BOARD" build "$states" >/dev/null || fail "could not build browser fixture"

out=$(chrome-devtools-axi open "file://$home/.lavish/project-cockpit.html") || fail "could not open Project Cockpit in Chrome: $out"
chrome-devtools-axi resize 1440 900 >/dev/null || fail "could not set desktop viewport"
assert_eval '() => ({overflow:document.documentElement.scrollWidth<=document.documentElement.clientWidth,width:innerWidth,projects:document.querySelectorAll(".project-button").length,tasks:document.querySelectorAll(".task-button").length,unknown:document.body.innerText.includes("UNKNOWN"),landmarks:{nav:!!document.querySelector("nav"),main:!!document.querySelector("main"),aside:!!document.querySelector("aside")},resources:performance.getEntriesByType("resource").map(e=>e.name)})' \
  '\"overflow\":true' "desktop viewport overflows horizontally"
assert_eval '() => ({unknown:document.body.innerText.includes("UNKNOWN"),nav:!!document.querySelector("nav"),main:!!document.querySelector("main"),aside:!!document.querySelector("aside"),unsafe:[...document.links].some(a=>a.protocol!=="https:"),resources:performance.getEntriesByType("resource").filter(e=>!e.name.startsWith("file:")).length})' \
  '\"unknown\":true' "unknown state is not visibly rendered"
assert_eval '() => ({unsafe:[...document.links].some(a=>a.protocol!=="https:"),resources:performance.getEntriesByType("resource").filter(e=>!e.name.startsWith("file:")).length})' \
  '\"unsafe\":false' "renderer created an unsafe link"
assert_eval '() => ({resources:performance.getEntriesByType("resource").filter(e=>!e.name.startsWith("file:")).length})' \
  '\"resources\":0' "renderer made an external resource request"

assert_eval '() => {const b=document.querySelector(".project-button"); b.focus(); return {project:b.dataset.projectId,focused:document.activeElement===b}}' \
  '\"focused\":true' "project navigation could not receive keyboard focus"
chrome-devtools-axi press ArrowDown >/dev/null || fail "ArrowDown could not move project focus"
assert_eval '() => ({focused:document.activeElement.dataset.projectId})' '\"focused\":\"beta\"' "ArrowDown did not move to the next project"
chrome-devtools-axi press Enter >/dev/null || fail "Enter could not activate a project"
assert_eval '() => window.fmCockpit.getState()' '\"projectId\":\"beta\"' "Enter did not select the focused project"
assert_eval '() => {const b=document.querySelector(".task-button"); b.focus(); return {focused:document.activeElement===b}}' \
  '\"focused\":true' "task navigation could not receive keyboard focus"
chrome-devtools-axi press ArrowDown >/dev/null || fail "ArrowDown could not move task focus"
assert_eval '() => ({focused:document.activeElement.dataset.taskKey})' 'queued-work' "ArrowDown did not move to the next task"
chrome-devtools-axi press Enter >/dev/null || fail "Enter could not activate a task"
assert_eval '() => window.fmCockpit.getState()' 'queued-work' "Enter did not select the focused task"
pass "desktop rendering, safe links, offline resources, landmarks, and keyboard navigation work in Chrome"

states_json=$(jq -c . "$states")
replacement_json=$(jq -c . "$replacement")
promoted_json=$(jq -c '.projects |= (map(select(.id == "beta")) + map(select(.id != "beta")))' "$states")
multiple_decisions_json=$(jq -c '(.projects[].tasks[] | select(.id == "captain-call")).decisions=["Choose deployment window","Approve rollback policy"]' "$states")
assert_eval "() => {window.fmCockpit.replacePayload($states_json); document.querySelector('[data-project-id=\"alpha\"]').click(); let b=[...document.querySelectorAll('.task-button')].find(x=>x.dataset.taskKey.startsWith('healthy-work')); b.click(); b=[...document.querySelectorAll('.task-button')].find(x=>x.dataset.taskKey.startsWith('healthy-work')); b.focus(); window.fmCockpit.replacePayload($states_json); return {state:window.fmCockpit.getState(),focused:document.activeElement.dataset.taskKey};}" \
  '\"focused\":\"healthy-work\\u001fgen-healthy-1\"' "same-generation refresh did not preserve focused task identity"
assert_eval "() => {window.fmCockpit.replacePayload($replacement_json); return window.fmCockpit.getState();}" \
  'healthy-work\\u001fgen-healthy-2' "replacement generation retained the old selection identity"
assert_eval "() => {window.fmCockpit.replacePayload($states_json); document.querySelector('[data-project-id=\"alpha\"]').click(); window.fmCockpit.replacePayload($promoted_json); return window.fmCockpit.getState().projectId + '|' + document.querySelector('.project-button').dataset.projectId;}" \
  'alpha|beta' "refresh did not adopt authoritative project priority while preserving selection"
assert_eval "() => {window.fmCockpit.replacePayload($multiple_decisions_json); document.querySelector('[data-project-id=\"alpha\"]').click(); [...document.querySelectorAll('.task-button')].find(x=>x.dataset.taskKey.startsWith('captain-call')).click(); return document.getElementById('task-detail').innerText;}" \
  'Approve rollback policy' "inspector omitted a consolidated decision summary"
assert_eval '() => document.getElementById("task-detail").innerText' \
  'Choose deployment window' "inspector omitted the other consolidated decision summary"
pass "refresh preserves selection, adopts payload order, and renders consolidated decisions"

empty_json=$(jq -c . "$empty")
invalid_json=$(jq -c . "$invalid")
partial_json=$(jq -c . "$partial")
assert_eval "() => {window.fmCockpit.replacePayload($empty_json); return {text:document.body.innerText,status:document.getElementById('inventory-warning').innerText};}" \
  'No active tasks. The snapshot is valid and empty.' "empty inventory was confused with unavailable"
assert_eval "() => {window.fmCockpit.replacePayload($invalid_json); return document.getElementById('inventory-warning').innerText;}" \
  'INVALID INVENTORY' "invalid inventory warning is missing"
assert_eval "() => {window.fmCockpit.replacePayload($partial_json); return document.getElementById('inventory-warning').innerText;}" \
  'PARTIAL INVENTORY' "partial inventory warning is missing"
assert_eval "() => document.getElementById('inventory-warning').innerText" \
  'STALE SNAPSHOT' "stale snapshot warning is missing"
pass "empty, invalid, partial, and stale browser states remain distinct"

assert_eval "() => {window.fmCockpit.replacePayload($states_json); return window.fmCockpit.getState();}" \
  '\"projectId\":\"alpha\"' "state fixture could not be restored"
chrome-devtools-axi resize 390 844 >/dev/null || fail "could not set narrow mobile viewport"
assert_eval '() => ({overflow:document.documentElement.scrollWidth<=document.documentElement.clientWidth,width:innerWidth,columns:getComputedStyle(document.querySelector(".project-list")).gridTemplateColumns,mobile:[...document.querySelectorAll(".mobile-label")].filter(e=>getComputedStyle(e).display!=="none").map(e=>e.innerText),identity:document.getElementById("task-identity").innerText})' \
  '\"overflow\":true' "narrow mobile viewport overflows horizontally"
assert_eval '() => ({mobile:[...document.querySelectorAll(".mobile-label")].filter(e=>getComputedStyle(e).display!=="none").map(e=>e.innerText)})' \
  '\"mobile\":[\"NOW\",\"DECISIONS\",\"QUEUE\"]' "mobile project drill-down labels are missing"
assert_eval '() => ({identity:document.getElementById("task-identity").innerText,columns:getComputedStyle(document.querySelector(".project-list")).gridTemplateColumns})' \
  'generation gen-call-1' "task identity is not retained in narrow detail"
assert_eval '() => {const b=document.querySelector(".task-button"); b.focus(); return document.activeElement===b;}' \
  'result: "true"' "mobile task did not receive focus"
chrome-devtools-axi press Escape >/dev/null || fail "Escape could not return from mobile task navigation"
assert_eval '() => ({project:document.activeElement.dataset.projectId})' '\"project\":\"alpha\"' "Escape did not return focus to the selected mobile project"
pass "narrow mobile layout has no horizontal overflow and preserves drill-down identity and keyboard return"
