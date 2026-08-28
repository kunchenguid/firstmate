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
# shellcheck source=bin/fm-backend-hometag-lib.sh
. "$ROOT/bin/fm-backend-hometag-lib.sh"

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
if [ -n "${FM_FAKE_TMUX_CMDLOG:-}" ]; then
  printf '%s\n' "$*" >> "$FM_FAKE_TMUX_CMDLOG"
fi
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message)
    case "$*" in
      *"#{pane_current_command}"*) printf '%s\n' "${FM_FAKE_PANE_COMMAND:-firstmate}" ;;
      *) printf 'firstmate\n' ;;
    esac
    exit 0
    ;;
  capture-pane) printf '%s\n' "${FM_FAKE_TMUX_CAPTURE:-}"; exit 0 ;;
  list-windows)
    [ -z "${FM_FAKE_TMUX_WINDOWS:-}" ] || printf '%s\n' "$FM_FAKE_TMUX_WINDOWS"
    exit 0
    ;;
  has-session|new-session|kill-window) exit 0 ;;
  new-window)
    [ -z "${FM_FAKE_ENDPOINT_LOG:-}" ] || printf 'created\n' >> "$FM_FAKE_ENDPOINT_LOG"
    printf '@1\n'
    exit 0
    ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      prev=
      for a in "$@"; do
        if [ "$prev" = "-l" ]; then
          printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG"
          if [ "${FM_FAKE_EXEC_LAUNCH:-0}" = 1 ]; then
            (
              cd "${FM_FAKE_EXEC_CWD:?}"
              /bin/bash -c "$a"
            ) > "${FM_FAKE_EXEC_STDOUT:?}" 2> "${FM_FAKE_EXEC_STDERR:?}"
            printf '%s\n' "$?" > "${FM_FAKE_EXEC_STATUS:?}"
          fi
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
  cat > "$fakebin/bwrap" <<'SH'
#!/usr/bin/env bash
set -u
project=
while [ $# -gt 0 ]; do
  case "$1" in
    --bind|--dev-bind)
      shift 3
      ;;
    --ro-bind)
      [ "$2" = / ] || project=$2
      shift 3
      ;;
    --cap-drop)
      shift 2
      ;;
    --die-with-parent)
      shift
      ;;
    --)
      shift
      break
      ;;
    *)
      exit 2
      ;;
  esac
done
if [ -n "$project" ]; then
  chmod -R u-w "$project"
fi
"$@"
status=$?
if [ -n "$project" ]; then
  chmod -R u+w "$project"
fi
exit "$status"
SH
  chmod +x "$fakebin/bwrap"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
store=$(dirname "$0")/occupancy.json
[ -f "$store" ] || printf '[]\n' > "$store"
if [ "${1:-}" = get ]; then
  holder=
  while [ "$#" -gt 0 ]; do
    if [ "$1" = --lease-holder ]; then holder=$2; shift; fi
    shift
  done
  path=${FM_FAKE_PANE_PATH:-}
  name=slot-$holder
  lease=lease-$holder
  tmp=$store.tmp
  jq --arg path "$path" --arg holder "$holder" --arg name "$name" --arg lease "$lease" \
    'map(select((.path|tostring) != $path)) + [{name:$name,path:$path,status:"leased",lease_id:$lease,lease_holder:$holder}]' \
    "$store" > "$tmp" && mv "$tmp" "$store"
  jq -cn --arg path "$path" --arg holder "$holder" --arg name "$name" --arg lease "$lease" \
    '{name:$name,path:$path,lease_id:$lease,lease_holder:$holder}'
  exit 0
fi
if [ "${1:-}" = status ]; then
  cat "$store"
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/treehouse"
  fm_fake_exit0 "$fakebin" pi-signed no-mistakes gh-axi gh tasks-axi
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

# Mirror bin/fm-launch-axis-lib.sh shell_quote so launch assertions can compare
# the exact single-quoted form fm-spawn writes into the pane.
shell_quote_value() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
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
  assert_contains "$out" "--routing-source must be one of captain, profile, fallback, secondmate-config" "invalid routing source refusal did not name the contract"
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
  printf '%s' "$sel" | jq -e '.matchedRule==null and (.quota.decision=="not-applicable") and (.quota.headroom=="unknown") and (.quota.runway=="unknown")' >/dev/null \
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
  expected="GIT_CONFIG_COUNT='1' GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0='/tmp/fm-$id/git-hooks' NM_HOME='$HOME_DIR/.no-mistakes' CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions \"\$('${ROOT}/bin/fm-operational-input.sh' encode launch-brief < '$HOME_DIR/data/$id/brief.md')\""
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
  assert_no_grep "access=" "$HOME_DIR/state/$id.meta" \
    "the default writer spawn added an access field to legacy metadata"

  launch=$(cat "$LAUNCH_LOG")
  expected="GIT_CONFIG_COUNT='1' GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0='/tmp/fm-$id/git-hooks' NM_HOME='$HOME_DIR/.no-mistakes' CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions \"\$('${ROOT}/bin/fm-operational-input.sh' encode launch-brief < '$HOME_DIR/data/$id/brief.md')\""
  [ "$launch" = "$expected" ] || fail "no-profile claude launch did not use the canonical launch kind"$'\n'"expected: $expected"$'\n'"actual:   $launch"
  pass "no --model/--effort records defaults, writer metadata omits access, and the claude launch is canonical"
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

test_codex_initial_and_resume_share_full_launch_posture() {
  local rec id out status initial resumed brief
  id=codex-resume-posture-z31
  rec=$(make_spawn_case codex-resume-posture codex "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --model gpt-5 --effort high)
  status=$?
  expect_code 0 "$status" "ordinary Codex launch should succeed"
  initial=$(cat "$LAUNCH_LOG")
  brief=$(shell_quote_value "$HOME_DIR/data/$id/brief.md")

  out=$(FM_FAKE_TMUX_WINDOWS="fm-$id" FM_FAKE_PANE_COMMAND=bash \
    run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
      "$id" --relaunch --resume-session session-123)
  status=$?
  expect_code 0 "$status" "resumed Codex launch should succeed"
  resumed=$(cat "$LAUNCH_LOG")

  assert_contains "$initial" "codex --model 'gpt-5' -c 'model_reasoning_effort=\"high\"' --dangerously-bypass-approvals-and-sandbox -c \"notify=" \
    "ordinary Codex launch lost model, effort, autonomy, or notification arguments"
  assert_contains "$initial" "launch-brief < $brief" \
    "ordinary Codex launch lost its prompt argument"
  assert_contains "$resumed" "codex resume --model 'gpt-5' -c 'model_reasoning_effort=\"high\"' --dangerously-bypass-approvals-and-sandbox -c \"notify=" \
    "resumed Codex launch lost model, effort, autonomy, or notification arguments"
  assert_contains "$resumed" "'session-123' \"" \
    "resumed Codex launch lost the supplied session identity"
  assert_contains "$resumed" "launch-brief < $brief" \
    "resumed Codex launch lost its prompt argument"
  pass "Codex initial and resumed launches share full lifecycle posture"
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

test_cursor_reader_launch_uses_noninteractive_brief_delivery() {
  local rec id out status launch
  id=cursor-reader-consumes-z7c
  rec=$(make_spawn_case cursor-reader-consumes cursor-agent "$id")
  read_case_record "$rec"
  write_reader_brief "$HOME_DIR" "$id" "$PROJ_DIR"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --scout --access reader --harness cursor-agent \
    --model cursor-grok-4.6-xhigh --effort xhigh)
  status=$?
  expect_code 0 "$status" "reader Cursor spawn should submit its launch command"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" '--print' \
    "reader Cursor launch omitted the documented non-interactive brief mode"
  assert_contains "$launch" 'encode launch-brief' \
    "reader Cursor launch omitted its typed launch brief"
  pass "reader Cursor launch uses non-interactive brief delivery through the confined process"
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

test_secondmate_recovery_records_durable_config_provenance() {
  local rec id sm out status meta
  id=profile-secondmate-config-z16b
  rec=$(make_spawn_case profile-secondmate-config cursor-agent "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"
  printf '%s\n' 'cursor-agent cursor-grok-4.6-xhigh xhigh' > "$HOME_DIR/config/secondmate-harness"
  sm="$CASE_DIR/secondmate-home"
  make_seeded_secondmate_home "$sm" "$id"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$sm" --secondmate)
  status=$?
  expect_code 0 "$status" "durably configured secondmate recovery should succeed"
  meta="$HOME_DIR/state/$id.meta"
  assert_grep "routing_source=secondmate-config" "$meta" "secondmate recovery lost its durable config provenance"
  assert_no_grep "dispatch=resolved" "$meta" "secondmate config recovery falsely claimed crew-profile resolution"
  assert_no_grep "matched_rule=" "$meta" "secondmate config recovery falsely claimed a crew-dispatch rule"
  assert_meta_profile "$meta" cursor-agent cursor-grok-4.6-xhigh xhigh
  jq -es 'map(select(.eventType=="attempt-intake")) | .[0].intake.selection.routingSource=="secondmate-config"' "$HOME_DIR/data/routing-outcomes.jsonl" >/dev/null \
    || fail "secondmate-config provenance did not reach the validated telemetry intake"
  pass "a no-argument secondmate recovery records durable secondmate-config provenance"
}

test_secondmate_config_provenance_requires_exclusive_complete_tuple() {
  local spec label config_text axis id rec sm out status meta
  for spec in \
    'bare|cursor-agent|none' \
    'partial|cursor-agent cursor-grok-4.6-xhigh|none' \
    'harness-flag|cursor-agent cursor-grok-4.6-xhigh xhigh|harness' \
    'model-flag|cursor-agent cursor-grok-4.6-xhigh xhigh|model' \
    'effort-flag|cursor-agent cursor-grok-4.6-xhigh xhigh|effort' \
    'positional-harness|cursor-agent cursor-grok-4.6-xhigh xhigh|positional'; do
    label=${spec%%|*}; spec=${spec#*|}
    config_text=${spec%%|*}; axis=${spec#*|}
    id="profile-secondmate-source-$label-z16c"
    rec=$(make_spawn_case "secondmate-source-$label" cursor-agent "$id")
    read_case_record "$rec"
    printf '%s\n' "$config_text" > "$HOME_DIR/config/secondmate-harness"
    sm="$CASE_DIR/secondmate-home"
    make_seeded_secondmate_home "$sm" "$id"
    case "$axis" in
      none) out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$sm" --secondmate) ;;
      harness) out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$sm" --harness codex --secondmate) ;;
      model) out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$sm" --model composer-2.5 --secondmate) ;;
      effort) out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$sm" --effort medium --secondmate) ;;
      positional) out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$sm" codex --secondmate) ;;
    esac
    status=$?
    expect_code 0 "$status" "$label secondmate launch should retain its ordinary fallback/override behavior"
    meta="$HOME_DIR/state/$id.meta"
    assert_no_grep "routing_source=secondmate-config" "$meta" "$label launch falsely claimed exclusive durable-config provenance"
    jq -es 'map(select(.eventType=="attempt-intake")) | length == 1 and (.[0].intake.selection | has("routingSource") | not)' "$HOME_DIR/data/routing-outcomes.jsonl" >/dev/null \
      || fail "$label launch wrote false secondmate-config telemetry provenance"
  done

  id=profile-secondmate-source-explicit-z16d
  rec=$(make_spawn_case secondmate-source-explicit cursor-agent "$id")
  read_case_record "$rec"
  printf '%s\n' 'cursor-agent cursor-grok-4.6-xhigh xhigh' > "$HOME_DIR/config/secondmate-harness"
  sm="$CASE_DIR/secondmate-home"
  make_seeded_secondmate_home "$sm" "$id"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$sm" \
    --model composer-2.5 --routing-source secondmate-config --secondmate)
  status=$?
  [ "$status" -ne 0 ] || fail "explicit secondmate-config provenance bypassed a model override"
  assert_contains "$out" "requires one complete durable tuple and no harness, model, effort, or positional harness override" "false explicit provenance refusal did not name the ownership contract"
  assert_absent "$HOME_DIR/state/$id.meta" "false explicit provenance published task metadata"
  [ ! -s "$LAUNCH_LOG" ] || fail "false explicit provenance reached endpoint launch"
  [ ! -e "$HOME_DIR/data/routing-outcomes.jsonl" ] || ! jq -e 'select(.eventType=="attempt-intake")' "$HOME_DIR/data/routing-outcomes.jsonl" >/dev/null \
    || fail "false explicit provenance reached telemetry intake"
  pass "secondmate-config provenance requires one complete unoverridden durable tuple in meta and telemetry"
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
    .[1].terminal.gateFacts=={source:"delivery",result:"cancelled",stepReruns:null} and
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
  # This fixture intentionally exercises the supported explicit NM_HOME
  # override; an unset override now uses the Firstmate home's private Codex root.
  export NM_HOME="$operator_home/.no-mistakes"

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
  unset NM_HOME
  pass "no-mistakes spawn requires one quota-eligible reviewer unless explicitly overridden"
}

