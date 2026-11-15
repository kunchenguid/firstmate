#!/usr/bin/env python3
"""Raw AF_UNIX subscriber for herdr's native pane.agent_status_changed stream.

This is the WIRE TRANSPORT half of the herdr push-escalation path
(bin/backends/herdr.sh fm_backend_herdr_wait_transition). It deliberately does
NOT know firstmate's supervision policy: it opens ONE connection to a herdr
session's control socket, subscribes to pane.agent_status_changed for the given
panes (all statuses, so working/idle/done edges are seen too), and prints one
projected line per event to stdout, flushing each so the bash caller can react
sub-second. The bash side normalizes each line through the shared transition
shape and applies the single-owner policy table (bin/fm-transition-lib.sh); the
bash side also decides when to stop and kills this reader.

Wire protocol (verified: herdr 0.7.3, protocol 16, newline-delimited JSON):
  request : {"id","method":"events.subscribe","params":{"subscriptions":[
             {"type":"pane.agent_status_changed","pane_id":P}, ...]}}\n
  ack     : {"id",...,"result":{"type":"subscription_started"}}\n
  stream  : {"event":"pane.agent_status_changed",
             "data":{"pane_id","workspace_id","agent_status","agent",...}}\n

Usage: herdr-eventwait.py <socket_path> <timeout_seconds> <pane_id> [<pane_id> ...]

Output (one line per pane.agent_status_changed event, TAB-separated, a raw
projection - NOT the final normalized record; the bash normalizer adds the
from_status and builds the canonical shape):
  @subscribed
  <pane_id>\t<workspace_id>\t<agent_status>\t<agent>

Exit status:
  0  streamed until the timeout elapsed with no error - a clean bounded wait;
     the caller treats this as "no fast escalation, poll cadence preserved".
  2  bad arguments, could not connect, or could not send the subscribe request.
  3  the subscribe request did not return a subscription_started ack.
  4  the server closed the stream early or a receive operation failed.
A non-zero exit tells the bash caller to fall back to plain polling for this
cycle (the permanent fail-closed backstop), never to go silent.
"""
import json
import socket
import sys
import time

CONNECT_TIMEOUT = 5.0
ACK_TIMEOUT = 5.0
RECV_CHUNK = 65536


def _read_line(sock, buf, deadline):
    """Read one newline-terminated chunk from sock, honoring an absolute
    monotonic deadline. Returns (line_bytes_or_None, buf, outcome), where
    outcome is line, timeout, closed, or error."""
    while b"\n" not in buf:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return None, buf, "timeout"
        sock.settimeout(remaining)
        try:
            chunk = sock.recv(RECV_CHUNK)
        except socket.timeout:
            return None, buf, "timeout"
        except OSError:
            return None, buf, "error"
        if not chunk:
            return None, buf, "closed"
        buf += chunk
    line, buf = buf.split(b"\n", 1)
    return line, buf, "line"


def _clean(value):
    return str(value).replace("\t", " ").replace("\r", " ").replace("\n", " ")


def main(argv):
    if len(argv) < 4:
        return 2
    sock_path = argv[1]
    try:
        timeout = float(argv[2])
    except ValueError:
        return 2
    panes = argv[3:]
    if not panes or timeout <= 0:
        return 2

    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(CONNECT_TIMEOUT)
        sock.connect(sock_path)
    except OSError:
        return 2

    subscriptions = [
        {"type": "pane.agent_status_changed", "pane_id": pane} for pane in panes
    ]
    request = {
        "id": "fm-eventwait",
        "method": "events.subscribe",
        "params": {"subscriptions": subscriptions},
    }
    try:
        sock.sendall((json.dumps(request) + "\n").encode("utf-8"))
    except OSError:
        return 2

    start = time.monotonic()
    deadline = start + timeout
    buf = b""

    # Bounded wait for the subscription_started ack (its own short budget, but
    # never past the overall deadline).
    ack_deadline = min(deadline, start + ACK_TIMEOUT)
    line, buf, outcome = _read_line(sock, buf, ack_deadline)
    if line is None:
        return 2
    try:
        ack = json.loads(line.decode("utf-8", "replace"))
    except ValueError:
        return 3
    result = ack.get("result") or {}
    if result.get("type") != "subscription_started":
        return 3

    sys.stdout.write("@subscribed\n")
    sys.stdout.flush()

    # Stream projected events until the deadline or the server closes.
    while True:
        line, buf, outcome = _read_line(sock, buf, deadline)
        if line is None:
            return 0 if outcome == "timeout" else 4
        try:
            message = json.loads(line.decode("utf-8", "replace"))
        except ValueError:
            continue
        if message.get("event") != "pane.agent_status_changed":
            continue
        data = message.get("data") or {}
        fields = (
            _clean(data.get("pane_id") or ""),
            _clean(data.get("workspace_id") or ""),
            _clean(data.get("agent_status") or ""),
            _clean(data.get("agent") or ""),
        )
        sys.stdout.write("\t".join(fields) + "\n")
        sys.stdout.flush()


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except BrokenPipeError:
        # The bash caller stopped reading (found its actionable edge and killed
        # us). That is a normal, successful end of the wait.
        sys.exit(0)
    except KeyboardInterrupt:
        sys.exit(0)
