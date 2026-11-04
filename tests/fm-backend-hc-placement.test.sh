#!/usr/bin/env bash
# tests/fm-backend-hc-placement.test.sh - fake-hc tests for placing ship and
# scout workers on another hc machine (docs/hc-backend.md "Workers on another
# machine"): the placement config, machine-qualified addresses and records, the
# remote exec transport and machine readiness gates, the remote agent-state
# scan, a real fm-spawn of a placed scout, and a real fm-teardown of a placed
# ship whose landed-work proof runs on the other machine.
#
# The fake hc stands in for both machines. Its "other machine" is a private
# directory that every exec, file write, and run --cwd reaches only through a
# virtual root (/fm-remote-root) that must not exist on this machine, so a step
# that read a placed path on the local filesystem would fail here rather than
# pass by accident.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-backend-hc-placement-tests)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
VROOT=/fm-remote-root
REAL_GIT=$(command -v git)

[ ! -e "$VROOT" ] || { echo "skip - $VROOT exists on this machine, so placed paths cannot be told apart from local ones"; echo "1..0"; echo FM_TEST_COMPLETE; exit 0; }

# make_fake_hc <dir>: the fake core. Every call is logged as
# <cmd>\x1f<arg>... in <dir>/log. State lives in <dir>:
#   machines.json   `machine ls` answer (default: laptop connected at 0.1.18)
#   unreachable     every --on call fails as an unreachable machine
#   reverse-as      the name the other machine's hc uses for this one
#   remote/         the other machine's filesystem, seen as /fm-remote-root
#   exec.json       answered by every exec instead of running the command
#   <address>.json  a terminal record for get; run writes it, rm removes it
make_fake_hc() {  # <dir> -> fakebin
  local dir=$1 fb=$1/fakebin
  mkdir -p "$fb" "$dir/remote"
  cat > "$fb/hc" <<'SH'
#!/usr/bin/env bash
set -u
D=${FAKE_HC_DIR:?}
V=/fm-remote-root
{
  printf "%s" "${1:-}"
  for a in "${@:2}"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$D/log"
to_local() {
  case "$1" in
    "$V"|"$V"/*) printf '%s' "$D/remote${1#"$V"}" ;;
    *) printf '%s' "$1" ;;
  esac
}
to_virtual() {  # stdin -> stdout
  FAKE_REMOTE="$D/remote" FAKE_V="$V" perl -pe 's/\Q$ENV{FAKE_REMOTE}\E/$ENV{FAKE_V}/g'
}
cmd=${1:-}
[ "$#" -eq 0 ] || shift
case "$cmd" in
  --version) printf 'hc %s\n' "${FAKE_HC_VERSION:-0.1.16}" ;;
  server) printf '{}\n' ;;
  connect)
    IFS= read -r _ || true
    printf '{"jsonrpc":"2.0","id":1,"result":{"generation":1}}\n'
    ;;
  machine)
    if [ -f "$D/machines.json" ]; then cat "$D/machines.json"
    else printf '{"machines":[{"name":"laptop","state":"connected","version":"0.1.18"}]}\n'; fi
    ;;
  exec)
    on='' cwd=''
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --json) shift ;;
        --on) on=$2; shift 2 ;;
        --cwd) cwd=$2; shift 2 ;;
        --timeout) shift 2 ;;
        --) shift; break ;;
        *) break ;;
      esac
    done
    if [ -n "$on" ] && [ -e "$D/unreachable" ]; then
      printf '{"error":{"kind":"unreachable","message":"cannot reach %s"}}\n' "$on" >&2
      exit 5
    fi
    if [ -f "$D/exec.json" ]; then cat "$D/exec.json"; exit 0; fi
    out=$(mktemp) err=$(mktemp)
    if [ "${1:-}" = hc ] && [ "${2:-}" = exec ] && [ "${3:-}" = --on ]; then
      # The other machine's own hc reaching back to this one.
      as=$4
      shift 4
      [ "${1:-}" != -- ] || shift
      if [ "$as" = "$(cat "$D/reverse-as" 2>/dev/null)" ]; then
        "$@" >"$out" 2>"$err"
        code=$?
      else
        printf 'unknown machine "%s"\n' "$as" >"$err"
        code=4
      fi
    else
      args=()
      for a in "$@"; do args+=("$(to_local "$a")"); done
      [ -n "$cwd" ] && cwd=$(to_local "$cwd") || cwd="$D/remote"
      ( cd "$cwd" && "${args[@]}" ) >"$out" 2>"$err"
      code=$?
    fi
    o=$(to_virtual < "$out")
    e=$(to_virtual < "$err")
    rm -f "$out" "$err"
    jq -n --argjson code "$code" --arg o "$o" --arg e "$e" \
      '{code: $code, signal: null, stdout: ($o | @base64), stderr: ($e | @base64), timed_out: false, truncated: false}'
    ;;
  file)
    [ "${1:-}" = write ] || exit 2
    shift
    on='' path=''
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --json) shift ;;
        --on) on=$2; shift 2 ;;
        *) path=$1; shift ;;
      esac
    done
    [ -z "$on" ] || [ ! -e "$D/unreachable" ] || exit 5
    path=$(to_local "$path")
    mkdir -p "${path%/*}"
    cat > "$path"
    printf '{"path":"%s"}\n' "$path"
    ;;
  run)
    on='' cwd='' labels='{}'
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --on) on=$2; shift 2 ;;
        --cwd) cwd=$2; shift 2 ;;
        --label) labels=$(printf '%s' "$labels" | jq --arg kv "$2" '. + {($kv | split("=")[0]): ($kv | split("=")[1:] | join("="))}'); shift 2 ;;
        *) shift ;;
      esac
    done
    if [ -f "$D/run.json" ]; then cat "$D/run.json"; exit 0; fi
    address="${on:+$on/}t9"
    mkdir -p "$(dirname "$D/$address.json")"
    jq -n --arg a "$address" --arg c "$cwd" --argjson l "$labels" \
      '{address: $a, state: "live", labels: $l, cwd: $c, foreground: {name: "zsh", argv: ["zsh"], cwd: $c, pid: 1}}' \
      > "$D/$address.json"
    printf '{"address":"%s"}\n' "$address"
    ;;
  get)
    last=''
    for a in "$@"; do last=$a; done
    [ ! -e "$D/unreachable" ] || case "$last" in */*) exit 5 ;; esac
    [ -f "$D/$last.json" ] || { printf '{"error":{"kind":"not_found"}}\n' >&2; exit 3; }
    cat "$D/$last.json"
    ;;
  ls) cat "$D/ls.json" 2>/dev/null || printf '{"terminals":[]}\n' ;;
  read) printf 'screen\n' ;;
  send) printf '{"started":true,"status":"working","turn":1}\n' ;;
  rm)
    last=''
    for a in "$@"; do last=$a; done
    rm -f "$D/$last.json"
    printf '{}\n'
    ;;
  *) printf '{}\n' ;;
