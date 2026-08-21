#!/usr/bin/env python3
"""fm-voice-relay.py - hold the Nova Sonic session on this desktop, on behalf of the laptop.

The captain talks into their laptop. The laptop captures audio and streams it
over the SSH connection it already has to this desktop. This relay holds the
Bedrock bidirectional session, answers the model's tool calls from firstmate's
records, and streams the spoken reply back down the same connection. AWS
credentials therefore stay on this desktop and never go near the laptop, which
is the whole reason for the shape.

The voice agent this relay runs is NOT firstmate. It stands in front of
firstmate: it answers questions about the fleet from the records, and when the
captain asks for real work it says out loud that it is handing the request over
and then queues it. It never claims to have done the work.

Modes:
  --serve            read fm_voice_frame frames on stdin, write them on stdout.
                     This is what the laptop client runs over SSH, and the
                     default when no mode is given.
  --self-test FILE   feed one raw 16 kHz PCM file into a session as if it had
                     arrived from the client, print the timings as JSON, exit.
                     This is the control measurement for the relay path, and it
                     needs no client, no SSH and no microphone.

The two traps this code already avoids, both found the expensive way and
recorded in data/speech-to-speech-survey-s2/report.md section 10:

  1. completionEnd does not arrive on its own. The model holds the session open
     waiting for more speech. The real "the reply is finished" signal is a
     contentEnd carrying stopReason END_TURN.
  2. Audio with no trailing silence is truncated and never answered, even when
     contentEnd follows immediately. A push-to-talk release supplies no trailing
     silence at all, so this relay appends its own on talk end. --tail-ms sets
     how much. Measured here, the tail is a content requirement and not a time
     one: nothing was answered at 0 or 100 ms, everything was answered from
     200 ms up, and 200 through 800 ms all landed in the same spread because the
     silence is sent unpaced. The 400 ms default is margin that costs nothing.

Read scope, deny list and the handover queue all belong to bin/fm_voice_records.py.
docs/voice-relay.md is the operator-facing guide and owns the wire contract.

Usage:
  fm-voice-relay.py [--serve] [options]
  fm-voice-relay.py --self-test <file.pcm> [options]

Options:
  --region <name>       Bedrock region.              default eu-north-1
  --model <id>          Nova Sonic model id.         default amazon.nova-2-sonic-v1:0
  --profile <name>      AWS profile.                 default inthuson-ct-sandbox
  --voice <id>          output voice.                default matthew
  --home <dir>          firstmate home for records.  default $FM_HOME or this repo
  --scope <name>        override the read scope for this run.
  --tail-ms <int>       silence appended on talk end. default 400
  --turn-timeout <sec>  how long --self-test waits.   default 40
  --verbose             log the session to stderr.
"""

import argparse
import asyncio
import base64
import datetime
import json
import os
import queue
import subprocess
import sys
import threading
import time
import traceback
import uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import fm_voice_frame as frame              # noqa: E402
import fm_voice_records as records          # noqa: E402

REGION = "eu-north-1"
# amazon.nova-sonic-v1:0 is marked legacy by AWS and measured 25 percent slower
# on the tool-backed path, which is the path this interface actually uses.
MODEL = "amazon.nova-2-sonic-v1:0"
PROFILE = "inthuson-ct-sandbox"
VOICE = "matthew"

IN_RATE = 16000
OUT_RATE = 24000
# 3200 bytes is 100 ms at 16 kHz 16-bit mono, the chunk size the survey measured
# its timings with. Keeping it identical keeps those numbers comparable.
CHUNK = 3200
BYTES_PER_MS_IN = IN_RATE * 2 // 1000

# Push-to-talk supplies no trailing silence, and trap 2 above means a turn with
# none is never answered. 400 ms is the measured floor plus one chunk of margin;
# see docs/voice-relay.md for the runs behind it.
TAIL_MS = 400

SYSTEM_PROMPT = (
    "You are the captain's voice assistant. You are NOT the first mate, and you "
    "must never claim to be. You stand in front of the first mate and you are "
    "the captain's spoken way of reaching it.\n"
    "\n"
    "When the captain asks how things are going, what is in flight, what is "
    "waiting on them, or whether anything is ready to review, call "
    "get_fleet_status and answer from what it returns. Give counts and at most a "
    "couple of names. Never invent a number, a name or a pull request. If the "
    "tool says detail is withheld, say the detail is not available by voice.\n"
    "\n"
    "Call get_fleet_status every single time the captain asks, including when "
    "they asked a moment ago. The records change while you are talking, and an "
    "answer repeated from memory is a stale answer given confidently, which is "
    "worse than a slow one.\n"
    "\n"
    "When the captain asks for actual work, anything that would change code, "
    "open a pull request, investigate a bug, or start a job, you do not do it "
    "and you do not pretend to. Say out loud that you are handing it to the "
    "first mate, then call hand_over_to_firstmate with the captain's request in "
    "their own words. Then confirm it is queued. Never say you have done, "
    "started, fixed or built anything yourself.\n"
    "\n"
    "Speak in one or two short sentences. You are being listened to, not read."
)

