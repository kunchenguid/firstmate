#!/usr/bin/env bash
# fm-agent-postmortem.sh - why did this task's agent process die?
#
# Usage: fm-agent-postmortem.sh <id> [--force]
#
# Called by bin/fm-resource-sample.sh the moment a task's agent pid disappears,
# and runnable by hand afterwards. Writes state/<id>.postmortem (key=value) and
# prints its verdict line. Without --force an existing postmortem is kept and
# reprinted, so the evidence is captured once, at the death, not overwritten by a
# later look.
#
# It collects, for the window around the death, every kill signal this machine
# actually exposes - and RECORDS THE ABSENCE of the ones it does not, because a
# collector that silently writes nothing is worse than none:
#
#   pane tail      the shell's own report of how the agent ended ("zsh: killed
#                  claude ...", "signal: killed", a segfault trap). This is the
#                  exit-signal source; tmux only, like all pid tracking here.
#   jetsam report  /Library/Logs/DiagnosticReports/JetsamEvent-*.ips, the kernel's
#                  authoritative record of a memory kill. Readable without root by
#                  a member of _analyticsusers. Matched by report timestamp inside
#                  the death window, then by the dead pid / harness name inside the
#                  report's processes[] table (each killed entry carries a
#                  `reason`, e.g. per-process-limit).
#   proc report    a pid-matched .ips for the harness binary. macOS writes one for a
#                  KERNEL-originated SIGKILL too, not only for a crash, and it names
#                  the killing subsystem in termination.namespace (JETSAM,
#                  CODESIGNING, RUNNINGBOARD, ...) plus exception.signal. A
#                  user-space `kill -9` writes NO report - so its ABSENCE next to a
#                  SIGKILL is itself the finding: something in user space killed it.
#   unified log    `/usr/bin/log show` for jetsam/memorystatus/kernel kill events.
#                  On this machine it CANNOT work (no /var/db/diagnostics, so the
#                  local log store does not exist) - the attempt's exact failure is
#                  written into the postmortem instead of a silent blank. See
#                  docs/agent-kill-evidence.md for what was probed and what the
#                  machine does and does not expose.
#   memory picture the sampler's own record: the agent's RSS trajectory, and the
#                  machine's free/compressor/swap/memorystatus_level at the last
#                  sample before the death and right now.
#
# The verdict never guesses. A SIGKILL with no jetsam record is reported as a
# SIGKILL from an unidentified killer, with the memory numbers attached, NOT as
# an OOM kill - which is exactly the unevidenced claim this whole mechanism
# exists to stop.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-resource-lib.sh
. "$SCRIPT_DIR/fm-resource-lib.sh"

ID=${1:-}
FORCE=${2:-}
[ -n "$ID" ] || { echo "usage: fm-agent-postmortem.sh <id> [--force]" >&2; exit 2; }

META="$STATE/$ID.meta"
PIDFILE="$STATE/$ID.agentpid"
SAMPLES="$STATE/$ID.resource"
OUT="$STATE/$ID.postmortem"
LOGF="$STATE/$ID.status"

if [ -f "$OUT" ] && [ "$FORCE" != --force ]; then
  fm_res_meta_value "$OUT" verdict
  echo
  exit 0
fi
[ -f "$META" ] || { echo "no metadata for $ID" >&2; exit 1; }

HARNESS=$(fm_res_meta_value "$META" harness)
WINDOW=$(fm_res_meta_value "$META" window)
BACKEND=$(fm_res_meta_value "$META" backend)
[ -n "$BACKEND" ] || BACKEND=tmux
AGENT_PID=$(fm_res_meta_value "$PIDFILE" pid)
LAST_SEEN=$(fm_res_meta_value "$PIDFILE" last_seen)
LAST_SEEN_ISO=$(fm_res_meta_value "$PIDFILE" last_seen_iso)
LAST_RSS_KB=$(fm_res_meta_value "$PIDFILE" last_rss_kb)
LAST_MEM=$(fm_res_meta_value "$PIDFILE" last_mem)
NOW=$(date +%s)
case "$LAST_SEEN" in ''|*[!0-9]*) LAST_SEEN=$NOW ;; esac
# The death happened between the last sample and now. Widen by a minute on each
# side so a jetsam report written just outside the sampling grid still matches.
WIN_START=$((LAST_SEEN - 60))
WIN_END=$((NOW + 60))
WIN_MINS=$(( (WIN_END - WIN_START) / 60 + 1 ))

