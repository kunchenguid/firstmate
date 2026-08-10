#!/usr/bin/env bash
# The one owner of the `fm-status-event.v1` status-event envelope: the typed
# shape a worker writes onto its append-only status log, and the only parser for
# it.
#
# The envelope replaces free prose as the CONTROL fact on the worker-to-supervisor
# boundary. It carries exactly what a worker genuinely knows about its own work:
#
#   fm-status-event.v1 verb=<verb> [key=<slug>] [phase=<slug>] [evidence=<ref>]... summary=<one line>
#
#   verb      REQUIRED. The status verb, the same vocabulary the prose form used
#             (working, needs-decision, blocked, paused, done, failed, resolved,
#             captain-held). bin/fm-classify-lib.sh owns what each verb MEANS;
#             this library only recovers the field.
#   key       OPTIONAL slug, default `default`. The durable decision/phase key,
#             the typed form of the prose `[key=<slug>]` token.
#   phase     OPTIONAL slug. The worker's own current work phase.
#   evidence  OPTIONAL, REPEATABLE. One whitespace-free reference per field - a
#             path, a URL, an id. A reference POINTS AT an artifact and never
#             inlines it, which is what keeps one event one bounded line.
#   summary   REQUIRED and LAST, consuming the rest of the line. The one bounded
#             human note. It is a note for a reader, never a control fact: no
#             consumer may classify on its prose.
#
# The field set above is CLOSED, and that is the enforcement point for this
# increment's central law: `blocking_on` is DERIVED by bin/fm-classify-lib.sh
# from verb + key + the crew state, never declared by the worker. A worker that
# writes `blocking_on=` (or any other field this library does not name) does not
# get its value quietly stripped and the rest believed - the whole event is
# REFUSED as invalid, reported with a named reason, and surfaced to a supervisor
# as malformed. A silently-overridden field would leave the worker believing it
# had reported something; a refusal cannot.
#
# Refusal is fail-closed everywhere: an invalid envelope classifies as
# FM_STATUS_EVENT_INVALID_VERB, which no policy arm recognizes, so it can never
# be absorbed, never close a decision, and never derive a state.
#
# PURE. Every function is a side-effect-free read of a string, so the strictly
# read-only consumers (bin/fm-crew-state.sh through bin/fm-classify-lib.sh) and
# the wake path (bin/fm-wake-lib.sh) can both source it. It must stay that way:
# it is deliberately NOT the library that observes or creates a home.

# The schema token. It is the first token of every typed line, which is what
# separates a typed event from a prose line without ambiguity: a prose line
# cannot begin with it, because a prose verb ends at the first colon.
FM_STATUS_EVENT_SCHEMA='fm-status-event.v1'

# The COMPLETE set of fields a worker may write. Adding one here is the only way
# to make it writable, so a derived field stays unwritable-by-the-worker by
# construction rather than by a reviewer noticing.
# shellcheck disable=SC2034 # Read by the schema conformance gate in tests/fm-watch-triage.test.sh, not by this file.
FM_STATUS_EVENT_FIELDS='verb key phase evidence summary'

# The verb reported for an envelope that failed validation. Deliberately not a
# member of any verb vocabulary: every policy arm in bin/fm-classify-lib.sh and
# every state mapping in bin/fm-crew-state.sh falls through to its unrecognized
# branch, and those branches all surface rather than absorb.
FM_STATUS_EVENT_INVALID_VERB='invalid-status-event'

# The default decision key, matching the prose form's bare-line behavior.
FM_STATUS_EVENT_DEFAULT_KEY='default'

_FM_STATUS_EVENT_TAB=$'\t'
_FM_STATUS_EVENT_NL=$'\n'

# 0 if <line> is a typed event line, whatever its validity. Leading whitespace is
# tolerated so a hand-written append with an accidental indent is still parsed as
# the typed event it plainly is, rather than silently read as prose.
fm_status_event_is_typed() {  # <line>
  local line=${1-}
  line=${line#"${line%%[![:space:]]*}"}
  case "$line" in
    "$FM_STATUS_EVENT_SCHEMA") return 0 ;;
    "$FM_STATUS_EVENT_SCHEMA"[[:space:]]*) return 0 ;;
  esac
  return 1
}

