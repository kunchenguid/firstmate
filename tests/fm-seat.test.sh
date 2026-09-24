#!/usr/bin/env bash
# Behavior tests for Claude seat switching: bin/fm-seat.sh and the seat half of
# bin/fm-spawn.sh.
#
# Every test here runs with no real Claude account and no network. The login
# probe and the quota read both shell out to `quota-axi`, so a fake quota-axi on
# PATH supplies the report each case needs; the scripts under test are driven
# through their real interfaces and never inspected as source.
#
# The property these tests exist to protect is that a switch changes only what
# the NEXT worker gets: a running task keeps the profile recorded in its own
# task record. The other half of that property - that a RELAUNCH reads the
# record rather than the home's current setting - is covered in
# tests/fm-control-relaunch.test.sh, which owns the fake backend that can prove
# a prior agent is gone and so is the only place a relaunch actually launches.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SEAT="$ROOT/bin/fm-seat.sh"
TMP_ROOT=$(fm_test_tmproot fm-seat)

# make_quota_fake <fakebin> <spec>
# A fake quota-axi whose verdict per profile directory is driven by files the
# test writes. <spec> is a directory holding one file per state:
#   <spec>/oauth        newline-separated CLAUDE_CONFIG_DIR values that are logged in
#   <spec>/rate_limited newline-separated CLAUDE_CONFIG_DIR values that are signed
#                       in but whose quota endpoint is rate limiting them
#   <spec>/remaining    percent remaining reported for a logged-in profile's
#                       account-level (all_models) window
#   <spec>/availability optional JSON array replacing the whole
#                       effectiveAvailability list, for scope-specific cases
#   <spec>/remaining_map  optional "<CLAUDE_CONFIG_DIR><TAB><percent>" rows,
#                       giving a profile its OWN percent remaining so a case can
#                       drive candidate seats apart; a profile with no row falls
#                       back to <spec>/remaining
#   <spec>/unreadable_quota  newline-separated CLAUDE_CONFIG_DIR values that are
#                       logged in but whose account-level availability cannot be
#                       read, which must never be guessed at as headroom
#   <spec>/extra_map    optional "<CLAUDE_CONFIG_DIR><TAB><spentUsd>" rows adding
#                       an extra_usage window (kind credits) to that profile's
#                       report, which is where paid overflow spend is observed
#   <spec>/slow         optional seconds every read sleeps before answering, for
#                       a quota endpoint slower than the watcher's budget
# An empty CLAUDE_CONFIG_DIR is spelled "(default)" in the oauth list.
# The fake reproduces the real tool's contract that matters here: an unavailable
# provider still prints a valid report AND exits non-zero.
make_quota_fake() {
  local fakebin=$1 spec=$2
  mkdir -p "$spec"
  cat > "$fakebin/quota-axi" <<SH
#!/usr/bin/env bash
set -u
spec="$spec"
key="\${CLAUDE_CONFIG_DIR:-}"
[ -n "\$key" ] || key='(default)'
[ ! -f "\$spec/slow" ] || sleep "\$(cat "\$spec/slow")"
remaining=\$(cat "\$spec/remaining" 2>/dev/null || printf '80')
if [ -f "\$spec/remaining_map" ]; then
  mapped=\$(awk -F'\t' -v k="\$key" '\$1==k{print \$2; exit}' "\$spec/remaining_map")
  [ -z "\$mapped" ] || remaining=\$mapped
fi
availability=\$(cat "\$spec/availability" 2>/dev/null ||
  printf '[{"scope":"all_models","status":"known","effectivePercentRemaining":%s,"runway":{"status":"through_reset"}}]' "\$remaining")
if [ -f "\$spec/unreadable_quota" ] && grep -Fxq "\$key" "\$spec/unreadable_quota"; then
  availability='[]'
fi
windows='[]'
if [ -f "\$spec/extra_map" ]; then
  spent=\$(awk -F'\t' -v k="\$key" '\$1==k{print \$2; exit}' "\$spec/extra_map")
  [ -z "\$spent" ] ||
    windows=\$(printf '[{"id":"extra_usage","kind":"credits","percentUsed":1,"spentUsd":%s,"limitUsd":10000}]' "\$spent")
fi
if [ -f "\$spec/rate_limited" ] && grep -Fxq "\$key" "\$spec/rate_limited"; then
  cat <<'JSON'
{"generatedAt":"2026-01-01T00:00:00Z","schemaVersion":5,"providers":[{"provider":"claude","label":"Claude","source":"unavailable","windows":[],"state":{"status":"rate_limited","error":"Claude quota endpoint rate limited"},"attempts":[{"source":"oauth-file","status":"skipped","error":"credentials_missing"},{"source":"keychain","status":"failed","error":"Claude quota endpoint rate limited"}],"quotaSemantics":{"status":"unknown","effectiveAvailability":[]}}]}
JSON
  exit 1
fi
if [ -f "\$spec/oauth" ] && grep -Fxq "\$key" "\$spec/oauth"; then
  semantics_status=known
  [ "\$availability" != '[]' ] || semantics_status=unknown
  cat <<JSON
{"generatedAt":"2026-01-01T00:00:00Z","schemaVersion":5,"providers":[{"provider":"claude","label":"Claude","source":"oauth","account":{"email":"seat-\$(printf '%s' "\$key" | tr -c 'a-zA-Z0-9' '-')@example.test"},"windows":\$windows,"quotaSemantics":{"status":"\$semantics_status","effectiveAvailability":\$availability}}]}
JSON
  exit 0
fi
if [ -f "\$spec/proven_empty" ] && grep -Fxq "\$key" "\$spec/proven_empty"; then
  # A file-backed credential store that was actually read and found empty: the
  # only shape that establishes absence. No keychain attempt is reported.
  cat <<'JSON'
{"generatedAt":"2026-01-01T00:00:00Z","schemaVersion":5,"providers":[{"provider":"claude","label":"Claude","source":"unavailable","windows":[],"state":{"status":"error","error":"credentials_missing"},"attempts":[{"source":"oauth-file","status":"skipped","error":"credentials_missing"}],"quotaSemantics":{"status":"unknown","effectiveAvailability":[]}}]}
JSON
  exit 1
fi
# Default: the store could not be READ. On macOS this is what both a
# never-logged-in profile and a signed-in-but-unapproved one report, so it
# establishes nothing and must read as undecided.
cat <<'JSON'
{"generatedAt":"2026-01-01T00:00:00Z","schemaVersion":5,"providers":[{"provider":"claude","label":"Claude","source":"unavailable","windows":[],"state":{"status":"error","error":"keychain_unreachable"},"attempts":[{"source":"oauth-file","status":"skipped","error":"credentials_missing"},{"source":"keychain","status":"skipped","error":"keychain_unreachable"}],"quotaSemantics":{"status":"unknown","effectiveAvailability":[]}}]}
JSON
exit 1
SH
  chmod +x "$fakebin/quota-axi"
}

# make_seat_case <name>
# A home with a seats root of its own plus a fake quota-axi. Echoes a record.
make_seat_case() {
  local name=$1 case_dir home seats fakebin spec
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  seats="$case_dir/seats"
  spec="$case_dir/quota-spec"
  mkdir -p "$home/config" "$home/state" "$home/data" "$seats"
  fakebin=$(fm_fakebin "$case_dir/fake")
  make_quota_fake "$fakebin" "$spec"
  printf '%s\n' "$seats" > "$home/config/claude-seats-root"
  printf '%s\n' "$case_dir|$home|$seats|$fakebin|$spec"
}

read_seat_case() {
  IFS='|' read -r CASE_DIR HOME_DIR SEATS_DIR FAKEBIN SPEC_DIR <<EOF
$1
EOF
}

# run_seat <home> <fakebin> [args...]
# firstmate's own CLAUDE_CONFIG_DIR is pinned empty unless a test opts in
# through SEAT_TEST_AMBIENT_CONFIG_DIR.
run_seat() {
  local home=$1 fakebin=$2
  shift 2
  FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" CLAUDE_CONFIG_DIR="${SEAT_TEST_AMBIENT_CONFIG_DIR:-}" \
    PATH="$fakebin:$PATH" "$SEAT" "$@" 2>&1
}

# seat_logged_in <spec> <value...>
# Declare which profiles the fake reports as logged in.
seat_logged_in() {
  local spec=$1
  shift
  printf '%s\n' "$@" > "$spec/oauth"
}

# seat_proven_empty <spec> <value...>
# Declare which profiles the fake reports as PROVEN to hold no login, as a
# file-backed store that was read and found empty does. Any profile not listed
# here and not logged in falls through to the unreadable-store shape, which
# establishes nothing.
seat_proven_empty() {
  local spec=$1
  shift
  printf '%s\n' "$@" > "$spec/proven_empty"
}

test_absent_setting_is_the_default_seat() {
  local rec out
  rec=$(make_seat_case absent-default)
  read_seat_case "$rec"
  seat_logged_in "$SPEC_DIR" '(default)'

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" status)
  assert_contains "$out" "active seat for NEW workers: default" \
    "an absent config/claude-seat must resolve to the default seat"
  assert_contains "$out" "active profile: (ambient default login)" \
    "the default seat must name no profile directory"
  assert_contains "$out" "auto-switch trigger: (unset" \
    "no switch trigger may be configured by default"
  assert_contains "$out" "destination minimum: (unset" \
    "no destination minimum may be configured by default"
  assert_contains "$out" "extra-usage policy: (unset" \
    "no extra-usage policy may be configured by default"
  assert_absent "$HOME_DIR/config/claude-seat" \
    "reading status must not create the seat setting"
  pass "an unset seat setting is the ambient default and configures no automatic switching"
}

test_switch_to_logged_in_seat_updates_only_the_setting() {
  local rec out
  rec=$(make_seat_case switch-ok)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/work"
  seat_logged_in "$SPEC_DIR" '(default)' "$SEATS_DIR/work"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" switch work)
  expect_code 0 "$?" "switching to a logged-in seat should succeed"
  assert_contains "$out" "switched: default -> work" "switch must report the transition"
  assert_grep "work" "$HOME_DIR/config/claude-seat" "the active seat must be recorded"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" status)
  assert_contains "$out" "active seat for NEW workers: work" "status must read back the new seat"
  assert_contains "$out" "active profile: $SEATS_DIR/work" "status must name the seat's profile directory"
  pass "a switch to a logged-in seat records the seat and nothing else"
}

test_switch_to_seat_that_is_not_logged_in_is_refused() {
  local rec out status
  rec=$(make_seat_case switch-refuse)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/spare"
  seat_logged_in "$SPEC_DIR" '(default)'
  # Proven empty, not merely unreadable: only that establishes absence.
  seat_proven_empty "$SPEC_DIR" "$SEATS_DIR/spare"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" switch spare)
  status=$?
  expect_code 1 "$status" "switching to a seat with no credentials must refuse"
  assert_contains "$out" "not logged in" "the refusal must say the seat is not logged in"
  assert_absent "$HOME_DIR/config/claude-seat" \
    "a refused switch must leave the active seat untouched"
  pass "a switch to a profile that is not logged in is refused and changes nothing"
}

test_forced_switch_cannot_override_a_proven_negative() {
  local rec out status
  rec=$(make_seat_case switch-force)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/spare"
  seat_logged_in "$SPEC_DIR" '(default)'
  seat_proven_empty "$SPEC_DIR" "$SEATS_DIR/spare"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" switch spare --force)
  status=$?
  expect_code 1 "$status" "--force must not override a profile proven to have no credentials"
  assert_contains "$out" "not logged in" "the forced refusal must still name the cause"
  assert_absent "$HOME_DIR/config/claude-seat" "a refused forced switch must change nothing"
  pass "--force does not override a seat proven to be logged out"
}

test_rate_limited_seat_is_undecided_and_forceable() {
  local rec out status
  rec=$(make_seat_case switch-rate-limited)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/busy"
  seat_logged_in "$SPEC_DIR" '(default)'
  printf '%s\n' "$SEATS_DIR/busy" > "$SPEC_DIR/rate_limited"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" probe busy)
  status=$?
  expect_code 2 "$status" "a rate-limited signed-in seat must probe as undecided, not logged out"
  assert_not_contains "$out" "not-logged-in" "a rate limit must not be reported as a missing login"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" switch busy)
  expect_code 1 "$?" "an unforced switch onto an undecided seat must still refuse"
  assert_contains "$out" "--force" "the refusal must point at --force"
  assert_absent "$HOME_DIR/config/claude-seat" "a refused switch must change nothing"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" switch busy --force)
  expect_code 0 "$?" "--force must switch onto a seat whose quota read was rate limited"
  assert_grep "busy" "$HOME_DIR/config/claude-seat" "the forced switch must record the seat"
  pass "a rate-limited signed-in seat is undecided, and --force switches onto it"
}

