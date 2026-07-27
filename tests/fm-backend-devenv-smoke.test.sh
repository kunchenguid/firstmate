#!/usr/bin/env bash
# fm-backend-devenv-smoke.test.sh - opt-in remote control-plane lease round trip.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CONTROLLER="$ROOT/bin/fm-devenv-controller.sh"
INSTALLER="$ROOT/bin/fm-devenv-install.sh"

# shellcheck source=bin/fm-devenv-controller.sh
. "$CONTROLLER"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

fm_devenv_smoke_error() {
  printf 'fm-backend-devenv-smoke: %s\n' "$1" >&2
  return 1
}

fm_devenv_smoke_validate_opt_in() {
  [ "$#" -eq 3 ] || return 2
  local environment=$1 session=$2 ambient=$3
  [ -n "$environment" ] || { fm_devenv_smoke_error 'FM_DEVENV_SMOKE_ENV is required'; return 1; }
  [ "$environment" != main ] || { fm_devenv_smoke_error 'main is not a smoke-test target'; return 1; }
  [ -n "$session" ] || { fm_devenv_smoke_error 'FM_DEVENV_SMOKE_SESSION is required'; return 1; }
  [ "$session" != default ] || { fm_devenv_smoke_error 'the default Herdr session is not a smoke-test target'; return 1; }
  [ "$session" != "$ambient" ] || { fm_devenv_smoke_error 'the ambient Herdr session is not a smoke-test target'; return 1; }
  fm_devenv_name_valid "$environment" || { fm_devenv_smoke_error 'FM_DEVENV_SMOKE_ENV is invalid'; return 1; }
  case "$session" in
    *[!A-Za-z0-9_-]*) fm_devenv_smoke_error 'FM_DEVENV_SMOKE_SESSION is invalid'; return 1 ;;
  esac
}

fm_devenv_smoke_live_requested() {
  [ "$#" -eq 2 ] || return 2
  if [ -z "$1" ] && [ -z "$2" ]; then
    return 3
  fi
  [ -n "$1" ] && [ -n "$2" ] || {
    fm_devenv_smoke_error 'FM_DEVENV_SMOKE_ENV and FM_DEVENV_SMOKE_SESSION must be set together'
    return 1
  }
}

fm_devenv_smoke_snapshot() {
  [ "$#" -eq 1 ] || return 2
  herdr --session "$1" api snapshot
}

fm_devenv_smoke_runtime_verify() {
  [ "$#" -eq 1 ] || return 2
  "$INSTALLER" --verify "$1" >/dev/null
}

fm_devenv_smoke_registry_row() {
  [ "$#" -eq 1 ] || return 2
  # shellcheck disable=SC2119
  fm_devenv_registry_get "$(fm_devenv_registry_path)" "$1"
}

fm_devenv_smoke_runtime_commit() {
  git -C "$ROOT" rev-parse HEAD
}

fm_devenv_smoke_new_token() {
  fm_devenv_new_token
}

fm_devenv_smoke_now() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

fm_devenv_smoke_exchange() {
  [ "$#" -eq 3 ] || return 2
  local row=$1 operation=$2 lease=$3 request response vm error
  request=$(fm_devenv_protocol_request "$row" "$operation" "$lease" '{}') || return 1
  vm=$(printf '%s\n' "$row" | jq -er '.vm') || return 1
  response=$(fm_backend_devenv_request "$vm" "$request") || return 1
  if ! printf '%s\n' "$response" | jq -e '.ok == true' >/dev/null 2>&1; then
    error=$(printf '%s\n' "$response" | jq -r '(.error.code // "unknown") + ": " + (.error.message // "remote request failed")' 2>/dev/null) \
      || error='remote request failed'
    fm_devenv_smoke_error "$operation failed: $error"
    return 1
  fi
  printf '%s\n' "$response" | jq -ce '.result'
}

