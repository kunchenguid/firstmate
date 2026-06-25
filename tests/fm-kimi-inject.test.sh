#!/usr/bin/env bash
# Tests for fm_tmux_inject_brief in bin/fm-tmux-lib.sh.
#
# Uses a fake tmux to verify single-line vs multi-line brief injection and timeout
# behavior without a real agent or tmux server.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/bin/fm-tmux-lib.sh"

# shellcheck source=bin/fm-tmux-lib.sh
. "$LIB"

TMP_ROOT=
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
cleanup() { [ -n "${TMP_ROOT:-}" ] && rm -rf "$TMP_ROOT"; }
trap cleanup EXIT

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-kimi-inject.XXXXXX")

# Build a fake tmux that records every send-keys/load-buffer/paste-buffer call
# and reads composer state from FM_FAKE_STATE (empty|pending|unknown).
make_fake_tmux() {  # <dir>
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<SH
#!/usr/bin/env bash
set -u
log() { printf '%s\n' "\$*" >> "$dir/tmux.log"; }
case "\${1:-}" in
  display-message)
    for a in "\$@"; do
      case "\$a" in *cursor_y*) printf '%s\n' "\${FM_FAKE_CY:-0}"; exit 0 ;; esac
    done
    printf 'faketarget\n'; exit 0 ;;
  capture-pane)
    case "\${FM_FAKE_STATE:-empty}" in
      empty) printf '\\xe2\\x94\\x82 > \\xe2\\x94\\x82\\n' ;;
      pending) printf '\\xe2\\x9d\\xaf hello\\n' ;;
      *) printf '\\n' ;;
    esac
    exit 0 ;;
  send-keys)
    log "send-keys \$*"
    # Strip -t <target> and -l; record the literal text if present.
    shift
    target=
    literal=0
    text=
    while [ "\$#" -gt 0 ]; do
      case "\$1" in
        -t) shift; target=\$1 ;;
        -l) literal=1 ;;
        Enter) log "send-keys-enter target=\$target" ;;
        *) text="\$1" ;;
      esac
      shift
    done
    if [ "\$literal" -eq 1 ] && [ -n "\$text" ]; then
      printf '%s' "\$text" > "$dir/sent-literal.txt"
    fi
    exit 0 ;;
  load-buffer)
    log "load-buffer \$*"
    cat > "$dir/paste-buffer.txt"
    exit 0 ;;
  paste-buffer)
    log "paste-buffer \$*"
    exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 1
SH
  chmod +x "$fb/tmux"
  printf '%s\n' "$fb"
}

# Build a fake tmux that models kimi's real composer: a multi-row box where typed
# text sits on the PROMPT row while the cursor parks on a blank continuation row,
# and the first Enters are dropped (pi-tui cold start). The composer only clears
# after FM_FAKE_ENTERS_REQUIRED Enters. This is the shape that made a single-row
# (cursor-line) emptiness check falsely report "submitted" after one dropped Enter,
# silently dropping the brief. Injection must instead judge the whole box and retry
# Enter until it actually clears.
make_fake_tmux_kimi() {  # <dir>
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<SH
#!/usr/bin/env bash
set -u
DIR="$dir"
REQ=\${FM_FAKE_ENTERS_REQUIRED:-3}
case "\${1:-}" in
  display-message)
    for a in "\$@"; do case "\$a" in *cursor_y*) printf '20\n'; exit 0 ;; esac; done
    printf 'faketarget\n'; exit 0 ;;
  capture-pane)
    shift
    S=
    while [ "\$#" -gt 0 ]; do case "\$1" in -S) shift; S=\$1 ;; -E) shift ;; esac; shift; done
    if [ "\$S" = 20 ]; then
      # A single cursor-row read (cursor_y=20): kimi parks the cursor on the BLANK
      # continuation row, so this looks empty even while the brief sits on the row
      # above. This is exactly what made the old single-row check false-positive.
      printf '\\xe2\\x94\\x82   \\xe2\\x94\\x82\\n'
      exit 0
    fi
    # A box scan (-S -12): prompt row plus blank continuation row.
    typed=0; [ -f "\$DIR/typed.txt" ] && typed=1
    enters=0; [ -f "\$DIR/enters.txt" ] && enters=\$(cat "\$DIR/enters.txt")
    if [ "\$typed" -eq 1 ] && [ "\$enters" -lt "\$REQ" ]; then
      printf '\\xe2\\x94\\x82 > the brief text \\xe2\\x94\\x82\\n'
      printf '\\xe2\\x94\\x82            \\xe2\\x94\\x82\\n'
    else
      printf '\\xe2\\x94\\x82 > \\xe2\\x94\\x82\\n'
      printf '\\xe2\\x94\\x82   \\xe2\\x94\\x82\\n'
    fi
    exit 0 ;;
  send-keys)
    shift
    literal=0; text=
    while [ "\$#" -gt 0 ]; do
      case "\$1" in
        -t) shift ;;
        -l) literal=1 ;;
        Enter)
          n=0; [ -f "\$DIR/enters.txt" ] && n=\$(cat "\$DIR/enters.txt")
          printf '%s' "\$((n + 1))" > "\$DIR/enters.txt" ;;
        *) text="\$1" ;;
      esac
      shift
    done
    if [ "\$literal" -eq 1 ] && [ -n "\$text" ]; then printf '%s' "\$text" > "\$DIR/typed.txt"; fi
    exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 1
