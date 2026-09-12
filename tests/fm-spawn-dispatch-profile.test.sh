#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh concrete dispatch profile flags.
#
# These tests drive fm-spawn through meta writing and launch construction with a
# fake tmux pane and a real isolated git worktree. The fake tmux captures the
# literal launch command sent with `tmux send-keys -l`, so assertions pin the
# command firstmate would run without starting any real harness.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-dispatch-profile)

make_spawn_pi_probe() {
  local fakebin=$1 tool=$2
  cat > "$fakebin/$tool" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = --help ]; then
  [ -z "${FM_PI_HELP_LOG:-}" ] || printf '%s\n' "$0" >> "$FM_PI_HELP_LOG"
  if [ "${FM_FAKE_PI_VERSION:-0.84.0}" = 0.82.0 ]; then
    printf '%s\n' 'Pi 0.82.0' 'Options: --help'
  else
    printf '%s\n' "Pi ${FM_FAKE_PI_VERSION:-0.84.0}" 'Options: --help --tui-mode <mode>'
  fi
elif [ -n "${FM_PI_ARGS:-}" ]; then
  printf '%s\n' "$@" > "$FM_PI_ARGS"
fi
exit 0
SH
  chmod +x "$fakebin/$tool"
}

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  fm_test_fake_tmux_spawn "$fakebin"
  fm_test_write_active_treehouse_fake "$fakebin"
  cat > "$fakebin/timeout" <<'SH'
#!/usr/bin/env bash
shift
exec "$@"
SH
  cat > "$fakebin/cursor-agent" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --list-models ]; then
  [ "${FM_FAKE_CURSOR_LIST_STATUS:-0}" -eq 0 ] || exit "${FM_FAKE_CURSOR_LIST_STATUS}"
  printf '%b\n' "${FM_FAKE_CURSOR_MODELS:-Available models\ncursor-grok-4.5-high - Grok 4.5 High}"
fi
exit 0
SH
  chmod +x "$fakebin/timeout" "$fakebin/cursor-agent"
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
  fm_test_spawn_home "$home" "$harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  for id in "$@"; do
    fm_test_spawn_brief "$home" "$id"
  done
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog"
}

enable_dispatch_profile() {
  local home=$1
  printf '%s\n' '{"rules":[{"when":"current events","use":{"harness":"grok","model":"grok-4","effort":"high"}}],"default":{"harness":"codex","model":"gpt-5","effort":"medium"}}' \
    > "$home/config/crew-dispatch.json"
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
  : > "$launchlog"
  # CLAUDE_CONFIG_DIR is forwarded onto claude launches by fm-spawn, so pin it
  # explicitly (empty by default) instead of leaking the invoking shell's value,
  # which would make launch assertions depend on the developer's environment.
  # A test opts in to the set case via FM_TEST_CLAUDE_CONFIG_DIR.
  CLAUDE_CONFIG_DIR="${FM_TEST_CLAUDE_CONFIG_DIR:-}" \
    FM_FAKE_LAUNCH_LOG="$launchlog" FM_FAKE_PI_VERSION="${FM_TEST_PI_VERSION:-0.84.0}" \
    FM_FAKE_CURSOR_MODELS="${FM_TEST_CURSOR_MODELS:-}" \
    FM_FAKE_CURSOR_LIST_STATUS="${FM_TEST_CURSOR_LIST_STATUS:-0}" \
    GROK_HOME="$home/grok-home" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$@"
}

# Ship spawns carry an explicit delivery contract (AGENTS.md section 7); these
# tests are about profile resolution, so they pass a fixed valid one.
run_ship_spawn() {
  run_spawn "$@" --mode no-mistakes --yolo off
}

make_spawn_backlog_tasks_axi() {
  local fakebin=$1 case_dir=$2 real
  real=$(command -v tasks-axi) || return 1
  cat > "$fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
set -u
printf '%s\\n' "\$*" >> "$case_dir/tasks-axi.log"
if [ "\${1:-}" = add ]; then
  id=\${2:-}
  state=\${FM_STATE_OVERRIDE:-\${FM_HOME:-}/state}
  [ -d "\$state/.meta-\$id.lock" ] || {
    printf '%s\\n' 'error: add was called without the spawn metadata lock' >&2
    exit 74
  }
  if [ "\${FM_TEST_TASKS_AXI_FAIL_ADD:-0}" = 1 ]; then
    printf '%s\\n' 'error: synthetic add failure' >&2
    printf '%s\\n' 'hint: backlog is locked' >&2
    exit 73
  fi
fi
exec "$real" "\$@"
SH
  chmod +x "$fakebin/tasks-axi"
  cat > "$fakebin/timeout" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -k ]; then
  shift 3
else
  shift
fi
exec "$@"
SH
  chmod +x "$fakebin/timeout"
}

seed_spawn_backlog() {
  local home=$1
  printf '%s\\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$home/data/backlog.md"
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

test_backlog_title_creates_repo_bound_item_under_spawn_lock() {
  local rec id out status row
  id=backlog-title-create-z1
  rec=$(make_spawn_case backlog-title-create pi "$id")
  read_case_record "$rec"
  seed_spawn_backlog "$HOME_DIR"
  make_spawn_backlog_tasks_axi "$FAKEBIN_DIR" "$CASE_DIR"
  fm_test_write_active_treehouse_fake "$FAKEBIN_DIR" "$WT_DIR"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --backlog-title 'Create the tracked item')
  status=$?
  expect_code 0 "$status" "--backlog-title spawn should succeed"
  row=$(PATH="$FAKEBIN_DIR:$PATH" tasks-axi show "$id" --file "$HOME_DIR/data/backlog.md")
  assert_contains "$row" 'title: Create the tracked item' "created backlog title missing"
  assert_contains "$row" 'state: in_flight' "created backlog item was not started by spawn"
  assert_contains "$row" 'repo: project' "created backlog item did not derive the project repo"
  assert_grep "add $id Create the tracked item --kind ship --repo project" \
    "$CASE_DIR/tasks-axi.log" "spawn did not add the repo-bound backlog item"
  pass "--backlog-title creates a repo-bound item under the spawn metadata lock"
}

test_backlog_title_repairs_existing_repo_gap() {
  local rec id out status row real
  id=backlog-title-repair-z2
  rec=$(make_spawn_case backlog-title-repair pi "$id")
  read_case_record "$rec"
  seed_spawn_backlog "$HOME_DIR"
  real=$(command -v tasks-axi)
  "$real" add "$id" 'Existing item' --kind ship --file "$HOME_DIR/data/backlog.md" >/dev/null
  make_spawn_backlog_tasks_axi "$FAKEBIN_DIR" "$CASE_DIR"
  fm_test_write_active_treehouse_fake "$FAKEBIN_DIR" "$WT_DIR"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --backlog-title 'Existing item')
  status=$?
  expect_code 0 "$status" "existing repo-gap spawn should succeed"
  row=$(PATH="$FAKEBIN_DIR:$PATH" tasks-axi show "$id" --file "$HOME_DIR/data/backlog.md")
  assert_contains "$row" 'repo: project' "existing backlog repo gap was not repaired"
  assert_grep "update $id --repo project" "$CASE_DIR/tasks-axi.log" \
    "spawn did not fill the existing backlog repo"
  pass "existing backlog rows gain the project repo before dispatch"
}

