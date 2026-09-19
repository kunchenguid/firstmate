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

  NOT verified, and cannot be from here: the audio DEVICES. The desktop this was
  written on has neither a microphone nor a speaker, and no worker can reach the
  captain's laptop. The sounddevice calls below are written from its documented
  interface and have never been run against a real device. Treat the first live
  run as the test.

  Verified, and worth telling apart from the devices: the speaker's own byte
  ACCOUNTING, which is the arithmetic deciding which turn a chunk of reply audio
  is credited to and which turn's first-audio clock it stamps. That is plain
  logic rather than device work, so it is exercised against a stub stream with
  the callback driven by hand. Nothing in that says how a real output device
  behaves.

TWO KINDS OF LISTENING, one of them built. --listen push-to-talk is the default
and the only mode that runs: the captain says when they are talking, the model is
only paid for that audio, and nothing is streamed while they are thinking.

--listen open-mic is accepted as a setting and REFUSES at startup. Streaming
continuously needs something to decide when the captain stopped speaking, and
this client has no end-of-speech detection: it would open a turn, stream audio
forever and never mark a boundary, so the relay would keep appending to a session
that had already answered. That detection belongs with session continuity across
turns, which is step three of the design. The setting stays here so that turning
it on later is a small change rather than a new flag, and refusing is honest
where half a mode would not be.

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
  --listen <mode>        push-to-talk, the default and the only mode that runs.
                         open-mic is accepted and refuses; see above.
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
import traceback

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import fm_voice_frame as frame              # noqa: E402

IN_RATE = 16000
OUT_RATE = 24000
# 100 ms at each rate. The uplink chunk matches what the relay and the earlier
# prototype work measured with; changing it changes the numbers.
CHUNK = 3200
OUT_BLOCK = 2400

PUSH_TO_TALK = "push-to-talk"
OPEN_MIC = "open-mic"
LISTEN_MODES = (PUSH_TO_TALK, OPEN_MIC)

# Anything the relay's login shell prints on stdout ahead of the first frame is
# discarded, up to this much. Past it, the stream is not a relay.
MAX_PREAMBLE = 8192

# The two ends of a turn, queued rather than written, for the reason _sender
# gives: everything the uplink carries has to stay in the order it happened in.
START = object()
END = object()


class DeviceError(Exception):
    """A microphone or speaker could not be opened, said in one line."""


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
    """Write reply audio to a file. This is the path that can be verified here.

    Every chunk carries the turn it belongs to, and turn_reset names the turn
    being measured. A chunk from a turn that has already been recorded is still
    written, because it is the tail of an answer the captain is still listening
    to, but it stamps no clock and is counted toward nobody: attributed to the
    turn that happens to be open, it would hand that turn a first-audio figure
    measured from somebody else's reply and report it answered when it was not.
    """

    def __init__(self, path):
        self._handle = open(path, "wb")
        # Two locks, and which one covers what is the point of them. _lock is the
        # per-turn accounting, and turn_reset takes it while the client holds its
        # own turn lock, so nothing slow may ever be done under it. _handle_lock
        # covers the file itself, so a write and a close cannot overlap. The
        # ordering is always _handle_lock then _lock and never the reverse.
        #
        # What close() needing _handle_lock costs: the exit is now only as bounded
        # as one write to --out-file, so on a hung or full filesystem the five
        # second downlink join in Client.close no longer bounds it. The wedged relay
        # that join was written for is unaffected, being another process while this
        # write is local. That cost belongs to the filed teardown-ordering work,
        # whose other half is the same five second join being shorter than the ten
        # seconds the relay may spend draining its own reply stream, which is why
        # audio can arrive after the output is released at all.
        self._handle_lock = threading.Lock()
        self._lock = threading.Lock()
        self.first_played = None
        self.device_latency = None
        self.turn_bytes = 0
        # Chunks dropped because they arrived after the file was released. Read by
        # --verbose only; see write() for why it is not an outcome input.
        self.discarded = 0
        self._turn = None
        self._closed = False

    def write(self, pcm, turn):
        # A chunk arriving after close is DISCARDED rather than raising. close()
        # joins the downlink at five seconds while the relay teardown it waits on
        # can take up to ten, so reply audio still in flight when the file is
        # released is an expected and benign race, and erroring on it reported this
        # end's own teardown as a fault through the frame-handling guard, on a
        # session that worked. Discard is the honest semantic for it, and after
        # this any fault line printed during teardown is a real one.
        #
        # Counted, because a write after close OUTSIDE teardown is a logic bug and
        # a silent no-op would hide it. Counted and nothing more: discarded bytes
        # stamp no clock, are credited to no turn, and so reach neither answered,
        # first_audio_s nor the exit code, which are decided from turn_bytes.
        #
        # The turn comparison, the stamp and the count are one decision and are
        # made together under _lock. The file write is not: it blocks, and holding
        # the lock turn_reset needs across it would stall the whole client behind
        # the filesystem. One writer keeps the file in order without that.
        with self._handle_lock:
            if self._closed:
                with self._lock:
                    self.discarded += 1
                return
            with self._lock:
                mine = turn == self._turn
                if mine and self.first_played is None:
                    self.first_played = time.monotonic()
                if mine:
                    self.turn_bytes += len(pcm)
            self._handle.write(pcm)

    def turn_reset(self, turn):
        with self._lock:
            self._turn = turn
            self.first_played = None
            self.turn_bytes = 0

    def drain(self, timeout=5):
        del timeout

    def close(self):
        with self._handle_lock:
            self._closed = True
            self._handle.close()


