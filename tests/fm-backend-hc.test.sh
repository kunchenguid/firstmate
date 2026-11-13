#!/usr/bin/env bash
# tests/fm-backend-hc.test.sh - fake-hc-CLI unit tests for the herdr-core
# session-provider adapter (bin/backends/hc.sh) and its dispatcher arms in
# bin/fm-backend.sh. tests/fm-backend-hc-smoke.test.sh drives a real isolated
# hc core; this suite pins selection, identity, keys, liveness, and close
# behavior with a stub so it runs everywhere.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-backend-hc-tests)

# The stub answers `get` from <dir>/<address>.json (exit from <address>.exit,
# 3 = not_found when no file exists), `ls` from <dir>/ls.json, `run` with
# <dir>/run.json, and removes <address>.json on `rm` unless <dir>/rm-sticks
# exists. `server status` reports core FAKE_HC_CORE (default core-a). Every
# call is logged with its HC_SESSION and HC_SOCKET.
#
# With <dir>/lifecycle present the stub also models a worker's life in the
# terminal it is sent to, through its own <address>.json: `cd -- '<dir>'` moves
# the foreground cwd, `/exit` replaces a claude foreground with the shell whose
# pid is in <dir>/shell.pid (unless <dir>/exit-ignored exists), and a launch
# line makes claude the foreground and is logged to <dir>/launched. `read`
# prints <dir>/screen when it exists, and `run` also creates the returned
# terminal from <dir>/run-creates.json, carrying the labels it was given, when
# that exists.
make_hc_fakebin() {  # <dir> -> echoes fakebin dir
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/hc" <<'SH'
#!/usr/bin/env bash
set -u
D="${FAKE_HC_DIR:?}"
{
  printf 'HC_SESSION=%s HC_SOCKET=%s' "${HC_SESSION:-}" "${HC_SOCKET:-}"
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$D/log"
cmd=${1:-}
last=""
for a in "$@"; do last=$a; done
case "$cmd" in
  --version) printf 'hc %s\n' "${FAKE_HC_VERSION:-0.1.14}" ;;
  server) printf '{"live":0,"core":{"id":"%s"}}\n' "${FAKE_HC_CORE:-core-a}" ;;
  connect)
    IFS= read -r _req || true
    printf '{"jsonrpc":"2.0","id":1,"result":{"generation":%s}}\n' "${FAKE_HC_GENERATION:-1}"
    ;;
  ls) cat "$D/ls.json" 2>/dev/null || printf '{"terminals":[]}\n' ;;
  run)
    cat "$D/run.json"
    if [ -f "$D/run-creates.json" ]; then
      labels='{}'
      while [ $# -gt 0 ]; do
        if [ "$1" = --label ]; then
          labels=$(jq -c --arg kv "${2:-}" '. + {($kv | split("=")[0]): ($kv | split("=")[1:] | join("="))}' <<<"$labels")
          shift
        fi
        shift
      done
      jq --argjson l "$labels" --arg a "$(jq -r .address "$D/run.json")" '.labels = $l | .address = $a' \
        "$D/run-creates.json" > "$D/$(jq -r .address "$D/run.json").json"
    fi
    ;;
  get)
    [ -f "$D/$last.exit" ] && exit "$(cat "$D/$last.exit")"
    [ -f "$D/$last.json" ] || { printf '{"error":{"kind":"not_found"}}\n' >&2; exit 3; }
    cat "$D/$last.json"
    ;;
  rm) [ -e "$D/rm-sticks" ] || rm -f "$D/$last.json"; printf '{}\n' ;;
  read)
    if [ -f "$D/screen" ]; then cat "$D/screen"; else printf 'screen of %s\n' "$last"; fi
    ;;
  send)
    if [ -f "$D/send.exit" ]; then
      printf '{"error":{"kind":"%s"}}\n' "$(cat "$D/send.kind" 2>/dev/null || echo blocked)" >&2
      exit "$(cat "$D/send.exit")"
    fi
    f="$D/${3:-}.json"
    if [ -f "$D/lifecycle" ] && [ -f "$f" ]; then
      # fm-spawn stages a long launch line in a script and sends `. '<file>'`.
      case "$last" in
        ". '"*"'") staged=${last#". '"}; staged=${staged%"'"}; [ ! -f "$staged" ] || last=$(cat "$staged") ;;
      esac
      case "$last" in
        "cd -- '"*"'")
          dir=${last#"cd -- '"}
          jq --arg d "${dir%"'"}" '.foreground.cwd = $d' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
          ;;
        /exit)
          [ -e "$D/exit-ignored" ] || jq --argjson p "$(cat "$D/shell.pid")" \
            '.foreground = {name: "bash", argv: ["bash"], cwd: .foreground.cwd, pid: $p}' "$f" > "$f.tmp" \
            && mv "$f.tmp" "$f"
          ;;
        *'Firstmate operational input waiting: read'*|*'encode launch-brief'*)
          printf '%s\n' "${3:-}" >> "$D/launched"
          jq '.foreground = {name: "claude", argv: ["claude"], cwd: .foreground.cwd, pid: .foreground.pid}' "$f" > "$f.tmp" \
            && mv "$f.tmp" "$f"
          ;;
      esac
    fi
    cat "$D/send.json" 2>/dev/null || printf '{"started":true,"wait":{"status":"working"}}\n'
    ;;
  *) printf '{}\n' ;;
esac
SH
  chmod +x "$fb/hc"
  printf '%s\n' "$fb"
}

# Each case runs in its own shell with a fresh stub directory and home.
setup_case() {  # <name> -> sets D, FB, HOMEDIR
  D="$TMP_ROOT/$1"
  mkdir -p "$D"
  FB=$(make_hc_fakebin "$D")
  HOMEDIR="$D/home"
  mkdir -p "$HOMEDIR"
}