fm_devenv_smoke_assert_clean_inspect() {
  [ "$#" -eq 3 ] || return 2
  local result=$1 commit=$2 expected_branch=$3
  printf '%s\n' "$result" | jq -e \
    --arg commit "$commit" \
    --arg branch "$expected_branch" '
      .runtime_version == $commit
      and .lease == null
      and .git.clean == true
      and (.git.branch | type == "string" and length > 0)
      and ($branch == "" or .git.branch == $branch)
      and .agent_present == null
      and .herdr_session_present == false
    ' >/dev/null 2>&1
}

fm_devenv_smoke_assert_lease() {
  [ "$#" -eq 2 ] || return 2
  printf '%s\n' "$1" | jq -e --argjson lease "$2" '
    .lease == ($lease | del(.schema, .generation_token))
    and .git.clean == true
    and .agent_present == null
    and .herdr_session_present == false
  ' >/dev/null 2>&1
}

fm_devenv_smoke_round_trip() (
  [ "$#" -eq 3 ] || return 2
  local environment=$1 session=$2 ambient=$3 row vm commit before_session before_ambient
  local initial branch token issued_at lease token_lease claim status release final
  local after_session after_ambient cleanup_armed=0

  # shellcheck disable=SC2329
  fm_devenv_smoke_cleanup_lease() {
    [ "$cleanup_armed" -eq 1 ] || return 0
    # shellcheck disable=SC2031
    token_lease=$(jq -cn --arg token "$token" '{generation_token:$token}') || return 1
    fm_devenv_smoke_exchange "$row" release "$token_lease" >/dev/null 2>&1 || {
      fm_devenv_smoke_error "cleanup could not release the control-plane-test lease for $environment"
      return 1
    }
  }
  trap fm_devenv_smoke_cleanup_lease EXIT

  fm_devenv_smoke_validate_opt_in "$environment" "$session" "$ambient" || return 1
  row=$(fm_devenv_smoke_registry_row "$environment") || {
    fm_devenv_smoke_error "could not resolve feature environment: $environment"
    return 1
  }
  vm=$(printf '%s\n' "$row" | jq -er '.vm') || return 1
  before_session=$(fm_devenv_smoke_snapshot "$session") || {
    fm_devenv_smoke_error "could not snapshot dedicated Herdr session: $session"
    return 1
  }
  before_ambient=$(fm_devenv_smoke_snapshot "$ambient") || {
    fm_devenv_smoke_error "could not snapshot ambient Herdr session: $ambient"
    return 1
  }
  fm_devenv_smoke_runtime_verify "$environment" || {
    fm_devenv_smoke_error "remote runtime verification failed for: $environment"
    return 1
  }
  commit=$(fm_devenv_smoke_runtime_commit) || return 1
  initial=$(fm_devenv_smoke_exchange "$row" inspect null) || return 1
  fm_devenv_smoke_assert_clean_inspect "$initial" "$commit" '' || {
    fm_devenv_smoke_error 'initial inspection was not clean, idle, lease-free, and runtime-matched'
    return 1
  }
  branch=$(printf '%s\n' "$initial" | jq -er '.git.branch') || return 1
  token=$(fm_devenv_smoke_new_token) || return 1
  issued_at=$(fm_devenv_smoke_now) || return 1
  lease=$(jq -cn \
    --arg token "$token" \
    --arg environment "$environment" \
    --arg vm "$vm" \
    --arg branch "$branch" \
    --arg issued_at "$issued_at" \
    '{schema:"firstmate.devenv.lease.v1",generation_token:$token,environment:$environment,vm:$vm,task_id:"control-plane-test",branch:$branch,lease_state:"leased",issued_at:$issued_at}') \
    || return 1
  cleanup_armed=1
  claim=$(fm_devenv_smoke_exchange "$row" claim "$lease") || return 1
  fm_devenv_smoke_assert_lease "$claim" "$lease" || {
    fm_devenv_smoke_error 'claim response did not match the control-plane-test lease'
    return 1
  }
  token_lease=$(jq -cn --arg token "$token" '{generation_token:$token}') || return 1
  status=$(fm_devenv_smoke_exchange "$row" status "$token_lease") || return 1
  fm_devenv_smoke_assert_lease "$status" "$lease" || {
    fm_devenv_smoke_error 'reconnected status did not return the same lease'
    return 1
  }
  release=$(fm_devenv_smoke_exchange "$row" release "$token_lease") || return 1
  printf '%s\n' "$release" | jq -e '.lease == null' >/dev/null 2>&1 || {
    fm_devenv_smoke_error 'release response still reported a lease'
    return 1
  }
  cleanup_armed=0
  final=$(fm_devenv_smoke_exchange "$row" inspect null) || return 1
  fm_devenv_smoke_assert_clean_inspect "$final" "$commit" "$branch" || {
    fm_devenv_smoke_error 'final inspection did not prove the marker absent and checkout unchanged'
    return 1
  }
  after_session=$(fm_devenv_smoke_snapshot "$session") || return 1
  after_ambient=$(fm_devenv_smoke_snapshot "$ambient") || return 1
  [ "$before_session" = "$after_session" ] || {
    fm_devenv_smoke_error "dedicated Herdr session changed during the lease round trip: $session"
    return 1
  }
  [ "$before_ambient" = "$after_ambient" ] || {
    fm_devenv_smoke_error "ambient Herdr session changed during the lease round trip: $ambient"
    return 1
  }
  trap - EXIT
  printf '%s\n' "$token"
)

