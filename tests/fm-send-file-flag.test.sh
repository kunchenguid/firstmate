#!/usr/bin/env bash
# tests/fm-send-file-flag.test.sh - fm-send's --file message source.
#
# A steer drafted under data/steers/ must be deliverable without surviving a
# shell quoting round-trip, and the flag must never half-start a delivery:
# every invalid use (unreadable, blank, positional mix, --key) is refused
# BEFORE anything is recorded or typed. The content rides the same data planes
# as positional text, so each plane gets its own pinned boundary here: the
# INBOX plane records a multi-line or dash-leading file verbatim (records are
# durable, newlines are legal), while the TYPED plane refuses a multi-line file
# loudly before any keystroke, because it submits on every newline and would
# garble them into separate partial messages. Hermetic throughout: a stubbed
# tmux records every keystroke argument, and the durable record itself is read
# back as delivery evidence.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SEND="$ROOT/bin/fm-send.sh"

TMP_ROOT=$(fm_test_tmproot fm-send-file-flag)

make_stubs() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    printf '%s\n' "$@" >> "${FM_SEND_KEYS_LOG:?}"
    [ "${*: -1}" = Enter ] && : > "${FM_SENT_ONCE:?}"
    exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*|*pane_id*) printf '1\n'; exit 0 ;; esac; done
    exit 0 ;;
  capture-pane)
    printf '╭────╮\n│    │\n╰────╯\n'
    exit 0 ;;
  list-windows)
    case "$*" in
      *-a*) printf 'sess:win\n' ;;
      *) printf 'win\n' ;;
    esac
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
  printf '%s\n' "$fb"
}

# fresh_case <name>: echo a prepared case dir with state/sendfile.meta.
fresh_case() {
  local name=$1
  local dir="$TMP_ROOT/$name"
  mkdir -p "$dir/state"
  fm_write_meta "$dir/state/sendfile.meta" \
    "window=sess:win" "endpoint_task_id=sendfile" "harness=claude"
  printf '%s\n' "$dir"
}

# run_inbox <case-dir> <fakebin> [args...]: run fm-send against the fixture
# task selector, whose send rides the INBOX plane.
run_inbox() {
  local home=$1 fb=$2
  shift 2
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
    FM_SEND_KEYS_LOG="$home/keys.log" FM_SENT_ONCE="$home/sent-once" \
    FM_SEND_SETTLE=0 \
    "$SEND" fm-sendfile "$@" 2>"$home/stderr.log"
}

# run_typed <case-dir> <fakebin> [args...]: run fm-send against the explicit
# backend target, which always stays on the TYPED plane.
run_typed() {
  local home=$1 fb=$2
  shift 2
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
    FM_SEND_KEYS_LOG="$home/keys.log" FM_SENT_ONCE="$home/sent-once" \
    FM_SEND_SETTLE=0 \
    "$SEND" sess:win "$@" 2>"$home/stderr.log"
}

# newest_record <case-dir>: the one .msg written under the fixture inbox.
newest_record() {
  ls -1 "$1/state/sendfile.inbox/"*.msg 2>/dev/null | sort | tail -1
}

# record_body <case-dir>: everything past the three schema/at/-- header lines.
record_body() {
  local rec
  rec=$(newest_record "$1") || return 1
  sed '1,3d' "$rec"
}

# assert_no_record <case-dir> <label>: a refused send must not half-start a
# durable record either.
assert_no_record() {
  local dir=$1 label=$2
  [ -z "$(newest_record "$dir")" ] \
    || fail "$label: a refused --file send must write no inbox record"
}

# The literal payload of a send-keys invocation sits on log line 6: line 1
# records the command word itself, then [-t, target, -l, --, <text>].
payload_line() {
  sed -n '6p' "$1"
}

