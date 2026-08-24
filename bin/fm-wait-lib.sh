#!/usr/bin/env bash
# bin/fm-wait-lib.sh - the ONE owner of the declared-wait machine field
# (plan v3 U1.4: declared waiting is a machine field with reason and deadline,
# not a prose prefix).
#
# Record file: state/<id>.wait - exactly one line, atomically replaced by
# bin/fm-wait.sh (the only writer):
#
#   v1 until=<epoch> ts=<epoch> reason=<free text to end of line>
#
# `reason=` is deliberately last so the reason may contain spaces; `until` is
# the deadline and `ts` the declaration time. The field is authoritative for
# ALARM DAMPING: while it is active (now < until) the watcher's liveness probe
# raises no stillness or no-progress alarm for the task - even while a run or
# busy pane says the worker looks occupied, because the abolished precedence
# rule "surface or run-step busy-ness outranks the self-declaration" is exactly
# what this field replaces - and fm-crew-state.sh reports the declared wait as
# the current state. At the deadline the watcher checks the task exactly once
# per field identity (never once per poll), after which the field is inert
# until the worker refreshes or clears it. A malformed or unparseable field
# never silences anything: fm_wait_read rejects it and callers treat the task
# as undeclared, so a corrupt declaration fails toward inspection, not silence.
#
# Sourced only; no side effects on source.

fm_wait_path() {  # <state-dir> <id>
  printf '%s/%s.wait' "$1" "$2"
}

# fm_wait_read: parse <id>'s field. Returns 0 with the globals below set when
# a well-formed field exists, 1 when no field exists, 2 when a field exists
# but is malformed (treat exactly like 1 for damping - malformed never
# silences - but callers may name the corruption when surfacing).
#   FM_WAIT_STATE     active | expired
#   FM_WAIT_UNTIL     deadline epoch
#   FM_WAIT_TS        declaration epoch
#   FM_WAIT_REASON    the declared reason text
#   FM_WAIT_IDENTITY  "<ts>-<until>", the single-fire key for expiry checks
fm_wait_read() {  # <state-dir> <id>
  local f line rest until ts reason
  FM_WAIT_STATE='' FM_WAIT_UNTIL='' FM_WAIT_TS='' FM_WAIT_REASON='' FM_WAIT_IDENTITY=''
  f=$(fm_wait_path "$1" "$2")
  [ -f "$f" ] || return 1
  IFS= read -r line < "$f" || line=''
  case "$line" in
    'v1 until='*) ;;
    *) return 2 ;;
  esac
  rest=${line#v1 until=}
  until=${rest%% *}
  case "$until" in ''|*[!0-9]*) return 2 ;; esac
  rest=${rest#"$until"}
  rest=${rest# }
  case "$rest" in ts=*) ;; *) return 2 ;; esac
  rest=${rest#ts=}
  ts=${rest%% *}
  case "$ts" in ''|*[!0-9]*) return 2 ;; esac
  rest=${rest#"$ts"}
  rest=${rest# }
  case "$rest" in reason=?*) ;; *) return 2 ;; esac
  reason=${rest#reason=}
  # shellcheck disable=SC2034 # Output globals are consumed by sourcing callers.
  FM_WAIT_UNTIL=$until
  # shellcheck disable=SC2034 # Output globals are consumed by sourcing callers.
  FM_WAIT_TS=$ts
  # shellcheck disable=SC2034 # Output globals are consumed by sourcing callers.
  FM_WAIT_REASON=$reason
  # shellcheck disable=SC2034 # Output globals are consumed by sourcing callers.
  FM_WAIT_IDENTITY="$ts-$until"
  if [ "$(date +%s)" -lt "$until" ]; then
    FM_WAIT_STATE=active
  else
    # shellcheck disable=SC2034 # Output globals are consumed by sourcing callers.
    FM_WAIT_STATE=expired
  fi
  return 0
}

# fm_wait_write: atomically replace <id>'s field. The writer CLI validates
# inputs; this helper only owns the byte format and the atomic replace.
fm_wait_write() {  # <state-dir> <id> <until-epoch> <ts-epoch> <reason>
  local f=$1/$2.wait
  printf 'v1 until=%s ts=%s reason=%s\n' "$3" "$4" "$5" > "$f.tmp" \
    && mv -f "$f.tmp" "$f"
}

# fm_wait_clear_file: remove <id>'s field (idempotent).
fm_wait_clear_file() {  # <state-dir> <id>
  rm -f "$1/$2.wait"
}
