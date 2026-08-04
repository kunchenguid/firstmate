#!/usr/bin/env bash
# Shared wake classifier: the common source of truth for captain-relevant status
# tests, declared-external-wait vocabulary, and the working/paused absorb
# classification that makes no-verb signal and stale-pane wakes safe to absorb.
# Sourced by BOTH the always-on watcher
# (bin/fm-watch.sh) and the away-mode daemon (bin/fm-supervise-daemon.sh) so the
# overlapping triage policy lives in one place instead of two copies that can
# drift apart.
#
# Most functions are pure, side-effect-free reads of status files: each takes
# what it needs as arguments and touches no globals beyond the optional
# FM_CAPTAIN_RE override. Consumers layer their own dedup/marker state on top (the
# daemon keeps its escalation-digest seen-markers; the watcher keeps its .seen-*
# signatures).
#
# The one exception is the absorb classification (crew_absorb_class and its
# working/paused wrappers). It is NOT a pure status-file read: it reuses
# bin/fm-crew-state.sh, which may make a bounded no-mistakes call, to decide
# whether a crew that just stopped its turn or went stale is working, deliberately
# paused, or neither. Callers run it ONLY on no-verb signal handling and first
# sighting of a stale hash, never on every wake, so the per-wake triage stays
# cheap.

# Directory of this library, used to locate the sibling fm-crew-state.sh reader.
# Resolved at source time from BASH_SOURCE so it works whether sourced by a
# bin/ script (which sets its own SCRIPT_DIR) or directly by a test.
_FM_CLASSIFY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _FM_CLASSIFY_LIB_DIR="."

# The crew current-state reader used for the "provably working" decision.
# Overridable so tests can stub the run-step/pane verdict without a real worktree
# or no-mistakes install; absent, it points at the real sibling script.
FM_CREW_STATE_BIN="${FM_CREW_STATE_BIN:-$_FM_CLASSIFY_LIB_DIR/fm-crew-state.sh}"

# Captain-relevant status verbs. A status line carrying any of these is work
# firstmate must see. Lines without these verbs are no-verb signals: the watcher
# absorbs them only with positive provably-working evidence, while the daemon uses
# its away-mode classification. FM_CAPTAIN_RE overrides the whole set when a home
# needs a custom verb vocabulary; absent, this default applies.
#
# Free-text tokens (PR ready, checks green, ready in branch, merged) exist only for
# legacy lines that lack a standard terminal verb. status_is_captain_relevant is
# verb-aware: a nonterminal working: or paused: line never becomes captain-relevant
# merely because its prose contains one of those tokens (for example
# "working: rebased onto merged #76").
FM_CLASSIFY_CAPTAIN_RE_DEFAULT='done:|needs-decision:|blocked:|failed:|PR ready|checks green|ready in branch|merged'

# The deliberate-external-wait verb. A crew (or firstmate steering it) appends
#   paused: <reason>
# to declare it is intentionally idling on a KNOWN external dependency - an
# upstream release, a vendor rate-limit reset, a scheduled window. Unlike
# `blocked:` (stuck, firstmate must help) an idle `paused:` pane is EXPECTED, so
# the stale path absorbs it instead of escalating a possible wedge. It is
# deliberately NOT in the captain-relevant set above: a pause is a "stop
# wedge-nagging this idle pane" signal, not work to keep surfacing. This constant
# is the ONE definition of the verb; both the watcher and the daemon read it here
# (status_is_paused) rather than hardcoding the literal, so the vocabulary cannot
# drift between the two consumers. FM_CLASSIFY_PAUSED_VERB overrides it.
FM_CLASSIFY_PAUSED_VERB_DEFAULT='paused'