esac
SH
  chmod +x "$fb/hc"
  printf '%s\n' "$fb"
}

setup_case() {  # <name> -> sets D, FB, HOMEDIR
  D="$TMP_ROOT/$1"
  mkdir -p "$D"
  D=$(cd "$D" && pwd -P)
  FB=$(make_fake_hc "$D")
  : > "$D/log"
  HOMEDIR="$D/home"
  mkdir -p "$HOMEDIR/state" "$HOMEDIR/config" "$HOMEDIR/data"
}

# hc_shell <script>: <script> in bash with the adapter sourced against the fake.
hc_shell() {
  FAKE_HC_DIR=$D PATH="$FB:$PATH" FM_HC_BIN="$FB/hc" \
    FM_HOME=$HOMEDIR FM_ROOT_OVERRIDE=$HOMEDIR HC_SESSION=fmtest bash -c '
      . "'"$ROOT"'/bin/fm-backend.sh"
      fm_backend_source hc || { echo "source failed" >&2; exit 90; }
      '"$1"
}

hometag_for() {  # <home>
  FM_HOME=$1 FM_ROOT_OVERRIDE="$ROOT" bash -c '. "'"$ROOT"'/bin/fm-backend.sh"; fm_backend_source hc; fm_backend_hometag'
}

git_q() {
  "$REAL_GIT" -c user.email=t@t -c user.name=t -c init.defaultBranch=main "$@"
}

# make_repos <dir> <project-name>: a bare origin, a clone of it here at
# <dir>/<project-name>, and a clone of it on the other machine at
# remote/code/<project-name>.
make_repos() {
  local dir=$1 name=$2
  git_q init -q --bare "$dir/origin.git"
  git_q -C "$dir/origin.git" symbolic-ref HEAD refs/heads/main
  git_q clone -q "$dir/origin.git" "$dir/_seed" 2>/dev/null
  git_q -C "$dir/_seed" commit -q --allow-empty -m baseline
  git_q -C "$dir/_seed" push -q origin main
  rm -rf "$dir/_seed"
  git_q clone -q "$dir/origin.git" "$dir/$name"
  git_q -C "$dir/$name" remote set-head origin main
  mkdir -p "$dir/remote/code"
  git_q clone -q "$dir/origin.git" "$dir/remote/code/$name"
  git_q -C "$dir/remote/code/$name" remote set-head origin main
}

test_placement_config_is_exact_or_refused() {
  local out rc
  setup_case config
  # shellcheck disable=SC2016 # the inner shell expands it
  out=$(hc_shell 'fm_backend_hc_placement_config "$FM_HOME/config/hc-machine"; echo "rc=$?"')
  assert_equals "rc=1" "$out" "an absent config/hc-machine means no placement"
  cat > "$HOMEDIR/config/hc-machine" <<'EOF'
# the bigger machine
laptop
firstmate-as mini   # what it calls this one
projects /Users/me/code/
EOF
  # shellcheck disable=SC2016 # the inner shell expands it
  out=$(hc_shell 'fm_backend_hc_placement_config "$FM_HOME/config/hc-machine" && echo "$FM_BACKEND_HC_PLACE_MACHINE|$FM_BACKEND_HC_PLACE_FIRSTMATE_AS|$FM_BACKEND_HC_PLACE_PROJECTS|$FM_BACKEND_HC_PLACE_CLAUDE_CONFIG"')
  assert_equals "laptop|mini|/Users/me/code|" "$out" "a valid file names the machine, the way back, and the projects directory"
  for bad in $'laptop\nprojects /Users/me/code' $'laptop\nfirstmate-as mini\nprojects code' \
    $'laptop\nfirstmate-as mini\nprojects /a\ncolour blue' $'laptop pro\nfirstmate-as mini\nprojects /a' \
    $'laptop\nfirstmate-as mini\nprojects /a\nprojects /b' $'laptop\nfirstmate-as mini\nprojects /a/../b'; do
    printf '%s\n' "$bad" > "$HOMEDIR/config/hc-machine"
    rc=0
    # shellcheck disable=SC2016 # the inner shell expands it
    out=$(hc_shell 'fm_backend_hc_placement_config "$FM_HOME/config/hc-machine"' 2>&1) || rc=$?
    expect_code 2 "$rc" "a malformed config/hc-machine must be refused, not read as no placement: $bad"
    assert_contains "$out" "error:" "the refusal names its reason"
  done
  pass "hc placement: config/hc-machine is read exactly, and anything else is refused rather than ignored"
}

