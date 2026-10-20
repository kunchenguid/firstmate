#!/usr/bin/env bash
# Contract: bin/fm-reports-page.sh builds the offline reports page of one home.
#
# The suite covers the generator's published contract - one page per home, a
# stable anchor per report, publish only on change, a link that proves its
# report exists - plus two regressions that cost a machine its memory once:
#
#   - A fenced code block must render. jq 1.6 grows without bound on a gsub
#     whose pattern can match the empty string, which "^[[:space:]]*" does, and
#     the renderer used to strip a fence line's indent exactly that way. Every
#     report with a fence then took the build down with "cannot allocate
#     memory", so the fence cases below are bounded rather than merely checked:
#     a regression does not fail fast, it consumes the host.
#   - A report's text must never be substituted into the page as markup or as a
#     page slot, and the payload must stay parsable JSON.
#
# It also covers the page's second kind of content: this home's recorded captain
# decisions. The cases below fix what the feature actually promises - a decision
# shown with the report of the task it gated, a decision that gated no report
# shown as its own searchable, anchored entry, every decision of one task shown
# newest first, one decision reached through two sources shown once, and a home
# with no archive files or another backlog store still getting its page with the
# gap named rather than hidden.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the renderer)"; exit 0; }
command -v perl >/dev/null 2>&1 || { echo "skip: perl not found (required by the page injection)"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "skip: node not found (required by the page behavior check)"; exit 0; }

PAGE_SH="$ROOT/bin/fm-reports-page.sh"

# A fixture home. Reports are added by write_report, so a case says only what
# its own reports contain.
new_home() {
  local home
  home=$(fm_test_tmproot fm-reports-page) || fail "cannot create a fixture home"
  mkdir -p "$home/data" "$home/state" || fail "cannot create the fixture home layout"
  printf '%s\n' "$home"
}

# A fixture home that also carries the tracked backlog configuration, so the
# decision sources resolve the way they do in a real home.
decision_home() {
  local home
  home=$(new_home)
  fm_test_tasks_toml "$home/.tasks.toml" || fail "cannot write the fixture .tasks.toml"
  printf '%s\n' "$home"
}

write_backlog() {  # <home> <markdown>
  printf '%s\n' "$2" > "$1/data/backlog.md" || fail "cannot write data/backlog.md"
}

write_note_archive() {  # <home> <markdown>
  printf '%s\n' "$2" > "$1/data/note-archive.md" || fail "cannot write data/note-archive.md"
}

write_report() {  # <home> <id> <markdown>
  local home=$1 id=$2 md=$3
  mkdir -p "$home/data/$id" || fail "cannot create data/$id"
  printf '%s\n' "$md" > "$home/data/$id/report.md" || fail "cannot write data/$id/report.md"
}

build() {  # <home> -> stdout of the build, status preserved
  local home=$1
  FM_HOME="$home" bash "$PAGE_SH" build
}

# The fence cases run bounded: the regression they guard against exhausts
# memory instead of failing, and an unbounded run would take the host with it.
build_bounded() {  # <home>
  local home=$1
  FM_HOME="$home" fm_run_timed 120 bash "$PAGE_SH" build
}

# The payload, read back the way the page's own script reads it.
payload_of() {  # <page>
  sed -n '/<script id="reports-data" type="application\/json">/,/<\/script>/p' "$1" | sed '1d;$d'
}

# The payload's entries, which is what the page lists.
entries_of() {  # <page>
  payload_of "$1" | jq '.entries'
}

# One rendered entry's html, by id.
html_of() {  # <page> <id>
  payload_of "$1" | jq -r --arg id "$2" '.entries[] | select(.id == $id) | .html'
}

fallback_anchor_of() {  # <page> <initial hash>
  node - "$1" "$2" <<'NODE'
const fs = require("fs");
const vm = require("vm");
const page = fs.readFileSync(process.argv[2], "utf8");
const payload = page.match(/<script id="reports-data" type="application\/json">([\s\S]*?)<\/script>/)[1];
const script = page.match(/<script>\n([\s\S]*?)<\/script>/)[1];
function element() {
  return {
    children: [], classList: { add() {}, remove() {}, toggle() {}, contains() { return false; } },
    addEventListener() {}, append(...items) { this.children.push(...items); },
    setAttribute() {}, setPointerCapture() {}, releasePointerCapture() {},
    focus() {}, select() {}, style: { setProperty() {}, removeProperty() {} },
    set textContent(value) { this._text = value; }, get textContent() { return this._text || ""; }
  };
}
const ids = ["reports-data", "q", "sort", "count", "list", "report", "where", "scroll", "grip", "scrim", "gaps", "toggle", "prev", "next"];
const elements = Object.fromEntries(ids.map(id => [id, element()]));
elements["reports-data"].textContent = payload;
elements.sort.value = "new";
elements.q.value = "";
let redirected = "";
const document = {
  body: element(), documentElement: element(), title: "",
  getElementById(id) { return elements[id]; },
  createElement() { return element(); }, addEventListener() {}
};
const context = {
  document, location: { hash: process.argv[3], replace(value) { redirected = value; } },
  window: { addEventListener() {}, matchMedia() { return { matches: false }; }, innerWidth: 1000 },
  localStorage: { getItem() { return null; }, setItem() {} },
  getComputedStyle() { return { getPropertyValue() { return ""; } }; },
  encodeURIComponent, decodeURIComponent
};
vm.runInNewContext(script, context);
if (!redirected) throw new Error("page did not redirect its unknown or empty anchor");
process.stdout.write(redirected);
NODE
}

