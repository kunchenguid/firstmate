#!/usr/bin/env bash
# Opt-in live guard for GitHub Copilot CLI repository hook discovery and order.
#
# Copilot owns which files under .github/hooks it discovers and the order in
# which it runs them. The portable spawn regressions pin Firstmate's generated
# filename, while this guard verifies those vendor-controlled loader facts
# against the installed CLI.
set -u

if [ "${FM_COPILOT_HOOKS_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_COPILOT_HOOKS_LIVE_E2E=1 to run the live Copilot hook discovery guard"
  exit 0
fi

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

COPILOT_BIN=${FM_COPILOT_BIN:-$(command -v copilot || true)}
[ -n "$COPILOT_BIN" ] && [ -x "$COPILOT_BIN" ] \
  || fail "copilot not found; install it or set FM_COPILOT_BIN. This guard refuses to pass without checking the real harness."
command -v timeout >/dev/null 2>&1 || fail "timeout not found"

COPILOT_VERSION=$("$COPILOT_BIN" --version 2>/dev/null | head -1)
[ -n "$COPILOT_VERSION" ] || fail "copilot did not report a version"
printf 'harness: %s\n' "$COPILOT_VERSION"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-copilot-hooks.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
mkdir -p "$LAB/.github/hooks"
git init -q "$LAB"
git -C "$LAB" -c user.email=fmtest@example.invalid -c user.name=fmtest \
  commit -q --allow-empty -m init

cat > "$LAB/.github/hooks/firstmate.json" <<'JSON'
{"version":1,"hooks":{"sessionStart":[{"type":"command","bash":"printf 'firstmate\\n' >> hook-order.log","powershell":"Add-Content -LiteralPath 'hook-order.log' -Value 'firstmate'","cwd":".","timeoutSec":10}]}}
JSON
cat > "$LAB/.github/hooks/zz-firstmate-probe.json" <<'JSON'
{"version":1,"hooks":{"sessionStart":[{"type":"command","bash":"printf 'visible\\n' >> hook-order.log","powershell":"Add-Content -LiteralPath 'hook-order.log' -Value 'visible'","cwd":".","timeoutSec":10}]}}
JSON
cat > "$LAB/.github/hooks/.firstmate-hidden-probe.json" <<'JSON'
{"version":1,"hooks":{"sessionStart":[{"type":"command","bash":"printf 'hidden\\n' >> hook-order.log","powershell":"Add-Content -LiteralPath 'hook-order.log' -Value 'hidden'","cwd":".","timeoutSec":10}]}}
JSON

out=$(timeout 240 "$COPILOT_BIN" -C "$LAB" --allow-all --no-ask-user \
  -p "Reply only with OK." 2>&1)
rc=$?
[ "$rc" -eq 0 ] || fail "Copilot prompt failed before hook discovery could be verified: $out"
[ -f "$LAB/hook-order.log" ] || fail "Copilot loaded no repository sessionStart hooks"

order=$(tr -d '\r' < "$LAB/hook-order.log")
[ "$order" = $'visible\nfirstmate' ] \
  || fail "expected visible generated hook before firstmate.json and hidden hook skipped, got: $order"
pass "Copilot repository hooks ignore hidden files and load visible files in descending filename order"
