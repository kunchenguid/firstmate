#!/usr/bin/env bash
# tests/fm-launch-secrets.test.sh - config/launch-secrets.json launches a worker
# inside a secret injector, so the named secret reaches only that worker.
#
# The spawn runs for real against a fake pane that EXECUTES the launch it is
# handed, a fake `av` injector, and a harness binary replaced by a probe that
# records the environment it started with. What the probe records is what a
# real worker would have received.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

CONTROL="$ROOT/bin/fm-control.sh"
TMP_ROOT=$(fm_test_tmproot fm-launch-secrets)
SECRET_VALUE="sk-or-test-$$-do-not-leak"

# The fake injector mirrors `av inject +NAME... -- <command>`: it puts each
# named secret in the command's environment and runs it. Each name gets
# FAKE_AV_SECRET_<name> when set, else FAKE_AV_SECRET. FAKE_AV_MODE selects
# a refusal (an approval denied) or a slow approval (FAKE_AV_DELAY seconds).
install_fake_av() {  # <fakebin>
  cat > "$1/av" <<'SH'
#!/bin/sh
[ "${1:-}" = inject ] || exit 64
shift
while [ $# -gt 0 ]; do
  case "$1" in
    --) shift; break ;;
    +*) name=${1#+}; eval "$name=\${FAKE_AV_SECRET_$name-\$FAKE_AV_SECRET}; export $name"; shift ;;
    *) exit 64 ;;
  esac
done
case "${FAKE_AV_MODE:-grant}" in
  refuse) echo 'av: approval denied' >&2; exit 3 ;;
  slow) sleep "${FAKE_AV_DELAY:-2}" ;;
esac
exec "$@"
SH
  chmod +x "$1/av"
}

# The probe stands in for the harness. It answers the spawn's --help probe and
# otherwise records whether it started and the secret it saw.
install_probe() {  # <fakebin> <harness> <record-file> [secret-name]
  cat > "$1/$2" <<SH
#!/bin/sh
case "\${1:-}" in --help|--version) exit 0 ;; esac
printf 'started secret=%s\n' "\${${4:-OPENROUTER_API_KEY}-unset}" >> '$3'
SH
  chmod +x "$1/$2"
}

# The fixture's tmux records launches; this wrapper also runs the staged launch
# file in the background, the way a pane shell sourcing it would. A capture
# reads the pane's output until the window is killed, after which the pane and
# everything it showed are gone.
install_running_pane() {  # <fakebin> <pane-output>
  mv "$1/tmux" "$1/tmux.recorder"
  cat > "$1/tmux" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  capture-pane) [ -e '$2.closed' ] || cat '$2'; exit 0 ;;
  kill-window) : > '$2.closed' ;;
esac
'$1/tmux.recorder' "\$@" || exit \$?
[ "\${1:-}" = send-keys ] || exit 0
for a in "\$@"; do
  case "\$a" in
    ". '"*"'")
      staged=\${a#". '"}
      staged=\${staged%"'"}
      ( /bin/sh "\$staged" >>'$2' 2>&1 </dev/null & )
      ;;
  esac
done
exit 0
SH
  chmod +x "$1/tmux"
}

# make_case <name> <harness> <id> [secret-name] -> sets CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN LAUNCH_LOG PANE_OUT PROBE_LOG
make_case() {
  local name=$1 harness=$2 id=$3 secret=${4:-OPENROUTER_API_KEY}
  CASE_DIR="$TMP_ROOT/$name"
  HOME_DIR="$CASE_DIR/home"
  PROJ_DIR="$CASE_DIR/project"
  WT_DIR="$CASE_DIR/wt"
  LAUNCH_LOG="$CASE_DIR/launch.log"
  PANE_OUT="$CASE_DIR/pane.out"
  PROBE_LOG="$CASE_DIR/probe.log"
  FAKEBIN=$(fm_test_make_spawn_fakebin "$CASE_DIR/fake")
  install_fake_av "$FAKEBIN"
  install_probe "$FAKEBIN" "$harness" "$PROBE_LOG" "$secret"
  install_running_pane "$FAKEBIN" "$PANE_OUT"
  fm_test_spawn_home "$HOME_DIR" "$harness"
  fm_git_worktree "$PROJ_DIR" "$WT_DIR" "wt-$name"
  fm_test_spawn_brief "$HOME_DIR" "$id"
  : > "$LAUNCH_LOG"
  : > "$PANE_OUT"
}

