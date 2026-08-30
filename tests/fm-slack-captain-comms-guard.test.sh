#!/usr/bin/env bash
# Captain-facing Slack post size guard: boundary, operator-owned caps, over-cap
# refusal and non-delivery, --long, and fail-open. Hermetic via the shared
# fakebin curl; jq stays real.
set -u

# shellcheck source=tests/slack-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/slack-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-slack-captain-comms-guard)

# A home plus its fake curl, with the real client's argv log armed so a case can
# assert which Slack methods the run actually reached. Echoes the fakebin dir.
setup_case() {
  local home=$1
  make_home "$home"
  : > "$home/curl.log"
  make_fake_curl "$home/fake"
}

# run_post is a shell function, so the log path must be exported rather than
# passed as a command prefix for the real client to inherit it.
post() {
  local home=$1 fakebin=$2 rc
  shift 2
  export FM_SLACK_CURL_LOG="$home/curl.log"
  run_post "$home" "$fakebin" "$@" >"$home/out" 2>"$home/post.err"
  rc=$?
  unset FM_SLACK_CURL_LOG
  return "$rc"
}

set_cap() {
  local home=$1 name=$2 value=$3
  printf '%s\n' "$value" > "$home/config/slack-captain-comms-$name"
  chmod 600 "$home/config/slack-captain-comms-$name"
}

assert_delivered() {
  local home=$1 what=$2
  grep -Eq 'method=(chat.postMessage|chat.update) ' "$home/curl.log" \
    || fail "$what must reach Slack: $(cat "$home/curl.log")"
}

assert_not_delivered() {
  local home=$1 what=$2
  ! grep -Eq 'method=(chat.postMessage|chat.update) ' "$home/curl.log" \
    || fail "$what must not reach Slack: $(cat "$home/curl.log")"
}

lines_text() {
  local n=$1 i
  for i in $(seq 1 "$n"); do
    printf 'line%d\n' "$i"
  done
}

chars_text() {
  local n=$1
  head -c "$n" /dev/zero | tr '\0' 'x'
}

# n multi-byte characters: one 4-byte emoji each, so a byte count would be 4n.
wide_chars_text() {
  local n=$1 i
  for ((i = 0; i < n; i++)); do
    printf '\xf0\x9f\x8e\x89'
  done
}

# --- boundary: at the cap passes --------------------------------------------

home="$TMP_ROOT/boundary-lines"
fakebin=$(setup_case "$home")
post "$home" "$fakebin" message "$(lines_text 12)" \
  || fail "12-line captain message at lines cap must pass: $(cat "$home/post.err")"
assert_delivered "$home" "a captain message at the lines cap"
pass "captain message at lines cap passes and is delivered"

home="$TMP_ROOT/boundary-chars"
fakebin=$(setup_case "$home")
post "$home" "$fakebin" message "$(chars_text 1200)" \
  || fail "1200-character captain message at characters cap must pass: $(cat "$home/post.err")"
assert_delivered "$home" "a captain message at the characters cap"
pass "captain message at characters cap passes and is delivered"

# The cap counts characters, not bytes: 1200 emoji are 4800 bytes and must pass.
home="$TMP_ROOT/boundary-multibyte"
fakebin=$(setup_case "$home")
post "$home" "$fakebin" message "$(wide_chars_text 1200)" \
  || fail "1200 multi-byte characters must pass a 1200-character cap: $(cat "$home/post.err")"
assert_delivered "$home" "a multi-byte captain message at the characters cap"
pass "characters cap counts characters, not bytes"

home="$TMP_ROOT/over-multibyte"
fakebin=$(setup_case "$home")
if post "$home" "$fakebin" message "$(wide_chars_text 1201)"; then
  fail "1201 multi-byte characters must refuse over a 1200-character cap"
fi
grep -Fq '(1201 > 1200)' "$home/post.err" \
  || fail "multi-byte refusal must report the character count: $(cat "$home/post.err")"
assert_not_delivered "$home" "a multi-byte captain message over the characters cap"
pass "characters cap counts multi-byte text in characters when over the cap"

# --- over cap: refuses, names the cap, and does not deliver ------------------

home="$TMP_ROOT/over-lines"
fakebin=$(setup_case "$home")
if post "$home" "$fakebin" message "$(lines_text 13)"; then
  fail "13-line captain message over lines cap must refuse"
fi
grep -Fq 'lines cap' "$home/post.err" \
  || fail "over-lines refusal must name the lines cap: $(cat "$home/post.err")"
