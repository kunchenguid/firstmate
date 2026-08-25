#!/usr/bin/env bash
# fm-order-gate-lib.sh - the ONE owner of the machine-readable half of a captain
# order: the `enforce:` line that turns recorded words into a gate a tool can ask.
#
# Usage:
#   . bin/fm-order-gate-lib.sh
#   fm_order_gate_check <gate> [key=value]...   0 free / 1 blocked / 2 loud error
#   fm_order_gate_validate_entry "<entry>"      0 valid / 2 loud error (write time)
#   fm_order_gate_deutung "<entry>"             one marked interpretation line
#
# WHY. An order's wording is the truth (L46: the wording travels unchanged), but
# no tool can read prose. So an order MAY carry, beside its verbatim wording, one
# or more `enforce:` header lines that state - in a closed vocabulary - which
# concrete action the order shuts. The wording stays the source; every rendering
# of an enforce line is an INTERPRETATION and is printed marked as such, next to
# the quote, never instead of it (L46, L50: a constraint without the captain's
# words behind it does not hold).
#
# Entry contract (this header is the single owner):
#
#   enforce: <gate> [allow] <key>=<value> [<key>=<value>...]
#
#   - repeatable header field in $FM_HOME/data/entscheide/*/order-*.md, written
#     before the first blank line (the order file's header block is owned by
#     bin/fm-order.sh; this file owns only the enforce field inside it).
#   - <gate>: spawn | plan-approval | merge | rollout | brief
#   - <key>:  account | project | task | klasse | path-prefix
#   - a DENY entry (no `allow`) blocks the gate on a FULL MATCH: every key=value
#     of the entry must be present in the call context with that value.
#   - an ALLOW entry lifts, on a full match, the denies OF ITS OWN ORDER; it says
#     nothing about any other order. Within one order allow wins; across orders a
#     surviving deny still blocks (the strictest captain word stands).
#   - value comparison is exact, with ONE exception: `path-prefix` matches when
#     the entry's value is a leading substring of the context's value.
#   - a key the call context does not mention can never match, so an entry only
#     ever blocks a call that actually names what the order talks about.
#   - an entry with no key=value pairs full-matches trivially and therefore shuts
#     the whole gate (`enforce: merge` = no merges at all).
#   - unknown gate, unknown key, or a token that is not key=value is a LOUD abort
#     (exit 2), at write time and at check time (L33, L64) - never a silent pass.
#
# Which orders count: only ACTIVE ones (status: active) whose `expires` date has
# not passed. A closed or expired order stops binding and its enforce lines stop
# with it - exactly as the order book's pin and recite treat it.
#
# Blocked output (stdout, one line per blocking order, exit 1):
#   O-xxxx<TAB><first line of that order's verbatim wording>
# The caller quotes that line in its refusal, so the agent reading the refusal
# sees the captain's own words and the id it can look up - never a paraphrase.
#
# Arming: this file is a LIBRARY and never blocks anything by itself; it answers
# a question. The gate script that calls it owns its state/.tor-<name>-scharf
# arming flag and owns the named exit it offers in its refusal.
#
# Every call writes one Tor-Log line via bin/fm-tor-log-lib.sh (gate name
# `order-gate`): rot with the blocking order id as the rule, gruen with `-`.
#
# A blocked check is a RETURN VALUE, not a failure: a caller under `set -e` must
# take the verdict in an `if`/`case` (`if fm_order_gate_check ...; then`), or its
# own shell dies on the very refusal it asked for.

# shellcheck source=bin/fm-tor-log-lib.sh
if [ -r "$(dirname "${BASH_SOURCE[0]}")/fm-tor-log-lib.sh" ]; then
  . "$(dirname "${BASH_SOURCE[0]}")/fm-tor-log-lib.sh"
else
  # TODO TOR-LOG-LIB: bin/fm-tor-log-lib.sh is missing - decisions still stand,
  # but they are not recorded. Remove this fallback once the lib is in place.
  fm_tor_log() { :; }
fi

FM_ORDER_GATE_GATES="spawn plan-approval merge rollout brief"
FM_ORDER_GATE_KEYS="account project task klasse path-prefix"

