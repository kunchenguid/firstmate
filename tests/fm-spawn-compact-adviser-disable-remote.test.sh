#!/usr/bin/env bash
# tests/fm-spawn-compact-adviser-disable-remote.test.sh - the compact-adviser
# kill switch must reach a second mate that Firstmate launches on another host.
#
# A remote second mate never reaches the local spawn path covered by
# tests/fm-spawn-compact-adviser-disable.test.sh: bin/fm-spawn.sh routes it
# through spawn_remote_secondmate, which hands the launch across the transport
# to the remote host's own fm-spawn. These assertions drive that real chain -
# parent fm-spawn -> fm-on -> the real remote entrypoint ->
# fm-remote-secondmate-control -> the remote host's fm-spawn - against a fake
# herdr CLI, so what the remote pane received is observable, and then execute
# that received command with a probe harness to read back the environment the
# remote agent would have started with.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/remote-herdr-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/remote-herdr-fixture.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(fm_test_tmproot fm-remote-compact-adviser)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
PARENT="$TMP_ROOT/parent"
REMOTE_ROOT="$TMP_ROOT/remote-root"
REMOTE_HOME="$TMP_ROOT/remote-home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fake")
PROBEBIN="$TMP_ROOT/probebin"
HERDR_LOG="$TMP_ROOT/remote-herdr.log"
HERDR_STATE="$TMP_ROOT/remote-herdr.state"
CLAIMS="$TMP_ROOT/claims"
mkdir -p "$PARENT/data" "$PARENT/state" "$PARENT/config" "$PARENT/projects" \
  "$REMOTE_ROOT" "$CLAIMS" "$PROBEBIN" "$TMP_ROOT/pane-home"
trap 'FM_HOME="$PARENT" FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true; if [ -f "$TMP_ROOT/remote-jobs/worker.pid" ]; then kill "$(cat "$TMP_ROOT/remote-jobs/worker.pid")" 2>/dev/null || true; fi; rm -rf -- "$TMP_ROOT"' EXIT

# A synthetic value the remote launch must override rather than inherit, so a
# launch that only forwarded the ambient environment cannot pass as a floor.
CONTRARY=0

# The remote host's tracked code root is this branch, as a real git repository:
# fm-on and the remote entrypoint both require the dispatched command to be
# tracked there, and the remote side runs the real scripts under test.
(
  cd "$ROOT" || exit
  tar --exclude=.git --exclude=.no-mistakes --exclude=data --exclude=state --exclude=config -cf - .
) | (cd "$REMOTE_ROOT" && tar -xf -)

# The remote host's own non-second-mate tooling only has to stay resolvable;
# the second mate itself always launches on Herdr, whose fixture logs every
# invocation verbatim.
cat > "$REMOTE_ROOT/bin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$REMOTE_ROOT/bin/tmux"
install_remote_herdr_fixture "$REMOTE_ROOT" "$HERDR_STATE" "$HERDR_LOG" \
  "$TMP_ROOT/herdr-send-fail" "$TMP_ROOT/herdr.sock"
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
# The readiness gate is answered here rather than by the real doctor, which
# would inspect the RUNNER's own account; tests/fm-remote-doctor.test.sh owns
# the doctor's behavior against controlled account fixtures.
if printf '%s' "$4" | base64 --decode 2>/dev/null | tr '\0' '\n' | head -1 | grep -q '^fm-remote-doctor.sh$'; then
  printf 'ok: remote second-mate readiness confirmed on this host\n'
  exit 0
fi
exec "$FM_FAKE_REMOTE_ENTRYPOINT" "$@"
SH
chmod +x "$FAKEBIN/fake-ssh"

# The harness the remote pane would have started, replaced by a probe that
# reports the one environment fact under test.
cat > "$PROBEBIN/codex" <<'SH'
#!/bin/sh
printf '%s\n' "${COMPACT_ADVISER_DISABLE-unset}"
SH
chmod +x "$PROBEBIN/codex"

printf 'codex\n' > "$PARENT/config/secondmate-harness"
printf 'tmux\n' > "$PARENT/config/backend"
printf 'codex\n' > "$PARENT/config/crew-harness"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$PARENT/data/backlog.md"
printf '%s\n' "$$" > "$PARENT/state/.lock"

