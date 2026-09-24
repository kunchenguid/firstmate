#!/usr/bin/env bash
# Behavior tests for bin/fm-seat-board.sh: the read-only local page that shows
# quota-axi's report for every Claude seat.
#
# Every test here runs against `render`, which prints the generated page once
# and exits with no server and no port. There is no network and no real Claude
# account: a fake quota-axi on PATH supplies each case's report, exactly as
# tests/fm-seat.test.sh does for bin/fm-seat.sh itself.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

BOARD="$ROOT/bin/fm-seat-board.sh"
TMP_ROOT=$(fm_test_tmproot fm-seat-board)

# expect_grep <pattern> <text> <msg>: fixed-string grep must match somewhere in <text>.
expect_grep() {
  printf %s "$2" | grep -F -- "$1" >/dev/null || fail "$3"
}

# make_board_quota_fake <fakebin>
# A fake quota-axi whose verdict per profile directory is driven by files the
# test writes into the fakebin's own directory:
#   oauth        newline-separated CLAUDE_CONFIG_DIR values that are logged in
#   email_map    "<CLAUDE_CONFIG_DIR><TAB><email>" rows for a logged-in profile
#   remaining_map "<CLAUDE_CONFIG_DIR><TAB><percent>" rows for the session window
#   extra_map    "<CLAUDE_CONFIG_DIR><TAB><spentUsd>" rows adding an
#                extra_usage window
# A profile named in neither oauth nor a rate_limited list falls through to an
# "unavailable" report, exactly like a seat that was never logged into.
make_board_quota_fake() {
  local fakebin=$1 spec="$1/quota-spec"
  mkdir -p "$spec"
  cat > "$fakebin/quota-axi" <<SH
#!/usr/bin/env bash
set -u
spec="$spec"
key="\${CLAUDE_CONFIG_DIR:-}"
[ -n "\$key" ] || key='(default)'
email=\$(awk -F'\t' -v k="\$key" '\$1==k{print \$2; exit}' "\$spec/email_map" 2>/dev/null)
remaining=\$(awk -F'\t' -v k="\$key" '\$1==k{print \$2; exit}' "\$spec/remaining_map" 2>/dev/null)
[ -n "\$remaining" ] || remaining=80
windows="[{\\"id\\":\\"five_hour\\",\\"label\\":\\"session\\",\\"percentRemaining\\":\$remaining,\\"resetsAt\\":\\"2026-01-02T00:00:00Z\\"}]"
spent=\$(awk -F'\t' -v k="\$key" '\$1==k{print \$2; exit}' "\$spec/extra_map" 2>/dev/null)
if [ -n "\$spent" ]; then
  windows=\$(printf '%s' "\$windows" | sed 's/]\$/,{"id":"extra_usage","kind":"credits","percentUsed":1,"spentUsd":'"\$spent"',"limitUsd":100}]/')
fi
if [ -f "\$spec/rate_limited" ] && grep -Fxq "\$key" "\$spec/rate_limited"; then
  cat <<JSON
{"generatedAt":"2026-01-01T00:00:00Z","schemaVersion":5,"providers":[{"provider":"claude","label":"Claude","source":"unavailable","windows":[],"state":{"status":"rate_limited","error":"Claude quota endpoint rate limited"},"attempts":[],"quotaSemantics":{"status":"unknown","effectiveAvailability":[]}}]}
JSON
  exit 1
fi
if [ -f "\$spec/oauth" ] && grep -Fxq "\$key" "\$spec/oauth"; then
  cat <<JSON
{"generatedAt":"2026-01-01T00:00:00Z","schemaVersion":5,"providers":[{"provider":"claude","label":"Claude","source":"oauth","account":{"email":"\$email"},"windows":\$windows,"quotaSemantics":{"status":"known","effectiveAvailability":[]}}]}
JSON
  exit 0
fi
cat <<JSON
{"generatedAt":"2026-01-01T00:00:00Z","schemaVersion":5,"providers":[{"provider":"claude","label":"Claude","source":"unavailable","windows":[],"state":{"status":"error","error":"credentials_missing"},"attempts":[],"quotaSemantics":{"status":"unknown","effectiveAvailability":[]}}]}
JSON
exit 1
SH
  chmod +x "$fakebin/quota-axi"
  printf '%s\n' "$spec"
}

# make_board_case <name>
# A home with its own seats root, cache dir, and fake quota-axi. Echoes a
# record: case_dir|home|seats|fakebin|spec
make_board_case() {
  local name=$1 case_dir home seats fakebin spec
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  seats="$case_dir/seats"
  mkdir -p "$home/config" "$home/state" "$home/data" "$seats"
  fakebin=$(fm_fakebin "$case_dir")
  spec=$(make_board_quota_fake "$fakebin")
  printf '%s\n' "$seats" > "$home/config/claude-seats-root"
  printf '%s\n' "$case_dir|$home|$seats|$fakebin|$spec"
}

read_board_case() {
  IFS='|' read -r CASE_DIR HOME_DIR SEATS_DIR FAKEBIN SPEC_DIR <<EOF
$1
EOF
}

# run_board <home> <fakebin> <cache-dir> [args...]
# firstmate's own ambient CLAUDE_CONFIG_DIR is pinned empty and every read goes
# through a per-test cache directory so no test shares another's cache.
run_board() {
  local home=$1 fakebin=$2 cache=$3
  shift 3
  FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" CLAUDE_CONFIG_DIR="" \
    FM_SEAT_BOARD_CACHE_DIR="$cache" FM_SEAT_BOARD_CACHE_SECONDS=60 \
    PATH="$fakebin:$PATH" "$BOARD" render 2>&1
}

