#!/usr/bin/env bash
# tests/fm-backend-hc-placement.test.sh - fake-hc tests for placing ship and
# scout workers on another hc machine (docs/hc-backend.md "Workers on another
# machine"): the placement config, machine-qualified addresses and records, the
# remote exec transport (byte-exact output) and machine readiness gates, the
# remote default branch and worktree creation, the remote agent-state scan, a
# real fm-spawn of a placed scout and ship (its claude check, and its abort's
# worktree and launch-file cleanup), and a real fm-teardown of a placed ship
# whose landed-work proof, no-mistakes abort, process reap, and launch-file
# removal run on the other machine, and which records no pipeline spend here.
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
#   machines.json   `machine ls` answer (default: worker-host connected at 0.1.18)
#   unreachable     every --on call fails as an unreachable machine
#   reverse-as      the name the other machine's hc uses for this one
#   remote/         the other machine's filesystem, seen as /fm-remote-root
#   exec.json       answered by every exec instead of running the command
#   exec-refuse     an exec whose argv contains this text fails as unreachable
#   file-write-lost a file write lands but its answer is lost (exit 5)
#   run-answer-lost run starts the terminal but its answer is lost (exit 5)
#   remote-bin/     the only PATH the other machine's login shell has
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
    else printf '{"machines":[{"name":"worker-host","state":"connected","version":"0.1.18"}]}\n'; fi
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
    if [ -f "$D/exec-refuse" ] && printf '%s\n' "$@" | grep -qF -- "$(cat "$D/exec-refuse")"; then
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
    [ ! -e "$D/file-write-lost" ] || exit 5
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
    [ ! -e "$D/run-answer-lost" ] || exit 5
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
  # The other machine's login shell: `-lc <cmd>` runs <cmd> with only
  # remote-bin on PATH, so a claude this machine has never answers for it.
  mkdir -p "$D/remote-bin"
  cat > "$D/remote-login-shell" <<SH
#!/bin/sh
[ "\$1" = -lc ] || exit 64
PATH='$D/remote-bin'
export PATH
exec /bin/sh -c "\$2"
SH
  chmod +x "$D/remote-login-shell"
  printf '#!/bin/sh\necho "2.1.0 (Claude Code)"\n' > "$D/remote-bin/claude"
  chmod +x "$D/remote-bin/claude"
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
worker-host
firstmate-as firstmate-host   # what it calls this one
projects /Users/me/code/
EOF
  # shellcheck disable=SC2016 # the inner shell expands it
  out=$(hc_shell 'fm_backend_hc_placement_config "$FM_HOME/config/hc-machine" && echo "$FM_BACKEND_HC_PLACE_MACHINE|$FM_BACKEND_HC_PLACE_FIRSTMATE_AS|$FM_BACKEND_HC_PLACE_PROJECTS|$FM_BACKEND_HC_PLACE_CLAUDE_CONFIG"')
  assert_equals "worker-host|firstmate-host|/Users/me/code|" "$out" "a valid file names the machine, the way back, and the projects directory"
  for bad in $'worker-host\nprojects /Users/me/code' $'worker-host\nfirstmate-as firstmate-host\nprojects code' \
    $'worker-host\nfirstmate-as firstmate-host\nprojects /a\ncolour blue' $'worker-host pro\nfirstmate-as firstmate-host\nprojects /a' \
    $'worker-host\nfirstmate-as firstmate-host\nprojects /a\nprojects /b' $'worker-host\nfirstmate-as firstmate-host\nprojects /a/../b'; do
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
  out=$(hc_shell 'for a in t3 worker-host/t3 a/b/t3 worker-host/ /t3 worker-host/x3; do fm_backend_hc_address_valid "$a" && printf "%s:ok " "$a" || printf "%s:no " "$a"; done')
  assert_equals "t3:ok worker-host/t3:ok a/b/t3:no worker-host/:no /t3:no worker-host/x3:no " "$out" "an address is t<id> or <machine>/t<id>"
  meta="$D/a1.meta"
  printf 'window=fmtest:worker-host/t4\nendpoint_task_id=a1\nworktree=/wt\nproject=/p\nbackend=hc\nhc_session=fmtest\nhc_terminal=worker-host/t4\nhc_machine=worker-host\n' > "$meta"
  out=$(bash -c '. "'"$ROOT"'/bin/fm-backend.sh"; fm_backend_validate_task_endpoint "'"$meta"'" a1 && echo "$FM_BACKEND_VALIDATED_BACKEND $FM_BACKEND_VALIDATED_TARGET"')
  assert_equals "hc fmtest:worker-host/t4" "$out" "a placed record validates to its machine-qualified target"
  for bad in 'hc_machine=desk|hc_terminal=worker-host/t4' '|hc_terminal=worker-host/t4' 'hc_machine=worker-host|hc_terminal=t4' \
    '|hc_terminal=/t4'; do
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
  out=$(hc_shell 'fm_backend_hc_remote_exec fmtest worker-host 30 /fm-remote-root/work sh -c "pwd; echo hi; exit 7"' 2>/dev/null) || rc=$?
  expect_code 7 "$rc" "the program's own exit code comes back"
  assert_equals "/fm-remote-root/work"$'\n'"hi" "$out" "stdout comes back decoded, from the requested directory there"
  rc=0
  hc_shell 'fm_backend_hc_remote_exec fmtest worker-host 30 - sh -c "exit 255"' >/dev/null 2>&1 || rc=$?
  expect_code 254 "$rc" "a program's own 255 never reads as a transport failure"
  for answer in '{"code":null,"signal":1,"stdout":"","stderr":"","timed_out":false,"truncated":false}' \
    '{"code":null,"signal":9,"stdout":"","stderr":"","timed_out":false,"truncated":false}' \
    '{"code":0,"signal":null,"stdout":"","stderr":"","timed_out":true,"truncated":false}' \
    '{"code":0,"signal":"","stdout":"","stderr":"","timed_out":false,"truncated":true}'; do
    printf '%s\n' "$answer" > "$D/exec.json"
    rc=0
    hc_shell 'fm_backend_hc_remote_exec fmtest worker-host 30 - true' >/dev/null 2>&1 || rc=$?
    expect_code 255 "$rc" "a killed, timed-out, or truncated run is a transport failure, never an exit code: $answer"
  done
  rm -f "$D/exec.json"
  touch "$D/unreachable"
  rc=0
  out=$(hc_shell 'fm_backend_hc_remote_exec fmtest worker-host 30 - true' 2>&1) || rc=$?
  expect_code 255 "$rc" "an unreachable machine is a transport failure"
  assert_contains "$out" "did not run" "the transport failure is named"
  pass "hc placement: remote exec returns the program's code and keeps 255 for a transport failure"
}

