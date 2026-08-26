#!/usr/bin/env bash
# fm-brief-product-lib.sh - the ONE owner of the v2 product blocks a brief carries.
#
# Usage:
#   . bin/fm-brief-product-lib.sh
#   fm_brief_v2_reset
#   fm_brief_v2_set --order O-0083            # or --no-order-reason '<why>'
#   fm_brief_v2_set --ziel '<sentence>|<repo>/<anchor>'
#   fm_brief_v2_set --abnahme 'A1::<criterion>::<evidence-kind>'   # repeatable
#   fm_brief_v2_set --no-go '<verbatim no-go line>'                # repeatable
#   FM_BRIEF_CAPTAIN_FLAECHE=1                # set by the --captain-flaeche flag
#   fm_brief_v2_require ship|scout            # 0 ok / 1 loud refusal
#   fm_brief_kopf_v2                          # the machine-readable header lines
#   fm_brief_v2_bloecke <geltung> [projekt]   # Abnahme + No-Gos + rules, in order
#
# WHY. A brief used to say what to build and never why it should exist. So a
# worker could not tell an ordered piece of work from an invented one, could not
# check its own result against anything but prose, and never saw the product
# no-gos that would have stopped it. These blocks make each of those three a
# line the brief carries and a machine can read: which captain order the work
# hangs from, which product goal it serves, what "done" will be measured
# against, and which lines must not be crossed.
#
# Text contract (this header owns the shape of every block below):
#
#   fm_brief_kopf_v2 - machine-readable header lines, one per line, in order:
#     Brief-Version: v2
#     Order-Bezug: O-0083            (or: Order-Bezug: keiner (<reason>))
#     Captain-Flaeche: ja            (only when FM_BRIEF_CAPTAIN_FLAECHE=1)
#     Dient Produktziel: <sentence> (<repo>/VISION.md#<anchor>)
#   The `Order-Bezug:` line mirrors the `Delivery contract:` mechanic: a fixed
#   prefix, one value, no prose around it, so a gate can read it back out of the
#   brief. `Captain-Flaeche: ja` is read verbatim by bin/fm-abnahme.sh, which
#   then requires at least one beleg=klickbeleg acceptance point.
#
#   fm_brief_abnahme_block - the acceptance block bin/fm-abnahme.sh parses. That
#   script's header is the single owner of the line format; this function only
#   renders into it:
#     ## Abnahme (maschinenlesbar)
#     - [A<n>] <criterion> :: beleg=<kind>
#   Input is one `--abnahme 'A<n>::<criterion>::<kind>'` per point; <kind> is the
#   closed set klickbeleg|testlauf|messung|diff|foto|sonstig. With no points the
#   block is omitted entirely rather than emitted empty: an empty block would
#   parse as a brief that demands nothing, while an absent one is what the
#   acceptance gate's --legacy path is for.
#
#   fm_brief_nogo_block - product no-gos, quoted verbatim:
#     ## No-Gos (woertlich aus der Produktgrundlage)
#     - <line>
#   The cap comes from regeln/VERFASSUNG.yaml (`nogo_zeilen_max_je_brief`) and is
#   enforced HARD: lines past the cap are dropped and the drop is announced on
#   stderr. Selecting which no-gos travel is the briefing party's judgement and
#   its fault - the cap exists so a brief cannot be turned into a rulebook, not
#   to grade the selection.
#
#   fm_brief_regeln_block - the rule block for harnesses with no hooks:
#     ## Regeln (eingebettet - der Brief ist der Handlungsort)
#     <output of `bin/fm-regeln brief --geltung <g> [--projekt <p>]
#      --kontext-datei <tmp>`>
#   FAIL-OPEN, deliberately: a missing or failing rule tool emits the single
#   comment line `<!-- regeln: nicht verfuegbar -->` and nothing else. A brief
#   that cannot be written at all because the retrieval index is cold is worse
#   than a brief whose rules arrive through the session hooks instead, and the
#   comment line makes the gap visible to anyone reading the brief later.
#
# Not a gate. This file has no state/.tor-*-scharf flag and blocks nothing: the
# mandatory-flag refusal lives in bin/fm-brief.sh and is an INPUT CONTRACT of
# that scaffold (like --mode), always on, never armed separately. What this file
# owns is the text; what fm-brief.sh owns is when a scaffold refuses to write.
#
# Bash 3.2 compatible on purpose (macOS stock bash runs the suite): array
# lengths are tracked in scalar counters and arrays are read by index, because
# `${#arr[@]}` and `"${arr[@]}"` on an EMPTY array abort under `set -u` there.

FM_BRIEF_ABNAHME_KINDS='klickbeleg testlauf messung diff foto sonstig'

