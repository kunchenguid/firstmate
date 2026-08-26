#!/usr/bin/env bash
# Behavior tests for the verified Antigravity CLI (agy) crewmate adapter.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-task-process-lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
HARNESS_SH="$ROOT/bin/fm-harness.sh"
BOOTSTRAP_SH="$ROOT/bin/fm-bootstrap.sh"
TMUX_LIB="$ROOT/bin/fm-tmux-lib.sh"
BACKEND_SH="$ROOT/bin/fm-backend.sh"
TMP_ROOT=$(fm_test_tmproot fm-agy-harness)

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf "%s\n" "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf "firstmate\n"; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|kill-window) exit 0 ;;
  new-session|new-window)
    [ -z "${FM_FAKE_ENDPOINT_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_FAKE_ENDPOINT_LOG"
    exit 0
    ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      prev=
      for a in "$@"; do
        if [ "$prev" = "-l" ]; then
          printf "%s\n" "$a" >> "$FM_FAKE_LAUNCH_LOG"
        fi
        prev=$a
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/unshare" <<'SH'
#!/usr/bin/env bash
set -u
while [ "$#" -gt 0 ]; do
  case "$1" in
    --user|--map-current-user|--pid|--fork|--kill-child=SIGKILL|--mount-proc) shift ;;
    --) shift; break ;;
    *) break ;;
  esac
done
if [ "${1:-}" = /bin/sh ] && [ "${2:-}" = -c ] \
   && [ "${3:-}" = '[ "$$" -eq 1 ]' ]; then
  exit 0
fi
exec "$@"
SH
  chmod +x "$fakebin/unshare"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh agy claude
  printf "%s\n" "$fakebin"
}

make_spawn_case() {
  local name=$1 explicit_id=${2:-} case_dir home proj wt fakebin launchlog id
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  id=${explicit_id:-"agy-$name-x1"}
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf "brief for %s\n" "$id" > "$home/data/$id/brief.md"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  touch "$home/state/.last-watcher-beat"
  printf "%s|%s|%s|%s|%s|%s|%s\n" "$case_dir" "$home" "$proj" "$wt" "$fakebin" "$launchlog" "$id"
}

run_agy_spawn() {
  local home=$1 proj=$2 wt=$3 fakebin=$4 launchlog=$5 id=$6 launch_path
  shift 6
  : > "$launchlog"
  : > "$launchlog.endpoints"
  launch_path=${FM_AGY_TEST_PATH:-$fakebin:$PATH}
  FM_ROOT_OVERRIDE="" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_TASK_PROCESS_SCOPE_START_ATTEMPTS=0 \
    FM_FAKE_LAUNCH_LOG="$launchlog" FM_FAKE_ENDPOINT_LOG="$launchlog.endpoints" PATH="$launch_path" \
    "$SPAWN" "$id" "$proj" agy --mode no-mistakes --yolo off "$@" 2>&1
}

agy_launch_fragment() {
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
}

test_agy_harness_detection() {
  local dir fakebin out
  dir="$TMP_ROOT/marker-fallback"
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$fakebin/ps"

  out=$(PATH="$fakebin:$PATH" ANTIGRAVITY_LS_VERSION=cli-1.1.19 "$HARNESS_SH")
  [ "$out" = "agy" ] || fail "harness detection failed on ANTIGRAVITY_LS_VERSION marker: $out"

  out=$(PATH="$fakebin:$PATH" ANTIGRAVITY_SOURCE_METADATA='{"conversationId":"123"}' "$HARNESS_SH")
  [ "$out" = "agy" ] || fail "harness detection failed on ANTIGRAVITY_SOURCE_METADATA marker: $out"

  # shellcheck source=bin/fm-session-lock-lib.sh
  . "$ROOT/bin/fm-session-lock-lib.sh"
  if fm_harness_process_matches agy agy; then
    fail "worker-only agy was accepted as a primary session-lock owner"
  fi
  if fm_harness_path_name /opt/homebrew/bin/agy >/dev/null; then
    fail "worker-only agy was present in the primary path-identity table"
  fi
  pass "fm-harness detects agy without granting primary session ownership"
}

test_agy_markers_defer_to_markerless_harness_ancestry() {
  local dir bin expected out
  dir="$TMP_ROOT/inherited-marker-detection"
  mkdir -p "$dir"

  for bin in codex opencode kimi muse-bin-0.1.0-R708.1; do
    case "$bin" in
      muse-bin-*) expected=muse ;;
      *) expected=$bin ;;
    esac
    cp "$(command -v bash)" "$dir/$bin"
    out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
      -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
      ANTIGRAVITY_LS_VERSION=cli-1.1.19 \
      ANTIGRAVITY_SOURCE_METADATA='{"conversationId":"inherited"}' \
      "$dir/$bin" -c "r=\$(\"$HARNESS_SH\"); printf '%s' \"\$r\"")
    [ "$out" = "$expected" ] \
      || fail "inherited agy markers overrode $expected ancestry: $out"
  done
  pass "inherited agy markers defer to markerless harness ancestry"
}

