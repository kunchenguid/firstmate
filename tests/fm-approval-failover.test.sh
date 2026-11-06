#!/usr/bin/env bash
# Behavior tests for the firstmate-invoked persistent fallback command.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-approval-failover)
BIN="$TMP_ROOT/bin"
mkdir -p "$BIN"
cp "$ROOT/bin/fm-approval-failover.sh" "$BIN/fm-approval-failover.sh"
# Use the actual metadata, identity and lease owners. Substitute only lifecycle
# control, avoiding real workers while proving the command releases its guard.
for lib in fm-backend.sh fm-pr-lib.sh fm-wake-lib.sh fm-lease-lib.sh fm-gate-refuse-lib.sh; do
  printf '. %q\n' "$ROOT/bin/$lib" > "$BIN/$lib"
done
cat > "$BIN/fm-control.sh" <<'SH'
#!/usr/bin/env bash
set -eu
STATE=$FM_HOME/state
. "$(dirname "$0")/fm-gate-refuse-lib.sh"
fm_refuse_if_gate_agent
. "$(dirname "$0")/fm-lease-lib.sh"
trap fm_lease_guard_release EXIT
fm_lease_guard "$1" 'test lifecycle control'
if [ -n "${CHECK_INHERIT_SETTING:-}" ]; then
  links=$("$REAL_PERL" -e 'print((stat($ARGV[0]))[3])' "$FM_HOME/config/$CHECK_INHERIT_SETTING")
  [ "$links" = 1 ] || { echo 'error: saved fallback is still hardlinked during recovery' >&2; exit 1; }
  printf 'single-linked: %s\n' "$CHECK_INHERIT_SETTING" >> "$FM_HOME/publication.log"
fi
printf '%s\n' "$*" >> "$FM_HOME/control.log"
[ "${FAIL_CONTROL:-0}" != 1 ]
SH
chmod +x "$BIN/fm-control.sh"
REAL_PERL=$(command -v perl)
export REAL_PERL
cat > "$BIN/perl" <<'SH'
#!/usr/bin/env bash
set -eu
case "${RACE_SETTING_KIND:-}" in
  file) printf 'bypass\n' > "$FM_HOME/config/$TEST_SETTING" ;;
  directory) mkdir "$FM_HOME/config/$TEST_SETTING" ;;
  symlink) mkdir "$FM_HOME/operator-directory"; ln -s "$FM_HOME/operator-directory" "$FM_HOME/config/$TEST_SETTING" ;;
esac
exec "$REAL_PERL" "$@"
SH
chmod +x "$BIN/perl"
run_apply() {
  env -u FM_SUPERVISION_ACTOR FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    "$@" "$BIN/fm-approval-failover.sh" apply task
}

