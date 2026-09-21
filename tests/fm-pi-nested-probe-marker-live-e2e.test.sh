#!/usr/bin/env bash
# Token-free live guard: a nested Pi CLI must not replace a live session binding.
#
# Why this file exists: on current Pi, `pi --help` and `pi --list-models` load
# trusted project extensions. A short-lived child of a live Pi session used to
# overwrite both marker files with its own pid, which then died and produced
# false PI_WATCH_EXTENSION / supervision-off alarms. A stub cannot see that
# vendor load behavior, so this guard runs the real CLI and fails naming the
# installed Pi version.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_PI_NESTED_PROBE_MARKER_LIVE pi

PI_VERSION=$(pi --version 2>/dev/null || printf 'unknown')
LAB=$(fm_test_tmproot fm-pi-nested-probe-marker)
HOME_DIR="$LAB/pi-home"
PROJECT="$LAB/project"
FM_HOME_DIR="$LAB/home"
STATE="$FM_HOME_DIR/state"

fail_pi() { fail "$1 (Pi ${PI_VERSION})"; }

mkdir -p "$HOME_DIR/.pi/agent" "$PROJECT/.pi/extensions/lib" "$PROJECT/bin" \
  "$FM_HOME_DIR/state" "$FM_HOME_DIR/config" "$FM_HOME_DIR/data" "$FM_HOME_DIR/projects"
printf '%s\n' '{"defaultProjectTrust":"always"}' > "$HOME_DIR/.pi/agent/settings.json"
cp "$ROOT/.pi/extensions/fm-primary-pi-watch.ts" "$PROJECT/.pi/extensions/"
cp "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$PROJECT/.pi/extensions/"
cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$PROJECT/.pi/extensions/lib/"
cp "$ROOT/.pi/extensions/lib/fm-async-exec.ts" "$PROJECT/.pi/extensions/lib/"
cp "$ROOT/.pi/extensions/lib/fm-branch-dispatch.ts" "$PROJECT/.pi/extensions/lib/"
cp "$ROOT/.pi/extensions/lib/fm-native-contract.ts" "$PROJECT/.pi/extensions/lib/"
cp "$ROOT/.pi/extensions/lib/fm-calm-visibility.ts" "$PROJECT/.pi/extensions/lib/"
cp "$ROOT/bin/fm-operational-input.sh" "$PROJECT/bin/"
chmod +x "$PROJECT/bin/fm-operational-input.sh"
cat > "$PROJECT/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'watcher: stub pid=%s\n' "$$"
SH
chmod +x "$PROJECT/bin/fm-watch-arm.sh"

export FM_HOME="$FM_HOME_DIR" FM_ROOT_OVERRIDE="$PROJECT"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-wake-lib.sh"

WATCH_VER=$(fm_pi_extension_version "$PROJECT/.pi/extensions/fm-primary-pi-watch.ts")
TURNEND_VER=$(fm_pi_extension_version "$PROJECT/.pi/extensions/fm-primary-turnend-guard.ts")
line2() { sed -n '2p' "$1" 2>/dev/null; }

run_pi_help() {
  (
    cd "$PROJECT" || exit 1
    HOME="$HOME_DIR" FM_HOME="$FM_HOME_DIR" FM_ROOT_OVERRIDE="$PROJECT" \
      pi --help >/dev/null
  )
}

# Positive control: a free lock must receive a marker, or --help no longer
# loads project extensions and the rest of the guard would be vacuous.
run_pi_help
watch_pid=$(line2 "$STATE/.pi-watch-extension-loaded")
turnend_pid=$(line2 "$STATE/.pi-turnend-extension-loaded")
[ -n "$watch_pid" ] || fail_pi "pi --help did not load the watch extension onto a free lock"
[ -n "$turnend_pid" ] || fail_pi "pi --help did not load the turn-end extension onto a free lock"
pass "pi --help still loads project extensions onto a free lock"

printf '%s\n' "$$" > "$STATE/.lock"
printf '%s\n%s\n' "$WATCH_VER" "$$" > "$STATE/.pi-watch-extension-loaded"
printf '%s\n%s\n' "$TURNEND_VER" "$$" > "$STATE/.pi-turnend-extension-loaded"
run_pi_help
[ "$(line2 "$STATE/.pi-watch-extension-loaded")" = "$$" ] \
  || fail_pi "pi --help replaced a live watch binding"
[ "$(line2 "$STATE/.pi-turnend-extension-loaded")" = "$$" ] \
  || fail_pi "pi --help replaced a live turn-end binding"
fm_pi_extension_owns_supervision "$STATE" "$PROJECT" \
  || fail_pi "pi --help left supervision unbound"
pass "pi --help leaves a live ancestor binding in place"

(
  cd "$PROJECT" || exit 1
  HOME="$HOME_DIR" FM_HOME="$FM_HOME_DIR" FM_ROOT_OVERRIDE="$PROJECT" \
    "$ROOT/bin/fm-spawn.sh" probe-x /nonexistent-project --scout --harness pi --backend tmux
) >/dev/null 2>&1 || true
[ "$(line2 "$STATE/.pi-watch-extension-loaded")" = "$$" ] \
  || fail_pi "refused fm-spawn Pi probe replaced a live watch binding"
[ "$(line2 "$STATE/.pi-turnend-extension-loaded")" = "$$" ] \
  || fail_pi "refused fm-spawn Pi probe replaced a live turn-end binding"
fm_pi_extension_owns_supervision "$STATE" "$PROJECT" \
  || fail_pi "refused fm-spawn Pi probe left supervision unbound"
pass "refused Pi-harness spawn leaves a live ancestor binding in place"
