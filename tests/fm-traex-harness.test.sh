#!/usr/bin/env bash
# Behavior tests for the TraeX ordinary worker/scout adapter.
#
# The launch cases execute the real bin/fm-spawn.sh against a stateful fake
# Herdr CLI and a real isolated git worktree. The fake exposes the same public
# status/agent/explain/pane command shapes used by the production adapter, so
# the test pins launch rendering, exact trust acceptance, the required working
# postcondition, metadata readiness, and semantic-state binding without
# starting a real agent or touching an existing Herdr session.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
HARNESS="$ROOT/bin/fm-harness.sh"
TMP_ROOT=$(fm_test_tmproot fm-traex-harness)

make_traex_fakebin() {  # <dir>
  local dir=$1 fb
  fb=$(fm_fakebin "$dir")
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
state=${FM_FAKE_HERDR_STATE:?}
log=${FM_FAKE_HERDR_LOG:?}
launch=${FM_FAKE_LAUNCH_LOG:?}
phase_file=${FM_FAKE_PHASE_FILE:?}
trust_count=${FM_FAKE_TRUST_COUNT:?}
project=${FM_FAKE_PROJECT:?}
worktree=${FM_FAKE_WORKTREE:?}
composer="$launch.composer"

{
  printf '%s' "${HERDR_SESSION:-}"
  for arg in "$@"; do printf '\x1f%s' "$arg"; done
  printf '\n'
} >> "$log"

phase=$(cat "$phase_file" 2>/dev/null || printf shell)
cmd=${1:-}
sub=${2:-}
case "$cmd $sub" in
  "status --json")
    printf '%s\n' '{"client":{"version":"0.8.0","protocol":19},"server":{"running":true,"version":"0.8.0","protocol":19}}'
    ;;
  "api schema")
    printf '%s\n' '{"methods":["events.subscribe"],"events":["pane.agent_status_changed"]}'
    ;;
  "workspace list")
    if [ -e "$state" ]; then
      printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate","focused":true,"active_tab_id":"w1:t2"}]}}'
    else
      printf '%s\n' '{"result":{"workspaces":[]}}'
    fi
    ;;
  "workspace create")
    : > "$state"
    printf '%s\n' '{"result":{"workspace":{"workspace_id":"w1","label":"firstmate"},"tab":{"tab_id":"w1:t1"},"root_pane":{"pane_id":"w1:p1"}}}'
    ;;
  "tab list")
    if [ "$phase" = shell ] && [ ! -s "$launch" ]; then
      printf '%s\n' '{"result":{"tabs":[{"tab_id":"w1:t1","label":"1","workspace_id":"w1","focused":false}]}}'
    else
      printf '%s\n' '{"result":{"tabs":[{"tab_id":"w1:t1","label":"1","workspace_id":"w1","focused":false},{"tab_id":"w1:t2","label":"fm-traex-test","workspace_id":"w1","focused":true}]}}'
    fi
    ;;
  "tab create")
    printf '%s\n' '{"result":{"tab":{"tab_id":"w1:t2"},"root_pane":{"pane_id":"w1:p2"}}}'
    ;;
  "pane list")
    printf '%s\n' '{"result":{"panes":[{"pane_id":"w1:p1","tab_id":"w1:t1"},{"pane_id":"w1:p2","tab_id":"w1:t2"}]}}'
    ;;
  "pane close")
    ;;
  "pane run")
    pane=${3:-}
    text=${4:-}
    if [ "$pane" = w1:p2 ] && [ "$text" = 'treehouse get' ]; then
      printf '%s\n' "$worktree" > "${FM_FAKE_CWD_FILE:?}"
    fi
    ;;
  "pane get")
    pane=${3:-}
    cwd=$(cat "${FM_FAKE_CWD_FILE:?}" 2>/dev/null || printf '%s' "$project")
    printf '{"result":{"pane":{"pane_id":"%s","tab_id":"w1:t2","workspace_id":"w1","cwd":"%s","foreground_cwd":"%s"}}}\n' "$pane" "$project" "$cwd"
    ;;
  "pane send-text")
    text=${4:-}
    printf '%s\n' "$text" >> "$launch"
    [ "$phase" = shell ] || printf '%s' "$text" > "$composer"
    ;;
  "pane send-keys")
    key=${4:-}
    if [ "$key" = enter ]; then
      case "$phase" in
        shell)
          printf blocked > "$phase_file"
          ;;
        blocked)
          n=$(cat "$trust_count" 2>/dev/null || printf 0)
          printf '%s\n' "$((n + 1))" > "$trust_count"
          : > "$composer"
          printf '%s' "${FM_FAKE_AFTER_TRUST:-working}" > "$phase_file"
          ;;
        idle)
          : > "$composer"
          printf working > "$phase_file"
          ;;
        working)
          [ "${FM_FAKE_SWALLOW_WORKING_ENTER:-0}" = 1 ] || : > "$composer"
          ;;
      esac
    fi
    ;;
  "pane read")
    if [ "$phase" = blocked ]; then
      cat <<'EOF'
> You are in the isolated task copy

  Do you trust the contents of this directory?
  Working with untrusted contents comes with higher risk of prompt injection.

❯ 1. Yes, continue
  2. No, quit

  Press enter to continue