SH
  chmod +x "$fb/tmux"
  printf '%s\n' "$fb"
}

test_retries_enter_until_multirow_composer_clears() {
  local dir fb brief enters
  dir="$TMP_ROOT/multirow"
  mkdir -p "$dir"
  fb=$(make_fake_tmux_kimi "$dir")
  brief="$dir/brief.md"
  printf 'the brief text' > "$brief"

  PATH="$fb:$PATH" FM_FAKE_ENTERS_REQUIRED=3 FM_INJECT_SUBMIT_SLEEP=0.05 \
    fm_tmux_inject_brief "sess:win" "$brief" || fail "injection failed on multi-row composer"

  [ -f "$dir/typed.txt" ] || fail "brief was never typed"
  enters=$(cat "$dir/enters.txt" 2>/dev/null || echo 0)
  # The old single-row check would have stopped after one (dropped) Enter and
  # falsely reported success. The box-aware check must retry until the box clears.
  [ "$enters" -ge 3 ] || fail "Enter was not retried until the composer cleared (sent $enters)"
  pass "injection retries Enter until kimi's multi-row composer actually clears"
}

test_single_line_uses_send_keys() {
  local dir fb brief
  dir="$TMP_ROOT/single"
  mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  brief="$dir/brief.md"
  printf 'fix the flaky login test' > "$brief"

  PATH="$fb:$PATH" FM_FAKE_STATE=empty FM_FAKE_CY=0 \
    fm_tmux_inject_brief "sess:win" "$brief" || fail "single-line injection failed"

  [ -f "$dir/sent-literal.txt" ] || fail "single-line brief was not sent with send-keys -l"
  [ "$(cat "$dir/sent-literal.txt")" = "fix the flaky login test" ] || fail "sent literal did not match brief"
  grep -q 'send-keys-enter' "$dir/tmux.log" || fail "Enter was not sent after single-line brief"
  pass "single-line brief uses send-keys -l + Enter"
}

test_multi_line_uses_paste_buffer() {
  local dir fb brief
  dir="$TMP_ROOT/multi"
  mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  brief="$dir/brief.md"
  printf 'line one\nline two\nline three\n' > "$brief"

  PATH="$fb:$PATH" FM_FAKE_STATE=empty FM_FAKE_CY=0 \
    fm_tmux_inject_brief "sess:win" "$brief" || fail "multi-line injection failed"

  [ -f "$dir/paste-buffer.txt" ] || fail "multi-line brief was not loaded into paste buffer"
  [ "$(cat "$dir/paste-buffer.txt")" = "$(cat "$brief")" ] || fail "paste buffer did not match brief"
  grep -q 'load-buffer' "$dir/tmux.log" || fail "load-buffer was not called"
  grep -q 'paste-buffer' "$dir/tmux.log" || fail "paste-buffer was not called"
  grep -q 'send-keys-enter' "$dir/tmux.log" || fail "Enter was not sent after paste"
  ! [ -f "$dir/sent-literal.txt" ] || fail "multi-line brief wrongly used send-keys -l"
  pass "multi-line brief uses load-buffer + paste-buffer + Enter"
}

test_times_out_when_composer_never_ready() {
  local dir fb brief rc
  dir="$TMP_ROOT/timeout"
  mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  brief="$dir/brief.md"
  printf 'brief text' > "$brief"

  set +e
  PATH="$fb:$PATH" FM_FAKE_STATE=pending FM_FAKE_CY=0 \
    fm_tmux_inject_brief "sess:win" "$brief" 2 2>"$dir/err"
  rc=$?
  set -e

  [ "$rc" -ne 0 ] || fail "injection should have timed out"
  grep -q 'never became ready' "$dir/err" || fail "timeout error message missing"
  pass "injection times out when composer never becomes ready"
}

test_single_line_uses_send_keys
test_multi_line_uses_paste_buffer
test_retries_enter_until_multirow_composer_clears
test_times_out_when_composer_never_ready