test_machine_qualified_records_bind_their_machine() {
  local meta out
  setup_case records
  # shellcheck disable=SC2016 # the inner shell expands it
  out=$(hc_shell 'for a in t3 laptop/t3 a/b/t3 laptop/ /t3 laptop/x3; do fm_backend_hc_address_valid "$a" && printf "%s:ok " "$a" || printf "%s:no " "$a"; done')
  assert_equals "t3:ok laptop/t3:ok a/b/t3:no laptop/:no /t3:no laptop/x3:no " "$out" "an address is t<id> or <machine>/t<id>"
  meta="$D/a1.meta"
  printf 'window=fmtest:laptop/t4\nendpoint_task_id=a1\nworktree=/wt\nproject=/p\nbackend=hc\nhc_session=fmtest\nhc_terminal=laptop/t4\nhc_machine=laptop\n' > "$meta"
  out=$(bash -c '. "'"$ROOT"'/bin/fm-backend.sh"; fm_backend_validate_task_endpoint "'"$meta"'" a1 && echo "$FM_BACKEND_VALIDATED_BACKEND $FM_BACKEND_VALIDATED_TARGET"')
  assert_equals "hc fmtest:laptop/t4" "$out" "a placed record validates to its machine-qualified target"
  for bad in 'hc_machine=desk|hc_terminal=laptop/t4' '|hc_terminal=laptop/t4' 'hc_machine=laptop|hc_terminal=t4'; do
    printf 'window=fmtest:%s\nendpoint_task_id=a1\nworktree=/wt\nproject=/p\nbackend=hc\nhc_session=fmtest\n%s\n%s\n' \
      "${bad#*hc_terminal=}" "${bad%%|*}" "${bad#*|}" > "$meta"
    expect_refused bash -c '. "'"$ROOT"'/bin/fm-backend.sh"; fm_backend_validate_task_endpoint "'"$meta"'" a1 2>/dev/null'
  done
  pass "hc placement: a machine-qualified terminal validates only with the matching hc_machine record"
}

expect_refused() {
  local rc=0
  "$@" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "expected a refusal from: ${*: -1}"
}

test_remote_exec_separates_transport_from_exit_codes() {
  local out rc
  setup_case exec
  mkdir -p "$D/remote/work"
  rc=0
  out=$(hc_shell 'fm_backend_hc_remote_exec fmtest laptop 30 /fm-remote-root/work sh -c "pwd; echo hi; exit 7"' 2>/dev/null) || rc=$?
  expect_code 7 "$rc" "the program's own exit code comes back"
  assert_equals "/fm-remote-root/work"$'\n'"hi" "$out" "stdout comes back decoded, from the requested directory there"
  rc=0
  hc_shell 'fm_backend_hc_remote_exec fmtest laptop 30 - sh -c "exit 255"' >/dev/null 2>&1 || rc=$?
  expect_code 254 "$rc" "a program's own 255 never reads as a transport failure"
  for answer in '{"code":null,"signal":1,"stdout":"","stderr":"","timed_out":false,"truncated":false}' \
    '{"code":null,"signal":9,"stdout":"","stderr":"","timed_out":false,"truncated":false}' \
    '{"code":0,"signal":null,"stdout":"","stderr":"","timed_out":true,"truncated":false}' \
    '{"code":0,"signal":"","stdout":"","stderr":"","timed_out":false,"truncated":true}'; do
    printf '%s\n' "$answer" > "$D/exec.json"
    rc=0
    hc_shell 'fm_backend_hc_remote_exec fmtest laptop 30 - true' >/dev/null 2>&1 || rc=$?
    expect_code 255 "$rc" "a killed, timed-out, or truncated run is a transport failure, never an exit code: $answer"
  done
  rm -f "$D/exec.json"
  touch "$D/unreachable"
  rc=0
  out=$(hc_shell 'fm_backend_hc_remote_exec fmtest laptop 30 - true' 2>&1) || rc=$?
  expect_code 255 "$rc" "an unreachable machine is a transport failure"
  assert_contains "$out" "did not run" "the transport failure is named"
  pass "hc placement: remote exec returns the program's code and keeps 255 for a transport failure"
}