class SpeakerPlayback:
    """Play reply audio through the laptop speaker.

    The DEVICE is UNVERIFIED: written from the sounddevice interface and never run
    against a real one, because the machine this was built on has no speaker, so
    the first live run is its test. The byte ACCOUNTING below is covered, against
    a stub stream with the callback driven by hand, and covering it says nothing
    about how a real device behaves.

    The timestamp is taken when the audio is handed to the device callback, which
    is the last moment this process can see. The device's own output buffer sits
    after that, so its reported latency is included in the turn record rather
    than pretended away.

    That timestamp is why the turn a chunk belongs to has to travel with the
    chunk rather than being checked before the write: the moment that matters
    happens in the callback, later than the frame arriving, and the gap between
    the two is the honest content of the figure. So the buffer remembers how many
    of its leading bytes belong to turns already recorded, and the first audio of
    the turn being measured is the first byte past them. Ordering makes that a
    count rather than a per-chunk tag: the downlink hands chunks over in arrival
    order on one thread and a turn number never goes backwards, so a chunk from an
    earlier turn can never queue behind one from a later turn.
    """

    def __init__(self, device=None):
        import sounddevice                    # noqa: PLC0415
        self._buffer = bytearray()
        self._lock = threading.Lock()
        self.first_played = None
        self.turn_bytes = 0
        # The same diagnostic the file path keeps, for the same reason. A counter
        # that can only ever read zero is indistinguishable from one that measured
        # zero, and this is the path the captain will actually use, so the write
        # after close that the counter exists to catch has to be visible here too.
        self.discarded = 0
        self._turn = None
        self._earlier = 0
        self._closed = False
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
            spent = min(self._earlier, take)
            self._earlier -= spent
            if take > spent and self.first_played is None:
                self.first_played = time.monotonic()
        outdata[:take] = chunk
        if take < want:
            outdata[take:want] = b"\x00" * (want - take)

    def write(self, pcm, turn):
        with self._lock:
            # close() stops the stream, and after that no callback drains the
            # buffer, so a chunk arriving here was never going to be heard however
            # it is stored. Discarded and counted rather than queued and credited
            # to the turn, which is what the file path does: queued, it is a
            # measurement the captain never heard, and silent, the write after
            # close outside teardown that this counts for would be invisible on the
            # one path they use. Counted and nothing more, so it stamps no clock
            # and reaches neither answered, first_audio_s nor the exit code.
            if self._closed:
                self.discarded += 1
                return
            if turn == self._turn:
                self.turn_bytes += len(pcm)
            else:
                self._earlier += len(pcm)
            self._buffer += pcm

    def turn_reset(self, turn):
        with self._lock:
            self._turn = turn
            self.first_played = None
            self.turn_bytes = 0
            # Whatever is still queued was spoken for an earlier turn. Counted as
            # this turn's, the previous answer's undrained tail would stamp this
            # turn's first audio the instant the device next asked for a block.
            self._earlier = len(self._buffer)

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
        # Marked before the stream is stopped and not while the lock is held: the
        # device callback takes this lock, and stop() waits for a callback already
        # running, so holding it across the stop is a deadlock. Marking first
        # instead leaves no instant where the stream is gone and a write still
        # queues for it.
        with self._lock:
            self._closed = True
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


