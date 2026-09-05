#!/usr/bin/env bash
# Portable regression coverage for Herdr lifecycle recovery after an agent exits.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-herdr-relaunch-recovery)
mkdir -p "$TMP_ROOT/fakebin"
STATE="$TMP_ROOT/herdr.json"
LOG="$TMP_ROOT/herdr.log"
: > "$LOG"

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

cat > "$TMP_ROOT/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
state=${FM_FAKE_HERDR_STATE:?}
log=${FM_FAKE_HERDR_LOG:?}
{
  printf 'call'
  for arg in "$@"; do printf '\x1f%s' "$arg"; done
  printf '\n'
} >> "$log"

save_state() {
  local tmp="$state.tmp.$$"
  cat > "$tmp" && mv "$tmp" "$state"
}

case "${1:-} ${2:-}" in
  "status --json")
    printf '{"client":{"version":"0.8.0","protocol":19},"server":{"running":true}}\n'
    ;;
  "session list")
    socket=${FM_FAKE_HERDR_SOCKET:-$(dirname "$state")/herdr.sock}
    jq -n --arg socket "$socket" '{sessions:[{name:"fmtest",running:true,socket_path:$socket}]}'
    ;;
  "pane get")
    pane=${3:-}
    if [ "$pane" = w1:p2 ]; then
      if [ "$(jq -r '.candidate_exists // false' "$state")" != true ]; then
        printf '{"id":"cli:pane:get","error":{"code":"pane_not_found"}}\n'
      else
        if [ "$(jq -r '.candidate_registered // false' "$state")" = true ] \
           && [ -n "${FM_FAKE_HERDR_POST_LIVE_MARKER:-}" ] \
           && [ ! -e "$FM_FAKE_HERDR_POST_LIVE_MARKER.done" ]; then
          : > "$FM_FAKE_HERDR_POST_LIVE_MARKER"
          while [ ! -e "${FM_FAKE_HERDR_POST_LIVE_RELEASE:?}" ]; do sleep 0.01; done
          : > "$FM_FAKE_HERDR_POST_LIVE_MARKER.done"
        fi
        jq --arg pane "$pane" '{id:"cli:pane:get",result:{type:"pane_info",pane:{pane_id:$pane,tab_id:"w1:t2",workspace_id:"w1",foreground_cwd:.candidate_cwd}}}' "$state"
        jq '
          .candidate_pane_gets=((.candidate_pane_gets // 0) + 1)
          | if .candidate_pane_gets == (.candidate_take_over_after_pane_get // -1)
            then .candidate_process="live" | .candidate_registered=true
            else . end
        ' "$state" | save_state
      fi
    else
      if [ "$(jq -r 'if .recorded_exists == null then true else .recorded_exists end' "$state")" != true ]; then
        printf '{"id":"cli:pane:get","error":{"code":"pane_not_found"}}\n'
      else
        jq --arg pane "$pane" '{id:"cli:pane:get",result:{type:"pane_info",pane:{pane_id:$pane,tab_id:"w1:t1",workspace_id:"w1",foreground_cwd:.cwd}}}' "$state"
        jq '
          .pane_gets=((.pane_gets // 0) + 1)
          | if .pane_gets == (.take_over_after_pane_get // -1) then .process="live" else . end
        ' "$state" | save_state
      fi
    fi
    ;;
  "agent get")
    pane=${3:-}
    if { [ "$pane" = w1:p2 ] && [ "$(jq -r '.candidate_registered // false' "$state")" = true ]; } \
       || { [ "$pane" != w1:p2 ] && [ "$(jq -r '.registered' "$state")" = true ]; }; then
      jq -n --arg pane "$pane" '{id:"cli:agent:get",result:{type:"agent_info",agent:{pane_id:$pane,agent:"pi",agent_status:"idle"}}}'
    else
      printf '{"id":"cli:agent:get","error":{"code":"agent_not_found"}}\n'
    fi
    ;;
  "pane process-info")
    pane=
    while [ "$#" -gt 0 ]; do
      if [ "$1" = --pane ]; then pane=${2:-}; break; fi
      shift
    done
    if [ "$(jq -r '.process_info_failures // 0' "$state")" -gt 0 ]; then
      jq '.process_info_failures -= 1' "$state" | save_state
      printf '{"id":"cli:pane:process_info","result":{"type":"pane_process_info","process_info":{"pane_id":"wrong"}}}\n'
      exit 0
    fi
    if [ "$pane" = w1:p2 ]; then
      mode=$(jq -r '.candidate_process // "shell"' "$state")
    else
      mode=$(jq -r '.process' "$state")
    fi
    if [ "$pane" = w1:p2 ]; then shell_pid=42001; live_pid=42002; else shell_pid=41001; live_pid=41002; fi
    case "$mode" in
      shell)
        jq -n --arg pane "$pane" --argjson shell "$shell_pid" '{id:"cli:pane:process_info",result:{type:"pane_process_info",process_info:{pane_id:$pane,shell_pid:$shell,foreground_process_group_id:$shell,foreground_processes:[{pid:$shell,name:"bash",argv:["/bin/bash"]}]}}}'
        ;;
      live)
        jq -n --arg pane "$pane" --argjson shell "$shell_pid" --argjson live "$live_pid" '{id:"cli:pane:process_info",result:{type:"pane_process_info",process_info:{pane_id:$pane,shell_pid:$shell,foreground_process_group_id:$live,foreground_processes:[{pid:$live,name:"pi",argv:["/opt/pi/bin/pi"]}]}}}'
        ;;
      replacement-shell)
        jq -n --arg pane "$pane" '{id:"cli:pane:process_info",result:{type:"pane_process_info",process_info:{pane_id:$pane,shell_pid:43001,foreground_process_group_id:43001,foreground_processes:[{pid:43001,name:"bash",argv:["/bin/bash"]}]}}}'
        ;;
      *) printf '{"id":"cli:pane:process_info","result":{"type":"pane_process_info","process_info":{"pane_id":"wrong"}}}\n' ;;
    esac
    ;;
  "pane send-text")
    pane=${3:-}
    text=${4:-}
    if [ "$pane" = w1:p2 ]; then
      jq --arg text "$text" '.candidate_pending=((.candidate_pending // "") + $text)' "$state" | save_state
    else
      jq --arg text "$text" '
        .pending=((.pending // "") + $text)
        | if .fail_after_send_once then .fail_after_send_once=false | .process_info_failures=1 else . end
        | if ((.process_after_send // "") != "") then .process=.process_after_send else . end
      ' "$state" | save_state
    fi
    ;;
  "pane run")
    pane=${3:-}
    text=${4:-}
    sleep "${FM_FAKE_HERDR_RUN_DELAY:-0}"
    if [ "$pane" = w1:p2 ]; then
      if [ "$(jq -r '.candidate_takeover_before_run // false' "$state")" = true ]; then
        jq '.candidate_process="live" | .candidate_registered=true' "$state" | save_state
        exit 1
      fi
      if [ "$text" = 'kill -KILL "$$"' ]; then
        jq '.candidate_exists=false | .candidate_registered=false | .candidate_process="dead"' "$state" | save_state
        exit 0
      fi
      [ "$(jq -r '.candidate_run_fail // false' "$state")" != true ] || exit 1
      cwd=$(jq -r '.candidate_cwd' "$state")
      if [ "$(jq -r '.candidate_run_ambiguous_after_pane_get // false' "$state")" = true ]; then
        (cd "$cwd" && bash -c "$text") || exit 1
        jq '
          .candidate_pending=""
          | .candidate_take_over_after_pane_get=((.candidate_pane_gets // 0) + 2)
        ' "$state" | save_state
        exit 1
      fi
      (cd "$cwd" && bash -c "$text") || exit 1
      jq '
        .candidate_pending=""
        | .candidate_process="live"
        | .candidate_registered=((.candidate_run_unregistered // false) | not)
      ' "$state" | save_state
      [ "$(jq -r '.candidate_run_ambiguous // false' "$state")" != true ] || exit 1
    else
      if [ "$text" = 'kill -KILL "$$"' ]; then
        jq '.recorded_exists=false | .registered=false | .process="dead"' "$state" | save_state
        exit 0
      fi
      pending=$(jq -r '.pending // empty' "$state")
      cwd=$(jq -r '.cwd' "$state")
      new_cwd=$(cd "$cwd" && bash -c "$pending$text; pwd -P") || exit 1
      jq --arg cwd "$new_cwd" '.cwd=$cwd | .pending=""' "$state" | save_state
    fi
    ;;
  "pane send-keys")
    pane=${3:-}
    key=${4:-}
    if [ "$key" = ctrl+c ]; then
      sleep "${FM_FAKE_HERDR_CLEAR_DELAY:-0}"
      if [ "$pane" = w1:p2 ]; then
        jq '.candidate_pending=""' "$state" | save_state
      else
        jq '.pending=""' "$state" | save_state
      fi
    elif [ "$key" = enter ]; then
      if [ "$pane" = w1:p2 ]; then
        jq '.candidate_pending=""' "$state" | save_state
      else
        pending=$(jq -r '.pending // empty' "$state")
        cwd=$(jq -r '.cwd' "$state")
        if [ -n "$pending" ]; then
          new_cwd=$(cd "$cwd" && bash -c "$pending; pwd -P") || exit 1
          jq --arg cwd "$new_cwd" '.cwd=$cwd | .pending=""' "$state" | save_state
        fi
      fi
    fi
    ;;
  "tab list")
    if [ "$(jq -r '.candidate_exists // false' "$state")" = true ]; then
      jq '{id:"cli:tab:list",result:{type:"tab_list",tabs:[{tab_id:"w1:t1",label:"fm-direct"},{tab_id:"w1:t2",label:.candidate_label}]}}' "$state"
    else
      printf '{"id":"cli:tab:list","result":{"type":"tab_list","tabs":[{"tab_id":"w1:t1","label":"fm-direct"}]}}\n'
    fi
    ;;
  "pane list")
    if [ "$(jq -r '.candidate_exists // false' "$state")" = true ]; then
      printf '{"id":"cli:pane:list","result":{"type":"pane_list","panes":[{"pane_id":"w1:p1","tab_id":"w1:t1"},{"pane_id":"w1:p2","tab_id":"w1:t2"}]}}\n'
    else
      printf '{"id":"cli:pane:list","result":{"type":"pane_list","panes":[{"pane_id":"w1:p1","tab_id":"w1:t1"}]}}\n'
    fi
    ;;
  "tab create")
    workspace=
    cwd=
    label=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --workspace) workspace=${2:-}; shift 2 ;;
        --cwd) cwd=${2:-}; shift 2 ;;
        --label) label=${2:-}; shift 2 ;;
        *) shift ;;
      esac
    done
    [ "$workspace" = w1 ] || exit 1
    if [ -n "${FM_FAKE_EXPECT_WIRING_PATH:-}" ] \
       && [ "$(cat "$FM_FAKE_EXPECT_WIRING_PATH" 2>/dev/null)" != "${FM_FAKE_EXPECT_WIRING_VALUE:-}" ]; then
      : > "${FM_FAKE_EXPECT_WIRING_FAILURE:?}"
      exit 1
    fi
    jq --arg cwd "$cwd" --arg label "$label" '
      .candidate_exists=true
      | .candidate_cwd=$cwd
      | .candidate_label=$label
      | .candidate_pending=""
      | .candidate_process="shell"
      | .candidate_registered=false
    ' "$state" | save_state
    if [ "$(jq -r '.candidate_create_ambiguous_once // false' "$state")" = true ]; then
      jq '.candidate_create_ambiguous_once=false' "$state" | save_state
      exit 1
    fi
    if [ -n "${FM_FAKE_HERDR_CREATE_MARKER:-}" ]; then
      : > "$FM_FAKE_HERDR_CREATE_MARKER"
      while [ ! -e "${FM_FAKE_HERDR_CREATE_RELEASE:?}" ]; do sleep 0.01; done
    fi
    jq -n --arg cwd "$cwd" --arg label "$label" '{id:"cli:tab:create",result:{type:"tab_created",tab:{tab_id:"w1:t2",workspace_id:"w1",label:$label},root_pane:{pane_id:"w1:p2",tab_id:"w1:t2",workspace_id:"w1",foreground_cwd:$cwd}}}'
    ;;
  "pane close")
    pane=${3:-}
    if [ "$pane" = w1:p2 ]; then
      jq '.candidate_exists=false | .candidate_registered=false | .candidate_process="dead" | .frozen=false' "$state" | save_state
    else
      jq '.recorded_exists=false | .registered=false | .process="dead" | .frozen=false' "$state" | save_state
    fi
    ;;
