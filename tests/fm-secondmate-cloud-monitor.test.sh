#!/usr/bin/env bash
# shellcheck source=tests/test-entry.sh
. "$(dirname "$0")/test-entry.sh"
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Hermetic coverage for the cloud secondmate compartment lane (R2/R3 design C
# item 4): bin/fm-secondmate-cloud-monitor.sh + .py, the fm-send compartment
# inbox routing, and the fm-spawn secondmate gate behind
# FM_SPAWN_SECONDMATE_CLOUD.
#
# The lifecycle CLI is a FIXTURE here (argv captured, canned JSON returned,
# blob transfers modeled against a local store directory): the real
# fm-worker-lifecycle.sh message lane lands in a sibling PR, and the real
# wrapper must never run Azure operations from a test. The chain the monitor
# verifies is REAL: every outbox fixture is produced by the real
# bin/fm-secondmate-session.py against the store, so the real producer feeds
# the real verifier and a contract drift between them goes red here.

MONITOR="$ROOT/bin/fm-secondmate-cloud-monitor.sh"
RUNNER="$ROOT/bin/fm-secondmate-session.py"
SEND="$ROOT/bin/fm-send.sh"
fm_git_identity fmtest fmtest@example.invalid
fm_test_tmproot_into TMP_ROOT fm-secondmate-cloud-monitor

ID=cmp-task
GEN=gen-one
ASSIGNMENT=asg-00000001
SUB=11111111-1111-4111-8111-111111111111

# --- fixture: the lifecycle CLI seam -----------------------------------------
#
# Records every invocation (one line, unit-separator-joined argv) and models
# exactly the three commands the monitor drives. execute returns a canned
# bounded result at once; message-put content-addresses the file into the
# store's session/in/; message-collect copies the store's session/out/ into
# the output dir and reports the paginated summary shape (cursor + more).
write_fixture_lifecycle() {
  cat > "$1" <<'SH'
#!/usr/bin/env bash
set -u
LOG=${FM_FIXTURE_LIFECYCLE_LOG:?}
STORE=${FM_FIXTURE_STORE:?}
{
  first=1
  for arg in "$@"; do
    if [ "$first" = 1 ]; then printf '%s' "$arg"; first=0; else printf '\x1f%s' "$arg"; fi
  done
  printf '\n'
} >> "$LOG"
command=$1
shift
case "$command" in
  execute)
    if [ -n "${FM_FIXTURE_EXECUTE_HOLD:-}" ]; then
      while [ ! -e "$FM_FIXTURE_EXECUTE_HOLD" ]; do sleep 0.05; done
    fi
    printf '{"schema":"fm.worker-execution-result/v1","exit_code":0,"timed_out":false}\n'
    ;;
  message-put)
    file=
    prev=
    for arg in "$@"; do
      [ "$prev" = --file ] && file=$arg
      prev=$arg
    done
    [ -n "$file" ] || { echo 'fixture: message-put without --file' >&2; exit 2; }
    digest=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$file")
    bytes=$(wc -c < "$file" | tr -d '[:space:]')
    target="$STORE/session/in/$digest.json"
    replayed=false
    if [ -e "$target" ]; then
      replayed=true
    else
      mkdir -p "$STORE/session/in"
      cp "$file" "$target"
    fi
    printf '{"blob_name":"session/in/%s.json","bytes":%s,"replayed":%s,"sha256":"%s"}\n' \
      "$digest" "$bytes" "$replayed" "$digest"
    ;;
  message-collect)
    outdir=
    prev=
    for arg in "$@"; do
      [ "$prev" = --output-dir ] && outdir=$arg
      prev=$arg
    done
    [ -n "$outdir" ] || { echo 'fixture: message-collect without --output-dir' >&2; exit 2; }
    cursor=
    if [ -d "$STORE/session/out" ]; then
      for blob in "$STORE/session/out"/*; do
        [ -e "$blob" ] || continue
        name=${blob##*/}
        [ -e "$outdir/$name" ] || cp "$blob" "$outdir/$name"
        cursor=$name
      done
    fi
    if [ -n "$cursor" ]; then
      printf '{"fetched":[],"skipped":[],"cursor":"%s","more":false}\n' "$cursor"
    else
      printf '{"fetched":[],"skipped":[],"cursor":null,"more":false}\n'
    fi
    ;;
  *)
    echo "fixture: unsupported lifecycle command $command" >&2
    exit 2
    ;;
esac
SH
  chmod +x "$1"
}

# --- fixture: one compartment world ------------------------------------------
#
# Globals set by make_world: WORLD HOME_DIR STATE_DIR STORE LC_LOG PANE_LOG
# LIFECYCLE_FIXTURE LANDING ORIGIN GUEST_REPO GUEST_STATE BASE FAKE_PI TURN_LOG
make_world() {
  local name=$1
  WORLD="$TMP_ROOT/$name"
  HOME_DIR="$WORLD/home"
  STATE_DIR="$HOME_DIR/state"
  STORE="$WORLD/store"
  LC_LOG="$WORLD/lifecycle.log"
  PANE_LOG="$WORLD/pane.log"
  LIFECYCLE_FIXTURE="$WORLD/fixture-lifecycle.sh"
  ORIGIN="$WORLD/origin"
  LANDING="$WORLD/landing"
  GUEST_REPO="$WORLD/guest-repo"
  GUEST_STATE="$WORLD/guest-state"
  FAKE_PI="$WORLD/fake-pi"
  TURN_LOG="$WORLD/turns.log"
  mkdir -p "$STATE_DIR/azure-workers" "$STORE/session/in" "$STORE/session/out" \
    "$STATE_DIR/$ID.cloud-payload" "$STATE_DIR/$ID.cloud-account"
  : > "$LC_LOG"
  : > "$TURN_LOG"
  printf 'staged\n' > "$STATE_DIR/$ID.cloud-payload/repo.bundle"
  printf 'staged\n' > "$STATE_DIR/$ID.cloud-account/auth.json"
  write_fixture_lifecycle "$LIFECYCLE_FIXTURE"
  fm_git_init_commit "$ORIGIN"
  git clone --quiet "$ORIGIN" "$LANDING"
  git clone --quiet "$ORIGIN" "$GUEST_REPO"
  BASE=$(git -C "$LANDING" rev-parse HEAD)
  printf '%s\n' "$LANDING" > "$STATE_DIR/$ID.cloud-worktree"
  # Persisted compartment environment: identities and durable leg config,
  # exactly what the gated spawn writes. Small legs keep the suite fast.
  {
    printf 'export FM_AZURE_SUBSCRIPTION_ID=%s\n' "$SUB"
    printf 'export FM_AZURE_STORAGE_NAME=stfixture\n'
    printf 'export FM_SECONDMATE_LEG_SECONDS=120\n'
    printf 'export FM_SECONDMATE_POLL_SECONDS=5\n'
    printf 'export FM_SECONDMATE_IDLE_SECONDS=600\n'
  } > "$STATE_DIR/$ID.cloud-env"
  write_controller assigned
  cat > "$FAKE_PI" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_FAKE_PI_LOG"
last=
for arg in "$@"; do last=$arg; done
case "${FM_FAKE_PI_MODE:-reply}" in
  reply) printf 'canned-reply:%s' "$last" ;;
  commit)
    echo turn >> turn.txt
    git add turn.txt
    git -c user.name='Fixture Pi' -c user.email='pi@example.invalid' commit -qm 'fixture turn'
    printf 'committed'
    ;;
esac
SH
  chmod +x "$FAKE_PI"
}

write_controller() {  # <status> [assignment]
  python3 - "$STATE_DIR/azure-workers/controller.json" "$ID" "$GEN" "${2:-$ASSIGNMENT}" "$BASE" "$1" <<'PY'
import json
import sys

path, task, generation, assignment, base, status = sys.argv[1:]
key = "{}@{}".format(task, generation)
state = {"queue": {key: {"task": task, "task_generation": generation, "status": status, "role": "secondmate"}}, "workers": {}}
if status == "assigned":
    state["queue"][key]["assignment_generation"] = assignment
    state["queue"][key]["slot"] = 3
    state["workers"]["3"] = {
        "slot": 3, "role": "secondmate", "assignment_generation": assignment,
        "bindings": {"repository_generation": base},
    }
with open(path, "w", encoding="utf-8") as handle:
    json.dump(state, handle)
PY
}

