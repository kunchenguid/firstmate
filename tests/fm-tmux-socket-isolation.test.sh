#!/usr/bin/env bash
# tests/fm-tmux-socket-isolation.test.sh - dedicated tmux socket for worker
# endpoints, and the provable-death reclaim it unlocks.
#
# Two layers, mirroring the feature:
#   A. The addressing contract (pure): fm_tmux routes every tmux invocation
#      through one owner; FM_TMUX_SOCKET scopes it to `tmux -L <name>`;
#      fm_tmux_fleet_socket resolves the configured name; fm-backend.sh reads
#      and validates the new socket= task-record field, keeping a record
#      without it a LEGACY record with unchanged behavior.
#   B/C. Real tmux on PRIVATE sockets only (never the host's default server):
#      scoped addressing isolates windows between two sockets; the death-proof
#      primitives (socket holder/process evidence, worktree live-pid scan) and
#      the composed fm_control_endpoint_absence_verdict answer gone/unproven
#      per conjunct.
#   D. The reclaim end to end (fake tmux, two-server model): a socket=
#      record whose server is provably dead rebinds through
#      `fm-control.sh relaunch` onto the RECORDED socket; a legacy record
#      refuses exactly as it always did; a surviving worktree process refuses
#      naming the survivor.
#
# Skips: B/C need a real tmux; D needs real lsof+pgrep (the proof itself must
# run - faking it would only re-assert the stub's own assumptions). A always
# runs.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-control-lib.sh"

CONTROL="$ROOT/bin/fm-control.sh"
SEND="$ROOT/bin/fm-send.sh"
PEEK="$ROOT/bin/fm-peek.sh"

TMP_ROOT=$(fm_test_tmproot fm-tmux-socket-isolation)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
TASK_TMPS=()

suite_cleanup() {
  local d
  for d in "${TASK_TMPS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
  rm -rf "$TMP_ROOT"
}
trap suite_cleanup EXIT

HAVE_TMUX=0
command -v tmux >/dev/null 2>&1 && HAVE_TMUX=1
REAL_TMUX=$(command -v tmux || true)
HAVE_PROOF_TOOLS=0
command -v lsof >/dev/null 2>&1 && command -v pgrep >/dev/null 2>&1 && HAVE_PROOF_TOOLS=1

# --- A. addressing contract --------------------------------------------------

test_fm_tmux_routes_every_invocation_through_one_owner() {
  local dir
  dir="$TMP_ROOT/a1"; mkdir -p "$dir/bin"
  cat > "$dir/bin/tmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$FM_FAKE_TMUX_ARGV"
SH
  chmod +x "$dir/bin/tmux"
  # shellcheck source=/dev/null
  ( . "$ROOT/bin/fm-tmux-lib.sh"
    FM_FAKE_TMUX_ARGV="$dir/argv"
    export FM_FAKE_TMUX_ARGV
    PATH="$dir/bin:$PATH"
    FM_TMUX_SOCKET=fleet-a fm_tmux list-windows -a
    [ "$(cat "$dir/argv")" = "-L fleet-a list-windows -a" ] || exit 11
    FM_TMUX_SOCKET='' fm_tmux list-windows -a
    [ "$(cat "$dir/argv")" = "list-windows -a" ] || exit 12
    unset FM_TMUX_SOCKET
    fm_tmux has-session -t firstmate
    [ "$(cat "$dir/argv")" = "has-session -t firstmate" ] || exit 13
    exit 0 ) || fail "fm_tmux must scope every invocation to -L <name> only when FM_TMUX_SOCKET is set"
  pass "fm_tmux: one owner, -L routing only under an explicit scope"

  # The adapter's own call sites must all route through the owner: every
  # command the tmux adapter runs must appear in argv recordings made with a
  # scoped socket, proving no bare tmux invocation can slip past the scope.
  local sock="a1fleet-$$" shim
  shim="$TMP_ROOT/a1-shim"; mkdir -p "$shim"
  cat > "$shim/tmux" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$shim/argv"
exec "$REAL_TMUX" -f /dev/null -L "$sock" "\$@"
SH
  chmod +x "$shim/tmux"
  [ "$HAVE_TMUX" = 1 ] || { pass "fm_tmux: adapter scope audit (skipped: no real tmux)"; return 0; }
  (
    PATH="$shim:$PATH"
    FM_TMUX_SOCKET=$sock
    export FM_TMUX_SOCKET PATH
    . "$ROOT/bin/fm-backend.sh"
    fm_backend_source tmux || exit 20
    : > "$shim/argv"
    fm_backend_tmux_container_ensure >/dev/null || exit 21
    fm_backend_tmux_create_task firstmate "fm-a1" "$TMP_ROOT" >/dev/null || exit 22
    fm_backend_tmux_capture "firstmate:fm-a1" 5 >/dev/null || exit 23
    fm_backend_tmux_target_exists "firstmate:fm-a1" || exit 24
    fm_backend_tmux_current_command "firstmate:fm-a1" >/dev/null || exit 25
    fm_backend_tmux_agent_state "firstmate:fm-a1" >/dev/null || exit 26
    "$REAL_TMUX" -L "$sock" kill-server 2>/dev/null || true
    grep -q "^-L $sock" "$shim/argv" || exit 27
    if grep -qvE "^-L $sock " "$shim/argv"; then
      # every recorded invocation began with -L <sock>
      exit 28
    fi
    exit 0
  ) || fail "every adapter call under a scope must be recorded with the -L prefix (audit rc=$?)"
  pass "fm_tmux: every scoped adapter call carries the -L prefix"
}

