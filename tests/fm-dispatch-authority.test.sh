#!/usr/bin/env bash
# Behavior tests for the captain's dispatch-authority restrictions, now enforced
# in the spawn path instead of relying on the agent remembering them:
#   - the Claude crewmate concurrency cap, counting only LIVE ordinary crewmates
#   - the Opus gate, where profile/rule routing is not captain authorization
#
# Endpoint liveness runs through the REAL fm_backend_target_exists tmux path; a
# selective fake `tmux` on PATH decides which targets exist, so no firstmate
# function is stubbed and live and dead endpoints can coexist in one fixture.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-dispatch-authority)

# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
# shellcheck source=bin/fm-dispatch-authority-lib.sh
. "$ROOT/bin/fm-dispatch-authority-lib.sh"

FAKEBIN=$(fm_fakebin "$TMP_ROOT")
cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = display-message ]; then
  target=
  prev=
  for a in "$@"; do
    if [ "$prev" = "-t" ]; then target=$a; fi
    prev=$a
  done
  case " ${FM_LIVE_TARGETS:-} " in
    *" $target "*) echo "%0"; exit 0 ;;
  esac
  exit 1
fi
exit 0
SH
chmod +x "$FAKEBIN/tmux"
PATH="$FAKEBIN:$PATH"
export PATH
FM_LIVE_TARGETS=
export FM_LIVE_TARGETS

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/config" "$home/data"
  printf '%s\n' "$home"
}

meta() {  # <home> <id> <kind> <harness> <target>
  local home=$1 id=$2 kind=$3 harness=$4 target=$5
  cat > "$home/state/$id.meta" <<EOF
kind=$kind
harness=$harness
backend=tmux
window=$target
EOF
}

live() {  # <home> <id> <kind> <harness> <target>
  meta "$@"
  FM_LIVE_TARGETS="$FM_LIVE_TARGETS $5"
  export FM_LIVE_TARGETS
}

spawn_in() {  # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_CONFIG_OVERRIDE="$home/config" FM_DATA_OVERRIDE="$home/data" \
    "$SPAWN" "$@" 2>&1
}

test_cap_counts_only_live_ordinary_claude_crew() {
  local home count
  home=$(make_home counting)

  [ "$(fm_dispatch_active_claude_count "$home/state")" -eq 0 ] \
    || fail "an empty state must count 0 active crew"

  live "$home" one ship claude fm:1.1
  [ "$(fm_dispatch_active_claude_count "$home/state")" -eq 1 ] \
    || fail "one live claude ship should count 1"

  live "$home" two scout claude fm:1.2
  [ "$(fm_dispatch_active_claude_count "$home/state")" -eq 2 ] \
    || fail "a live claude scout must also consume a slot"

  # None of the following may consume a slot.
  meta "$home" stale ship claude fm:dead          # endpoint not in live set
  live "$home" mate secondmate claude fm:1.3      # persistent home, not a crewmate
  live "$home" codexworker ship codex fm:1.4      # cap is Claude-specific
  printf 'kind=ship\nharness=claude\nbackend=tmux\n' > "$home/state/nowindow.meta"

  count=$(fm_dispatch_active_claude_count "$home/state")
  [ "$count" -eq 2 ] \
    || fail "dead, secondmate, non-claude, and window-less records must not consume capacity, got $count"
  pass "the cap counts only live, ordinary, Claude-backed crewmates"
}

test_opus_predicate_matches_naming_generations() {
  local m
  for m in opus Opus claude-opus-5 claude-3-opus-20240229 OPUS-4.8; do
    fm_dispatch_model_is_opus "$m" || fail "'$m' should be recognized as Opus"
  done
  for m in "" default sonnet claude-sonnet-5 haiku gpt-5.6-sol; do
    ! fm_dispatch_model_is_opus "$m" || fail "'$m' must NOT be treated as Opus"
  done
  pass "the Opus predicate spans naming generations without catching other models"
}

test_cap_override_is_validated() {
  local home status=0
  home=$(make_home cap-config)

  [ "$(fm_dispatch_concurrency_cap_read "$home/config")" = 2 ] \
    || fail "an absent override must yield the tracked default of 2"

  printf '4\n' > "$home/config/crew-concurrency-cap"
  [ "$(fm_dispatch_concurrency_cap_read "$home/config")" = 4 ] \
    || fail "a valid override must be honored"

  printf 'lots\n' > "$home/config/crew-concurrency-cap"
  fm_dispatch_concurrency_cap_read "$home/config" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "a malformed cap must refuse rather than silently widen the restriction"
  assert_contains "$(fm_dispatch_authority_error)" "decimal integer" \
    "the malformed-cap error did not explain itself"
  pass "the cap override is honored and a malformed one refuses instead of defaulting"
}

