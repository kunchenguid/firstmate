#!/usr/bin/env bash
# fm-afk-contract.sh - the one owner of the away-posture record: its schema, the
# captain's away words recorded verbatim, the read-back rendering, the entry
# announcement, and the archive at return.
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
# THE RECORD IS THE WORDS. The captain's away words are the whole mandate: they
# are recorded verbatim, read back as plain sentences by firstmate before the
# captain says go, and acted on by the supervision session's own judgment at the
# moment an event makes them relevant, through the guarded scripts and under the
# standing authority it already has (bin/fm-branch-prompt.sh "Postures" owns the
# execution rules). NO PARSER, TOKENIZER, CLASSIFIER, OR GRAMMAR READS THE WORDS
# HERE, BY THE CAPTAIN'S MANDATE: this script never tokenizes, classifies, or
# semantically validates them, records no clause fields, ids, or verbs, and keeps
# no per-task merge-grant list. What stays mechanical is exactly what a script can
# check without reading words: a merge green at its live head under this record's
# lock, synchronous merges only, the spend cap, and the never-set.
# HARD RULE: destructive, irreversible, and security-sensitive actions are never
# pre-authorizable whatever the words say.
#
# RECORD (state/.afk-contract; written only by this script; YAML-shaped so a
# human can read it, but parsed only here - consumers use the read subcommands):
#   version: 2
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
# The words block runs to the end of a version 2 record; in a version 1 record
# only its legacy clauses:, refused:, and merge_grants: sections end it. Any
# other line after the header that is not a stored line is damage, not a
# boundary, so a truncated mandate can never read as a whole one.
# A version 1 record (the retired clause model) still validates and reads: its
# scalar fields and words are read exactly as above, and its clauses:, refused:,
# and merge_grants: sections are ignored, so an upgrade never breaks a live away
# window. Only version 2 is ever written.
# A proposal (state/.afk-contract.proposed) has the same shape without the
# confirmed fields; confirmation stamps the first entry time. Archived final
# records live under state/afk-contracts/ as <entered_epoch>.afk-contract, and
# replaced mandates use <entered_epoch>-superseded-<confirmed_epoch>.afk-contract.
# A replacement carries the original session entry forward. Durable
# archive-chain identity and same-second session identity are deferred, with no
# owner: no incident motivates them.
#
# Usage:
#   fm-afk-contract.sh propose [--words-file <path> | --words <text>]
#       [--expected-return <UTC ISO 8601>] [--spend <n>]
#     Write the proposal, then print the read-back. Exit 0 on success and 2 on a
#     usage error. --words-file keeps the file's bytes verbatim, trailing
#     newlines included.
#   fm-afk-contract.sh confirm
#     Promote the proposal into the record with the confirmed timestamp and
#     print the entry announcement. A proposal is required when no confirmed
#     record exists; an existing record with no proposal is a no-op refresh.
#     A replacement is staged before the prior record is archived and replaced.
#   fm-afk-contract.sh readback [--proposal]
#     The record's content for the captain and for the away session: the words
#     verbatim plus the entry time, expected return, spend cap, and reach line.
#   fm-afk-contract.sh field <name> [--proposal]
#   fm-afk-contract.sh words [--proposal | --path <record>]
#   fm-afk-contract.sh validate [--proposal | --path <record>]  exit 0 when the record is readable and, for a record, confirmed
#   fm-afk-contract.sh archive              move the record aside; print its path
#   fm-afk-contract.sh archived <entered_epoch>   print that archived record's path
#
# CROSS-SUBSYSTEM LOCK (state/.afk-contract.lock; this script is its one owner).
# This record is authority another subsystem reads and then ACTS on outside this
# script: bin/fm-pr-merge.sh reads the record's presence as away merge authority
# and afterwards hands a merge to the forge. A publication, replacement, or
# archive landing between that read and the forge handoff would land a merge on
# authority that no longer holds, so the two subsystems share one lock instead of
# each locking its own records: the record-mutating subcommands (confirm,
# archive) hold it across their mutation, and a reader that acts on the record
# holds it across both its read and that action (fm_afk_contract_lock_hold /
# fm_afk_contract_lock_release). The read-only subcommands never take it, so a
# holder can still read the record it locked. Neither side ever proceeds without
# it: the acquire is bounded, and a bound that is hit refuses and names the live
# holder rather than racing. That fixed bound is 120 seconds, sized so only a
# genuinely wedged holder trips it. A lock left by a killed process is reclaimed
# by the ordinary stale-owner recovery in bin/fm-wake-lib.sh, which owns the lock
# primitive itself.
#
# Sourceable: with the BASH_SOURCE guard, other scripts get the path, presence,
# and lock helpers (fm_afk_contract_path, fm_afk_contract_present,
# fm_afk_contract_proposal_path, fm_afk_contract_archive_dir,
# fm_afk_contract_lock_hold, fm_afk_contract_lock_release) without running main.
set -u

