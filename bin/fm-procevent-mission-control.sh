#!/usr/bin/env bash
# Mission control adapter for the generic process-to-event runner: the LEGACY
# Lavish-bridged captain reply surface.
#
# SUPERSEDED. The board's reply controls now reach firstmate through the direct
# loopback service in bin/fm-procevent-board-reply.sh, because Lavish's own
# annotate mode intercepts a real tap on a board control before it reaches the
# button. This adapter is kept working, and is not extended further.
#
# Usage:
#   fm-procevent-mission-control.sh arm <board.html>
#   fm-procevent-mission-control.sh requests <result-file>
#   fm-procevent-mission-control.sh classify <result-file>
#   fm-procevent-mission-control.sh terminal <result-file>
#   fm-procevent-mission-control.sh source-id <board.html>
#   fm-procevent-mission-control.sh retire <board.html>
#
# arm        Register the captain reply surface: the mission control board
#            rendered with --controls, polled through Lavish. The wake it
#            produces is `procevent mission-control <source-id> <sequence>`,
#            which is the whole reason this adapter exists rather than reusing
#            the lavish one - it SELF-IDENTIFIES. Captain action requests and
#            ordinary artifact review feedback arrive through the same Lavish
#            poll, and reading the first as the second is exactly the mistake
#            this name prevents.
#
#            PRECONDITION: open the Lavish session on the board FIRST. This only
#            registers the source. With no session open, the first poll returns
#            "No active Lavish Editor session", which is terminal, so the runner
#            retires the registration straight away and the reply surface is
#            dead without ever having worked. Arming is not what puts the board
#            on screen.
# requests   Normalize a captured result into one JSON record per line. See
#            "What requests emits" below.
#
# AUTHORITY: none. A board control performs no action; it queues a request.
# Every record this adapter emits is captain INTENT for firstmate to adjudicate
# under its own contract, exactly as if the captain had said the same words in
# chat, and never an authorization. The surface is reachable by anything that
# can reach the local Lavish port, so reachability is never authorization
# either. Nothing here merges, answers, defers, or writes anything: this reads
# one file and prints to stdout.
#
# Identity, terminal knowledge, and Lavish lifecycle stay owned by
# bin/fm-procevent-lavish.sh, which this delegates to, so one Lavish session can
# never acquire two competing owners and "ended" keeps exactly one definition.
#
# The request vocabulary, the record kinds `requests` prints, and every
# fail-closed rule are owned by bin/fm-board-request-parse.pl and shared with the
# direct transport, so a rule fixed in one place is fixed for both. A `message`
# record - captain prose carrying no request marker - is the ORDINARY case here,
# because the Lavish panel sits beside the board at all times.
#
# `requests` says what the captain asked for, never whether the surface is still
# there, so classify every result too. The captain's "Send & End" sits beside
# "Send to Agent" in the Lavish panel, and one tap on it makes that delivery
# terminal: the request still arrives, and the source retires behind it. An
# `ended` or `missing` result means the reply surface is GONE until the Lavish
# session is opened on the board again and it is re-armed.
#
# Wire format verified end to end against lavish-axi 0.1.45, the version
# bin/fm-procevent-lavish.sh pins. Three facts it depends on: one prompt is one
# physical line with embedded newlines escaped inside a JSON-quoted field; the
# queuePrompt `data` option is NOT returned as its own column, so the envelope
# carries everything; and a note containing text like intent=merge stays inside
# its JSON string value and cannot contribute tokens to the parse.
# tests/fm-procevent-mission-control.test.sh pins that format against captured
# real bytes; re-capture it after a lavish-axi upgrade.
#
# Exit codes: 0 success, 1 runtime failure, 2 usage error.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAVISH="$SCRIPT_DIR/fm-procevent-lavish.sh"
PARSER="$SCRIPT_DIR/fm-board-request-parse.pl"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,/^# Exit codes/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }

# Identity is delegated so this adapter and the lavish one always agree on which
# physical file is which source; a second derivation here could drift and hand
# one Lavish session two owners.
cmd_source_id() {
  local artifact=${1-}
  [ -n "$artifact" ] || usage
  "$LAVISH" source-id "$artifact"
}

cmd_arm() {
  local artifact=${1-} id real
  [ -n "$artifact" ] || usage
  command -v lavish-axi >/dev/null 2>&1 || die "lavish-axi is not installed"
  id=$(cmd_source_id "$artifact") || exit 1
  real=$(perl -MCwd=realpath -e '$p = realpath($ARGV[0]); defined($p) or exit 1; print "$p\n"' "$artifact" 2>/dev/null) \
    || die "cannot resolve the board path: $artifact"
  # The same plain blocking poll the lavish adapter registers; only the adapter
  # name differs, so the wake says which kind of source produced the result.
  "$SCRIPT_DIR/fm-procevent.sh" register mission-control "$id" -- lavish-axi poll "$real" || exit 1
  printf 'armed: %s\n' "$id"
  printf 'board: %s\n' "$real"
}

cmd_retire() {
  local artifact=${1-} id
  [ -n "$artifact" ] || usage
  id=$(cmd_source_id "$artifact") || exit 1
  "$SCRIPT_DIR/fm-procevent.sh" retire "$id"
}

cmd_requests() {
  local file=${1-}
  [ -n "$file" ] || usage
  [ -f "$file" ] || die "result file does not exist: $file"
  [ -f "$PARSER" ] || die "request validator not found: $PARSER"
  perl "$PARSER" "$file"
}

case "${1-}" in
  arm)       shift; cmd_arm "$@" ;;
  retire)    shift; cmd_retire "$@" ;;
  source-id) shift; cmd_source_id "$@" ;;
  requests)  shift; cmd_requests "$@" ;;
  classify)  shift; [ $# -ge 1 ] || usage; "$LAVISH" classify "$@" ;;
  terminal)  shift; [ $# -ge 1 ] || usage; "$LAVISH" terminal "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
