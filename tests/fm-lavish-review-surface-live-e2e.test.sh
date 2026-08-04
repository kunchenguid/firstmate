#!/usr/bin/env bash
# Opt-in live regression for Firstmate's Lavish review-surface contract.
# It drives the installed Lavish Editor and chrome-devtools-axi against a
# self-contained frontend review fixture.
# The fixture exposes separate desktop and mobile product targets, selects both
# through the real annotation card, verifies the queued-comment transition, and
# confirms lavish-axi poll receives element-specific selectors instead of a
# whole-page or report-shell target.
set -u

if [ "${FM_LAVISH_REVIEW_SURFACE_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_LAVISH_REVIEW_SURFACE_LIVE_E2E=1 to run the Lavish review-surface live regression"
  exit 0
fi

TMP_ROOT=
PORT=
CHROME_PORT=
CHROME_SESSION=

fail() {
  printf 'not ok - %s\n' "$1" >&2
  cleanup
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

assert_contains() {
  case "$1" in
    *"$2"*) : ;;
    *) fail "$3 (missing: '$2')"$'\n'"--- output ---"$'\n'"$1" ;;
  esac
}

assert_not_contains() {
  case "$1" in
    *"$2"*) fail "$3 (unexpected: '$2')"$'\n'"--- output ---"$'\n'"$1" ;;
    *) : ;;
  esac
}

command -v lavish-axi >/dev/null 2>&1 || fail "lavish-axi not found"
command -v chrome-devtools-axi >/dev/null 2>&1 || fail "chrome-devtools-axi not found"

cleanup() {
  [ -z "$CHROME_SESSION" ] || CHROME_DEVTOOLS_AXI_SESSION="$CHROME_SESSION" CHROME_DEVTOOLS_AXI_PORT="$CHROME_PORT" chrome-devtools-axi stop >/dev/null 2>&1 || true
  [ -z "$PORT" ] || LAVISH_AXI_PORT="$PORT" lavish-axi stop --port "$PORT" >/dev/null 2>&1 || true
  [ -z "$TMP_ROOT" ] || rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-lavish-review-surface.XXXXXX")
STATE_DIR="$TMP_ROOT/lavish-state"
ARTIFACT="$TMP_ROOT/frontend-review.html"
EVIDENCE_DIR=${FM_LAVISH_REVIEW_SURFACE_EVIDENCE_DIR:-}
PORT=$((4387 + ($$ % 1000) + 1000))
CHROME_PORT=$((9224 + ($$ % 1000) + 1000))
CHROME_SESSION="fm-lavish-review-surface-$$"
export TMP_ROOT STATE_DIR ARTIFACT PORT CHROME_PORT CHROME_SESSION

mkdir -p "$STATE_DIR"
if [ -n "$EVIDENCE_DIR" ]; then
  mkdir -p "$EVIDENCE_DIR"
fi

cat > "$ARTIFACT" <<'HTML'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Firstmate Lavish frontend review fixture</title>
  <style>
    * { box-sizing: border-box; }
    body {
      margin: 0;
      font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      background: #f6f4ef;
      color: #171717;
    }
    main {
      display: grid;
      gap: 24px;
      min-height: 100vh;
      padding: 28px;
    }
    .review-grid {
      display: grid;
      grid-template-columns: minmax(0, 1fr) minmax(280px, 390px);
      gap: 24px;
      align-items: start;
    }
    .surface {
      border: 1px solid #c8c3b8;
      background: #fffefa;
      box-shadow: 0 14px 30px rgba(30, 28, 22, 0.08);
    }
    .desktop {
      min-height: 520px;
      border-radius: 6px;
    }
    .mobile {
      min-height: 640px;
      border-radius: 28px;
      overflow: hidden;
    }
    .target {
      display: block;
      margin: 18px;
      border: 2px solid #2f6f73;
      background: rgba(47, 111, 115, 0.08);
      outline-offset: 2px;
    }
    .desktop-nav {
      padding: 18px 22px;
      font-weight: 700;
    }
    .desktop-card {
      padding: 22px;
    }
    .mobile-search {
      margin: 18px 16px;
      padding: 16px;
      border-radius: 18px;
      font-weight: 700;
    }
    .label {
      display: block;
      color: #5f5b51;
      font-size: 12px;
      font-weight: 700;
      letter-spacing: 0;
      margin-bottom: 8px;
      text-transform: uppercase;
    }
    .visual-button,
    .visual-input {
      display: inline-block;
      border: 1px solid #b6b0a3;
      border-radius: 6px;
      padding: 10px 12px;
      background: #f3f0e7;
    }
    @media (max-width: 820px) {
      .review-grid { grid-template-columns: minmax(0, 1fr); }
      main { padding: 16px; }
    }
  </style>
</head>
<body>
  <main aria-label="Review subject">
    <section class="review-grid" aria-label="Desktop and mobile presentations">
      <article class="surface desktop" aria-label="Desktop product presentation">
        <nav id="desktop-nav-target" class="target desktop-nav" aria-label="Desktop navigation target">
          Desktop navigation target: Overview, Search, Reports, Settings
        </nav>
        <section id="desktop-oauth-target" class="target desktop-card" aria-label="Desktop OAuth sign-in target">
          <span class="label">OAuth sign-in control</span>
          <span class="visual-button">Sign in with GitHub</span>
        </section>
      </article>
      <article class="surface mobile" aria-label="Mobile product presentation">
        <form id="mobile-search-target" class="target mobile-search" aria-label="Mobile search target">
          <span class="label">Mobile search control</span>
          <span class="visual-input">Search clients</span>
        </form>
      </article>
    </section>
  </main>
</body>
</html>
HTML

[ -z "$EVIDENCE_DIR" ] || cp "$ARTIFACT" "$EVIDENCE_DIR/frontend-review.html"

lavish() {
  LAVISH_AXI_STATE_DIR="$STATE_DIR" LAVISH_AXI_PORT="$PORT" LAVISH_AXI_NO_OPEN=1 lavish-axi "$@"
}

cdt() {
  CHROME_DEVTOOLS_AXI_SESSION="$CHROME_SESSION" CHROME_DEVTOOLS_AXI_PORT="$CHROME_PORT" chrome-devtools-axi "$@"
}

uid_for() {
  local output=$1 needle=$2 label=$3 uid
  uid=$(printf '%s\n' "$output" | awk -v needle="$needle" '
    index($0, needle) {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^uid=/) {
          sub(/^uid=/, "", $i)
          print $i
          exit
        }
      }
    }
  ')
  [ -n "$uid" ] || fail "could not find $label in chrome-devtools snapshot"
  printf '%s\n' "$uid"
}

