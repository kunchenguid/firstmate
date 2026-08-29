#!/usr/bin/env bash
# shellcheck source=tests/test-entry.sh
. "$(dirname "$0")/test-entry.sh"
# Behavior: renewing a Pi credential before it expires, republishing it into the
# account home its consumers read, and refusing every way that can go wrong,
# without writing a token into the transcript or reaching the network on any
# path that must not.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-pi-refresh.py"
ADAPTER="$ROOT/bin/fm-pi-refresh.mjs"
# A marker standing in for token material, so a leak is caught by grep rather
# than by reading the output and hoping.
MARKER=fmtestpirefreshmarker

# File scope on purpose. Only one unit used to set this, which made the other
# units' isolation depend on the very property one of them asserts: a mutation
# that let a non-scheduled run stamp wrote a fixture heartbeat into the
# operator's real state root.
FM_PI_REFRESH_STATE_ROOT=$(fm_test_tmproot fm-pi-refresh-state)
FM_PI_REFRESH_LAUNCH_AGENTS_DIR=$(fm_test_tmproot fm-pi-refresh-agents)
export FM_PI_REFRESH_STATE_ROOT FM_PI_REFRESH_LAUNCH_AGENTS_DIR

file_mode() {
  python3 -c 'import os,sys; print("%o" % (os.stat(sys.argv[1]).st_mode & 0o777))' "$1"
}

# Build a pool whose slots differ in exactly the axis under test: how long the
# access token has left, and whether it can be renewed at all.
make_pool() {
  python3 - "$1" "$MARKER" <<'PY'
import json
import sys
import time

path, marker = sys.argv[1], sys.argv[2]
now = time.time() * 1000
day = 86400 * 1000


def entry(account, days, *, refresh=True, kind="oauth"):
    value = {
        "type": kind,
        "access": f"{marker}.access.{account}",
        "refresh": f"{marker}.refresh.{account}" if refresh else "",
        "accountId": account,
        "expires": now + days * day,
    }
    return value


json.dump(
    {
        "openai-codex": entry("acct-one", 2),
        "openai-codex-2": entry("acct-two", 9),
        "openai-codex-3": entry("acct-three", 1, refresh=False),
    },
    open(path, "w"),
    indent=2,
)
PY
}

# A Pi install that is only a shape: enough for the resolver to accept it, with
# no runtime behind it. The CLI-level contracts must hold without a real Pi.
make_fake_pi() {
  local root=$1
  mkdir -p "$root/pkg/dist" "$root/bin"
  # The real package name: the resolver checks it, because any directory with a
  # package.json used to pass and pushed the refusal one layer down into the
  # module import, where a wrong Pi reads as a missing file.
  printf '{"name":"@earendil-works/pi-coding-agent","version":"0.0.0","engines":{"node":">=22.19.0"}}\n' \
    >"$root/pkg/package.json"
  printf '#!/usr/bin/env node\n' >"$root/pkg/dist/cli.js"
  # Executable on purpose: a Pi entrypoint without the bit is not resolvable,
  # and the refusal under test would be that one rather than the intended one.
  chmod +x "$root/pkg/dist/cli.js"
  ln -sf "$root/pkg/dist/cli.js" "$root/bin/pi"
}

# A Node that answers the floor probe honestly and records that it was asked to
# run anything else. `--version` has to work, or the refusal under test would be
# the version refusal rather than the one being exercised.
make_fake_node() {
  local path=$1 version=$2 marker=$3 code=$4
  cat >"$path" <<SH
#!/bin/sh
if [ "\$1" = "--version" ]; then printf '%s\n' '$version'; exit 0; fi
: >'$marker'
exit $code
SH
  chmod +x "$path"
}

# A launchctl that succeeds and records what it was asked to do, so the install
# sequence is asserted rather than assumed. A real launchctl would register a
# real job on the developer's machine.
# `registers` is the case a return code cannot express: launchctl accepting a
# bootstrap while launchd ends up holding nothing. Without it, checking the
# return code and checking the loaded state are the same assertion.
make_fake_launchctl() {
  local path=$1 log=$2 loaded=$3 bootstrap_code=${4:-0} bootout_code=${5:-0} registers=${6:-1}
  cat >"$path" <<SH
#!/bin/sh
printf '%s\n' "\$*" >>'$log'
case "\$1" in
  print) [ -f '$loaded' ] ;;
  bootstrap)
    if [ $bootstrap_code -eq 0 ] && [ $registers -eq 1 ]; then : >'$loaded'; fi
    exit $bootstrap_code
    ;;
  bootout) [ $bootout_code -ne 0 ] || rm -f '$loaded'; exit $bootout_code ;;
esac
SH
  chmod +x "$path"
}

# Read the nonce launchd would carry, so a test can run the job the way the
# schedule runs it instead of asserting against a copy of the mechanism.
installed_nonce() {
  python3 -c '
import plistlib, sys
print(plistlib.load(open(sys.argv[1], "rb"))["EnvironmentVariables"]["FM_PI_REFRESH_ACTIVATION_NONCE"])
' "$1"
}

