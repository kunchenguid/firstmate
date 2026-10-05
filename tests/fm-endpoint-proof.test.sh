#!/usr/bin/env bash
# tests/fm-endpoint-proof.test.sh - the tmux endpoint identity and absence proof
# (bin/fm-endpoint-proof-lib.sh, bin/fm-endpoint-proof.sh, and the tmux arm of
# fm_control_endpoint_absence_verdict).
#
# Real tmux servers on private sockets and real processes, no harness and no
# credentials, so it runs everywhere CI runs tmux. Every server this file starts
# is addressed through a per-label shim, so nothing here can reach the host's
# own tmux sessions.
#
# The recovery the proof exists for: the tmux server that hosted a task's window
# is gone (a crash, a restart that wipes /tmp), a different server now answers,
# and the control plane must decide whether the recorded endpoint is GONE or
# merely unreachable. The cases below pin each way that decision can go:
#   - server absent                   the recorded server instance is gone
#   - window gone from a live server  the recorded window id left its server
#   - another live session            the endpoint is alive somewhere else
#   - server unreachable              stopped, or its socket unreadable
#   - boot / host identity            a reboot proves it, another host cannot
#   - live process in the worktree    an agent that outlived its server vetoes
#   - legacy record, no evidence      nothing to prove from, so nothing claimed
#   - legacy record, reviewed digest  the explicit, specific, recorded consent
#   - dirty work                      the proof never touches the worktree
#   - repeated recovery               idempotent evidence, consent, backfill
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "skip: git not found"; exit 0; }
REAL_TMUX=$(command -v tmux)
CLI="$ROOT/bin/fm-endpoint-proof.sh"

# A short private socket directory: the unix socket path limit is ~104 bytes and
# a long TMPDIR would break it.
LAB=$(mktemp -d /tmp/fmep.XXXXXX) || fail "could not create a lab directory"
export TMUX_TMPDIR="$LAB/sock"
mkdir -p "$TMUX_TMPDIR" "$LAB/shim" "$LAB/home/state" "$LAB/home/data"
unset TMUX
LABELS=()
BGPIDS=()

cleanup_lab() {
  local label pid
  for pid in "${BGPIDS[@]:-}"; do
    [ -n "$pid" ] || continue
    kill -CONT "$pid" 2>/dev/null || true
    kill "$pid" 2>/dev/null || true
  done
  for label in "${LABELS[@]:-}"; do
    [ -n "$label" ] || continue
    env -u TMUX TMUX_TMPDIR="$TMUX_TMPDIR" "$REAL_TMUX" -L "$label" kill-server >/dev/null 2>&1 || true
  done
  rm -rf "$LAB"
}
trap cleanup_lab EXIT

mkshim() {  # <label>
  mkdir -p "$LAB/shim/$1"
  printf '#!/usr/bin/env bash\nexec "%s" -L "%s" -f /dev/null "$@"\n' "$REAL_TMUX" "$1" > "$LAB/shim/$1/tmux"
  chmod +x "$LAB/shim/$1/tmux"
}

# tm <label> <tmux args...>: run tmux against that label's server.
tm() {
  local label=$1
  shift
  env -u TMUX PATH="$LAB/shim/$label:$PATH" tmux "$@"
}

# start_server <label> <session> <window>: a server whose only window is a
# long-lived sleep, named so tmux never renames it.
start_server() {
  mkshim "$1"
  LABELS+=("$1")
  tm "$1" new-session -d -s "$2" -n "$3" 'exec sleep 3000' || fail "could not start tmux server $1"
}

kill_server() { tm "$1" kill-server >/dev/null 2>&1 || true; }

server_pid() { tm "$1" display-message -p '#{pid}'; }

# libeval <ambient-label> <bash snippet>: run the snippet with the proof library
# and the control plane sourced, addressing <ambient-label> as "this seat's"
# tmux server. Prints combined output; status is the snippet's own.
libeval() {
  local ambient=$1 snippet=$2
  # shellcheck disable=SC2016  # the snippet expands inside the child shell, not here
  env -u TMUX PATH="$LAB/shim/$ambient:$PATH" FM_ENDPOINT_PROBE_TIMEOUT="${PROBE_TIMEOUT:-2}" \
    bash -c '. "$1/bin/fm-backend.sh"; . "$1/bin/fm-control-lib.sh"; eval "$2"' _ "$ROOT" "$snippet" 2>&1
}