TOOLS = {"tools": [
    {"toolSpec": {
        "name": "get_fleet_status",
        "description": (
            "Read the first mate's durable records: how many jobs are in "
            "flight, how many decisions are waiting on the captain, how many "
            "pull requests are open, and the names of a few of them."),
        "inputSchema": {"json": json.dumps(
            {"type": "object", "properties": {}, "required": []})},
    }},
    {"toolSpec": {
        "name": "hand_over_to_firstmate",
        "description": (
            "Hand a request for real work to the first mate, which will pick it "
            "up at its next check. Use this for anything you cannot answer from "
            "the records. It queues the request and does not do the work."),
        "inputSchema": {"json": json.dumps({
            "type": "object",
            "properties": {"request": {
                "type": "string",
                "description": "The captain's request, in the captain's own words.",
            }},
            "required": ["request"],
        })},
    }},
]}


def log(enabled, message):
    if enabled:
        sys.stderr.write("relay: {}\n".format(message))
        sys.stderr.flush()


def widen_path():
    """Put the toolbox directories on PATH, as bin/fm-inbox.sh does and for the same reason.

    `ssh host command` gets no login shell, so it gets no ~/.toolbox/bin. The
    sandbox profile's credential_process is the bare word `ada`, so without this
    the relay starts, connects to nothing, and reports a missing file. That is
    the normal way this relay is launched, so it has to hold here.
    """
    extra = [os.path.expanduser(p) for p in ("~/.toolbox/bin", "~/.local/bin")]
    parts = os.environ.get("PATH", "").split(os.pathsep)
    added = [p for p in extra if os.path.isdir(p) and p not in parts]
    if added:
        os.environ["PATH"] = os.pathsep.join(added + parts)


# A credential that states an expiry this interpreter cannot read. The
# credential itself is fine; only its deadline is unknown, and that is not the
# same thing as not having one.
EXPIRY_UNKNOWN = object()


def _expires_at(stamp):
    """Return the expiry as epoch seconds, None when there is none, or EXPIRY_UNKNOWN.

    The two failure shapes mean opposite things and must not collapse into one.
    No Expiration at all is a credential that does not expire. An Expiration
    that will not parse, such as an offset written +0000 on an interpreter older
    than 3.11, is a credential that does expire at a moment this process cannot
    read, and treating that as "never" would cache it past its real deadline and
    fail every session from then on.
    """
    if not stamp:
        return None
    try:
        when = datetime.datetime.fromisoformat(str(stamp).replace("Z", "+00:00"))
    except ValueError:
        return EXPIRY_UNKNOWN
    if when.tzinfo is None:
        when = when.replace(tzinfo=datetime.timezone.utc)
    return when.timestamp()


def ambient_credentials(verbose=False, margin=0):
    """Return (credentials, expiry) from the environment, or None if it has none to give.

    None means "ask the profile instead", and there are three ways to get it.
    An environment with no key id at all is the ordinary ssh case. One carrying
    a key id without a secret beside it is a half-set variable, which is a
    mistake worth naming rather than a KeyError from inside a worker thread.
    And one whose AWS_CREDENTIAL_EXPIRATION has passed, or passes within margin
    seconds, is no longer usable: os.environ cannot get fresher values while
    this process runs, so the only way forward is the profile.

    Temporary credentials with no stated deadline are reported as
    EXPIRY_UNKNOWN rather than as eternal, because a session token always has a
    deadline whether or not the shell that exported it said so.
    """
    key = os.environ.get("AWS_ACCESS_KEY_ID")
    if not key:
        return None
    secret = os.environ.get("AWS_SECRET_ACCESS_KEY")
    if not secret:
        log(verbose, "AWS_ACCESS_KEY_ID is set with no AWS_SECRET_ACCESS_KEY "
                     "beside it, so the environment is being ignored")
        return None
    token = os.environ.get("AWS_SESSION_TOKEN")
    expires = _expires_at(os.environ.get("AWS_CREDENTIAL_EXPIRATION"))
    if expires is None and token:
        expires = EXPIRY_UNKNOWN
    if expires not in (None, EXPIRY_UNKNOWN) and time.time() + margin >= expires:
        log(verbose, "the credentials in the environment have expired")
        return None
    log(verbose, "using credentials already in the environment")
    return {
        "aws_access_key_id": key,
        "aws_secret_access_key": secret,
        "aws_session_token": token,
    }, expires


