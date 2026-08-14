# shellcheck shell=bash
# Shared quota-axi compatibility check for the bootstrap diagnostic.
# Usage: . bin/fm-quota-axi-lib.sh
#
# bin/fm-reviewed-toolchain.sh owns the exact reviewed version.
# bin/fm-bootstrap.sh turns a failing check into the operator-facing MISSING
# diagnostic, which keeps a mismatched build from reaching dispatch intake.

FM_QUOTA_AXI_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-reviewed-toolchain.sh disable=SC1091
. "$FM_QUOTA_AXI_LIB_DIR/fm-reviewed-toolchain.sh"

fm_quota_axi_compatible() {
  local timeout=${1:-} output installed expected
  command -v quota-axi >/dev/null 2>&1 || return 1
  if [ -n "$timeout" ]; then
    case "$timeout" in
      ''|*[!0-9]*|0) return 1 ;;
    esac
    if command -v timeout >/dev/null 2>&1; then
      output=$(timeout "$timeout" quota-axi --version 2>/dev/null </dev/null) || return 1
    elif command -v gtimeout >/dev/null 2>&1; then
      output=$(gtimeout "$timeout" quota-axi --version 2>/dev/null </dev/null) || return 1
    elif command -v perl >/dev/null 2>&1; then
      output=$(perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$timeout" quota-axi --version 2>/dev/null </dev/null) || return 1
    else
      return 1
    fi
  else
    output=$(quota-axi --version 2>/dev/null </dev/null) || return 1
  fi
  installed=$(printf '%s\n' "$output" |
    sed -nE 's/.*[vV]?([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' |
    head -n 1)
  expected=$(fm_reviewed_tool_version quota-axi) || return 1
  [ "$installed" = "$expected" ]
}
