#!/usr/bin/env bash
# tests/fm-backend-herdr-smoke.test.sh - real herdr smoke test for the herdr
# session-provider adapter (bin/backends/herdr.sh), P2 of
# data/fm-backend-design-d7 (herdr-addendum.md), extended for the P3
# workspace-per-home pass (AGENTS.md task herdr-sm-spaces-k4). Mirrors
# tests/fm-backend-tmux-smoke.test.sh's structure: every other suite fakes the
# CLI, this one talks to a REAL herdr server - but ALWAYS on a private, named,
# throwaway HERDR_SESSION (never the default session), so it never touches a
# captain's real herdr usage. Skips cleanly when herdr (or jq) is not
# installed, so CI/dev machines without herdr are unaffected.
#
# Safety (2026-07-02 incident, see tests/herdr-test-safety.sh): cleanup uses
# ONLY herdr_safe_stop_and_delete, never a bare/ambient `herdr server stop` -
# that command killed the captain's live default herdr server twice in
# production because HERDR_SESSION-based targeting (env var OR inline prefix)
# is not reliably honored once another herdr server is already running.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"

SESSION="fm-lab-backend-smoke-$$"
export HERDR_SESSION="$SESSION"
SM_SCRATCH=
cleanup_all() {
  [ -n "$SM_SCRATCH" ] && rm -rf "$SM_SCRATCH"
  herdr_safe_stop_and_delete "$SESSION"
}
trap cleanup_all EXIT
fm_herdr_lab_prepare "$SESSION" || fail "could not prepare isolated Herdr lab session"

# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "fm_backend_source herdr failed"

# --- version gate + container ensure -----------------------------------------

fm_backend_herdr_version_check || fail "version_check failed against the real installed herdr"
pass "real herdr: version_check accepts the installed binary's protocol"

# fm_backend_herdr_container_ensure now echoes
# "<session>:<workspace_id>\t<seeded_default_tab_id>" (the second field empty
# when the call ADOPTED a pre-existing workspace rather than creating a fresh
# one - docs/herdr-backend.md "Default-tab prune"). Split on the guaranteed
# single tab character; only fm_backend_herdr_create_task is ever allowed to
# act on the seeded tab id, and only for the container that just created it.
CONTAINER_RAW=$(fm_backend_herdr_container_ensure /tmp) || fail "container_ensure failed"
CONTAINER=${CONTAINER_RAW%%$'\t'*}
SEEDED_TAB_ID=${CONTAINER_RAW#*$'\t'}
case "$CONTAINER" in
  "$SESSION":w*) : ;;
  *) fail "container_ensure returned an unexpected shape: $CONTAINER" ;;
esac
[ -n "$SEEDED_TAB_ID" ] || fail "the first container_ensure in a brand-new isolated session must CREATE the workspace and report its seeded default tab id"
pass "real herdr: container_ensure starts the isolated session's server, creates the firstmate workspace ($CONTAINER), and reports its seeded default tab id ($SEEDED_TAB_ID)"

