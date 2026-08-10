#!/usr/bin/env bash
# fm-send's handling of the durable pending-reply expectation when a verified
# submit does NOT come back exactly "empty" (issue #2003).
#
# fm-send's exit code contract is intentionally strict and untouched by this
# suite: anything other than an exact "empty" verdict still refuses loudly, so
# a caller can never mistake an unconfirmed send for a landed one. What this
# suite pins is a narrower, separate defect: what happens to the durable
# state/pending-replies/ record backing that send.
#
#   - "pending" is a PROVEN verdict: every backend's submit core returns it
#     only after its own retry budget shows the composer still holding the
#     text. That is real proof of non-delivery, so the record is discarded.
#   - "unknown" (and any other non-proof verdict, e.g. tmux's
#     "pending-unproven") means the backend could not confirm submission but
#     also could not disprove it - the send may have actually landed. Before
#     this fix fm-send treated every non-"empty", non-"send-failed" verdict
#     identically and discarded the record outright, silently losing the
#     missed-report safety net for a send that might have succeeded. This is
#     exactly the fm-send-side damage reported in #2003 for the Claude
#     NBSP-composer misclassification (root-caused and fixed for the
#     classifier itself in PR #1995, a different file/lane): the false
#     "pending" that PR fixes could equally have surfaced as "unknown" on a
#     harness that cannot structurally prove its composer content, and this
#     suite pins that fm-send itself now preserves the record instead of
#     discarding it whenever the backend cannot prove non-delivery.
#   - "send-failed" (typing itself was rejected) remains a discard: nothing
#     was ever accepted by the backend, so there is nothing ambiguous about it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-pending-reply-lib.sh"

SEND="$ROOT/bin/fm-send.sh"

TMP_ROOT=$(fm_test_tmproot fm-send-verdict)

# A fake tmux whose composer-read behavior is controlled by <mode>:
#   send-failed - the literal send-keys itself fails (nothing ever accepted).
#   pending     - capture-pane always shows a bare, unbordered "hello" row, so
#                 fm_tmux_composer_state structurally PROVES real leftover
#                 content on every retry (a genuine swallow).
#   unknown     - display-message cannot report a numeric cursor_y, so
#                 fm_tmux_composer_state cannot even attempt classification and
#                 reports "unknown" on the very first check.
make_stubs() {  # <dir> <mode> -> echoes fakebin dir
  local dir=$1 mode=$2 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<SH
#!/usr/bin/env bash
set -u
case "\${1:-}" in
  send-keys)
    shift
    literal=0
    while [ \$# -gt 0 ]; do
      case "\$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    if [ "\$literal" = 1 ]; then
      printf '%s' "\${1:-}" >> "\$FM_SEND_LOG"
      case "$mode" in send-failed) exit 1 ;; esac
    fi
    exit 0 ;;
  display-message)
    for a in "\$@"; do
      case "\$a" in
        *cursor_y*)
          case "$mode" in
            unknown) printf 'not-a-number\n' ;;
            *) printf '0\n' ;;
          esac
          exit 0 ;;
      esac
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf 'hello\n'; exit 0 ;;
  list-windows) exit 0 ;;
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

# run_send <fakebin> <home> <send-log> <err-file> -- <fm-send args...>
# Mirrors tests/fm-send-secondmate-marker.test.sh's run_send, but also
# captures stderr (into <err-file>) so the reported verdict can be asserted.
run_send() {
  local fb=$1 home=$2 log=$3 errfile=$4; shift 4
  : > "$log"
  env PATH="$fb:$PATH" \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    FM_SEND_RETRIES=2 FM_SEND_SLEEP=0 \
    "$SEND" "$@" 2> "$errfile"
}

# setup_home <name> -> echoes a fresh home dir with an empty state/, marked as
# a kind=secondmate target so fm-send creates a pending-reply expectation.
setup_home() {
  local home="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$home/state"
  fm_write_secondmate_meta "$home/state/domain.meta" "$home" "sess:fm-domain"
  printf '%s\n' "$home"
}

