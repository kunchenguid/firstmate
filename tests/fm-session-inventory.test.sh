#!/usr/bin/env bash
# Behavior tests for the running-session inventory and its human renderer
# (bin/fm-session-inventory.sh, bin/fm-session-view.sh).
#
# The harness-session cases build REAL process trees out of a bash symlinked as
# "claude": a daemon process whose children are the background sessions. That is
# deliberate. Whether a process is a verified harness is decided by
# bin/fm-session-lock-lib.sh and the parent/child relation is a kernel fact, so
# these cases pin the classifier against real processes with no harness
# installed and no stubbed answer to the question under test. The live
# counterpart in tests/fm-session-inventory-live-e2e.test.sh exercises real
# installed harnesses on demand.
#
# Ages that must be deterministic come from sources whose clock the test owns -
# the backlog `since` date and file mtimes, read against
# FM_SESSION_INVENTORY_NOW_EPOCH - because a freshly spawned fixture process is
# always seconds old. Machine-wide shared services (a real Lavish server, the
# shared no-mistakes daemon) may legitimately appear on a developer machine, so
# no case asserts on total row counts; each asserts on the rows it created.
# shellcheck disable=SC2016 # single quotes are deliberate: $FAKE_CLAUDE and $1 expand inside the fake harness child, not here
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INVENTORY="$ROOT/bin/fm-session-inventory.sh"
VIEW="$ROOT/bin/fm-session-view.sh"
TMP_ROOT=$(fm_test_tmproot fm-session-inventory)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

FAKEBIN=$(fm_fakebin "$TMP_ROOT/fakebin")
ln -s /bin/bash "$FAKEBIN/claude"
FAKE_CLAUDE="$FAKEBIN/claude"