# --- exit signal, from the pane the agent was launched in -------------------

PANE_LINE=""
EXIT_SIGNAL=unknown
if [ "$BACKEND" = tmux ] && [ -n "$WINDOW" ]; then
  fm_tmux_bind_meta "$META"
  pane=$(fm_tmux capture-pane -p -t "$WINDOW" -S -100 2>/dev/null || true)
  if [ -n "$pane" ]; then
    PANE_LINE=$(printf '%s\n' "$pane" | grep -iE 'killed|signal: |terminated|segmentation fault|abort trap|bus error|illegal instruction|out of memory' | tail -1 || true)
  fi
fi
case "$(printf '%s' "$PANE_LINE" | tr '[:upper:]' '[:lower:]')" in
  *"signal: killed"*|*killed*)   EXIT_SIGNAL=SIGKILL ;;
  *"segmentation fault"*)        EXIT_SIGNAL=SIGSEGV ;;
  *"abort trap"*)                EXIT_SIGNAL=SIGABRT ;;
  *"bus error"*)                 EXIT_SIGNAL=SIGBUS ;;
  *terminated*)                  EXIT_SIGNAL=SIGTERM ;;
  *"out of memory"*)             EXIT_SIGNAL=oom-message ;;
esac

# --- jetsam report: the kernel's own memory-kill record ---------------------
#
# Darwin only. Reports are whole-machine, not per-process, so a report inside the
# window is matched against the dead pid and the harness name before it is
# claimed as THIS agent's killer; a window-matching report that killed something
# else is recorded as `other-victims` rather than counted as our cause.
JETSAM=none
JETSAM_MATCH=""
if [ "$FM_RES_UNAME" = Darwin ]; then
  for rep in /Library/Logs/DiagnosticReports/JetsamEvent-*.ips; do
    [ -e "$rep" ] || continue
    mt=$(stat -f %m "$rep" 2>/dev/null) || continue
    [ "$mt" -ge "$WIN_START" ] && [ "$mt" -le "$WIN_END" ] || continue
    victims=""
    if command -v jq >/dev/null 2>&1; then
      victims=$(tail -n +2 "$rep" | fm_res_bounded 20 jq -r '.processes[] | select(.reason) | "\(.name):\(.pid):\(.reason):\(.rpages)pages"' 2>/dev/null || true)
    else
      victims=$(grep -o '"name" : "[^"]*"' "$rep" 2>/dev/null | head -5 | tr '\n' ' ')
    fi
    # victims lines are "<name>:<pid>:<reason>:<rpages>pages"
    ours=$(printf '%s\n' "$victims" | grep -E "^${HARNESS:-__none__}:|:${AGENT_PID:-__none__}:" || true)
    if [ -n "$ours" ]; then
      JETSAM="killed-here $rep"
      JETSAM_MATCH=$(printf '%s' "$ours" | tr '\n' ';')
    else
      JETSAM="other-victims $rep"
      JETSAM_MATCH=$(printf '%s' "$victims" | tr '\n' ';')
    fi
  done
else
  JETSAM="n/a (non-Darwin: no jetsam reports)"
fi

