#!/usr/bin/env bash
# tests/fm-voice-relay.test.sh - the spoken interface's wire format, read scope and handover.
#
# Every case here runs offline. The three things worth protecting in this feature
# are all offline properties: the frame format the laptop and the desktop agree
# on, WHAT a status answer is allowed to contain, and the fact that real work is
# handed to firstmate rather than done by the voice agent. The latency work that
# motivated the build is a measurement, not an assertion, so it is not here; the
# numbers and the method live in docs/voice-relay.md.
#
# THE CASE THAT MATTERS MOST is the confidentiality boundary. The captain granted
# the voice agent full read access to their records, so the reader defaults to the
# wider scope. What keeps that safe is structural: finished work and free-form
# note bodies are never assembled at all, and those are exactly where commercial
# detail accumulates. This suite plants a marker in both places and fails if it
# ever reaches an answer, so widening the reader later breaks a test instead of
# quietly widening what is sent to a model in another region.
#
# The markers below are invented for this fixture. Real customer names are not
# committed to a test file.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-voice-relay)
HOME_FIXTURE="$TMP_ROOT/home"

# NEVER_TOKEN sits in finished work and in a note body: both are excluded by
# construction, so it must never appear at any scope.
NEVER_TOKEN=NEVERLEAVESTHISHOST
# DENY_TOKEN sits in the title of open in-flight work, which the wide scope does
# report. It proves the deny list suppresses something that genuinely would have
# been sent, rather than passing vacuously against text no answer contains.
DENY_TOKEN=DENYMEPLEASE

seed_home() {
  mkdir -p "$HOME_FIXTURE/data" "$HOME_FIXTURE/state" "$HOME_FIXTURE/config"
  cat > "$HOME_FIXTURE/data/backlog.md" <<EOF
# Backlog

## In flight
- [ ] alpha-one - Fix the sign-in redirect (repo: alpha) (kind: ship) (priority: 0) (since 2026-08-01)
  Long note body written for someone with the whole file open, mentioning
  $NEVER_TOKEN and the rate we agreed.
- [ ] beta-two - Decide the storage shape (repo: beta) (kind: captain) (priority: 1)
- [ ] gamma-three - Migrate the $DENY_TOKEN account onto the new plan (repo: gamma) (kind: ship)

## Queued
- [ ] delta-four - Add the retry (repo: delta) (kind: ship) (hold-kind: captain) (hold: waiting on the captain)
- [ ] epsilon-five - Tidy the logs (repo: epsilon) (kind: ship)

## Done
- [x] old-six - Shipped the $NEVER_TOKEN integration (repo: alpha) (done 2026-07-01)
# An unticked line under Done, held for the captain. Two separate mechanisms keep
# finished work out of an answer: the section is never parsed, and a ticked box is
# dropped. A ticked line is blocked by both, so it cannot tell which one broke.
# This line is blocked by the section rule alone, and the list of what waits on
# the captain is assembled with no section filter at all, so it is the one place
# where losing that rule would put finished work into a spoken answer.
- [ ] old-seven - Decide the $NEVER_TOKEN renewal (repo: alpha) (kind: captain)
EOF

  fm_write_meta "$HOME_FIXTURE/state/alpha-one.meta" \
    kind=ship mode=no-mistakes window=firstmate:fm-alpha-one \
    pr=https://github.com/example/alpha/pull/7
  fm_write_meta "$HOME_FIXTURE/state/gamma-three.meta" kind=ship mode=direct-PR
  printf 'working: reading the failing test\n' > "$HOME_FIXTURE/state/alpha-one.status"
  # The bracketed shape, which is what bin/fm-secondmate-report.sh writes and
  # what a keyed decision line looks like. Status metadata sits between the verb
  # and the colon, so a reader that only cuts at the colon reads no verb here.
  printf 'blocked [key=api-shape]: needs a credential (via-helper)\n' \
    > "$HOME_FIXTURE/state/gamma-three.status"
}

records_status() {
  python3 "$ROOT/bin/fm_voice_records.py" status --home "$HOME_FIXTURE" "$@"
}

seed_home

# --- the wire format --------------------------------------------------------
#
# A desynchronised stream must be a loud error rather than audio interpreted as
# a frame header. The laptop copy of this module is the only other place these
# rules exist, so they are pinned here.

