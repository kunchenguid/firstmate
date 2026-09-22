#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MUSE_BIN=$(command -v muse 2>/dev/null || true)
MUSE_VERSION=$([ -n "$MUSE_BIN" ] && "$MUSE_BIN" --version 2>/dev/null || echo "unknown")
REAL_TMUX=$(command -v tmux 2>/dev/null || true)
LAB=
SOCKET="fm-muse-signals-$$"
SESSION=muse-signals
TARGET="$SESSION:muse"

cleanup() {
  [ -n "$REAL_TMUX" ] && "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -z "$LAB" ] || rm -rf -- "$LAB"
}

fail() {
  printf 'not ok - %s [muse %s]\n' "$1" "$MUSE_VERSION" >&2
  cleanup
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

muse_prompt_glyph_is_bright() {  # <capture-path|--self-test>
  node - "$1" <<'NODE'
const fs = require("fs");

function applySgr(foreground, raw) {
  const fields = raw === "" ? ["0"] : raw.split(";");
  const params = fields.map((value) => value === "" ? 0 : Number(value));
  for (let index = 0; index < params.length; index += 1) {
    const code = params[index];
    if (code === 0 || code === 39) {
      foreground = null;
    } else if ((code >= 30 && code <= 37) || (code >= 90 && code <= 97)) {
      foreground = { kind: "unverifiable" };
    } else if (code === 48 || code === 58) {
      const mode = params[index + 1];
      const channels = params.slice(index + 2, index + 5);
      const channelFields = fields.slice(index + 2, index + 5);
      if (mode === 2 && channels.length === 3 && channelFields.every((value) => /^[0-9]+$/.test(value)) && channels.every((value) => Number.isInteger(value) && value >= 0 && value <= 255)) {
        index += 4;
      } else if (mode === 5 && /^[0-9]+$/.test(fields[index + 2] ?? "") && Number.isInteger(params[index + 2]) && params[index + 2] >= 0 && params[index + 2] <= 255) {
        index += 2;
      } else {
        break;
      }
    } else if (code === 38) {
      const mode = params[index + 1];
      const channels = params.slice(index + 2, index + 5);
      const channelFields = fields.slice(index + 2, index + 5);
      const paletteField = fields[index + 2] ?? "";
      const paletteIndex = params[index + 2];
      if (mode === 2 && channels.length === 3 && channelFields.every((value) => /^[0-9]+$/.test(value)) && channels.every((value) => Number.isInteger(value) && value >= 0 && value <= 255)) {
        foreground = { kind: "rgb", values: channels };
        index += 4;
      } else if (mode === 5 && /^[0-9]+$/.test(paletteField) && Number.isInteger(paletteIndex) && paletteIndex >= 0 && paletteIndex <= 255) {
        // Palette entries 16-255 are fixed xterm values, so their luminance
        // is verifiable; 0-15 follow the terminal theme and are not.
        foreground = paletteIndex >= 16 ? { kind: "palette", value: paletteIndex } : { kind: "unverifiable" };
        index += 2;
      } else {
        foreground = { kind: "invalid" };
      }
    }
  }
  return foreground;
}

function lastGlyphForeground(pane) {
  const tokens = /\x1b\[([0-9;]*)m|⟩|❯/gu;
  let foreground = null;
  let glyphForeground;
  for (const match of pane.matchAll(tokens)) {
    if (match[0] === "⟩" || match[0] === "❯") {
      glyphForeground = foreground;
    } else {
      foreground = applySgr(foreground, match[1]);
    }
  }
  return glyphForeground;
}

function paletteToRgb(entry) {
  if (entry >= 232) {
    const level = 8 + 10 * (entry - 232);
    return [level, level, level];
  }
  const levels = [0, 95, 135, 175, 215, 255];
  const v = entry - 16;
  return [levels[Math.floor(v / 36)], levels[Math.floor((v % 36) / 6)], levels[v % 6]];
}

function luminanceOf([r, g, b]) {
  return (r * 299 + g * 587 + b * 114) / 1000;
}

function isBrightGlyph(pane) {
  const foreground = lastGlyphForeground(pane);
  if (!foreground) return false;
  if (foreground.kind === "rgb") return luminanceOf(foreground.values) >= 128;
  if (foreground.kind === "palette") return luminanceOf(paletteToRgb(foreground.value)) >= 128;
  return false;
}

const positive = "\x1b[38;2;90;160;255m\x1b[48;2;38;56;84m⟩";
const brightThenDark = "\x1b[38;2;204;211;219mearlier bright\x1b[38;2;30;30;30m⟩";
const brightThenMalformed = "\x1b[38;2;204;211;219mearlier bright\x1b[38;2m⟩";
const brightThenOutOfRange = "\x1b[38;2;204;211;219mearlier bright\x1b[38;2;256;160;255m⟩";
const paletteBright = "\x1b[38;5;75m❯";
const paletteDark = "\x1b[38;5;232m❯";
const paletteMalformed = "\x1b[38;5m❯";
const paletteOutOfRange = "\x1b[38;5;300m❯";
const paletteThemeBase = "\x1b[34m❯";
const brightThenPaletteDark = "\x1b[38;2;204;211;219mearlier bright\x1b[38;5;232m❯";
if (!isBrightGlyph(positive) || isBrightGlyph(brightThenDark) || isBrightGlyph(brightThenMalformed) || isBrightGlyph(brightThenOutOfRange) || !isBrightGlyph(paletteBright) || isBrightGlyph(paletteDark) || isBrightGlyph(paletteMalformed) || isBrightGlyph(paletteOutOfRange) || isBrightGlyph(paletteThemeBase) || isBrightGlyph(brightThenPaletteDark)) process.exit(2);
if (process.argv[2] === "--self-test") process.exit(0);

const pane = fs.readFileSync(process.argv[2], "utf8");
const foreground = lastGlyphForeground(pane);
if (!foreground || (foreground.kind !== "rgb" && foreground.kind !== "palette")) {
  console.error("the final Muse prompt glyph has no effective verifiable foreground");
  process.exit(1);
}
const rgb = foreground.kind === "rgb" ? foreground.values : paletteToRgb(foreground.value);
const [r, g, b] = rgb;
const luminance = luminanceOf(rgb);
if (luminance < 128) {
  console.error(`the final Muse prompt glyph foreground is dark: ${r};${g};${b}, luminance ${luminance}`);
  process.exit(1);
}
NODE
}

if [ "${1:-}" = --ansi-self-test ]; then
  command -v node >/dev/null 2>&1 || fail "node is required to test Muse prompt glyph ANSI state"
  muse_prompt_glyph_is_bright --self-test || fail "Muse glyph color parser accepted a dark or malformed negative control"
  pass "Muse glyph color parser follows effective foreground state"
  exit 0
fi

# Default-on: the echo provider spends no model tokens and needs no credentials,
# so an installed Muse is exercised for real wherever it is present, while an
# absent one reports a skip naming the missing tool instead of passing silently.
fm_live_gate default-on FM_MUSE_SIGNALS_LIVE muse tmux node

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-muse-signals.XXXXXX") || fail "could not create the isolated Muse lab"
trap cleanup EXIT
mkdir -p "$LAB/bin" "$LAB/config" "$LAB/data" "$LAB/workspace"
git -C "$LAB/workspace" init -q || fail "could not initialize the isolated Muse workspace"
WORKSPACE=$(cd "$LAB/workspace" && pwd -P) || fail "could not resolve the isolated Muse workspace"

cat > "$LAB/bin/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$LAB/bin/tmux"
PATH="$LAB/bin:$PATH"
export PATH

# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=bin/fm-tmux-lib.sh
. "$ROOT/bin/fm-tmux-lib.sh"

"$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -n control -c "$WORKSPACE" \
  || fail "could not start the isolated tmux server"
"$REAL_TMUX" -L "$SOCKET" new-window -d -t "$SESSION:" -n muse -c "$WORKSPACE" -- \
  env XDG_CONFIG_HOME="$LAB/config" XDG_DATA_HOME="$LAB/data" \
  MUSE_EXPERIMENTAL_FOREIGN_PERSONAL_CONTEXT_KILL=on \
  "$MUSE_BIN" --provider echo --yolo \
  || fail "could not launch Muse with the echo provider"

SESSION_LOG=
for _ in $(seq 1 150); do
  SESSION_LOG=$(fm_busy_muse_matching_logs "$LAB/data/muse/sessions" "$WORKSPACE" 2>/dev/null | head -1)
  [ -z "$SESSION_LOG" ] || break
  sleep 0.2
done
[ -n "$SESSION_LOG" ] || fail "real Muse produced no workspace-bound session.jsonl"

RUN_STATE=$(fm_busy_muse_run_state "$SESSION_LOG" 2>/dev/null || true)
[ "$RUN_STATE" = none ] || fail "the fresh lab session already holds run records before any submit (fold '$RUN_STATE')"

# An echo turn settles about forty milliseconds after its started record
# reaches the log, so a one-shot launch is already settled before the first
# fold sample. The guard instead drives the interactive TUI the way firstmate
# drives a worker: it waits for an idle composer, submits a prompt, and folds
# back to back with no sleep, several samples per open window. A turn that
# starts and settles between two samples was missed, so the next attempt
# submits a fresh one. The typed text must be visible plus settled before
# Enter goes out: an Enter sent in the same tick as the text is evaluated
# against a still-empty composer and ignored, leaving the text sitting
# unsubmitted.
ATTEMPTS=0
RUN_STATE=
CAUGHT=
for attempt in 1 2 3; do
  ATTEMPTS=$attempt
  COMPOSER_STATE=
  for _ in $(seq 1 150); do
    COMPOSER_STATE=$(fm_tmux_composer_state "$TARGET")
    [ "$COMPOSER_STATE" = empty ] && break
    sleep 0.2
  done
  [ "$COMPOSER_STATE" = empty ] \
    || fail "Muse's TUI never reached an idle composer before submit $attempt (state '$COMPOSER_STATE')"
  PROMPT="firstmate Muse signal drift guard turn $attempt"
  tmux send-keys -t "$TARGET" -l "$PROMPT" \
    || fail "could not type submit $attempt into Muse's composer"
  TYPED=
  for _ in $(seq 1 50); do
    if tmux capture-pane -p -t "$TARGET" 2>/dev/null | grep -Fq "$PROMPT"; then
      TYPED=1
      break
    fi
    sleep 0.1
  done
  [ -n "$TYPED" ] || fail "typed submit $attempt never appeared in Muse's composer"
  sleep 1
  STARTED_BEFORE=$(fm_busy_muse_run_events "$SESSION_LOG" 2>/dev/null \
    | LC_ALL=C awk -F '\t' '$2 == "started" { count++ } END { print count + 0 }')
  MISSED=
  for _round in 1 2 3; do
    tmux send-keys -t "$TARGET" Enter \
      || fail "could not submit prompt $attempt to Muse"
    ITER=0
    for _ in $(seq 1 500); do
      RUN_STATE=$(fm_busy_muse_run_state "$SESSION_LOG" 2>/dev/null || true)
      if [ "$RUN_STATE" = busy ]; then
        CAUGHT=1
        break 3
      fi
      # A new started record without an open run means this turn settled
      # unseen. Checked sparingly so the fold samples stay dense.
      ITER=$((ITER + 1))
      if [ $((ITER % 50)) = 0 ]; then
        STARTED_NOW=$(fm_busy_muse_run_events "$SESSION_LOG" 2>/dev/null \
          | LC_ALL=C awk -F '\t' '$2 == "started" { count++ } END { print count + 0 }')
        if [ "$STARTED_NOW" -gt "$STARTED_BEFORE" ]; then
          MISSED=1
          break 2
        fi
      fi
    done
    STARTED_NOW=$(fm_busy_muse_run_events "$SESSION_LOG" 2>/dev/null \
      | LC_ALL=C awk -F '\t' '$2 == "started" { count++ } END { print count + 0 }')
    if [ "$STARTED_NOW" -gt "$STARTED_BEFORE" ]; then
      MISSED=1
      break
    fi
  done
  [ -n "$MISSED" ] || fail "submit $attempt never started a turn after repeated Enter keys"
done
[ -n "$CAUGHT" ] || fail "fm_busy_muse_run_state never observed a real echo turn in flight"
pass "Muse's real session protocol classifies busy in flight (submit $ATTEMPTS)"

for _ in $(seq 1 300); do
  RUN_STATE=$(fm_busy_muse_run_state "$SESSION_LOG" 2>/dev/null || true)
  [ "$RUN_STATE" = settled ] && break
  sleep 0.2
done
[ "$RUN_STATE" = settled ] || fail "fm_busy_muse_run_state did not settle the real echo turn"

node - "$SESSION_LOG" "$ATTEMPTS" <<'NODE' || fail "real Muse did not emit one matched run bracket per submitted turn"
const fs = require("fs");
const expected = Number(process.argv[3]);
const records = fs.readFileSync(process.argv[2], "utf8").trim().split("\n").filter(Boolean).map(JSON.parse);
const lifecycle = records.filter((record) => record?.payload_type === "runtime.session" && record?.payload?.kind === "run" && ["started", "terminal"].includes(record?.payload?.event?.kind));
if (lifecycle.length !== expected * 2) process.exit(1);
for (let index = 0; index < expected; index += 1) {
  const open = lifecycle[2 * index];
  const close = lifecycle[2 * index + 1];
  if (open.payload.event.kind !== "started" || close.payload.event.kind !== "terminal") process.exit(1);
  if (open.payload.run_id !== close.payload.run_id) process.exit(1);
}
NODE
pass "Muse's real session protocol emits one matched run bracket per submitted turn"

COMPOSER_STATE=
for _ in $(seq 1 100); do
  COMPOSER_STATE=$(fm_tmux_composer_state "$TARGET")
  [ "$COMPOSER_STATE" = empty ] && break
  sleep 0.2
done
[ "$COMPOSER_STATE" = empty ] || fail "the shared classifier read Muse's real idle composer as '$COMPOSER_STATE'"

CAPTURE="$LAB/muse-pane.ansi"
tmux capture-pane -e -p -t "$TARGET" -S 0 -E - > "$CAPTURE" \
  || fail "could not capture Muse's styled pane"
muse_prompt_glyph_is_bright "$CAPTURE" \
  || fail "Muse's real prompt glyph is missing a bright effective foreground"
pass "Muse's real bright prompt glyph classifies as an empty composer"

cleanup
trap - EXIT
