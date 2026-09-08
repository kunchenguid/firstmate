#!/usr/bin/env bash
# fm-afk-contract.sh - the one owner of the away-posture record: its schema, the
# mandate-clause grammar and compiler, refusal naming the missing part, the
# read-back rendering, the entry announcement, and the archive at return.
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
#   words: |                       the captain's words, verbatim, never edited,
#     <line>                       one record line per input line (or `words: -`
#     ...                          when /afk carried no words)
#   clauses:                       accepted clauses, compiled from --clause inputs
#     - id: <input ordinal>
#       action: <verb>
#       object: <text>
#       when: <condition>
#       stop: <condition> | -
#   refused:                       clauses missing a part, with the part named
#     - id: <input ordinal>
#       text: <the clause as given>
#       missing: <part - reason>
# A proposal (state/.afk-contract.proposed) has the same shape without the
# confirmed fields. Archived records live under state/afk-contracts/ as
# <entered_epoch>.afk-contract.
#
# CLAUSE GRAMMAR. One clause per --clause argument, on one line:
#   <action> <object> when <condition> [stop <condition>]
#   action  one of: merge land prerelease install rerun dispatch abort-run answer
#           discard wake-me. A new verb is a code change here, never a prompt change.
#   object  a named thing: a task id, "task X's PR", a repo, a machine, a named
#           run. A class word (anything, everything, whatever, any, all, every,
#           whichever, whoever) is refused: the object must name a thing.
#   when    a verifiable condition: "checks green"; "red on <check>" (a red merge
#           or landing is legal only when the failing check is named); "after
#           clause N" (an earlier accepted clause); a named event such as
#           "install deadlocks"; or a time "at <UTC ISO 8601>". Unconditional
#           wording (regardless, always, unconditionally, anyway, no matter what,
#           whatever happens) is refused because nothing verifies it.
#   stop    optional: a condition that ends the clause early.
# The never-set is checked before the grammar: a clause naming credentials,
# passwords or logins, legal or financial acceptance, or an attended prompt is
# refused for every actor, because those are physically the captain's.
# A clause missing any required part is refused with that part named, recorded
# under refused:, read back beside the accepted list, and never executes. Ids
# are the input ordinals across accepted and refused clauses, so "after clause
# N" always means the N-th clause the captain gave.
# THIS RELEASE RECORDS CLAUSES AND DOES NOT EXECUTE THEM: the guarded gates learn
# to cite a clause in a later phase, and the announcement and return brief both
# say so, so a recorded clause is never mistaken for a promise.
#
# Usage:
#   fm-afk-contract.sh compile [--words-file <path> | --words <text>]
#       [--clause <text>]... [--expected-return <UTC ISO 8601>] [--spend <n>]
#     Compile without writing; print the read-back. Exit 0 with every clause
#     accepted, 3 when at least one clause was refused (the read-back names the
#     missing part), 2 on a usage error.
#   fm-afk-contract.sh propose [same options]
#     Compile, write the proposal, and print the read-back; exits as compile.
#     A refused clause does not fail the proposal: it is recorded as refused so
#     the captain can restate it before saying go.
#   fm-afk-contract.sh confirm
#     Promote the proposal into the record with the confirmed timestamp and
#     print the entry announcement. With no proposal: write the default record
#     (no words, no clauses) when none exists, or refresh nothing when one does.
#     A proposal confirmed over an existing record archives the old record first.
#   fm-afk-contract.sh discard-proposal
#   fm-afk-contract.sh present              exit 0 when the record exists
#   fm-afk-contract.sh announce             print the entry announcement
#   fm-afk-contract.sh readback [--proposal]
#   fm-afk-contract.sh field <name> [--proposal]
#   fm-afk-contract.sh words [--proposal | --path <record>]
#   fm-afk-contract.sh clauses [--proposal | --path <record>]   TSV: id action object when stop
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

# One line, trimmed, tabs and newlines collapsed to spaces: the shape every
# clause part is stored in.
fm_afk_contract_oneline() {  # <text>
  printf '%s' "$1" | tr '\t\r\n' '   ' | sed 's/^ *//; s/ *$//; s/  */ /g'
}

# --- clause compiler --------------------------------------------------------

