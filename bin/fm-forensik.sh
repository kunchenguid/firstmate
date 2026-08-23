#!/usr/bin/env bash
# fm-forensik.sh - tracked daily session forensics (plan v3 U1.2). The former
# scratchpad pipeline died with its session; this tool is its durable core.
#
# Usage:
#   fm-forensik.sh run [--datum YYYY-MM-DD]
#   fm-forensik.sh --help
#
# What run does:
#   1. Collects every session transcript (*.jsonl) touched on the target date
#      under the roots in FM_FORENSIK_ROOTS (colon-separated; default: the four
#      account project trees ~/.claude1..4/projects).
#   2. Deterministic extraction per transcript into extraktion.tsv:
#      path, lines, user msgs, assistant msgs, wake deliveries ("Stop hook
#      feedback"), error-marked lines, bytes.
#   3. Writes forensik.md (totals, busiest sessions) - its first line is the
#      one-line verdict the day report quotes.
#   4. Lesson CANDIDATES: with FM_FORENSIK_LESEN=1 and a model CLI available
#      (FM_FORENSIK_CLAUDE_CMD, default "claude"), one bounded reading pass
#      writes candidates; otherwise lehren-kandidaten.md records that the
#      reading pass did not run. Candidates always carry the stage marker
#      HYPOTHESE and a MAST field.
#
# Output (this header is the single owner):
#   $FM_HOME/data/tagesschluss/<datum>/extraktion.tsv, forensik.md, lehren-kandidaten.md
#
# The lesson ledger (data/forensik-2026-08/lehren-ledger.md) is NEVER written
# by this tool: a candidate ascends hypothesis -> probation -> rule only with
# an external anchor (test, CI, diff, captain verdict), curated on the
# following day (hardenings 2 and 3; judge use stays marked not-decision-capable
# until a frozen captain gold set exists).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
ROOTS="${FM_FORENSIK_ROOTS:-$HOME/.claude1/projects:$HOME/.claude2/projects:$HOME/.claude3/projects:$HOME/.claude4/projects}"

usage() { sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

cmd="${1:-}"
case "$cmd" in
  run)
    shift
    datum="$(date +%F)"
    while [ $# -gt 0 ]; do
      case "$1" in
        --datum) datum="${2:-}"; shift 2 ;;
        *) echo "error: unknown argument '$1' for run" >&2; exit 2 ;;
      esac
    done
    [[ "$datum" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { echo "error: --datum must be YYYY-MM-DD" >&2; exit 2; }
    out="$FM_HOME/data/tagesschluss/$datum"
    mkdir -p "$out"

    # 1.+2. Collect and extract deterministically.
    tsv="$out/extraktion.tsv"
    printf 'pfad\tzeilen\tuser\tassistant\twecks\tfehler\tbytes\n' > "$tsv"
    next_day="$(date -d "$datum + 1 day" +%F)"
    found=0
    IFS=':' read -r -a root_arr <<< "$ROOTS"
    for root in "${root_arr[@]}"; do
      [ -d "$root" ] || continue
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        found=$((found + 1))
        awk -v OFS='\t' -v path="$f" '
          { lines++ }
          /"type":"user"/ { user++ }
          /"type":"assistant"/ { assistant++ }
          /Stop hook feedback/ { wecks++ }
          /"is_error":true|error:|FAILED/ { fehler++ }
          END { print path, lines+0, user+0, assistant+0, wecks+0, fehler+0 }
        ' "$f" | while IFS=$'\t' read -r p l u a w e; do
          printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$p" "$l" "$u" "$a" "$w" "$e" "$(wc -c < "$f" | tr -d ' ')"
        done >> "$tsv"
      done < <(find "$root" -name '*.jsonl' -newermt "$datum" ! -newermt "$next_day" 2>/dev/null | sort)
    done

    # 3. Report; line 1 is the verdict the day report quotes.
    total_msgs="$(awk -F'\t' 'NR>1 {s+=$3+$4} END {print s+0}' "$tsv")"
    total_wecks="$(awk -F'\t' 'NR>1 {s+=$5} END {print s+0}' "$tsv")"
    total_fehler="$(awk -F'\t' 'NR>1 {s+=$6} END {print s+0}' "$tsv")"
    {
      echo "$found sessions, $total_msgs messages, $total_wecks wake deliveries, $total_fehler error-marked lines ($datum)"
      echo
      echo "# Forensik $datum"
      echo
      echo "Extraction: $tsv"
      echo
      echo "Busiest sessions (by messages):"
      awk -F'\t' 'NR>1 {print $3+$4 "\t" $1}' "$tsv" | sort -rn | head -5 | sed 's/^/  /'
      echo
      echo "Judge status: NOT decision-capable - no frozen captain gold set yet (hardening 3)."
    } > "$out/forensik.md"

    # 4. Candidate stage (hypothesis only; the ledger is never auto-written).
    kand="$out/lehren-kandidaten.md"
    {
      echo "# Lehren-Kandidaten $datum"
      echo
      echo "STUFE: HYPOTHESE - Aufstieg nur mit externem Anker (Test, CI, Diff, Captain-Verdikt),"
      echo "Kuratierung am Folgetag; eine Lehre aus einem einzigen Tag ist meist Rauschen (Haertung 2)."
      echo
    } > "$kand"
    if [ "${FM_FORENSIK_LESEN:-}" = "1" ] && command -v "${FM_FORENSIK_CLAUDE_CMD:-claude}" >/dev/null 2>&1; then
      prompt="Read this one-day fleet extraction summary and name at most five lesson CANDIDATES (stage: hypothesis). Per candidate: one-line finding, the session path as evidence pointer, a MAST failure-mode code, and what external anchor would confirm it. Answer in English, be terse. Summary:
$(head -40 "$tsv")"
      if "${FM_FORENSIK_CLAUDE_CMD:-claude}" -p "$prompt" >> "$kand" 2>>"$out/.lesen.err"; then
        echo "reading pass: done" >> "$out/forensik.md"
      else
        echo "reading pass: FAILED (see .lesen.err)" >> "$out/forensik.md"
        echo "(Lese-Durchgang fehlgeschlagen - nur deterministische Extraktion vorhanden.)" >> "$kand"
      fi
    else
      echo "(Lese-Durchgang nicht gefahren: FM_FORENSIK_LESEN unset oder Modell-CLI fehlt - nur deterministische Extraktion.)" >> "$kand"
    fi
    echo "forensik done: $out/forensik.md"
    ;;
  --help|-h|help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
