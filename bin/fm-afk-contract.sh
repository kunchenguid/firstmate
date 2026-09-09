#!/usr/bin/env bash
# fm-afk-contract.sh - the one owner of the away-posture record: its schema, the
# mandate-clause fields and their structural check, refusal naming the missing
# part, the read-back rendering, the entry announcement, and the archive at return.
#
# POSTURE. Away mode is a posture of the one supervision session, recorded in
# state/.afk-contract and never inferred from chat. While the record exists the
# home is afk; the captain's first unmarked message archives it (the return path
# in bin/fm-afk-return.sh calls `archive` through bin/fm-afk-launch.sh stop).
# Being away changes how the captain is informed and what happens at a
# captain-owned decision point, never the authority set. Hold-for-return is the
# only reach profile this release records: there is no phone channel, and the
# entry announcement says so every time.
#
# RECORD (state/.afk-contract; written only by this script; YAML-shaped so a
# human can read it, but parsed only here - consumers use the read subcommands):
#   version: 1
#   entered: <UTC ISO 8601>
#   entered_epoch: <seconds>
#   expected_return: <UTC ISO 8601> | -
#   reach_channels: none
#   reach_announced: <the one-sentence reach announcement>
#   spend_max_concurrent_workers: <n>
#   confirmed: <UTC ISO 8601>
#   confirmed_epoch: <seconds>
#   words: | or |-                 the captain's words, verbatim, never edited,
#     <line>                       one record line per input line (or `words: -`
#     ...                          when /afk carried no words); `|` retains a
#                                  final newline and `|-` records its absence
#   clauses:                       accepted clauses, recorded from the fields given
#     - id: <input ordinal>
#       action: <verb>
#       object: e:<reversible escaped text>
#       when: e:<reversible escaped precondition>
#       stop: e:<reversible escaped text> | -
#       flag: <never-set concept the best-effort scan matched> | -
#   refused:                       clauses missing a part, with the part named
#     - id: <input ordinal>
#       text: e:<the fields as given, reversibly escaped>
#       missing: <part - reason>
# A proposal (state/.afk-contract.proposed) has the same shape without the
# confirmed fields; confirmation stamps the first entry time. Archived final
# records live under state/afk-contracts/ as <entered_epoch>.afk-contract, and
# replaced mandates use <entered_epoch>-superseded-<confirmed_epoch>.afk-contract.
# A replacement carries the original session entry forward as the phase-1
# fail-safe. Durable archive-chain identity and same-second session identity are
# deferred to phase 4 (fm-afk-clauses-execute-r1).
#
# CLAUSE FIELDS. A clause is given as explicit fields, one clause per --action:
#   --action <verb> --object <text> --when <text> [--stop <text>]
#   action  one of: merge land prerelease install rerun dispatch abort-run answer
#           discard wake-me. A new verb is a code change here, never a prompt change.
#   object  the thing the clause acts on, in the captain's words, verbatim.
#   when    the stated precondition, in the captain's words, verbatim.
#   stop    optional: what ends the clause early, verbatim.
# NO STATIC NATURAL-LANGUAGE PARSER EXISTS HERE, BY THE CAPTAIN'S MANDATE. The
# object and precondition text are recorded exactly as given and are never
# tokenized, classified, or semantically validated by this script; whether a
# precondition holds is the supervision session's judgment at execution time
# in a later phase. The structural check asserts only that the action, object,
# and precondition fields are present, and that the action is a listed verb.
# THE NEVER-SET SCAN is only a coarse best-effort structural FLAG, never a
# refusal and never the authoritative gate: a clause whose fields mention a
# listed never-set concept is still recorded, with `flag:` naming the concept
# so the read-back and the return brief show it. The scan matches a listed term
# exactly or with a plain inflection (s, es, d, ed, ing, er, ers) at
# punctuation-delimited token boundaries, so an unrelated name such as
# ping-service or tokenize-worker is never flagged, and it can miss spellings,
# with joined compounds such as oneTimeCode a known limitation. Authoritative
# never-set and forbidden-action enforcement is the supervision session's
# judgment at execution time in phase 4.
# A clause missing a required field is refused with that field named, recorded
# under refused:, read back beside the accepted list, and never executes. Ids
# are the input ordinals across accepted and refused clauses.
# THIS RELEASE RECORDS CLAUSES AND DOES NOT EXECUTE THEM: the guarded gates learn
# to cite a clause in a later phase, and the announcement and return brief both
# say so, so a recorded clause is never mistaken for a promise.
# HARD RULE: forbidden, destructive, irreversible, and security-sensitive actions
# are never pre-authorizable regardless of clause text, and no recorded clause is
# authority by itself.
#
# Usage:
#   fm-afk-contract.sh propose [--words-file <path> | --words <text>]
#       [--action <verb> --object <text> --when <text> [--stop <text>]]...
#       [--expected-return <UTC ISO 8601>] [--spend <n>]
#     Compile and write the proposal, then print the read-back. Exit 0 with every
#     clause accepted, 3 when at least one clause was refused (the read-back names
#     the missing part), and 2 on a usage error. --words-file keeps the file's
#     bytes verbatim, trailing newlines included. A refused clause remains in the
#     proposal so the captain can restate it before saying go.
#   fm-afk-contract.sh confirm
#     Promote the proposal into the record with the confirmed timestamp and
#     print the entry announcement. A proposal is required when no confirmed
#     record exists; an existing record with no proposal is a no-op refresh.
#     A replacement is staged before the prior record is archived and replaced.
#   fm-afk-contract.sh readback [--proposal]
#   fm-afk-contract.sh field <name> [--proposal]
#   fm-afk-contract.sh words [--proposal | --path <record>]
#   fm-afk-contract.sh clauses [--proposal | --path <record>]   TSV: id action object when stop
#   fm-afk-contract.sh flags [--proposal | --path <record>]     TSV: id concept (flagged clauses only)
#   fm-afk-contract.sh validate [--proposal | --path <record>]  exit 0 when the record is readable and, for a record, confirmed
#     Backslashes and control whitespace in TSV fields use reversible escapes
#     (`\\`, `\t`, `\r`, and `\n`) so every record remains one row per clause;
#     a literal `-` is `\x2d` to distinguish it from the empty-stop marker.
#   fm-afk-contract.sh refused [--proposal | --path <record>]   TSV: id text missing
#   fm-afk-contract.sh archive              move the record aside; print its path
#   fm-afk-contract.sh archived <entered_epoch>   print that archived record's path
#
# Sourceable: with the BASH_SOURCE guard, other scripts get the path and
# presence helpers (fm_afk_contract_path, fm_afk_contract_present,
# fm_afk_contract_proposal_path, fm_afk_contract_archive_dir) without running main.
set -u

