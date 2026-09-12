#!/usr/bin/env bash
# tests/fm-wake-drain-parent-inbox.test.sh - a secondmate's turn-boundary drain
# surfaces its oldest unacknowledged parent instruction ahead of routine wake
# rows, for local and remote parent routes, without acknowledging it.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"
TMP_ROOT=$(fm_test_tmproot fm-wake-drain-parent-inbox-tests)

seed_mate() {  # <home> <route> [parent-home]
  mkdir -p "$1/state"
  printf 'mate-1\n' > "$1/.fm-secondmate-home"
  if [ "$2" = local ]; then
    printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$3" > "$1/.fm-secondmate-parent"
  else
    printf 'schema=fm-secondmate-parent.v1\nroute=remote\nparent_host=parent\n' > "$1/.fm-secondmate-parent"
  fi
}

write_msg() {  # <inbox> <seq> <text>
  mkdir -p "$1/handled"
  printf 'schema=fm-task-inbox.v1\n--\n%s\n' "$3" > "$1/$2.msg"
}

assert_parent_first() {  # <home> <inbox> <label>
  local home=$1 inbox=$2 label=$3 out first
  out="$home/drain.out"
  append_wake "$home/state" check refill-deficit "check: refill-deficit"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$DRAIN" > "$out" 2>/dev/null \
    || fail "$label: drain failed"
  first=$(head -n 1 "$out")
  case "$first" in
    "PARENT INSTRUCTION WAITING: "*"$inbox/002.msg "*) ;;
    *) fail "$label: the oldest parent instruction was not surfaced first: $(cat "$out")" ;;
  esac
  grep -F 'check: refill-deficit' "$out" >/dev/null \
    || fail "$label: the routine refill wake was dropped: $(cat "$out")"
  [ -f "$inbox/002.msg" ] && [ -f "$inbox/010.msg" ] \
    || fail "$label: drain acknowledged a parent instruction"
  mv "$inbox/002.msg" "$inbox/010.msg" "$inbox/handled/"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$DRAIN" > "$out" 2>/dev/null \
    || fail "$label: drain after acknowledgement failed"
  if grep -F 'PARENT INSTRUCTION WAITING' "$out" >/dev/null; then
    fail "$label: an acknowledged parent instruction was surfaced again: $(cat "$out")"
  fi
  pass "$label: a pending parent instruction precedes routine wakes until acknowledged"
}

test_local_route() {
  local home="$TMP_ROOT/local/mate" parent="$TMP_ROOT/local/parent" inbox
  inbox="$parent/state/mate-1.inbox"
  seed_mate "$home" local "$parent"
  write_msg "$inbox" 010 'later instruction'
  write_msg "$inbox" 002 'persist the update and restart'
  assert_parent_first "$home" "$inbox" "local route"
}

test_remote_route() {
  local home="$TMP_ROOT/remote/mate" inbox
  inbox="$home/state/parent-route/mate-1.inbox"
  seed_mate "$home" remote
  write_msg "$inbox" 010 'later instruction'
  write_msg "$inbox" 002 'persist the update and restart'
  assert_parent_first "$home" "$inbox" "remote route"
}

test_main_home_is_silent() {
  local home="$TMP_ROOT/main" out
  mkdir -p "$home/state"
  append_wake "$home/state" check refill-deficit "check: refill-deficit"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$DRAIN" 2>/dev/null) || fail "main-home drain failed"
  case "$out" in *'PARENT INSTRUCTION WAITING'*) fail "a main home reported a parent instruction: $out" ;; esac
  pass "a main home drain has no parent-instruction notice"
}

test_local_route
test_remote_route
test_main_home_is_silent
