#!/usr/bin/env bash
set -u
ROOT=$PWD
EVIDENCE=~/.no-mistakes/evidence/01M687E3DS9224TN83TFMN7BT8
exec > "$EVIDENCE/live-autoarm.log" 2>&1
unset FM_GATE_REFUSE_BYPASS FM_TEST_SEAM
printf 'REAL HARNESS ANCESTRY\n'; ps -p "$PPID" -o pid=,ppid=,comm=,args=
bin/fm-lock.sh || exit 20
printf 'lab=%s lock=%s\n' "$FM_HOME" "$(cat "$FM_HOME/state/.lock")"
: > "$FM_HOME/state/scenario.meta"
: > "$FM_HOME/config/supervision-host-off"
for variant in arm signal; do
  rm -f "$FM_HOME/state/.claude-autoarm-failure-notified" "$FM_HOME/state/.claude-autoarm-failure-alarmed" "$FM_HOME/state/.turnend-claude-blocks"
  if [ "$variant" = arm ]; then
    printf 'sleep 1; exit 1\n' > "$FM_HOME/config/watch.env"
  else
    printf 'sleep 30; exit 1\n' > "$FM_HOME/config/watch.env"
  fi
  printf '\nSCENARIO %s: user config fault exits the real arm before watcher creation\n' "$variant"
  for i in 1 2 3 4 5 6; do
    printf '{"session_id":"live-%s","stop_hook_active":false}\n' "$variant" | FM_CLAUDE_AUTOARM_ATTEMPTS=1 bin/fm-claude-stop-autoarm.sh > "$FM_HOME/auto.out" 2>&1 &
    hook=$!
    for n in $(seq 1 100); do
      grep -q 'outcome=arming ' "$FM_HOME/state/.claude-autoarm-epoch" 2>/dev/null && break
      sleep .02
    done
    printf '{"session_id":"live-%s","stop_hook_active":false}\n' "$variant" | FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=100 bin/fm-turnend-guard.sh --claude > "$FM_HOME/guard.out" 2>&1
    guard_rc=$?
    if [ "$variant" = signal ]; then kill -TERM "$hook"; fi
    wait "$hook"; rc=$?
    printf '\nstop=%s auto_rc=%s guard_rc=%s notice=%s alarm=%s\n' "$i" "$rc" "$guard_rc" "$([ -e "$FM_HOME/state/.claude-autoarm-failure-notified" ] && echo yes || echo no)" "$([ -e "$FM_HOME/state/.claude-autoarm-failure-alarmed" ] && echo yes || echo no)"
    cat "$FM_HOME/auto.out"; cat "$FM_HOME/state/.turnend-claude-blocks" 2>/dev/null; cat "$FM_HOME/state/.claude-autoarm-epoch"
  done
done
rm -f "$FM_HOME/config/watch.env" "$FM_HOME/state/scenario.meta"
printf '\nLIVE DRIVER COMPLETE\n'
: > "$FM_HOME/driver.done"
