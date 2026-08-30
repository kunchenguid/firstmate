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
# The lifecycle CLI is a FIXTURE for the lanes that would reach Azure (argv
# captured, canned JSON returned, blob transfers modeled against a local store
# directory), because the real wrapper must never run Azure operations from a
# test. `compartment-chain-tip` reaches no provider - it takes the controller
# lock and writes one field - so it is additionally driven through the REAL
# bin/fm-worker-lifecycle.sh against a real controller document, and the
# fixture models its gates and refusal texts. The chain the monitor
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
    attach=
    prev=
    for arg in "$@"; do
      [ "$prev" = --file ] && file=$arg
      [ "$prev" = --attach ] && attach=$arg
      prev=$arg
    done
    [ -n "$file" ] || [ -n "$attach" ] || { echo 'fixture: message-put without --file or --attach' >&2; exit 2; }
    source=${file:-$attach}
    digest=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$source")
    bytes=$(wc -c < "$source" | tr -d '[:space:]')
    if [ -n "$attach" ]; then
      target="$STORE/session/in/attach/$digest.bundle"
      blob="session/in/attach/$digest.bundle"
    else
      target="$STORE/session/in/$digest.json"
      blob="session/in/$digest.json"
    fi
    replayed=false
    if [ -e "$target" ]; then
      replayed=true
    else
      mkdir -p "${target%/*}"
      cp "$source" "$target"
    fi
    # FM_FIXTURE_ATTACH_RECEIPT_SKEW makes the receipt LIE about the uploaded
    # size, the one thing the announcement must never propagate.
    if [ -n "${FM_FIXTURE_ATTACH_RECEIPT_SKEW:-}" ] && [ -n "$attach" ]; then
      bytes=$((bytes + FM_FIXTURE_ATTACH_RECEIPT_SKEW))
    fi
    printf '{"blob_name":"%s","bytes":%s,"replayed":%s,"sha256":"%s"}\n' \
      "$blob" "$bytes" "$replayed" "$digest"
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
  compartment-chain-tip)
    # Models bin/fm-worker-lifecycle.py command_compartment_chain_tip against
    # the fixture controller document: the same assignment gates, the same
    # monotonicity rules, the same refusal texts. The REAL CLI's own gates are
    # exercised by the real-lifecycle unit below and by
    # tests/fm-worker-authority-secondmate.test.sh; this seam exists so the
    # monitor's classification of each refusal can be driven on demand.
    if [ -n "${FM_FIXTURE_CHAIN_TIP_REFUSAL:-}" ]; then
      printf 'ELASTIC WORKER REFUSED: %s\n' "$FM_FIXTURE_CHAIN_TIP_REFUSAL" >&2
      exit 2
    fi
    python3 - "${FM_FIXTURE_CONTROLLER:?}" "$@" <<'PY'
import json, sys
path = sys.argv[1]
flags = sys.argv[2:]
values = {}
for index in range(0, len(flags) - 1, 1):
    if flags[index].startswith("--"):
        values[flags[index]] = flags[index + 1]
task = values["--task"]
generation = values["--task-generation"]
assignment = values["--assignment-generation"]
sequence = int(values["--sequence"])
digest = values["--chain-digest"]

def refuse(text):
    print("ELASTIC WORKER REFUSED: " + text, file=sys.stderr)
    raise SystemExit(2)

if sequence < 1:
    refuse("compartment chain tip sequence must be a positive integer")
if len(digest) != 64 or any(c not in "0123456789abcdef" for c in digest):
    refuse("compartment chain tip digest must be an exact lowercase SHA-256 binding")
with open(path, encoding="utf-8") as handle:
    state = json.load(handle)
key = "{}@{}".format(task, generation)
item = (state.get("queue") or {}).get(key)
if item is None or item.get("status") != "assigned":
    refuse("compartment chain tip requires one exact assigned task generation")
if item.get("role") != "secondmate":
    refuse("compartment chain tip is owned by secondmate compartments only")
worker = (state.get("workers") or {}).get(str(item.get("slot")))
if worker is None or worker.get("queue_key") != key:
    refuse("compartment chain tip task has no exact durable worker owner")
if worker.get("assignment_generation") != assignment:
    refuse("compartment chain tip assignment generation is not exact")
if worker.get("release_proof") is not None:
    refuse("released work cannot record a compartment chain tip")
current = worker.get("verified_chain_tip")
if isinstance(current, dict) and isinstance(current.get("sequence"), int):
    held = current["sequence"]
    if sequence < held:
        refuse("compartment chain tip refuses to rewind from sequence {} to {}".format(held, sequence))
    if sequence == held and current.get("chain_digest") != digest:
        refuse("compartment chain tip sequence {} already recorded a different digest".format(sequence))
worker["verified_chain_tip"] = {
    "sequence": sequence, "chain_digest": digest, "recorded_at": "fixture",
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(state, handle)
print("recorded compartment chain tip {} for {}".format(sequence, task))
PY
    ;;
  *)
    echo "fixture: unsupported lifecycle command $command" >&2
    exit 2
    ;;
esac
SH
  chmod +x "$1"
}

# --- fixture: the fm-spawn seam ----------------------------------------------
#
# The child relay's ONLY way to spend anything. It records argv and the exact
# environment the relay hands it (the parent pair, the moved FM_HOME, the
# pinned controller directory, and the absence of the compartment's own state
# override), and can play an admission refusal on demand. Zero invocations of
# this fixture is therefore proof that command_request was never reached.
write_fixture_spawn() {
  cat > "$1" <<'SH'
#!/usr/bin/env bash
set -u
LOG=${FM_FIXTURE_SPAWN_LOG:?}
{
  first=1
  for arg in "$@"; do
    if [ "$first" = 1 ]; then printf '%s' "$arg"; first=0; else printf '\x1f%s' "$arg"; fi
  done
  printf '\n'
  printf 'env\x1fFM_HOME=%s\x1fFM_SPAWN_TASK_HOME=%s\x1fFM_SPAWN_PARENT_TASK=%s\x1fFM_SPAWN_PARENT_TASK_GENERATION=%s\x1fFM_SPAWN_CLOUD=%s\x1fFM_AZURE_WORKER_STATE_DIR=%s\x1fFM_STATE_OVERRIDE=%s\x1fFM_SECONDMATE_LEG_SECONDS=%s\n' \
    "${FM_HOME:-}" "${FM_SPAWN_TASK_HOME:-<unset>}" \
    "${FM_SPAWN_PARENT_TASK:-}" "${FM_SPAWN_PARENT_TASK_GENERATION:-}" \
    "${FM_SPAWN_CLOUD:-}" "${FM_AZURE_WORKER_STATE_DIR:-<unset>}" \
    "${FM_STATE_OVERRIDE:-<unset>}" "${FM_SECONDMATE_LEG_SECONDS:-<unset>}"
} >> "$LOG"
if [ -n "${FM_FIXTURE_SPAWN_REFUSAL:-}" ]; then
  printf 'ELASTIC WORKER REFUSED: %s\n' "$FM_FIXTURE_SPAWN_REFUSAL" >&2
  echo "error: cloud worker request was refused for ${1:-}" >&2
  exit 1
fi
# A real spawn's admission is a queue entry carrying the parent pair. The
# fixture writes exactly that, so the relay's readback has something true to
# find; FM_FIXTURE_SPAWN_NO_ADMIT models the exit-0-without-admission shape
# the readback exists to catch.
if [ -z "${FM_FIXTURE_SPAWN_NO_ADMIT:-}" ] && [ -n "${FM_FIXTURE_SPAWN_CONTROLLER:-}" ]; then
  python3 - "$FM_FIXTURE_SPAWN_CONTROLLER" "${1:-}" "${FM_SPAWN_PARENT_TASK:-}" "${FM_SPAWN_PARENT_TASK_GENERATION:-}" <<'PY'
import json, sys
path, child, parent, parent_generation = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    state = json.load(handle)
state.setdefault("queue", {})["{}@fixture-gen".format(child)] = {
    "task": child, "task_generation": "fixture-gen", "status": "queued",
    "role": "author", "owner_kind": "secondmate",
    "parent_task": parent, "parent_task_generation": parent_generation,
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(state, handle)
PY
fi
printf 'spawned %s\n' "${1:-}"
SH
  chmod +x "$1"
}

# --- fixture: one compartment world ------------------------------------------
#
# Globals set by make_world: WORLD HOME_DIR STATE_DIR STORE LC_LOG PANE_LOG
# LIFECYCLE_FIXTURE LANDING ORIGIN GUEST_REPO GUEST_STATE BASE FAKE_PI TURN_LOG
# SPAWN_FIXTURE SP_LOG CHILDREQ INBOX_DIR
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
  SPAWN_FIXTURE="$WORLD/fixture-spawn.sh"
  SP_LOG="$WORLD/spawn.log"
  CHILDREQ="$STATE_DIR/$ID.cloud-childreq"
  INBOX_DIR="$STATE_DIR/$ID.cloud-inbox"
  mkdir -p "$STATE_DIR/azure-workers" "$STORE/session/in" "$STORE/session/out" \
    "$STATE_DIR/$ID.cloud-payload" "$STATE_DIR/$ID.cloud-account"
  : > "$LC_LOG"
  : > "$TURN_LOG"
  : > "$SP_LOG"
  write_fixture_spawn "$SPAWN_FIXTURE"
  printf 'staged\n' > "$STATE_DIR/$ID.cloud-payload/repo.bundle"
  printf 'staged\n' > "$STATE_DIR/$ID.cloud-account/auth.json"
  write_fixture_lifecycle "$LIFECYCLE_FIXTURE"
  fm_git_init_commit "$ORIGIN"
  git clone --quiet "$ORIGIN" "$LANDING"
  git clone --quiet "$ORIGIN" "$GUEST_REPO"
  BASE=$(git -C "$LANDING" rev-parse HEAD)
  printf '%s\n' "$LANDING" > "$STATE_DIR/$ID.cloud-worktree"
  # The compartment's local secondmate home IS the recorded worktree, and it
  # is the child's TASK HOME: its brief, backlog row, project and worker
  # result all live there, because the relay hands it to fm-spawn as
  # FM_SPAWN_TASK_HOME. FM_HOME stays this monitor's own home, the
  # controller's, because that is what names the ONE money document.
  # The two homes carry DIFFERENTLY NAMED projects on purpose: the child's
  # project must resolve out of the compartment's home, so a regression that
  # read the primary's projects/ names the wrong directory instead of
  # accidentally naming the right one.
  mkdir -p "$LANDING/data" "$LANDING/projects/alpha" "$LANDING/state" \
    "$HOME_DIR/projects/primary-only" "$HOME_DIR/data"
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
  intent)
    # What the staged pi extension does: write a child-spawn intent into the
    # runner's spool. The REAL runner then validates it and mints the real
    # fm.secondmate-child-request/v1 outbox message.
    printf '%s' "${FM_FAKE_PI_INTENT:?}" > "${FM_SECONDMATE_SPOOL_DIR:?}/intent.json"
    printf 'intent queued'
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
        # queue_key and release_proof are what compartment-chain-tip binds a
        # tip to one exact live assignment, so the fixture world carries the
        # same durable worker shape the real controller writes.
        "queue_key": key, "release_proof": None,
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