# Finding 1: the resolved private NM_HOME must cross the pane process boundary
# in the literal worker launch command (the verified per-backend environment
# channel that already ships GOTMPDIR), not only live in the fm-spawn process.
# Finding 2 (spawn side): the same resolved root is bound durably per task in
# state/<id>.meta as nm_home=<root> so crew-state/teardown observe the exact root.
test_no_mistakes_spawn_carries_nm_home_into_launch_and_meta() {
  local rec id override_id newline_id trailing_newline_id derived_newline_id derived_trailing_newline_id direct_id out status launch meta home_nm override_nm override_home newline_nm trailing_newline_nm derived_home derived_nm derived_trailing_home derived_trailing_nm normalized_trailing_nm
  id=profile-nm-home-launch-z29
  override_id=profile-nm-home-override-z30
  newline_id=profile-nm-home-newline-z30b
  trailing_newline_id=profile-nm-home-trailing-newline-z30c
  derived_newline_id=profile-nm-home-derived-newline-z30d
  derived_trailing_newline_id=profile-nm-home-derived-trailing-newline-z30e
  direct_id=profile-nm-home-direct-pr-z31
  rec=$(make_spawn_case profile-nm-home-launch codex "$id" "$override_id" "$newline_id" "$trailing_newline_id" "$derived_newline_id" "$derived_trailing_newline_id" "$direct_id")
  read_case_record "$rec"
  home_nm="$HOME_DIR/.no-mistakes"

  trailing_newline_nm="$CASE_DIR/operator-trailing-nm-home"$'\n'
  mkdir -p "${trailing_newline_nm%$'\n'}"
  printf '%s\n' 'agent: [codex]' > "${trailing_newline_nm%$'\n'}/config.yaml"
  : > "$LAUNCH_LOG"
  out=$(NM_HOME="$trailing_newline_nm" run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$trailing_newline_id" "$PROJ_DIR")
  status=$?
  [ "$status" -ne 0 ] || fail "explicit trailing-newline NM_HOME override was accepted"
  assert_contains "$out" "NM_HOME must be a single line" \
    "explicit trailing-newline NM_HOME refusal did not name the metadata constraint"
  [ ! -s "$LAUNCH_LOG" ] || fail "explicit trailing-newline NM_HOME reached launch submission"
  assert_absent "$HOME_DIR/state/$trailing_newline_id.meta" \
    "explicit trailing-newline NM_HOME published partial task metadata"
  assert_absent "$home_nm" \
    "explicit trailing-newline NM_HOME mutated the Firstmate-owned no-mistakes home"

  derived_home="$CASE_DIR/derived"$'\n'"home"
  derived_nm="$derived_home/.no-mistakes"
  : > "$LAUNCH_LOG"
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$derived_home" NM_HOME='' \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
    CLAUDE_CONFIG_DIR='' FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
    GROK_HOME="$HOME_DIR/grok-home" PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$derived_newline_id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "newline-bearing derived NM_HOME was accepted"
  assert_contains "$out" "FM_HOME must be a single line" \
    "newline-bearing FM_HOME refusal did not precede path normalization"
  [ ! -s "$LAUNCH_LOG" ] || fail "newline-bearing derived NM_HOME reached launch submission"
  assert_absent "$HOME_DIR/state/$derived_newline_id.meta" \
    "newline-bearing derived NM_HOME published partial task metadata"
  assert_absent "$derived_nm" \
    "newline-bearing derived NM_HOME mutated the selected no-mistakes home"

  derived_trailing_home="$CASE_DIR/derived-trailing-home"$'\n'
  derived_trailing_nm="$derived_trailing_home/.no-mistakes"
  normalized_trailing_nm="${derived_trailing_home%$'\n'}/.no-mistakes"
  : > "$LAUNCH_LOG"
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$derived_trailing_home" NM_HOME='' \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
    CLAUDE_CONFIG_DIR='' FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
    GROK_HOME="$HOME_DIR/grok-home" PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$derived_trailing_newline_id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "trailing-newline FM_HOME was accepted"
  assert_contains "$out" "FM_HOME must be a single line" \
    "trailing-newline FM_HOME refusal did not precede path normalization"
  [ ! -s "$LAUNCH_LOG" ] || fail "trailing-newline FM_HOME reached launch submission"
  assert_absent "$HOME_DIR/state/$derived_trailing_newline_id.meta" \
    "trailing-newline FM_HOME published partial task metadata"
  assert_absent "$derived_trailing_nm" \
    "trailing-newline FM_HOME mutated the selected no-mistakes home"
  assert_absent "$normalized_trailing_nm" \
    "trailing-newline FM_HOME mutated the normalized no-mistakes home"

  # Default root: an unset NM_HOME resolves to this home's private root, which
  # must appear in the literal launch command and in the task metadata.
  : > "$LAUNCH_LOG"
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "default no-mistakes spawn should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "NM_HOME=$(shell_quote_value "$home_nm")" \
    "default no-mistakes launch did not carry the resolved NM_HOME into the worker pane"
  meta="$HOME_DIR/state/$id.meta"
  assert_grep "nm_home=$home_nm" "$meta" \
    "default no-mistakes spawn did not bind nm_home to the home private root in metadata"

  # Explicit operator override: the override root is carried verbatim, not the
  # home private root.
  override_home="$CASE_DIR/operator-nm-home"
  mkdir -p "$override_home"
  printf '%s\n' 'agent: [codex]' > "$override_home/config.yaml"
  override_nm="$override_home"
  : > "$LAUNCH_LOG"
  out=$(NM_HOME="$override_nm" run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$override_id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "explicit NM_HOME override spawn should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "NM_HOME=$(shell_quote_value "$override_nm")" \
    "explicit NM_HOME override was not carried verbatim into the worker pane"
  assert_grep "nm_home=$override_nm" "$HOME_DIR/state/$override_id.meta" \
    "explicit NM_HOME override was not bound verbatim in metadata"

  newline_nm="$CASE_DIR/operator"$'\n'"nm-home"
  mkdir -p "$newline_nm"
  printf '%s\n' 'agent: [codex]' > "$newline_nm/config.yaml"
  : > "$LAUNCH_LOG"
  out=$(NM_HOME="$newline_nm" run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$newline_id" "$PROJ_DIR")
  status=$?
  [ "$status" -ne 0 ] || fail "explicit newline NM_HOME override was accepted"
  assert_contains "$out" "NM_HOME must be a single line" \
    "explicit newline NM_HOME refusal did not name the metadata constraint"
  [ ! -s "$LAUNCH_LOG" ] || fail "explicit newline NM_HOME reached launch submission"
  assert_absent "$HOME_DIR/state/$newline_id.meta" \
    "explicit newline NM_HOME published partial task metadata"

  # A non-no-mistakes ship (direct-PR) must not receive an NM_HOME export: the
  # binding is specific to the no-mistakes delivery path.
  : > "$LAUNCH_LOG"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$direct_id" "$PROJ_DIR" --mode direct-PR --yolo off)
  status=$?
  expect_code 0 "$status" "direct-PR spawn should succeed"
  launch=$(cat "$LAUNCH_LOG")
  case "$launch" in
    *"NM_HOME="*) fail "direct-PR launch received an NM_HOME export reserved for no-mistakes ships" ;;
  esac
  assert_no_grep "nm_home=" "$HOME_DIR/state/$direct_id.meta" \
    "direct-PR spawn recorded an nm_home binding reserved for no-mistakes ships"

  pass "no-mistakes spawn carries the resolved NM_HOME into the launch command and binds it per task in metadata"
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

# The load-bearing bookend gate (bin/fm-brief.sh --validate-bookends) is wired
# into bin/fm-spawn.sh before any endpoint or task-state creation. A ship brief
# whose two standalone {TASK} slots are not both filled must be refused before
# the backend creates a window, so a half-filled or divergent brief can never
# launch a worker. This drives the real spawn path with a fake tmux that logs
# new-window calls, and asserts the gate refuses and no endpoint is created.
test_spawn_refuses_unfilled_bookends_before_endpoint_creation() {
  local rec id out status endpoint_log
  id=profile-bookend-refuse-z30
  rec=$(make_spawn_case bookend-refuse codex "$id")
  read_case_record "$rec"
  endpoint_log="$CASE_DIR/endpoint.log"
  : > "$endpoint_log"
  # Replace the stub brief with a real unfilled ordinary ship brief so the
  # bookend gate sees the two standalone {TASK} slots and refuses.
  rm -f "$HOME_DIR/data/$id/brief.md"
  FM_HOME="$HOME_DIR" "$ROOT/bin/fm-brief.sh" "$id" "$PROJ_DIR" --mode no-mistakes >/dev/null 2>&1 \
    || fail "fm-brief.sh failed to scaffold a real ship brief for the bookend gate"
  grep -qx '^# Task$' "$HOME_DIR/data/$id/brief.md" || fail "real ship brief missing its # Task section"
  out=$(FM_TEST_ENDPOINT_LOG="$endpoint_log" run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model gpt-5 --effort medium --routing-source fallback 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a ship brief with unfilled {TASK} bookends"
  assert_contains "$out" "bookend check" "spawn refusal did not name the bookend gate"
  assert_contains "$out" "fill both standalone {TASK} slots" "spawn refusal did not point at the fill command"
  # No endpoint mutation: the fake tmux new-window hook never ran.
  [ ! -s "$endpoint_log" ] || fail "spawn created an endpoint before the bookend gate refused"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "spawn wrote task metadata before the bookend gate refused"
  pass "fm-spawn refuses an unfilled bookend brief before endpoint or task-state creation"
}

test_spawn_refuses_reader_bookends_before_endpoint_creation() {
  local rec id out status endpoint_log text_file
  id=profile-reader-bookend-refuse-z31
  rec=$(make_spawn_case reader-bookend-refuse codex "$id")
  read_case_record "$rec"
  endpoint_log="$CASE_DIR/endpoint.log"
  : > "$endpoint_log"
  rm -f "$HOME_DIR/data/$id/brief.md"
  FM_HOME="$HOME_DIR" "$ROOT/bin/fm-brief.sh" "$id" "$PROJ_DIR" --scout --access reader >/dev/null 2>&1 \
    || fail "fm-brief.sh failed to scaffold a real reader scout brief for the bookend gate"
  grep -qx '^# Task$' "$HOME_DIR/data/$id/brief.md" || fail "real reader brief missing its # Task section"
  out=$(FM_TEST_ENDPOINT_LOG="$endpoint_log" run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --scout --access reader --model gpt-5 --effort medium --routing-source fallback 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a reader scout brief with unfilled {TASK} bookends"
  assert_contains "$out" "bookend check" "reader spawn refusal did not name the bookend gate"
  assert_contains "$out" "fill both standalone {TASK} slots" "reader spawn refusal did not point at the fill command"
  [ ! -s "$endpoint_log" ] || fail "reader spawn created an endpoint before the bookend gate refused"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "reader spawn wrote task metadata before the bookend gate refused"

  rm -f "$HOME_DIR/data/$id/brief.md"
  FM_HOME="$HOME_DIR" "$ROOT/bin/fm-brief.sh" "$id" "$PROJ_DIR" --scout --access reader >/dev/null 2>&1 \
    || fail "fm-brief.sh failed to scaffold a divergent reader brief fixture"
  text_file="$CASE_DIR/reader-bookend-text.txt"
  printf 'Oracle: FM-READER-ORACLE-7f3a\nAcceptance: FM-READER-ACCEPT-7f3a\nConstraints: FM-READER-CONSTRAINT-7f3a\n' > "$text_file"
  FM_HOME="$HOME_DIR" "$ROOT/bin/fm-brief.sh" "$id" --fill "$text_file" >/dev/null 2>&1 \
    || fail "fm-brief.sh failed to fill the reader brief for the divergent gate"
  python3 - "$HOME_DIR/data/$id/brief.md" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
i=s.rfind("# Load-bearing contract")
open(p,"w").write(s[:i] + s[i:].replace("FM-READER-CONSTRAINT-7f3a","FM-READER-DIVERGE-7f3a",1))
PY
  out=$(FM_TEST_ENDPOINT_LOG="$endpoint_log" run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --scout --access reader --model gpt-5 --effort medium --routing-source fallback 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a reader scout brief with divergent bookends"
  assert_contains "$out" "bookend check" "divergent reader spawn refusal did not name the bookend gate"
  assert_contains "$out" "diverge" "divergent reader spawn refusal did not name the divergent pair"
  [ ! -s "$endpoint_log" ] || fail "divergent reader spawn created an endpoint before the bookend gate refused"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "divergent reader spawn wrote task metadata before the bookend gate refused"
  pass "fm-spawn refuses unfilled and divergent reader bookends before endpoint or task-state creation"
}

test_routing_source_recorded_only_when_declared
test_spawn_writes_routing_facts_into_intake
test_secondmate_config_provenance_requires_exclusive_complete_tuple
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
# --- the reader/writer access axis (--access, scouts only) ------------------
#
# A reader scout is dispatched slot-free: no `treehouse get`, no pool worktree.
# fm-spawn builds a disposable scratch directory at the task temp root, refuses
# to launch unless that directory resolves outside the primary checkout and
# outside every git work tree or git dir (the reader isolation enforcement
# predicate), creates a fresh per-launch bare object-store read handle at
# scratch/repo.git cloned from the launched project, and records access=reader
# in the task meta. Distinct guards protect that path and each is pinned through its
# own diagnostic so they can never be
# conflated: a symlinked task temp root or scratch entry is refused BEFORE the
# scratch mkdir ever runs ("sits behind a symlink"), so spawn never creates
# anything through an attacker-chosen path. The descendant-link guard allows
# only stable relative links that resolve within scratch. The symlink-free cases
# reach validate_reader_scratch itself and kill its mutants - the primary-checkout
# branch ("resolves into the primary checkout") via a project located at the
# task temp root, and the any-checkout branch ("is inside a git checkout or
# git dir") via a foreign repo grown at the task temp root.

# Ask the shipped owner of the reader temp-root spelling (fm_reader_task_tmp)
# where this task's root is, so these oracles follow fm-spawn and fm-teardown
# instead of pinning a third private copy of the path.
reader_task_tmp() {  # <task-id> [home]
  local id=$1 home=${2:-$HOME_DIR}
  (
    FM_HOME=$home FM_ROOT=$ROOT
    fm_reader_task_tmp "$id" || exit 1
    printf '%s\n' "$FM_READER_TASK_TMP"
  ) || fail "the reader temp-root owner refused to derive a path for $id"
}

reader_meta_value() {  # <meta> <key>
  grep "^$2=" "$1" | tail -1 | cut -d= -f2-
}

write_reader_brief() {  # <home> <task-id> [repo]
  local home=$1 id=$2 repo=${3:-project} text_file
  rm -f "$home/data/$id/brief.md"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" "$repo" --scout --access reader >/dev/null 2>&1 \
    || fail "write_reader_brief failed to scaffold $id"
  text_file="$TMP_ROOT/reader-brief-text-$id.txt"
  printf 'Fixture task for %s\n' "$id" > "$text_file"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" --fill "$text_file" >/dev/null 2>&1 \
    || fail "write_reader_brief failed to fill $id"
}

install_reader_realpath_test_double() {  # <fakebin>
  local fakebin=$1 real_realpath
  real_realpath=$(command -v realpath) || fail "reader symlink tests require realpath"
  cat > "$fakebin/realpath" <<'SH'
#!/usr/bin/env bash
set -eu
case "${FM_TEST_REALPATH_MODE:-delegate}" in
  resolution-error) exit 1 ;;
esac
"${FM_TEST_REALPATH_BIN:?}" "$@"
SH
  chmod +x "$fakebin/realpath"
  printf '%s\n' "$real_realpath"
}

test_reader_scout_spawn_skips_pool_and_builds_scratch() {
  local rec id out status task_tmp scratch_real proj_head cmdlog hook message hook_out hook_status launch
  id=access-reader-ok-z1
  rec=$(make_spawn_case access-reader-ok claude "$id")
  read_case_record "$rec"
  write_reader_brief "$HOME_DIR" "$id"
  task_tmp=$(reader_task_tmp "$id")
  rm -rf "$task_tmp" "/tmp/fm-$id"
  cmdlog="$CASE_DIR/tmux-cmd.log"

  out=$(FM_FAKE_TMUX_CMDLOG="$cmdlog" \
    run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --scout --access reader)
  status=$?
  expect_code 0 "$status" "reader scout spawn should succeed"
  assert_contains "$out" "spawned $id harness=claude kind=scout access=reader" \
    "reader spawn did not report the access axis"

  [ -d "$task_tmp/scratch" ] || fail "reader spawn did not create the scratch directory"
  scratch_real=$(cd "$task_tmp/scratch" && pwd -P)
  assert_grep "worktree=$scratch_real" "$HOME_DIR/state/$id.meta" \
    "reader meta did not record the scratch directory as its working directory"
  assert_grep "kind=scout" "$HOME_DIR/state/$id.meta" "reader meta lost kind=scout"
  assert_grep "access=reader" "$HOME_DIR/state/$id.meta" "reader meta did not record access=reader"

  [ "$(git --git-dir="$task_tmp/scratch/repo.git" rev-parse --is-bare-repository 2>/dev/null)" = true ] \
    || fail "reader spawn did not create a bare read handle at scratch/repo.git"
  proj_head=$(git -C "$PROJ_DIR" rev-parse HEAD)
  assert_grep "base_commit=$proj_head" "$HOME_DIR/state/$id.meta" \
    "reader meta did not record the read revision as base_commit"
  [ "$(git --git-dir="$task_tmp/scratch/repo.git" rev-parse HEAD)" = "$proj_head" ] \
    || fail "the reader read handle does not read the launched project's revision"

  grep -F "new-window" "$cmdlog" | grep -Fq "$scratch_real" \
    || fail "reader task window was not created in the scratch directory"
  assert_no_grep "treehouse get" "$cmdlog" \
    "reader spawn still sent treehouse get, which takes a pool slot"
  [ -s "$LAUNCH_LOG" ] || fail "reader spawn did not submit a launch command"
  grep -Fq "$HOME_DIR/data/$id/brief.md" "$LAUNCH_LOG" \
    || fail "reader launch command did not carry the brief"
  hook="$task_tmp/git-hooks/commit-msg"
  assert_present "$hook" "reader launch did not receive the ordinary-worker co-author sanitizer"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" 'core.hooksPath' \
    "reader launch did not select the task-local sanitizer relay"
  message="$CASE_DIR/reader-commit-message"
  printf 'Reader note\n\nCo-authored-by: Codex <codex@openai.com>\n' > "$message"
  hook_out=$("$hook" "$message" 2>&1)
  hook_status=$?
  expect_code 0 "$hook_status" "reader sanitizer relay should execute: $hook_out"
  assert_not_contains "$(cat "$message")" 'Codex <codex@openai.com>' \
    "reader sanitizer relay did not strip the recognized agent co-author"

  rm -rf "$task_tmp"
  pass "reader scout spawn is slot-free: scratch dir + bare read handle, no treehouse get"
}

test_reader_launch_cannot_write_absolute_project_path() {
  local rec id out status task_tmp scratch probe raw exec_status
  id=access-reader-process-boundary-z16
  rec=$(make_spawn_case access-reader-process-boundary claude "$id")
  read_case_record "$rec"
  write_reader_brief "$HOME_DIR" "$id"
  task_tmp=$(reader_task_tmp "$id")
  scratch="$task_tmp/scratch"
  rm -rf "$task_tmp"
  probe="$CASE_DIR/reader-probe.sh"
  cat > "$probe" <<'SH'
#!/usr/bin/env bash
set -u
project_file=$1
scratch=$2
handle=$3
if printf 'reader boundary violation\n' >> "$project_file" 2>/dev/null; then
  project_write=allowed
else
  project_write=denied
fi
printf 'scratch write allowed\n' > "$scratch/scratch-write.txt"
if git --git-dir="$handle" show HEAD:README.md > "$scratch/read-handle.txt"; then
  read_handle=allowed
else
  read_handle=denied
fi
printf 'project_write=%s\nread_handle=%s\n' "$project_write" "$read_handle" > "$scratch/probe-result"
SH
  chmod +x "$probe"
  raw="$probe $PROJ_DIR/README.md $scratch $scratch/repo.git"
  exec_status="$CASE_DIR/exec.status"

  out=$(FM_FAKE_EXEC_LAUNCH=1 FM_FAKE_EXEC_CWD="$scratch" \
    FM_FAKE_EXEC_STDOUT="$CASE_DIR/exec.stdout" FM_FAKE_EXEC_STDERR="$CASE_DIR/exec.stderr" \
    FM_FAKE_EXEC_STATUS="$exec_status" \
    run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
      --scout --access reader --harness "$raw")
  status=$?
  expect_code 0 "$status" "reader scout spawn should submit its confined launch"
  [ "$(cat "$exec_status")" = 0 ] || fail "the launched reader probe did not complete"
  grep -qx 'project_write=denied' "$scratch/probe-result" \
    || fail "the launched reader wrote a tracked file through the absolute project path"
  [ -z "$(git -C "$PROJ_DIR" status --porcelain)" ] \
    || fail "the launched reader left the project checkout dirty"
  grep -qx 'scratch write allowed' "$scratch/scratch-write.txt" \
    || fail "process confinement blocked the reader's own scratch writes"
  grep -qx 'read_handle=allowed' "$scratch/probe-result" \
    || fail "process confinement blocked Git reads through the bare handle"
  cmp -s "$PROJ_DIR/README.md" "$scratch/read-handle.txt" \
    || fail "the confined read handle returned different tracked content"

  rm -rf "$task_tmp"
  pass "reader launch confinement denies absolute tracked writes while preserving scratch and Git reads"
}

test_reader_spawn_does_not_probe_harness_version_outside_confinement() {
  local rec id out status task_tmp probe raw project_status
  id=access-reader-version-probe-z19
  rec=$(make_spawn_case access-reader-version-probe claude "$id")
  read_case_record "$rec"
  write_reader_brief "$HOME_DIR" "$id"
  task_tmp=$(reader_task_tmp "$id")
  rm -rf "$task_tmp"
  probe="$FAKEBIN_DIR/side-effecting-harness"
  cat > "$probe" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = --version ]; then
  printf 'unconfined version probe\n' >> "${FM_TEST_READER_PROJECT_FILE:?}"
  printf 'side-effecting-harness 1.0\n'
fi
SH
  chmod +x "$probe"
  raw="side-effecting-harness --run"

  out=$(FM_TEST_READER_PROJECT_FILE="$PROJ_DIR/README.md" \
    run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
      --scout --access reader --harness "$raw")
  status=$?
  expect_code 0 "$status" "reader scout spawn should submit its confined launch"
  project_status=$(git -C "$PROJ_DIR" status --porcelain)

  rm -rf "$task_tmp"
  [ -z "$project_status" ] \
    || fail "reader spawn executed the harness version probe outside confinement"
  pass "reader spawn never probes its harness version outside confinement"
}

# The read handle is READ access only: `git clone --bare --shared` records
# origin=<project>, and a push through it deletes any project branch that is
# not the project's checked-out one - on this repo, another task's unlanded
# fm/<id> work. The reader boundary is enforced, not promised, so the shipped
# handle must carry no configured ref-write path while every read still works.
test_reader_read_handle_holds_no_ref_write_path_to_project() {
  local rec id out status task_tmp handle push_out push_status proj_head
  id=access-reader-no-origin-z15
  rec=$(make_spawn_case access-reader-no-origin claude "$id")
  read_case_record "$rec"
  write_reader_brief "$HOME_DIR" "$id"
  task_tmp=$(reader_task_tmp "$id")
  rm -rf "$task_tmp"
  git -C "$PROJ_DIR" branch fm/victim-task

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --scout --access reader)
  status=$?
  expect_code 0 "$status" "reader scout spawn should succeed"
  handle="$task_tmp/scratch/repo.git"

  [ -z "$(git --git-dir="$handle" remote)" ] \
    || fail "the reader read handle still records a remote, a configured ref-write path into the project it may only read"

  push_out=$(git --git-dir="$handle" push origin --delete fm/victim-task 2>&1)
  push_status=$?
  [ "$push_status" -ne 0 ] \
    || fail "a reader-side ref write reached the project through the read handle: $push_out"
  git -C "$PROJ_DIR" rev-parse --verify -q fm/victim-task >/dev/null \
    || fail "a reader-side push deleted a branch in the project the reader may only read"

  proj_head=$(git -C "$PROJ_DIR" rev-parse HEAD)
  [ "$(git --git-dir="$handle" rev-parse HEAD)" = "$proj_head" ] \
    || fail "closing the ref-write path cost the reader its view of the project revision"
  [ "$(git --git-dir="$handle" show "$proj_head:README.md")" = "$(cat "$PROJ_DIR/README.md")" ] \
    || fail "closing the ref-write path cost the reader object-store reads"
  git --git-dir="$handle" archive "$proj_head" | tar -tf - | grep -qx README.md \
    || fail "closing the ref-write path cost the reader archive snapshots"

  rm -rf "$task_tmp"
  pass "the reader read handle keeps object-store reads with no ref-write path back into the project"
}

test_reader_same_id_scopes_scratch_by_home_identity() {
  local rec id out status home_one proj_one meta_one tmp_one head_one
  local home_two proj_two meta_two tmp_two head_two
  id=access-reader-home-scope-z7

  rec=$(make_spawn_case access-reader-home-one claude "$id")
  read_case_record "$rec"
  write_reader_brief "$HOME_DIR" "$id"
  rm -rf "$(reader_task_tmp "$id" "$HOME_DIR")" "/tmp/fm-$id"
  home_one=$HOME_DIR
  proj_one=$PROJ_DIR
  meta_one="$HOME_DIR/state/$id.meta"
  head_one=$(git -C "$PROJ_DIR" rev-parse HEAD)
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --scout --access reader)
  status=$?
  expect_code 0 "$status" "the first home reader spawn should succeed"
  tmp_one=$(reader_meta_value "$meta_one" tasktmp)

  rec=$(make_spawn_case access-reader-home-two claude "$id")
  read_case_record "$rec"
  write_reader_brief "$HOME_DIR" "$id"
  printf '%s\n' second-home > "$HOME_DIR/.fm-secondmate-home"
  rm -rf "$(reader_task_tmp "$id" "$HOME_DIR")"
  printf '%s\n' second-home > "$PROJ_DIR/second-home.txt"
  git -C "$PROJ_DIR" add second-home.txt
  git -C "$PROJ_DIR" -c user.email=t@t -c user.name=t commit -q -m "second home identity"
  home_two=$HOME_DIR
  proj_two=$PROJ_DIR
  meta_two="$HOME_DIR/state/$id.meta"
  head_two=$(git -C "$PROJ_DIR" rev-parse HEAD)
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --scout --access reader)
  status=$?
  expect_code 0 "$status" "the second home reader spawn should succeed"
  tmp_two=$(reader_meta_value "$meta_two" tasktmp)

  [ "$tmp_one" != "$tmp_two" ] \
    || fail "two homes with the same reader task id shared one task temp root"
  [ "$(git --git-dir="$tmp_one/scratch/repo.git" rev-parse HEAD)" = "$head_one" ] \
    || fail "the first home's reader handle changed after the second home spawned"
  [ "$(git --git-dir="$tmp_two/scratch/repo.git" rev-parse HEAD)" = "$head_two" ] \
    || fail "the second home's reader handle points at the first home's project"
  [ "$home_one" != "$home_two" ] && [ "$proj_one" != "$proj_two" ] \
    || fail "reader home-scope fixture did not create distinct homes and projects"

  rm -rf "$tmp_one" "$tmp_two"
  pass "reader task temp roots are scoped by home identity"
}

test_reader_access_flag_is_scout_only_and_closed_set() {
  local rec id out status
  id=access-reader-flags-z2
  rec=$(make_spawn_case access-reader-flags claude "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --mode no-mistakes --yolo off --access reader)
  status=$?
  [ "$status" -ne 0 ] || fail "--access reader on a ship spawn should be refused"
  assert_contains "$out" "--access applies only to scout spawns" \
    "ship access refusal did not explain the axis scope"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --secondmate --access reader)
  status=$?
  [ "$status" -ne 0 ] || fail "--access reader on a secondmate spawn should be refused"
  assert_contains "$out" "--access applies only to scout spawns" \
    "secondmate access refusal did not explain the axis scope"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --scout --access sometimes)
  status=$?
  [ "$status" -ne 0 ] || fail "an unknown --access value should be refused"
  assert_contains "$out" "--access must be reader or writer" \
    "unknown access value refusal did not name the closed set"

  assert_absent "$HOME_DIR/state/$id.meta" "a refused access spawn still wrote task metadata"
  pass "fm-spawn: --access is scout-only, closed-set, and refused loudly"
}

