#!/usr/bin/env bash
# Behavior tests for the managed-policy classifier and durable failover command.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-approval-failover)
CMD="$ROOT/bin/fm-approval-failover.sh"
CODEX_SCREEN=$'Would you like to run the following command?\n  $ pwd -P\n› 1. Yes, proceed (y)\n  2. No, and tell Codex what to do differently (esc)'
CLAUDE_SCREEN='API Error: 403 {"error":"A Formal policy has blocked the connection for your user to this resource"}'

for harness in codex claude; do
  if [ "$harness" = codex ]; then screen=$CODEX_SCREEN; else screen=$CLAUDE_SCREEN; fi
  printf '%s\n' "$screen" | "$CMD" classify "$harness" >/dev/null || fail "$harness concrete evidence was missed"
  for unrelated in 'Please run /login' 'Failed to authenticate' 'HTTP 403 invalid API key' 'Would you like to run the following command?' '› 1. Yes, proceed (y)' 'A Formal policy has blocked the connection for your user to this resource'; do
    if printf '%s\n' "$unrelated" | "$CMD" classify "$harness"; then fail "$harness guessed failover on partial/unrelated output"; fi
  done
  pass "$harness classifier requires concrete refusal evidence, not generic auth errors"
done

# Match full marker byte sequences even without multibyte locale semantics.
for marker in '›' '>' '❯'; do
  screen=$(printf 'Would you like to run the following command?\n%s 1. Yes, proceed (y)\n' "$marker")
  verdict=$(printf '%s\n' "$screen" | LC_ALL=C "$CMD" classify codex) || fail "C locale missed the complete $marker approval modal"
  [ "$verdict" = codex-approval-prompt ] || fail 'C locale emitted the wrong approval verdict'
  if printf '%s 1. Yes, proceed (y)\n' "$marker" | LC_ALL=C "$CMD" classify codex; then
    fail 'C locale accepted a selection marker without the approval question'
  fi
done
pass 'Codex approval evidence matches full markers under LC_ALL=C without accepting partial evidence'

# Substitute backend and lifecycle collaborators, not the failover owner. Its
# executable still performs the evidence check and real atomic filesystem write.
BIN="$TMP_ROOT/bin"
mkdir -p "$BIN"
cp "$CMD" "$BIN/fm-approval-failover.sh"
printf '. %q\n' "$ROOT/bin/fm-lease-lib.sh" > "$BIN/fm-lease-lib.sh"
cat > "$BIN/fm-backend.sh" <<'SH'
fm_meta_get() { awk -F= -v key="$2" '$1 == key {print substr($0, length(key)+2); exit}' "$1"; }
fm_backend_validate_task_endpoint() { FM_BACKEND_VALIDATED_BACKEND=tmux; FM_BACKEND_VALIDATED_TARGET=firstmate:fm-task; }
fm_backend_visible_capture() {
  printf 'capture\n' >> "$FM_HOME/capture.log"
  if [ "${WRITE_DURING_CAPTURE:-0}" = 1 ]; then printf 'bypass\n' > "$FM_HOME/config/$TEST_SETTING"; fi
  if [ "${RESPAWN_DURING_CAPTURE:-0}" = 1 ]; then printf 'spawn_gen=two\n' >> "$FM_HOME/state/task.meta"; fi
  cat "$FM_HOME/screen"
}
SH
cat > "$BIN/fm-control.sh" <<'SH'
#!/usr/bin/env bash
set -eu
STATE=$FM_HOME/state
. "$(dirname "$0")/fm-lease-lib.sh"
trap fm_lease_guard_release EXIT
fm_lease_guard "$1" 'test lifecycle control'
printf '%s\n' "$*" >> "$FM_HOME/control.log"
[ "${FAIL_CONTROL:-0}" != 1 ]
SH
chmod +x "$BIN/fm-control.sh"