test_file_message_records_content_verbatim_on_inbox_plane() {
  local dir fb rc got rec
  dir=$(fresh_case happy); fb=$(make_stubs "$dir")
  f="$dir/steer.md"
  printf 'STEER vom Firstmate: magic-link-Rundlauf mit Verlustschutz pruefen.\n' > "$f"
  : > "$dir/keys.log"
  run_inbox "$dir" "$fb" --file "$f" >/dev/null; rc=$?
  expect_code 0 "$rc" "--file happy path exits 0"
  got=$(record_body "$dir")
  [ "$got" = 'STEER vom Firstmate: magic-link-Rundlauf mit Verlustschutz pruefen.' ] \
    || fail "--file content must be recorded verbatim, got '$got'"
  rec=$(newest_record "$dir")
  [ "$(sed -n 's/^schema=//p' "$rec")" = 'fm-task-inbox.v1' ] \
    || fail "the --file delivery must be a durable inbox record, got '$rec'"
  grep -q 'Firstmate instruction waiting' "$dir/keys.log" \
    || fail "the inbox plane must ring the constant doorbell, got '$(cat "$dir/keys.log")'"
  pass "fm-send --file: single-line file content recorded verbatim on the inbox plane"
}

test_file_trailing_newline_is_normalized() {
  local dir fb rc got
  dir=$(fresh_case trailing); fb=$(make_stubs "$dir")
  printf 'Zeile ohne Ueberraschung\n\n' > "$dir/steer.md"
  : > "$dir/keys.log"
  run_inbox "$dir" "$fb" --file "$dir/steer.md" >/dev/null; rc=$?
  expect_code 0 "$rc" "trailing-newline file exits 0"
  got=$(record_body "$dir")
  [ "$got" = 'Zeile ohne Ueberraschung' ] \
    || fail "trailing newlines should normalize away, got '$got'"
  pass "fm-send --file: trailing newline normalized away"
}

