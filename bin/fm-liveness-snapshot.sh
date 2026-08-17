#!/usr/bin/env bash
# fm-liveness-snapshot.sh - measured worker liveness for the current home.
#
# This is the single owner of the fleet liveness observation contract used by
# session start, the canonical fleet snapshot, and Bearings.
# It never reads state/<id>.status because that file is wake-event history, not
# current-state evidence.
#
# Trust anchors:
#   - Endpoint presence comes from fm_backend_agent_state, whose backend adapter
#     verifies the recorded endpoint rather than accepting a pane label as a
#     process claim.
#   - Worker ownership comes from a random per-spawn token recorded in task
#     metadata and inherited by that task's process tree. `lsof -a -d cwd`
#     remains a second constraint, never task identity: pooled worktrees are
#     intentionally reused and cannot distinguish their former owners.
#   - Activity comes from two independent observations: a hash of backend output
#     at each sample and the delta of cumulative process CPU time.
#
# CPU is never read as instantaneous %CPU.
# Each sample takes the MAX cumulative CPU across EVERY matching harness process
# carrying the task token whose cwd is the exact task worktree.
# This avoids both launcher traps: Codex's near-zero node launcher is not chosen
# ahead of its native codex child, and Claude's first short-lived wrapper is not
# chosen ahead of the real long-running agent.
# A harness process must also exist in that worktree before CPU can establish
# activity, so leftover background shells cannot impersonate a live worker.
# Sample 2 owns current worker presence, and cumulative CPU can establish
# activity only when the worker exists in both samples.
#
# Harness-relative CPU thresholds are rates in milliseconds per minute.
# The 7.5-second default interval gives a 10 ms process-time clock at least ten
# ticks at the measured 800 ms/min working floor, instead of deciding near the
# boundary from one or two scheduler ticks.
# They preserve the measured separation in the 2026-08-03 observation:
#   claude idle <=190 ms/min, working >=800 ms/min -> threshold 760 ms/min
#     (four times the observed idle ceiling);
#   codex idle approximately 0 ms/min, working >=800 ms/min -> threshold
#     400 ms/min (midway across that harness's measured gap).
# Other harnesses can still establish activity from changed output, but their
# static-output CPU verdict is `unverified` until a measured baseline is added.
#
# Output (`--json` only):
#   {schema,observed_at,interval_ms,process_samples,records[]}
# Each record has explicit endpoint and worker presence values:
#   verified_present | verified_absent | unverified
# and activity:
#   active | parked | inactive | absent | unverified
#
# Test seams name external evidence producers, not classifier decisions:
#   FM_LIVENESS_PROCESS_SNAPSHOT_BIN prints an exact process-table witness
#     __FM_LIVENESS_OBSERVER__<TAB>process-table-visible
#   followed by pid<TAB>cpu_ms<TAB>comm<TAB>cwd<TAB>worker_token rows, and
#     may write its CPU-read clock to FM_LIVENESS_PROCESS_TIMESTAMP_FILE.
#   FM_LIVENESS_ENDPOINT_BIN prints an fm_backend_agent_state verdict.
#   FM_LIVENESS_CAPTURE_BIN prints the current endpoint output.
# The production path ignores none of its guards; tests replace evidence only.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVIDENCE_RUN="$SCRIPT_DIR/fm-evidence-run.sh"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
INTERVAL_MS=${FM_LIVENESS_INTERVAL_MS:-7500}
case "$INTERVAL_MS" in
  ''|*[!0-9]*|0) echo "fm-liveness-snapshot: FM_LIVENESS_INTERVAL_MS must be a positive integer" >&2; exit 2 ;;
esac
EVIDENCE_TIMEOUT=${FM_LIVENESS_EVIDENCE_TIMEOUT:-5}
REMOTE_OVERHEAD_SECS=${FM_LIVENESS_REMOTE_OVERHEAD_SECS:-2}
case "$EVIDENCE_TIMEOUT" in
  ''|*[!0-9]*|0) echo "fm-liveness-snapshot: FM_LIVENESS_EVIDENCE_TIMEOUT must be a positive integer" >&2; exit 2 ;;