# Bounded re-surface cadence for a declared pause or a dead-agent captain hold.
# Far longer than the wedge threshold (FM_STALE_ESCALATE_SECS, default 240s), it
# avoids nagging a deliberate wait while ensuring a forgotten hold cannot rot
# invisibly - it re-surfaces once for a recheck every window. One hour by default;
# both consumers read FM_PAUSE_RESURFACE_SECS with this default so the cadence has
# one owner.
# shellcheck disable=SC2034 # Read by the watcher and daemon (fm-watch.sh, fm-supervise-daemon.sh), not this lib.
FM_PAUSE_RESURFACE_SECS_DEFAULT=3600

# The resolution verb and durable-backlog-transfer verb that CLOSE a keyed
# status decision opened by needs-decision or blocked. See status_open_decisions
# below for the status-fold contract. The transfer verb is written only after
# fm-decision-hold.sh has verified the corresponding captain-held backlog item.
FM_CLASSIFY_RESOLVE_VERB_DEFAULT='resolved'
FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT='captain-held'

# Return the last non-blank line of a status file (empty if missing/blank).
last_status_line() {
  local f=$1
  [ -e "$f" ] || return 0
  grep -v '^[[:space:]]*$' "$f" 2>/dev/null | tail -1
}

# 0 if the given (last) status line's leading verb is a real terminal captain verb
# (done, needs-decision, blocked, failed). Free-text tokens alone never count here;
# callers that need legacy free-text matching use status_is_captain_relevant.
status_is_terminal_verb() {
  local line=$1 verb
  [ -n "$line" ] || return 1
  verb=$(status_line_verb "$line")
  case "$verb" in
    done|needs-decision|blocked|failed) return 0 ;;
    *) return 1 ;;
  esac
}

# 0 if the given (last) status line matches a captain-relevant verb.
# Verb-aware by default: terminal verbs always match; nonterminal progress verbs
# (working, resolved, captain-held) and paused never match from free-text prose;
# only lines without those leading verbs may still match free-text tokens for
# legacy bare lines such as "merged" or "PR ready".
status_is_captain_relevant() {
  local line=$1 verb
  [ -n "$line" ] || return 1
  status_is_paused "$line" && return 1
  verb=$(status_line_verb "$line")
  case "$verb" in
    working|resolved|captain-held|"${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}")
      return 1
      ;;
  esac
  if [ -z "${FM_CAPTAIN_RE+x}" ]; then
    case "$verb" in
      done|needs-decision|blocked|failed) return 0 ;;
    esac
  fi
  printf '%s' "$line" | grep -qiE "${FM_CAPTAIN_RE:-$FM_CLASSIFY_CAPTAIN_RE_DEFAULT}"
}

# 0 if a status line's leading verb is the pause verb (paused: <reason>). A pure
# read of the line itself, so the daemon's classify_stale can reuse the last line
# it already read without a fm-crew-state.sh call. Matches only the verb before the
# first colon, so a reason mentioning "paused" elsewhere does not false-match.
status_is_paused() {  # <status-line>
  local line=$1 verb
  [ -n "$line" ] || return 1
  verb=$(status_line_verb "$line")
  [ "$verb" = "${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}" ]
}

# 0 if a status line declares either an external-wait pause or a verified
# captain-held transfer.
# Both declarations can intentionally leave an exited crew's endpoint idle, so
# the watcher applies its bounded pause cadence when agent death confirms that
# no live decision gate is being silenced.
status_is_paused_or_captain_held() {  # <status-line>
  local line=$1 verb
  status_is_paused "$line" && return 0
  [ -n "$line" ] || return 1
  verb=$(status_line_verb "$line")
  [ "$verb" = "${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}" ]
}

