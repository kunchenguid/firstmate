#!/usr/bin/env bash
set -u
EVIDENCE=~/.no-mistakes/evidence/01M687E3DS9224TN83TFMN7BT8
exec > "$EVIDENCE/live-handback.log" 2>&1
unset FM_GATE_REFUSE_BYPASS FM_TEST_SEAM
: > "$FM_HOME/state/scenario.meta"
rm -f "$FM_HOME/config/supervision-host-off"
: > "$FM_HOME/config/supervision-host"
printf 'sleep 30; exit 1\n' > "$FM_HOME/config/watch.env"
trap 'rm -f "$FM_HOME/config/watch.env" "$FM_HOME/state/scenario.meta"; touch "$FM_HOME/config/supervision-host-off"' EXIT
for variant in pending announced; do
  rm -f "$FM_HOME/state/.claude-autoarm-failure-notified" "$FM_HOME/state/.claude-autoarm-failure-alarmed" "$FM_HOME/state/.turnend-claude-blocks"
  printf '%s:handling:live-incomplete-handback\n' "$variant" > "$FM_HOME/state/.watcher-down"
  printf '\nSCENARIO real host boundary with unresolved %s handling marker; arm startup starved by user config\n' "$variant"
  for i in 1 2 3 4 5 6; do
    printf '{"session_id":"live-%s-handback","stop_hook_active":false}\n' "$variant" | FM_SUPERVISION_HOST_PARK_SECONDS=1 FM_CLAUDE_AUTOARM_ATTEMPTS=1 bin/fm-claude-stop-autoarm.sh > "$FM_HOME/host-auto.out" 2>&1 &
    hook=$!
    for n in $(seq 1 100); do
      grep -q 'outcome=arming ' "$FM_HOME/state/.claude-autoarm-epoch" 2>/dev/null && break
      sleep .02
    done
    printf '{"session_id":"live-%s-handback","stop_hook_active":false}\n' "$variant" | FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=100 bin/fm-turnend-guard.sh --claude > "$FM_HOME/host-guard.out" 2>&1
    guard_rc=$?
    wait "$hook"; rc=$?
    printf '\nstop=%s auto_rc=%s guard_rc=%s notice=%s alarm=%s marker=%s\n' "$i" "$rc" "$guard_rc" "$([ -e "$FM_HOME/state/.claude-autoarm-failure-notified" ] && echo yes || echo no)" "$([ -e "$FM_HOME/state/.claude-autoarm-failure-alarmed" ] && echo yes || echo no)" "$(cat "$FM_HOME/state/.watcher-down")"
    cat "$FM_HOME/host-auto.out"; cat "$FM_HOME/state/.turnend-claude-blocks" 2>/dev/null; cat "$FM_HOME/state/.claude-autoarm-epoch"
  done
done
printf '\nHANDBACK DRIVER COMPLETE\n'