FM_AFK_CONTRACT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$FM_AFK_CONTRACT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
FM_AFK_CONTRACT_STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-classify-lib.sh
. "$FM_AFK_CONTRACT_DIR/fm-classify-lib.sh"

FM_AFK_CONTRACT_VERSION=1
FM_AFK_CONTRACT_VERBS="merge land prerelease install rerun dispatch abort-run answer discard wake-me"
FM_AFK_CONTRACT_REACH_ANNOUNCED='No phone channel is configured; anything that needs you waits for your return.'
FM_AFK_CONTRACT_SPEND_DEFAULT=4

fm_afk_contract_path() {  # [state-dir]
  printf '%s/.afk-contract' "${1:-$FM_AFK_CONTRACT_STATE}"
}

fm_afk_contract_proposal_path() {  # [state-dir]
  printf '%s/.afk-contract.proposed' "${1:-$FM_AFK_CONTRACT_STATE}"
}

fm_afk_contract_archive_dir() {  # [state-dir]
  printf '%s/afk-contracts' "${1:-$FM_AFK_CONTRACT_STATE}"
}

fm_afk_contract_present() {  # [state-dir]
  [ -f "$(fm_afk_contract_path "${1:-$FM_AFK_CONTRACT_STATE}")" ]
}

fm_afk_contract_log() { printf 'fm-afk-contract: %s\n' "$*" >&2; }

fm_afk_contract_usage() {
  sed -n '/^# Usage:/,/^# Sourceable:/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
}

fm_afk_contract_now_iso() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