test_unreadable_store_is_undecided_and_force_may_cross_it() {
  local rec out status
  rec=$(make_seat_case unreadable-store)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/pending"
  seat_logged_in "$SPEC_DIR" '(default)'
  # 'pending' is neither logged in nor proven empty, so the fake returns the
  # unreadable-store shape. On macOS that is what BOTH a never-logged-in seat
  # and a signed-in seat still awaiting its one-time Keychain approval report,
  # so it must establish nothing.

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" probe pending)
  status=$?
  expect_code 2 "$status" "an unreadable credential store must probe as undecided, not as logged out"
  assert_contains "$out" "unknown" "the probe must report the seat as unknown"

  # A plain switch still refuses, because nothing confirmed the seat is usable.
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" switch pending)
  expect_code 1 "$?" "a plain switch must refuse a seat that could not be confirmed"
  assert_absent "$HOME_DIR/config/claude-seat" "a refused switch must change nothing"

  # --force is the owner accepting that uncertainty, and must get through. A
  # forced switch to a seat that turns out to be empty fails safely on the
  # worker's first message rather than spending another account.
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" switch pending --force)
  expect_code 0 "$?" "--force must cross an undecided probe: $out"
  assert_contains "$out" "-> pending" "the forced switch must take effect"
  assert_grep "pending" "$HOME_DIR/config/claude-seat" "the forced switch must record the seat"
  pass "an unreadable credential store reads as undecided and --force may cross it"
}

test_forced_switch_refuses_a_seat_with_no_profile_directory() {
  local rec out
  rec=$(make_seat_case missing-seat-dir)
  read_seat_case "$rec"
  seat_logged_in "$SPEC_DIR" '(default)'
  # No directory named 'nosuch' exists under the seats root: a typo. A missing
  # profile probes as undecided, so without its own check --force would cross
  # it and send every new worker to a profile that was never set up.
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" switch nosuch --force)
  expect_code 1 "$?" "a forced switch must refuse a seat with no profile directory: $out"
  assert_contains "$out" "fm-seat.sh add nosuch" "the refusal must point at how to create the seat"
  assert_absent "$HOME_DIR/config/claude-seat" "a refused switch must change nothing"
  pass "a forced switch refuses a seat whose profile directory does not exist"
}

test_switch_back_to_default_clears_the_setting() {
  local rec out
  rec=$(make_seat_case switch-back)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/work"
  seat_logged_in "$SPEC_DIR" '(default)' "$SEATS_DIR/work"

  run_seat "$HOME_DIR" "$FAKEBIN" switch work >/dev/null
  assert_present "$HOME_DIR/config/claude-seat" "precondition: the seat setting exists"
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" switch default)
  expect_code 0 "$?" "switching back to the default seat should succeed"
  assert_contains "$out" "switched: work -> default" "switch must report the return"
  assert_absent "$HOME_DIR/config/claude-seat" \
    "returning to the default seat must clear the setting, not record a name"
  pass "switching to the default seat clears the setting and restores ambient behaviour"
}

# add_local_secondmate <home> <fakebin> <id> -> echoes a seeded local secondmate
# home the primary <home> records as live. A fake tmux on <fakebin> absorbs the
# config reread nudge so it can never reach a real tmux server.
add_local_secondmate() {
  local home=$1 fakebin=$2 id=$3 sm
  fm_fake_exit0 "$fakebin" tmux
  sm="$(dirname "$home")/sm-$id"
  mkdir -p "$sm/config" "$sm/data" "$sm/state" "$sm/bin"
  printf '%s\n' "$id" > "$sm/.fm-secondmate-home"
  printf 'instructions\n' > "$sm/AGENTS.md"
  {
    printf 'window=firstmate:fm-%s\n' "$id"
    printf 'kind=secondmate\n'
    printf 'home=%s\n' "$sm"
  } > "$home/state/$id.meta"
  printf '%s\n' "$sm"
}

test_switch_reaches_running_local_secondmate_homes() {
  local rec out sm
  rec=$(make_seat_case switch-secondmate)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/work"
  seat_logged_in "$SPEC_DIR" '(default)' "$SEATS_DIR/work"
  sm=$(add_local_secondmate "$HOME_DIR" "$FAKEBIN" smseat)

  out=$(TMUX='' run_seat "$HOME_DIR" "$FAKEBIN" switch work)
  assert_contains "$out" "switched: default -> work" "the primary switch must be reported"
  [ "$(cat "$sm/config/claude-seat" 2>/dev/null)" = work ] \
    || fail "a switch must carry the new seat to a running local secondmate home: $out"
  assert_contains "$out" "secondmate smseat ($sm)" "the switch must name each secondmate home it reached"
  assert_contains "$out" "claude-seat: pushed" "the switch must report the home as updated"

  out=$(TMUX='' run_seat "$HOME_DIR" "$FAKEBIN" switch default)
  assert_absent "$sm/config/claude-seat" "returning to the default seat must clear it in the secondmate home too"
  pass "a seat switch reaches running local secondmate homes and reports each one"
}

test_failed_secondmate_push_does_not_undo_the_switch() {
  local rec out sm
  if [ "$(id -u)" = 0 ]; then
    printf '# skip - an unwritable secondmate config requires a non-root user\n'
    return
  fi
  rec=$(make_seat_case switch-secondmate-fail)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/work"
  seat_logged_in "$SPEC_DIR" '(default)' "$SEATS_DIR/work"
  sm=$(add_local_secondmate "$HOME_DIR" "$FAKEBIN" smfail)
  chmod 500 "$sm/config"

  out=$(TMUX='' run_seat "$HOME_DIR" "$FAKEBIN" switch work)
  expect_code 0 "$?" "a failed secondmate push must not fail the primary switch: $out"
  chmod 700 "$sm/config"
  assert_grep "work" "$HOME_DIR/config/claude-seat" "the primary switch must stand when a secondmate push fails"
  assert_absent "$sm/config/claude-seat" "precondition: the secondmate home was not updated"
  assert_contains "$out" "not every secondmate home was updated" "a failed push must be reported plainly"
  pass "a failed secondmate push is reported and never undoes the primary switch"
}

# decline_inherited_seats <secondmate-home> [content]
# The declining home's own opt-out flag. Presence is the whole setting, so the
# default case writes an empty file exactly as an operator's `touch` would.
decline_inherited_seats() {
  local sm=$1
  mkdir -p "$sm/config"
  printf '%s' "${2-}" > "$sm/config/claude-seat-local"
}

test_a_declining_home_keeps_its_own_seat_through_a_switch() {
  local rec out sm
  rec=$(make_seat_case switch-decline)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/work"
  seat_logged_in "$SPEC_DIR" '(default)' "$SEATS_DIR/work"
  sm=$(add_local_secondmate "$HOME_DIR" "$FAKEBIN" smdecline)
  decline_inherited_seats "$sm"
  printf 'personal\n' > "$sm/config/claude-seat"
  printf '%s\n' "$CASE_DIR/own-seats" > "$sm/config/claude-seats-root"
  printf '40\n' > "$sm/config/claude-seat-threshold"

  out=$(TMUX='' run_seat "$HOME_DIR" "$FAKEBIN" switch work)
  expect_code 0 "$?" "a switch must succeed with a declining home on the machine: $out"
  assert_grep "work" "$HOME_DIR/config/claude-seat" "the primary switch must still land"
  [ "$(cat "$sm/config/claude-seat" 2>/dev/null)" = personal ] \
    || fail "a declining home must keep its own seat through a switch (got '$(cat "$sm/config/claude-seat" 2>/dev/null)')"
  [ "$(cat "$sm/config/claude-seats-root" 2>/dev/null)" = "$CASE_DIR/own-seats" ] \
    || fail "a declining home must keep its own seats root"
  [ "$(cat "$sm/config/claude-seat-threshold" 2>/dev/null)" = 40 ] \
    || fail "a declining home must keep its own auto-switch threshold"
  assert_contains "$out" "claude-seat: skipped - home declines inherited seat settings" \
    "the switch must say which seat item it skipped and why"
  assert_contains "$out" "secondmate smdecline ($sm)" "the skip must be attributed to the home it belongs to"

  # A home that declines while holding NO seat of its own keeps holding none:
  # the primary's value is not pushed in as a "missing" default either.
  rm -f "$sm/config/claude-seat"
  out=$(TMUX='' run_seat "$HOME_DIR" "$FAKEBIN" switch default)
  expect_code 0 "$?" "the second switch must succeed: $out"
  assert_absent "$sm/config/claude-seat" \
    "a declining home with no seat of its own must still be left alone"

  # The decline takes nothing away from the home itself: it runs its own switch
  # against its own seats root, and that switch reaches no other home.
  mkdir -p "$CASE_DIR/own-seats/client"
  seat_logged_in "$SPEC_DIR" '(default)' "$SEATS_DIR/work" "$CASE_DIR/own-seats/client"
  out=$(TMUX='' run_seat "$sm" "$FAKEBIN" switch client)
  expect_code 0 "$?" "a declining home must still run its own switch: $out"
  [ "$(cat "$sm/config/claude-seat" 2>/dev/null)" = client ] \
    || fail "a declining home's own switch must record its own seat: $out"
  assert_absent "$HOME_DIR/config/claude-seat" \
    "a declining home's own switch must not reach back into the primary"
  pass "a local home that declines keeps its own three seat settings through a switch"
}

test_a_switch_still_reaches_every_home_that_did_not_decline() {
  local rec out declining taking
  rec=$(make_seat_case switch-mixed)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/work"
  seat_logged_in "$SPEC_DIR" '(default)' "$SEATS_DIR/work"
  declining=$(add_local_secondmate "$HOME_DIR" "$FAKEBIN" smoptout)
  taking=$(add_local_secondmate "$HOME_DIR" "$FAKEBIN" smfleet)
  # Presence alone is the setting, so text an operator might expect to turn it
  # back off does not: a file saying "off" still declines.
  decline_inherited_seats "$declining" 'off
'
  printf 'personal\n' > "$declining/config/claude-seat"

  out=$(TMUX='' run_seat "$HOME_DIR" "$FAKEBIN" switch work)
  expect_code 0 "$?" "the switch should succeed: $out"
  [ "$(cat "$taking/config/claude-seat" 2>/dev/null)" = work ] \
    || fail "one home's decline must not hold back any other local home: $out"
  [ "$(cat "$declining/config/claude-seat" 2>/dev/null)" = personal ] \
    || fail "the declining home must be the only one left alone, whatever its flag file says"
  pass "one home's decline leaves every other local home taking the switch"
}

test_status_names_every_local_home_that_declined() {
  local rec out declining taking
  rec=$(make_seat_case status-decline)
  read_seat_case "$rec"
  seat_logged_in "$SPEC_DIR" '(default)'

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" status)
  assert_contains "$out" "local secondmate homes declining inherited seats:" \
    "status must always carry the declining-homes section"
  assert_contains "$out" "(none - every local home takes this seat)" \
    "with no decline anywhere status must say so plainly"

  declining=$(add_local_secondmate "$HOME_DIR" "$FAKEBIN" smshown)
  taking=$(add_local_secondmate "$HOME_DIR" "$FAKEBIN" smhidden)
  decline_inherited_seats "$declining"
  printf 'personal\n' > "$declining/config/claude-seat"
  printf 'work\n' > "$taking/config/claude-seat"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" status |
    sed -n '/^local secondmate homes declining inherited seats:$/,$p')
  assert_contains "$out" "smshown	personal	$declining" \
    "status must name each declining home with the seat it is actually on"
  assert_not_contains "$out" "smhidden" \
    "the declining section must not list a home that takes the fleet's seat"
  pass "status names every local home that declined and the seat it is really on"
}