for harness in codex claude; do
  home="$TMP_ROOT/$harness"
  mkdir -p "$home/state" "$home/config"
  if [ "$harness" = codex ]; then setting=codex-approval-mode; fallback=approve-for-me; else setting=claude-permission-mode; fallback=auto; fi
  printf 'harness=%s\napproval_mode=bypass\n' "$harness" > "$home/state/task.meta"
  printf 'branch\t0\t1\n' > "$home/state/.lease-task"
  printf 'blocked: existing task event\n' > "$home/state/task.status"
  cp "$home/state/.lease-task" "$home/lease.before"
  cp "$home/state/task.status" "$home/status.before"
  rc=0
  run_apply FM_GATE_REFUSE_BYPASS=0 NO_MISTAKES_GATE=1 FM_SUPERVISION_ACTOR=branch > "$home/gate.out" 2>&1 || rc=$?
  [ "$rc" -eq 3 ] || fail "$harness gate caller did not receive the gate refusal"
  [ -z "$(find "$home/config" -mindepth 1 -print)" ] || fail 'gate refusal changed configuration'
  cmp "$home/lease.before" "$home/state/.lease-task" || fail 'gate refusal reached stale-lease cleanup'
  cmp "$home/status.before" "$home/state/task.status" || fail 'gate refusal changed task status'
  [ ! -e "$home/state/.fm-lease-command.lock" ] || fail 'gate refusal left a lease lock'
  [ ! -e "$home/control.log" ] || fail 'gate refusal reached lifecycle control'
  rm "$home/state/.lease-task"
  pass "$harness refuses gate callers before configuration, lease or lifecycle mutation"

  lab=$("$ROOT/bin/fm-lab-home.sh" create "$TMP_ROOT/$harness-lab") || fail 'could not create disposable lab home'
  printf 'harness=%s\napproval_mode=bypass\n' "$harness" > "$lab/state/task.meta"
  rc=0
  (
    for var in "${!FM_@}"; do
      case "$var" in *_OVERRIDE) unset "$var" ;; esac
    done
    env -u FM_GATE_REFUSE_BYPASS FM_HOME="$lab" NO_MISTAKES_GATE=1 FM_SUPERVISION_ACTOR=branch \
      FM_CONFIG_OVERRIDE="$home/config" "$BIN/fm-approval-failover.sh" apply task
  ) > "$home/lab-override.out" 2>&1 || rc=$?
  [ "$rc" -eq 3 ] || fail 'lab with a config override outside its home escaped gate refusal'
  [ -z "$(find "$lab/config" -mindepth 1 -print)" ] || fail 'refused lab override changed configuration'
  [ ! -e "$lab/control.log" ] || fail 'refused lab override reached lifecycle control'
  (
    for var in "${!FM_@}"; do
      case "$var" in *_OVERRIDE) unset "$var" ;; esac
    done
    env -u FM_GATE_REFUSE_BYPASS FM_HOME="$lab" NO_MISTAKES_GATE=1 FM_SUPERVISION_ACTOR=branch \
      FM_CONFIG_OVERRIDE="$lab/config" CHECK_INHERIT_SETTING="$setting" "$BIN/fm-approval-failover.sh" apply task
  ) > "$home/lab.out" 2>&1 || fail "$harness disposable lab recovery was refused"
  [ "$(cat "$lab/config/$setting")" = "$fallback" ] || fail 'lab fallback was not saved'
  assert_grep 'task interrupt' "$lab/control.log" 'lab did not cancel the pending turn'
  assert_grep 'task relaunch --note ' "$lab/control.log" 'lab did not relaunch'
  [ "$(wc -l < "$lab/publication.log" | tr -d ' ')" = 2 ] || fail 'lab fallback remained hardlinked at a lifecycle boundary'
  pass "$harness permits disposable lab recovery only through its stock layout"

  run_apply FM_SUPERVISION_ACTOR=branch CHECK_INHERIT_SETTING="$setting" >/dev/null || fail "$harness apply failed"
  [ "$(cat "$home/config/$setting")" = "$fallback" ] || fail "$harness fallback was not saved"
  [ "$(wc -l < "$home/publication.log" | tr -d ' ')" = 2 ] || fail 'fallback remained hardlinked during interrupt or relaunch'
  pass "$harness publishes a single-linked setting before interrupt and relaunch"
  assert_grep 'task interrupt' "$home/control.log" 'pending turn was not cancelled'
  assert_grep 'task relaunch --note ' "$home/control.log" 'guarded relaunch was not called'
  before=$(wc -l < "$home/control.log")
  if run_apply; then fail 'repeat failover succeeded'; fi
  [ "$(wc -l < "$home/control.log")" = "$before" ] || fail 'repeat attempt touched the worker'
  pass "$harness writes once and relaunches through the lifecycle owner"

  for explicit in bypass "$fallback" invalid ''; do
    printf '%s\n' "$explicit" > "$home/config/$setting"
    cp "$home/config/$setting" "$home/before"
    if run_apply; then fail "explicit $explicit was changed"; fi
    cmp "$home/before" "$home/config/$setting" || fail 'explicit bytes overwritten'
  done
  rm "$home/config/$setting"
  ln -s "$home/missing" "$home/config/$setting"
  if run_apply; then fail 'dangling explicit setting overwritten'; fi
  [ -L "$home/config/$setting" ] || fail 'explicit symlink replaced'
  rm "$home/config/$setting"
  mkdir "$home/config/$setting"
  if run_apply; then fail 'explicit directory was changed'; fi
  [ -z "$(find "$home/config/$setting" -mindepth 1 -print)" ] || fail 'explicit directory acquired a nested link'
  rmdir "$home/config/$setting"
  [ "$(wc -l < "$home/control.log")" = "$before" ] || fail 'explicit-setting refusal touched the worker'
  pass "$harness preserves explicit files, invalid values, empty files, links and directories"

  for race in file directory symlink; do
    if run_apply PATH="$BIN:$PATH" TEST_SETTING="$setting" RACE_SETTING_KIND="$race"; then fail "concurrent $race did not win"; fi
    case "$race" in
      file) [ "$(cat "$home/config/$setting")" = bypass ] || fail 'concurrent explicit bytes overwritten'; rm "$home/config/$setting" ;;
      directory) [ -z "$(find "$home/config/$setting" -mindepth 1 -print)" ] || fail 'publication linked inside a concurrent directory'; rmdir "$home/config/$setting" ;;
      symlink) [ -L "$home/config/$setting" ] || fail 'concurrent symlink replaced'; [ -z "$(find "$home/operator-directory" -mindepth 1 -print)" ] || fail 'publication followed a concurrent symlink'; rm "$home/config/$setting"; rmdir "$home/operator-directory" ;;
    esac
  done
  [ "$(wc -l < "$home/control.log")" = "$before" ] || fail 'publication failure touched the worker'
  pass "$harness atomically preserves concurrent explicit destinations"

  printf '%s\n' "$$" > "$home/state/.lock"
  printf 'branch\t%s\t%s\n' "$$" "$(date +%s)" > "$home/state/.lease-task"
  for actor in '' main; do
    rc=0
    run_apply FM_SUPERVISION_ACTOR="$actor" > "$home/lease.out" 2>&1 || rc=$?
    [ "$rc" -eq 6 ] || fail 'other-actor lease did not refuse failover'
    [ ! -e "$home/config/$setting" ] || fail 'lease refusal saved fallback'
    [ "$(wc -l < "$home/control.log")" = "$before" ] || fail 'lease refusal reached lifecycle control'
  done
  run_apply FM_SUPERVISION_ACTOR=branch >/dev/null || fail 'same-actor lifecycle call deadlocked or failed'
  [ "$(cat "$home/config/$setting")" = "$fallback" ] || fail 'authorized actor lost fallback'
  rm "$home/config/$setting" "$home/state/.lease-task" "$home/state/.lock"
  pass "$harness honors live leases before saving and releases its guard before child control"

  # No timestamp or detector state is needed: firstmate supplies the observed
  # failure, including for an existing worker predating launch-mode metadata.
  printf 'harness=%s\n' "$harness" > "$home/state/task.meta"
  run_apply >/dev/null || fail 'manual recovery unnecessarily required detector metadata'
  rm "$home/config/$setting"
  printf 'harness=%s\napproval_mode=%s\n' "$harness" "$fallback" > "$home/state/task.meta"
  if run_apply; then fail 'known non-bypass record accepted'; fi
  [ ! -e "$home/config/$setting" ] || fail 'non-bypass refusal saved fallback'
  printf 'harness=%s\napproval_mode=bypass\nremote_host=another-host\n' "$harness" > "$home/state/task.meta"
  if run_apply; then fail 'remote supervisor record accepted'; fi
  [ ! -e "$home/config/$setting" ] || fail 'remote refusal saved fallback'
  pass "$harness needs no detector state and refuses contradictory or remote records"

  printf 'harness=%s\napproval_mode=bypass\nbackend=t3code\n' "$harness" > "$home/state/task.meta"
  before=$(wc -l < "$home/control.log")
  rc=0
  run_apply > "$home/t3code.out" 2>&1 || rc=$?
  [ "$rc" -eq 1 ] || fail "$harness t3code task was not refused"
  [ -z "$(find "$home/config" -mindepth 1 -print)" ] || fail 't3code refusal changed configuration'
  [ "$(wc -l < "$home/control.log")" = "$before" ] || fail 't3code refusal reached lifecycle control'
  assert_grep "T3's full-access runtime mode and cannot honor config/$setting=$fallback" "$home/t3code.out" 't3code refusal did not name the full-access runtime'
  assert_grep 'approve the pending request in T3 Code itself' "$home/t3code.out" 't3code refusal did not name the remedy'
  pass "$harness refuses a t3code task before saving a fallback T3 cannot honor"

  printf 'harness=%s\napproval_mode=bypass\n' "$harness" > "$home/state/task.meta"
  if run_apply FAIL_CONTROL=1 > "$home/failure.out" 2>&1; then fail 'failed lifecycle claimed success'; fi
  [ "$(cat "$home/config/$setting")" = "$fallback" ] || fail 'lifecycle failure lost saved remedy'
  assert_grep 'fallback saved, but worker recovery failed' "$home/failure.out" 'lifecycle failure was not reported'
  pass "$harness keeps the setting while reporting incomplete recovery"
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
  [ ! -e "$local_config/$setting" ] || fail 'primary absence did not clear local fallback'
  FM_HOME="$remote_home" "$ROOT/bin/fm-remote-inherit.sh" absent "config/$setting" 0 "$empty_hash" 1 >/dev/null || fail 'remote absence transfer failed'
  [ ! -e "$remote_home/config/$setting" ] || fail 'primary absence did not clear remote fallback'
  printf 'bypass\n' > "$primary/$setting"
  propagate_inheritable_config "$primary" "$local_config" || fail 'explicit primary inheritance failed'
  [ "$(cat "$local_config/$setting")" = bypass ] || fail 'explicit primary did not replace local fallback'
  printf 'bypass\n' | FM_HOME="$remote_home" "$ROOT/bin/fm-remote-inherit.sh" put "config/$setting" 7 "$bypass_hash" 2 >/dev/null || fail 'explicit remote transfer failed'
  [ "$(cat "$remote_home/config/$setting")" = bypass ] || fail 'explicit primary did not replace remote fallback'
  rm "$primary/$setting"
  propagate_inheritable_config "$primary" "$local_config" || fail 'local primary removal failed'
  FM_HOME="$remote_home" "$ROOT/bin/fm-remote-inherit.sh" absent "config/$setting" 0 "$empty_hash" 3 >/dev/null || fail 'remote primary removal failed'
  [ ! -e "$local_config/$setting" ] && [ ! -e "$remote_home/config/$setting" ] || fail 'primary removal did not clear inherited modes'
  pass "$setting follows primary values and absence locally and remotely"
done
echo '# all fm-approval-failover tests passed'
