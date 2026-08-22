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

# A payload that never starts at all is the same fault, one byte earlier.
try:
    frame.Reader(io.BytesIO(frame.HEADER.pack(frame.AUDIO, 5))).read()
    sys.exit("frame: a header with no payload behind it was accepted")
except frame.FrameError:
    pass

# A stream cut inside the HEADER is a dropped connection too, and must NOT come
# back as the clean close checked above. A lost SSH connection does not politely
# end on a frame boundary, and a partial header read as end of input records the
# turn as unanswered with no error, which puts a transport failure into a results
# file as an ordinary turn the model did not answer.
for cut in range(1, frame.HEADER.size):
    try:
        frame.Reader(io.BytesIO(frame.encode(frame.BYE)[:cut])).read()
        sys.exit("frame: %d header bytes then EOF was read as a clean close" % cut)
    except frame.FrameError as exc:
        check("header" in str(exc),
              "a truncated header should name itself: %s" % exc)

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

# --- whose account, whose model ---------------------------------------------
#
# A region, a model id and an AWS profile name somebody's account and somebody's
# choices, so nothing here ships one. A home that has configured none of them
# cannot start the relay at all, and it is told which file to write rather than
# quietly reaching an API in somebody else's account. That configuration IS the
# opt-in, so this case is what keeps the feature off by default.

CONFIG_HOME="$TMP_ROOT/unconfigured"
mkdir -p "$CONFIG_HOME/config"

python3 - "$ROOT/bin" "$CONFIG_HOME" <<'PY' || fail "relay configuration"
import sys
sys.path.insert(0, sys.argv[1])
import importlib.util, os, pathlib
spec = importlib.util.spec_from_file_location(
    "relay", str(pathlib.Path(sys.argv[1]) / "fm-voice-relay.py"))
relay = importlib.util.module_from_spec(spec)
spec.loader.exec_module(relay)
import fm_voice_records as records

home = sys.argv[2]
for name in ("FM_VOICE_REGION", "FM_VOICE_MODEL", "FM_VOICE_PROFILE", "FM_VOICE_ID",
             "FM_CONFIG_OVERRIDE"):
    os.environ.pop(name, None)

def check(cond, label):
    if not cond:
        sys.exit("configuration: " + label)

# An unconfigured home refuses, and the refusal is the path to write.
try:
    relay.resolve_settings(relay.parse_args(["--serve", "--home", home]))
    sys.exit("configuration: an unconfigured home started the relay")
except records.RecordError as exc:
    check("voice-region" in str(exc),
          "the refusal should name the file to write: %s" % exc)
    check(home in str(exc), "and it should be this home's path: %s" % exc)

# One file at a time: the region alone is not enough to reach a model.
with open(os.path.join(home, "config", "voice-region"), "w") as handle:
    handle.write("# the region this home talks to\neu-somewhere-1\n")
try:
    relay.resolve_settings(relay.parse_args(["--serve", "--home", home]))
    sys.exit("configuration: a home with no model id started the relay")
except records.RecordError as exc:
    check("voice-model" in str(exc),
          "the refusal should name the missing model file: %s" % exc)

with open(os.path.join(home, "config", "voice-model"), "w") as handle:
    handle.write("some.model-v1:0\n")
options = relay.resolve_settings(relay.parse_args(["--serve", "--home", home]))
check(options.region == "eu-somewhere-1",
      "the configured region should be used, comment and all: %r" % options.region)
check(options.model == "some.model-v1:0",
      "the configured model should be used: %r" % options.model)
# No profile configured means ambient credentials only, which is a real choice
# rather than a missing one, so it is not a refusal.
check(options.profile == "", "an absent profile should stay empty: %r" % options.profile)
check(options.voice == relay.VOICE,
      "an absent voice should fall back to the shipped one: %r" % options.voice)

# The environment overrides a file for a single run.
os.environ["FM_VOICE_REGION"] = "eu-elsewhere-2"
os.environ["FM_VOICE_ID"] = "amy"
options = relay.resolve_settings(relay.parse_args(["--serve", "--home", home]))
check(options.region == "eu-elsewhere-2",
      "the environment should override the file: %r" % options.region)
check(options.voice == "amy", "the voice should be overridable: %r" % options.voice)

# And an explicit flag overrides both.
options = relay.resolve_settings(
    relay.parse_args(["--serve", "--home", home, "--region", "eu-flag-3"]))
check(options.region == "eu-flag-3", "a flag should win: %r" % options.region)

os.environ.pop("FM_VOICE_REGION", None)
os.environ.pop("FM_VOICE_ID", None)

# THE PROFILE IS READ BY PRESENCE, NOT BY TRUTHINESS. An empty FM_VOICE_PROFILE is
# the captain saying "use the credentials I already have", so it must not fall
# through to a configured profile and spend a second exporting from an account
# they just opted out of. fm-inbox.sh reads its own equivalent that way and
# docs/configuration.md promises it for both.
with open(os.path.join(home, "config", "voice-profile"), "w") as handle:
    handle.write("a-configured-profile\n")
options = relay.resolve_settings(relay.parse_args(["--serve", "--home", home]))
check(options.profile == "a-configured-profile",
      "a configured profile should be used: %r" % options.profile)

os.environ["FM_VOICE_PROFILE"] = ""
options = relay.resolve_settings(relay.parse_args(["--serve", "--home", home]))
check(options.profile == "",
      "an empty FM_VOICE_PROFILE must force ambient credentials: %r" % options.profile)

os.environ["FM_VOICE_PROFILE"] = "another-profile"
options = relay.resolve_settings(relay.parse_args(["--serve", "--home", home]))
check(options.profile == "another-profile",
      "a set FM_VOICE_PROFILE should override the file: %r" % options.profile)
os.environ.pop("FM_VOICE_PROFILE", None)

# An empty region, by contrast, is not a choice about anything, so it still falls
# through to the file rather than refusing.
os.environ["FM_VOICE_REGION"] = ""
options = relay.resolve_settings(relay.parse_args(["--serve", "--home", home]))
check(options.region == "eu-somewhere-1",
      "an empty region variable should fall through to the file: %r" % options.region)
os.environ.pop("FM_VOICE_REGION", None)

# --help must work in a home that has configured nothing, or the captain cannot
# read how to configure it.
PY
pass "the relay reads whose account to use from this home and refuses to guess"

set +e
help_out=$(python3 "$ROOT/bin/fm-voice-relay.py" --help 2>&1)
help_code=$?
set -e
expect_code 0 "$help_code" "--help must work with no configuration: $help_out"
assert_contains "$help_out" 'voice-region' \
  "--help should name the files a home has to write"
pass "an unconfigured home can still read how to configure the relay"

# The captain inbox is the same rule with a different consequence: note, status,
# list and drain make no model call, so they must keep working unconfigured. The
# voice handover depends on note, so that is not a nicety.
#
# EVERY FM_INBOX_ VARIABLE IS NEUTRALIZED HERE, at the harness rather than in each
# case, and the list is read out of the environment rather than written down, so a
# knob added later cannot quietly survive into a refusal case. A shell that
# exports a region and a model id would otherwise walk these cases straight past
# the refusal they assert and into a real model call: an offline suite that can
# spend the operator's credentials is worse than a failing one.
inbox_env=()
while IFS= read -r inbox_knob; do
  [ -n "$inbox_knob" ] || continue
  inbox_env+=(-u "$inbox_knob")
done < <(env | sed -n 's/^\(FM_INBOX_[A-Za-z0-9_]*\)=.*/\1/p' | sort -u)
inbox_env+=(FM_HOME="$CONFIG_HOME" FM_STATE_OVERRIDE="$CONFIG_HOME/state"
            FM_CONFIG_OVERRIDE="$CONFIG_HOME/config")

# And a stub that records any attempt, so "no model call" is a checked fact rather
# than a claim about control flow. The real aws would need credentials; this one
# leaves evidence and exits non-zero.
INBOX_FAKEBIN=$(fm_fakebin "$TMP_ROOT/inbox-fake")
AWS_CALLED="$TMP_ROOT/aws-was-called"
cat > "$INBOX_FAKEBIN/aws" <<SH
#!/usr/bin/env bash
printf 'aws %s\n' "\$*" >> "$AWS_CALLED"
exit 9
SH
chmod +x "$INBOX_FAKEBIN/aws"
inbox_env+=(PATH="$INBOX_FAKEBIN:$PATH")

set +e
ask_out=$(env "${inbox_env[@]}" "$ROOT/bin/fm-inbox.sh" ask "how is the fleet" 2>&1)
ask_code=$?
set -e
[ "$ask_code" -ne 0 ] || fail "ask ran with nothing configured"
assert_contains "$ask_out" 'inbox-region' \
  "the first refusal should name the region file: $ask_out"

# One file at a time, so each refusal names one thing to do.
printf 'eu-somewhere-1\n' > "$CONFIG_HOME/config/inbox-region"
set +e
ask_out=$(env "${inbox_env[@]}" "$ROOT/bin/fm-inbox.sh" ask "how is the fleet" 2>&1)
ask_code=$?
set -e
[ "$ask_code" -ne 0 ] || fail "ask ran without a configured model"
assert_contains "$ask_out" 'inbox-ask-model' \
  "the refusal should name the model file to write: $ask_out"

set +e
say_out=$(printf '' | env "${inbox_env[@]}" "$ROOT/bin/fm-inbox.sh" say 2>&1)
say_code=$?
set -e
[ "$say_code" -ne 0 ] || fail "say ran without a configured model"
assert_contains "$say_out" 'inbox-stt-model' \
  "the refusal should name the model file to write: $say_out"

rm -f "$CONFIG_HOME/config/inbox-region"
unconfigured_note=$(env "${inbox_env[@]}" \
  "$ROOT/bin/fm-inbox.sh" note "the handover must work with no configuration") \
  || fail "note should not need any configuration"
assert_contains "$unconfigured_note" 'queued ' "note should still queue a record"
assert_absent "$AWS_CALLED" \
  "no case above may reach a model: the aws stub recorded an attempt"
pass "the model-backed subcommands refuse by name while note keeps working"

# --help prints the whole header block, and finds where that block ends rather
# than counting lines to it, so growing the header cannot silently truncate the
# help again. The PRIVACY paragraph is the part that matters: it is the only place
# a new operator is told which subcommands send audio or text off this host, and a
# fixed line range had already dropped it.
inbox_help=$("$ROOT/bin/fm-inbox.sh" --help) || fail "fm-inbox.sh --help failed"
assert_contains "$inbox_help" 'PRIVACY:' \
  "the help must say which subcommands send anything to a model"
assert_contains "$inbox_help" 'make no network call at all' \
  "the help must name the subcommands that stay on this host"
assert_contains "$inbox_help" 'FM_HOME' \
  "the help must keep its environment section"
assert_contains "$inbox_help" 'inbox-ask-model' \
  "the help must name the files a home has to write"
assert_contains "$inbox_help" 'fm-inbox.sh note' \
  "the help must still open with the usage it always had"
pass "fm-inbox.sh --help prints its whole header, privacy paragraph included"

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
import asyncio, datetime, os, sys, time
sys.path.insert(0, sys.argv[1])
import importlib.util, pathlib
spec = importlib.util.spec_from_file_location(
    "relay", str(pathlib.Path(sys.argv[1]) / "fm-voice-relay.py"))
relay = importlib.util.module_from_spec(spec)
spec.loader.exec_module(relay)

def check(cond, label):
    if not cond:
        sys.exit("credentials: " + label)

AWS_VARS = ("AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN",
            "AWS_CREDENTIAL_EXPIRATION")

def iso(at):
    return datetime.datetime.fromtimestamp(at, datetime.timezone.utc).isoformat()

# Credentials taken from the environment cannot be refreshed in place, because
# os.environ never gets fresher values while this process runs. So they are only
# preferred while they are usable, and what decides that is the deadline the
# exporter states beside the keys. Treating one as eternal strands a long-lived
# relay: every session after the real deadline is rejected for an expired token.
for name in AWS_VARS:
    os.environ.pop(name, None)

check(relay.ambient_credentials() is None,
      "an environment with no keys must send the relay to the profile")

os.environ["AWS_ACCESS_KEY_ID"] = "AKIAEXAMPLE"
check(relay.ambient_credentials() is None,
      "a key id with no secret beside it must be refused, not indexed blindly")

os.environ["AWS_SECRET_ACCESS_KEY"] = "s3cret"
ambient = relay.ambient_credentials()
check(ambient[0]["aws_access_key_id"] == "AKIAEXAMPLE",
      "a complete environment should be used: %r" % (ambient,))
check(ambient[1] is None,
      "long-term keys, with no session token and no stated deadline, do not expire")

os.environ["AWS_SESSION_TOKEN"] = "t0ken"
check(relay.ambient_credentials()[1] is relay.EXPIRY_UNKNOWN,
      "a session token has a deadline whether or not the shell stated it")

os.environ["AWS_CREDENTIAL_EXPIRATION"] = iso(time.time() + 3600)
check(isinstance(relay.ambient_credentials()[1], float),
      "a stated deadline should be carried through as the expiry")
# The environment wins while it is usable, so this never shells out to a profile.
picked = relay.resolve_credentials("no-such-profile")
check(picked[0]["aws_session_token"] == "t0ken",
      "the environment should be preferred over the profile while it is usable")
check(picked[2] == relay.FROM_ENVIRONMENT,
      "the resolver must say where the credentials came from: %r" % (picked[2],))

os.environ["AWS_CREDENTIAL_EXPIRATION"] = iso(time.time() - 1)
check(relay.ambient_credentials() is None,
      "expired ambient credentials must send the relay to the profile instead")

os.environ["AWS_CREDENTIAL_EXPIRATION"] = iso(time.time() + 60)
check(relay.ambient_credentials(margin=300) is None,
      "ambient credentials inside the refresh margin must not start a session")
check(relay.ambient_credentials(margin=0) is not None,
      "the same credentials are still usable when no margin is asked for")

# A profile export that fails must be an ordinary exception. SystemExit would walk
# straight through the per-turn boundary in handle_uplink_frame and end the relay,
# and since credentials are resolved lazily this refusal can land mid-conversation.
class Failed:
    returncode = 1
    stdout = ""
    stderr = "The config profile (nobody) could not be found"

real_run = relay.subprocess.run
relay.subprocess.run = lambda *a, **k: Failed()
try:
    relay.profile_credentials("nobody")
    sys.exit("credentials: a failed profile export was accepted")
except relay.CredentialError as exc:
    check(isinstance(exc, Exception),
          "the refusal must be an ordinary exception, not a SystemExit")
    check("nobody" in str(exc), "the refusal should name the profile: %s" % exc)
except SystemExit:
    sys.exit("credentials: a failed profile export raised SystemExit")
finally:
    relay.subprocess.run = real_run

# No profile and no environment is also a named refusal rather than a traceback
# from inside the AWS CLI argument list.
try:
    relay.profile_credentials("")
    sys.exit("credentials: an empty profile was accepted")
except relay.CredentialError as exc:
    check("voice-profile" in str(exc),
          "the refusal should name the file to write: %s" % exc)

for name in AWS_VARS:
    os.environ.pop(name, None)

calls = []
stamp = [""]
delay = [0.0]

def fake(profile, verbose=False, margin=0, allow_ambient=True):
    # Whatever the profile says about expiry reaches the cache through the real
    # parser, so the fixture hands it a stamp rather than a decided answer.
    calls.append(profile)
    time.sleep(delay[0])
    return ({"aws_access_key_id": "AK%d" % len(calls)},
            relay._expires_at(stamp[0]), relay.FROM_PROFILE)

real_resolve = relay.resolve_credentials
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

# GIVING UP ON AMBIENT CREDENTIALS HAS TO STICK. A bound that re-reads the same
# environment is not a bound: os.environ never gets fresher values while this
# process runs, so the same stale keys would come back every time and every
# session past the real deadline would fail while a working profile went untried.
# This drives the real resolver, with only the profile export replaced.
relay.resolve_credentials = real_resolve
exports = []

def fake_profile(profile, verbose=False):
    exports.append(profile)
    return {"aws_access_key_id": "FROM-PROFILE",
            "aws_secret_access_key": "s", "aws_session_token": None}, None

real_profile = relay.profile_credentials
relay.profile_credentials = fake_profile
os.environ["AWS_ACCESS_KEY_ID"] = "AKIAENVIRONMENT"
os.environ["AWS_SECRET_ACCESS_KEY"] = "s3cret"
os.environ["AWS_SESSION_TOKEN"] = "stale-token"
os.environ.pop("AWS_CREDENTIAL_EXPIRATION", None)

cache = Bounded("a-profile")
first = asyncio.run(cache.get())
check(first["aws_session_token"] == "stale-token",
      "usable ambient credentials should be preferred: %r" % first)
check(exports == [], "the profile should not be consulted while ambient ones hold")
time.sleep(0.1)
later = [asyncio.run(cache.get()) for _ in range(3)]
check([c["aws_access_key_id"] for c in later] == ["FROM-PROFILE"] * 3,
      "past the margin the relay must ask the profile, not re-read the "
      "environment it already gave up on: %r" % later)
check(len(exports) == 1,
      "and the profile answer is then cached like any other: %d exports" % len(exports))

# WITH NO PROFILE THERE IS NOTHING TO ESCALATE TO, and a relay configured that
# way is a documented shape. Giving up on the environment there would end every
# turn from the margin onwards, with a message saying there are no credentials in
# the environment while the process is still holding them. The bound becomes a
# re-read instead: the keys may be stale, which is between AWS and whoever
# exported them, but the conversation survives.
del exports[:]
cache = Bounded("")
kept = [asyncio.run(cache.get())]
for _ in range(3):
    time.sleep(0.1)
    kept.append(asyncio.run(cache.get()))
check([c["aws_session_token"] for c in kept] == ["stale-token"] * 4,
      "a profile-free relay must keep answering from the environment: %r" % kept)
check(exports == [], "and must not try to export from a profile it does not have")

# Even a credential whose stated deadline has already passed, for the same
# reason: there is no fresher source, so refusing is a dead relay rather than a
# safer one.
os.environ["AWS_CREDENTIAL_EXPIRATION"] = iso(time.time() - 60)
cache = Bounded("")
past = asyncio.run(cache.get())
check(past["aws_session_token"] == "stale-token",
      "an expired ambient credential is still the only answer available: %r" % past)
# With a profile, that same credential is abandoned for it, as before.
cache = Bounded("a-profile")
check(asyncio.run(cache.get())["aws_access_key_id"] == "FROM-PROFILE",
      "an expired ambient credential should be abandoned when a profile exists")
os.environ.pop("AWS_CREDENTIAL_EXPIRATION", None)

# A PROFILE THAT CANNOT ANSWER must not cost the environment. Abandoning ambient
# credentials is justified by the profile answering, so it is only decided once the
# profile has: otherwise one failed export strands a relay that is still holding
# keys, and every later turn names a profile while the answer sits in os.environ.
del exports[:]

def refusing_profile(profile, verbose=False):
    exports.append(profile)
    raise relay.CredentialError(
        "could not get credentials for profile {}".format(profile))

relay.profile_credentials = refusing_profile
os.environ["AWS_ACCESS_KEY_ID"] = "AKIAENVIRONMENT"
os.environ["AWS_SECRET_ACCESS_KEY"] = "s3cret"
os.environ["AWS_SESSION_TOKEN"] = "still-held-token"
os.environ.pop("AWS_CREDENTIAL_EXPIRATION", None)

cache = Bounded("a-profile")
check(asyncio.run(cache.get())["aws_session_token"] == "still-held-token",
      "usable ambient credentials should be preferred while they hold")
kept = []
for _ in range(3):
    time.sleep(0.1)
    try:
        kept.append(asyncio.run(cache.get())["aws_session_token"])
    except relay.CredentialError:
        kept.append("CredentialError")
check(kept == ["still-held-token"] * 3,
      "a refusing profile must cost one attempt, not the conversation: %r" % kept)
check(exports, "and the profile should have been tried at least once: %r" % exports)

# An environment with nothing in it and no profile is still a named refusal, so
# this restores the real resolver rather than asking the stub to pretend.
for name in AWS_VARS:
    os.environ.pop(name, None)
relay.profile_credentials = real_profile
refused = None
try:
    asyncio.run(Bounded("").get())
except relay.CredentialError as exc:
    refused = str(exc)
check(refused is not None, "no credentials anywhere should refuse")
check("voice-profile" in refused,
      "and the refusal should name the file to write: %s" % refused)
PY
pass "credentials are resolved once per relay, refreshed before expiry, off the event loop"

# --- a turn the model refuses -----------------------------------------------
#
# The relay rebuilds the model session on every turn by design, so every turn
# reaches the model and every turn can fail on its own: a throttle, a dropped
# stream, a token that went stale between turns. That has to cost the captain one
# turn rather than the whole session, because the alternative is a traceback on
# the stderr the client inherits and a relay restarted by hand.

python3 - "$ROOT/bin" <<'PY' || fail "failed turn"
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
        sys.exit("failed turn: " + label)

class Down:
    def __init__(self):
        self.notices = []

    def send(self, kind, payload=b""):
        pass

    def send_json(self, kind, obj):
        if kind == frame.NOTICE:
            self.notices.append(obj)

class Stub:
    """A session that records what it was asked, or raises where the model would."""

    def __init__(self, raises=None):
        self.raises = raises
        self.replies = 0
        self.failed = False
        self.ended = asyncio.Event()
        self.turn = {}
        self.calls = []

    async def _step(self, name):
        self.calls.append(name)
        if self.raises is not None:
            raise self.raises

    async def talk_start(self):
        await self._step("talk_start")

    async def audio(self, pcm):
        await self._step("audio:%d" % len(pcm))

    async def talk_end(self):
        await self._step("talk_end")

options = relay.parse_args(["--serve"])

