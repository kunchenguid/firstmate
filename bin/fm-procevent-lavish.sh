#!/usr/bin/env bash
# Lavish adapter for the generic process-to-event runner.
#
# Usage:
#   fm-procevent-lavish.sh arm <artifact.html>
#   fm-procevent-lavish.sh session-state <artifact.html>
#   fm-procevent-lavish.sh classify <result-file>
#   fm-procevent-lavish.sh terminal <result-file>
#   fm-procevent-lavish.sh source-id <artifact.html>
#   fm-procevent-lavish.sh retire <artifact.html>
#
# arm        Register the canonical source, reconcile it through the generic
#            runner, and report armed only while two independent things are both
#            true: Lavish's own listing says that exact session is open, and the
#            runner says the exact registered listener is executing. Neither is a
#            timer, so neither can be defeated by host load.
#            A failed confirmation returns nonzero and stays registered for the
#            runner's ordinary restart recovery. A target session that has
#            already ended or is missing is a hard failure too, reported as
#            exactly that: it cannot accept feedback, so it never becomes live,
#            and re-arming it only polls an ended session again. Its terminal
#            result is still captured, announced, and handled normally, because
#            an ended session still owes one final `Send & End` payload and the
#            listener is started before that verdict is read.
# session-state
#            Print what Lavish's own published listing says about that exact
#            artifact's session: its status word - `open` for a session that can
#            still accept feedback - or `absent` when no session is listed for it,
#            which is what both an ended and a never-opened review look like.
# classify   Print the lifecycle state a handler should act on: feedback, ended,
#            waiting, missing, or unknown.
# terminal   Exit 0 when the captured result means this Lavish source will never
#            produce another result, so the runner may retire it; any other exit
#            keeps it armed. This is the generic adapter contract bin/fm-procevent.sh
#            calls, and the only place Lavish's notion of "ended" is decided.
#
# This adapter is deliberately thin. It owns only what is specific to Lavish:
# canonical source identity, the argv for the currently published poll command,
# and how to read a completed result. Ownership, durable capture, publication,
# and restart recovery all belong to bin/fm-procevent.sh.
#
# It wraps ONLY the currently published interface, verified against 0.1.45:
#   Usage: lavish-axi poll <html-file> [--agent-reply "..."]
# and that command "long-polls indefinitely" server-side. The adapter therefore
# runs the plain blocking form with no timeout flag, so results arrive as real
# server-side events. It adds no periodic discovery, no timer fallback, and no
# dependency on any unreleased capability.
#
# LOSS LIMITATION, stated plainly. The published poll destructively clears
# feedback before returning it. A result lost after that clearing and before the
# runner reads the process output is unrecoverable, and no Firstmate wrapper can
# close that source-side handoff window. Never describe this path as
# at-least-once, no-loss, or lossless. The only durability this proves is the
# runner's own: output that reached the runner is stored before it is announced.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-procevent-lib.sh
. "$SCRIPT_DIR/fm-procevent-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,54p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }

# Canonical identity is physical, not the path string: Lavish itself keys a
# session on the realpath of the artifact, so two names for one file are one
# source and must never become two owners.
cmd_source_id() {
  local artifact=${1-} real
  [ -n "$artifact" ] || usage
  case "$artifact" in *$'\n'*) die "artifact paths cannot contain newlines" ;; esac
  real=$(perl -MCwd=realpath -e '$p = realpath($ARGV[0]); defined($p) or exit 1; print "$p\n"' "$artifact" 2>/dev/null) \
    || die "cannot resolve the artifact path: $artifact"
  [ -f "$real" ] || die "artifact does not exist: $artifact"
  if command -v shasum >/dev/null 2>&1; then
    printf 'lavish-%s\n' "$(printf '%s' "$real" | shasum -a 256 | awk '{print substr($1,1,16)}')"
  else
    printf 'lavish-%s\n' "$(printf '%s' "$real" | sha256sum | awk '{print substr($1,1,16)}')"
  fi
}

