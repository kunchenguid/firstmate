#!/usr/bin/env bash
# Real-composition behavior tests for bin/fm-graph-server.mjs.
#
# These start the ACTUAL server over a seeded FM_STATE_OVERRIDE home, talk to it
# over real HTTP, and assert on what a browser would receive. Nothing here mocks
# the server, the projection, or the owners it shells out to: a test that
# asserted on a fake would prove nothing about the surface the captain opens.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SERVER="$ROOT/bin/fm-graph-server.mjs"
TMP_ROOT=$(fm_test_tmproot fm-graph-server)

command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }
command -v curl >/dev/null 2>&1 || { echo "skip: curl not found"; exit 0; }

SERVER_PID=
SERVER_PORT=
# Every server this suite starts is recorded here as well as in SERVER_PID.
# The variable alone is not a teardown guarantee: a case that ends in fail()
# never reaches its own stop_server, and the registry is what lets the exit
# path reap those anyway.
SERVER_PIDS="$TMP_ROOT/server-pids"
: > "$SERVER_PIDS"

# Baseline for the survivor oracle. Other worktrees and hand-started boards can
# be running this same file, so the oracle compares against this count rather
# than requiring zero, and counts processes because --port 0 leaves no fixed
# port to count by.
server_process_count() {
  pgrep -f "$SERVER" 2>/dev/null | wc -l | tr -d ' '
}
SERVER_BASELINE=$(server_process_count)

reap_pid() {  # <pid>
  local pid=$1 attempt=0
  kill -0 "$pid" 2>/dev/null || return 0
  kill "$pid" 2>/dev/null || true
  while [ "$attempt" -lt 50 ]; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
    attempt=$((attempt + 1))
  done
  # A server that ignored TERM is still a leak, so escalate rather than leaving
  # it behind and reporting success.
  kill -9 "$pid" 2>/dev/null || true
  attempt=0
  while [ "$attempt" -lt 30 ]; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
    attempt=$((attempt + 1))
  done
  return 1
}

stop_server() {
  [ -n "$SERVER_PID" ] || return 0
  reap_pid "$SERVER_PID" || printf 'fm-graph-server test: server %s survived teardown\n' "$SERVER_PID" >&2
  wait "$SERVER_PID" 2>/dev/null || true
  SERVER_PID=
}

reap_all_servers() {
  local pid
  [ -f "$SERVER_PIDS" ] || return 0
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    reap_pid "$pid" || true
  done < "$SERVER_PIDS"
  SERVER_PID=
}

cleanup() {
  # Unconditional: this runs on a passing suite, on a fail() exit, and on an
  # interrupt, which is the difference between a teardown guarantee and a
  # happy-path kill.
  reap_all_servers
  fm_test_cleanup
}
trap cleanup EXIT INT TERM

seed_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '%s\n' "$home"
}

seed_lane() {  # <home> <id> <kind> <gen> [<step> <ts>]
  local home=$1 id=$2 kind=$3 gen=$4 step=${5:-} ts=${6:-}
  printf 'kind=%s\nspawn_gen=%s\nworktree=%s/worktree\nharness=tmux\nmode=direct-PR\n' \
    "$kind" "$gen" "$home" > "$home/state/$id.meta"
  {
    printf 'schema=fm-pipeline.v3 task=%s kind=%s gen=%s\n' "$id" "$kind" "$gen"
    [ -n "$step" ] && printf 'rev=1 ts=%s step=%s evidence=meta:state/%s.meta gen=%s head=unknown attempt=-\n' \
      "$ts" "$step" "$id" "$gen"
  } > "$home/state/$id.pipeline"
}

