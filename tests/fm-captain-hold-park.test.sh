#!/usr/bin/env bash
# Behavior tests for `fm-captain-hold.sh hold --park`: PARK/HOLD is execution
# state and must not automatically surface as a current captain decision.
# Covers the DO IT/DECIDE/REVIEW filter's park path: a fresh parked item stays
# out of the OPEN DECISIONS drain, an ordinary live ask still surfaces
# normally, and parking a task that already carried a live unresolved captain
# hold resolves that occurrence's parent-channel decision instead of leaving
# it dangling (the defect diagnosed in the parked upstream branch).
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-captain-hold-park)
TASKS_AXI_BIN=$(command -v tasks-axi || true)

command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  printf '# Synthetic home\n' > "$home/AGENTS.md"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  printf '%s\n' "$home"
}

make_secondmate_home() {  # <name> <parent>
  local home="$TMP_ROOT/$1" parent=$2 fakebin
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  printf '# Synthetic secondmate home\n' > "$home/AGENTS.md"
  printf '%s\n' "$1" > "$home/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$parent" \
    > "$home/.fm-secondmate-parent"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  printf '%s\n' "$home"
}

tasks_in() {  # <home> <tasks-axi args...>
  local home=$1
  shift
  (cd "$home" && tasks-axi "$@")
}

# show_field_in <home> <id> <field>: read one "  field: value" line out of
# `tasks-axi show <id> --full`'s plain-text output (the same shape
# bin/fm-captain-hold.sh's own show_field parses), stripping a JSON quoting
# layer when present. Avoids depending on a --json flag `show` does not have.
show_field_in() {  # <home> <id> <field>
  local home=$1 id=$2 field=$3 raw
  raw=$(tasks_in "$home" show "$id" --full 2>/dev/null | sed -n "s/^  $field: //p" | head -1)
  case "$raw" in
    \"*\") printf '%s' "$raw" | perl -MJSON::PP -e 'local $/; print decode_json(<STDIN>);' ;;
    *) printf '%s' "$raw" ;;
  esac
}

run_captain() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-captain-hold.sh" "$@"
}

test_fresh_park_excluded_from_open_decisions() {
  local home
  home=$(make_home fresh-park)
  run_captain "$home" hold parked-task --title "Standby item" \
    --reason "not a current ask" --repo sample --park >/dev/null \
    || fail "hold --park on a fresh task failed"

  local hold_kind
  hold_kind=$(show_field_in "$home" parked-task hold_kind)
  assert_equals parked "$hold_kind" "hold --park did not record hold_kind=parked"
  assert_present "$home/state/parked-task.parked" "hold --park did not write the parked marker"

  local body
  body=$(show_field_in "$home" parked-task body)
  case "$body" in
    *"Captain hold set:"*) fail "hold --park incorrectly wrote a live-ask hold-set stamp" ;;
  esac

  # Seed a needs-decision line in the task's own status log, as a worker
  # would; the parked marker must keep it out of the presented drain even
  # though the raw log line stays untouched underneath.
  printf 'needs-decision [key=standby-check]: still not a live ask\n' \
    > "$home/state/parked-task.status"
  local open
  open=$(scan_open_decisions "$home/state")
  assert_equals "" "$open" "a parked task's open decision leaked into the drain"
  assert_grep "needs-decision" "$home/state/parked-task.status" \
    "parking must not rewrite or erase the underlying status log"
  pass "a fresh parked item stays out of the OPEN DECISIONS drain"
}

test_ordinary_hold_still_surfaces() {
  local home
  home=$(make_home ordinary-hold)
  run_captain "$home" hold live-task --title "A live ask" \
    --reason "genuine choice pending" --repo sample >/dev/null \
    || fail "an ordinary hold failed"
  assert_absent "$home/state/live-task.parked" \
    "an ordinary hold incorrectly wrote a parked marker"
  printf 'needs-decision [key=live-check]: genuine choice pending\n' \
    > "$home/state/live-task.status"
  local open
  open=$(scan_open_decisions "$home/state")
  assert_contains "$open" "live-task" \
    "an ordinary held item's own status line did not surface in the drain"
  pass "an ordinary (non-parked) held item still surfaces normally"
}

test_unpark_restores_live_hold_and_removes_marker() {
  local home
  home=$(make_home unpark)
  run_captain "$home" hold flip-task --title "Flip me" \
    --reason "starts parked" --repo sample --park >/dev/null \
    || fail "initial park failed"
  assert_present "$home/state/flip-task.parked" "park did not write its marker"
  run_captain "$home" hold flip-task --reason "now a live ask" >/dev/null \
    || fail "un-parking hold failed"
  local hold_kind
  hold_kind=$(show_field_in "$home" flip-task hold_kind)
  assert_equals captain "$hold_kind" "un-parking did not restore hold_kind=captain"
  assert_absent "$home/state/flip-task.parked" \
    "un-parking left the parked marker behind"
  pass "an ordinary hold on a previously parked task removes the marker and restores a live ask"
}