fm_devenv_smoke_use_fakes() {
  fm_devenv_smoke_snapshot() {
    local session=$1 counter count
    [ -z "${FM_TEST_SMOKE_LOG:-}" ] || printf 'snapshot:%s\n' "$session" >> "$FM_TEST_SMOKE_LOG"
    if [ "$session" = "${FM_TEST_SMOKE_MUTATE_SESSION:-}" ]; then
      counter="$FM_TEST_SMOKE_COUNTER/$session"
      printf '%s\n' "$session" >> "$counter"
      count=$(wc -l < "$counter" | tr -d '[:space:]')
      printf '%s\n' "{\"session\":\"$session\",\"revision\":$count}"
    else
      printf '%s\n' "{\"session\":\"$session\",\"revision\":1}"
    fi
  }
  fm_devenv_smoke_runtime_verify() {
    [ -z "${FM_TEST_SMOKE_LOG:-}" ] || printf 'verify:%s\n' "$1" >> "$FM_TEST_SMOKE_LOG"
  }
  fm_devenv_smoke_registry_row() {
    printf '%s\n' '{"name":"reviews","vm":"expanly-reviews","slot":1,"frontend_port":5174,"branch":""}'
  }
  fm_devenv_smoke_runtime_commit() { printf '%040d\n' 1; }
  fm_devenv_smoke_new_token() { printf '%s\n' "$FM_TEST_SMOKE_TOKEN"; }
  fm_devenv_smoke_now() { printf '%s\n' 2026-07-27T12:00:00Z; }
  fm_devenv_smoke_exchange() {
    local operation=$2 lease=$3
    [ -z "${FM_TEST_SMOKE_LOG:-}" ] \
      || printf '%s:%s\n' "$operation" "$(printf '%s\n' "$lease" | jq -r '.generation_token // "null"')" >> "$FM_TEST_SMOKE_LOG"
    [ "$operation" != status ] || [ "${FM_TEST_SMOKE_STATUS_FAIL:-0}" != 1 ] || return 1
    case "$operation" in
      inspect)
        jq -cn --arg runtime "$(printf '%040d' 1)" \
          '{runtime_version:$runtime,lease:null,git:{branch:"feature/reviews",clean:true},agent_present:null,herdr_session_present:false}'
        ;;
      claim|status)
        jq -cn '{runtime_version:null,lease:{environment:"reviews",vm:"expanly-reviews",task_id:"control-plane-test",branch:"feature/reviews",lease_state:"leased",issued_at:"2026-07-27T12:00:00Z"},git:{branch:"feature/reviews",clean:true},agent_present:null,herdr_session_present:false}'
        ;;
      release)
        jq -cn '{runtime_version:null,lease:null,git:{branch:"feature/reviews",clean:true},agent_present:null,herdr_session_present:false}'
        ;;
    esac
  }
}

