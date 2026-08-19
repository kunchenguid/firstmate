#!/usr/bin/env bash
# ONE owner of "how many context tokens is this primary session carrying?".
#
# No turn-end hook payload on any harness carries a token count, so the number
# comes from the transcript the payload points at. Two rules bind every caller:
# read transcript_path from the PAYLOAD and never derive it from $HOME (a
# non-default Claude config dir puts the transcript where $HOME cannot predict),
# and measure with fm_context_measure_transcript rather than a private formula.
#
# THE FORMULA: the total is input_tokens + cache_creation_input_tokens +
# cache_read_input_tokens + output_tokens on the LAST non-sidechain
# type=="assistant" entry. That reproduces Claude Code's own accounting;
# docs/verification/session-handover.md records the cross-check.
#
# Three correctness rules the measurement must keep:
#   1. Dedupe a multi-block turn by requestId. Several JSONL lines share one
#      turn's usage; summing them would multiply the real total.
#   2. Take LAST, never max. Compaction RESETS the running total, so a max
#      implementation would latch the pre-compaction peak and never fall back
#      below a threshold again.
#   3. Exclude sidechains. isSidechain==true marks subagent turns, which must
#      never inflate the primary's measurement.
#
# HISTORY, and why this file exists rather than a second copy: the parked branch
# feat/context-budget-guardrail carries this exact formula inline in
# bin/fm-context-budget.sh at 9bedde8. That branch is unlanded and holds its own
# open decisions, so this file lifts the formula verbatim instead of duplicating
# or reinventing it. When that branch resumes it must source this lib and delete
# its inline copy, so the two converge on one owner rather than drifting.
#
# This file is sourced by scripts and has no side effects on source.

# fm_context_payload_transcript <payload>: print the transcript path a turn-end
# payload points at. Non-zero when the payload carries none, is unparseable, or
# the path is not a readable regular file. jq is the repo's established JSON
# dependency; its absence is an ordinary unmeasurable, never an error.
fm_context_payload_transcript() {
  local payload=$1 path
  [ -n "$payload" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  path=$(printf '%s' "$payload" | jq -r '.transcript_path // empty' 2>/dev/null) || return 1
  [ -n "$path" ] || return 1
  [ -f "$path" ] && [ -r "$path" ] || return 1
  printf '%s\n' "$path"
}

# fm_context_measure_transcript <transcript>: print the session's context total
# in tokens. Non-zero when the total cannot be established at all - absent jq,
# missing or unreadable file, no assistant usage, or output that is not a plain
# integer - so every caller has exactly one unmeasurable case to degrade on.
#
# jq -R with fromjson? drops malformed or truncated lines instead of aborting, so
# a partially written transcript degrades to "measure what parsed" rather than to
# an error.
#
# Rule 3 (matching bin/fm-context-budget.sh's own inline guard): Claude Code
# writes a synthetic all-zero-usage assistant entry whenever a turn ends
# abnormally. A real session never measures 0, so a 0 usage total is a missing
# measurement, not a valid reading - candidates with total 0 are excluded before
# the LAST/dedupe step, so a trailing synthetic entry cannot mask the last real
# total or be reported as a false 0.
fm_context_measure_transcript() {
  local transcript=$1 total
  [ -n "$transcript" ] || return 1
  [ -f "$transcript" ] && [ -r "$transcript" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  total=$(jq -R 'fromjson? // empty' "$transcript" 2>/dev/null | jq -s '
    def usage_total:
      (.input_tokens // 0) + (.cache_creation_input_tokens // 0)
      + (.cache_read_input_tokens // 0) + (.output_tokens // 0);
    [ .[]
      | select((.isSidechain != true)
        and (.type == "assistant")
        and ((.message.usage | type) == "object")
        and ((.message.usage | usage_total) > 0)) ]
    | if length == 0 then empty
      else
        # LAST, never max: compaction resets the running total.
        (.[-1].requestId) as $rid
        # Dedupe a multi-block turn: one requestId is one turn, so take the
        # final usage object of that turn rather than summing its blocks.
        | [ .[] | select($rid == null or .requestId == $rid) ][-1]
        | .message.usage
        | usage_total
        | floor
      end
  ' 2>/dev/null) || return 1
  case "$total" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$total"
}
