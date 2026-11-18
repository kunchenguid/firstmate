#!/usr/bin/env bash
# fm-boot-resume-lib.sh - single owner of the boot-resume decision surface: the
# gates (kill switch, unattended posture, boot identity, per-boot idempotence),
# primary-pane resolution across running herdr sessions, the guarded primary
# restore, the secondmate fallback sweep, and the bounded attempt ledger with
# park markers. Entry points that drive this library:
#   bin/fm-boot-resume.sh        - the boot-time systemd oneshot
#   bin/fm-watchdog-beat.sh      - the recurring watcher-beat watchdog tick
#   bin/fm-boot-resume-install.sh- renders and installs the user units
# docs/boot-resume.md owns the operator contract (gates, install, rehearsal,
# what only a real reboot can prove).
#
# Restore philosophy (the S5 away-autonomy decision): restore THROUGH the
# primary, never around it. The one mechanism that brings back the captain's
# exact conversation, the locked session-start sweeps (secondmate liveness
# auto-respawn), the wake-queue drain, and the watcher auto-arm chain is a live
# primary harness session; every one of those paths already exists and is
# supervised. So the restore finds the pane herdr's reboot restore left behind
# (exact match: the recorded state/.lock-session conversation id against
# herdr's per-pane agent_session.value), starts the same interactive agent in
# it with --resume, and submits one standing recovery prompt; the primary's own
# SessionStart/Stop hooks then re-establish everything else through the
# existing safe paths. A blind script relaunch of recorded workers is
# deliberately NOT attempted: no-mistakes run rules, duplicate-worker guards,
# and fresh dispatch receipts are judgment the stuck-crewmate-recovery skill
# owns, and this library never discards or forces anything.
#
# Gates, in order (every one must pass before any action):
#   1. kill switch        config/boot-resume-off present -> typed skip line, exit 0.
#   2. posture            an away record stands (bin/fm-afk-contract.sh mode
#                         prints away) OR an active goal exists (bin/fm-goal.sh
#                         active). A present captain needs nothing restored.
#   3. boot idempotence   (boot path only) state/.boot-resume-boot already
#                         holds this boot id -> already handled this boot.
#   4. primary aliveness  state/.lock names a live verified harness -> nothing
#                         to restore; the watchdog takes over from there.
# Only `dead`/`missing` secondmate probe verdicts authorize a fallback
# relaunch (the shared recovery contract in fm-secondmate-liveness-lib.sh);
# ambiguous, unreadable, and unverified endpoints are never touched, and the
# watcher's own park markers (.secondmate-relaunch-bound-<id>) are honored so
# this sweep can never retry past the budget the ordinary tick already set.
#
# Attempt ledger: every restore/nudge action appends
# "<epoch>\t<kind>\t<outcome>" to state/.boot-resume-attempts; more than
# FM_BOOT_RESUME_ATTEMPT_MAX (2) outcomes of one kind inside
# FM_BOOT_RESUME_ATTEMPT_WINDOW (3600s) parks that kind in
# state/.boot-resume-parked-<kind> and leaves exactly one durable inbox note,
# so a boot loop can never spend an unbounded retry budget or spam the inbox.
#
# Test seams: with FM_TEST_SEAM=1 (armed by tests/lib.sh), the file named by
# FM_TEST_BOOT_RESUME_SHIM is sourced after this library so a suite can
# override the wrapper functions (fm_btr_herdr, fm_btr_goal_active,
# fm_btr_sm_probe, fm_btr_sm_relaunch, fm_btr_inbox_note) with hermetic fakes;
# FM_TEST_BOOT_ID pins the boot identity. Normal operation never reads them.

# shellcheck source=bin/fm-wake-lib.sh
. "${FM_BTR_LIB_DIR:?}/fm-wake-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "${FM_BTR_LIB_DIR:?}/fm-session-lock-lib.sh"
# The secondmate recovery contract (probe, per-mate lock, ledger, guarded
# relaunch); it self-sources bin/fm-backend.sh.
# shellcheck source=bin/fm-secondmate-liveness-lib.sh
. "${FM_BTR_LIB_DIR:?}/fm-secondmate-liveness-lib.sh"

