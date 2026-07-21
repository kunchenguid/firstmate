#!/usr/bin/env bash
# tests/fm-failover.test.sh - preservation-first provider failover.
# Deterministic tests using fake tmux/ps/harness CLIs so no tokens are spent
# and no real backend state is required.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
# shellcheck source=bin/fm-failover-lib.sh
. "$ROOT/bin/fm-failover-lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-failover-tests)

FAKE_ROOT="$TMP_ROOT/fakeroot"
mkdir -p "$FAKE_ROOT/bin"
cat > "$FAKE_ROOT/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$FAKE_ROOT/bin/fm-guard.sh"

# Export fake control variables with safe defaults so every test can assign
# per-case overrides and have them inherited by the script under test.
export FM_FAKE_TMUX_COMMAND='' FM_FAKE_TMUX_COMMAND_FILE='' FM_FAKE_TMUX_PATH=''
export FM_FAKE_TMUX_CAPTURE='' FM_FAKE_TMUX_PANE_PID=99999 FM_FAKE_TMUX_WINDOWS=''
export FM_FAKE_PS_ROWS='' FM_FAKE_TMUX_SENT=/dev/null
export FM_FAKE_CLAUDE_AUTH_EXIT=0 FM_FAKE_CLAUDE_AUTH_OUT=''
export FM_FAKE_CODEX_LOGIN_EXIT=0 FM_FAKE_CODEX_LOGIN_OUT=''
export FM_FAKE_PI_LIST_EXIT=0 FM_FAKE_PI_LIST_OUT=''
export FM_FAKE_PI_LIST_ollama_kimi_k2_7_code_EXIT=0 FM_FAKE_PI_LIST_ollama_kimi_k2_7_code_OUT=''
export FM_FAKE_PI_LIST_ollama_glm_5_2_EXIT=0 FM_FAKE_PI_LIST_ollama_glm_5_2_OUT=''
export FM_FAKE_CREW_STATE='state: unknown · source: none · fake default'
export FM_FAKE_QUOTA_AXI_OUT='' FM_FAKE_QUOTA_AXI_EXIT=0
export NM_BRANCH='' NM_ID=none NM_HEAD=none NM_STATUS=none NM_STEP=none NM_STEP_STATE=idle
export FM_PROVIDER_PROBE_MODEL_OLLAMA=ollama/glm-5.2

make_fakebin() {
  local dir=$1
  mkdir -p "$dir/fakebin"
  local fb="$dir/fakebin"

  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = "capture-pane" ]; then
  cat "${FM_FAKE_TMUX_CAPTURE:-/dev/null}" 2>/dev/null
  exit 0
fi
if [ "${1:-}" = "display-message" ]; then
  fmt=""
  print=0
  for a in "$@"; do
    case "$a" in
      -p) print=1 ;;
      '#{pane_current_path}') fmt=pane_current_path ;;
      '#{pane_current_command}') fmt=pane_current_command ;;
      '#{pane_id}') fmt=pane_id ;;
      '#{pane_pid}') fmt=pane_pid ;;
      '#{cursor_y}'*) fmt=cursor_y ;;
    esac
  done
  if [ "$print" = 1 ]; then
    case "$fmt" in
      pane_current_path) printf '%s\n' "${FM_FAKE_TMUX_PATH:-/tmp}" ;;
      pane_current_command)
        if [ -n "${FM_FAKE_TMUX_COMMAND_FILE:-}" ] && [ -f "$FM_FAKE_TMUX_COMMAND_FILE" ]; then
          cat "$FM_FAKE_TMUX_COMMAND_FILE"
        else
          printf '%s\n' "${FM_FAKE_TMUX_COMMAND:-bash}"
        fi
        ;;
      pane_id) printf 'fakepane\n' ;;
      pane_pid) printf '%s\n' "${FM_FAKE_TMUX_PANE_PID:-99999}" ;;
      cursor_y) printf '0\n' ;;
      *) printf '\n' ;;
    esac
  fi
  exit 0
fi
if [ "${1:-}" = "list-windows" ]; then
  printf '%s\n' "${FM_FAKE_TMUX_WINDOWS:-}"
  exit 0
fi
if [ "${1:-}" = "send-keys" ]; then
  shift
  target=""
  text=""
  is_enter=0
  is_esc=0
  lit=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -t) shift; target=${1:-} ;;
      -l) lit=1 ;;
      Enter) is_enter=1 ;;
      Escape) is_esc=1 ;;
      *) [ "$lit" = 1 ] && text="$1" ;;
    esac
    shift
  done
  if [ "$is_esc" = 1 ]; then
    printf '[ESC]\n' >> "${FM_FAKE_TMUX_SENT:-/dev/null}"
  fi
  if [ "$lit" = 1 ] && [ -n "$text" ]; then
    printf '%s\n' "$text" >> "${FM_FAKE_TMUX_SENT:-/dev/null}"
    if [ -n "${FM_FAKE_TMUX_CAPTURE:-}" ]; then
      printf '%s\n' "$text" >> "$FM_FAKE_TMUX_CAPTURE"
    fi
    case "$text" in
      /quit|/exit)
        [ -n "${FM_FAKE_TMUX_COMMAND_FILE:-}" ] && printf 'bash\n' > "$FM_FAKE_TMUX_COMMAND_FILE"
        ;;
    esac
  fi
  if [ "$is_enter" = 1 ]; then
    printf '[ENTER]\n' >> "${FM_FAKE_TMUX_SENT:-/dev/null}"
    if [ -n "${FM_FAKE_TMUX_CAPTURE:-}" ] && [ -s "$FM_FAKE_TMUX_CAPTURE" ]; then
      _tmp=$(mktemp 2>/dev/null) || _tmp="${FM_FAKE_TMUX_CAPTURE}.tmp"
      sed '$d' "$FM_FAKE_TMUX_CAPTURE" > "$_tmp" 2>/dev/null && mv -f "$_tmp" "$FM_FAKE_TMUX_CAPTURE"
      rm -f "$_tmp" 2>/dev/null
    fi
  fi
  exit 0
fi
exit 1
SH
  chmod +x "$fb/tmux"

  cat > "$fb/ps" <<'SH'