# Parse one clause into C_ACTION C_OBJECT C_WHEN C_STOP, then validate against
# the grammar above. On refusal C_MISSING names the part and the reason.
# <accepted-ids> is a space-separated list of earlier accepted ordinals, for
# "after clause N" references.
fm_afk_contract_clause_compile() {  # <ordinal> <text> <accepted-ids>
  local ordinal=$1 text accepted=$3 lower head rest rest_lower head_lower cond_lower word ref
  C_ACTION=; C_OBJECT=; C_WHEN=; C_STOP=-; C_MISSING=
  text=$(fm_afk_contract_oneline "$2")
  lower=$(fm_afk_contract_lower "$text")
  # The never-set outranks the grammar: no actor may hold these, in either posture.
  for word in credential credentials password passwords passcode login "log in" "sign in" sign-in 2fa otp mfa legal financial payment invoice; do
    case " $lower " in
      *" $word "*|*" $word's "*|*" ${word}s "*)
        C_MISSING="object - the never-set refuses it: credentials, logins, legal or financial acceptance, and attended prompts are the captain's ('$word')"
        return 1 ;;
    esac
  done
  case " $lower " in
    *" attended prompt"*)
      C_MISSING="object - the never-set refuses it: an attended prompt is the captain's"
      return 1 ;;
  esac
  case " $lower " in
    *" when "*)
      head_lower=${lower%% when *}
      head=${text:0:${#head_lower}}
      rest=${text:$(( ${#head_lower} + 6 ))}
      ;;
    *)
      head=$text
      rest=
      ;;
  esac
  case "$lower" in
    "when "*) head=; rest=${text:5} ;;
  esac
  C_ACTION=$(fm_afk_contract_lower "${head%% *}")
  case "$head" in
    *" "*) C_OBJECT=${head#* } ;;
    *) C_OBJECT= ;;
  esac
  C_OBJECT=$(fm_afk_contract_oneline "$C_OBJECT")
  rest_lower=$(fm_afk_contract_lower "$rest")
  case " $rest_lower " in
    *" stop "*)
      cond_lower=${rest_lower%% stop *}
      C_WHEN=${rest:0:${#cond_lower}}
      C_STOP=${rest:$(( ${#cond_lower} + 6 ))}
      ;;
    *)
      C_WHEN=$rest
      C_STOP=-
      ;;
  esac
  case "$rest_lower" in
    "stop "*) C_WHEN=; C_STOP=${rest:5} ;;
  esac
  C_WHEN=$(fm_afk_contract_oneline "$C_WHEN")
  C_STOP=$(fm_afk_contract_oneline "$C_STOP")
  [ -n "$C_STOP" ] || C_STOP=-

  # action
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
  # object
  if [ -z "$C_OBJECT" ]; then
    C_MISSING='object - the clause names no thing to act on'
    return 1
  fi
  for word in anything everything whatever any all every whichever whoever; do
    case " $(fm_afk_contract_lower "$C_OBJECT") " in
      *" $word "*)
        C_MISSING="object - names a class ('$word'), not a thing: name the task, PR, repo, machine, or run"
        return 1 ;;
    esac
  done
  # when
  if [ -z "$C_WHEN" ]; then
    C_MISSING='when - no verifiable condition: name the check, event, clause, or time'
    return 1
  fi
  cond_lower=$(fm_afk_contract_lower "$C_WHEN")
  for word in regardless always unconditionally anyway "no matter what" "whatever happens" "in any case"; do
    case " $cond_lower " in
      *" $word "*)
        C_MISSING="when - not verifiable ('$word'): name the check, event, clause, or time"
        return 1 ;;
    esac
  done
  case "$cond_lower" in
    "after clause "*|*" after clause "*)
      ref=${cond_lower##*after clause }
      ref=${ref%% *}
      case "$ref" in
        ''|*[!0-9]*)
          C_MISSING="when - 'after clause' names no clause number"
          return 1 ;;
      esac
      if [ "$ref" -ge "$ordinal" ]; then
        C_MISSING="when - 'after clause $ref' names this clause or a later one"
        return 1
      fi
      case " $accepted " in
        *" $ref "*) ;;
        *)
          C_MISSING="when - 'after clause $ref' names a refused clause"
          return 1 ;;
      esac
      ;;
  esac
  case "$C_ACTION" in
    merge|land)
      case " $cond_lower " in
        *red*|*fail*)
          # The failing check must be named: strip the filler and require a name.
          word=$(printf ' %s ' "$cond_lower" \
            | sed -E 's/ (red|failing|fails|failed|fail|failure|check|checks|ci|is|are|even|if|on|the|when|despite|with|while|still|although|though|a|an|or|and|its) / /g; s/ (red|failing|fails|failed|fail|failure|check|checks|ci|is|are|even|if|on|the|when|despite|with|while|still|although|though|a|an|or|and|its) / /g' \
            | sed 's/^ *//; s/ *$//')
          if [ -z "$word" ]; then
            C_MISSING='when - the failing check is not named: a red merge needs "red on <check>"'
            return 1
          fi
          ;;
      esac
      ;;
  esac
  case " $lower " in
    *" stop "*|"stop "*)
      if [ "$C_STOP" = - ]; then
        C_MISSING='stop - "stop" was given with no condition after it'
        return 1
      fi
      ;;
  esac
  return 0
}

