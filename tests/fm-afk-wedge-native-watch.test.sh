#!/usr/bin/env bash
# tests/fm-afk-wedge-native-watch.test.sh - the harness-native wedge watch the
# afk skill instructs firstmate to arm alongside the daemon on a harness with a
# native tracked-background tool (Claude's Monitor over a background Bash,
# Codex's own background task tool). Regression for the 2026-08 incident: a
# thousand injections deferred over four hours because the primary composer was
# never read and the wedge alarm had no active channel on this Linux/WSL host.
#
# The skill text (.agents/skills/afk/SKILL.md) prescribes the watch's exact
# contract in prose because arming it is a harness tool call the skill's reader
# performs, not a script this repo ships. This test builds that exact
# prescribed polling body as a standalone portable executable and drives it
# through both trigger conditions plus the no-trigger case, proving the
# contract is correct and vendor-portable (POSIX sh, no bashisms) before any
# harness is asked to run it. Both vendors read the identical body: Claude
# wraps it in a background Bash + Monitor pair, Codex hands it to its own
# background task tool - the body itself has no harness dependency to fake.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-afk-wedge-native-watch-tests)

# The prescribed one-shot polling body: watch state/.subsuper-inject-wedged and
# the age of state/.subsuper-escalations against max-defer; on the first
# trigger, print exactly one line to stdout (the harness attaches its own
# notification surface to that stdout) and exit 0. No trigger within the
# bounded iteration budget exits 1 with no output, so a caller can tell a
# genuine timeout apart from a fired watch.
install_watch() {  # <dir>
  local dir=$1
  cat > "$dir/native-wedge-watch.sh" <<'SH'
#!/bin/sh
# Portable one-shot wedge watch: see .agents/skills/afk/SKILL.md
# "Also arm a native wedge watch". <state> <max_defer_secs> <interval_secs> <max_iters>
set -u
state=$1
max_defer=$2
interval=$3
max_iters=$4
i=0
while [ "$i" -lt "$max_iters" ]; do
  if [ -s "$state/.subsuper-inject-wedged" ]; then
    printf 'native wedge watch fired: marker present at %s\n' "$state/.subsuper-inject-wedged"
    exit 0
  fi
  if [ -s "$state/.subsuper-escalations" ] && [ -f "$state/.subsuper-escalations.since" ]; then
    since=$(cat "$state/.subsuper-escalations.since" 2>/dev/null || echo 0)
    now=$(date +%s)
    age=$((now - since))
    if [ "$age" -ge "$max_defer" ]; then
      printf 'native wedge watch fired: escalation buffer age %ss >= max-defer %ss\n' "$age" "$max_defer"
      exit 0
    fi
  fi
  i=$((i + 1))
  sleep "$interval"
done
exit 1
SH
  chmod +x "$dir/native-wedge-watch.sh"
}

test_wedge_marker_fires_exactly_one_line() {
  local dir out rc
  dir="$TMP_ROOT/marker"
  mkdir -p "$dir/state"
  install_watch "$dir"
  printf 'fm away-mode inject WEDGED: 400s undelivered\n' > "$dir/state/.subsuper-inject-wedged"
  set +e
  out=$("$dir/native-wedge-watch.sh" "$dir/state" 300 0.02 20)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "watch did not fire on an existing wedge marker (rc=$rc)"
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" -eq 1 ] || fail "watch printed more than one line: $out"
  assert_contains "$out" 'native wedge watch fired' "watch output did not name the fired condition"
  assert_contains "$out" "$dir/state/.subsuper-inject-wedged" "watch output did not name the marker path"
  pass "an existing wedge marker fires the watch with exactly one line and exit 0"
}

test_escalation_age_past_max_defer_fires() {
  local dir out rc
  dir="$TMP_ROOT/age"
  mkdir -p "$dir/state"
  install_watch "$dir"
  printf 'done: PR https://example/pull/1\n' > "$dir/state/.subsuper-escalations"
  echo $(( $(date +%s) - 500 )) > "$dir/state/.subsuper-escalations.since"
  set +e
  out=$("$dir/native-wedge-watch.sh" "$dir/state" 300 0.02 20)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "watch did not fire once the escalation buffer aged past max-defer (rc=$rc)"
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" -eq 1 ] || fail "watch printed more than one line: $out"
  assert_contains "$out" 'max-defer' "watch output did not name the max-defer condition"
  pass "an escalation buffer aged past max-defer fires the watch even with no wedge marker yet"
}

test_neither_condition_stays_silent() {
  local dir out rc
  dir="$TMP_ROOT/quiet"
  mkdir -p "$dir/state"
  install_watch "$dir"
  printf 'done: PR https://example/pull/2\n' > "$dir/state/.subsuper-escalations"
  date +%s > "$dir/state/.subsuper-escalations.since"
  set +e
  out=$("$dir/native-wedge-watch.sh" "$dir/state" 300 0.02 5)
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "watch fired before either trigger condition was met (rc=$rc)"
  [ -z "$out" ] || fail "watch produced output while neither condition was met: $out"
  pass "neither an absent marker nor a fresh escalation buffer produces any output before its budget runs out"
}

test_wedge_marker_fires_exactly_one_line
test_escalation_age_past_max_defer_fires
test_neither_condition_stays_silent