python3 - "$ROOT/bin" <<'PY' || fail "frame round trip"
import os, io, sys
sys.path.insert(0, sys.argv[1])
import fm_voice_frame as frame

def check(cond, label):
    if not cond:
        sys.exit("frame: " + label)

# Round trip of every kind, including an empty payload and a large one.
buf = io.BytesIO()
w = frame.Writer(buf)
w.send(frame.TALK_START)
w.send(frame.AUDIO, b"\x01\x02" * 1600)
w.send_json(frame.TEXT, {"role": "USER", "text": "how is the fleet"})
w.send(frame.TALK_END)
buf.seek(0)
r = frame.Reader(buf)
got = []
while True:
    item = r.read()
    if item is None:
        break
    got.append(item)
check([k for k, _ in got] == [frame.TALK_START, frame.AUDIO, frame.TEXT,
                              frame.TALK_END], "kinds did not round trip")
check(got[1][1] == b"\x01\x02" * 1600, "audio payload did not round trip")
check(frame.decode_json(got[2][1])["text"] == "how is the fleet",
      "json payload did not round trip")

# A clean close between frames is end of input, not an error.
check(frame.Reader(io.BytesIO(b"")).read() is None, "clean EOF should be None")

# A stream cut inside a payload is a dropped connection and must say so.
try:
    frame.Reader(io.BytesIO(frame.encode(frame.AUDIO, b"12345")[:-2])).read()
    sys.exit("frame: truncated payload was accepted")
except frame.FrameError:
    pass

# Audio bytes that happen to look like a header must not be trusted.
for bad in (b"\xffZZZZ", frame.HEADER.pack(frame.AUDIO, frame.MAX_PAYLOAD + 1)):
    try:
        frame.Reader(io.BytesIO(bad)).read()
        sys.exit("frame: accepted a bad header: %r" % bad)
    except frame.FrameError:
        pass

try:
    frame.encode(b"?")
    sys.exit("frame: encoded an unknown kind")
except frame.FrameError:
    pass

try:
    frame.encode(frame.AUDIO, b"x" * (frame.MAX_PAYLOAD + 1))
    sys.exit("frame: encoded an oversized payload")
except frame.FrameError:
    pass

# The relay's uplink decodes headers itself, on an asynchronous stream Reader
# cannot drive, and calls this to decide whether to read the payload at all. A
# bogus length has to be refused BEFORE the read, or the relay waits for up to
# four gigabytes while the captain waits for an answer.
for kind, length in ((b"\xff", 0), (frame.AUDIO, frame.MAX_PAYLOAD + 1)):
    try:
        frame.check_header(kind, length)
        sys.exit("frame: check_header accepted %r/%d" % (kind, length))
    except frame.FrameError:
        pass
frame.check_header(frame.AUDIO, frame.MAX_PAYLOAD)
PY
pass "wire format round trips and rejects a desynchronised stream"

# --- the relay's uplink ------------------------------------------------------
#
# The relay decodes the captain's frames on an asyncio stream, which frame.Reader
# cannot drive, so the rule above has to be exercised on that path as well. The
# failure mode it prevents is not a wrong answer, it is no answer: a relay that
# reads the payload before it checks the length waits inside readexactly for up
# to four gigabytes that will never arrive, while the captain sits in front of a
# client that never replies. The timeout below is what tells those two apart.

python3 - "$ROOT/bin" <<'PY' || fail "relay uplink"
import asyncio, sys
sys.path.insert(0, sys.argv[1])
import importlib.util, pathlib
spec = importlib.util.spec_from_file_location(
    "relay", str(pathlib.Path(sys.argv[1]) / "fm-voice-relay.py"))
relay = importlib.util.module_from_spec(spec)
spec.loader.exec_module(relay)
import fm_voice_frame as frame

def check(cond, label):
    if not cond:
        sys.exit("uplink: " + label)

async def read(raw):
    reader = asyncio.StreamReader()
    reader.feed_data(raw)
    return await asyncio.wait_for(relay.read_uplink_frame(reader), timeout=5)