def resolve_credentials(profile, verbose=False, margin=0):
    """Return (credentials dict, expiry epoch or None), preferring the environment.

    The sandbox profile's credential_process costs about a second, so ambient
    credentials win while they are usable. It also blocks the caller for that
    second, so Credentials below owns when this runs and keeps it out of a turn.
    """
    ambient = ambient_credentials(verbose, margin)
    if ambient is not None:
        return ambient
    log(verbose, "exporting credentials from profile {}".format(profile))
    widen_path()
    done = subprocess.run(
        ["aws", "configure", "export-credentials", "--profile", profile,
         "--format", "process"],
        # The relay's own stdin is the captain's audio in --serve mode. A child
        # that read it would eat frames and desynchronise the uplink, so no
        # child gets it.
        stdin=subprocess.DEVNULL,
        capture_output=True, text=True, timeout=60, check=False)
    if done.returncode != 0:
        raise SystemExit(
            "fm-voice-relay: could not get credentials for profile {}: {}".format(
                profile, (done.stderr or done.stdout).strip()))
    blob = json.loads(done.stdout)
    return {
        "aws_access_key_id": blob["AccessKeyId"],
        "aws_secret_access_key": blob["SecretAccessKey"],
        "aws_session_token": blob.get("SessionToken"),
    }, _expires_at(blob.get("Expiration"))


class Credentials:
    """The relay's credentials, resolved once and shared by every session it opens.

    A session is rebuilt for every turn, on purpose and for a measured reason
    (see renew), so resolving per session would charge the credential_process
    second to each turn after the first. The relay resolves once at start and
    every later session reuses that answer, so a reconnect costs a reconnect
    and not a credential fetch.

    Credentials that carry an expiry are refreshed a few minutes ahead of it,
    because a relay left running outlives them. One whose expiry cannot be read
    is held for that same margin and no longer, so an unreadable deadline costs
    an occasional resolution rather than every session after the deadline. The
    margin is handed to the resolver as well, because credentials taken from the
    environment cannot be refreshed in place and have to be abandoned for the
    profile once they are that close to the end.
    Every resolution, the first one included, runs in a worker thread, so the
    event loop keeps reading the captain's audio while it happens.
    """

    REFRESH_MARGIN = 300

    def __init__(self, profile, verbose=False):
        self.profile = profile
        self.verbose = verbose
        self._creds = None
        self._expires = None
        self._resolved = None
        self._lock = asyncio.Lock()

    def _usable(self):
        if self._creds is None:
            return False
        if self._expires is EXPIRY_UNKNOWN:
            return time.monotonic() - self._resolved < self.REFRESH_MARGIN
        if self._expires is None:
            return True
        return time.time() + self.REFRESH_MARGIN < self._expires

    async def get(self):
        async with self._lock:
            if not self._usable():
                self._creds, self._expires = await asyncio.to_thread(
                    resolve_credentials, self.profile, self.verbose,
                    self.REFRESH_MARGIN)
                self._resolved = time.monotonic()
            return dict(self._creds)


class Downlink:
    """Write frames to the client from one dedicated thread.

    A blocking write to a stalled SSH channel must not stop the relay reading
    the captain's audio or the model's output, and the moment a reply byte is
    actually handed to the connection is the only honest place to timestamp it.
    Both of those want the writes off the event loop, so they live here.
    """

    def __init__(self, stream):
        self._stream = stream
        self._queue = queue.Queue()
        self._first_audio = None
        self._lock = threading.Lock()
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()

    def _run(self):
        writer = frame.Writer(self._stream)
        while True:
            item = self._queue.get()
            if item is None:
                return
            kind, payload = item
            try:
                writer.send(kind, payload)
            except (BrokenPipeError, ValueError, OSError):
                return
            if kind == frame.AUDIO:
                with self._lock:
                    if self._first_audio is None:
                        self._first_audio = time.monotonic()

    def send(self, kind, payload=b""):
        self._queue.put((kind, payload))

    def send_json(self, kind, obj):
        self.send(kind, json.dumps(obj, separators=(",", ":")).encode("utf-8"))

    def arm_turn(self):
        """Forget the previous turn's first-audio mark."""
        with self._lock:
            self._first_audio = None

    def first_audio(self):
        with self._lock:
            return self._first_audio

    def close(self):
        self._queue.put(None)
        self._thread.join(timeout=5)


