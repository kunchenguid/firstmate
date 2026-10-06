#!/usr/bin/env bash
# Behavior tests for bin/fm-mem-protection-install.sh.
#
# The installer owns the reproducible host policy, so these pin the generated
# artifacts (earlyoom args, the one-minute timer unit, the heavy-suite posture)
# through its `print` interface and exercise the config-only subcommands against
# a temporary home. `install` with a valid home touches the real host and are
# not run here.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INSTALLER="$ROOT/bin/fm-mem-protection-install.sh"

test_print_policy_semantics() {
  local root home
  root=$(fm_test_tmproot fm-mem-protection-install)
  home="$root/home"
  mkdir -p "$home/bin"
  printf '#!/bin/sh\nprintf "%%s" "$1" > "$FM_HOME/called"\n' > "$home/bin/fm-mem-alert.sh"
  chmod +x "$home/bin/fm-mem-alert.sh"
  "$INSTALLER" print --home "$home" > "$root/policy" || fail "print failed"
  python3 - "$root/policy" "$home" <<'PYMODEL' || fail "generated policy semantics failed"
import os
import re
import shlex
import subprocess
import sys
from pathlib import Path

files = {}
current = None
for line in Path(sys.argv[1]).read_text().splitlines():
    if line.startswith('=== ') and line.endswith(' ==='):
        current = line[4:-4]
        files[current] = []
    elif current is not None:
        files[current].append(line)

def unit(suffix):
    name, lines = next((k, v) for k, v in files.items() if k.endswith(suffix))
    model = {}
    section = None
    for line in lines:
        line = line.strip()
        if not line or line.startswith(('#', ';')):
            continue
        if line.startswith('[') and line.endswith(']'):
            section = line[1:-1]
        else:
            key, value = line.split('=', 1)
            model.setdefault((section, key), []).append(value)
    return name, model

assignments = {}
for line in files['/etc/default/earlyoom']:
    if not line.strip() or line.lstrip().startswith('#'):
        continue
    key, value = line.split('=', 1)
    assignments[key] = shlex.split(value)[0]
args = shlex.split(assignments['EARLYOOM_ARGS'])
options = dict(zip(args[::2], args[1::2]))
assert len(args) == 2 * len(options)
assert options['-m'] == '5'
assert options['-s'] == '100'
assert options['-r'] == '60'
assert '--avoid' not in options
for name in ('node', 'MainThread', 'pytest', 'vitest', 'acceptance'):
    assert re.search(options['--prefer'], name), name
for name in ('omp', 'sshd', 'dockerd', 'containerd', 'herdr', 'clickhouse-serv',
             'systemd', 'systemd-journal', 'dbus-daemon', 'Xorg', 'gnome-shell', 'tmux', 'earlyoom'):
    assert re.search(options['--ignore'], name), name

service_name, service = unit('/fm-mem-alert.service')
timer_name, timer = unit('/fm-mem-alert.timer')
def seconds(value):
    match = re.fullmatch(r'(\d+)(s|min)', value)
    assert match, value
    return int(match[1]) * {'s': 1, 'min': 60}[match[2]]
assert seconds(timer['Timer', 'OnUnitActiveSec'][0]) == 60
assert seconds(timer['Timer', 'OnBootSec'][0]) == 120
assert timer['Timer', 'Unit'] == [Path(service_name).name]
assert timer['Install', 'WantedBy'] == ['timers.target']
assert service['Service', 'Type'] == ['oneshot']
env = os.environ.copy()
for value in service['Service', 'Environment']:
    for assignment in shlex.split(value):
        key, val = assignment.split('=', 1)
        env[key] = val
assert env['FM_HOME'] == sys.argv[2]
starts = service['Service', 'ExecStart']
assert len(starts) == 1
subprocess.run(shlex.split(starts[0]), env=env, check=True)
assert Path(sys.argv[2], 'called').read_text() == 'check'
Path(sys.argv[2], 'bin/fm-mem-alert.sh').unlink()
assert subprocess.run(shlex.split(starts[0]), env=env, stderr=subprocess.DEVNULL).returncode != 0
PYMODEL
  pass "generated defaults and units enforce the required policy"
}

test_install_refuses_a_missing_alert_executable() {
  local root home rc out
  root=$(fm_test_tmproot fm-mem-protection-install)
  home="$root/home"
  mkdir -p "$home"
  rc=0
  out=$(XDG_CONFIG_HOME="$root/units" "$INSTALLER" install --home "$home" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "installation accepted a home without an alert executable"
  case "$out" in *"alert executable missing"*) ;; *) fail "missing alert not named: $out" ;; esac
  [ ! -e "$root/units" ] || fail "units written before checking alert executable"
  pass "installation refuses before host changes when the alert executable is absent"
}

test_config_install_is_idempotent() {
  local root home out
  root=$(fm_test_tmproot fm-mem-protection-install)
  home="$root/home"
  mkdir -p "$home"
  "$INSTALLER" install-config --home "$home" --runner /campaign/runner \
    || fail "install-config exited non-zero"
  [ "$(cat "$home/config/heavy-suites")" = remote-only ] || fail "heavy-suites not written"
  [ "$(cat "$home/config/campaign-runner")" = /campaign/runner ] || fail "campaign-runner not written"
  out=$("$INSTALLER" status --home "$home") || fail "status exited non-zero"
  case "$out" in *"config/heavy-suites: remote-only"*) ;; *) fail "status did not report the posture: $out" ;; esac
  "$INSTALLER" install-config --home "$home" --runner /campaign/runner || fail "repeated installation failed"
  [ "$(cat "$home/config/heavy-suites")" = remote-only ] || fail "posture changed"
  [ "$(cat "$home/config/campaign-runner")" = /campaign/runner ] || fail "runner changed"
  pass "config installation writes the posture idempotently"
}

