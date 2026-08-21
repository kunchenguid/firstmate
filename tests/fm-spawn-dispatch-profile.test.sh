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
TEARDOWN="$ROOT/bin/fm-teardown.sh"
COOLDOWN="$ROOT/bin/fm-quota-cooldown.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-dispatch-profile)

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
  capture-pane) printf '%s\n' "${FM_FAKE_TMUX_CAPTURE:-}"; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|kill-window) exit 0 ;;
  new-window)
    [ -z "${FM_FAKE_ENDPOINT_LOG:-}" ] || printf 'created\n' >> "$FM_FAKE_ENDPOINT_LOG"
    exit 0
    ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      prev=
      for a in "$@"; do
        if [ "$prev" = "-l" ]; then
          printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG"
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
  fm_fake_exit0 "$fakebin" treehouse pi-signed no-mistakes gh-axi gh tasks-axi
  cat > "$fakebin/claude" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = auth ] && [ "${2:-}" = status ] && [ "${3:-}" = --json ]; then
  if [ -n "${FM_FAKE_CLAUDE_AUTH_STDIN_LOG:-}" ]; then
    if IFS= read -r fake_stdin_line; then
      printf 'read:%s\n' "$fake_stdin_line" >> "$FM_FAKE_CLAUDE_AUTH_STDIN_LOG"
    else
      printf 'eof\n' >> "$FM_FAKE_CLAUDE_AUTH_STDIN_LOG"
    fi
  fi
  # exec so the bounded runner's signal reaches the sleeping process itself and
  # no survivor keeps the captured stdout pipe open.
  [ "${FM_FAKE_CLAUDE_AUTH_HANG_SECONDS:-0}" = 0 ] || exec sleep "$FM_FAKE_CLAUDE_AUTH_HANG_SECONDS"
  printf '{"loggedIn":%s,"authMethod":"%s","apiProvider":"%s"}\n' \
    "${FM_FAKE_CLAUDE_LOGGED_IN:-true}" \
    "${FM_FAKE_CLAUDE_AUTH_METHOD:-claude.ai}" \
    "${FM_FAKE_CLAUDE_API_PROVIDER:-firstParty}"
  exit "${FM_FAKE_CLAUDE_AUTH_RC:-0}"
fi
printf 'profile=%s\n' "${CLAUDE_CONFIG_DIR:-absent}" >> "${FM_FAKE_CLAUDE_RUN_LOG:?}"
[ "${FM_FAKE_CLAUDE_HOLD_SECONDS:-0}" = 0 ] || sleep "$FM_FAKE_CLAUDE_HOLD_SECONDS"
SH
  chmod +x "$fakebin/claude"
  write_reviewer_quota_fixture "$fakebin" known known 100
  printf '%s\n' "$fakebin"
}

write_reviewer_quota_fixture() {
  local fakebin=$1 claude_status=$2 codex_status=$3 percent_remaining=$4
  cat > "$fakebin/quota-axi" <<EOF
#!/usr/bin/env bash
cat <<'JSON'
{"schemaVersion":3,"providers":[{"provider":"claude","quotaSemantics":{"effectiveAvailability":[{"scope":"all_models","status":"$claude_status","effectivePercentRemaining":$percent_remaining}]}},{"provider":"codex","quotaSemantics":{"effectiveAvailability":[{"scope":"all_models","status":"$codex_status","effectivePercentRemaining":$percent_remaining}]}}]}
JSON
EOF
  chmod +x "$fakebin/quota-axi"
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

record_dispatch_family_cooldown() {
  local home=$1 family=$2 expires=$3
  FM_HOME="$home" FM_QUOTA_COOLDOWN_NOW=2026-08-16T12:00:00Z \
    "$COOLDOWN" record --scope model-family --harness cursor-agent \
    --provider cursor --model-family "$family" \
    --evidence-kind provider-refusal \
    --evidence "You've hit your usage limit for $family; resets 9/14/2026" \
    --expires-at "$expires" >/dev/null
}

record_dispatch_provider_cooldown() {
  local home=$1 expires=$2
  FM_HOME="$home" FM_QUOTA_COOLDOWN_NOW=2026-08-16T12:00:00Z \
    "$COOLDOWN" record --scope provider --provider cursor \
    --evidence-kind quota-axi \
    --evidence "cursor all_models effectivePercentRemaining=0" \
    --expires-at "$expires" >/dev/null
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
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    CLAUDE_CONFIG_DIR="${FM_TEST_CLAUDE_CONFIG_DIR:-}" \
    FM_FAKE_LAUNCH_LOG="$launchlog" FM_FAKE_ENDPOINT_LOG="${FM_TEST_ENDPOINT_LOG:-}" \
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

make_claude_profile_dir() { # <path> -> physical path, owner-only like the documented setup
  local path=$1
  mkdir -p "$path"
  chmod 0700 "$path"
  (CDPATH='' cd -- "$path" && pwd -P)
}

write_claude_account_profile() {
  local home=$1 name=$2 dir=$3
  printf '%s=%s\n' "$name" "$dir" > "$home/config/claude-account-profiles"
  chmod 0600 "$home/config/claude-account-profiles"
}

write_two_claude_account_profiles() {
  local home=$1 name1=$2 dir1=$3 name2=$4 dir2=$5
  printf '%s=%s\n%s=%s\n' "$name1" "$dir1" "$name2" "$dir2" \
    > "$home/config/claude-account-profiles"
  chmod 0600 "$home/config/claude-account-profiles"
}

test_routing_source_recorded_only_when_declared() {
  local rec id out status
  id=profile-routing-source-z29
  rec=$(make_spawn_case routing-source codex "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model gpt-5 --effort medium --routing-source fallback)
  status=$?
  expect_code 0 "$status" "spawn with --routing-source fallback should succeed"
  assert_grep "routing_source=fallback" "$HOME_DIR/state/$id.meta" "meta missing routing_source=fallback"
  jq -es 'map(select(.eventType=="attempt-intake")) | .[0].intake.selection.routingSource=="fallback"' "$HOME_DIR/data/routing-outcomes.jsonl" >/dev/null \
    || fail "the declared routing source was not written into the intake row's selection"

  id=profile-routing-source-z30
  rec=$(make_spawn_case routing-source-absent codex "$id")
  read_case_record "$rec"
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model gpt-5 --effort medium)
  status=$?
  expect_code 0 "$status" "spawn without --routing-source should succeed"
  assert_no_grep "routing_source=" "$HOME_DIR/state/$id.meta" "undeclared routing source must stay absent (unknown provenance fails closed)"

  id=profile-routing-source-z31
  rec=$(make_spawn_case routing-source-invalid codex "$id")
  read_case_record "$rec"
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --routing-source vibes)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted an unrecognized --routing-source"
  assert_contains "$out" "--routing-source must be one of captain, profile, fallback" "invalid routing source refusal did not name the contract"
  [ ! -s "$LAUNCH_LOG" ] || fail "invalid routing source reached launch submission"
  assert_absent "$HOME_DIR/state/$id.meta" "invalid routing source published task metadata"
  pass "--routing-source records provenance in meta, stays absent when undeclared, and refuses unknown values"
}

test_spawn_writes_routing_facts_into_intake() {
  local rec id out status sel long_reason long_family long_provider empty_flag row
  id=profile-intake-facts-z2a
  rec=$(make_spawn_case intake-facts codex "$id")
  read_case_record "$rec"
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model gpt-5 --effort high --routing-source profile \
    --dispatch-provider openai --dispatch-model-family gpt-5 --dispatch-resolved)
  status=$?
  expect_code 0 "$status" "spawn with full routing-facts flags should succeed"
  sel=$(jq -es 'map(select(.eventType=="attempt-intake")) | .[0].intake.selection' "$HOME_DIR/data/routing-outcomes.jsonl")
  printf '%s' "$sel" | jq -e '.routingSource=="profile" and .dispatchModelFamily=="gpt-5" and .dispatchAttestation.kind=="resolved"' >/dev/null \
    || fail "the intake selection did not carry routingSource, dispatchModelFamily, and a resolved dispatchAttestation: $sel"
  jq -es 'map(select(.eventType=="attempt-intake")) | .[0].intake.tuple.provider=="openai"' "$HOME_DIR/data/routing-outcomes.jsonl" >/dev/null \
    || fail "the intake tuple did not carry the dispatch provider axis"

  # An override attestation carries its reason into the intake row.
  id=profile-intake-override-z2b
  rec=$(make_spawn_case intake-override codex "$id")
  read_case_record "$rec"
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model gpt-5 --effort high --routing-source captain \
    --dispatch-provider openai --dispatch-model-family gpt-5 \
    --dispatch-override-reason "captain raised the spend limit")
  status=$?
  expect_code 0 "$status" "spawn with an override attestation should succeed"
  sel=$(jq -es 'map(select(.eventType=="attempt-intake")) | .[0].intake.selection' "$HOME_DIR/data/routing-outcomes.jsonl")
  printf '%s' "$sel" | jq -e '.routingSource=="captain" and .dispatchAttestation.kind=="override" and .dispatchAttestation.reason=="captain raised the spend limit"' >/dev/null \
    || fail "the intake selection did not carry the override attestation and its reason: $sel"

  # A spawn with no dispatch axes leaves the additive fields absent so the
  # intake row stays the base five-key selection (backward compatible).
  id=profile-intake-bare-z2c
  rec=$(make_spawn_case intake-bare codex "$id")
  read_case_record "$rec"
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model gpt-5 --effort high)
  status=$?
  expect_code 0 "$status" "a bare spawn without dispatch axes should succeed"
  sel=$(jq -es 'map(select(.eventType=="attempt-intake")) | .[0].intake.selection' "$HOME_DIR/data/routing-outcomes.jsonl")
  printf '%s' "$sel" | jq -e '(has("routingSource")|not) and (has("dispatchAttestation")|not) and (has("dispatchModelFamily")|not)' >/dev/null \
    || fail "a bare spawn added additive routing-provenance fields it did not have evidence for: $sel"
  printf '%s' "$sel" | jq -e '.matchedRule==null and (.quota.decision=="unknown") and (.quota.headroom=="unknown") and (.quota.runway=="unknown")' >/dev/null \
    || fail "a bare spawn changed the base selection facts it should still default: $sel"

  # matched-rule and quota facts are written when firstmate passes them.
  id=profile-intake-quota-z2d
  rec=$(make_spawn_case intake-quota codex "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --harness codex --model gpt-5 --effort high --routing-source profile \
    --dispatch-provider openai --dispatch-model-family gpt-5 --dispatch-resolved \
    --matched-rule rule-3 --quota-decision selected --quota-headroom tight --quota-runway sufficient)
  status=$?
  expect_code 0 "$status" "spawn with matched-rule and quota facts should succeed"
  sel=$(jq -es 'map(select(.eventType=="attempt-intake")) | .[0].intake.selection' "$HOME_DIR/data/routing-outcomes.jsonl")
  printf '%s' "$sel" | jq -e '.matchedRule=="rule-3" and .quota.decision=="selected" and .quota.headroom=="tight" and .quota.runway=="sufficient"' >/dev/null \
    || fail "the intake selection did not carry the matched-rule and quota facts: $sel"
  assert_grep "matched_rule=rule-3" "$HOME_DIR/state/$id.meta" "meta missing matched_rule=rule-3"
  assert_grep "quota_decision=selected" "$HOME_DIR/state/$id.meta" "meta missing quota_decision=selected"
  assert_grep "quota_headroom=tight" "$HOME_DIR/state/$id.meta" "meta missing quota_headroom=tight"

  # An invalid matched-rule or quota value is refused before launch.
  id=profile-intake-bad-rule-z2e
  rec=$(make_spawn_case intake-bad-rule codex "$id")
  read_case_record "$rec"
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model gpt-5 --effort high --matched-rule vibes)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted an invalid --matched-rule"
  assert_contains "$out" "--matched-rule must be 'default' or 'rule-<n>'" "invalid matched-rule refusal did not name the contract"
  id=profile-intake-bad-quota-z2f
  rec=$(make_spawn_case intake-bad-quota codex "$id")
  read_case_record "$rec"
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model gpt-5 --effort high --quota-decision maybe)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted an invalid --quota-decision"
  assert_contains "$out" "--quota-decision must be one of" "invalid quota-decision refusal did not name the contract"

  # An empty value is a caller that computed nothing, not a caller that omitted
  # the flag, and every sibling flag refuses it rather than recording "unknown".
  for empty_flag in --matched-rule --quota-headroom --quota-runway; do
    id="profile-intake-empty${empty_flag//--/-}-z2h"
    rec=$(make_spawn_case "intake-empty${empty_flag//--/-}" codex "$id")
    read_case_record "$rec"
    out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
      --harness codex --model gpt-5 --effort high "$empty_flag" "")
    status=$?
    expect_code 1 "$status" "spawn accepted an empty $empty_flag"
    assert_contains "$out" "$empty_flag requires a non-empty value" "the empty $empty_flag refusal did not name the contract"
    [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "an empty $empty_flag published task metadata"
    row=$(jq -c 'select(.eventType=="spawn-failure")' "$HOME_DIR/data/routing-outcomes.jsonl" 2>/dev/null | head -n1)
    [ -n "$row" ] || fail "an empty $empty_flag left no spawn-failure row while its siblings record one"
    printf '%s' "$row" | jq -e --arg f "$empty_flag" '.failure.failureKind=="validation" and (.failure.cause|test($f))' >/dev/null \
      || fail "the empty $empty_flag refusal did not record its exact cause: $row"
  done

  # The ledger bounds the dispatch axes it stores, and nothing upstream bounds
  # what a captain types, so an over-long value must be recorded within the cap
  # rather than wedging a spawn that would otherwise have launched.
  id=profile-intake-long-axes-z2g
  rec=$(make_spawn_case intake-long-axes codex "$id")
  read_case_record "$rec"
  long_reason=$(printf 'r%.0s' $(seq 1 200))
  long_family=$(printf 'f%.0s' $(seq 1 120))
  long_provider=$(printf 'p%.0s' $(seq 1 120))
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --harness codex --model gpt-5 --effort high --routing-source captain \
    --dispatch-provider "$long_provider" --dispatch-model-family "$long_family" \
    --dispatch-override-reason "$long_reason")
  status=$?
  expect_code 0 "$status" "an over-long dispatch axis wedged a spawn that should have launched: $out"
  sel=$(jq -es 'map(select(.eventType=="attempt-intake")) | .[0].intake' "$HOME_DIR/data/routing-outcomes.jsonl")
  printf '%s' "$sel" | jq -e '(.selection.dispatchAttestation.reason|length)==160 and (.selection.dispatchModelFamily|length)==96 and (.tuple.provider|length)==96' >/dev/null \
    || fail "the intake row did not carry the dispatch axes within the caps the ledger enforces: $sel"
  printf '%s' "$sel" | jq -e '.selection.dispatchAttestation.kind=="override" and (.selection.dispatchAttestation.reason|test("^r+$"))' >/dev/null \
    || fail "the clamped attestation lost the reason it was recording: $sel"
  pass "fm-spawn writes routingSource, dispatch axes, and the dispatch attestation into the intake row, and omits them when absent"
}