test_fm_tmux_fleet_socket_resolution() {
  local dir
  dir="$TMP_ROOT/a2"; mkdir -p "$dir/cfg"
  # shellcheck source=/dev/null
  ( . "$ROOT/bin/fm-tmux-lib.sh"
    [ "$(fm_tmux_fleet_socket "$dir/cfg")" = firstmate ] || exit 11
    printf 'captains-fleet\n' > "$dir/cfg/fleet-tmux-socket"
    [ "$(fm_tmux_fleet_socket "$dir/cfg")" = captains-fleet ] || exit 12
    FM_FLEET_TMUX_SOCKET=env-fleet
    export FM_FLEET_TMUX_SOCKET
    [ "$(fm_tmux_fleet_socket "$dir/cfg")" = env-fleet ] || exit 13
    exit 0 ) || fail "fm_tmux_fleet_socket must resolve env > config > firstmate default"
  pass "fm_tmux_fleet_socket: env beats config beats the firstmate default"

  # shellcheck source=/dev/null
  ( . "$ROOT/bin/fm-tmux-lib.sh"
    printf 'bad name!\n' > "$dir/cfg/fleet-tmux-socket"
    unset FM_FLEET_TMUX_SOCKET || true
    if fm_tmux_fleet_socket "$dir/cfg" 2>/dev/null; then exit 11; fi
    FM_FLEET_TMUX_SOCKET='x'
    export FM_FLEET_TMUX_SOCKET
    if fm_tmux_fleet_socket "$dir/cfg" 2>/dev/null; then exit 12; fi
    exit 0 ) || fail "fm_tmux_fleet_socket must refuse malformed names, not pass them to tmux"
  pass "fm_tmux_fleet_socket: malformed config or env name refuses loudly"
}

test_socket_meta_round_trip_and_validation() {
  local dir meta
  dir="$TMP_ROOT/a3"; mkdir -p "$dir"
  meta="$dir/t1.meta"
  cat > "$meta" <<EOF
window=firstmate:fm-t1
endpoint_task_id=t1
worktree=$dir/wt
project=$dir/proj
harness=claude
kind=ship
socket=fleet-rt
EOF
  mkdir -p "$dir/wt" "$dir/proj"
  [ "$(fm_backend_tmux_socket_of_meta "$meta")" = fleet-rt ] \
    || fail "socket= must round-trip through fm_backend_tmux_socket_of_meta"
  fm_backend_validate_task_endpoint "$meta" t1 || fail "a well-formed socket= record must validate"
  FM_BACKEND_VALIDATED_BACKEND='' FM_BACKEND_VALIDATED_TARGET=''

  # Legacy record: no socket line at all - same validation pass, empty scope.
  grep -v '^socket=' "$meta" > "$dir/t1-legacy.meta"
  [ -z "$(fm_backend_tmux_socket_of_meta "$dir/t1-legacy.meta")" ] \
    || fail "a record without socket= must read as an empty (legacy/ambient) scope"
  fm_backend_validate_task_endpoint "$dir/t1-legacy.meta" t1 \
    || fail "a legacy record without socket= must keep validating unchanged"

  # Malformed shapes refuse.
  sed 's/^socket=fleet-rt/socket=bad name/' "$meta" > "$dir/bad-chars.meta"
  if fm_backend_validate_task_endpoint "$dir/bad-chars.meta" t1 2>/dev/null; then
    fail "socket= with spaces must refuse validation"
  fi
  long_name=$(printf 'a%.0s' $(seq 1 65))
  sed "s/^socket=fleet-rt/socket=$long_name/" "$meta" > "$dir/long.meta"
  if fm_backend_validate_task_endpoint "$dir/long.meta" t1 2>/dev/null; then
    fail "socket= longer than 64 chars must refuse validation"
  fi
  { cat "$meta"; echo 'socket=second-line'; } > "$dir/dup.meta"
  if fm_backend_validate_task_endpoint "$dir/dup.meta" t1 2>/dev/null; then
    fail "two socket= lines must refuse validation as ambiguous"
  fi
  sed 's/^socket=fleet-rt/socket=fleet-rt/; s/^harness=claude/harness=claude\nbackend=herdr/' "$meta" > "$dir/wrong-backend.meta"
  if fm_backend_validate_task_endpoint "$dir/wrong-backend.meta" t1 2>/dev/null; then
    fail "socket= on a non-tmux record must refuse validation"
  fi
  pass "socket=: round-trips, validates, and refuses malformed/ambiguous/foreign shapes"
}