class Session:
    """One Nova Sonic bidirectional session, plus the turn bookkeeping around it."""

    def __init__(self, options, down, credentials):
        self.options = options
        self.down = down
        self.credentials = credentials
        self.verbose = options.verbose
        self.prompt = str(uuid.uuid4())
        self.stream = None
        self.reader_task = None
        self.audio_content = None
        self.turn = {}
        self.tool_calls = 0
        # Replies this session has finished. One is the most it should ever
        # deliver; see serve() for why a second turn gets a new session.
        self.replies = 0
        # Set when a call into the model raised, which makes this session spent
        # whether or not it ever answered. handle_uplink_frame owns it.
        self.failed = False
        # Which tools ran, in order. The handover boundary is the whole point of
        # this relay, so "it called hand_over_to_firstmate and did not answer
        # for firstmate" has to be evidence in the run record, not an inference
        # from a count.
        self.tool_names = []
        self.ended = asyncio.Event()
        self.turn_done = asyncio.Event()
        self.home = options.home or records.default_home()
        self.scope = options.scope or records.read_scope(self.home)
        self.root = os.path.dirname(os.path.abspath(__file__))

    # ---------------------------------------------------------------- protocol

    def _event(self, obj):
        from aws_sdk_bedrock_runtime.models import (
            BidirectionalInputPayloadPart,
            InvokeModelWithBidirectionalStreamInputChunk)
        return InvokeModelWithBidirectionalStreamInputChunk(
            value=BidirectionalInputPayloadPart(
                bytes_=json.dumps({"event": obj}).encode()))

    async def _send(self, obj):
        await self.stream.input_stream.send(self._event(obj))

    async def start(self):
        from aws_sdk_bedrock_runtime.client import (
            AsyncBedrockRuntimeClient,
            InvokeModelWithBidirectionalStreamOperationInput)
        from aws_sdk_bedrock_runtime.config import AsyncBedrockRuntimeConfig

        creds = await self.credentials.get()
        began = time.monotonic()
        config = await AsyncBedrockRuntimeConfig.resolve(
            endpoint_uri="https://bedrock-runtime.{}.amazonaws.com".format(
                self.options.region),
            region=self.options.region, **creds)
        client = AsyncBedrockRuntimeClient(config=config)
        self.stream = await client.invoke_model_with_bidirectional_stream(
            InvokeModelWithBidirectionalStreamOperationInput(
                model_id=self.options.model))
        self.connect_seconds = round(time.monotonic() - began, 3)
        self.reader_task = asyncio.create_task(self._read_model())

        await self._send({"sessionStart": {"inferenceConfiguration": {
            "maxTokens": 512, "topP": 0.9, "temperature": 0.7}}})
        await self._send({"promptStart": {
            "promptName": self.prompt,
            "textOutputConfiguration": {"mediaType": "text/plain"},
            "audioOutputConfiguration": {
                "mediaType": "audio/lpcm", "sampleRateHertz": OUT_RATE,
                "sampleSizeBits": 16, "channelCount": 1,
                "voiceId": self.options.voice, "encoding": "base64",
                "audioType": "SPEECH"},
            "toolUseOutputConfiguration": {"mediaType": "application/json"},
            "toolConfiguration": TOOLS}})
        content = str(uuid.uuid4())
        await self._send({"contentStart": {
            "promptName": self.prompt, "contentName": content, "type": "TEXT",
            "interactive": True, "role": "SYSTEM",
            "textInputConfiguration": {"mediaType": "text/plain"}}})
        await self._send({"textInput": {
            "promptName": self.prompt, "contentName": content,
            "content": SYSTEM_PROMPT}})
        await self._send({"contentEnd": {
            "promptName": self.prompt, "contentName": content}})
        log(self.verbose, "session up in {}s, read scope {}".format(
            self.connect_seconds, self.scope))

    async def close(self):
        if self.stream is None:
            return
        try:
            if self.audio_content:
                await self._send({"contentEnd": {
                    "promptName": self.prompt, "contentName": self.audio_content}})
                self.audio_content = None
            await self._send({"promptEnd": {"promptName": self.prompt}})
            await self._send({"sessionEnd": {}})
            await self.stream.input_stream.close()
        except Exception as exc:                       # noqa: BLE001
            log(self.verbose, "close: {}: {}".format(type(exc).__name__, exc))
        if self.reader_task is not None:
            try:
                await asyncio.wait_for(self.reader_task, timeout=10)
            except (asyncio.TimeoutError, asyncio.CancelledError):
                pass

    # ------------------------------------------------------------------ uplink

    async def talk_start(self):
        """Open an audio block for a new turn, if one is not already open."""
        if self.audio_content is not None:
            return
        self.audio_content = str(uuid.uuid4())
        self.turn = {"began": time.monotonic()}
        self.tool_calls = 0
        self.tool_names = []
        self.turn_done.clear()
        self.down.arm_turn()
        await self._send({"contentStart": {
            "promptName": self.prompt, "contentName": self.audio_content,
            "type": "AUDIO", "interactive": True, "role": "USER",
            "audioInputConfiguration": {
                "mediaType": "audio/lpcm", "sampleRateHertz": IN_RATE,
                "sampleSizeBits": 16, "channelCount": 1,
                "audioType": "SPEECH", "encoding": "base64"}}})
        log(self.verbose, "talk start")

    async def audio(self, pcm):
        """Forward captured audio, chunked the way the measurements were taken."""
        if self.audio_content is None:
            await self.talk_start()
        for at in range(0, len(pcm), CHUNK):
            await self._send({"audioInput": {
                "promptName": self.prompt, "contentName": self.audio_content,
                "content": base64.b64encode(pcm[at:at + CHUNK]).decode()}})

    async def talk_end(self):
        """Close the turn: pad with silence, then close the audio block.

        The padding is trap 2: a clip with no trailing silence is truncated and
        never answered. It is a CONTENT requirement rather than a time one. The
        padding is sent unpaced, so measured against tail_ms 200 through 800 it
        cost no wall clock at all; what it buys is the model deciding the
        captain has stopped. 400 ms is therefore free margin above the 200 ms
        floor where answers first appear.

        The clock is still taken before the padding, because that instant is
        when the captain actually stopped talking and every number this build
        reports has to be measured from there.
        """
        if self.audio_content is None:
            return
        self.turn["talk_end"] = time.monotonic()
        tail = self.options.tail_ms * BYTES_PER_MS_IN
        if tail:
            await self.audio(b"\x00" * tail)
        await self._send({"contentEnd": {
            "promptName": self.prompt, "contentName": self.audio_content}})
        self.audio_content = None
        log(self.verbose, "talk end, {} ms of silence appended".format(
            self.options.tail_ms))

    # ---------------------------------------------------------------- downlink

    def _mark(self, name, at=None):
        now = at if at is not None else time.monotonic()
        self.turn.setdefault(name, now)
        base = self.turn.get("talk_end")
        if base is None:
            return
        self.down.send_json(frame.MARK, {
            "mark": name,
            "since_talk_end": round(now - base, 3),
            "tool_calls": self.tool_calls,
        })

    # Every question worth asking about a session is a question about the order
    # of these events and the stop reason on them, so --verbose prints that
    # order. audioOutput and usageEvent are left out because they repeat many
    # times per reply and bury everything else.
    TRACE_SKIP = ("audioOutput", "usageEvent")

    def _trace(self, event):
        for name, body in event.items():
            if name in self.TRACE_SKIP:
                continue
            detail = ""
            if isinstance(body, dict):
                bits = [(k, body.get(k)) for k in ("type", "role", "stopReason")
                        if body.get(k)]
                detail = "".join(" {}={}".format(k, v) for k, v in bits)
            log(True, "event {}{}".format(name, detail))

    async def _read_model(self):
        while True:
            try:
                out = await self.stream.await_output()
                result = await out[1].receive()
            except Exception as exc:                   # noqa: BLE001
                log(self.verbose, "model stream ended: {}: {}".format(
                    type(exc).__name__, exc))
                break
            if result is None:
                break
            raw = result.value.bytes_
            if not raw:
                continue
            try:
                event = json.loads(raw.decode()).get("event", {})
            except ValueError:
                continue
            await self._handle(event)
        self.ended.set()
        self.turn_done.set()

    async def _handle(self, event):
        if self.verbose:
            self._trace(event)

        if "userSpeechEnd" in event:
            # Open microphone: the model's own detector, not a talk-end frame,
            # is what ends the turn, so the clock starts here instead.
            self.turn.setdefault("talk_end", time.monotonic())
            log(self.verbose, "model reports the captain stopped speaking")

        if "audioOutput" in event:
            pcm = base64.b64decode(event["audioOutput"].get("content", ""))
            if pcm:
                if "first_audio" not in self.turn:
                    self._mark("first_audio")
                self.down.send(frame.AUDIO, pcm)

        if "textOutput" in event:
            text = event["textOutput"].get("content", "")
            role = event["textOutput"].get("role", "")
            if text:
                self.down.send_json(frame.TEXT, {"role": role, "text": text})
                log(self.verbose, "{}: {}".format(role.lower(), text[:120]))
                if '"interrupted"' in text and "true" in text:
                    # Informational only. Stopping playback mid-sentence is
                    # barge-in, which is step three of the design, not this build.
                    self.down.send_json(frame.NOTICE, {"event": "interrupted"})

        if "toolUse" in event:
            self._mark("tool_use")
            self.tool_calls += 1
            self.tool_names.append(event["toolUse"].get("toolName", ""))
            await self._run_tool(event["toolUse"])

        if "contentEnd" in event:
            stop = event["contentEnd"].get("stopReason")
            if stop == "INTERRUPTED":
                self.down.send_json(frame.NOTICE, {"event": "interrupted"})
            if stop == "END_TURN":
                # Trap 1: this, not completionEnd, is the end of the reply.
                self._mark("reply_end")
                # first_audio above is stamped when the model event is decoded.
                # The Downlink knows the later instant when that audio reached
                # the connection, which is the one the captain hears, so it is
                # reported too rather than measured and thrown away. It can only
                # be read once the frame is out, hence here and not there.
                wire = self.down.first_audio()
                if wire is not None:
                    self._mark("first_audio_wire", wire)
                self.replies += 1
                self.turn_done.set()

    # -------------------------------------------------------------------- tools

    async def _run_tool(self, call):
        name = call.get("toolName", "")
        use_id = call.get("toolUseId")
        raw = call.get("content") or "{}"
        try:
            arguments = json.loads(raw) if isinstance(raw, str) else dict(raw)
        except ValueError:
            arguments = {}
        log(self.verbose, "tool {} {}".format(name, arguments))

        try:
            if name == "get_fleet_status":
                result = records.fleet_status(home=self.home, scope=self.scope)
            elif name == "hand_over_to_firstmate":
                request = (arguments.get("request") or "").strip()
                result = await asyncio.to_thread(
                    records.queue_request, request, self.home, self.root)
                self.down.send_json(frame.NOTICE, {
                    "event": "queued", "request": request,
                    "note_id": result.get("note_id", "")})
            else:
                result = {"error": "no such tool: {}".format(name)}
        except records.RecordError as exc:
            result = {"error": str(exc)}
        except Exception as exc:                       # noqa: BLE001
            result = {"error": "{}: {}".format(type(exc).__name__, exc)}

        content = str(uuid.uuid4())
        await self._send({"contentStart": {
            "promptName": self.prompt, "contentName": content, "type": "TOOL",
            "interactive": False, "role": "TOOL",
            "toolResultInputConfiguration": {
                "toolUseId": use_id, "type": "TEXT",
                "textInputConfiguration": {"mediaType": "text/plain"}}}})
        await self._send({"toolResult": {
            "promptName": self.prompt, "contentName": content,
            "content": json.dumps(result)}})
        await self._send({"contentEnd": {
            "promptName": self.prompt, "contentName": content}})
        self._mark("tool_answered")