test_agy_ancestry_detection_is_anchored() {
  local dir bin out helper
  dir="$TMP_ROOT/ancestry-detection"
  mkdir -p "$dir"

  cp "$(command -v bash)" "$dir/agy"
  out=$(env -u ANTIGRAVITY_LS_VERSION -u ANTIGRAVITY_SOURCE_METADATA \
    -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
    "$dir/agy" -c "r=\$(\"$HARNESS_SH\"); printf '%s' \"\$r\"")
  [ "$out" = agy ] || fail "exact agy process ancestry reported '$out'"

  for bin in notagy agy-helper; do
    cp "$(command -v bash)" "$dir/$bin"
    out=$(env -u ANTIGRAVITY_LS_VERSION -u ANTIGRAVITY_SOURCE_METADATA \
      -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
      -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
      "$dir/$bin" -c "r=\$(\"$HARNESS_SH\"); printf '%s' \"\$r\"")
    [ "$out" != agy ] \
      || fail "unrelated process '$bin' was misdetected as agy"
  done

  if command -v python3 >/dev/null 2>&1; then
    helper="$dir/notagy-helper.py"
    cat > "$helper" <<'PY'
import subprocess
import sys

sys.stdout.write(subprocess.check_output([sys.argv[1]], text=True))
PY
    out=$(env -u ANTIGRAVITY_LS_VERSION -u ANTIGRAVITY_SOURCE_METADATA \
      -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
      -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
      python3 "$helper" "$HARNESS_SH")
    [ "$out" != agy ] \
      || fail "an unrelated interpreter argument containing agy was misdetected"
  fi
  pass "fm-harness detects only agy's exact executable ancestry"
}

test_agy_default_model_and_launch_template() {
  local rec case_dir home proj wt fakebin launchlog id out launched meta_file state_real
  rec=$(make_spawn_case default-model)
  IFS="|" read -r case_dir home proj wt fakebin launchlog id <<EOF
$rec
EOF
  out=$(run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$launchlog" "$id")
  assert_contains "$out" "spawned $id harness=agy" "agy spawn did not report success: $out"

  launched=$(cat "$launchlog")
  assert_contains "$launched" "$(agy_launch_fragment "'$fakebin/agy' --dangerously-skip-permissions --model 'gemini-3.7-flash-high' --prompt-interactive")" \
    "agy launch command did not match expected template with default model: $launched"
  assert_contains "$launched" "env -u CURSOR_AGENT -u CURSOR_INVOKED_AS" \
    "agy launch did not clear inherited Cursor markers: $launched"
  assert_contains "$launched" "env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS" \
    "agy launch did not clear inherited Claude, Pi, and Grok markers: $launched"
  assert_contains "$launched" "fm-task-process-launch.sh" \
    "agy launch did not establish its task process scope: $launched"
  state_real=$(cd "$home/state" && pwd -P)
  assert_contains "$launched" "$state_real/$id.process-scope" \
    "agy launch did not bind its process scope to task state: $launched"

  meta_file="$home/state/$id.meta"
  assert_contains "$(cat "$meta_file")" "model=gemini-3.7-flash-high" "meta file did not record default model: $(cat "$meta_file")"
  assert_contains "$(cat "$meta_file")" "process_scope_token=" "meta file did not retain the agy task process scope"
  assert_contains "$(cat "$home/state/$id.process-scope")" "status=empty" \
    "agy spawn did not prepare a recoverable process scope before launch"
  assert_contains "$(cat "$home/state/$id.process-scope")" "containment=pid-namespace" \
    "agy spawn did not retain its available PID namespace containment"
  pass "fm-spawn: agy defaults to gemini-3.7-flash-high and uses --prompt-interactive"
}

test_agy_process_scope_launcher() {
  local case_dir state record token leader child child_file attempt=0 status launch anchor child_stat anchor_stat fakebin
  case_dir="$TMP_ROOT/process-scope-launcher"
  state="$case_dir/state"
  record="$state/task-x1.process-scope"
  token=scope-launch-x1
  child_file="$case_dir/child.pid"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$state"
  FM_TASK_PROCESS_SCOPE_STATUS=
  printf -v launch 'env -i PATH=/usr/bin:/bin /bin/sh -c "sleep 30" & echo $! > %q' "$child_file"
  python3 - "$ROOT/bin/fm-task-process-launch.sh" "$record" "$token" "$launch" "$fakebin/unshare" <<'PY' &
import os
import sys

os.setpgrp()
os.execv(sys.argv[1], [sys.argv[1], sys.argv[2], sys.argv[3], "-", sys.argv[4], sys.argv[5]])
PY
  leader=$!
  while [ "$attempt" -lt 50 ]; do
    if fm_task_process_scope_record_read "$state" task-x1 "$token" 2>/dev/null \
       && [ "$FM_TASK_PROCESS_SCOPE_STATUS" = active ]; then
      break
    fi
    sleep 0.02
    attempt=$((attempt + 1))
  done
  status=${FM_TASK_PROCESS_SCOPE_STATUS:-}
  if [ "$status" != active ]; then
    [ ! -f "$child_file" ] || kill -KILL "$(cat "$child_file")" 2>/dev/null || true
    fail "agy process-scope launcher did not publish an active scope"
  fi
  attempt=0
  while [ ! -f "$child_file" ] && [ "$attempt" -lt 50 ]; do
    sleep 0.02
    attempt=$((attempt + 1))
  done
  [ -f "$child_file" ] || {
    kill -KILL "$leader" 2>/dev/null || true
    fail "agy process-scope launcher did not start its detached child fixture"
  }
  child=$(cat "$child_file")
  anchor=$FM_TASK_PROCESS_SCOPE_ANCHOR_PID
  [ "$anchor" = "$leader" ] \
    || {
      kill -KILL "$child" "$anchor" 2>/dev/null || true
      fail "agy process-scope launcher did not retain its group leader as ownership anchor"
    }
  [ "$FM_TASK_PROCESS_SCOPE_PGID" = "$leader" ] \
    || {
      kill -KILL "$child" "$anchor" 2>/dev/null || true
      fail "agy process-scope launcher recorded the wrong process group"
    }
  fm_task_process_identity_matches "$anchor" "$FM_TASK_PROCESS_SCOPE_ANCHOR_IDENTITY" \
    || {
      kill -KILL "$child" "$anchor" 2>/dev/null || true
      fail "agy process-scope launcher did not retain a live ownership anchor"
    }
  kill -0 "$child" 2>/dev/null \
    || fail "agy process-scope launcher lost the env-stripped detached child before cleanup"
  fm_task_process_scope_quiesce "$state" task-x1 "$token" agy \
    || fail "agy process-scope launcher could not reap its task process"
  wait "$leader" 2>/dev/null || true
  if kill -0 "$child" 2>/dev/null; then
    child_stat=$(ps -o stat= -p "$child" 2>/dev/null || true)
    case "$child_stat" in
      *Z*) ;;
      *)
        kill -KILL "$child" 2>/dev/null || true
        fail "agy process-scope launcher left its env-stripped detached child alive"
        ;;
    esac
  fi
  attempt=0
  while kill -0 "$anchor" 2>/dev/null && [ "$attempt" -lt 50 ]; do
    anchor_stat=$(ps -o stat= -p "$anchor" 2>/dev/null || true)
    case "$anchor_stat" in *Z*) break ;; esac
    sleep 0.02
    attempt=$((attempt + 1))
  done
  anchor_stat=$(ps -o stat= -p "$anchor" 2>/dev/null || true)
  if kill -0 "$anchor" 2>/dev/null && [ -n "$anchor_stat" ]; then
    case "$anchor_stat" in *Z*) ;; *)
    kill -KILL "$anchor" 2>/dev/null || true
    fail "agy process-scope launcher left its ownership anchor alive after retirement"
    esac
  fi
  fm_task_process_scope_record_read "$state" task-x1 "$token" \
    || fail "agy process-scope launcher lost its durable scope record"
  [ "$FM_TASK_PROCESS_SCOPE_STATUS" = empty ] \
    || fail "agy process-scope launcher did not publish an empty scope after reap"
  pass "agy process-scope launcher owns detached task processes"
}

