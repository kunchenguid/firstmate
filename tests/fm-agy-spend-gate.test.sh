#!/usr/bin/env bash
# tests/fm-agy-spend-gate.test.sh - the regression for the agy point-of-spend gate.
#
# The per-poll descent detects a crossed floor within about a minute but can
# only act on a provably idle worker, so a worker inside one long turn spends
# the captain's reserved quarter with nothing in its path. The PostInvocation
# verdict below runs synchronously in the worker's own loop and ends the turn
# the moment the floor is proven crossed. Each case pins one direction of the
# gate, because a gate that cannot act is worse than no gate and one that
# breaks correct output is the same defect from the other side:
#
#   1. A healthy rung passes through untouched (the {} direction).
#   2. An exhausted own rung terminates (the terminate direction).
#   3. The boundary itself: Opus at exactly 25% terminates, at 25.1% passes.
#   4. A floor-0 rung terminates only at true zero, never above it.
#   5. Override and pre-gate entries always pass, even when exhausted.
#   6. Unknown or stale evidence passes when polling is off (no-stall).
#   7. Stale evidence plus a live poll decides on the fresh reading, both ways.
#   8. The entry script never prints an empty line and never exits non-zero.
#   9. A real spawn wires the registry lines, the PostInvocation hook, and the
#      plugin enablement, and the generated hook behaves (passthrough healthy,
#      terminate exhausted) when driven with a synthetic payload.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Force the built-in ladder order so a direct run under an ambient FM_HOME
# with its own crew-dispatch.json cannot reorder the rungs underneath the
# cases. Under bin/fm-test-run.sh FM_HOME is unset and the defaults apply
# anyway; this only pins the same answer for a bare `bash` invocation.
export FM_AGY_LADDER_CONFIG=/dev/null/fm-agy-spend-gate-no-config
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$ROOT/bin/fm-wake-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=bin/fm-agy-quota-lib.sh
. "$ROOT/bin/fm-agy-quota-lib.sh"
# shellcheck source=bin/fm-agy-descent-lib.sh
. "$ROOT/bin/fm-agy-descent-lib.sh"
# shellcheck source=bin/fm-agy-lib.sh
. "$ROOT/bin/fm-agy-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-agy-spend-gate)

# The in-flight ledger is scoped to the agy ACCOUNT and stored machine-wide, so
# this suite is pointed at a scratch root rather than the operator's own.
export FM_AGY_SHARED_ROOT="$TMP_ROOT/agy-shared"
export FM_AGY_QUOTA_MAX_AGE=300
export FM_AGY_INFLIGHT_TTL=300
export FM_AGY_LADDER_INFLIGHT_MARGIN=1
# Readings are written by hand, so the live intake poll stays off unless a
# case turns it back on against a fake agy: a real poll would replace them
# with the host account's own and every expectation would turn on whatever agy
# says today.
export FM_AGY_QUOTA_POLL=off

RUNG1='Gemini 3.1 Pro (High)'
RUNG2='Claude Opus 4.6 (Thinking)'
RUNG3='Gemini 3.7 Flash (High)'

NOW=$(date +%s)

record_at() {  # <state-dir> <display-model> <percent> <reset-window> <now>
  mkdir -p "$1"
  fm_agy_quota_observe "$2 | ctx: 3.0% | quota: $3% ($4)" "$1" "$5"
}

fresh_state() {
  local dir="$TMP_ROOT/state-$1"
  rm -rf "$dir"
  mkdir -p "$dir"
  printf '%s\n' "$dir"
}

meta() {  # <state-dir> <id> <model>
  {
    printf 'harness=agy\n'
    printf 'backend=tmux\n'
    printf 'window=fmlab:%s\n' "$2"
    printf 'kind=ship\n'
    printf 'model=%s\n' "$3"
  } > "$1/$2.meta"
}

# --- the {} direction: healthy output passes untouched -----------------------

S=$(fresh_state healthy)
meta "$S" w1 "$RUNG2"
record_at "$S" "$RUNG2" 28.7 "4h 0m" "$NOW"
OUT=$(fm_agy_spend_gate_verdict "$S" w1 on "$NOW") || fail "a healthy rung must exit 0"
[ "$OUT" = '{}' ] || fail "a healthy rung must pass through, got: $OUT"
pass "a worker above its floor passes through untouched"

# --- the terminate direction: exhausted own rung ends the turn ---------------

