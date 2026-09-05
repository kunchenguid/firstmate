#!/usr/bin/env bash
# Behavior tests for bin/fm-ticket-board.sh: fail-closed store validation,
# slot-injection round-trip through the built page, serve-then-arm ordering
# with no captain-hold binding, idempotent re-arm, init, and set-status.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BOARD="$ROOT/bin/fm-ticket-board.sh"
TMP_ROOT=$(fm_test_tmproot fm-ticket-board)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/state" "$home/data"
  fakebin=$(fm_fakebin "$home")
  fake_lavish_axi_opened "$fakebin"
  printf '%s\n' "$home"
}

# A realistic-enough stub of `lavish-axi <artifact> [--reopen]` for the happy
# path: any invocation reports a live, opened session, matching the exact
# `session:` block shape a real open/reopen prints (verified live against
# lavish-axi 0.1.x). Tests that need the "captain ended this session" path
# install their own narrower stub instead - see
# test_build_reopens_a_session_the_captain_ended below.
fake_lavish_axi_opened() {  # <fakebin>
  cat > "$1/lavish-axi" <<'SH'
#!/usr/bin/env bash
printf 'session:\n  file: %s\n  status: opened\n' "$1"
SH
  chmod +x "$1/lavish-axi"
}

run_board() {  # <home> <args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$BOARD" "$@"
}

run_procevent() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$ROOT/bin/fm-procevent.sh" "$@"
}

run_lavish_source_id() {  # <home> <artifact>
  local home=$1
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$ROOT/bin/fm-procevent-lavish.sh" source-id "$2"
}

write_valid_store() {  # <path>
  cat > "$1" <<'EOF'
{
  "schema": "fm-ticket-board.v1",
  "generated": "2026-08-19T00:00Z",
  "tickets": [
    {
      "id": "tkt-sample-one",
      "title": "A sample ticket that tries to break out: </script><b>x</b>",
      "status": "backlog",
      "created": "2026-08-19T00:00Z",
      "body": "full body text"
    },
    {
      "id": "tkt-sample-two",
      "title": "In progress ticket",
      "status": "in_progress",
      "created": "2026-08-19T00:05Z"
    }
  ]
}
EOF
}

extract_payload() {  # <board-path>
  sed -n '/<script id="ticket-board-data" type="application\/json">/,/<\/script>/p' "$1" \
    | sed '1d;$d'
}

test_path_and_store_are_stable_and_home_scoped() {
  local home
  home=$(make_home path)
  [ "$(run_board "$home" path)" = "$home/.lavish/ticket-board.html" ] \
    || fail "the board path is not the stable home-scoped location"
  [ "$(run_board "$home" store)" = "$home/data/tickets.json" ] \
    || fail "the store path is not the stable home-scoped location"
  pass "path and store print the stable home-scoped locations"
}

test_init_creates_an_empty_store_and_is_idempotent() {
  local home store out
  home=$(make_home init)
  store="$home/data/tickets.json"
  out=$(run_board "$home" init) || fail "init failed on an absent store"
  assert_contains "$out" "created: $store" "init did not report creation: $out"
  jq -e '.schema == "fm-ticket-board.v1" and .tickets == []' "$store" >/dev/null \
    || fail "init did not write a valid empty store"

  echo '{"schema":"fm-ticket-board.v1","generated":"x","tickets":[{"id":"a"}]}' > "$store"
  out=$(run_board "$home" init) || fail "init failed on an existing store"
  assert_contains "$out" "exists: $store" "init clobbered an existing store: $out"
  grep -q '"id":"a"' "$store" || fail "init overwrote an existing store"
  pass "init creates an empty store once and never clobbers an existing one"
}

