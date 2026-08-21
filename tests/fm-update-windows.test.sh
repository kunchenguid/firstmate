#!/usr/bin/env bash
# Windows regression for bin/fm-update.ps1.
#
# The PowerShell wrapper must locate Git Bash from git.exe even when Git Bash is
# absent from PATH and an unrelated ambient bash command takes precedence.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) ;;
  *)
    echo "skip: Windows only"
    exit 0
    ;;
esac

POWERSHELL=$(command -v powershell.exe || true)
[ -n "$POWERSHELL" ] || {
  echo "skip: Windows PowerShell not found"
  exit 0
}

UPDATE_WINDOWS=$(cygpath -w "$ROOT/bin/fm-update.ps1")

output=$(
  "$POWERSHELL" -NoProfile -ExecutionPolicy Bypass -Command "
    \$gitPath = (Get-Command git.exe -CommandType Application -ErrorAction Stop).Source
    \$gitDirectory = Split-Path -Parent \$gitPath
    \$env:Path = \"\$env:SystemRoot\\System32;\$gitDirectory\"
    \$ambientBash = (Get-Command bash.exe -CommandType Application -ErrorAction SilentlyContinue).Source
    Write-Output \"ambient-bash=\$ambientBash\"
    & '$UPDATE_WINDOWS' --help
  " 2>&1
)
status=$?

[ "$status" -eq 0 ] || fail "Windows updater failed when Git Bash was absent from PATH: $output"
assert_contains "$output" "usage: fm-update.sh [--help]" "Windows wrapper reached the Bash updater"
assert_contains "$output" "ambient-bash=" "test recorded the competing ambient bash resolution"
pass "Windows updater resolves Git Bash from Git for Windows instead of ambient PATH"
