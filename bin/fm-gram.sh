#!/usr/bin/env bash
# fm-gram.sh - automatic intake of owner Gram messages addressed to this home.
#
# Usage:
#   fm-gram.sh poll        one bounded poll; capture and publish what is new
#   fm-gram.sh --help
#
# Gram is Herdr's owner<->agent message channel (`herdr gram`). Before this, a
# message the owner sent to firstmate sat in the store until somebody ran
# `herdr gram list` by hand. This poll is the automatic half; the recurring
# schedule is bin/fm-gram-check.sh, which registers it as a standing watcher
# check.
#
# WHAT IT TAKES, AND WHAT IT DELIBERATELY LEAVES ALONE
#
# Eligible: `direction == "owner_to_agent"` messages that carry a non-empty `to`,
# i.e. the owner addressed this agent specifically.
# Never eligible, and never claimed:
#   - shared queue items (owner_to_agent with no `to`). Claiming one needs
#     `herdr gram grab`, which is a first-wins claim against the whole fleet, and
#     silently taking fleet work nobody asked this home for is exactly the
#     behavior this poll must not have.
#   - anything this or another agent sent (`agent_to_owner`), which is what keeps
#     a home from reading and re-answering its own messages in a loop.
# Nothing here ever mutates the store: no grab, no post, no mark-read, no delete.
# The poll is read-only against Gram, so it cannot consume a message another
# recipient still needs, and a re-read is always safe.
#
# IDENTITY
#
# `herdr gram list` has no identity override (only `send --from` and `grab --as`
# do), so the audience it returns is resolved solely from HERDR_PANE_ID. Verified
# on herdr 0.9.0-preview: a Herdr pane exports HERDR_PANE_ID and nested children
# inherit it, so a check running under the watcher, under the primary's turn-end
# hook, under the pane, sees the primary's own audience. Outside a pane there is
# no identity and the list comes back empty, which would be a silent gap rather
# than an error, so this poll reports a missing HERDR_PANE_ID instead of
# treating "no messages" as good news.
#
# ROUTING
#
# A new message is captured privately first, then handed to bin/fm-inbox.sh note,
# which already owns durable capture plus exactly one `check` wake and stays
# pending until `bin/fm-inbox.sh drain --ack <id>`. The message body reaches
# firstmate as ordinary captain input under ordinary authority: it is passed as a
# single argument, never interpolated into a shell, and it authorizes nothing by
# itself. An instruction inside a Gram message is a request, exactly like a
# request typed in chat, and every merge, destructive, irreversible, and
# security-sensitive boundary applies to it unchanged.
#
# DUPLICATE BOUNDARY, stated plainly
#
# The cursor state/.gram-seen is keyed by store id plus message id, so the same
# message is published once across restarts and across a store that renumbers
# nothing. The order is capture -> publish -> record, because losing a message
# the owner sent is worse than showing it twice: a crash between publishing and
# recording can therefore re-publish that one message on the next poll. That is
# the whole guarantee. This is not at-least-once, not no-loss, and not
# exactly-once delivery, and must never be described as any of them.
#
# CONFIDENTIALITY, AND WHAT THE OWNER'S DELETION MEANS HERE
#
# Message text is written only to the private capture under state/gram-inbox/
# (mode 0600) and to the inbox note. It is never printed to stdout, never put in
# a wake payload beyond what fm-inbox.sh's own summary does, and never written to
# a status log. The poll's own output lines carry counts and ids, never bodies.
#
# `herdr gram delete` is documented as the way to clean up a short-lived secret,
# so a copy of that secret sitting in this home after the owner purged it would
# quietly break that advice. Every poll therefore reconciles: a capture for THIS
# store whose message id is gone from the listing is deleted, and so is every
# other local copy it produced.
#
# There are exactly THREE durable local sinks for a message body, and the purge
# covers all three:
#   1. the private capture under state/gram-inbox/;
#   2. the derived note under state/inbox/, or state/inbox/handled/ once acked;
#   3. the state/.wake-queue row fm-inbox.sh appended, whose payload carries the
#      note's first hundred characters of body.
# Anything else that ever sees a body is transient: this poll's own printed
# lines and the standing check's output carry counts and ids only.
#
# What the purge CANNOT do is retract text already delivered into a conversation
# transcript. Once a drained wake or a read note has reached the model's context
# or a rendered pane, it is out of this home's reach, and no claim here covers it.
#
# The deletion is inferred only from absence in the audience this poll can see,
# which is exactly the audience that produced the capture, so nothing is
# concluded about any other recipient's copy. The state/.gram-seen entry is
# deliberately kept, so a purged message is never re-published if the store ever
# shows it again.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CAPTURE_DIR="$STATE/gram-inbox"
SEEN="$STATE/.gram-seen"
SEEN_LOCK="$STATE/.gram-seen.lock"
INBOX_BIN="$SCRIPT_DIR/fm-inbox.sh"
HERDR_BIN=${FM_GRAM_HERDR_BIN:-herdr}