test_multiline_file_is_welcome_on_the_inbox_plane() {
  local dir fb rc got
  dir=$(fresh_case multiline-ok); fb=$(make_stubs "$dir")
  printf 'erste Zeile\nzweite Zeile\ndritte Zeile\n' > "$dir/steer.md"
  : > "$dir/keys.log"
  run_inbox "$dir" "$fb" --file "$dir/steer.md" >/dev/null; rc=$?
  expect_code 0 "$rc" "multi-line file rides the inbox plane"
  got=$(record_body "$dir")
  [ "$got" = 'erste Zeile
zweite Zeile
dritte Zeile' ] \
    || fail "multi-line record body mismatch, got '$got'"
  pass "fm-send --file: multi-line file recorded whole on the inbox plane"
}

test_missing_file_refuses_before_any_send() {
  local dir fb rc
  dir=$(fresh_case missing); fb=$(make_stubs "$dir")
  : > "$dir/keys.log"
  run_inbox "$dir" "$fb" --file "$dir/nope.md" >/dev/null; rc=$?
  [ "$rc" -ne 0 ] || fail "missing file must refuse"
  assert_grep "not a readable file" "$dir/stderr.log" "missing-file stderr"
  [ ! -s "$dir/keys.log" ] || fail "a refused --file send must type nothing"
  assert_no_record "$dir" "missing file"
  pass "fm-send --file: unreadable path refused before any send"
}

test_blank_file_refuses() {
  local dir fb rc
  dir=$(fresh_case blank); fb=$(make_stubs "$dir")
  printf '   \n' > "$dir/steer.md"
  : > "$dir/keys.log"
  run_inbox "$dir" "$fb" --file "$dir/steer.md" >/dev/null; rc=$?
  [ "$rc" -ne 0 ] || fail "blank file must refuse"
  assert_grep "blank" "$dir/stderr.log" "blank-file stderr"
  [ ! -s "$dir/keys.log" ] || fail "a refused blank --file must type nothing"
  assert_no_record "$dir" "blank file"
  pass "fm-send --file: blank file refused"
}

test_file_and_positional_text_refuse_together() {
  local dir fb rc
  dir=$(fresh_case mixed); fb=$(make_stubs "$dir")
  printf 'aus der Datei\n' > "$dir/steer.md"
  : > "$dir/keys.log"
  run_inbox "$dir" "$fb" --file "$dir/steer.md" 'positional Text' >/dev/null; rc=$?
  [ "$rc" -ne 0 ] || fail "--file plus positional text must refuse"
  assert_grep "positional" "$dir/stderr.log" "mixed stderr"
  [ ! -s "$dir/keys.log" ] || fail "a refused mixed send must type nothing"
  assert_no_record "$dir" "positional mix"
  pass "fm-send --file: positional text combination refused"
}

test_file_and_key_refuse_together() {
  local dir fb rc
  dir=$(fresh_case keyed); fb=$(make_stubs "$dir")
  printf 'aus der Datei\n' > "$dir/steer.md"
  : > "$dir/keys.log"
  run_inbox "$dir" "$fb" --file "$dir/steer.md" --key Enter >/dev/null; rc=$?
  [ "$rc" -ne 0 ] || fail "--file plus --key must refuse"
  assert_grep "cannot accompany --key" "$dir/stderr.log" "--key stderr"
  [ ! -s "$dir/keys.log" ] || fail "a refused --key/--file send must type nothing"
  assert_no_record "$dir" "--key mix"
  pass "fm-send --file: --key combination refused"
}

test_multiline_file_refuses_on_the_typed_plane_before_any_keystroke() {
  local dir fb rc
  dir=$(fresh_case multiline-typed); fb=$(make_stubs "$dir")
  printf 'erste Zeile\nzweite Zeile\n' > "$dir/steer.md"
  : > "$dir/keys.log"
  run_typed "$dir" "$fb" --file "$dir/steer.md" >/dev/null; rc=$?
  [ "$rc" -ne 0 ] || fail "multi-line file must refuse on the typed plane"
  assert_grep "multiple lines" "$dir/stderr.log" "typed multiline stderr"
  [ ! -s "$dir/keys.log" ] || fail "a refused typed multi-line --file must keystroke nothing"
  pass "fm-send --file: multi-line content refused on the typed plane before any keystroke"
}

test_dash_leading_content_is_recorded_verbatim_on_the_inbox_plane() {
  local dir fb rc got
  dir=$(fresh_case dashy-inbox); fb=$(make_stubs "$dir")
  f="$dir/steer.md"
  printf -- '--file /pfad/der/nie/eine/nachricht/sein/sollte.md\n' > "$f"
  : > "$dir/keys.log"
  run_inbox "$dir" "$fb" --file "$f" >/dev/null; rc=$?
  expect_code 0 "$rc" "--file with dash-leading content exits 0 on the inbox plane"
  got=$(record_body "$dir")
  [ "$got" = '--file /pfad/der/nie/eine/nachricht/sein/sollte.md' ] \
    || fail "dash-leading record body mismatch, got '$got'"
  pass "fm-send --file: dash-leading file content recorded verbatim on the inbox plane"
}

test_dash_leading_content_rides_behind_dash_dash_on_the_typed_plane() {
  local dir fb rc got
  dir=$(fresh_case dashy-typed); fb=$(make_stubs "$dir")
  f="$dir/steer.md"
  printf -- '--flagged-looking steer body\n' > "$f"
  : > "$dir/keys.log"
  run_typed "$dir" "$fb" --file "$f" >/dev/null; rc=$?
  expect_code 0 "$rc" "--file with dash-leading content exits 0 on the typed plane"
  got=$(payload_line "$dir/keys.log")
  [ "$got" = '--flagged-looking steer body' ] \
    || fail "dash-leading typed content must ride behind --, got '$got'"
  pass "fm-send --file: dash-leading file content delivered behind -- on the typed plane"
}

test_file_message_records_content_verbatim_on_inbox_plane
test_file_trailing_newline_is_normalized
test_multiline_file_is_welcome_on_the_inbox_plane
test_missing_file_refuses_before_any_send
test_blank_file_refuses
test_file_and_positional_text_refuse_together
test_file_and_key_refuse_together
test_multiline_file_refuses_on_the_typed_plane_before_any_keystroke
test_dash_leading_content_is_recorded_verbatim_on_the_inbox_plane
test_dash_leading_content_rides_behind_dash_dash_on_the_typed_plane