esac
SH
chmod +x "$TMP_ROOT/fakebin/herdr"

cat > "$TMP_ROOT/fakebin/ps" <<'SH'
#!/usr/bin/env bash
state=${FM_FAKE_HERDR_STATE:?}
case "$*" in
  "-axo pid=,ppid=") printf '41001 1\n42001 1\n' ;;
  "-p 41001 -o stat="|"-p 42001 -o stat=")
    if [ "$(jq -r '.frozen // false' "$state")" = true ]; then printf 'T\n'; else printf 'S\n'; fi
    ;;
  "-p 41001 -o comm="|"-p 42001 -o comm=") printf 'bash\n' ;;
  "-p 41001 -o lstart= -o command=")
    printf 'Mon Jan  1 00:00:00 2024 /bin/bash\n'
    jq '
      .identity_reads=((.identity_reads // 0) + 1)
      | if .replace_after_identity then .process="replacement-shell" else . end
    ' "$state" > "$state.tmp.$$" && mv "$state.tmp.$$" "$state"
    ;;
  "-p 42001 -o lstart= -o command=")
    printf 'Mon Jan  1 00:00:00 2024 /bin/bash\n'
    jq '
      .identity_reads=((.identity_reads // 0) + 1)
      | if .candidate_replace_after_identity then .candidate_process="replacement-shell" else . end
    ' "$state" > "$state.tmp.$$" && mv "$state.tmp.$$" "$state"
    ;;
  *) exit 1 ;;
esac
SH
chmod +x "$TMP_ROOT/fakebin/ps"

cat > "$TMP_ROOT/fakebin/kill" <<'SH'
#!/usr/bin/env bash
set -u
state=${FM_FAKE_HERDR_STATE:?}
case "${1:-} ${2:-}" in
  "-STOP 41001")
    jq '.stop_calls=((.stop_calls // 0) + 1) | .frozen=true | if (.take_over_on_stop // false) then .process="live" else . end' \
      "$state" > "$state.tmp.$$" && mv "$state.tmp.$$" "$state"
    ;;
  "-STOP 42001")
    jq '.stop_calls=((.stop_calls // 0) + 1) | .frozen=true | if (.candidate_take_over_on_stop // false) then .candidate_process="live" | .candidate_registered=true else . end' \
      "$state" > "$state.tmp.$$" && mv "$state.tmp.$$" "$state"
    ;;
  "-CONT 41001"|"-CONT 42001")
    jq '.frozen=false' "$state" > "$state.tmp.$$" && mv "$state.tmp.$$" "$state"
    ;;
  *) exit 1 ;;
esac
SH
chmod +x "$TMP_ROOT/fakebin/kill"

cat > "$TMP_ROOT/fakebin/claude" <<'SH'
#!/usr/bin/env bash
if [ -n "${FM_FAKE_CLAUDE_ENV_LOG:-}" ]; then
  printf 'GOTMPDIR=%s\nTRACEPARENT=%s\n' "${GOTMPDIR:-}" "${TRACEPARENT:-}" > "$FM_FAKE_CLAUDE_ENV_LOG"
fi
exit 0
SH
chmod +x "$TMP_ROOT/fakebin/claude"

cat > "$TMP_ROOT/fakebin/pi" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$TMP_ROOT/fakebin/pi"

cat > "$TMP_ROOT/fakebin/codex" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$TMP_ROOT/fakebin/codex"

cat > "$TMP_ROOT/fakebin/mv" <<'SH'
#!/usr/bin/env bash
set -u
real_mv=${FM_FAKE_REAL_MV:-$(PATH=/usr/bin:/bin command -v mv)}
target=${!#}
source_match=0
for arg in "$@"; do
  case "$arg" in *.meta.relaunch.*) source_match=1 ;; esac
done
if [ -n "${FM_FAKE_MV_PROVENANCE_BLOCK_RECEIPT_TARGET:-}" ] \
   && [ "$target" = "$FM_FAKE_MV_PROVENANCE_BLOCK_RECEIPT_TARGET" ]; then
  "$real_mv" "$@" || exit 1
  mkdir "$target/launch-receipt" || exit 1
  exit 0
fi
if [ -n "${FM_FAKE_MV_PROVENANCE_MARKER:-}" ] \
   && [ "$target" = "${FM_FAKE_MV_PROVENANCE_TARGET:-}" ]; then
  "$real_mv" "$@" || exit 1
  : > "$FM_FAKE_MV_PROVENANCE_MARKER"
  while [ ! -e "${FM_FAKE_MV_PROVENANCE_RELEASE:?}" ]; do sleep 0.01; done
  exit 0
fi
if [ -n "${FM_FAKE_MV_PUBLISH_MARKER:-}" ] \
   && [ "$target" = "${FM_FAKE_MV_PUBLISH_TARGET:-}" ] \
   && [ "$source_match" = 1 ]; then
  "$real_mv" "$@" || exit 1
  : > "$FM_FAKE_MV_PUBLISH_MARKER"
  while [ ! -e "${FM_FAKE_MV_PUBLISH_RELEASE:?}" ]; do sleep 0.01; done
  exit 0
fi
exec "$real_mv" "$@"
SH
chmod +x "$TMP_ROOT/fakebin/mv"

cat > "$TMP_ROOT/fakebin/date" <<'SH'
#!/usr/bin/env bash
set -u
real_date=${FM_FAKE_REAL_DATE:-$(PATH=/usr/bin:/bin command -v date)}
if [ "${1:-}" = +%s ] && [ -n "${FM_FAKE_DATE_MARKER:-}" ]; then
  : > "$FM_FAKE_DATE_MARKER"
  while [ ! -e "${FM_FAKE_DATE_RELEASE:?}" ]; do sleep 0.01; done
fi
exec "$real_date" "$@"
SH
chmod +x "$TMP_ROOT/fakebin/date"

cat > "$TMP_ROOT/fakebin/git" <<'SH'
#!/usr/bin/env bash
set -u
real_git=${FM_FAKE_REAL_GIT:-$(PATH=/usr/bin:/bin command -v git)}
if [ "$*" = "-C ${FM_FAKE_GIT_WORKTREE:-none} rev-parse --git-path info/exclude" ] \
   && [ -n "${FM_FAKE_GIT_MARKER:-}" ]; then
  : > "$FM_FAKE_GIT_MARKER"
  while [ ! -e "${FM_FAKE_GIT_RELEASE:?}" ]; do sleep 0.01; done
fi
exec "$real_git" "$@"
SH
chmod +x "$TMP_ROOT/fakebin/git"

write_state() {
  jq -n --arg cwd "$1" --arg process "$2" --argjson registered "$3" \
    '{cwd:$cwd,process:$process,registered:$registered,recorded_exists:true,pending:"",fail_after_send_once:false,process_info_failures:0,process_after_send:"",pane_gets:0,take_over_after_pane_get:-1,frozen:false,stop_calls:0,identity_reads:0,replace_after_identity:false,take_over_on_stop:false,candidate_exists:false,candidate_cwd:"",candidate_pending:"",candidate_process:"shell",candidate_registered:false,candidate_replace_after_identity:false,candidate_take_over_on_stop:false,candidate_takeover_before_run:false,candidate_create_ambiguous_once:false,candidate_run_fail:false,candidate_run_ambiguous:false,candidate_run_ambiguous_after_pane_get:false,candidate_run_unregistered:false,candidate_pane_gets:0,candidate_take_over_after_pane_get:-1,unmanaged_workspace:"w9",unmanaged_pane:"w9:p9",unmanaged_fingerprint:"unchanged"}' > "$STATE"
  : > "$LOG"
}

run_backend() {
  PATH="$TMP_ROOT/fakebin:$PATH" \
    FM_FAKE_HERDR_STATE="$STATE" FM_FAKE_HERDR_LOG="$LOG" FM_FAKE_HERDR_SOCKET="$TMP_ROOT/herdr.sock" \
    FM_HERDR_PS_BIN="$TMP_ROOT/fakebin/ps" FM_HERDR_KILL_BIN="$TMP_ROOT/fakebin/kill" \
    FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 \
    bash -c '. "$0/bin/fm-backend.sh"; "$@"' "$ROOT" "$@"
}

OLD="$TMP_ROOT/old"
mkdir -p "$OLD"

write_state "$OLD" shell true
ordinary=$(run_backend fm_backend_agent_state herdr fmtest:w1:p1)
recovery=$(run_backend fm_backend_recovery_agent_state herdr fmtest:w1:p1)
[ "$ordinary" = alive ] || fail "the ordinary Herdr registry read should remain alive, got '$ordinary'"
[ "$recovery" = dead ] || fail "a retained registration over one lone idle shell should be dead for lifecycle recovery, got '$recovery'"
pass "Herdr relaunch recovery: a provably stale registered-agent report reconciles to agent-free"

write_state "$OLD" live true
recovery=$(run_backend fm_backend_recovery_agent_state herdr fmtest:w1:p1)
[ "$recovery" = alive ] || fail "a registered agent with a distinct foreground process group must remain alive, got '$recovery'"
pass "Herdr relaunch recovery: a real foreground agent remains alive and cannot be replaced"

write_state "$OLD" live false
recovery=$(run_backend fm_backend_recovery_agent_state herdr fmtest:w1:p1)
[ "$recovery" = unreadable ] || fail "an unregistered non-shell process must remain ambiguous, got '$recovery'"
pass "Herdr relaunch recovery: an unregistered foreground process cannot receive lifecycle input"

write_state "$OLD" ambiguous true
recovery=$(run_backend fm_backend_recovery_agent_state herdr fmtest:w1:p1)
[ "$recovery" = unreadable ] || fail "an ambiguous registered process surface must remain unreadable, got '$recovery'"
pass "Herdr relaunch recovery: ambiguous process evidence refuses rather than becoming agent-free"