# mkworktree <id>: a git worktree with committed, staged, modified, and
# untracked work - exactly what a recovery must never touch.
mkworktree() {
  local id=$1 repo="$LAB/repo-$1" wt="$LAB/wt-$1"
  fm_git_identity
  fm_git_init_commit "$repo"
  git -C "$repo" worktree add --quiet -b "fm/$id" "$wt"
  printf 'unstaged edit\n' >> "$wt/README.md"
  printf 'staged new file\n' > "$wt/staged.txt"
  git -C "$wt" add staged.txt
  printf 'untracked scratch\n' > "$wt/untracked.txt"
  printf '%s\n' "$wt"
}

# tree_fingerprint <worktree>: everything a recovery must leave alone.
tree_fingerprint() {
  local wt=$1
  {
    git -C "$wt" rev-parse HEAD
    git -C "$wt" symbolic-ref HEAD
    git -C "$wt" status --porcelain=v1 --untracked-files=all
    git -C "$wt" diff
    git -C "$wt" diff --cached
    ( cd "$wt" && find . -path ./.git -prune -o -type f -print | LC_ALL=C sort | while IFS= read -r f; do printf '%s ' "$f"; cksum < "$f"; done )
  } 2>&1 | cksum
}

# write_meta <id> <window> <worktree> [extra lines...]: a task record the proof
# and the CLI accept.
write_meta() {
  local id=$1 window=$2 wt=$3 file="$LAB/home/state/$1.meta"
  shift 3
  {
    printf 'window=%s\n' "$window"
    printf 'endpoint_task_id=%s\n' "$id"
    printf 'worktree=%s\n' "$wt"
    printf 'project=%s\n' "$LAB/project"
    printf 'harness=claude\nkind=ship\nbranch=fm/%s\n' "$id"
    printf 'spawn_gen=s%s.4242.7\n' "$(date +%s)"
    for line in "$@"; do printf '%s\n' "$line"; done
  } > "$file"
  printf '%s\n' "$file"
}

# record_identity <id> <recorded-label> <session>: the identity lines the spawn
# would record for fm-<id> on <recorded-label>'s server.
record_identity() {
  local id=$1 label=$2 session=$3
  libeval "$label" "fm_endpoint_tmux_identity_lines '=$session:=fm-$id' '$session:fm-$id'"
}

verdict_of() { printf '%s' "${1%%$'\t'*}"; }
detail_of() { printf '%s' "${1#*$'\t'}"; }

proof() {  # <ambient-label> <meta>
  libeval "$1" "fm_endpoint_tmux_proof '$2'"
}

mkdir -p "$LAB/project"
start_server amb main other

# --- identity capture --------------------------------------------------------

test_identity_is_recorded_and_validated() {
  local id=ep-ident lines pid out rc
  start_server rec-ident firstmate "fm-$id"
  lines=$(record_identity "$id" rec-ident firstmate) || fail "identity capture failed: $lines"
  pid=$(server_pid rec-ident)
  assert_contains "$lines" "tmux_socket=$TMUX_TMPDIR/tmux-$(id -u)/rec-ident" "the server's socket path is recorded"
  assert_contains "$lines" "tmux_server_pid=$pid" "the server pid is recorded"
  assert_contains "$lines" "tmux_server_start=" "the server start time is recorded"
  assert_contains "$lines" "tmux_window_id=@" "the stable window id is recorded"
  assert_contains "$lines" "endpoint_host=" "the host identity is recorded"
  # A label that does not match what tmux read back records nothing, so a target
  # that silently resolved to another window can never mint a wrong identity.
  out=$(libeval rec-ident "fm_endpoint_tmux_identity_lines '=firstmate:=fm-$id' 'firstmate:fm-someone-else'"); rc=$?
  [ "$rc" -ne 0 ] || fail "a mismatching label must not record an identity"
  [ -z "$out" ] || fail "a mismatching label must print nothing (got '$out')"
  out=$(libeval rec-ident "fm_endpoint_tmux_identity_lines '=firstmate:=fm-missing' 'firstmate:fm-missing'"); rc=$?
  [ "$rc" -ne 0 ] || fail "an absent window must not record an identity"
  pass "identity: a tmux endpoint's server, window id, and host are recorded, and a mismatching read records nothing"
}

