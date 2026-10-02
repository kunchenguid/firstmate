#!/usr/bin/env bash
# fm-send native invocation submission (retired popup-settle regression).
#
# Some TUIs open a completion popup when terminal text is typed. Ordinary text
# submission now uses Herdr's native agent prompt API, so these cases must have
# no pre-submit sleep, terminal typing, or Enter retry. The historical filename
# remains stable for test inventory compatibility.
#
# The routing matrix distinguishes direct native invocations and
# explicit backend targets); a task-selector message that is not an invocation
# rides the durable inbox instead, where only the constant doorbell reaches the
# native prompt API:
#   /... and Codex $... -> direct native prompt
#   other task-selector text -> durable inbox plus native prompt doorbell
#   explicit target text -> direct native prompt
#
# Every case below passes a LITERAL `$<skill>` / `$price` message in single quotes
# on purpose - the whole point is to send an unexpanded `$...` line to the agent -
# so SC2016 (which flags single-quoted `$` as a probably-forgotten expansion) is a
# false positive here and is disabled file-wide.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/fixtures.sh
. "$ROOT/tests/fixtures.sh"

SEND="$ROOT/bin/fm-send.sh"

TMP_ROOT=$(fm_test_tmproot fm-send-popup-settle)

# A fake Herdr CLI captures native prompt bytes, while fake sleep records any
# obsolete pre-submit delay so the test can reject it.
make_stubs() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  fm_test_fake_herdr_send "$fb"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${1:-}" >> "$FM_SLEEP_LOG"
exit 0
SH
  chmod +x "$fb/sleep"
  printf '%s\n' "$fb"
}

native_direct() {  # <label> <harness|--explicit> <message> [selector-form]
  local label=$1 harness=$2 msg=$3
  local selector_form=${4:-legacy}
  local dir fb log send_log home target rc meta_id
  dir="$TMP_ROOT/case-$RANDOM"; mkdir -p "$dir/state"
  fb=$(make_stubs "$dir"); log="$dir/sleep.log"; send_log="$dir/send.log"; home="$dir"
  if [ "$harness" = --explicit ]; then
    target="sess:w1:p1"
  else
    case "$selector_form" in
      exact)
        target="popupcase"
        meta_id=popupcase
        ;;
      legacy)
        target="fm-popupcase"
        meta_id=popupcase
        ;;
      *)
        fail "$label: unknown selector form '$selector_form'"
        ;;
    esac
    fm_test_write_herdr_meta "$home/state/$meta_id.meta" "window=sess:w1:p1" "harness=$harness"
  fi
  : > "$log"; : > "$send_log"
  env FM_SEND_SETTLE=0 PATH="$fb:$PATH" \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SLEEP_LOG="$log" FM_SEND_LOG="$send_log" \
    "$SEND" "$target" "$msg" 2>/dev/null; rc=$?
  expect_code 0 "$rc" "$label: send should succeed"
  [ ! -s "$log" ] || fail "$label: native prompt unexpectedly slept"$'\n'"$(cat "$log")"
  [ "$(cat "$send_log")" = "$msg" ] || fail "$label: native prompt did not preserve exact text"
  pass "fm-send native prompt: $label -> one direct submission without popup settle"
}

# rides_inbox <label> <harness> <message>: a task-selector message that is NOT
# a harness-native invocation no longer types its payload at all - it rides
# the durable inbox, so no popup-settle question exists for it. Assert the
# routing (record enqueued, payload never typed) and that the doorbell's own
# native prompt doorbell. No popup-settle sleep remains.
rides_inbox() {  # <label> <harness> <message>
  local label=$1 harness=$2 msg=$3
  local dir fb log send_log home rc
  dir="$TMP_ROOT/case-$RANDOM"; mkdir -p "$dir/state"
  fb=$(make_stubs "$dir"); log="$dir/sleep.log"; send_log="$dir/send.log"; home="$dir"
  fm_test_write_herdr_meta "$home/state/popupcase.meta" "window=sess:w1:p1" "harness=$harness"
  : > "$log"; : > "$send_log"
  env FM_SEND_SETTLE=0 PATH="$fb:$PATH" \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SLEEP_LOG="$log" FM_SEND_LOG="$send_log" \
    "$SEND" fm-popupcase "$msg" 2>/dev/null; rc=$?
  expect_code 0 "$rc" "$label: send should succeed"
  grep -qF -- "$msg" "$home/state/popupcase.inbox/001.msg" \
    || fail "$label: the steer should be enqueued in the task inbox"
  [ ! -s "$log" ] || fail "$label: native doorbell unexpectedly slept"$'\n'"$(cat "$log")"
  assert_contains "$(cat "$send_log")" ": Firstmate instruction waiting" "$label: native doorbell was not submitted"
  assert_not_contains "$(cat "$send_log")" "$msg" "$label: inbox payload leaked into native prompt"
  pass "fm-send native prompt: $label -> inbox plane, no popup settle"
}

# Codex `$<skill>` is a direct native invocation.
native_direct 'codex $skill' codex '$no-mistakes'

# The same Codex `$<skill>` path must work when the target is addressed by exact
# task id, not only by the legacy `fm-<id>` window label.
native_direct 'codex $skill exact task id' codex '$no-mistakes' exact

# Same `$` message to Pi is ordinary text there and rides the inbox.
rides_inbox 'pi $-message' pi '$no-mistakes'

# `$`-prefixed plain text to pi (a price) is likewise ordinary text - the
# routing distinction keeps it out of the direct invocation plane.
rides_inbox 'pi "$5/month"' pi '$5/month is cheap'

# An explicit session:window target has no meta, so the harness is unknown and
# is submitted directly even for a `$` message.
native_direct 'explicit target $message' --explicit '$no-mistakes'

# The `/` slash case stays a direct invocation regardless of harness.
native_direct 'pi /command' pi '/no-mistakes'

# A `/` to Codex is likewise a direct native invocation.
native_direct 'codex /command' codex '/help'

# Plain text to codex rides the inbox - the codex scope is `$`-prefixed only.
rides_inbox 'codex plain text' codex 'just a normal steer'
