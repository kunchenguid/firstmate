#!/usr/bin/env bash
# shellcheck source=tests/test-entry.sh
. "$(dirname "$0")/test-entry.sh"
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Hermetic coverage for the secondmate compartment session runner (R2/R3
# design section C item 2). Every unit drives the REAL runner binary against
# a fixture blob directory (the transport's dir backend) and a fixture pi;
# nothing inside the runner is mocked. Canonical emitted bytes are asserted
# byte-exact, the outbox chain is recomputed independently, and the
# chain-tamper case must REFUSE, never skip.

RUNNER="$ROOT/bin/fm-secondmate-session.py"
EXTENSION="$ROOT/bin/fm-secondmate-spawn.pi-ext.ts"

# Globals set by fixture(): TMP BLOB STATE_DIR REPO ORIGIN BASE FAKE_PI TURN_LOG
TMP='' BLOB='' STATE_DIR='' REPO='' ORIGIN='' BASE='' FAKE_PI='' TURN_LOG=''

fixture() {
  fm_test_tmproot_into TMP fm-secondmate-session
  BLOB="$TMP/blob"
  STATE_DIR="$TMP/state"
  ORIGIN="$TMP/origin"
  REPO="$TMP/repo"
  TURN_LOG="$TMP/turns.log"
  mkdir -p "$BLOB"
  : > "$TURN_LOG"
  fm_git_init_commit "$ORIGIN"
  git clone --quiet "$ORIGIN" "$REPO"
  BASE=$(git -C "$REPO" rev-parse HEAD)
  FAKE_PI="$TMP/fake-pi"
  cat > "$FAKE_PI" <<'SH'
#!/usr/bin/env bash
# Fixture pi: records each invocation's argv, then behaves per FM_FAKE_PI_MODE.
set -u
printf '%s\n' "$*" >> "$FM_FAKE_PI_LOG"
if [ -n "${FM_FAKE_PI_ENVDUMP:-}" ]; then
  printf '%s\n' "${PI_CODING_AGENT_DIR:-UNSET}" >> "$FM_FAKE_PI_ENVDUMP"
fi
last=
for arg in "$@"; do last=$arg; done
case "${FM_FAKE_PI_MODE:-reply}" in
  reply)
    printf 'canned-reply:%s' "$last"
    ;;
  commit)
    echo turn >> turn.txt
    git add turn.txt
    git -c user.name='Fixture Pi' -c user.email='pi@example.invalid' commit -qm 'fixture turn'
    printf 'committed'
    ;;
  intent)
    for intent in "$FM_FAKE_PI_INTENT_SRC"/*.json; do
      cp "$intent" "$FM_SECONDMATE_SPOOL_DIR/"
    done
    printf 'intents-spooled'
    ;;
esac
SH
  chmod +x "$FAKE_PI"
}

# run_leg [VAR=value ...] - run one real leg with the fixture wiring plus any
# per-call overrides, under a hard alarm so a wedged loop fails instead of
# hanging the suite.
run_leg() {
  perl -e 'alarm 120; exec @ARGV or die "exec failed: $!"' -- \
    env FM_WORKER_TASK=smc-task FM_WORKER_TASK_GENERATION=gen-one \
    FM_WORKER_ASSIGNMENT_GENERATION=asg-00000001 \
    FM_WORKER_REPOSITORY_GENERATION="$BASE" \
    FM_SECONDMATE_BLOB_DIR="$BLOB" FM_SECONDMATE_STATE_DIR="$STATE_DIR" \
    FM_SECONDMATE_REPO_DIR="$REPO" FM_SECONDMATE_PI_BIN="$FAKE_PI" \
    FM_FAKE_PI_LOG="$TURN_LOG" \
    "$@" python3 "$RUNNER"
}

# put_inbox '<json>' - canonicalize, content-address, and store one inbox
# message the way the monitor's message-put will; prints the digest.
put_inbox() {
  python3 - "$BLOB" "$1" <<'PY'
import hashlib, json, pathlib, sys
blob, raw = sys.argv[1:]
body = json.dumps(json.loads(raw), sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
digest = hashlib.sha256(body).hexdigest()
target = pathlib.Path(blob) / "session" / "in" / (digest + ".json")
target.parent.mkdir(parents=True, exist_ok=True)
target.write_bytes(body)
print(digest)
PY
}

# verify_chain - independently recompute the whole outbox chain from the
# fixture store and the durable tip; fails on any divergence.
verify_chain() {
  python3 - "$BLOB" "$STATE_DIR" <<'PY' || fail "outbox chain recompute failed"
import hashlib, json, pathlib, re, sys
blob, state = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
name_re = re.compile(r"^([0-9]{8})-([0-9a-f]{64})\.json$")
entries = {}
for path in (blob / "session" / "out").iterdir():
    match = name_re.fullmatch(path.name)
    if not match:
        continue
    entries[int(match.group(1))] = (match.group(2), path.read_bytes())
assert sorted(entries) == list(range(1, len(entries) + 1)), sorted(entries)
chain = "0" * 64
for sequence in range(1, len(entries) + 1):
    named_digest, body = entries[sequence]
    message = json.loads(body.decode("utf-8"))
    unsigned = dict(message)
    content_digest = unsigned.pop("content_sha256")
    chain_field = unsigned.pop("chain_digest")
    canonical = json.dumps(unsigned, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
    assert hashlib.sha256(canonical).hexdigest() == content_digest == named_digest, sequence
    assert message["sequence"] == sequence, message
    chain = hashlib.sha256((chain + content_digest).encode()).hexdigest()
    assert chain_field == chain, sequence
durable = json.loads((state / "outbox-chain.json").read_text())
assert durable == {"sequence": len(entries), "chain_digest": chain}, durable
PY
}

happy_leg_canonical_bytes() {
  fixture
  put_inbox '{"kind":"fm.secondmate-message/v1","text":"hello there"}' >/dev/null
  put_inbox '{"kind":"fm.secondmate-control/v1","action":"close"}' >/dev/null
  run_leg >/dev/null 2>&1 || fail "happy leg did not exit cleanly"
  # The emitted reply blob must be byte-exact canonical JSON, chain fields
  # included, and its name must be the content address of the unsigned form.
  python3 - "$BLOB" <<'PY' || fail "reply blob bytes are not canonical-exact"
import hashlib, json, pathlib, sys
blob = pathlib.Path(sys.argv[1])
unsigned = {
    "agent_exit_code": 0,
    "kind": "fm.secondmate-message/v1",
    "sequence": 1,
    "text": "canned-reply:hello there",
    "text_truncated": False,
}
canonical = json.dumps(unsigned, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
content = hashlib.sha256(canonical).hexdigest()
chain = hashlib.sha256(("0" * 64 + content).encode()).hexdigest()
final = dict(unsigned)
final["content_sha256"] = content
final["chain_digest"] = chain
expected = json.dumps(final, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
path = blob / "session" / "out" / ("00000001-" + content + ".json")
assert path.is_file(), sorted(p.name for p in (blob / "session" / "out").iterdir())
assert path.read_bytes() == expected, path.read_bytes()
PY
  # The final act of the leg is the summary: reason=close, no bundles.
  python3 - "$BLOB" <<'PY' || fail "leg summary is not exact"
import json, pathlib, sys
blob = pathlib.Path(sys.argv[1])
summary = None
for path in sorted((blob / "session" / "out").iterdir()):
    if path.name.startswith("00000002-"):
        summary = json.loads(path.read_text())
assert summary is not None
assert summary["kind"] == "fm.secondmate-leg-summary/v1", summary
assert summary["reason"] == "close" and summary["bundles"] == [], summary
assert summary["legs_completed"] == 1, summary
PY
  verify_chain
  test "$(wc -l < "$TURN_LOG" | tr -d ' ')" = 1 || fail "expected exactly one pi turn"
  pass "a full leg emits byte-exact chained reply and close summary from one real pi turn"
}

chain_continues_across_legs() {
  fixture
  put_inbox '{"kind":"fm.secondmate-message/v1","text":"first"}' >/dev/null
  put_inbox '{"kind":"fm.secondmate-control/v1","action":"close","nonce":"leg-1"}' >/dev/null
  run_leg >/dev/null 2>&1 || fail "leg 1 did not exit cleanly"
  put_inbox '{"kind":"fm.secondmate-message/v1","text":"second"}' >/dev/null
  put_inbox '{"kind":"fm.secondmate-control/v1","action":"close","nonce":"leg-2"}' >/dev/null
  run_leg >/dev/null 2>&1 || fail "leg 2 did not exit cleanly"
  # Sequence and chain continue 1..4 across the process boundary; the second
  # leg resumed the SAME persisted pi session id.
  python3 - "$BLOB" "$TURN_LOG" <<'PY' || fail "chain or session continuity broke across legs"
import json, pathlib, sys
blob, log = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
names = sorted(p.name for p in (blob / "session" / "out").iterdir())
assert [n[:9] for n in names] == ["00000001-", "00000002-", "00000003-", "00000004-"], names
summaries = [json.loads((blob / "session" / "out" / n).read_text()) for n in names]
assert summaries[1]["legs_completed"] == 1 and summaries[3]["legs_completed"] == 2, names
sessions = set()
for line in log.read_text().splitlines():
    argv = line.split()
    sessions.add(argv[argv.index("--session-id") + 1])
assert len(sessions) == 1, sessions
PY
  verify_chain
  pass "sequence, chain digest, and pi session id continue across runner restarts"
}

chain_tamper_refuses() {
  fixture
  put_inbox '{"kind":"fm.secondmate-message/v1","text":"first"}' >/dev/null
  put_inbox '{"kind":"fm.secondmate-control/v1","action":"close"}' >/dev/null
  run_leg >/dev/null 2>&1 || fail "setup leg did not exit cleanly"
  rm "$BLOB"/session/out/00000001-*.json
  local rc=0 err
  err=$(run_leg FM_SECONDMATE_IDLE_SECONDS=1 2>&1 >/dev/null) || rc=$?
  expect_code 2 "$rc" "tampered outbox must refuse"
  assert_contains "$err" "SECONDMATE SESSION REFUSED: outbox chain is broken" \
    "tamper refusal must name the broken chain"
  # Refused means refused: the tampered store gained no new outbox entry.
  test "$(find "$BLOB/session/out" -name '0*.json' | wc -l | tr -d ' ')" = 1 \
    || fail "a refused leg must not emit into a tampered outbox"
  pass "a dropped outbox blob refuses the leg loudly instead of skipping or renumbering"
}

idle_exit_emits_summary() {
  fixture
  run_leg FM_SECONDMATE_IDLE_SECONDS=1 >/dev/null 2>&1 || fail "idle leg did not exit cleanly"
  python3 - "$BLOB" <<'PY' || fail "idle summary is not exact"
import json, pathlib, sys
blob = pathlib.Path(sys.argv[1])
names = sorted(p.name for p in (blob / "session" / "out").iterdir())
assert len(names) == 1 and names[0].startswith("00000001-"), names
summary = json.loads((blob / "session" / "out" / names[0]).read_text())
assert summary["kind"] == "fm.secondmate-leg-summary/v1" and summary["reason"] == "idle", summary
PY
  pass "an idle leg exits 0 with a reason=idle summary"
}

close_control_exits() {
  fixture
  put_inbox '{"kind":"fm.secondmate-control/v1","action":"close"}' >/dev/null
  run_leg >/dev/null 2>&1 || fail "close leg did not exit cleanly"
  python3 - "$BLOB" <<'PY' || fail "close summary is not exact"
import json, pathlib, sys
blob = pathlib.Path(sys.argv[1])
names = sorted(p.name for p in (blob / "session" / "out").iterdir())
assert len(names) == 1, names
summary = json.loads((blob / "session" / "out" / names[0]).read_text())
assert summary["reason"] == "close" and summary["legs_completed"] == 1, summary
PY
  test "$(wc -l < "$TURN_LOG" | tr -d ' ')" = 0 || fail "close alone must not run a pi turn"
  pass "a close control message ends the leg with reason=close and no agent turn"
}

wall_exit_before_hard_timeout() {
  fixture
  run_leg FM_SECONDMATE_LEG_SECONDS=6 >/dev/null 2>&1 || fail "wall leg did not exit cleanly"
  python3 - "$BLOB" <<'PY' || fail "wall summary is not exact"
import json, pathlib, sys
blob = pathlib.Path(sys.argv[1])
names = sorted(p.name for p in (blob / "session" / "out").iterdir())
assert len(names) == 1, names
summary = json.loads((blob / "session" / "out" / names[0]).read_text())
assert summary["reason"] == "wall", summary
PY
  # A leg above the pinned supervisor's wall ceiling refuses at configuration.
  local rc=0 err
  err=$(run_leg FM_SECONDMATE_LEG_SECONDS=21601 2>&1 >/dev/null) || rc=$?
  expect_code 2 "$rc" "over-ceiling leg seconds must refuse"
  assert_contains "$err" "leg seconds must be at most 21600" \
    "over-ceiling refusal must name the supervisor wall ceiling"
  pass "an expiring leg exits 0 with a reason=wall summary before the hard timeout"
}

agent_dir_reaches_every_turn() {
  fixture
  put_inbox '{"kind":"fm.secondmate-message/v1","text":"who am i"}' >/dev/null
  put_inbox '{"kind":"fm.secondmate-control/v1","action":"close"}' >/dev/null
  # Default: the staged auth projection path, exactly as fm-spawn's cloud
  # launch line and the D.1 gate set it.
  run_leg FM_FAKE_PI_ENVDUMP="$TMP/envdump" >/dev/null 2>&1 \
    || fail "agent-dir default leg did not exit cleanly"
  test "$(cat "$TMP/envdump")" = "/mnt/account/pi-agent" \
    || fail "pi did not observe the default PI_CODING_AGENT_DIR: $(cat "$TMP/envdump")"
  # Override: the hermetic/agent-relocation lane.
  put_inbox '{"kind":"fm.secondmate-message/v1","text":"who am i now"}' >/dev/null
  put_inbox '{"kind":"fm.secondmate-control/v1","action":"close","nonce":"leg-2"}' >/dev/null
  run_leg FM_FAKE_PI_ENVDUMP="$TMP/envdump2" FM_SECONDMATE_AGENT_DIR="$TMP/custom-agent" \
    >/dev/null 2>&1 || fail "agent-dir override leg did not exit cleanly"
  test "$(cat "$TMP/envdump2")" = "$TMP/custom-agent" \
    || fail "pi did not observe the overridden PI_CODING_AGENT_DIR: $(cat "$TMP/envdump2")"
  pass "every pi turn runs with PI_CODING_AGENT_DIR bound to the configured agent dir"
}

leading_dash_text_refused() {
  fixture
  # pi 0.84.1 rejects a '--' end-of-options separator (probed: "Unknown
  # options: --, ..."), so text that could parse as a pi flag must refuse
  # loudly and never reach the agent argv.
  put_inbox '{"kind":"fm.secondmate-message/v1","text":"--exclude-tools"}' >/dev/null
  put_inbox '{"kind":"fm.secondmate-message/v1","text":"a safe message"}' >/dev/null
  put_inbox '{"kind":"fm.secondmate-control/v1","action":"close"}' >/dev/null
  run_leg >/dev/null 2>&1 || fail "dash-refusal leg did not exit cleanly"
  test "$(wc -l < "$TURN_LOG" | tr -d ' ')" = 1 || fail "expected exactly one pi turn"
  assert_no_grep "--exclude-tools" "$TURN_LOG" "dash text must never reach the pi argv"
  python3 - "$BLOB" <<'PY' || fail "dash refusal message missing"
import json, pathlib, sys
blob = pathlib.Path(sys.argv[1])
checks = []
for path in sorted((blob / "session" / "out").iterdir()):
    message = json.loads(path.read_text())
    if message["kind"] == "fm.secondmate-refusal/v1":
        checks.append(message["check"])
assert any("begins with '-' and cannot ride the pi argv" in check for check in checks), checks
PY
  pass "leading-dash message text refuses loudly and never reaches the pi argv"
}

wall_defers_unstarted_turn() {
  fixture
  local digest
  digest=$(put_inbox '{"kind":"fm.secondmate-message/v1","text":"too late"}')
  # leg=2 puts the deadline one second out: the message is listed but no
  # honest turn fits, so it must be DEFERRED (not marked processed), never
  # silently swallowed.
  run_leg FM_SECONDMATE_LEG_SECONDS=2 >/dev/null 2>&1 || fail "deferral leg did not exit cleanly"
  test "$(wc -l < "$TURN_LOG" | tr -d ' ')" = 0 || fail "a turn ran with no room before the wall"
  assert_absent "$STATE_DIR/processed/$digest" \
    "a deferred message must not enter the processed set"
  # The next leg with room replays the deferred message exactly once.
  put_inbox '{"kind":"fm.secondmate-control/v1","action":"close"}' >/dev/null
  run_leg >/dev/null 2>&1 || fail "replay leg did not exit cleanly"
  test "$(wc -l < "$TURN_LOG" | tr -d ' ')" = 1 || fail "the deferred message did not replay once"
  pass "a message with no room before the wall defers to the next leg instead of vanishing"
}

child_intent_round_trip() {
  fixture
  local intents="$TMP/intents"
  mkdir -p "$intents"
  printf '%s' '{"kind":"scout","brief":"probe the api","model":"frontier","effort":"high"}' \
    > "$intents/valid.json"
  put_inbox '{"kind":"fm.secondmate-message/v1","text":"spawn a scout"}' >/dev/null
  put_inbox '{"kind":"fm.secondmate-control/v1","action":"close"}' >/dev/null
  run_leg FM_FAKE_PI_MODE=intent FM_FAKE_PI_INTENT_SRC="$intents" >/dev/null 2>&1 \
    || fail "intent leg did not exit cleanly"
  python3 - "$BLOB" <<'PY' || fail "child request message is not exact"
import hashlib, json, pathlib, sys
blob = pathlib.Path(sys.argv[1])
requests = []
for path in sorted((blob / "session" / "out").iterdir()):
    if path.suffix != ".json":
        continue
    message = json.loads(path.read_text())
    if message["kind"] == "fm.secondmate-child-request/v1":
        requests.append(message)
assert len(requests) == 1, requests
request = requests[0]
assert request["parent_task"] == "smc-task", request
assert request["parent_task_generation"] == "gen-one", request
assert request["parent_assignment_generation"] == "asg-00000001", request
assert request["child_kind"] == "scout" and request["brief"] == "probe the api", request
assert request["child_model"] == "frontier" and request["child_effort"] == "high", request
# The self digest binds the canonical payload before chain framing.
unsigned = dict(request)
for framing in ("sequence", "content_sha256", "chain_digest"):
    unsigned.pop(framing)
supplied = unsigned.pop("self_digest")
canonical = json.dumps(unsigned, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
assert supplied == hashlib.sha256(canonical).hexdigest(), request
# The closed schema cannot express placement: no binding-shaped key exists.
for forbidden in ("home", "account", "worktree", "harness", "sku", "repository"):
    assert not any(forbidden in key for key in request), sorted(request)
PY
  test -z "$(find "$STATE_DIR/spool" -name '*.json' -print 2>/dev/null)" \
    || fail "an emitted intent must leave the spool"
  pass "a valid spool intent becomes one chained child-request with parent triple and self digest"
}

invalid_intent_refused_not_emitted() {
  fixture
  local intents="$TMP/intents"
  mkdir -p "$intents"
  printf '%s' '{"kind":"ship","brief":"fine","sku":"Standard_D4as_v7"}' > "$intents/unknown-key.json"
  printf '%s' '{"kind":"frigate","brief":"fine"}' > "$intents/bad-kind.json"
  # A brief at the 256KiB bound passes the intent schema but cannot fit the
  # framed outbox message: that refuses the one intent, not the leg.
  python3 - "$intents/oversize.json" <<'PY'
import json, sys
brief = "x" * (256 * 1024)
open(sys.argv[1], "w").write(json.dumps({"kind": "ship", "brief": brief}))
PY
  put_inbox '{"kind":"fm.secondmate-message/v1","text":"spawn things"}' >/dev/null
  put_inbox '{"kind":"fm.secondmate-control/v1","action":"close"}' >/dev/null
  run_leg FM_FAKE_PI_MODE=intent FM_FAKE_PI_INTENT_SRC="$intents" >/dev/null 2>&1 \
    || fail "invalid-intent leg did not exit cleanly"
  python3 - "$BLOB" <<'PY' || fail "invalid intents were not refused by name"
import json, pathlib, sys
blob = pathlib.Path(sys.argv[1])
kinds = []
checks = []
for path in sorted((blob / "session" / "out").iterdir()):
    if path.suffix != ".json":
        continue
    message = json.loads(path.read_text())
    kinds.append(message["kind"])
    if message["kind"] == "fm.secondmate-refusal/v1":
        checks.append(message["check"])
assert "fm.secondmate-child-request/v1" not in kinds, kinds
assert any("unknown key: sku" in check for check in checks), checks
assert any("kind must be ship or scout" in check for check in checks), checks
assert any("exceeds the outbox message cap" in check for check in checks), checks
PY
  pass "an invalid spool intent is refused naming the exact check and never emitted"
}

namespace_boundary_refuses() {
  fixture
  # Direct unit on the REAL transport class: the refusal lives inside the
  # transport, above the backend split, so no caller-supplied name escapes.
  # Probes run against their own store so the leg below starts clean.
  mkdir -p "$TMP/probe-blob"
  python3 - "$RUNNER" "$TMP/probe-blob" <<'PY' || fail "transport namespace boundary failed"
import importlib.util, sys
spec = importlib.util.spec_from_file_location("runner", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
transport = module.SessionTransport(module.DirBackend(sys.argv[2]))
transport.put("session/out/probe.json", b"{}")
assert transport.get("session/out/probe.json", 16) == b"{}"
assert [entry["name"] for entry in transport.list("session/out/")] == ["session/out/probe.json"]
for bad in (
    "outcome.bundle", "payload.tar.gz", "sessions/out/x.json", "session",
    "session/../request.json", "session//x.json", "/session/out/x.json",
):
    for operation in (
        lambda name: transport.put(name, b"x"),
        lambda name: transport.get(name, 16),
        lambda name: transport.list(name),
    ):
        try:
            operation(bad)
        except module.SessionError as exc:
            assert "outside the session/ namespace" in str(exc), (bad, exc)
        else:
            raise SystemExit("transport admitted a name outside session/: " + bad)
PY
  # And through a real runner code path: an attach announcement naming a blob
  # outside session/in/attach/ is refused as input, and the transport is
  # never asked for the foreign name.
  put_inbox '{"kind":"fm.secondmate-attach/v1","name":"payload.tar.gz","sha256":"'"$(printf 'x' | shasum -a 256 | awk '{print $1}')"'","bytes":1}' >/dev/null
  put_inbox '{"kind":"fm.secondmate-control/v1","action":"close"}' >/dev/null
  run_leg >/dev/null 2>&1 || fail "namespace leg did not exit cleanly"
  python3 - "$BLOB" <<'PY' || fail "attach namespace refusal missing"
import json, pathlib, sys
blob = pathlib.Path(sys.argv[1])
checks = []
for path in sorted((blob / "session" / "out").iterdir()):
    message = json.loads(path.read_text())
    if message["kind"] == "fm.secondmate-refusal/v1":
        checks.append(message["check"])
assert any("attach name is outside session/in/attach/" in check for check in checks), checks
PY
  pass "blob names outside session/ refuse in the transport and through the attach path"
}

processed_set_dedupes_replay() {
  fixture
  put_inbox '{"kind":"fm.secondmate-message/v1","text":"only once"}' >/dev/null
  put_inbox '{"kind":"fm.secondmate-control/v1","action":"close"}' >/dev/null
  run_leg >/dev/null 2>&1 || fail "dedupe leg 1 did not exit cleanly"
  test "$(wc -l < "$TURN_LOG" | tr -d ' ')" = 1 || fail "expected one pi turn in leg 1"
  # The identical content-addressed blobs are still in the store: replaying
  # the whole inbox in leg 2 must run zero additional turns.
  run_leg FM_SECONDMATE_IDLE_SECONDS=1 >/dev/null 2>&1 || fail "dedupe leg 2 did not exit cleanly"
  test "$(wc -l < "$TURN_LOG" | tr -d ' ')" = 1 || fail "a replayed inbox message re-ran a pi turn"
  verify_chain
  pass "a replayed content-addressed inbox message is a durable no-op"
}

commit_bundles_ride_home() {
  fixture
  put_inbox '{"kind":"fm.secondmate-message/v1","text":"do work"}' >/dev/null
  put_inbox '{"kind":"fm.secondmate-control/v1","action":"close"}' >/dev/null
  run_leg FM_FAKE_PI_MODE=commit >/dev/null 2>&1 || fail "bundling leg did not exit cleanly"
  local bundle
  bundle=$(find "$BLOB/session/out" -name 'bundle-*.bundle' | head -1)
  test -n "$bundle" || fail "no bundle blob was uploaded"
  python3 - "$BLOB" "$bundle" <<'PY' || fail "bundle declaration is not exact"
import hashlib, json, pathlib, sys
blob, bundle = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
body = bundle.read_bytes()
summary = None
for path in sorted((blob / "session" / "out").iterdir()):
    if path.suffix != ".json":
        continue
    message = json.loads(path.read_text())
    if message["kind"] == "fm.secondmate-leg-summary/v1":
        summary = message
assert summary is not None and len(summary["bundles"]) == 1, summary
declared = summary["bundles"][0]
assert declared["name"] == "session/out/" + bundle.name, declared
assert declared["sha256"] == hashlib.sha256(body).hexdigest(), declared
assert declared["bytes"] == len(body) and declared["commits"] == 1, declared
PY
  # The emitted bundle must verify against a repository at the dispatched base.
  git clone --quiet "$ORIGIN" "$TMP/verify"
  git -C "$TMP/verify" bundle verify "$bundle" >/dev/null 2>&1 \
    || fail "emitted bundle does not verify against the dispatched base"
  # Zero new commits on the next leg: declared as no bundle at all.
  put_inbox '{"kind":"fm.secondmate-message/v1","text":"read only"}' >/dev/null
  put_inbox '{"kind":"fm.secondmate-control/v1","action":"close","nonce":"leg-2"}' >/dev/null
  run_leg >/dev/null 2>&1 || fail "zero-commit leg did not exit cleanly"
  python3 - "$BLOB" <<'PY' || fail "zero-commit leg summary is not exact"
import json, pathlib, sys
blob = pathlib.Path(sys.argv[1])
summaries = []
for path in sorted((blob / "session" / "out").iterdir()):
    if path.suffix != ".json":
        continue
    message = json.loads(path.read_text())
    if message["kind"] == "fm.secondmate-leg-summary/v1":
        summaries.append(message)
assert len(summaries) == 2 and summaries[1]["bundles"] == [], summaries
PY
  test "$(find "$BLOB/session/out" -name 'bundle-*.bundle' | wc -l | tr -d ' ')" = 1 \
    || fail "a zero-commit leg must not upload a bundle"
  pass "leg-end bundling uploads, declares, and verifies commits; zero commits declare none"
}

attach_bundle_fetches_on_demand() {
  fixture
  # A child's delta bundle: one commit over the same dispatched base.
  git clone --quiet "$ORIGIN" "$TMP/child"
  echo child > "$TMP/child/child.txt"
  git -C "$TMP/child" add child.txt
  git -C "$TMP/child" -c user.name='Child' -c user.email='child@example.invalid' \
    commit -qm 'child work'
  local child_head
  child_head=$(git -C "$TMP/child" rev-parse HEAD)
  git -C "$TMP/child" bundle create "$TMP/child.bundle" "$BASE..HEAD" 2>/dev/null
  local digest bytes
  digest=$(shasum -a 256 "$TMP/child.bundle" | awk '{print $1}')
  bytes=$(wc -c < "$TMP/child.bundle" | tr -d ' ')
  mkdir -p "$BLOB/session/in/attach"
  cp "$TMP/child.bundle" "$BLOB/session/in/attach/$digest.bundle"
  put_inbox '{"kind":"fm.secondmate-attach/v1","name":"session/in/attach/'"$digest"'.bundle","sha256":"'"$digest"'","bytes":'"$bytes"'}' >/dev/null
  # A second announcement declaring the wrong size must refuse before fetch.
  put_inbox '{"kind":"fm.secondmate-attach/v1","name":"session/in/attach/'"$digest"'.bundle","sha256":"'"$digest"'","bytes":'"$((bytes + 1))"'}' >/dev/null
  put_inbox '{"kind":"fm.secondmate-control/v1","action":"close"}' >/dev/null
  run_leg >/dev/null 2>&1 || fail "attach leg did not exit cleanly"
  git -C "$REPO" cat-file -e "$child_head" || fail "child commit was not fetched into the repo"
  python3 - "$BLOB" <<'PY' || fail "wrong-size attach announcement was not refused"
import json, pathlib, sys
blob = pathlib.Path(sys.argv[1])
checks = []
for path in sorted((blob / "session" / "out").iterdir()):
    if path.suffix != ".json":
        continue
    message = json.loads(path.read_text())
    if message["kind"] == "fm.secondmate-refusal/v1":
        checks.append(message["check"])
assert any("attach blob size differs from the declared" in check for check in checks), checks
PY
  pass "a declared attach bundle is size-checked, fetched, and landed; a size lie refuses"
}

static_extension_contract() {
  python3 - "$EXTENSION" "$RUNNER" <<'PY' || fail "secondmate extension static contract failed"
from pathlib import Path
import sys
extension = Path(sys.argv[1]).read_text(encoding="utf-8")
runner = Path(sys.argv[2]).read_text(encoding="utf-8")
# The staged tool writes spool files only: no blob, HTTP, or az reach.
for marker in ("registerTool", "fm_cloud_spawn", "FM_SECONDMATE_SPOOL_DIR",
               '"ship", "scout"', "additionalProperties: false"):
    assert marker in extension, marker
for forbidden in ("http://", "https://", "blob.core.windows.net", "child_process", "spawnSync", "node:net"):
    assert forbidden not in extension, forbidden
# The runner owns the namespace refusal inside the transport and never
# weakens the chain-break refusal into a skip.
for marker in ("outside the session/ namespace", "outbox chain is broken",
               "SECONDMATE SESSION REFUSED: ", 'GENESIS_CHAIN_DIGEST = "0" * 64',
               "x-ms-blob-type", "2021-08-06", "Metadata",
               "PI_CODING_AGENT_DIR", "MAX_LEG_SECONDS = 6 * 60 * 60",
               "cannot ride the pi argv"):
    assert marker in runner, marker
PY
  pass "extension does spool-only I/O and the runner pins its refusal strings"
}

happy_leg_canonical_bytes
chain_continues_across_legs
chain_tamper_refuses
idle_exit_emits_summary
close_control_exits
wall_exit_before_hard_timeout
agent_dir_reaches_every_turn
leading_dash_text_refused
wall_defers_unstarted_turn
child_intent_round_trip
invalid_intent_refused_not_emitted
namespace_boundary_refuses
processed_set_dedupes_replay
commit_bundles_ride_home
attach_bundle_fetches_on_demand
static_extension_contract

echo "# fm-secondmate-session.test.sh: all assertions passed"
