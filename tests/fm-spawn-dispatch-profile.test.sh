#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh concrete dispatch profile flags.
#
# These tests drive fm-spawn through meta writing and launch construction with a
# fake tmux pane and a real isolated git worktree. The fake tmux captures the
# literal launch command sent with `tmux send-keys -l`, so assertions pin the
# command firstmate would run without starting any real harness.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-dispatch-profile)
REAL_PERL=$(command -v perl)
export FM_TEST_REAL_PERL="$REAL_PERL"

test_sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

test_sha256_text() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    sha256sum | awk '{print $1}'
  fi
}

make_spawn_pi_probe() {
  local fakebin=$1 tool=$2
  cat > "$fakebin/$tool" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = --help ]; then
  if [ "${FM_FAKE_PI_VERSION:-0.84.0}" = 0.82.0 ]; then
    printf '%s\n' 'Pi 0.82.0' 'Options: --help'
  else
    printf '%s\n' "Pi ${FM_FAKE_PI_VERSION:-0.84.0}" 'Options: --help --tui-mode <mode>'
  fi
fi
exit 0
SH
  chmod +x "$fakebin/$tool"
}

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  new-window)
    [ -z "${FM_FAKE_ENDPOINT_LOG:-}" ] || printf 'new-window\n' >> "$FM_FAKE_ENDPOINT_LOG"
    exit 0
    ;;
  has-session|new-session|kill-window) exit 0 ;;
  send-keys)
    shift
    literal=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *)
          if [ "$literal" -eq 1 ]; then
            [ -z "${FM_FAKE_LAUNCH_LOG:-}" ] || printf '%s\n' "$1" >> "$FM_FAKE_LAUNCH_LOG"
          else
            [ -z "${FM_FAKE_TEXT_LOG:-}" ] || printf '%s\n' "$1" >> "$FM_FAKE_TEXT_LOG"
          fi
          break
          ;;
      esac
    done
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
[ -z "${FM_FAKE_WORKTREE_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_FAKE_WORKTREE_LOG"
exit 0
SH
  cat > "$fakebin/timeout" <<'SH'
#!/usr/bin/env bash
shift
exec "$@"
SH
  cat > "$fakebin/cp" <<'SH'
#!/usr/bin/env bash
set -u
/bin/cp "$@" || exit 1
if [ -n "${FM_TEST_MUTATE_BRIEF_SOURCE:-}" ] \
  && [ "${1:-}" = "$FM_TEST_MUTATE_BRIEF_SOURCE" ]; then
  case "${2:-}" in
    */.routing-decision.validate.*/data/*/brief.md)
      printf '%s\n' "${FM_TEST_BRIEF_REPLACEMENT:-replacement brief bytes}" > "$FM_TEST_MUTATE_BRIEF_SOURCE"
      ;;
  esac
fi
SH
  cat > "$fakebin/chmod" <<'SH'
#!/usr/bin/env bash
set -u
/bin/chmod "$@" || exit 1
target=
for target in "$@"; do :; done
if [ -n "${FM_TEST_REPLACE_BRIEF_TARGET:-}" ] \
  && [ "$target" = "$FM_TEST_REPLACE_BRIEF_TARGET" ]; then
  rm -f -- "$target"
  printf '%s\n' "${FM_TEST_BRIEF_TARGET_REPLACEMENT:-replacement target bytes}" > "$target"
fi
SH
  cat > "$fakebin/perl" <<'SH'
#!/usr/bin/env bash
set -u
target=${!#}
result=
receipt_target=
if [ "${2:-}" = publish ]; then
  receipt_target="$3/routing-generation.$target/receipt.json"
fi
for candidate in "$@"; do
  case "$candidate" in
    */routing-decision.*.json)
      case "$candidate" in
        */routing-decision.pending.json) ;;
        *) receipt_target=$candidate ;;
      esac
      ;;
  esac
done
if [ -n "${FM_TEST_FAIL_RECEIPT_LINK_MARKER:-}" ]; then
  case "$receipt_target" in
    ?*)
      if [ ! -e "$FM_TEST_FAIL_RECEIPT_LINK_MARKER" ]; then
        : > "$FM_TEST_FAIL_RECEIPT_LINK_MARKER"
        exit 1
      fi
      ;;
  esac
fi
result=$("$FM_TEST_REAL_PERL" "$@")
status=$?
[ -z "$result" ] || printf '%s\n' "$result"
if [ "$status" -eq 0 ] \
  && [ "${2:-}" = snapshot ] \
  && [ -n "${FM_TEST_MUTATE_BRIEF_SOURCE:-}" ]; then
  printf '%s\n' "${FM_TEST_BRIEF_REPLACEMENT:-replacement brief bytes}" > "$FM_TEST_MUTATE_BRIEF_SOURCE"
fi
if [ "$status" -eq 0 ] \
  && [ "${2:-}" = snapshot ] \
  && [ -n "${FM_TEST_MUTATE_SNAPSHOT_BRIEF:-}" ]; then
  snapshot_name=${result%%$'\t'*}
  rm -f -- "$3/$snapshot_name/data/$5/brief.md"
  printf '%s\n' "${FM_TEST_BRIEF_TARGET_REPLACEMENT:-replacement target bytes}" > "$3/$snapshot_name/data/$5/brief.md"
  [ -z "${FM_TEST_SNAPSHOT_BRIEF_MARKER:-}" ] || : > "$FM_TEST_SNAPSHOT_BRIEF_MARKER"
fi
exit "$status"
SH
  cat > "$fakebin/claude" <<'SH'
#!/usr/bin/env bash
[ -z "${FM_FAKE_HARNESS_EXEC_LOG:-}" ] || printf 'claude-executed\n' >> "$FM_FAKE_HARNESS_EXEC_LOG"
if [ -n "${FM_FAKE_HARNESS_INPUT_LOG:-}" ]; then
  last=
  for last in "$@"; do :; done
  printf '%s' "$last" > "$FM_FAKE_HARNESS_INPUT_LOG"
fi
exit 0
SH
  cat > "$fakebin/muse" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fakebin/cursor-agent" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --list-models ]; then
  [ "${FM_FAKE_CURSOR_LIST_STATUS:-0}" -eq 0 ] || exit "${FM_FAKE_CURSOR_LIST_STATUS}"
  printf '%b\n' "${FM_FAKE_CURSOR_MODELS:-Available models\ncursor-grok-4.5-high - Grok 4.5 High}"
fi
exit 0
SH
  chmod +x "$fakebin/timeout" "$fakebin/cp" "$fakebin/chmod" "$fakebin/perl" "$fakebin/claude" "$fakebin/muse" "$fakebin/cursor-agent" "$fakebin/treehouse"
  make_spawn_pi_probe "$fakebin" pi
  make_spawn_pi_probe "$fakebin" pi-signed
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 harness=$2 case_dir home proj wt fakebin launchlog id
  shift 2
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf '%s\n' "$harness" > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  for id in "$@"; do
    mkdir -p "$home/data/$id"
    printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  done
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog"
}

enable_dispatch_profile() {
  local home=$1
  printf '%s\n' '{"rules":[{"when":"current events","use":{"harness":"grok","model":"grok-4","effort":"high"}}],"default":{"harness":"codex","model":"gpt-5","effort":"medium"}}' \
    > "$home/config/crew-dispatch.json"
}