esac
case "$REMOTE_OVERHEAD_SECS" in
  ''|*[!0-9]*|0) echo "fm-liveness-snapshot: FM_LIVENESS_REMOTE_OVERHEAD_SECS must be a positive integer" >&2; exit 2 ;;
esac
INTERVAL_CEIL_SECS=$(( (INTERVAL_MS + 999) / 1000 ))
REMOTE_ACQUISITION_TIMEOUT=$((INTERVAL_CEIL_SECS + 5 * EVIDENCE_TIMEOUT + REMOTE_OVERHEAD_SECS))

usage() {
  cat <<'EOF'
usage: fm-liveness-snapshot.sh --json [--id <task-id>]

Measure endpoint presence, task-bound worker presence, output change, and
two-sample cumulative CPU delta for recorded tasks in the current FM_HOME.
EOF
}

FORMAT=
ONLY_ID=
while [ $# -gt 0 ]; do
  case "$1" in
    --json) FORMAT=json ;;
    --id) shift; ONLY_ID=${1:-} ;;
    --id=*) ONLY_ID=${1#--id=} ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done
[ "$FORMAT" = json ] || { usage >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "fm-liveness-snapshot: jq not found" >&2; exit 1; }

# shellcheck source=bin/fm-backend.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-backend.sh"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-liveness.XXXXXX") || exit 1
OWNED_PIDS="$TMP/owned-pids"
: > "$OWNED_PIDS"
PENDING_EVIDENCE_PID=
cleanup() {
  local job_pid cleanup_pids
  cleanup_pids=${PENDING_EVIDENCE_PID:-}
  cleanup_pids="${cleanup_pids}${cleanup_pids:+
}$(cat "$OWNED_PIDS" 2>/dev/null || true)"
  cleanup_pids="${cleanup_pids}${cleanup_pids:+
}$(jobs -pr 2>/dev/null || true)"
  while IFS= read -r job_pid; do
    [ -n "$job_pid" ] || continue
    kill "$job_pid" 2>/dev/null || true
    wait "$job_pid" 2>/dev/null || true
  done <<EOF
$cleanup_pids
EOF
  rm -rf -- "$TMP"
}
cleanup_signal() { local rc=$1; trap - EXIT HUP INT TERM; cleanup; exit "$rc"; }
trap cleanup EXIT
trap 'cleanup_signal 129' HUP
trap 'cleanup_signal 130' INT
trap 'cleanup_signal 143' TERM

forget_owned_pid() {  # <pid>
  grep -Fvx "$1" "$OWNED_PIDS" > "$OWNED_PIDS.next" 2>/dev/null || true
  mv "$OWNED_PIDS.next" "$OWNED_PIDS"
}

meta_value() {  # <meta> <key>
  fm_meta_get "$1" "$2"
}

process_snapshot() {  # <output> <timestamp-output>
  local output=$1 timestamp_output=$2
  rm -f -- "$timestamp_output"
  if [ -n "${FM_LIVENESS_PROCESS_SNAPSHOT_BIN:-}" ]; then
    FM_LIVENESS_PROCESS_TIMESTAMP_FILE="$timestamp_output" \
      "$EVIDENCE_RUN" --total "$EVIDENCE_TIMEOUT" "$FM_LIVENESS_PROCESS_SNAPSHOT_BIN" > "$output" 2>/dev/null || return
  else
    FM_LIVENESS_PROCESS_TIMESTAMP_FILE="$timestamp_output" \
      "$EVIDENCE_RUN" --total "$EVIDENCE_TIMEOUT" "$SCRIPT_DIR/fm-liveness-process-snapshot.sh" "$timestamp_output" > "$output" 2>/dev/null || return
  fi
  # A successful producer needs an exact process-table witness. The observer
  # need not see any worker token: no task-bound worker anywhere is a verified
  # empty fleet, whereas a failed or blind producer has no usable table.
  grep -Fqx $'__FM_LIVENESS_OBSERVER__	process-table-visible' "$output" || return 1
  [ -s "$timestamp_output" ] || monotonic_ms > "$timestamp_output"
}

