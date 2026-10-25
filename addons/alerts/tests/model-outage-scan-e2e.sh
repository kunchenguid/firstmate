#!/usr/bin/env bash
# Model-outage scan behaviour over fixture lanes: the real fm_model_outage_tick
# from this add-on, with backend liveness, the lane verdict and the wake sink
# faked; busy-gen and the pane capture are the real on-disk contract.
# FM_TEST_FORK names a read-only Firstmate checkout whose bin/ holds the sibling
# libraries; the watcher itself is never run.
# shellcheck disable=SC2031 # the case bodies run inside run_scans' subshell, where FAKE_LIVENESS is set
set -euo pipefail
addons=$(cd "$(dirname "$0")/../.." && pwd)
: "${FM_TEST_FORK:?set FM_TEST_FORK to a Firstmate checkout}"
d=$(mktemp -d)
cleanup() {
  rc=$?
  if [ "$rc" -eq 0 ]; then rm -rf -- "$d"; else printf 'fixture retained: %s\n' "$d" >&2; fi
}
trap cleanup EXIT
export HOME=$d/user TMPDIR=$d/tmp
mkdir -p "$HOME" "$TMPDIR" "$d/fork"
cp -a "$FM_TEST_FORK/bin" "$d/fork/bin"
rm -f "$d/fork/bin/fm-model-outage-lib.sh"
cat > "$d/fork/bin/fm-backend.sh" <<'FAKE'
fm_backend_agent_state() { cat "$FAKE_LIVENESS/$4" 2>/dev/null || printf alive; }
fm_backend_visible_capture_supported() { return 0; }
fm_backend_visible_capture() { local t=${2#fake:}; cat "$FAKE_LIVENESS/capture-${t%.meta}" 2>/dev/null; }
FAKE
cat > "$d/fork/bin/fm-busy-lib.sh" <<'FAKE'
fm_busy_classify_semantic() {
  local verdict
  verdict=$(cat "$STATE/$4.verdict")
  if [ "$verdict" = hang ]; then sleep 30; printf 'idle opencode-plugin\n'; return 0; fi
  printf '%s\n' "$verdict"
}
FAKE

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok: $*"; }

# run_scans <case> <body>: runs <body> in a subshell with lane/tick helpers.
# lane <id> <verdict> <liveness> [error] sets a lane; wakes land in <case>/wakes.
run_scans() {
  local case_dir=$d/$1 body=$2
  mkdir -p "$case_dir/state" "$case_dir/liveness"
  # shellcheck disable=SC2317,SC2329,SC2030,SC2031 # the sourced library calls the stubs; the body is called indirectly
  (
    export FM_HOME=$d/fork SCRIPT_DIR=$d/fork/bin STATE=$case_dir/state FAKE_LIVENESS=$case_dir/liveness
    # shellcheck source=/dev/null
    . "$addons/alerts/bin/fm-model-outage-lib.sh"
    fm_busy_token_valid() { return 0; }
    fm_busy_current_gen() { cat "$1/$2.busy-gen"; }
    fm_meta_get() { printf opencode; }
    fm_backend_visible_capture_supported() { return 0; }
    fm_backend_target_of_meta() { printf 'fake:%s' "${1##*/}"; }
    fm_backend_of_meta() { printf fake; }
    hash_pane() { md5sum | cut -c1-12; }
    wake() { :; }
    fm_wake_append() { printf '%s\n' "$3" >> "$case_dir/wakes"; }
    lane() {
      : > "$STATE/$1.meta"
      printf 'g1\n' > "$STATE/$1.busy-gen"
      printf '%s\n' "$2" > "$STATE/$1.verdict"
      printf '%s\n' "$3" > "$FAKE_LIVENESS/$1"
      printf '%s\n' "${4-Upstream request failed: region denied}" > "$FAKE_LIVENESS/capture-$1"
    }
    tick() { ( rm -f "$STATE/.model-outages/.scan-at"; fm_model_outage_tick ); }
    "$body"
  ) || fail "$1: scans failed"
  if compgen -G "$case_dir/state/.model-outages/.scan.*" >/dev/null; then fail "$1: a scan batch directory leaked"; fi
}

# expect_wakes <case> <expected lines...>: the wake file holds exactly these lines.
expect_wakes() {
  local name=$1 case_dir=$d/$1; shift
  [ "$(cat "$case_dir/wakes" 2>/dev/null)" = "$(printf '%s\n' "$@")" ] \
    || fail "$name: unexpected wakes: $(cat "$case_dir/wakes" 2>/dev/null)"
}
expect_no_wakes() { [ ! -s "$d/$1/wakes" ] || fail "$1: expected no wake, got: $(cat "$d/$1/wakes")"; }

ERR='Upstream request failed: region denied'
FLOOR='  ╹▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀'
limit_banner() {  # <reset minutes> <retry minutes>: the real 5-hour usage-limit rows
  printf '%s\n' "   ■5⬝hour⬝usage limit reached. It will reset in 1 hour $1 minutes. To cont" \
    "    usin... (click to expand) [retrying in 1h $2m attempt #1]"
}

# A lane joining an alerted episode sends one union wake; a dead mid-turn lane is not named.
staggered() {
  lane alpha "idle opencode-plugin" alive; tick
  lane bravo "idle opencode-plugin" alive
  lane charlie "busy opencode-plugin" missing
  tick; tick
}
run_scans union staggered
expect_wakes union "check: model outage affected=[alpha]: $ERR" "check: model outage affected=[alpha,bravo]: $ERR"
pass "a staggered lane joins its alerted outage in one union wake; a dead mid-turn lane is not named"

# A recovered lane leaves the wake and is named again when it re-fails.
recovered() {
  lane alpha "idle opencode-plugin" alive; tick
  lane alpha "idle opencode-plugin" alive ""
  lane bravo "idle opencode-plugin" alive; tick
  lane alpha "idle opencode-plugin" alive; tick
}
run_scans recovered recovered
expect_wakes recovered "check: model outage affected=[alpha]: $ERR" "check: model outage affected=[bravo]: $ERR" "check: model outage affected=[alpha,bravo]: $ERR"
pass "a recovered lane leaves the alert record and re-alerts when it fails again"

# An unreadable lane is not named while unreadable, and is named again once it reads failing.
unreadable() {
  lane alpha "idle opencode-plugin" alive
  lane bravo "idle opencode-plugin" alive; tick
  lane bravo "idle opencode-plugin" unreadable
  lane alpha "idle opencode-plugin" alive ""; tick
  lane bravo "idle opencode-plugin" alive; tick
}
run_scans unreadable unreadable
expect_wakes unreadable "check: model outage affected=[alpha,bravo]: $ERR" "check: model outage affected=[bravo]: $ERR"
pass "an unreadable lane is named again once it reads failing, never silently pinned"

# A hung verdict read is bounded: it cannot block the scan or name a lane.
hung() { lane delta hang alive; tick; }
started=$SECONDS
run_scans hung hung
expect_no_wakes hung
[ $((SECONDS - started)) -lt 20 ] || fail "a hung verdict read blocked the scan for $((SECONDS - started))s"
pass "a hung verdict read is bounded and names no lane"

# The episode identity is the banner line: text below a wrapped banner changes the error, not the episode.
wrapped() {
  lane alpha "idle opencode-plugin" alive
  printf '%s\n' "$ERR" '' 'composer A' > "$FAKE_LIVENESS/capture-alpha"; tick
  printf '%s\n' "$ERR" '' 'composer B' > "$FAKE_LIVENESS/capture-alpha"; tick
}
run_scans wrapped wrapped
expect_wakes wrapped "check: model outage affected=[alpha]: $ERR composer A"
pass "a wrapped legacy banner keeps its episode when unrelated pane text below it changes"

# A mid-turn lane on the usage-limit banner alerts once; its ticking clocks never split the episode.
midturn() {
  lane alpha "busy opencode-plugin" alive ""
  local m
  for m in 38 37 36; do
    { printf '%s\n' "$FLOOR"; limit_banner "$m" "$((m - 30))"; } > "$FAKE_LIVENESS/capture-alpha"; tick
  done
}
run_scans midturn midturn
expect_wakes midturn "check: model outage affected=[alpha]: 5 hour usage limit reached. It will reset in 1 hour 37 minutes. To cont usin... (click to expand) [retrying in 1h 7m attempt #1]"
pass "a mid-turn usage-limit lane alerts once; ticking clocks keep one episode"

# A banner-shaped line a worker printed above the composer is scrollback, not status: no alert.
above() {
  lane alpha "busy opencode-plugin" alive ""
  { limit_banner 38 8; printf '%s\n' '  ┃  typed draft' "$FLOOR" '  /work/worktree  22.1K (2%)'; } > "$FAKE_LIVENESS/capture-alpha"; tick
}
run_scans above above
expect_no_wakes above
pass "a worker-printed banner above the composer does not alert a busy lane"

# A floor-then-banner pair in scrollback above the live footer is worker text: no alert.
scrollback() {
  lane alpha "busy opencode-plugin" alive ""
  { printf '%s\n' "$FLOOR"; limit_banner 38 8; printf '%s\n' '' '  ┃  Build · DeepSeek V4.1 Flash OpenCode Go' "$FLOOR" '  /work/worktree  22.1K (2%)'; } > "$FAKE_LIVENESS/capture-alpha"; tick
}
run_scans scrollback scrollback
expect_no_wakes scrollback
pass "a worker-printed floor-then-banner in scrollback does not alert a busy lane"
