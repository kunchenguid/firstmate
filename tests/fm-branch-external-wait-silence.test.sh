#!/usr/bin/env bash
# Unchanged declared-external-wait branch outcomes stay silent after the first
# notice, while every required transition remains visible.
# Public interface: bin/fm-branch-outcome.sh (append, list, unread, startup-replay).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-branch-external-wait-silence)
OUTCOME="$ROOT/bin/fm-branch-outcome.sh"

append_outcome() {
  local home=$1 task=$2 verdict=$3 summary=$4 wake=$5
  if [ -n "${6:-}" ]; then
    FM_HOME="$home" "$OUTCOME" append --task "$task" --verdict "$verdict" --summary "$summary" --wake "$wake" --silent "$6"
  else
    FM_HOME="$home" "$OUTCOME" append --task "$task" --verdict "$verdict" --summary "$summary" --wake "$wake"
  fi
}

row_silent() {
  FM_HOME="$1" "$OUTCOME" list --recent 1 | jq -r '.silent'
}

row_silent_at() {
  FM_HOME="$1" "$OUTCOME" get --seq "$2" | jq -r '.silent'
}

assert_silent() {
  local home=$1 want=$2 msg=$3 got
  got=$(row_silent "$home") || fail "$msg (could not read silent field)"
  [ "$got" = "$want" ] || fail "$msg (silent=$got, expected $want)"
}

assert_replay_has() {
  local home=$1 needle=$2 msg=$3 replay
  replay=$(FM_HOME="$home" "$OUTCOME" startup-replay) || fail "$msg (startup-replay failed)"
  assert_contains "$replay" "$needle" "$msg"
}

assert_replay_silent() {
  local home=$1 needle=$2 msg=$3 replay
  replay=$(FM_HOME="$home" "$OUTCOME" startup-replay) || fail "$msg (startup-replay failed)"
  assert_not_contains "$replay" "$needle" "$msg"
}

home="$TMP_ROOT/home"
home_b="$TMP_ROOT/home-b"
mkdir -p "$home/state" "$home_b/state"

stale_wake_240='stale: firstmate:fm-pr-1 (paused 240s, awaiting external - declared pause, rechecked on a long cadence not a wedge; confirm the wait still holds)'
stale_wake_480='stale: firstmate:fm-pr-1 (paused 480s, awaiting external - declared pause, rechecked on a long cadence not a wedge; confirm the wait still holds)'
stale_wake_other='stale: firstmate:fm-pr-2 (paused 240s, awaiting external - declared pause, rechecked on a long cadence not a wedge; confirm the wait still holds)'

printf '%s\n' 'paused: self-hosted runner unavailable' > "$home/state/pr-1.status"
printf '%s\n' 'paused: self-hosted runner unavailable' > "$home/state/pr-2.status"
printf '%s\n' 'paused: self-hosted runner unavailable' > "$home_b/state/pr-1.status"

# First notice stays visible even if the caller asked for silence.
append_outcome "$home" pr-1 routine 'PR worker still waiting on the self-hosted runner' "$stale_wake_240" true >/dev/null \
  || fail "first wait append failed"
assert_silent "$home" false "first wait notice must stay visible"
assert_replay_has "$home" 'PR worker still waiting on the self-hosted runner' "startup replay hid the first wait notice"

# Unchanged wait: different age in the wake and different summary prose, same paused line.
append_outcome "$home" pr-1 routine 'still parked on the unavailable runner' "$stale_wake_480" >/dev/null \
  || fail "unchanged wait append failed"
assert_silent "$home" true "unchanged wait must be stored silent"
assert_replay_silent "$home" 'still parked on the unavailable runner' "startup replay replayed an unchanged wait"

# Exact sequence lookup remains bound to the appended outcome after another task appends.
wait_seq=$(append_outcome "$home" pr-1 routine 'still parked after another inspection' "$stale_wake_480") \
  || fail "concurrent-handoff wait append failed"
append_outcome "$home" pr-2 routine 'other task produced a visible transition' 'signal: working' >/dev/null \
  || fail "interleaved visible append failed"
[ "$(row_silent_at "$home" "$wait_seq")" = true ] \
  || fail "exact sequence lookup inherited a later outcome's visibility"

# Another task with the same pause prose is a first notice of its own.
append_outcome "$home" pr-2 routine 'PR worker still waiting on the self-hosted runner' "$stale_wake_other" >/dev/null \
  || fail "other-task wait append failed"
assert_silent "$home" false "a second task with similar prose must stay visible"
assert_replay_has "$home" 'PR worker still waiting on the self-hosted runner' "startup replay hid the other task's first wait"

# A different home with the same task id and pause line is isolated.
append_outcome "$home_b" pr-1 routine 'PR worker still waiting on the self-hosted runner' "$stale_wake_240" >/dev/null \
  || fail "other-home wait append failed"
assert_silent "$home_b" false "per-home isolation lost: other home reused this home's wait silence"
assert_replay_has "$home_b" 'PR worker still waiting on the self-hosted runner' "startup replay hid the other home's first wait"

