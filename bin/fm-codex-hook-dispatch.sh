#!/usr/bin/env bash
# Codex hook transport for firstmate's tracked `.codex/hooks.json`.
#
# Codex hook stdin has regressed in the past from "closed after payload" to an
# open stream that can leave a plain `cat` blocked until Codex kills the hook.
# This adapter reads at most one short burst with a bounded wait, then fails
# open on absent input instead of making every tool call wait for the hook timeout.
set -u

usage() {
  cat <<'EOF'
Usage: fm-codex-hook-dispatch.sh <PreToolUse|Stop> <checker-script>

Reads one Codex hook payload from stdin with a short timeout, verifies that the
tracked hook file still points at the requested checker, then forwards the
payload to bin/<checker-script>.
EOF
}

[ "$#" -eq 2 ] || { usage >&2; exit 2; }

EVENT=$1
CHECKER=$2

case "$EVENT:$CHECKER" in
  PreToolUse:fm-arm-pretool-check.sh|PreToolUse:fm-cd-pretool-check.sh|Stop:fm-turnend-guard.sh) ;;
  *) exit 0 ;;
esac

ROOT=$(pwd -P) || exit 0
[ -x "$ROOT/bin/$CHECKER" ] || exit 0
[ -f "$ROOT/AGENTS.md" ] || exit 0
[ -f "$ROOT/.codex/hooks.json" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

case "$EVENT" in
  PreToolUse)
    # shellcheck disable=SC2016 # $checker is a jq variable supplied with --arg.
    jq_expr='any(.hooks.PreToolUse[]?.hooks[]?.command?; type == "string" and contains($checker))'
    ;;
  Stop)
    # shellcheck disable=SC2016 # $checker is a jq variable supplied with --arg.
    jq_expr='any(.hooks.Stop[]?.hooks[]?.command?; type == "string" and contains($checker))'
    ;;
  *)
    exit 0
    ;;
esac

jq -e --arg checker "$CHECKER" "$jq_expr" "$ROOT/.codex/hooks.json" >/dev/null 2>&1 || exit 0
command -v perl >/dev/null 2>&1 || exit 0

PAYLOAD=$(perl -MIO::Select -e '
  my $timeout = $ENV{FM_CODEX_HOOK_READ_TIMEOUT} || 0.2;
  my $sel = IO::Select->new(\*STDIN);
  exit 0 unless $sel->can_read($timeout);
  my $buf = "";
  my $n = sysread(STDIN, $buf, 65536);
  print $buf if $n;
' 2>/dev/null || true)

[ -n "$PAYLOAD" ] || exit 0
printf '%s' "$PAYLOAD" | "$ROOT/bin/$CHECKER"