# A second container_ensure must reuse (ADOPT) the same workspace (idempotent)
# and report an EMPTY seeded tab id - the created-vs-adopted gate that fixes
# the 2026-07-02 self-kill incident (docs/herdr-backend.md "Default-tab
# prune"): only the call that actually just created a workspace may identify
# a tab as prunable.
CONTAINER2_RAW=$(fm_backend_herdr_container_ensure /tmp) || fail "second container_ensure failed"
CONTAINER2=${CONTAINER2_RAW%%$'\t'*}
SEEDED_TAB_ID2=${CONTAINER2_RAW#*$'\t'}
[ "$CONTAINER2" = "$CONTAINER" ] || fail "container_ensure is not idempotent: '$CONTAINER' vs '$CONTAINER2'"
[ -z "$SEEDED_TAB_ID2" ] || fail "an ADOPTED (reused) workspace must report an EMPTY seeded default tab id, got '$SEEDED_TAB_ID2'"
pass "real herdr: container_ensure is idempotent (reuses/adopts the existing firstmate workspace, reports no seeded default tab on adoption)"

# --- create_task + duplicate refusal + default-tab prune ---------------------

LABEL="fm-smoke1"
TASK_IDS=$(fm_backend_herdr_create_task "$CONTAINER" "$LABEL" /tmp "$SEEDED_TAB_ID") || fail "create_task failed"
read -r TAB_ID PANE_ID <<EOF
$TASK_IDS
EOF
if [ -z "$TAB_ID" ] || [ -z "$PANE_ID" ]; then
  fail "create_task did not return tab/pane ids"
fi
TARGET="$SESSION:$PANE_ID"

# The happy path: a fresh workspace's seeded default tab (label "1") must be
# pruned once the first real task tab is created alongside it, leaving
# exactly one clean fm-<id> task tab.
POST_CREATE_TABS=$(herdr tab list --workspace "${CONTAINER#*:}" --session "$SESSION" 2>&1)
POST_CREATE_COUNT=$(printf '%s' "$POST_CREATE_TABS" | jq -r '.result.tabs? // [] | length')
[ "$POST_CREATE_COUNT" = 1 ] || fail "expected exactly 1 tab (the seeded default pruned) after the first real task tab, got $POST_CREATE_COUNT: $POST_CREATE_TABS"
printf '%s' "$POST_CREATE_TABS" | jq -e --arg t "$SEEDED_TAB_ID" '.result.tabs[] | select(.tab_id == $t)' >/dev/null 2>&1 \
  && fail "the seeded default tab ($SEEDED_TAB_ID) should have been pruned but is still present: $POST_CREATE_TABS"
pass "real herdr: create_task prunes the freshly-created workspace's seeded default tab, leaving exactly one clean fm-<id> task tab"

# NOTE: create_task no longer refuses EVERY same-labeled duplicate
# unconditionally - a same-labeled tab whose pane hosts no registered agent is
# now a close-and-replace candidate (the restored-layout husk fix below), so
# testing "$LABEL"/$PANE_ID again here would actually succeed and silently
# replace this suite's own primary task pane, which the rest of this file
# still depends on ($TARGET, the restart-stability check, send/capture/kill).
# The duplicate-refusal and husk-replacement behaviors are covered next,
# each against its own independent throwaway tab.

# --- restored-layout husk close-and-replace, against the REAL binary --------
# (docs/herdr-backend.md "Known gaps" / "ID stability across a server
# restart"). herdr persists and restores its whole session layout across a
# server restart, and a restored fm-<id> task tab comes back a HUSK: a dead
# pane, or (verified above and empirically in "ID stability") a plain
# agent-less shell. Both throwaway tabs below are independent of $TAB_ID/
# $PANE_ID/$TARGET (this suite's primary task, which the rest of the file
# still depends on) so neither scenario disturbs it.

# 1. A genuinely LIVE duplicate (a real registered agent, via herdr's own
#    `pane report-agent`) must still refuse exactly as before.
LIVE_DUP_LABEL="fm-smoke-livedup"
LIVE_DUP_IDS=$(fm_backend_herdr_create_task "$CONTAINER" "$LIVE_DUP_LABEL" /tmp) || fail "could not create the live-duplicate scenario's tab"
read -r LIVE_DUP_TAB_ID LIVE_DUP_PANE_ID <<EOF
$LIVE_DUP_IDS
EOF
if [ -z "$LIVE_DUP_TAB_ID" ] || [ -z "$LIVE_DUP_PANE_ID" ]; then
  fail "live-duplicate scenario tab creation did not return ids"
fi
herdr pane report-agent "$LIVE_DUP_PANE_ID" --source fm-smoke-test --agent fm-smoke-live-agent --state idle --session "$SESSION" >/dev/null 2>&1 \
  || fail "could not register a live agent on the live-duplicate scenario's pane"
if fm_backend_herdr_create_task "$CONTAINER" "$LIVE_DUP_LABEL" /tmp >/dev/null 2>&1; then
  fail "REGRESSION: create_task should refuse a duplicate label whose pane hosts a genuinely live registered agent (idle counts as live)"
fi
herdr pane get "$LIVE_DUP_PANE_ID" --session "$SESSION" >/dev/null 2>&1 \
  || fail "REGRESSION: the live-duplicate scenario's pane should have survived the refused create_task call untouched"
pass "real herdr: create_task refuses a same-labeled tab whose pane hosts a genuinely live registered agent (unchanged behavior)"
fm_backend_herdr_kill "$SESSION:$LIVE_DUP_PANE_ID"

# 2. A husk (no registered agent at all - the restored-plain-shell shape)
#    must be CLOSED AND REPLACED instead of refused.
HUSK_LABEL="fm-smoke-husk1"
HUSK_IDS=$(fm_backend_herdr_create_task "$CONTAINER" "$HUSK_LABEL" /tmp) || fail "could not create the husk-simulation tab"
read -r HUSK_TAB_ID HUSK_PANE_ID <<EOF
$HUSK_IDS
EOF
if [ -z "$HUSK_TAB_ID" ] || [ -z "$HUSK_PANE_ID" ]; then
  fail "husk-simulation tab creation did not return ids"
fi
herdr agent get "$HUSK_PANE_ID" --session "$SESSION" >/dev/null 2>&1 \
  && fail "husk-simulation setup is wrong: this pane should have NO registered agent yet"
REPLACED_IDS=$(fm_backend_herdr_create_task "$CONTAINER" "$HUSK_LABEL" /tmp) \
  || fail "REGRESSION: create_task should close-and-replace a same-labeled tab whose pane hosts no registered agent, not refuse it"
read -r NEW_HUSK_TAB_ID NEW_HUSK_PANE_ID <<EOF
$REPLACED_IDS
EOF
if [ -z "$NEW_HUSK_TAB_ID" ] || [ -z "$NEW_HUSK_PANE_ID" ]; then
  fail "husk close-and-replace did not return new tab/pane ids"
fi
[ "$NEW_HUSK_PANE_ID" != "$HUSK_PANE_ID" ] || fail "husk close-and-replace returned the SAME pane id - it did not actually replace anything"
if herdr pane get "$HUSK_PANE_ID" --session "$SESSION" >/dev/null 2>&1; then
  fail "REGRESSION: the old husk pane should have been closed by close-and-replace, but it still exists"
fi
HUSK_WS_TABS=$(herdr tab list --workspace "${CONTAINER#*:}" --session "$SESSION" 2>&1)
printf '%s' "$HUSK_WS_TABS" | jq -e --arg t "$NEW_HUSK_TAB_ID" '.result.tabs[] | select(.tab_id == $t)' >/dev/null 2>&1 \
  || fail "REGRESSION: the replacement tab is missing from the workspace's own tab list"
pass "real herdr: create_task closes and replaces a same-labeled tab whose pane hosts no registered agent (the restored-husk shape), leaving the workspace intact"
fm_backend_herdr_kill "$SESSION:$NEW_HUSK_PANE_ID"

# --- workspace-per-home: a secondmate-shaped home gets its OWN space --------
# (docs/herdr-backend.md "Task container shape", AGENTS.md task
# herdr-sm-spaces-k4). Reuses this suite's own isolated $SESSION - a SECOND,
# distinct workspace inside the SAME session, never a second session. Placed
# here (both workspaces' tabs still alive) so the restart-stability check
# right after it exercises the true multi-workspace shape, not a
# possibly-emptied-and-auto-closed primary workspace.

SM_SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-herdr-smoke-sm.XXXXXX")
SM_HOME="$SM_SCRATCH/secondmate-home"
mkdir -p "$SM_HOME"
printf 'smoketest-sm1\n' > "$SM_HOME/.fm-secondmate-home"

SM_CONTAINER_RAW=$(FM_HOME="$SM_HOME" fm_backend_herdr_container_ensure /tmp) || fail "secondmate-shaped container_ensure failed"
SM_CONTAINER=${SM_CONTAINER_RAW%%$'\t'*}
SM_SEEDED_TAB_ID=${SM_CONTAINER_RAW#*$'\t'}
case "$SM_CONTAINER" in
  "$SESSION":w*) : ;;
  *) fail "secondmate container_ensure returned an unexpected shape: $SM_CONTAINER" ;;
