#!/usr/bin/env bash
# tests/fm-notify.test.sh - behavior tests for the captain's producer-tag
# notifications (bin/fm-notify.sh) and their single status-surfacing owner
# (mark_surfaced in bin/fm-push-transition-lib.sh).
#
# Every channel is intercepted through the FM_NOTIFY_EXEC seam, so no assertion
# here can post a real desktop notification or require a GUI. The fail-open
# cases run with the seam removed and every channel binary hidden from PATH,
# which is exactly the state a Linux CI runner is already in.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NOTIFY="$ROOT/bin/fm-notify.sh"
TMPROOT=$(fm_test_tmproot fm-notify)
mkdir -p "$TMPROOT"
trap 'fm_test_cleanup; rm -rf "$TMPROOT"' EXIT
RECORDER="$TMPROOT/recorder"
LOG="$TMPROOT/notifications.log"

cat > "$RECORDER" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$LOG"
SH
chmod +x "$RECORDER"

# A genuine primary home: a plain checkout (not a linked worktree), carrying
# AGENTS.md, bin/, and its own state/. That is what the notifier's scope guard
# requires, and building a real one keeps the guard itself under test.
make_home() {  # <dir>
  local home=$1
  mkdir -p "$home/state" "$home/bin" "$home/config"
  : > "$home/AGENTS.md"
  git -C "$home" init -q
  printf '%s\n' "$home"
}

PRIMARY=$(make_home "$TMPROOT/primary")

reset_log() {
  : > "$LOG"
}

# Run the notifier against the primary home with the recorder seam installed and
# the channel pinned. Pinning matters: `auto` resolves against the machine's own
# osascript/herdr binaries, so every assertion about a class, sound, config key,
# or dedup would otherwise only hold on macOS and go silently vacuous on a Linux
# CI runner. Channel resolution itself is asserted separately, below.
notify() {  # <arg>...
  FM_NOTIFY_CHANNEL=macos notify_unpinned "$@"
}

# The same run with no channel pin, for the assertions that are about channel
# resolution itself.
notify_unpinned() {  # <arg>...
  FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$PRIMARY/state" FM_NOTIFY_EXEC="$RECORDER" \
    "$NOTIFY" "$@"
}

logged() {
  cat "$LOG" 2>/dev/null || true
}

# --- event class -> channel and sound mapping -------------------------------

reset_log
notify pr-merged "firstmate: PR merged" "alpha landed"
notify pr-ready "firstmate: PR ready for review" "alpha open"
notify attention "firstmate: decision needed" "alpha asks"
OUT=$(logged)
assert_contains "$OUT" "macos Glass firstmate: PR merged alpha landed" "pr-merged must map to the Glass tag"
assert_contains "$OUT" "macos Ping firstmate: PR ready for review alpha open" "pr-ready must map to the Ping tag"
assert_contains "$OUT" "macos Sosumi firstmate: decision needed alpha asks" "attention must map to the Sosumi tag"
pass "each event class carries its own distinct default sound"

# The three sounds must actually differ, or the producer tags carry no signal.
SOUNDS=$(logged | awk '{print $2}' | sort -u | wc -l | tr -d '[:space:]')
[ "$SOUNDS" = 3 ] || fail "the three classes must use three distinct sounds, got $SOUNDS"
pass "the three event classes are audibly distinct from one another"

reset_log
notify not-an-event "title" "body"
[ -z "$(logged)" ] || fail "an unknown event class must post nothing"
pass "an unknown event class posts nothing"

# --- status events map onto exactly one class -------------------------------

reset_log
notify --from-status alpha "done: PR https://github.com/o/r/pull/12 checks green"
assert_contains "$(logged)" "macos Ping firstmate: PR ready for review alpha: PR https://github.com/o/r/pull/12 checks green" \
  "a done: line naming a PR must raise the review-ready tag"
pass "a done: status naming a pull request raises the PR-ready tag"

reset_log
notify --from-status alpha "done: PR https://gitlab.com/o/r/-/merge_requests/4"
assert_contains "$(logged)" "macos Ping" "a GitLab merge request URL must also raise the review-ready tag"
pass "a merge request URL raises the same PR-ready tag as a pull request URL"

reset_log
notify --from-status alpha "done: report written to data/alpha/report.md"
assert_contains "$(logged)" "macos Sosumi firstmate: task finished alpha: report written to data/alpha/report.md" \
  "a done: line with no PR must raise the attention tag"
notify --from-status alpha "failed: the build never recovered"
notify --from-status alpha "needs-decision [key=api]: two shapes are viable"
notify --from-status alpha "blocked: no credential for the forge"
OUT=$(logged)
assert_contains "$OUT" "firstmate: task failed alpha: the build never recovered" "failed: must raise the attention tag"
assert_contains "$OUT" "firstmate: decision needed alpha: two shapes are viable" "needs-decision: must raise the attention tag"
assert_contains "$OUT" "firstmate: blocked alpha: no credential for the forge" "blocked: must raise the attention tag"
[ "$(logged | awk '{print $2}' | sort -u)" = Sosumi ] || fail "every terminal/needs-input verb must share one sound"
pass "done, failed, needs-decision, and blocked all raise the single attention tag"