test_spawn_refuses_opus_without_authorization() {
  local home out status=0
  home=$(make_home opus-refusal)
  out=$(spawn_in "$home" --harness claude --model claude-opus-5 authz-opus) || status=$?
  [ "$status" -ne 0 ] || fail "an Opus spawn without authorization must not succeed"
  assert_contains "$out" "requires explicit captain authorization" \
    "the Opus refusal did not name the authorization requirement"
  assert_contains "$out" "is NOT authorization" \
    "the refusal must state that profile routing is not captain authorization"
  assert_contains "$out" "--captain-authorized" \
    "the refusal must name the flag that carries the captain's approval"
  pass "spawn refuses an Opus crewmate that carries no captain authorization"
}

test_spawn_does_not_gate_non_opus_models() {
  local home out
  home=$(make_home sonnet-ok)
  out=$(spawn_in "$home" --harness claude --model claude-sonnet-5 authz-sonnet || true)
  assert_not_contains "$out" "Opus model" \
    "a non-Opus model must never trip the Opus gate"
  pass "non-Opus models are not gated"
}

test_spawn_refuses_past_the_cap_and_names_the_live_crew() {
  local home out status=0
  home=$(make_home cap-refusal)
  live "$home" busy-one ship claude fm:2.1
  live "$home" busy-two ship claude fm:2.2

  out=$(spawn_in "$home" --harness claude capped-task) || status=$?
  [ "$status" -ne 0 ] || fail "a spawn at the cap must not succeed"
  assert_contains "$out" "at the captain's cap of 2" "the refusal did not state the cap"
  assert_contains "$out" "busy-one" "the refusal did not name the live crew holding the slots"
  assert_contains "$out" "--captain-authorized" "the refusal did not name the override"
  assert_contains "$out" "hold" "the refusal did not offer the queue-it alternative"
  pass "spawn refuses past the cap and names both the blockers and the way forward"
}

test_below_the_cap_still_dispatches() {
  local home out
  home=$(make_home under-cap)
  live "$home" busy-one ship claude fm:3.1

  # One live crewmate is under the cap of 2, so the authority gate must not be
  # what stops this spawn. It still fails later for unrelated reasons.
  out=$(spawn_in "$home" --harness claude second-task || true)
  assert_not_contains "$out" "at the captain's cap" \
    "a spawn below the cap must not be refused by the concurrency gate"
  pass "a spawn below the cap passes the concurrency gate"
}

test_dead_crew_does_not_hold_a_slot_at_spawn_time() {
  local home out
  home=$(make_home dead-slots)
  meta "$home" gone-one ship claude fm:dead1
  meta "$home" gone-two ship claude fm:dead2

  out=$(spawn_in "$home" --harness claude fresh-task || true)
  assert_not_contains "$out" "at the captain's cap" \
    "finished-but-not-torn-down crewmates must not ratchet the cap shut"
  pass "dead crewmates never consume capacity at spawn time"
}

test_captain_authorization_lifts_both_gates() {
  local home out
  home=$(make_home authorized)
  live "$home" busy-one ship claude fm:4.1
  live "$home" busy-two ship claude fm:4.2

  out=$(spawn_in "$home" --harness claude --captain-authorized capped-task || true)
  assert_not_contains "$out" "at the captain's cap" \
    "captain authorization must lift the concurrency cap"

  out=$(spawn_in "$home" --harness claude --model claude-opus-5 --captain-authorized authz-opus || true)
  assert_not_contains "$out" "requires explicit captain authorization" \
    "captain authorization must lift the Opus gate"
  pass "explicit captain authorization lifts both gates"
}

test_zero_cap_disables_the_check() {
  local home out
  home=$(make_home zero-cap)
  printf '0\n' > "$home/config/crew-concurrency-cap"
  live "$home" busy-one ship claude fm:5.1
  live "$home" busy-two ship claude fm:5.2

  out=$(spawn_in "$home" --harness claude uncapped || true)
  assert_not_contains "$out" "at the captain's cap" \
    "a cap of 0 must mean unlimited, not refuse-everything"
  pass "a cap of 0 disables the concurrency check"
}

test_cap_counts_only_live_ordinary_claude_crew
test_opus_predicate_matches_naming_generations
test_cap_override_is_validated
test_spawn_refuses_opus_without_authorization
test_spawn_does_not_gate_non_opus_models
test_spawn_refuses_past_the_cap_and_names_the_live_crew
test_below_the_cap_still_dispatches
test_dead_crew_does_not_hold_a_slot_at_spawn_time
test_captain_authorization_lifts_both_gates
test_zero_cap_disables_the_check