click_uid() {
  local uid=$1 label=$2 output status
  output=$(cdt click "@$uid" 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "chrome-devtools click failed for $label: $output"
  printf '%s\n' "$output"
}

capture_stage() {
  local name=$1 image log
  [ -n "$EVIDENCE_DIR" ] || return 0
  image="$EVIDENCE_DIR/$name.png"
  log="$EVIDENCE_DIR/$name.screenshot.log"
  if cdt screenshot "$image" > "$log" 2>&1 && [ -s "$image" ]; then
    return 0
  fi
  printf 'chrome-devtools-axi screenshot unavailable; see %s.snapshot.txt for browser-accessibility evidence.\n' "$name" \
    > "$EVIDENCE_DIR/$name.screenshot-unavailable.txt"
  rm -f "$image"
}

record_stage() {
  local name=$1 output=$2
  [ -n "$EVIDENCE_DIR" ] || return 0
  printf '%s\n' "$output" > "$EVIDENCE_DIR/$name.snapshot.txt"
  capture_stage "$name"
}

select_and_queue() {
  local target_needle=$1 prompt=$2 target_label=$3 snapshot target_uid out textarea_uid queue_uid
  cdt wait 400 >/dev/null 2>&1 || true
  snapshot=$(cdt snapshot)
  assert_contains "$snapshot" "$target_needle" "$target_label was not exposed as a selectable browser target"
  target_uid=$(uid_for "$snapshot" "$target_needle" "$target_label")
  out=$(click_uid "$target_uid" "$target_label")
  assert_contains "$out" 'textbox "Tell the agent what to change about this element..."' \
    "$target_label click did not open the Lavish annotation card"
  record_stage "$target_label-card" "$out"
  textarea_uid=$(uid_for "$out" 'textbox "Tell the agent what to change about this element..."' "$target_label annotation textarea")
  if ! out=$(cdt fill "@$textarea_uid" "$prompt" 2>&1); then
    fail "could not fill annotation for $target_label: $out"
  fi
  queue_uid=$(uid_for "$out" 'button "Queue"' "$target_label queue button")
  out=$(click_uid "$queue_uid" "$target_label queue button")
  assert_contains "$out" "$prompt" "$target_label annotation text did not enter the conversation queue"
  assert_contains "$out" 'button "Remove queued prompt"' "$target_label queued prompt did not expose a removable review-queue entry"
  record_stage "$target_label-queued" "$out"
}

if ! open_out=$(lavish "$ARTIFACT" --no-open --no-gate 2>&1); then
  fail "lavish-axi did not open the fixture: $open_out"
fi
url=$(printf '%s\n' "$open_out" | sed -n 's/^  url: "\(.*\)"$/\1/p' | sed -n '1p')
[ -n "$url" ] || fail "lavish-axi did not print a session URL: $open_out"

cdt start >/dev/null || fail "chrome-devtools-axi could not start Chrome"
cdt open "$url" >/dev/null || fail "chrome-devtools-axi could not open Lavish session at $url"
cdt resize 1360 900 >/dev/null || fail "chrome-devtools-axi could not size the browser"
cdt wait "Mobile search target" >/dev/null || fail "Lavish artifact never rendered the mobile target"

initial=$(cdt snapshot)
assert_contains "$initial" 'navigation "Desktop navigation target' "desktop navigation target missing from accessible artifact"
assert_contains "$initial" 'form "Mobile search target' "mobile search target missing from accessible artifact"
assert_contains "$initial" 'complementary' "Lavish conversation chrome missing from live review"
record_stage "01-initial-subject" "$initial"

select_and_queue 'navigation "Desktop navigation target' \
  "Desktop annotation: tighten the navigation priority." \
  "02-desktop-navigation"

cdt resize 390 844 >/dev/null || fail "chrome-devtools-axi could not switch to a mobile viewport"
cdt wait "Mobile search target" >/dev/null || fail "Lavish artifact did not keep the mobile target available in a mobile viewport"
mobile_initial=$(cdt snapshot)
assert_contains "$mobile_initial" 'form "Mobile search target' "mobile search target missing from mobile viewport"
record_stage "03-mobile-viewport-subject" "$mobile_initial"

select_and_queue 'form "Mobile search target' \
  "Mobile annotation: expose the filter action inside search." \
  "04-mobile-search"

send_snapshot=$(cdt snapshot)
send_uid=$(uid_for "$send_snapshot" 'button "Send to Agent"' "Send to Agent button")
click_uid "$send_uid" "Send to Agent button" >/dev/null
cdt wait 400 >/dev/null 2>&1 || true

if ! poll_out=$(lavish poll "$ARTIFACT" --timeout-ms 2000 2>&1); then
  fail "lavish-axi poll failed after queued annotations: $poll_out"
fi
assert_contains "$poll_out" 'status: feedback' "Lavish poll did not enter feedback state after sending annotations"
assert_contains "$poll_out" 'prompts[2]' "Lavish poll did not receive both queued annotations"
assert_contains "$poll_out" 'Desktop annotation: tighten the navigation priority.' "desktop annotation prompt missing from poll"
assert_contains "$poll_out" 'Mobile annotation: expose the filter action inside search.' "mobile annotation prompt missing from poll"
assert_contains "$poll_out" 'nav#desktop-nav-target' "desktop annotation was not bound to the desktop navigation element"
assert_contains "$poll_out" 'form#mobile-search-target' "mobile annotation was not bound to the mobile search element"
assert_not_contains "$poll_out" ',body,' "annotation fell back to the whole body"
assert_not_contains "$poll_out" ',main,' "annotation fell back to the whole review shell"

if [ -n "$EVIDENCE_DIR" ]; then
  printf '%s\n' "$poll_out" > "$EVIDENCE_DIR/poll-output.txt"
  shasum -a 256 "$ARTIFACT" > "$EVIDENCE_DIR/artifact.sha256"
fi

pass "Lavish review surface exposes desktop and mobile product targets, queues annotations, and polls element-specific feedback"
