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
# consumption and the normal notify callback in a guarded named Herdr lab.
# That explicit opt-in spends code-assistant tokens on synthetic instructions
# only. FM_CODEX_FULL_BRIEF_MODEL names a model in the installed CLI catalog.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

if [ "${FM_CODEX_FULL_BRIEF_LIVE:-${FM_LIVE:-0}}" = 1 ]; then
  fm_live_gate opt-in FM_CODEX_FULL_BRIEF_LIVE codex herdr jq python3
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

test_full_record_native_model_and_turn_end() (
  fm_live_gate opt-in FM_CODEX_FULL_BRIEF_LIVE codex herdr jq python3
  local helper session case_dir home proj wt fakebin launchlog id launch created pane i tail arg doorbell record
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
  : > "$launchlog"
  FM_FAKE_LAUNCH_LOG="$launchlog" fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" \
    --model "${FM_CODEX_FULL_BRIEF_MODEL:-gpt-6-sol}" --effort high --mode no-mistakes --yolo off \
    > "$case_dir/spawn.log" 2>&1 || fail "codex $CODEX_VERSION: cannot emit full-record launch"
  launch=$(cat "$launchlog")
  eval "set -- ${launch#*codex }"
  for arg do doorbell=$arg; done
  . "$ROOT/bin/fm-operational-input.sh"
  fm_operational_doorbell_kind "$doorbell" "$home/state" arg || fail "native prompt lost home-bound record"
  fm_operational_doorbell_path "$doorbell" record || fail "native prompt names no canonical record"
  "$ROOT/bin/fm-operational-input.sh" encode launch-brief < "$home/data/$id/launch-brief.md" > "$case_dir/expected-envelope"
  cmp -s "$record" "$case_dir/expected-envelope" || fail "live launch did not retain exact full envelope"
  [ "$(wc -c < "$record")" -gt 189321 ] || fail "live fixture did not exceed the incident's complete launch size"
  printf '# native full-record bytes=%s model=%s effort=high version=%s\n' "$(wc -c < "$record" | tr -d ' ')" "${FM_CODEX_FULL_BRIEF_MODEL:-gpt-6-sol}" "$CODEX_VERSION"
  printf '%s\n' "$launch" > "$case_dir/native-launch.sh"
  created=$("$helper" run "$session" workspace create --cwd "$wt" --label native-full-record --no-focus) || fail "cannot create synthetic lab pane"
  pane=$(printf '%s' "$created" | jq -r '.result.root_pane.pane_id // empty')
  [ -n "$pane" ] || fail "lab workspace returned no pane"
  "$helper" run "$session" pane run "$pane" "bash '$case_dir/native-launch.sh'" >/dev/null || fail "cannot execute stock-emitted native launch"
  for ((i=0; i<${FM_CODEX_FULL_BRIEF_TIMEOUT:-360}; i++)); do
    [ ! -s "$wt/receipt.json" ] || [ ! -e "$home/state/$id.turn-ended" ] || break
    if [ "$i" -eq 5 ]; then
      tail=$("$helper" run "$session" pane read "$pane" --source visible --lines 40)
      # The documented affirmative default is the only trust choice used.
      if printf '%s' "$tail" | grep -qi 'Do you trust the contents of this directory'; then
        "$helper" run "$session" pane send-keys "$pane" enter >/dev/null || fail "cannot confirm synthetic directory trust"
      fi
    fi
    sleep 1
  done
  "$helper" run "$session" pane read "$pane" --source recent-unwrapped --lines 100 > "$case_dir/native-tail.json" || true
  [ -s "$wt/receipt.json" ] && [ -e "$home/state/$id.turn-ended" ] || {
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
)

test_installed_codex_still_reports_the_hook_feature
test_installed_codex_disables_hooks_for_the_captured_crewmate_launch
if [ "${FM_CODEX_FULL_BRIEF_LIVE:-${FM_LIVE:-0}}" = 1 ]; then
  test_full_record_native_model_and_turn_end
fi

echo "# all fm-codex-hook-layer-live-e2e tests passed"