# run_guest_leg [VAR=value ...] - one REAL runner leg against the store, so
# the outbox chain the monitor verifies is produced by the real producer.
run_guest_leg() {
  perl -e 'alarm 120; exec @ARGV or die "exec failed: $!"' -- \
    env FM_WORKER_TASK="$ID" FM_WORKER_TASK_GENERATION="$GEN" \
    FM_WORKER_ASSIGNMENT_GENERATION="$ASSIGNMENT" \
    FM_WORKER_REPOSITORY_GENERATION="$BASE" \
    FM_SECONDMATE_BLOB_DIR="$STORE" FM_SECONDMATE_STATE_DIR="$GUEST_STATE" \
    FM_SECONDMATE_REPO_DIR="$GUEST_REPO" FM_SECONDMATE_PI_BIN="$FAKE_PI" \
    FM_FAKE_PI_LOG="$TURN_LOG" \
    "$@" python3 "$RUNNER"
}

put_guest_inbox() {  # '<json>' - store one canonical inbox message
  python3 - "$STORE" "$1" <<'PY'
import hashlib, json, pathlib, sys
store, raw = sys.argv[1:]
body = json.dumps(json.loads(raw), sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
digest = hashlib.sha256(body).hexdigest()
target = pathlib.Path(store) / "session" / "in" / (digest + ".json")
target.parent.mkdir(parents=True, exist_ok=True)
target.write_bytes(body)
print(digest)
PY
}

MONITOR_PID=
start_monitor() {
  perl -e 'alarm 90; exec @ARGV or die "exec failed: $!"' -- \
    env FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE_DIR" \
    FM_SECONDMATE_LIFECYCLE_BIN="$LIFECYCLE_FIXTURE" \
    FM_SECONDMATE_MONITOR_INTERVAL_SECONDS=1 \
    FM_FIXTURE_LIFECYCLE_LOG="$LC_LOG" FM_FIXTURE_STORE="$STORE" \
    "$MONITOR" "$ID" "$GEN" >> "$PANE_LOG" 2>&1 &
  MONITOR_PID=$!
}

stop_monitor() {
  [ -z "$MONITOR_PID" ] || kill "$MONITOR_PID" 2>/dev/null || true
  [ -z "$MONITOR_PID" ] || wait "$MONITOR_PID" 2>/dev/null
  MONITOR_PID=
}

wait_for() {  # <description> <check-command...>
  local description=$1 limit i=0
  shift
  limit=$(fm_test_liveness_iterations 1 0.2)
  while [ "$i" -lt "$limit" ]; do
    if "$@" >/dev/null 2>&1; then return 0; fi
    if [ -n "$MONITOR_PID" ] && ! kill -0 "$MONITOR_PID" 2>/dev/null; then
      # The monitor may have exited legitimately (terminal status); give the
      # check one final chance against the settled state.
      "$@" >/dev/null 2>&1 && return 0
      fail "monitor exited before: $description (pane: $(tail -5 "$PANE_LOG" 2>/dev/null))"
    fi
    sleep 0.2
    i=$((i + 1))
  done
  fail "timed out waiting for: $description (pane: $(tail -5 "$PANE_LOG" 2>/dev/null); lifecycle: $(tail -3 "$LC_LOG" 2>/dev/null))"
}

grep_lc() { grep -c "$1" "$LC_LOG" 2>/dev/null | tr -d '[:space:]'; }

both_envelopes_relayed() {
  [ "$(find "$STATE_DIR/$ID.cloud-inbox/.relayed" -type f 2>/dev/null | wc -l | tr -d '[:space:]')" -ge 2 ]
}

first_matching() {  # <dir> <glob> - first matching basename, empty if none
  local match
  for match in "$1"/$2; do
    if [ -e "$match" ]; then
      printf '%s\n' "${match##*/}"
      return 0
    fi
  done
  printf '\n'
}

lc_line() {  # <n> - nth lifecycle invocation, unit separators shown as \x1f
  sed -n "${1}p" "$LC_LOG"
}

leg_entry_argv() {  # <n> - the exact leg entrypoint string the monitor builds
  printf 'FM_SECONDMATE_LEG=%s python3 /mnt/task/.fm-task/fm-secondmate-session.py --task %s --task-generation %s --assignment-generation %s --repository-generation %s --pi-ext /mnt/task/.fm-task/fm-secondmate-spawn.pi-ext.ts --storage-account stfixture --container worker-state-03 --leg-seconds 120 --poll-seconds 5 --idle-seconds 600' \
    "$1" "$ID" "$GEN" "$ASSIGNMENT" "$BASE"
}

# --- units --------------------------------------------------------------------

test_leg1_carries_staging_and_leg2_is_manifest_free_golden() {
  make_world leg-chain
  # A real wall-ended leg: tiny leg budget, no inbox traffic, so the runner
  # exits reason=wall with a verified summary (legs_completed=1).
  run_guest_leg FM_SECONDMATE_LEG_SECONDS=2 >/dev/null 2>&1 \
    || fail "guest wall leg did not exit cleanly"
  start_monitor
  wait_for "leg 2 dispatch after the wall summary" grep -q $'execute\x1f.*FM_SECONDMATE_LEG=2' "$LC_LOG"
  stop_monitor
  local line1 line2 expected1 expected2
  line1=$(grep $'^execute\x1f' "$LC_LOG" | sed -n 1p)
  line2=$(grep $'^execute\x1f' "$LC_LOG" | sed -n 2p)
  expected1=$(printf 'execute\x1f--task\x1f%s\x1f--task-generation\x1f%s\x1f--assignment-generation\x1f%s\x1f--wall-seconds\x1f1920\x1f--payload-dir\x1f%s\x1f--account-dir\x1f%s\x1f--confirm-execute\x1f--confirm-subscription\x1f%s\x1f--\x1f/bin/bash\x1f-lc\x1f%s' \
    "$ID" "$GEN" "$ASSIGNMENT" "$STATE_DIR/$ID.cloud-payload" "$STATE_DIR/$ID.cloud-account" "$SUB" "$(leg_entry_argv 1)")
  [ "$line1" = "$expected1" ] || fail "leg 1 dispatch argv is not the staged shape:
got:      $(printf '%s' "$line1" | tr '\037' '|')
expected: $(printf '%s' "$expected1" | tr '\037' '|')"
  # THE GOLDEN (the rmtree regression guard): the leg 2+ request argv is
  # byte-exact and carries NEITHER --payload-dir NOR --account-dir, so it
  # hits the supervisor's staging-skip branch instead of rmtree-ing the
  # compartment repository. wall 1920 = leg 120 + finish-leg budget 1800.
  expected2=$(printf 'execute\x1f--task\x1f%s\x1f--task-generation\x1f%s\x1f--assignment-generation\x1f%s\x1f--wall-seconds\x1f1920\x1f--confirm-execute\x1f--confirm-subscription\x1f%s\x1f--\x1f/bin/bash\x1f-lc\x1f%s' \
    "$ID" "$GEN" "$ASSIGNMENT" "$SUB" "$(leg_entry_argv 2)")
  [ "$line2" = "$expected2" ] || fail "GOLDEN: leg 2 dispatch argv is not byte-exact manifest-free:
got:      $(printf '%s' "$line2" | tr '\037' '|')
expected: $(printf '%s' "$expected2" | tr '\037' '|')"
  case "$line2" in
    *payload-dir*|*account-dir*) fail "leg 2 dispatch carries staging manifests (the rmtree regression)" ;;
  esac
  assert_present "$STATE_DIR/$ID.cloud-secondmate-leg-0001.dispatched" "leg 1 O_EXCL marker missing"
  assert_present "$STATE_DIR/$ID.cloud-secondmate-leg-0002.dispatched" "leg 2 O_EXCL marker missing"
  assert_present "$STATE_DIR/$ID.cloud-secondmate-first-dispatch" "TTL anchor missing"
  pass "leg 1 carries the staging pair; leg 2 argv is byte-exact manifest-free (rmtree guard)"
}

test_o_excl_guard_prevents_double_dispatch() {
  make_world double-dispatch
  # No outbox traffic at all: leg 1 result lands but no summary ever appears,
  # so renewal stays withheld and leg 1 is the only dispatch either racing
  # monitor could make.
  local second_pane="$WORLD/pane-2.log" second_pid
  start_monitor
  perl -e 'alarm 90; exec @ARGV or die "exec failed: $!"' -- \
    env FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE_DIR" \
    FM_SECONDMATE_LIFECYCLE_BIN="$LIFECYCLE_FIXTURE" \
    FM_SECONDMATE_MONITOR_INTERVAL_SECONDS=1 \
    FM_FIXTURE_LIFECYCLE_LOG="$LC_LOG" FM_FIXTURE_STORE="$STORE" \
    "$MONITOR" "$ID" "$GEN" >> "$second_pane" 2>&1 &
  second_pid=$!
  wait_for "leg 1 dispatch" grep -q $'execute\x1f' "$LC_LOG"
  # Let both monitors run several further iterations against the same state.
  sleep 3
  kill "$second_pid" 2>/dev/null || true
  wait "$second_pid" 2>/dev/null
  stop_monitor
  local executes
  executes=$(grep_lc $'^execute\x1f')
  [ "$executes" = 1 ] || fail "two racing monitors dispatched $executes executes for one leg (O_EXCL guard broken)"
  pass "two racing monitors dispatch exactly one leg execute (O_EXCL)"
}