# --- B. real-tmux scoped addressing ------------------------------------------

test_real_tmux_scoped_addressing_isolates_servers() {
  [ "$HAVE_TMUX" = 1 ] || { pass "scoped addressing isolation (skipped: no real tmux)"; return 0; }
  local sockA="fmiso-a-$$" sockB="fmiso-b-$$" out ses
  cleanup_isolation() { tmux -L "$sockA" kill-server 2>/dev/null || true; tmux -L "$sockB" kill-server 2>/dev/null || true; }
  trap 'cleanup_isolation; suite_cleanup' EXIT

  tmux -L "$sockA" new-session -d -s firstmate -x 120 -y 30 \
    || fail "real tmux: socket A session failed"
  tmux -L "$sockB" new-session -d -s firstmate -x 120 -y 30 \
    || fail "real tmux: socket B session failed"

  # Scoped container_ensure must NOT adopt an ambient session even when $TMUX
  # claims we run inside one: the scoped shape is always the dedicated
  # "firstmate" session ON THE SCOPED SOCKET.
  out=$(
    . "$ROOT/bin/fm-backend.sh"
    fm_backend_source tmux || exit 1
    TMUX=/tmp/fake-tmux-socket,1234,0
    export TMUX
    FM_TMUX_SOCKET=$sockA
    export FM_TMUX_SOCKET
    fm_backend_tmux_container_ensure
  ) || fail "scoped container_ensure failed"
  [ "$out" = firstmate ] || fail "scoped container_ensure must answer 'firstmate', got '$out'"
  tmux -L "$sockA" has-session -t firstmate 2>/dev/null \
    || fail "scoped container_ensure did not ensure the session on socket A"

  # Create the task window on A and prove B cannot see it.
  (
    . "$ROOT/bin/fm-backend.sh"
    fm_backend_source tmux || exit 1
    FM_TMUX_SOCKET=$sockA; export FM_TMUX_SOCKET
    fm_backend_tmux_create_task firstmate "fm-iso1" "$TMP_ROOT" >/dev/null || exit 1
    fm_backend_tmux_send_text_line "firstmate:fm-iso1" "printf 'iso-token-%s\\n' alpha" || exit 1
    sleep 1
    fm_backend_tmux_capture "firstmate:fm-iso1" 10 | grep -q 'iso-token-alpha' || exit 1
  ) || fail "scoped create/send/capture on socket A failed"

  # The same window name on B is a different, empty endpoint: scoped reads of
  # A's window through B prove physical isolation between the sockets.
  if (
    . "$ROOT/bin/fm-backend.sh"
    fm_backend_source tmux || exit 1
    FM_TMUX_SOCKET=$sockB; export FM_TMUX_SOCKET
    fm_backend_target_exists tmux "firstmate:fm-iso1"
  ); then
    fail "socket B must not see socket A's window"
  fi
  ses=$(
    . "$ROOT/bin/fm-backend.sh"
    fm_backend_source tmux || exit 1
    FM_TMUX_SOCKET=$sockB; export FM_TMUX_SOCKET
    fm_backend_tmux_agent_state "firstmate:fm-iso1"
  )
  [ "$ses" = missing ] \
    || fail "socket B must classify A's window as missing (absent on B), got '$ses'"

  # And the scoped kill on A removes it there without touching B's server.
  (
    . "$ROOT/bin/fm-backend.sh"
    fm_backend_source tmux || exit 1
    FM_TMUX_SOCKET=$sockA; export FM_TMUX_SOCKET
    fm_backend_tmux_kill "firstmate:fm-iso1" || exit 1
  ) || fail "scoped kill on socket A failed"
  ses=$(
    . "$ROOT/bin/fm-backend.sh"
    fm_backend_source tmux || exit 1
    FM_TMUX_SOCKET=$sockA; export FM_TMUX_SOCKET
    fm_backend_tmux_agent_state "firstmate:fm-iso1"
  )
  [ "$ses" = missing ] || fail "socket A must classify its killed window missing, got '$ses'"
  tmux -L "$sockB" has-session -t firstmate 2>/dev/null \
    || fail "socket B's server must survive socket A's kill"
  cleanup_isolation
  trap 'suite_cleanup' EXIT
  pass "real tmux: scoped addressing isolates create/read/kill between sockets"
}

