#!/usr/bin/env bash
# fm-redact-lib.sh - the ONE owner of turning registered secret VALUES into
# harmless [GEHEIM:<name>] markers before text leaves the machine (a log
# line, an agent message, a captain report). Sourced, never executed.
#
# Provides:
#   fm_redact         reads text on stdin, writes the same text to stdout
#                      with every registered secret value replaced by
#                      [GEHEIM:<name>]. Passthrough (byte-identical output)
#                      when state/secrets/ is absent or empty.
#   fm_redact_check    reads text on stdin, writes nothing; returns 0 if no
#                      registered value appears in it, returns 1 and names
#                      every value found (on stderr, never the value itself)
#                      otherwise. Passthrough (0, silent) when
#                      state/secrets/ is absent or empty.
#
# Secrets source: the exact same directory bin/fm-secret.sh owns
# ($FM_HOME/state/secrets/<name>, or $FM_STATE_OVERRIDE/secrets when that
# override is set) - this file computes that path with the identical
# FM_ROOT_OVERRIDE / FM_HOME / FM_STATE_OVERRIDE precedence fm-secret.sh
# uses, so the two scripts can never disagree about where a secret lives.
# Only regular files directly inside that directory count as registered
# secrets (fm-secret.sh's own dotfile temp files are skipped, matching how
# a plain shell glob already excludes dotfiles).
#
# Matching is exact-byte substring matching, never regex (a secret value
# containing '.', '*', '[' etc. is matched literally) - both functions use
# bash's quoted-pattern parameter/case expansion for this, so no external
# interpreter is spawned and a secret value never crosses into another
# process's argv or environment. When two registered values overlap (one is
# a substring of another), fm_redact replaces the LONGEST value first, so a
# shorter value's redaction can never leave a fragment of a longer one
# exposed in plain text.
#
# Everything here operates on text already in this shell's memory - nothing
# is ever written to /tmp or any other path.

FM_REDACT_LIB_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_REDACT_LIB_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$FM_REDACT_LIB_SCRIPT_DIR/.." && pwd)}"

fm_redact_secrets_dir() { # -> the secrets directory fm-secret.sh writes to
  local home="${FM_HOME:-$FM_REDACT_LIB_ROOT}"
  local state="${FM_STATE_OVERRIDE:-$home/state}"
  printf '%s/secrets' "$state"
}

# _fm_redact_load_secrets: populate the caller's _fm_redact_names/_fm_redact_vals
# arrays (must already be declared, e.g. `local a=() b=()`) from the secrets
# directory. Internal helper shared by fm_redact and fm_redact_check.
_fm_redact_load_secrets() {
  local dir f name val
  dir="$(fm_redact_secrets_dir)"
  [ -d "$dir" ] || return 0
  for f in "$dir"/*; do
    [ -f "$f" ] || continue
    name="$(basename "$f")"
    val="$(cat "$f")" || continue
    [ -n "$val" ] || continue
    _fm_redact_names+=("$name")
    _fm_redact_vals+=("$val")
  done
}

fm_redact() {
  local data
  data="$(cat; printf x)"; data="${data%x}"
  local _fm_redact_names=() _fm_redact_vals=()
  _fm_redact_load_secrets
  if [ "${#_fm_redact_vals[@]}" -gt 0 ]; then
    local order i idx len
    order="$(
      for ((i = 0; i < ${#_fm_redact_vals[@]}; i++)); do
        len="${#_fm_redact_vals[$i]}"
        printf '%s\t%s\n' "$len" "$i"
      done | sort -t "$(printf '\t')" -k1,1nr
    )"
    while IFS="$(printf '\t')" read -r _len idx; do
      [ -n "${idx:-}" ] || continue
      data="${data//"${_fm_redact_vals[$idx]}"/[GEHEIM:${_fm_redact_names[$idx]}]}"
    done <<< "$order"
  fi
  printf '%s' "$data"
}

fm_redact_check() {
  local data
  data="$(cat; printf x)"; data="${data%x}"
  local _fm_redact_names=() _fm_redact_vals=()
  _fm_redact_load_secrets
  local hits="" i
  for ((i = 0; i < ${#_fm_redact_vals[@]}; i++)); do
    case "$data" in
      *"${_fm_redact_vals[$i]}"*) hits="${hits:+$hits, }${_fm_redact_names[$i]}" ;;
    esac
  done
  if [ -n "$hits" ]; then
    printf 'fm_redact_check: unredacted secret value(s) present: %s\n' "$hits" >&2
    return 1
  fi
  return 0
}