# ------------------------------------------------------------------- audio setup


def open_file_end(flag, path, build):
    """Open a file-backed end of the audio, naming the path and the flag for it.

    The file ends are the ones this host can run, and they are what every figure
    in docs/voice-relay.md was measured with, so their refusal is the one most
    likely to be read. It stays an OSError, which main prints as it stands, and it
    names the path and the flag that chose it. Reporting a mistyped path as a
    device failure would send the reader to the device flags instead of to the
    path.
    """
    try:
        return build()
    except OSError as exc:
        raise OSError("could not open {}, given as {}: {}".format(
            path, flag, exc))


def open_device_end(flag, build):
    """Open a device-backed end of the audio, or refuse in one line with a next step.

    sounddevice raises its own error types and is an optional import, so neither
    shape reaches main as an OSError on its own and a traceback is what the
    captain would otherwise get. Whether this refusal ever fires, and what a real
    device says when it does, is unverified for the reason the module docstring
    gives.
    """
    try:
        return build()
    except Exception as exc:                       # noqa: BLE001
        raise DeviceError(
            "could not open the audio device ({}: {}). Name another one with {}, "
            "or run without a device using --in-file and --out-file".format(
                type(exc).__name__, exc, flag))


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
        self.down_thread = None
        self.up_q = queue.Queue()
        self.talking = threading.Event()
        self.ready = threading.Event()
        self.reply_done = threading.Event()
        self.closed = threading.Event()
        # Set the moment this end asks the relay to stop. It is the only thing
        # that tells an expected goodbye from the relay stopping on its own,
        # because the frame is the same one either way, and reading a clean end as
        # a fault would train the captain to ignore the line that means it.
        self.quitting = threading.Event()
        self.ready_notice = {}
        self.turn = {}
        # Which turn self.turn is. A frame is read on one thread and applied on
        # another, so a reply that arrives late, or a notice whose handling is
        # descheduled, can be applied after the turn it belongs to has already
        # been recorded and the next one opened. Without an identity to compare,
        # that reply lands on the wrong turn: it names a fault that turn never
        # had, releases it before its own answer, and stamps its first and last
        # audio, which are the figures this whole tool exists to report. The
        # downlink takes a copy of this when a frame arrives and applies nothing
        # once it no longer matches.
        self.turn_id = 0
        # What run() tells the captain when no further turn can be taken. Every
        # path that makes the connection unusable names itself here, so the line
        # about the runs that were lost restates the cause that was recorded
        # rather than asserting one; a line naming the wrong cause sends them
        # looking where the fault is not. The default only covers a closure with
        # no path at all behind it, which nothing here can currently produce.
        self.closed_because = "the connection closed"
        self.lock = threading.Lock()

    # ------------------------------------------------------------------ lifecycle

    def open(self):
        """Start the relay, the audio devices and the two frame threads.

        A startup that refuses part way through releases whatever it already
        started, including on the SystemExit _wait_ready raises: a started
        PortAudio stream left open at interpreter shutdown is a known hang on
        macOS, which is the laptop this runs on. Whether it releases them
        correctly against a real device is not something this host can show, for
        the reason the module docstring gives.
        """
        try:
            self._start()
        except BaseException:
            self.close()
            raise

    def _start(self):
        argv = relay_command(self.options)
        log(self.verbose, "starting relay: {}".format(" ".join(argv)))
        self.proc = subprocess.Popen(
            argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        sync_magic(self.proc.stdout, self.verbose)
        self.reader = frame.Reader(self.proc.stdout)
        self.uplink = Uplink(self.proc.stdin)

        if self.options.out_file:
            self.playback = open_file_end(
                "--out-file", self.options.out_file,
                lambda: FilePlayback(self.options.out_file))
        else:
            self.playback = open_device_end(
                "--output-device",
                lambda: SpeakerPlayback(self.options.output_device))

        if self.options.in_file:
            self.capture = open_file_end(
                "--in-file", self.options.in_file,
                lambda: FileCapture(self.options.in_file))
        else:
            self.capture = open_device_end(
                "--input-device",
                lambda: MicCapture(self.options.input_device))
        self.capture.start(self.up_q, self.talking)

        self.down_thread = threading.Thread(target=self._downlink, daemon=True)
        self.down_thread.start()
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

    def _quietly(self, what, action):
        """Run one cleanup step without letting it mask why we are cleaning up."""
        try:
            action()
        except Exception as exc:                   # noqa: BLE001
            log(self.verbose, "{} did not close cleanly: {}: {}".format(
                what, type(exc).__name__, exc))

    def close(self):
        # Every step is guarded and every field is checked, because close() also
        # runs from a startup that refused part way through, where the later
        # fields are still None and the original refusal is the message worth
        # keeping.
        if self.uplink is not None:
            # Before the frame, so the goodbye that answers it is read as the
            # answer to a question this end asked rather than as the relay
            # stopping on its own.
            self.quitting.set()
            self._quietly("the uplink", lambda: self.uplink.send(frame.QUIT))
        # Before the devices are released, so the reply the goodbye above answers
        # has somewhere to land, and bounded so a wedged relay cannot hold the
        # exit. The bound is shorter than the relay's own teardown, so audio can
        # still arrive after the output is released; the playback discards that
        # rather than raising, which is what keeps a fault line meaning a fault.
        if self.down_thread is not None:
            self.down_thread.join(timeout=5)
        if self.capture is not None:
            self._quietly("the microphone", self.capture.close)
        if self.playback is not None:
            self._quietly("the speaker", self.playback.drain)
            self._quietly("the speaker", self.playback.close)
        if self.proc is not None:
            try:
                self.proc.stdin.close()
            except Exception:                  # noqa: BLE001
                pass
            try:
                self.proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.proc.kill()
        # Said last, because the relay exiting above is what stops the audio still
        # in flight, and through _quietly like every other step here: a playback
        # that cannot answer for its count must not replace the refusal that
        # brought us into close() in the first place.
        self._quietly("the discard count", self._say_dropped)

    def _say_dropped(self):
        """Report reply audio the output was no longer open to take.

        A count read at teardown, which should normally be zero. This has one
        caller and it is the last statement of close(), so the count is only ever
        reported at the end of a session; the tripwire is still worth keeping,
        because a close() added anywhere else would be counted here too. Both
        output paths count it rather than only the file one. Diagnostic only: it
        names nothing in the record and decides no exit code.

        Read straight off the playback rather than through a default, so a playback
        that cannot answer is a failure rather than a zero indistinguishable from
        having measured none. The None check is close()'s own, for the startup that
        refused before there was an output at all.
        """
        if self.playback is None:
            return
        dropped = self.playback.discarded
        if dropped:
            log(self.verbose,
                "discarded {} reply audio chunk(s) that arrived after the output "
                "was released".format(dropped))

    # -------------------------------------------------------------------- threads

    def _sender(self):
        """Own the whole uplink, so nothing on it can be sent out of order.

        Every frame a turn consists of goes through this one queue, talk start
        included. Sending the start from the turn thread instead cost a turn: a
        turn that ends with no answer to wait for - a failed turn, or the model
        finishing with the session - returns as soon as it is told, while the last
        chunk and the talk end may still be here. The next talk start would then
        overtake them, the relay would open a fresh session and apply the previous
        turn's talk end to it, and the captain's entire next question was dropped
        as audio arriving with no turn open. It answered a question nobody had
        finished asking.

        A closed connection is a dead uplink for talk start and talk end just as
        much as for audio, so all three are sent through the same guard. Sending
        the control frames outside it cost the rest of the session: the write
        raised, this thread died with a traceback, and every later turn queued
        frames nobody was left to send, so it waited out the full timeout with
        no answer instead of reporting the lost connection the downlink had
        already seen.
        """
        while True:
            item = self.up_q.get()
            if item is None:
                return
            if item is START:
                kind, payload = frame.TALK_START, b""
            elif item is END:
                with self.lock:
                    self.turn["wire_end"] = time.monotonic()
                kind, payload = frame.TALK_END, b""
            else:
                kind, payload = frame.AUDIO, item
            try:
                self.uplink.send(kind, payload)
            except (BrokenPipeError, OSError):
                return

    def _unfinished(self, subject):
        """Name a fault that landed on an open turn, in the words that turn earned.

        A relay dies mid-turn in two shapes and they are not the same fault. With
        no reply audio yet, the turn went unanswered. With some already played,
        the captain heard the start of an answer and the rest was cut off, so the
        turn WAS answered and first_audio_s is a real measurement of when: saying
        nothing arrived would contradict the answered field two lines below it in
        the same record, and a reader who believes the wrong one goes looking in
        the wrong place.

        Read off the same count answered is read off, so the two cannot disagree
        about one turn whatever the timing.
        """
        if self.playback.turn_bytes > 0:
            return "{} before the reply finished".format(subject)
        return "{} before this turn was answered".format(subject)

    def _downlink(self):
        # Why the loop stopped, for a turn that was still waiting for its reply
        # when it did. Neither of the quiet exits below raises, and they are
        # different faults, so each names itself rather than leaving the tail to
        # guess or to say nothing.
        why = None
        # And what run() says about the runs that were lost to it. Separate from
        # the reason above because they are different statements: that one is why
        # this turn has no answer, this one is why there will be no more turns.
        cause = None
        while True:
            try:
                got = self.reader.read()
            except (frame.FrameError, OSError) as exc:
                say("client: connection lost: {}".format(exc))
                # Recorded as well as said, because the turn record is what a
                # latency figure is read from later and stderr is not. A dropped
                # connection that only says answered: false is indistinguishable
                # there from a turn the model declined to answer. setdefault
                # because a relay that named the failure first said it better.
                #
                # closed is set in this same critical section, not left to the
                # tail below, because take_turn decides whether another turn can
                # be opened by reading it under this lock. Naming the failure
                # first and announcing the closure afterwards left a window where
                # the connection was known gone and no reader could tell.
                #
                # The reply_done test is the one the quiet close paths below
                # already apply, and it is here for the same reason: a reason
                # belongs to a turn that has not had its answer yet. Without it a
                # fault landing in the gap between reply_end arriving and the
                # record being copied named a turn that was fully answered, and
                # since a recorded reason exits non-zero that failed a session
                # which had delivered everything asked of it. An end of stream and
                # a reset differ only in what the kernel handed us, so they must
                # not produce two different exit codes for one relay death.
                #
                # WHAT THE TEST MAKES INVISIBLE, because it is a real cost rather
                # than none: a relay failure arriving after the FINAL turn's reply
                # was already complete now records no reason and exits 0. The relay
                # puts every audioOutput chunk and the reply_end mark on one
                # ordered queue, so by the time this end sets reply_done every byte
                # of that answer has already reached the playback, and a fault
                # after it cannot have cost the captain any part of what they were
                # given. What it can still cost is a LATER turn, and that is
                # reported with no per-turn reason at all by the remaining-runs
                # check, which exits non-zero whenever the connection is known gone
                # with runs still to take. A relay dying at that instant is also
                # indistinguishable from the same relay dying a moment later during
                # this end's own teardown, which this client already treats as
                # benign. The bound: take_turn clears reply_done in the same
                # critical section as the closure mark, so the blind spot is
                # exactly "after this turn's reply completed" and never "during a
                # turn".
                #
                # closed_because and the closure mark stay outside it, so the
                # session still knows the connection went and still says so.
                with self.lock:
                    if not self.reply_done.is_set():
                        self.turn.setdefault(
                            "failed", "{}: {}".format(
                                self._unfinished("the connection was lost"),
                                exc))
                    self.closed_because = "the connection was lost"
                    self.closed.set()
                break
            if got is None:
                if not self.quitting.is_set():
                    say("client: the connection ended")
                # The subject only. Whether it ended before the turn was answered
                # or partway through the answer is decided by _unfinished at the
                # tail, where the audio count is read.
                why = "the connection ended"
                cause = "the connection ended"
                break
            kind, payload = got
            # Which turn this frame belongs to, taken the moment it arrives. Every
            # write below applies only while it is still that turn; see turn_id.
            with self.lock:
                arrived_in = self.turn_id
            try:
                if kind == frame.AUDIO:
                    with self.lock:
                        if arrived_in == self.turn_id:
                            now = time.monotonic()
                            self.turn.setdefault("first_frame", now)
                            self.turn["last_frame"] = now
                    # Played whichever turn it belongs to, and told which that is.
                    # Late audio is the tail of an answer the captain is still
                    # listening to, so dropping it would cut them off, but three
                    # figures are read off what this call does - first_played, the
                    # reply's own duration and whether the turn was answered at all
                    # - and a stale chunk credited to the turn now open reports an
                    # unanswered turn as answered, which is an exit code of zero on
                    # a session that lost one.
                    self.playback.write(payload, arrived_in)
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
                            if arrived_in == self.turn_id:
                                self.turn["queued"] = obj.get("note_id", "")
                    elif event == "interrupted":
                        with self.lock:
                            if arrived_in == self.turn_id:
                                self.turn["interrupted"] = True
                        log(self.verbose, "the model treated this turn as an "
                                          "interruption of its own speech")
                    elif event == "turn-failed":
                        # The relay is still there and the next talk key gets a
                        # new session, so this ends the turn rather than the run.
                        say("client: the relay could not finish that turn: {}"
                            .format(obj.get("error", "")))
                        # Named and released in one critical section, so no turn
                        # can be released without also being told why. The
                        # reply_done test is the read path's, for the reason given
                        # there: a relay whose model stream broke in the gap after
                        # this turn's answer completed has cost this turn nothing,
                        # and naming it here would fail a session that answered.
                        # The release stays outside the test, so a failure arriving
                        # while the turn is still waiting still ends its wait.
                        with self.lock:
                            if arrived_in == self.turn_id:
                                if not self.reply_done.is_set():
                                    self.turn["failed"] = obj.get("error", "")
                                self.reply_done.set()
                    elif event == "session-ended":
                        say("client: the relay ended the session")
                        # An ordinary session end is not a turn failure at the
                        # relay, and the next talk key still gets a working one. A
                        # turn released by it nevertheless has no answer, and
                        # relay_error is where the reason for that is read from
                        # later, so it carries what the captain was just told. The
                        # reply_done test and the setdefault are the tail's, for
                        # the tail's reasons.
                        with self.lock:
                            if arrived_in == self.turn_id:
                                if not self.reply_done.is_set():
                                    self.turn.setdefault(
                                        "failed",
                                        self._unfinished(
                                            "the relay ended the session"))
                                self.reply_done.set()
                    else:
                        log(self.verbose, "notice {}".format(obj))
                elif kind == frame.MARK:
                    obj = frame.decode_json(payload)
                    with self.lock:
                        if arrived_in == self.turn_id:
                            self.turn.setdefault(
                                "marks", {})[obj.get("mark", "?")] = \
                                obj.get("since_talk_end")
                            self.turn["tool_calls"] = obj.get("tool_calls", 0)
                            if obj.get("mark") == "reply_end":
                                self.reply_done.set()
                elif kind == frame.BYE:
                    # The same frame ends a session this end asked to end and a
                    # relay that stopped on its own, so the frame says nothing on
                    # its own and whether we asked is the whole discriminator.
                    # Both speak, because a session that ended should say so, and
                    # neither borrows the other's words: a line that also appears
                    # when everything worked is a line the captain learns to skip,
                    # and then the one that means trouble is invisible too.
                    if self.quitting.is_set():
                        say("client: the relay signed off")
                        cause = "the relay signed off after being asked to stop"
                    else:
                        say("client: the relay stopped without being asked to")
                        why = "the relay stopped"
                        cause = "the relay stopped without being asked to"
                    break
            except Exception as exc:               # noqa: BLE001
                # A fault on THIS end, handling a reply that did arrive: the
                # speaker or the output file refusing the audio, or a payload that
                # is not the JSON the wire format promises. Caught as a class
                # rather than as a list, because this handling code can raise
                # something nobody listed, and the failure being removed here is
                # this thread dying silently: closed and reply_done then stay
                # unset, and every remaining run opens a turn, waits out the whole
                # timeout and is recorded unanswered with no reason at all, so one
                # fault costs the session instead of one turn.
                #
                # Deliberately not worded as a lost connection. The connection is
                # fine and naming it would send the captain to the wrong end.
                fault = ("this end could not handle the relay's reply: {}: {}"
                         .format(type(exc).__name__, exc))
                say("client: {}".format(fault))
                # The one line is for the captain and the record; the traceback is
                # for whoever has to find the bug behind it. Before this guard
                # existed the thread died and threading.excepthook printed one, so
                # a programming error in here would otherwise be strictly harder to
                # locate than it used to be. Terminal path, so this prints once per
                # session at worst, and the record keeps the one-line reason
                # because that field is machine read.
                sys.stderr.write(traceback.format_exc())
                sys.stderr.flush()
                with self.lock:
                    self.turn.setdefault("failed", fault)
                    self.closed_because = fault
                    self.closed.set()
                break
        # Under the turn lock for the same reason the failure above is: a clean
        # end of file and a goodbye leave the connection just as unusable as a
        # dropped one, and take_turn reads this under that lock to decide whether
        # a turn can still be opened. Already set on the failure path; setting an
        # event twice costs nothing.
        #
        # A turn still waiting for its reply is named in the same critical
        # section, and before the event that releases it, so the turn reading the
        # record finds the reason rather than racing it. reply_done is the test:
        # take_turn clears it under this lock when it opens a turn and it is set
        # at every other moment, so an answered turn whose connection then ends
        # cleanly keeps its record and stays reason-free. setdefault, because a
        # relay that named the failure first said it more precisely than this end
        # can infer it.
        with self.lock:
            if why is not None and not self.reply_done.is_set():
                self.turn.setdefault("failed", self._unfinished(why))
            if cause is not None:
                self.closed_because = cause
            self.closed.set()
        self.reply_done.set()

    # ---------------------------------------------------------------------- turns

    def take_turn(self, index):
        """Run one turn and return its record, or None if the connection is gone.

        The check and the reset share one critical section with the downlink's
        closure mark on purpose. The wait between turns is seconds long and is
        where a relay that dies between questions dies, so the run loop cannot
        decide to open another turn by reading a flag the downlink sets after it
        records the failure: between those two writes the connection is already
        gone and the loop cannot see it. It then cleared the failure the downlink
        had recorded, sent talk-start into a dead pipe, and came back after the
        whole reply timeout as answered: false with relay_error: null - a lost
        connection wearing the shape of a turn the model declined, in the file
        docs/voice-relay.md computes its published latency spread from.
        """
        with self.lock:
            if self.closed.is_set():
                return None
            self.turn = {}
            # Advanced here, with the reset it names, so a frame still being
            # handled from the previous turn can tell that its turn is over.
            self.turn_id += 1
            # In the same critical section as the closure mark, because this
            # event is how the downlink tells a turn waiting for a reply from the
            # space between turns. Cleared outside the lock it leaves a window
            # where the connection has already gone, the downlink has read the
            # event as nobody waiting and named nothing, and this turn then waits
            # out its whole timeout to be recorded with no reason at all.
            self.reply_done.clear()
            # In the same critical section, and named with the same identity the
            # frames carry, so there is no instant where the turn has advanced and
            # the playback is still counting audio toward the turn before it.
            self.playback.turn_reset(self.turn_id)
        self.up_q.put(START)

        # Unreachable while parse_args refuses open-mic, and kept so that turning
        # the mode on later is a small change. It is still missing the turn
        # boundary: it opens the gate and nothing ever closes it, so no talk end
        # is ever sent. Do not lift the refusal without adding that first.
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
        reply_bytes = self.playback.turn_bytes
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
            # Why a turn has no answer, when either end knows: the relay names a
            # failed turn, and this end names a connection that went during one.
            # A results file that only says answered: false invites the reader to
            # average an infrastructure failure into a latency figure.
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
            # This turn's own audio, counted by the playback rather than by
            # subtracting a byte total it shares with every other turn. A total
            # cannot tell a reply from the previous reply's tail arriving late, and
            # counting that tail here reports a turn nobody answered as answered.
            "reply_audio_seconds": round(
                reply_bytes / float(OUT_RATE * 2), 3),
            "answered": reply_bytes > 0,
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

    def _say_stopped(self, index):
        """Name why no more turns can be taken, and which run was the first lost.

        The cause is whatever the path that closed the connection recorded, not an
        assertion made here: a fault on this end leaves the connection open, and a
        line blaming the connection for it sends the captain to the wrong end.
        """
        with self.lock:
            because = self.closed_because
        say("client: {} before run {} of {}; it and the rest were not "
            "taken".format(because, index, self.options.runs))

    def run(self):
        rc = 0
        for index in range(1, self.options.runs + 1):
            record = self.take_turn(index)
            # take_turn refusing is the one place a closed connection stops the
            # session, so the outcome is the same wherever the connection went:
            # nothing more can be taken over it, the runs the captain asked for
            # were not, and the exit code says so, because a session that stops
            # early while reporting success is read later as a complete
            # measurement. A second check here, on a flag read before the turn
            # rather than under the lock that guards it, is what let a lost
            # connection through in the first place; and no record is printed for
            # a turn that never opened, since an invented turn is the whole thing
            # being kept out of runs.jsonl.
            if record is None:
                self._say_stopped(index)
                rc = 1
                break
            print(json.dumps(record))
            sys.stdout.flush()
            # A named reason counts as well as an unanswered turn, and not only
            # when a later run remains. A relay killed while speaking leaves a
            # turn that was answered and a record that says why the answer stopped
            # partway, and at the default of one run that turn cleared all three of
            # the other paths to a non-zero code and reported the session a
            # success. A results file whose own record names an infrastructure
            # failure must not sit behind an exit code that says nothing happened.
            if not record["answered"] or record["relay_error"]:
                rc = 1
            if index < self.options.runs:
                # Checked after the record and before the wait, because that wait
                # is seconds long and exists only to avoid interrupting the model's
                # own speech, which a relay that is already gone cannot be doing.
                # Waiting it out here left the captain sitting through the last
                # reply's whole spoken duration before being told the session had
                # stopped. The exit code is still the unhappy one: the runs asked
                # for were not taken, whatever the last one reported.
                if self.closed.is_set():
                    self._say_stopped(index + 1)
                    rc = 1
                    break
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
    parser.add_argument("--listen", choices=LISTEN_MODES, default=PUSH_TO_TALK,
                        help="push-to-talk is the default and the only mode that "
                             "runs; open-mic is accepted and refuses until "
                             "end-of-speech detection exists")
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
    if options.listen == OPEN_MIC:
        # Here rather than in open(), so nothing is spent: no ssh, no relay, no
        # model session. See the module docstring on the two kinds of listening.
        parser.error(
            "--listen open-mic is not built yet: it needs end-of-speech "
            "detection to know when a turn ended, which lands with session "
            "continuity across turns, so it would stream forever and never end "
            "a turn. Use the default --listen push-to-talk.")
    return options


def main(argv):
    options = parse_args(argv)
    client = Client(options)
    try:
        client.open()
    except SystemExit as exc:
        # _wait_ready refuses this way and its message is already the whole
        # story. open() has released what it started; this turns the refusal
        # into the same one-line exit the rest of this file gives.
        if exc.code not in (None, 0):
            sys.stderr.write("{}\n".format(exc.code))
        return 2
    except (frame.FrameError, OSError, DeviceError) as exc:
        sys.stderr.write("fm-voice-client: {}\n".format(exc))
        return 2
    except Exception as exc:                       # noqa: BLE001
        sys.stderr.write("fm-voice-client: could not start: {}: {}\n".format(
            type(exc).__name__, exc))
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