write_config() {  # <harness> [names-json]
  printf '{"injector": ["av", "inject", "+{name}", "--"], "harnesses": {"%s": %s}}\n' \
    "$1" "${2:-[\"OPENROUTER_API_KEY\"]}" > "$HOME_DIR/config/launch-secrets.json"
}

run_spawn() {  # <id> [extra spawn args...]
  local id=$1
  shift
  FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" FAKE_AV_SECRET="$SECRET_VALUE" \
    FM_LAUNCH_SECRETS_TIMEOUT="${TIMEOUT:-20}" FM_LAUNCH_SECRETS_POLL="${POLL:-0.05}" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN" "$id" "$PROJ_DIR" \
    --mode no-mistakes --yolo off "$@"
}

# wait_for_probe <want-lines>: the pane runs in the background.
wait_for_probe() {
  local i=0
  while [ "$i" -lt 100 ]; do
    [ "$({ wc -l < "$PROBE_LOG"; } 2>/dev/null || echo 0)" -ge "$1" ] && return 0
    sleep 0.05
    i=$((i + 1))
  done
  return 1
}

# The secret value must never be written anywhere Firstmate keeps text: the
# home (task record, status, data), the staged launch namespace, the launch
# text the pane received, the pane's own output, or the spawn's output.
assert_secret_not_leaked() {  # <id> <spawn-output> <label>
  local id=$1 out=$2 label=$3 hits
  hits=$(grep -rlF -- "$SECRET_VALUE" "$HOME_DIR" "$LAUNCH_LOG" "$PANE_OUT" /tmp/fm-"$id"+* 2>/dev/null || true)
  [ -z "$hits" ] || fail "$label: the secret value was written to: $hits"
  case "$out" in
    *"$SECRET_VALUE"*) fail "$label: the secret value appeared in the spawn output" ;;
  esac
}

test_absent_config_is_unchanged() {
  local out status
  make_case absent pi absent-a1
  out=$(run_spawn absent-a1)
  status=$?
  expect_code 0 "$status" "spawn without launch secrets should succeed: $out"
  assert_not_contains "$(cat "$LAUNCH_LOG")" "$FAKEBIN/av" \
    "an absent config must not wrap the launch in an injector"
  assert_not_contains "$(cat "$LAUNCH_LOG")" 'spawn already gave up' \
    "an absent config must not add the launch handshake"
  wait_for_probe 1 || fail "absent config: the worker never started; pane output: $(cat "$PANE_OUT")"
  assert_equals 'started secret=unset' "$(cat "$PROBE_LOG")" \
    "an absent config must launch the worker with no injected secret"
  pass "an absent launch-secrets config launches the worker unwrapped"
}

test_other_harness_is_unchanged() {
  local out status
  make_case other-harness pi other-a1
  write_config claude
  out=$(run_spawn other-a1)
  status=$?
  expect_code 0 "$status" "spawn with secrets only for another harness should succeed: $out"
  assert_not_contains "$(cat "$LAUNCH_LOG")" "$FAKEBIN/av" \
    "secrets configured for another harness must not wrap this launch"
  pass "secrets configured for another harness leave this harness's launch unwrapped"
}

test_configured_injects_the_secret() {
  local allowlist out status launch
  for allowlist in absent enabled; do
    make_case "inject-$allowlist" pi "inject-$allowlist-a1"
    write_config pi
    [ "$allowlist" = absent ] || : > "$HOME_DIR/config/launch-env-allowlist"
    out=$(run_spawn "inject-$allowlist-a1")
    status=$?
    expect_code 0 "$status" "allowlist=$allowlist: spawn with launch secrets should succeed: $out"
    launch=$(cat "$LAUNCH_LOG")
    assert_contains "$launch" "'$FAKEBIN/av' 'inject' '+OPENROUTER_API_KEY' '--' /bin/sh -c" \
      "allowlist=$allowlist: the launch must run inside the configured injector"
    wait_for_probe 1 || fail "allowlist=$allowlist: the worker never started; pane output: $(cat "$PANE_OUT")"
    assert_equals "started secret=$SECRET_VALUE" "$(cat "$PROBE_LOG")" \
      "allowlist=$allowlist: the worker must start with the injected secret"
    assert_secret_not_leaked "inject-$allowlist-a1" "$out" "allowlist=$allowlist"
  done
  pass "a configured injector hands the secret to the worker alone, with or without the env allowlist"
}