fm_brief_product_root() { # -> the firstmate repo this library lives in
  if [ -n "${FM_ROOT_OVERRIDE:-}" ]; then
    printf '%s' "$FM_ROOT_OVERRIDE"
  else
    (cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
  fi
}

fm_brief_v2_reset() { # clear all parse state; safe to call more than once
  FM_BRIEF_ORDER=
  FM_BRIEF_NO_ORDER_REASON=
  FM_BRIEF_ZIEL_SATZ=
  FM_BRIEF_ZIEL_REPO=
  FM_BRIEF_ZIEL_ANKER=
  FM_BRIEF_CAPTAIN_FLAECHE=${FM_BRIEF_CAPTAIN_FLAECHE:-0}
  FM_BRIEF_ABNAHME=()
  FM_BRIEF_ABNAHME_N=0
  FM_BRIEF_NOGO=()
  FM_BRIEF_NOGO_N=0
}

# One flag, one value. Returns 1 after a loud, cited refusal so the caller can
# stop the scaffold; never accepts and silently discards a malformed value.
fm_brief_v2_set() { # <--flag> <value>
  local flag=$1 value=$2 rest kind
  case "$flag" in
    --order)
      [ -z "$FM_BRIEF_NO_ORDER_REASON" ] || {
        echo "error: --order and --no-order-reason are mutually exclusive; a brief either hangs from one captain order or names why it hangs from none" >&2
        return 1
      }
      if ! [[ $value =~ ^O-[0-9]+$ ]]; then
        echo "error: --order expects an order-book id of the form O-0083 (got '$value'); list the active set with bin/fm-order.sh list, or pass --no-order-reason '<why this work has no order>'" >&2
        return 1
      fi
      FM_BRIEF_ORDER=$value
      ;;
    --no-order-reason)
      [ -z "$FM_BRIEF_ORDER" ] || {
        echo "error: --order and --no-order-reason are mutually exclusive; a brief either hangs from one captain order or names why it hangs from none" >&2
        return 1
      }
      [ -n "$value" ] || {
        echo "error: --no-order-reason needs a reason; 'keiner ()' records nothing. Example: --no-order-reason 'housekeeping from the 2026-08-24 Tagesschluss strike list'" >&2
        return 1
      }
      FM_BRIEF_NO_ORDER_REASON=$value
      ;;
    --ziel)
      case "$value" in
        *'|'*) ;;
        *)
          echo "error: --ziel expects '<sentence>|<repo>/<anchor>' (got '$value'). Example: --ziel 'Scans reach a card without a detour|lensclash/scan-zu-karte'" >&2
          return 1 ;;
      esac
      FM_BRIEF_ZIEL_SATZ=${value%%|*}
      rest=${value#*|}
      case "$rest" in
        */*) ;;
        *)
          echo "error: --ziel's anchor half must be '<repo>/<anchor>' pointing into that repo's VISION.md (got '$rest'). Example: lensclash/scan-zu-karte" >&2
          return 1 ;;
      esac
      FM_BRIEF_ZIEL_REPO=${rest%%/*}
      FM_BRIEF_ZIEL_ANKER=${rest#*/}
      if [ -z "$FM_BRIEF_ZIEL_SATZ" ] || [ -z "$FM_BRIEF_ZIEL_REPO" ] || [ -z "$FM_BRIEF_ZIEL_ANKER" ]; then
        echo "error: --ziel needs all three parts: a sentence, a repo, and an anchor (got '$value')" >&2
        return 1
      fi
      ;;
    --abnahme)
      if ! [[ $value =~ ^A[0-9]+::.+::[a-z]+$ ]]; then
        echo "error: --abnahme expects 'A<n>::<criterion>::<evidence-kind>' (got '$value'); the line format is owned by bin/fm-abnahme.sh. Example: --abnahme 'A1::the gate refuses a brief with no order::testlauf'" >&2
        return 1
      fi
      kind=${value##*::}
      case " $FM_BRIEF_ABNAHME_KINDS " in
        *" $kind "*) ;;
        *)
          echo "error: --abnahme evidence kind must be one of $FM_BRIEF_ABNAHME_KINDS (got '$kind'); see the Art-Pruefung section of bin/fm-abnahme.sh" >&2
          return 1 ;;
      esac
      FM_BRIEF_ABNAHME[FM_BRIEF_ABNAHME_N]=$value
      FM_BRIEF_ABNAHME_N=$((FM_BRIEF_ABNAHME_N + 1))
      ;;
    --no-go)
      [ -n "$value" ] || {
        echo "error: --no-go needs the no-go line verbatim; an empty line quotes nothing" >&2
        return 1
      }
      FM_BRIEF_NOGO[FM_BRIEF_NOGO_N]=$value
      FM_BRIEF_NOGO_N=$((FM_BRIEF_NOGO_N + 1))
      ;;
    *)
      echo "error: fm_brief_v2_set does not know '$flag'" >&2
      return 1 ;;
  esac
  return 0
}