# --- durable keyed decisions ------------------------------------------------
#
# The status stream is an append-only EVENT log. Reading it last-event-wins
# (last_status_line above) cannot represent "an earlier decision is still open
# after a later, unrelated event": a subsequent done/paused/working line silently
# masks a still-open needs-decision. status_open_decisions is the ONE authoritative
# statement of the status-fold contract that fixes this - a needs-decision/blocked
# line OPENS a keyed decision, and only an explicit resolution or a verified
# captain-held backlog transfer referencing that key CLOSES it; a later unrelated
# terminal line never clears an open captain decision.
#
# Decision key grammar (backward-compatible with the existing "<verb>: <note>"
# format): an OPTIONAL "[key=<slug>]" token sits between the verb and the colon,
#   needs-decision [key=api-shape]: <summary>
#   resolved       [key=api-shape]: <how it was decided>
# A line with no token uses the key "default", preserving the historical
# one-open-decision-per-task behavior (a bare "resolved:" closes "default").
# The three parsers are pure reads of a single line; the verb parser strips any
# key token before the colon so the leading word is recovered cleanly.
status_line_verb() {  # <status-line> -> leading verb word
  local v=${1%%:*}
  v=${v%%\[key=*}
  v=${v#"${v%%[![:space:]]*}"}
  v=${v%"${v##*[![:space:]]}"}
  printf '%s' "$v"
}
status_line_note() {  # <status-line> -> text after the first colon, trimmed
  case "$1" in
    *:*) local n=${1#*:}; printf '%s' "${n#"${n%%[![:space:]]*}"}" ;;
    *) printf '%s' "$1" ;;
  esac
}
_fm_decision_key() {  # <status-line> -> key slug, or "default" when no token
  local prefix=${1%%:*} k
  case "$prefix" in
    *\[key=*\]*)
      k=${prefix#*\[key=}
      k=${k%%\]*}
      case "$k" in
        ''|*[!A-Za-z0-9._-]*) return 1 ;;
        *) printf '%s' "$k" ;;
      esac
      ;;
    *) printf 'default' ;;
  esac
}
# Drop the record for <key> from a newline-terminated "<key>\t<verb>\t<note>" set.
# Portable (no associative arrays) so the fold runs on bash 3.2 as well as 4+.
_fm_decision_drop() {  # <open-set> <key>
  local set=$1 key=$2 line out=''
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      "$key"$'\t'*) : ;;
      *) out="${out}${line}"$'\n' ;;
    esac
  done <<EOF
$set
EOF
  printf '%s' "$out"
}
# Fold the WHOLE status stream into the set of decisions still open. Prints one
# TAB-separated "<key>\t<verb>\t<summary>" line per still-open decision, in
# most-recently-opened-last order; prints nothing when none are open. Pure read of
# the file, no globals beyond the optional FM_CLASSIFY_RESOLVE_VERB override. This
# is the durable open-set the fleet snapshot and any point-in-time consumer must use
# instead of trusting the last status line.
status_open_decisions() {  # <status-file>
  local f=$1 line verb key note resolve held open='' stripped
  [ -f "$f" ] || return 0
  resolve=${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}
  held=${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}
  while IFS= read -r line || [ -n "$line" ]; do
    stripped=${line//[[:space:]]/}
    [ -n "$stripped" ] || continue
    verb=$(status_line_verb "$line")
    key=$(_fm_decision_key "$line") || continue
    case "$verb" in
      needs-decision|blocked)
        note=$(status_line_note "$line")
        open=$(_fm_decision_drop "$open" "$key")
        [ -n "$open" ] && open="${open}"$'\n'
        open="${open}${key}"$'\t'"${verb}"$'\t'"${note}"$'\n'
        ;;
      "$resolve"|"$held")
        open=$(_fm_decision_drop "$open" "$key")
        [ -n "$open" ] && open="${open}"$'\n'
        ;;
    esac
  done < "$f"
  printf '%s' "$open"
}