# Sets SERVER_PID and SERVER_PORT. Deliberately NOT called through a command
# substitution: that runs the function in a subshell, so the pid assignment dies
# with it and teardown has nothing to kill - the same trap tests/lib.sh
# documents for fm_test_tmproot. The port comes back through SERVER_PORT.
start_server() {  # <home>
  local home=$1 attempt=0 body
  # Port 0 lets the kernel pick a free port, so two suites never collide.
  local out="$home/server.out" err="$home/server.err"
  : > "$out"; : > "$err"
  SERVER_PORT=
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    node "$SERVER" --port 0 --ready-line >"$out" 2>"$err" &
  SERVER_PID=$!
  printf '%s\n' "$SERVER_PID" >> "$SERVER_PIDS"
  while [ "$attempt" -lt 150 ]; do
    body=$(head -1 "$out" 2>/dev/null || true)
    case "$body" in
      ready\ http://127.0.0.1:*)
        SERVER_PORT=${body##*:}
        return 0
        ;;
    esac
    sleep 0.1
    attempt=$((attempt + 1))
  done
  cat "$err" >&2
  fail "server did not report a ready line"
}

get() {  # <port> <path>
  curl -sS --max-time 20 "http://127.0.0.1:$1$2"
}

wait_for() {  # <port> <path> <jq-filter>
  local port=$1 path=$2 filter=$3 attempt=0
  while [ "$attempt" -lt 200 ]; do
    if get "$port" "$path" | jq -e "$filter" >/dev/null 2>&1; then return 0; fi
    sleep 0.1
    attempt=$((attempt + 1))
  done
  return 1
}

test_server_binds_loopback_only_and_serves_its_own_page() {
  local home port page listeners
  home=$(seed_home loopback)
  seed_lane "$home" alpha ship gen-a dispatched 2026-09-07T10:00:00Z
  start_server "$home"
  port=$SERVER_PORT

  page=$(get "$port" /)
  assert_contains "$page" '<title>Firstmate flows</title>' "the server must serve its own page same-origin"
  assert_contains "$page" 'EventSource("/events")' "the page must open the live stream against its own origin"
  assert_not_contains "$page" 'https://cdn' "the page must load nothing from an external origin"
  assert_not_contains "$page" '<script src=' "the page must carry no external script"

  # Binding is the whole security scope for a local-only surface, so it is
  # asserted rather than assumed: a request to a non-loopback address must not
  # reach this server.
  if command -v lsof >/dev/null 2>&1; then
    listeners=$(lsof -nP -a -p "$SERVER_PID" -iTCP -sTCP:LISTEN 2>/dev/null || true)
    if [ -n "$listeners" ]; then
      assert_contains "$listeners" "127.0.0.1:$port" "the listener must be bound to 127.0.0.1"
      assert_not_contains "$listeners" "*:$port" "the listener must not be bound to every interface"
    fi
  fi
  stop_server
  pass "fm-graph-server: binds 127.0.0.1 and serves a same-origin page with no external assets"
}

test_board_projects_real_records_with_per_node_state() {
  local home port board
  home=$(seed_home project)
  seed_lane "$home" alpha ship gen-a dispatched 2026-09-07T10:00:00Z
  seed_lane "$home" beta scout gen-b
  printf 'working: first light\n' > "$home/state/alpha.status"
  start_server "$home"
  port=$SERVER_PORT
  wait_for "$port" /api/board '.ready == true' || fail "board never became ready"

  board=$(get "$port" /api/board)
  printf '%s' "$board" | jq -e '[.lanes[].id] | index("alpha") != null and index("beta") != null' >/dev/null \
    || fail "the board did not project both seeded lanes"
  printf '%s' "$board" | jq -e '[.lanes[] | select(.id == "alpha")][0]
    | .step == "dispatched"
    and ([.nodes[] | select(.name == "dispatched")][0].state == "current")
    and ([.nodes[] | select(.name == "merged")][0].state == "pending")' >/dev/null \
    || fail "per-node state was not derived from the record"

  # The captain's complaint was that everything looked the same. A step with no
  # writer anywhere must not render as a step that is merely waiting its turn.
  printf '%s' "$board" | jq -e '[.lanes[] | select(.id == "alpha")][0]
    | [.nodes[] | select(.name == "working")][0].state == "uninstrumented"' >/dev/null \
    || fail "an uninstrumented node was not distinguished from a pending one"
  printf '%s' "$board" | jq -e '[.lanes[] | select(.id == "alpha")][0].last_event.text == "working: first light"' >/dev/null \
    || fail "the lane did not carry what the agent last said"
  stop_server
  pass "fm-graph-server: projects real records with per-node state and an uninstrumented distinction"
}

test_sse_delivers_a_lane_delta_when_a_record_changes() {
  local home port stream_out delta attempt=0
  home=$(seed_home sse)
  seed_lane "$home" alpha ship gen-a dispatched 2026-09-07T10:00:00Z
  start_server "$home"
  port=$SERVER_PORT
  wait_for "$port" /api/board '.ready == true' || fail "board never became ready"

  stream_out="$home/stream.txt"
  curl -sS --no-buffer --max-time 25 "http://127.0.0.1:$port/events" > "$stream_out" &
  local stream_pid=$!
  # The first frame is the whole board, so wait for it before mutating: a delta
  # that raced the initial frame would prove nothing about the watch path.
  while [ "$attempt" -lt 150 ]; do
    grep -q '^event: board' "$stream_out" 2>/dev/null && break
    sleep 0.1
    attempt=$((attempt + 1))
  done
  grep -q '^event: board' "$stream_out" || { kill "$stream_pid" 2>/dev/null; fail "the stream never sent an initial board frame"; }

  printf 'working: the second thing happened\n' >> "$home/state/alpha.status"

  attempt=0
  while [ "$attempt" -lt 250 ]; do
    if grep -q '^event: lane' "$stream_out" 2>/dev/null; then break; fi
    sleep 0.1
    attempt=$((attempt + 1))
  done
  kill "$stream_pid" 2>/dev/null || true
  wait "$stream_pid" 2>/dev/null || true

  grep -q '^event: lane' "$stream_out" || fail "no lane delta arrived after the record changed"
  delta=$(grep -A1 '^event: lane' "$stream_out" | grep '^data: ' | head -1 | sed 's/^data: //')
  # The delta must be a reprojection of that one lane, not a reset: it carries
  # the new narrative AND still carries the step the record already proved.
  printf '%s' "$delta" | jq -e '.id == "alpha"
    and .last_event.text == "working: the second thing happened"
    and .step == "dispatched"' >/dev/null \
    || fail "the lane delta did not reproject the changed lane: $delta"
  # One lane changed, so exactly one lane frame is pushed. This is the whole
  # reason the server exists over a rebuilt board: it never fans out 93 lanes.
  [ "$(grep -c '^event: lane' "$stream_out")" -eq 1 ] \
    || fail "a single-lane change pushed $(grep -c '^event: lane' "$stream_out") lane frames"
  stop_server
  pass "fm-graph-server: a record change reaches a live SSE client as a single-lane delta"
}

test_node_log_resolves_a_source_or_names_why_it_cannot() {
  local home port proven absent
  home=$(seed_home logs)
  seed_lane "$home" alpha ship gen-a dispatched 2026-09-07T10:00:00Z
  start_server "$home"
  port=$SERVER_PORT
  wait_for "$port" /api/board '.ready == true' || fail "board never became ready"

  proven=$(get "$port" "/api/log?task=alpha&step=dispatched")
  printf '%s' "$proven" | jq -e '.source == "record" and (.entries | length) >= 1
    and (.entries[0].text | contains("step=dispatched"))' >/dev/null \
    || fail "a proven node did not resolve its own transition record: $proven"

  # A node with no durable source must say so in words. An empty panel that
  # looks like a failed fetch, or invented content, would both be worse.
  absent=$(get "$port" "/api/log?task=alpha&step=working")
  printf '%s' "$absent" | jq -e '.source == "none" and (.entries | length) == 0
    and (.note | test("uninstrumented"))' >/dev/null \
    || fail "an unwritten node did not report an honest empty state: $absent"
  stop_server
  pass "fm-graph-server: a node log resolves a real source or names why there is none"
}

test_hostile_request_fields_cannot_reach_the_filesystem_or_a_shell() {
  local home port out code
  home=$(seed_home hostile)
  seed_lane "$home" alpha ship gen-a dispatched 2026-09-07T10:00:00Z
  printf 'secret-canary-8842\n' > "$TMP_ROOT/outside.txt"
  start_server "$home"
  port=$SERVER_PORT
  wait_for "$port" /api/board '.ready == true' || fail "board never became ready"

  # Literal hostile strings: single quotes are what keeps them unexpanded here,
  # because the point is what the SERVER does with the bytes, not the shell.
  # shellcheck disable=SC2016
  for probe in '../../etc/passwd' '/etc/passwd' 'alpha;id' 'alpha$(id)' '..%2F..%2Fetc%2Fpasswd'; do
    out=$(get "$port" "/api/log?task=$(printf '%s' "$probe" | sed 's/ /%20/g')&step=dispatched")
    printf '%s' "$out" | jq -e '.error == "unknown task"' >/dev/null \
      || fail "a hostile task id was not refused: $probe -> $out"
  done

  out=$(get "$port" "/api/log?task=alpha&step=../../etc/passwd")
  printf '%s' "$out" | jq -e '.error == "unknown step"' >/dev/null \
    || fail "a hostile step was not refused: $out"

  # The action route is the one that INVOKES things, so its refusals matter most.
  code=$(curl -sS -o "$home/action.json" -w '%{http_code}' --max-time 20 \
    -X POST -H 'content-type: application/json' \
    -d '{"task":"alpha","action":"rm -rf /"}' "http://127.0.0.1:$port/api/action")
  [ "$code" = 400 ] || fail "an action outside the allowlist was not refused: $code"
  jq -e '.error == "unknown action"' "$home/action.json" >/dev/null \
    || fail "the refused action did not name the allowlist"

  code=$(curl -sS -o "$home/action2.json" -w '%{http_code}' --max-time 20 \
    -X POST -H 'content-type: application/json' \
    -d '{"task":"../outside","action":"exit"}' "http://127.0.0.1:$port/api/action")
  [ "$code" = 404 ] || fail "an action against an unknown task was not refused: $code"
  stop_server
  pass "fm-graph-server: hostile ids, steps and actions are refused before any path or command is built"
}

test_search_delegates_to_the_search_owner() {
  local home port out
  home=$(seed_home search)
  seed_lane "$home" alpha ship gen-a dispatched 2026-09-07T10:00:00Z
  printf 'working: graphserver-needle-4417 landed\n' > "$home/state/alpha.status"
  start_server "$home"
  port=$SERVER_PORT
  wait_for "$port" /api/board '.ready == true' || fail "board never became ready"

  out=$(get "$port" "/api/search?q=graphserver-needle-4417")
  printf '%s' "$out" | jq -e '[.hits[].path] | any(test("alpha\\.status"))' >/dev/null \
    || fail "search did not find the seeded needle through the search owner: $out"

  out=$(get "$port" "/api/search?q=a")
  printf '%s' "$out" | jq -e '.error != null' >/dev/null \
    || fail "a too-short query was not refused"

  # The query is a search argument, never a command fragment. If a shell ever
  # assembled this route, the second half of this query would run and its marker
  # would land in the results.
  out=$(get "$port" "/api/search?q=graphserver-needle-4417%3B%20echo%20GRAPHSRV-PWNED-4417")
  printf '%s' "$out" | jq -e '[.hits[].text] | any(contains("GRAPHSRV-PWNED-4417")) | not' >/dev/null \
    || fail "the search query was executed by a shell: $out"
  stop_server
  pass "fm-graph-server: search delegates to bin/fm-search.sh and refuses a degenerate query"
}

test_server_writes_nothing_into_state() {
  local home port before after
  home=$(seed_home readonly)
  seed_lane "$home" alpha ship gen-a dispatched 2026-09-07T10:00:00Z
  printf 'working: untouched\n' > "$home/state/alpha.status"
  before=$(cd "$home/state" && find . -type f | sort | while IFS= read -r f; do printf '%s %s\n' "$f" "$(wc -c < "$f")"; done)
  start_server "$home"
  port=$SERVER_PORT
  wait_for "$port" /api/board '.ready == true' || fail "board never became ready"
  get "$port" /api/board >/dev/null
  get "$port" "/api/log?task=alpha&step=dispatched" >/dev/null
  get "$port" "/api/status?task=alpha" >/dev/null
  get "$port" "/api/search?q=untouched" >/dev/null
  stop_server
  after=$(cd "$home/state" && find . -type f | sort | while IFS= read -r f; do printf '%s %s\n' "$f" "$(wc -c < "$f")"; done)
  [ "$before" = "$after" ] || fail "the server mutated state/: $(diff <(printf '%s' "$before") <(printf '%s' "$after") || true)"
  pass "fm-graph-server: reading the board writes nothing into state/"
}

test_allowlisted_actions_reach_the_real_owner_with_an_argument_vector() {
  local home port body
  home=$(seed_home actions)
  seed_lane "$home" alpha ship gen-a dispatched 2026-09-07T10:00:00Z
  start_server "$home"
  port=$SERVER_PORT
  wait_for "$port" /api/board '.ready == true' || fail "board never became ready"

  # The lane's endpoint does not exist, so the real owner refuses. That is the
  # point: the route reaches bin/fm-control.sh itself, with the exact verb, and
  # the owner's refusal is surfaced instead of being reported as done.
  curl -sS -o "$home/interrupt.json" --max-time 40 \
    -X POST -H 'content-type: application/json' \
    -d '{"task":"alpha","action":"interrupt"}' "http://127.0.0.1:$port/api/action" >/dev/null
  jq -e '.invoked | test("bin/fm-control\\.sh \"alpha\" \"interrupt\"$")' "$home/interrupt.json" >/dev/null \
    || fail "interrupt did not invoke the control owner with an exact argument vector: $(cat "$home/interrupt.json")"
  jq -e '.ok == false and (.output | length) > 0' "$home/interrupt.json" >/dev/null \
    || fail "the control owner's refusal was not surfaced: $(cat "$home/interrupt.json")"

  # Steer text is an argument, never a fragment of a command line. The marker
  # below only ever appears in the captured output if a shell ran the second
  # half of it, so this fails loudly the day someone builds a command string.
  curl -sS -o "$home/steer.json" --max-time 40 \
    -X POST -H 'content-type: application/json' \
    -d '{"task":"alpha","action":"steer","text":"hold on; echo GRAPHSRV-PWNED-9931"}' \
    "http://127.0.0.1:$port/api/action" >/dev/null
  body=$(cat "$home/steer.json")
  printf '%s' "$body" | jq -e '.invoked | contains("hold on; echo GRAPHSRV-PWNED-9931")' >/dev/null \
    || fail "the steer text did not reach the send owner verbatim: $body"
  if printf '%s' "$body" | jq -re '.output' | grep -q 'GRAPHSRV-PWNED-9931'; then
    fail "the steer text was executed by a shell: $body"
  fi
  stop_server
  pass "fm-graph-server: an allowlisted action reaches its real owner as an argument vector, unexpanded"
}

# A lane whose worktree and endpoint exist on paper is what lets the real
# bin/fm-crew-state.sh reach its busy classifier, which is the owner of what
# "this agent is working" means. These fixtures reproduce two live lanes.
seed_activity() {  # <home> <id> <harness> [<busy-line>]
  local home=$1 id=$2 harness=$3 busy=${4:-}
  mkdir -p "$home/wt"
  printf 'kind=ship\nspawn_gen=gen-%s\nworktree=%s/wt\nharness=%s\nbackend=tmux\nwindow=nosuch:w1:p1\nmode=direct-PR\n' \
    "$id" "$home" "$harness" > "$home/state/$id.meta"
  if [ -n "$busy" ]; then
    printf 'g-%s\n' "$id" > "$home/state/$id.busy-gen"
    printf '%s\n' "$busy" > "$home/state/$id.busy-state"
  fi
  printf 'schema=fm-pipeline.v3 task=%s kind=ship gen=gen-%s\n' "$id" "$id" > "$home/state/$id.pipeline"
  printf 'rev=1 ts=2026-09-07T10:00:00Z step=dispatched evidence=meta:state/%s.meta gen=gen-%s head=unknown attempt=-\n' \
    "$id" "$id" >> "$home/state/$id.pipeline"
}

test_activity_never_reads_a_launch_arm_as_work_or_an_absent_record_as_quiet() {
  local home port board
  home=$(seed_home activity)
  # Armed and nothing since: the only busy event is the launch brief the
  # spawner seeds. The owner classifies that busy, but "we handed it a brief"
  # is not "it is working", and showing it as running is the false instrument
  # this board exists to remove.
  seed_activity "$home" armedonly claude \
    "v1 gen=g-armedonly seq=1 state=busy source=fm-spawn event=launch-brief ts=$(date +%s)"
  # A live adapter reporting its own turn.
  seed_activity "$home" reallyworking claude \
    "v1 gen=g-reallyworking seq=4 state=busy source=claude-hook event=user-prompt-submit ts=$(date +%s)"
  # No busy record at all. Absence is not idleness: some harnesses write none,
  # so this must read unknown, never quiet.
  seed_activity "$home" norecord codex

  start_server "$home"
  port=$SERVER_PORT
  wait_for "$port" /api/board '.ready == true' || fail "board never became ready"
  wait_for "$port" /api/board '.snapshot_at != null or .snapshot_error != null' \
    || fail "agent state never resolved"
  board=$(get "$port" /api/board)

  printf '%s' "$board" | jq -e '[.lanes[] | select(.id == "armedonly")][0].attention == "armed"' >/dev/null \
    || fail "a lane whose only activity is the launch arm was not shown as armed: $(printf '%s' "$board" | jq -c '[.lanes[]|select(.id=="armedonly")][0].activity')"
  printf '%s' "$board" | jq -e '[.lanes[] | select(.id == "armedonly")][0].attention != "running"' >/dev/null \
    || fail "a lane that never started was shown as running"
  printf '%s' "$board" | jq -e '[.lanes[] | select(.id == "reallyworking")][0].attention == "running"' >/dev/null \
    || fail "a lane whose own adapter reported a turn was not shown as running: $(printf '%s' "$board" | jq -c '[.lanes[]|select(.id=="reallyworking")][0].activity')"
  printf '%s' "$board" | jq -e '[.lanes[] | select(.id == "norecord")][0].attention == "unknown"' >/dev/null \
    || fail "a lane with no activity record was not shown as unknown: $(printf '%s' "$board" | jq -c '[.lanes[]|select(.id=="norecord")][0].activity')"

  # The activity cell must name the owner that produced it, so a reader can
  # tell a verdict apart from a guess.
  printf '%s' "$board" | jq -e '[.lanes[] | select(.id == "armedonly")][0].activity.provenance == "fm-spawn"' >/dev/null \
    || fail "the activity cell did not carry the classifier's own provenance"
  stop_server
  pass "fm-graph-server: a launch arm never reads as work and an absent record never reads as quiet"
}

test_a_question_is_delivered_to_the_existing_note_path_and_never_answered_here() {
  local home port code after
  home=$(seed_home ask)
  seed_lane "$home" alpha ship gen-a dispatched 2026-09-07T10:00:00Z
  start_server "$home"
  port=$SERVER_PORT
  wait_for "$port" /api/board '.ready == true' || fail "board never became ready"

  code=$(curl -sS -o "$home/ask.json" -w '%{http_code}' --max-time 40 \
    -X POST -H 'content-type: application/json' \
    -d '{"task":"alpha","question":"what is this lane waiting on"}' "http://127.0.0.1:$port/api/ask")
  [ "$code" = 200 ] || fail "a question was not accepted: $code $(cat "$home/ask.json")"
  jq -e '.delivered == true' "$home/ask.json" >/dev/null \
    || fail "the question was not reported as delivered: $(cat "$home/ask.json")"

  # Delivered, not answered. The board relays through the existing note path and
  # calls no model of its own, so the durable record is the only outcome.
  after=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$ROOT/bin/fm-inbox.sh" list 2>/dev/null)
  printf '%s' "$after" | grep -q 'what is this lane waiting on' \
    || fail "the question did not reach the captain's note record: $after"
  printf '%s' "$after" | grep -q 'alpha' \
    || fail "the delivered note did not name the lane the question was aimed at"

  code=$(curl -sS -o "$home/ask2.json" -w '%{http_code}' --max-time 20 \
    -X POST -H 'content-type: application/json' -d '{"question":"   "}' \
    "http://127.0.0.1:$port/api/ask")
  [ "$code" = 400 ] || fail "an empty question was not refused: $code"
  stop_server
  pass "fm-graph-server: a question is delivered through the existing note path, never answered here"
}

# A page on any other site can send a "simple" cross-origin POST - text/plain
# carrying JSON needs no preflight - so without an origin guard a merely visited
# web page could drive this server's mutating routes. Host is asserted on a read
# too, because a DNS-rebinding name resolving to 127.0.0.1 would otherwise let a
# foreign page read this home's records as same-origin.
test_only_same_origin_requests_may_act() {
  local home port code before after
  home=$(seed_home origin-guard)
  seed_lane "$home" alpha ship gen-a dispatched 2026-09-07T10:00:00Z
  start_server "$home"
  port=$SERVER_PORT
  wait_for "$port" /api/board '.ready == true' || fail "board never became ready"

  before=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$ROOT/bin/fm-inbox.sh" list 2>/dev/null || true)

  # The exact shape of the attack: a simple request, so the browser sends it
  # without asking this server first.
  code=$(curl -sS -o "$home/csrf.json" -w '%{http_code}' --max-time 20 \
    -X POST -H 'content-type: text/plain' -H 'Origin: http://evil.example' \
    -d '{"task":"alpha","question":"cross-site write"}' "http://127.0.0.1:$port/api/ask")
  [ "$code" = 403 ] || fail "a cross-origin text/plain question was not refused: $code $(cat "$home/csrf.json" 2>/dev/null)"

  code=$(curl -sS -o "$home/csrf2.json" -w '%{http_code}' --max-time 20 \
    -X POST -H 'content-type: text/plain' \
    -d '{"task":"alpha","action":"exit"}' "http://127.0.0.1:$port/api/action")
  [ "$code" = 403 ] || fail "an action sent as text/plain was not refused: $code"

  code=$(curl -sS -o "$home/csrf3.json" -w '%{http_code}' --max-time 20 \
    -X POST -H 'content-type: application/json' -H 'Origin: http://evil.example' \
    -d '{"task":"alpha","action":"exit"}' "http://127.0.0.1:$port/api/action")
  [ "$code" = 403 ] || fail "a foreign-origin action was not refused: $code"

  # A rebound name that resolves here must not read this home's records either.
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 \
    -H 'Host: rebound.example' "http://127.0.0.1:$port/api/board")
  [ "$code" = 403 ] || fail "a foreign Host was not refused on a read: $code"

  after=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$ROOT/bin/fm-inbox.sh" list 2>/dev/null || true)
  [ "$before" = "$after" ] || fail "a refused cross-origin request still reached the note record"
  printf '%s' "$after" | grep -q 'cross-site write' \
    && fail "the cross-site question reached the captain's note record"

  # localhost is loopback by RFC 6761, so it must not be collateral damage.
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 \
    -H "Host: localhost:$port" "http://127.0.0.1:$port/api/board")
  [ "$code" = 200 ] || fail "localhost was refused as a loopback name: $code"

  # The board's own requests must still work: same-origin, declared JSON.
  code=$(curl -sS -o "$home/ok.json" -w '%{http_code}' --max-time 40 \
    -X POST -H 'content-type: application/json' -H "Origin: http://127.0.0.1:$port" \
    -d '{"task":"alpha","question":"same-origin question"}' "http://127.0.0.1:$port/api/ask")
  [ "$code" = 200 ] || fail "the board's own same-origin question was refused: $code $(cat "$home/ok.json")"
  jq -e '.delivered == true' "$home/ok.json" >/dev/null \
    || fail "the same-origin question was not delivered: $(cat "$home/ok.json")"

  stop_server
  pass "fm-graph-server: only same-origin requests declaring JSON may act, and a foreign Host cannot read"
}