bounded_endpoint_verdict() {  # <output> <backend> <target> <label>
  local output=$1 backend=$2 target=$3 label=$4
  if [ -n "${FM_LIVENESS_ENDPOINT_BIN:-}" ]; then
    "$EVIDENCE_RUN" --total "$EVIDENCE_TIMEOUT" "$FM_LIVENESS_ENDPOINT_BIN" "$backend" "$target" "$label" > "$output" 2>/dev/null
  else
    "$EVIDENCE_RUN" --total "$EVIDENCE_TIMEOUT" bash -c ". \"\$1\"; fm_backend_agent_state \"\$2\" \"\$3\"" \
      fm-endpoint-verdict "$SCRIPT_DIR/fm-backend.sh" "$backend" "$target" > "$output" 2>/dev/null
  fi
}

bounded_capture_output() {  # <output> <backend> <target> <label>
  local output=$1 backend=$2 target=$3 label=$4
  if [ -n "${FM_LIVENESS_CAPTURE_BIN:-}" ]; then
    "$EVIDENCE_RUN" --total "$EVIDENCE_TIMEOUT" "$FM_LIVENESS_CAPTURE_BIN" "$backend" "$target" "$label" > "$output" 2>/dev/null
  else
    "$EVIDENCE_RUN" --total "$EVIDENCE_TIMEOUT" bash -c ". \"\$1\"; fm_backend_capture \"\$2\" \"\$3\" 80 \"\$4\"" \
      fm-output-capture "$SCRIPT_DIR/fm-backend.sh" "$backend" "$target" "$label" > "$output" 2>/dev/null
  fi
}

monotonic_ms() {
  if command -v perl >/dev/null 2>&1; then
    perl -MTime::HiRes=clock_gettime,CLOCK_MONOTONIC -e 'printf "%.0f\n", clock_gettime(CLOCK_MONOTONIC) * 1000'
    return
  fi
  if [ -r /proc/uptime ]; then
    awk '{printf "%.0f\n", $1 * 1000}' /proc/uptime
    return
  fi
  return 1
}

hash_output() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'
  else cksum | awk '{print $1 ":" $2}'
  fi
}

harness_family() {
  case "$1" in
    claude*) printf claude ;;
    codex*) printf codex ;;
    opencode*) printf opencode ;;
    pi-signed*) printf pi-signed ;;
    pi*) printf pi ;;
    grok*) printf grok ;;
    kimi*) printf kimi ;;
    *) printf unknown ;;
  esac
}

threshold_for() {  # <family>
  case "$1" in
    claude) printf 760 ;;
    codex) printf 400 ;;
    *) printf '' ;;
  esac
}