fm_afk_contract_lower() {  # <text>
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

fm_afk_contract_action() {  # <text>
  fm_afk_contract_lower "$1" | tr '\t\r\n' '   ' | sed 's/^ *//; s/ *$//; s/  */ /g'
}

fm_afk_contract_blank() {  # <text>
  [ -z "$(printf '%s' "$1" | tr -d '[:space:]')" ]
}

fm_afk_contract_escape() {  # <text>
  local value=$1
  value=${value//\\/\\\\}
  value=${value//$'\t'/\\t}
  value=${value//$'\r'/\\r}
  value=${value//$'\n'/\\n}
  [ "$value" != - ] || value='\x2d'
  printf '%s' "$value"
}

fm_afk_contract_unescape() {  # <escaped-text>
  printf '%b' "$1"
}

# --- clause structural check and never-set scan ------------------------------

# fm_afk_contract_never_set_hit <text...>: prints the protected concept the
# text mentions, or nothing. This coarse best-effort structural flag lowercases
# and splits punctuation before checking fixed token stems. It is not authoritative,
# can miss joined compounds such as oneTimeCode, and does not understand language;
# phase-4 supervision judgment owns never-set and forbidden-action enforcement.
fm_afk_contract_never_set_hit() {  # <text...>
  local normalized concept matched i j
  local -a tokens stems concepts=(
    credential password passcode login signin otp totp hotp 2fa mfa token secret
    passphrase apikey legal financial payment invoice pin
    'log in' 'sign in' 'attended prompt' 'one time code' 'one time password'
    'one time passcode' 'verification code' 'security code' 'auth code'
    'authentication code' 'recovery code' 'backup code' 'api key' 'access token'
    'secret key' 'private key'
  )
  normalized=$(printf '%s ' "$@" | tr '[:upper:]' '[:lower:]' | sed 's/[^[:alnum:]]/ /g; s/  */ /g')
  read -r -a tokens <<< "$normalized"
  for concept in "${concepts[@]}"; do
    read -r -a stems <<< "$concept"
    for ((i = 0; i + ${#stems[@]} <= ${#tokens[@]}; i++)); do
      matched=1
      for ((j = 0; j < ${#stems[@]}; j++)); do
        case "${tokens[$((i + j))]}" in
          "${stems[$j]}"|"${stems[$j]}s"|"${stems[$j]}es"|"${stems[$j]}d"|"${stems[$j]}ed"|"${stems[$j]}ing"|"${stems[$j]}er"|"${stems[$j]}ers") ;;
          *) matched=0; break ;;
        esac
      done
      if [ "$matched" -eq 1 ]; then
        printf '%s' "$concept"
        return 0
      fi
    done
  done
  return 1
}

# Check one clause's fields. Sets C_ACTION C_OBJECT C_WHEN C_STOP; on refusal
# C_MISSING names the missing field and the reason. The fields are never parsed:
# presence, the listed verb, and the coarse best-effort flag are the whole check.
fm_afk_contract_clause_check() {  # <action> <object> <when> <stop> <stop-given 0|1>
  C_ACTION=$(fm_afk_contract_action "$1")
  C_OBJECT=$2
  C_WHEN=$3
  C_STOP=$4
  C_MISSING=
  C_FLAG=$(fm_afk_contract_never_set_hit "$C_ACTION" "$C_OBJECT" "$C_WHEN" "$C_STOP") || C_FLAG=
  if [ -z "$C_ACTION" ]; then
    C_MISSING='action - the clause names no action'
    return 1
  fi
  case " $FM_AFK_CONTRACT_VERBS " in
    *" $C_ACTION "*) ;;
    *)
      C_MISSING="action - '$C_ACTION' is not a mandate verb (one of: ${FM_AFK_CONTRACT_VERBS// /, })"
      return 1 ;;
  esac
  if fm_afk_contract_blank "$C_OBJECT"; then
    C_MISSING='object - the clause names no thing to act on'
    return 1
  fi
  if fm_afk_contract_blank "$C_WHEN"; then
    C_MISSING='when - the clause states no precondition'
    return 1
  fi
  if [ "$5" -eq 1 ] && fm_afk_contract_blank "$C_STOP"; then
    C_MISSING='stop - --stop was given with no text'
    return 1
  fi
  return 0
}

# The refused list keeps the fields exactly as given, so the captain sees what
# was refused; an absent field reads as "(none)".
fm_afk_contract_clause_as_given() {  # <action> <object> <when> <stop> <stop-given 0|1>
  local text
  text="action=${1:-(none)} object=${2:-(none)} when=${3:-(none)}"
  [ "$5" -eq 0 ] || text="$text stop=${4:-(none)}"
  printf '%s' "$text"
}

# --- record writing ---------------------------------------------------------

fm_afk_contract_validate_iso() {  # <ts>
  fm_utc_iso_to_epoch "$1" >/dev/null 2>&1
}

# Compile every input into a record body on stdout (everything except the
# confirmed fields). Inputs: WORDS (verbatim), the parallel clause field arrays
# CLAUSE_ACTIONS CLAUSE_OBJECTS CLAUSE_WHENS CLAUSE_STOPS, EXPECTED_RETURN, SPEND.
fm_afk_contract_render_body() {  # <entered-iso> <entered-epoch>
  local entered=$1 entered_epoch=$2 ordinal=0 i as_given
  local accepted_block="" refused_block=""
  i=0
  while [ "$i" -lt "${#CLAUSE_ACTIONS[@]}" ]; do
    ordinal=$((ordinal + 1))
    if fm_afk_contract_clause_check "${CLAUSE_ACTIONS[$i]}" "${CLAUSE_OBJECTS[$i]}" "${CLAUSE_WHENS[$i]}" "${CLAUSE_STOPS[$i]}" "${CLAUSE_STOP_GIVENS[$i]}"; then
      accepted_block="$accepted_block$(printf '  - id: %s\n    action: %s\n    object: e:%s\n    when: e:%s\n' \
        "$ordinal" "$C_ACTION" "$(fm_afk_contract_escape "$C_OBJECT")" "$(fm_afk_contract_escape "$C_WHEN")"
      if [ -n "$C_STOP" ]; then
        printf '    stop: e:%s\n' "$(fm_afk_contract_escape "$C_STOP")"
      else
        printf '    stop: -\n'
      fi
      if [ -n "$C_FLAG" ]; then
        printf '    flag: %s' "$C_FLAG"
      else
        printf '    flag: -'
      fi)
"
    else
      as_given=$(fm_afk_contract_clause_as_given "${CLAUSE_ACTIONS[$i]}" "${CLAUSE_OBJECTS[$i]}" "${CLAUSE_WHENS[$i]}" "${CLAUSE_STOPS[$i]}" "${CLAUSE_STOP_GIVENS[$i]}"; printf x)
      as_given=${as_given%x}
      refused_block="$refused_block$(printf '  - id: %s\n    text: e:%s\n    missing: %s' \
        "$ordinal" "$(fm_afk_contract_escape "$as_given")" "$C_MISSING")
"
    fi
    i=$((i + 1))
  done
  printf 'version: %s\n' "$FM_AFK_CONTRACT_VERSION"
  printf 'entered: %s\n' "$entered"
  printf 'entered_epoch: %s\n' "$entered_epoch"
  printf 'expected_return: %s\n' "${EXPECTED_RETURN:--}"
  printf 'reach_channels: none\n'
  printf 'reach_announced: %s\n' "$FM_AFK_CONTRACT_REACH_ANNOUNCED"
  printf 'spend_max_concurrent_workers: %s\n' "${SPEND:-$FM_AFK_CONTRACT_SPEND_DEFAULT}"
  if [ -n "$WORDS" ]; then
    local words_body=$WORDS words_indicator='|-'
    case "$words_body" in
      *$'\n') words_indicator='|'; words_body=${words_body%$'\n'} ;;
    esac
    printf 'words: %s\n' "$words_indicator"
    printf '%s\n' "$words_body" | sed 's/^/  /'
  else
    printf 'words: -\n'
  fi
  printf 'clauses:\n'
  [ -z "$accepted_block" ] || printf '%s' "$accepted_block"
  printf 'refused:\n'
  [ -z "$refused_block" ] || printf '%s' "$refused_block"
}

fm_afk_contract_write_atomic() {  # <path> (content on stdin)
  local path=$1 pending
  mkdir -p "$(dirname "$path")" || return 1
  pending=$(mktemp "$(dirname "$path")/.afk-contract.pending.XXXXXX") || return 1
  if ! cat > "$pending"; then
    rm -f "$pending"
    return 1
  fi
  mv "$pending" "$path" || { rm -f "$pending"; return 1; }
}

# --- record reading (the only parser) --------------------------------------

fm_afk_contract_read_field() {  # <path> <name>
  local path=$1 name=$2
  [ -f "$path" ] || return 1
  sed -n "s/^${name}: //p" "$path" | head -1
}

fm_afk_contract_read_words() {  # <path>
  local path=$1
  [ -f "$path" ] || return 1
  awk -v record="$path" '
    function die(reason) {
      printf "fm-afk-contract: record %s has an invalid words block: %s\n", record, reason > "/dev/stderr"
      bad = 1
      exit 2
    }
    /^words: \|$/ && !found { found = inwords = 1; keep_final = 1; next }
    /^words: \|-$/ && !found { found = inwords = 1; keep_final = 0; next }
    /^words: -$/ && !found { found = scalar = 1; next }
    !found { next }
    $0 == "clauses:" {
      if (inwords && count == 0) die("the block indicator has no stored lines")
      done = 1
      exit
    }
    inwords && /^  / { lines[++count] = substr($0, 3); next }
    { die("a stored line lacks its two-space record prefix") }
    END {
      if (bad) exit 2
      if (!found) die("the words field is missing")
      if (!done) die("the clauses section does not follow the words field")
      for (i = 1; i <= count; i++) {
        printf "%s", lines[i]
        if (i < count || keep_final) printf "\n"
      }
    }
  ' "$path"
}

# TSV rows for a list section: <section> is clauses or refused.
fm_afk_contract_read_list() {  # <path> <section>
  local path=$1 section=$2
  [ -f "$path" ] || return 1
  awk -v want="$section" -v verbs="$FM_AFK_CONTRACT_VERBS" -v record="$path" '
    function row_name() { return (id != "" ? id : ordinal + 1) }
    function die(part) {
      printf "fm-afk-contract: record %s has malformed %s row %s: missing or invalid %s\n", record, section, row_name(), part > "/dev/stderr"
      bad = 1
      exit 2
    }
    function valid_action(value,    values, count, i) {
      count = split(verbs, values, " ")
      for (i = 1; i <= count; i++) if (value == values[i]) return 1
      return 0
    }
    function flush() {
      if (!active) return
      if (section == "clauses") {
        if (state < 1 || id !~ /^[0-9]+$/) die("id")
        if (state < 2 || !valid_action(action)) die("action")
        if (state < 3) die("object")
        if (state < 4) die("when")
        if (state < 5) die("stop")
        if (state < 6 || flag == "") die("flag")
        if (want == "clauses") printf "%s\t%s\t%s\t%s\t%s\n", id, action, object, when, stop
        else if (flag != "-") printf "%s\t%s\n", id, flag
      } else {
        if (state < 1 || id !~ /^[0-9]+$/) die("id")
        if (state < 2) die("text")
        if (state < 3 || missing == "") die("missing")
        printf "%s\t%s\t%s\n", id, text, missing
      }
      ordinal++
      active = 0
      state = 0
      id = action = object = when = stop = text = missing = flag = ""
    }
    BEGIN { section = (want == "flags") ? "clauses" : want }
    $0 == section ":" && !found { found = insection = 1; next }
    insection && /^[^ ]/ { flush(); done = 1; exit }
    !insection { next }
    /^  - id: / {
      flush()
      active = 1
      id = substr($0, 9)
      state = 1
      next
    }
    section == "clauses" && state == 1 && /^    action: / { action = substr($0, 13); state = 2; next }
    section == "clauses" && state == 2 && /^    object: e:/ { object = substr($0, 15); state = 3; next }
    section == "clauses" && state == 3 && /^    when: e:/ { when = substr($0, 13); state = 4; next }
    section == "clauses" && state == 4 && /^    stop: e:/ { stop = substr($0, 13); state = 5; next }
    section == "clauses" && state == 4 && /^    stop: -$/ { stop = "-"; state = 5; next }
    section == "clauses" && state == 5 && /^    flag: / { flag = substr($0, 11); state = 6; next }
    section == "refused" && state == 1 && /^    text: e:/ { text = substr($0, 13); state = 2; next }
    section == "refused" && state == 2 && /^    missing: / { missing = substr($0, 14); state = 3; next }
    { die(section == "clauses" ? (state == 1 ? "action" : state == 2 ? "object" : state == 3 ? "when" : state == 4 ? "stop" : state == 5 ? "flag" : "row") : (state == 1 ? "text" : state == 2 ? "missing" : "row")) }
    END {
      if (bad) exit 2
      if (!done) flush()
      if (!found) {
        printf "fm-afk-contract: record %s lacks its %s section\n", record, section > "/dev/stderr"
        exit 2
      }
    }
  ' "$path"
}

# A record is valid when its version is the one this script writes and the
# required scalar fields are present. Refuses rather than guessing at a foreign
# schema.
fm_afk_contract_validate() {  # <path> <require-confirmed 0|1>
  local path=$1 require_confirmed=$2 version entered entered_epoch expected reach announced spend words_header confirmed
  local clause_rows refused_rows clause refused id object when stop text decoded
  [ -f "$path" ] || return 1
  version=$(fm_afk_contract_read_field "$path" version)
  [ "$version" = "$FM_AFK_CONTRACT_VERSION" ] || {
    fm_afk_contract_log "record $path carries version '${version:-none}', expected $FM_AFK_CONTRACT_VERSION; refusing to read it"
    return 1
  }
  entered=$(fm_afk_contract_read_field "$path" entered)
  fm_afk_contract_validate_iso "$entered" || { fm_afk_contract_log "record $path has no valid entered time"; return 1; }
  entered_epoch=$(fm_afk_contract_read_field "$path" entered_epoch)
  case "$entered_epoch" in ''|*[!0-9]*) fm_afk_contract_log "record $path has no entered_epoch"; return 1 ;; esac
  expected=$(fm_afk_contract_read_field "$path" expected_return)
  [ "$expected" = - ] || fm_afk_contract_validate_iso "$expected" || { fm_afk_contract_log "record $path has no valid expected_return"; return 1; }
  reach=$(fm_afk_contract_read_field "$path" reach_channels)
  [ "$reach" = none ] || { fm_afk_contract_log "record $path has no valid reach_channels"; return 1; }
  announced=$(fm_afk_contract_read_field "$path" reach_announced)
  [ -n "$announced" ] || { fm_afk_contract_log "record $path has no reach announcement"; return 1; }
  spend=$(fm_afk_contract_read_field "$path" spend_max_concurrent_workers)
  case "$spend" in ''|*[!0-9]*|0) fm_afk_contract_log "record $path has no valid spend cap"; return 1 ;; esac
  words_header=$(sed -n '/^words: /{p;q;}' "$path")
  case "$words_header" in 'words: -'|'words: |'|'words: |-') ;; *) fm_afk_contract_log "record $path has no valid words field"; return 1 ;; esac
  fm_afk_contract_read_words "$path" >/dev/null || return 1
  if [ "$require_confirmed" -eq 1 ]; then
    confirmed=$(fm_afk_contract_read_field "$path" confirmed)
    fm_afk_contract_validate_iso "$confirmed" || { fm_afk_contract_log "record $path has no valid confirmed time"; return 1; }
    case "$(fm_afk_contract_read_field "$path" confirmed_epoch)" in
      ''|*[!0-9]*) fm_afk_contract_log "record $path was never confirmed"; return 1 ;;
    esac
  fi
  if ! clause_rows=$(fm_afk_contract_read_list "$path" clauses); then
    return 1
  fi
  while IFS= read -r clause; do
    [ -n "$clause" ] || continue
    id=$(printf '%s' "$clause" | cut -f1)
    object=$(printf '%s' "$clause" | cut -f3)
    when=$(printf '%s' "$clause" | cut -f4)
    stop=$(printf '%s' "$clause" | cut -f5)
    decoded=$(fm_afk_contract_unescape "$object"; printf x)
    decoded=${decoded%x}
    if fm_afk_contract_blank "$decoded"; then
      fm_afk_contract_log "record $path has malformed clauses row $id: missing or invalid object"
      return 1
    fi
    decoded=$(fm_afk_contract_unescape "$when"; printf x)
    decoded=${decoded%x}
    if fm_afk_contract_blank "$decoded"; then
      fm_afk_contract_log "record $path has malformed clauses row $id: missing or invalid when"
      return 1
    fi
    if [ "$stop" != - ]; then
      decoded=$(fm_afk_contract_unescape "$stop"; printf x)
      decoded=${decoded%x}
      if fm_afk_contract_blank "$decoded"; then
        fm_afk_contract_log "record $path has malformed clauses row $id: missing or invalid stop"
        return 1
      fi
    fi
  done <<EOF
$clause_rows
EOF
  if ! refused_rows=$(fm_afk_contract_read_list "$path" refused); then
    return 1
  fi
  while IFS= read -r refused; do
    [ -n "$refused" ] || continue
    id=$(printf '%s' "$refused" | cut -f1)
    text=$(printf '%s' "$refused" | cut -f2)
    decoded=$(fm_afk_contract_unescape "$text"; printf x)
    decoded=${decoded%x}
    if fm_afk_contract_blank "$decoded"; then
      fm_afk_contract_log "record $path has malformed refused row $id: missing or invalid text"
      return 1
    fi
  done <<EOF
$refused_rows
EOF
}