EOF
    else
      printf '❯ %s\n' "$(cat "$composer" 2>/dev/null || true)"
    fi
    ;;
  "agent get")
    case "$phase" in
      blocked|working|idle|done)
        if [ "$phase" = working ] && [ "${FM_FAKE_DROP_AFTER_WORKING:-0}" = 1 ]; then
          reads=$(cat "$phase_file.working-reads" 2>/dev/null || printf 0)
          printf '%s\n' "$((reads + 1))" > "$phase_file.working-reads"
          if [ "$reads" -ge 1 ]; then
            printf '%s\n' '{"error":{"code":"agent_not_found"}}'
            exit 0
          fi
        fi
        # Herdr preserves the pane's creation cwd at the source project while
        # foreground_cwd follows treehouse into the isolated task copy.
        printf '{"result":{"agent":{"agent":"traex","agent_status":"%s","cwd":"%s","foreground_cwd":"%s","pane_id":"w1:p2","state_change_seq":3}}}\n' \
          "$phase" "${FM_FAKE_AGENT_CWD:-$project}" "$worktree"
        ;;
      *)
        printf '%s\n' '{"error":{"code":"agent_not_found"}}'
        ;;
    esac
    ;;
  "agent explain")
    if [ "${FM_FAKE_TRUST_RULE:-exact}" = exact ]; then
      rule='directory_trust_prompt (region=whole_recent priority=1000)'
    else
      rule='unrelated_blocker (region=whole_recent priority=1000)'
    fi
    printf 'agent: traex\nstate: blocked\nmanifest: bundled 2026.08.08.2\nrule: %s\nevidence: "blocked"\n' "$rule"
    ;;
  *)
    ;;
esac
exit 0
SH
  chmod +x "$fb/herdr"
  fm_fake_exit0 "$fb" traex treehouse
  printf '%s\n' "$fb"
}

make_spawn_case() {  # <name>
  local name=$1 dir home project wt fakebin id
  dir="$TMP_ROOT/$name"
  home="$dir/home"
  project="$dir/project"
  wt="$dir/wt"
  id=traex-test
  fakebin=$(make_traex_fakebin "$dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'brief for TraeX\n' > "$home/data/$id/brief.md"
  printf 'off\n' > "$home/config/herdr-presentation-spaces"
  fm_git_worktree "$project" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  : > "$dir/herdr.log"
  : > "$dir/launch.log"
  : > "$dir/launch.log.composer"
  printf shell > "$dir/phase"
  printf '%s\n' "$dir|$home|$project|$wt|$fakebin|$id"
}

read_spawn_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJECT_DIR WT_DIR FAKEBIN_DIR TASK_ID <<EOF
$1
EOF
}

run_traex_spawn() {
  local effort=${1:-high}
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND_HERDR_EVENTS_FORCE=1 HERDR_SESSION=traex-test-session \
    FM_FAKE_HERDR_STATE="$CASE_DIR/herdr.state" FM_FAKE_HERDR_LOG="$CASE_DIR/herdr.log" \
    FM_FAKE_LAUNCH_LOG="$CASE_DIR/launch.log" FM_FAKE_PHASE_FILE="$CASE_DIR/phase" \
    FM_FAKE_TRUST_COUNT="$CASE_DIR/trust-count" FM_FAKE_CWD_FILE="$CASE_DIR/cwd" \
    FM_FAKE_PROJECT="$PROJECT_DIR" FM_FAKE_WORKTREE="$WT_DIR" \
    PATH="$FAKEBIN_DIR:$PATH" \
    env -u HERDR_PANE_ID -u HERDR_SOCKET_PATH -u HERDR_ENV -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
    "$SPAWN" "$TASK_ID" "$PROJECT_DIR" --harness traex --backend herdr \
      --model Doubao-Seed-2.1-Pro --effort "$effort" --mode no-mistakes --yolo off 2>&1
}

run_raw_spawn() {  # <command>
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND_HERDR_EVENTS_FORCE=1 HERDR_SESSION=traex-test-session \
    FM_FAKE_HERDR_STATE="$CASE_DIR/herdr.state" FM_FAKE_HERDR_LOG="$CASE_DIR/herdr.log" \
    FM_FAKE_LAUNCH_LOG="$CASE_DIR/launch.log" FM_FAKE_PHASE_FILE="$CASE_DIR/phase" \
    FM_FAKE_TRUST_COUNT="$CASE_DIR/trust-count" FM_FAKE_CWD_FILE="$CASE_DIR/cwd" \
    FM_FAKE_PROJECT="$PROJECT_DIR" FM_FAKE_WORKTREE="$WT_DIR" \
    PATH="$FAKEBIN_DIR:$PATH" \
    env -u HERDR_PANE_ID -u HERDR_SOCKET_PATH -u HERDR_ENV -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
    "$SPAWN" "$TASK_ID" "$PROJECT_DIR" "$1" --backend herdr \
      --mode no-mistakes --yolo off 2>&1
}

run_traex_send() {  # <text>
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND_HERDR_EVENTS_FORCE=1 HERDR_SESSION=traex-test-session \
    FM_BACKEND_HERDR_SUBMIT_MIN_SLEEP=0 FM_BACKEND_HERDR_SUBMIT_POLLS=1 \
    FM_SEND_SLEEP=0 FM_SEND_SETTLE=0 \
    FM_FAKE_HERDR_STATE="$CASE_DIR/herdr.state" FM_FAKE_HERDR_LOG="$CASE_DIR/herdr.log" \
    FM_FAKE_LAUNCH_LOG="$CASE_DIR/launch.log" FM_FAKE_PHASE_FILE="$CASE_DIR/phase" \
    FM_FAKE_TRUST_COUNT="$CASE_DIR/trust-count" FM_FAKE_CWD_FILE="$CASE_DIR/cwd" \
    FM_FAKE_PROJECT="$PROJECT_DIR" FM_FAKE_WORKTREE="$WT_DIR" \
    PATH="$FAKEBIN_DIR:$PATH" \
    env -u HERDR_PANE_ID -u HERDR_SOCKET_PATH -u HERDR_ENV -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
    "$ROOT/bin/fm-send.sh" "$TASK_ID" "$1" 2>&1
}

run_traex_reconcile() {
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_BACKEND_HERDR_EVENTS_FORCE=1 HERDR_SESSION=traex-test-session \
    FM_FAKE_HERDR_STATE="$CASE_DIR/herdr.state" FM_FAKE_HERDR_LOG="$CASE_DIR/herdr.log" \
    FM_FAKE_LAUNCH_LOG="$CASE_DIR/launch.log" FM_FAKE_PHASE_FILE="$CASE_DIR/phase" \
    FM_FAKE_TRUST_COUNT="$CASE_DIR/trust-count" FM_FAKE_CWD_FILE="$CASE_DIR/cwd" \
    FM_FAKE_PROJECT="$PROJECT_DIR" FM_FAKE_WORKTREE="$WT_DIR" \
    PATH="$FAKEBIN_DIR:$PATH" \
    env -u HERDR_PANE_ID -u HERDR_SOCKET_PATH -u HERDR_ENV -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
    bash -c '. "$1/bin/fm-backend.sh"; fm_backend_source herdr; fm_backend_herdr_traex_reconcile_current "$2" "$3" "$4"' \
      _ "$ROOT" "$HOME_DIR/state" traex-test-session w1:p2
}

