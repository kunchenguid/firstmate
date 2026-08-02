#!/usr/bin/env bash
# fm-harness-drift.sh - detect-only drift between the harness build stamps
# recorded in .agents/skills/harness-adapters/SKILL.md and the harness binaries
# installed on this machine.
#
# Every harness fact in that skill was established by one manual observation
# against one build. Nothing used to compare those stamps to the installed
# runtimes, so a fact stopped describing reality the moment a harness updated
# and no signal fired. This check is that signal.
#
# Usage:
#   fm-harness-drift.sh           print one line per drifted or absent harness;
#                                 silent when every stamp matches; always exit 0
#   fm-harness-drift.sh --stamps  print the parsed "<harness> <version>" stamps
#   fm-harness-drift.sh --help    print this usage
#
# Lines (the stamp source owns which harnesses appear):
#   "HARNESS_DRIFT: <harness> recorded <stamp>, installed <version>"
#   "HARNESS_DRIFT: <harness> recorded <stamp>, not installed here"
#   "HARNESS_DRIFT: <harness> recorded <stamp>, installed build unreadable"
#   "HARNESS_DRIFT: recorded build stamps unreadable in <path>"
#
# Three outcomes are distinguished per harness: the stamp equals the installed
# build (silent), the stamp differs from the installed build (drift, in EITHER
# direction - a stamp ahead of the installed build describes a build nobody is
# running just as much as one behind it), and the harness is absent (drift).
#
# It is detect-only by construction: it never edits the skill, never installs
# anything, and always exits 0 so a drifted fleet still starts. Drift is normal
# and expected; the defect this fixes is drift being invisible, not drift
# existing. Do not turn it into a gate.
#
# Test overrides: FM_HARNESS_DRIFT_SKILL selects the stamp source file, and
# FM_HARNESS_DRIFT_TIMEOUT (default 10) bounds each `<harness> --version` probe.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_CODE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# The stamps live with the tracked skill, which always ships from the code root,
# never from a per-home FM_HOME.
SKILL="${FM_HARNESS_DRIFT_SKILL:-$FM_CODE_ROOT/.agents/skills/harness-adapters/SKILL.md}"
PROBE_TIMEOUT="${FM_HARNESS_DRIFT_TIMEOUT:-10}"
case "$PROBE_TIMEOUT" in ''|*[!0-9]*) PROBE_TIMEOUT=10 ;; esac

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

# Bounded probe with the same portable ladder fm-fleet-snapshot.sh uses. When no
# bounding tool exists at all, run the probe directly rather than reporting every
# harness unreadable: a false drift storm on every run is worse than an
# unbounded `--version` call on a host with no timeout, gtimeout, or perl.
run_timed() {  # <seconds> <command...>
  local seconds=$1
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$seconds" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$seconds" "$@"
  elif command -v perl >/dev/null 2>&1; then
    perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$seconds" "$@"
  else
    "$@"
  fi
}

# Read the fenced ```fm-harness-builds block. A unique info string keeps this
# unambiguous next to the skill's many ordinary Markdown tables and fences.
read_stamps() {
  [ -f "$SKILL" ] || return 0
  awk '
    /^```fm-harness-builds[[:space:]]*$/ { inblock = 1; next }
    inblock && /^```/ { exit }
    inblock { print }
  ' "$SKILL"
}

# First dotted version-looking token of a `--version` line. Covers every verified
# harness shape: "2.1.220 (Claude Code)", "codex-cli 0.145.0", "1.18.3", and
# "grok 0.2.112 (9bbd559437aa) [stable]".
installed_version() {  # <harness>
  local out
  out=$(run_timed "$PROBE_TIMEOUT" "$1" --version 2>/dev/null) || return 1
  printf '%s\n' "$out" | grep -Eo '[0-9]+\.[0-9]+(\.[0-9]+)*' | head -1
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
  --stamps)
    read_stamps
    exit 0
    ;;
  '') ;;
  *)
    echo "usage: fm-harness-drift.sh [--stamps|--help]" >&2
    exit 2
    ;;
esac

stamps=$(read_stamps)
parsed=0
malformed=0
while IFS= read -r line; do
  case "$line" in ''|'#'*) continue ;; esac
  # A blank or whitespace-only line inside the block is spacing, not a malformed
  # stamp; treating it as one would raise a false alarm on every run.
  [ -n "${line//[[:space:]]/}" ] || continue
  harness=${line%% *}
  recorded=${line#* }
  case "$harness" in *[!a-z0-9-]*|'') malformed=1; continue ;; esac
  # A line with no space leaves recorded == line, which is malformed, not a stamp.
  if [ "$recorded" = "$line" ]; then malformed=1; continue; fi
  case "$recorded" in ''|*[!0-9.]*) malformed=1; continue ;; esac
  parsed=$((parsed + 1))
  if ! command -v "$harness" >/dev/null 2>&1; then
    echo "HARNESS_DRIFT: $harness recorded $recorded, not installed here"
    continue
  fi
  if ! found=$(installed_version "$harness") || [ -z "$found" ]; then
    echo "HARNESS_DRIFT: $harness recorded $recorded, installed build unreadable"
    continue
  fi
  [ "$found" = "$recorded" ] && continue
  echo "HARNESS_DRIFT: $harness recorded $recorded, installed $found"
done <<EOF
$stamps
EOF

if [ "$parsed" -eq 0 ] || [ "$malformed" -eq 1 ]; then
  echo "HARNESS_DRIFT: recorded build stamps unreadable in $SKILL"
fi

exit 0