test_a_non_file_decline_flag_still_declines() {
  local rec out sm_dir sm_link kind
  rec=$(make_seat_case decline-non-file)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/work"
  seat_logged_in "$SPEC_DIR" '(default)' "$SEATS_DIR/work"
  sm_dir=$(add_local_secondmate "$HOME_DIR" "$FAKEBIN" smdirflag)
  sm_link=$(add_local_secondmate "$HOME_DIR" "$FAKEBIN" smlinkflag)
  mkdir -p "$sm_dir/config/claude-seat-local"
  mkdir -p "$sm_link/config"
  ln -s "$CASE_DIR/nowhere" "$sm_link/config/claude-seat-local"
  printf 'personal\n' > "$sm_link/config/claude-seat"

  out=$(TMUX='' run_seat "$HOME_DIR" "$FAKEBIN" switch work 2>&1)
  expect_code 0 "$?" "a switch must succeed with non-file decline flags on the machine: $out"
  assert_grep "work" "$HOME_DIR/config/claude-seat" "the primary switch must still stand"
  assert_absent "$sm_dir/config/claude-seat" \
    "a directory flag must decline, not let the seat through"
  [ "$(cat "$sm_link/config/claude-seat" 2>/dev/null)" = personal ] \
    || fail "a dangling symlink flag must decline and keep the home's own seat"
  assert_not_contains "$out" "not every secondmate home was updated" \
    "a non-file decline flag is a decline, not a push failure"
  for kind in smdirflag smlinkflag; do
    assert_contains "$out" "secondmate $kind" "the switch must report the declining home $kind"
  done
  assert_contains "$out" "claude-seat: skipped - home declines inherited seat settings" \
    "a non-file flag must be reported as a decline"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" status)
  assert_contains "$out" "smdirflag	default	$sm_dir" \
    "status must list a directory-flag home as declined"
  assert_contains "$out" "smlinkflag	personal	$sm_link" \
    "status must list a dangling-symlink-flag home as declined"
  pass "a decline flag of any type declines and shows in status"
}

# add_unreachable_remote_secondmate <home> <fakebin> <id> -> echoes the path of
# a log that records every SSH attempt to the remote route, which always fails.
add_unreachable_remote_secondmate() {
  local home=$1 fakebin=$2 id=$3 log
  log="$(dirname "$home")/ssh-$id.log"
  : > "$log"
  cat > "$fakebin/unreachable-ssh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$log"
exit 255
SH
  chmod +x "$fakebin/unreachable-ssh"
  {
    printf 'window=firstmate:fm-%s\n' "$id"
    printf 'kind=secondmate\n'
    printf 'home=/remote/home-%s\n' "$id"
    printf 'remote_host=down-host\n'
  } > "$home/state/$id.meta"
  printf -- '- %s - Remote route (host: down-host; root: /remote/root; home: /remote/home-%s; scope: test; projects: ; added 2026-09-23)\n' \
    "$id" "$id" >> "$home/data/secondmates.md"
  printf '%s\n' "$log"
}

test_switch_never_contacts_remote_routes() {
  local rec out sm log
  rec=$(make_seat_case switch-remote-down)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/work"
  seat_logged_in "$SPEC_DIR" '(default)' "$SEATS_DIR/work"
  sm=$(add_local_secondmate "$HOME_DIR" "$FAKEBIN" smlocal)
  log=$(add_unreachable_remote_secondmate "$HOME_DIR" "$FAKEBIN" smremote)

  out=$(TMUX='' FM_SSH_BIN="$FAKEBIN/unreachable-ssh" run_seat "$HOME_DIR" "$FAKEBIN" switch work)
  expect_code 0 "$?" "a switch with an unreachable remote route should succeed: $out"
  [ "$(cat "$sm/config/claude-seat" 2>/dev/null)" = work ] \
    || fail "the local secondmate home must still take the new seat: $out"
  [ ! -s "$log" ] || fail "a seat switch must never open SSH to a remote route: $(cat "$log")"
  assert_not_contains "$out" "smremote" "a switch must report only this machine's homes"
  assert_not_contains "$out" "not every secondmate home was updated" \
    "an unreachable remote route must not make a switch report a home stuck on its previous seat"
  pass "a seat switch pushes only local secondmate homes and never waits on a remote route"
}

test_config_push_without_local_only_still_reaches_remote_routes() {
  local rec out sm log
  rec=$(make_seat_case push-no-flag)
  read_seat_case "$rec"
  printf 'codex\n' > "$HOME_DIR/config/crew-harness"
  sm=$(add_local_secondmate "$HOME_DIR" "$FAKEBIN" smlocal)
  log=$(add_unreachable_remote_secondmate "$HOME_DIR" "$FAKEBIN" smremote)
  out=$(TMUX='' PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_SSH_BIN="$FAKEBIN/unreachable-ssh" "$ROOT/bin/fm-config-push.sh" 2>&1)
  expect_code 1 "$?" "a plain config push must still report the unreachable remote route: $out"
  [ -s "$log" ] || fail "a plain config push must still attempt the remote route: $out"
  assert_contains "$out" "secondmate smremote (down-host:" "a plain config push must report the remote route"
  [ "$(cat "$sm/config/crew-harness" 2>/dev/null)" = codex ] \
    || fail "a plain config push must still update the local home: $out"

  : > "$log"
  out=$(TMUX='' PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_SSH_BIN="$FAKEBIN/unreachable-ssh" "$ROOT/bin/fm-config-push.sh" --local-only 2>&1)
  expect_code 0 "$?" "a local-only config push must skip the remote route: $out"
  [ ! -s "$log" ] || fail "a local-only config push must not open SSH: $(cat "$log")"
  assert_contains "$out" "secondmate smlocal (" "a local-only config push must still report the local home"
  pass "fm-config-push reaches remote routes by default and skips them only with --local-only"
}

test_remote_route_never_receives_seat_settings() {
  local rec out remote payload hash
  rec=$(make_seat_case remote-inherit)
  read_seat_case "$rec"
  remote="$CASE_DIR/remote-home"
  mkdir -p "$remote/config" "$remote/data" "$remote/state"
  printf 'work\n' > "$HOME_DIR/config/claude-seat"
  printf '15\n' > "$HOME_DIR/config/claude-seat-threshold"
  printf 'codex\n' > "$HOME_DIR/config/crew-harness"
  printf -- '- remsm - Remote route (host: inherit-host; root: %s; home: %s; scope: test; projects: ; added 2026-09-23)\n' \
    "$ROOT" "$remote" > "$HOME_DIR/data/secondmates.md"
  cat > "$FAKEBIN/inherit-ssh" <<'SH'
#!/usr/bin/env bash
set -eu
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
[ "$#" -eq 6 ] && [ "$1" = inherit-host ] && [ "$2" = fm-remote-entrypoint.sh ] || exit 91
remote_root=$(printf '%s' "$4" | base64 --decode)
remote_home=$(printf '%s' "$5" | base64 --decode)
args=()
while IFS= read -r -d '' arg; do args+=("$arg"); done < <(printf '%s' "$6" | base64 --decode)
FM_HOME="$remote_home" FM_STATE_OVERRIDE="$remote_home/state" \
  exec "$remote_root/bin/${args[0]}" "${args[@]:1}"
SH
  chmod +x "$FAKEBIN/inherit-ssh"

  out=$(FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_SSH_BIN="$FAKEBIN/inherit-ssh" \
    "$ROOT/bin/fm-remote-inherit-push.sh" remsm 1 2>&1)
  expect_code 0 "$?" "the remote inheritance push should succeed: $out"
  [ "$(cat "$remote/config/crew-harness" 2>/dev/null)" = codex ] \
    || fail "precondition: the remote push must still carry ordinary inherited config: $out"
  assert_absent "$remote/config/claude-seat" "a remote route must never receive the active seat"
  assert_absent "$remote/config/claude-seat-threshold" "a remote route must never receive the seat threshold"
  assert_not_contains "$out" "claude-seat" "the remote push must not transfer any seat setting"

  payload="$CASE_DIR/seat-payload"
  printf 'work\n' > "$payload"
  hash=$(shasum -a 256 "$payload" 2>/dev/null | awk '{print $1}' || sha256sum "$payload" | awk '{print $1}')
  out=$(FM_HOME="$remote" FM_STATE_OVERRIDE="$remote/state" \
    "$ROOT/bin/fm-remote-inherit.sh" put config/claude-seat 5 "$hash" 2 < "$payload" 2>&1)
  expect_code 1 "$?" "the remote receiver must refuse a seat setting: $out"
  assert_absent "$remote/config/claude-seat" "a refused seat setting must not land in the remote home"
  pass "seat settings reach local secondmate homes only and never cross to a remote route"
}

test_threshold_is_configurable_and_absent_by_default() {
  local rec out
  rec=$(make_seat_case threshold-config)
  read_seat_case "$rec"
  seat_logged_in "$SPEC_DIR" '(default)'

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" threshold)
  assert_contains "$out" "(unset" "an unconfigured threshold must report as unset"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" threshold 15)
  expect_code 0 "$?" "setting a threshold should succeed"
  assert_contains "$out" "15%" "setting a threshold must echo it"
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" threshold)
  assert_contains "$out" "15" "the threshold must read back"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" threshold 101)
  expect_code 1 "$?" "an out-of-range threshold must be refused"
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" threshold)
  assert_contains "$out" "15" "a refused threshold must leave the configured one intact"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" threshold off)
  expect_code 0 "$?" "clearing the threshold should succeed"
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" threshold)
  assert_contains "$out" "(unset" "a cleared threshold must report as unset"
  pass "the auto-switch threshold is configurable, validated, clearable, and unset by default"
}

test_threshold_reached_is_edge_triggered_by_the_configured_percent() {
  local rec status
  rec=$(make_seat_case threshold-edge)
  read_seat_case "$rec"
  seat_logged_in "$SPEC_DIR" '(default)'

  # No threshold configured: the condition must be an error, never a true, so a
  # home that never asked for automatic switching can never switch.
  run_seat "$HOME_DIR" "$FAKEBIN" threshold-reached >/dev/null
  expect_code 2 "$?" "with no threshold configured the condition must report an error"

  run_seat "$HOME_DIR" "$FAKEBIN" threshold 20 >/dev/null

  printf '80\n' > "$SPEC_DIR/remaining"
  run_seat "$HOME_DIR" "$FAKEBIN" threshold-reached >/dev/null
  expect_code 1 "$?" "well above the threshold the condition must be false"

  printf '21\n' > "$SPEC_DIR/remaining"
  run_seat "$HOME_DIR" "$FAKEBIN" threshold-reached >/dev/null
  expect_code 1 "$?" "just above the threshold the condition must still be false"

  printf '20\n' > "$SPEC_DIR/remaining"
  run_seat "$HOME_DIR" "$FAKEBIN" threshold-reached >/dev/null
  status=$?
  expect_code 0 "$status" "at the threshold the condition must be true"

  printf '5\n' > "$SPEC_DIR/remaining"
  run_seat "$HOME_DIR" "$FAKEBIN" threshold-reached >/dev/null
  expect_code 0 "$?" "below the threshold the condition must be true"
  pass "the threshold condition turns true exactly at the configured percent"
}

test_unreadable_quota_never_reports_the_threshold_reached() {
  local rec
  rec=$(make_seat_case threshold-unreadable)
  read_seat_case "$rec"
  seat_logged_in "$SPEC_DIR" '(default)'
  run_seat "$HOME_DIR" "$FAKEBIN" threshold 20 >/dev/null

  # An active seat whose quota cannot be read at all: the report carries no
  # known availability, so the condition must be an error rather than a true.
  : > "$SPEC_DIR/oauth"
  run_seat "$HOME_DIR" "$FAKEBIN" threshold-reached >/dev/null
  expect_code 2 "$?" "an unreadable quota must be an error, never a fired condition"
  pass "an unreadable quota never trips an automatic switch"
}

test_model_scoped_window_alone_does_not_trip_the_threshold() {
  local rec
  rec=$(make_seat_case threshold-scope)
  read_seat_case "$rec"
  seat_logged_in "$SPEC_DIR" '(default)'
  run_seat "$HOME_DIR" "$FAKEBIN" threshold 10 >/dev/null

  # An Opus-only window nearly spent while the account-level window has plenty
  # left: only workers on that model are constrained, so no switch.
  cat > "$SPEC_DIR/availability" <<'JSON'
[{"scope":"all_models","status":"known","effectivePercentRemaining":60,"runway":{"status":"through_reset"}},
 {"scope":"model:opus","status":"known","effectivePercentRemaining":5,"runway":{"status":"through_reset"}}]
JSON
  run_seat "$HOME_DIR" "$FAKEBIN" threshold-reached >/dev/null
  expect_code 1 "$?" "a model-scoped window below the threshold must not trip the account-level condition"

  # A report with no account-level window at all is undecidable, never a true.
  cat > "$SPEC_DIR/availability" <<'JSON'
[{"scope":"model:opus","status":"known","effectivePercentRemaining":5,"runway":{"status":"through_reset"}}]
JSON
  run_seat "$HOME_DIR" "$FAKEBIN" threshold-reached >/dev/null
  expect_code 2 "$?" "a report with no account-level window must be an error, not a fired condition"
  pass "only account-level quota windows count toward the auto-switch threshold"
}

