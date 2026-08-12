#!/usr/bin/env bash
# Live drift guard for the agy (Google Antigravity CLI) adapter's
# harness-dependent signals: the per-workspace hook events the busy contract
# rides (PreInvocation/Stop), the trust-gated hook loading the spawn pre-trust
# relies on, and the separated `>`-pair composer verdict backed by the tmux
# identity probe. Opt-in (live-harness-optin family): it launches the REAL
# installed agy, spends real model quota on one trivial turn, and briefly adds
# one scratch-workspace entry to the operator's agy trust store, removed on
# cleanup. Run after every agy upgrade and before trusting refreshed evidence
# in docs/verification/antigravity.md.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGY_BIN=$(command -v agy 2>/dev/null || true)
[ -n "$AGY_BIN" ] || AGY_BIN="${HOME:-}/.local/bin/agy"
REAL_TMUX=$(command -v tmux 2>/dev/null || true)
LAB=
SOCKET="fm-agy-signals-$$"
SESSION=agy-signals
TARGET="$SESSION:agy"
SETTINGS="${HOME:-}/.gemini/antigravity-cli/settings.json"
WORKSPACE=
TRUST_ADDED=0

remove_trust_entry() {
  [ "$TRUST_ADDED" = 1 ] || return 0
  [ -n "$WORKSPACE" ] && [ -f "$SETTINGS" ] || return 0
  if jq --arg wt "$WORKSPACE" \
    '.trustedWorkspaces = ((.trustedWorkspaces // []) | map(select(. != $wt)))' \
    "$SETTINGS" > "$SETTINGS.fm-live-tmp.$$" 2>/dev/null; then
    mv -f "$SETTINGS.fm-live-tmp.$$" "$SETTINGS"
  else
    rm -f "$SETTINGS.fm-live-tmp.$$"
  fi
  TRUST_ADDED=0
}

cleanup() {
  [ -n "$REAL_TMUX" ] && "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  remove_trust_entry
  [ -z "$LAB" ] || rm -rf -- "$LAB"
}

agy_version() {
  "$AGY_BIN" --version 2>/dev/null | head -1
}

fail() {
  printf 'not ok - agy %s: %s\n' "$(agy_version)" "$1" >&2
  cleanup
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

if [ "${FM_AGY_SIGNALS_LIVE:-0}" != 1 ]; then
  echo "skip: set FM_AGY_SIGNALS_LIVE=1 to run the real agy signal drift guard"
  exit 0
fi

[ -x "$AGY_BIN" ] || { printf 'not ok - FM_AGY_SIGNALS_LIVE=1 but no real agy executable is installed (PATH or ~/.local/bin/agy)\n' >&2; exit 1; }
[ -x "$REAL_TMUX" ] || fail "tmux is not installed"
command -v jq >/dev/null 2>&1 || fail "jq is required for the trust-store edit"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-agy-signals.XXXXXX") || fail "could not create the isolated agy lab"
trap cleanup EXIT
mkdir -p "$LAB/bin" "$LAB/workspace/.agent"
git -C "$LAB/workspace" init -q || fail "could not initialize the isolated agy workspace"
WORKSPACE=$(cd "$LAB/workspace" && pwd) || fail "could not resolve the isolated agy workspace"

# Per-workspace hook logger: the exact surface fm-spawn wires, minus the busy
# record, so the guard observes agy's raw event delivery.
cat > "$LAB/hooklog.sh" <<SH
#!/bin/sh
cat >/dev/null
printf '%s\n' "\$1" >> "$LAB/events.log"
printf '{}'
SH
chmod +x "$LAB/hooklog.sh"
cat > "$WORKSPACE/.agent/hooks.json" <<EOF
{"fm-live-guard":{"PreInvocation":[{"command":"$LAB/hooklog.sh PreInvocation"}],"Stop":[{"command":"$LAB/hooklog.sh Stop"}]}}
EOF
: > "$LAB/events.log"

# Pre-trust the scratch workspace exactly as fm-spawn does; hooks only load
# when the workspace is trusted AT LAUNCH (docs/verification/antigravity.md).
[ -f "$SETTINGS" ] || fail "agy settings file '$SETTINGS' is absent; run agy once to create it"
jq -e . "$SETTINGS" >/dev/null 2>&1 || fail "agy settings file '$SETTINGS' is not valid JSON"
jq --arg wt "$WORKSPACE" '.trustedWorkspaces = (((.trustedWorkspaces // []) + [$wt]) | unique)' \
  "$SETTINGS" > "$SETTINGS.fm-live-tmp.$$" || fail "could not compose the trust edit"
mv -f "$SETTINGS.fm-live-tmp.$$" "$SETTINGS" || fail "could not write the trust edit"
TRUST_ADDED=1

cat > "$LAB/bin/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$LAB/bin/tmux"
PATH="$LAB/bin:$PATH"
export PATH

# shellcheck source=bin/fm-tmux-lib.sh
. "$ROOT/bin/fm-tmux-lib.sh"

"$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -n control -c "$WORKSPACE" \
  || fail "could not start the isolated tmux server"
"$REAL_TMUX" -L "$SOCKET" new-window -d -t "$SESSION:" -n agy -c "$WORKSPACE" -- \
  env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS \
  "$AGY_BIN" --dangerously-skip-permissions --model gemini-3.6-flash-low \
  -i "Say exactly LIVE_GUARD_OK and nothing else." \
  || fail "could not launch agy"

# The trust dialog must NOT appear: the workspace was pre-trusted.
for _ in $(seq 1 50); do
  if "$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$TARGET" 2>/dev/null \
    | grep -q 'trust this folder'; then
    fail "the trust dialog appeared despite the pre-trust edit"
  fi
  grep -q PreInvocation "$LAB/events.log" 2>/dev/null && break
  sleep 0.4
done
grep -q PreInvocation "$LAB/events.log" \
  || fail "no PreInvocation hook event arrived from the pre-trusted workspace hook file"
pass "agy's workspace hook file fires PreInvocation for a pre-trusted launch"

STOPPED=0
for _ in $(seq 1 150); do
  if grep -q '^Stop$' "$LAB/events.log" 2>/dev/null; then STOPPED=1; break; fi
  sleep 0.4
done
[ "$STOPPED" = 1 ] || fail "no Stop hook event closed the turn"
pass "agy's Stop hook event closes the turn"

"$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$TARGET" | grep -q 'LIVE_GUARD_OK' \
  || fail "the initial -i prompt did not produce its response in the pane"

IDENTITY=$(fm_tmux_composer_identity "$TARGET" 2>/dev/null || true)
[ "$IDENTITY" = "$(printf 'agy\tidle')" ] \
  || fail "the tmux identity probe read '$IDENTITY', expected agy<TAB>idle"
pass "the tmux identity probe reports a live idle agy"

COMPOSER_STATE=
for _ in $(seq 1 50); do
  COMPOSER_STATE=$(fm_tmux_composer_state "$TARGET")
  [ "$COMPOSER_STATE" = empty ] && break
  sleep 0.2
done
[ "$COMPOSER_STATE" = empty ] \
  || fail "the shared classifier read agy's real idle composer as '$COMPOSER_STATE'"
pass "agy's real idle >-pair composer classifies empty through the shared owner"

cleanup
trap - EXIT
