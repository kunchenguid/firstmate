#!/usr/bin/env bash
# shellcheck shell=bash
# Parent-owned goal-drive health episodes. Source after backend, busy, inbox,
# wake and secondmate-liveness libraries. fm-secondmate-health.sh owns execution.
# A new startable-item set, endpoint or parent status line starts a fresh
# observation interval. After 1800s without progress, ring once, then after a
# second interval request a durable-checkpoint restart. Never infer death
# from silence. Explicit waits, busy/unknown agents and unrelated composer text
# are left alone. Remote routes remain under pending-reply/liveness supervision.
# Episode files are local, atomic TSV: signature, since, phase.

fm_secondmate_health_store() { # <path> <signature> <since> <phase>
  local tmp
  [ ! -L "$1" ] || return 1
  tmp=$(mktemp "$STATE/.secondmate-health.XXXXXX") || return 1
  if ! printf '%s\t%s\t%s\n' "$2" "$3" "$4" > "$tmp" || ! mv -f -- "$tmp" "$1"; then
    rm -f -- "$tmp"; return 1
  fi
}

fm_secondmate_health_result() { # <id> <reason>
  local tmp
  tmp=$(mktemp "$STATE/.secondmate-health-result.XXXXXX") || return 1
  if ! printf '%s\n' "$2" > "$tmp" || ! mv -f -- "$tmp" "$STATE/.secondmate-health-result-$1-${tmp##*.}"; then
    rm -f -- "$tmp"; return 1
  fi
}

# Fresh-session clock is independent of goal-stall episodes. A generation
# change resets it; elapsed time is eligibility, never proof of quietness.
# FM_SECONDMATE_FRESH_SECS=0 disables proactive refresh (default 2700 seconds).
# Remote homes must run the host-local quiet check, never infer idle over SSH.
fm_secondmate_fresh_observe() { # <id> <now-epoch>
  local id=$1 now=$2 meta="$STATE/$1.meta" marker="$STATE/.secondmate-fresh-$1"
  local signature old='' since='' phase='' threshold target backend harness verdict cstate last log rc
  threshold=${FM_SECONDMATE_FRESH_SECS:-2700}
  case "$threshold" in ''|*[!0-9]*) return 1 ;; esac
  [ "${#threshold}" -le 9 ] || return 1
  threshold=$((10#$threshold))
  [ "$threshold" -gt 0 ] || return 0
  signature=$(printf '%s\n' "$(fm_backend_target_of_meta "$meta")" "$(fm_meta_get "$meta" spawn_gen)" | cksum | awk '{print $1 ":" $2}')
  [ ! -L "$marker" ] || return 1
  if [ -f "$marker" ]; then
    IFS=$'\t' read -r old since phase < "$marker" || return 1
  fi
  case "$since" in ''|*[!0-9]*) old='' ;; esac
  if [ "$signature" != "$old" ] || [ "$now" -lt "${since:-0}" ]; then
    fm_secondmate_health_store "$marker" "$signature" "$now" observing
    return $?
  fi
  [ "$((now - since))" -ge "$threshold" ] || return 0
  last=$(tail -n 1 "$STATE/$id.status" 2>/dev/null || true)
  case "$last" in paused\ *|paused:*|blocked\ *|blocked:*|needs-decision\ *|needs-decision:*) return 0 ;; esac
  target=$(fm_backend_target_of_meta "$meta")
  backend=$(fm_backend_of_meta "$meta")
  harness=$(fm_meta_get "$meta" harness)
  [ "$(fm_backend_agent_state "$backend" "$target" 2>/dev/null)" = alive ] || return 0
  verdict=$(fm_busy_classify_meta "$meta" "$id" "$STATE")
  [ "${verdict%% *}" = idle ] || return 0
  cstate=$(FM_COMPOSER_HARNESS=$harness fm_backend_composer_state "$backend" "$target" "$(fm_meta_get "$meta" label)" 2>/dev/null) || cstate=unknown
  [ "$cstate" = empty ] || return 0
  # Write ahead: interrupted or refused attempts cannot storm every sweep.
  fm_secondmate_health_store "$marker" "$signature" "$now" attempted || return 1
  log=$(mktemp "$STATE/.secondmate-fresh-log.XXXXXX") || return 1
  rc=0
  FM_HOME=$FM_HOME FM_STATE_OVERRIDE=$STATE FM_SECONDMATE_RESTART_MODE=durable \
    "$FM_SM_HEALTH_DIR/fm-secondmate-restart.sh" --quiet "$id" > "$log" 2>&1 || rc=$?
  mv -f -- "$log" "$STATE/.secondmate-fresh-$id.restart.log" || return 1
  if [ "$rc" = 0 ]; then
    [ ! -L "$STATE/.secondmate-health-$id" ] || return 1
    rm -f -- "$STATE/.secondmate-health-$id"
  fi
  printf 'secondmate-fresh: %s quiet restart exit=%s\n' "$id" "$rc"
}