run_traex_poll_reconcile() {
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_BACKEND_HERDR_EVENTS_FORCE=1 HERDR_SESSION=traex-test-session \
    FM_FAKE_HERDR_STATE="$CASE_DIR/herdr.state" FM_FAKE_HERDR_LOG="$CASE_DIR/herdr.log" \
    FM_FAKE_LAUNCH_LOG="$CASE_DIR/launch.log" FM_FAKE_PHASE_FILE="$CASE_DIR/phase" \
    FM_FAKE_TRUST_COUNT="$CASE_DIR/trust-count" FM_FAKE_CWD_FILE="$CASE_DIR/cwd" \
    FM_FAKE_PROJECT="$PROJECT_DIR" FM_FAKE_WORKTREE="$WT_DIR" \
    PATH="$FAKEBIN_DIR:$PATH" \
    env -u HERDR_PANE_ID -u HERDR_SOCKET_PATH -u HERDR_ENV -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
    bash -c '. "$1/bin/fm-backend.sh"; fm_backend_source herdr; fm_backend_herdr_reconcile_transitions "$2" "$3" "$3:$4"' \
      _ "$ROOT" "$HOME_DIR/state" traex-test-session w1:p2
}

set_traex_readiness() {  # <expected> <new>
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    bash -c '. "$1/bin/fm-backend.sh"; fm_backend_source herdr; fm_backend_herdr_traex_readiness_set "$2" "$3" "$4" "$5" "$6"' \
      _ "$ROOT" "$HOME_DIR/state" traex-test-session w1:p2 "$1" "$2"
}

run_traex_observe() {  # <reported-status> <reported-agent>
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_BACKEND_HERDR_EVENTS_FORCE=1 HERDR_SESSION=traex-test-session \
    FM_FAKE_HERDR_STATE="$CASE_DIR/herdr.state" FM_FAKE_HERDR_LOG="$CASE_DIR/herdr.log" \
    FM_FAKE_LAUNCH_LOG="$CASE_DIR/launch.log" FM_FAKE_PHASE_FILE="$CASE_DIR/phase" \
    FM_FAKE_TRUST_COUNT="$CASE_DIR/trust-count" FM_FAKE_CWD_FILE="$CASE_DIR/cwd" \
    FM_FAKE_PROJECT="$PROJECT_DIR" FM_FAKE_WORKTREE="$WT_DIR" \
    PATH="$FAKEBIN_DIR:$PATH" \
    env -u HERDR_PANE_ID -u HERDR_SOCKET_PATH -u HERDR_ENV -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
    bash -c '. "$1/bin/fm-backend.sh"; fm_backend_source herdr; rec=$(fm_backend_herdr_normalize_event "$4" "" "$5" "$6"); fm_backend_herdr_traex_observe_transition "$2" "$3" "$rec"' \
      _ "$ROOT" "$HOME_DIR/state" traex-test-session w1:p2 "$1" "$2"
}

start_interruptible_traex_spawn() {
  exec env -u HERDR_PANE_ID -u HERDR_SOCKET_PATH -u HERDR_ENV -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
    FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND_HERDR_EVENTS_FORCE=1 HERDR_SESSION=traex-test-session \
    FM_BACKEND_HERDR_TRAEX_START_INTERVAL=1 FM_FAKE_AFTER_TRUST=blocked \
    FM_FAKE_HERDR_STATE="$CASE_DIR/herdr.state" FM_FAKE_HERDR_LOG="$CASE_DIR/herdr.log" \
    FM_FAKE_LAUNCH_LOG="$CASE_DIR/launch.log" FM_FAKE_PHASE_FILE="$CASE_DIR/phase" \
    FM_FAKE_TRUST_COUNT="$CASE_DIR/trust-count" FM_FAKE_CWD_FILE="$CASE_DIR/cwd" \
    FM_FAKE_PROJECT="$PROJECT_DIR" FM_FAKE_WORKTREE="$WT_DIR" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$TASK_ID" "$PROJECT_DIR" --harness traex --backend herdr \
      --model Doubao-Seed-2.1-Pro --effort high --mode no-mistakes --yolo off
}

test_marker_detection_is_scoped() {
  local out dir
  out=$(FM_TRAEX_HARNESS=traex CLAUDECODE=1 "$HARNESS")
  [ "$out" = traex ] || fail "Firstmate TraeX marker did not win detection, got '$out'"
  dir="$TMP_ROOT/detect"
  mkdir -p "$dir"
  cp "$(command -v bash)" "$dir/traex"
  out=$(env -u FM_TRAEX_HARNESS -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT \
    "$dir/traex" -c "r=\$(\"$HARNESS\"); printf '%s' \"\$r\"")
  [ "$out" != traex ] || fail "an unrelated traex-named process was misclassified as a Firstmate worker"
  pass "traex detection requires the exact Firstmate launch marker and ignores unrelated ancestry"
}