test_machine_readiness_gates_connection_and_versions() {
  local out
  setup_case ready
  hc_shell 'fm_backend_hc_machine_ready fmtest laptop' >/dev/null 2>&1 || fail "a connected machine at the floor must be ready"
  out=$(hc_shell 'fm_backend_hc_machine_ready fmtest desk' 2>&1) && fail "an unadded machine must refuse"
  assert_contains "$out" "not added" "an unadded machine is named as such"
  printf '{"machines":[{"name":"laptop","state":"connecting","version":"0.1.18"}]}\n' > "$D/machines.json"
  out=$(hc_shell 'fm_backend_hc_machine_ready fmtest laptop' 2>&1) && fail "a machine that is not connected must refuse"
  assert_contains "$out" "not connected" "the refusal says the machine is not connected"
  assert_contains "$out" "never falling back" "the refusal says nothing starts here instead"
  printf '{"machines":[{"name":"laptop","state":"connected","version":"0.1.17"}]}\n' > "$D/machines.json"
  out=$(hc_shell 'fm_backend_hc_machine_ready fmtest laptop' 2>&1) && fail "an old hc there must refuse"
  assert_contains "$out" "older than 0.1.18" "the refusal names the remote floor"
  rm -f "$D/machines.json"
  out=$(FAKE_HC_VERSION=0.1.15 hc_shell 'fm_backend_hc_machine_ready fmtest laptop' 2>&1) && fail "an old local hc must refuse placement"
  assert_contains "$out" "older than 0.1.16" "the refusal names the local placement floor"
  pass "hc placement: a machine must be added, connected, and at the verified hc floor on both ends"
}

test_create_task_places_the_terminal_on_the_machine() {
  local out
  setup_case create
  out=$(hc_shell 'fm_backend_hc_create_task fmtest fm-a1 /fm-remote-root/wt laptop')
  assert_equals "laptop/t9" "$out" "the address names the machine"
  assert_contains "$(grep '^run' "$D/log")" $'\x1f--on\x1flaptop\x1f' "hc run carries --on"
  assert_contains "$(grep '^run' "$D/log")" $'--cwd\x1f/fm-remote-root/wt' "the terminal starts in the placed worktree"
  rm -f "$D/laptop/t9.json"
  printf '{"address":"t9"}\n' > "$D/run.json"
  expect_refused hc_shell 'fm_backend_hc_create_task fmtest fm-a1 /fm-remote-root/wt laptop'
  pass "hc placement: create_task starts the terminal there and refuses one that came up elsewhere"
}

test_remote_agent_state_reads_the_group_there() {
  local tag out wrapper
  setup_case agent
  tag=$(hometag_for "$HOMEDIR")
  set -m
  bash -c '(exec -a claude sleep 30); :' &
  wrapper=$!
  set +m
  mkdir -p "$D/laptop"
  jq -n --argjson p "$wrapper" --arg h "$tag" \
    '{address: "laptop/t9", state: "live", labels: {"firstmate.task": "fm-a1", "firstmate.home": $h},
      foreground: {name: "bash", argv: ["bash"], cwd: "/x", pid: $p}}' > "$D/laptop/t9.json"
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -g "$wrapper" -f '^claude' >/dev/null && break; sleep 0.1; done
  out=$(hc_shell 'fm_backend_agent_state hc fmtest:laptop/t9')
  assert_equals "alive" "$out" "a wrapper whose group runs a harness there is alive"
  assert_contains "$(grep '^exec' "$D/log")" $'\x1f--on\x1flaptop\x1f' "the group is read on the machine the terminal runs on"
  kill -- "-$wrapper" 2>/dev/null || true
  wait "$wrapper" 2>/dev/null || true
  out=$(FAKE_HC_DIR=$D PATH="$FB:$PATH" FM_HC_BIN="$FB/hc" FM_HOME=$HOMEDIR FM_ROOT_OVERRIDE=$HOMEDIR bash -c '
    . "'"$ROOT"'/bin/fm-backend.sh"; fm_backend_source hc
    fm_backend_hc_remote_exec() { return 255; }
    fm_backend_agent_state hc fmtest:laptop/t9')
  assert_equals "unreadable" "$out" "a group scan that cannot run there proves nothing, so a shell is not called dead"
  pass "hc placement: agent state reads a placed terminal's process group on its own machine"
}

test_placed_busy_state_reads_hc_native_status() {
  local tag out status
  setup_case busy
  tag=$(hometag_for "$HOMEDIR")
  mkdir -p "$D/laptop"
  printf 'backend=hc\nhc_session=fmtest\nhc_terminal=laptop/t9\nhc_machine=laptop\n' > "$HOMEDIR/state/p1.meta"
  printf 'backend=hc\nhc_session=fmtest\nhc_terminal=t8\n' > "$HOMEDIR/state/l1.meta"
  for status in working idle; do
    for addr in laptop/t9 t8; do
      jq -n --arg a "$addr" --arg h "$tag" --arg s "$status" \
        '{address: $a, state: "live", labels: {"firstmate.task": "x", "firstmate.home": $h}, status: {state: $s}}' > "$D/$addr.json"
    done
    # shellcheck disable=SC2016 # the inner shell expands it
    out=$(hc_shell '. "'"$ROOT"'/bin/fm-busy-lib.sh"
      fm_busy_classify hc fmtest:laptop/t9 claude p1 "$FM_HOME/state"; echo
      fm_busy_classify hc fmtest:t8 claude l1 "$FM_HOME/state"')
    case "$status" in
      working) assert_equals "busy hc-native"$'\n'"unknown missing" "$out" "a placed worker reads hc's working as busy; a local hc task with no record stays unknown" ;;
      idle) assert_equals "idle hc-native"$'\n'"unknown missing" "$out" "a placed worker reads hc's idle as idle; a local hc task with no record stays unknown" ;;
    esac
  done
  pass "hc placement: a placed worker's busy and idle come from hc's native status, and local hc tasks are unchanged"
}