test_every_listed_name_is_injected() {
  local allowlist id out status
  for allowlist in absent enabled; do
    id="two-$allowlist-a1"
    make_case "two-$allowlist" pi "$id"
    cat > "$FAKEBIN/pi" <<SH
#!/bin/sh
case "\${1:-}" in --help|--version) exit 0 ;; esac
printf 'started first=%s second=%s\n' "\${OPENROUTER_API_KEY-unset}" "\${OTHER_KEY-unset}" >> '$PROBE_LOG'
SH
    write_config pi '["OPENROUTER_API_KEY", "OTHER_KEY"]'
    [ "$allowlist" = absent ] || : > "$HOME_DIR/config/launch-env-allowlist"
    out=$(FAKE_AV_SECRET_OTHER_KEY="$SECRET_VALUE-second" run_spawn "$id")
    status=$?
    expect_code 0 "$status" "allowlist=$allowlist: spawn with two secrets should succeed: $out"
    assert_contains "$(cat "$LAUNCH_LOG")" "'inject' '+OPENROUTER_API_KEY' '+OTHER_KEY' '--'" \
      "allowlist=$allowlist: each listed name must expand the {name} element once, in order"
    wait_for_probe 1 || fail "allowlist=$allowlist: the worker never started; pane output: $(cat "$PANE_OUT")"
    assert_equals "started first=$SECRET_VALUE second=$SECRET_VALUE-second" "$(cat "$PROBE_LOG")" \
      "allowlist=$allowlist: the worker must start with each secret under its own name"
    assert_secret_not_leaked "$id" "$out" "two names, allowlist=$allowlist"
  done
  pass "every listed secret reaches the worker under its own name, with or without the env allowlist"
}

test_refusing_injector_stops_the_spawn() {
  local out status
  make_case refuse pi refuse-a1
  write_config pi
  out=$(FAKE_AV_MODE=refuse run_spawn refuse-a1)
  status=$?
  [ "$status" -ne 0 ] || fail "a refusing injector must fail the spawn: $out"
  assert_contains "$out" 'refused (exit 3)' "the spawn must report the injector's refusal"
  [ -e "$PANE_OUT.closed" ] || fail "a refusing injector must close the worker's endpoint"
  assert_contains "$out" 'the pane last showed: av: approval denied' \
    "the spawn must carry the injector's own message past the closed pane"
  assert_contains "$(cat "$HOME_DIR/state/refuse-a1.status")" 'the secret injector refused (exit 3)' \
    "the task status must record the refusal"
  assert_contains "$(cat "$HOME_DIR/state/refuse-a1.status")" 'the pane last showed: av: approval denied' \
    "the task status must record the injector's own message"
  [ ! -s "$PROBE_LOG" ] || fail "a refusing injector must not start the worker: $(cat "$PROBE_LOG")"
  assert_secret_not_leaked refuse-a1 "$out" "refusal"
  pass "a refusing injector stops the spawn with its exit status and never starts the worker"
}

test_stopped_spawn_takes_the_claim_and_closes_the_pane() {
  local id=term-a1 out_file pid i
  make_case term pi "$id"
  write_config pi
  out_file="$CASE_DIR/spawn.out"
  FAKE_AV_MODE=slow FAKE_AV_DELAY=3 TIMEOUT=60 run_spawn "$id" > "$out_file" 2>&1 &
  pid=$!
  i=0
  until grep -q "$FAKEBIN/av" "$LAUNCH_LOG" 2>/dev/null || [ "$i" -ge 200 ]; do
    sleep 0.05
    i=$((i + 1))
  done
  sleep 1
  pkill -TERM -f "bin/fm-spawn.sh $id " || fail "the spawn was not waiting on the approval: $(cat "$out_file")"
  wait "$pid"
  [ -e "$PANE_OUT.closed" ] || fail "a spawn stopped mid-approval must close the worker's endpoint: $(cat "$out_file")"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "a spawn stopped mid-approval must not leave a task record"
  i=0
  until grep -q 'spawn already gave up' "$PANE_OUT" 2>/dev/null || [ "$i" -ge 100 ]; do
    sleep 0.05
    i=$((i + 1))
  done
  assert_contains "$(cat "$PANE_OUT")" 'spawn already gave up' \
    "a late approval must not start the worker of a spawn that was stopped"
  [ ! -s "$PROBE_LOG" ] || fail "a late approval started an orphaned worker: $(cat "$PROBE_LOG")"
  pass "a spawn stopped during the approval takes the claim, so the late approval cannot start an orphan"
}

