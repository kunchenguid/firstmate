#!/usr/bin/env bash
# Load-profile bind plans, parser rejections, and the Pi-extension graft.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-load-profile-lib.sh
. "$ROOT/bin/fm-load-profile-lib.sh"

unset FM_LOAD_PROFILES_TSV
unset FM_SESSION_START_TIMEOUT FM_SESSION_START_STATUS_TAIL
unset FM_SESSION_START_QUEUED_LIMIT FM_SESSION_START_ENDPOINT_TIMEOUT

TMP_ROOT=$(fm_test_tmproot fm-load-profile)
SCOPE_BEFORE=$(cksum "$ROOT/AGENTS.md")

SLIM_STAGES='lock
role
bootstrap
wake-queue
supervision-instructions
read-once
fleet-state
network-checks
context
next-step'

SLIM_PLAN='lock|run=yes emit=body timeout=30
role|run=yes emit=body timeout=30
bootstrap|run=no emit=pointer timeout=30
wake-queue|run=yes emit=body timeout=30
supervision-instructions|run=yes emit=body timeout=30
read-once|run=yes emit=body timeout=30
fleet-state|run=yes emit=body depth=identity timeout=30
network-checks|run=no emit=pointer timeout=30
context|run=yes emit=slots timeout=30
next-step|run=yes emit=body timeout=30'

FULL_PLAN='lock|run=yes emit=body timeout=120
role|run=yes emit=body timeout=120
bootstrap|run=yes emit=body timeout=120
wake-queue|run=yes emit=body timeout=120
supervision-instructions|run=yes emit=body timeout=120
read-once|run=yes emit=body timeout=120
fleet-state|run=yes emit=body depth=full tail=5 queued=20 endpoint=10 timeout=120
network-checks|run=yes emit=body timeout=120
context|run=yes emit=slots timeout=120
next-step|run=yes emit=body timeout=120'

POINTER_SLOTS='projects	pointer	-
secondmates	pointer	-
captain	pointer	-
captain-shared	pointer	-
learnings	pointer	-'

BODY_SLOTS='projects	body	uncapped
secondmates	body	uncapped
captain	body	uncapped
captain-shared	body	uncapped
learnings	body	uncapped'

new_home() {  # <name>
  local home=$TMP_ROOT/$1
  mkdir -p "$home/config" "$home/.pi/extensions"
  printf 'on\n' >"$home/.pi/extensions/primary.on"
  printf '%s\n' "$home"
}

bind_home() {  # <home> <harness> <backend>
  unset FM_LOAD_PROFILES_TSV
  fm_load_profile_bind "$1" "$2" "$3" >"$TMP_ROOT/bind.out" 2>"$TMP_ROOT/bind.err"
  FM_LP_CODE=$?
}

