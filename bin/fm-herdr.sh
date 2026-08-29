#!/usr/bin/env bash
# fm-herdr.sh — firstmate's herdr surface: one library, one multiplexer.
#
# Sourceable as a library, and executable as the workspace-reconcile CLI (see
# the bottom of this file). It replaces bin/fm-mux-lib.sh and
# bin/fm-herdr-workspaces.sh, which were split across a driver-selection seam
# that no longer has two drivers to choose between.
#
# THE NAME. `fm-herdr.sh`, deliberately not a bare `herdr`: a script called
# `herdr` would shadow the real binary at ~/.local/bin/herdr, and which one a
# call site got would depend on PATH order at the moment of the call.
#
# WHY THERE IS NO DRIVER SELECTION. Agents run in herdr and herdr is the ONLY
# automatic choice (AGENTS.md, "herdr workspace hygiene" - the shared statement
# of record; the captain's own copy is local and gitignored). Headless is never
# selected automatically — not by a reachability probe, not by a missing binary,
# not by an environment variable, and not loudly. Degrading is the decision the
# captain reserved for himself: believing he is watching the fleet while work
# lands somewhere he cannot see is worse than knowing it is invisible.
#
# So there is no `fm_mux_driver`, no dispatch table, and no FM_MUX. Reachability
# is still CHECKED — by fm_herdr_require, which ESCALATES when no server can be
# reached rather than quietly picking something else. A tier may RECOMMEND a
# headless run; it recommends by stopping and saying why, and the captain
# decides.
#
# WHY TARGETS ARE NOT OPAQUE ANY MORE. The opacity rule existed so a tmux
# `session:window` and a herdr id could travel through one contract without
# either caller knowing which it held. With one surface there is nothing to hide
# behind: a target here is a herdr PANE ID, and it is named as one.
#
# THE DRAIN. Crewmates spawned before this cutover live in tmux windows, and
# their `state/<id>.meta` has no `mux=` line. They must stay readable, steerable
# and closable until they are torn down, or the watcher goes blind and teardown
# cannot clean up work that is still running. fm_herdr_resolve marks those
# targets so callers take the legacy path; nothing NEW ever does.
# See "the drain" below, and bin/fm-peek.sh / bin/fm-send.sh.

# --- reachability, and the escalation ---------------------------------------

# Is a herdr server actually reachable? Not "are we running inside herdr" —
# HERDR_ENV is unset in firstmate's own process even while a server is running
# and the captain is watching it, so this is the only correct way to ask.
#
# It is a DIAGNOSTIC. Nothing in this file selects anything from its answer.
#
# IT PROBES THE SESSION THE VERBS WILL ACTUALLY USE, which is neither a fixed
# `default` nor "any running session". Verified against herdr 0.8.2: every verb
# that matters — workspace list, tab create, agent list, pane read, agent prompt
# — takes its session from $HERDR_SESSION and defaults to `default`, and none of
# them accepts a --session flag; meanwhile `herdr session list` IGNORES
# $HERDR_SESSION and lists every session on the machine. So the two ends of this
# predicate answer different questions unless the name is matched explicitly.
#
# Both directions have been live defects on this branch, and they are opposite:
#   * pinning `default` reported a fleet running under a named session as
#     unreachable — bootstrap printed NEEDS_HERDR_SERVER and every spawn stopped;
#   * matching ANY running row reported the fleet reachable while the verbs were
#     aimed at a session that is not up — the spawn then died later at `tab
#     create` with a worse, less actionable diagnostic than this one.
# Matching the one session the verbs will reach is honest in both directions.
#
# Nothing is skipped by POSITION: a herdr that stopped printing its header would
# otherwise hide the fleet's only running session behind a false negative, and
# the header's own fields cannot collide with a real session named `<want>` that
# is `running`.
fm_herdr_session() {
  [ -z "${FM_HERDR_SESSION:-}" ] || export HERDR_SESSION="$FM_HERDR_SESSION"
  printf '%s' "${HERDR_SESSION:-default}"
}
# FM_HERDR_SESSION EXPORTS rather than merely filtering the probe. A pin that
# moved this predicate but not the verbs would re-open the very divergence above.
fm_herdr_session >/dev/null

fm_herdr_up() {
  command -v herdr >/dev/null 2>&1 || return 1
  local want
  want=$(fm_herdr_session)
  herdr session list 2>/dev/null | awk -v want="$want" '
    $1 == want && $2 == "running" { found = 1 }
    END { exit !found }'
}

# Precondition for putting an AGENT anywhere. Call it before creating a pane.
#
# When herdr cannot be reached this returns non-zero with an escalation and the
# caller must STOP. It must not fall back, because falling back is the decision
# the captain reserved for himself. The message says what is wrong, whose call
# it is, and that a headless run needs his word — a tier recommends headless by
# printing this and stopping, never by choosing it.
#
# It NAMES THE SESSION it looked for. A bare "no herdr server is running" is
# actively misleading when another session is plainly up and only the one the
# verbs target is missing — the captain would go looking for a dead server he
# can see running.
fm_herdr_require() {  # [what-for]
  local what=${1:-this agent} sess
  if fm_herdr_up; then return 0; fi
  sess=$(fm_herdr_session)
  {
    echo "fm-herdr: cannot place $what - no herdr server is reachable for session '$sess'."
    if command -v herdr >/dev/null 2>&1; then
      echo "  herdr is installed but session '$sess' is not running. Start or attach it with"
      echo "  \`herdr session attach $sess\` (or \`herdr\` for the default session). Every herdr"
      echo "  verb targets \$HERDR_SESSION only, so another session being up does not help."
    else
      echo "  herdr is not on PATH. Install it, or run this where a server is reachable."
    fi
    echo "  NOT falling back to a headless pane: where agents run is the captain's"
    echo "  decision, and a pane he cannot see does not count. If this particular"
    echo "  run genuinely belongs headless, that is his call to make, not this script's."
  } >&2
  return 1
}