test_identity_state_separates_legacy_complete_and_malformed() {
  local id=ep-state wt meta lines state
  start_server rec-state firstmate "fm-$id"
  wt=$(mkworktree "$id")
  lines=$(record_identity "$id" rec-state firstmate)
  meta=$(write_meta "$id" "firstmate:fm-$id" "$wt")
  state=$(libeval amb "fm_endpoint_identity_state '$meta'")
  assert_equals legacy "$state" "a record with no identity key is legacy"
  meta=$(write_meta "$id" "firstmate:fm-$id" "$wt" "$lines")
  state=$(libeval amb "fm_endpoint_identity_state '$meta'")
  assert_equals complete "$state" "a record with every identity key is complete"
  meta=$(write_meta "$id" "firstmate:fm-$id" "$wt" "tmux_socket=$TMUX_TMPDIR/x")
  state=$(libeval amb "fm_endpoint_identity_state '$meta'")
  assert_equals malformed "$state" "a partial identity is malformed, never legacy"
  meta=$(write_meta "$id" "firstmate:fm-$id" "$wt" "$lines" "tmux_server_pid=1")
  state=$(libeval amb "fm_endpoint_identity_state '$meta'")
  assert_equals malformed "$state" "a duplicated identity key is malformed"
  meta=$(write_meta "$id" "firstmate:fm-$id" "$wt" "$(printf '%s\n' "$lines" | sed 's/^tmux_server_pid=.*/tmux_server_pid=abc/')")
  state=$(libeval amb "fm_endpoint_identity_state '$meta'")
  assert_equals malformed "$state" "an invalid identity value is malformed"
  pass "identity: legacy, complete, and malformed records are told apart, and a half-written one never reads as legacy"
}

# --- server absent / replaced / window gone / other live session -------------

test_a_killed_server_proves_the_endpoint_gone() {
  local id=ep-dead wt meta lines out
  start_server rec-dead firstmate "fm-$id"
  wt=$(mkworktree "$id")
  lines=$(record_identity "$id" rec-dead firstmate)
  meta=$(write_meta "$id" "firstmate:fm-$id" "$wt" "$lines")
  # The seat's own server is healthy and knows nothing about the task: the
  # global window inventory says "absent", which alone is never the proof.
  out=$(proof amb "$meta")
  assert_equals unproven "$(verdict_of "$out")" "a live recorded server with the window still present is not gone"
  kill_server rec-dead
  sleep 0.3
  out=$(proof amb "$meta")
  assert_equals gone "$(verdict_of "$out")" "a recorded server that is gone proves its endpoint gone"
  assert_contains "$(detail_of "$out")" "refuses connections" "the basis names the dead server"
  assert_contains "$(detail_of "$out")" "no tmux process holds the recorded pid" "the basis names the pid check"
  pass "server absent: a recorded server that no longer exists proves the endpoint gone"
}

test_a_window_gone_from_its_live_server_proves_the_endpoint_gone() {
  local id=ep-win wt meta lines out
  start_server rec-win firstmate "fm-$id"
  tm rec-win new-window -d -t firstmate: -n keep 'exec sleep 3000'
  wt=$(mkworktree "$id")
  lines=$(record_identity "$id" rec-win firstmate)
  meta=$(write_meta "$id" "firstmate:fm-$id" "$wt" "$lines")
  tm rec-win kill-window -t "=firstmate:=fm-$id"
  out=$(proof amb "$meta")
  assert_equals gone "$(verdict_of "$out")" "a live recorded server that lost the window proves it gone"
  assert_contains "$(detail_of "$out")" "no longer has the recorded window" "the basis names the window"
  pass "window gone: a live recorded server is authoritative about its own windows"
}

test_a_live_recorded_endpoint_is_never_gone_even_renamed_or_moved() {
  local id=ep-live wt meta lines out
  start_server rec-live firstmate "fm-$id"
  tm rec-live new-session -d -s elsewhere -n keep 'exec sleep 3000'
  wt=$(mkworktree "$id")
  lines=$(record_identity "$id" rec-live firstmate)
  meta=$(write_meta "$id" "firstmate:fm-$id" "$wt" "$lines")
  out=$(proof amb "$meta")
  assert_equals unproven "$(verdict_of "$out")" "a live endpoint on its recorded server is not gone"
  assert_contains "$(detail_of "$out")" "still alive on its recorded server" "the refusal names the live endpoint"
  # The label no longer reads, but the window id still does: a renamed window
  # and one moved into another session are both the SAME live endpoint.
  tm rec-live rename-window -t "=firstmate:=fm-$id" renamed-away
  out=$(proof amb "$meta")
  assert_equals unproven "$(verdict_of "$out")" "a renamed live endpoint is not gone"
  assert_contains "$(detail_of "$out")" "firstmate:renamed-away" "the refusal names where it lives now"
  tm rec-live move-window -s "=firstmate:=renamed-away" -t elsewhere:
  out=$(proof amb "$meta")
  assert_equals unproven "$(verdict_of "$out")" "an endpoint moved to another session is not gone"
  assert_contains "$(detail_of "$out")" "elsewhere:renamed-away" "the refusal names the new session"
  pass "another live session: an endpoint alive elsewhere, renamed or moved, is never proven gone"
}