test_inbox_relay_is_content_addressed_and_replay_safe() {
  make_world inbox-relay
  # fm-send's envelope shape, written directly (the fm-send routing unit
  # covers the real writer): canonical JSON named <seq>-<sha256>.json.
  mkdir -p "$STATE_DIR/$ID.cloud-inbox"
  python3 - "$STATE_DIR/$ID.cloud-inbox" "$ASSIGNMENT" <<'PY'
import hashlib, json, pathlib, sys
inbox, assignment = sys.argv[1:]
for sequence, text in ((1, "first captain note"), (2, "second captain note")):
    message = {"kind": "fm.secondmate-message/v1", "text": text, "nonce": "{}/{:08d}".format(assignment, sequence)}
    body = json.dumps(message, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
    name = "{:08d}-{}.json".format(sequence, hashlib.sha256(body).hexdigest())
    (pathlib.Path(inbox) / name).write_bytes(body)
PY
  start_monitor
  wait_for "both envelopes relayed" both_envelopes_relayed
  stop_monitor
  local puts
  puts=$(grep_lc $'^message-put\x1f')
  [ "$puts" = 2 ] || fail "expected exactly 2 message-put relays, saw $puts"
  # message-put argv names the envelope file; the store blob name digest must
  # equal the local file digest (content addressing end to end).
  python3 - "$STATE_DIR/$ID.cloud-inbox" "$STORE" <<'PY' || fail "store blobs do not content-address the relayed envelopes"
import hashlib, pathlib, re, sys
inbox, store = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
locals_ = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in inbox.glob("[0-9]*.json")}
assert len(locals_) == 2, locals_
for name, digest in locals_.items():
    assert re.fullmatch(r"[0-9]{8}-" + digest + r"\.json", name), (name, digest)
    blob = store / "session" / "in" / (digest + ".json")
    assert blob.is_file(), blob
    assert hashlib.sha256(blob.read_bytes()).hexdigest() == digest
PY
  # Replay: a fresh monitor over the same durable state must not re-put.
  : > "$LC_LOG"
  start_monitor
  sleep 3
  stop_monitor
  puts=$(grep_lc $'^message-put\x1f')
  [ "$puts" = 0 ] || fail "a respawned monitor re-relayed already-relayed envelopes ($puts puts)"
  pass "inbox relay is content-addressed and replay-safe across monitor restarts"
}

test_verified_chain_delivers_and_close_is_terminal() {
  make_world verified-chain
  put_guest_inbox '{"kind":"fm.secondmate-message/v1","text":"hello compartment"}' >/dev/null
  put_guest_inbox '{"kind":"fm.secondmate-control/v1","action":"close"}' >/dev/null
  run_guest_leg >/dev/null 2>&1 || fail "guest close leg did not exit cleanly"
  start_monitor
  wait_for "terminal status file" test -f "$STATE_DIR/$ID.cloud-secondmate-status"
  stop_monitor
  assert_contains "$(cat "$STATE_DIR/$ID.cloud-secondmate-status")" "closed" "close summary did not record a closed terminal status"
  assert_grep 'canned-reply:hello compartment' "$PANE_LOG" "the verified reply text never reached the pane"
  assert_grep 'reason=close' "$PANE_LOG" "the close leg summary never rendered"
  # close is terminal: exactly one leg was dispatched, ever.
  [ "$(grep_lc $'^execute\x1f')" = 1 ] || fail "a closed chain dispatched more than one leg"
  assert_absent "$STATE_DIR/$ID.cloud-secondmate-leg-0002.dispatched" "a closed chain claimed a second leg"
  pass "a verified chain delivers replies to the pane and close ends the chain without renewal"
}

