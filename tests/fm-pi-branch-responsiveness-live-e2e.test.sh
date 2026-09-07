#!/usr/bin/env bash
# Opt-in live guard for the ONE thing only a real Pi TUI can answer: whether
# the captain can still type and see the screen repaint while a supervision
# outcome is being delivered into his session.
#
# The portable regression in tests/fm-pi-branch-extension.test.sh pins the
# mechanism (the delivery path must not block the event loop) with real
# processes and no harness. This one measures the symptom the captain
# actually reported, against the installed Pi, by typing into the pane and
# timing how long each keystroke takes to be echoed - the method of
# data/<scout>/report.md section 4.1.
#
# Three arms in one run, so the verdict is calibrated to this machine rather
# than to a remembered millisecond figure:
#   floor     - Pi with the supervision extension NOT loaded
#   idle      - Pi with the extension loaded and nothing to deliver
#   delivery  - Pi with the extension loaded and two outcomes arriving
# The floor is what Pi itself costs here; the other two must stay in its
# class. Before the asynchronous conversion the loaded arms ran an order of
# magnitude worse than the floor, which is the regression this guard catches.
#
# Nothing global is touched: a scratch FM_HOME, a scratch project holding a
# copy of the tracked extension, a private tmux socket, a scratch session
# directory, --approve (trust for this run only), and --offline. Pi reads the
# operator's own agent directory because a Pi with no model renders a setup
# screen instead of a usable TUI, but nothing there is written and NO model
# turn is ever started: /new is a local command, and it re-fires session_start,
# which runs the same reconcile-and-deliver chain an arriving outcome runs.
set -u

if [ "${FM_PI_BRANCH_RESPONSIVENESS_E2E:-0}" != 1 ]; then
  echo "skip: set FM_PI_BRANCH_RESPONSIVENESS_E2E=1 to run the real-Pi delivery responsiveness guard"
  exit 0
fi

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v pi >/dev/null 2>&1 || fail "pi not installed: the real-Pi responsiveness guard cannot report a verdict without it"
command -v tmux >/dev/null 2>&1 || fail "tmux not installed: the real-Pi responsiveness guard cannot drive a pane without it"
command -v node >/dev/null 2>&1 || fail "node not installed: the real-Pi responsiveness guard cannot time keystroke echo without it"

PI_VERSION=$(pi --version 2>/dev/null || printf 'unknown')
TMUX=$(command -v tmux)
SOCKET="fm-pi-branch-responsiveness-$$"
SESSION=pi-branch-responsiveness
TMP_ROOT=$(fm_test_tmproot fm-pi-branch-responsiveness)
LAB="$TMP_ROOT/lab"
PROJECT="$LAB/project"
HOME_DIR="$LAB/fmhome"
SESSION_DIR="$LAB/sessions"
mkdir -p "$PROJECT/.pi/extensions/lib" "$HOME_DIR/state" "$HOME_DIR/config" "$SESSION_DIR"

cleanup() {
  "$TMUX" -L "$SOCKET" kill-server 2>/dev/null || true
}
trap cleanup EXIT

cp "$ROOT/.pi/extensions/fm-branch-supervision.ts" "$PROJECT/.pi/extensions/fm-branch-supervision.ts"
for lib in fm-async-exec fm-branch-dispatch fm-branch-model-picker fm-calm-visibility fm-operational-input; do
  cp "$ROOT/.pi/extensions/lib/$lib.ts" "$PROJECT/.pi/extensions/lib/$lib.ts"
done

EXT="$PROJECT/.pi/extensions/fm-branch-supervision.ts"
OUTCOME_SCRIPT="$ROOT/bin/fm-branch-outcome.sh"

# The store this guard drives is the real one; only the rows are synthetic.
append_outcome() {
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_ROOT_OVERRIDE="$ROOT" \
    bash "$OUTCOME_SCRIPT" append --task lab-task --verdict routine --summary "$1" --silent false >/dev/null \
    || fail "could not seed the outcome store"
}

# Pi is launched through this script so the session lock names the pi process
# itself, which is what makes the extension the lock owner in the lab.
cat > "$LAB/launch.sh" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$$" > "$FM_STATE_OVERRIDE/.lock"
cd "$LAB_PROJECT" || exit 1
exec "$@"
SH
chmod +x "$LAB/launch.sh"