test_config_write_refuses_a_captain_edit() {
  local root home rc
  root=$(fm_test_tmproot fm-mem-protection-install)
  home="$root/home"
  mkdir -p "$home/config"
  printf 'keep-me\n' > "$home/config/heavy-suites"
  rc=0
  "$INSTALLER" install-config --home "$home" --runner /campaign/runner >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "a differing existing value must not be replaced"
  [ "$(cat "$home/config/heavy-suites")" = keep-me ] || fail "the existing value was overwritten"
  pass "install-config never replaces a value it did not write"
}

test_status_runs_on_a_bare_home() {
  local root home out
  root=$(fm_test_tmproot fm-mem-protection-install)
  home="$root/home"
  mkdir -p "$home"
  out=$("$INSTALLER" status --home "$home") || fail "status exited non-zero"
  case "$out" in *"config/heavy-suites: absent"*) ;; *) fail "status did not report an absent posture: $out" ;; esac
  case "$out" in *"earlyoom"*) ;; *) fail "status did not report earlyoom: $out" ;; esac
  pass "status reports every part on a bare home"
}

test_config_write_failures_stop_installation() {
  local root home mode rc out
  root=$(fm_test_tmproot fm-mem-protection-install)
  for mode in directory heavy-suites campaign-runner; do
    home="$root/$mode"
    mkdir -p "$home"
    if [ "$mode" = directory ]; then
      printf 'blocked\n' > "$home/config"
    else
      mkdir -p "$home/config/$mode"
    fi
    rc=0
    out=$("$INSTALLER" install-config --home "$home" 2>&1) || rc=$?
    [ "$rc" -ne 0 ] || fail "$mode write failure returned success"
    case "$out" in *"could not"*) ;; *) fail "write failure not diagnosed: $out" ;; esac
    case "$out" in *"install: heavy suites refused"*) fail "failed install reported success" ;; esac
    if [ "$mode" != campaign-runner ]; then
      [ ! -e "$home/config/campaign-runner" ] || fail "continued after posture write failure"
    fi
  done
  pass "configuration directory and both policy writes fail closed"
}

test_generated_file_failures_prevent_activation() {
  local root home fakebin mode rc out units
  root=$(fm_test_tmproot fm-mem-protection-install)
  home="$root/home"
  mkdir -p "$home/bin"
  printf '#!/bin/sh\nexit 0\n' > "$home/bin/fm-mem-alert.sh"
  chmod +x "$home/bin/fm-mem-alert.sh"
  fakebin=$(fm_fakebin "$root")
  fm_fake_exit0 "$fakebin" earlyoom
  cat > "$fakebin/sudo" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$INSTALL_LOG"
SH
  cat > "$fakebin/systemctl" <<'SH'
#!/bin/sh
case "$*" in is-enabled*|is-active*) exit 1 ;; esac
printf '%s\n' "$*" >> "$INSTALL_LOG"
SH
  chmod +x "$fakebin/sudo" "$fakebin/systemctl"
  for mode in defaults service timer; do
    units="$root/$mode/systemd/user"
    mkdir -p "$units"
    if [ "$mode" = defaults ]; then
      printf 'blocked\n' > "$root/blocked"
      cat > "$fakebin/mktemp" <<'SH'
#!/bin/sh
printf '%s\n' "$BLOCKED_DEFAULTS"
SH
      chmod +x "$fakebin/mktemp"
    else
      rm -f "$fakebin/mktemp"
      mkdir "$units/fm-mem-alert.$mode"
    fi
    : > "$root/install.log"
    rc=0
    out=$(PATH="$fakebin:$PATH" INSTALL_LOG="$root/install.log" \
      BLOCKED_DEFAULTS="$root/blocked/defaults" XDG_CONFIG_HOME="$root/$mode" \
      "$INSTALLER" install --home "$home" 2>&1) || rc=$?
    [ "$rc" -ne 0 ] || fail "$mode generation failure returned success"
    case "$out" in *"could not write"*) ;; *) fail "generation failure not diagnosed: $out" ;; esac
    case "$(cat "$root/install.log")" in *"--user daemon-reload"*|*"--user enable"*) fail "activated failed units" ;; esac
    if [ "$mode" = defaults ]; then
      case "$(cat "$root/install.log")" in *"install -m"*|*"systemctl enable"*|*"systemctl restart"*) fail "activated failed defaults" ;; esac
    fi
    [ ! -e "$home/config/heavy-suites" ] || fail "continued after generated file failure"
  done
  pass "failed defaults or either unit cannot reach dependent activation"
}

test_print_policy_semantics
test_install_refuses_a_missing_alert_executable
test_config_install_is_idempotent
test_config_write_refuses_a_captain_edit
test_status_runs_on_a_bare_home

test_config_write_failures_stop_installation
test_generated_file_failures_prevent_activation
