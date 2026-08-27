#!/usr/bin/env bash
# Browser-level layout regressions for the shipped bearings fleet board.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BOARD="$ROOT/bin/fm-bearings-board.sh"
TMP_ROOT=$(fm_test_tmproot fm-bearings-board-layout)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }

find_chrome() {
  local candidate
  if [ -n "${FM_CHROME_BIN:-}" ] && [ -x "$FM_CHROME_BIN" ]; then
    printf '%s\n' "$FM_CHROME_BIN"
    return 0
  fi
  for candidate in \
    google-chrome \
    google-chrome-stable \
    chromium \
    chromium-browser \
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
  do
    if command -v "$candidate" >/dev/null 2>&1; then
      command -v "$candidate"
      return 0
    fi
  done
  return 1
}

CHROME=$(find_chrome) || { echo "skip: Chrome or Chromium not found"; exit 0; }

make_board() {
  local home="$TMP_ROOT/home" fakebin data long_title long_reason long_level long_detail board
  mkdir -p "$home/state" "$home/data"
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" lavish-axi
  data="$home/payload.json"
  long_title="$(printf 'Readable title segment %.0s' {1..24})"
  long_reason="$(printf 'Readable secondary context %.0s' {1..18})"
  long_level="$(printf 'x%.0s' {1..180})"
  long_detail="$(printf 'y%.0s' {1..180})"
  jq -n \
    --arg title "$long_title" \
    --arg reason "$long_reason" \
    --arg long_level "$long_level" \
    --arg long_detail "$long_detail" '{
      schema:"fm-bearings-board.v1",
      home:"layout-home",
      generated:"2026-08-27T00:00Z",
      prs_live:false,
      captains_call:[
        {
          key:"long-level",
          type:"merge",
          repo:"sample",
          title:"Keep an unbroken risk level inside its card",
          risk:$long_level,
          options:[{value:"merge", label:"Merge"}]
        },
        {
          key:"long-detail",
          type:"merge",
          repo:"sample",
          title:"Keep a moved risk justification readable",
          risk:("faible. " + $long_detail),
          options:[{value:"merge", label:"Merge"}]
        }
      ],
      underway:[],
      landed:[],
      charted:[{
        id:"long-row",
        repo:"sample",
        title:$title,
        reason:$reason,
        dispatchable:true
      }],
      charted_more:0,
      charted_warning_more:0
    }' > "$data"
  PATH="$fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$BOARD" build "$data" >/dev/null || fail "the layout fixture board did not build"
  board="$home/.lavish/bearings-board.html"
  node - "$board" <<'JS' || fail "the browser layout probe could not be installed"
const fs = require("node:fs");
const path = process.argv[2];
const html = fs.readFileSync(path, "utf8");
const probe = String.raw`<script>
(function () {
  function lineCount(element) {
    var style = getComputedStyle(element);
    return element.getBoundingClientRect().height / parseFloat(style.lineHeight);
  }
  function within(inner, outer) {
    var innerRect = inner.getBoundingClientRect();
    var outerRect = outer.getBoundingClientRect();
    return innerRect.left >= outerRect.left - 0.5 && innerRect.right <= outerRect.right + 0.5;
  }
  var title = document.querySelector("#bb-charted .bb-row__title");
  var subtitle = document.querySelector("#bb-charted .bb-row__sub");
  var firstCard = document.querySelector("#bb-call .bb-decision:not([hidden])");
  var riskPin = firstCard.querySelector(".bb-decision__risk");
  var result = {
    titleLines: lineCount(title),
    subtitleLines: lineCount(subtitle),
    riskPinInsideCard: within(riskPin, firstCard),
    scrollWidth: document.documentElement.scrollWidth,
    viewportWidth: window.innerWidth
  };
  document.getElementById("bb-stack-next").click();
  var secondCard = document.querySelector("#bb-call .bb-decision:not([hidden])");
  var riskValue = secondCard.querySelector(".bb-ctx__v");
  result.riskValueInsideCard = within(riskValue, secondCard);
  result.riskValueLines = lineCount(riskValue);
  result.riskValueScrollWidth = riskValue.scrollWidth;
  result.riskValueClientWidth = riskValue.clientWidth;
  var output = document.createElement("pre");
  output.id = "fm-layout-result";
  output.textContent = JSON.stringify(result);
  document.body.appendChild(output);
}());
</script>`;
if (!html.includes("</body>")) process.exit(1);
fs.writeFileSync(path, html.replace("</body>", `${probe}\n</body>`));
JS
  printf '%s\n' "$board"
}