async def renew(session, options, down):
    """Replace a session that has already answered once, and return the new one.

    MEASURED, and the reason this exists: a second user audio block in a session
    that has already spoken is treated as barge-in, unconditionally. The model
    raises INTERRUPTED the instant the block opens, and waiting does not help.
    Six consecutive turns were tried with no wait, with a wait until the reply's
    audio had all arrived, and with a wait of the reply's full spoken duration
    after that; every one of those interrupted every second turn. Worse, an
    interrupted turn that calls a tool is then lost outright: the model asks for
    the tool, takes the result, and never answers.

    Reconnecting instead costs 0.02 seconds, measured, and it happens when the
    captain presses the talk key rather than while they are waiting for a reply,
    so it is invisible. What it gives up is conversational memory: each turn
    starts fresh, so the captain cannot say "and what about that one". Carrying
    context across turns means handling barge-in properly, which is step three of
    the design, not this build. It also means the system prompt is sent once per
    turn rather than once per session, which is the small cost of the trade.
    """
    log(options.verbose, "renewing the session for a new turn")
    await session.close()
    fresh = Session(options, down, session.credentials)
    await fresh.start()
    down.send_json(frame.NOTICE, {
        "event": "renewed", "connect_seconds": fresh.connect_seconds})
    return fresh


