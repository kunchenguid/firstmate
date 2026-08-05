#!/usr/bin/env bash
# fm-send strict target resolution.
#
# A send that cannot be tied to a recorded task/lane or to an explicit
# well-formed backend target must fail loudly. These tests pin the historical
# silent-fallback failures: missing FM_HOME, unresolved selectors, prefixless
# herdr pane ids, dead explicit endpoints, and the healthy exact/fm-id paths.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SEND="$ROOT/bin/fm-send.sh"
TMP_ROOT=$(fm_test_tmproot fm-send-strict)

make_stubs() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift
    literal=0
    target=
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) target=$2; shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    printf 'send-keys target=%s literal=%s arg=%s\n' "$target" "$literal" "${1:-}" >> "$FM_TMUX_LOG"
    exit 0 ;;
  display-message)
    target=
    cursor=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) target=$2; shift 2 ;;
        *cursor_y*) cursor=1; shift ;;
        *) shift ;;
      esac
    done
    if [ -n "${FM_FAKE_TMUX_DEAD_TARGET:-}" ] && [ "$target" = "$FM_FAKE_TMUX_DEAD_TARGET" ]; then
      exit 1
    fi
    [ "$cursor" = 1 ] && { printf '%s\n' "${FM_FAKE_TMUX_CURSOR:-1}"; exit 0; }
    printf '%%1\n'
    exit 0 ;;
  capture-pane)
    if [ -n "${FM_TMUX_CAPTURE_FILE:-}" ]; then
      cat "$FM_TMUX_CAPTURE_FILE"
    else
      printf '╭────╮\n│    │\n╰────╯\n'
    fi
    exit 0 ;;
  list-windows)
    printf 'foreign:%s\n' "${FM_FAKE_TMUX_WINDOW:-fm-lost}"
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_HERDR_LOG"
case "${1:-} ${2:-}" in
  "status --json") printf '{"client":{"version":"0.7.5","protocol":16},"server":{"running":true}}\n' ;;
  "pane get") printf '{"result":{"pane":{"pane_id":"%s"}}}\n' "${3:-}" ;;
  "pane send-keys") : ;;
esac
SH
  chmod +x "$fb/herdr"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
  printf '%s\n' "$fb"
}

setup_home() {  # <name> -> echoes home dir
  local home="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

test_composer_classifier_capability_matrix() {
  (
    local backend expected expected_preflight observed observed_preflight seen=''
    # shellcheck source=bin/fm-backend.sh
    . "$ROOT/bin/fm-backend.sh"
    fm_backend_composer_state() { printf 'unknown'; }
    for backend in $FM_BACKEND_KNOWN; do
      case "$backend" in
        tmux|herdr|orca|cmux) expected=present; expected_preflight=classified:unknown ;;
        zellij) expected=absent; expected_preflight=unclassified ;;
        *) fail "composer-classifier matrix has no expected row for known backend '$backend'" ;;
      esac
      observed=$(fm_backend_composer_classifier_capability "$backend") \
        || fail "composer-classifier capability query failed for known backend '$backend'"
      [ "$observed" = "$expected" ] \
        || fail "composer-classifier capability for $backend: expected $expected, got $observed"
      observed_preflight=$(fm_backend_composer_preflight_state "$backend" fixture-target) \
        || fail "composer preflight-state query failed for known backend '$backend'"
      [ "$observed_preflight" = "$expected_preflight" ] \
        || fail "composer preflight for $backend with classifier verdict unknown: expected $expected_preflight, got $observed_preflight"
      seen="$seen $backend=$observed/$observed_preflight"
    done
    [ "$seen" = " tmux=present/classified:unknown herdr=present/classified:unknown zellij=absent/unclassified orca=present/classified:unknown cmux=present/classified:unknown" ] \
      || fail "composer-classifier matrix did not cover the exact known-backend enumeration:$seen"
    [ "$(fm_backend_composer_classifier_capability bogus)" = unknown ] \
      || fail "an unrecognized backend must not inherit the no-classifier fallback"
    [ "$(fm_backend_composer_preflight_state bogus fixture-target)" = capability-unknown ] \
      || fail "an unrecognized backend must fail closed at preflight"
    fm_backend_composer_state() { printf 'unclassified'; }
    [ "$(fm_backend_composer_preflight_state tmux fixture-target)" = classified:unclassified ] \
      || fail "a classified backend's actor-influenced verdict impersonated the static no-classifier state"
  ) || fail "composer-classifier capability matrix failed"
  pass "fm-backend: every known backend declares a static composer-classifier capability"
}

