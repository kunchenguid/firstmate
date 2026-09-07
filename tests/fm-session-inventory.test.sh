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
DAEMON_BODY="$TMP_ROOT/fm-fake-daemon.sh"
cat > "$DAEMON_BODY" <<'SH'
#!/usr/bin/env bash
spec=$1
fake=$2
ready=$3
while IFS= read -r line; do
  [ -n "$line" ] || continue
  # shellcheck disable=SC2086 # deliberate: the spec line IS the child argv
  "$fake" -c 'sleep 120; :' $line &
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
  local home spec daemon json sessions owner rows
  home=$(make_home two-sessions)
  finish_backlog "$home"
  write_lavish_stub "$FAKEBIN"
  spec="$home/children"
  cat > "$spec" <<'EOF'
sess-a --session-id aaaa --agent claude --permission-mode bypassPermissions
sess-b --session-id bbbb --agent claude --permission-mode bypassPermissions
pool-a --bg-spare /tmp/cc-daemon/spare/1111.claim.sock
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
    | "\(.label)=\(.detail)"] | sort | join(" ")')
  case "$rows" in
    *'session=drives this home: ambiguous'*) ;;
    *) fail "each live session must say it cannot be told apart: $rows" ;;
  esac
  case "$rows" in
    *'spare=drives this home: no'*) ;;
    *) fail "an idle pool process drives no home whatever the ancestry says: $rows" ;;
  esac

  # The captain-facing surface must lead with the ambiguity, not bury it.
  local rendered
  rendered=$(COLUMNS=100 run_view "$home" --color never)
  assert_contains "$rendered" "2 background sessions share harness daemon $daemon" \
    "the view must say plainly that several sessions share one daemon"

  kill_spawned
  pass "inventory: two concurrent background sessions read as ambiguous, and the view says so"
}

test_single_session_is_attributed_to_this_home() {
  local home spec daemon json owner drives
  home=$(make_home one-session)
  finish_backlog "$home"
  write_lavish_stub "$FAKEBIN"
  spec="$home/children"
  cat > "$spec" <<'EOF'
sess-a --session-id aaaa --agent claude --permission-mode bypassPermissions
pool-a --bg-spare /tmp/cc-daemon/spare/1111.claim.sock
pool-b --bg-spare /tmp/cc-daemon/spare/2222.claim.sock
EOF
  start_daemon_tree "$home" "$spec"
  daemon=$DAEMON_PID
  printf '%s\n' "$daemon" > "$home/state/.lock"

  json=$(run_inventory "$home" --json) || fail "inventory failed for a single session"
  owner=$(printf '%s' "$json" | jq -r '.harness_sessions.lock_owner')
  [ "$owner" = single ] || fail "one live session under the daemon must read as single, got '$owner'"
  drives=$(printf '%s' "$json" | jq -r '.rows[] | select(.kind == "harness-session" and .label == "session") | .detail')
  [ "$drives" = "drives this home: yes" ] \
    || fail "the only live session under the lock-owning daemon drives this home, got '$drives'"
  [ "$(printf '%s' "$json" | jq -r '.harness_sessions.spares')" = 2 ] \
    || fail "both idle pool processes must still be inventoried"

  kill_spawned
  pass "inventory: a single background session is attributed to this home"
}

test_conflicting_argv_is_reported_unknown() {
  local home spec daemon json
  home=$(make_home unknown-role)
  finish_backlog "$home"
  write_lavish_stub "$FAKEBIN"
  spec="$home/children"
  # Both a session token and a pool token: a vendor rename must surface, never
  # silently reclassify a live session as an idle spare.
  cat > "$spec" <<'EOF'
odd --session-id cccc --bg-spare /tmp/cc-daemon/spare/3333.claim.sock
EOF
  start_daemon_tree "$home" "$spec"
  daemon=$DAEMON_PID
  printf '%s\n' "$daemon" > "$home/state/.lock"

  json=$(run_inventory "$home" --json) || fail "inventory failed for a conflicting argv"
  [ "$(printf '%s' "$json" | jq -r '.harness_sessions.unknown')" = 1 ] \
    || fail "conflicting session and pool tokens must report role unknown"
  [ "$(printf '%s' "$json" | jq -r '.harness_sessions.spares')" = 0 ] \
    || fail "a conflicting argv must never be counted as a known idle spare"
  [ "$(printf '%s' "$json" | jq -r '.harness_sessions.lock_owner')" = single ] \
    || fail "an unclassified row still counts as a candidate driver"

  kill_spawned
  pass "inventory: a conflicting harness argv is reported unknown rather than guessed"
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

test_inventory_closes_nothing_it_reports() {
  local home spec daemon children pid
  home=$(make_home read-only)
  finish_backlog "$home"
  write_lavish_stub "$FAKEBIN"
  spec="$home/children"
  cat > "$spec" <<'EOF'
sess-a --session-id aaaa --agent claude
pool-a --bg-spare /tmp/cc-daemon/spare/1111.claim.sock
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
test_conflicting_argv_is_reported_unknown
test_stale_lock_pid_is_not_attributed
test_nothing_old_prints_nothing_at_session_start
test_stale_rows_carry_their_exact_close_command
test_row_without_a_safe_close_stays_out_of_the_unasked_line
test_captain_held_work_stays_out_of_the_unasked_line
test_review_pages_are_listed_and_aged
test_review_page_with_queued_notes_needs_confirmation
test_unreadable_source_is_disclosed_not_counted_as_zero
test_view_is_readable_narrow_and_without_colour
test_view_refuses_a_cadence_below_the_floor
test_inventory_makes_no_cross_home_network_read
test_inventory_closes_nothing_it_reports
