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
[ -z "${E_ENDPOINT_SLEEP:-}" ] || sleep "$E_ENDPOINT_SLEEP"
printf '%s\n' "${E_ENDPOINT:-alive}"
SH
  cat > "$dir/bin/capture" <<'SH'
#!/usr/bin/env bash
count_file=${E_DIR:?}/capture.count
[ -z "${E_CAPTURE_SLEEP:-}" ] || sleep "$E_CAPTURE_SLEEP"
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
  stall) sleep 30 ;;
  working)
    if [ "$n" -eq 1 ]; then cpu=1000; else cpu=${E_CPU2:-1030}; fi
    printf '11\t%s\t%s\t%s\n' "$cpu" "$worker" "$wt"
    ;;
  launcher-trap)
    if [ "$n" -eq 1 ]; then real=5000; else real=5020; fi
    printf '10\t40\tnode\t%s\n' "$wt"
    printf '11\t%s\t%s\t%s\n' "$real" "$worker" "$wt"
    ;;
  same-family-max)
    if [ "$n" -eq 1 ]; then high=5000; else high=5020; fi
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
  exit-between-samples)
    if [ "$n" -eq 1 ]; then
      printf '11\t500000\t%s\t%s\n' "$worker" "$wt"
    fi
    ;;
  enter-between-samples)
    if [ "$n" -eq 2 ]; then
      printf '11\t500000\t%s\t%s\n' "$worker" "$wt"
    fi
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
printf 'remote\t%s\t%s\t%s\n' "$1" "$2" "$3" >> "${E_DIR:?}/remote.log"
[ "${E_REMOTE:-ok}" = fail ] && exit 1
[ "${E_REMOTE:-ok}" = stall ] && {
  trap '' TERM
  (trap '' TERM; sleep 30) &
  child_pid=$!
  printf '%s\t%s\n' "$$" "$child_pid" > "$E_DIR/remote.pid"
  wait "$child_pid"
  exit 1
}
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
  json=$(E_FAMILY=claude E_PROCESS=working E_CPU2=1020 run_case "$dir")
  printf '%s' "$json" | jq -e '.records[0] | .activity=="active" and .cpu.threshold_ms_per_minute==760 and .cpu.delta_ms==20' >/dev/null \
    || fail "Claude row did not fire above its elapsed-time working floor: $json"

  dir=$(make_case claude-refusal claude); install_evidence "$dir"
  json=$(E_FAMILY=claude E_PROCESS=working E_CPU2=1001 run_case "$dir")
  assert_activity "$json" parked "Claude row did not refuse its legitimate idle-baseline input"

  dir=$(make_case codex-active codex); install_evidence "$dir"
  json=$(E_FAMILY=codex E_PROCESS=working E_CPU2=1010 run_case "$dir")
  printf '%s' "$json" | jq -e '.records[0] | .activity=="active" and .cpu.threshold_ms_per_minute==400 and .cpu.delta_ms==10' >/dev/null \
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
  printf '%s' "$json" | jq -e '.records[0] | .activity=="active" and .cpu.sample_1_max_ms==5000 and .cpu.sample_2_max_ms==5020' >/dev/null \
    || fail "max-CPU guard trusted the thin launcher instead of the real child: $json"

  dir=$(make_case same-family-max claude); install_evidence "$dir"
  json=$(E_FAMILY=claude E_PROCESS=same-family-max run_case "$dir")
  printf '%s' "$json" | jq -e '.records[0] | .activity=="active" and .cpu.sample_1_max_ms==5000 and .cpu.sample_2_max_ms==5020' >/dev/null \
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

