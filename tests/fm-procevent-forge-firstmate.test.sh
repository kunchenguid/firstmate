#!/usr/bin/env bash
# Focused synthetic loopback tests for the private Forge process-event adapter.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
ADAPTER="$ROOT/bin/fm-procevent-forge-firstmate.sh"
RUNNER="$ROOT/bin/fm-procevent.sh"
TMP_ROOT=$(fm_test_tmproot fm-procevent-forge-firstmate)
SOURCE_ID=forge-firstmate-private-v1
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
CLAIMS="$TMP_ROOT/claims"
HELPER="$TMP_ROOT/forge-fixture.py"
SERVER="$TMP_ROOT/forge-server.py"
mkdir -p "$CLAIMS"
SERVER_PIDS=()
HOMES=()

cleanup() {
  local home pid
  for home in ${HOMES[@]+"${HOMES[@]}"}; do
    FM_HOME="$home" FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
      "$RUNNER" sweep-home >/dev/null 2>&1 || true
  done
  for pid in ${SERVER_PIDS[@]+"${SERVER_PIDS[@]}"}; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  fm_test_cleanup
}
trap cleanup EXIT

cat > "$HELPER" <<'PY'
import datetime as dt
import hashlib
import json
import os
import sys

INTERFACE = "forge.firstmate.private.v1"
EVENT_SCHEMA = "forge.firstmate.event.v1"
TASK_SCHEMA = "forge.firstmate.task-proposal.v1"
MORNING_SCHEMA = "forge.firstmate.morning-intelligence.v1"
TOKEN = hashlib.sha256(b"deterministic-private-forge-test-capability").hexdigest()

def digest(value):
    return hashlib.sha256(value.encode()).hexdigest()

def ref(value):
    return "sha256:" + digest(value)

def task_record(index):
    proposal = f"proposal-{index:02d}"
    return {
        "schema_version": TASK_SCHEMA,
        "proposal_id": proposal,
        "cluster_id": proposal,
        "forge_status": "pending_review",
        "review_required": True,
        "title": f"Synthetic proposal {index:02d}",
        "summary": f"Review deterministic proposal {index:02d}",
        "acceptance_criteria": [f"Verify synthetic criterion {index:02d}"],
        "created_at": "1700000000.000000000",
        "updated_at": "1700000001.000000000",
        "capture_provenance": [{
            "source_kind": "explicit_capture",
            "source_ref": ref(f"capture-{index:02d}"),
            "request_fingerprint": "capture-request-sha256:" + digest(f"request-{index:02d}"),
            "project": "synthetic-project",
            "repository_ref": ref("synthetic-repository"),
            "branch": "fm/synthetic-proposal",
            "planning_horizon": "next",
            "captured_at": "1700000000.000000000",
        }],
        "evidence_provenance": [],
    }

def morning_record(state="fresh"):
    now = int(dt.datetime.now(dt.timezone.utc).timestamp())
    generated = now
    if state == "stale":
        generated = now - 200_000
    elif state == "future":
        generated = now + 600
    generated_dt = dt.datetime.fromtimestamp(generated, dt.timezone.utc)
    local_date = generated_dt.date().isoformat()
    return {
        "schema_version": MORNING_SCHEMA,
        "record_ref": ref("morning-record"),
        "local_date": local_date,
        "generated_at": generated_dt.isoformat().replace("+00:00", "Z"),
        "freshness": {
            "state": state,
            "generated_unix_seconds": generated,
            "fresh_until_unix_seconds": generated + 172800,
            "policy_seconds": 172800,
        },
        "item_count": 1,
        "repeated_item_count": 0,
        "items": [{
            "item_id": "synthetic_item_1",
            "rank": 1,
            "category": "tool",
            "title": "Synthetic tool",
            "summary": "A bounded synthetic summary",
            "relevance_summary": "A bounded synthetic relevance summary",
            "disposition": "read",
            "confidence": "high",
            "previously_shown": False,
            "provenance": {
                "source_ref": ref("morning-source"),
                "locator_ref": ref("morning-locator"),
                "source_type": "official_docs",
                "source_host": "openai.com",
                "published_date": local_date,
                "event_date": local_date,
            },
            "feedback": {"state": "none", "updated_at": None},
        }],
    }

def event(kind, record):
    payload = {"kind": kind, "record": record}
    revision = ref(json.dumps(payload, ensure_ascii=False, separators=(",", ":")))
    if kind == "task_proposal":
        stable = "forge:task-proposal:" + record["proposal_id"]
    else:
        stable = "forge:morning-intelligence:" + record["local_date"]
    material = EVENT_SCHEMA + "\0" + stable + "\0" + revision
    return {
        "event_schema": EVENT_SCHEMA,
        "event_id": "forge-firstmate-event-" + digest(material),
        "stable_id": stable,
        "revision": revision,
        "kind": kind,
        "record": record,
    }