audio = b"\x01\x02" * 8
check(asyncio.run(read(frame.encode(frame.AUDIO, audio))) == (frame.AUDIO, audio),
      "a frame carrying audio did not survive the uplink")
check(asyncio.run(read(frame.encode(frame.TALK_END))) == (frame.TALK_END, b""),
      "an empty control frame did not survive the uplink")

# A header with nothing behind it. Refused on the header, this raises at once;
# read first and checked later, it hangs, so a timeout here is the regression.
for bad in (frame.HEADER.pack(frame.AUDIO, frame.MAX_PAYLOAD + 1),
            b"\xff\x00\x00\x10\x00"):
    try:
        asyncio.run(read(bad))
        sys.exit("uplink: accepted a bad header: %r" % bad)
    except frame.FrameError:
        pass
    except (asyncio.TimeoutError, TimeoutError):
        sys.exit("uplink: waited for the payload of a bad header instead of "
                 "refusing it: %r" % bad)
PY
pass "the relay refuses a desynchronised uplink header instead of waiting for its payload"

# --- the tool surface the two sides share -----------------------------------
#
# The relay declares the tools and fm_voice_records implements them. Renaming one
# side only would leave the agent unable to answer or unable to hand over, and
# the failure would look like a confused model rather than a typo.

python3 - "$ROOT/bin" <<'PY' || fail "tool surface"
import sys
sys.path.insert(0, sys.argv[1])
import importlib.util, pathlib
spec = importlib.util.spec_from_file_location(
    "relay", str(pathlib.Path(sys.argv[1]) / "fm-voice-relay.py"))
relay = importlib.util.module_from_spec(spec)
spec.loader.exec_module(relay)

names = sorted(t["toolSpec"]["name"] for t in relay.TOOLS["tools"])
if names != ["get_fleet_status", "hand_over_to_firstmate"]:
    sys.exit("relay declares unexpected tools: %s" % names)

# The handover tool has to take the request text, or the agent can announce a
# handover it never performed.
handover = [t["toolSpec"] for t in relay.TOOLS["tools"]
            if t["toolSpec"]["name"] == "hand_over_to_firstmate"][0]
import json
schema = json.loads(handover["inputSchema"]["json"])
if schema.get("required") != ["request"]:
    sys.exit("hand_over_to_firstmate must require the request text")

# Push to talk is the default for this build and is meant to be one setting.
options = relay.parse_args(["--self-test", "x.pcm"])
if options.tail_ms <= 0:
    sys.exit("the trailing silence default must be positive; 0 is never answered")
PY
pass "the relay and the reader agree on the tool names and the handover argument"

# --- credentials -------------------------------------------------------------
#
# The relay rebuilds the model session on every turn, on purpose. Resolving AWS
# credentials belongs to the relay's start rather than to that rebuild: the
# sandbox profile's credential_process costs about a second, and a second spent
# there is a second added to the delay this whole build exists to keep honest.
# Nothing here talks to AWS; the resolver is replaced with a counter.

python3 - "$ROOT/bin" <<'PY' || fail "credential reuse"
import asyncio, datetime, sys, time
sys.path.insert(0, sys.argv[1])
import importlib.util, pathlib
spec = importlib.util.spec_from_file_location(
    "relay", str(pathlib.Path(sys.argv[1]) / "fm-voice-relay.py"))
relay = importlib.util.module_from_spec(spec)
spec.loader.exec_module(relay)

def check(cond, label):
    if not cond:
        sys.exit("credentials: " + label)

calls = []
stamp = [""]
delay = [0.0]

def iso(at):
    return datetime.datetime.fromtimestamp(at, datetime.timezone.utc).isoformat()

def fake(profile, verbose=False):
    # Whatever the profile says about expiry reaches the cache through the real
    # parser, so the fixture hands it a stamp rather than a decided answer.
    calls.append(profile)
    time.sleep(delay[0])
    return ({"aws_access_key_id": "AK%d" % len(calls)},
            relay._expires_at(stamp[0]))

relay.resolve_credentials = fake

async def take(cache, count):
    return [await cache.get() for _ in range(count)]