# The input contract of a ship scaffold: order reference and product goal are
# mandatory, acceptance points are strongly expected. Scout briefs pass through
# because a scout's deliverable is a report and its order may be the question
# itself. Returns 1 on a refusal; warnings go to stderr and still return 0.
fm_brief_v2_require() { # <ship|scout>
  local kind=$1 fehlt=0 i punkt
  if [ "$kind" = ship ]; then
    if [ -z "$FM_BRIEF_ORDER" ] && [ -z "$FM_BRIEF_NO_ORDER_REASON" ]; then
      echo "error: a ship brief must state its order reference: pass --order O-0083, or --no-order-reason '<why this work has no order>'." >&2
      echo "       Example: bin/fm-brief.sh $kind-task some-repo --mode local-only --order O-0083 --ziel 'Scans reach a card without a detour|lensclash/scan-zu-karte'" >&2
      fehlt=1
    fi
    if [ -z "$FM_BRIEF_ZIEL_SATZ" ]; then
      echo "error: a ship brief must name the product goal it serves: pass --ziel '<sentence>|<repo>/<anchor>'." >&2
      echo "       Example: --ziel 'Scans reach a card without a detour|lensclash/scan-zu-karte' renders as 'Dient Produktziel: ... (lensclash/VISION.md#scan-zu-karte)'" >&2
      fehlt=1
    fi
  fi
  [ "$fehlt" -eq 0 ] || return 1

  if [ "$kind" = ship ] && [ "$FM_BRIEF_ABNAHME_N" -eq 0 ]; then
    echo "warn: this ship brief carries no acceptance points; pass --abnahme 'A1::<criterion>::<evidence-kind>' (repeatable), or expect bin/fm-abnahme.sh to hold the result on its --legacy path" >&2
  fi
  if [ "${FM_BRIEF_CAPTAIN_FLAECHE:-0}" -eq 1 ] && [ "$FM_BRIEF_ABNAHME_N" -gt 0 ]; then
    i=0
    while [ "$i" -lt "$FM_BRIEF_ABNAHME_N" ]; do
      punkt=${FM_BRIEF_ABNAHME[$i]}
      [ "${punkt##*::}" = klickbeleg ] && return 0
      i=$((i + 1))
    done
    echo "warn: --captain-flaeche is set but no acceptance point uses beleg=klickbeleg; bin/fm-abnahme.sh will refuse the report until one does" >&2
  fi
  return 0
}

fm_brief_kopf_v2() { # -> the machine-readable header lines
  printf 'Brief-Version: v2\n'
  if [ -n "$FM_BRIEF_ORDER" ]; then
    printf 'Order-Bezug: %s\n' "$FM_BRIEF_ORDER"
  elif [ -n "$FM_BRIEF_NO_ORDER_REASON" ]; then
    printf 'Order-Bezug: keiner (%s)\n' "$FM_BRIEF_NO_ORDER_REASON"
  fi
  [ "${FM_BRIEF_CAPTAIN_FLAECHE:-0}" -eq 1 ] && printf 'Captain-Flaeche: ja\n'
  if [ -n "$FM_BRIEF_ZIEL_SATZ" ]; then
    printf 'Dient Produktziel: %s (%s/VISION.md#%s)\n' \
      "$FM_BRIEF_ZIEL_SATZ" "$FM_BRIEF_ZIEL_REPO" "$FM_BRIEF_ZIEL_ANKER"
  fi
  return 0
}