test_dropped_blob_refuses_whole_mailbox_and_freezes_relay() {
  make_world dropped-blob
  put_guest_inbox '{"kind":"fm.secondmate-message/v1","text":"turn one"}' >/dev/null
  put_guest_inbox '{"kind":"fm.secondmate-message/v1","text":"turn two","nonce":"n2"}' >/dev/null
  put_guest_inbox '{"kind":"fm.secondmate-control/v1","action":"close"}' >/dev/null
  run_guest_leg >/dev/null 2>&1 || fail "guest leg did not exit cleanly"
  # Drop the MIDDLE chain entry from the store before any collection.
  local middle
  middle=$(first_matching "$STORE/session/out" '00000002-*.json')
  [ -n "$middle" ] || fail "fixture outbox lacks a second entry"
  rm "$STORE/session/out/$middle"
  # A pending captain envelope proves the inbound freeze.
  mkdir -p "$STATE_DIR/$ID.cloud-inbox"
  start_monitor
  wait_for "chain-break marker" test -f "$STATE_DIR/$ID.cloud-mailbox/.chain-break"
  # Now enqueue an envelope AFTER the break and let the monitor loop again.
  python3 - "$STATE_DIR/$ID.cloud-inbox" "$ASSIGNMENT" <<'PY'
import hashlib, json, pathlib, sys
inbox, assignment = sys.argv[1:]
message = {"kind": "fm.secondmate-message/v1", "text": "after the break", "nonce": assignment + "/00000001"}
body = json.dumps(message, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
name = "00000001-{}.json".format(hashlib.sha256(body).hexdigest())
(pathlib.Path(inbox) / name).write_bytes(body)
PY
  sleep 3
  stop_monitor
  assert_grep 'SECONDMATE MAILBOX REFUSED' "$PANE_LOG" "the chain break was not loud"
  assert_no_grep 'canned-reply:turn one' "$PANE_LOG" "a broken mailbox still relayed entries (must refuse the WHOLE mailbox)"
  assert_no_grep 'canned-reply:turn two' "$PANE_LOG" "a broken mailbox relayed a message"
  [ "$(grep_lc $'^message-put\x1f')" = 0 ] || fail "inbound relay ran after a chain break (must freeze both directions)"
  # Files retained, nothing deleted.
  [ -n "$(first_matching "$STATE_DIR/$ID.cloud-mailbox" '00000001-*.json')" ] \
    || fail "mailbox files were not retained after the break"
  # The marker is sticky: a fresh monitor refuses again without new evidence.
  : > "$PANE_LOG"
  start_monitor
  sleep 2
  stop_monitor
  assert_grep 'CHAIN BREAK recorded' "$PANE_LOG" "the chain-break marker is not sticky across monitor restarts"
  pass "a dropped middle blob refuses the whole mailbox, retains files, freezes relay both ways, and is sticky"
}

test_tampered_content_refuses_whole_mailbox() {
  make_world tampered
  put_guest_inbox '{"kind":"fm.secondmate-message/v1","text":"authentic"}' >/dev/null
  put_guest_inbox '{"kind":"fm.secondmate-control/v1","action":"close"}' >/dev/null
  run_guest_leg >/dev/null 2>&1 || fail "guest leg did not exit cleanly"
  python3 - "$STORE/session/out" <<'PY'
import json, pathlib, sys
out = pathlib.Path(sys.argv[1])
first = sorted(out.glob("00000001-*.json"))[0]
message = json.loads(first.read_text())
message["text"] = "forged reply"
first.write_text(json.dumps(message, sort_keys=True, separators=(",", ":"), ensure_ascii=False))
PY
  start_monitor
  wait_for "chain-break marker" test -f "$STATE_DIR/$ID.cloud-mailbox/.chain-break"
  stop_monitor
  assert_grep 'SECONDMATE MAILBOX REFUSED' "$PANE_LOG" "tampered content was not refused loudly"
  assert_no_grep 'forged reply' "$PANE_LOG" "tampered content was delivered"
  assert_no_grep 'canned-reply:authentic' "$PANE_LOG" "a tampered mailbox still delivered other entries"
  pass "tampered message content refuses the whole mailbox"
}

test_bundle_lands_by_fast_forward_when_clean() {
  make_world bundle-land
  put_guest_inbox '{"kind":"fm.secondmate-message/v1","text":"do a commit"}' >/dev/null
  put_guest_inbox '{"kind":"fm.secondmate-control/v1","action":"close"}' >/dev/null
  FM_FAKE_PI_MODE=commit run_guest_leg >/dev/null 2>&1 || fail "guest commit leg did not exit cleanly"
  local guest_head
  guest_head=$(git -C "$GUEST_REPO" rev-parse HEAD)
  [ "$guest_head" != "$BASE" ] || fail "fixture guest never committed"
  start_monitor
  wait_for "terminal status" test -f "$STATE_DIR/$ID.cloud-secondmate-status"
  wait_for "bundle landed" grep -q 'landed bundle' "$PANE_LOG"
  stop_monitor
  [ "$(git -C "$LANDING" rev-parse HEAD)" = "$guest_head" ] \
    || fail "clean home worktree did not fast-forward to the compartment's commit"
  pass "a verified declared bundle fast-forwards a clean home worktree to the compartment tip"
}

test_bundle_kept_when_worktree_dirty() {
  make_world bundle-kept
  put_guest_inbox '{"kind":"fm.secondmate-message/v1","text":"do a commit"}' >/dev/null
  put_guest_inbox '{"kind":"fm.secondmate-control/v1","action":"close"}' >/dev/null
  FM_FAKE_PI_MODE=commit run_guest_leg >/dev/null 2>&1 || fail "guest commit leg did not exit cleanly"
  printf 'local edit\n' >> "$LANDING/README.md"
  start_monitor
  wait_for "kept-for-manual-landing report" grep -q 'kept at .* for manual landing' "$PANE_LOG"
  stop_monitor
  [ "$(git -C "$LANDING" rev-parse HEAD)" = "$BASE" ] || fail "a dirty worktree was mutated by bundle landing"
  [ -n "$(first_matching "$STATE_DIR/$ID.cloud-mailbox" 'bundle-*.bundle')" ] \
    || fail "the kept bundle is not retained in the mailbox"
  pass "a dirty home worktree keeps the bundle and reports its path instead of landing"
}

test_ttl_refuses_renewal() {
  make_world ttl-refusal
  run_guest_leg FM_SECONDMATE_LEG_SECONDS=2 >/dev/null 2>&1 \
    || fail "guest wall leg did not exit cleanly"
  printf 'export FM_SECONDMATE_TTL_HOURS=0\n' >> "$STATE_DIR/$ID.cloud-env"
  start_monitor
  wait_for "ttl terminal status" test -f "$STATE_DIR/$ID.cloud-secondmate-status"
  stop_monitor
  assert_contains "$(cat "$STATE_DIR/$ID.cloud-secondmate-status")" "ttl-exhausted" "TTL refusal did not record its terminal status"
  assert_grep 'refusing to renew' "$PANE_LOG" "TTL refusal was not loud"
  [ "$(grep_lc $'^execute\x1f')" = 1 ] || fail "TTL-exhausted chain still dispatched a renewal leg"
  pass "renewal past the TTL is refused with a terminal status, never dispatched"
}

test_leg_seconds_above_ceiling_refused_at_startup() {
  make_world leg-ceiling
  # Rewrite (not append): persisted_env_value reads the FIRST match.
  {
    printf 'export FM_AZURE_SUBSCRIPTION_ID=%s\n' "$SUB"
    printf 'export FM_AZURE_STORAGE_NAME=stfixture\n'
    printf 'export FM_SECONDMATE_LEG_SECONDS=19801\n'
  } > "$STATE_DIR/$ID.cloud-env"
  local out status
  out=$(env FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE_DIR" \
    FM_SECONDMATE_LIFECYCLE_BIN="$LIFECYCLE_FIXTURE" \
    FM_FIXTURE_LIFECYCLE_LOG="$LC_LOG" FM_FIXTURE_STORE="$STORE" \
    "$MONITOR" "$ID" "$GEN" 2>&1)
  status=$?
  expect_code 1 "$status" "an over-ceiling leg budget must refuse at startup: $out"
  assert_contains "$out" "cannot fit its finish-leg budget" "the wall-arithmetic refusal did not explain itself: $out"
  [ ! -s "$LC_LOG" ] || fail "an over-ceiling monitor still dispatched something"
  pass "leg_seconds above 19800 refuses at startup (wall = leg + 1800 must fit 21600)"
}

# stage_stale_leg1 <recorded-assignment>: the reviewer's resume scenario. A
# leg-1 claim from hours ago (aged past wall+slack), an empty result (the
# local execute invocation died), and the TTL anchor - the state a respawned
# monitor meets after a crash, with or without an intervening resume.
stage_stale_leg1() {
  local recorded=$1 marker
  marker="$STATE_DIR/$ID.cloud-secondmate-leg-0001.dispatched"
  printf '%s\n' "$recorded" > "$marker"
  : > "$STATE_DIR/$ID.cloud-secondmate-leg-0001.result.json"
  python3 - "$marker" "$STATE_DIR/$ID.cloud-secondmate-first-dispatch" <<'PY'
import os, sys, time
marker, first = sys.argv[1:]
stale = time.time() - 4000  # past WALL(1920) + 300 slack
os.utime(marker, (stale, stale))
with open(first, "w", encoding="utf-8") as handle:
    handle.write(str(int(stale)) + "\n")
PY
}

run_helper() {
  python3 "$ROOT/bin/fm-secondmate-cloud-monitor.py" process-mailbox \
    --task "$ID" --mailbox "$STATE_DIR/$ID.cloud-mailbox" \
    --state-file "$STATE_DIR/$ID.cloud-secondmate-state.json" --worktree "$LANDING"
}

collect_store_into_mailbox() {  # [store-dir]
  local source=${1:-$STORE} blob
  mkdir -p "$STATE_DIR/$ID.cloud-mailbox"
  for blob in "$source"/session/out/*; do
    [ -e "$blob" ] || continue
    cp "$blob" "$STATE_DIR/$ID.cloud-mailbox/${blob##*/}"
  done
}

test_stale_leg1_reclaim_refuses_when_assignment_moved() {
  make_world reclaim-moved
  # The resume moved the worker to a NEW assignment generation; the stale
  # claim was recorded under the old one. A manifest-carrying redispatch
  # here is exactly the rmtree that erases the retained task disk.
  write_controller assigned asg-00000002
  stage_stale_leg1 "$ASSIGNMENT"
  start_monitor
  wait_for "the reclaim refusal" grep -q 'REFUSING to reclaim the stale leg 1 claim' "$PANE_LOG"
  sleep 3
  stop_monitor
  [ "$(grep_lc $'^execute\x1f')" = 0 ] \
    || fail "a moved-assignment stale leg-1 claim was redispatched (the resume rmtree): $(grep $'^execute\x1f' "$LC_LOG" | tr '\037' '|')"
  assert_present "$STATE_DIR/$ID.cloud-secondmate-leg-0001.dispatched" "the refused claim was released anyway"
  assert_contains "$(cat "$PANE_LOG")" "asg-00000002" "the refusal does not name the current assignment"
  assert_contains "$(cat "$PANE_LOG")" "$ASSIGNMENT" "the refusal does not name the recorded assignment"
  pass "a stale leg-1 claim under a moved assignment refuses redispatch, loudly, naming both generations"
}

test_stale_leg1_reclaim_replays_under_same_assignment() {
  make_world reclaim-same
  stage_stale_leg1 "$ASSIGNMENT"
  start_monitor
  wait_for "the digest-idempotent replay" grep -q $'execute\x1f.*FM_SECONDMATE_LEG=1' "$LC_LOG"
  stop_monitor
  assert_grep 'dispatch claim is stale (no result after its bounded wall); reclaiming' "$PANE_LOG" \
    "the same-assignment reclaim was not announced"
  [ "$(grep_lc $'^execute\x1f')" = 1 ] || fail "the same-assignment replay dispatched more than once"
  case "$(grep $'^execute\x1f' "$LC_LOG")" in
    *payload-dir*) : ;;
    *) fail "the replayed leg 1 lost its staging pair" ;;
  esac
  pass "a stale leg-1 claim under the unchanged assignment replays (digest-idempotent)"
}