test_live_opt_in_refusals() {
  fm_devenv_smoke_validate_opt_in reviews fm-devenv-protocol-lab default \
    || fail "an isolated feature environment and dedicated Herdr session were refused"
  ! fm_devenv_smoke_validate_opt_in main fm-devenv-protocol-lab default 2>/dev/null \
    || fail "main was accepted for the live smoke"
  ! fm_devenv_smoke_validate_opt_in reviews '' default 2>/dev/null \
    || fail "an empty Herdr session was accepted for the live smoke"
  ! fm_devenv_smoke_validate_opt_in reviews fm-ambient fm-ambient 2>/dev/null \
    || fail "the ambient Herdr session was accepted for the live smoke"
  pass "devenv smoke: main, empty, and ambient targets are refused"
}

test_default_and_partial_opt_in_gate() {
  local rc
  fm_devenv_smoke_live_requested '' '' >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 3 ] || fail "the default smoke path should skip live work"
  ! fm_devenv_smoke_live_requested reviews '' >/dev/null 2>&1 \
    || fail "an environment-only opt-in was accepted"
  ! fm_devenv_smoke_live_requested '' fm-devenv-protocol-lab >/dev/null 2>&1 \
    || fail "a session-only opt-in was accepted"
  fm_devenv_smoke_live_requested reviews fm-devenv-protocol-lab \
    || fail "the complete live opt-in was refused"
  pass "devenv smoke: live work requires both explicit opt-in values"
}

test_snapshot_uses_global_named_session_option() (
  local log snapshot
  log=$(mktemp "${TMPDIR:-/tmp}/fm-devenv-smoke-herdr.XXXXXX") || exit 1
  trap 'rm -f -- "$log"' EXIT
  herdr() {
    printf '%s\n' "$*" > "$log"
    printf '%s\n' '{"agents":[],"layouts":[],"panes":[],"tabs":[],"workspaces":[]}'
  }
  snapshot=$(fm_devenv_smoke_snapshot fm-devenv-protocol-lab) \
    || fail "the named Herdr snapshot failed"
  [ "$(cat "$log")" = '--session fm-devenv-protocol-lab api snapshot' ] \
    || fail "api snapshot did not put the global --session option before the subcommand"
  printf '%s\n' "$snapshot" | jq -e '.panes == [] and .workspaces == []' >/dev/null \
    || fail "the named Herdr snapshot output was not preserved"
  pass "devenv smoke: Herdr snapshot uses the explicit global named-session option"
)

test_fake_round_trip_order_and_token_continuity() (
  local log result
  log=$(mktemp "${TMPDIR:-/tmp}/fm-devenv-smoke-calls.XXXXXX") || exit 1
  trap 'rm -f -- "$log"' EXIT
  FM_TEST_SMOKE_LOG=$log
  FM_TEST_SMOKE_TOKEN=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  fm_devenv_smoke_use_fakes

  result=$(fm_devenv_smoke_round_trip reviews fm-devenv-protocol-lab default) \
    || fail "the fake lease round trip failed"
  [ "$result" = "$FM_TEST_SMOKE_TOKEN" ] || fail "the fake round trip did not return its generation token"
  [ "$(cat "$log")" = "$(printf '%s\n' \
    'snapshot:fm-devenv-protocol-lab' \
    'snapshot:default' \
    'verify:reviews' \
    'inspect:null' \
    "claim:$FM_TEST_SMOKE_TOKEN" \
    "status:$FM_TEST_SMOKE_TOKEN" \
    "release:$FM_TEST_SMOKE_TOKEN" \
    'inspect:null' \
    'snapshot:fm-devenv-protocol-lab' \
    'snapshot:default')" ] || fail "the smoke did not use the required read-mostly order with one token"
  pass "devenv smoke: fake transport preserves the exact lease sequence and token"
)

