#!/usr/bin/env bash
# Resolution provenance shared by fm-send and fm-captain-hold.
# Call fm_resolution_source_validate <kind> <reference> <message-UTC-time>.
# Kinds are user, supervisor, or mechanical. A user source requires the
# answering message's UTC time (YYYY-MM-DDTHH:MM:SSZ), never the close time.
# References name the answering message, supervisor judgement, or owning
# operation and evidence respectively. These are caller declarations, not
# authentication or proof that a human authored an answer.
# Fields are single-line printable text, bounded so status closes can retain
# the entire provenance or refuse before delivery. Older stored records remain
# readable without migration; new writes must supply provenance.

fm_resolution_source_validate() {
  local kind=$1 reference=$2 at=$3
  case "$kind" in
    user|supervisor|mechanical) ;;
    *) echo 'error: --source-kind must be user, supervisor, or mechanical' >&2; return 1 ;;
  esac
  if [ -z "${reference//[[:space:]]/}" ] || [ "${#reference}" -gt 512 ] \
    || [ "$(printf '%s' "$reference" | LC_ALL=C tr -d '\000-\037\177[]')" != "$reference" ]; then
    echo 'error: --source requires a nonempty printable reference of at most 512 characters without brackets' >&2
    return 1
  fi
  if [ "$kind" = user ] && [ -z "$at" ]; then
    echo 'error: a user source requires --source-time with the answering message UTC time' >&2
    return 1
  fi
  if [ -n "$at" ] && { [ "${#at}" -ne 20 ] || ! printf '%s\n' "$at" \
    | LC_ALL=C grep -Eq '^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]Z$'; }; then
    echo 'error: --source-time must be UTC YYYY-MM-DDTHH:MM:SSZ' >&2
    return 1
  fi
}

fm_resolution_source_note() { # <kind> <reference> <message-UTC-time>
  printf '[source-kind=%s] [source=%s]' "$1" "$2"
  [ -z "$3" ] || printf ' [source-time=%s]' "$3"
}

fm_resolution_source_record() { # <kind> <reference> <message-UTC-time>
  printf 'Source kind: %s\nSource reference: %s\n' "$1" "$2"
  [ -z "$3" ] || printf 'Source message UTC: %s\n' "$3"
}
