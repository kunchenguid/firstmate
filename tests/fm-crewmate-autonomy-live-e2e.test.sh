#!/usr/bin/env bash
# tests/fm-crewmate-autonomy-live-e2e.test.sh - opt-in live guard proving that a
# crewmate launched under the autonomy flags bin/fm-spawn.sh actually passes
# today can (a) reach its composer unattended and (b) append to its own status
# file, which lives OUTSIDE its worktree.
#
# Why this file exists: the status append is the load-bearing crewmate contract.
# bin/fm-brief.sh hands every worker `echo "{state}: ..." >> $FM_HOME/state/<id>.status`
# as the ONLY way to report done, blocked, or needs-decision, and that path is
# outside the worktree the harness sandboxes to. Whether a sandboxed, non-
# bypassing launch posture still permits it is a property of the harness vendor's
# sandbox and approval classifier, not of firstmate's code, so no stub and no
# transcribed flag table can answer it. Only a real agent, driven for real, can.
#
# The two halves are measured separately and reported separately, because they
# fail for different reasons and only one of them is a firstmate defect:
#   1. the unattended-launch reading is taken with NO key sent at all, so a
#      harness that parks behind a trust, approval, or update modal is recorded
#      as exactly that rather than being typed into (see reach_composer);
#   2. the write reading then costs ONE short turn, in which the agent is asked
#      to run the very append bin/fm-brief.sh hands it and to answer with a
#      separate token, so reply-without-write is distinguishable from no-reply.
#
# The lab home is created under $HOME and NEVER under TMPDIR or /tmp. That is not
# cosmetic: codex's `workspace-write` sandbox grants /tmp and $TMPDIR as writable
# roots by default, so a status file placed there would be writable for reasons
# that have nothing to do with the crewmate contract and this guard would pass
# while proving nothing. A real FM_HOME lives beside the firstmate checkout under
# $HOME, and the lab mirrors that shape.
#
# Unlike tests/fm-harness-liveness-drift-live-e2e.test.sh and
# tests/fm-herdr-agent-free-proof-live-e2e.test.sh, this guard DOES submit a
# prompt and therefore does consume model tokens - one short turn per installed
# harness. That cost is unavoidable: a shell command run outside the agent proves
# nothing about the agent's own sandbox.
#
# Standard CI has neither harness binaries nor credentials, so this is opt-in and
# on-demand. Run it after any harness upgrade, after any change to a launch
# template in bin/fm-spawn.sh, and before trusting the refreshed evidence in
# docs/verification/runtime-backends.md "Crewmate autonomy and the status-file
# write contract".
#
# Always runs on a private, named, throwaway Herdr lab session, never the default
# one (tests/herdr-test-safety.sh).
set -u

if [ "${FM_CREWMATE_AUTONOMY_LIVE:-0}" != 1 ]; then
  echo "skip: set FM_CREWMATE_AUTONOMY_LIVE=1 to run the live crewmate autonomy and status-write guard"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || fail "herdr not found"
command -v jq >/dev/null 2>&1 || fail "jq not found (required by the herdr adapter)"
command -v git >/dev/null 2>&1 || fail "git not found"

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

SESSION="fm-lab-autonomy-$$"
export HERDR_SESSION="$SESSION"
LAB=
CLEANED=0
cleanup_all() {
  [ "$CLEANED" = 0 ] || return 0
  CLEANED=1
  [ -n "$LAB" ] && rm -rf "$LAB"
  herdr_safe_stop_and_delete "$SESSION"
}
trap cleanup_all EXIT
fm_herdr_lab_prepare "$SESSION" || fail "could not prepare isolated Herdr lab session"

# See the header: $HOME, never TMPDIR, or codex's default writable roots make the
# write measurement vacuous.
LAB="$HOME/.fm-crewmate-autonomy-lab-$$"
mkdir -p "$LAB/state" "$LAB/wt" || fail "could not create the lab home at $LAB"
LAB=$(cd "$LAB" && pwd -P)
# A real crewmate is launched in a git worktree, and cursor's --workspace wants a
# repository root; give the lab worktree the same shape.
git -C "$LAB/wt" init -q >/dev/null 2>&1 || fail "could not initialise the lab worktree"

# Label the lab's Herdr workspace from the lab home, so it can never collide with
# the captain's live per-home workspace.
export FM_HOME="$LAB"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-cursor-lib.sh"
fm_backend_source herdr || fail "fm_backend_source herdr failed"

