#!/usr/bin/env bash
# fm-progress-lib.sh - the ONE owner of firstmate's observable-progress
# contract: which numbers a harness renders are PROGRESS, and which are mere
# animation.
#
# Why this distinction has to exist. A busy verdict (bin/fm-busy-lib.sh) says a
# turn is in flight; it does not say the turn is advancing. A hung foreground
# call keeps the semantic busy record open and keeps the harness repainting its
# footer, so the pane looks alive from every angle the watcher had: the busy
# verdict stays busy, and the whole-pane hash keeps CHANGING because the footer
# carries an elapsed-time clock. Hashing the pane therefore reports motion where
# there is no progress, which is exactly backwards.
#
# The counters are the ground truth. A harness that renders token, cost, or
# context counters moves them only when the model actually consumes or produces
# something. Two readings of those counters spaced far apart separate a worker
# that is advancing from one that is frozen; nothing else rendered in the pane
# does. That is the manual diagnostic this library automates.
#
# Deliberately NOT counted as progress:
#   - elapsed-time clocks ("16s", "(3600.1s)", "1m 30s", "0:12") and spinner
#     frames: they advance while nothing happens, which is the whole failure
#     mode. Every pattern below is anchored on a non-time marker (an up/down
#     arrow, the word "tokens", a currency sign, or a percentage on a line that
#     names the context window), so a bare duration can never match one.
#   - anything not rendered in the footer region: displayed CONTENT can contain
#     token-shaped or cost-shaped text, so the scan is limited to the last
#     FM_PROGRESS_FOOTER_LINES non-blank lines. Six is the footer size this repo
#     already settled on for exactly this contamination risk - see the busy-match
#     comment in bin/fm-watch.sh and the acknowledgement scan in
#     bin/fm-pending-reply-lib.sh, both of which read the last 6 non-blank lines
#     so that lookalike strings in displayed content cannot drive a verdict.
#     Every rendered footer this repo has recorded is a single status line at the
#     bottom, so a wider window buys nothing and only admits more transcript.
#
# Absence of counters is a REPORTED fact, not a verdict. A harness that renders
# no counters at all (Codex's "• Working (6s • esc to interrupt)" is the
# recorded example) yields no tokens and a non-zero return; callers must say so
# and fall back to a measure they can honestly take, never invent a reading.
#
# This library is pure text: no state, no filesystem, no harness calls, so its
# behavior is fully pinned by tests/fm-progress-lib.test.sh. The per-harness
# question it CANNOT answer alone - does this release still render these
# counters - is a rendered-surface fact only a real harness can prove, and
# tests/fm-busy-progress-drift-live-e2e.test.sh is the guard that proves it.

# Footer region scanned for counters, in non-blank lines from the end.
FM_PROGRESS_FOOTER_LINES=${FM_PROGRESS_FOOTER_LINES:-6}
case "$FM_PROGRESS_FOOTER_LINES" in ''|*[!0-9]*|0) FM_PROGRESS_FOOTER_LINES=6 ;; esac

_FM_PROGRESS_ARROW_UP=$'\xE2\x86\x91'
_FM_PROGRESS_ARROW_DOWN=$'\xE2\x86\x93'

