#!/usr/bin/env bash
# Behavioral tests for the thin TraeX ordinary worker/scout adapter.
# The public spawn/send/backend interfaces run against a stateful fake Herdr;
# no test reads implementation source as a proxy for behavior.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
SEND="$ROOT/bin/fm-send.sh"
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
input=${FM_FAKE_INPUT_LOG:?}
keys=${FM_FAKE_KEY_LOG:?}
phase_file=${FM_FAKE_PHASE_FILE:?}
trust_count=${FM_FAKE_TRUST_COUNT:?}
project=${FM_FAKE_PROJECT:?}
worktree=${FM_FAKE_WORKTREE:?}

printf '%s' "${HERDR_SESSION:-}" >> "$log"
for arg in "$@"; do printf '\x1f%s' "$arg" >> "$log"; done
printf '\n' >> "$log"
phase=$(cat "$phase_file" 2>/dev/null || printf shell)
case "${1:-} ${2:-}" in
  "status --json")
    printf '%s\n' '{"client":{"version":"0.8.0","protocol":19},"server":{"running":true,"version":"0.8.0","protocol":19}}'
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
    if [ "${3:-}" = w1:p2 ] && [ "${4:-}" = 'treehouse get' ]; then
      printf '%s\n' "$worktree" > "${FM_FAKE_CWD_FILE:?}"
    fi
    ;;
  "pane get")
    pane=${3:-}
    cwd=$(cat "${FM_FAKE_CWD_FILE:?}" 2>/dev/null || printf '%s' "$project")
    printf '{"result":{"pane":{"pane_id":"%s","tab_id":"w1:t2","workspace_id":"w1","cwd":"%s","foreground_cwd":"%s"}}}\n' "$pane" "$project" "$cwd"
    ;;
  "pane send-text")
    if [ "$phase" = shell ]; then
      printf '%s\n' "${4:-}" >> "$launch"
    else
      printf '%s\n' "${4:-}" >> "$input"
    fi
    ;;
  "pane send-keys")
    key=${4:-}
    printf '%s\n' "$key" >> "$keys"
    case "$key:$phase" in
      enter:shell) printf blocked > "$phase_file" ;;
      enter:blocked)
        n=$(cat "$trust_count" 2>/dev/null || printf 0)
        printf '%s\n' "$((n + 1))" > "$trust_count"
        printf '%s' "${FM_FAKE_AFTER_TRUST:-working}" > "$phase_file"
        ;;
      enter:idle) printf working > "$phase_file" ;;
      escape:working) printf idle > "$phase_file" ;;
    esac
    ;;
  "pane read")
    cat <<'EOF'
> You are in the isolated task copy

  Do you trust the contents of this directory?

❯ 1. Yes, continue
  2. No, quit

  Press enter to continue
EOF
    ;;
  "agent get")
    case "$phase" in
      blocked|working|idle|done)
        printf '{"result":{"agent":{"agent":"traex","agent_status":"%s","cwd":"%s","foreground_cwd":"%s","pane_id":"w1:p2"}}}\n' \
          "$phase" "${FM_FAKE_AGENT_CWD:-$project}" "$worktree"
        ;;
      *) printf '%s\n' '{"error":{"code":"agent_not_found"}}' ;;
    esac
    ;;
  "agent explain")
    if [ "${FM_FAKE_TRUST_RULE:-exact}" = exact ]; then
      rule='directory_trust_prompt (region=whole_recent priority=1000)'
    else
      rule='unrelated_blocker (region=whole_recent priority=1000)'
    fi
    printf 'agent: traex\nstate: blocked\nrule: %s\n' "$rule"
    ;;
  *) ;;
esac
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
  : > "$dir/input.log"
  : > "$dir/key.log"
  printf shell > "$dir/phase"
  printf '%s\n' "$dir|$home|$project|$wt|$fakebin|$id"
}

read_spawn_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJECT_DIR WT_DIR FAKEBIN_DIR TASK_ID <<EOF
$1
EOF
}