# Three sessions, one resolution: the second and third turns pay nothing.
cache = relay.Credentials("a-profile")
got = asyncio.run(take(cache, 3))
check(len(calls) == 1, "three sessions resolved credentials %d times" % len(calls))
check([c["aws_access_key_id"] for c in got] == ["AK1"] * 3,
      "every session should get the same credentials: %s" % got)

# A session that edits what it was handed must not edit what the next one gets.
got[0]["aws_access_key_id"] = "tampered"
check(asyncio.run(take(cache, 1))[0]["aws_access_key_id"] == "AK1",
      "one session must not be able to corrupt the shared credentials")

# Credentials with an expiry are refreshed ahead of it, because a relay left
# running outlives them and a dead credential is a dead session.
del calls[:]
stamp[0] = iso(time.time() + relay.Credentials.REFRESH_MARGIN - 1)
cache = relay.Credentials("a-profile")
asyncio.run(take(cache, 2))
check(len(calls) == 2,
      "credentials near expiry should be refreshed, resolved %d times" % len(calls))

# An expiry this interpreter cannot read is NOT an expiry that never comes. The
# credential works, its deadline does not, so it is held for the same margin and
# no longer. Read as "never expires" it would be cached past the real deadline
# and every session from then on would fail to start with no way back.
class Bounded(relay.Credentials):
    REFRESH_MARGIN = 0.05

del calls[:]
stamp[0] = "expires some time on Tuesday"
cache = Bounded("a-profile")
asyncio.run(take(cache, 2))
check(len(calls) == 1,
      "an unreadable expiry should still be reused within the margin: %d" % len(calls))
time.sleep(0.1)
asyncio.run(take(cache, 1))
check(len(calls) == 2,
      "an unreadable expiry must not be cached for the life of the relay")

# An absent expiry keeps meaning what it says: this credential does not expire.
del calls[:]
stamp[0] = ""
cache = Bounded("a-profile")
asyncio.run(take(cache, 1))
time.sleep(0.1)
asyncio.run(take(cache, 1))
check(len(calls) == 1,
      "a credential with no expiry should not be resolved again: %d" % len(calls))

# Whenever a resolution does happen it must stay off the event loop, or the
# relay stops reading the captain's audio for as long as it takes.
del calls[:]
stamp[0] = ""
delay[0] = 0.3

async def resolve_while_the_loop_runs():
    ticks = []

    async def tick():
        for _ in range(20):
            await asyncio.sleep(0.01)
            ticks.append(1)

    task = asyncio.create_task(tick())
    await relay.Credentials("slow-profile").get()
    during = len(ticks)
    task.cancel()
    return during

during = asyncio.run(resolve_while_the_loop_runs())
check(during >= 2,
      "the event loop ran %d times during a 0.3s credential resolution" % during)
PY
pass "credentials are resolved once per relay, refreshed before expiry, off the event loop"

# --- the laptop end ---------------------------------------------------------
#
# The microphone and speaker paths cannot be tested from a host with neither, and
# are not tested anywhere: the first live run is their test. What IS testable is
# everything around them, and these are the pieces whose failure is hardest to
# read from the symptom. A missing -T corrupts audio rather than erroring, and a
# banner-printing login shell desynchronises the stream in a way that looks like a
# protocol bug and is not.

python3 - "$ROOT/bin" <<'PY' || fail "laptop client"
import io, sys
sys.path.insert(0, sys.argv[1])
import importlib.util, pathlib
spec = importlib.util.spec_from_file_location(
    "client", str(pathlib.Path(sys.argv[1]) / "fm-voice-client.py"))
client = importlib.util.module_from_spec(spec)
spec.loader.exec_module(client)
import fm_voice_frame as frame

def check(cond, label):
    if not cond:
        sys.exit("client: " + label)

# Push to talk is the default for this build, and open mic is the one flip.
check(client.parse_args(["--host", "h"]).listen == client.PUSH_TO_TALK,
      "push to talk must be the default")
check(client.parse_args(["--host", "h", "--listen", "open-mic"]).listen
      == client.OPEN_MIC, "open mic must be selectable")

# The audio devices themselves cannot be reached from here, but their SELECTOR
# can be, and it is typed: sounddevice reads an int as an index into its device
# list and a str as a name to match, so an index left as text is looked up as a
# device literally called "3" and raises on the captain's first live run.
picked = client.parse_args(["--host", "h", "--input-device", "3",
                            "--output-device", "External Headphones"])
