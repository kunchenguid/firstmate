#!/usr/bin/env bash
# Behavior tests for the dependency-free static report and Bearings presenter.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PRESENTER="$ROOT/bin/fm-present-report.sh"
TMP_ROOT=$(fm_test_tmproot fm-present-report)
HOME_DIR="$TMP_ROOT/home"
FAKEBIN="$TMP_ROOT/fakebin"
OPEN_LOG="$TMP_ROOT/open.log"
NET_LOG="$TMP_ROOT/network.log"
NOW=2026-07-26T14:20:39Z
mkdir -p "$HOME_DIR" "$FAKEBIN"
: >"$OPEN_LOG"
: >"$NET_LOG"
trap fm_test_cleanup EXIT

cat >"$FAKEBIN/uname" <<'SH'
#!/usr/bin/env bash
printf 'Darwin\n'
SH
cat >"$FAKEBIN/open" <<'SH'
#!/usr/bin/env bash
printf 'open %s\n' "$1" >>"$OPEN_LOG"
[ "${FAIL_OPEN:-0}" != 1 ]
SH
cat >"$FAKEBIN/xdg-open" <<'SH'
#!/usr/bin/env bash
printf 'xdg-open %s\n' "$1" >>"$OPEN_LOG"
[ "${FAIL_OPEN:-0}" != 1 ]
SH
for tool in curl gh gh-axi wget; do
  cat >"$FAKEBIN/$tool" <<'SH'
#!/usr/bin/env bash
printf '%s %s\n' "$(basename "$0")" "$*" >>"$NET_LOG"
exit 91
SH
  chmod +x "$FAKEBIN/$tool"
done
chmod +x "$FAKEBIN/uname" "$FAKEBIN/open" "$FAKEBIN/xdg-open"

run_presenter() {
  PATH="$FAKEBIN:$PATH" \
    FM_HOME="$HOME_DIR" \
    FM_PRESENT_NOW="$NOW" \
    OPEN_LOG="$OPEN_LOG" \
    NET_LOG="$NET_LOG" \
    "$PRESENTER" "$@"
}

SOURCE="$HOME_DIR/data/sample-report.md"
mkdir -p "$(dirname "$SOURCE")"
cat >"$SOURCE" <<'MD'
# Danger & calm <script>alert("bad")</script>

A complete **outcome** with `code & evidence`.

## Captain's Call

- Choose A <img src=x onerror=alert(1)>

## Evidence

```text
raw <failure> & output
```
MD

SNAPSHOT="$TMP_ROOT/bearings.json"
cat >"$SNAPSHOT" <<'JSON'
{
  "schema": "fm-bearings.v1",
  "home": "fixture/home",
  "generated": "2026-07-26T14:19:00Z",
  "prs": "not_requested (run: /bearings include PRs)",
  "in_flight": [
    {"id":"worker-alpha","kind":"ship","state":"working","doing":"Implement <safe> output"},
    {"id":"mate-active","kind":"secondmate","state":"active_child_work","doing":"Running child work"}
  ],
  "secondmates": [
    {"id":"mate-active","state":"active_child_work","doing":"Running child work","provenance":"structured-home","freshness":"fresh","age_seconds":2,"contradiction":false,"reason":"-"},
    {"id":"mate-held","state":"externally_held","doing":"Waiting on vendor","provenance":"structured-home","freshness":"fresh","age_seconds":3,"contradiction":false,"reason":"vendor window"}
  ],
  "decisions_open": [
    {"id":"decision-one","key":"route","verb":"captain-hold","summary":"Choose <route> A or B","owner":"(main)"}
  ],
  "landed": [
    {"id":"landed-one","what":"Completed & verified","artifact":"data/landed/report.md","owner":"(main)"}
  ],
  "gates": [
    {"id":"gate-one","title":"Wait for release","blocked_by":"worker-alpha","reason":"dependency","owner":"(main)"},
    {"id":"task-1","title":"Main queue item","blocked_by":"-","reason":"queued","owner":"(main)"},
    {"id":"task-1","title":"Secondmate queue item","blocked_by":"-","reason":"queued","owner":"mate-held"}
  ],
  "reports": [],
  "recorded_prs": [],
  "omitted": [
    {"surface":"live PR discovery + checks","reveal":"--include-prs"}
  ]
}
JSON