# --- reading herdr's responses ----------------------------------------------
#
# herdr answers over its socket API in single-line JSON. jq is not a firstmate
# dependency, so fields are pulled with targeted sed, splitting on `{` first so
# a per-record grep cannot straddle two objects.
#
# ASSUMPTION, worth naming: the first match wins. That is exact for the flat
# sibling arrays this reads (workspace list, tab list) and for single-object
# reads (pane get). It is only safe on `tab create` — whose response nests
# root_pane.tab_id beside tab.tab_id — because those two ids are identical in
# every shape herdr emits. If a future herdr let them diverge this would take
# the first; the extraction that matters there asks for pane_id, which appears
# exactly once.
fm_herdr_field() {  # <json> <key>
  printf '%s' "$1" | tr '{' '\n' | sed -n "s/.*\"$2\":\"\\([^\"]*\\)\".*/\\1/p" | head -1
}

# --- naming -----------------------------------------------------------------
#
# A pane name is the ADDRESS, not decoration: herdr addresses agents by name, so
# a task id like `afs-resources-r7` is not merely untidy at a glance, it is
# unreadable. `afs-resource-registry` says both the project and the work without
# attaching to the pane.
#
# THE CONVENTION: <project-short>-<what-the-work-is>, kebab-case, under 28 chars.
#   afs-resource-registry   mac-config-cutover-guard   cellarsky-booking-fix
#   firstmate-fleet-view    firstmate-hook-register    archify-leak-fixes
#
# One HYPHEN joins the halves, never a slash. That is not a style preference:
# verified against herdr 0.8.2, `herdr agent rename` rejects anything but
# ^[a-z][a-z0-9_-]{0,31}$ with invalid_agent_name, so a slashed name renames
# nothing and leaves the pane unaddressable. A live gate pins the separator
# against the real binary, so restoring a slash turns that gate red.
#
# 28 chars keeps the name readable in herdr's sidebar (sidebar_width 30) and
# inside the 32-char address limit at once. No task suffix — the id lives in
# state/<id>.meta, which is where an id belongs.

fm_herdr_name_max=28

# Sanitize one half of a name. Anything herdr would reject is removed here
# rather than discovered at rename time. A LEADING DIGIT IS KEPT: herdr's
# ^[a-z][a-z0-9_-]{0,31}$ constrains the first character of the WHOLE name, so
# only the half that starts the name has to start with a letter. Enforcing that
# per half deleted a character for nothing - `2fa-login` became `fa-login`, so
# `app-2fa-login`, a name herdr accepts, was rendered as `app-fa-login` and the
# one line the captain reads named the wrong work.
fm_herdr_work_name() {  # <work...>
  printf '%s' "$*" | tr '[:upper:]' '[:lower:]' | tr ' _/' '-' \
    | tr -cd 'a-z0-9-' | sed 's/--*/-/g; s/^-*//; s/-*$//'
}

# The leading-letter rule, applied where it actually belongs: to whichever half
# ends up first in the assembled name.
fm_herdr_lead_name() {  # <half>
  printf '%s' "$1" | sed 's/^[^a-z]*//'
}

# The name the halves ASK for, before any budget is applied: project, one
# hyphen, work. This is the one owner of how the halves join, so a caller that
# would rather refuse than accept a shortened name compares against this rather
# than reassembling the halves itself and drifting from what was assembled.
fm_herdr_full_name() {  # <project-short> <work...>
  local proj=$1; shift
  local work
  proj=$(fm_herdr_lead_name "$(fm_herdr_work_name "$proj")")
  work=$(fm_herdr_work_name "$@")
  if [ -z "$proj" ]; then
    fm_herdr_lead_name "$work"
  elif [ -z "$work" ]; then
    printf '%s' "$proj"
  else
    printf '%s-%s' "$proj" "$work"
  fi
}

# The full pane name, within the budget. Over-length truncates the WORK half;
# callers that would rather refuse than accept a name the captain did not choose
# compare against fm_herdr_full_name before calling.
fm_herdr_pane_name() {  # <project-short> <work...>
  local proj=$1; shift
  local full work room
  full=$(fm_herdr_full_name "$proj" "$@")
  [ "${#full}" -gt "$fm_herdr_name_max" ] || { printf '%s' "$full"; return 0; }
  proj=$(fm_herdr_lead_name "$(fm_herdr_work_name "$proj")")
  work=$(fm_herdr_work_name "$@")
  [ -n "$proj" ] || { printf '%s' "$full" | cut -c "1-$fm_herdr_name_max" | sed 's/-*$//'; return 0; }
  room=$(( fm_herdr_name_max - ${#proj} - 1 ))
  if [ "$room" -lt 1 ]; then
    printf '%s' "$proj" | cut -c "1-$fm_herdr_name_max" | sed 's/-*$//'
    return 0
  fi
  work=$(printf '%s' "$work" | cut -c "1-$room" | sed 's/-*$//')
  printf '%s-%s' "$proj" "$work"
}

# 0 when a name is one herdr will actually accept as an agent address. This is
# the check a slash fails, and the reason the separator is a hyphen.
fm_herdr_name_valid() {  # <name>
  case "$1" in
    '' ) return 1 ;;
    *[!a-z0-9_-]* ) return 1 ;;
    [!a-z]* ) return 1 ;;
  esac
  [ "${#1}" -le "$fm_herdr_name_max" ]
}