for harness in codex claude; do
  home="$TMP_ROOT/$harness"
  gen="s$(date +%s).$$.1"
  mkdir -p "$home/state" "$home/config"
  if [ "$harness" = codex ]; then setting=codex-approval-mode; fallback=approve-for-me; screen=$CODEX_SCREEN; else setting=claude-permission-mode; fallback=auto; screen=$CLAUDE_SCREEN; fi
  printf '%s\n' "$screen" > "$home/screen"
  printf 'harness=%s\napproval_mode=bypass\napproval_configured=0\nspawn_gen=%s\n' "$harness" "$gen" > "$home/state/task.meta"
  FM_HOME="$home" "$BIN/fm-approval-failover.sh" probe task >/dev/null || fail "probe missed $harness"
  FM_HOME="$home" "$BIN/fm-approval-failover.sh" apply task >/dev/null || fail "apply failed $harness"
  [ "$(cat "$home/config/$setting")" = "$fallback" ] || fail "$harness fallback was not persisted"
  assert_grep 'task interrupt' "$home/control.log" 'recovery did not cancel the refused turn'
  assert_grep 'task relaunch --note ' "$home/control.log" 'recovery did not use guarded relaunch'
  before=$(wc -l < "$home/control.log")
  if FM_HOME="$home" "$BIN/fm-approval-failover.sh" apply task; then fail 'repeat failover succeeded'; fi
  [ "$(wc -l < "$home/control.log")" = "$before" ] || fail 'repeat attempt touched the worker'
  pass "$harness fallback persists once and recovers through the lifecycle plane"

  for explicit in bypass "$fallback" invalid ''; do
    printf '%s\n' "$explicit" > "$home/config/$setting"
    cp "$home/config/$setting" "$home/before"
    if FM_HOME="$home" "$BIN/fm-approval-failover.sh" apply task; then fail "explicit $explicit was changed"; fi
    cmp "$home/before" "$home/config/$setting" || fail 'explicit bytes overwritten'
  done
  rm "$home/config/$setting"
  ln -s "$home/missing" "$home/config/$setting"
  if FM_HOME="$home" "$BIN/fm-approval-failover.sh" apply task; then fail 'dangling explicit setting overwritten'; fi
  [ -L "$home/config/$setting" ] || fail 'explicit symlink was replaced'
  rm "$home/config/$setting"
  printf 'harness=%s\napproval_mode=bypass\napproval_configured=1\nspawn_gen=%s\n' "$harness" "$gen" > "$home/state/task.meta"
  if FM_HOME="$home" "$BIN/fm-approval-failover.sh" apply task; then fail 'previously explicit launch treated as unconfigured'; fi
  [ ! -e "$home/config/$setting" ] || fail 'explicit launch caused setting write'
  pass "$harness preserves all explicit settings and launch choices"

  printf 'harness=%s\napproval_mode=bypass\napproval_configured=0\nspawn_gen=%s\n' "$harness" "$gen" > "$home/state/task.meta"
  if FM_HOME="$home" TEST_SETTING="$setting" WRITE_DURING_CAPTURE=1 "$BIN/fm-approval-failover.sh" apply task; then fail 'concurrent explicit write did not win'; fi
  [ "$(cat "$home/config/$setting")" = bypass ] || fail 'concurrent explicit write overwritten'
  rm "$home/config/$setting"
  if FM_HOME="$home" RESPAWN_DURING_CAPTURE=1 "$BIN/fm-approval-failover.sh" apply task; then fail 'changed launch reused old evidence'; fi
  [ ! -e "$home/config/$setting" ] || fail 'changed launch caused persistence'
  pass "$harness rejects changed launch records and preserves concurrent explicit writes"

  before=$(wc -l < "$home/capture.log")
  expired="s$(( $(date +%s) - 121 )).$$.2"
  future="s$(( $(date +%s) + 600 )).$$.3"
  for old_gen in "$expired" "$future" one; do
    printf 'harness=%s\napproval_mode=bypass\napproval_configured=0\nspawn_gen=%s\n' "$harness" "$old_gen" > "$home/state/task.meta"
    for verb in probe apply; do
      if FM_HOME="$home" "$BIN/fm-approval-failover.sh" "$verb" task; then fail "$harness $verb accepted an expired, future, or unknown launch"; fi
    done
  done
  [ "$(wc -l < "$home/capture.log")" = "$before" ] || fail "$harness captured a viewport past the startup window"
  [ ! -e "$home/config/$setting" ] || fail 'expired launch changed configuration'
  pass "$harness stops probing expired workers without additional marker state"

  printf 'harness=%s\napproval_mode=bypass\napproval_configured=0\nspawn_gen=%s\n' "$harness" "$gen" > "$home/state/task.meta"
  printf '%s\n' "$$" > "$home/state/.lock"
  printf 'branch\t%s\t%s\n' "$$" "$(date +%s)" > "$home/state/.lease-task"
  cp "$home/state/task.status" "$home/status-before"
  before=$(wc -l < "$home/control.log")
  rc=0
  FM_HOME="$home" FM_SUPERVISION_ACTOR=main "$BIN/fm-approval-failover.sh" apply task > "$home/lease.out" 2>&1 || rc=$?
  [ "$rc" -eq 6 ] || fail 'other-actor lease did not refuse failover'
  [ ! -e "$home/config/$setting" ] || fail 'lease refusal persisted fallback'
  cmp "$home/status-before" "$home/state/task.status" || fail 'lease refusal changed task status'
  [ "$(wc -l < "$home/control.log")" = "$before" ] || fail 'lease refusal reached lifecycle control'
  FM_HOME="$home" FM_SUPERVISION_ACTOR=branch "$BIN/fm-approval-failover.sh" apply task >/dev/null || fail 'same-actor failover did not release guard before child control'
  [ "$(cat "$home/config/$setting")" = "$fallback" ] || fail 'authorized actor lost fallback'
  rm "$home/config/$setting" "$home/state/.lease-task" "$home/state/.lock"
  pass "$harness authorizes every persistent change and permits guarded child lifecycle calls"

  if FM_HOME="$home" FAIL_CONTROL=1 "$BIN/fm-approval-failover.sh" apply task; then fail 'failed lifecycle claimed success'; fi
  [ "$(cat "$home/config/$setting")" = "$fallback" ] || fail 'lifecycle failure lost persistent remedy'
  assert_grep 'worker recovery failed' "$home/state/task.status" 'lifecycle failure was not reported'
  pass "$harness retains the remedy but reports lifecycle failure honestly"