test_exact_lane_id_send_still_works() {
  local dir fb home err log rc got
  dir="$TMP_ROOT/exact"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home exact); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"
  fm_write_meta "$home/state/mpf-lane-m8.meta" "window=sess:fm-mpf-lane-m8" "kind=ship"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" mpf-lane-m8 "lost dispatch" >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "exact task id send should succeed when metadata exists"
  got=$(cat "$log")
  assert_contains "$got" "target=sess:fm-mpf-lane-m8 literal=1 arg=lost dispatch" "exact id should type literal text to the meta target"
  assert_contains "$got" "target=sess:fm-mpf-lane-m8 literal=0 arg=Enter" "exact id should submit with Enter"
  pass "fm-send strict: exact task/lane ids resolve through home metadata"
}

test_unset_fm_home_fails() {
  local dir fb err log rc
  dir="$TMP_ROOT/nohome"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"

  env -u FM_HOME PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$dir" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" sess:win "hello" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "unset FM_HOME should fail"
  assert_contains "$(cat "$err")" "FM_HOME is not set" "unset FM_HOME diagnostic should be explicit"
  [ ! -s "$log" ] || fail "unset FM_HOME still attempted a send"$'\n'"$(cat "$log")"
  pass "fm-send strict: unset FM_HOME fails before target resolution"
}

test_unresolvable_target_does_not_tmux_fallback() {
  local dir fb home err log rc
  dir="$TMP_ROOT/unresolved"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home unresolved); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_FAKE_TMUX_WINDOW=lost-target FM_SEND_SETTLE=0 \
    "$SEND" lost-target "hello" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "unresolvable target should fail"
  assert_contains "$(cat "$err")" "not resolvable" "unresolvable diagnostic should be loud"
  assert_contains "$(cat "$err")" "metadata window/terminal lookup" "unresolvable diagnostic should name the attempted lookup"
  assert_contains "$(cat "$err")" "backend=none" "unresolvable diagnostic should name that no backend was assumed"
  [ ! -s "$log" ] || fail "unresolvable target fell through to tmux send"$'\n'"$(cat "$log")"
  pass "fm-send strict: unresolvable selectors do not fall back to tmux"
}

test_prefixless_herdr_pane_id_fails() {
  local dir fb home err log rc
  dir="$TMP_ROOT/herdr-pane"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home herdr); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"
  fm_write_meta "$home/state/nudge.meta" \
    "window=default:wB:p2" "backend=herdr" "herdr_session=default" "herdr_pane_id=wB:p2" "kind=ship"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" wB:p2 "nudge" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "prefixless herdr pane id should fail"
  assert_contains "$(cat "$err")" "matches herdr_pane_id" "herdr pane diagnostic should name the meta match"
  assert_contains "$(cat "$err")" "expected <herdr-session>:<pane-id>" "herdr pane diagnostic should show expected shape"
  assert_contains "$(cat "$err")" "default:wB:p2" "herdr pane diagnostic should show the canonical target"
  [ ! -s "$log" ] || fail "prefixless herdr pane id fell through to tmux send"$'\n'"$(cat "$log")"
  pass "fm-send strict: prefixless herdr pane ids are rejected before tmux fallback"
}

test_unmatched_single_colon_target_must_exist() {
  local dir fb home err log rc
  dir="$TMP_ROOT/dead-explicit"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home deadexplicit); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_FAKE_TMUX_DEAD_TARGET=sess:missing FM_SEND_SETTLE=0 \
    "$SEND" sess:missing "hello" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "dead explicit tmux-shaped target should fail"
  assert_contains "$(cat "$err")" "not a live tmux endpoint" "dead explicit target diagnostic should name the assumed backend"
  assert_contains "$(cat "$err")" "backend=tmux" "dead explicit target diagnostic should name the tried backend"
  [ ! -s "$log" ] || fail "dead explicit target still attempted a send"$'\n'"$(cat "$log")"
  pass "fm-send strict: unmatched single-colon explicit targets must verify live before sending"
}

