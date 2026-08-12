#!/usr/bin/env bash
# Shared sourced contract for website deployment completion evidence.
# fm-brief.sh and fm-promote.sh write the canonical block into a ship brief's
# Definition-of-done section, and fm-spawn.sh validates it there before launch.

# The canonical gate lines a web ship brief carries directly under its surface
# declaration. Sole owner of the accepted web completion evidence.
fm_web_gate_text() {
  cat <<'EOF'
Web gate contract: custom-domain/chrome-devtools-axi/revision-marker/screenshot
## Website deployment completion gate
This is a website or web-deployment ship task, so the task is not complete until firstmate can accept all of the following evidence together:
- Verify the deployed revision against the real custom production domain, never only on a preview or staging URL.
- Perform a fresh-browser visual verification against the real custom production domain with the existing chrome-devtools-axi tool: start a fresh browser session, run `chrome-devtools-axi open <custom-production-domain>`, render the page, and inspect the actual result, not a headless or CDP shortcut.
- Confirm that the rendered page visibly contains concrete distinguishing revision content - a marker introduced by this change - and record the exact marker checked.
- Exercise a concrete interaction on the deployed custom-domain page and record the observed result from that deployed site.
- Capture screenshot evidence of that verified custom-domain page with `chrome-devtools-axi screenshot`, and preserve the screenshot as durable task or PR evidence.
- Explicitly record the custom production URL, marker, and screenshot evidence before reporting done.
HTTP 200, a preview URL, or bare reachability alone is explicitly rejected as insufficient acceptance evidence.
Do not append a done status or claim completion when any visual, marker, custom-domain, or screenshot evidence is missing.
EOF
}

# The whole operative declaration for a surface, written and validated as one unit.
fm_web_gate_block() {  # <web|non-web>
  printf 'Surface contract: %s\n' "$1"
  [ "$1" = web ] && fm_web_gate_text
  return 0
}

# One fence-aware structural pass over a ship brief's operative Definition-of-done
# section. Fenced lines and every line outside that section are ignored, so a
# marker quoted in the task description or inside a code fence never satisfies the
# gate and a whole-file match can no longer stand in for operative placement.
#   check            prints the operative surface; fails when the brief has no
#                    single unfenced "# Definition of done" heading, no single
#                    operative "Surface contract:" line, an unknown surface, or a
#                    web declaration not followed by the canonical gate lines.
#   insert:<surface> reprints the brief with that canonical block added at the
#                    operative boundary.
fm_web_gate_scan() {  # <check|insert:web|insert:non-web> <brief>
  awk -v mode="$1" '
    function parse_fence(line,   i,c,n) {
      candidate_char = ""
      candidate_len = 0
      candidate_rest = ""
      i = 1
      while (i <= length(line) && i <= 4 && substr(line, i, 1) == " ") i++
      if (i > 4) return 0
      c = substr(line, i, 1)
      if (c != "`" && c != "~") return 0
      n = 0
      while (substr(line, i + n, 1) == c) n++
      if (n < 3) return 0
      candidate_char = c
      candidate_len = n
      candidate_rest = substr(line, i + n)
      return 1
    }
    NR == FNR { gate[++gn] = $0; next }
    {
      raw[++ln] = $0
      if (parse_fence($0)) {
        fenced[ln] = 1
        if (!fence) {
          fence = 1
          fence_char = candidate_char
          fence_len = candidate_len
        } else if (candidate_char == fence_char && candidate_len >= fence_len && candidate_rest ~ /^[ \t]*$/) {
          fence = 0
          fence_char = ""
          fence_len = 0
        }
        next
      }
      fenced[ln] = fence
      if (fence) next
      if ($0 == "# Definition of done") { dod = ln; dods++ }
      else if (dod && !stop && $0 ~ /^# /) stop = ln
    }
    END {
      if (dods != 1) exit 1
      if (mode ~ /^insert:/) {
        surface = substr(mode, 8)
        for (i = 1; i <= ln; i++) {
          print raw[i]
          if (i != dod) continue
          print "Surface contract: " surface
          if (surface == "web") for (j = 1; j <= gn; j++) print gate[j]
        }
        exit 0
      }
      if (!stop) stop = ln + 1
      for (i = dod + 1; i < stop; i++) if (!fenced[i]) operative[++n] = raw[i]
      for (i = 1; i <= n; i++)
        if (operative[i] ~ /^Surface contract: /) {
          declarations++
          at = i
          surface = substr(operative[i], 19)
        }
      if (declarations != 1) exit 1
      if (surface != "web" && surface != "non-web") exit 1
      if (surface == "web")
        for (j = 1; j <= gn; j++) if (operative[at + j] != gate[j]) exit 1
      print surface
    }
  ' <(fm_web_gate_text) "$2"
}