# The worker wins the claim during the spawn's poll sleep, and only then is the
# spawn stopped: the abort removes the fresh task record, so it must close the
# endpoint of the worker that already started rather than leave it running.
test_stopped_spawn_after_the_worker_claims_closes_the_pane() {
  local id=term-late-a1 out_file pid
  make_case term-late pi "$id"
  write_config pi
  out_file="$CASE_DIR/spawn.out"
  FAKE_AV_MODE=slow FAKE_AV_DELAY=1 POLL=10 TIMEOUT=60 run_spawn "$id" > "$out_file" 2>&1 &
  pid=$!
  wait_for_probe 1 || fail "the worker never started before the spawn was stopped: $(cat "$out_file")"
  pkill -TERM -f "bin/fm-spawn.sh $id " || fail "the spawn was not waiting on the handshake: $(cat "$out_file")"
  wait "$pid"
  [ -e "$PANE_OUT.closed" ] || fail "a spawn stopped after its worker started must close the worker's endpoint: $(cat "$out_file")"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "a spawn stopped mid-handshake must not leave a task record"
  pass "a spawn stopped after its worker claimed the launch closes that worker's endpoint with its record"
}

# The fake pi answers the pin's sign-in check the way the real one does: an
# OPENROUTER_API_KEY in its environment signs the openrouter provider in
# (tests/fm-worker-account-live-e2e.test.sh proves that for real Pi).
install_pinned_pi() {  # <fakebin> <record-file> <check-file>
  cat > "$1/pi" <<SH
#!/bin/sh
case "\${1:-}" in
  --help|--version) exit 0 ;;
  auth)
    printf 'check secret=%s\n' "\${OPENROUTER_API_KEY-unset}" >> '$3'
    if [ "\$4" = openrouter ] && [ -n "\${OPENROUTER_API_KEY:-}" ]; then
      printf '{"status":"ready","provider":"openrouter"}\n'
      exit 0
    fi
    printf '{"status":"not_ready","provider":"%s","reason":"credentials_not_configured"}\n' "\$4"
    exit 1
    ;;
  --list-models) printf 'provider  model  context\n'; exit 0 ;;
esac
printf 'started secret=%s\n' "\${OPENROUTER_API_KEY-unset}" >> '$2'
SH
  chmod +x "$1/pi"
}