metrics_for() {  # <snapshot> <worktree> <family> <worker-token> -> max_ms<TAB>pid_count<TAB>worker_count
  awk -F '\t' -v wt="$2" -v family="$3" -v token="$4" '
    function worker(comm, family, base) {
      base=comm; sub(/^.*\//,"",base); base=tolower(base)
      if (family=="claude") return base ~ /^claude/
      if (family=="codex") return base ~ /^codex/
      if (family=="opencode") return base ~ /^opencode/
      if (family=="pi-signed") return base=="pi-signed" || base=="pi"
      if (family=="pi") return base=="pi" || base=="pi-launcher"
      if (family=="grok") return base ~ /^grok/
      if (family=="kimi") return base ~ /^kimi/
      return 0
    }
    token != "" && $4==wt && $5==token {
      count++
      if (worker($3,family)) {
        workers++
        cpu=$2+0
        if (!have || cpu>max) { max=cpu; have=1 }
      }
    }
    END { printf "%d\t%d\t%d\n", (have?max:0), count+0, workers+0 }
  ' "$1"
}

unverified_remote_record() {  # <id> <harness> <worktree> <backend> <target>
  local id=$1 harness=$2 worktree=$3 backend=$4 target=$5 family
  family=$(harness_family "$harness")
  [ "$target" = __FM_MISSING_TARGET__ ] && target=
  jq -n -c --arg id "$id" --arg harness "$harness" --arg family "$family" \
    --arg backend "$backend" --arg target "$target" --arg worktree "$worktree" '
    {id:$id,harness:$harness,harness_family:$family,backend:$backend,
     target:(if $target=="" then null else $target end),worktree:(if $worktree=="" then null else $worktree end),
     endpoint:{presence:"unverified",raw:"remote_unreadable"},
     worker:{presence:"unverified",pids_sample_1:0,pids_sample_2:0,
       harness_processes_sample_1:0,harness_processes_sample_2:0},
     evidence:{grade:"unverified"},
     output:{sample_1_readable:false,sample_2_readable:false,changed:false},
     cpu:{sample_1_max_ms:0,sample_2_max_ms:0,delta_ms:0,rate_ms_per_minute:0,
       baseline:"unverified",threshold_ms_per_minute:null},activity:"unverified"}'
}

METAS="$TMP/metas.tsv"
: > "$METAS"
for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] || continue
  id=${meta##*/}
  id=${id%.meta}
  [ -z "$ONLY_ID" ] || [ "$id" = "$ONLY_ID" ] || continue
  worktree=$(meta_value "$meta" worktree)
  harness=$(meta_value "$meta" harness)
  remote_host=$(meta_value "$meta" remote_host)
  if [ -n "$remote_host" ]; then
    backend=$(meta_value "$meta" remote_backend)
    target=$(meta_value "$meta" remote_target)
    [ -n "$backend" ] || backend=unknown
    [ -n "$target" ] || target=__FM_MISSING_TARGET__
    route=remote
  else
    backend=$(fm_backend_of_meta "$meta")
    target=$(fm_backend_target_of_meta "$meta")
    route=local
  fi
  worker_token=$(meta_value "$meta" worker_token)
  case "$worker_token" in *[!0-9a-f]*) worker_token= ;; esac
  [ "${#worker_token}" -eq 32 ] || worker_token=
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$harness" "$worktree" "$backend" "$target" "$route" "$worker_token" >> "$METAS"
done

if [ ! -s "$METAS" ]; then
  NOW=${FM_LIVENESS_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
  jq -n --arg observed "$NOW" --argjson interval "$INTERVAL_MS" \
    '{schema:"fm-liveness.v1",observed_at:$observed,interval_ms:$interval,
      sample_elapsed_ms:0,process_samples:{sample_1_readable:true,sample_2_readable:true},records:[]}'
  exit 0
fi

SAMPLE1="$TMP/process-1.tsv"
SAMPLE2="$TMP/process-2.tsv"
SAMPLE1_TIME="$TMP/process-1.time"
SAMPLE2_TIME="$TMP/process-2.time"
PROCESS1_OK=true
PROCESS2_OK=true
TIMING_OK=true
process_snapshot "$SAMPLE1" "$SAMPLE1_TIME" || { PROCESS1_OK=false; : > "$SAMPLE1"; }
SAMPLE1_AT_MS=$(cat "$SAMPLE1_TIME" 2>/dev/null) || { TIMING_OK=false; SAMPLE1_AT_MS=0; }
case "$SAMPLE1_AT_MS" in ''|*[!0-9]*) TIMING_OK=false; SAMPLE1_AT_MS=0 ;; esac