#!/usr/bin/env bash
set -u
if [ -n "${FM_FAKE_PS_ROWS:-}" ] && [ -f "$FM_FAKE_PS_ROWS" ]; then
  current=${FM_FAKE_TMUX_COMMAND:-bash}
  if [ -n "${FM_FAKE_TMUX_COMMAND_FILE:-}" ] && [ -f "$FM_FAKE_TMUX_COMMAND_FILE" ]; then
    current=$(head -1 "$FM_FAKE_TMUX_COMMAND_FILE" 2>/dev/null || printf '%s' "$current")
  fi
  if [ "$current" = bash ] || [ "$current" = sh ] || [ -z "$current" ]; then
    cat "$FM_FAKE_PS_ROWS"
  else
    while IFS= read -r line; do
      case "$line" in
        *" $current "*|*"/$current "*) printf '%s\n' "$line" ;;
        *) printf '%s\n' "$line" | grep -qF -- "$current" && printf '%s\n' "$line" || true ;;
      esac
    done < "$FM_FAKE_PS_ROWS"
  fi
fi
exit 0
SH
  chmod +x "$fb/ps"

  cat > "$fb/claude" <<'SH'
#!/usr/bin/env bash
set -u
if [ "$1" = "auth" ] && [ "${2:-}" = "status" ]; then
  [ -n "${FM_FAKE_CLAUDE_AUTH_OUT:-}" ] && printf '%s\n' "$FM_FAKE_CLAUDE_AUTH_OUT"
  exit "${FM_FAKE_CLAUDE_AUTH_EXIT:-0}"
fi
if [ "$1" = "--version" ]; then
  echo 'fake-claude 1.0'
  exit 0
fi
echo "fake claude: unhandled $*" >&2
exit 1
SH
  chmod +x "$fb/claude"

  cat > "$fb/codex" <<'SH'
#!/usr/bin/env bash
set -u
if [ "$1" = "login" ] && [ "${2:-}" = "status" ]; then
  [ -n "${FM_FAKE_CODEX_LOGIN_OUT:-}" ] && printf '%s\n' "$FM_FAKE_CODEX_LOGIN_OUT"
  exit "${FM_FAKE_CODEX_LOGIN_EXIT:-0}"
fi
if [ "$1" = "--version" ] || [ "$1" = "-V" ]; then
  echo 'fake-codex 1.0'
  exit 0
fi
echo "fake codex: unhandled $*" >&2
exit 1
SH
  chmod +x "$fb/codex"

  cat > "$fb/pi" <<'SH'
#!/usr/bin/env bash
set -u
if [ "$1" = "--list-models" ]; then
  model=${2:-default}
  key=$(printf '%s' "$model" | tr -c 'A-Za-z0-9' '_')
  exit_var="FM_FAKE_PI_LIST_${key}_EXIT"
  out_var="FM_FAKE_PI_LIST_${key}_OUT"
  code=${!exit_var:-${FM_FAKE_PI_LIST_EXIT:-0}}
  [ -n "${!out_var:-}" ] && printf '%s\n' "${!out_var:-}"
  [ -n "${FM_FAKE_PI_LIST_OUT:-}" ] && printf '%s\n' "$FM_FAKE_PI_LIST_OUT"
  exit "$code"
fi
if [ "$1" = "--version" ] || [ "$1" = "-v" ]; then
  echo 'fake-pi 1.0'
  exit 0
fi
echo "fake pi: unhandled $*" >&2
exit 1
SH
  chmod +x "$fb/pi"

  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -u
if [ "$1" = "axi" ] && [ "$2" = "status" ]; then
  printf 'branch: %s\n' "${NM_BRANCH:-}"
  printf 'id: %s\n' "${NM_ID:-none}"
  printf 'head: %s\n' "${NM_HEAD:-none}"
  printf 'status: %s\n' "${NM_STATUS:-none}"
  printf '%s, "%s", step detail\n' "${NM_STEP:-run_step}" "${NM_STEP_STATE:-running}"
  exit 0
fi
echo "fake no-mistakes: unhandled $*" >&2
exit 0
SH
  chmod +x "$fb/no-mistakes"

  cat > "$fb/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
set -u
id=${1:-}
key=$(printf '%s' "$id" | tr -c 'A-Za-z0-9' '_')
var="FM_FAKE_CREW_STATE_$key"
val=${!var:-${FM_FAKE_CREW_STATE:-}}
printf '%s\n' "${val:-state: unknown · source: none · fake default}"
exit 0
SH
  chmod +x "$fb/fm-crew-state.sh"

  cat > "$fb/quota-axi" <<'SH'
#!/usr/bin/env bash
set -u
[ -n "${FM_FAKE_QUOTA_AXI_OUT:-}" ] && printf '%s\n' "$FM_FAKE_QUOTA_AXI_OUT"
exit "${FM_FAKE_QUOTA_AXI_EXIT:-0}"
SH
  chmod +x "$fb/quota-axi"

  printf '%s\n' "$fb"
}

make_home() {
  local name=$1
  local dir="$TMP_ROOT/$name"
  mkdir -p "$dir/state" "$dir/data"
  printf '%s\n' "$dir"
}

make_task() {
  local home=$1 id=$2 harness=$3 model=$4 effort=$5 backend=${6:-tmux}
  local proj wt
  proj="$home/proj"
  wt="$home/wt"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  fm_write_meta "$home/state/$id.meta" \
    "window=test:$id" \
    "worktree=$wt" \
    "project=$proj" \
    "harness=$harness" \
    "model=$model" \
    "effort=$effort" \
    "kind=ship" \
    "backend=$backend" \
    "mode=no-mistakes" \
    "yolo=off" \
    "tasktmp=$home/tmp"
  mkdir -p "$home/data/$id"
  printf '# brief for %s\n' "$id" > "$home/data/$id/brief.md"
  printf '%s\n' "$wt"
}

# Run fm-failover.sh with the hermetic fakebin and write its combined output to
# <outfile>. Per-case fake env vars must be set as separate assignments before
# calling this function (they are exported because they were exported at the
# top of the file).
run_failover_to() {
  local outfile=$1 home=$2 id=$3 fakebin=$4
  shift 4
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_ROOT_OVERRIDE="$FAKE_ROOT" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAILOVER_PROBE_TIMEOUT=5 FM_FAILOVER_EXIT_TIMEOUT=5 FM_FAILOVER_VERIFY_TIMEOUT=5 \
    PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-failover.sh" "$id" "$@" > "$outfile" 2>&1
}

