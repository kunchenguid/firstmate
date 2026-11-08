#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
EVIDENCE=~/.no-mistakes/evidence/01M6DN8XWZK886JNCEVABDTY9C
WORK="$ROOT/.live-validation"
export FM_HERDR_LAB_STATE_DIR="$WORK/lab-state"
LAB=$(bin/fm-herdr-lab.sh name readiness)
export LIVE_LAB="$LAB" LIVE_ROOT="$ROOT" LIVE_ACCOUNT_HOME="$HOME" LIVE_REAL_PATH="$PATH"
cleanup() { bin/fm-herdr-lab.sh teardown "$LAB"; }
# Provision calls prepare itself for a new named session.
trap cleanup EXIT
bin/fm-herdr-lab.sh provision "$LAB"
printf 'Lab session: %s\n' "$LAB"
mkdir -p "$WORK/bin" "$WORK/account" "$WORK/home"
: > "$WORK/transport.log"
cat > "$WORK/bin/herdr" <<'SH'
#!/usr/bin/env bash
# Safety transport only: all responses come from the real Herdr via the lab helper.
set -eu
args=()
while [ "$#" -gt 0 ]; do
  if [ "$1" = --session ]; then
    case "$2" in fm-remote|"$LIVE_LAB") ;; *) echo 'refused foreign session' >&2; exit 97 ;; esac
    shift 2
  else args+=("$1"); shift; fi
done
printf 'real Herdr transport: %s\n' "${args[*]}" >> "$LIVE_ROOT/.live-validation/transport.log"
HOME="$LIVE_ACCOUNT_HOME" PATH="$LIVE_REAL_PATH" exec "$LIVE_ROOT/bin/fm-herdr-lab.sh" run "$LIVE_LAB" "${args[@]}"
SH
chmod +x "$WORK/bin/herdr"
# Both lab commands and doctor use real status and pane responses. The doctor is
# exercised in Linux mode to avoid any account-global macOS launchd operation.
printf '\n== Initial real server status ==\n'
bin/fm-herdr-lab.sh run "$LAB" status --json
printf '\n== Guard over running, empty, non-Aqua lab server ==\n'
HOME="$WORK/account" bin/fm-remote-herdr-guard.sh "$WORK/bin/herdr" "$LAB"
printf '\n== Create a disposable real shell pane ==\n'
bin/fm-herdr-lab.sh run "$LAB" workspace create --label readiness-proof --cwd "$WORK/home" --no-focus > "$WORK/workspace.json"
cat "$WORK/workspace.json"
bin/fm-herdr-lab.sh run "$LAB" pane list > "$WORK/before.json"
cat "$WORK/before.json"
BEFORE=$(jq -ce '[.result.panes[].pane_id] | sort | select(length > 0 and all(. != null))' "$WORK/before.json")
[ "$BEFORE" != '[]' ]
printf '\n== Guard over lab server with live shell pane ==\n'
HOME="$WORK/account" bin/fm-remote-herdr-guard.sh "$WORK/bin/herdr" "$LAB"
printf '\n== Automatic doctor repair refuses unowned running legacy service (real lab transport; Linux mode) ==\n'
set +e
HOME="$WORK/account" FM_HOME="$WORK/home" FM_ROOT_OVERRIDE="$ROOT" FM_REMOTE_JOB_ACTIVE=1 FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux PATH="$WORK/bin:$PATH" bin/fm-remote-doctor.sh --fix --automatic --backend herdr > "$WORK/doctor.out" 2>&1
RC=$?
set -e
cat "$WORK/doctor.out"
printf 'Doctor exit status: %s\n' "$RC"
[ "$RC" -eq 1 ]
grep -F 'its Firstmate code-root owner cannot be proven; leaving the legacy service untouched' "$WORK/doctor.out"
[ ! -e "$WORK/account/.firstmate/remote-herdr-owner" ]
bin/fm-herdr-lab.sh run "$LAB" pane list > "$WORK/after.json"
printf '\n== Real pane list after both product guards ==\n'
cat "$WORK/after.json"
AFTER=$(jq -ce '[.result.panes[].pane_id] | sort | select(length > 0 and all(. != null))' "$WORK/after.json")
[ "$BEFORE" = "$AFTER" ]
printf '\nSame real shell pane survived: %s\n' "$AFTER"
printf '\n== Actual CLI calls (no server lifecycle allowed by transport) ==\n'
cat "$WORK/transport.log"
printf '\n== Namespace restriction proving full fm-remote integration cannot use required lab helper ==\n'
set +e
bin/fm-herdr-lab.sh prepare fm-remote
REFUSAL=$?
set -e
[ "$REFUSAL" -ne 0 ]
printf '\n== Teardown, including unchanged default-session tripwire ==\n'
cleanup
trap - EXIT
printf 'Cleanup exit status: 0\n'