test_a_replaced_server_instance_proves_the_recorded_one_gone() {
  local id=ep-repl wt meta lines out sock
  start_server rec-repl firstmate "fm-$id"
  wt=$(mkworktree "$id")
  lines=$(record_identity "$id" rec-repl firstmate)
  sock=$(printf '%s\n' "$lines" | sed -n 's/^tmux_socket=//p')
  meta=$(write_meta "$id" "firstmate:fm-$id" "$wt" "$lines")
  kill_server rec-repl
  sleep 0.3
  # A DIFFERENT server now owns the same socket path (a restarted supervisor).
  # Its window ids mean nothing for the recorded one, so it must not be read as
  # still holding the task - and must not be mistaken for the recorded server.
  sleep 1
  env -u TMUX "$REAL_TMUX" -S "$sock" -f /dev/null new-session -d -s firstmate -n "fm-$id" 'exec sleep 3000' || fail "could not start the replacement server"
  LABELS+=(rec-repl)
  out=$(proof amb "$meta")
  assert_equals gone "$(verdict_of "$out")" "a socket now served by another instance proves the recorded one gone"
  assert_contains "$(detail_of "$out")" "another tmux server" "the basis names the replacement"
  env -u TMUX "$REAL_TMUX" -S "$sock" kill-server >/dev/null 2>&1 || true
  pass "server replaced: another instance on the recorded socket path proves the recorded instance gone"
}

# --- unreachable -------------------------------------------------------------

test_an_unresponsive_server_is_unproven_and_never_hangs() {
  local id=ep-stop wt meta lines out pid start elapsed
  start_server rec-stop firstmate "fm-$id"
  wt=$(mkworktree "$id")
  lines=$(record_identity "$id" rec-stop firstmate)
  meta=$(write_meta "$id" "firstmate:fm-$id" "$wt" "$lines")
  pid=$(server_pid rec-stop)
  kill -STOP "$pid"
  start=$(date +%s)
  out=$(proof amb "$meta")
  elapsed=$(( $(date +%s) - start ))
  kill -CONT "$pid"
  assert_equals unproven "$(verdict_of "$out")" "a stopped server is unreachable, not gone"
  assert_contains "$(detail_of "$out")" "did not answer within 2s" "the refusal names the unresponsive server"
  # A tmux client hands its stdout to the server, so a pipe-captured read of a
  # stopped server waits until it resumes. The proof reads through a file.
  [ "$elapsed" -lt 20 ] || fail "the proof must stay bounded against a stopped server (took ${elapsed}s)"
  pass "server unreachable: a stopped server is unproven and the read stays bounded (${elapsed}s)"
}

test_an_unreadable_socket_is_unproven() {
  local id=ep-perm wt meta lines out sock
  start_server rec-perm firstmate "fm-$id"
  wt=$(mkworktree "$id")
  lines=$(record_identity "$id" rec-perm firstmate)
  sock=$(printf '%s\n' "$lines" | sed -n 's/^tmux_socket=//p')
  meta=$(write_meta "$id" "firstmate:fm-$id" "$wt" "$lines")
  chmod 000 "$sock"
  out=$(proof amb "$meta")
  chmod 700 "$sock"
  if [ "$(id -u)" = 0 ]; then
    pass "server unreachable: skipped the permission case as root"
    return 0
  fi
  assert_equals unproven "$(verdict_of "$out")" "a socket this seat may not open is unreadable, not gone"
  assert_contains "$(detail_of "$out")" "Permission denied" "the refusal carries tmux's own reason"
  pass "server unreachable: a socket that cannot be opened is unproven"
}

# --- host and boot identity ---------------------------------------------------