# --- record writing ---------------------------------------------------------

fm_afk_contract_validate_iso() {  # <ts>
  fm_utc_iso_to_epoch "$1" >/dev/null 2>&1
}

# Compile every input into a record body on stdout (everything except the
# confirmed fields). Inputs: WORDS (verbatim), CLAUSES (one per line, the raw
# arguments joined with newlines), EXPECTED_RETURN, SPEND.
fm_afk_contract_render_body() {  # <entered-iso> <entered-epoch>
  local entered=$1 entered_epoch=$2 ordinal=0 accepted="" clause
  local accepted_block="" refused_block=""
  while IFS= read -r clause || [ -n "$clause" ]; do
    [ -n "$(fm_afk_contract_oneline "$clause")" ] || continue
    ordinal=$((ordinal + 1))
    if fm_afk_contract_clause_compile "$ordinal" "$clause" "$accepted"; then
      accepted="$accepted $ordinal"
      accepted_block="$accepted_block$(printf '  - id: %s\n    action: %s\n    object: %s\n    when: %s\n    stop: %s' \
        "$ordinal" "$C_ACTION" "$C_OBJECT" "$C_WHEN" "$C_STOP")
"
    else
      refused_block="$refused_block$(printf '  - id: %s\n    text: %s\n    missing: %s' \
        "$ordinal" "$(fm_afk_contract_oneline "$clause")" "$C_MISSING")
"
    fi
  done <<EOF
$CLAUSES
EOF
  printf 'version: %s\n' "$FM_AFK_CONTRACT_VERSION"
  printf 'entered: %s\n' "$entered"
  printf 'entered_epoch: %s\n' "$entered_epoch"
  printf 'expected_return: %s\n' "${EXPECTED_RETURN:--}"
  printf 'reach_channels: none\n'
  printf 'reach_announced: %s\n' "$FM_AFK_CONTRACT_REACH_ANNOUNCED"
  printf 'spend_max_concurrent_workers: %s\n' "${SPEND:-$FM_AFK_CONTRACT_SPEND_DEFAULT}"
  if [ -n "$WORDS" ]; then
    printf 'words: |\n'
    printf '%s\n' "$WORDS" | sed 's/^/  /'
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
  awk '
    /^words: \|$/ { inwords = 1; next }
    /^words: -$/ { exit }
    inwords && /^  / { print substr($0, 3); next }
    inwords && /^$/ { print ""; next }
    inwords { exit }
  ' "$path"
}

# TSV rows for a list section: <section> is clauses or refused.
fm_afk_contract_read_list() {  # <path> <section>
  local path=$1 section=$2
  [ -f "$path" ] || return 1
  awk -v section="$section" '
    function flush() {
      if (id == "") return
      if (section == "clauses") printf "%s\t%s\t%s\t%s\t%s\n", id, action, object, when, stop
      else printf "%s\t%s\t%s\n", id, text, missing
      id = ""; action = ""; object = ""; when = ""; stop = ""; text = ""; missing = ""
    }
    $0 == section ":" { insection = 1; next }
    insection && /^[^ ]/ { flush(); exit }
    insection && /^  - id: / { flush(); id = substr($0, 9); next }
    insection && /^    action: / { action = substr($0, 13); next }
    insection && /^    object: / { object = substr($0, 13); next }
    insection && /^    when: / { when = substr($0, 11); next }
    insection && /^    stop: / { stop = substr($0, 11); next }
    insection && /^    text: / { text = substr($0, 11); next }
    insection && /^    missing: / { missing = substr($0, 14); next }
    END { flush() }
  ' "$path"
}

# A record is valid when its version is the one this script writes and the
# required scalar fields are present. Refuses rather than guessing at a foreign
# schema.
fm_afk_contract_validate() {  # <path> <require-confirmed 0|1>
  local path=$1 require_confirmed=$2 version entered_epoch
  [ -f "$path" ] || return 1
  version=$(fm_afk_contract_read_field "$path" version)
  [ "$version" = "$FM_AFK_CONTRACT_VERSION" ] || {
    fm_afk_contract_log "record $path carries version '${version:-none}', expected $FM_AFK_CONTRACT_VERSION; refusing to read it"
    return 1
  }
  entered_epoch=$(fm_afk_contract_read_field "$path" entered_epoch)
  case "$entered_epoch" in ''|*[!0-9]*) fm_afk_contract_log "record $path has no entered_epoch"; return 1 ;; esac
  if [ "$require_confirmed" -eq 1 ]; then
    case "$(fm_afk_contract_read_field "$path" confirmed_epoch)" in
      ''|*[!0-9]*) fm_afk_contract_log "record $path was never confirmed"; return 1 ;;
    esac
  fi
  grep -q '^clauses:$' "$path" && grep -q '^refused:$' "$path" || {
    fm_afk_contract_log "record $path lacks its clause sections"
    return 1
  }
}