# --- the agent's own .ips report: it NAMES the killer ------------------------
#
# The most useful signal on this machine, and the one the fleet was not looking
# at. A per-process report is written for a kernel-originated SIGKILL, not just
# for a crash, and it carries `termination.namespace` - the killing subsystem
# (JETSAM, CODESIGNING, RUNNINGBOARD, ...) - plus `exception.signal`, e.g.
# "SIGKILL (Code Signature Invalid)" (verified live 2026-07-14 against a real
# SIGKILL, see docs/agent-kill-evidence.md).
#
# A plain user-space `kill -9` writes NO report (verified in the same session).
# So a SIGKILL with no report here is a user-space kill, and one WITH a report is
# the kernel telling you which subsystem did it - a distinction the fleet had no
# way to make before.
#
# Matched by pid, not just by the time window: a same-window report for another
# incarnation of the same binary is recorded as `window-match` and never claimed
# as this agent's cause.
PROC_REPORT=none
PROC_SIGNAL=""
PROC_TERMINATION=""
if [ "$FM_RES_UNAME" = Darwin ] && [ -n "$HARNESS" ]; then
  for rep in "$HOME"/Library/Logs/DiagnosticReports/"$HARNESS"-*.ips /Library/Logs/DiagnosticReports/"$HARNESS"-*.ips; do
    [ -e "$rep" ] || continue
    mt=$(stat -f %m "$rep" 2>/dev/null) || continue
    [ "$mt" -ge "$WIN_START" ] && [ "$mt" -le "$WIN_END" ] || continue
    rep_pid=""
    sig=""
    term=""
    if command -v jq >/dev/null 2>&1; then
      rep_pid=$(tail -n +2 "$rep" | fm_res_bounded 20 jq -r '.pid // empty' 2>/dev/null || true)
      sig=$(tail -n +2 "$rep" | fm_res_bounded 20 jq -r '.exception.signal // .exception.type // empty' 2>/dev/null || true)
      term=$(tail -n +2 "$rep" | fm_res_bounded 20 jq -r '[.termination.namespace, .termination.indicator] | map(select(. != null)) | join(": ")' 2>/dev/null || true)
    fi
    if [ -n "$rep_pid" ] && [ "$rep_pid" = "${AGENT_PID:-__none__}" ]; then
      PROC_REPORT="$rep"
      PROC_SIGNAL=$sig
      PROC_TERMINATION=$term
      break
    fi
    PROC_REPORT="window-match (pid ${rep_pid:-unknown} != agent ${AGENT_PID:-unknown}) $rep"
  done
fi

# --- unified log: attempted, and its failure recorded verbatim ---------------
#
# `log` is a shell BUILTIN in zsh, so the absolute path is mandatory - the bare
# name silently resolves to the builtin and reports "too many arguments".
LOG_SHOW="not attempted (non-Darwin)"
if [ "${FM_POSTMORTEM_SKIP_LOG_SHOW:-0}" = 1 ]; then
  LOG_SHOW="not attempted (FM_POSTMORTEM_SKIP_LOG_SHOW=1)"
elif [ "$FM_RES_UNAME" = Darwin ] && [ -x /usr/bin/log ]; then
  log_out=$(fm_res_bounded 30 /usr/bin/log show --last "${WIN_MINS}m" --style compact \
    --predicate 'eventMessage CONTAINS "jetsam" OR eventMessage CONTAINS "memorystatus" OR eventMessage CONTAINS "lowmem"' 2>&1) || true
  case "$log_out" in
    *"Could not open local log store"*)
      LOG_SHOW="unavailable: $(printf '%s' "$log_out" | head -1)"
      ;;
    "")
      LOG_SHOW="ok rows=0 (no jetsam/memorystatus events in the window)"
      ;;
    *)
      rows=$(printf '%s\n' "$log_out" | grep -c . || true)
      LOG_SHOW="ok rows=$rows"
      printf '%s\n' "$log_out" | tail -50 > "$STATE/$ID.postmortem.logshow" 2>/dev/null || true
      ;;
  esac
fi