# hc_shell <script>: run <script> in bash with the adapter sourced against the
# stub. FM_HC_BIN pins the stub so an inherited FM_HC_BIN or an installed
# herdr-core never wins; CASE_HC_BIN overrides it for binary-resolution cases.
# HOMETAG is exported so the script can build matching labels.
hc_shell() {  # <script>
  FAKE_HC_DIR=$D PATH="$FB:$PATH" FM_HC_BIN=${CASE_HC_BIN:-$FB/hc} \
    FM_HOME=$HOMEDIR FM_ROOT_OVERRIDE=$HOMEDIR \
    HC_SESSION=fmtest bash -c '
      . "'"$FM_TEST_ROOT"'/bin/fm-backend.sh"
      fm_backend_source hc || { echo "source failed" >&2; exit 90; }
      HOMETAG=$(fm_backend_hometag)
      '"$1"
}

# write_terminal <dir> <address> <state> <task-label> <home> <fg-name> <fg-argv0> [fg-pid] [root-pid]
# The foreground pid defaults to 1 and the root pid is absent, so a terminal
# written without real pids can never be proven agent-free.
write_terminal() {
  jq -n --arg a "$2" --arg s "$3" --arg t "$4" --arg h "$5" --arg n "$6" --arg v "$7" \
    --arg p "${8:-1}" --arg r "${9:-}" '
    {address: $a, state: $s, labels: {"firstmate.task": $t, "firstmate.home": $h},
     cwd: "/start", foreground: (if $n == "" then null else {name: $n, argv: [$v], cwd: "/live", pid: ($p | tonumber)} end)}
    + (if $r == "" then {} else {pid: ($r | tonumber)} end)' \
    > "$1/$2.json"
}

# Real process trees for the classifier, built from scripts so each process's
# command line is exactly what the shared classifier reads. Every tree runs in
# its own process group and blocks reading a fifo nothing writes, so it holds
# still until stop_trees kills it. idle.sh is a bare shell that writes its own
# pid to <pidfile>; agent.sh is that shell started under argv[0] `claude`.
TREE_PGIDS=()
# shellcheck disable=SC2016 # the scripts expand their own variables
write_tree_scripts() {  # <dir>
  mkfifo "$1/fifo"
  printf '%s\n' 'echo $$ > "$1"' 'read -r _ < "$2"' > "$1/idle.sh"
  # A harness that hands the terminal to a nested interactive shell: the shell
  # runs in its own group, and the harness waits on it.
  printf '%s\n' 'set -m' 'bash "${0%/*}/idle.sh" "$@" &' 'wait' > "$1/agent.sh"
}

# start_tree <dir> <name> <script>: start `bash -c <script>` in its own
# process group with <dir>/<name>.pid as $1 and the fifo as $2, wait for the
# pid file, and set TREE_LEADER to the group leader's pid. It runs in the
# caller's shell, never a command substitution, so the tree holds no pipe the
# caller waits on and stop_trees sees every group it started.
start_tree() {  # <dir> <name> <script>
  local dir=$1 name=$2
  set -m
  bash -c "$3" _ "$dir/$name.pid" "$dir/fifo" </dev/null >/dev/null 2>&1 &
  TREE_LEADER=$!
  set +m
  TREE_PGIDS+=("$TREE_LEADER")
  for _ in $(seq 1 50); do [ -s "$dir/$name.pid" ] && break; sleep 0.1; done
  [ -s "$dir/$name.pid" ] || { stop_trees; fail "process tree $name did not start"; }
}

stop_trees() {
  local g
  for g in "${TREE_PGIDS[@]:-}"; do
    [ -n "$g" ] || continue
    kill -- "-$g" 2>/dev/null || true
    wait "$g" 2>/dev/null || true
  done
  TREE_PGIDS=()
}

hometag_of() {
  FM_HOME=$HOMEDIR FM_ROOT_OVERRIDE=$HOMEDIR bash -c '. "'"$FM_TEST_ROOT"'/bin/fm-backend.sh"; fm_backend_source hc; fm_backend_hometag'
}

# expect_refused <cmd...>: the command must exit nonzero.
expect_refused() {
  local rc=0
  "$@" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "expected a refusal from: ${*: -1}"
}

FM_TEST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