done

. "$ROOT/bin/fm-config-inherit-lib.sh"
primary="$TMP_ROOT/primary/config"
local_config="$TMP_ROOT/local/config"
remote_home="$TMP_ROOT/remote"
mkdir -p "$primary" "$local_config" "$remote_home/config"
empty_hash=$(printf '' | shasum -a 256 | awk '{print $1}')
bypass_hash=$(printf 'bypass\n' | shasum -a 256 | awk '{print $1}')
for setting in codex-approval-mode claude-permission-mode; do
  if [ "$setting" = codex-approval-mode ]; then fallback=approve-for-me; else fallback=auto; fi
  printf '%s\n' "$fallback" > "$local_config/$setting"
  printf '%s\n' "$fallback" > "$remote_home/config/$setting"
  propagate_inheritable_config "$primary" "$local_config" || fail 'local inheritance failed'
  [ "$(cat "$local_config/$setting")" = "$fallback" ] || fail 'primary absence erased local fallback'
  FM_HOME="$remote_home" "$ROOT/bin/fm-remote-inherit.sh" absent "config/$setting" 0 "$empty_hash" 1 >/dev/null || fail 'remote absence transfer failed'
  [ "$(cat "$remote_home/config/$setting")" = "$fallback" ] || fail 'primary absence erased remote fallback'

  printf 'bypass\n' > "$primary/$setting"
  propagate_inheritable_config "$primary" "$local_config" || fail 'explicit primary inheritance failed'
  [ "$(cat "$local_config/$setting")" = bypass ] || fail 'explicit primary did not replace local fallback'
  printf 'bypass\n' | FM_HOME="$remote_home" "$ROOT/bin/fm-remote-inherit.sh" put "config/$setting" 7 "$bypass_hash" 2 >/dev/null || fail 'explicit remote transfer failed'
  [ "$(cat "$remote_home/config/$setting")" = bypass ] || fail 'explicit primary did not replace remote fallback'
  rm "$primary/$setting"
  propagate_inheritable_config "$primary" "$local_config" || fail 'local primary removal failed'
  FM_HOME="$remote_home" "$ROOT/bin/fm-remote-inherit.sh" absent "config/$setting" 0 "$empty_hash" 3 >/dev/null || fail 'remote primary removal failed'
  [ "$(cat "$local_config/$setting")" = bypass ] && [ "$(cat "$remote_home/config/$setting")" = bypass ] || fail 'primary removal erased local choice'
  pass "$setting preserves home-local values on primary absence and honors explicit primary precedence locally and remotely"
done

echo '# all fm-approval-failover tests passed'