fm_order_gate_home() {
  if [ -n "${FM_HOME:-}" ]; then
    printf '%s' "$FM_HOME"
  else
    (cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
  fi
}

fm_order_gate_is_gate() { # <token>
  case " $FM_ORDER_GATE_GATES " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

fm_order_gate_is_key() { # <token>
  case " $FM_ORDER_GATE_KEYS " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

fm_order_gate_validate_entry() { # "<gate> [allow] k=v..." -> 0 valid, 2 loud
  local entry="${1:-}"
  local -a toks=()
  read -r -a toks <<< "$entry"
  if [ "${#toks[@]}" -eq 0 ]; then
    echo "error: an enforce entry needs at least a gate: '<gate> [allow] k=v...' (gates: $FM_ORDER_GATE_GATES)" >&2
    return 2
  fi
  if ! fm_order_gate_is_gate "${toks[0]}"; then
    echo "error: unknown enforce gate '${toks[0]}'; known gates: $FM_ORDER_GATE_GATES" >&2
    return 2
  fi
  local i=1
  [ "${toks[1]:-}" = "allow" ] && i=2
  local pair k
  while [ "$i" -lt "${#toks[@]}" ]; do
    pair="${toks[$i]}"
    case "$pair" in
      *=*) ;;
      *) echo "error: enforce token '$pair' is not key=value (keys: $FM_ORDER_GATE_KEYS)" >&2; return 2 ;;
    esac
    k="${pair%%=*}"
    if ! fm_order_gate_is_key "$k"; then
      echo "error: unknown enforce key '$k'; known keys: $FM_ORDER_GATE_KEYS" >&2
      return 2
    fi
    if [ -z "${pair#*=}" ]; then
      echo "error: enforce key '$k' carries an empty value; name what is meant" >&2
      return 2
    fi
    i=$((i + 1))
  done
  return 0
}

fm_order_gate_deutung() { # "<entry>" -> one marked interpretation line
  local entry="${1:-}"
  local -a toks=()
  read -r -a toks <<< "$entry"
  [ "${#toks[@]}" -gt 0 ] || return 0
  local gate="${toks[0]}" mode="blocked" i=1
  if [ "${toks[1]:-}" = "allow" ]; then mode="expressly allowed"; i=2; fi
  local pairs=""
  while [ "$i" -lt "${#toks[@]}" ]; do
    pairs="${pairs:+$pairs, }${toks[$i]}"
    i=$((i + 1))
  done
  printf '[interpretation] %s with %s is %s by this order\n' \
    "$gate" "${pairs:-any context}" "$mode"
}

fm_order_gate_entry_matches() { # <ctx-array-name> "<entry>" <want-allow:yes|no>
  local -n _fm_ctx="$1"                     # 0 = full match, 1 = no match, 2 = loud
  local entry="$2" want_allow="$3"
  local -a toks=()
  read -r -a toks <<< "$entry"
  [ "${#toks[@]}" -gt 0 ] || return 2
  local i=1 is_allow="no"
  if [ "${toks[1]:-}" = "allow" ]; then is_allow="yes"; i=2; fi
  [ "$is_allow" = "$want_allow" ] || return 1
  local pair k v have
  while [ "$i" -lt "${#toks[@]}" ]; do
    pair="${toks[$i]}"
    k="${pair%%=*}"
    v="${pair#*=}"
    have="${_fm_ctx[$k]-}"
    if [ -z "${_fm_ctx[$k]+set}" ]; then return 1; fi
    if [ "$k" = "path-prefix" ]; then
      case "$have" in "$v"*) ;; *) return 1 ;; esac
    else
      [ "$have" = "$v" ] || return 1
    fi
    i=$((i + 1))
  done
  return 0
}

fm_order_gate_enforce_lines() { # <order file> -> its enforce entries, one per line
  awk '/^$/{exit} index($0, "enforce: ")==1 {print substr($0, 10)}' "$1"
}

fm_order_gate_check() { # <gate> [key=value]... -> 0 free, 1 blocked, 2 loud
  local gate="${1:-}"
  if [ "$#" -lt 1 ]; then
    echo "error: fm_order_gate_check needs a gate: $FM_ORDER_GATE_GATES" >&2
    return 2
  fi
  shift
  if ! fm_order_gate_is_gate "$gate"; then
    echo "error: unknown gate '$gate'; known gates: $FM_ORDER_GATE_GATES" >&2
    return 2
  fi
  # shellcheck disable=SC2034 # read through the nameref in fm_order_gate_entry_matches
  local -A ctx=()
  local pair k
  for pair in "$@"; do
    case "$pair" in
      *=*) ;;
      *) echo "error: context '$pair' is not key=value (keys: $FM_ORDER_GATE_KEYS)" >&2; return 2 ;;
    esac
    k="${pair%%=*}"
    if ! fm_order_gate_is_key "$k"; then
      echo "error: unknown context key '$k'; known keys: $FM_ORDER_GATE_KEYS" >&2
      return 2
    fi
    # shellcheck disable=SC2034 # read through the nameref in fm_order_gate_entry_matches
    ctx["$k"]="${pair#*=}"
  done
  local ctx_text="gate=$gate ${*:-(no context)}"

  local orders_dir blocked="" f status expires today id entry
  orders_dir="$(fm_order_gate_home)/data/entscheide"
  today="$(date -u +%F)"
  if [ -d "$orders_dir" ]; then
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      status="$(awk '/^$/{exit} index($0,"status: ")==1 {print substr($0,9); exit}' "$f")"
      [ "$status" = "active" ] || continue
      expires="$(awk '/^$/{exit} index($0,"expires: ")==1 {print substr($0,10); exit}' "$f")"
      if [ -n "$expires" ] && [ "$expires" != "-" ] && [[ "$expires" < "$today" ]]; then continue; fi
      local hit="no" lifted="no"
      while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        if ! fm_order_gate_validate_entry "$entry" >/dev/null 2>&1; then
          echo "error: order file $f carries an unreadable enforce entry: '$entry'" >&2
          echo "       fix the order (bin/fm-order.sh show) - a gate never guesses what the captain meant" >&2
          return 2
        fi
        [ "${entry%% *}" = "$gate" ] || continue
        if fm_order_gate_entry_matches ctx "$entry" no; then hit="yes"; fi
        if fm_order_gate_entry_matches ctx "$entry" yes; then lifted="yes"; fi
      done < <(fm_order_gate_enforce_lines "$f")
      if [ "$hit" = "yes" ] && [ "$lifted" = "no" ]; then
        id="$(awk '/^$/{exit} index($0,"id: ")==1 {print substr($0,5); exit}' "$f")"
        blocked+="$id"$'\t'"$(awk '/^## wording/{s=1; next} s && NF {print; exit}' "$f")"$'\n'
      fi
    done < <(find "$orders_dir" -mindepth 2 -maxdepth 2 -name 'order-O-*.md' 2>/dev/null | sort)
  fi

  if [ -n "$blocked" ]; then
    printf '%s' "$blocked"
    while IFS=$'\t' read -r id _; do
      [ -n "$id" ] || continue
      fm_tor_log order-gate "$id" rot - "$ctx_text"
    done <<< "${blocked%$'\n'}"
    return 1
  fi
  fm_tor_log order-gate - gruen - "$ctx_text"
  return 0
}