traex_env() {
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 HERDR_SESSION=traex-test-session \
    FM_FAKE_HERDR_STATE="$CASE_DIR/herdr.state" FM_FAKE_HERDR_LOG="$CASE_DIR/herdr.log" \
    FM_FAKE_LAUNCH_LOG="$CASE_DIR/launch.log" FM_FAKE_INPUT_LOG="$CASE_DIR/input.log" \
    FM_FAKE_KEY_LOG="$CASE_DIR/key.log" FM_FAKE_PHASE_FILE="$CASE_DIR/phase" \
    FM_FAKE_TRUST_COUNT="$CASE_DIR/trust-count" FM_FAKE_CWD_FILE="$CASE_DIR/cwd" \
    FM_FAKE_PROJECT="$PROJECT_DIR" FM_FAKE_WORKTREE="$WT_DIR" \
    PATH="$FAKEBIN_DIR:$PATH" "$@"
}

run_traex_spawn() {
  traex_env env -u HERDR_PANE_ID -u HERDR_SOCKET_PATH -u HERDR_ENV \
    -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
    "$SPAWN" "$TASK_ID" "$PROJECT_DIR" --harness traex --backend herdr \
      --model Doubao-Seed-2.1-Pro --effort high --mode no-mistakes --yolo off 2>&1
}

run_traex_send() {
  touch "$HOME_DIR/state/.last-watcher-beat"
  traex_env "$SEND" "$TASK_ID" "$@" 2>&1
}

assert_no_custom_lifecycle() {
  local meta="$HOME_DIR/state/$TASK_ID.meta"
  assert_no_grep '^traex_ready=' "$meta" "thin adapter wrote TraeX readiness state"
  assert_no_grep '^traex_session_id=' "$meta" "thin adapter wrote a native-session lifecycle binding"
  assert_absent "$HOME_DIR/state/$TASK_ID.busy-gen" "thin adapter armed a custom busy-state writer"
  assert_absent "$HOME_DIR/state/.traex-herdr-bindings" "thin adapter created a binding index"
}

test_marker_detection_is_scoped() {
  local out dir
  out=$(FM_TRAEX_HARNESS=traex CLAUDECODE=1 "$HARNESS")
  [ "$out" = traex ] || fail "TraeX marker did not win detection, got '$out'"
  dir="$TMP_ROOT/detect"
  mkdir -p "$dir"
  cp "$(command -v bash)" "$dir/traex"
  out=$(env -u FM_TRAEX_HARNESS -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT \
    "$dir/traex" -c "r=\$(\"$HARNESS\"); printf '%s' \"\$r\"")
  [ "$out" != traex ] || fail "unrelated TraeX ancestry was misclassified"
  pass "traex detection requires the exact Firstmate launch marker"
}

test_spawn_trust_and_generic_lifecycle() {
  local rec out status launch verdict
  rec=$(make_spawn_case launch)
  read_spawn_case "$rec"
  out=$(run_traex_spawn)
  status=$?
  expect_code 0 "$status" "TraeX Herdr spawn should succeed: $out"
  assert_contains "$out" "spawned $TASK_ID harness=traex kind=ship" "spawn omitted TraeX identity"
  [ "$(cat "$CASE_DIR/trust-count")" = 1 ] || fail "trust chooser was not accepted exactly once"
  [ "$(cat "$CASE_DIR/phase")" = working ] || fail "spawn returned before native working"
  launch=$(cat "$CASE_DIR/launch.log")
  [ "$(grep -c . "$CASE_DIR/launch.log")" = 1 ] || fail "launch brief was injected more than once"
  assert_contains "$launch" 'FM_TRAEX_HARNESS=traex traex -y' "launch omitted scoped identity/autonomy"
  assert_contains "$launch" "--model 'Doubao-Seed-2.1-Pro'" "launch omitted model"
  assert_contains "$launch" "-c 'model_reasoning_effort=\"high\"'" "launch omitted effort"
  assert_contains "$launch" 'encode launch-brief' "launch omitted positional brief"
  assert_grep 'backend=herdr' "$HOME_DIR/state/$TASK_ID.meta" "metadata omitted Herdr"
  assert_grep 'harness=traex' "$HOME_DIR/state/$TASK_ID.meta" "metadata omitted TraeX"
  assert_no_custom_lifecycle
  # shellcheck source=bin/fm-backend.sh
  . "$ROOT/bin/fm-backend.sh"
  verdict=$(traex_env fm_backend_busy_state herdr traex-test-session:w1:p2)
  [ "$verdict" = busy ] || fail "generic Herdr current-state observation returned '$verdict'"
  pass "traex spawn uses exact trust and generic Herdr lifecycle state"
}