# --- rendering --------------------------------------------------------------

fm_afk_contract_render_readback() {  # <path> <title>
  local path=$1 title=$2 words line count id action object when stop text missing expected spend
  expected=$(fm_afk_contract_read_field "$path" expected_return)
  spend=$(fm_afk_contract_read_field "$path" spend_max_concurrent_workers)
  printf '%s\n' "$title"
  printf '  entered: %s\n' "$(fm_afk_contract_read_field "$path" entered)"
  printf '  expected return: %s\n' "$( [ "$expected" = - ] && printf 'not given' || printf '%s' "$expected")"
  printf '  spend cap: %s concurrent workers\n' "$spend"
  printf '  reach: hold-for-return only. %s\n' "$(fm_afk_contract_read_field "$path" reach_announced)"
  words=$(fm_afk_contract_read_words "$path")
  if [ -n "$words" ]; then
    printf '  your words (verbatim):\n'
    printf '%s\n' "$words" | sed 's/^/    /'
  else
    printf '  your words: (none)\n'
  fi
  printf '  accepted clauses:\n'
  count=0
  while IFS="$(printf '\t')" read -r id action object when stop; do
    [ -n "$id" ] || continue
    count=$((count + 1))
    line="$id. $action $object when $when"
    [ "$stop" = - ] || line="$line stop $stop"
    printf '    %s\n' "$line"
  done <<EOF
$(fm_afk_contract_read_list "$path" clauses)
EOF
  [ "$count" -gt 0 ] || printf '    (none)\n'
  printf '  refused clauses:\n'
  count=0
  while IFS="$(printf '\t')" read -r id text missing; do
    [ -n "$id" ] || continue
    count=$((count + 1))
    printf '    %s. "%s" - refused: missing %s\n' "$id" "$text" "$missing"
  done <<EOF
$(fm_afk_contract_read_list "$path" refused)
EOF
  [ "$count" -gt 0 ] || printf '    (none)\n'
  printf '  everything else waits for your return: no red merge without its named check, no discard without a named object and condition, never credentials, legal, financial, or attended prompts, nothing by analogy, and every clause expires at return.\n'
  printf '  recorded clauses are held for the return brief and are not executed by this release.\n'
}

fm_afk_contract_render_announcement() {  # <path>
  local path=$1 accepted refused expected clause_text
  accepted=$(fm_afk_contract_read_list "$path" clauses | grep -c . || true)
  refused=$(fm_afk_contract_read_list "$path" refused | grep -c . || true)
  expected=$(fm_afk_contract_read_field "$path" expected_return)
  if [ "$accepted" -eq 0 ] && [ "$refused" -eq 0 ]; then
    clause_text='No mandate clauses recorded.'
  else
    clause_text="$accepted mandate clause(s) recorded and $refused refused; recorded clauses are held for the return brief and are not executed by this release."
  fi
  printf 'Away posture confirmed at %s: hold-for-return only. %s %s Expected return: %s. Spend cap: %s concurrent workers.\n' \
    "$(fm_afk_contract_read_field "$path" confirmed)" \
    "$(fm_afk_contract_read_field "$path" reach_announced)" \
    "$clause_text" \
    "$( [ "$expected" = - ] && printf 'not given' || printf '%s' "$expected")" \
    "$(fm_afk_contract_read_field "$path" spend_max_concurrent_workers)"
}

# --- subcommands ------------------------------------------------------------

fm_afk_contract_parse_inputs() {  # <args...>; sets WORDS CLAUSES EXPECTED_RETURN SPEND
  local words_file=
  WORDS=; CLAUSES=; EXPECTED_RETURN=-; SPEND=$FM_AFK_CONTRACT_SPEND_DEFAULT
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
      --clause)
        [ "$#" -gt 1 ] && [ -n "$(fm_afk_contract_oneline "$2")" ] \
          || { fm_afk_contract_log '--clause requires text: <action> <object> when <condition> [stop <condition>]'; return 2; }
        CLAUSES="$CLAUSES$(fm_afk_contract_oneline "$2")