test_spawn_accepts_only_exact_trust_then_observes_working() {
  local rec out status launch meta verdict lifecycle
  rec=$(make_spawn_case launch)
  read_spawn_case "$rec"
  out=$(run_traex_spawn)
  status=$?
  expect_code 0 "$status" "TraeX Herdr spawn should succeed after exact trust acceptance: $out"
  assert_contains "$out" "spawned $TASK_ID harness=traex kind=ship" "spawn did not report TraeX success"
  [ "$(cat "$CASE_DIR/trust-count")" = 1 ] || fail "the trust chooser was not accepted exactly once"
  [ "$(cat "$CASE_DIR/phase")" = working ] || fail "spawn returned before native working"
  launch=$(cat "$CASE_DIR/launch.log")
  [ "$(grep -c . "$CASE_DIR/launch.log")" = 1 ] \
    || fail "the TraeX launch brief was injected more than once"
  assert_contains "$launch" 'FM_TRAEX_HARNESS=traex traex -y' "launch omitted scoped TraeX identity/autonomy"
  assert_contains "$launch" "--model 'Doubao-Seed-2.1-Pro'" "launch omitted selected model"
  assert_contains "$launch" "-c 'model_reasoning_effort=\"high\"'" "launch omitted verified effort config"
  assert_contains "$launch" 'encode launch-brief' "launch did not deliver one positional brief"
  assert_not_contains "$launch" 'projects.' "launch tried to edit/bypass TraeX global project trust"
  meta="$HOME_DIR/state/$TASK_ID.meta"
  assert_grep 'backend=herdr' "$meta" "meta did not retain Herdr"
  assert_grep 'harness=traex' "$meta" "meta did not retain TraeX"
  assert_grep 'traex_ready=1' "$meta" "spawn published success without lifecycle readiness"
  verdict=$(fm_busy_classify herdr traex-test-session:w1:p2 traex "$TASK_ID" "$HOME_DIR/state")
  [ "$verdict" = 'busy herdr-traex' ] || fail "working launch did not bind semantic lifecycle, got '$verdict'"
  lifecycle=$(fm_busy_record_read "$HOME_DIR/state" "$TASK_ID")
  case "$lifecycle" in
    'busy herdr-traex agent-working '*) ;;
    *) fail "initial native working did not flow through the bound transition record: $lifecycle" ;;
  esac
  pass "traex spawn accepts only the exact fresh-worktree trust chooser and requires native working"
}

test_mismatched_launch_provenance_sends_no_key() {
  local rec out status other
  rec=$(make_spawn_case wrong-cwd)
  read_spawn_case "$rec"
  other="$CASE_DIR/unrelated"
  mkdir -p "$other"
  out=$(FM_FAKE_AGENT_CWD="$other" FM_BACKEND_HERDR_TRAEX_START_POLLS=3 \
    FM_BACKEND_HERDR_TRAEX_START_INTERVAL=0 run_traex_spawn)
  status=$?
  [ "$status" -ne 0 ] || fail "TraeX accepted a pane created outside both exact task roots"
  assert_contains "$out" 'launch identity does not belong to the isolated task worktree' \
    "wrong creation provenance did not fail with the identity diagnostic"
  assert_absent "$CASE_DIR/trust-count" "wrong creation provenance received Enter"
  pass "traex accepts only exact source-root provenance plus the live isolated cwd"
}

test_unrecognized_dialog_sends_no_key_and_fails_launch() {
  local rec out status
  rec=$(make_spawn_case wrong-dialog)
  read_spawn_case "$rec"
  out=$(FM_FAKE_TRUST_RULE=wrong FM_BACKEND_HERDR_TRAEX_START_POLLS=3 \
    FM_BACKEND_HERDR_TRAEX_START_INTERVAL=0 run_traex_spawn)
  status=$?
  [ "$status" -ne 0 ] || fail "an unrecognized blocked screen was accepted as directory trust"
  assert_contains "$out" 'did not identify the exact directory-trust dialog' \
    "unrecognized dialog failure did not name the structural proof"
  assert_absent "$CASE_DIR/trust-count" "an unrecognized blocked screen received Enter"
  assert_grep 'traex_ready=failed' "$HOME_DIR/state/$TASK_ID.meta" \
    "failed structural recognition left lifecycle readiness pending"
  pass "traex sends no key when the exact trust rule/default cannot be identified"
}

test_key_send_without_working_is_not_launch_success() {
  local rec out status
  rec=$(make_spawn_case no-working)
  read_spawn_case "$rec"
  out=$(FM_FAKE_AFTER_TRUST=idle FM_BACKEND_HERDR_TRAEX_START_POLLS=3 \
    FM_BACKEND_HERDR_TRAEX_START_INTERVAL=0 run_traex_spawn)
  status=$?
  [ "$status" -ne 0 ] || fail "trust-key transport was mistaken for task launch success"
  [ "$(cat "$CASE_DIR/trust-count")" = 1 ] || fail "fixture did not submit the verified chooser once"
  assert_contains "$out" 'never observed the task instructions begin processing' \
    "postcondition failure did not name the missing working transition"
  assert_not_contains "$out" "spawned $TASK_ID" "spawn printed success from the key send alone"
  pass "traex requires native working after trust acceptance and never trusts key transport alone"
}

test_post_ready_reconciliation_failure_preserves_bound_lifecycle() {
  local rec out status verdict
  rec=$(make_spawn_case reconcile-fail)
  read_spawn_case "$rec"
  out=$(FM_FAKE_DROP_AFTER_WORKING=1 run_traex_spawn)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded after losing its native lifecycle identity"
  assert_contains "$out" 'current Herdr lifecycle could not be reconciled' \
    "post-ready reconciliation failure did not name its lifecycle consequence"
  assert_grep 'traex_ready=1' "$HOME_DIR/state/$TASK_ID.meta" \
    "post-ready failure disabled later native lifecycle recovery"
  assert_not_contains "$out" "spawned $TASK_ID" \
    "post-ready reconciliation failure still printed spawn success"
  verdict=$(fm_busy_classify herdr traex-test-session:w1:p2 traex "$TASK_ID" "$HOME_DIR/state")
  [ "$verdict" = 'busy herdr-traex' ] \
    || fail "transient reconciliation failure overwrote the observed working state: $verdict"
  printf idle > "$CASE_DIR/phase"
  run_traex_reconcile || fail "later native idle recovery was refused after spawn reconciliation failed"
  verdict=$(fm_busy_classify herdr traex-test-session:w1:p2 traex "$TASK_ID" "$HOME_DIR/state")
  [ "$verdict" = 'idle herdr-traex' ] \
    || fail "later native idle did not close the preserved working state: $verdict"
  assert_present "$HOME_DIR/state/$TASK_ID.turn-ended" \
    "later native idle recovery emitted no durable completion notification"
  pass "traex preserves bound working state and readiness across transient spawn reconciliation failure"
}