test_trust_refusals() {
  local rec out status other
  rec=$(make_spawn_case wrong-cwd)
  read_spawn_case "$rec"
  other="$CASE_DIR/unrelated"
  mkdir -p "$other"
  out=$(FM_FAKE_AGENT_CWD="$other" FM_BACKEND_HERDR_TRAEX_START_POLLS=3 \
    FM_BACKEND_HERDR_TRAEX_START_INTERVAL=0 run_traex_spawn)
  status=$?
  [ "$status" -ne 0 ] || fail "mismatched trust provenance succeeded"
  assert_absent "$CASE_DIR/trust-count" "mismatched provenance received Enter"

  rec=$(make_spawn_case wrong-dialog)
  read_spawn_case "$rec"
  out=$(FM_FAKE_TRUST_RULE=wrong FM_BACKEND_HERDR_TRAEX_START_POLLS=3 \
    FM_BACKEND_HERDR_TRAEX_START_INTERVAL=0 run_traex_spawn)
  status=$?
  [ "$status" -ne 0 ] || fail "unrecognized blocker was accepted"
  assert_contains "$out" 'exact TraeX directory-trust chooser' "wrong blocker diagnostic was unclear"
  assert_absent "$CASE_DIR/trust-count" "unrecognized blocker received Enter"

  rec=$(make_spawn_case no-working)
  read_spawn_case "$rec"
  out=$(FM_FAKE_AFTER_TRUST=idle FM_BACKEND_HERDR_TRAEX_START_POLLS=3 \
    FM_BACKEND_HERDR_TRAEX_START_INTERVAL=0 run_traex_spawn)
  status=$?
  [ "$status" -ne 0 ] || fail "trust transport was mistaken for working"
  [ "$(cat "$CASE_DIR/trust-count")" = 1 ] || fail "verified chooser was not submitted once"
  assert_not_contains "$out" "spawned $TASK_ID" "spawn reported success without native working"
  pass "traex trust refuses mismatched evidence and requires native working"
}