render_viewport() {
  local board=$1 width=$2 dom="$TMP_ROOT/layout-$2.html" profile="$TMP_ROOT/chrome-$2"
  local chrome_pid chrome_wait=0
  "$CHROME" \
    --headless=new \
    --disable-gpu \
    --no-sandbox \
    --user-data-dir="$profile" \
    --window-size="$width,900" \
    --virtual-time-budget=2000 \
    --dump-dom \
    "file://$board" > "$dom" 2>/dev/null &
  chrome_pid=$!
  while kill -0 "$chrome_pid" 2>/dev/null && [ "$chrome_wait" -lt 100 ]; do
    if grep -Fq '</html>' "$dom" 2>/dev/null && grep -Fq 'id="fm-layout-result"' "$dom" 2>/dev/null; then
      break
    fi
    sleep 0.1
    chrome_wait=$((chrome_wait + 1))
  done
  kill "$chrome_pid" 2>/dev/null || true
  wait "$chrome_pid" 2>/dev/null || true
  if ! grep -Fq '</html>' "$dom" 2>/dev/null \
    || ! grep -Fq 'id="fm-layout-result"' "$dom" 2>/dev/null; then
    fail "the board did not render in a ${width}px browser viewport"
  fi
  node - "$dom" "$width" <<'JS' || fail "the board layout escaped its bounds at ${width}px"
const fs = require("node:fs");
const dom = fs.readFileSync(process.argv[2], "utf8");
const width = Number(process.argv[3]);
const match = dom.match(/<pre id="fm-layout-result">([^<]+)<\/pre>/);
if (!match) throw new Error("the browser did not emit layout measurements");
const result = JSON.parse(match[1]);
const close = (actual, expected) => Math.abs(actual - expected) <= 0.08;
const failures = [];
if (!(result.titleLines > 1.5 && result.titleLines <= 3.08)) failures.push(`title lines=${result.titleLines}`);
if (!(result.subtitleLines > 1.5 && result.subtitleLines <= 2.08)) failures.push(`subtitle lines=${result.subtitleLines}`);
if (!result.riskPinInsideCard) failures.push("risk pin left its card");
if (!result.riskValueInsideCard) failures.push("risk detail box left its card");
if (!(result.riskValueLines > 1.5)) failures.push(`risk detail lines=${result.riskValueLines}`);
if (result.riskValueScrollWidth > result.riskValueClientWidth + 1) {
  failures.push(`risk detail scroll=${result.riskValueScrollWidth}, client=${result.riskValueClientWidth}`);
}
if (result.scrollWidth !== result.viewportWidth || result.viewportWidth !== width) {
  failures.push(`document=${result.scrollWidth}, viewport=${result.viewportWidth}, requested=${width}`);
}
if (failures.length) throw new Error(failures.join("; "));
if (!close(result.titleLines, 3)) throw new Error(`long title did not reach its three-line clamp: ${result.titleLines}`);
if (!close(result.subtitleLines, 2)) throw new Error(`long subtitle did not reach its two-line clamp: ${result.subtitleLines}`);
JS
}

board=$(make_board) || exit 1
render_viewport "$board" 1440
render_viewport "$board" 620
pass "bearings rows and risk text stay readable and contained at desktop and narrow widths"