reset_fakes() {
  FM_FAKE_TMUX_COMMAND='' FM_FAKE_TMUX_COMMAND_FILE='' FM_FAKE_TMUX_PATH=''
  FM_FAKE_TMUX_CAPTURE='' FM_FAKE_TMUX_PANE_PID=99999 FM_FAKE_TMUX_WINDOWS=''
  FM_FAKE_PS_ROWS='' FM_FAKE_TMUX_SENT=/dev/null
  FM_FAKE_CLAUDE_AUTH_EXIT=0 FM_FAKE_CLAUDE_AUTH_OUT=''
  FM_FAKE_CODEX_LOGIN_EXIT=0 FM_FAKE_CODEX_LOGIN_OUT=''
  FM_FAKE_PI_LIST_EXIT=0 FM_FAKE_PI_LIST_OUT=''
  FM_FAKE_PI_LIST_ollama_kimi_k2_7_code_EXIT=0 FM_FAKE_PI_LIST_ollama_kimi_k2_7_code_OUT=''
  FM_FAKE_PI_LIST_ollama_glm_5_2_EXIT=0 FM_FAKE_PI_LIST_ollama_glm_5_2_OUT=''
  FM_FAKE_CREW_STATE='state: unknown · source: none · fake default'
  FM_FAKE_QUOTA_AXI_OUT='' FM_FAKE_QUOTA_AXI_EXIT=0
  NM_BRANCH='' NM_ID=none NM_HEAD=none NM_STATUS=none NM_STEP=none NM_STEP_STATE=idle
}

# --- pure classification tests ------------------------------------------------

test_outage_evidence_hits_and_misses() {
  local hit miss
  hit=$(fm_failover_outage_evidence "$(printf 'some output\nusage limit exceeded\n')")
  [ -n "$hit" ] || fail "usage limit evidence not detected"
  miss=$(fm_failover_outage_evidence "$(printf 'working: compiling\nretrying in 23s\n')")
  [ -z "$miss" ] || fail "plain working text misclassified as outage: $miss"
  pass "outage evidence hits quota signatures and misses ordinary work"
}

test_route_and_provider_classification() {
  local meta home
  home=$(make_home route-class)
  meta="$home/state/meta"
  fm_write_meta "$meta" "harness=codex" "model=gpt-5.6-sol"
  fm_failover_route_is_openai "$meta" || fail "codex route should be OpenAI"
  fm_write_meta "$meta" "harness=pi" "model=openai/gpt-5.6-sol"
  fm_failover_route_is_openai "$meta" || fail "pi openai model should be OpenAI"
  fm_write_meta "$meta" "harness=pi" "model=ollama/kimi-k2.7-code"
  fm_failover_route_is_openai "$meta" && fail "pi ollama route should not be OpenAI"
  fm_write_meta "$meta" "harness=claude" "model=claude-fable-5[1m]"
  fm_failover_route_is_openai "$meta" && fail "claude route should not be OpenAI"
  [ "$(fm_failover_provider_of_route claude 'claude-fable-5[1m]')" = anthropic ] || fail "claude provider mismatch"
  [ "$(fm_failover_provider_of_route codex gpt-5.6-sol)" = openai ] || fail "codex provider mismatch"
  [ "$(fm_failover_provider_of_route pi ollama/glm-5.2)" = ollama ] || fail "pi ollama provider mismatch"
  pass "route and provider classification match the GLX routing rules"
}

test_candidate_ladder_never_opens_openai() {
  local list
  list=$(fm_failover_candidates)
  [ "$(printf '%s' "$list" | head -1)" = "claude:claude-fable-5[1m]" ] || fail "first candidate is not Fable"
  printf '%s' "$list" | grep -qF "codex" && fail "OpenAI-backed codex appears in default ladder"
  if FM_FAILOVER_CANDIDATES='codex:gpt-5.6-sol claude:claude-fable-5[1m]' fm_failover_candidates >/dev/null 2>&1; then
    fail "OpenAI override was accepted"
  fi
  pass "candidate ladder refuses OpenAI destinations"
}

test_probe_classification() {
  [ "$(fm_failover_probe_classify 0 'ok')" = available ] || fail "exit 0 not available"
  [ "$(fm_failover_probe_classify 124 'timeout')" = unavailable ] || fail "timeout not unavailable"
  [ "$(fm_failover_probe_classify 1 'not logged in')" = unavailable ] || fail "auth fail not unavailable"
  [ "$(fm_failover_probe_classify 1 'ollama is not running')" = unavailable ] || fail "ollama down not unavailable"
  [ "$(fm_failover_probe_classify 1 'random crash')" = inconclusive ] || fail "random crash not inconclusive"
  pass "probe classification distinguishes available, unavailable, and inconclusive"
}

test_backend_support_matrix() {
  fm_failover_backend_supported tmux || fail "tmux should be supported"
  if fm_failover_backend_supported herdr >/dev/null 2>&1; then fail "herdr should be refused"; fi
  if fm_failover_backend_supported zellij >/dev/null 2>&1; then fail "zellij should be refused"; fi
  if fm_failover_backend_supported orca >/dev/null 2>&1; then fail "orca should be refused"; fi
  if fm_failover_backend_supported cmux >/dev/null 2>&1; then fail "cmux should be refused"; fi
  pass "backend support is tmux-only with named refusal reasons for others"
}

test_provider_readiness_states() {
  local home state
  home=$(make_home ready-states)
  state="$home/state"
  [ "$(fm_failover_provider_readiness "$state" openai)" = "unknown openai no fresh readiness receipt" ] || fail "unknown without receipt"
  fm_write_meta "$(fm_failover_usage_path "$state" openai)" \
    "recorded_at=$(($(date +%s) - 10))" "status=ready" "source=test"
  [ "$(fm_failover_provider_readiness "$state" openai)" = "ready openai recent successful native operation (age 10s)" ] || fail "fresh ready receipt not ready"
  touch "$(fm_failover_hold_path "$state" openai)"
  [ "$(fm_failover_provider_readiness "$state" openai)" = "limited openai held after verified exhaustion" ] || fail "held provider not limited"
  rm -f "$(fm_failover_hold_path "$state" openai)"
  fm_write_meta "$(fm_failover_usage_path "$state" openai)" \
    "recorded_at=$(($(date +%s) - 9999))" "status=ready" "source=test"
  [ "$(fm_failover_provider_readiness "$state" openai)" = "unknown openai no fresh readiness receipt" ] || fail "stale ready receipt not unknown"
  pass "provider readiness states are limited, ready, and unknown"
}

test_provider_specific_weekly_avoid() {
  local home state line
  home=$(make_home openai-avoid)
  state="$home/state"
  fm_write_meta "$(fm_failover_usage_path "$state" openai)" \
    "recorded_at=$(date +%s)" "source=test" "status=advisory" "session_pct=30" "week_pct=45"
  line=$(fm_failover_provider_pressure "$state" openai)
  [ "${line%% *}" = ok ] || fail "openai week 45 should be ok (threshold 50): $line"
  fm_write_meta "$(fm_failover_usage_path "$state" openai)" \
    "recorded_at=$(date +%s)" "source=test" "status=advisory" "session_pct=30" "week_pct=55"
  line=$(fm_failover_provider_pressure "$state" openai)
  [ "${line%% *}" = avoid ] || fail "openai week 55 should be avoid (threshold 50): $line"
  fm_write_meta "$(fm_failover_usage_path "$state" anthropic)" \
    "recorded_at=$(date +%s)" "source=test" "status=advisory" "session_pct=30" "week_pct=55"
  line=$(fm_failover_provider_pressure "$state" anthropic)
  [ "${line%% *}" = ok ] || fail "anthropic week 55 should be ok (threshold 90): $line"
  pass "provider-specific weekly avoid threshold defaults openai to 50 and leaves others at 90"
}