test_rewound_mailbox_refuses_via_durable_tip() {
  make_world rewind-tip
  put_guest_inbox '{"kind":"fm.secondmate-message/v1","text":"pre-rewind"}' >/dev/null
  put_guest_inbox '{"kind":"fm.secondmate-control/v1","action":"close"}' >/dev/null
  run_guest_leg >/dev/null 2>&1 || fail "guest leg did not exit cleanly"
  collect_store_into_mailbox
  local out
  out=$(run_helper) || fail "the untouched chain did not verify: $out"
  python3 - "$STATE_DIR/$ID.cloud-secondmate-state.json" <<'PY' || fail "the durable verified tip was not recorded"
import json, sys
state = json.load(open(sys.argv[1]))
tip = state.get("verified_tip") or {}
assert state.get("delivered_sequence") == 2, state
assert tip.get("sequence") == 2 and len(tip.get("chain_digest") or "") == 64, tip
PY
  # ATTACK C: the store (and hence the collected mailbox) is rewound below
  # what was already delivered. A stateless verifier calls that a valid
  # short chain; the durable tip refuses it.
  rm "$STATE_DIR/$ID.cloud-mailbox/"*.json
  out=$(run_helper)
  [ $? -eq 3 ] || fail "a rewound mailbox verified instead of refusing: $out"
  assert_contains "$out" "rewound outbox" "the rewind refusal does not explain itself: $out"
  assert_present "$STATE_DIR/$ID.cloud-mailbox/.chain-break" "the rewind left no sticky marker"
  pass "a mailbox rewound below the delivered sequence refuses via the durable tip"
}

test_regenesis_chain_refuses_via_durable_tip() {
  make_world regen-tip
  put_guest_inbox '{"kind":"fm.secondmate-message/v1","text":"authentic turn"}' >/dev/null
  put_guest_inbox '{"kind":"fm.secondmate-control/v1","action":"close"}' >/dev/null
  run_guest_leg >/dev/null 2>&1 || fail "guest leg did not exit cleanly"
  collect_store_into_mailbox
  run_helper >/dev/null || fail "the authentic chain did not verify"
  # ATTACK D: wipe the store and mint a fresh, longer, fully self-consistent
  # chain from genesis (a second runner world), so entries past the old
  # delivered sequence would deliver as verified on a stateless verifier.
  local store2="$WORLD/store2" guest_state2="$WORLD/guest-state2" out
  mkdir -p "$store2/session/in" "$store2/session/out"
  ( STORE="$store2"
    put_guest_inbox '{"kind":"fm.secondmate-message/v1","text":"attack payload one"}' >/dev/null
    put_guest_inbox '{"kind":"fm.secondmate-message/v1","text":"attack payload two","nonce":"n2"}' >/dev/null
    put_guest_inbox '{"kind":"fm.secondmate-control/v1","action":"close"}' >/dev/null
  ) || fail "attacker inbox staging failed"
  run_guest_leg FM_SECONDMATE_BLOB_DIR="$store2" FM_SECONDMATE_STATE_DIR="$guest_state2" \
    >/dev/null 2>&1 || fail "attacker chain generation failed"
  rm "$STATE_DIR/$ID.cloud-mailbox/"*.json
  collect_store_into_mailbox "$store2"
  out=$(run_helper)
  [ $? -eq 3 ] || fail "a re-genesis chain verified instead of refusing: $out"
  assert_contains "$out" "does not reproduce the durable verified tip" "the re-genesis refusal does not explain itself: $out"
  assert_not_contains "$out" "attack payload" "re-genesis entries were delivered as verified"
  assert_present "$STATE_DIR/$ID.cloud-mailbox/.chain-break" "the re-genesis left no sticky marker"
  pass "a wiped-and-reminted chain refuses via the durable tip and delivers nothing"
}

# --- fm-send compartment routing ----------------------------------------------

# shellcheck source=bin/fm-marker-lib.sh
. "$ROOT/bin/fm-marker-lib.sh"

make_send_stubs() {  # <dir> -> echoes fakebin (fake tmux logging literal sends)
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    if [ "$literal" = 1 ]; then
      printf '%s' "${1:-}" >> "$FM_SEND_LOG"
    fi
    exit 0 ;;
  has-session|display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '0\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '\xe2\x94\x82 \xe2\x94\x82\n'; exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  printf '%s\n' "$fb"
}

run_send() {  # <fakebin> <home> <send-log> <fm-send args...>
  local fb=$1 home=$2 log=$3
  shift 3
  : > "$log"
  env PATH="$fb:$PATH" \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" "$@" 2>&1
}

make_send_home() {  # <name> <with-placement> <with-assignment> -> SEND_HOME/SEND_FB/SEND_LOG
  local name=$1 with_placement=$2 with_assignment=$3 dir
  dir="$TMP_ROOT/send-$name"
  SEND_HOME="$dir/home"
  mkdir -p "$SEND_HOME/state" "$dir/stubs"
  SEND_FB=$(make_send_stubs "$dir/stubs")
  SEND_LOG="$dir/send.log"
  fm_write_secondmate_meta "$SEND_HOME/state/domain.meta" "$SEND_HOME" "firstmate:fm-domain"
  {
    printf 'generation_id=%s\n' "$GEN"
    [ "$with_placement" != 1 ] || printf 'placement=azure\n'
    [ "$with_assignment" != 1 ] || printf 'worker_assignment_generation=%s\n' "$ASSIGNMENT"
  } >> "$SEND_HOME/state/domain.meta"
}