# --- workspaces -------------------------------------------------------------
#
# One workspace per project (the captain's standing order), and the workspace is
# resolved EXPLICITLY. `herdr tab create` without --workspace puts the tab in
# whatever workspace happens to be FOCUSED, which is luck, not targeting: it is
# how a crewmate for project A ends up in the captain's config workspace.
#
# Resolution order:
#   1. FM_HERDR_WORKSPACE — an explicit override; a label if one matches, else
#      taken as a literal workspace id. Refused loudly if it names nothing live,
#      so a typo cannot quietly become focus-luck again.
#   2. the workspace whose LABEL is the project name.
#   3. neither exists -> CREATE it, labelled for the project. That is the
#      documented policy: refusing would strand the first spawn into every newly
#      added project, and it is what the reconcile CLI below already does, so
#      the spawn path and the reconcile path agree instead of disagreeing.
# A creation failure is fatal to the caller — never a silent focus fallback.
#
# Ids are never hardcoded: `wJ` is a runtime value that does not survive a
# server restart.

fm_herdr_workspace_id() {  # <label>
  herdr workspace list 2>/dev/null | tr '{' '\n' \
    | grep -F "\"label\":\"$1\"" \
    | sed -n 's/.*"workspace_id":"\([^"]*\)".*/\1/p' | head -1
}

fm_herdr_workspace_exists() {  # <workspace-id>
  herdr workspace list 2>/dev/null | tr '{' '\n' | grep -qF "\"workspace_id\":\"$1\""
}

fm_herdr_workspace_for() {  # <project-label> <cwd>
  local label=$1 cwd=${2:-} ws out
  if [ -n "${FM_HERDR_WORKSPACE:-}" ]; then
    ws=$(fm_herdr_workspace_id "$FM_HERDR_WORKSPACE")
    [ -n "$ws" ] || ws=$FM_HERDR_WORKSPACE
    if fm_herdr_workspace_exists "$ws"; then printf '%s' "$ws"; return 0; fi
    echo "fm-herdr: FM_HERDR_WORKSPACE='$FM_HERDR_WORKSPACE' matches no live workspace" >&2
    return 1
  fi
  ws=$(fm_herdr_workspace_id "$label")
  if [ -n "$ws" ]; then printf '%s' "$ws"; return 0; fi
  out=$(herdr workspace create --cwd "$cwd" --label "$label" --no-focus 2>&1) || {
    echo "fm-herdr: could not create workspace '$label': $out" >&2; return 1; }
  ws=$(fm_herdr_field "$out" workspace_id)
  [ -n "$ws" ] || ws=$(fm_herdr_workspace_id "$label")
  [ -n "$ws" ] || { echo "fm-herdr: created workspace '$label' but no id came back" >&2; return 1; }
  printf '%s' "$ws"
}

# --- tabs and panes ---------------------------------------------------------

fm_herdr_tab_exists() {  # <workspace-id> <label>
  herdr tab list --workspace "$1" 2>/dev/null | tr '{' '\n' | grep -qF "\"label\":\"$2\""
}

# Creates the tab and prints the PANE ID it runs in. That id is what every agent
# verb below addresses, and what state/<id>.meta records as window=.
fm_herdr_new_tab() {  # <workspace-id> <label> <cwd>
  local ws=$1 label=$2 cwd=$3 out pane
  out=$(herdr tab create --workspace "$ws" --cwd "$cwd" --label "$label" --no-focus 2>&1) || {
    echo "fm-herdr: tab create failed: $out" >&2; return 1; }
  pane=$(fm_herdr_field "$out" pane_id)
  [ -n "$pane" ] || { echo "fm-herdr: tab create returned no pane id: $out" >&2; return 1; }
  printf '%s' "$pane"
}

# A shell pane, not an agent: `pane run` types the command line and submits it.
fm_herdr_run() {  # <pane> <shell-command>
  local out
  out=$(herdr pane run "$1" "$2" 2>&1) && return 0
  echo "fm-herdr: pane run failed: $out" >&2
  return 1
}