test_outage_evidence_hits_and_misses
test_route_and_provider_classification
test_candidate_ladder_never_opens_openai
test_probe_classification
test_backend_support_matrix
test_provider_readiness_states
test_provider_specific_weekly_avoid

# --- script-level eligibility and preservation -----------------------------

test_non_openai_route_is_noop() {
  local home wt fakebin out code
  home=$(make_home noop)
  fakebin=$(make_fakebin "$home")
  wt=$(make_task "$home" ship1 claude 'claude-fable-5[1m]' high)
  out="$home/ship1.out"
  run_failover_to "$out" "$home" ship1 "$fakebin" --reason test
  code=$?
  out_text=$(cat "$out")
  expect_code 0 "$code" "non-OpenAI route should exit 0: $out_text"
  assert_contains "$out_text" "no-op: task ship1" "no-op message missing"
  pass "non-OpenAI route is a no-op"
}

test_secondmate_refused() {
  local home fakebin meta out code out_text
  home=$(make_home secondmate-refuse)
  fakebin=$(make_fakebin "$home")
  meta="$home/state/sm1.meta"
  fm_write_meta "$meta" "window=firstmate:sm1" "worktree=$home" "project=$home" \
    "harness=codex" "model=gpt-5.6-sol" "kind=secondmate" "mode=secondmate"
  out="$home/sm1.out"
  run_failover_to "$out" "$home" sm1 "$fakebin" --reason test
  code=$?
  out_text=$(cat "$out")
  expect_code 1 "$code" "secondmate should be refused"
  assert_contains "$out_text" "secondmate" "secondmate refusal message missing"
  pass "secondmate tasks are refused by failover"
}

test_healthy_worker_refused() {
  local home wt fakebin out code out_text
  home=$(make_home healthy)
  fakebin=$(make_fakebin "$home")
  wt=$(make_task "$home" ship2 codex 'gpt-5.6-sol' high)
  FM_FAKE_TMUX_COMMAND=codex
  FM_FAKE_CREW_STATE='state: working · source: run-step · validating'
  out="$home/ship2.out"
  run_failover_to "$out" "$home" ship2 "$fakebin" --reason test
  code=$?
  out_text=$(cat "$out")
  expect_code 3 "$code" "healthy worker should be ineligible: $out_text"
  assert_contains "$out_text" "not eligible" "ineligibility message missing"
  reset_fakes
  pass "healthy worker is refused"
}

test_parked_wedge_refused() {
  local home wt fakebin out code out_text
  home=$(make_home parked-wedge)
  fakebin=$(make_fakebin "$home")
  wt=$(make_task "$home" ship3 codex 'gpt-5.6-sol' high)
  FM_FAKE_TMUX_COMMAND=codex
  FM_FAKE_CREW_STATE='state: parked · source: run-step · parked at review'
  out="$home/ship3.out"
  run_failover_to "$out" "$home" ship3 "$fakebin" --reason test
  code=$?
  out_text=$(cat "$out")
  expect_code 3 "$code" "parked+wedge should be ineligible"
  assert_contains "$out_text" "parked" "parked refusal missing"
  reset_fakes
  pass "parked review decision plus wedge pressure is refused"
}

test_outage_evidence_eligible_and_sets_hold() {
  local home wt fakebin out code out_text capture command_file ps_rows
  home=$(make_home outage)
  fakebin=$(make_fakebin "$home")
  wt=$(make_task "$home" ship4 codex 'gpt-5.6-sol' high)
  capture="$home/cap"
  printf 'working...\nusage limit exceeded for organization\n' > "$capture"
  command_file="$home/tmux-command"; printf 'codex\n' > "$command_file"
  ps_rows="$home/ps"
  printf '1 0 codex --model gpt-5.6-sol\n' > "$ps_rows"
  printf '2 1 claude --model claude-fable-5[1m]\n' >> "$ps_rows"
  FM_FAKE_TMUX_CAPTURE="$capture"
  FM_FAKE_TMUX_PATH="$wt"
  FM_FAKE_TMUX_COMMAND_FILE="$command_file"
  FM_FAKE_TMUX_COMMAND=codex
  FM_FAKE_TMUX_PANE_PID=1
  FM_FAKE_PS_ROWS="$ps_rows"
  FM_FAKE_CLAUDE_AUTH_EXIT=0
  FM_FAKE_CLAUDE_AUTH_OUT='Logged in'
  FM_FAKE_CREW_STATE='state: unknown · source: none'
  out="$home/ship4.out"
  run_failover_to "$out" "$home" ship4 "$fakebin" --check-only
  code=$?
  out_text=$(cat "$out")
  expect_code 0 "$code" "outage evidence should be eligible in check-only"
  assert_contains "$out_text" "eligible ship4 evidence=outage" "eligible outage line missing"
  out="$home/ship4b.out"
  run_failover_to "$out" "$home" ship4 "$fakebin" --reason test
  code=$?
  out_text=$(cat "$out")
  expect_code 0 "$code" "outage failover should succeed: $out_text"
  assert_present "$home/state/.provider-hold-openai" "verified outage should create openai hold"
  reset_fakes
  pass "outage evidence makes task eligible and records provider hold"
}

test_dead_agent_eligible() {
  local home wt fakebin out code out_text
  home=$(make_home dead-agent)
  fakebin=$(make_fakebin "$home")
  wt=$(make_task "$home" ship5 codex 'gpt-5.6-sol' high)
  FM_FAKE_TMUX_COMMAND=bash
  out="$home/ship5.out"
  run_failover_to "$out" "$home" ship5 "$fakebin" --check-only
  code=$?
  out_text=$(cat "$out")
  expect_code 0 "$code" "dead agent should be eligible"
  assert_contains "$out_text" "eligible ship5 evidence=dead" "eligible dead line missing"
  reset_fakes
  pass "dead agent is eligible"
}

