#!/usr/bin/env bash
# Live opt-in drift guard for the Grok Build CLI adapter's launch-profile and
# capacity facts.
#
# All of these are harness-dependent: the accepted reasoning-effort vocabulary,
# the headless single-turn surface, the no-pty failure text, and whether the
# quota surface resolves a window at all come from what the vendor emits. Grok's
# effort ceiling has already moved once under firstmate - 0.2.99 rejected xhigh,
# 1.0.4 accepts it - which is exactly the drift this guard exists to catch.
# Fails naming the harness and version.
#
# Refresh docs/verification/runtime-backends.md from this guard after every grok
# upgrade.
set -u

GROK_BIN=$(command -v grok 2>/dev/null || true)
LAB=
VERSION=

cleanup() {
  [ -z "$LAB" ] || rm -rf -- "$LAB"
}

fail() {
  printf 'not ok - grok %s: %s\n' "${VERSION:-unknown-version}" "$1" >&2
  cleanup
  exit 1
}

pass() {
  printf 'ok - grok %s: %s\n' "$VERSION" "$1"
}

if [ "${FM_GROK_SIGNALS_LIVE:-0}" != 1 ]; then
  echo "skip: set FM_GROK_SIGNALS_LIVE=1 to run the real grok signal drift guard"
  exit 0
fi

[ -x "$GROK_BIN" ] || fail "FM_GROK_SIGNALS_LIVE=1 but no real grok executable is installed on PATH"

VERSION=$("$GROK_BIN" --version 2>/dev/null | head -1)
[ -n "$VERSION" ] || fail "the installed grok did not report a version"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-grok-signals.XXXXXX") || fail "could not create the isolated grok lab"
trap cleanup EXIT
cd "$LAB" || fail "could not enter the isolated grok lab"

# --- the accepted reasoning-effort vocabulary -------------------------------
#
# Read it from grok's own refusal rather than from a remembered list. This costs
# nothing: the value is rejected before any API call.
REFUSAL=$("$GROK_BIN" --reasoning-effort fm-not-a-tier -p x 2>&1 | head -2 || true)
case "$REFUSAL" in
  *"unknown effort level"*) ;;
  *) fail "grok no longer names its accepted effort levels when refusing one; re-verify the mapping in bin/fm-spawn.sh (got: $REFUSAL)" ;;
esac

# firstmate maps exactly what the binary accepts and omits what it rejects.
for tier in low medium high xhigh; do
  case "$REFUSAL" in
    *"$tier"*) ;;
    *) fail "grok no longer accepts effort '$tier', which bin/fm-spawn.sh still passes; correct the mapping" ;;
  esac
done
case "$REFUSAL" in
  *max*) fail "grok now accepts effort 'max', which bin/fm-spawn.sh still omits; correct the mapping" ;;
esac
pass "grok's accepted effort vocabulary is still low|medium|high|xhigh with no max"

# The highest tier firstmate passes must actually work, not merely parse. A
# vocabulary listing states what is offered; only a real turn states what is usable.
OUT=$("$GROK_BIN" --reasoning-effort xhigh -p 'Reply with exactly: XHIGH-OK' 2>&1) \
  || fail "grok refused a real single-turn prompt at the highest effort firstmate passes: $OUT"
case "$OUT" in
  *XHIGH-OK*) ;;
  *) fail "grok's headless single-turn surface did not answer at the highest effort firstmate passes: $OUT" ;;
esac
pass "grok answers a real headless single turn at the highest effort firstmate passes"

# --- a missing pty is a harness artifact, never an auth fault ---------------
#
# The bare TUI form cannot run without a pty and says so in OS terms. Nothing in
# firstmate may read that as a credential problem, because the two need opposite
# responses: one is a test-harness limitation, the other needs the captain.
NOPTY=$("$GROK_BIN" --always-approve 'hi' < /dev/null 2>&1 | head -3 || true)
case "$NOPTY" in
  *"Device not configured"*|*"os error 6"*) ;;
  *) fail "grok's no-pty failure text changed; re-verify that firstmate still separates it from an auth fault (got: $NOPTY)" ;;
esac
for word in auth login credential unauthorized "API key"; do
  case "$NOPTY" in
    *"$word"*)
      fail "grok's no-pty failure now mentions '$word', so a harness artifact could be misread as a credential need: $NOPTY"
      ;;
  esac
done
pass "grok's no-pty failure is an OS device error and names no credential problem"

# --- capacity evidence, or the honest absence of it -------------------------
#
# grok's auth is usable while its quota surface resolves nothing. That pairing is
# the trap the credit selector must not fall into, so assert the shape rather
# than assuming it holds.
if command -v quota-axi >/dev/null 2>&1; then
  QUOTA=$(quota-axi --provider grok --json 2>/dev/null || true)
  if [ -n "$QUOTA" ] && command -v jq >/dev/null 2>&1; then
    WINDOWS=$(printf '%s' "$QUOTA" | jq -r '[.providers[]? | select(.provider == "grok") | .windows[]?] | length' 2>/dev/null || printf 'unknown')
    if [ "$WINDOWS" != 0 ]; then
      printf 'note - grok %s: quota-axi now resolves %s quota window(s) for grok, which bin/fm-dispatch-select.mjs could price; re-read its provider notes\n' \
        "$VERSION" "$WINDOWS"
    else
      pass "quota-axi still resolves no grok quota window, so grok stays unpriceable"
    fi
  fi
fi

# --- the native model catalog ------------------------------------------------
MODELS=$("$GROK_BIN" models 2>&1 || true)
case "$MODELS" in
  *grok-*) ;;
  *) fail "grok models no longer lists any grok-* id; bin/fm-model-refresh.sh's grok surface has moved: $MODELS" ;;
esac
pass "grok's native model listing surface still answers"

cleanup
trap - EXIT
echo "ALL PASS: fm-grok-signals-live-e2e (grok $VERSION)"