async def drive(session, items):
    down = Down()
    serving = True
    for kind, payload in items:
        session, serving = await relay.handle_uplink_frame(
            kind, payload, session, options, down)
        if not serving:
            break
    return session, serving, down

# The ordinary path is unchanged: the frames reach the session in order.
good = Stub()
session, serving, down = asyncio.run(drive(good, [
    (frame.TALK_START, b""), (frame.AUDIO, b"1234"), (frame.TALK_END, b"")]))
check(good.calls == ["talk_start", "audio:4", "talk_end"],
      "a good turn should reach the session: %s" % good.calls)
check(serving and not good.failed,
      "a good turn must not mark the session spent")
check(down.notices == [], "a good turn should not announce a failure")

# A model failure mid-turn: the captain is told what happened, the relay stays
# up, and the session is marked spent so nothing reuses a dead stream.
broken = Stub(raises=RuntimeError("ThrottlingException"))
session, serving, down = asyncio.run(drive(broken, [(frame.AUDIO, b"1234")]))
check(serving, "a failed turn must not stop the relay")
check(session is broken and broken.failed,
      "a failed session must be marked spent")
check([n["event"] for n in down.notices] == ["turn-failed"],
      "a failed turn must be announced to the client: %s" % down.notices)
check("ThrottlingException" in down.notices[0].get("error", ""),
      "the notice should name the failure: %s" % down.notices[0])

# ONCE PER TURN, not once per frame. The captain is still holding the talk key
# when the failure lands, so the rest of that press is another thirty audio
# frames, one per hundred milliseconds. The client says every notice out loud on
# stderr, so reporting each one would put ten identical lines a second in front of
# the captain while they are still speaking, and would keep calling into a session
# that is already gone.
held = Stub(raises=RuntimeError("ValidationException"))
frames = [(frame.TALK_START, b"")] + [(frame.AUDIO, b"x" * 3200)] * 30
frames.append((frame.TALK_END, b""))
session, serving, down = asyncio.run(drive(held, frames))
check(serving, "a failed turn must not stop the relay")
check(len(down.notices) == 1,
      "a failed turn must be announced once, not once per frame: %d notices"
      % len(down.notices))
check(held.calls == ["talk_start"],
      "nothing after the failure should reach the dead session: %s" % held.calls)

# And the next talk key rebuilds instead of reusing it, which is what marking it
# spent is for.
renewed = []
fresh = Stub()
real_renew = relay.renew

async def fake_renew(session, options, down):
    renewed.append(session)
    return fresh

relay.renew = fake_renew
session, serving, down = asyncio.run(drive(broken, [(frame.TALK_START, b"")]))
check(renewed == [broken], "a spent session must be replaced on the next turn")
check(session is fresh and fresh.calls == ["talk_start"],
      "the replacement session must take the turn: %s" % fresh.calls)

# A reconnect that fails is itself just a failed turn: the captain presses the
# key again rather than restarting the relay.
async def failing_renew(session, options, down):
    raise RuntimeError("EndpointConnectionError")

relay.renew = failing_renew
spent = Stub()
spent.replies = 1
session, serving, down = asyncio.run(drive(spent, [(frame.TALK_START, b"")]))
check(serving, "a failed reconnect must not stop the relay")
check(spent.failed, "a failed reconnect must leave the session spent")
check([n["event"] for n in down.notices] == ["turn-failed"],
      "a failed reconnect must be announced: %s" % down.notices)
check(spent.calls == [], "a session whose reconnect failed must not be spoken to")

# Quit still ends the loop, so the relay exits when the client says so.
session, serving, down = asyncio.run(drive(Stub(), [(frame.QUIT, b"")]))
check(not serving, "quit must end the loop")

# A reconnect that fails part way must not strand the session it was building.
# start() opens the model stream and a reader task before it sends anything, and
# the relay now survives the failure and retries, so a session left open here
# would accumulate one live stream and one live task per retry, all of them still
# writing into the shared downlink.
class Partial:
    """A session whose start fails after it would have opened the stream."""

    def __init__(self, *args):
        self.closed = 0
        self.credentials = None
        self.connect_seconds = None

    async def start(self):
        raise RuntimeError("ServiceUnavailableException")

    async def close(self):
        self.closed += 1

built = []

def make_partial(options, down, credentials):
    session = Partial()
    built.append(session)
    return session

relay.Session = make_partial
outgoing = Partial()
try:
    asyncio.run(real_renew(outgoing, options, Down()))
    sys.exit("failed turn: a failed reconnect was reported as success")
except RuntimeError:
    pass
check(len(built) == 1, "renew should have built one replacement: %d" % len(built))
check(built[0].closed == 1,
      "a session whose start failed must be closed, not stranded: %d closes"
      % built[0].closed)
PY
pass "a turn the model refuses is announced and costs one turn, not the relay"

# --- audio that arrives with no turn open ------------------------------------
#
# Both listen modes send a talk start before any audio, so audio outside a turn
# means the capture callback raced the key release and a stray chunk landed behind
# the talk end. Opening a block for it would append the captain's stray tenth of a
# second to a session that is already answering, which is the unconditional
# barge-in the per-turn reconnect exists to avoid, and would leave that block open
# so the next turn skipped its own reset and its first-audio mark.

python3 - "$ROOT/bin" "$TMP_ROOT/stray-home" <<'PY' || fail "stray audio"
import asyncio, os, sys
sys.path.insert(0, sys.argv[1])
import importlib.util, pathlib
spec = importlib.util.spec_from_file_location(
    "relay", str(pathlib.Path(sys.argv[1]) / "fm-voice-relay.py"))
relay = importlib.util.module_from_spec(spec)
spec.loader.exec_module(relay)

home = sys.argv[2]
os.makedirs(home, exist_ok=True)

def check(cond, label):
    if not cond:
        sys.exit("stray audio: " + label)

class Down:
    def send(self, kind, payload=b""):
        pass

    def send_json(self, kind, obj):
        pass

    def arm_turn(self):
        pass

    def first_audio(self):
        return None

sent = []

async def record(event):
    sent.append(event)

session = relay.Session(relay.parse_args(["--serve", "--home", home]), Down(), None)
session._send = record

# No turn open: the stray chunk goes nowhere, and no block is left behind for the
# next turn to trip over. This session has no model stream either, so anything
# that did try to open a block would raise rather than pass quietly.
asyncio.run(session.audio(b"\x01" * 3200))
check(sent == [], "audio with no turn open must not be forwarded: %r" % sent)
check(session.audio_content is None,
      "and must not leave an audio block open: %r" % session.audio_content)

# Inside a turn it flows, so the guard is about the boundary and not about audio.
asyncio.run(session.talk_start())
del sent[:]
asyncio.run(session.audio(b"\x01" * 3200))
check([next(iter(event)) for event in sent] == ["audioInput"],
      "audio inside a turn must still be forwarded: %r" % sent)

# And talk end still pads with its trailing silence before closing the block,
# which is the whole reason a push-to-talk clip gets answered at all.
del sent[:]
asyncio.run(session.talk_end())
kinds = [next(iter(event)) for event in sent]
check(kinds.count("audioInput") > 0 and kinds[-1] == "contentEnd",
      "talk end must pad with silence and then close the block: %r" % kinds)
check(session.audio_content is None, "talk end must close the block")
PY
pass "audio that arrives with no turn open is dropped, not turned into a turn"

# --- a model stream that dies while answering --------------------------------
#
# The reader task is the other place a turn can fail, and it fails in the middle
# of work: handling an event reaches back into the model to answer a tool call. A
# failure there must still tell a waiting turn the session is over, and close()
# must absorb it, because close() is the first thing renew does. Neither held
# once, and the cost was not one lost turn but every later one: the reader task
# kept its exception, close() re-raised it on every await, renew never reached
# the line that builds a replacement, and the captain heard the same failure
# forever with no way back short of restarting the relay.
#
# Releasing the waiting turn is only half of it. The client waits for a reply end
# or a notice, so a reader failure that says nothing costs the captain their whole
# timeout and leaves a record that says the turn was not answered without saying
# why. It has to be named, once, and only when it really is a failure: a stream
# that simply ends, and a stream that went away because close() asked it to, are
# both ordinary and neither may look like one.

python3 - "$ROOT/bin" "$TMP_ROOT/reader-home" <<'PY' || fail "reader failure"
import asyncio, json, os, sys
sys.path.insert(0, sys.argv[1])
import fm_voice_frame as frame
import importlib.util, pathlib
spec = importlib.util.spec_from_file_location(
    "relay", str(pathlib.Path(sys.argv[1]) / "fm-voice-relay.py"))
relay = importlib.util.module_from_spec(spec)
spec.loader.exec_module(relay)

home = sys.argv[2]
os.makedirs(home, exist_ok=True)
options = relay.parse_args(["--serve", "--home", home])

def check(cond, label):
    if not cond:
        sys.exit("reader failure: " + label)

class Down:
    def __init__(self):
        self.notices = []

    def send(self, kind, payload=b""):
        pass

    def send_json(self, kind, obj):
        self.notices.append(obj)

    def arm_turn(self):
        pass

    def first_audio(self):
        return None

class Input:
    async def send(self, chunk):
        pass

    async def close(self):
        pass

class Payload:
    def __init__(self, raw):
        self.bytes_ = raw

class Result:
    def __init__(self, raw):
        self.value = Payload(raw)

class Receiver:
    def __init__(self, raw):
        self._raw = raw

    async def receive(self):
        return None if self._raw is None else Result(self._raw)

class Stream:
    """The scripted events, and then either a clean end or a stream that is gone."""

    def __init__(self, raws, clean=False):
        self._raws = list(raws)
        self._clean = clean
        self.input_stream = Input()

    async def await_output(self):
        if not self._raws:
            if self._clean:
                return (None, Receiver(None))
            raise RuntimeError("the model stream is gone")
        return (None, Receiver(self._raws.pop(0)))

TOOL_EVENT = json.dumps({"event": {"toolUse": {
    "toolName": "no_such_tool", "toolUseId": "t-1", "content": "{}"}}}).encode()

def failures(down):
    return [n for n in down.notices if n.get("event") == "turn-failed"]

async def poison(how):
    """Break a session one of the ways the model side can break it."""
    down = Down()
    session = relay.Session(options, down, None)
    session.stream = Stream([TOOL_EVENT])
    # A turn is open and waiting for a reply, which is when this costs the most.
    session.turn["talk_end"] = 0.0
    if how == "handler":
        async def boom(event):
            raise RuntimeError("handling blew up")
        session._handle = boom
    elif how == "tool-result":
        # The real _handle and _run_tool, with the tool-result send failing: the
        # shape a dropped stream takes while the relay answers a tool call.
        async def refuse(obj):
            raise RuntimeError("the model stream is gone")
        session._send = refuse
    elif how == "drop":
        # Nothing to read and no clean end: the stream simply goes away, which is
        # what a network blip looks like from here.
        session.stream = Stream([])
    session.reader_task = asyncio.create_task(session._read_model())
    await asyncio.wait_for(session.ended.wait(), timeout=5)
    return down, session

async def one_case(how):
    """Break a session, then take the next turn over the same relay."""
    down, session = await poison(how)
    check(session.turn_done.is_set(),
          "%s: a waiting turn must be released" % how)
    check(session.failed, "%s: the session must be marked spent" % how)
    named = failures(down)
    check(len(named) == 1,
          "%s: the captain must be told once, not never and not twice: %r"
          % (how, down.notices))
    check(named[0].get("error"),
          "%s: the notice must carry the cause: %r" % (how, named[0]))
    check(session.turn.get("failed") == named[0]["error"],
          "%s: the run record must carry the same cause: %r" % (how, session.turn))

    # close() absorbs the stored failure however many times it is asked, which is
    # what lets the next turn get as far as building a replacement.
    for _ in range(3):
        await session.close()

    built = []

    class Fresh:
        def __init__(self, *args):
            self.connect_seconds = 0.02
            self.failed = False
            self.replies = 0
            self.ended = asyncio.Event()
            self.turns = 0
            built.append(self)

        async def start(self):
            pass

        async def talk_start(self):
            self.turns += 1

    real, relay.Session = relay.Session, Fresh
    try:
        used, serving = await relay.handle_uplink_frame(
            frame.TALK_START, b"", session, options, down)
    finally:
        relay.Session = real
    check(len(built) == 1,
          "%s: the next talk key must build a session: %r" % (how, built))
    check(used is built[0] and serving,
          "%s: the relay must go on serving with it: %r %r" % (how, used, serving))
    check(used.turns == 1, "%s: and give it the new turn: %r" % (how, used.turns))
    check(len(failures(down)) == 1,
          "%s: recovering must not name the turn again: %r" % (how, down.notices))

for how in ("handler", "tool-result", "drop"):
    asyncio.run(one_case(how))

# A stream that simply ends is the end of a session, not a failed turn. It is
# still said out loud, once, and it says what it is: the client is waiting on a
# turn that is not coming, and only a notice releases it, but calling it a failure
# would tell the captain something broke when the model merely finished.
async def clean_end():
    down = Down()
    session = relay.Session(options, down, None)
    session.stream = Stream([], clean=True)
    session.reader_task = asyncio.create_task(session._read_model())
    await asyncio.wait_for(session.ended.wait(), timeout=5)
    return down, session

down, ended = asyncio.run(clean_end())
check(ended.turn_done.is_set(), "a clean end must release a waiting turn too")
check(not ended.failed, "a clean end of stream is not a turn failure")
check(not failures(down),
      "and no failure should be named to the captain: %r" % (down.notices,))
check([n.get("event") for n in down.notices] == ["session-ended"],
      "a clean end must be announced once, as the end it is: %r" % (down.notices,))

# Nor is a stream that went away because close() asked it to. renew closes the
# old session on every single turn, so announcing that would put a failure notice
# in front of the captain on every ordinary turn.
async def torn_down():
    down = Down()
    session = relay.Session(options, down, None)
    gone = asyncio.Event()

    class Closer:
        async def send(self, chunk):
            pass

        async def close(self):
            # The stream goes away exactly when close() closes the input half,
            # which is the ordering every renewed turn goes through.
            gone.set()

    class Blocking:
        def __init__(self):
            self.input_stream = Closer()

        async def await_output(self):
            await gone.wait()
            raise RuntimeError("the model stream is gone")

    async def quiet(obj):
        pass

    session.stream = Blocking()
    # The real one builds an SDK event, and the SDK is deliberately not installed
    # here; what this case needs is close() getting as far as the input half.
    session._send = quiet
    session.reader_task = asyncio.create_task(session._read_model())
    await asyncio.sleep(0)
    await session.close()
    await asyncio.wait_for(session.ended.wait(), timeout=5)
    return down, session

down, closed = asyncio.run(torn_down())
check(closed.ended.is_set(), "the reader must still report the session over")
check(not closed.failed, "a deliberate close is not a turn failure")
check(not down.notices,
      "and an ordinary renew must say nothing at all: %r" % (down.notices,))
PY
pass "a failure inside the model reader costs one turn, not every later one"
pass "a reader failure is named to the captain, a clean end and a close are not"

# --- the laptop end ---------------------------------------------------------
#
# The microphone and speaker DEVICES cannot be opened on a host with neither, so
# the first live run is their test and nothing below touches audio hardware. What
# IS testable is everything around them, and these are the pieces whose failure is
# hardest to read from the symptom. A missing -T corrupts audio rather than
# erroring, and a banner-printing login shell desynchronises the stream in a way
# that looks like a protocol bug and is not. The speaker's byte accounting is
# testable as well, being arithmetic rather than device work, and is covered
# further down this block against a stub stream with the callback driven by hand.

mkdir -p "$TMP_ROOT/client-files"
printf '\0\0\0\0' > "$TMP_ROOT/client-files/clip.pcm"

python3 - "$ROOT/bin" "$TMP_ROOT/client-files" <<'PY' || fail "laptop client"
import io, os, sys, types
sys.path.insert(0, sys.argv[1])
import importlib.util, pathlib
spec = importlib.util.spec_from_file_location(
    "client", str(pathlib.Path(sys.argv[1]) / "fm-voice-client.py"))
client = importlib.util.module_from_spec(spec)
spec.loader.exec_module(client)
import fm_voice_frame as frame

TMP = sys.argv[2]

def check(cond, label):
    if not cond:
        sys.exit("client: " + label)

# Where the relay lives on the desktop is one operator's directory layout, so the
# client carries no default for it and says so rather than trying a path that
# belongs to somebody else. The refusal is checked before the variable below is
# set, because after that every other case supplies it.
os.environ.pop("FM_VOICE_RELAY", None)
try:
    client.parse_args(["--host", "desk"])
    sys.exit("client: started with no relay path at all")
except SystemExit as exc:
    check(exc.code != 0, "a missing relay path must be a refusal, not a default")

os.environ["FM_VOICE_RELAY"] = "/desktop/firstmate/bin/fm-voice-relay.py"
check(client.parse_args(["--host", "desk"]).relay
      == "/desktop/firstmate/bin/fm-voice-relay.py",
      "FM_VOICE_RELAY should supply the relay path for a whole shell")
check(client.parse_args(["--host", "desk", "--relay", "/other/relay.py"]).relay
      == "/other/relay.py", "an explicit --relay must win over the variable")

# Push to talk is the default for this build, and the only mode that runs.
check(client.parse_args(["--host", "h"]).listen == client.PUSH_TO_TALK,
      "push to talk must be the default")

# An open microphone needs to know when the captain stopped speaking, and this
# client cannot: it would open a turn and stream forever without ever marking a
# boundary. So the setting is accepted as a value and refuses at parse time,
# before any ssh connection is opened or any model session is paid for. The value
# stays in the accepted set so switching it on later is a small change.
check(client.OPEN_MIC in client.LISTEN_MODES,
      "open mic must stay a value the flag accepts")
refusal = None
try:
    client.parse_args(["--host", "h", "--listen", "open-mic"])
except SystemExit as exc:
    refusal = exc.code
check(refusal not in (None, 0),
      "open mic must refuse rather than start: %r" % (refusal,))

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

# A relay that dies after the handshake must be reported at once rather than at
# the end of the timeout. Its own one-line error is already on the captain's
# terminal, because the relay's stderr is inherited rather than piped, so the only
# thing a full timeout adds is thirty seconds of watching nothing. This is the
# likely first-run shape: the Bedrock SDK is imported inside the model session, so
# a forgotten --relay-python exits the relay after the handshake.
import time as clock
waiting = client.Client(client.parse_args(["--host", "desk", "--timeout", "5"]))
waiting.closed.set()
began = clock.monotonic()
refused = None
try:
    waiting._wait_ready()
except SystemExit as exc:
    refused = str(exc)
check(refused is not None, "a closed relay was treated as ready")
check("closed the connection" in refused,
      "the refusal should name the closed connection: %s" % refused)
check("by hand" in refused, "and should give the next step: %s" % refused)
took = clock.monotonic() - began
check(took < 2, "a closed relay should be reported at once, waited %.1fs" % took)

# Ready still wins, and a relay that says nothing at all still times out with the
# message that fits that case instead.
ready = client.Client(client.parse_args(["--host", "desk", "--timeout", "5"]))
ready.ready.set()
ready._wait_ready()

silent = client.Client(client.parse_args(["--host", "desk", "--timeout", "0.3"]))
timed_out = None
try:
    silent._wait_ready()
except SystemExit as exc:
    timed_out = str(exc)
check(timed_out is not None, "a silent relay was treated as ready")
check("never reported ready" in timed_out,
      "a silent relay should time out with its own message: %s" % timed_out)

# The uplink can die mid-session - the SSH connection drops, or the relay exits -
# and the next talk start or talk end is then a write to a dead pipe. Every frame
# a turn is made of goes through the one sender thread, so that write has to end
# the thread the same quiet way a dead audio write does. Raising instead killed
# the thread with a traceback and left the queue unserved, so each remaining run
# sat out the full timeout with nothing sending its frames and was reported as an
# unanswered turn rather than as the lost connection the downlink had already seen.
class DeadPipe:
    def __init__(self):
        self.sent = []

    def send(self, kind, payload=b""):
        self.sent.append(kind)
        raise BrokenPipeError(32, "Broken pipe")

for label, opening in (("talk start", client.START), ("talk end", client.END),
                       ("audio", b"\x00\x00")):
    sending = client.Client(client.parse_args(["--host", "desk"]))
    sending.uplink = DeadPipe()
    sending.up_q.put(opening)
    sending.up_q.put(b"\x01\x01")
    sending.up_q.put(None)
    try:
        sending._sender()
    except BaseException as exc:               # noqa: BLE001
        sys.exit("client: a broken pipe on %s killed the sender thread: %s: %s"
                 % (label, type(exc).__name__, exc))
    check(sending.uplink.sent and len(sending.uplink.sent) == 1,
          "the sender should stop at the broken pipe on %s rather than keep "
          "writing into it: %r" % (label, sending.uplink.sent))
    if opening is client.END:
        # Talk end stamps the moment it reached the wire before the write is
        # attempted, so uplink_drain_s survives a turn the connection cut short.
        check("wire_end" in sending.turn,
              "talk end must still record when it reached the wire: %r"
              % sending.turn)

# A connection that drops mid-turn does not wait for a frame boundary, so the
# downlink meets a header cut in half. That is a transport failure and the turn
# record has to say so: a run that only reports answered: false reads in
# runs.jsonl exactly like a turn the model declined, and the latency spread
# docs/voice-relay.md publishes is computed from that file.
import threading as thread_lib


class CutStream:
    """A downlink that drops mid-header once the turn is under way.

    Held closed until the client has actually opened the turn, so the cut lands
    inside the turn being measured rather than before it, which is the sequence
    a dropped SSH connection produces and the only one whose record matters.
    """

    def __init__(self, gate):
        self._gate = gate
        self._half = frame.encode(frame.BYE)[:2]
        self._at = 0

    def read(self, count):
        check(self._gate.wait(10), "the turn never opened, so nothing was cut")
        chunk = self._half[self._at:self._at + count]
        self._at += len(chunk)
        return chunk


