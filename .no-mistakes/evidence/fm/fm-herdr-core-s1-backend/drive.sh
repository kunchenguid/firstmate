#!/usr/bin/env bash
set -eu
export FM_HC_BIN="$PWD/.live-hc/bin/herdr-core"
export FM_HC_LAB_DIR="$PWD/.live-hc/labs" FM_HC_LAB_SOCK_DIR=.s
export XDG_STATE_HOME="$PWD/.live-hc/operator-state" XDG_CONFIG_HOME="$PWD/.live-hc/operator-config" XDG_DATA_HOME="$PWD/.live-hc/operator-data"
export FM_HOME="$PWD/.live-hc/home" FM_ROOT_OVERRIDE="$PWD/.live-hc/home"
mkdir -p "$FM_HOME" "$XDG_STATE_HOME/herdr-core"
printf 'untouched synthetic operator state\n' > "$XDG_STATE_HOME/herdr-core/sentinel"
lab=bin/fm-hc-lab.sh
ses=fm-hclab-proof
cleanup() { rc=$?; trap - EXIT; "$lab" teardown "$ses" || rc=1; exit "$rc"; }
"$lab" provision "$ses"
trap cleanup EXIT
export HC_SESSION=$ses FM_HC_SOCKET=$("$lab" socket "$ses")
# Every adapter call can autostart safely only into this lab's XDG roots.
export XDG_STATE_HOME="$FM_HC_LAB_DIR/$ses/env/xdg-state" XDG_CONFIG_HOME="$FM_HC_LAB_DIR/$ses/env/xdg-config" XDG_DATA_HOME="$FM_HC_LAB_DIR/$ses/env/xdg-data"
# Adversarial ambient socket/terminal markers must not redirect calls.
export HC_SOCKET="$PWD/.live-hc/forbidden.sock" HC_TERMINAL_ID=t999 HC_TERMINAL_SOCKET="$PWD/.live-hc/forbidden.sock" HC_SCOPE=foreign
. bin/fm-backend.sh
fm_backend_source hc
printf 'Verified session: '; fm_backend_hc_container_ensure; echo
fm_backend_required_tool_available hc hc
printf 'Dependency check accepts FM_HC_BIN-only installation\n'
a=$(fm_backend_hc_create_task "$ses" fm-status "$PWD/.live-hc")
t="$ses:$a"
fm_backend_hc_send_text_line "$t" "exec $(command -v python3) -u $PWD/.live-hc/reporter.py idle" fm-status
wait_status() {
 for i in $(seq 1 60); do
  state=$(fm_backend_hc_get "$t" | jq -r '.status.state // ""')
  [ "$state" != "$1" ] || return 0
  sleep .2
 done
 return 1
}
wait_status idle
printf 'Real Core record before submit: '; fm_backend_hc_get "$t" | jq -c '{address,state,status,labels,foreground}'
v=$(fm_backend_hc_send_text_submit "$t" 'native-submit-proof' 1 .4 0 fm-status)
printf 'Native submit verdict: %s\n' "$v"
[ "$v" = empty ]
printf 'Busy-state immediately after native submit: '; fm_backend_hc_busy_state "$t"; echo
wait_status done
printf 'Settled native status: '; fm_backend_hc_get "$t" | jq -c '{state,status,turn}'
[ "$(fm_backend_hc_busy_state "$t")" = idle ]
printf 'Captured terminal output:\n'; fm_backend_hc_capture "$t" 25 fm-status
# Ownership checks must prevent both input and destructive close.
if fm_backend_hc_send_text_line "$t" 'UNAUTHORIZED' fm-wrong; then exit 1; fi
if fm_backend_hc_kill "$t" '' fm-wrong; then exit 1; fi
fm_backend_target_exists hc "$t" fm-status
printf 'Mismatched task input/close refused; owned endpoint remains present\n'
fm_backend_hc_kill "$t" '' fm-status
[ "$(fm_backend_hc_agent_state "$t")" = missing ]
a=$(fm_backend_hc_create_task "$ses" fm-blocked "$PWD/.live-hc")
t="$ses:$a"
fm_backend_hc_send_text_line "$t" "exec $(command -v python3) -u $PWD/.live-hc/reporter.py blocked" fm-blocked
wait_status blocked
printf 'Blocked Core record: '; fm_backend_hc_get "$t" | jq -c '{state,status}'
v=$(fm_backend_hc_send_text_submit "$t" 'MUST-NOT-DELIVER' 2 .4 0 fm-blocked)
printf 'Blocked submit verdict: %s\n' "$v"
[ "$v" = unknown ]
cap=$(fm_backend_hc_capture "$t" 50 fm-blocked)
printf 'Blocked terminal output:\n%s\n' "$cap"
if printf '%s' "$cap" | grep -q 'MUST-NOT-DELIVER'; then exit 1; fi
[ "$(fm_backend_hc_get "$t" | jq -r .status.state)" = blocked ]
printf 'Blocked send delivered zero payload and kept native blocked status\n'
fm_backend_hc_kill "$t" '' fm-blocked
# Real installed harness, no prompt and no model request.
export DISABLE_AUTOUPDATER=1
a=$(fm_backend_hc_create_task "$ses" fm-claude "$PWD/.live-hc")
t="$ses:$a"
fm_backend_hc_send_text_line "$t" "DISABLE_AUTOUPDATER=1 $(command -v claude)" fm-claude
for i in $(seq 1 100); do
 state=$(fm_backend_hc_agent_state "$t")
 [ "$state" != alive ] || break
 sleep .2
done
printf 'Real Claude liveness: %s\n' "$state"
fm_backend_hc_get "$t" | jq -c '{state,status,foreground}'
[ "$state" = alive ]
fm_backend_hc_kill "$t" '' fm-claude
printf 'All owned terminals closed; lab teardown follows\n'