REMOTE_JOBS="$TMP/remote-jobs.tsv"
REMOTE_RECORDS="$TMP/remote-records.jsonl"
: > "$REMOTE_JOBS"
: > "$REMOTE_RECORDS"
while IFS=$(printf '\t') read -r id harness worktree backend target route worker_token; do
  remote_pid=
  [ "$route" = remote ] || continue
  if [ "$backend" = unknown ] || [ "$target" = __FM_MISSING_TARGET__ ]; then
    unverified_remote_record "$id" "$harness" "$worktree" "$backend" "$target" >> "$REMOTE_RECORDS"
    continue
  fi
  remote_file="$TMP/remote-$id.json"
  if [ -n "${FM_LIVENESS_REMOTE_BIN:-}" ]; then
    "$EVIDENCE_RUN" --total "$REMOTE_ACQUISITION_TIMEOUT" \
      "$FM_LIVENESS_REMOTE_BIN" "$id" "$INTERVAL_MS" "$EVIDENCE_TIMEOUT" > "$remote_file" 2>/dev/null &
  else
    "$EVIDENCE_RUN" --total "$REMOTE_ACQUISITION_TIMEOUT" \
      "$SCRIPT_DIR/fm-on.sh" "$id" fm-remote-secondmate-control.sh liveness "$id" "$INTERVAL_MS" "$EVIDENCE_TIMEOUT" \
      > "$remote_file" 2>/dev/null &
  fi
  PENDING_EVIDENCE_PID=$!
  if [ -n "${FM_LIVENESS_BEFORE_REGISTER_BIN:-}" ]; then
    "$FM_LIVENESS_BEFORE_REGISTER_BIN" "$id" "$PENDING_EVIDENCE_PID"
  fi
  remote_pid=$PENDING_EVIDENCE_PID
  printf '%s\n' "$remote_pid" >> "$OWNED_PIDS"
  PENDING_EVIDENCE_PID=
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$remote_pid" "$remote_file" "$harness" "$worktree" "$backend" "$target" >> "$REMOTE_JOBS"
done < "$METAS"

ENDPOINTS="$TMP/endpoints.tsv"
OUTPUT1="$TMP/output-1.tsv"
: > "$ENDPOINTS"
: > "$OUTPUT1"
while IFS=$(printf '\t') read -r id harness worktree backend target route worker_token; do
  [ -n "$id" ] || continue
  [ "$route" = local ] || continue
  if [ -z "$target" ]; then
    verdict=unreadable
  else
    endpoint_file="$TMP/endpoint-verdict.out"
    if bounded_endpoint_verdict "$endpoint_file" "$backend" "$target" "fm-$id"; then
      verdict=$(cat "$endpoint_file")
    else
      verdict=unreadable
    fi
  fi
  case "$verdict" in alive|dead|missing|unreadable|ambiguous) ;; *) verdict=unreadable ;; esac
  printf '%s\t%s\n' "$id" "$verdict" >> "$ENDPOINTS"
  hash=
  readable=false
  case "$verdict" in
    alive|dead|ambiguous)
      capture_file="$TMP/capture-output.out"
      if bounded_capture_output "$capture_file" "$backend" "$target" "fm-$id"; then
        output=$(cat "$capture_file")
        hash=$(printf '%s' "$output" | hash_output)
        readable=true
      fi
      ;;
  esac
  printf '%s\t%s\t%s\n' "$id" "$readable" "$hash" >> "$OUTPUT1"
done < "$METAS"

sleep_seconds=$(awk -v ms="$INTERVAL_MS" 'BEGIN { printf "%.3f", ms/1000 }')
sleep "$sleep_seconds"
process_snapshot "$SAMPLE2" "$SAMPLE2_TIME" || { PROCESS2_OK=false; : > "$SAMPLE2"; }
SAMPLE2_AT_MS=$(cat "$SAMPLE2_TIME" 2>/dev/null) || { TIMING_OK=false; SAMPLE2_AT_MS=0; }
case "$SAMPLE2_AT_MS" in ''|*[!0-9]*) TIMING_OK=false; SAMPLE2_AT_MS=0 ;; esac
SAMPLE_ELAPSED_MS=$((SAMPLE2_AT_MS - SAMPLE1_AT_MS))
if [ "$TIMING_OK" != true ] || [ "$SAMPLE_ELAPSED_MS" -le 0 ]; then
  TIMING_OK=false
  SAMPLE_ELAPSED_MS=1