test_fm_prefixed_herdr_session_is_an_explicit_target() {
  local dir fb home err log herdr_log rc
  dir="$TMP_ROOT/fm-remote-explicit"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home fmremote); err="$dir/send.err"; log="$dir/tmux.log"; herdr_log="$dir/herdr.log"
  : > "$log"
  : > "$herdr_log"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_HERDR_LOG="$herdr_log" FM_SEND_SETTLE=0 \
    "$SEND" fm-remote:w1:p2 --key Enter >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "an fm-prefixed Herdr session target should be accepted as explicit"
  assert_grep 'pane get w1:p2 --session fm-remote' "$herdr_log" "fm-prefixed Herdr target was not verified in its session"
  assert_grep 'pane send-keys w1:p2 enter --session fm-remote' "$herdr_log" "fm-prefixed Herdr target was not sent its key in its session"
  assert_no_grep '--session default' "$herdr_log" "fm-prefixed Herdr target fell back to the default session"
  pass "fm-send strict: fm-prefixed Herdr sessions remain explicit backend targets"
}

test_healthy_fm_id_send_still_works() {
  local dir fb home err log rc got
  dir="$TMP_ROOT/healthy"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home healthy); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"
  fm_write_meta "$home/state/lane-ok.meta" "window=sess:fm-lane-ok" "kind=ship" "harness=codex"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" fm-lane-ok "hello captain" >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "healthy fm-id send should succeed"
  got=$(cat "$log")
  assert_contains "$got" "target=sess:fm-lane-ok literal=1 arg=hello captain" "healthy send should type literal text to the meta target"
  assert_contains "$got" "target=sess:fm-lane-ok literal=0 arg=Enter" "healthy send should submit with Enter"
  assert_contains "$(cat "$err")" "requested message WILL still be sent" "fm-send guard banner should keep send-specific continuation wording"
  pass "fm-send strict: healthy fm-<id> sends still type once and submit"
}

test_stale_composer_refuses_before_typing() {
  local dir fb home err log capture rc got
  dir="$TMP_ROOT/stale-composer"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home stalecomposer); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"
  capture="$dir/capture.txt"
  printf '╭────────────────────╮\n│ stale prior order  │\n╰────────────────────╯\n' > "$capture"
  fm_write_meta "$home/state/stale.meta" "window=sess:fm-stale" "kind=ship" "harness=codex"

  rc=0
  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" \
    FM_TMUX_CAPTURE_FILE="$capture" FM_SEND_SETTLE=0 \
    "$SEND" stale "fresh order" >/dev/null 2>"$err" || rc=$?
  [ "$rc" -ne 0 ] || fail "stale composer accepted a second instruction"
  got=$(cat "$log")
  assert_not_contains "$got" 'literal=1 arg=fresh order' \
    "fm-send typed the fresh order into a composer that already contained stale text"
  assert_not_contains "$got" 'literal=0 arg=Enter' \
    "fm-send submitted the stale composer while attempting the fresh order"
  assert_contains "$(cat "$err")" 'composer is not affirmatively empty' \
    "stale-composer refusal did not explain the delivery gap"
  pass "fm-send strict: stale composer text refuses before any typing or Enter"
}

test_unknown_classified_composer_refuses_before_typing() {
  local dir fb home err log rc got
  dir="$TMP_ROOT/unknown-classified-composer"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home unknownclassified); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"
  fm_write_meta "$home/state/unknown.meta" "window=sess:fm-unknown" "kind=ship" "harness=codex"

  rc=0
  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_TMUX_LOG="$log" \
    FM_FAKE_TMUX_CURSOR=unreadable FM_SEND_SETTLE=0 \
    "$SEND" unknown "fresh order" >/dev/null 2>"$err" || rc=$?
  [ "$rc" -ne 0 ] || fail "unknown verdict from a classified backend was accepted"
  got=$(cat "$log")
  assert_not_contains "$got" 'literal=1 arg=fresh order' \
    "fm-send typed after a classified backend returned unknown"
  assert_not_contains "$got" 'literal=0 arg=Enter' \
    "fm-send submitted after a classified backend returned unknown"
  assert_contains "$(cat "$err")" 'verdict=unknown' \
    "classified-backend refusal did not preserve the unknown verdict"
  pass "fm-send strict: unknown remains unsafe when a backend has a composer classifier"
}

