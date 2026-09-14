#!/usr/bin/env bash
# tests/fm-agy-spend-gate-live-e2e.test.sh - the LIVE guard for the agy
# point-of-spend gate's mechanism: what only the real harness can prove.
#
# tests/fm-agy-spend-gate.test.sh pins the verdict logic against fixtures with
# no harness, so CI enforces it everywhere. It cannot notice the things that
# would silently break the mechanism in production: agy not firing
# PostInvocation, not honouring terminate, or breaking a healthy turn when the
# hook answers. This guard proves those three against the agy actually
# installed, in a disposable Herdr lab session, on the cheapest rung only.
#
# It is opt-in and on demand because it spends real quota on a real account and
# standard CI has neither the binary nor the credentials. Run it after every
# agy upgrade, and refresh docs/verification/agy-spend-gate.md from what it
# prints. Never point it at Opus: the reserve this gate protects must never be
# spent by its own guard.
#
# What it proves, end to end:
#   1. PostInvocation fires after a tool batch, with a payload carrying the
#      workspace the hook can resolve.
#   2. Answering {} lets a tool-using turn finish untouched (the gate must
#      never break correct output).
#   3. Answering terminate stops the loop after the in-flight batch, and Stop
#      fires afterwards (the gate can end the spend it exists to end).
#
# A missing agy, herdr, or jq is reported and skipped, never passed over
# silently: a guard that checked nothing must not look like a guard that passed.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
# The shared live gate, not a private env check: the fm-live-gate family sweep
# runs every live guard with FM_LIVE=0 and requires the shared refusal line.
fm_live_gate opt-in FM_AGY_SPEND_GATE_LIVE_E2E agy herdr jq
# shellcheck source=bin/fm-agy-descent-lib.sh
. "$ROOT/bin/fm-agy-descent-lib.sh"

AGY_VERSION=$(agy --version 2>/dev/null | head -1)
[ -n "$AGY_VERSION" ] || fail "agy did not report a version; refusing to record evidence against an unknown build"
echo "# agy $AGY_VERSION"

# Deliberately the cheapest rung: this guard must never spend the reserve it
# exists to protect.
MODEL_KEBAB=gemini-3.7-flash-high
MODEL_DISPLAY='Gemini 3.7 Flash (High)'

TMP=$(fm_test_tmproot fm-agy-spend-gate-live)
WORK="$TMP/work"
LOG="$TMP/firings.log"
MODE="$TMP/mode"
mkdir -p "$WORK/.agents"
printf 'passthrough' > "$MODE"

# The probe hook: logs every firing, then answers from the mode file. A canned
# verdict rather than the real gate, because what is under test here is agy's
# half of the contract - that the event fires and the verdict is honoured -
# while the verdict's own logic is pinned without a harness.
cat > "$TMP/hook.sh" <<SH
#!/usr/bin/env bash
set -u
event=\${1:-}
emit() { printf '{}\n'; exit 0; }
payload=\$(cat 2>/dev/null) || emit
ws=\$(printf '%s' "\$payload" | LC_ALL=C sed -n 's/.*"workspacePaths":\[[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
case "\$ws" in */fm-agy-spend-gate-live.*/work) : ;; *) emit ;; esac
printf '%s %s %s\n' "\$(date +%s)" "\$event" "\$payload" >> "$LOG"
mode=\$(cat "$MODE" 2>/dev/null || true)
if [ "\$event" = PostInvocation ] && [ "\$mode" = terminate ]; then
  printf '{"terminationBehavior":"terminate","injectSteps":[{"ephemeralMessage":"LIVE GUARD: floor reached, ending turn."}]}\n'
  exit 0
fi
emit
SH
chmod +x "$TMP/hook.sh"
cat > "$WORK/.agents/hooks.json" <<EOF
{"fm-spend-gate-guard":{"PreInvocation":[{"type":"command","command":"bash $TMP/hook.sh PreInvocation","timeout":10}],"PostInvocation":[{"type":"command","command":"bash $TMP/hook.sh PostInvocation","timeout":10}],"Stop":[{"type":"command","command":"bash $TMP/hook.sh Stop","timeout":10}]}}
EOF

HELPER="$ROOT/bin/fm-herdr-lab.sh"
[ -x "$HELPER" ] || fail "the Herdr lab helper is missing; this guard must never touch the live default session"
SESSION=$(FM_HERDR_LAB_LABEL=agy-spend-gate "$HELPER" name agy-spend-gate)

cleanup() { "$HELPER" teardown "$SESSION" >/dev/null 2>&1 || true; }
trap cleanup EXIT