test_max_effort_refuses_before_endpoint() {
  local rec out status
  rec=$(make_spawn_case max-refuse)
  read_spawn_case "$rec"
  out=$(run_traex_spawn max)
  status=$?
  [ "$status" -ne 0 ] || fail "TraeX accepted the unverified max effort"
  assert_contains "$out" 'max is not verified and is refused' \
    "max-effort refusal did not identify the verified TraeX ceiling"
  [ ! -s "$CASE_DIR/herdr.log" ] || fail "max effort queried or created a Herdr endpoint"
  assert_absent "$HOME_DIR/state/$TASK_ID.meta" "max effort published task metadata"
  pass "traex refuses max effort before endpoint creation"
}

test_unsupported_tmux_refuses_before_endpoint() {
  local rec out status fake_tmux_log
  rec=$(make_spawn_case tmux-refuse)
  read_spawn_case "$rec"
  fake_tmux_log="$CASE_DIR/tmux.log"
  cat > "$FAKEBIN_DIR/tmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_FAKE_TMUX_LOG:?}"
exit 0
SH
  chmod +x "$FAKEBIN_DIR/tmux"
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_TMUX_LOG="$fake_tmux_log" TMUX='fake,1,0' \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$TASK_ID" "$PROJECT_DIR" --harness traex --backend tmux \
      --mode no-mistakes --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "TraeX tmux spawn was accepted without a structural launch postcondition"
  assert_contains "$out" 'verified only on backend=herdr' "unsupported backend refusal was not actionable"
  [ ! -s "$fake_tmux_log" ] || fail "unsupported TraeX backend created or queried a tmux endpoint"
  assert_absent "$HOME_DIR/state/$TASK_ID.meta" "unsupported TraeX backend published metadata"
  pass "traex refuses every unproven backend before endpoint creation"
}

test_secondmate_and_raw_launch_refuse() {
  local rec out status sm
  rec=$(make_spawn_case role-refuse)
  read_spawn_case "$rec"
  sm="$CASE_DIR/secondmate"
  mkdir -p "$sm/data" "$sm/bin"
  printf '# Firstmate\n' > "$sm/AGENTS.md"
  printf '%s\n' "$TASK_ID" > "$sm/.fm-secondmate-home"
  printf 'charter\n' > "$sm/data/charter.md"
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_SPAWN_NO_GUARD=1 \
    FM_BACKEND_HERDR_EVENTS_FORCE=1 PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$TASK_ID" "$sm" --harness traex --backend herdr --secondmate 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "TraeX secondmate was accepted"
  assert_contains "$out" 'crewmate/scout adapter only' "secondmate refusal did not name the role boundary"

  rm -f "$HOME_DIR/state/$TASK_ID.meta"
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_SPAWN_NO_GUARD=1 \
    FM_BACKEND_HERDR_EVENTS_FORCE=1 PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$TASK_ID" "$PROJECT_DIR" 'traex -y arbitrary' --backend herdr \
      --mode no-mistakes --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "raw TraeX command was promoted into the verified adapter"
  assert_contains "$out" 'verified launch template' "raw TraeX refusal did not name the verified boundary"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_SPAWN_NO_GUARD=1 \
    FM_BACKEND_HERDR_EVENTS_FORCE=1 PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$TASK_ID" "$PROJECT_DIR" \
      'env FM_TRAEX_HARNESS=traex traex -y arbitrary' --backend herdr \
      --mode no-mistakes --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "an env-prefixed raw TraeX command bypassed the verified template"
  assert_contains "$out" 'verified launch template' \
    "env-prefixed raw TraeX refusal did not name the verified boundary"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_SPAWN_NO_GUARD=1 \
    FM_BACKEND_HERDR_EVENTS_FORCE=1 PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$TASK_ID" "$PROJECT_DIR" \
      "sh -c 'tra''ex -y arbitrary'" --backend herdr \
      --mode no-mistakes --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a shell-obfuscated raw TraeX command bypassed admission"
  assert_contains "$out" 'verified launch template' \
    "shell-wrapped raw TraeX refusal did not name the verified boundary"
  [ ! -s "$CASE_DIR/herdr.log" ] || fail "a refused raw TraeX command queried or created Herdr state"
  assert_absent "$HOME_DIR/state/$TASK_ID.meta" "a refused raw TraeX command published task metadata"
  pass "traex refuses secondmate and raw-command promotion"
}

test_non_traex_raw_shell_launch_remains_supported() {
  local rec out status launch
  rec=$(make_spawn_case non-traex-raw)
  read_spawn_case "$rec"
  out=$(run_raw_spawn "sh -c 'echo ordinary-raw-ok'")
  status=$?
  expect_code 0 "$status" "ordinary raw shell launch should retain existing Herdr behavior: $out"
  launch=$(cat "$CASE_DIR/launch.log")
  [ "$launch" = "sh -c 'echo ordinary-raw-ok'" ] \
    || fail "ordinary non-TraeX raw launch changed: $launch"
  assert_grep 'harness=sh' "$HOME_DIR/state/$TASK_ID.meta" \
    "ordinary raw shell launch did not retain its detected harness"
  pass "non-traex raw shell launch behavior remains available"
}