test_pinned_pi_account_counts_the_injected_key() {
  local names id out status checks
  for names in '["OPENROUTER_API_KEY"]' '["OTHER_KEY"]'; do
    id="pin-$( [ "$names" = '["OPENROUTER_API_KEY"]' ] && echo inj || echo other )-a1"
    make_case "$id" pi "$id"
    checks="$CASE_DIR/checks.log"
    install_pinned_pi "$FAKEBIN" "$PROBE_LOG" "$checks"
    mkdir -p "$CASE_DIR/pi-root"
    printf '%s\nopenrouter\n' "$CASE_DIR/pi-root" > "$HOME_DIR/config/pi-account"
    write_config pi "$names"
    out=$(OPENROUTER_API_KEY='' run_spawn "$id" --model openrouter/z-ai/glm-5.3)
    status=$?
    assert_secret_not_leaked "$id" "$out" "pin $names"
    assert_not_contains "$(cat "$checks" 2>/dev/null)" "$SECRET_VALUE" \
      "pin $names: the sign-in check must never receive the secret value"
    if [ "$names" = '["OPENROUTER_API_KEY"]' ]; then
      expect_code 0 "$status" "a pinned Pi spawn whose provider key is injected should pass the sign-in check: $out"
      wait_for_probe 1 || fail "pinned pi: the worker never started; pane output: $(cat "$PANE_OUT")"
      assert_equals "started secret=$SECRET_VALUE" "$(cat "$PROBE_LOG")" \
        "the pinned Pi worker must start with the injected provider key"
    else
      [ "$status" -ne 0 ] || fail "a pinned Pi spawn whose injected names do not sign its provider in must refuse: $out"
      assert_contains "$out" "not signed in for provider 'openrouter'" "the refusal must name the provider"
      [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "the refusal must come before any task record exists"
    fi
  done
  pass "a pinned Pi account's sign-in check counts the provider key the launch injects, and only that"
}

test_invalid_timeout_refuses_before_any_record() {
  local out status
  make_case bad-timeout pi bad-timeout-a1
  write_config pi
  out=$(TIMEOUT=5m run_spawn bad-timeout-a1)
  status=$?
  [ "$status" -ne 0 ] || fail "a non-integer timeout must refuse the spawn: $out"
  assert_contains "$out" "FM_LAUNCH_SECRETS_TIMEOUT must be a non-negative integer" \
    "the refusal must name the invalid timeout"
  [ ! -e "$HOME_DIR/state/bad-timeout-a1.meta" ] || fail "a non-integer timeout must refuse before any task record exists"
  [ ! -s "$LAUNCH_LOG" ] || fail "a non-integer timeout must refuse before any launch: $(cat "$LAUNCH_LOG")"
  pass "a non-integer launch-secrets timeout refuses the spawn before any record or launch exists"
}

test_muse_injected_key_satisfies_the_credential_preflight() {
  local out status
  make_case muse muse muse-a1 META_API_KEY
  write_config muse '["META_API_KEY"]'
  mkdir -p "$CASE_DIR/xdgconfig" "$CASE_DIR/xdgdata"
  out=$(XDG_CONFIG_HOME="$CASE_DIR/xdgconfig" XDG_DATA_HOME="$CASE_DIR/xdgdata" META_API_KEY='' \
    run_spawn muse-a1)
  status=$?
  expect_code 0 "$status" "a muse spawn whose META_API_KEY is injected should pass the credential preflight: $out"
  wait_for_probe 1 || fail "muse: the worker never started; pane output: $(cat "$PANE_OUT")"
  assert_equals "started secret=$SECRET_VALUE" "$(cat "$PROBE_LOG")" \
    "the muse worker must start with the injected META_API_KEY"
  assert_secret_not_leaked muse-a1 "$out" "muse"
  pass "a META_API_KEY injected for muse satisfies its credential preflight without a stored login"
}

test_slow_injector_times_out_and_cannot_start_late() {
  local out status i
  make_case slow pi slow-a1
  write_config pi
  out=$(FAKE_AV_MODE=slow FAKE_AV_DELAY=2 TIMEOUT=1 run_spawn slow-a1)
  status=$?
  [ "$status" -ne 0 ] || fail "an injector that never starts the worker in time must fail the spawn: $out"
  assert_contains "$out" 'did not start the worker within 1s' "the spawn must report the timeout"
  # Let the late approval land: it must find the spawn's claim and refuse.
  i=0
  until grep -q 'spawn already gave up' "$PANE_OUT" 2>/dev/null || [ "$i" -ge 100 ]; do
    sleep 0.05
    i=$((i + 1))
  done
  assert_contains "$(cat "$PANE_OUT")" 'spawn already gave up' \
    "a late approval must not start the worker the spawn already failed"
  [ ! -s "$PROBE_LOG" ] || fail "a late approval started the worker: $(cat "$PROBE_LOG")"
  pass "a timed-out injector fails the spawn and its late approval cannot start the worker"
}

test_missing_injector_refuses_before_any_record() {
  local out status
  make_case missing pi missing-a1
  printf '{"injector": ["fm-no-such-injector", "+{name}"], "harnesses": {"pi": ["OPENROUTER_API_KEY"]}}\n' \
    > "$HOME_DIR/config/launch-secrets.json"
  out=$(run_spawn missing-a1)
  status=$?
  [ "$status" -ne 0 ] || fail "a missing injector must refuse the spawn: $out"
  assert_contains "$out" "injector 'fm-no-such-injector'" "the refusal must name the missing injector"
  [ ! -e "$HOME_DIR/state/missing-a1.meta" ] || fail "a missing injector must refuse before any task record exists"
  [ ! -s "$LAUNCH_LOG" ] || fail "a missing injector must refuse before any launch: $(cat "$LAUNCH_LOG")"
  pass "a missing injector refuses the spawn before any record or launch exists"
}

test_malformed_config_refuses() {
  local bad out status
  for bad in '{"injector": ["av", "inject", "--"], "harnesses": {"pi": ["OPENROUTER_API_KEY"]}}' \
    '{"injector": ["av", "inject", "+{name}", "--"], "harnesses": {"pi": ["NOT-A-NAME"]}}' \
    '{"injector": ["{name}"], "harnesses": {"pi": ["K"]}}' \
    'not json'; do
    make_case malformed pi malformed-a1
    printf '%s\n' "$bad" > "$HOME_DIR/config/launch-secrets.json"
    out=$(run_spawn malformed-a1)
    status=$?
    [ "$status" -ne 0 ] || fail "malformed config '$bad' must refuse the spawn: $out"
    assert_contains "$out" 'config/launch-secrets.json must be' "malformed config '$bad' must name the schema"
    [ ! -e "$HOME_DIR/state/malformed-a1.meta" ] || fail "malformed config '$bad' must refuse before any task record exists"
    rm -rf "$CASE_DIR"
  done
  pass "a malformed launch-secrets config refuses the spawn before any record exists"
}

# --- relaunch ---------------------------------------------------------------
#
# bin/fm-control.sh relaunch rebuilds the launch through bin/fm-spawn.sh
# --relaunch. This stub models the pane just enough for that transaction: the
# harness exit command leaves a shell behind, and the staged launch both
# restarts the harness and runs, so the replacement worker really starts.
make_relaunch_stub() {  # <fakebin> <fake-state-dir> <pane-output>
  cat > "$1/tmux" <<SH
#!/usr/bin/env bash
set -u
D='$2'
case "\${1:-}" in
  send-keys)
    shift
    literal=0
    while [ \$# -gt 0 ]; do
      case "\$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    payload=\${1:-}
    if [ "\$literal" = 1 ]; then
      case "\$payload" in
        ". '"*"'")
          staged=\${payload#". '"}
          staged=\${staged%"'"}
          if [ -f "\$staged" ]; then
            payload=\$(cat "\$staged")
            printf 'codex' > "\$D/command"
            ( /bin/sh "\$staged" >>'$3' 2>&1 </dev/null & )
          fi
          ;;
      esac
      printf '%s\n' "\$payload" >> "\$D/literal"
      case "\$payload" in
        /exit|/quit) printf 'zsh' > "\$D/command" ;;
      esac
    fi
    exit 0 ;;
  display-message)
    for a in "\$@"; do
      case "\$a" in
        *cursor_y*) printf '1\n'; exit 0 ;;
        *pane_current_command*) cat "\$D/command"; printf '\n'; exit 0 ;;
        *pane_current_path*) cat "\$D/cwd"; printf '\n'; exit 0 ;;
      esac
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) [ -f "\$D/windows" ] && cat "\$D/windows"; exit 0 ;;
esac
exit 0
SH
  chmod +x "$1/tmux"
}