cat > "$LAB/probe.mjs" <<'JS'
// Types markers into the pane and records, for each one, how long it took to
// be echoed. The worst of those delays is the captain's symptom: the window
// in which the TUI refuses to repaint or echo.
//
// Typing continues until the pane proves the measured event actually happened
// (`expect`) and then for a further tail, so the window cannot close before
// the work it is measuring. An expectation that never appears is a failure,
// never a fast verdict.
import { execFileSync } from "node:child_process";

const [tmux, socket, session, trigger, expect] = process.argv.slice(2);
const MARKER_TAIL = 20;
const MARKER_CAP = 140;
const capture = () => {
  try {
    return execFileSync(tmux, ["-L", socket, "capture-pane", "-p", "-t", session], { encoding: "utf8" });
  } catch {
    return "";
  }
};
const key = (name) => execFileSync(tmux, ["-L", socket, "send-keys", "-t", session, name]);
const send = (literal) => execFileSync(tmux, ["-L", socket, "send-keys", "-t", session, "-l", literal]);
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// Two characters per marker, so no marker can be spelled by two neighbours
// running together in the composer.
const markers = [];
for (const letter of "abcdefghijklmnopqrstuvwxyz") {
  for (const digit of "0123456789") markers.push(`${letter}${digit}`);
}

key("C-u");
await sleep(300);
if (expect && capture().includes(expect)) {
  console.log(`ERROR the pane already showed ${JSON.stringify(expect)} before the trigger`);
  process.exit(1);
}
send(trigger);
key("Enter");

const delays = [];
let seenExpected = false;
let tail = 0;
for (const marker of markers.slice(0, MARKER_CAP)) {
  const typedAt = process.hrtime.bigint();
  send(marker);
  let echoed = "";
  for (let poll = 0; poll < 400; poll += 1) {
    echoed = capture();
    if (echoed.includes(marker)) break;
    await sleep(8);
    echoed = "";
  }
  const delayMs = Number(process.hrtime.bigint() - typedAt) / 1e6;
  if (!echoed) {
    console.log(`ERROR marker ${marker} never echoed`);
    process.exit(1);
  }
  delays.push(delayMs);
  if (!seenExpected && (!expect || echoed.includes(expect))) seenExpected = true;
  if (seenExpected) {
    tail += 1;
    if (tail > MARKER_TAIL) break;
  }
  await sleep(30);
}
key("C-u");
if (!seenExpected) {
  console.log(`ERROR the pane never showed ${JSON.stringify(expect)}, so nothing was measured`);
  process.exit(1);
}
delays.sort((a, b) => b - a);
console.log(`SAMPLES=${delays.length}`);
console.log(`WORST_MS=${delays[0].toFixed(1)}`);
console.log(`MEDIAN_MS=${delays[Math.floor(delays.length / 2)].toFixed(1)}`);
console.log(`ALL_MS=${delays.map((delay) => delay.toFixed(0)).join(",")}`);
JS

wait_for_pane_text() {
  local expected=$1 attempts=${2:-120} i=0
  while [ "$i" -lt "$attempts" ]; do
    if "$TMUX" -L "$SOCKET" capture-pane -p -t "$SESSION" 2>/dev/null | grep -Fq "$expected"; then
      return 0
    fi
    sleep 0.25
    i=$((i + 1))
  done
  return 1
}