test_the_suite_leaves_no_server_process_behind() {
  local pid alive=0 after attempt=0
  # This case runs last on purpose: by here every earlier case has started a
  # server and torn it down, so the registry is the complete set this suite
  # created and the count is the whole machine's view of them.
  [ -s "$SERVER_PIDS" ] || fail "the suite recorded no servers, so this oracle would pass vacuously"

  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    if kill -0 "$pid" 2>/dev/null; then
      alive=$((alive + 1))
      printf 'survivor: %s\n' "$(ps -o pid,etime,command -p "$pid" 2>/dev/null | tail -1)" >&2
    fi
  done < "$SERVER_PIDS"
  [ "$alive" -eq 0 ] || fail "$alive server process(es) this suite started are still running"

  # The registry can only see what this shell recorded, so also compare the
  # machine's own count against the baseline taken before the first case. A
  # teardown that misses a server shows up here even if the registry is clean.
  while [ "$attempt" -lt 30 ]; do
    after=$(server_process_count)
    [ "$after" -le "$SERVER_BASELINE" ] && break
    sleep 0.1
    attempt=$((attempt + 1))
  done
  after=$(server_process_count)
  [ "$after" -le "$SERVER_BASELINE" ] \
    || fail "server processes grew from $SERVER_BASELINE to $after across the suite"
  pass "fm-graph-server: the suite leaves no server process behind (started $(wc -l < "$SERVER_PIDS" | tr -d ' '), baseline $SERVER_BASELINE, after $after)"
}