# Lavish's own authoritative session state for one exact artifact, read from the
# published listing that bare `lavish-axi` prints. Verified against 0.1.45: an
# open session appears as `  <realpath>,<status>,"<url>",<pending>` under a
# `sessions[N]{file,status,url,pending_prompts}:` header, an empty machine
# prints `sessions: []`, and a session that ended - by the human in the browser
# or by the agent - disappears from the listing entirely, exactly like an
# artifact that never had one. So `absent` covers both halves of "cannot accept
# feedback", which is the only distinction arm has to make.
#
# The listing keys on the SAME realpath Lavish itself keys a session on, which is
# what makes this an exact-session question rather than a path-string one. The
# path field is matched as a whole literal prefix up to its comma, so an artifact
# path containing a comma cannot be read as some other session's row.
cmd_session_state() {  # <artifact.html>
  local artifact=${1-} real listing status
  [ -n "$artifact" ] || usage
  command -v lavish-axi >/dev/null 2>&1 || die "lavish-axi is not installed"
  real=$(perl -MCwd=realpath -e '$p = realpath($ARGV[0]); defined($p) or exit 1; print "$p\n"' "$artifact" 2>/dev/null) \
    || die "cannot resolve the artifact path: $artifact"
  listing=$(lavish-axi </dev/null 2>/dev/null) || true
  # No session block at all means the question was not answered. Reporting that
  # as "absent" would turn an unreadable Lavish into a false ended verdict, which
  # is exactly the wrong way for this check to fail.
  printf '%s\n' "$listing" | grep -q '^sessions' \
    || die "cannot read the Lavish session listing"
  status=$(printf '%s\n' "$listing" | FM_LAVISH_TARGET="$real," awk '
    $0 ~ /^sessions:[[:space:]]*\[\][[:space:]]*$/ { exit }
    $0 ~ /^sessions\[[0-9]+\]\{/ { in_s = 1; next }
    in_s && $0 !~ /^[[:space:]]/ { exit }
    in_s {
      row = $0
      sub(/^[[:space:]]+/, "", row)
      target = ENVIRON["FM_LAVISH_TARGET"]
      if (substr(row, 1, length(target)) != target) next
      rest = substr(row, length(target) + 1)
      cut = index(rest, ",")
      if (cut > 0) rest = substr(rest, 1, cut - 1)
      print rest
      exit
    }
  ')
  printf '%s\n' "${status:-absent}"
}

# The one wording for a target that cannot accept feedback, so an ended session
# and a never-opened artifact read identically to a caller: both mean this
# handoff has no surface to wait on, and neither is fixed by re-arming.
die_target_gone() {  # <source-id> <realpath>
  die "the Lavish session for $2 ended or was missing before a live listener was established, so it cannot accept feedback and this handoff did not arm: $1"
}

# One confirmation: Lavish's own state says that exact session is open, and the
# runner says the exact source has a live owner executing its registered
# listener. Whether the session can still accept feedback is a question Lavish
# answers directly, rather than one inferred from how long the blocking poll
# takes to reach the same verdict - that inference is what reported ended and
# missing targets as armed on a loaded host, because the poll's answer arrives
# later under load while this answer does not move with load at all.
#
# Exit 3 from await-live is the runner's distinct "this source already ended"
# verdict, which for Lavish means the same thing: a failed handoff however
# durably its terminal result was captured.
confirm_handoff() {  # <source-id> <realpath> <baseline-sequence>
  local state live_status=0
  state=$(cmd_session_state "$2") || exit 1
  [ "$state" = open ] || die_target_gone "$1" "$2"
  "$SCRIPT_DIR/fm-procevent.sh" await-live "$1" "$3" >/dev/null || live_status=$?
  [ "$live_status" -ne 3 ] || die_target_gone "$1" "$2"
  [ "$live_status" -eq 0 ] || exit 1
}

cmd_arm() {
  local artifact=${1-} id real baseline
  [ -n "$artifact" ] || usage
  command -v lavish-axi >/dev/null 2>&1 || die "lavish-axi is not installed"
  id=$(cmd_source_id "$artifact") || exit 1
  real=$(perl -MCwd=realpath -e '$p = realpath($ARGV[0]); defined($p) or exit 1; print "$p\n"' "$artifact" 2>/dev/null) \
    || die "cannot resolve the artifact path: $artifact"
  # The plain blocking form: no --timeout-ms, so completion is a server event.
  "$SCRIPT_DIR/fm-procevent.sh" register lavish "$id" -- lavish-axi poll "$real" || exit 1
  # A canonical id is the artifact path, so results captured from earlier reviews
  # of the same file live on. Baselining here - after the registration exists and
  # before anything can start - is what keeps the ended verdict below about THIS
  # attempt rather than about a session that ended days ago.
  baseline=$("$SCRIPT_DIR/fm-procevent.sh" latest-sequence "$id") || exit 1
  # Reconcile before the first confirmation, never after it. An ended session
  # still owes one final `Send & End` payload, and only a started listener can
  # collect it; the registration then retires itself on that terminal result
  # whether or not this arm is still around to watch. Confirming first would drop
  # the human's last feedback on the floor.
  "$SCRIPT_DIR/fm-procevent.sh" reconcile >/dev/null || exit 1
  confirm_handoff "$id" "$real" "$baseline"
  # Confirm again immediately before reporting ready. The session can end while
  # liveness is being confirmed, and the listener can exit while the session is
  # being read; neither half subsumes the other, so `armed:` is printed only when
  # a whole confirmation holds with nothing else in between.
  confirm_handoff "$id" "$real" "$baseline"
  printf 'armed: %s\n' "$id"
  printf 'artifact: %s\n' "$real"
}

cmd_retire() {
  local artifact=${1-} id
  [ -n "$artifact" ] || usage
  id=$(cmd_source_id "$artifact") || exit 1
  "$SCRIPT_DIR/fm-procevent.sh" retire "$id"
}

# Read one field of the response's leading `session:` block. Those fields are
# INDENTED, so each is read as the first indented match inside that block rather
# than an anchored whole-line match; anchoring on "^status:" silently never
# matches and treats every ended review as feedback. Confining the read to the
# leading block is also what stops prompt payload text from forging a session
# field. <field> is a fixed field name supplied by this adapter, never by input.
session_field() {  # <result-file> <field>
  awk -v field="$2" '
    $0 == "session:" { in_s=1; next }
    in_s && $0 !~ /^[[:space:]]/ { exit }
    in_s && $0 ~ "^[[:space:]]+" field ":[[:space:]]*[A-Za-z_]+[[:space:]]*$" {
      sub("^[[:space:]]+" field ":[[:space:]]*", ""); sub(/[[:space:]]*$/, ""); print; exit }
  ' "$1"
}

# Classify a completed result into a lifecycle state for the handler.
cmd_classify() {
  local file=${1-} status error_code error_message
  [ -n "$file" ] || usage
  [ -f "$file" ] || die "result file does not exist: $file"
  status=$(session_field "$file" status)
  case "$status" in
    feedback) printf 'feedback\n'; return 0 ;;
    ended)    printf 'ended\n'; return 0 ;;
    waiting)  printf 'waiting\n'; return 0 ;;
  esac
  error_message=$(awk 'NR == 1 && /^error:[[:space:]]*/ { sub(/^error:[[:space:]]*/, ""); print }' "$file")
  error_code=$(awk '
    NR == 1 && /^error:[[:space:]]*/ { in_error=1; next }
    in_error && /^code:[[:space:]]*[A-Z_]+[[:space:]]*$/ {
      sub(/^code:[[:space:]]*/, ""); sub(/[[:space:]]*$/, ""); print; exit }
    in_error { exit }
  ' "$file")
  if [ "$error_code" = NOT_FOUND ] || [[ "$error_message" == "No active Lavish Editor session"* ]]; then
    printf 'missing\n'
  else
    printf 'unknown\n'
  fi
}

# Whether a captured result ends this source, for the generic runner's automatic
# retirement. Lavish's notion of "ended" lives here and nowhere else: an ended
# session produces nothing further, a missing session has nothing left to
# produce, and the published poll delivers the final feedback of a `Send & End`
# review marked with session_ended and returns only empty ended sessions after
# it. Anything else - including an unreadable result - keeps the source armed.
cmd_terminal() {
  local file=${1-}
  [ -n "$file" ] || usage
  [ -f "$file" ] || die "result file does not exist: $file"
  case "$(cmd_classify "$file")" in
    ended|missing) return 0 ;;
  esac
  case "$(session_field "$file" session_ended)" in
    true|True|TRUE) return 0 ;;
  esac
  return 1
}

case "${1-}" in
  arm)       shift; cmd_arm "$@" ;;
  session-state) shift; cmd_session_state "$@" ;;
  retire)    shift; cmd_retire "$@" ;;
  source-id) shift; cmd_source_id "$@" ;;
  classify)  shift; cmd_classify "$@" ;;
  terminal)  shift; cmd_terminal "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
