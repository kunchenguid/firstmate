#!/usr/bin/env bash
# fm-sense-lib.sh - what supervision SENSES, split out from the loop that acts on it.
#
# bin/fm-watch.sh is a loop, a singleton lock, a coalescing window, an
# exponential backoff and a durable wake queue. None of that changes when the
# crew moves to a new multiplexer; only the SENSING does. So the sensing lives
# here, where it can be sourced and unit-tested without starting a watcher (the
# watcher's `while :;` runs at source time, which is why these cannot live in
# fm-watch.sh itself).
#
# Two senses live here, and they answer two different questions:
#
#   1. IS THE AGENT STOPPED?  Under tmux that was inferred from rendered text -
#      capture the pane, hash it, and call two identical hashes with no busy
#      footer "stale". herdr does not need the inference: `herdr api snapshot`
#      returns every agent's LIFECYCLE STATE in ONE call, so the answer is read
#      rather than guessed, and the read is O(1) at any fleet width.
#
#      `agent_status: unknown` is the herdr-side equivalent of "stopped without
#      reporting", and it is the ONLY value that means it. `idle` and `done` do
#      NOT: an agent that finished its turn is idle, an agent waiting on a
#      verdict is idle, and an agent whose turn ended while its own background
#      shells keep running is idle. Treating those as stale is exactly the
#      defect that produced four false "stalled" reports to the captain across
#      2026-08-28..31. A pane ABSENT from the snapshot is not sensed here at
#      all - that is orphan detection, which is deliberately out of scope.
#
#   2. IS IT WAITING ON US?  A crewmate that appended `done:` has reported; a
#      supervisor that then calls it "stopped without reporting" is describing
#      its own bookkeeping, not the crewmate. fm_sense_awaiting_verdict is the
#      state supervision was missing: the claim is in, and the ball is in
#      firstmate's court (a verify cycle is running, the verdict was approved,
#      or it escalated / hit the attempt cap and the captain owns it). The one
#      case that is NOT awaiting is a `reject:` - the findings were relayed and
#      the crewmate is expected to be working, so an idle pane there is a real
#      signal and must still wake.
#
# Source this; do not execute it.

# The herdr surface owns session resolution, and this file must go through it
# rather than call the binary bare. Every herdr verb takes its session from
# $HERDR_SESSION and defaults to `default`, and FM_HERDR_SESSION only reaches
# them because fm_herdr_session EXPORTS it - so a watcher that called
# `herdr api snapshot` without this would poll `default` while the captain's
# fleet ran under a pinned name, find none of its own panes in the answer, and
# go silently blind on exactly the crewmates it was migrated to watch.
# shellcheck source=bin/fm-herdr.sh disable=SC1091  # sibling lib sourced at runtime; not a shellcheck input
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-herdr.sh"

# --- the herdr sense --------------------------------------------------------

# ONE call per poll cycle, whatever the fleet width. Prints "<pane_id>\t<status>"
# per agent; non-zero (and prints nothing) when no answer could be obtained.
#
# WHY PYTHON AND NOT sed. An agent record carries terminal_title - the crewmate's
# own prompt text, rendered. A line-oriented extractor over that JSON lets a
# crewmate whose title happens to contain `"agent_status":"unknown"` forge a
# stale wake against another pane. The title is untrusted content; a real parser
# is the only honest way to read a field out from beside it. python3 is already
# a dependency of this subsystem (fm-ctx-statusline.sh, fm-captain-bootstrap.sh).
#
# It FAILS CLOSED: an unreachable herdr, a malformed snapshot or a missing
# python3 yields no rows, so no stale wake is raised for a herdr pane. The
# alternative - guessing - is how a supervisor reports a crewmate wedged that
# is not. The gap is named once on stderr rather than every poll.
fm_sense_herdr_warned=0
fm_sense_herdr_statuses() {
  local snap
  command -v herdr >/dev/null 2>&1 || return 1
  if ! command -v python3 >/dev/null 2>&1; then
    if [ "$fm_sense_herdr_warned" = 0 ]; then
      fm_sense_herdr_warned=1
      echo "fm-sense: python3 is missing, so herdr agent state cannot be read; stale detection is blind for herdr panes" >&2
    fi
    return 1
  fi
  # Re-resolve the pin on every read rather than trusting the export that ran at
  # source time: a watcher is long-lived, and this is the one call whose answer
  # is silently EMPTY - not an error - when it is aimed at the wrong session.
  fm_herdr_session >/dev/null
  snap=$(herdr api snapshot 2>/dev/null) || return 1
  [ -n "$snap" ] || return 1
  printf '%s' "$snap" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
snap = (d.get("result") or {}).get("snapshot") or {}
for a in snap.get("agents") or []:
    if not isinstance(a, dict):
        continue
    pane = a.get("pane_id") or ""
    st = a.get("agent_status") or ""
    if pane and st:
        sys.stdout.write("%s\t%s\n" % (pane, st))
' 2>/dev/null || return 1
}