write_test_routing_decision() { # <home> <id> <harness> <model> <effort> <raw:0|1>
  local home=$1 id=$2 harness=$3 model=$4 effort=$5 raw=$6
  local task_dir brief_hash intent_hash home_hash host_hash now source authority config_binding
  local launch_kind launch_model launch_effort
  task_dir="$home/data/$id"
  [ -d "$task_dir" ] || return 0
  brief_hash=$(test_sha256_file "$task_dir/brief.md")
  if [ -f "$home/config/crew-dispatch.json" ]; then
    source=explicit_override
    authority=EXPLICIT_RUNTIME_OVERRIDE
    config_binding=$(jq -cn --arg sha256 "$(test_sha256_file "$home/config/crew-dispatch.json")" \
      '{kind: "present", sha256: $sha256}')
  else
    source=static_harness
    authority=STATIC_HARNESS
    config_binding='{"kind":"absent","sha256":null}'
  fi
  jq -n \
    --arg task_id "$id" \
    --arg brief_sha256 "$brief_hash" \
    --arg authority "$authority" \
    '{
      schema_version: 1,
      task_id: $task_id,
      brief_sha256: $brief_sha256,
      hard_capability: "test fixture dispatch",
      ambiguity: "LOW",
      risk: "LOCAL_TEST_ONLY",
      authority: $authority,
      gate: "LOCAL_TEST_GATE",
      forbidden_effects: ["push", "merge", "publication"]
    }' > "$task_dir/routing-intent.json"
  intent_hash=$(test_sha256_file "$task_dir/routing-intent.json")
  home_hash=$(printf '%s' "$home" | test_sha256_text)
  host_hash=$(uname -n | test_sha256_text)
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  launch_kind=verified_template
  [ "$raw" -eq 0 ] || launch_kind=raw_launch
  launch_model=null
  [ "$model" = default ] || launch_model=$(jq -cn --arg value "$model" '$value')
  launch_effort=null
  case "$harness:$effort" in
    claude:low|claude:medium|claude:high|claude:xhigh|claude:max|codex:low|codex:medium|codex:high|codex:xhigh|grok:low|grok:medium|grok:high|pi:low|pi:medium|pi:high|pi:xhigh|pi:max|pi-signed:low|pi-signed:medium|pi-signed:high|pi-signed:xhigh|pi-signed:max|muse:low|muse:medium|muse:high|muse:xhigh)
      launch_effort=$(jq -cn --arg value "$effort" '$value')
      ;;
    muse:max) launch_effort='"ultra"' ;;
  esac
  if [ "$raw" -eq 1 ] && [ "$effort" != default ]; then
    launch_effort=$(jq -cn --arg value "$effort" '$value')
  fi
  jq -n \
    --arg task_id "$id" \
    --arg intent_sha256 "$intent_hash" \
    --argjson dispatch_config "$config_binding" \
    --arg source "$source" \
    --arg harness "$harness" \
    --arg model "$model" \
    --arg effort "$effort" \
    --arg launch_kind "$launch_kind" \
    --argjson launch_model "$launch_model" \
    --argjson launch_effort "$launch_effort" \
    --arg home_sha256 "$home_hash" \
    --arg identity_sha256 "$host_hash" \
    --arg generated_at "$now" \
    '{
      schema_version: 1,
      task_id: $task_id,
      intent_sha256: $intent_sha256,
      dispatch_config: $dispatch_config,
      matched_profile: {source: $source, index: null},
      supervisor: {kind: "current-firstmate-home", home_sha256: $home_sha256},
      host: {kind: "local", identity_sha256: $identity_sha256},
      launch_binding: {kind: $launch_kind, harness: $harness, model: $launch_model, effort: $launch_effort},
      harness: $harness,
      model: $model,
      effort: $effort,
      candidates_considered: [{harness: $harness, model: $model, effort: $effort}],
      quota: {source: "NOT_APPLICABLE_SINGLETON", observed_at: null, snapshot_sha256: null},
      quota_basis: "NOT_APPLICABLE_SINGLETON",
      fallback: "NONE",
      rationale: "explicit test-only singleton receipt",
      required_gate: "LOCAL_TEST_GATE",
      selection_order: ["hard_capability", "ambiguity_complexity", "fresh_quota_among_capable"],
      generated_at: $generated_at
    }' > "$task_dir/routing-decision.pending.json"
}

prepare_test_routing_receipts() {
  local home=$1 harness model=default effort=default raw=0 arg next='' first positional=0 id item
  shift
  [ "${FM_TEST_ROUTING_PRESERVE:-0}" = 0 ] || return 0
  harness=$(sed -n '/^[[:space:]]*#/d; /^[[:space:]]*$/d; 1{s/[[:space:]].*$//; p;}' "$home/config/crew-harness")
  for arg in "$@"; do
    if [ -n "$next" ]; then
      case "$next" in harness) harness=$arg ;; model) model=$arg ;; effort) effort=$arg ;; esac
      next=
      continue
    fi
    case "$arg" in
      --secondmate|--relaunch) return 0 ;;
      --harness) next=harness ;;
      --harness=*) harness=${arg#--harness=} ;;
      --model) next=model ;;
      --model=*) model=${arg#--model=} ;;
      --effort) next=effort ;;
      --effort=*) effort=${arg#--effort=} ;;
      --backend|--mode|--yolo|--traceparent) next=ignore ;;
      --*) ;;
      *)
        positional=$((positional + 1))
        if [ "$positional" -eq 3 ] && [[ "$arg" == *' '* ]]; then
          raw=1
          first=${arg%% *}
          case "$first" in
            *=*) harness=$(basename "${arg#* }"); harness=${harness%% *} ;;
            *) harness=$(basename "$first") ;;
          esac
        elif [ "$positional" -eq 3 ]; then
          harness=$arg
        fi
        ;;
    esac
  done
  for item in "$@"; do
    case "$item" in
      --*) break ;;
      *=*) id=${item%%=*}; write_test_routing_decision "$home" "$id" "$harness" "$model" "$effort" "$raw" ;;
      *) id=$item; write_test_routing_decision "$home" "$id" "$harness" "$model" "$effort" "$raw"; break ;;
    esac
  done
}

make_seeded_secondmate_home() {
  local home=$1 id=$2
  mkdir -p "$home/bin" "$home/data"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  printf 'charter for %s\n' "$id" > "$home/data/charter.md"
}

run_spawn() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  prepare_test_routing_receipts "$home" "$@"
  : > "$launchlog"
  : > "$home/endpoint.log"
  : > "$home/text.log"
  : > "$home/worktree.log"
  # CLAUDE_CONFIG_DIR is forwarded onto claude launches by fm-spawn, so pin it
  # explicitly (empty by default) instead of leaking the invoking shell's value,
  # which would make launch assertions depend on the developer's environment.
  # A test opts in to the set case via FM_TEST_CLAUDE_CONFIG_DIR.
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="${FM_TEST_CONFIG_OVERRIDE:-$home/config}" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    CLAUDE_CONFIG_DIR="${FM_TEST_CLAUDE_CONFIG_DIR:-}" \
    FM_FAKE_LAUNCH_LOG="$launchlog" FM_FAKE_ENDPOINT_LOG="$home/endpoint.log" \
    FM_FAKE_TEXT_LOG="$home/text.log" \
    FM_FAKE_WORKTREE_LOG="$home/worktree.log" FM_FAKE_PI_VERSION="${FM_TEST_PI_VERSION:-0.84.0}" \
    FM_FAKE_CURSOR_MODELS="${FM_TEST_CURSOR_MODELS:-}" \
    FM_FAKE_CURSOR_LIST_STATUS="${FM_TEST_CURSOR_LIST_STATUS:-0}" \
    FM_TEST_REAL_PERL="$REAL_PERL" \
    FM_TEST_MUTATE_SNAPSHOT_BRIEF="${FM_TEST_MUTATE_SNAPSHOT_BRIEF:-}" \
    FM_TEST_SNAPSHOT_BRIEF_MARKER="${FM_TEST_SNAPSHOT_BRIEF_MARKER:-}" \
    XDG_CONFIG_HOME="${FM_TEST_XDG_CONFIG_HOME:-$home/xdgconfig}" \
    XDG_DATA_HOME="${FM_TEST_XDG_DATA_HOME:-$home/xdgdata}" \
    GROK_HOME="$home/grok-home" PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

# Ship spawns carry an explicit delivery contract (AGENTS.md section 7); these
# tests are about profile resolution, so they pass a fixed valid one.
run_ship_spawn() {
  run_spawn "$@" --mode no-mistakes --yolo off
}

read_case_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$1
EOF
}

assert_meta_profile() {
  local meta=$1 harness=$2 model=$3 effort=$4
  assert_grep "harness=$harness" "$meta" "meta missing harness=$harness"
  assert_grep "model=$model" "$meta" "meta missing model=$model"
  assert_grep "effort=$effort" "$meta" "meta missing effort=$effort"
}

assert_spawn_refused_before_side_effects() { # <home> <id> <launch-log>
  local home=$1 id=$2 launchlog=$3
  assert_absent "$home/state/$id.meta" "routing refusal published task metadata"
  [ ! -s "$launchlog" ] || fail "routing refusal sent pane input"
  [ ! -s "$home/text.log" ] || fail "routing refusal sent non-literal pane input"
  [ ! -s "$home/endpoint.log" ] || fail "routing refusal created an endpoint"
}

