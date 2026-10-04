#!/usr/bin/env bash
# fm-inbox.sh - the captain's out-of-band capture surface.
#
# Solves three DIFFERENT problems with three different mechanisms, because they
# are not the same problem:
#
#   note    Queue an idea for firstmate while firstmate is mid-turn and cannot
#           answer. Writes a durable record and appends ONE `check` wake, so the
#           note survives a crash and is presented at firstmate's next drain.
#           This is the only subcommand that touches firstmate's wake queue.
#   status  Answer "what is happening" from durable records ONLY. Reads no
#           network and appends NO wake, so it never interrupts work and is safe
#           to run in a loop.
#   ask     Answer a side question with a one-shot model call that never touches
#           firstmate, task records, or the wake queue. A side question is not
#           fleet work and must not become fleet work.
#
# Usage:
#   fm-inbox.sh note <text>...          | fm-inbox.sh note -   (body from stdin)
#   fm-inbox.sh status
#   fm-inbox.sh ask  <question>...
#   fm-inbox.sh list
#   fm-inbox.sh drain [--ack <id>...]
#
# Configuration. A region, a model id and an AWS profile name somebody's account
# and somebody's choices, so this file carries no default for any of them. Each is
# read from the home's gitignored config/ directory, or from the matching
# environment variable, and the model-backed subcommand refuses with the path to
# write rather than reaching for a value that belongs to another home. That
# configuration is also the opt-in: `ask` is off until it exists.
#
#   config/inbox-region     FM_INBOX_REGION     AWS region.            required by ask
#   config/inbox-ask-model  FM_INBOX_ASK_MODEL  side-question model.   required by ask
#   config/inbox-profile    FM_INBOX_PROFILE    AWS profile.           optional
#
# An absent profile means the call uses whatever credentials are already in the
# environment, which is also what FM_INBOX_PROFILE= (empty) forces.
#
# `note`, `status`, `list` and `drain` need NO configuration at all, because they
# make no model call and work in a home that has configured nothing.
#
# Environment:
#   FM_HOME              operational home whose state/ and data/ are used.
#
# PRIVACY: `ask` sends your question to Bedrock.
# `note`, `status`, `list` and `drain` make no network call at all.
#
set -euo pipefail

# A non-interactive `ssh host fm-inbox.sh ...` does NOT get a login shell, so it
# does not get ~/.toolbox/bin on PATH. The AWS profile's credential_process is
# the bare word `ada`, so without this the model-backed subcommand fails with
# "[Errno 2] No such file or directory: 'ada'" while note/status still work.
# Verified: this is exactly what happens over SSH without the fix.
for _extra in "$HOME/.toolbox/bin" "$HOME/.local/bin"; do
  case ":$PATH:" in
    *":$_extra:"*) ;;
    *) [ -d "$_extra" ] && PATH="$_extra:$PATH" ;;
  esac
done
unset _extra
export PATH

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SELF_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
INBOX="$STATE/inbox"

CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

die() { printf 'fm-inbox: %s\n' "$*" >&2; exit 1; }

