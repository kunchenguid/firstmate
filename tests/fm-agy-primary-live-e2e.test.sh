#!/usr/bin/env bash
# Opt-in live guard for Antigravity CLI (agy) as a firstmate PRIMARY.
#
# Exercises live agy CLI invocation with .agents/hooks.json in an isolated
# temporary Firstmate home so SessionStart and Stop hooks run end-to-end
# against the installed agy binary.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_AGY_PRIMARY_LIVE,FM_AGY_PRIMARY_LIVE_E2E agy jq

AGY_BIN=${FM_AGY_BIN:-$(command -v agy 2>/dev/null || true)}
[ -n "$AGY_BIN" ] && [ -x "$AGY_BIN" ] \
  || fail "agy not found; install it or set FM_AGY_BIN"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-agy-primary-live.XXXXXX") || fail "could not create isolated agy lab"
HOME_DIR="$LAB/home"
AGY_USER_HOME="$LAB/user-home"
MARKER="FM_AGY_LIVE_MARKER_$$"

cleanup_all() {
  [ -n "${LAB:-}" ] && rm -rf -- "$LAB"
}
trap cleanup_all EXIT

mkdir -p "$HOME_DIR" "$AGY_USER_HOME/.gemini/antigravity-cli"
for auth_file in antigravity-oauth-token installation_id jetski_state.pbtxt settings.json; do
  if [ -f "$HOME/.gemini/antigravity-cli/$auth_file" ]; then
    cp "$HOME/.gemini/antigravity-cli/$auth_file" "$AGY_USER_HOME/.gemini/antigravity-cli/$auth_file"
  fi
done

(cd "$ROOT" && tar --exclude=.git --exclude=state --exclude=projects --exclude=node_modules -cf - .) \
  | (cd "$HOME_DIR" && tar -xf -) \
  || fail "could not stage the working tree into the throwaway home"

git init -q -b main "$HOME_DIR"
git -C "$HOME_DIR" add -A >/dev/null 2>&1 || true
git -C "$HOME_DIR" -c user.email=fmtest@example.invalid -c user.name=fmtest \
  commit -q -m "live-e2e fixture" >/dev/null 2>&1 || true

[ -f "$HOME_DIR/.agents/hooks.json" ] \
  || fail "working tree ships no .agents/hooks.json"

mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config"
printf 'Live marker: %s\n' "$MARKER" > "$HOME_DIR/data/learnings.md"
printf '# Backlog\n\n- live probe\n' > "$HOME_DIR/data/backlog.md"

HOME="$AGY_USER_HOME" "$HOME_DIR/bin/fm-agy-trust.sh" "$HOME_DIR" "live-primary" >/dev/null 2>&1 || true

OUT=$(cd "$HOME_DIR" && HOME="$AGY_USER_HOME" FM_HOME="$HOME_DIR" \
  "$AGY_BIN" -p "Reply with the exact live marker token from session start context and nothing else." \
  --model gemini-3.8-flash-low --effort low --dangerously-skip-permissions 2>&1 || true)

[ -f "$HOME_DIR/state/.lock" ] || fail "SessionStart hook did not create state/.lock in live agy run"
assert_contains "$OUT" "$MARKER" "SessionStart injectSteps systemMessage did not reach live agy context"
pass "agy primary live: SessionStart hook acquires lock and injects digest into live model context"

cleanup_all
trap - EXIT