test_markdown_html_is_local_escaped_accessible_and_quiet() {
  local out html body
  out=$(run_presenter markdown --source "$SOURCE") || fail "Markdown presentation failed: $out"
  case "$out" in html:*) html=${out#html:} ;; *) fail "Markdown presenter did not return an HTML artifact: $out" ;; esac
  [ "$html" = "$HOME_DIR/.lavish/sample-report-20260726T142039Z.html" ] \
    || fail "Markdown artifact path was not timestamped under the effective home's .lavish: $html"
  [ -f "$html" ] || fail "Markdown HTML artifact was not created"
  body=$(cat "$html")
  assert_contains "$body" '<html lang="en">' "static report language landmark"
  assert_contains "$body" '<meta name="viewport"' "static report responsive viewport"
  assert_contains "$body" 'Content-Security-Policy' "static report local-only content policy"
  assert_contains "$body" '<a class="skip-link" href="#content">Skip to report</a>' "static report skip link"
  assert_contains "$body" '<main id="content"' "static report main landmark"
  assert_contains "$body" ':focus-visible' "static report keyboard focus treatment"
  assert_contains "$body" 'prefers-reduced-motion' "static report reduced-motion treatment"
  assert_contains "$body" '&lt;script&gt;alert(&quot;bad&quot;)&lt;/script&gt;' "Markdown content must be escaped"
  assert_contains "$body" '&lt;img src=x onerror=alert(1)&gt;' "Markdown list content must be escaped"
  assert_not_contains "$body" '<script>' "static report must not execute source markup or client JavaScript"
  assert_not_contains "$body" 'http-equiv="refresh"' "static report must not auto-refresh"
  assert_contains "$body" "$SOURCE" "static report canonical Markdown source"
  [ ! -s "$OPEN_LOG" ] || fail "default report rendering opened a browser without an explicit request"
  [ ! -s "$NET_LOG" ] || fail "static report rendering made a network call: $(cat "$NET_LOG")"
  pass "Markdown presentation is escaped, accessible, timestamped, local-only, and does not open unsolicited tabs"
}

test_bearings_page_has_all_current_rows_once_and_discloses_freshness() {
  local out html body id count headings expected
  out=$(run_presenter bearings --source "$SOURCE" --snapshot "$SNAPSHOT") \
    || fail "Bearings presentation failed: $out"
  case "$out" in html:*) html=${out#html:} ;; *) fail "Bearings presenter did not return an HTML artifact: $out" ;; esac
  [ "$html" = "$HOME_DIR/.lavish/bearings-20260726T142039Z.html" ] \
    || fail "Bearings artifact path was not timestamped: $html"
  body=$(cat "$html")
  for id in worker-alpha mate-active mate-held decision-one landed-one gate-one; do
    count=$(grep -Fo "data-record-id=\"$id\"" "$html" | wc -l | tr -d ' ')
    [ "$count" -eq 1 ] || fail "Bearings row $id appeared $count times instead of once"
  done
  count=$(grep -Fo 'data-record-id="task-1"' "$html" | wc -l | tr -d ' ')
  [ "$count" -eq 2 ] || fail "Bearings rows with matching IDs from separate homes appeared $count times instead of twice"
  headings=$(printf '%s' "$body" | grep -Eo '<h2[^>]*>[^<]+' | sed -E 's/<h2[^>]*>//')
  expected=$(printf '%s\n' "Captain's Call" "Recently Landed" "Underway" "Charted Next")
  [ "$headings" = "$expected" ] || fail "Bearings sections changed order: $headings"
  assert_contains "$body" '<time datetime="2026-07-26T14:19:00Z">' "Bearings source observation timestamp"
  assert_contains "$body" 'fresh · observed 2s before snapshot' "Bearings secondmate freshness"
  assert_contains "$body" 'Main queue item' "main-home queued item with a shared ID"
  assert_contains "$body" 'Secondmate queue item' "secondmate-home queued item with a shared ID"
  assert_contains "$body" 'Run <code>/bearings</code> again to refresh.' "Bearings honest refresh instruction"
  assert_contains "$body" 'fm-bearings.v1' "Bearings source schema disclosure"
  assert_contains "$body" 'live PR discovery + checks' "Bearings omission disclosure"
  assert_contains "$body" '&lt;safe&gt;' "Bearings task content escaping"
  assert_contains "$body" '&lt;route&gt;' "Bearings decision content escaping"
  assert_not_contains "$body" '<script>' "Bearings page must not contain client JavaScript"
  assert_not_contains "$body" 'http-equiv="refresh"' "Bearings page must remain a static snapshot"
  [ ! -s "$OPEN_LOG" ] || fail "Bearings rendering without --open opened a tab"
  [ ! -s "$NET_LOG" ] || fail "Bearings rendering made a network call: $(cat "$NET_LOG")"
  pass "Bearings renders every all-current worker, secondmate, decision, completion, and gate exactly once with timestamp and omissions"
}

