#!/usr/bin/env bash
# tests/fm-afk-alarm.test.sh - the away posture's supervisor-failure channel
# (bin/fm-afk-alarm.sh): the loud local marker, the captain-held record it
# creates through the real bin/fm-captain-hold.sh and tasks-axi, its refusal
# without a confirmed away-posture record, idempotent repeats, and the read
# subcommands the return brief relies on.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

ALARM="$ROOT/bin/fm-afk-alarm.sh"
TMP_ROOT=$(fm_test_tmproot fm-afk-alarm-tests)

make_home() {  # <name> -> prints the home dir
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data" "$home/config"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  printf '%s\n' "$home"
}

alarm() {  # <home> <args...>
  local home=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$ALARM" "$@"
}

write_record() {  # <home>
  local home=$1
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$ROOT/bin/fm-afk-contract.sh" propose >/dev/null 2>&1 \
    || fail "could not propose the away-posture record"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$ROOT/bin/fm-afk-contract.sh" confirm >/dev/null 2>&1 \
    || fail "could not confirm the away-posture record"
}

hold_field() {  # <home> <field>
  (cd "$1" && tasks-axi show fm-afk-supervisor-alarm --full --file data/backlog.md 2>/dev/null) \
    | sed -n "s/^  $2: //p" | head -1
}

test_raise_refuses_without_the_record() {
  local home rc out
  home=$(make_home attended)
  set +e
  out=$(alarm "$home" raise 'watcher: FAILED - synthetic' 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 3 ] || fail "raise without a record exited $rc, not 3: $out"
  assert_contains "$out" 'no confirmed away-posture record' "the attended refusal lost its wording"
  [ ! -e "$home/state/.afk-supervisor-alarm" ] || fail "an attended raise wrote the marker"
  set +e
  alarm "$home" present
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "present reported an alarm in a home that has none"
  [ -z "$(alarm "$home" list)" ] || fail "list printed alarms in a home that has none"
  pass "an attended failure never uses the away alarm channel"
}

test_raise_writes_the_marker_and_holds_the_record() {
  local home rc out first second
  home=$(make_home away)
  write_record "$home"
  set +e
  out=$(alarm "$home" raise $'watcher: FAILED - Pi extension\tcould not restore\nsecond line' 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "raise under the record exited $rc: $out"
  [ -s "$home/state/.afk-supervisor-alarm" ] || fail "raise did not write the marker"
  first=$(head -1 "$home/state/.afk-supervisor-alarm")
  case "$first" in
    [0-9]*"	watcher: FAILED - Pi extension could not restore second line") ;;
    *) fail "marker line is not '<epoch>\\t<one-line summary>': $first" ;;
  esac
  [ "$(hold_field "$home" hold_kind)" = captain ] || fail "the alarm did not hold its record for the captain: $(cd "$home" && tasks-axi show fm-afk-supervisor-alarm --full --file data/backlog.md 2>&1)"
  [ "$(hold_field "$home" held)" = yes ] || fail "the alarm's record is not held"
  alarm "$home" present || fail "present did not see the raised alarm"

  # A second alarm appends and re-holds idempotently.
  set +e
  out=$(alarm "$home" raise 'watcher: FAILED - again' 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "second raise exited $rc: $out"
  [ "$(grep -c . "$home/state/.afk-supervisor-alarm")" -eq 2 ] || fail "second raise did not append"
  second=$(alarm "$home" list | tail -1 | cut -f2-)
  [ "$second" = 'watcher: FAILED - again' ] || fail "list did not print the second alarm: $second"
  [ "$(hold_field "$home" hold_kind)" = captain ] || fail "the repeat lost the captain hold"
  [ "$(cd "$home" && tasks-axi list --file data/backlog.md 2>/dev/null | grep -c 'fm-afk-supervisor-alarm')" -eq 1 ] \
    || fail "the repeat created a second hold record"
  pass "an away failure writes the loud marker and holds one captain record, idempotently"
}

test_marker_stands_when_the_hold_cannot_be_written() {
  local home rc out fakebin
  home=$(make_home no-backlog)
  write_record "$home"
  # A tasks-axi that refuses everything: the courtesy hold fails, the marker
  # does not.
  fakebin=$(fm_fakebin "$home")
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fakebin/tasks-axi"
  chmod +x "$fakebin/tasks-axi"
  set +e
  out=$(PATH="$fakebin:$PATH" alarm "$home" raise 'watcher: FAILED - no backlog backend' 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 4 ] || fail "raise with an unusable backlog exited $rc, not 4: $out"
  assert_contains "$out" 'hold record fm-afk-supervisor-alarm could not be written' "the hold failure was not named"
  [ -s "$home/state/.afk-supervisor-alarm" ] || fail "the marker did not survive a failed hold"
  pass "the marker is the guarantee: it stands even when the hold record cannot be written"
}

test_raise_refuses_without_the_record
test_raise_writes_the_marker_and_holds_the_record
test_marker_stands_when_the_hold_cannot_be_written