check(picked.input_device == 3 and not isinstance(picked.input_device, str),
      "a numeric device must arrive as an index: %r" % picked.input_device)
check(picked.output_device == "External Headphones",
      "a named device must stay a name: %r" % picked.output_device)
check(client.parse_args(
          ["--host", "h", "--input-device", "2 - Built-in Microphone"]
      ).input_device == "2 - Built-in Microphone",
      "a device name that begins with a digit must stay a name")
check(client.parse_args(["--host", "h"]).input_device is None,
      "no device flag must stay unset, so sounddevice picks the default")

# Over SSH: no pty, or the audio stream is silently rewritten.
argv = client.relay_command(client.parse_args(["--host", "desk"]))
check(argv[:3] == ["ssh", "-T", "desk"], "ssh must be invoked with -T: %s" % argv)
check("--serve" in argv, "the relay must be started in serve mode")

# Locally: no ssh at all, so the same client can be measured on this host.
argv = client.relay_command(client.parse_args(["--local"]))
check(argv[0] != "ssh", "--local must not invoke ssh: %s" % argv)

# The interpreter is a setting because the relay needs a virtual environment the
# system interpreter does not have.
argv = client.relay_command(client.parse_args(
    ["--host", "desk", "--relay-python", "/opt/venv/bin/python",
     "--relay-arg=--scope", "--relay-arg=counts"]))
check("/opt/venv/bin/python" in argv, "the relay interpreter must be passed: %s" % argv)
check(argv[-2:] == ["--scope", "counts"],
      "relay arguments must reach the relay: %s" % argv)

# A login shell banner is discarded with a warning naming it, not an error.
noise = b"You have mail.\n"
stream = io.BytesIO(noise + frame.MAGIC + frame.encode(frame.BYE))
client.sync_magic(stream)
check(frame.Reader(stream).read()[0] == frame.BYE,
      "the first frame after the handshake must still be readable")

# Junk with no handshake at all must be a named refusal rather than a hang.
try:
    client.sync_magic(io.BytesIO(b"x" * (client.MAX_PREAMBLE + 64)))
    sys.exit("client: accepted a stream with no handshake")
except frame.FrameError as exc:
    check("not fm-voice-relay.py" in str(exc),
          "the refusal should say what is on the far end: %s" % exc)

# A far end that dies before saying hello must say that, because the useful next
# step is running the relay command by hand.
try:
    client.sync_magic(io.BytesIO(b""))
    sys.exit("client: accepted a closed stream")
except frame.FrameError as exc:
    check("before it said hello" in str(exc),
          "the refusal should name the early close: %s" % exc)

# The two ends must agree on the sample rates, or the reply plays at the wrong
# pitch and nothing reports an error.
relay_spec = importlib.util.spec_from_file_location(
    "relay", str(pathlib.Path(sys.argv[1]) / "fm-voice-relay.py"))
relay = importlib.util.module_from_spec(relay_spec)
relay_spec.loader.exec_module(relay)
check((client.IN_RATE, client.OUT_RATE) == (relay.IN_RATE, relay.OUT_RATE),
      "the two ends disagree on the sample rates")
PY
pass "the laptop client builds the right remote command and survives a chatty login shell"

# docs/voice-relay.md tells the captain to copy exactly two files to the laptop,
# so the real property is that the client runs from a directory holding exactly
# those two and nothing else from bin/. A third local import would leave that
# instruction wrong and the laptop dying at import time, a long way from the
# change that caused it. Run there with no PYTHONPATH, so bin/ cannot supply the
# missing piece the way it does on this host.
LAPTOP="$TMP_ROOT/laptop"
mkdir -p "$LAPTOP"
cp "$ROOT/bin/fm-voice-client.py" "$ROOT/bin/fm_voice_frame.py" "$LAPTOP/"

set +e
copied_out=$(cd "$LAPTOP" && env -u PYTHONPATH python3 ./fm-voice-client.py --help 2>&1)
copied_code=$?
set -e
expect_code 0 "$copied_code" \
  "the client must start with only the two copied files: $copied_out"