"
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
    WORDS=$(cat "$words_file")
  fi
  return 0
}

fm_afk_contract_cmd_compile() {  # <write-proposal 0|1> <args...>
  local write=$1 entered entered_epoch proposal rc=0 refused
  shift
  fm_afk_contract_parse_inputs "$@" || return 2
  entered=$(fm_afk_contract_now_iso)
  entered_epoch=$(date +%s)
  if [ "$write" -eq 1 ]; then
    proposal=$(fm_afk_contract_proposal_path)
    fm_afk_contract_render_body "$entered" "$entered_epoch" | fm_afk_contract_write_atomic "$proposal" || {
      fm_afk_contract_log "failed to write the proposal at $proposal"
      return 1
    }
  else
    proposal=$(mktemp "${TMPDIR:-/tmp}/fm-afk-contract-compile.XXXXXX") || return 1
    fm_afk_contract_render_body "$entered" "$entered_epoch" > "$proposal" || { rm -f "$proposal"; return 1; }
  fi
  refused=$(fm_afk_contract_read_list "$proposal" refused | grep -c . || true)
  [ "$refused" -eq 0 ] || rc=3
  if [ "$write" -eq 1 ]; then
    fm_afk_contract_render_readback "$proposal" 'Away posture read-back (proposed, not yet confirmed):'
    printf 'Say go to confirm; restate any refused clause first if you want it recorded.\n'
  else
    fm_afk_contract_render_readback "$proposal" 'Away posture read-back (compiled, not written):'
    rm -f "$proposal"
  fi
  return "$rc"
}

fm_afk_contract_cmd_confirm() {
  local record proposal body confirmed confirmed_epoch archived
  record=$(fm_afk_contract_path)
  proposal=$(fm_afk_contract_proposal_path)
  confirmed=$(fm_afk_contract_now_iso)
  confirmed_epoch=$(date +%s)
  if [ -f "$proposal" ]; then
    fm_afk_contract_validate "$proposal" 0 || return 1
    if [ -f "$record" ]; then
      archived=$(fm_afk_contract_cmd_archive) || return 1
      fm_afk_contract_log "replaced the earlier away posture; its record is archived at $archived"
    fi
    body=$(cat "$proposal")
  elif [ -f "$record" ]; then
    fm_afk_contract_validate "$record" 1 || return 1
    fm_afk_contract_log "away posture already recorded at $(fm_afk_contract_read_field "$record" entered); nothing to confirm"
    fm_afk_contract_render_announcement "$record"
    return 0
  else
    WORDS=; CLAUSES=; EXPECTED_RETURN=-; SPEND=$FM_AFK_CONTRACT_SPEND_DEFAULT
    body=$(fm_afk_contract_render_body "$confirmed" "$confirmed_epoch")
  fi
  {
    printf '%s\n' "$body" | awk '/^words: /{exit} {print}'
    printf 'confirmed: %s\nconfirmed_epoch: %s\n' "$confirmed" "$confirmed_epoch"
    printf '%s\n' "$body" | awk 'p{print} /^words: /{p=1; print}'
  } | fm_afk_contract_write_atomic "$record" || {
    fm_afk_contract_log "failed to write the away-posture record at $record"
    return 1
  }
  rm -f "$proposal"
  fm_afk_contract_render_announcement "$record"
}

fm_afk_contract_cmd_archive() {
  local record dir entered_epoch target
  record=$(fm_afk_contract_path)
  [ -f "$record" ] || return 0
  dir=$(fm_afk_contract_archive_dir)
  mkdir -p "$dir" || return 1
  entered_epoch=$(fm_afk_contract_read_field "$record" entered_epoch)
  case "$entered_epoch" in ''|*[!0-9]*) entered_epoch=$(date +%s) ;; esac
  target="$dir/$entered_epoch.afk-contract"
  if [ -e "$target" ]; then
    target="$dir/$entered_epoch-$(date +%s)-$$.afk-contract"
  fi
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
    compile) fm_afk_contract_cmd_compile 0 "$@" ;;
    propose) fm_afk_contract_cmd_compile 1 "$@" ;;
    confirm) [ "$#" -eq 0 ] || { fm_afk_contract_usage >&2; return 2; }; fm_afk_contract_cmd_confirm ;;
    discard-proposal) rm -f "$(fm_afk_contract_proposal_path)" ;;
    present) fm_afk_contract_present ;;
    announce)
      path=$(fm_afk_contract_path)
      fm_afk_contract_validate "$path" 1 || return 1
      fm_afk_contract_render_announcement "$path" ;;
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