opened = thread_lib.Event()


class GateOpeningUplink:
    """Discards the uplink and reports when the turn's first frame went out."""

    def send(self, kind, payload=b""):
        if kind == frame.TALK_START:
            opened.set()


cut = client.Client(client.parse_args(
    ["--host", "desk", "--in-file", os.path.join(TMP, "clip.pcm"),
     "--out-file", os.path.join(TMP, "reply-cut.pcm"), "--timeout", "5"]))
cut.reader = frame.Reader(CutStream(opened))
cut.uplink = GateOpeningUplink()
cut.playback = client.FilePlayback(os.path.join(TMP, "reply-cut.pcm"))
cut.capture = client.FileCapture(os.path.join(TMP, "clip.pcm"))
cut.capture.start(cut.up_q, cut.talking)
thread_lib.Thread(target=cut._sender, daemon=True).start()
thread_lib.Thread(target=cut._downlink, daemon=True).start()
cut_record = cut.take_turn(1)
cut.up_q.put(None)
cut.playback.close()

check(cut.closed.wait(10), "a cut header must end the downlink, not hang it")
check(not cut_record["answered"], "a cut connection cannot have answered: %r"
      % cut_record)
check(cut_record["relay_error"],
      "a dropped connection must be reported in the turn record rather than "
      "leaving it indistinguishable from a turn nobody answered: %r"
      % cut_record)
check("the connection was lost before this turn was answered"
      in cut_record["relay_error"],
      "and it should say the connection went before this turn had its answer, "
      "which is the half of that fault this case is: %r"
      % cut_record["relay_error"])

# The other moment a connection can go is BETWEEN two turns, during the seconds
# the client spends letting the previous answer finish. That wait is most of a
# multi-run session, so it is where a relay that dies between questions dies.
# Opening the next turn anyway cleared the failure the downlink had recorded,
# left nothing on the far end to answer it, and produced a run that came back
# after the whole reply timeout saying answered: false with relay_error: null.
# In runs.jsonl that is indistinguishable from a turn the model declined, and
# runs.jsonl is the file docs/voice-relay.md computes its latency spread from, so
# the invented turn would be averaged into a published number.
import contextlib
import json as json_lib


class ClosingStream:
    """Serves one whole turn, then closes during the wait after it.

    Both moments are released by the client reaching them rather than by a
    timer: the frames wait for the turn to open, and the close waits for the
    client to enter the inter-turn wait. So the sequence under test is the same
    on a loaded host as on an idle one.
    """

    def __init__(self, gate, waiting):
        self._gate = gate
        self._waiting = waiting
        self._reply = (
            frame.encode(frame.AUDIO, b"\x00\x00" * 1200)
            + frame.encode_json(frame.MARK, {"mark": "reply_end",
                                             "since_talk_end": 0.4,
                                             "tool_calls": 1}))
        self._at = 0

    def read(self, count):
        check(self._gate.wait(10), "the turn never opened, so nothing was served")
        if self._at >= len(self._reply):
            check(self._waiting.wait(10),
                  "fixture: the client never reached the wait between turns")
            return b""
        chunk = self._reply[self._at:self._at + count]
        self._at += len(chunk)
        return chunk


class StartGate:
    """Discards the uplink and reports when a turn's first frame went out."""

    def __init__(self, gate):
        self._gate = gate

    def send(self, kind, payload=b""):
        if kind == frame.TALK_START:
            self._gate.set()


served, waiting_between = thread_lib.Event(), thread_lib.Event()
closing = client.Client(client.parse_args(
    ["--host", "desk", "--in-file", os.path.join(TMP, "clip.pcm"),
     "--out-file", os.path.join(TMP, "reply-closing.pcm"), "--runs", "2",
     "--timeout", "2", "--audio-idle", "0.05", "--gap-seconds", "0.05"]))
closing.reader = frame.Reader(ClosingStream(served, waiting_between))
closing.uplink = StartGate(served)
closing.playback = client.FilePlayback(os.path.join(TMP, "reply-closing.pcm"))
closing.capture = client.FileCapture(os.path.join(TMP, "clip.pcm"))
closing.capture.start(closing.up_q, closing.talking)
thread_lib.Thread(target=closing._sender, daemon=True).start()
thread_lib.Thread(target=closing._downlink, daemon=True).start()

# The wait between turns is the seam: the connection goes while the client is
# inside it, after the first run was reported and before the second could open.
# Waiting for the downlink to see it keeps that ordering exact rather than
# leaving it to whichever thread the scheduler runs next.
finish_wait = closing._let_reply_finish


def lose_connection_while_waiting(record):
    waiting_between.set()
    check(closing.closed.wait(10),
          "fixture: the connection never closed during the wait between turns")
    return finish_wait(record)


closing._let_reply_finish = lose_connection_while_waiting
emitted, spoken = io.StringIO(), io.StringIO()
with contextlib.redirect_stdout(emitted), contextlib.redirect_stderr(spoken):
    closing_code = closing.run()
closing.up_q.put(None)
closing.playback.close()

closing_runs = [json_lib.loads(line) for line in emitted.getvalue().splitlines()
                if line.strip()]
check(len(closing_runs) == 1,
      "a connection lost between turns must end the session rather than invent a "
      "turn nobody took: %d run(s) reported, %r" % (len(closing_runs), closing_runs))
check(closing_runs[0]["answered"] and closing_runs[0]["relay_error"] is None,
      "fixture is wrong: the turn before the connection went should be a good "
      "one, so the case cannot pass on a run that failed anyway: %r"
      % closing_runs[0])
# Two runs were asked for and one was taken, so the exit code has to be the
# unhappy one; a session that stops early while reporting success is a
# measurement someone reads as complete.
check(closing_code != 0,
      "a session that took 1 of 2 runs must not exit 0, got %r" % closing_code)
check("the connection ended before run 2 of 2" in spoken.getvalue(),
      "and the captain should be told why it stopped, in the words the path that "
      "stopped it recorded: %r" % spoken.getvalue())

# The case above is the connection going while the run loop is watching for it.
# The loop cannot only be watching, though: the downlink names the failure and
# marks the connection closed, and a loop that decides by reading the mark alone
# is blind for as long as those are two separate writes - the connection is gone,
# the failure is on the record, and the check has already passed. So the decision
# belongs where the turn is opened, under the lock both writes are made under.
# With the connection already gone, opening the turn anyway erased the failure the
# downlink had recorded, pushed talk-start into a dead pipe, and printed a run
# that waited out the whole reply timeout as answered: false with relay_error:
# null - the invented turn this whole seam exists to keep out of runs.jsonl.
class LostStream:
    """A downlink that is already gone the first time it is read."""

    def read(self, count):
        raise OSError(104, "Connection reset by peer")


class CountingUplink:
    """Accepts frames and remembers which kinds were pushed at it."""

    def __init__(self):
        self.sent = []

    def send(self, kind, payload=b""):
        self.sent.append(kind)


gone = client.Client(client.parse_args(
    ["--host", "desk", "--in-file", os.path.join(TMP, "clip.pcm"),
     "--out-file", os.path.join(TMP, "reply-gone.pcm"), "--runs", "2",
     "--timeout", "2", "--audio-idle", "0.05", "--gap-seconds", "0.05"]))
gone.reader = frame.Reader(LostStream())
gone.uplink = CountingUplink()
gone.playback = client.FilePlayback(os.path.join(TMP, "reply-gone.pcm"))
gone.capture = client.FileCapture(os.path.join(TMP, "clip.pcm"))
gone.capture.start(gone.up_q, gone.talking)
thread_lib.Thread(target=gone._sender, daemon=True).start()
# Run to completion in this thread rather than in a started one: the connection
# is gone before the first read returns, so the whole downlink is over by the
# time run() begins and there is no ordering left for the scheduler to decide.
gone._downlink()
check(gone.closed.is_set(),
      "fixture: a connection lost on the first read must leave the client closed")

gone_out, gone_said = io.StringIO(), io.StringIO()
with contextlib.redirect_stdout(gone_out), contextlib.redirect_stderr(gone_said):
    gone_code = gone.run()
gone.up_q.put(None)
gone.playback.close()

gone_runs = [json_lib.loads(line) for line in gone_out.getvalue().splitlines()
             if line.strip()]
check(gone_runs == [],
      "a turn must not be opened on a connection already known gone, and no run "
      "reported for one that never opened: %r" % gone_runs)
check(gone.uplink.sent == [],
      "and nothing should be pushed into the dead pipe: %r" % gone.uplink.sent)
check(gone_code != 0,
      "a session that took none of its 2 runs must not exit 0, got %r" % gone_code)
check("the connection was lost before run 1 of 2" in gone_said.getvalue(),
      "and the captain should be told why nothing was taken, naming the run it "
      "stopped at and the cause the read that failed recorded: %r"
      % gone_said.getvalue())

# The third moment is a connection that goes DURING a turn that answered anyway,
# with runs still to take. The answer is real and its record stands, so nothing
# here is a turn failure; what must not happen is the session ending quietly on a
# happy exit code, because two of the three runs asked for are missing and a
# runs.jsonl short of its runs, reported as success, is read later as the whole
# measurement. Refusing the next turn is the one place a closed connection stops
# a session, so it reports the same way wherever the connection went.
class EndingStream:
    """Serves one whole turn, then reports end of file without waiting."""

    def __init__(self, gate):
        self._gate = gate
        self._reply = (
            frame.encode(frame.AUDIO, b"\x00\x00" * 1200)
            + frame.encode_json(frame.MARK, {"mark": "reply_end",
                                             "since_talk_end": 0.4,
                                             "tool_calls": 0}))
        self._at = 0

    def read(self, count):
        check(self._gate.wait(10), "the turn never opened, so nothing was served")
        chunk = self._reply[self._at:self._at + count]
        self._at += len(chunk)
        return chunk


ending_served = thread_lib.Event()
ending = client.Client(client.parse_args(
    ["--host", "desk", "--in-file", os.path.join(TMP, "clip.pcm"),
     "--out-file", os.path.join(TMP, "reply-ending.pcm"), "--runs", "3",
     "--timeout", "2", "--audio-idle", "0.05", "--gap-seconds", "0.05"]))
ending.reader = frame.Reader(EndingStream(ending_served))
ending.uplink = StartGate(ending_served)
ending.playback = client.FilePlayback(os.path.join(TMP, "reply-ending.pcm"))
ending.capture = client.FileCapture(os.path.join(TMP, "clip.pcm"))
ending.capture.start(ending.up_q, ending.talking)
thread_lib.Thread(target=ending._sender, daemon=True).start()
thread_lib.Thread(target=ending._downlink, daemon=True).start()

# The end of file lands inside the first turn, so it is already seen by the time
# the wait after that turn begins. Confirming it here rather than trusting the
# timing keeps the sequence exact on a loaded host as well as an idle one.
finish_after_end = ending._let_reply_finish


def confirm_ended_then_wait(record):
    check(ending.closed.wait(10),
          "fixture: the end of file never reached the client during the turn")
    return finish_after_end(record)


ending._let_reply_finish = confirm_ended_then_wait
ending_out, ending_said = io.StringIO(), io.StringIO()
with contextlib.redirect_stdout(ending_out), contextlib.redirect_stderr(ending_said):
    ending_code = ending.run()
ending.up_q.put(None)
ending.playback.close()

ending_runs = [json_lib.loads(line) for line in ending_out.getvalue().splitlines()
               if line.strip()]
check(len(ending_runs) == 1,
      "one turn was served, so exactly one run belongs in the file: %d, %r"
      % (len(ending_runs), ending_runs))
check(ending_runs[0]["answered"] and ending_runs[0]["relay_error"] is None,
      "an answered turn whose connection then ended cleanly is not a turn "
      "failure, and its record stands: %r" % ending_runs[0])
check(ending_code != 0,
      "but a session that took 1 of 3 runs must not exit 0, got %r" % ending_code)
check("run 2 of 3" in ending_said.getvalue(),
      "and it should name the run it stopped at: %r" % ending_said.getvalue())

# The case above is the connection ending AFTER a turn was answered, which is the
# negative case: nothing broke inside a turn, so nothing is named. The three
# below are the same three endings landing INSIDE a turn, while it is still
# waiting for its reply, and there each of them has to name itself.
#
# None of them raises. frame.Writer sends whole frames and the relay spends
# almost all of a turn awaiting the model, so a relay killed mid-turn - SIGKILL,
# the host going, the SSH connection dropping between frames - ends its stdout on
# a frame boundary. Reader then reads nothing at all where a header should start
# and reports end of input by design. A goodbye is the same shape by another
# route: the relay sends one from its own teardown after a fault. Released with
# no reason recorded, both come back as answered: false with relay_error: null,
# which in runs.jsonl is the shape of a turn the model declined, and runs.jsonl
# is the file docs/voice-relay.md computes its published latency spread from. An
# infrastructure failure averaged into that number is the whole thing being kept
# out of it.
class ScriptedStream:
    """Serves prepared downlink bytes, held until the turn under test has opened.

    One class for every case below, because each of them differs only in the bytes
    it serves: the gate and the slicing are the same everywhere, and an empty
    script is what an end of stream at a frame boundary looks like. The label is
    per case so a fixture that never fires still names which case it belonged to.

    What happens once the script is spent is the one thing a case may choose, and
    the default is the clean end of stream every case but one wants. at_end takes
    a callable for the case that needs the other shape a dropped link has, a reset
    rather than a close, which reaches the client as a raised error instead of an
    empty read.
    """

    def __init__(self, gate, payload, label, at_end=None):
        self._gate = gate
        self._bytes = payload
        self._label = label
        self._at_end = at_end
        self._at = 0

    def read(self, count):
        check(self._gate.wait(10),
              "the turn never opened, so %s was never served" % self._label)
        if self._at >= len(self._bytes) and self._at_end is not None:
            self._at_end()
        chunk = self._bytes[self._at:self._at + count]
        self._at += len(chunk)
        return chunk


RELAY_REASON = "FrameError: unknown frame kind: b'\\xff'"
REPLY_END = frame.encode_json(frame.MARK, {"mark": "reply_end",
                                           "since_talk_end": 0.4,
                                           "tool_calls": 0})


def wire_client(args, reader, uplink, playback=None, start=True):
    """Build a client wired to stand-ins for both its ends, threads running.

    The same seven lines were written out at every case below. playback defaults to
    a file at whatever --out-file the arguments name, which is what most of them
    want; a case needing a playback of its own passes one. start=False is for the
    one case that has to arrange something before the threads may read.
    """
    wired = client.Client(client.parse_args(args))
    wired.reader = frame.Reader(reader)
    wired.uplink = uplink
    wired.playback = (client.FilePlayback(wired.options.out_file)
                      if playback is None else playback)
    wired.capture = client.FileCapture(os.path.join(TMP, "clip.pcm"))
    wired.capture.start(wired.up_q, wired.talking)
    if start:
        thread_lib.Thread(target=wired._sender, daemon=True).start()
        thread_lib.Thread(target=wired._downlink, daemon=True).start()
    return wired


def turn_lost(label, make_stream, out_name, runs="1"):
    """Take one turn against a downlink that ends during it, and return run and stderr."""
    gate = thread_lib.Event()
    lost = wire_client(
        ["--host", "desk", "--in-file", os.path.join(TMP, "clip.pcm"),
         "--out-file", os.path.join(TMP, out_name), "--runs", runs,
         "--timeout", "2", "--audio-idle", "0.05"],
        make_stream(gate), StartGate(gate))
    out, said = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(said):
        code = lost.run()
    lost.up_q.put(None)
    lost.playback.close()
    runs = [json_lib.loads(line) for line in out.getvalue().splitlines()
            if line.strip()]
    # The record is still emitted: the turn was taken and it really did go
    # unanswered, so dropping it would hide the failure instead of naming it.
    check(len(runs) == 1,
          "%s: the turn was taken, so its run belongs in the file: %d, %r"
          % (label, len(runs), runs))
    check(not runs[0]["answered"],
          "%s: fixture is wrong, the turn was answered after all: %r"
          % (label, runs[0]))
    check(code != 0, "%s: an unanswered turn must not exit 0, got %r"
          % (label, code))
    check(runs[0]["relay_error"],
          "%s: a turn lost to the connection must say so rather than reading in "
          "runs.jsonl exactly like a turn the model declined: %r"
          % (label, runs[0]))
    # With one run asked for, the run loop never reaches its "and the rest were
    # not taken" line. A record on stdout and silence on stderr is a captain who
    # spoke, heard nothing back, and was told nothing either; the module docstring
    # puts everything human on stderr.
    check("client:" in said.getvalue(),
          "%s: the captain must be told the connection went, not only the file: "
          "%r" % (label, said.getvalue()))
    return runs[0], said.getvalue()


eof_run, eof_said = turn_lost(
    "end of stream",
    lambda gate: ScriptedStream(gate, b"", "the end of stream"),
    "reply-eof.pcm")
check("ended" in eof_run["relay_error"],
      "an end of stream should say the connection ended: %r"
      % eof_run["relay_error"])
check("the connection ended" in eof_said,
      "and should say so on stderr as well: %r" % eof_said)

# A goodbye nobody asked for. This end sent no quit, so the relay stopping is the
# relay's own decision, and mid-turn it costs the captain their question.
bye_run, bye_said = turn_lost(
    "goodbye",
    lambda gate: ScriptedStream(gate, frame.encode(frame.BYE), "the goodbye"),
    "reply-bye.pcm")
check("the relay stopped" in bye_run["relay_error"],
      "a goodbye nobody asked for mid-turn should say the relay stopped, because "
      "that is the relay deciding rather than the connection dying: %r"
      % bye_run["relay_error"])
# Distinct from the line above, because they are distinct faults: a stream that
# stopped, versus a relay that chose to stop. One line for both would send the
# captain looking for the wrong thing.
check("stopped without being asked" in bye_said
      and "the connection ended" not in bye_said,
      "a goodbye should name itself on stderr rather than borrowing the wording "
      "of an ended stream: %r" % bye_said)

# And when the relay does name the fault, its words are what the record carries.
# This end can only infer that a goodbye arrived; the relay knows what happened,
# so a reason it sent is never replaced by one inferred here.
named_run, _ = turn_lost(
    "named fault",
    lambda gate: ScriptedStream(
        gate,
        frame.encode_json(frame.NOTICE,
                          {"event": "turn-failed", "error": RELAY_REASON})
        + frame.encode(frame.BYE),
        "the named fault"),
    "reply-named.pcm")
check(named_run["relay_error"] == RELAY_REASON,
      "the relay's own reason must reach the record unchanged rather than being "
      "overwritten by the goodbye behind it: %r" % named_run["relay_error"])

# THE MIDDLE OF THE SCENARIO, which the cases above and below both miss. A relay
# killed mid-turn ends its stdout on a frame boundary, and it spends nearly the
# whole turn streaming a reply, so dying AFTER some of that reply has played is
# the likelier half of the very fault this work exists to name. The cases above
# cover dying before any of it, and the answered-turn case below covers a reply
# that finished, so nothing pinned the middle.
#
# In the middle both halves of the record are true at once and must say so: sound
# reached the captain, so the turn was answered and first_audio_s measures when,
# AND the answer stopped partway, so the reason has to say the reply did not
# finish rather than that the turn was never answered. A record asserting both
# "answered" and "before this turn was answered" sends whoever reads it to the
# wrong end. At the default of one run this also used to clear every path to a
# non-zero exit code and report the session a success.
SOME_REPLY = frame.encode(frame.AUDIO, b"\x00\x00" * 1200)
SESSION_ENDED = frame.encode_json(frame.NOTICE, {"event": "session-ended"})


def turn_cut(label, payload, out_name, at_end=None):
    """Take one turn, at the default run count, against a scripted downlink."""
    gate = thread_lib.Event()
    cut = wire_client(
        ["--host", "desk", "--in-file", os.path.join(TMP, "clip.pcm"),
         "--out-file", os.path.join(TMP, out_name),
         "--timeout", "2", "--audio-idle", "0.05"],
        ScriptedStream(gate, payload, label, at_end), StartGate(gate))
    out, said = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(said):
        code = cut.run()
    cut.up_q.put(None)
    cut.playback.close()
    records = [json_lib.loads(line) for line in out.getvalue().splitlines()
               if line.strip()]
    check(len(records) == 1,
          "%s: one turn was taken, so one record belongs in the file: %r"
          % (label, records))
    check(cut.options.runs == 1,
          "%s: fixture is wrong, this case is about the default run count: %r"
          % (label, cut.options.runs))
    return records[0], said.getvalue(), code


for label, payload, subject in (
        ("end of stream", b"", "the connection ended"),
        ("relay stopped", frame.encode(frame.BYE), "the relay stopped"),
        ("session ended", SESSION_ENDED, "the relay ended the session")):
    slug = label.replace(" ", "-")
    # No audio at all. This half keeps the wording it already had, so the two can
    # never be collapsed back into one sentence that fits neither.
    silent, _, silent_code = turn_cut(
        "%s, nothing played" % label, payload, "reply-silent-%s.pcm" % slug)
    check(not silent["answered"] and silent["reply_audio_seconds"] == 0,
          "%s: fixture is wrong, this half is the one where nothing played: %r"
          % (label, silent))
    check(silent["relay_error"] == "%s before this turn was answered" % subject,
          "%s: a turn that got no audio went unanswered and the reason should say "
          "so: %r" % (label, silent["relay_error"]))
    check(silent_code != 0,
          "%s: an unanswered turn must not exit 0, got %r" % (label, silent_code))

    # Some of the reply played, then the same ending. Same fault, different turn,
    # and the record has to describe the turn it actually got.
    partial, _, partial_code = turn_cut(
        "%s, part of a reply played" % label, SOME_REPLY + payload,
        "reply-partial-%s.pcm" % slug)
    check(partial["answered"] and partial["reply_audio_seconds"] > 0,
          "%s: audio reached the captain, so the turn was answered: %r"
          % (label, partial))
    check(partial["first_audio_s"] is not None,
          "%s: and when it reached them is a real measurement, not a null: %r"
          % (label, partial))
    check(partial["relay_error"] == "%s before the reply finished" % subject,
          "%s: a reply cut short must say the reply did not finish: %r"
          % (label, partial["relay_error"]))
    check("before this turn was answered" not in partial["relay_error"],
          "%s: and must not claim nothing arrived, which its own answered field "
          "contradicts: %r" % (label, partial["relay_error"]))
    # The record and the exit code have to agree with each other as well.
    check(partial_code != 0,
          "%s: a record naming a fault must not exit 0, even at the default of "
          "one run and even though the turn was answered, got %r"
          % (label, partial_code))