# Atomic, acknowledged delivery to a running AGENT. --wait makes herdr confirm
# the agent actually consumed the prompt — the acknowledgment tmux never had.
#
# Return codes are the whole contract, because "did it land" is the only
# question a supervisor actually has:
#   0  delivered AND acknowledged — the agent consumed it. From a non-working
#      agent that is herdr's --wait; from a WORKING one it is the observed
#      settle-then-working transition, because herdr's --wait "does not track
#      turns" and can be satisfied by the turn that was already running.
#   3  refused: the agent is blocked at an approval dialog, nothing was sent
#   4  delivered but NOT acknowledged
#   5  no agent detected in that pane: nothing delivered, nothing executed
#   1  failed
#
# WHY 4 IS NOT 1. herdr accepts the submission first and only then waits for a
# state change; when none arrives it returns agent_prompt_stalled AFTER the text
# has already gone in. Observed live against a claude TUI herdr reported as idle
# while it was still finishing its boot. Calling that a failure would be the
# worse of the two available errors: firstmate would re-send a steer that
# already landed and the crewmate would be told twice.
fm_herdr_prompt() {  # <pane> <text>
  local pane=$1 text=$2 out rc=0 state budget deadline poll settled
  budget=${FM_HERDR_SEND_TIMEOUT_MS:-15000}
  poll=${FM_HERDR_ACK_POLL:-0.25}

  # READ THE STATE FIRST. Which acknowledgment is available depends on it, and
  # the binary is explicit about why (herdr agent prompt --help):
  #
  #   "It does not track turns: if the agent is already working, that active
  #    turn's completion may match."
  #
  # So from a WORKING agent, --wait's verdict is not evidence about OUR prompt -
  # it can be satisfied by the turn that was already running. Leaning on it there
  # returned 0, "the agent consumed it", for a steer that had not started.
  state=$(fm_herdr_field "$(herdr agent get "$pane" 2>&1)" agent_status)

  if [ "$state" = working ]; then
    # Submit WITHOUT --wait: its answer here would be about the wrong turn, and
    # waiting on it would also block for the whole current turn to no purpose.
    out=$(herdr agent prompt "$pane" "$text" 2>&1) || rc=$?
    fm_herdr_prompt_classify "$pane" "$out" "$rc" && return 0 || rc=$?
    [ "$rc" = 200 ] || return "$rc"

    # A queued prompt is consumed when the current turn ENDS and a new one
    # BEGINS. That settle-then-working transition is the acknowledgment, and it
    # is the only one available here. Its absence within the budget is reported
    # as delivered-but-unconfirmed - never invented as success.
    deadline=$(( $(date +%s) + (budget / 1000) + 1 ))
    settled=0
    while [ "$(date +%s)" -lt "$deadline" ]; do
      state=$(fm_herdr_field "$(herdr agent get "$pane" 2>&1)" agent_status)
      case "$state" in
        working) [ "$settled" = 1 ] && return 0 ;;
        idle|done) settled=1 ;;
        blocked)
          echo "fm-herdr: $pane stopped at an approval dialog after the steer; delivery is unconfirmed" >&2
          return 4 ;;
      esac
      sleep "$poll"
    done
    echo "fm-herdr: $pane was mid-turn; the steer is queued but no new turn started within the budget." >&2
    echo "  Delivery is UNCONFIRMED, not acknowledged - and NOT re-sent, because re-sending" >&2
    echo "  a steer the crewmate already holds is the worse of the two errors." >&2
    return 4
  fi

  # From a non-working state --wait IS trustworthy: the binary requires an
  # observed state change before it matches, so a match means the agent moved
  # because of this prompt. --until is explicit so a change to herdr's default
  # cannot silently alter what "acknowledged" means here.
  out=$(herdr agent prompt "$pane" "$text" --wait \
          --until idle --until 'done' --until blocked \
          --timeout "$budget" 2>&1) || rc=$?
  fm_herdr_prompt_classify "$pane" "$out" "$rc" && return 0 || rc=$?
  [ "$rc" = 200 ] || return "$rc"
  return 0
}

# Shared outcome classification for a submission attempt.
# Returns 0 for a clean acknowledged result, 200 when the caller should carry on
# with its own confirmation, and otherwise the code the caller must return:
#   3 blocked (nothing sent) · 4 delivered-unconfirmed · 5 no agent · 1 failed
#
# The EXIT STATUS is authoritative. A dropped socket, a CLI parse error, an error
# envelope this list has never seen - none of them match the patterns, and all of
# them mean the steer did not land.
fm_herdr_prompt_classify() {  # <pane> <out> <rc>
  local pane=$1 out=$2 rc=$3
  case "$out" in
    *agent_blocked*)
      echo "fm-herdr: $pane is at an approval dialog; not overwriting it" >&2
      return 3 ;;
    *agent_prompt_stalled*|*'"code":"timeout"'*)
      echo "fm-herdr: $pane took the prompt but never changed state; delivery is unconfirmed, NOT re-sent" >&2
      return 4 ;;
    *agent_not_found*)
      # No agent in this pane. NOTHING is delivered, and nothing is executed:
      # forwarding the steer to `herdr pane run` would RUN it as a shell command.
      echo "fm-herdr: no agent detected in $pane; the steer was NOT delivered." >&2
      echo "  Nothing was executed - a pane holding a shell would have RUN the steer." >&2
      echo "  Peek the pane: the agent may have exited or may still be starting." >&2
      return 5 ;;
  esac
  if [ "$rc" -ne 0 ]; then
    echo "fm-herdr: prompt failed for $pane (herdr exited $rc): $out" >&2
    return 1
  fi
  case "$out" in
    *'{"error"'*)
      echo "fm-herdr: prompt failed for $pane: $out" >&2
      return 1 ;;
    '')
      echo "fm-herdr: prompt produced no response for $pane" >&2
      return 1 ;;
  esac
  return 200
}

# Keys are the trust-dialog clearing step, so a failure here has to SAY so.
# Swallowing both attempts left `fm-send.sh <pane> --key enter` exiting non-zero
# with no output at all under `set -eu` - the operator got a failed command and
# nothing to act on.
fm_herdr_send_key() {  # <pane> <key>
  local out
  herdr agent send-keys "$1" "$2" >/dev/null 2>&1 && return 0
  out=$(herdr pane send-keys "$1" "$2" 2>&1) && return 0
  echo "fm-herdr: could not send key '$2' to $1: ${out:-herdr gave no output}" >&2
  return 1
}