test_agy_process_scope_wait_survives_signals() {
  local case_dir state record token leader attempt=0 agent agent_identity
  case_dir="$TMP_ROOT/process-scope-signal"
  state="$case_dir/state"
  record="$state/task-x2.process-scope"
  token=scope-launch-x2
  mkdir -p "$state"
  python3 - /bin/bash "$ROOT/bin/fm-task-process-launch.sh" "$record" "$token" - <<'PY' &
import os
import sys

os.setpgrp()
os.execv(sys.argv[1], [sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], "-", "sleep 30", sys.argv[5]])
PY
  leader=$!
  while [ "$attempt" -lt 100 ]; do
    if fm_task_process_scope_record_read "$state" task-x2 "$token" 2>/dev/null \
       && [ "$FM_TASK_PROCESS_SCOPE_STATUS" = active ]; then
      break
    fi
    sleep 0.02
    attempt=$((attempt + 1))
  done
  [ "${FM_TASK_PROCESS_SCOPE_STATUS:-}" = active ] || {
    kill -KILL "$leader" 2>/dev/null || true
    fail "agy process-scope signal fixture did not publish an active scope"
  }
  [ "$FM_TASK_PROCESS_SCOPE_CONTAINMENT" = process-group ] || {
    kill -KILL "$leader" 2>/dev/null || true
    fail "agy portable process-scope fixture did not record process-group containment"
  }
  agent=$FM_TASK_PROCESS_SCOPE_AGENT_PID
  agent_identity=$FM_TASK_PROCESS_SCOPE_AGENT_IDENTITY
  kill -HUP "$leader"
  sleep 0.05
  fm_task_process_scope_record_read "$state" task-x2 "$token" \
    || fail "agy process-scope signal interrupted its durable record"
  [ "$FM_TASK_PROCESS_SCOPE_STATUS" = active ] \
    || fail "agy process-scope signal prematurely retired a live worker"
  fm_task_process_identity_matches "$agent" "$agent_identity" \
    || fail "agy process-scope signal lost its live worker identity"
  fm_task_process_scope_quiesce "$state" task-x2 "$token" agy \
    || fail "agy process-scope signal fixture could not quiesce"
  wait "$leader" 2>/dev/null || true
  pass "agy process-scope launcher survives stock Bash and interrupted waits"
}