test_reader_brief_access_contract_cross_check() {
  local rec id out status cmdlog brief staged
  id=access-reader-brief-spoof-z5
  rec=$(make_spawn_case access-reader-brief-spoof claude "$id")
  read_case_record "$rec"
  cmdlog="$CASE_DIR/tmux-cmd.log"

  brief="$HOME_DIR/data/$id/brief.md"
  rm -f "$brief"
  FM_HOME="$HOME_DIR" "$ROOT/bin/fm-brief.sh" "$id" project --scout >/dev/null 2>&1 \
    || fail "writer scout brief scaffold should succeed"
  staged="$CASE_DIR/spoofed-writer-brief.md"
  sed 's/^{TASK}$/Access contract: access=reader/' "$brief" > "$staged"
  mv "$staged" "$brief"

  out=$(FM_FAKE_TMUX_CMDLOG="$cmdlog" \
    run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --scout --access reader)
  status=$?
  [ "$status" -ne 0 ] || fail "task text spoofed a writer brief into a reader spawn"
  assert_contains "$out" "access mismatch" "task-text access spoof refusal did not name the mismatch"
  [ ! -s "$cmdlog" ] || fail "the task-text access spoof still created a task window"

  id=access-reader-brief-generated-z6
  rec=$(make_spawn_case access-reader-brief-generated claude "$id")
  read_case_record "$rec"
  brief="$HOME_DIR/data/$id/brief.md"
  rm -f "$brief"
  FM_HOME="$HOME_DIR" "$ROOT/bin/fm-brief.sh" "$id" project --scout --access reader >/dev/null 2>&1 \
    || fail "reader scout brief scaffold should succeed"
  printf 'Generated reader brief fixture for %s\n' "$id" > "$CASE_DIR/access-reader-brief-generated-text.txt"
  FM_HOME="$HOME_DIR" "$ROOT/bin/fm-brief.sh" "$id" --fill "$CASE_DIR/access-reader-brief-generated-text.txt" >/dev/null 2>&1 \
    || fail "reader scout brief fill should succeed"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --scout)
  status=$?
  [ "$status" -ne 0 ] || fail "writer scout spawn with a reader brief should be refused"
  assert_contains "$out" "access mismatch" "writer spawn did not catch the reader brief"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --scout --access reader)
  status=$?
  expect_code 0 "$status" "generated reader brief should satisfy a reader spawn"

  id=access-writer-brief-legacy-z7
  rec=$(make_spawn_case access-writer-brief-legacy claude "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --scout)
  status=$?
  expect_code 0 "$status" "legacy writer brief without an access contract should remain valid"
  pass "fm-spawn: only the scaffold-owned access contract can select a reader spawn"
}