# First non-comment, non-blank line of a config file, or nothing.
read_setting() {  # <file-name>
  local path="$CONFIG/$1" line
  [ -r "$path" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%#*}
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    [ -n "$line" ] || continue
    printf '%s' "$line"
    return 0
  done < "$path"
}

# Refuse by naming the file to write. A model call that guessed at a region or an
# account would either fail confusingly or, worse, succeed against a stranger's.
require_setting() {  # <file-name> <env-var> <what>
  local value
  value=$(read_setting "$1")
  [ -n "$value" ] || die "no $3 is configured: write one line into $CONFIG/$1 or set $2"
  printf '%s' "$value"
}

REGION="${FM_INBOX_REGION:-}"
ASK_MODEL="${FM_INBOX_ASK_MODEL:-}"
# Unset falls through to config; explicitly empty means "use ambient credentials".
PROFILE="${FM_INBOX_PROFILE-$(read_setting inbox-profile)}"

# Resolved only by the subcommands that make a model call, so note, status, list
# and drain keep working in a home that has configured nothing.
need_region() {
  [ -n "$REGION" ] || REGION=$(require_setting inbox-region FM_INBOX_REGION "AWS region")
}

need_ask_model() {
  need_region
  [ -n "$ASK_MODEL" ] || ASK_MODEL=$(require_setting inbox-ask-model \
    FM_INBOX_ASK_MODEL "side-question model")
}

need() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

# The profile's credential_process (`ada`) costs a MEASURED ~1030ms on every
# single call, which is about half the wall time of `ask`. If real
# credentials are already in the environment, skip --profile entirely and let the
# ambient ones win. Set FM_INBOX_PROFILE= (empty) to force that even without env
# credentials present.
aws_call() {
  if [ -z "$PROFILE" ] || [ -n "${AWS_ACCESS_KEY_ID:-}" ]; then
    aws --region "$REGION" "$@"
  else
    aws --profile "$PROFILE" --region "$REGION" "$@"
  fi
}

# ---------------------------------------------------------------- note

# Append exactly one wake so firstmate picks the note up at its next drain.
# Failure to wake is NOT allowed to lose the note: the record is already on
# disk, so we report the wake failure and still exit non-zero loudly.
wake_for() {
  local id=$1 summary=$2 lib="$FM_ROOT/bin/fm-wake-lib.sh"
  if [ ! -r "$lib" ]; then
    printf 'fm-inbox: note saved but NOT announced (missing %s)\n' "$lib" >&2
    return 1
  fi
  # shellcheck source=/dev/null
  FM_ROOT_OVERRIDE="$FM_ROOT" FM_HOME="$FM_HOME" STATE="$STATE" . "$lib"
  fm_wake_append check "inbox:$id" "check: captain inbox note $id - $summary"
}

queue_note() {
  local source=$1 body=$2 extra=${3:-}
  [ -n "${body//[[:space:]]/}" ] || die "refusing to queue an empty note"
  mkdir -p "$INBOX"

  local tmp id summary staging_name
  tmp=$(mktemp "$INBOX/.staging-XXXXXX")
  staging_name=$(basename "$tmp")
  id="$(date +%s)-${staging_name#.staging-}"
  {
    printf 'id=%s\n' "$id"
    printf 'at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'source=%s\n' "$source"
    [ -z "$extra" ] || printf '%s\n' "$extra"
    printf -- '--\n'
    printf '%s\n' "$body"
  } >"$tmp"

  # Publish the completed note atomically.
  mv "$tmp" "$INBOX/$id.note"

  # One-line summary for the wake payload; the full body stays in the file.
  summary=$(printf '%s' "$body" | tr '\n\t' '  ' | cut -c1-100)
  printf 'queued %s\n' "$id"
  printf '  %s\n' "$summary"
  if wake_for "$id" "$summary"; then
    printf '  firstmate will pick this up at its next check.\n'
  else
    die "note $id is saved at $INBOX/$id.note but firstmate was NOT woken"
  fi
}

cmd_note() {
  local body
  if [ "$#" -eq 0 ]; then
    die "usage: fm-inbox.sh note <text>...   (or: note - to read stdin)"
  elif [ "$1" = "-" ]; then
    body=$(cat)
  else
    body="$*"
  fi
  queue_note text "$body"
}

# ---------------------------------------------------------------- status

cmd_status() {
  local pending=0
  [ -d "$INBOX" ] && pending=$(find "$INBOX" -maxdepth 1 -name '*.note' 2>/dev/null | wc -l | tr -d ' ')

  printf '=== firstmate status (read-only, no wake sent) ===\n'
  printf 'home     %s\n' "$FM_HOME"
  printf 'time     %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'inbox    %s note(s) waiting for firstmate\n' "$pending"

  printf '\n--- in flight ---\n'
  FM_DATA_OVERRIDE="$DATA" "$FM_ROOT/bin/fm-tasks-axi.sh" list \
    --state in_flight --limit 10000 | cut -c1-150

  local any=0
  for m in "$STATE"/*.meta; do
    [ -e "$m" ] || break
    if [ "$any" -eq 0 ]; then printf '\n--- workers ---\n'; any=1; fi
    local id kind mode last
    id=$(basename "$m" .meta)
    kind=$(sed -n 's/^kind=//p' "$m" | head -1)
    mode=$(sed -n 's/^mode=//p' "$m" | head -1)
    last=""
    [ -f "$STATE/$id.status" ] && last=$(tail -1 "$STATE/$id.status" 2>/dev/null | cut -c1-100)
    printf '  %-42s %-6s %-10s %s\n' "$id" "${kind:-?}" "${mode:--}" "${last:-(no events yet)}"
  done
  [ "$any" -eq 1 ] || printf '\n(no workers on deck)\n'

  printf '\nNote: the last event line is history, not current state.\n'
}

# ---------------------------------------------------------------- ask

cmd_ask() {
  [ "$#" -gt 0 ] || die "usage: fm-inbox.sh ask <question>..."
  need_ask_model
  need aws
  need python3
  local q="$*" msg
  msg=$(mktemp /tmp/fm-inbox-ask-XXXXXX.json)
  # shellcheck disable=SC2064
  trap "rm -f '$msg'" EXIT

  Q="$q" python3 - "$msg" <<'PY'
import json, os, sys
json.dump([{"role": "user", "content": [{"text": os.environ["Q"]}]}],
          open(sys.argv[1], 'w'))
PY

  aws_call bedrock-runtime converse \
    --model-id "$ASK_MODEL" \
    --messages "file://$msg" \
    --system '[{"text":"You are a terse engineering assistant answering a side question. Be direct and concrete. No preamble. If you are not sure, say so."}]' \
    --inference-config '{"maxTokens":700,"temperature":0.2}' \
    --query 'output.message.content[0].text' --output text \
    || die "ask failed"
}

# ---------------------------------------------------------------- list / drain

cmd_list() {
  [ -d "$INBOX" ] || { printf '(inbox empty)\n'; return 0; }
  local any=0
  for f in "$INBOX"/*.note; do
    [ -e "$f" ] || break
    any=1
    printf '%s\n' "$(basename "$f" .note)"
    sed -n '/^--$/,$p' "$f" | tail -n +2 | sed 's/^/    /'
  done
  [ "$any" -eq 1 ] || printf '(inbox empty)\n'
}

cmd_drain() {
  if [ "${1:-}" = "--ack" ]; then
    shift
    [ "$#" -gt 0 ] || die "usage: fm-inbox.sh drain --ack <id>..."
    mkdir -p "$INBOX/handled"
    local id
    for id in "$@"; do
      if [ -f "$INBOX/$id.note" ]; then
        mv "$INBOX/$id.note" "$INBOX/handled/$id.note"
        printf 'acked %s\n' "$id"
      else
        printf 'already-acked %s\n' "$id"
      fi
    done
    return 0
  fi
  cmd_list
  printf '\nAck with: fm-inbox.sh drain --ack <id>...\n'
}

# ---------------------------------------------------------------- dispatch

case "${1:-}" in
  note)   shift; cmd_note "$@" ;;
  status) shift; cmd_status ;;
  ask)    shift; cmd_ask "$@" ;;
  list)   shift; cmd_list ;;
  drain)  shift; cmd_drain "$@" ;;
  ''|-h|--help|help)
    # The whole header block, found rather than counted: everything after the
    # shebang up to the first line that is not a comment. A fixed line range
    # silently truncates this help the next time the header grows, and the last
    # thing to fall off the end is the PRIVACY paragraph, which is the one place
    # a new operator is told which subcommands send anything off this host.
    awk 'NR == 1 { next }
         /^#/ { sub(/^# ?/, ""); print; next }
         { exit }' "${BASH_SOURCE[0]}" ;;
  *) die "unknown subcommand: $1 (try --help)" ;;
esac