reset_log
notify --from-status alpha "working: rebased onto merged #76"
notify --from-status alpha "paused: waiting on the upstream release"
notify --from-status alpha "resolved [key=api]: captain chose the second shape"
[ -z "$(logged)" ] || fail "routine status events must stay silent: $(logged)"
pass "routine progress, pause, and resolution events stay silent"

# --- config overrides -------------------------------------------------------

CONFIG="$PRIMARY/config/notify"

reset_log
cat > "$CONFIG" <<'EOF'
# the captain's own tuning
attention = Hero
pr-merged=Submarine
EOF
notify attention "t" "b"
notify pr-merged "t" "b"
notify pr-ready "t" "b"
OUT=$(logged)
assert_contains "$OUT" "macos Hero t b" "attention must take the configured Hero sound"
assert_contains "$OUT" "macos Submarine t b" "pr-merged must take the configured Submarine sound"
assert_contains "$OUT" "macos Ping t b" "an unconfigured class must keep its default sound"
pass "config/notify overrides per-class sounds and leaves unconfigured classes alone"

reset_log
printf 'attention=Hero\nattention=Funk\n' > "$CONFIG"
notify attention "t" "b"
assert_contains "$(logged)" "macos Funk t b" "the last assignment for a key must win"
pass "a repeated config key resolves to its last assignment"

reset_log
printf 'attention=Hero,herdr\n' > "$CONFIG"
notify_unpinned attention "t" "b"
assert_contains "$(logged)" "herdr request t b" "a per-class channel must route to herdr with the herdr sound"
pass "a per-class channel override routes that class to its own channel"

reset_log
printf 'channel=both\n' > "$CONFIG"
notify_unpinned pr-merged "t" "b"
OUT=$(logged)
assert_contains "$OUT" "macos Glass t b" "channel=both must still post the macOS tag"
assert_contains "$OUT" "herdr done t b" "channel=both must also post the herdr tag"
pass "channel=both posts through both channels"

reset_log
printf 'channel=macos\nattention=Hero,herdr\n' > "$CONFIG"
FM_NOTIFY_CHANNEL=herdr notify_unpinned attention "t" "b"
assert_contains "$(logged)" "herdr request t b" "FM_NOTIFY_CHANNEL must win over every configured channel"
reset_log
FM_NOTIFY_CHANNEL=none notify_unpinned attention "t" "b"
[ -z "$(logged)" ] || fail "FM_NOTIFY_CHANNEL=none must post nothing"
pass "FM_NOTIFY_CHANNEL overrides both the per-class and the default configured channel"

reset_log
printf 'attention=Hero; rm -rf /\n' > "$CONFIG"
notify attention "t" "b"
assert_contains "$(logged)" "macos Sosumi t b" "an unusable sound name must fall back to the class default"
pass "a sound name that is not a plain system-sound name is refused, not passed through"

# --- off switches -----------------------------------------------------------

reset_log
printf 'pr-ready=off\n' > "$CONFIG"
notify pr-ready "t" "b"
[ -z "$(logged)" ] || fail "pr-ready=off must silence that class"
notify attention "t" "b"
assert_contains "$(logged)" "macos Sosumi" "one class switched off must not silence the others"
pass "a per-class off switch silences only that class"

reset_log
printf 'pr-ready=off,herdr\n' > "$CONFIG"
notify pr-ready "t" "b"
[ -z "$(logged)" ] || fail "off in the sound position must silence the class, not name a sound"
pass "an off switch written alongside a channel still silences the class"

reset_log
printf 'enabled=off\nattention=Hero\n' > "$CONFIG"
notify attention "t" "b"
notify pr-merged "t" "b"
notify --from-status alpha "blocked: nothing works"
[ -z "$(logged)" ] || fail "enabled=off must silence every class: $(logged)"
pass "enabled=off is a global kill switch across every class"

rm -f "$CONFIG"

# --- --once dedup between the two merge owners ------------------------------

reset_log
notify --once "pr-merged:alpha" pr-merged "firstmate: PR merged" "alpha: url"
notify --once "pr-merged:alpha" pr-merged "firstmate: PR merged" "alpha: url"
[ "$(logged | wc -l | tr -d '[:space:]')" = 1 ] || fail "--once must fire exactly once per key: $(logged)"
notify --once "pr-merged:beta" pr-merged "firstmate: PR merged" "beta: url"
[ "$(logged | wc -l | tr -d '[:space:]')" = 2 ] || fail "--once must still fire for a different key"
pass "--once keeps two owners of one merge from beeping twice, per task"

# --- scope: only a primary home reaches the captain -------------------------

reset_log
SECONDMATE=$(make_home "$TMPROOT/secondmate")
printf 'sm-alpha\n' > "$SECONDMATE/.fm-secondmate-home"
FM_HOME="$SECONDMATE" FM_STATE_OVERRIDE="$SECONDMATE/state" FM_NOTIFY_EXEC="$RECORDER" \
  "$NOTIFY" attention "t" "b"
[ -z "$(logged)" ] || fail "a secondmate home must not notify the captain directly"
pass "a secondmate home posts nothing; it reports through firstmate instead"