async def read_uplink_frame(reader):
    """Return the next (kind, payload) the client sent, or raise on a bad header.

    The header is checked before the payload is read, not after. A
    desynchronised uplink offers a length of up to 4 GiB, and waiting for that
    many bytes is a hang where the wire format promises a loud error, with the
    captain sitting in front of a client that will never answer.
    """
    head = await reader.readexactly(frame.HEADER.size)
    kind, length = frame.HEADER.unpack(head)
    frame.check_header(kind, length)
    payload = await reader.readexactly(length) if length else b""
    return kind, payload


async def handle_uplink_frame(kind, payload, session, options, down):
    """Act on one frame from the client. Returns (session to use next, keep serving).

    Every branch below reaches the model, and the model side fails on its own:
    a reconnect can be throttled, a token can expire between turns, a stream can
    drop. Because the relay rebuilds the session on every turn by design, one
    such failure would otherwise leave the loop, end the relay with a traceback
    on the stderr the client inherits, and cost the captain a whole session for
    a single bad reconnect. Instead it is named in a notice and the session is
    marked spent, so the next press of the talk key builds a new one and tries
    again. A failure the model cannot recover from repeats the notice per turn,
    which is a captain who can hear what is wrong rather than a dead pipe.
    """
    if kind == frame.QUIT:
        return session, False
    try:
        if kind == frame.TALK_START:
            if session.failed or session.replies or session.ended.is_set():
                session = await renew(session, options, down)
            await session.talk_start()
        elif kind == frame.AUDIO:
            await session.audio(payload)
        elif kind == frame.TALK_END:
            await session.talk_end()
        else:
            log(options.verbose, "ignoring uplink kind {!r}".format(kind))
    except Exception as exc:                       # noqa: BLE001
        session.failed = True
        log(options.verbose, "turn failed: {}: {}".format(
            type(exc).__name__, exc))
        down.send_json(frame.NOTICE, {
            "event": "turn-failed",
            "error": "{}: {}".format(type(exc).__name__, exc)})
    return session, True