FM_AFK_CONTRACT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$FM_AFK_CONTRACT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
FM_AFK_CONTRACT_STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-classify-lib.sh
. "$FM_AFK_CONTRACT_DIR/fm-classify-lib.sh"

FM_AFK_CONTRACT_VERSION=2
# Older record versions this script still reads (never writes).
FM_AFK_CONTRACT_READABLE_VERSIONS="1 2"
FM_AFK_CONTRACT_REACH_ANNOUNCED='No phone channel is configured; anything that needs you waits for your return.'
FM_AFK_CONTRACT_SPEND_DEFAULT=4
# Generous against the longest legitimate holder, a merge waiting on the forge,
# so the bound only ever trips on something genuinely wedged.
_FM_AFK_CONTRACT_LOCK_TIMEOUT=120
FM_AFK_CONTRACT_LOCK_HELD=

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

fm_afk_contract_lock_path() {  # [state-dir]
  printf '%s/.afk-contract.lock' "${1:-$FM_AFK_CONTRACT_STATE}"
}

# Lazily reach the lock primitive. bin/fm-wake-lib.sh is a canonical lint root
# in its own right, so keep this an analysis boundary for the same reason
# bin/fm-lease-lib.sh's fm_lease_lock_helpers does.
fm_afk_contract_lock_helpers() {
  command -v fm_lock_acquire_wait_bounded >/dev/null 2>&1 && return 0
  # shellcheck source=/dev/null
  . "$FM_AFK_CONTRACT_DIR/fm-wake-lib.sh"
}

# fm_afk_contract_lock_hold [state-dir]: take the cross-subsystem lock described
# in the header. The acquire is bounded so a wedged holder is refused instead of
# blocking a merge or a captain return forever, and returns 1 WITHOUT the lock so
# every caller refuses rather than proceeding unlocked.
fm_afk_contract_lock_hold() {  # [state-dir]
  local lock rc=0 STATE timeout
  STATE=${1:-$FM_AFK_CONTRACT_STATE}
  lock=$(fm_afk_contract_lock_path "$STATE")
  timeout=${FM_TEST_AFK_CONTRACT_LOCK_TIMEOUT:-$_FM_AFK_CONTRACT_LOCK_TIMEOUT}
  fm_afk_contract_lock_helpers || {
    fm_afk_contract_log "could not load the lock primitive for $lock"
    return 1
  }
  fm_lock_acquire_wait_bounded "$lock" "$timeout" || rc=$?
  if [ "$rc" -ne 0 ]; then
    if [ "$rc" -eq 124 ] && [ -n "${FM_LOCK_HELD_PID:-}" ]; then
      fm_afk_contract_log "the away-posture record is locked by live process $FM_LOCK_HELD_PID (an in-flight merge, or another change to this record); nothing was changed"
    else
      fm_afk_contract_log "could not take the away-posture record lock at $lock; nothing was changed"
    fi
    return 1
  fi
  FM_AFK_CONTRACT_LOCK_HELD=$lock
}

# Release the lock taken by fm_afk_contract_lock_hold. Idempotent, so callers can
# invoke it unconditionally from their own cleanup.
fm_afk_contract_lock_release() {
  local lock=$FM_AFK_CONTRACT_LOCK_HELD
  [ -n "$lock" ] || return 0
  FM_AFK_CONTRACT_LOCK_HELD=
  fm_afk_contract_lock_helpers || return 1
  fm_lock_release "$lock"
}

fm_afk_contract_log() { printf 'fm-afk-contract: %s\n' "$*" >&2; }

fm_afk_contract_usage() {
  sed -n '/^# Usage:/,/^# CROSS-SUBSYSTEM LOCK/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
}

fm_afk_contract_now_iso() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# --- record writing ---------------------------------------------------------

fm_afk_contract_validate_iso() {  # <ts>
  fm_utc_iso_to_epoch "$1" >/dev/null 2>&1
}

