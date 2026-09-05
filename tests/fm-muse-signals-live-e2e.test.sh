#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/git-config-helpers.sh
. "$ROOT/tests/git-config-helpers.sh"
MUSE_BIN=$(command -v muse 2>/dev/null || true)
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
  printf 'not ok - %s\n' "$1" >&2
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
      foreground = { kind: "indexed" };
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
      if (mode === 2 && channels.length === 3 && channelFields.every((value) => /^[0-9]+$/.test(value)) && channels.every((value) => Number.isInteger(value) && value >= 0 && value <= 255)) {
        foreground = { kind: "rgb", values: channels };
        index += 4;
      } else if (mode === 5 && /^[0-9]+$/.test(fields[index + 2] ?? "") && Number.isInteger(params[index + 2]) && params[index + 2] >= 0 && params[index + 2] <= 255) {
        foreground = { kind: "indexed" };
        index += 2;
      } else {
        foreground = { kind: "invalid" };
      }
    }
  }
  return foreground;
}

function lastGlyphForeground(pane) {
  const tokens = /\x1b\[([0-9;]*)m|⟩/gu;
  let foreground = null;
  let glyphForeground;
  for (const match of pane.matchAll(tokens)) {
    if (match[0] === "⟩") {
      glyphForeground = foreground;
    } else {
      foreground = applySgr(foreground, match[1]);
    }
  }
  return glyphForeground;
}

function isBrightTruecolor(pane) {
  const foreground = lastGlyphForeground(pane);
  if (!foreground || foreground.kind !== "rgb") return false;
  const [r, g, b] = foreground.values;
  return (r * 299 + g * 587 + b * 114) / 1000 >= 128;
}

const positive = "\x1b[38;2;90;160;255m\x1b[48;2;38;56;84m⟩";
const brightThenDark = "\x1b[38;2;204;211;219mearlier bright\x1b[38;2;30;30;30m⟩";
const brightThenMalformed = "\x1b[38;2;204;211;219mearlier bright\x1b[38;2m⟩";
const brightThenOutOfRange = "\x1b[38;2;204;211;219mearlier bright\x1b[38;2;256;160;255m⟩";
if (!isBrightTruecolor(positive) || isBrightTruecolor(brightThenDark) || isBrightTruecolor(brightThenMalformed) || isBrightTruecolor(brightThenOutOfRange)) process.exit(2);
if (process.argv[2] === "--self-test") process.exit(0);

const pane = fs.readFileSync(process.argv[2], "utf8");
const foreground = lastGlyphForeground(pane);
if (!foreground || foreground.kind !== "rgb") {
  console.error("the final Muse prompt glyph has no effective truecolor foreground");
  process.exit(1);
}
const [r, g, b] = foreground.values;
const luminance = (r * 299 + g * 587 + b * 114) / 1000;
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

if [ "${FM_MUSE_SIGNALS_LIVE:-0}" != 1 ]; then
  echo "skip: set FM_MUSE_SIGNALS_LIVE=1 to run the real Muse signal drift guard"
  exit 0
fi

[ -x "$MUSE_BIN" ] || fail "FM_MUSE_SIGNALS_LIVE=1 but no real muse executable is installed on PATH"
[ -x "$REAL_TMUX" ] || fail "FM_MUSE_SIGNALS_LIVE=1 but tmux is not installed"
command -v node >/dev/null 2>&1 || fail "node is required to inspect Muse's serialized session protocol"

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
  "$MUSE_BIN" --provider echo --yolo "firstmate Muse signal drift guard" \
  || fail "could not launch Muse with the echo provider"

SESSION_LOG=
for _ in $(seq 1 150); do
  SESSION_LOG=$(fm_busy_muse_matching_logs "$LAB/data/muse/sessions" "$WORKSPACE" 2>/dev/null | head -1)
  [ -z "$SESSION_LOG" ] || break
  sleep 0.2
done
[ -n "$SESSION_LOG" ] || fail "real Muse produced no workspace-bound session.jsonl"

RUN_STATE=
for _ in $(seq 1 150); do
  RUN_STATE=$(fm_busy_muse_run_state "$SESSION_LOG" 2>/dev/null || true)
  [ "$RUN_STATE" = busy ] && break
  sleep 0.2
done
[ "$RUN_STATE" = busy ] || fail "fm_busy_muse_run_state never observed the real echo turn in flight"
pass "Muse's real session protocol classifies busy in flight"

for _ in $(seq 1 300); do
  RUN_STATE=$(fm_busy_muse_run_state "$SESSION_LOG" 2>/dev/null || true)
  [ "$RUN_STATE" = settled ] && break
  sleep 0.2
done
[ "$RUN_STATE" = settled ] || fail "fm_busy_muse_run_state did not settle the real echo turn"

node - "$SESSION_LOG" <<'NODE' || fail "real Muse did not emit exactly one matched started and terminal run pair"
const fs = require("fs");
const records = fs.readFileSync(process.argv[2], "utf8").trim().split("\n").filter(Boolean).map(JSON.parse);
const lifecycle = records.filter((record) => record?.payload_type === "runtime.session" && record?.payload?.kind === "run" && ["started", "terminal"].includes(record?.payload?.event?.kind));
const started = lifecycle.filter((record) => record.payload.event.kind === "started");
const terminal = lifecycle.filter((record) => record.payload.event.kind === "terminal");
if (started.length !== 1 || terminal.length !== 1 || started[0].payload.run_id !== terminal[0].payload.run_id) process.exit(1);
NODE
pass "Muse's real session protocol emits one matched run bracket"

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
  || fail "Muse's real prompt glyph is missing a bright effective truecolor foreground"
pass "Muse's real bright prompt glyph classifies as an empty composer"

cleanup
trap - EXIT
