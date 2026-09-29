#!/usr/bin/env bash
# tests/fm-remote-session-config.test.sh - the remote Herdr session name is a
# deployment choice, not a constant, and the shared default session is
# host-owned.
#
# Drives the real bin/fm-remote-doctor.sh against minimal darwin fixtures (a
# private HOME, a stub launchctl) and asserts through the stable line
# protocol: FM_REMOTE_HERDR_SESSION unset skips Firstmate agent management for
# the shared default session and never derives a default label, an explicit
# value manages its derived label, and a leftover dev.firstmate.herdr.fm-remote
# agent is retired by --fix only once its session is provably idle (left alone
# while it may serve live mates, or when its state cannot be proven).
# Nothing here touches the runner's own launch agents or Herdr server.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-remote-session-config)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
trap 'fm_test_cleanup || true' EXIT

UID_NUM=$(id -u 2>/dev/null)
REAL_JQ=$(command -v jq)

make_world() { # <name> [with-herdr] -> sets WORLD_HOME/WORLD_BIN/WORLD_OUT
  local name=$1 with_herdr=${2:-without-herdr}
  local home=$TMP_ROOT/$name-home bin=$TMP_ROOT/$name-bin
  mkdir -p "$home/Library/LaunchAgents" "$home/.local/bin" "$bin"
  cat > "$bin/launchctl" <<EOF
#!/usr/bin/env bash
set -u
domain=\${2:-}
case "\${1:-}" in
  print)
    case "\$domain" in
      gui/$UID_NUM) exit 0 ;;
      *) exit 113 ;;
    esac
    ;;
  bootout) exit 0 ;;
  bootstrap) printf 'Bootstrap failed: 5: Input/output error\n' >&2; exit 5 ;;
  kickstart) printf 'Kickstart failed\n' >&2; exit 5 ;;
esac
exit 0
EOF
  chmod +x "$bin/launchctl"
  if [ "$with_herdr" = with-herdr ]; then
    ln -sf "$REAL_JQ" "$bin/jq"
    cat > "$bin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
session=
prev=
for a in "$@"; do
  if [ "$prev" = --session ]; then session=$a; fi
  prev=$a
done
running=false
case "$session" in
  default) running=true ;;
  fm-remote) running=${FM_FAKE_LEGACY_RUNNING:-false} ;;
esac
case "${1:-} ${2:-}" in
  "status --json")
    printf '{"client":{"version":"0.9.1","protocol":16},"server":{"running":%s,"socket":""}}\n' "$running"
    ;;
esac
exit 0
SH
    chmod +x "$bin/herdr"
  fi
  WORLD_HOME=$home
  WORLD_BIN=$bin
  WORLD_OUT=$TMP_ROOT/$name.out
}

run_doctor() { # <home> <bin> <out> [args...]; DOCTOR_SESSION unset = env unset
  local home=$1 bin=$2 out=$3
  shift 3
  set +e
  if [ "${DOCTOR_SESSION-unset}" = unset ]; then
    env -u FM_REMOTE_HERDR_SESSION \
      HOME="$home" FM_HOME="$TMP_ROOT/project-home" \
      PATH="$home/.local/bin:$bin:/usr/bin:/bin" \
      FM_FAKE_LEGACY_RUNNING="${DOCTOR_LEGACY_RUNNING-false}" \
      FM_REMOTE_JOB_PLATFORM_OVERRIDE=darwin SHELL=/bin/sh \
      "$ROOT/bin/fm-remote-doctor.sh" "$@" > "$out" 2>&1
  else
    FM_REMOTE_HERDR_SESSION="$DOCTOR_SESSION" \
      HOME="$home" FM_HOME="$TMP_ROOT/project-home" \
      PATH="$home/.local/bin:$bin:/usr/bin:/bin" \
      FM_FAKE_LEGACY_RUNNING="${DOCTOR_LEGACY_RUNNING-false}" \
      FM_REMOTE_JOB_PLATFORM_OVERRIDE=darwin SHELL=/bin/sh \
      "$ROOT/bin/fm-remote-doctor.sh" "$@" > "$out" 2>&1
  fi
  set -e
}

mkdir -p "$TMP_ROOT/project-home"