# corr_and_record <log> <state> -> echoes "<corr> <record-path>", failing loud
# if the send never embedded a correlation id.
corr_and_record() {
  local log=$1 state=$2 corr
  corr=$(fm_pending_reply_extract_corr "$(cat "$log")")
  [ -n "$corr" ] || fail "send did not embed a pending-reply correlation id"
  printf '%s %s' "$corr" "$(fm_pending_reply_path "$state" "$corr")"
}

test_proven_pending_still_discards_and_still_fails_loud() {
  local dir fb log err home rc corr rec
  dir="$TMP_ROOT/proven-pending"; mkdir -p "$dir"
  fb=$(make_stubs "$dir" pending); log="$dir/send.log"; err="$dir/send.err"
  home=$(setup_home proven-pending)
  run_send "$fb" "$home" "$log" "$err" "domain" "do the thing"; rc=$?
  [ "$rc" -ne 0 ] || fail "a proven-pending verdict must still exit non-zero"
  grep -q 'verdict=pending' "$err" \
    || fail "expected verdict=pending in stderr, got: $(cat "$err")"
  read -r corr rec < <(corr_and_record "$log" "$home/state")
  [ ! -f "$rec" ] \
    || fail "a PROVEN pending verdict (genuine swallow) must still discard the pending-reply record"
  pass "fm-send: a proven pending verdict discards the pending-reply record and still exits non-zero"
}

test_send_failed_still_discards_and_still_fails_loud() {
  local dir fb log err home rc corr rec
  dir="$TMP_ROOT/send-failed"; mkdir -p "$dir"
  fb=$(make_stubs "$dir" send-failed); log="$dir/send.log"; err="$dir/send.err"
  home=$(setup_home send-failed)
  run_send "$fb" "$home" "$log" "$err" "domain" "do the thing"; rc=$?
  [ "$rc" -ne 0 ] || fail "a send-failed verdict must still exit non-zero"
  read -r corr rec < <(corr_and_record "$log" "$home/state")
  [ ! -f "$rec" ] \
    || fail "a send-failed verdict (nothing ever accepted) must still discard the pending-reply record"
  pass "fm-send: a send-failed verdict discards the pending-reply record and still exits non-zero"
}

# The test that fails against today's behavior: before this fix, "unknown" hit
# the exact same catch-all as a proven "pending" and was unconditionally
# discarded, even though the backend never proved the send did not land.
test_unproven_verdict_preserves_record_as_delivery_unknown() {
  local dir fb log err home rc corr rec
  dir="$TMP_ROOT/unproven"; mkdir -p "$dir"
  fb=$(make_stubs "$dir" unknown); log="$dir/send.log"; err="$dir/send.err"
  home=$(setup_home unproven)
  run_send "$fb" "$home" "$log" "$err" "domain" "do the thing"; rc=$?
  [ "$rc" -ne 0 ] \
    || fail "an unproven verdict must still exit non-zero (fail-safe direction preserved)"
  grep -q 'verdict=unknown' "$err" \
    || fail "expected verdict=unknown in stderr, got: $(cat "$err")"
  read -r corr rec < <(corr_and_record "$log" "$home/state")
  [ -f "$rec" ] \
    || fail "an unproven (non-disproving) verdict must NOT discard the pending-reply record - the send may have landed (#2003)"
  [ "$(fm_pending_reply_get "$rec" phase)" = delivery_unknown ] \
    || fail "surviving record should move to phase delivery_unknown, got $(fm_pending_reply_get "$rec" phase)"
  pass "fm-send: an unproven verdict preserves the pending-reply record as delivery-unknown instead of discarding it"
}

test_proven_pending_still_discards_and_still_fails_loud
test_send_failed_still_discards_and_still_fails_loud
test_unproven_verdict_preserves_record_as_delivery_unknown