test_agent_state_is_read_on_demand_and_never_on_a_timer() {
  local home port first second
  home=$(seed_home ondemand)
  seed_lane "$home" alpha ship gen-a dispatched 2026-09-07T10:00:00Z
  start_server "$home"
  port=$SERVER_PORT

  # Nobody has asked for the board yet. Nothing may read fleet state on its own:
  # a timer that runs whether or not a reader exists is a scheduler, and this
  # server is a projection, not a background job.
  wait_for "$port" /health '.ok == true' || fail "server never answered /health"
  sleep 3
  get "$port" /health | jq -e '.ready == true' >/dev/null || fail "the board never finished projecting"
  get "$port" /health | jq -e '.agent_state_read == false' >/dev/null \
    || fail "fleet state was read with no reader asking for it"

  # A reader asking is the trigger.
  get "$port" /api/board >/dev/null
  wait_for "$port" /api/board '.snapshot_at != null or .snapshot_error != null' \
    || fail "asking for the board did not trigger a fleet-state read"
  first=$(get "$port" /api/board | jq -r '.snapshot_at')

  # Asking again with nothing changed on disk must not re-run it. The read costs
  # tens of seconds, so "a reader asked" alone is not the condition - the records
  # have to have moved too.
  get "$port" /api/board >/dev/null
  get "$port" /api/board >/dev/null
  sleep 2
  second=$(get "$port" /api/board | jq -r '.snapshot_at')
  [ "$first" = "$second" ] \
    || fail "an unchanged home re-read fleet state on a second ask: $first then $second"
  stop_server
  pass "fm-graph-server: fleet state is read when a reader asks and the records moved, never on a timer"
}