test_recorded_default_axes_respawn_as_unset() {
  local rec id out status launch expected ledger
  id=profile-default-sentinel-z32
  rec=$(make_spawn_case default-sentinel claude "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model default --effort default --routing-source fallback)
  status=$?
  expect_code 0 "$status" "a relaunch re-passing the meta's recorded tuple should succeed"
  assert_meta_profile "$HOME_DIR/state/$id.meta" claude default default

  launch=$(cat "$LAUNCH_LOG")
  expected="GIT_CONFIG_COUNT='1' GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0='/tmp/fm-$id/git-hooks' CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions \"\$('${ROOT}/bin/fm-operational-input.sh' encode launch-brief < '$HOME_DIR/data/$id/brief.md')\""
  [ "$launch" = "$expected" ] || fail "recorded default axes did not launch identically to unset axes"$'\n'"expected: $expected"$'\n'"actual:   $launch"

  ledger="$HOME_DIR/data/routing-outcomes.jsonl"
  jq -es 'map(select(.eventType=="attempt-intake")) | length==1 and .[0].intake.tuple.model==null and .[0].intake.tuple.effort=="default"' "$ledger" >/dev/null \
    || fail "the recorded default tuple entered the routing ledger under a second spelling instead of one unset model axis"
  pass "a tuple recorded as model=default/effort=default respawns verbatim, launches as unset axes, and enters the ledger once"
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
  expected="GIT_CONFIG_COUNT='1' GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0='/tmp/fm-$id/git-hooks' CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions \"\$('${ROOT}/bin/fm-operational-input.sh' encode launch-brief < '$HOME_DIR/data/$id/brief.md')\""
  [ "$launch" = "$expected" ] || fail "no-profile claude launch did not use the canonical launch kind"$'\n'"expected: $expected"$'\n'"actual:   $launch"
  pass "no --model/--effort records defaults and types the claude launch instructions"
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
  assert_contains "$launch" "< '$home_real/data/$id/brief.md'" \
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
  assert_contains "$launch" "< '$home_real/data/$relative_id/brief.md'" \
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
  assert_contains "$launch" "< '$linked_home/data/$absolute_id/brief.md'" \
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
  assert_contains "$launch" "< '$linked_home/data/$id/brief.md'" \
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
    "$id" "$PROJ_DIR" --harness codex --model gpt-5 --effort high --dispatch-resolved)
  status=$?
  expect_code 0 "$status" "explicit harness should satisfy active dispatch-profile requirement"
  assert_contains "$out" "spawned $id harness=codex" "spawn did not report explicit codex harness"
  assert_meta_profile "$HOME_DIR/state/$id.meta" codex gpt-5 high
  assert_grep "dispatch=resolved" "$HOME_DIR/state/$id.meta" "explicit resolved attestation did not land in meta"
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
    "$id" "$PROJ_DIR" codex --model gpt-5 --effort high --dispatch-resolved)
  status=$?
  expect_code 0 "$status" "positional harness should satisfy active dispatch-profile requirement"
  assert_contains "$out" "spawned $id harness=codex" "spawn did not report positional codex harness"
  assert_meta_profile "$HOME_DIR/state/$id.meta" codex gpt-5 high
  assert_grep "dispatch=resolved" "$HOME_DIR/state/$id.meta" "positional resolved attestation did not land in meta"
  pass "active crew-dispatch profile allows the legacy positional harness form"
}