assert_not_delivered "$home" "a captain message over the lines cap"
pass "captain message over lines cap refuses, names the cap, and is not delivered"

home="$TMP_ROOT/over-chars"
fakebin=$(setup_case "$home")
if post "$home" "$fakebin" message "$(chars_text 1201)"; then
  fail "1201-character captain message over characters cap must refuse"
fi
grep -Fq 'characters cap' "$home/post.err" \
  || fail "over-chars refusal must name the characters cap: $(cat "$home/post.err")"
assert_not_delivered "$home" "a captain message over the characters cap"
pass "captain message over characters cap refuses, names the cap, and is not delivered"

home="$TMP_ROOT/over-lines-update"
fakebin=$(setup_case "$home")
if post "$home" "$fakebin" update 1786735224.690829 "$(lines_text 13)"; then
  fail "13-line captain update over lines cap must refuse"
fi
assert_not_delivered "$home" "a captain update over the lines cap"
pass "captain update over lines cap refuses and is not delivered"

# --- operator-owned caps -----------------------------------------------------

home="$TMP_ROOT/config-raises-lines"
fakebin=$(setup_case "$home")
set_cap "$home" lines 20
post "$home" "$fakebin" message "$(lines_text 20)" \
  || fail "operator-raised lines cap must admit a 20-line message: $(cat "$home/post.err")"
assert_delivered "$home" "a 20-line message under an operator-raised lines cap"
pass "operator-owned lines cap raises the built-in default"

home="$TMP_ROOT/config-lowers-chars"
fakebin=$(setup_case "$home")
set_cap "$home" chars 50
if post "$home" "$fakebin" message "$(chars_text 60)"; then
  fail "operator-lowered characters cap must refuse a 60-character message"
fi
grep -Fq '(60 > 50)' "$home/post.err" \
  || fail "refusal must name the operator-owned characters cap: $(cat "$home/post.err")"
assert_not_delivered "$home" "a 60-character message over an operator-lowered characters cap"
pass "operator-owned characters cap lowers the built-in default"

# Each cap file is independent: a raised lines cap leaves the characters default.
home="$TMP_ROOT/config-independent"
fakebin=$(setup_case "$home")
set_cap "$home" lines 20
if post "$home" "$fakebin" message "$(chars_text 1201)"; then
  fail "raising only the lines cap must leave the built-in characters default in force"
fi
grep -Fq '(1201 > 1200)' "$home/post.err" \
  || fail "unset characters cap must keep its built-in default: $(cat "$home/post.err")"
pass "each cap file is independent of the other"

# --- malformed config falls back to the built-in default --------------------

home="$TMP_ROOT/malformed-config"
fakebin=$(setup_case "$home")
set_cap "$home" lines not-a-number
if post "$home" "$fakebin" message "$(lines_text 13)"; then
  fail "a malformed lines cap must fall back to the built-in default, not disable the guard"
fi
grep -Fq '(13 > 12)' "$home/post.err" \
  || fail "malformed cap file must fall back to the built-in default: $(cat "$home/post.err")"
assert_not_delivered "$home" "a message over the default lines cap with a malformed cap file"
pass "malformed cap file falls back to the built-in default"

# A symlinked cap file is followed to its target, so an operator can keep the
# file in a dotfiles checkout without the guard standing down.
home="$TMP_ROOT/config-symlinked"
fakebin=$(setup_case "$home")
mkdir -p "$home/dotfiles"
printf '3\n' > "$home/dotfiles/slack-comms-lines"
chmod 600 "$home/dotfiles/slack-comms-lines"
ln -s "$home/dotfiles/slack-comms-lines" "$home/config/slack-captain-comms-lines"
if post "$home" "$fakebin" message "$(lines_text 4)"; then
  fail "a symlinked cap file must stay in force, not stand the guard down"
fi
grep -Fq '(4 > 3)' "$home/post.err" \
  || fail "a symlinked cap file must apply its target's value: $(cat "$home/post.err")"
assert_not_delivered "$home" "a message over a symlinked lines cap"
pass "symlinked cap file is followed to its target and stays in force"

# --- --long escape ----------------------------------------------------------

home="$TMP_ROOT/long-escape"
fakebin=$(setup_case "$home")
post "$home" "$fakebin" --long "urgent status digest" message "$(lines_text 20)" \
  || fail "--long must allow an over-cap captain message: $(cat "$home/post.err")"
grep -Fq 'slack-captain-comms: --long override: urgent status digest' "$home/post.err" \
  || fail "--long must record the one-line reason on stderr: $(cat "$home/post.err")"
