#!/usr/bin/env bash
# Default-on live guard for Firstmate's Pi inline image display under the REAL
# Pi TUI in a REAL Herdr pane, with a real attached Herdr client standing in for
# the outer terminal. It measures the vendor facts /image and fm_show_image rest
# on, which no fixture can prove:
#
#   1. Pi restores a recorded fm_show_image result through the extension's own
#      renderer, and /image adds a second image to the same transcript;
#   2. Pi, seeing the WezTerm identity a Herdr pane inherits from the terminal
#      that started its server, draws both images through the Kitty graphics
#      protocol (Pi's raw terminal write log);
#   3. Herdr consumes those graphics commands inside the pane, so pane reads
#      show the path lines and never a graphics escape or image payload;
#   4. Herdr relays the image to an attached client whose cell size is known,
#      as an upload of the decoded pixels plus a placement (the capturing lab
#      viewer's recorded output).
#
# Whether the outer terminal then paints those commands is that terminal's
# fact; docs/verification/runtime-backends.md records the WezTerm evidence.
# Pi starts with an empty private agent directory, no model, and no prompt, so
# no model token is spent and the shared live gate runs it by default wherever
# herdr, pi, jq, and python3 are installed. Re-run it after every Herdr or Pi
# upgrade. Every Herdr call goes through the guarded lab helper against a
# named, throwaway, non-default session (bin/fm-herdr-lab.sh).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_PI_IMAGE_HERDR_LIVE_E2E herdr pi jq python3

LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
[ -x "$LAB_HELPER" ] || fail "Herdr lab helper not executable at $LAB_HELPER"

