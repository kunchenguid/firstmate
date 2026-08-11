#!/usr/bin/env bash
# tests/fm-refill.test.sh - the refill evidence a heartbeat wake carries
# (bin/fm-refill.sh) and the watcher heartbeat path that appends it
# (bin/fm-watch.sh).
#
# The behavioral contract under test: an emitted heartbeat tells the supervisor
# how much capacity is live and which queued work was dispatchable, so refilling
# a drained fleet is part of handling the wake; and the probe is fail-open, so a
# home that cannot answer still gets its heartbeat unchanged.
#
# Everything here goes through the two executables. The probe cases drive
# bin/fm-refill.sh with a real backlog and a real tasks-axi (the parse is only
# worth anything against the tool that produces the format), the fail-open cases
# substitute a fake tasks-axi on PATH, and the wake cases drive a real
# fm-watch.sh subprocess and read the payload back through fm-wake-drain.sh.
#
# General watcher triage lives in fm-watch-triage.test.sh; the durable-queue
# safety matrix in fm-wake-queue.test.sh.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

REFILL="$ROOT/bin/fm-refill.sh"
WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-refill-tests)

HAVE_TASKS_AXI=0
command -v tasks-axi >/dev/null 2>&1 && HAVE_TASKS_AXI=1

# A firstmate home skeleton plus a fake tmux whose endpoints are alive exactly
# for the windows named in FM_FAKE_ALIVE_WINDOWS, so a case can make a recorded
# endpoint live or dead without a terminal.
make_home() {  # <name>
  local name=$1 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/state" "$dir/config" "$dir/data" "$dir/fakebin"
  cat > "$dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
[ "${1:-}" = display-message ] || exit 1
target=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -t) target="${2:-}"; shift 2; continue ;;
    *) shift ;;
  esac
done
case " ${FM_FAKE_ALIVE_WINDOWS:-} " in
  *" $target "*) printf '%%1\n'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$dir/fakebin/tmux"
  make_fake_crew_state "$dir/fakebin" >/dev/null
  printf '%s\n' "$dir"
}

# The .seen-* signature a primed status marker must hold so the per-poll signal
# scan stays quiet (mirrors fm-watch.sh's stat_sig).
seen_sig() {
  if [ "$(uname)" = Darwin ]; then stat -f '%z:%Fm' "$1" 2>/dev/null; else stat -c '%s:%Y' "$1" 2>/dev/null; fi
}

# Record one task the way fm-spawn does, minus every field this probe ignores.
write_meta() {  # <home> <id> <kind> <window>
  local home=$1 id=$2 kind=$3 window=$4
  {
    [ -z "$window" ] || printf 'window=%s\n' "$window"
    printf 'kind=%s\n' "$kind"
  } > "$home/state/$id.meta"
}

# A fake tasks-axi that passes the compatibility probe and behaves as <mode>
# tells it to for `ready`.
fake_tasks_axi() {  # <home> <version> <ready-mode>
  local home=$1 version=$2 mode=$3
  cat > "$home/fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
set -u
case "\${1:-}" in
  --version|-v|-V) printf 'tasks-axi $version\n'; exit 0 ;;
  update) printf 'usage: tasks-axi update <id> [flags]\n  --archive-body\n'; exit 0 ;;
  mv) printf 'usage: tasks-axi mv <id> [<id>...] --to <path-or-dir>\n'; exit 0 ;;
  ready)
    case "$mode" in
      ok)   printf 'count: 1\nready[1]{id,state,kind,repo,title}:\n  fake-one,queued,task,"-",fake\n'; exit 0 ;;
      fail) printf 'error: backlog unreadable\n' >&2; exit 1 ;;
      junk) printf 'ready[nope]{}: <garbage\n  ,,,,\n'; exit 0 ;;
      missing) printf 'count: 1\n  fake-one,queued,task,"-",fake\n'; exit 0 ;;
      duplicate) printf 'count: 1\nready[1]{id,state,kind,repo,title}:\n  fake-one,queued,task,"-",fake\nready[1]{id,state,kind,repo,title}:\n  fake-two,queued,task,"-",fake\n'; exit 0 ;;
      truncated) printf 'count: 2\nready[2]{id,state,kind,repo,title}:\n  fake-one,queued,task,"-",fake\n'; exit 0 ;;
      hang) sleep 30; exit 0 ;;
      ignore-term) trap '' TERM; while :; do sleep 1; done ;;
    esac
    ;;
esac
exit 1
SH
  chmod +x "$home/fakebin/tasks-axi"
}

