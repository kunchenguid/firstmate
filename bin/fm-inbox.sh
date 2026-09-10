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
#   say     Same as `note`, but the body comes from spoken audio on stdin.
#           Speech is an INPUT METHOD here, not an architecture: it transcribes
#           and then takes exactly the `note` path.
#   status  Answer "what is happening" from durable records ONLY. Reads no
#           network and appends NO wake, so it never interrupts work and is safe
#           to run in a loop.
#   ask     Answer a side question with a one-shot model call that never touches
#           firstmate, the backlog, or the wake queue. A side question is not
#           fleet work and must not become fleet work.
#
# Usage:
#   fm-inbox.sh note [--source <name> --external-id <id> [--metadata-file <json>]] <text>...
#   fm-inbox.sh note [--source <name> --external-id <id> [--metadata-file <json>]] -
#   fm-inbox.sh say  [<file.wav>]       (default: audio on stdin)
#   fm-inbox.sh status
#   fm-inbox.sh ask  <question>...
#   fm-inbox.sh list
#   fm-inbox.sh drain [--ack <id>...]
#
# Configuration. A region, a model id and an AWS profile name somebody's account
# and somebody's choices, so this file carries no default for any of them. Each is
# read from the home's gitignored config/ directory, or from the matching
# environment variable, and the model-backed subcommands refuse with the path to
# write rather than reaching for a value that belongs to another home. That
# configuration is also the opt-in: `say` and `ask` are off until it exists.
#
#   config/inbox-region     FM_INBOX_REGION     AWS region.            required
#   config/inbox-stt-model  FM_INBOX_STT_MODEL  speech-to-text model.  required by say
#   config/inbox-ask-model  FM_INBOX_ASK_MODEL  side-question model.   required by ask
#   config/inbox-profile    FM_INBOX_PROFILE    AWS profile.           optional
#
# An absent profile means the call uses whatever credentials are already in the
# environment, which is also what FM_INBOX_PROFILE= (empty) forces.
#
# `note`, `status`, `list` and `drain` need NO configuration at all, because they
# make no model call. The voice handover depends on `note`, so it keeps working in
# a home that has configured nothing.
#
# Environment:
#   FM_HOME              operational home whose state/ and data/ are used.
#
# PRIVACY: `say` sends your audio and `ask` sends your question to Bedrock.
# `note`, `status`, `list` and `drain` make no network call at all.
#
# `note` is also the queueing half of the spoken interface: when the voice agent
# in bin/fm-voice-relay.py hands real work over to firstmate, it runs this
# subcommand rather than carrying a second queue of its own. Keep the `note`
# contract stable for that caller. A trusted external intake may add
# `--source`, `--external-id`, and `--metadata-file`; replaying the same source
# and upstream id returns the first note id and appends no second wake. `status`
# is the HUMAN view of the records; bin/fm_voice_records.py owns the
# scope-controlled machine view the voice agent reads, because the voice agent
# must be able to answer without record free text ever reaching a model.
set -euo pipefail

# A non-interactive `ssh host fm-inbox.sh ...` does NOT get a login shell, so it
# does not get ~/.toolbox/bin on PATH. The AWS profile's credential_process is
# the bare word `ada`, so without this the model-backed subcommands fail with
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
STT_MODEL="${FM_INBOX_STT_MODEL:-}"
ASK_MODEL="${FM_INBOX_ASK_MODEL:-}"
# Unset falls through to config; explicitly empty means "use ambient credentials".
PROFILE="${FM_INBOX_PROFILE-$(read_setting inbox-profile)}"

# Resolved only by the subcommands that make a model call, so note, status, list
# and drain keep working in a home that has configured nothing.
need_region() {
  [ -n "$REGION" ] || REGION=$(require_setting inbox-region FM_INBOX_REGION "AWS region")
}

need_stt_model() {
  need_region
  [ -n "$STT_MODEL" ] || STT_MODEL=$(require_setting inbox-stt-model \
    FM_INBOX_STT_MODEL "speech-to-text model")
}

need_ask_model() {
  need_region
  [ -n "$ASK_MODEL" ] || ASK_MODEL=$(require_setting inbox-ask-model \
    FM_INBOX_ASK_MODEL "side-question model")
}

need() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

source_wake_lib() {
  local lib="$FM_ROOT/bin/fm-wake-lib.sh"
  [ -r "$lib" ] || return 1
  # shellcheck source=/dev/null
  FM_ROOT_OVERRIDE="$FM_ROOT" FM_HOME="$FM_HOME" STATE="$STATE" . "$lib"
}

sha256_text() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  else
    die "no SHA-256 tool is available"
  fi
}

# The profile's credential_process (`ada`) costs a MEASURED ~1030ms on every
# single call, which is about half the wall time of `say` and `ask`. If real
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
  if ! source_wake_lib; then
    printf 'fm-inbox: note saved but NOT announced (missing %s)\n' "$lib" >&2
    return 1
  fi
  fm_wake_append check "inbox:$id" "check: captain inbox note $id - $summary"
}

validate_note_source() {
  case "$1" in
    ''|*[!A-Za-z0-9._-]*) die "note source must be path-safe" ;;
  esac
}

validate_external_id() {
  case "$1" in
    ''|*[!A-Za-z0-9._:-]*) die "external id must be a bounded non-secret id" ;;
  esac
  [ "${#1}" -le 256 ] || die "external id is too long"
}

validate_metadata_file() {
  local path=$1 bytes
  [ -f "$path" ] && [ ! -L "$path" ] || die "metadata file is unavailable or unsafe: $path"
  bytes=$(wc -c < "$path" | tr -d ' ')
  case "$bytes" in ''|*[!0-9]*) die "metadata file size is unreadable: $path" ;; esac
  [ "$bytes" -le 16384 ] || die "metadata file is too large: $path"
  need python3
  python3 - "$path" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    data = json.load(f)
if not isinstance(data, dict):
    raise SystemExit("metadata root must be a JSON object")
PY
}

external_map_path() {  # <source> <external-id>
  local digest
  digest=$(sha256_text "$1:$2") || return 1
  printf '%s/external/%s.map\n' "$INBOX" "$digest"
}