test_scope_refuses_before_endpoint() {
  local rec out status sm
  rec=$(make_spawn_case scope)
  read_spawn_case "$rec"
  out=$(traex_env "$SPAWN" "$TASK_ID" "$PROJECT_DIR" --harness traex --backend herdr \
    --effort max --mode no-mistakes --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "TraeX max effort succeeded"
  assert_contains "$out" 'max is not verified and is refused' "max refusal was unclear"
  [ ! -s "$CASE_DIR/herdr.log" ] || fail "max refusal reached Herdr"

  cat > "$FAKEBIN_DIR/tmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_FAKE_TMUX_LOG:?}"
SH
  chmod +x "$FAKEBIN_DIR/tmux"
  : > "$CASE_DIR/tmux.log"
  out=$(FM_FAKE_TMUX_LOG="$CASE_DIR/tmux.log" TMUX='fake,1,0' traex_env \
    "$SPAWN" "$TASK_ID" "$PROJECT_DIR" --harness traex --backend tmux \
      --mode no-mistakes --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "TraeX tmux spawn succeeded"
  [ ! -s "$CASE_DIR/tmux.log" ] || fail "unsupported backend created an endpoint"

  sm="$CASE_DIR/secondmate"
  mkdir -p "$sm/data" "$sm/bin"
  printf '# Firstmate\n' > "$sm/AGENTS.md"
  printf '%s\n' "$TASK_ID" > "$sm/.fm-secondmate-home"
  printf 'charter\n' > "$sm/data/charter.md"
  out=$(traex_env "$SPAWN" "$TASK_ID" "$sm" --harness traex --backend herdr --secondmate 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "TraeX secondmate succeeded"
  assert_contains "$out" 'crewmate/scout adapter only' "role refusal was unclear"
  pass "traex refuses max effort, non-Herdr backends, and secondmate scope before endpoint creation"
}

test_raw_traex_refuses_without_breaking_other_raw_launches() {
  local rec out status raw_id
  rec=$(make_spawn_case raw)
  read_spawn_case "$rec"
  out=$(traex_env "$SPAWN" "$TASK_ID" "$PROJECT_DIR" \
    "sh -c 'traex -y arbitrary'" --backend herdr --mode no-mistakes --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "shell-wrapped raw TraeX command succeeded"
  assert_contains "$out" 'verified launch template' "raw TraeX refusal was unclear"
  [ ! -s "$CASE_DIR/herdr.log" ] || fail "raw TraeX refusal reached Herdr"

  raw_id='raw-other'
  mkdir -p "$HOME_DIR/data/$raw_id"
  printf 'raw brief\n' > "$HOME_DIR/data/$raw_id/brief.md"
  out=$(traex_env env -u HERDR_PANE_ID -u HERDR_SOCKET_PATH -u HERDR_ENV \
    -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
    "$SPAWN" "$raw_id" "$PROJECT_DIR" "bash -lc 'printf ok'" \
      --backend herdr --mode no-mistakes --yolo off 2>&1)
  status=$?
  expect_code 0 "$status" "ordinary raw launch regressed: $out"
  pass "raw TraeX is refused while general raw execution remains supported"
}

test_generic_steer_interrupt_and_keys() {
  local rec out status verdict
  rec=$(make_spawn_case controls)
  read_spawn_case "$rec"
  run_traex_spawn >/dev/null || fail "control fixture spawn failed"
  printf idle > "$CASE_DIR/phase"
  out=$(run_traex_send 'reply with exactly STEER_OK')
  status=$?
  expect_code 0 "$status" "generic TraeX steer failed: $out"
  assert_grep 'reply with exactly STEER_OK' "$CASE_DIR/input.log" "steer text never reached Herdr"
  assert_grep enter "$CASE_DIR/key.log" "steer Enter never reached Herdr"
  [ "$(cat "$CASE_DIR/phase")" = working ] || fail "steer was not observed working"

  # shellcheck source=bin/fm-backend.sh
  . "$ROOT/bin/fm-backend.sh"
  verdict=$(traex_env fm_backend_busy_state herdr traex-test-session:w1:p2)
  [ "$verdict" = busy ] || fail "generic busy observation returned '$verdict'"
  out=$(run_traex_send --key Escape)
  status=$?
  expect_code 0 "$status" "generic TraeX interrupt failed: $out"
  assert_grep escape "$CASE_DIR/key.log" "Escape never reached Herdr"
  assert_grep ctrl+u "$CASE_DIR/key.log" "restored TraeX input was not cleared generically"
  out=$(run_traex_send --key C-c)
  status=$?
  expect_code 0 "$status" "generic TraeX key path failed: $out"
  assert_grep ctrl+c "$CASE_DIR/key.log" "C-c never reached Herdr"
  pass "traex steering, interrupt clearing, keys, and current state use generic Herdr owners"
}

test_marker_detection_is_scoped
test_spawn_trust_and_generic_lifecycle
test_trust_refusals
test_scope_refuses_before_endpoint
test_raw_traex_refuses_without_breaking_other_raw_launches
test_generic_steer_interrupt_and_keys

echo '# all thin TraeX harness tests passed'