make_world default
unset DOCTOR_SESSION
run_doctor "$WORLD_HOME" "$WORLD_BIN" "$WORLD_OUT"
assert_grep "check launchagent=skip: the shared 'default' server is owned by the host, not a Firstmate launch agent" "$WORLD_OUT" "the unset default did not skip agent management with the deployed wording"
assert_grep "check launchagent-legacy=ok: no legacy dev.firstmate.herdr.fm-remote agent remains" "$WORLD_OUT" "a clean default home wrongly reported a legacy agent"
assert_no_grep "dev.firstmate.herdr.default" "$WORLD_OUT" "the shared default session wrongly derived a Firstmate label"
pass "unset FM_REMOTE_HERDR_SESSION leaves the shared default session host-owned"

make_world custom
DOCTOR_SESSION=custom run_doctor "$WORLD_HOME" "$WORLD_BIN" "$WORLD_OUT"
assert_grep "check launchagent=fixable: no Firstmate herdr launch agent at $WORLD_HOME/Library/LaunchAgents/dev.firstmate.herdr.custom.plist" "$WORLD_OUT" "FM_REMOTE_HERDR_SESSION=custom did not derive label dev.firstmate.herdr.custom"
pass "FM_REMOTE_HERDR_SESSION=custom manages its derived label"

make_world legacy-idle with-herdr
printf '%s\n' "stale legacy plist" > "$WORLD_HOME/Library/LaunchAgents/dev.firstmate.herdr.fm-remote.plist"
unset DOCTOR_SESSION
DOCTOR_LEGACY_RUNNING=false run_doctor "$WORLD_HOME" "$WORLD_BIN" "$WORLD_OUT"
assert_grep "check launchagent-legacy=fixable: legacy launch agent dev.firstmate.herdr.fm-remote remains and its fm-remote session is not running" "$WORLD_OUT" "check mode did not flag the idle leftover fm-remote agent"
DOCTOR_LEGACY_RUNNING=false run_doctor "$WORLD_HOME" "$WORLD_BIN" "$WORLD_OUT" --fix
assert_grep "fix launchagent-legacy=applied:" "$WORLD_OUT" "--fix did not report retiring the idle leftover fm-remote agent"
assert_absent "$WORLD_HOME/Library/LaunchAgents/dev.firstmate.herdr.fm-remote.plist" "--fix left the idle legacy fm-remote plist behind"
DOCTOR_LEGACY_RUNNING=false run_doctor "$WORLD_HOME" "$WORLD_BIN" "$WORLD_OUT"
assert_grep "check launchagent-legacy=ok: no legacy dev.firstmate.herdr.fm-remote agent remains" "$WORLD_OUT" "the retired legacy agent still reports after --fix"
pass "the idle leftover fm-remote agent is retired by --fix"

make_world legacy-live with-herdr
printf '%s\n' "serving legacy plist" > "$WORLD_HOME/Library/LaunchAgents/dev.firstmate.herdr.fm-remote.plist"
unset DOCTOR_SESSION
DOCTOR_LEGACY_RUNNING=true run_doctor "$WORLD_HOME" "$WORLD_BIN" "$WORLD_OUT"
assert_grep "check launchagent-legacy=skip: legacy launch agent dev.firstmate.herdr.fm-remote left alone while its fm-remote session is running" "$WORLD_OUT" "check mode did not defer to the live fm-remote session"
DOCTOR_LEGACY_RUNNING=true run_doctor "$WORLD_HOME" "$WORLD_BIN" "$WORLD_OUT" --fix
assert_present "$WORLD_HOME/Library/LaunchAgents/dev.firstmate.herdr.fm-remote.plist" "--fix retired a legacy agent that still serves a live session"
pass "the serving leftover fm-remote agent is left alone"

make_world legacy-unprovable
printf '%s\n' "unprovable legacy plist" > "$WORLD_HOME/Library/LaunchAgents/dev.firstmate.herdr.fm-remote.plist"
unset DOCTOR_SESSION
run_doctor "$WORLD_HOME" "$WORLD_BIN" "$WORLD_OUT"
assert_grep "check launchagent-legacy=skip: legacy launch agent dev.firstmate.herdr.fm-remote left alone because its fm-remote session state cannot be proven without herdr" "$WORLD_OUT" "check mode guessed at an unprovable legacy session"
pass "the unprovable leftover fm-remote agent is left alone"
