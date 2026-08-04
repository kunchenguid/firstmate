#!/usr/bin/env bash
# Behavior tests for measured fleet liveness.
# Every classifier row names both its firing input and its legitimate refusal.
# The final mutation matrix neutralizes each evidence guard and requires the
# active assertion to go RED, so no row can pass vacuously.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIVENESS=${FM_LIVENESS_UNDER_TEST:-$ROOT/bin/fm-liveness-snapshot.sh}
TMP_ROOT=$(fm_test_tmproot fm-liveness-snapshot)
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
trap fm_test_cleanup EXIT

make_case() {  # <name> <harness>
  local dir=$TMP_ROOT/$1 harness=$2
  mkdir -p "$dir/home/state" "$dir/wt" "$dir/bin"
  fm_write_meta "$dir/home/state/task.meta" \
    "window=fm:fm-task" "worktree=$dir/wt" "harness=$harness" "kind=ship"
  printf '%s\n' "$dir"
}

install_evidence() {  # <dir>
  local dir=$1
  cat > "$dir/bin/endpoint" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${E_ENDPOINT:-alive}"
SH
  cat > "$dir/bin/capture" <<'SH'
#!/usr/bin/env bash
count_file=${E_DIR:?}/capture.count
n=$(cat "$count_file" 2>/dev/null || printf 0)
n=$((n + 1))
printf '%s' "$n" > "$count_file"
case "${E_OUTPUT:-static}" in
  changing) printf 'frame-%s\n' "$n" ;;
  fail) exit 1 ;;
  *) printf 'same-frame\n' ;;
esac
SH
  cat > "$dir/bin/process" <<'SH'
#!/usr/bin/env bash
count_file=${E_DIR:?}/process.count
n=$(cat "$count_file" 2>/dev/null || printf 0)
n=$((n + 1))
printf '%s' "$n" > "$count_file"
wt=${E_WT:?}
family=${E_FAMILY:-claude}
case "$family" in claude) worker=claude ;; codex) worker=codex ;; *) worker=$family ;; esac
case "${E_PROCESS:-working}" in
  working)
    if [ "$n" -eq 1 ]; then cpu=1000; else cpu=${E_CPU2:-1030}; fi
    printf '11\t%s\t%s\t%s\n' "$cpu" "$worker" "$wt"
    ;;
  launcher-trap)
    if [ "$n" -eq 1 ]; then real=5000; else real=5002; fi
    printf '10\t40\tnode\t%s\n' "$wt"
    printf '11\t%s\t%s\t%s\n' "$real" "$worker" "$wt"
    ;;
  same-family-max)
    if [ "$n" -eq 1 ]; then high=5000; else high=5002; fi
    printf '10\t40\t%s\t%s\n' "$worker" "$wt"
    printf '11\t%s\t%s\t%s\n' "$high" "$worker" "$wt"
    ;;
  parked-high-total)
    printf '11\t500000\t%s\t%s\n' "$worker" "$wt"
    ;;
  wrong-cwd)
    printf '11\t9000\t%s\t%s-other\n' "$worker" "$wt"
    ;;
  shells-only)
    if [ "$n" -eq 1 ]; then cpu=1000; else cpu=9000; fi
    printf '11\t%s\tzsh\t%s\n' "$cpu" "$wt"
    ;;
  parked-worker-busy-shells)
    if [ "$n" -eq 1 ]; then shell_cpu=1000; else shell_cpu=9000; fi
    printf '11\t500000\t%s\t%s\n' "$worker" "$wt"
    printf '12\t%s\tzsh\t%s\n' "$shell_cpu" "$wt"
    ;;
  fail) exit 1 ;;
esac
SH
  chmod +x "$dir/bin/endpoint" "$dir/bin/capture" "$dir/bin/process"
}

install_remote_evidence() {  # <dir>
  local dir=$1
  cat > "$dir/bin/remote" <<'SH'
#!/usr/bin/env bash
printf 'remote\n' >> "${E_DIR:?}/remote.log"
[ "${E_REMOTE:-ok}" = ok ] || exit 1
id=$1
interval=$2
jq -n --arg id "$id" --argjson interval "$interval" '
  {schema:"fm-liveness.v1",observed_at:"2026-08-03T12:00:00Z",interval_ms:$interval,
   process_samples:{sample_1_readable:true,sample_2_readable:true},
   records:[{id:$id,harness:"claude",harness_family:"claude",backend:"tmux",
     target:"remote-session:fm-task",worktree:"remote-worktree",
     endpoint:{presence:"verified_present",raw:"alive"},
     worker:{presence:"verified_present",pids_sample_1:1,pids_sample_2:1,
       harness_processes_sample_1:1,harness_processes_sample_2:1},
     output:{sample_1_readable:true,sample_2_readable:true,changed:false},
     cpu:{sample_1_max_ms:5000,sample_2_max_ms:5000,delta_ms:0,rate_ms_per_minute:0,
       baseline:"verified",threshold_ms_per_minute:760},activity:"parked"}]}'
SH
  chmod +x "$dir/bin/remote"
}