TARGET="$TMP_ROOT/recorded ' ; touch PWNED ; #"
mkdir -p "$TARGET"
write_state "$OLD" shell true
run_backend fm_backend_prepare_relaunch_path herdr fmtest:w1:p1 "$TARGET" \
  || fail "an agent-free Herdr shell should restore to its exact recorded path"
seen=$(jq -r '.cwd' "$STATE")
[ "$seen" = "$TARGET" ] || fail "the restored foreground cwd should equal the quoted recorded path, got '$seen'"
[ ! -e "$OLD/PWNED" ] || fail "recorded-path bytes escaped shell quoting and executed as syntax"
command=$(awk -F '\x1f' '$2 == "pane" && $3 == "send-text" {print $5}' "$LOG")
case "$command" in "cd -- "*) ;; *) fail "path restoration did not submit a cd command: $command" ;; esac
count_before=$(grep -c $'\x1fpane\x1fsend-text\x1f' "$LOG" || true)
run_backend fm_backend_prepare_relaunch_path herdr fmtest:w1:p1 "$TARGET" \
  || fail "repeated exact-path preparation should be an idempotent success"
count_after=$(grep -c $'\x1fpane\x1fsend-text\x1f' "$LOG" || true)
[ "$count_after" -eq "$count_before" ] || fail "idempotent path preparation submitted a second cd command"
pass "Herdr relaunch recovery: exact path restoration is persistent, quoted, and idempotent"

EXACT_MARKER="$TMP_ROOT/exact-cwd-marker"
write_state "$TARGET" shell true
jq --arg pending "touch '$EXACT_MARKER'; " '.pending=$pending' "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
run_backend fm_backend_prepare_relaunch_path herdr fmtest:w1:p1 "$TARGET" \
  || fail "exact-cwd preparation should still clear pending shell input"
[ ! -e "$EXACT_MARKER" ] || fail "exact-cwd preparation executed preexisting buffered shell input"
[ -z "$(jq -r '.pending // empty' "$STATE")" ] || fail "exact-cwd preparation left shell input buffered"
pass "Herdr relaunch recovery: exact-cwd preparation still clears shell input"

BUFFERED_MARKER="$TMP_ROOT/buffered-marker"
write_state "$OLD" shell true
jq --arg pending "touch '$BUFFERED_MARKER'; " '.pending=$pending' "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
run_backend fm_backend_prepare_relaunch_path herdr fmtest:w1:p1 "$TARGET" \
  || fail "path restoration should clear preexisting idle-shell input before submitting"
[ ! -e "$BUFFERED_MARKER" ] || fail "path restoration executed preexisting buffered shell input"
[ "$(jq -r '.cwd' "$STATE")" = "$TARGET" ] || fail "path restoration lost the recorded path after clearing buffered input"
pass "Herdr relaunch recovery: preexisting shell input is cancelled before path restoration"

write_state "$OLD" shell true
FM_FAKE_HERDR_CLEAR_DELAY=0.2 run_backend fm_backend_prepare_relaunch_path herdr fmtest:w1:p1 "$TARGET" &
first_pid=$!
first_started=0
for _ in {1..500}; do
  if grep -q $'\x1fpane\x1fsend-keys\x1f.*\x1fctrl+c' "$LOG"; then
    first_started=1
    break
  fi
  sleep 0.01
done
[ "$first_started" -eq 1 ] || fail "the first concurrent path preparation did not reach its mutation boundary"
FM_FAKE_HERDR_CLEAR_DELAY=0.2 run_backend fm_backend_prepare_relaunch_path herdr fmtest:w1:p1 "$TARGET" &
second_pid=$!
wait "$first_pid" || fail "the first concurrent path preparation failed"
wait "$second_pid" || fail "the second concurrent path preparation failed"
mutation_order=$(awk -F '\x1f' '$2 == "pane" && $3 == "send-text" {print "send-text"; next} $2 == "pane" && $3 == "send-keys" {print $3 ":" $5}' "$LOG")
expected_order=$'send-keys:ctrl+c\nsend-text\nsend-keys:enter\nsend-keys:ctrl+c'
[ "$mutation_order" = "$expected_order" ] \
  || fail "concurrent path preparations interleaved their pane mutations: $mutation_order"
pass "Herdr relaunch recovery: concurrent preparation is serialized at the pane mutation boundary"

write_state "$OLD" shell true
jq '.fail_after_send_once=true' "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
if run_backend fm_backend_prepare_relaunch_path herdr fmtest:w1:p1 "$TARGET" >/dev/null 2>&1; then
  fail "a transient post-send process inspection failure should abort path restoration"
fi
[ -z "$(jq -r '.pending // empty' "$STATE")" ] || fail "failed path restoration left its command buffered for a retry"
run_backend fm_backend_prepare_relaunch_path herdr fmtest:w1:p1 "$TARGET" \
  || fail "path restoration should retry cleanly after post-send cleanup"
[ "$(jq -r '.cwd' "$STATE")" = "$TARGET" ] || fail "the clean retry did not restore the recorded path"
pass "Herdr relaunch recovery: pre-submit failures clean their buffered command for retry"

write_state "$OLD" shell true
jq '.process_after_send="live"' "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
if run_backend fm_backend_prepare_relaunch_path herdr fmtest:w1:p1 "$TARGET" >/dev/null 2>&1; then
  fail "path restoration should refuse when the shell owner changes after typing"
fi
[ -n "$(jq -r '.pending // empty' "$STATE")" ] || fail "cleanup sent input after the pane stopped belonging to the exact idle shell"
pass "Herdr relaunch recovery: cleanup refuses a changed shell owner"

DIRECT_HOME="$TMP_ROOT/direct-home"
DIRECT_PROJECT="$TMP_ROOT/direct-project"
DIRECT_WT="$TMP_ROOT/direct-worktree"
DIRECT_MARKER="$TMP_ROOT/direct-marker"
DIRECT_ENV_LOG="$TMP_ROOT/direct-env.log"
fm_git_worktree "$DIRECT_PROJECT" "$DIRECT_WT" direct-relaunch
mkdir -p "$DIRECT_HOME/state" "$DIRECT_HOME/data/direct"
cat > "$DIRECT_HOME/data/direct/brief.md" <<'EOF'
# Task
## Captain's intent
Resume the existing worker safely.

## Firstmate spec
Relaunch in the recorded worktree.
EOF
cat > "$DIRECT_HOME/state/direct.meta" <<EOF
window=fmtest:w1:p1
endpoint_task_id=direct
worktree=$DIRECT_WT
project=$DIRECT_PROJECT
harness=claude
kind=ship
mode=no-mistakes
yolo=off
model=test-model
effort=high
traceparent=00-11111111111111111111111111111111-2222222222222222-01
backend=herdr
herdr_session=fmtest
herdr_workspace_id=w1
herdr_tab_id=w1:t1
herdr_pane_id=w1:p1
EOF
cp "$DIRECT_HOME/state/direct.meta" "$DIRECT_HOME/state/direct.meta.original"
reset_direct_meta() {
  cp "$DIRECT_HOME/state/direct.meta.original" "$DIRECT_HOME/state/direct.meta"
  rm -f "$DIRECT_HOME/state/direct.control-relaunch-candidate"
}
write_direct_candidate_record() {  # <phase>
  cat > "$DIRECT_HOME/state/direct.control-relaunch-candidate" <<EOF
v1
task=direct
phase=$1
tx=prior
session=fmtest
workspace=w1
old_tab=w1:t1
old_pane=w1:p1
candidate_tab=w1:t2
candidate_pane=w1:p2
worktree=$DIRECT_WT
replacement_harness=claude
replacement_model=test-model
replacement_effort=high
EOF
}
printf '%s\n' "$$" > "$DIRECT_HOME/state/.lock"
printf '%s on\n' "$$" > "$DIRECT_HOME/state/.trace-context-effective"
write_state "$DIRECT_WT" shell true
jq --arg pending "touch '$DIRECT_MARKER'; " '.pending=$pending' "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
DIRECT_OUT=$(PATH="$TMP_ROOT/fakebin:$PATH" FM_HOME="$DIRECT_HOME" FM_FAKE_HERDR_STATE="$STATE" \
  FM_FAKE_HERDR_LOG="$LOG" FM_HERDR_PS_BIN="$TMP_ROOT/fakebin/ps" FM_HERDR_KILL_BIN="$TMP_ROOT/fakebin/kill" \
  FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 FM_FAKE_CLAUDE_ENV_LOG="$DIRECT_ENV_LOG" \
  FM_SPAWN_NO_GUARD=1 "$ROOT/bin/fm-spawn.sh" direct --relaunch 2>&1) \
  || fail "direct Herdr relaunch should prepare its endpoint before launch: $DIRECT_OUT"
[ ! -e "$DIRECT_MARKER" ] || fail "direct Herdr relaunch executed buffered shell input before launch"
[ "$(cat "$DIRECT_ENV_LOG" 2>/dev/null)" = $'GOTMPDIR=/tmp/fm-direct/gotmp\nTRACEPARENT=00-11111111111111111111111111111111-2222222222222222-01' ] \
  || fail "direct Herdr relaunch did not preserve its environment and trace carrier: $(cat "$DIRECT_ENV_LOG" 2>/dev/null)"
case "$DIRECT_OUT" in *"spawned direct "*) : ;; *) fail "direct Herdr relaunch did not complete: $DIRECT_OUT" ;; esac
[ "$(jq -r '.stop_calls' "$STATE")" -eq 0 ] \
  || fail "successful replacement launch or cleanup signaled a sampled OS process"
[ "$(awk -F= '$1 == "herdr_pane_id" { print $2 }' "$DIRECT_HOME/state/direct.meta")" = w1:p2 ] \
  || fail "successful replacement did not publish the fresh pane binding"
jq -e '.endpoints[] | select(.id == "direct") | .endpoint.target == "fmtest:w1:p2"' \
  "$DIRECT_HOME/state/home-summary.json" >/dev/null \
  || fail "successful replacement did not refresh its published home-summary endpoint"
if ! grep -q '^model=test-model$' "$DIRECT_HOME/state/direct.meta" \
   || ! grep -q '^effort=high$' "$DIRECT_HOME/state/direct.meta" \
   || ! grep -q '^traceparent=00-11111111111111111111111111111111-2222222222222222-01$' "$DIRECT_HOME/state/direct.meta"; then
  fail "successful replacement did not preserve its model, effort, and trace binding: $(cat "$DIRECT_HOME/state/direct.meta")"
fi
pass "fm-spawn relaunch: fresh endpoint becomes authoritative only after launch proof"

reset_direct_meta
write_state "$DIRECT_WT" shell true
CREATE_MARKER="$TMP_ROOT/create-window.marker"
CREATE_RELEASE="$TMP_ROOT/create-window.release"
CREATE_OUT="$TMP_ROOT/create-window.out"
PATH="$TMP_ROOT/fakebin:$PATH" FM_HOME="$DIRECT_HOME" FM_FAKE_HERDR_STATE="$STATE" \
  FM_FAKE_HERDR_LOG="$LOG" FM_HERDR_PS_BIN="$TMP_ROOT/fakebin/ps" FM_HERDR_KILL_BIN="$TMP_ROOT/fakebin/kill" \
  FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 FM_SPAWN_NO_GUARD=1 \
  FM_FAKE_HERDR_CREATE_MARKER="$CREATE_MARKER" FM_FAKE_HERDR_CREATE_RELEASE="$CREATE_RELEASE" \
  "$ROOT/bin/fm-spawn.sh" direct --relaunch > "$CREATE_OUT" 2>&1 &