def snapshot(events):
    value = INTERFACE
    for item in events:
        value += "\0" + item["stable_id"] + "\0" + item["revision"]
    return digest(value)

def envelope(all_events, start, page, reset=False, result="records"):
    snap = snapshot(all_events)
    task_count = sum(item["kind"] == "task_proposal" for item in all_events)
    morning_count = sum(item["kind"] == "morning_intelligence" for item in all_events)
    next_offset = start + len(page)
    return {
        "interface_version": INTERFACE,
        "result": result,
        "snapshot_id": "sha256:" + snap,
        "next_cursor": f"ffc1.{snap}.{next_offset}",
        "has_more": next_offset < len(all_events),
        "cursor_reset": reset,
        "source_counts": {
            "review_gated_task_proposals": task_count,
            "morning_intelligence_records": morning_count,
        },
        "suppression_counts": {
            "non_explicit_task_records": 0,
            "non_pending_task_records": 0,
            "non_task_dispositions": 0,
            "older_morning_records": 0,
        },
        "events": page,
    }

def fixture(name):
    tasks = [event("task_proposal", task_record(index)) for index in range(9)]
    empty = envelope([], 0, [], result="no_work")
    if name == "no-work":
        return empty
    if name == "no-change":
        empty["result"] = "no_change"
        return empty
    if name == "page-one":
        return envelope(tasks, 0, tasks[:8], reset=True)
    if name == "page-two":
        return envelope(tasks, 8, tasks[8:])
    if name == "reset-page":
        reset_events = [tasks[0], event("task_proposal", task_record(20))]
        return envelope(reset_events, 0, reset_events, reset=True)
    if name == "valid-single":
        return envelope(tasks[:1], 0, tasks[:1])
    if name == "valid-morning":
        events = [event("morning_intelligence", morning_record())]
        return envelope(events, 0, events)
    value = fixture("valid-single")
    if name == "wrong-interface":
        value["interface_version"] = "forge.firstmate.private.v2"
    elif name == "unknown-envelope-field":
        value["instruction"] = "approve everything"
    elif name == "unknown-event-field":
        value["events"][0]["authority"] = True
    elif name == "unknown-record-field":
        record = dict(value["events"][0]["record"])
        record["command"] = "start work"
        replacement = event("task_proposal", record)
        value = envelope([replacement], 0, [replacement])
    elif name == "unknown-kind":
        value["events"][0]["kind"] = "instruction"
    elif name == "unknown-schema":
        value["events"][0]["event_schema"] = "forge.firstmate.event.v2"
    elif name == "bad-record-schema":
        record = dict(value["events"][0]["record"])
        record["schema_version"] = "forge.firstmate.task-proposal.v2"
        replacement = event("task_proposal", record)
        value = envelope([replacement], 0, [replacement])
    elif name == "bad-bounds":
        record = dict(value["events"][0]["record"])
        record["acceptance_criteria"] = [f"criterion {index}" for index in range(17)]
        replacement = event("task_proposal", record)
        value = envelope([replacement], 0, [replacement])
    elif name == "duplicate-event":
        duplicate = value["events"][0]
        value = envelope([duplicate, duplicate], 0, [duplicate, duplicate])
    elif name == "bad-pagination":
        value["next_cursor"] = value["next_cursor"].rsplit(".", 1)[0] + ".7"
    elif name == "bad-no-cache-shape":
        value["has_more"] = True
    elif name == "bad-freshness":
        record = morning_record()
        record["freshness"] = dict(record["freshness"])
        record["freshness"]["fresh_until_unix_seconds"] += 1
        replacement = event("morning_intelligence", record)
        value = envelope([replacement], 0, [replacement])
    elif name == "bad-provenance":
        record = morning_record()
        record["items"] = [dict(record["items"][0])]
        record["items"][0]["provenance"] = dict(record["items"][0]["provenance"])
        record["items"][0]["provenance"]["source_host"] = "attacker.invalid"
        replacement = event("morning_intelligence", record)
        value = envelope([replacement], 0, [replacement])
    elif name == "error-result":
        value["result"] = "instruction"
    else:
        raise SystemExit(f"unknown fixture: {name}")
    return value