# THE FOURTH SUBJECT, and the one a real captain is likeliest to meet. The three
# above all reach the client as an orderly end: a close, a goodbye frame, or a
# notice. A dropped SSH link is a reset instead, which arrives as a raised error
# from the read rather than as anything the far end chose to send, and that is a
# separate path in the downlink from all three. It has to tell the same two halves
# apart, because the fault is no different from the captain's side.
#
# Its never-played half is the cut-header case far above, which pins the other
# wording, so this is the half that was missing.


def a_reset():
    raise OSError(104, "Connection reset by peer")


reset, _, reset_code = turn_cut(
    "reset, part of a reply played", SOME_REPLY, "reply-partial-reset.pcm",
    at_end=a_reset)
check(reset["answered"] and reset["reply_audio_seconds"] > 0,
      "a reset after some of the reply played still reached the captain, so the "
      "turn was answered: %r" % reset)
check(reset["first_audio_s"] is not None,
      "and when it reached them is a real measurement, not a null: %r" % reset)
check(reset["relay_error"].startswith(
          "the connection was lost before the reply finished"),
      "a reply cut short by a reset must say the reply did not finish, the same "
      "as one cut short by a close: %r" % reset["relay_error"])
check("before this turn was answered" not in reset["relay_error"],
      "and must not claim nothing arrived, which its own answered field "
      "contradicts: %r" % reset["relay_error"])
# The clause is what the reader acts on and the detail is what tells a reset from
# a header cut in half, so neither may be lost to the other.
check("Connection reset by peer" in reset["relay_error"],
      "and must still carry what the kernel said, which is the only thing that "
      "tells a reset from a truncated frame: %r" % reset["relay_error"])
check(reset_code != 0,
      "a record naming a fault must not exit 0, even at the default of one run "
      "and even though the turn was answered, got %r" % reset_code)

# THE OTHER SIDE OF THE SAME LINE, and the complement of the answered case further
# up this block. Those cases are faults that landed while the turn was still owed
# an answer. These two land AFTER the answer was complete, in the gap between the
# reply_end mark arriving and the record being copied, which the client spends
# waiting for the reply audio to go quiet. A turn answered in full must carry no
# reason and must not fail the session, whichever path the late fault takes: an
# end of stream and a reset differ only in what the kernel delivered, and one relay
# death must not produce two different exit codes depending on which it was.
#
# Gated at both ends rather than timed. The fault cannot be delivered until the
# client has passed the reply_end wait, and the record cannot be copied until the
# downlink has marked the connection finished with, which it does only after the
# fault has been applied. Nothing here sleeps and nothing races.
class RaisingAfterReply:
    """Serves one whole answer, then raises once the record window is open."""

    def __init__(self, gate, window):
        self._gate = gate
        self._window = window
        self._bytes = frame.encode(frame.AUDIO, b"\x00\x00" * 1200) + REPLY_END
        self._at = 0

    def read(self, count):
        check(self._gate.wait(10), "the turn never opened, so nothing was served")
        if self._at < len(self._bytes):
            chunk = self._bytes[self._at:self._at + count]
            self._at += len(chunk)
            return chunk
        check(self._window.wait(10),
              "fixture: the record window never opened, so nothing raced it")
        raise OSError(104, "Connection reset by peer")


class FailingAfterReply:
    """Serves one whole answer, then a named turn failure in that same window."""

    def __init__(self, gate, window):
        self._gate = gate
        self._window = window
        self._reply = frame.encode(frame.AUDIO, b"\x00\x00" * 1200) + REPLY_END
        self._late = frame.encode_json(
            frame.NOTICE, {"event": "turn-failed",
                           "error": "the model stream dropped"})
        self._at = 0
        self._late_at = 0

    def read(self, count):
        check(self._gate.wait(10), "the turn never opened, so nothing was served")
        if self._at < len(self._reply):
            chunk = self._reply[self._at:self._at + count]
            self._at += len(chunk)
            return chunk
        check(self._window.wait(10),
              "fixture: the record window never opened, so nothing raced it")
        if self._late_at < len(self._late):
            chunk = self._late[self._late_at:self._late_at + count]
            self._late_at += len(chunk)
            return chunk
        # The notice is handled before this read is reached again, and the end of
        # stream behind it is what marks the connection finished with, which is the
        # gate the record waits on below.
        return b""


def fault_after_answer(label, make_stream, out_name):
    """Answer one turn in full, then land a fault before the record is copied."""
    gate, window = thread_lib.Event(), thread_lib.Event()
    after = wire_client(
        ["--host", "desk", "--in-file", os.path.join(TMP, "clip.pcm"),
         "--out-file", os.path.join(TMP, out_name),
         "--timeout", "2", "--audio-idle", "0.05"],
        make_stream(gate, window), StartGate(gate))
    quiet_wait = after._wait_audio_quiet

    def open_the_window(deadline):
        window.set()
        quiet_wait(deadline)
        # take_turn copies the record on the line after this returns, so the fault
        # has to be in before it. closed is the downlink's own mark that it has
        # finished with the connection and it is set only after the fault has been
        # applied, which makes it the gate rather than any elapsed time.
        check(after.closed.wait(10),
              "%s: fixture: the late fault never landed before the record"
              % label)

    after._wait_audio_quiet = open_the_window
    out, said = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(said):
        code = after.run()
    after.up_q.put(None)
    after.playback.close()
    records = [json_lib.loads(line) for line in out.getvalue().splitlines()
               if line.strip()]
    check(len(records) == 1,
          "%s: one turn was answered, so one record belongs in the file: %r"
          % (label, records))
    check(after.options.runs == 1,
          "%s: fixture is wrong, this case is about the default run count: %r"
          % (label, after.options.runs))
    check(records[0]["answered"] and records[0]["reply_audio_seconds"] > 0,
          "%s: fixture is wrong, the whole reply should have arrived: %r"
          % (label, records[0]))
    check(records[0]["relay_error"] is None,
          "%s: a turn answered in full must carry no reason, whatever arrived "
          "afterwards: %r" % (label, records[0]["relay_error"]))
    check(code == 0,
          "%s: and a session that delivered its answer must exit 0, got %r"
          % (label, code))
    return said.getvalue()


# The read-failure path: a reset rather than a clean end of stream.
rst_said = fault_after_answer(
    "a reset after the answer", RaisingAfterReply, "reply-rst.pcm")
# The guard is on the record and nothing else, so the captain is still told.
check("connection lost" in rst_said,
      "the connection going is still said on stderr, only not recorded against a "
      "turn it did not cost: %r" % rst_said)

# The relay fail_turn path: its own model stream broke, after this turn's answer.
failed_said = fault_after_answer(
    "a named relay failure after the answer", FailingAfterReply,
    "reply-late-fail.pcm")
check("could not finish that turn" in failed_said,
      "the relay's own words are still said on stderr for the same reason: %r"
      % failed_said)

# With runs still to take, the loop also has to say why they were not taken, and
# that line has to restate the cause that was recorded rather than asserting a
# default. Told "the relay stopped" and then "the connection closed", the captain
# has been given two causes for one event and has to guess which end to look at.
for label, payload, expected in (
        ("end of stream", b"", "the connection ended"),
        ("goodbye", frame.encode(frame.BYE),
         "the relay stopped without being asked to")):
    _, stopped_said = turn_lost(
        "%s, runs remaining" % label,
        lambda gate, payload=payload, label=label: ScriptedStream(
            gate, payload, "the %s" % label),
        "reply-stop-%s.pcm" % label.replace(" ", "-"), runs="2")
    check("%s before run 2 of 2" % expected in stopped_said,
          "the run loop should restate the recorded cause for %s: %r"
          % (label, stopped_said))
    check("the connection closed" not in stopped_said,
          "and must not fall back to the default wording for %s: %r"
          % (label, stopped_said))

# A fault on THIS end, handling a reply that did arrive. The try in the downlink
# used to cover only the read, so the output file refusing the audio, or a payload
# that is not the JSON the wire format promises, killed the reader thread outright
# with the connection neither marked closed nor released. run() then opened every
# remaining turn, each waiting out the whole timeout and printing answered false
# with no reason, so ONE fault cost the session instead of one turn.
#
# The reason it records must also be the right reason: the connection here is
# perfectly healthy, and a record or a message blaming it sends whoever reads it
# to the wrong end of a working link.
class FullDiskPlayback(client.FilePlayback):
    """Refuses reply audio the way a filesystem with nothing left does."""

    def write(self, pcm, turn):
        raise OSError(28, "No space left on device")


handling_served = thread_lib.Event()
handling = wire_client(
    ["--host", "desk", "--in-file", os.path.join(TMP, "clip.pcm"),
     "--out-file", os.path.join(TMP, "reply-handling.pcm"), "--runs", "2",
     "--timeout", "2", "--audio-idle", "0.05", "--gap-seconds", "0.05"],
    ScriptedStream(handling_served, frame.encode(frame.AUDIO, b"\x00\x00" * 600),
                   "the one reply frame"),
    StartGate(handling_served),
    FullDiskPlayback(os.path.join(TMP, "reply-handling.pcm")))
handling_out, handling_said = io.StringIO(), io.StringIO()
with contextlib.redirect_stdout(handling_out), \
        contextlib.redirect_stderr(handling_said):
    handling_code = handling.run()
handling.up_q.put(None)
handling.playback.close()
handling_said = handling_said.getvalue()

handling_runs = [json_lib.loads(line)
                 for line in handling_out.getvalue().splitlines() if line.strip()]
# One fault, one lost turn. The reader surviving is the whole point: without it
# the second run opens as well and burns another whole timeout for nothing.
check(len(handling_runs) == 1,
      "a fault handling a reply must stop the session rather than opening every "
      "remaining turn: %d run(s), %r" % (len(handling_runs), handling_runs))
check(not handling_runs[0]["answered"],
      "the audio never reached the file, so the turn was not answered: %r"
      % handling_runs[0])
check(handling_runs[0]["relay_error"],
      "a fault this end could name must not be recorded as a turn that merely "
      "went unanswered: %r" % handling_runs[0])
check("No space left on device" in handling_runs[0]["relay_error"],
      "the record should carry what actually raised: %r"
      % handling_runs[0]["relay_error"])
# The overriding rule: a wrong cause is worse than a missing one.
check("connection" not in handling_runs[0]["relay_error"],
      "the connection was never lost here, so the record must not say it was: %r"
      % handling_runs[0]["relay_error"])
handling_lines = [line for line in handling_said.splitlines()
                  if line.startswith("client:")]
check(not any("connection" in line for line in handling_lines),
      "and the captain must not be sent to a connection that is working: %r"
      % handling_lines)
check("No space left on device" in handling_said
      and "run 2 of 2" in handling_said,
      "the run loop should name the real reason and the run it stopped at: %r"
      % handling_said)
# The one line is what the captain and the record get. The traceback is what
# whoever has to find the bug behind it gets, and before the guard existed a dying
# thread printed one, so losing it would make a programming error in the frame
# handling strictly harder to locate than it used to be.
check("Traceback (most recent call last)" in handling_said,
      "a fault this end raised should still leave its traceback on stderr: %r"
      % handling_said)
check("Traceback" not in (handling_runs[0]["relay_error"] or ""),
      "but the record is machine read, so the one-line reason belongs there: %r"
      % handling_runs[0]["relay_error"])
check(handling_code != 0,
      "a session that took none of its runs must not exit 0, got %r"
      % handling_code)

# The other end of the same handler: reply audio that arrives after THIS end has
# released the output. close() joins the downlink at five seconds while the relay
# teardown it waits on can take up to ten, so the join can expire with audio still
# in flight, and the chunk behind it then met a closed file. That raised into the
# guard above and printed its fault line and a full traceback on a session that
# answered its turn and exited 0, which is an alarm firing on success: the reader
# learns to skip the line, and the real one is then invisible too. The connection
# was never the problem either, so it was a wrong cause as well as a false one.
#
# Driven through the events the client itself reaches, not a sleep: the turn is
# answered and recorded, the output is released exactly as close() releases it, and
# only then is the late chunk let through.
class LateAudioStream:
    """Serves one whole answer, then one more chunk once the output is released."""

    def __init__(self, opened, released):
        self._opened = opened
        self._released = released
        self._reply = frame.encode(frame.AUDIO, b"\x00\x00" * 1200) + REPLY_END
        self._late = frame.encode(frame.AUDIO, b"\x00\x00" * 1200)
        self._at = 0
        self._late_at = 0
        self._never = thread_lib.Event()

    def read(self, count):
        check(self._opened.wait(10), "the turn never opened, so nothing was served")
        if self._at < len(self._reply):
            chunk = self._reply[self._at:self._at + count]
            self._at += len(chunk)
            return chunk
        check(self._released.wait(10),
              "fixture: the output was never released, so nothing arrived late")
        if self._late_at < len(self._late):
            chunk = self._late[self._late_at:self._late_at + count]
            self._late_at += len(chunk)
            return chunk
        # Parked rather than ending the stream, so the only lines on stderr are the
        # ones this case is about.
        self._never.wait(30)
        return b""


class CountingPlayback(client.FilePlayback):
    """Reports each chunk once it has been handed over, so the test can wait."""

    def __init__(self, path, handled):
        client.FilePlayback.__init__(self, path)
        self._handled = handled
        self.calls = 0

    def write(self, pcm, turn):
        self.calls += 1
        try:
            client.FilePlayback.write(self, pcm, turn)
        finally:
            # In a finally, so the late chunk raising is as observable as the late
            # chunk being discarded and neither outcome hangs the case.
            if self.calls >= 2:
                self._handled.set()


def audio_after_close(label, extra):
    """Answer one turn, release the output, then let a late chunk arrive."""
    opened, released, handled = (thread_lib.Event(), thread_lib.Event(),
                                 thread_lib.Event())
    out_file = os.path.join(TMP, "reply-late-%s.pcm" % label)
    late = wire_client(
        ["--host", "desk", "--in-file", os.path.join(TMP, "clip.pcm"),
         "--out-file", out_file, "--timeout", "2", "--audio-idle", "0.05"]
        + extra,
        LateAudioStream(opened, released), StartGate(opened),
        CountingPlayback(out_file, handled))
    out, said = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(said):
        code = late.run()
        # Exactly what close() does with the output, at the point close() does it.
        late.playback.close()
        released.set()
        check(handled.wait(10), "fixture: the late chunk never reached the output")
        # Through close(), not the reporting method directly, so the wiring is
        # covered as well as the report: nothing else drives the only production
        # caller, and hand-calling it would pass with that call deleted. Returns at
        # once here, because the uplink stand-in swallows the quit, no downlink
        # thread or relay process was ever assigned, and the file drain is a no-op.
        late.close()
    late.up_q.put(None)
    records = [json_lib.loads(line) for line in out.getvalue().splitlines()
               if line.strip()]
    check(len(records) == 1,
          "%s: one turn was answered, so one record belongs in the file: %r"
          % (label, records))
    return late, records[0], said.getvalue(), code, out_file


quiet, quiet_run, quiet_said, quiet_code, quiet_file = audio_after_close(
    "quiet", [])
# THE POINT. The session worked, so nothing may read as a fault.
check("could not handle the relay's reply" not in quiet_said,
      "audio arriving after the output was released is this end's own teardown, "
      "not a fault to alarm on: %r" % quiet_said)
check("Traceback" not in quiet_said,
      "and it must not leave a traceback behind either: %r" % quiet_said)
check(quiet_code == 0,
      "a session whose only turn was answered must still exit 0, got %r"
      % quiet_code)
check(quiet_run["answered"] and quiet_run["relay_error"] is None,
      "and its record stands, reason-free: %r" % quiet_run)
# Condition 2: the discard is diagnostic only. The late chunk is the same size as
# the answer, so anything crediting it would double both figures.
check(quiet.playback.discarded == 1,
      "the late chunk must be counted as discarded: %r"
      % quiet.playback.discarded)
check(quiet.playback.turn_bytes == 2400,
      "but must not be credited to the turn: %r" % quiet.playback.turn_bytes)
check(quiet_run["reply_audio_seconds"] == 0.05,
      "so the reply's own duration stands: %r" % quiet_run["reply_audio_seconds"])
check(quiet_run["first_audio_s"] is not None,
      "and the answer's real first-audio figure stands: %r"
      % quiet_run["first_audio_s"])
check(os.path.getsize(quiet_file) == 2400,
      "and the discarded chunk reached no file: %d bytes"
      % os.path.getsize(quiet_file))

# Condition 1: discarded, not silently swallowed. A write after close outside
# teardown is a real logic bug, so the count has somewhere to be read.
loud, _, loud_said, loud_code, _ = audio_after_close("loud", ["--verbose"])
check("discarded 1 reply audio chunk" in loud_said,
      "--verbose must say how many chunks were dropped: %r" % loud_said)
check("could not handle the relay's reply" not in loud_said
      and "Traceback" not in loud_said,
      "and saying so is not the same as calling it a fault: %r" % loud_said)
check(loud_code == 0 and loud.playback.turn_bytes == 2400,
      "and reporting it changes neither the exit code nor the turn's bytes: %r %r"
      % (loud_code, loud.playback.turn_bytes))

# Which of the playback's two locks covers what, driven rather than asserted about.
# take_turn calls turn_reset while holding the client's own turn lock, so anything
# turn_reset can wait behind stalls the whole client: neither the downlink nor the
# sender can stamp a thing without that lock. The file write is the one slow step
# here, so it must sit outside the lock turn_reset takes. The handle below parks
# instead of writing, which makes a slow filesystem exact rather than simulated.
parked, release_write, reset_done = (thread_lib.Event(), thread_lib.Event(),
                                     thread_lib.Event())


class ParkingHandle:
    """A file whose write blocks until this case lets it through."""

    def __init__(self):
        self.written = 0

    def write(self, pcm):
        self.written += len(pcm)
        parked.set()
        check(release_write.wait(10), "fixture: the parked write was never freed")

    def close(self):
        pass


slow = client.FilePlayback(os.path.join(TMP, "reply-slow.pcm"))
slow._handle.close()
slow._handle = ParkingHandle()
slow.turn_reset(1)
thread_lib.Thread(target=slow.write, args=(b"\x00\x00" * 600, 1),
                  daemon=True).start()
check(parked.wait(10), "fixture: the write never reached the handle")


def advance_the_turn():
    slow.turn_reset(2)
    reset_done.set()


thread_lib.Thread(target=advance_the_turn, daemon=True).start()
# Bounded, and it discriminates in both directions: with the write outside that
# lock the reset completes at once, and with the write inside it the reset cannot
# complete until the line below runs, whatever the machine is doing.
check(reset_done.wait(5),
      "a turn advance must not wait behind a file write, because take_turn makes "
      "it while holding the lock the downlink and the sender both need")
release_write.set()
# The accounting still had to happen, and under the lock: the chunk was turn one's.
check(slow.turn_bytes == 0 and slow.first_played is None,
      "and turn two starts owed nothing and unstamped: %r %r"
      % (slow.turn_bytes, slow.first_played))

# The record's own two figures for one turn's audio. reply_audio_seconds and
# answered are the same measurement asked twice, and the record is built outside
# the playback's lock, so reading that measurement twice lets a chunk land between
# the two reads and produce a record saying both that no audio arrived and that the
# turn was answered. The reader of runs.jsonl then has to guess which half to
# believe, which is the whole failure this work exists to remove.
#
# The playback below is that interleaving made exact rather than raced for: the
# count grows between one read of it and the next, so a record built from two reads
# cannot agree with itself and a record built from one always does.
class SlippingCount(client.FilePlayback):
    """A playback whose byte count grows between one read of it and the next."""

    def __init__(self, path):
        self.reads = 0
        client.FilePlayback.__init__(self, path)

    @property
    def turn_bytes(self):
        self.reads += 1
        return self._counted if self.reads == 1 else self._counted + 2400

    @turn_bytes.setter
    def turn_bytes(self, count):
        self._counted = count


slip_open, slip_parked = thread_lib.Event(), thread_lib.Event()


def park_the_downlink():
    # Parked rather than ended, because an end of stream would make the downlink
    # name a reason, and naming one reads the byte count itself. The turn has to
    # reach its record with the count still unread by anything else.
    slip_parked.wait(30)


slipping = SlippingCount(os.path.join(TMP, "reply-slip.pcm"))
# The timeout boundary is the one moment the first chunk of a reply can land while
# the record is being built, because a turn that timed out with nothing played is
# the only one whose count is still zero when the record reads it.
slipped = wire_client(
    ["--host", "desk", "--in-file", os.path.join(TMP, "clip.pcm"),
     "--out-file", os.path.join(TMP, "reply-slip.pcm"),
     "--timeout", "0.3", "--audio-idle", "0.05"],
    ScriptedStream(slip_open, b"", "nothing at all", park_the_downlink),
    StartGate(slip_open), slipping)
slip_out, slip_said = io.StringIO(), io.StringIO()
with contextlib.redirect_stdout(slip_out), contextlib.redirect_stderr(slip_said):
    slip_code = slipped.run()