test_full_fable_failover_preserves_state() {
  local home wt fakebin out code out_text capture head_before head_after dirty_before dirty_after
  home=$(make_home fable-failover)
  fakebin=$(make_fakebin "$home")
  wt=$(make_task "$home" ship6 codex 'gpt-5.6-sol' xhigh)
  head_before=$(git -C "$wt" rev-parse HEAD)
  printf 'uncommitted\n' > "$wt/dirty.txt"
  dirty_before=$(git -C "$wt" diff HEAD | shasum -a 256 2>/dev/null | awk '{print $1}')
  capture="$home/cap"
  printf 'retrying after rate limit exceeded\n' > "$capture"
  command_file="$home/tmux-command"
  printf 'codex\n' > "$command_file"
  ps_rows="$home/ps"
  printf '1 0 codex --model gpt-5.6-sol\n' > "$ps_rows"
  printf '2 1 claude --model claude-fable-5[1m] --dangerously-skip-permissions\n' >> "$ps_rows"
  FM_FAKE_TMUX_CAPTURE="$capture"
  FM_FAKE_TMUX_PATH="$wt"
  FM_FAKE_TMUX_COMMAND_FILE="$command_file"
  FM_FAKE_TMUX_COMMAND=codex
  FM_FAKE_TMUX_PANE_PID=1
  FM_FAKE_PS_ROWS="$ps_rows"
  FM_FAKE_CLAUDE_AUTH_EXIT=0
  FM_FAKE_CLAUDE_AUTH_OUT='Logged in as test'
  FM_FAKE_CREW_STATE='state: unknown · source: none'
  NM_BRANCH="fm/ship6"
  NM_ID=nm-123
  NM_HEAD="$head_before"
  NM_STATUS=running
  NM_STEP=run_step
  NM_STEP_STATE=running
  out="$home/ship6.out"
  run_failover_to "$out" "$home" ship6 "$fakebin" --reason 'quota hit'
  code=$?
  out_text=$(cat "$out")
  expect_code 0 "$code" "Fable failover should succeed: $out_text"
  assert_contains "$out_text" "failed-over ship6 provider=anthropic" "success result missing"
  assert_contains "$out_text" "harness=claude model=claude-fable-5[1m] effort=high" "Fable route missing"
  assert_grep "harness=claude" "$home/state/ship6.meta" "meta harness not updated"
  assert_grep "model=claude-fable-5[1m]" "$home/state/ship6.meta" "meta model not updated"
  assert_grep "effort=high" "$home/state/ship6.meta" "Fable effort not capped to high"
  head_after=$(git -C "$wt" rev-parse HEAD)
  dirty_after=$(git -C "$wt" diff HEAD | shasum -a 256 2>/dev/null | awk '{print $1}')
  [ "$head_before" = "$head_after" ] || fail "HEAD changed during failover"
  [ "$dirty_before" = "$dirty_after" ] || fail "dirty diff changed during failover"
  [ -n "$(ls "$home/data/ship6/failover"/receipt-* 2>/dev/null)" ] || fail "receipt not written"
  [ -n "$(ls "$home/data/ship6/failover"/resume-* 2>/dev/null)" ] || fail "resume prompt not written"
  assert_present "$home/data/ship6/failover/history" "history not written"
  local receipt resume
  receipt=$(find "$home/data/ship6/failover" -maxdepth 1 -name 'receipt-*' -print | head -1)
  resume=$(find "$home/data/ship6/failover" -maxdepth 1 -name 'resume-*' -print | head -1)
  assert_grep "from=codex:gpt-5.6-sol" "$home/data/ship6/failover/history" "history missing from route"
  assert_grep "to=claude:claude-fable-5[1m]:high" "$home/data/ship6/failover/history" "history missing to route"
  assert_grep "nm_run_id: nm-123" "$receipt" "receipt missing nm run id"
  assert_grep "Existing no-mistakes run: nm-123" "$resume" "resume missing nm run"
  reset_fakes
  pass "full Fable failover preserves identity, caps effort, records receipt/history, and resumes the same nm run"
}

test_fallback_fable_to_kimi_to_glm() {
  local home wt fakebin out code out_text capture command_file ps_rows
  home=$(make_home f2k)
  fakebin=$(make_fakebin "$home")
  wt=$(make_task "$home" ship7 codex 'gpt-5.6-sol' high)
  capture="$home/cap"; printf 'rate limit_exceeded\n' > "$capture"
  command_file="$home/tmux-command"; printf 'codex\n' > "$command_file"
  ps_rows="$home/ps"
  printf '1 0 codex --model gpt-5.6-sol\n' > "$ps_rows"
  printf '2 1 pi --model ollama/kimi-k2.7-code\n' >> "$ps_rows"
  FM_FAKE_TMUX_CAPTURE="$capture"
  FM_FAKE_TMUX_PATH="$wt"
  FM_FAKE_TMUX_COMMAND_FILE="$command_file"
  FM_FAKE_TMUX_COMMAND=codex
  FM_FAKE_TMUX_PANE_PID=1
  FM_FAKE_PS_ROWS="$ps_rows"
  FM_FAKE_CLAUDE_AUTH_EXIT=1
  FM_FAKE_CLAUDE_AUTH_OUT='not logged in'
  FM_FAKE_PI_LIST_ollama_kimi_k2_7_code_EXIT=0
  FM_FAKE_PI_LIST_ollama_kimi_k2_7_code_OUT='ollama/kimi-k2.7-code'
  FM_FAKE_CREW_STATE='state: unknown · source: none'
  out="$home/ship7.out"
  run_failover_to "$out" "$home" ship7 "$fakebin" --reason test
  code=$?
  out_text=$(cat "$out")
  expect_code 0 "$code" "Fable-to-Kimi failover should succeed"
  assert_contains "$out_text" "harness=pi model=ollama/kimi-k2.7-code" "Kimi route missing"
  assert_grep "harness=pi" "$home/state/ship7.meta" "meta harness not updated to pi"
  assert_present "$home/state/.provider-hold-openai" "openai hold missing"

  home=$(make_home k2g)
  fakebin=$(make_fakebin "$home")
  wt=$(make_task "$home" ship8 codex 'gpt-5.6-sol' high)
  capture="$home/cap"; printf 'rate limit_exceeded\n' > "$capture"
  command_file="$home/tmux-command"; printf 'codex\n' > "$command_file"
  ps_rows="$home/ps2"
  printf '1 0 codex --model gpt-5.6-sol\n' > "$ps_rows"
  printf '2 1 pi --model ollama/glm-5.2\n' >> "$ps_rows"
  FM_FAKE_TMUX_CAPTURE="$capture"
  FM_FAKE_TMUX_PATH="$wt"
  FM_FAKE_TMUX_COMMAND_FILE="$command_file"
  FM_FAKE_TMUX_COMMAND=codex
  FM_FAKE_TMUX_PANE_PID=1
  FM_FAKE_PS_ROWS="$ps_rows"
  FM_FAKE_CLAUDE_AUTH_EXIT=1
  FM_FAKE_CLAUDE_AUTH_OUT='connection refused'
  FM_FAKE_PI_LIST_ollama_kimi_k2_7_code_EXIT=1
  FM_FAKE_PI_LIST_ollama_kimi_k2_7_code_OUT='model not available'
  FM_FAKE_PI_LIST_ollama_glm_5_2_EXIT=0
  FM_FAKE_PI_LIST_ollama_glm_5_2_OUT='ollama/glm-5.2'
  FM_FAKE_CREW_STATE='state: unknown · source: none'
  out="$home/ship8.out"
  run_failover_to "$out" "$home" ship8 "$fakebin" --reason test
  code=$?
  out_text=$(cat "$out")
  expect_code 0 "$code" "Kimi-to-GLM failover should succeed: $out_text"
  assert_contains "$out_text" "harness=pi model=ollama/glm-5.2" "GLM route missing"
  reset_fakes
  pass "fallback ladder advances past unavailable candidates to Kimi and then GLM"
}