test_a_reboot_proves_absence_and_another_host_never_does() {
  local id=ep-boot wt meta lines out other
  start_server rec-boot firstmate "fm-$id"
  wt=$(mkworktree "$id")
  lines=$(record_identity "$id" rec-boot firstmate)
  if ! printf '%s\n' "$lines" | grep -q '^endpoint_boot='; then
    pass "boot identity: skipped, this platform exposes no boot id"
    return 0
  fi
  # Same machine, an earlier boot: nothing of that boot can be running now, so
  # the recorded server is gone whatever answers on its old socket path.
  meta=$(write_meta "$id" "firstmate:fm-$id" "$wt" "$(printf '%s\n' "$lines" | sed 's/^endpoint_boot=.*/endpoint_boot=00000000-0000-0000-0000-000000000000/')")
  out=$(proof amb "$meta")
  assert_equals gone "$(verdict_of "$out")" "a reboot since the record proves the endpoint gone"
  assert_contains "$(detail_of "$out")" "rebooted" "the basis names the reboot"
  # Another machine: this host cannot see its processes at all.
  other=$(printf '%s\n' "$lines" | sed 's/^endpoint_host=.*/endpoint_host=ffffffffffffffffffffffff/')
  meta=$(write_meta "$id" "firstmate:fm-$id" "$wt" "$other")
  kill_server rec-boot
  sleep 0.3
  out=$(proof amb "$meta")
  assert_equals unproven "$(verdict_of "$out")" "a record from another host proves nothing, even with its server gone"
  assert_contains "$(detail_of "$out")" "another machine" "the refusal names the host mismatch"
  pass "boot and host: a reboot proves absence on the same host, another host never does"
}

# --- live processes in the worktree -------------------------------------------

test_a_live_process_in_the_worktree_vetoes_the_proof() {
  local id=ep-veto wt meta lines out pid fifo
  start_server rec-veto firstmate "fm-$id"
  wt=$(mkworktree "$id")
  lines=$(record_identity "$id" rec-veto firstmate)
  meta=$(write_meta "$id" "firstmate:fm-$id" "$wt" "$lines")
  kill_server rec-veto
  sleep 0.3
  out=$(proof amb "$meta")
  assert_equals gone "$(verdict_of "$out")" "with nothing running there the dead server proves the endpoint gone"
  # An idle SHELL sitting in the directory is not an agent and does not veto.
  fifo="$LAB/fifo-$id"
  mkfifo "$fifo"
  ( cd "$wt" && exec bash -c 'read -r x < "$1"' _ "$fifo" ) &
  BGPIDS+=("$!")
  sleep 0.4
  out=$(proof amb "$meta")
  assert_equals gone "$(verdict_of "$out")" "an idle shell in the worktree is not a live agent"
  # A non-shell process working in the worktree outlived its server: veto.
  ( cd "$wt" && exec sleep 600 ) &
  pid=$!
  BGPIDS+=("$pid")
  sleep 0.4
  out=$(proof amb "$meta")
  assert_equals unproven "$(verdict_of "$out")" "a live process in the worktree vetoes the proof"
  assert_contains "$(detail_of "$out")" "still running in the task worktree" "the refusal names the process"
  assert_contains "$(detail_of "$out")" "pid $pid" "the refusal names the pid"
  kill "$pid"
  wait "$pid" 2>/dev/null || true
  # The task's own marker vetoes too, wherever the process happens to stand.
  ( cd "$LAB" && FM_TASK_ID="$id" exec sleep 600 ) &
  pid=$!
  BGPIDS+=("$pid")
  sleep 0.4
  out=$(proof amb "$meta")
  assert_equals unproven "$(verdict_of "$out")" "a process carrying the task's FM_TASK_ID vetoes the proof"
  kill "$pid"
  wait "$pid" 2>/dev/null || true
  out=$(proof amb "$meta")
  assert_equals gone "$(verdict_of "$out")" "the proof returns once nothing is left running"
  # The probe's own helpers (a `sleep` in a wait loop, started by whoever runs
  # the proof from inside the worktree) are never mistaken for an agent.
  out=$(libeval amb "( cd '$wt' && exec sleep 5 ) & sleep 0.4; fm_endpoint_worktree_processes '$wt' '$id'; kill %1 2>/dev/null; wait 2>/dev/null")
  assert_equals "" "$out" "a process the proof's own shell started is not a live agent"
  pass "live process: an agent that outlived its server vetoes the proof, an idle shell does not"
}

# --- the control plane's verdict ------------------------------------------------

absence() {  # <ambient> <id> [digest]
  libeval "$1" "fm_control_endpoint_absence_verdict tmux 'firstmate:fm-$2' '$LAB/home/state/$2.meta' '${3:-}'"
}