# --- rendering --------------------------------------------------------------

fm_afk_contract_render_readback() {  # <path> <title>
  local path=$1 title=$2 words count id action object when stop text missing expected spend flag
  expected=$(fm_afk_contract_read_field "$path" expected_return)
  spend=$(fm_afk_contract_read_field "$path" spend_max_concurrent_workers)
  printf '%s\n' "$title"
  printf '  entered: %s\n' "$(fm_afk_contract_read_field "$path" entered)"
  printf '  expected return: %s\n' "$( [ "$expected" = - ] && printf 'not given' || printf '%s' "$expected")"
  printf '  spend cap: %s concurrent workers\n' "$spend"
  printf '  reach: hold-for-return only. %s\n' "$(fm_afk_contract_read_field "$path" reach_announced)"
  words=$(fm_afk_contract_read_words "$path"; printf x)
  words=${words%x}
  if [ -n "$words" ]; then
    printf '  your words (verbatim):\n'
    printf '%s' "$words" | sed 's/^/    /'
    case "$words" in *$'\n') ;; *) printf '\n' ;; esac
  else
    printf '  your words: (none)\n'
  fi
  printf '  accepted clauses:\n'
  count=0
  while IFS="$(printf '\t')" read -r id action object when stop; do
    [ -n "$id" ] || continue
    count=$((count + 1))
    printf '    %s. %s ' "$id" "$action"
    fm_afk_contract_unescape "$object"
    printf ' when '
    fm_afk_contract_unescape "$when"
    if [ "$stop" != - ]; then
      printf ' stop '
      fm_afk_contract_unescape "$stop"
    fi
    flag=$(fm_afk_contract_read_list "$path" flags | awk -F '\t' -v id="$id" '$1 == id { print $2 }')
    [ -z "$flag" ] || printf " - flagged: names '%s', a never-set concept that is never pre-authorizable; recorded, judged at execution" "$flag"
    printf '\n'
  done <<EOF