test_fm_send_routes_cloud_secondmate_into_the_compartment_inbox() {
  local out rc inbox
  make_send_home routed 1 1
  inbox="$SEND_HOME/state/domain.cloud-inbox"
  out=$(run_send "$SEND_FB" "$SEND_HOME" "$SEND_LOG" fm-domain 'audit the build')
  rc=$?
  expect_code 0 "$rc" "cloud secondmate send should succeed: $out"
  assert_contains "$out" "queued for cloud secondmate" "the routed send did not report its envelope: $out"
  [ ! -s "$SEND_LOG" ] || fail "a cloud secondmate send typed into a local pane: $(cat "$SEND_LOG")"
  python3 - "$inbox" "$ASSIGNMENT" "$FM_FROMFIRST_MARK" <<'PY' || fail "the compartment envelope is not the canonical fenced shape"
import hashlib, json, pathlib, re, sys
inbox, assignment, marker = sys.argv[1:]
files = sorted(p for p in pathlib.Path(inbox).iterdir() if re.fullmatch(r"[0-9]{8}-[0-9a-f]{64}\.json", p.name))
assert len(files) == 1, files
body = files[0].read_bytes()
digest = hashlib.sha256(body).hexdigest()
assert files[0].name == "00000001-{}.json".format(digest), files[0].name
message = json.loads(body)
assert set(message) == {"kind", "text", "nonce"}, message
assert message["kind"] == "fm.secondmate-message/v1"
assert message["nonce"] == assignment + "/00000001", message["nonce"]
assert message["text"] == marker + "audit the build", repr(message["text"])
canonical = json.dumps(message, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
assert canonical == body, "envelope bytes are not canonical"
PY
  # A second identical send is a NEW message (distinct sequence and nonce),
  # never a silent dedupe of a repeated captain instruction.
  out=$(run_send "$SEND_FB" "$SEND_HOME" "$SEND_LOG" fm-domain 'audit the build')
  expect_code 0 $? "second cloud secondmate send should succeed: $out"
  [ -n "$(first_matching "$inbox" '00000002-*.json')" ] || fail "a repeated send did not claim the next sequence"
  # --key has no composer to press.
  out=$(run_send "$SEND_FB" "$SEND_HOME" "$SEND_LOG" fm-domain --key Enter)
  rc=$?
  [ "$rc" -ne 0 ] || fail "--key to a cloud compartment must refuse: $out"
  assert_contains "$out" "no local composer" "--key refusal did not explain the compartment lane: $out"
  pass "fm-send routes cloud secondmate text into fenced canonical inbox envelopes; --key refuses"
}

test_fm_send_local_secondmate_path_is_unchanged() {
  local out rc got
  make_send_home local-path 0 0
  out=$(run_send "$SEND_FB" "$SEND_HOME" "$SEND_LOG" fm-domain 'route this work')
  rc=$?
  expect_code 0 "$rc" "local secondmate send should succeed: $out"
  got=$(cat "$SEND_LOG")
  [ "$got" = "${FM_FROMFIRST_MARK}route this work" ] \
    || fail "a placement-less secondmate send changed behavior (must stay the marked backend send): $(printf '%s' "$got" | od -An -c | head -3)"
  assert_absent "$SEND_HOME/state/domain.cloud-inbox" "a local secondmate send created a compartment inbox"
  pass "fm-send to a local secondmate stays byte-identical (marker + backend send, no inbox)"
}

test_fm_send_prefers_controller_current_assignment() {
  local out rc envelope
  make_send_home resumed 1 1
  # Meta still carries the spawn-time assignment; the controller moved on
  # (a resume). The envelope must fence to the CURRENT generation, not the
  # dead one meta remembers.
  mkdir -p "$SEND_HOME/state/azure-workers"
  python3 - "$SEND_HOME/state/azure-workers/controller.json" domain "$GEN" <<'PY'
import json, sys
path, task, generation = sys.argv[1:]
key = "{}@{}".format(task, generation)
state = {"queue": {key: {"task": task, "task_generation": generation, "status": "assigned",
                         "role": "secondmate", "assignment_generation": "asg-00000099", "slot": 3}},
         "workers": {}}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(state, handle)
PY
  out=$(run_send "$SEND_FB" "$SEND_HOME" "$SEND_LOG" fm-domain 'post-resume note')
  rc=$?
  expect_code 0 "$rc" "post-resume cloud send should succeed: $out"
  envelope=$(first_matching "$SEND_HOME/state/domain.cloud-inbox" '[0-9]*.json')
  [ -n "$envelope" ] || fail "no envelope was written: $out"
  python3 - "$SEND_HOME/state/domain.cloud-inbox/$envelope" <<'PY' || fail "the envelope is not fenced to the controller's current assignment"
import json, sys
message = json.load(open(sys.argv[1]))
assert message["nonce"].startswith("asg-00000099/"), message["nonce"]
PY
  pass "fm-send fences the envelope to the controller's current assignment, not the spawn-time meta"
}

test_fm_send_cloud_secondmate_without_assignment_refuses() {
  local out rc
  make_send_home unassigned 1 0
  out=$(run_send "$SEND_FB" "$SEND_HOME" "$SEND_LOG" fm-domain 'too early')
  rc=$?
  [ "$rc" -ne 0 ] || fail "an unassigned compartment send must refuse (no generation to fence): $out"
  assert_contains "$out" "no worker assignment yet" "the unassigned refusal did not explain itself: $out"
  [ ! -e "$SEND_HOME/state/domain.cloud-inbox" ] \
    || [ -z "$(first_matching "$SEND_HOME/state/domain.cloud-inbox" '[0-9]*.json')" ] \
    || fail "an unfenced envelope was written despite the refusal"
  pass "fm-send refuses a cloud secondmate send that cannot be generation-fenced"
}

# --- fm-spawn gate: FM_SPAWN_SECONDMATE_CLOUD -----------------------------------
#
# A REAL seeded secondmate home (bin/fm-home-seed.sh against an isolated
# default-branch copy of this repo), a real fm-spawn, the fake herdr/tmux
# backends, and the same hermetic provider protocol fixture the
# fm-spawn-cloud suite drives. Off-flag behavior must match main's gate
# byte-for-byte (the exact notice string, local backend, no cloud metadata,
# no controller state); on-flag routes the spawn through queue request
# (role=secondmate), reconcile, and the compartment monitor launch - and
# never dispatches an execute itself.

SPAWN="$ROOT/bin/fm-spawn.sh"
# shellcheck source=tests/secondmate-helpers.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/secondmate-helpers.sh"

GATE_NOTICE='notice: cloud placement covers new ship/scout spawns only; this spawn stays on the local backend'

SPAWN_PRIMARY_ROOT=
make_primary_root() {
  [ -z "$SPAWN_PRIMARY_ROOT" ] || return 0
  SPAWN_PRIMARY_ROOT="$TMP_ROOT/primary-root"
  git init -q -b main "$SPAWN_PRIMARY_ROOT"
  git -C "$SPAWN_PRIMARY_ROOT" fetch -q --no-tags "$ROOT" HEAD
  git -C "$SPAWN_PRIMARY_ROOT" reset -q --hard FETCH_HEAD
}

write_role_fixture_provider() {
  cat >"$1" <<'PY'
#!/usr/bin/env python3
import hashlib
import json
import os
from pathlib import Path
import sys

path = Path(os.environ["FIXTURE_STATE"])
request = json.load(sys.stdin)
controller = request["controller"]
if path.exists():
    state = json.loads(path.read_text())
else:
    state = {
        "workers": {}, "seen": {}, "calls": [],
        "metrics": {
            "actual_usd": float(os.environ.get("FM_TEST_ACTUAL_USD", "100")),
            "forecast_usd": float(os.environ.get("FM_TEST_FORECAST_USD", "150")),
        },
    }

def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()

def tags(action):
    bindings = action["bindings"]
    base = {
        "workload": "firstmate",
        "deployment-generation": action["deployment_generation"], "cleanup-owner": action["owner"],
        "worker-slot": str(action["slot"]), "home-binding": bindings["home_binding"],
        "task-binding": bindings["task"], "task-generation": bindings["task_generation"],
        "assignment-generation": bindings["assignment_generation"],
        "account-binding": bindings["account_binding"], "worktree-binding": bindings["worktree_binding"],
        "repository-binding": bindings["repository_binding"],
        "repository-generation": bindings["repository_generation"],
        "nested-team": "forbidden", "browser-profile": "forbidden",
    }
    if action.get("role") == "secondmate":
        base.update({
            "firstmate-role": "secondmate-compartment",
            "agent-capacity": "one-home-scoped-secondmate",
            "child-launcher": "absent",
        })
    else:
        base.update({
            "firstmate-role": "worker",
            "agent-capacity": "one-task-scoped-crewmate",
            "secondmate-placement": "forbidden",
        })
    return base

def resource(action, kind, serial=None):
    serial = serial or "{}-{}".format(action["cloud_generation"], action["idempotency_key"][:8])
    return {
        "id": "/fixture/slot/{}/{}".format(action["slot"], kind),
        "immutable_id": "{}-{}".format(kind, serial), "etag": "etag-{}".format(serial),
        "tags": tags(action),
    }

def complete_worker(action):
    resources = {}
    for kind in (
        "vm", "nic", "os-disk", "task-disk", "account-disk", "identity", "role-assignment",
        "state-container", "monitor-extension", "bootstrap-command", "task-command", "ttl-schedule",
        "global-reservation", "staging-request", "staging-result",
    ):
        resources[kind] = resource(action, kind)
    resources["vm"]["power_state"] = "VM running"
    resources["nic"]["attached_to"] = resources["vm"]["id"]
    for kind in ("os-disk", "task-disk", "account-disk"):
        resources[kind]["attached_to"] = resources["vm"]["id"]
    for kind in ("monitor-extension", "bootstrap-command", "task-command", "ttl-schedule"):
        resources[kind]["attached_to"] = resources["vm"]["id"]
    for kind in ("monitor-extension", "bootstrap-command", "task-command"):
        resources[kind]["provisioning_state"] = "Succeeded"
    resources["ttl-schedule"].update({"status": "Enabled", "deadline": "2300"})
    for kind in ("global-reservation", "staging-request", "staging-result"):
        resources[kind].update({"digest": "f" * 64, "length": 1})
    return {"slot": action["slot"], "resources": resources}

def save():
    path.write_text(json.dumps(state, sort_keys=True, separators=(",", ":")) + "\n")

if request["operation"] == "mutate":
    action = request["action"]
    key = action["idempotency_key"]
    state["calls"].append({"type": action["type"], "slot": action["slot"], "key": key})
    if key in state["seen"]:
        result = state["seen"][key]
    else:
        slot = str(action["slot"])
        kind = action["type"]
        if kind == "create":
            assert slot not in state["workers"]
            worker = complete_worker(action)
            state["workers"][slot] = worker
            result = {"idempotency_key": key, "action": kind, "worker": worker}
        else:
            raise AssertionError("unexpected mutation for a compartment spawn: " + kind)
        state["seen"][key] = result
    save()
else:
    active = sum(
        1 for worker in state["workers"].values()
        if "vm" in worker["resources"] and "deallocated" not in worker["resources"]["vm"].get("power_state", "").lower()
    )
    metrics = {
        "actual_usd": state["metrics"]["actual_usd"],
        "forecast_usd": state["metrics"]["forecast_usd"],
        "regional_limit_vcpus": 128, "regional_used_vcpus": 2 + 4 * active,
        "specialized_active_vcpus": 0, "specialized_active_by_family": {},
        "family_limit_vcpus": {}, "family_used_vcpus": {},
        "family_free_vcpus": {}, "sku_hourly_usd": {},
    }
    plan = {
        1:("Standard_D4as_v6","standardDav6Family"),2:("Standard_D4as_v6","standardDav6Family"),
        3:("Standard_D4as_v7","StandardDasv7Family"),4:("Standard_D4as_v7","StandardDasv7Family"),
        5:("Standard_D4s_v6","StandardDsv6Family"),6:("Standard_D4s_v6","StandardDsv6Family"),
        7:("Standard_D4ads_v7","StandardDadsv7Family"),8:("Standard_D4ads_v7","StandardDadsv7Family"),
        9:("Standard_D4ads_v6","standardDadv6Family"),10:("Standard_D4ads_v6","standardDadv6Family"),
        11:("Standard_E4as_v7","StandardEasv7Family"),12:("Standard_E4as_v7","StandardEasv7Family"),
        13:("Standard_E4as_v6","standardEav6Family"),14:("Standard_E4as_v6","standardEav6Family"),
        15:("Standard_D4ds_v6","StandardDdsv6Family"),16:("Standard_D4ds_v6","StandardDdsv6Family"),
    }
    for sku, family in plan.values():
        metrics["family_limit_vcpus"][family] = 10
        metrics["family_used_vcpus"][family] = 0
        metrics["family_free_vcpus"][family] = 10
        metrics["sku_hourly_usd"][sku] = 0.25
    inventory = {
        "schema": "fm.worker-provider-inventory/v1", "observed_at": "2026-01-01T00:00:00Z",
        "workers": [state["workers"][key] for key in sorted(state["workers"], key=int)],
        "capacity_reservations": [], "conflicts": [], "metrics": metrics,
    }
    result = inventory

response = {
    "schema": "fm.worker-provider-response/v1", "operation": request["operation"],
    "controller": controller,
}
response["result" if request["operation"] == "mutate" else "inventory"] = result
print(json.dumps(response, sort_keys=True, separators=(",", ":")))
PY
  chmod +x "$1"
}

write_fake_herdr() {  # <fakebin>
  local fakebin=$1
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
LOG="${FM_HERDR_LOG:?}"
STATE="${FM_FAKE_HERDR_STATE:?}"
{
  printf 'HERDR_SESSION=%s' "${HERDR_SESSION:-}"
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$LOG"

jq_state() { jq "$@" "$STATE"; }
save() { local tmp="$STATE.tmp.$$"; cat > "$tmp" && mv "$tmp" "$STATE"; }

cmd=${1:-}; sub=${2:-}
ws=""; label=""; tab=""
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  case "${args[$i]}" in
    --workspace) ws=${args[$((i+1))]:-} ;;
    --label) label=${args[$((i+1))]:-} ;;
    --tab) tab=${args[$((i+1))]:-} ;;
  esac
