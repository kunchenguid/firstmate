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

# --- the laptop end ---------------------------------------------------------
#
# The microphone and speaker paths cannot be tested from a host with neither, and
# are not tested anywhere: the first live run is their test. What IS testable is
# everything around them, and these are the pieces whose failure is hardest to
# read from the symptom. A missing -T corrupts audio rather than erroring, and a
# banner-printing login shell desynchronises the stream in a way that looks like a
# protocol bug and is not.

python3 - "$ROOT/bin" <<'PY' || fail "laptop client"
import io, os, sys
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

# The deny list is the only control the guide offers for a customer name, and it
# could not touch these items at all, because their titles were never in the field
# set it matches against.
printf '%s\n' "$FINISHED_TOKEN" > "$DONE_HOME/config/voice-read-deny"
denied_done=$(done_status) || fail "deny by a finished title failed"
assert_not_contains "$denied_done" 'pull/2' \
  "a deny substring matching a finished title must not leave its link named"
assert_not_contains "$denied_done" 'pull/3' \
  "a deny substring matching a finished title must not leave its link named"
assert_contains "$denied_done" 'pull/1' "the open task is unaffected"
pass "a finished task's pull request is neither counted nor named"

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
