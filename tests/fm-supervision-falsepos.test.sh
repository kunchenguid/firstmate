#!/usr/bin/env bash
# Regression tests for the three supervision false-positive classes that burned a
# firstmate turn each, several times a day, and burned tokens all night in
# away-mode (2026-07-11..13). Each case pins one class, and each class's fix is
# paired with a companion case proving the fix did NOT weaken the real detection
# it lives next to - a missed wedge is worse than a false one.
#
#   (1) A crew PARKED at a no-mistakes gate whose status log declares
#       `paused: <reason>` fell in the gap between the two absorb classes: the
#       run-step (parked) outranked the declared pause, and parked is neither
#       `working` (no positive evidence) nor `paused`, so the watcher re-surfaced
#       it as stale on EVERY poll. Verified live on nm-6951-fullflow-e2e,
#       2026-07-13: `paused: awaiting captain decision on the 3 review-gate
#       findings` + a stale wake every ~40s.
#         (1a) parked + declared pause                     -> paused (absorbed)
#         (1b) parked, NO pause declared                   -> still surfaces
#         (1c) each distinct stale hash surfaces at most ONCE (the per-poll
#              re-surface loop that turned one wake into one per poll)
#
#   (2) The catch-all fleet scan re-escalated stale status EVENTS: it read every
#       state/*.status tail with no check that the task was still on the books,
#       and the away-mode daemon's own dedupe markers are empty on a fresh start,
#       so its first scan re-raised needs-decision lines firstmate had answered
#       hours earlier (coze-obj-rename-fix-y3, 2026-07-12).
#         (2a) a torn-down task's leftover status is not scanned
#         (2b) a line the watcher already surfaced is not re-escalated
#         (2c) a captain-relevant line NOBODY surfaced is still escalated
#
#   (3) The pane busy signature stopped matching claude. Verified live on claude
#       2.1.207: a busy crew renders `✳ Meandering… (5m 46s · ↓ 18.2k tokens)`
#       and NO interrupt hint, and that line sits 7 rows from the bottom - outside
#       the 6-line footer window. So a demonstrably working crew read as idle
#       everywhere the pane is the evidence, and the away-mode wedge recheck
#       escalated "stale persisted Ns (possible wedge)" against a crew that was
#       mid-turn.
#         (3a) claude 2.1.207's live busy footer reads busy
#         (3b) a FROZEN spinner frame (a wedged harness's last paint) reads NOT
#              busy - the liveness rule, which is why widening the signature does
#              not cost wedge detection
#         (3c) parked run + busy pane -> absorbed as working; parked + idle pane
#              -> still surfaces
#         (3d) claude 2.1.220's THINKING-phase status line reads busy. The
#              signature written for 2.1.207 keyed on a parenthesised elapsed
#              counter followed by a token counter, which claude renders only
#              once it starts emitting output. Sampled every 3s across a live
#              thinking phase on 2026-07-28, that pattern matched 0 of 8
#              consecutive captures of a demonstrably busy pane, so
#              `fm_pane_is_busy` read NOT busy for the whole thinking phase of
#              every turn - and the busy-queued-Enter fallback in
#              `fm_tmux_submit_enter_core`, which rescues opencode, could not
#              rescue claude (task fm-send-busy-false-negative).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=bin/fm-tmux-lib.sh
. "$ROOT/bin/fm-tmux-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-supervision-falsepos)
mkdir -p "$TMP_ROOT"

# The real busy footer of a working claude 2.1.207 crew, captured from a live
# pane. Note: no interrupt hint anywhere, and the spinner is the 7th line from
# the bottom. <elapsed> is substituted so a "live" pane can advance its timer
# between captures while a "frozen" one cannot.
claude_busy_pane() {  # <elapsed>
  cat <<EOF
  ⎿  \$ git status --short
✳ Meandering… ($1 · ↓ 18.2k tokens)
───────────────────────────────────────────────
❯
───────────────────────────────────────────────
    Opus 4.8 (1M context)  ctx 15% (154k)  session 49% (resets 20:19)
    session-id 8c284187-4bf0-4af8-a8c0-abf7d66bd4f3
  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← for agents
EOF
}