done

case "$cmd $sub" in
  "status --json")
    printf '{"client":{"version":"0.7.1","protocol":14},"server":{"running":true}}\n'
    ;;
  "workspace list")
    jq_state '{result:{workspaces:.workspaces}}'
    ;;
  "workspace create")
    n=$(jq_state -r '.next'); wsid="w$n"; dn=$((n + 1))
    jq_state --arg wsid "$wsid" --arg wlabel "$label" \
      --arg tabid "$wsid:t$dn" --arg paneid "$wsid:p$dn" \
      '.workspaces += [{workspace_id:$wsid, label:$wlabel}]
       | .tabs += [{tab_id:$tabid, label:"1", workspace_id:$wsid, pane_id:$paneid}]
       | .next = (.next + 2)' | save
    printf '{"result":{"workspace":{"workspace_id":"%s","label":"%s"},"tab":{"tab_id":"%s"},"root_pane":{"pane_id":"%s"}}}\n' \
      "$wsid" "$label" "$wsid:t$dn" "$wsid:p$dn"
    ;;
  "tab list")
    jq_state --arg w "$ws" '{result:{tabs:[.tabs[]|select(.workspace_id==$w)]}}'
    ;;
  "tab create")
    n=$(jq_state -r '.next'); tabid="$ws:t$n"; paneid="$ws:p$n"
    jq_state --arg w "$ws" --arg wlabel "$label" --arg tabid "$tabid" --arg paneid "$paneid" \
      '.tabs += [{tab_id:$tabid, label:$wlabel, workspace_id:$w, pane_id:$paneid}]
       | .next = (.next + 1)' | save
    printf '{"result":{"tab":{"tab_id":"%s"},"root_pane":{"pane_id":"%s"}}}\n' "$tabid" "$paneid"
    ;;
  "pane list")
    if [ -n "$ws" ]; then
      jq_state --arg w "$ws" '{result:{panes:[.tabs[]|select(.workspace_id==$w)|{pane_id:.pane_id, tab_id:.tab_id}]}}'
    else
      jq_state '{result:{panes:[.tabs[]|{pane_id:.pane_id, tab_id:.tab_id}]}}'
    fi
    ;;
  "session list")
    printf '{"sessions":[{"name":"default","running":true}]}\n'
    ;;
  "pane close")
    pane=${3:-}
    jq_state --arg p "$pane" '.tabs |= [.[]|select(.pane_id != $p)]' | save
    ;;
  "tab close")
    tab_target=${3:-}
    jq_state --arg t "$tab_target" '.tabs |= [.[]|select(.tab_id != $t)]' | save
    ;;
  "agent start")
    n=$(jq_state -r '.next'); paneid="${tab%%:*}:p$n"
    jq_state --arg t "$tab" --arg paneid "$paneid" \
      '(.tabs[] | select(.tab_id == $t) | .pane_id) = $paneid
       | .next = (.next + 1)' | save
    printf '{"result":{"agent":{"pane_id":"%s","tab_id":"%s"}}}\n' "$paneid" "$tab"
    ;;
  "agent get")
    pane=${3:-}
    printf '{"error":{"code":"agent_not_found","message":"agent target %s not found"}}\n' "$pane"
    ;;
  *) : ;;
esac
exit 0
SH
  chmod 755 "$fakebin/herdr"
}

# setup_spawn_world <name> <id>: seeded secondmate home + fakes + provider.
# Globals: SP_DIR SP_HOME SP_SUB SP_FAKEBIN SP_TMUX_LOG SP_HERDR_LOG SP_PANE
setup_spawn_world() {
  local name=$1 id=$2
  make_primary_root
  SP_DIR="$TMP_ROOT/spawn-$name"
  SP_HOME="$SP_DIR/main-home"
  SP_SUB="$SP_DIR/${id}-home"
  SP_TMUX_LOG="$SP_DIR/tmux.log"
  SP_HERDR_LOG="$SP_DIR/herdr.log"
  SP_PANE="$SP_DIR/pane.txt"
  mkdir -p "$SP_HOME/projects" "$SP_HOME/data" "$SP_HOME/state" "$SP_DIR/pi-agent-home"
  chmod 755 "$SP_DIR"
  printf '{"openai-codex":{"accountId":"fixture-account"}}\n' > "$SP_DIR/pi-agent-home/auth.json"
  chmod 600 "$SP_DIR/pi-agent-home/auth.json"
  fm_git_init_commit "$SP_HOME/projects/alpha"
  fm_git_add_origin "$SP_HOME/projects/alpha" "$SP_DIR/remotes/alpha.git"
  # direct-PR mode: an untagged project defaults to no-mistakes mode, whose
  # seeding requires the no-mistakes binary (absent on CI runners). The fake
  # is still pinned onto PATH so a mode drift fails deterministically instead
  # of reaching whatever binary the host happens to carry.
  printf -- '- alpha [direct-PR] - alpha project (added 2026-06-22)\n' > "$SP_HOME/data/projects.md"
  SP_FAKEBIN=$(make_fake_tmux "$SP_DIR/fake")
  make_fake_no_mistakes "$SP_DIR/fake" >/dev/null
  chmod 755 "$SP_DIR/fake" "$SP_FAKEBIN"
  write_fake_herdr "$SP_FAKEBIN"
  write_role_fixture_provider "$SP_DIR/provider.py"
  : > "$SP_TMUX_LOG"
  : > "$SP_HERDR_LOG"
  printf 'idle prompt\n' > "$SP_PANE"
  printf '{"next":1,"workspaces":[],"tabs":[],"agent_status":{}}\n' > "$SP_DIR/herdr-state.json"
  FM_SECONDMATE_SCOPE='compartment gate coverage' \
    scaffold_secondmate_charter "$SP_HOME" "$id" 'compartment gate charter' alpha \
    || fail "charter scaffold failed for $id"
  PATH="$SP_FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$SPAWN_PRIMARY_ROOT" FM_HOME="$SP_HOME" \
    "$ROOT/bin/fm-home-seed.sh" "$id" "$SP_SUB" alpha >/dev/null \
    || fail "home seed failed for $id"
}

