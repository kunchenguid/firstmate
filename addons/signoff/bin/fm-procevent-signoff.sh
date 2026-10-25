#!/usr/bin/env bash
# sign-off adapter for the generic process-to-event runner: captain answers
# given on a sign-off board come in, and captain holds go out as board cards.
#
# Usage:
#   fm-procevent-signoff.sh arm
#   fm-procevent-signoff.sh retire
#   fm-procevent-signoff.sh raise <task-id> <title> <reason> <done|release>
#   fm-procevent-signoff.sh poll
#   fm-procevent-signoff.sh answers <result-file>
#   fm-procevent-signoff.sh ack <result-file>
#   fm-procevent-signoff.sh relisten
#
# arm        Opt this home in: check that sign-off-axi runs, bind the source to
#            the keyed-answer intake (bin/fm-captain-hold.sh bind), and register
#            the `signoff` source with bin/fm-procevent.sh. Nothing here runs
#            until a home arms it, so an unarmed home behaves exactly as before.
#            Arming is per home; secondmate homes arm themselves.
# retire     Opt out: retire the registration and drop the binding.
# raise      Called by `fm-captain-hold.sh hold` after a hold is recorded. While
#            enabled it raises one board card keyed by this home's tag, the task
#            id and the hold-set stamp, when an authored owner ask exists.
#            The ask-default authoring boundary supplies the question,
#            context and choices; it refuses an absent or invalid owner ask.
#            No backlog title or hold reason is published. A failure, including a missing
#            sign-off-axi, exits nonzero with sign-off's own output; the caller
#            warns and keeps the hold.
# poll       The blocking child the runner executes; never run it in a
#            conversational turn. It prints one JSON object per line for each
#            deliverable answer, `{"key","card","answer","label","close","at"}` with the
#            bare task id as key and its board card as card, and exits 0. With nothing deliverable it blocks
#            in `sign-off-axi wait` for up to 600 seconds, rests when still
#            nothing is deliverable, and exits 75 with no output, the runner's
#            clean empty wait, so `relisten` polls again.
# answers    This adapter's half of the keyed-answer contract in
#            bin/fm-procevent.sh: read the captured poll lines and print
#            `<task-id>\t<answer>\t<label>\t<close>` for each, with tabs and
#            newlines inside the answer or label turned into spaces (the intake
#            stores them that way too). It records nothing.
# ack        Run by the runner only after the keyed-answer intake exits 0 or 3 for
#            this result: it records each answer in the captured poll lines as
#            delivered. The intake exits 0 when every answer was taken, and 3 when
#            every skip is permanent (the reserved reconcile value, already closed,
#            not held for the captain, unknown close mode, migrated hold whose marker
#            line matches several rows), so only a transient skip or failure leaves
#            an answer undelivered; a migrated-hold scan that cannot read its graph,
#            or an ambiguous configured-prefix match, is transient.
#
# Read mark: the runner announces each captured result to this home's handler (Main,
# or the lead in a secondmate home), who concludes it with `bin/fm-procevent.sh
# handled signoff <sequence>`. That is the pickup of the note carrying the owner's
# answer, so each poll round runs `sign-off-axi feedback <card> <board.json> --read`
# for every card in a handled captured result, on the board `sign-off-axi status`
# names. It reads the captured results, not `ack`, because the runner runs `answers`
# and `ack` from the Firstmate checkout's own adapter. A card is marked once per
# result; sign-off's NOT_FOUND counts as done, and a sign-off-axi older than 0.6.1
# (no feedback command) skips with one log line.
#
# An answer is deliverable only when its key carries this home's tag, its bare
# task id is one this home still holds for the captain (`fm-captain-hold.sh
# open --identity`), its key names that hold's current stamp, and it was not
# already acknowledged. The open hold is the cursor: an answer saved while no
# poll ran is still found on the next round, and an answer on an earlier card
# never resolves a re-held task. An answer the intake fails on, or skips for a transient reason, stays
# deliverable and is offered again on the next round. Answers on the same board from other
# agents are never read as Firstmate's. What an answer DOES is owned by the
# keyed-answer intake in bin/fm-captain-hold.sh; this adapter maps nothing and
# closes nothing.
#
# Board keys are `fm-<tag>-<task-id>-<stamp>`, where <tag> is a stable digest of
# FM_HOME and <stamp> is the hold-set stamp in alphanumerics only. The default
# board is shared by every home on the machine, so the tag keeps one home from
# being handed another home's answer, and the stamp gives each hold occurrence
# its own card. sign-off-axi must be on PATH: without it `arm`
# refuses, and `raise` prints an install hint and fails, so a hold is kept and
# only warns. Cards and answers use sign-off's default board
# (~/.sign-off/decisions.json), the one `sign-off-axi open` shows.
# ponytail: one default board per machine; add a board option when a home needs its own.
# sign-off-axi has no command to withdraw a card, so a hold answered through
# another channel leaves its card waiting on the board.
set -u

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# The Firstmate checkout owns the runner, the keyed-answer intake and the libraries.
# FM_CODE_ROOT defaults to FM_HOME, the checkout a home runs from (as in the sentinel wrapper).
CODE_ROOT="${FM_CODE_ROOT:-${FM_HOME:-}}"
BIN="$CODE_ROOT/bin"
if [ -z "$CODE_ROOT" ] || [ ! -f "$BIN/fm-procevent-lib.sh" ]; then
  echo "fm-procevent-signoff: no Firstmate checkout with bin/fm-procevent-lib.sh; set FM_CODE_ROOT" >&2
  exit 2
