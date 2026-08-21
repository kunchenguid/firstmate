#!/usr/bin/env python3
"""fm-voice-client.py - the captain's laptop end of the spoken interface.

Captures audio on the laptop, streams it over the SSH connection the captain
already has to the desktop, plays back the spoken reply, and reports how long
the round trip took. The desktop holds the Bedrock session and the AWS
credentials; this client needs neither. It needs Python and a microphone.

WHAT IS VERIFIED AND WHAT IS NOT. Read this before trusting a number from it.

  Verified on the desktop: the frame protocol, the SSH transport, the relay
  handshake, turn sequencing, the reply audio arriving intact, and the timing
  arithmetic. All of that was exercised with --in-file and --out-file, which
  replace the microphone and the speaker with files and leave everything else
  alone.

  NOT verified, and cannot be from here: the microphone capture path and the
  speaker playback path. The desktop this was written on has neither a
  microphone nor a speaker, and no worker can reach the captain's laptop. The
  sounddevice calls below are written from its documented interface and have
  never been run against a real device. Treat the first live run as the test.

TWO KINDS OF LISTENING, one setting. --listen push-to-talk is the default: the
captain says when they are talking, the model is only paid for that audio, and
nothing is streamed while they are thinking. --listen open-mic streams
continuously and lets the model decide when a turn ended, which is a nicer
conversation and costs about half again as much per minute. The captain has not
decided that question, so the cheaper one is the default and the flag is the
whole difference.

Copy this file and fm_voice_frame.py to the laptop; they are the only two files
it needs and both are standard library only, apart from sounddevice for the
audio devices.

Usage:
  fm-voice-client.py --host <sshhost> [options]
  fm-voice-client.py --local [options]          (relay as a child, no SSH)

Options:
  --host <name>          SSH destination of the desktop holding the relay.
  --local                run the relay as a local child process instead. This is
                         how the relay path is measured without a laptop.
  --relay <path>         path to fm-voice-relay.py on the desktop, or set
                         $FM_VOICE_RELAY. Required: this file carries no default,
                         because one operator's home directory is not a path to
                         hand anybody else.
  --relay-python <path>  interpreter that has aws-sdk-bedrock-runtime installed.
                         default $FM_VOICE_PYTHON or python3
  --relay-arg <arg>      extra argument for the relay, repeatable. Write it
                         joined with an equals sign, --relay-arg=--scope
                         --relay-arg=counts, or the leading dashes are read as
                         options of this client instead.
  --listen <mode>        push-to-talk (default) or open-mic.
  --runs <n>             turns to take in one session.        default 1
  --talk-seconds <sec>   capture for this long instead of waiting on a keypress.
  --in-file <file.pcm>   raw 16 kHz mono 16-bit input instead of the microphone.
  --out-file <file.pcm>  write reply audio here instead of playing it.
  --input-device <id>    sounddevice input device.
  --output-device <id>   sounddevice output device.
  --timeout <sec>        how long to wait for a reply.        default 30
  --no-wait-for-reply    open the next turn without waiting for the previous
                         answer to finish. The model treats that as being
                         interrupted and stops instead of answering, so this
                         exists to reproduce the trap, not to use.
  --gap-seconds <sec>    quiet beat after an answer finishes.  default 0.5
  --verbose              log the session to stderr.

One JSON record per turn goes to stdout; everything human goes to stderr, so
`fm-voice-client.py --host desktop --runs 5 > runs.jsonl` gives measurements and
a readable session at the same time.
"""

import argparse
import json
import os
import queue
import subprocess
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import fm_voice_frame as frame              # noqa: E402

IN_RATE = 16000
OUT_RATE = 24000
# 100 ms at each rate. The uplink chunk matches what the relay and the survey
# measured with; changing it changes the numbers.
CHUNK = 3200
OUT_BLOCK = 2400

PUSH_TO_TALK = "push-to-talk"
OPEN_MIC = "open-mic"
LISTEN_MODES = (PUSH_TO_TALK, OPEN_MIC)

# Anything the relay's login shell prints on stdout ahead of the first frame is
# discarded, up to this much. Past it, the stream is not a relay.
MAX_PREAMBLE = 8192

END = object()


def log(enabled, message):
    if enabled:
        sys.stderr.write("client: {}\n".format(message))
        sys.stderr.flush()


def say(message):
    sys.stderr.write("{}\n".format(message))
    sys.stderr.flush()