$(fm_afk_contract_read_list "$path" clauses)
EOF
  [ "$count" -gt 0 ] || printf '    (none)\n'
  printf '  refused clauses:\n'
  count=0
  while IFS="$(printf '\t')" read -r id text missing; do
    [ -n "$id" ] || continue
    count=$((count + 1))
    printf '    %s. "' "$id"
    fm_afk_contract_unescape "$text"
    printf '" - refused: missing %s\n' "$missing"
  done <<EOF
$(fm_afk_contract_read_list "$path" refused)
EOF
  [ "$count" -gt 0 ] || printf '    (none)\n'
  printf '  everything else waits for your return: no red merge without its named check, no discard without a named object and condition, never credentials, legal, financial, or attended prompts, nothing by analogy, and every clause expires at return.\n'
  printf '  hard rule: forbidden, destructive, irreversible, and security-sensitive actions are never pre-authorizable regardless of clause text; no recorded clause is authority by itself.\n'
  printf '  recorded clauses are held for the return brief and are not executed by this release.\n'
}

fm_afk_contract_render_announcement() {  # <path>
  local path=$1 accepted refused flagged expected clause_text
  accepted=$(fm_afk_contract_read_list "$path" clauses | grep -c . || true)
  refused=$(fm_afk_contract_read_list "$path" refused | grep -c . || true)
  flagged=$(fm_afk_contract_read_list "$path" flags | grep -c . || true)
  expected=$(fm_afk_contract_read_field "$path" expected_return)
  if [ "$accepted" -eq 0 ] && [ "$refused" -eq 0 ]; then
    clause_text='No mandate clauses recorded. Forbidden, destructive, irreversible, and security-sensitive actions are never pre-authorizable regardless of clause text, and no recorded clause is authority by itself.'
  else
    clause_text="$accepted mandate clause(s) recorded, $refused refused, and $flagged flagged as naming a never-set concept; recorded clauses are held for the return brief and are not executed by this release; forbidden, destructive, irreversible, and security-sensitive actions are never pre-authorizable regardless of clause text, and no recorded clause is authority by itself."
  fi
  printf 'Away posture confirmed at %s: hold-for-return only. %s %s Expected return: %s. Spend cap: %s concurrent workers.\n' \
    "$(fm_afk_contract_read_field "$path" confirmed)" \
    "$(fm_afk_contract_read_field "$path" reach_announced)" \
    "$clause_text" \
    "$( [ "$expected" = - ] && printf 'not given' || printf '%s' "$expected")" \
    "$(fm_afk_contract_read_field "$path" spend_max_concurrent_workers)"
}