assert_contains "$copied_out" 'fm-voice-client.py' \
  "the copied client should print its own usage"

# The negative half, so the case above is not passing because bin/ was reachable
# after all: without its one companion the client must fail at import and name it.
SHORT="$TMP_ROOT/laptop-missing-companion"
mkdir -p "$SHORT"
cp "$ROOT/bin/fm-voice-client.py" "$SHORT/"
set +e
short_out=$(cd "$SHORT" && env -u PYTHONPATH python3 ./fm-voice-client.py --help 2>&1)
short_code=$?
set -e
[ "$short_code" -ne 0 ] || fail "the client started without fm_voice_frame.py beside it"
assert_contains "$short_out" 'fm_voice_frame' \
  "the import failure should name the file the laptop is missing"
pass "the client runs from a laptop holding only the two files the guide names"

# --- read scope -------------------------------------------------------------

narrow=$(records_status --scope counts) || fail "counts scope failed"
assert_contains "$narrow" '"scope": "counts"' "counts scope should say so"
assert_contains "$narrow" '"in_flight": 3' "counts scope should still count in-flight work"
assert_contains "$narrow" '"queued": 2' "counts scope should still count queued work"
assert_contains "$narrow" '"awaiting_captain": 2' "counts scope should count what waits on the captain"
assert_contains "$narrow" '"open_pull_requests": 1' "counts scope should count open pull requests"
# No record free text is assembled at all at this scope, so there is nothing to
# filter and nothing to get wrong.
assert_not_contains "$narrow" 'alpha-one' "counts scope must not name work"
assert_not_contains "$narrow" 'sign-in redirect' "counts scope must not carry titles"
assert_not_contains "$narrow" 'github.com' "counts scope must not carry pull request links"
pass "the narrow scope answers how much is waiting without saying what it is"

wide=$(records_status --scope full) || fail "full scope failed"
assert_contains "$wide" '"scope": "full"' "full scope should say so"
assert_contains "$wide" 'alpha-one' "full scope should name in-flight work"
assert_contains "$wide" 'sign-in redirect' "full scope should carry titles"
assert_contains "$wide" 'https://github.com/example/alpha/pull/7' \
  "full scope should carry the pull request link"
assert_contains "$wide" 'beta-two' "full scope should name what waits on the captain"
# The state verb only. The agent speaks to the captain and must not read an
# internal event line aloud.
assert_contains "$wide" '"state": "working"' "full scope should carry the state verb"
assert_not_contains "$wide" 'reading the failing test' \
  "full scope must not carry the raw event line"
# The same rule against the bracketed shape: the verb is still the verb, and the
# metadata and the note stay unspoken.
assert_contains "$wide" '"state": "blocked"' \
  "a status line with a metadata token before the colon should still report its verb"
assert_not_contains "$wide" 'key=api-shape' \
  "full scope must not carry status metadata"
assert_not_contains "$wide" 'needs a credential' \
  "full scope must not carry the raw event line of a bracketed status"
pass "the wide scope names open work and reports state without quoting event lines"

# The default is the wide scope, because that is the access the captain granted.
default=$(records_status) || fail "default scope failed"
assert_contains "$default" '"scope": "full"' "the default read scope should be full"
pass "an absent read-scope setting means the access the captain granted"

# --- the confidentiality boundary -------------------------------------------
#
# This is the case that lets the wide scope be the default.

for scope in full counts; do
  answer=$(records_status --scope "$scope") || fail "scope $scope failed"
  assert_not_contains "$answer" "$NEVER_TOKEN" \
    "finished work and note bodies must never reach a $scope answer"
  assert_not_contains "$answer" 'old-six' \
    "finished work must not be named in a $scope answer"
  assert_not_contains "$answer" 'old-seven' \
    "an unticked line under finished work must not be named in a $scope answer"
  assert_not_contains "$answer" 'the rate we agreed' \
    "a note body must not reach a $scope answer"
  # The count is the assertion that bites if the section rule is lost: old-seven
  # is held for the captain and that list has no section filter of its own.
  assert_contains "$answer" '"awaiting_captain": 2' \
    "finished work must not be counted as waiting on the captain at $scope scope"
done
pass "finished work and note bodies never reach a spoken answer at any scope"