# --- fm-spawn of a placed scout ------------------------------------------------

placed_spawn_case() {  # <name> <id> -> sets D, FB, HOMEDIR, PROJ
  setup_case "$1"
  make_repos "$D" proj
  PROJ="$D/proj"
  fm_test_spawn_home "$HOMEDIR" claude
  fm_test_spawn_brief "$HOMEDIR" "$2"
  printf 'laptop\nfirstmate-as mini\nprojects %s/code\n' "$VROOT" > "$HOMEDIR/config/hc-machine"
  printf 'mini\n' > "$D/reverse-as"
  mkdir -p "$HOMEDIR/user-home"
  jq -n --arg c "$D/remote/code/proj" '{projects: {($c): {hasTrustDialogAccepted: true}}}' \
    > "$HOMEDIR/user-home/.claude.json"
  fm_fake_exit0 "$FB" treehouse claude
}

run_placed_spawn() {  # <id> [args...]
  local id=$1
  shift
  FAKE_HC_DIR=$D FM_HC_BIN="$FB/hc" HC_SESSION=fmtest \
    fm_test_run_spawn "$HOMEDIR" "$D/nowhere" "$FB" "$id" "$PROJ" --scout --backend hc "$@"
}

test_placed_spawn_builds_everything_on_the_machine() {
  local id=place1 out rc=0 tag wt meta record launch
  placed_spawn_case spawn-ok "$id"
  tag=$(hometag_for "$HOMEDIR")
  wt="$VROOT/code/.fm-hc/$tag/$id"
  out=$(run_placed_spawn "$id") || rc=$?
  expect_code 0 "$rc" "a placed scout spawn should succeed"$'\n'"$out"
  meta="$HOMEDIR/state/$id.meta"
  assert_grep "hc_machine=laptop" "$meta" "the record names the machine"
  assert_grep "hc_terminal=laptop/t9" "$meta" "the record names the machine-qualified terminal"
  assert_grep "window=fmtest:laptop/t9" "$meta" "the target is machine-qualified"
  assert_grep "hc_clone=$VROOT/code/proj" "$meta" "the record names the clone there"
  assert_grep "hc_firstmate_as=mini" "$meta" "the record names the way back"
  assert_grep "worktree=$wt" "$meta" "the worktree is the one on the machine: $(cat "$meta")"
  [ "$("$REAL_GIT" -C "$D/remote/code/.fm-hc/$tag/$id" rev-parse --show-toplevel)" = "$D/remote/code/.fm-hc/$tag/$id" ] \
    || fail "the worktree was not created as a checkout on the machine"
  "$REAL_GIT" -C "$D/remote/code/proj" worktree list | grep -F "$D/remote/code/.fm-hc/$tag/$id" >/dev/null \
    || fail "the worktree is not a linked worktree of the clone there"
  assert_contains "$(grep '^run' "$D/log")" $'\x1f--on\x1flaptop\x1f' "the terminal starts there"
  assert_contains "$(grep '^run' "$D/log")" $'--cwd\x1f'"$wt" "the terminal starts in the placed worktree"
  assert_not_contains "$(cat "$D/log")" "treehouse" "no treehouse runs for a placed task"
  launch=
  for f in "$D/remote/code/.fm-hc/$tag/"*.launch.*.sh; do [ -e "$f" ] && { launch=$f; break; }; done
  [ -n "$launch" ] || fail "the launch file was not staged on the machine"
  assert_grep "command rm -f -- '$VROOT/code/.fm-hc/$tag/$id.launch." "$launch" "the launch removes itself there"
  assert_grep "hc file read --on mini" "$launch" "the launch prompt says how to read the brief from there"
  assert_no_grep "--add-dir" "$launch" "no local directory is granted to a worker that cannot see it"
  assert_no_grep "$HOMEDIR/state/$id.git-hooks" "$launch" "no local git hooks reach the placed worker"
  assert_contains "$(grep '^send' "$D/log")" ". '$VROOT/code/.fm-hc/$tag/$id.launch." "the pane sources the launch file there"
  assert_absent "$HOMEDIR/state/$id.busy-gen" "a placed worker gets no busy record nothing there could clear"
  record=$(grep -l 'Machine placement' "$HOMEDIR/state/operational-inbox/"*.msg 2>/dev/null | head -1)
  [ -n "$record" ] || fail "the launch brief record does not carry the placement section"
  assert_grep "hc exec --on mini -- sh -c" "$record" "the brief says how to run Firstmate-path commands"
  assert_grep "brief for $id" "$record" "the brief itself follows the placement section"
  pass "hc placement: a placed scout gets its worktree, terminal, and launch on the machine, and its brief stays here"
}