# One entry's searchable text, derived exactly as the page's own script derives
# it, so a search case is proved against the built page and not against a
# report's source text.
searchable_of() {  # <page> <id>
  html_of "$1" "$2" | jq -Rrs '
    gsub("<[^>]*>"; " ")
    | gsub("&lt;"; "<") | gsub("&gt;"; ">")
    | gsub("&quot;"; "\"") | gsub("&#39;"; "'"'"'")
    | gsub("&amp;"; "&")
    | ascii_downcase'
}

test_build_publishes_every_report() {
  local home page out ids
  home=$(new_home)
  write_report "$home" alpha '# Alpha

Erste Zeile.'
  write_report "$home" beta '# Beta

Zweite Zeile.'
  out=$(build "$home") || fail "build failed: $out"
  assert_contains "$out" 'page: ' "build must print the published page path"
  assert_contains "$out" 'reports: 2' "build must print the number of reports"
  page="$home/state/reports.html"
  assert_present "$page" "build must publish the page"
  assert_equals 2 "$(entries_of "$page" | jq 'length')" "the page must carry both reports"
  ids=$(entries_of "$page" | jq -r '[.[].id] | sort | join(",")')
  assert_equals 'alpha,beta' "$ids" "every report id must reach the page as its anchor"
  pass "build publishes every report of the home"
}

test_build_sorts_newest_first() {
  local home page
  home=$(new_home)
  write_report "$home" older '# Older'
  write_report "$home" newer '# Newer'
  touch -d '2026-01-01 10:00' "$home/data/older/report.md" 2>/dev/null \
    || touch -t 202601011000 "$home/data/older/report.md" \
    || fail "cannot age a fixture report"
  touch -d '2026-06-01 10:00' "$home/data/newer/report.md" 2>/dev/null \
    || touch -t 202606011000 "$home/data/newer/report.md" \
    || fail "cannot age a fixture report"
  build "$home" >/dev/null || fail "build failed"
  page="$home/state/reports.html"
  assert_equals 'newer' "$(entries_of "$page" | jq -r '.[0].id')" \
    "the newest report must come first"
  pass "the page lists the newest report first"
}

test_rebuild_without_a_change_leaves_the_page_alone() {
  local home page before out
  home=$(new_home)
  write_report "$home" alpha '# Alpha'
  build "$home" >/dev/null || fail "first build failed"
  page="$home/state/reports.html"
  before=$(fm_test_tmproot fm-reports-page-copy)/page.html
  cp "$page" "$before" || fail "cannot copy the published page"
  out=$(build "$home") || fail "second build failed: $out"
  assert_contains "$out" 'unchanged: ' "an unchanged rebuild must say so"
  assert_contains "$out" 'reports: 1' "an unchanged rebuild still reports the count"
  cmp -s "$before" "$page" || fail "an unchanged rebuild must not rewrite the page"
  pass "a rebuild with no change leaves the published page untouched"
}

test_changed_report_republishes_the_page() {
  local home out
  home=$(new_home)
  write_report "$home" alpha '# Alpha'
  build "$home" >/dev/null || fail "first build failed"
  write_report "$home" alpha '# Alpha

Ein neuer Satz.'
  out=$(build "$home") || fail "rebuild failed: $out"
  assert_contains "$out" 'page: ' "a changed report must republish the page"
  assert_contains "$(html_of "$home/state/reports.html" alpha)" 'Ein neuer Satz.' \
    "the republished page must carry the new text"
  pass "a changed report republishes the page"
}

test_home_without_a_report_still_publishes_the_page() {
  local home out
  home=$(new_home)
  out=$(build "$home") || fail "build failed on an empty home: $out"
  assert_contains "$out" 'reports: 0' "an empty home reports no reports"
  assert_present "$home/state/reports.html" \
    "the page path a skill hands out must resolve even with no report"
  assert_equals 0 "$(entries_of "$home/state/reports.html" | jq 'length')" \
    "an empty home carries an empty payload"
  pass "a home with no report still publishes the page"
}

test_fenced_code_block_renders() {
  local home html status
  home=$(new_home)
  write_report "$home" fenced '# Fenced

```sh
echo hallo
```

Nach dem Block.'
  build_bounded "$home" >/dev/null
  status=$?
  if fm_timed_out "$status"; then
    fail "a report with a fenced code block did not build within the bound (the jq empty-match regression is back)"
  fi
  expect_code 0 "$status" "a report with a fenced code block must build"
  html=$(html_of "$home/state/reports.html" fenced)
  assert_contains "$html" '<pre><code' "a fenced block must render as preformatted code"
  assert_contains "$html" 'echo hallo' "the fenced block must keep its text"
  assert_contains "$html" 'Nach dem Block.' "the paragraph after the fence must survive"
  pass "a fenced code block renders"
}

test_indented_fence_renders() {
  local home html status
  home=$(new_home)
  # The indent is what the removed gsub used to strip, so an indented fence is
  # the exact shape of the regression.
  write_report "$home" indented '# Indented

- Ein Punkt:

  ```text
  eingerueckt
  ```'
  build_bounded "$home" >/dev/null
  status=$?
  if fm_timed_out "$status"; then
    fail "an indented fence did not build within the bound (the jq empty-match regression is back)"
  fi
  expect_code 0 "$status" "an indented fence must build"
  html=$(html_of "$home/state/reports.html" indented)
  assert_contains "$html" 'eingerueckt' "an indented fence must keep its text"
  pass "an indented fence renders"
}

test_report_text_never_becomes_markup() {
  local home page html
  home=$(new_home)
  write_report "$home" hostile '# Hostile

<script>alert(1)</script>

Ein </script> mitten im Satz.'
  build "$home" >/dev/null || fail "build failed on a report quoting markup"
  page="$home/state/reports.html"
  assert_equals 1 "$(entries_of "$page" | jq 'length')" \
    "a report quoting markup must leave the payload parsable"
  html=$(html_of "$page" hostile)
  assert_contains "$html" '&lt;script&gt;' "quoted markup must be shown as text"
  assert_not_contains "$html" '<script>' "a report must never contribute a live tag"
  pass "a report's markup is shown as text and never built into the page"
}

test_report_cannot_impersonate_a_page_slot() {
  local home page html
  home=$(new_home)
  write_report "$home" slots '# Slots

__FM_REPORTS_DATA__

const BUILT = "__FM_REPORTS_BUILT__";'
  build "$home" >/dev/null || fail "build failed on a report quoting the page slots"
  page="$home/state/reports.html"
  assert_equals 1 "$(entries_of "$page" | jq 'length')" \
    "a report quoting the page slots must leave the payload parsable"
  html=$(html_of "$page" slots)
  assert_contains "$html" '__FM_REPORTS_DATA__' "the quoted data slot must survive as text"
  assert_contains "$html" '__FM_REPORTS_BUILT__' "the quoted build stamp must survive as text"
  pass "a report quoting a page slot does not become a substitution target"
}

test_title_comes_from_the_first_heading() {
  local home page
  home=$(new_home)
  write_report "$home" titled '# Ein klarer Titel

Text.'
  write_report "$home" untitled 'Kein Titel, nur Text.'
  build "$home" >/dev/null || fail "build failed"
  page="$home/state/reports.html"
  assert_equals 'Ein klarer Titel' \
    "$(entries_of "$page" | jq -r '.[] | select(.id == "titled") | .title')" \
    "the first heading must become the list title"
  assert_equals 'untitled' \
    "$(entries_of "$page" | jq -r '.[] | select(.id == "untitled") | .title')" \
    "a report without a heading must fall back to its id"
  write_report "$home" later 'Text before heading.

# A later heading is content, not the list title.'
  build "$home" >/dev/null || fail "rebuild failed"
  assert_equals 'later' \
    "$(entries_of "$page" | jq -r '.[] | select(.id == "later") | .title')" \
    "a report without a first-line heading must fall back to its id"
  pass "the list title comes from the first heading, else the id"
}

test_unsafe_link_and_image_schemes_are_rejected() {
  local home page html
  home=$(new_home)
  write_report "$home" schemes '# Schemes

[javascript](javascript:alert(1)) [vbscript](vbscript:alert(1)) [file](file:///etc/passwd)
[obfuscated](java&#58;script:alert(1))
[control-obfuscated](java&#x09;script&#58;alert(1))
[semicolonless-obfuscated](java&#x09script&#58alert(1))
![bad data](data:text/html,alert(1)) ![bad file](file:///etc/passwd)
[good](https://example.test/path)'
  build "$home" >/dev/null || fail "build failed"
  page="$home/state/reports.html"
  html=$(html_of "$page" schemes)
  assert_not_contains "$html" 'href="javascript:' "javascript links must be inert"
  assert_not_contains "$html" 'href="vbscript:' "vbscript links must be inert"
  assert_not_contains "$html" 'href="file:' "file links must be inert"
  assert_not_contains "$html" 'href="javascript&#58;' "entity-obfuscated schemes must be inert"
  assert_not_contains "$html" 'href="java&amp;#x09;script' \
    "numeric references must be decoded before control characters are stripped"
  assert_not_contains "$html" 'href="java&amp;#x09script' \
    "semicolonless numeric references must be decoded before scheme validation"
  assert_not_contains "$html" 'src="data:' "unsafe data images must be inert"
  assert_not_contains "$html" 'src="file:' "file images must be inert"
  assert_contains "$html" 'href="https://example.test/path"' "https links must remain usable"
  assert_contains "$html" 'bad data' "rejected images must leave their alt text visible"
  pass "unsafe link and image schemes are rejected"
}

test_hard_break_becomes_a_line_break() {
  local home
  home=$(new_home)
  mkdir -p "$home/data/breaks" || fail "cannot create data/breaks"
  printf '# Breaks\n\nErste Zeile.  \nZweite Zeile.\n' > "$home/data/breaks/report.md" \
    || fail "cannot write the fixture report"
  build "$home" >/dev/null || fail "build failed"
  assert_contains "$(html_of "$home/state/reports.html" breaks)" '<br>' \
    "two trailing spaces must become a line break"
  pass "a hard break becomes a line break"
}

test_heading_gets_an_id_to_jump_to() {
  local home
  home=$(new_home)
  write_report "$home" anchored '# Anchored

## Ablauf und Nachweis

Text.'
  build "$home" >/dev/null || fail "build failed"
  assert_contains "$(html_of "$home/state/reports.html" anchored)" 'id="ablauf-und-nachweis"' \
    "a heading must carry an id an in-report link can reach"
  pass "a heading carries an id"
}

test_malformed_in_report_fragment_does_not_throw_or_navigate() {
  local home page
  home=$(new_home)
  write_report "$home" anchored '# Anchored

[broken](#%)'
  build "$home" >/dev/null || fail "build failed"
  page="$home/state/reports.html"
  node - "$page" <<'NODE' || fail "built page behavior failed"
const fs = require("fs");
const vm = require("vm");
const page = fs.readFileSync(process.argv[2], "utf8");
const payload = page.match(/<script id="reports-data" type="application\/json">([\s\S]*?)<\/script>/)[1];
const script = page.match(/<script>\n([\s\S]*?)<\/script>/)[1];
let click;
let navigated = false;
function element() {
  return {
    children: [], classList: { add() {}, remove() {}, toggle() {}, contains() { return false; } },
    addEventListener(type, fn) { if (this.id === "report" && type === "click") click = fn; },
    append(...items) { this.children.push(...items); }, setAttribute() {}, querySelector() { return null; },
    setPointerCapture() {}, releasePointerCapture() {}, focus() {}, select() {},
    style: { setProperty() {}, removeProperty() {} },
    set textContent(value) { this._text = value; }, get textContent() { return this._text || ""; }
  };
}
const ids = ["reports-data", "q", "sort", "count", "list", "report", "where", "scroll", "grip", "scrim", "gaps", "toggle", "prev", "next"];
const elements = Object.fromEntries(ids.map(id => { const el = element(); el.id = id; return [id, el]; }));
elements["reports-data"].textContent = payload;
elements.sort.value = "new";
elements.q.value = "";
const document = { body: element(), documentElement: element(), title: "", getElementById(id) { return elements[id]; }, createElement() { return element(); }, addEventListener() {} };
const context = {
  document, location: { hash: "#anchored", replace() { navigated = true; } },
  window: { addEventListener() {}, matchMedia() { return { matches: false }; }, innerWidth: 1000, CSS: { escape: value => value } },
  localStorage: { getItem() { return null; }, setItem() {} },
  getComputedStyle() { return { getPropertyValue() { return ""; } }; }, encodeURIComponent, decodeURIComponent
};
vm.runInNewContext(script, context);
const html = JSON.parse(payload).entries[0].html;
const href = html.match(/href="([^"]*)"/)[1];
let prevented = false;
click({ target: { closest() { return { getAttribute() { return href; } }; } }, preventDefault() { prevented = true; } });
if (!prevented || navigated || context.location.hash !== "#anchored") throw new Error("malformed in-report link navigated");
NODE
  pass "a malformed in-report fragment leaves the report in place"
}

test_nested_list_dedent_and_reindent_keep_siblings_at_their_level() {
  local home html
  home=$(new_home)
  write_report "$home" nested '# Nested

- Eltern
  - Kind
- Geschwister
  - Weiter eingerueckt'
  build "$home" >/dev/null || fail "build failed"
  html=$(html_of "$home/state/reports.html" nested | tr -d '\n')
  assert_contains "$html" '<ul><li>Eltern<ul><li>Kind</li></ul></li><li>Geschwister<ul><li>Weiter eingerueckt</li></ul></li></ul>' \
    "dedenting must close the child list before a sibling, and a later indent must nest under that sibling"
  pass "nested lists preserve sibling levels after dedent and reindent"
}

test_symlinked_report_is_not_read() {
  local home out
  home=$(new_home)
  write_report "$home" real '# Real'
  mkdir -p "$home/data/linked" || fail "cannot create data/linked"
  ln -s "$home/data/real/report.md" "$home/data/linked/report.md" \
    || fail "cannot create the symlink fixture"
  out=$(build "$home") || fail "build failed: $out"
  assert_contains "$out" 'reports: 1' "a symlinked report must not be read"
  pass "a symlinked report is skipped"
}

test_symlinked_report_directory_is_not_read_or_used_for_decision_targets() {
  local home external out entries html
  home=$(decision_home)
  external="$home/external"
  mkdir -p "$external" || fail "cannot create external report fixture"
  write_report "$home" real '# Real'
  printf '# Linked private report\n\nOutside report content.\n' > "$external/report.md" \
    || fail "cannot write external report fixture"
  ln -s "$external" "$home/data/linked" || fail "cannot create the report directory symlink"
  write_backlog "$home" '# Backlog

## Done
- [x] linked - Decision for linked report (kind: captain) (done 2026-10-20) (hold-kind: captain)
  Resolution recorded by fm-captain-hold.
  Decision digest: bbbb1111bbbb2222cccc3333dddd4444eeee5555ffff6666aaaa7777bbbb8888
  Resolution mode: answered

  Captain decision:
  Keep the linked report private.'
  out=$(build "$home") || fail "build failed: $out"
  assert_contains "$out" 'reports: 1' "only the real report directory should be counted"
  assert_contains "$out" 'entries: 2' "the decision must remain its own entry"
  entries=$(entries_of "$home/state/reports.html")
  assert_equals 'decision' \
    "$(printf '%s' "$entries" | jq -r '.[] | select(.id == "linked") | .kind')" \
    "a decision must not be attached to a report found only through a directory symlink"
  html=$(printf '%s' "$entries" | jq -r 'map(.html) | join("\n")')
  assert_not_contains "$html" 'Outside report content.' \
    "a report reachable only through a symlink directory must not be read"
  pass "a symlinked report directory is excluded from both read boundaries"
}

test_path_prints_the_page_path() {
  local home out
  home=$(new_home)
  out=$(FM_HOME="$home" bash "$PAGE_SH" path) || fail "path failed: $out"
  assert_equals "$home/state/reports.html" "$out" "path must print this home's page path"
  pass "path prints the page path of the home"
}

test_link_proves_the_report_exists() {
  local home out status
  home=$(new_home)
  write_report "$home" alpha '# Alpha'
  out=$(FM_HOME="$home" bash "$PAGE_SH" link alpha 2>&1) && status=0 || status=$?
  expect_code 1 "$status" "link must refuse before the page is built"
  build "$home" >/dev/null || fail "build failed"
  out=$(FM_HOME="$home" bash "$PAGE_SH" link alpha) || fail "link failed: $out"
  assert_equals "file://$home/state/reports.html#alpha" "$out" \
    "link must print the page link with the report's anchor"
  out=$(FM_HOME="$home" bash "$PAGE_SH" link gone 2>&1) && status=0 || status=$?
  expect_code 1 "$status" "link must refuse an id the published page has no entry for"
  assert_contains "$out" 'the page carries no entry for gone' \
    "link must name the entry the page does not carry"
  # A report written since the last build is exactly the case a hand-built
  # anchor gets wrong, so it is refused too, naming the rebuild.
  write_report "$home" neu '# Neu'
  out=$(FM_HOME="$home" bash "$PAGE_SH" link neu 2>&1) && status=0 || status=$?
  expect_code 1 "$status" "link must refuse a report the published page does not carry yet"
  assert_contains "$out" 'rebuild it if that is new' "link must name the rebuild"
  build "$home" >/dev/null || fail "rebuild failed"
  out=$(FM_HOME="$home" bash "$PAGE_SH" link neu) || fail "link failed after the rebuild: $out"
  assert_equals "file://$home/state/reports.html#neu" "$out" \
    "link must hand out the anchor once the page carries it"
  pass "link proves the published page carries the anchor before handing it out"
}

test_build_refuses_without_a_home() {
  local out status
  out=$(FM_HOME='' bash "$PAGE_SH" build 2>&1) && status=0 || status=$?
  expect_code 1 "$status" "build must refuse without FM_HOME"
  assert_contains "$out" 'FM_HOME is not set' "build must name the missing home"
  pass "build refuses without a home"
}

# Exercise the shipped template at its public build interface. Keep its path
# explicit so changed-file test mapping associates template edits with this test.
test_shipped_template_build_replaces_both_slots() {
  local home page
  home=$(new_home)
  write_report "$home" shipped '# Shipped payload'
  FM_HOME="$home" FM_REPORTS_PAGE_TEMPLATE="$ROOT/.agents/skills/reports-page/assets/page-template.html" \
    bash "$PAGE_SH" build >/dev/null || fail "build with shipped template failed"
  page="$home/state/reports.html"
  assert_equals 1 "$(entries_of "$page" | jq 'length')" "the shipped template must carry the built payload"
  assert_contains "$(payload_of "$page")" 'Shipped payload' "the payload slot must be replaced"
  assert_not_contains "$(cat "$page")" '__FM_REPORTS_' "no template slot may survive the build"
  assert_not_contains "$(cat "$page")" 'const BUILT = "__FM_REPORTS_BUILT__"' "the stamp slot must be replaced"
  assert_contains "$(cat "$page")" 'const BUILT = "' "the built page must carry a timestamp"
  pass "the shipped template builds with both slots replaced"
}

test_build_refuses_a_template_without_a_slot() {
  local home template out status
  home=$(new_home)
  write_report "$home" alpha '# Alpha'
  template=$(fm_test_tmproot fm-reports-page-template)/page.html
  printf '<html><body></body></html>\n' > "$template" \
    || fail "cannot write the broken template fixture"
  out=$(FM_HOME="$home" FM_REPORTS_PAGE_TEMPLATE="$template" bash "$PAGE_SH" build 2>&1) \
    && status=0 || status=$?
  expect_code 1 "$status" "build must refuse a template with no data slot"
  assert_contains "$out" 'does not carry exactly one data slot' \
    "build must name the missing slot"
  assert_absent "$home/state/reports.html" "a refused build must publish nothing"
  pass "build refuses a template without a data slot"
}

test_page_fetches_nothing() {
  local home page
  home=$(new_home)
  write_report "$home" alpha '# Alpha'
  build "$home" >/dev/null || fail "build failed"
  page="$home/state/reports.html"
  assert_no_grep '<script src=' "$page" "the page must load no external script"
  assert_no_grep '<link rel="stylesheet"' "$page" "the page must load no external stylesheet"
  assert_no_grep '@import' "$page" "the page must import no external stylesheet"
  assert_no_grep 'fetch(' "$page" "the page must make no network request"
  assert_no_grep 'XMLHttpRequest' "$page" "the page must make no network request"
  pass "the published page fetches nothing"
}

# --- recorded decisions ------------------------------------------------------

test_recorded_decision_reaches_the_report_it_gated() {
  local home html
  home=$(decision_home)
  write_report "$home" plattenpruefung-20261020 '# Plattenpruefung

Gemessen und belegt.'
  write_backlog "$home" '# Backlog

## Done
- [x] plattenpruefung-20261020 - Platte tauschen oder behalten? (kind: captain) (done 2026-10-20) (hold-kind: captain)
  Resolution recorded by fm-captain-hold.
  Decision digest: aaaa1111bbbb2222cccc3333dddd4444eeee5555ffff6666aaaa7777bbbb8888
  Resolution mode: answered

  Captain decision:
  Behalten. Der Sektor liest wieder und SMART meldet null Ausfaelle.'
  build "$home" >/dev/null || fail "build failed"
  html=$(html_of "$home/state/reports.html" plattenpruefung-20261020)
  assert_contains "$html" 'Gemessen und belegt.' "the report itself must still render"
  assert_contains "$html" 'id="decisions"' \
    "a report whose task recorded a decision must carry the decision section"
  assert_contains "$html" 'Behalten. Der Sektor liest wieder' \
    "the captain's own words must reach the report's entry"
  assert_contains "$html" 'aaaa1111bbbb' \
    "the decision's checksum must be shown, so the record can be found again"
  pass "a recorded decision reaches the report of the task it gated"
}

test_reconciliation_evidence_is_rendered_as_reconciled() {
  local home html
  home=$(decision_home)
  write_backlog "$home" '# Backlog

## Done
- [x] reconciled-evidence - Reconciliation evidence (kind: captain) (done 2026-10-20) (hold-kind: captain)
  Resolution recorded by fm-captain-hold.
  Decision digest: 88881111bbbb2222cccc3333dddd4444eeee5555ffff6666aaaa7777bbbb8888
  Resolution mode: reconciled

  Reconciliation evidence:
  The question no longer applies after the service retired.'
  build "$home" >/dev/null || fail "build failed"
  html=$(html_of "$home/state/reports.html" reconciled-evidence)
  assert_contains "$html" 'class="dec-state">reconciled<' \
    "reconciliation evidence must have its own outcome state"
  assert_contains "$html" 'The question no longer applies after the service retired.' \
    "the recorded reconciliation evidence must be shown"
  assert_not_contains "$html" 'class="dec-state">decided<' \
    "reconciliation evidence must not be presented as the captain's answer"
  pass "resolution evidence appears as a reconciled outcome"
}

test_still_open_reconciliation_note_is_rendered_as_reconciled() {
  local home html
  home=$(decision_home)
  write_backlog "$home" '# Backlog

## Active
- [ ] reconciled-note - Still open (kind: captain) (hold-kind: captain)
  Captain hold reconciled: 2026-10-20T12:34:56Z
  Reconcile request: 2026-10-20T12:00:00Z | board | note digest: deadbeef
  The evidence is incomplete, so the question remains open.'
  build "$home" >/dev/null || fail "build failed"
  html=$(html_of "$home/state/reports.html" reconciled-note)
  assert_contains "$html" 'class="dec-state">reconciled<' \
    "a still-open reconcile note must have its own outcome state"
  assert_contains "$html" 'The evidence is incomplete, so the question remains open.' \
    "the note content must be shown"
  assert_not_contains "$html" '2026-10-20T12:00:00Z' \
    "reconcile request bookkeeping must not be shown as the note"
  assert_not_contains "$html" 'class="dec-state">decided<' \
    "a reconcile note must not be presented as the captain's answer"
  pass "a still-open reconcile note appears as a reconciled outcome"
}

test_task_line_tags_never_reach_the_title() {
  local home entries title
  home=$(decision_home)
  # A finished task line ends in the tag groups tasks-axi appends. None of them
  # is part of the title, and a title that legitimately ends in parentheses has
  # to survive the stripping.
  write_backlog "$home" '# Backlog

## Done
- [x] mit-anhang-20261011 - Firstmate: Rueckfragen ueber Lavish (AGENTS.md) (repo: firstmate) (kind: ship) (merged 2026-10-11) (hold-kind: captain)
  Resolution recorded by fm-captain-hold.
  Decision digest: 4444444444444444444444444444444444444444444444444444444444444444
  Resolution mode: answered

  Captain decision:
  Freigegeben.
- [x] gemeldet-20261012 - Eine Untersuchung (siehe oben) (repo: firstmate) (kind: scout) (reported 2026-10-12)
  Resolution recorded by fm-captain-hold.
  Decision digest: 5151515151515151515151515151515151515151515151515151515151515151
  Resolution mode: answered

  Captain decision:
  Zur Kenntnis genommen.'
  build "$home" >/dev/null || fail "build failed"
  entries=$(entries_of "$home/state/reports.html")
  title=$(printf '%s' "$entries" | jq -r '.[] | select(.id == "mit-anhang-20261011") | .title')
  assert_equals 'Firstmate: Rueckfragen ueber Lavish (AGENTS.md)' "$title" \
    "no task-line tag group may survive into an entry title"
  title=$(printf '%s' "$entries" | jq -r '.[] | select(.id == "gemeldet-20261012") | .title')
  assert_equals 'Eine Untersuchung (siehe oben)' "$title" \
    "stripping the tag groups must leave an ordinary trailing parenthesis alone"
  assert_not_contains "$(html_of "$home/state/reports.html" mit-anhang-20261011)" '(merged 2026-10-11)' \
    "the entry heading must not show a tag group either"
  pass "task-line tag groups never reach an entry title"
}

test_decision_without_a_report_becomes_its_own_entry() {
  local home out entries link
  home=$(decision_home)
  write_report "$home" fremder-bericht '# Fremder Bericht'
  write_backlog "$home" '# Backlog

## Done
- [x] luefterfrage-20261017 - Luefter ueber das OS regeln? (kind: captain) (done 2026-10-17) (hold-kind: captain)
  Resolution recorded by fm-captain-hold.
  Decision digest: 1234123412341234123412341234123412341234123412341234123412341234
  Resolution mode: answered

  Captain decision:
  Den Fremdtreiber versuchen.'
  out=$(build "$home") || fail "build failed: $out"
  assert_contains "$out" 'entries: 2' "a decision that gated no report must add its own entry"
  entries=$(entries_of "$home/state/reports.html")
  assert_equals 'decision' \
    "$(printf '%s' "$entries" | jq -r '.[] | select(.id == "luefterfrage-20261017") | .kind')" \
    "that entry must declare itself a decision rather than pass for a report"
  assert_equals 'null' \
    "$(printf '%s' "$entries" | jq -r '.[] | select(.id == "luefterfrage-20261017") | .file | tostring')" \
    "a decision entry must claim no report file"
  assert_contains \
    "$(printf '%s' "$entries" | jq -r '.[] | select(.id == "luefterfrage-20261017") | .html')" \
    'Den Fremdtreiber versuchen.' "the decision's words must be its entry's content"
  link=$(FM_HOME="$home" bash "$PAGE_SH" link luefterfrage-20261017) \
    || fail "link must hand out the anchor of a decision entry"
  assert_equals "file://$home/state/reports.html#luefterfrage-20261017" "$link" \
    "a decision must be reachable by the same stable anchor a report gets"
  pass "a decision that gated no report becomes its own anchored entry"
}

test_empty_anchor_falls_back_to_newest_report() {
  local home actual
  home=$(decision_home)
  write_report "$home" letzter-bericht '# Letzter Bericht'
  touch -d '2026-10-18 10:00' "$home/data/letzter-bericht/report.md" 2>/dev/null \
    || touch -t 202610181000 "$home/data/letzter-bericht/report.md" \
    || fail "cannot age the fixture report"
  write_backlog "$home" '# Backlog

## Done
- [x] neueste-entscheidung-20261020 - Neue Entscheidung (kind: captain) (done 2026-10-20) (hold-kind: captain)
  Resolution recorded by fm-captain-hold.
  Decision digest: aaaa1111bbbb2222cccc3333dddd4444eeee5555ffff6666aaaa7777bbbb8888
  Resolution mode: answered

  Captain decision:
  Diese Entscheidung ist neuer als der Bericht.'
  build "$home" >/dev/null || fail "build failed"
  actual=$(fallback_anchor_of "$home/state/reports.html" "") \
    || fail "could not open the built page with an empty anchor"
  assert_equals '#letzter-bericht' "$actual" \
    "an empty anchor must prefer the newest report over a newer decision"
  pass "an empty anchor falls back to the newest report"
}

test_malformed_anchor_falls_back_to_newest_report() {
  local home actual
  home=$(new_home)
  write_report "$home" sicherer-fallback '# Sicherer Fallback'
  build "$home" >/dev/null || fail "build failed"
  actual=$(fallback_anchor_of "$home/state/reports.html" '#%') \
    || fail "opening the built page with a malformed anchor threw"
  assert_equals '#sicherer-fallback' "$actual" \
    "a malformed anchor must behave like an unknown anchor"
  pass "a malformed anchor falls back to the newest report"
}

test_unknown_anchor_falls_back_to_newest_decision_without_reports() {
  local home actual
  home=$(decision_home)
  write_backlog "$home" '# Backlog

## Done
- [x] alte-entscheidung-20261018 - Alte Entscheidung (kind: captain) (done 2026-10-18) (hold-kind: captain)
  Resolution recorded by fm-captain-hold.
  Decision digest: aaaa1111bbbb2222cccc3333dddd4444eeee5555ffff6666aaaa7777bbbb8888
  Resolution mode: answered

  Captain decision:
  Die fruehere Entscheidung.

- [x] neue-entscheidung-20261020 - Neue Entscheidung (kind: captain) (done 2026-10-20) (hold-kind: captain)
  Resolution recorded by fm-captain-hold.
  Decision digest: bbbb1111bbbb2222cccc3333dddd4444eeee5555ffff6666aaaa7777bbbb8888
  Resolution mode: answered

  Captain decision:
  Die neueste Entscheidung.'
  build "$home" >/dev/null || fail "build failed"
  actual=$(fallback_anchor_of "$home/state/reports.html" '#does-not-exist') \
    || fail "could not open the built page with an unknown anchor"
  assert_equals '#neue-entscheidung-20261020' "$actual" \
    "without reports, an unknown anchor must fall back to the newest entry"
  pass "an unknown anchor falls back to the newest decision when no reports exist"
}

test_filename_sort_keeps_decisions_without_reports() {
  local home page
  home=$(decision_home)
  write_report "$home" fremder-bericht '# Fremder Bericht'
  write_backlog "$home" '# Backlog

## Done
- [x] luefterfrage-20261017 - Luefter ueber das OS regeln? (kind: captain) (done 2026-10-17) (hold-kind: captain)
  Resolution recorded by fm-captain-hold.
  Decision digest: 1234123412341234123412341234123412341234123412341234123412341234
  Resolution mode: answered

  Captain decision:
  Den Fremdtreiber versuchen.'
  build "$home" >/dev/null || fail "build failed"
  page="$home/state/reports.html"
  node - "$page" <<'NODE' || fail "built page behavior failed"
const fs = require("fs");
const vm = require("vm");
const page = fs.readFileSync(process.argv[2], "utf8");
const payload = page.match(/<script id="reports-data" type="application\/json">([\s\S]*?)<\/script>/)[1];
const script = page.match(/<script>\n([\s\S]*?)<\/script>/)[1];
const listeners = {};
function element(tagName = "DIV") {
  return {
    tagName, children: [], classList: { add() {}, remove() {}, toggle() {}, contains() { return false; } },
    addEventListener(type, fn) { listeners[this.id + ":" + type] = fn; },
    append(...items) { this.children.push(...items); }, setAttribute() {},
    setPointerCapture() {}, releasePointerCapture() {}, focus() {}, select() {},
    style: { setProperty() {}, removeProperty() {} },
    set textContent(value) { this._text = value; if (this.id === "list") this.children = []; },
    get textContent() { return this._text || ""; }
  };
}
const ids = ["reports-data", "q", "sort", "count", "list", "report", "where", "scroll", "grip", "scrim", "gaps", "toggle", "prev", "next"];
const elements = Object.fromEntries(ids.map(id => {
  const el = element();
  el.id = id;
  return [id, el];
}));
elements["reports-data"].textContent = payload;
elements.sort.tagName = "SELECT";
elements.sort.value = "new";
elements.q.tagName = "INPUT";
elements.q.value = "";
const document = {
  body: element(), documentElement: element(), title: "",
  getElementById(id) { return elements[id]; },
  createElement(tag) { return element(tag.toUpperCase()); },
  addEventListener() {}
};
const context = {
  document, location: { hash: "#fremder-bericht", replace() {} },
  window: { addEventListener() {}, matchMedia() { return { matches: false }; }, innerWidth: 1000 },
  localStorage: { getItem() { return null; }, setItem() {} },
  getComputedStyle() { return { getPropertyValue() { return ""; } }; },
  encodeURIComponent, decodeURIComponent, CSS: { escape: value => value }
};
vm.runInNewContext(script, context);
elements.sort.value = "file";
listeners["sort:change"]();
const idsInView = elements.list.children.map(link => link.href);
if (idsInView.join(",") !== "#fremder-bericht,#luefterfrage-20261017") {
  throw new Error("Dateiname sort must show both report and fileless decision: " + idsInView.join(","));
}
NODE
  pass "filename sorting keeps a decision without a report"
}

test_report_without_a_decision_carries_no_decision_section() {
  local home out
  home=$(decision_home)
  write_report "$home" einsam '# Einsam

Nur ein Bericht.'
  out=$(build "$home") || fail "build failed: $out"
  assert_contains "$out" 'decisions: 0' "a home with no recorded decision must say so"
  assert_contains "$out" 'entries: 1' "no decision means no extra entry"
  assert_not_contains "$(html_of "$home/state/reports.html" einsam)" 'class="dec"' \
    "a report with no decision must not grow an empty decision section"
  pass "a report without a decision is left exactly as it was"
}

test_search_finds_a_phrase_only_the_decision_carries() {
  local home searchable
  home=$(decision_home)
  write_report "$home" kuehlung-20261017 '# Kuehlung

Der Bericht nennt dieses Wort nicht.'
  write_backlog "$home" '# Backlog

## Done
- [x] kuehlung-20261017 - Wie weiter mit der Kuehlung? (kind: captain) (done 2026-10-17) (hold-kind: captain)
  Resolution recorded by fm-captain-hold.
  Decision digest: 5555555555555555555555555555555555555555555555555555555555555555
  Resolution mode: answered

  Captain decision:
  Zugestimmt, Kennwort Schneeflocke.'
  build "$home" >/dev/null || fail "build failed"
  searchable=$(searchable_of "$home/state/reports.html" kuehlung-20261017)
  assert_contains "$searchable" 'schneeflocke' \
    "the page's own search text must include what only the decision says"
  pass "search reaches a phrase that only the decision carries"
}

test_every_decision_of_one_task_appears_newest_first() {
  local home html first second third
  home=$(decision_home)
  write_backlog "$home" '# Backlog

## Done
- [x] mehrfach-20261018 - Mehrfach beantwortet (kind: captain) (done 2026-10-18) (hold-kind: captain)
  Resolution recorded by fm-captain-hold.
  Decision digest: 3333333333333333333333333333333333333333333333333333333333333333
  Resolution mode: answered

  Captain decision:
  Die dritte und neueste Antwort.

  Resolution recorded by fm-captain-hold.
  Decision digest: 2222222222222222222222222222222222222222222222222222222222222222
  Resolution mode: released

  Captain decision:
  Die zweite Antwort.

  Resolution recorded by fm-captain-hold.
  Decision digest: 1111111111111111111111111111111111111111111111111111111111111111
  Resolution mode: released

  Captain decision:
  Die erste Antwort.'
  build "$home" >/dev/null || fail "build failed"
  html=$(html_of "$home/state/reports.html" mehrfach-20261018)
  assert_contains "$html" 'Die erste Antwort.' "an older decision must not be dropped"
  assert_contains "$html" 'Die zweite Antwort.' "an older decision must not be dropped"
  assert_contains "$html" 'Die dritte und neueste Antwort.' "the newest decision must be there"
  first=${html%%Die dritte und neueste Antwort.*}
  second=${html%%Die zweite Antwort.*}
  third=${html%%Die erste Antwort.*}
  [ "${#first}" -lt "${#second}" ] && [ "${#second}" -lt "${#third}" ] \
    || fail "the decisions of one task must stay newest first, as they are recorded"
  pass "every decision of one task appears, newest first"
}

test_same_text_without_checksums_keeps_distinct_resolution_blocks() {
  local home html
  home=$(decision_home)
  write_note_archive "$home" '# Notes

## Archived 2026-10-20
- [x] gleiche-antwort - Same response twice (kind: captain) (done 2026-10-20) (hold-kind: captain)
  Resolution recorded by fm-captain-hold.
  Resolution mode: answered

  Captain decision:
  Same answer.

  Resolution recorded by fm-captain-hold.
  Resolution mode: answered

  Captain decision:
  Same answer.'
  build "$home" >/dev/null || fail "build failed"
  html=$(html_of "$home/state/reports.html" gleiche-antwort)
  assert_equals 2 "$(printf '%s' "$html" | grep -o 'Same answer\.' | wc -l | tr -d ' ')" \
    "two blocks without checksums must remain separate even with identical text"
  pass "identical checksum-free decisions remain distinct"
}

test_same_task_archived_twice_keeps_checksumless_blocks_distinct() {
  local home html
  home=$(decision_home)
  write_note_archive "$home" '# Notes

## Archived 2026-10-20
- [x] repeated-task - Repeated task snapshot (kind: captain) (done 2026-10-20) (hold-kind: captain)
  Resolution recorded by fm-captain-hold.
  Resolution mode: answered

  Captain decision:
  Same archived answer.

- [x] repeated-task - Repeated task snapshot (kind: captain) (done 2026-10-20) (hold-kind: captain)
  Resolution recorded by fm-captain-hold.
  Resolution mode: answered

  Captain decision:
  Same archived answer.'
  build "$home" >/dev/null || fail "build failed"
  html=$(html_of "$home/state/reports.html" repeated-task)
  assert_equals 2 "$(printf '%s' "$html" | grep -o 'Same archived answer\.' | wc -l | tr -d ' ')" \
    "same-id records in one source must not collide on block position"
  pass "repeated archive records keep checksumless blocks distinct"
}

test_a_decision_reached_through_two_sources_appears_once() {
  local home html
  home=$(decision_home)
  # The same recorded block, in the live backlog AND as an archived snapshot of
  # the same task. Its checksum is its identity, so it is one decision.
  write_backlog "$home" '# Backlog

## Done
- [x] doppelt-20261019 - Zweimal aufgezeichnet (kind: captain) (done 2026-10-19) (hold-kind: captain)
  Resolution recorded by fm-captain-hold.
  Decision digest: 9999999999999999999999999999999999999999999999999999999999999999
  Resolution mode: answered

  Captain decision:
  Genau einmal zu sehen.'
  write_note_archive "$home" '# Notes

## Archived 2026-10-19
- [ ] doppelt-20261019 - Zweimal aufgezeichnet (kind: captain) (since 2026-10-19) (hold-kind: captain)
  Resolution recorded by fm-captain-hold.
  Decision digest: 9999999999999999999999999999999999999999999999999999999999999999
  Resolution mode: answered

  Captain decision:
  Genau einmal zu sehen.'
  assert_contains "$(build "$home")" 'decisions: 1' \
    "a decision reached through two sources must be counted once"
  html=$(html_of "$home/state/reports.html" doppelt-20261019)
  assert_equals 1 "$(printf '%s' "$html" | grep -c '9999999999' || true)" \
    "a decision reached through two sources must be shown once"
  pass "a decision reached through two sources appears once"
}

test_home_without_archive_files_still_builds() {
  local home out
  home=$(decision_home)
  write_report "$home" ohne-ablage '# Ohne Ablage'
  out=$(build "$home") || fail "a home with no archive files must still build: $out"
  assert_contains "$out" 'reports: 1' "the report must still reach the page"
  assert_contains "$out" 'decisions: 0' "no archive file means no decision, not a refusal"
  assert_contains "$out" 'source: data/done-archive.md absent' \
    "a source that is not there must be named, not passed over in silence"
  assert_contains "$(cat "$home/state/reports.html")" 'Not read in full' \
    "the page itself must be able to show the gap"
  pass "a home without archive files still builds, and names the gap"
}

test_missing_tasks_toml_uses_readable_default_sources_without_warning() {
  local home out
  home=$(new_home)
  : > "$home/data/backlog.md"
  : > "$home/data/done-archive.md"
  : > "$home/data/note-archive.md"
  out=$(build "$home") || fail "build failed without .tasks.toml: $out"
  assert_not_contains "$out" 'source: store configuration' \
    "the absent optional config selects defaults and is not a missing data source"
  pass "missing task configuration uses readable default sources quietly"
}

test_unreadable_tasks_toml_is_reported() {
  local home out
  home=$(new_home)
  : > "$home/data/backlog.md"
  : > "$home/data/done-archive.md"
  : > "$home/data/note-archive.md"
  mkdir "$home/.tasks.toml" || fail "cannot create the unreadable config fixture"
  out=$(build "$home") || fail "build failed with unreadable .tasks.toml: $out"
  assert_contains "$out" 'source: store configuration unreadable' \
    "an existing config path that cannot be read must be named"
  pass "an unreadable task configuration is reported"
}

test_missing_configured_archive_path_is_reported_precisely() {
  local home out missing
  home=$(new_home)
  printf 'backend = "markdown"\npath = "data/backlog.md"\narchive = "data/custom-archive.md"\n' \
    > "$home/.tasks.toml" || fail "cannot write configured paths"
  : > "$home/data/backlog.md"
  : > "$home/data/note-archive.md"
  out=$(build "$home") || fail "build failed with missing configured archive: $out"
  assert_contains "$out" 'source: data/custom-archive.md absent - not present in this home' \
    "the configured data source that could not contribute must be named"
  missing=$(printf '%s\n' "$out" | sed -n '/^source: .* absent - /p')
  assert_equals 'source: data/custom-archive.md absent - not present in this home' "$missing" \
    "only the missing configured archive should be reported absent"
  pass "a missing configured archive is reported by its exact path"
}

test_home_on_another_backlog_store_still_builds() {
  local home out
  home=$(decision_home)
  printf 'backend = "beads"\n' > "$home/.tasks.toml" \
    || fail "cannot write the foreign-store fixture"
  write_report "$home" fremde-ablage '# Fremde Ablage'
  write_backlog "$home" '# Backlog

## Done
- [x] ignoriert-20261019 - Darf nicht aus der Datei gelesen werden (kind: captain) (done 2026-10-19)
  Resolution recorded by fm-captain-hold.
  Decision digest: 7777777777777777777777777777777777777777777777777777777777777777
  Resolution mode: answered

  Captain decision:
  Aus einer Datei, die diesem Zuhause nicht gehoert.'
  out=$(build "$home") || fail "a home on another backlog store must still build: $out"
  assert_contains "$out" 'reports: 1' "the report must still reach the page"
  assert_contains "$out" 'decisions: 0' \
    "a markdown file must not be read for a home whose store is not markdown"
  assert_contains "$out" 'source: store files skipped' \
    "the skipped markdown files must be named"
  pass "a home on another backlog store still builds"
}

test_decision_text_never_becomes_markup() {
  local home html
  home=$(decision_home)
  write_backlog "$home" '# Backlog

## Done
- [x] boshaft-20261019 - Eine Entscheidung, die Markup zitiert (kind: captain) (done 2026-10-19) (hold-kind: captain)
  Resolution recorded by fm-captain-hold.
  Decision digest: 8888888888888888888888888888888888888888888888888888888888888888
  Resolution mode: answered

  Captain decision:
  Freigegeben, auch fuer <script>alert(1)</script> und __FM_REPORTS_DATA__.'
  build "$home" >/dev/null || fail "build failed on a decision quoting markup"
  assert_equals 1 "$(entries_of "$home/state/reports.html" | jq 'length')" \
    "a decision quoting markup must leave the payload parsable"
  html=$(html_of "$home/state/reports.html" boshaft-20261019)
  assert_contains "$html" '&lt;script&gt;' "quoted markup in a decision must be shown as text"
  assert_not_contains "$html" '<script>' "a decision must never contribute a live tag"
  assert_contains "$html" '__FM_REPORTS_DATA__' \
    "a decision quoting a page slot must survive as text"
  pass "a decision's text is shown as text and never built into the page"
}

test_decisions_can_be_switched_off_for_a_build() {
  local home out
  home=$(decision_home)
  write_backlog "$home" '# Backlog

## Done
- [x] abgeschaltet-20261019 - Nicht zu sehen (kind: captain) (done 2026-10-19) (hold-kind: captain)
  Resolution recorded by fm-captain-hold.
  Decision digest: 6666666666666666666666666666666666666666666666666666666666666666
  Resolution mode: answered

  Captain decision:
  Darf bei abgeschalteter Sammlung nicht erscheinen.'
  out=$(FM_HOME="$home" FM_REPORTS_PAGE_DECISIONS=off bash "$PAGE_SH" build) \
    || fail "build failed with the decisions switched off: $out"
  assert_contains "$out" 'decisions: 0' "the switch must leave the build with no decision"
  assert_contains "$out" 'entries: 0' "the switch must leave the build with no entry"
  pass "a build can be run with no decisions at all"
}

test_build_publishes_every_report
test_build_sorts_newest_first
test_rebuild_without_a_change_leaves_the_page_alone
test_changed_report_republishes_the_page
test_home_without_a_report_still_publishes_the_page
test_fenced_code_block_renders
test_indented_fence_renders
test_report_text_never_becomes_markup
test_report_cannot_impersonate_a_page_slot
test_title_comes_from_the_first_heading
test_hard_break_becomes_a_line_break
test_heading_gets_an_id_to_jump_to
test_malformed_in_report_fragment_does_not_throw_or_navigate
test_nested_list_dedent_and_reindent_keep_siblings_at_their_level
test_symlinked_report_is_not_read
test_symlinked_report_directory_is_not_read_or_used_for_decision_targets
test_path_prints_the_page_path
test_link_proves_the_report_exists
test_build_refuses_without_a_home
test_unsafe_link_and_image_schemes_are_rejected
test_shipped_template_build_replaces_both_slots
test_build_refuses_a_template_without_a_slot
test_page_fetches_nothing
test_recorded_decision_reaches_the_report_it_gated
test_reconciliation_evidence_is_rendered_as_reconciled
test_still_open_reconciliation_note_is_rendered_as_reconciled
test_decision_without_a_report_becomes_its_own_entry
test_empty_anchor_falls_back_to_newest_report
test_malformed_anchor_falls_back_to_newest_report
test_unknown_anchor_falls_back_to_newest_decision_without_reports
test_filename_sort_keeps_decisions_without_reports
test_task_line_tags_never_reach_the_title
test_report_without_a_decision_carries_no_decision_section
test_search_finds_a_phrase_only_the_decision_carries
test_every_decision_of_one_task_appears_newest_first
test_same_text_without_checksums_keeps_distinct_resolution_blocks
test_same_task_archived_twice_keeps_checksumless_blocks_distinct
test_a_decision_reached_through_two_sources_appears_once
test_home_without_archive_files_still_builds
test_missing_tasks_toml_uses_readable_default_sources_without_warning
test_unreadable_tasks_toml_is_reported
test_missing_configured_archive_path_is_reported_precisely
test_home_on_another_backlog_store_still_builds
test_decision_text_never_becomes_markup
test_decisions_can_be_switched_off_for_a_build