# Fold material routed-work phases in the same keyed event stream.
# A working or declared-pause event opens or replaces one phase for its key.
# A later done, failed, needs-decision, blocked, or resolved event carrying that
# key closes the phase, because it has moved to a terminal or separately tracked
# state.
# A bare legacy event uses the default key, preserving one-phase behavior.
# This fold is evidence about whether a parent event was explicitly superseded.
# It is never authoritative current crew state, and consumers must not let an open
# phase outrank a structured home snapshot or fm-crew-state result.
_fm_status_open_activities_stream() {
  local line verb key note resolve held open='' stripped pause
  resolve=${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}
  held=${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}
  pause=${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}
  while IFS= read -r line || [ -n "$line" ]; do
    stripped=${line//[[:space:]]/}
    [ -n "$stripped" ] || continue
    verb=$(status_line_verb "$line")
    key=$(_fm_decision_key "$line") || continue
    case "$verb" in
      working|"$pause")
        note=$(status_line_note "$line")
        open=$(_fm_decision_drop "$open" "$key")
        [ -n "$open" ] && open="${open}"$'\n'
        open="${open}${key}"$'\t'"${verb}"$'\t'"${note}"$'\n'
        ;;
      done|failed|needs-decision|blocked|"$resolve"|"$held")
        open=$(_fm_decision_drop "$open" "$key")
        [ -n "$open" ] && open="${open}"$'\n'
        ;;
    esac
  done
  printf '%s' "$open"
}

status_open_activities() {  # <status-file-or-dash>
  local f=$1
  if [ "$f" = - ]; then
    _fm_status_open_activities_stream
    return 0
  fi
  [ -f "$f" ] || return 0
  _fm_status_open_activities_stream < "$f"
}

