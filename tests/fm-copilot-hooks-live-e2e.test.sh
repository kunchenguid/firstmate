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
ASYNC_LAB=
trap 'rm -rf "$LAB" "${ASYNC_LAB:-}"' EXIT
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

ASYNC_LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-copilot-async.XXXXXX")
ASYNC_TOKEN="FM_COPILOT_ASYNC_NOTIFICATION_$$"
mkdir -p "$ASYNC_LAB/.github/hooks"
git init -q "$ASYNC_LAB"
git -C "$ASYNC_LAB" -c user.email=fmtest@example.invalid -c user.name=fmtest \
  commit -q --allow-empty -m init

cat > "$ASYNC_LAB/notification.sh" <<EOF
#!/usr/bin/env bash
set -u
payload=\$(cat)
printf '%s\n' "\$payload" >> notification.log
jq -n --arg c "$ASYNC_TOKEN" '{additionalContext:\$c}'
EOF
chmod +x "$ASYNC_LAB/notification.sh"
cat > "$ASYNC_LAB/notification.ps1" <<EOF
\$payload = [Console]::In.ReadToEnd()
Add-Content -LiteralPath "notification.log" -Value \$payload
@{ additionalContext = "$ASYNC_TOKEN" } | ConvertTo-Json -Compress
EOF
cat > "$ASYNC_LAB/.github/hooks/async-notification.json" <<'JSON'
{
  "version": 1,
  "hooks": {
    "notification": [
      {
        "matcher": "shell_completed",
        "type": "command",
        "bash": "bash ./notification.sh",
        "powershell": "& './notification.ps1'",
        "cwd": ".",
        "timeoutSec": 10
      }
    ]
  }
}
JSON

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    ASYNC_TOOL=powershell
    ASYNC_COMMAND='Start-Sleep -Seconds 2'
    ;;
  *)
    ASYNC_TOOL=bash
    ASYNC_COMMAND='sleep 2'
    ;;
esac

PROMPT="Use the $ASYNC_TOOL tool exactly once with its native asynchronous mode and the exact command: $ASYNC_COMMAND
After that tool call returns, reply exactly ASYNC_STARTED.
If a later system message contains $ASYNC_TOKEN, reply exactly $ASYNC_TOKEN.
Do not run any other tool."
out=$(COPILOT_TASK_WAIT_TIMEOUT_SECONDS=60 timeout 300 "$COPILOT_BIN" -C "$ASYNC_LAB" \
  --allow-all --no-ask-user --available-tools "$ASYNC_TOOL" -p "$PROMPT" 2>&1)
rc=$?
[ "$rc" -eq 0 ] || fail "Copilot async shell notification probe failed: $out"
assert_contains "$out" "ASYNC_STARTED" \
  "Copilot did not continue the initiating turn after starting the background shell task"
assert_contains "$out" "$ASYNC_TOKEN" \
  "a background shell completion did not inject notification additionalContext into an idle Copilot session"
[ -f "$ASYNC_LAB/notification.log" ] \
  || fail "the shell completion did not fire the configured notification hook"
grep -q '"notification_type":"shell_completed"' "$ASYNC_LAB/notification.log" \
  || fail "the notification hook did not receive a shell_completed payload: $(cat "$ASYNC_LAB/notification.log")"
pass "Copilot background shell completion asynchronously injects a follow-up turn"

rm -rf "$ASYNC_LAB"
ASYNC_LAB=