probe() {  # <home> [VAR=VALUE...]
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" env "$@" "$REFILL" "$home/state" "$home/config" "$home/data/backlog.md"
}

assert_refill_line() {  # <line> <display-prefix>
  local line=$1 prefix=$2 fingerprint
  case "$line" in "$prefix fingerprint="*) ;; *) fail "refill line had the wrong display fields: got '$line'" ;; esac
  fingerprint=${line##* fingerprint=}
  [ "${#fingerprint}" -eq 64 ] || fail "refill fingerprint was not SHA-256: got '$line'"
  case "$fingerprint" in *[!0-9a-f]*) fail "refill fingerprint was not lowercase hex: got '$line'" ;; esac
}

require_tasks_axi() {  # <case-name>
  [ "$HAVE_TASKS_AXI" -eq 1 ] && return 0
  printf 'ok - skip: tasks-axi not found (required by %s)\n' "$1"
  return 1
}

# --- probe: shape and counts ------------------------------------------------

test_reports_dispatchable_work_and_live_capacity() {
  local home out
  require_tasks_axi "the refill shape case" || return 0
  home=$(make_home shape)
  tasks-axi add a "task a" --file "$home/data/backlog.md" >/dev/null
  tasks-axi add b "task b" --file "$home/data/backlog.md" >/dev/null
  tasks-axi add c "task c" --file "$home/data/backlog.md" >/dev/null
  tasks-axi add d "task d" --file "$home/data/backlog.md" >/dev/null
  tasks-axi block b --by a --file "$home/data/backlog.md" >/dev/null
  tasks-axi hold c --reason "captain decision pending" --kind captain --file "$home/data/backlog.md" >/dev/null
  # Two live seats (a ship and a scout), and three records that are not free
  # capacity: a dead endpoint, an idle-by-design secondmate, and a task with no
  # recorded endpoint at all.
  write_meta "$home" ship-live ship "sess:1"
  write_meta "$home" scout-live scout "sess:2"
  write_meta "$home" ship-dead ship "sess:3"
  write_meta "$home" mate-live secondmate "sess:4"
  write_meta "$home" no-window ship ""
  out=$(probe "$home" FM_FAKE_ALIVE_WINDOWS="sess:1 sess:2 sess:4")
  assert_refill_line "$out" "refill: ready=2 live=2 ids=a,d"
  pass "the refill line reports dispatchable ready work, its ids, and live ship/scout capacity"
}

test_reports_an_empty_queue_rather_than_going_silent() {
  local home out
  require_tasks_axi "the empty-queue case" || return 0
  home=$(make_home empty-queue)
  tasks-axi add solo "captain-gated" --file "$home/data/backlog.md" >/dev/null
  tasks-axi hold solo --reason "captain decision pending" --kind captain --file "$home/data/backlog.md" >/dev/null
  out=$(probe "$home")
  # A silent probe means "cannot answer"; nothing-to-dispatch must still answer,
  # or the supervisor cannot tell the two apart.
  assert_refill_line "$out" "refill: ready=0 live=0 ids="
  pass "captain-gated work is not dispatchable and an empty ready queue is still reported"
}

test_ids_are_capped_while_the_count_stays_whole() {
  local home out ids i
  require_tasks_axi "the id-cap case" || return 0
  home=$(make_home id-cap)
  i=1
  while [ "$i" -le 12 ]; do
    tasks-axi add "t$i" "task $i" --file "$home/data/backlog.md" >/dev/null
    i=$((i + 1))
  done
  out=$(probe "$home" FM_REFILL_IDS_MAX=3)
  case "$out" in
    "refill: ready=12 live=0 ids="*) ;;
    *) fail "capped refill line lost the whole ready count: got '$out'" ;;
  esac
  ids=${out#*ids=}
  ids=${ids%% fingerprint=*}
  [ "$(printf '%s' "$ids" | tr ',' '\n' | grep -c .)" -eq 3 ] \
    || fail "refill line did not cap the listed ids: got '$out'"
  pass "the id list is capped while the ready count still reports the whole queue"
}

# --- probe: fail open -------------------------------------------------------

assert_silent() {  # <label> <output>
  [ -z "$2" ] || fail "$1 emitted refill data instead of failing open: got '$2'"
}

test_manual_backlog_backend_fails_open() {
  local home out
  home=$(make_home manual-backend)
  printf 'manual\n' > "$home/config/backlog-backend"
  fake_tasks_axi "$home" 0.2.5 ok
  printf '# Backlog\n' > "$home/data/backlog.md"
  out=$(probe "$home")
  assert_silent "a manual backlog backend" "$out"
  pass "a manual backlog backend answers nothing rather than guessing at the queue"
}