claude_idle_pane() {
  cat <<'EOF'
  ⎿  Wrote 12 lines to notes.md
───────────────────────────────────────────────
❯
───────────────────────────────────────────────
    Opus 4.8 (1M context)  ctx 15% (154k)  session 49% (resets 20:19)
  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← for agents
EOF
}

# --- (3a/3b) the busy signature itself --------------------------------------

busy_pane=$(claude_busy_pane '5m 46s')
fm_busy_hint_in_text "$busy_pane" \
  && fail "(3a) claude 2.1.207's busy footer must NOT be matched by the interrupt-hint scan (it carries no hint) - the test fixture is wrong"
fm_spinner_in_text "$busy_pane" \
  || fail "(3a) a working claude crew's spinner line must match the spinner signature"
pass "(3a) claude 2.1.207's live busy footer is recognized (spinner signature, hint absent)"

fm_spinner_in_text "$(claude_idle_pane)" \
  && fail "(3a) an idle claude pane must not match the spinner signature"
pass "(3a) an idle claude pane does not match the spinner signature"

# The liveness rule: a spinner FRAME is not evidence; a spinner that ADVANCES is.
# This is what keeps a wedged harness (whose last painted frame still shows a
# spinner) from reading as busy forever.
fm_pane_text_advanced "$busy_pane" "$busy_pane" \
  && fail "(3b) a frozen spinner frame must not count as an advancing pane"
pass "(3b) a frozen spinner frame is not busy (wedge detection preserved)"

fm_pane_text_advanced "$busy_pane" "$(claude_busy_pane '5m 48s')" \
  || fail "(3b) a live spinner (advancing timer) must count as an advancing pane"
pass "(3b) a live spinner is busy"

# --- (3d) claude 2.1.220's thinking-phase status lines ----------------------
#
# Sampled live on 2026-07-28, one capture every 3s, from a claude 2.1.220 pane
# asked to think without tools. None of these carries an interrupt hint either,
# so the spinner signature is the only thing that can see them.
claude_2_1_220_busy_lines() {
  cat <<'EOF'
✻ Whatchamacalliting… (2s · thinking with high effort)
✢ Whatchamacalliting… (11s · still thinking with high effort)
* Whatchamacalliting… (23s · thinking more with high effort)
· Crystallizing… (running stop hooks… 4/5 · 52s · ↓ 87 tokens)
✽ Crystallizing… (running stop hooks… 4/5 · 8s · ↓ 3 tokens · thought for 1s)
· Metamorphosing… (0s · ↓ 4 tokens)
EOF
}

while IFS= read -r line; do
  [ -n "$line" ] || continue
  fm_busy_hint_in_text "$line" \
    && fail "(3d) claude 2.1.220 renders no interrupt hint - the fixture is wrong: $line"
  fm_spinner_in_text "$line" \
    || fail "(3d) a live claude 2.1.220 thinking-phase status line must read busy: $line"
done <<EOF
$(claude_2_1_220_busy_lines)
EOF
pass "(3d) every live claude 2.1.220 busy status line matches the spinner signature"

# The companion: the widened signature must not turn an idle claude footer busy,
# or the wedge detection it feeds would stop escalating a stopped crew. These are
# the exact idle rows of the same live pane, including the ones that DO carry an
# ellipsis (a truncated line ends at the `…`, so it is never followed by `(`).
while IFS= read -r line; do
  [ -n "$line" ] || continue
  fm_spinner_in_text "$line" \
    && fail "(3d) an idle claude 2.1.220 footer row must not read busy: $line"
done <<'EOF'
    Opus 5 (1M context)  ctx 4% (44k)  session 55% (resets 10:40)
    session-id 870ecb16-95f4-4851-8153-340f626ad6e8
  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← for agents
│   Opus 5 (1M context) with high… · Claude Max ·    │
✻ Crunched for 1m 12s
❯ Press up to edit queued messages
EOF
pass "(3d) an idle claude 2.1.220 footer stays not-busy (wedge detection preserved)"

# The hint signature keeps working for the harnesses that still render it.
fm_busy_hint_in_text "$(printf 'building...\n(esc to interrupt)\n')" \
  || fail "(3b) the interrupt-hint signature must still match"
