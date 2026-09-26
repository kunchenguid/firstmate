#!/usr/bin/env bash
# Focused executable regression for a quiet entry on an opted-in home whose
# malformed mirror forces the daemon fallback.
set -eu
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAUNCH="$ROOT/bin/fm-afk-launch.sh"
MIRROR="$ROOT/bin/fm-host-mirror.sh"
st=$(mktemp -d "$ROOT/.quiet-fallback-test.XXXXXX")
trap 'rm -rf "$st"' EXIT
mkdir -p "$st/state" "$st/config"
printf 'claude\n' > "$st/config/supervision-host"
printf '%s\n' "$$" > "$st/state/.lock"
printf '%s\n' '{"seq":"invalid","tag":"captain"}' > "$st/state/.host-mirror.jsonl"
printf '#!/usr/bin/env bash\nexit 0\n' > "$st/engine"
chmod +x "$st/engine"
export FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" FM_TEST_SEAM=1 FM_TEST_HARNESS=claude
export FM_SUPERVISION_ENGINE_CLAUDE_BIN="$st/engine"
check_status() {
  local expected=$1 actual
  shift
  actual=0
  "$@" > "$st/output" 2>&1 || actual=$?
  if [ "$actual" -ne "$expected" ]; then
    printf 'expected exit %s, got %s from %s:\n' "$expected" "$actual" "$*" >&2
    cat "$st/output" >&2
    exit 1
  fi
}
check_status 1 "$MIRROR" check
check_status 1 "$LAUNCH" quiet-check
grep -F 'dialog mirror is missing or could not be read' "$st/output" >/dev/null
check_status 0 env FM_AFK_MODE=quiet "$LAUNCH" enter --words 'stay quiet'
[ "$(FM_HOME="$st" "$ROOT/bin/fm-afk-contract.sh" field mode)" = quiet ]
# start reaches backend selection without falsely refusing an away daemon;
# this deliberately unsupported backend avoids launching a real terminal.
check_status 1 env FM_SUPERVISOR_TARGET=unused FM_SUPERVISOR_BACKEND=unsupported "$LAUNCH" start
grep -F "no non-visible daemon-launch primitive for backend 'unsupported'" "$st/output" >/dev/null
! grep -F 'away-posture record is the posture here' "$st/output" >/dev/null
check_status 0 "$LAUNCH" start-native
[ "$(head -n 1 "$st/state/.afk")" = quiet ]
[ "$(cut -f1 "$st/state/.afk-daemon-terminal")" = none ]
# Explicit mode wins even over the existing quiet daemon flag.
check_status 1 env FM_AFK_MODE=away "$LAUNCH" start-native
grep -F 'the away-posture record is the posture here' "$st/output" >/dev/null
check_status 1 env FM_AFK_MODE=away "$LAUNCH" start
grep -F 'the away-posture record is the posture here' "$st/output" >/dev/null
check_status 0 "$LAUNCH" start-native
check_status 2 "$LAUNCH" quiet-check
grep -F 'away record (state/.afk-contract) is live' "$st/output" >/dev/null
check_status 0 "$LAUNCH" stop
[ ! -e "$st/state/.afk-contract" ]
# A stale flag must not override the mode a subsequent quiet enter recorded.
check_status 0 env FM_AFK_MODE=quiet "$LAUNCH" enter --words 'stay quiet again'
printf 'away\n' > "$st/state/.afk"
check_status 0 "$LAUNCH" start-native
[ "$(head -n 1 "$st/state/.afk")" = quiet ]
check_status 0 "$LAUNCH" stop
# Where the attended host is ready, quiet remains a statement, not an entry.
printf '%s\n' '{"seq":1,"key":"k","tag":"captain","text":"hello"}' > "$st/state/.host-mirror.jsonl"
check_status 0 "$LAUNCH" quiet-check
check_status 3 env FM_AFK_MODE=quiet "$LAUNCH" enter --words 'stay quiet'
[ ! -e "$st/state/.afk-contract" ]
printf 'ok - quiet fallback and attended statement\n'