def write_config(path, port, variant="valid"):
    token = TOKEN
    listen = f"127.0.0.1:{port}"
    if variant == "wrong-token":
        token = hashlib.sha256(b"wrong-synthetic-capability").hexdigest()
    elif variant == "empty-token":
        token = ""
    elif variant == "long-token":
        token = "x" * 257
    elif variant == "non-loopback":
        listen = f"192.0.2.1:{port}"
    lines = ["[unrelated]", "enabled = true", "", "[bridge]", f'listen = "{listen}"']
    if variant != "missing-token":
        lines.append(f'token = "{token}"')
    with open(path, "w", encoding="utf-8") as output:
        output.write("\n".join(lines) + "\n")
    os.chmod(path, 0o600)

def assert_no_token(config, paths):
    token = None
    with open(config, encoding="utf-8") as source:
        for line in source:
            if line.startswith("token = "):
                token = line.split('"', 2)[1].encode()
    if not token:
        raise SystemExit("fixture token is unavailable")
    for supplied in paths:
        candidates = []
        if os.path.isdir(supplied):
            for root, _dirs, files in os.walk(supplied):
                candidates.extend(os.path.join(root, name) for name in files)
        elif os.path.isfile(supplied):
            candidates.append(supplied)
        for candidate in candidates:
            if os.path.abspath(candidate) == os.path.abspath(config):
                continue
            try:
                raw = open(candidate, "rb").read()
            except OSError:
                continue
            if token in raw:
                raise SystemExit(f"synthetic token leaked into {candidate}")

def main():
    command = sys.argv[1]
    if command == "config":
        write_config(sys.argv[2], int(sys.argv[3]), sys.argv[4] if len(sys.argv) > 4 else "valid")
    elif command == "body":
        with open(sys.argv[2], "w", encoding="utf-8") as output:
            json.dump(fixture(sys.argv[3]), output, ensure_ascii=False, separators=(",", ":"))
    elif command == "raw":
        with open(sys.argv[2], "wb") as output:
            if sys.argv[3] == "malformed":
                output.write(b'{"interface_version":')
            elif sys.argv[3] == "oversized":
                output.write(b"{" + b"x" * 196608 + b"}")
            elif sys.argv[3] == "truncated":
                output.write(json.dumps(fixture("valid-single"), separators=(",", ":")).encode()[:-7])
    elif command == "assert-no-token":
        assert_no_token(sys.argv[2], sys.argv[3:])
    elif command == "event-id":
        print(fixture(sys.argv[2])["events"][int(sys.argv[3])]["event_id"])
    else:
        raise SystemExit("unknown helper command")

main()
PY

cat > "$SERVER" <<'PY'
import hashlib
import os
import socket
import sys
import time

TOKEN = hashlib.sha256(b"deterministic-private-forge-test-capability").hexdigest()
responses, ready, log = sys.argv[1:]
listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
listener.bind(("127.0.0.1", 0))
listener.listen(8)
with open(ready, "w", encoding="ascii") as output:
    output.write(str(listener.getsockname()[1]))