test_all_candidates_unavailable_leaves_records_intact() {
  local home wt fakebin out code out_text meta_before meta_after capture command_file
  home=$(make_home all-unavail)
  fakebin=$(make_fakebin "$home")
  wt=$(make_task "$home" ship9 codex 'gpt-5.6-sol' high)
  capture="$home/cap"; printf 'insufficient quota\n' > "$capture"
  command_file="$home/tmux-command"; printf 'codex\n' > "$command_file"
  meta_before=$(cat "$home/state/ship9.meta")
  FM_FAKE_TMUX_CAPTURE="$capture"
  FM_FAKE_TMUX_PATH="$wt"
  FM_FAKE_TMUX_COMMAND_FILE="$command_file"
  FM_FAKE_TMUX_COMMAND=codex
  FM_FAKE_CLAUDE_AUTH_EXIT=1
  FM_FAKE_CLAUDE_AUTH_OUT='not authenticated'
  FM_FAKE_PI_LIST_ollama_glm_5_2_EXIT=1
  FM_FAKE_PI_LIST_ollama_glm_5_2_OUT='ollama is not running'
  FM_FAKE_PI_LIST_ollama_kimi_k2_7_code_EXIT=1
  FM_FAKE_PI_LIST_ollama_kimi_k2_7_code_OUT='ollama is not running'
  FM_FAKE_CREW_STATE='state: unknown · source: none'
  out="$home/ship9.out"
  run_failover_to "$out" "$home" ship9 "$fakebin" --reason test
  code=$?
  out_text=$(cat "$out")
  expect_code 4 "$code" "all unavailable should exit 4: $out_text"
  meta_after=$(cat "$home/state/ship9.meta")
  [ "$meta_before" = "$meta_after" ] || fail "metadata changed when every destination unavailable"
  assert_absent "$home/data/ship9/failover/history" "history must not be written on all-unavailable"
  reset_fakes
  pass "all unavailable leaves task and metadata intact"
}

test_inconclusive_probe_stops_failover() {
  local home wt fakebin out code out_text capture command_file
  home=$(make_home inconclusive)
  fakebin=$(make_fakebin "$home")
  wt=$(make_task "$home" ship10 codex 'gpt-5.6-sol' high)
  capture="$home/cap"; printf 'rate limit_exceeded\n' > "$capture"
  command_file="$home/tmux-command"; printf 'codex\n' > "$command_file"
  FM_FAKE_TMUX_CAPTURE="$capture"
  FM_FAKE_TMUX_PATH="$wt"
  FM_FAKE_TMUX_COMMAND_FILE="$command_file"
  FM_FAKE_TMUX_COMMAND=codex
  FM_FAKE_CLAUDE_AUTH_EXIT=1
  FM_FAKE_CLAUDE_AUTH_OUT='segmentation fault'
  FM_FAKE_PI_LIST_ollama_glm_5_2_EXIT=1
  FM_FAKE_PI_LIST_ollama_glm_5_2_OUT='segmentation fault'
  FM_FAKE_PI_LIST_ollama_kimi_k2_7_code_EXIT=1
  FM_FAKE_PI_LIST_ollama_kimi_k2_7_code_OUT='segmentation fault'
  FM_FAKE_CREW_STATE='state: unknown · source: none'
  out="$home/ship10.out"
  run_failover_to "$out" "$home" ship10 "$fakebin" --reason test
  code=$?
  out_text=$(cat "$out")
  expect_code 1 "$code" "inconclusive probe should stop failover"
  assert_contains "$out_text" "inconclusive" "inconclusive message missing"
  reset_fakes
  pass "inconclusive probe stops failover instead of advancing"
}

test_failed_live_verification_leaves_meta_unchanged() {
  local home wt fakebin out code out_text meta_before meta_after ps_rows capture command_file
  home=$(make_home live-fail)
  fakebin=$(make_fakebin "$home")
  wt=$(make_task "$home" ship11 codex 'gpt-5.6-sol' high)
  capture="$home/cap"; printf 'quota exceeded\n' > "$capture"
  command_file="$home/tmux-command"; printf 'codex\n' > "$command_file"
  ps_rows="$home/ps"
  printf '1 0 codex --model gpt-5.6-sol\n' > "$ps_rows"
  meta_before=$(cat "$home/state/ship11.meta")
  FM_FAKE_TMUX_CAPTURE="$capture"
  FM_FAKE_TMUX_PATH="$wt"
  FM_FAKE_TMUX_COMMAND_FILE="$command_file"
  FM_FAKE_TMUX_COMMAND=codex
  FM_FAKE_TMUX_PANE_PID=1
  FM_FAKE_PS_ROWS="$ps_rows"
  FM_FAKE_CLAUDE_AUTH_EXIT=0
  FM_FAKE_CLAUDE_AUTH_OUT='ok'
  FM_FAKE_CREW_STATE='state: unknown · source: none'
  out="$home/ship11.out"
  run_failover_to "$out" "$home" ship11 "$fakebin" --reason test
  code=$?
  out_text=$(cat "$out")
  expect_code 5 "$code" "failed live verification should exit 5"
  meta_after=$(cat "$home/state/ship11.meta")
  [ "$meta_before" = "$meta_after" ] || fail "metadata changed after failed live verification"
  reset_fakes
  pass "failed live verification leaves metadata unchanged"
}