test_no_profile_keeps_claude_profile_defaults() {
  local rec id out status expected launch routing_brief launch_input
  id=profile-off-z1
  rec=$(make_spawn_case profile-off claude "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "claude spawn without profile flags should succeed"
  assert_contains "$out" "spawned $id harness=claude" "spawn did not report claude"
  assert_meta_profile "$HOME_DIR/state/$id.meta" claude default default
  assert_grep "treehouse get" "$HOME_DIR/text.log" \
    "successful spawn did not exercise the non-literal worktree-lease channel"

  launch=$(cat "$LAUNCH_LOG")
  routing_brief=$(sed -n 's/^routing_brief=//p' "$HOME_DIR/state/$id.meta")
  launch_input=$("$ROOT/bin/fm-operational-input.sh" encode launch-brief < "$routing_brief"; printf x)
  launch_input=${launch_input%x}
  expected="env -u CURSOR_AGENT -u CURSOR_INVOKED_AS CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions '$launch_input'"
  [ "$launch" = "$expected" ] || fail "no-profile claude launch did not use the canonical launch kind"$'\n'"expected: $expected"$'\n'"actual:   $launch"
  pass "no --model/--effort records defaults and types the claude launch instructions"
}

test_non_cursor_launch_clears_inherited_cursor_markers() {
  local rec id out status launch
  id=profile-claude-cursor-markers-z1b
  rec=$(make_spawn_case profile-claude-cursor-markers claude "$id")
  read_case_record "$rec"

  out=$(CURSOR_AGENT=1 CURSOR_INVOKED_AS=cursor-agent \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "claude spawn under Cursor markers should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "env -u CURSOR_AGENT -u CURSOR_INVOKED_AS" \
    "non-cursor launch must clear both inherited Cursor identity markers"
  pass "non-cursor launches clear inherited Cursor identity markers"
}

test_relative_home_overrides_launch_with_absolute_cross_process_paths() {
  local rec id out status launch home_real routing_brief
  id=profile-relative-paths-z1b
  rec=$(make_spawn_case profile-relative-paths pi "$id")
  read_case_record "$rec"
  home_real=$(cd "$HOME_DIR" && pwd -P)
  mkdir -p "$CASE_DIR/cdpath/home/state" "$CASE_DIR/cdpath/home/data"
  write_test_routing_decision "$home_real" "$id" pi default default 0
  : > "$LAUNCH_LOG"

  out=$(
    cd "$CASE_DIR" || exit 1
    CDPATH="$CASE_DIR/cdpath" FM_ROOT_OVERRIDE='' FM_HOME=home \
      FM_STATE_OVERRIDE=home/state FM_DATA_OVERRIDE=home/data \
      FM_PROJECTS_OVERRIDE=home/projects FM_CONFIG_OVERRIDE=home/config \
      FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
      CLAUDE_CONFIG_DIR='' FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
      GROK_HOME=home/grok-home PATH="$FAKEBIN_DIR:$PATH" \
      "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
  )
  status=$?
  expect_code 0 "$status" "spawn with relative home overrides should succeed"
  launch=$(cat "$LAUNCH_LOG")
  routing_brief=$(sed -n 's/^routing_brief=//p' "$home_real/state/$id.meta")
  assert_contains "$launch" "-e '$home_real/state/$id.pi-ext.ts'" \
    "relative FM_STATE_OVERRIDE leaked into Pi's cross-process extension path"
  assert_not_contains "$launch" "$routing_brief" \
    "relative FM_DATA_OVERRIDE leaked a cross-process brief path"
  assert_contains "$launch" "FIRSTMATE_OP: v1 launch-brief:" \
    "relative FM_DATA_OVERRIDE lost the verified launch input"
  pass "relative home overrides ignore CDPATH and become absolute before spawn launch construction"
}

test_home_defaults_preserve_absolute_or_resolve_relative_paths() {
  local rec relative_id absolute_id out status launch home_real linked_home routing_brief
  relative_id=profile-relative-home-defaults-z1c
  absolute_id=profile-absolute-home-defaults-z1d
  rec=$(make_spawn_case profile-home-defaults pi "$relative_id" "$absolute_id")
  read_case_record "$rec"
  home_real=$(cd "$HOME_DIR" && pwd -P)
  write_test_routing_decision "$home_real" "$relative_id" pi default default 0

  : > "$LAUNCH_LOG"
  out=$(
    cd "$CASE_DIR" || exit 1
    FM_ROOT_OVERRIDE='' FM_HOME=home \
      FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' \
      FM_PROJECTS_OVERRIDE=home/projects FM_CONFIG_OVERRIDE=home/config \
      FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
      CLAUDE_CONFIG_DIR='' FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
      GROK_HOME=home/grok-home PATH="$FAKEBIN_DIR:$PATH" \
      "$SPAWN" "$relative_id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
  )
  status=$?
  expect_code 0 "$status" "spawn with relative FM_HOME defaults should succeed"
  launch=$(cat "$LAUNCH_LOG")
  routing_brief=$(sed -n 's/^routing_brief=//p' "$home_real/state/$relative_id.meta")
  assert_contains "$launch" "-e '$home_real/state/$relative_id.pi-ext.ts'" \
    "relative FM_HOME leaked into Pi's default cross-process extension path"
  assert_not_contains "$launch" "$routing_brief" \
    "relative FM_HOME leaked a default cross-process brief path"

  linked_home="$CASE_DIR/home-link"
  ln -s "$HOME_DIR" "$linked_home"
  write_test_routing_decision "$linked_home" "$absolute_id" pi default default 0
  : > "$LAUNCH_LOG"
  out=$(
    FM_ROOT_OVERRIDE='' FM_HOME="$linked_home" \
      FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' \
      FM_PROJECTS_OVERRIDE="$linked_home/projects" FM_CONFIG_OVERRIDE="$linked_home/config" \
      FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
      CLAUDE_CONFIG_DIR='' FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
      GROK_HOME="$linked_home/grok-home" PATH="$FAKEBIN_DIR:$PATH" \
      "$SPAWN" "$absolute_id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
  )
  status=$?
  expect_code 0 "$status" "spawn with absolute symlink-spelled FM_HOME defaults should succeed"
  launch=$(cat "$LAUNCH_LOG")
  routing_brief=$(sed -n 's/^routing_brief=//p' "$linked_home/state/$absolute_id.meta")
  assert_contains "$launch" "-e '$linked_home/state/$absolute_id.pi-ext.ts'" \
    "absolute FM_HOME spelling changed in Pi's default cross-process extension path"
  assert_not_contains "$launch" "$routing_brief" \
    "absolute FM_HOME leaked a default cross-process brief path"
  pass "FM_HOME defaults resolve relative paths and preserve absolute spellings"
}

test_absolute_override_spelling_is_preserved_in_launch_paths() {
  local rec id out status launch linked_home routing_brief
  id=profile-absolute-paths-z1c
  rec=$(make_spawn_case profile-absolute-paths pi "$id")
  read_case_record "$rec"
  linked_home="$CASE_DIR/home-link"
  ln -s "$HOME_DIR" "$linked_home"
  write_test_routing_decision "$linked_home" "$id" pi default default 0
  : > "$LAUNCH_LOG"

  out=$(
    FM_ROOT_OVERRIDE='' FM_HOME="$linked_home" \
      FM_STATE_OVERRIDE="$linked_home/state" FM_DATA_OVERRIDE="$linked_home/data" \
      FM_PROJECTS_OVERRIDE="$linked_home/projects" FM_CONFIG_OVERRIDE="$linked_home/config" \
      FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
      CLAUDE_CONFIG_DIR='' FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
      GROK_HOME="$linked_home/grok-home" PATH="$FAKEBIN_DIR:$PATH" \
      "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
  )
  status=$?
  expect_code 0 "$status" "spawn with absolute symlink-spelled overrides should succeed"
  launch=$(cat "$LAUNCH_LOG")
  routing_brief=$(sed -n 's/^routing_brief=//p' "$linked_home/state/$id.meta")
  assert_contains "$launch" "-e '$linked_home/state/$id.pi-ext.ts'" \
    "absolute FM_STATE_OVERRIDE spelling changed in Pi's cross-process extension path"
  assert_not_contains "$launch" "$routing_brief" \
    "absolute FM_DATA_OVERRIDE leaked a cross-process brief path"
  pass "absolute override spellings are preserved in spawn launch paths"
}

test_unresolvable_relative_overrides_fail_loudly() {
  local rec id out status
  id=profile-unresolvable-paths-z1d
  rec=$(make_spawn_case profile-unresolvable-paths pi "$id")
  read_case_record "$rec"

  out=$(
    cd "$CASE_DIR" || exit 1
    FM_ROOT_OVERRIDE='' FM_HOME=missing-home \
      FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' \
      "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
  )
  status=$?
  expect_code 1 "$status" "spawn with an unresolvable relative home should fail"
  assert_contains "$out" "FM_HOME directory cannot be resolved: missing-home" \
    "spawn did not name the unresolvable FM_HOME"

  out=$(
    cd "$CASE_DIR" || exit 1
    FM_ROOT_OVERRIDE='' FM_HOME=home \
      FM_STATE_OVERRIDE=missing-state FM_DATA_OVERRIDE=home/data \
      "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
  )
  status=$?
  expect_code 1 "$status" "spawn with an unresolvable relative state override should fail"
  assert_contains "$out" "FM_STATE_OVERRIDE directory cannot be resolved: missing-state" \
    "spawn did not name the unresolvable FM_STATE_OVERRIDE"

  out=$(
    cd "$CASE_DIR" || exit 1
    FM_ROOT_OVERRIDE='' FM_HOME=home \
      FM_STATE_OVERRIDE=home/state FM_DATA_OVERRIDE=missing-data \
      "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
  )
  status=$?
  expect_code 1 "$status" "spawn with an unresolvable relative data override should fail"
  assert_contains "$out" "FM_DATA_OVERRIDE directory cannot be resolved: missing-data" \
    "spawn did not name the unresolvable FM_DATA_OVERRIDE"
  pass "unresolvable relative spawn overrides fail with named diagnostics"
}

test_active_dispatch_profile_requires_explicit_harness_for_ship() {
  local rec id out status
  id=profile-required-ship-z11
  rec=$(make_spawn_case profile-required-ship claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "ship spawn without explicit harness should fail when dispatch profiles are active"
  assert_contains "$out" "config/crew-dispatch.json is active - pass an explicit harness resolved from the dispatch rules" \
    "spawn did not explain the dispatch-profile backstop"
  assert_absent "$HOME_DIR/state/$id.meta" "ship refusal should happen before meta is written"
  pass "active crew-dispatch profile requires an explicit harness for ship spawns"
}

test_active_dispatch_profile_requires_explicit_harness_for_scout() {
  local rec id out status
  id=profile-required-scout-z12
  rec=$(make_spawn_case profile-required-scout claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --scout)
  status=$?
  expect_code 1 "$status" "scout spawn without explicit harness should fail when dispatch profiles are active"
  assert_contains "$out" "config/crew-dispatch.json is active - pass an explicit harness resolved from the dispatch rules" \
    "scout refusal did not explain the dispatch-profile backstop"
  assert_absent "$HOME_DIR/state/$id.meta" "scout refusal should happen before meta is written"
  pass "active crew-dispatch profile requires an explicit harness for scout spawns"
}

test_routing_receipt_is_unconditional_without_dispatch_config() {
  local rec id out status
  id=profile-receipt-unconditional-z12a
  rec=$(make_spawn_case profile-receipt-unconditional claude "$id")
  read_case_record "$rec"

  out=$(FM_TEST_ROUTING_PRESERVE=1 \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "missing receipt should refuse even when dispatch config is absent"
  assert_contains "$out" "ROUTING_DECISION missing" \
    "unconfigured route did not retain unconditional receipt enforcement"
  assert_spawn_refused_before_side_effects "$HOME_DIR" "$id" "$LAUNCH_LOG"
  pass "routing receipt enforcement does not depend on dispatch config presence"
}

test_config_override_cannot_relocate_receipt_authority() {
  local rec id empty_config out status
  id=profile-config-override-z12b
  rec=$(make_spawn_case profile-config-override claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"
  empty_config="$CASE_DIR/empty-config"
  mkdir -p "$empty_config"

  out=$(FM_TEST_ROUTING_PRESERVE=1 FM_TEST_CONFIG_OVERRIDE="$empty_config" \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness grok --model grok-4 --effort high)
  status=$?
  expect_code 1 "$status" "config relocation without a receipt should still refuse"
  assert_contains "$out" "ROUTING_DECISION missing" \
    "FM_CONFIG_OVERRIDE relocated the routing requirement out of existence"
  assert_spawn_refused_before_side_effects "$HOME_DIR" "$id" "$LAUNCH_LOG"
  pass "FM_CONFIG_OVERRIDE cannot relocate routing receipt authority"
}

assert_preflight_kept_retryable_receipt() {
  local home=$1 id=$2 launchlog=$3
  assert_present "$home/data/$id/routing-decision.pending.json" \
    "preflight refusal consumed the retryable routing receipt"
  if fm_test_existing_routing_decision_path "$home" "$id" >/dev/null; then
    fail "preflight refusal published the final routing receipt"
  fi
  assert_spawn_refused_before_side_effects "$home" "$id" "$launchlog"
  [ ! -s "$home/worktree.log" ] || fail "preflight refusal leased a worktree"
}

test_project_preflight_keeps_receipt_retryable() {
  local rec id out status missing_project
  id=profile-project-preflight-z12b1
  rec=$(make_spawn_case profile-project-preflight claude "$id")
  read_case_record "$rec"
  missing_project="$CASE_DIR/missing-project"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$missing_project")
  status=$?
  expect_code 1 "$status" "missing project should refuse during preflight"
  assert_preflight_kept_retryable_receipt "$HOME_DIR" "$id" "$LAUNCH_LOG"

  out=$(FM_TEST_ROUTING_PRESERVE=1 \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "corrected project retry should consume the original receipt"
  assert_present "$(fm_test_routing_decision_path "$HOME_DIR" "$id")" \
    "corrected project retry did not publish the routing receipt"
  pass "project preflight leaves the routing receipt retryable"
}

test_delivery_preflight_keeps_receipt_retryable() {
  local rec id out status
  id=profile-delivery-preflight-z12b2
  rec=$(make_spawn_case profile-delivery-preflight claude "$id")
  read_case_record "$rec"
  printf 'Delivery contract: mode=direct-PR\n' > "$HOME_DIR/data/$id/brief.md"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --mode no-mistakes --yolo off)
  status=$?
  expect_code 1 "$status" "delivery mismatch should refuse during preflight"
  assert_contains "$out" "delivery mismatch" "delivery preflight refusal did not fire"
  assert_preflight_kept_retryable_receipt "$HOME_DIR" "$id" "$LAUNCH_LOG"

  out=$(FM_TEST_ROUTING_PRESERVE=1 \
    run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
      "$id" "$PROJ_DIR" --mode direct-PR --yolo off)
  status=$?
  expect_code 0 "$status" "corrected delivery retry should consume the original receipt"
  assert_present "$(fm_test_routing_decision_path "$HOME_DIR" "$id")" \
    "corrected delivery retry did not publish the routing receipt"
  pass "delivery preflight leaves the routing receipt retryable"
}

test_muse_credential_preflight_keeps_receipt_retryable() {
  local rec id out status config_home
  id=profile-muse-preflight-z12b3
  rec=$(make_spawn_case profile-muse-preflight muse "$id")
  read_case_record "$rec"
  config_home="$CASE_DIR/muse-config"
  mkdir -p "$config_home/muse"

  out=$(FM_TEST_XDG_CONFIG_HOME="$config_home" \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "missing Muse credential should refuse during preflight"
  assert_contains "$out" "no worker-reachable credential" "Muse credential refusal did not fire"
  assert_preflight_kept_retryable_receipt "$HOME_DIR" "$id" "$LAUNCH_LOG"

  printf '{"schema_version":1}\n' > "$config_home/muse/auth.json"
  out=$(FM_TEST_ROUTING_PRESERVE=1 FM_TEST_XDG_CONFIG_HOME="$config_home" \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "credentialed Muse retry should consume the original receipt"
  assert_present "$(fm_test_routing_decision_path "$HOME_DIR" "$id")" \
    "credentialed Muse retry did not publish the routing receipt"
  pass "Muse credential preflight leaves the routing receipt retryable"
}

test_duplicate_spawn_preserves_active_routing_provenance() {
  local rec id out status pending_tmp
  id=profile-duplicate-routing-z12b2
  rec=$(make_spawn_case profile-duplicate-routing claude "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "initial spawn should establish active routing provenance"
  cp "$HOME_DIR/state/$id.meta" "$CASE_DIR/active.meta"
  cp "$(sed -n 's/^routing_decision=//p' "$HOME_DIR/state/$id.meta")" "$CASE_DIR/active-routing-decision.json"

  write_test_routing_decision "$HOME_DIR" "$id" claude default default 0
  pending_tmp="$HOME_DIR/data/$id/routing-decision.pending.json.tmp"
  jq '.rationale = "duplicate fresh spawn receipt"' \
    "$HOME_DIR/data/$id/routing-decision.pending.json" > "$pending_tmp"
  mv "$pending_tmp" "$HOME_DIR/data/$id/routing-decision.pending.json"

  out=$(FM_TEST_ROUTING_PRESERVE=1 \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "duplicate fresh spawn should refuse before receipt consumption"
  assert_contains "$out" "task $id already has metadata" \
    "duplicate refusal did not identify the active task record"
  cmp -s "$CASE_DIR/active.meta" "$HOME_DIR/state/$id.meta" \
    || fail "duplicate spawn changed active task metadata"
  cmp -s "$CASE_DIR/active-routing-decision.json" "$(sed -n 's/^routing_decision=//p' "$HOME_DIR/state/$id.meta")" \
    || fail "duplicate spawn changed the active routing receipt bytes"
  assert_present "$HOME_DIR/data/$id/routing-decision.pending.json" \
    "duplicate spawn consumed its unaccepted pending receipt"
  [ ! -s "$LAUNCH_LOG" ] || fail "duplicate spawn sent pane input"
  [ ! -s "$HOME_DIR/text.log" ] || fail "duplicate spawn sent non-literal pane input"
  [ ! -s "$HOME_DIR/endpoint.log" ] || fail "duplicate spawn created an endpoint"
  [ ! -s "$HOME_DIR/worktree.log" ] || fail "duplicate spawn leased a worktree"
  pass "duplicate fresh spawn preserves active metadata and routing receipt bytes"
}

test_launch_uses_validated_brief_snapshot_after_source_replacement() {
  local rec id out status routing_brief launch expected_input_file
  id=profile-brief-snapshot-z12b3
  rec=$(make_spawn_case profile-brief-snapshot claude "$id")
  read_case_record "$rec"
  printf 'validated __MODELFLAG__ __TURNEND__ __WORKTREE__ bytes\n\n\n' > "$HOME_DIR/data/$id/brief.md"
  /bin/cp "$HOME_DIR/data/$id/brief.md" "$CASE_DIR/validated-brief.expected"

  out=$(FM_TEST_MUTATE_BRIEF_SOURCE="$HOME_DIR/data/$id/brief.md" \
    FM_TEST_BRIEF_REPLACEMENT="replacement after validation snapshot" \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "source brief replacement should not change validated launch input"
  routing_brief=$(sed -n 's/^routing_brief=//p' "$HOME_DIR/state/$id.meta")
  [ -n "$routing_brief" ] || fail "spawn metadata omitted the validated brief snapshot"
  cmp -s "$CASE_DIR/validated-brief.expected" "$routing_brief" \
    || fail "persisted brief snapshot differs from the validated bytes"
  [ "$(cat "$HOME_DIR/data/$id/brief.md")" = "replacement after validation snapshot" ] \
    || fail "source brief replacement counterexample did not fire"
  launch=$(cat "$LAUNCH_LOG")
  expected_input_file="$CASE_DIR/validated-launch-input.expected"
  "$ROOT/bin/fm-operational-input.sh" encode launch-brief \
    < "$CASE_DIR/validated-brief.expected" > "$expected_input_file"
  : > "$CASE_DIR/harness-input.log"
  PATH="$FAKEBIN_DIR:$PATH" FM_FAKE_HARNESS_INPUT_LOG="$CASE_DIR/harness-input.log" bash -c "$launch" \
    || fail "verified launch command could not execute through its public launch interface"
  cmp -s "$expected_input_file" "$CASE_DIR/harness-input.log" \
    || fail "verified harness did not receive every receipt-bound launch-input byte"
  assert_not_contains "$launch" "$routing_brief" \
    "emitted launch reopened the mutable validated brief pathname"
  pass "launch verifies the persisted brief bytes after source replacement"
}

test_launch_refuses_replaced_validated_brief_target() {
  local rec id out status marker
  id=profile-brief-target-race-z12b4
  rec=$(make_spawn_case profile-brief-target-race claude "$id")
  read_case_record "$rec"
  write_test_routing_decision "$HOME_DIR" "$id" claude default default 0
  marker="$CASE_DIR/snapshot-brief-replaced"

  out=$(FM_TEST_ROUTING_PRESERVE=1 FM_TEST_MUTATE_SNAPSHOT_BRIEF=1 \
    FM_TEST_SNAPSHOT_BRIEF_MARKER="$marker" \
    FM_TEST_BRIEF_TARGET_REPLACEMENT="attacker replacement before validation read" \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "brief snapshot replacement should refuse synchronously"
  assert_present "$marker" "brief snapshot replacement counterexample did not fire"
  assert_contains "$out" "ROUTING_DECISION BRIEF_HASH_MISMATCH" \
    "brief snapshot replacement lacked its routing refusal diagnostic"
  assert_spawn_refused_before_side_effects "$HOME_DIR" "$id" "$LAUNCH_LOG"
  [ ! -s "$HOME_DIR/worktree.log" ] || fail "brief target replacement leased a worktree"
  pass "spawn refuses a substituted brief snapshot before side effects"
}

test_late_commit_failure_burns_generation_and_requires_fresh_receipt() {
  local rec id out status marker pending fresh_pending consumed_count routing_brief_count routing_brief
  id=profile-late-commit-retry-z12b5
  rec=$(make_spawn_case profile-late-commit-retry claude "$id")
  read_case_record "$rec"
  marker="$CASE_DIR/receipt-link-failed"

  out=$(FM_TEST_FAIL_RECEIPT_LINK_MARKER="$marker" \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "late receipt publication failure should refuse"
  assert_present "$marker" "late receipt publication failure counterexample did not fire"
  assert_preflight_kept_retryable_receipt "$HOME_DIR" "$id" "$LAUNCH_LOG"

  out=$(FM_TEST_ROUTING_PRESERVE=1 FM_TEST_FAIL_RECEIPT_LINK_MARKER="$marker" \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "a late publication failure must burn the consumed receipt generation"
  assert_contains "$out" "ROUTING_DECISION PERSISTENCE_REFUSED: CONSUMED_GENERATION:" \
    "same-generation retry lacked its replay refusal diagnostic"
  assert_spawn_refused_before_side_effects "$HOME_DIR" "$id" "$LAUNCH_LOG"

  pending="$HOME_DIR/data/$id/routing-decision.pending.json"
  fresh_pending="$pending.fresh"
  jq '.rationale = "fresh retry after burned generation"' "$pending" > "$fresh_pending" \
    || fail "could not author a fresh receipt generation for the retry counterexample"
  mv "$fresh_pending" "$pending" \
    || fail "could not publish the fresh receipt generation for the retry counterexample"
  out=$(FM_TEST_ROUTING_PRESERVE=1 FM_TEST_FAIL_RECEIPT_LINK_MARKER="$marker" \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "a fresh receipt should allow retry after late publication failure"
  consumed_count=$(sort -u "$HOME_DIR/data/$id/routing-generations.consumed" | wc -l | tr -d ' ')
  [ "$consumed_count" -eq 2 ] || fail "late commit retry recorded $consumed_count consumed generations instead of the burned and fresh generations"
  routing_brief_count=$(find "$HOME_DIR/data/$id" -maxdepth 1 -type d -name 'routing-generation.*' | wc -l | tr -d ' ')
  [ "$routing_brief_count" -eq 1 ] || fail "late commit retry left $routing_brief_count published receipt generations instead of only the fresh generation"
  routing_brief=$(sed -n 's/^routing_brief=//p' "$HOME_DIR/state/$id.meta")
  assert_present "$routing_brief" "late commit retry left its durable brief link orphaned"
  assert_present "$(fm_test_routing_decision_path "$HOME_DIR" "$id")" \
    "late commit retry did not publish the routing receipt"
  pass "late commit failure burns its generation and a fresh receipt can retry"
}

test_raw_launches_refuse_unobserved_runtime_selection() {
  local rec dynamic env_prefix env_wrapper terminator nonstandard unresolved id out status command predicate
  dynamic=profile-raw-dynamic-z12c
  env_prefix=profile-raw-env-z12d
  env_wrapper=profile-raw-env-wrapper-z12d2
  terminator=profile-raw-terminator-z12d3
  nonstandard=profile-raw-nonstandard-z12e
  unresolved=profile-raw-unresolved-z12f
  rec=$(make_spawn_case profile-raw-unobserved claude \
    "$dynamic" "$env_prefix" "$env_wrapper" "$terminator" "$nonstandard" "$unresolved")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  for id in "$dynamic" "$env_prefix" "$env_wrapper" "$terminator" "$nonstandard" "$unresolved"; do
    # shellcheck disable=SC2016 # This fixture must preserve the unresolved variable literally.
    case "$id" in
      "$dynamic") command='claude --model "$ROUTE_MODEL" --effort high'; predicate=RAW_LAUNCH_NOT_VERIFIABLE ;;
      "$env_prefix") command='MODEL=opus claude --model opus --effort high'; predicate=RAW_LAUNCH_NOT_VERIFIABLE ;;
      "$env_wrapper") command='env ROUTE_MODEL=sonnet claude --model opus --effort high'; predicate=RAW_LAUNCH_NOT_VERIFIABLE ;;
      "$terminator") command='claude -- --model opus --effort high'; predicate=RAW_LAUNCH_UNRESOLVED ;;
      "$nonstandard") command='claude -m opus --effort high'; predicate=RAW_LAUNCH_NOT_VERIFIABLE ;;
      *) command='claude --model opus'; predicate=RAW_LAUNCH_UNRESOLVED ;;
    esac
    out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
      "$id" "$PROJ_DIR" "$command" --model opus --effort high)
    status=$?
    expect_code 1 "$status" "$id should refuse before spawn effects"
    assert_contains "$out" "ROUTING_DECISION $predicate" "$id named the wrong raw-launch predicate"
    assert_spawn_refused_before_side_effects "$HOME_DIR" "$id" "$LAUNCH_LOG"
  done
  pass "raw shell expansion, environment prefixes, non-standard flags, and missing axes refuse"
}

test_active_dispatch_profile_allows_explicit_harness() {
  local rec id out status launch
  id=profile-explicit-z13
  rec=$(make_spawn_case profile-explicit claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness codex --model gpt-5 --effort high)
  status=$?
  expect_code 0 "$status" "explicit harness should satisfy active dispatch-profile requirement"
  assert_contains "$out" "spawned $id harness=codex" "spawn did not report explicit codex harness"
  assert_meta_profile "$HOME_DIR/state/$id.meta" codex gpt-5 high
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "codex --model 'gpt-5' -c 'model_reasoning_effort=\"high\"' --dangerously-bypass-approvals-and-sandbox" \
    "explicit harness launch did not thread model and effort"
  pass "active crew-dispatch profile allows an explicit resolved harness"
}

test_active_dispatch_profile_allows_positional_harness() {
  local rec id out status
  id=profile-positional-z14
  rec=$(make_spawn_case profile-positional claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" codex --model gpt-5 --effort high)
  status=$?
  expect_code 0 "$status" "positional harness should satisfy active dispatch-profile requirement"
  assert_contains "$out" "spawned $id harness=codex" "spawn did not report positional codex harness"
  assert_meta_profile "$HOME_DIR/state/$id.meta" codex gpt-5 high
  pass "active crew-dispatch profile allows the legacy positional harness form"
}

test_active_dispatch_profile_allows_raw_launch_command() {
  local rec id out status launch command expected_input_file
  id=profile-raw-z15
  rec=$(make_spawn_case profile-raw claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"
  printf 'raw launch brief with trailing newlines\n\n\n' > "$HOME_DIR/data/$id/brief.md"

  command="$FAKEBIN_DIR/claude --model=custom%v1 --effort=high --flag"
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" "$command" \
    --model custom%v1 --effort high)
  status=$?
  expect_code 0 "$status" "raw launch command should satisfy active dispatch-profile requirement"
  assert_contains "$out" "spawned $id harness=claude" "spawn did not report raw command harness"
  assert_meta_profile "$HOME_DIR/state/$id.meta" claude custom%v1 high
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "env -u CURSOR_AGENT -u CURSOR_INVOKED_AS $command " \
    "raw launch command did not preserve the verified harness invocation"
  expected_input_file="$CASE_DIR/raw-launch-input.expected"
  "$ROOT/bin/fm-operational-input.sh" encode launch-brief \
    < "$HOME_DIR/data/$id/brief.md" > "$expected_input_file"
  : > "$CASE_DIR/harness-input.log"
  FM_FAKE_HARNESS_INPUT_LOG="$CASE_DIR/harness-input.log" bash -c "$launch" \
    || fail "raw launch command could not execute through its public launch interface"
  cmp -s "$expected_input_file" "$CASE_DIR/harness-input.log" \
    || fail "raw harness did not receive every receipt-bound launch-input byte"
  pass "raw launch consumes the verified receipt-bound brief"
}

test_raw_launch_allows_shell_quoted_punctuation() {
  local rec id out status launch model command
  id=profile-raw-quoted-z15b
  model='custom!#(model)'
  command="claude --model '$model' --effort high --flag"
  rec=$(make_spawn_case profile-raw-quoted claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" "$command" --model "$model" --effort high)
  status=$?
  expect_code 0 "$status" "shell-quoted raw punctuation should remain observable"
  assert_contains "$out" "spawned $id harness=claude" "quoted raw command did not spawn"
  assert_meta_profile "$HOME_DIR/state/$id.meta" claude "$model" high
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "env -u CURSOR_AGENT -u CURSOR_INVOKED_AS $command " \
    "quoted raw launch command did not preserve its verified invocation"
  pass "raw launch allowlist leaves shell-quoted punctuation intact"
}

test_claude_threads_model_and_effort() {
  local rec id out status launch
  id=profile-claude-z2
  rec=$(make_spawn_case profile-claude claude "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model sonnet --effort high)
  status=$?
  expect_code 0 "$status" "claude spawn with profile flags should succeed"
  assert_meta_profile "$HOME_DIR/state/$id.meta" claude sonnet high
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "claude --dangerously-skip-permissions --model 'sonnet' --effort 'high'" \
    "claude launch did not thread model and effort flags"
  assert_not_contains "$launch" "--tui-mode" "non-Pi launches must not receive Pi's TUI mode override"
  pass "claude receives --model and --effort profile flags"
}

test_codex_threads_model_and_effort() {
  local rec id out status launch
  id=profile-codex-z3
  rec=$(make_spawn_case profile-codex codex "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model gpt-5 --effort high)
  status=$?
  expect_code 0 "$status" "codex spawn with profile flags should succeed"
  assert_meta_profile "$HOME_DIR/state/$id.meta" codex gpt-5 high
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "codex --model 'gpt-5' -c 'model_reasoning_effort=\"high\"' --dangerously-bypass-approvals-and-sandbox" \
    "codex launch did not thread model and reasoning effort config"
  pass "codex receives --model and model_reasoning_effort profile flags"
}

test_codex_omits_invalid_max_effort() {
  local rec id out status launch
  id=profile-codex-max-z4
  rec=$(make_spawn_case profile-codex-max codex "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model gpt-5 --effort max)
  status=$?
  expect_code 0 "$status" "codex spawn with unsupported max effort should omit the effort flag"
  assert_meta_profile "$HOME_DIR/state/$id.meta" codex gpt-5 max
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "codex --model 'gpt-5' --dangerously-bypass-approvals-and-sandbox" \
    "codex launch did not preserve the model flag when max effort was omitted"
  assert_not_contains "$launch" "model_reasoning_effort" "codex launch must omit unsupported max reasoning effort"
  jq -e '.launch_binding.effort == null' "$(fm_test_routing_decision_path "$HOME_DIR" "$id")" >/dev/null \
    || fail "codex max receipt laundered the requested effort as emitted"
  pass "codex omits unsupported max effort instead of passing a bad config value"
}

test_grok_threads_model_and_reasoning_effort() {
  local rec id out status launch
  id=profile-grok-z5
  rec=$(make_spawn_case profile-grok grok "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model grok-4 --effort high)
  status=$?
  expect_code 0 "$status" "grok spawn with profile flags should succeed"
  assert_meta_profile "$HOME_DIR/state/$id.meta" grok grok-4 high
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "grok --always-approve --model 'grok-4' --reasoning-effort 'high'" \
    "grok launch did not thread model and reasoning-effort flags"
  assert_not_contains "$launch" "--effort" "grok launch must use --reasoning-effort, not --effort"
  pass "grok receives --model and --reasoning-effort profile flags"
}

test_grok_omits_invalid_max_reasoning_effort() {
  local rec id out status launch
  id=profile-grok-max-z6
  rec=$(make_spawn_case profile-grok-max grok "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model grok-4 --effort max)
  status=$?
  expect_code 0 "$status" "grok spawn with unsupported max reasoning effort should omit the effort flag"
  assert_meta_profile "$HOME_DIR/state/$id.meta" grok grok-4 max
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "grok --always-approve --model 'grok-4' '" \
    "grok launch did not preserve the model flag and typed brief when max effort was omitted"
  assert_not_contains "$launch" "--reasoning-effort" "grok launch must omit unsupported max reasoning effort"
  assert_not_contains "$launch" "--effort" "grok launch must not fall back to --effort for reasoning effort"
  jq -e '.launch_binding.effort == null' "$(fm_test_routing_decision_path "$HOME_DIR" "$id")" >/dev/null \
    || fail "grok max receipt laundered the requested effort as emitted"
  pass "grok omits unsupported max reasoning effort"
}

test_grok_omits_invalid_xhigh_reasoning_effort() {
  local rec id out status launch
  id=profile-grok-xhigh-z6b
  rec=$(make_spawn_case profile-grok-xhigh grok "$id")
  read_case_record "$rec"

  # grok 0.2.99 rejects xhigh (accepted set is only low|medium|high).
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model grok-4 --effort xhigh)
  status=$?
  expect_code 0 "$status" "grok spawn with unsupported xhigh reasoning effort should omit the effort flag"
  assert_meta_profile "$HOME_DIR/state/$id.meta" grok grok-4 xhigh
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "grok --always-approve --model 'grok-4' '" \
    "grok launch did not preserve the model flag and typed brief when xhigh effort was omitted"
  assert_not_contains "$launch" "--reasoning-effort" "grok launch must omit unsupported xhigh reasoning effort"
  assert_not_contains "$launch" "--effort" "grok launch must not fall back to --effort for reasoning effort"
  jq -e '.launch_binding.effort == null' "$(fm_test_routing_decision_path "$HOME_DIR" "$id")" >/dev/null \
    || fail "grok xhigh receipt laundered the requested effort as emitted"
  pass "grok omits unsupported xhigh reasoning effort"
}

test_cursor_threads_model_workspace_and_omits_effort_axis() {
  local rec id out status launch
  id=profile-cursor-z6c
  rec=$(make_spawn_case profile-cursor cursor "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model cursor-grok-4.5-high --effort high)
  status=$?
  expect_code 0 "$status" "cursor spawn with a model-qualified reasoning class should succeed"
  assert_meta_profile "$HOME_DIR/state/$id.meta" cursor cursor-grok-4.5-high high
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "--trust --yolo --model 'cursor-grok-4.5-high' --workspace '$WT_DIR'" \
    "cursor launch did not carry trust, autonomy, model, and exact workspace flags"
  # The executable is RESOLVED, never named: `cursor` is not the CLI, so a
  # literal `cursor agent` command cannot run on a machine that has only the
  # real installed names.
  assert_not_contains "$launch" "cursor agent --trust" \
    "cursor launch must resolve its executable, not invoke a literal 'cursor agent'"
  assert_contains "$launch" "cursor-agent" "cursor launch did not resolve a cursor executable"
  # -w/--worktree would allocate a SECOND worktree under ~/.cursor/worktrees and
  # break the isolation contract the spawn assertion depends on.
  assert_not_contains "$launch" " --worktree" "cursor launch must never allocate a second worktree"
  assert_not_contains "$launch" " -w " "cursor launch must never allocate a second worktree"
  # An inherited CLAUDECODE would otherwise outrank cursor's own marker.
  assert_contains "$launch" "env -u CLAUDECODE" "cursor launch must clear foreign primary markers"
  assert_contains "$launch" "FIRSTMATE_OP: v1 launch-brief:" "cursor launch did not carry the verified brief positionally"
  assert_not_contains "$launch" "--effort" "cursor launch must not invent a separate effort flag"
  assert_not_contains "$launch" "--reasoning-effort" "cursor launch must not invent a separate reasoning-effort flag"
  assert_grep 'harness=cursor' "$HOME_DIR/state/$id.meta" "cursor harness was not recorded in meta"
  assert_grep 'model=cursor-grok-4.5-high' "$HOME_DIR/state/$id.meta" "cursor model was recorded as default"
  jq -e '.launch_binding.model == "cursor-grok-4.5-high" and .launch_binding.effort == null' \
    "$(fm_test_routing_decision_path "$HOME_DIR" "$id")" >/dev/null \
    || fail "cursor receipt did not distinguish emitted model from metadata-only effort"
  pass "cursor receives its model-qualified reasoning class and exact task workspace"
}

test_cursor_refuses_model_absent_from_live_catalog() {
  local rec id out status
  id=profile-cursor-unsupported-z6d
  rec=$(make_spawn_case profile-cursor-unsupported cursor "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model cursor-grok-4.5)
  status=$?
  expect_code 1 "$status" "cursor spawn should refuse a model absent from a successful catalog"
  assert_contains "$out" "Cursor model 'cursor-grok-4.5' is not available" \
    "cursor model refusal did not identify the unavailable model"
  assert_contains "$out" "--list-models" \
    "cursor model refusal did not tell the caller how to find valid ids"
  [ ! -s "$LAUNCH_LOG" ] || fail "cursor model refusal must happen before launch"
  pass "cursor refuses model ids absent from its resolved binary's live catalog"
}

test_cursor_failed_catalog_probe_does_not_block_spawn() {
  local rec id out status launch
  id=profile-cursor-catalog-unreachable-z6e
  rec=$(make_spawn_case profile-cursor-catalog-unreachable cursor "$id")
  read_case_record "$rec"

  FM_TEST_CURSOR_LIST_STATUS=124 \
    out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
      --model cursor-catalog-unreachable)
  status=$?
  expect_code 0 "$status" "cursor spawn should fail open when the bounded catalog query fails"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "--model 'cursor-catalog-unreachable'" \
    "failed catalog lookup incorrectly removed the requested model"
  assert_meta_profile "$HOME_DIR/state/$id.meta" cursor cursor-catalog-unreachable default
  pass "cursor preserves the requested model when its live catalog is unreachable"
}

test_opencode_threads_model_and_ignores_effort_axis() {
  local rec id out status launch
  id=profile-opencode-z7
  rec=$(make_spawn_case profile-opencode opencode "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model anthropic/claude-sonnet-4-5 --effort high)
  status=$?
  expect_code 0 "$status" "opencode spawn with model and ignored effort should succeed"
  assert_meta_profile "$HOME_DIR/state/$id.meta" opencode anthropic/claude-sonnet-4-5 high
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "opencode --model 'anthropic/claude-sonnet-4-5' --prompt" \
    "opencode launch did not thread model"
  assert_not_contains "$launch" "--effort" "opencode launch must not pass unsupported --effort"
  assert_not_contains "$launch" "--variant" "opencode launch must not pass run-only --variant"
  assert_not_contains "$launch" "--thinking" "opencode launch must not pass pi thinking flag"
  jq -e '.launch_binding.model == "anthropic/claude-sonnet-4-5" and .launch_binding.effort == null' \
    "$(fm_test_routing_decision_path "$HOME_DIR" "$id")" >/dev/null \
    || fail "opencode receipt did not distinguish emitted model from metadata-only effort"
  pass "opencode receives --model and omits the unsupported effort axis"
}

test_pi_threads_model_and_max_effort() {
  local rec id out status launch
  id=profile-pi-z8
  rec=$(make_spawn_case profile-pi pi "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model openai-codex/gpt-5.6-sol --effort max)
  status=$?
  expect_code 0 "$status" "pi spawn with max effort should succeed"
  assert_meta_profile "$HOME_DIR/state/$id.meta" pi openai-codex/gpt-5.6-sol max
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "FM_PI_HARNESS=pi '$FAKEBIN_DIR/pi' --tui-mode regular --model 'openai-codex/gpt-5.6-sol' --thinking 'max' -e" \
    "pi launch did not force the regular TUI while threading the requested model and max thinking level"
  assert_not_contains "$launch" "FM_FIRSTMATE_PI_LAUNCH_BRIEF=" \
    "pi launch still exports the removed Calm input-reroute binding"
  assert_contains "$launch" "FIRSTMATE_OP: v1 launch-brief:" \
    "pi launch lost the canonical typed launch-brief envelope"
  pass "pi receives --model and --thinking max profile flags"
}

test_pi_signed_threads_shared_pi_profile_and_preserves_identity() {
  local rec id out status launch
  id=profile-pi-signed-z8b
  rec=$(make_spawn_case profile-pi-signed pi-signed "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model openai-codex/gpt-5.6-sol --effort max)
  status=$?
  expect_code 0 "$status" "pi-signed spawn with max effort should succeed"
  assert_contains "$out" "spawned $id harness=pi-signed" "pi-signed spawn did not preserve its visible identity"
  assert_meta_profile "$HOME_DIR/state/$id.meta" pi-signed openai-codex/gpt-5.6-sol max
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "FM_PI_HARNESS=pi-signed '$FAKEBIN_DIR/pi-signed' --tui-mode regular --model 'openai-codex/gpt-5.6-sol' --thinking 'max' -e" \
    "pi-signed launch did not force the regular TUI with Pi's model, thinking, and extension semantics"
  assert_contains "$launch" "FIRSTMATE_OP: v1 launch-brief:" \
    "pi-signed launch lost the canonical typed launch-brief envelope"
  assert_present "$HOME_DIR/state/$id.pi-ext.ts" "pi-signed launch did not install Pi's turn-end extension"
  assert_present "$HOME_DIR/state/$id.busy-gen" "pi-signed spawn did not arm the busy-state contract"
  assert_contains "$(cat "$HOME_DIR/state/$id.busy-state")" "state=busy source=fm-spawn" \
    "pi-signed spawn did not seed the busy-state record from the launch brief"
  local ext gen
  ext=$(cat "$HOME_DIR/state/$id.pi-ext.ts")
  gen=$(cat "$HOME_DIR/state/$id.busy-gen")
  assert_contains "$ext" 'pi.on("agent_start"' "pi extension lost the semantic agent_start busy edge"
  assert_contains "$ext" 'pi.on("agent_settled"' "pi extension lost the semantic agent_settled idle edge"
  assert_contains "$ext" 'ctx.isIdle()' "pi extension no longer confirms idle with ctx.isIdle()"
  assert_contains "$ext" "\"--gen\", \"$gen\"" "pi extension does not carry the armed incarnation gen"
  assert_contains "$ext" '"--source", "pi-ext"' "pi extension does not attribute its semantic source"
  assert_contains "$ext" 'pi.on("turn_end"' "pi extension lost the turn-end notification touch"
  pass "pi-signed shares Pi launch semantics while preserving its configured and recorded identity"
}

test_pi_tui_mode_probe_is_safe_for_old_and_new_pi() {
  local harness version rec id out status launch
  for harness in pi pi-signed; do
    for version in 0.82.0 0.84.0; do
      id="profile-${harness}-tui-${version//./}-z8d"
      rec=$(make_spawn_case "profile-__MODELFLAG__-${harness}-tui-${version//./}" "$harness" "$id")
      read_case_record "$rec"

      out=$(FM_TEST_PI_VERSION="$version" \
        run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
        "$id" "$PROJ_DIR")
      status=$?
      expect_code 0 "$status" "$harness $version spawn should succeed"
      launch=$(cat "$LAUNCH_LOG")
      assert_contains "$launch" "'$FAKEBIN_DIR/$harness'" \
        "$harness $version launch must use the executable selected for probing"
      assert_not_contains "$launch" "FM_PI_HARNESS=$harness $harness" \
        "$harness $version launch must not re-resolve a bare executable in the worker"
      if [ "$version" = 0.82.0 ]; then
        assert_not_contains "$launch" "--tui-mode" \
          "$harness $version launch must omit unsupported --tui-mode"
      else
        assert_contains "$launch" "'$FAKEBIN_DIR/$harness' --tui-mode regular" \
          "$harness $version launch must preserve the regular TUI"
      fi
    done
  done
  pass "Pi launch probing omits --tui-mode on older Pi and preserves it on supporting Pi"
}

test_pi_signed_missing_binary_refuses_before_endpoint_or_metadata() {
  local rec id out status
  id=profile-pi-signed-missing-z8c
  rec=$(make_spawn_case profile-pi-signed-missing pi-signed "$id")
  read_case_record "$rec"
  rm -f "$FAKEBIN_DIR/pi-signed"
  : > "$LAUNCH_LOG"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" PATH="$FAKEBIN_DIR:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1)
  status=$?
  expect_code 1 "$status" "a missing pi-signed executable should refuse the spawn"
  assert_contains "$out" "pi-signed executable not found on PATH" \
    "missing pi-signed refusal did not name the actionable requirement"
  assert_absent "$HOME_DIR/state/$id.meta" "missing pi-signed refusal wrote task metadata"
  [ ! -s "$LAUNCH_LOG" ] || fail "missing pi-signed refusal typed a launch command"
  pass "pi-signed refuses safely and actionably when the selected executable is unavailable"
}

test_pi_signed_persistent_secondmate_uses_pi_extensions_and_identity() {
  local rec id sm out status launch
  id=profile-pi-signed-secondmate-z8d
  rec=$(make_spawn_case profile-pi-signed-secondmate codex "$id")
  read_case_record "$rec"
  printf '%s\n' pi-signed > "$HOME_DIR/config/secondmate-harness"
  sm="$CASE_DIR/secondmate-home"
  make_seeded_secondmate_home "$sm" "$id"
  sm=$(cd "$sm" && pwd -P)

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$sm" --secondmate)
  status=$?
  expect_code 0 "$status" "pi-signed persistent secondmate spawn should succeed"
  assert_contains "$out" "spawned $id harness=pi-signed kind=secondmate" \
    "pi-signed secondmate spawn did not preserve its runtime identity"
  assert_meta_profile "$HOME_DIR/state/$id.meta" pi-signed default default
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "FM_PI_HARNESS=pi-signed '$FAKEBIN_DIR/pi-signed' --tui-mode regular -e '$sm/.pi/extensions/fm-primary-turnend-guard.ts' -e '$sm/.pi/extensions/fm-primary-pi-watch.ts'" \
    "pi-signed secondmate did not force the regular TUI with Pi's primary extension launch shape"
  pass "pi-signed is a distinct persistent secondmate runtime with shared Pi supervision semantics"
}

test_batch_forwards_shared_profile_flags() {
  local rec id1 id2 out status
  id1=profile-batch-a-z9
  id2=profile-batch-b-z10
  rec=$(make_spawn_case profile-batch claude "$id1" "$id2")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id1=$PROJ_DIR" "$id2=$PROJ_DIR" --harness codex --model gpt-5 --effort high)
  status=$?
  expect_code 0 "$status" "batch spawn with shared profile flags should succeed"
  assert_contains "$out" "spawned $id1 harness=codex" "first batch task did not use shared harness"
  assert_contains "$out" "spawned $id2 harness=codex" "second batch task did not use shared harness"
  assert_meta_profile "$HOME_DIR/state/$id1.meta" codex gpt-5 high
  assert_meta_profile "$HOME_DIR/state/$id2.meta" codex gpt-5 high
  pass "batch dispatch forwards shared --harness, --model, and --effort to every pair"
}

test_claude_forwards_firstmate_config_dir_when_set() {
  local rec id out status launch
  id=profile-claude-cfgdir-z17
  rec=$(make_spawn_case profile-claude-cfgdir claude "$id")
  read_case_record "$rec"

  out=$(FM_TEST_CLAUDE_CONFIG_DIR="/opt/test/claude-work" \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "claude spawn with CLAUDE_CONFIG_DIR set should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "CLAUDE_CONFIG_DIR='/opt/test/claude-work' env -u CURSOR_AGENT -u CURSOR_INVOKED_AS CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude" \
    "claude launch did not forward firstmate's CLAUDE_CONFIG_DIR to the crewmate pane"
  pass "claude forwards firstmate's CLAUDE_CONFIG_DIR so the crewmate uses the same credential store"
}

test_claude_omits_config_dir_prefix_when_unset() {
  local rec id out status launch
  id=profile-claude-nocfgdir-z18
  rec=$(make_spawn_case profile-claude-nocfgdir claude "$id")
  read_case_record "$rec"

  # run_spawn pins CLAUDE_CONFIG_DIR empty by default, exercising the single-store
  # default path where fm-spawn adds no prefix.
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "claude spawn without CLAUDE_CONFIG_DIR should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_not_contains "$launch" "CLAUDE_CONFIG_DIR=" \
    "claude launch must not add a config-dir prefix when firstmate has no CLAUDE_CONFIG_DIR set"
  pass "claude omits the config-dir prefix when firstmate runs with the single-store default"
}

test_non_claude_harness_ignores_config_dir() {
  local rec id out status launch
  id=profile-codex-nocfgdir-z19
  rec=$(make_spawn_case profile-codex-nocfgdir codex "$id")
  read_case_record "$rec"

  out=$(FM_TEST_CLAUDE_CONFIG_DIR="/opt/test/claude-work" \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "codex spawn with CLAUDE_CONFIG_DIR set should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_not_contains "$launch" "CLAUDE_CONFIG_DIR=" \
    "non-claude harness launch must not receive the claude-specific config-dir prefix"
  pass "non-claude harnesses do not receive the claude CLAUDE_CONFIG_DIR prefix"
}

test_active_dispatch_profile_does_not_block_secondmate_launch() {
  local rec id sm out status
  id=profile-secondmate-z16
  rec=$(make_spawn_case profile-secondmate codex "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"
  sm="$CASE_DIR/secondmate-home"
  make_seeded_secondmate_home "$sm" "$id"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$sm" --secondmate)
  status=$?
  expect_code 0 "$status" "secondmate spawn should be exempt from the dispatch-profile explicit harness requirement"
  assert_contains "$out" "spawned $id harness=codex kind=secondmate" "secondmate launch did not use secondmate harness resolution"
  assert_grep "kind=secondmate" "$HOME_DIR/state/$id.meta" "secondmate meta missing kind=secondmate"
  assert_meta_profile "$HOME_DIR/state/$id.meta" codex default default
  pass "active crew-dispatch profile does not block secondmate launches"
}

test_no_profile_keeps_claude_profile_defaults
test_non_cursor_launch_clears_inherited_cursor_markers
test_relative_home_overrides_launch_with_absolute_cross_process_paths
test_home_defaults_preserve_absolute_or_resolve_relative_paths
test_absolute_override_spelling_is_preserved_in_launch_paths
test_unresolvable_relative_overrides_fail_loudly
test_active_dispatch_profile_requires_explicit_harness_for_ship
test_active_dispatch_profile_requires_explicit_harness_for_scout
test_routing_receipt_is_unconditional_without_dispatch_config
test_config_override_cannot_relocate_receipt_authority
test_project_preflight_keeps_receipt_retryable
test_delivery_preflight_keeps_receipt_retryable
test_muse_credential_preflight_keeps_receipt_retryable
test_duplicate_spawn_preserves_active_routing_provenance
test_launch_uses_validated_brief_snapshot_after_source_replacement
test_launch_refuses_replaced_validated_brief_target
test_late_commit_failure_burns_generation_and_requires_fresh_receipt
test_raw_launches_refuse_unobserved_runtime_selection
test_active_dispatch_profile_allows_explicit_harness
test_active_dispatch_profile_allows_positional_harness
test_active_dispatch_profile_allows_raw_launch_command
test_raw_launch_allows_shell_quoted_punctuation
test_claude_threads_model_and_effort
test_codex_threads_model_and_effort
test_codex_omits_invalid_max_effort
test_grok_threads_model_and_reasoning_effort
test_grok_omits_invalid_max_reasoning_effort
test_grok_omits_invalid_xhigh_reasoning_effort
test_cursor_threads_model_workspace_and_omits_effort_axis
test_cursor_refuses_model_absent_from_live_catalog
test_cursor_failed_catalog_probe_does_not_block_spawn
test_opencode_threads_model_and_ignores_effort_axis
test_pi_threads_model_and_max_effort
test_pi_tui_mode_probe_is_safe_for_old_and_new_pi
test_pi_signed_threads_shared_pi_profile_and_preserves_identity
test_pi_signed_missing_binary_refuses_before_endpoint_or_metadata
test_pi_signed_persistent_secondmate_uses_pi_extensions_and_identity
test_batch_forwards_shared_profile_flags
test_claude_forwards_firstmate_config_dir_when_set
test_claude_omits_config_dir_prefix_when_unset
test_non_claude_harness_ignores_config_dir
test_active_dispatch_profile_does_not_block_secondmate_launch

echo "# all fm-spawn-dispatch-profile tests passed"