# SOURCE MATTERS, and the two sources are NOT interchangeable - do not unify
# them. `visible` is the current viewport, so it silently caps a read at one
# screen however many lines were asked for, and a peek that comes back short is
# indistinguishable from a quiet crewmate. `recent` is herdr's scrollback-backed
# source and is the equivalent of the `capture-pane -S -$N` this replaced, so it
# is the default for peeking. The probes that ask "what does the pane show RIGHT
# NOW" - the readiness marker, and the post-launch shell-error check - pass
# `visible` explicitly, because scrollback would let stale pre-launch noise
# answer a question about the present.
#
# The quiet variant is for those probes only: they poll, and a read that fails
# means "not ready yet" rather than something worth printing.
fm_herdr_read_quiet() {  # <pane> [lines] [source]
  local pane=$1 lines=${2:-40} src=${3:-recent}
  herdr agent read "$pane" --source "$src" --lines "$lines" --format text 2>/dev/null \
    || herdr pane read "$pane" --source "$src" --lines "$lines" --format text 2>/dev/null
}

# A read is the first step of the stale-wake and stuck-crewmate playbooks, so a
# failure has to SAY so - exactly as fm_herdr_send_key does. Swallowing both
# attempts left `fm-peek.sh <pane>` exiting non-zero with no output under
# `set -eu`, which made a dead pane and a quiet crewmate look identical to a
# supervisor.
#
# stderr is kept OUT of the returned text and only surfaced on failure. Folding
# it in with 2>&1 would print any warning, deprecation notice or socket retry
# herdr emits during a SUCCESSFUL read as if it were crewmate pane content, and
# peek is what a supervisor reads to decide whether a crewmate is wedged.
fm_herdr_read() {  # <pane> [lines] [source]
  local pane=$1 lines=${2:-40} src=${3:-recent} out err errfile
  if out=$(herdr agent read "$pane" --source "$src" --lines "$lines" --format text 2>/dev/null); then
    [ -z "$out" ] || printf '%s\n' "$out"
    return 0
  fi
  errfile=$(mktemp "${TMPDIR:-/tmp}/fm-herdr-read.XXXXXX")
  if out=$(herdr pane read "$pane" --source "$src" --lines "$lines" --format text 2>"$errfile"); then
    rm -f "$errfile"
    [ -z "$out" ] || printf '%s\n' "$out"
    return 0
  fi
  err=$(cat "$errfile" 2>/dev/null)
  rm -f "$errfile"
  echo "fm-herdr: could not read $pane: ${err:-herdr gave no output}" >&2
  return 1
}

fm_herdr_cwd() {  # <pane>
  fm_herdr_field "$(herdr pane get "$1" 2>/dev/null)" foreground_cwd
}

# A real lifecycle state, not a regex over rendered text - and that means
# reading the FIELD. An agent record carries terminal_title and
# terminal_title_stripped, which are rendered text, so a grep over the whole
# record calls a pane blocked at an approval dialog busy the moment its title
# happens to contain the word "working".
fm_herdr_is_busy() {  # <pane>
  [ "$(fm_herdr_field "$(herdr agent get "$1" 2>/dev/null)" agent_status)" = working ]
}

# Shell readiness, not agent readiness: at spawn time the pane holds a bare
# shell and `agent wait` would fail. The proof is positive — a marker echoed
# back on a line of its OWN, so the command echo cannot pass for the output.
# Inferring readiness from anything weaker is what left two secondmates as dead
# bare shells on 2026-08-26.
fm_herdr_wait_shell_ready() {  # <pane> [timeout-seconds]
  local pane=$1 timeout=${2:-${FM_SHELL_READY_TIMEOUT:-20}}
  local poll=${FM_SHELL_READY_POLL:-0.2} marker deadline waited
  marker="fmready$$$(od -An -N3 -tu4 /dev/urandom 2>/dev/null | tr -cd '0-9')"
  deadline=$(( $(date +%s) + timeout ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    fm_herdr_run "$pane" "printf '%s\\n' $marker" >/dev/null 2>&1 || return 1
    waited=0
    while [ "$waited" -lt 10 ]; do
      sleep "$poll"
      waited=$((waited + 1))
      if fm_herdr_read_quiet "$pane" 40 visible | grep -qx "$marker"; then return 0; fi
    done
  done
  return 1
}

# Post-launch verification. If the launch string reached the shell as text
# instead of starting the agent, the shell says so — and firstmate should fail
# loudly rather than record a meta for a pane that holds nothing.
#
# `visible`, deliberately, NOT the `recent` default: this asks what the pane
# shows right now. Read from scrollback, pre-launch noise - treehouse output,
# the readiness marker echoes, a shell-rc error - stays within the last 15 lines
# and produces a false "launch did not start an agent" that aborts a spawn whose
# agent in fact came up. This one is not the same question fm-peek asks.
fm_herdr_launch_failed() {  # <pane>
  fm_herdr_read_quiet "$1" 15 visible \
    | grep -qiE 'parse error|command not found|syntax error near|no such file or directory'
}

# Name the pane for the work. The SAME name goes in both slots — the tab label
# the captain reads, and the socket-API address herdr steers by.
#
# The tab label is the gated half and its failure is REPORTED: an unnamed tab is
# the exact defect this naming exists to remove, so it is never assumed. The
# agent rename is best effort by timing alone — herdr classifies an agent a beat
# after launch — and a spawn must not die waiting for it.
# Returns: 0 both named; 1 tab named but herdr has not classified an agent yet;
# 2 a real refusal - the tab rename failed, or the agent rename was refused for
# any reason other than the agent not existing yet.
fm_herdr_label() {  # <pane> <name>
  local pane=$1 name=$2 tab out
  if ! fm_herdr_name_valid "$name"; then
    echo "fm-herdr: '$name' is not a valid pane name (want ^[a-z][a-z0-9_-]{0,$((fm_herdr_name_max-1))}$)" >&2
    return 2
  fi
  tab=$(fm_herdr_field "$(herdr pane get "$pane" 2>/dev/null)" tab_id)
  if [ -z "$tab" ]; then
    echo "fm-herdr: no tab found for $pane; cannot name it" >&2
    return 2
  fi
  if ! out=$(herdr tab rename "$tab" "$name" 2>&1); then
    echo "fm-herdr: tab rename failed for $tab: $out" >&2
    return 2
  fi
  # The agent rename can legitimately be early: herdr classifies an agent a beat
  # after launch, so agent_not_found here means "not yet", not "refused". Any
  # OTHER failure - a duplicate name, a permission error, a server problem -
  # leaves the pane without the address it is supposed to be steered by, and
  # must be reported. Returning 1 for all of them told the caller every failure
  # was harmless startup lag.
  if ! out=$(herdr agent rename "$pane" "$name" 2>&1); then
    case "$out" in
      *agent_not_found*) return 1 ;;
      *)
        echo "fm-herdr: agent rename refused for $pane -> '$name': $out" >&2
        return 2 ;;
    esac
  fi
  return 0
}