esac
[ "$SM_CONTAINER" != "$CONTAINER" ] || fail "a secondmate-shaped home must get a DIFFERENT workspace than the primary's, got the same: $SM_CONTAINER"
[ -n "$SM_SEEDED_TAB_ID" ] || fail "the secondmate-shaped home's container_ensure must CREATE its own workspace and report its seeded default tab id"
pass "real herdr: a secondmate-shaped home (.fm-secondmate-home) gets its OWN herdr workspace, distinct from the primary's, in the SAME session"

SM_WSID=${SM_CONTAINER#*:}
SM_LABEL_REAL=$(herdr workspace list --session "$SESSION" 2>&1 | jq -r --arg id "$SM_WSID" '.result.workspaces[]? | select(.workspace_id == $id) | .label')
[ "$SM_LABEL_REAL" = "2ndmate-smoketest-sm1" ] || fail "the secondmate workspace's real herdr label should be 2ndmate-smoketest-sm1, got '$SM_LABEL_REAL'"
pass "real herdr: the secondmate-shaped home's workspace is labeled 2ndmate-<secondmate-id> in herdr itself"

SM_TASK_LABEL="fm-smtask1"
SM_TASK_IDS=$(FM_HOME="$SM_HOME" fm_backend_herdr_create_task "$SM_CONTAINER" "$SM_TASK_LABEL" /tmp "$SM_SEEDED_TAB_ID") || fail "secondmate create_task failed"
read -r SM_TAB_ID SM_PANE_ID <<EOF
$SM_TASK_IDS
EOF
if [ -z "$SM_TAB_ID" ] || [ -z "$SM_PANE_ID" ]; then
  fail "secondmate create_task did not return tab/pane ids"
fi
pass "real herdr: a task spawned into the secondmate-shaped home lands as a tab inside the secondmate's OWN workspace"

# list_live for each home must never see the OTHER home's task.
PRIMARY_LIVE=$(fm_backend_herdr_list_live "$SESSION")
case "$PRIMARY_LIVE" in
  *"$SM_TASK_LABEL"*) fail "the primary home's list_live must not see a secondmate-shaped home's task"$'\n'"$PRIMARY_LIVE" ;;