assert_delivered "$home" "an over-cap captain message sent with --long"
pass "captain message --long records reason, bypasses the guard, and delivers"

# The override record has to stay one greppable line whatever the sender typed.
home="$TMP_ROOT/long-multiline-reason"
fakebin=$(setup_case "$home")
post "$home" "$fakebin" --long "$(printf 'urgent\nsee thread')" message "$(lines_text 20)" \
  || fail "--long must allow an over-cap message with a multi-line reason: $(cat "$home/post.err")"
grep -Fq 'slack-captain-comms: --long override: urgent see thread' "$home/post.err" \
  || fail "--long must record a multi-line reason on one line: $(cat "$home/post.err")"
[ "$(grep -c '^slack-captain-comms: --long override: ' "$home/post.err")" = 1 ] \
  || fail "--long must record exactly one override line: $(cat "$home/post.err")"
[ "$(grep -c . "$home/post.err")" = 1 ] \
  || fail "--long must not leave a bare reason fragment on stderr: $(cat "$home/post.err")"
assert_delivered "$home" "an over-cap captain message sent with a multi-line --long reason"
pass "--long collapses a multi-line reason into one recorded line"

home="$TMP_ROOT/long-no-reason"
fakebin=$(setup_case "$home")
if post "$home" "$fakebin" --long; then
  fail "--long without a reason must be a usage error"
fi
grep -Fq -e '--long requires a one-line reason' "$home/post.err" \
  || fail "--long without a reason must say so: $(cat "$home/post.err")"
assert_not_delivered "$home" "a --long invocation with no reason"
pass "--long without a reason refuses as a usage error"

# --- exempt paths -----------------------------------------------------------

home="$TMP_ROOT/board-exempt"
fakebin=$(setup_case "$home")
post "$home" "$fakebin" board "$(lines_text 20)" \
  || fail "fleet board path must stay exempt from the captain message guard: $(cat "$home/post.err")"
assert_delivered "$home" "an over-cap fleet board message"
pass "fleet board path is exempt from the captain message guard"

# Exempt means the guard never runs, so a sender that reflexively prefixes
# --long still delivers and nothing is recorded about an override that never
# happened.
home="$TMP_ROOT/board-ignores-long"
fakebin=$(setup_case "$home")
post "$home" "$fakebin" --long "urgent status digest" board "$(lines_text 20)" \
  || fail "--long must not cost the exempt fleet board path its post: $(cat "$home/post.err")"
assert_delivered "$home" "an over-cap board message carrying --long"
[ ! -s "$home/post.err" ] \
  || fail "board must ignore --long silently: $(cat "$home/post.err")"
pass "fleet board path ignores --long instead of refusing delivery"

# A rollover snapshot posts through the same exempt board path as the live
# update, so an over-cap closed-date body must still deliver and --long must
# still be ignored silently rather than refused.
home="$TMP_ROOT/board-rollover-snapshot-exempt"
fakebin=$(setup_case "$home")
export FM_SLACK_BOARD_TODAY_OVERRIDE=2026-08-27
post "$home" "$fakebin" board "$(lines_text 20)" \
  || fail "rollover setup board post must succeed: $(cat "$home/post.err")"
export FM_SLACK_BOARD_TODAY_OVERRIDE=2026-08-28
post "$home" "$fakebin" board "today text" \
  || fail "rollover snapshot of an over-cap body must stay exempt from the captain message guard: $(cat "$home/post.err")"
[ "$(grep -c 'method=chat.postMessage ' "$home/curl.log")" -eq 2 ] \
  || fail "rollover snapshot of an over-cap body must still post: $(cat "$home/curl.log")"
pass "rollover snapshot path is exempt from the captain message guard"

home="$TMP_ROOT/board-rollover-snapshot-ignores-long"
fakebin=$(setup_case "$home")
export FM_SLACK_BOARD_TODAY_OVERRIDE=2026-08-27
post "$home" "$fakebin" board "$(lines_text 20)" \
  || fail "rollover setup board post must succeed: $(cat "$home/post.err")"
export FM_SLACK_BOARD_TODAY_OVERRIDE=2026-08-28
post "$home" "$fakebin" --long "urgent status digest" board "today text" \
  || fail "--long must not cost the rollover snapshot its post: $(cat "$home/post.err")"
[ "$(grep -c 'method=chat.postMessage ' "$home/curl.log")" -eq 2 ] \
  || fail "rollover snapshot carrying --long must still post: $(cat "$home/curl.log")"