# setup_relaunch <name> <id> -> sets R_DIR R_HOME R_WT R_FB R_PROBE R_PANE
setup_relaunch() {
  local name=$1 id=$2 proj
  R_DIR="$TMP_ROOT/$name"
  R_HOME="$R_DIR/home"
  proj="$R_DIR/proj"
  R_WT="$R_DIR/wt"
  R_FB="$R_DIR/fakebin"
  R_PROBE="$R_DIR/probe.log"
  R_PANE="$R_DIR/pane.out"
  mkdir -p "$R_HOME/state" "$R_HOME/data" "$R_HOME/config" "$R_HOME/projects" "$R_DIR/fake" "$R_FB" "$R_DIR/user-home"
  touch "$R_HOME/state/.last-watcher-beat"
  make_relaunch_stub "$R_FB" "$R_DIR/fake" "$R_PANE"
  install_fake_av "$R_FB"
  install_probe "$R_FB" codex "$R_PROBE"
  fm_git_worktree "$proj" "$R_WT" "wt-$name"
  fm_test_spawn_brief "$R_HOME" "$id"
  : > "$R_DIR/fake/literal"
  : > "$R_PANE"
  printf 'codex' > "$R_DIR/fake/command"
  printf '%s\n' "fm-$id" > "$R_DIR/fake/windows"
  printf '%s' "$R_WT" > "$R_DIR/fake/cwd"
  {
    echo "window=fmses:fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$R_WT"
    echo "project=$proj"
    echo "harness=codex"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "tasktmp=$R_DIR/tasktmp"
    echo "model=default"
    echo "effort=default"
  } > "$R_HOME/state/$id.meta"
}