HERDR_VERSION=$(herdr --version 2>&1 | head -1)
HERDR_VERSION=${HERDR_VERSION#herdr }
PI_VERSION=$(pi --version 2>/dev/null | head -1 | tr -d '\r')
[ -n "$PI_VERSION" ] || PI_VERSION=unknown
version_fail() { # <message>
  fail "$1 [herdr $HERDR_VERSION, pi $PI_VERSION]"
}

# A test started from inside a Herdr pane must not carry that pane's identity
# into the lab server it provisions.
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION

TMP_ROOT=$(fm_test_tmproot fm-pi-image-herdr)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
mkdir -p "$TMP_ROOT/cwd" "$TMP_ROOT/agent"
IMAGE="$TMP_ROOT/cwd/pattern.png"
SESSION_FILE="$TMP_ROOT/session.jsonl"
TUI_LOG="$TMP_ROOT/pi-tui.log"
CAPTURE="$TMP_ROOT/client.bin"

# The fixture PNG, and a session whose last tool call is an fm_show_image
# result. A 240x160 PNG is its own display copy, so the recorded details are
# exactly what the tool would have returned.
python3 - "$IMAGE" "$SESSION_FILE" "$TMP_ROOT/cwd" <<'PY' || fail "could not write the fixture image and session"
import base64, json, struct, sys, time, zlib
image_path, session_path, cwd = sys.argv[1:4]
width, height = 240, 160
rows = b"".join(
    b"\x00" + bytes(((x * 255) // width if c == 0 else (y * 255) // height if c == 1 else 96) for x in range(width) for c in range(3))
    for y in range(height)
)
def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
png = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
       + chunk(b"IDAT", zlib.compress(rows, 9)) + chunk(b"IEND", b""))
with open(image_path, "wb") as out:
    out.write(png)
now = int(time.time() * 1000)
stamp = time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime())
usage = {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0, "totalTokens": 0,
         "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0, "total": 0}}
view = {"path": image_path, "mimeType": "image/png", "width": width, "height": height, "bytes": len(png),
        "display": {"data": base64.b64encode(png).decode(), "width": width, "height": height}}
entries = [
    {"type": "session", "version": 3, "id": "fm-pi-image-live", "timestamp": stamp, "cwd": cwd},
    {"type": "message", "id": "e0000001", "parentId": None, "timestamp": stamp,
     "message": {"role": "user", "content": "show the pattern", "timestamp": now}},
    {"type": "message", "id": "e0000002", "parentId": "e0000001", "timestamp": stamp,
     "message": {"role": "assistant", "content": [{"type": "toolCall", "id": "call_fm_show_image", "name": "fm_show_image",
                 "arguments": {"path": "pattern.png"}}], "api": "openai-responses", "provider": "openai", "model": "fixture",
                 "usage": usage, "stopReason": "toolUse", "timestamp": now + 1}},
    {"type": "message", "id": "e0000003", "parentId": "e0000002", "timestamp": stamp,
     "message": {"role": "toolResult", "toolCallId": "call_fm_show_image", "toolName": "fm_show_image",
                 "content": [{"type": "text", "text": "Showing the image inline: " + image_path}],
                 "details": view, "isError": False, "timestamp": now + 2}},
]
with open(session_path, "w") as out:
    out.write("".join(json.dumps(entry) + "\n" for entry in entries))
PY

LAB_SESSION=$("$LAB_HELPER" name fm-pi-image) || fail "could not name the lab session"
cleanup() {
  local status=$?
  "$LAB_HELPER" viewer stop "$LAB_SESSION" >/dev/null 2>&1 || status=1
  "$LAB_HELPER" teardown "$LAB_SESSION" || status=1
  fm_test_cleanup
  exit "$status"
}
trap cleanup EXIT
"$LAB_HELPER" provision "$LAB_SESSION" || fail "could not provision the isolated Herdr lab"

lab() { "$LAB_HELPER" run "$LAB_SESSION" "$@"; }
pane_text() { lab pane read "$PANE" --source recent --lines 80 2>/dev/null; }
wait_for_pane_text() { # <needle> <tries>
  local i=0
  while [ "$i" -lt "$2" ]; do
    pane_text | grep -Fq "$1" && return 0
    sleep 0.25
    i=$((i + 1))
  done
  return 1
}

WS=$(lab workspace create --label fm-pi-image --cwd "$TMP_ROOT/cwd" 2>&1) \
  || fail "could not create the lab workspace: $WS"
PANE=$(printf '%s' "$WS" | jq -r '.result.root_pane.pane_id // empty')
[ -n "$PANE" ] || fail "workspace create did not return a root pane id"

"$LAB_HELPER" viewer start "$LAB_SESSION" --capture "$CAPTURE" >/dev/null \
  || fail "could not attach a capturing Herdr viewer to the lab session"

# Pi runs with a private agent directory, only the extension under test, and
# the WezTerm identity set explicitly, so the verdict does not depend on which
# terminal or multiplexer started this test.
lab pane run "$PANE" "env -u TMUX -u KITTY_WINDOW_ID -u ITERM_SESSION_ID -u GHOSTTY_RESOURCES_DIR TERM_PROGRAM=WezTerm PI_CODING_AGENT_DIR='$TMP_ROOT/agent' PI_OFFLINE=1 PI_SKIP_VERSION_CHECK=1 PI_TELEMETRY=0 PI_TUI_WRITE_LOG='$TUI_LOG' pi --session '$SESSION_FILE' --no-extensions --extension '$ROOT/.pi/extensions/fm-image.ts' --no-skills --no-context-files --no-themes --no-approve" >/dev/null \
  || fail "could not start pi in the lab pane"
wait_for_pane_text "pi v" 160 || version_fail "the Pi TUI did not start in the lab pane: $(pane_text | tail -5)"
wait_for_pane_text "[Image:" 80 || version_fail "the restored fm_show_image result drew no path line: $(pane_text | tail -8)"
assert_contains "$(pane_text)" "show image pattern.png" "the restored fm_show_image call row did not use the extension's renderer"
pass "real pi $PI_VERSION restores an fm_show_image result through the extension's own renderer"
sleep 1

# A slash command can open a completion popup that swallows the first Enter, so
# one extra Enter is allowed before judging.
lab pane send-text "$PANE" "/image $IMAGE" >/dev/null || fail "could not type /image"
sleep 0.5
lab pane send-keys "$PANE" Enter >/dev/null || fail "could not submit /image"
image_lines() { pane_text | grep -Fc "[Image:"; }
wait_for_second_image() { # <tries>
  local i=0
  while [ "$i" -lt "$1" ]; do
    [ "$(image_lines)" -ge 2 ] && return 0
    sleep 0.25
    i=$((i + 1))
  done
  return 1
}
if ! wait_for_second_image 40; then
  lab pane send-keys "$PANE" Enter >/dev/null 2>&1 || true
  wait_for_second_image 80 || version_fail "/image never drew its path line: $(pane_text | tail -8)"
fi
sleep 2

# The path line may be truncated at the pane width, so match its leading part.
TEXT=$(pane_text)
assert_contains "$TEXT" "[Image: ${IMAGE:0:24}" "the path line did not name the image file"
for leak in "a=T,f=100" "iVBORw0KGgo"; do
  assert_not_contains "$TEXT" "$leak" "a graphics escape or payload leaked into the pane text ($leak)"
done
pass "real herdr $HERDR_VERSION + pi $PI_VERSION: /image shows its path line and pane reads stay free of graphics bytes"

python3 - "$TUI_LOG" <<'PY' || version_fail "Pi did not draw both images through the Kitty graphics protocol inside the Herdr pane"
import re, sys
data = open(sys.argv[1], "rb").read()
images = set()
for match in re.finditer(rb"\x1b_G([^;\x1b]*)[;\x1b]", data):
    keys = set(match.group(1).split(b","))
    if {b"a=T", b"f=100", b"C=1"} <= keys:
        images.update(key for key in keys if key.startswith(b"i="))
sys.exit(0 if len(images) >= 2 else 1)
PY
pass "real pi $PI_VERSION draws both images with Kitty transmit-and-display commands in a WezTerm-identified Herdr pane"

python3 - "$CAPTURE" <<'PY' || version_fail "Herdr did not relay the pane image to its attached client as an upload plus a placement"
import re, sys
data = open(sys.argv[1], "rb").read()
uploads, placements = set(), set()
for match in re.finditer(rb"\x1b_G([^;\x1b]*);", data):
    keys = dict(item.split(b"=", 1) for item in match.group(1).split(b",") if b"=" in item)
    action = keys.get(b"a")
    if action in (b"t", b"T") and keys.get(b"s") == b"240" and keys.get(b"v") == b"160":
        uploads.add(keys.get(b"i"))
    if action in (b"p", b"T") and b"c" in keys and b"r" in keys:
        placements.add(keys.get(b"i"))
sys.exit(0 if uploads & placements else 1)
PY
pass "real herdr $HERDR_VERSION relays the 240x160 pane image to an attached client as an upload and a placement"

lab pane send-text "$PANE" "/quit" >/dev/null 2>&1 || true
sleep 0.5
lab pane send-keys "$PANE" Enter >/dev/null 2>&1 || true