pass "(3b) the interrupt-hint signature still matches (codex/opencode/pi/grok unaffected)"

# --- crew-state stub: drives the classifier without a real crew --------------
#
# crew_absorb_class shells out to FM_CREW_STATE_BIN. Stub it with the exact line
# shapes bin/fm-crew-state.sh emits, so these cases pin the CLASSIFIER contract.
# fm-crew-state.sh's own parked/pause/pane logic is pinned in fm-crew-state.test.sh.
STUB="$TMP_ROOT/fake-crew-state.sh"
cat > "$STUB" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${FM_FAKE_CREW_STATE:-}"
SH
chmod +x "$STUB"
export FM_CREW_STATE_BIN="$STUB"

# --- (1a/1b) parked at a gate, with and without a declared pause -------------

cls=$(FM_FAKE_CREW_STATE='state: paused · source: status-log · awaiting captain decision · run parked at a gate (declared pause holds)' crew_absorb_class task-a)
[ "$cls" = paused ] \
  || fail "(1a) a run parked at a gate under a DECLARED pause must classify as paused, got '$cls'"
pass "(1a) parked-at-gate + declared pause is absorbed as a declared pause, not re-surfaced as stale"

cls=$(FM_FAKE_CREW_STATE='state: parked · source: run-step · parked at review: 4 finding(s) (ask-user: captain decision) · pane idle' crew_absorb_class task-a)
[ "$cls" = none ] \
  || fail "(1b) a parked crew with an idle pane and NO declared pause must still surface, got '$cls'"
pass "(1b) parked-at-gate with no declared pause still surfaces (a crew that owes an answer is not hidden)"

# --- (3c) parked at a gate while actively working ---------------------------

cls=$(FM_FAKE_CREW_STATE='state: parked · source: run-step · parked at test: 3 finding(s) · pane busy' crew_absorb_class task-a)
[ "$cls" = working ] \
  || fail "(3c) a parked crew whose pane is BUSY is composing its gate answer, not wedged; got '$cls'"
pass "(3c) parked-at-gate + busy pane is absorbed as working (no possible-wedge escalation)"

# --- (2a/2b/2c) the catch-all fleet scan ------------------------------------

STATE="$TMP_ROOT/state"
mkdir -p "$STATE"

# live: a task still on the books, with a captain-relevant status nobody surfaced
fm_write_meta "$STATE/live-task-a1.meta" 'window=firstmate:fm-live-task-a1' 'kind=ship'
printf 'needs-decision: two review findings need a call\n' > "$STATE/live-task-a1.status"

# torn-down: teardown removed the meta; only a stale status file survives (the
# coze-obj-rename-fix-y3 shape: an hours-old needs-decision from a dead task)
printf 'needs-decision: document gate 1 ask-user finding\n' > "$STATE/gone-task-y3.status"

# surfaced: still on the books, but the always-on watcher already woke firstmate
# for this exact line
fm_write_meta "$STATE/seen-task-b2.meta" 'window=firstmate:fm-seen-task-b2' 'kind=ship'
printf 'done: PR https://example.invalid/pull/7 checks green\n' > "$STATE/seen-task-b2.status"
printf 'done: PR https://example.invalid/pull/7 checks green' > "$(hb_surfaced_path seen-task-b2 "$STATE")"

scan=$(scan_captain_relevant_statuses "$STATE")

case "$scan" in
  *gone-task-y3*) fail "(2a) a torn-down task's leftover status must not be scanned:"$'\n'"$scan" ;;
esac
pass "(2a) a torn-down task (no meta = off the books) is never re-escalated"

case "$scan" in
  *live-task-a1*) : ;;
  *) fail "(2c) a live task's unsurfaced captain-relevant status must still be scanned:"$'\n'"$scan" ;;
esac
pass "(2c) a live task's captain-relevant status is still surfaced (backstop intact)"

status_already_surfaced seen-task-b2 'done: PR https://example.invalid/pull/7 checks green' "$STATE" \
  || fail "(2b) a line the watcher already surfaced must be recognized as surfaced"