reset_log
CREWREPO="$TMPROOT/crewrepo"
CREWTREE="$TMPROOT/crewtree"
fm_git_worktree "$CREWREPO" "$CREWTREE" fm/task
mkdir -p "$CREWTREE/state" "$CREWTREE/bin"
: > "$CREWTREE/AGENTS.md"
FM_HOME="$CREWTREE" FM_STATE_OVERRIDE="$CREWTREE/state" FM_NOTIFY_EXEC="$RECORDER" \
  "$NOTIFY" attention "t" "b"
[ -z "$(logged)" ] || fail "a crewmate task worktree must not notify the captain"
pass "a crewmate task worktree posts nothing"

reset_log
FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$TMPROOT/elsewhere-state" FM_NOTIFY_EXEC="$RECORDER" \
  "$NOTIFY" attention "t" "b"
[ -z "$(logged)" ] || fail "a redirected state directory must not notify the captain"
assert_absent "$TMPROOT/elsewhere-state" "a refused scope must not create anything"
pass "a home whose state directory is not its own posts nothing"

# --- fail-open: no channel, no binaries, no crash ---------------------------

# A PATH carrying the notifier's own dependencies but neither channel binary:
# the state every non-macOS machine without herdr is already in, and the state
# `auto` must resolve to `none` from. The seam is deliberately NOT installed
# here, so this exercises the real channel resolution.
SPARSEBIN=$(fm_fakebin "$TMPROOT")
for tool in bash env dirname uname git tr find; do
  TOOLPATH=$(command -v "$tool" 2>/dev/null) || continue
  ln -sf "$TOOLPATH" "$SPARSEBIN/$tool"
done
[ ! -e "$SPARSEBIN/osascript" ] || fail "the sparse PATH must not carry osascript"
[ ! -e "$SPARSEBIN/herdr" ] || fail "the sparse PATH must not carry herdr"
PATH="$SPARSEBIN" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$PRIMARY/state" \
  env -u FM_NOTIFY_EXEC "$NOTIFY" attention "t" "b" >/dev/null 2>&1
NO_BIN_CODE=$?
expect_code 0 "$NO_BIN_CODE" "the notifier must exit 0 with no channel binary on PATH"
pass "a machine with neither osascript nor herdr is a silent no-op, never a failure"

FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$PRIMARY/state" FM_NOTIFY_EXEC="$TMPROOT/does-not-exist" \
  "$NOTIFY" attention "t" "b" >/dev/null 2>&1
BAD_EXEC_CODE=$?
expect_code 0 "$BAD_EXEC_CODE" "a failing channel must not fail the notifier"

FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$PRIMARY/state" FM_NOTIFY_EXEC="$RECORDER" \
  "$NOTIFY" >/dev/null 2>&1
NO_ARGS_CODE=$?
expect_code 0 "$NO_ARGS_CODE" "a malformed invocation must not fail the caller"
pass "a failing channel and a malformed invocation both exit 0 so no caller breaks"

# --- the status-surfacing owner fires the tag exactly once ------------------

SURFACE_HOME=$(make_home "$TMPROOT/surface")
SURFACE_STATE="$SURFACE_HOME/state"
reset_log

surface() {  # <task> — run mark_surfaced against the real library
  FM_HOME="$SURFACE_HOME" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$SURFACE_STATE" \
  FM_NOTIFY_EXEC="$RECORDER" FM_NOTIFY_CHANNEL=macos bash -c '
    . "$1/bin/fm-push-transition-lib.sh"
    mark_surfaced "$2"
  ' _ "$ROOT" "$SURFACE_STATE/$1.status"
}

printf 'working: under way\n' > "$SURFACE_STATE/alpha.status"
surface alpha
[ -z "$(logged)" ] || fail "a non-captain-relevant status must not notify: $(logged)"
pass "surfacing a routine status writes no notification"

printf 'done: PR https://github.com/o/r/pull/3 checks green\n' >> "$SURFACE_STATE/alpha.status"
surface alpha
assert_contains "$(logged)" "macos Ping firstmate: PR ready for review" \
  "surfacing a done: PR status must raise the review-ready tag"
[ "$(logged | wc -l | tr -d '[:space:]')" = 1 ] || fail "one surfaced status must produce one tag"

# Every later path through the same owner (the stale path, the push-transition
# path, the heartbeat backstop) re-marks the same unchanged line. None may beep.
surface alpha
surface alpha
[ "$(logged | wc -l | tr -d '[:space:]')" = 1 ] || fail "re-surfacing an unchanged status must not beep again: $(logged)"
pass "an unchanged status re-surfaced by another supervision path never beeps twice"

printf 'needs-decision: which shape\n' >> "$SURFACE_STATE/alpha.status"
surface alpha
[ "$(logged | wc -l | tr -d '[:space:]')" = 2 ] || fail "a genuinely new status must raise its own tag"
assert_contains "$(logged)" "firstmate: decision needed alpha: which shape" \
  "the new status must raise the attention tag"
pass "a genuinely new captain-relevant status raises its own tag"

echo "# fm-notify.test.sh: all assertions passed"