# One arm: launch Pi, let it settle, optionally seed outcomes that the
# trigger will deliver, then measure. Prints the probe's own key=value lines.
run_arm() {
  local label=$1 load_extension=$2 seed_rows=$3 expect=$4 out=""
  "$TMUX" -L "$SOCKET" kill-session -t "$SESSION" 2>/dev/null || true
  rm -f "$HOME_DIR/state/.lock"
  local -a pi_args
  pi_args=(pi -ns -np -nc --no-themes --offline --approve --session-dir "$SESSION_DIR")
  if [ "$load_extension" = yes ]; then
    pi_args+=(-e "$EXT")
  else
    pi_args+=(-ne)
  fi
  "$TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -x 200 -y 50 \
    "FM_HOME='$HOME_DIR' FM_STATE_OVERRIDE='$HOME_DIR/state' FM_CONFIG_OVERRIDE='$HOME_DIR/config' \
     FM_ROOT_OVERRIDE='$ROOT' LAB_PROJECT='$PROJECT' '$LAB/launch.sh' ${pi_args[*]@Q}"
  # The lab project path in Pi's own status line is the readiness signal: it
  # appears only once the TUI has drawn, unlike any prompt character.
  wait_for_pane_text "$PROJECT" 240 \
    || { "$TMUX" -L "$SOCKET" capture-pane -p -t "$SESSION" >&2; fail "Pi $PI_VERSION never drew its TUI in the $label arm"; }
  sleep 2

  if [ "$seed_rows" -gt 0 ]; then
    local i=1
    while [ "$i" -le "$seed_rows" ]; do
      append_outcome "synthetic responsiveness outcome $i"
      i=$((i + 1))
    done
  fi

  out=$(node "$LAB/probe.mjs" "$TMUX" "$SOCKET" "$SESSION" "/new" "$expect" 2>&1) \
    || { printf '%s\n' "$out" >&2; "$TMUX" -L "$SOCKET" capture-pane -p -t "$SESSION" -S -200 >&2; fail "the keystroke probe failed in the $label arm against Pi $PI_VERSION"; }
  printf '%s\n' "$out"
}

arm_value() {
  printf '%s\n' "$2" | sed -n "s/^$1=//p"
}

DELIVERED_MARK="synthetic responsiveness outcome 2"
FLOOR_OUT=$(run_arm floor no 0 "New session started")
IDLE_OUT=$(run_arm idle yes 0 "New session started")
DELIVERY_OUT=$(run_arm delivery yes 2 "$DELIVERED_MARK")

FLOOR_WORST=$(arm_value WORST_MS "$FLOOR_OUT")
IDLE_WORST=$(arm_value WORST_MS "$IDLE_OUT")
DELIVERY_WORST=$(arm_value WORST_MS "$DELIVERY_OUT")
FLOOR_SAMPLES=$(arm_value SAMPLES "$FLOOR_OUT")
DELIVERY_SAMPLES=$(arm_value SAMPLES "$DELIVERY_OUT")

[ -n "$FLOOR_WORST" ] && [ -n "$IDLE_WORST" ] && [ -n "$DELIVERY_WORST" ] \
  || fail "the responsiveness probe produced no measurement against Pi $PI_VERSION"
[ "${FLOOR_SAMPLES:-0}" -ge 20 ] && [ "${DELIVERY_SAMPLES:-0}" -ge 20 ] \
  || fail "the responsiveness probe measured too few keystrokes against Pi $PI_VERSION to mean anything"

printf 'pi %s keystroke echo, worst observed: floor %s ms, extension idle %s ms, extension delivering %s ms\n' \
  "$PI_VERSION" "$FLOOR_WORST" "$IDLE_WORST" "$DELIVERY_WORST"

# Budget is derived from this machine's own floor, so a slow host raises it
# with everything else. The margin is wide on purpose: the regression it
# guards against was an order of magnitude, not a few milliseconds.
BUDGET=$(node -e 'const f=Number(process.argv[1]); console.log(Math.max(f * 4, f + 120).toFixed(1));' "$FLOOR_WORST")
for arm in "idle:$IDLE_WORST" "delivering:$DELIVERY_WORST"; do
  label=${arm%%:*}
  worst=${arm#*:}
  node -e 'process.exit(Number(process.argv[1]) <= Number(process.argv[2]) ? 0 : 1);' "$worst" "$BUDGET" \
    || { printf '%s\n' "$IDLE_OUT" "$DELIVERY_OUT" >&2; fail "Pi $PI_VERSION froze for ${worst} ms while $label with the supervision extension loaded (budget ${BUDGET} ms from a ${FLOOR_WORST} ms unloaded floor): the delivery path is blocking the TUI again"; }
done

pass "supervision outcome delivery keeps the real Pi $PI_VERSION TUI echoing keystrokes at its unloaded floor"