# Changed wait condition on the original task becomes visible again.
printf '%s\n' 'paused: waiting for rate-limit reset' >> "$home/state/pr-1.status"
append_outcome "$home" pr-1 routine 'now waiting on a rate-limit reset' "$stale_wake_240" >/dev/null \
  || fail "changed-wait append failed"
assert_silent "$home" false "a changed wait must stay visible"
assert_replay_has "$home" 'now waiting on a rate-limit reset' "startup replay hid a changed wait"

# A later identical recheck of the new wait goes silent again.
append_outcome "$home" pr-1 routine 'still waiting on that rate-limit reset' "$stale_wake_480" >/dev/null \
  || fail "second unchanged wait append failed"
assert_silent "$home" true "the new wait's unchanged recheck must be silent"

# Decision / blocker, validation failure, recovery, green PR, merge, and a
# replacement task must all remain visible. These are not paused+stale matches.
printf '%s\n' 'needs-decision: which runner image to pin' >> "$home/state/pr-1.status"
append_outcome "$home" pr-1 captain 'need a decision on the runner image' 'signal: needs-decision' >/dev/null \
  || fail "decision append failed"
assert_silent "$home" false "a new decision must stay visible"

printf '%s\n' 'blocked: missing GHCR credential' >> "$home/state/pr-1.status"
append_outcome "$home" pr-1 captain 'blocked on a missing credential' 'signal: blocked' >/dev/null \
  || fail "blocker append failed"
assert_silent "$home" false "a blocker must stay visible"

printf '%s\n' 'failed: validation tests red' >> "$home/state/pr-1.status"
append_outcome "$home" pr-1 routine 'validation failed' 'signal: failed' >/dev/null \
  || fail "validation-failure append failed"
assert_silent "$home" false "a validation failure must stay visible"

printf '%s\n' 'working: self-hosted runner recovered, resuming' >> "$home/state/pr-1.status"
append_outcome "$home" pr-1 routine 'runner recovered, worker resuming' 'signal: working' >/dev/null \
  || fail "recovery append failed"
assert_silent "$home" false "runner recovery must stay visible"

append_outcome "$home" pr-1 captain 'PR https://example.com/pr/9 checks green' 'signal: done' >/dev/null \
  || fail "green-PR append failed"
assert_silent "$home" false "a green PR must stay visible"

append_outcome "$home" pr-1 captain 'merged https://example.com/pr/9' 'check: pr merged' >/dev/null \
  || fail "merge append failed"
assert_silent "$home" false "a merge must stay visible"

printf '%s\n' 'paused: self-hosted runner unavailable' > "$home/state/pr-1-replacement.status"
append_outcome "$home" pr-1-replacement routine 'replacement task waiting on the runner' "$stale_wake_240" >/dev/null \
  || fail "replacement-task append failed"
assert_silent "$home" false "a replacement task must stay visible"

# Same original pause text after recovery is a new episode because the most
# recent pr-1 outcome is not that wait identity.
printf '%s\n' 'paused: self-hosted runner unavailable' >> "$home/state/pr-1.status"
append_outcome "$home" pr-1 routine 'waiting on the runner again after recovery' "$stale_wake_240" >/dev/null \
  || fail "re-pause append failed"
assert_silent "$home" false "a new wait episode after recovery must stay visible"

# Similar summary on a different wait identity stays visible.
printf '%s\n' 'paused: waiting for docker hub' >> "$home/state/pr-2.status"
append_outcome "$home" pr-2 routine 'PR worker still waiting on the self-hosted runner' "$stale_wake_other" >/dev/null \
  || fail "similar-prose different-identity append failed"
assert_silent "$home" false "similar prose on a different wait must stay visible"

# A captain first-notice still records identity so a later routine recheck silences.
printf '%s\n' 'paused: upstream release not shipped' > "$home/state/pr-3.status"
append_outcome "$home" pr-3 captain 'first notice of the upstream wait' "$stale_wake_240" >/dev/null \
  || fail "captain first-wait append failed"
assert_silent "$home" false "a captain wait notice must stay visible"
append_outcome "$home" pr-3 routine 'upstream wait unchanged' "$stale_wake_480" >/dev/null \
  || fail "routine recheck after captain notice failed"
assert_silent "$home" true "routine recheck after a captain first notice must be silent"

# Restart path: an unread silent duplicate is consumed without a captain-facing reprint.
unread=$(FM_HOME="$home" "$OUTCOME" unread) || fail "unread failed"
assert_contains "$unread" 'upstream wait unchanged' "silent duplicate was not left unread before replay"
assert_replay_silent "$home" 'upstream wait unchanged' "restart replayed an unread unchanged wait"
[ -z "$(FM_HOME="$home" "$OUTCOME" unread)" ] || fail "startup replay did not mark the silent duplicate read"

printf 'PASS: unchanged external-wait outcomes are deduplicated while transitions remain visible\n'