test_the_control_verdict_rests_on_the_record_not_the_label() {
  local id=ep-ctl wt lines out
  start_server rec-ctl firstmate "fm-$id"
  wt=$(mkworktree "$id")
  lines=$(record_identity "$id" rec-ctl firstmate)
  write_meta "$id" "firstmate:fm-$id" "$wt" "$lines" >/dev/null
  out=$(absence amb "$id")
  assert_equals unproven "$(verdict_of "$out")" "the verdict is unproven while the recorded endpoint is alive"
  kill_server rec-ctl
  sleep 0.3
  out=$(absence amb "$id")
  assert_equals gone "$(verdict_of "$out")" "the verdict is gone once the recorded server is gone"
  # No record handed over: the label alone never proves anything.
  out=$(libeval amb "fm_control_endpoint_absence_verdict tmux 'firstmate:fm-$id'")
  assert_equals unproven "$(verdict_of "$out")" "without the record there is no proof"
  # A malformed identity is never guessed past, and no consent opens it.
  write_meta "$id" "firstmate:fm-$id" "$wt" "tmux_socket=/tmp/x" >/dev/null
  out=$(absence amb "$id" "$(printf '0%.0s' $(seq 1 64))")
  assert_equals unproven "$(verdict_of "$out")" "a malformed identity is unproven"
  assert_contains "$(detail_of "$out")" "incomplete or invalid" "the refusal says the record is malformed"
  pass "control verdict: tmux absence rests on the record's identity, never on the window label"
}

# --- legacy records ---------------------------------------------------------------

cli() {  # <ambient-label> <args...>
  local ambient=$1
  shift
  env -u TMUX PATH="$LAB/shim/$ambient:$PATH" FM_HOME="$LAB/home" FM_ENDPOINT_PROBE_TIMEOUT="${PROBE_TIMEOUT:-2}" \
    "$CLI" "$@" 2>&1
}

digest_of() { printf '%s\n' "$1" | sed -n 's/^consent-digest: //p'; }

test_a_legacy_record_without_evidence_stays_refused() {
  local id=ep-leg wt out
  wt=$(mkworktree "$id")
  write_meta "$id" "firstmate:fm-$id" "$wt" >/dev/null
  out=$(absence amb "$id")
  assert_equals unproven "$(verdict_of "$out")" "a legacy record cannot be proven gone"
  assert_contains "$(detail_of "$out")" "recorded before tmux endpoint identity existed" "the refusal names the legacy record"
  assert_contains "$(detail_of "$out")" "legacy-endpoint-consent" "the refusal names the explicit consent path"
  assert_not_contains "$(detail_of "$out")" "endpoint-gone" "the refusal never reuses the outcome token"
  # A digest that is not the evidence's digest opens nothing, and the refusal
  # offers the current one.
  out=$(absence amb "$id" "$(printf 'a%.0s' $(seq 1 64))")
  assert_equals unproven "$(verdict_of "$out")" "a wrong digest is refused"
  assert_contains "$(detail_of "$out")" "does not match the evidence" "the refusal says the digest is stale"
  pass "legacy without evidence: nothing is claimed, and a wrong digest opens nothing"
}

test_a_reviewed_digest_is_a_specific_consent_that_cannot_be_replayed() {
  local id=ep-cons wt out digest pid
  wt=$(mkworktree "$id")
  write_meta "$id" "firstmate:fm-$id" "$wt" >/dev/null
  out=$(cli amb show "$id")
  assert_contains "$out" "identity: legacy" "the report names the legacy record"
  assert_contains "$out" "verdict: unproven" "the report does not claim a proof"
  assert_contains "$out" "endpoint-state: missing" "the ambient server reads the endpoint missing"
  assert_contains "$out" "worktree_processes=none" "the evidence reports the worktree's processes"
  assert_contains "$out" "record_vs_boot=" "the evidence reports whether the record predates this boot"
  digest=$(digest_of "$out")
  [ "${#digest}" -eq 64 ] || fail "the report must print a 64-character digest (got '$digest')"
  # Identical evidence digests identically, run after run.
  assert_equals "$digest" "$(digest_of "$(cli amb show "$id")")" "the digest is stable for identical evidence"
  out=$(absence amb "$id" "$digest")
  assert_equals gone "$(verdict_of "$out")" "the reviewed digest is accepted while the evidence is unchanged"
  assert_contains "$(detail_of "$out")" "operator's reviewed evidence" "the basis names the consent"
  # The consent is for THIS evidence. Anything that changes it voids it: the
  # server the replacement would open on, and any live process.
  start_server amb2 main other
  out=$(absence amb2 "$id" "$digest")
  assert_equals unproven "$(verdict_of "$out")" "a digest reviewed against another server is void"
  kill_server amb2
  sleep 0.3
  ( cd "$wt" && exec sleep 600 ) &
  pid=$!
  BGPIDS+=("$pid")
  sleep 0.4
  out=$(cli amb show "$id")
  assert_contains "$out" "consent: not possible" "a live process in the worktree withdraws the consent path"
  assert_not_contains "$out" "consent-digest:" "no digest is offered while the evidence names a live process"
  out=$(absence amb "$id" "$digest")
  assert_equals unproven "$(verdict_of "$out")" "a live process voids even a digest reviewed earlier"
  assert_contains "$(detail_of "$out")" "no consent can override" "the refusal says a live agent cannot be consented away"
  kill "$pid"
  wait "$pid" 2>/dev/null || true
  out=$(absence amb "$id" "$digest")
  assert_equals gone "$(verdict_of "$out")" "the same evidence verifies again once the process is gone"
  pass "legacy with a reviewed digest: consent is specific to the evidence, voided by change, never over a live agent"
}