# The diagnosed parent-decision resolution defect: parking a task that already
# carries a LIVE, unresolved captain hold must resolve that occurrence's
# parent-channel decision rather than leaving it open forever. Exercised
# through a secondmate home, where publish_parent_hold's effect (a line in the
# parent's own status file) is directly observable.
test_parking_a_live_hold_resolves_its_parent_decision() {
  local parent mate channel
  parent=$(make_home park-parent)
  mate=$(make_secondmate_home park-mate "$parent")
  channel="$parent/state/park-mate.status"

  run_captain "$mate" hold live-then-parked --title "Choose the release" \
    --reason "release choice pending" --repo sample >/dev/null \
    || fail "initial live hold failed"
  assert_grep 'needs-decision [key=captain-hold-live-then-parked-1]: captain hold live-then-parked: release choice pending' \
    "$channel" "the initial live hold did not reach the parent channel"

  run_captain "$mate" hold live-then-parked --reason "now standing by" --park >/dev/null \
    || fail "parking a live hold failed"
  assert_grep 'resolved [key=captain-hold-live-then-parked-1]: captain hold live-then-parked: parked' \
    "$channel" "parking a live hold left its parent decision dangling"
  assert_present "$mate/state/live-then-parked.parked" "parking did not write the marker in the mate home"

  local hold_kind
  hold_kind=$(show_field_in "$mate" live-then-parked hold_kind)
  assert_equals parked "$hold_kind" "parking a live hold did not record hold_kind=parked"
  pass "parking a live captain hold resolves its dangling parent decision instead of leaving it open"
}

# A fresh park (no prior live hold to resolve) must not fabricate a resolved
# event: there was never a live ask open on the parent channel for it.
test_fresh_park_publishes_no_resolved_event() {
  local parent mate channel
  parent=$(make_home fresh-park-parent)
  mate=$(make_secondmate_home fresh-park-mate "$parent")
  channel="$parent/state/fresh-park-mate.status"

  run_captain "$mate" hold standby-only --title "Standby only" \
    --reason "not a current ask" --repo sample --park >/dev/null \
    || fail "fresh park in a secondmate home failed"
  if [ -f "$channel" ]; then
    assert_no_grep "standby-only" "$channel" \
      "a fresh park fabricated a parent-channel event with nothing to resolve"
  fi
  pass "a fresh park with no prior live hold publishes nothing to the parent channel"
}

# Codex review finding on PR #4344: when parking an existing live hold and the
# parent-channel write itself fails, the backlog already transitioned to
# hold_kind=parked. A naive re-check of `existing_hold_kind = captain` then
# never fires again on retry (existing_hold_kind now reads "parked"), so the
# parent's needs-decision would stay open forever with no way to complete it.
# Force that failure by making the destination file unwritable, confirm the
# resolved line is NOT published and a durable pending marker survives the
# failed attempt, then restore write access and confirm a plain re-park
# (still without --park having changed) completes the deferred publish and
# clears the marker.
test_park_retries_resolution_after_a_failed_publish() {
  local parent mate channel
  parent=$(make_home retry-parent)
  mate=$(make_secondmate_home retry-mate "$parent")
  channel="$parent/state/retry-mate.status"

  run_captain "$mate" hold flaky-parent --title "Choose the flaky release" \
    --reason "flaky release choice pending" --repo sample >/dev/null \
    || fail "initial live hold failed"
  assert_present "$channel" "the initial live hold did not create the parent channel file"

  chmod 0444 "$channel" || fail "could not make the parent channel read-only for the test"
  run_captain "$mate" hold flaky-parent --reason "now standing by" --park >/dev/null \
    || fail "parking with a broken parent channel unexpectedly failed the whole command"
  chmod 0644 "$channel" || fail "could not restore parent channel permissions"

  assert_no_grep 'resolved [key=captain-hold-flaky-parent-1]' "$channel" \
    "a failed parent-channel write was somehow still recorded as resolved"
  assert_present "$mate/state/flaky-parent.park-pending-resolve" \
    "a failed publish attempt did not leave a durable retry marker"

  local hold_kind
  hold_kind=$(show_field_in "$mate" flaky-parent hold_kind)
  assert_equals parked "$hold_kind" \
    "the backlog transition to parked must land even when the parent publish fails"

  run_captain "$mate" hold flaky-parent --reason "still standing by" --park >/dev/null \
    || fail "the retrying park call failed"
  assert_grep 'resolved [key=captain-hold-flaky-parent-1]: captain hold flaky-parent: parked' \
    "$channel" "retrying park after repairing the channel did not complete the deferred resolution"
  assert_absent "$mate/state/flaky-parent.park-pending-resolve" \
    "the retry marker survived a successful retry"
  pass "a park whose parent-channel publish fails retries the resolution on a later park instead of losing it"
}

test_fresh_park_excluded_from_open_decisions
test_ordinary_hold_still_surfaces
test_unpark_restores_live_hold_and_removes_marker
test_parking_a_live_hold_resolves_its_parent_decision
test_fresh_park_publishes_no_resolved_event
test_park_retries_resolution_after_a_failed_publish
