#!/usr/bin/env bash
set -u
EVIDENCE=~/.no-mistakes/evidence/01M687E3DS9224TN83TFMN7BT8
exec > "$EVIDENCE/live-lock-cleanup.log" 2>&1
unset FM_GATE_REFUSE_BYPASS FM_TEST_SEAM
. bin/fm-wake-lib.sh
: > "$FM_HOME/config/supervision-host-off"
rm -f "$FM_HOME/config/watch.env" "$STATE/.watcher-down"
for variant in unpublished published; do
  printf '\nSCENARIO %s lock blocks interrupted real watcher cleanup\n' "$variant"
  rm -f "$STATE/.watcher-down" "$FM_HOME/holder.ready" "$FM_HOME/holder.release"
  FM_POLL=1 FM_LOCK_STALE_AFTER=2 FM_WATCHER_CLEANUP_LOCK_BOUND=2 bin/fm-watch-arm.sh > "$FM_HOME/lock-arm.out" 2>&1 &
  arm=$!
  for i in $(seq 1 200); do grep -q '^watcher: started' "$FM_HOME/lock-arm.out" && break; sleep .05; done
  cat "$FM_HOME/lock-arm.out"
  watcher=$(cat "$STATE/.watch.lock/pid")
  printf 'arm=%s watcher=%s pid_file_bytes=%s\n' "$arm" "$watcher" "$(wc -c < "$STATE/.watch.lock/pid")"
  if [ "$variant" = unpublished ]; then
    owner=$(fm_lock_owner_dir "$STATE/.watcher-down.lock") || exit 30
    printf 'partial unpublished artifact\n' > "$owner/pid.tmp.aborted"
    ln -s "$owner" "$STATE/.watcher-down.lock" || exit 31
    printf 'synthetic orphan owner=%s pid_unpublished=yes residue=pid.tmp.aborted\n' "$owner"
  else
    bash -c '. bin/fm-wake-lib.sh; fm_lock_try_acquire "$STATE/.watcher-down.lock" || exit 1; touch "$FM_HOME/holder.ready"; while [ ! -e "$FM_HOME/holder.release" ]; do sleep .05; done; fm_lock_release "$STATE/.watcher-down.lock"' &
    holder=$!
    for i in $(seq 1 100); do [ -e "$FM_HOME/holder.ready" ] && break; sleep .05; done
    printf 'published live holder=%s lock_pid=%s\n' "$holder" "$(cat "$STATE/.watcher-down.lock/pid")"
  fi
  start=$SECONDS
  kill -HUP "$arm"
  wait "$arm"; rc=$?
  elapsed=$((SECONDS-start))
  printf 'interrupted arm_exit=%s elapsed_seconds=%s\n' "$rc" "$elapsed"
  cat "$FM_HOME/lock-arm.out"
  if [ "$variant" = unpublished ]; then
    printf 'orphan_dir_remaining=%s residue_remaining=%s marker=%s\n' "$([ -e "$owner" ] && echo yes || echo no)" "$([ -e "$owner/pid.tmp.aborted" ] && echo yes || echo no)" "$(cat "$STATE/.watcher-down" 2>/dev/null)"
  else
    printf 'live holder survives=%s watcher_lock_retained=%s\n' "$(kill -0 "$holder" 2>/dev/null && echo yes || echo no)" "$([ -e "$STATE/.watch.lock" ] && echo yes || echo no)"
    touch "$FM_HOME/holder.release"; wait "$holder"; printf 'holder_exit=%s\n' "$?"
  fi
  bin/fm-wake-drain.sh > "$FM_HOME/drain.out" 2>&1; printf 'drain_exit=%s\n' "$?"
  cat "$FM_HOME/drain.out"
  if [ "$variant" = unpublished ]; then
    ack=$(sed -n 's/^WAKE_ACK_REQUIRED: after handling completes run //p' "$FM_HOME/drain.out")
    if [ -n "$ack" ]; then bash -c "$ack"; printf 'ack_exit=%s\n' "$?"; fi
  fi
done
printf '\nLOCK DRIVER COMPLETE\n'
