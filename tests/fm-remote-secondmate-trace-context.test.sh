#!/usr/bin/env bash
# tests/fm-remote-secondmate-trace-context.test.sh - trace-context regressions for
# the REMOTE second mate route, over the deterministic generic SSH boundary.
#
# The local spawn path's coverage lives in tests/fm-trace-context-spawn.test.sh.
# A remote second mate never reaches that path: bin/fm-spawn.sh routes it through
# spawn_remote_secondmate, which hands the launch to the remote host. These
# assertions drive the real chain - parent fm-spawn -> fm-on -> the real remote
# entrypoint -> fm-remote-secondmate-control -> the remote host's own fm-spawn -
# against a fake tmux, so the carrier the remote pane receives is observable.
# See docs/verification/trace-context.md for the maintained coverage inventory.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-trace-context-lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(fm_test_tmproot fm-remote-trace-context)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
PARENT="$TMP_ROOT/parent"
REMOTE_ROOT="$TMP_ROOT/remote-root"
REMOTE_HOME="$TMP_ROOT/remote-home"
SECOND_HOME="$TMP_ROOT/remote-home-2"
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fake")
TMUX_LOG="$TMP_ROOT/remote-tmux.log"
TMUX_STATE="$TMP_ROOT/remote-tmux.state"
CLAIMS="$TMP_ROOT/claims"
mkdir -p "$PARENT/data" "$PARENT/state" "$PARENT/config" "$PARENT/projects" "$REMOTE_ROOT" "$CLAIMS"
trap 'FM_HOME="$PARENT" FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true; rm -rf -- "$TMP_ROOT"' EXIT

# The remote host's tracked code root is this branch, as a real git repository:
# fm-on and the remote entrypoint both require the dispatched command to be
# tracked there, and the remote side runs the real scripts under test.
(
  cd "$ROOT" || exit
  tar --exclude=.git --exclude=.no-mistakes --exclude=data --exclude=state --exclude=config -cf - .
) | (cd "$REMOTE_ROOT" && tar -xf -)

# Fake tmux on the remote host. Every invocation is logged verbatim, so the
# pre-launch `export TRACEPARENT=` line and the launch literal's
# FM_TRACE_CONTEXT prefix are both observable exactly as the pane received them.
cat > "$REMOTE_ROOT/bin/tmux" <<SH
#!/usr/bin/env bash
set -u
log='$TMUX_LOG'
state='$TMUX_STATE'
printf '%s\n' "\$*" >> "\$log"
case "\${1:-}" in
  has-session|new-session|set-window-option) exit 0 ;;
  list-windows)
    [ -f "\$state" ] || exit 0
    name=\$(cut -d'|' -f1 "\$state")
    case "\$*" in *'#{session_name}:#{window_name}'*) printf 'firstmate:%s\n' "\$name" ;; *) printf '%s\n' "\$name" ;; esac
    exit 0
    ;;
  new-window)
    name=; cwd=
    while [ "\$#" -gt 0 ]; do
      case "\$1" in -n) shift; name=\$1 ;; -c) shift; cwd=\$1 ;; esac
      shift
    done
    printf '%s|%s\n' "\$name" "\$cwd" > "\$state"
    printf '@1\n'
    exit 0
    ;;
  display-message)
    case "\$*" in
      *'#{pane_current_path}'*) cut -d'|' -f2- "\$state" ;;
      *'#{pane_current_command}'*) printf 'codex\n' ;;
      *'#{cursor_y}'*) printf '0\n' ;;
      *'#S'*) printf 'firstmate\n' ;;
      *) printf '%%1\n' ;;
    esac
    exit 0
    ;;
  capture-pane) printf '\n'; exit 0 ;;
  send-keys) exit 0 ;;
  kill-window) rm -f -- "\$state"; exit 0 ;;
  list-panes) printf 'codex\n'; exit 0 ;;
esac
exit 0
SH
chmod +x "$REMOTE_ROOT/bin/tmux"
git -C "$REMOTE_ROOT" init -q -b main
git -C "$REMOTE_ROOT" config user.email test@example.com
git -C "$REMOTE_ROOT" config user.name Test
git -C "$REMOTE_ROOT" add .
git -C "$REMOTE_ROOT" commit -qm 'remote fixture root'

cat > "$FAKEBIN/fake-ssh" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
host=$1
entry=$2
shift 2
[ "$host" = remote-mac ] || exit 91
[ "$entry" = fm-remote-entrypoint.sh ] || exit 92
cd "$FM_FAKE_REMOTE_CWD" || exit 93
exec "$FM_FAKE_REMOTE_ENTRYPOINT" "$@"
SH
chmod +x "$FAKEBIN/fake-ssh"