FM_BTR_STATE=${FM_STATE_OVERRIDE:-${FM_HOME:?}/state}
FM_BTR_CONFIG=${FM_CONFIG_OVERRIDE:-$FM_HOME/config}
FM_BTR_LOG="$FM_BTR_STATE/boot-resume.log"
FM_BTR_ATTEMPT_LEDGER="$FM_BTR_STATE/.boot-resume-attempts"
FM_BTR_BOOT_MARKER="$FM_BTR_STATE/.boot-resume-boot"
FM_BTR_HERDR_WAIT_SECS=${FM_BOOT_RESUME_HERDR_WAIT_SECS:-120}
FM_BTR_AGENT_START_TIMEOUT_MS=${FM_BOOT_RESUME_AGENT_START_TIMEOUT_MS:-120000}
FM_BTR_ATTEMPT_MAX=${FM_BOOT_RESUME_ATTEMPT_MAX:-2}
FM_BTR_ATTEMPT_WINDOW=${FM_BOOT_RESUME_ATTEMPT_WINDOW:-3600}
# Mirrors bin/fm-watch.sh's secondmate tick budget so both owners spend from
# the same allowance shape (this sweep keeps its own counters inside the shared
# per-mate ledgers the tick also reads).
FM_BTR_SM_TIMEOUT=${FM_SECONDMATE_LIVENESS_TIMEOUT:-120}
FM_BTR_SM_MAX_ATTEMPTS=${FM_SECONDMATE_LIVENESS_MAX_ATTEMPTS:-3}
FM_BTR_SM_WINDOW=${FM_SECONDMATE_LIVENESS_WINDOW_SECS:-3600}

# Bounded, timestamped log; every entry carries the boot id so a post-reboot
# read can tell this boot's actions from the pre-crash tail.
fm_btr_log() {  # <line>
  local line=$1 dir
  dir=$(dirname "$FM_BTR_LOG")
  mkdir -p "$dir" 2>/dev/null || return 0
  printf '%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(fm_btr_boot_id)" "$line" >> "$FM_BTR_LOG" || return 0
  if tail -n 400 "$FM_BTR_LOG" > "$FM_BTR_LOG.tmp" 2>/dev/null; then
    mv -f "$FM_BTR_LOG.tmp" "$FM_BTR_LOG" 2>/dev/null || rm -f "$FM_BTR_LOG.tmp"
  else
    rm -f "$FM_BTR_LOG.tmp"
  fi
  return 0
}

fm_btr_boot_id() {
  if [ -n "${FM_TEST_BOOT_ID:-}" ]; then
    printf '%s' "$FM_TEST_BOOT_ID"
    return 0
  fi
  cat /proc/sys/kernel/random/boot_id 2>/dev/null || printf 'boot-id-unavailable'
}

fm_btr_kill_switch_engaged() {
  [ -e "$FM_BTR_CONFIG/boot-resume-off" ]
}

# Posture gate: an away record stands or an active goal exists. Wraps the two
# owners of those verdicts rather than re-deriving either.
fm_btr_posture_away() {
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$FM_BTR_STATE" \
    "${FM_BTR_LIB_DIR}/fm-afk-contract.sh" mode 2>/dev/null | grep -qx 'away'
}

fm_btr_goal_active() {
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$FM_BTR_STATE" \
    "${FM_BTR_LIB_DIR}/fm-goal.sh" active >/dev/null 2>&1
}

fm_btr_posture_active() {
  fm_btr_posture_away || fm_btr_goal_active
}

# Read-only lock classification through the session-lock owner. Prints the
# state word (free|held|stale|unknown|unreadable); never acquires anything.
fm_btr_lock_state() {
  fm_session_lock_inspect "$FM_BTR_STATE"
  printf '%s' "$FM_LOCK_INSPECT_STATE"
}

fm_btr_boot_handled() {
  [ "$(cat "$FM_BTR_BOOT_MARKER" 2>/dev/null || true)" = "$(fm_btr_boot_id)" ]
}

fm_btr_mark_boot_handled() {
  printf '%s\n' "$(fm_btr_boot_id)" > "$FM_BTR_BOOT_MARKER" 2>/dev/null || \
    fm_btr_log "boot marker $FM_BTR_BOOT_MARKER unwritable; idempotence limited to this run"
}

# All herdr access goes through one wrapper so a suite can pin a fake binary.
fm_btr_herdr() {  # <herdr-args...>
  command -v herdr >/dev/null 2>&1 || return 127
  herdr "$@"
}