test_send_refuses_unready_or_invalid_lifecycle_before_typing() {
  local rec out status before after
  rec=$(make_spawn_case send-readiness)
  read_spawn_case "$rec"
  out=$(run_traex_spawn)
  status=$?
  expect_code 0 "$status" "TraeX spawn for steering admission should succeed: $out"
  before=$(wc -l < "$CASE_DIR/launch.log" | tr -d '[:space:]')

  set_traex_readiness 1 pending || fail "could not install pending readiness fixture"
  out=$(run_traex_send 'must not type while pending')
  status=$?
  [ "$status" -ne 0 ] || fail "TraeX steer accepted pending launch readiness"
  after=$(wc -l < "$CASE_DIR/launch.log" | tr -d '[:space:]')
  [ "$after" = "$before" ] || fail "pending TraeX steer typed before exact readiness validation"

  set_traex_readiness pending failed || fail "could not install failed readiness fixture"
  out=$(run_traex_send 'must not type after launch failure')
  status=$?
  [ "$status" -ne 0 ] || fail "TraeX steer accepted failed launch readiness"
  after=$(wc -l < "$CASE_DIR/launch.log" | tr -d '[:space:]')
  [ "$after" = "$before" ] || fail "failed TraeX steer typed before exact readiness validation"

  set_traex_readiness failed 1 || fail "could not restore ready fixture"
  printf 'malformed\n' > "$HOME_DIR/state/$TASK_ID.busy-state"
  out=$(run_traex_send 'must not type with malformed lifecycle')
  status=$?
  [ "$status" -ne 0 ] || fail "TraeX steer accepted a malformed lifecycle record"
  after=$(wc -l < "$CASE_DIR/launch.log" | tr -d '[:space:]')
  [ "$after" = "$before" ] || fail "malformed-lifecycle TraeX steer typed before validation"
  pass "traex steering validates exact readiness and lifecycle before typing"
}

test_start_observation_persists_lifecycle_before_return() {
  local rec gen out status lifecycle
  rec=$(make_spawn_case start-boundary)
  read_spawn_case "$rec"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$HOME_DIR/state" "$TASK_ID") \
    || fail "could not arm the startup observation fixture"
  fm_write_meta "$HOME_DIR/state/$TASK_ID.meta" \
    'window=traex-test-session:w1:p2' "endpoint_task_id=$TASK_ID" \
    "worktree=$WT_DIR" "project=$PROJECT_DIR" 'harness=traex' 'kind=ship' \
    'backend=herdr' 'herdr_session=traex-test-session' 'herdr_pane_id=w1:p2' \
    "busy_gen=$gen" 'traex_ready=pending'
  printf working > "$CASE_DIR/phase"
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_FAKE_HERDR_STATE="$CASE_DIR/herdr.state" FM_FAKE_HERDR_LOG="$CASE_DIR/herdr.log" \
    FM_FAKE_LAUNCH_LOG="$CASE_DIR/launch.log" FM_FAKE_PHASE_FILE="$CASE_DIR/phase" \
    FM_FAKE_TRUST_COUNT="$CASE_DIR/trust-count" FM_FAKE_CWD_FILE="$CASE_DIR/cwd" \
    FM_FAKE_PROJECT="$PROJECT_DIR" FM_FAKE_WORKTREE="$WT_DIR" PATH="$FAKEBIN_DIR:$PATH" \
    bash -c '. "$1/bin/fm-backend.sh"; fm_backend_source herdr; fm_backend_herdr_traex_lock_runtime; lock="$2/.spawn-$3.lock"; fm_lock_try_acquire "$lock" || exit 1; fm_backend_herdr_traex_spawn_owner_publish "$lock" || exit 1; fm_backend_herdr_traex_wait_started "$4" "$5" "$6" "$2"' \
      _ "$ROOT" "$HOME_DIR/state" "$TASK_ID" traex-test-session:w1:p2 "$WT_DIR" "$PROJECT_DIR" 2>&1)
  status=$?
  expect_code 0 "$status" "startup working observation should persist through its owner: $out"
  lifecycle=$(fm_busy_record_read "$HOME_DIR/state" "$TASK_ID")
  case "$lifecycle" in
    'busy herdr-traex agent-working '*) ;;
    *) fail "startup observation returned before persisting its lifecycle: $lifecycle" ;;
  esac
  pass "traex startup observation persists lifecycle before returning"
}

test_active_send_requires_post_submit_composer_clearance() {
  local rec out status before after
  rec=$(make_spawn_case active-send)
  read_spawn_case "$rec"
  out=$(run_traex_spawn)
  status=$?
  expect_code 0 "$status" "TraeX spawn for active steering should succeed: $out"
  before=$(wc -l < "$CASE_DIR/launch.log" | tr -d '[:space:]')
  out=$(FM_FAKE_SWALLOW_WORKING_ENTER=1 run_traex_send 'must remain visibly pending')
  status=$?
  [ "$status" -ne 0 ] || fail "pre-existing native working falsely acknowledged a swallowed steer"
  assert_contains "$out" 'delivery unconfirmed' \
    "swallowed active TraeX steer did not retain the loud failure boundary"
  after=$(wc -l < "$CASE_DIR/launch.log" | tr -d '[:space:]')
  [ "$after" = "$((before + 1))" ] || fail "active TraeX steer was typed more than once"
  [ "$(cat "$CASE_DIR/launch.log.composer")" = 'must remain visibly pending' ] \
    || fail "active TraeX steer did not remain in the observable composer"
  pass "traex active steering requires post-submit composer clearance"
}

test_send_persists_working_before_delivery_ack() {
  local rec out status verdict
  rec=$(make_spawn_case send-transition)
  read_spawn_case "$rec"
  out=$(run_traex_spawn)
  status=$?
  expect_code 0 "$status" "TraeX spawn for steering should succeed: $out"
  printf idle > "$CASE_DIR/phase"
  run_traex_reconcile || fail "initial TraeX completion could not be reconciled"
  rm -f "$HOME_DIR/state/$TASK_ID.turn-ended"

  out=$(run_traex_send 'reply with exactly STEER_OK')
  status=$?
  expect_code 0 "$status" "TraeX steer should be confirmed: $out"
  verdict=$(fm_busy_classify herdr traex-test-session:w1:p2 traex "$TASK_ID" "$HOME_DIR/state")
  [ "$verdict" = 'busy herdr-traex' ] \
    || fail "confirmed TraeX steer returned without persisting observed working: $verdict"

  printf idle > "$CASE_DIR/phase"
  run_traex_reconcile || fail "missed steer completion could not be reconciled"
  verdict=$(fm_busy_classify herdr traex-test-session:w1:p2 traex "$TASK_ID" "$HOME_DIR/state")
  [ "$verdict" = 'idle herdr-traex' ] \
    || fail "reconnect did not close the persisted steer: $verdict"
  assert_present "$HOME_DIR/state/$TASK_ID.turn-ended" \
    "reconnect emitted no durable completion for the confirmed steer"
  pass "traex steering persists working before acknowledgement so reconnect recovers completion"
}

