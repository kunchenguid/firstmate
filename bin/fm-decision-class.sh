#!/usr/bin/env bash
# fm-decision-class.sh - deterministic D0-D3 decision classification.
#
# The platform previously treated "the agent is uncertain" and "only the operator
# may decide" as the same thing, so any hard engineering call became an operator
# gate. This script separates them structurally rather than by convention:
#
#   AUTHORITY inputs (reserved-authority predicates) are the ONLY inputs that can
#   produce D3. They are read first, into one reserved/delegated verdict.
#   CAPABILITY inputs (confidence, novelty, number of reasonable options, blast
#   radius) are read second and can only ever choose between D0, D1 and D2.
#
# Because the capability inputs are consulted only after the authority verdict is
# already delegated, no combination of low confidence, novelty, or several
# reasonable choices can produce D3. That is a property of the control flow, not
# a rule an agent has to remember, and tests/fm-away-decision-class.test.sh
# asserts it exhaustively over the capability input space.
#
# Tiers (commission "Separate reasoning escalation from authority escalation"):
#   D0  an accepted rule, invariant or standing precedent determines the answer.
#   D1  delegated engineering judgment: in-architecture, reversible, contained.
#   D2  still delegated, but ambiguous, novel, broad or high-value enough to be
#       worth assisted judgment before firstmate makes the disposition.
#   D3  operator-reserved.
#
# Usage:
#   fm-decision-class.sh classify [options]
#
# Authority inputs (yes|no, default no unless noted; any yes reserves the
# decision to the operator):
#   --reassigns-authority     changes who owns an authority or architecture
#   --constitutional          constitutional change, or a contradiction in
#                             accepted architecture
#   --operator-reserved-gate  a Decision Gate explicitly reserved to human
#                             judgment
#   --credentials             credentials or other sensitive approval
#   --external-effect         material financial or external side effects
#   --destructive             destructive action beyond standing authority
#   --weakens-certification   weakens certification ownership or ordering
#   --reversible yes|no       default yes; `no` reserves unless a standing rule
#                             already covers it
#   --within-architecture yes|no  default yes
#   --pbe-resolved yes|no     default no; consulted only when
#                             --within-architecture no, and `yes` means an
#                             existing primitive can be populated instead of
#                             expanding, so the decision is back in-architecture
#
# Determinism input:
#   --standing-rule <ref>     an accepted rule, invariant, test, lifecycle
#                             transition or standing precedent that determines
#                             the answer; `none` (default) means none applies
#
# Capability inputs (never sufficient for D3):
#   --confidence high|medium|low     default high
#   --novel yes|no                   default no
#   --options <n>                    number of reasonable choices, default 1
#   --blast-radius contained|broad   default contained
#
# Binding and evidence:
#   --task <id>    the work object the decision arose from
#   --key <slug>   stable decision key, unique within that work object
#   --record       append the classification to the current away-session ledger
#                  (requires --task and --key)
#
# Prints tier=, authority=, routing=, next=, escalators= and reason= lines, and
# exits 0. Invalid input exits 2. This script classifies only: creating the
# durable operator hold stays with bin/fm-decision-hold.sh, and pausing dependent
# work stays with bin/fm-away-continuation.sh.
set -u

FM_DECISION_CLASS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-away-lib.sh
. "$FM_DECISION_CLASS_DIR/fm-away-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "${BASH_SOURCE[0]}"
}

fail() {
  printf 'fm-decision-class: %s\n' "$*" >&2
  exit 2
}

want_bool() {  # <flag> <value>
  case "$2" in
    yes|no) printf '%s' "$2" ;;
    *) fail "$1 must be yes or no: $2" ;;
  esac
}

