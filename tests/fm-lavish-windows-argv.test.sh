#!/usr/bin/env bash
# Executable-boundary regression for Windows PowerShell 5.1 argv forwarding.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if ! command -v powershell.exe >/dev/null 2>&1 || ! command -v wslpath >/dev/null 2>&1; then
  printf 'skip: Windows PowerShell interoperability is unavailable\n'
  exit 0
fi

TMP_ROOT=$(fm_test_tmproot fm-lavish-windows-argv)
FIXTURE="$TMP_ROOT/fixture"
LOG="$TMP_ROOT/argv.json"
mkdir -p "$FIXTURE/node_modules/lavish-axi"
printf '@exit /b 99\r\n' > "$FIXTURE/lavish-axi.cmd"
printf '{"bin":{"lavish-axi":"cli.js"}}\n' > "$FIXTURE/node_modules/lavish-axi/package.json"
printf '%s\n' "require('fs').writeFileSync(process.env.FM_LAVISH_ARGV_LOG, JSON.stringify(process.argv.slice(2)));" > "$FIXTURE/node_modules/lavish-axi/cli.js"

FIXTURE_WIN=$(wslpath -w "$FIXTURE") || fail "could not convert the fixture path"
BRIDGE_WIN=$(wslpath -w "$ROOT/bin/fm-lavish-windows.ps1") || fail "could not convert the bridge path"
LOG_WIN=$(wslpath -w "$LOG") || fail "could not convert the log path"
export FM_LAVISH_WINDOWS_ARGV_JSON='["","--foo","stop value"]'
export FM_LAVISH_ARGV_LOG="$LOG_WIN"
export WSLENV="${WSLENV:+$WSLENV:}FM_LAVISH_WINDOWS_ARGV_JSON:FM_LAVISH_ARGV_LOG"

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command \
  "\$env:Path = '$FIXTURE_WIN;' + \$env:Path; & '$BRIDGE_WIN' stop" \
  || fail "the real PowerShell bridge invocation failed"
actual=$(perl -MJSON::PP -e 'print join("\n", map { "<$_>" } @{decode_json(do { local $/; <> })})' "$LOG")
[ "$actual" = $'<stop>\n<>\n<--foo>\n<stop value>' ] \
  || fail "PowerShell changed forwarded argv: $actual"
pass "PowerShell 5.1 preserves empty and stop-style arguments"
