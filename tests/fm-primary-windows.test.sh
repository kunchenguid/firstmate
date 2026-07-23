#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PS1="$ROOT/windows/firstmate.ps1"
CMD="$ROOT/windows/firstmate.cmd"
PSTEST="$ROOT/tests/fm-primary-windows.test.ps1"

assert_present "$PS1" "PowerShell wrapper is missing"
assert_present "$CMD" "CMD refusal shim is missing"
assert_present "$PSTEST" "PowerShell wrapper contract test is missing"

if command -v powershell.exe >/dev/null 2>&1; then
  powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass \
    -File "$(wslpath -w "$PSTEST")" \
    || fail "PowerShell wrapper contract failed"
else
  python3 - "$PS1" "$CMD" <<'PY' || fail "portable Windows wrapper structure check failed"
import re
import sys
from pathlib import Path

wrapper = Path(sys.argv[1]).read_text(encoding="utf-8")
cmd = Path(sys.argv[2]).read_text(encoding="utf-8")
match = re.search(r"(?s)\$wslArgs\s*=\s*@\((.*?)\)\s*\+\s*\$args", wrapper)
assert match, "PowerShell wrapper no longer appends the original argument array"
prefix = match.group(1)
assert re.search(r"&\s+wsl\.exe\s+@wslArgs", wrapper), "PowerShell wrapper no longer splats the WSL argument array"
assert not re.search(r"Invoke-Expression|Start-Process|ArgumentList|-Command", wrapper), "PowerShell wrapper introduced string-based argument reparsing"
for value in ('"-d", "Ubuntu"', '"-u", "firstmate"', '"--cd", "/home/firstmate/firstmate"', '"-e", "/home/firstmate/firstmate/bin/fm-primary-launch.sh"'):
    assert value in prefix, f"PowerShell wrapper changed fixed routing: {value}"
assert not re.search(r"%\*|%~[0-9]", cmd), "CMD refusal shim expands untrusted arguments"
assert "run firstmate from PowerShell" in cmd, "CMD refusal does not name the safe entrypoint"
assert not re.search(r"(?im)^\s*(powershell(?:\.exe)?|wsl\.exe)\b", cmd), "CMD refusal shim unexpectedly delegates arguments"
PY
  pass "portable structure preserves PowerShell argv and CMD refusal"
fi