# --- subcommands ------------------------------------------------------------

fm_afk_contract_parse_inputs() {  # <args...>; sets WORDS, the CLAUSE_* arrays, EXPECTED_RETURN, SPEND
  local words_file='' open=-1
  WORDS=; EXPECTED_RETURN=-; SPEND=$FM_AFK_CONTRACT_SPEND_DEFAULT
  CLAUSE_ACTIONS=(); CLAUSE_OBJECTS=(); CLAUSE_WHENS=(); CLAUSE_STOPS=(); CLAUSE_STOP_GIVENS=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --words-file)
        [ "$#" -gt 1 ] || { fm_afk_contract_log '--words-file requires a path'; return 2; }
        words_file=$2
        shift 2 ;;
      --words)
        [ "$#" -gt 1 ] || { fm_afk_contract_log '--words requires text'; return 2; }
        WORDS=$2
        shift 2 ;;
      --action)
        [ "$#" -gt 1 ] || { fm_afk_contract_log '--action requires a verb; it opens a clause for the --object, --when, and --stop that follow it'; return 2; }
        CLAUSE_ACTIONS+=("$2"); CLAUSE_OBJECTS+=(''); CLAUSE_WHENS+=(''); CLAUSE_STOPS+=(''); CLAUSE_STOP_GIVENS+=(0)
        open=$(( ${#CLAUSE_ACTIONS[@]} - 1 ))
        shift 2 ;;
      --object|--when|--stop)
        [ "$#" -gt 1 ] || { fm_afk_contract_log "$1 requires text"; return 2; }
        [ "$open" -ge 0 ] || { fm_afk_contract_log "$1 must follow the --action that opens its clause"; return 2; }
        case "$1" in
          --object) CLAUSE_OBJECTS[open]=$2 ;;
          --when) CLAUSE_WHENS[open]=$2 ;;
          --stop) CLAUSE_STOPS[open]=$2; CLAUSE_STOP_GIVENS[open]=1 ;;
        esac
        shift 2 ;;
      --expected-return)
        [ "$#" -gt 1 ] || { fm_afk_contract_log '--expected-return requires a UTC ISO 8601 time'; return 2; }
        if ! fm_afk_contract_validate_iso "$2"; then
          fm_afk_contract_log "--expected-return must be UTC ISO 8601 (YYYY-MM-DDTHH:MM[:SS]Z), got '$2'"
          return 2
        fi
        EXPECTED_RETURN=$2
        shift 2 ;;
      --spend)
        [ "$#" -gt 1 ] || { fm_afk_contract_log '--spend requires a positive integer'; return 2; }
        case "$2" in ''|*[!0-9]*|0) fm_afk_contract_log "--spend must be a positive integer, got '$2'"; return 2 ;; esac
        SPEND=$2
        shift 2 ;;
      *)
        fm_afk_contract_log "unknown option '$1'"
        return 2 ;;
    esac
  done
  if [ -n "$words_file" ]; then
    [ -f "$words_file" ] || { fm_afk_contract_log "words file not found: $words_file"; return 2; }
    # Command substitution strips trailing newlines; the sentinel keeps the
    # file's bytes verbatim, trailing newlines included.
    WORDS=$(cat "$words_file"; printf x) || return 1
    WORDS=${WORDS%x}
  fi
  return 0
}