slipped.up_q.put(None)
slip_records = [json_lib.loads(line) for line in slip_out.getvalue().splitlines()
                if line.strip()]
check(len(slip_records) == 1,
      "the turn was taken, so its record belongs in the file: %r" % slip_records)
slip = slip_records[0]
check(slipping.reads >= 1,
      "fixture: the record never read the byte count at all, so this case proves "
      "nothing: %r" % slipping.reads)
# THE POINT. One record may not answer the same question two ways.
check(slip["answered"] == (slip["reply_audio_seconds"] > 0),
      "a record that counts no reply audio must not also call the turn answered: "
      "%r" % slip)
check(slip["reply_audio_seconds"] == 0.0 and slip["answered"] is False,
      "and the figures are the ones true when the record was built, not one from "
      "before the chunk and one from after: %r" % slip)
check(slip_code != 0,
      "an unanswered turn must not exit 0, got %r" % slip_code)
# Released under a redirect so the end of stream this case parked cannot print into
# the suite's own output, and waited for so it cannot land after the case has ended.
with contextlib.redirect_stderr(io.StringIO()):
    slip_parked.set()
    slip_drained = slipped.closed.wait(10)
check(slip_drained, "fixture: the parked stream never ended")

# An end of stream arriving during THIS end's own teardown. close() bounds the
# relay's exit and the relay's own teardown can outlast that bound, so the child is
# killed with no goodbye written and the still-live downlink reads the empty stream
# it left behind. Every turn was answered and the session exits 0, so the mid-turn
# fault line must not be the last thing the captain reads: an alarm that also fires
# on success is one they learn to skip past, and then the real one is invisible too.
#
# The discriminator is the same one the goodbye branch uses, whether this end asked
# to stop, and the mid-session case further up this file is the other direction of
# it: there the stream ends long before close() is reached, so the line still fires.
class QuitThenEnd:
    """Serves one whole answer, then ends the stream once this end says goodbye."""

    def __init__(self, opened, quit_seen):
        self._opened = opened
        self._quit = quit_seen
        self._bytes = frame.encode(frame.AUDIO, b"\x00\x00" * 1200) + REPLY_END
        self._at = 0

    def read(self, count):
        check(self._opened.wait(10), "the turn never opened, so nothing was served")
        if self._at < len(self._bytes):
            chunk = self._bytes[self._at:self._at + count]
            self._at += len(chunk)
            return chunk
        check(self._quit.wait(10),
              "fixture: this end never asked to stop, so the stream never ended")
        return b""


class GoodbyeWatchingGate:
    """Opens on the turn's first frame and reports this end asking to stop."""

    def __init__(self, opened, quit_seen):
        self._opened = opened
        self._quit = quit_seen

    def send(self, kind, payload=b""):
        if kind == frame.TALK_START:
            self._opened.set()
        elif kind == frame.QUIT:
            self._quit.set()


tidy_open, tidy_quit = thread_lib.Event(), thread_lib.Event()
tidy = wire_client(
    ["--host", "desk", "--in-file", os.path.join(TMP, "clip.pcm"),
     "--out-file", os.path.join(TMP, "reply-tidy.pcm"),
     "--timeout", "2", "--audio-idle", "0.05"],
    QuitThenEnd(tidy_open, tidy_quit), GoodbyeWatchingGate(tidy_open, tidy_quit))
tidy_out, tidy_said = io.StringIO(), io.StringIO()
with contextlib.redirect_stdout(tidy_out), contextlib.redirect_stderr(tidy_said):
    tidy_code = tidy.run()
    # Gated on the downlink reaching the end of stream rather than on any elapsed
    # time: close() does not wait for it here, so without this the case could pass
    # by asserting on output the downlink had not written yet.
    tidy.close()
    tidy_drained = tidy.closed.wait(10)
tidy.up_q.put(None)
check(tidy_drained, "fixture: the downlink never saw the stream end")
tidy_records = [json_lib.loads(line) for line in tidy_out.getvalue().splitlines()
                if line.strip()]
check(len(tidy_records) == 1,
      "one turn was answered, so one record belongs in the file: %r" % tidy_records)
# Proof the end of stream really was taken, so the silence below is a decision
# rather than a branch this case never reached: the cause is recorded outside the
# test that decides whether to speak.
check(tidy.closed_because == "the connection ended",
      "fixture: the downlink did not take the end of stream at all: %r"
      % tidy.closed_because)
# THE POINT. The session answered everything asked of it, so nothing may read as a
# fault, least of all as the last line the captain sees.
check("the connection ended" not in tidy_said.getvalue(),
      "an end of stream during this end's own teardown is the relay doing as it "
      "was told, not a fault to alarm on: %r" % tidy_said.getvalue())
check(tidy_code == 0,
      "and a session whose only turn was answered must still exit 0, got %r"
      % tidy_code)
check(tidy_records[0]["answered"] and tidy_records[0]["relay_error"] is None,
      "and its record stands, reason-free: %r" % tidy_records[0])

# A reply that is handled AFTER the turn it belongs to has already been recorded.
# The downlink reads a frame on one thread and applies it on another, so a turn
# that times out while a notice is in flight used to have that notice applied to
# whatever turn came next: it named the new turn with the old turn's fault, and
# released it before its own answer had arrived. A turn that would have been
# answered normally was reported unanswered, carrying a reason belonging to a turn
# the captain had already been told about.
#
# Driven through the client's own say(), not a sleep: the notice is parked exactly
# where the real window is, after the frame has arrived and before its handler
# takes the lock, and it is released only once the NEXT turn has really opened,
# which the uplink reports when that turn's talk start goes out.
class TurnCountingGate:
    """Reports the first turn opening, and the second one separately."""

    def __init__(self, first, second):
        self._first = first
        self._second = second
        self.starts = 0

    def send(self, kind, payload=b""):
        if kind == frame.TALK_START:
            self.starts += 1
            (self._first if self.starts == 1 else self._second).set()


stale_open, stale_next = thread_lib.Event(), thread_lib.Event()
# Wired without starting its threads, because the notice has to be parked before
# the downlink is allowed to read it.
stale = wire_client(
    ["--host", "desk", "--in-file", os.path.join(TMP, "clip.pcm"),
     "--out-file", os.path.join(TMP, "reply-stale.pcm"), "--runs", "2",
     "--timeout", "2", "--audio-idle", "0.05", "--gap-seconds", "0.05"],
    ScriptedStream(
        stale_open,
        frame.encode_json(frame.NOTICE, {"event": "turn-failed",
                                         "error": "the model dropped turn one"})
        + frame.encode(frame.AUDIO, b"\x00\x00" * 1200) + REPLY_END,
        "turn one's failure and turn two's answer"),
    TurnCountingGate(stale_open, stale_next), start=False)

# The notice is held between arriving and being applied, which is the window the
# turn identity exists to close. Turn one then times out and is recorded, turn two
# opens, and only then is the notice allowed to finish being handled.
said_plainly = client.say


def park_the_notice(message):
    said_plainly(message)
    if "could not finish that turn" in message:
        check(stale_next.wait(10),
              "fixture: the second turn never opened, so nothing went stale")


client.say = park_the_notice
try:
    thread_lib.Thread(target=stale._sender, daemon=True).start()
    thread_lib.Thread(target=stale._downlink, daemon=True).start()
    stale_out, stale_said = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(stale_out), contextlib.redirect_stderr(stale_said):
        stale_code = stale.run()
finally:
    client.say = said_plainly
stale.up_q.put(None)
stale.playback.close()

stale_runs = [json_lib.loads(line) for line in stale_out.getvalue().splitlines()
              if line.strip()]
check(len(stale_runs) == 2,
      "both turns were taken, so both belong in the file: %d, %r"
      % (len(stale_runs), stale_runs))
check(not stale_runs[0]["answered"],
      "fixture is wrong: the first turn should time out unanswered: %r"
      % stale_runs[0])
# THE POINT. The stale notice belonged to turn one and must touch nothing else.
check(stale_runs[1]["relay_error"] is None,
      "a fault from a turn that has already ended must not be recorded against "
      "the next one: %r" % stale_runs[1])
check(stale_runs[1]["answered"] and stale_runs[1]["reply_audio_seconds"] > 0,
      "and the next turn must be left to run normally rather than released "
      "before its answer arrived: %r" % stale_runs[1])
check(stale_code != 0,
      "one turn of two was still lost, so the exit code must say so, got %r"
      % stale_code)

# The same window, with AUDIO in it instead of a notice, which is the worse half.
# The frame's timing marks are taken under the turn lock, but the audio itself goes
# to the playback, and the playback is where first_played is stamped, where the
# reply's duration is counted, and where answered comes from. Credited to whatever
# turn is open, one stale chunk gives a turn that was never answered a headline
# latency figure measured from somebody else's reply, reports it answered, and with
# that the whole session exits 0 having lost a turn.
#
# Parked at the playback rather than at say(), because that IS the accounting
# point: the write is released only once the next turn has really opened, which the
# uplink reports when that turn's talk start goes out. No sleeps.
class LatePlayback(client.FilePlayback):
    """Holds the first chunk until the turn after the one it belongs to has opened."""

    def __init__(self, path, opened):
        client.FilePlayback.__init__(self, path)
        self._opened = opened
        self._held = False

    def write(self, pcm, turn):
        if not self._held:
            self._held = True
            check(self._opened.wait(10),
                  "fixture: the next turn never opened, so nothing went stale")
        client.FilePlayback.write(self, pcm, turn)


late_open, late_next = thread_lib.Event(), thread_lib.Event()
late_out_file = os.path.join(TMP, "reply-late.pcm")
late = wire_client(
    ["--host", "desk", "--in-file", os.path.join(TMP, "clip.pcm"),
     "--out-file", late_out_file, "--runs", "2",
     "--timeout", "2", "--audio-idle", "0.05", "--gap-seconds", "0.05"],
    ScriptedStream(late_open, frame.encode(frame.AUDIO, b"\x00\x00" * 1200),
                   "turn one's audio"),
    TurnCountingGate(late_open, late_next),
    LatePlayback(late_out_file, late_next))
late_out, late_said = io.StringIO(), io.StringIO()
with contextlib.redirect_stdout(late_out), contextlib.redirect_stderr(late_said):
    late_code = late.run()
late.up_q.put(None)
late.playback.close()

late_runs = [json_lib.loads(line) for line in late_out.getvalue().splitlines()
             if line.strip()]
check(len(late_runs) == 2,
      "both turns were taken, so both belong in the file: %d, %r"
      % (len(late_runs), late_runs))
# THE POINT. Turn two was served nothing at all, and the stale chunk must not make
# it look otherwise on any of the four figures the playback feeds.
second = late_runs[1]
check(not second["answered"],
      "a turn served no audio of its own must not be reported answered because "
      "an earlier turn's chunk arrived during it: %r" % second)
check(second["reply_audio_seconds"] == 0,
      "and none of that chunk's duration belongs to it: %r" % second)
check(second["first_played_s"] is None,
      "and it must not be stamped with when that chunk reached the output: %r"
      % second)
check(second["first_audio_s"] is None,
      "and the headline figure, which prefers the playback stamp, must be absent "
      "too rather than measured from another turn's reply: %r" % second)
check(second["first_frame_s"] is None,
      "and the frame stamp stays absent, as the turn identity already ensured: %r"
      % second)
check(late_code != 0,
      "a session that lost a turn must not exit 0, got %r" % late_code)
# And the audio was still written. Attributing it to nobody must not mean dropping
# it: it is the tail of an answer the captain is still listening to.
check(os.path.getsize(late_out_file) == 2400,
      "the late chunk must still reach the output, not be discarded to make the "
      "figures tidy: %d bytes" % os.path.getsize(late_out_file))

# The wait between turns is the last thing a lost session should do. It exists
# only to avoid talking over the model's own speech, and a relay that is already
# gone is not speaking, so waiting it out leaves the captain sitting through the
# previous reply's whole spoken duration before anyone tells them the session
# stopped. The gap here is deliberately long and the reply deliberately short, so
# the elapsed time distinguishes stopping from waiting; nothing in the case sleeps
# on purpose, the code under test is the sleep.
prompt_served = thread_lib.Event()
prompt = wire_client(
    ["--host", "desk", "--in-file", os.path.join(TMP, "clip.pcm"),
     "--out-file", os.path.join(TMP, "reply-prompt.pcm"), "--runs", "3",
     "--timeout", "2", "--audio-idle", "0.05", "--gap-seconds", "5"],
    ScriptedStream(prompt_served,
                   frame.encode(frame.AUDIO, b"\x00\x00" * 1200) + REPLY_END,
                   "one whole answer and then the end of stream"),
    StartGate(prompt_served))
prompt_out, prompt_said = io.StringIO(), io.StringIO()
prompt_began = clock.monotonic()
with contextlib.redirect_stdout(prompt_out), contextlib.redirect_stderr(prompt_said):
    prompt_code = prompt.run()
prompt_took = clock.monotonic() - prompt_began
prompt.up_q.put(None)
prompt.playback.close()

prompt_runs = [json_lib.loads(line) for line in prompt_out.getvalue().splitlines()
               if line.strip()]
check(len(prompt_runs) == 1 and prompt_runs[0]["answered"],
      "fixture is wrong: one answered turn should be taken and no more: %r"
      % prompt_runs)
check(prompt_code != 0,
      "a session that took 1 of 3 runs must not exit 0, got %r" % prompt_code)
check(prompt_took < 3,
      "a session that already knows the connection is gone must stop rather than "
      "wait out the 5s gap first: took %.2fs" % prompt_took)
check("the connection ended before run 2 of 3" in prompt_said.getvalue(),
      "and it should name the cause and the first run it lost: %r"
      % prompt_said.getvalue())

# The speaker's byte ACCOUNTING, which is not the speaker. No audio device is
# reached here and none can be on this host: the stream is a stub and the device
# callback is called by hand, so nothing below says anything about how a real
# output device behaves. What it does cover is the arithmetic deciding which turn
# a chunk is credited to and whose first-audio clock it stamps, which until now
# was the one piece of that logic with no coverage at all while the file path it
# mirrors had plenty. Its correctness rests on the earlier turns' bytes being a
# prefix of the buffer, and a sign or bound slip in the prefix count would
# silently mismeasure the headline latency on the path the captain will use.
class StubStream:
    """Stands in for the output device: accepts the settings, plays nothing."""

    def __init__(self, **settings):
        self.settings = settings
        self.latency = 0.011
        self.started = False

    def start(self):
        self.started = True

    def stop(self):
        pass

    def close(self):
        pass


stub_audio = types.ModuleType("sounddevice")
stub_audio.RawOutputStream = StubStream
sys.modules["sounddevice"] = stub_audio


def fresh_speaker():
    return client.SpeakerPlayback()


def pull(speaker, frames):
    """Ask the stub device for one block, and return exactly what it was handed."""
    block = bytearray(frames * 2)
    speaker._callback(block, frames, None, None)
    return bytes(block)


opened = fresh_speaker()
check(opened.device_latency == 0.011,
      "the reported device latency should come from the stream: %r"
      % opened.device_latency)

# No earlier bytes at all: the first chunk of this turn's own reply is this turn's
# first audio.
speaker = fresh_speaker()
speaker.turn_reset(1)
speaker.write(b"\x01\x01" * 300, 1)
check(speaker.turn_bytes == 600,
      "this turn's own audio is credited to it: %r" % speaker.turn_bytes)
check(pull(speaker, 300) == b"\x01\x01" * 300, "and is played unchanged")
check(speaker.first_played is not None,
      "and stamps this turn's first audio when it reaches the device")

# An empty buffer. Silence handed to the device is not the reply arriving, so the
# count taken and the count skipped are equal at zero and nothing is stamped.
speaker = fresh_speaker()
speaker.turn_reset(1)
check(pull(speaker, 100) == b"\x00" * 200,
      "an empty buffer is padded with silence")
check(speaker.first_played is None,
      "and stamps nothing: no reply audio has reached the device yet")

# Earlier bytes exactly equal to the block taken. The whole block belongs to a turn
# already recorded, so it plays and stamps nothing.
speaker = fresh_speaker()
speaker.turn_reset(2)
speaker.write(b"\x02\x02" * 300, 1)
check(speaker.turn_bytes == 0,
      "a chunk from an earlier turn is credited to nobody: %r" % speaker.turn_bytes)
check(pull(speaker, 300) == b"\x02\x02" * 300,
      "but is still played, because it is the tail of an answer being listened to")
check(speaker.first_played is None,
      "and must not stamp the later turn's first audio")

# Earlier bytes larger than the block taken, drained across two blocks. The count
# has to come down by what was taken and no more, or the turn's real first audio
# is stamped by somebody else's tail.
speaker = fresh_speaker()
speaker.turn_reset(2)
speaker.write(b"\x03\x03" * 300, 1)
speaker.write(b"\x04\x04" * 300, 1)
check(pull(speaker, 150) == b"\x03\x03" * 150, "the earlier tail plays in order")
check(speaker.first_played is None, "and stamps nothing on the first block")
check(pull(speaker, 150) == b"\x03\x03" * 150, "nor on the second")
check(speaker.first_played is None, "still nothing stamped")
check(pull(speaker, 300) == b"\x04\x04" * 300, "nor while the rest of it drains")
check(speaker.first_played is None,
      "1200 earlier bytes must take 1200 bytes to drain, not one block")
speaker.write(b"\x05\x05" * 300, 2)
check(pull(speaker, 300) == b"\x05\x05" * 300, "then this turn's own reply plays")
check(speaker.first_played is not None, "and that is what stamps the clock")

# Earlier bytes smaller than the block taken, so one block spans the boundary. The
# first byte past the earlier tail is this turn's first audio, and it is inside a
# block that started with somebody else's.
speaker = fresh_speaker()
speaker.turn_reset(2)
speaker.write(b"\x06\x06" * 150, 1)
speaker.write(b"\x07\x07" * 150, 2)
check(pull(speaker, 300) == b"\x06\x06" * 150 + b"\x07\x07" * 150,
      "a block spanning the boundary is played whole")
check(speaker.first_played is not None,
      "and the first byte past the earlier tail stamps this turn's first audio")
check(speaker.turn_bytes == 300,
      "with only this turn's half credited to it: %r" % speaker.turn_bytes)

# A turn advancing while the previous answer is still queued, which is the case
# turn_reset itself has to handle: everything already buffered belongs to the turn
# that is being closed, however it got there.
speaker = fresh_speaker()
speaker.turn_reset(1)
speaker.write(b"\x08\x08" * 300, 1)
check(speaker.turn_bytes == 600, "turn one is credited its own reply")
speaker.turn_reset(2)
check(speaker.turn_bytes == 0 and speaker.first_played is None,
      "turn two starts owed nothing and unstamped: %r %r"
      % (speaker.turn_bytes, speaker.first_played))
check(pull(speaker, 300) == b"\x08\x08" * 300,
      "turn one's undrained tail still reaches the device")
check(speaker.first_played is None,
      "but it must not stamp turn two, which is what it would have done before "
      "turn_reset counted what was already queued")
speaker.write(b"\x09\x09" * 300, 2)
check(pull(speaker, 300) == b"\x09\x09" * 300 and speaker.first_played is not None,
      "and turn two's own reply is what stamps turn two")
check(speaker.turn_bytes == 600, "credited to turn two: %r" % speaker.turn_bytes)

# A short buffer of earlier bytes: padded with silence, and the padding is not
# mistaken for this turn's reply either.
speaker = fresh_speaker()
speaker.turn_reset(2)
speaker.write(b"\x0a\x0a" * 100, 1)
check(pull(speaker, 300) == b"\x0a\x0a" * 100 + b"\x00" * 400,
      "a short earlier tail is padded rather than repeated")
check(speaker.first_played is None, "and the padding stamps nothing")

# A chunk arriving after close, which is the same teardown race the file path
# already discards and counts. Nothing here goes near a device: the stream is the
# same stub, and stopping it is what makes the chunk unplayable, so queuing it
# would be recording a measurement the captain never heard.
speaker = fresh_speaker()
speaker.turn_reset(1)
speaker.write(b"\x0b\x0b" * 300, 1)
speaker.turn_reset(2)
speaker.write(b"\x0c\x0c" * 150, 2)
was = (speaker.turn_bytes, speaker._earlier, speaker.first_played,
       bytes(speaker._buffer))
check(was == (300, 600, None, b"\x0b\x0b" * 300 + b"\x0c\x0c" * 150),
      "fixture: turn two should be owed its own bytes behind turn one's tail: %r"
      % (was,))
speaker.close()
speaker.write(b"\x0d\x0d" * 300, 2)
check(speaker.discarded == 1,
      "a chunk arriving after close must be counted, not silently swallowed: %r"
      % speaker.discarded)
check(bytes(speaker._buffer) == was[3],
      "and must not be queued for a stream that has already stopped")
check((speaker.turn_bytes, speaker._earlier, speaker.first_played) == was[:3],
      "and must leave every per-turn figure exactly as it was: %r"
      % ((speaker.turn_bytes, speaker._earlier, speaker.first_played),))

# And the count reaches the captain on this path through the same close() that
# reports it on the file path, so the counter is not merely present here.
heard = fresh_speaker()
heard.turn_reset(1)
heard.write(b"\x0e\x0e" * 300, 1)
check(pull(heard, 300) == b"\x0e\x0e" * 300,
      "fixture: the turn's own reply should drain before the output is released")
heard.close()
heard.write(b"\x0f\x0f" * 300, 1)
reported = client.Client(client.parse_args(["--host", "desk", "--verbose"]))
reported.playback = heard
speaker_said = io.StringIO()
with contextlib.redirect_stderr(speaker_said):
    reported.close()
check("discarded 1 reply audio chunk" in speaker_said.getvalue(),
      "--verbose must report the count on this path as it does on the file one: %r"
      % speaker_said.getvalue())