# ALREADY GONE IS A SUCCESSFUL CLOSE. The desired end state is "no such pane",
# and a pane the captain closed by hand — or one herdr already reaped with its
# agent — reaches it without us. Verified against herdr 0.8.2: `pane get`,
# `tab close` and `pane close` ALL return rc=1 for an id that does not exist, so
# reading the exit code alone made an ordinary path fire teardown's "check for a
# leftover pane" warning and send firstmate hunting a tab that is not there.
# That dilutes the one signal this helper exists to produce. The envelope, not
# the exit code, is what distinguishes gone from unclosable.
fm_herdr_close() {  # <pane>
  local pane=$1 get tab out rc=0
  get=$(herdr pane get "$pane" 2>&1) || rc=$?
  if [ "$rc" != 0 ]; then
    case "$get" in *pane_not_found*|*tab_not_found*) return 0 ;; esac
    get=""
  fi
  tab=$(fm_herdr_field "$get" tab_id)
  if [ -n "$tab" ]; then
    out=$(herdr tab close "$tab" 2>&1) && return 0
    case "$out" in *pane_not_found*|*tab_not_found*) return 0 ;; esac
  fi
  out=$(herdr tab close "$pane" 2>&1) && return 0
  out=$(herdr pane close "$pane" 2>&1) && return 0
  case "$out" in *pane_not_found*|*tab_not_found*) return 0 ;; esac
  return 1
}

# Close the pane a meta recorded, on the surface that CREATED it.
#
# THE DEFECT THIS EXISTS FOR (Quarterdeck reject, attempt 1). fm-teardown.sh
# passed the meta's window= - a herdr pane id for every post-cutover crewmate -
# straight to `tmux kill-window`, swallowed the failure with `|| true`, deleted
# the meta and printed "teardown complete". The tab leaked, untracked and
# possibly still running an agent, while firstmate believed it was cleaned up.
#
# `<mux>` is the meta's mux= value: herdr for a post-cutover pane, empty or
# anything else for a tmux window still being drained. A close that cannot
# happen is REPORTED - swallowing it is what let the leak go unnoticed.
fm_herdr_close_pane() {  # <target> <mux>
  local target=$1 mux=${2:-}
  [ -n "$target" ] || return 0
  if [ "$mux" = herdr ]; then
    if fm_herdr_close "$target"; then return 0; fi
    echo "fm-herdr: could not close herdr pane $target; the tab may still be open" >&2
    return 1
  fi
  # DRAIN ONLY - a window that predates the cutover. Delete this branch when
  # fm_herdr_drain_pending reports nothing left in any home.
  if tmux kill-window -t "$target" 2>/dev/null; then return 0; fi
  # ALREADY GONE IS A SUCCESSFUL CLOSE, on this branch exactly as on the herdr
  # one above: kill-window fails for a window that no longer exists, and the
  # captain closing a finished window by hand is an ordinary path, not a leak.
  # Warning about it would send firstmate hunting a window that is not there and
  # dilute the one signal this helper exists to produce.
  #
  # But GONE MUST BE OBSERVED, never inferred from silence. An absent tmux, a
  # dropped server or any other unreadable listing also yields no matching line,
  # and treating that as gone reports a successful close for a window nothing
  # ever touched - teardown then prints no warning, deletes the meta and calls
  # itself complete, which is the exact leak this helper was written to stop.
  # So the LISTING itself has to succeed before its silence means anything; the
  # herdr branch above is the same rule, keyed on an explicit not-found envelope.
  local listing lrc=0
  listing=$(tmux list-windows -a -F '#{session_name}:#{window_name}' 2>/dev/null) || lrc=$?
  if [ "$lrc" = 0 ]; then
    if ! printf '%s\n' "$listing" | grep -qFx -- "$target"; then return 0; fi
    echo "fm-herdr: could not close tmux window $target; it may still be open" >&2
    return 1
  fi
  echo "fm-herdr: could not close tmux window $target and could not determine whether it is still open" >&2
  return 1
}