create_pid=$!
for _ in {1..500}; do [ ! -e "$CREATE_MARKER" ] || break; sleep 0.01; done
[ -e "$CREATE_MARKER" ] || fail "pre-journal crash simulation never reached endpoint creation"
kill -KILL "$create_pid" 2>/dev/null || fail "could not stop relaunch in the pre-journal window"
touch "$CREATE_RELEASE"
wait "$create_pid" 2>/dev/null || true
[ "$(jq -r '.candidate_exists' "$STATE")" = true ] || fail "pre-journal crash simulation left no candidate to discover"
DIRECT_OUT=$(PATH="$TMP_ROOT/fakebin:$PATH" FM_HOME="$DIRECT_HOME" FM_FAKE_HERDR_STATE="$STATE" \
  FM_FAKE_HERDR_LOG="$LOG" FM_HERDR_PS_BIN="$TMP_ROOT/fakebin/ps" FM_HERDR_KILL_BIN="$TMP_ROOT/fakebin/kill" \
  FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 FM_SPAWN_NO_GUARD=1 \
  "$ROOT/bin/fm-spawn.sh" direct --relaunch 2>&1) \
  || fail "retry could not discover and retire the pre-journal candidate: $DIRECT_OUT"
case "$DIRECT_OUT" in *"spawned direct "*) : ;; *) fail "pre-journal recovery did not complete relaunch: $DIRECT_OUT" ;; esac
pass "fm-spawn relaunch: retry discovers the exact pre-journal candidate"