# Bounded wait for the fleet-read counter to reach a value; returns 1 if it
# never does, so a caller can assert either direction.
wait_reads() {  # <port> <count>
  local port=$1 want=$2 attempt=0
  while [ "$attempt" -lt 300 ]; do
    [ "$(get "$port" /health | jq -r '.agent_state_reads')" = "$want" ] && return 0
    sleep 0.1
    attempt=$((attempt + 1))
  done
  return 1
}

test_only_records_that_feed_fleet_state_force_a_fleet_reread() {
  local home port
  home=$(seed_home invalidation)
  seed_activity "$home" alpha claude \
    "v1 gen=g-alpha seq=3 state=busy source=claude-hook event=user-prompt-submit ts=$(date +%s)"
  start_server "$home"
  port=$SERVER_PORT
  wait_for "$port" /api/board '.ready == true' || fail "board never became ready"

  get "$port" /api/board >/dev/null
  wait_reads "$port" 1 || fail "the first reader did not trigger exactly one fleet read"

  # Writes that fleet state is not a function of must not cost a re-read. The
  # read takes tens of seconds on a real home, so "anything under state/ moved"
  # is far too coarse a trigger for it.
  printf 'unrelated\n' >> "$home/state/.wake-queue"
  printf 'unrelated\n' >> "$home/state/pipeline-events.log"
  : > "$home/state/alpha.turn-ended"
  : > "$home/state/alpha.check-trust"
  printf 'x\n' > "$home/state/.fm-board-scratch.tmp"
  sleep 1
  get "$port" /api/board >/dev/null
  get "$port" /api/board >/dev/null
  sleep 2
  [ "$(get "$port" /health | jq -r '.agent_state_reads')" = 1 ] \
    || fail "an unrelated state write forced a fleet re-read (reads now $(get "$port" /health | jq -r '.agent_state_reads'))"

  # A pipeline record moves the graph, and the single-lane reprojection already
  # covers that, so it must not drag the whole fleet read along with it.
  printf 'rev=2 ts=2026-09-07T11:00:00Z step=pr-registered evidence=meta:state/alpha.meta gen=gen-alpha head=unknown attempt=-\n' \
    >> "$home/state/alpha.pipeline"
  sleep 1
  get "$port" /api/board >/dev/null
  sleep 2
  [ "$(get "$port" /health | jq -r '.agent_state_reads')" = 1 ] \
    || fail "a pipeline record write forced a fleet re-read"

  # A record fleet state IS a function of must trigger exactly one, not none and
  # not one per ask.
  printf 'model=opus\n' >> "$home/state/alpha.meta"
  sleep 1
  get "$port" /api/board >/dev/null
  wait_reads "$port" 2 || fail "a fleet-relevant record change did not trigger a re-read"
  get "$port" /api/board >/dev/null
  get "$port" /api/board >/dev/null
  sleep 2
  [ "$(get "$port" /health | jq -r '.agent_state_reads')" = 2 ] \
    || fail "repeated asks after one relevant change triggered more than one re-read"
  stop_server
  pass "fm-graph-server: only records fleet state is a function of force a fleet re-read"
}

test_server_binds_loopback_only_and_serves_its_own_page
test_board_projects_real_records_with_per_node_state
test_sse_delivers_a_lane_delta_when_a_record_changes
test_node_log_resolves_a_source_or_names_why_it_cannot
test_hostile_request_fields_cannot_reach_the_filesystem_or_a_shell
test_search_delegates_to_the_search_owner
test_allowlisted_actions_reach_the_real_owner_with_an_argument_vector
test_activity_never_reads_a_launch_arm_as_work_or_an_absent_record_as_quiet
test_a_question_is_delivered_to_the_existing_note_path_and_never_answered_here
test_server_writes_nothing_into_state
test_only_same_origin_requests_may_act
test_agent_state_is_read_on_demand_and_never_on_a_timer
test_only_records_that_feed_fleet_state_force_a_fleet_reread
test_the_suite_leaves_no_server_process_behind