scheduler_contract() {
  local work out code fakebin piroot log loaded agents state nonce
  work=$(fm_test_tmproot fm-pi-refresh-schedule)
  make_pool "$work/auth.json"
  piroot=$work/pi
  make_fake_pi "$piroot"
  fakebin=$(fm_fakebin "$work")
  log=$work/launchctl.log
  loaded=$work/launchd-holds-it
  agents=$work/agents
  state=$work/state
  make_fake_launchctl "$fakebin/launchctl" "$log" "$loaded"
  make_fake_node "$fakebin/node" v99.0.0 "$work/node-ran" 3
  mkdir -p "$agents"

  # The install refuses a non-macOS host, and CI runs this file on Linux. The
  # seam is the one bin/fm-checkout-refresh.sh uses for the same reason.
  export FM_PI_REFRESH_PLATFORM=Darwin
  export FM_PI_REFRESH_LAUNCH_AGENTS_DIR="$agents"
  export FM_PI_REFRESH_STATE_ROOT="$state"
  export FM_PI_REFRESH_LAUNCHCTL="$fakebin/launchctl"
  export FM_PI_BIN="$piroot/bin/pi"
  export FM_PI_NODE_BIN="$fakebin/node"

  code=0
  out=$(FM_PI_REFRESH_PLATFORM=Linux python3 "$TOOL" install-scheduler 2>&1) || code=$?
  expect_code 1 "$code" "install-scheduler accepted a host with no scheduler adapter"
  assert_contains "$out" "Linux" "the refusal did not name the host it refused"

  out=$(python3 "$TOOL" scheduler-status 2>&1) || true
  assert_contains "$out" "absent" "an uninstalled schedule did not report absent"

  code=0
  out=$(python3 "$TOOL" ensure 2>&1) || code=$?
  expect_code 1 "$code" "ensure passed with no schedule installed"
  assert_contains "$out" "install-scheduler" "ensure did not name how to install one"

  code=0
  out=$(python3 "$TOOL" install-scheduler --interval-seconds 1 2>&1) || code=$?
  expect_code 1 "$code" "install-scheduler accepted an interval below its own floor"
  assert_absent "$agents/com.firstmate.pi-auth-refresh.plist" "a refused interval still wrote a plist"

  python3 "$TOOL" install-scheduler --interval-seconds 900 >/dev/null 2>&1 \
    || fail "install-scheduler refused a healthy host"
  assert_present "$agents/com.firstmate.pi-auth-refresh.plist" "no schedule plist was written"
  expect_code 600 "$(file_mode "$agents/com.firstmate.pi-auth-refresh.plist")" \
    "the schedule plist is not owner-only"
  assert_grep 'bootout' "$log" "install never booted out a previous job"
  python3 - "$log" <<'PY' || fail "install bootstrapped before it booted out"
import sys

lines = [line.strip() for line in open(sys.argv[1]) if line.strip()]
boot = next(i for i, line in enumerate(lines) if line.startswith("bootout"))
strap = next(i for i, line in enumerate(lines) if line.startswith("bootstrap"))
assert boot < strap, lines
PY

  # A LaunchAgent inherits almost no environment, so every path the job needs
  # at fire time has to be absolute inside the plist.
  python3 - "$agents/com.firstmate.pi-auth-refresh.plist" "$TOOL" <<'PY' \
    || fail "the schedule plist does not describe the job it must run"
import plistlib
import pathlib
import sys

job = plistlib.load(open(sys.argv[1], "rb"))
assert job["Label"] == "com.firstmate.pi-auth-refresh", job["Label"]
assert job["RunAtLoad"] is True, job
assert job["StartInterval"] == 900, job
arguments = job["ProgramArguments"]
assert str(pathlib.Path(sys.argv[2]).resolve()) in arguments, arguments
assert arguments[-5:-2] == ["run-once", "--all", "--scheduled"], arguments
assert arguments[-2] == "--azure-home-config", arguments
assert pathlib.Path(arguments[-1]).is_absolute(), arguments
environment = job["EnvironmentVariables"]
for name in ("PATH", "HOME", "FM_PI_BIN", "FM_PI_NODE_BIN",
             "FM_PI_REFRESH_STATE_ROOT", "FM_PI_REFRESH_ACTIVATION_NONCE",
             # The job checks its nonce against its own plist, so it must be
             # told where that plist is rather than assuming the default path.
             "FM_PI_REFRESH_LAUNCH_AGENTS_DIR"):
    assert name in environment, name
for name in ("HOME", "FM_PI_BIN", "FM_PI_NODE_BIN", "FM_PI_REFRESH_STATE_ROOT"):
    assert environment[name].startswith("/"), (name, environment[name])
assert len(environment["FM_PI_REFRESH_ACTIVATION_NONCE"]) >= 16, "the nonce is guessable"
PY

  out=$(python3 "$TOOL" scheduler-status 2>&1) || true
  assert_contains "$out" "unproven" "a schedule that never ran reported as healthy"

  # The nonce is the whole mechanism: a `--scheduled` typed by hand carries
  # none, so it must write nothing at all. Otherwise it could either forge
  # proof of life or destroy the real one.
  python3 "$TOOL" run-once --source "$work/auth.json" --slot openai-codex --scheduled \
    --backup-root "$work/backups" --destination-root "$work/homes" >/dev/null 2>&1 || true
  assert_absent "$state/heartbeat.json" "a hand-run --scheduled faked scheduler liveness"

  # Run it the way launchd runs it: same command, same nonce.
  nonce=$(installed_nonce "$agents/com.firstmate.pi-auth-refresh.plist")
  FM_PI_REFRESH_ACTIVATION_NONCE="$nonce" python3 "$TOOL" run-once \
    --source "$work/auth.json" --slot openai-codex --scheduled \
    --backup-root "$work/backups" --destination-root "$work/homes" >/dev/null 2>&1 || true
  assert_present "$state/heartbeat.json" "the scheduled invocation left no proof of life"
  expect_code 600 "$(file_mode "$state/heartbeat.json")" "the heartbeat is not owner-only"
  out=$(python3 "$TOOL" scheduler-status --json 2>&1) || true
  assert_contains "$out" '"heartbeat_kind": "failed"' "a failed scheduled run reported as ok"
  assert_contains "$out" "failing" "a failing schedule did not report as failing"

  # A profile that needs a browser is not a broken schedule. Calling it one is
  # the alarm that gets ignored, so it reports separately and ensure passes.
  FM_PI_REFRESH_ACTIVATION_NONCE="$nonce" python3 "$TOOL" run-once \
    --source "$work/auth.json" --slot openai-codex-3 --scheduled \
    --backup-root "$work/backups" --destination-root "$work/homes" >/dev/null 2>&1 || true
  out=$(python3 "$TOOL" scheduler-status 2>&1) || true
  assert_contains "$out" "attention" "an unrenewable profile reported the schedule as broken"
  python3 "$TOOL" ensure >/dev/null 2>&1 \
    || fail "ensure called a working schedule unavailable because a profile needs a login"

  # Machine-global: a different checkout must read the same job the same way,
  # or eight of this machine's nine homes warn at every session start and the
  # remedy they print tears the working job down.
  local elsewhere
  elsewhere=$work/other-home/bin
  mkdir -p "$elsewhere"
  cp "$ROOT/bin/fm-pi-refresh.py" "$ROOT/bin/fm-pi-account-home.py" \
    "$ROOT/bin/fm-credential-expiry.py" "$ROOT/bin/fm-pi-refresh.mjs" "$elsewhere/"
  out=$(python3 "$elsewhere/fm-pi-refresh.py" scheduler-status 2>&1) || true
  assert_not_contains "$out" "different checkout" \
    "a second Firstmate home called the machine-global schedule foreign"
  assert_contains "$out" "attention" "a second home did not read the same schedule state"

  # An old heartbeat is staleness, not health, however good its last outcome.
  python3 - "$state/heartbeat.json" <<'PY'
import json
import sys

path = sys.argv[1]
value = json.load(open(path))
value["kind"] = "ok"
value["ok"] = True
value["at"] = "2001-01-01T00:00:00Z"
json.dump(value, open(path, "w"))
PY
  out=$(python3 "$TOOL" scheduler-status 2>&1) || true
  assert_contains "$out" "stale" "an ancient heartbeat reported as healthy"

  # A plist that launchd is not holding is installed, not working.
  rm -f "$loaded"
  out=$(python3 "$TOOL" scheduler-status 2>&1) || true
  assert_contains "$out" "unloaded" "an unloaded schedule reported as healthy"

  # launchd holding the label with nothing describing it is its own state, and
  # was previously inexpressible because absent was decided before launchd was
  # ever asked.
  : >"$loaded"
  mv "$agents/com.firstmate.pi-auth-refresh.plist" "$work/parked.plist"
  out=$(python3 "$TOOL" scheduler-status 2>&1) || true
  assert_contains "$out" "orphaned" "a running job with no plist reported as absent"
  mv "$work/parked.plist" "$agents/com.firstmate.pi-auth-refresh.plist"

  # A job that runs something else, or that never stamps, is not this schedule.
  python3 - "$agents/com.firstmate.pi-auth-refresh.plist" <<'PY'
import plistlib
import sys

path = sys.argv[1]
job = plistlib.load(open(path, "rb"))
job["ProgramArguments"] = ["/usr/bin/true"]
plistlib.dump(job, open(path, "wb"))
PY
  out=$(python3 "$TOOL" scheduler-status 2>&1) || true
  assert_contains "$out" "foreign" "a job running something else was claimed as this schedule"

  python3 - "$agents/com.firstmate.pi-auth-refresh.plist" "$TOOL" <<'PY'
import pathlib
import plistlib
import sys

path = sys.argv[1]
job = plistlib.load(open(path, "rb"))
job["ProgramArguments"] = ["/usr/bin/python3", str(pathlib.Path(sys.argv[2]).resolve()),
                           "run-once", "--all"]
plistlib.dump(job, open(path, "wb"))
PY
  out=$(python3 "$TOOL" scheduler-status 2>&1) || true
  assert_contains "$out" "proof of life" "a schedule that never stamps was accepted as healthy"

  # A refused bootstrap must not leave the new definition on disk with the old
  # job still running: every report reads the file, so it would describe a job
  # launchd never accepted.
  python3 "$TOOL" install-scheduler --interval-seconds 3600 >/dev/null 2>&1 \
    || fail "reinstall refused"
  make_fake_launchctl "$fakebin/launchctl" "$log" "$loaded" 5 0
  code=0
  out=$(python3 "$TOOL" install-scheduler --interval-seconds 1800 2>&1) || code=$?
  expect_code 1 "$code" "a refused bootstrap was reported as an install"
  python3 - "$agents/com.firstmate.pi-auth-refresh.plist" <<'PY' \
    || fail "a refused install left its own definition on disk"
import plistlib
import sys

job = plistlib.load(open(sys.argv[1], "rb"))
assert job["StartInterval"] == 3600, job["StartInterval"]
PY

  # launchctl reporting success while launchd holds nothing is not an install.
  # A return code cannot see this; only re-probing the loaded state can.
  make_fake_launchctl "$fakebin/launchctl" "$log" "$loaded" 0 0 0
  rm -f "$loaded"
  code=0
  out=$(python3 "$TOOL" install-scheduler --interval-seconds 3600 2>&1) || code=$?
  expect_code 1 "$code" "an install launchd did not accept was reported as installed"
  assert_contains "$out" "not holding it" "the refusal did not say launchd holds nothing"
  make_fake_launchctl "$fakebin/launchctl" "$log" "$loaded" 0 0 1
  python3 "$TOOL" install-scheduler --interval-seconds 3600 >/dev/null 2>&1 \
    || fail "reinstall refused after a non-registering bootstrap"

  # A bootout that does not take must not be reported as a removal, and the
  # plist must stay so the job launchd is still running remains describable.
  make_fake_launchctl "$fakebin/launchctl" "$log" "$loaded" 0 5
  : >"$loaded"
  code=0
  out=$(python3 "$TOOL" uninstall-scheduler 2>&1) || code=$?
  expect_code 1 "$code" "uninstall reported success while launchd kept the job"
  assert_present "$agents/com.firstmate.pi-auth-refresh.plist" \
    "uninstall removed the only description of a job that is still running"

  make_fake_launchctl "$fakebin/launchctl" "$log" "$loaded" 0 0
  python3 "$TOOL" uninstall-scheduler >/dev/null 2>&1 || fail "uninstall-scheduler refused"
  assert_absent "$agents/com.firstmate.pi-auth-refresh.plist" "uninstall left the plist behind"

  # Bootstrap must surface an unhealthy schedule, and the real bootstrap must
  # be the thing that does it.
  out=$(cd "$ROOT" && FM_BOOTSTRAP_BACKGROUND_BYPASS=1 FM_PI_REFRESH_BOOTSTRAP_TEST=1 \
    FM_BOOTSTRAP_DETECT_ONLY=1 FM_FAKE_TREEHOUSE_LEASE_HELP=1 \
    bash "$ROOT/bin/fm-bootstrap.sh" 2>&1 || true)
  assert_contains "$out" "PI_AUTH_REFRESH" \
    "the real bootstrap stayed silent about a missing schedule when asked not to"

  out=$(cd "$ROOT" && FM_BOOTSTRAP_BACKGROUND_BYPASS=1 \
    FM_BOOTSTRAP_DETECT_ONLY=1 FM_FAKE_TREEHOUSE_LEASE_HELP=1 \
    bash "$ROOT/bin/fm-bootstrap.sh" 2>&1 || true)
  assert_not_contains "$out" "PI_AUTH_REFRESH" \
    "the schedule report leaked into every bootstrap run under the test bypass"

  # The install target operators are told to run, driven through the real
  # bootstrap rather than by calling the tool directly.
  out=$(cd "$ROOT" && FM_PI_REFRESH_PLATFORM=Darwin \
    FM_PI_REFRESH_LAUNCH_AGENTS_DIR="$agents" FM_PI_REFRESH_STATE_ROOT="$state" \
    FM_PI_REFRESH_LAUNCHCTL="$fakebin/launchctl" FM_PI_BIN="$piroot/bin/pi" \
    FM_PI_NODE_BIN="$fakebin/node" \
    bash "$ROOT/bin/fm-bootstrap.sh" install pi-auth-refresh 2>&1 || true)
  assert_contains "$out" "pi-auth-refresh" "the bootstrap install target named nothing"
  assert_present "$agents/com.firstmate.pi-auth-refresh.plist" \
    "bin/fm-bootstrap.sh install pi-auth-refresh installed no schedule"
  python3 "$TOOL" uninstall-scheduler >/dev/null 2>&1 || true

  unset FM_PI_REFRESH_PLATFORM FM_PI_REFRESH_LAUNCHCTL FM_PI_BIN FM_PI_NODE_BIN
  export FM_PI_REFRESH_LAUNCH_AGENTS_DIR="$agents"
  pass "the schedule is machine-global, stamps only for launchd, and reports absent, orphaned, foreign, unloaded, unproven, stale, failing and attention apart from healthy"
}