# --------------------------------------------------------------------- transport


def sync_magic(stream, verbose=False):
    """Discard anything ahead of the relay's magic preamble.

    `ssh host command` runs the command through the captain's login shell, so a
    shell startup file that prints a banner lands in front of the first frame.
    Skipping to the preamble turns that from a baffling protocol error into a
    warning naming the offending text.
    """
    seen = bytearray()
    while True:
        byte = stream.read(1)
        if not byte:
            raise frame.FrameError(
                "the relay closed the connection before it said hello; run the "
                "relay command by hand over SSH to see its error")
        seen += byte
        if seen.endswith(frame.MAGIC):
            junk = bytes(seen[: -len(frame.MAGIC)])
            if junk:
                say("client: discarded {} bytes your login shell printed before "
                    "the relay started: {!r}".format(len(junk), junk[:200]))
            log(verbose, "relay handshake found")
            return
        if len(seen) > MAX_PREAMBLE:
            raise frame.FrameError(
                "no relay handshake in the first {} bytes; the command on the "
                "far end is not fm-voice-relay.py --serve".format(MAX_PREAMBLE))


def relay_command(options):
    """Return the argv that starts the relay, locally or over SSH."""
    remote = [options.relay_python, options.relay, "--serve"]
    remote += list(options.relay_arg or [])
    if options.verbose:
        remote.append("--verbose")
    if options.local:
        return remote
    # -T because a pty would rewrite bytes in the audio stream, which is the
    # single most confusing way this could fail.
    return ["ssh", "-T", options.host] + remote


class Uplink:
    """Serialise every frame the client sends, from whichever thread sends it."""

    def __init__(self, stream):
        self._writer = frame.Writer(stream)
        self._lock = threading.Lock()

    def send(self, kind, payload=b""):
        with self._lock:
            self._writer.send(kind, payload)


# ---------------------------------------------------------------------- playback


class FilePlayback:
    """Write reply audio to a file. This is the path that can be verified here."""

    def __init__(self, path):
        self._handle = open(path, "wb")
        self.first_played = None
        self.device_latency = None
        self.bytes = 0

    def write(self, pcm):
        if self.first_played is None:
            self.first_played = time.monotonic()
        self._handle.write(pcm)
        self.bytes += len(pcm)

    def turn_reset(self):
        self.first_played = None

    def drain(self, timeout=5):
        del timeout

    def close(self):
        self._handle.close()