# Render a record body on stdout (everything except the confirmed fields).
# Inputs: WORDS (verbatim), EXPECTED_RETURN, SPEND.
fm_afk_contract_render_body() {  # <entered-iso> <entered-epoch>
  local entered=$1 entered_epoch=$2
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

# The words block runs from its header to the end of a version 2 record, and in a
# version 1 record to one of its legacy sections. Every stored line carries the
# two-space record prefix; anything else there is damage, and reading refuses
# rather than returning the mandate truncated at the damage.
fm_afk_contract_read_words() {  # <path>
  local path=$1 version
  [ -f "$path" ] || return 1
  version=$(fm_afk_contract_read_field "$path" version)
  awk -v record="$path" -v version="$version" '
    function die(reason) {
      printf "fm-afk-contract: record %s has an invalid words block: %s\n", record, reason > "/dev/stderr"
      bad = 1
      exit 2
    }
    /^words: \|$/ && !found { found = inwords = 1; keep_final = 1; next }
    /^words: \|-$/ && !found { found = inwords = 1; keep_final = 0; next }
    /^words: -$/ && !found { found = scalar = 1; next }
    !found { next }
    /^[^ ]/ {
      if (version != "1" || ($0 != "clauses:" && $0 != "refused:" && $0 != "merge_grants:")) {
        die("the line after the stored words is neither a stored line nor a section this record version ends the block at: " $0)
      }
      if (inwords && count == 0) die("the block indicator has no stored lines")
      exit
    }
    inwords && /^  / { lines[++count] = substr($0, 3); next }
    { die("a line after the words field is not a stored line with its two-space record prefix") }
    END {
      if (bad) exit 2
      if (!found) die("the words field is missing")
      if (inwords && count == 0) die("the block indicator has no stored lines")
      for (i = 1; i <= count; i++) {
        printf "%s", lines[i]
        if (i < count || keep_final) printf "\n"
      }
    }
  ' "$path"
}

# A record is valid when its version is one this script reads and the required
# scalar fields and words block are present. Refuses rather than guessing at a
# foreign schema. A version 1 record's clause and grant sections are ignored.
fm_afk_contract_validate() {  # <path> <require-confirmed 0|1>
  local path=$1 require_confirmed=$2 version entered entered_epoch expected reach announced spend words_header confirmed
  [ -f "$path" ] || return 1
  version=$(fm_afk_contract_read_field "$path" version)
  case " $FM_AFK_CONTRACT_READABLE_VERSIONS " in
    *" $version "*) ;;
    *)
      fm_afk_contract_log "record $path carries version '${version:-none}', expected one of ${FM_AFK_CONTRACT_READABLE_VERSIONS// /, }; refusing to read it"
      return 1 ;;
  esac
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
}

# --- rendering --------------------------------------------------------------

# The read-back is the record's content and nothing else: the words verbatim
# beside the entry time, expected return, spend cap, and reach line. Firstmate's
# plain-sentence restatement is spoken in chat, and the execution rules live in
# bin/fm-branch-prompt.sh, so this render stays a faithful mirror of the record
# for the captain at entry and for the away session on every wake.
fm_afk_contract_render_readback() {  # <path> <title>
  local path=$1 title=$2 words expected spend
  expected=$(fm_afk_contract_read_field "$path" expected_return)
  spend=$(fm_afk_contract_read_field "$path" spend_max_concurrent_workers)
  printf '%s\n' "$title"
  printf '  entered: %s\n' "$(fm_afk_contract_read_field "$path" entered)"
  printf '  expected return: %s\n' "$( [ "$expected" = - ] && printf 'not given' || printf '%s' "$expected")"
  printf '  spend cap: %s concurrent workers\n' "$spend"
  printf '  reach: hold-for-return only. %s\n' "$(fm_afk_contract_read_field "$path" reach_announced)"
  words=$(fm_afk_contract_read_words "$path"; rc=$?; printf x; exit "$rc") || return 1
  words=${words%x}
  if [ -n "$words" ]; then
    printf '  your words (verbatim):\n'
    printf '%s' "$words" | sed 's/^/    /'
    case "$words" in *$'\n') ;; *) printf '\n' ;; esac
  else
    printf '  your words: (none)\n'
  fi
}

fm_afk_contract_render_announcement() {  # <path>
  local path=$1 expected words mandate_text
  expected=$(fm_afk_contract_read_field "$path" expected_return)
  words=$(fm_afk_contract_read_words "$path"; rc=$?; printf x; exit "$rc") || return 1
  words=${words%x}
  if [ -n "$words" ]; then
    mandate_text='Your away instructions are recorded verbatim; the away session will carry them out where it can, and anything it is unsure of, or that needs you, waits for your return.'
  else
    mandate_text='No away instructions were recorded; the away session acts on standing authority only, and anything that needs you waits for your return.'
  fi
  printf 'Away posture confirmed at %s: hold-for-return only. %s %s Destructive, irreversible, and security-sensitive actions are never pre-authorizable, whatever the words say. Expected return: %s. Spend cap: %s concurrent workers.\n' \
    "$(fm_afk_contract_read_field "$path" confirmed)" \
    "$(fm_afk_contract_read_field "$path" reach_announced)" \
    "$mandate_text" \
    "$( [ "$expected" = - ] && printf 'not given' || printf '%s' "$expected")" \
    "$(fm_afk_contract_read_field "$path" spend_max_concurrent_workers)"
}