scheduled_azure_pool_contract() {
  local work primary azure config out code
  work=$(fm_test_tmproot fm-pi-refresh-azure-pool)
  primary=$work/primary
  azure=$work/azure
  config=$work/azure-worker-account-home
  mkdir -p "$primary" "$azure"
  python3 - "$primary/auth.json" "$azure/auth.json" "$MARKER" <<'PY'
import json
import sys
import time

primary, azure, marker = sys.argv[1:]
day = 86400 * 1000
now = time.time() * 1000
json.dump({
    "openai-codex": {
        "type": "oauth", "access": marker + ".primary.access",
        "refresh": marker + ".primary.refresh", "accountId": "primary-account",
        "expires": now + 9 * day,
    }
}, open(primary, "w"))
json.dump({
    "openai-codex": {
        "type": "oauth", "access": marker + ".azure.access",
        "refresh": "", "accountId": "azure-account", "expires": now + day,
    }
}, open(azure, "w"))
PY
  printf '%s\n' "$azure" > "$config"

  code=0
  out=$(python3 "$TOOL" run-once --source "$primary/auth.json" --all --scheduled \
    --azure-home-config "$config" --backup-root "$work/backups" \
    --destination-root "$work/homes" 2>&1) || code=$?
  expect_code 1 "$code" "the scheduled run ignored an Azure pool that needs interactive login"
  assert_contains "$out" "interactive login" "the Azure pool refusal did not reach the scheduler result"
  assert_not_contains "$out" "$MARKER" "the two-pool scheduled refusal leaked credential material"
  pass "the machine scheduler owns a separately configured Azure Pi pool"
}