test_fake_failure_attempts_token_guarded_cleanup() (
  local log
  log=$(mktemp "${TMPDIR:-/tmp}/fm-devenv-smoke-cleanup.XXXXXX") || exit 1
  trap 'rm -f -- "$log"' EXIT
  FM_TEST_SMOKE_LOG=$log
  FM_TEST_SMOKE_TOKEN=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  FM_TEST_SMOKE_STATUS_FAIL=1
  fm_devenv_smoke_use_fakes

  ! fm_devenv_smoke_round_trip reviews fm-devenv-protocol-lab default >/dev/null 2>&1 \
    || fail "the injected reconnect failure was accepted"
  assert_grep "release:$FM_TEST_SMOKE_TOKEN" "$log" \
    "a post-claim failure did not attempt token-guarded cleanup"
  pass "devenv smoke: a post-claim failure attempts token-guarded cleanup"
)

test_fake_snapshot_mutation_is_refused() {
  local changed
  for changed in fm-devenv-protocol-lab default; do
    (
      FM_TEST_SMOKE_COUNTER=$(mktemp -d "${TMPDIR:-/tmp}/fm-devenv-smoke-snapshot.XXXXXX") || exit 1
      trap 'rm -rf -- "$FM_TEST_SMOKE_COUNTER"' EXIT
      FM_TEST_SMOKE_TOKEN=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
      FM_TEST_SMOKE_MUTATE_SESSION=$changed
      fm_devenv_smoke_use_fakes

      ! fm_devenv_smoke_round_trip reviews fm-devenv-protocol-lab default >/dev/null 2>&1 \
        || fail "a changed Herdr snapshot was accepted for $changed"
    ) || return 1
  done
  pass "devenv smoke: dedicated and ambient Herdr snapshot changes are refused"
}

test_live_opt_in_refusals
test_default_and_partial_opt_in_gate
test_snapshot_uses_global_named_session_option || exit 1
test_fake_round_trip_order_and_token_continuity || exit 1
test_fake_failure_attempts_token_guarded_cleanup || exit 1
test_fake_snapshot_mutation_is_refused || exit 1

smoke_environment=${FM_DEVENV_SMOKE_ENV:-}
smoke_session=${FM_DEVENV_SMOKE_SESSION:-}
smoke_gate=0
fm_devenv_smoke_live_requested "$smoke_environment" "$smoke_session" >/dev/null 2>&1 || smoke_gate=$?
case "$smoke_gate" in
  0) ;;
  3) echo "skip: set FM_DEVENV_SMOKE_ENV and FM_DEVENV_SMOKE_SESSION for the live devenv smoke"; exit 0 ;;
  *) fm_devenv_smoke_live_requested "$smoke_environment" "$smoke_session"; exit 1 ;;
esac

command -v herdr >/dev/null 2>&1 || fail "the live devenv smoke requires herdr"
command -v ssh >/dev/null 2>&1 || fail "the live devenv smoke requires ssh"
ambient_session=${HERDR_SESSION:-default}
live_token=$(fm_devenv_smoke_round_trip "$smoke_environment" "$smoke_session" "$ambient_session") \
  || fail "the live devenv lease round trip failed"
# Token continuity is the guarantee; the value itself must never reach a retained log.
printf '%s\n' "$live_token" | grep -Eq '^[0-9a-f]{64}$' \
  || fail "the live devenv round trip did not return one generation token"
pass "devenv smoke: live lease [generation token redacted] survived a fresh SSH request and released cleanly"