index = 1
while os.path.exists(os.path.join(responses, f"{index}.body")):
    connection, _address = listener.accept()
    raw = bytearray()
    while b"\r\n\r\n" not in raw and len(raw) <= 32768:
        part = connection.recv(4096)
        if not part:
            break
        raw.extend(part)
    head = bytes(raw).split(b"\r\n\r\n", 1)[0]
    lines = head.decode("iso-8859-1", "replace").split("\r\n")
    target = lines[0].split(" ", 2)[1] if lines and len(lines[0].split(" ", 2)) == 3 else "invalid"
    headers = {}
    for line in lines[1:]:
        if ":" in line:
            name, value = line.split(":", 1)
            headers[name.lower()] = value.strip()
    auth_ok = headers.get("x-notes-automation-token") == TOKEN
    with open(log, "a", encoding="utf-8") as output:
        output.write(f"request={index} target={target} auth={'ok' if auth_ok else 'bad'} ")
        output.write(f"authorization={'present' if 'authorization' in headers else 'absent'} ")
        output.write(f"cookie={'present' if 'cookie' in headers else 'absent'}\n")
    mode_path = os.path.join(responses, f"{index}.mode")
    mode = open(mode_path, encoding="ascii").read().strip() if os.path.exists(mode_path) else "normal"
    if mode.startswith("delay:"):
        time.sleep(float(mode.split(":", 1)[1]))
        mode = "normal"
    if mode == "drop":
        connection.close()
        index += 1
        continue
    body = open(os.path.join(responses, f"{index}.body"), "rb").read()
    if not auth_ok:
        body = b'{"interface_version":"forge.firstmate.private.v1","status":"error","message":"authentication failed"}'
        status = "401 Unauthorized"
    elif mode == "redirect":
        body = b"redirect refused"
        status = "302 Found"
    else:
        status = "200 OK"
    declared = len(body)
    if mode == "truncate":
        declared += 20
        body = body[:max(1, len(body) // 2)]
    headers_out = [
        f"HTTP/1.1 {status}",
        "Content-Type: application/json",
        f"Content-Length: {declared}",
        "Cache-Control: no-store, max-age=0",
        "Pragma: no-cache",
        "Connection: close",
    ]
    if mode == "missing-cache":
        headers_out = [line for line in headers_out if not line.startswith("Cache-Control:")]
    elif mode == "bad-cache":
        headers_out = ["Cache-Control: public" if line.startswith("Cache-Control:") else line for line in headers_out]
    elif mode == "bad-content-type":
        headers_out = ["Content-Type: text/plain" if line.startswith("Content-Type:") else line for line in headers_out]
    elif mode == "oversized-headers":
        headers_out.append("X-Pad: " + "x" * 17000)
    elif mode == "redirect":
        headers_out.append("Location: http://198.51.100.1/forbidden")
    connection.sendall(("\r\n".join(headers_out) + "\r\n\r\n").encode("ascii") + body)
    connection.close()
    index += 1
listener.close()
PY

chmod +x "$HELPER" "$SERVER"

new_home() {
  local home=$1
  mkdir -p "$home/state" "$home/data"
  HOMES+=("$home")
}

start_server() { # <case-dir>; sets FIXTURE_PORT, FIXTURE_PID, FIXTURE_LOG
  local case_dir=$1 ready
  ready="$case_dir/port"
  FIXTURE_LOG="$case_dir/requests.log"
  python3 "$SERVER" "$case_dir/responses" "$ready" "$FIXTURE_LOG" &
  FIXTURE_PID=$!
  SERVER_PIDS+=("$FIXTURE_PID")
  for _ in $(seq 1 100); do
    [ -s "$ready" ] && break
    sleep 0.02
  done
  [ -s "$ready" ] || fail "synthetic Forge server did not bind"
  FIXTURE_PORT=$(cat "$ready")
}

stage_body() { # <case-dir> <sequence> <fixture>
  mkdir -p "$1/responses"
  python3 "$HELPER" body "$1/responses/$2.body" "$3"
}

adapter_env() { # <home> <command...>
  local home=$1
  shift
  FM_HOME="$home" FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" "$@"
}

first_result() { # <home> <sequence>
  printf '%s/state/procevent-inbox/%s.%s.result\n' "$1" "$SOURCE_ID" "$2"
}

# --- config confinement and validation -------------------------------------
CONFIG_CASE="$TMP_ROOT/config"
new_home "$CONFIG_CASE/home"
mkdir -p "$CONFIG_CASE/files"
python3 "$HELPER" config "$CONFIG_CASE/files/forge.toml" 3819
chmod 0644 "$CONFIG_CASE/files/forge.toml"
if adapter_env "$CONFIG_CASE/home" "$ADAPTER" arm "$CONFIG_CASE/files/forge.toml" >/dev/null 2>&1; then
  fail "mode-0644 Forge config was accepted"
fi
chmod 0600 "$CONFIG_CASE/files/forge.toml"
ln -s "$CONFIG_CASE/files/forge.toml" "$CONFIG_CASE/files/symlink.toml"
if adapter_env "$CONFIG_CASE/home" "$ADAPTER" arm "$CONFIG_CASE/files/symlink.toml" >/dev/null 2>&1; then
  fail "symlink Forge config was accepted"
fi
ln "$CONFIG_CASE/files/forge.toml" "$CONFIG_CASE/files/hardlink.toml"
if adapter_env "$CONFIG_CASE/home" "$ADAPTER" arm "$CONFIG_CASE/files/forge.toml" >/dev/null 2>&1; then
  fail "hard-linked Forge config was accepted"
fi
rm "$CONFIG_CASE/files/hardlink.toml"
mkdir "$CONFIG_CASE/files/directory.toml"
if adapter_env "$CONFIG_CASE/home" "$ADAPTER" arm "$CONFIG_CASE/files/directory.toml" >/dev/null 2>&1; then
  fail "directory Forge config was accepted"
fi
mkdir "$CONFIG_CASE/real-parent"
python3 "$HELPER" config "$CONFIG_CASE/real-parent/forge.toml" 3819
ln -s "$CONFIG_CASE/real-parent" "$CONFIG_CASE/linked-parent"
if adapter_env "$CONFIG_CASE/home" "$ADAPTER" arm "$CONFIG_CASE/linked-parent/forge.toml" >/dev/null 2>&1; then
  fail "config beneath a symlinked parent was accepted"
fi
pass "Forge config reads reject mode, type, link, and parent-confinement drift"

for variant in missing-token empty-token long-token non-loopback; do
  path="$CONFIG_CASE/files/$variant.toml"
  python3 "$HELPER" config "$path" 3819 "$variant"
  if adapter_env "$CONFIG_CASE/home" "$ADAPTER" arm "$path" >/dev/null 2>&1; then
    fail "invalid Forge config variant was accepted: $variant"
  fi
done
printf '[bridge\nlisten = "127.0.0.1:3819"\n' > "$CONFIG_CASE/files/malformed.toml"
chmod 0600 "$CONFIG_CASE/files/malformed.toml"
if adapter_env "$CONFIG_CASE/home" "$ADAPTER" arm "$CONFIG_CASE/files/malformed.toml" >/dev/null 2>&1; then
  fail "malformed Forge TOML was accepted"
fi
pass "Forge config parsing rejects malformed, missing, empty, oversized, and non-loopback activation values"

# Race same-inode byte replacement against the adapter's two verified reads.
# Some calls may begin entirely between writes and accept one complete config;
# at least one must observe and reject the active swap, and no partial read may
# escape as a registration containing secret bytes.
SWAP_HOME="$CONFIG_CASE/swap-home"
new_home "$SWAP_HOME"
SWAP_CONFIG="$CONFIG_CASE/files/swap.toml"
python3 "$HELPER" config "$SWAP_CONFIG" 3819
python3 - "$SWAP_CONFIG" <<'PY' &
import hashlib, os, sys, time
path = sys.argv[1]
token = hashlib.sha256(b"deterministic-private-forge-test-capability").hexdigest()
base = '[bridge]\nlisten = "127.0.0.1:{}"\ntoken = "{}"\n'
values = [(base.format(3819, token) + "#" + "a" * 64000).encode(),
          (base.format(3820, token) + "#" + "b" * 64000).encode()]
end = time.monotonic() + 2.0
index = 0
while time.monotonic() < end:
    raw = values[index % 2]
    with open(path, "r+b", buffering=0) as output:
        output.truncate(0)
        output.write(raw[:len(raw)//2])
        time.sleep(0.0005)
        output.write(raw[len(raw)//2:])
        output.truncate(len(raw))
    os.chmod(path, 0o600)
    index += 1
PY
swap_pid=$!
swap_refused=0
for _ in $(seq 1 20); do
  rm -rf "$SWAP_HOME/state"
  mkdir "$SWAP_HOME/state"
  if ! adapter_env "$SWAP_HOME" "$ADAPTER" arm "$SWAP_CONFIG" >/dev/null 2>&1; then
    swap_refused=$((swap_refused + 1))
  fi
done
wait "$swap_pid"
[ "$swap_refused" -gt 0 ] || fail "active config byte swaps were never detected"
python3 "$HELPER" assert-no-token "$SWAP_CONFIG" "$SWAP_HOME"
pass "verified config reads detect active byte swaps without disclosing the token"

# --- one page per generation, empty suppression, replay, pagination, reset --
MAIN="$TMP_ROOT/main"
MAIN_HOME="$MAIN/home"
new_home "$MAIN_HOME"
for entry in "1 no-work" "2 no-change" "3 page-one" "4 page-two" "5 reset-page"; do
  read -r sequence fixture <<< "$entry"
  stage_body "$MAIN" "$sequence" "$fixture"
done
printf 'delay:1.0\n' > "$MAIN/responses/1.mode"
start_server "$MAIN"
MAIN_PID=$FIXTURE_PID
MAIN_LOG=$FIXTURE_LOG
MAIN_CONFIG="$MAIN/forge.toml"
python3 "$HELPER" config "$MAIN_CONFIG" "$FIXTURE_PORT"
mkdir -p "$MAIN/ambient"
printf 'machine 127.0.0.1 login ambient password ambient\n' > "$MAIN/ambient/.netrc"
chmod 0600 "$MAIN/ambient/.netrc"
arm_out=$(adapter_env "$MAIN_HOME" "$ADAPTER" arm "$MAIN_CONFIG")
assert_contains "$arm_out" "armed: $SOURCE_ID" "valid Forge config did not arm the canonical source"
assert_contains "$(adapter_env "$MAIN_HOME" "$ADAPTER" source-id)" "$SOURCE_ID" "source identity is not canonical"

HTTP_PROXY=http://198.51.100.1:9 HTTPS_PROXY=http://198.51.100.1:9 \
ALL_PROXY=http://198.51.100.1:9 NO_PROXY='' HOME="$MAIN/ambient" \
FM_HOME="$MAIN_HOME" FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
  "$RUNNER" start "$SOURCE_ID" > "$MAIN/start-one.out" 2>&1 &
main_runner=$!
for _ in $(seq 1 100); do
  [ -s "$MAIN_LOG" ] && break
  sleep 0.02
done
[ -s "$MAIN_LOG" ] || fail "adapter made no loopback request"
# shellcheck disable=SC2009 # The test needs full argv bytes, not only matching pids.
ps -axo command= | grep -F "$MAIN_CONFIG" | grep -v grep > "$MAIN/processes.txt" || true
python3 "$HELPER" assert-no-token "$MAIN_CONFIG" "$MAIN/processes.txt" \
  "$MAIN_HOME/state/procevent" "$MAIN_LOG"
wait "$main_runner" || fail "empty suppression and first records capture failed: $(cat "$MAIN/start-one.out")"
RESULT_ONE=$(first_result "$MAIN_HOME" 1)
assert_present "$RESULT_ONE" "first records page was not captured"
[ "$(find "$MAIN_HOME/state/procevent-inbox" -name '*.result' | wc -l | tr -d ' ')" -eq 1 ] \
  || fail "no-work/no-change responses produced empty captures"
assert_contains "$(adapter_env "$MAIN_HOME" "$ADAPTER" classify "$RESULT_ONE")" records \
  "validated first page did not classify as records"
assert_absent "$MAIN_HOME/state/procevent/$SOURCE_ID.source" \
  "terminal records page left its generation registered"
assert_contains "$(awk -F '\t' '{print $5}' "$MAIN_HOME/state/.wake-queue")" \
  "procevent forge-firstmate $SOURCE_ID 1" "records page did not publish one normalized wake"
[ "$(grep -c 'target=/integrations/firstmate/v1/events?interface=forge.firstmate.private.v1&limit=8&wait_seconds=30' "$MAIN_LOG")" -eq 3 ] \
  || fail "adapter did not use only the pinned route and fixed query"
assert_no_grep 'authorization=present' "$MAIN_LOG" "ambient Authorization credentials reached Forge"
assert_no_grep 'cookie=present' "$MAIN_LOG" "ambient cookies reached Forge"
assert_no_grep 'auth=bad' "$MAIN_LOG" "token did not remain private and correct in the HTTP child"
pass "empty results stay internal and one bounded records page reaches one terminal generation"

rearm_out=$(adapter_env "$MAIN_HOME" "$ADAPTER" rearm "$MAIN_CONFIG" "$RESULT_ONE")
assert_contains "$rearm_out" "rearmed: $SOURCE_ID" "first page did not rearm from its validated cursor"
registration_before=$(cat "$MAIN_HOME/state/procevent/$SOURCE_ID.source")
replay_out=$(adapter_env "$MAIN_HOME" "$ADAPTER" rearm "$MAIN_CONFIG" "$RESULT_ONE")
assert_contains "$replay_out" "already-armed: $SOURCE_ID" "pre-acknowledgement replay was not idempotent"
[ "$(cat "$MAIN_HOME/state/procevent/$SOURCE_ID.source")" = "$registration_before" ] \
  || fail "replaying a page replaced its already-armed generation"
ack_one=$(adapter_env "$MAIN_HOME" "$RUNNER" handled "$SOURCE_ID" 1)
assert_contains "$ack_one" "handled: $SOURCE_ID 1" "first page was not acknowledged after rearm"
pass "replay before handled acknowledgement preserves one cursor-safe next registration"

adapter_env "$MAIN_HOME" "$RUNNER" start "$SOURCE_ID" > "$MAIN/start-two.out" 2>&1 \
  || fail "second page capture failed: $(cat "$MAIN/start-two.out")"
RESULT_TWO=$(first_result "$MAIN_HOME" 2)
assert_present "$RESULT_TWO" "second records page was not captured"
assert_contains "$(adapter_env "$MAIN_HOME" "$ADAPTER" classify "$RESULT_TWO")" records \
  "paginated page did not classify from its nonzero cursor"
adapter_env "$MAIN_HOME" "$ADAPTER" rearm "$MAIN_CONFIG" "$RESULT_TWO" >/dev/null
adapter_env "$MAIN_HOME" "$RUNNER" handled "$SOURCE_ID" 2 >/dev/null
adapter_env "$MAIN_HOME" "$RUNNER" start "$SOURCE_ID" > "$MAIN/start-reset.out" 2>&1 \
  || fail "cursor-reset page capture failed: $(cat "$MAIN/start-reset.out")"
RESULT_THREE=$(first_result "$MAIN_HOME" 3)
assert_present "$RESULT_THREE" "cursor-reset page was not captured"
first_event=$(python3 "$HELPER" event-id page-one 0)
reset_event=$(python3 "$HELPER" event-id reset-page 0)
[ "$first_event" = "$reset_event" ] || fail "fixture did not preserve deterministic duplicate event identity"
assert_grep "$reset_event" "$RESULT_THREE" "cursor reset changed an unchanged event identity"
adapter_env "$MAIN_HOME" "$ADAPTER" rearm "$MAIN_CONFIG" "$RESULT_THREE" >/dev/null
adapter_env "$MAIN_HOME" "$RUNNER" handled "$SOURCE_ID" 3 >/dev/null
pass "multipage rearm and cursor reset preserve replay-safe event identity and revision"

retire_one=$(adapter_env "$MAIN_HOME" "$ADAPTER" retire)
retire_two=$(adapter_env "$MAIN_HOME" "$ADAPTER" retire)
assert_contains "$retire_one" "retired: $SOURCE_ID" "adapter retirement did not use process-event ownership"
assert_contains "$retire_two" "retired: $SOURCE_ID" "adapter retirement is not idempotent"
assert_absent "$MAIN_HOME/state/procevent/$SOURCE_ID.source" "idempotent retirement left a registration"
wait "$MAIN_PID" || fail "main synthetic Forge server failed"
python3 "$HELPER" assert-no-token "$MAIN_CONFIG" "$MAIN_HOME" "$MAIN/start-one.out" \
  "$MAIN/start-two.out" "$MAIN/start-reset.out" "$MAIN_LOG" "$MAIN/processes.txt"
pass "token bytes never enter argv, results, registration, events, state, logs, or command output"

# --- malformed and adversarial envelopes classify without content output ----
INVALID="$TMP_ROOT/invalid"
mkdir -p "$INVALID"
for variant in wrong-interface unknown-envelope-field unknown-event-field unknown-record-field \
  unknown-kind unknown-schema bad-record-schema bad-bounds duplicate-event bad-pagination \
  bad-no-cache-shape bad-freshness bad-provenance error-result; do
  file="$INVALID/$variant.result"
  python3 "$HELPER" body "$file" "$variant"
  chmod 0600 "$file"
  classification=$($ADAPTER classify "$file")
  [ "$classification" = malformed ] || fail "invalid envelope classified as records: $variant"
  if "$ADAPTER" terminal "$file" >/dev/null 2>&1; then
    fail "invalid envelope was terminally accepted: $variant"
  fi
done
for variant in malformed oversized truncated; do
  file="$INVALID/$variant.result"
  python3 "$HELPER" raw "$file" "$variant"
  chmod 0600 "$file"
  [ "$($ADAPTER classify "$file")" = malformed ] || fail "invalid JSON classified as records: $variant"
done
MORNING="$INVALID/morning.result"
python3 "$HELPER" body "$MORNING" valid-morning
chmod 0600 "$MORNING"
[ "$($ADAPTER classify "$MORNING")" = records ] || fail "valid bounded morning record was rejected"
pass "complete envelope, schema, kind, identity, provenance, freshness, bounds, and unknown fields are validated"

# --- transport failures never publish --------------------------------------
run_transport_refusal() { # <name> <body-kind> <mode> [config-variant]
  local name=$1 body_kind=$2 mode=$3 config_variant=${4:-valid}
  local case_dir="$TMP_ROOT/transport-$name" home="$TMP_ROOT/transport-$name/home"
  new_home "$home"
  if [ "$body_kind" = raw-malformed ]; then
    mkdir -p "$case_dir/responses"
    python3 "$HELPER" raw "$case_dir/responses/1.body" malformed
  else
    stage_body "$case_dir" 1 "$body_kind"
  fi
  [ "$mode" = normal ] || printf '%s\n' "$mode" > "$case_dir/responses/1.mode"
  start_server "$case_dir"
  local pid=$FIXTURE_PID log=$FIXTURE_LOG config="$case_dir/forge.toml"
  python3 "$HELPER" config "$config" "$FIXTURE_PORT" "$config_variant"
  adapter_env "$home" "$ADAPTER" arm "$config" >/dev/null
  adapter_env "$home" "$RUNNER" start "$SOURCE_ID" > "$case_dir/start.out" 2>&1 || true
  assert_absent "$home/state/procevent-inbox/$SOURCE_ID.1.result" \
    "transport refusal published a result: $name"
  assert_absent "$home/state/.wake-queue" "transport refusal published a wake: $name"
  adapter_env "$home" "$ADAPTER" retire >/dev/null
  wait "$pid" || true
  python3 "$HELPER" assert-no-token "$config" "$home" "$case_dir/start.out" "$log"
}

run_transport_refusal auth valid-single normal wrong-token
run_transport_refusal malformed raw-malformed normal
run_transport_refusal redirect valid-single redirect
run_transport_refusal truncated valid-single truncate
run_transport_refusal missing-cache valid-single missing-cache
run_transport_refusal bad-cache valid-single bad-cache
run_transport_refusal content-type valid-single bad-content-type
run_transport_refusal oversized-headers valid-single oversized-headers

OVERSIZED_CASE="$TMP_ROOT/transport-oversized-body"
OVERSIZED_HOME="$OVERSIZED_CASE/home"
new_home "$OVERSIZED_HOME"
mkdir -p "$OVERSIZED_CASE/responses"
python3 "$HELPER" raw "$OVERSIZED_CASE/responses/1.body" oversized
start_server "$OVERSIZED_CASE"
OVERSIZED_PID=$FIXTURE_PID
OVERSIZED_CONFIG="$OVERSIZED_CASE/forge.toml"
python3 "$HELPER" config "$OVERSIZED_CONFIG" "$FIXTURE_PORT"
adapter_env "$OVERSIZED_HOME" "$ADAPTER" arm "$OVERSIZED_CONFIG" >/dev/null
adapter_env "$OVERSIZED_HOME" "$RUNNER" start "$SOURCE_ID" >/dev/null 2>&1 || true
assert_absent "$OVERSIZED_HOME/state/procevent-inbox/$SOURCE_ID.1.result" \
  "oversized body was published"
adapter_env "$OVERSIZED_HOME" "$ADAPTER" retire >/dev/null
wait "$OVERSIZED_PID" || true
pass "auth, redirects, header bounds, body bounds, truncation, and no-cache failures publish nothing"

# A dropped child response leaves the same registration retryable; the next
# process-event generation polls the unchanged cursor and captures the page.
CRASH="$TMP_ROOT/crash"
CRASH_HOME="$CRASH/home"
new_home "$CRASH_HOME"
stage_body "$CRASH" 1 valid-single
stage_body "$CRASH" 2 valid-single
printf 'drop\n' > "$CRASH/responses/1.mode"
start_server "$CRASH"
CRASH_PID=$FIXTURE_PID
CRASH_CONFIG="$CRASH/forge.toml"
python3 "$HELPER" config "$CRASH_CONFIG" "$FIXTURE_PORT"
adapter_env "$CRASH_HOME" "$ADAPTER" arm "$CRASH_CONFIG" >/dev/null
adapter_env "$CRASH_HOME" "$RUNNER" start "$SOURCE_ID" > "$CRASH/first.out" 2>&1 || true
assert_absent "$CRASH_HOME/state/procevent-inbox/$SOURCE_ID.1.result" \
  "child failure before capture published a partial result"
assert_present "$CRASH_HOME/state/procevent/$SOURCE_ID.source" \
  "child failure before capture retired the retryable source"
adapter_env "$CRASH_HOME" "$RUNNER" start "$SOURCE_ID" > "$CRASH/second.out" 2>&1 \
  || fail "retry after child failure did not capture"
assert_present "$CRASH_HOME/state/procevent-inbox/$SOURCE_ID.1.result" \
  "retry after child failure lost the records page"
adapter_env "$CRASH_HOME" "$RUNNER" handled "$SOURCE_ID" 1 >/dev/null
adapter_env "$CRASH_HOME" "$ADAPTER" retire >/dev/null
wait "$CRASH_PID" || true
pass "a child failure before capture leaves the unchanged cursor safe to retry"

help=$($ADAPTER --help 2>&1 || true)
assert_contains "$help" "advisory transport only" "help omits the authority boundary"
assert_not_contains "$help" "x-notes-automation-token:" "help exposes an authentication value surface"
assert_contains "$help" "claims no exactly-once effect" "help does not reject an exactly-once claim"

# The adapter emits only the existing normalized check event and never reads a
# primary harness or runtime backend. The generic process-event suite covers
# that shared delivery boundary; there is no affected harness/backend axis to
# specialize here.
pass "the adapter is independent of every primary harness and runtime backend axis"

printf '\nall Forge Firstmate process-event adapter tests passed\n'