fi
if [ "$TIMING_OK" = true ]; then SAMPLE_ELAPSED_JSON=$SAMPLE_ELAPSED_MS; else SAMPLE_ELAPSED_JSON=null; fi

while IFS=$(printf '\t') read -r id remote_pid remote_file harness worktree backend target; do
  [ -n "$id" ] || continue
  remote_ok=false
  remote_wait_ok=false
  if wait "$remote_pid"; then remote_wait_ok=true; fi
  forget_owned_pid "$remote_pid"
  if [ "$remote_wait_ok" = true ] && jq -e \
    --arg id "$id" --arg backend "$backend" --arg target "$target" --arg worktree "$worktree" --argjson interval "$INTERVAL_MS" '
      .schema == "fm-liveness.v1" and .interval_ms == $interval
      and (.records | length) == 1 and .records[0].id == $id
      and .records[0].backend == $backend and .records[0].target == $target
      and .records[0].worktree == $worktree
    ' "$remote_file" >/dev/null 2>&1; then
    jq -c '.records[0]' "$remote_file" >> "$REMOTE_RECORDS"
    remote_ok=true
  fi
  if [ "$remote_ok" != true ]; then
    unverified_remote_record "$id" "$harness" "$worktree" "$backend" "$target" >> "$REMOTE_RECORDS"
  fi
done < "$REMOTE_JOBS"

RECORDS="$TMP/records.jsonl"
cp "$REMOTE_RECORDS" "$RECORDS"
while IFS=$(printf '\t') read -r id harness worktree backend target route worker_token; do
  [ -n "$id" ] || continue
  [ "$route" = local ] || continue
  family=$(harness_family "$harness")
  threshold=$(threshold_for "$family")
  IFS=$(printf '\t') read -r cpu1 pids1 workers1 <<EOF
$(metrics_for "$SAMPLE1" "$worktree" "$family" "$worker_token")
EOF
  IFS=$(printf '\t') read -r cpu2 pids2 workers2 <<EOF
$(metrics_for "$SAMPLE2" "$worktree" "$family" "$worker_token")
EOF
  verdict=$(awk -F '\t' -v id="$id" '$1==id {print $2; exit}' "$ENDPOINTS")
  IFS=$(printf '\t') read -r output1_ok hash1 <<EOF