test_a_live_window_for_the_task_on_any_server_blocks_consent() {
  local id=ep-elsewhere wt out
  wt=$(mkworktree "$id")
  write_meta "$id" "firstmate:fm-$id" "$wt" >/dev/null
  start_server rec-elsewhere other-session "fm-$id"
  out=$(cli amb show "$id")
  assert_contains "$out" "info.tmux_server: " "the evidence lists the servers it read"
  assert_contains "$out" "has-window=yes" "the evidence reports a server holding a window for the task"
  assert_contains "$out" "consent: not possible" "no consent is offered while a live window for the task exists"
  assert_contains "$out" "veto=a live tmux window named fm-$id" "the veto names the window"
  out=$(absence amb "$id" "$(printf 'b%.0s' $(seq 1 64))")
  assert_equals unproven "$(verdict_of "$out")" "a live window elsewhere is never accepted gone"
  kill_server rec-elsewhere
  pass "legacy with a live window elsewhere: the evidence withdraws the consent path"
}

test_consent_never_applies_to_a_record_that_carries_identity() {
  local id=ep-nolegacy wt lines out pid digest rc
  start_server rec-nolegacy firstmate "fm-$id"
  wt=$(mkworktree "$id")
  lines=$(record_identity "$id" rec-nolegacy firstmate)
  # Whatever digest an operator holds, a record that carries identity is decided
  # by its proof alone.
  digest=$(printf 'c%.0s' $(seq 1 64))
  write_meta "$id" "firstmate:fm-$id" "$wt" "$lines" >/dev/null
  out=$(libeval amb "fm_endpoint_legacy_check '$LAB/home/state/$id.meta' '$digest'"); rc=$?
  [ "$rc" -ne 0 ] || fail "a complete record must refuse consent outright"
  assert_contains "$out" "predates endpoint identity" "the refusal says consent is for legacy records only"
  # The recorded server is unreachable (stopped): a complete record is decided
  # by its proof alone, so no digest can talk it into `gone`.
  pid=$(server_pid rec-nolegacy)
  kill -STOP "$pid"
  out=$(absence amb "$id" "$digest")
  kill -CONT "$pid"
  assert_equals unproven "$(verdict_of "$out")" "a digest never overrides an unreachable recorded server"
  assert_contains "$(detail_of "$out")" "did not answer" "the refusal is the proof's own"
  # And it never overrides a live one.
  out=$(absence amb "$id" "$digest")
  assert_equals unproven "$(verdict_of "$out")" "a digest never overrides a live recorded endpoint"
  pass "consent boundary: a record that carries identity is decided by its proof, never by a digest"
}

# --- dirty work and repeated recovery ----------------------------------------------

test_the_proof_and_the_consent_leave_the_worktree_untouched() {
  local id=ep-dirty wt before after digest out
  wt=$(mkworktree "$id")
  write_meta "$id" "firstmate:fm-$id" "$wt" >/dev/null
  before=$(tree_fingerprint "$wt")
  out=$(cli amb show "$id")
  digest=$(digest_of "$out")
  absence amb "$id" "$digest" >/dev/null
  libeval amb "fm_endpoint_consent_record '$LAB/home/state' '$id' '$LAB/home/state/$id.meta' '$digest'" >/dev/null
  after=$(tree_fingerprint "$wt")
  assert_equals "$before" "$after" "committed, staged, modified, and untracked work is bit-identical after the proof and the consent"
  assert_contains "$(git -C "$wt" status --porcelain)" "untracked.txt" "the untracked file is still there"
  assert_contains "$(git -C "$wt" status --porcelain)" "staged.txt" "the staged file is still there"
  pass "dirty work: the proof and the consent never touch the worktree"
}