del sys.modules["sounddevice"]



# A startup that refuses part way through releases what it already started, and
# close() therefore has to survive a half-built client. The real devices cannot be
# opened on this host, so these stand in for them; what is tested here is the
# release path and the refusal, not the devices themselves.
class Recorder:
    def __init__(self, closed):
        self._closed = closed
        self.first_played = None
        self.device_latency = None
        self.discarded = 0

    def drain(self, timeout=5):
        pass

    def close(self):
        self._closed.append("closed")

    def start(self, out_q, talking):
        pass

# Nothing built yet: close() must not trip over the fields that are still None.
client.Client(client.parse_args(["--host", "desk"])).close()

# Built part way, then refused: whatever was started is released once.
half = client.Client(client.parse_args(["--host", "desk"]))
speaker, microphone = [], []
half.playback = Recorder(speaker)
half.capture = Recorder(microphone)
half.close()
check(speaker == ["closed"] and microphone == ["closed"],
      "a half-built client must release both devices: %r %r" % (speaker, microphone))

# open() releases them itself when a later step refuses, so no caller has to.
refusing = client.Client(client.parse_args(["--host", "desk"]))
speaker, microphone = [], []

def half_start():
    refusing.playback = Recorder(speaker)
    refusing.capture = Recorder(microphone)
    raise SystemExit("fm-voice-client: the relay closed the connection")

refusing._start = half_start
raised = None
try:
    refusing.open()
except SystemExit as exc:
    raised = str(exc)
check(raised is not None, "open must not swallow the refusal")
check(speaker == ["closed"] and microphone == ["closed"],
      "open must release the devices it started: %r %r" % (speaker, microphone))

# A device that cannot be opened is one named line with a next step, not a
# traceback, because this is the path the guide warns will fail first. The relay
# side is stubbed out here so nothing is launched: the subject is the refusal.
class Boom:
    def __init__(self, *args, **kwargs):
        raise RuntimeError("PortAudio said no")

class FakeProc:
    def __init__(self, *args, **kwargs):
        self.stdin = io.BytesIO()
        self.stdout = io.BytesIO(frame.MAGIC)

    def wait(self, timeout=None):
        return 0

    def kill(self):
        pass

real_speaker = client.SpeakerPlayback
real_popen = client.subprocess.Popen
real_sync = client.sync_magic
client.SpeakerPlayback = Boom
client.subprocess.Popen = FakeProc
client.sync_magic = lambda stream, verbose=False: None

def refusal_for(argv):
    """Return how open() refuses, as (exception type name, message)."""
    try:
        client.Client(client.parse_args(["--host", "desk"] + argv)).open()
    except BaseException as exc:               # noqa: BLE001
        return type(exc).__name__, str(exc)
    return None, "open() did not refuse"

kind, named = refusal_for([])
try:
    check(kind == "DeviceError",
          "a device failure should be a named refusal, got %s: %s" % (kind, named))
    check("could not open the audio device" in named,
          "and should say what it could not open: %s" % named)
    check("--output-device" in named,
          "and should name the flag for that end: %s" % named)
    check("--in-file" in named,
          "and should name a way to run without a device: %s" % named)

    # The file ends are the ones this host runs and the ones every measured
    # figure was taken with, so a path that cannot be opened must say so and name
    # the flag that chose it. Calling it a device failure sends the reader to
    # --input-device when the thing to fix is the path.
    missing = os.path.join(TMP, "no-such-clip.pcm")
    kind, named = refusal_for(["--in-file", missing, "--out-file",
                               os.path.join(TMP, "reply.pcm")])
    check(kind in ("OSError", "FileNotFoundError"),
          "a missing clip is not a device failure, got %s: %s" % (kind, named))
    check(missing in named, "the refusal must name the path: %s" % named)
    check("--in-file" in named and "--output-device" not in named,
          "and the flag that named it, and no device advice: %s" % named)

    nowhere = os.path.join(TMP, "no-such-dir", "reply.pcm")
    kind, named = refusal_for(["--in-file", os.path.join(TMP, "clip.pcm"),
                               "--out-file", nowhere])
    check(kind in ("OSError", "FileNotFoundError"),
          "an unwritable reply file is not a device failure either: %s" % named)
    check(nowhere in named and "--out-file" in named,
          "and must name the path and its flag: %s" % named)
finally:
    client.SpeakerPlayback = real_speaker
    client.subprocess.Popen = real_popen
    client.sync_magic = real_sync

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

# --listen open-mic refuses, out loud and early. The mode has no way to tell when
# the captain stopped speaking, so it would stream a turn that never ends; the
# captain should be told that rather than watching it half work. Early matters as
# much as loud: an ssh stub here records any attempt to reach the desktop, and the
# refusal must come before it, so nothing is opened and nothing is spent.
OPENMIC_FAKEBIN=$(fm_fakebin "$TMP_ROOT/openmic-fake")
SSH_CALLED="$TMP_ROOT/ssh-was-called"
cat > "$OPENMIC_FAKEBIN/ssh" <<SH
#!/usr/bin/env bash
printf 'ssh %s\n' "\$*" >> "$SSH_CALLED"
exit 9
SH
chmod +x "$OPENMIC_FAKEBIN/ssh"

set +e
openmic_out=$(PATH="$OPENMIC_FAKEBIN:$PATH" python3 "$ROOT/bin/fm-voice-client.py" \
  --host a-desktop --relay /desktop/bin/fm-voice-relay.py --listen open-mic 2>&1)
openmic_code=$?
set -e
[ "$openmic_code" -ne 0 ] || fail "--listen open-mic started instead of refusing"
assert_contains "$openmic_out" 'end-of-speech' \
  "the refusal should name the missing piece: $openmic_out"
assert_contains "$openmic_out" 'push-to-talk' \
  "the refusal should name the mode that does work: $openmic_out"
assert_absent "$SSH_CALLED" \
  "the refusal must come before anything reaches the desktop"
# The default still starts far enough to try the connection, so the case above is
# a property of the setting rather than of the fixture refusing everything.
set +e
PATH="$OPENMIC_FAKEBIN:$PATH" python3 "$ROOT/bin/fm-voice-client.py" \
  --host a-desktop --relay /desktop/bin/fm-voice-relay.py --talk-seconds 0 \
  >/dev/null 2>&1
set -e
assert_present "$SSH_CALLED" \
  "fixture is wrong: push to talk should have reached the ssh stub"
pass "--listen open-mic refuses at startup, before it opens anything"

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

# THE DEFAULT IS THE NARROW SCOPE. A home that has configured nothing has granted
# nothing, and sending task identifiers, titles and pull request links to a model
# in another region is not something to inherit from somebody else's settings
# file. Widening is one line the captain of those records writes themselves.
default=$(records_status) || fail "default scope failed"
assert_contains "$default" '"scope": "counts"' \
  "an unconfigured home should get the narrow scope"
assert_not_contains "$default" 'alpha-one' \
  "an unconfigured home must not name work"
assert_not_contains "$default" 'sign-in redirect' \
  "an unconfigured home must not carry titles"
assert_not_contains "$default" 'github.com' \
  "an unconfigured home must not carry pull request links"
assert_contains "$default" '"in_flight": 3' \
  "an unconfigured home should still say how much is waiting"
pass "an absent read-scope setting means the narrowest answer, not the widest"

# Widening is what the file is for, and it takes effect without a flag.
printf 'full\n' > "$HOME_FIXTURE/config/voice-read-scope"
widened=$(records_status) || fail "configured wide scope failed"
assert_contains "$widened" '"scope": "full"' \
  "writing full into config/voice-read-scope should widen the answer"
assert_contains "$widened" 'alpha-one' "the wide scope should then name work"
rm -f "$HOME_FIXTURE/config/voice-read-scope"
pass "a home widens its own read scope by writing the setting"

# --- the confidentiality boundary -------------------------------------------
#
# This is the case that lets a home widen to the full scope at all.

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

# THE CASE THE DENY LIST EXISTS FOR, and the one a per-list decision gets wrong.
# The docstring says the list is for a future open task carrying a customer name,
# and a name like that lives in the TITLE or in the HOLD text of an item that is
# also in flight, also waiting on the captain, and also carrying a pull request.
# A decision taken separately in each list, from whichever fields that list
# happens to use, withholds such an item from one list and names it in another.
# That is not a narrower answer, it is a leak with a reassuring count beside it.
# Both items below sit in all three lists, and each is matched on a field only
# one of those lists reads.
#
# The third item is the one an in-flight-only fixture cannot catch: a QUEUED item
# that nothing holds for the captain, so no list iterates it, while its pull
# request link still reaches the answer through the worker records. Assembling its
# fields only where some list walks past it misses a match on its own title.
LEAK_HOME="$TMP_ROOT/deny-every-list"
TITLE_TOKEN=LEAKSBYTITLE
HOLD_TOKEN=LEAKSBYHOLD
QUEUED_TOKEN=LEAKSFROMQUEUED
mkdir -p "$LEAK_HOME/data" "$LEAK_HOME/state" "$LEAK_HOME/config"
cat > "$LEAK_HOME/data/backlog.md" <<EOF
# Backlog

## In flight
- [ ] omega-nine - Renew the $TITLE_TOKEN contract (repo: omega) (kind: captain)
- [ ] sigma-ten - Move the account onto the new tier (repo: sigma) (kind: ship) (hold-kind: captain) (hold: waiting on the $HOLD_TOKEN owner)

## Queued
- [ ] zeta-eight - Migrate the $QUEUED_TOKEN estate (repo: zeta) (kind: ship)
EOF
fm_write_meta "$LEAK_HOME/state/omega-nine.meta" \
  kind=captain pr=https://github.com/example/omega/pull/11
fm_write_meta "$LEAK_HOME/state/sigma-ten.meta" \
  kind=ship pr=https://github.com/example/sigma/pull/12
fm_write_meta "$LEAK_HOME/state/zeta-eight.meta" \
  kind=ship pr=https://github.com/example/zeta/pull/99

leak_status() {
  python3 "$ROOT/bin/fm_voice_records.py" status --home "$LEAK_HOME" --scope full
}

# Reachable in all three lists first, or the suppression below proves nothing.
reachable=$(leak_status) || fail "the deny-every-list fixture failed"
assert_contains "$reachable" "$TITLE_TOKEN" "fixture: the title marker should be reachable"
assert_contains "$reachable" 'omega-nine' "fixture: the item should be named"
assert_contains "$reachable" 'pull/11' "fixture: its pull request should be reachable"
assert_contains "$reachable" 'sigma-ten' "fixture: the held item should be named"
assert_contains "$reachable" 'pull/12' "fixture: its pull request should be reachable"
assert_contains "$reachable" '"awaiting_captain": 2' \
  "fixture: both in-flight items should be waiting on the captain"
assert_contains "$reachable" 'pull/99' \
  "fixture: the queued item should reach the answer through its pull request"
assert_contains "$reachable" '"queued": 1' "fixture: the queued item should be counted"

# Matched on its title, which only the in-flight list reads.
printf '%s\n' "$TITLE_TOKEN" > "$LEAK_HOME/config/voice-read-deny"
by_title=$(leak_status) || fail "deny by title failed"
assert_not_contains "$by_title" "$TITLE_TOKEN" "a title match must be suppressed"
assert_not_contains "$by_title" 'omega-nine' \
  "a denied item must not be named in any list"
assert_not_contains "$by_title" 'pull/11' \
  "a denied item must not surface through its pull request link"
assert_contains "$by_title" '"withheld_as_confidential": 1' \
  "the denied item should be counted once"
# The other items are untouched, so this is a substring list and not a switch.
assert_contains "$by_title" 'sigma-ten' "the deny list must not suppress everything"
assert_contains "$by_title" 'pull/12' "the other pull requests should still be named"
assert_contains "$by_title" 'pull/99' "the other pull requests should still be named"
assert_contains "$by_title" '"open_pull_requests": 3' \
  "denying an item must not change the count of open pull requests"

# Matched on its hold text, which only the captain list reads. The mirror of the
# case above: get one list right and this one still leaks.
printf '%s\n' "$HOLD_TOKEN" > "$LEAK_HOME/config/voice-read-deny"
by_hold=$(leak_status) || fail "deny by hold text failed"
assert_not_contains "$by_hold" 'sigma-ten' \
  "an item matched on its hold text must not be named in the in-flight list"
assert_not_contains "$by_hold" 'pull/12' \
  "an item matched on its hold text must not surface through its pull request"
assert_contains "$by_hold" '"withheld_as_confidential": 1' \
  "the denied item should be counted once"
assert_contains "$by_hold" 'omega-nine' "the deny list must not suppress everything"
assert_contains "$by_hold" 'pull/11' "the other pull request should still be named"
assert_contains "$by_hold" '"in_flight": 2' \
  "denying an item must not change the count of in-flight work"

# Matched on the title of a QUEUED item that no list iterates. Its only way into
# the answer is its pull request link, and the pull request list knows nothing
# about titles, so a field set assembled per list never sees the match at all.
printf '%s\n' "$QUEUED_TOKEN" > "$LEAK_HOME/config/voice-read-deny"
by_queued=$(leak_status) || fail "deny by queued title failed"
assert_not_contains "$by_queued" "$QUEUED_TOKEN" \
  "a queued item's title match must be suppressed"
assert_not_contains "$by_queued" 'zeta-eight' \
  "a denied queued item must not be named"
assert_not_contains "$by_queued" 'pull/99' \
  "a denied queued item must not surface through its pull request link"
assert_contains "$by_queued" '"withheld_as_confidential": 1' \
  "a denied queued item must be counted, so nothing is hidden silently"
assert_contains "$by_queued" '"queued": 1' \
  "denying it must not change the count of queued work"
assert_contains "$by_queued" 'pull/11' "the other pull requests should still be named"
assert_contains "$by_queued" 'pull/12' "the other pull requests should still be named"
pass "one deny decision per item covers every list that item could appear in"

# --- what a status line may say ---------------------------------------------
#
# A status line is free text a crewmate appended, and the verb taken off the
# front of it is the ONE record-derived string a counts-scope answer says out
# loud. At that scope there is no title and no link, so there is nothing for the
# deny list to filter and no scope setting that makes it safe. The vocabulary is
# therefore closed to the states bin/fm-brief.sh gives every crewmate plus the two
# bin/fm-classify-lib.sh adds when a decision closes, and anything else is a note.
VERB_HOME="$TMP_ROOT/status-verbs"
# Lowercase on purpose. The reader lowercases a verb before it could ever be
# emitted, and assert_not_contains compares case-sensitively, so an uppercase
# marker here would make the assertion below unable to fail on leaking code.
CUSTOMER_TOKEN=acmecorpmigration
mkdir -p "$VERB_HOME/data" "$VERB_HOME/state"
cat > "$VERB_HOME/data/backlog.md" <<'EOF'
# Backlog

## In flight
- [ ] one - First thing (repo: a) (kind: ship)
- [ ] two - Second thing (repo: b) (kind: ship)
- [ ] three - Third thing (repo: c) (kind: ship)
EOF
fm_write_meta "$VERB_HOME/state/one.meta" kind=ship
fm_write_meta "$VERB_HOME/state/two.meta" kind=ship
fm_write_meta "$VERB_HOME/state/three.meta" kind=ship
printf 'needs-decision [key=shape]: which shape\n' > "$VERB_HOME/state/one.status"
printf '%s: waiting on their security review\n' "$CUSTOMER_TOKEN" \
  > "$VERB_HOME/state/two.status"
# A log past the tail window, so the read is proven to end at the last line
# rather than at the start of whatever window it happened to open.
{
  verb_line=0
  while [ "$verb_line" -lt 400 ]; do
    printf 'working: step %s of a long task with a wordy status line\n' "$verb_line"
    verb_line=$((verb_line + 1))
  done
  printf 'done: shipped it\n'
} > "$VERB_HOME/state/three.status"
[ "$(wc -c < "$VERB_HOME/state/three.status")" -gt 8192 ] \
  || fail "fixture: the long status log should exceed the tail window"

verb_status() {
  python3 "$ROOT/bin/fm_voice_records.py" status --home "$VERB_HOME" "$@"
}

verbs=$(verb_status --scope counts) || fail "counts scope with odd verbs failed"
assert_not_contains "$verbs" "$CUSTOMER_TOKEN" \
  "a word outside the vocabulary must not be spoken, at the default scope least of all"
assert_contains "$verbs" '"note": 1' \
  "an unrecognised verb should be counted as a note instead"
assert_contains "$verbs" '"needs-decision": 1' \
  "a canonical verb, brackets and all, should survive the fold"
assert_contains "$verbs" '"done": 1' \
  "the last line of a long log is the line that counts"
assert_not_contains "$verbs" '"working"' \
  "an earlier line in the same log must not be reported as the state"
pass "the state verb is a closed vocabulary, so free text cannot ride out on it"

# The two halves of one answer must come from one home. Every script that sets
# FM_DATA_OVERRIDE sets FM_STATE_OVERRIDE beside it, so a reader that resolved one
# and not the other would count workers and notes from one home while counting
# in-flight work from another, which reads exactly like an ordinary answer.
alt_data="$TMP_ROOT/data-elsewhere"
mkdir -p "$alt_data"
cat > "$alt_data/backlog.md" <<'EOF'
# Backlog

## In flight
- [ ] moved-one - Work recorded in the overridden data directory (repo: m) (kind: ship)
EOF
moved=$(FM_DATA_OVERRIDE="$alt_data" verb_status --scope full) \
  || fail "status with an overridden data directory failed"
assert_contains "$moved" 'moved-one' \
  "the reader must take the backlog from the overridden data directory"
assert_contains "$moved" '"in_flight": 1' "and count only what that backlog holds"
inbox_moved=$(FM_HOME="$VERB_HOME" FM_STATE_OVERRIDE="$VERB_HOME/state" \
  FM_DATA_OVERRIDE="$alt_data" "$ROOT/bin/fm-inbox.sh" status) \
  || fail "fm-inbox status with an overridden data directory failed"
assert_contains "$inbox_moved" 'moved-one' \
  "the human rendering of the same records must read the same backlog"
pass "the backlog and the state directory always come from the same home"

# --- pull requests on finished work -----------------------------------------
#
# A task keeps its state/<id>.meta after its backlog item is marked done, because
# removing the record and moving the item are separate steps. So a reader that took
# every worker carrying a pull request would count and name finished work, which
# this module promises never to read. Worse, the deny list could not reach those
# items: with no open item there is no title in the field set, so a captain
# substring matching the title silently failed for exactly them while working
# everywhere else. Losing the count of a pull request on a finished task is the
# accepted cost of that control applying everywhere it appears to.
DONE_HOME="$TMP_ROOT/finished-pull-requests"
FINISHED_TOKEN=SHIPPEDLASTWEEK
mkdir -p "$DONE_HOME/data" "$DONE_HOME/state" "$DONE_HOME/config"
cat > "$DONE_HOME/data/backlog.md" <<EOF
# Backlog

## In flight
- [ ] still-open - Fix the retry (repo: a) (kind: ship)
- [x] ticked-two - Renew the $FINISHED_TOKEN contract (repo: b) (kind: ship)

## Done
- [x] older-three - Migrate the $FINISHED_TOKEN estate (repo: c) (kind: ship)
EOF
fm_write_meta "$DONE_HOME/state/still-open.meta" \
  kind=ship pr=https://github.com/example/a/pull/1
fm_write_meta "$DONE_HOME/state/ticked-two.meta" \
  kind=ship pr=https://github.com/example/b/pull/2
fm_write_meta "$DONE_HOME/state/older-three.meta" \
  kind=ship pr=https://github.com/example/c/pull/3

done_status() {
  python3 "$ROOT/bin/fm_voice_records.py" status --home "$DONE_HOME" --scope full
}

open_only=$(done_status) || fail "the finished-pull-request fixture failed"
assert_contains "$open_only" '"open_pull_requests": 1' \
  "only open work has an open pull request"
assert_contains "$open_only" 'pull/1' "the open task's pull request should be named"
assert_not_contains "$open_only" 'ticked-two' \
  "a ticked item must not be named through its pull request"
assert_not_contains "$open_only" 'pull/2' \
  "a ticked item's pull request must not be named"
assert_not_contains "$open_only" 'older-three' \
  "an item under Done must not be named through its pull request"
assert_not_contains "$open_only" 'pull/3' \
  "an item under Done must not have its pull request named"
assert_not_contains "$open_only" "$FINISHED_TOKEN" \
  "no finished title may reach the answer at any scope"
# Excluded by construction, not withheld and counted. A later change that put
# finished work back in and leaned on the deny list to hide it would fail here.
assert_contains "$open_only" '"withheld_as_confidential": 0' \
  "finished work is left out rather than counted as withheld"
# The worker count is deliberately NOT open-only: a task keeps its runtime record
# until teardown removes it, and that record is what "on deck" counts. Asserted in
# the same case as the pull request count so the two cannot quietly converge.
assert_contains "$open_only" '"workers_on_deck": 3' \
  "every live runtime record is still on deck, finished or not"
pass "a finished task's pull request is neither counted nor named"

# The deny list, observed doing its job on the one list that still carries links.
# A substring matching an OPEN task's title takes that task out of the pull
# request detail and says one thing is being withheld, while the count stays
# honest: that split is the contract this module states and the earlier cases
# pin, so the captain learns how much is waiting without learning what it is.
printf '%s\n' 'Fix the retry' > "$DONE_HOME/config/voice-read-deny"
denied_open=$(done_status) || fail "deny by an open title failed"
assert_not_contains "$denied_open" 'still-open' \
  "a denied open task must not be named in the pull request detail"
assert_not_contains "$denied_open" 'pull/1' \
  "a denied open task's pull request link must go with it"
assert_contains "$denied_open" '"withheld_as_confidential": 1' \
  "and the captain must be told one thing is being withheld"