run_gate_spawn() {  # <id> [VAR=value ...] -- <spawn args...>
  local id=$1 assignments=()
  shift
  while [ $# -gt 0 ] && [ "$1" != -- ]; do
    assignments+=("$1")
    shift
  done
  [ "${1:-}" != -- ] || shift
  env PATH="$SP_FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$SPAWN_PRIMARY_ROOT" FM_HOME="$SP_HOME" \
    FM_FAKE_TMUX_LOG="$SP_TMUX_LOG" FM_FAKE_TMUX_CAPTURE="$SP_PANE" \
    FM_BACKEND_HERDR_TEST_LAB=firstmate-herdr-test-lab-v1 \
    FM_HERDR_LOG="$SP_HERDR_LOG" FM_FAKE_HERDR_STATE="$SP_DIR/herdr-state.json" \
    PI_CODING_AGENT_DIR="$SP_DIR/pi-agent-home" \
    FM_SPAWN_NO_GUARD=1 \
    ${assignments[@]+"${assignments[@]}"} \
    "$SPAWN" "$id" "$SP_SUB" "$@" 2>&1
}

test_spawn_gate_off_flag_is_byte_identical() {
  local out rc meta
  setup_spawn_world off-flag design
  out=$(run_gate_spawn design FM_SPAWN_CLOUD=azure -- codex --secondmate)
  rc=$?
  expect_code 0 "$rc" "off-flag azure secondmate spawn should stay local and succeed: $out"
  assert_contains "$out" "$GATE_NOTICE" "the gate notice string changed (off-flag byte-identity broken): $out"
  assert_contains "$out" "spawned design" "the gated spawn did not complete locally: $out"
  meta="$SP_HOME/state/design.meta"
  assert_present "$meta" "the local spawn wrote no task metadata"
  assert_grep 'kind=secondmate' "$meta" "meta lost kind=secondmate"
  assert_no_grep 'placement=' "$meta" "an off-flag gated spawn recorded cloud placement"
  assert_no_grep 'worker_assignment_generation=' "$meta" "an off-flag gated spawn recorded a worker assignment"
  assert_absent "$SP_HOME/state/azure-workers/controller.json" "an off-flag gated spawn touched the worker controller"
  assert_absent "$SP_HOME/state/design.cloud-payload" "an off-flag gated spawn staged a cloud payload"
  grep -q 'FM_HOME=.*design-home' "$SP_TMUX_LOG" \
    || fail "the local secondmate launch never ran in the subhome; tmux log: $(cat "$SP_TMUX_LOG" 2>/dev/null | head -8); out: $out"
  pass "off-flag: azure + --secondmate keeps the exact gate notice and the byte-identical local path"
}

test_spawn_gate_on_flag_routes_compartment_and_never_executes() {
  local out rc meta
  setup_spawn_world on-flag helm
  out=$(run_gate_spawn helm \
    FM_SPAWN_CLOUD=azure FM_SPAWN_SECONDMATE_CLOUD=1 \
    FM_AZURE_SUBSCRIPTION_ID="$SUB" FM_AZURE_DEPLOYMENT_GENERATION=dep-one \
    FM_AZURE_OWNER_TAG=owner FM_AZURE_NAMING_PREFIX=fmtest \
    FM_AZURE_WORKER_IDLE_COOLDOWN_SECONDS=0 \
    FM_SECONDMATE_LEG_SECONDS=7200 \
    FM_WORKER_PROVIDER_COMMAND="python3 $SP_DIR/provider.py" \
    FIXTURE_STATE="$SP_DIR/provider-state.json" \
    -- --secondmate)
  rc=$?
  expect_code 0 "$rc" "on-flag compartment spawn should succeed: $out"
  assert_not_contains "$out" "$GATE_NOTICE" "the open gate still refused the compartment: $out"
  assert_contains "$out" "spawned helm" "the compartment spawn did not complete: $out"
  assert_contains "$out" "placement=azure" "the compartment spawn did not report cloud placement: $out"
  assert_contains "$out" "secondmate compartment helm is assigned; fm-secondmate-cloud-monitor dispatches its session legs" \
    "the compartment dispatch note is missing: $out"
  meta="$SP_HOME/state/helm.meta"
  assert_grep 'kind=secondmate' "$meta" "meta lost kind=secondmate"
  assert_grep 'placement=azure' "$meta" "meta did not record placement=azure"
  assert_grep 'harness=pi' "$meta" "the compartment did not select the pi runtime"
  assert_grep 'worker_assignment_generation=' "$meta" "the compartment assignment was not recorded in meta"
  # Queue entry: role=secondmate, assigned, on the primary's controller.
  python3 - "$SP_HOME/state/azure-workers/controller.json" helm <<'PY' || fail "controller queue entry is not an assigned role=secondmate compartment"
import json, sys
state = json.load(open(sys.argv[1]))
items = [item for key, item in state["queue"].items() if key.startswith(sys.argv[2] + "@")]
assert len(items) == 1, items
assert items[0]["role"] == "secondmate", items[0]
assert items[0]["owner_kind"] == "primary", items[0]
assert items[0]["status"] == "assigned", items[0]
PY
  # The spawn NEVER dispatches an execute for a compartment: the provider saw
  # exactly one mutation (create), and no worker result or entrypoint exists.
  python3 - "$SP_DIR/provider-state.json" <<'PY' || fail "the spawn drove more than the create mutation"
import json, sys
state = json.load(open(sys.argv[1]))
kinds = sorted({call["type"] for call in state["calls"]})
assert kinds == ["create"], kinds
PY
  assert_absent "$SP_HOME/state/helm.cloud-entrypoint" "a compartment spawn persisted a crewmate entrypoint"
  [ ! -s "$SP_HOME/state/helm.worker-result.json" ] || fail "a compartment spawn dispatched an execute"
  # The staged payload carries the runner, the extension, the repo bundle and
  # the brief; the account dir carries the auth projection.
  assert_present "$SP_HOME/state/helm.cloud-payload/repo.bundle" "payload lacks the home repo bundle"
  assert_present "$SP_HOME/state/helm.cloud-payload/brief.md" "payload lacks the brief"
  assert_present "$SP_HOME/state/helm.cloud-payload/fm-secondmate-session.py" "payload lacks the session runner"
  assert_present "$SP_HOME/state/helm.cloud-payload/fm-secondmate-spawn.pi-ext.ts" "payload lacks the pi extension"
  assert_present "$SP_HOME/state/helm.cloud-account/auth.json" "account staging lacks the auth projection"
  # Durable leg config rode into the persisted compartment environment.
  assert_grep 'FM_SECONDMATE_LEG_SECONDS=7200' "$SP_HOME/state/helm.cloud-env" "leg config was not persisted for the monitor"
  # The tracking pane runs the COMPARTMENT monitor, not the crewmate one.
  assert_grep 'fm-secondmate-cloud-monitor.sh' "$SP_HERDR_LOG" "the pane does not run the compartment monitor"
  assert_no_grep 'fm-spawn-cloud-monitor.sh' "$SP_HERDR_LOG" "the pane runs the crewmate monitor instead of the compartment one"
  pass "on-flag: --secondmate routes through role=secondmate request + monitor launch, with no spawn-side execute"
}

test_leg1_carries_staging_and_leg2_is_manifest_free_golden
test_o_excl_guard_prevents_double_dispatch
test_inbox_relay_is_content_addressed_and_replay_safe
test_verified_chain_delivers_and_close_is_terminal
test_dropped_blob_refuses_whole_mailbox_and_freezes_relay
test_tampered_content_refuses_whole_mailbox
test_bundle_lands_by_fast_forward_when_clean
test_bundle_kept_when_worktree_dirty
test_ttl_refuses_renewal
test_leg_seconds_above_ceiling_refused_at_startup
test_stale_leg1_reclaim_refuses_when_assignment_moved
test_stale_leg1_reclaim_replays_under_same_assignment
test_rewound_mailbox_refuses_via_durable_tip
test_regenesis_chain_refuses_via_durable_tip
test_fm_send_routes_cloud_secondmate_into_the_compartment_inbox
test_fm_send_prefers_controller_current_assignment
test_fm_send_local_secondmate_path_is_unchanged
test_fm_send_cloud_secondmate_without_assignment_refuses
test_spawn_gate_off_flag_is_byte_identical
test_spawn_gate_on_flag_routes_compartment_and_never_executes

echo "# fm-secondmate-cloud-monitor.test.sh: all assertions passed"