run_relaunch() {  # <id>
  env PATH="$R_FB:$PATH" FM_HOME="$R_HOME" HOME="$R_DIR/user-home" CLAUDE_CONFIG_DIR='' \
    FM_SPAWN_NO_GUARD=1 FAKE_AV_SECRET="$SECRET_VALUE" \
    FM_LAUNCH_SECRETS_TIMEOUT=20 FM_LAUNCH_SECRETS_POLL=0.05 \
    FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_LAUNCH_WAIT=0.05 \
    "$CONTROL" "$1" relaunch --note 'replacement continues the same task' 2>&1
}

test_relaunch_injects_the_secret() {
  local id=relaunch-a1 out status
  setup_relaunch relaunch "$id"
  printf '{"injector": ["av", "inject", "+{name}", "--"], "harnesses": {"codex": ["OPENROUTER_API_KEY"]}}\n' \
    > "$R_HOME/config/launch-secrets.json"
  out=$(run_relaunch "$id")
  status=$?
  expect_code 0 "$status" "relaunch with launch secrets should succeed: $out"
  assert_contains "$(cat "$R_DIR/fake/literal")" "'$R_FB/av' 'inject' '+OPENROUTER_API_KEY' '--'" \
    "the replacement launch must run inside the configured injector"
  PROBE_LOG=$R_PROBE
  wait_for_probe 1 || fail "relaunch: the replacement worker never started; pane output: $(cat "$R_PANE")"
  assert_equals "started secret=$SECRET_VALUE" "$(cat "$R_PROBE")" \
    "the replacement worker must start with the injected secret"
  HOME_DIR=$R_HOME LAUNCH_LOG="$R_DIR/fake/literal" PANE_OUT=$R_PANE \
    assert_secret_not_leaked "$id" "$out" relaunch
  pass "relaunch rebuilds the launch inside the injector and the replacement worker gets the secret"
}

test_relaunch_refuses_a_broken_secrets_file_before_stopping_the_agent() {
  local id=relaunch-bad-a1 out status
  setup_relaunch relaunch-bad "$id"
  printf '{"injector": ["av", "inject", "--"], "harnesses": {"codex": ["OPENROUTER_API_KEY"]}}\n' \
    > "$R_HOME/config/launch-secrets.json"
  out=$(run_relaunch "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "relaunch with a malformed launch-secrets file must refuse: $out"
  assert_contains "$out" 'config/launch-secrets.json must be' "the refusal must name the schema"
  assert_equals '' "$(cat "$R_DIR/fake/literal")" "the running agent must not be stopped or relaunched"
  assert_equals codex "$(cat "$R_DIR/fake/command")" "the running agent must keep running"
  pass "relaunch refuses a malformed launch-secrets file before it stops the running agent"
}

test_absent_config_is_unchanged
test_other_harness_is_unchanged
test_configured_injects_the_secret
test_every_listed_name_is_injected
test_refusing_injector_stops_the_spawn
test_stopped_spawn_takes_the_claim_and_closes_the_pane
test_stopped_spawn_after_the_worker_claims_closes_the_pane
test_pinned_pi_account_counts_the_injected_key
test_invalid_timeout_refuses_before_any_record
test_muse_injected_key_satisfies_the_credential_preflight
test_slow_injector_times_out_and_cannot_start_late
test_missing_injector_refuses_before_any_record
test_malformed_config_refuses
test_relaunch_injects_the_secret
test_relaunch_refuses_a_broken_secrets_file_before_stopping_the_agent