assert_contains "$denied_open" '"open_pull_requests": 1' \
  "while the count of open pull requests stays honest"
rm -f "$DONE_HOME/config/voice-read-deny"
pass "a deny substring on an open title removes its pull request and says so"

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

# --- the whole round trip ----------------------------------------------------
#
# Every case above holds one piece of the spoken interface still. This one runs
# the piece the captain experiences: the laptop client opens the transport, the
# relay answers a spoken question from the records and hands a spoken request for
# real work to firstmate, and the reply audio and the timing come back down the
# same stream. It is the only case that would notice the round trip stopping
# working while all of the pieces still passed.
#
# ONE thing is stood in for: the model. It is a paid service in another region
# and no test has a credential for it. The stand-in below speaks the same event
# protocol Nova Sonic does and composes what it says out of the tool results the
# relay actually hands it, so the words asserted here are the records rather than
# a script, and it records what the session was opened with so this case can
# check the account and the model the relay chose. Everything else is real: the
# client, the frame format, the relay, the reader and bin/fm-inbox.sh.
#
# What only this case can hold:
#   the round trip completes at all, in both of its shapes, a status answer and a
#   handover, and a second turn is not treated as an interruption of the first;
#   the headline figure is measured from the captain's talk end rather than from
#   the start of their speech, which on this clip is the difference between half
#   a second and two and a half;
#   the talk-end silence padding really is sent, which is trap 2 and the
#   difference between an answer and no answer;
#   the laptop needs no AWS credential: the client runs with an environment that
#   has none, and the session is opened with the key only the desktop side holds.

E2E="$TMP_ROOT/e2e"
E2E_KEY=AKIADESKTOPONLYEXAMPLE
E2E_REGION=eu-north-1
E2E_MODEL=amazon.nova-2-sonic-v1:0
E2E_REQUEST="take the flaky sign-in test on alpha and open a pull request for it"
mkdir -p "$E2E/bin" "$E2E/laptop" "$E2E/desktop-home" "$E2E/laptop-home" \
  "$E2E/fakesdk/aws_sdk_bedrock_runtime" \
  "$E2E/home/data" "$E2E/home/state" "$E2E/home/config"

# The laptop holds the two files the guide says to copy, and nothing else.
cp "$ROOT/bin/fm-voice-client.py" "$ROOT/bin/fm_voice_frame.py" "$E2E/laptop/"

cat > "$E2E/home/data/backlog.md" <<EOF
# Backlog

## In flight
- [ ] alpha-one - Fix the sign-in redirect (repo: alpha) (kind: ship) (priority: 0)
  A note body, which is never assembled: $NEVER_TOKEN and the rate we agreed.
- [ ] beta-two - Decide the storage shape (repo: beta) (kind: captain)

## Queued
- [ ] delta-four - Add the retry (repo: delta) (kind: ship) (hold-kind: captain)

## Done
- [x] old-six - Shipped the $NEVER_TOKEN integration (repo: alpha) (done 2026-07-01)
EOF
fm_write_meta "$E2E/home/state/alpha-one.meta" kind=ship mode=no-mistakes \
  pr=https://github.com/example/alpha/pull/7
printf 'working: reading the failing test\n' > "$E2E/home/state/alpha-one.status"
printf '%s\n' "$E2E_REGION" > "$E2E/home/config/voice-region"
printf '%s\n' "$E2E_MODEL" > "$E2E/home/config/voice-model"
printf 'full\n' > "$E2E/home/config/voice-read-scope"

# The model stand-in, at exactly the import boundary bin/fm-voice-relay.py uses.
cat > "$E2E/fakesdk/aws_sdk_bedrock_runtime/__init__.py" <<'PY'
"""A scripted stand-in for Nova Sonic's bidirectional stream.

It answers with what the relay's own tool results contain, so a spoken answer
here is derived from firstmate's records rather than from a fixture string, and
it appends one JSON line per session describing what that session was opened
with and what it was asked. tests/fm-voice-relay.test.sh reads that record.

  FM_FAKE_SCRIPT   comma-separated turn kinds: status | handover | clean-end
  FM_FAKE_THINK    seconds before the reply begins, standing in for the model
  FM_FAKE_STATE    file holding the turn counter across the relay's reconnects
  FM_FAKE_LOG      where to append the per-session record
  FM_FAKE_REQUEST  the words the captain uses when asking for real work
  FM_FAKE_EARLY    1 to answer from the first audio in, not from the talk end

A clean-end turn is a session the model finishes with while the captain is still
speaking: the output stream simply ends, with no error and no answer. That is an
ordinary end of a Bedrock session rather than a fault, and the relay has to
survive it, so it is a turn kind here rather than a failure injection.

FM_FAKE_EARLY stands in for the model's own end-of-speech detector firing inside
a clip that already ends in silence: the answer begins before this end of the
stream has said the turn is over. Nova Sonic really does that, and the relay's
own timing figures are negative when it happens, which is the one case where a
fast-looking number is meaningless.
"""

import asyncio
import base64
import json
import math
import os
import struct
import sys
import types

OUT_RATE = 24000
CHUNK_MS = 100

THINK = float(os.environ.get("FM_FAKE_THINK", "0.4"))
REPLY_SECONDS = float(os.environ.get("FM_FAKE_REPLY_SECONDS", "0.4"))
SCRIPT = [s.strip() for s in os.environ.get("FM_FAKE_SCRIPT", "status").split(",")
          if s.strip()]
STATE = os.environ.get("FM_FAKE_STATE", "")
LOG = os.environ.get("FM_FAKE_LOG", "")
REQUEST = os.environ.get("FM_FAKE_REQUEST", "open a pull request for the retry")
EARLY = os.environ.get("FM_FAKE_EARLY", "") == "1"

HEARD = {"status": "how is the fleet doing right now", "handover": REQUEST}

# How much of the captain's speech a clean-end session takes before its output
# stream ends. Three chunks is 300 ms, so on a two second clip the end lands well
# inside the key press and the rest of that press arrives at a session that is
# already over.
CLEAN_END_AFTER_BYTES = 3200 * 3


def _turn_kind():
    """Return this session's turn kind, advancing a counter that lives on disk.

    The relay reconnects per turn on purpose, so the count cannot live in this
    process: each turn is a new stream in a new session.
    """
    index = 0
    if STATE:
        try:
            with open(STATE, encoding="utf-8") as handle:
                index = int(handle.read().strip() or "0")
        except (OSError, ValueError):
            index = 0
        try:
            with open(STATE, "w", encoding="utf-8") as handle:
                handle.write(str(index + 1))
        except OSError:
            pass
    if not SCRIPT:
        return "status", index
    return SCRIPT[index % len(SCRIPT)], index


def _speech(seconds):
    """Return reply audio: a quiet tone, so a byte count is a duration."""
    out = bytearray()
    for n in range(int(OUT_RATE * seconds)):
        out += struct.pack("<h", int(6000 * math.sin(2 * math.pi * 220 * n / OUT_RATE)))
    return bytes(out)


def _status_sentence(result):
    """Compose the spoken answer out of what the records reader returned."""
    if result.get("error"):
        return "I could not read the records: {}".format(result["error"])
    said = "Right now, {} in flight, {} waiting on you, {} open pull requests.".format(
        result.get("in_flight"), result.get("awaiting_captain"),
        result.get("open_pull_requests"))
    names = [row.get("id") for row in result.get("in_flight_detail", [])][:2]
    if names:
        said += " The ones moving are {}.".format(" and ".join(names))
    notes = result.get("captain_notes_waiting") or 0
    if notes:
        said += " {} note is queued for the first mate.".format(notes)
    if result.get("scope") == "counts":
        said += " Identifiers are not available by voice at this read scope."
    return said


def _queued_sentence(result):
    if result.get("error"):
        return "I could not queue that: {}".format(result["error"])
    return ("That is queued with the first mate as {}. I have not done any of it "
            "myself.".format(result.get("note_id") or "a note"))


class _Result:
    def __init__(self, payload):
        self.value = types.SimpleNamespace(bytes_=payload)


class _OutputReader:
    def __init__(self, queue):
        self._queue = queue

    async def receive(self):
        item = await self._queue.get()
        return None if item is None else _Result(item)


class _InputStream:
    def __init__(self, stream):
        self._stream = stream

    async def send(self, chunk):
        await self._stream.on_input(chunk.value.bytes_)

    async def close(self):
        await self._stream.finish()


class _Stream:
    """One bidirectional session, which is one turn the way the relay uses it."""

    def __init__(self, model_id, config):
        self.kind, self.index = _turn_kind()
        self.out = asyncio.Queue()
        self.input_stream = _InputStream(self)
        self._reader = _OutputReader(self.out)
        self._audio_content = None
        self._pending_use = None
        self._tools = {}
        self._next_tool = 0
        self._replied = False
        self._reply_task = None
        self._logged = False
        self._ended_early = False
        self.record = {
            "turn": self.index + 1,
            "turn_kind": self.kind,
            "model_id": model_id,
            "endpoint": config.endpoint_uri,
            "region": config.region,
            "credential_key_id": config.credentials.get("aws_access_key_id"),
            "tool_names_offered": [],
            "audio_bytes_in": 0,
            "tool_calls": [],
            "heard": "",
            "said": [],
            "reply_audio_bytes": 0,
        }

    async def await_output(self):
        return (None, self._reader)

    def _emit(self, event):
        self.out.put_nowait(json.dumps({"event": event}).encode())

    async def on_input(self, raw):
        event = json.loads(raw.decode()).get("event", {})
        for name, body in event.items():
            if name == "promptStart":
                self.record["tool_names_offered"] = [
                    t.get("toolSpec", {}).get("name")
                    for t in body.get("toolConfiguration", {}).get("tools", [])]
            elif name == "contentStart" and body.get("type") == "AUDIO":
                self._audio_content = body.get("contentName")
            elif name == "contentStart" and body.get("type") == "TOOL":
                self._pending_use = body.get(
                    "toolResultInputConfiguration", {}).get("toolUseId")
            elif name == "audioInput":
                self.record["audio_bytes_in"] += len(
                    base64.b64decode(body.get("content", "")))
                self._maybe_end_cleanly()
                if EARLY and not self._replied and not self._ended_early:
                    # Answering while the captain's clip is still arriving, which
                    # is what the model's own endpoint detector does to a clip
                    # that ends in silence.
                    self._replied = True
                    self._reply_task = asyncio.create_task(self._reply())
            elif name == "toolResult":
                self._tool_result(body)
            elif name == "contentEnd":
                if (body.get("contentName") == self._audio_content
                        and not self._replied and not self._ended_early):
                    # The captain's talk end. Everything measured is measured
                    # from here, so the reply starts no earlier than this.
                    self._replied = True
                    self._audio_content = None
                    self._reply_task = asyncio.create_task(self._reply())

    def _maybe_end_cleanly(self):
        """End a clean-end session's output stream, mid-key-press and unannounced.

        None on the output queue is what the SDK gives the reader for a stream
        that is simply over: no exception, no stop reason, nothing to report. The
        input half stays open, exactly as it does when the model is the side that
        finished, so the rest of the captain's key press still arrives here and
        goes nowhere.
        """
        if (self.kind != "clean-end" or self._ended_early
                or self.record["audio_bytes_in"] < CLEAN_END_AFTER_BYTES):
            return
        self._ended_early = True
        self.record["ended_early"] = True
        self._write_log()
        self.out.put_nowait(None)

    def _tool_result(self, body):
        try:
            result = json.loads(body.get("content") or "{}")
        except ValueError:
            result = {}
        if self.record["tool_calls"]:
            self.record["tool_calls"][-1]["result"] = result
        future = self._tools.pop(self._pending_use, None)
        if future is not None and not future.done():
            future.set_result(result)

    async def _call_tool(self, name, arguments):
        self._next_tool += 1
        use_id = "use-{}-{}".format(self.index + 1, self._next_tool)
        future = asyncio.get_running_loop().create_future()
        self._tools[use_id] = future
        self.record["tool_calls"].append({"name": name, "arguments": arguments})
        self._emit({"toolUse": {"toolName": name, "toolUseId": use_id,
                                "content": json.dumps(arguments)}})
        try:
            return await asyncio.wait_for(future, timeout=15)
        except asyncio.TimeoutError:
            return {"error": "the relay never answered the tool call"}

    def _say(self, text):
        self.record["said"].append(text)
        self._emit({"textOutput": {"role": "ASSISTANT", "content": text}})

    async def _reply(self):
        await asyncio.sleep(THINK)
        heard = HEARD.get(self.kind, "how is the fleet doing")
        self.record["heard"] = heard
        self._emit({"textOutput": {"role": "USER", "content": heard}})
        if self.kind == "handover":
            self._say("I am not the first mate, so I am handing that to it.")
            result = await self._call_tool("hand_over_to_firstmate",
                                           {"request": REQUEST})
            self._say(_queued_sentence(result))
        else:
            result = await self._call_tool("get_fleet_status", {})
            self._say(_status_sentence(result))
        pcm = _speech(REPLY_SECONDS)
        step = OUT_RATE * 2 * CHUNK_MS // 1000
        for at in range(0, len(pcm), step):
            block = pcm[at:at + step]
            self._emit({"audioOutput": {
                "content": base64.b64encode(block).decode()}})
            self.record["reply_audio_bytes"] += len(block)
            await asyncio.sleep(0.01)
        # Trap 1: this, not completionEnd, is what says the reply ended.
        self._emit({"contentEnd": {"stopReason": "END_TURN"}})
        self._write_log()

    def _write_log(self):
        if self._logged or not LOG:
            return
        self._logged = True
        with open(LOG, "a", encoding="utf-8") as handle:
            handle.write(json.dumps(self.record) + "\n")

    async def finish(self):
        self._write_log()
        self.out.put_nowait(None)


class AsyncBedrockRuntimeConfig:
    def __init__(self, endpoint_uri, region, credentials):
        self.endpoint_uri = endpoint_uri
        self.region = region
        self.credentials = credentials

    @classmethod
    async def resolve(cls, endpoint_uri=None, region=None, **credentials):
        return cls(endpoint_uri, region, credentials)


class AsyncBedrockRuntimeClient:
    def __init__(self, config=None):
        self.config = config

    async def invoke_model_with_bidirectional_stream(self, operation):
        return _Stream(operation.model_id, self.config)


class InvokeModelWithBidirectionalStreamOperationInput:
    def __init__(self, model_id=None):
        self.model_id = model_id


class BidirectionalInputPayloadPart:
    def __init__(self, bytes_=b""):
        self.bytes_ = bytes_


class InvokeModelWithBidirectionalStreamInputChunk:
    def __init__(self, value=None):
        self.value = value


def _submodule(name, **members):
    module = types.ModuleType(__name__ + "." + name)
    for key, value in members.items():
        setattr(module, key, value)
    sys.modules[module.__name__] = module
    return module


client = _submodule(
    "client",
    AsyncBedrockRuntimeClient=AsyncBedrockRuntimeClient,
    InvokeModelWithBidirectionalStreamOperationInput=(
        InvokeModelWithBidirectionalStreamOperationInput))
config = _submodule("config", AsyncBedrockRuntimeConfig=AsyncBedrockRuntimeConfig)
models = _submodule(
    "models",
    BidirectionalInputPayloadPart=BidirectionalInputPayloadPart,
    InvokeModelWithBidirectionalStreamInputChunk=(
        InvokeModelWithBidirectionalStreamInputChunk))
PY

# What the desktop side of the connection has, and the laptop side does not. The
# AWS credential is here and nowhere else, which is the whole point of the shape.
cat > "$E2E/bin/desktop.env" <<EOF
PATH=$PATH
HOME=$E2E/desktop-home
PYTHONPATH=$E2E/fakesdk
PYTHONDONTWRITEBYTECODE=1
FM_HOME=$E2E/home
FM_FAKE_STATE=$E2E/turn-counter
FM_FAKE_LOG=$E2E/model-sessions.jsonl
FM_FAKE_THINK=0.4
FM_FAKE_REPLY_SECONDS=0.4
FM_FAKE_SCRIPT=status,handover
FM_FAKE_REQUEST=$E2E_REQUEST
AWS_ACCESS_KEY_ID=$E2E_KEY
AWS_SECRET_ACCESS_KEY=desktop-secret-not-a-real-key
EOF

# Stands in for ssh, so the client takes its real `ssh -T <host> <relay>` path
# and the desktop's environment is a boundary rather than an assertion: the relay
# starts from env -i and desktop.env, so nothing the laptop holds can reach it.
cat > "$E2E/bin/ssh" <<'SH'
#!/usr/bin/env bash
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
if [ "${1:-}" = "-T" ]; then shift; fi
shift                                   # the host, which is this machine
desktop_env=()
while IFS= read -r line; do desktop_env+=("$line"); done < "$DIR/desktop.env"
exec env -i "${desktop_env[@]}" "$@"
SH
chmod +x "$E2E/bin/ssh"

# Two seconds of speech-shaped audio ending on speech, not silence: the relay's
# own 400 ms of padding is what makes a push-to-talk release answerable, and a
# clip this long makes a clock started at the wrong end unmistakable.
python3 - "$E2E/clip.pcm" <<'PY' || fail "could not write the e2e clip"
import math, struct, sys
out = bytearray()
for n in range(16000 * 2):
    swell = 0.5 + 0.5 * math.sin(2 * math.pi * 2.5 * n / 16000)
    out += struct.pack("<h", int(9000 * swell * math.sin(2 * math.pi * 190 * n / 16000)))
open(sys.argv[1], "wb").write(bytes(out))
PY

printf '0\n' > "$E2E/turn-counter"
: > "$E2E/model-sessions.jsonl"

# env -i: the laptop has PATH and HOME and nothing else. No AWS variable, no
# interpreter that can reach Bedrock, no firstmate home.
laptop_aws=$(env -i PATH="$E2E/bin:$PATH" HOME="$E2E/laptop-home" env \
  | grep -c '^AWS_' || true)
[ "$laptop_aws" = 0 ] || fail "the laptop end should hold no AWS variables"

set +e
env -i PATH="$E2E/bin:$PATH" HOME="$E2E/laptop-home" PYTHONDONTWRITEBYTECODE=1 \
  python3 "$E2E/laptop/fm-voice-client.py" \
    --host desktop.example \
    --relay "$ROOT/bin/fm-voice-relay.py" \
    --relay-python python3 \
    --in-file "$E2E/clip.pcm" --out-file "$E2E/reply.pcm" \
    --runs 2 > "$E2E/runs.jsonl" 2> "$E2E/session.log"
e2e_code=$?
set -e
[ "$e2e_code" = 0 ] || {
  cat "$E2E/session.log" >&2
  fail "the spoken round trip exited $e2e_code"
}

# The reader's own answer, taken independently, so the spoken answer is checked
# against the records rather than against itself.
independent=$(python3 "$ROOT/bin/fm_voice_records.py" status \
  --home "$E2E/home" --scope full) || fail "independent status read failed"
printf '%s' "$independent" > "$E2E/independent.json"

python3 - "$E2E" "$E2E_KEY" "$E2E_REGION" "$E2E_MODEL" "$E2E_REQUEST" \
  "$NEVER_TOKEN" <<'PY' || fail "the spoken round trip did not hold"
import json, os, sys

root, key, region, model, request, never = sys.argv[1:7]


def check(cond, label):
    if not cond:
        sys.exit("round trip: " + label)


def read(name):
    with open(os.path.join(root, name), encoding="utf-8") as handle:
        return [json.loads(line) for line in handle if line.strip()]


runs = read("runs.jsonl")
sessions = read("model-sessions.jsonl")
records = json.load(open(os.path.join(root, "independent.json"), encoding="utf-8"))
transcript = open(os.path.join(root, "session.log"), encoding="utf-8").read()

# Two turns asked, two turns answered with audio, neither of them lost.
check(len(runs) == 2, "expected two turn records, got %d" % len(runs))
check(len(sessions) == 2, "expected two model sessions, got %d" % len(sessions))
for run in runs:
    check(run["answered"], "turn %s was not answered" % run["run"])
    check(run["relay_error"] is None,
          "turn %s failed: %s" % (run["run"], run["relay_error"]))
    check(run["reply_audio_seconds"] > 0,
          "turn %s produced no reply audio" % run["run"])
    # Push to talk is the default and the only mode that runs, and the transport
    # is the ssh path rather than a local child.
    check(run["listen"] == "push-to-talk", "listen mode was %r" % run["listen"])
    check(run["transport"] == "ssh", "transport was %r" % run["transport"])
    # The per-turn reconnect exists so a second question is not barge-in.
    check(not run["interrupted"],
          "turn %s was treated as an interruption" % run["run"])

# Whose account and which model. The relay carries no default for either, so
# this is the home's configuration reaching Bedrock, and the credential is the
# one only the desktop side of the connection holds.
for session in sessions:
    check(session["model_id"] == model, "model was %r" % session["model_id"])
    check(session["region"] == region, "region was %r" % session["region"])
    check(session["endpoint"] ==
          "https://bedrock-runtime.{}.amazonaws.com".format(region),
          "endpoint was %r" % session["endpoint"])
    check(session["credential_key_id"] == key,
          "session opened with %r" % session["credential_key_id"])
    check(session["tool_names_offered"] ==
          ["get_fleet_status", "hand_over_to_firstmate"],
          "tools offered were %r" % session["tool_names_offered"])
    # Trap 2: a push-to-talk release supplies no trailing silence, so the relay
    # appends its own. Without it the model truncates the turn and never answers.
    check(session["audio_bytes_in"] == 16000 * 2 * 2 + 400 * 32,
          "the uplink carried %d bytes, so the talk-end padding is not being "
          "sent" % session["audio_bytes_in"])

# The status answer is the records. Every number the agent said aloud came from
# the reader, checked against a separate read of the same home.
status = sessions[0]
check([c["name"] for c in status["tool_calls"]] == ["get_fleet_status"],
      "the status turn called %r" % [c["name"] for c in status["tool_calls"]])