test_send_from_blocked_requires_native_working() {
  local rec out status verdict
  rec=$(make_spawn_case send-blocked)
  read_spawn_case "$rec"
  out=$(run_traex_spawn)
  status=$?
  expect_code 0 "$status" "TraeX spawn for blocked steering should succeed: $out"
  printf idle > "$CASE_DIR/phase"
  run_traex_reconcile || fail "initial completion for blocked steering could not be reconciled"
  rm -f "$HOME_DIR/state/$TASK_ID.turn-ended"
  printf blocked > "$CASE_DIR/phase"
  run_traex_reconcile || fail "blocked baseline could not be persisted"

  out=$(run_traex_send 'resume from the blocker')
  status=$?
  expect_code 0 "$status" "TraeX blocked-baseline steer should observe working: $out"
  verdict=$(fm_busy_classify herdr traex-test-session:w1:p2 traex "$TASK_ID" "$HOME_DIR/state")
  [ "$verdict" = 'busy herdr-traex' ] \
    || fail "blocked-baseline steer acknowledged without native working: $verdict"
  pass "traex blocked-baseline steering acknowledges only persisted native working"
}

test_stale_idle_cannot_close_a_new_working_turn() {
  local rec out status verdict
  rec=$(make_spawn_case stale-idle)
  read_spawn_case "$rec"
  out=$(run_traex_spawn)
  status=$?
  expect_code 0 "$status" "TraeX spawn for stale transition should succeed: $out"
  printf idle > "$CASE_DIR/phase"
  run_traex_reconcile || fail "old turn idle could not be reconciled"
  rm -f "$HOME_DIR/state/$TASK_ID.turn-ended"
  printf working > "$CASE_DIR/phase"
  run_traex_reconcile || fail "new turn working could not be reconciled"

  run_traex_observe idle traex || fail "queued old idle could not be folded authoritatively"
  verdict=$(fm_busy_classify herdr traex-test-session:w1:p2 traex "$TASK_ID" "$HOME_DIR/state")
  [ "$verdict" = 'busy herdr-traex' ] \
    || fail "queued old idle closed the current native working turn: $verdict"
  assert_absent "$HOME_DIR/state/$TASK_ID.turn-ended" \
    "queued old idle emitted a false completion for the new turn"
  pass "traex transition folding revalidates native level before semantic mutation"
}

test_failed_and_orphaned_pending_launches_reconcile_terminal_level() {
  local readiness rec out status verdict
  for readiness in failed pending; do
    rec=$(make_spawn_case "terminal-$readiness")
    read_spawn_case "$rec"
    out=$(run_traex_spawn)
    status=$?
    expect_code 0 "$status" "TraeX spawn for $readiness terminal recovery should succeed: $out"
    set_traex_readiness 1 "$readiness" || fail "could not install $readiness readiness fixture"
    rm -f "$HOME_DIR/state/$TASK_ID.turn-ended"
    printf idle > "$CASE_DIR/phase"
    run_traex_poll_reconcile || fail "$readiness TraeX lifecycle did not reconcile through polling"
    verdict=$(fm_busy_classify herdr traex-test-session:w1:p2 traex "$TASK_ID" "$HOME_DIR/state")
    [ "$verdict" = 'idle herdr-traex' ] \
      || fail "$readiness TraeX launch remained busy after native idle: $verdict"
    assert_present "$HOME_DIR/state/$TASK_ID.turn-ended" \
      "$readiness TraeX launch emitted no recovered completion notification"
    assert_grep 'traex_ready=failed' "$HOME_DIR/state/$TASK_ID.meta" \
      "$readiness TraeX launch did not retain terminal recovery readiness"
  done
  pass "failed and orphaned pending TraeX launches reconcile terminal levels"
}

test_interrupted_spawn_clears_pending_readiness() {
  local rec pid i ready
  rec=$(make_spawn_case interrupted-spawn)
  read_spawn_case "$rec"
  start_interruptible_traex_spawn > "$CASE_DIR/spawn.out" 2>&1 &
  pid=$!
  ready=
  for ((i = 0; i < 200; i++)); do
    ready=$(grep '^traex_ready=' "$HOME_DIR/state/$TASK_ID.meta" 2>/dev/null || true)
    [ "$ready" = 'traex_ready=pending' ] && break
    sleep 0.02
  done
  if [ "$ready" != 'traex_ready=pending' ]; then
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "interrupt fixture never published pending readiness: $(cat "$CASE_DIR/spawn.out" 2>/dev/null)"
  fi
  kill -TERM "$pid" 2>/dev/null || fail "could not interrupt the pending TraeX spawn"
  wait "$pid" 2>/dev/null || true
  assert_grep 'traex_ready=failed' "$HOME_DIR/state/$TASK_ID.meta" \
    "interrupted TraeX spawn left readiness pending"
  pass "traex spawn cleanup fails pending readiness before releasing ownership"
}