test_real_tmux_death_proof_primitives() {
  [ "$HAVE_TMUX" = 1 ] || { pass "death-proof primitives (skipped: no real tmux)"; return 0; }
  [ "$HAVE_PROOF_TOOLS" = 1 ] || { pass "death-proof primitives (skipped: no lsof/pgrep)"; return 0; }
  local sock="fmprim-$$" wt="$TMP_ROOT/prim-wt" out
  mkdir -p "$wt"
  tmux -L "$sock" new-session -d -s firstmate -x 120 -y 30 \
    || fail "real tmux: primitive socket session failed"
  (
    . "$ROOT/bin/fm-tmux-lib.sh"
    fm_tmux_server_evidence "$sock" || exit 1
  ) || fail "a live server must produce positive evidence"
  tmux -L "$sock" kill-server 2>/dev/null || true
  sleep 1
  if (
    . "$ROOT/bin/fm-tmux-lib.sh"
    fm_tmux_server_evidence "$sock"
  ); then
    fail "a killed server must produce no evidence once its process is gone"
  fi

  ( cd "$wt" && exec sleep 30 ) &
  local sleeper=$!
  sleep 1
  out=$(
    . "$ROOT/bin/fm-tmux-lib.sh"
    fm_tmux_worktree_live_pids "$wt"
  ) || fail "the worktree live-pid scan failed on a readable host"
  case "$out" in
    *"$sleeper"*) : ;;
    *) kill "$sleeper" 2>/dev/null || true; fail "the sleeper's pid must appear in the worktree scan, got '$out'" ;;
  esac
  kill "$sleeper" 2>/dev/null || true
  wait "$sleeper" 2>/dev/null || true
  sleep 1
  out=$(
    . "$ROOT/bin/fm-tmux-lib.sh"
    fm_tmux_worktree_live_pids "$wt"
  ) || fail "the worktree live-pid scan must stay readable after the sleeper exits"
  [ -z "$out" ] || fail "an empty worktree must scan empty, got '$out'"
  out=$(
    . "$ROOT/bin/fm-tmux-lib.sh"
    fm_tmux_worktree_live_pids "$TMP_ROOT/no-such-dir"
  )
  [ -z "$out" ] || fail "a gone worktree cannot hold a cwd and must scan empty"
  pass "real tmux: server evidence and worktree live-pid scan prove both directions"
}

# --- C. the composed absence verdict on real sockets -------------------------