reset_direct_meta
write_state "$DIRECT_WT" shell true
jq '.candidate_create_ambiguous_once=true' "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
if DIRECT_OUT=$(PATH="$TMP_ROOT/fakebin:$PATH" FM_HOME="$DIRECT_HOME" FM_FAKE_HERDR_STATE="$STATE" \
    FM_FAKE_HERDR_LOG="$LOG" FM_HERDR_PS_BIN="$TMP_ROOT/fakebin/ps" FM_HERDR_KILL_BIN="$TMP_ROOT/fakebin/kill" \
    FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" direct --relaunch 2>&1); then
  fail "ambiguous candidate creation should require recovery: $DIRECT_OUT"
fi
grep -q '^phase=creation-failed$' "$DIRECT_HOME/state/direct.control-relaunch-candidate" \
  || fail "ambiguous candidate creation did not retain recoverable label provenance"
[ "$(jq -r '.candidate_exists' "$STATE")" = true ] \
  || fail "ambiguous candidate creation did not commit its endpoint"
DIRECT_OUT=$(PATH="$TMP_ROOT/fakebin:$PATH" FM_HOME="$DIRECT_HOME" FM_FAKE_HERDR_STATE="$STATE" \
  FM_FAKE_HERDR_LOG="$LOG" FM_HERDR_PS_BIN="$TMP_ROOT/fakebin/ps" FM_HERDR_KILL_BIN="$TMP_ROOT/fakebin/kill" \
  FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 FM_SPAWN_NO_GUARD=1 \
  "$ROOT/bin/fm-spawn.sh" direct --relaunch 2>&1) \
  || fail "retry could not discover and retire the ambiguously created candidate: $DIRECT_OUT"
[ "$(awk -F= '$1 == "herdr_pane_id" { print $2 }' "$DIRECT_HOME/state/direct.meta")" = w1:p2 ] \
  || fail "retry did not publish a replacement after ambiguous creation recovery"
[ "$(grep -c $'\x1ftab\x1fcreate\x1f' "$LOG" || true)" -eq 2 ] \
  || fail "ambiguous creation recovery did not retire before creating one replacement"
pass "fm-spawn relaunch: retry recovers ambiguous candidate creation"

reset_direct_meta
write_state "$DIRECT_WT" shell true
LIVE_MARKER="$TMP_ROOT/post-live-window.marker"
LIVE_RELEASE="$TMP_ROOT/post-live-window.release"
LIVE_OUT="$TMP_ROOT/post-live-window.out"
PATH="$TMP_ROOT/fakebin:$PATH" FM_HOME="$DIRECT_HOME" FM_FAKE_HERDR_STATE="$STATE" \
  FM_FAKE_HERDR_LOG="$LOG" FM_HERDR_PS_BIN="$TMP_ROOT/fakebin/ps" FM_HERDR_KILL_BIN="$TMP_ROOT/fakebin/kill" \
  FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 FM_SPAWN_NO_GUARD=1 \
  FM_FAKE_HERDR_POST_LIVE_MARKER="$LIVE_MARKER" FM_FAKE_HERDR_POST_LIVE_RELEASE="$LIVE_RELEASE" \
  "$ROOT/bin/fm-spawn.sh" direct --relaunch > "$LIVE_OUT" 2>&1 &
live_pid=$!
for _ in {1..500}; do [ ! -e "$LIVE_MARKER" ] || break; sleep 0.01; done
[ -e "$LIVE_MARKER" ] || fail "post-live crash simulation never reached launch proof"
kill -KILL "$live_pid" 2>/dev/null || fail "could not stop relaunch in the post-live window"
touch "$LIVE_RELEASE"
wait "$live_pid" 2>/dev/null || true
[ "$(jq -r '.candidate_registered' "$STATE")" = true ] || fail "post-live crash simulation left no live candidate to adopt"
DIRECT_OUT=$(PATH="$TMP_ROOT/fakebin:$PATH" FM_HOME="$DIRECT_HOME" FM_FAKE_HERDR_STATE="$STATE" \
  FM_FAKE_HERDR_LOG="$LOG" FM_HERDR_PS_BIN="$TMP_ROOT/fakebin/ps" FM_HERDR_KILL_BIN="$TMP_ROOT/fakebin/kill" \
  FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 FM_SPAWN_NO_GUARD=1 \
  "$ROOT/bin/fm-spawn.sh" direct --relaunch 2>&1) \
  || fail "retry could not adopt the exact post-live candidate: $DIRECT_OUT"
[ "$(awk -F= '$1 == "herdr_pane_id" { print $2 }' "$DIRECT_HOME/state/direct.meta")" = w1:p2 ] \
  || fail "post-live adoption did not publish the discovered candidate"
create_count=$(grep -c $'\x1ftab\x1fcreate\x1f' "$LOG" || true)
[ "$create_count" -eq 1 ] || fail "post-live adoption created a duplicate replacement endpoint"
grep -q '^candidate_state=adopted-alive$' "$DIRECT_HOME/state/direct.control-relaunch-candidate" \
  || fail "post-live adoption did not persist its reconciliation"
pass "fm-spawn relaunch: retry adopts the exact post-live candidate"

reset_direct_meta
mkdir -p "$DIRECT_WT/.claude"
printf '%s\n' prior-claude-wiring > "$DIRECT_WT/.claude/settings.local.json"
rm -f "$DIRECT_HOME/state/direct.pi-ext.ts"
write_state "$DIRECT_WT" shell true
SWITCH_MARKER="$TMP_ROOT/post-live-switch.marker"
SWITCH_RELEASE="$TMP_ROOT/post-live-switch.release"
SWITCH_OUT="$TMP_ROOT/post-live-switch.out"
PATH="$TMP_ROOT/fakebin:$PATH" FM_HOME="$DIRECT_HOME" FM_FAKE_HERDR_STATE="$STATE" \
  FM_FAKE_HERDR_LOG="$LOG" FM_HERDR_PS_BIN="$TMP_ROOT/fakebin/ps" FM_HERDR_KILL_BIN="$TMP_ROOT/fakebin/kill" \
  FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 FM_SPAWN_NO_GUARD=1 \
  FM_FAKE_HERDR_POST_LIVE_MARKER="$SWITCH_MARKER" FM_FAKE_HERDR_POST_LIVE_RELEASE="$SWITCH_RELEASE" \
  "$ROOT/bin/fm-spawn.sh" direct --relaunch --harness pi > "$SWITCH_OUT" 2>&1 &
switch_pid=$!
for _ in {1..500}; do [ ! -e "$SWITCH_MARKER" ] || break; sleep 0.01; done
[ -e "$SWITCH_MARKER" ] || fail "harness-switch crash simulation never reached launch proof"
kill -KILL "$switch_pid" 2>/dev/null || fail "could not stop harness-switch relaunch after live launch"
touch "$SWITCH_RELEASE"
wait "$switch_pid" 2>/dev/null || true
[ -f "$DIRECT_WT/.claude/settings.local.json" ] \
  || fail "crash simulation unexpectedly retired prior Claude wiring"
[ -f "$DIRECT_HOME/state/direct.pi-ext.ts" ] \
  || fail "crash simulation did not leave replacement Pi wiring"
rm -f "$DIRECT_WT/.claude/settings.local.json"
mkdir "$DIRECT_WT/.claude/settings.local.json"
if DIRECT_OUT=$(PATH="$TMP_ROOT/fakebin:$PATH" FM_HOME="$DIRECT_HOME" FM_FAKE_HERDR_STATE="$STATE" \
    FM_FAKE_HERDR_LOG="$LOG" FM_HERDR_PS_BIN="$TMP_ROOT/fakebin/ps" FM_HERDR_KILL_BIN="$TMP_ROOT/fakebin/kill" \
    FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" direct --relaunch --harness pi 2>&1); then
  fail "crash adoption reported success while prior wiring could not be retired: $DIRECT_OUT"
fi
[ "$(awk -F= '$1 == "herdr_pane_id" { print $2 }' "$DIRECT_HOME/state/direct.meta")" = w1:p2 ] \
  || fail "failed prior-wiring retirement did not preserve the published replacement binding"
[ "$(awk -F= '$1 == "harness" { print $2 }' "$DIRECT_HOME/state/direct.meta")" = pi ] \
  || fail "failed prior-wiring retirement did not preserve the published replacement harness"
[ -f "$DIRECT_HOME/state/direct.pi-ext.ts" ] \
  || fail "failed prior-wiring retirement removed replacement wiring"
rmdir "$DIRECT_WT/.claude/settings.local.json"
printf '%s\n' prior-claude-wiring > "$DIRECT_WT/.claude/settings.local.json"
DIRECT_OUT=$(PATH="$TMP_ROOT/fakebin:$PATH" FM_HOME="$DIRECT_HOME" FM_FAKE_HERDR_STATE="$STATE" \
  FM_FAKE_HERDR_LOG="$LOG" FM_HERDR_PS_BIN="$TMP_ROOT/fakebin/ps" FM_HERDR_KILL_BIN="$TMP_ROOT/fakebin/kill" \
  FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 FM_SPAWN_NO_GUARD=1 \
  "$ROOT/bin/fm-spawn.sh" direct --relaunch --harness pi 2>&1) \
  || fail "retry could not adopt the harness-switched candidate: $DIRECT_OUT"
[ ! -e "$DIRECT_WT/.claude/settings.local.json" ] \
  || fail "crash adoption retained prior Claude wiring"
[ -f "$DIRECT_HOME/state/direct.pi-ext.ts" ] \
  || fail "crash adoption removed replacement Pi wiring"
[ "$(awk -F= '$1 == "harness" { print $2 }' "$DIRECT_HOME/state/direct.meta")" = pi ] \
  || fail "crash adoption did not publish the replacement harness"
[ "$(grep -c $'\x1ftab\x1fcreate\x1f' "$LOG" || true)" -eq 1 ] \
  || fail "wiring reconciliation created a duplicate replacement endpoint"
pass "fm-spawn relaunch: crash adoption publishes before retryable wiring retirement"
rm -f "$DIRECT_HOME/state/direct.pi-ext.ts"

reset_direct_meta
mkdir -p "$DIRECT_WT/.claude"
printf '%s\n' prior-codex-switch-wiring > "$DIRECT_WT/.claude/settings.local.json"
printf '%s\n' prior-codex-switch-gen > "$DIRECT_HOME/state/direct.busy-gen"
printf '%s\n' 'v1 gen=prior-codex-switch-gen seq=3 state=idle source=test event=prior ts=1' \
  > "$DIRECT_HOME/state/direct.busy-state"
write_state "$DIRECT_WT" shell true
CODEX_PUBLISH_MARKER="$TMP_ROOT/codex-publish.marker"
CODEX_PUBLISH_RELEASE="$TMP_ROOT/codex-publish.release"
CODEX_PUBLISH_OUT="$TMP_ROOT/codex-publish.out"
PATH="$TMP_ROOT/fakebin:$PATH" FM_HOME="$DIRECT_HOME" FM_FAKE_HERDR_STATE="$STATE" \
  FM_FAKE_HERDR_LOG="$LOG" FM_HERDR_PS_BIN="$TMP_ROOT/fakebin/ps" FM_HERDR_KILL_BIN="$TMP_ROOT/fakebin/kill" \
  FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 FM_SPAWN_NO_GUARD=1 \
  FM_FAKE_MV_PUBLISH_MARKER="$CODEX_PUBLISH_MARKER" FM_FAKE_MV_PUBLISH_RELEASE="$CODEX_PUBLISH_RELEASE" \
  FM_FAKE_MV_PUBLISH_TARGET="$DIRECT_HOME/state/direct.meta" \
  "$ROOT/bin/fm-spawn.sh" direct --relaunch --harness codex > "$CODEX_PUBLISH_OUT" 2>&1 &
codex_publish_pid=$!
for _ in {1..500}; do [ ! -e "$CODEX_PUBLISH_MARKER" ] || break; sleep 0.01; done
[ -e "$CODEX_PUBLISH_MARKER" ] || fail "unarmed-harness switch never reached metadata publication"
[ ! -e "$DIRECT_HOME/state/direct.busy-gen" ] && [ ! -e "$DIRECT_HOME/state/direct.busy-state" ] \
  || fail "unarmed-harness replacement retained the prior busy generation before publication"
rm -f "$DIRECT_WT/.claude/settings.local.json"
mkdir "$DIRECT_WT/.claude/settings.local.json"
touch "$CODEX_PUBLISH_RELEASE"
if wait "$codex_publish_pid"; then
  fail "unarmed-harness switch succeeded while prior harness wiring retirement was blocked"
fi
[ "$(awk -F= '$1 == "harness" { print $2 }' "$DIRECT_HOME/state/direct.meta")" = codex ] \
  || fail "failed wiring retirement did not preserve the published unarmed harness"
[ ! -e "$DIRECT_HOME/state/direct.busy-gen" ] && [ ! -e "$DIRECT_HOME/state/direct.busy-state" ] \
  || fail "failed wiring retirement resurrected the retired busy generation"
rmdir "$DIRECT_WT/.claude/settings.local.json"
printf '%s\n' prior-codex-switch-wiring > "$DIRECT_WT/.claude/settings.local.json"
DIRECT_OUT=$(PATH="$TMP_ROOT/fakebin:$PATH" FM_HOME="$DIRECT_HOME" FM_FAKE_HERDR_STATE="$STATE" \
  FM_FAKE_HERDR_LOG="$LOG" FM_HERDR_PS_BIN="$TMP_ROOT/fakebin/ps" FM_HERDR_KILL_BIN="$TMP_ROOT/fakebin/kill" \
  FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 FM_SPAWN_NO_GUARD=1 \
  "$ROOT/bin/fm-spawn.sh" direct --relaunch --harness codex 2>&1) \
  || fail "binding recovery could not finish the unarmed-harness switch: $DIRECT_OUT"
[ ! -e "$DIRECT_HOME/state/direct.busy-gen" ] && [ ! -e "$DIRECT_HOME/state/direct.busy-state" ] \
  || fail "unarmed-harness binding recovery restored a prior busy generation"
[ "$(grep -c $'\x1ftab\x1fcreate\x1f' "$LOG" || true)" -eq 1 ] \
  || fail "unarmed-harness binding recovery created a duplicate endpoint"
pass "fm-spawn relaunch: unarmed harness switches retire stale busy generations"

reset_direct_meta
write_state "$DIRECT_WT" shell true
jq '.candidate_take_over_after_pane_get=1' "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
if DIRECT_OUT=$(PATH="$TMP_ROOT/fakebin:$PATH" FM_HOME="$DIRECT_HOME" FM_FAKE_HERDR_STATE="$STATE" \
    FM_FAKE_HERDR_LOG="$LOG" FM_HERDR_PS_BIN="$TMP_ROOT/fakebin/ps" FM_HERDR_KILL_BIN="$TMP_ROOT/fakebin/kill" \
    FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" direct --relaunch 2>&1); then
  fail "direct Herdr relaunch should refuse after foreground ownership changes: $DIRECT_OUT"
fi
run_count=$(grep -c $'\x1fpane\x1frun\x1f' "$LOG" || true)
[ "$run_count" -eq 0 ] || fail "owner-change refusal sent input after foreground ownership changed"
cmp -s "$DIRECT_HOME/state/direct.meta.original" "$DIRECT_HOME/state/direct.meta" \
  || fail "pre-launch takeover changed the authoritative endpoint binding"
case "$DIRECT_OUT" in *"acquired an agent before launch ownership was established"*) : ;; *) fail "owner-change refusal was not explicit: $DIRECT_OUT" ;; esac
create_count=$(grep -c $'\x1ftab\x1fcreate\x1f' "$LOG" || true)
if DIRECT_OUT=$(PATH="$TMP_ROOT/fakebin:$PATH" FM_HOME="$DIRECT_HOME" FM_FAKE_HERDR_STATE="$STATE" \
    FM_FAKE_HERDR_LOG="$LOG" FM_HERDR_PS_BIN="$TMP_ROOT/fakebin/ps" FM_HERDR_KILL_BIN="$TMP_ROOT/fakebin/kill" \
    FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" direct --relaunch 2>&1); then
  fail "retry adopted the pre-launch takeover: $DIRECT_OUT"
fi
[ "$(grep -c $'\x1ftab\x1fcreate\x1f' "$LOG" || true)" -eq "$create_count" ] \
  || fail "retry created a duplicate beside the pre-launch takeover"
cmp -s "$DIRECT_HOME/state/direct.meta.original" "$DIRECT_HOME/state/direct.meta" \
  || fail "retry published the pre-launch takeover"
pass "fm-spawn relaunch: pre-launch takeover preserves the old binding"

reset_direct_meta
mkdir -p "$DIRECT_WT/.claude"
printf '%s\n' prior-claude-wiring > "$DIRECT_WT/.claude/settings.local.json"
printf '%s\n' prior-busy-gen > "$DIRECT_HOME/state/direct.busy-gen"
printf '%s\n' 'v1 gen=prior-busy-gen seq=7 state=idle source=test event=prior ts=1' > "$DIRECT_HOME/state/direct.busy-state"
write_state "$DIRECT_WT" shell true
jq '.candidate_run_fail=true' "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
if DIRECT_OUT=$(PATH="$TMP_ROOT/fakebin:$PATH" FM_HOME="$DIRECT_HOME" FM_FAKE_HERDR_STATE="$STATE" \
    FM_FAKE_HERDR_LOG="$LOG" FM_HERDR_PS_BIN="$TMP_ROOT/fakebin/ps" FM_HERDR_KILL_BIN="$TMP_ROOT/fakebin/kill" \
    FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" direct --relaunch 2>&1); then
  fail "failed candidate launch should not report a successful relaunch: $DIRECT_OUT"
fi
cmp -s "$DIRECT_HOME/state/direct.meta.original" "$DIRECT_HOME/state/direct.meta" \
  || fail "failed candidate launch changed the authoritative endpoint binding"
[ "$(jq -r '.candidate_exists' "$STATE")" = false ] \
  || fail "failed agent-free candidate launch was not rolled back"
grep -q '^phase=rolled-back$' "$DIRECT_HOME/state/direct.control-relaunch-candidate" \
  || fail "failed candidate launch left no durable rollback evidence"
[ "$(cat "$DIRECT_WT/.claude/settings.local.json")" = prior-claude-wiring ] \
  || fail "failed candidate launch did not restore prior harness wiring"
[ "$(cat "$DIRECT_HOME/state/direct.busy-gen")" = prior-busy-gen ] \
  || fail "failed candidate launch did not restore the prior busy generation"
grep -q 'gen=prior-busy-gen seq=7 state=idle' "$DIRECT_HOME/state/direct.busy-state" \
  || fail "failed candidate launch did not restore prior busy state"
pass "fm-spawn relaunch: failed candidate launch rolls back endpoint, binding, and supervision wiring"

reset_direct_meta
write_state "$DIRECT_WT" shell true
RECEIPT_TARGET="$DIRECT_HOME/state/direct.control-relaunch-candidate.launch/launch"
if DIRECT_OUT=$(PATH="$TMP_ROOT/fakebin:$PATH" FM_HOME="$DIRECT_HOME" FM_FAKE_HERDR_STATE="$STATE" \
    FM_FAKE_HERDR_LOG="$LOG" FM_HERDR_PS_BIN="$TMP_ROOT/fakebin/ps" FM_HERDR_KILL_BIN="$TMP_ROOT/fakebin/kill" \
    FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 FM_SPAWN_NO_GUARD=1 \
    FM_FAKE_MV_PROVENANCE_BLOCK_RECEIPT_TARGET="$RECEIPT_TARGET" \
    "$ROOT/bin/fm-spawn.sh" direct --relaunch 2>&1); then
  fail "replacement launch succeeded without writing its adoption receipt: $DIRECT_OUT"
fi
cmp -s "$DIRECT_HOME/state/direct.meta.original" "$DIRECT_HOME/state/direct.meta" \
  || fail "receipt-write failure changed the authoritative endpoint binding"
[ "$(jq -r '.candidate_registered' "$STATE")" = false ] \
  || fail "receipt-write failure still started a registered replacement agent"
[ "$(jq -r '.candidate_process' "$STATE")" != live ] \
  || fail "receipt-write failure still started the replacement process"
pass "fm-spawn relaunch: receipt failure prevents an unadoptable agent launch"

reset_direct_meta
write_state "$DIRECT_WT" shell true
jq '.candidate_run_ambiguous_after_pane_get=true' "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
if DIRECT_OUT=$(PATH="$TMP_ROOT/fakebin:$PATH" FM_HOME="$DIRECT_HOME" FM_FAKE_HERDR_STATE="$STATE" \
    FM_FAKE_HERDR_LOG="$LOG" FM_HERDR_PS_BIN="$TMP_ROOT/fakebin/ps" FM_HERDR_KILL_BIN="$TMP_ROOT/fakebin/kill" \
    FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 FM_HERDR_RELAUNCH_ABORT_POLLS=10 \
    FM_HERDR_RELAUNCH_ABORT_INTERVAL=0.05 FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" direct --relaunch 2>&1); then
  fail "ambiguous candidate submission should require retry adoption: $DIRECT_OUT"
fi
grep -q '^phase=launch-attempt$' "$DIRECT_HOME/state/direct.control-relaunch-candidate" \
  || fail "ambiguous live submission lost its launch-attempt provenance"
[ "$(jq -r '.candidate_exists and .candidate_registered and (.candidate_process == "live")' "$STATE")" = true ] \
  || fail "ambiguous live submission did not preserve its exact replacement candidate"
DIRECT_OUT=$(PATH="$TMP_ROOT/fakebin:$PATH" FM_HOME="$DIRECT_HOME" FM_FAKE_HERDR_STATE="$STATE" \
  FM_FAKE_HERDR_LOG="$LOG" FM_HERDR_PS_BIN="$TMP_ROOT/fakebin/ps" FM_HERDR_KILL_BIN="$TMP_ROOT/fakebin/kill" \
  FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 FM_SPAWN_NO_GUARD=1 \
  "$ROOT/bin/fm-spawn.sh" direct --relaunch 2>&1) \
  || fail "retry could not adopt an ambiguously submitted live candidate: $DIRECT_OUT"
[ "$(awk -F= '$1 == "herdr_pane_id" { print $2 }' "$DIRECT_HOME/state/direct.meta")" = w1:p2 ] \
  || fail "ambiguous live candidate adoption did not publish its endpoint"
jq -e '.endpoints[] | select(.id == "direct") | .endpoint.target == "fmtest:w1:p2"' \
  "$DIRECT_HOME/state/home-summary.json" >/dev/null \
  || fail "crash adoption did not refresh its published home-summary endpoint"
pass "fm-spawn relaunch: ambiguous live submission remains adoptable"

reset_direct_meta
mkdir -p "$DIRECT_WT/.claude"
printf '%s\n' prior-hard-crash-wiring > "$DIRECT_WT/.claude/settings.local.json"
printf '%s\n' prior-hard-crash-gen > "$DIRECT_HOME/state/direct.busy-gen"
printf '%s\n' 'v1 gen=prior-hard-crash-gen seq=4 state=idle source=test event=prior ts=1' > "$DIRECT_HOME/state/direct.busy-state"
write_state "$DIRECT_WT" shell true
WIRING_MARKER="$TMP_ROOT/wiring-window.marker"
WIRING_RELEASE="$TMP_ROOT/wiring-window.release"
WIRING_OUT="$TMP_ROOT/wiring-window.out"
PATH="$TMP_ROOT/fakebin:$PATH" FM_HOME="$DIRECT_HOME" FM_FAKE_HERDR_STATE="$STATE" \
  FM_FAKE_HERDR_LOG="$LOG" FM_HERDR_PS_BIN="$TMP_ROOT/fakebin/ps" FM_HERDR_KILL_BIN="$TMP_ROOT/fakebin/kill" \
  FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 FM_SPAWN_NO_GUARD=1 \
  FM_FAKE_GIT_WORKTREE="$DIRECT_WT" FM_FAKE_GIT_MARKER="$WIRING_MARKER" FM_FAKE_GIT_RELEASE="$WIRING_RELEASE" \
  "$ROOT/bin/fm-spawn.sh" direct --relaunch > "$WIRING_OUT" 2>&1 &
wiring_pid=$!
for _ in {1..500}; do [ ! -e "$WIRING_MARKER" ] || break; sleep 0.01; done
[ -e "$WIRING_MARKER" ] || fail "wiring crash simulation never reached the first replacement mutation"
kill -KILL "$wiring_pid" 2>/dev/null || fail "could not stop relaunch after replacement wiring mutation"
touch "$WIRING_RELEASE"
wait "$wiring_pid" 2>/dev/null || true
[ "$(cat "$DIRECT_WT/.claude/settings.local.json")" != prior-hard-crash-wiring ] \
  || fail "wiring crash simulation did not mutate replacement wiring"
rm -f "$DIRECT_WT/.claude/settings.local.json"
mkdir "$DIRECT_WT/.claude/settings.local.json"
if DIRECT_OUT=$(PATH="$TMP_ROOT/fakebin:$PATH" FM_HOME="$DIRECT_HOME" FM_FAKE_HERDR_STATE="$STATE" \
    FM_FAKE_HERDR_LOG="$LOG" FM_HERDR_PS_BIN="$TMP_ROOT/fakebin/ps" FM_HERDR_KILL_BIN="$TMP_ROOT/fakebin/kill" \
    FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" direct --relaunch 2>&1); then
  fail "retry should refuse when persisted prior wiring cannot be restored: $DIRECT_OUT"
fi
[ "$(jq -r '.candidate_exists' "$STATE")" = true ] \
  || fail "failed wiring restoration retired the only candidate recovery evidence"
! grep -q '^phase=rolled-back$' "$DIRECT_HOME/state/direct.control-relaunch-candidate" \
  || fail "failed wiring restoration marked candidate rollback complete"
rmdir "$DIRECT_WT/.claude/settings.local.json"
WIRING_FAILURE="$TMP_ROOT/wiring-restore.failure"
DIRECT_OUT=$(PATH="$TMP_ROOT/fakebin:$PATH" FM_HOME="$DIRECT_HOME" FM_FAKE_HERDR_STATE="$STATE" \
  FM_FAKE_HERDR_LOG="$LOG" FM_HERDR_PS_BIN="$TMP_ROOT/fakebin/ps" FM_HERDR_KILL_BIN="$TMP_ROOT/fakebin/kill" \
  FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 FM_SPAWN_NO_GUARD=1 \
  FM_FAKE_EXPECT_WIRING_PATH="$DIRECT_WT/.claude/settings.local.json" \
  FM_FAKE_EXPECT_WIRING_VALUE=prior-hard-crash-wiring FM_FAKE_EXPECT_WIRING_FAILURE="$WIRING_FAILURE" \
  "$ROOT/bin/fm-spawn.sh" direct --relaunch 2>&1) \
  || fail "retry could not proceed after hard-crash rollback: $DIRECT_OUT"
[ ! -e "$WIRING_FAILURE" ] \
  || fail "retry created a replacement before restoring prior harness wiring"
[ "$(cat "$DIRECT_WT/.claude/settings.local.json")" != prior-hard-crash-wiring ] \
  || fail "successful retry did not install its own replacement wiring"
grep -q '^phase=published$' "$DIRECT_HOME/state/direct.control-relaunch-candidate" \
  || fail "hard-crash rollback did not complete before retry publication"
pass "fm-spawn relaunch: hard-crash rollback restores deterministic prior wiring"

reset_direct_meta
mkdir -p "$DIRECT_WT/.claude"
printf '%s\n' prior-provenance-wiring > "$DIRECT_WT/.claude/settings.local.json"
write_state "$DIRECT_WT" shell true
PROVENANCE_MARKER="$TMP_ROOT/provenance-window.marker"
PROVENANCE_RELEASE="$TMP_ROOT/provenance-window.release"
PROVENANCE_OUT="$TMP_ROOT/provenance-window.out"
PROVENANCE_TARGET="$DIRECT_HOME/state/direct.control-relaunch-candidate.launch/launch"
PATH="$TMP_ROOT/fakebin:$PATH" FM_HOME="$DIRECT_HOME" FM_FAKE_HERDR_STATE="$STATE" \
  FM_FAKE_HERDR_LOG="$LOG" FM_HERDR_PS_BIN="$TMP_ROOT/fakebin/ps" FM_HERDR_KILL_BIN="$TMP_ROOT/fakebin/kill" \
  FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 FM_SPAWN_NO_GUARD=1 \
  FM_FAKE_MV_PROVENANCE_MARKER="$PROVENANCE_MARKER" FM_FAKE_MV_PROVENANCE_RELEASE="$PROVENANCE_RELEASE" \
  FM_FAKE_MV_PROVENANCE_TARGET="$PROVENANCE_TARGET" \
  "$ROOT/bin/fm-spawn.sh" direct --relaunch > "$PROVENANCE_OUT" 2>&1 &
provenance_pid=$!
for _ in {1..500}; do [ ! -e "$PROVENANCE_MARKER" ] || break; sleep 0.01; done
[ -e "$PROVENANCE_MARKER" ] || fail "provenance crash simulation never reached atomic installation"
kill -KILL "$provenance_pid" 2>/dev/null || fail "could not stop relaunch during provenance installation"
touch "$PROVENANCE_RELEASE"
wait "$provenance_pid" 2>/dev/null || true
[ -d "$DIRECT_HOME/state/direct.control-relaunch-candidate.launch/prior-snapshot" ] \
  || fail "atomic provenance installation lost the prior wiring snapshot"
jq '.candidate_exists=false | .candidate_registered=false | .candidate_process="dead"' \
  "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
printf '%s\n' interrupted-replacement-wiring > "$DIRECT_WT/.claude/settings.local.json"
PROVENANCE_FAILURE="$TMP_ROOT/provenance-restore.failure"
DIRECT_OUT=$(PATH="$TMP_ROOT/fakebin:$PATH" FM_HOME="$DIRECT_HOME" FM_FAKE_HERDR_STATE="$STATE" \
  FM_FAKE_HERDR_LOG="$LOG" FM_HERDR_PS_BIN="$TMP_ROOT/fakebin/ps" FM_HERDR_KILL_BIN="$TMP_ROOT/fakebin/kill" \
  FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 FM_SPAWN_NO_GUARD=1 \
  FM_FAKE_EXPECT_WIRING_PATH="$DIRECT_WT/.claude/settings.local.json" \
  FM_FAKE_EXPECT_WIRING_VALUE=prior-provenance-wiring FM_FAKE_EXPECT_WIRING_FAILURE="$PROVENANCE_FAILURE" \
  "$ROOT/bin/fm-spawn.sh" direct --relaunch 2>&1) \
  || fail "retry could not restore wiring after missing post-wiring candidate: $DIRECT_OUT"
[ ! -e "$PROVENANCE_FAILURE" ] \
  || fail "retry created a replacement before restoring the preserved wiring snapshot"
case "$DIRECT_OUT" in *"spawned direct "*) : ;; *) fail "post-wiring missing-candidate recovery did not complete: $DIRECT_OUT" ;; esac
pass "fm-spawn relaunch: atomic provenance preserves missing-candidate rollback"

reset_direct_meta
write_state "$DIRECT_WT" shell true
jq '.candidate_run_unregistered=true' "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
if DIRECT_OUT=$(PATH="$TMP_ROOT/fakebin:$PATH" FM_HOME="$DIRECT_HOME" FM_FAKE_HERDR_STATE="$STATE" \
    FM_FAKE_HERDR_LOG="$LOG" FM_HERDR_PS_BIN="$TMP_ROOT/fakebin/ps" FM_HERDR_KILL_BIN="$TMP_ROOT/fakebin/kill" \
    FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 FM_HERDR_RELAUNCH_LAUNCH_POLLS=1 FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" direct --relaunch 2>&1); then
  fail "an unregistered foreground process passed replacement launch proof: $DIRECT_OUT"
fi
cmp -s "$DIRECT_HOME/state/direct.meta.original" "$DIRECT_HOME/state/direct.meta" \
  || fail "an unregistered foreground process changed the authoritative binding"
[ "$(jq -r '.candidate_exists' "$STATE")" = true ] \
  || fail "failed launch proof closed an unregistered foreground process"
grep -q '^phase=launch-attempt$' "$DIRECT_HOME/state/direct.control-relaunch-candidate" \
  || fail "failed launch proof discarded recoverable launch-attempt provenance"
pass "fm-spawn relaunch: publication requires registration and preserves launch provenance"
write_direct_candidate_record launch-attempt
if DIRECT_OUT=$(PATH="$TMP_ROOT/fakebin:$PATH" FM_HOME="$DIRECT_HOME" FM_FAKE_HERDR_STATE="$STATE" \
    FM_FAKE_HERDR_LOG="$LOG" FM_HERDR_PS_BIN="$TMP_ROOT/fakebin/ps" FM_HERDR_KILL_BIN="$TMP_ROOT/fakebin/kill" \
    FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" direct --relaunch 2>&1); then
  fail "adoption accepted an unregistered foreground process: $DIRECT_OUT"
fi
cmp -s "$DIRECT_HOME/state/direct.meta.original" "$DIRECT_HOME/state/direct.meta" \
  || fail "unregistered adoption changed the authoritative binding"
pass "fm-spawn relaunch: adoption requires registration and live process proof"

reset_direct_meta
write_state "$DIRECT_WT" shell true
write_direct_candidate_record created
DIRECT_OUT=$(PATH="$TMP_ROOT/fakebin:$PATH" FM_HOME="$DIRECT_HOME" FM_FAKE_HERDR_STATE="$STATE" \
  FM_FAKE_HERDR_LOG="$LOG" FM_HERDR_PS_BIN="$TMP_ROOT/fakebin/ps" FM_HERDR_KILL_BIN="$TMP_ROOT/fakebin/kill" \
  FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 FM_SPAWN_NO_GUARD=1 \
  "$ROOT/bin/fm-spawn.sh" direct --relaunch 2>&1) \
  || fail "retry could not roll back an exactly recorded missing pre-wiring candidate: $DIRECT_OUT"
[ "$(grep -c $'\x1ftab\x1fcreate\x1f' "$LOG" || true)" -eq 1 ] \
  || fail "missing pre-wiring candidate recovery did not create exactly one replacement"
case "$DIRECT_OUT" in *"spawned direct "*) : ;; *) fail "missing pre-wiring candidate recovery did not complete: $DIRECT_OUT" ;; esac
pass "fm-spawn relaunch: a missing pre-wiring candidate rolls back cleanly"

reset_direct_meta
write_state "$DIRECT_WT" shell true
jq '.candidate_exists=true | .candidate_cwd=$cwd | .candidate_process="shell" | .candidate_registered=true | .candidate_takeover_before_run=true' \
  --arg cwd "$DIRECT_WT" "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
write_direct_candidate_record created
if DIRECT_OUT=$(PATH="$TMP_ROOT/fakebin:$PATH" FM_HOME="$DIRECT_HOME" FM_FAKE_HERDR_STATE="$STATE" \
    FM_FAKE_HERDR_LOG="$LOG" FM_HERDR_PS_BIN="$TMP_ROOT/fakebin/ps" FM_HERDR_KILL_BIN="$TMP_ROOT/fakebin/kill" \
    FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" direct --relaunch 2>&1); then
  fail "retry reported success after another client won the candidate close boundary: $DIRECT_OUT"
fi
[ "$(jq -r '.candidate_exists and .candidate_registered and (.candidate_process == "live")' "$STATE")" = true ] \
  || fail "candidate cleanup removed the new foreground owner"
! grep -Fq $'\x1fpane\x1fclose\x1fw1:p2' "$LOG" \
  || fail "candidate cleanup used an unconditional pane close after sampling the idle shell"
pass "fm-spawn relaunch: shell-aware cleanup preserves a close-boundary takeover"

reset_direct_meta
write_state "$DIRECT_WT" shell true
jq '.candidate_exists=true | .candidate_cwd=$cwd | .candidate_process="shell" | .candidate_registered=true' \
  --arg cwd "$DIRECT_WT" "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
write_direct_candidate_record created
DIRECT_OUT=$(PATH="$TMP_ROOT/fakebin:$PATH" FM_HOME="$DIRECT_HOME" FM_FAKE_HERDR_STATE="$STATE" \
  FM_FAKE_HERDR_LOG="$LOG" FM_HERDR_PS_BIN="$TMP_ROOT/fakebin/ps" FM_HERDR_KILL_BIN="$TMP_ROOT/fakebin/kill" \
  FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 FM_SPAWN_NO_GUARD=1 \
  "$ROOT/bin/fm-spawn.sh" direct --relaunch 2>&1) \
  || fail "retry should reconcile an exact stale registered candidate before relaunch: $DIRECT_OUT"
retire_line=$(grep -n $'\x1fpane\x1frun\x1fw1:p2\x1fkill -KILL "$$"' "$LOG" | head -1 | cut -d: -f1)
create_line=$(grep -n $'\x1ftab\x1fcreate\x1f' "$LOG" | head -1 | cut -d: -f1)
[ -n "$retire_line" ] && [ -n "$create_line" ] && [ "$retire_line" -lt "$create_line" ] \
  || fail "retry did not retire the stale exact candidate before creating its replacement: $(cat "$LOG")"
pass "fm-spawn relaunch: retry idempotently reconciles a stale exact candidate"

reset_direct_meta
write_state "$DIRECT_WT" shell true
jq '.candidate_exists=true | .candidate_cwd=$cwd | .candidate_process="live" | .candidate_registered=true' \
  --arg cwd "$DIRECT_WT" "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
write_direct_candidate_record quarantined
if DIRECT_OUT=$(PATH="$TMP_ROOT/fakebin:$PATH" FM_HOME="$DIRECT_HOME" FM_FAKE_HERDR_STATE="$STATE" \
    FM_FAKE_HERDR_LOG="$LOG" FM_HERDR_PS_BIN="$TMP_ROOT/fakebin/ps" FM_HERDR_KILL_BIN="$TMP_ROOT/fakebin/kill" \
    FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" direct --relaunch 2>&1); then
  fail "retry adopted a quarantined live candidate without launch provenance: $DIRECT_OUT"
fi
! grep -Fq $'\x1ftab\x1fcreate\x1f' "$LOG" \
  || fail "retry created a duplicate endpoint beside a quarantined live candidate"
[ "$(jq -r '.candidate_exists' "$STATE")" = true ] \
  || fail "retry removed a quarantined live candidate"
cmp -s "$DIRECT_HOME/state/direct.meta.original" "$DIRECT_HOME/state/direct.meta" \
  || fail "quarantined live-candidate refusal changed the authoritative binding"
pass "fm-spawn relaunch: retry refuses live candidates without launch provenance"

reset_direct_meta
write_state "$DIRECT_WT" shell true
jq '.candidate_takeover_before_run=true' "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
if DIRECT_OUT=$(PATH="$TMP_ROOT/fakebin:$PATH" FM_HOME="$DIRECT_HOME" FM_FAKE_HERDR_STATE="$STATE" \
    FM_FAKE_HERDR_LOG="$LOG" FM_HERDR_PS_BIN="$TMP_ROOT/fakebin/ps" FM_HERDR_KILL_BIN="$TMP_ROOT/fakebin/kill" \
    FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" direct --relaunch 2>&1); then
  fail "direct Herdr relaunch should refuse a takeover at the final delivery boundary: $DIRECT_OUT"
fi
[ "$(jq -r '.stop_calls' "$STATE")" -eq 0 ] \
  || fail "delivery-boundary refusal signaled a sampled OS process"
[ ! -e "$DIRECT_HOME/state/.relaunch-direct/launch/launch-receipt" ] \
  || fail "delivery-boundary takeover executed the replacement command"
pass "fm-spawn relaunch: exact-pane delivery refuses takeover without OS PID signaling"

reset_direct_meta
write_state "$DIRECT_WT" shell true
DIRECT_CONCURRENT_OUT="$TMP_ROOT/direct-concurrent.out"
PATH="$TMP_ROOT/fakebin:$PATH" FM_HOME="$DIRECT_HOME" FM_FAKE_HERDR_STATE="$STATE" \
  FM_FAKE_HERDR_LOG="$LOG" FM_HERDR_PS_BIN="$TMP_ROOT/fakebin/ps" FM_HERDR_KILL_BIN="$TMP_ROOT/fakebin/kill" \
  FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 FM_FAKE_HERDR_RUN_DELAY=0.5 FM_SPAWN_NO_GUARD=1 \
  "$ROOT/bin/fm-spawn.sh" direct --relaunch > "$DIRECT_CONCURRENT_OUT" 2>&1 &
direct_pid=$!
direct_started=0
for _ in {1..500}; do
  if grep -q $'\x1fpane\x1fsend-keys\x1f.*\x1fctrl+c' "$LOG"; then
    direct_started=1
    break
  fi
  sleep 0.01
done
[ "$direct_started" -eq 1 ] || fail "the direct relaunch did not reach endpoint preparation"
session_reads_before=$(grep -c $'\x1fsession\x1flist\x1f' "$LOG" || true)
run_backend fm_backend_prepare_relaunch_path herdr fmtest:w1:p1 "$DIRECT_WT" &
competitor_pid=$!
competitor_started=0
for _ in {1..500}; do
  session_reads=$(grep -c $'\x1fsession\x1flist\x1f' "$LOG" || true)
  if [ "$session_reads" -gt "$session_reads_before" ]; then
    competitor_started=1
    break
  fi
  sleep 0.01
done
[ "$competitor_started" -eq 1 ] || fail "the competing pane mutation did not reach the session lock"
sleep 0.05
clear_count=$(grep -c $'\x1fpane\x1fsend-keys\x1f.*\x1fctrl+c' "$LOG" || true)
[ "$clear_count" -eq 1 ] || fail "a competing pane mutation entered between relaunch preparation and command submission"
wait "$direct_pid" || fail "the serialized direct relaunch failed: $(cat "$DIRECT_CONCURRENT_OUT")"
if wait "$competitor_pid"; then
  fail "the competing path preparation mutated the original endpoint after publication"
fi
clear_count=$(grep -c $'\x1fpane\x1fsend-keys\x1f.*\x1fctrl+c' "$LOG" || true)
[ "$clear_count" -eq 2 ] || fail "the competing pane mutation reached the retired original endpoint"
pass "fm-spawn relaunch: session locking prevents mutation of the retired original endpoint"

[ "$(jq -r '.unmanaged_fingerprint' "$STATE")" = unchanged ] \
  || fail "replacement transaction mutated an unrelated unmanaged endpoint"
! grep -Fq $'\x1fworkspace\x1flist\x1f' "$LOG" \
  || fail "replacement transaction enumerated unrelated Herdr workspaces"
! grep -Eq 'w9(:p9)?' "$LOG" \
  || fail "replacement transaction addressed an unrelated unmanaged identity"
pass "fm-spawn relaunch: replacement stays exact-record scoped and ignores unmanaged workspaces"

reset_direct_meta
mkdir -p "$DIRECT_WT/.claude"
printf '%s\n' prior-claude-wiring > "$DIRECT_WT/.claude/settings.local.json"
rm -f "$DIRECT_HOME/state/direct.pi-ext.ts" "$DIRECT_HOME/state/direct.herdr-presentation"
bash -c '
  . "$0/bin/backends/herdr.sh"
  token=$(fm_backend_herdr_projection_journal_create "$1" direct) || exit 1
  label=$(fm_backend_herdr_projection_workspace_label direct "$token")
  fm_backend_herdr_projection_journal_bind \
    "$1/direct.herdr-presentation" direct "$2" fmtest \
    w1 w1:t1 w1:p1 w0 firstmate "$label" fm-direct
' "$ROOT" "$DIRECT_HOME/state" "$DIRECT_HOME" \
  || fail "could not seed the post-publication presentation binding"
write_state "$DIRECT_WT" shell true
PUBLISH_MARKER="$TMP_ROOT/publish-window.marker"
PUBLISH_RELEASE="$TMP_ROOT/publish-window.release"
PUBLISH_OUT="$TMP_ROOT/publish-window.out"
PATH="$TMP_ROOT/fakebin:$PATH" FM_HOME="$DIRECT_HOME" FM_FAKE_HERDR_STATE="$STATE" \
  FM_FAKE_HERDR_LOG="$LOG" FM_HERDR_PS_BIN="$TMP_ROOT/fakebin/ps" FM_HERDR_KILL_BIN="$TMP_ROOT/fakebin/kill" \
  FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 FM_SPAWN_NO_GUARD=1 \
  FM_FAKE_MV_PUBLISH_MARKER="$PUBLISH_MARKER" FM_FAKE_MV_PUBLISH_RELEASE="$PUBLISH_RELEASE" \
  FM_FAKE_MV_PUBLISH_TARGET="$DIRECT_HOME/state/direct.meta" \
  "$ROOT/bin/fm-spawn.sh" direct --relaunch --harness pi > "$PUBLISH_OUT" 2>&1 &
publish_pid=$!
for _ in {1..500}; do [ ! -e "$PUBLISH_MARKER" ] || break; sleep 0.01; done
[ -e "$PUBLISH_MARKER" ] || fail "publication crash simulation never committed candidate metadata"
jq '.candidate_process="shell" | .candidate_registered=false' "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
kill -TERM "$publish_pid" 2>/dev/null || fail "could not interrupt relaunch after metadata publication"
touch "$PUBLISH_RELEASE"
wait "$publish_pid" 2>/dev/null || true
[ "$(awk -F= '$1 == "herdr_pane_id" { print $2 }' "$DIRECT_HOME/state/direct.meta")" = w1:p2 ] \
  || fail "post-publication interruption rolled back authoritative metadata"
[ "$(awk -F= '$1 == "harness" { print $2 }' "$DIRECT_HOME/state/direct.meta")" = pi ] \
  || fail "post-publication interruption lost the replacement harness"
[ "$(jq -r '.candidate_exists' "$STATE")" = true ] \
  || fail "post-publication interruption closed the authoritative candidate"
grep -q '^pane_id=w1:p1$' "$DIRECT_HOME/state/direct.herdr-presentation" \
  || fail "post-publication interruption unexpectedly advanced the presentation binding"
DIRECT_OUT=$(PATH="$TMP_ROOT/fakebin:$PATH" FM_HOME="$DIRECT_HOME" FM_FAKE_HERDR_STATE="$STATE" \
  FM_FAKE_HERDR_LOG="$LOG" FM_HERDR_PS_BIN="$TMP_ROOT/fakebin/ps" FM_HERDR_KILL_BIN="$TMP_ROOT/fakebin/kill" \
  FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 FM_SPAWN_NO_GUARD=1 \
  "$ROOT/bin/fm-spawn.sh" direct --relaunch --harness pi 2>&1) \
  || fail "retry could not finish the interrupted binding commit: $DIRECT_OUT"
case "$DIRECT_OUT" in *"spawned direct "*) : ;; *) fail "post-publication recovery did not permit the next relaunch: $DIRECT_OUT" ;; esac
[ ! -e "$DIRECT_WT/.claude/settings.local.json" ] \
  || fail "post-publication recovery lost the original prior harness identity"
grep -q '^pane_id=w1:p2$' "$DIRECT_HOME/state/direct.herdr-presentation" \
  || fail "post-publication recovery left the presentation binding stale"
[ "$(jq -r '.recorded_exists' "$STATE")" = false ] \
  || fail "post-publication recovery abandoned the retained original endpoint"
pass "fm-spawn relaunch: post-publication retry reconciles presentation and retained endpoint"
rm -f "$DIRECT_HOME/state/direct.pi-ext.ts" "$DIRECT_HOME/state/direct.herdr-presentation"

reset_direct_meta
write_state "$DIRECT_WT" shell true
jq '.take_over_after_pane_get=2' "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
if DIRECT_OUT=$(PATH="$TMP_ROOT/fakebin:$PATH" FM_HOME="$DIRECT_HOME" FM_FAKE_HERDR_STATE="$STATE" \
    FM_FAKE_HERDR_LOG="$LOG" FM_HERDR_PS_BIN="$TMP_ROOT/fakebin/ps" FM_HERDR_KILL_BIN="$TMP_ROOT/fakebin/kill" \
    FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" direct --relaunch 2>&1); then
  fail "replacement creation should refuse when the old endpoint becomes live under its session lock: $DIRECT_OUT"
fi
! grep -Fq $'\x1ftab\x1fcreate\x1f' "$LOG" \
  || fail "replacement creation proceeded after the old endpoint became live"
cmp -s "$DIRECT_HOME/state/direct.meta.original" "$DIRECT_HOME/state/direct.meta" \
  || fail "live-agent boundary refusal changed the authoritative endpoint binding"
case "$DIRECT_OUT" in *"no longer proves agent-free under the session mutation lock"*) : ;; *) fail "live-agent boundary refusal was not explicit: $DIRECT_OUT" ;; esac
pass "fm-spawn relaunch: a real-live old endpoint is rechecked under the mutation lock"

reset_direct_meta
awk '/^herdr_workspace_id=/{print "herdr_workspace_id=w9"; next} {print}' \
  "$DIRECT_HOME/state/direct.meta" > "$DIRECT_HOME/state/direct.meta.tmp"
mv "$DIRECT_HOME/state/direct.meta.tmp" "$DIRECT_HOME/state/direct.meta"
write_state "$DIRECT_WT" shell true
if DIRECT_OUT=$(PATH="$TMP_ROOT/fakebin:$PATH" FM_HOME="$DIRECT_HOME" FM_FAKE_HERDR_STATE="$STATE" \
    FM_FAKE_HERDR_LOG="$LOG" FM_HERDR_PS_BIN="$TMP_ROOT/fakebin/ps" FM_HERDR_KILL_BIN="$TMP_ROOT/fakebin/kill" \
    FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" direct --relaunch 2>&1); then
  fail "replacement creation should refuse a contradictory recorded workspace relation: $DIRECT_OUT"
fi
! grep -Fq $'\x1ftab\x1fcreate\x1f' "$LOG" \
  || fail "contradictory workspace metadata created a replacement endpoint"
[ "$(jq -r '.unmanaged_fingerprint' "$STATE")" = unchanged ] \
  || fail "contradictory workspace metadata mutated the unrelated workspace"
case "$DIRECT_OUT" in *"does not match its exact workspace and tab"*) : ;; *) fail "contradictory workspace refusal was not explicit: $DIRECT_OUT" ;; esac
pass "fm-spawn relaunch: contradictory endpoint relations refuse before workspace mutation"

reset_direct_meta
awk -v wt="$DIRECT_PROJECT" '/^worktree=/{print "worktree=" wt; next} {print}' \
  "$DIRECT_HOME/state/direct.meta" > "$DIRECT_HOME/state/direct.meta.tmp"
mv "$DIRECT_HOME/state/direct.meta.tmp" "$DIRECT_HOME/state/direct.meta"
INVALID_PENDING="touch '$TMP_ROOT/invalid-primary-marker'; "
write_state "$DIRECT_PROJECT" shell true
jq --arg pending "$INVALID_PENDING" '.pending=$pending' "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
if DIRECT_OUT=$(PATH="$TMP_ROOT/fakebin:$PATH" FM_HOME="$DIRECT_HOME" FM_FAKE_HERDR_STATE="$STATE" \
    FM_FAKE_HERDR_LOG="$LOG" FM_HERDR_PS_BIN="$TMP_ROOT/fakebin/ps" FM_HERDR_KILL_BIN="$TMP_ROOT/fakebin/kill" \
    FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" direct --relaunch 2>&1); then
  fail "direct Herdr relaunch should reject the primary checkout: $DIRECT_OUT"
fi
[ "$(jq -r '.pending' "$STATE")" = "$INVALID_PENDING" ] || fail "invalid-worktree relaunch sent input before refusing"
! awk -F '\x1f' '$2 == "pane" && ($3 == "send-text" || $3 == "send-keys" || $3 == "run") {found=1} END {exit !found}' "$LOG" \
  || fail "invalid-worktree relaunch issued a pane input command"
pass "fm-spawn relaunch: invalid recorded worktrees refuse before pane input"

write_state "$OLD" live true
if run_backend fm_backend_prepare_relaunch_path herdr fmtest:w1:p1 "$TARGET" >/dev/null 2>&1; then
  fail "path restoration must refuse while a real foreground agent remains"
fi
! grep -q $'\x1fpane\x1fsend-text\x1f' "$LOG" || fail "live-agent refusal typed a shell command"
pass "Herdr relaunch recovery: live-agent refusal sends no path-changing input"

write_state "$OLD" ambiguous true
if run_backend fm_backend_prepare_relaunch_path herdr fmtest:w1:p1 "$TARGET" >/dev/null 2>&1; then
  fail "path restoration must refuse ambiguous endpoint evidence"
fi
! grep -q $'\x1fpane\x1fsend-text\x1f' "$LOG" || fail "ambiguous-state refusal typed a shell command"
pass "Herdr relaunch recovery: ambiguous-state refusal sends no path-changing input"

run_backend fm_backend_prepare_relaunch_path tmux ignored "$TARGET" \
  || fail "tmux relaunch path preparation should retain its existing no-op behavior"
if run_backend fm_backend_prepare_relaunch_path zellij ignored "$TARGET" >/dev/null 2>&1; then
  fail "a backend without verified lifecycle recovery must not gain path-changing behavior"
fi
pass "Relaunch path recovery: tmux remains unchanged and unverified backends refuse"