put_guest_inbox() {  # '<json>' [store] - store one canonical inbox message
  python3 - "${2:-$STORE}" "$1" <<'PY'
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

# A monitor loop sleeps in a CHILD process, so killing the monitor alone
# orphans that `sleep`. Orphaning does not change process-group membership, so
# the sleep stays in the suite's owned group, where tests/run-one.py reaps it
# and reports a test-isolation violation - failing the whole file with exit 97
# AFTER every assertion has already passed (the exact CI failure this suite hit
# while printing "all assertions passed").
#
# Every backgrounded monitor is therefore its own session leader
# (POSIX::setsid before exec), so one group kill takes the monitor and its
# in-flight sleep down together. That also moves them out of the harness's
# owned group, so stop_process_group replaces the net it removed: it PROVES
# the group is gone and fails loudly if anything survives, rather than letting
# a leak go unnoticed.
MONITOR_PERL='use POSIX (); POSIX::setsid(); alarm shift @ARGV; exec @ARGV or die "exec failed: $!"'

stop_process_group() {  # <pid>
  local pid=${1:-} i=0
  [ -n "$pid" ] || return 0
  kill -- -"$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null
  while [ "$i" -lt 40 ]; do
    kill -0 -- -"$pid" 2>/dev/null || return 0
    sleep 0.05
    i=$((i + 1))
  done
  kill -KILL -- -"$pid" 2>/dev/null || true
  fail "monitor process group $pid survived its stop (a leaked background process)"
}

MONITOR_PID=
start_monitor() {
  perl -e "$MONITOR_PERL" -- 90 \
    env FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE_DIR" \
    FM_SECONDMATE_LIFECYCLE_BIN="$LIFECYCLE_FIXTURE" \
    FM_SECONDMATE_SPAWN_BIN="$SPAWN_FIXTURE" \
    FM_SECONDMATE_MONITOR_INTERVAL_SECONDS=1 \
    FM_FIXTURE_LIFECYCLE_LOG="$LC_LOG" FM_FIXTURE_STORE="$STORE" \
    FM_FIXTURE_SPAWN_LOG="$SP_LOG" \
    FM_FIXTURE_CONTROLLER="$STATE_DIR/azure-workers/controller.json" \
    FM_FIXTURE_CHAIN_TIP_REFUSAL="${FM_FIXTURE_CHAIN_TIP_REFUSAL:-}" \
    FM_FIXTURE_SPAWN_CONTROLLER="$STATE_DIR/azure-workers/controller.json" \
    "$MONITOR" "$ID" "$GEN" >> "$PANE_LOG" 2>&1 &
  MONITOR_PID=$!
}

stop_monitor() {
  stop_process_group "$MONITOR_PID"
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
  perl -e "$MONITOR_PERL" -- 90 \
    env FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE_DIR" \
    FM_SECONDMATE_LIFECYCLE_BIN="$LIFECYCLE_FIXTURE" \
    FM_SECONDMATE_MONITOR_INTERVAL_SECONDS=1 \
    FM_FIXTURE_LIFECYCLE_LOG="$LC_LOG" FM_FIXTURE_STORE="$STORE" \
    "$MONITOR" "$ID" "$GEN" >> "$second_pane" 2>&1 &
  second_pid=$!
  wait_for "leg 1 dispatch" grep -q $'execute\x1f' "$LC_LOG"
  # Let both monitors run several further iterations against the same state.
  sleep 3
  stop_process_group "$second_pid"
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
    --state-file "$STATE_DIR/$ID.cloud-secondmate-state.json" --worktree "$LANDING" \
    --childreq "$CHILDREQ"
}

# run_relay [assignment] - one child-relay pass, the ONLY place a landed
# request is validated, refused, or spent.
run_relay() {
  env FM_FIXTURE_SPAWN_LOG="$SP_LOG" FM_FIXTURE_LIFECYCLE_LOG="$LC_LOG" \
    FM_FIXTURE_STORE="$STORE" \
    FM_FIXTURE_SPAWN_CONTROLLER="$STATE_DIR/azure-workers/controller.json" \
    FM_FIXTURE_SPAWN_NO_ADMIT="${FM_FIXTURE_SPAWN_NO_ADMIT:-}" \
    FM_FIXTURE_SPAWN_REFUSAL="${FM_FIXTURE_SPAWN_REFUSAL:-}" \
    FM_FIXTURE_ATTACH_RECEIPT_SKEW="${FM_FIXTURE_ATTACH_RECEIPT_SKEW:-}" \
    python3 "$ROOT/bin/fm-secondmate-cloud-monitor.py" child-relay \
    --task "$ID" --task-generation "$GEN" \
    --assignment-generation "${1:-$ASSIGNMENT}" \
    --childreq "$CHILDREQ" --inbox "$INBOX_DIR" \
    --spawn-home "$HOME_DIR" --home "$LANDING" \
    --controller "$STATE_DIR/azure-workers/controller.json" \
    --spawn-bin "$SPAWN_FIXTURE" --lifecycle-bin "$LIFECYCLE_FIXTURE"
}

# emit_child_intent <intent-json> - one REAL runner leg whose fake pi writes
# that intent into the spool, so the landed request is the real producer's.
emit_child_intent() {
  put_guest_inbox '{"kind":"fm.secondmate-message/v1","text":"spawn a child"}' >/dev/null
  put_guest_inbox '{"kind":"fm.secondmate-control/v1","action":"close"}' >/dev/null
  run_guest_leg FM_FAKE_PI_MODE=intent FM_FAKE_PI_INTENT="$1" >/dev/null 2>&1 \
    || fail "the guest intent leg did not exit cleanly"
}

# land_from_store - collect the store outbox and run the REAL chain verifier,
# which is what lands request kinds into the relay directory.
land_from_store() {
  collect_store_into_mailbox
  run_helper >> "$PANE_LOG" 2>&1 || fail "the chain verifier refused a chain it produced itself"
}

# inbox_messages - every delivered inbox envelope, one JSON per line.
inbox_messages() {
  python3 - "$INBOX_DIR" <<'PY'
import json, pathlib, re, sys
inbox = pathlib.Path(sys.argv[1])
if not inbox.is_dir():
    raise SystemExit(0)
for path in sorted(p for p in inbox.iterdir() if re.fullmatch(r"[0-9]{8}-[0-9a-f]{64}\.json", p.name)):
    print(json.dumps(json.loads(path.read_bytes()), sort_keys=True))
PY
}

spawn_invocations() { grep -c $'\x1f' "$SP_LOG" 2>/dev/null | tr -d '[:space:]'; }

# inbox_has <pattern> - a PREDICATE over the delivered inbox, re-evaluated on
# every call. `wait_for ... grep -q <pattern> <(inbox_messages)` looks
# equivalent and is not: the process substitution is set up once at call time,
# so the retry loop re-greps an already-exhausted fd and the check can only
# succeed on its first attempt.
inbox_has() { inbox_messages | grep -q "$1"; }

# craft_landed_request <resign|asis> <python-mutation> - take the REAL landed
# child request, mutate it, and re-land it. "resign" recomputes the self digest
# over the mutated payload, which is what a hostile or drifted producer would
# do; "asis" leaves the digest stale, which is the tamper case.
craft_landed_request() {
  python3 - "$CHILDREQ" "$1" "$2" <<'PY'
import hashlib, json, pathlib, sys
childreq, mode, code = sys.argv[1:]
childreq = pathlib.Path(childreq)
CHAIN = ("sequence", "content_sha256", "chain_digest")

def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()

target = None
for path in sorted(childreq.glob("[0-9]*.json")):
    message = json.loads(path.read_text(encoding="utf-8"))
    if message.get("kind") == "fm.secondmate-child-request/v1":
        target = (path, message)
        break
assert target, "no landed child request to craft from"
path, message = target
exec(code, {"message": message})
if mode == "resign":
    payload = {k: v for k, v in message.items() if k not in CHAIN and k != "self_digest"}
    message["self_digest"] = hashlib.sha256(canonical(payload)).hexdigest()
body = canonical(message)
path.unlink()
name = "{:08d}-{}.json".format(int(message.get("sequence", 1)), hashlib.sha256(body).hexdigest())
(childreq / name).write_bytes(body)
print(name)
PY
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
  put_guest_inbox '{"kind":"fm.secondmate-message/v1","text":"attack payload one"}' "$store2" >/dev/null \
    || fail "attacker inbox staging failed"
  put_guest_inbox '{"kind":"fm.secondmate-message/v1","text":"attack payload two","nonce":"n2"}' "$store2" >/dev/null \
    || fail "attacker inbox staging failed"
  put_guest_inbox '{"kind":"fm.secondmate-control/v1","action":"close"}' "$store2" >/dev/null \
    || fail "attacker inbox staging failed"
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

# --- the controller-owned chain tip (the release authority's anchor) ----------
#
# bin/fm-worker-authority.py reads the verified chain tip ONLY from the
# controller-owned worker record and REFUSES when it is absent, naming
# `surrender` as the sanctioned exit. These units own the monitor half of that
# contract: the tip is attested exactly when local verification ADVANCES it,
# never before verification, never twice for the same pair, and each refusal
# class lands on its decided semantics.

# One process-mailbox pass with the tip recording lane wired, which is what
# the bash monitor always does. run_helper deliberately stays unwired so the
# units that predate this lane keep exercising it exactly as they did.
run_helper_recording() {  # [assignment]
  env FM_FIXTURE_LIFECYCLE_LOG="$LC_LOG" FM_FIXTURE_STORE="$STORE" \
    FM_FIXTURE_CONTROLLER="$STATE_DIR/azure-workers/controller.json" \
    FM_FIXTURE_CHAIN_TIP_REFUSAL="${FM_FIXTURE_CHAIN_TIP_REFUSAL:-}" \
    python3 "$ROOT/bin/fm-secondmate-cloud-monitor.py" process-mailbox \
    --task "$ID" --mailbox "$STATE_DIR/$ID.cloud-mailbox" \
    --state-file "$STATE_DIR/$ID.cloud-secondmate-state.json" --worktree "$LANDING" \
    --childreq "$CHILDREQ" \
    --task-generation "$GEN" --assignment-generation "${1:-$ASSIGNMENT}" \
    --lifecycle-bin "$LIFECYCLE_FIXTURE" \
    --controller "${FM_TEST_TIP_CONTROLLER:-$STATE_DIR/azure-workers/controller.json}"
}

# The tip an INDEPENDENT re-derivation of the collected mailbox proves,
# computed from the chain contract itself rather than from anything the
# monitor wrote, printed as "<sequence> <chain_digest>". This is the
# ground truth every recorded tip below is compared against. With an
# argument it prints the chain state at THAT sequence instead of the last,
# which is what a genuinely non-contradicting held tip has to carry.
mailbox_chain_tip() {  # [sequence]
  python3 - "$STATE_DIR/$ID.cloud-mailbox" "${1:-0}" <<'PY'
import hashlib, json, pathlib, re, sys
mailbox = pathlib.Path(sys.argv[1])
want = int(sys.argv[2])
entries = {}
for path in sorted(mailbox.iterdir()):
    match = re.fullmatch(r"([0-9]{8})-([0-9a-f]{64})\.json", path.name)
    if match:
        entries[int(match.group(1))] = path
total = len(entries)
want = total if want <= 0 else want
assert 1 <= want <= total or total == 0, "sequence {} is not in a {}-entry chain".format(want, total)
chain = "0" * 64
for sequence in range(1, want + 1):
    message = json.loads(entries[sequence].read_text(encoding="utf-8"))
    unsigned = {k: v for k, v in message.items() if k not in ("content_sha256", "chain_digest")}
    body = json.dumps(unsigned, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
    content = hashlib.sha256(body).hexdigest()
    chain = hashlib.sha256((chain + content).encode()).hexdigest()
print("{} {}".format(want if total else 0, chain))
PY
}

# The tip the CONTROLLER document carries for this compartment's worker,
# printed the same way; empty when the record carries none.
recorded_worker_tip() {  # [controller-path]
  python3 - "${1:-$STATE_DIR/azure-workers/controller.json}" <<'PY'
import json, sys
try:
    state = json.load(open(sys.argv[1], encoding="utf-8"))
except (OSError, ValueError):
    raise SystemExit(0)
tip = ((state.get("workers") or {}).get("3") or {}).get("verified_chain_tip")
if isinstance(tip, dict):
    print("{} {}".format(tip.get("sequence"), tip.get("chain_digest")))
PY
}

chain_tip_invocations() { grep_lc $'^compartment-chain-tip\x1f'; }

# A PREDICATE, not a substitution. wait_for re-runs its argv on every retry,
# so any `$(...)` or `<(...)` in the arguments is evaluated ONCE at call time
# and the loop then re-tests a frozen value (or an exhausted fd) - a liveness
# check that can only ever succeed on its first attempt.
worker_tip_recorded() { [ -n "$(recorded_worker_tip)" ]; }

monitor_state_field() {  # <python-expression over `state`>
  python3 - "$STATE_DIR/$ID.cloud-secondmate-state.json" "$1" <<'PY'
import json, sys
state = json.load(open(sys.argv[1], encoding="utf-8"))
value = eval(sys.argv[2], {"state": state})  # noqa: S307 - test-local expression
print("" if value is None else value)
PY
}

# one_verified_leg - a real wall-ended runner leg, so the chain the tip is
# taken from is produced by the real producer.
one_verified_leg() {
  run_guest_leg FM_SECONDMATE_LEG_SECONDS=2 >/dev/null 2>&1 \
    || fail "the guest wall leg did not exit cleanly"
  collect_store_into_mailbox
}

# verified_chain_of_two - a real closed leg, whose chain is a reply plus its
# leg summary. Units that need a held tip strictly BELOW the proved one need a
# proved sequence above 1.
verified_chain_of_two() {
  put_guest_inbox '{"kind":"fm.secondmate-message/v1","text":"chain turn"}' >/dev/null
  put_guest_inbox '{"kind":"fm.secondmate-control/v1","action":"close"}' >/dev/null
  run_guest_leg >/dev/null 2>&1 || fail "the guest leg did not exit cleanly"
  collect_store_into_mailbox
}

# force_tip_retry_due - bring the durable backoff deadline forward, so a unit
# can exercise the retry without sleeping through it.
force_tip_retry_due() {
  python3 - "$STATE_DIR/$ID.cloud-secondmate-state.json" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    state = json.load(handle)
error = state.get("chain_tip_error")
assert isinstance(error, dict), "there is no durable chain tip error to bring forward"
error["next_attempt_at"] = 0
with open(path, "w", encoding="utf-8") as handle:
    handle.write(json.dumps(state, sort_keys=True, separators=(",", ":")) + "\n")
PY
}

# build_real_controller <name> <assigned|released> <none|rewind|belowfork|clean>
#
# A REAL controller document for this compartment, minted through the real
# lifecycle module's own environment()/empty_state() so load_state and
# verify_state accept it. Prints the document path. <phase> sets the release
# proof; <held> sets the tip the record already carries:
#   none      - no tip at all
#   rewind    - past this chain's sequence, which the controller's own
#               monotonicity rule already calls a contradiction
#   belowfork - BELOW this chain's sequence with a digest this chain does not
#               reproduce: monotonicity alone accepts it, which is exactly the
#               hole the reproduction check closes
#   clean     - below this chain's sequence carrying the digest this chain
#               ACTUALLY reproduces there, so it is genuinely non-contradicting
build_real_controller() {
  local name=$1 phase=$2 held=$3 home reproduced
  home="$WORLD/$name-home"
  mkdir -p "$home/state/azure-workers"
  # A "clean" control must be clean for the real reason: the held digest has
  # to be the one the proved chain reproduces at that sequence, not merely a
  # lower sequence number.
  reproduced=$(mailbox_chain_tip 1)
  reproduced=${reproduced##* }
  env FM_HOME="$home" FM_AZURE_SUBSCRIPTION_ID="$SUB" \
    FM_AZURE_DEPLOYMENT_GENERATION=dep-one FM_AZURE_OWNER_TAG=owner \
    FM_AZURE_NAMING_PREFIX=fmtest \
    python3 - "$ROOT/bin/fm-worker-lifecycle.py" "$home/state/azure-workers/controller.json" \
    "$ID" "$GEN" "$ASSIGNMENT" "$phase" "$held" "$reproduced" <<'PY' >/dev/null \
    || fail "the real controller fixture could not be built"
import importlib.util, json, sys
module_path, out_path, task, generation, assignment, phase, held, reproduced = sys.argv[1:]
spec = importlib.util.spec_from_file_location("controller", module_path)
controller = importlib.util.module_from_spec(spec)
spec.loader.exec_module(controller)
env = controller.environment()
state = controller.empty_state(env)
key = "{}@{}".format(task, generation)
state["queue"][key] = {
    "task": task, "task_generation": generation, "status": "assigned",
    "role": "secondmate", "slot": 3, "assignment_generation": assignment,
}
worker = {
    "slot": 3, "role": "secondmate", "assignment_generation": assignment,
    "queue_key": key, "release_proof": None,
}
if phase == "released":
    worker["release_proof"] = {"schema": "fm.worker-release/v2", "receipts": []}
if held == "rewind":
    worker["verified_chain_tip"] = {"sequence": 5, "chain_digest": "d" * 64}
elif held == "belowfork":
    worker["verified_chain_tip"] = {"sequence": 1, "chain_digest": "d" * 64}
elif held == "clean":
    assert len(reproduced) == 64, "the clean control needs the digest this chain reproduces"
    worker["verified_chain_tip"] = {"sequence": 1, "chain_digest": reproduced}
state["workers"]["3"] = worker
with open(out_path, "w", encoding="utf-8") as handle:
    json.dump(state, handle, sort_keys=True, separators=(",", ":"))
PY
  printf '%s\n' "$home/state/azure-workers/controller.json"
}

# run_real_cli_recording <controller> - one process-mailbox pass whose
# recording lane is the REAL bin/fm-worker-lifecycle.sh against that real
# controller document. No provider call happens: compartment-chain-tip only
# takes the controller lock and writes one field.
run_real_cli_recording() {  # <controller>
  local controller=$1 home
  home=${controller%/state/azure-workers/controller.json}
  env FM_HOME="$home" FM_AZURE_SUBSCRIPTION_ID="$SUB" \
    FM_AZURE_DEPLOYMENT_GENERATION=dep-one FM_AZURE_OWNER_TAG=owner \
    FM_AZURE_NAMING_PREFIX=fmtest \
    FM_AZURE_WORKER_STATE_DIR="$home/state/azure-workers" \
    python3 "$ROOT/bin/fm-secondmate-cloud-monitor.py" process-mailbox \
    --task "$ID" --mailbox "$STATE_DIR/$ID.cloud-mailbox" \
    --state-file "$STATE_DIR/$ID.cloud-secondmate-state.json" --worktree "$LANDING" \
    --childreq "$CHILDREQ" --task-generation "$GEN" \
    --assignment-generation "$ASSIGNMENT" \
    --lifecycle-bin "$ROOT/bin/fm-worker-lifecycle.sh" \
    --controller "$controller" 2>&1
}

test_verified_advance_records_the_tip_with_the_exact_argv() {
  make_world tip-argv
  one_verified_leg
  local out tip sequence digest expected line
  out=$(run_helper_recording) || fail "the verified chain did not process: $out"
  tip=$(mailbox_chain_tip)
  sequence=${tip%% *}
  digest=${tip##* }
  [ "$sequence" -ge 1 ] || fail "the fixture chain is empty, so there is no tip to record"
  # THE GOLDEN ARGV: exactly the flags bin/fm-worker-lifecycle.py's
  # compartment-chain-tip parser declares, carrying the sequence and digest an
  # independent re-derivation of the mailbox proves.
  expected=$(printf 'compartment-chain-tip\x1f--task\x1f%s\x1f--task-generation\x1f%s\x1f--assignment-generation\x1f%s\x1f--sequence\x1f%s\x1f--chain-digest\x1f%s' \
    "$ID" "$GEN" "$ASSIGNMENT" "$sequence" "$digest")
  line=$(grep $'^compartment-chain-tip\x1f' "$LC_LOG" | sed -n 1p)
  [ "$line" = "$expected" ] || fail "the chain tip argv is not the exact contract:
got:      $(printf '%s' "$line" | tr '\037' '|')
expected: $(printf '%s' "$expected" | tr '\037' '|')"
  # NOT THE MESSAGE LANE: compartment-chain-tip is its own verb, outside the
  # claim-exempt carve whose invariant is that the message ops write no
  # lifecycle state.
  [ "$(grep -c $'^message-[a-z]*\x1f.*--chain-digest' "$LC_LOG" 2>/dev/null | tr -d '[:space:]')" = 0 ] \
    || fail "the chain tip was routed through the claim-exempt message lane"
  [ "$(recorded_worker_tip)" = "$tip" ] \
    || fail "the controller worker record does not carry the verified tip: $(recorded_worker_tip) vs $tip"
  assert_contains "$out" "recorded verified chain tip" "the recording was not announced in the pane: $out"
  pass "a verified advance records the tip on the controller worker record with the exact argv"
}

test_recorded_tip_equals_what_the_local_verifier_proved() {
  make_world tip-truth
  one_verified_leg
  run_helper_recording >/dev/null || fail "the verified chain did not process"
  local truth
  truth=$(mailbox_chain_tip)
  # Three independent statements of the same tip must agree: the local
  # verifier's durable state, the controller-owned record, and a re-derivation
  # from the mailbox that shares no code with either.
  [ "$(monitor_state_field 'state["verified_tip"]["sequence"]') $(monitor_state_field 'state["verified_tip"]["chain_digest"]')" = "$truth" ] \
    || fail "the monitor's durable verified tip differs from the re-derived chain"
  [ "$(monitor_state_field 'state["recorded_chain_tip"]["sequence"]') $(monitor_state_field 'state["recorded_chain_tip"]["chain_digest"]')" = "$truth" ] \
    || fail "the recorded pair differs from the re-derived chain"
  [ "$(recorded_worker_tip)" = "$truth" ] \
    || fail "the controller record differs from the re-derived chain"
  pass "the recorded (sequence, digest) is exactly what the local verifier proved"
}

test_unchanged_tip_is_not_re_recorded_and_an_advance_is() {
  make_world tip-idempotent
  one_verified_leg
  run_helper_recording >/dev/null || fail "the first pass did not process"
  [ "$(chain_tip_invocations)" = 1 ] || fail "the first verified advance did not record a tip"
  run_helper_recording >/dev/null || fail "the second pass did not process"
  run_helper_recording >/dev/null || fail "the third pass did not process"
  [ "$(chain_tip_invocations)" = 1 ] \
    || fail "an unchanged tip was re-recorded ($(chain_tip_invocations) invocations for one tip)"
  # A genuine ADVANCE is recorded again: a second real leg extends the chain.
  local before after
  before=$(mailbox_chain_tip)
  one_verified_leg
  after=$(mailbox_chain_tip)
  [ "$before" != "$after" ] || fail "the second leg did not extend the chain, so there is no advance to test"
  run_helper_recording >/dev/null || fail "the advancing pass did not process"
  [ "$(chain_tip_invocations)" = 2 ] \
    || fail "an advanced tip was not recorded ($(chain_tip_invocations) invocations)"
  [ "$(recorded_worker_tip)" = "$after" ] || fail "the controller record did not advance with the chain"
  pass "an unchanged tip is skipped and only a genuine advance records again"
}

test_refused_chain_verification_records_no_tip() {
  make_world tip-after-verify
  # A chain of at least two entries, so dropping one leaves a real gap.
  put_guest_inbox '{"kind":"fm.secondmate-message/v1","text":"first turn"}' >/dev/null
  put_guest_inbox '{"kind":"fm.secondmate-control/v1","action":"close"}' >/dev/null
  run_guest_leg >/dev/null 2>&1 || fail "the guest leg did not exit cleanly"
  collect_store_into_mailbox
  # ATTACK: a blob is dropped, so the chain does not verify. The tip command
  # attests WITHOUT verifying, so a refused mailbox must never reach it.
  local dropped out
  dropped=$(first_matching "$STATE_DIR/$ID.cloud-mailbox" '00000001-*.json')
  [ -n "$dropped" ] || fail "the fixture chain has no first entry to drop"
  [ -n "$(first_matching "$STATE_DIR/$ID.cloud-mailbox" '00000002-*.json')" ] \
    || fail "the fixture chain is too short for a gap to exist after the drop"
  rm "$STATE_DIR/$ID.cloud-mailbox/$dropped"
  out=$(run_helper_recording)
  [ $? -eq 3 ] || fail "a gapped chain verified instead of refusing: $out"
  [ "$(chain_tip_invocations)" = 0 ] \
    || fail "a gapped chain attested a tip it never verified"
  [ -z "$(recorded_worker_tip)" ] || fail "the controller record carries a tip from a gapped mailbox"
  # THE SUBSTITUTION CASE, which is what the ordering exists for: the names
  # (and therefore the whole chain arithmetic over them) are intact while the
  # bodies are forged. Only verification tells these apart, so a monitor that
  # attested first would report a tip for a mailbox it goes on to refuse.
  make_world tip-after-verify-tampered
  put_guest_inbox '{"kind":"fm.secondmate-message/v1","text":"authentic"}' >/dev/null
  put_guest_inbox '{"kind":"fm.secondmate-control/v1","action":"close"}' >/dev/null
  run_guest_leg >/dev/null 2>&1 || fail "the guest leg did not exit cleanly"
  collect_store_into_mailbox
  python3 - "$STATE_DIR/$ID.cloud-mailbox" <<'PY'
import json, pathlib, sys
mailbox = pathlib.Path(sys.argv[1])
first = sorted(mailbox.glob("00000001-*.json"))[0]
message = json.loads(first.read_text())
message["text"] = "forged reply"
first.write_text(json.dumps(message, sort_keys=True, separators=(",", ":"), ensure_ascii=False))
PY
  out=$(run_helper_recording)
  [ $? -eq 3 ] || fail "a substituted body verified instead of refusing: $out"
  [ "$(chain_tip_invocations)" = 0 ] \
    || fail "a tip was attested for a mailbox whose bodies were substituted"
  [ -z "$(recorded_worker_tip)" ] || fail "the controller record carries a tip from a tampered mailbox"
  pass "a refused chain verification attests no tip at all, gapped or substituted"
}

test_monotonicity_refusal_freezes_the_lane_like_a_chain_break() {
  make_world tip-fork
  put_guest_inbox '{"kind":"fm.secondmate-message/v1","text":"disputed turn"}' >/dev/null
  put_guest_inbox '{"kind":"fm.secondmate-control/v1","action":"close"}' >/dev/null
  run_guest_leg >/dev/null 2>&1 || fail "the guest leg did not exit cleanly"
  collect_store_into_mailbox
  local out
  # The controller holds a different digest at this sequence: its record and
  # this monitor's own proof disagree about the chain, which no later pass can
  # repair.
  out=$(FM_FIXTURE_CHAIN_TIP_REFUSAL='compartment chain tip sequence 2 already recorded a different digest' run_helper_recording)
  [ $? -eq 3 ] || fail "a monotonicity refusal did not freeze the lane: $out"
  assert_contains "$out" "refuses the tip this monitor verified" "the freeze does not explain itself: $out"
  assert_contains "$out" "already recorded a different digest" "the freeze does not carry the controller's own reason: $out"
  assert_present "$STATE_DIR/$ID.cloud-mailbox/.chain-break" "the monotonicity refusal left no sticky marker"
  assert_not_contains "$out" "disputed turn" "a disputed chain was relayed anyway"
  [ "$(monitor_state_field 'state["delivered_sequence"]')" = 0 ] \
    || fail "a disputed chain advanced the delivered sequence"
  [ "$(monitor_state_field 'state["chain_tip_error"]["fatal"]')" = True ] \
    || fail "the fatal refusal was not recorded durably"
  pass "a monotonicity refusal freezes the lane like a chain break and relays nothing"
}

test_already_released_refusal_closes_the_tip_lane_benignly() {
  make_world tip-released
  put_guest_inbox '{"kind":"fm.secondmate-message/v1","text":"late turn"}' >/dev/null
  put_guest_inbox '{"kind":"fm.secondmate-control/v1","action":"close"}' >/dev/null
  run_guest_leg >/dev/null 2>&1 || fail "the guest leg did not exit cleanly"
  collect_store_into_mailbox
  local out
  out=$(FM_FIXTURE_CHAIN_TIP_REFUSAL='released work cannot record a compartment chain tip' run_helper_recording) \
    || fail "a benign end-of-life refusal failed the pass: $out"
  assert_absent "$STATE_DIR/$ID.cloud-mailbox/.chain-break" "an already-released worker froze the lane"
  assert_contains "$out" "chain tip recording is closed" "the benign close was not announced: $out"
  assert_contains "$out" "late turn" "a released worker stopped ordinary delivery"
  [ -n "$(monitor_state_field 'state["chain_tip_closed"]["reason"]')" ] \
    || fail "the close was not recorded durably"
  # The lane stays closed: a later pass makes no further attempt.
  out=$(FM_FIXTURE_CHAIN_TIP_REFUSAL='released work cannot record a compartment chain tip' run_helper_recording) \
    || fail "the second pass failed: $out"
  [ "$(chain_tip_invocations)" = 1 ] \
    || fail "the closed tip lane kept calling the controller ($(chain_tip_invocations) invocations)"
  pass "an already-released refusal closes the tip lane quietly and never freezes the compartment"
}

test_ownership_refusal_warns_backs_off_and_retries_without_freezing() {
  make_world tip-transient
  one_verified_leg
  local out refusal warnings
  # A moved assignment is what a re-spawn does to a HEALTHY compartment (a
  # resume preserves the assignment generation and bumps cloud_generation).
  # It must never wedge the lane; a later pass carries the current assignment.
  refusal='compartment chain tip assignment generation is not exact'
  : > "$WORLD/tip-warnings.log"
  out=$(FM_FIXTURE_CHAIN_TIP_REFUSAL="$refusal" run_helper_recording) \
    || fail "an ownership refusal failed the pass: $out"
  printf '%s\n' "$out" >> "$WORLD/tip-warnings.log"
  assert_contains "$out" "the controller refused the verified chain tip" "the warning is not loud: $out"
  assert_contains "$out" "retrying in" "the warning does not say when it retries: $out"
  assert_absent "$STATE_DIR/$ID.cloud-mailbox/.chain-break" "an ownership refusal froze the lane"
  [ "$(monitor_state_field 'state["chain_tip_error"]["fatal"]')" = False ] \
    || fail "an ownership refusal was recorded as fatal"
  [ "$(monitor_state_field 'state["chain_tip_error"]["attempts"]')" = 1 ] \
    || fail "the first refused attempt was not counted durably"
  [ -z "$(monitor_state_field 'state["recorded_chain_tip"]')" ] \
    || fail "a refused tip was recorded as landed"
  # BACKOFF: every attempt takes the controller lock, so an immediate second
  # pass must not call the CLI again at all.
  out=$(FM_FIXTURE_CHAIN_TIP_REFUSAL="$refusal" run_helper_recording) \
    || fail "the backed-off pass failed: $out"
  printf '%s\n' "$out" >> "$WORLD/tip-warnings.log"
  [ "$(chain_tip_invocations)" = 1 ] \
    || fail "a backed-off pass still took the controller lock ($(chain_tip_invocations) invocations)"
  # Once the backoff elapses the same call is retried, and the identical
  # refusal is recorded durably rather than reprinted.
  force_tip_retry_due
  out=$(FM_FIXTURE_CHAIN_TIP_REFUSAL="$refusal" run_helper_recording) \
    || fail "the retry pass failed: $out"
  printf '%s\n' "$out" >> "$WORLD/tip-warnings.log"
  [ "$(chain_tip_invocations)" = 2 ] || fail "the refused tip was not retried once its backoff elapsed"
  [ "$(monitor_state_field 'state["chain_tip_error"]["attempts"]')" = 2 ] \
    || fail "the retried attempt was not counted durably"
  warnings=$(grep -c 'the controller refused the verified chain tip' "$WORLD/tip-warnings.log" | tr -d '[:space:]')
  [ "$warnings" = 1 ] \
    || fail "an identical repeated refusal was reprinted $warnings times instead of recorded once"
  # And once ownership settles, the same tip lands and the error clears.
  force_tip_retry_due
  run_helper_recording >/dev/null || fail "the settled pass failed"
  [ "$(recorded_worker_tip)" = "$(mailbox_chain_tip)" ] || fail "the retry never landed the tip"
  [ -z "$(monitor_state_field 'state["chain_tip_error"]')" ] || fail "a landed tip left its error behind"
  pass "an ownership refusal warns once, backs off the controller lock, and retries instead of freezing"
}

test_released_worker_holding_a_contradicting_tip_still_freezes() {
  make_world tip-released-fork
  verified_chain_of_two
  # THE ORDERING HOLE THIS CLOSES, proven against the REAL CLI:
  # command_compartment_chain_tip checks the release proof BEFORE its
  # monotonicity block, so a RELEASED worker answers a genuine rewind with
  # "released work cannot record a compartment chain tip" - the benign string.
  # Classifying on the string alone would close the lane and keep relaying a
  # chain the controller's own record contradicts.
  local real_controller out
  real_controller=$(build_real_controller tip-released-fork released rewind)
  out=$(run_real_cli_recording "$real_controller")
  [ $? -eq 3 ] || fail "a released worker holding a contradicting tip did not freeze: $out"
  # The real CLI really did answer with the benign string, and the readback is
  # what turned it back into a freeze.
  assert_contains "$out" "released work cannot record a compartment chain tip" \
    "the real CLI did not produce the released refusal, so this no longer pins the ordering hole: $out"
  assert_contains "$out" "cannot be the tip this monitor verified" "the freeze does not explain itself: $out"
  assert_present "$STATE_DIR/$ID.cloud-mailbox/.chain-break" "the released fork left no sticky marker"
  [ "$(monitor_state_field 'state["chain_tip_error"]["fatal"]')" = True ] \
    || fail "the released fork was not recorded as fatal"
  [ -z "$(monitor_state_field 'state["chain_tip_closed"]')" ] \
    || fail "a contradicting held tip still closed the lane benignly"
  pass "a released worker whose held tip contradicts this chain freezes, though the CLI calls it benign"
}

test_released_worker_holding_a_below_tip_fork_still_freezes() {
  make_world tip-released-belowfork
  verified_chain_of_two
  # CASE E, which the controller's monotonicity rule alone NEVER catches: the
  # held tip sits strictly BELOW the proved sequence, so no rewind and no
  # same-sequence fork exists, and a longer chain that diverges BENEATH the
  # held tip would be attested as an ordinary lagging record. Same
  # preconditions as the rewind case (released worker, monitor state lost),
  # and without the reproduction check the forgery closes benignly AND relays.
  local real_controller out held
  real_controller=$(build_real_controller tip-released-belowfork released belowfork)
  held=$(mailbox_chain_tip 1)
  [ "${held##* }" != "$(printf 'd%.0s' $(seq 1 64))" ] \
    || fail "the below-tip control accidentally planted the digest this chain reproduces"
  out=$(run_real_cli_recording "$real_controller")
  [ $? -eq 3 ] || fail "a held tip below the proved sequence with a digest this chain does not reproduce was accepted: $out"
  assert_contains "$out" "released work cannot record a compartment chain tip" \
    "the real CLI did not produce the released refusal, so this no longer pins the ordering hole: $out"
  assert_contains "$out" "does not reproduce it" "the freeze does not name the reproduction failure: $out"
  assert_present "$STATE_DIR/$ID.cloud-mailbox/.chain-break" "the below-tip fork left no sticky marker"
  assert_not_contains "$out" "chain turn" "a chain the held tip contradicts beneath the tip was relayed"
  [ -z "$(monitor_state_field 'state["chain_tip_closed"]')" ] \
    || fail "a below-tip fork closed the tip lane benignly"
  [ "$(monitor_state_field 'state["delivered_sequence"]')" = 0 ] \
    || fail "a below-tip fork advanced the delivered sequence"
  pass "a held tip below the proved sequence that this chain does not reproduce freezes, not closes"
}

test_released_worker_with_no_contradicting_tip_closes_benignly() {
  make_world tip-released-clean
  verified_chain_of_two
  # The same released refusal from the same real CLI, with a GENUINELY
  # non-contradicting held tip: below the proved sequence AND carrying the
  # digest this chain actually reproduces there. A lower sequence number alone
  # is not a clean control - that is the below-tip fork above.
  local real_controller out held
  real_controller=$(build_real_controller tip-released-clean released clean)
  held=$(mailbox_chain_tip 1)
  assert_contains "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["workers"]["3"]["verified_chain_tip"]["chain_digest"])' "$real_controller")" \
    "${held##* }" "the clean control does not carry the digest this chain reproduces at sequence 1"
  out=$(run_real_cli_recording "$real_controller") \
    || fail "a benign end-of-life refusal failed the pass: $out"
  assert_contains "$out" "chain tip recording is closed" "the benign close was not announced: $out"
  assert_absent "$STATE_DIR/$ID.cloud-mailbox/.chain-break" "an ordinary released worker froze the lane"
  # The durable record carries the real CLI's own refusal text, which is what
  # pins the released marker string against the real command rather than
  # against this suite's fixture.
  assert_contains "$(monitor_state_field 'state["chain_tip_closed"]["reason"]')" \
    "released work cannot record a compartment chain tip" \
    "the real CLI did not produce the released refusal, so the marker string is unpinned"
  pass "a released worker whose held tip cannot contradict this chain closes the lane quietly"
}

test_unreadable_controller_never_closes_the_tip_lane() {
  make_world tip-released-unreadable
  one_verified_leg
  local out
  # The released string with NO readable controller document: agreement
  # cannot be proved, and closing on faith would silently downgrade this
  # compartment to surrender for good. It must fall to the retry class.
  out=$(FM_TEST_TIP_CONTROLLER="$WORLD/absent-controller.json" \
    FM_FIXTURE_CHAIN_TIP_REFUSAL='released work cannot record a compartment chain tip' \
    run_helper_recording) || fail "the unreadable-controller pass failed: $out"
  assert_absent "$STATE_DIR/$ID.cloud-mailbox/.chain-break" "an unreadable controller froze the lane"
  [ -z "$(monitor_state_field 'state["chain_tip_closed"]')" ] \
    || fail "the tip lane closed without reading the held tip back"
  assert_contains "$out" "could not be read back" "the unreadable readback was not explained: $out"
  [ "$(monitor_state_field 'state["chain_tip_error"]["fatal"]')" = False ] \
    || fail "an unreadable controller was recorded as fatal"
  pass "a released refusal with an unreadable controller retries instead of closing on faith"
}

test_monitor_pass_records_the_tip_end_to_end() {
  make_world tip-monitor
  put_guest_inbox '{"kind":"fm.secondmate-message/v1","text":"monitor turn"}' >/dev/null
  put_guest_inbox '{"kind":"fm.secondmate-control/v1","action":"close"}' >/dev/null
  run_guest_leg >/dev/null 2>&1 || fail "the guest leg did not exit cleanly"
  start_monitor
  wait_for "the chain tip recorded through the monitor" \
    grep -q $'^compartment-chain-tip\x1f' "$LC_LOG"
  wait_for "the controller record to carry the tip" worker_tip_recorded
  stop_monitor
  [ "$(recorded_worker_tip)" = "$(mailbox_chain_tip)" ] \
    || fail "the monitor recorded a tip other than the one it verified: $(recorded_worker_tip) vs $(mailbox_chain_tip)"
  assert_grep 'recorded verified chain tip' "$PANE_LOG" "the monitor pane never reported the recording"
  pass "the whole monitor pass records the verified tip the release authority reads"
}

test_chain_tip_argv_is_accepted_by_the_real_lifecycle_cli() {
  make_world tip-real-cli
  one_verified_leg
  # The fixture above models the command; this proves the MONITOR'S OWN ARGV
  # is the argv the real bin/fm-worker-lifecycle.sh parses and honours. No
  # provider call happens: compartment-chain-tip only takes the controller
  # lock and writes one field.
  local real_controller out
  real_controller=$(build_real_controller tip-real-cli assigned none)
  out=$(run_real_cli_recording "$real_controller") \
    || fail "the real lifecycle CLI refused the monitor's chain tip argv: $out"
  assert_contains "$out" "recorded verified chain tip" "the real CLI recorded nothing: $out"
  [ "$(recorded_worker_tip "$real_controller")" = "$(mailbox_chain_tip)" ] \
    || fail "the real controller document does not carry the verified tip: $(recorded_worker_tip "$real_controller")"
  pass "the monitor's chain tip argv is accepted and honoured by the real lifecycle CLI"
}

# --- the child relay (design B.5 steps 2-5) -----------------------------------

test_valid_child_request_spawns_with_the_exact_parent_pair() {
  make_world child-valid
  emit_child_intent '{"kind":"ship","brief":"ship the compartment child","model":"openai-codex/gpt-5.6-sol","effort":"high"}'
  start_monitor
  wait_for "the child spawn" test -s "$SP_LOG"
  wait_for "the acceptance delivered into the inbox" inbox_has 'FIRSTMATE ACCEPTED'
  stop_monitor
  local self_digest child argv env_line
  self_digest=$(python3 - "$CHILDREQ" <<'PY'
import json, pathlib, sys
for path in sorted(pathlib.Path(sys.argv[1]).glob("[0-9]*.json")):
    message = json.loads(path.read_text())
    if message.get("kind") == "fm.secondmate-child-request/v1":
        print(message["self_digest"])
        break
PY
)
  [ -n "$self_digest" ] || fail "the real runner landed no child request"
  child="$ID-c${self_digest:0:8}"
  argv=$(sed -n 1p "$SP_LOG")
  # The project resolves out of the COMPARTMENT's home (alpha), never the
  # primary's (primary-only): the split points fm-spawn's projects/ there.
  [ "$argv" = "$(printf '%s\x1f%s\x1f--harness\x1fpi\x1f--model\x1fopenai-codex/gpt-5.6-sol\x1f--effort\x1fhigh' "$child" "$LANDING/projects/alpha")" ] \
    || fail "the child spawn argv is not the exact ship shape: $(printf '%s' "$argv" | tr '\037' '|')"
  env_line=$(sed -n 2p "$SP_LOG")
  assert_contains "$env_line" "FM_HOME=$HOME_DIR" \
    "the child spawn moved FM_HOME; it must stay the controller's own home"
  # THE SPLIT: the task home is the compartment's own home, and it is what
  # makes fm-spawn derive owner_kind=secondmate and forward --task-home.
  assert_contains "$env_line" "FM_SPAWN_TASK_HOME=$LANDING" \
    "the child spawn carried no task home, so it would mint an unrestricted primary-owned request"
  assert_contains "$env_line" "FM_SPAWN_PARENT_TASK=$ID" "the child spawn lost the parent task"
  assert_contains "$env_line" "FM_SPAWN_PARENT_TASK_GENERATION=$GEN" "the child spawn lost the parent generation"
  assert_contains "$env_line" "FM_SPAWN_CLOUD=azure-only" \
    "the nested child did not enter the mandatory Azure placement policy"
  # NO state-dir pin: that name is persisted into the child's durable cloud
  # environment, so a pin would outlive this spawn and misdirect every later
  # execute and release. With FM_HOME unmoved the default is already right.
  assert_contains "$env_line" "FM_AZURE_WORKER_STATE_DIR=<unset>" \
    "the child spawn pinned a worker state dir, which is persisted and becomes a durable trap"
  assert_contains "$env_line" "FM_STATE_OVERRIDE=<unset>" \
    "the compartment's own state override leaked into the child spawn"
  assert_contains "$env_line" "FM_SECONDMATE_LEG_SECONDS=<unset>" \
    "the compartment's leg configuration leaked into the child spawn"
  # The brief bytes became the child's brief file, byte for byte.
  assert_present "$LANDING/data/$child/brief.md" "the child brief was never written"
  [ "$(cat "$LANDING/data/$child/brief.md")" = "ship the compartment child" ] \
    || fail "the child brief is not the requested bytes: $(cat "$LANDING/data/$child/brief.md")"
  # The brief and the backlog row land in the TASK home, which is the data/
  # fm-spawn reads; a copy under the primary would leave fm-spawn's own
  # backlog-row gate refusing every child in a real home.
  assert_absent "$HOME_DIR/data/$child" "the child brief landed under the primary, where fm-spawn does not look"
  assert_present "$LANDING/data/backlog.md" "the child backlog row was never filed in the task home"
  assert_absent "$HOME_DIR/data/backlog.md" "the child backlog row was filed under the primary"
  assert_present "$CHILDREQ/.accepted-$self_digest.json" "no durable acceptance record"
  [ "$(spawn_invocations)" = 2 ] || fail "expected exactly one spawn (argv + env lines), saw $(spawn_invocations) lines"
  pass "a real runner-emitted child request spawns once, as the secondmate, with the exact parent pair"
}

test_invalid_child_requests_refuse_by_name_and_never_reach_the_request() {
  local case_name mutation mode expected
  # Each case: one landed request that must be refused BEFORE any spawn, with
  # the exact check named in the delivered refusal.
  for case_name in unknown-key bad-kind wrong-parent tampered-digest; do
    make_world "child-invalid-$case_name"
    emit_child_intent '{"kind":"ship","brief":"a child that must not be spawned"}'
    land_from_store
    case "$case_name" in
      unknown-key)
        mode=asis
        mutation='message["repository"] = "/etc"'
        expected="request carries unknown key: repository" ;;
      bad-kind)
        mode=resign
        mutation='message["child_kind"] = "invade"'
        expected="request child_kind must be ship or scout" ;;
      wrong-parent)
        mode=resign
        mutation='message["parent_assignment_generation"] = "asg-00000099"'
        expected="request parent_assignment_generation 'asg-00000099' is not the current assignment" ;;
      tampered-digest)
        mode=asis
        mutation='message["self_digest"] = "f" * 64'
        expected="request self_digest does not recompute over its payload" ;;
    esac
    craft_landed_request "$mode" "$mutation" >/dev/null \
      || fail "$case_name: crafting the landed request failed"
    run_relay > "$WORLD/relay.log" 2>&1 || fail "$case_name: the relay pass itself failed: $(cat "$WORLD/relay.log")"
    local delivered
    delivered=$(inbox_messages)
    assert_contains "$delivered" "$expected" "$case_name: the delivered refusal does not name the failed check"
    assert_contains "$delivered" "FIRSTMATE REFUSED your request" "$case_name: no refusal was delivered at all"
    [ -n "$(first_matching "$CHILDREQ" '.refused-*.json')" ] \
      || fail "$case_name: no durable .refused record was written"
    [ ! -s "$SP_LOG" ] || fail "$case_name: an invalid request reached the spawn (and so command_request): $(cat "$SP_LOG")"
    [ "$(grep_lc $'^message-put\x1f')" = 0 ] || fail "$case_name: an invalid request spent the message lane"
  done
  pass "unknown key, bad child kind, wrong parent triple and a tampered self digest each refuse by name, deliver it, and never spawn"
}

test_non_string_optional_field_refuses_and_the_pass_continues() {
  # THE ALWAYS-AN-ANSWER RULE. A present-but-not-a-string optional field used
  # to reach a regex and raise, which killed the whole pass: no refusal
  # record, no delivered refusal, every later request unanswered, and child
  # status mirroring dead for good. Each type must refuse by name, and the
  # NEXT request in the SAME pass must still be served.
  local shape expected
  for shape in int dict list null bool; do
    make_world "child-nonstring-$shape"
    emit_child_intent '{"kind":"ship","brief":"the poisoned request"}'
    land_from_store
    case "$shape" in
      int) expected='message["child_model"] = 7' ;;
      dict) expected='message["child_model"] = {"a": 1}' ;;
      list) expected='message["child_model"] = ["a"]' ;;
      null) expected='message["child_model"] = None' ;;
      bool) expected='message["child_model"] = True' ;;
    esac
    craft_landed_request resign "$expected" >/dev/null || fail "$shape: crafting failed"
    # A SECOND, entirely valid request lands after the poisoned one, in the
    # same relay pass, at a later chain sequence.
    land_second_valid_request
    run_relay > "$WORLD/relay.log" 2>&1
    expect_code 0 $? "$shape: the relay pass must survive a poisoned field: $(cat "$WORLD/relay.log")"
    local delivered
    delivered=$(inbox_messages)
    assert_contains "$delivered" "request field child_model is present but is not a non-empty string" \
      "$shape: the non-string optional field was not refused by name"
    [ -n "$(first_matching "$CHILDREQ" '.refused-*.json')" ] \
      || fail "$shape: no durable refusal record for the poisoned request"
    assert_contains "$delivered" "FIRSTMATE ACCEPTED" \
      "$shape: the request AFTER the poisoned one was never served (the pass died)"
    [ "$(spawn_invocations)" = 2 ] \
      || fail "$shape: expected exactly one spawn for the following valid request, saw $(spawn_invocations) log lines"
  done
  pass "a non-string optional field of any type refuses by name and the next request in the pass is still served"
}

