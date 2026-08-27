# shellcheck shell=bash
# Shared quota-axi compatibility floor for the bootstrap diagnostic.
# Usage: . bin/fm-quota-axi-lib.sh
#
# FM_QUOTA_AXI_MIN follows the axi-family floor policy owned beside the floor
# constants in bin/fm-bootstrap.sh.
#
# This file is the single owner of that version number and of the comparison
# against it. bin/fm-bootstrap.sh turns a failing check into the operator-facing
# MISSING diagnostic, which is what keeps an older build from reaching a
# dispatch intake at all.
#
# Two entry points, because a caller that has already read `quota-axi --version`
# for its own output must not pay for a second invocation to learn whether that
# same string clears the floor:
#   fm_quota_axi_version_at_least <version-output>  compare a string, no exec.
#   fm_quota_axi_compatible [timeout]               read the version, then compare.

FM_QUOTA_AXI_MIN=0.1.29

# 0 when the version in $1 is at or above FM_QUOTA_AXI_MIN. Pure: it runs
# nothing, so a caller holding a captured `--version` string pays no second
# invocation, and the parse rule below has exactly one owner.
fm_quota_axi_version_at_least() {  # <version-output>
  local output=${1:-} parts major minor patch extra
  local min_major min_minor min_patch min_extra
  parts=$(printf '%s\n' "$output" |
    sed -n 's/.*\([0-9][0-9]*\)\.\([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1 \2 \3/p' |
    head -1)
  IFS=' ' read -r major minor patch extra <<< "$parts"
  # An unparseable version is incompatible, never assumed current, so a
  # development or vendored build cannot pass a floor it was never checked against.
  [ -n "$major" ] && [ -n "$minor" ] && [ -n "$patch" ] && [ -z "$extra" ] || return 1
  # The floor is compared from FM_QUOTA_AXI_MIN so bumping it needs one edit.
  IFS='.' read -r min_major min_minor min_patch min_extra <<< "$FM_QUOTA_AXI_MIN"
  [ -n "$min_major" ] && [ -n "$min_minor" ] && [ -n "$min_patch" ] && [ -z "$min_extra" ] || return 1
  [ "$major" -gt "$min_major" ] && return 0
  [ "$major" -eq "$min_major" ] || return 1
  [ "$minor" -gt "$min_minor" ] && return 0
  [ "$minor" -eq "$min_minor" ] || return 1
  [ "$patch" -ge "$min_patch" ]
}

# 0 when the INSTALLED quota-axi clears the floor. Reads the version once and
# hands the string to the comparator above.
fm_quota_axi_compatible() {  # [timeout-secs]
  local timeout=${1:-} output
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
  fm_quota_axi_version_at_least "$output"
}