selection_contract() {
  local work pool out code
  work=$(fm_test_tmproot fm-pi-refresh-select)
  pool=$work/auth.json
  make_pool "$pool"

  out=$(python3 "$TOOL" report --source "$pool" --json 2>&1) \
    || fail "report refused a readable pool"
  assert_not_contains "$out" "$MARKER" "report leaked token material"

  python3 - "$out" <<'PY' || fail "report classified the pool wrongly"
import json
import sys

value = json.loads(sys.argv[1])
due = {record["slot"] for record in value["due"]}
held = {record["slot"]: record["reason"] for record in value["held"]}
assert due == {"openai-codex"}, due
assert "openai-codex-2" in held and "horizon" in held["openai-codex-2"], held
assert held.get("openai-codex-3", "").startswith("unrenewable"), held
# The account is reported, and only as a digest.
assert all(record["account"] != "acct-one" for record in value["due"]), value
PY

  # A slot outside the horizon becomes due when the horizon widens. Without
  # this the horizon could be ignored entirely and the split above would still
  # look right.
  out=$(python3 "$TOOL" report --source "$pool" --horizon-seconds 864000 --json 2>&1) \
    || fail "report refused a widened horizon"
  python3 - "$out" <<'PY' || fail "the renewal horizon does not select"
import json
import sys

value = json.loads(sys.argv[1])
assert {record["slot"] for record in value["due"]} == {"openai-codex", "openai-codex-2"}, value
PY

  # Reporting is a local read. It must not be able to reach a token endpoint,
  # so a Node that records being run proves the adapter was never invoked.
  local fakebin marker
  fakebin=$(fm_fakebin "$work")
  marker=$work/node-was-run
  make_fake_node "$fakebin/node" v99.0.0 "$marker" 1
  PATH="$fakebin:$PATH" FM_PI_NODE_BIN="$fakebin/node" \
    python3 "$TOOL" report --source "$pool" >/dev/null 2>&1 \
    || fail "report refused with a stubbed Node on PATH"
  assert_absent "$marker" "report invoked the renewal adapter"

  code=0
  out=$(python3 "$TOOL" run-once --source "$pool" 2>&1) || code=$?
  # 1, not 2: the sibling credential tools refuse through their own error class
  # rather than through argparse, so an operator gets one refusal contract.
  expect_code 1 "$code" "run-once accepted no slot selection"
  assert_contains "$out" "--slot" "the refusal did not name how to select a profile"

  pass "report names the due, the held, and the unrenewable without a token or a network call"
}