# land_second_valid_request - a valid child request at a later chain sequence,
# minted the way the runner mints one (payload, then self digest over it).
land_second_valid_request() {
  python3 - "$CHILDREQ" "$ID" "$GEN" "$ASSIGNMENT" <<'PY'
import hashlib, json, pathlib, sys
childreq, task, generation, assignment = sys.argv[1:]
childreq = pathlib.Path(childreq)

def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()

payload = {
    "kind": "fm.secondmate-child-request/v1",
    "parent_task": task,
    "parent_task_generation": generation,
    "parent_assignment_generation": assignment,
    "child_kind": "ship",
    "brief": "the request that must still be served",
}
message = dict(payload)
message["self_digest"] = hashlib.sha256(canonical(payload)).hexdigest()
message["sequence"] = 90
message["content_sha256"] = "c" * 64
message["chain_digest"] = "d" * 64
body = canonical(message)
(childreq / "00000090-{}.json".format(hashlib.sha256(body).hexdigest())).write_bytes(body)
PY
}

test_leading_dash_brief_refuses() {
  make_world child-dash-brief
  emit_child_intent '{"kind":"ship","brief":"the brief"}'
  land_from_store
  craft_landed_request resign 'message["brief"] = "--session-dir /mnt/account"' >/dev/null \
    || fail "crafting the leading-dash brief failed"
  run_relay > "$WORLD/relay.log" 2>&1 || fail "the relay pass failed: $(cat "$WORLD/relay.log")"
  assert_contains "$(inbox_messages)" "request brief begins with '-' and cannot ride the pi argv" \
    "a leading-dash brief was not refused by name"
  [ ! -s "$SP_LOG" ] || fail "a leading-dash brief reached the spawn: $(cat "$SP_LOG")"
  pass "a brief beginning with '-' refuses, matching the runner's own leading-dash rule"
}