test_nested_pipeline_agent_blocks_exit() {
  local home wt fakebin out code out_text ps_rows capture command_file
  home=$(make_home nested)
  fakebin=$(make_fakebin "$home")
  wt=$(make_task "$home" ship12 codex 'gpt-5.6-sol' high)
  capture="$home/cap"; printf 'usage limit\n' > "$capture"
  command_file="$home/tmux-command"; printf 'codex\n' > "$command_file"
  ps_rows="$home/ps"
  printf '1 0 codex --model gpt-5.6-sol\n' > "$ps_rows"
  printf '2 1 codex exec resume --model gpt-5.5\n' >> "$ps_rows"
  FM_FAKE_TMUX_CAPTURE="$capture"
  FM_FAKE_TMUX_PATH="$wt"
  FM_FAKE_TMUX_COMMAND_FILE="$command_file"
  FM_FAKE_TMUX_COMMAND=codex
  FM_FAKE_TMUX_PANE_PID=1
  FM_FAKE_PS_ROWS="$ps_rows"
  FM_FAKE_CLAUDE_AUTH_EXIT=0
  FM_FAKE_CLAUDE_AUTH_OUT='ok'
  FM_FAKE_CREW_STATE='state: unknown · source: none'
  out="$home/ship12.out"
  run_failover_to "$out" "$home" ship12 "$fakebin" --check-only
  code=$?
  out_text=$(cat "$out")
  expect_code 0 "$code" "check-only with nested agent should be eligible"
  assert_contains "$out_text" "nested_agents=codex:gpt-5.5" "nested agent summary missing"
  out="$home/ship12b.out"
  run_failover_to "$out" "$home" ship12 "$fakebin" --reason test
  code=$?
  out_text=$(cat "$out")
  expect_code 1 "$code" "failover must refuse to interrupt nested agent"
  assert_contains "$out_text" "live pipeline-owned agent subprocess" "nested block message missing"
  reset_fakes
  pass "nested pipeline-owned agent is reported and blocks outer exit"
}

test_repeat_run_is_idempotent() {
  local home wt fakebin out code out_text
  home=$(make_home repeat)
  fakebin=$(make_fakebin "$home")
  wt=$(make_task "$home" ship13 claude 'claude-fable-5[1m]' high)
  out="$home/ship13.out"
  run_failover_to "$out" "$home" ship13 "$fakebin" --reason test
  code=$?
  out_text=$(cat "$out")
  expect_code 0 "$code" "repeat run on non-OpenAI route should exit 0"
  assert_contains "$out_text" "no-op: task ship13" "no-op message missing on repeat"
  pass "re-running failover after a switch is a no-op"
}

test_non_openai_route_is_noop
test_secondmate_refused
test_healthy_worker_refused
test_parked_wedge_refused
test_outage_evidence_eligible_and_sets_hold
test_dead_agent_eligible
test_full_fable_failover_preserves_state
test_fallback_fable_to_kimi_to_glm
test_all_candidates_unavailable_leaves_records_intact
test_inconclusive_probe_stops_failover
test_failed_live_verification_leaves_meta_unchanged
test_nested_pipeline_agent_blocks_exit
test_repeat_run_is_idempotent

# --- provider-hold lifecycle ------------------------------------------------

test_provider_hold_lifecycle() {
  local home fakebin out code out_text
  home=$(make_home holds)
  fakebin=$(make_fakebin "$home")
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_ROOT_OVERRIDE="$FAKE_ROOT" PATH="$fakebin:$BASE_PATH" \
    "$ROOT/bin/fm-provider-hold.sh" list 2>&1)
  assert_contains "$out" "no active provider holds" "empty hold list missing"

  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_ROOT_OVERRIDE="$FAKE_ROOT" PATH="$fakebin:$BASE_PATH" \
    "$ROOT/bin/fm-provider-hold.sh" set openai --task t1 --evidence 'quota' >/dev/null
  assert_present "$home/state/.provider-hold-openai" "hold file not created"

  FM_FAKE_CODEX_LOGIN_EXIT=1
  FM_FAKE_CODEX_LOGIN_OUT='not logged in'
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_ROOT_OVERRIDE="$FAKE_ROOT" PATH="$fakebin:$BASE_PATH" \
    "$ROOT/bin/fm-provider-hold.sh" release openai 2>&1); code=$?
  expect_code 1 "$code" "release with failed probe should keep hold"
  assert_present "$home/state/.provider-hold-openai" "hold removed after failed probe"

  FM_FAKE_CODEX_LOGIN_EXIT=0
  FM_FAKE_CODEX_LOGIN_OUT='Logged in'
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_ROOT_OVERRIDE="$FAKE_ROOT" PATH="$fakebin:$BASE_PATH" \
    "$ROOT/bin/fm-provider-hold.sh" release openai 2>&1); code=$?
  expect_code 0 "$code" "release with successful probe should clear hold"
  assert_absent "$home/state/.provider-hold-openai" "hold still present after release"
  assert_present "$home/state/.provider-usage-openai" "ready receipt not recorded on release"
  reset_fakes
  pass "provider-hold set/release honors probe results and records ready receipt"
}

test_provider_hold_lifecycle

# --- spawn/dispatch/usage integration ---------------------------------------

test_spawn_refuses_held_provider_and_warns_on_pressure() {
  local home fakebin wt out code out_text
  home=$(make_home spawn-hold)
  fakebin=$(make_fakebin "$home")
  wt=$(make_task "$home" ship14 codex 'gpt-5.6-sol' high)
  touch "$home/state/.provider-hold-openai"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_ROOT_OVERRIDE="$FAKE_ROOT" PATH="$fakebin:$BASE_PATH" \
    "$ROOT/bin/fm-spawn.sh" ship14 "$wt" --harness codex --model gpt-5.6-sol 2>&1); code=$?
  expect_code 1 "$code" "spawn should refuse held provider"
  assert_contains "$out" "provider openai is held" "hold refusal message missing"

  rm -f "$home/state/.provider-hold-openai"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-provider-usage.sh" record openai --session-pct 90 --week-pct 95 >/dev/null
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_ROOT_OVERRIDE="$FAKE_ROOT" PATH="$fakebin:$BASE_PATH" \
    "$ROOT/bin/fm-spawn.sh" ship14 "$wt" --harness codex --model gpt-5.6-sol 2>&1); code=$?
  expect_code 1 "$code" "spawn should still exit (no brief)"
  assert_contains "$out" "advisory quota pressure" "advisory pressure warning missing"
  assert_not_contains "$out" "refusing this NEW launch" "spawn hard-blocked on advisory pressure"
  pass "spawn refuses held providers and warns on advisory pressure"
}