L() { "$HELPER" run "$SESSION" "$@"; }
CAP() { L pane read "$PANE" --source recent --lines 200 2>/dev/null | tail -n 60; }

"$HELPER" provision "$SESSION" >/dev/null || fail "could not provision the isolated Herdr lab session"
WS=$(L workspace create --cwd "$WORK" --label agyspendgate --no-focus 2>&1) \
  || fail "could not create the lab workspace: $WS"
PANE=$(printf '%s' "$WS" | jq -r '.result.root_pane.pane_id')
[ -n "$PANE" ] && [ "$PANE" != null ] || fail "the lab workspace reported no pane to drive"

L pane run "$PANE" agy --model "$MODEL_KEBAB" --dangerously-skip-permissions >/dev/null
for _ in $(seq 1 30); do
  sleep 3
  case "$(CAP)" in *'trust the contents'*|*'quota:'*) break ;; esac
done
case "$(CAP)" in
  *'trust the contents'*) L pane send-keys "$PANE" Enter >/dev/null; sleep 6 ;;
esac

BEFORE=$(CAP)
[ "$(fm_agy_footer_model "$BEFORE")" = "$MODEL_DISPLAY" ] \
  || fail "the worker did not come up on $MODEL_DISPLAY; got '$(fm_agy_footer_model "$BEFORE")'"
pass "a live agy worker is running on $MODEL_DISPLAY"

# --- direction one: {} lets a tool-using turn finish untouched ----------------

L pane send-text "$PANE" "List the files in this directory and report the count. Reply with only COUNT=<n>." >/dev/null
sleep 1
L pane send-keys "$PANE" Enter >/dev/null
# The prompt echo itself contains COUNT=, so only the worker's own indented
# reply line counts as completion.
for _ in $(seq 1 40); do
  sleep 3
  printf '%s\n' "$(CAP)" | grep -q '^  COUNT=' && break
done
printf '%s\n' "$(CAP)" | grep -q '^  COUNT=' || {
  fail "the worker never finished a tool-using turn with the hook answering {}, so passthrough is unproven. Pane was:"$'\n'"$(CAP)"
}
[ -f "$LOG" ] || fail "the hook never logged a firing, so nothing below would mean anything"
grep -q ' PostInvocation ' "$LOG" \
  || fail "PostInvocation never fired during a tool-using turn on agy $AGY_VERSION"
# The answer renders before the loop terminates, so Stop lands a beat after
# the reply. Wait for it boundedly rather than asserting on arrival order.
for _ in $(seq 1 10); do
  grep -q ' Stop ' "$LOG" && break
  sleep 3
done
grep -q ' Stop ' "$LOG" \
  || fail "Stop never fired after a tool-using turn on agy $AGY_VERSION"
pass "PostInvocation and Stop fire around a tool-using turn the hook passes"

# --- direction two: terminate ends the spend -----------------------------------

: > "$LOG"
printf 'terminate' > "$MODE"
L pane send-text "$PANE" "Do these three things in order: 1) list files here, 2) list files in .agents, 3) print the date. Then reply DONE." >/dev/null
sleep 1
L pane send-keys "$PANE" Enter >/dev/null
sleep 60
# The prompt echo itself contains DONE, so only the worker's own indented
# reply line - or a second tool batch past the first - counts as the loop
# surviving the verdict.
AFTER=$(printf '%s\n' "$(CAP)" | sed -n '/Do these three things/,$p')
printf '%s\n' "$AFTER" | grep -q '^  DONE$' && {
  fail "the worker replied DONE after a terminate verdict, so terminate did not stop the loop on agy $AGY_VERSION. Pane was:"$'\n'"$(CAP)"
}
[ "$(printf '%s\n' "$AFTER" | grep -c '● ' || true)" -le 1 ] || {
  fail "the worker ran further tool batches after a terminate verdict on agy $AGY_VERSION. Pane was:"$'\n'"$(CAP)"
}
grep -q ' PostInvocation ' "$LOG" \
  || fail "no PostInvocation firing was logged, so the terminate verdict was never delivered"
grep -q ' Stop ' "$LOG" \
  || fail "Stop never fired after the terminate verdict, so the worker did not end its turn on agy $AGY_VERSION"
FIRINGS=$(grep -c ' PreInvocation ' "$LOG" || true)
[ "$FIRINGS" -le 4 ] \
  || fail "the loop kept starting new invocations after terminate ($FIRINGS PreInvocation firings)"
pass "terminate stops a live loop after the in-flight batch and Stop fires"

echo "# evidence captured against agy $AGY_VERSION"
