"""fm_voice_frame.py - the wire format between the voice client and the relay.

The client and the relay share one bidirectional byte stream: an SSH exec
channel, where the client's stdout is the relay's stdin and the relay's stdout
is the client's stdin. Audio and control therefore travel together and need
framing. A frame is a 1 byte kind, a 4 byte unsigned big-endian payload length,
then exactly that many payload bytes.

Kinds the client sends up to the relay:
  S  talk start, empty payload
  A  captured audio, 16000 Hz mono signed 16-bit little-endian
  E  talk end, empty payload
  Q  quit, empty payload

Kinds the relay sends down to the client:
  A  reply audio, 24000 Hz mono signed 16-bit little-endian
  T  JSON {"role": ..., "text": ...}, one transcript line
  V  JSON {"event": ..., ...}, a notice such as a queued request or a failed turn
  M  JSON {"mark": ..., "since_talk_end": ..., "tool_calls": ...}, one relay-side
     timing mark. since_talk_end is seconds from the moment the captain stopped
     talking, which is the instant every figure in this build is measured from.
     The marks the relay sends are tool_use, first_audio, first_audio_wire,
     tool_answered and reply_end; bin/fm-voice-relay.py owns what each means.
  B  bye, empty payload

Audio is raw PCM rather than base64 because base64 belongs to the Bedrock
event protocol, not to this hop, and the extra third of the bytes would sit
inside the latency this build exists to measure.

This module is the owner of the contract above and of the sample rates;
docs/voice-relay.md is the operator-facing guide and points here for the format.
This module is copied to the laptop beside fm-voice-client.py, so it imports
nothing outside the standard library.
"""

import json
import struct

HEADER = struct.Struct(">cI")

# The relay writes this once before its first frame and the client discards
# everything ahead of it. `ssh host command` runs the command through the login
# shell, so a shell startup file that prints to stdout would otherwise land in
# front of the first frame and desynchronise the stream, which reads as a
# baffling protocol error rather than as the chatty shell it is.
MAGIC = b"FMVOICE1"

# One second of 24000 Hz 16-bit mono is 48000 bytes, so this ceiling is far
# above any real chunk while still rejecting a desynchronised stream early.
MAX_PAYLOAD = 1 << 20

TALK_START = b"S"
AUDIO = b"A"
TALK_END = b"E"
QUIT = b"Q"
TEXT = b"T"
NOTICE = b"V"
MARK = b"M"
BYE = b"B"

KINDS = (TALK_START, AUDIO, TALK_END, QUIT, TEXT, NOTICE, MARK, BYE)


class FrameError(Exception):
    """A frame could not be encoded or decoded."""


def check_header(kind, length):
    """Raise FrameError unless a decoded header is one this format allows.

    Both directions of the stream decode headers, and audio that happens to
    look like one must be rejected identically wherever that happens, so the
    rules live here rather than beside each decoder.
    """
    if kind not in KINDS:
        raise FrameError("unknown frame kind: {!r}".format(kind))
    if length > MAX_PAYLOAD:
        raise FrameError("payload of {} bytes exceeds the {} byte limit".format(
            length, MAX_PAYLOAD))


def encode(kind, payload=b""):
    """Return the wire bytes for one frame."""
    check_header(kind, len(payload))
    return HEADER.pack(kind, len(payload)) + payload


def encode_json(kind, obj):
    """Return the wire bytes for one frame carrying a compact JSON payload."""
    return encode(kind, json.dumps(obj, separators=(",", ":")).encode("utf-8"))


def decode_json(payload):
    """Return the object in a JSON frame payload."""
    try:
        return json.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, ValueError) as exc:
        raise FrameError("payload is not JSON: {}".format(exc))


class Reader:
    """Read frames from a blocking binary stream.

    read() returns a (kind, payload) pair, or None once the peer has closed
    the stream cleanly between frames. A stream that ends part way through a
    frame raises FrameError, because a truncated frame is a real fault and
    silently treating it as end of input would hide a dropped connection.
    """

    def __init__(self, stream):
        self._stream = stream

    def _exact(self, count, what):
        """Return exactly count bytes, or None if the stream ended before any.

        Ending part way through raises rather than returning None, because the
        two are not the same fault and only the caller reading a header can
        treat nothing-at-all as end of input. A partial header returned as None
        would be read as a clean close, and a dropped connection would be
        recorded as a turn the model simply did not answer.
        """
        parts = []
        have = 0
        while have < count:
            chunk = self._stream.read(count - have)
            if not chunk:
                if have:
                    raise FrameError(
                        "stream ended after {} of the {} bytes of a {}".format(
                            have, count, what))
                return None
            parts.append(chunk)
            have += len(chunk)
        return b"".join(parts)

    def read(self):
        head = self._exact(HEADER.size, "frame header")
        if head is None:
            return None
        kind, length = HEADER.unpack(head)
        check_header(kind, length)
        if length == 0:
            return kind, b""
        payload = self._exact(length, "payload")
        if payload is None:
            raise FrameError("stream ended inside a {} byte payload".format(length))
        return kind, payload


class Writer:
    """Write frames to a blocking binary stream, flushing each one.

    Every frame is flushed because a buffered reply frame is indistinguishable
    from a slow model, and this build exists to measure the difference.
    """

    def __init__(self, stream):
        self._stream = stream

    def send(self, kind, payload=b""):
        self._stream.write(encode(kind, payload))
        self._stream.flush()

    def send_json(self, kind, obj):
        self._stream.write(encode_json(kind, obj))
        self._stream.flush()