expect_plan() {  # <spec>
  local line stage expect got
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    stage=${line%%|*}
    expect=${line#*|}
    got=$(fm_load_profile_policy "$stage")
    assert_equals "$expect" "$got" "policy $stage"
  done <<<"$1"
}

clear_timeout_env() {
  unset FM_SESSION_START_TIMEOUT FM_SESSION_START_STATUS_TAIL
  unset FM_SESSION_START_QUEUED_LIMIT FM_SESSION_START_ENDPOINT_TIMEOUT
}

test_default_pi_herdr_is_slim() {
  local home stages slots
  home=$(new_home pi-herdr)
  bind_home "$home" pi herdr
  assert_equals 0 "$FM_LP_CODE" "pi herdr bind failed"
  assert_equals slim "$(fm_load_profile_bound_id)" "pi herdr profile"
  assert_equals default-pi-herdr "$(fm_load_profile_source)" "pi herdr source"
  assert_equals '' "$(fm_load_profile_diagnostic)" "pi herdr diagnostic"
  stages=$(fm_load_profile_stages)
  assert_equals "$SLIM_STAGES" "$stages" "slim stage order"
  expect_plan "$SLIM_PLAN"
  slots=$(fm_load_profile_memory_slots)
  assert_equals "$POINTER_SLOTS" "$slots" "slim memory slots"
  assert_equals 24576 "$(fm_load_profile_slim_max_bytes)" "slim digest byte cap"

  home=$(new_home pi-signed)
  bind_home "$home" pi-signed herdr
  assert_equals 0 "$FM_LP_CODE" "pi-signed herdr bind failed"
  assert_equals slim "$(fm_load_profile_bound_id)" "pi-signed profile"
  assert_equals default-pi-herdr "$(fm_load_profile_source)" "pi-signed source"
  pass "pi and pi-signed herdr homes bind the slim plan"
}

test_default_other_is_full() {
  local home slots
  home=$(new_home claude)
  bind_home "$home" claude herdr
  assert_equals 0 "$FM_LP_CODE" "claude herdr bind failed"
  assert_equals full "$(fm_load_profile_bound_id)" "claude profile"
  assert_equals default-other "$(fm_load_profile_source)" "claude source"
  assert_equals '' "$(fm_load_profile_diagnostic)" "claude diagnostic"
  assert_equals "$SLIM_STAGES" "$(fm_load_profile_stages)" "full stage order"
  expect_plan "$FULL_PLAN"
  slots=$(fm_load_profile_memory_slots)
  assert_equals "$BODY_SLOTS" "$slots" "full memory slots"

  home=$(new_home pi-tmux)
  bind_home "$home" pi tmux
  assert_equals 0 "$FM_LP_CODE" "pi tmux bind failed"
  assert_equals full "$(fm_load_profile_bound_id)" "pi tmux profile"
  assert_equals default-other "$(fm_load_profile_source)" "pi tmux source"
  pass "other harness and backend homes bind the full plan"
}

test_config_token_and_unknown_fallthrough() {
  local home
  home=$(new_home configured)
  printf 'full\n' >"$home/config/load-profile"
  bind_home "$home" pi herdr
  assert_equals 0 "$FM_LP_CODE" "config full bind failed"
  assert_equals full "$(fm_load_profile_bound_id)" "config token profile"
  assert_equals config "$(fm_load_profile_source)" "config token source"
  assert_equals '' "$(fm_load_profile_diagnostic)" "config token diagnostic"
  assert_equals 'run=yes emit=body timeout=120' "$(fm_load_profile_policy bootstrap)" \
    "config full keeps bootstrap"

  printf 'nope\n' >"$home/config/load-profile"
  bind_home "$home" pi herdr
  assert_equals 0 "$FM_LP_CODE" "unknown token bind failed"
  assert_equals slim "$(fm_load_profile_bound_id)" "unknown token on pi herdr"
  assert_equals default-pi-herdr "$(fm_load_profile_source)" "unknown token pi source"
  assert_equals 'unknown load-profile token: nope' "$(fm_load_profile_diagnostic)" \
    "unknown token diagnostic"
  assert_equals 'run=no emit=pointer timeout=30' "$(fm_load_profile_policy bootstrap)" \
    "unknown token fell through to slim"

  bind_home "$home" claude tmux
  assert_equals full "$(fm_load_profile_bound_id)" "unknown token on other home"
  assert_equals default-other "$(fm_load_profile_source)" "unknown token other source"
  assert_equals 'unknown load-profile token: nope' "$(fm_load_profile_diagnostic)" \
    "unknown token other diagnostic"
  pass "config tokens select a profile and unknown tokens fall through"
}

test_env_overrides_do_not_flip_run_or_emit() {
  local home fleet
  home=$(new_home env)
  export FM_SESSION_START_TIMEOUT=9
  export FM_SESSION_START_STATUS_TAIL=2
  export FM_SESSION_START_QUEUED_LIMIT=3
  export FM_SESSION_START_ENDPOINT_TIMEOUT=4
  bind_home "$home" claude herdr
  assert_equals 0 "$FM_LP_CODE" "full env bind failed"
  assert_equals 'run=yes emit=body depth=full tail=2 queued=3 endpoint=4 timeout=9' \
    "$(fm_load_profile_policy fleet-state)" "full caps follow numeric env"
  assert_equals 'run=yes emit=body timeout=9' "$(fm_load_profile_policy lock)" \
    "timeout override keeps run and emit"

  bind_home "$home" pi herdr
  fleet=$(fm_load_profile_policy fleet-state)
  assert_equals 'run=yes emit=body depth=identity timeout=9' "$fleet" \
    "identity depth ignores tail, queued, and endpoint env"
  assert_not_contains "$fleet" 'tail=' "identity policy gained a tail cap"
  assert_equals 'run=no emit=pointer timeout=9' "$(fm_load_profile_policy network-checks)" \
    "numeric env flipped a slim emit"

  export FM_SESSION_START_TIMEOUT=pointer
  export FM_SESSION_START_STATUS_TAIL=body
  export FM_SESSION_START_QUEUED_LIMIT=no
  export FM_SESSION_START_ENDPOINT_TIMEOUT=emit
  bind_home "$home" claude herdr
  assert_equals 'run=yes emit=body depth=full tail=5 queued=20 endpoint=10 timeout=120' \
    "$(fm_load_profile_policy fleet-state)" "non-numeric env changed the full plan"
  bind_home "$home" pi herdr
  assert_equals 'run=no emit=pointer timeout=30' "$(fm_load_profile_policy network-checks)" \
    "non-numeric env flipped slim emit"
  clear_timeout_env
  pass "numeric env overrides change caps only"
}

test_reject_illegal_rows() {
  local home bad code
  home=$(new_home reject)
  bind_home "$home" pi herdr
  assert_equals slim "$(fm_load_profile_bound_id)" "reject setup lost the slim bind"

  bad=$TMP_ROOT/run-no-body.tsv
  printf '%s\n' $'profile\tstage\trun\temit\textra\tsession_timeout_sec' >"$bad"
  printf '%s\n' $'slim\tlock\tno\tbody\t\t30' >>"$bad"
  FM_LOAD_PROFILES_TSV=$bad
  fm_load_profile_bind "$home" pi herdr >"$TMP_ROOT/bind.out" 2>"$TMP_ROOT/bind.err"
  code=$?
  unset FM_LOAD_PROFILES_TSV
  assert_not_equals 0 "$code" "run=no emit=body was accepted"
  assert_contains "$(cat "$TMP_ROOT/bind.err")" 'run=no emit=body' \
    "rejection did not name run=no emit=body"
  fm_load_profile_bound_id >"$TMP_ROOT/bind.out" 2>"$TMP_ROOT/bind.err"
  code=$?
  assert_not_equals 0 "$code" "failed bind left a bound profile"

  bad=$TMP_ROOT/identity-tail.tsv
  printf '%s\n' $'profile\tstage\trun\temit\textra\tsession_timeout_sec' >"$bad"
  printf '%s\n' $'slim\tfleet-state\tyes\tbody\tidentity:tail=5,queued=20,endpoint=10\t30' >>"$bad"
  FM_LOAD_PROFILES_TSV=$bad
  fm_load_profile_bind "$home" pi herdr >"$TMP_ROOT/bind.out" 2>"$TMP_ROOT/bind.err"
  code=$?
  unset FM_LOAD_PROFILES_TSV
  assert_not_equals 0 "$code" "identity fleet with tail, queued, and endpoint was accepted"
  assert_contains "$(cat "$TMP_ROOT/bind.err")" \
    'identity fleet cannot carry tail, queued, or endpoint' \
    "rejection did not name the identity tail"
  fm_load_profile_stages >"$TMP_ROOT/bind.out" 2>"$TMP_ROOT/bind.err"
  code=$?
  assert_not_equals 0 "$code" "failed identity bind left stage state"
  pass "parser rejects run=no emit=body and identity tails"
}

test_pi_extensions_and_prefix_stay() {
  # Graft: this unit does not turn off Pi primary extensions or inject skills
  # into the always-on prefix. Bind reads the profile table and the config token.
  local home stages after
  home=$(new_home pi-ext)
  printf 'enabled\n' >"$home/.pi/extensions/sample.js"
  bind_home "$home" pi herdr
  assert_equals 0 "$FM_LP_CODE" "extension home bind failed"
  assert_equals on "$(cat "$home/.pi/extensions/primary.on")" \
    "bind turned off a Pi primary extension"
  assert_equals enabled "$(cat "$home/.pi/extensions/sample.js")" \
    "bind rewrote a Pi primary extension"
  stages=$(fm_load_profile_stages)
  assert_equals "$SLIM_STAGES" "$stages" "digest stages changed"
  assert_not_contains "$stages" 'SKILL.md' "bound stages name a skill file"
  assert_not_contains "$stages" '.agents/' "bound stages inject an always-on skill path"
  assert_absent "$home/AGENTS.md" "bind wrote an always-on prefix"
  after=$(cksum "$ROOT/AGENTS.md")
  assert_equals "$SCOPE_BEFORE" "$after" "unit edited AGENTS.md"
  pass "slim bind leaves Pi primary extensions on and does not inject skills"
}

test_default_pi_herdr_is_slim
test_default_other_is_full
test_config_token_and_unknown_fallthrough
test_env_overrides_do_not_flip_run_or_emit
test_reject_illegal_rows
test_pi_extensions_and_prefix_stay