refusal_contract() {
  local work pool out code fakebin marker piroot
  work=$(fm_test_tmproot fm-pi-refresh-refuse)
  pool=$work/auth.json
  make_pool "$pool"
  piroot=$work/pi
  make_fake_pi "$piroot"
  fakebin=$(fm_fakebin "$work")
  marker=$work/adapter-was-run

  # An adapter that fails must not be reported as a renewal, and the pre-rotation
  # copy must already exist when it fails: the copy is the only thing standing
  # between an interrupted in-place write and every slot in the file.
  make_fake_node "$fakebin/node" v99.0.0 "$marker" 3
  code=0
  out=$(FM_PI_BIN="$piroot/bin/pi" FM_PI_NODE_BIN="$fakebin/node" \
    python3 "$TOOL" run-once --source "$pool" --slot openai-codex \
    --backup-root "$work/backups" --destination-root "$work/homes" 2>&1) || code=$?
  expect_code 1 "$code" "a failed adapter was reported as a renewal"
  assert_present "$marker" "run-once never invoked the adapter"
  assert_not_contains "$out" "$MARKER" "the refusal leaked token material"
  [ -n "$(find "$work/backups" -name 'auth.json.*' -type f 2>/dev/null)" ] \
    || fail "run-once rotated without first copying the pool"
  expect_code 600 \
    "$(file_mode "$(find "$work/backups" -name 'auth.json.*' -type f | head -1)")" \
    "the pre-rotation copy is not owner-only"

  # A Node below the floor the install declares does not merely warn: it dies
  # inside undici with an unrelated message. Refusing by version keeps that from
  # being reported as a provider failure.
  make_fake_node "$fakebin/oldnode" v20.20.2 "$work/oldnode-ran" 0
  code=0
  out=$(FM_PI_BIN="$piroot/bin/pi" FM_PI_NODE_BIN="$fakebin/oldnode" \
    python3 "$TOOL" run-once --source "$pool" --slot openai-codex \
    --backup-root "$work/backups" --destination-root "$work/homes" 2>&1) || code=$?
  expect_code 1 "$code" "a Node below the declared floor was accepted"
  assert_contains "$out" "22" "the refusal did not name the floor it applied"
  assert_absent "$work/oldnode-ran" "the refused Node was run anyway"

  # A run whose only selected profile cannot be renewed at all exits non-zero:
  # a scheduled run must not report success over an account that needs a login.
  code=0
  out=$(FM_PI_BIN="$piroot/bin/pi" FM_PI_NODE_BIN="$fakebin/node" \
    python3 "$TOOL" run-once --source "$pool" --slot openai-codex-3 \
    --backup-root "$work/backups" --destination-root "$work/homes" 2>&1) || code=$?
  expect_code 1 "$code" "an unrenewable profile was reported as a clean run"
  assert_contains "$out" "unrenewable" "the report did not name why it cannot be renewed"
  assert_absent "$work/adapter-was-run-unrenewable" "an unrenewable profile reached the adapter"

  code=0
  out=$(python3 "$TOOL" run-once --source "$pool" --slot no-such-slot \
    --backup-root "$work/backups" --destination-root "$work/homes" 2>&1) || code=$?
  expect_code 1 "$code" "a slot absent from the pool was accepted"
  assert_contains "$out" "no-such-slot" "the refusal did not name the missing slot"

  pass "run-once copies before it rotates, and refuses a failed adapter, an underpowered Node, an unrenewable profile, and an absent slot"
}