test_incompatible_tasks_axi_fails_open() {
  local home out
  home=$(make_home incompatible)
  fake_tasks_axi "$home" 0.1.0 ok
  printf '# Backlog\n' > "$home/data/backlog.md"
  out=$(probe "$home")
  assert_silent "an incompatible tasks-axi" "$out"
  pass "an incompatible backlog tool answers nothing rather than parsing an unknown format"
}

test_failing_and_malformed_backend_output_fails_open() {
  local home out mode
  home=$(make_home broken-backend)
  printf '# Backlog\n' > "$home/data/backlog.md"
  fake_tasks_axi "$home" 0.2.5 fail
  out=$(probe "$home")
  assert_silent "a failing ready query" "$out"
  for mode in junk missing duplicate truncated; do
    fake_tasks_axi "$home" 0.2.5 "$mode"
    out=$(probe "$home")
    assert_silent "malformed ready output ($mode)" "$out"
  done
  pass "a failing or malformed backlog query never produces a malformed refill line"
}

test_missing_backlog_fails_open() {
  local home out
  home=$(make_home no-backlog)
  fake_tasks_axi "$home" 0.2.5 ok
  out=$(probe "$home")
  assert_silent "a home with no backlog file" "$out"
  pass "a home with no backlog file answers nothing"
}

test_probe_is_bounded() {
  local home out started elapsed
  home=$(make_home hanging)
  printf '# Backlog\n' > "$home/data/backlog.md"
  fake_tasks_axi "$home" 0.2.5 ignore-term
  started=$(date +%s)
  out=$(probe "$home" FM_REFILL_TIMEOUT=2)
  elapsed=$(( $(date +%s) - started ))
  assert_silent "a hung backlog query" "$out"
  [ "$elapsed" -lt 20 ] \
    || fail "the probe was not bounded: a hung backlog query took ${elapsed}s"
  pass "a hung backlog query is bounded and returns nothing rather than stalling the caller"
}

# A stock macOS box has neither `timeout` nor `gtimeout`, so the portable
# fallback is the real bound there, not a theoretical branch. Drive it with a
# PATH that has the fake backlog tool and the base system directories only.
test_the_bound_holds_without_a_timeout_binary() {
  local home out started elapsed
  home=$(make_home no-timeout-binary)
  printf '# Backlog\n' > "$home/data/backlog.md"
  fake_tasks_axi "$home" 0.2.5 ok
  out=$(PATH="$home/fakebin:/usr/bin:/bin" env "$REFILL" \
    "$home/state" "$home/config" "$home/data/backlog.md")
  assert_refill_line "$out" "refill: ready=1 live=0 ids=fake-one"
  fake_tasks_axi "$home" 0.2.5 ignore-term
  started=$(date +%s)
  out=$(PATH="$home/fakebin:/usr/bin:/bin" env FM_REFILL_TIMEOUT=2 "$REFILL" \
    "$home/state" "$home/config" "$home/data/backlog.md")
  elapsed=$(( $(date +%s) - started ))
  assert_silent "a hung backlog query with no timeout binary" "$out"
  [ "$elapsed" -lt 20 ] \
    || fail "the portable bound did not hold: a hung backlog query took ${elapsed}s"
  pass "the probe answers and stays bounded with no timeout binary on PATH"
}

# --- the heartbeat wake carries it ------------------------------------------

# Arm the heartbeat backstop: a captain-relevant status whose .seen-* signature
# already matches (so the per-poll signal scan stays quiet) but which was never
# surfaced, exactly as fm-watch-triage.test.sh sets it up.
arm_heartbeat() {  # <home>
  local home=$1 sig
  printf 'done: PR https://example.test/pr/5\n' > "$home/state/miss.status"
  sig=$(seen_sig "$home/state/miss.status")
  printf '%s' "$sig" > "$home/state/.seen-miss_status"
}

# Run one watcher until it exits, with the recorded endpoint live and its crew
# provably working, so only the heartbeat backstop can end the cycle.
run_heartbeat() {  # <home> <out> <alive-windows>; 0 when the watcher exited
  local home=$1 out=$2 alive=$3 pid
  PATH="$home/fakebin:$PATH" FM_STATE_OVERRIDE="$home/state" \
    FM_CONFIG_OVERRIDE="$home/config" FM_DATA_OVERRIDE="$home/data" \
    FM_CREW_STATE_BIN="$home/fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)' \
    FM_FAKE_ALIVE_WINDOWS="$alive" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 \
    "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100
}