# task id from a recorded window target, falling back to the tmux-shaped
# "<session>:fm-<id>" form when no metadata state is available.
window_to_task() {
  local w=$1 state=${2:-${STATE:-${FM_STATE_OVERRIDE:-}}} meta mw mt t
  if [ -n "$state" ]; then
    for meta in "$state"/*.meta; do
      [ -e "$meta" ] || continue
      mw=$(grep '^window=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
      mt=$(grep '^terminal=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
      [ "$mw" = "$w" ] || [ "$mt" = "$w" ] || continue
      t=$(basename "$meta")
      t=${t%.meta}
      printf '%s' "$t"
      return 0
    done
  fi
  t="${w##*:}"; t="${t#fm-}"; printf '%s' "$t"
}

# 0 (actionable) if ANY status file listed in a "signal:" wake carries a
# captain-relevant last line; 1 otherwise. Pass the space-separated file list that
# follows the "signal:" prefix. Non-.status arguments (e.g. .turn-ended markers,
# which never carry a verb) are skipped. A 1 here is NOT "benign" on its own: a
# no-verb signal (a bare turn-end, a working: note) is only benign when the crew is
# also provably working (signal_crew_provably_working below); otherwise it surfaces.
signal_reason_is_actionable() {  # <file> ...
  local f last
  for f in "$@"; do
    [ -e "$f" ] || continue
    case "$f" in *.status) ;; *) continue ;; esac
    last=$(last_status_line "$f")
    [ -n "$last" ] || continue
    status_is_captain_relevant "$last" && return 0
  done
  return 1
}

# --- process liveness: descendant CPU advancement ---------------------------
#
# Every absorb source below is SEMANTIC: the no-mistakes run step, the status
# log, the harness busy signal. All three correctly read "not working" the
# moment an agent backgrounds a long command and ends its turn - while the real
# work continues in a child process none of them can see. Measured 2026-08-03:
# one crew running the portable suite in the background produced seven
# consecutive false wedge escalations across 42 minutes, each demanding a deep
# inspection, and at least three other crews hit the same pattern while pipeline
# stages ran underneath them.
#
# This adds the missing PROCESS-level evidence ALONGSIDE those sources, never in
# place of them. Two rules keep it from becoming a blindfold:
#
#   1. Identity, never a bare pid. The kernel reissues pids, so a recorded pid
#      routinely resolves to an unrelated live process; `kill -0`, a `/proc/<pid>`
#      directory test and a bare `ps -p` all report that impostor as alive
#      (data/learnings.md records the measured evidence). Every stored sample is
#      bound to the fm_pid_identity of the agent it was taken from, and a sample
#      whose anchor identity no longer matches is discarded, never compared.
#   2. ADVANCEMENT, never existence. A descendant that merely EXISTS is no
#      evidence of work: a hung child would then mask a genuine wedge, trading a
#      false alarm for the far more dangerous silence. Only cumulative CPU that
#      GREW since the previous sample counts.
#
# The agent is resolved from kernel facts, never a vendor process name: the
# task's recorded worktree is the agent's working directory, and the agent is
# the LEADER of the foreground process group on that pane's terminal.
#
# Leader, not the whole group, and that choice is load-bearing. Whether a tool
# subprocess ends up in its parent's process group or its own is entirely a
# harness implementation detail - Claude Code detaches its Bash-tool children
# into a new session, a plain shell leaves a background job in the shell's own
# group and on the shell's terminal. Excluding the whole group would therefore
# make this signal silently measure nothing for any harness that spawns children
# the second way, which is far worse than the cost of the leader rule: where a
# harness does NOT get its own foreground group (a multi-process launcher such
# as pi-signed, or an agent started without `exec`), the second harness process
# is a descendant of the leader and its own CPU is counted. The threshold below
# and the caller's completed-turn bound are what keep that over-inclusion safe.
#
# The LEADER's own utime/stime is deliberately EXCLUDED. That is the agent
# itself working, which the semantic busy contract (bin/fm-busy-lib.sh) already
# owns, and counting it would let an idle agent's rendering jitter - or worse, a
# genuinely looping wedged agent - read as work. What is counted is everything
# below it: every live strict descendant's CPU, plus every already-reaped
# descendant's CPU through the leader's own cutime/cstime. That sum is monotonic
# across a child exiting (the child's total leaves the live set and lands in its
# parent's cutime), so one aggregate is enough and no per-child bookkeeping is
# needed - which is also what makes a long run of short-lived children, such as
# a test suite driving one script after another, register as advancing at all.
#
# A Linux-compatible /proc is required. Where it is absent this reports `none`,
# which is exactly today's no-evidence behaviour: the wake surfaces.

# Kernel ticks of descendant CPU that must accrue between two samples before a
# crew counts as working. A tick is 10ms at the standard Linux USER_HZ of 100,
# so the default is one full CPU-second per sample: far above what a harness
# helper being spawned and reaped costs incidentally, and far below any real
# build, test run, or pipeline stage. At the watcher's default 15s poll that is
# roughly 7% of one core sustained.
FM_CHILD_CPU_MIN_TICKS_DEFAULT=100
# A baseline older than this proves nothing about NOW, so it is refreshed and
# the probe reports no evidence for that poll rather than comparing against it.
FM_CHILD_CPU_MAX_SAMPLE_AGE_DEFAULT=120
# The baseline is replaced only once it is at least this old. Both the no-verb
# signal path and the stale path can probe within one watcher cycle; without
# this the second probe would reset the baseline to a near-zero measurement
# window and report live work as static.
FM_CHILD_CPU_SAMPLE_INTERVAL_DEFAULT=5

# fm_pid_identity lives in bin/fm-wake-lib.sh, which creates the state directory
# when sourced. This library is also sourced by strictly read-only readers
# (bin/fm-crew-state.sh), so it is loaded on first probe instead of at source
# time. Every consumer that actually probes - the watcher and the away-mode
# daemon - has already loaded it, so this normally sources nothing.
_fm_child_cpu_need_identity() {
  command -v fm_pid_identity >/dev/null 2>&1 && return 0
  # shellcheck source=bin/fm-wake-lib.sh
  . "$_FM_CLASSIFY_LIB_DIR/fm-wake-lib.sh" 2>/dev/null || return 1
  command -v fm_pid_identity >/dev/null 2>&1
}

# Print "<ticks>\t<agent-identity>" for the agent that owns <worktree>: the
# total CPU its descendants have consumed, live and already reaped, and the
# identity that total is bound to. Returns 1 when no agent can be resolved -
# no readable /proc, no live process whose working directory is that worktree,
# no controlling terminal, no foreground group, no live foreground group leader,
# or two different panes claiming the same worktree (refused rather than
# guessed).
_fm_child_cpu_measure() {  # <worktree>
  local wt=$1 proc d pid line rest cur c i
  local tty='' tpgid='' total=0 identity
  local -a ppid_of pgrp_of own_of reaped_of kids_of visited queue
  [ -n "$wt" ] && [ -d "$wt" ] || return 1
  proc=${FM_PROC_ROOT_OVERRIDE:-/proc}
  [ -d "$proc" ] || return 1
  for d in "$proc"/[0-9]*; do
    pid=${d#"$proc"/}
    # stderr is redirected BEFORE stdin on purpose: redirections are applied
    # left to right, so this also swallows the shell's own "no such file"
    # complaint for a process that exited mid-scan, or for the literal glob left
    # behind when the process table is empty.
    read -r line 2>/dev/null < "$d/stat" || continue
    # The comm field is parenthesised and may itself contain ") ", so strip
    # greedily to the LAST one; every field after it is numeric. What remains
    # starts at proc stat field 3, so field N sits at position N-2: ppid 4->2,
    # pgrp 5->3, tty_nr 7->5, tpgid 8->6, utime 14->12, stime 15->13,
    # cutime 16->14, cstime 17->15.
    rest=${line##*') '}
    # shellcheck disable=SC2086  # deliberate split of the fixed-shape numeric stat tail
    set -- $rest
    [ "$#" -ge 15 ] || continue
    ppid_of[pid]=$2
    pgrp_of[pid]=$3
    own_of[pid]=$(( ${12} + ${13} ))
    reaped_of[pid]=$(( ${14} + ${15} ))
    # `-ef` compares the RESOLVED directory by device and inode, so it needs no
    # readlink fork and is immune to a symlinked or bind-mounted worktree path.
    [ "$d/cwd" -ef "$wt" ] 2>/dev/null || continue
    # tty_nr 0 means no controlling terminal and tpgid -1 means no foreground
    # group; neither can anchor an agent.
    [ "$5" != 0 ] && [ "$6" != -1 ] || continue
    if [ -z "$tty" ]; then
      tty=$5
      tpgid=$6
    elif [ "$tty" != "$5" ] || [ "$tpgid" != "$6" ]; then
      return 1
    fi
  done
  [ -n "$tpgid" ] || return 1
  # The foreground group's LEADER is the agent, and it must still be alive: a
  # group whose leader has gone describes an agent already replaced.
  [ -n "${pgrp_of[tpgid]+set}" ] && [ "${pgrp_of[tpgid]}" = "$tpgid" ] || return 1
  for pid in "${!ppid_of[@]}"; do
    kids_of[ppid_of[pid]]="${kids_of[ppid_of[pid]]:-} $pid"
  done
  # The leader's own cutime/cstime: the CPU of every descendant it has already
  # reaped. Its own utime/stime is excluded on purpose (see above).
  total=${reaped_of[tpgid]}
  visited[tpgid]=1
  queue=("$tpgid")
  i=0
  while [ "$i" -lt "${#queue[@]}" ]; do
    cur=${queue[i]}
    i=$(( i + 1 ))
    for c in ${kids_of[cur]:-}; do
      [ -z "${visited[c]+set}" ] || continue
      visited[c]=1
      total=$(( total + own_of[c] + reaped_of[c] ))
      queue+=("$c")
    done
  done
  identity=$(fm_pid_identity "$tpgid") || return 1
  printf '%s\t%s' "$total" "$identity"
}

# Print the process-liveness verdict for crew <id>:
#   advancing - its agent's descendants burned at least FM_CHILD_CPU_MIN_TICKS
#               of CPU since the previous sample, so work is happening NOW in a
#               child process even though the pane and every semantic source
#               look idle;
#   static    - an agent was resolved but its descendants did not advance (they
#               are hung, finished, or absent), or there is no usable baseline
#               to compare against yet;
#   none      - no agent could be resolved at all: no /proc, no worktree
#               recorded, no live agent on it, or an unreadable process table.
# NOT a pure read: it maintains the state/<id>.childcpu sample the next call
# measures against. Safe to call more than once per cycle - the baseline is
# replaced only once it is FM_CHILD_CPU_SAMPLE_INTERVAL old, so a second probe
# re-scores the SAME baseline instead of resetting the measurement window.
fm_child_cpu_state() {  # <state-dir> <id>
  local state=$1 id=$2 meta wt file now measured identity ticks verdict
  local prev_ts='' prev_ticks='' prev_identity='' age min interval max_age
  [ -n "$state" ] && [ -n "$id" ] || { printf 'none'; return; }
  meta="$state/$id.meta"
  [ -f "$meta" ] || { printf 'none'; return; }
  wt=$(grep '^worktree=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
  [ -n "$wt" ] || { printf 'none'; return; }
  _fm_child_cpu_need_identity || { printf 'none'; return; }
  measured=$(_fm_child_cpu_measure "$wt") || { printf 'none'; return; }
  ticks=${measured%%$'\t'*}
  identity=${measured#*$'\t'}
  file="$state/$id.childcpu"
  now=$(date +%s)
  min=${FM_CHILD_CPU_MIN_TICKS:-$FM_CHILD_CPU_MIN_TICKS_DEFAULT}
  interval=${FM_CHILD_CPU_SAMPLE_INTERVAL:-$FM_CHILD_CPU_SAMPLE_INTERVAL_DEFAULT}
  max_age=${FM_CHILD_CPU_MAX_SAMPLE_AGE:-$FM_CHILD_CPU_MAX_SAMPLE_AGE_DEFAULT}
  # Identity last, so a stray separator inside it can never shift the numbers.
  if [ -f "$file" ]; then
    IFS=$'\t' read -r prev_ts prev_ticks prev_identity < "$file" 2>/dev/null || true
  fi
  # A missing, truncated, or corrupt baseline is no baseline: measure afresh.
  case "$prev_ts" in ''|*[!0-9]*) prev_ts='' ;; esac
  case "$prev_ticks" in ''|*[!0-9]*) prev_ts='' ;; esac
  verdict=static
  if [ -n "$prev_ts" ] && [ "$prev_identity" = "$identity" ]; then
    age=$(( now - prev_ts ))
    if [ "$age" -ge 0 ] && [ "$age" -le "$max_age" ] \
      && [ $(( ticks - prev_ticks )) -ge "$min" ]; then
      verdict=advancing
    fi
  fi
  if [ -z "$prev_ts" ] || [ "$prev_identity" != "$identity" ] \
    || [ $(( now - prev_ts )) -ge "$interval" ]; then
    printf '%s\t%s\t%s\n' "$now" "$ticks" "$identity" > "$file" 2>/dev/null || true
  fi
  printf '%s' "$verdict"
}

# 0 if crew <id> shows advancing descendant CPU. The positive half of the
# process-liveness signal; see fm_child_cpu_state for the exact verdict.
crew_child_cpu_advancing() {  # <id> [state-dir]
  local id=$1 state=${2:-${STATE:-${FM_STATE_OVERRIDE:-}}}
  [ "$(fm_child_cpu_state "$state" "$id")" = advancing ]
}

# Classify bin/fm-crew-state.sh's authoritative current-state line without
# consulting process liveness. Prints working, paused, definite, or inconclusive.
# FM_CREW_STATE_BIN lets tests stub the semantic verdict.
crew_semantic_class() {  # <id>
  local id=$1 line state src
  [ -n "$id" ] || { printf 'definite'; return; }
  line=$("$FM_CREW_STATE_BIN" "$id" 2>/dev/null) || true
  state=unreadable
  case "$line" in
    state:*)
      state=${line#state: }; state=${state%% *}
      if [ "$state" = paused ]; then printf 'paused'; return; fi
      if [ "$state" = working ]; then
        src=${line#*source: }; src=${src%% *}
        case "$src" in run-step|pane) printf 'working'; return ;; esac
      fi
      ;;
  esac
  case "$state" in
    working|unknown|unreadable) printf 'inconclusive' ;;
    *) printf 'definite' ;;
  esac
}

# Classify why an idle or stale crew may be absorbed. Prints working, paused, or
# none. Process liveness is consulted only after an inconclusive semantic read.
crew_absorb_class() {  # <id> [state-dir]
  local id=$1 state_dir=${2:-${STATE:-${FM_STATE_OVERRIDE:-}}} semantic
  [ -n "$id" ] || { printf 'none'; return; }
  semantic=$(crew_semantic_class "$id")
  case "$semantic" in
    working|paused) printf '%s' "$semantic"; return ;;
    definite) printf 'none'; return ;;
  esac
  if [ "$(fm_child_cpu_state "$state_dir" "$id")" = advancing ]; then
    printf 'working'
    return
  fi
  printf 'none'
}

# 0 if crew <id> shows POSITIVE evidence it is still working (crew_absorb_class
# reports `working`). This is the "provably working" predicate at the heart of
# absorb-only-when-provably-working: a no-verb turn-end or stale wake is absorbed
# ONLY when this returns 0, and SURFACED otherwise (the crew may be done, waiting
# on a decision, or wedged). For stale panes it is checked before trusting the
# status log so a pre-validation captain-relevant line does not override an active
# run. See crew_absorb_class for the exact working/paused/none decision.
crew_is_provably_working() {  # <id>
  [ "$(crew_absorb_class "$1")" = working ]
}

# 0 if crew <id>'s authoritative current state is a declared external-wait pause.
# The stale path absorbs such a crew (on a long re-surface cadence) instead of
# escalating a possible wedge.
crew_is_paused() {  # <id>
  [ "$(crew_absorb_class "$1")" = paused ]
}

# 0 (benign/absorb) if EVERY task referenced by a no-verb "signal:" wake is provably
# working; 1 (actionable/surface) if any is not, or no task can be resolved. Pass the
# same space-separated file list as signal_reason_is_actionable. Files are mapped to
# task ids by stripping the .status / .turn-ended suffix; a no-verb wake with nothing
# provably working must surface, so an empty/unresolvable list returns 1.
signal_crew_provably_working() {  # <file> ...
  local f base task seen=""
  for f in "$@"; do
    base=${f##*/}
    case "$base" in
      *.status)     task=${base%.status} ;;
      *.turn-ended) task=${base%.turn-ended} ;;
      *)            continue ;;
    esac
    [ -n "$task" ] || continue
    case " $seen " in *" $task "*) continue ;; esac
    seen="$seen $task"
    crew_is_provably_working "$task" || return 1
  done
  [ -n "$seen" ] || return 1
  return 0
}

# 0 (terminal/actionable) if a stale window's last status line is
# captain-relevant; 1 otherwise, including the no-status case. A 1 only means
# "non-terminal"; the always-on watcher then applies crew_is_provably_working,
# while the away-mode daemon applies its persistence recheck.
stale_is_terminal() {  # <window> <state>
  local win=$1 state=$2 last
  last=$(last_status_line "$state/$(window_to_task "$win" "$state").status")
  [ -n "$last" ] && status_is_captain_relevant "$last"
}

# Print "<file>\t<task>\t<last-line>" for every state/*.status whose last line is
# captain-relevant. This is the cheap fleet-scan both supervisors run as a
# catch-all backstop for a captain-relevant status the per-wake path might miss.
# No dedup is applied here: each consumer dedupes against its own seen-state (the
# daemon against .subsuper-seen-status-*, the watcher against .seen-* signatures).
scan_captain_relevant_statuses() {  # <state>
  local state=$1 f last task
  for f in "$state"/*.status; do
    [ -e "$f" ] || continue
    last=$(last_status_line "$f")
    status_is_captain_relevant "$last" || continue
    task=$(basename "$f"); task="${task%.status}"
    printf '%s\t%s\t%s\n' "$f" "$task" "$last"
  done
  return 0
}