# 0 if <value> is a slug: the constrained identifier shape the typed token
# fields accept. Empty is not a slug, so a present-but-empty field is refused
# rather than read as a default.
_fm_status_event_is_slug() {  # <value>
  case "${1-}" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# Parse <line> into the FM_STATUS_EVENT_* variables.
#   0 - a valid typed event; VERB/KEY/PHASE/EVIDENCE/SUMMARY are set
#   1 - a typed event that failed validation; INVALID_REASON names why
#   2 - not a typed event at all (a prose line); callers fall back to prose
# EVIDENCE holds one reference per line, in written order, empty when none.
# Callers read the fields through the accessors below rather than touching the
# variables, so this stays the only place the shape is known.
fm_status_event_parse() {  # <line>
  local line=${1-} rest tok name value
  local seen_verb=0 seen_key=0 seen_phase=0 seen_summary=0
  FM_STATUS_EVENT_VERB=''
  FM_STATUS_EVENT_KEY=$FM_STATUS_EVENT_DEFAULT_KEY
  FM_STATUS_EVENT_PHASE=''
  FM_STATUS_EVENT_EVIDENCE=''
  FM_STATUS_EVENT_SUMMARY=''
  FM_STATUS_EVENT_INVALID_REASON=''
  fm_status_event_is_typed "$line" || return 2
  # A TAB is the record separator of the open-decision fold this event feeds
  # (status_open_decisions emits "<key>\t<verb>\t<note>"), so a TAB inside an
  # event would split one record into two. Prose inherited that hazard; the
  # typed form refuses it instead of carrying it forward.
  case "$line" in
    *"$_FM_STATUS_EVENT_TAB"*)
      FM_STATUS_EVENT_INVALID_REASON='tab-in-event'
      return 1
      ;;
  esac
  line=${line#"${line%%[![:space:]]*}"}
  rest=${line#"$FM_STATUS_EVENT_SCHEMA"}
  while :; do
    rest=${rest#"${rest%%[![:space:]]*}"}
    [ -n "$rest" ] || break
    # summary is terminal: everything after it is the human note, so a token
    # shaped like a field inside the note can never be read as one. That is what
    # keeps the note prose and only prose - including a `blocking_on=...` a
    # worker writes into its own sentence.
    case "$rest" in
      summary=*)
        seen_summary=1
        FM_STATUS_EVENT_SUMMARY=${rest#summary=}
        break
        ;;
    esac
    tok=${rest%%[[:space:]]*}
    rest=${rest#"$tok"}
    case "$tok" in
      *=*) ;;
      *)
        FM_STATUS_EVENT_INVALID_REASON="not-a-field:$tok"
        return 1
        ;;
    esac
    name=${tok%%=*}
    value=${tok#*=}
    case "$name" in
      verb)
        [ "$seen_verb" -eq 0 ] || { FM_STATUS_EVENT_INVALID_REASON='duplicate-field:verb'; return 1; }
        seen_verb=1
        FM_STATUS_EVENT_VERB=$value
        ;;
      key)
        [ "$seen_key" -eq 0 ] || { FM_STATUS_EVENT_INVALID_REASON='duplicate-field:key'; return 1; }
        seen_key=1
        FM_STATUS_EVENT_KEY=$value
        ;;
      phase)
        [ "$seen_phase" -eq 0 ] || { FM_STATUS_EVENT_INVALID_REASON='duplicate-field:phase'; return 1; }
        seen_phase=1
        FM_STATUS_EVENT_PHASE=$value
        ;;
      evidence)
        [ -n "$value" ] || { FM_STATUS_EVENT_INVALID_REASON='empty-field:evidence'; return 1; }
        FM_STATUS_EVENT_EVIDENCE=${FM_STATUS_EVENT_EVIDENCE}${FM_STATUS_EVENT_EVIDENCE:+$_FM_STATUS_EVENT_NL}$value
        ;;
      blocking_on)
        # Named ahead of the generic arm so the certified case reports the
        # reason that explains itself rather than "unknown field".
        FM_STATUS_EVENT_INVALID_REASON='derived-field:blocking_on'
        return 1
        ;;
      *)
        FM_STATUS_EVENT_INVALID_REASON="unknown-field:$name"
        return 1
        ;;
    esac
  done
  [ "$seen_verb" -eq 1 ] || { FM_STATUS_EVENT_INVALID_REASON='missing-field:verb'; return 1; }
  _fm_status_event_is_slug "$FM_STATUS_EVENT_VERB" \
    || { FM_STATUS_EVENT_INVALID_REASON='malformed-field:verb'; return 1; }
  _fm_status_event_is_slug "$FM_STATUS_EVENT_KEY" \
    || { FM_STATUS_EVENT_INVALID_REASON='malformed-field:key'; return 1; }
  if [ "$seen_phase" -eq 1 ] && ! _fm_status_event_is_slug "$FM_STATUS_EVENT_PHASE"; then
    FM_STATUS_EVENT_INVALID_REASON='malformed-field:phase'
    return 1
  fi
  [ "$seen_summary" -eq 1 ] || { FM_STATUS_EVENT_INVALID_REASON='missing-field:summary'; return 1; }
  FM_STATUS_EVENT_SUMMARY=${FM_STATUS_EVENT_SUMMARY%"${FM_STATUS_EVENT_SUMMARY##*[![:space:]]}"}
  [ -n "$FM_STATUS_EVENT_SUMMARY" ] || { FM_STATUS_EVENT_INVALID_REASON='empty-field:summary'; return 1; }
  return 0
}