# The exclusion has to be structural rather than a filter on the way out, so the
# count of in-flight work stays honest while the body stays unread.
assert_contains "$wide" '"in_flight": 3' \
  "excluding note bodies must not change the count of in-flight work"
pass "excluding a note body does not distort the counts"

# --- the deny list ----------------------------------------------------------
#
# Reachable first, suppressed second. Without the first assertion the second
# proves nothing.

assert_contains "$wide" "$DENY_TOKEN" \
  "fixture is wrong: the deny marker should be reachable before it is denied"

printf '# one plain substring per line\n%s\n' "$DENY_TOKEN" \
  > "$HOME_FIXTURE/config/voice-read-deny"
denied=$(records_status --scope full) || fail "full scope with a deny list failed"
assert_not_contains "$denied" "$DENY_TOKEN" "the deny list must suppress a match"
assert_not_contains "$denied" 'gamma-three' \
  "a denied item must not be named at all"
assert_contains "$denied" '"withheld_as_confidential": 1' \
  "a denied item must still be counted so the captain knows it exists"
assert_contains "$denied" '"in_flight": 3' \
  "denying an item must not change the count of in-flight work"
# The other in-flight work is unaffected: this is a substring list, not a switch.
assert_contains "$denied" 'alpha-one' "the deny list must not suppress everything"
pass "a denied item becomes a withheld count without hiding that work exists"

# Case-insensitive, because a confidentiality list that depends on the captain
# matching the file's capitalisation is a confidentiality list that fails quietly.
printf '%s\n' "$(printf '%s' "$DENY_TOKEN" | tr '[:upper:]' '[:lower:]')" \
  > "$HOME_FIXTURE/config/voice-read-deny"
lower=$(records_status --scope full) || fail "lowercase deny list failed"
assert_not_contains "$lower" "$DENY_TOKEN" "the deny list must match regardless of case"
pass "the deny list matches regardless of case"

# The withheld figure counts denied items, not refusals, and the lists overlap by
# design: alpha-one is in flight AND carries a pull request, beta-two is in flight
# AND waiting on the captain. Counting each refusal would tell the captain four
# things are being withheld when two are, which is a wrong number spoken
# confidently about exactly the subject the captain is most careful with.
printf '%s\n%s\n' alpha-one beta-two > "$HOME_FIXTURE/config/voice-read-deny"
overlap=$(records_status --scope full) || fail "overlapping deny list failed"
assert_contains "$overlap" '"withheld_as_confidential": 2' \
  "two denied items appearing in two lists each must be withheld twice, not four times"
assert_not_contains "$overlap" 'alpha-one' "a denied item must not be named"
assert_not_contains "$overlap" 'beta-two' "a denied item must not be named"
assert_not_contains "$overlap" 'github.com' \
  "denying an item must suppress its pull request link too"
assert_contains "$overlap" '"in_flight": 3' \
  "denying items must not change the count of in-flight work"
assert_contains "$overlap" '"open_pull_requests": 1' \
  "denying items must not change the count of open pull requests"
pass "an item denied in more than one list is counted as withheld once"

rm -f "$HOME_FIXTURE/config/voice-read-deny"

# --- refusals ---------------------------------------------------------------
#
# A misconfigured read scope must stop rather than fall back to the wider one,
# because falling back would widen what is sent on the strength of a typo.

printf 'everything\n' > "$HOME_FIXTURE/config/voice-read-scope"
set +e
out=$(records_status 2>&1)
code=$?
set -e
expect_code 2 "$code" "an unknown read scope should refuse"
assert_contains "$out" 'voice-read-scope' "the refusal should name the setting"
pass "an unknown read scope refuses instead of widening"

printf 'counts\n' > "$HOME_FIXTURE/config/voice-read-scope"
configured=$(records_status) || fail "configured scope failed"
assert_contains "$configured" '"scope": "counts"' "the configured scope should be used"
rm -f "$HOME_FIXTURE/config/voice-read-scope"
pass "the configured read scope is honoured"

# --- handover ---------------------------------------------------------------
#
# The point of the boundary: real work is queued for firstmate, not done by the
# voice agent. It reuses bin/fm-inbox.sh rather than carrying a second queue.