fm_brief_abnahme_block() { # -> the acceptance block, or nothing
  local i punkt nummer rest kriterium kind
  [ "$FM_BRIEF_ABNAHME_N" -gt 0 ] || return 0
  printf '## Abnahme (maschinenlesbar)\n'
  i=0
  while [ "$i" -lt "$FM_BRIEF_ABNAHME_N" ]; do
    punkt=${FM_BRIEF_ABNAHME[$i]}
    nummer=${punkt%%::*}
    rest=${punkt#*::}
    kriterium=${rest%::*}
    kind=${punkt##*::}
    printf -- '- [%s] %s :: beleg=%s\n' "$nummer" "$kriterium" "$kind"
    i=$((i + 1))
  done
  # shellcheck disable=SC2016  # literal brief text: the backticked A<n> line must reach the worker verbatim.
  printf 'Answer every point in data/<task-id>/report.md, one line each: `A<n>: erfuellt|nicht-erfuellt|unklar - <evidence path under data/<task-id>/belege/ or reason>`.\n'
  return 0
}

fm_brief_nogo_deckel() { # -> the per-brief no-go cap from regeln/VERFASSUNG.yaml
  local datei wert=
  datei="${FM_HOME:-$(fm_brief_product_root)}/regeln/VERFASSUNG.yaml"
  [ -f "$datei" ] || datei="$(fm_brief_product_root)/regeln/VERFASSUNG.yaml"
  if [ -f "$datei" ]; then
    wert=$(sed -n 's/^nogo_zeilen_max_je_brief:[[:space:]]*\([0-9][0-9]*\).*$/\1/p' "$datei" 2>/dev/null | head -n 1) || wert=
  fi
  if [ -z "$wert" ]; then
    echo "warn: no nogo_zeilen_max_je_brief in $datei; capping at the built-in 5" >&2
    wert=5
  fi
  printf '%s' "$wert"
  return 0
}

fm_brief_nogo_block() { # -> the verbatim no-go block, hard-capped
  local deckel i
  [ "$FM_BRIEF_NOGO_N" -gt 0 ] || return 0
  deckel=$(fm_brief_nogo_deckel)
  if [ "$FM_BRIEF_NOGO_N" -gt "$deckel" ]; then
    echo "warn: $FM_BRIEF_NOGO_N no-go lines exceed the cap of $deckel (regeln/VERFASSUNG.yaml, nogo_zeilen_max_je_brief); keeping the first $deckel, dropping $((FM_BRIEF_NOGO_N - deckel)). Choosing which no-gos travel is the briefing party's call." >&2
  else
    deckel=$FM_BRIEF_NOGO_N
  fi
  printf '## No-Gos (woertlich aus der Produktgrundlage)\n'
  i=0
  while [ "$i" -lt "$deckel" ]; do
    printf -- '- %s\n' "${FM_BRIEF_NOGO[$i]}"
    i=$((i + 1))
  done
  printf 'These lines are quoted, not summarised. Crossing one stops the work and is reported, never weighed against the task.\n'
  return 0
}

# The context the rule retrieval ranks against. The task text itself is still a
# {TASK} placeholder at scaffold time, so the goal sentence, the acceptance
# criteria, the no-gos, and the repo name are the whole signal there is.
fm_brief_v2_kontext() { # [repo]
  local repo=${1:-} i punkt rest
  [ -z "$repo" ] || printf '%s\n' "$repo"
  [ -z "$FM_BRIEF_ZIEL_SATZ" ] || printf '%s\n' "$FM_BRIEF_ZIEL_SATZ"
  i=0
  while [ "$i" -lt "$FM_BRIEF_ABNAHME_N" ]; do
    punkt=${FM_BRIEF_ABNAHME[$i]}
    rest=${punkt#*::}
    printf '%s\n' "${rest%::*}"
    i=$((i + 1))
  done
  i=0
  while [ "$i" -lt "$FM_BRIEF_NOGO_N" ]; do
    printf '%s\n' "${FM_BRIEF_NOGO[$i]}"
    i=$((i + 1))
  done
  return 0
}

fm_brief_regeln_block() { # <geltung> [projekt] -> embedded rules, fail-open
  local geltung=$1 projekt=${2:-} regeln kontext out rc=0
  printf '## Regeln (eingebettet - der Brief ist der Handlungsort)\n'
  regeln="$(fm_brief_product_root)/bin/fm-regeln"
  if [ ! -x "$regeln" ]; then
    printf '<!-- regeln: nicht verfuegbar -->\n'
    return 0
  fi
  kontext=$(mktemp "${TMPDIR:-/tmp}/fm-brief-kontext.XXXXXX") || {
    printf '<!-- regeln: nicht verfuegbar -->\n'
    return 0
  }
  fm_brief_v2_kontext "$projekt" > "$kontext" 2>/dev/null || true
  if [ -n "$projekt" ]; then
    out=$("$regeln" brief --geltung "$geltung" --projekt "$projekt" --kontext-datei "$kontext" 2>/dev/null) || rc=$?
  else
    out=$("$regeln" brief --geltung "$geltung" --kontext-datei "$kontext" 2>/dev/null) || rc=$?
  fi
  rm -f "$kontext"
  if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
    printf '<!-- regeln: nicht verfuegbar -->\n'
    return 0
  fi
  printf '%s\n' "$out"
  return 0
}

# Abnahme, No-Gos, and rules in that order, blank-line separated, with no
# leading or trailing blank line. Emits at least the rule block, so the return
# value is never an empty string the caller has to special-case.
fm_brief_v2_bloecke() { # <geltung> [projekt]
  local geltung=$1 projekt=${2:-} teil erste=1
  for teil in abnahme nogo; do
    local text
    case "$teil" in
      abnahme) text=$(fm_brief_abnahme_block) ;;
      nogo) text=$(fm_brief_nogo_block) ;;
    esac
    [ -n "$text" ] || continue
    [ "$erste" -eq 1 ] || printf '\n'
    printf '%s\n' "$text"
    erste=0
  done
  [ "$erste" -eq 1 ] || printf '\n'
  fm_brief_regeln_block "$geltung" "$projekt"
  return 0
}