test_placed_spawn_refuses_before_creating_anything() {
  local id out rc
  id=refuse1
  placed_spawn_case refuse-disconnected "$id"
  printf '{"machines":[{"name":"laptop","state":"disconnected","version":"0.1.18"}]}\n' > "$D/machines.json"
  rc=0
  out=$(run_placed_spawn "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "a disconnected machine must refuse the spawn"
  assert_contains "$out" "not connected" "the refusal names the disconnected machine"
  assert_no_grep $'run\x1f' "$D/log" "no terminal may start anywhere"
  assert_absent "$HOMEDIR/state/$id.meta" "no record may be written"

  id=refuse2
  placed_spawn_case refuse-clone "$id"
  rm -rf "$D/remote/code/proj"
  rc=0
  out=$(run_placed_spawn "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "a missing clone must refuse the spawn"
  assert_contains "$out" "no clone of this project" "the refusal names the missing clone"
  assert_no_grep $'run\x1f' "$D/log" "no terminal may start without the clone"

  id=refuse3
  placed_spawn_case refuse-route "$id"
  printf 'elsewhere\n' > "$D/reverse-as"
  rc=0
  out=$(run_placed_spawn "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "a missing route back must refuse the spawn"
  assert_contains "$out" "does not reach this machine as 'mini'" "the refusal names the missing route back"
  assert_no_grep $'run\x1f' "$D/log" "no terminal may start without the route back"
  for f in "$HOMEDIR/state/".hc-reverse-route.*; do
    [ -e "$f" ] && fail "the route probe must not be left behind"
  done

  id=refuse4
  placed_spawn_case refuse-trust "$id"
  printf '{"projects":{}}\n' > "$HOMEDIR/user-home/.claude.json"
  rc=0
  out=$(run_placed_spawn "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "an untrusted clone must refuse the spawn"
  assert_contains "$out" "workspace-trust dialog" "the refusal names the trust dialog"

  id=refuse5
  placed_spawn_case refuse-harness "$id"
  fm_fake_exit0 "$FB" codex
  rc=0
  out=$(run_placed_spawn "$id" --harness codex) || rc=$?
  [ "$rc" -ne 0 ] || fail "a non-claude harness must refuse placement"
  assert_contains "$out" "claude harness only" "the refusal names the supported harness"
  assert_no_grep $'run\x1f' "$D/log" "no terminal may start for an unsupported harness"

  id=refuse6
  placed_spawn_case refuse-flag "$id"
  rm -f "$HOMEDIR/config/hc-machine"
  rc=0
  out=$(run_placed_spawn "$id" --hc-machine laptop) || rc=$?
  [ "$rc" -ne 0 ] || fail "--hc-machine without config/hc-machine must refuse"
  assert_contains "$out" "needs config/hc-machine" "the refusal names the missing declaration"
  assert_no_grep $'run\x1f' "$D/log" "no terminal may start on an undeclared machine"
  pass "hc placement: a machine that is down, lacks the clone, the route back, or trust, or an unsupported harness, refuses before anything is created"
}

# A projects path with a symlink component (macOS /tmp is /private/tmp) names
# the clone by a path git reports only in its physical form. Oracle: the clone
# is the same directory either way, so the check must accept it and hand back
# the physical path the rest of the spawn uses; a symlinked path with no clone
# behind it is still refused.
test_placed_clone_check_resolves_a_symlinked_projects_path() {
  local id=link1 out rc tag meta
  setup_case clone-link
  make_repos "$D" proj
  ln -s "$D/remote/code" "$D/remote/link"
  rc=0
  out=$(hc_shell 'fm_backend_hc_remote_clone_check fmtest laptop /fm-remote-root/link/proj "'"$D/proj"'"' 2>&1) || rc=$?
  expect_code 0 "$rc" "a clone reached through a symlinked projects path is the clone: $out"
  assert_equals "$VROOT/code/proj" "$out" "the check reports the clone's physical path there"
  rc=0
  out=$(hc_shell 'fm_backend_hc_remote_clone_check fmtest laptop /fm-remote-root/link/nosuch "'"$D/proj"'"' 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a symlinked path with no clone behind it must be refused"
  assert_contains "$out" "no clone of this project" "the refusal names the missing clone"

  placed_spawn_case clone-link-spawn "$id"
  ln -s "$D/remote/code" "$D/remote/link"
  printf 'laptop\nfirstmate-as mini\nprojects %s/link\n' "$VROOT" > "$HOMEDIR/config/hc-machine"
  tag=$(hometag_for "$HOMEDIR")
  rc=0
  out=$(run_placed_spawn "$id") || rc=$?
  expect_code 0 "$rc" "a placed spawn under a symlinked projects path should succeed"$'\n'"$out"
  meta="$HOMEDIR/state/$id.meta"
  assert_grep "hc_clone=$VROOT/code/proj" "$meta" "the record names the clone's physical path"
  assert_grep "worktree=$VROOT/code/.fm-hc/$tag/$id" "$meta" "the worktree is recorded by git's physical path for it: $(cat "$meta")"
  "$REAL_GIT" -C "$D/remote/code/proj" worktree list | grep -F "$D/remote/code/.fm-hc/$tag/$id" >/dev/null \
    || fail "the worktree is not a linked worktree of the clone there"
  pass "hc placement: a symlinked projects path reaches its clone, and a symlinked path with no clone is refused"
}

# --- fm-teardown of a placed ship ---------------------------------------------

# placed_teardown_case <name>: a placed ship task-x1 whose worktree is a linked
# worktree of the clone on the machine, on branch fm/task-x1.
placed_teardown_case() {
  local tag fakebin
  setup_case "$1"
  make_repos "$D" proj
  tag=$(hometag_for "$HOMEDIR")
  TWT_LOCAL="$D/remote/code/.fm-hc/$tag/task-x1"
  TWT="$VROOT/code/.fm-hc/$tag/task-x1"
  mkdir -p "$D/remote/code/.fm-hc/$tag"
  git_q -C "$D/remote/code/proj" worktree add -q -b fm/task-x1 "$TWT_LOCAL" origin/main
  mkdir -p "$D/laptop"
  jq -n --arg h "$tag" '{address: "laptop/t9", state: "live",
    labels: {"firstmate.task": "fm-task-x1", "firstmate.home": $h},
    foreground: {name: "zsh", argv: ["zsh"], cwd: "/x", pid: 1}}' > "$D/laptop/t9.json"
  fm_write_meta "$HOMEDIR/state/task-x1.meta" \
    "window=fmtest:laptop/t9" "endpoint_task_id=task-x1" "worktree=$TWT" \
    "project=$D/proj" "harness=claude" "kind=ship" "mode=no-mistakes" \
    "spawn_gen=placed-teardown-test" "backend=hc" "hc_session=fmtest" \
    "hc_terminal=laptop/t9" "hc_machine=laptop" "hc_firstmate_as=mini" \
    "hc_clone=$VROOT/code/proj"
  touch "$HOMEDIR/state/.last-watcher-beat"
  fakebin=$FB
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []" ; exit 0 ;;
esac
exit 1
SH
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
echo "error: pull request not found" >&2
exit 1
SH
  cat > "$fakebin/lsof" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" -d cwd "*) exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/lsof"
  fm_fake_exit0 "$fakebin" treehouse tmux no-mistakes
  chmod +x "$fakebin/gh-axi" "$fakebin/gh"
}

run_placed_teardown() {
  FAKE_HC_DIR=$D FM_HC_BIN="$FB/hc" FM_HOME=$HOMEDIR FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$HOMEDIR/state" FM_DATA_OVERRIDE="$HOMEDIR/data" \
    FM_CONFIG_OVERRIDE="$HOMEDIR/config" PATH="$FB:$PATH" \
    "$ROOT/bin/fm-teardown.sh" task-x1 "$@"
}

test_placed_teardown_refuses_unlanded_or_unreachable_work() {
  local out rc
  placed_teardown_case teardown-dirty
  printf 'unsaved\n' > "$TWT_LOCAL/notes.txt"
  rc=0
  out=$(run_placed_teardown 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "uncommitted work on the machine must refuse cleanup"$'\n'"$out"
  assert_contains "$out" "has uncommitted changes" "the refusal names the uncommitted work"
  assert_present "$HOMEDIR/state/task-x1.meta" "the record naming that work must survive"
  assert_present "$TWT_LOCAL/notes.txt" "the work there must survive"
  assert_no_grep $'kill\x1f' "$D/log" "the worker there must not be stopped by a refused cleanup"

  placed_teardown_case teardown-unpushed
  printf "change\n" > "$TWT_LOCAL/change.txt"
  git_q -C "$TWT_LOCAL" add change.txt
  git_q -C "$TWT_LOCAL" commit -q -m "local only"
  rc=0
  out=$(run_placed_teardown 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a commit on no remote must refuse cleanup"$'\n'"$out"
  assert_contains "$out" "not on any remote and not landed" "the refusal names the unlanded commit"
  assert_present "$HOMEDIR/state/task-x1.meta" "the record must survive an unlanded commit"
  assert_present "$TWT_LOCAL" "the worktree there must survive an unlanded commit"

  placed_teardown_case teardown-unreachable
  git_q -C "$TWT_LOCAL" commit -q --allow-empty -m "pushed" && git_q -C "$TWT_LOCAL" push -q origin fm/task-x1
  touch "$D/unreachable"
  rc=0
  out=$(run_placed_teardown 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "an unreachable machine must refuse cleanup, even for pushed work"$'\n'"$out"
  assert_contains "$out" "cannot reach hc machine 'laptop'" "the refusal names the unreachable machine"
  assert_present "$HOMEDIR/state/task-x1.meta" "the record must survive an unreachable machine"
  assert_present "$TWT_LOCAL" "the worktree there must survive an unreachable machine"
  pass "hc placement: teardown refuses uncommitted, unlanded, or unreachable work on the machine and keeps every record"
}

test_placed_teardown_removes_landed_work_there() {
  local out rc
  placed_teardown_case teardown-landed
  git_q -C "$TWT_LOCAL" commit -q --allow-empty -m "the change"
  git_q -C "$TWT_LOCAL" push -q origin fm/task-x1
  rc=0
  out=$(run_placed_teardown 2>&1) || rc=$?
  expect_code 0 "$rc" "pushed work on the machine should clean up"$'\n'"$out"
  assert_absent "$TWT_LOCAL" "the worktree there is removed"
  "$REAL_GIT" -C "$D/remote/code/proj" show-ref --verify --quiet refs/heads/fm/task-x1 \
    && fail "the task branch in the clone there must be deleted"
  assert_grep $'kill\x1f--json\x1flaptop/t9' "$D/log" "the terminal there is ended"
  assert_absent "$D/laptop/t9.json" "the terminal there is removed"
  assert_absent "$HOMEDIR/state/task-x1.meta" "the record is retired"
  assert_absent "$VROOT" "nothing was created under the placed path on this machine"

  placed_teardown_case teardown-force
  printf 'discard me\n' > "$TWT_LOCAL/scratch.txt"
  rc=0
  out=$(run_placed_teardown --force 2>&1) || rc=$?
  expect_code 0 "$rc" "--force discards the work there as it does here"$'\n'"$out"
  assert_absent "$TWT_LOCAL" "the forced worktree there is removed"
  pass "hc placement: teardown removes a placed worktree there only after proving its work landed, or under --force"
}

crew_state() {
  FAKE_HC_DIR=$D FM_HC_BIN="$FB/hc" FM_HOME=$HOMEDIR FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$HOMEDIR/state" FM_DATA_OVERRIDE="$HOMEDIR/data" \
    FM_CONFIG_OVERRIDE="$HOMEDIR/config" PATH="$FB:$PATH" \
    "$ROOT/bin/fm-crew-state.sh" task-x1 2>&1
}

test_placed_crew_state_reads_the_worktree_there() {
  local out
  placed_teardown_case crew
  printf 'working [at=%s]: implementing\n' "$(date +%s)" > "$HOMEDIR/state/task-x1.status"
  out=$(crew_state)
  assert_not_contains "$out" "worktree gone" "a placed worktree that exists there is not gone"
  touch "$D/unreachable"
  out=$(crew_state)
  assert_not_contains "$out" "worktree gone" "an unreachable machine proves nothing about its worktree"
  assert_not_contains "$out" "backend target gone" "an unreachable machine is never read as a gone terminal"
  assert_contains "$out" "backend unreachable" "an unreachable machine reads as unreachable"
  rm -f "$D/unreachable"
  rm -rf "$TWT_LOCAL"
  out=$(crew_state)
  assert_contains "$out" "worktree gone on hc machine laptop" "a placed worktree removed there reads as gone"
  pass "hc placement: current state reads a placed worktree's presence on its own machine"
}

dod_gate() {  # <done-line> -> the gate's reason, exit status preserved
  FAKE_HC_DIR=$D FM_HC_BIN="$FB/hc" FM_HOME=$HOMEDIR FM_ROOT_OVERRIDE="$ROOT" PATH="$FB:$PATH" bash -c '
    . "'"$ROOT"'/bin/fm-dod-lib.sh"
    fm_dod_accept_ship_done ship direct-PR "$1" "$2" "$3" "$4" task-x1 "$4/task-x1.meta"
  ' _ "$TWT" "$D/proj" "$1" "$HOMEDIR/state"
}

test_placed_done_gate_reads_the_head_there() {
  local out rc line='done [at=1]: PR https://github.com/o/r/pull/1'
  placed_teardown_case dod
  printf 'change\n' > "$TWT_LOCAL/change.txt"
  git_q -C "$TWT_LOCAL" add change.txt
  git_q -C "$TWT_LOCAL" commit -q -m "the change"
  rc=0
  out=$(dod_gate "$line") || rc=$?
  [ "$rc" -ne 0 ] || fail "a head that exists only in the worktree there must not be accepted"
  assert_contains "$out" "unreachable outside the worker copy on hc machine 'laptop'" "the refusal names the unpushed head there"
  git_q -C "$TWT_LOCAL" push -q origin fm/task-x1
  dod_gate "$line" >/dev/null || fail "a head reachable from the clone's remote-tracking refs there must be accepted"
  touch "$D/unreachable"
  rc=0
  out=$(dod_gate "$line") || rc=$?
  [ "$rc" -ne 0 ] || fail "an unreachable machine must not accept the done"
  assert_contains "$out" "could not be read" "the refusal says the worktree there could not be read"
  pass "hc placement: the done gate reads a placed worker's head on its own machine"
}

fm_test_run \
  test_placement_config_is_exact_or_refused \
  test_machine_qualified_records_bind_their_machine \
  test_remote_exec_separates_transport_from_exit_codes \
  test_machine_readiness_gates_connection_and_versions \
  test_create_task_places_the_terminal_on_the_machine \
  test_remote_agent_state_reads_the_group_there \
  test_placed_busy_state_reads_hc_native_status \
  test_placed_spawn_builds_everything_on_the_machine \
  test_placed_spawn_refuses_before_creating_anything \
  test_placed_clone_check_resolves_a_symlinked_projects_path \
  test_placed_teardown_refuses_unlanded_or_unreachable_work \
  test_placed_teardown_removes_landed_work_there \
  test_placed_done_gate_reads_the_head_there \
  test_placed_crew_state_reads_the_worktree_there