test_spawn_exit_zero_without_admission_refuses() {
  # B.1's invariant is that child compute exists only when the ONE controller
  # admits it. fm-spawn has an exit-0 path that silently downgrades placement,
  # so a zero exit is never proof of admission: the queue is.
  make_world child-no-admission
  emit_child_intent '{"kind":"ship","brief":"a child that is never admitted"}'
  land_from_store
  FM_FIXTURE_SPAWN_NO_ADMIT=1 run_relay > "$WORLD/relay.log" 2>&1 \
    || fail "the relay pass failed: $(cat "$WORLD/relay.log")"
  assert_contains "$(inbox_messages)" "the controller holds no queue entry for" \
    "an exit-0 spawn with no admitted queue entry was accepted"
  [ -z "$(first_matching "$CHILDREQ" '.accepted-*.json')" ] \
    || fail "an unadmitted child was recorded as accepted"
  pass "a zero-exit spawn that admitted nothing refuses loudly instead of counting as a child"
}

test_attach_sequence_allows_repeat_asks_and_refuses_non_monotone() {
  make_world attach-sequence
  printf 'first artifact\n' >> "$LANDING/README.md"
  git -C "$LANDING" add README.md
  git -C "$LANDING" commit -qm 'home artifact one'
  land_attach_request 1 1 >/dev/null
  run_relay > "$WORLD/relay-1.log" 2>&1 || fail "the first attach pass failed: $(cat "$WORLD/relay-1.log")"
  [ "$(inbox_messages | grep -c 'fm.secondmate-attach/v1')" = 1 ] \
    || fail "the first ask did not announce exactly one attach"
  # A SECOND ask, distinguished only by attach_sequence, is served: without
  # the discriminator its payload would hash identically and refuse.
  printf 'second artifact\n' >> "$LANDING/README.md"
  git -C "$LANDING" add README.md
  git -C "$LANDING" commit -qm 'home artifact two'
  land_attach_request 2 2 >/dev/null
  run_relay > "$WORLD/relay-2.log" 2>&1 || fail "the second attach pass failed: $(cat "$WORLD/relay-2.log")"
  [ "$(inbox_messages | grep -c 'fm.secondmate-attach/v1')" = 2 ] \
    || fail "a second attach ask was not served: $(inbox_messages | grep -c 'fm.secondmate-attach/v1') announcements"
  # Non-monotone: an ask at or below what was served refuses by name.
  land_attach_request 2 3 >/dev/null
  run_relay > "$WORLD/relay-3.log" 2>&1 || fail "the third attach pass failed"
  assert_contains "$(inbox_messages)" "is not past the 2 already served" \
    "a non-monotone attach_sequence was not refused by name"
  [ "$(inbox_messages | grep -c 'fm.secondmate-attach/v1')" = 2 ] \
    || fail "a non-monotone ask still announced an attach"
  pass "attach_sequence lets a compartment ask more than once and refuses a non-monotone ask by name"
}