S=$(fresh_state exhausted)
meta "$S" w1 "$RUNG2"
record_at "$S" "$RUNG2" 22.3 "4h 0m" "$NOW"
OUT=$(fm_agy_spend_gate_verdict "$S" w1 on "$NOW") || fail "an exhausted rung must exit 0"
case "$OUT" in
  '{"terminationBehavior":"terminate"'*) : ;;
  *) fail "an exhausted rung must terminate, got: $OUT" ;;
esac
case "$OUT" in
  *"$RUNG2"*25*) : ;;
  *) fail "the terminate verdict must name the rung and its floor, got: $OUT" ;;
esac
pass "a worker at 22.3% on Opus 4.6 terminates its turn"

# --- the boundary itself, both sides ------------------------------------------

S=$(fresh_state boundary)
meta "$S" w1 "$RUNG2"
record_at "$S" "$RUNG2" 25.0 "4h 0m" "$NOW"
OUT=$(fm_agy_spend_gate_verdict "$S" w1 on "$NOW")
case "$OUT" in
  '{"terminationBehavior":"terminate"'*) : ;;
  *) fail "Opus at exactly 25% is at its floor and must terminate, got: $OUT" ;;
esac
record_at "$S" "$RUNG2" 25.1 "4h 0m" "$NOW"
OUT=$(fm_agy_spend_gate_verdict "$S" w1 on "$NOW")
[ "$OUT" = '{}' ] || fail "Opus at 25.1% is above its floor and must pass, got: $OUT"
pass "the 25% floor boundary terminates at-or-below and passes above"

# --- floor-0 rungs terminate only at true zero --------------------------------

S=$(fresh_state floorzero)
meta "$S" w1 "$RUNG3"
record_at "$S" "$RUNG3" 5.0 "4h 0m" "$NOW"
OUT=$(fm_agy_spend_gate_verdict "$S" w1 on "$NOW")
[ "$OUT" = '{}' ] || fail "a floor-0 rung at 5% must pass, got: $OUT"
record_at "$S" "$RUNG3" 0.0 "4h 0m" "$NOW"
OUT=$(fm_agy_spend_gate_verdict "$S" w1 on "$NOW")
case "$OUT" in
  '{"terminationBehavior":"terminate"'*) : ;;
  *) fail "a floor-0 rung at 0% must terminate, got: $OUT" ;;
esac
pass "a floor-0 rung terminates only at true zero"

# --- override and pre-gate entries always pass ---------------------------------

S=$(fresh_state override)
meta "$S" w1 "$RUNG2"
record_at "$S" "$RUNG2" 10.0 "4h 0m" "$NOW"
OUT=$(fm_agy_spend_gate_verdict "$S" w1 off "$NOW")
[ "$OUT" = '{}' ] || fail "an override-pinned worker must pass even exhausted, got: $OUT"
OUT=$(fm_agy_spend_gate_verdict "$S" w1 "" "$NOW")
[ "$OUT" = '{}' ] || fail "a pre-gate registry entry must pass even exhausted, got: $OUT"
pass "override and pre-gate entries pass even below the floor"

# --- unknown and stale evidence fail open when polling is off -----------------

S=$(fresh_state unknown)
meta "$S" w1 "$RUNG2"
OUT=$(fm_agy_spend_gate_verdict "$S" w1 on "$NOW")
[ "$OUT" = '{}' ] || fail "an unknown reading must fail open, got: $OUT"
record_at "$S" "$RUNG2" 10.0 "4h 0m" "$((NOW - 900))"
OUT=$(fm_agy_spend_gate_verdict "$S" w1 on "$NOW")
[ "$OUT" = '{}' ] || fail "a stale reading must fail open when polling is off, got: $OUT"
pass "unknown and stale evidence fail open with the poll off"

# --- off-ladder models and missing records pass --------------------------------

S=$(fresh_state offmodel)
meta "$S" w1 "Claude Sonnet 4.6"
record_at "$S" "Claude Sonnet 4.6" 1.0 "4h 0m" "$NOW"
OUT=$(fm_agy_spend_gate_verdict "$S" w1 on "$NOW")
[ "$OUT" = '{}' ] || fail "an off-ladder model must pass, got: $OUT"
OUT=$(fm_agy_spend_gate_verdict "$S" nosuchid on "$NOW")
[ "$OUT" = '{}' ] || fail "a missing record must pass, got: $OUT"
pass "off-ladder models and missing records pass"