class SpeakerPlayback:
    """Play reply audio through the laptop speaker.

    UNVERIFIED: written from the sounddevice interface and never run against a
    real device, because the machine this was built on has no speaker. The
    timestamp is taken when the audio is handed to the device callback, which is
    the last moment this process can see. The device's own output buffer sits
    after that, so its reported latency is included in the turn record rather
    than pretended away.
    """

    def __init__(self, device=None):
        import sounddevice                    # noqa: PLC0415
        self._buffer = bytearray()
        self._lock = threading.Lock()
        self.first_played = None
        self.bytes = 0
        self._stream = sounddevice.RawOutputStream(
            samplerate=OUT_RATE, channels=1, dtype="int16",
            blocksize=OUT_BLOCK, device=device, latency="low",
            callback=self._callback)
        self._stream.start()
        self.device_latency = getattr(self._stream, "latency", None)

    def _callback(self, outdata, frames_wanted, time_info, status):
        del time_info, status
        want = frames_wanted * 2
        with self._lock:
            take = min(want, len(self._buffer))
            chunk = bytes(self._buffer[:take])
            del self._buffer[:take]
            if chunk and self.first_played is None:
                self.first_played = time.monotonic()
        outdata[:take] = chunk
        if take < want:
            outdata[take:want] = b"\x00" * (want - take)

    def write(self, pcm):
        with self._lock:
            self._buffer += pcm
        self.bytes += len(pcm)

    def turn_reset(self):
        with self._lock:
            self.first_played = None

    def drain(self, timeout=30):
        """Wait for the buffered reply to finish, so the process does not cut it off."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            with self._lock:
                if not self._buffer:
                    break
            time.sleep(0.05)
        time.sleep(0.2)

    def close(self):
        try:
            self._stream.stop()
            self._stream.close()
        except Exception:                      # noqa: BLE001
            pass


# ----------------------------------------------------------------------- capture


class FileCapture:
    """Stream a PCM file as if it were the microphone, paced at real time.

    Paced deliberately: a file pushed as fast as the socket accepts it measures
    the socket rather than the conversation.
    """

    def __init__(self, path):
        with open(path, "rb") as handle:
            self._pcm = handle.read()
        self.seconds = round(len(self._pcm) / float(IN_RATE * 2), 3)
        self.device_latency = None
        self._q = None
        self._talking = None
        self._done = threading.Event()

    def start(self, out_q, talking):
        self._q = out_q
        self._talking = talking

    def begin_turn(self):
        """Start feeding the file. One pass per turn, from the top each time."""
        self._done.clear()

        def run():
            for at in range(0, len(self._pcm), CHUNK):
                if not self._talking.is_set():
                    return
                self._q.put(self._pcm[at:at + CHUNK])
                time.sleep(CHUNK / float(IN_RATE * 2))
            self._done.set()

        threading.Thread(target=run, daemon=True).start()

    def wait_exhausted(self, timeout):
        return self._done.wait(timeout)

    def close(self):
        pass


class MicCapture:
    """Capture from the laptop microphone.

    UNVERIFIED: written from the sounddevice interface and never run against a
    real device. The stream stays open for the whole session and the gate decides
    what is sent, so push to talk costs no device setup per turn and the model is
    only paid for audio while the gate is open.
    """

    def __init__(self, device=None):
        import sounddevice                    # noqa: PLC0415
        self.seconds = None
        self._q = None
        self._talking = None
        self._stream = sounddevice.RawInputStream(
            samplerate=IN_RATE, channels=1, dtype="int16",
            blocksize=CHUNK // 2, device=device, latency="low",
            callback=self._callback)
        self._stream.start()
        self.device_latency = getattr(self._stream, "latency", None)

    def _callback(self, indata, frames_read, time_info, status):
        del frames_read, time_info, status
        if self._talking is not None and self._talking.is_set():
            self._q.put(bytes(indata))

    def start(self, out_q, talking):
        self._q = out_q
        self._talking = talking

    def begin_turn(self):
        """Nothing to do: the device stream is already open and the gate decides."""

    def wait_exhausted(self, timeout):
        del timeout
        return False

    def close(self):
        try:
            self._stream.stop()
            self._stream.close()
        except Exception:                      # noqa: BLE001
            pass


# ------------------------------------------------------------------------ client


class Client:
    """One relay connection and the turns taken over it."""

    def __init__(self, options):
        self.options = options
        self.verbose = options.verbose
        self.proc = None
        self.reader = None
        self.uplink = None
        self.playback = None
        self.capture = None
        self.up_q = queue.Queue()
        self.talking = threading.Event()
        self.ready = threading.Event()
        self.reply_done = threading.Event()
        self.closed = threading.Event()
        self.ready_notice = {}
        self.turn = {}
        self.lock = threading.Lock()

    # ------------------------------------------------------------------ lifecycle

    def open(self):
        argv = relay_command(self.options)
        log(self.verbose, "starting relay: {}".format(" ".join(argv)))
        self.proc = subprocess.Popen(
            argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        sync_magic(self.proc.stdout, self.verbose)
        self.reader = frame.Reader(self.proc.stdout)
        self.uplink = Uplink(self.proc.stdin)

        if self.options.out_file:
            self.playback = FilePlayback(self.options.out_file)
        else:
            self.playback = SpeakerPlayback(self.options.output_device)

        if self.options.in_file:
            self.capture = FileCapture(self.options.in_file)
        else:
            self.capture = MicCapture(self.options.input_device)
        self.capture.start(self.up_q, self.talking)

        threading.Thread(target=self._downlink, daemon=True).start()
        threading.Thread(target=self._sender, daemon=True).start()

        self._wait_ready()
        notice = self.ready_notice
        say("client: relay ready, {} in {}, read scope {}, connected in {}s".format(
            notice.get("model", "?"), notice.get("region", "?"),
            notice.get("read_scope", "?"), notice.get("connect_seconds", "?")))

    def _wait_ready(self):
        """Wait for the relay's ready notice, or for the connection to close first.

        A relay that dies after the handshake is the likely first-run failure:
        the Bedrock SDK is imported inside the model session, so a forgotten
        --relay-python exits the relay after the handshake and before ready. Its
        own one-line error is already on the captain's terminal, because stderr is
        inherited rather than piped, so waiting out the full timeout after that
        just leaves them watching nothing.
        """
        deadline = time.monotonic() + self.options.timeout
        while not self.ready.is_set():
            if self.closed.is_set():
                raise SystemExit(
                    "fm-voice-client: the relay closed the connection before it "
                    "was ready; run the relay command by hand over SSH to see "
                    "its error")
            if time.monotonic() >= deadline:
                raise SystemExit(
                    "fm-voice-client: the relay never reported ready; run it by "
                    "hand over SSH to see why")
            self.ready.wait(0.2)

    def close(self):
        try:
            self.uplink.send(frame.QUIT)
        except Exception:                      # noqa: BLE001
            pass
        self.capture.close()
        self.playback.drain()
        self.playback.close()
        if self.proc is not None:
            try:
                self.proc.stdin.close()
            except Exception:                  # noqa: BLE001
                pass
            try:
                self.proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.proc.kill()

    # -------------------------------------------------------------------- threads

    def _sender(self):
        """Own the uplink audio, so talk end is never sent ahead of the last chunk."""
        while True:
            item = self.up_q.get()
            if item is None:
                return
            if item is END:
                with self.lock:
                    self.turn["wire_end"] = time.monotonic()
                self.uplink.send(frame.TALK_END)
                continue
            try:
                self.uplink.send(frame.AUDIO, item)
            except (BrokenPipeError, OSError):
                return

    def _downlink(self):
        while True:
            try:
                got = self.reader.read()
            except (frame.FrameError, OSError) as exc:
                say("client: connection lost: {}".format(exc))
                break
            if got is None:
                break
            kind, payload = got
            if kind == frame.AUDIO:
                with self.lock:
                    now = time.monotonic()
                    self.turn.setdefault("first_frame", now)
                    self.turn["last_frame"] = now
                self.playback.write(payload)
            elif kind == frame.TEXT:
                obj = frame.decode_json(payload)
                text = (obj.get("text") or "").strip()
                if text and not text.startswith("{"):
                    who = "you" if obj.get("role") == "USER" else "assistant"
                    say("  {}: {}".format(who, text))
            elif kind == frame.NOTICE:
                obj = frame.decode_json(payload)
                event = obj.get("event", "")
                if event == "ready":
                    self.ready_notice = obj
                    self.ready.set()
                elif event == "queued":
                    say("  handed to the first mate: {}".format(
                        obj.get("request", "")))
                    with self.lock:
                        self.turn["queued"] = obj.get("note_id", "")
                elif event == "interrupted":
                    with self.lock:
                        self.turn["interrupted"] = True
                    log(self.verbose, "the model treated this turn as an "
                                      "interruption of its own speech")
                elif event == "turn-failed":
                    # The relay is still there and the next talk key gets a new
                    # session, so this ends the turn rather than the run.
                    say("client: the relay could not finish that turn: {}".format(
                        obj.get("error", "")))
                    with self.lock:
                        self.turn["failed"] = obj.get("error", "")
                    self.reply_done.set()
                elif event == "session-ended":
                    say("client: the relay ended the session")
                    self.reply_done.set()
                else:
                    log(self.verbose, "notice {}".format(obj))
            elif kind == frame.MARK:
                obj = frame.decode_json(payload)
                with self.lock:
                    self.turn.setdefault("marks", {})[obj.get("mark", "?")] = \
                        obj.get("since_talk_end")
                    self.turn["tool_calls"] = obj.get("tool_calls", 0)
                if obj.get("mark") == "reply_end":
                    self.reply_done.set()
            elif kind == frame.BYE:
                break
        self.closed.set()
        self.reply_done.set()

    # ---------------------------------------------------------------------- turns

    def take_turn(self, index):
        """Run one turn and return its record."""
        with self.lock:
            self.turn = {}
        self.playback.turn_reset()
        self.reply_done.clear()
        before = self.playback.bytes
        self.uplink.send(frame.TALK_START)

        if self.options.listen == OPEN_MIC:
            release = None
            self.talking.set()
            self.capture.begin_turn()
            say("client: open microphone, run {}. Speak when you like.".format(index))
        else:
            release = self._push_to_talk(index)

        deadline = self.options.timeout
        if not self.reply_done.wait(timeout=deadline):
            say("client: no reply within {}s".format(deadline))
        self._wait_audio_quiet(deadline)

        with self.lock:
            turn = dict(self.turn)
        marks = turn.get("marks", {})
        played = self.playback.first_played
        first_frame = turn.get("first_frame")

        def since(at):
            if release is None or at is None:
                return None
            return round(at - release, 3)

        record = {
            "run": index,
            "listen": self.options.listen,
            "transport": "local" if self.options.local else "ssh",
            "host": None if self.options.local else self.options.host,
            "input": self.options.in_file or "microphone",
            "output": self.options.out_file or "speaker",
            "model": self.ready_notice.get("model"),
            "region": self.ready_notice.get("region"),
            "read_scope": self.ready_notice.get("read_scope"),
            "connect_seconds": self.ready_notice.get("connect_seconds"),
            "tool_calls": turn.get("tool_calls", 0),
            "queued_note": turn.get("queued"),
            "interrupted": bool(turn.get("interrupted")),
            # Why a turn has no answer, when the relay knows. A results file
            # that only says answered: false invites the reader to average an
            # infrastructure failure into a latency figure.
            "relay_error": turn.get("failed"),
            # The number this build exists to produce: the captain stopped
            # talking, and this many seconds later sound came out.
            "first_audio_s": since(played if played is not None else first_frame),
            "first_frame_s": since(first_frame),
            "first_played_s": since(played),
            "last_frame_s": since(turn.get("last_frame")),
            "uplink_drain_s": since(turn.get("wire_end")),
            "device_output_latency_s": self.playback.device_latency,
            "device_input_latency_s": self.capture.device_latency,
            "relay_marks_since_talk_end": marks,
            "reply_audio_seconds": round(
                (self.playback.bytes - before) / float(OUT_RATE * 2), 3),
            "answered": self.playback.bytes > before,
        }
        if release is None:
            record["first_audio_note"] = (
                "An open microphone has no local end of speech, so the model's "
                "own detector is the only clock. Read "
                "relay_marks_since_talk_end instead.")
        elif not self.options.out_file:
            record["first_audio_note"] = (
                "Measured to the moment audio was handed to the output device. "
                "The device's own buffer, reported as "
                "device_output_latency_s, comes after that.")
        else:
            record["first_audio_note"] = (
                "Measured to the moment reply audio reached this process. There "
                "is no speaker in this configuration, so no playback latency is "
                "included.")
        return record

    def _wait_audio_quiet(self, deadline):
        """Wait for the reply audio to stop arriving before reading the turn.

        Measured, the last audio frame and END_TURN land within about ten
        milliseconds of each other, audio first, so this almost always returns
        at once. It is here because the count of reply audio is what the
        no-overlap wait below depends on, and a turn that ends any other way,
        such as the session closing, would otherwise be counted short.
        """
        limit = time.monotonic() + deadline
        while time.monotonic() < limit:
            with self.lock:
                last = self.turn.get("last_frame")
            if last is None:
                return
            if time.monotonic() - last >= self.options.audio_idle:
                return
            time.sleep(0.05)

    def _push_to_talk(self, index):
        """Open the gate, close it, and return the moment the captain stopped.

        That instant, not the moment the last byte reaches the wire, is what the
        captain experiences as the end of their own speech. Every headline number
        is measured from it, and uplink_drain_s reports the difference so a slow
        connection stays visible rather than hiding inside the total.
        """
        seconds = self.options.talk_seconds
        if seconds is None and not self.options.in_file:
            try:
                input("\nrun {}: press Enter, speak, then press Enter again.".format(
                    index))
            except EOFError:
                raise SystemExit(
                    "fm-voice-client: no keyboard on this input. Use "
                    "--talk-seconds or --in-file for an unattended run.")

        self.talking.set()
        self.capture.begin_turn()
        if seconds is not None:
            say("client: run {}, capturing {}s.".format(index, seconds))
            time.sleep(seconds)
        elif self.options.in_file:
            self.capture.wait_exhausted(self.options.timeout)
        else:
            say("  listening. Enter to send.")
            try:
                input()
            except EOFError:
                pass

        self.talking.clear()
        release = time.monotonic()
        self.up_q.put(END)
        log(self.verbose, "talk end queued")
        return release

    def _let_reply_finish(self, record):
        """Wait for the previous answer to finish before opening another turn.

        The model tracks its own speech, and audio arriving while it believes it
        is still talking is an interruption: it emits an INTERRUPTED marker, and
        the interrupted turn is then lost. It goes as far as calling the tool and
        then produces no answer at all, which is the worst of both, so this is
        not an inconvenience to be tolerated.

        The clock that matters runs from the END of generation, not the start.
        The model streams a six second answer in about one second, and a turn
        opened at first-frame plus six seconds was still interrupted, while
        last-frame plus six seconds was not. So the wait is the reply's own
        duration measured from the last frame, plus a beat. In conversation that
        costs nothing: it is exactly the pause a captain takes anyway, because
        they are listening to the answer.

        Barge-in is step three of the design, so until it is built a turn waits.
        --no-wait-for-reply reproduces the trap deliberately.
        """
        if not self.options.wait_for_reply:
            return
        self.playback.drain()
        with self.lock:
            last = self.turn.get("last_frame")
        seconds = record.get("reply_audio_seconds") or 0
        if last is None or not seconds:
            return
        remaining = last + seconds + self.options.gap_seconds - time.monotonic()
        if remaining > 0:
            log(self.verbose,
                "waiting {:.2f}s for the answer to finish".format(remaining))
            time.sleep(remaining)

    def run(self):
        rc = 0
        for index in range(1, self.options.runs + 1):
            record = self.take_turn(index)
            print(json.dumps(record))
            sys.stdout.flush()
            if not record["answered"]:
                rc = 1
            if self.closed.is_set():
                break
            if index < self.options.runs:
                self._let_reply_finish(record)
        return rc


def device_selector(value):
    """Return a sounddevice device: an index when the value is digits, a name otherwise.

    sounddevice reads an int as an index into its device list and a str as a
    substring to match against device names, so an index left as text is looked
    up as a device literally called "3" and raises. docs/voice-relay.md tells the
    captain these flags take a name or an index, so both have to arrive typed.
    """
    return int(value) if value.strip().isdigit() else value


def parse_args(argv):
    parser = argparse.ArgumentParser(
        prog="fm-voice-client.py", add_help=True,
        description=__doc__.splitlines()[0])
    parser.add_argument("--host")
    parser.add_argument("--local", action="store_true")
    parser.add_argument("--relay", default=os.environ.get("FM_VOICE_RELAY"),
                        help="path to fm-voice-relay.py on the desktop; required, "
                             "and FM_VOICE_RELAY sets it for a whole shell")
    parser.add_argument("--relay-python",
                        default=os.environ.get("FM_VOICE_PYTHON", "python3"))
    parser.add_argument("--relay-arg", action="append")
    parser.add_argument("--listen", choices=LISTEN_MODES, default=PUSH_TO_TALK)
    parser.add_argument("--runs", type=int, default=1)
    parser.add_argument("--talk-seconds", type=float)
    parser.add_argument("--in-file")
    parser.add_argument("--out-file")
    parser.add_argument("--input-device", type=device_selector)
    parser.add_argument("--output-device", type=device_selector)
    parser.add_argument("--timeout", type=float, default=30.0)
    parser.add_argument("--wait-for-reply", action=argparse.BooleanOptionalAction,
                        default=True,
                        help="wait for each answer to finish being spoken before "
                             "opening the next turn (default on)")
    parser.add_argument("--gap-seconds", type=float, default=0.5,
                        help="quiet beat after an answer finishes. default 0.5")
    parser.add_argument("--audio-idle", type=float, default=0.4,
                        help="silence that counts as the reply having stopped "
                             "arriving. default 0.4")
    parser.add_argument("--verbose", action="store_true")
    options = parser.parse_args(argv)
    if bool(options.host) == bool(options.local):
        parser.error("give exactly one of --host <sshhost> or --local")
    if not options.relay:
        parser.error(
            "say where the relay is: --relay <path to fm-voice-relay.py on the "
            "desktop>, or set FM_VOICE_RELAY")
    if options.runs < 1:
        parser.error("--runs must be at least 1")
    if options.listen == OPEN_MIC and options.in_file:
        parser.error(
            "--listen open-mic with --in-file would end the turn when the file "
            "ran out, which is not what an open microphone does")
    return options


def main(argv):
    options = parse_args(argv)
    client = Client(options)
    try:
        client.open()
    except (frame.FrameError, OSError) as exc:
        sys.stderr.write("fm-voice-client: {}\n".format(exc))
        return 2
    try:
        return client.run()
    except KeyboardInterrupt:
        say("client: stopping.")
        return 130
    finally:
        client.close()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