test_empty_delta_burns_no_attach_sequence() {
  make_world attach-empty
  # No commits over the dispatched base: the ask serves nothing.
  land_attach_request 1 1 >/dev/null
  run_relay > "$WORLD/relay-1.log" 2>&1 || fail "the empty attach pass failed: $(cat "$WORLD/relay-1.log")"
  assert_contains "$(inbox_messages)" "is not spent and you may ask again with it" \
    "the empty delta did not tell the compartment its sequence survived"
  [ -z "$(first_matching "$CHILDREQ" '.accepted-*.json')" ] \
    || fail "an empty delta recorded an acceptance and burned the sequence"
  # The SAME attach_sequence is therefore still available once work lands.
  printf 'late artifact\n' >> "$LANDING/README.md"
  git -C "$LANDING" add README.md
  git -C "$LANDING" commit -qm 'home artifact after the empty ask'
  land_attach_request 1 2 >/dev/null
  run_relay > "$WORLD/relay-2.log" 2>&1 || fail "the re-ask pass failed: $(cat "$WORLD/relay-2.log")"
  [ "$(inbox_messages | grep -c 'fm.secondmate-attach/v1')" = 1 ] \
    || fail "re-asking with the unspent sequence was not served"
  pass "an ask that finds no delta serves nothing, records nothing, and leaves its attach_sequence unspent"
}