republish_contract() {
  local work pool out
  work=$(fm_test_tmproot fm-pi-refresh-republish)
  pool=$work/auth.json
  make_pool "$pool"
  mkdir -p "$work/homes/openai-codex"

  # The republish and verify halves drive the real projection tool and the real
  # expiry owner, not a restatement of either. Only a home that already exists
  # is republished, because the reviewer roster names homes by path and one
  # appearing on its own is a reviewer nobody added.
  python3 - "$TOOL" "$pool" "$work/homes" <<'PY' \
    || fail "the real projection and expiry owners rejected a republished home"
import importlib.util
import pathlib
import sys

spec = importlib.util.spec_from_file_location("refresh", sys.argv[1])
refresh = importlib.util.module_from_spec(spec)
spec.loader.exec_module(refresh)

pool = pathlib.Path(sys.argv[2])
homes = pathlib.Path(sys.argv[3])
present, absent = refresh.reproject(
    source=pool, destination_root=homes, slots=["openai-codex", "openai-codex-2"]
)
assert present == ["openai-codex"], present
assert absent == ["openai-codex-2"], absent
assert (homes / "openai-codex" / "auth.json").is_file()
assert not (homes / "openai-codex-2").exists(), "an unrequested account home was created"

verified = refresh.verify_homes(homes, present)
assert verified[0]["state"] == "usable", verified
PY

  # Verification is a gate, not a report: a republished home whose credential
  # dies inside the margin must refuse rather than be counted as renewed.
  python3 - "$TOOL" "$work/homes" <<'PY' \
    || fail "verification admitted a home that expires inside its margin"
import importlib.util
import json
import pathlib
import sys

spec = importlib.util.spec_from_file_location("refresh", sys.argv[1])
refresh = importlib.util.module_from_spec(spec)
spec.loader.exec_module(refresh)

home = pathlib.Path(sys.argv[2]) / "openai-codex"
credential = home / "auth.json"
value = json.loads(credential.read_text())
value["openai-codex"]["expires"] = 1000.0
credential.write_text(json.dumps(value))
try:
    refresh.verify_homes(pathlib.Path(sys.argv[2]), ["openai-codex"])
except refresh.RefreshError as error:
    assert "openai-codex" in str(error), error
else:
    raise AssertionError("an expired republished home was accepted")
PY

  out=$(cat "$work/homes/openai-codex/auth.json")
  assert_contains "$out" "openai-codex" "the republished home lost its consumer key"

  pass "renewed profiles republish only into homes that exist, and a home that expires inside its margin refuses"
}

