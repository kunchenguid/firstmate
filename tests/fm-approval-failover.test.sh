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

# Substitute backend and lifecycle collaborators, not the failover owner. Its
# executable still performs the evidence check and real atomic filesystem write.
BIN="$TMP_ROOT/bin"
mkdir -p "$BIN"
cp "$CMD" "$BIN/fm-approval-failover.sh"
cat > "$BIN/fm-backend.sh" <<'SH'
fm_meta_get() { awk -F= -v key="$2" '$1 == key {print substr($0, length(key)+2); exit}' "$1"; }
fm_backend_validate_task_endpoint() { FM_BACKEND_VALIDATED_BACKEND=tmux; FM_BACKEND_VALIDATED_TARGET=firstmate:fm-task; }
fm_backend_visible_capture() {
  if [ "${WRITE_DURING_CAPTURE:-0}" = 1 ]; then printf 'bypass\n' > "$FM_HOME/config/$TEST_SETTING"; fi
  if [ "${RESPAWN_DURING_CAPTURE:-0}" = 1 ]; then printf 'spawn_gen=two\n' >> "$FM_HOME/state/task.meta"; fi
  cat "$FM_HOME/screen"
}
SH
cat > "$BIN/fm-control.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_HOME/control.log"
[ "${FAIL_CONTROL:-0}" != 1 ]
SH
chmod +x "$BIN/fm-control.sh"

for harness in codex claude; do
  home="$TMP_ROOT/$harness"
  mkdir -p "$home/state" "$home/config"
  if [ "$harness" = codex ]; then setting=codex-approval-mode; fallback=approve-for-me; screen=$CODEX_SCREEN; else setting=claude-permission-mode; fallback=auto; screen=$CLAUDE_SCREEN; fi
  printf '%s\n' "$screen" > "$home/screen"
  printf 'harness=%s\napproval_mode=bypass\napproval_configured=0\nspawn_gen=one\n' "$harness" > "$home/state/task.meta"
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
  printf 'harness=%s\napproval_mode=bypass\napproval_configured=1\n' "$harness" > "$home/state/task.meta"
  if FM_HOME="$home" "$BIN/fm-approval-failover.sh" apply task; then fail 'previously explicit launch treated as unconfigured'; fi
  [ ! -e "$home/config/$setting" ] || fail 'explicit launch caused setting write'
  pass "$harness preserves all explicit settings and launch choices"

  printf 'harness=%s\napproval_mode=bypass\napproval_configured=0\nspawn_gen=one\n' "$harness" > "$home/state/task.meta"
  if FM_HOME="$home" TEST_SETTING="$setting" WRITE_DURING_CAPTURE=1 "$BIN/fm-approval-failover.sh" apply task; then fail 'concurrent explicit write did not win'; fi
  [ "$(cat "$home/config/$setting")" = bypass ] || fail 'concurrent explicit write overwritten'
  rm "$home/config/$setting"
  if FM_HOME="$home" RESPAWN_DURING_CAPTURE=1 "$BIN/fm-approval-failover.sh" apply task; then fail 'changed launch reused old evidence'; fi
  [ ! -e "$home/config/$setting" ] || fail 'changed launch caused persistence'
  pass "$harness rejects changed launch records and preserves concurrent explicit writes"

  printf 'harness=%s\napproval_mode=bypass\napproval_configured=0\nspawn_gen=one\n' "$harness" > "$home/state/task.meta"
  if FM_HOME="$home" FAIL_CONTROL=1 "$BIN/fm-approval-failover.sh" apply task; then fail 'failed lifecycle claimed success'; fi
  [ "$(cat "$home/config/$setting")" = "$fallback" ] || fail 'lifecycle failure lost persistent remedy'
  assert_grep 'worker recovery failed' "$home/state/task.status" 'lifecycle failure was not reported'
  pass "$harness retains the remedy but reports lifecycle failure honestly"
done

echo '# all fm-approval-failover tests passed'