test_agy_relaunch_sources_receive_process_scopes() {
  local rec case_dir home proj wt fakebin launchlog id out launched
  rec=$(make_spawn_case scoped-source)
  IFS="|" read -r case_dir home proj wt fakebin launchlog id <<EOF
$rec
EOF
  : > "$launchlog"
  out=$(FM_ROOT_OVERRIDE="" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_TASK_PROCESS_SCOPE_START_ATTEMPTS=0 \
    FM_FAKE_LAUNCH_LOG="$launchlog" FM_FAKE_ENDPOINT_LOG="$launchlog.endpoints" \
    PATH="$fakebin:$PATH" "$SPAWN" "$id" "$proj" claude \
    --mode no-mistakes --yolo off 2>&1)
  assert_contains "$out" "spawned $id harness=claude" "verified agy relaunch source did not spawn: $out"
  launched=$(cat "$launchlog")
  assert_contains "$launched" "fm-task-process-launch.sh" \
    "verified agy relaunch source did not receive a durable process scope"
  assert_contains "$(cat "$home/state/$id.meta")" "process_scope_token=" \
    "verified agy relaunch source metadata omitted its process scope"
  pass "fm-spawn: every verified worker source is scoped for agy transitions"
}

test_agy_effort_flag_handling() {
  local rec case_dir home proj wt fakebin launchlog id out launched

  # 1. Variant model ID with explicit effort: do NOT emit conflicting/redundant --effort
  rec=$(make_spawn_case variant-effort)
  IFS="|" read -r case_dir home proj wt fakebin launchlog id <<EOF
$rec
EOF
  out=$(run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$launchlog" "$id" --model gemini-3.7-flash-high --effort high)
  launched=$(cat "$launchlog")
  assert_contains "$launched" "$(agy_launch_fragment "--model 'gemini-3.7-flash-high'")" "launch did not include model: $launched"
  assert_not_contains "$launched" "--effort" "launch command emitted redundant/conflicting --effort for variant model ID"

  # 2. Base model ID with effort: emits --effort <effort>
  rec=$(make_spawn_case base-effort)
  IFS="|" read -r case_dir home proj wt fakebin launchlog id <<EOF
$rec
EOF
  out=$(run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$launchlog" "$id" --model gemini-3.7-flash --effort medium)
  launched=$(cat "$launchlog")
  assert_contains "$launched" "$(agy_launch_fragment "--model 'gemini-3.7-flash' --effort 'medium'")" "launch command did not include resolved effort: $launched"

  # 3. Base model ID with unsupported xhigh or max effort: capped to high
  rec=$(make_spawn_case capped-effort)
  IFS="|" read -r case_dir home proj wt fakebin launchlog id <<EOF
$rec
EOF
  out=$(run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$launchlog" "$id" --model gemini-3.7-flash --effort xhigh)
  launched=$(cat "$launchlog")
  assert_contains "$launched" "$(agy_launch_fragment "--model 'gemini-3.7-flash' --effort 'high'")" "launch command did not cap xhigh to high: $launched"

  rec=$(make_spawn_case capped-max)
  IFS="|" read -r case_dir home proj wt fakebin launchlog id <<EOF
$rec
EOF
  out=$(run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$launchlog" "$id" --model gemini-3.7-flash --effort max)
  launched=$(cat "$launchlog")
  assert_contains "$launched" "$(agy_launch_fragment "--model 'gemini-3.7-flash' --effort 'high'")" "launch command did not cap max to high: $launched"

  rec=$(make_spawn_case implicit-low)
  IFS="|" read -r case_dir home proj wt fakebin launchlog id <<EOF
$rec
EOF
  out=$(run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$launchlog" "$id" --effort low)
  launched=$(cat "$launchlog")
  assert_contains "$launched" "$(agy_launch_fragment "--model 'gemini-3.7-flash-low'")" "explicit low effort did not select the low model variant: $launched"
  assert_contains "$(cat "$home/state/$id.meta")" "effort=low" "meta did not retain explicit low effort"

  rec=$(make_spawn_case implicit-medium)
  IFS="|" read -r case_dir home proj wt fakebin launchlog id <<EOF
$rec
EOF
  out=$(run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$launchlog" "$id" --effort medium)
  launched=$(cat "$launchlog")
  assert_contains "$launched" "$(agy_launch_fragment "--model 'gemini-3.7-flash-medium'")" "explicit medium effort did not select the medium model variant: $launched"

  rec=$(make_spawn_case conflicting-effort)
  IFS="|" read -r case_dir home proj wt fakebin launchlog id <<EOF
$rec
EOF
  out=$(run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$launchlog" "$id" --model gemini-3.7-flash-high --effort low)
  expect_code 1 $? "a conflicting model variant and effort should be refused"
  assert_contains "$out" "conflicts with requested effort 'low'" "profile conflict refusal was not actionable: $out"
  [ ! -s "$launchlog.endpoints" ] || fail "profile conflict created an endpoint before refusing"
  pass "fm-spawn: agy handles variant model suppression and effort capping appropriately"
}

run_agy_hook() {
  local hooks=$1 event=$2 payload=${3:-'{}'} cmd
  cmd=$(jq -r ".[\"fm-firstmate-busy\"][\"$event\"][0].command" "$hooks")
  [ -n "$cmd" ] && [ "$cmd" != null ] || fail "agy plugin lacks $event"
  printf '%s\n' "$payload" | sh -c "$cmd"
}

test_agy_semantic_busy_lifecycle() {
  local rec case_dir home proj wt fakebin launchlog id out hooks state
  rec=$(make_spawn_case semantic-busy)
  IFS="|" read -r case_dir home proj wt fakebin launchlog id <<EOF
$rec
EOF
  out=$(run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$launchlog" "$id")
  expect_code 0 $? "agy spawn should install semantic lifecycle wiring: $out"
  hooks="$wt/.agents/plugins/fm-firstmate-busy-$id/hooks.json"
  state="$home/state"
  assert_present "$hooks" "agy spawn did not write its isolated lifecycle plugin"
  jq -e . "$hooks" >/dev/null || fail "agy lifecycle plugin is not valid JSON"
  [ "$(fm_busy_classify tmux fake:w agy "$id" "$state")" = "busy fm-spawn" ] \
    || fail "agy launch turn was not seeded busy"
  rm -f "$state/$id.turn-ended"
  out=$(run_agy_hook "$hooks" Stop '{"fullyIdle":false}') \
    || fail "agy active Stop hook failed: $out"
  printf '%s' "$out" | jq -e '.decision == "allow"' >/dev/null \
    || fail "agy active Stop hook did not allow the vendor lifecycle to continue: $out"
  assert_absent "$state/$id.turn-ended" "agy active Stop hook published an unverified turn end"
  [ "$(fm_busy_classify tmux fake:w agy "$id" "$state")" = "unknown agy-hook" ] \
    || fail "agy active Stop hook did not expose unsupported background completion as unknown"
  out=$(run_agy_hook "$hooks" PreInvocation) || fail "agy PreInvocation hook failed: $out"
  [ "$(fm_busy_classify tmux fake:w agy "$id" "$state")" = "busy agy-hook" ] \
    || fail "agy PreInvocation hook did not reopen semantic state"
  out=$(run_agy_hook "$hooks" Stop '{}') || fail "agy malformed Stop hook failed: $out"
  printf '%s' "$out" | jq -e '.decision == "allow"' >/dev/null \
    || fail "agy malformed Stop hook did not terminate defensively: $out"
  assert_absent "$state/$id.turn-ended" "agy Stop hook published a turn end without fullyIdle true"
  [ "$(fm_busy_classify tmux fake:w agy "$id" "$state")" = "unknown agy-hook" ] \
    || fail "agy malformed Stop hook did not expose unreadable state as unknown"
  out=$(run_agy_hook "$hooks" Stop '{"fullyIdle":true}') || fail "agy fully-idle Stop hook failed: $out"
  [ -f "$state/$id.turn-ended" ] || fail "agy Stop hook did not touch the turn-end notification"
  [ "$(fm_busy_classify tmux fake:w agy "$id" "$state")" = "idle agy-hook" ] \
    || fail "agy Stop hook did not settle semantic state"
  out=$(run_agy_hook "$hooks" PreInvocation) || fail "agy PreInvocation hook failed: $out"
  printf '%s' "$out" | jq -e 'type == "object"' >/dev/null \
    || fail "agy PreInvocation hook did not return JSON: $out"
  [ "$(fm_busy_classify tmux fake:w agy "$id" "$state")" = "busy agy-hook" ] \
    || fail "agy PreInvocation hook did not open semantic state"
  pass "fm-spawn and fm-busy-lib: agy hooks preserve verified lifecycle boundaries"
}

test_agy_manifest_name_accepts_dotted_task_id() {
  local rec case_dir home proj wt fakebin launchlog id out manifest
  rec=$(make_spawn_case dotted-id agy.fix.v1)
  IFS="|" read -r case_dir home proj wt fakebin launchlog id <<EOF
$rec
EOF
  out=$(run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$launchlog" "$id")
  expect_code 0 $? "agy spawn should accept a path-safe dotted task ID: $out"
  manifest="$wt/.agents/plugins/fm-firstmate-busy-$id/plugin.json"
  jq -e '.name == "fm-firstmate-busy"' "$manifest" >/dev/null \
    || fail "agy plugin manifest name is not schema-safe for a dotted task ID: $(cat "$manifest")"
  pass "fm-spawn: agy plugin manifest supports dotted task IDs"
}

test_agy_plugin_collisions_are_refused() {
  local rec case_dir home proj wt fakebin launchlog id out plugin exclude
  rec=$(make_spawn_case plugin-collision)
  IFS="|" read -r case_dir home proj wt fakebin launchlog id <<EOF
$rec
EOF
  plugin="$wt/.agents/plugins/fm-firstmate-busy-$id"
  mkdir -p "$plugin"
  printf 'project-owned\n' > "$plugin/plugin.json"
  exclude=$(git -C "$wt" rev-parse --git-path info/exclude)
  printf '/.agents/plugins/fm-firstmate-busy-%s/\n' "$id" >> "$exclude"
  out=$(run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$launchlog" "$id")
  expect_code 1 $? "agy spawn should refuse an existing plugin directory"
  assert_contains "$out" "plugin path already exists" "agy collision refusal was not actionable: $out"
  [ "$(cat "$plugin/plugin.json")" = project-owned ] || fail "agy spawn overwrote a project-owned plugin manifest"
  assert_absent "$plugin/hooks.json" "agy spawn wrote hooks into a project-owned plugin directory"
  assert_present "$home/state/$id.meta" "agy plugin collision did not preserve recovery metadata"
  assert_contains "$(cat "$home/state/$id.meta")" "worktree=$wt" "agy recovery metadata omitted the allocated worktree"
  assert_contains "$(cat "$home/state/$id.meta")" "harness=unknown" "agy collision recovery metadata claimed ownership of the colliding plugin"

  rec=$(make_spawn_case plugin-symlink)
  IFS="|" read -r case_dir home proj wt fakebin launchlog id <<EOF
$rec
EOF
  mkdir -p "$wt/.agents/plugins" "$wt/agy-plugin-target"
  printf 'target-owned\n' > "$wt/agy-plugin-target/sentinel"
  plugin="$wt/.agents/plugins/fm-firstmate-busy-$id"
  ln -s ../../agy-plugin-target "$plugin"
  exclude=$(git -C "$wt" rev-parse --git-path info/exclude)
  printf '/.agents/plugins/fm-firstmate-busy-%s\n/agy-plugin-target/\n' "$id" >> "$exclude"
  out=$(run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$launchlog" "$id")
  expect_code 1 $? "agy spawn should refuse a symlinked plugin directory"
  assert_contains "$out" "plugin path is a symlink" "agy symlink refusal was not actionable: $out"
  [ "$(cat "$wt/agy-plugin-target/sentinel")" = target-owned ] || fail "agy spawn changed the symlink target"
  assert_absent "$wt/agy-plugin-target/plugin.json" "agy spawn followed the plugin symlink for its manifest"
  assert_absent "$wt/agy-plugin-target/hooks.json" "agy spawn followed the plugin symlink for its hooks"
  assert_present "$home/state/$id.meta" "agy plugin symlink refusal did not preserve recovery metadata"
  pass "fm-spawn: agy plugin installation refuses collisions and symlinks"
}

test_agy_post_allocation_failure_preserves_recovery_metadata() {
  local rec case_dir home proj wt fakebin launchlog id out plugin meta
  rec=$(make_spawn_case busy-arm-failure)
  IFS="|" read -r case_dir home proj wt fakebin launchlog id <<EOF
$rec
EOF
  mkdir "$home/state/$id.busy-state.lock"
  out=$(FM_BUSY_LOCK_STALE_SECS=3600 \
    run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$launchlog" "$id")
  expect_code 1 $? "agy spawn should fail when semantic busy-state arming fails"
  assert_contains "$out" "failed to arm the busy-state contract" \
    "agy busy-state failure was not actionable: $out"
  [ -s "$launchlog.endpoints" ] || fail "agy busy-state failure did not exercise a post-allocation path"
  meta="$home/state/$id.meta"
  assert_present "$meta" "agy busy-state failure did not preserve recovery metadata"
  assert_contains "$(cat "$meta")" "worktree=$wt" \
    "agy busy-state recovery metadata omitted the allocated worktree"
  assert_contains "$(cat "$meta")" "harness=unknown" \
    "agy busy-state recovery metadata claimed an incompletely installed adapter"
  plugin="$wt/.agents/plugins/fm-firstmate-busy-$id"
  [ ! -e "$plugin" ] && [ ! -L "$plugin" ] \
    || fail "agy busy-state failure left a partial plugin installation"
  pass "fm-spawn: post-allocation agy failures preserve recovery metadata"
}

test_agy_missing_binary_refuses_before_endpoint_creation() {
  local rec case_dir home proj wt fakebin launchlog id out
  rec=$(make_spawn_case missing-binary)
  IFS="|" read -r case_dir home proj wt fakebin launchlog id <<EOF
$rec
EOF
  rm -f "$fakebin/agy"
  out=$(FM_AGY_TEST_PATH="$fakebin:/usr/bin:/bin" \
    run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$launchlog" "$id")
  expect_code 1 $? "missing agy should refuse the spawn"
  assert_contains "$out" "agy executable not found on PATH" "missing binary refusal did not name agy: $out"
  [ ! -s "$launchlog.endpoints" ] || fail "missing agy created an endpoint before refusing"
  assert_absent "$home/state/$id.meta" "missing agy published task metadata"
  pass "fm-spawn: missing agy refuses before endpoint creation"
}

test_agy_missing_process_enclosure_uses_portable_scope() {
  local rec case_dir home proj wt fakebin launchlog id out rc
  rec=$(make_spawn_case missing-enclosure)
  IFS="|" read -r case_dir home proj wt fakebin launchlog id <<EOF
$rec
EOF
  cat > "$fakebin/unshare" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$fakebin/unshare"
  out=$(run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$launchlog" "$id"); rc=$?
  expect_code 0 "$rc" "agy should launch with portable process tracking when PID namespaces are unavailable"
  assert_contains "$out" "spawned $id harness=agy" \
    "agy portable process scope did not preserve the worker launch: $out"
  [ -s "$launchlog.endpoints" ] \
    || fail "agy portable process scope did not allocate its endpoint"
  assert_contains "$(cat "$home/state/$id.process-scope")" "containment=process-group" \
    "agy portable process scope did not record its containment limit"
  pass "fm-spawn: agy preserves portable worker launches without PID namespaces"
}

test_agy_refuses_secondmate() {
  local case_dir home fakebin id out raw_id raw_out wrapped_id wrapped_out missing_id missing_out
  case_dir="$TMP_ROOT/secondmate"
  home="$case_dir/home"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  id=agy-secondmate-x1
  raw_id=agy-raw-secondmate-x1
  wrapped_id=agy-wrapped-secondmate-x1
  missing_id=agy-missing-identity-secondmate-x1
  mkdir -p "$home/data/$id" "$home/data/$raw_id" "$home/data/$wrapped_id" \
    "$home/data/$missing_id" "$home/projects" "$home/state" "$home/config"
  printf 'charter\n' > "$home/data/$id/brief.md"
  printf 'charter\n' > "$home/data/$raw_id/brief.md"
  printf 'charter\n' > "$home/data/$wrapped_id/brief.md"
  printf 'charter\n' > "$home/data/$missing_id/brief.md"
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 TMUX='fake,1,0' PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" agy --secondmate 2>&1)
  expect_code 1 $? "agy should be refused for secondmate work"
  assert_contains "$out" "crewmate/scout adapter only" "agy secondmate refusal did not explain the capability boundary: $out"

  raw_out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 TMUX='fake,1,0' PATH="$fakebin:$PATH" \
    "$SPAWN" "$raw_id" 'agy-cli --dangerously-skip-permissions' \
      --raw-harness agy --secondmate 2>&1)
  expect_code 1 $? "raw agy command should be refused for secondmate work"
  assert_contains "$raw_out" "agy is a verified crewmate/scout adapter only" \
    "raw agy command bypassed the secondmate capability boundary: $raw_out"

  wrapped_out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 TMUX='fake,1,0' PATH="$fakebin:$PATH" \
    "$SPAWN" "$wrapped_id" 'env -u CLAUDECODE agy-cli --dangerously-skip-permissions' \
      --raw-harness agy --secondmate 2>&1)
  expect_code 1 $? "wrapped agy command should be refused for secondmate work"
  assert_contains "$wrapped_out" "agy is a verified crewmate/scout adapter only" \
    "explicit raw agy identity did not enforce the secondmate capability boundary: $wrapped_out"

  missing_out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 TMUX='fake,1,0' PATH="$fakebin:$PATH" \
    "$SPAWN" "$missing_id" 'env -u CLAUDECODE agy-cli --dangerously-skip-permissions' \
      --secondmate 2>&1)
  expect_code 1 $? "wrapped raw secondmate command without an identity should be refused"
  assert_contains "$missing_out" "requires --raw-harness <adapter-identity>" \
    "wrapped raw command bypassed explicit secondmate identity validation: $missing_out"
  pass "fm-spawn: agy is restricted to crewmate and scout work"
}

test_agy_like_raw_worker_stays_unverified() {
  local rec case_dir home proj wt fakebin launchlog id out meta launched
  rec=$(make_spawn_case raw-lookalike)
  IFS="|" read -r case_dir home proj wt fakebin launchlog id <<EOF
$rec
EOF
  : > "$launchlog"
  : > "$launchlog.endpoints"
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX='fake,1,0' \
    FM_TASK_PROCESS_SCOPE_START_ATTEMPTS=0 \
    FM_FAKE_LAUNCH_LOG="$launchlog" FM_FAKE_ENDPOINT_LOG="$launchlog.endpoints" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" 'agytest --example' \
      --mode no-mistakes --yolo off 2>&1)
  expect_code 0 $? "an unrelated raw worker should still launch through the escape hatch: $out"
  meta=$(cat "$home/state/$id.meta")
  assert_contains "$meta" "harness=agytest" \
    "raw worker metadata did not retain its unverified command identity: $meta"
  assert_not_contains "$meta" "process_scope_token=" \
    "agy-like raw worker was granted a verified adapter process scope: $meta"
  assert_absent "$home/state/$id.process-scope" \
    "agy-like raw worker created an Antigravity process-scope record"
  assert_absent "$wt/.agents/plugins/fm-firstmate-busy-$id" \
    "agy-like raw worker installed Antigravity lifecycle hooks"
  launched=$(cat "$launchlog")
  assert_not_contains "$launched" "fm-task-process-launch.sh" \
    "agy-like raw worker entered the verified Antigravity launch enclosure"
  pass "fm-spawn: agy-like raw workers remain unverified escape-hatch commands"
}

test_agy_busy_matching_and_liveness() {
  # shellcheck source=bin/fm-tmux-lib.sh
  . "$TMUX_LIB"

  # Busy samples
  printf "● Bash(ls -la)\n⣾  Loading...\nesc to cancel\n" | fm_busy_lines_match agy || fail "agy busy footer did not match"

  # Idle samples
  if printf "? for shortcuts                                      Gemini 3.7 Flash · high\n" | fm_busy_lines_match agy; then
    fail "agy idle footer falsely matched as busy"
  fi
  if printf "Completed output mentions ⣾ Loading... as ordinary transcript text\n" | fm_busy_lines_match agy; then
    fail "agy transcript text falsely matched as a live delivery-busy footer"
  fi

  # shellcheck source=bin/backends/tmux.sh
  . "$BACKEND_SH"
  fm_backend_source tmux
  tmux() {
    case "$*" in
      *"list-windows"*) printf "dummy\n"; return 0 ;;
      *"#{pane_current_command}"*) printf "%s\n" "$TEST_COMM"; return 0 ;;
    esac
    return 0
  }
  TEST_COMM=agy
  [ "$(fm_backend_tmux_agent_state "firstmate:dummy")" = "alive" ] || fail "tmux agent state did not report alive for agy"

  TEST_COMM=/opt/homebrew/bin/agy
  [ "$(fm_backend_tmux_agent_state "firstmate:dummy")" = "alive" ] || fail "tmux agent state did not report alive for full path agy"

  TEST_COMM=/opt/homebrew/bin/notagy
  [ "$(fm_backend_tmux_agent_state "firstmate:dummy")" = "ambiguous" ] \
    || fail "tmux agent state misclassified an unrelated agy-containing process"
  pass "fm-tmux-lib and tmux backend: agy busy signature and liveness detection verified"
}

test_agy_crew_dispatch_validation() {
  local case_dir home config out
  case_dir="$TMP_ROOT/dispatch-val"
  home="$case_dir/home"
  config="$home/config"
  mkdir -p "$config"

  # Valid agy profile in crew-dispatch.json
  printf "%s\n" '{"default":{"harness":"agy","model":"gemini-3.7-flash-high","effort":"high"}}' > "$config/crew-dispatch.json"
  out=$(FM_HOME="$home" "$BOOTSTRAP_SH" 2>&1)
  assert_not_contains "$out" "CREW_DISPATCH: invalid" "crew-dispatch was rejected"

  printf "%s\n" '{"default":{"harness":"agy","model":"gemini-3.7-flash","effort":"xhigh"}}' > "$config/crew-dispatch.json"
  out=$(FM_HOME="$home" "$BOOTSTRAP_SH" 2>&1)
  assert_not_contains "$out" "CREW_DISPATCH: invalid" "crew-dispatch rejected an effort that agy caps to high"

  # Invalid effort for agy
  printf "%s\n" '{"default":{"harness":"agy","effort":"bad-effort"}}' > "$config/crew-dispatch.json"
  out=$(FM_HOME="$home" "$BOOTSTRAP_SH" 2>&1)
  assert_contains "$out" "CREW_DISPATCH: invalid config/crew-dispatch.json - invalid effort: agy:bad-effort" \
    "bootstrap did not reject invalid agy effort: $out"
  pass "fm-bootstrap: validates agy harness and accepted efforts in crew-dispatch.json"
}

test_agy_harness_detection
test_agy_markers_defer_to_markerless_harness_ancestry
test_agy_ancestry_detection_is_anchored
test_agy_default_model_and_launch_template
test_agy_process_scope_launcher
test_agy_process_scope_wait_survives_signals
test_agy_relaunch_sources_receive_process_scopes
test_agy_effort_flag_handling
test_agy_semantic_busy_lifecycle
test_agy_manifest_name_accepts_dotted_task_id
test_agy_plugin_collisions_are_refused
test_agy_post_allocation_failure_preserves_recovery_metadata
test_agy_missing_binary_refuses_before_endpoint_creation
test_agy_missing_process_enclosure_uses_portable_scope
test_agy_refuses_secondmate
test_agy_like_raw_worker_stays_unverified
test_agy_busy_matching_and_liveness
test_agy_crew_dispatch_validation