esac
SM_LIVE=$(FM_HOME="$SM_HOME" fm_backend_herdr_list_live "$SESSION")
case "$SM_LIVE" in
  *"$SM_TASK_LABEL"*) : ;;
  *) fail "the secondmate-shaped home's list_live did not see its own task"$'\n'"$SM_LIVE" ;;
esac
case "$SM_LIVE" in
  *"$LABEL"*) fail "the secondmate-shaped home's list_live must not see the primary's task ($LABEL)"$'\n'"$SM_LIVE" ;;
esac
pass "real herdr: list_live stays scoped to each home's own workspace - neither home sees the other's tasks"

# --- restart stability in the MULTI-workspace shape --------------------------
# P2 (herdr-verification-p2.md "ID stability") verified this for a single
# workspace only. Both this suite's workspaces (and their tabs/panes) must
# still resolve, unchanged, after a `session stop` + fresh server restart, all
# scoped to this suite's OWN isolated $SESSION - never the default session.

fm_herdr_lab_stop "$SESSION" >/dev/null 2>&1 \
  || fail "could not stop the isolated session for the restart-stability check"
sleep 0.5
fm_backend_herdr_server_ensure "$SESSION" || fail "the isolated session's server did not come back up after the stop"

POST_LIST=$(herdr workspace list --session "$SESSION" 2>&1)
POST_PRIMARY_ID=$(printf '%s' "$POST_LIST" | jq -r '.result.workspaces[]? | select(.label == "firstmate") | .workspace_id')
POST_SM_ID=$(printf '%s' "$POST_LIST" | jq -r --arg l "2ndmate-smoketest-sm1" '.result.workspaces[]? | select(.label == $l) | .workspace_id')
[ "$POST_PRIMARY_ID" = "${CONTAINER#*:}" ] || fail "the primary workspace id did not survive the restart: before=${CONTAINER#*:} after=$POST_PRIMARY_ID"
[ "$POST_SM_ID" = "$SM_WSID" ] || fail "the secondmate workspace id did not survive the restart: before=$SM_WSID after=$POST_SM_ID"