# fm_progress_counters: print every progress counter found in a rendered tail as
# a normalized "<kind>=<value>" token, one per line, sorted and de-duplicated so
# the output is a stable fingerprint of "how far along is this worker".
# Reads <text> when given, else stdin. Returns 1 when the tail renders no
# progress counter at all - the caller's cue that this harness gives no sharp
# measure here and must say so rather than guess.
# fm_progress_advanced: 0 iff two readings from fm_progress_counters show the
# same counter KIND at a strictly higher value in the later one - the one shape
# of change that only a real meter produces.
#
# "Changed" is too weak to be evidence, because the reading is taken over a live
# pane's footer region and the transcript scrolls through it: a counter-free
# harness whose displayed content says "we used 4321 tokens" on one poll and
# something else on the next renders a DIFFERENT counter-shaped string each
# time, which is motion without progress and exactly what this library exists to
# separate. A meter, by contrast, accumulates: tokens, spend and context filled
# only ever rise within a turn. So a kind that appears in one reading and not
# the other proves nothing, a value that falls proves nothing, and a compound
# value (the used/total context ratio) is not compared at all; only a rise does.
# Values carry the k/M suffixes harnesses render, which are normalized here so
# "1.1k" and "1100" compare as the same number.
fm_progress_advanced() {  # <previous-reading> <current-reading>
  [ -n "${1:-}" ] && [ -n "${2:-}" ] || return 1
  awk -v prev="$1" -v cur="$2" '
    function num(v,   mult) {
      mult = 1
      if (v ~ /[kK]$/) { mult = 1000; v = substr(v, 1, length(v) - 1) }
      else if (v ~ /[mM]$/) { mult = 1000000; v = substr(v, 1, length(v) - 1) }
      if (v !~ /^[0-9]+(\.[0-9]+)?$/) return -1
      return v * mult
    }
    function load(s, arr,   i, n, parts, k, v, x) {
      n = split(s, parts, /[[:space:]]+/)
      for (i = 1; i <= n; i++) {
        x = index(parts[i], "=")
        if (x < 2) continue
        k = substr(parts[i], 1, x - 1)
        v = num(substr(parts[i], x + 1))
        if (v < 0) continue
        if (!(k in arr) || v > arr[k]) arr[k] = v
      }
    }
    BEGIN {
      load(prev, a); load(cur, b)
      for (k in b) if (k in a && b[k] > a[k]) exit 0
      exit 1
    }
  '
}

fm_progress_counters() {  # [<text>]
  local text out
  if [ "$#" -gt 0 ]; then text=$1; else text=$(cat); fi
  out=$(printf '%s\n' "$text" \
    | grep -v '^[[:space:]]*$' \
    | tail -"$FM_PROGRESS_FOOTER_LINES" \
    | awk -v up="$_FM_PROGRESS_ARROW_UP" -v down="$_FM_PROGRESS_ARROW_DOWN" '
      # The first number inside a matched span is always the counter value,
      # because every pattern anchors on the marker beside it.
      function numpart(m,   p) {
        if (match(m, /[0-9]+(\.[0-9]+)?[kKmM]?/)) {
          p = substr(m, RSTART, RLENGTH)
          return tolower(p)
        }
        return ""
      }
      # Emit <kind>=<first number> for every occurrence of <re> on <line>.
      # The span bounds are saved BEFORE numpart runs: its own match() resets
      # RSTART/RLENGTH, and advancing the loop on those clobbered values walks
      # back into the middle of the span and re-reads a suffix of the same
      # number as a second, fictitious counter.
      function scan(line, re, kind,   rest, m, v, s, l) {
        rest = line
        while (match(rest, re)) {
          s = RSTART; l = RLENGTH
          m = substr(rest, s, l)
          v = numpart(m)
          if (v != "") print kind "=" v
          rest = substr(rest, s + l)
        }
      }
      # Emit <kind>=<whole match, whitespace stripped>, for compound values
      # (a used/total context ratio) whose meaning needs both numbers.
      function scanraw(line, re, kind,   rest, m, s, l) {
        rest = line
        while (match(rest, re)) {
          s = RSTART; l = RLENGTH
          m = substr(rest, s, l)
          gsub(/[[:space:]]+/, "", m)
          print kind "=" tolower(m)
          rest = substr(rest, s + l)
        }
      }
      {
        line = $0
        lower = tolower(line)
        num = "[0-9]+(\\.[0-9]+)?[kKmM]?"
        # Up/down token meters, the most common live-progress rendering.
        scan(line, up "[[:space:]]*" num, "tok:up")
        scan(line, down "[[:space:]]*" num, "tok:down")
        # A word-anchored token count, with or without an arrow beside it.
        scan(line, num "[[:space:]]*tokens?", "tok:n")
        # Spend meters. Anchored on the currency sign, never a bare number.
        scan(line, "\\$[0-9]+(\\.[0-9]+)?", "cost")
        # Context meters count only on a line that names the context window, so
        # an unrelated percentage (a build or download meter in displayed
        # content) cannot be read as model progress.
        if (index(lower, "context") > 0) {
          scan(line, num "[[:space:]]*%", "ctx:pct")
          scanraw(line, num "[[:space:]]*/[[:space:]]*" num, "ctx:ratio")
        }
      }
    ' | LC_ALL=C sort -u)
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}