fi
FM_HOME="${FM_HOME:-$CODE_ROOT}"
STATE=${FM_STATE_OVERRIDE:-"$FM_HOME/state"}
export FM_HOME

. "$BIN/fm-pr-lib.sh"
. "$BIN/fm-wake-lib.sh"
. "$BIN/fm-procevent-lib.sh"

# These adapters do not themselves call Claude; when a pool is configured,
# downstream tools inherit its account rather than an ambient default login.
# shellcheck source=account-pool/bin/fm-pool-claude-env.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/account-pool/bin/fm-pool-claude-env.sh"
# shellcheck source=signoff/bin/fm-signoff-feedback-lib.sh
. "$SCRIPT_DIR/fm-signoff-feedback-lib.sh"
if [ -f "$FM_HOME/config/account-pool" ]; then fm_pool_claude_env || exit 1; fi

SOURCE_ID=signoff
DELIVERED="$STATE/signoff-delivered"
# <card>\t<result sequence> for each card marked Read.
READ="$STATE/signoff-read-marked"
# How long a round rests when nothing is deliverable after a wait (no board yet,
# nothing waiting, or the tool failing), so an idle home does not spin.
IDLE_REST=30
WAIT_SECS=600

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
  exit 2
}
die() { printf "error: %s\n" "$1" >&2; exit 1; }

signoff() {
  command -v sign-off-axi >/dev/null 2>&1 \
    || { printf 'sign-off-axi is not on PATH; install it from https://github.com/umeranjum17/sign-off\n' >&2; return 127; }
  sign-off-axi "$@"
}

home_key_prefix() {
  printf 'fm-%s-' "$(printf '%s' "$FM_HOME" | cksum | awk '{printf "%08x", $1}')"
}

stamp_token() { printf '%s' "$1" | tr -cd 'A-Za-z0-9'; }

cmd_enabled() { [ -f "$(fm_procevent_registry_dir "$STATE")/$SOURCE_ID.source" ]; }

cmd_arm() {
  local out
  out=$(signoff --version 2>&1) \
    || die "sign-off-axi does not run here: $out"
  "$BIN/fm-captain-hold.sh" bind "$SOURCE_ID" >/dev/null || die "could not bind $SOURCE_ID to the keyed-answer intake"
  "$BIN/fm-procevent.sh" register signoff "$SOURCE_ID" -- "$SCRIPT_DIR/fm-procevent-signoff.sh" poll || exit 1
  printf 'armed: %s\nsign-off-axi: %s\n' "$SOURCE_ID" "$out"
}

cmd_retire() {
  "$BIN/fm-procevent.sh" retire "$SOURCE_ID" || exit 1
  "$BIN/fm-captain-hold.sh" unbind "$SOURCE_ID" >/dev/null || exit 1
}