$(awk -F '\t' -v id="$id" '$1==id {print $2 "\t" $3; exit}' "$OUTPUT1")
EOF
  output2_ok=false
  hash2=
  case "$verdict" in
    alive|dead|ambiguous)
      capture_file="$TMP/capture-output.out"
      if bounded_capture_output "$capture_file" "$backend" "$target" "fm-$id"; then
        output=$(cat "$capture_file")
        hash2=$(printf '%s' "$output" | hash_output)
        output2_ok=true
      fi
      ;;
  esac

  case "$verdict" in
    alive|dead|ambiguous) endpoint=verified_present ;;
    missing) endpoint=verified_absent ;;
    *) endpoint=unverified ;;
  esac
  if [ -n "$worker_token" ] && [ "$PROCESS1_OK" = true ] && [ "$PROCESS2_OK" = true ]; then
    evidence_grade=task_bound_process
    if [ "$workers2" -gt 0 ]; then worker=verified_present
    else worker=verified_absent
    fi
  elif [ -z "$worker_token" ]; then
    evidence_grade=endpoint_only
    case "$verdict" in
      alive) worker=verified_present ;;
      dead|missing) worker=verified_absent ;;
      *) worker=unverified; evidence_grade=unverified ;;
    esac
  else
    worker=unverified
    evidence_grade=unverified
  fi

  cpu_worker_evidence=false
  if [ "$workers1" -gt 0 ] && [ "$workers2" -gt 0 ]; then
    cpu_worker_evidence=true
  fi

  delta=$((cpu2 - cpu1))
  [ "$delta" -ge 0 ] || delta=0
  if [ "$TIMING_OK" = true ]; then rate=$((delta * 60000 / SAMPLE_ELAPSED_MS)); else rate=0; fi
  output_changed=false
  if [ "$output1_ok" = true ] && [ "$output2_ok" = true ] && [ "$hash1" != "$hash2" ]; then
    output_changed=true
  fi
  baseline=unverified
  if [ -n "$threshold" ] && [ "$TIMING_OK" = true ]; then baseline=verified; fi

  if [ "$worker" = verified_present ] && [ "$output_changed" = true ]; then
    activity=active
  elif [ "$worker" = verified_present ] && [ "$baseline" = verified ] && [ "$cpu_worker_evidence" = true ] && [ "$rate" -ge "$threshold" ]; then
    activity=active
  elif [ "$endpoint" = verified_absent ] && [ "$worker" = verified_absent ]; then
    activity=absent
  elif [ "$endpoint" = unverified ] || [ "$worker" = unverified ]; then
    activity=unverified
  elif [ "$worker" = verified_absent ]; then
    activity=inactive
  elif [ "$baseline" = verified ] && [ "$output1_ok" = true ] && [ "$output2_ok" = true ]; then
    activity=parked
  else
    activity=unverified
  fi

  jq -n -c \
    --arg id "$id" --arg harness "$harness" --arg family "$family" \
    --arg backend "$backend" --arg target "$target" --arg worktree "$worktree" \
    --arg endpoint "$endpoint" --arg endpoint_raw "$verdict" --arg worker "$worker" \
    --arg activity "$activity" --arg baseline "$baseline" --arg evidence_grade "$evidence_grade" \
    --argjson cpu1 "$cpu1" --argjson cpu2 "$cpu2" --argjson delta "$delta" \
    --argjson rate "$rate" --argjson pids1 "$pids1" --argjson pids2 "$pids2" \
    --argjson workers1 "$workers1" --argjson workers2 "$workers2" \
    --argjson output1 "$output1_ok" --argjson output2 "$output2_ok" \
    --argjson changed "$output_changed" \
    --arg threshold "${threshold:-}" \
    '{id:$id,harness:$harness,harness_family:$family,backend:$backend,
      target:(if $target=="" then null else $target end),worktree:(if $worktree=="" then null else $worktree end),
      endpoint:{presence:$endpoint,raw:$endpoint_raw},
      worker:{presence:$worker,pids_sample_1:$pids1,pids_sample_2:$pids2,
        harness_processes_sample_1:$workers1,harness_processes_sample_2:$workers2},
      evidence:{grade:$evidence_grade},
      output:{sample_1_readable:$output1,sample_2_readable:$output2,changed:$changed},
      cpu:{sample_1_max_ms:$cpu1,sample_2_max_ms:$cpu2,delta_ms:$delta,
        rate_ms_per_minute:$rate,baseline:$baseline,
        threshold_ms_per_minute:(if $threshold=="" then null else ($threshold|tonumber) end)},
      activity:$activity}' >> "$RECORDS"
done < "$METAS"

NOW=${FM_LIVENESS_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
jq -s \
  --arg observed "$NOW" \
  --argjson interval "$INTERVAL_MS" \
  --argjson elapsed "$SAMPLE_ELAPSED_JSON" \
  --argjson p1 "$PROCESS1_OK" \
  --argjson p2 "$PROCESS2_OK" \
  '{schema:"fm-liveness.v1",observed_at:$observed,interval_ms:$interval,sample_elapsed_ms:$elapsed,
    process_samples:{sample_1_readable:$p1,sample_2_readable:$p2},records:(sort_by(.id))}' \
  "$RECORDS"