pass "(2b) a status the watcher already surfaced is recognized (the daemon adopts it instead of re-escalating)"

status_already_surfaced live-task-a1 'needs-decision: two review findings need a call' "$STATE" \
  && fail "(2b) an unsurfaced line must NOT be treated as already surfaced"
pass "(2b) an unsurfaced status is not mistaken for a surfaced one (no escalation is swallowed)"

# --- (1c) each distinct stale hash surfaces at most once ---------------------
#
# The end-to-end shape of class 1, against a real bin/fm-watch.sh subprocess.
# A crew whose pane is frozen on one hash and whose absorb class is `none` must
# wake firstmate ONCE for that hash and then never again: before the fix, a
# status line the classifier did not absorb sent every poll back through the
# surface path, so the SAME frozen hash re-woke firstmate every poll (~40s apart,
# forever - nm-6951-fullflow-e2e, 2026-07-13).
#
# The two assertions are deliberately opposite so neither can pass vacuously:
#   - the FIRST sighting must still surface (the watcher exits on a wake), which
#     proves the fix did not simply mute stale detection;
#   - a re-run over the same frozen hash must NOT surface, and the watcher's
#     absorb path is a blocking one, so "still alive after N polls" IS the
#     absorbed assertion.
CASE=$(make_case falsepos-stale-once)
W_STATE="$CASE/state"
FAKEBIN="$CASE/fakebin"
WIN=fmtest:fm-wedged-c3

fm_write_meta "$W_STATE/wedged-c3.meta" "window=$WIN" 'kind=ship' 'backend=tmux'
printf 'paused: awaiting captain decision on the review-gate findings\n' > "$W_STATE/wedged-c3.status"
# Prime the .seen-* marker so the per-poll SIGNAL scan does not fire on this
# pre-existing status: this case is about the STALE path only.
seen_sig "$W_STATE/wedged-c3.status" > "$W_STATE/.seen-wedged-c3_status"

# A frozen pane: the same bytes on every capture, so the watcher computes one
# unchanging stale hash - a crew that has genuinely stopped repainting.
CAP="$CASE/frozen-capture.txt"
printf 'frozen output\n> \n' > "$CAP"

watch_once() {  # <out> -> pid; exits on a wake, blocks while absorbing
  PATH="$FAKEBIN:$PATH" FM_STATE_OVERRIDE="$W_STATE" FM_CREW_STATE_BIN="$STUB" \
    FM_FAKE_TMUX_WINDOW="$WIN" FM_FAKE_TMUX_CAPTURE="$CAP" \
    FM_FAKE_CREW_STATE='state: parked · source: run-step · parked at review: 3 finding(s) · pane idle' \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_STALE_ESCALATE_SECS=999999 \
    bash "$ROOT/bin/fm-watch.sh" > "$1" 2>/dev/null &
}

# First sighting: the frozen pane is a crew that stopped without positive working
# evidence, so it MUST wake firstmate. The watcher exits on that wake.
OUT1="$CASE/out1"
watch_once "$OUT1"; pid=$!
wait_live "$pid" 80 && { reap "$pid"; fail "(1c) a stopped crew's frozen pane never surfaced - stale detection is broken"; }
wait "$pid" 2>/dev/null || true
assert_grep 'stale:' "$OUT1" "(1c) the first sighting of a stopped crew must surface as a stale wake"
pass "(1c) a stopped crew's stale pane still surfaces the first time (detection intact)"

# Same frozen hash, fresh watcher: the .surfaced-<key> marker records that this
# exact hash already woke firstmate, so every later poll must absorb it and the
# watcher must keep blocking instead of exiting with another stale wake.
OUT2="$CASE/out2"
watch_once "$OUT2"; pid=$!
if ! wait_live "$pid" 60; then
  reap "$pid"
  fail "(1c) the SAME stale hash woke firstmate a second time - this is the every-poll re-surface loop:"$'\n'"$(cat "$OUT2")"
fi
reap "$pid"
assert_no_grep 'stale:' "$OUT2" "(1c) an already-surfaced stale hash must not re-surface"
pass "(1c) the same stale hash never wakes firstmate twice (the ~40s re-surface loop is closed)"