run_case() {  # <dir> [env assignments through caller]
  local dir=$1
  rm -f "$dir"/*.count
  FM_HOME="$dir/home" FM_LIVENESS_INTERVAL_MS=100 FM_LIVENESS_NOW=2026-08-03T12:00:00Z \
    FM_LIVENESS_ENDPOINT_BIN="$dir/bin/endpoint" \
    FM_LIVENESS_CAPTURE_BIN="$dir/bin/capture" \
    FM_LIVENESS_PROCESS_SNAPSHOT_BIN="$dir/bin/process" \
    E_DIR="$dir" E_WT="$dir/wt" "$LIVENESS" --json
}

assert_activity() {  # <json> <activity> <message>
  printf '%s' "$1" | jq -e --arg a "$2" '.records == [(.records[0] | select(.activity==$a))]' >/dev/null \
    || fail "$3: $1"
}

test_harness_relative_cpu_rows() {
  local dir json
  dir=$(make_case claude-active claude); install_evidence "$dir"
  json=$(E_FAMILY=claude E_PROCESS=working E_CPU2=1002 run_case "$dir")
  printf '%s' "$json" | jq -e '.records[0] | .activity=="active" and .cpu.threshold_ms_per_minute==760 and .cpu.delta_ms==2' >/dev/null \
    || fail "Claude row did not fire on a 2ms cumulative delta over 100ms: $json"

  dir=$(make_case claude-refusal claude); install_evidence "$dir"
  json=$(E_FAMILY=claude E_PROCESS=working E_CPU2=1001 run_case "$dir")
  assert_activity "$json" parked "Claude row did not refuse its legitimate idle-baseline input"

  dir=$(make_case codex-active codex); install_evidence "$dir"
  json=$(E_FAMILY=codex E_PROCESS=working E_CPU2=1001 run_case "$dir")
  printf '%s' "$json" | jq -e '.records[0] | .activity=="active" and .cpu.threshold_ms_per_minute==400 and .cpu.delta_ms==1' >/dev/null \
    || fail "Codex row did not fire on its own measured working delta: $json"

  dir=$(make_case codex-refusal codex); install_evidence "$dir"
  json=$(E_FAMILY=codex E_PROCESS=working E_CPU2=1000 run_case "$dir")
  assert_activity "$json" parked "Codex row did not refuse its legitimate zero-delta parked input"
  pass "harness-relative CPU rows fire and refuse independently for Claude and Codex"
}

test_max_cpu_launcher_and_two_sample_delta() {
  local dir json
  dir=$(make_case launcher-max codex); install_evidence "$dir"
  json=$(E_FAMILY=codex E_PROCESS=launcher-trap run_case "$dir")
  printf '%s' "$json" | jq -e '.records[0] | .activity=="active" and .cpu.sample_1_max_ms==5000 and .cpu.sample_2_max_ms==5002' >/dev/null \
    || fail "max-CPU guard trusted the thin launcher instead of the real child: $json"

  dir=$(make_case same-family-max claude); install_evidence "$dir"
  json=$(E_FAMILY=claude E_PROCESS=same-family-max run_case "$dir")
  printf '%s' "$json" | jq -e '.records[0] | .activity=="active" and .cpu.sample_1_max_ms==5000 and .cpu.sample_2_max_ms==5002' >/dev/null \
    || fail "max-CPU guard trusted the first same-family wrapper instead of the busy worker: $json"

  dir=$(make_case cumulative-not-percent claude); install_evidence "$dir"
  json=$(E_FAMILY=claude E_PROCESS=parked-high-total run_case "$dir")
  printf '%s' "$json" | jq -e '.records[0] | .activity=="parked" and .cpu.sample_1_max_ms==500000 and .cpu.delta_ms==0' >/dev/null \
    || fail "two-sample guard mistook a high lifetime total for current activity: $json"
  pass "max CPU crosses launcher wrappers and only a two-sample delta establishes activity"
}

test_real_process_snapshot_accepts_partial_lsof_output() {
  local dir json real_lsof
  command -v lsof >/dev/null 2>&1 || { echo "skip: lsof not found (real process snapshot)"; return; }
  real_lsof=$(command -v lsof)
  dir=$(make_case real-process-snapshot codex); install_evidence "$dir"
  cat > "$dir/bin/lsof" <<SH
#!/usr/bin/env bash
"$real_lsof" "\$@"
rc=\$?
[ -t 1 ] || exit 1
exit "\$rc"
SH
  chmod +x "$dir/bin/lsof"
  rm -f "$dir"/*.count
  json=$(PATH="$dir/bin:$PATH" FM_HOME="$dir/home" FM_LIVENESS_INTERVAL_MS=100 \
    FM_LIVENESS_NOW=2026-08-03T12:00:00Z \
    FM_LIVENESS_ENDPOINT_BIN="$dir/bin/endpoint" \
    FM_LIVENESS_CAPTURE_BIN="$dir/bin/capture" \
    E_DIR="$dir" E_WT="$dir/wt" "$LIVENESS" --json)
  printf '%s' "$json" | jq -e '
    .process_samples.sample_1_readable == true
    and .process_samples.sample_2_readable == true
  ' >/dev/null || fail "real ps/lsof process snapshot discarded nonempty evidence after a nonzero lsof exit: $json"
  pass "real process_snapshot accepts live process-table evidence when lsof emits output and exits nonzero"
}

test_cwd_binding_and_shell_amplifier_refusals() {
  local dir json
  dir=$(make_case wrong-cwd claude); install_evidence "$dir"
  json=$(E_FAMILY=claude E_PROCESS=wrong-cwd run_case "$dir")
  printf '%s' "$json" | jq -e '.records[0] | .worker.presence=="verified_absent" and .activity=="inactive"' >/dev/null \
    || fail "process from another cwd was attributed to this task: $json"

  dir=$(make_case shell-amplifier claude); install_evidence "$dir"
  json=$(E_FAMILY=claude E_PROCESS=shells-only run_case "$dir")
  printf '%s' "$json" | jq -e '.records[0] | .cpu.delta_ms==0 and .worker.presence=="verified_absent" and .activity=="inactive"' >/dev/null \
    || fail "background shells amplified into a live-worker verdict: $json"

  dir=$(make_case retained-shell-amplifier claude); install_evidence "$dir"
  json=$(E_FAMILY=claude E_PROCESS=parked-worker-busy-shells run_case "$dir")
  printf '%s' "$json" | jq -e '.records[0] | .worker.presence=="verified_present" and .cpu.sample_1_max_ms==500000 and .cpu.sample_2_max_ms==500000 and .cpu.delta_ms==0 and .activity=="parked"' >/dev/null \
    || fail "busy background shells amplified a retained parked worker into activity: $json"
  pass "exact CWD binding refuses another worktree and background shells cannot amplify worker CPU"
}

test_endpoint_three_way_and_output_activity() {
  local dir json
  dir=$(make_case endpoint-present claude); install_evidence "$dir"
  json=$(E_ENDPOINT=alive E_FAMILY=claude E_PROCESS=working E_CPU2=1000 E_OUTPUT=changing run_case "$dir")
  printf '%s' "$json" | jq -e '.records[0] | .endpoint.presence=="verified_present" and .output.changed==true and .activity=="active"' >/dev/null \
    || fail "changed output did not establish activity independently of CPU: $json"

  dir=$(make_case endpoint-absent claude); install_evidence "$dir"
  json=$(E_ENDPOINT=missing E_FAMILY=claude E_PROCESS=working run_case "$dir")
  printf '%s' "$json" | jq -e '.records[0] | .endpoint.presence=="verified_absent" and .activity=="absent"' >/dev/null \
    || fail "authoritatively missing endpoint was not absent: $json"

  dir=$(make_case endpoint-unverified claude); install_evidence "$dir"
  json=$(E_ENDPOINT=unreadable E_FAMILY=claude E_PROCESS=working run_case "$dir")
  printf '%s' "$json" | jq -e '.records[0] | .endpoint.presence=="unverified" and .activity=="unverified"' >/dev/null \
    || fail "unreadable endpoint was silently collapsed to present or absent: $json"
  pass "endpoint presence is three-way and changed output independently establishes work"
}

test_remote_routes_use_remote_endpoint_evidence() {
  local dir json
  dir=$(make_case remote-route claude)
  install_evidence "$dir"
  install_remote_evidence "$dir"
  cat >> "$dir/home/state/task.meta" <<EOF
remote_host=fixture-host
remote_root=/remote/firstmate
remote_backend=tmux
remote_target=remote-session:fm-task
worktree=remote-worktree
EOF
  json=$(FM_LIVENESS_REMOTE_BIN="$dir/bin/remote" E_REMOTE=ok run_case "$dir")
  printf '%s' "$json" | jq -e '
    .records[0] | .backend=="tmux" and .target=="remote-session:fm-task"
      and .endpoint.presence=="verified_present" and .worker.presence=="verified_present"
      and .activity=="parked"
  ' >/dev/null || fail "remote route did not retain its remote backend evidence: $json"
  [ "$(wc -l < "$dir/remote.log" | tr -d ' ')" = 1 ] \
    || fail "remote liveness evidence producer was not called exactly once"

  : > "$dir/remote.log"
  json=$(FM_LIVENESS_REMOTE_BIN="$dir/bin/remote" E_REMOTE=fail run_case "$dir")
  printf '%s' "$json" | jq -e '
    .records[0] | .target=="remote-session:fm-task"
      and .endpoint.presence=="unverified" and .endpoint.raw=="remote_unreadable"
      and .worker.presence=="unverified" and .activity=="unverified"
  ' >/dev/null || fail "unreachable remote evidence was collapsed to local absence: $json"
  pass "remote routes use their recorded remote target or remain unverified"
}

test_remote_control_samples_recorded_host_local_target() {
  local dir home json
  dir=$(make_case remote-control claude)
  install_evidence "$dir"
  home="$dir/remote-home"
  mkdir -p "$home/state/parent-route" "$home/bin"
  printf 'task\n' > "$home/.fm-secondmate-home"
  printf '# fixture\n' > "$home/AGENTS.md"
  fm_write_meta "$home/state/parent-route/task.meta" \
    "window=remote-session:fm-task" "worktree=$dir/wt" "harness=claude" "kind=secondmate"
  json=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_LIVENESS_INTERVAL_MS=100 \
    FM_LIVENESS_ENDPOINT_BIN="$dir/bin/endpoint" FM_LIVENESS_CAPTURE_BIN="$dir/bin/capture" \
    FM_LIVENESS_PROCESS_SNAPSHOT_BIN="$dir/bin/process" E_DIR="$dir" E_WT="$dir/wt" \
    E_FAMILY=claude E_PROCESS=working E_CPU2=1002 \
    "$ROOT/bin/fm-remote-secondmate-control.sh" liveness task 100)
  printf '%s' "$json" | jq -e '
    .records[0] | .id=="task" and .backend=="tmux" and .target=="remote-session:fm-task"
      and .worktree != null and .endpoint.presence=="verified_present"
      and .worker.presence=="verified_present" and .activity=="active"
  ' >/dev/null || fail "remote control did not sample its recorded host-local target: $json"
  pass "remote control samples the recorded backend target in its host-local process table"
}

# Neutralization matrix: each active proof is rerun with one guard's evidence
# removed or falsified.
# The inner assertion MUST fail, which is the required RED proof.
neutralized_active_assertion_fails() {  # <label> <dir> <env command args...>
  local label=$1 dir=$2 json
  shift 2
  json=$(export "${@?}"; run_case "$dir")
  if (printf '%s' "$json" | jq -e '.records[0].activity=="active"' >/dev/null); then
    fail "neutralized $label guard left the active assertion green: $json"
  fi
}

test_neutralization_matrix_goes_red() {
  local dir
  dir=$(make_case neutralize-endpoint claude); install_evidence "$dir"
  neutralized_active_assertion_fails endpoint "$dir" E_ENDPOINT=missing E_FAMILY=claude E_PROCESS=working

  dir=$(make_case neutralize-cwd claude); install_evidence "$dir"
  neutralized_active_assertion_fails cwd "$dir" E_ENDPOINT=alive E_FAMILY=claude E_PROCESS=wrong-cwd

  dir=$(make_case neutralize-max codex); install_evidence "$dir"
  neutralized_active_assertion_fails max-cpu "$dir" E_ENDPOINT=alive E_FAMILY=codex E_PROCESS=working E_CPU2=1000

  dir=$(make_case neutralize-delta claude); install_evidence "$dir"
  neutralized_active_assertion_fails cpu-delta "$dir" E_ENDPOINT=alive E_FAMILY=claude E_PROCESS=parked-high-total

  dir=$(make_case neutralize-output claude); install_evidence "$dir"
  neutralized_active_assertion_fails output-delta "$dir" E_ENDPOINT=alive E_FAMILY=claude E_PROCESS=working E_CPU2=1000 E_OUTPUT=static
  pass "neutralizing endpoint, CWD, max-CPU, CPU-delta, or output-delta evidence makes the active assertion RED"
}

test_harness_relative_cpu_rows
test_max_cpu_launcher_and_two_sample_delta
test_real_process_snapshot_accepts_partial_lsof_output
test_cwd_binding_and_shell_amplifier_refusals
test_endpoint_three_way_and_output_activity
test_remote_routes_use_remote_endpoint_evidence
test_remote_control_samples_recorded_host_local_target
test_neutralization_matrix_goes_red

echo "all fm-liveness-snapshot tests passed"