# --- stale evidence plus a live poll decides on the fresh reading --------------

agy_poll_fakebin() {  # <dir> <fraction>: an agy answering only /quota.
  local fakebin fraction=$2 reset
  fakebin=$(fm_fakebin "$1")
  reset='2030-01-01T00:00:00Z'
  cat > "$fakebin/agy" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = --print ]; then
  printf '{"command":{"data":{"groups":[{"buckets":[{"name":"%s","remaining_fraction":%s,"reset_time":"%s"},{"name":"%s","remaining_fraction":0.99,"reset_time":"%s"}]}]}}}\n' "$RUNG2" "$fraction" "$reset" "$RUNG3" "$reset"
fi
exit 0
SH
  chmod +x "$fakebin/agy"
  printf '%s\n' "$fakebin"
}

if command -v jq >/dev/null 2>&1; then
  S=$(fresh_state pollshut)
  meta "$S" w1 "$RUNG2"
  record_at "$S" "$RUNG2" 10.0 "4h 0m" "$((NOW - 900))"
  FAKE=$(agy_poll_fakebin "$TMP_ROOT/pollshut" 0.223)
  OUT=$(env PATH="$FAKE:$PATH" FM_AGY_QUOTA_POLL=on \
    "$ROOT/bin/fm-agy-spend-gate.sh" "$S" w1 on "$NOW") || fail "a deciding poll must exit 0"
  case "$OUT" in
    '{"terminationBehavior":"terminate"'*) : ;;
    *) fail "a stale reading refreshed to 22.3% must terminate, got: $OUT" ;;
  esac
  pass "a stale reading refreshed below the floor terminates"

  S=$(fresh_state pollopen)
  meta "$S" w1 "$RUNG2"
  record_at "$S" "$RUNG2" 10.0 "4h 0m" "$((NOW - 900))"
  FAKE=$(agy_poll_fakebin "$TMP_ROOT/pollopen" 0.60)
  OUT=$(env PATH="$FAKE:$PATH" FM_AGY_QUOTA_POLL=on \
    "$ROOT/bin/fm-agy-spend-gate.sh" "$S" w1 on "$NOW") || fail "a deciding poll must exit 0"
  [ "$OUT" = '{}' ] || fail "a stale reading refreshed to 60% must pass, got: $OUT"
  pass "a stale reading refreshed above the floor passes"
else
  pass "skip: jq is absent so the live-poll fallback cannot be exercised"
fi

# --- the entry script never answers empty and never fails ----------------------

OUT=$("$ROOT/bin/fm-agy-spend-gate.sh") || fail "the entry script must exit 0 with no arguments"
[ -n "$OUT" ] || fail "the entry script must print a verdict with no arguments"
[ "$OUT" = '{}' ] || fail "the entry script must allow with no arguments, got: $OUT"
S=$(fresh_state entryexhausted)
meta "$S" w1 "$RUNG2"
record_at "$S" "$RUNG2" 22.3 "4h 0m" "$NOW"
OUT=$(FM_AGY_QUOTA_POLL=off "$ROOT/bin/fm-agy-spend-gate.sh" "$S" w1 on "$NOW") \
  || fail "the entry script must exit 0 on an exhausted rung"
case "$OUT" in
  '{"terminationBehavior":"terminate"'*) : ;;
  *) fail "the entry script must terminate an exhausted rung, got: $OUT" ;;
esac
pass "the entry script always answers exactly one verdict line with exit 0"

# --- a real spawn wires the registry, the hook, and the enablement ------------
#
# This drives bin/fm-spawn.sh itself (with a fake agy and fake tmux, into a
# scratch agy customization root, so the operator's own configuration is never
# touched) and then drives the GENERATED hook with a synthetic PostInvocation
# payload. What is asserted is behavior - the verdict the hook prints - not
# the bytes it was generated from. Never run on Opus: rung 1 needs no
# exhaustion proof above it, so the launch gate lets it through on a healthy
# reading and nothing here spends the reserve.

agy_spawn_fakebin() {  # <dir>: fake agy answering only the catalogue.
  local fakebin
  fakebin=$(fm_fakebin "$1")
  cat > "$fakebin/agy" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = models ]; then
  printf 'claude-opus-4-6-thinking\tClaude Opus 4.6 (Thinking)\n'
  printf 'gemini-3.1-pro-high\tGemini 3.1 Pro (High)\n'
  printf 'gemini-3.7-flash-high\tGemini 3.7 Flash (High)\n'