# Oracle: hc's exec stdout is base64 of the program's raw bytes. Two different
# patches must never read alike, and an answer that cannot be decoded is no
# answer at all (the remote_exec header: a failure never reads as output).
test_remote_exec_keeps_bytes_and_refuses_undecodable_output() {
  local out rc
  setup_case exec-bytes
  # "6Xg=" is the bytes e9 78: a Latin-1 e-acute then x, which is not UTF-8.
  printf '{"code":0,"signal":null,"stdout":"6Xg=","stderr":"","timed_out":false,"truncated":false}\n' > "$D/exec.json"
  out=$(hc_shell 'fm_backend_hc_remote_exec fmtest worker-host 30 - true | od -An -tx1' 2>/dev/null | tr -d ' \n')
  assert_equals "e978" "$out" "stdout comes back byte for byte, with no replacement character"
  printf '{"code":0,"signal":null,"stdout":" M dirty.txt\\n","stderr":"","timed_out":false,"truncated":false}\n' > "$D/exec.json"
  rc=0
  out=$(hc_shell 'fm_backend_hc_remote_exec fmtest worker-host 30 - true' 2>&1) || rc=$?
  expect_code 255 "$rc" "output that is not base64 is a transport failure, never an empty answer"
  assert_contains "$out" "not base64" "the failure is named"
  pass "hc placement: remote exec returns raw bytes and refuses output it cannot decode"
}

# Oracle: a local spawn reads origin's current default branch and refuses when
# it cannot (fm-spawn's pooled-worktree base check); a placed spawn's base
# follows the same rule there, so a renamed default branch is never read stale.
test_placed_default_branch_is_read_from_origin() {
  local out
  setup_case default-branch
  make_repos "$D" proj
  git_q -C "$D/origin.git" branch trunk main
  git_q -C "$D/origin.git" symbolic-ref HEAD refs/heads/trunk
  out=$(hc_shell 'fm_backend_hc_remote_default_branch fmtest worker-host /fm-remote-root/code/proj')
  assert_equals "trunk" "$out" "origin's current default branch is read, not the clone's cached origin/HEAD"
  git_q -C "$D/remote/code/proj" remote set-url origin "$D/no-such-origin.git"
  expect_refused hc_shell 'fm_backend_hc_remote_default_branch fmtest worker-host /fm-remote-root/code/proj'
  pass "hc placement: a placed base is origin's current default branch, or nothing"
}

