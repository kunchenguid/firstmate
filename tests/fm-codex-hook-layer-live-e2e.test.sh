#!/usr/bin/env bash
# Live guard for the codex crewmate launch's hook posture.
#
# The verdict here comes from the installed codex, not from a stub: a stub can
# only confirm the assumption already written into it, and what this guard
# protects is exactly a vendor-owned surface. Codex blocks a fresh crewmate
# launch on an unanswerable "Hooks need review" modal whenever the machine's
# ~/.codex/hooks.json or a project's .codex/hooks.json carries a hook it has no
# persisted trust for, so the crewmate launch disables codex's hook layer
# outright (bin/fm-spawn.sh's launch template owns the flag).
#
# The guard replays the REAL launch flags fm-spawn builds - captured from a
# spawn driven through a fake pane - against the installed codex and asks codex
# itself whether hooks ended up disabled. If a codex release renames or drops
# the feature, the flag becomes a hard "Unknown feature flag" error and this
# guard fails naming the harness and version instead of letting the modal
# silently come back.
#
# The default checks spend no model tokens (`codex features list` resolves
# configuration only), so they run wherever codex is installed.
# FM_CODEX_FULL_BRIEF_LIVE=1 additionally proves complete large-record model
# consumption and the normal notify callback in a guarded named Herdr lab, then
# relaunches that same worker after changed instructions from a fresh complete
# record that keeps its intent and unfinished work, and forces record
# publication to fail with no native launch or inline fallback.
# That explicit opt-in spends code-assistant tokens on synthetic instructions
# only. FM_CODEX_FULL_BRIEF_MODEL names a model in the installed CLI catalog.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

if [ "${FM_CODEX_FULL_BRIEF_LIVE:-${FM_LIVE:-0}}" = 1 ]; then
  fm_live_gate opt-in FM_CODEX_FULL_BRIEF_LIVE codex herdr jq python3 pgrep pkill
else
  fm_live_gate default-on FM_CODEX_HOOK_LAYER_LIVE codex
fi

CODEX_VERSION=$(codex --version 2>&1)
TMP_ROOT=$(fm_test_tmproot fm-codex-hook-layer-live)

# capture_codex_launch <name> <extra fm-spawn args...>: spawns a codex crewmate
# against a fake pane and echoes the literal launch command firstmate sent.
capture_codex_launch() {
  local name=$1
  shift
  local case_dir home proj wt fakebin launchlog id
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  id="codex-hook-layer-$name"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" codex
  fm_test_spawn_brief "$home" "$id"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  : > "$launchlog"
  FM_FAKE_LAUNCH_LOG="$launchlog" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" "$@" >/dev/null 2>&1 ||
    fail "codex $CODEX_VERSION: fm-spawn could not build a crewmate launch"
  cat "$launchlog"
}

# codex_global_flags <launch command>: the flags between the codex executable
# and the positional brief, which is everything codex itself is configured by.
codex_global_flags() {
  local launch=$1 flags
  flags=${launch#*codex }
  # Parse the public emitted command and omit only its final prompt argument.
  # The positional input may be either an encoded envelope or a record doorbell.
  eval "set -- $flags"
  while [ "$#" -gt 1 ]; do
    printf '%q ' "$1"
    shift
  done
}

test_installed_codex_disables_hooks_for_the_captured_crewmate_launch() {
  local launch flags state
  launch=$(capture_codex_launch ship --mode no-mistakes --yolo off)
  flags=$(codex_global_flags "$launch")

  # The whole point: every flag firstmate will launch with, handed to the real
  # codex, must leave the hook layer off. `features list` reports the effective
  # state after those flags are applied and contacts no model.
  state=$(eval "codex $flags features list" 2>&1) ||
    fail "codex $CODEX_VERSION rejected firstmate's crewmate launch flags: $state"
  case "$state" in
    *"Unknown feature flag"*)
      fail "codex $CODEX_VERSION no longer knows the hook feature firstmate disables: $state"
      ;;
  esac
  printf '%s\n' "$state" | awk '$1 == "hooks" { print $NF }' | grep -qx false ||
    fail "codex $CODEX_VERSION left hooks enabled for firstmate's crewmate launch flags, so a fresh launch can park on the hook-trust modal"

  printf 'ok - codex %s runs a firstmate crewmate launch with its hook layer disabled\n' "$CODEX_VERSION"
}