test_between_sample_exit_is_absent_for_every_harness() {
  local family dir json
  for family in claude codex opencode pi-signed pi grok kimi; do
    dir=$(make_case "between-sample-$family" "$family"); install_evidence "$dir"
    json=$(E_FAMILY="$family" E_PROCESS=exit-between-samples run_case "$dir")
    printf '%s' "$json" | jq -e '
      .records[0]
      | .worker.presence=="verified_absent"
        and .worker.harness_processes_sample_1==1
        and .worker.harness_processes_sample_2==0
        and .activity=="inactive"
    ' >/dev/null || fail "$family retained a worker that exited between samples: $json"

    dir=$(make_case "one-sample-cpu-$family" "$family"); install_evidence "$dir"
    json=$(E_FAMILY="$family" E_PROCESS=enter-between-samples run_case "$dir")
    printf '%s' "$json" | jq -e '
      .records[0]
      | .worker.presence=="verified_present"
        and .worker.harness_processes_sample_1==0
        and .worker.harness_processes_sample_2==1
        and .activity!="active"
    ' >/dev/null || fail "$family credited processor activity without two-sample worker evidence: $json"

    dir=$(make_case "two-sample-$family" "$family"); install_evidence "$dir"
    json=$(E_FAMILY="$family" E_PROCESS=parked-high-total run_case "$dir")
    printf '%s' "$json" | jq -e '
      .records[0]
      | .worker.presence=="verified_present"
        and .worker.harness_processes_sample_1==1
        and .worker.harness_processes_sample_2==1
        and .activity!="inactive"
    ' >/dev/null || fail "$family refused a worker present in both samples: $json"
  done
  pass "sample 2 owns current worker presence for every harness and two samples preserve legitimate workers"
}

test_endpoint_three_way_and_output_activity() {
  local dir json
  dir=$(make_case endpoint-present claude); install_evidence "$dir"
  json=$(E_ENDPOINT=alive E_FAMILY=claude E_PROCESS=working E_CPU2=1000 E_OUTPUT=changing run_case "$dir")
  printf '%s' "$json" | jq -e '.records[0] | .endpoint.presence=="verified_present" and .output.changed==true and .activity=="active"' >/dev/null \
    || fail "changed output did not establish activity independently of CPU: $json"

  dir=$(make_case endpoint-absent claude); install_evidence "$dir"
  json=$(E_ENDPOINT=missing E_FAMILY=claude E_PROCESS=working run_case "$dir")
  printf '%s' "$json" | jq -e '
    .records[0] | .endpoint.presence=="verified_absent"
      and .worker.presence=="verified_present" and .activity=="active"
  ' >/dev/null || fail "missing endpoint erased independently active process evidence: $json"

  dir=$(make_case endpoint-unverified claude); install_evidence "$dir"
  json=$(E_ENDPOINT=unreadable E_FAMILY=claude E_PROCESS=working run_case "$dir")
  printf '%s' "$json" | jq -e '
    .records[0] | .endpoint.presence=="unverified"
      and .worker.presence=="verified_present" and .activity=="active"
  ' >/dev/null || fail "unreadable endpoint erased independently active process evidence: $json"
  pass "endpoint presence remains three-way while independent process or output evidence establishes work"
}

test_local_evidence_producers_are_bounded() {
  local dir json started elapsed
  dir=$(make_case local-process-stall claude); install_evidence "$dir"
  started=$(date +%s)
  json=$(FM_LIVENESS_EVIDENCE_TIMEOUT=1 E_PROCESS=stall run_case "$dir")
  elapsed=$(( $(date +%s) - started ))
  [ "$elapsed" -lt 6 ] || fail "stalled process producer exceeded the shared bound (${elapsed}s)"
  printf '%s' "$json" | jq -e '
    .process_samples.sample_1_readable == false and .process_samples.sample_2_readable == false
      and .records[0].worker.presence == "unverified" and .records[0].activity == "unverified"
  ' >/dev/null || fail "stalled process evidence did not degrade to unverified: $json"

  dir=$(make_case local-endpoint-stall claude); install_evidence "$dir"
  started=$(date +%s)
  json=$(FM_LIVENESS_EVIDENCE_TIMEOUT=1 E_ENDPOINT_SLEEP=30 run_case "$dir")
  elapsed=$(( $(date +%s) - started ))
  [ "$elapsed" -lt 5 ] || fail "stalled endpoint producer exceeded the shared bound (${elapsed}s)"
  printf '%s' "$json" | jq -e '
    .records[0] | .endpoint.presence=="unverified"
      and .worker.presence=="verified_present" and .activity=="active"
  ' >/dev/null || fail "stalled endpoint evidence erased independently active process evidence: $json"

  dir=$(make_case local-capture-stall claude); install_evidence "$dir"
  started=$(date +%s)
  json=$(FM_LIVENESS_EVIDENCE_TIMEOUT=1 E_CAPTURE_SLEEP=30 E_CPU2=1000 run_case "$dir")
  elapsed=$(( $(date +%s) - started ))
  [ "$elapsed" -lt 6 ] || fail "stalled capture producer exceeded the shared bound (${elapsed}s)"
  printf '%s' "$json" | jq -e '
    .records[0] | .endpoint.presence=="verified_present"
      and .output.sample_1_readable==false and .output.sample_2_readable==false
      and .activity=="unverified"
  ' >/dev/null || fail "stalled output evidence did not degrade to unreadable: $json"

  dir=$(make_case local-lsof-stall claude); install_evidence "$dir"
  cat > "$dir/bin/lsof" <<'SH'
#!/usr/bin/env bash
sleep 30
SH
  chmod +x "$dir/bin/lsof"
  started=$(date +%s)
  json=$(PATH="$dir/bin:$PATH" FM_HOME="$dir/home" FM_LIVENESS_INTERVAL_MS=100 \
    FM_LIVENESS_NOW=2026-08-03T12:00:00Z FM_LIVENESS_EVIDENCE_TIMEOUT=1 \
    FM_LIVENESS_ENDPOINT_BIN="$dir/bin/endpoint" FM_LIVENESS_CAPTURE_BIN="$dir/bin/capture" \
    E_DIR="$dir" E_WT="$dir/wt" "$LIVENESS" --json)
  elapsed=$(( $(date +%s) - started ))
  [ "$elapsed" -lt 6 ] || fail "stalled production lsof exceeded the shared bound (${elapsed}s)"
  printf '%s' "$json" | jq -e '
    .process_samples.sample_1_readable == false and .process_samples.sample_2_readable == false
      and .records[0].worker.presence == "unverified"
  ' >/dev/null || fail "stalled production lsof did not become unreadable: $json"
  pass "all local process, endpoint, and output evidence producers share one bound"
}