fm_afk_contract_cmd_propose() {
  local entered entered_epoch proposal rc=0 refused
  fm_afk_contract_parse_inputs "$@" || return 2
  entered=$(fm_afk_contract_now_iso)
  entered_epoch=$(date +%s)
  proposal=$(fm_afk_contract_proposal_path)
  fm_afk_contract_render_body "$entered" "$entered_epoch" | fm_afk_contract_write_atomic "$proposal" || {
    fm_afk_contract_log "failed to write the proposal at $proposal"
    return 1
  }
  refused=$(fm_afk_contract_read_list "$proposal" refused | grep -c . || true)
  [ "$refused" -eq 0 ] || rc=3
  fm_afk_contract_render_readback "$proposal" 'Away posture read-back (proposed, not yet confirmed):'
  printf 'Say go to confirm; restate any refused clause first if you want it recorded.\n'
  return "$rc"
}

fm_afk_contract_archive_target() {  # <record> [superseded-stamp]
  local record=$1 stamp=${2:-} dir entered_epoch target
  dir=$(fm_afk_contract_archive_dir)
  mkdir -p "$dir" || return 1
  entered_epoch=$(fm_afk_contract_read_field "$record" entered_epoch)
  case "$entered_epoch" in ''|*[!0-9]*) entered_epoch=$(date +%s) ;; esac
  if [ -n "$stamp" ]; then
    target="$dir/$entered_epoch-superseded-$stamp.afk-contract"
    [ ! -e "$target" ] || target="$dir/$entered_epoch-superseded-$stamp-$$.afk-contract"
  else
    target="$dir/$entered_epoch.afk-contract"
  fi
  printf '%s\n' "$target"
}