# --- subcommands ------------------------------------------------------------

fm_afk_contract_parse_inputs() {  # <args...>; sets WORDS, EXPECTED_RETURN, SPEND
  local words_file=''
  WORDS=; EXPECTED_RETURN=-; SPEND=$FM_AFK_CONTRACT_SPEND_DEFAULT
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
      --action|--object|--when|--stop|--grant|--grant=*)
        fm_afk_contract_log "$1 was retired: the captain's away words are the whole mandate, so pass them with --words or --words-file and nothing else"
        return 2 ;;
      *)
        fm_afk_contract_log "unknown option '$1'"
        return 2 ;;
    esac
  done
  if [ -n "$words_file" ]; then
    [ -f "$words_file" ] || { fm_afk_contract_log "words file not found: $words_file"; return 2; }
    # Command substitution strips trailing newlines; the sentinel keeps the
    # file's bytes verbatim, trailing newlines included.
    WORDS=$(cat "$words_file"; rc=$?; printf x; exit "$rc") || return 1
    WORDS=${WORDS%x}
  fi
  return 0
}

fm_afk_contract_cmd_propose() {
  local entered entered_epoch proposal
  fm_afk_contract_parse_inputs "$@" || return 2
  entered=$(fm_afk_contract_now_iso)
  entered_epoch=$(date +%s)
  proposal=$(fm_afk_contract_proposal_path)
  fm_afk_contract_render_body "$entered" "$entered_epoch" | fm_afk_contract_write_atomic "$proposal" || {
    fm_afk_contract_log "failed to write the proposal at $proposal"
    return 1
  }
  fm_afk_contract_render_readback "$proposal" 'Away posture read-back (proposed, not yet confirmed):' || return 1
  printf 'Say go to confirm; restate your instructions first if this reading is not what you meant.\n'
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
    fm_afk_contract_render_announcement "$record" || return 1
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
  fm_afk_contract_render_announcement "$record" || return 1
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

# The record-mutating subcommands run inside the cross-subsystem lock, so no
# publication, replacement, or archive can land between another subsystem's
# authority read and the action it takes on that authority.
fm_afk_contract_locked_cmd() {  # <command> [args...]
  local rc=0
  fm_afk_contract_lock_hold || return 1
  trap 'fm_afk_contract_lock_release || true' EXIT
  "$@" || rc=$?
  trap - EXIT
  fm_afk_contract_lock_release || true
  return "$rc"
}

fm_afk_contract_main() {
  local cmd=${1:-} path
  [ -n "$cmd" ] || { fm_afk_contract_usage >&2; return 2; }
  shift
  case "$cmd" in
    propose) fm_afk_contract_cmd_propose "$@" ;;
    confirm)
      [ "$#" -eq 0 ] || { fm_afk_contract_usage >&2; return 2; }
      fm_afk_contract_locked_cmd fm_afk_contract_cmd_confirm ;;
    readback)
      path=$(fm_afk_contract_select_path "$@") || { fm_afk_contract_usage >&2; return 2; }
      [ -f "$path" ] || { fm_afk_contract_log "no record at $path"; return 1; }
      if [ "$path" = "$(fm_afk_contract_proposal_path)" ]; then
        fm_afk_contract_render_readback "$path" 'Away posture read-back (proposed, not yet confirmed):' || return 1
      else
        fm_afk_contract_render_readback "$path" 'Away posture (confirmed):' || return 1
      fi ;;
    field)
      [ "$#" -ge 1 ] || { fm_afk_contract_usage >&2; return 2; }
      local name=$1; shift
      path=$(fm_afk_contract_select_path "$@") || { fm_afk_contract_usage >&2; return 2; }
      fm_afk_contract_read_field "$path" "$name" ;;
    words)
      path=$(fm_afk_contract_select_path "$@") || { fm_afk_contract_usage >&2; return 2; }
      fm_afk_contract_read_words "$path" ;;
    validate)
      path=$(fm_afk_contract_select_path "$@") || { fm_afk_contract_usage >&2; return 2; }
      if [ "$path" = "$(fm_afk_contract_proposal_path)" ]; then
        fm_afk_contract_validate "$path" 0
      else
        fm_afk_contract_validate "$path" 1
      fi ;;
    clauses|flags|refused|grants)
      fm_afk_contract_log "'$cmd' was retired with the clause and merge-grant apparatus: the record is the captain's words (read them with 'words' or 'readback')"
      return 2 ;;
    archive) fm_afk_contract_locked_cmd fm_afk_contract_cmd_archive ;;
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