printf 'codex\n' > "$PARENT/config/secondmate-harness"
printf 'tmux\n' > "$PARENT/config/backend"
printf 'codex\n' > "$PARENT/config/crew-harness"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$PARENT/data/backlog.md"

remote_env() {
  FM_HOME="$PARENT" \
  FM_ROOT_OVERRIDE="$REMOTE_ROOT" \
  FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
  FM_SSH_BIN="$FAKEBIN/fake-ssh" \
  FM_FAKE_REMOTE_ENTRYPOINT="$REMOTE_ROOT/bin/fm-remote-entrypoint.sh" \
  FM_FAKE_REMOTE_CWD="$TMP_ROOT" \
  FM_SEND_SETTLE=0 FM_SEND_SLEEP=0 \
  "$@"
}

# Freeze the parent home's trace-context decision the way a locked session start
# does, hermetically against an ambient FM_TRACE_CONTEXT.
freeze_parent_session() {
  printf '%s\n' "$$" > "$PARENT/state/.lock"
  (
    unset FM_TRACE_CONTEXT
    fm_trace_context_session_start "$PARENT/config" "$PARENT/state/.trace-context-effective"
  )
}

# What the remote pane actually received, read back from the remote tmux log.
remote_injected_traceparent() {
  sed -n 's/.*export TRACEPARENT=\([0-9a-f-]*\).*/\1/p' "$TMUX_LOG" | tail -1
}
remote_launch_snapshot() {
  grep -o 'FM_TRACE_CONTEXT=[a-z]*' "$TMUX_LOG" | tail -1 | cut -d= -f2
}
meta_traceparent() { sed -n 's/^traceparent=//p' "$1"; }

# Provision and register the remote route from the captain-facing primary.
FM_SECONDMATE_CHARTER='Own iOS delivery on the build Mac.' \
  FM_SECONDMATE_SCOPE='iOS implementation and Xcode validation' \
  remote_env "$ROOT/bin/fm-remote-home-seed.sh" ios remote-mac "$REMOTE_ROOT" "$REMOTE_HOME" --no-projects >/dev/null \
  || fail "remote seed did not provision the traced route"

# --- disabled: the remote route must stay byte-identically untraced ----------
freeze_parent_session
: > "$TMUX_LOG"
remote_env "$ROOT/bin/fm-spawn.sh" ios --secondmate >/dev/null 2>&1 \
  || fail "default-off remote secondmate spawn failed"
assert_present "$PARENT/state/ios.meta" "default-off remote spawn published no parent metadata"
! grep -q '^traceparent=' "$PARENT/state/ios.meta" \
  || fail "default-off remote spawn must not record a traceparent= line"
! grep -q 'export TRACEPARENT=' "$TMUX_LOG" \
  || fail "default-off remote spawn must not export a carrier into the remote pane"
! grep -q '^traceparent=' "$REMOTE_HOME/state/parent-route/ios.meta" \
  || fail "default-off remote spawn must not record a carrier on the remote host"
[ "$(remote_launch_snapshot)" = off ] \
  || fail "default-off remote spawn must deliver FM_TRACE_CONTEXT=off (got '$(remote_launch_snapshot)')"
assert_absent "$REMOTE_HOME/config/trace-context" "default-off remote spawn inherited an enablement flag"
grep -q 'export GOTMPDIR=' "$TMUX_LOG" || fail "the remote spawn should still run (GOTMPDIR is always exported)"
pass "disabled: a remote-routed second mate records and receives no carrier and stays enabled-off end to end"

# --- enabled: one carrier is recorded by the parent and received remotely ----
: > "$PARENT/config/trace-context"
freeze_parent_session
rm -f "$TMUX_STATE"   # the previous endpoint is gone; this is an ordinary relaunch
: > "$TMUX_LOG"
remote_env "$ROOT/bin/fm-spawn.sh" ios --secondmate >/dev/null 2>&1 \
  || fail "enabled remote secondmate spawn failed"

PARENT_TP=$(meta_traceparent "$PARENT/state/ios.meta")
REMOTE_TP=$(meta_traceparent "$REMOTE_HOME/state/parent-route/ios.meta")
INJECTED_TP=$(remote_injected_traceparent)
fm_trace_context_valid "$PARENT_TP" \
  || fail "an enabled remote spawn must record a valid carrier in the parent metadata (got '$PARENT_TP')"