pool_integrity_contract() {
  local work pool
  work=$(fm_test_tmproot fm-pi-refresh-integrity)
  pool=$work/auth.json
  make_pool "$pool"

  python3 - "$TOOL" "$pool" <<'PY' || fail "pool damage was not detected"
import importlib.util
import pathlib
import sys

spec = importlib.util.spec_from_file_location("refresh", sys.argv[1])
refresh = importlib.util.module_from_spec(spec)
spec.loader.exec_module(refresh)

pool = pathlib.Path(sys.argv[2])
expected = {"openai-codex", "openai-codex-2", "openai-codex-3"}
assert refresh.pool_is_intact(pool, expected) == "", "an intact pool was called damaged"

pool.write_text('{"openai-codex": {}}')
assert "lost profiles" in refresh.pool_is_intact(pool, expected)

pool.write_text("not json at all")
assert "no longer reads as JSON" in refresh.pool_is_intact(pool, expected)
PY

  # Backups protect exactly one failure and are credential material at rest
  # otherwise, so the run prunes down to the retained count.
  python3 - "$TOOL" "$work" <<'PY' || fail "backups were not bounded"
import importlib.util
import pathlib
import stat
import sys

spec = importlib.util.spec_from_file_location("refresh", sys.argv[1])
refresh = importlib.util.module_from_spec(spec)
spec.loader.exec_module(refresh)

work = pathlib.Path(sys.argv[2])
source = work / "seed.json"
source.write_text('{"openai-codex": {}}')
root = work / "backups"
expected = {"openai-codex"}
made = [
    refresh.backup_pool(source, root, now=1_700_000_000 + index * 60, expected=expected)
    for index in range(refresh.BACKUP_KEEP + 2)
]

# The copy is proved to be a copy before it is offered as one: an unlocked read
# of a pool being written can tear, and a torn copy is worse than none because
# it is only ever reached for by an operator whose pool is already damaged.
torn = work / "torn.json"
torn.write_text('{"openai-codex": {}, "openai-codex-2": {}}')
try:
    refresh.backup_pool(torn, root, now=1_700_000_999, expected={"openai-codex", "gone"})
except refresh.RefreshError as error:
    assert "did not come out intact" in str(error), error
else:
    raise AssertionError("a copy missing a profile was accepted as a backup")
assert all(path.is_file() for path in made), made
assert stat.S_IMODE(root.stat().st_mode) == 0o700, oct(root.stat().st_mode)
refresh.prune_backups(root, refresh.BACKUP_KEEP)
kept = sorted(path.name for path in root.glob("auth.json.*"))
assert len(kept) == refresh.BACKUP_KEEP, kept
assert kept == sorted(path.name for path in made)[-refresh.BACKUP_KEEP :], kept
PY

  pass "a damaged pool is named rather than reported as renewed, and the pre-rotation copies stay bounded and owner-only"
}

# Every outcome the adapter can report, driven through the REAL refreshSlots
# with a store that keeps `modify`'s contract. This unit needs Node and nothing
# else, because the classification it pins is the adapter's own logic; the
# integration with Pi's credential store is the next unit's job. Splitting them
# is the point: the previous shape put the redaction and the rotation decision
# behind a `pi is installed` check, so both were compiled out on the gate.
adapter_outcome_contract() {
  local work
  work=$(fm_test_tmproot fm-pi-refresh-outcomes)
  command -v node >/dev/null 2>&1 || fail "node is required to run the renewal adapter"

  node --input-type=module -e "
const adapter = await import('file://$ADAPTER');

// Faithful to the one behavior the classification depends on: a callback that
// returns undefined leaves the stored credential alone and modify hands that
// same stored credential back, which is otherwise indistinguishable from a
// successful rotation that returned an identical credential.
const makeStore = (data) => ({
  data,
  async read(slot) { return this.data[slot]; },
  async modify(slot, fn) {
    const next = await fn(this.data[slot]);
    if (next !== undefined) this.data[slot] = next;
    return this.data[slot];
  },
});

const codex = (id) => ({ type: 'oauth', access: 'a.' + id, refresh: 'r.' + id, expires: 1, accountId: id });
const run = (data, oauth, slots) => adapter.refreshSlots({
  storeFactory: () => makeStore(data), oauth, poolPath: '$work/unused.json', slots, timeoutMs: 1000,
});
const only = async (data, oauth, slot) => (await run(data, oauth, [slot]))[0];

const rotating = { refresh: async (c) => ({ ...c, access: 'NEW.' + c.accountId, refresh: 'NEWR.' + c.accountId }) };
const identical = { refresh: async (c) => ({ ...c }) };
const drifting = { refresh: async (c) => ({ ...c, access: 'z', accountId: 'someone-else' }) };
const never = { refresh: async () => { throw new Error('boom'); } };

let r = await only({ s: codex('one') }, rotating, 's');
if (r.outcome !== 'refreshed') throw new Error('a rotation was not reported: ' + r.outcome);
if (r.access_rotated !== true || r.account_stable !== true) throw new Error('rotation flags wrong: ' + JSON.stringify(r));

// The case a truthy return cannot distinguish on its own.
r = await only({ s: codex('one') }, identical, 's');
if (r.outcome !== 'unchanged') throw new Error('an unrotated credential was counted as renewed: ' + r.outcome);

r = await only({}, rotating, 's');
if (r.outcome !== 'absent') throw new Error('an absent slot was not reported absent: ' + r.outcome);

r = await only({ s: { type: 'api_key', key: 'k' } }, rotating, 's');
if (r.outcome !== 'not-oauth') throw new Error('a non-oauth credential was not reported: ' + r.outcome);

// An Anthropic Pi credential carries no accountId. Handing it to the Codex
// flow would POST its refresh token to the wrong provider's token endpoint.
r = await only({ s: { type: 'oauth', access: 'a', refresh: 'r', expires: 1 } }, rotating, 's');
if (r.outcome !== 'unsupported-provider') throw new Error('a non-Codex credential reached the Codex flow: ' + r.outcome);

r = await only({ s: codex('one') }, never, 's');
if (r.outcome !== 'failed') throw new Error('a throwing refresh was not reported failed: ' + r.outcome);

r = await only({ s: codex('one') }, drifting, 's');
if (r.account_stable !== false) throw new Error('an account change was not reported');

// A provider error carrying token-shaped text must come back redacted, and the
// redaction must be applied before the truncation or a short run survives.
const leaky = { refresh: async () => { throw new Error('missing fields: {\"access_token\":\"$MARKER-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}'); } };
r = await only({ s: codex('one') }, leaky, 's');
if (r.detail.includes('$MARKER')) throw new Error('a provider error leaked token material');
if (!r.detail.includes('[redacted]')) throw new Error('a token-shaped run was not redacted');

// The provider rotated and the store could not keep it. That is not an
// ordinary failure: the host now holds a token the provider has retired, and
// no pre-renewal copy helps, so it must be reported as its own outcome.
const refusingStore = {
  async read(slot) { return codex('one'); },
  async modify(slot, fn) { await fn(codex('one')); throw new Error('EACCES: permission denied'); },
};
r = (await adapter.refreshSlots({
  storeFactory: () => refusingStore, oauth: rotating, poolPath: 'x', slots: ['s'], timeoutMs: 1000,
}))[0];
if (r.outcome !== 'rotated-unpersisted') throw new Error('a lost rotation was reported as an ordinary failure: ' + r.outcome);

// A store that refuses BEFORE the provider is reached is an ordinary failure.
const deadStore = { async read() { return codex('one'); }, async modify() { throw new Error('ELOCKED'); } };
r = (await adapter.refreshSlots({
  storeFactory: () => deadStore, oauth: rotating, poolPath: 'x', slots: ['s'], timeoutMs: 1000,
}))[0];
if (r.outcome !== 'failed') throw new Error('a failure before the provider was miscalled a lost rotation: ' + r.outcome);

const all = JSON.stringify(await run({ s: codex('one') }, rotating, ['s']));
if (all.includes('a.one') || all.includes('r.one') || all.includes('\"one\"')) {
  throw new Error('the adapter emitted raw credential or account material');
}
" || fail "the adapter reported the wrong outcome for a case it must distinguish"

  pass "the adapter distinguishes refreshed, unchanged, absent, not-oauth, unsupported-provider, failed and a rotation it could not store, and redacts before it truncates"
}