[ ! -s "$home/post.err" ] \
  || fail "rollover snapshot must ignore --long silently: $(cat "$home/post.err")"
pass "rollover snapshot path ignores --long instead of refusing delivery"
unset FM_SLACK_BOARD_TODAY_OVERRIDE

# --- fail-open --------------------------------------------------------------
#
# Standing aside must be visible: an over-cap message that gets delivered because
# the guard could not do its job is indistinguishable from a passing one without
# the stand-down line, which is the evidence mechanism-health-auditor reads.

assert_stood_down() {
  local home=$1 reason=$2
  grep -Fq "slack-captain-comms: guard stood down: $reason" "$home/post.err" \
    || fail "standing aside must name the reason \"$reason\": $(cat "$home/post.err")"
}

home="$TMP_ROOT/fail-open-unreadable"
fakebin=$(setup_case "$home")
if [ "$(id -u)" -eq 0 ]; then
  pass "unreadable cap file fail-open case skipped as root"
else
  set_cap "$home" lines 12
  chmod 000 "$home/config/slack-captain-comms-lines"
  post "$home" "$fakebin" message "$(lines_text 20)" \
    || fail "an unreadable cap file must fail open and allow delivery: $(cat "$home/post.err")"
  assert_delivered "$home" "an over-cap message with an unreadable cap file"
  assert_stood_down "$home" "cannot read cap file $home/config/slack-captain-comms-lines"
  chmod 600 "$home/config/slack-captain-comms-lines"
  pass "unreadable cap file fails open, names the reason, and delivers"
fi

home="$TMP_ROOT/fail-open-dangling-symlink"
fakebin=$(setup_case "$home")
ln -s "$home/config/absent-cap-target" "$home/config/slack-captain-comms-lines"
post "$home" "$fakebin" message "$(lines_text 20)" \
  || fail "a dangling cap symlink must fail open and allow delivery: $(cat "$home/post.err")"
assert_delivered "$home" "an over-cap message with a dangling cap symlink"
assert_stood_down "$home" \
  "cap file $home/config/slack-captain-comms-lines is a dangling symlink"
pass "cap file the guard cannot read fails open, names the reason, and delivers"

home="$TMP_ROOT/fail-open-line-measure"
fakebin=$(setup_case "$home")
export FMS_CAPTAIN_COMMS_MEASURE_AWK=invalid-awk-path-not-a-command
post "$home" "$fakebin" message "$(lines_text 20)" \
  || fail "line measurement failure must fail open and allow delivery: $(cat "$home/post.err")"
assert_delivered "$home" "an over-cap message whose lines the guard could not count"
assert_stood_down "$home" 'cannot count message lines'
unset FMS_CAPTAIN_COMMS_MEASURE_AWK
pass "line measurement failure fails open, names the reason, and delivers"

# The character count is the second measurement, so a failing tr exercises the
# branch the awk seam above cannot reach. Delivery alone cannot tell standing
# aside apart from a fabricated count of 0, so both cases pin the stand-down line.
home="$TMP_ROOT/fail-open-char-measure"
fakebin=$(setup_case "$home")
printf '#!/usr/bin/env bash\nexit 3\n' > "$fakebin/tr"
chmod +x "$fakebin/tr"
post "$home" "$fakebin" message "$(chars_text 1201)" \
  || fail "character measurement failure must fail open and allow delivery: $(cat "$home/post.err")"
assert_delivered "$home" "an over-cap message whose characters the guard could not count"
assert_stood_down "$home" 'cannot count message characters'
pass "character measurement failure fails open, names the reason, and delivers"

# Only the UTF-8 stripping stage fails; every later stage succeeds, so a count
# is still produced. Without the whole pipeline's status the guard would read
# that count as 0 and admit an over-cap message while claiming it measured it.
home="$TMP_ROOT/fail-open-char-strip-stage"
fakebin=$(setup_case "$home")
real_tr=$(command -v tr)
cat > "$fakebin/tr" <<SH
#!/usr/bin/env bash
case " \$* " in
  *'\200-\277'*) exit 3 ;;
esac
exec $real_tr "\$@"
SH
chmod +x "$fakebin/tr"
post "$home" "$fakebin" message "$(chars_text 1201)" \
  || fail "a failed stripping stage must fail open and allow delivery: $(cat "$home/post.err")"
assert_delivered "$home" "an over-cap message whose stripping stage failed"
assert_stood_down "$home" 'cannot count message characters'
pass "a failed stripping stage stands the guard down instead of fabricating a count"