cmd_raise() {
  [ $# -eq 4 ] || usage
  local out identity
  cmd_enabled || return 0
  identity=$("$BIN/fm-captain-hold.sh" open "$1" --identity 2>/dev/null) || {
    printf 'sign-off card not raised: the hold identity of %s could not be read\n' "$1" >&2
    return 1
  }
  out=$(python3 "$SCRIPT_DIR/../../ask-default/bin/fm-captain-ask.py" post "$1" \
    "$(home_key_prefix)$1-$(stamp_token "${identity%%#*}")" "$4" 2>&1) || {
    printf 'sign-off card refused: %s\n' "$out" >&2
    return 1
  }
  case "$out" in
    *"already answered"*)
      printf 'sign-off already holds an answered card under %s; this hold has no live card\n' "$1" >&2
      return 1
      ;;
  esac
  printf 'sign-off card on the board for %s\n' "$1" >&2
}

# Print every deliverable answer as one JSON object per line, keyed by bare task id.
deliverable() {
  local json prefix line key stamp answer at identity
  prefix=$(home_key_prefix)
  json=$(signoff answers --json 2>/dev/null) || return 0
  printf '%s\n' "$json" \
    | jq -c --arg prefix "$prefix" '
        to_entries[] | select(.key | startswith($prefix))
        | (.key[($prefix | length):]) as $rest
        | {key: ($rest | sub("-[^-]*$"; "")), card: .key, stamp: ($rest | sub("^.*-"; "")), answer: (.value.answer // ""), label: (.value.label // ""), close: (.value.close // ""), at: (.value.at // "")}' 2>/dev/null \
    | while IFS= read -r line ; do
        key=$(jq -r '.key' <<<"$line")
        stamp=$(jq -r '.stamp' <<<"$line")
        answer=$(jq -r '.answer' <<<"$line")
        at=$(jq -r '.at' <<<"$line")
        fm_procevent_source_id_valid "$key" && [ -n "$answer" ] && [ -n "$at" ] || continue
        [ ! -f "$DELIVERED" ] || ! grep -qxF "$key"$'\t'"$at" "$DELIVERED" || continue
        identity=$("$BIN/fm-captain-hold.sh" open "$key" --identity 2>/dev/null) || continue
        [ "$stamp" = "$(stamp_token "${identity%%#*}")" ] || continue
        jq -c 'del(.stamp)' <<<"$line"
      done
}

# Mark Read each card in a captured result the handler concluded (see the header).
mark_read() {
  local result seq card rc board='' old=0
  for result in "$(fm_procevent_inbox_dir "$STATE")/$SOURCE_ID".*.result; do
    seq=$(fm_procevent_result_sequence "$result")
    fm_procevent_is_handled "$STATE" "$SOURCE_ID" "$seq" || continue
    while IFS= read -r card; do
      [ ! -f "$READ" ] || ! grep -qxF "$card"$'\t'"$seq" "$READ" || continue
      [ -n "$board" ] || board=$(signoff status --json 2>/dev/null | jq -r '.board // empty' 2>/dev/null)
      [ -n "$board" ] || return 0
      rc=0
      fm_signoff_feedback "$card" "$board" --read || rc=$?
      case $rc in
        0) ;;
        3) old=1 ;;
        *) continue ;;
      esac
      printf '%s\t%s\n' "$card" "$seq" >> "$READ"
    done < <(jq -r '.card // empty' "$result" 2>/dev/null)
  done
  [ "$old" -eq 0 ] || printf 'sign-off-axi has no feedback command (needs 0.6.1+); answered cards were not marked Read\n' >&2
}

cmd_poll() {
  local found
  [ $# -eq 0 ] || usage
  mark_read
  found=$(deliverable)
  if [ -z "$found" ]; then
    signoff wait --json --timeout "$WAIT_SECS" >/dev/null 2>&1
    mark_read
    found=$(deliverable)
    [ -n "$found" ] || sleep "$IDLE_REST"
  fi
  [ -n "$found" ] || exit 75
  printf "%s\n" "$found"
}

cmd_answers() {
  local file=${1-} line key answer at
  [ -f "$file" ] || die "result file does not exist: ${file}"
  while IFS= read -r line ; do
    key=$(jq -r '.key' <<<"$line")
    answer=$(jq -r '.answer' <<<"$line")
    at=$(jq -r '.at' <<<"$line")
    fm_procevent_source_id_valid "$key" && [ -n "$answer" ] && [ -n "$at" ] || continue
    jq -r '[.key, .answer, .label, .close] | map(gsub("[\n\r\t]"; " ")) | join("\t")' <<<"$line"
  done < "$file"
}

cmd_ack() {
  local file=${1-} line key at
  [ -f "$file" ] || die "result file does not exist: ${file}"
  while IFS= read -r line ; do
    key=$(jq -r '.key' <<<"$line")
    at=$(jq -r '.at' <<<"$line")
    fm_procevent_source_id_valid "$key" && [ -n "$at" ] || continue
    printf '%s\t%s\n' "$key" "$at" >> "$DELIVERED"
  done < "$file"
}

case "${1-}" in
  arm) shift; cmd_arm "$@" ;;
  retire) shift; cmd_retire "$@" ;;
  raise) shift; cmd_raise "$@" ;;
  poll) shift; cmd_poll "$@" ;;
  answers) shift; cmd_answers "$@" ;;
  ack) shift; cmd_ack "$@" ;;
  relisten) exit 0 ;;
  -h|--help|help|'') usage ;;
  *) die "unknown command: ${1}" ;;
esac