test_heartbeat_wake_carries_refill_evidence() {
  local home out drain_out payload
  require_tasks_axi "the heartbeat payload case" || return 0
  home=$(make_home wake-carries)
  tasks-axi add refill-me "queued work nobody dispatched" --file "$home/data/backlog.md" >/dev/null
  write_meta "$home" worker ship "sess:9"
  arm_heartbeat "$home"
  out="$home/watch.out"; drain_out="$home/drain.out"
  run_heartbeat "$home" "$out" "sess:9" \
    || fail "the watcher did not emit a heartbeat wake"
  # The printed reason line is matched as heartbeat($|:) by the arm, checkpoint,
  # and Stop auto-arm layers, so it must stay exactly "heartbeat".
  grep -Fx "heartbeat" "$out" >/dev/null \
    || fail "the printed heartbeat reason changed shape: $(cat "$out")"
  FM_STATE_OVERRIDE="$home/state" "$DRAIN" > "$drain_out" 2>/dev/null \
    || fail "draining the heartbeat wake failed"
  payload=$(grep "$(printf '\theartbeat\t')" "$drain_out" | head -1)
  [ -n "$payload" ] || fail "the heartbeat wake was not queued: $(cat "$drain_out")"
  case "$payload" in
    *"refill: ready=1 live=1 ids=refill-me fingerprint="*) ;;
    *) fail "the drained heartbeat did not carry intact refill evidence: got '$payload'" ;;
  esac
  pass "an emitted heartbeat carries its refill evidence intact through the durable queue"
}

test_refill_evidence_alone_fires_a_normal_heartbeat() {
  local home out drain_out payload
  home=$(make_home refill-only-wake)
  printf '# Backlog\n' > "$home/data/backlog.md"
  fake_tasks_axi "$home" 0.2.5 ok
  out="$home/watch.out"; drain_out="$home/drain.out"
  run_heartbeat "$home" "$out" "" \
    || fail "refillable work alone did not emit a normal-mode heartbeat"
  grep -Fx "heartbeat" "$out" >/dev/null \
    || fail "the refill-only heartbeat changed the printed reason: $(cat "$out")"
  FM_STATE_OVERRIDE="$home/state" "$DRAIN" > "$drain_out" 2>/dev/null \
    || fail "draining the refill-only heartbeat failed"
  payload=$(grep "$(printf '\theartbeat\t')" "$drain_out" | head -1)
  case "$payload" in
    *"refill: ready=1 live=0 ids=fake-one fingerprint="*) ;;
    *) fail "the refill-only heartbeat lost its evidence: got '$payload'" ;;
  esac
  pass "refillable work alone fires a normal-mode heartbeat on the existing cadence"
}

test_heartbeat_still_fires_when_the_probe_is_broken() {
  local home out drain_out payload
  home=$(make_home wake-probe-broken)
  printf '# Backlog\n' > "$home/data/backlog.md"
  fake_tasks_axi "$home" 0.2.5 fail
  write_meta "$home" worker ship "sess:9"
  arm_heartbeat "$home"
  out="$home/watch.out"; drain_out="$home/drain.out"
  run_heartbeat "$home" "$out" "sess:9" \
    || fail "a broken refill probe suppressed the heartbeat wake"
  grep -Fx "heartbeat" "$out" >/dev/null \
    || fail "a broken refill probe changed the printed heartbeat reason: $(cat "$out")"
  FM_STATE_OVERRIDE="$home/state" "$DRAIN" > "$drain_out" 2>/dev/null \
    || fail "draining the heartbeat wake failed"
  payload=$(grep "$(printf '\theartbeat\t')" "$drain_out" | head -1)
  [ -n "$payload" ] || fail "a broken refill probe lost the queued heartbeat: $(cat "$drain_out")"
  case "$payload" in
    *"$(printf '\theartbeat\theartbeat')") ;;
    *) fail "a broken refill probe left residue on the heartbeat payload: got '$payload'" ;;
  esac
  pass "a broken refill probe leaves the heartbeat wake exactly as it was"
}

test_reports_dispatchable_work_and_live_capacity
test_reports_an_empty_queue_rather_than_going_silent
test_ids_are_capped_while_the_count_stays_whole
test_manual_backlog_backend_fails_open
test_incompatible_tasks_axi_fails_open
test_failing_and_malformed_backend_output_fails_open
test_missing_backlog_fails_open
test_probe_is_bounded
test_the_bound_holds_without_a_timeout_binary
test_heartbeat_wake_carries_refill_evidence
test_refill_evidence_alone_fires_a_normal_heartbeat
test_heartbeat_still_fires_when_the_probe_is_broken