test_terminal_notification_intent_recovers_after_publication_failure() {
  local rec out status verdict pending notification
  rec=$(make_spawn_case completion-intent)
  read_spawn_case "$rec"
  out=$(run_traex_spawn)
  status=$?
  expect_code 0 "$status" "TraeX spawn for completion-intent recovery should succeed: $out"
  pending="$HOME_DIR/state/$TASK_ID.traex-turn-ended.pending"
  notification="$HOME_DIR/state/$TASK_ID.turn-ended"
  mkdir "$notification"
  printf idle > "$CASE_DIR/phase"
  if run_traex_reconcile >/dev/null 2>&1; then
    fail "terminal reconciliation succeeded without publishing its notification"
  fi
  verdict=$(fm_busy_classify herdr traex-test-session:w1:p2 traex "$TASK_ID" "$HOME_DIR/state")
  [ "$verdict" = 'idle herdr-traex' ] \
    || fail "failed notification publication did not retain terminal idle: $verdict"
  assert_present "$pending" \
    "terminal idle committed without crash-recoverable notification intent"
  rmdir "$notification"
  run_traex_reconcile || fail "reconnect did not publish the staged completion notification"
  assert_present "$notification" \
    "reconnect lost the staged completion notification"
  assert_absent "$pending" \
    "published completion left replayable notification intent"
  rm -f "$notification"
  run_traex_reconcile || fail "repeated terminal reconciliation failed after intent publication"
  assert_absent "$notification" \
    "repeated terminal reconciliation duplicated the recovered notification"
  pass "traex terminal notification intent survives publication failure and reconnect"
}

test_native_transition_fold_is_sparse_and_bound() {
  local rec out status verdict before
  rec=$(make_spawn_case transitions)
  read_spawn_case "$rec"
  out=$(run_traex_spawn)
  status=$?
  expect_code 0 "$status" "TraeX spawn for transition folding should succeed: $out"
  verdict=$(fm_busy_classify herdr traex-test-session:w1:p2 traex "$TASK_ID" "$HOME_DIR/state")
  [ "$verdict" = 'busy herdr-traex' ] || fail "working transition classified '$verdict'"
  before=$(cat "$HOME_DIR/state/$TASK_ID.busy-state")
  run_traex_reconcile || fail "reconciled working failed"
  [ "$(cat "$HOME_DIR/state/$TASK_ID.busy-state")" = "$before" ] \
    || fail "repeated working level rewrote the semantic record"

  printf idle > "$CASE_DIR/phase"
  run_traex_reconcile || fail "idle transition failed"
  verdict=$(fm_busy_classify herdr traex-test-session:w1:p2 traex "$TASK_ID" "$HOME_DIR/state")
  [ "$verdict" = 'idle herdr-traex' ] || fail "idle transition classified '$verdict'"
  assert_present "$HOME_DIR/state/$TASK_ID.turn-ended" \
    "busy-to-idle did not write the durable completion notification"
  before=$(cat "$HOME_DIR/state/$TASK_ID.busy-state")
  rm -f "$HOME_DIR/state/$TASK_ID.turn-ended"
  run_traex_reconcile || fail "reconciled idle failed"
  assert_absent "$HOME_DIR/state/$TASK_ID.turn-ended" \
    "repeated idle level duplicated the completion notification"
  [ "$(cat "$HOME_DIR/state/$TASK_ID.busy-state")" = "$before" ] \
    || fail "repeated idle level rewrote the semantic record"

  if run_traex_observe working codex 2>/dev/null; then
    fail "a mismatched Herdr agent identity updated the TraeX lifecycle"
  fi
  pass "traex Herdr transitions persist busy/idle and emit one bound completion notification"
}

test_pending_trust_block_is_suppressed_only_until_launch_fails() {
  local state id gen blocked marker rc lock
  state="$TMP_ROOT/pending/state"
  id=traex-pending
  mkdir -p "$state"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" "$id")
  fm_write_meta "$state/$id.meta" \
    'window=sess:w1:p2' 'endpoint_task_id=traex-pending' 'worktree=/tmp/wt' 'project=/tmp/project' \
    'harness=traex' 'kind=ship' 'backend=herdr' 'herdr_session=sess' \
    'herdr_workspace_id=w1' 'herdr_tab_id=w1:t2' 'herdr_pane_id=w1:p2' \
    "busy_gen=$gen" 'traex_ready=pending'
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-backend.sh"
  fm_backend_source herdr
  blocked=$(fm_transition_record w1:p2 w1 '' blocked traex)
  STATE=$state
  fm_backend_herdr_traex_lock_runtime
  lock="$state/.spawn-$id.lock"
  fm_lock_try_acquire "$lock" || fail "could not claim the active spawn-owner fixture"
  fm_backend_herdr_traex_spawn_owner_publish "$lock" \
    || fail "could not publish the active spawn-owner identity"
  fm_backend_herdr_apply_transition "$state" sess "$blocked" >/dev/null
  rc=$?
  [ "$rc" = 1 ] || fail "actively owned pending launch trust should be absorbed, got $rc"
  marker="$state/.herdr-escalated-sess_w1_p2"
  assert_absent "$marker" "pending trust was committed as a supervisor blocker"
  fm_lock_release "$lock"
  fm_backend_herdr_apply_transition "$state" sess "$blocked" >/dev/null
  rc=$?
  [ "$rc" = 0 ] || fail "orphaned pending launch blocker should become actionable, got $rc"
  assert_grep 'traex_ready=failed' "$state/$id.meta" \
    "orphaned pending launch did not leave suppression atomically"
  pass "only a live TraeX spawn owner can suppress startup trust"
}

test_marker_detection_is_scoped
test_spawn_accepts_only_exact_trust_then_observes_working
test_mismatched_launch_provenance_sends_no_key
test_unrecognized_dialog_sends_no_key_and_fails_launch
test_key_send_without_working_is_not_launch_success
test_post_ready_reconciliation_failure_preserves_bound_lifecycle
test_max_effort_refuses_before_endpoint
test_unsupported_tmux_refuses_before_endpoint
test_secondmate_and_raw_launch_refuse
test_non_traex_raw_shell_launch_remains_supported
test_send_refuses_unready_or_invalid_lifecycle_before_typing
test_start_observation_persists_lifecycle_before_return
test_active_send_requires_post_submit_composer_clearance
test_send_persists_working_before_delivery_ack
test_send_from_blocked_requires_native_working
test_stale_idle_cannot_close_a_new_working_turn
test_failed_and_orphaned_pending_launches_reconcile_terminal_level
test_interrupted_spawn_clears_pending_readiness
test_terminal_notification_intent_recovers_after_publication_failure
test_native_transition_fold_is_sparse_and_bound
test_pending_trust_block_is_suppressed_only_until_launch_fails

echo "# all fm-traex-harness tests passed"