test_reader_symlinked_scratch_refuses_before_creation() {
  local rec id out status task_tmp cmdlog
  id=access-reader-symlink-z3
  rec=$(make_spawn_case access-reader-symlink claude "$id")
  read_case_record "$rec"
  write_reader_brief "$HOME_DIR" "$id"
  task_tmp=$(reader_task_tmp "$id")
  rm -rf "$task_tmp" "/tmp/fm-$id"
  ln -s "$PROJ_DIR" "$task_tmp"
  cmdlog="$CASE_DIR/tmux-cmd.log"

  out=$(FM_FAKE_TMUX_CMDLOG="$cmdlog" \
    run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --scout --access reader)
  status=$?
  [ "$status" -ne 0 ] || fail "a symlinked reader task temp root must refuse to launch"
  assert_contains "$out" "sits behind a symlink" "symlinked task temp root refusal did not name the symlink gate"
  [ ! -e "$PROJ_DIR/scratch" ] || fail "the refused reader spawn created a scratch entry inside the symlink target"
  [ ! -s "$cmdlog" ] || fail "the refused reader spawn still created a task window"
  assert_absent "$HOME_DIR/state/$id.meta" "the refused reader spawn still wrote task metadata"
  rm -f "$task_tmp"

  mkdir -p "$task_tmp"
  ln -s "$PROJ_DIR" "$task_tmp/scratch"
  out=$(FM_FAKE_TMUX_CMDLOG="$cmdlog" \
    run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --scout --access reader)
  status=$?
  [ "$status" -ne 0 ] || fail "a reader scratch entry that is itself a symlink must refuse to launch"
  assert_contains "$out" "sits behind a symlink" "symlinked scratch entry refusal did not name the symlink gate"
  [ ! -s "$cmdlog" ] || fail "the refused reader spawn still created a task window"
  assert_absent "$HOME_DIR/state/$id.meta" "the refused reader spawn still wrote task metadata"

  rm -rf "$task_tmp"
  pass "reader symlink gate: a symlinked task temp root or scratch entry refuses to launch before anything is created through it"
}

