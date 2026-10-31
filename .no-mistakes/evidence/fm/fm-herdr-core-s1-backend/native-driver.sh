#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
export FM_HC_BIN="$ROOT/.live-hc/bin/herdr-core"
export FM_HC_LAB_DIR="$ROOT/.live-hc/labs" FM_HC_LAB_SOCK_DIR=.s
LAB="$ROOT/bin/fm-hc-lab.sh"
SESSION=fm-hclab-native
cleanup() {
  rc=$?
  trap - EXIT
  "$LAB" teardown "$SESSION" || rc=1
  echo "native lab teardown exit=$rc"
  exit "$rc"
}
trap cleanup EXIT
"$LAB" provision "$SESSION"
D="$FM_HC_LAB_DIR/$SESSION"
export XDG_STATE_HOME="$D/env/xdg-state" XDG_CONFIG_HOME="$D/env/xdg-config" XDG_DATA_HOME="$D/env/xdg-data"
export FM_HOME="$ROOT/.live-hc/home" FM_ROOT_OVERRIDE="$ROOT/.live-hc/home"
mkdir -p "$FM_HOME"
export HC_SESSION="$SESSION" FM_HC_SOCKET="$("$LAB" socket "$SESSION")"
. "$ROOT/bin/fm-backend.sh"
fm_backend_source hc
# Gate uses real binaries, no CLI doubles.
echo "resolved=$(fm_backend_hc_bin) version=$($FM_HC_BIN --version) dependency_available=$(fm_backend_required_tool_available hc hc && echo yes)"
[ "$(fm_backend_hc_container_ensure)" = "$SESSION" ]
echo "generation=$(fm_backend_hc_hello "$SESSION")"
VALID=$FM_HC_BIN
export FM_HC_BIN="$(command -v herdr)"
if fm_backend_hc_version_check; then echo 'ERROR accepted unrelated herdr binary'; exit 1; fi
export FM_HC_BIN=$VALID
echo 'unrelated Herdr TUI binary rejected before core lifecycle'
ADDR=$(fm_backend_hc_create_task "$SESSION" fm-native "$ROOT/.live-hc")
T="$SESSION:$ADDR"
"$LAB" run "$SESSION" get --json "$ADDR"
if fm_backend_hc_create_task "$SESSION" fm-native "$ROOT/.live-hc"; then echo 'ERROR duplicate accepted'; exit 1; fi
for op in send capture close; do
  case "$op" in
    send) if fm_backend_hc_send_text_line "$T" 'echo FOREIGN-INPUT' fm-wrong; then exit 1; fi ;;
    capture) if fm_backend_hc_capture "$T" 20 fm-wrong; then exit 1; fi ;;
    close) if fm_backend_hc_kill "$T" '' fm-wrong; then exit 1; fi ;;
  esac
  echo "foreign-label $op refused"
done
[ "$(fm_backend_hc_endpoint_state "$T" fm-native)" = ready ]
# Python is a synthetic application, not a substitute for Core or the adapter.
fm_backend_hc_send_text_line "$T" "exec $(command -v python3) '$ROOT/.live-hc/status-program.py' '$ROOT/.live-hc/received.txt'" fm-native
poll_state() {
  local want=$1 got
  for ((i=0;i<100;i++)); do
    got=$(fm_backend_hc_get "$T" | jq -r '.status.state // ""')
    [ "$got" != "$want" ] || return 0
    sleep .1
  done
  echo "ERROR wanted $want got $got"; return 1
}
poll_state idle
[ "$(fm_backend_hc_busy_state "$T")" = idle ]
verdict=$(fm_backend_hc_send_text_submit "$T" '-literal --force' 1 .4 0 fm-native)
echo "native submit verdict=$verdict"
[ "$verdict" = empty ]
[ "$(fm_backend_hc_busy_state "$T")" = busy ]
"$LAB" run "$SESSION" get --json "$ADDR"
poll_state idle
[ "$(fm_backend_hc_busy_state "$T")" = idle ]
grep -qx -- '-literal --force' "$ROOT/.live-hc/received.txt"
fm_backend_hc_send_text_line "$T" block fm-native
poll_state blocked
before=$(shasum -a 256 "$ROOT/.live-hc/received.txt")
verdict=$(fm_backend_hc_send_text_submit "$T" 'MUST-NOT-REACH-APP' 5 .2 0 fm-native)
echo "blocked submit verdict=$verdict"
[ "$verdict" = unknown ]
sleep .5
[ "$before" = "$(shasum -a 256 "$ROOT/.live-hc/received.txt")" ]
echo 'input receipt file unchanged after blocked send; received only:'
python3 -c 'import sys; print(open(sys.argv[1]).read())' "$ROOT/.live-hc/received.txt"
fm_backend_hc_capture "$T" 30 fm-native
fm_backend_kill hc "$T" '' fm-native
[ "$(fm_backend_hc_agent_state "$T")" = missing ]
echo 'native status terminal removed; liveness=missing'
echo 'ALL NATIVE AND IDENTITY CHECKS PASSED'