test_unknown_composer_classifier_capability_refuses_before_typing() {
  local dir fb home err log fixture_root rc got
  dir="$TMP_ROOT/unknown-composer-capability"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home unknowncapability); err="$dir/send.err"; log="$dir/tmux.log"; : > "$log"
  fixture_root="$dir/fixture-root"
  cp -R "$ROOT/bin" "$fixture_root"
  cat >> "$fixture_root/fm-backend.sh" <<'SH'

fm_backend_composer_classifier_capability() { printf 'unknown'; }
SH
  fm_write_meta "$home/state/unknown-capability.meta" "window=sess:fm-unknown-capability" "kind=ship" "harness=codex"

  rc=0
  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_TMUX_LOG="$log" FM_SEND_SETTLE=0 \
    "$fixture_root/fm-send.sh" unknown-capability "fresh order" >/dev/null 2>"$err" || rc=$?
  [ "$rc" -ne 0 ] || fail "unknown composer-classifier capability was accepted"
  got=$(cat "$log")
  assert_not_contains "$got" 'literal=1 arg=fresh order' \
    "fm-send typed after the backend's composer-classifier capability became unknown"
  assert_not_contains "$got" 'literal=0 arg=Enter' \
    "fm-send submitted after the backend's composer-classifier capability became unknown"
  assert_contains "$(cat "$err")" 'composer-classifier capability is not established' \
    "unknown-capability refusal did not explain the delivery gap"
  assert_contains "$(cat "$err")" 'capability=capability-unknown' \
    "unknown-capability refusal did not preserve the preflight verdict"
  pass "fm-send strict: unknown composer-classifier capability refuses before any typing or Enter"
}

test_remote_send_uses_host_local_composer_check() {
  local dir fb home err log rc decoded
  dir="$TMP_ROOT/remote"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home remote); err="$dir/send.err"; log="$dir/ssh.log"; decoded="$dir/decoded.log"
  mkdir -p "$home/data"
  cat > "$home/data/secondmates.md" <<'EOF'
- ios - iOS delivery (host: remote-mac; root: /remote/root; home: /remote/home; scope: iOS work; projects: alpha; added 2026-08-02)
EOF
  fm_write_meta "$home/state/ios.meta" "remote_host=remote-mac" "kind=ship" "harness=codex"
  cat > "$fb/ssh" <<'SH'
#!/usr/bin/env bash
set -u
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
printf '%s\n' "$*" > "$FM_SSH_LOG"
perl -MMIME::Base64=decode_base64 -e '
  my $data = decode_base64($ARGV[0]);
  $data =~ s/\0/\n/g;
  print $data;
' "$6" > "$FM_SSH_DECODED"
SH
  chmod +x "$fb/ssh"

  rc=0
  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_SSH_BIN="$fb/ssh" \
    FM_SSH_LOG="$log" FM_SSH_DECODED="$decoded" FM_SEND_SETTLE=0 \
    "$SEND" fm-ios "remote order" >/dev/null 2>"$err" || rc=$?
  expect_code 0 "$rc" "remote task selector should delegate the composer check to the remote host"
  assert_contains "$(cat "$decoded")" "fm-remote-secondmate-control.sh" "remote send did not use the host-local control path"
  assert_contains "$(cat "$decoded")" "remote order" "remote send lost the requested text"
  pass "fm-send strict: remote text reaches the host-local guarded sender"
}

test_composer_classifier_capability_matrix
test_exact_lane_id_send_still_works
test_unset_fm_home_fails
test_unresolvable_target_does_not_tmux_fallback
test_prefixless_herdr_pane_id_fails
test_unmatched_single_colon_target_must_exist
test_fm_prefixed_herdr_session_is_an_explicit_target
test_healthy_fm_id_send_still_works
test_unknown_classified_composer_refuses_before_typing
test_unknown_composer_classifier_capability_refuses_before_typing
test_stale_composer_refuses_before_typing
test_remote_send_uses_host_local_composer_check