fi
exit 0
SH
  chmod +x "$fakebin/agy"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window|send-keys) exit 0 ;;
  # The readiness gate (agy_wait_for_working) needs a busy screen to confirm
  # the brief is running. The covered path below means no dialog renders, so
  # a steady busy row is the whole story - and it must carry no dialog text,
  # or the gate would wait for an answer instead.
  capture-pane) printf 'esc to cancel                                Gemini 3.1 Pro (High)\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  # Upstream's no-op treehouse stub (tests/lib.sh): the spawn under test uses
  # a real linked worktree, never a pool lease, so no `treehouse get` path is
  # consulted. The fork's fm_fake_treehouse differs only in answering `get`.
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

spawn_case() {  # <dir> <id> [override]: a real agy spawn into a scratch home.
  local dir=$1 id=$2 override=${3:-} home proj wt fakebin
  home="$dir/home"
  proj="$dir/proj"
  wt="$dir/wt"
  mkdir -p "$home/data/$id" "$home/state" "$home/config" "$home/projects" "$dir/agy-config"
  fakebin=$(agy_spawn_fakebin "$dir/fake")
  fm_git_worktree "$proj" "$wt" "wt-$id"
  # The spawn refuses an unfilled scaffold (upstream's brief placeholder
  # guard), so the brief carries both subsections; the fork's legacy one-line
  # body does not pass on this tree.
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
brief for $id

## Firstmate spec
Exercise the spawn behavior under test.
EOF
  fm_agy_quota_observe "$RUNG1 | ctx: 3.0% | quota: 88.0% (4h 0m)" "$home/state"
  # The readiness gate counts a busy turn at once only on a covered path, and
  # coverage is read from the launching user's own store - so the spawn runs
  # under a scratch HOME whose store already trusts the worktree. That keeps
  # the suite hermetic (the developer's real store is never read) and
  # deterministic (no dependence on what the machine happens to trust).
  mkdir -p "$dir/scratch-home/.gemini/antigravity-cli"
  wt_abs=$(cd -P -- "$wt" && pwd -P)
  printf '{"trustedWorkspaces":["%s"]}\n' "$wt_abs" > "$dir/scratch-home/.gemini/antigravity-cli/settings.json"
  if [ -n "$override" ]; then
    FM_AGY_LADDER_OVERRIDE="$override" \
    env PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$dir/scratch-home" \
      FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
      FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
      FM_AGY_CONFIG_HOME="$dir/agy-config" FM_AGY_SETTINGS="$dir/agy-settings.json" \
      FM_AGY_QUOTA_POLL=off FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
      "$ROOT/bin/fm-spawn.sh" "$id" "$proj" \
      --harness agy --model "$RUNG1" --mode no-mistakes --yolo off >/dev/null 2>&1
  else
    env PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$dir/scratch-home" \
      FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
      FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
      FM_AGY_CONFIG_HOME="$dir/agy-config" FM_AGY_SETTINGS="$dir/agy-settings.json" \
      FM_AGY_QUOTA_POLL=off FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
      "$ROOT/bin/fm-spawn.sh" "$id" "$proj" \
      --harness agy --model "$RUNG1" --mode no-mistakes --yolo off >/dev/null 2>&1
  fi
  printf '%s\n' "$dir"
}

hook_payload() {  # <worktree>: a synthetic PostInvocation stdin payload.
  printf '{"workspacePaths":["%s"],"conversationId":"test-conv","invocationNum":2,"initialNumSteps":9}\n' "$1"
}

D="$TMP_ROOT/spawnwired"
spawn_case "$D" w1 >/dev/null || fail "the wiring spawn must succeed"

ENTRY_TOKEN=$(sed -n 's/^token=//p' "$D/wt/.fm-agy-turnend" 2>/dev/null || true)
[ -n "$ENTRY_TOKEN" ] || fail "the spawn must leave a worktree pointer to its registry entry"
ENTRY="$D/agy-config/plugins/fm-turn-end/fm-turn-end.d/$ENTRY_TOKEN"
[ -f "$ENTRY" ] || fail "the registry entry must exist"
grep -q '^spend_gate=on$' "$ENTRY" || fail "the registry entry must carry spend_gate=on"
grep -q '^gate=.*/fm-agy-spend-gate\.sh$' "$ENTRY" || fail "the registry entry must name the gate"