CONTAINER_RAW=$(fm_backend_herdr_container_ensure "$LAB/wt") || fail "container_ensure failed"
CONTAINER=${CONTAINER_RAW%%$'\t'*}
SEEDED_TAB_ID=${CONTAINER_RAW#*$'\t'}

HERDR_VERSION=$(herdr --version 2>/dev/null | head -1 | tr -d '\r')
[ -n "$HERDR_VERSION" ] || HERDR_VERSION=unknown
note "herdr: $HERDR_VERSION"
note "lab home: <\$HOME>/${LAB##*/} (status files outside the lab worktree)"

# Mirror bin/fm-spawn.sh's own binary resolution, so this guard launches the same
# binary firstmate would.
resolve_harness_binary() {  # <harness>
  local harness=$1 candidate
  # cursor first, and never through a bare PATH lookup: it installs as
  # `cursor-agent` plus the legacy alias `agent`, while a `cursor` on PATH is
  # routinely the editor launcher rather than the agent, which answers a
  # --trust launch with an Electron warning and exits. fm_cursor_resolve_binary
  # is the verified owner fm-spawn itself uses.
  if [ "$harness" = cursor ]; then
    fm_cursor_resolve_binary 2>/dev/null && return 0
    return 1
  fi
  candidate=$(command -v "$harness" 2>/dev/null || true)
  if [ -n "$candidate" ] && [ -x "$candidate" ]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  return 1
}

# The autonomy posture under measurement, quoted from bin/fm-spawn.sh's launch
# templates with only the positional brief removed. Anything else would measure a
# posture firstmate does not ship.
launch_command() {  # <harness> <binary> <worktree>
  case "$1" in
    claude) printf '%s' "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false $2 --permission-mode auto" ;;
    codex) printf '%s' "$2 -s workspace-write -a never" ;;
    cursor) printf '%s' "env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS -u CURSOR_INVOKED_AS $2 --trust --auto-review --sandbox enabled --workspace $3" ;;
    *) return 1 ;;
  esac
}

foreground_names() {  # <pane>
  fm_backend_herdr_cli "$SESSION" pane process-info --pane "$1" 2>/dev/null \
    | jq -r '[.result.process_info.foreground_processes[]? | "\(.name)/\(.argv0 // .argv[0] // "")"] | join(" ")' 2>/dev/null
}

foreground_pids() {  # <pane>
  fm_backend_herdr_cli "$SESSION" pane process-info --pane "$1" 2>/dev/null \
    | jq -r '.result.process_info.foreground_processes[]?.pid | select(type == "number") | floor' 2>/dev/null
}

pane_tail() {  # <pane> <lines>
  fm_backend_herdr_capture "$SESSION:$1" "$2" 2>/dev/null | tr '\n' '|'
}

# end_harness: stop only the processes this guard launched into the pane, leaving
# the pane and its tab in place, so the next harness still has its container.
end_harness() {  # <pane>
  local pid
  for pid in $(foreground_pids "$1"); do
    kill -TERM "$pid" 2>/dev/null || true
  done
  for _ in $(seq 1 100); do
    case "$(foreground_names "$1")" in
      ''|*sh/*sh*) return 0 ;;
    esac
    sleep 0.1
  done
  for pid in $(foreground_pids "$1"); do
    kill -KILL "$pid" 2>/dev/null || true
  done
}

# numbered_menu_index / numbered_menu_selected: read a vendor TUI menu of the
# shape "> 1. Yes, continue" / "  2. No, quit" by its own printed labels rather
# than by a hardcoded keystroke count, so a vendor that reorders or inserts an
# option moves the guard's cursor with it instead of silently changing what the
# guard answers.
numbered_menu_index() {  # <screen> <label-pattern> -> index
  printf '%s\n' "$1" | sed -n 's/^[^0-9]*\([0-9]\)\. *\(.*\)$/\1 \2/p' \
    | grep -i -- "$2" | head -1 | cut -d' ' -f1
}

numbered_menu_selected() {  # <screen> -> index of the currently highlighted row
  # The highlighted row is the one carrying a selection marker before its
  # number; every other row is indented with whitespace only. Matching "some
  # non-space, non-digit character before the digit" covers the markers the
  # vendors actually print (>, U+203A, U+276F) without pinning any of them.
  printf '%s\n' "$1" | grep -E '^[[:space:]]*[^[:space:][:digit:]][[:space:]]*[0-9]+\.' \
    | head -1 | sed -E 's/^[^0-9]*([0-9]+)\..*/\1/'
}