test_render_shows_the_default_seat_and_marks_it_active() {
  local rec out
  rec=$(make_board_case default-seat)
  read_board_case "$rec"
  printf '(default)\tdefault@example.test\n' > "$SPEC_DIR/email_map"
  printf '(default)\n' > "$SPEC_DIR/oauth"

  out=$(run_board "$HOME_DIR" "$FAKEBIN" "$CASE_DIR/cache")
  expect_grep 'default@example.test' "$out" "the default seat's account email must appear"
  expect_grep 'active for new workers' "$out" "the default seat is active for new workers when no seat is configured"
  pass "render shows the default seat and marks it active"
}

test_render_lists_a_named_seat_with_its_windows_and_extra_usage() {
  local rec out
  rec=$(make_board_case named-seat)
  read_board_case "$rec"
  mkdir -p "$SEATS_DIR/alpha"
  printf '%s\talpha@example.test\n' "$SEATS_DIR/alpha" > "$SPEC_DIR/email_map"
  printf '%s\n' "$SEATS_DIR/alpha" > "$SPEC_DIR/oauth"
  printf '%s\t63\n' "$SEATS_DIR/alpha" > "$SPEC_DIR/remaining_map"
  printf '%s\t12.5\n' "$SEATS_DIR/alpha" > "$SPEC_DIR/extra_map"

  out=$(run_board "$HOME_DIR" "$FAKEBIN" "$CASE_DIR/cache")
  expect_grep '<h2>alpha</h2>' "$out" "the named seat's own heading must appear"
  expect_grep 'alpha@example.test' "$out" "the named seat's account email must appear"
  expect_grep '63%' "$out" "the named seat's percent left must appear"
  expect_grep 'extra usage: $12.5' "$out" "the named seat's extra-usage spend must appear"
  pass "render lists a named seat with its windows and extra-usage spend"
}

test_render_shows_an_attention_line_for_a_seat_that_is_not_logged_in() {
  local rec out
  rec=$(make_board_case not-logged-in)
  read_board_case "$rec"
  mkdir -p "$SEATS_DIR/bravo"

  out=$(run_board "$HOME_DIR" "$FAKEBIN" "$CASE_DIR/cache")
  expect_grep '<h2>bravo</h2>' "$out" "a never-logged-in named seat still gets its own section"
  expect_grep 'class="attention"' "$out" "an unlogged-in seat must show an attention line"
  pass "render shows an attention line for a seat that is not logged in"
}

test_render_shows_a_rate_limited_seats_error_as_is() {
  local rec out
  rec=$(make_board_case rate-limited)
  read_board_case "$rec"
  mkdir -p "$SEATS_DIR/charlie"
  printf '%s\n' "$SEATS_DIR/charlie" > "$SPEC_DIR/rate_limited"

  out=$(run_board "$HOME_DIR" "$FAKEBIN" "$CASE_DIR/cache")
  expect_grep 'Claude quota endpoint rate limited' "$out" \
    "the rate-limit error quota-axi reports must be shown as-is"
  pass "render shows a rate-limited seat's error as-is"
}

test_a_reload_within_the_cache_window_does_not_read_quota_axi_again() {
  local rec out
  rec=$(make_board_case cached-reload)
  read_board_case "$rec"
  printf '(default)\tcached@example.test\n' > "$SPEC_DIR/email_map"
  printf '(default)\n' > "$SPEC_DIR/oauth"

  out=$(run_board "$HOME_DIR" "$FAKEBIN" "$CASE_DIR/cache")
  expect_grep 'cached@example.test' "$out" "the first render must read the seat"

  # A second render within the cache window must reuse the cache file rather
  # than shelling out to quota-axi again: replacing the fake with one that
  # always fails proves no further read was attempted.
  rm -f "$FAKEBIN/quota-axi"
  cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
exit 9
SH
  chmod +x "$FAKEBIN/quota-axi"

  out=$(run_board "$HOME_DIR" "$FAKEBIN" "$CASE_DIR/cache")
  expect_grep 'cached@example.test' "$out" \
    "a reload within the cache window must reuse the cached report, not fail"
  pass "a reload within the cache window does not read quota-axi again"
}

test_serve_prints_127_0_0_1_only_and_never_0_0_0_0() {
  assert_grep '127.0.0.1' "$BOARD" "the serve path must bind 127.0.0.1"
  assert_no_grep '0.0.0.0' "$BOARD" "the serve path must never bind 0.0.0.0"
  pass "the script binds 127.0.0.1 only and never 0.0.0.0"
}

test_serve_never_invokes_allow_keychain_prompt() {
  assert_no_grep '--allow-keychain-prompt ' "$BOARD" \
    "the board must never pass --allow-keychain-prompt to quota-axi"
  assert_grep 'fm_seat_quota_read' "$BOARD" \
    "every quota read must go through fm-seat-lib.sh's own --no-credential-refresh read"
  pass "the script never invokes --allow-keychain-prompt and reads through fm_seat_quota_read"
}

test_render_shows_the_default_seat_and_marks_it_active
test_render_lists_a_named_seat_with_its_windows_and_extra_usage
test_render_shows_an_attention_line_for_a_seat_that_is_not_logged_in
test_render_shows_a_rate_limited_seats_error_as_is
test_a_reload_within_the_cache_window_does_not_read_quota_axi_again
test_serve_prints_127_0_0_1_only_and_never_0_0_0_0
test_serve_never_invokes_allow_keychain_prompt

echo "# all fm-seat-board tests passed"