test_build_refuses_a_missing_or_malformed_store() {
  local home data rc out
  home=$(make_home refusal)
  data="$home/payload.json"

  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a missing store was accepted"
  assert_contains "$out" "does not exist" "the missing-store refusal did not say why: $out"

  printf 'not json\n' > "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a non-JSON store was accepted"
  assert_contains "$out" "not valid JSON" "the non-JSON refusal did not say why: $out"

  printf '{"schema":"fm-ticket-board.v2","generated":"x","tickets":[]}\n' > "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a wrong-schema store was accepted"
  assert_contains "$out" "fm-ticket-board.v1" "the schema refusal did not name the contract: $out"

  write_valid_store "$data"
  jq '.tickets[0].status = "someday"' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "an unknown ticket status was accepted"

  write_valid_store "$data"
  jq 'del(.tickets[0].title)' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a ticket without a title was accepted"

  write_valid_store "$data"
  jq '.tickets[0].id = .tickets[1].id' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "duplicate ticket ids were accepted"

  write_valid_store "$data"
  jq '.tickets[0].id = "not a slug!"' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "a non-slug ticket id was accepted"

  assert_absent "$home/.lavish/ticket-board.html" "a refused store still produced a board"
  pass "build refuses a missing or malformed store before touching the board"
}

test_build_serves_then_arms_with_no_captain_hold_binding() {
  local home data board out sid
  home=$(make_home build)
  data="$home/payload.json"
  board="$home/.lavish/ticket-board.html"
  write_valid_store "$data"

  out=$(run_board "$home" build "$data") || fail "a valid store did not build"
  assert_contains "$out" "board: $board" "build did not report the board path: $out"
  assert_contains "$out" "served: $board" "build did not establish the Lavish session: $out"
  assert_contains "$out" "armed: " "the first build did not arm the board source: $out"
  assert_not_contains "$out" "bound: " "the ticket board wrongly bound a captain-hold answer source: $out"
  assert_present "$board" "build reported success without a board"

  extract_payload "$board" | jq -S . > "$home/extracted.json" \
    || fail "the built board does not carry parseable payload JSON"
  jq -S . "$data" > "$home/expected.json"
  diff -u "$home/expected.json" "$home/extracted.json" >/dev/null \
    || fail "the injected payload does not round-trip to the input document"
  grep -qF '</script><b>' "$board" \
    && fail "a ticket title embedded a live closing script tag in the page"
  grep -qxF '__FM_TICKET_BOARD_DATA__' "$board" \
    && fail "the data slot survived injection"

  sid=$(run_lavish_source_id "$home" "$board")
  assert_contains "$out" "armed: $sid" "the arm confirmation does not name the board source: $out"
  run_procevent "$home" list | awk 'NR > 1 { print $1 }' | grep -Fxq "$sid" \
    || fail "the board source is not registered after build"
  pass "build serves the board then arms its source with no captain-hold binding"
}

test_build_does_not_arm_when_session_start_fails() {
  local home data rc sid
  home=$(make_home serve-failure)
  data="$home/payload.json"
  write_valid_store "$data"
  cat > "$home/fakebin/lavish-axi" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$home/fakebin/lavish-axi"

  set +e
  run_board "$home" build "$data" >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "build continued after Lavish session establishment failed"
  sid=$(run_lavish_source_id "$home" "$home/.lavish/ticket-board.html")
  ! run_procevent "$home" list | awk 'NR > 1 { print $1 }' | grep -Fxq "$sid" \
    || fail "build armed the board before its Lavish session existed"
  pass "build establishes the Lavish session before arming"
}

test_build_reopens_a_session_the_captain_ended() {
  local home data board out
  home=$(make_home reopen)
  data="$home/payload.json"
  board="$home/.lavish/ticket-board.html"
  write_valid_store "$data"
  # Verified live: `lavish-axi <board>` exits 0 and reports status "user-ended"
  # without reopening when the captain ended the session from the browser,
  # and only `--reopen` re-establishes a live one.
  cat > "$home/fakebin/lavish-axi" <<'SH'
#!/usr/bin/env bash
if [ "${2-}" = "--reopen" ]; then
  printf 'session:\n  file: %s\n  status: opened\n' "$1"
else
  printf 'session:\n  file: %s\n  status: user-ended\n' "$1"
fi
SH
  chmod +x "$home/fakebin/lavish-axi"

  out=$(run_board "$home" build "$data") || fail "build did not recover a captain-ended session"
  assert_contains "$out" "status: opened" "build did not report the reopened session as opened: $out"
  assert_contains "$out" "served: $board" "build did not claim served after reopening: $out"
  assert_contains "$out" "armed: " "build did not (re-)arm the source after reopening: $out"
  pass "build reopens a session the captain ended instead of falsely claiming served"
}