BUDGET=${FM_GRAM_BUDGET:-10}
case "$BUDGET" in
  ''|*[!0-9]*|0) BUDGET=10 ;;
esac

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

usage() {
  cat <<'EOF'
Usage:
  fm-gram.sh poll     one bounded poll: capture and publish owner messages addressed to this home
  fm-gram.sh --help   print this help

Environment:
  FM_HOME              operational home whose state/ is used
  FM_GRAM_HERDR_BIN    herdr executable to call (default: herdr)
  FM_GRAM_BUDGET       seconds allowed for the herdr call (default: 10)
  HERDR_PANE_ID        resolves which audience `herdr gram list` returns
EOF
}

say() {
  printf 'fm-gram: %s\n' "$1"
}

# One bounded `herdr gram list`. Prints the raw JSON on success.
gram_list() {
  fm_run_timed "$BUDGET" "$HERDR_BIN" gram list 2>/dev/null
}

# Eligible rows as tab-separated "<id>\t<from>", oldest first. Bodies never pass
# through this function's stdout.
select_eligible() {  # <json>
  printf '%s' "$1" | jq -r '
    (.result.messages // [])
    | map(select(
        .direction == "owner_to_agent"
        and (.to | type) == "string"
        and ((.to | length) > 0)
        and (.id | type) == "string"
      ))
    | sort_by(.created_unix_ms // 0)
    | .[]
    | [.id, (.from // "owner")]
    | @tsv
  ' 2>/dev/null
}

seen_has() {  # <store> <id>
  [ -f "$SEEN" ] || return 1
  grep -Fqx "$1	$2" "$SEEN" 2>/dev/null
}

seen_record() {  # <store> <id>
  printf '%s\t%s\n' "$1" "$2" >>"$SEEN" 2>/dev/null || return 1
  chmod 0600 "$SEEN" 2>/dev/null || true
}

# Capture the whole message record privately BEFORE anything is published, so a
# crash mid-publish still leaves the owner's words on disk to recover from.
capture() {  # <json> <store> <id>
  local json=$1 store=$2 id=$3 safe path tmp
  safe=$(printf '%s.%s' "$store" "$id" | tr -c 'A-Za-z0-9._-' '_')
  path="$CAPTURE_DIR/$safe.json"
  [ -e "$path" ] && { printf '%s' "$path"; return 0; }
  tmp=$(umask 077; mktemp "$CAPTURE_DIR/.capture.XXXXXX" 2>/dev/null) || return 1
  if ! printf '%s' "$json" | jq --arg id "$id" --arg store "$store" \
    '{store_id: $store, captured_unix: (now | floor), message: ((.result.messages // []) | map(select(.id == $id)) | first)}' \
    >"$tmp" 2>/dev/null
  then
    rm -f -- "$tmp"
    return 1
  fi
  chmod 0600 "$tmp" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$path" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
  printf '%s' "$path"
}

# Hand the body to the inbox owner as one argument. Never a shell string.
# Prints the queued note id so the capture can record which note it produced;
# the inbox's own output is consumed here and never reaches this poll's stdout,
# because its summary line carries the message body.
publish() {  # <capture-path> <from>
  local path=$1 from=$2 body out
  body=$(jq -r '
    [ (.message.text // ""),
      (if (.message.file.name // "") != "" then "[attached file: " + .message.file.name + "]" else "" end)
    ] | map(select(. != "")) | join("\n")
  ' "$path" 2>/dev/null) || return 1
  [ -n "${body//[[:space:]]/}" ] || body="(the owner sent a Gram message with no text)"
  [ -x "$INBOX_BIN" ] || return 1
  out=$(FM_HOME="$FM_HOME" "$INBOX_BIN" note "Gram message from $from: $body" 2>/dev/null) || return 1
  printf '%s' "$out" | sed -n 's/^queued //p' | head -n 1 | tr -dc 'A-Za-z0-9._-'
}

# Record which inbox note this capture produced, so honouring a later deletion
# can remove both halves of the copy rather than only the capture.
capture_note() {  # <capture-path> <note-id>
  local path=$1 note=$2 tmp
  [ -n "$note" ] || return 0
  tmp=$(umask 077; mktemp "$CAPTURE_DIR/.capture.XXXXXX" 2>/dev/null) || return 1
  if ! jq --arg note "$note" '. + {note_id: $note}' "$path" >"$tmp" 2>/dev/null; then
    rm -f -- "$tmp"
    return 1
  fi
  chmod 0600 "$tmp" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$path" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
}

# Drop the pending wake row a purged note produced, and nothing else. The wake
# queue is durable supervision state, so dropping the wrong row loses a wake for
# good: this matches the exact `inbox:<note-id>` key in the row's own key field
# rather than any substring of its payload, takes the queue's own lock so a
# concurrent drain never reads a half-written file, and renames a sibling
# temporary into place. A lock it cannot take inside its bound, or a rewrite it
# cannot finish, is reported rather than attempted optimistically - a surviving
# row is recoverable on the next poll, a corrupted queue is not.
purge_wake_row() {  # <note-id>
  local note=$1 tmp rc=0
  [ -f "$FM_WAKE_QUEUE" ] || return 0
  fm_lock_acquire_wait_bounded "$FM_WAKE_QUEUE_LOCK" 5 || return 1
  if tmp=$(mktemp "$FM_WAKE_QUEUE.purge.XXXXXX" 2>/dev/null); then
    if awk -F '\t' -v key="inbox:$note" 'NF < 5 || $4 != key' "$FM_WAKE_QUEUE" >"$tmp" 2>/dev/null \
      && mv -f -- "$tmp" "$FM_WAKE_QUEUE" 2>/dev/null
    then
      rc=0
    else
      rm -f -- "$tmp"
      rc=1
    fi
  else
    rc=1
  fi
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  return "$rc"
}

# Honour `herdr gram delete`: a capture for THIS store whose message id is gone
# from the listing describes a message the owner purged, so every local copy this
# home made goes too - the wake row carrying the note's summary, the inbox note
# itself whether pending or already handled, and the capture.
#
# The wake row goes FIRST, because the capture is what records the note id: a
# capture removed ahead of a row that could not be dropped would strand that row
# with nothing left to identify it. So a row this poll cannot drop leaves the
# whole capture in place, counts a failure, and the next poll retries the lot.
# A capture for another store is never touched, and state/.gram-seen is left
# alone so a purged message can never be published a second time.
PURGE_FAILED=0
purge_deleted() {  # <store> <live-ids>
  local store=$1 live=$2 f cap_store cap_id note
  PURGE_FAILED=0
  [ -d "$CAPTURE_DIR" ] || return 0
  for f in "$CAPTURE_DIR"/*.json; do
    [ -f "$f" ] || continue
    cap_store=$(jq -r '.store_id // empty' "$f" 2>/dev/null) || continue
    [ "$cap_store" = "$store" ] || continue
    cap_id=$(jq -r '.message.id // empty' "$f" 2>/dev/null) || continue
    [ -n "$cap_id" ] || continue
    printf '%s\n' "$live" | grep -Fqx -- "$cap_id" && continue
    note=$(jq -r '.note_id // empty' "$f" 2>/dev/null)
    case "$note" in
      ''|*[!A-Za-z0-9._-]*) note='' ;;
    esac
    if [ -n "$note" ]; then
      if ! purge_wake_row "$note"; then
        PURGE_FAILED=$((PURGE_FAILED + 1))
        continue
      fi
      rm -f -- "$STATE/inbox/$note.note" "$STATE/inbox/handled/$note.note"
    fi
    rm -f -- "$f"
  done
}

action_poll() {
  local json rc store rows live published=0 failed=0 id from path note

  command -v jq >/dev/null 2>&1 || { say 'jq is missing, so Gram intake cannot run'; return 1; }
  command -v "$HERDR_BIN" >/dev/null 2>&1 || { say "the herdr CLI ($HERDR_BIN) is missing, so Gram intake cannot run"; return 1; }
  if [ -z "${HERDR_PANE_ID:-}" ]; then
    say 'no HERDR_PANE_ID in this environment, so "herdr gram list" resolves no audience and would report an empty inbox whether or not the owner wrote. Gram intake is not running.'
    return 1
  fi
  mkdir -p "$CAPTURE_DIR" 2>/dev/null || { say "cannot create $CAPTURE_DIR"; return 1; }
  chmod 0700 "$CAPTURE_DIR" 2>/dev/null || true

  json=$(gram_list)
  rc=$?
  if [ "$rc" -eq 124 ]; then
    say "the herdr gram call did not finish inside ${BUDGET}s"
    return 1
  fi
  if [ "$rc" -ne 0 ] || [ -z "$json" ]; then
    local err
    err=$(printf '%s' "$json" | jq -r '.error.code // .error // empty' 2>/dev/null)
    say "herdr gram list failed${err:+ ($err)}"
    return 1
  fi
  store=$(printf '%s' "$json" | jq -r '.result.store_id // empty' 2>/dev/null)
  if [ -z "$store" ]; then
    say 'herdr gram list returned no store id, so nothing can be deduplicated safely'
    return 1
  fi

  # Every id the store still shows this audience, eligible or not: absence from
  # THIS set is what a purge looks like from here.
  live=$(printf '%s' "$json" | jq -r '
    (.result.messages // [])[] | select((.id | type) == "string") | .id
  ' 2>/dev/null)
  rows=$(select_eligible "$json")

  # Serialize against an overlapping poll so two cycles cannot publish the same
  # message twice, or one purge a capture the other is still publishing. A held
  # lock means another poll is already doing this work.
  fm_lock_try_acquire "$SEEN_LOCK" || return 0
  purge_deleted "$store" "$live"
  while IFS=$'\t' read -r id from; do
    [ -n "$id" ] || continue
    seen_has "$store" "$id" && continue
    if ! path=$(capture "$json" "$store" "$id"); then
      failed=$((failed + 1))
      continue
    fi
    if ! note=$(publish "$path" "$from"); then
      failed=$((failed + 1))
      continue
    fi
    capture_note "$path" "$note" || true
    if ! seen_record "$store" "$id"; then
      # Published but unrecorded: say so, because this exact message is the one
      # that can appear twice after a crash here.
      say "published Gram message $id but could not record it as seen; it may be published again"
    fi
    published=$((published + 1))
  done <<EOF
$rows
EOF
  fm_lock_release "$SEEN_LOCK"

  if [ "$failed" -gt 0 ]; then
    say "could not take in $failed Gram message(s) addressed to this home"
    return 1
  fi
  if [ "$published" -gt 0 ]; then
    say "$published new Gram message(s) from the owner are waiting in the captain inbox"
  fi
  if [ "$PURGE_FAILED" -gt 0 ]; then
    say "could not clear this home's copy of $PURGE_FAILED deleted Gram message(s); their wake rows are still queued and the next poll retries"
    return 1
  fi
  return 0
}

case "${1:-poll}" in
  poll) action_poll ;;
  -h|--help) usage ;;
  *)
    printf 'fm-gram: unknown action: %s\n' "$1" >&2
    usage >&2
    exit 2
    ;;
esac