# The fleet snapshot underneath asks the backend and the validation daemon about
# every task it finds. Left to the real tools, each fixture task waits out a
# per-task bound against a window that was never created. Stub both: this suite
# is about the inventory built ON TOP of that snapshot, not about backend
# liveness, which tests/fm-fleet-snapshot-view.test.sh already owns.
fm_fake_exit0 "$FAKEBIN" no-mistakes
cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows) sed -n 's/^window=[^:]*://p' "${FM_HOME:?}"/state/*.meta 2>/dev/null ;;
  display-message) printf '%%1\n' ;;
  capture-pane) printf 'all quiet\n> \n' ;;
esac
exit 0
SH
chmod +x "$FAKEBIN/tmux"

# A fixed observation clock: 2026-09-06T12:00:00Z.
NOW_EPOCH=1788696000
DAY=86400

SPAWNED=""
# Kill the whole fixture tree, not just the daemon. Each fake session parents a
# sleeping process of its own, and a survivor both lingers for minutes and holds
# this suite stdout open - which is exactly how a seven-second run reports two
# minutes to the runner.
kill_tree() {  # <pid>
  local pid=$1 child
  for child in $(pgrep -P "$pid" 2>/dev/null); do
    kill_tree "$child"
  done
  kill -TERM "$pid" 2>/dev/null || true
}
kill_spawned() {
  local pid
  for pid in $SPAWNED; do
    kill_tree "$pid"
  done
  for pid in $SPAWNED; do
    wait "$pid" 2>/dev/null || true
  done
  SPAWNED=""
}
trap 'kill_spawned' EXIT

date_days_ago() {  # <n>
  local epoch=$((NOW_EPOCH - $1 * DAY))
  date -u -r "$epoch" +%Y-%m-%d 2>/dev/null || date -u -d "@$epoch" +%Y-%m-%d
}

# A home with no Lavish sessions at all: the listing is present and empty, which
# is a readable source reporting zero, not an unreadable one.
write_lavish_stub() {  # <fakebin> [<file> <status> <pending>]...
  local fakebin=$1 body='' count=0
  shift
  while [ "$#" -ge 3 ]; do
    body="$body  $1,$2,\"http://127.0.0.1:4387/session/sid$count\",$3\n"
    count=$((count + 1))
    shift 3
  done
  {
    printf '#!/usr/bin/env bash\n'
    printf 'printf "sessions[%s]{file,status,url,pending_prompts}:\\n"\n' "$count"
    [ "$count" -eq 0 ] || printf 'printf "%s"\n' "$body"
  } > "$fakebin/lavish-axi"
  chmod +x "$fakebin/lavish-axi"
}

# A stand-in for the harness pool directory. It must sit OUTSIDE the home, the
# way a real unclaimed pool process does: a directory inside the home would make
# the fixture claim its own pool as a session working in that home.
make_pool() {  # <home>
  local pool
  pool=$TMP_ROOT/pool-$(basename "$1")
  mkdir -p "$pool"
  printf '%s\n' "$pool"
}

make_home() {  # <name>
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state" "$home/data" "$home/projects" "$home/config"
  printf '%s\n' "$home"
}

# One in-flight ship task, aged through its backlog `since` date.
write_worker() {  # <home> <id> <days-old> [kind]
  local home=$1 id=$2 days=$3 kind=${4:-ship}
  mkdir -p "$home/projects/$id-worktree"
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$home/projects/$id-worktree" \
    "project=alpha" \
    "harness=claude" \
    "kind=$kind" \
    "mode=no-mistakes" \
    "yolo=off"
  printf -- '- [ ] %s - %s Task (repo: alpha) (kind: %s) (since %s)\n' \
    "$id" "$id" "$kind" "$(date_days_ago "$days")" >> "$home/data/backlog.md.inflight"
}

finish_backlog() {  # <home>
  local home=$1
  {
    printf '## In flight\n'
    cat "$home/data/backlog.md.inflight" 2>/dev/null || true
    printf '\n## Queued\n\n## Done\n'
  } > "$home/data/backlog.md"
  rm -f "$home/data/backlog.md.inflight"
}

run_inventory() {  # <home> <mode> [extra env assignments are the caller's]
  local home=$1 mode=$2
  FM_HOME="$home" FM_SESSION_INVENTORY_NOW_EPOCH="$NOW_EPOCH" \
    PATH="$FAKEBIN:$PATH" "$INVENTORY" "$mode"
}

# The same run, through a named shell. The system shell on macOS is bash 3.2,
# which is what firstmate's scripts have to keep working under.
run_inventory_with_shell() {  # <shell> <home> <mode>
  local shell=$1 home=$2 mode=$3
  FM_HOME="$home" FM_SESSION_INVENTORY_NOW_EPOCH="$NOW_EPOCH" \
    PATH="$FAKEBIN:$PATH" "$shell" "$INVENTORY" "$mode"
}

run_view() {  # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" FM_SESSION_INVENTORY_NOW_EPOCH="$NOW_EPOCH" \
    PATH="$FAKEBIN:$PATH" "$VIEW" "$@"
}

# The daemon body: read one argv line per child and launch each as its own
# harness-named process, so the kernel really records this process as their
# parent. Kept as a file rather than an inline -c string because the child argv
# has to reach ps unmangled.
# Every `sleep` below is followed by `:` on purpose. Given a single simple
# command, bash exec-collapses itself into it, and the child would show up as a
# bare `sleep` - losing both the harness name and the argv this fixture exists
# to present. The extra no-op keeps each fake session a real, correctly named
# process.
# Each spec line is "<cwd>|<argv>": a real working directory for the child plus
# the argv it should present. The working directory is what distinguishes a
# claimed session from an idle pool process, so the fixture has to set it for
# real rather than describe it.
DAEMON_BODY="$TMP_ROOT/fm-fake-daemon.sh"
cat > "$DAEMON_BODY" <<'SH'
#!/usr/bin/env bash
spec=$1
fake=$2
ready=$3
while IFS= read -r line; do
  [ -n "$line" ] || continue
  child_cwd=${line%%|*}
  child_argv=${line#*|}
  # shellcheck disable=SC2086 # deliberate: the spec line IS the child argv
  ( cd "$child_cwd" && exec "$fake" -c 'sleep 120; :' $child_argv ) &
done < "$spec"
: > "$ready"
sleep 120
:
SH

# Start a fake harness daemon and publish its pid in DAEMON_PID.
#
# Deliberately NOT `daemon=$(start_daemon_tree ...)`: a command substitution runs
# in a subshell that inherits this file EXIT trap, so the tree would be torn down
# by kill_spawned the instant the substitution returned.
DAEMON_PID=
start_daemon_tree() {  # <home> <child-argv-file>
  local home=$1 spec=$2 daemon_pid want waited=0 ready seen=0
  want=$(grep -c '[^[:space:]]' "$spec")
  ready="$home/daemon-ready"
  rm -f "$ready"
  # Detached from this suite stdio on purpose: a fixture process must never be
  # able to hold the test output pipe open.
  "$FAKE_CLAUDE" "$DAEMON_BODY" "$spec" "$FAKE_CLAUDE" "$ready" </dev/null >/dev/null 2>&1 &
  daemon_pid=$!
  SPAWNED="$SPAWNED $daemon_pid"
  # Wait until every fake session is a live, harness-named child of the daemon,
  # so no case observes a half-built tree.
  while [ "$waited" -lt 200 ]; do
    if [ -e "$ready" ]; then
      seen=$(pgrep -P "$daemon_pid" 2>/dev/null | while IFS= read -r c; do
        ps -o args= -p "$c" 2>/dev/null | grep -c -- "$FAKE_CLAUDE" || true
      done | LC_ALL=C awk '{ n += $1 } END { print n + 0 }')
      [ "${seen:-0}" -lt "$want" ] || break
    fi
    sleep 0.05
    waited=$((waited + 1))
  done
  [ "${seen:-0}" -ge "$want" ] \
    || fail "fixture did not build a $want-child harness tree under pid $daemon_pid (saw ${seen:-0})"
  DAEMON_PID=$daemon_pid
}

# --- cases -------------------------------------------------------------------

test_two_concurrent_sessions_are_ambiguous() {
  local home spec daemon json sessions owner rows pool
  home=$(make_home two-sessions)
  finish_backlog "$home"
  write_lavish_stub "$FAKEBIN"
  spec="$home/children"
  pool=$(make_pool "$home")
  cat > "$spec" <<EOF
$home|sess-a --session-id aaaa --agent claude --permission-mode bypassPermissions
$home|sess-b --session-id bbbb --agent claude --permission-mode bypassPermissions
$pool|pool-a --bg-spare /tmp/cc-daemon/spare/1111.claim.sock
EOF
  start_daemon_tree "$home" "$spec"
  daemon=$DAEMON_PID
  printf '%s\n' "$daemon" > "$home/state/.lock"

  json=$(run_inventory "$home" --json) || fail "inventory failed for two concurrent sessions"
  owner=$(printf '%s' "$json" | jq -r '.harness_sessions.lock_owner')
  sessions=$(printf '%s' "$json" | jq -r '.harness_sessions.sessions')
  [ "$owner" = ambiguous ] \
    || fail "two live sessions under one shared daemon must read as ambiguous, got '$owner'"
  [ "$sessions" = 2 ] || fail "expected 2 live sessions, got '$sessions'"

  rows=$(printf '%s' "$json" | jq -r '[.rows[] | select(.kind == "harness-session")
    | .detail] | sort | unique | join(" ")')
  [ "$rows" = "drives this home: ambiguous" ] \
    || fail "each live session must say it cannot be told apart: $rows"
  # The idle pool process is not this home's session and is not listed as one;
  # it is only counted, so nothing is claimed on another home's behalf.
  [ "$(printf '%s' "$json" | jq -r '.harness_sessions.elsewhere')" = 1 ] \
    || fail "an idle pool process must be counted as belonging elsewhere, not listed here"
  [ "$(printf '%s' "$json" | jq -r '[.rows[] | select(.kind == "harness-session")] | length')" = 2 ] \
    || fail "only the sessions working in this home may be listed"

  # The captain-facing surface must lead with the ambiguity, not bury it.
  local rendered
  rendered=$(COLUMNS=100 run_view "$home" --color never)
  assert_contains "$rendered" "2 background sessions are working in this home at once" \
    "the view must say plainly that two sessions are working in this home at once"

  kill_spawned
  pass "inventory: two concurrent background sessions read as ambiguous, and the view says so"
}

test_single_session_is_attributed_to_this_home() {
  local home spec daemon json owner drives pool
  home=$(make_home one-session)
  finish_backlog "$home"
  write_lavish_stub "$FAKEBIN"
  spec="$home/children"
  pool=$(make_pool "$home")
  cat > "$spec" <<EOF
$home|sess-a --session-id aaaa --agent claude --permission-mode bypassPermissions
$pool|pool-a --bg-spare /tmp/cc-daemon/spare/1111.claim.sock
$pool|pool-b --bg-spare /tmp/cc-daemon/spare/2222.claim.sock
EOF
  start_daemon_tree "$home" "$spec"
  daemon=$DAEMON_PID
  printf '%s\n' "$daemon" > "$home/state/.lock"

  json=$(run_inventory "$home" --json) || fail "inventory failed for a single session"
  owner=$(printf '%s' "$json" | jq -r '.harness_sessions.lock_owner')
  [ "$owner" = single ] || fail "one live session under the daemon must read as single, got '$owner'"
  drives=$(printf '%s' "$json" | jq -r '.rows[] | select(.kind == "harness-session") | .detail')
  [ "$drives" = "drives this home: yes" ] \
    || fail "the only live session under the lock-owning daemon drives this home, got '$drives'"
  # The two idle pool processes are working outside this home, so they are
  # counted as belonging elsewhere rather than listed as this home's sessions.
  [ "$(printf '%s' "$json" | jq -r '.harness_sessions.elsewhere')" = 2 ] \
    || fail "both idle pool processes must be accounted for as belonging elsewhere"

  kill_spawned
  pass "inventory: a single background session is attributed to this home"
}

# Argv must not decide anything. This fixture presents a process carrying BOTH a
# session token and a pool token - the shape a vendor rename or a reused spare
# produces - while working in this home. Where the process is working is the
# only signal that counts, so the contradiction in its argv changes nothing.
# This is the regression guard against reintroducing argv role classification.
test_contradictory_argv_does_not_decide_the_role() {
  local home spec daemon json pool
  home=$(make_home contradictory-argv)
  finish_backlog "$home"
  write_lavish_stub "$FAKEBIN"
  spec="$home/children"
  pool=$(make_pool "$home")
  cat > "$spec" <<EOF
$home|odd --session-id cccc --bg-spare /tmp/cc-daemon/spare/3333.claim.sock
EOF
  start_daemon_tree "$home" "$spec"
  daemon=$DAEMON_PID
  printf '%s\n' "$daemon" > "$home/state/.lock"

  json=$(run_inventory "$home" --json) || fail "inventory failed for a contradictory argv"
  [ "$(printf '%s' "$json" | jq -r '.harness_sessions.sessions')" = 1 ] \
    || fail "a process working in this home is a live session whatever its argv says"
  [ "$(printf '%s' "$json" | jq -r '.harness_sessions.elsewhere')" = 0 ] \
    || fail "a pool token must never move a process working in this home elsewhere"
  [ "$(printf '%s' "$json" | jq -r '.harness_sessions.lock_owner')" = single ] \
    || fail "one session working in this home reads as single"

  kill_spawned
  pass "inventory: a contradictory harness argv does not decide the role"
}

# THE MEASURED FAILURE. A harness pre-warms pooled processes and turns one into
# a session by CLAIMING it; the claimed process keeps the argv it was started
# with, so argv alone cannot tell a live session from an idle spare. What does
# change is the working directory: an unclaimed process still sits in the pool,
# and a claimed one is working in the home it was claimed for. Reported against
# the real fleet this was four live sessions in one home shown as zero.
test_claimed_pool_process_is_a_live_session() {
  local home spec daemon json pool
  home=$(make_home claimed-pool)
  finish_backlog "$home"
  write_lavish_stub "$FAKEBIN"
  pool=$(make_pool "$home")
  spec="$home/children"
  cat > "$spec" <<EOF
$home|claimed-a --bg-spare /tmp/cc-daemon/spare/aaaa.claim.sock
$pool|idle-a --bg-spare /tmp/cc-daemon/spare/bbbb.claim.sock
EOF
  start_daemon_tree "$home" "$spec"
  daemon=$DAEMON_PID
  printf '%s\n' "$daemon" > "$home/state/.lock"

  json=$(run_inventory "$home" --json) || fail "inventory failed for a claimed pool process"
  [ "$(printf '%s' "$json" | jq -r '.harness_sessions.sessions')" = 1 ] \
    || fail "a pool process working in this home is a live session, whatever argv it kept"
  [ "$(printf '%s' "$json" | jq -r '[.rows[] | select(.kind == "harness-session")] | length')" = 1 ] \
    || fail "the live session must be listed, and the still-idle one must not be"
  [ "$(printf '%s' "$json" | jq -r '.rows[] | select(.kind == "harness-session") | .detail')" \
    = "drives this home: yes" ] \
    || fail "a session working in this home drives it"

  kill_spawned
  pass "inventory: a claimed pool process working in this home counts as a live session"
}

# The concurrency hazard itself, in the shape it actually occurs: several
# claimed processes working in one home at once.
test_several_claimed_sessions_in_one_home_are_ambiguous() {
  local home spec daemon json pool
  home=$(make_home claimed-many)
  finish_backlog "$home"
  write_lavish_stub "$FAKEBIN"
  pool=$(make_pool "$home")
  spec="$home/children"
  cat > "$spec" <<EOF
$home|claimed-a --bg-spare /tmp/cc-daemon/spare/aaaa.claim.sock
$home|claimed-b --bg-spare /tmp/cc-daemon/spare/bbbb.claim.sock
$pool|idle-a --bg-spare /tmp/cc-daemon/spare/cccc.claim.sock
EOF
  start_daemon_tree "$home" "$spec"
  daemon=$DAEMON_PID
  printf '%s\n' "$daemon" > "$home/state/.lock"

  json=$(run_inventory "$home" --json) || fail "inventory failed for several claimed sessions"
  [ "$(printf '%s' "$json" | jq -r '.harness_sessions.sessions')" = 2 ] \
    || fail "both claimed processes working in this home must be counted"
  [ "$(printf '%s' "$json" | jq -r '.harness_sessions.lock_owner')" = ambiguous ] \
    || fail "two live sessions in one home is the ambiguity the captain must see"

  local rendered
  rendered=$(COLUMNS=100 run_view "$home" --color never)
  assert_contains "$rendered" "2 background sessions" \
    "the view must lead with the fact that two sessions share this home"

  kill_spawned
  pass "inventory: several claimed sessions in one home read as ambiguous"
}

test_stale_lock_pid_is_not_attributed() {
  local home json owner
  home=$(make_home stale-lock)
  finish_backlog "$home"
  write_lavish_stub "$FAKEBIN"
  printf '2147483646\n' > "$home/state/.lock"

  json=$(run_inventory "$home" --json) || fail "inventory failed for a stale lock"
  owner=$(printf '%s' "$json" | jq -r '.harness_sessions.lock_owner')
  [ "$owner" = stale ] || fail "a dead recorded lock pid must read as stale, got '$owner'"
  [ "$(printf '%s' "$json" | jq -r '[.rows[] | select(.kind == "harness-session")] | length')" = 0 ] \
    || fail "a home whose lock names no live harness must claim no sessions"
  [ "$(printf '%s' "$json" | jq -r '.sources[] | select(.name == "harness-sessions") | .ok')" = false ] \
    || fail "an unscopable harness must be disclosed as an unreadable source"

  pass "inventory: a stale lock pid is disclosed instead of attributed"
}

# A live lock-owning harness whose processes all work somewhere else is an
# ordinary state - a pool that has not been claimed for this home yet. It is
# also the one path with no session rows at all, and the command still has to
# produce its whole inventory there. Run through the SYSTEM shell on purpose:
# on macOS that is bash 3.2, where an unguarded empty-array expansion under
# `set -u` aborts the script, which would take the session-start notice with it.
test_a_harness_with_no_session_in_this_home_still_reports() {
  local home spec pool daemon json out
  home=$(make_home no-session-here)
  write_worker "$home" old-anchor 9
  finish_backlog "$home"
  write_lavish_stub "$FAKEBIN"
  pool=$(make_pool "$home")
  spec="$home/children"
  cat > "$spec" <<EOF
$pool|pool-a --bg-spare /tmp/cc-daemon/spare/1111.claim.sock
$pool|pool-b --bg-spare /tmp/cc-daemon/spare/2222.claim.sock
EOF
  start_daemon_tree "$home" "$spec"
  daemon=$DAEMON_PID
  printf '%s\n' "$daemon" > "$home/state/.lock"

  json=$(run_inventory_with_shell /bin/bash "$home" --json) \
    || fail "the inventory must still produce its output when no session works in this home"
  [ "$(printf '%s' "$json" | jq -r '.harness_sessions.lock_owner')" = none ] \
    || fail "a live harness with no process working in this home must read as none"
  [ "$(printf '%s' "$json" | jq -r '.harness_sessions.sessions')" = 0 ] \
    || fail "no session may be claimed for this home"
  [ "$(printf '%s' "$json" | jq -r '.harness_sessions.elsewhere')" = 2 ] \
    || fail "both pool processes must still be counted as belonging elsewhere"

  # And the unasked session-start line survives the same path: the rest of the
  # inventory is exactly what a session start would otherwise silently lose.
  out=$(run_inventory_with_shell /bin/bash "$home" --stale-lines) \
    || fail "--stale-lines must still run when no session works in this home"
  assert_contains "$out" "SESSIONS_STALE: worker old-anchor" \
    "overdue work must still be reported when this home has no session of its own"

  kill_spawned
  pass "inventory: a lock-owning harness with no session here still reports everything else"
}

# The overview is the surface the captain asks for in order to close things, and
# it is not the session-start line: it has no age cutoff and does not defer held
# work to the backlog. Every row it shows that CAN be closed shows how.
test_view_offers_a_close_command_for_every_closeable_row() {
  local home out
  home=$(make_home closeable-view)
  mkdir -p "$home/data"
  cat > "$home/data/backlog.md" <<EOF
## In flight
- [ ] fresh-task - Fresh Task (repo: alpha) (kind: ship) (since $(date_days_ago 0))
- [ ] held-task - Held Task (repo: alpha) (kind: ship) (since $(date_days_ago 40)) (hold: captain choice pending) (hold-kind: captain)

## Queued

## Done
EOF
  local id
  for id in fresh-task held-task; do
    mkdir -p "$home/projects/$id-worktree"
    fm_write_meta "$home/state/$id.meta" \
      "window=firstmate:fm-$id" \
      "worktree=$home/projects/$id-worktree" \
      "project=alpha" \
      "harness=claude" \
      "kind=ship" \
      "mode=no-mistakes" \
      "yolo=off"
  done
  write_lavish_stub "$FAKEBIN"

  out=$(COLUMNS=100 run_view "$home" --color never)
  assert_contains "$out" "FM_HOME=$home bin/fm-teardown.sh fresh-task" \
    "a worker that is nowhere near the stale threshold must still come with its close command"
  assert_contains "$out" "FM_HOME=$home bin/fm-teardown.sh held-task" \
    "captain-held work the captain can see must also be closeable from the same view"

  # The startup line keeps its own, narrower rule: nothing fresh, nothing held.
  out=$(run_inventory "$home" --stale-lines) || fail "--stale-lines failed"
  assert_not_contains "$out" "fresh-task" "the unasked line must stay bound to the stale threshold"
  assert_not_contains "$out" "held-task" "the unasked line must still leave held work to the backlog"

  # --stale-only narrows the whole view, close commands included.
  out=$(COLUMNS=100 run_view "$home" --color never --stale-only)
  assert_not_contains "$out" "fresh-task" "--stale-only must not offer to close what it does not show"

  pass "view: every row it shows with a close command carries that command"
}

# Close commands are printed to be pasted, and real artifact and home paths on
# this machine contain spaces. Both are executed here against stand-ins, so what
# is proven is what the printed line does when a shell runs it - never the real
# teardown or the real Lavish.
test_close_commands_stay_pasteable_when_paths_contain_spaces() {
  local home stage artifact close out
  home=$(make_home 'a home with spaces')
  mkdir -p "$home/data/board with notes"
  artifact="$home/data/board with notes/review page.html"
  printf '<html></html>\n' > "$artifact"
  write_worker "$home" ship-task 1
  finish_backlog "$home"
  write_lavish_stub "$FAKEBIN" "$artifact" open 0

  stage="$TMP_ROOT/paste-stage"
  mkdir -p "$stage/bin"
  cat > "$stage/bin/fm-teardown.sh" <<'SH'
#!/usr/bin/env bash
printf 'home=%s\nargc=%s\narg1=%s\n' "${FM_HOME:-}" "$#" "${1:-}"
SH
  cat > "$stage/lavish-axi" <<'SH'
#!/usr/bin/env bash
printf 'argc=%s\narg1=%s\narg2=%s\n' "$#" "${1:-}" "${2:-}"
SH
  chmod +x "$stage/bin/fm-teardown.sh" "$stage/lavish-axi"

  local json
  json=$(run_inventory "$home" --json) || fail "inventory failed for paths with spaces"

  close=$(printf '%s' "$json" | jq -r '.rows[] | select(.id == "ship-task") | .close')
  out=$(cd "$stage" && bash -c "$close") \
    || fail "the printed worker close command must run as a single command"
  assert_contains "$out" "home=$home" \
    "a home path with spaces must reach the close command as one value"
  assert_contains "$out" "argc=1" \
    "the close command must pass exactly the task id"

  close=$(printf '%s' "$json" | jq -r '.rows[] | select(.kind == "review") | .close')
  out=$(PATH="$stage:$PATH" bash -c "$close") \
    || fail "the printed review close command must run as a single command"
  assert_contains "$out" "argc=2" \
    "an artifact path with spaces must reach lavish-axi as one argument, not several"
  assert_contains "$out" "arg2=$artifact" \
    "the artifact path must arrive unaltered"

  pass "inventory: close commands stay pasteable when a path contains spaces"
}

# close_safety is advisory, and an advisory that reads "safe" over work that is
# only paused, blocked, or unreadable is worse than none. The vocabulary it
# judges is bin/fm-crew-state.sh's, so it has to be judged in those words.
test_unsettled_worker_state_is_never_presented_as_safe() {
  local home json gen state safety
  home=$(make_home unsettled-state)
  write_worker "$home" blocked-task 1
  write_worker "$home" done-task 1
  finish_backlog "$home"
  write_lavish_stub "$FAKEBIN"
  for id in blocked-task done-task; do
    gen=$("$ROOT/bin/fm-busy-event.sh" arm "$home/state" "$id")
    "$ROOT/bin/fm-busy-event.sh" apply "$home/state" "$id" idle --gen "$gen" \
      --source claude-hook --event stop
  done
  printf 'blocked: waiting on access\n' > "$home/state/blocked-task.status"
  printf 'done: landed\n' > "$home/state/done-task.status"

  json=$(run_inventory "$home" --json) || fail "inventory failed for unsettled worker state"
  state=$(printf '%s' "$json" | jq -r '.rows[] | select(.id == "blocked-task") | .detail')
  safety=$(printf '%s' "$json" | jq -r '.rows[] | select(.id == "blocked-task") | .close_safety')
  [ "$safety" = confirm ] \
    || fail "a blocked worker may still hold unlanded work and must need a decision, got '$safety' ($state)"
  [ "$(printf '%s' "$json" | jq -r '.rows[] | select(.id == "blocked-task") | .close_note')" != null ] \
    || fail "a row that needs a decision must say why"
  [ "$(printf '%s' "$json" | jq -r '.rows[] | select(.id == "done-task") | .close_safety')" = safe ] \
    || fail "finished work must still be reported as safe to clean up"

  pass "inventory: a worker that is not settled is never presented as safe to close"
}

test_nothing_old_prints_nothing_at_session_start() {
  local home out
  home=$(make_home nothing-old)
  write_worker "$home" fresh-task 0
  finish_backlog "$home"
  write_lavish_stub "$FAKEBIN"

  out=$(run_inventory "$home" --stale-lines) || fail "--stale-lines failed on a fresh home"
  [ -z "$out" ] || fail "a home with nothing old must print no session-start lines, got: $out"

  # Same home, every threshold pushed out of reach: the view says so in words
  # rather than printing an empty table.
  out=$(FM_SESSION_STALE_DAYS=36500 COLUMNS=100 run_view "$home" --color never --stale-only)
  assert_contains "$out" "Nothing is older than 36500 days." \
    "--stale-only must say plainly that nothing is old"

  pass "inventory: nothing older than the threshold prints nothing unasked"
}

test_stale_rows_carry_their_exact_close_command() {
  local home json out
  home=$(make_home stale-rows)
  write_worker "$home" old-ship 9
  write_worker "$home" new-ship 1
  finish_backlog "$home"
  write_lavish_stub "$FAKEBIN"

  json=$(run_inventory "$home" --json) || fail "inventory failed for stale rows"
  [ "$(printf '%s' "$json" | jq -r '.rows[] | select(.id == "old-ship") | "\(.age_days) \(.stale) \(.notify) \(.age_source)"')" \
    = "9 true true backlog-since" ] \
    || fail "a nine-day-old worker must be stale, notifiable, and aged from its backlog date"
  [ "$(printf '%s' "$json" | jq -r '.rows[] | select(.id == "new-ship") | .stale')" = false ] \
    || fail "a one-day-old worker must not be marked stale"
  [ "$(printf '%s' "$json" | jq -r '.rows[] | select(.id == "old-ship") | .close')" \
    = "FM_HOME=$home bin/fm-teardown.sh old-ship" ] \
    || fail "a worker row must carry the guarded cleanup command for its own home"

  out=$(run_inventory "$home" --stale-lines) || fail "--stale-lines failed"
  assert_contains "$out" "SESSIONS_STALE: worker old-ship - 9d" \
    "the session-start line must name the old worker and its age"
  assert_contains "$out" "close: FM_HOME=$home bin/fm-teardown.sh old-ship" \
    "the session-start line must carry the exact close command"
  assert_not_contains "$out" "new-ship" \
    "the session-start line must name only what is over the threshold"

  pass "inventory: stale rows carry their age and their exact close command"
}

# The unasked line is the only place a background session is named without the
# captain asking for it, so it has to name the one thing that identifies it: its
# pid, which is also what the close command below it kills.
test_stale_session_line_names_the_pid() {
  local home spec daemon out
  home=$(make_home stale-session-line)
  finish_backlog "$home"
  write_lavish_stub "$FAKEBIN"
  spec="$home/children"
  printf '%s|sess-a --session-id aaaa --agent claude --permission-mode bypassPermissions\n' \
    "$home" > "$spec"
  start_daemon_tree "$home" "$spec"
  daemon=$DAEMON_PID
  printf '%s\n' "$daemon" > "$home/state/.lock"

  # A fixture session is seconds old, so the threshold comes down to it instead.
  out=$(FM_SESSION_STALE_DAYS=0 run_inventory "$home" --stale-lines) \
    || fail "--stale-lines failed with a live background session"

  local pid
  pid=$(FM_SESSION_STALE_DAYS=0 run_inventory "$home" --json \
    | jq -r '.rows[] | select(.kind == "harness-session") | .id')
  [ -n "$pid" ] || fail "the fixture session was not listed as this home's"
  assert_contains "$out" "SESSIONS_STALE: background session $pid" \
    "the unasked line must name the session by the pid its close command kills"
  assert_contains "$out" "close: kill $pid" \
    "the unasked line must carry the exact close command for that pid"
  assert_not_contains "$out" "background session (" \
    "the unasked line must not pad the session name with a parenthetical that names nothing"

  kill_spawned
  pass "inventory: the unasked line names an overdue background session by its pid"
}

test_row_without_a_safe_close_stays_out_of_the_unasked_line() {
  local home json out
  home=$(make_home manual-close)
  write_worker "$home" old-mate 12 secondmate
  finish_backlog "$home"
  write_lavish_stub "$FAKEBIN"

  json=$(run_inventory "$home" --json) || fail "inventory failed for a manual-close row"
  [ "$(printf '%s' "$json" | jq -r '.rows[] | select(.id == "old-mate") | "\(.stale) \(.notify) \(.close_safety) \(.close)"')" \
    = "true false manual null" ] \
    || fail "a persistent second mate must stay visible and stale but carry no close command"

  out=$(run_inventory "$home" --stale-lines) || fail "--stale-lines failed"
  assert_not_contains "$out" "old-mate" \
    "a row with no single safe close command must not occupy the unasked session-start line"

  out=$(COLUMNS=100 run_view "$home" --color never)
  assert_contains "$out" "old-mate" "the view must still show it"

  pass "inventory: a row with no safe close command stays visible but out of the unasked line"
}

# A task the captain is deliberately holding is not an overdue running session.
# The backlog captain-hold lifecycle already surfaces it, so repeating it in the
# unasked session-start line would report one parked decision from two places.
# THE SECOND MEASURED FAILURE. The age column answered "how old is the task",
# not "how long has this been running". A task thought up last week and started
# ten minutes ago was flagged as overdue, which makes the warning worthless.
# What costs the captain money and attention is running time, so that is what
# the threshold keys on; task age is still reported, separately.
test_worker_age_is_running_time_not_task_age() {
  local home spec daemon json pool worktree
  home=$(make_home runtime-age)
  worktree="$home/projects/fresh-worker-worktree"
  mkdir -p "$worktree"
  write_worker "$home" fresh-worker 30
  finish_backlog "$home"
  write_lavish_stub "$FAKEBIN"
  # A worker whose task was filed a month ago but whose process started moments
  # ago: the process is working in the recorded worktree, which is what ties the
  # two together.
  pool=$(make_pool "$home")
  spec="$home/children"
  cat > "$spec" <<EOF
$worktree|worker-proc --session-id dddd --agent claude
EOF
  start_daemon_tree "$home" "$spec"
  daemon=$DAEMON_PID
  printf '%s\n' "$daemon" > "$home/state/.lock"

  json=$(run_inventory "$home" --json) || fail "inventory failed for a freshly started worker"
  [ "$(printf '%s' "$json" | jq -r '.rows[] | select(.id == "fresh-worker") | .age_source')" = process ] \
    || fail "a worker with a live process must be aged from that process, not from its task record"
  [ "$(printf '%s' "$json" | jq -r '.rows[] | select(.id == "fresh-worker") | .age_days')" = 0 ] \
    || fail "a worker that started moments ago has not been running for days"
  [ "$(printf '%s' "$json" | jq -r '.rows[] | select(.id == "fresh-worker") | .stale')" = false ] \
    || fail "an old task with a fresh worker must not be flagged as overdue"
  [ "$(printf '%s' "$json" | jq -r '.rows[] | select(.id == "fresh-worker") | .task_age_days')" = 30 ] \
    || fail "the task age must still be reported, separately from running time"

  local out
  out=$(run_inventory "$home" --stale-lines) || fail "--stale-lines failed"
  assert_not_contains "$out" "fresh-worker" \
    "a worker running for minutes must never occupy the unasked session-start line"

  out=$(COLUMNS=110 run_view "$home" --color never)
  assert_contains "$out" "TASK" "the view must show task age as its own column"

  kill_spawned
  pass "inventory: a worker is aged by its running time, with task age reported separately"
}

# The other direction, and the case the captain actually complained about: a
# worker with no live process is abandoned work still holding a worktree. It is
# aged by the work's own date and stays in the overdue warning, because dropping
# it would silently hide the thing he asked to be told about.
test_worker_with_no_live_process_is_aged_by_its_task() {
  local home json out
  home=$(make_home no-process)
  write_worker "$home" gone-worker 30
  finish_backlog "$home"
  write_lavish_stub "$FAKEBIN"

  json=$(run_inventory "$home" --json) || fail "inventory failed for a worker with no live process"
  [ "$(printf '%s' "$json" | jq -r '.rows[] | select(.id == "gone-worker") | .age_source')" = backlog-since ] \
    || fail "with nothing running, the work's own date is the honest age"
  [ "$(printf '%s' "$json" | jq -r '.rows[] | select(.id == "gone-worker") | .age_days')" = 30 ] \
    || fail "a worker abandoned for 30 days is 30 days old"
  [ "$(printf '%s' "$json" | jq -r '.rows[] | select(.id == "gone-worker") | .stale')" = true ] \
    || fail "abandoned work past the threshold must still be marked overdue"
  [ "$(printf '%s' "$json" | jq -r '.rows[] | select(.id == "gone-worker") | .task_age_days')" = 30 ] \
    || fail "the task age is still reported in its own field"

  out=$(run_inventory "$home" --stale-lines) || fail "--stale-lines failed"
  assert_contains "$out" "gone-worker" \
    "abandoned work past the threshold belongs in the unasked session-start line"

  pass "inventory: a worker with no live process is aged by its task and stays overdue"
}

test_captain_held_work_stays_out_of_the_unasked_line() {
  local home json out
  home=$(make_home held)
  mkdir -p "$home/data"
  cat > "$home/data/backlog.md" <<EOF
## In flight
- [ ] held-task - Held Task (repo: alpha) (kind: ship) (since $(date_days_ago 40)) (hold: captain choice pending) (hold-kind: captain)
- [ ] plain-task - Plain Task (repo: alpha) (kind: ship) (since $(date_days_ago 40))

## Queued

## Done
EOF
  local id
  for id in held-task plain-task; do
    fm_write_meta "$home/state/$id.meta" \
      "window=firstmate:fm-$id" \
      "worktree=$home/projects/$id-worktree" \
      "project=alpha" \
      "harness=claude" \
      "kind=ship" \
      "mode=no-mistakes" \
      "yolo=off"
  done
  write_lavish_stub "$FAKEBIN"

  json=$(run_inventory "$home" --json) || fail "inventory failed for captain-held work"
  [ "$(printf '%s' "$json" | jq -r '.rows[] | select(.id == "held-task") | "\(.held) \(.stale) \(.notify)"')" \
    = "true true false" ] \
    || fail "captain-held work must stay visible and stale but out of the unasked notice"
  [ "$(printf '%s' "$json" | jq -r '.rows[] | select(.id == "plain-task") | "\(.held) \(.stale) \(.notify)"')" \
    = "false true true" ] \
    || fail "unheld work of the same age must still be reported"

  out=$(run_inventory "$home" --stale-lines) || fail "--stale-lines failed"
  assert_contains "$out" "worker plain-task" "unheld overdue work must be named"
  assert_not_contains "$out" "held-task" \
    "a task the captain is holding must not be reported again as an overdue session"

  out=$(COLUMNS=100 run_view "$home" --color never)
  assert_contains "$out" "held-task" "the view must still show captain-held work with its age"

  pass "inventory: captain-held work stays visible but out of the unasked line"
}

test_review_pages_are_listed_and_aged() {
  local home json artifact
  home=$(make_home reviews)
  finish_backlog "$home"
  mkdir -p "$home/data/board/lavish"
  artifact="$home/data/board/lavish/index.html"
  printf '<html></html>\n' > "$artifact"
  touch -t "$(date -u -r $((NOW_EPOCH - 5 * DAY)) +%Y%m%d%H%M 2>/dev/null \
    || date -u -d "@$((NOW_EPOCH - 5 * DAY))" +%Y%m%d%H%M)" "$artifact"
  write_lavish_stub "$FAKEBIN" "$artifact" open 0

  json=$(run_inventory "$home" --json) || fail "inventory failed for review pages"
  [ "$(printf '%s' "$json" | jq -r '.rows[] | select(.kind == "review" and .label == "index.html")
      | "\(.age_days) \(.stale) \(.age_source) \(.close_safety)"')" = "5 true file-mtime safe" ] \
    || fail "an untouched review page must be aged from its own artifact and be safe to close"
  [ "$(printf '%s' "$json" | jq -r '.rows[] | select(.kind == "review" and .label == "index.html") | .close')" \
    = "lavish-axi end $artifact" ] \
    || fail "a review row must carry the supported end command for its own artifact"

  pass "inventory: open review pages are listed, aged, and closeable"
}

test_review_page_with_queued_notes_needs_confirmation() {
  local home json artifact
  home=$(make_home reviews-pending)
  finish_backlog "$home"
  mkdir -p "$home/data/board/lavish"
  artifact="$home/data/board/lavish/index.html"
  printf '<html></html>\n' > "$artifact"
  write_lavish_stub "$FAKEBIN" "$artifact" open 2

  json=$(run_inventory "$home" --json) || fail "inventory failed for a review page with queued notes"
  [ "$(printf '%s' "$json" | jq -r '.rows[] | select(.kind == "review") | .close_safety')" = confirm ] \
    || fail "queued captain notes must make closing a review page need confirmation first"

  pass "inventory: a review page holding queued notes is never presented as safe to close"
}

test_unreadable_source_is_disclosed_not_counted_as_zero() {
  local home json
  home=$(make_home unreadable)
  finish_backlog "$home"
  cat > "$FAKEBIN/lavish-axi" <<'SH'
#!/usr/bin/env bash
echo "error: something went wrong" >&2
exit 1
SH
  chmod +x "$FAKEBIN/lavish-axi"

  json=$(run_inventory "$home" --json) || fail "inventory failed when Lavish could not be read"
  [ "$(printf '%s' "$json" | jq -r '.sources[] | select(.name == "lavish") | .ok')" = false ] \
    || fail "a Lavish listing that could not be read must be disclosed as unreadable"
  [ -n "$(printf '%s' "$json" | jq -r '.sources[] | select(.name == "lavish") | .reason')" ] \
    || fail "an unreadable source must name why"

  local rendered
  rendered=$(COLUMNS=100 run_view "$home" --color never)
  assert_contains "$rendered" "lavish unreadable:" \
    "the view must show an unreadable source rather than implying there is nothing open"

  write_lavish_stub "$FAKEBIN"
  pass "inventory: an unreadable source is disclosed instead of reported as zero"
}

test_view_is_readable_narrow_and_without_colour() {
  local home plain narrow coloured longest
  home=$(make_home rendering)
  write_worker "$home" a-very-long-worker-identifier-for-width 9
  finish_backlog "$home"
  write_lavish_stub "$FAKEBIN"

  plain=$(COLUMNS=100 run_view "$home" --color never)
  case "$plain" in
    *$'\033'*) fail "--color never must emit no escape sequences" ;;
  esac
  assert_contains "$plain" "! worker" "a stale row must be marked with text, not colour alone"

  # Narrow pane: every TABLE line fits the pane. The title, a source
  # diagnostic, and the close commands are deliberately left whole to wrap
  # rather than be cut, because a truncated home path, reason, or command is
  # worse than a wrapped one.
  narrow=$(COLUMNS=50 run_view "$home" --color never)
  longest=$(printf '%s\n' "$narrow" | LC_ALL=C awk '
      /^ *KIND +WHAT/ { intable = 1 }
      /^To close/ { intable = 0 }
      intable { print length }' | sort -n | tail -1)
  [ -n "$longest" ] && [ "$longest" -le 50 ] \
    || fail "the table must fit a 50-column pane, longest table line was ${longest:-unknown}"
  assert_contains "$narrow" "FM_HOME=$home bin/fm-teardown.sh a-very-long-worker-identifier-for-width" \
    "a close command must never be truncated, however narrow the pane"

  coloured=$(COLUMNS=100 run_view "$home" --color always)
  case "$coloured" in
    *$'\033'[*) ;;
    *) fail "--color always must emit escape sequences" ;;
  esac

  pass "view: readable without colour and in a narrow pane, with close commands intact"
}

test_view_refuses_a_cadence_below_the_floor() {
  local home status=0
  home=$(make_home cadence)
  finish_backlog "$home"
  write_lavish_stub "$FAKEBIN"
  run_view "$home" --watch --interval 5 >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "a redraw faster than the supervision floor must be refused, not accepted"
  pass "view: refuses a redraw cadence that would poll harder than supervision"
}

# The read-only, no-network promise is the reason this is safe both on the
# blocking session-start path and in a pane that redraws on a timer. The
# snapshot underneath reads remote secondmate ledgers over the network and
# refreshes a parent-side cache unless it is told not to, so the guard is that
# the inventory asks for local-only collection and that a remote home is then
# reported unread rather than quietly treated as absent.
test_inventory_makes_no_cross_home_network_read() {
  local home json cache
  home=$(make_home local-only)
  finish_backlog "$home"
  write_lavish_stub "$FAKEBIN"
  cat > "$home/data/secondmates.md" <<'EOF'
# Secondmates

- remote-mate - remote helper (host: unreachable.invalid; root: /srv/fm; home: /srv/fm/home; scope: nothing; projects: none; added 2026-01-01)
EOF
  cache="$home/state/secondmate-summary-cache"

  json=$(run_inventory "$home" --json) || fail "inventory failed with a remote secondmate registered"
  [ ! -e "$cache" ] \
    || fail "the inventory must not refresh the cross-home summary cache; it runs on the blocking startup path"

  # And the same collection, asked for directly, must say plainly that it did
  # not read the remote home rather than reporting it as absent.
  local snap
  snap=$(FM_HOME="$home" FM_SNAPSHOT_LOCAL_ONLY=1 "$ROOT/bin/fm-fleet-snapshot.sh" --json) \
    || fail "the local-only fleet snapshot failed"
  [ "$(printf '%s' "$snap" | jq -r '[.secondmate_current.records[]? | select(.id == "remote-mate")] | length')" = 1 ] \
    || fail "a registered remote home must still appear, so it is never silently dropped"
  printf '%s' "$snap" | jq -e '.secondmate_current.records[]
    | select(.id == "remote-mate")
    | select(.current.state == "unknown")
    | select((.current.reason // "") | test("cross-home collection was not run"))' >/dev/null \
    || fail "a remote home that was deliberately not read must be unknown, with that reason"
  [ ! -e "$cache" ] || fail "local-only collection must refresh no cache"

  pass "inventory: no cross-home network read, and an unread remote home says so"
}

# A home reached through a symlink is the ordinary case on macOS, where TMPDIR
# itself is one (/var -> /private/var). The kernel reports every process working
# directory with the symlinks already resolved, so a home compared in its
# logical form matches none of its own running processes: the sessions would be
# counted as belonging elsewhere and the overview would report zero while four
# are running - silently, with every source still reported ok. Both sides have
# to be physical, so this drives the command through the symlink and demands the
# same answer the real path gives.
test_a_home_reached_through_a_symlink_still_finds_what_runs_in_it() {
  local home link spec daemon json worktree
  home=$(make_home symlinked)
  link="$TMP_ROOT/symlinked-link"
  rm -f "$link"
  ln -s "$home" "$link" || fail "could not build the symlinked home fixture"

  # The worker's recorded worktree is a SYMLINKED path too, while the process
  # running in it reports the real one - the same split, one level down. It sits
  # outside the home, like a real worktree, so it stays a worker question rather
  # than becoming a second session working inside this home.
  worktree="$TMP_ROOT/symlinked-worktree-link"
  mkdir -p "$TMP_ROOT/symlinked-worktree"
  rm -f "$worktree"
  ln -s "$TMP_ROOT/symlinked-worktree" "$worktree" \
    || fail "could not build the symlinked worktree fixture"
  fm_write_meta "$home/state/ship-task.meta" \
    "window=firstmate:fm-ship-task" \
    "worktree=$worktree" \
    "project=alpha" \
    "harness=claude" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off"
  printf -- '- [ ] ship-task - Ship Task (repo: alpha) (kind: ship) (since %s)\n' \
    "$(date_days_ago 30)" >> "$home/data/backlog.md.inflight"
  finish_backlog "$home"
  write_lavish_stub "$FAKEBIN"

  spec="$home/children"
  cat > "$spec" <<EOF
$home|sess-a --session-id aaaa --agent claude
$TMP_ROOT/symlinked-worktree|work-a --session-id bbbb --agent claude
EOF
  start_daemon_tree "$home" "$spec"
  daemon=$DAEMON_PID
  printf '%s\n' "$daemon" > "$home/state/.lock"

  json=$(run_inventory "$link" --json) || fail "inventory failed for a symlinked home"
  [ "$(printf '%s' "$json" | jq -r '.harness_sessions.lock_owner')" = single ] \
    || fail "a session working in a symlinked home must still be attributed to it, got '$(printf '%s' "$json" | jq -r '.harness_sessions.lock_owner')'"
  [ "$(printf '%s' "$json" | jq -r '.harness_sessions.sessions')" = 1 ] \
    || fail "a symlinked home reported none of its own live sessions"

  # A worker with a live process in its worktree is aged by that process, not by
  # the month-old task date - which is only true if the worktree matched too.
  [ "$(printf '%s' "$json" | jq -r '.rows[] | select(.id == "ship-task") | .age_source')" = process \
    ] || fail "a worktree reached through a symlink did not match its own running process"

  kill_spawned
  pass "inventory: a home reached through a symlink still finds the sessions and workers running in it"
}

# The bootstrap runs inside the lock-owning session, whose working directory is
# this home by construction, so the captain's own session is always one of the
# rows. Handing him `kill <pid>` for the conversation he is having is worse than
# telling him nothing at all, so that one row is marked and carries no command.
test_the_session_running_the_command_is_never_offered_for_closing() {
  local home runner json pid self rendered
  home=$(make_home own-session)
  finish_backlog "$home"
  write_lavish_stub "$FAKEBIN"

  # A real harness-named ancestor of the command, working in this home: exactly
  # the shape a session-start bootstrap has. The trailing `:` keeps bash from
  # collapsing itself into the command it runs, which would replace the harness
  # process this fixture exists to be.
  runner="$TMP_ROOT/own-session-runner.sh"
  cat > "$runner" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$FM_HOME/state/.lock"
"$@"
:
SH
  chmod +x "$runner"

  # <mode...>: run the given command from inside that session, in this home.
  run_from_own_session() {
    (cd "$home" && FM_HOME="$home" FM_SESSION_INVENTORY_NOW_EPOCH="$NOW_EPOCH" \
      PATH="$FAKEBIN:$PATH" "$FAKE_CLAUDE" "$runner" "$@")
  }

  json=$(run_from_own_session "$INVENTORY" --json) \
    || fail "inventory failed when run from inside a live session"

  pid=$(printf '%s' "$json" | jq -r '.rows[] | select(.kind == "harness-session") | .id')
  [ -n "$pid" ] || fail "the session running the command was not listed at all"
  self=$(printf '%s' "$json" | jq -r '.rows[] | select(.kind == "harness-session")
    | "\(.self) \(.close) \(.close_safety)"')
  [ "$self" = "true null manual" ] \
    || fail "the session running the command must be marked as such and carry no close command, got '$self'"

  # The unasked session-start line must not offer it either, at any age.
  local out
  out=$(FM_SESSION_STALE_DAYS=0 run_from_own_session "$INVENTORY" --stale-lines) \
    || fail "--stale-lines failed when run from inside a live session"
  assert_not_contains "$out" "kill" \
    "the unasked line must never hand the captain a kill for his own session"

  # Each run is its own session, so the pid above belongs to the run above; what
  # must hold for every run is the marking and the absent kill.
  rendered=$(COLUMNS=100 run_from_own_session "$VIEW" --color never) \
    || fail "the view failed when run from inside a live session"
  assert_contains "$rendered" "live session (yours)" \
    "the view must mark the session the captain is reading it from"
  assert_not_contains "$rendered" "kill " \
    "the view must not put the captain's own session in the To close block"

  pass "inventory: the session running the command is marked and never offered as one to close"
}

# The Lavish listing is machine-wide by intent - the captain works across many
# projects and asked to see all of those pages. An unasked session-start line is
# a different budget: every home on the machine would otherwise print the same
# review lines at every start. The main home says them; a secondmate home leaves
# them to it, and the pages themselves stay in --json for both.
test_a_secondmate_home_leaves_the_unasked_review_lines_to_the_main_home() {
  local main mate artifact out
  main=$(make_home review-main)
  mate=$(make_home review-mate)
  finish_backlog "$main"
  finish_backlog "$mate"
  printf 'mate-one\n' > "$mate/.fm-secondmate-home"

  artifact="$TMP_ROOT/elsewhere-project/plan.html"
  mkdir -p "$(dirname "$artifact")"
  printf '<html></html>\n' > "$artifact"
  touch -t "$(date -u -r "$((NOW_EPOCH - 30 * DAY))" +%Y%m%d%H%M 2>/dev/null \
    || date -u -d "@$((NOW_EPOCH - 30 * DAY))" +%Y%m%d%H%M)" "$artifact"
  write_lavish_stub "$FAKEBIN" "$artifact" open 0

  out=$(run_inventory "$main" --stale-lines) || fail "--stale-lines failed for the main home"
  assert_contains "$out" "review page plan.html" \
    "the main home must still name an overdue review page unasked"

  out=$(run_inventory "$mate" --stale-lines) || fail "--stale-lines failed for a secondmate home"
  assert_not_contains "$out" "plan.html" \
    "a secondmate home must not repeat the machine-wide review pages the main home already names"

  # The pages themselves are not scoped away: both homes still list them.
  [ "$(run_inventory "$mate" --json | jq -r '[.rows[] | select(.kind == "review")] | length')" = 1 ] \
    || fail "a secondmate home must still SHOW the machine-wide review pages"

  pass "inventory: the unasked review lines come from the main home, while every home still lists the pages"
}

# Every close command is printed to be pasted exactly as shown. A listener id
# comes from a state/procevent/<id>.runner filename rather than from a validated
# registration, so it gets the same quoting the worker and review commands do.
test_a_listener_close_command_survives_an_id_that_needs_quoting() {
  local home stage json close out
  home=$(make_home listener-quoting)
  finish_backlog "$home"
  write_lavish_stub "$FAKEBIN"
  mkdir -p "$home/state/procevent"
  printf '%s\n' "$$" > "$home/state/procevent/odd id.runner"

  json=$(run_inventory "$home" --json) || fail "inventory failed for a listener id with a space"
  close=$(printf '%s' "$json" | jq -r '.rows[] | select(.id == "listener-odd id") | .close')
  [ -n "$close" ] && [ "$close" != null ] || fail "the listener row carried no close command"

  stage="$TMP_ROOT/listener-stage"
  mkdir -p "$stage/bin"
  cat > "$stage/bin/fm-procevent.sh" <<'SH'
#!/usr/bin/env bash
printf 'argc=%s\narg1=%s\narg2=%s\n' "$#" "${1:-}" "${2:-}"
SH
  chmod +x "$stage/bin/fm-procevent.sh"

  out=$(cd "$stage" && bash -c "$close") \
    || fail "the printed listener close command must run as a single command"
  assert_contains "$out" "argc=2" \
    "a listener id with a space must reach fm-procevent.sh as one argument, not two"
  assert_contains "$out" "arg2=odd id" "the listener id must arrive unaltered"

  pass "inventory: a listener close command stays pasteable when its id needs quoting"
}

# The overview redraws on a timer and sits on the blocking session-start path,
# so a pass must write nothing at all. The one state file a classification pass
# would otherwise touch is muse's memo of the session log it resolved, which it
# rewrites and clears concurrently with the watcher that owns it.
# bin/fm-busy-lib.sh owns the read-only rule; this pins that the overview
# actually reaches it through the snapshot underneath.
test_inventory_does_not_rewrite_the_busy_classifier_cache() {
  local home cache
  home=$(make_home busy-cache)
  write_worker "$home" muse-task 1
  finish_backlog "$home"
  write_lavish_stub "$FAKEBIN"
  # The worker's recorded harness is what selects the classifier path.
  fm_write_meta "$home/state/muse-task.meta" \
    "window=firstmate:fm-muse-task" \
    "worktree=$home/projects/muse-task-worktree" \
    "project=alpha" \
    "harness=muse" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off"
  mkdir -p "$home/muse-sessions"
  printf 'sessions_root=%s\nworkspace_root=%s\nbinding_id=one\n' \
    "$home/muse-sessions" "$home/projects/muse-task-worktree" \
    > "$home/state/muse-task.muse-session"
  cache="$home/state/muse-task.muse-session-current"
  printf 'binding_id=retired\nsession_log=%s\n' "$home/gone.jsonl" > "$cache"

  run_inventory "$home" --json >/dev/null || fail "inventory failed for a muse worker"

  [ -f "$cache" ] || fail "the overview removed a state file the watcher owns"
  assert_contains "$(cat "$cache")" "binding_id=retired" \
    "the overview rewrote a state file it is only supposed to read"

  pass "inventory: a pass writes nothing, the busy classifier's own cache included"
}

test_inventory_closes_nothing_it_reports() {
  local home spec daemon children pid pool
  home=$(make_home read-only)
  finish_backlog "$home"
  write_lavish_stub "$FAKEBIN"
  spec="$home/children"
  pool=$(make_pool "$home")
  cat > "$spec" <<EOF
$home|sess-a --session-id aaaa --agent claude
$pool|pool-a --bg-spare /tmp/cc-daemon/spare/1111.claim.sock
EOF
  start_daemon_tree "$home" "$spec"
  daemon=$DAEMON_PID
  printf '%s\n' "$daemon" > "$home/state/.lock"
  children=$(pgrep -P "$daemon" | tr '\n' ' ')

  run_inventory "$home" --json >/dev/null || fail "inventory failed"
  COLUMNS=100 run_view "$home" --color never >/dev/null || fail "view failed"

  kill -0 "$daemon" 2>/dev/null || fail "the inventory must never signal the harness daemon it reports"
  for pid in $children; do
    kill -0 "$pid" 2>/dev/null \
      || fail "the inventory must never signal a background session it reports (pid $pid)"
  done
  [ ! -e "$home/state/.watch.lock" ] || fail "the inventory must not arm or touch the watcher"
  [ "$(cat "$home/state/.lock")" = "$daemon" ] || fail "the inventory must not rewrite the session lock"

  kill_spawned
  pass "inventory: reports every running thing without closing, signalling, or locking anything"
}

test_two_concurrent_sessions_are_ambiguous
test_single_session_is_attributed_to_this_home
test_claimed_pool_process_is_a_live_session
test_several_claimed_sessions_in_one_home_are_ambiguous
test_contradictory_argv_does_not_decide_the_role
test_stale_lock_pid_is_not_attributed
test_a_harness_with_no_session_in_this_home_still_reports
test_nothing_old_prints_nothing_at_session_start
test_view_offers_a_close_command_for_every_closeable_row
test_close_commands_stay_pasteable_when_paths_contain_spaces
test_unsettled_worker_state_is_never_presented_as_safe
test_stale_rows_carry_their_exact_close_command
test_stale_session_line_names_the_pid
test_worker_age_is_running_time_not_task_age
test_worker_with_no_live_process_is_aged_by_its_task
test_row_without_a_safe_close_stays_out_of_the_unasked_line
test_captain_held_work_stays_out_of_the_unasked_line
test_review_pages_are_listed_and_aged
test_review_page_with_queued_notes_needs_confirmation
test_unreadable_source_is_disclosed_not_counted_as_zero
test_view_is_readable_narrow_and_without_colour
test_view_refuses_a_cadence_below_the_floor
test_inventory_makes_no_cross_home_network_read
test_a_home_reached_through_a_symlink_still_finds_what_runs_in_it
test_the_session_running_the_command_is_never_offered_for_closing
test_a_secondmate_home_leaves_the_unasked_review_lines_to_the_main_home
test_a_listener_close_command_survives_an_id_that_needs_quoting
test_inventory_does_not_rewrite_the_busy_classifier_cache
test_inventory_closes_nothing_it_reports