test_verdict_real_socket_gone_and_refusal_cases() {
  [ "$HAVE_TMUX" = 1 ] || { pass "absence verdict on real sockets (skipped: no real tmux)"; return 0; }
  [ "$HAVE_PROOF_TOOLS" = 1 ] || { pass "absence verdict on real sockets (skipped: no lsof/pgrep)"; return 0; }
  local sock="fmvdct-$$" wt="$TMP_ROOT/vdct-wt" meta="$TMP_ROOT/vdct.meta" verdict
  mkdir -p "$wt"
  cat > "$meta" <<EOF
window=firstmate:fm-vdct
endpoint_task_id=vdct
worktree=$wt
project=$TMP_ROOT
socket=$sock
EOF

  run_verdict() {
    (
      . "$ROOT/bin/fm-backend.sh"
      fm_backend_source tmux || exit 1
      . "$ROOT/bin/fm-control-lib.sh"
      fm_control_endpoint_absence_verdict tmux "firstmate:fm-vdct" "$meta"
    )
  }

  # Server alive + window present: the endpoint came back; verdict alive.
  tmux -L "$sock" new-session -d -s firstmate -n fm-vdct -x 120 -y 30 \
    || fail "real tmux: verdict socket session failed"
  sleep 1
  verdict=$(run_verdict)
  [ "${verdict%%$'\t'*}" = alive ] \
    || fail "a present window on a live recorded socket must read alive, got '$verdict'"

  # Server alive + window destroyed: absence of the WINDOW is proven, but the
  # server's death is not - reclaim stays refused. A second window keeps the
  # session (and its server) alive: destroying a session's LAST window takes
  # the whole server down (tmux exit-empty), which is the `gone` case below.
  tmux -L "$sock" new-window -d -t "firstmate:" -n fm-vdct-other \
    || fail "real tmux: companion window failed"
  tmux -L "$sock" kill-window -t "firstmate:=fm-vdct" 2>/dev/null || true
  sleep 1
  verdict=$(run_verdict)
  case "$verdict" in
    unproven*$'\t'*server*running*) : ;;
    *) fail "a live server with a destroyed window must refuse naming the live server, got '$verdict'" ;;
  esac

  # Session destroyed while its SERVER survives (a companion session keeps
  # it alive): the window reads definitively absent, but the server-death
  # proof fails on live evidence - reclaim stays refused.
  tmux -L "$sock" new-session -d -s other -x 120 -y 30 \
    || fail "real tmux: other session failed"
  tmux -L "$sock" kill-session -t firstmate 2>/dev/null || true
  sleep 1
  verdict=$(run_verdict)
  case "$verdict" in
    unproven*$'\t'*server*) : ;;
    *) fail "a destroyed session on a live server must refuse naming the live server, got '$verdict'" ;;
  esac
  tmux -L "$sock" kill-session -t other 2>/dev/null || true

  # Server dead + empty worktree: all three conjuncts hold - gone. (The
  # companion session goes down with its server here.)
  tmux -L "$sock" kill-server 2>/dev/null || true
  sleep 1
  verdict=$(run_verdict)
  [ "${verdict%%$'\t'*}" = gone ] \
    || fail "a provably dead server with an empty worktree must read gone, got '$verdict'"

  # Server dead + a surviving process in the worktree: the orphan guard
  # refuses and names the survivor.
  ( cd "$wt" && exec sleep 30 ) &
  local sleeper=$!
  sleep 1
  verdict=$(run_verdict)
  kill "$sleeper" 2>/dev/null || true
  wait "$sleeper" 2>/dev/null || true
  case "$verdict" in
    unproven*$'\t'*live*processes*) : ;;
    *) fail "a surviving worktree process must refuse the reclaim naming it, got '$verdict'" ;;
  esac

  # Legacy record (no socket=): the historic refusal, byte-for-byte shape.
  grep -v '^socket=' "$meta" > "$TMP_ROOT/vdct-legacy.meta"
  verdict=$(
    . "$ROOT/bin/fm-backend.sh"
    fm_backend_source tmux || exit 1
    . "$ROOT/bin/fm-control-lib.sh"
    fm_control_endpoint_absence_verdict tmux "firstmate:fm-vdct" "$TMP_ROOT/vdct-legacy.meta"
  )
  case "$verdict" in
    unproven*$'\t'*without*its\ socket\ identity*) : ;;
    *) fail "a legacy record must keep the historic unproven refusal, got '$verdict'" ;;
  esac

  # Unreadable socket (a tmux that answers with a NON-definitive failure -
  # the rc=1 inventory read): proves nothing.
  local unread_shim="$TMP_ROOT/unread-shim"
  mkdir -p "$unread_shim"
  cat > "$unread_shim/tmux" <<'SH'
#!/usr/bin/env bash
echo 'lost server' >&2
exit 1
SH
  chmod +x "$unread_shim/tmux"
  verdict=$(
    PATH="$unread_shim:$PATH"
    . "$ROOT/bin/fm-backend.sh"
    fm_backend_source tmux || exit 1
    . "$ROOT/bin/fm-control-lib.sh"
    fm_control_endpoint_absence_verdict tmux "firstmate:fm-vdct" "$meta"
  )
  case "$verdict" in
    unproven*$'\t'*could\ not\ be\ read*) : ;;
    *) fail "an unreadable socket must refuse as unproven, got '$verdict'" ;;
  esac
  pass "real tmux: the three-conjunct verdict answers alive/unproven/gone per case, and legacy refuses unchanged"
}

# --- D. reclaim through the control plane ------------------------------------

# A `-L`-aware variant of the fm-control-relaunch lifecycle stub: socket state
# lives per socket name (server alive marker, session and window lists), so a
# socket-isolated record can be modeled end to end. Only what the relaunch
# path exercises is modeled; anything else exits 0 silently, like the suites
# it borrows from.
make_socket_stub() {  # <dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
sock=default
while [ $# -gt 0 ]; do
  case "$1" in
    -L) sock=${2:-default}; shift 2 ;;
    *) break ;;
  esac