remote_env() {
  FM_HOME="$PARENT" \
  FM_ROOT_OVERRIDE="$REMOTE_ROOT" \
  FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
  FM_SSH_BIN="$FAKEBIN/fake-ssh" \
  FM_FAKE_REMOTE_ENTRYPOINT="$REMOTE_ROOT/bin/fm-remote-entrypoint.sh" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
  FM_REMOTE_JOB_STATE_ROOT="$TMP_ROOT/remote-jobs" \
  FM_FAKE_REMOTE_CWD="$TMP_ROOT" \
  FM_SEND_SETTLE=0 FM_SEND_SLEEP=0 \
  "$@"
}

# What the remote pane received, read back from the fixture's verbatim log. The
# fixture logs one line per invocation as the joined argv, so each payload sits
# between the pane id and the trailing session selector. The Herdr adapter sends
# a pre-launch export as a `pane run` line and the launch command itself as the
# unsubmitted literal `pane send-text`.
remote_pane_payload() {  # <verb>
  sed -n "s/^pane $1 [^ ]* \\(.*\\) --session [^ ]*\$/\\1/p" "$HERDR_LOG"
}
remote_launch_command() {
  remote_pane_payload send-text | grep 'encode launch-brief' | tail -1
}
remote_pane_exports() {
  remote_pane_payload run | grep '^export '
}

# Provision and register the remote route from the captain-facing primary.
FM_SECONDMATE_CHARTER='Own iOS delivery on the build Mac.' \
  FM_SECONDMATE_SCOPE='iOS implementation and Xcode validation' \
  remote_env "$ROOT/bin/fm-remote-home-seed.sh" ios remote-mac "$REMOTE_ROOT" "$REMOTE_HOME" --no-projects >/dev/null \
  || fail "remote seed did not provision the route under test"

run_remote_launch() {  # <label>
  local label=$1
  reset_remote_herdr_fixture "$HERDR_STATE"
  : > "$HERDR_LOG"
  remote_env "$ROOT/bin/fm-spawn.sh" ios --secondmate >/dev/null 2>&1 \
    || fail "$label: the remote second-mate launch failed"
}

# Replay what the remote pane received, in the order it received it, under a
# synthetic pane environment carrying the contrary value.
replay_remote_launch() {  # <preamble|bare>
  local shape=$1 preamble='' launch
  launch=$(remote_launch_command)
  [ -n "$launch" ] || fail "the remote pane received no launch command"
  [ "$shape" = bare ] || preamble=$(remote_pane_exports)
  env -i HOME="$TMP_ROOT/pane-home" PATH="$PROBEBIN:$PATH" TERM=xterm \
    COMPACT_ADVISER_DISABLE="$CONTRARY" \
    /bin/sh -c "$preamble
$launch"
}

# --- the remote route delivers the switch, allowlist absent -----------------
run_remote_launch 'allowlist absent'
remote_pane_exports | grep -qx 'export COMPACT_ADVISER_DISABLE=1' \
  || fail "the remote pane shell never received the compact-adviser export"
SEEN=$(replay_remote_launch preamble) \
  || fail "the command the remote pane received failed to run"
assert_equals 1 "$SEEN" \
  "a second mate launched on a remote host must start with the compact adviser disabled"
SEEN=$(replay_remote_launch bare) \
  || fail "the remote launch command failed to run on its own"
assert_equals 1 "$SEEN" \
  "the remote launch command must set the compact-adviser switch on its own, overriding a contrary remote pane value"
pass "a remote-routed second mate starts with the compact adviser disabled, from the pane export and from the launch command alike"

# --- the same holds through the cleared allowlisted environment -------------
# The allowlist is inherited local material, so the parent's opt-in is what puts
# the remote launch under /usr/bin/env -i. The switch is a floor, so it has to
# survive that host's cleared environment although nothing there ever set it.
: > "$PARENT/config/launch-env-allowlist"
run_remote_launch 'allowlist enabled'
assert_present "$REMOTE_HOME/config/launch-env-allowlist" \
  "the remote launch did not inherit the launch-environment opt-in"
LAUNCH=$(remote_launch_command)
assert_contains "$LAUNCH" '/usr/bin/env -i' \
  "an inherited allowlist should launch the remote second mate under a cleared environment"
SEEN=$(replay_remote_launch bare) \
  || fail "the cleared-environment remote launch failed to run"
assert_equals 1 "$SEEN" \
  "a remote second mate launched under the cleared allowlisted environment must still start with the compact adviser disabled"
pass "the remote route keeps the compact-adviser switch through the cleared allowlisted environment"

echo "ALL TESTS PASSED"
