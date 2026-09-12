# shellcheck shell=bash
# Lane size measurement and its verdicts. ONE owner for the thresholds, so the
# brief scaffold, the worker's own pre-run check, and the telemetry row cannot
# drift apart.
#
# The numbers are not arbitrary. Over 2026-08-29 to 09-05 portfolio-tracker's
# MEDIAN merged PR was 1,026 changed lines, 71% were over 400 and 55% over
# 800, and its pipeline averaged 9.6 review rounds per run against 6.7 for a
# project whose median PR was 491 lines. Big diffs need more rounds to
# converge, and rounds are 40% of the fleet's tokens.
#
# 400 is the target a lane is SHAPED toward. 800 is where a worker stops and
# asks firstmate to split rather than pushing on. Neither is a refusal: a
# refusal in the middle of a worker's turn strands the work.

FM_DIFF_TARGET_LINES=400
FM_DIFF_CAP_LINES=800

# fm_diff_size <worktree> <base-ref>: print "<changed_lines> <files_changed>".
# Always exits 0 and always prints two integers: a measurement that can fail is
# a measurement nobody wires in.
fm_diff_size() {  # <worktree> <base-ref>
    local wt=$1 base=$2 stat added removed files
    if [ ! -d "$wt" ]; then printf '0 0\n'; return 0; fi
    stat=$(git -C "$wt" diff --numstat "$base"...HEAD 2>/dev/null) || {
        printf '0 0\n'; return 0; }
    added=0; removed=0; files=0
    while IFS=$'\t' read -r a r _path; do
        [ -n "${_path:-}" ] || continue
        case "$a" in ''|*[!0-9]*) a=0 ;; esac
        case "$r" in ''|*[!0-9]*) r=0 ;; esac
        added=$((added + a)); removed=$((removed + r)); files=$((files + 1))
    done <<< "$stat"
    printf '%s %s\n' "$((added + removed))" "$files"
    return 0
}

# fm_diff_size_verdict <changed_lines>: print ok | over-target | over-cap.
fm_diff_size_verdict() {  # <changed_lines>
    local lines=${1:-0}
    case "$lines" in ''|*[!0-9]*) lines=0 ;; esac
    if [ "$lines" -gt "$FM_DIFF_CAP_LINES" ]; then printf 'over-cap\n'
    elif [ "$lines" -gt "$FM_DIFF_TARGET_LINES" ]; then printf 'over-target\n'
    else printf 'ok\n'
    fi
    return 0
}