test_reader_scratch_predicate_refuses_primary_checkout() {
  local rec id out status task_tmp cmdlog
  id=access-reader-prim-z4
  rec=$(make_spawn_case access-reader-prim claude "$id")
  read_case_record "$rec"
  write_reader_brief "$HOME_DIR" "$id"
  task_tmp=$(reader_task_tmp "$id")
  rm -rf "$task_tmp"
  fm_git_init_commit "$task_tmp"
  cmdlog="$CASE_DIR/tmux-cmd.log"

  out=$(FM_FAKE_TMUX_CMDLOG="$cmdlog" \
    run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$task_tmp" --scout --access reader)
  status=$?
  [ "$status" -ne 0 ] || fail "a symlink-free reader scratch resolving into the primary checkout must refuse to launch"
  assert_contains "$out" "resolves into the primary checkout" \
    "primary-checkout refusal did not come from the isolation predicate's own branch"
  [ ! -s "$cmdlog" ] || fail "the refused reader spawn still created a task window"
  assert_absent "$HOME_DIR/state/$id.meta" "the refused reader spawn still wrote task metadata"

  rm -rf "$task_tmp"
  pass "reader predicate: a scratch inside the primary checkout refuses to launch through the predicate's primary-checkout branch"
}

test_reader_scratch_predicate_refuses_any_checkout() {
  local rec id out status task_tmp cmdlog
  id=access-reader-foreign-z5
  rec=$(make_spawn_case access-reader-foreign claude "$id")
  read_case_record "$rec"
  write_reader_brief "$HOME_DIR" "$id"
  task_tmp=$(reader_task_tmp "$id")
  rm -rf "$task_tmp"
  mkdir -p "$task_tmp/scratch"
  git init -q "$task_tmp"
  cmdlog="$CASE_DIR/tmux-cmd.log"

  out=$(FM_FAKE_TMUX_CMDLOG="$cmdlog" \
    run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --scout --access reader)
  status=$?
  [ "$status" -ne 0 ] || fail "a symlink-free reader scratch inside ANY git checkout must refuse to launch, not just the primary"
  assert_contains "$out" "is inside a git checkout or git dir" \
    "foreign-checkout refusal did not come from the isolation predicate's own branch"
  [ ! -s "$cmdlog" ] || fail "the refused reader spawn still created a task window"
  assert_absent "$HOME_DIR/state/$id.meta" "the refused reader spawn still wrote task metadata"

  rm -rf "$task_tmp"
  pass "reader predicate: a scratch inside any git checkout refuses to launch through the predicate's git branch"
}

test_reader_scratch_predicate_refuses_descendant_checkout() {
  local rec id out status task_tmp cmdlog
  id=access-reader-descendant-z6
  rec=$(make_spawn_case access-reader-descendant claude "$id")
  read_case_record "$rec"
  write_reader_brief "$HOME_DIR" "$id"
  task_tmp=$(reader_task_tmp "$id")
  rm -rf "$task_tmp"
  mkdir -p "$task_tmp/scratch"
  git init -q "$task_tmp/scratch/hack"
  cmdlog="$CASE_DIR/tmux-cmd.log"

  out=$(FM_FAKE_TMUX_CMDLOG="$cmdlog" \
    run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --scout --access reader)
  status=$?
  [ "$status" -ne 0 ] || fail "a reader scratch containing a descendant checkout must refuse to launch"
  assert_contains "$out" "contains a git checkout" \
    "descendant-checkout refusal did not come from the isolation predicate"
  [ -d "$task_tmp/scratch/hack/.git" ] || fail "the refusal removed the descendant checkout"
  [ ! -s "$cmdlog" ] || fail "the refused reader spawn still created a task window"
  assert_absent "$HOME_DIR/state/$id.meta" "the refused reader spawn still wrote task metadata"

  rm -rf "$task_tmp"
  pass "reader predicate: a descendant checkout in stale scratch refuses launch"
}

test_reader_scratch_predicate_allows_contained_archive_symlink_on_relaunch() {
  local rec id out status task_tmp cmdlog
  id=access-reader-contained-link-z8
  rec=$(make_spawn_case access-reader-contained-link claude "$id")
  read_case_record "$rec"
  write_reader_brief "$HOME_DIR" "$id"
  printf 'archive target\n' > "$PROJ_DIR/archive-target.txt"
  ln -s archive-target.txt "$PROJ_DIR/archive-link.txt"
  git -C "$PROJ_DIR" add archive-target.txt archive-link.txt
  git -C "$PROJ_DIR" -c user.email=t@t -c user.name=t commit -q -m "reader archive symlink fixture"
  task_tmp=$(reader_task_tmp "$id")
  rm -rf "$task_tmp"
  cmdlog="$CASE_DIR/tmux-cmd.log"

  out=$(FM_FAKE_TMUX_CMDLOG="$cmdlog" \
    run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --scout --access reader)
  status=$?
  expect_code 0 "$status" "the initial reader spawn should succeed before extracting a snapshot"
  mkdir -p "$task_tmp/scratch/snapshot"
  git --git-dir="$task_tmp/scratch/repo.git" archive HEAD \
    | tar -x -C "$task_tmp/scratch/snapshot" \
    || fail "could not extract the sanctioned reader archive snapshot"
  [ -L "$task_tmp/scratch/snapshot/archive-link.txt" ] \
    || fail "git archive did not preserve the tracked relative symlink fixture"
  [ "$(cat "$task_tmp/scratch/snapshot/archive-link.txt")" = "archive target" ] \
    || fail "the archived relative symlink did not resolve inside reader scratch"

  : > "$cmdlog"
  out=$(FM_FAKE_TMUX_CMDLOG="$cmdlog" \
    run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --scout --access reader)
  status=$?
  expect_code 0 "$status" "a reader relaunch should allow an existing relative symlink contained within scratch"
  [ -s "$LAUNCH_LOG" ] || fail "the contained archive symlink prevented reader relaunch submission"
  assert_grep "access=reader" "$HOME_DIR/state/$id.meta" \
    "the relaunched contained-symlink reader lost its access contract"

  rm -rf "$task_tmp"
  pass "reader predicate: a contained Git-archive symlink survives reader relaunch"
}

test_reader_scratch_predicate_refuses_absolute_descendant_symlink() {
  local rec id out status task_tmp cmdlog
  id=access-reader-absolute-link-z9
  rec=$(make_spawn_case access-reader-absolute-link claude "$id")
  read_case_record "$rec"
  write_reader_brief "$HOME_DIR" "$id"
  task_tmp=$(reader_task_tmp "$id")
  rm -rf "$task_tmp"
  mkdir -p "$task_tmp/scratch"
  ln -s "$PROJ_DIR" "$task_tmp/scratch/project"
  cmdlog="$CASE_DIR/tmux-cmd.log"

  out=$(FM_FAKE_TMUX_CMDLOG="$cmdlog" \
    run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --scout --access reader)
  status=$?
  [ "$status" -ne 0 ] || fail "a reader scratch containing an absolute descendant symlink must refuse to launch"
  assert_contains "$out" "uses an absolute target" \
    "absolute descendant-symlink refusal did not name the unsafe target class"
  [ -L "$task_tmp/scratch/project" ] || fail "the refusal removed the descendant symlink"
  [ ! -s "$cmdlog" ] || fail "the refused reader spawn still created a task window"
  assert_absent "$HOME_DIR/state/$id.meta" "the refused reader spawn still wrote task metadata"
  assert_absent "$task_tmp/scratch/repo.git" "the refused reader spawn still created a read handle"

  rm -rf "$task_tmp"
  pass "reader predicate: an absolute descendant symlink refuses launch"
}

test_reader_scratch_predicate_refuses_unresolvable_or_escaping_symlinks() {
  local class rec id out status task_tmp scratch cmdlog expected real_realpath=
  for class in relative-outside dangling cyclic resolution-error; do
    id="access-reader-${class}-link-z10"
    rec=$(make_spawn_case "access-reader-${class}-link" claude "$id")
    read_case_record "$rec"
    write_reader_brief "$HOME_DIR" "$id"
    task_tmp=$(reader_task_tmp "$id")
    rm -rf "$task_tmp"
    scratch="$task_tmp/scratch"
    mkdir -p "$scratch"
    cmdlog="$CASE_DIR/tmux-cmd.log"
    case "$class" in
      relative-outside)
        mkdir -p "$task_tmp/outside"
        printf 'outside scratch\n' > "$task_tmp/outside/secret.txt"
        ln -s ../outside "$scratch/link"
        expected="resolves outside"
        ;;
      dangling)
        ln -s missing "$scratch/link"
        expected="cannot be resolved"
        ;;
      cyclic)
        ln -s cycle "$scratch/link"
        ln -s link "$scratch/cycle"
        expected="cannot be resolved"
        ;;
      resolution-error)
        printf 'inside scratch\n' > "$scratch/target"
        ln -s target "$scratch/link"
        real_realpath=$(install_reader_realpath_test_double "$FAKEBIN_DIR")
        expected="cannot be resolved"
        ;;
    esac

    if [ "$class" = resolution-error ]; then
      out=$(FM_TEST_REALPATH_MODE=resolution-error FM_TEST_REALPATH_BIN="$real_realpath" \
        FM_FAKE_TMUX_CMDLOG="$cmdlog" \
        run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --scout --access reader)
    else
      out=$(FM_FAKE_TMUX_CMDLOG="$cmdlog" \
        run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --scout --access reader)
    fi
    status=$?
    [ "$status" -ne 0 ] || fail "a reader scratch containing a $class symlink must refuse to launch"
    assert_contains "$out" "$expected" "$class symlink refusal did not name its unsafe resolution"
    [ -d "$scratch" ] || fail "$class symlink refusal removed reader scratch"
    [ -L "$scratch/link" ] || fail "$class symlink refusal removed the planted link"
    [ ! -s "$cmdlog" ] || fail "$class symlink refusal still created a task window"
    [ ! -s "$LAUNCH_LOG" ] || fail "$class symlink refusal still submitted a harness launch"
    assert_absent "$HOME_DIR/state/$id.meta" "$class symlink refusal still wrote task metadata"
    assert_absent "$scratch/repo.git" "$class symlink refusal still created a read handle"
    rm -rf "$task_tmp"
  done
  pass "reader predicate: outside, dangling, cyclic, and resolution-error symlinks refuse without launch"
}