fm_trace_context_valid "$INJECTED_TP" \
  || fail "an enabled remote spawn must export a valid carrier into the remote pane (got '$INJECTED_TP')"
[ "$PARENT_TP" = "$INJECTED_TP" ] \
  || fail "the parent's recorded carrier and the remote pane's carrier must be identical (parent='$PARENT_TP' pane='$INJECTED_TP')"
[ "$REMOTE_TP" = "$PARENT_TP" ] \
  || fail "the remote endpoint record must carry the parent's identity (remote='$REMOTE_TP' parent='$PARENT_TP')"
[ "$(remote_launch_snapshot)" = on ] \
  || fail "an enabled remote spawn must deliver FM_TRACE_CONTEXT=on (got '$(remote_launch_snapshot)')"
assert_present "$REMOTE_HOME/config/trace-context" \
  "an enabled remote launch did not inherit the enablement flag into the remote home"
GOTMP_LINE=$(grep -n 'export GOTMPDIR=' "$TMUX_LOG" | tail -1 | cut -d: -f1)
TP_LINE=$(grep -n 'export TRACEPARENT=' "$TMUX_LOG" | tail -1 | cut -d: -f1)
LAUNCH_LINE=$(grep -n 'FM_TRACE_CONTEXT=' "$TMUX_LOG" | tail -1 | cut -d: -f1)
[ -n "$GOTMP_LINE" ] && [ -n "$TP_LINE" ] && [ -n "$LAUNCH_LINE" ] \
  || fail "remote pane log missing GOTMPDIR/TRACEPARENT/launch lines"
[ "$TP_LINE" -gt "$GOTMP_LINE" ] \
  || fail "the remote TRACEPARENT export must ride the GOTMPDIR pre-launch site (gotmp=$GOTMP_LINE tp=$TP_LINE)"
[ "$TP_LINE" -lt "$LAUNCH_LINE" ] \
  || fail "the remote TRACEPARENT export must be sent before the launch command (tp=$TP_LINE launch=$LAUNCH_LINE)"
pass "enabled: a remote-routed second mate receives one carrier in its pane, identical to the parent's recorded identity, before launch"

# --- relaunch stability on the remote path ----------------------------------
rm -f "$TMUX_STATE"
: > "$TMUX_LOG"
remote_env "$ROOT/bin/fm-spawn.sh" ios --secondmate >/dev/null 2>&1 \
  || fail "enabled remote secondmate relaunch failed"
RELAUNCH_TP=$(meta_traceparent "$PARENT/state/ios.meta")
RELAUNCH_INJECTED=$(remote_injected_traceparent)
[ "$RELAUNCH_TP" = "$PARENT_TP" ] \
  || fail "a remote relaunch must keep the task's recorded carrier (first='$PARENT_TP' relaunch='$RELAUNCH_TP')"
[ "$RELAUNCH_INJECTED" = "$PARENT_TP" ] \
  || fail "a remote relaunch must re-export the original carrier (first='$PARENT_TP' injected='$RELAUNCH_INJECTED')"
pass "relaunch: a remote-routed second mate keeps one stable identity across restarts"

# --- per-task boundary: ambient carriers are never adopted or shared ---------
# A persistent supervisor exports its own launch-time TRACEPARENT for its whole
# life. A second remote route resolved from that same environment must root its
# own trace rather than chain onto it or onto the first route.
AMBIENT='00-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab-bbbbbbbbbbbbbbbb-01'
FM_SECONDMATE_CHARTER='Own the second build Mac.' \
  FM_SECONDMATE_SCOPE='second remote domain' \
  TRACEPARENT="$AMBIENT" \
  remote_env "$ROOT/bin/fm-remote-home-seed.sh" ios2 remote-mac "$REMOTE_ROOT" "$SECOND_HOME" --no-projects >/dev/null \
  || fail "second remote seed failed"
rm -f "$TMUX_STATE"
: > "$TMUX_LOG"
TRACEPARENT="$AMBIENT" remote_env "$ROOT/bin/fm-spawn.sh" ios2 --secondmate >/dev/null 2>&1 \
  || fail "second remote secondmate spawn failed"
SECOND_TP=$(meta_traceparent "$PARENT/state/ios2.meta")
fm_trace_context_valid "$SECOND_TP" \
  || fail "the second remote route must record a valid carrier (got '$SECOND_TP')"