# Print one field of <line>: verb, key, phase, evidence (one reference per line),
# or summary. Prints nothing and returns 1 when the line is prose or invalid, so
# no caller can read a field out of an event that was refused.
fm_status_event_field() {  # <line> <field>
  fm_status_event_parse "${1-}" || return 1
  case "${2-}" in
    verb)     printf '%s' "$FM_STATUS_EVENT_VERB" ;;
    key)      printf '%s' "$FM_STATUS_EVENT_KEY" ;;
    phase)    printf '%s' "$FM_STATUS_EVENT_PHASE" ;;
    evidence) printf '%s' "$FM_STATUS_EVENT_EVIDENCE" ;;
    summary)  printf '%s' "$FM_STATUS_EVENT_SUMMARY" ;;
    *)        return 1 ;;
  esac
  return 0
}

# Print why <line> was refused, or nothing when it is a valid event or prose.
# The reason is a stable token, so a consumer reports the refusal without
# restating this library's rules.
fm_status_event_invalid_reason() {  # <line>
  local rc=0
  fm_status_event_parse "${1-}" || rc=$?
  [ "$rc" -eq 1 ] || return 0
  printf '%s' "$FM_STATUS_EVENT_INVALID_REASON"
}

# Render <line> as its canonical prose projection, "<verb>[ [key=<k>]]: <summary>".
# This is the ONE bridge from the typed form back to the prose shape, used where
# a bounded human-facing line or a home's own FM_CAPTAIN_RE regex needs one. A
# refused event projects to its reserved verb and its reason, so a malformed
# event still reads as an event and still cannot be mistaken for a valid one.
# A prose line is returned unchanged: the projection of prose is itself.
fm_status_event_prose() {  # <line>
  local rc=0 key=''
  fm_status_event_parse "${1-}" || rc=$?
  case "$rc" in
    2) printf '%s' "${1-}"; return 0 ;;
    1)
      printf '%s: %s (%s)' "$FM_STATUS_EVENT_INVALID_VERB" \
        "$FM_STATUS_EVENT_INVALID_REASON" "$FM_STATUS_EVENT_SCHEMA"
      return 0
      ;;
  esac
  [ "$FM_STATUS_EVENT_KEY" = "$FM_STATUS_EVENT_DEFAULT_KEY" ] \
    || key=" [key=$FM_STATUS_EVENT_KEY]"
  printf '%s%s: %s' "$FM_STATUS_EVENT_VERB" "$key" "$FM_STATUS_EVENT_SUMMARY"
}
