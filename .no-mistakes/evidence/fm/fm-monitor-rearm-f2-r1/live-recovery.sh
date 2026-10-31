#!/usr/bin/env bash
set -u
EVIDENCE=~/.no-mistakes/evidence/01M687E3DS9224TN83TFMN7BT8
exec > "$EVIDENCE/live-recovery.log" 2>&1
unset FM_GATE_REFUSE_BYPASS FM_TEST_SEAM
: > "$FM_HOME/state/scenario.meta"
rm -f "$FM_HOME/config/watch.env"
FM_POLL=1 bin/fm-watch.sh > "$FM_HOME/watcher.out" 2>&1 &
watcher=$!
cleanup() { kill -TERM "$watcher" 2>/dev/null || true; wait "$watcher" 2>/dev/null || true; rm -f "$FM_HOME/config/watch.env" "$FM_HOME/state/scenario.meta"; }
trap cleanup EXIT
for i in $(seq 1 200); do [ -f "$FM_HOME/state/.last-watcher-beat" ] && break; sleep .1; done
printf 'REAL watcher=%s lock=%s\n' "$watcher" "$(cat "$FM_HOME/state/.watch.lock/pid" 2>/dev/null)"
cat "$FM_HOME/watcher.out"
kill -0 "$watcher" || exit 21
printf 'exit 1\n' > "$FM_HOME/config/watch.env"
# The contender is a real lock holder; hold across the hook's bounded reset.
bash -c '. bin/fm-wake-lib.sh; fm_lock_try_acquire "$FM_HOME/state/.turnend-claude-blocks.lock" || exit 1; touch "$FM_HOME/lock.ready"; while [ ! -f "$FM_HOME/lock.release" ]; do sleep .1; done; fm_lock_release "$FM_HOME/state/.turnend-claude-blocks.lock"' &
holder=$!
for i in $(seq 1 100); do [ -e "$FM_HOME/lock.ready" ] && break; sleep .05; done
printf '{"session_id":"live-signal","stop_hook_active":false}\n' | FM_CLAUDE_AUTOARM_ATTEMPTS=1 bin/fm-claude-stop-autoarm.sh > "$FM_HOME/reset-busy.out" 2>&1
rc=$?
printf '\nCONTENDED recovery auto_rc=%s\n' "$rc"; cat "$FM_HOME/reset-busy.out"
for f in .claude-autoarm-failure-notified .claude-autoarm-failure-alarmed .turnend-claude-blocks; do printf '%s present=%s\n' "$f" "$([ -e "$FM_HOME/state/$f" ] && echo yes || echo no)"; done
: > "$FM_HOME/lock.release"; wait "$holder"; printf 'lock_holder_exit=%s\n' "$?"
printf '{"session_id":"live-signal","stop_hook_active":false}\n' | FM_CLAUDE_AUTOARM_ATTEMPTS=1 bin/fm-claude-stop-autoarm.sh > "$FM_HOME/reset-ok.out" 2>&1
rc=$?
printf '\nUNCONTENDED recovery auto_rc=%s\n' "$rc"; cat "$FM_HOME/reset-ok.out"
for f in .claude-autoarm-failure-notified .claude-autoarm-failure-alarmed .turnend-claude-blocks; do printf '%s present=%s\n' "$f" "$([ -e "$FM_HOME/state/$f" ] && echo yes || echo no)"; done
cat "$FM_HOME/state/.claude-autoarm-epoch"
printf '\nRECOVERY DRIVER COMPLETE\n'