test_hc_is_spawn_capable_and_needs_app_signals() {
  local out
  # HC_TERMINAL_ID alone is never a selection: it reaches every process an hc
  # terminal starts. This env lacks the app-terminal claim defined in
  # docs/hc-backend.md "Runtime auto-detection"; an open window is irrelevant.
  out=$(bash -c '. "'"$FM_TEST_ROOT"'/bin/fm-backend.sh"
    fm_backend_validate_spawn hc && echo spawn-ok
    unset TMUX HERDR_ENV CMUX_WORKSPACE_ID TERM_PROGRAM REX_BLOCK __CFBundleIdentifier HC_TERMINAL_SOCKET
    HC_TERMINAL_ID=t7 HC_SESSION=x HERDR_APP_HOME="'"$TMP_ROOT"'/no-app-home" fm_backend_detect >/dev/null && echo detected || echo not-detected
    fm_backend_required_tools hc' 2>&1)
  assert_contains "$out" spawn-ok "hc must be spawn-capable"
  assert_contains "$out" not-detected "bare HC_TERMINAL_* markers without an app signal must not select hc"
  assert_contains "$out" "hc jq treehouse" "hc needs hc, jq and treehouse"
  pass "hc: spawn-capable, detects only on the Herdr app signals, with its tool set"
}

test_create_task_is_independent_labeled_and_refuses_duplicates() {
  local out tag
  setup_case create
  printf '{"address":"t9"}\n' > "$D/run.json"
  out=$(hc_shell 'fm_backend_hc_create_task fmtest fm-a1 /proj')
  assert_equals "$out" t9 "create_task prints the new address"
  tag=$(hometag_of)
  out=$(grep $'\x1frun\x1f' "$D/log")
  for want in HC_SESSION=fmtest --no-parent --outlive-parent --no-notify $'--cwd\x1f/proj' \
    "firstmate.task=fm-a1" "firstmate.home=$tag" "herdr.space=fm-$tag" "herdr.tab=$tag-fm-a1"; do
    assert_contains "$out" "$want" "hc run must carry $want"
  done
  printf '{"terminals":[{"address":"t9"}]}\n' > "$D/ls.json"
  : > "$D/log"
  expect_refused hc_shell 'fm_backend_hc_create_task fmtest fm-a1 /proj'
  assert_not_contains "$(cat "$D/log")" $'\x1frun\x1f' "a live duplicate must not start a second terminal"
  pass "hc: create_task starts an independent labeled terminal and refuses a duplicate"
}

test_control_interrupt_delivers_the_harness_keys() {
  local tag out rc=0 id=hcint1
  setup_case interrupt
  tag=$(hometag_of)
  write_terminal "$D" t2 live "fm-$id" "$tag" 2.1.312 claude
  mkdir -p "$HOMEDIR/state" "$HOMEDIR/data"
  printf 'window=fmtest:t2\nendpoint_task_id=%s\nworktree=%s\nproject=%s\nharness=claude\nkind=scout\nbackend=hc\nhc_session=fmtest\nhc_terminal=t2\n' \
    "$id" "$D" "$D" > "$HOMEDIR/state/$id.meta"
  out=$(FAKE_HC_DIR=$D PATH="$FB:$PATH" FM_HC_BIN="$FB/hc" FM_HOME=$HOMEDIR FM_ROOT_OVERRIDE=$HOMEDIR \
    FM_STATE_OVERRIDE="$HOMEDIR/state" FM_DATA_OVERRIDE="$HOMEDIR/data" FM_CONTROL_POLL=0.05 \
    "$FM_TEST_ROOT/bin/fm-control.sh" "$id" interrupt 2>&1) || rc=$?
  expect_code 0 "$rc" "interrupt on an hc task should succeed"$'\n'"$out"
  assert_contains "$(grep $'\x1fkeys\x1f' "$D/log")" $'keys\x1f--json\x1ft2\x1f--\x1fesc' "interrupt must press Escape on the recorded terminal"
  pass "hc: fm-control interrupt delivers the harness's interrupt key"
}

test_foreign_or_unlabeled_terminal_gets_no_input_and_no_close() {
  local tag
  setup_case foreign
  tag=$(hometag_of)
  write_terminal "$D" t3 live fm-other "$tag" zsh /bin/zsh
  write_terminal "$D" t4 live fm-a1 other-home zsh /bin/zsh
  write_terminal "$D" t5 live "" "" zsh /bin/zsh
  expect_refused hc_shell 'fm_backend_send_key hc fmtest:t3 Enter fm-a1'
  expect_refused hc_shell 'fm_backend_send_key hc fmtest:t4 Enter fm-a1'
  expect_refused hc_shell 'fm_backend_kill hc fmtest:t5'
  expect_refused hc_shell 'fm_backend_kill hc fmtest:t4'
  assert_not_contains "$(cat "$D/log")" $'\x1fkeys\x1f' "no key may reach a foreign terminal"
  assert_not_contains "$(cat "$D/log")" $'\x1fkill\x1f' "no foreign terminal may be closed"
  pass "hc: another task's, another home's, or an unlabeled terminal gets no input and no close"
}

test_invalid_session_never_reaches_hc() {
  setup_case session
  expect_refused hc_shell 'fm_backend_hc_cli "" ls'
  expect_refused hc_shell 'fm_backend_send_key hc :t2 Enter'
  assert_equals "$(cat "$D/log" 2>/dev/null)" "" "an empty or malformed session must not call hc"
  pass "hc: an empty session never falls through to the ambient core"
}

# hc 0.1.14 lets an exported HC_SOCKET win over HC_SESSION, so an inherited one
# would send every call to another core.
test_inherited_socket_never_overrides_the_session() {
  setup_case socket
  HC_SOCKET=/elsewhere/other.sock hc_shell 'fm_backend_hc_cli fmtest ls' >/dev/null
  assert_contains "$(cat "$D/log")" "HC_SESSION=fmtest HC_SOCKET="$'\x1f'"ls" "hc must run with HC_SOCKET unset"
  pass "hc: an inherited HC_SOCKET never overrides the session pin"
}

test_agent_state_classifies_foreground_and_absence() {
  local tag out
  setup_case state
  tag=$(hometag_of)
  write_terminal "$D" t1 live fm-a1 "$tag" 2.1.312 claude
  write_terminal "$D" t2 live fm-a1 "$tag" zsh /bin/zsh
  write_terminal "$D" t3 finished fm-a1 "$tag" "" ""
  write_terminal "$D" t4 live fm-a1 "$tag" node node
  write_terminal "$D" t5 live fm-a1 "$tag" "" ""
  printf '1\n' > "$D/t6.exit"
  # shellcheck disable=SC2016 # the inner shell expands it
  out=$(hc_shell 'for a in t1 t2 t3 t4 t5 t6 t7; do printf "%s=%s " $a "$(fm_backend_agent_state hc fmtest:$a)"; done')
  assert_equals "$out" "t1=alive t2=unreadable t3=missing t4=unreadable t5=unreadable t6=unreadable t7=missing " \
    "agent_state over claude, a shell and a non-shell hc names under no terminal root, finished, no foreground, core error, not found"
  pass "hc: agent_state maps foreground, finished, not_found and core errors onto the shared vocabulary"
}

test_agent_state_reads_a_shell_wrappers_group() {
  local tag out wrapper
  setup_case wrapper
  tag=$(hometag_of)
  # A shell wrapper in its own process group, waiting on a harness child.
  set -m
  bash -c '(exec -a claude sleep 30); :' &
  wrapper=$!
  set +m
  write_terminal "$D" t9 live fm-a1 "$tag" bash bash
  jq --argjson p "$wrapper" '.foreground.pid = $p | .pid = $p' "$D/t9.json" > "$D/t9.tmp" && mv "$D/t9.tmp" "$D/t9.json"
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -g "$wrapper" -f '^claude' >/dev/null && break; sleep 0.1; done
  out=$(hc_shell 'fm_backend_agent_state hc fmtest:t9')
  kill -- "-$wrapper" 2>/dev/null || true
  wait "$wrapper" 2>/dev/null || true
  assert_equals "$out" alive "a shell wrapper running a harness child is alive"
  pass "hc: agent_state reads a shell wrapper's process group before calling it dead"
}

# The trees an hc terminal really holds, with the foreground hc would name
# (measured on hc 0.1.20: the terminal's foreground process group leader) and
# its root program. Only the bare shell may read dead.
test_agent_state_reads_the_whole_terminal_before_calling_it_dead() {
  local tag out idle bg nested fgnested busy shape
  setup_case tree
  tag=$(hometag_of)
  write_tree_scripts "$D"
  # A bare login shell after a restart: root and foreground are one shell.
  start_tree "$D" idle 'exec bash "'"$D"'/idle.sh" "$@"'
  idle=$TREE_LEADER
  write_terminal "$D" t1 live fm-a1 "$tag" bash bash "$idle" "$idle"
  # A harness started from that shell as a background job: hc still names the
  # shell, and the harness is in another process group.
  start_tree "$D" bg 'set -m; (exec -a claude sleep 300) & exec bash "'"$D"'/idle.sh" "$@"'
  bg=$TREE_LEADER
  write_terminal "$D" t2 live fm-a1 "$tag" bash bash "$bg" "$bg"
  # A harness that handed the terminal to a nested shell: hc names the nested
  # shell, alone in its group, and the harness is its parent.
  start_tree "$D" nested 'exec -a claude bash "'"$D"'/agent.sh" "$@"'
  nested=$TREE_LEADER
  fgnested=$(cat "$D/nested.pid")
  write_terminal "$D" t3 live fm-a1 "$tag" bash bash "$fgnested" "$nested"
  # A shell running a non-shell, non-harness command in its own group.
  # shellcheck disable=SC2016 # the tree's shell expands it
  start_tree "$D" busy 'echo $$ > "$1"; sleep 300; :'
  busy=$TREE_LEADER
  write_terminal "$D" t4 live fm-a1 "$tag" bash bash "$busy" "$busy"
  # A pid that is not inside the terminal hc reports it for.
  write_terminal "$D" t5 live fm-a1 "$tag" bash bash "$idle" "$bg"
  for _ in $(seq 1 50); do
    pgrep -P "$bg" -f '^claude' >/dev/null && pgrep -g "$busy" sleep >/dev/null && break
    sleep 0.1
  done
  # The nested case must really separate the two sources: hc's pid is not the
  # harness and is not in the harness's process group.
  shape="$(ps -o pgid= -p "$fgnested" | tr -d ' ') $(ps -o pgid= -p "$nested" | tr -d ' ')"
  # shellcheck disable=SC2016 # the inner shell expands it
  out=$(hc_shell 'for a in t1 t2 t3 t4 t5; do printf "%s=%s " $a "$(fm_backend_agent_state hc fmtest:$a)"; done')
  stop_trees
  [ "$fgnested" != "$nested" ] && [ "${shape% *}" != "${shape#* }" ] \
    || fail "the nested shell must be its own process in its own group (pgids: $shape)"
  assert_equals "$out" "t1=dead t2=alive t3=alive t4=ambiguous t5=unreadable " \
    "agent_state over a bare shell, a background harness, a nested shell under a harness, a busy shell, and a foreign pid"
  pass "hc: agent_state reads the terminal's whole tree, so only a bare shell is dead"
}

# A process table that cannot be read proves nothing, even for a bare shell.
test_agent_state_without_a_process_table_is_unreadable() {
  local tag out idle
  setup_case noprocs
  tag=$(hometag_of)
  write_tree_scripts "$D"
  start_tree "$D" idle 'exec bash "'"$D"'/idle.sh" "$@"'
  idle=$TREE_LEADER
  write_terminal "$D" t1 live fm-a1 "$tag" bash bash "$idle" "$idle"
  mkdir -p "$D/noprocs"
  printf '#!/bin/sh\nexit 1\n' > "$D/noprocs/ps"
  chmod +x "$D/noprocs/ps"
  # shellcheck disable=SC2016 # the inner shell expands it
  out=$(hc_shell 'printf "%s " "$(fm_backend_agent_state hc fmtest:t1)"; PATH="'"$D"'/noprocs:$PATH" fm_backend_agent_state hc fmtest:t1')
  stop_trees
  assert_equals "$out" "dead unreadable" "a bare shell is dead only while the process table can be read"
  pass "hc: agent_state never reads dead without the process table"
}

# --- relaunch on hc ---------------------------------------------------------
#
# fm-control.sh relaunch and fm-spawn.sh --relaunch driven end to end against
# the stub in lifecycle mode. The terminal's shell is a real bare shell, so the
# dead verdict that licenses adoption comes from the real classifier.

# hc_relaunch_case <name> <id> <fg: shell|claude>: a ship task on terminal
# fmtest:t2 recorded on core core-a, whose worktree is a real git worktree.
# Sets D, FB, HOMEDIR, WT, and TREE_LEADER (the bare shell).
hc_relaunch_case() {  # <name> <id> <fg>
  local id=$2 tag proj
  setup_case "$1"
  tag=$(hc_lifecycle_hometag)
  proj="$D/proj"
  WT="$D/wt"
  fm_git_worktree "$proj" "$WT" "task-$id" >/dev/null 2>&1 || fail "could not create the task worktree"
  write_tree_scripts "$D"
  start_tree "$D" shell 'exec bash "'"$D"'/idle.sh" "$@"'
  if [ "$3" = claude ]; then
    write_terminal "$D" t2 live "fm-$id" "$tag" claude claude "$TREE_LEADER" "$TREE_LEADER"
  else
    write_terminal "$D" t2 live "fm-$id" "$tag" bash bash "$TREE_LEADER" "$TREE_LEADER"
  fi
  # The previous worker ran in its worktree, as a restored hc shell still is.
  jq --arg d "$WT" '.foreground.cwd = $d' "$D/t2.json" > "$D/t2.tmp" && mv "$D/t2.tmp" "$D/t2.json"
  : > "$D/lifecycle"
  printf '%s\n' '────────' '❯ ' '────────' > "$D/screen"
  mkdir -p "$HOMEDIR/state" "$HOMEDIR/data/$id"
  printf '%s\n' '# Task' "## Captain's intent" "Exercise an hc relaunch for $id." '' \
    '## Firstmate spec' 'Replace the agent in its own terminal.' > "$HOMEDIR/data/$id/brief.md"
  {
    echo "window=fmtest:t2"
    echo "endpoint_task_id=$id"
    echo "worktree=$WT"
    echo "project=$proj"
    echo "harness=claude"
    echo "kind=ship"
    echo "mode=local-only"
    echo "yolo=off"
    echo "branch=task-$id"
    echo "tasktmp=$D/tasktmp"
    echo "model=default"
    echo "effort=default"
    echo "backend=hc"
    echo "hc_session=fmtest"
    echo "hc_terminal=t2"
    echo "hc_home=$tag"
    echo "hc_core=core-a"
  } > "$HOMEDIR/state/$id.meta"
}

# The home tag a lifecycle script computes for HOMEDIR: its root is the code
# root, not the FM_ROOT_OVERRIDE hc_shell pins.
hc_lifecycle_hometag() {
  FM_HOME=$HOMEDIR bash -c '. "'"$FM_TEST_ROOT"'/bin/fm-backend.sh"; fm_backend_source hc; fm_backend_hometag'
}

# hc_lifecycle <script> <args...>: run a lifecycle script against the stub
# from a seat outside any hc terminal, with a throwaway HOME so a claude
# launch never writes the developer's own trust store.
hc_lifecycle() {  # <script> <args...>
  local script=$1
  shift
  mkdir -p "$D/user-home"
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION -u HERDR_SOCKET_PATH -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
    -u HC_TERMINAL_ID -u HC_TERMINAL_SOCKET -u HC_SCOPE -u HC_SOCKET -u FM_HC_SOCKET \
    FAKE_HC_DIR="$D" PATH="$FB:$PATH" FM_HC_BIN="$FB/hc" FM_HERDR_APP_BIN="$FB/herdr-app" \
    FM_CREW_STATE_BIN="$FB/crew-state" HC_SESSION=fmtest \
    FM_HOME="$HOMEDIR" HOME="$D/user-home" CLAUDE_CONFIG_DIR='' FM_SPAWN_NO_GUARD=1 \
    FM_CONTROL_POLL=0.05 FM_CONTROL_EXIT_WAIT=1 FM_CONTROL_LAUNCH_WAIT=2 \
    "$FM_TEST_ROOT/bin/$script" "$@" 2>&1
}

hc_meta_field() {  # <id> <key>
  grep "^$2=" "$HOMEDIR/state/$1.meta" | tail -1 | cut -d= -f2-
}

# A launch stages its scripts under /tmp/fm-<id>[+<hash>]; the relaunch ids
# here are unique to this suite.
hc_relaunch_cleanup() {  # <id>
  local d
  stop_trees
  for d in "/tmp/fm-$1" "/tmp/fm-$1+"*; do
    [ ! -e "$d" ] || fm_test_remove_tree "$d"
  done
}

test_relaunch_adopts_a_terminal_whose_agent_died() {
  local out rc=0 id=hcrl1
  hc_relaunch_case rl-dead "$id" shell
  out=$(hc_lifecycle fm-control.sh "$id" relaunch --note "the machine restarted") || rc=$?
  hc_relaunch_cleanup "$id"
  expect_code 0 "$rc" "relaunch of an hc task whose terminal holds a bare shell should succeed"$'\n'"$out"
  assert_contains "$out" "relaunched $id harness=claude" "the outcome should name the relaunch"
  assert_equals "$(hc_meta_field "$id" window) $(hc_meta_field "$id" hc_terminal) $(hc_meta_field "$id" hc_core)" \
    "fmtest:t2 t2 core-a" "the recorded terminal and its core must be kept"
  assert_equals "$(hc_meta_field "$id" hc_home)" "$(hc_lifecycle_hometag)" "the recorded home tag must be kept"
  assert_equals "$(cat "$D/launched" 2>/dev/null)" t2 "the replacement must launch once, in the recorded terminal"
  assert_contains "$(cat "$D/log")" $'send\x1f--json\x1ft2\x1f--\x1fcd -- \''"$WT" "the replacement must enter the recorded worktree"
  assert_not_contains "$(cat "$D/log")" $'\x1frun\x1f' "an adopted terminal must not be re-created"
  assert_not_contains "$(cat "$D/log")" $'\x1f/exit' "a dead agent needs no exit command"
  pass "hc: fm-control relaunch adopts a terminal whose agent died and relaunches into it"
}

test_relaunch_stops_a_live_agent_before_replacing_it() {
  local out rc=0 id=hcrl2
  hc_relaunch_case rl-live "$id" claude
  out=$(hc_lifecycle fm-control.sh "$id" relaunch --note "replace the worker") || rc=$?
  hc_relaunch_cleanup "$id"
  expect_code 0 "$rc" "relaunch of a live hc agent that exits should succeed"$'\n'"$out"
  assert_contains "$(cat "$D/log")" $'send\x1f--json\x1ft2\x1f--wait' "the exit command must be submitted to the recorded terminal"
  assert_contains "$(cat "$D/log")" $'\x1f/exit' "the live agent must be sent its exit command"
  assert_equals "$(cat "$D/launched" 2>/dev/null)" t2 "the replacement must launch once, after the stop"
  pass "hc: fm-control relaunch stops a live agent, proves it gone, then relaunches"
}

test_relaunch_refuses_while_the_agent_is_alive() {
  local out rc=0 id=hcrl3 before
  hc_relaunch_case rl-stays "$id" claude
  : > "$D/exit-ignored"
  before=$(cat "$HOMEDIR/state/$id.meta")
  out=$(hc_lifecycle fm-control.sh "$id" relaunch --note "replace the worker") || rc=$?
  [ "$rc" -ne 0 ] || { hc_relaunch_cleanup "$id"; fail "a relaunch must refuse while the agent is still alive"$'\n'"$out"; }
  assert_contains "$out" "did not stop" "the refusal should say the agent did not stop"
  rc=0
  out=$(hc_lifecycle fm-spawn.sh "$id" --relaunch) || rc=$?
  hc_relaunch_cleanup "$id"
  [ "$rc" -ne 0 ] || fail "fm-spawn --relaunch must refuse a live agent"$'\n'"$out"
  assert_contains "$out" "positively agent-free" "fm-spawn's refusal should name the live endpoint"
  [ ! -e "$D/launched" ] || fail "no replacement may launch beside a live agent"
  assert_equals "$(cat "$HOMEDIR/state/$id.meta")" "$before" "a refused relaunch must leave the record as it was"
  pass "hc: relaunch refuses while the agent is alive and launches nothing"
}

test_relaunch_rebinds_only_a_terminal_proven_gone() {
  local out rc=0 id=hcrl4 tag
  hc_relaunch_case rl-gone "$id" shell
  tag=$(hc_lifecycle_hometag)
  rm -f "$D/t2.json"
  printf '{"address":"t5"}\n' > "$D/run.json"
  write_terminal "$D" t5 live "fm-$id" "$tag" bash bash "$TREE_LEADER" "$TREE_LEADER"
  # hc run --cwd starts the new terminal's shell in the worktree.
  jq --arg d "$WT" '.foreground.cwd = $d' "$D/t5.json" > "$D/run-creates.json" && rm -f "$D/t5.json"
  # The record names another core than the one answering the session now.
  sed -i.bak 's/^hc_core=.*/hc_core=core-b/' "$HOMEDIR/state/$id.meta"
  out=$(hc_lifecycle fm-spawn.sh "$id" --relaunch) || rc=$?
  [ "$rc" -ne 0 ] || { hc_relaunch_cleanup "$id"; fail "a not_found from another core must not rebind"$'\n'"$out"; }
  assert_contains "$out" "is not the one the task record names" "the refusal should name the core mismatch"
  sed -i.bak '/^hc_core=/d' "$HOMEDIR/state/$id.meta"
  rc=0
  out=$(hc_lifecycle fm-spawn.sh "$id" --relaunch) || rc=$?
  [ "$rc" -ne 0 ] || { hc_relaunch_cleanup "$id"; fail "a record without hc_core must not rebind"$'\n'"$out"; }
  assert_not_contains "$(cat "$D/log")" $'\x1frun\x1f' "an unproven absence must create nothing"
  printf 'hc_core=core-a\n' >> "$HOMEDIR/state/$id.meta"
  rc=0
  out=$(hc_lifecycle fm-control.sh "$id" relaunch --note "the terminal was closed") || rc=$?
  hc_relaunch_cleanup "$id"
  expect_code 0 "$rc" "relaunch of an hc task whose terminal is proven gone should succeed"$'\n'"$out"
  assert_equals "$(hc_meta_field "$id" window) $(hc_meta_field "$id" hc_terminal) $(hc_meta_field "$id" hc_core)" \
    "fmtest:t5 t5 core-a" "the record must rebind to the new terminal on the same core"
  assert_contains "$(grep $'\x1frun\x1f' "$D/log")" "HC_SESSION=fmtest" "the new terminal must be created on the recorded session"
  assert_contains "$(grep $'\x1frun\x1f' "$D/log")" $'--cwd\x1f'"$WT" "the new terminal must open in the recorded worktree"
  assert_equals "$(cat "$D/launched" 2>/dev/null)" t5 "the replacement must launch in the new terminal"
  pass "hc: relaunch re-creates a terminal only when its own core proves it gone, and rebinds the record"
}

test_kill_proves_the_terminal_is_gone() {
  local tag
  setup_case kill
  tag=$(hometag_of)
  write_terminal "$D" t1 live fm-a1 "$tag" zsh /bin/zsh
  hc_shell 'fm_backend_kill hc fmtest:t1' || fail "closing a live own terminal must succeed"
  assert_contains "$(cat "$D/log")" $'\x1fkill\x1f--json\x1ft1' "kill must end the program"
  assert_contains "$(cat "$D/log")" $'\x1frm\x1f--json\x1ft1' "kill must remove the terminal"
  hc_shell 'fm_backend_kill hc fmtest:t1' || fail "an already-gone terminal is a silent success"
  write_terminal "$D" t2 live fm-a1 "$tag" zsh /bin/zsh
  touch "$D/rm-sticks"
  expect_refused hc_shell 'fm_backend_kill hc fmtest:t2'
  pass "hc: kill ends and removes the terminal and refuses when it survives"
}

test_kill_refuses_another_tasks_terminal() {
  local tag
  setup_case kill-label
  tag=$(hometag_of)
  write_terminal "$D" t1 live fm-other "$tag" zsh /bin/zsh
  write_terminal "$D" t2 live fm-a1 "$tag" zsh /bin/zsh
  expect_refused hc_shell 'fm_backend_kill hc fmtest:t1 "" fm-a1'
  [ -f "$D/t1.json" ] || fail "another task's terminal must stay alive"
  assert_not_contains "$(cat "$D/log")" $'\x1fkill\x1f' "another task's terminal must not be closed"
  hc_shell 'fm_backend_kill hc fmtest:t2 "" fm-a1' || fail "closing the task's own labeled terminal must succeed"
  [ ! -f "$D/t2.json" ] || fail "the task's own terminal must be removed"
  pass "hc: teardown's expected label refuses another task's terminal and closes the matching one"
}

test_capture_and_current_path_read_the_recorded_terminal() {
  local tag out
  setup_case read
  tag=$(hometag_of)
  write_terminal "$D" t1 live fm-a1 "$tag" zsh /bin/zsh
  out=$(hc_shell 'fm_backend_capture hc fmtest:t1 40 fm-a1; fm_backend_visible_capture hc fmtest:t1 fm-a1; fm_backend_hc_current_path fmtest:t1 fm-a1')
  assert_contains "$out" "screen of t1" "capture reads the recorded terminal"
  assert_contains "$out" "/live" "current_path prefers the foreground cwd"
  assert_contains "$(cat "$D/log")" $'read\x1f--lines\x1f40\x1ft1' "capture asks for the requested history"
  assert_contains "$(cat "$D/log")" $'read\x1f--lines\x1f0\x1ft1' "visible capture reads the screen only"
  pass "hc: capture, visible capture, and current path read the recorded terminal"
}

test_endpoint_validation_binds_hc_meta() {
  local meta out
  setup_case meta
  meta="$D/a1.meta"
  printf 'window=fmtest:t4\nendpoint_task_id=a1\nworktree=/wt\nproject=/p\nbackend=hc\nhc_session=fmtest\nhc_terminal=t4\n' > "$meta"
  out=$(bash -c '. "'"$FM_TEST_ROOT"'/bin/fm-backend.sh"; fm_backend_validate_task_endpoint "'"$meta"'" a1 && echo "$FM_BACKEND_VALIDATED_BACKEND $FM_BACKEND_VALIDATED_TARGET"')
  assert_equals "$out" "hc fmtest:t4" "a consistent hc record validates to its target"
  printf 'window=fmtest:t5\nendpoint_task_id=a1\nworktree=/wt\nproject=/p\nbackend=hc\nhc_session=fmtest\nhc_terminal=t4\n' > "$meta"
  expect_refused bash -c '. "'"$FM_TEST_ROOT"'/bin/fm-backend.sh"; fm_backend_validate_task_endpoint "'"$meta"'" a1 2>/dev/null'
  pass "hc: endpoint validation requires window to equal hc_session:hc_terminal"
}

test_container_ensure_gates_binary_version_and_generation() {
  local out
  setup_case gate
  out=$(hc_shell 'fm_backend_hc_container_ensure')
  assert_equals "$out" fmtest "container_ensure prints the session after every gate passes"
  : > "$D/log"
  FAKE_HC_VERSION=0.1.9 expect_refused hc_shell 'fm_backend_hc_container_ensure'
  FAKE_HC_VERSION=bogus expect_refused hc_shell 'fm_backend_hc_container_ensure'
  FAKE_HC_GENERATION=2 expect_refused hc_shell 'fm_backend_hc_container_ensure'
  FAKE_HC_GENERATION=1 hc_shell 'fm_backend_hc_container_ensure' >/dev/null \
    || fail "generation 1 must be accepted"
  assert_contains "$(cat "$D/log")" $'\x1fconnect\x1f' "container_ensure must run the hello handshake"
  pass "hc: container_ensure refuses a misnamed, old, or wrong-generation binary"
}

test_send_text_submit_confirms_through_send_wait() {
  local tag out log
  setup_case submit
  tag=$(hometag_of)
  write_terminal "$D" t1 live fm-a1 "$tag" zsh /bin/zsh
  out=$(hc_shell 'fm_backend_hc_send_text_submit fmtest:t1 "deploy now" 3 0.4 0 fm-a1')
  assert_equals "$out" empty "a started turn confirms the submit"
  log=$(grep $'\x1fsend\x1f' "$D/log")
  assert_contains "$log" $'--wait\x1f--timeout\x1f' "submit must confirm through send --wait"
  assert_contains "$log" $'\x1f--\x1fdeploy now' "the text must arrive after the -- delimiter"
  printf '9\n' > "$D/send.exit"
  printf 'blocked\n' > "$D/send.kind"
  out=$(hc_shell 'fm_backend_hc_send_text_submit fmtest:t1 "deploy now" 3 0.4 0 fm-a1' 2>&1)
  assert_contains "$out" unknown "a blocked terminal is unknown, never forced"
  assert_contains "$out" blocked "the refusal must name the blocked cause"
  printf '11\n' > "$D/send.exit"
  out=$(hc_shell 'fm_backend_hc_send_text_submit fmtest:t1 "deploy now" 3 0.4 0 fm-a1')
  assert_equals "$out" send-failed "a finished terminal is send-failed"
  printf '3\n' > "$D/send.exit"
  out=$(hc_shell 'fm_backend_hc_send_text_submit fmtest:t1 "deploy now" 3 0.4 0 fm-a1')
  assert_equals "$out" send-failed "a missing terminal is send-failed"
  rm -f "$D/send.exit" "$D/send.kind"
  printf '{"started":null,"wait":{"status":"idle","timed_out":true}}\n' > "$D/send.json"
  out=$(hc_shell 'fm_backend_hc_send_text_submit fmtest:t1 "deploy now" 3 0.4 0 fm-a1')
  assert_equals "$out" unknown "a silent program falls back to the composer screen, which cannot prove empty on a plain pane"
  pass "hc: send_text_submit proves the turn through send --wait and never forces a blocked terminal"
}

test_send_delimiters_and_binary_socket_pins() {
  local tag out
  setup_case pins
  tag=$(hometag_of)
  write_terminal "$D" t1 live fm-a1 "$tag" zsh /bin/zsh
  hc_shell 'fm_backend_hc_send_text_line fmtest:t1 "-rf / --force" fm-a1' \
    || fail "send_text_line must accept flag-looking text"
  assert_contains "$(cat "$D/log")" $'send\x1f--json\x1ft1\x1f--\x1f-rf / --force' \
    "flag-looking text must arrive after the -- delimiter"
  out=$(FM_HC_SOCKET=/tmp/pinned.sock hc_shell 'fm_backend_hc_cli fmtest ls'; cat "$D/log")
  assert_contains "$out" "HC_SOCKET=/tmp/pinned.sock" "FM_HC_SOCKET must pin the socket for the call"
  CASE_HC_BIN=/nonexistent/hc expect_refused hc_shell 'fm_backend_hc_cli fmtest ls'
  mkdir -p "$D/pinned"
  cp "$FB/hc" "$D/pinned/hc"
  out=$(CASE_HC_BIN="$D/pinned/hc" hc_shell 'fm_backend_hc_bin')
  assert_equals "$out" "$D/pinned/hc" "FM_HC_BIN must win over an hc on PATH"
  pass "hc: send text is -- delimited, and FM_HC_BIN/FM_HC_SOCKET pin the call"
}

test_required_tool_check_uses_the_adapter_resolver() {
  local out
  setup_case tools
  mkdir -p "$D/core-only" "$D/none"
  cp "$FB/hc" "$D/core-only/herdr-core"
  out=$(env -u FM_HC_BIN PATH="$D/core-only:/usr/bin:/bin" "$BASH" -c '
    . "'"$FM_TEST_ROOT"'/bin/fm-backend.sh"
    fm_backend_required_tool_available hc hc && echo core-only-ok' 2>&1)
  assert_contains "$out" core-only-ok "a herdr-core-only install must satisfy the hc tool check"
  out=$(FM_HC_BIN="$FB/hc" PATH="$D/none:/usr/bin:/bin" "$BASH" -c '
    . "'"$FM_TEST_ROOT"'/bin/fm-backend.sh"
    fm_backend_required_tool_available hc hc && echo pinned-ok' 2>&1)
  assert_contains "$out" pinned-ok "an FM_HC_BIN-only install must satisfy the hc tool check"
  out=$(FM_HC_BIN=/nonexistent/hc PATH="$FB:/usr/bin:/bin" "$BASH" -c '
    . "'"$FM_TEST_ROOT"'/bin/fm-backend.sh"
    fm_backend_required_tool_available hc hc && echo found || echo missing' 2>&1)
  assert_contains "$out" missing "an unusable FM_HC_BIN must report hc missing even with hc on PATH"
  pass "hc: the bootstrap tool check resolves hc exactly as the adapter does"
}

fm_test_run \
  test_hc_is_spawn_capable_and_needs_app_signals \
  test_required_tool_check_uses_the_adapter_resolver \
  test_create_task_is_independent_labeled_and_refuses_duplicates \
  test_control_interrupt_delivers_the_harness_keys \
  test_foreign_or_unlabeled_terminal_gets_no_input_and_no_close \
  test_invalid_session_never_reaches_hc \
  test_inherited_socket_never_overrides_the_session \
  test_agent_state_classifies_foreground_and_absence \
  test_agent_state_reads_a_shell_wrappers_group \
  test_agent_state_reads_the_whole_terminal_before_calling_it_dead \
  test_agent_state_without_a_process_table_is_unreadable \
  test_relaunch_adopts_a_terminal_whose_agent_died \
  test_relaunch_stops_a_live_agent_before_replacing_it \
  test_relaunch_refuses_while_the_agent_is_alive \
  test_relaunch_rebinds_only_a_terminal_proven_gone \
  test_kill_proves_the_terminal_is_gone \
  test_kill_refuses_another_tasks_terminal \
  test_capture_and_current_path_read_the_recorded_terminal \
  test_endpoint_validation_binds_hc_meta \
  test_container_ensure_gates_binary_version_and_generation \
  test_send_text_submit_confirms_through_send_wait \
  test_send_delimiters_and_binary_socket_pins