before=$(find "$HOME_FIXTURE/state" -maxdepth 2 -name '*.note' | wc -l)
[ "$before" = 0 ] || fail "fixture should start with an empty inbox"

handed=$(FM_HOME="$HOME_FIXTURE" python3 "$ROOT/bin/fm_voice_records.py" queue \
  "Refactor the login module and open a pull request for it" \
  --home "$HOME_FIXTURE") || fail "handover failed"
assert_contains "$handed" '"queued": true' "handover should report the request queued"
assert_contains "$handed" 'did not do the work yourself' \
  "handover should tell the model it handed over rather than acted"

notes=$(find "$HOME_FIXTURE/state/inbox" -maxdepth 1 -name '*.note' | wc -l)
[ "$notes" = 1 ] || fail "handover should leave exactly one note, found $notes"
note_file=$(find "$HOME_FIXTURE/state/inbox" -maxdepth 1 -name '*.note' | head -1)
assert_grep 'Refactor the login module' "$note_file" \
  "the note should carry the captain's words"

# Exactly one wake, so a spoken request is presented once at firstmate's next
# check rather than queued twice or lost.
assert_present "$HOME_FIXTURE/state/.wake-queue" \
  "handover should wake firstmate"
wakes=$(grep -c 'inbox:' "$HOME_FIXTURE/state/.wake-queue")
[ "$wakes" = 1 ] || fail "handover should append exactly one wake, found $wakes"

# The reading half must see what the queueing half just wrote, or the agent says
# the request is queued and then, asked what is waiting, says nothing is.
paired=$(records_status --scope counts) || fail "status after a handover failed"
assert_contains "$paired" '"captain_notes_waiting": 1' \
  "the reader should count the note the handover just queued"
pass "handover queues the request for firstmate and wakes it exactly once"

# The same pairing when the state directory is moved. bin/fm-inbox.sh resolves
# ${FM_STATE_OVERRIDE:-$FM_HOME/state} and the handover queues through it with
# the ambient environment, so a reader that ignored the override would count
# notes in a directory nothing writes to.
alt_state="$TMP_ROOT/state-elsewhere"
alt_home="$TMP_ROOT/override-home"
mkdir -p "$alt_state" "$alt_home/data" "$alt_home/state"
FM_STATE_OVERRIDE="$alt_state" python3 "$ROOT/bin/fm_voice_records.py" queue \
  "Chase the flaky retry test" --home "$alt_home" >/dev/null \
  || fail "handover with an overridden state directory failed"

moved=$(find "$alt_state/inbox" -maxdepth 1 -name '*.note' | wc -l)
[ "$moved" = 1 ] || \
  fail "the queue should write into the overridden state directory, found $moved"
[ ! -e "$alt_home/state/inbox" ] || \
  fail "the queue should not have written under the home when the state is moved"

overridden=$(FM_STATE_OVERRIDE="$alt_state" python3 \
  "$ROOT/bin/fm_voice_records.py" status --home "$alt_home") \
  || fail "status with an overridden state directory failed"
assert_contains "$overridden" '"captain_notes_waiting": 1' \
  "the reader must count notes where the queue actually wrote them"
pass "the reader and the queue resolve the state directory the same way"

set +e
empty_out=$(python3 "$ROOT/bin/fm_voice_records.py" queue "   " \
  --home "$HOME_FIXTURE" 2>&1)
empty_code=$?
set -e
expect_code 2 "$empty_code" "queueing empty text should refuse"
assert_contains "$empty_out" 'empty' "the refusal should say the request was empty"
pass "an empty request is refused rather than queued as a blank note"

# --- absent records ---------------------------------------------------------
#
# A home with no records at all must answer "nothing" rather than fail, because
# the agent is spoken to and an exception is not an answer.

bare="$TMP_ROOT/bare"
mkdir -p "$bare"
bare_out=$(python3 "$ROOT/bin/fm_voice_records.py" status --home "$bare") \
  || fail "an empty home should still answer"
assert_contains "$bare_out" '"in_flight": 0' "an empty home should report no work"
assert_contains "$bare_out" '"workers_on_deck": 0' "an empty home should report no workers"
pass "a home with no records answers nothing rather than failing"

printf 'all voice relay cases passed\n'