test_consent_records_are_durable_self_verifying_and_repeatable() {
  local id=ep-rep wt digest out meta
  wt=$(mkworktree "$id")
  meta=$(write_meta "$id" "firstmate:fm-$id" "$wt")
  digest=$(digest_of "$(cli amb show "$id")")
  libeval amb "fm_endpoint_consent_record '$LAB/home/state' '$id' '$meta' '$digest'" >/dev/null
  libeval amb "fm_endpoint_consent_record '$LAB/home/state' '$id' '$meta' '$digest'" >/dev/null
  out=$(cli amb consents "$id")
  assert_equals 2 "$(printf '%s\n' "$out" | grep -c 'evidence-matches-digest=yes')" "two repeated consents leave two self-verifying records"
  assert_contains "$out" "digest=$digest" "the record carries the digest"
  assert_grep "ev.worktree=$wt" "$LAB/home/state/$id.endpoint-consent" "the record carries the evidence verbatim"
  # Tampering with the recorded evidence is visible.
  sed -i.bak 's/^ev\.record_vs_boot=.*/ev.record_vs_boot=forged/' "$LAB/home/state/$id.endpoint-consent"
  out=$(cli amb consents "$id")
  assert_contains "$out" "evidence-matches-digest=no" "an altered consent record no longer matches its digest"
  pass "repeated recovery: consent records are durable, append-only, and audit themselves"
}

test_backfill_gives_a_live_legacy_record_its_identity_once() {
  local id=ep-fill wt meta before after out
  start_server rec-fill firstmate "fm-$id"
  wt=$(mkworktree "$id")
  meta=$(write_meta "$id" "firstmate:fm-$id" "$wt")
  # Backfill reads the window through THIS seat's server: it lives on rec-fill.
  out=$(cli rec-fill backfill "$id")
  assert_contains "$out" "recorded endpoint identity" "backfill records the identity of a live legacy endpoint"
  assert_contains "$(libeval amb "fm_endpoint_identity_state '$meta'")" complete "the record is now complete"
  assert_grep "tmux_window_id=@" "$meta" "the window id was appended"
  assert_grep "endpoint_task_id=$id" "$meta" "the rest of the record is intact"
  before=$(cksum < "$meta")
  out=$(cli rec-fill backfill "$id")
  assert_contains "$out" "skipped (identity complete)" "a second backfill is a no-op"
  after=$(cksum < "$meta")
  assert_equals "$before" "$after" "a repeated backfill leaves the record byte-identical"
  # And the identity it recorded now proves a later loss of that server.
  kill_server rec-fill
  sleep 0.3
  out=$(absence amb "$id")
  assert_equals gone "$(verdict_of "$out")" "the backfilled identity proves the next loss of the server"
  pass "backfill: a live legacy record gains identity exactly once, and the identity then proves its loss"
}

test_backfill_skips_what_it_cannot_attribute() {
  local id=ep-skip wt out
  wt=$(mkworktree "$id")
  write_meta "$id" "firstmate:fm-$id" "$wt" >/dev/null
  out=$(cli amb backfill "$id")
  assert_contains "$out" "skipped (endpoint reads missing)" "a missing endpoint is never given an identity"
  assert_not_contains "$(cat "$LAB/home/state/$id.meta")" "tmux_socket" "the record was not touched"
  pass "backfill: an endpoint that is not on this seat's server is left alone"
}

test_identity_is_recorded_and_validated
test_identity_state_separates_legacy_complete_and_malformed
test_a_killed_server_proves_the_endpoint_gone
test_a_window_gone_from_its_live_server_proves_the_endpoint_gone
test_a_live_recorded_endpoint_is_never_gone_even_renamed_or_moved
test_a_replaced_server_instance_proves_the_recorded_one_gone
test_an_unresponsive_server_is_unproven_and_never_hangs
test_an_unreadable_socket_is_unproven
test_a_reboot_proves_absence_and_another_host_never_does
test_a_live_process_in_the_worktree_vetoes_the_proof
test_the_control_verdict_rests_on_the_record_not_the_label
test_a_legacy_record_without_evidence_stays_refused
test_a_reviewed_digest_is_a_specific_consent_that_cannot_be_replayed
test_a_live_window_for_the_task_on_any_server_blocks_consent
test_consent_never_applies_to_a_record_that_carries_identity
test_the_proof_and_the_consent_leave_the_worktree_untouched
test_consent_records_are_durable_self_verifying_and_repeatable
test_backfill_gives_a_live_legacy_record_its_identity_once
test_backfill_skips_what_it_cannot_attribute