fm_afk_contract_cmd_confirm() {
  local record proposal body confirmed confirmed_epoch archived archived_tmp staged session_entered session_entered_epoch
  record=$(fm_afk_contract_path)
  proposal=$(fm_afk_contract_proposal_path)
  confirmed=$(fm_afk_contract_now_iso)
  confirmed_epoch=$(date +%s)
  if [ -f "$proposal" ]; then
    fm_afk_contract_validate "$proposal" 0 || return 1
    body=$(cat "$proposal")
  elif [ -f "$record" ]; then
    fm_afk_contract_validate "$record" 1 || return 1
    fm_afk_contract_log "away posture already recorded at $(fm_afk_contract_read_field "$record" entered); nothing to confirm"
    fm_afk_contract_render_announcement "$record"
    return 0
  else
    fm_afk_contract_log "no away-posture proposal exists; run propose before confirm"
    return 1
  fi
  session_entered=$confirmed
  session_entered_epoch=$confirmed_epoch
  if [ -f "$record" ]; then
    session_entered=$(fm_afk_contract_read_field "$record" entered)
    session_entered_epoch=$(fm_afk_contract_read_field "$record" entered_epoch)
  fi
  staged=$(mktemp "$(dirname "$record")/.afk-contract.confirming.XXXXXX") || return 1
  {
    printf '%s\n' "$body" | awk -v entered="$session_entered" -v epoch="$session_entered_epoch" '
      /^entered: / { print "entered: " entered; next }
      /^entered_epoch: / { print "entered_epoch: " epoch; next }
      /^words: / { exit }
      { print }
    '
    printf 'confirmed: %s\nconfirmed_epoch: %s\n' "$confirmed" "$confirmed_epoch"
    printf '%s\n' "$body" | awk 'p{print} /^words: /{p=1; print}'
  } > "$staged" || { rm -f "$staged"; return 1; }
  fm_afk_contract_validate "$staged" 1 || { rm -f "$staged"; return 1; }
  if [ -f "$record" ]; then
    archived=$(fm_afk_contract_archive_target "$record" "$confirmed_epoch") || { rm -f "$staged"; return 1; }
    # Copy into a temporary name first and rename atomically, so a failed copy
    # never leaves a partial archive at a glob-visible name.
    archived_tmp=$(mktemp "$(dirname "$archived")/.afk-contract.archiving.XXXXXX") || { rm -f "$staged"; return 1; }
    if ! cp -p "$record" "$archived_tmp" || ! mv "$archived_tmp" "$archived"; then
      rm -f "$staged" "$archived_tmp"
      return 1
    fi
  fi
  mv "$staged" "$record" || {
    rm -f "$staged"
    [ -z "${archived:-}" ] || rm -f "$archived"
    return 1
  }
  if [ -n "${archived:-}" ]; then
    fm_afk_contract_log "replaced the earlier away posture; its record is archived at $archived"
  fi
  rm -f "$proposal"
  fm_afk_contract_render_announcement "$record"
}

fm_afk_contract_cmd_archive() {
  local record target
  record=$(fm_afk_contract_path)
  [ -f "$record" ] || return 0
  if ! fm_afk_contract_validate "$record" 1; then
    fm_afk_contract_log "confirmed away-posture record at $record is invalid; refusing to archive"
    return 1
  fi
  target=$(fm_afk_contract_archive_target "$record") || return 1
  mv "$record" "$target" || return 1
  printf '%s\n' "$target"
}

fm_afk_contract_select_path() {  # <args...> -> prints the record path chosen by --proposal/--path
  local path
  path=$(fm_afk_contract_path)
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --proposal) path=$(fm_afk_contract_proposal_path); shift ;;
      --path) [ "$#" -gt 1 ] || return 2; path=$2; shift 2 ;;
      *) return 2 ;;
    esac
  done
  printf '%s' "$path"
}

fm_afk_contract_main() {
  local cmd=${1:-} path
  [ -n "$cmd" ] || { fm_afk_contract_usage >&2; return 2; }
  shift
  case "$cmd" in
    propose) fm_afk_contract_cmd_propose "$@" ;;
    confirm) [ "$#" -eq 0 ] || { fm_afk_contract_usage >&2; return 2; }; fm_afk_contract_cmd_confirm ;;
    readback)
      path=$(fm_afk_contract_select_path "$@") || { fm_afk_contract_usage >&2; return 2; }
      [ -f "$path" ] || { fm_afk_contract_log "no record at $path"; return 1; }
      if [ "$path" = "$(fm_afk_contract_proposal_path)" ]; then
        fm_afk_contract_render_readback "$path" 'Away posture read-back (proposed, not yet confirmed):'
      else
        fm_afk_contract_render_readback "$path" 'Away posture (confirmed):'
      fi ;;
    field)
      [ "$#" -ge 1 ] || { fm_afk_contract_usage >&2; return 2; }
      local name=$1; shift
      path=$(fm_afk_contract_select_path "$@") || { fm_afk_contract_usage >&2; return 2; }
      fm_afk_contract_read_field "$path" "$name" ;;
    words)
      path=$(fm_afk_contract_select_path "$@") || { fm_afk_contract_usage >&2; return 2; }
      fm_afk_contract_read_words "$path" ;;
    clauses)
      path=$(fm_afk_contract_select_path "$@") || { fm_afk_contract_usage >&2; return 2; }
      fm_afk_contract_read_list "$path" clauses ;;
    flags)
      path=$(fm_afk_contract_select_path "$@") || { fm_afk_contract_usage >&2; return 2; }
      fm_afk_contract_read_list "$path" flags ;;
    validate)
      path=$(fm_afk_contract_select_path "$@") || { fm_afk_contract_usage >&2; return 2; }
      if [ "$path" = "$(fm_afk_contract_proposal_path)" ]; then
        fm_afk_contract_validate "$path" 0
      else
        fm_afk_contract_validate "$path" 1
      fi ;;
    refused)
      path=$(fm_afk_contract_select_path "$@") || { fm_afk_contract_usage >&2; return 2; }
      fm_afk_contract_read_list "$path" refused ;;
    archive) fm_afk_contract_cmd_archive ;;
    archived)
      [ "$#" -eq 1 ] || { fm_afk_contract_usage >&2; return 2; }
      path="$(fm_afk_contract_archive_dir)/$1.afk-contract"
      [ -f "$path" ] || { fm_afk_contract_log "no archived record for entered_epoch $1"; return 1; }
      printf '%s\n' "$path" ;;
    -h|--help|help) fm_afk_contract_usage ;;
    *) fm_afk_contract_usage >&2; return 2 ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  fm_afk_contract_main "$@"
fi