rewrite_external_map_announced() {  # <map-path> <0|1>
  local map=$1 announced=$2 tmp
  tmp=$(mktemp "${map%/*}/.map-XXXXXX") || return 1
  {
    sed -n '/^announced=/!p' "$map"
    printf 'announced=%s\n' "$announced"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv "$tmp" "$map"
}

queue_note_file() {  # <source> <body> <extra>
  local source=$1 body=$2 extra=${3:-} tmp id staging_name
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
  mv "$tmp" "$INBOX/$id.note"
  printf '%s\n' "$id"
}

queue_note() {
  local source=$1 body=$2 extra=${3:-} external_id=${4:-} metadata_file=${5:-}
  [ -n "${body//[[:space:]]/}" ] || die "refusing to queue an empty note"
  mkdir -p "$INBOX"

  if [ -n "$external_id" ]; then
    validate_note_source "$source"
    validate_external_id "$external_id"
    [ -z "$metadata_file" ] || validate_metadata_file "$metadata_file"
  fi

  local id summary map lock lock_held=0 metadata_dst tmp_map existing
  if [ -n "$external_id" ]; then
    mkdir -p "$INBOX/external"
    chmod 700 "$INBOX/external" 2>/dev/null || true
    map=$(external_map_path "$source" "$external_id")
    lock="$INBOX/.external.lock"
    source_wake_lib || die "missing wake/lock library: $FM_ROOT/bin/fm-wake-lib.sh"
    fm_lock_acquire_wait "$lock" || die "cannot lock external inbox map"
    lock_held=1
    # shellcheck disable=SC2064
    trap "[ '$lock_held' -eq 0 ] || fm_lock_release '$lock'" RETURN
    die_locked() { fm_lock_release "$lock"; lock_held=0; trap - RETURN; die "$1"; }
    if [ -f "$map" ] && [ ! -L "$map" ]; then
      existing=$(sed -n 's/^note_id=//p' "$map" | head -1)
      [ -n "$existing" ] || die_locked "external inbox map is malformed: $map"
      if [ "$(sed -n 's/^announced=//p' "$map" | head -1)" = "0" ]; then
        # The original note exists but its announcement failed earlier.
        # Retry announcing that same note; never create a duplicate.
        existing_summary=$(sed -n 's/^summary=//p' "$map" | head -1)
        if wake_for "$existing" "$existing_summary"; then
          rewrite_external_map_announced "$map" 1 || die_locked "cannot update external inbox map: $map"
          printf 'queued %s\n' "$existing"
          printf '  announcement retried and delivered; no new note was created.\n'
        else
          printf 'queued %s\n' "$existing"
          printf '  announcement retry FAILED; the original note stays saved at %s/%s.note.\n' "$INBOX" "$existing" >&2
          fm_lock_release "$lock"
          lock_held=0
          trap - RETURN
          return 1
        fi
      else
        printf 'queued %s\n' "$existing"
        printf '  duplicate external id; no new wake was appended.\n'
      fi
      fm_lock_release "$lock"
      lock_held=0
      trap - RETURN
      return 0
    fi
    [ ! -e "$map" ] && [ ! -L "$map" ] || die_locked "external inbox map is unsafe: $map"
    metadata_dst=""
    if [ -n "$metadata_file" ]; then
      metadata_dst="${map%.map}.metadata.json"
      cp "$metadata_file" "$metadata_dst" || die_locked "cannot copy metadata file"
      chmod 600 "$metadata_dst" || die_locked "cannot protect metadata file"
      extra="${extra}${extra:+$'\n'}external_metadata=$metadata_dst"
    fi
    extra="${extra}${extra:+$'\n'}external_source=$source
external_id=$external_id"
    id=$(queue_note_file "$source" "$body" "$extra")
    tmp_map=$(mktemp "$INBOX/external/.map-XXXXXX")
    summary=$(printf '%s' "$body" | tr '\n\t' '  ' | cut -c1-100)
    {
      printf 'schema=fm-inbox-external-map.v2\n'
      printf 'source=%s\n' "$source"
      printf 'external_id=%s\n' "$external_id"
      printf 'note_id=%s\n' "$id"
      printf 'announced=0\n'
      printf 'summary=%s\n' "$summary"
      [ -z "$metadata_dst" ] || printf 'metadata=%s\n' "$metadata_dst"
    } > "$tmp_map"
    chmod 600 "$tmp_map" || die_locked "cannot protect external inbox map"
    mv "$tmp_map" "$map" || die_locked "cannot publish external inbox map"
    printf 'queued %s\n' "$id"
    printf '  %s\n' "$summary"
    if wake_for "$id" "$summary"; then
      rewrite_external_map_announced "$map" 1 || die_locked "cannot update external inbox map: $map"
      printf '  firstmate will pick this up at its next check.\n'
    else
      # Keep the note and its external mapping (announced=0) so a replay of
      # the same source/external-id re-announces the original note instead of
      # creating a duplicate.
      printf '  announcement FAILED; replay the same source/external-id to retry. Note stays at %s/%s.note.\n' "$INBOX" "$id" >&2
      fm_lock_release "$lock"
      lock_held=0
      trap - RETURN
      die "note $id is saved at $INBOX/$id.note but firstmate was NOT woken"
    fi
    fm_lock_release "$lock"
    lock_held=0
    trap - RETURN
    return 0
  fi

  id=$(queue_note_file "$source" "$body" "$extra")
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
  local body source=text external_id='' metadata_file=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --source)
        [ "$#" -ge 2 ] || die "--source needs a value"
        source=$2
        shift 2
        ;;
      --external-id)
        [ "$#" -ge 2 ] || die "--external-id needs a value"
        external_id=$2
        shift 2
        ;;
      --metadata-file)
        [ "$#" -ge 2 ] || die "--metadata-file needs a value"
        metadata_file=$2
        shift 2
        ;;
      --)
        shift
        break
        ;;
      -|*)
        break
        ;;
    esac
  done
  if [ -z "$external_id" ] && { [ "$source" != text ] || [ -n "$metadata_file" ]; }; then
    die "--source or --metadata-file requires --external-id"
  fi
  if [ "$#" -eq 0 ]; then
    die "usage: fm-inbox.sh note [--source <name> --external-id <id> [--metadata-file <json>]] <text>..."
  elif [ "$1" = "-" ]; then
    body=$(cat)
  else
    body="$*"
  fi
  queue_note "$source" "$body" "" "$external_id" "$metadata_file"
}