# Oracle: once the worktree path is proved absent there, anything at it is the
# creation's own, so a creation that fails after that point (here the answer
# after git worktree add is lost) removes it rather than leaking it.
test_placed_worktree_add_failure_removes_what_it_made() {
  local out rc
  setup_case wt-add-fail
  make_repos "$D" proj
  printf 'rev-parse\n' > "$D/exec-refuse"
  rc=0
  out=$(hc_shell 'fm_backend_hc_remote_worktree_add fmtest worker-host /fm-remote-root/code/proj /fm-remote-root/code/.fm-hc/x/w1 main' 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a creation whose check cannot run must fail"$'\n'"$out"
  assert_absent "$D/remote/code/.fm-hc/x/w1" "the worktree the failed creation made there is removed"
  "$REAL_GIT" -C "$D/remote/code/proj" worktree list | grep -F ".fm-hc/x/w1" >/dev/null \
    && fail "the clone there still lists the failed worktree"
  pass "hc placement: a worktree creation that fails part way removes what it made there"
}

# Oracle: a worktree this creation did not make is not its to remove. Here
# another checkout (with its own branch and work) appears at the path after the
# absence check, so this call's git worktree add fails; that checkout, its file,
# and its branch must survive the failed creation untouched.
test_placed_worktree_add_failure_leaves_a_foreign_worktree() {
  local out rc wt
  setup_case wt-add-race
  make_repos "$D" proj
  wt="$D/remote/code/.fm-hc/x/w1"
  mkdir -p "$D/racebin"
  cat > "$D/racebin/git" <<SH
#!/bin/sh
case " \$* " in
  *" worktree add "*)
    "$REAL_GIT" -C "$D/remote/code/proj" worktree add --quiet -b other-work "$wt" origin/main >/dev/null 2>&1 || exit 97
    echo "their work" > "$wt/theirs.txt" ;;
esac
exec "$REAL_GIT" "\$@"
SH
  chmod +x "$D/racebin/git"
  rc=0
  out=$(PATH="$D/racebin:$PATH" hc_shell 'fm_backend_hc_remote_worktree_add fmtest worker-host /fm-remote-root/code/proj /fm-remote-root/code/.fm-hc/x/w1 main' 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "an add that finds the path taken must fail"$'\n'"$out"
  assert_contains "$out" "could not add worktree" "the refusal names the failed add"
  [ -f "$wt/theirs.txt" ] || fail "the other checkout's work must survive the failed creation"$'\n'"$out"
  "$REAL_GIT" -C "$D/remote/code/proj" worktree list | grep -F ".fm-hc/x/w1" >/dev/null \
    || fail "the clone there must still list the other checkout"
  "$REAL_GIT" -C "$D/remote/code/proj" rev-parse --verify --quiet refs/heads/other-work >/dev/null \
    || fail "the other checkout's branch must survive the failed creation"
  pass "hc placement: a failed worktree add leaves a checkout it did not make, with its work and branch"
}

test_machine_readiness_gates_connection_and_versions() {
  local out
  setup_case ready
  hc_shell 'fm_backend_hc_machine_ready fmtest worker-host' >/dev/null 2>&1 || fail "a connected machine at the floor must be ready"
  out=$(hc_shell 'fm_backend_hc_machine_ready fmtest desk' 2>&1) && fail "an unadded machine must refuse"
  assert_contains "$out" "not added" "an unadded machine is named as such"
  printf '{"machines":[{"name":"worker-host","state":"connecting","version":"0.1.18"}]}\n' > "$D/machines.json"
  out=$(hc_shell 'fm_backend_hc_machine_ready fmtest worker-host' 2>&1) && fail "a machine that is not connected must refuse"
  assert_contains "$out" "not connected" "the refusal says the machine is not connected"
  assert_contains "$out" "never falling back" "the refusal says nothing starts here instead"
  printf '{"machines":[{"name":"worker-host","state":"connected","version":"0.1.17"}]}\n' > "$D/machines.json"
  out=$(hc_shell 'fm_backend_hc_machine_ready fmtest worker-host' 2>&1) && fail "an old hc there must refuse"
  assert_contains "$out" "older than 0.1.18" "the refusal names the remote floor"
  rm -f "$D/machines.json"
  out=$(FAKE_HC_VERSION=0.1.15 hc_shell 'fm_backend_hc_machine_ready fmtest worker-host' 2>&1) && fail "an old local hc must refuse placement"
  assert_contains "$out" "older than 0.1.16" "the refusal names the local placement floor"
  pass "hc placement: a machine must be added, connected, and at the verified hc floor on both ends"
}

test_create_task_places_the_terminal_on_the_machine() {
  local out
  setup_case create
  out=$(hc_shell 'fm_backend_hc_create_task fmtest fm-a1 /fm-remote-root/wt worker-host')
  assert_equals "worker-host/t9" "$out" "the address names the machine"
  assert_contains "$(grep '^run' "$D/log")" $'\x1f--on\x1fworker-host\x1f' "hc run carries --on"
  assert_contains "$(grep '^run' "$D/log")" $'--cwd\x1f/fm-remote-root/wt' "the terminal starts in the placed worktree"
  rm -f "$D/worker-host/t9.json"
  printf '{"address":"t9"}\n' > "$D/run.json"
  expect_refused hc_shell 'fm_backend_hc_create_task fmtest fm-a1 /fm-remote-root/wt worker-host'
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
  mkdir -p "$D/worker-host"
  jq -n --argjson p "$wrapper" --arg h "$tag" \
    '{address: "worker-host/t9", state: "live", labels: {"firstmate.task": "fm-a1", "firstmate.home": $h},
      foreground: {name: "bash", argv: ["bash"], cwd: "/x", pid: $p}}' > "$D/worker-host/t9.json"
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -g "$wrapper" -f '^claude' >/dev/null && break; sleep 0.1; done
  out=$(hc_shell 'fm_backend_agent_state hc fmtest:worker-host/t9')
  assert_equals "alive" "$out" "a wrapper whose group runs a harness there is alive"
  assert_contains "$(grep '^exec' "$D/log")" $'\x1f--on\x1fworker-host\x1f' "the group is read on the machine the terminal runs on"
  kill -- "-$wrapper" 2>/dev/null || true
  wait "$wrapper" 2>/dev/null || true
  out=$(FAKE_HC_DIR=$D PATH="$FB:$PATH" FM_HC_BIN="$FB/hc" FM_HOME=$HOMEDIR FM_ROOT_OVERRIDE=$HOMEDIR bash -c '
    . "'"$ROOT"'/bin/fm-backend.sh"; fm_backend_source hc
    fm_backend_hc_remote_exec() { return 255; }
    fm_backend_agent_state hc fmtest:worker-host/t9')
  assert_equals "unreadable" "$out" "a group scan that cannot run there proves nothing, so a shell is not called dead"
  pass "hc placement: agent state reads a placed terminal's process group on its own machine"
}

test_placed_busy_state_reads_hc_native_status() {
  local tag out status
  setup_case busy
  tag=$(hometag_for "$HOMEDIR")
  mkdir -p "$D/worker-host"
  printf 'backend=hc\nhc_session=fmtest\nhc_terminal=worker-host/t9\nhc_machine=worker-host\n' > "$HOMEDIR/state/p1.meta"
  printf 'backend=hc\nhc_session=fmtest\nhc_terminal=t8\n' > "$HOMEDIR/state/l1.meta"
  for status in working idle; do
    for addr in worker-host/t9 t8; do
      jq -n --arg a "$addr" --arg h "$tag" --arg s "$status" \
        '{address: $a, state: "live", labels: {"firstmate.task": "x", "firstmate.home": $h}, status: {state: $s}}' > "$D/$addr.json"
    done
    # shellcheck disable=SC2016 # the inner shell expands it
    out=$(hc_shell '. "'"$ROOT"'/bin/fm-busy-lib.sh"
      fm_busy_classify hc fmtest:worker-host/t9 claude p1 "$FM_HOME/state"; echo
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
  printf 'worker-host\nfirstmate-as firstmate-host\nprojects %s/code\n' "$VROOT" > "$HOMEDIR/config/hc-machine"
  printf 'firstmate-host\n' > "$D/reverse-as"
  mkdir -p "$HOMEDIR/user-home"
  jq -n --arg c "$D/remote/code/proj" '{projects: {($c): {hasTrustDialogAccepted: true}}}' \
    > "$HOMEDIR/user-home/.claude.json"
  fm_fake_exit0 "$FB" treehouse claude
}

run_placed_spawn() {  # <id> [args...]: a scout, or a ship with PLACED_SHIP=1
  local id=$1 kind=(--scout)
  shift
  [ "${PLACED_SHIP:-0}" = 0 ] || kind=(--mode no-mistakes --yolo off)
  FAKE_HC_DIR=$D FM_HC_BIN="$FB/hc" HC_SESSION=fmtest SHELL="$D/remote-login-shell" \
    fm_test_run_spawn "$HOMEDIR" "$D/nowhere" "$FB" "$id" "$PROJ" "${kind[@]}" --backend hc "$@"
}

test_placed_spawn_builds_everything_on_the_machine() {
  local id=place1 out rc=0 tag wt meta record launch
  placed_spawn_case spawn-ok "$id"
  tag=$(hometag_for "$HOMEDIR")
  wt="$VROOT/code/.fm-hc/$tag/$id"
  # A pinned account on this machine cannot follow the worker there.
  printf '%s\n' "$HOMEDIR/pinned-claude" > "$HOMEDIR/config/claude-account"
  out=$(run_placed_spawn "$id" 2>&1) || rc=$?
  expect_code 0 "$rc" "a placed scout spawn should succeed"$'\n'"$out"
  assert_contains "$out" "config/claude-account does not apply to a worker placed on hc machine 'worker-host'" "a skipped account pin is named"
  meta="$HOMEDIR/state/$id.meta"
  assert_grep "hc_machine=worker-host" "$meta" "the record names the machine"
  assert_grep "hc_terminal=worker-host/t9" "$meta" "the record names the machine-qualified terminal"
  assert_grep "window=fmtest:worker-host/t9" "$meta" "the target is machine-qualified"
  assert_grep "hc_clone=$VROOT/code/proj" "$meta" "the record names the clone there"
  assert_grep "hc_firstmate_as=firstmate-host" "$meta" "the record names the way back"
  assert_grep "hc_launch_file=$wt.launch." "$meta" "the record names the launch file staged there"
  assert_grep "worktree=$wt" "$meta" "the worktree is the one on the machine: $(cat "$meta")"
  [ "$("$REAL_GIT" -C "$D/remote/code/.fm-hc/$tag/$id" rev-parse --show-toplevel)" = "$D/remote/code/.fm-hc/$tag/$id" ] \
    || fail "the worktree was not created as a checkout on the machine"
  "$REAL_GIT" -C "$D/remote/code/proj" worktree list | grep -F "$D/remote/code/.fm-hc/$tag/$id" >/dev/null \
    || fail "the worktree is not a linked worktree of the clone there"
  assert_contains "$(grep '^run' "$D/log")" $'\x1f--on\x1fworker-host\x1f' "the terminal starts there"
  assert_contains "$(grep '^run' "$D/log")" $'--cwd\x1f'"$wt" "the terminal starts in the placed worktree"
  assert_not_contains "$(cat "$D/log")" "treehouse" "no treehouse runs for a placed task"
  launch=
  for f in "$D/remote/code/.fm-hc/$tag/"*.launch.*.sh; do [ -e "$f" ] && { launch=$f; break; }; done
  [ -n "$launch" ] || fail "the launch file was not staged on the machine"
  assert_grep "command rm -f -- '$VROOT/code/.fm-hc/$tag/$id.launch." "$launch" "the launch removes itself there"
  assert_grep "hc file read --on firstmate-host" "$launch" "the launch prompt says how to read the brief from there"
  assert_no_grep "--add-dir" "$launch" "no local directory is granted to a worker that cannot see it"
  assert_no_grep "$HOMEDIR/state/$id.git-hooks" "$launch" "no local git hooks reach the placed worker"
  assert_contains "$(grep '^send' "$D/log")" ". '$VROOT/code/.fm-hc/$tag/$id.launch." "the pane sources the launch file there"
  assert_absent "$HOMEDIR/state/$id.busy-gen" "a placed worker gets no busy record nothing there could clear"
  record=$(grep -l 'Machine placement' "$HOMEDIR/state/operational-inbox/"*.msg 2>/dev/null | head -1)
  [ -n "$record" ] || fail "the launch brief record does not carry the placement section"
  assert_grep "hc exec --on firstmate-host -- sh -c" "$record" "the brief says how to run Firstmate-path commands"
  assert_grep "brief for $id" "$record" "the brief itself follows the placement section"
  pass "hc placement: a placed scout gets its worktree, terminal, and launch on the machine, and its brief stays here"
}

test_placed_spawn_refuses_before_creating_anything() {
  local id out rc
  id=refuse1
  placed_spawn_case refuse-disconnected "$id"
  printf '{"machines":[{"name":"worker-host","state":"disconnected","version":"0.1.18"}]}\n' > "$D/machines.json"
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
  assert_contains "$out" "does not reach this machine as 'firstmate-host'" "the refusal names the missing route back"
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

  id=refuse-claude
  placed_spawn_case refuse-claude "$id"
  rm -f "$D/remote-bin/claude"
  rc=0
  out=$(run_placed_spawn "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "a machine whose login shell cannot run claude must refuse the spawn"
  assert_contains "$out" "claude does not run on hc machine 'worker-host'" "the refusal names the machine and what failed"
  assert_no_grep $'run\x1f' "$D/log" "no terminal may start where claude cannot run"
  assert_absent "$HOMEDIR/state/$id.meta" "no record may be written where claude cannot run"
  assert_absent "$D/remote/code/.fm-hc" "no worktree may be created where claude cannot run"

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
  out=$(run_placed_spawn "$id" --hc-machine worker-host) || rc=$?
  [ "$rc" -ne 0 ] || fail "--hc-machine without config/hc-machine must refuse"
  assert_contains "$out" "needs config/hc-machine" "the refusal names the missing declaration"
  assert_no_grep $'run\x1f' "$D/log" "no terminal may start on an undeclared machine"
  pass "hc placement: a machine that is down, cannot run claude, lacks the clone, the route back, or trust, or an unsupported harness, refuses before anything is created"
}

# A launch file whose write landed there although hc lost the answer aborts the
# spawn before the launch is sent. Oracle: the abort closes the terminal, so
# nothing there may source the file any more, and it must not outlive the
# spawn beside a worktree that is itself removed.
test_placed_spawn_abort_removes_its_launch_file_there() {
  local id=abort1 out rc=0 tag f
  placed_spawn_case spawn-abort "$id"
  tag=$(hometag_for "$HOMEDIR")
  touch "$D/file-write-lost"
  out=$(run_placed_spawn "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "a launch file whose write was not confirmed must abort the spawn"$'\n'"$out"
  assert_contains "$out" "could not stage the launch command" "the abort names the launch file"
  assert_grep $'kill\x1f--json\x1fworker-host/t9' "$D/log" "the abort closes the terminal there"
  for f in "$D/remote/code/.fm-hc/$tag/"*.launch.*; do
    [ -e "$f" ] && fail "the staged launch file must be removed there after the abort: $f"
  done
  assert_absent "$D/remote/code/.fm-hc/$tag/$id" "the fresh worktree there is removed"
  assert_absent "$HOMEDIR/state/$id.meta" "no record survives the abort"
  pass "hc placement: an aborted placed spawn removes its staged launch file there once its terminal is closed"
}

# Oracle: a placed ship is built like a placed scout, on the machine, and is
# recorded as a ship with its delivery contract; the commit hooks that live in
# this machine's checkout are not installed for a worker that cannot run them.
test_placed_ship_spawn_builds_everything_on_the_machine() {
  local id=ship1 out rc=0 tag wt meta
  placed_spawn_case spawn-ship "$id"
  tag=$(hometag_for "$HOMEDIR")
  wt="$VROOT/code/.fm-hc/$tag/$id"
  out=$(PLACED_SHIP=1 run_placed_spawn "$id" 2>&1) || rc=$?
  expect_code 0 "$rc" "a placed ship spawn should succeed"$'\n'"$out"
  meta="$HOMEDIR/state/$id.meta"
  assert_grep "kind=ship" "$meta" "the record is a ship's"
  assert_grep "mode=no-mistakes" "$meta" "the record carries the ship's delivery mode"
  assert_grep "hc_machine=worker-host" "$meta" "the record names the machine"
  assert_grep "worktree=$wt" "$meta" "the ship's worktree is the one on the machine: $(cat "$meta")"
  [ "$("$REAL_GIT" -C "$D/remote/code/.fm-hc/$tag/$id" rev-parse --show-toplevel)" = "$D/remote/code/.fm-hc/$tag/$id" ] \
    || fail "the ship's worktree was not created as a checkout on the machine"
  assert_contains "$(grep '^run' "$D/log")" $'\x1f--on\x1fworker-host\x1f' "the ship's terminal starts there"
  assert_absent "$HOMEDIR/state/$id.git-hooks" "no hooks from this machine's checkout are installed for a placed ship"
  assert_absent "$HOMEDIR/state/$id.push-guard" "no push guard from this machine is written for a placed ship"
  pass "hc placement: a placed ship gets its worktree and terminal on the machine, recorded as a ship"
}

# Oracle: hc started the terminal, but its answer was lost, so this spawn never
# learned its address. An unknown address is no proof that no terminal is
# there, so the abort must not remove the worktree a shell may be sitting in;
# it keeps both and names them.
test_placed_spawn_keeps_its_worktree_when_the_terminal_answer_is_lost() {
  local id=lost1 out rc=0 tag
  placed_spawn_case spawn-run-lost "$id"
  tag=$(hometag_for "$HOMEDIR")
  touch "$D/run-answer-lost"
  out=$(run_placed_spawn "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "a terminal whose answer was lost must abort the spawn"$'\n'"$out"
  assert_present "$D/worker-host/t9.json" "the fake started the terminal there"
  assert_present "$D/remote/code/.fm-hc/$tag/$id" "the worktree there must stay while its terminal may still be open"
  assert_contains "$out" "address unknown" "the warning says the terminal's address is unknown"
  assert_contains "$out" "worktree remove $VROOT/code/.fm-hc/$tag/$id" "the warning names how to remove the worktree there"
  assert_absent "$HOMEDIR/state/$id.meta" "no record survives the abort"
  pass "hc placement: a placed spawn that lost its terminal's answer keeps the worktree there and names both"
}

# Oracle: the worktree path was proved absent, then another checkout took it
# before this spawn's git worktree add ran. That checkout is not this spawn's,
# so the failed spawn must leave it, its work, and its branch, and start nothing.
test_placed_spawn_failed_add_leaves_a_foreign_worktree() {
  local id=race1 out rc=0 tag wt
  placed_spawn_case spawn-add-race "$id"
  tag=$(hometag_for "$HOMEDIR")
  wt="$D/remote/code/.fm-hc/$tag/$id"
  mkdir -p "$D/racebin"
  cat > "$D/racebin/git" <<SH
#!/bin/sh
case " \$* " in
  *" worktree add "*"$VROOT/code/.fm-hc/"*|*" worktree add "*"$D/remote/code/.fm-hc/"*)
    "$REAL_GIT" -C "$D/remote/code/proj" worktree add --quiet -b other-work "$wt" origin/main >/dev/null 2>&1 || exit 97
    echo "their work" > "$wt/theirs.txt" ;;
esac
exec "$REAL_GIT" "\$@"
SH
  chmod +x "$D/racebin/git"
  out=$(PATH="$D/racebin:$PATH" run_placed_spawn "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "a spawn whose worktree path was taken must fail"$'\n'"$out"
  assert_contains "$out" "could not add worktree" "the refusal names the failed add"
  [ -f "$wt/theirs.txt" ] || fail "the other checkout's work must survive the failed spawn"$'\n'"$out"
  "$REAL_GIT" -C "$D/remote/code/proj" rev-parse --verify --quiet refs/heads/other-work >/dev/null \
    || fail "the other checkout's branch must survive the failed spawn"
  assert_no_grep $'run\x1f' "$D/log" "no terminal may start for a failed spawn"
  assert_absent "$HOMEDIR/state/$id.meta" "no record may be written for a failed spawn"
  pass "hc placement: a placed spawn whose add fails leaves the checkout it did not make, with its work and branch"
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
  out=$(hc_shell 'fm_backend_hc_remote_clone_check fmtest worker-host /fm-remote-root/link/proj "'"$D/proj"'"' 2>&1) || rc=$?
  expect_code 0 "$rc" "a clone reached through a symlinked projects path is the clone: $out"
  assert_equals "$VROOT/code/proj" "$out" "the check reports the clone's physical path there"
  rc=0
  out=$(hc_shell 'fm_backend_hc_remote_clone_check fmtest worker-host /fm-remote-root/link/nosuch "'"$D/proj"'"' 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a symlinked path with no clone behind it must be refused"
  assert_contains "$out" "no clone of this project" "the refusal names the missing clone"

  placed_spawn_case clone-link-spawn "$id"
  ln -s "$D/remote/code" "$D/remote/link"
  printf 'worker-host\nfirstmate-as firstmate-host\nprojects %s/link\n' "$VROOT" > "$HOMEDIR/config/hc-machine"
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
  # A launch file the pane never sourced, left beside the worktree there.
  TLAUNCH_LOCAL="$D/remote/code/.fm-hc/$tag/task-x1.launch.s1.sh"
  printf 'claude\n' > "$TLAUNCH_LOCAL"
  git_q -C "$D/remote/code/proj" worktree add -q -b fm/task-x1 "$TWT_LOCAL" origin/main
  mkdir -p "$D/worker-host"
  jq -n --arg h "$tag" '{address: "worker-host/t9", state: "live",
    labels: {"firstmate.task": "fm-task-x1", "firstmate.home": $h},
    foreground: {name: "zsh", argv: ["zsh"], cwd: "/x", pid: 1}}' > "$D/worker-host/t9.json"
  fm_write_meta "$HOMEDIR/state/task-x1.meta" \
    "window=fmtest:worker-host/t9" "endpoint_task_id=task-x1" "worktree=$TWT" \
    "project=$D/proj" "harness=claude" "kind=ship" "mode=no-mistakes" \
    "spawn_gen=placed-teardown-test" "backend=hc" "hc_session=fmtest" \
    "hc_terminal=worker-host/t9" "hc_machine=worker-host" "hc_firstmate_as=firstmate-host" \
    "hc_clone=$VROOT/code/proj" "hc_launch_file=$VROOT/code/.fm-hc/$tag/task-x1.launch.s1.sh"
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
  assert_contains "$out" "cannot reach hc machine 'worker-host'" "the refusal names the unreachable machine"
  assert_contains "$out" "once that machine is reachable again" "the refusal says the task waits for that machine"
  assert_not_contains "$out" "--force" "the refusal must not offer --force, which also refuses while that machine is unreachable"
  assert_present "$HOMEDIR/state/task-x1.meta" "the record must survive an unreachable machine"
  assert_present "$TWT_LOCAL" "the worktree there must survive an unreachable machine"
  pass "hc placement: teardown refuses uncommitted, unlanded, or unreachable work on the machine and keeps every record"
}

# A placed close also fails while the machine answers: here the terminal there
# lacks this task's labels (fm_backend_hc_kill's foreign refusal). Oracle:
# docs/hc-backend.md, only an unreachable machine defeats --force, so the hint
# must still offer --force rather than only telling the operator to reconnect.
test_placed_teardown_close_failure_on_a_reachable_machine_offers_force() {
  local out rc
  placed_teardown_case teardown-close-foreign
  git_q -C "$TWT_LOCAL" commit -q --allow-empty -m "pushed" && git_q -C "$TWT_LOCAL" push -q origin fm/task-x1
  jq '.labels["firstmate.task"] = "fm-someone-else"' "$D/worker-host/t9.json" > "$D/t9.tmp" \
    && mv "$D/t9.tmp" "$D/worker-host/t9.json"
  rc=0
  out=$(run_placed_teardown 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a placed close that fails must refuse cleanup"$'\n'"$out"
  assert_contains "$out" "could not be closed" "the refusal names the failed close"
  assert_contains "$out" "rerun with --force" "a reachable machine's failed close still offers --force"
  assert_present "$HOMEDIR/state/task-x1.meta" "the record survives a failed close"
  assert_present "$TWT_LOCAL" "the worktree there survives a failed close"
  pass "hc placement: a placed close that fails on a reachable machine refuses, keeps the record, and still offers --force"
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
  assert_grep $'kill\x1f--json\x1fworker-host/t9' "$D/log" "the terminal there is ended"
  assert_absent "$D/worker-host/t9.json" "the terminal there is removed"
  assert_absent "$HOMEDIR/state/task-x1.meta" "the record is retired"
  assert_absent "$TLAUNCH_LOCAL" "the staged launch file there is removed"
  assert_absent "$VROOT" "nothing was created under the placed path on this machine"

  placed_teardown_case teardown-force
  printf 'discard me\n' > "$TWT_LOCAL/scratch.txt"
  rc=0
  out=$(run_placed_teardown --force 2>&1) || rc=$?
  expect_code 0 "$rc" "--force discards the work there as it does here"$'\n'"$out"
  assert_absent "$TWT_LOCAL" "the forced worktree there is removed"
  pass "hc placement: teardown removes a placed worktree there only after proving its work landed, or under --force"
}

# Oracle: a placed ship's copy and its no-mistakes runs are on the other
# machine, so with config/pipeline-spend on, its cleanup must not write a spend
# entry read from a copy that is not here.
test_placed_teardown_records_no_spend_here() {
  local out rc=0
  placed_teardown_case teardown-spend
  git_q -C "$TWT_LOCAL" commit -q --allow-empty -m "the change"
  git_q -C "$TWT_LOCAL" push -q origin fm/task-x1
  touch "$HOMEDIR/config/pipeline-spend"
  out=$(run_placed_teardown 2>&1) || rc=$?
  expect_code 0 "$rc" "pushed work on the machine should clean up"$'\n'"$out"
  assert_absent "$HOMEDIR/data/pipeline-spend.jsonl" "no spend entry is written for a placed ship"
  assert_absent "$HOMEDIR/state/task-x1.meta" "the record is retired"
  pass "hc placement: a placed ship's cleanup writes no pipeline spend entry here"
}

# fake_nm_there <head> <abort-works 1|0>: a no-mistakes on the machine whose
# run R1, on the task branch at <head>, is parked at a gate until aborted.
fake_nm_there() {
  cat > "$FB/no-mistakes" <<SH
#!/usr/bin/env bash
case "\$*" in
  "axi abort --run R1") [ "$2" = 0 ] || touch "$D/nm-aborted"; exit 0 ;;
  "axi status"|"axi status --run R1")
    if [ -e "$D/nm-aborted" ]; then
      printf 'run:\n  id: "R1"\n  branch: fm/task-x1\n  status: cancelled\n  head: $1\noutcome: cancelled\n'
    else
      printf 'run:\n  id: "R1"\n  branch: fm/task-x1\n  status: awaiting_approval\n  head: $1\ngate:\n  step: review\n'
    fi ;;
esac
exit 0
SH
  chmod +x "$FB/no-mistakes"
}

# Oracle: the header's Fix 1 - a ship's own run parked at a gate is aborted
# before its worker is removed, and a run still parked afterwards refuses -
# applied to the machine that run's daemon is on.
test_placed_teardown_aborts_its_parked_no_mistakes_run_there() {
  local out rc head
  placed_teardown_case teardown-nm
  git_q -C "$TWT_LOCAL" commit -q --allow-empty -m "the change"
  git_q -C "$TWT_LOCAL" push -q origin fm/task-x1
  head=$("$REAL_GIT" -C "$TWT_LOCAL" rev-parse HEAD)
  fake_nm_there "$head" 1
  rc=0
  out=$(run_placed_teardown 2>&1) || rc=$?
  expect_code 0 "$rc" "a parked run there is aborted and cleanup goes on"$'\n'"$out"
  assert_present "$D/nm-aborted" "the parked run there was aborted"
  assert_contains "$(grep '^exec' "$D/log")" $'no-mistakes\x1faxi\x1fabort\x1f--run\x1fR1' "the abort runs through hc on the machine"
  assert_absent "$TWT_LOCAL" "the worktree there is removed after the abort"

  placed_teardown_case teardown-nm-stuck
  git_q -C "$TWT_LOCAL" commit -q --allow-empty -m "the change"
  git_q -C "$TWT_LOCAL" push -q origin fm/task-x1
  head=$("$REAL_GIT" -C "$TWT_LOCAL" rev-parse HEAD)
  fake_nm_there "$head" 0
  rc=0
  out=$(run_placed_teardown 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a run still parked after the abort must refuse cleanup"$'\n'"$out"
  assert_contains "$out" "still parked after axi abort" "the refusal names the parked run"
  assert_present "$HOMEDIR/state/task-x1.meta" "the record survives a run that would not stop"
  assert_present "$TWT_LOCAL" "the worktree there survives a run that would not stop"
  pass "hc placement: teardown aborts a placed ship's parked no-mistakes run on its machine, or refuses"
}

# Oracle: docs/hc-backend.md "Limits of a placed worker" - no relaunch path
# reaches a placed worker; it refuses and stops nothing there.
test_placed_relaunch_refuses_and_stops_nothing() {
  local out rc
  placed_teardown_case relaunch
  mkdir -p "$HOMEDIR/data/task-x1"
  printf 'brief\n' > "$HOMEDIR/data/task-x1/brief.md"
  rc=0
  out=$(FAKE_HC_DIR=$D FM_HC_BIN="$FB/hc" FM_HOME=$HOMEDIR FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$HOMEDIR/state" FM_DATA_OVERRIDE="$HOMEDIR/data" \
    FM_CONFIG_OVERRIDE="$HOMEDIR/config" PATH="$FB:$PATH" \
    "$ROOT/bin/fm-control.sh" task-x1 relaunch --note "pick up where it stopped" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "relaunching a placed worker must refuse"$'\n'"$out"
  assert_contains "$out" "refusing" "the refusal says so"$'\n'"$out"
  assert_no_grep $'kill\x1f' "$D/log" "nothing there is stopped"
  assert_no_grep $'send\x1f' "$D/log" "nothing is typed there"
  assert_present "$TWT_LOCAL" "the worktree there is untouched"
  pass "hc placement: relaunch refuses a placed worker and stops nothing there"
}

# A disowned job the worker left running in its worktree survives the close of
# its terminal (fm-teardown.sh header, Fix 2). Oracle: the local reap's own
# contract, every process whose cwd is under the worktree is stopped before the
# worktree is removed; a scan that cannot run there proves nothing, so the
# teardown refuses and keeps every record.
test_placed_teardown_reaps_processes_left_in_the_worktree_there() {
  local out rc pid i
  placed_teardown_case teardown-reap
  rm -f "$FB/lsof"
  git_q -C "$TWT_LOCAL" commit -q --allow-empty -m "the change"
  git_q -C "$TWT_LOCAL" push -q origin fm/task-x1
  mkdir -p "$TWT_LOCAL/build"
  pid=$(bash -c 'cd "$1" && { sleep 300 >/dev/null 2>&1 </dev/null & echo $!; }' _ "$TWT_LOCAL/build")
  kill -0 "$pid" 2>/dev/null || fail "the stand-in job did not start"
  rc=0
  out=$(run_placed_teardown 2>&1) || rc=$?
  for i in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$pid" 2>/dev/null || break; sleep 0.2; done
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null || true
    fail "a job left under the placed worktree must be stopped by teardown"$'\n'"$out"
  fi
  expect_code 0 "$rc" "a placed teardown with a leftover job should succeed once it is stopped"$'\n'"$out"
  assert_contains "$out" "reaped leaked worktree process(es) on hc machine 'worker-host': $pid" "the reap names the stopped job"
  assert_absent "$TWT_LOCAL" "the worktree there is removed after the reap"

  placed_teardown_case teardown-reap-blind
  git_q -C "$TWT_LOCAL" commit -q --allow-empty -m "the change"
  git_q -C "$TWT_LOCAL" push -q origin fm/task-x1
  printf -- '-d cwd' > "$D/exec-refuse"
  rc=0
  out=$(run_placed_teardown 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a process scan that cannot run there must refuse the teardown"$'\n'"$out"
  assert_contains "$out" "cannot reach hc machine 'worker-host' to stop processes" "the refusal names the scan that could not run"
  assert_present "$HOMEDIR/state/task-x1.meta" "the record survives a refused reap"
  assert_present "$TWT_LOCAL" "the worktree there survives a refused reap"
  pass "hc placement: teardown stops processes left under a placed worktree there, and refuses when it cannot scan for them"
}

# A pid the scan found can exit and be reused by an unrelated process before a
# signal lands. Oracle: the local reap's contract (task_process_identity_matches
# in fm-teardown.sh), a pid is signalled only while its start identity still
# matches the one read at the scan. The fake lsof reports the stand-in under the
# worktree there on the first scan only, and the fake ps reports a different
# start time after the first read, as a reused pid would; the stand-in, sitting
# outside the worktree, must survive. Code that signals every scanned pid kills it.
test_placed_teardown_reap_skips_a_reused_pid() {
  local out rc pid real_ps wt_phys
  placed_teardown_case teardown-reap-reused
  git_q -C "$TWT_LOCAL" commit -q --allow-empty -m "the change"
  git_q -C "$TWT_LOCAL" push -q origin fm/task-x1
  pid=$(bash -c 'cd "$1" && { sleep 300 >/dev/null 2>&1 </dev/null & echo $!; }' _ "$D")
  kill -0 "$pid" 2>/dev/null || fail "the stand-in job did not start"
  wt_phys=$(cd "$TWT_LOCAL" && pwd -P)
  real_ps=$(command -v ps)
  cat > "$FB/lsof" <<SH
#!/usr/bin/env bash
if [ "\$PWD" = "$D/remote" ] && [ ! -e "$D/lsof-seen" ]; then
  : > "$D/lsof-seen"
  printf 'p%s\nn%s\n' "$pid" "$wt_phys"
fi
exit 0
SH
  cat > "$FB/ps" <<SH
#!/usr/bin/env bash
if [ "\$*" = "-p $pid -o lstart=" ]; then
  if [ -e "$D/ps-seen" ]; then echo "Tue Jan  6 00:00:00 2026"; else : > "$D/ps-seen"; echo "Mon Jan  5 00:00:00 2026"; fi
  exit 0
fi
exec "$real_ps" "\$@"
SH
  chmod +x "$FB/lsof" "$FB/ps"
  mkdir -p "$D/no-proc"
  rc=0
  out=$(FM_PROC_ROOT_OVERRIDE="$D/no-proc" run_placed_teardown 2>&1) || rc=$?
  sleep 0.3
  if ! kill -0 "$pid" 2>/dev/null; then
    fail "a reused pid must not be signalled by the placed reap"$'\n'"$out"
  fi
  kill -KILL "$pid" 2>/dev/null || true
  [ -e "$D/ps-seen" ] || fail "the reap never read the scanned pid's start identity"$'\n'"$out"
  expect_code 0 "$rc" "a placed teardown whose scanned pid was reused should succeed"$'\n'"$out"
  assert_absent "$TWT_LOCAL" "the worktree there is removed"
  pass "hc placement: the placed reap skips a pid reused after its scan"
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
  assert_contains "$out" "worktree gone on hc machine worker-host" "a placed worktree removed there reads as gone"
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
  assert_contains "$out" "unreachable outside the worker copy on hc machine 'worker-host'" "the refusal names the unpushed head there"
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
  test_remote_exec_keeps_bytes_and_refuses_undecodable_output \
  test_placed_default_branch_is_read_from_origin \
  test_placed_worktree_add_failure_removes_what_it_made \
  test_placed_worktree_add_failure_leaves_a_foreign_worktree \
  test_machine_readiness_gates_connection_and_versions \
  test_create_task_places_the_terminal_on_the_machine \
  test_remote_agent_state_reads_the_group_there \
  test_placed_busy_state_reads_hc_native_status \
  test_placed_spawn_builds_everything_on_the_machine \
  test_placed_spawn_refuses_before_creating_anything \
  test_placed_spawn_abort_removes_its_launch_file_there \
  test_placed_ship_spawn_builds_everything_on_the_machine \
  test_placed_spawn_keeps_its_worktree_when_the_terminal_answer_is_lost \
  test_placed_spawn_failed_add_leaves_a_foreign_worktree \
  test_placed_clone_check_resolves_a_symlinked_projects_path \
  test_placed_teardown_refuses_unlanded_or_unreachable_work \
  test_placed_teardown_close_failure_on_a_reachable_machine_offers_force \
  test_placed_teardown_removes_landed_work_there \
  test_placed_teardown_records_no_spend_here \
  test_placed_teardown_aborts_its_parked_no_mistakes_run_there \
  test_placed_relaunch_refuses_and_stops_nothing \
  test_placed_teardown_reaps_processes_left_in_the_worktree_there \
  test_placed_teardown_reap_skips_a_reused_pid \
  test_placed_done_gate_reads_the_head_there \
  test_placed_crew_state_reads_the_worktree_there