test_active_dispatch_profile_allows_raw_launch_command() {
  local rec id out status launch
  id=profile-raw-z15
  rm -rf "/tmp/fm-$id"
  rec=$(make_spawn_case profile-raw claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" "custom-agent --flag" --dispatch-resolved)
  status=$?
  expect_code 0 "$status" "raw launch command should satisfy active dispatch-profile requirement"
  assert_contains "$out" "spawned $id harness=custom-agent" "spawn did not report raw command harness"
  assert_meta_profile "$HOME_DIR/state/$id.meta" custom-agent default default
  assert_grep "dispatch=resolved" "$HOME_DIR/state/$id.meta" "raw-command resolved attestation did not land in meta"
  launch=$(cat "$LAUNCH_LOG")
  [ "$launch" = "custom-agent --flag" ] || fail "raw launch command changed"$'\n'"expected: custom-agent --flag"$'\n'"actual: $launch"
  assert_absent "/tmp/fm-$id/git-hooks/commit-msg" \
    "raw launch installed the ordinary-worker co-author sanitizer"
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
  assert_contains "$launch" "claude --dangerously-skip-permissions --model 'sonnet' --effort 'high'" \
    "claude launch did not thread model and effort flags"
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
  assert_contains "$launch" "grok --always-approve --model 'grok-4' \"\$('${ROOT}/bin/fm-operational-input.sh' encode launch-brief < " \
    "grok launch did not preserve the model flag and typed brief when max effort was omitted"
  assert_not_contains "$launch" "--reasoning-effort" "grok launch must omit unsupported max reasoning effort"
  assert_not_contains "$launch" "--effort" "grok launch must not fall back to --effort for reasoning effort"
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
  assert_contains "$launch" "grok --always-approve --model 'grok-4' \"\$('${ROOT}/bin/fm-operational-input.sh' encode launch-brief < " \
    "grok launch did not preserve the model flag and typed brief when xhigh effort was omitted"
  assert_not_contains "$launch" "--reasoning-effort" "grok launch must omit unsupported xhigh reasoning effort"
  assert_not_contains "$launch" "--effort" "grok launch must not fall back to --effort for reasoning effort"
  pass "grok omits unsupported xhigh reasoning effort"
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
  pass "opencode receives --model and omits the unsupported effort axis"
}

test_cursor_agent_threads_model_variant_and_records_effort() {
  local rec id out status launch
  id=profile-cursor-agent-z7b
  rec=$(make_spawn_case profile-cursor-agent cursor-agent "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model cursor-grok-4.6-high --effort high)
  status=$?
  expect_code 0 "$status" "cursor-agent spawn with a model-variant effort should succeed"
  assert_meta_profile "$HOME_DIR/state/$id.meta" cursor-agent cursor-grok-4.6-high high
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "cursor-agent --trust --force --model 'cursor-grok-4.6-high' \"\$('${ROOT}/bin/fm-operational-input.sh' encode launch-brief < " \
    "cursor-agent launch did not preserve the model variant and typed brief"
  assert_not_contains "$launch" "--effort" \
    "cursor-agent launch must not invent a separate effort flag"
  assert_not_contains "$launch" "--reasoning-effort" \
    "cursor-agent launch must not borrow another harness's effort flag"
  pass "cursor-agent receives the model variant while metadata preserves the selected effort axis"
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
  assert_contains "$launch" "FM_PI_HARNESS=pi pi --model 'openai-codex/gpt-5.6-sol' --thinking 'max' -e" \
    "pi launch did not thread the requested model and max thinking level"
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
  assert_contains "$launch" "FM_PI_HARNESS=pi-signed pi-signed --model 'openai-codex/gpt-5.6-sol' --thinking 'max' -e" \
    "pi-signed launch did not share Pi's model, thinking, and extension semantics"
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
  assert_contains "$launch" "FM_PI_HARNESS=pi-signed pi-signed -e '$sm/.pi/extensions/fm-primary-turnend-guard.ts' -e '$sm/.pi/extensions/fm-primary-pi-watch.ts'" \
    "pi-signed secondmate did not share Pi's primary extension launch shape"
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
    "$id1=$PROJ_DIR" "$id2=$PROJ_DIR" --harness codex --model gpt-5 --effort high --dispatch-resolved)
  status=$?
  expect_code 0 "$status" "batch spawn with shared profile flags should succeed"
  assert_contains "$out" "spawned $id1 harness=codex" "first batch task did not use shared harness"
  assert_contains "$out" "spawned $id2 harness=codex" "second batch task did not use shared harness"
  assert_meta_profile "$HOME_DIR/state/$id1.meta" codex gpt-5 high
  assert_meta_profile "$HOME_DIR/state/$id2.meta" codex gpt-5 high
  assert_grep "dispatch=resolved" "$HOME_DIR/state/$id1.meta" "batch did not forward attestation to first task meta"
  assert_grep "dispatch=resolved" "$HOME_DIR/state/$id2.meta" "batch did not forward attestation to second task meta"
  pass "batch dispatch forwards shared --harness, --model, and --effort to every pair"
}

test_claude_account_profile_binds_canonical_dir_and_records_alias_only() {
  local rec id out status profile_dir endpoint_log launch meta ledger run_log marker
  id=profile-claude-account-z43
  rec=$(make_spawn_case profile-claude-account claude "$id")
  read_case_record "$rec"
  profile_dir=$(make_claude_profile_dir "$CASE_DIR/profiles/account-\$(touch injected)")
  write_claude_account_profile "$HOME_DIR" paid-primary "$profile_dir"
  endpoint_log="$CASE_DIR/endpoints.log"
  : > "$endpoint_log"

  out=$(FM_TEST_ENDPOINT_LOG="$endpoint_log" \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
      "$id" "$PROJ_DIR" --account-profile paid-primary)
  status=$?
  expect_code 0 "$status" "authenticated claude account profile should spawn"
  [ "$(wc -l < "$endpoint_log" | tr -d ' ')" = 1 ] || fail "selected profile did not create exactly one endpoint"

  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "CLAUDE_CONFIG_DIR='$profile_dir' CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude" \
    "selected account profile did not bind its canonical directory to the claude launch"
  meta="$HOME_DIR/state/$id.meta"
  assert_grep "account_profile=paid-primary" "$meta" "selected account alias was not recorded in private task metadata"
  assert_no_grep "$profile_dir" "$meta" "task metadata leaked the selected config directory"
  ledger="$HOME_DIR/data/routing-outcomes.jsonl"
  jq -e 'select(.eventType=="attempt-intake") | .intake.tuple.accountProfile=="paid-primary" and .intake.selection.candidateAssessments[0].tuple.accountProfile=="paid-primary"' \
    "$ledger" >/dev/null || fail "model-attempt selection evidence did not record the selected account alias"
  assert_no_grep "$profile_dir" "$ledger" "model telemetry leaked the selected config directory"

  marker="$CASE_DIR/injected"
  run_log="$CASE_DIR/claude-run.log"
  (
    cd "$CASE_DIR" || exit 1
    PATH="$FAKEBIN_DIR:$PATH" FM_FAKE_CLAUDE_RUN_LOG="$run_log" bash -c "$launch"
  )
  assert_absent "$marker" "shell metacharacters from the canonical config directory executed during launch"
  [ "$(cat "$run_log")" = "profile=$profile_dir" ] \
    || fail "launched claude did not receive the selected config directory as one literal environment value"
  pass "claude account profile binds one canonical directory without shell re-parsing and records alias-only evidence"
}

test_two_claude_account_profiles_can_run_concurrently() {
  local rec id1 id2 out status dir1 dir2 launch1 launch2 run_log p1 p2 i lines
  id1=profile-claude-concurrent-a-z44
  id2=profile-claude-concurrent-b-z45
  rec=$(make_spawn_case profile-claude-concurrent claude "$id1" "$id2")
  read_case_record "$rec"
  dir1=$(make_claude_profile_dir "$CASE_DIR/profiles/one")
  dir2=$(make_claude_profile_dir "$CASE_DIR/profiles/two")
  write_two_claude_account_profiles "$HOME_DIR" paid-primary "$dir1" paid-secondary "$dir2"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id1" "$PROJ_DIR" --account-profile paid-primary)
  status=$?
  expect_code 0 "$status" "first isolated claude profile should spawn"
  launch1=$(cat "$LAUNCH_LOG")
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id2" "$PROJ_DIR" --account-profile paid-secondary)
  status=$?
  expect_code 0 "$status" "second isolated claude profile should spawn"
  launch2=$(cat "$LAUNCH_LOG")

  run_log="$CASE_DIR/concurrent-runs.log"
  PATH="$FAKEBIN_DIR:$PATH" FM_FAKE_CLAUDE_RUN_LOG="$run_log" FM_FAKE_CLAUDE_HOLD_SECONDS=5 bash -c "$launch1" &
  p1=$!
  PATH="$FAKEBIN_DIR:$PATH" FM_FAKE_CLAUDE_RUN_LOG="$run_log" FM_FAKE_CLAUDE_HOLD_SECONDS=5 bash -c "$launch2" &
  p2=$!
  i=0
  lines=0
  while [ "$i" -lt 50 ]; do
    if [ -f "$run_log" ]; then
      lines=$(wc -l < "$run_log" | tr -d ' ')
    else
      lines=0
    fi
    [ "$lines" = 2 ] && break
    sleep 0.1
    i=$((i + 1))
  done
  kill -0 "$p1" 2>/dev/null || fail "first claude profile was not live while the second started"
  kill -0 "$p2" 2>/dev/null || fail "second claude profile was not live with the first"
  kill "$p1" "$p2" 2>/dev/null || true
  wait "$p1" 2>/dev/null || true
  wait "$p2" 2>/dev/null || true
  [ "$lines" = 2 ] || fail "concurrent claude profile launches did not both reach the native command"
  [ "$(grep -Fxc "profile=$dir1" "$run_log")" = 1 ] || fail "first concurrent launch did not receive only its own profile"
  [ "$(grep -Fxc "profile=$dir2" "$run_log")" = 1 ] || fail "second concurrent launch did not receive only its own profile"
  pass "two isolated claude account profiles remain live concurrently and each receives only its own binding"
}

test_claude_account_profile_rejects_unsafe_mapping_before_endpoint() {
  local rec id out status endpoint_log profile_dir target

  id=profile-claude-missing-z46
  rec=$(make_spawn_case profile-claude-missing claude "$id")
  read_case_record "$rec"
  endpoint_log="$CASE_DIR/endpoints.log"
  : > "$endpoint_log"
  out=$(FM_TEST_ENDPOINT_LOG="$endpoint_log" run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --account-profile missing)
  status=$?
  expect_code 1 "$status" "missing account mapping should be refused"
  [ ! -s "$endpoint_log" ] || fail "missing account mapping created an endpoint"

  id=profile-claude-malformed-z47
  rec=$(make_spawn_case profile-claude-malformed claude "$id")
  read_case_record "$rec"
  printf 'malformed-record\n' > "$HOME_DIR/config/claude-account-profiles"
  chmod 0600 "$HOME_DIR/config/claude-account-profiles"
  endpoint_log="$CASE_DIR/endpoints.log"
  : > "$endpoint_log"
  out=$(FM_TEST_ENDPOINT_LOG="$endpoint_log" run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --account-profile paid-primary)
  status=$?
  expect_code 1 "$status" "malformed account mapping should be refused"
  [ ! -s "$endpoint_log" ] || fail "malformed account mapping created an endpoint"

  id=profile-claude-symlink-file-z48
  rec=$(make_spawn_case profile-claude-symlink-file claude "$id")
  read_case_record "$rec"
  profile_dir=$(make_claude_profile_dir "$CASE_DIR/profiles/one")
  target="$CASE_DIR/profile-map"
  printf 'paid-primary=%s\n' "$profile_dir" > "$target"
  chmod 0600 "$target"
  ln -s "$target" "$HOME_DIR/config/claude-account-profiles"
  endpoint_log="$CASE_DIR/endpoints.log"
  : > "$endpoint_log"
  out=$(FM_TEST_ENDPOINT_LOG="$endpoint_log" run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --account-profile paid-primary)
  status=$?
  expect_code 1 "$status" "symlink account mapping should be refused"
  [ ! -s "$endpoint_log" ] || fail "symlink account mapping created an endpoint"

  id=profile-claude-symlink-dir-z49
  rec=$(make_spawn_case profile-claude-symlink-dir claude "$id")
  read_case_record "$rec"
  mkdir -p "$CASE_DIR/profiles/real"
  ln -s "$CASE_DIR/profiles/real" "$CASE_DIR/profiles/link"
  write_claude_account_profile "$HOME_DIR" paid-primary "$CASE_DIR/profiles/link"
  endpoint_log="$CASE_DIR/endpoints.log"
  : > "$endpoint_log"
  out=$(FM_TEST_ENDPOINT_LOG="$endpoint_log" run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --account-profile paid-primary)
  status=$?
  expect_code 1 "$status" "symlink profile directory should be refused"
  [ ! -s "$endpoint_log" ] || fail "symlink profile directory created an endpoint"

  id=profile-claude-unsafe-name-z50
  rec=$(make_spawn_case profile-claude-unsafe-name claude "$id")
  read_case_record "$rec"
  endpoint_log="$CASE_DIR/endpoints.log"
  : > "$endpoint_log"
  out=$(FM_TEST_ENDPOINT_LOG="$endpoint_log" run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --account-profile '../paid-primary')
  status=$?
  expect_code 1 "$status" "unsafe account profile name should be refused"
  [ ! -s "$endpoint_log" ] || fail "unsafe account profile name created an endpoint"

  id=profile-claude-control-path-z56
  rec=$(make_spawn_case profile-claude-control-path claude "$id")
  read_case_record "$rec"
  profile_dir="$CASE_DIR/profiles/control"$'\033'"path"
  mkdir -p "$profile_dir"
  profile_dir=$(cd "$profile_dir" && pwd -P)
  write_claude_account_profile "$HOME_DIR" paid-primary "$profile_dir"
  endpoint_log="$CASE_DIR/endpoints.log"
  : > "$endpoint_log"
  out=$(FM_TEST_ENDPOINT_LOG="$endpoint_log" run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --account-profile paid-primary)
  status=$?
  expect_code 1 "$status" "control character in account profile path should be refused"
  [ ! -s "$endpoint_log" ] || fail "control-character account profile path created an endpoint"

  id=profile-claude-duplicate-name-z58
  rec=$(make_spawn_case profile-claude-duplicate-name claude "$id")
  read_case_record "$rec"
  write_two_claude_account_profiles "$HOME_DIR" \
    paid-primary "$(make_claude_profile_dir "$CASE_DIR/profiles/dup-a")" \
    paid-primary "$(make_claude_profile_dir "$CASE_DIR/profiles/dup-b")"
  endpoint_log="$CASE_DIR/endpoints.log"
  : > "$endpoint_log"
  out=$(FM_TEST_ENDPOINT_LOG="$endpoint_log" run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --account-profile paid-primary)
  status=$?
  expect_code 1 "$status" "repeated account profile name should be refused"
  [ ! -s "$endpoint_log" ] || fail "repeated account profile name created an endpoint"

  id=profile-claude-duplicate-dir-z59
  rec=$(make_spawn_case profile-claude-duplicate-dir claude "$id")
  read_case_record "$rec"
  profile_dir=$(make_claude_profile_dir "$CASE_DIR/profiles/shared")
  write_two_claude_account_profiles "$HOME_DIR" \
    paid-primary "$profile_dir" paid-secondary "$profile_dir"
  endpoint_log="$CASE_DIR/endpoints.log"
  : > "$endpoint_log"
  out=$(FM_TEST_ENDPOINT_LOG="$endpoint_log" run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --account-profile paid-primary)
  status=$?
  expect_code 1 "$status" "two names mapping to one directory should be refused"
  [ ! -s "$endpoint_log" ] || fail "duplicate account profile directory created an endpoint"
  pass "unsafe, malformed, missing, symlink, and duplicate account mappings are refused before endpoint creation"
}

test_claude_account_profile_requires_exact_paid_native_auth_predicate() {
  local rec id out status endpoint_log profile_dir

  id=profile-claude-auth-weaken-z51
  rec=$(make_spawn_case profile-claude-auth-weaken claude "$id")
  read_case_record "$rec"
  profile_dir=$(make_claude_profile_dir "$CASE_DIR/profiles/one")
  write_claude_account_profile "$HOME_DIR" paid-primary "$profile_dir"
  endpoint_log="$CASE_DIR/endpoints.log"
  : > "$endpoint_log"
  out=$(FM_TEST_ENDPOINT_LOG="$endpoint_log" FM_FAKE_CLAUDE_LOGGED_IN=false \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
      "$id" "$PROJ_DIR" --account-profile paid-primary)
  status=$?
  expect_code 1 "$status" "loggedIn=false with exit zero should be refused"
  [ ! -s "$endpoint_log" ] || fail "weakened loggedIn predicate created an endpoint"

  id=profile-claude-auth-constant-z52
  rec=$(make_spawn_case profile-claude-auth-constant claude "$id")
  read_case_record "$rec"
  profile_dir=$(make_claude_profile_dir "$CASE_DIR/profiles/one")
  write_claude_account_profile "$HOME_DIR" paid-primary "$profile_dir"
  endpoint_log="$CASE_DIR/endpoints.log"
  : > "$endpoint_log"
  out=$(FM_TEST_ENDPOINT_LOG="$endpoint_log" FM_FAKE_CLAUDE_AUTH_RC=1 \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
      "$id" "$PROJ_DIR" --account-profile paid-primary)
  status=$?
  expect_code 1 "$status" "auth status exit one with a true-looking body should be refused"
  [ ! -s "$endpoint_log" ] || fail "constant-true auth body created an endpoint despite native command refusal"

  id=profile-claude-auth-method-z53
  rec=$(make_spawn_case profile-claude-auth-method claude "$id")
  read_case_record "$rec"
  profile_dir=$(make_claude_profile_dir "$CASE_DIR/profiles/one")
  write_claude_account_profile "$HOME_DIR" paid-primary "$profile_dir"
  endpoint_log="$CASE_DIR/endpoints.log"
  : > "$endpoint_log"
  out=$(FM_TEST_ENDPOINT_LOG="$endpoint_log" FM_FAKE_CLAUDE_AUTH_METHOD=api_key \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
      "$id" "$PROJ_DIR" --account-profile paid-primary)
  status=$?
  expect_code 1 "$status" "non-subscription native auth method should be refused"
  [ ! -s "$endpoint_log" ] || fail "non-subscription auth method created an endpoint"
  pass "account binding requires native status success plus the exact paid first-party auth predicate"
}

test_claude_account_profile_requires_owner_only_directory() {
  local rec id_open id_private out status endpoint_log profile_dir
  id_open=profile-claude-dir-mode-z60
  id_private=profile-claude-dir-mode-ok-z61
  rec=$(make_spawn_case profile-claude-dir-mode claude "$id_open" "$id_private")
  read_case_record "$rec"
  profile_dir=$(make_claude_profile_dir "$CASE_DIR/profiles/one")
  write_claude_account_profile "$HOME_DIR" paid-primary "$profile_dir"
  endpoint_log="$CASE_DIR/endpoints.log"

  chmod 0755 "$profile_dir"
  : > "$endpoint_log"
  out=$(FM_TEST_ENDPOINT_LOG="$endpoint_log" run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id_open" "$PROJ_DIR" --account-profile paid-primary)
  status=$?
  expect_code 1 "$status" "a world-readable credential directory should be refused"
  [ ! -s "$endpoint_log" ] || fail "world-readable credential directory created an endpoint"
  assert_contains "$out" "must not be group- or world-accessible" \
    "the refusal did not name the directory permission invariant"

  chmod 0750 "$profile_dir"
  : > "$endpoint_log"
  out=$(FM_TEST_ENDPOINT_LOG="$endpoint_log" run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id_open" "$PROJ_DIR" --account-profile paid-primary)
  status=$?
  expect_code 1 "$status" "a group-readable credential directory should be refused"
  [ ! -s "$endpoint_log" ] || fail "group-readable credential directory created an endpoint"

  chmod 0700 "$profile_dir"
  : > "$endpoint_log"
  out=$(FM_TEST_ENDPOINT_LOG="$endpoint_log" run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id_private" "$PROJ_DIR" --account-profile paid-primary)
  status=$?
  expect_code 0 "$status" "the documented owner-only mode should still spawn"
  assert_grep "account_profile=paid-primary" "$HOME_DIR/state/$id_private.meta" \
    "owner-only profile directory did not bind and record the alias"
  pass "credential-bearing profile directories must be owner-only before endpoint creation"
}

test_claude_account_profile_auth_command_is_bounded_with_stdin_closed() {
  local rec id_stdin id_bound out status endpoint_log profile_dir stdin_log started elapsed
  id_stdin=profile-claude-auth-stdin-z62
  id_bound=profile-claude-auth-bound-z63
  rec=$(make_spawn_case profile-claude-auth-envelope claude "$id_stdin" "$id_bound")
  read_case_record "$rec"
  profile_dir=$(make_claude_profile_dir "$CASE_DIR/profiles/one")
  write_claude_account_profile "$HOME_DIR" paid-primary "$profile_dir"
  endpoint_log="$CASE_DIR/endpoints.log"
  stdin_log="$CASE_DIR/auth-stdin.log"
  : > "$endpoint_log"
  : > "$stdin_log"

  out=$(printf 'INJECTED-CAPTAIN-INPUT\n' \
    | FM_TEST_ENDPOINT_LOG="$endpoint_log" FM_FAKE_CLAUDE_AUTH_STDIN_LOG="$stdin_log" \
      run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
        "$id_stdin" "$PROJ_DIR" --account-profile paid-primary)
  status=$?
  expect_code 0 "$status" "authenticated profile should spawn with the caller holding stdin"
  assert_grep "eof" "$stdin_log" "the native auth command did not run with stdin closed"
  assert_no_grep "INJECTED-CAPTAIN-INPUT" "$stdin_log" \
    "caller stdin reached the native auth command, so an interactive prompt could consume it"

  : > "$endpoint_log"
  started=$(date +%s)
  out=$(FM_TEST_ENDPOINT_LOG="$endpoint_log" FM_FAKE_CLAUDE_AUTH_HANG_SECONDS=30 \
    FM_CLAUDE_ACCOUNT_PROFILE_TIMEOUT=1 \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
      "$id_bound" "$PROJ_DIR" --account-profile paid-primary)
  status=$?
  elapsed=$(( $(date +%s) - started ))
  expect_code 1 "$status" "a native auth command that never answers should refuse the spawn"
  [ ! -s "$endpoint_log" ] || fail "an unanswered native auth command created an endpoint"
  [ "$elapsed" -lt 15 ] \
    || fail "a hung native auth command wedged intake for ${elapsed}s instead of hitting its 1s bound"
  assert_contains "$out" "exceeded its 1s bound" \
    "the refusal did not report the hard bound as the reason"
  pass "the native auth command runs with stdin closed under a hard bound that refuses instead of wedging intake"
}

test_claude_account_profile_rejects_non_directory_before_endpoint() {
  local rec id out status endpoint_log profile_path
  id=profile-claude-nondir-z55
  rec=$(make_spawn_case profile-claude-nondir claude "$id")
  read_case_record "$rec"
  mkdir -p "$CASE_DIR/profiles"
  profile_path="$CASE_DIR/profiles/not-a-directory"
  touch "$profile_path"
  write_claude_account_profile "$HOME_DIR" paid-primary "$profile_path"
  endpoint_log="$CASE_DIR/endpoints.log"
  : > "$endpoint_log"

  out=$(FM_TEST_ENDPOINT_LOG="$endpoint_log" run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --account-profile paid-primary)
  status=$?
  expect_code 1 "$status" "regular file account profile path should be refused"
  [ ! -s "$endpoint_log" ] || fail "non-directory account profile path created an endpoint"
  pass "account profile paths must be directories before endpoint creation"
}

test_non_claude_harness_refuses_account_profile_before_endpoint() {
  local rec id out status endpoint_log profile_dir
  id=profile-codex-account-refusal-z54
  rec=$(make_spawn_case profile-codex-account-refusal codex "$id")
  read_case_record "$rec"
  profile_dir=$(make_claude_profile_dir "$CASE_DIR/profiles/one")
  write_claude_account_profile "$HOME_DIR" paid-primary "$profile_dir"
  endpoint_log="$CASE_DIR/endpoints.log"
  : > "$endpoint_log"

  out=$(FM_TEST_ENDPOINT_LOG="$endpoint_log" run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --account-profile paid-primary)
  status=$?
  expect_code 1 "$status" "non-claude harness should refuse the claude account-profile axis"
  [ ! -s "$endpoint_log" ] || fail "non-claude account-profile refusal created an endpoint"
  pass "only the verified native claude adapter accepts the account-profile axis"
}

test_secondmate_parent_refuses_home_local_account_profile() {
  local rec id sm out status endpoint_log profile_dir
  id=profile-secondmate-account-refusal-z57
  rec=$(make_spawn_case profile-secondmate-account-refusal claude "$id")
  read_case_record "$rec"
  printf '%s\n' claude > "$HOME_DIR/config/secondmate-harness"
  sm="$CASE_DIR/secondmate-home"
  make_seeded_secondmate_home "$sm" "$id"
  profile_dir=$(make_claude_profile_dir "$CASE_DIR/profiles/one")
  write_claude_account_profile "$HOME_DIR" paid-primary "$profile_dir"
  endpoint_log="$CASE_DIR/endpoints.log"
  : > "$endpoint_log"

  out=$(FM_TEST_ENDPOINT_LOG="$endpoint_log" run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$sm" --secondmate --account-profile paid-primary)
  status=$?
  expect_code 1 "$status" "secondmate parent launch should refuse a home-local account profile"
  assert_contains "$out" "run the account-profile mechanism inside that home" \
    "secondmate account-profile refusal did not name the home-local setup path"
  [ ! -s "$endpoint_log" ] || fail "secondmate account-profile refusal created an endpoint"
  pass "secondmate parent launches cannot transfer a home-local Claude account profile"
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
  assert_contains "$launch" "CLAUDE_CONFIG_DIR='/opt/test/claude-work' CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude" \
    "claude launch did not forward firstmate's CLAUDE_CONFIG_DIR to the crewmate pane"
  pass "claude forwards firstmate's CLAUDE_CONFIG_DIR so the crewmate uses the same credential store"
}

test_selected_account_profile_wins_over_ambient_config_dir() {
  local rec id out status profile_dir launch run_log
  id=profile-claude-account-precedence-z64
  rec=$(make_spawn_case profile-claude-account-precedence claude "$id")
  read_case_record "$rec"
  profile_dir=$(make_claude_profile_dir "$CASE_DIR/profiles/one")
  write_claude_account_profile "$HOME_DIR" paid-primary "$profile_dir"

  out=$(FM_TEST_CLAUDE_CONFIG_DIR="/opt/test/claude-work" \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
      "$id" "$PROJ_DIR" --account-profile paid-primary)
  status=$?
  expect_code 0 "$status" "a selected account profile should spawn while firstmate runs under its own store"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "CLAUDE_CONFIG_DIR='$profile_dir' CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude" \
    "the selected account profile did not bind the crewmate launch"
  assert_not_contains "$launch" "/opt/test/claude-work" \
    "firstmate's ambient CLAUDE_CONFIG_DIR reached an account-bound claude launch"
  run_log="$CASE_DIR/claude-run.log"
  (
    cd "$CASE_DIR" || exit 1
    PATH="$FAKEBIN_DIR:$PATH" FM_FAKE_CLAUDE_RUN_LOG="$run_log" bash -c "$launch"
  )
  [ "$(cat "$run_log")" = "profile=$profile_dir" ] \
    || fail "the launched claude resolved an account other than the selected profile"
  pass "a selected account profile wins over firstmate's ambient CLAUDE_CONFIG_DIR"
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

test_telemetry_precedes_submission_and_metadata_is_opaque() {
  local rec id out status meta ledger attempt terminal refusal_rec refusal_id
  id=profile-telemetry-z20
  rec=$(make_spawn_case profile-telemetry pi "$id")
  read_case_record "$rec"
  fm_fake_version_tool "$FAKEBIN_DIR" pi FM_TEST_PI_VERSION 'pi 0.82.0'
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model gpt-5 --effort high --task-class bounded-implementation-proven-root-fix --exploration)
  status=$?
  expect_code 0 "$status" "telemetry-backed spawn should succeed"
  meta="$HOME_DIR/state/$id.meta"
  ledger="$HOME_DIR/data/routing-outcomes.jsonl"
  grep -Eq '^telemetry_attempt=mra_' "$meta" || fail "spawn meta missing opaque telemetry attempt id"
  grep -Eq '^telemetry_task_root=mrt_' "$meta" || fail "spawn meta missing opaque telemetry task root"
  [ "$(grep -c '^telemetry_' "$meta")" -eq 2 ] || fail "spawn metadata contains telemetry fields beyond the two opaque ids"
  jq -e 'select(.eventType=="attempt-intake" and .intake.tuple.harness=="pi" and .intake.tuple.model=="gpt-5" and .intake.tuple.modelVersion=="gpt-5" and .intake.tuple.cliVersion=="pi 0.82.0" and .intake.tuple.effort=="high" and .intake.taskClass=="bounded-implementation-proven-root-fix" and .intake.exploration.kind=="deliberate" and (.intake.exploration.machineCondition.loadAverage1m|type)=="number" and (.intake.exploration.machineCondition.logicalCpuCount|type)=="number")' "$ledger" >/dev/null || fail "spawn did not durably record the model/version, task class, exploration tuple, and observed machine condition before submission"
  ! grep -F -- "$PROJ_DIR" "$ledger" >/dev/null || fail "spawn telemetry exposed the project path instead of its opaque reference"

  attempt=$(sed -n 's/^telemetry_attempt=//p' "$meta")
  terminal='{"classification":"accepted","refusalQuality":"not-applicable","endedAt":"2026-08-02T00:01:00Z","wallSeconds":60,"firstPassAccepted":true,"correctionCount":0,"interventionCount":0,"evidence":{"tests":"pass","reviewer":"not-run","oracle":"not-run","refs":[{"kind":"test","id":"spawn-teardown-e2e"}]},"outcomeLink":{"kind":"commit","id":"0123456789abcdef"},"usage":{"inputTokens":null,"outputTokens":null,"cost":null,"currency":null},"primaryFailureClass":"none","flags":{"tool":false,"transport":false,"environment":false,"externalWait":false,"scopeChange":false,"quota":false},"reclassification":{"fromTaskClass":null,"toTaskClass":null,"reasonCodes":["none"],"escalated":false}}'
  # shellcheck disable=SC2016 # Literal dollar spend is a captured harness fixture.
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_FAKE_TMUX_CAPTURE='↑109k ↓2.9k R383k CH87.9% $0.728 (sub) 38.5%/272k (auto)' PATH="$FAKEBIN_DIR:$PATH" \
    "$TEARDOWN" "$id" --force --terminal-payload "$terminal" >/dev/null 2>&1 \
    || fail "telemetry-backed spawn could not complete through real teardown"
  jq -es --arg attempt "$attempt" '
    map(select(.attemptId==$attempt)) |
    length==2 and .[0].eventType=="attempt-intake" and
    .[1].eventType=="attempt-terminal" and
    .[1].terminal.classification=="accepted" and
    .[1].terminal.evidence.refs[0].id=="spawn-teardown-e2e" and
    .[1].terminal.usage.cost==null and .[1].terminal.usage.currency==null
  ' "$ledger" >/dev/null || fail "spawn and teardown did not seal one end-to-end attempt with cost left absent"
  assert_absent "$meta" "real teardown left the completed task metadata behind"

  refusal_id=profile-telemetry-refusal-z21
  refusal_rec=$(make_spawn_case profile-telemetry-refusal codex "$refusal_id")
  read_case_record "$refusal_rec"
  ln -s "$CASE_DIR/unsafe-ledger-target" "$HOME_DIR/data/routing-outcomes.jsonl"
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$refusal_id" "$PROJ_DIR")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn proceeded after telemetry refusal"
  assert_contains "$out" "model telemetry intake refused; no model launch was submitted" "spawn refusal did not name the telemetry boundary"
  [ ! -s "$LAUNCH_LOG" ] || fail "telemetry refusal reached launch submission"
  assert_absent "$HOME_DIR/state/$refusal_id.meta" "telemetry refusal published task metadata"
  pass "spawn records only opaque telemetry ids and refuses telemetry failures before launch submission"
}

test_exploration_requires_an_explicit_rotated_model_and_effort() {
  local rec id id2 out status
  id=profile-exploration-missing-model-z24
  rec=$(make_spawn_case profile-exploration-missing-model pi "$id")
  read_case_record "$rec"
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --effort xhigh --task-class bounded-implementation-proven-root-fix --exploration)
  status=$?
  [ "$status" -ne 0 ] || fail "exploration accepted a tuple with no explicit rotated model"
  assert_contains "$out" "--exploration requires explicit --model and --effort values" "missing-model exploration refusal did not name the tuple contract"
  [ ! -s "$LAUNCH_LOG" ] || fail "missing-model exploration reached launch submission"
  assert_absent "$HOME_DIR/data/routing-outcomes.jsonl" "missing-model exploration recorded an attempt"

  id=profile-exploration-missing-effort-z25
  rec=$(make_spawn_case profile-exploration-missing-effort pi "$id")
  read_case_record "$rec"
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model gpt-5.6-sol --task-class bounded-implementation-proven-root-fix --exploration)
  status=$?
  [ "$status" -ne 0 ] || fail "exploration accepted a tuple with no explicit rotated effort"
  assert_contains "$out" "--exploration requires explicit --model and --effort values" "missing-effort exploration refusal did not name the tuple contract"
  [ ! -s "$LAUNCH_LOG" ] || fail "missing-effort exploration reached launch submission"
  assert_absent "$HOME_DIR/data/routing-outcomes.jsonl" "missing-effort exploration recorded an attempt"

  id=profile-exploration-default-effort-z26
  rec=$(make_spawn_case profile-exploration-default-effort pi "$id")
  read_case_record "$rec"
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model gpt-5.6-sol --effort default --task-class bounded-implementation-proven-root-fix --exploration)
  status=$?
  [ "$status" -ne 0 ] || fail "exploration accepted the unset-effort sentinel as a rotated effort"
  assert_contains "$out" "--exploration requires explicit --model and --effort values" "default-effort exploration refusal did not name the tuple contract"
  [ ! -s "$LAUNCH_LOG" ] || fail "default-effort exploration reached launch submission"
  assert_absent "$HOME_DIR/data/routing-outcomes.jsonl" "default-effort exploration recorded an attempt"

  id=profile-exploration-default-model-z27
  rec=$(make_spawn_case profile-exploration-default-model pi "$id")
  read_case_record "$rec"
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model default --effort high --task-class bounded-implementation-proven-root-fix --exploration)
  status=$?
  [ "$status" -ne 0 ] || fail "exploration accepted the unset-model sentinel as a rotated model"
  assert_contains "$out" "--exploration requires explicit --model and --effort values" "default-model exploration refusal did not name the tuple contract"
  [ ! -s "$LAUNCH_LOG" ] || fail "default-model exploration reached launch submission"
  assert_absent "$HOME_DIR/data/routing-outcomes.jsonl" "default-model exploration recorded an attempt"

  id=profile-exploration-batch-default-model-z28
  id2=profile-exploration-batch-default-model-z29
  rec=$(make_spawn_case profile-exploration-batch-default-model pi "$id" "$id2")
  read_case_record "$rec"
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id=$PROJ_DIR" "$id2=$PROJ_DIR" \
    --model default --effort high --task-class bounded-implementation-proven-root-fix --exploration)
  status=$?
  [ "$status" -ne 0 ] || fail "batch exploration accepted the unset-model sentinel as a rotated model"
  assert_not_contains "$out" "batch: FAILED to spawn" "batch exploration dispatched pairs the parent should have refused up front"
  assert_absent "$HOME_DIR/state/$id.meta" "refused batch exploration published task metadata"
  assert_absent "$HOME_DIR/state/$id2.meta" "refused batch exploration published second-pair metadata"
  pass "deliberate exploration requires an explicit rotated model and effort before intake or submission, on single and batch dispatch"
}

test_no_mistakes_spawn_requires_one_quota_eligible_reviewer() {
  local rec operator_home exhausted_id uncertain_id override_id out status
  exhausted_id=profile-reviewers-exhausted-z26
  uncertain_id=profile-reviewers-uncertain-z27
  override_id=profile-reviewers-override-z28
  rec=$(make_spawn_case profile-reviewer-quota codex "$exhausted_id" "$uncertain_id" "$override_id")
  read_case_record "$rec"
  operator_home="$CASE_DIR/operator-home"
  mkdir -p "$operator_home/.no-mistakes"
  printf '%s\n' 'agent: [claude, codex]' > "$operator_home/.no-mistakes/config.yaml"

  write_reviewer_quota_fixture "$FAKEBIN_DIR" known known 0
  out=$(HOME="$operator_home" run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$exhausted_id" "$PROJ_DIR")
  status=$?
  [ "$status" -ne 0 ] || fail "no-mistakes spawn started with every configured reviewer exhausted"
  assert_contains "$out" "claude=exhausted" "reviewer-quota refusal did not report Claude's result"
  assert_contains "$out" "codex=exhausted" "reviewer-quota refusal did not report Codex's result"
  assert_contains "$out" "--allow-no-mistakes-without-reviewer-quota" "reviewer-quota refusal did not name the captain-authorized override"
  [ ! -s "$LAUNCH_LOG" ] || fail "reviewer-quota refusal reached launch submission"
  assert_absent "$HOME_DIR/state/$exhausted_id.meta" "reviewer-quota refusal published task metadata"

  write_reviewer_quota_fixture "$FAKEBIN_DIR" known unknown 0
  out=$(HOME="$operator_home" run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$uncertain_id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "unmeasurable reviewer quota must remain eligible"
  assert_contains "$out" "codex=unmeasurable" "eligible uncertainty was not disclosed"

  write_reviewer_quota_fixture "$FAKEBIN_DIR" known known 0
  out=$(HOME="$operator_home" run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$override_id" "$PROJ_DIR" --allow-no-mistakes-without-reviewer-quota)
  status=$?
  expect_code 0 "$status" "captain-authorized reviewer-quota override should allow the spawn"
  assert_contains "$out" "captain-authorized reviewer-quota override" "override did not disclose the exhausted reviewer results"
  pass "no-mistakes spawn requires one quota-eligible reviewer unless explicitly overridden"
}

test_linked_telemetry_identifiers_chain_one_task_root() {
  local rec first_id retry_id out status ledger attempt root
  first_id=profile-telemetry-root-z22
  retry_id=profile-telemetry-retry-z23
  rec=$(make_spawn_case profile-telemetry-link codex "$first_id" "$retry_id")
  read_case_record "$rec"
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$first_id" "$PROJ_DIR" --model gpt-5 --effort medium)
  status=$?
  expect_code 0 "$status" "first linked-telemetry spawn should succeed"
  attempt=$(sed -n 's/^telemetry_attempt=//p' "$HOME_DIR/state/$first_id.meta")
  root=$(sed -n 's/^telemetry_task_root=//p' "$HOME_DIR/state/$first_id.meta")

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$retry_id" "$PROJ_DIR" \
    --model gpt-5.6-sol --effort xhigh --telemetry-task-root "$root" --telemetry-parent "$attempt")
  status=$?
  expect_code 0 "$status" "linked retry spawn should succeed"
  ledger="$HOME_DIR/data/routing-outcomes.jsonl"
  [ "$(sed -n 's/^telemetry_task_root=//p' "$HOME_DIR/state/$retry_id.meta")" = "$root" ] || fail "linked retry left its task root"
  jq -e --arg r "$root" --arg p "$attempt" 'select(.eventType=="attempt-intake" and .intake.taskRootId==$r and .intake.parentAttemptId==$p and .intake.tuple.model=="gpt-5.6-sol" and .intake.tuple.effort=="xhigh")' "$ledger" >/dev/null || fail "linked retry did not record its escalated tuple under the prior root and parent"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$retry_id" "$PROJ_DIR" --telemetry-task-root ../../etc/passwd)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a non-opaque telemetry task root"
  assert_contains "$out" "--telemetry-task-root requires an opaque mrt UUID" "non-opaque root refusal did not name the identifier contract"
  [ ! -s "$LAUNCH_LOG" ] || fail "non-opaque telemetry root reached launch submission"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$retry_id" "$PROJ_DIR" --telemetry-parent "$attempt")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a parent attempt without its task root"
  assert_contains "$out" "--telemetry-parent requires --telemetry-task-root" "orphan parent refusal did not name the missing root"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$first_id=$PROJ_DIR" "$retry_id=$PROJ_DIR" --telemetry-task-root "$root")
  status=$?
  [ "$status" -ne 0 ] || fail "batch dispatch accepted per-attempt telemetry identifiers"
  assert_contains "$out" "not supported by batch dispatch" "batch refusal did not name the per-attempt boundary"
  [ ! -s "$LAUNCH_LOG" ] || fail "batch telemetry refusal reached launch submission"
  pass "linked telemetry identifiers chain a retry under one task root and are refused when unsafe, orphaned, or batched"
}

# --- dispatch attestation backstop ------------------------------------------
#
# The explicit-harness guard above only proves *something* was passed. The
# measured failure it was built from (2026-08-15) was firstmate hand-picking an
# explicit harness for every dispatch while crew-dispatch.json sat on disk
# unread, so the guard stayed green while the rule was broken. The attestation
# backstop closes that gap: when profiles are active, an explicit harness must
# be accompanied by a declaration of HOW it was chosen - either --dispatch-resolved
# (firstmate consulted the profiles) or --dispatch-override-reason "<why>"
# (firstmate deliberately departed). A bare explicit harness is refused, because
# that is the silent hand-pick the guard exists to catch. The guard never reads
# crew-dispatch.json to verify the harness matches; it checks that resolution
# HAPPENED, not what it produced, and records the override reason in meta.

test_active_profile_refuses_explicit_harness_without_attestation() {
  local rec id resolved_id out status
  # The bare explicit harness is the silent hand-pick the guard exists to catch.
  id=profile-no-attestation-z30
  rec=$(make_spawn_case profile-no-attestation claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness codex --model gpt-5 --effort high)
  status=$?
  expect_code 1 "$status" "explicit harness without attestation should be refused when profiles are active"
  assert_contains "$out" "config/crew-dispatch.json is active" \
    "refusal did not name the active dispatch profile file"
  assert_contains "$out" "--dispatch-resolved" "refusal did not name the resolved attestation flag"
  assert_contains "$out" "--dispatch-override-reason" "refusal did not name the override attestation flag"
  assert_absent "$HOME_DIR/state/$id.meta" "refusal should happen before meta is written"

  # The same guard must NOT fire when the caller did the right thing: a resolved
  # attestation passes. This second direction is what makes the test die on a
  # predicate weakened to constant true (which would refuse both) and on a
  # predicate that refuses every explicit harness (which would refuse both),
  # not only on deletion/unreachability/weakening that lets the bare case through.
  resolved_id=profile-no-attestation-resolved-z30b
  rec=$(make_spawn_case profile-no-attestation-resolved claude "$resolved_id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$resolved_id" "$PROJ_DIR" --harness codex --model gpt-5 --effort high --dispatch-resolved)
  status=$?
  expect_code 0 "$status" "explicit harness with --dispatch-resolved should pass the same guard"
  assert_contains "$out" "spawned $resolved_id harness=codex" "resolved attestation spawn did not pass"
  pass "active profile refuses a bare explicit harness that skipped profile consultation while passing a resolved one"
}

test_active_profile_requires_attestation_for_scout() {
  local rec id resolved_id out status
  # Scouts are in scope with crewmates: the guard keys on "not a secondmate", so a
  # predicate narrowed to the ship kind would let every scout skip consultation.
  id=profile-scout-no-attestation-z38
  rec=$(make_spawn_case profile-scout-no-attestation claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness codex --model gpt-5 --effort high --scout)
  status=$?
  expect_code 1 "$status" "scout with an explicit harness but no attestation should be refused"
  assert_contains "$out" "--dispatch-resolved" "scout refusal did not name the resolved attestation flag"
  assert_contains "$out" "--dispatch-override-reason" "scout refusal did not name the override attestation flag"
  assert_absent "$HOME_DIR/state/$id.meta" "scout attestation refusal should happen before meta is written"

  resolved_id=profile-scout-resolved-z39
  rec=$(make_spawn_case profile-scout-resolved claude "$resolved_id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$resolved_id" "$PROJ_DIR" --harness codex --model gpt-5 --effort high --scout --dispatch-resolved)
  status=$?
  expect_code 0 "$status" "scout with --dispatch-resolved should pass the same guard"
  assert_contains "$out" "spawned $resolved_id harness=codex" "resolved scout spawn did not pass"
  assert_grep "dispatch=resolved" "$HOME_DIR/state/$resolved_id.meta" \
    "resolved scout attestation did not land in meta"
  pass "active profile requires and records the dispatch attestation on scout spawns too"
}

test_active_profile_refuses_multiline_override_reason() {
  local rec id out status
  # state/<id>.meta is one key=value per line and every reader takes the LAST match,
  # so a newline in the free-text reason would forge a later worktree= line and
  # point peek and teardown at another directory.
  id=profile-override-multiline-z40
  rec=$(make_spawn_case profile-override-multiline claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness codex --model gpt-5 --effort high \
    --dispatch-override-reason "codex quota out"$'\n'"worktree=/tmp/forged-by-reason")
  status=$?
  expect_code 1 "$status" "a multi-line override reason should be refused"
  assert_contains "$out" "--dispatch-override-reason must be a single line" \
    "refusal did not explain the single-line meta contract"
  assert_absent "$HOME_DIR/state/$id.meta" "multi-line reason should be refused before meta is written"
  pass "active profile refuses a multi-line override reason that would forge a meta key"
}

test_active_profile_allows_resolved_attestation_and_records_it() {
  local rec id out status meta
  id=profile-resolved-z31
  rec=$(make_spawn_case profile-resolved claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness codex --model gpt-5 --effort high --dispatch-resolved)
  status=$?
  expect_code 0 "$status" "explicit harness with --dispatch-resolved should pass"
  assert_contains "$out" "spawned $id harness=codex" "resolved attestation spawn did not report codex"
  meta="$HOME_DIR/state/$id.meta"
  assert_grep "dispatch=resolved" "$meta" "resolved attestation did not land dispatch=resolved in meta"
  pass "active profile allows a resolved attestation and records dispatch=resolved in meta"
}

test_active_profile_records_override_reason_in_meta() {
  local rec id out status meta
  id=profile-override-z32
  rec=$(make_spawn_case profile-override claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness claude --model sonnet --effort high \
    --dispatch-override-reason "captain instruction: use claude for this task")
  status=$?
  expect_code 0 "$status" "explicit harness with --dispatch-override-reason should pass"
  assert_contains "$out" "spawned $id harness=claude" "override spawn did not report claude"
  meta="$HOME_DIR/state/$id.meta"
  assert_grep "dispatch=override" "$meta" "override attestation did not land dispatch=override in meta"
  assert_grep "dispatch_override_reason=captain instruction: use claude for this task" "$meta" \
    "override attestation did not land the reason text in meta"
  pass "active profile records a deliberate override and its reason in meta"
}

test_active_profile_refuses_both_attestations() {
  local rec id out status
  id=profile-both-attestations-z33
  rec=$(make_spawn_case profile-both-attestations claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness codex --model gpt-5 --effort high \
    --dispatch-resolved --dispatch-override-reason "captain instruction")
  status=$?
  expect_code 1 "$status" "passing both attestations should be refused as ambiguous"
  assert_contains "$out" "pass exactly one of --dispatch-resolved or --dispatch-override-reason" \
    "refusal did not name the mutual-exclusion contract"
  assert_absent "$HOME_DIR/state/$id.meta" "ambiguous-attestation refusal should happen before meta is written"
  pass "active profile refuses when both attestations are supplied"
}

test_active_profile_refuses_override_reason_without_explicit_harness() {
  local rec id out status
  id=profile-override-no-harness-z34
  rec=$(make_spawn_case profile-override-no-harness claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --mode no-mistakes --yolo off \
    --dispatch-override-reason "captain instruction")
  status=$?
  expect_code 1 "$status" "override reason without an explicit harness should be refused"
  assert_contains "$out" "config/crew-dispatch.json is active - pass an explicit harness resolved from the dispatch rules" \
    "override-without-harness refusal did not reuse the explicit-harness backstop"
  assert_absent "$HOME_DIR/state/$id.meta" "override-without-harness refusal should happen before meta is written"
  pass "active profile refuses an override reason that has no harness to override from"
}

test_no_profile_does_not_require_attestation() {
  local rec id out status meta
  id=profile-absent-no-attestation-z35
  rec=$(make_spawn_case profile-absent-no-attestation claude "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --model sonnet --effort high)
  status=$?
  expect_code 0 "$status" "absent profiles should not require attestation"
  assert_contains "$out" "spawned $id harness=claude" "no-profile spawn did not report claude"
  meta="$HOME_DIR/state/$id.meta"
  assert_no_grep "dispatch=" "$meta" "absent profiles should not record a dispatch attestation line"
  pass "absent crew-dispatch.json does not require or record an attestation"
}

test_active_profile_batch_forwards_resolved_attestation() {
  local rec id1 id2 out status
  id1=profile-batch-resolved-a-z36
  id2=profile-batch-resolved-b-z37
  rec=$(make_spawn_case profile-batch-resolved claude "$id1" "$id2")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id1=$PROJ_DIR" "$id2=$PROJ_DIR" --harness codex --model gpt-5 --effort high --dispatch-resolved)
  status=$?
  expect_code 0 "$status" "batch with shared --dispatch-resolved should succeed"
  assert_contains "$out" "spawned $id1 harness=codex" "first batch task did not use shared harness"
  assert_contains "$out" "spawned $id2 harness=codex" "second batch task did not use shared harness"
  assert_grep "dispatch=resolved" "$HOME_DIR/state/$id1.meta" "batch did not forward attestation to first task meta"
  assert_grep "dispatch=resolved" "$HOME_DIR/state/$id2.meta" "batch did not forward attestation to second task meta"
  pass "batch dispatch forwards shared --dispatch-resolved to every pair"
}

test_active_profile_batch_refuses_without_attestation() {
  local rec id1 id2 out status
  # The batch guard must refuse the whole invocation up front, before any pair is
  # re-execed: without it each pair would still fail its own guard, so the only
  # observable difference is that no pair is ever attempted.
  id1=profile-batch-no-attestation-a-z41
  id2=profile-batch-no-attestation-b-z42
  rec=$(make_spawn_case profile-batch-no-attestation claude "$id1" "$id2")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id1=$PROJ_DIR" "$id2=$PROJ_DIR" --harness codex --model gpt-5 --effort high)
  status=$?
  expect_code 1 "$status" "batch with a shared harness but no attestation should be refused"
  assert_contains "$out" "--dispatch-resolved" "batch refusal did not name the resolved attestation flag"
  assert_not_contains "$out" "batch: FAILED to spawn" \
    "batch refused per pair instead of refusing the whole invocation before any spawn"
  assert_absent "$HOME_DIR/state/$id1.meta" "batch refusal should happen before the first pair spawns"
  assert_absent "$HOME_DIR/state/$id2.meta" "batch refusal should happen before the second pair spawns"
  [ ! -s "$LAUNCH_LOG" ] || fail "batch refusal still launched a harness"$'\n'"launch log: $(cat "$LAUNCH_LOG")"
  pass "batch dispatch refuses a shared harness with no attestation before any pair spawns"
}

test_active_quota_cooldown_suppresses_resolved_spawn() {
  local rec id out status
  id=profile-cooldown-active-z43
  rec=$(make_spawn_case profile-cooldown-active claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"
  record_dispatch_family_cooldown "$HOME_DIR" glm 2026-09-14T00:00:00Z \
    || fail "could not seed active dispatch cooldown"

  out=$(FM_QUOTA_COOLDOWN_NOW=2026-08-16T12:05:00Z \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness cursor-agent --model glm-4.5 --effort high \
    --dispatch-provider cursor --dispatch-model-family glm --dispatch-resolved)
  status=$?
  expect_code 3 "$status" "automatic resolved spawn should fail closed on an active tuple cooldown"
  assert_contains "$out" "routing cooldown active" "spawn refusal did not name the durable cooldown"
  assert_absent "$HOME_DIR/state/$id.meta" "cooled automatic spawn should stop before metadata"
  [ ! -s "$LAUNCH_LOG" ] || fail "cooled automatic spawn reached harness submission"
  pass "fm-spawn suppresses an automatic candidate with an active routing cooldown"
}

test_expired_and_sibling_cooldowns_do_not_suppress_spawn() {
  local rec expired_id sibling_id out status
  expired_id=profile-cooldown-expired-z44
  rec=$(make_spawn_case profile-cooldown-expired claude "$expired_id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"
  record_dispatch_family_cooldown "$HOME_DIR" glm 2026-08-16T12:01:00Z \
    || fail "could not seed expired dispatch cooldown"

  out=$(FM_QUOTA_COOLDOWN_NOW=2026-08-16T12:05:00Z \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$expired_id" "$PROJ_DIR" --harness cursor-agent --model glm-4.5 --effort high \
    --dispatch-provider cursor --dispatch-model-family glm --dispatch-resolved)
  status=$?
  expect_code 0 "$status" "expired tuple cooldown should not suppress a normal spawn"

  sibling_id=profile-cooldown-sibling-z45
  rec=$(make_spawn_case profile-cooldown-sibling claude "$sibling_id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"
  record_dispatch_family_cooldown "$HOME_DIR" glm 2026-09-14T00:00:00Z \
    || fail "could not seed sibling dispatch cooldown"

  out=$(FM_QUOTA_COOLDOWN_NOW=2026-08-16T12:05:00Z \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$sibling_id" "$PROJ_DIR" --harness cursor-agent --model kimi-k2.5 --effort high \
    --dispatch-provider cursor --dispatch-model-family kimi --dispatch-resolved)
  status=$?
  expect_code 0 "$status" "family-scoped cooldown should not suppress a sibling family spawn"
  pass "fm-spawn ignores expired cooldowns and model-family sibling records"
}

test_captain_override_dispatches_cooled_tuple_and_updates_record() {
  local rec id out status record meta
  id=profile-cooldown-override-z46
  rec=$(make_spawn_case profile-cooldown-override claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"
  record_dispatch_family_cooldown "$HOME_DIR" kimi 2026-09-14T00:00:00Z \
    || fail "could not seed override dispatch cooldown"

  out=$(FM_QUOTA_COOLDOWN_NOW=2026-08-16T12:05:00Z \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness cursor-agent --model kimi-k2.5 --effort high \
    --dispatch-provider cursor --dispatch-model-family kimi \
    --dispatch-override-reason "captain raised the Cursor spend limit")
  status=$?
  expect_code 0 "$status" "captain override should dispatch a cooled tuple"
  assert_contains "$out" "spawned $id harness=cursor-agent" "cooled override did not reach spawn"
  meta="$HOME_DIR/state/$id.meta"
  assert_grep "dispatch_provider=cursor" "$meta" "override meta did not retain dispatch provider"
  assert_grep "dispatch_model_family=kimi" "$meta" "override meta did not retain dispatch family"
  record=$(FM_HOME="$HOME_DIR" "$COOLDOWN" list --json)
  printf '%s' "$record" | jq -e --arg id "$id" \
    '[.cooldowns[] | select(.scope.model_family == "kimi") | .overrides[]
      | select(.task_id == $id
        and .reason == "captain raised the Cursor spend limit")] | length == 1' >/dev/null \
    || fail "cooldown did not note the overriding spawn and its reason"$'\n'"--- record ---"$'\n'"$record"
  pass "fm-spawn honors an explicit captain override and records it on the cooldown"
}

test_missing_axis_refusal_names_the_flags_spawn_accepts() {
  local rec id out status
  id=profile-cooldown-axes-z47
  rec=$(make_spawn_case profile-cooldown-axes claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"
  record_dispatch_provider_cooldown "$HOME_DIR" 2026-09-14T00:00:00Z \
    || fail "could not seed provider dispatch cooldown"

  out=$(FM_QUOTA_COOLDOWN_NOW=2026-08-16T12:05:00Z \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness claude --model sonnet --effort high \
    --dispatch-resolved)
  status=$?
  expect_code 3 "$status" "a cooldown that could match should fail closed on the missing provider axis"
  assert_contains "$out" "--dispatch-provider" "relayed refusal did not name the axis flag fm-spawn accepts"
  assert_absent "$HOME_DIR/state/$id.meta" "fail-closed spawn should stop before metadata"
  [ ! -s "$LAUNCH_LOG" ] || fail "fail-closed spawn reached harness submission"
  pass "fm-spawn's relayed missing-axis refusal names its own dispatch axis flags"
}

test_cooldown_protects_the_static_crew_harness_path() {
  local rec id out status
  id=profile-cooldown-static-z48
  rec=$(make_spawn_case profile-cooldown-static cursor-agent "$id")
  read_case_record "$rec"
  # Deliberately no crew-dispatch.json: a durable cooldown must also suppress the
  # automatic config/crew-harness path, not only a matched profile array.
  record_dispatch_family_cooldown "$HOME_DIR" glm 2026-09-14T00:00:00Z \
    || fail "could not seed static-path dispatch cooldown"

  out=$(FM_QUOTA_COOLDOWN_NOW=2026-08-16T12:05:00Z \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --model cursor-glm-4.6 --effort high \
    --dispatch-provider cursor --dispatch-model-family glm)
  status=$?
  expect_code 3 "$status" "a cooled static crew-harness spawn should fail closed without any dispatch profile"
  assert_contains "$out" "routing cooldown active" "static-path refusal did not name the durable cooldown"
  assert_absent "$HOME_DIR/state/$id.meta" "cooled static-path spawn should stop before metadata"
  [ ! -s "$LAUNCH_LOG" ] || fail "cooled static-path spawn reached harness submission"
  pass "a durable cooldown suppresses the static crew-harness path with no dispatch profile active"
}

# A pre-launch refusal must record a spawn-failure event into the routing
# telemetry ledger so login or credential rot is visible per pool/model/task-type
# with the exact cause. The capture is best-effort and never changes the spawn's
# own exit code. RED evidence is structural: the base fm-spawn has no
# fm_record_spawn_failure helper and its cooldown block only runs
# `exit "$cooldown_status"`, so no spawn-failure row can be appended; the
# companion telemetry test proves the base ledger rejects the spawn-failure
# command outright as "unknown command spawn-failure".
test_quota_cooldown_refusal_records_spawn_failure() {
  local rec id out status row ledger
  id=profile-cooldown-spawn-failure-z45
  rec=$(make_spawn_case profile-cooldown-spawn-failure claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"
  record_dispatch_family_cooldown "$HOME_DIR" glm 2026-09-14T00:00:00Z \
    || fail "could not seed active dispatch cooldown"
  out=$(FM_QUOTA_COOLDOWN_NOW=2026-08-16T12:05:00Z \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness cursor-agent --model glm-4.5 --effort high \
    --routing-source profile \
    --dispatch-provider cursor --dispatch-model-family glm --dispatch-resolved)
  status=$?
  expect_code 3 "$status" "cooled spawn should still exit 3 (telemetry never changes the exit code)"
  ledger="$HOME_DIR/data/routing-outcomes.jsonl"
  row=$(jq -c 'select(.eventType=="spawn-failure")' "$ledger" 2>/dev/null | head -n1)
  [ -n "$row" ] || fail "no spawn-failure row was recorded for the cooldown refusal"
  printf '%s' "$row" | jq -e '.failure.failureKind=="quota" and .failure.quotaReader=="available" and .failure.capability=="unknown"' >/dev/null \
    || fail "spawn-failure row did not classify real quota exhaustion (quota/available/unknown): $row"
  printf '%s' "$row" | jq -e '(.failure.cause|type=="string" and length>=1)' >/dev/null \
    || fail "spawn-failure row did not carry the exact cause: $row"
  printf '%s' "$row" | jq -e '.failure.tuple.harness=="cursor-agent" and .failure.tuple.model=="glm-4.5" and .failure.routingSource=="profile" and .failure.dispatchAttestation.kind=="resolved" and .failure.dispatchModelFamily=="glm"' >/dev/null \
    || fail "spawn-failure row did not carry the routing axes of the refused spawn: $row"
  # The refused spawn never produced an attempt-intake row.
  if jq -es 'any(.eventType=="attempt-intake")' "$ledger" >/dev/null; then
    fail "a cooled spawn recorded an attempt-intake row (it should stop before any attempt)"
  fi
  pass "a quota cooldown refusal records a spawn-failure row with the exact cause"
}

# A quota-READ credential gap (quota-axi reports kimi_code_cli_credential_expired)
# must record failureKind=quota-reader with capability=unknown (NOT unsupported)
# and quotaReader=credential-expired, so the pool is never falsely marked
# undispatchable by a reader gap. Standalone Kimi dispatch is supported; only
# its quota-read credential is expired. RED evidence is structural: the base
# fm-spawn has no fm_classify_cooldown_refusal helper, so a credential-expired
# cooldown would be recorded as failureKind=quota (falsely conflating a reader
# gap with quota exhaustion).
test_quota_reader_gap_records_spawn_failure_separately() {
  local rec id out status row ledger
  id=profile-cooldown-reader-gap-z46
  rec=$(make_spawn_case profile-cooldown-reader-gap claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"
  FM_HOME="$HOME_DIR" FM_QUOTA_COOLDOWN_NOW=2026-08-16T12:00:00Z \
    "$COOLDOWN" record --scope model-family --harness kimi \
    --provider moonshot --model-family kimi \
    --evidence-kind quota-axi \
    --evidence "kimi_code_cli_credential_expired" \
    --expires-at 2026-09-14T00:00:00Z >/dev/null \
    || fail "could not seed a quota-reader credential-expired cooldown"
  out=$(FM_QUOTA_COOLDOWN_NOW=2026-08-16T12:05:00Z \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness kimi --model kimi-k2 --effort high \
    --routing-source profile \
    --dispatch-provider moonshot --dispatch-model-family kimi --dispatch-resolved)
  status=$?
  expect_code 3 "$status" "a quota-reader-gap cooldown should still exit 3 (telemetry never changes the exit code)"
  ledger="$HOME_DIR/data/routing-outcomes.jsonl"
  row=$(jq -c 'select(.eventType=="spawn-failure")' "$ledger" 2>/dev/null | head -n1)
  [ -n "$row" ] || fail "no spawn-failure row was recorded for the quota-reader gap"
  printf '%s' "$row" | jq -e '.failure.failureKind=="quota-reader" and .failure.quotaReader=="credential-expired" and .failure.capability=="unknown"' >/dev/null \
    || fail "quota-reader gap was not recorded separately from spawn capability: $row"
  # A quota-read login gap must never mark the pool undispatchable.
  printf '%s' "$row" | jq -e '.failure.capability!="unsupported"' >/dev/null \
    || fail "a quota-reader gap falsely marked the pool unsupported (undispatchable): $row"
  printf '%s' "$row" | jq -e '(.failure.cause|test("kimi_code_cli_credential_expired"))' >/dev/null \
    || fail "spawn-failure row did not carry the exact credential-expired cause: $row"
  pass "a quota-reader credential gap records spawn-failure separately from spawn capability"
}

# A refusal raised while the arguments are still being parsed runs before the
# task id has been resolved from the positionals, and `set -u` is active the
# whole time. Such a refusal must still record its spawn-failure row, keep its
# own exit code, and never leak a shell diagnostic into the message the caller
# reads.
test_parse_time_validation_refusal_records_spawn_failure() {
  local rec id out status row ledger
  id=profile-parse-refusal-z47
  rec=$(make_spawn_case profile-parse-refusal claude "$id")
  read_case_record "$rec"
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness codex --model gpt-5 --effort high \
    --routing-source profile --dispatch-resolved --quota-decision vibes)
  status=$?
  expect_code 1 "$status" "an invalid --quota-decision should still exit 1"
  assert_contains "$out" "--quota-decision must be one of" "the refusal did not name the rejected value"
  case "$out" in
    *"unbound variable"*) fail "a parse-time refusal leaked a shell diagnostic: $out" ;;
  esac
  ledger="$HOME_DIR/data/routing-outcomes.jsonl"
  row=$(jq -c 'select(.eventType=="spawn-failure")' "$ledger" 2>/dev/null | head -n1)
  [ -n "$row" ] || fail "no spawn-failure row was recorded for the parse-time validation refusal"
  printf '%s' "$row" | jq -e '.failure.failureKind=="validation" and (.failure.cause|test("--quota-decision"))' >/dev/null \
    || fail "the parse-time refusal did not record its exact cause: $row"
  # The pool axis is the point of the row: a model and effort with no harness
  # cannot be attributed to the subscription that refused the spawn.
  printf '%s' "$row" | jq -e '.failure.tuple.harness=="codex" and .failure.tuple.model=="gpt-5" and .failure.tuple.effort=="high"' >/dev/null \
    || fail "the parse-time refusal lost the declared harness axis: $row"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "a refused spawn published task metadata"
  # Every flag guard in this block is a refusal class the read surface must see;
  # a refusal that exits silently is invisible next to its byte-adjacent sibling.
  id=profile-parse-refusal-runway-z50
  rec=$(make_spawn_case profile-parse-refusal-runway claude "$id")
  read_case_record "$rec"
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness codex --model gpt-5 --effort high \
    --routing-source profile --dispatch-resolved --quota-runway vibes)
  status=$?
  expect_code 1 "$status" "an invalid --quota-runway should still exit 1"
  assert_contains "$out" "--quota-runway must be one of" "the refusal did not name the rejected value"
  ledger="$HOME_DIR/data/routing-outcomes.jsonl"
  row=$(jq -c 'select(.eventType=="spawn-failure")' "$ledger" 2>/dev/null | head -n1)
  [ -n "$row" ] || fail "a --quota-runway refusal left no spawn-failure row while its siblings record one"
  printf '%s' "$row" | jq -e '.failure.failureKind=="validation" and (.failure.cause|test("--quota-runway")) and .failure.tuple.harness=="codex"' >/dev/null \
    || fail "the --quota-runway refusal did not record its exact cause and pool: $row"
  # The axes a parse-time refusal has not validated yet must not take the whole
  # row down with them: an operator typo on --effort or --task-class is exactly
  # the refusal the ledger exists to make visible.
  id=profile-parse-refusal-axes-z51
  rec=$(make_spawn_case profile-parse-refusal-axes claude "$id")
  read_case_record "$rec"
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness codex --model gpt-5 --effort ultra --task-class vibes \
    --account-profile work --routing-source profile --dispatch-resolved --quota-decision vibes)
  status=$?
  expect_code 1 "$status" "an invalid --quota-decision should still exit 1 alongside unvalidated axes"
  case "$out" in
    *"spawn-failure telemetry could not be recorded"*) fail "unvalidated axes dropped the refusal row: $out" ;;
  esac
  ledger="$HOME_DIR/data/routing-outcomes.jsonl"
  row=$(jq -c 'select(.eventType=="spawn-failure")' "$ledger" 2>/dev/null | head -n1)
  [ -n "$row" ] || fail "no spawn-failure row survived the unvalidated effort, task-class, and account-profile axes"
  printf '%s' "$row" | jq -e '.failure.tuple.harness=="codex" and .failure.tuple.model=="gpt-5" and (.failure.cause|test("--quota-decision"))' >/dev/null \
    || fail "the refusal lost the axes it could vouch for: $row"
  # An axis fm-spawn cannot vouch for is named as unknown, never invented.
  printf '%s' "$row" | jq -e '.failure.tuple.effort=="default" and .failure.taskClass=="unresolved" and (.failure.tuple|has("accountProfile")|not)' >/dev/null \
    || fail "an unvalidated axis was recorded verbatim instead of being named unknown: $row"
  # The refused axis is itself one the schema constrains, so the row for its own
  # refusal must not be the one the ledger throws away.
  id=profile-parse-refusal-routing-z52
  rec=$(make_spawn_case profile-parse-refusal-routing claude "$id")
  read_case_record "$rec"
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness codex --model gpt-5 --effort high --routing-source vibes)
  status=$?
  expect_code 1 "$status" "an invalid --routing-source should still exit 1"
  assert_contains "$out" "--routing-source must be one of" "the refusal did not name the rejected value"
  case "$out" in
    *"spawn-failure telemetry could not be recorded"*) fail "the --routing-source refusal dropped its own row: $out" ;;
  esac
  ledger="$HOME_DIR/data/routing-outcomes.jsonl"
  row=$(jq -c 'select(.eventType=="spawn-failure")' "$ledger" 2>/dev/null | head -n1)
  [ -n "$row" ] || fail "no spawn-failure row was recorded for the rejected --routing-source"
  printf '%s' "$row" | jq -e '.failure.failureKind=="validation" and (.failure.cause|test("--routing-source")) and .failure.routingSource==null and .failure.tuple.harness=="codex"' >/dev/null \
    || fail "the --routing-source refusal did not record its cause with the rejected axis named unknown: $row"
  pass "a parse-time validation refusal records a spawn-failure row and keeps its exit code"
}

# --matched-rule feeds the intake schema, which accepts only 'default' or
# 'rule-<n>'. The parse-time guard must enforce that same shape: a looser guard
# lets the spawn run to completion before the schema refuses it, records no
# spawn-failure row for it, and leaves state/<id>.meta - one key=value per line,
# every reader taking the LAST match - open to a forged line.
test_matched_rule_guard_matches_the_intake_schema() {
  local rec id out status row ledger
  id=profile-matched-rule-z49
  rec=$(make_spawn_case profile-matched-rule claude "$id")
  read_case_record "$rec"
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness codex --model gpt-5 --effort high \
    --routing-source profile --dispatch-resolved --matched-rule rule-3x)
  status=$?
  expect_code 1 "$status" "a --matched-rule outside the schema shape should be refused at parse time"
  assert_contains "$out" "--matched-rule must be" "the refusal did not name the rejected flag"
  [ ! -s "$LAUNCH_LOG" ] || fail "a rule id the schema rejects still reached harness submission"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "a refused spawn published task metadata"
  ledger="$HOME_DIR/data/routing-outcomes.jsonl"
  row=$(jq -c 'select(.eventType=="spawn-failure")' "$ledger" 2>/dev/null | head -n1)
  [ -n "$row" ] || fail "no spawn-failure row was recorded for the rejected --matched-rule"
  printf '%s' "$row" | jq -e '.failure.failureKind=="validation" and (.failure.cause|test("--matched-rule"))' >/dev/null \
    || fail "the --matched-rule refusal did not record its exact cause: $row"
  # A rule id carrying a newline would forge a later meta line; the flag's own
  # guard must reject it rather than resting on a downstream ordering accident.
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness codex --model gpt-5 --effort high \
    --routing-source profile --dispatch-resolved --matched-rule "rule-1
worktree=/tmp/forged")
  status=$?
  expect_code 1 "$status" "a multi-line --matched-rule should be refused at parse time"
  assert_contains "$out" "--matched-rule must be" "the multi-line refusal did not name the rejected flag"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "a multi-line rule id published task metadata"
  # A multi-digit rule id is schema-valid, so the tightened guard must still let
  # it through to the intake row the schema itself validates.
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness codex --model gpt-5 --effort high \
    --routing-source profile --dispatch-resolved --matched-rule rule-12)
  status=$?
  expect_code 0 "$status" "a schema-valid rule id should still spawn: $out"
  row=$(jq -es 'map(select(.eventType=="attempt-intake")) | .[0].intake.selection' "$ledger")
  printf '%s' "$row" | jq -e '.matchedRule=="rule-12"' >/dev/null \
    || fail "the accepted rule id did not reach the intake selection: $row"
  pass "--matched-rule is validated at parse time against the shape the intake schema requires"
}

# The ledger caps a spawn-failure cause at 512 characters, and a cooldown
# refusal carries the stored provider-refusal quote verbatim - a quote the
# cooldown owner does not bound. An oversized quote must still be recorded
# (truncated) rather than dropped, because that is exactly the credential- or
# quota-rot event the ledger exists to make visible.
test_oversized_cooldown_evidence_is_recorded_truncated() {
  local rec id out status row ledger quote
  id=profile-cooldown-long-evidence-z48
  rec=$(make_spawn_case profile-cooldown-long-evidence claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"
  quote="You've hit your usage limit for glm; resets 9/14/2026 $(printf 'x%.0s' $(seq 1 600))"
  FM_HOME="$HOME_DIR" FM_QUOTA_COOLDOWN_NOW=2026-08-16T12:00:00Z \
    "$COOLDOWN" record --scope model-family --harness cursor-agent \
    --provider cursor --model-family glm \
    --evidence-kind provider-refusal \
    --evidence "$quote" \
    --expires-at 2026-09-14T00:00:00Z >/dev/null \
    || fail "could not seed a cooldown carrying an unbounded evidence quote"
  out=$(FM_QUOTA_COOLDOWN_NOW=2026-08-16T12:05:00Z \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness cursor-agent --model glm-4.5 --effort high \
    --routing-source profile \
    --dispatch-provider cursor --dispatch-model-family glm --dispatch-resolved)
  status=$?
  expect_code 3 "$status" "a cooled spawn should still exit 3 with an oversized evidence quote"
  case "$out" in
    *"spawn-failure telemetry could not be recorded"*) fail "an oversized cause was dropped instead of truncated: $out" ;;
  esac
  ledger="$HOME_DIR/data/routing-outcomes.jsonl"
  row=$(jq -c 'select(.eventType=="spawn-failure")' "$ledger" 2>/dev/null | head -n1)
  [ -n "$row" ] || fail "an oversized cooldown evidence quote dropped the spawn-failure row entirely"
  printf '%s' "$row" | jq -e '.failure.failureKind=="quota" and (.failure.cause|length)<=512 and (.failure.cause|test("usage limit"))' >/dev/null \
    || fail "the oversized cause was not truncated to the recordable cap: $row"
  pass "an oversized cooldown evidence quote is truncated into the ledger, never dropped"
}

test_routing_source_recorded_only_when_declared
test_spawn_writes_routing_facts_into_intake
test_recorded_default_axes_respawn_as_unset
test_no_profile_keeps_claude_profile_defaults
test_relative_home_overrides_launch_with_absolute_cross_process_paths
test_home_defaults_preserve_absolute_or_resolve_relative_paths
test_absolute_override_spelling_is_preserved_in_launch_paths
test_unresolvable_relative_overrides_fail_loudly
test_active_dispatch_profile_requires_explicit_harness_for_ship
test_active_dispatch_profile_requires_explicit_harness_for_scout
test_active_dispatch_profile_allows_explicit_harness
test_active_dispatch_profile_allows_positional_harness
test_active_dispatch_profile_allows_raw_launch_command
test_active_profile_refuses_explicit_harness_without_attestation
test_active_profile_requires_attestation_for_scout
test_active_profile_refuses_multiline_override_reason
test_active_profile_allows_resolved_attestation_and_records_it
test_active_profile_records_override_reason_in_meta
test_active_profile_refuses_both_attestations
test_active_profile_refuses_override_reason_without_explicit_harness
test_no_profile_does_not_require_attestation
test_active_profile_batch_forwards_resolved_attestation
test_active_profile_batch_refuses_without_attestation
test_active_quota_cooldown_suppresses_resolved_spawn
test_quota_cooldown_refusal_records_spawn_failure
test_quota_reader_gap_records_spawn_failure_separately
test_parse_time_validation_refusal_records_spawn_failure
test_matched_rule_guard_matches_the_intake_schema
test_oversized_cooldown_evidence_is_recorded_truncated
test_expired_and_sibling_cooldowns_do_not_suppress_spawn
test_captain_override_dispatches_cooled_tuple_and_updates_record
test_missing_axis_refusal_names_the_flags_spawn_accepts
test_cooldown_protects_the_static_crew_harness_path
test_claude_threads_model_and_effort
test_codex_threads_model_and_effort
test_codex_omits_invalid_max_effort
test_grok_threads_model_and_reasoning_effort
test_grok_omits_invalid_max_reasoning_effort
test_grok_omits_invalid_xhigh_reasoning_effort
test_opencode_threads_model_and_ignores_effort_axis
test_cursor_agent_threads_model_variant_and_records_effort
test_pi_threads_model_and_max_effort
test_pi_signed_threads_shared_pi_profile_and_preserves_identity
test_pi_signed_missing_binary_refuses_before_endpoint_or_metadata
test_pi_signed_persistent_secondmate_uses_pi_extensions_and_identity
test_batch_forwards_shared_profile_flags
test_claude_account_profile_binds_canonical_dir_and_records_alias_only
test_two_claude_account_profiles_can_run_concurrently
test_claude_account_profile_rejects_unsafe_mapping_before_endpoint
test_claude_account_profile_requires_exact_paid_native_auth_predicate
test_claude_account_profile_requires_owner_only_directory
test_claude_account_profile_auth_command_is_bounded_with_stdin_closed
test_claude_account_profile_rejects_non_directory_before_endpoint
test_non_claude_harness_refuses_account_profile_before_endpoint
test_secondmate_parent_refuses_home_local_account_profile
test_claude_forwards_firstmate_config_dir_when_set
test_selected_account_profile_wins_over_ambient_config_dir
test_claude_omits_config_dir_prefix_when_unset
test_non_claude_harness_ignores_config_dir
test_active_dispatch_profile_does_not_block_secondmate_launch
test_telemetry_precedes_submission_and_metadata_is_opaque
test_exploration_requires_an_explicit_rotated_model_and_effort
test_no_mistakes_spawn_requires_one_quota_eligible_reviewer
test_linked_telemetry_identifiers_chain_one_task_root

echo "# all fm-spawn-dispatch-profile tests passed"