test_build_fails_loudly_when_reopen_cannot_establish_a_live_session() {
  local home data rc out
  home=$(make_home reopen-fails)
  data="$home/payload.json"
  write_valid_store "$data"
  cat > "$home/fakebin/lavish-axi" <<'SH'
#!/usr/bin/env bash
printf 'session:\n  file: %s\n  status: user-ended\n' "$1"
SH
  chmod +x "$home/fakebin/lavish-axi"

  set +e; out=$(run_board "$home" build "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "build claimed success even though --reopen never reported an open session"
  assert_contains "$out" "did not report an open" "the failure did not explain why: $out"
  assert_not_contains "$out" "served: " "build must never print served: against a dead session"
  pass "build fails loudly instead of claiming served when --reopen still cannot establish a live session"
}

test_rebuild_is_idempotent_and_does_not_double_arm() {
  local home data board out records
  home=$(make_home rearm)
  data="$home/payload.json"
  board="$home/.lavish/ticket-board.html"
  write_valid_store "$data"
  run_board "$home" build "$data" >/dev/null || fail "the first build failed"

  jq '.generated = "2026-08-19T01:00Z"' "$data" > "$data.tmp" && mv "$data.tmp" "$data"
  out=$(run_board "$home" build "$data") || fail "the rebuild failed"
  assert_contains "$out" "already-armed: " "the rebuild re-armed an already registered source: $out"
  extract_payload "$board" | jq -e '.generated == "2026-08-19T01:00Z"' >/dev/null \
    || fail "the rebuild did not refresh the board payload in place"
  records=$(find "$home/state/procevent" -name '*.source' | wc -l | tr -d ' ')
  [ "$records" = 1 ] || fail "rebuilding left $records source registrations instead of 1"
  pass "rebuild refreshes the board in place without double-arming"
}

test_build_refuses_a_template_without_exactly_one_slot() {
  local home data rc out
  home=$(make_home badslot)
  data="$home/payload.json"
  write_valid_store "$data"
  printf '<html><body>no slot</body></html>\n' > "$home/broken-template.html"
  set +e
  out=$(FM_TICKET_BOARD_TEMPLATE="$home/broken-template.html" run_board "$home" build "$data" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a template with no data slot was accepted"
  assert_contains "$out" "data slot" "the slot refusal did not say why: $out"
  assert_absent "$home/.lavish/ticket-board.html" "a refused template still produced a board"
  pass "build refuses a template without exactly one data slot"
}

test_set_status_updates_and_rebuilds() {
  local home data out
  home=$(make_home set-status)
  data="$home/payload.json"
  write_valid_store "$data"
  run_board "$home" build "$data" >/dev/null || fail "the initial build failed"

  out=$(run_board "$home" set-status tkt-sample-one "done" "$data") \
    || fail "set-status refused a known ticket and a known status"
  assert_contains "$out" "updated: tkt-sample-one -> done" "set-status did not report the change: $out"
  assert_contains "$out" "board: " "set-status did not rebuild the board: $out"
  jq -e '.tickets[] | select(.id == "tkt-sample-one") | .status == "done"' "$data" >/dev/null \
    || fail "set-status did not persist the new status in the store"
  extract_payload "$home/.lavish/ticket-board.html" \
    | jq -e '.tickets[] | select(.id == "tkt-sample-one") | .status == "done"' >/dev/null \
    || fail "set-status did not rebuild the board with the new status"

  set +e; out=$(run_board "$home" set-status tkt-sample-one someday "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "set-status accepted an unknown status"

  set +e; out=$(run_board "$home" set-status tkt-does-not-exist "done" "$data" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "set-status accepted an unknown ticket id"
  pass "set-status updates one ticket's status in place and rebuilds"
}

test_path_and_store_are_stable_and_home_scoped
test_init_creates_an_empty_store_and_is_idempotent
test_build_refuses_a_missing_or_malformed_store
test_build_serves_then_arms_with_no_captain_hold_binding
test_build_does_not_arm_when_session_start_fails
test_build_reopens_a_session_the_captain_ended
test_build_fails_loudly_when_reopen_cannot_establish_a_live_session
test_rebuild_is_idempotent_and_does_not_double_arm
test_build_refuses_a_template_without_exactly_one_slot
test_set_status_updates_and_rebuilds