done
cmd=${1:-}; shift || true
alive() { [ -f "$D/server-$1-alive" ]; }
case "$cmd" in
  send-keys)
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    payload=${1:-}
    printf '%s\n' "$sock $payload" >> "$D/literal"
    if [ "$literal" = 1 ]; then
      case "$payload" in
        /exit|/quit)
          printf 'zsh' > "$D/command"
          ;;
        *'Firstmate operational input waiting: read'*)
          cat "$D/becomes" > "$D/command"
          ;;
      esac
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *cursor_y*) printf '1\n'; exit 0 ;;
        *pane_current_command*) cat "$D/command"; printf '\n'; exit 0 ;;
        *pane_current_path*) cat "$D/cwd"; printf '\n'; exit 0 ;;
      esac
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane)
    if [ -s "$D/composer" ]; then
      printf 'tail\n╭────╮\n│ %s  │\n╰────╯\n' "$(cat "$D/composer")"
    else
      printf 'tail\n╭────╮\n│    │\n╰────╯\n'
    fi
    exit 0 ;;
  list-windows)
    alive "$sock" || { echo "no server running on /tmp/tmux-1000/$sock" >&2; exit 1; }
    [ -f "$D/windows-$sock" ] && cat "$D/windows-$sock"
    exit 0 ;;
  has-session)
    alive "$sock" || exit 1
    exit 0 ;;
  new-session)
    ses=
    while [ $# -gt 0 ]; do
      case "$1" in
        -s) ses=${2:-}; shift 2 ;;
        *) shift ;;
      esac
    done
    : > "$D/server-$sock-alive"
    printf '%s\n' "$ses" >> "$D/created-sessions-$sock"
    printf '%s\n' "$sock" >> "$D/created-on"
    exit 0 ;;
  new-window)
    name=
    while [ $# -gt 0 ]; do
      case "$1" in
        -n) name=${2:-}; shift 2 ;;
        -c|-t) shift 2 ;;
        *) shift ;;
      esac
    done
    printf '%s\n' "$name" >> "$D/windows-$sock"
    printf '%s\n' "$sock $name" >> "$D/created-windows"
    printf '@9\n'
    exit 0 ;;
  kill-window)
    exit 0 ;;
  set-window-option)
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
}

new_socket_case() {  # <name> [id]
  local id=${2:-d1} dir="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/fake"
  : > "$dir/fake/literal"
  : > "$dir/fake/server-default-alive"
  : > "$dir/fake/windows-default"
  printf 'claude' > "$dir/fake/command"
  printf 'claude' > "$dir/fake/becomes"
  make_socket_stub "$dir"
  printf '%s\n' "$dir"
}

add_socket_ship_task() {  # <case-dir> <id> [socket]
  local dir=$1 id=$2 socket=$3
  local home="$dir/home" proj="$dir/proj" wt="$dir/wt"
  fm_git_worktree "$proj" "$wt" "task-$id"
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise socket-isolated relaunch for $id.

## Firstmate spec
Preserve the task while replacing its agent process.
EOF
  {
    echo "window=fmses:fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$wt"
    echo "project=$proj"
    echo "harness=claude"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "tasktmp=/tmp/fm-$id"
    echo "model=default"
    echo "effort=default"
    [ -z "$socket" ] || echo "socket=$socket"
  } > "$home/state/$id.meta"
  printf '%s' "$wt" > "$dir/fake/cwd"
  TASK_TMPS+=("/tmp/fm-$id")
}

seed_socket_backlog() {  # <case-dir> <id>
  local dir=$1 id=$2 file="$1/home/data/backlog.md"
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$file"
  tasks-axi add "$id" "socket relaunch fixture task" --kind ship --file "$file" >/dev/null
  tasks-axi start "$id" --file "$file" >/dev/null
}

run_socket_control() {  # <case-dir> <args...>
  local dir=$1; shift
  mkdir -p "$dir/user-home"
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION -u HERDR_SOCKET_PATH \
    -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID -u TMUX \
    PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    HOME="$dir/user-home" CLAUDE_CONFIG_DIR='' \
    FM_SPAWN_NO_GUARD=1 GROK_HOME="$dir/grokhome" \
    FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_LAUNCH_WAIT=0.05 \
    "$CONTROL" "$@" 2>&1
}

socket_meta_field() {  # <case-dir> <id> <key>
  grep "^$3=" "$1/home/state/$2.meta" | tail -1 | cut -d= -f2-
}