POST_PANE=$(herdr pane get "$PANE_ID" --session "$SESSION" 2>/dev/null | jq -r '.result.pane.pane_id // empty')
[ "$POST_PANE" = "$PANE_ID" ] || fail "the primary task's pane id did not survive the restart: before=$PANE_ID after=$POST_PANE"
POST_SM_PANE=$(herdr pane get "$SM_PANE_ID" --session "$SESSION" 2>/dev/null | jq -r '.result.pane.pane_id // empty')
[ "$POST_SM_PANE" = "$SM_PANE_ID" ] || fail "the secondmate task's pane id did not survive the restart: before=$SM_PANE_ID after=$POST_SM_PANE"
pass "real herdr: BOTH workspace ids/labels AND both tasks' pane ids survive a session stop + fresh server restart (multi-workspace shape)"

fm_backend_herdr_kill "$SESSION:$SM_PANE_ID"

# --- send_text_line (atomic run) ---------------------------------------------

fm_backend_herdr_send_text_line "$TARGET" "echo captain-on-deck-line" \
  || fail "send_text_line failed"
sleep 0.5
out=$(fm_backend_herdr_capture "$TARGET" 20) || fail "capture failed after send_text_line"
case "$out" in
  *captain-on-deck-line*) : ;;
  *) fail "real herdr: send_text_line did not run and echo the line"$'\n'"$out" ;;
esac
pass "real herdr: send_text_line runs a command atomically (pane run) and its output is capturable"

# --- send_literal + send_key(Enter), the two-step launch-command form -------

fm_backend_herdr_send_literal "$TARGET" 'echo literal-then-key-captain' \
  || fail "send_literal failed"
sleep 0.2
fm_backend_herdr_send_key "$TARGET" Enter || fail "send_key Enter failed"
sleep 0.5
out=$(fm_backend_herdr_capture "$TARGET" 20) || fail "capture failed after send_literal+send_key"
case "$out" in
  *literal-then-key-captain*) : ;;
  *) fail "real herdr: send_literal + send_key(Enter) did not submit and echo the line"$'\n'"$out" ;;
esac
pass "real herdr: send_literal + send_key Enter submit as two separate steps (verified: send-text does NOT auto-submit)"

# --- current_path -------------------------------------------------------------

fm_backend_herdr_send_text_line "$TARGET" "cd /tmp"
sleep 0.3
p=$(fm_backend_herdr_current_path "$TARGET") || fail "current_path failed"
case "$p" in
  */tmp) : ;;
  *) fail "real herdr: current_path did not report the pane's cwd after cd /tmp, got '$p'" ;;
esac
pass "real herdr: current_path reads the pane's live cwd"

# --- busy_state on a real claude harness (verified in herdr-verification-p2.md) ---