select_numbered_option() {  # <target> <screen> <label-pattern>
  local target=$1 screen=$2 pattern=$3 want cur step
  want=$(numbered_menu_index "$screen" "$pattern")
  cur=$(numbered_menu_selected "$screen")
  case "$want$cur" in ''|*[!0-9]*) return 1 ;; esac
  step=$cur
  while [ "$step" -lt "$want" ]; do
    fm_backend_herdr_send_key "$target" Down || return 1
    sleep 0.3
    step=$((step + 1))
  done
  while [ "$step" -gt "$want" ]; do
    fm_backend_herdr_send_key "$target" Up || return 1
    sleep 0.3
    step=$((step - 1))
  done
  fm_backend_herdr_send_key "$target" Enter
}

# composer_settled: an empty composer that STAYS empty for a whole settle window.
#
# A single empty verdict is NOT safe to act on. Observed live: codex 0.150.1
# rendered a classifiable empty composer and raised its update-available modal a
# moment later, and a run of this guard that trusted the earlier read submitted
# into that modal - whose preselected row is "Update now" - and upgraded the
# codex CLI on the machine. Every key this guard sends into a live harness is
# gated on a composer that is still a composer for the whole window, which is
# what makes a late modal impossible to race. The classifier alone is the test:
# a modal screen classifies pending or unknown, never empty, and unlike a text
# signature it cannot be fooled by a dismissed modal still sitting in scrollback.
COMPOSER_SETTLE_SECONDS=${FM_CREWMATE_AUTONOMY_SETTLE_SECONDS:-10}
composer_settled() {  # <target>
  local target=$1 deadline=$((SECONDS + COMPOSER_SETTLE_SECONDS))
  while [ "$SECONDS" -lt "$deadline" ]; do
    [ "$(fm_backend_composer_state herdr "$target" 2>/dev/null)" = empty ] || return 1
    sleep 1
  done
  return 0
}

# reach_composer: drive <pane> to a proven-empty composer WITHOUT ever answering a
# question the guard cannot read, and set READY_VIA to how it got there:
#
#   unattended - empty with no key sent at all; this is the guarantee under test
#   <steps>    - empty only after the listed startup gates were cleared, each one
#                named in READY_VIA in the order it appeared
#   blocked    - never empty; the caller reports the pane instead of guessing
#
# Two rules keep this honest. First, phase one sends NOTHING, because typing into
# a modal answers it: an earlier run of this guard submitted its prompt into
# Claude's trust dialog, selected "No, exit", and destroyed the reading. Second,
# the only gate this guard ACCEPTS is the first-launch directory-trust prompt,
# which .agents/skills/harness-adapters/SKILL.md already tells the captain to
# accept by hand after a spawn; every other gate is DECLINED by its own printed
# decline option, so the guard never widens the trust the launch flags grant and
# never measures a posture more permissive than the one firstmate ships. An
# unrecognised trust-shaped prompt is refused outright rather than guessed at.
#
# tests/fm-composer-matrix-live-e2e.test.sh takes the narrower path of declining
# every modal, because an empty composer is all it needs; this guard has to get
# past the prompt to measure the write contract behind it.
READY_VIA=blocked
# Wall-clock, not a poll count: one composer read is a full pane fetch, so a
# fixed iteration budget silently becomes minutes.
REACH_ROUND_SECONDS=${FM_CREWMATE_AUTONOMY_REACH_SECONDS:-40}
REACH_ROUNDS=6
reach_composer() {  # <harness> <pane>
  local harness=$1 pane=$2 target="$SESSION:$2" round deadline verdict screen step
  READY_VIA=
  for round in $(seq 1 "$REACH_ROUNDS"); do
    deadline=$((SECONDS + REACH_ROUND_SECONDS))
    while [ "$SECONDS" -lt "$deadline" ]; do
      verdict=$(fm_backend_composer_state herdr "$target" 2>/dev/null)
      if [ "$verdict" = empty ] && composer_settled "$target"; then
        [ -n "$READY_VIA" ] || READY_VIA=unattended
        return 0
      fi
      sleep 0.2
    done
    [ "$round" -lt "$REACH_ROUNDS" ] || break
    screen=$(fm_backend_herdr_capture "$target" 60 2>/dev/null)
    step=
    if printf '%s\n' "$screen" | grep -qF 'Yes, I trust this folder'; then
      # Claude Code's workspace-trust prompt: an UNNUMBERED menu whose accept row
      # sits directly below the preselected "No, exit".
      fm_backend_herdr_send_key "$target" Down || return 1
      sleep 0.3
      fm_backend_herdr_send_key "$target" Enter || return 1
      step=accepted-workspace-trust
    elif printf '%s\n' "$screen" | grep -qiF 'trust the contents of this directory'; then
      select_numbered_option "$target" "$screen" 'yes, continue' || return 1
      step=accepted-directory-trust
    elif printf '%s\n' "$screen" | grep -qiF 'Hooks need review'; then
      # Declined, never "Trust all": letting hooks run would grant the measured
      # agent capabilities the launch flags never asked for.
      select_numbered_option "$target" "$screen" 'continue without trusting' || return 1
      step=declined-hook-trust
    elif printf '%s\n' "$screen" | grep -qi 'update available'; then
      # Escape, never Enter: Enter on codex's update dialog RUNS the upgrade.
      fm_backend_herdr_send_key "$target" Escape || return 1
      step=dismissed-update-offer
    elif printf '%s\n' "$screen" | grep -qi 'trust'; then
      # An unrecognised trust-shaped prompt. Never guess at it.
      return 1
    else
      fm_backend_herdr_send_key "$target" Escape || return 1
      step=dismissed-startup-modal
    fi
    note "$harness: $step"
    READY_VIA="${READY_VIA:+$READY_VIA,}$step"
    sleep 1
  done
  READY_VIA=blocked
  return 1
}