async def serve(options):
    """Relay frames between the client on stdin/stdout and one Nova Sonic session."""
    loop = asyncio.get_running_loop()
    reader = asyncio.StreamReader()
    await loop.connect_read_pipe(
        lambda: asyncio.StreamReaderProtocol(reader), sys.stdin.buffer)
    # Ahead of every frame, so a login shell that prints a banner on stdout
    # cannot desynchronise the client. See fm_voice_frame.MAGIC.
    sys.stdout.buffer.write(frame.MAGIC)
    sys.stdout.buffer.flush()
    down = Downlink(sys.stdout.buffer)
    session = Session(options, down, Credentials(options.profile, options.verbose))
    await session.start()
    down.send_json(frame.NOTICE, {
        "event": "ready", "model": options.model, "region": options.region,
        "read_scope": session.scope, "tail_ms": options.tail_ms,
        "connect_seconds": session.connect_seconds})

    status = 0
    try:
        while True:
            kind, payload = await read_uplink_frame(reader)
            session, serving = await handle_uplink_frame(
                kind, payload, session, options, down)
            if not serving:
                break
            # A session already marked spent is about to be replaced on the next
            # talk key, so its stream closing is expected rather than the end of
            # the relay's usefulness.
            if session.ended.is_set() and not session.failed:
                down.send_json(frame.NOTICE, {"event": "session-ended"})
                break
    except (asyncio.IncompleteReadError, ConnectionResetError):
        log(options.verbose, "client closed the connection")
    except frame.FrameError as exc:
        sys.stderr.write(
            "fm-voice-relay: the uplink is not a frame stream any more: {}\n"
            .format(exc))
        status = 2
    finally:
        await session.close()
        down.send(frame.BYE)
        down.close()
    return status