test_relaunch_rebinds_a_proven_dead_socket_recorded_endpoint() {
  [ "$HAVE_PROOF_TOOLS" = 1 ] || { pass "relaunch reclaim on a dead fleet socket (skipped: no lsof/pgrep)"; return 0; }
  local dir out rc sock="fmfake-fleet-$$"
  dir=$(new_socket_case reclaim d1)
  add_socket_ship_task "$dir" d1 "$sock"
  seed_socket_backlog "$dir" d1
  # Premise: the recorded fleet server is dead (no alive marker, so the stub
  # answers every read with the definitive no-server error) and the worktree
  # holds no live process. The reclaim proof must compose, and the re-created
  # window must land ON THE RECORDED SOCKET.

  out=$(run_socket_control "$dir" d1 relaunch --note "the fleet server died under load"); rc=$?

  expect_code 0 "$rc" "a provably dead recorded socket must relaunch"$'\n'"$out"
  assert_contains "$out" "relaunched d1" "the outcome should name the reclaim"
  [ "$(socket_meta_field "$dir" d1 socket)" = "$sock" ] \
    || fail "the rebind must preserve the recorded socket identity"
  [ "$(socket_meta_field "$dir" d1 window)" = "fmses:fm-d1" ] \
    || fail "the rebind must publish the re-created window, got '$(socket_meta_field "$dir" d1 window)'"
  [ -f "$dir/fake/server-$sock-alive" ] \
    || fail "the rebind must have re-created the recorded socket's server"
  assert_grep "$sock fm-d1" "$dir/fake/created-windows" \
    "the replacement window must be created on the RECORDED socket"
  if grep -vF "$sock" "$dir/fake/created-windows" | grep -q 'fm-'; then
    fail "no window may be created on any socket other than the recorded one"
  fi
  [ "$(cat "$dir/fake/command")" = claude ] \
    || fail "the replacement agent must be running after the reclaim"
  pass "fm-control relaunch: a proven-dead fleet socket rebinds onto the recorded socket"
}

test_relaunch_refuses_a_dead_socket_legacy_record_unchanged() {
  [ "$HAVE_PROOF_TOOLS" = 1 ] || { pass "legacy dead-server refusal (skipped: no lsof/pgrep)"; return 0; }
  local dir out rc
  dir=$(new_socket_case legacy-refusal d2)
  add_socket_ship_task "$dir" d2 ""
  seed_socket_backlog "$dir" d2
  # The default (ambient) server holds the window; killing its record's
  # endpoint still refuses reclaim - a legacy record cannot prove absence.
  rm -f "$dir/fake/server-default-alive"

  out=$(run_socket_control "$dir" d2 relaunch --note "try anyway"); rc=$?

  expect_code 1 "$rc" "a legacy record must refuse relaunch exactly as before socket isolation"
  assert_contains "$out" "without its socket identity" \
    "the refusal must name the missing socket identity"
  [ ! -e "$dir/fake/created-windows" ] \
    || fail "a refused legacy reclaim must not create any window"
  pass "fm-control relaunch: a legacy record refuses a dead endpoint unchanged"
}

test_relaunch_refuses_when_the_worktree_survived_the_server() {
  [ "$HAVE_PROOF_TOOLS" = 1 ] || { pass "worktree-survivor refusal (skipped: no lsof/pgrep)"; return 0; }
  local dir out rc sock="fmfake-surv-$$"
  dir=$(new_socket_case survivor-refusal d3)
  add_socket_ship_task "$dir" d3 "$sock"
  seed_socket_backlog "$dir" d3
  # A pane process survived the server death: it kept its cwd in the recorded
  # worktree, so the orphan guard must refuse and name it.
  ( cd "$dir/wt" && exec sleep 60 ) &
  local sleeper=$!
  sleep 1

  out=$(run_socket_control "$dir" d3 relaunch --note "reclaim anyway"); rc=$?
  kill "$sleeper" 2>/dev/null || true
  wait "$sleeper" 2>/dev/null || true

  expect_code 1 "$rc" "a surviving worktree process must refuse the reclaim"$'\n'"$out"
  assert_contains "$out" "still has live processes" \
    "the refusal must name the orphan guard"
  [ "$(socket_meta_field "$dir" d3 window)" = "fmses:fm-d3" ] \
    || fail "a refused reclaim must leave the record's window untouched"
  [ ! -e "$dir/fake/created-windows" ] \
    || fail "a refused reclaim must not create any window"
  pass "fm-control relaunch: a worktree survivor refuses the reclaim"
}