served = status["tool_calls"][0]["result"]
for field in ("in_flight", "awaiting_captain", "open_pull_requests", "queued"):
    check(served[field] == records[field],
          "the reader served %s=%r but the records say %r"
          % (field, served[field], records[field]))
said = " ".join(status["said"])
check("{} in flight".format(records["in_flight"]) in said,
      "the spoken answer did not carry the count: %r" % said)
check(records["in_flight_detail"][0]["id"] in said,
      "the spoken answer named no open work: %r" % said)
check(never not in said and never not in json.dumps(served),
      "a note body or finished title reached a spoken answer")
check(said in transcript, "the captain never saw the answer: %r" % transcript)

# The handover turn queues real work and says so. The note is firstmate's own
# queue, written by bin/fm-inbox.sh, and the agent's confirmation carries the id
# that queue gave it, so it cannot be claiming to have queued something it did
# not.
handover = sessions[1]
check([c["name"] for c in handover["tool_calls"]] == ["hand_over_to_firstmate"],
      "the handover turn called %r" % [c["name"] for c in handover["tool_calls"]])
check(handover["tool_calls"][0]["arguments"]["request"] == request,
      "the captain's words were rewritten: %r"
      % handover["tool_calls"][0]["arguments"])
queued = handover["tool_calls"][0]["result"]
check(queued.get("queued") is True, "the request was not queued: %r" % queued)
note_id = queued.get("note_id")
check(bool(note_id), "the queue returned no note id: %r" % queued)
check(runs[1]["queued_note"] == note_id,
      "the client was told %r, the queue wrote %r"
      % (runs[1]["queued_note"], note_id))
check(note_id in " ".join(handover["said"]),
      "the agent did not confirm the queued note: %r" % handover["said"])
check("handed to the first mate" in transcript,
      "the captain was never told it was handed over: %r" % transcript)
note = os.path.join(root, "home", "state", "inbox", note_id + ".note")
check(os.path.exists(note), "no note on disk at %s" % note)
check(request in open(note, encoding="utf-8").read(),
      "the note does not carry the captain's words")

# THE NUMBER THIS BUILD EXISTS TO PRODUCE, and the instant it is measured from.
# The clip is two seconds long and the stand-in waits 0.4 s before speaking, so a
# figure measured from the captain's talk end lands near half a second and one
# measured from the start of their speech lands near two and a half. The bound is
# loose enough for a loaded machine and nowhere near the wrong clock.
for run in runs:
    first = run["first_audio_s"]
    check(first is not None, "turn %s reported no first audio" % run["run"])
    check(0.2 < first < 1.6,
          "turn %s reported first audio at %.3fs, which is not measured from the "
          "captain's talk end" % (run["run"], first))
    marks = run["relay_marks_since_talk_end"]
    for mark in ("tool_use", "tool_answered", "first_audio", "reply_end"):
        check(mark in marks, "turn %s is missing the %s mark" % (run["run"], mark))
    check(marks["tool_use"] <= marks["first_audio"] <= marks["reply_end"],
          "turn %s reports its marks out of order: %r" % (run["run"], marks))
    check(run["first_frame_s"] is not None and run["first_played_s"] is not None,
          "turn %s reported no wire or playback figure" % run["run"])

# The reply audio survived the framing byte for byte.
sent = sum(s["reply_audio_bytes"] for s in sessions)
got = os.path.getsize(os.path.join(root, "reply.pcm"))
check(sent > 0 and sent == got,
      "the model sent %d bytes of reply audio and the client wrote %d" % (sent, got))

# AND NOTHING ALARMING WAS SAID, which is the other half of every fault line this
# build added. The relay's goodbye arrives on this path too, at the end of every
# ordinary session, so a line that reads as a fault would fire here on a session
# where all of it worked. An alarm that also goes off on success is worse than no
# alarm: the captain learns to skip it, and then the one that means their question
# was lost is invisible as well. The session end still speaks, in its own words.
for alarming in ("stopped without being asked", "could not handle the relay's",
                 "connection lost", "the connection ended",
                 "were not taken", "no reply within"):
    check(alarming not in transcript,
          "a session where every turn was answered said %r: %r"
          % (alarming, transcript))
# And no record named a reason, which is what now decides the exit code as well.
# A fault that fires on a session where everything worked would fail every clean
# run from here on, so the absence is worth pinning next to the exit code itself.
for run in runs:
    check(run["relay_error"] is None,
          "turn %s recorded a reason on a session that worked: %r"
          % (run["run"], run["relay_error"]))
check("the relay signed off" in transcript,
      "but the end of the session should still be said, in wording that cannot be "
      "read as a fault: %r" % transcript)
PY
pass "a spoken turn goes out and comes back: the records answer, firstmate gets the work"

# --- a model session that ends while the captain is still talking ------------
#
# A Bedrock session ending is not a fault. The stream simply stops: no exception,
# no stop reason, nothing to report. It can happen mid-conversation, and when it
# does the captain is usually still holding the talk key, because that is when
# the relay is talking to the model at all.
#
# The relay used to treat that as its own reason to stop, which is the worst
# available failure shape: the relay dies without saying anything the captain can
# act on, and they find out by speaking a whole question into nothing and getting
# no answer. Per-turn reconnect already covers this - the next talk key builds a
# new session, at a measured cost of 0.02 s - and a reconnect that cannot be made
# is spoken to the captain through the turn-failed path. So the session ending
# costs them the remainder of one key press, and nothing else.
#
# This case is the round trip above with one difference: the model finishes with
# the first session 300 ms into a two second key press. What it holds is that the
# relay is still serving afterwards and that the NEXT talk key gets a working
# session rather than a closed pipe - a real answer, out of the real records, over
# the same connection. The relay may exit for three reasons and this is not one of
# them.

SURVIVE="$E2E/survive"
mkdir -p "$SURVIVE/bin"

# The same desktop, with its own turn script and its own record of what the model
# was asked, so neither run can read the other's sessions.
grep -v '^FM_FAKE_' "$E2E/bin/desktop.env" > "$SURVIVE/bin/desktop.env"
cat >> "$SURVIVE/bin/desktop.env" <<EOF
FM_FAKE_STATE=$SURVIVE/turn-counter
FM_FAKE_LOG=$SURVIVE/model-sessions.jsonl
FM_FAKE_THINK=0.4
FM_FAKE_REPLY_SECONDS=0.4
FM_FAKE_SCRIPT=clean-end,status
EOF
cp "$E2E/bin/ssh" "$SURVIVE/bin/ssh"
printf '0\n' > "$SURVIVE/turn-counter"
: > "$SURVIVE/model-sessions.jsonl"

# Exit 1 is the honest outcome and what is asserted: one of the two turns really
# was lost, because the model stopped listening part way through it.
set +e
env -i PATH="$SURVIVE/bin:$PATH" HOME="$E2E/laptop-home" PYTHONDONTWRITEBYTECODE=1 \
  python3 "$E2E/laptop/fm-voice-client.py" \
    --host desktop.example \
    --relay "$ROOT/bin/fm-voice-relay.py" \
    --relay-python python3 \
    --in-file "$E2E/clip.pcm" --out-file "$SURVIVE/reply.pcm" \
    --timeout 12 --runs 2 > "$SURVIVE/runs.jsonl" 2> "$SURVIVE/session.log"
survive_code=$?
set -e
[ "$survive_code" = 1 ] || {
  cat "$SURVIVE/session.log" >&2
  fail "a lost turn and a good one should exit 1, not $survive_code"
}

python3 - "$SURVIVE" "$E2E/independent.json" <<'PY' \
  || fail "a model session ending did not leave the relay serving"
import json, os, sys

root, records_path = sys.argv[1:3]

CLIP_BYTES = 16000 * 2 * 2


def check(cond, label):
    if not cond:
        sys.exit("session ended: " + label)


def read(name):
    with open(os.path.join(root, name), encoding="utf-8") as handle:
        return [json.loads(line) for line in handle if line.strip()]


runs = read("runs.jsonl")
sessions = read("model-sessions.jsonl")
records = json.load(open(records_path, encoding="utf-8"))
transcript = open(os.path.join(root, "session.log"), encoding="utf-8").read()

# The first session really did end part way through the captain's key press,
# rather than after answering: it took some of the clip and not all of it.
check(len(sessions) >= 1, "the model was never asked anything")
first = sessions[0]
check(first["turn_kind"] == "clean-end" and first.get("ended_early"),
      "the first session did not end early: %r" % first)
check(0 < first["audio_bytes_in"] < CLIP_BYTES,
      "the session ended after %d of %d bytes, so it did not end mid-press"
      % (first["audio_bytes_in"], CLIP_BYTES))
check(not first["said"] and not first["reply_audio_bytes"],
      "the lost turn was answered after all: %r" % first)

# THE POINT. The relay was still there for the next talk key, so two turns were
# taken over the one connection and the second one was a whole session of its own.
check(len(runs) == 2,
      "the relay stopped serving when the model ended its session: %d turn(s) "
      "taken, %r" % (len(runs), transcript))
check(len(sessions) == 2,
      "the next talk key did not get a session: %d opened" % len(sessions))
check(not runs[0]["answered"], "the lost turn should be the first one: %r" % runs[0])
# An ordinary session end is not a turn FAILURE - the relay names none, marks the
# session spent for nobody, and the next talk key gets a working one - but the
# turn it landed in still has no answer, and the record has to say why. Left null
# there, the only turn in this whole file that went unanswered for a knowable
# reason reads in runs.jsonl exactly like a turn the model declined, and that file
# is where the published latency spread comes from.
check(runs[0]["relay_error"],
      "a turn released by the session ending must name why it has no answer: %r"
      % runs[0])
check("session" in runs[0]["relay_error"],
      "and it should name the session ending rather than some other fault: %r"
      % runs[0]["relay_error"])
check("could not finish that turn" not in transcript,
      "the relay must not have called this a failed turn: %r" % transcript)

# And it was a working session rather than a closed pipe: a real answer, composed
# from a real read of the records, spoken to the captain over the same connection.
good = runs[1]
check(good["answered"] and good["reply_audio_seconds"] > 0,
      "the next talk key got no answer: %r" % good)
check(good["relay_error"] is None,
      "the replacement session failed: %r" % good["relay_error"])
check([c["name"] for c in sessions[1]["tool_calls"]] == ["get_fleet_status"],
      "the replacement turn called %r"
      % [c["name"] for c in sessions[1]["tool_calls"]])
# The whole question, not an answer to nothing: every byte of the clip and the
# talk-end padding reached the replacement session.
check(sessions[1]["audio_bytes_in"] == CLIP_BYTES + 400 * 32,
      "the replacement session heard %d bytes of a %d byte question"
      % (sessions[1]["audio_bytes_in"], CLIP_BYTES + 400 * 32))
served = sessions[1]["tool_calls"][0]["result"]
for field in ("in_flight", "open_pull_requests"):
    check(served[field] == records[field],
          "the replacement session served %s=%r but the records say %r"
          % (field, served[field], records[field]))
said = " ".join(sessions[1]["said"])
check("{} in flight".format(records["in_flight"]) in said,
      "the answer did not carry the count: %r" % said)
check(said in transcript, "the captain never heard the answer: %r" % transcript)
check(good["first_audio_s"] is not None and 0.2 < good["first_audio_s"] < 1.6,
      "the recovered turn reported first audio at %r, which is not measured from "
      "the captain's talk end" % good["first_audio_s"])
check(os.path.getsize(os.path.join(root, "reply.pcm"))
      == sessions[1]["reply_audio_bytes"],
      "the reply audio the client wrote is not what the good session sent")

# Said once. The rest of that key press is another seventeen audio frames, and
# the flag saying the session is over stays set for every one of them, so a
# notice sent from the frame loop instead of from the end itself would put this
# line in front of the captain ten times a second while they were still speaking.
check(transcript.count("the relay ended the session") == 1,
      "the session ending was announced %d times: %r"
      % (transcript.count("the relay ended the session"), transcript))
check("connection lost" not in transcript,
      "the connection should have outlived the session: %r" % transcript)
PY
pass "a model session that ends mid-conversation costs one turn, not the relay"

# --- an uplink that stops being a frame stream --------------------------------
#
# One of the three things that ends the relay, and the only one it diagnoses: the
# captain's uplink desynchronises, so the relay can no longer tell a header from
# audio. It writes what it saw on its own stderr and exits 2, which is honest,
# and it used to tell the client only goodbye. Everything the relay knew stayed
# on a stderr no run file quotes, while the turn the captain was in the middle of
# came back as answered: false with nothing in relay_error - the reason existed
# and was thrown away.
#
# Worse, the teardown closes the model session first, and that sets the flag which
# silences the session reader's own notice, so this path really did send the client
# nothing at all but the goodbye.
#
# The relay is driven directly here rather than through the client, because no
# client sends a bad frame: the desync is the transport corrupting one, and the
# only way to put one on the wire is to be the other end. The model is the same
# stand-in the round trip above uses, and it is never asked to answer.

set +e
env -i PATH="$PATH" HOME="$E2E/desktop-home" PYTHONPATH="$E2E/fakesdk" \
  PYTHONDONTWRITEBYTECODE=1 FM_HOME="$E2E/home" \
  AWS_ACCESS_KEY_ID="$E2E_KEY" \
  AWS_SECRET_ACCESS_KEY=desktop-secret-not-a-real-key \
  python3 - "$ROOT/bin" <<'PY'
import os, subprocess, sys
sys.path.insert(0, sys.argv[1])
import fm_voice_frame as frame

relay = os.path.join(sys.argv[1], "fm-voice-relay.py")


def check(cond, label):
    if not cond:
        sys.exit("desync: " + label)


proc = subprocess.Popen(
    [sys.executable, relay, "--serve"],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
try:
    magic = proc.stdout.read(len(frame.MAGIC))
    check(magic == frame.MAGIC, "the relay did not open the stream: %r" % magic)
    reader = frame.Reader(proc.stdout)
    kind, payload = reader.read()
    check(kind == frame.NOTICE
          and frame.decode_json(payload).get("event") == "ready",
          "the relay was never ready: %r %r" % (kind, payload))

    # A turn is open when the uplink goes, which is when it goes in practice: the
    # captain is holding the talk key, so that is when there are frames on the
    # wire to be corrupted at all.
    proc.stdin.write(frame.encode(frame.TALK_START))
    proc.stdin.write(b"\xff\x00\x00\x00\x00")
    proc.stdin.flush()

    frames = []
    while True:
        got = reader.read()
        if got is None:
            break
        frames.append(got)
        if got[0] == frame.BYE:
            break
finally:
    proc.stdin.close()
    said = proc.stderr.read().decode("utf-8", "replace")
    code = proc.wait(timeout=30)

kinds = [k for k, _ in frames]
check(frame.BYE in kinds, "the relay never said goodbye: %r" % kinds)
named = [n for n in (frame.decode_json(p) for k, p in frames if k == frame.NOTICE)
         if n.get("event") == "turn-failed"]
check(named,
      "the relay diagnosed the fault and told the client only goodbye: %r" % kinds)
check("FrameError" in named[0].get("error", ""),
      "the notice should carry what the relay saw: %r" % named[0])
# Before the goodbye, and before the model session is closed: closing it awaits
# the model stream, which can be slow or raise, and the client must learn the
# reason either way.
failed_at = next(i for i, (k, p) in enumerate(frames)
                 if k == frame.NOTICE
                 and frame.decode_json(p).get("event") == "turn-failed")
check(failed_at < kinds.index(frame.BYE),
      "the reason must reach the client ahead of the goodbye: %r" % kinds)

# Still said on the relay's own stderr, which the captain reads over SSH, and
# still the unhappy exit code: naming the fault down the connection does not make
# it a turn the relay recovered from.
check("not a frame stream any more" in said,
      "the relay should still name the desync on its stderr: %r" % said)
check(code == 2, "a desynchronised uplink must exit 2, got %r" % code)
PY
desync_code=$?
set -e
[ "$desync_code" = 0 ] || fail "a desynchronised uplink was not named to the client"
pass "a desynchronised uplink is named to the client before the goodbye, not only to stderr"

# --- the desktop's own check, and the clock it refuses to lie about ----------
#
# `fm-voice-relay.py --self-test <clip.pcm>` is what docs/voice-relay.md tells the
# captain to run before they touch the laptop, and it is also the instrument the
# direct column of the latency table was measured with. Everything above drives
# the relay through the client; this drives the desktop check itself, because a
# broken --self-test is a captain who cannot tell a configured desktop from an
# unconfigured one, and a number in a table that nobody can reproduce.
#
# The second case is the one worth having. A clip that already ends in silence
# makes the model answer before this end of the stream has said the turn is over,
# so every figure is measured from the wrong instant and comes out negative. The
# reply really is fast and the number really is meaningless, which is the worst
# combination to leave in a results file for someone who was not here. The guard
# has to name the marks and say why, not print the figure.

SELFTEST="$E2E/self-test"
mkdir -p "$SELFTEST"
printf '0\n' > "$SELFTEST/turn-counter"

# The same two seconds of speech, with a second of silence glued on the end: the
# shape the docs warn against, and the only way to reach the guard.
cat "$E2E/clip.pcm" > "$SELFTEST/ends-in-silence.pcm"
python3 - "$SELFTEST/ends-in-silence.pcm" <<'PY' \
  || fail "could not write the silence-tailed clip"
import sys
with open(sys.argv[1], "ab") as handle:
    handle.write(b"\x00\x00" * 16000)
PY

# The desktop, and only the desktop: the AWS credential and the SDK live here.
relay_self_test() {
  local clip=$1
  shift
  env -i PATH="$PATH" HOME="$E2E/desktop-home" PYTHONPATH="$E2E/fakesdk" \
    PYTHONDONTWRITEBYTECODE=1 FM_HOME="$E2E/home" \
    FM_FAKE_STATE="$SELFTEST/turn-counter" FM_FAKE_LOG="$SELFTEST/sessions.jsonl" \
    FM_FAKE_THINK=0.4 FM_FAKE_REPLY_SECONDS=0.4 FM_FAKE_SCRIPT=status \
    AWS_ACCESS_KEY_ID="$E2E_KEY" \
    AWS_SECRET_ACCESS_KEY=desktop-secret-not-a-real-key \
    "$@" python3 "$ROOT/bin/fm-voice-relay.py" --self-test "$clip"
}

set +e
ok_out=$(relay_self_test "$E2E/clip.pcm" 2> "$SELFTEST/ok.err")
ok_code=$?
set -e
expect_code 0 "$ok_code" "the documented desktop check should answer"
printf '%s\n' "$ok_out" > "$SELFTEST/ok.json"

python3 - "$SELFTEST/ok.json" "$E2E/independent.json" "$E2E_REGION" "$E2E_MODEL" \
  <<'PY' || fail "the desktop check did not report a usable measurement"
import json, sys

report = json.load(open(sys.argv[1], encoding="utf-8"))
records = json.load(open(sys.argv[2], encoding="utf-8"))
region, model = sys.argv[3:5]


def check(cond, label):
    if not cond:
        sys.exit("self-test: %s -- %r" % (label, report))


check(report["mode"] == "self-test", "not a self-test report")
check(report["answered"] and report["reply_audio_seconds"] > 0, "it did not answer")
check(report["relay_error"] is None, "it reported an error")
check(report["region"] == region and report["model"] == model,
      "it used the wrong account's model")
check(report["tool_names"] == ["get_fleet_status"], "it called the wrong tool")
# The words are the records, the same as over the relay.
check("{} in flight".format(records["in_flight"]) in report["said"],
      "the spoken answer did not carry the count")
check(report["heard"], "it reported nothing heard")
# The figure the direct column of the latency table is made of, measured from the
# talk end: the clip is two seconds and the stand-in thinks for 0.4 s, so a clock
# started at the wrong end lands near 2.4.
check(report["clock_unusable"] == [], "it flagged a clip that ends on speech")
for mark in ("tool_use_s", "first_audio_s", "reply_end_s"):
    check(report[mark] is not None, "no %s figure" % mark)
check(0.2 < report["first_audio_s"] < 1.6,
      "first audio at %r is not measured from the talk end" % report["first_audio_s"])
check(report["tool_use_s"] <= report["first_audio_s"] <= report["reply_end_s"],
      "the figures are out of order")
PY
pass "the desktop's own check answers from the records and times it from the talk end"

set +e
early_out=$(relay_self_test "$SELFTEST/ends-in-silence.pcm" FM_FAKE_EARLY=1 \
  2> "$SELFTEST/early.err")
early_code=$?
set -e
expect_code 0 "$early_code" "an answered turn is still an answered turn"
printf '%s\n' "$early_out" > "$SELFTEST/early.json"

early_err=$(cat "$SELFTEST/early.err")
assert_contains "$early_err" "measured from the wrong instant" \
  "the guard must say why the timings cannot be used"
assert_contains "$early_err" "ends on speech" \
  "the guard must say what clip to pass instead"

python3 - "$SELFTEST/early.json" <<'PY' \
  || fail "a reply that beat the end of the clip was recorded as a good measurement"
import json, sys

report = json.load(open(sys.argv[1], encoding="utf-8"))


def check(cond, label):
    if not cond:
        sys.exit("wrong clock: %s -- %r" % (label, report))


# It answered. That is exactly why the figure is dangerous rather than obviously
# broken: a reader sees answered: true and a fast number.
check(report["answered"] and report["reply_audio_seconds"] > 0,
      "the turn was not answered at all, so this is not the case under test")
check(report["first_audio_s"] < 0,
      "the reply did not beat the end of the clip, so the guard was not reached")
for mark in ("tool_use", "first_audio", "reply_end"):
    check(mark in report["clock_unusable"], "%s is not named as unusable" % mark)
PY
pass "a reply that arrives before the end of the clip is named as an unusable clock"

printf 'all voice relay cases passed\n'