# --- the sampler's own memory picture ---------------------------------------
MEM_NOW=$(fm_res_mem_snapshot)
RSS_TRAIL=""
if [ -f "$SAMPLES" ]; then
  RSS_TRAIL=$(tail -3 "$SAMPLES" | awk -F'\t' '{ printf "%s(%s) ", $3, $4 }')
fi
LAST_STATUS=$(grep -v '^[[:space:]]*$' "$LOGF" 2>/dev/null | tail -1 || true)
LAST_VERB=${LAST_STATUS%%:*}

# --- verdict ----------------------------------------------------------------
#
# Evidence order, strongest first. The verdict never upgrades a guess into a
# cause: a SIGKILL with no kernel record is reported AS a SIGKILL with no kernel
# record, with the memory numbers attached for the reader to judge - not as an
# OOM kill. Claiming memory exhaustion without a jetsam record is precisely the
# unevidenced claim this mechanism exists to prevent.
ABNORMAL=1
if [ "${JETSAM#killed-here}" != "$JETSAM" ]; then
  VERDICT="killed by jetsam (macOS memory kill): $JETSAM_MATCH"
elif [ -n "$PROC_TERMINATION" ] || { [ "$PROC_REPORT" != none ] && [ "${PROC_REPORT#window-match}" = "$PROC_REPORT" ]; }; then
  # The kernel wrote a report for THIS pid: it names the killing subsystem.
  VERDICT="killed by the kernel [${PROC_TERMINATION:-termination namespace absent}] signal=${PROC_SIGNAL:-unknown} (report: $PROC_REPORT)"
else
  case "$EXIT_SIGNAL" in
    SIGKILL)
      VERDICT="SIGKILL, killer unidentified: no jetsam report and no kernel termination report for this pid, which is what a user-space kill -9 looks like. NOT evidence of OOM. Memory at last sample: $LAST_MEM"
      ;;
    SIGSEGV|SIGABRT|SIGBUS|SIGILL)
      VERDICT="agent crashed ($EXIT_SIGNAL), not killed; report: $PROC_REPORT"
      ;;
    SIGTERM)
      VERDICT="agent terminated (SIGTERM) - a deliberate stop, not a memory kill"
      ;;
    *)
      case "$LAST_VERB" in
        done|failed)
          ABNORMAL=0
          VERDICT="agent exited after reporting '$LAST_VERB' - normal end of task"
          ;;
        *)
          VERDICT="agent process gone with no exit signal recorded in the pane (no kill evidence found; pane may have scrolled or closed)"
          ;;
      esac
      ;;
  esac
fi

{
  echo "task=$ID"
  echo "detected=$(fm_res_now_iso)"
  echo "abnormal=$ABNORMAL"
  echo "verdict=$VERDICT"
  echo "agent_pid=${AGENT_PID:-unknown}"
  echo "harness=${HARNESS:-unknown}"
  echo "backend=$BACKEND"
  echo "window=${WINDOW:-unknown}"
  echo "exit_signal=$EXIT_SIGNAL"
  echo "pane_exit_line=${PANE_LINE:-none}"
  echo "jetsam=$JETSAM"
  echo "jetsam_match=${JETSAM_MATCH:-none}"
  echo "proc_report=$PROC_REPORT"
  echo "proc_report_signal=${PROC_SIGNAL:-none}"
  echo "proc_report_termination=${PROC_TERMINATION:-none}"
  echo "log_show=$LOG_SHOW"
  echo "last_seen=${LAST_SEEN_ISO:-unknown}"
  echo "last_rss_kb=${LAST_RSS_KB:-unknown}"
  echo "mem_at_last_sample=${LAST_MEM:-unknown}"
  echo "mem_now=$MEM_NOW"
  echo "rss_trail=${RSS_TRAIL:-none}"
  echo "last_status=${LAST_STATUS:-none}"
  echo "samples=$SAMPLES"
} > "$OUT"

printf '%s\n' "$VERDICT"
