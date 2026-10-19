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
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the renderer)"; exit 0; }
command -v perl >/dev/null 2>&1 || { echo "skip: perl not found (required by the page injection)"; exit 0; }

PAGE_SH="$ROOT/bin/fm-reports-page.sh"

# A fixture home. Reports are added by write_report, so a case says only what
# its own reports contain.
new_home() {
  local home
  home=$(fm_test_tmproot fm-reports-page) || fail "cannot create a fixture home"
  mkdir -p "$home/data" "$home/state" || fail "cannot create the fixture home layout"
  printf '%s\n' "$home"
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

# One rendered report's html, by id.
html_of() {  # <page> <id>
  payload_of "$1" | jq -r --arg id "$2" '.[] | select(.id == $id) | .html'
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
  assert_equals 2 "$(payload_of "$page" | jq 'length')" "the page must carry both reports"
  ids=$(payload_of "$page" | jq -r '[.[].id] | sort | join(",")')
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
  assert_equals 'newer' "$(payload_of "$page" | jq -r '.[0].id')" \
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
  assert_equals 0 "$(payload_of "$home/state/reports.html" | jq 'length')" \
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
  assert_equals 1 "$(payload_of "$page" | jq 'length')" \
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
  assert_equals 1 "$(payload_of "$page" | jq 'length')" \
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
    "$(payload_of "$page" | jq -r '.[] | select(.id == "titled") | .title')" \
    "the first heading must become the list title"
  assert_equals 'untitled' \
    "$(payload_of "$page" | jq -r '.[] | select(.id == "untitled") | .title')" \
    "a report without a heading must fall back to its id"
  write_report "$home" later 'Text before heading.

# A later heading is content, not the list title.'
  build "$home" >/dev/null || fail "rebuild failed"
  assert_equals 'later' \
    "$(payload_of "$page" | jq -r '.[] | select(.id == "later") | .title')" \
    "a report without a first-line heading must fall back to its id"
  pass "the list title comes from the first heading, else the id"
}

test_unsafe_link_and_image_schemes_are_rejected() {
  local home page html
  home=$(new_home)
  write_report "$home" schemes '# Schemes

[javascript](javascript:alert(1)) [vbscript](vbscript:alert(1)) [file](file:///etc/passwd)
[obfuscated](java&#58;script:alert(1))
![bad data](data:text/html,alert(1)) ![bad file](file:///etc/passwd)
[good](https://example.test/path)'
  build "$home" >/dev/null || fail "build failed"
  page="$home/state/reports.html"
  html=$(html_of "$page" schemes)
  assert_not_contains "$html" 'href="javascript:' "javascript links must be inert"
  assert_not_contains "$html" 'href="vbscript:' "vbscript links must be inert"
  assert_not_contains "$html" 'href="file:' "file links must be inert"
  assert_not_contains "$html" 'href="javascript&#58;' "entity-obfuscated schemes must be inert"
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
  expect_code 1 "$status" "link must refuse an id that has no report"
  assert_contains "$out" 'no such report: gone' "link must name the missing report"
  pass "link proves its report exists before handing out an anchor"
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
  assert_equals 1 "$(payload_of "$page" | jq 'length')" "the shipped template must carry the built payload"
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
test_symlinked_report_is_not_read
test_path_prints_the_page_path
test_link_proves_the_report_exists
test_build_refuses_without_a_home
test_unsafe_link_and_image_schemes_are_rejected
test_shipped_template_build_replaces_both_slots
test_build_refuses_a_template_without_a_slot
test_page_fetches_nothing