# --- resolution, and the drain ----------------------------------------------
#
# THE DRAIN, and why it is derived rather than listed. Crewmates spawned before
# this cutover live in tmux windows; their meta records `window=<session>:<name>`
# and has no `mux=` line, because the seam that would have written one did not
# exist yet. Those windows must stay readable, steerable and closable until they
# are torn down — a watcher that cannot read them is blind, and a teardown that
# cannot close them strands work that is still running, some of it carrying
# unlanded commits.
#
# The discriminator is the META, never a hardcoded inventory. A list would have
# to be right, and the one this migration was handed was not: it named four
# windows and missed three live crewmates with metas in another firstmate home,
# while naming two whose metas live somewhere the author had not enumerated. A
# meta-derived rule is correct under any inventory and needs no census, and it
# closes by itself — when no meta lacks `mux=herdr`, the drain is empty.
#
# Sets, for the caller:
#   FM_HERDR_TARGET  the pane id (herdr) or session:window (drain)
#   FM_HERDR_DRAIN   1 when this is a pre-cutover tmux window, 0 otherwise
#
# Accepts a bare firstmate window name (fm-xyz) resolved through this home's
# state/<id>.meta; an explicit target carrying a colon; or a plain tmux window
# name looked up across sessions, which is a drain-only convenience.
# shellcheck disable=SC2034  # both globals are the point: read by the caller, not here
fm_herdr_resolve() {  # <window-or-target> <state-dir>
  local want=$1 state=$2 meta window mux
  case "$want" in
    *:*)
      # An explicit target, checked FIRST exactly as the pre-collapse resolve
      # had it, so a session literally named `fm-something` still addresses
      # `fm-something:window` rather than being looked up as a task id.
      FM_HERDR_TARGET=$want
      # THE META FIRST. A recorded target is not a shape to be guessed at: if
      # this home has a meta whose window= is exactly this target, its mux= says
      # which surface minted it, and that is the answer. The shape test below is
      # the LAST RESORT, for a pane in another home that this home has no record
      # of.
      meta=$(grep -lFx "window=$want" "$state"/*.meta 2>/dev/null | head -1 || true)
      if [ -n "$meta" ]; then
        mux=$(grep '^mux=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
        if [ "$mux" = herdr ]; then FM_HERDR_DRAIN=0; else FM_HERDR_DRAIN=1; fi
      else
        # A herdr pane id is `w<id>:p<id>`, and BOTH halves are base-36, not
        # decimal: the pane counter rolls into letters at the tenth pane, so a
        # live server holds `wM:p9` and `wM:pA` side by side. Matching only
        # digits sent every pane past the ninth down the tmux path, at a session
        # that does not exist - peek and steer broke for exactly the crewmates a
        # busy fleet has most of. Anything else with a colon is a tmux
        # session:window, which is drain-only.
        #
        # The match is ANCHORED to the shape the binary actually emits, because
        # the same test errs both ways: a glob whose tails are `*` also swallows
        # `work:prod-fix`, `web:pane1` and `wide:print`, which are tmux
        # session:window pairs, and sends herdr verbs at them. Base-36 here
        # means UPPERCASE - verified against herdr 0.8.2, whose counters read
        # `wM:p9`, `wM:pA`, `wN:p1`, never a lowercase digit - so the lowercase
        # words that make a plausible tmux session stay on the drain path.
        if [[ $want =~ ^w[0-9A-Z]+:p[0-9A-Z]+$ ]]; then
          FM_HERDR_DRAIN=0
        else
          FM_HERDR_DRAIN=1
        fi
      fi
      ;;
    fm-*)
      meta="$state/${want#fm-}.meta"
      if [ ! -f "$meta" ]; then
        echo "error: no metadata for $want in $state; pass an explicit target to reach a pane outside this firstmate home" >&2
        return 1
      fi
      window=$(grep '^window=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
      [ -n "$window" ] || { echo "error: no window recorded in $meta" >&2; return 1; }
      mux=$(grep '^mux=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
      FM_HERDR_TARGET=$window
      if [ "$mux" = herdr ]; then FM_HERDR_DRAIN=0; else FM_HERDR_DRAIN=1; fi
      ;;
    *)
      window=$(tmux list-windows -a -F '#{session_name}:#{window_name}' 2>/dev/null | grep -m1 ":$want\$") \
        || { echo "error: no window named $want" >&2; return 1; }
      FM_HERDR_TARGET=$window
      FM_HERDR_DRAIN=1
      ;;
  esac
  return 0
}

# 0 while any pre-cutover tmux window is still accounted-for work. Once this
# returns 1 for every firstmate home, bin/fm-tmux-lib.sh has no drain left to
# serve and can be deleted. It is a question with an answer, not a date.
fm_herdr_drain_pending() {  # <state-dir>
  local state=${1:-} meta
  [ -d "$state" ] || return 1
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] || continue
    grep -q '^mux=herdr$' "$meta" || return 0
  done
  return 1
}

# --- the reconcile CLI ------------------------------------------------------
#
# Everything above is a library, and below runs only when this file is EXECUTED,
# so sourcing it never trips the caller's shell options.
#
# ONE DELIBERATE EXCEPTION, and it is not an oversight: sourcing runs
# `fm_herdr_session` once, which exports HERDR_SESSION when FM_HERDR_SESSION
# pins one. The export has to land in the CALLER's environment - a pin that
# moved this file's probe but not the herdr verbs is exactly the divergence that
# reported a fleet reachable while every verb aimed at a session that was not
# up. So sourcing does mutate the environment: HERDR_SESSION is inherited by
# processes this script itself forks - the herdr verbs it runs.
#
# IT DOES NOT REACH AN AGENT IN A PANE. A crewmate's shell is forked by the
# HERDR SERVER at `tab create`, not by fm-spawn, so no amount of exporting here
# lands in it; that is the same reason fm-spawn has to prepend FM_HOME and the
# operational overrides to the launch string rather than rely on inheritance.
# HERDR_SESSION rides in that same prefix (bin/fm-spawn.sh), which is the one
# way a pinned session reaches an agent that runs these scripts itself.

fm_herdr_cli() {
  set -euo pipefail
  # NOT `local FM_HOME`: declaring it local blanks the caller's value before the
  # default below can read it, which silently points the CLI at the wrong home.
  local home REGISTRY PROJECTS_DIR
  home="${FM_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  REGISTRY="$home/data/projects.md"
  PROJECTS_DIR="$home/projects"

  die() { printf 'fm-herdr: %s\n' "$1" >&2; exit 1; }
  require_server() {
    command -v herdr >/dev/null 2>&1 || die "herdr is not on PATH"
    fm_herdr_up || die "no herdr server is running — run \`herdr\` to start or attach it, then retry"
  }

  # --name: apply the naming convention to a live agent pane. Names BOTH slots -
  # the tab label the captain reads and the address herdr steers by - with the
  # same string, because they are the same name.
  if [ "${1:-}" = "--name" ]; then
    require_server
    [ $# -ge 4 ] || die "usage: --name <pane> <project-short> <what-the-work-is>"
    local pane=$2 proj=$3 name untruncated label_rc
    shift 3
    name=$(fm_herdr_pane_name "$proj" "$*")
    [ -n "$name" ] || die "'$proj' + '$*' leaves nothing usable as a name"
    # Refuse an unreadably long name rather than silently truncating it: a name
    # the captain did not choose is worse than being told to choose a shorter
    # one. (fm_herdr_pane_name truncates for callers that must not fail, e.g. a
    # spawn, where a cosmetic name must never abort the work.)
    untruncated=$(fm_herdr_full_name "$proj" "$*")
    [ "${#untruncated}" -le 28 ] \
      || die "'$untruncated' is ${#untruncated} chars; keep it under 28, e.g. afs-resource-registry"
    fm_herdr_name_valid "$name" \
      || die "'$name' is not a name herdr will accept as an address (want ^[a-z][a-z0-9_-]{0,31}$ - a slash is rejected)"
    label_rc=0
    fm_herdr_label "$pane" "$name" || label_rc=$?
    case "$label_rc" in
      0) printf 'named %s -> %s\n' "$pane" "$name" ;;
      # rc=1 is not a refusal: the tab carries the name and herdr has simply not
      # classified an agent in the pane yet.
      1) printf 'named %s -> %s (tab only; no agent detected in the pane yet)\n' "$pane" "$name" ;;
      *) die "herdr did not accept '$name' for $pane" ;;
    esac
    exit 0
  fi

  # Default: reconcile one workspace per project against data/projects.md.
  local APPLY=0
  [ "${1:-}" = "--apply" ] && APPLY=1
  [ -f "$REGISTRY" ] || die "no project registry at $REGISTRY"
  require_server

  local made=0 skipped=0 missing=0 name cwd
  printf '%-26s %-9s %s\n' PROJECT STATUS CWD
  printf '%-26s %-9s %s\n' "-------" "------" "---"
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    cwd="$PROJECTS_DIR/$name"
    if [ ! -d "$cwd" ]; then
      printf '%-26s %-9s %s\n' "$name" "NO-DIR" "$cwd"; missing=$((missing+1)); continue
    fi
    # fm_herdr_workspace_id is the one owner of this question. `grep -w` over the
    # raw listing treated `-` as a word boundary, so project `fm` matched a
    # workspace labelled `fm-x` and was reported as already present - it never got
    # its own workspace, and its first spawn landed in someone else's.
    if [ -n "$(fm_herdr_workspace_id "$name")" ]; then
      printf '%-26s %-9s %s\n' "$name" "exists" "$cwd"; skipped=$((skipped+1)); continue
    fi
    if [ "$APPLY" = 1 ]; then
      herdr workspace create --cwd "$cwd" --label "$name" --no-focus >/dev/null \
        && { printf '%-26s %-9s %s\n' "$name" "CREATED" "$cwd"; made=$((made+1)); } \
        || printf '%-26s %-9s %s\n' "$name" "FAILED" "$cwd"
    else
      printf '%-26s %-9s %s\n' "$name" "would-add" "$cwd"; made=$((made+1))
    fi
  done < <(sed -n 's/^- \([a-z0-9][a-z0-9._-]*\) .*/\1/p' "$REGISTRY")

  printf '\n'
  if [ "$APPLY" = 1 ]; then
    printf 'created %s, already present %s, no directory %s\n' "$made" "$skipped" "$missing"
  else
    printf 'plan only: %s to create, %s present, %s missing a directory\n' "$made" "$skipped" "$missing"
    printf 'run with --apply to create them.\n'
  fi
}

# Executed, not sourced? The standard idiom: when this file is run directly,
# $0 is its own path; when sourced, $0 is the caller's. (A caller contriving
# `bash -c '. "$0"' <this file>` would defeat that - source it as "$1" instead.)
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  fm_herdr_cli "$@"
fi
