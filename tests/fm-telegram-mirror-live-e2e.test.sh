#!/usr/bin/env bash
# Real-Pi guard for the Telegram mirror's reply coverage.
#
# Pi's run collapsing is vendor behavior: submissions that arrive while a run is
# streaming join that run, so a burst can produce several visible replies inside
# one settled agent, and Pi alone decides how many replies that is. A stub cannot
# prove any of that, so this guard drives the real Pi TUI and asserts the actual
# contract from both origins - messages delivered the way the bot drains its
# queue, and messages typed in the terminal: every reply Pi renders reaches
# Telegram exactly once, and nothing else does.
#
# It costs no tokens. A local OpenAI-compatible endpoint answers with a fixed
# slow stream that numbers every reply, so no credential, vendor quota, or
# outbound network call is involved.
set -u

if [ "${FM_TELEGRAM_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_TELEGRAM_LIVE_E2E=1 to run the real-Pi Telegram mirror regression"
  exit 0
fi

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v pi >/dev/null 2>&1 || fail "pi not found for the real-Pi Telegram mirror regression"
command -v tmux >/dev/null 2>&1 || fail "tmux not found for the real-Pi Telegram mirror regression"
command -v python3 >/dev/null 2>&1 || fail "python3 not found for the real-Pi Telegram mirror regression"

FIXTURES="$ROOT/tests/fixtures/telegram-mirror"
EXT="$ROOT/.pi/extensions/fm-telegram-mirror.ts"
PI_VERSION=$(pi --version)
TMP_ROOT=$(fm_test_tmproot fm-telegram-live-e2e)
SOCKET="fm-telegram-live-$$"
SESSION=telegram-mirror-e2e
HOME_DIR="$TMP_ROOT/home"
FM_LAB_HOME="$TMP_ROOT/fmhome"
WORK="$TMP_ROOT/work"
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
MODEL_PID=
BOT_PID=
STRANGER_PID=

mkdir -p "$HOME_DIR" "$WORK" "$FM_LAB_HOME/state"

cleanup() {
  tmux -L "$SOCKET" kill-server 2>/dev/null || true
  [ -n "$MODEL_PID" ] && kill "$MODEL_PID" 2>/dev/null
  [ -n "$BOT_PID" ] && kill "$BOT_PID" 2>/dev/null
  [ -n "$STRANGER_PID" ] && kill "$STRANGER_PID" 2>/dev/null
  fm_test_cleanup
}
trap cleanup EXIT

PAYLOADS="$TMP_ROOT/payloads.jsonl"
export FM_FAKE_MODEL_PAYLOADS="$PAYLOADS"
python3 "$FIXTURES/fake-model.py" "$PORT" 0.6 >"$TMP_ROOT/model.log" 2>&1 &
MODEL_PID=$!
FM_TELEGRAM_DIR="$HOME_DIR" python3 "$FIXTURES/fake-bot.py" >"$TMP_ROOT/bot.log" 2>&1 &
BOT_PID=$!

wait_for_socket() {
  local i=0
  while [ "$i" -lt 100 ]; do
    [ -e "$HOME_DIR/bot.sock" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  fail "the fixture bot never opened its socket"
}
wait_for_socket

frames_of() {  # <kind>
  local count=0
  count=$(grep -c "\"t\":\"$1\"" "$HOME_DIR/frames.log" 2>/dev/null) || count=0
  printf '%s\n' "$count"
}

capture_pane() {
  tmux -L "$SOCKET" capture-pane -p -t "$SESSION" -S -400 2>/dev/null || true
}

# Every reply the fake model streams carries a unique MIRROR_LIVE_REPLY <n>
# marker, so the pane and the mirrored frames can be compared as sets.
reply_ids() {  # <source-file> pane|frames
  python3 - "$1" "$2" <<'PY'
import json
import re
import sys

path, kind = sys.argv[1], sys.argv[2]
text = open(path, encoding="utf-8", errors="replace").read()
if kind == "frames":
    bodies = []
    for line in text.splitlines():
        _, _, payload = line.partition("FRAME ")
        if not payload:
            continue
        frame = json.loads(payload)
        if frame.get("t") == "reply":
            bodies.append(frame["text"])
else:
    bodies = text.splitlines()
ids = [match for body in bodies for match in re.findall(r"MIRROR_LIVE_REPLY (\d+)", body)]
print(" ".join(ids))
PY
}

settle() {  # wait until Pi stops producing replies
  local previous=-1 current stable=0 i=0
  while [ "$i" -lt 200 ]; do
    current=$(frames_of reply)
    if [ "$current" = "$previous" ] && ! capture_pane | grep -q 'Working\.\.\.'; then
      stable=$((stable + 1))
      [ "$stable" -ge 4 ] && return 0
    else
      stable=0
    fi
    previous=$current
    sleep 0.5
    i=$((i + 1))
  done
  return 0
}

start_pi() {
  : >"$HOME_DIR/frames.log"
  rm -f "$HOME_DIR/inject.txt"
  tmux -L "$SOCKET" kill-server 2>/dev/null || true
  # The bridge mirrors only for the session that holds the Firstmate home's
  # lock, so this fixture launches Pi as that session: the shell records its own
  # pid as the lock holder and then execs Pi into it.
  mkdir -p "$FM_LAB_HOME/state"
  tmux -L "$SOCKET" new-session -d -s "$SESSION" -x 200 -y 50 -c "$WORK" \
    "printf '%s\n' \$\$ >'$FM_LAB_HOME/state/.lock'; \
     FM_HOME='$ROOT' FM_STATE_OVERRIDE='$FM_LAB_HOME/state' \
     FM_TELEGRAM_DIR='$HOME_DIR' FAKE_MODEL_PORT='$PORT' \
     exec pi --no-session --no-context-files --no-extensions --no-skills --no-tools \
     -e '$FIXTURES/fake-provider.ts' -e '$EXT' --model fakelab/slow-fake"
  local i=0
  while [ "$i" -lt 150 ]; do
    [ "$(frames_of hello)" -ge 1 ] && return 0
    sleep 0.2
    i=$((i + 1))
  done
  fail "the Telegram bridge never connected inside a real Pi session (Pi $PI_VERSION)"
}

# Sets VISIBLE_REPLIES for the caller. Deliberately not a command substitution:
# fail() inside one would exit only that subshell, and this guard would report a
# pass after printing its own failure.
VISIBLE_REPLIES=0
assert_every_visible_reply_mirrored() {  # <label>
  local label=$1 pane_file visible mirrored
  settle
  pane_file="$TMP_ROOT/pane.$$"
  capture_pane >"$pane_file"
  visible=$(reply_ids "$pane_file" pane)
  mirrored=$(reply_ids "$HOME_DIR/frames.log" frames)
  VISIBLE_REPLIES=$(printf '%s\n' "$visible" | wc -w)
  # A burst that never collapsed into a multi-reply run would pass vacuously,
  # because the lost replies only exist when one run answers more than once.
  [ "$VISIBLE_REPLIES" -ge 2 ] \
    || fail "$label: Pi rendered $VISIBLE_REPLIES reply/replies, so the burst never exercised a queued run (Pi $PI_VERSION)"
  [ "$visible" = "$mirrored" ] \
    || fail "$label: Pi rendered replies [$visible] but Telegram received [$mirrored] (Pi $PI_VERSION)"
}

# A: five messages delivered exactly as the bot drains its in-memory queue.
start_pi
printf 'Telegram 1\nTelegram 2\nTelegram 3\nTelegram 4\nTelegram 5\n' >"$HOME_DIR/inject.txt"
assert_every_visible_reply_mirrored "Telegram-origin burst"
telegram_replies=$VISIBLE_REPLIES
[ "$(frames_of accepted)" -eq 5 ] || fail "Telegram-origin burst: Pi did not accept all five messages"
[ "$(frames_of terminal)" -eq 0 ] || fail "Telegram-origin burst: Telegram text was echoed back as terminal input"
pass "five Telegram-origin messages delivered back-to-back mirror every one of the $telegram_replies replies Pi rendered, exactly once (Pi $PI_VERSION)"

# B: the same five typed straight into the terminal.
start_pi
for i in 1 2 3 4 5; do
  tmux -L "$SOCKET" send-keys -t "$SESSION" -l "Terminal $i"
  tmux -L "$SOCKET" send-keys -t "$SESSION" Enter
  sleep 0.4
done
assert_every_visible_reply_mirrored "terminal-origin burst"
terminal_replies=$VISIBLE_REPLIES
[ "$(frames_of terminal)" -eq 5 ] || fail "terminal-origin burst: not every submission was mirrored"
pass "five terminal submissions typed back-to-back mirror every one of the $terminal_replies replies Pi rendered, exactly once (Pi $PI_VERSION)"

# C: a screenshot must reach the model as a real image, with its caption in the
# same message. The live failure delivered a caption-only turn and, without a
# caption, an empty one, with no image anywhere in the session.
wait_for_image_payload() {  # <expected caption>
  local caption=$1 i=0
  while [ "$i" -lt 200 ]; do
    if python3 - "$PAYLOADS" "$caption" <<'PY'
import json, sys
try:
    lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
except OSError:
    raise SystemExit(1)
wanted = sys.argv[2]
for line in lines:
    for message in json.loads(line).get("messages", []):
        content = message.get("content")
        if message.get("role") != "user" or not isinstance(content, list):
            continue
        images = [part for part in content if part.get("type") == "image_url"]
        texts = [part.get("text", "") for part in content if part.get("type") == "text"]
        if not images:
            continue
        url = str(images[0].get("image_url", {}).get("url", ""))
        if not url.startswith("data:image/png;base64,") or len(url) < 60:
            raise SystemExit(1)
        joined = " ".join(texts)
        # The terminal renders no preview, so the message must say an image is
        # there, and must not say where it came from.
        if "[Image attached]" not in joined or "elegram" in joined:
            raise SystemExit(1)
        if wanted and wanted not in joined:
            continue
        raise SystemExit(0)
raise SystemExit(1)
PY
    then
      return 0
    fi
    sleep 0.2
    i=$((i + 1))
  done
  return 1
}

start_pi
: >"$PAYLOADS"
printf 'Okay what is this image\n' >"$HOME_DIR/inject-image.txt"
wait_for_image_payload "Okay what is this image" \
  || fail "a captioned screenshot never reached the model as an image (Pi $PI_VERSION)"
pass "a captioned Telegram screenshot reaches the model as one message carrying the caption, the [Image attached] marker, and the image (Pi $PI_VERSION)"

: >"$PAYLOADS"
printf ' \n' >"$HOME_DIR/inject-image.txt"
wait_for_image_payload "" \
  || fail "a screenshot without a caption never reached the model as image content (Pi $PI_VERSION)"
pass "a Telegram screenshot without a caption reaches the model as the [Image attached] marker plus the image (Pi $PI_VERSION)"

# D: the production start order. Firstmate records its session lock from inside
# the session Pi has already started, so the bridge is loaded before the home
# names it. The fixture above writes the lock first and would never see that
# window; here Pi starts against an unrecorded home, exactly as a real Firstmate
# session does, and the mirror has to come up on its own once the lock lands -
# including across a leftover record whose pid an unrelated live process has
# since inherited, which is indistinguishable from a live session to anything
# coarser than Firstmate's own harness classification.
# The rendered footer is asserted from the real TUI because how Pi orders,
# joins, and separates independently published statuses is Pi's own behavior.
start_pi_unrecorded() {
  : >"$HOME_DIR/frames.log"
  rm -f "$HOME_DIR/inject.txt" "$FM_LAB_HOME/state/.lock"
  tmux -L "$SOCKET" kill-server 2>/dev/null || true
  mkdir -p "$FM_LAB_HOME/state"
  tmux -L "$SOCKET" new-session -d -s "$SESSION" -x 200 -y 50 -c "$WORK" \
    "FM_HOME='$ROOT' FM_STATE_OVERRIDE='$FM_LAB_HOME/state' \
     FM_TELEGRAM_DIR='$HOME_DIR' FAKE_MODEL_PORT='$PORT' \
     exec pi --no-session --no-context-files --no-extensions --no-skills --no-tools \
     -e '$FIXTURES/fake-provider.ts' -e '$FIXTURES/status-peer.ts' -e '$EXT' --model fakelab/slow-fake"
  local i=0
  while [ "$i" -lt 100 ]; do
    capture_pane | grep -q 'voice: alt+m' && return 0
    sleep 0.2
    i=$((i + 1))
  done
  fail "the real Pi session never rendered its footer (Pi $PI_VERSION)"
}

start_pi_unrecorded
sleep 2
[ "$(frames_of hello)" -eq 0 ] \
  || fail "the bridge connected before the home recorded its live session (Pi $PI_VERSION)"
capture_pane | grep -q 'telegram:' \
  && fail "the mirror published a footer status before the home recorded its live session (Pi $PI_VERSION)"

# A leftover record naming a pid an unrelated live process has since inherited
# is not a live Firstmate session. Firstmate's own session start overwrites it,
# so the bridge must keep waiting for the real record rather than concluding the
# home belongs to someone else and staying dark until a reload.
sleep 600 &
STRANGER_PID=$!
printf '%s\n' "$STRANGER_PID" >"$FM_LAB_HOME/state/.lock"
sleep 2
capture_pane | grep -q 'telegram:' \
  && fail "an unrelated live process on a recycled pid was treated as this home's session (Pi $PI_VERSION)"
[ "$(frames_of hello)" -eq 0 ] \
  || fail "the bridge connected on behalf of an unrelated live process (Pi $PI_VERSION)"

# The lock names the pane's own process, which is Pi itself: the fixture execs
# Pi into the pane, so this is the same shape fm-session-start.sh records.
tmux -L "$SOCKET" display-message -p -t "$SESSION" '#{pane_pid}' >"$TMP_ROOT/pane-pid"
cat "$TMP_ROOT/pane-pid" >"$FM_LAB_HOME/state/.lock"

wait_for_status_line() {
  local i=0
  while [ "$i" -lt 150 ]; do
    capture_pane | grep -q 'telegram:' && return 0
    sleep 0.2
    i=$((i + 1))
  done
  fail "the mirror never appeared after the home recorded its live session, so only a Pi reload would have revived it (Pi $PI_VERSION)"
}
wait_for_status_line
[ "$(frames_of hello)" -ge 1 ] \
  || fail "the mirror published a footer status without connecting to the bot (Pi $PI_VERSION)"

STATUS_LINE=$(capture_pane | grep 'telegram:' | tail -1 | sed 's/[[:space:]]*$//')
# Telegram first, then the separator the other statuses use between their own
# fields, then the status Pi renders next, all on the one status line.
case $STATUS_LINE in
  "telegram: "*" • voice: alt+m • parakeet-v3-q8") ;;
  *) fail "Telegram and the next status were not rendered as one separated footer line: [$STATUS_LINE] (Pi $PI_VERSION)" ;;
esac
[ "$(capture_pane | grep -c 'telegram:')" -eq 1 ] \
  || fail "the Telegram status was rendered more than once: (Pi $PI_VERSION)"
pass "a real Pi session started before its home recorded the session, and left holding a record an unrelated live process had inherited, brings the mirror up without a reload and renders it ahead of the next status on one separated footer line (Pi $PI_VERSION)"