test_installed_codex_still_reports_the_hook_feature() {
  local listing
  listing=$(codex features list 2>&1) ||
    fail "codex $CODEX_VERSION could not list its feature flags: $listing"
  printf '%s\n' "$listing" | awk '{ print $1 }' | grep -qx hooks ||
    fail "codex $CODEX_VERSION no longer publishes a hook feature flag; firstmate's crewmate launch needs a new control"

  printf 'ok - codex %s still publishes the hook feature flag firstmate disables\n' "$CODEX_VERSION"
}

# native_record <launch log> <state dir>: prints the canonical home-bound record
# named by the final prompt line of the logged stock launch.
native_record() {
  local log=$1 state=$2 launch arg doorbell record
  launch=$(cat "$log")
  eval "set -- ${launch#*codex }"
  for arg do doorbell=$arg; done
  doorbell=${doorbell##*$'\n'}
  fm_operational_doorbell_kind "$doorbell" "$state" arg || return 1
  fm_operational_doorbell_path "$doorbell" record || return 1
  printf '%s\n' "$record"
}

# run_native_turn <helper> <session> <pane> <script> <receipt> <marker> <tail>:
# runs a stock-emitted launch in the lab pane and waits for its receipt and the
# normal turn-end notification; the documented trust default is the only choice.
run_native_turn() {
  local helper=$1 session=$2 pane=$3 script=$4 receipt=$5 marker=$6 tail_json=$7 i tail
  "$helper" run "$session" pane run "$pane" "bash '$script'" >/dev/null || return 1
  for ((i=0; i<${FM_CODEX_FULL_BRIEF_TIMEOUT:-360}; i++)); do
    [ ! -s "$receipt" ] || [ ! -e "$marker" ] || break
    if [ "$i" -eq 5 ]; then
      tail=$("$helper" run "$session" pane read "$pane" --source visible --lines 40)
      if printf '%s' "$tail" | grep -qi 'Do you trust the contents of this directory'; then
        "$helper" run "$session" pane send-keys "$pane" enter >/dev/null || return 1
      fi
    fi
    sleep 1
  done
  "$helper" run "$session" pane read "$pane" --source recent-unwrapped --lines 100 > "$tail_json" || true
  [ -s "$receipt" ] && [ -e "$marker" ]
}

test_full_record_native_model_and_turn_end() (
  fm_live_gate opt-in FM_CODEX_FULL_BRIEF_LIVE codex herdr jq python3 pgrep pkill
  local helper session case_dir home proj wt fakebin launchlog id created pane i record
  local relaunch_record relaunch_code token head_before dirty_before
  local fail_dir fail_home fail_wt fail_log fail_id status
  helper=${HERDR_LAB_HELPER:-"$ROOT/bin/fm-herdr-lab.sh"}
  session=$("$helper" name fm-native-full-brief-delivery) || fail "cannot name isolated lab"
  # Install cleanup before provisioning; only the generated non-default lab
  # may be stopped, and the helper verifies the default-session tripwire.
  trap '"$helper" teardown "$session" || exit 1' EXIT
  "$helper" provision "$session" || fail "cannot provision named native Codex lab"
  case_dir="$TMP_ROOT/full-record"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  id=native-full-record
  launchlog="$case_dir/launch.log"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" codex
  fm_git_worktree "$proj" "$wt" wt-full-record
  mkdir -p "$home/data/$id"
  # Three independently sampled constraints force a real model result to
  # depend on the beginning, middle and end, rather than just hashing a file.
  python3 - "$home/data/$id/brief.md" "$case_dir/expected.json" <<'PY'
import json, secrets, sys
codes = {k: secrets.token_hex(12) for k in ('begin', 'middle', 'end')}
goal = '''Synthetic Firstmate launch transport proof only. Read the entire launch record before acting, using sequential bounded reads with no omitted/truncated bytes. Write only receipt.json in the current directory. Its JSON must contain the three receipt constraint fields distributed through this intent, plus role="crewmate" and inbox equal to the exact steering inbox from the worker role contract. Do not touch notification markers. Do not commit, initialize tools, run validation or contact any external service. After writing the receipt, end the turn with a short acknowledgement.\n'''
parts = [goal + 'Receipt constraint begin=' + codes['begin'] + '\n']
parts += ['Synthetic inert transport padding. No additional action is authorized.\n' * 500]
parts += ['Receipt constraint middle=' + codes['middle'] + '\n']
parts += ['Synthetic inert transport padding. No additional action is authorized.\n' * 500]
parts += ['Receipt constraint end=' + codes['end'] + '\n']
intent = ''.join(parts)
# Preserve a full-size synthetic intent rather than replacing it with a path.
missing = 83828 - len(intent.encode())
assert missing > 0
intent += 'p' * missing
brief = "# Task\n## Captain's intent\n" + intent + '\n\n## Firstmate spec\nSynthetic source-only launch proof.\n' + ('Extra inert specification padding.\n' * 1000)
open(sys.argv[1], 'w').write(brief)
json.dump(codes, open(sys.argv[2], 'w'))
PY
  cp "$home/data/$id/brief.md" "$case_dir/start-brief.md"
  : > "$launchlog"
  FM_FAKE_LAUNCH_LOG="$launchlog" fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" \
    --model "${FM_CODEX_FULL_BRIEF_MODEL:-gpt-6-sol}" --effort high --mode no-mistakes --yolo off --codex-brief-record \
    > "$case_dir/spawn.log" 2>&1 || fail "codex $CODEX_VERSION: cannot emit full-record launch"
  . "$ROOT/bin/fm-operational-input.sh"
  record=$(native_record "$launchlog" "$home/state") || fail "native prompt lost its home-bound canonical record"
  "$ROOT/bin/fm-operational-input.sh" encode launch-brief < "$home/data/$id/launch-brief.md" > "$case_dir/expected-envelope"
  cmp -s "$record" "$case_dir/expected-envelope" || fail "live launch did not retain exact full envelope"
  [ "$(wc -c < "$record")" -gt 189321 ] || fail "live fixture did not exceed the incident's complete launch size"
  printf '# native full-record bytes=%s model=%s effort=high version=%s\n' "$(wc -c < "$record" | tr -d ' ')" "${FM_CODEX_FULL_BRIEF_MODEL:-gpt-6-sol}" "$CODEX_VERSION"
  cp "$launchlog" "$case_dir/native-launch.sh"
  created=$("$helper" run "$session" workspace create --cwd "$wt" --label native-full-record --no-focus) || fail "cannot create synthetic lab pane"
  pane=$(printf '%s' "$created" | jq -r '.result.root_pane.pane_id // empty')
  [ -n "$pane" ] || fail "lab workspace returned no pane"
  run_native_turn "$helper" "$session" "$pane" "$case_dir/native-launch.sh" "$wt/receipt.json" "$home/state/$id.turn-ended" "$case_dir/native-tail.json" || {
    cat "$case_dir/native-tail.json" >&2
    fail "codex $CODEX_VERSION: complete-record receipt and normal turn-end notification not proven"
  }
  python3 - "$case_dir/expected.json" "$wt/receipt.json" "$home/state/$id.inbox" <<'PY' || fail "codex $CODEX_VERSION: full-record constraints/role/inbox changed"
import json, sys
want, got = (json.load(open(p)) for p in sys.argv[1:3])
assert all(got.get(k) == v for k, v in want.items()), (want, got)
assert got.get('role') == 'crewmate' and got.get('inbox') == sys.argv[3], got
PY
  printf 'ok - codex %s consumed beginning/middle/end of the complete synthetic launch record and emitted normal turn-end notification\n' "$CODEX_VERSION"
  if [ -n "${FM_CODEX_FULL_BRIEF_EVIDENCE:-}" ]; then
    mkdir -p "$FM_CODEX_FULL_BRIEF_EVIDENCE"
    cp "$case_dir/expected.json" "$wt/receipt.json" "$case_dir/native-tail.json" "$case_dir/spawn.log" "$case_dir/native-launch.sh" "$FM_CODEX_FULL_BRIEF_EVIDENCE/"
    cp "$record" "$FM_CODEX_FULL_BRIEF_EVIDENCE/launch-envelope.msg"
  fi

  # Same-worker relaunch after changed instructions. Only this case's native
  # process stops (its argv carries the unique record path), so the endpoint
  # reads as a bare shell and the public relaunch verb republishes the record.
  pkill -TERM -f -- "$record" || true
  for ((i=0; i<30; i++)); do
    pgrep -f -- "$record" >/dev/null || break
    [ "$i" -ne 20 ] || pkill -KILL -f -- "$record" || true
    sleep 1
  done
  ! pgrep -f -- "$record" >/dev/null || fail "codex $CODEX_VERSION: start-case native process did not stop"
  mv "$wt/receipt.json" "$case_dir/receipt-start.json"
  rm -f "$home/state/$id.turn-ended"
  token=$(python3 -c 'import secrets; print(secrets.token_hex(12))')
  relaunch_code=$(python3 -c 'import secrets; print(secrets.token_hex(12))')
  printf '%s\n' "$token" > "$wt/unfinished.txt"
  head_before=$(git -C "$wt" rev-parse HEAD)
  dirty_before=$(git -C "$wt" status --porcelain)
  printf 'bash\n' > "$case_dir/pane-command"
  : > "$case_dir/relaunch.log"
  FM_FAKE_PANE_COMMAND_FILE="$case_dir/pane-command" FM_FAKE_PANE_BECOMES=codex FM_FAKE_LAUNCH_LOG="$case_dir/relaunch.log" \
    FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$home/user-home" CLAUDE_CONFIG_DIR='' \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-control.sh" "$id" relaunch --note "Relaunch constraint relaunch=$relaunch_code. Rewrite receipt.json with every field required above plus relaunch equal to that value and unfinished equal to the exact first line of unfinished.txt, which is unfinished work to leave unchanged." \
    > "$case_dir/control.log" 2>&1 || {
    cat "$case_dir/control.log" >&2
    fail "codex $CODEX_VERSION: public relaunch verb refused the same worker"
  }
  relaunch_record=$(native_record "$case_dir/relaunch.log" "$home/state") || fail "relaunch prompt lost its home-bound canonical record"
  [ "$relaunch_record" != "$record" ] || fail "relaunch reused the start record instead of publishing a fresh one"
  "$ROOT/bin/fm-operational-input.sh" encode launch-brief < "$home/data/$id/launch-brief.md" | cmp -s - "$relaunch_record" ||
    fail "relaunch record is not the complete current launch brief"
  [ "$(wc -c < "$relaunch_record")" -gt 189321 ] || fail "relaunch record is not complete-size"
  grep -q "relaunch=$relaunch_code" "$relaunch_record" || fail "relaunch record lost the changed instructions"
  head -c "$(wc -c < "$case_dir/start-brief.md")" "$home/data/$id/brief.md" | cmp -s - "$case_dir/start-brief.md" ||
    fail "relaunch did not retain the original intent"
  [ "$(git -C "$wt" rev-parse HEAD)" = "$head_before" ] && [ "$(git -C "$wt" status --porcelain)" = "$dirty_before" ] ||
    fail "relaunch did not retain the worker's unfinished work"
  grep -qx 'codex_brief_record=1' "$home/state/$id.meta" || fail "relaunch dropped the complete-record opt-in"
  printf '# native relaunch record bytes=%s fresh=%s\n' "$(wc -c < "$relaunch_record" | tr -d ' ')" "$relaunch_record"
  cp "$case_dir/relaunch.log" "$case_dir/native-relaunch.sh"
  run_native_turn "$helper" "$session" "$pane" "$case_dir/native-relaunch.sh" "$wt/receipt.json" "$home/state/$id.turn-ended" "$case_dir/native-relaunch-tail.json" || {
    cat "$case_dir/native-relaunch-tail.json" >&2
    fail "codex $CODEX_VERSION: relaunched complete-record receipt and normal turn-end notification not proven"
  }
  python3 - "$case_dir/expected.json" "$wt/receipt.json" "$home/state/$id.inbox" "$relaunch_code" "$token" <<'PY' || fail "codex $CODEX_VERSION: relaunch lost intent, changed instructions or unfinished work"
import json, sys
want, got = (json.load(open(p)) for p in sys.argv[1:3])
assert all(got.get(k) == v for k, v in want.items()), (want, got)
assert got.get('role') == 'crewmate' and got.get('inbox') == sys.argv[3], got
assert got.get('relaunch') == sys.argv[4] and got.get('unfinished') == sys.argv[5], got
PY
  [ "$(cat "$wt/unfinished.txt")" = "$token" ] || fail "relaunched worker changed its unfinished work"
  pkill -TERM -f -- "$relaunch_record" || true
  printf 'ok - codex %s relaunched the same worker from a fresh complete record that kept its intent, changed instructions and unfinished work\n' "$CODEX_VERSION"
  if [ -n "${FM_CODEX_FULL_BRIEF_EVIDENCE:-}" ]; then
    mkdir -p "$FM_CODEX_FULL_BRIEF_EVIDENCE/relaunch"
    cp "$case_dir/receipt-start.json" "$wt/receipt.json" "$case_dir/native-relaunch-tail.json" "$case_dir/control.log" "$case_dir/native-relaunch.sh" "$FM_CODEX_FULL_BRIEF_EVIDENCE/relaunch/"
    cp "$relaunch_record" "$FM_CODEX_FULL_BRIEF_EVIDENCE/relaunch/launch-envelope.msg"
  fi

  # Forced complete-record publication failure: the operational inbox is a
  # regular file, so the stock spawn must refuse before any native launch and
  # must not fall back to an inline or argv brief.
  fail_dir="$TMP_ROOT/record-refused"
  fail_home="$fail_dir/home"
  fail_wt="$fail_dir/wt"
  fail_log="$fail_dir/launch.log"
  fail_id=native-record-refused
  fm_test_spawn_home "$fail_home" codex
  fm_git_worktree "$fail_dir/project" "$fail_wt" wt-record-refused
  mkdir -p "$fail_home/data/$fail_id"
  cp "$case_dir/start-brief.md" "$fail_home/data/$fail_id/brief.md"
  rm -rf "$fail_home/state/operational-inbox"
  : > "$fail_home/state/operational-inbox"
  : > "$fail_log"
  status=0
  FM_FAKE_LAUNCH_LOG="$fail_log" fm_test_run_spawn "$fail_home" "$fail_wt" "$fakebin" "$fail_id" "$fail_dir/project" \
    --model "${FM_CODEX_FULL_BRIEF_MODEL:-gpt-6-sol}" --effort high --mode no-mistakes --yolo off --codex-brief-record \
    > "$fail_dir/spawn.log" 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail "codex $CODEX_VERSION: unpublishable complete record was still launched"
  grep -q 'could not publish the launch brief' "$fail_dir/spawn.log" || fail "publication refusal missing: $(cat "$fail_dir/spawn.log")"
  [ ! -s "$fail_log" ] || fail "publication failure still sent a native launch: $(cat "$fail_log")"
  [ ! -e "$fail_home/state/$fail_id.meta" ] || fail "publication failure recorded a launched worker"
  printf '# publication-failure spawn exit=%s launch-bytes=%s\n' "$status" "$(wc -c < "$fail_log" | tr -d ' ')"
  printf 'ok - codex %s complete-record publication failure refused with zero native launches and no inline fallback\n' "$CODEX_VERSION"
  if [ -n "${FM_CODEX_FULL_BRIEF_EVIDENCE:-}" ]; then
    mkdir -p "$FM_CODEX_FULL_BRIEF_EVIDENCE/publication-failure"
    cp "$fail_dir/spawn.log" "$fail_log" "$FM_CODEX_FULL_BRIEF_EVIDENCE/publication-failure/"
  fi
)

test_installed_codex_still_reports_the_hook_feature
test_installed_codex_disables_hooks_for_the_captured_crewmate_launch
if [ "${FM_CODEX_FULL_BRIEF_LIVE:-${FM_LIVE:-0}}" = 1 ]; then
  # The subshell scopes the lab trap; its failure must still fail this script.
  test_full_record_native_model_and_turn_end || exit 1
fi

echo "# all fm-codex-hook-layer-live-e2e tests passed"