if [ "${FM_HERDR_SMOKE_REAL_CLAUDE:-0}" = 1 ] && command -v claude >/dev/null 2>&1; then
  fm_backend_herdr_send_literal "$TARGET" "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions --print 'say the word HERDRSMOKEOK and nothing else'"
  sleep 0.2
  fm_backend_herdr_send_key "$TARGET" Enter
  found_working=0
  for _ in $(seq 1 20); do
    bs=$(fm_backend_herdr_busy_state "$TARGET" 2>/dev/null)
    [ "$bs" = busy ] && { found_working=1; break; }
    [ "$bs" = idle ] && break
    sleep 0.5
  done
  [ "$found_working" -eq 1 ] || echo "note: never observed agent_status=working for the real claude run (timing-dependent, not fatal)" >&2
  # Wait for completion regardless, bounded.
  for _ in $(seq 1 40); do
    bs=$(fm_backend_herdr_busy_state "$TARGET" 2>/dev/null)
    [ "$bs" = idle ] && break
    sleep 0.5
  done
  out=$(fm_backend_herdr_capture "$TARGET" 30)
  case "$out" in
    *HERDRSMOKEOK*) pass "real herdr: agent_status busy/idle detection tracks a real claude turn, and capture shows its output" ;;
    *) echo "note: claude output marker not observed within the bound (timing-dependent, not fatal to this smoke suite)" >&2 ;;
  esac
elif [ "${FM_HERDR_SMOKE_REAL_CLAUDE:-0}" != 1 ]; then
  echo "note: FM_HERDR_SMOKE_REAL_CLAUDE=1 not set; skipping the real-agent busy_state check" >&2
else
  echo "note: claude not installed; skipping the real-agent busy_state check" >&2
fi

# --- kill -----------------------------------------------------------------

fm_backend_herdr_kill "$TARGET"
if herdr pane get "$PANE_ID" --session "$SESSION" >/dev/null 2>&1; then
  fail "kill did not remove the pane"
fi
# Best-effort contract: killing an already-gone pane must not error.
fm_backend_herdr_kill "$TARGET" || fail "kill on an already-dead target must stay best-effort (never fail)"
pass "real herdr: kill removes the pane and is idempotent/best-effort"

# --- list_live (label-based recovery discovery) ------------------------------

# Real firstmate spawns always re-run container_ensure immediately before
# create_task (bin/fm-spawn.sh), never reusing a container reference from an
# earlier spawn. This test must do the same: the kill above closed the only
# remaining tab in $CONTAINER's workspace, and closing a workspace's last tab
# deletes the workspace itself (verified real-herdr behavior), so the stale
# $CONTAINER from container_ensure at test start no longer names a live
# workspace.
CONTAINER_RAW=$(fm_backend_herdr_container_ensure /tmp) || fail "container_ensure for the second task failed"
CONTAINER=${CONTAINER_RAW%%$'\t'*}
SEEDED_TAB_ID=${CONTAINER_RAW#*$'\t'}
[ -n "$SEEDED_TAB_ID" ] || fail "the workspace was deleted when its last tab was killed, so this container_ensure must CREATE a fresh one and report its seeded default tab id"
LABEL2="fm-smoke2"
TASK_IDS2=$(fm_backend_herdr_create_task "$CONTAINER" "$LABEL2" /tmp "$SEEDED_TAB_ID") || fail "second create_task failed"
read -r _TAB_ID2 PANE_ID2 <<EOF
$TASK_IDS2
EOF
live=$(fm_backend_herdr_list_live "$SESSION")
assert_contains_local() { case "$1" in *"$2"*) : ;; *) fail "$3"$'\n'"--- got ---"$'\n'"$1" ;; esac; }
assert_contains_local "$live" "$LABEL2" "list_live did not report the freshly created task tab by label"
pass "real herdr: list_live discovers a live task tab by fm-<id> label"

fm_backend_herdr_kill "$SESSION:$PANE_ID2"

cleanup_all
trap - EXIT