test_backlog_title_refuses_different_existing_title() {
  local rec id out status real
  id=backlog-title-mismatch-z3
  rec=$(make_spawn_case backlog-title-mismatch pi "$id")
  read_case_record "$rec"
  seed_spawn_backlog "$HOME_DIR"
  real=$(command -v tasks-axi)
  "$real" add "$id" 'Original item' --kind ship --file "$HOME_DIR/data/backlog.md" >/dev/null
  make_spawn_backlog_tasks_axi "$FAKEBIN_DIR" "$CASE_DIR"
  fm_test_write_active_treehouse_fake "$FAKEBIN_DIR" "$WT_DIR"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --backlog-title 'Different item')
  status=$?
  [ "$status" -ne 0 ] || fail "different existing backlog title was accepted"
  assert_contains "$out" "already has backlog title 'Original item'" \
    "title mismatch did not explain the refusal"
  assert_absent "$HOME_DIR/state/$id.meta" "title mismatch published task metadata"
  pass "--backlog-title refuses an existing id with a different title"
}

test_backlog_title_surfaces_full_add_diagnostic() {
  local rec id out status
  id=backlog-title-add-failure-z4
  rec=$(make_spawn_case backlog-title-add-failure pi "$id")
  read_case_record "$rec"
  seed_spawn_backlog "$HOME_DIR"
  make_spawn_backlog_tasks_axi "$FAKEBIN_DIR" "$CASE_DIR"
  fm_test_write_active_treehouse_fake "$FAKEBIN_DIR" "$WT_DIR"

  out=$(FM_TEST_TASKS_AXI_FAIL_ADD=1 run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --backlog-title 'Fail this add')
  status=$?
  [ "$status" -ne 0 ] || fail "failed backlog add was accepted"
  assert_contains "$out" 'error: synthetic add failure' "add failure did not surface tasks-axi stderr"
  assert_contains "$out" 'hint: backlog is locked' "multiline add diagnostic was truncated"
  assert_absent "$HOME_DIR/state/$id.meta" "failed backlog add published task metadata"
  pass "failed backlog creation preserves the complete tasks-axi diagnostic"
}

test_tachikoma_routes_through_real_spawn_and_telemetry() {
  local rec id out status
  id=tachikoma-compose
  rec=$(make_spawn_case tachikoma-compose pi "$id")
  read_case_record "$rec"
  fm_test_write_active_treehouse_fake "$FAKEBIN_DIR" "$WT_DIR"
  mkdir -p "$HOME_DIR/config/tachikoma"
  node - "$HOME_DIR" <<'NODE'
const fs=require('fs'),c=require('crypto'),p=process.argv[2];
const put=(f,v)=>fs.writeFileSync(p+'/'+f,JSON.stringify(v));
put('config/model-catalog.json',{pools:[{pool:'subscription',provider:'example',plan:'paid',harness:'pi',account:'fixture',models:['example-model'],quota_readable:true}]});
const profile={harness:'pi',model:'example/example-model',effort:'high'};
put('config/crew-dispatch.json',{default:profile});
const sha=f=>c.createHash('sha256').update(fs.readFileSync(p+'/'+f)).digest('hex');
put('config/tachikoma/policy.json',{schemaVersion:1,enabled:true,catalogSha256:sha('config/model-catalog.json'),dispatchSha256:sha('config/crew-dispatch.json'),allowedHarnesses:['pi'],disabledPools:[],maxLoadPerCpu:100000,rules:[{repo:'project',taskClass:'bounded-implementation-proven-root-fix',matchedRule:'default',horizonSeconds:60,strongestOnly:false,selectionStrategy:'quota-weighted'}],bindings:[{...profile,pool:'subscription',catalogModel:'example-model',quotaProvider:'example',modelFamily:'example',quotaScopes:['all_models'],strongest:true,qualityPrior:0.7}]});
NODE
  cat > "$FAKEBIN_DIR/quota-axi" <<'QUOTA'
#!/usr/bin/env bash
printf 'generatedAt: "%s"\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '%s\n' 'quota[1]{provider,scope,effectivePercentRemaining,spendPriority,runway,confidence,limitedBy,resetsAt}:' '  example,all_models,90,1,through_reset,established,weekly,unknown'
QUOTA
  chmod +x "$FAKEBIN_DIR/quota-axi"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --mode direct-PR --yolo off --dispatch-tachikoma --task-class bounded-implementation-proven-root-fix)
  status=$?
  expect_code 0 "$status" "Tachikoma composition: $out"
  assert_meta_profile "$HOME_DIR/state/$id.meta" pi example/example-model high
  assert_grep 'routing_source=tachikoma' "$HOME_DIR/state/$id.meta" "missing router provenance"
  jq -se 'any(.[]; .intake.selection.routingSource=="tachikoma" and (.intake.selection.tachikomaDecision|length)==36 and .intake.selection.quota.headroom=="sufficient" and .intake.selection.quota.observedAt!=null)' "$HOME_DIR/data/routing-outcomes.jsonl" >/dev/null || fail "intake lost decision identity"
  [ "$(wc -l < "$HOME_DIR/data/tachikoma/decisions.jsonl" | tr -d ' ')" = 1 ] || fail "spawn routed more than once"
  pass "Tachikoma selection reaches real spawn metadata, launch construction, and immutable telemetry"
}