# Bounded readiness wait: the herdr server (herdr-bucket@ units) restores the
# panes this restore relaunches agents into; right after boot it may still be
# starting. One bound, no polling storm: 2s sleeps up to the wait bound.
fm_btr_herdr_wait() {
  local waited=0
  while ! fm_btr_herdr session list >/dev/null 2>&1; do
    [ "$waited" -lt "$FM_BTR_HERDR_WAIT_SECS" ] || return 1
    sleep 2
    waited=$((waited + 2))
  done
  return 0
}

fm_btr_herdr_sessions_running() {
  fm_btr_herdr session list --json 2>/dev/null | \
    jq -r '.sessions[]? | select(.running == true) | .name' 2>/dev/null
}

fm_btr_recorded_session_id() {
  fm_session_lock_recorded_session_id "$FM_BTR_STATE"
}

# Resolve the pane the reboot left for the primary: exact match of the recorded
# conversation id against herdr's per-pane agent_session.value, restricted to
# the home's own cwd as a second signal. On success sets
# FM_BTR_PRIMARY_SESSION and FM_BTR_PRIMARY_PANE (this is a global-result
# function, never captured into a subshell, so the failure reason
# FM_BTR_PRIMARY_WHY survives) and returns 0; otherwise sets only the why and
# returns 1 (unresolvable) or 2 (ambiguous). A cwd-only or focused-pane guess
# is deliberately refused: several panes share the home cwd on a real fleet
# day, and typing an agent start into the captain's wrong tab is exactly the
# silent mis-restore this must never do.
FM_BTR_PRIMARY_WHY=
FM_BTR_PRIMARY_SESSION=
FM_BTR_PRIMARY_PANE=
fm_btr_primary_pane() {
  local sid sessions out panes count
  FM_BTR_PRIMARY_WHY=
  sid=$(fm_btr_recorded_session_id) || { FM_BTR_PRIMARY_WHY="no recorded primary session id in $FM_BTR_STATE/.lock-session"; return 1; }
  if [ -s "$FM_BTR_CONFIG/boot-resume-herdr-session" ]; then
    sessions=$(head -n 1 "$FM_BTR_CONFIG/boot-resume-herdr-session")
  else
    sessions=$(fm_btr_herdr_sessions_running)
  fi
  [ -n "$sessions" ] || { FM_BTR_PRIMARY_WHY="no running herdr session to search"; return 1; }
  while IFS= read -r sessions; do
    [ -n "$sessions" ] || continue
    out=$(fm_btr_herdr --session "$sessions" agent list 2>/dev/null) || continue
    panes=$(printf '%s' "$out" | jq -r --arg id "$sid" --arg home "$FM_HOME" '
      .result.agents[]?
      | select(.agent == "claude")
      | select(.agent_session.value == $id)
      | select((.cwd // "") == $home)
      | .pane_id') || continue
    count=$(printf '%s' "$panes" | grep -c .)
    [ "$count" -gt 1 ] && { FM_BTR_PRIMARY_WHY="session id $sid matches more than one pane in herdr session $sessions"; return 2; }
    if [ "$count" -eq 1 ]; then
      FM_BTR_PRIMARY_SESSION=$sessions
      FM_BTR_PRIMARY_PANE=$panes
      return 0
    fi
  done <<EOF
$sessions
EOF
  FM_BTR_PRIMARY_WHY="no herdr pane records primary session $sid"
  return 1
}

# The claude argv for the restored primary: the permission default every
# fm-spawn claude launch uses, plus this home's config/boot-resume-primary-args
# words (e.g. --model sonnet --effort high), plus the exact-conversation
# resume. One arg per output line so callers keep array discipline.
fm_btr_claude_args() {  # <session-id-or-empty>
  local sid=$1 line
  printf '%s\n' --dangerously-skip-permissions
  if [ -s "$FM_BTR_CONFIG/boot-resume-primary-args" ]; then
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      case "$line" in \#*) continue ;; esac
      # shellcheck disable=SC2086 # Config words are shell words by contract.
      printf '%s\n' $line
    done < "$FM_BTR_CONFIG/boot-resume-primary-args"
  fi
  [ -n "$sid" ] && printf '%s\n' --resume "$sid"
}

# The standing recovery prompt submitted to the restored primary. It names the
# situation and points at the skills that own each recovery; it never restates
# their procedures (one-owner rule).
fm_btr_boot_prompt() {
  local posture='an away record stands'
  fm_btr_posture_away || posture='an active goal stands'
  printf '%s' "The WSL host rebooted while $posture. bin/fm-boot-resume.sh restored this session automatically. Your SessionStart hook already ran session start: read its digest, then recover recorded workers per stuck-crewmate-recovery (fm-control relaunch with fresh dispatch receipts), keep the standing away contract or goal, and arm supervision per watcher-continuity. Never discard unlanded work; never force an endpoint."
}

# Durable, idempotent operator note (the captain's out-of-band surface): a
# repeated request id replays the original instead of writing a second note.
fm_btr_inbox_note() {  # <request-id> <text>
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$FM_BTR_STATE" \
    "${FM_BTR_LIB_DIR}/fm-inbox.sh" note --request-id "$1" -- "$2" >/dev/null 2>&1
}

fm_btr_attempts_recent() {  # <kind>
  local kind=$1 cutoff now
  [ -f "$FM_BTR_ATTEMPT_LEDGER" ] || { printf '0\n'; return 0; }
  now=$(date +%s)
  cutoff=$((now - FM_BTR_ATTEMPT_WINDOW))
  awk -F'\t' -v k="$kind" -v c="$cutoff" \
    '$1 >= c && $2 == k { n++ } END { print n + 0 }' "$FM_BTR_ATTEMPT_LEDGER" 2>/dev/null || printf '0\n'
}

fm_btr_attempt_ledger() {  # <kind> <outcome>
  mkdir -p "$FM_BTR_STATE" 2>/dev/null || return 1
  printf '%s\t%s\t%s\n' "$(date +%s)" "$1" "$2" >> "$FM_BTR_ATTEMPT_LEDGER"
}

fm_btr_parked() {  # <kind>
  [ -e "$FM_BTR_STATE/.boot-resume-parked-$1" ]
}

fm_btr_park() {  # <kind> <reason>
  printf '%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$2" > "$FM_BTR_STATE/.boot-resume-parked-$1" 2>/dev/null || true
  fm_btr_log "parked $1: $2"
  fm_btr_inbox_note "boot-resume-parked-$1-$(fm_btr_boot_id)" \
    "boot-resume: $1 recovery parked after $FM_BTR_ATTEMPT_MAX attempts in ${FM_BTR_ATTEMPT_WINDOW}s: $2. The kill switch is config/boot-resume-off; recovery re-arms when the park marker is removed or the window passes."
}

# Budget check shared by both actors: returns 0 (budget available), 1 (parked
# already), 2 (out of budget, caller parks). Never mutates anything.
fm_btr_budget() {  # <kind>
  fm_btr_parked "$1" && return 1
  [ "$(fm_btr_attempts_recent "$1")" -lt "$FM_BTR_ATTEMPT_MAX" ] || return 2
  return 0
}

# The secondmate fallback sweep: runs only when the primary restore failed, so
# the mates do not wait on one broken conversation. Reuses the shared recovery
# contract verbatim (per-mate liveness lock serializes against the session-start
# sweep and the watcher tick; only dead/missing verdicts authorize a relaunch;
# the tick's park markers and per-mate ledgers bound the budget) - this
# function only owns the loop and its typed log lines.
fm_btr_sm_probe() {  # <meta> <id>
  fm_secondmate_liveness_probe "$1" "$2" poll
}

fm_btr_sm_relaunch() {  # <meta> <id>
  fm_secondmate_liveness_relaunch "$1" "$2" "$FM_BTR_SM_TIMEOUT"
}

fm_btr_secondmate_sweep() {
  local meta id
  [ -d "$FM_BTR_STATE" ] || return 0
  for meta in "$FM_BTR_STATE"/*.meta; do
    [ -f "$meta" ] || continue
    grep -q '^kind=secondmate$' "$meta" 2>/dev/null || continue
    id=${meta##*/}
    id=${id%.meta}
    case "$id" in ''|*[!A-Za-z0-9._-]*) continue ;; esac
    fm_secondmate_liveness_lock "$id" || continue
    if ! fm_btr_sm_probe "$meta" "$id"; then
      fm_secondmate_liveness_unlock "$id"
      continue
    fi
    case "$FM_SM_LIVE_STATUS" in
      relaunchable)
        if fm_btr_parked "secondmate-$id" || [ -e "$FM_BTR_STATE/.secondmate-relaunch-bound-$id" ]; then
          fm_btr_log "secondmate $id still $FM_SM_LIVE_STATE; relaunch already bounded"
        elif [ "$(fm_secondmate_liveness_recent_attempts "$id" "$FM_BTR_SM_WINDOW")" -ge "$FM_BTR_SM_MAX_ATTEMPTS" ]; then
          printf '%s\t%s\n' "$(date +%s)" "$FM_SM_LIVE_STATE" > "$FM_BTR_STATE/.secondmate-relaunch-bound-$id" 2>/dev/null || true
          fm_btr_log "secondmate $id auto-relaunch paused after $FM_BTR_SM_MAX_ATTEMPTS attempts; endpoint $FM_SM_LIVE_STATE"
        elif fm_btr_sm_relaunch "$meta" "$id"; then
          fm_btr_log "secondmate $id relaunched after $FM_SM_LIVE_CAUSE ($FM_SM_LIVE_WHERE)"
        else
          fm_btr_log "secondmate $id relaunch failed after $FM_SM_LIVE_CAUSE: $(printf '%s' "$FM_SM_LIVE_OUT" | head -n 1)"
        fi
        ;;
      alive)
        ;;
      *)
        fm_btr_log "secondmate $id endpoint $FM_SM_LIVE_STATE left untouched (evidence not recovery-authorizing)"
        ;;
    esac
    fm_secondmate_liveness_unlock "$id"
  done
  return 0
}