test_default_seat_probes_the_ambient_profile_workers_get() {
  local rec out ambient
  rec=$(make_seat_case default-ambient)
  read_seat_case "$rec"
  ambient="$CASE_DIR/ambient-profile"
  # Only firstmate's own ambient profile is logged in; the bare ~/.claude is not.
  seat_logged_in "$SPEC_DIR" "$ambient"
  run_seat "$HOME_DIR" "$FAKEBIN" threshold 20 >/dev/null
  printf '5\n' > "$SPEC_DIR/remaining"

  out=$(SEAT_TEST_AMBIENT_CONFIG_DIR="$ambient" run_seat "$HOME_DIR" "$FAKEBIN" probe default)
  expect_code 0 "$?" "the default seat must probe the ambient profile a new worker would get: $out"
  out=$(SEAT_TEST_AMBIENT_CONFIG_DIR="$ambient" run_seat "$HOME_DIR" "$FAKEBIN" status)
  assert_contains "$out" "active profile: $ambient" "status must name the ambient profile for the default seat"
  assert_contains "$out" "login state: logged-in" "status must report the ambient profile's login state"
  SEAT_TEST_AMBIENT_CONFIG_DIR="$ambient" run_seat "$HOME_DIR" "$FAKEBIN" threshold-reached >/dev/null
  expect_code 0 "$?" "the threshold must be read against the ambient profile default-seat workers spend"
  pass "the default seat's probe and threshold read the ambient profile new workers launch with"
}

test_rotation_picks_the_next_logged_in_seat() {
  local rec out
  rec=$(make_seat_case rotate)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/work" "$SEATS_DIR/spare" "$SEATS_DIR/third"
  # 'spare' has no credentials, so rotation must skip it.
  seat_logged_in "$SPEC_DIR" '(default)' "$SEATS_DIR/work" "$SEATS_DIR/third"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" switch --next)
  expect_code 0 "$?" "rotation to a logged-in seat should succeed"
  assert_contains "$out" "-> third" "rotation must skip the seat that is not logged in"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" switch --next)
  expect_code 0 "$?" "rotation should continue to the other logged-in seat"
  assert_contains "$out" "-> work" "rotation must move on to the remaining logged-in seat"

  # And it wraps, still without ever choosing the default profile.
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" switch --next)
  expect_code 0 "$?" "rotation should wrap"
  assert_contains "$out" "-> third" "rotation must wrap among the seats under the root"
  pass "rotation chooses the next logged-in seat under the root and skips ones with no credentials"
}

test_rotation_never_targets_the_default_profile() {
  local rec out status
  rec=$(make_seat_case rotate-not-default)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/work"
  # The default profile is logged in and is the only other candidate, but it is
  # the owner's own interactive login and its account can change under them, so
  # an automatic rotation must never land workers on it.
  seat_logged_in "$SPEC_DIR" '(default)' "$SEATS_DIR/work"
  printf 'work\n' > "$HOME_DIR/config/claude-seat"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" switch --next)
  status=$?
  expect_code 1 "$status" "rotation must refuse rather than fall back to the default profile"
  assert_not_contains "$out" "-> default" "rotation must never choose the default profile"
  assert_grep "work" "$HOME_DIR/config/claude-seat" "a refused rotation must leave the active seat in place"
  pass "rotation never targets the default profile, even when it is the only other logged-in store"
}

test_rotation_refuses_when_there_is_nowhere_to_go() {
  local rec out status
  rec=$(make_seat_case rotate-nowhere)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/spare"
  seat_logged_in "$SPEC_DIR" '(default)'

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" switch --next)
  status=$?
  expect_code 1 "$status" "rotation with no other logged-in seat must refuse"
  assert_contains "$out" "no seat under the seats root qualifies" "the refusal must name the cause"
  assert_contains "$out" "seat spare: skipped, not logged in" \
    "the refusal must say which seat was rejected and why"
  assert_absent "$HOME_DIR/config/claude-seat" "a refused rotation must change nothing"
  pass "rotation refuses rather than pretending to switch when no other seat is usable"
}

test_rotation_reads_the_seat_set_fresh() {
  local rec out
  rec=$(make_seat_case rotate-fresh)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/work"
  seat_logged_in "$SPEC_DIR" "$SEATS_DIR/work"
  printf 'work\n' > "$HOME_DIR/config/claude-seat"

  # Nothing else exists yet, so there is nowhere to rotate.
  run_seat "$HOME_DIR" "$FAKEBIN" switch --next >/dev/null 2>&1
  expect_code 1 "$?" "precondition: a single seat leaves nowhere to rotate"

  # A seat added afterwards must be picked up without anything being re-armed:
  # the seat set is never assumed or cached.
  mkdir -p "$SEATS_DIR/later"
  seat_logged_in "$SPEC_DIR" "$SEATS_DIR/work" "$SEATS_DIR/later"
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" switch --next)
  expect_code 0 "$?" "a seat created after the first attempt should be found"
  assert_contains "$out" "-> later" "rotation must read the seat set fresh each time"
  pass "rotation never assumes which seats exist and picks up seats added later"
}

test_add_creates_the_profile_directory_without_touching_credentials() {
  local rec out
  rec=$(make_seat_case add-seat)
  read_seat_case "$rec"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" add work)
  expect_code 0 "$?" "adding a seat should succeed"
  assert_present "$SEATS_DIR/work" "add must create the seat's profile directory"
  assert_contains "$out" "CLAUDE_CONFIG_DIR=$SEATS_DIR/work claude" \
    "add must print the exact login command the account owner runs"
  assert_contains "$out" "No credential" "add must state that it touched no credential"
  # The directory is empty: nothing was copied into it from any other profile.
  [ -z "$(ls -A "$SEATS_DIR/work")" ] || fail "add must leave the new profile directory empty"
  pass "adding a seat creates an empty profile directory and prints the owner's login steps"
}

test_a_directory_named_default_is_not_offered_as_a_seat() {
  local rec out status
  rec=$(make_seat_case reserved-default)
  read_seat_case "$rec"
  # "default" names the ambient login, so a directory of that name can never be
  # selected. Listing it would offer a seat that every switch then refuses.
  mkdir -p "$SEATS_DIR/default" "$SEATS_DIR/work"
  seat_logged_in "$SPEC_DIR" '(default)' "$SEATS_DIR/work" "$SEATS_DIR/default"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" list)
  [ "$(printf '%s\n' "$out" | grep -c '[[:space:]]default[[:space:]]')" -eq 1 ] \
    || fail "the reserved default seat must appear exactly once, not also as a directory"$'\n'"$out"
  assert_not_contains "$out" "$SEATS_DIR/default" \
    "a directory named 'default' must not be listed as a seat profile"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" add default)
  status=$?
  expect_code 1 "$status" "adding a seat named 'default' must be refused"
  assert_contains "$out" "ambient login" "the refusal must say why the name is reserved"

  # Rotation must not offer it either.
  printf 'work\n' > "$HOME_DIR/config/claude-seat"
  run_seat "$HOME_DIR" "$FAKEBIN" switch --next >/dev/null 2>&1
  expect_code 1 "$?" "a directory named 'default' must not become a rotation target"
  pass "a directory named 'default' is never offered, added, or rotated to"
}

test_seat_names_that_escape_the_seats_root_are_refused() {
  local rec name
  rec=$(make_seat_case seat-names)
  read_seat_case "$rec"
  seat_logged_in "$SPEC_DIR" '(default)'

  for name in '../escape' 'a/b' '..' '' '.hidden'; do
    if run_seat "$HOME_DIR" "$FAKEBIN" switch "$name" >/dev/null 2>&1; then
      fail "seat name '$name' must be refused"
    fi
  done
  assert_absent "$HOME_DIR/config/claude-seat" "no invalid name may be recorded as the active seat"
  pass "seat names that are not a single safe path component are refused"
}

# --- spawn integration ------------------------------------------------------
#
# These drive the real bin/fm-spawn.sh with a fake tmux that captures the literal
# launch command, so they assert what firstmate would actually run.

spawn_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin launchlog seats
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  seats="$case_dir/seats"
  mkdir -p "$seats"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" claude
  fm_test_spawn_brief "$home" "$id"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  printf '%s\n' "$seats" > "$home/config/claude-seats-root"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog|$seats"
}

read_spawn_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN LAUNCH_LOG SEATS_DIR <<EOF
$1
EOF
}

run_spawn_here() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  : > "$launchlog"
  CLAUDE_CONFIG_DIR='' FM_FAKE_LAUNCH_LOG="$launchlog" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$@" --mode no-mistakes --yolo off
}