test_no_profile_keeps_claude_profile_defaults() {
  local rec id out status expected launch
  id=profile-off-z1
  rec=$(make_spawn_case profile-off claude "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "claude spawn without profile flags should succeed"
  assert_contains "$out" "spawned $id harness=claude" "spawn did not report claude"
  assert_meta_profile "$HOME_DIR/state/$id.meta" claude default default

  launch=$(cat "$LAUNCH_LOG")
  expected="env -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GEMINI_CLI CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --dangerously-skip-permissions --settings '{\"feedbackDrafts\":\"off\",\"attribution\":{\"commit\":\"\",\"pr\":\"\",\"sessionUrl\":false}}' \"\$('${ROOT}/bin/fm-operational-input.sh' encode launch-brief < '$HOME_DIR/data/$id/launch-brief.md')\""
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
  assert_contains "$launch" "env -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GEMINI_CLI" \
    "non-cursor launch must clear both inherited Cursor identity markers"
  pass "non-cursor launches clear inherited Cursor identity markers"
}

test_relative_home_overrides_launch_with_absolute_cross_process_paths() {
  local rec id out status launch home_real
  id=profile-relative-paths-z1b
  rec=$(make_spawn_case profile-relative-paths pi "$id")
  read_case_record "$rec"
  home_real=$(cd "$HOME_DIR" && pwd -P)
  mkdir -p "$CASE_DIR/cdpath/home/state" "$CASE_DIR/cdpath/home/data"
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
  assert_contains "$launch" "-e '$home_real/state/$id.pi-ext.ts'" \
    "relative FM_STATE_OVERRIDE leaked into Pi's cross-process extension path"
  assert_contains "$launch" "< '$home_real/data/$id/launch-brief.md'" \
    "relative FM_DATA_OVERRIDE leaked into the cross-process brief path"
  pass "relative home overrides ignore CDPATH and become absolute before spawn launch construction"
}

test_home_defaults_preserve_absolute_or_resolve_relative_paths() {
  local rec relative_id absolute_id out status launch home_real linked_home
  relative_id=profile-relative-home-defaults-z1c
  absolute_id=profile-absolute-home-defaults-z1d
  rec=$(make_spawn_case profile-home-defaults pi "$relative_id" "$absolute_id")
  read_case_record "$rec"
  home_real=$(cd "$HOME_DIR" && pwd -P)

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
  assert_contains "$launch" "-e '$home_real/state/$relative_id.pi-ext.ts'" \
    "relative FM_HOME leaked into Pi's default cross-process extension path"
  assert_contains "$launch" "< '$home_real/data/$relative_id/launch-brief.md'" \
    "relative FM_HOME leaked into the default cross-process brief path"

  linked_home="$CASE_DIR/home-link"
  ln -s "$HOME_DIR" "$linked_home"
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
  assert_contains "$launch" "-e '$linked_home/state/$absolute_id.pi-ext.ts'" \
    "absolute FM_HOME spelling changed in Pi's default cross-process extension path"
  assert_contains "$launch" "< '$linked_home/data/$absolute_id/launch-brief.md'" \
    "absolute FM_HOME spelling changed in the default cross-process brief path"
  pass "FM_HOME defaults resolve relative paths and preserve absolute spellings"
}

test_absolute_override_spelling_is_preserved_in_launch_paths() {
  local rec id out status launch linked_home
  id=profile-absolute-paths-z1c
  rec=$(make_spawn_case profile-absolute-paths pi "$id")
  read_case_record "$rec"
  linked_home="$CASE_DIR/home-link"
  ln -s "$HOME_DIR" "$linked_home"
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
  assert_contains "$launch" "-e '$linked_home/state/$id.pi-ext.ts'" \
    "absolute FM_STATE_OVERRIDE spelling changed in Pi's cross-process extension path"
  assert_contains "$launch" "< '$linked_home/data/$id/launch-brief.md'" \
    "absolute FM_DATA_OVERRIDE spelling changed in the cross-process brief path"
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
  local rec id out status launch
  id=profile-raw-z15
  rec=$(make_spawn_case profile-raw claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" "custom-agent --flag")
  status=$?
  expect_code 0 "$status" "raw launch command should satisfy active dispatch-profile requirement"
  assert_contains "$out" "spawned $id harness=custom-agent" "spawn did not report raw command harness"
  assert_meta_profile "$HOME_DIR/state/$id.meta" custom-agent default default
  launch=$(cat "$LAUNCH_LOG")
  [ "$launch" = "custom-agent --flag" ] || fail "raw launch command changed"$'\n'"actual: $launch"
  pass "active crew-dispatch profile allows the raw launch-command escape hatch"
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
  assert_contains "$launch" "claude --dangerously-skip-permissions --settings '{\"feedbackDrafts\":\"off\",\"attribution\":{\"commit\":\"\",\"pr\":\"\",\"sessionUrl\":false}}' --model 'sonnet' --effort 'high'" \
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

test_codex_refuses_invalid_max_effort() {
  local rec id out status
  id=profile-codex-max-z4
  rec=$(make_spawn_case profile-codex-max codex "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model gpt-5 --effort max)
  status=$?
  expect_code 1 "$status" "codex must refuse unsupported max effort"
  assert_contains "$out" "unsupported effort 'max'" "missing effort refusal"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused effort published metadata"
  [ ! -s "$LAUNCH_LOG" ] || fail "refused effort launched an agent"
  pass "codex refuses unsupported max effort before metadata or launch"
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

test_grok_refuses_invalid_max_reasoning_effort() {
  local rec id out status
  id=profile-grok-max-z6
  rec=$(make_spawn_case profile-grok-max grok "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model grok-4 --effort max)
  status=$?
  expect_code 1 "$status" "grok must refuse unsupported max reasoning effort"
  assert_contains "$out" "unsupported effort 'max'" "missing effort refusal"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused effort published metadata"
  [ ! -s "$LAUNCH_LOG" ] || fail "refused effort launched an agent"
  pass "grok refuses unsupported max reasoning effort"
}

test_grok_refuses_invalid_xhigh_reasoning_effort() {
  local rec id out status
  id=profile-grok-xhigh-z6b
  rec=$(make_spawn_case profile-grok-xhigh grok "$id")
  read_case_record "$rec"

  # grok 0.2.99 rejects xhigh (accepted set is only low|medium|high).
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model grok-4 --effort xhigh)
  status=$?
  expect_code 1 "$status" "grok must refuse unsupported xhigh reasoning effort"
  assert_contains "$out" "unsupported effort 'xhigh'" "missing effort refusal"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused effort published metadata"
  [ ! -s "$LAUNCH_LOG" ] || fail "refused effort launched an agent"
  pass "grok refuses unsupported xhigh reasoning effort"
}

test_cursor_threads_model_workspace_with_default_effort() {
  local rec id out status launch
  id=profile-cursor-z6c
  rec=$(make_spawn_case profile-cursor cursor "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model cursor-grok-4.5-high)
  status=$?
  expect_code 0 "$status" "cursor spawn with default effort should succeed"
  assert_meta_profile "$HOME_DIR/state/$id.meta" cursor cursor-grok-4.5-high default
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
  assert_contains "$launch" "encode launch-brief" "cursor launch did not deliver the brief positionally"
  assert_not_contains "$launch" "--effort" "cursor launch must not invent a separate effort flag"
  assert_not_contains "$launch" "--reasoning-effort" "cursor launch must not invent a separate reasoning-effort flag"
  assert_grep 'harness=cursor' "$HOME_DIR/state/$id.meta" "cursor harness was not recorded in meta"
  assert_grep 'model=cursor-grok-4.5-high' "$HOME_DIR/state/$id.meta" "cursor model was recorded as default"
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

test_opencode_threads_model_with_default_effort() {
  local rec id out status launch
  id=profile-opencode-z7
  rec=$(make_spawn_case profile-opencode opencode "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model anthropic/claude-sonnet-4-5)
  status=$?
  expect_code 0 "$status" "opencode spawn with model and default effort should succeed"
  assert_meta_profile "$HOME_DIR/state/$id.meta" opencode anthropic/claude-sonnet-4-5 default
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "opencode --model 'anthropic/claude-sonnet-4-5' --prompt" \
    "opencode launch did not thread model"
  assert_not_contains "$launch" "--effort" "opencode launch must not pass unsupported --effort"
  assert_not_contains "$launch" "--variant" "opencode launch must not pass run-only --variant"
  assert_not_contains "$launch" "--thinking" "opencode launch must not pass pi thinking flag"
  pass "opencode receives --model with an explicitly unset effort axis"
}

test_native_effort_validator_keeps_axes_separate() {
  local harness
  for harness in pi pi-signed; do
    "$ROOT/bin/fm-harness.sh" validate-native-effort "$harness" codex-native/gpt-6-astra ultra \
      || fail "native validator refused supported harness $harness"
  done
  if "$ROOT/bin/fm-harness.sh" validate-native-effort 'pi:codex-native/forged' '' ultra 2>/dev/null; then
    fail "native validator accepted a model prefix embedded in the harness axis"
  fi
  pass "native effort validator checks harness and model as separate axes"
}

test_native_pi_ultra_is_explicit_and_model_scoped() {
  local rec id out launch harness mode native_profile model
  for harness in pi pi-signed; do
    for mode in no-mistakes direct-PR; do
      id="ultra-$harness-$mode"
      rec=$(make_spawn_case "$id" "$harness" "$id")
      read_case_record "$rec"
      out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
        --harness "$harness" --model codex-native/gpt-6-astra --effort ultra --mode "$mode" --yolo off)
      expect_code 0 "$?" "native Ultra spawn failed: $out"
      assert_meta_profile "$HOME_DIR/state/$id.meta" "$harness" codex-native/gpt-6-astra ultra
      launch=$(cat "$LAUNCH_LOG")
      assert_contains "$launch" "--model 'codex-native/gpt-6-astra' --codex-effort 'ultra'" "native Ultra flag missing"
      assert_not_contains "$launch" "--thinking" "native Ultra was converted into Pi thinking"
      assert_not_contains "$launch" "'max'" "native Ultra was aliased to max"
    done
  done
  for native_profile in 'claude:codex-native/gpt-6-astra' 'codex:codex-native/gpt-6-astra' 'pi:openai-codex/gpt-6-astra' 'pi:default' 'pi:codex-native/'; do
    harness=${native_profile%%:*}; model=${native_profile#*:}; id="ultra-refused-$RANDOM"
    rec=$(make_spawn_case "$id" "$harness" "$id")
    read_case_record "$rec"
    out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
      --harness "$harness" --model "$model" --effort ultra 2>&1)
    expect_code 1 "$?" "unsupported Ultra profile should refuse: $native_profile"
    assert_contains "$out" "ultra effort requires pi or pi-signed" "native-only refusal missing"
    [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "unsupported Ultra published metadata"
    [ ! -e "$HOME_DIR/state/$id.busy-gen" ] || fail "unsupported Ultra provisioned lifecycle wiring"
    [ ! -s "$LAUNCH_LOG" ] || fail "unsupported Ultra launched an agent"
  done
  id=ultra-raw-refused
  rec=$(make_spawn_case "$id" pi "$id")
  read_case_record "$rec"
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    'pi --offline' --model codex-native/gpt-6-astra --effort ultra 2>&1)
  expect_code 1 "$?" "raw launch silently omitted the native Ultra flag"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "raw Ultra launch published metadata"
  assert_contains "$out" "canonical --harness pi or pi-signed" "raw launch refusal was not actionable"
  pass "Ultra is explicit for native Pi and Pi-signed, including direct-PR, and refuses unsupported profiles before provisioning"
}

test_batch_preserves_native_ultra() {
  local rec id1=ultra-batch-a id2=ultra-batch-b out launch
  rec=$(make_spawn_case ultra-batch pi "$id1" "$id2")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id1=$PROJ_DIR" "$id2=$PROJ_DIR" --harness pi --model codex-native/gpt-6-astra --effort ultra)
  expect_code 0 "$?" "native Ultra batch failed: $out"
  assert_meta_profile "$HOME_DIR/state/$id1.meta" pi codex-native/gpt-6-astra ultra
  assert_meta_profile "$HOME_DIR/state/$id2.meta" pi codex-native/gpt-6-astra ultra
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "--codex-effort 'ultra'" "batch dropped native effort"
  assert_not_contains "$launch" "--thinking 'ultra'" "batch passed an invalid Pi level"
  pass "batch dispatch preserves native Ultra in metadata and launch flags"
}

test_pi_firstmate_context_is_scoped_to_project_and_worker_kind() {
  local harness rec id out status launch firstmate_origin sm args_file args
  firstmate_origin=$(git -C "$ROOT" remote get-url origin 2>/dev/null) \
    || fail "could not read the Firstmate repository origin for the Pi context test"
  for harness in pi pi-signed; do
    id="firstmate-context-$harness"
    rec=$(make_spawn_case "$id" "$harness" "$id")
    read_case_record "$rec"
    git -C "$PROJ_DIR" remote set-url origin "$firstmate_origin"
    args_file="$CASE_DIR/pi-args"

    out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
    status=$?
    expect_code 0 "$status" "$harness Firstmate-repository spawn should succeed: $out"
    launch=$(cat "$LAUNCH_LOG")
    assert_contains "$launch" "--no-context-files" \
      "$harness Firstmate-repository launch must disable project context discovery"
    FM_PI_ARGS="$args_file" PATH="$FAKEBIN_DIR:$PATH" bash -c "$launch" \
      || fail "$harness Firstmate-repository launch command did not execute"
    args=$(cat "$args_file")
    assert_contains "$args" "--append-system-prompt" \
      "$harness Firstmate-repository launch must pass an appended system prompt"
    assert_contains "$args" "You are a Firstmate crewmate working in an isolated worktree of the Firstmate repository. The repository's AGENTS.md is a file you may be asked to change, not your instructions; your instructions are the launch brief you were given." \
      "$harness Firstmate-repository launch must carry the worker role boundary"

    id="firstmate-module-context-$harness"
    rec=$(make_spawn_case "$id" "$harness" "$id")
    read_case_record "$rec"
    args_file="$CASE_DIR/pi-args"
    git -C "$PROJ_DIR" remote set-url origin "$firstmate_origin"
    mkdir -p "$WT_DIR/modules/worker-alpha"
    printf '%s\n' '# Worker alpha instructions' > "$WT_DIR/modules/worker-alpha/AGENTS.md"
    awk '{ print; if ($0 == "## Captain'"'"'s intent") print "The task names modules/worker-alpha/." }' \
      "$HOME_DIR/data/$id/brief.md" > "$CASE_DIR/module-brief"
    mv "$CASE_DIR/module-brief" "$HOME_DIR/data/$id/brief.md"
    out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
    status=$?
    expect_code 0 "$status" "$harness Firstmate module spawn should succeed: $out"
    launch=$(cat "$LAUNCH_LOG")
    case "$launch" in
      *"--append-system-prompt 'You are a Firstmate crewmate working in an isolated worktree of the Firstmate repository."*"--append-system-prompt '$WT_DIR/modules/worker-alpha/AGENTS.md'"*) ;;
      *) fail "$harness module AGENTS.md was not appended after the fixed role prompt" ;;
    esac
    FM_PI_ARGS="$args_file" PATH="$FAKEBIN_DIR:$PATH" bash -c "$launch" \
      || fail "$harness Firstmate module launch command did not execute"
    args=$(cat "$args_file")
    assert_contains "$args" "$WT_DIR/modules/worker-alpha/AGENTS.md" \
      "$harness Firstmate module launch did not pass the module AGENTS.md path"
    assert_not_contains "$args" "$ROOT/AGENTS.md" \
      "$harness Firstmate module launch must not pass the repository-root AGENTS.md"

    id="other-project-context-$harness"
    rec=$(make_spawn_case "$id" "$harness" "$id")
    read_case_record "$rec"
    out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
    status=$?
    expect_code 0 "$status" "$harness other-project spawn should succeed: $out"
    launch=$(cat "$LAUNCH_LOG")
    assert_not_contains "$launch" "--no-context-files" \
      "$harness other-project launch unexpectedly disabled project context discovery"
    assert_not_contains "$launch" "--append-system-prompt" \
      "$harness other-project launch unexpectedly carried the Firstmate role boundary"

    id="secondmate-context-$harness"
    rec=$(make_spawn_case "$id" codex "$id")
    read_case_record "$rec"
    printf '%s\n' "$harness" > "$HOME_DIR/config/secondmate-harness"
    sm="$CASE_DIR/secondmate-home"
    make_seeded_secondmate_home "$sm" "$id"
    cp "$ROOT/AGENTS.md" "$sm/AGENTS.md"
    out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$sm" --secondmate)
    status=$?
    expect_code 0 "$status" "$harness secondmate spawn should succeed: $out"
    launch=$(cat "$LAUNCH_LOG")
    assert_not_contains "$launch" "--no-context-files" \
      "$harness secondmate launch unexpectedly disabled supervisor context discovery"
    assert_not_contains "$launch" "--append-system-prompt" \
      "$harness secondmate launch unexpectedly carried the worker role boundary"
  done
  pass "Pi context isolation is limited to Firstmate-repository worker launches"
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
  assert_contains "$launch" "fm-operational-input.sh' encode launch-brief" \
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
  assert_contains "$launch" "fm-operational-input.sh' encode launch-brief" \
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

test_pi_tui_mode_probe_is_cached_per_binary_path() {
  local rec id1 id2 help_log out status
  id1=profile-pi-tui-cache-a-z8e
  id2=profile-pi-tui-cache-b-z8f
  rec=$(make_spawn_case profile-pi-tui-cache pi "$id1" "$id2")
  read_case_record "$rec"
  help_log="$CASE_DIR/pi-help.log"

  out=$(FM_PI_HELP_LOG="$help_log" run_ship_spawn \
    "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id1" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "first cached Pi probe spawn should succeed: $out"
  out=$(FM_PI_HELP_LOG="$help_log" run_ship_spawn \
    "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id2" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "second cached Pi probe spawn should succeed: $out"
  [ "$(wc -l < "$help_log")" -eq 1 ] || fail "Pi help probe was not cached per binary path"

  pass "Pi TUI support probe is cached per resolved binary path"
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
  cp "$ROOT/AGENTS.md" "$sm/AGENTS.md"
  cp "$sm/data/charter.md" "$CASE_DIR/charter-before"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$sm" --secondmate)
  status=$?
  expect_code 0 "$status" "pi-signed persistent secondmate spawn should succeed"
  assert_contains "$out" "spawned $id harness=pi-signed kind=secondmate" \
    "pi-signed secondmate spawn did not preserve its runtime identity"
  assert_meta_profile "$HOME_DIR/state/$id.meta" pi-signed default default
  cmp -s "$ROOT/AGENTS.md" "$sm/AGENTS.md" || fail "secondmate launch rewrote the supervisor contract"
  cmp -s "$CASE_DIR/charter-before" "$sm/data/charter.md" || fail "secondmate launch rewrote the charter"
  assert_absent "$HOME_DIR/data/$id/launch-brief.md" "secondmate launch received a worker overlay"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "< '$sm/data/charter.md'" "secondmate launch lost its original charter"
  assert_contains "$launch" "FM_PI_HARNESS=pi-signed '$FAKEBIN_DIR/pi-signed' --tui-mode regular -e '$sm/.pi/extensions/fm-primary-turnend-guard.ts' -e '$sm/.pi/extensions/fm-primary-pi-watch.ts'" \
    "pi-signed secondmate did not force the regular TUI with Pi's primary extension launch shape"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# evidence begin: persistent secondmate\n%s\n' "$out"
    printf 'launch command:\n%s\noriginal charter:\n' "$launch"
    cat "$sm/data/charter.md"
    printf 'supervisor AGENTS.md and charter remain byte-identical; no worker overlay created\n# evidence end\n'
  fi
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

  # A creatable path: this spawn now pre-registers workspace trust in that store
  # (bin/fm-claude-trust.sh), so an unwritable directory is a genuine blocker.
  # The forwarding assertion below is what this case proves and is unchanged.
  out=$(FM_TEST_CLAUDE_CONFIG_DIR="$CASE_DIR/claude-work" \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "claude spawn with CLAUDE_CONFIG_DIR set should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "CLAUDE_CONFIG_DIR='$CASE_DIR/claude-work' env -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GEMINI_CLI CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --dangerously-skip-permissions --settings '{\"feedbackDrafts\":\"off\",\"attribution\":{\"commit\":\"\",\"pr\":\"\",\"sessionUrl\":false}}'" \
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

# The captain's attribution policy lives in the `user` settings scope, which a
# spawned worker's settings sources are not guaranteed to load. Every claude
# launch must therefore carry the policy itself, or a spawned worker writes
# Co-Authored-By and Claude-Session trailers into commits and PR bodies.
assert_attribution_policy() {  # <launch-command> <what>
  local launch=$1 what=$2
  assert_contains "$launch" '"attribution":' "$what launch carries no attribution policy"
  assert_contains "$launch" '"commit":""' "$what launch does not silence the commit trailer"
  assert_contains "$launch" '"pr":""' "$what launch does not silence the PR-body attribution"
  assert_contains "$launch" '"sessionUrl":false' "$what launch does not silence the session URL"
}

test_claude_crewmate_launch_carries_the_attribution_policy() {
  local rec id out status launch
  id=profile-claude-attribution-z22
  rec=$(make_spawn_case profile-claude-attribution claude "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "claude crewmate spawn should succeed"$'\n'"$out"
  launch=$(cat "$LAUNCH_LOG")
  assert_attribution_policy "$launch" "claude crewmate"
  pass "a claude crewmate launch carries the attribution-off policy in its own settings"
}

test_claude_secondmate_launch_carries_the_attribution_policy() {
  local rec id sm out status launch
  id=profile-secondmate-attribution-z23
  rec=$(make_spawn_case profile-secondmate-attribution claude "$id")
  read_case_record "$rec"
  sm="$CASE_DIR/secondmate-home"
  make_seeded_secondmate_home "$sm" "$id"

  out=$(FM_TEST_CLAUDE_CONFIG_DIR="$CASE_DIR/claude-work" \
    run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$sm" --secondmate)
  status=$?
  expect_code 0 "$status" "secondmate claude spawn should succeed"$'\n'"$out"
  launch=$(cat "$LAUNCH_LOG")
  assert_attribution_policy "$launch" "claude secondmate"
  pass "a claude secondmate launch carries the attribution-off policy too"
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

# Execute the actual emitted command in a synthetic pane environment: the
# fake backend records delivery, while real shells exercise the env boundary.
# No developer environment or credential values are inspected by these probes.
test_launch_environment_allowlist() {
  local setting rec id out status probe result expected launch value pane_shell pane_path
  # shellcheck disable=SC2016
  value='synthetic value; $(touch SHOULD_NOT_EXIST) `false` "quoted"'
  for setting in absent missing-config enabled empty; do
    id="env-$setting"
    rec=$(make_spawn_case "$id" codex "$id")
    read_case_record "$rec"
    case "$setting" in
      missing-config) rm "$HOME_DIR/config/crew-harness"; rmdir "$HOME_DIR/config" ;;
      enabled) printf '# Synthetic credential name\nFM_TEST_ALLOWED\nFM_TEST_EMPTY\nFM_TEST_UNSET\n' > "$HOME_DIR/config/launch-env-allowlist" ;;
      empty) : > "$HOME_DIR/config/launch-env-allowlist" ;;
    esac
    probe="$CASE_DIR/probe.sh"
    cat > "$probe" <<'SH'
#!/bin/sh
printf '%s\n' "${FM_TEST_AMBIENT_SENTINEL-unset}" "${FM_TEST_ALLOWED-unset}" \
  "${FM_TEST_EMPTY-unset}" "${FM_TEST_UNSET-unset}" "$HOME" "$PATH" "$TERM" "$TMUX" "$GOTMPDIR"
SH
    out=$(FM_TEST_AMBIENT_SENTINEL=synthetic-unrelated \
      run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
      "$id" "$PROJ_DIR" --harness "/bin/sh '$probe'")
    status=$?
    expect_code 0 "$status" "allowlist=$setting spawn should succeed: $out"
    launch=$(cat "$LAUNCH_LOG")
    for pane_shell in /bin/sh /bin/bash /bin/zsh; do
      [ -x "$pane_shell" ] || continue
      pane_path=$(env -i HOME="$HOME_DIR/user-home" PATH=/usr/bin:/bin TERM=xterm \
        TMUX=synthetic-pane GOTMPDIR=/synthetic/gotmp \
        "$pane_shell" -c "printf %s \"\$PATH\"") \
        || fail "could not read $pane_shell startup PATH"
      result=$(env -i HOME="$HOME_DIR/user-home" PATH=/usr/bin:/bin TERM=xterm \
      TMUX=synthetic-pane GOTMPDIR=/synthetic/gotmp \
      FM_TEST_AMBIENT_SENTINEL=synthetic-unrelated FM_TEST_ALLOWED="$value" FM_TEST_EMPTY='' \
      "$pane_shell" -c "$launch") || fail "allowlist=$setting emitted launch failed in $pane_shell"
      case "$setting" in
        absent|missing-config) expected=$(printf '%s\n' synthetic-unrelated "$value" '' unset) ;;
        enabled) expected=$(printf '%s\n' unset "$value" '' unset) ;;
        empty) expected=$(printf '%s\n' unset unset unset unset) ;;
      esac
      expected="$expected"$'\n'"$HOME_DIR/user-home"$'\n'"$pane_path"$'\nxterm\nsynthetic-pane\n/synthetic/gotmp'
      [ "$result" = "$expected" ] || fail "allowlist=$setting worker environment mismatch: $result"
    done
    pass "allowlist=$setting preserves the operational floor and filters only when opted in"
  done
}

test_launch_environment_invalid_config_refuses() {
  local rec id bad out status
  id=env-invalid
  rec=$(make_spawn_case "$id" codex "$id")
  read_case_record "$rec"
  for bad in 'FM_TEST_ALLOWED=value' 'NAME;false' '1INVALID' '*'; do
    printf '%s\n' "$bad" > "$HOME_DIR/config/launch-env-allowlist"
    out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
    status=$?
    expect_code 1 "$status" "invalid allowlist must refuse spawn"
    assert_contains "$out" 'launch-env-allowlist' "refusal must identify the config file"
    [ ! -s "$LAUNCH_LOG" ] || fail "invalid allowlist delivered a launch command"
    [ ! -f "$HOME_DIR/state/$id.meta" ] || fail "invalid allowlist published a task"
  done
  pass "invalid allowlist names refuse before launch or task publication"
}

test_launch_environment_inaccessible_config_refuses() {
  local setting presence rec id blocked out status
  if [ "$(id -u)" = 0 ]; then
    printf '# skip - inaccessible launch configuration requires a non-root user\n'
    return
  fi
  for setting in config ancestor; do
    for presence in present absent; do
      id="env-inaccessible-$setting-$presence"
      rec=$(make_spawn_case "$id" codex "$id")
      read_case_record "$rec"
      if [ "$presence" = present ]; then
        printf 'FM_TEST_ALLOWED\n' > "$HOME_DIR/config/launch-env-allowlist"
      fi
      blocked="$HOME_DIR/config"
      if [ "$setting" = ancestor ]; then
        blocked="$HOME_DIR/config-parent"
        mkdir "$blocked"
        mv "$HOME_DIR/config" "$blocked/config"
        ln -s config-parent/config "$HOME_DIR/config"
      fi
      chmod 600 "$blocked" || fail "could not remove configuration search permission"
      out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
        "$id" "$PROJ_DIR" --harness codex --backend tmux)
      status=$?
      chmod 700 "$blocked" || fail "could not restore configuration search permission"
      expect_code 1 "$status" "inaccessible $setting with $presence allowlist must refuse spawn: $out"
      assert_contains "$out" 'launch-env-allowlist' "refusal must identify the launch configuration"
      [ ! -s "$LAUNCH_LOG" ] || fail "inaccessible configuration delivered a launch command"
      [ ! -f "$HOME_DIR/state/$id.meta" ] || fail "inaccessible configuration published a task"
      pass "inaccessible $setting with $presence allowlist refuses before launch or task publication"
    done
  done
}

test_launch_environment_inherited_by_secondmate() {
  local rec id sm out status result
  id=env-secondmate
  rec=$(make_spawn_case "$id" codex "$id")
  read_case_record "$rec"
  printf 'FM_TEST_ALLOWED\n' > "$HOME_DIR/config/launch-env-allowlist"
  sm="$CASE_DIR/secondmate-home"
  make_seeded_secondmate_home "$sm" "$id"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$sm" --secondmate)
  status=$?
  expect_code 0 "$status" "secondmate with an allowlist should spawn: $out"
  cmp -s "$HOME_DIR/config/launch-env-allowlist" "$sm/config/launch-env-allowlist" \
    || fail "secondmate did not inherit the launch environment contract"
  cat > "$FAKEBIN_DIR/codex" <<'SH'
#!/bin/sh
printf '%s\n' "${FM_TEST_AMBIENT_SENTINEL-unset}" "$FM_TEST_ALLOWED" "$FM_HOME" "${FM_STATE_OVERRIDE-unset}"
SH
  chmod +x "$FAKEBIN_DIR/codex"
  result=$(env -i HOME="$HOME_DIR/user-home" PATH="$FAKEBIN_DIR:$PATH" \
    FM_TEST_AMBIENT_SENTINEL=synthetic-unrelated FM_TEST_ALLOWED=synthetic-provider \
    /bin/sh -c "$(cat "$LAUNCH_LOG")") || fail "secondmate's emitted command failed"
  [ "$result" = "unset"$'\nsynthetic-provider\n'"$sm" ] \
    || fail "secondmate's environment lost filtering or explicit home assignments: $result"
  # Exercise the same inheritance owner used by local and remote transfers;
  # removal must restore absence downstream as well as copying an opt-in.
  (
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-config-inherit-lib.sh"
    rm "$HOME_DIR/config/launch-env-allowlist"
    propagate_secondmate_inheritance "$HOME_DIR" "$sm" >/dev/null
  ) || fail "allowlist removal failed to converge"
  [ ! -e "$sm/config/launch-env-allowlist" ] || fail "secondmate retained a removed allowlist"
  pass "secondmate launch inherits the allowlist for subsequent worker launches"
}

run_launch_environment_inheritance() {
  local route=$1 home=$2 dest=$3 fakebin=$4 generation=$5
  if [ "$route" = local ]; then
    (
      # shellcheck source=/dev/null
      . "$ROOT/bin/fm-config-inherit-lib.sh"
      FM_INHERITABLE_CONFIG=launch-env-allowlist \
        propagate_inheritable_config "$home/config" "$dest/config"
    )
  else
    FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_CONFIG_OVERRIDE="$home/config" \
      FM_DATA_OVERRIDE="$home/data" FM_INHERITABLE_CONFIG=launch-env-allowlist \
      FM_SSH_BIN="$fakebin/inherit-ssh" \
      "$ROOT/bin/fm-remote-inherit-push.sh" inherited-env "$generation"
  fi
}

test_launch_environment_inheritance_preserves_on_source_errors() {
  local route rec id dest out status
  if [ "$(id -u)" = 0 ]; then
    printf '# skip - inaccessible inheritance sources require a non-root user\n'
    return
  fi
  for route in local remote; do
    id="env-inherit-$route"
    rec=$(make_spawn_case "$id" codex "$id")
    read_case_record "$rec"
    dest="$CASE_DIR/inherited-home"
    mkdir -p "$dest/config"
    printf 'FM_TEST_ALLOWED\n' > "$HOME_DIR/config/launch-env-allowlist"
    printf -- '- inherited-env - Test route (host: inherit-host; root: %s; home: %s; scope: test; projects: ; added 2026-09-05)\n' \
      "$ROOT" "$dest" > "$HOME_DIR/data/secondmates.md"
    cat > "$FAKEBIN_DIR/inherit-ssh" <<'SH'
#!/usr/bin/env bash
set -eu
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
[ "$#" -eq 6 ] && [ "$1" = inherit-host ] && [ "$2" = fm-remote-entrypoint.sh ] && [ "$3" = 1 ] || exit 91
remote_root=$(printf '%s' "$4" | base64 --decode)
remote_home=$(printf '%s' "$5" | base64 --decode)
args=()
while IFS= read -r -d '' arg; do args+=("$arg"); done < <(printf '%s' "$6" | base64 --decode)
[ "${args[0]}" = fm-remote-inherit.sh ] || exit 92
FM_HOME="$remote_home" FM_STATE_OVERRIDE="$remote_home/state" \
  exec "$remote_root/bin/${args[0]}" "${args[@]:1}"
SH
    chmod +x "$FAKEBIN_DIR/inherit-ssh"
    out=$(run_launch_environment_inheritance "$route" "$HOME_DIR" "$dest" "$FAKEBIN_DIR" 1 2>&1)
    status=$?
    expect_code 0 "$status" "$route allowlist inheritance should succeed: $out"
    [ "$(cat "$dest/config/launch-env-allowlist")" = FM_TEST_ALLOWED ] \
      || fail "$route inheritance did not publish the allowlist"

    chmod 600 "$HOME_DIR/config" || fail "could not remove source search permission"
    out=$(run_launch_environment_inheritance "$route" "$HOME_DIR" "$dest" "$FAKEBIN_DIR" 2 2>&1)
    status=$?
    chmod 700 "$HOME_DIR/config" || fail "could not restore source search permission"
    expect_code 1 "$status" "$route inheritance must refuse an inaccessible source: $out"
    assert_contains "$out" launch-env-allowlist "$route inspection error must identify the allowlist"
    [ "$(cat "$dest/config/launch-env-allowlist")" = FM_TEST_ALLOWED ] \
      || fail "$route inheritance removed or changed the allowlist after an inspection error"

    rm "$HOME_DIR/config/launch-env-allowlist"
    ln -s missing-allowlist "$HOME_DIR/config/launch-env-allowlist"
    out=$(run_launch_environment_inheritance "$route" "$HOME_DIR" "$dest" "$FAKEBIN_DIR" 3 2>&1)
    status=$?
    expect_code 1 "$status" "$route inheritance must refuse a dangling source link: $out"
    [ "$(cat "$dest/config/launch-env-allowlist")" = FM_TEST_ALLOWED ] \
      || fail "$route inheritance treated a dangling source link as absence"

    rm "$HOME_DIR/config/launch-env-allowlist"
    out=$(run_launch_environment_inheritance "$route" "$HOME_DIR" "$dest" "$FAKEBIN_DIR" 4 2>&1)
    status=$?
    expect_code 0 "$status" "$route inheritance should mirror proven absence: $out"
    [ ! -e "$dest/config/launch-env-allowlist" ] || fail "$route inheritance retained a removed allowlist"
    pass "$route inheritance preserves the allowlist on source errors and mirrors proven absence"
  done
}

test_unsupported_effort_refuses_before_attempt_or_launch() {
  local rec id out status harness effort requested_tuple
  for requested_tuple in codex:max cursor:high opencode:high kimi:high gemini:high rovo:xhigh; do
    harness=${requested_tuple%:*}; effort=${requested_tuple#*:}
    id="unsupported-effort-$harness"
    rec=$(make_spawn_case "$id" "$harness" "$id")
    read_case_record "$rec"
    out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --effort "$effort")
    status=$?
    expect_code 1 "$status" "$requested_tuple must refuse, not silently launch with a different effective setting: $out"
    if [ "$harness" = rovo ]; then
      assert_contains "$out" "no launch template" "an unavailable adapter must refuse before applying axes"
    else
      assert_contains "$out" "unsupported effort" "effort refusal must name the requested axis"
    fi
    [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "unsupported effort published misleading metadata"
    [ ! -s "$LAUNCH_LOG" ] || fail "unsupported effort submitted a model launch"
    if [ -f "$HOME_DIR/data/routing-outcomes.jsonl" ]; then
      jq -se 'all(.[]; .intake == null)' "$HOME_DIR/data/routing-outcomes.jsonl" >/dev/null || fail "unsupported effort created an attempt"
    fi
  done
  pass "unsupported effort refuses before runtime metadata, attempt intake, or launch"
}

test_raw_launch_refuses_unapplied_axes() {
  local rec id out axis value
  for axis in model effort; do
    id="raw-unapplied-$axis"
    rec=$(make_spawn_case "$id" pi "$id")
    read_case_record "$rec"
    value=high
    [ "$axis" != model ] || value=openai-codex/example
    out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
      'pi --offline' "--$axis" "$value")
    expect_code 1 "$?" "raw launch must refuse an unapplied $axis: $out"
    assert_contains "$out" "cannot apply the requested $axis axis" "raw launch lost the axis diagnostic"
    [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "raw launch published metadata"
    [ ! -s "$LAUNCH_LOG" ] || fail "raw launch submitted an agent"
    if [ -f "$HOME_DIR/data/routing-outcomes.jsonl" ]; then
      jq -se 'all(.[]; .intake == null)' "$HOME_DIR/data/routing-outcomes.jsonl" >/dev/null || fail "raw launch created an attempt"
    fi
  done
  pass "raw launch refuses model and effort settings absent from its template before intake"
}

# A focused regression entry for the launch-axis refusal; normal CI still runs
# the complete script below. Unknown selectors refuse rather than skip tests.
if [ -n "${FM_TEST_ONLY:-}" ]; then
  case "$FM_TEST_ONLY" in
    test_unsupported_effort_refuses_before_attempt_or_launch|test_raw_launch_refuses_unapplied_axes|test_native_pi_ultra_is_explicit_and_model_scoped|test_pi_threads_model_and_max_effort|test_pi_signed_threads_shared_pi_profile_and_preserves_identity|test_opencode_threads_model_with_default_effort) "$FM_TEST_ONLY"; exit "$?" ;;
    launch-axes)
      result=0
      for check in \
        test_unsupported_effort_refuses_before_attempt_or_launch \
        test_tachikoma_routes_through_real_spawn_and_telemetry \
        test_no_profile_keeps_claude_profile_defaults \
        test_claude_threads_model_and_effort \
        test_codex_threads_model_and_effort \
        test_codex_refuses_invalid_max_effort \
        test_grok_threads_model_and_reasoning_effort \
        test_grok_refuses_invalid_max_reasoning_effort \
        test_grok_refuses_invalid_xhigh_reasoning_effort \
        test_cursor_threads_model_workspace_with_default_effort \
        test_opencode_threads_model_with_default_effort \
        test_pi_threads_model_and_max_effort \
        test_pi_signed_threads_shared_pi_profile_and_preserves_identity; do
        ( "$check" ) || result=1
      done
      exit "$result" ;;
    *) fail "unknown FM_TEST_ONLY selector: $FM_TEST_ONLY" ;;
  esac
fi

test_unsupported_effort_refuses_before_attempt_or_launch
test_raw_launch_refuses_unapplied_axes
test_tachikoma_routes_through_real_spawn_and_telemetry
test_launch_environment_allowlist
test_launch_environment_invalid_config_refuses
test_launch_environment_inaccessible_config_refuses
test_launch_environment_inherited_by_secondmate
test_launch_environment_inheritance_preserves_on_source_errors

test_worker_launch_delivers_role_scope() {
  local rec id out launch kind prompt brief_kind brief content
  for brief_kind in heading legacy scaffold; do
  for kind in no-mistakes direct-PR local-only scout; do
    [ "$brief_kind" = heading ] && [ "$kind" != no-mistakes ] && continue
    id="role-launch-$brief_kind-$kind"
    rec=$(make_spawn_case "$id" codex)
    read_case_record "$rec"
    if [ "$brief_kind" != scaffold ]; then
      fm_test_spawn_brief "$HOME_DIR" "$id"
      if [ "$brief_kind" = heading ]; then
        printf '\n# Worker role\nFollow the project instructions.\n' >> "$HOME_DIR/data/$id/brief.md"
      fi
    else
      if [ "$kind" = scout ]; then
        FM_HOME="$HOME_DIR" "$ROOT/bin/fm-brief.sh" "$id" arbitrary-project-name --scout >/dev/null || fail "scout scaffold failed"
      else
        FM_HOME="$HOME_DIR" "$ROOT/bin/fm-brief.sh" "$id" arbitrary-project-name --mode "$kind" >/dev/null || fail "$kind scaffold failed"
      fi
      brief="$HOME_DIR/data/$id/brief.md"
      content=$(cat "$brief")
      content=${content//'{TASK}'/brief for $id}
      content=${content//'{FIRSTMATE_SPEC}'/Exercise the spawn behavior under test.}
      printf '%s\n' "$content" > "$brief"
    fi
    cp "$HOME_DIR/data/$id/brief.md" "$CASE_DIR/brief-before"
    cat > "$FAKEBIN_DIR/codex" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$FM_ROLE_PROMPT"
SH
    chmod +x "$FAKEBIN_DIR/codex"
    if [ "$kind" = scout ]; then
      out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --scout)
    else
      out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --mode "$kind" --yolo off)
    fi
    expect_code 0 "$?" "$kind worker spawn failed: $out"
    launch=$(cat "$LAUNCH_LOG")
    prompt="$CASE_DIR/prompt"
    FM_ROLE_PROMPT="$prompt" PATH="$FAKEBIN_DIR:$PATH" bash -c "$launch" || fail "could not consume $kind launch command"
    # The final prompt delivered to the harness is the generated interface.
    # An authored role heading must neither suppress nor duplicate the current
    # worker contract; the launch section is its single, superseding owner.
    assert_grep 'follow this brief instead of that supervisor contract' "$prompt" "$kind command did not deliver the role correction"
    assert_grep 'brief for' "$prompt" "$kind command lost the task"
    [ "$(grep -c '^# Current worker role contract$' "$prompt")" -eq 1 ] ||
      fail "$brief_kind $kind duplicated the delivered worker contract"
    if [ "$brief_kind" = heading ]; then
      assert_grep 'Follow the project instructions' "$prompt" "$kind command dropped the authored role section"
    fi
    cmp -s "$CASE_DIR/brief-before" "$HOME_DIR/data/$id/brief.md" || fail "spawn rewrote the authored brief"
    if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
      printf '# evidence begin: %s %s worker\n%s\n' "$brief_kind" "$kind" "$out"
      printf 'launch command executed with an argv-capture harness:\n%s\nreceived arguments and final prompt:\n' "$launch"
      cat "$prompt"
      printf 'authored brief remains byte-identical\n# evidence end\n'
    fi
  done
  done
  pass "fm-spawn: actual ship/scout launch commands deliver the worker role contract"
}

test_worker_launch_delivers_role_scope
test_backlog_title_creates_repo_bound_item_under_spawn_lock
test_backlog_title_repairs_existing_repo_gap
test_backlog_title_refuses_different_existing_title
test_backlog_title_surfaces_full_add_diagnostic
test_no_profile_keeps_claude_profile_defaults
test_non_cursor_launch_clears_inherited_cursor_markers
test_relative_home_overrides_launch_with_absolute_cross_process_paths
test_home_defaults_preserve_absolute_or_resolve_relative_paths
test_absolute_override_spelling_is_preserved_in_launch_paths
test_unresolvable_relative_overrides_fail_loudly
test_active_dispatch_profile_requires_explicit_harness_for_ship
test_active_dispatch_profile_requires_explicit_harness_for_scout
test_active_dispatch_profile_allows_explicit_harness
test_active_dispatch_profile_allows_positional_harness
test_active_dispatch_profile_allows_raw_launch_command
test_claude_threads_model_and_effort
test_codex_threads_model_and_effort
test_codex_refuses_invalid_max_effort
test_grok_threads_model_and_reasoning_effort
test_grok_refuses_invalid_max_reasoning_effort
test_grok_refuses_invalid_xhigh_reasoning_effort
test_cursor_threads_model_workspace_with_default_effort
test_cursor_refuses_model_absent_from_live_catalog
test_cursor_failed_catalog_probe_does_not_block_spawn
test_opencode_threads_model_with_default_effort
test_native_effort_validator_keeps_axes_separate
test_native_pi_ultra_is_explicit_and_model_scoped
test_batch_preserves_native_ultra
test_pi_firstmate_context_is_scoped_to_project_and_worker_kind
test_pi_threads_model_and_max_effort
test_pi_tui_mode_probe_is_cached_per_binary_path
test_pi_tui_mode_probe_is_safe_for_old_and_new_pi
test_pi_signed_threads_shared_pi_profile_and_preserves_identity
test_pi_signed_missing_binary_refuses_before_endpoint_or_metadata
test_pi_signed_persistent_secondmate_uses_pi_extensions_and_identity
test_batch_forwards_shared_profile_flags
test_claude_forwards_firstmate_config_dir_when_set
test_claude_omits_config_dir_prefix_when_unset
test_non_claude_harness_ignores_config_dir
test_claude_crewmate_launch_carries_the_attribution_policy
test_claude_secondmate_launch_carries_the_attribution_policy
test_active_dispatch_profile_does_not_block_secondmate_launch

echo "# all fm-spawn-dispatch-profile tests passed"