# --- E. real-script screen read and doorbell through the recorded socket -----

test_real_socket_peek_and_doorbell_end_to_end() {
  [ "$HAVE_TMUX" = 1 ] || { pass "fm-peek/fm-send through the recorded socket (skipped: no real tmux)"; return 0; }
  local sock="fme2e-$$" home="$TMP_ROOT/e2e-home" wt="$TMP_ROOT/e2e-wt" id="e2e1" target
  local meta before after out rc
  mkdir -p "$home/state" "$home/data" "$wt"
  tmux -L "$sock" new-session -d -s firstmate -x 120 -y 30 \
    || fail "real tmux: e2e session failed"
  tmux -L "$sock" new-window -d -t "firstmate:" -n "fm-$id" -c "$wt" \
    || fail "real tmux: e2e window failed"
  target="firstmate:fm-$id"

  # Prove command execution with a marker, retrying until the shell is ready.
  local i=0
  while [ "$i" -lt 50 ]; do
    tmux -L "$sock" send-keys -t "$target" "printf 'e2e-marker-%s\\n' ready" Enter
    if tmux -L "$sock" capture-pane -p -t "$target" -S -20 2>/dev/null | grep -q 'e2e-marker-ready'; then
      break
    fi
    i=$((i + 1))
    sleep 0.2
  done
  [ "$i" -lt 50 ] || { tmux -L "$sock" kill-server 2>/dev/null; fail "the e2e pane shell never became ready"; }

  # A task record ON THE FLEET SOCKET: fm-peek reads the window through the
  # recorded socket= scope.
  meta="$home/state/$id.meta"
  cat > "$meta" <<EOF
window=$target
endpoint_task_id=$id
worktree=$wt
project=$TMP_ROOT
harness=claude
kind=ship
socket=$sock
EOF
  out=$(FM_HOME="$home" "$PEEK" "$id" 20 2>&1); rc=$?
  [ "$rc" -eq 0 ] || { tmux -L "$sock" kill-server 2>/dev/null; fail "fm-peek through the recorded socket failed: $out"; }
  case "$out" in
    *e2e-marker-ready*) : ;;
    *) tmux -L "$sock" kill-server 2>/dev/null; fail "fm-peek did not return the pane marker through the recorded socket" ;;
  esac
  pass "fm-peek.sh: the recorded socket scope reaches the fleet window"

  # The doorbell: fm-send --key Enter lands on the fleet window, not the
  # ambient server - the pane's last line (a fresh prompt) changes.
  before=$(tmux -L "$sock" capture-pane -p -t "$target")
  out=$(FM_HOME="$home" "$SEND" "$id" --key Enter 2>&1); rc=$?
  [ "$rc" -eq 0 ] || { tmux -L "$sock" kill-server 2>/dev/null; fail "fm-send --key Enter through the recorded socket failed: $out"; }
  sleep 1
  after=$(tmux -L "$sock" capture-pane -p -t "$target")
  [ "$before" != "$after" ] \
    || { tmux -L "$sock" kill-server 2>/dev/null; fail "the doorbell key never reached the fleet window" ; }
  pass "fm-send.sh: the doorbell key addresses the recorded socket"

  # A legacy record (no socket=) must NOT see the fleet window: peek resolves
  # through the ambient server and fails read-only.
  grep -v '^socket=' "$meta" > "$home/state/$id.meta.legacy"
  mv "$home/state/$id.meta.legacy" "$meta"
  if FM_HOME="$home" "$PEEK" "$id" 10 >/dev/null 2>&1; then
    tmux -L "$sock" kill-server 2>/dev/null
    fail "a legacy record must not read a fleet window through the ambient server"
  fi
  pass "fm-peek.sh: a legacy record stays on the ambient server and misses the fleet window"

  tmux -L "$sock" kill-server 2>/dev/null || true
}

# --- entrypoint ---------------------------------------------------------------

test_fm_tmux_routes_every_invocation_through_one_owner
test_fm_tmux_fleet_socket_resolution
test_socket_meta_round_trip_and_validation
test_real_tmux_scoped_addressing_isolates_servers
test_real_tmux_death_proof_primitives
test_verdict_real_socket_gone_and_refusal_cases
test_real_socket_peek_and_doorbell_end_to_end
test_relaunch_rebinds_a_proven_dead_socket_recorded_endpoint
test_relaunch_refuses_a_dead_socket_legacy_record_unchanged
test_relaunch_refuses_when_the_worktree_survived_the_server