# The primary restore ladder. Prints exactly one typed outcome line, ledgers
# the attempt, and returns 0 only when a primary harness was actually started.
#   restore: skipped - primary lock held by live pid <pid>
#   restore: skipped - <gate reason>            (no primary pane, no budget)
#   restore: started primary session <sid> in <session>:<pane>
#   restore: FAILED - <typed reason>
fm_btr_restore_primary() {
  local state sid session pane args=() arg rc budget_rc
  state=$(fm_btr_lock_state)
  if [ "$state" = held ]; then
    fm_btr_log "restore: skipped - primary lock held by live pid ${FM_LOCK_INSPECT_PID:-unknown}"
    return 0
  fi
  fm_btr_budget primary; budget_rc=$?
  case "$budget_rc" in
    0) ;;
    1) fm_btr_log "restore: skipped - primary recovery parked this window"; return 1 ;;
    2)
      fm_btr_park primary "primary restore kept failing while unattended"
      return 1
      ;;
  esac
  fm_btr_herdr_wait || {
    fm_btr_attempt_ledger primary fail
    fm_btr_log "restore: FAILED - herdr not ready within ${FM_BTR_HERDR_WAIT_SECS}s"
    return 1
  }
  sid=$(fm_btr_recorded_session_id) || sid=
  if ! fm_btr_primary_pane; then
    fm_btr_attempt_ledger primary fail
    fm_btr_log "restore: FAILED - $FM_BTR_PRIMARY_WHY"
    return 1
  fi
  session=$FM_BTR_PRIMARY_SESSION
  pane=$FM_BTR_PRIMARY_PANE
  while IFS= read -r arg; do
    [ -n "$arg" ] || continue
    args+=("$arg")
  done < <(fm_btr_claude_args "$sid")
  if ! fm_btr_herdr --session "$session" agent start firstmate \
      --kind claude --pane "$pane" --timeout "$FM_BTR_AGENT_START_TIMEOUT_MS" \
      -- "${args[@]}" >/dev/null 2>&1; then
    fm_btr_attempt_ledger primary fail
    fm_btr_log "restore: FAILED - herdr agent start refused for pane $pane"
    return 1
  fi
  fm_btr_attempt_ledger primary relaunched
  fm_btr_log "restore: started primary session ${sid:-fresh} in $session:$pane"
  # The prompt is the recovery brief, not a liveness dependency: the
  # SessionStart hook already ran the locked sweeps, and if this submit is
  # rejected (agent busy) the watchdog's next tick re-nudges with the same
  # standing text.
  if fm_btr_herdr --session "$session" agent prompt "$pane" "$(fm_btr_boot_prompt)" >/dev/null 2>&1; then
    fm_btr_log "restore: recovery prompt accepted by $session:$pane"
  else
    fm_btr_log "restore: recovery prompt rejected by $session:$pane; SessionStart recovery stands, watchdog will re-nudge"
  fi
  return 0
}

# Test-only override point (see header). Sourced last so a shim can redefine
# any wrapper above; never active outside FM_TEST_SEAM=1.
if [ "${FM_TEST_SEAM:-}" = 1 ] && [ -n "${FM_TEST_BOOT_RESUME_SHIM:-}" ] && [ -f "${FM_TEST_BOOT_RESUME_SHIM:-}" ]; then
  # shellcheck source=/dev/null
  . "$FM_TEST_BOOT_RESUME_SHIM"
fi
