#!/usr/bin/env bash
# fm-wake-ack-lib.sh - the ONE owner of the WAKE_ACK_REQUIRED line format
# (plan v3 U1.3 guardrail: the shared emit/parse helper precedes any semantic
# change to waking, so the wording lives in exactly one place).
#
# Line format (byte-stable; production parsers and the wake tests read it):
#   WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through <N> --recovery-generation <TOKEN>
#
# <N> is a non-negative integer; <TOKEN> matches [A-Za-z0-9._-]+. The parsers
# read the LAST matching line of a capture and print nothing on no match or on
# a malformed line - callers treat an empty result as "no acknowledgement
# offered" and keep the durable wakes.
#
# This file is sourced only and has no side effects on source.

fm_wake_ack_line() { # <ack-through> <recovery-generation> -> the exact line on stdout
  printf 'WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through %s --recovery-generation %s\n' \
    "$1" "$2"
}

fm_wake_ack_parse_through() { # <capture-file> -> the last line's --ack-through value, or nothing
  sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$1" | tail -1
}

fm_wake_ack_parse_generation() { # <capture-file> -> the last line's --recovery-generation value, or nothing
  sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$1" | tail -1
}