fm_secondmate_health_observe() { # <id> <startable-rows> <now-epoch>
  local id=$1 rows=$2 now=$3 meta marker owned last signature old='' since='' phase=''
  local target backend harness verdict rec='' f line cstate threshold log outcome
  case "$id" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  meta="$STATE/$id.meta"
  marker="$STATE/.secondmate-health-$id"
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 0
  [ "$(fm_meta_get "$meta" kind)" = secondmate ] || return 0
  [ -z "$(fm_meta_get "$meta" remote_host)" ] || return 0
  fm_secondmate_fresh_observe "$id" "$now" || return $?
  owned=$(printf '%s\n' "$rows" | awk -F '\t' -v id="$id" '$3 == id')
  if [ -z "$owned" ]; then
    [ ! -L "$marker" ] || return 1
    rm -f -- "$marker"
    return 0
  fi
  threshold=${FM_SECONDMATE_HEALTH_SECS:-1800}
  case "$threshold" in ''|0*|*[!0-9]*) threshold=1800 ;; esac
  [ "${#threshold}" -le 9 ] || threshold=1800
  target=$(fm_backend_target_of_meta "$meta")
  [ -n "$target" ] || return 0
  backend=$(fm_backend_of_meta "$meta")
  harness=$(fm_meta_get "$meta" harness)
  last=$(tail -n 1 "$STATE/$id.status" 2>/dev/null || true)
  signature=$(printf '%s\n' "$target" "$backend" "$harness" "$owned" "$last" | cksum | awk '{print $1 ":" $2}')
  [ ! -L "$marker" ] || return 1
  if [ -f "$marker" ]; then
    IFS=$'\t' read -r old since phase < "$marker" || return 1
  fi
  case "$since" in ''|*[!0-9]*) since=$now; old='' ;; esac
  if [ "$old" != "$signature" ] || [ "$now" -lt "$since" ]; then
    fm_secondmate_health_store "$marker" "$signature" "$now" observing
    return $?
  fi
  [ "$phase" != recovering ] || return 0
  [ "$((now - since))" -ge "$threshold" ] || return 0
  # A deliberate wait is not permission to interrupt, even if the goal
  # projection still lists work. The ordinary wait-expiry path owns it.
  case "$last" in paused\ *|paused:*|blocked\ *|blocked:*|needs-decision\ *|needs-decision:*) return 0 ;; esac
  [ "$(fm_backend_agent_state "$backend" "$target" 2>/dev/null)" = alive ] || return 0
  verdict=$(fm_busy_classify_meta "$meta" "$id" "$STATE")
  [ "${verdict%% *}" = idle ] || return 0
  cstate=$(FM_COMPOSER_HARNESS=$harness fm_backend_composer_state "$backend" "$target" "$(fm_meta_get "$meta" label)" 2>/dev/null) || cstate=unknown
  # Protect user text and unreadable composers on BOTH steps. An exact own
  # doorbell may be submitted through the existing inbox Enter-only path.
  for f in "$STATE/$id.inbox"/*.msg; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    fm_task_inbox_seq_of "${f##*/}" >/dev/null || continue
    rec=$f; break
  done
  case "$cstate" in
    empty) ;;
    pending)
      [ -n "$rec" ] || return 0
      line=$(fm_task_inbox_doorbell_line "$rec") || return 1
      FM_COMPOSER_HARNESS=$harness fm_task_inbox_composer_holds "$backend" "$target" "$line" "$(fm_meta_get "$meta" label)" || return 0
      ;;
    *) return 0 ;;
  esac
  case "$phase" in
    observing)
      if [ -n "$rec" ]; then
        FM_COMPOSER_HARNESS=$harness fm_task_inbox_ring "$backend" "$target" "$rec" "$(fm_meta_get "$meta" label)" || return 0
      else
        FM_HOME=$FM_HOME FM_STATE_OVERRIDE=$STATE "$FM_SM_HEALTH_DIR/fm-send.sh" "$id" \
          "You own startable goal items with no parent-status progress for ${threshold}s. Drain your steering inbox and wake queue, inspect fm-goal.sh startable, and advance the ready items through their next safe step. Respect holds and pauses; report concrete progress or the blocker." >/dev/null 2>&1 || return 0
      fi
      fm_secondmate_health_store "$marker" "$signature" "$now" rung || return 1
      printf 'secondmate-health: %s rung after %ss without goal progress\n' "$id" "$threshold"
      ;;
    rung)
      # Write ahead so a killed watcher/job never repeats a restart request.
      # The control transaction persists an inventory before stopping. No
      # correlated answer or model turn is needed for recovery.
      fm_secondmate_health_store "$marker" "$signature" "$now" recovering || return 1
      printf 'secondmate-health: %s requesting durable-checkpoint recovery\n' "$id"
      fm_secondmate_health_result "$id" "check: secondmate $id goal-stall recovery requested; checkpointing durable records" || return 1
      log=$(mktemp "$STATE/.secondmate-health-log.XXXXXX") || return 1
      outcome=unconfirmed
      if FM_HOME=$FM_HOME FM_STATE_OVERRIDE=$STATE "$FM_SM_HEALTH_DIR/fm-secondmate-restart.sh" "$id" > "$log" 2>&1; then
        outcome=completed
      fi
      mv -f -- "$log" "$STATE/.secondmate-health-$id.restart.log" || return 1
      fm_secondmate_health_result "$id" "check: secondmate $id goal-stall recovery $outcome; records preserved, see .secondmate-health-$id.restart.log"
      ;;
  esac
}
