#!/usr/bin/env bash
# Shared outbound-message splitting for firstmate's chat channels.
#
# This file is sourced, never executed. It owns the single splitting algorithm
# used by every channel that must fit an agent-composed reply inside a
# per-message character budget (X mode, the Telegram bridge), so the boundary
# rules, numbering, and cap behavior cannot drift between them.
#
# It defines:
#   fm_message_split_thread <limit> <cap>  - split stdin into a JSON array of
#       chunks, each at most <limit> codepoints, at most <cap> chunks
#
# The caller owns the budget: it passes the target channel's per-message limit
# and message cap, so this library stays platform-neutral. It needs jq.

# Split a reply into a numbered thread of <=<max>-codepoint chunks, packing first
# on fenced-code, paragraph, and line boundaries, then on word boundaries, and
# hard-splitting only a single over-long unit. A reply that already fits in one
# message is returned as a single UNNUMBERED chunk; longer replies get " (k/n)"
# suffixes. At most <cap> messages are produced; if the reply would need more,
# the last kept message is marked with an ellipsis. Reads the reply text on stdin
# and prints a compact JSON array of chunks. Length is codepoint-based (via jq);
# the relay remains the final authority and trims.
fm_message_split_thread() {
  jq -Rsc --argjson limit "$1" --argjson cap "$2" '
    def trim: gsub("^[[:space:]]+|[[:space:]]+$"; "");
    def fence_marker: test("^[[:space:]]*```");
    def fence_count: ((split("```") | length) - 1);
    def numbered($i; $n):
      "(\($i + 1)/\($n))" as $mark
      | if ((fence_count % 2) == 0) and (split("\n")[-1] | fence_marker)
        then . + "\n" + $mark
        else . + " " + $mark
        end;
    def hardsplit($b): . as $s | [range(0; ($s|length); $b) as $i | $s[$i:$i+$b]];
    def wordsplit($b):
      (gsub("[[:space:]]+"; " ") | trim) as $norm
      | if ($norm | length) == 0 then []
        else
          [ $norm | split(" ")[] | if (length > $b) then hardsplit($b)[] else . end ] as $words
          | (reduce $words[] as $w ({chunks: [], cur: ""};
              (if .cur == "" then $w else .cur + " " + $w end) as $cand
              | if ($cand | length) <= $b then .cur = $cand
                else .chunks += (if .cur == "" then [] else [.cur] end) | .cur = $w end
            )) as $st
          | $st.chunks + (if $st.cur != "" then [$st.cur] else [] end)
        end;
    def split_units:
      split("\n") as $lines
      | (reduce $lines[] as $line ({units: [], cur: "", fence: false};
          if .fence then
            .cur = (if .cur == "" then $line else .cur + "\n" + $line end)
            | if ($line | fence_marker) then .units += [.cur] | .cur = "" | .fence = false else . end
          elif ($line | fence_marker) then
            (if .cur != "" then .units += [.cur] | .cur = "" else . end)
            | .cur = $line
            | .fence = true
          elif ($line | test("^[[:space:]]*$")) then
            if .cur != "" then .units += [.cur] | .cur = "" else . end
          else
            ($line | trim) as $clean
            | .cur = (if .cur == "" then $clean else .cur + " " + $clean end)
          end
        )) as $st
      | ($st.units + (if $st.cur != "" then [$st.cur] else [] end))
      | map(select((trim | length) > 0));
    def pack_units($units; $b):
      (reduce $units[] as $u ({chunks: [], cur: ""};
        if ($u | length) > $b then
          (if .cur != "" then .chunks += [.cur] | .cur = "" else . end)
          | .chunks += ($u | wordsplit($b))
        else
          (if .cur == "" then $u else .cur + "\n\n" + $u end) as $cand
          | if ($cand | length) <= $b then .cur = $cand
            else .chunks += (if .cur == "" then [] else [.cur] end) | .cur = $u end
        end
      )) as $st
      | $st.chunks + (if $st.cur != "" then [$st.cur] else [] end);
    def split_thread($limit; $cap):
      trim as $norm
      | if ($norm | length) == 0 then []
        elif ($norm | length) <= $limit then [$norm]
        else
          ($cap | tostring | length) as $digits
          | (4 + 2 * $digits) as $suffixw
          | (if ($limit - $suffixw - 1) < 1 then 1 else ($limit - $suffixw - 1) end) as $budget
          | ($norm | split_units) as $units
          | pack_units($units; $budget) as $raw
          | (if ($raw | length) > $cap
              then ($raw[0:$cap] | (.[($cap - 1)] += "…"))
              else $raw end) as $kept
          | ($kept | length) as $n
          | [ range(0; $n) as $i | $kept[$i] | numbered($i; $n) ]
        end;
    split_thread($limit; $cap)
  '
}
