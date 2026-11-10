#!/usr/bin/env bash
# ak47/status.sh - render the budget board: one screen, five seconds to read.
#
# Reads ak47/budget.conf, samples every metric, and writes
# ~/.local/state/ak47/status.md with each metric against its ceiling and the
# one-line reason that ceiling is that number. A breach is marked BREACH and
# repeated at the top, so the first line of the file is the answer.
#
# This is the "is the box humming" surface. It never acts: tick.sh acts.
#
# Usage: status.sh [--print] [--no-write]
#   --print     also write the board to stdout
#   --no-write  do not touch status.md (a read-only look)
# Exit: 0 always when the board was rendered; 2 on a malformed budget table.
set -u

AK47_ROOT=${AK47_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)}
# shellcheck source=lib/common.sh
. "$AK47_ROOT/lib/common.sh"

PRINT=0; WRITE=1
for a in "$@"; do
  case "$a" in
    --print) PRINT=1 ;;
    --no-write) WRITE=0 ;;
    *) echo "status.sh: usage: $0 [--print] [--no-write]" >&2; exit 2 ;;
  esac
done

rows=$(ak47_budget_rows) || exit 2
[ -n "$rows" ] || { echo "status.sh: budget table is empty" >&2; exit 2; }

now=$(ak47_now)
et=$(TZ=America/New_York date '+%-I:%M %p ET')
out=$(mktemp) || exit 1
trap 'rm -f "$out"' EXIT

breaches=0
: >"$out"

# First pass: sample and classify, so the verdict line can lead the file.
detail=$(mktemp) || exit 1
trap 'rm -f "$out" "$detail"' EXIT
while IFS=$'\t' read -r key ceil dir _unit reason; do
  val=$(ak47_metric "$key" 2>/dev/null) || val=""
  if [ -z "$val" ]; then
    printf '%-14s %-10s %-10s %-6s %s\n' "$key" "?" "$ceil" "?" "could not sample" >>"$detail"
    continue
  fi
  if ak47_breach "$val" "$ceil" "$dir"; then
    mark="BREACH"; breaches=$((breaches + 1))
  else
    mark="ok"
  fi
  cmp="<="; [ "$dir" = min ] && cmp=">="
  printf '%-14s %-10s %-10s %-6s %s\n' "$key" "$val" "$cmp $ceil" "$mark" "$reason" >>"$detail"
done <<<"$rows"

# The verdict is the first line of the file, not the title. The board exists to
# be read in five seconds, and the five-second question is "is the box fine".
if [ "$breaches" -eq 0 ]; then
  echo "VERDICT: humming - every ceiling holds." >>"$out"
else
  echo "VERDICT: $breaches ceiling(s) breached - see the BREACH rows below." >>"$out"
fi
echo "# ak47 budget - $et ($now)" >>"$out"
echo >>"$out"
{
  printf '%-14s %-10s %-10s %-6s %s\n' METRIC NOW CEILING STATE REASON
  printf '%-14s %-10s %-10s %-6s %s\n' ------ --- ------- ----- ------
  cat "$detail"
} >>"$out"

# The last action the tick took, and the last finding it could not settle.
echo >>"$out"
if [ -r "$AK47_STATE/reap.log" ]; then
  echo "## last action" >>"$out"
  tail -n 3 "$AK47_STATE/reap.log" | sed 's/^/  /' >>"$out"
else
  echo "## last action" >>"$out"
  echo "  none recorded yet" >>"$out"
fi
echo >>"$out"
if [ -r "$AK47_STATE/findings.log" ]; then
  echo "## open findings (the table cannot settle these)" >>"$out"
  tail -n 5 "$AK47_STATE/findings.log" | sed 's/^/  /' >>"$out"
else
  echo "## open findings (the table cannot settle these)" >>"$out"
  echo "  none" >>"$out"
fi
echo >>"$out"
if [ -r "$AK47_STATE/devops.log" ]; then
  last=$(tail -n 1 "$AK47_STATE/devops.log" | cut -d' ' -f1)
  age=$(( $(ak47_epoch) - $(date -u -d "$last" +%s 2>/dev/null || echo 0) ))
  echo "## loop" >>"$out"
  echo "  last tick ${age}s ago ($last); log $AK47_STATE/devops.log" >>"$out"
else
  echo "## loop" >>"$out"
  echo "  no tick has run yet; log $AK47_STATE/devops.log" >>"$out"
fi

if [ "$WRITE" = 1 ]; then
  tmp=$(mktemp "${AK47_STATE}/.status.XXXXXX") || exit 1
  cat "$out" >"$tmp" && mv -f "$tmp" "$AK47_STATE/status.md" || { rm -f "$tmp"; exit 1; }
fi
[ "$PRINT" = 1 ] && cat "$out"
exit 0