[ "${SECOND_TP:3:32}" != "${AMBIENT:3:32}" ] \
  || fail "a remote route must not adopt the spawning process's ambient trace id (got '$SECOND_TP')"
[ "${SECOND_TP:3:32}" != "${PARENT_TP:3:32}" ] \
  || fail "two remote routes must root distinct traces (first='$PARENT_TP' second='$SECOND_TP')"
[ "$(remote_injected_traceparent)" = "$SECOND_TP" ] \
  || fail "the second remote route's pane must receive its own recorded carrier"
pass "boundary: each remote-routed second mate roots its own trace and never adopts the spawning environment's carrier"

# --- the enablement flag is one allowlist, shared by both remote ends --------
# config/trace-context reaches the remote home only because the sender and the
# receiver derive the same declared inherited-material set. Prove the receiver
# accepts it as ordinary inherited material rather than by name.
PROTOCOL_HOME="$TMP_ROOT/protocol-home"
mkdir -p "$PROTOCOL_HOME/config" "$PROTOCOL_HOME/data" "$PROTOCOL_HOME/state"
: > "$TMP_ROOT/flag-payload"
FLAG_BYTES=$(LC_ALL=C wc -c < "$TMP_ROOT/flag-payload" | tr -d ' ')
if command -v shasum >/dev/null 2>&1; then
  FLAG_HASH=$(shasum -a 256 "$TMP_ROOT/flag-payload" | awk '{print $1}')
else
  FLAG_HASH=$(sha256sum "$TMP_ROOT/flag-payload" | awk '{print $1}')
fi
FM_HOME="$PROTOCOL_HOME" "$REMOTE_ROOT/bin/fm-remote-inherit.sh" \
  put config/trace-context "$FLAG_BYTES" "$FLAG_HASH" 1 < "$TMP_ROOT/flag-payload" >/dev/null \
  || fail "the remote inherit receiver refused a declared inheritable item"
assert_present "$PROTOCOL_HOME/config/trace-context" "the accepted inherited enablement flag was not published"
if FM_HOME="$PROTOCOL_HOME" "$REMOTE_ROOT/bin/fm-remote-inherit.sh" \
  put config/secondmate-harness "$FLAG_BYTES" "$FLAG_HASH" 1 < "$TMP_ROOT/flag-payload" >/dev/null 2>&1; then
  fail "the remote inherit receiver accepted an item outside the declared set"
fi
assert_absent "$PROTOCOL_HOME/config/secondmate-harness" "a non-inheritable item was published remotely"
pass "allowlist: the remote receiver accepts exactly the declared inherited-material set, including the enablement flag"

# --- the delivery flag is the only caller-supplied path to a pane export -----
# A remote host receives the carrier as an argument rather than resolving it, so
# that argument is refused unless it is a secondmate launch carrying a strictly
# valid W3C value. Nothing else may reach `export TRACEPARENT=`.
FLAG_HOME="$TMP_ROOT/flag-home"
mkdir -p "$FLAG_HOME/state" "$FLAG_HOME/data" "$FLAG_HOME/config" "$FLAG_HOME/projects" "$TMP_ROOT/flag-proj"
VALID='00-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab-bbbbbbbbbbbbbbbb-01'
try_flag() { # <expect-substring> <message> [extra args...]
  local expect=$1 message=$2 out
  shift 2
  if out=$(FM_SPAWN_NO_GUARD=1 FM_HOME="$FLAG_HOME" "$ROOT/bin/fm-spawn.sh" \
    flag-a-b1 "$TMP_ROOT/flag-proj" "$@" 2>&1); then
    fail "$message (the spawn succeeded instead)"
  fi
  assert_contains "$out" "$expect" "$message"
}
try_flag 'applies only to --secondmate spawns' \
  "a ship spawn must refuse a caller-supplied carrier" \
  --mode no-mistakes --yolo off --traceparent "$VALID"
try_flag 'not a valid W3C traceparent' \
  "a shell-metacharacter carrier must be refused before any pane export" \
  --secondmate --traceparent 'bogus; rm -rf /'
try_flag 'not a valid W3C traceparent' \
  "an all-zero trace id must be refused as W3C-invalid" \
  --secondmate --traceparent '00-00000000000000000000000000000000-bbbbbbbbbbbbbbbb-01'
try_flag 'requires a non-empty value' \
  "an empty carrier must be refused rather than silently ignored" \
  --secondmate --traceparent=
pass "delivery: a parent-supplied carrier is accepted only for a secondmate launch and only as a strict W3C value"

echo "ALL TESTS PASSED"