# ---------------------------------------------------------------- say

cmd_say() {
  # Before the tool checks, so an unconfigured home is told what to configure
  # rather than what to install for a call it is not yet allowed to make.
  need_stt_model
  need aws
  need python3
  need base64

  local src wav raw transcript
  raw=$(mktemp /tmp/fm-inbox-audio-XXXXXX)
  wav=$(mktemp /tmp/fm-inbox-wav-XXXXXX.wav)
  # shellcheck disable=SC2064
  trap "rm -f '$raw' '$wav' '$wav.json'" EXIT

  if [ "$#" -ge 1 ] && [ "$1" != "-" ]; then
    src=$1
    [ -r "$src" ] || die "cannot read audio file: $src"
    cat "$src" >"$raw"
  else
    cat >"$raw"
  fi
  [ -s "$raw" ] || die "no audio received on stdin"

  # Accept a real WAV as-is; wrap headerless 16kHz mono s16le PCM if that is
  # what arrived. Anything else is rejected rather than silently mistranscribed.
  python3 - "$raw" "$wav" <<'PY'
import sys, wave
src, dst = sys.argv[1], sys.argv[2]
data = open(src, 'rb').read()
if data[:4] == b'RIFF':
    open(dst, 'wb').write(data)
    sys.stderr.write("fm-inbox: input is WAV, passing through\n")
elif data[:4] in (b'OggS', b'fLaC') or data[:3] == b'ID3':
    sys.exit("fm-inbox: got Ogg/FLAC/MP3; re-encode to WAV first")
else:
    if len(data) % 2:
        data = data[:-1]
    w = wave.open(dst, 'wb')
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000)
    w.writeframes(data); w.close()
    sys.stderr.write("fm-inbox: input looked like raw PCM, wrapped as 16kHz mono WAV\n")
PY

  local secs
  secs=$(python3 -c "
import wave,sys
w=wave.open('$wav'); print(round(w.getnframes()/w.getframerate(),2))")
  printf 'fm-inbox: %ss of audio, transcribing with %s in %s\n' "$secs" "$STT_MODEL" "$REGION" >&2

  python3 - "$wav" "$wav.json" <<'PY'
import base64, json, sys
b = base64.b64encode(open(sys.argv[1], 'rb').read()).decode()
json.dump([{"role": "user", "content": [
    {"audio": {"format": "wav", "source": {"bytes": b}}},
    {"text": "Transcribe the speech exactly. Output only the transcript, nothing else."},
]}], open(sys.argv[2], 'w'))
PY

  transcript=$(aws_call bedrock-runtime converse \
    --model-id "$STT_MODEL" \
    --messages "file://$wav.json" \
    --inference-config '{"maxTokens":600,"temperature":0}' \
    --query 'output.message.content[0].text' --output text) \
    || die "transcription failed"

  [ -n "${transcript//[[:space:]]/}" ] || die "transcription came back empty"
  printf 'fm-inbox: heard: %s\n' "$transcript" >&2
  queue_note voice "$transcript" "transcript_model=$STT_MODEL
audio_seconds=$secs"
}

# ---------------------------------------------------------------- status

cmd_status() {
  local pending=0
  [ -d "$INBOX" ] && pending=$(find "$INBOX" -maxdepth 1 -name '*.note' 2>/dev/null | wc -l | tr -d ' ')

  printf '=== firstmate status (read-only, no wake sent) ===\n'
  printf 'home     %s\n' "$FM_HOME"
  printf 'time     %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'inbox    %s note(s) waiting for firstmate\n' "$pending"

  if [ -f "$DATA/backlog.md" ]; then
    printf '\n--- in flight ---\n'
    awk '/^## In flight/{f=1;next} /^## /{f=0} f && /^- \[/{print}' \
      "$DATA/backlog.md" | sed 's/^- \[ \] /  /' | cut -c1-150
  else
    printf '\n(no backlog at %s)\n' "$DATA/backlog.md"
  fi

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
  say)    shift; cmd_say "$@" ;;
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