# Look one pane up in a table produced by fm_sense_herdr_statuses. Prints the
# status, or nothing when the pane carries no agent herdr knows about.
fm_sense_herdr_status() {  # <pane-id> <table>
  printf '%s\n' "$2" | awk -F'\t' -v p="$1" '$1 == p { print $2; exit }'
}

# The one place that decides what "stopped without reporting" means on herdr.
fm_sense_herdr_is_stopped() {  # <agent_status>
  [ "$1" = unknown ]
}

# --- the awaiting-verdict sense ---------------------------------------------

# The kind of the last status line a task reported ("done", "working", ...), or
# nothing when it has never reported.
fm_sense_status_kind() {  # <state-dir> <id>
  local f=$1/$2.status line
  [ -f "$f" ] || return 1
  line=$(grep -v '^[[:space:]]*$' "$f" | tail -1) || return 1
  [ -n "$line" ] || return 1
  case "$line" in
    *:*) printf '%s' "${line%%:*}" ;;
    *) return 1 ;;
  esac
}

# A verify cycle is in flight. bin/fm-verify.sh writes the marker at entry and
# removes it on exit, so this is a fact rather than an inference - but a
# verifier that was killed outright would leave one behind, so it also ages out.
# The TTL is generous because a verify legitimately runs for many minutes.
fm_sense_verify_running() {  # <state-dir> <id>
  local m=$1/$2.verifying ttl=${FM_VERIFY_RUNNING_TTL:-3600} mt now
  [ -e "$m" ] || return 1
  if [ "$(uname)" = Darwin ]; then mt=$(stat -f %m "$m" 2>/dev/null); else mt=$(stat -c %Y "$m" 2>/dev/null); fi
  [ -n "$mt" ] || return 0
  now=$(date +%s)
  [ "$(( now - mt ))" -lt "$ttl" ]
}

# The missing supervision state. See the header: a completion claim whose ball
# is in firstmate's or the captain's court is awaiting a verdict, not wedged.
#
# It is deliberately NOT "the task reported anything at all": a `reject:` puts
# the ball back in the crewmate's court, and an idle pane there is the very
# signal stale detection exists to raise.
fm_sense_awaiting_verdict() {  # <state-dir> <id>
  local state=$1 id=$2 last max
  [ "$(fm_sense_status_kind "$state" "$id" || true)" = "done" ] || return 1
  fm_sense_verify_running "$state" "$id" && return 0
  # The verdict grammar has one owner; ask it rather than re-reading the file.
  if ! command -v fm_verdict_last >/dev/null 2>&1; then
    # shellcheck source=bin/fm-verdict-lib.sh disable=SC1091
    . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-verdict-lib.sh"
  fi
  last=$(fm_verdict_last "$state" "$id" 2>/dev/null) || last=none
  case "$last" in
    approve|escalate) return 0 ;;
  esac
  max=${FM_VERIFY_MAX_ATTEMPTS:-3}
  [ "$(fm_verdict_reject_count "$state" "$id")" -ge "$max" ]
}