test_reader_stale_handle_replaced_with_current_project() {
  local rec id out status task_tmp foreign proj_head
  id=access-reader-stale-handle-z11
  rec=$(make_spawn_case access-reader-stale-handle claude "$id")
  read_case_record "$rec"
  write_reader_brief "$HOME_DIR" "$id"
  task_tmp=$(reader_task_tmp "$id")
  rm -rf "$task_tmp"
  mkdir -p "$task_tmp/scratch"
  foreign="$CASE_DIR/foreign-project"
  mkdir -p "$foreign"
  git -C "$foreign" init -q
  printf 'foreign\n' > "$foreign/foreign.txt"
  git -C "$foreign" add foreign.txt
  git -C "$foreign" -c user.email=t@t -c user.name=t commit -q -m "foreign repo"
  git clone -q --bare --shared "$foreign" "$task_tmp/scratch/repo.git"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --scout --access reader)
  status=$?
  expect_code 0 "$status" "a reader spawn over a stale foreign handle should succeed with a fresh handle"
  proj_head=$(git -C "$PROJ_DIR" rev-parse HEAD)
  [ "$(git --git-dir="$task_tmp/scratch/repo.git" rev-parse HEAD)" = "$proj_head" ] \
    || fail "the reader read handle still reads the stale foreign repository instead of the launched project"
  assert_grep "base_commit=$proj_head" "$HOME_DIR/state/$id.meta" \
    "reader meta did not record the launched project's revision as base_commit"

  rm -rf "$task_tmp"
  pass "reader handle is per-launch: a stale foreign handle is replaced by a clone of the launched project"
}