# The integration the unit above deliberately does not cover: Pi's own
# credential store, its lock, and what actually lands on disk.
adapter_store_contract() {
  local work pool package
  work=$(fm_test_tmproot fm-pi-refresh-adapter)
  pool=$work/auth.json
  make_pool "$pool"

  package=${FM_PI_PACKAGE_DIR:-}
  if [ -z "$package" ]; then
    local located
    located=$(command -v pi 2>/dev/null || true)
    if [ -n "$located" ]; then
      package=$(cd "$(dirname "$(readlink -f "$located")")/.." && pwd -P)
    fi
  fi
  if [ -z "$package" ] || [ ! -f "$package/dist/core/auth-storage.js" ]; then
    # FM_PI_REQUIRED is set wherever Pi is supposed to be installed, so an
    # install that silently failed goes red instead of skipping. A skip that
    # can never fail is how this contract came to be absent from CI.
    [ "${FM_PI_REQUIRED:-0}" != 1 ] \
      || fail "FM_PI_REQUIRED is set but no Pi credential store was found to contract against"
    echo "skip: pi is not installed for the adapter store contract"
    return 0
  fi
  command -v node >/dev/null 2>&1 || fail "node is required to run the renewal adapter"

  node --input-type=module -e "
import { readFileSync } from 'node:fs';
const adapter = await import('file://$ADAPTER');
const { AuthStorage } = await import('file://$package/dist/core/auth-storage.js');

const rotating = {
  refresh: async (current) => ({
    type: 'oauth', access: 'rotated.' + current.accountId,
    refresh: 'rotated-refresh.' + current.accountId,
    expires: Date.now() + 864e5, accountId: current.accountId,
  }),
};
const records = await adapter.refreshSlots({
  storeFactory: (path) => AuthStorage.create(path),
  oauth: rotating, poolPath: '$pool', slots: ['openai-codex', 'no-such-slot'], timeoutMs: 5000,
});
const rotated = records.find((record) => record.slot === 'openai-codex');
if (rotated.outcome !== 'refreshed') throw new Error('Pi store did not persist a rotation: ' + rotated.outcome);
if (records.find((record) => record.slot === 'no-such-slot').outcome !== 'absent') {
  throw new Error('an absent slot was not reported absent through the real store');
}
if (JSON.stringify(records).includes('$MARKER')) throw new Error('the adapter emitted token material');

const onDisk = JSON.parse(readFileSync('$pool', 'utf8'));
if (onDisk['openai-codex'].access !== 'rotated.acct-one') throw new Error('the rotation did not land in the pool');
if (Object.keys(onDisk).length !== 3) throw new Error('the pool lost a slot');
if (onDisk['openai-codex-3'].accountId !== 'acct-three') throw new Error('an untouched slot changed');

// Also prove the module paths the production entrypoint resolves are the ones
// this Pi actually ships, so a Pi upgrade that moves them fails here.
const loaded = await adapter.loadPiModules('$package');
if (typeof loaded.oauth.refresh !== 'function') throw new Error('the resolved Pi OAuth flow has no refresh');
" || fail "the adapter contract against Pi's real credential store failed"

  pass "the adapter rotates through Pi's real credential store and lands exactly one slot on disk"
}

selection_contract
refusal_contract
republish_contract
pool_integrity_contract
adapter_outcome_contract
adapter_store_contract
scheduled_azure_pool_contract
scheduler_contract