test_dispatch_select_excludes_held_candidates() {
  local home fakebin out err code out_text
  home=$(make_home dispatch)
  fakebin=$(make_fakebin "$home")
  touch "$home/state/.provider-hold-openai"
  err=$(mktemp)
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$FAKE_ROOT" \
    PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-dispatch-select.sh" \
    '[{"harness":"codex","model":"gpt-5.6-sol"},{"harness":"claude","model":"claude-fable-5[1m]"}]' 2>"$err"); code=$?
  expect_code 0 "$code" "dispatch should select remaining candidate"
  [ "$out" = '{"harness":"claude","model":"claude-fable-5[1m]"}' ] || fail "did not fall back to claude: stdout=$out stderr=$(cat "$err")"
  assert_contains "$(cat "$err")" "provider openai held" "exclusion log missing"

  touch "$home/state/.provider-hold-anthropic"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$FAKE_ROOT" \
    PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-dispatch-select.sh" \
    '[{"harness":"codex","model":"gpt-5.6-sol"},{"harness":"claude","model":"claude-fable-5[1m]"}]' 2>"$err"); code=$?
  expect_code 3 "$code" "all held should exit 3"
  assert_contains "$out" 'all-candidates-excluded' "structured exclusion missing"
  rm -f "$err"
  pass "dispatch-select excludes held candidates and returns structured all-excluded"
}

test_usage_refresh_records_advisory_not_ready() {
  local home fakebin out code out_text
  home=$(make_home usage)
  fakebin=$(make_fakebin "$home")
  FM_FAKE_QUOTA_AXI_OUT='{"providers":[{"provider":"claude","state":{"stale":false},"windows":[{"kind":"session","id":"five_hour","percentUsed":55},{"kind":"weekly","id":"seven_day","percentUsed":40}]},{"provider":"codex","state":{"stale":true},"windows":[]}]}'
  FM_FAKE_QUOTA_AXI_EXIT=0
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_ROOT_OVERRIDE="$FAKE_ROOT" PATH="$fakebin:$BASE_PATH" \
    "$ROOT/bin/fm-provider-usage.sh" refresh 2>&1); code=$?
  expect_code 0 "$code" "refresh should succeed"
  assert_present "$home/state/.provider-usage-anthropic" "anthropic advisory snapshot missing"
  assert_absent "$home/state/.provider-usage-openai" "stale codex snapshot should not be recorded"
  assert_grep "source=quota-axi-advisory" "$home/state/.provider-usage-anthropic" "source not advisory"
  assert_grep "status=advisory" "$home/state/.provider-usage-anthropic" "status not advisory"
  assert_grep "session_pct=55" "$home/state/.provider-usage-anthropic" "session_pct missing"
  [ "$(fm_failover_provider_readiness "$home/state" anthropic)" = "unknown anthropic no fresh readiness receipt" ] || fail "advisory snapshot should not count as ready"
  reset_fakes
  pass "usage refresh records advisory snapshots, skips stale, and does not claim ready"
}

test_dispatch_select_excludes_pressure_candidates() {
  local home fakebin out err code
  home=$(make_home dispatch-pressure)
  fakebin=$(make_fakebin "$home")
  err=$(mktemp)
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-provider-usage.sh" record openai --week-pct 55 >/dev/null
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$FAKE_ROOT" \
    PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-dispatch-select.sh" \
    '[{"harness":"codex","model":"gpt-5.6-sol"},{"harness":"claude","model":"claude-fable-5[1m]"}]' 2>"$err"); code=$?
  expect_code 0 "$code" "dispatch should skip pressure-excluded openai"
  [ "$out" = '{"harness":"claude","model":"claude-fable-5[1m]"}' ] || fail "did not fall back to claude under openai weekly pressure: stdout=$out stderr=$(cat "$err")"
  assert_contains "$(cat "$err")" "provider openai pressure: avoid" "pressure exclusion log missing"
  rm -f "$err"
  pass "dispatch-select excludes openai at the provider-specific weekly avoid floor"
}

test_spawn_refuses_held_provider_and_warns_on_pressure
test_dispatch_select_excludes_held_candidates
test_dispatch_select_excludes_pressure_candidates
test_usage_refresh_records_advisory_not_ready

# --- planned handoff --------------------------------------------------------

test_planned_handoff_defer_and_skip_unknown() {
  local home wt fakebin out code out_text capture command_file ps_rows
  home=$(make_home planned-defer)
  fakebin=$(make_fakebin "$home")
  wt=$(make_task "$home" ship15 codex 'gpt-5.6-sol' high)
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-provider-usage.sh" record openai --session-pct 90 >/dev/null
  capture="$home/cap"; printf 'idle\n' > "$capture"
  command_file="$home/tmux-command"; printf 'codex\n' > "$command_file"
  FM_FAKE_TMUX_CAPTURE="$capture"
  FM_FAKE_TMUX_PATH="$wt"
  FM_FAKE_TMUX_COMMAND_FILE="$command_file"
  FM_FAKE_TMUX_COMMAND=codex
  FM_FAKE_CREW_STATE='state: working · source: run-step · validating'
  out="$home/ship15.out"
  run_failover_to "$out" "$home" ship15 "$fakebin" --planned --reason 'handoff review'
  code=$?
  out_text=$(cat "$out")
  expect_code 6 "$code" "planned handoff on busy worker should defer"
  assert_contains "$out_text" "not at a safe checkpoint" "defer message missing"

  fm_write_meta "$(fm_failover_usage_path "$home/state" anthropic)" \
    "recorded_at=$(date +%s)" "status=ready" "source=test"
  ps_rows="$home/ps"
  printf '1 0 codex --model gpt-5.6-sol\n' > "$ps_rows"
  printf '2 1 claude --model claude-fable-5[1m]\n' >> "$ps_rows"
  FM_FAKE_TMUX_PANE_PID=1
  FM_FAKE_PS_ROWS="$ps_rows"
  FM_FAKE_CLAUDE_AUTH_EXIT=0
  FM_FAKE_CLAUDE_AUTH_OUT='ok'
  FM_FAKE_CREW_STATE='state: unknown · source: none'
  out="$home/ship15b.out"
  run_failover_to "$out" "$home" ship15 "$fakebin" --planned --reason 'handoff review'
  code=$?
  out_text=$(cat "$out")
  expect_code 0 "$code" "planned handoff at safe checkpoint should succeed"
  assert_contains "$out_text" "harness=claude" "planned handoff did not switch to confirmed ready destination"
  reset_fakes
  pass "planned handoff defers on busy pane and proceeds to a ready destination at idle"
}

test_planned_handoff_defer_and_skip_unknown

echo "# all fm-failover tests passed"