test_reader_relaunch_onto_different_project_refuses_loudly() {
  local rec id out status task_tmp other first_head
  id=access-reader-project-flip-z12
  rec=$(make_spawn_case access-reader-project-flip claude "$id")
  read_case_record "$rec"
  write_reader_brief "$HOME_DIR" "$id"
  task_tmp=$(reader_task_tmp "$id")
  rm -rf "$task_tmp"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --scout --access reader)
  status=$?
  expect_code 0 "$status" "the initial reader spawn should succeed"
  first_head=$(git -C "$PROJ_DIR" rev-parse HEAD)

  other="$CASE_DIR/other-project"
  mkdir -p "$other"
  git -C "$other" init -q
  printf 'other\n' > "$other/other.txt"
  git -C "$other" add other.txt
  git -C "$other" -c user.email=t@t -c user.name=t commit -q -m "other repo"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$other" --scout --access reader)
  status=$?
  [ "$status" -ne 0 ] \
    || fail "a reader relaunch pointed at a different project must refuse, not silently record one project while reading another"
  assert_contains "$out" "refusing to replace its launch boundary" \
    "the cross-project reader relaunch refusal did not name the launch boundary"
  assert_grep "base_commit=$first_head" "$HOME_DIR/state/$id.meta" \
    "the refused cross-project relaunch overwrote the original launch boundary"

  rm -rf "$task_tmp"
  pass "reader relaunch onto a different project refuses instead of mixing repositories"
}

test_access_flip_on_existing_task_refuses() {
  local rec id out status task_tmp
  id=access-flip-z13
  rec=$(make_spawn_case access-flip claude "$id")
  read_case_record "$rec"
  task_tmp=$(reader_task_tmp "$id")
  rm -rf "$task_tmp"

  mkdir -p "$HOME_DIR/state"
  printf 'window=firstmate:fm-%s\nendpoint_task_id=%s\nworktree=%s\nproject=%s\nharness=claude\nkind=scout\ntasktmp=/tmp/fm-%s\n' \
    "$id" "$id" "$WT_DIR" "$PROJ_DIR" "$id" > "$HOME_DIR/state/$id.meta"
  write_reader_brief "$HOME_DIR" "$id"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --scout --access reader)
  status=$?
  [ "$status" -ne 0 ] \
    || fail "a reader relaunch of an existing writer task must refuse before overwriting its pool lease record"
  assert_contains "$out" "leak the pool lease" \
    "the writer-to-reader flip refusal did not name the leaked pool lease"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "the refused writer-to-reader flip overwrote the writer's pool worktree record"
  [ ! -e "$task_tmp" ] || fail "the refused writer-to-reader flip still created a reader temp root"

  printf 'window=firstmate:fm-%s\nendpoint_task_id=%s\nworktree=%s/scratch\nproject=%s\nharness=claude\nkind=scout\naccess=reader\ntasktmp=%s\n' \
    "$id" "$id" "$task_tmp" "$PROJ_DIR" "$task_tmp" > "$HOME_DIR/state/$id.meta"
  printf 'brief for %s\n' "$id" > "$HOME_DIR/data/$id/brief.md"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --scout)
  status=$?
  [ "$status" -ne 0 ] \
    || fail "a writer relaunch of an existing reader task must refuse before orphaning its scratch record"
  assert_contains "$out" "orphan its scratch cleanup" \
    "the reader-to-writer flip refusal did not name the orphaned scratch"
  assert_grep "access=reader" "$HOME_DIR/state/$id.meta" \
    "the refused reader-to-writer flip overwrote the reader's access record"

  printf 'window=firstmate:fm-%s\nendpoint_task_id=%s\nworktree=%s/scratch\nproject=%s\nharness=claude\nkind=scout\naccess=sometimes\ntasktmp=%s\n' \
    "$id" "$id" "$task_tmp" "$PROJ_DIR" "$task_tmp" > "$HOME_DIR/state/$id.meta"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --scout)
  status=$?
  [ "$status" -ne 0 ] \
    || fail "a writer relaunch over an unknown access record must refuse instead of laundering the damaged meta"
  assert_contains "$out" "unknown access" \
    "the unknown-access writer relaunch refusal did not name the record damage"
  assert_grep "access=sometimes" "$HOME_DIR/state/$id.meta" \
    "the refused unknown-access writer relaunch rewrote the damaged record"

  write_reader_brief "$HOME_DIR" "$id"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --scout --access reader)
  status=$?
  [ "$status" -ne 0 ] \
    || fail "a reader relaunch over an unknown access record must refuse instead of laundering the damaged meta"
  assert_contains "$out" "unknown access" \
    "the unknown-access reader relaunch refusal did not name the record damage"
  assert_grep "access=sometimes" "$HOME_DIR/state/$id.meta" \
    "the refused unknown-access reader relaunch rewrote the damaged record"

  rm -rf "$task_tmp"
  pass "the access axis of an existing task id is immutable: flips and unknown values refuse in both directions"
}

test_duplicate_access_record_refuses_before_reader_relaunch_mutation() {
  local rec id out status task_tmp before
  id=access-duplicate-z14
  rec=$(make_spawn_case access-duplicate claude "$id")
  read_case_record "$rec"
  task_tmp=$(reader_task_tmp "$id")
  rm -rf "$task_tmp"

  printf 'window=firstmate:fm-%s\nendpoint_task_id=%s\nworktree=%s\nproject=%s\nharness=claude\nkind=scout\naccess=writer\naccess=reader\ntasktmp=/tmp/fm-%s\n' \
    "$id" "$id" "$WT_DIR" "$PROJ_DIR" "$id" > "$HOME_DIR/state/$id.meta"
  before=$(cat "$HOME_DIR/state/$id.meta")
  write_reader_brief "$HOME_DIR" "$id"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --scout --access reader)
  status=$?
  [ "$status" -ne 0 ] \
    || fail "a reader relaunch over duplicate access metadata must refuse before laundering a writer pool lease"
  assert_contains "$out" "ambiguous access" \
    "the duplicate-access refusal did not name the ambiguous task record"
  [ "$(cat "$HOME_DIR/state/$id.meta")" = "$before" ] \
    || fail "the duplicate-access refusal rewrote the writer's task record"
  [ ! -e "$task_tmp" ] \
    || fail "the duplicate-access refusal still created a reader temp root"
  [ ! -s "$LAUNCH_LOG" ] \
    || fail "the duplicate-access refusal launched a reader over the writer record"
  pass "duplicate access metadata refuses before reader relaunch mutation"
}