test_spawn_without_a_seat_sets_no_config_dir() {
  local rec id out launch
  id=seat-none-1
  rec=$(spawn_case spawn-no-seat "$id")
  read_spawn_case "$rec"

  out=$(run_spawn_here "$HOME_DIR" "$WT_DIR" "$FAKEBIN" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  expect_code 0 "$?" "a spawn with no seat configured should succeed: $out"
  launch=$(cat "$LAUNCH_LOG")
  assert_not_contains "$launch" "CLAUDE_CONFIG_DIR=" \
    "with no seat configured the launch must carry no config-dir prefix"
  assert_no_grep "claude_seat=" "$HOME_DIR/state/$id.meta" \
    "with no seat configured the task record must not claim a seat"
  pass "an unset seat setting leaves the launch and the task record exactly as before"
}

test_spawn_uses_the_active_seat_and_records_it() {
  local rec id out launch
  id=seat-active-1
  rec=$(spawn_case spawn-active-seat "$id")
  read_spawn_case "$rec"
  mkdir -p "$SEATS_DIR/work"
  printf 'work\n' > "$HOME_DIR/config/claude-seat"

  out=$(run_spawn_here "$HOME_DIR" "$WT_DIR" "$FAKEBIN" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  expect_code 0 "$?" "a spawn on a configured seat should succeed: $out"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "CLAUDE_CONFIG_DIR='$SEATS_DIR/work'" \
    "the launch must point the worker at the active seat's profile"
  assert_grep "claude_seat=$SEATS_DIR/work" "$HOME_DIR/state/$id.meta" \
    "the task record must remember the seat this worker launched on"
  pass "a spawn launches on the active seat and records it in the task's own record"
}

test_switching_seats_does_not_move_a_running_worker() {
  local rec id out before after
  id=seat-running-1
  rec=$(spawn_case spawn-running "$id")
  read_spawn_case "$rec"
  mkdir -p "$SEATS_DIR/work" "$SEATS_DIR/spare"
  printf 'work\n' > "$HOME_DIR/config/claude-seat"

  out=$(run_spawn_here "$HOME_DIR" "$WT_DIR" "$FAKEBIN" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  expect_code 0 "$?" "the first spawn should succeed: $out"
  before=$(sed -n 's/^claude_seat=//p' "$HOME_DIR/state/$id.meta")
  assert_equals "$SEATS_DIR/work" "$before" "precondition: the task launched on the work seat"

  # The switch itself: the running task's record must be untouched by it.
  printf 'spare\n' > "$HOME_DIR/config/claude-seat"
  after=$(sed -n 's/^claude_seat=//p' "$HOME_DIR/state/$id.meta")
  assert_equals "$SEATS_DIR/work" "$after" \
    "a seat switch must not rewrite a running task's recorded seat"
  pass "switching seats leaves a running worker's recorded profile unchanged"
}

test_a_later_spawn_uses_the_new_seat_while_the_old_task_keeps_its_own() {
  local rec id2 out launch case_dir home proj fakebin
  rec=$(spawn_case spawn-two-seats seat-first-1)
  read_spawn_case "$rec"
  mkdir -p "$SEATS_DIR/work" "$SEATS_DIR/spare"
  printf 'work\n' > "$HOME_DIR/config/claude-seat"

  out=$(run_spawn_here "$HOME_DIR" "$WT_DIR" "$FAKEBIN" "$LAUNCH_LOG" seat-first-1 "$PROJ_DIR")
  expect_code 0 "$?" "the first spawn should succeed: $out"

  # Switch, then spawn a second task from a second worktree in the same home.
  printf 'spare\n' > "$HOME_DIR/config/claude-seat"
  id2=seat-second-1
  fm_test_spawn_brief "$HOME_DIR" "$id2"
  git -C "$PROJ_DIR" worktree add --quiet -b wt-two-seats-2 "$CASE_DIR/wt2"
  out=$(run_spawn_here "$HOME_DIR" "$CASE_DIR/wt2" "$FAKEBIN" "$LAUNCH_LOG" "$id2" "$PROJ_DIR")
  expect_code 0 "$?" "the second spawn should succeed: $out"
  launch=$(cat "$LAUNCH_LOG")

  assert_contains "$launch" "CLAUDE_CONFIG_DIR='$SEATS_DIR/spare'" \
    "the new worker must launch on the seat that is active now"
  assert_grep "claude_seat=$SEATS_DIR/spare" "$HOME_DIR/state/$id2.meta" \
    "the new task must record the new seat"
  assert_grep "claude_seat=$SEATS_DIR/work" "$HOME_DIR/state/seat-first-1.meta" \
    "the earlier task must still record the seat it launched on"
  pass "after a switch new workers get the new seat while existing ones keep theirs"
}

test_ambient_config_dir_still_reaches_workers_when_no_seat_is_set() {
  local rec id out launch
  id=seat-ambient-1
  rec=$(spawn_case spawn-ambient "$id")
  read_spawn_case "$rec"

  # No seat configured, but firstmate itself runs under a non-default profile.
  # That predates seats and must keep working: the worker gets the same store.
  : > "$LAUNCH_LOG"
  out=$(FM_TEST_CLAUDE_CONFIG_DIR="$CASE_DIR/ambient-profile" \
    FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1)
  expect_code 0 "$?" "a spawn under an ambient config dir should succeed: $out"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "CLAUDE_CONFIG_DIR='$CASE_DIR/ambient-profile'" \
    "firstmate's own config dir must still reach the worker when no seat is configured"
  assert_grep "claude_seat=$CASE_DIR/ambient-profile" "$HOME_DIR/state/$id.meta" \
    "the ambient store must be recorded as this task's seat so a relaunch keeps it"
  pass "an ambient CLAUDE_CONFIG_DIR still reaches workers and is recorded per task"
}

test_non_claude_spawn_records_no_seat() {
  local rec id out launch
  id=seat-codex-1
  rec=$(spawn_case spawn-codex-seat "$id")
  read_spawn_case "$rec"
  printf 'codex\n' > "$HOME_DIR/config/crew-harness"
  mkdir -p "$SEATS_DIR/work"
  printf 'work\n' > "$HOME_DIR/config/claude-seat"

  out=$(run_spawn_here "$HOME_DIR" "$WT_DIR" "$FAKEBIN" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  expect_code 0 "$?" "a codex spawn with a named seat active should succeed: $out"
  launch=$(cat "$LAUNCH_LOG")
  assert_not_contains "$launch" "CLAUDE_CONFIG_DIR=" "a non-claude launch must carry no Claude profile"
  assert_no_grep "claude_seat=" "$HOME_DIR/state/$id.meta" \
    "a non-claude task must not record a Claude seat"
  make_quota_fake "$FAKEBIN" "$CASE_DIR/quota-spec"
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" status)
  assert_not_contains "$(printf '%s\n' "$out" | grep "$id")" "$SEATS_DIR/work" \
    "status must not list a non-claude task as running on a seat"
  pass "a non-claude spawn records no Claude seat while a named seat is active"
}

test_active_seat_overrides_the_ambient_config_dir() {
  local rec id out launch
  id=seat-override-1
  rec=$(spawn_case spawn-override "$id")
  read_spawn_case "$rec"
  mkdir -p "$SEATS_DIR/work"
  printf 'work\n' > "$HOME_DIR/config/claude-seat"

  : > "$LAUNCH_LOG"
  out=$(FM_TEST_CLAUDE_CONFIG_DIR="$CASE_DIR/ambient-profile" \
    FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1)
  expect_code 0 "$?" "a spawn with both a seat and an ambient dir should succeed: $out"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "CLAUDE_CONFIG_DIR='$SEATS_DIR/work'" \
    "the configured seat must win over firstmate's ambient config dir"
  assert_not_contains "$launch" "$CASE_DIR/ambient-profile" \
    "the ambient config dir must not also appear in the launch"
  pass "a configured seat takes precedence over firstmate's own ambient config dir"
}

# Two mechanisms select a Claude worker's configuration directory: this home's
# seat and the worker account pin (config/claude-account). Composed, the pin's
# `env` launch consumes the seat's assignment and silently wins, while trust is
# pre-registered in the seat's profile - so the worker meets a trust dialog it
# cannot answer. A home configuring both is a configuration conflict, refused
# before any endpoint, local copy, or task record exists.
test_account_pin_and_active_seat_refuse_the_spawn() {
  local rec id out
  id=seat-account-conflict-1
  rec=$(spawn_case spawn-account-conflict "$id")
  read_spawn_case "$rec"
  mkdir -p "$SEATS_DIR/work"
  printf 'work\n' > "$HOME_DIR/config/claude-seat"
  printf 'ordinary\n' > "$HOME_DIR/config/claude-account"

  out=$(run_spawn_here "$HOME_DIR" "$WT_DIR" "$FAKEBIN" "$LAUNCH_LOG" "$id" "$PROJ_DIR" 2>&1)
  expect_code 1 "$?" "configuring both an account pin and an active seat must refuse the spawn: $out"
  assert_contains "$out" "$HOME_DIR/config/claude-account" \
    "the refusal must name the account pin file by path"
  assert_contains "$out" "$HOME_DIR/config/claude-seat" \
    "the refusal must name the seat file by path"
  assert_contains "$out" "remove either file" \
    "the refusal must say that removing either file resolves the conflict"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused spawn must leave no task record"
  [ ! -s "$LAUNCH_LOG" ] || fail "a refused spawn must launch no worker endpoint"
  pass "a home configuring both an account pin and an active seat is refused before anything exists"
}

# make_dead_endpoint_tmux <fakebin> <window>
# Wraps the spawn fake tmux so <window> exists and its pane runs a bare shell:
# the positively agent-free endpoint a relaunch requires before it may launch.
make_dead_endpoint_tmux() {
  local fakebin=$1 window=$2
  mv "$fakebin/tmux" "$fakebin/tmux-spawn"
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
case "\$*" in
  list-windows*) printf '%s\\n' '$window'; exit 0 ;;
  *'#{pane_tty}'*) exit 1 ;;
  *'#{pane_current_command}'*) printf 'zsh\\n'; exit 0 ;;
esac
exec "$fakebin/tmux-spawn" "\$@"
SH
  chmod +x "$fakebin/tmux"
}

test_account_pin_and_recorded_seat_refuse_the_relaunch() {
  local rec id out meta_before
  id=seat-account-relaunch-1
  rec=$(spawn_case spawn-account-relaunch "$id")
  read_spawn_case "$rec"
  mkdir -p "$SEATS_DIR/work"
  printf 'work\n' > "$HOME_DIR/config/claude-seat"
  out=$(run_spawn_here "$HOME_DIR" "$WT_DIR" "$FAKEBIN" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  expect_code 0 "$?" "the task's first spawn on the work seat should succeed: $out"
  assert_grep "claude_seat=$SEATS_DIR/work" "$HOME_DIR/state/$id.meta" \
    "the task record must carry the seat it launched on"
  # The home drops its seat and adds a pin; the task's record still names the
  # work seat, which a relaunch keeps.
  rm "$HOME_DIR/config/claude-seat"
  printf 'ordinary\n' > "$HOME_DIR/config/claude-account"
  fm_fake_exit0 "$FAKEBIN" claude
  make_dead_endpoint_tmux "$FAKEBIN" "fm-$id"
  meta_before="$CASE_DIR/meta.before"
  cp "$HOME_DIR/state/$id.meta" "$meta_before"
  : > "$LAUNCH_LOG"

  out=$(CLAUDE_CONFIG_DIR='' FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN" "$id" --relaunch)
  expect_code 1 "$?" "an account pin must refuse relaunching a task recorded on a seat: $out"
  assert_contains "$out" "$HOME_DIR/config/claude-account" \
    "the refusal must name the account pin file by path"
  assert_contains "$out" "task $id was launched on the Claude seat $SEATS_DIR/work" \
    "the refusal must name the recorded seat and say the task was launched on it"
  assert_not_contains "$out" "remove either file" \
    "the refusal must not offer removing the seat file, which leaves the recorded seat in place"
  cmp -s "$meta_before" "$HOME_DIR/state/$id.meta" \
    || fail "a refused relaunch must leave the task record untouched"
  [ ! -s "$LAUNCH_LOG" ] || fail "a refused relaunch must launch no worker endpoint"
  pass "an account pin refuses relaunching a task recorded on a seat before anything is touched"
}

test_pin_only_home_still_relaunches_a_claude_task() {
  local rec id out pin
  id=seat-pin-only-relaunch-1
  rec=$(spawn_case spawn-pin-only-relaunch "$id")
  read_spawn_case "$rec"
  fm_fake_exit0 "$FAKEBIN" claude
  pin="$CASE_DIR/pin-root"
  mkdir -p "$pin"
  printf '%s\n' "$pin" > "$HOME_DIR/config/claude-account"
  out=$(run_spawn_here "$HOME_DIR" "$WT_DIR" "$FAKEBIN" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  expect_code 0 "$?" "a spawn under a named-root pin with no seat should succeed: $out"
  make_dead_endpoint_tmux "$FAKEBIN" "fm-$id"
  : > "$LAUNCH_LOG"

  out=$(CLAUDE_CONFIG_DIR='' FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN" "$id" --relaunch)
  expect_code 0 "$?" "a pin-only home must still relaunch its claude task: $out"
  assert_contains "$(cat "$LAUNCH_LOG")" "CLAUDE_CONFIG_DIR='$pin'" \
    "the relaunched worker must launch under the pinned root"
  pass "a pin-only home with no seat file still relaunches a claude task under its pin"
}

test_pin_at_a_seat_directory_still_relaunches_a_claude_task() {
  local rec id out
  id=seat-pin-at-seat-relaunch-1
  rec=$(spawn_case spawn-pin-at-seat-relaunch "$id")
  read_spawn_case "$rec"
  fm_fake_exit0 "$FAKEBIN" claude
  mkdir -p "$SEATS_DIR/work"
  printf '%s\n' "$SEATS_DIR/work" > "$HOME_DIR/config/claude-account"
  out=$(run_spawn_here "$HOME_DIR" "$WT_DIR" "$FAKEBIN" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  expect_code 0 "$?" "a spawn under a pin at a seat directory should succeed: $out"
  assert_grep "claude_seat=$SEATS_DIR/work" "$HOME_DIR/state/$id.meta" \
    "the task record must carry the pinned seat directory it launched on"
  make_dead_endpoint_tmux "$FAKEBIN" "fm-$id"
  : > "$LAUNCH_LOG"

  out=$(CLAUDE_CONFIG_DIR='' FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN" "$id" --relaunch)
  expect_code 0 "$?" "a pin at the task's own seat directory must still relaunch it: $out"
  assert_contains "$(cat "$LAUNCH_LOG")" "CLAUDE_CONFIG_DIR='$SEATS_DIR/work'" \
    "the relaunched worker must launch on the pinned seat directory"
  pass "a pin pointing at a seat directory still relaunches a task recorded on that directory"
}

# --- automatic mode ----------------------------------------------------------
# The three controls are the trigger (the ACTIVE seat's percent left), the
# destination minimum (the percent left a DESTINATION must exceed), and the
# extra-usage policy (what happens when neither can be satisfied). Every one is
# off when absent, which the first case below pins.

# seat_remaining <spec> <profile> <percent>
# Give one profile its own percent remaining.
seat_remaining() {
  printf '%s\t%s\n' "$2" "$3" >> "$1/remaining_map"
}

# seat_quota_unreadable <spec> <profile...>
# Declare profiles that are logged in but whose account-level quota cannot be
# read, so a case can prove an ambiguous read is skipped rather than guessed at.
seat_quota_unreadable() {
  local spec=$1
  shift
  printf '%s\n' "$@" > "$spec/unreadable_quota"
}

# seat_extra_spend <spec> <profile> <usd>
# Give one profile an extra_usage window carrying that much paid spend.
seat_extra_spend() {
  printf '%s\t%s\n' "$2" "$3" >> "$1/extra_map"
}

test_an_unconfigured_home_reads_no_candidate_quota_and_holds_nothing() {
  local rec out
  rec=$(make_seat_case auto-off-by-default)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/work" "$SEATS_DIR/spare"
  seat_logged_in "$SPEC_DIR" '(default)' "$SEATS_DIR/work" "$SEATS_DIR/spare"
  printf 'work\n' > "$HOME_DIR/config/claude-seat"
  # Both other seats read as nearly empty. With no destination minimum set, that
  # is not consulted at all and rotation is login-only, exactly as before these
  # settings existed.
  seat_remaining "$SPEC_DIR" "$SEATS_DIR/spare" 1

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" switch --next)
  expect_code 0 "$?" "with no destination minimum, rotation must ignore a candidate's quota entirely"
  assert_contains "$out" "-> spare" "an unconfigured home must rotate exactly as it did before"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" status)
  assert_contains "$out" "new Claude dispatch: allowed" "with no extra-usage policy, dispatch must never be held"
  assert_contains "$out" "no extra-usage policy is configured" \
    "the gate must say it read nothing rather than implying a quota verdict"
  assert_absent "$HOME_DIR/config/claude-seat-destination-min" \
    "reading the gate must not create a destination minimum"
  assert_absent "$HOME_DIR/config/claude-seat-extra-usage" \
    "reading the gate must not create an extra-usage policy"
  pass "a home that configures none of the automatic settings behaves exactly as before they existed"
}

test_dispatch_gate_needs_no_quota_reader_when_unconfigured() {
  local rec out bare
  rec=$(make_seat_case auto-off-no-reader)
  read_seat_case "$rec"
  # A fakebin with NO quota-axi at all. An unconfigured home must still allow
  # dispatch, which proves the gate reads nothing rather than failing open on a
  # read it attempted and could not make.
  bare=$(fm_fakebin "$CASE_DIR/bare")
  out=$(run_seat "$HOME_DIR" "$bare" status)
  assert_contains "$out" "new Claude dispatch: allowed" \
    "an unconfigured gate must allow dispatch with no quota reader present at all"
  assert_contains "$out" "no extra-usage policy" "the allow must name the unset policy as its reason"
  pass "the dispatch gate reads no quota at all until an extra-usage policy is configured"
}

test_destination_minimum_is_configurable_validated_and_clearable() {
  local rec out
  rec=$(make_seat_case dest-min-config)
  read_seat_case "$rec"
  seat_logged_in "$SPEC_DIR" '(default)'

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" destination-min)
  assert_contains "$out" "(unset" "an unconfigured destination minimum must report as unset"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" destination-min 30)
  expect_code 0 "$?" "setting a destination minimum should succeed"
  assert_contains "$out" "30% left" "the setter must echo the value in percent LEFT"
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" destination-min)
  assert_contains "$out" "30" "the destination minimum must read back"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" destination-min 101)
  expect_code 1 "$?" "an out-of-range destination minimum must be refused"
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" destination-min)
  assert_contains "$out" "30" "a refused value must leave the configured one intact"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" destination-min off)
  expect_code 0 "$?" "clearing the destination minimum should succeed"
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" destination-min)
  assert_contains "$out" "(unset" "a cleared destination minimum must report as unset"
  pass "the destination minimum is settable by command, validated, clearable, and unset by default"
}

test_a_switch_skips_a_seat_below_the_destination_minimum() {
  local rec out
  rec=$(make_seat_case dest-min-skip)
  read_seat_case "$rec"
  # Named so the LEAN seat comes first in rotation order and the roomy one
  # second: a gate that only ever looked at the first candidate would pass a
  # test where the roomy seat happened to be reached first.
  mkdir -p "$SEATS_DIR/alpha" "$SEATS_DIR/beta-lean" "$SEATS_DIR/zulu-roomy"
  seat_logged_in "$SPEC_DIR" "$SEATS_DIR/alpha" "$SEATS_DIR/beta-lean" "$SEATS_DIR/zulu-roomy"
  printf 'alpha\n' > "$HOME_DIR/config/claude-seat"
  seat_remaining "$SPEC_DIR" "$SEATS_DIR/alpha" 5
  seat_remaining "$SPEC_DIR" "$SEATS_DIR/beta-lean" 12
  seat_remaining "$SPEC_DIR" "$SEATS_DIR/zulu-roomy" 70
  run_seat "$HOME_DIR" "$FAKEBIN" destination-min 25 >/dev/null

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" switch --next)
  expect_code 0 "$?" "a rotation with one qualifying seat must succeed: $out"
  assert_contains "$out" "-> zulu-roomy" "rotation must land on the seat with headroom, not the next one in list order"
  assert_contains "$out" "seat beta-lean: skipped, 12% left is not above the 25% destination minimum" \
    "the skipped seat and its measured headroom must be reported"
  assert_grep "zulu-roomy" "$HOME_DIR/config/claude-seat" "the qualifying seat must be recorded"
  pass "a switch skips a logged-in seat below the destination minimum and lands on one above it"
}

test_no_switch_happens_when_no_seat_clears_the_destination_minimum() {
  local rec out
  rec=$(make_seat_case dest-min-none)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/alpha" "$SEATS_DIR/beta-lean"
  seat_logged_in "$SPEC_DIR" "$SEATS_DIR/alpha" "$SEATS_DIR/beta-lean"
  printf 'alpha\n' > "$HOME_DIR/config/claude-seat"
  seat_remaining "$SPEC_DIR" "$SEATS_DIR/alpha" 5
  seat_remaining "$SPEC_DIR" "$SEATS_DIR/beta-lean" 12
  run_seat "$HOME_DIR" "$FAKEBIN" destination-min 25 >/dev/null

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" switch --next)
  expect_code 1 "$?" "a rotation with no qualifying seat must refuse rather than switch"
  assert_contains "$out" "no seat under the seats root qualifies" "the refusal must name the cause"
  assert_contains "$out" "seat beta-lean: skipped, 12% left" "the refusal must say which seat was rejected and why"
  assert_grep "alpha" "$HOME_DIR/config/claude-seat" "a refused rotation must leave the active seat in place"
  pass "no switch happens when every candidate is below the destination minimum"
}

test_an_unreadable_candidate_quota_is_skipped_and_never_guessed() {
  local rec out
  rec=$(make_seat_case dest-min-unreadable)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/alpha" "$SEATS_DIR/murky"
  seat_logged_in "$SPEC_DIR" "$SEATS_DIR/alpha" "$SEATS_DIR/murky"
  printf 'alpha\n' > "$HOME_DIR/config/claude-seat"
  # murky is logged in, so the login gate alone would accept it. Its quota gives
  # no verdict, which is not evidence of headroom in either direction.
  seat_quota_unreadable "$SPEC_DIR" "$SEATS_DIR/murky"
  run_seat "$HOME_DIR" "$FAKEBIN" destination-min 25 >/dev/null

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" switch --next)
  expect_code 1 "$?" "an ambiguous candidate quota must never be treated as headroom"
  assert_contains "$out" "seat murky: skipped, its quota could not be read" \
    "the skip must say the quota gave no verdict rather than implying a number"
  assert_contains "$out" "makes no guess" "the refusal must state that nothing was guessed"
  assert_grep "alpha" "$HOME_DIR/config/claude-seat" "nothing may be switched on an unreadable quota"
  pass "a candidate whose quota gives no verdict is skipped, never guessed at as headroom"
}

test_extra_usage_policy_is_configurable_validated_and_clearable() {
  local rec out
  rec=$(make_seat_case extra-usage-config)
  read_seat_case "$rec"
  seat_logged_in "$SPEC_DIR" '(default)'

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" extra-usage)
  assert_contains "$out" "(unset" "an unconfigured extra-usage policy must report as unset"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" extra-usage stop)
  expect_code 0 "$?" "setting the stop policy should succeed"
  assert_contains "$out" "not a guarantee of zero spend" \
    "setting stop must state plainly that a running worker is not stopped"
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" extra-usage)
  assert_contains "$out" "stop" "the stop policy must read back"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" extra-usage allow 25)
  expect_code 0 "$?" "setting a dollar cap should succeed"
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" extra-usage)
  assert_contains "$out" "25" "the cap must read back"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" extra-usage allow)
  expect_code 1 "$?" "allow with no dollar cap must be refused"
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" extra-usage banana)
  expect_code 1 "$?" "an unknown policy word must be refused"
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" extra-usage)
  assert_contains "$out" "25" "a refused policy must leave the configured one intact"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" extra-usage off)
  expect_code 0 "$?" "clearing the policy should succeed"
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" extra-usage)
  assert_contains "$out" "(unset" "a cleared policy must report as unset"
  pass "the extra-usage policy is settable by command, validated, clearable, and unset by default"
}

test_stop_policy_holds_dispatch_only_once_the_plan_quota_is_gone() {
  local rec out
  rec=$(make_seat_case extra-usage-stop)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/alpha"
  seat_logged_in "$SPEC_DIR" "$SEATS_DIR/alpha"
  printf 'alpha\n' > "$HOME_DIR/config/claude-seat"
  run_seat "$HOME_DIR" "$FAKEBIN" extra-usage stop >/dev/null

  # Plan quota still left: the gate exists to guard paid overflow, not to
  # ration the plan, so this must allow.
  seat_remaining "$SPEC_DIR" "$SEATS_DIR/alpha" 8
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" status)
  assert_contains "$out" "new Claude dispatch: allowed" \
    "plan quota still remaining must never be held by the extra-usage policy"
  assert_contains "$out" "8% of its plan quota left" "the allow must name the remaining plan quota"

  # Plan quota gone: any further work runs on paid extra usage.
  printf '%s\t0\n' "$SEATS_DIR/alpha" > "$SPEC_DIR/remaining_map"
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" status)
  assert_contains "$out" "new Claude dispatch: HELD" \
    "with the plan quota gone and the policy set to stop, dispatch must be held"
  assert_contains "$out" "no new Claude worker is started on paid extra usage" \
    "the hold must say what it is preventing"
  assert_contains "$out" "a worker already running keeps its own seat" \
    "the hold must state plainly that a running worker is not stopped"
  pass "the stop policy holds new dispatch only once the active seat's plan quota is gone"
}

test_allow_policy_proceeds_under_the_cap_and_holds_at_it() {
  local rec out
  rec=$(make_seat_case extra-usage-cap)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/alpha"
  seat_logged_in "$SPEC_DIR" "$SEATS_DIR/alpha"
  printf 'alpha\n' > "$HOME_DIR/config/claude-seat"
  seat_remaining "$SPEC_DIR" "$SEATS_DIR/alpha" 0
  run_seat "$HOME_DIR" "$FAKEBIN" extra-usage allow 25 >/dev/null

  seat_extra_spend "$SPEC_DIR" "$SEATS_DIR/alpha" 10
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" status)
  assert_contains "$out" "new Claude dispatch: allowed" "spend below the cap must keep dispatching: $out"
  # shellcheck disable=SC2016  # literal dollar signs in the expected output, not expansions
  assert_contains "$out" '$10 of extra usage spent on the active Claude seat, under the $25 cap' \
    "the allow must name the spend and the cap it was compared against"

  printf '%s\t25\n' "$SEATS_DIR/alpha" > "$SPEC_DIR/extra_map"
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" status)
  assert_contains "$out" "new Claude dispatch: HELD" \
    "spend at the cap must hold, so the cap is a ceiling and not a target to pass"
  # shellcheck disable=SC2016  # literal dollar signs in the expected output, not expansions
  assert_contains "$out" 'at or over the $25 cap' "the hold must name the cap it reached"
  pass "the allow policy dispatches under its dollar cap and holds once the spend reaches it"
}

test_an_unreadable_quota_holds_dispatch_rather_than_guessing() {
  local rec out
  rec=$(make_seat_case extra-usage-unreadable)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/alpha"
  seat_logged_in "$SPEC_DIR" "$SEATS_DIR/alpha"
  printf 'alpha\n' > "$HOME_DIR/config/claude-seat"
  seat_quota_unreadable "$SPEC_DIR" "$SEATS_DIR/alpha"
  run_seat "$HOME_DIR" "$FAKEBIN" extra-usage stop >/dev/null

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" status)
  assert_contains "$out" "new Claude dispatch: HELD" \
    "a quota that gives no verdict must hold rather than dispatch on a guess"
  assert_contains "$out" "makes no guess" "the hold must say it refused to guess"

  # Once the plan quota can be read again the hold lifts on its own, so this is
  # a condition that clears rather than a state an operator must reset.
  rm -f "$SPEC_DIR/unreadable_quota"
  seat_remaining "$SPEC_DIR" "$SEATS_DIR/alpha" 40
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" status)
  assert_contains "$out" "new Claude dispatch: allowed" \
    "a readable quota with plan headroom must lift the hold with no operator action"
  pass "an unreadable quota holds dispatch instead of guessing, and the hold lifts once it reads again"
}

test_the_watch_keeps_firing_across_crossings_and_never_twice_on_one() {
  local rec out
  rec=$(make_seat_case auto-repeats)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/alpha" "$SEATS_DIR/beta" "$SEATS_DIR/gamma"
  seat_logged_in "$SPEC_DIR" "$SEATS_DIR/alpha" "$SEATS_DIR/beta" "$SEATS_DIR/gamma"
  printf 'alpha\n' > "$HOME_DIR/config/claude-seat"
  run_seat "$HOME_DIR" "$FAKEBIN" threshold 15 >/dev/null
  run_seat "$HOME_DIR" "$FAKEBIN" destination-min 25 >/dev/null

  # Above the trigger: silent, and nothing moves.
  seat_remaining "$SPEC_DIR" "$SEATS_DIR/alpha" 60
  seat_remaining "$SPEC_DIR" "$SEATS_DIR/beta" 80
  seat_remaining "$SPEC_DIR" "$SEATS_DIR/gamma" 90
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" auto)
  [ -z "$out" ] || fail "a seat above its trigger must produce no wake: $out"
  assert_grep "alpha" "$HOME_DIR/config/claude-seat" "nothing may move above the trigger"

  # First crossing: switches, and says so once.
  printf '%s\t10\n%s\t80\n%s\t90\n' \
    "$SEATS_DIR/alpha" "$SEATS_DIR/beta" "$SEATS_DIR/gamma" > "$SPEC_DIR/remaining_map"
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" auto)
  assert_contains "$out" "switched from alpha at 10% left to beta" "the first crossing must switch and report it"
  assert_grep "beta" "$HOME_DIR/config/claude-seat" "the first crossing must record the new seat"

  # The same seat sitting below its trigger is one crossing, not many: the next
  # poll must be silent even though the condition is still true.
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" auto)
  [ -z "$out" ] || fail "a crossing already acted on must not fire again on the next poll: $out"

  # The seat it moved TO now crosses. This is the property a fire-once watch
  # loses: it must fire again with nothing re-armed by hand.
  printf '%s\t10\n%s\t9\n%s\t90\n' \
    "$SEATS_DIR/alpha" "$SEATS_DIR/beta" "$SEATS_DIR/gamma" > "$SPEC_DIR/remaining_map"
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" auto)
  assert_contains "$out" "switched from beta at 9% left to gamma" \
    "the watch must keep watching and fire on the next seat's own crossing"
  assert_grep "gamma" "$HOME_DIR/config/claude-seat" "the second crossing must record the third seat"
  pass "the watch keeps running after a switch, fires once per crossing, and catches the next seat's own"
}

test_the_watch_reports_the_policy_consequence_when_no_seat_qualifies() {
  local rec out
  rec=$(make_seat_case auto-no-destination)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/alpha" "$SEATS_DIR/beta"
  seat_logged_in "$SPEC_DIR" "$SEATS_DIR/alpha" "$SEATS_DIR/beta"
  printf 'alpha\n' > "$HOME_DIR/config/claude-seat"
  run_seat "$HOME_DIR" "$FAKEBIN" threshold 15 >/dev/null
  run_seat "$HOME_DIR" "$FAKEBIN" destination-min 25 >/dev/null
  run_seat "$HOME_DIR" "$FAKEBIN" extra-usage stop >/dev/null
  seat_remaining "$SPEC_DIR" "$SEATS_DIR/alpha" 10
  seat_remaining "$SPEC_DIR" "$SEATS_DIR/beta" 11

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" auto)
  assert_contains "$out" "no seat has enough headroom" "the wake must say why no switch happened"
  assert_contains "$out" "will be held once this seat's plan quota runs out" \
    "the wake must name the policy consequence, not just the failed switch"
  assert_contains "$out" "A worker already running is not stopped" \
    "the wake must state the limit plainly"
  assert_grep "alpha" "$HOME_DIR/config/claude-seat" "no seat qualifying must leave the active seat alone"

  # One crossing, one wake: the same unqualified state must not wake again.
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" auto)
  [ -z "$out" ] || fail "an unchanged unqualified crossing must not wake again: $out"
  pass "with no seat qualifying the watch reports the policy consequence once and switches nothing"
}

test_the_watch_and_status_agree_while_plan_quota_remains() {
  local rec wake st
  rec=$(make_seat_case auto-agrees-with-status)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/alpha" "$SEATS_DIR/beta"
  seat_logged_in "$SPEC_DIR" "$SEATS_DIR/alpha" "$SEATS_DIR/beta"
  printf 'alpha\n' > "$HOME_DIR/config/claude-seat"
  run_seat "$HOME_DIR" "$FAKEBIN" threshold 15 >/dev/null
  run_seat "$HOME_DIR" "$FAKEBIN" destination-min 30 >/dev/null
  run_seat "$HOME_DIR" "$FAKEBIN" extra-usage stop >/dev/null
  seat_remaining "$SPEC_DIR" "$SEATS_DIR/alpha" 11
  seat_remaining "$SPEC_DIR" "$SEATS_DIR/beta" 20

  wake=$(run_seat "$HOME_DIR" "$FAKEBIN" auto)
  st=$(run_seat "$HOME_DIR" "$FAKEBIN" status)
  assert_contains "$wake" "no seat has enough headroom" "precondition: the crossing must find nowhere to go"
  assert_contains "$st" "new Claude dispatch: allowed" \
    "precondition: with plan quota still left, status must report dispatch allowed: $st"
  case "$wake" in
    *"is held"*|*"held rather"*) fail "the wake claims work is already held while status says dispatch is allowed: $wake" ;;
  esac
  assert_contains "$wake" "once this seat's plan quota runs out" \
    "the wake must say when the hold will begin"
  assert_contains "$wake" "A worker already running is not stopped" "the wake must still state the limit"
  pass "the watch's wake line and status agree while the seat still has plan quota"
}

test_the_watch_switches_once_a_candidate_recovers_after_a_crossing_with_nowhere_to_go() {
  local rec out
  rec=$(make_seat_case auto-recovers)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/alpha" "$SEATS_DIR/beta"
  seat_logged_in "$SPEC_DIR" "$SEATS_DIR/alpha" "$SEATS_DIR/beta"
  printf 'alpha\n' > "$HOME_DIR/config/claude-seat"
  run_seat "$HOME_DIR" "$FAKEBIN" threshold 15 >/dev/null
  run_seat "$HOME_DIR" "$FAKEBIN" destination-min 30 >/dev/null
  run_seat "$HOME_DIR" "$FAKEBIN" extra-usage stop >/dev/null
  printf '%s\t5\n%s\t20\n' "$SEATS_DIR/alpha" "$SEATS_DIR/beta" > "$SPEC_DIR/remaining_map"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" auto)
  assert_contains "$out" "no seat has enough headroom" "precondition: the crossing must find nowhere to go"

  # beta's window resets while alpha is still below its trigger. The watch must
  # look again rather than stay silent until alpha itself recovers.
  printf '%s\t5\n%s\t100\n' "$SEATS_DIR/alpha" "$SEATS_DIR/beta" > "$SPEC_DIR/remaining_map"
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" auto)
  assert_contains "$out" "switched from alpha at 5% left to beta" \
    "a candidate that recovers after a crossing with nowhere to go must be switched to"
  assert_grep "beta" "$HOME_DIR/config/claude-seat" "the recovered candidate must become the active seat"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" auto)
  [ -z "$out" ] || fail "a completed switch must not wake again on the next poll: $out"
  pass "after a crossing with nowhere to go, the watch keeps looking and switches once a seat recovers"
}

test_the_watch_keeps_every_quota_read_inside_the_check_budget() {
  local rec out started elapsed
  rec=$(make_seat_case auto-slow-reads)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/alpha" "$SEATS_DIR/beta"
  seat_logged_in "$SPEC_DIR" "$SEATS_DIR/alpha" "$SEATS_DIR/beta"
  printf 'alpha\n' > "$HOME_DIR/config/claude-seat"
  run_seat "$HOME_DIR" "$FAKEBIN" threshold 15 >/dev/null
  run_seat "$HOME_DIR" "$FAKEBIN" extra-usage stop >/dev/null
  printf '%s\t5\n%s\t90\n' "$SEATS_DIR/alpha" "$SEATS_DIR/beta" > "$SPEC_DIR/remaining_map"
  printf 'task=t1\nharness=claude\nclaude_seat=%s\n' "$SEATS_DIR/alpha" > "$HOME_DIR/state/t1.meta"
  printf '30\n' > "$SPEC_DIR/slow"

  started=$(date +%s)
  out=$(FM_CHECK_TIMEOUT=8 run_seat "$HOME_DIR" "$FAKEBIN" auto)
  elapsed=$(($(date +%s) - started))
  [ "$elapsed" -lt 8 ] || fail "a pass with slow quota reads must finish inside FM_CHECK_TIMEOUT, took ${elapsed}s"
  [ -z "$out" ] || fail "a read cut short must give no verdict and no wake: $out"
  assert_grep "alpha" "$HOME_DIR/config/claude-seat" "a read cut short must never switch accounts"
  pass "every quota read one automatic pass makes stays inside the watcher's per-check budget"
}

test_the_watch_never_switches_on_an_unreadable_active_quota() {
  local rec out
  rec=$(make_seat_case auto-unreadable)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/alpha" "$SEATS_DIR/beta"
  seat_logged_in "$SPEC_DIR" "$SEATS_DIR/alpha" "$SEATS_DIR/beta"
  printf 'alpha\n' > "$HOME_DIR/config/claude-seat"
  run_seat "$HOME_DIR" "$FAKEBIN" threshold 15 >/dev/null
  seat_quota_unreadable "$SPEC_DIR" "$SEATS_DIR/alpha"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" auto)
  [ -z "$out" ] || fail "an unreadable active quota must not wake firstmate on every poll: $out"
  assert_grep "alpha" "$HOME_DIR/config/claude-seat" "an unreadable active quota must never switch accounts"
  pass "the watch switches nothing when the active seat's quota gives no verdict"
}

test_arm_registers_a_repeating_watch_and_retire_removes_it() {
  local rec out shim
  rec=$(make_seat_case auto-arm)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/alpha" "$SEATS_DIR/beta"
  seat_logged_in "$SPEC_DIR" "$SEATS_DIR/alpha" "$SEATS_DIR/beta"
  printf 'alpha\n' > "$HOME_DIR/config/claude-seat"
  shim="$HOME_DIR/state/claude-seat.check.sh"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" arm)
  expect_code 1 "$?" "arming with no trigger configured must refuse"
  assert_contains "$out" "no auto-switch threshold configured" "the refusal must name the missing setting"
  assert_absent "$shim" "a refused arm must register nothing"

  run_seat "$HOME_DIR" "$FAKEBIN" threshold 15 >/dev/null
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" arm)
  expect_code 0 "$?" "arming with a trigger and a destination should succeed: $out"
  assert_contains "$out" "keeps watching after each switch" \
    "arming must say the watch is repeating rather than one-shot"
  [ -f "$shim" ] || fail "arm must write the check shim"
  [ -f "$HOME_DIR/state/claude-seat.check-trust" ] || fail "arm must bind the shim's bytes"
  assert_grep "auto" "$shim" "the shim must dispatch the automatic pass"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" status)
  assert_contains "$out" "auto-switch watch: armed" "status must report the armed watch"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" retire)
  expect_code 0 "$?" "retiring should succeed"
  assert_absent "$shim" "retire must remove the shim"
  assert_absent "$HOME_DIR/state/claude-seat.check-trust" "retire must remove the trust binding"
  assert_absent "$HOME_DIR/state/.claude-seat-auto" "retire must remove the de-dupe record"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" status)
  assert_contains "$out" "auto-switch watch: not armed" "status must report the retired watch"
  pass "arm registers a repeating watch the watcher can run, and retire removes it cleanly"
}

test_status_reports_every_automatic_setting_in_percent_left() {
  local rec out
  rec=$(make_seat_case auto-status)
  read_seat_case "$rec"
  seat_logged_in "$SPEC_DIR" '(default)'
  run_seat "$HOME_DIR" "$FAKEBIN" threshold 15 >/dev/null
  run_seat "$HOME_DIR" "$FAKEBIN" destination-min 30 >/dev/null
  run_seat "$HOME_DIR" "$FAKEBIN" extra-usage allow 25 >/dev/null

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" status)
  assert_contains "$out" "auto-switch trigger: at or below 15% left on the active seat" \
    "the trigger must be reported in percent left"
  assert_contains "$out" "destination minimum: only switch to a seat above 30% left" \
    "the destination minimum must be reported in percent left"
  # shellcheck disable=SC2016  # literal dollar signs in the expected output, not expansions
  assert_contains "$out" 'extra-usage policy: allow up to $25' \
    "the extra-usage policy must be reported with its dollar cap"
  pass "status reports all three automatic settings, every percentage counting percent left"
}

test_a_stop_policy_holds_a_fresh_claude_spawn_and_the_override_gets_through() {
  local rec id out spec
  id=seat-hold-1
  rec=$(spawn_case spawn-extra-usage-hold "$id")
  read_spawn_case "$rec"
  spec="$CASE_DIR/quota-spec"
  make_quota_fake "$FAKEBIN" "$spec"
  mkdir -p "$SEATS_DIR/alpha"
  printf '%s\n' "$SEATS_DIR/alpha" > "$spec/oauth"
  printf 'alpha\n' > "$HOME_DIR/config/claude-seat"
  # The active seat's plan quota is gone, so any new worker would run on paid
  # extra usage.
  printf '%s\t0\n' "$SEATS_DIR/alpha" > "$spec/remaining_map"
  printf 'stop\n' > "$HOME_DIR/config/claude-seat-extra-usage"

  out=$(run_spawn_here "$HOME_DIR" "$WT_DIR" "$FAKEBIN" "$LAUNCH_LOG" "$id" "$PROJ_DIR" 2>&1)
  expect_code 1 "$?" "a fresh claude spawn must be held once the seat has no plan quota left"
  assert_contains "$out" "holds new Claude work" "the refusal must say the work was held, not that it failed"
  assert_contains "$out" "the extra-usage policy is stop" "the refusal must give the reason the gate held it"
  assert_contains "$out" "--ignore-seat-hold" "the refusal must name the override"
  assert_absent "$HOME_DIR/state/$id.meta" "a held spawn must create no task record"
  [ ! -s "$LAUNCH_LOG" ] || fail "a held spawn must launch nothing: $(cat "$LAUNCH_LOG")"

  out=$(run_spawn_here "$HOME_DIR" "$WT_DIR" "$FAKEBIN" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --ignore-seat-hold 2>&1)
  expect_code 0 "$?" "--ignore-seat-hold must start the task anyway: $out"
  assert_grep "claude_seat=" "$HOME_DIR/state/$id.meta" "the overridden spawn must record its seat as any other does"
  assert_grep "stop" "$HOME_DIR/config/claude-seat-extra-usage" \
    "the override must change no setting, so the next spawn is gated again"
  pass "a stop policy holds a fresh claude spawn, names the override, and changes nothing when overridden"
}

test_the_spawn_gate_holds_at_the_cap_and_on_an_unreadable_quota() {
  local rec id out spec
  id=seat-hold-cap-1
  rec=$(spawn_case spawn-extra-usage-cap "$id")
  read_spawn_case "$rec"
  spec="$CASE_DIR/quota-spec"
  make_quota_fake "$FAKEBIN" "$spec"
  mkdir -p "$SEATS_DIR/alpha"
  printf '%s\n' "$SEATS_DIR/alpha" > "$spec/oauth"
  printf 'alpha\n' > "$HOME_DIR/config/claude-seat"
  printf '%s\t0\n' "$SEATS_DIR/alpha" > "$spec/remaining_map"
  printf '%s\t25\n' "$SEATS_DIR/alpha" > "$spec/extra_map"
  printf 'allow 25\n' > "$HOME_DIR/config/claude-seat-extra-usage"

  out=$(run_spawn_here "$HOME_DIR" "$WT_DIR" "$FAKEBIN" "$LAUNCH_LOG" "$id" "$PROJ_DIR" 2>&1)
  expect_code 1 "$?" "a fresh claude spawn must be held once extra-usage spend reaches the cap"
  # shellcheck disable=SC2016  # literal dollar signs in the expected output, not expansions
  assert_contains "$out" 'at or over the $25 cap' "the spawn refusal must name the cap it reached"
  assert_absent "$HOME_DIR/state/$id.meta" "a held spawn must create no task record"

  printf '%s\n' "$SEATS_DIR/alpha" > "$spec/unreadable_quota"
  out=$(run_spawn_here "$HOME_DIR" "$WT_DIR" "$FAKEBIN" "$LAUNCH_LOG" "$id" "$PROJ_DIR" 2>&1)
  expect_code 1 "$?" "a fresh claude spawn must be held when the quota gives no verdict"
  assert_contains "$out" "makes no guess" "the spawn refusal must say it refused to guess"

  rm -f "$spec/unreadable_quota"
  printf '%s\t10\n' "$SEATS_DIR/alpha" > "$spec/extra_map"
  out=$(run_spawn_here "$HOME_DIR" "$WT_DIR" "$FAKEBIN" "$LAUNCH_LOG" "$id" "$PROJ_DIR" 2>&1)
  expect_code 0 "$?" "spend under the cap must let the spawn through: $out"
  pass "the spawn gate holds at the dollar cap and on an unreadable quota, and dispatches under the cap"
}

test_a_hold_never_blocks_a_relaunch_or_another_harness() {
  local rec id out spec
  id=seat-hold-relaunch-1
  rec=$(spawn_case spawn-extra-usage-relaunch "$id")
  read_spawn_case "$rec"
  spec="$CASE_DIR/quota-spec"
  make_quota_fake "$FAKEBIN" "$spec"
  fm_fake_exit0 "$FAKEBIN" claude
  mkdir -p "$SEATS_DIR/alpha"
  printf '%s\n' "$SEATS_DIR/alpha" > "$spec/oauth"
  printf 'alpha\n' > "$HOME_DIR/config/claude-seat"
  printf '%s\t80\n' "$SEATS_DIR/alpha" > "$spec/remaining_map"

  # Launch the task while the seat is healthy, then exhaust it.
  out=$(run_spawn_here "$HOME_DIR" "$WT_DIR" "$FAKEBIN" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  expect_code 0 "$?" "precondition: a spawn on a healthy seat should succeed: $out"
  printf '%s\t0\n' "$SEATS_DIR/alpha" > "$spec/remaining_map"
  printf 'stop\n' > "$HOME_DIR/config/claude-seat-extra-usage"
  make_dead_endpoint_tmux "$FAKEBIN" "fm-$id"
  : > "$LAUNCH_LOG"

  # A relaunch is recovery of work already under way, not work being started.
  # Holding it would strand a task mid-flight over a decision its own launch
  # already made.
  out=$(CLAUDE_CONFIG_DIR='' FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN" "$id" --relaunch 2>&1)
  expect_code 0 "$?" "a relaunch must never be held by the extra-usage policy: $out"
  [ -s "$LAUNCH_LOG" ] || fail "the relaunch must actually launch"
  pass "the dispatch hold covers fresh claude spawns only and never strands a task already under way"
}

test_a_non_claude_spawn_is_never_held_by_the_claude_policy() {
  local rec id out spec
  id=seat-hold-codex-1
  rec=$(spawn_case spawn-extra-usage-codex "$id")
  read_spawn_case "$rec"
  spec="$CASE_DIR/quota-spec"
  make_quota_fake "$FAKEBIN" "$spec"
  mkdir -p "$SEATS_DIR/alpha"
  printf '%s\n' "$SEATS_DIR/alpha" > "$spec/oauth"
  printf 'alpha\n' > "$HOME_DIR/config/claude-seat"
  printf '%s\t0\n' "$SEATS_DIR/alpha" > "$spec/remaining_map"
  printf 'stop\n' > "$HOME_DIR/config/claude-seat-extra-usage"

  out=$(run_spawn_here "$HOME_DIR" "$WT_DIR" "$FAKEBIN" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness codex 2>&1)
  expect_code 0 "$?" "a worker on another harness reads no Claude profile and must never be held: $out"
  assert_no_grep "claude_seat=" "$HOME_DIR/state/$id.meta" "a non-claude spawn must still record no Claude seat"
  pass "the Claude extra-usage hold never reaches a worker on another harness"
}

test_absent_setting_is_the_default_seat
test_switch_to_logged_in_seat_updates_only_the_setting
test_switch_to_seat_that_is_not_logged_in_is_refused
test_forced_switch_cannot_override_a_proven_negative
test_rate_limited_seat_is_undecided_and_forceable
test_unreadable_store_is_undecided_and_force_may_cross_it
test_forced_switch_refuses_a_seat_with_no_profile_directory
test_switch_back_to_default_clears_the_setting
test_switch_reaches_running_local_secondmate_homes
test_failed_secondmate_push_does_not_undo_the_switch
test_a_declining_home_keeps_its_own_seat_through_a_switch
test_a_switch_still_reaches_every_home_that_did_not_decline
test_status_names_every_local_home_that_declined
test_a_non_file_decline_flag_still_declines
test_remote_route_never_receives_seat_settings
test_switch_never_contacts_remote_routes
test_config_push_without_local_only_still_reaches_remote_routes
test_threshold_is_configurable_and_absent_by_default
test_threshold_reached_is_edge_triggered_by_the_configured_percent
test_unreadable_quota_never_reports_the_threshold_reached
test_model_scoped_window_alone_does_not_trip_the_threshold
test_default_seat_probes_the_ambient_profile_workers_get
test_an_unconfigured_home_reads_no_candidate_quota_and_holds_nothing
test_dispatch_gate_needs_no_quota_reader_when_unconfigured
test_destination_minimum_is_configurable_validated_and_clearable
test_a_switch_skips_a_seat_below_the_destination_minimum
test_no_switch_happens_when_no_seat_clears_the_destination_minimum
test_an_unreadable_candidate_quota_is_skipped_and_never_guessed
test_extra_usage_policy_is_configurable_validated_and_clearable
test_stop_policy_holds_dispatch_only_once_the_plan_quota_is_gone
test_allow_policy_proceeds_under_the_cap_and_holds_at_it
test_an_unreadable_quota_holds_dispatch_rather_than_guessing
test_the_watch_keeps_firing_across_crossings_and_never_twice_on_one
test_the_watch_reports_the_policy_consequence_when_no_seat_qualifies
test_the_watch_and_status_agree_while_plan_quota_remains
test_the_watch_switches_once_a_candidate_recovers_after_a_crossing_with_nowhere_to_go
test_the_watch_keeps_every_quota_read_inside_the_check_budget
test_the_watch_never_switches_on_an_unreadable_active_quota
test_arm_registers_a_repeating_watch_and_retire_removes_it
test_status_reports_every_automatic_setting_in_percent_left
test_rotation_picks_the_next_logged_in_seat
test_rotation_never_targets_the_default_profile
test_rotation_reads_the_seat_set_fresh
test_rotation_refuses_when_there_is_nowhere_to_go
test_add_creates_the_profile_directory_without_touching_credentials
test_a_directory_named_default_is_not_offered_as_a_seat
test_seat_names_that_escape_the_seats_root_are_refused
test_spawn_without_a_seat_sets_no_config_dir
test_spawn_uses_the_active_seat_and_records_it
test_switching_seats_does_not_move_a_running_worker
test_a_later_spawn_uses_the_new_seat_while_the_old_task_keeps_its_own
test_ambient_config_dir_still_reaches_workers_when_no_seat_is_set
test_active_seat_overrides_the_ambient_config_dir
test_non_claude_spawn_records_no_seat
test_account_pin_and_active_seat_refuse_the_spawn
test_account_pin_and_recorded_seat_refuse_the_relaunch
test_pin_only_home_still_relaunches_a_claude_task
test_pin_at_a_seat_directory_still_relaunches_a_claude_task
test_a_stop_policy_holds_a_fresh_claude_spawn_and_the_override_gets_through
test_the_spawn_gate_holds_at_the_cap_and_on_an_unreadable_quota
test_a_hold_never_blocks_a_relaunch_or_another_harness
test_a_non_claude_spawn_is_never_held_by_the_claude_policy

echo "# all fm-seat tests passed"