CHECKED=0
SKIPPED=
DENIED=
BLOCKED=

# The three adapters whose launch templates carry an explicit autonomy or sandbox
# posture. An adapter that gains one belongs here too.
for harness in claude codex cursor; do
  if ! bin_path=$(resolve_harness_binary "$harness"); then
    SKIPPED="$SKIPPED $harness"
    note "skip: $harness is not installed on this machine, so its autonomy posture is unverified here"
    continue
  fi

  version=$("$bin_path" --version 2>/dev/null | head -1 | tr -d '\r') || version=
  [ -n "$version" ] || version="unknown"

  TASK_IDS=$(fm_backend_herdr_create_task "$CONTAINER" "fm-auto-$harness" "$LAB/wt" "$SEEDED_TAB_ID") \
    || fail "$harness ($version): could not create a lab tab"
  SEEDED_TAB_ID=
  read -r _TAB_ID PANE_ID <<EOF
$TASK_IDS
EOF
  [ -n "$PANE_ID" ] || fail "$harness ($version): create_task returned no pane id"
  TARGET="$SESSION:$PANE_ID"

  launch=$(launch_command "$harness" "$bin_path" "$LAB/wt") \
    || fail "$harness ($version): no launch posture is recorded for this harness"
  fm_backend_herdr_send_text_line "$TARGET" "$launch" \
    || fail "$harness ($version): could not launch it in the lab pane"

  # Wait until the harness's OWN executable owns the pane foreground, so the rest
  # is measured against a running harness rather than the shell that launched it.
  bin_base=${bin_path##*/}
  running=0
  for _ in $(seq 1 300); do
    case "$(foreground_names "$PANE_ID")" in
      *"$bin_base"*) running=1; break ;;
    esac
    sleep 0.2
  done
  names=$(foreground_names "$PANE_ID")
  [ "$running" = 1 ] || fail \
    "$harness $version: '$bin_base' never owned the pane foreground, so nothing about its autonomy posture was measured. Observed foreground name/argv0 pairs [$names]. Pane tail: $(pane_tail "$PANE_ID" 40)"

  if ! reach_composer "$harness" "$PANE_ID"; then
    BLOCKED="$BLOCKED $harness"
    CHECKED=$((CHECKED + 1))
    printf 'not ok - %s\n' \
      "UNATTENDED LAUNCH: $harness $version, launched with the flags bin/fm-spawn.sh ships in a worktree path it has never seen, never presented an empty composer, and what is on its screen is not a modal this guard knows how to clear safely. Nothing was submitted, so this reading did not answer it. Pane tail: $(pane_tail "$PANE_ID" 60)" >&2
    end_harness "$PANE_ID"
    continue
  fi
  case "$READY_VIA" in
    unattended)
      pass "unattended launch: $harness $version reaches an empty composer with no key sent"
      ;;
    *)
      note "$harness $version: NOT unattended - reached its composer only via $READY_VIA (see the record in docs/verification/runtime-backends.md)"
      ;;
  esac

  TOKEN="FMWROTE${harness}$$$RANDOM"
  # A DISTINCT reply token: the write token also appears in whatever tool-call
  # transcript the harness renders, so counting it could confirm a reply the
  # harness never gave.
  REPLY_TOKEN="FMREPLY${harness}$$$RANDOM"
  STATUS_FILE="$LAB/state/$harness-$$.status"
  # Exactly the append bin/fm-brief.sh gives every worker, at exactly the place it
  # gives it: outside the worktree, under the crewmate's FM_HOME.
  #
  # The prompt asks for the file to be READ BACK, not just written, because an
  # agent that simply answers without touching its shell is indistinguishable
  # from an agent the sandbox refused, and both are wrong answers here. Demanding
  # either the file's contents or the exact error text forces a tool call and
  # makes "refused" and "never tried" tell themselves apart in the pane.
  PROMPT="Use your shell tool to append the line: done: $TOKEN   to the file $STATUS_FILE   Then read that file back with your shell tool and reply with only $REPLY_TOKEN followed by the file's exact contents. If any step fails, reply with only $REPLY_TOKEN followed by the exact error text."

  # Last check before the only Enter this guard ever sends into a live harness.
  composer_settled "$TARGET" || fail \
    "$harness $version: the composer stopped being a composer between the readiness gate and the submit, so nothing was sent. Pane tail: $(pane_tail "$PANE_ID" 60)"

  verdict=$(fm_backend_herdr_send_text_submit "$TARGET" "$PROMPT" 3 0.4 0.4) \
    || fail "$harness $version: send_text_submit failed to run"

  replied=0
  wrote=0
  for _ in $(seq 1 180); do
    [ "$wrote" = 1 ] || { [ -s "$STATUS_FILE" ] && grep -qF "done: $TOKEN" "$STATUS_FILE" 2>/dev/null && wrote=1; }
    if [ "$replied" = 0 ]; then
      # The reply token appears once in the submitted prompt; a second
      # occurrence is the harness's own reply.
      occurrences=$(fm_backend_herdr_capture "$TARGET" 200 2>/dev/null | grep -F -c "$REPLY_TOKEN" || true)
      [ "${occurrences:-0}" -ge 2 ] && replied=1
    fi
    [ "$wrote" = 1 ] && [ "$replied" = 1 ] && break
    sleep 1
  done

  tail_evidence=$(pane_tail "$PANE_ID" 60)

  [ "$replied" = 1 ] || fail \
    "$harness $version: reached its composer ($READY_VIA) but never answered a one-line prompt within 180s, so the write contract behind it could not be measured. Submit verdict '$verdict'. Pane tail: $tail_evidence"

  note "$harness $version: ready=$READY_VIA submit=$verdict reply=landed"

  if [ "$wrote" != 1 ]; then
    DENIED="$DENIED $harness"
    printf 'not ok - %s\n' \
      "CREWMATE WRITE CONTRACT: $harness $version answered a prompt but could NOT append to its own status file outside its worktree ($STATUS_FILE). bin/fm-brief.sh makes that append the only way a worker reports done, blocked, or needs-decision, so under this launch posture such a worker is mute. Pane tail: $tail_evidence" >&2
  else
    pass "crewmate write contract: $harness $version appends to its status file outside its worktree"
  fi

  CHECKED=$((CHECKED + 1))
  end_harness "$PANE_ID"
done

[ "$CHECKED" -gt 0 ] || fail \
  "no measured harness is installed here, so this run proved nothing; install at least one of claude, codex, or cursor before trusting a pass"

if [ -n "$SKIPPED" ]; then
  note "unverified on this machine (not installed):$SKIPPED"
fi
note "checked $CHECKED installed harness(es) on herdr $HERDR_VERSION"

if [ -n "$BLOCKED" ]; then
  fail "the launch posture bin/fm-spawn.sh ships parks behind an unrecognised blocker for:$BLOCKED"
fi

if [ -n "$DENIED" ]; then
  fail "the status-file write contract is BROKEN under today's launch posture for:$DENIED"
fi

cleanup_all
trap - EXIT