test_reader_relaunch_refuses_missing_base_commit_before_mutation() {
  local rec id out status task_tmp meta before cmdlog
  id=access-reader-missing-base-z17
  rec=$(make_spawn_case access-reader-missing-base claude "$id")
  read_case_record "$rec"
  write_reader_brief "$HOME_DIR" "$id"
  task_tmp=$(reader_task_tmp "$id")
  rm -rf "$task_tmp"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --scout --access reader)
  status=$?
  expect_code 0 "$status" "the initial reader spawn should succeed"

  meta="$HOME_DIR/state/$id.meta"
  grep -v '^base_commit=' "$meta" > "$meta.next"
  mv "$meta.next" "$meta"
  touch "$task_tmp/scratch/repo.git/FM-TEST-SENTINEL"
  before=$(cat "$meta")
  : > "$LAUNCH_LOG"
  cmdlog="$CASE_DIR/relaunch-tmux.log"
  : > "$cmdlog"

  out=$(FM_FAKE_TMUX_CMDLOG="$cmdlog" \
    run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --scout --access reader)
  status=$?
  [ "$status" -ne 0 ] \
    || fail "a reader relaunch without base_commit replaced its handle and advanced the task baseline"
  assert_contains "$out" "exactly one non-empty base_commit" \
    "the missing-baseline refusal did not name the damaged reader record"
  [ "$(cat "$meta")" = "$before" ] \
    || fail "the missing-baseline refusal rewrote the reader task record"
  [ -f "$task_tmp/scratch/repo.git/FM-TEST-SENTINEL" ] \
    || fail "the missing-baseline refusal replaced the existing reader handle"
  assert_no_grep "list-windows" "$cmdlog" \
    "the missing-baseline refusal checked endpoint liveness before validating the baseline"
  [ ! -s "$LAUNCH_LOG" ] \
    || fail "the missing-baseline refusal submitted another reader launch"

  rm -rf "$task_tmp"
  pass "reader relaunch refuses a missing immutable baseline before mutation"
}

test_reader_relaunch_refuses_duplicate_base_commit_before_mutation() {
  local rec id out status task_tmp meta base_commit before cmdlog
  id=access-reader-duplicate-base-z18
  rec=$(make_spawn_case access-reader-duplicate-base claude "$id")
  read_case_record "$rec"
  write_reader_brief "$HOME_DIR" "$id"
  task_tmp=$(reader_task_tmp "$id")
  rm -rf "$task_tmp"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --scout --access reader)
  status=$?
  expect_code 0 "$status" "the initial reader spawn should succeed"

  meta="$HOME_DIR/state/$id.meta"
  base_commit=$(reader_meta_value "$meta" base_commit)
  printf 'base_commit=%s\n' "$base_commit" >> "$meta"
  touch "$task_tmp/scratch/repo.git/FM-TEST-SENTINEL"
  before=$(cat "$meta")
  : > "$LAUNCH_LOG"
  cmdlog="$CASE_DIR/relaunch-tmux.log"
  : > "$cmdlog"

  out=$(FM_FAKE_TMUX_CMDLOG="$cmdlog" \
    run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --scout --access reader)
  status=$?
  [ "$status" -ne 0 ] \
    || fail "a reader relaunch with duplicate base_commit values replaced its handle and laundered the task record"
  assert_contains "$out" "exactly one non-empty base_commit" \
    "the duplicate-baseline refusal did not name the ambiguous reader record"
  [ "$(cat "$meta")" = "$before" ] \
    || fail "the duplicate-baseline refusal rewrote the reader task record"
  [ -f "$task_tmp/scratch/repo.git/FM-TEST-SENTINEL" ] \
    || fail "the duplicate-baseline refusal replaced the existing reader handle"
  assert_no_grep "list-windows" "$cmdlog" \
    "the duplicate-baseline refusal checked endpoint liveness before validating the baseline"
  [ ! -s "$LAUNCH_LOG" ] \
    || fail "the duplicate-baseline refusal submitted another reader launch"

  rm -rf "$task_tmp"
  pass "reader relaunch refuses duplicate immutable baselines before mutation"
}

test_reader_live_duplicate_refuses_before_handle_replacement() {
  local rec id out status task_tmp base_commit advanced_head
  id=access-reader-live-dup-z14
  rec=$(make_spawn_case access-reader-live-dup claude "$id")
  read_case_record "$rec"
  write_reader_brief "$HOME_DIR" "$id"
  task_tmp=$(reader_task_tmp "$id")
  rm -rf "$task_tmp"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --scout --access reader)
  status=$?
  expect_code 0 "$status" "the initial reader spawn should succeed"
  base_commit=$(git -C "$PROJ_DIR" rev-parse HEAD)
  printf 'advanced after reader launch\n' > "$PROJ_DIR/advanced.txt"
  git -C "$PROJ_DIR" add advanced.txt
  git -C "$PROJ_DIR" -c user.email=t@t -c user.name=t commit -q -m "advance reader source"
  advanced_head=$(git -C "$PROJ_DIR" rev-parse HEAD)
  [ "$advanced_head" != "$base_commit" ] || fail "reader relaunch fixture did not advance the project HEAD"
  touch "$task_tmp/scratch/repo.git/FM-TEST-SENTINEL"

  out=$(FM_FAKE_TMUX_WINDOWS="fm-$id" \
    run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --scout --access reader)
  status=$?
  [ "$status" -ne 0 ] \
    || fail "a duplicate relaunch of a not-provably-dead reader must refuse before touching its read handle"
  assert_contains "$out" "refusing a duplicate launch" \
    "the live-reader duplicate refusal did not name the duplicate"
  [ -f "$task_tmp/scratch/repo.git/FM-TEST-SENTINEL" ] \
    || fail "the refused duplicate relaunch still destructively replaced the live reader's read handle"
  assert_grep "access=reader" "$HOME_DIR/state/$id.meta" \
    "the refused duplicate relaunch damaged the live reader's task record"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --scout --access reader)
  status=$?
  expect_code 0 "$status" "a relaunch against the provably dead endpoint should proceed"
  [ ! -f "$task_tmp/scratch/repo.git/FM-TEST-SENTINEL" ] \
    || fail "the dead-endpoint relaunch did not replace the disposable read handle"
  [ "$(git --git-dir="$task_tmp/scratch/repo.git" rev-parse HEAD)" = "$base_commit" ] \
    || fail "the reader relaunch moved its read handle past the immutable task baseline"
  assert_grep "base_commit=$base_commit" "$HOME_DIR/state/$id.meta" \
    "the reader relaunch overwrote the immutable task baseline"

  touch "$task_tmp/scratch/repo.git/FM-TEST-SENTINEL"
  printf '%s\n' 'backend=zellij' >> "$HOME_DIR/state/$id.meta"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --scout --access reader)
  status=$?
  [ "$status" -ne 0 ] \
    || fail "a reader relaunch with unknown backend liveness must refuse"
  assert_contains "$out" "targeted inspection" \
    "the unknown-liveness refusal did not route the preserved reader to targeted inspection"
  [ -f "$task_tmp/scratch/repo.git/FM-TEST-SENTINEL" ] \
    || fail "the unknown-liveness refusal replaced the reader's existing read handle"
  assert_grep "backend=zellij" "$HOME_DIR/state/$id.meta" \
    "the unknown-liveness refusal rewrote the recorded backend"
  [ ! -s "$LAUNCH_LOG" ] \
    || fail "the unknown-liveness refusal launched a second worker"

  rm -rf "$task_tmp"
  pass "a reader duplicate refuses before handle replacement unless the endpoint is provably dead"
}

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
test_spawn_refuses_unfilled_bookends_before_endpoint_creation
test_spawn_refuses_reader_bookends_before_endpoint_creation
test_missing_axis_refusal_names_the_flags_spawn_accepts
test_cooldown_protects_the_static_crew_harness_path
test_claude_threads_model_and_effort
test_codex_threads_model_and_effort
test_codex_initial_and_resume_share_full_launch_posture
test_codex_omits_invalid_max_effort
test_grok_threads_model_and_reasoning_effort
test_grok_omits_invalid_max_reasoning_effort
test_grok_omits_invalid_xhigh_reasoning_effort
test_opencode_threads_model_and_ignores_effort_axis
test_cursor_agent_threads_model_variant_and_records_effort
test_cursor_reader_launch_uses_noninteractive_brief_delivery
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
test_secondmate_recovery_records_durable_config_provenance
test_telemetry_precedes_submission_and_metadata_is_opaque
test_exploration_requires_an_explicit_rotated_model_and_effort
test_no_mistakes_spawn_requires_one_quota_eligible_reviewer
test_no_mistakes_spawn_carries_nm_home_into_launch_and_meta
test_linked_telemetry_identifiers_chain_one_task_root
test_reader_scout_spawn_skips_pool_and_builds_scratch
test_reader_launch_cannot_write_absolute_project_path
test_reader_spawn_does_not_probe_harness_version_outside_confinement
test_reader_read_handle_holds_no_ref_write_path_to_project
test_reader_same_id_scopes_scratch_by_home_identity
test_reader_access_flag_is_scout_only_and_closed_set
test_reader_brief_access_contract_cross_check
test_reader_symlinked_scratch_refuses_before_creation
test_reader_scratch_predicate_refuses_primary_checkout
test_reader_scratch_predicate_refuses_any_checkout
test_reader_scratch_predicate_refuses_descendant_checkout
test_reader_scratch_predicate_allows_contained_archive_symlink_on_relaunch
test_reader_scratch_predicate_refuses_absolute_descendant_symlink
test_reader_scratch_predicate_refuses_unresolvable_or_escaping_symlinks
test_reader_stale_handle_replaced_with_current_project
test_reader_relaunch_onto_different_project_refuses_loudly
test_access_flip_on_existing_task_refuses
test_duplicate_access_record_refuses_before_reader_relaunch_mutation
test_reader_relaunch_refuses_missing_base_commit_before_mutation
test_reader_relaunch_refuses_duplicate_base_commit_before_mutation
test_reader_live_duplicate_refuses_before_handle_replacement

echo "# all fm-spawn-dispatch-profile tests passed"