HOOK="$D/agy-config/plugins/fm-turn-end/fm-turn-end.sh"
[ -x "$HOOK" ] || fail "the generated hook must exist and be executable"
if command -v jq >/dev/null 2>&1; then
  jq -e '.["fm-turn-end"].PostInvocation | length == 1' \
    "$D/agy-config/plugins/fm-turn-end/hooks.json" >/dev/null 2>&1 \
    || fail "the generated hooks.json must register exactly one PostInvocation handler"
  jq -e '.plugins["fm-turn-end"].enabled == true' \
    "$D/agy-config/config.json" >/dev/null 2>&1 \
    || fail "the spawn must record the plugin enabled in the agy config"
else
  fail "jq is required to check the generated hooks.json and config.json"
fi

OUT=$(hook_payload "$D/wt" | bash "$HOOK" PostInvocation 2>/dev/null) \
  || fail "the generated hook must exit 0 on a healthy rung"
[ "$OUT" = '{}' ] || fail "the generated hook must pass a healthy rung, got: $OUT"

fm_agy_quota_observe "$RUNG1 | ctx: 3.0% | quota: 0.0% (4h 0m)" "$D/home/state"
OUT=$(FM_AGY_QUOTA_POLL=off hook_payload "$D/wt" | bash "$HOOK" PostInvocation 2>/dev/null) \
  || fail "the generated hook must exit 0 on an exhausted rung"
case "$OUT" in
  '{"terminationBehavior":"terminate"'*) : ;;
  *) fail "the generated hook must terminate an exhausted rung, got: $OUT" ;;
esac
pass "a real spawn wires the gate and the generated hook enforces it"

D2="$TMP_ROOT/spawnoverride"
spawn_case "$D2" w2 captain-request >/dev/null || fail "the override spawn must succeed"
ENTRY_TOKEN=$(sed -n 's/^token=//p' "$D2/wt/.fm-agy-turnend" 2>/dev/null || true)
ENTRY="$D2/agy-config/plugins/fm-turn-end/fm-turn-end.d/$ENTRY_TOKEN"
grep -q '^spend_gate=off$' "$ENTRY" || fail "an override spawn must carry spend_gate=off"
HOOK="$D2/agy-config/plugins/fm-turn-end/fm-turn-end.sh"
fm_agy_quota_observe "$RUNG1 | ctx: 3.0% | quota: 0.0% (4h 0m)" "$D2/home/state"
OUT=$(FM_AGY_QUOTA_POLL=off hook_payload "$D2/wt" | bash "$HOOK" PostInvocation 2>/dev/null) \
  || fail "the override hook must exit 0"
[ "$OUT" = '{}' ] || fail "an override-pinned worker must pass even exhausted, got: $OUT"
pass "an override spawn pins the worker past the gate"

# --- the enablement merge preserves the operator's own config ------------------

E="$TMP_ROOT/enablemerge"
mkdir -p "$E/config"
printf '{"userSettings":{"verboseAgentChat":true},"plugins":{"other":{"enabled":false}}}\n' > "$E/config/config.json"
FM_AGY_CONFIG_HOME="$E/config" fm_agy_ensure_plugin_enabled
if command -v jq >/dev/null 2>&1; then
  jq -e '.plugins["fm-turn-end"].enabled == true and .plugins.other.enabled == false and .userSettings.verboseAgentChat == true' \
    "$E/config/config.json" >/dev/null 2>&1 \
    || fail "the enablement must record fm-turn-end and preserve existing keys"
else
  MERGED=$(cat "$E/config/config.json" 2>/dev/null || true)
  case "$MERGED" in
    *fm-turn-end*) : ;;
    *) fail "the enablement must record fm-turn-end, got: $MERGED" ;;
  esac
fi
printf 'not json\n' > "$E/config/config.json"
FM_AGY_CONFIG_HOME="$E/config" fm_agy_ensure_plugin_enabled
[ "$(cat "$E/config/config.json")" = 'not json' ] \
  || fail "a malformed config must be left untouched"
rm -f "$E/config/config.json"
FM_AGY_CONFIG_HOME="$E/config" fm_agy_ensure_plugin_enabled
if command -v jq >/dev/null 2>&1; then
  jq -e '.plugins["fm-turn-end"].enabled == true' \
    "$E/config/config.json" >/dev/null 2>&1 \
    || fail "an absent config must gain the enablement entry"
fi
pass "the plugin enablement merges without touching anything else"