test_duplicate_child_request_refuses_loudly_and_spawns_once() {
  make_world child-duplicate
  emit_child_intent '{"kind":"scout","brief":"scout the duplicate lane"}'
  land_from_store
  run_relay > "$WORLD/relay-1.log" 2>&1 || fail "the first relay pass failed: $(cat "$WORLD/relay-1.log")"
  [ "$(spawn_invocations)" = 2 ] || fail "the first valid request did not spawn exactly once"
  grep -q -- '--scout' "$SP_LOG" || fail "a scout request did not carry --scout: $(tr '\037' '|' < "$SP_LOG")"
  # A RESEND of the same intent: the runner would re-emit it at a new
  # sequence, so the same self digest arrives under a new content address.
  python3 - "$CHILDREQ" <<'PY'
import hashlib, json, pathlib, sys
childreq = pathlib.Path(sys.argv[1])
source = None
for path in sorted(childreq.glob("[0-9]*.json")):
    message = json.loads(path.read_text())
    if message.get("kind") == "fm.secondmate-child-request/v1":
        source = message
        break
assert source, "no landed child request"
resend = dict(source)
resend["sequence"] = int(resend["sequence"]) + 10
body = json.dumps(resend, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
name = "{:08d}-{}.json".format(resend["sequence"], hashlib.sha256(body).hexdigest())
(childreq / name).write_bytes(body)
PY
  run_relay > "$WORLD/relay-2.log" 2>&1 || fail "the resend relay pass failed: $(cat "$WORLD/relay-2.log")"
  assert_contains "$(inbox_messages)" "was already accepted and is not spent twice" \
    "the duplicate resend was not refused loudly"
  [ "$(spawn_invocations)" = 2 ] || fail "a duplicate resend spawned a second child ($(spawn_invocations) log lines)"
  pass "a resent child request refuses loudly as a duplicate and never spawns twice"
}

test_admission_refusal_round_trips_into_the_inbox() {
  make_world child-admission
  emit_child_intent '{"kind":"ship","brief":"a child past the fan-out cap"}'
  land_from_store
  FM_FIXTURE_SPAWN_REFUSAL="secondmate $ID already owns 4 active children (cap 4)" \
    run_relay > "$WORLD/relay.log" 2>&1 || fail "the relay pass failed: $(cat "$WORLD/relay.log")"
  local delivered
  delivered=$(inbox_messages)
  assert_contains "$delivered" "already owns 4 active children (cap 4)" \
    "the controller's admission refusal did not round-trip into the compartment inbox"
  assert_contains "$delivered" "child spawn was refused" "the refusal does not say what was refused"
  [ -n "$(first_matching "$CHILDREQ" '.refused-*.json')" ] || fail "no durable refusal record for the admission refusal"
  [ -z "$(first_matching "$CHILDREQ" '.accepted-*.json')" ] || fail "a refused admission still recorded an acceptance"
  # No queue item exists: the fixture spawn refused before touching anything,
  # so the controller still holds exactly the compartment itself.
  python3 - "$STATE_DIR/azure-workers/controller.json" "$ID" <<'PY' || fail "a refused child left a queue item behind"
import json, sys
state = json.load(open(sys.argv[1]))
keys = sorted(state["queue"])
assert keys == ["{}@gen-one".format(sys.argv[2])], keys
PY
  pass "a command_request admission refusal round-trips verbatim into the inbox with no queue item"
}

test_attach_announcement_matches_the_uploaded_bundle() {
  make_world attach-bundle
  # The home worktree gains a commit (what a child's landed outcome looks
  # like), then the compartment asks for the delta.
  printf 'child work\n' >> "$LANDING/README.md"
  git -C "$LANDING" add README.md
  git -C "$LANDING" commit -qm 'child landed work'
  land_attach_request 1 1 >/dev/null
  run_relay > "$WORLD/relay.log" 2>&1 || fail "the relay pass failed: $(cat "$WORLD/relay.log")"
  local announcement
  announcement=$(inbox_messages | grep 'fm.secondmate-attach/v1') \
    || fail "no attach announcement was delivered: $(inbox_messages)"
  python3 - "$STORE" "$announcement" <<'PY' || fail "the announcement does not match the uploaded bundle"
import hashlib, json, pathlib, sys
store, raw = sys.argv[1:]
message = json.loads(raw)
assert set(message) == {"kind", "name", "sha256", "bytes", "nonce"}, message
assert message["name"].startswith("session/in/attach/"), message["name"]
blob = pathlib.Path(store) / message["name"]
assert blob.is_file(), blob
body = blob.read_bytes()
assert hashlib.sha256(body).hexdigest() == message["sha256"], "digest differs from the uploaded blob"
assert len(body) == message["bytes"], (len(body), message["bytes"])
assert message["name"] == "session/in/attach/{}.bundle".format(message["sha256"])
PY
  # The runner's own size-checked fetch consumes it: relay the announcement
  # VERBATIM (nonce and all, exactly the bytes the monitor delivers) into the
  # guest inbox and run a REAL leg, which must fetch the bundle.
  python3 - "$STORE" "$announcement" <<'PY'
import hashlib, json, pathlib, sys
store, raw = sys.argv[1:]
message = json.loads(raw)
body = json.dumps(message, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
target = pathlib.Path(store) / "session" / "in" / (hashlib.sha256(body).hexdigest() + ".json")
target.write_bytes(body)
PY
  put_guest_inbox '{"kind":"fm.secondmate-control/v1","action":"close"}' >/dev/null
  run_guest_leg >/dev/null 2>&1 || fail "the guest leg consuming the attach did not exit cleanly"
  git -C "$GUEST_REPO" cat-file -e "$(git -C "$LANDING" rev-parse HEAD)^{commit}" \
    || fail "the runner's size-checked fetch did not bring the announced delta into the guest repository"
  pass "the attach announcement carries name+sha256+bytes matching the upload, and the real runner fetches it"
}

test_size_mismatched_announcement_is_never_sent() {
  make_world attach-skew
  printf 'child work\n' >> "$LANDING/README.md"
  git -C "$LANDING" add README.md
  git -C "$LANDING" commit -qm 'child landed work'
  land_attach_request 1 1 >/dev/null
  FM_FIXTURE_ATTACH_RECEIPT_SKEW=1 run_relay > "$WORLD/relay.log" 2>&1 \
    || fail "the relay pass failed: $(cat "$WORLD/relay.log")"
  local delivered
  delivered=$(inbox_messages)
  assert_not_contains "$delivered" "fm.secondmate-attach/v1" \
    "an announcement was sent for an upload receipt that disagreed about the size"
  assert_contains "$delivered" "differs from the bundle this monitor hashed" \
    "the size mismatch was not refused by name"
  [ -n "$(first_matching "$CHILDREQ" '.refused-*.json')" ] || fail "no durable refusal record for the skewed receipt"
  pass "an upload receipt disagreeing about size is refused and never announced"
}

test_child_terminal_status_mirrors_once() {
  make_world child-status
  emit_child_intent '{"kind":"ship","brief":"a child that finishes"}'
  land_from_store
  run_relay > "$WORLD/relay-1.log" 2>&1 || fail "the accepting relay pass failed: $(cat "$WORLD/relay-1.log")"
  local child
  child=$(python3 - "$CHILDREQ" <<'PY'
import json, pathlib, sys
for path in sorted(pathlib.Path(sys.argv[1]).glob(".accepted-*.json")):
    print(json.loads(path.read_text())["child_task"])
    break
PY
)
  [ -n "$child" ] || fail "no child was accepted"
  # Not terminal yet: nothing is mirrored.
  write_controller_with_child "$child" assigned 0
  run_relay > "$WORLD/relay-2.log" 2>&1 || fail "the pre-terminal relay pass failed"
  assert_not_contains "$(inbox_messages)" "CHILD $child is" "a non-terminal child was reported as finished"
  # Terminal AND failed: the controller says complete, the child's own result
  # carries the non-zero exit that makes it a failure.
  write_controller_with_child "$child" complete 0
  # The child's own lane writes its result under the TASK home's state/,
  # because the split aimed this task's state/ there.
  printf '{"schema":"fm.worker-execution-result/v1","exit_code":3,"timed_out":false}\n' \
    > "$LANDING/state/$child.worker-result.json"
  run_relay > "$WORLD/relay-3.log" 2>&1 || fail "the terminal relay pass failed"
  assert_contains "$(inbox_messages)" "CHILD $child is failed (exit code 3)" \
    "the child's terminal status was not mirrored with its failure classification"
  local mirrored
  mirrored=$(inbox_messages | grep -c "CHILD $child is")
  run_relay > "$WORLD/relay-4.log" 2>&1 || fail "the repeat relay pass failed"
  [ "$(inbox_messages | grep -c "CHILD $child is")" = "$mirrored" ] \
    || fail "the terminal status was mirrored more than once"
  pass "a child's terminal status mirrors into the inbox exactly once, with its complete/failed classification"
}

# land_attach_request [attach-sequence] [chain-sequence] - the attach contract
# this monitor PINS (the runner-side emission is a follow-up), landed exactly
# as the chain verifier would.
land_attach_request() {
  python3 - "$CHILDREQ" "$ID" "$GEN" "$ASSIGNMENT" "${1:-1}" "${2:-1}" <<'PY'
import hashlib, json, pathlib, sys
childreq, task, generation, assignment, counter, chain = sys.argv[1:]
childreq = pathlib.Path(childreq)
childreq.mkdir(parents=True, exist_ok=True)

def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()

payload = {
    "kind": "fm.secondmate-attach-request/v1",
    "parent_task": task,
    "parent_task_generation": generation,
    "parent_assignment_generation": assignment,
    "attach_sequence": int(counter),
}
message = dict(payload)
message["self_digest"] = hashlib.sha256(canonical(payload)).hexdigest()
message["sequence"] = int(chain)
message["content_sha256"] = "{:064x}".format(int(chain))
message["chain_digest"] = "b" * 64
body = canonical(message)
name = "{:08d}-{}.json".format(int(chain), hashlib.sha256(body).hexdigest())
(childreq / name).write_bytes(body)
print(message["self_digest"])
PY
}

# write_controller_with_child <child-task> <child-status> <unused> - the
# compartment plus one child queue item carrying the parent pair.
write_controller_with_child() {
  mkdir -p "$HOME_DIR/state"
  python3 - "$STATE_DIR/azure-workers/controller.json" "$ID" "$GEN" "$ASSIGNMENT" "$BASE" "$1" "$2" <<'PY'
import json
import sys

path, task, generation, assignment, base, child, child_status = sys.argv[1:]
key = "{}@{}".format(task, generation)
state = {
    "queue": {
        key: {
            "task": task, "task_generation": generation, "status": "assigned",
            "role": "secondmate", "assignment_generation": assignment, "slot": 3,
        },
        "{}@child-gen".format(child): {
            "task": child, "task_generation": "child-gen", "status": child_status,
            "role": "author", "owner_kind": "secondmate",
            "parent_task": task, "parent_task_generation": generation,
        },
    },
    "workers": {
        "3": {
            "slot": 3, "role": "secondmate", "assignment_generation": assignment,
            "bindings": {"repository_generation": base},
        },
    },
}
with open(path, "w", encoding="utf-8") as handle:
    json.dump(state, handle)
PY
}

test_child_request_queue_item_bindings_equal_local_mints() {
  # The REAL request path (bin/fm-worker-lifecycle.py request) against the
  # fixture provider: a compartment is requested and assigned, then a child is
  # requested with the parent pair, and its queue item's bindings are diffed
  # FIELD BY FIELD against what authoritative_request_bindings mints locally.
  local world home azure out
  world="$TMP_ROOT/real-request"
  home="$world/home"
  azure="$home/state/azure-workers"
  mkdir -p "$home/state" "$azure"
  write_role_fixture_provider "$world/provider.py"
  make_lifecycle_task "$world" "$home" parent pgen
  make_lifecycle_task "$world" "$home" child cgen
  out=$(run_lifecycle "$world" "$home" request \
    --task parent --task-generation pgen --owner-kind primary --role secondmate --eligible 2>&1) \
    || fail "the compartment request was refused: $out"
  out=$(run_lifecycle "$world" "$home" reconcile --apply --confirm-subscription "$SUB" --json 2>&1) \
    || fail "the compartment reconcile was refused: $out"
  out=$(run_lifecycle "$world" "$home" request \
    --task child --task-generation cgen --owner-kind secondmate --role author \
    --parent-task parent --parent-task-generation pgen --eligible 2>&1) \
    || fail "the compartment child request was refused: $out"
  python3 - "$ROOT/bin/fm-worker-lifecycle.py" "$azure/controller.json" "$home" "$SUB" <<'PY' \
    || fail "the child queue item bindings are not the local authoritative mints"
import importlib.util, json, os, sys

module_path, controller, home, subscription = sys.argv[1:]
os.environ.update({
    "FM_HOME": home,
    "FM_AZURE_SUBSCRIPTION_ID": subscription,
    "FM_AZURE_DEPLOYMENT_GENERATION": "dep-one",
    "FM_AZURE_OWNER_TAG": "owner",
    "FM_AZURE_NAMING_PREFIX": "fmtest",
    "FM_AZURE_WORKER_STATE_DIR": os.path.join(home, "state", "azure-workers"),
    "FM_AZURE_WORKER_IDLE_COOLDOWN_SECONDS": "0",
})
spec = importlib.util.spec_from_file_location("fm_worker_lifecycle", module_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
env = module.environment()
minted = module.authoritative_request_bindings(env, "child", "cgen")
item = json.load(open(controller))["queue"]["child@cgen"]
for field, value in sorted(minted.items()):
    assert item.get(field) == value, (field, item.get(field), value)
assert item["parent_task"] == "parent", item
assert item["parent_task_generation"] == "pgen", item
assert item["owner_kind"] == "secondmate" and item["role"] == "author", item
PY
  pass "a compartment child's queue item bindings equal the local authoritative mints, field by field"
}

# fm_secondmate_write_pi_pool <auth.json path> <profiles> - a fixture Pi
# credential pool shaped as bin/fm-pi-account-home.py requires of a projectable
# profile, with one distinct upstream account per slot.
fm_secondmate_write_pi_pool() {  # <auth.json path> <profiles> [account-scope]
  python3 - "$1" "$2" "${3:-shared}" <<'FMPIPOOL'
import json
import sys

scope = sys.argv[3]
pool = {}
for index in range(1, int(sys.argv[2]) + 1):
    name = "openai-codex" if index == 1 else "openai-codex-{}".format(index)
    pool[name] = {
        "type": "oauth", "access": "fixture-access-{}".format(index),
        "refresh": "fixture-refresh-{}".format(index),
        # Scoped so pools written for different tasks never name the same
        # upstream account: placement leases the ACCOUNT, so colliding ids
        # across fixtures would read as exhaustion rather than as a fixture bug.
        "accountId": "fixture-account-{}-{}".format(scope, index),
        "expires": 4102444800000,
    }
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(pool, handle, sort_keys=True, indent=2)
FMPIPOOL
  chmod 600 "$1"
}

# make_lifecycle_task <world> <home> <task> <generation> - the ordinary local
# authorities a real request derives its bindings from.
make_lifecycle_task() {
  local world=$1 home=$2 task=$3 generation=$4
  fm_git_init_commit "$world/$task-wt"
  mkdir -p "$world/$task-account"
  # The task's provider-account POOL. Placement leases one profile out of the
  # pool named by this task's own metadata and refuses a directory it cannot
  # identify an upstream account in, so an empty directory is not a usable
  # account authority any more.
  # Distinct accounts PER TASK, not a shared pair: every lifecycle task in this
  # suite draws from its own pool, and identical accountId values across tasks
  # would make a future third concurrent task hit exhaustion and look
  # mysterious. The task name seeds the account ids so they cannot collide.
  fm_secondmate_write_pi_pool "$world/$task-account/auth.json" 2 "$task"
  python3 - "$home/state/$task.meta" "$generation" "$world/$task-wt" "$world/$task-account" "$task" <<'PY'
import os
import pathlib
import sys

meta, generation, worktree, account, task = sys.argv[1:]
worktree = str(pathlib.Path(worktree).resolve())
git_dir = os.path.join(worktree, ".git")
stat = os.stat(git_dir)
pathlib.Path(meta).write_text(
    "generation_id={}\nworktree={}\naccount_home={}\naccount_task={}\n"
    "worktree_git_dir_identity={}:{}\n".format(
        generation, worktree, str(pathlib.Path(account).resolve()), task,
        stat.st_dev, stat.st_ino,
    ),
    encoding="utf-8",
)
PY
}

run_lifecycle() {  # <world> <home> <args...>
  local world=$1 home=$2
  shift 2
  env FM_HOME="$home" \
    FM_AZURE_SUBSCRIPTION_ID="$SUB" FM_AZURE_DEPLOYMENT_GENERATION=dep-one \
    FM_AZURE_OWNER_TAG=owner FM_AZURE_NAMING_PREFIX=fmtest \
    FM_AZURE_WORKER_IDLE_COOLDOWN_SECONDS=0 \
    FM_AZURE_WORKER_STATE_DIR="$home/state/azure-workers" \
    FM_WORKER_PROVIDER_COMMAND="python3 $world/provider.py" \
    FIXTURE_STATE="$world/provider-state.json" \
    python3 "$ROOT/bin/fm-worker-lifecycle.py" "$@"
}

test_child_request_through_the_real_fm_spawn_with_crew_dispatch() {
  # THE SEAM THE FIXTURE SPAWN CANNOT TOUCH: relay argv -> the REAL
  # bin/fm-spawn.sh argument validation, in a home carrying
  # config/crew-dispatch.json (the primary propagates it into secondmate
  # homes, so most real homes have it).
  #
  # THE WHOLE LANE, END TO END, through every real component: a real
  # compartment spawned by the real fm-spawn, a real child request, the real
  # relay, the real fm-spawn again, and the real controller. It used to stop
  # at a third gate that no change in the relay's own files could close -
  # owner_kind was derived from the spawn's own home marker, so a request
  # minted under the primary's FM_HOME was primary-owned and verify_request
  # refused the parent pair on it. The task-home split closed that gate:
  #
  #   FM_HOME stays the PRIMARY's, so the request is admitted into the ONE
  #   money document and the home fence on it is never touched;
  #   FM_SPAWN_TASK_HOME is the COMPARTMENT's own home, so owner_kind derives
  #   secondmate from THAT marker, the bindings are minted from the child's
  #   meta under that home, and --task-home carries the directory to the
  #   controller, which authorizes it against the marker plus the primary's
  #   registry and then applies the four child bounds.
  #
  # So this unit now asserts ADMISSION, and asserts it from the money
  # document rather than from an exit code: the child's own queue entry,
  # owner_kind=secondmate, this compartment's parent pair, home_binding
  # naming the COMPARTMENT's home while the document's own home_binding names
  # the PRIMARY, and the parent's children_total incremented.
  local out rc parent parent_generation assignment controller relay_home child_task
  setup_spawn_world real-spawn mast
  out=$(run_gate_spawn mast \
    FM_SPAWN_CLOUD=azure FM_SPAWN_SECONDMATE_CLOUD=1 \
    FM_AZURE_SUBSCRIPTION_ID="$SUB" FM_AZURE_DEPLOYMENT_GENERATION=dep-one \
    FM_AZURE_OWNER_TAG=owner FM_AZURE_NAMING_PREFIX=fmtest \
    FM_AZURE_WORKER_IDLE_COOLDOWN_SECONDS=0 \
    FM_WORKER_PROVIDER_COMMAND="python3 $SP_DIR/provider.py" \
    FIXTURE_STATE="$SP_DIR/provider-state.json" \
    -- --secondmate)
  rc=$?
  expect_code 0 "$rc" "the compartment spawn should succeed: $out"
  controller="$SP_HOME/state/azure-workers/controller.json"
  parent=mast
  parent_generation=$(python3 -c 'import json,sys
state = json.load(open(sys.argv[1]))
for key, item in state["queue"].items():
    if item.get("task") == sys.argv[2]:
        print(item["task_generation"]); break' "$controller" "$parent")
  assignment=$(python3 -c 'import json,sys
state = json.load(open(sys.argv[1]))
for key, item in state["queue"].items():
    if item.get("task") == sys.argv[2]:
        print(item.get("assignment_generation", "")); break' "$controller" "$parent")
  [ -n "$parent_generation" ] && [ -n "$assignment" ] \
    || fail "the compartment is not assigned on the controller: $(cat "$controller")"
  # The consultation backstop file, in BOTH homes: the primary carries it and
  # propagates it into secondmate homes, and the spawn runs under the
  # controller's home, so that is the copy the harness gate reads.
  mkdir -p "$SP_SUB/config" "$SP_HOME/config"
  printf '{"profiles":[]}\n' > "$SP_SUB/config/crew-dispatch.json"
  printf '{"profiles":[]}\n' > "$SP_HOME/config/crew-dispatch.json"
  printf '%s\n' manual > "$SP_SUB/config/backlog-backend"
  printf '%s\n' manual > "$SP_HOME/config/backlog-backend"
  relay_home="$SP_SUB"
  # A crewmate child leases a worktree of its PROJECT repo, so this world needs
  # the crewmate-shaped treehouse stub (the secondmate helper's leases homes).
  mkdir -p "$SP_DIR/child-fake"
  cat > "$SP_DIR/child-fake/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = get ]; then
  printf '%s\n' "${FM_FAKE_TREEHOUSE_WORKTREE:?}"
fi
exit 0
SH
  chmod +x "$SP_DIR/child-fake/treehouse"
  mkdir -p "$SP_SUB/treehouse-pools" "$SP_HOME/treehouse-pools"
  chmod 755 "$SP_SUB" "$SP_SUB/treehouse-pools" "$SP_HOME/treehouse-pools"
  # The child's project resolves out of the COMPARTMENT's home, so its leased
  # worktree must be a worktree of THAT clone; fm-spawn refuses a lease from
  # an unrelated repository.
  git -C "$SP_SUB/projects/alpha" worktree add --quiet --detach "$SP_DIR/child-worktree" \
    || fail "could not stage a child worktree of the compartment home's project"
  # One valid child request landed for this compartment.
  mkdir -p "$SP_DIR/childreq" "$SP_DIR/inbox"
  python3 - "$SP_DIR/childreq" "$parent" "$parent_generation" "$assignment" <<'PY'
import hashlib, json, pathlib, sys
childreq, task, generation, assignment = sys.argv[1:]

def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()

payload = {
    "kind": "fm.secondmate-child-request/v1",
    "parent_task": task, "parent_task_generation": generation,
    "parent_assignment_generation": assignment,
    "child_kind": "scout", "brief": "read the alpha project and report",
}
message = dict(payload)
message["self_digest"] = hashlib.sha256(canonical(payload)).hexdigest()
message["sequence"] = 1
message["content_sha256"] = "e" * 64
message["chain_digest"] = "f" * 64
body = canonical(message)
(pathlib.Path(childreq) / "00000001-{}.json".format(hashlib.sha256(body).hexdigest())).write_bytes(body)
PY
  out=$(perl -e 'alarm 600; exec @ARGV or die "exec failed: $!"' -- \
    env PATH="$SP_DIR/child-fake:$SP_FAKEBIN:$PATH" FM_ROOT_OVERRIDE="$SPAWN_PRIMARY_ROOT" \
    FM_FAKE_TMUX_LOG="$SP_TMUX_LOG" FM_FAKE_TMUX_CAPTURE="$SP_PANE" \
    FM_BACKEND_HERDR_TEST_LAB=firstmate-herdr-test-lab-v1 \
    FM_HERDR_LOG="$SP_HERDR_LOG" FM_FAKE_HERDR_STATE="$SP_DIR/herdr-state.json" \
    FM_FAKE_TREEHOUSE_WORKTREE="$SP_DIR/child-worktree" \
    FM_FAKE_PANE_PATH="$SP_DIR/child-worktree" \
    FM_HOME="$SP_HOME" \
    FM_TREEHOUSE_ROOT="$SP_HOME/treehouse-pools" \
    FM_CHECKOUT_REFRESH_STATE_BASE="$SP_DIR/checkout-refresh-state" \
    PI_CODING_AGENT_DIR="$SP_DIR/pi-agent-home" FM_SPAWN_NO_GUARD=1 \
    FM_AZURE_SUBSCRIPTION_ID="$SUB" FM_AZURE_DEPLOYMENT_GENERATION=dep-one \
    FM_AZURE_OWNER_TAG=owner FM_AZURE_NAMING_PREFIX=fmtest \
    FM_AZURE_WORKER_IDLE_COOLDOWN_SECONDS=0 \
    FM_WORKER_PROVIDER_COMMAND="python3 $SP_DIR/provider.py" \
    FIXTURE_STATE="$SP_DIR/provider-state.json" \
    python3 "$ROOT/bin/fm-secondmate-cloud-monitor.py" child-relay \
    --task "$parent" --task-generation "$parent_generation" \
    --assignment-generation "$assignment" \
    --childreq "$SP_DIR/childreq" --inbox "$SP_DIR/inbox" \
    --spawn-home "$SP_HOME" --home "$relay_home" \
    --controller "$controller" \
    --spawn-bin "$SPAWN" --lifecycle-bin "$ROOT/bin/fm-worker-lifecycle.sh" 2>&1)
  rc=$?
  expect_code 0 "$rc" "the relay pass over the real fm-spawn failed: $out"
  local delivered
  delivered=$(python3 - "$SP_DIR/inbox" <<'PY'
import json, pathlib, re, sys
inbox = pathlib.Path(sys.argv[1])
for path in sorted(p for p in inbox.iterdir() if re.fullmatch(r"[0-9]{8}-[0-9a-f]{64}\.json", p.name)):
    print(json.dumps(json.loads(path.read_bytes()), sort_keys=True))
PY
)
  # Gate 1, closed by this PR: the harness consultation backstop.
  assert_not_contains "$delivered" "crew-dispatch.json is active" \
    "the real fm-spawn refused the relay's argv at the harness consultation backstop: $delivered"
  # Gate 2, closed by this PR: the missing backlog row.
  assert_not_contains "$delivered" "has no In flight or Queued row" \
    "the real fm-spawn refused the relay's argv at the backlog-row gate: $delivered"
  # Gate 3, closed by the task-home split: the request is SECONDMATE-owned,
  # so the parent pair is accepted and the child bounds apply to it.
  assert_not_contains "$delivered" "parent_task is owned by secondmate-owned author requests only" \
    "the compartment child lane still mints a primary-owned request: $delivered"
  assert_not_contains "$delivered" "FIRSTMATE REFUSED your request" \
    "the compartment child lane refused instead of admitting: $delivered"
  assert_contains "$delivered" "FIRSTMATE ACCEPTED your" \
    "the admitted child was never acknowledged into the compartment inbox: $delivered"
  [ -z "$(first_matching "$SP_DIR/childreq" '.refused-*.json')" ] \
    || fail "an admitted child also left a durable refusal record"
  [ -n "$(first_matching "$SP_DIR/childreq" '.accepted-*.json')" ] \
    || fail "an admitted child left no durable acceptance record"
  # THE MONEY DOCUMENT IS THE PROOF, not the exit code: exactly one child
  # entry under this compartment's parent pair, secondmate-owned, bound to
  # the COMPARTMENT's home inside the PRIMARY's document, with the parent's
  # lifetime child count incremented and no second document anywhere.
  assert_absent "$SP_SUB/state/azure-workers/controller.json" \
    "the compartment child lane created a SECOND controller document under the compartment home"
  child_task=$(python3 - "$controller" "$parent" "$parent_generation" "$SP_SUB" "$SP_HOME" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

controller, parent, generation, sub, primary = sys.argv[1:]
state = json.load(open(controller))
children = [
    item for item in state["queue"].values()
    if item.get("parent_task") == parent and item.get("parent_task_generation") == generation
]
assert len(children) == 1, children
child = children[0]
assert child["owner_kind"] == "secondmate", child
assert child["role"] == "author", child
sub_binding = hashlib.sha256(str(Path(sub).resolve()).encode()).hexdigest()
primary_binding = hashlib.sha256(str(Path(primary).resolve()).encode()).hexdigest()
assert child["home_binding"] == sub_binding, (child["home_binding"], sub_binding)
assert child.get("task_home") == str(Path(sub).resolve()), child
assert state["home_binding"] == primary_binding, (state["home_binding"], primary_binding)
parent_item = state["queue"]["{}@{}".format(parent, generation)]
worker = state["workers"][str(parent_item["slot"])]
assert int(worker.get("children_total", 0)) == 1, worker
print(child["task"])
PY
) || fail "the admitted child is not a bounded, compartment-bound entry in the primary's one document"
  [ -n "$child_task" ] || fail "the admitted child's task id could not be read back"
  # THE TASK HOME IS CONSUMED ONCE, NEVER PERSISTED. <id>.cloud-env is
  # re-sourced by every LATER execute and release for this id, so a name that
  # landed there would permanently pair a foreign home with all of them
  # instead of with this one request - the durable trap spawn_environment
  # names. The durable record of the split is the queue item's own task_home
  # field, asserted above, which the release lane reads back.
  assert_present "$SP_SUB/state/$child_task.cloud-env" \
    "the admitted child persisted no cloud environment at all"
  assert_no_grep 'FM_SPAWN_TASK_HOME' "$SP_SUB/state/$child_task.cloud-env" \
    "FM_SPAWN_TASK_HOME was persisted into the child's durable cloud environment, where it becomes a durable trap"
  pass "through the REAL fm-spawn the relay admits a compartment child into the primary's ONE money document, secondmate-owned and bound to the compartment's home, under the child bounds, with the task home consumed once and never persisted"
}

test_crewmate_monitor_reclaims_a_stale_dispatch_marker() {
  # BEHAVIORAL coverage of the fixed branch (Darwin here): a stale dispatch
  # claim with no result must actually be reclaimed. If the mtime read yields
  # anything non-numeric the guard returns early and NOTHING is reclaimed,
  # which is exactly the bug the uname branch fixes.
  local dir state marker log pid
  dir="$TMP_ROOT/crewmate-reclaim"
  state="$dir/home/state"
  mkdir -p "$state/azure-workers"
  marker="$state/reclaim-task.cloud-execute-dispatched"
  log="$dir/monitor.log"
  python3 - "$state/azure-workers/controller.json" reclaim-task gen-1 <<'PY'
import json, sys
path, task, generation = sys.argv[1:]
state = {"queue": {"{}@{}".format(task, generation): {
    "task": task, "task_generation": generation, "status": "assigned",
    "assignment_generation": "asg-00000001", "slot": 1}}, "workers": {}}
json.dump(state, open(path, "w"))
PY
  printf 'export FM_SPAWN_CLOUD_WALL_SECONDS=60\n' > "$state/reclaim-task.cloud-env"
  # An EMPTY entrypoint: the dispatch that follows a successful reclaim stands
  # down loudly instead of driving a real execute, so the reclaim is what the
  # log proves.
  : > "$state/reclaim-task.cloud-entrypoint"
  : > "$marker"
  python3 - "$marker" <<'PY'
import os, sys, time
stale = time.time() - 4000  # far past wall(60) + 300 slack
os.utime(sys.argv[1], (stale, stale))
PY
  perl -e "$MONITOR_PERL" -- 60 \
    env FM_HOME="$dir/home" FM_SPAWN_CLOUD_MONITOR_INTERVAL_SECONDS=1 \
    "$ROOT/bin/fm-spawn-cloud-monitor.sh" reclaim-task gen-1 > "$log" 2>&1 &
  pid=$!
  wait_for_file_grep "$log" 'dispatch claim is stale' 40 \
    || { stop_process_group "$pid"; fail "the stale dispatch claim was never reclaimed (the mtime read failed closed): $(cat "$log")"; }
  stop_process_group "$pid"
  assert_grep 'persisted entrypoint is empty' "$log" \
    "the reclaim did not release the claim for the next dispatch attempt"
  pass "the crewmate monitor really reclaims a stale dispatch claim through the uname-branched mtime read"
}

wait_for_file_grep() {  # <file> <pattern> <iterations>
  local file=$1 pattern=$2 limit=$3 i=0
  while [ "$i" -lt "$limit" ]; do
    grep -q "$pattern" "$file" 2>/dev/null && return 0
    sleep 0.25
    i=$((i + 1))
  done
  return 1
}

test_crewmate_monitor_stat_chain_is_uname_branched() {
  # The flagged latent bug: GNU stat ACCEPTS `-f %m` (it names a filesystem
  # there), so a BSD-first `stat -f %m || stat -c %Y` chain never reaches the
  # GNU form on Linux and yields non-numeric output, disabling the crewmate
  # reclaim staleness guard on exactly the platform the workers run.
  local monitor="$ROOT/bin/fm-spawn-cloud-monitor.sh"
  assert_no_grep 'stat -f %m .* || stat -c %Y' "$monitor" \
    "the crewmate monitor still carries the BSD-first stat fallback chain"
  # shellcheck disable=SC2016  # the literal shell text is the pin, not an expansion
  grep -q 'if \[ "$(uname)" = Darwin \]; then' "$monitor" \
    || fail "the crewmate monitor does not branch its mtime read on uname like bin/fm-lock-lib.sh"
  python3 - "$monitor" <<'PY' || fail "the uname branch does not guard the reclaim marker read"
import re, sys
body = open(sys.argv[1], encoding="utf-8").read()
block = re.search(r'if \[ "\$\(uname\)" = Darwin \]; then(.*?)\n\s*fi\n', body, re.S)
assert block, "no uname branch found"
inner = block.group(1)
assert 'stat -f %m "$DISPATCH_MARKER"' in inner, inner
assert 'stat -c %Y "$DISPATCH_MARKER"' in inner, inner
PY
  pass "the crewmate monitor reads its reclaim marker mtime through the uname-branched idiom"
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
  # MORE THAN ONE ACCOUNT, deliberately. This lane places a compartment AND a
  # child of that compartment, and a placement now leases one upstream account
  # exclusively. Against a single-account pool the child refuses as exhausted -
  # which is the invariant working, not a regression - so a one-profile fixture
  # here could only ever have passed while that invariant was unenforced.
  fm_secondmate_write_pi_pool "$SP_DIR/pi-agent-home/auth.json" 3
  fm_git_init_commit "$SP_HOME/projects/alpha"
  fm_git_add_origin "$SP_HOME/projects/alpha" "$SP_DIR/remotes/alpha.git"
  # Pin the project to direct-PR so the seed preserves its delivery policy.
  printf -- '- alpha [direct-PR] - alpha project (added 2026-06-22)\n' > "$SP_HOME/data/projects.md"
  SP_FAKEBIN=$(make_fake_tmux "$SP_DIR/fake")
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
  # EFFECT-shaped, not syntax-shaped: run the REAL lifecycle validator over the
  # REAL directory the REAL fm-spawn.sh just produced. The assertions above name
  # files they expect to be present; this one bounds what may be present at all,
  # so a producer that stages an unadmitted file goes red here no matter HOW the
  # staging was spelled (literal name, shell variable, trailing-slash cp). That
  # distinction matters: the defect this closes was a producer and a validator
  # drifting apart, and a guard that recognizes only today's syntax is the same
  # class of weakness as the defect.
  python3 - "$SP_HOME/state/helm.cloud-payload" "$ROOT/bin/fm-worker-lifecycle.py" \
    <<'PY' || fail "the staged compartment payload is not admitted by the reviewed set"
import importlib.util
import sys
from pathlib import Path

payload = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("lifecycle", sys.argv[2])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
bounds, required = module.payload_contract("secondmate")

# Deliberately NOT filtering dotfiles, though staged_directory_manifest skips
# them: nothing should ever put a dotfile here, so this is stricter than the
# validator on purpose and a stray one goes red instead of travelling unseen.
staged = sorted(entry.name for entry in payload.iterdir())
unadmitted = [name for name in staged if name not in bounds]
assert not unadmitted, (
    "fm-spawn.sh staged {} into the compartment payload, which the reviewed set "
    "does not admit; every leg dispatch would refuse. Staged: {}".format(
        unadmitted, staged))

# The validator itself is the authority, so this cannot drift from what the
# controller enforces at dispatch: it bounds bytes and requires the pair too.
manifest = module.staged_directory_manifest(
    "payload", payload, bounds=bounds, required=required)
assert sorted(manifest) == staged, (sorted(manifest), staged)
PY
  assert_present "$SP_HOME/state/helm.cloud-account/auth.json" "account staging lacks the auth projection"
  # Durable leg config rode into the persisted compartment environment.
  assert_grep 'FM_SECONDMATE_LEG_SECONDS=7200' "$SP_HOME/state/helm.cloud-env" "leg config was not persisted for the monitor"
  # The tracking pane runs the COMPARTMENT monitor, not the crewmate one.
  assert_grep 'fm-secondmate-cloud-monitor.sh' "$SP_HERDR_LOG" "the pane does not run the compartment monitor"
  assert_no_grep 'fm-spawn-cloud-monitor.sh' "$SP_HERDR_LOG" "the pane runs the crewmate monitor instead of the compartment one"
  pass "on-flag: --secondmate routes through role=secondmate request + monitor launch, with no spawn-side execute"
}

test_azure_only_policy_routes_secondmate_without_transition_flag() {
  local out rc meta
  setup_spawn_world azure-only-policy compass
  mkdir -p "$SP_HOME/config"
  printf 'azure-only\n' > "$SP_HOME/config/spawn-cloud"
  out=$(run_gate_spawn compass \
    FM_AZURE_SUBSCRIPTION_ID="$SUB" FM_AZURE_DEPLOYMENT_GENERATION=dep-one \
    FM_AZURE_OWNER_TAG=owner FM_AZURE_NAMING_PREFIX=fmtest \
    FM_AZURE_WORKER_IDLE_COOLDOWN_SECONDS=0 \
    FM_SECONDMATE_LEG_SECONDS=7200 \
    FM_WORKER_PROVIDER_COMMAND="python3 $SP_DIR/provider.py" \
    FIXTURE_STATE="$SP_DIR/provider-state.json" \
    -- --secondmate)
  rc=$?
  expect_code 0 "$rc" "azure-only secondmate should enter the compartment without the transition flag: $out"
  assert_contains "$out" "placement=azure" \
    "azure-only secondmate did not report Azure placement: $out"
  assert_not_contains "$out" "$GATE_NOTICE" \
    "azure-only secondmate fell through the optional-cloud local gate: $out"
  meta="$SP_HOME/state/compass.meta"
  assert_grep 'kind=secondmate' "$meta" "azure-only secondmate meta lost its kind"
  assert_grep 'placement=azure' "$meta" "azure-only secondmate meta lost its placement"
  assert_grep 'harness=pi' "$meta" "azure-only secondmate did not use the pi-codex runtime"
  assert_grep 'fm-secondmate-cloud-monitor.sh' "$SP_HERDR_LOG" \
    "azure-only secondmate did not launch its local non-agent compartment monitor"
  [ ! -s "$SP_TMUX_LOG" ] || fail "azure-only secondmate launched a local agent process: $(cat "$SP_TMUX_LOG")"
  [ "$(cat "$SP_SUB/config/spawn-cloud" 2>/dev/null)" = azure-only ] \
    || fail "azure-only placement policy was not inherited into the secondmate home"
  python3 - "$SP_HOME/state/azure-workers/controller.json" compass <<'PY' \
    || fail "azure-only secondmate was not admitted as a compartment"
import json
import sys
state = json.load(open(sys.argv[1], encoding="utf-8"))
items = [item for key, item in state["queue"].items() if key.startswith(sys.argv[2] + "@")]
assert len(items) == 1, items
assert items[0]["role"] == "secondmate", items[0]
assert items[0]["status"] == "assigned", items[0]
PY
  pass "azure-only routes secondmate agent sessions through the Azure compartment while home and monitor stay local"
}

test_azure_only_policy_refuses_secondmate_local_opt_out_before_mutation() {
  local out rc
  setup_spawn_world azure-only-opt-out sextant
  mkdir -p "$SP_HOME/config"
  printf 'azure-only\n' > "$SP_HOME/config/spawn-cloud"
  out=$(run_gate_spawn sextant FM_SPAWN_SECONDMATE_CLOUD=off -- --secondmate)
  rc=$?
  expect_code 1 "$rc" "azure-only secondmate must refuse a local compartment opt-out: $out"
  assert_contains "$out" "refuses FM_SPAWN_SECONDMATE_CLOUD='off'" \
    "secondmate opt-out refusal did not name the policy conflict: $out"
  assert_absent "$SP_HOME/state/sextant.meta" "the refused secondmate opt-out wrote metadata"
  assert_absent "$SP_HOME/state/azure-workers/controller.json" \
    "the refused secondmate opt-out requested cloud capacity"
  [ ! -s "$SP_HERDR_LOG" ] || fail "the refused secondmate opt-out created a tracking endpoint"
  [ ! -s "$SP_TMUX_LOG" ] || fail "the refused secondmate opt-out created a local agent endpoint"
  pass "azure-only refuses a secondmate local opt-out before endpoint or capacity mutation"
}

test_spawn_forwards_the_parent_pair_into_the_request() {
  local out rc
  setup_spawn_world parent-pair keel
  # The passthrough is proven by the CONTROLLER seeing it: a compartment
  # request (role=secondmate) that also carries a parent pair is refused by
  # verify_request naming parent_task, which can only happen if fm-spawn
  # forwarded --parent-task/--parent-task-generation into the request argv.
  out=$(run_gate_spawn keel \
    FM_SPAWN_CLOUD=azure FM_SPAWN_SECONDMATE_CLOUD=1 \
    FM_SPAWN_PARENT_TASK=someparent FM_SPAWN_PARENT_TASK_GENERATION=somegen \
    FM_AZURE_SUBSCRIPTION_ID="$SUB" FM_AZURE_DEPLOYMENT_GENERATION=dep-one \
    FM_AZURE_OWNER_TAG=owner FM_AZURE_NAMING_PREFIX=fmtest \
    FM_AZURE_WORKER_IDLE_COOLDOWN_SECONDS=0 \
    FM_WORKER_PROVIDER_COMMAND="python3 $SP_DIR/provider.py" \
    FIXTURE_STATE="$SP_DIR/provider-state.json" \
    -- --secondmate)
  rc=$?
  [ "$rc" -ne 0 ] || fail "a compartment request carrying a parent pair must refuse: $out"
  assert_contains "$out" "parent_task is owned by secondmate-owned author requests only" \
    "the forwarded parent pair never reached verify_request: $out"
  assert_absent "$SP_HOME/state/azure-workers/controller.json" \
    "a refused parent-paired request still wrote a queue document"
  pass "fm-spawn forwards FM_SPAWN_PARENT_TASK/_GENERATION into the lifecycle request argv"
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
test_verified_advance_records_the_tip_with_the_exact_argv
test_recorded_tip_equals_what_the_local_verifier_proved
test_unchanged_tip_is_not_re_recorded_and_an_advance_is
test_refused_chain_verification_records_no_tip
test_monotonicity_refusal_freezes_the_lane_like_a_chain_break
test_already_released_refusal_closes_the_tip_lane_benignly
test_ownership_refusal_warns_backs_off_and_retries_without_freezing
test_released_worker_holding_a_contradicting_tip_still_freezes
test_released_worker_holding_a_below_tip_fork_still_freezes
test_released_worker_with_no_contradicting_tip_closes_benignly
test_unreadable_controller_never_closes_the_tip_lane
test_monitor_pass_records_the_tip_end_to_end
test_chain_tip_argv_is_accepted_by_the_real_lifecycle_cli
test_fm_send_routes_cloud_secondmate_into_the_compartment_inbox
test_fm_send_prefers_controller_current_assignment
test_fm_send_local_secondmate_path_is_unchanged
test_fm_send_cloud_secondmate_without_assignment_refuses
test_spawn_gate_off_flag_is_byte_identical
test_spawn_gate_on_flag_routes_compartment_and_never_executes
test_azure_only_policy_routes_secondmate_without_transition_flag
test_azure_only_policy_refuses_secondmate_local_opt_out_before_mutation
test_spawn_forwards_the_parent_pair_into_the_request
test_valid_child_request_spawns_with_the_exact_parent_pair
test_invalid_child_requests_refuse_by_name_and_never_reach_the_request
test_non_string_optional_field_refuses_and_the_pass_continues
test_leading_dash_brief_refuses
test_spawn_exit_zero_without_admission_refuses
test_duplicate_child_request_refuses_loudly_and_spawns_once
test_admission_refusal_round_trips_into_the_inbox
test_attach_announcement_matches_the_uploaded_bundle
test_size_mismatched_announcement_is_never_sent
test_attach_sequence_allows_repeat_asks_and_refuses_non_monotone
test_empty_delta_burns_no_attach_sequence
test_child_terminal_status_mirrors_once
test_child_request_queue_item_bindings_equal_local_mints
test_child_request_through_the_real_fm_spawn_with_crew_dispatch
test_crewmate_monitor_reclaims_a_stale_dispatch_marker
test_crewmate_monitor_stat_chain_is_uname_branched

echo "# fm-secondmate-cloud-monitor.test.sh: all assertions passed"