command_classify() {
  local reassigns=no constitutional=no reserved_gate=no credentials=no
  local external=no destructive=no weakens=no reversible=yes
  local within=yes pbe=no standing=none
  local confidence=high novel=no options=1 blast=contained
  local task='' key='' record=0
  local authority=delegated tier reason='' escalators='' routing next session

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --reassigns-authority) shift; reassigns=$(want_bool --reassigns-authority "${1:-}") ;;
      --constitutional) shift; constitutional=$(want_bool --constitutional "${1:-}") ;;
      --operator-reserved-gate) shift; reserved_gate=$(want_bool --operator-reserved-gate "${1:-}") ;;
      --credentials) shift; credentials=$(want_bool --credentials "${1:-}") ;;
      --external-effect) shift; external=$(want_bool --external-effect "${1:-}") ;;
      --destructive) shift; destructive=$(want_bool --destructive "${1:-}") ;;
      --weakens-certification) shift; weakens=$(want_bool --weakens-certification "${1:-}") ;;
      --reversible) shift; reversible=$(want_bool --reversible "${1:-}") ;;
      --within-architecture) shift; within=$(want_bool --within-architecture "${1:-}") ;;
      --pbe-resolved) shift; pbe=$(want_bool --pbe-resolved "${1:-}") ;;
      --standing-rule) shift; standing=${1:-none} ;;
      --confidence)
        shift
        case "${1:-}" in high|medium|low) confidence=$1 ;; *) fail "--confidence must be high, medium or low" ;; esac
        ;;
      --novel) shift; novel=$(want_bool --novel "${1:-}") ;;
      --options)
        shift
        case "${1:-}" in ''|*[!0-9]*) fail "--options must be a non-negative integer" ;; *) options=$1 ;; esac
        ;;
      --blast-radius)
        shift
        case "${1:-}" in contained|broad) blast=$1 ;; *) fail "--blast-radius must be contained or broad" ;; esac
        ;;
      --task) shift; task=${1:-} ;;
      --key) shift; key=${1:-} ;;
      --record) record=1 ;;
      -h|--help) usage; return 0 ;;
      *) fail "unknown option: $1" ;;
    esac
    shift
  done

  # --- authority verdict: the only path to D3 -------------------------------
  reserve() {  # <reason>
    authority=reserved
    [ -z "$reason" ] || reason="$reason; "
    reason="$reason$1"
  }
  [ "$reassigns" = no ] || reserve 'reassigns an authority or architectural owner'
  [ "$constitutional" = no ] || reserve 'constitutional change or a contradiction in accepted architecture'
  [ "$reserved_gate" = no ] || reserve 'a Decision Gate explicitly reserved to human judgment'
  [ "$credentials" = no ] || reserve 'credentials or sensitive approval'
  [ "$external" = no ] || reserve 'material financial or external side effects'
  [ "$destructive" = no ] || reserve 'destructive action beyond standing authority'
  [ "$weakens" = no ] || reserve 'weakens certification ownership or ordering'
  if [ "$reversible" = no ] && [ "$standing" = none ]; then
    reserve 'irreversible with no standing rule covering it'
  fi
  if [ "$within" = no ] && [ "$pbe" = no ]; then
    reserve 'architectural expansion that Population-before-Expansion did not resolve'
  fi

  if [ "$authority" = reserved ]; then
    tier=D3
    routing=operator
    next=captain-hold
  else
    # --- capability routing: D0, D1 or D2 only ------------------------------
    if [ "$standing" != none ]; then
      tier=D0
      routing=deterministic
      next=apply-standing-rule
      reason="standing rule determines the answer: $standing"
    else
      [ "$confidence" != low ] || escalators="${escalators}${escalators:+,}confidence-low"
      [ "$novel" = no ] || escalators="${escalators}${escalators:+,}novel"
      [ "$options" -lt 3 ] || escalators="${escalators}${escalators:+,}multiple-options"
      [ "$blast" != broad ] || escalators="${escalators}${escalators:+,}broad-blast-radius"
      if [ -n "$escalators" ]; then
        tier=D2
        routing=sol-assisted
        next=ruling-request
        reason='delegated judgment routed for assistance by capability signals, not by authority'
      else
        tier=D1
        routing=firstmate
        next=decide-and-record
        reason='in-architecture, reversible, contained delegated engineering judgment'
      fi
    fi
  fi

  printf 'tier=%s\n' "$tier"
  printf 'authority=%s\n' "$authority"
  printf 'routing=%s\n' "$routing"
  printf 'next=%s\n' "$next"
  printf 'escalators=%s\n' "$escalators"
  printf 'reason=%s\n' "$reason"

  if [ "$record" -eq 1 ]; then
    [ -n "$task" ] || fail '--record requires --task'
    [ -n "$key" ] || fail '--record requires --key'
    fm_away_valid_session_id "$task" || fail "--task must be a privacy-safe slug: $task"
    fm_away_valid_session_id "$key" || fail "--key must be a privacy-safe slug: $key"
    session=$(fm_away_session_id)
    [ -n "$session" ] || fail 'no away session is open, so there is nothing to record against'
    fm_away_ledger_append "$session" classification \
      "task=$task" "key=$key" "tier=$tier" "authority=$authority" \
      "escalators=$escalators" "reason=$reason" \
      || fail 'could not record the classification'
  fi
}

case "${1:-}" in
  classify) shift; command_classify "$@" ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