test_cpu_rate_uses_actual_sample_elapsed_time() {
  local dir json
  dir=$(make_case elapsed-rate claude); install_evidence "$dir"
  json=$(FM_LIVENESS_EVIDENCE_TIMEOUT=2 E_ENDPOINT_SLEEP=1 E_FAMILY=claude E_PROCESS=working E_CPU2=1010 run_case "$dir")
  printf '%s' "$json" | jq -e '
    .sample_elapsed_ms >= 900 and .records[0].cpu.delta_ms == 10
      and .records[0].cpu.rate_ms_per_minute < 760 and .records[0].activity == "parked"
  ' >/dev/null || fail "configured sleep inflated CPU rate instead of using elapsed sample time: $json"
  pass "CPU rate uses monotonic elapsed time between cumulative samples"
}

test_production_cpu_clock_excludes_trailing_lsof_latency() {
  local dir json neutralized_json real_ps
  dir=$(make_case cpu-clock-boundary claude); install_evidence "$dir"
  real_ps=$(command -v ps)
  cat > "$dir/bin/ps" <<'SH'
#!/usr/bin/env bash
if [ "$*" != "-Ao pid=,time=,comm=" ]; then exec "${E_REAL_PS:?}" "$@"; fi
count_file=${E_DIR:?}/ps.count
n=$(cat "$count_file" 2>/dev/null || printf 0)
n=$((n + 1))
printf '%s' "$n" > "$count_file"
if [ "$n" -eq 1 ]; then cpu=00:00:01.00; else cpu=00:00:01.04; fi
printf '11 %s claude\n' "$cpu"
SH
  cat > "$dir/bin/lsof" <<'SH'
#!/usr/bin/env bash
count_file=${E_DIR:?}/lsof.count
n=$(cat "$count_file" 2>/dev/null || printf 0)
n=$((n + 1))
printf '%s' "$n" > "$count_file"
[ "$(cat "${E_DIR:?}/ps.count")" -ne 2 ] || sleep 4
printf 'p11\nn%s\n' "${E_WT:?}"
SH
  cat > "$dir/bin/late-clock-process" <<SH
#!/usr/bin/env bash
unset FM_LIVENESS_PROCESS_TIMESTAMP_FILE
exec "$ROOT/bin/fm-liveness-process-snapshot.sh"
SH
  chmod +x "$dir/bin/ps" "$dir/bin/lsof" "$dir/bin/late-clock-process"
  rm -f "$dir"/*.count
  json=$(PATH="$dir/bin:$PATH" FM_HOME="$dir/home" FM_LIVENESS_INTERVAL_MS=100 \
    FM_LIVENESS_NOW=2026-08-03T12:00:00Z FM_LIVENESS_EVIDENCE_TIMEOUT=6 FM_LIVENESS_ENDPOINT_BIN="$dir/bin/endpoint" \
    FM_LIVENESS_CAPTURE_BIN="$dir/bin/capture" FM_LIVENESS_PROCESS_SNAPSHOT_BIN='' \
    E_ENDPOINT_SLEEP='' E_CAPTURE_SLEEP='' E_CPU2='' \
    E_REAL_PS="$real_ps" E_DIR="$dir" E_WT="$dir/wt" "$LIVENESS" --json)
  printf '%s' "$json" | jq -e '
    .records[0].cpu.delta_ms == 40 and .records[0].activity == "active"
  ' >/dev/null || fail "trailing lsof latency distorted the CPU-read interval: $json"

  rm -f "$dir"/*.count
  neutralized_json=$(PATH="$dir/bin:$PATH" FM_HOME="$dir/home" FM_LIVENESS_INTERVAL_MS=100 \
    FM_LIVENESS_NOW=2026-08-03T12:00:00Z FM_LIVENESS_EVIDENCE_TIMEOUT=6 FM_LIVENESS_ENDPOINT_BIN="$dir/bin/endpoint" \
    FM_LIVENESS_CAPTURE_BIN="$dir/bin/capture" FM_LIVENESS_PROCESS_SNAPSHOT_BIN="$dir/bin/late-clock-process" \
    E_ENDPOINT_SLEEP='' E_CAPTURE_SLEEP='' E_REAL_PS="$real_ps" E_DIR="$dir" E_WT="$dir/wt" "$LIVENESS" --json)
  printf '%s' "$neutralized_json" | jq -e '.records[0].activity == "active"' >/dev/null \
    && fail "neutralizing the CPU-boundary timestamp left the activity assertion green: $neutralized_json"
  pass "production CPU timestamps are taken before trailing lsof work"
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
  grep -F $'remote\ttask\t100\t2' "$dir/remote.log" >/dev/null \
    || fail "validated evidence timeout was not carried to the remote producer"

  : > "$dir/remote.log"
  json=$(FM_LIVENESS_REMOTE_BIN="$dir/bin/remote" E_REMOTE=fail run_case "$dir")
  printf '%s' "$json" | jq -e '
    .records[0] | .target=="remote-session:fm-task"
      and .endpoint.presence=="unverified" and .endpoint.raw=="remote_unreadable"
      and .worker.presence=="unverified" and .activity=="unverified"
  ' >/dev/null || fail "unreachable remote evidence was collapsed to local absence: $json"
  pass "remote routes use their recorded remote target or remain unverified"
}

test_stalled_remote_route_is_bounded_and_reaped() {
  local dir json started elapsed remote_pid child_pid neutralized_bin neutralized_rc
  dir=$(make_case remote-stall claude)
  install_evidence "$dir"
  install_remote_evidence "$dir"
  cat >> "$dir/home/state/task.meta" <<EOF
remote_host=fixture-host
remote_root=/remote/firstmate
remote_backend=tmux
remote_target=remote-session:fm-task
worktree=remote-worktree
EOF
  started=$(date +%s)
  json=$(FM_LIVENESS_REMOTE_BIN="$dir/bin/remote" FM_LIVENESS_EVIDENCE_TIMEOUT=1 \
    FM_LIVENESS_REMOTE_OVERHEAD_SECS=1 E_REMOTE=stall run_case "$dir")
  elapsed=$(( $(date +%s) - started ))
  [ "$elapsed" -lt 12 ] || fail "stalled remote liveness exceeded its derived acquisition bound (${elapsed}s)"
  printf '%s' "$json" | jq -e '
    .records[0] | .endpoint.presence=="unverified" and .endpoint.raw=="remote_unreadable"
      and .worker.presence=="unverified" and .activity=="unverified"
  ' >/dev/null || fail "stalled remote route did not degrade to explicit unverified evidence: $json"
  while IFS=$(printf '\t') read -r remote_pid child_pid; do
    if kill -0 "$remote_pid" 2>/dev/null || kill -0 "$child_pid" 2>/dev/null; then
      fail "stalled remote evidence process survived timeout cancellation: $remote_pid $child_pid"
    fi
  done < "$dir/remote.pid"

  neutralized_bin="$dir/neutralized-bin"
  mkdir -p "$neutralized_bin"
  cat > "$neutralized_bin/timeout" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = -k ] && shift 2
shift
exec "$@"
SH
  chmod +x "$neutralized_bin/timeout"
  rm -f "$dir/remote.pid"
  perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; waitpid $pid, 0; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' \
    9 env PATH="$neutralized_bin:$PATH" FM_HOME="$dir/home" FM_LIVENESS_INTERVAL_MS=100 FM_LIVENESS_NOW=2026-08-03T12:00:00Z \
    FM_LIVENESS_ENDPOINT_BIN="$dir/bin/endpoint" FM_LIVENESS_CAPTURE_BIN="$dir/bin/capture" \
    FM_LIVENESS_PROCESS_SNAPSHOT_BIN="$dir/bin/process" FM_LIVENESS_REMOTE_BIN="$dir/bin/remote" \
    FM_LIVENESS_EVIDENCE_TIMEOUT=1 FM_LIVENESS_REMOTE_OVERHEAD_SECS=1 E_REMOTE=stall \
    E_DIR="$dir" E_WT="$dir/wt" "$LIVENESS" --json >/dev/null 2>&1
  neutralized_rc=$?
  [ "$neutralized_rc" -eq 124 ] \
    || fail "neutralizing remote acquisition cancellation did not make the bounded assertion RED: rc=$neutralized_rc"
  pass "stalled remote evidence is bounded, reaped, and reported unverified"
}

test_external_cancellation_reaps_perl_remote_group() {
  local dir perl_path snapshot_pid snapshot_rc remote_pid child_pid i real_perl neutralized_path tool tool_path
  local neutralized_pid neutralized_rc survivor=false
  dir=$(make_case remote-cancel claude)
  install_evidence "$dir"
  install_remote_evidence "$dir"
  cat >> "$dir/home/state/task.meta" <<EOF
remote_host=fixture-host
remote_root=/remote/firstmate
remote_backend=tmux
remote_target=remote-session:fm-task
worktree=remote-worktree
EOF
  perl_path="$dir/perl-path"
  mkdir -p "$perl_path"
  for tool in bash basename cat cksum cp cut date dirname grep head jq mktemp mv perl rm sed shasum sha256sum sleep sort tail tr uname wc awk; do
    tool_path=$(command -v "$tool" 2>/dev/null || true)
    [ -n "$tool_path" ] || continue
    ln -s "$tool_path" "$perl_path/$tool"
  done
  PATH="$perl_path" FM_HOME="$dir/home" \
    FM_LIVENESS_INTERVAL_MS=100 FM_LIVENESS_NOW=2026-08-03T12:00:00Z \
    FM_LIVENESS_ENDPOINT_BIN="$dir/bin/endpoint" FM_LIVENESS_CAPTURE_BIN="$dir/bin/capture" \
    FM_LIVENESS_PROCESS_SNAPSHOT_BIN="$dir/bin/process" FM_LIVENESS_REMOTE_BIN="$dir/bin/remote" \
    FM_LIVENESS_EVIDENCE_TIMEOUT=1 FM_LIVENESS_REMOTE_OVERHEAD_SECS=1 E_REMOTE=stall \
    E_DIR="$dir" E_WT="$dir/wt" "$LIVENESS" --json > "$dir/cancel.json" 2>/dev/null &
  snapshot_pid=$!
  i=0
  while [ ! -s "$dir/remote.pid" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
  [ -s "$dir/remote.pid" ] || { kill "$snapshot_pid" 2>/dev/null || true; fail "Perl cancellation fixture did not start remote evidence"; }
  kill -TERM "$snapshot_pid"
  wait "$snapshot_pid"
  snapshot_rc=$?
  [ "$snapshot_rc" -eq 143 ] || fail "Perl cancellation did not preserve TERM status: $snapshot_rc"
  while IFS=$(printf '\t') read -r remote_pid child_pid; do
    i=0
    while { kill -0 "$remote_pid" 2>/dev/null || kill -0 "$child_pid" 2>/dev/null; } && [ "$i" -lt 40 ]; do
      sleep 0.05
      i=$((i + 1))
    done
    if kill -0 "$remote_pid" 2>/dev/null || kill -0 "$child_pid" 2>/dev/null; then
      fail "Perl cancellation left a remote descendant alive: $remote_pid $child_pid"
    fi
  done < "$dir/remote.pid"

  real_perl=$(command -v perl)
  neutralized_path="$dir/neutralized-perl"
  mkdir -p "$neutralized_path"
  cat > "$neutralized_path/perl" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in -MIO::Select) ;; *) exec "${REAL_PERL:?}" "$@" ;; esac
shift 5
mode=$1
seconds=$2
shift 2
[ "$mode" = --total ] || exit 124
exec "${REAL_PERL:?}" -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } alarm $t; waitpid $pid, 0; exit($? >> 8)' "$seconds" "$@"
SH
  chmod +x "$neutralized_path/perl"
  rm -f "$dir/remote.pid"
  PATH="$neutralized_path:$perl_path" REAL_PERL="$real_perl" \
    FM_HOME="$dir/home" FM_LIVENESS_INTERVAL_MS=100 FM_LIVENESS_NOW=2026-08-03T12:00:00Z \
    FM_LIVENESS_ENDPOINT_BIN="$dir/bin/endpoint" FM_LIVENESS_CAPTURE_BIN="$dir/bin/capture" \
    FM_LIVENESS_PROCESS_SNAPSHOT_BIN="$dir/bin/process" FM_LIVENESS_REMOTE_BIN="$dir/bin/remote" \
    FM_LIVENESS_EVIDENCE_TIMEOUT=1 FM_LIVENESS_REMOTE_OVERHEAD_SECS=1 E_REMOTE=stall \
    E_DIR="$dir" E_WT="$dir/wt" "$LIVENESS" --json > "$dir/neutralized.json" 2>/dev/null &
  neutralized_pid=$!
  i=0
  while [ ! -s "$dir/remote.pid" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
  [ -s "$dir/remote.pid" ] || { kill "$neutralized_pid" 2>/dev/null || true; fail "neutralized Perl fixture did not start remote evidence"; }
  kill -TERM "$neutralized_pid"
  wait "$neutralized_pid"
  neutralized_rc=$?
  [ "$neutralized_rc" -eq 143 ] || fail "neutralized Perl fixture did not receive TERM: $neutralized_rc"
  while IFS=$(printf '\t') read -r remote_pid child_pid; do
    if kill -0 "$remote_pid" 2>/dev/null || kill -0 "$child_pid" 2>/dev/null; then survivor=true; fi
    kill -KILL "$remote_pid" "$child_pid" 2>/dev/null || true
  done < "$dir/remote.pid"
  [ "$survivor" = true ] || fail "neutralizing the Perl signal handler left the descendant-reap assertion green"
  pass "external cancellation reaps the real Perl fallback process group"
}

test_signal_before_remote_pid_registration_reaps_job() {
  local dir hook rc remote_pid child_pid i
  dir=$(make_case registration-race claude)
  install_evidence "$dir"
  install_remote_evidence "$dir"
  cat >> "$dir/home/state/task.meta" <<EOF
remote_host=fixture-host
remote_root=/remote/firstmate
remote_backend=tmux
remote_target=remote-session:fm-task
worktree=remote-worktree
EOF
  hook="$dir/bin/before-register"
  cat > "$hook" <<'SH'
#!/usr/bin/env bash
i=0
while [ ! -s "${E_DIR:?}/remote.pid" ] && [ "$i" -lt 100 ]; do sleep 0.02; i=$((i + 1)); done
kill -TERM "$PPID"
SH
  chmod +x "$hook"
  PATH="$PATH" FM_HOME="$dir/home" FM_LIVENESS_INTERVAL_MS=100 FM_LIVENESS_NOW=2026-08-03T12:00:00Z \
    FM_LIVENESS_ENDPOINT_BIN="$dir/bin/endpoint" FM_LIVENESS_CAPTURE_BIN="$dir/bin/capture" \
    FM_LIVENESS_PROCESS_SNAPSHOT_BIN="$dir/bin/process" FM_LIVENESS_REMOTE_BIN="$dir/bin/remote" \
    FM_LIVENESS_BEFORE_REGISTER_BIN="$hook" FM_LIVENESS_EVIDENCE_TIMEOUT=1 \
    FM_LIVENESS_REMOTE_OVERHEAD_SECS=1 E_REMOTE=stall E_DIR="$dir" E_WT="$dir/wt" \
    "$LIVENESS" --json >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 143 ] || fail "pre-registration cancellation did not preserve TERM status: $rc"
  [ -s "$dir/remote.pid" ] || fail "pre-registration fixture never launched remote evidence"
  while IFS=$(printf '\t') read -r remote_pid child_pid; do
    i=0
    while { kill -0 "$remote_pid" 2>/dev/null || kill -0 "$child_pid" 2>/dev/null; } && [ "$i" -lt 40 ]; do
      sleep 0.05
      i=$((i + 1))
    done
    if kill -0 "$remote_pid" 2>/dev/null || kill -0 "$child_pid" 2>/dev/null; then
      fail "pre-registration cancellation leaked remote evidence: $remote_pid $child_pid"
    fi
  done < "$dir/remote.pid"
  pass "signal-before-registration cancellation still owns and reaps the remote job"
}

test_remote_control_samples_recorded_host_local_target() {
  local dir home json started elapsed
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
    E_FAMILY=claude E_PROCESS=working E_CPU2=1020 \
    "$ROOT/bin/fm-remote-secondmate-control.sh" liveness task 100 2)
  printf '%s' "$json" | jq -e '
    .records[0] | .id=="task" and .backend=="tmux" and .target=="remote-session:fm-task"
      and .worktree != null and .endpoint.presence=="verified_present"
      and .worker.presence=="verified_present" and .activity=="active"
  ' >/dev/null || fail "remote control did not sample its recorded host-local target: $json"

  started=$(date +%s)
  json=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_LIVENESS_INTERVAL_MS=100 \
    FM_LIVENESS_EVIDENCE_TIMEOUT=9 FM_LIVENESS_ENDPOINT_BIN="$dir/bin/endpoint" \
    FM_LIVENESS_CAPTURE_BIN="$dir/bin/capture" FM_LIVENESS_PROCESS_SNAPSHOT_BIN="$dir/bin/process" \
    E_ENDPOINT_SLEEP=30 E_DIR="$dir" E_WT="$dir/wt" \
    "$ROOT/bin/fm-remote-secondmate-control.sh" liveness task 100 1)
  elapsed=$(( $(date +%s) - started ))
  [ "$elapsed" -lt 6 ] || fail "remote control ignored the handed-off evidence timeout (${elapsed}s)"
  printf '%s' "$json" | jq -e '.records[0].endpoint.presence == "unverified"' >/dev/null \
    || fail "remote control timeout did not become unverified evidence: $json"
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
  dir=$(make_case neutralize-cwd claude); install_evidence "$dir"
  neutralized_active_assertion_fails cwd "$dir" E_ENDPOINT=alive E_FAMILY=claude E_PROCESS=wrong-cwd

  dir=$(make_case neutralize-max codex); install_evidence "$dir"
  neutralized_active_assertion_fails max-cpu "$dir" E_ENDPOINT=alive E_FAMILY=codex E_PROCESS=working E_CPU2=1000

  dir=$(make_case neutralize-delta claude); install_evidence "$dir"
  neutralized_active_assertion_fails cpu-delta "$dir" E_ENDPOINT=alive E_FAMILY=claude E_PROCESS=parked-high-total

  dir=$(make_case neutralize-output claude); install_evidence "$dir"
  neutralized_active_assertion_fails output-delta "$dir" E_ENDPOINT=alive E_FAMILY=claude E_PROCESS=working E_CPU2=1000 E_OUTPUT=static
  pass "neutralizing CWD, max-CPU, CPU-delta, or output-delta evidence makes the active assertion RED"
}

test_harness_relative_cpu_rows
test_max_cpu_launcher_and_two_sample_delta
test_real_process_snapshot_accepts_partial_lsof_output
test_cwd_binding_and_shell_amplifier_refusals
test_between_sample_exit_is_absent_for_every_harness
test_endpoint_three_way_and_output_activity
test_local_evidence_producers_are_bounded
test_cpu_rate_uses_actual_sample_elapsed_time
test_production_cpu_clock_excludes_trailing_lsof_latency
test_remote_routes_use_remote_endpoint_evidence
test_stalled_remote_route_is_bounded_and_reaped
test_external_cancellation_reaps_perl_remote_group
test_signal_before_remote_pid_registration_reaps_job
test_remote_control_samples_recorded_host_local_target
test_neutralization_matrix_goes_red

echo "all fm-liveness-snapshot tests passed"