test_open_is_explicit_and_browser_failure_falls_back_to_markdown() {
  local out html err rc
  : >"$OPEN_LOG"
  out=$(run_presenter markdown --source "$SOURCE" --open) || fail "explicit report open failed: $out"
  html=${out#html:}
  [ "$(cat "$OPEN_LOG")" = "open $html" ] || fail "explicit --open did not open exactly the generated local page"

  : >"$OPEN_LOG"
  err="$TMP_ROOT/open.err"
  out=$(FAIL_OPEN=1 run_presenter markdown --source "$SOURCE" --open 2>"$err"); rc=$?
  [ "$rc" -eq 0 ] || fail "browser opener failure blocked report completion"
  [ "$out" = "markdown:$SOURCE" ] || fail "browser opener failure did not return the canonical Markdown fallback: $out"
  assert_contains "$(cat "$err")" "could not open" "browser failure fallback warning"
  [ "$(wc -l <"$OPEN_LOG" | tr -d ' ')" -eq 1 ] || fail "browser failure retried or opened multiple tabs"
  [ ! -s "$NET_LOG" ] || fail "explicit local opening made a network call: $(cat "$NET_LOG")"
  pass "only explicit --open launches a local page and opener failure falls back without blocking"
}

test_render_failure_falls_back_without_partial_page() {
  local broken out err rc before after
  broken="$TMP_ROOT/broken.json"
  printf '{not json\n' >"$broken"
  before=$(find "$HOME_DIR/.lavish" -type f | wc -l | tr -d ' ')
  err="$TMP_ROOT/render.err"
  out=$(run_presenter bearings --source "$SOURCE" --snapshot "$broken" --open 2>"$err"); rc=$?
  after=$(find "$HOME_DIR/.lavish" -type f | wc -l | tr -d ' ')
  [ "$rc" -eq 0 ] || fail "HTML rendering failure blocked canonical report completion"
  [ "$out" = "markdown:$SOURCE" ] || fail "HTML rendering failure did not return the Markdown fallback: $out"
  [ "$before" -eq "$after" ] || fail "HTML rendering failure left a partial page"
  assert_contains "$(cat "$err")" "could not render" "render failure fallback warning"
  [ "$(wc -l <"$OPEN_LOG" | tr -d ' ')" -eq 1 ] || fail "render failure attempted to open a browser"
  [ ! -s "$NET_LOG" ] || fail "render failure fallback made a network call: $(cat "$NET_LOG")"
  pass "rendering failure leaves no partial page and falls back to canonical Markdown"
}

assert_present "$PRESENTER" "static report presentation owner is missing"
test_markdown_html_is_local_escaped_accessible_and_quiet
test_bearings_page_has_all_current_rows_once_and_discloses_freshness
test_open_is_explicit_and_browser_failure_falls_back_to_markdown
test_render_failure_falls_back_without_partial_page