async def self_test(options):
    """Feed one PCM file through a real session and report the timings."""
    with open(options.self_test, "rb") as handle:
        pcm = handle.read()

    class Sink:
        """Stands in for the client, counting reply audio and timing its arrival.

        There is no connection here and no writer thread: this stamps its arrival
        inline, in the same coroutine that decoded the model event. So the wire
        hand-off Downlink times on the --serve path does not exist in this mode,
        and the record below reports no figure for it rather than reporting one
        that would be zero because of how this stub is built. The first_audio
        figure it does report is the model event, which is real in both modes.
        """

        def __init__(self):
            self.first = None
            self.bytes = 0
            self.heard = []
            self.said = []
            self.notices = []

        def send(self, kind, payload=b""):
            if kind == frame.AUDIO:
                if self.first is None:
                    self.first = time.monotonic()
                self.bytes += len(payload)

        def send_json(self, kind, obj):
            # The transcript is the only way to check the two things that matter
            # about a spoken answer: that the words were heard correctly, and
            # that the agent handed real work over instead of claiming it.
            if kind == frame.TEXT:
                text = (obj.get("text") or "").strip()
                if not text or text.startswith("{"):
                    return
                if obj.get("role") == "USER":
                    self.heard.append(text)
                elif obj.get("role") == "ASSISTANT":
                    self.said.append(text)
            elif kind == frame.NOTICE:
                self.notices.append(obj.get("event", ""))

        def arm_turn(self):
            self.first = None

        def first_audio(self):
            return self.first

    sink = Sink()
    session = Session(options, sink, Credentials(options.profile, options.verbose))
    await session.start()
    await session.talk_start()
    # Paced at real time, because a file pushed as fast as the socket accepts it
    # would measure the socket rather than the conversation.
    for at in range(0, len(pcm), CHUNK):
        await session.audio(pcm[at:at + CHUNK])
        await asyncio.sleep(CHUNK / (IN_RATE * 2.0))
    await session.talk_end()
    try:
        await asyncio.wait_for(session.turn_done.wait(),
                               timeout=options.turn_timeout)
    except asyncio.TimeoutError:
        session.turn["timeout"] = True
    await session.close()

    base = session.turn.get("talk_end")

    def since(name):
        at = session.turn.get(name)
        if at is None or base is None:
            return None
        return round(at - base, 3)

    # A negative figure means the model started answering before this end of the
    # stream said the turn was over, which happens when the clip handed in
    # ALREADY ends in silence: the model's own endpoint detector fires part way
    # through that silence while the file is still being streamed at real time.
    # The reply is genuinely fast in that case but the number is meaningless,
    # because it is measured from the wrong instant. Feed --self-test a clip that
    # ends on speech and let --tail-ms add the silence. This is flagged rather
    # than silently recorded, because a negative in a results file gets averaged
    # into a report by someone who was not here.
    early = [n for n in ("tool_use", "first_audio", "reply_end")
             if (since(n) or 0) < 0]
    if early:
        sys.stderr.write(
            "fm-voice-relay: {} came in before the end of the clip, so these "
            "timings are measured from the wrong instant. The clip already ends "
            "in silence; pass one that ends on speech and use --tail-ms.\n"
            .format(", ".join(early)))

    print(json.dumps({
        "mode": "self-test",
        "model": options.model,
        "region": options.region,
        "read_scope": session.scope,
        "input_seconds": round(len(pcm) / float(IN_RATE * 2), 3),
        "tail_ms": options.tail_ms,
        "connect_seconds": session.connect_seconds,
        "tool_calls": session.tool_calls,
        "tool_names": session.tool_names,
        "tool_use_s": since("tool_use"),
        "first_audio_s": since("first_audio"),
        "reply_end_s": since("reply_end"),
        "reply_audio_seconds": round(sink.bytes / float(OUT_RATE * 2), 3),
        "answered": sink.bytes > 0,
        "timed_out": bool(session.turn.get("timeout")),
        "clock_unusable": early,
        "heard": " ".join(sink.heard),
        "said": " ".join(sink.said),
        "notices": sink.notices,
    }))
    return 0 if sink.bytes > 0 else 1


def parse_args(argv):
    parser = argparse.ArgumentParser(
        prog="fm-voice-relay.py", add_help=True,
        description=__doc__.splitlines()[0])
    parser.add_argument("--serve", action="store_true")
    parser.add_argument("--self-test", metavar="FILE")
    parser.add_argument("--region", default=REGION)
    parser.add_argument("--model", default=MODEL)
    parser.add_argument("--profile", default=PROFILE)
    parser.add_argument("--voice", default=VOICE)
    parser.add_argument("--home")
    parser.add_argument("--scope", choices=records.SCOPES)
    parser.add_argument("--tail-ms", type=int, default=TAIL_MS)
    parser.add_argument("--turn-timeout", type=float, default=40.0,
                        help="seconds --self-test waits for a reply")
    parser.add_argument("--verbose", action="store_true")
    options = parser.parse_args(argv)
    if options.tail_ms < 0:
        parser.error("--tail-ms cannot be negative")
    return options


def main(argv):
    options = parse_args(argv)
    try:
        if options.self_test:
            return asyncio.run(self_test(options))
        return asyncio.run(serve(options)) or 0
    except records.RecordError as exc:
        sys.stderr.write("fm-voice-relay: {}\n".format(exc))
        return 2
    except KeyboardInterrupt:
        return 130
    except Exception as exc:                       # noqa: BLE001
        # The captain reads this stderr over SSH, so a failure that gets this
        # far says what it was in one line. --verbose still gets the traceback,
        # because whoever passed it is debugging rather than talking.
        sys.stderr.write("fm-voice-relay: {}: {}\n".format(
            type(exc).__name__, exc))
        if options.verbose:
            traceback.print_exc()
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
