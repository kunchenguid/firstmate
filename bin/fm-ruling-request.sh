#!/usr/bin/env bash
# fm-ruling-request.sh - the durable Ruling Request artifact and the validation
# firstmate performs on an advisor's response before that response may influence
# any action.
#
# A Ruling Request is what a D2 or D3 decision becomes when firstmate asks an
# external reasoning resource for advice. The advisor is a disposable reasoning
# resource, never an authority: its answer is advisory evidence, not
# certification, and firstmate makes the authoritative disposition either way.
#
# THE ADVISOR'S RESPONSE IS NEVER EXECUTED. Nothing in this script evals,
# sources, or expands any response value. Every comparison is a literal string
# test, response fields that carry shell metacharacters are refused outright by
# name, and the untrusted evidence a request carries lives in its own file that
# this script writes and copies but never parses as instruction.
#
# Layout, under the current away session (bin/fm-away-lib.sh):
#   state/away/<session>/ruling/<request-id>/request    trusted key/value fields
#   state/away/<session>/ruling/<request-id>/evidence   untrusted verbatim text
#   state/away/<session>/ruling/<request-id>/response   the accepted response
#   state/away/<session>/ruling/<request-id>/accepted   digest of that response
#
# Usage:
#   fm-ruling-request.sh create --task <id> --key <slug> --repo <dir> [fields]
#   fm-ruling-request.sh show <request-id>
#   fm-ruling-request.sh validate <request-id> --repo <dir> --response <file>
#   fm-ruling-request.sh schema
#
# create requires every field the request contract names, and refuses a partial
# request rather than sending an advisor a question it cannot answer:
#   single-valued: --question --why --recommendation --counterargument
#                  --dependency-impact --reversibility --blast-radius
#                  --falsifier --expiry-condition --expires <epoch> --tier D2|D3
#   repeatable (at least one each):
#                  --alternative --authority-evidence --authorized-action
#                  --invariant --available-verification --verifiable-precondition
#   optional:      --evidence-file <path>   untrusted supporting text
# --reversibility is the closed enum reversible|irreversible|unknown.
# Each --verifiable-precondition is a checker name from the closed set
# baseline-current|worktree-clean; validation runs every checker from the
# trusted request after confirming response membership.
# The exact repository baseline is READ from --repo, never typed, so no claim
# about which commit a request is bound to can be wrong; its canonical checkout
# path is persisted as request context for dynamic reentry validation.
#
# validate refuses a response for any of these reasons, each named on stderr and
# recorded in the away-session ledger:
#   malformed                  unreadable, empty, unknown key, or missing field
#   shell-content              an actionable field carries shell metacharacters
#   duplicate                  a different response was already accepted
#   id-mismatch                request or session id does not match
#   stale-baseline             response or request baseline is not the live one
#   expired                    the request's expiry has passed
#   authority-expansion        an operator-reserved request answered as
#                              delegated, or an action outside the authorized
#                              action boundary
#   higher-rule-contradiction  the response waives a declared invariant
#   precondition-unverifiable  a response names no request-declared precondition
#   precondition-unsatisfied   a request-declared deterministic checker is
#                              unknown, false, or cannot determine its result
#   verification-unavailable   a verification the request does not offer
# Exit 0 accepts, 1 rejects, 2 is invalid usage.
set -u

FM_RULING_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-away-lib.sh
. "$FM_RULING_DIR/fm-away-lib.sh"

FM_RULING_SCHEMA=fm-ruling-request.v1

FM_RULING_REQUEST_SINGLE='schema request session task tier repo baseline question why recommendation counterargument dependency-impact reversibility blast-radius falsifier expiry-condition expires'
FM_RULING_REQUEST_MULTI='alternative authority-evidence authorized-action invariant available-verification verifiable-precondition'
FM_RULING_RESPONSE_SINGLE='request session baseline disposition action rationale opposing verification residual-uncertainty authority'
FM_RULING_RESPONSE_MULTI='precondition invalidator'

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "${BASH_SOURCE[0]}"
}

fail() {  # invalid usage
  printf 'fm-ruling-request: %s\n' "$*" >&2
  exit 2
}

# A rejection is a normal, expected outcome, so it is reported by name and
# recorded rather than thrown away.
reject() {  # <code> <detail>
  local session
  printf 'invalid %s: %s\n' "$1" "$2" >&2
  session=$(fm_away_session_id)
  if [ -n "$session" ] && fm_away_valid_session_id "$session"; then
    fm_away_ledger_append "$session" ruling-rejected \
      "request=${FM_RULING_ID:-unknown}" "code=$1" "detail=$2" || true
  fi
  exit 1
}

sha256_file() {  # <path>
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    fail 'shasum or sha256sum is required'
  fi
}

in_word_list() {  # <word> <space-separated list>
  case " $2 " in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

# Print every value recorded for <key> in a key/value file, one per line.
field_values() {  # <file> <key>
  awk -F '\t' -v k="$2" '$1 == k { sub(/^[^\t]*\t/, ""); print }' "$1"
}

field_one() {  # <file> <key>
  field_values "$1" "$2" | head -1
}

ruling_root() {  # <session>
  printf '%s/ruling' "$(fm_away_session_dir "$1")"
}

# --- create -----------------------------------------------------------------

command_create() {
  local task='' key='' repo='' tier='' evidence_file='' session dir id baseline
  local single_keys='question why recommendation counterargument dependency-impact reversibility blast-radius falsifier expiry-condition expires'
  local multi_keys='alternative authority-evidence authorized-action invariant available-verification verifiable-precondition'
  local pending name value k stage ledger

  pending=$(mktemp "${TMPDIR:-/tmp}/fm-ruling-create.XXXXXX") || fail 'could not stage the request'
  # The staging paths go in a global the EXIT trap can still read after this
  # function returns; a trap over a `local` would evaluate an unset name.
  FM_RULING_PENDING=$pending
  trap 'rm -f "${FM_RULING_PENDING:-/dev/null}" "${FM_RULING_PENDING:-/dev/null}.final"' EXIT

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --task) shift; task=${1:-} ;;
      --key) shift; key=${1:-} ;;
      --repo) shift; repo=${1:-} ;;
      --tier) shift; tier=${1:-} ;;
      --evidence-file) shift; evidence_file=${1:-} ;;
      --*)
        name=${1#--}
        shift
        value=${1:-}
        if in_word_list "$name" "$single_keys" || in_word_list "$name" "$multi_keys"; then
          [ -n "$value" ] || fail "--$name must not be empty"
          printf '%s\t%s\n' "$name" "$(fm_away_clean_field "$value")" >> "$pending"
        else
          fail "unknown option: --$name"
        fi
        ;;
      *) fail "unknown argument: $1" ;;
    esac
    shift
  done

  fm_away_valid_session_id "$task" || fail 'a privacy-safe --task slug is required'
  fm_away_valid_session_id "$key" || fail 'a privacy-safe --key slug is required'
  case "$tier" in D2|D3) ;; *) fail '--tier must be D2 or D3' ;; esac
  [ -n "$repo" ] || fail '--repo is required so the baseline is read, never typed'
  repo=$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null) \
    || fail "could not read a git checkout from $repo"
  baseline=$(fm_away_baseline "$repo") || fail "could not read a git baseline from $repo"

  for k in $single_keys; do
    [ "$(field_values "$pending" "$k" | grep -c .)" = 1 ] \
      || fail "--$k is required exactly once"
  done
  case "$(field_one "$pending" reversibility)" in
    reversible|irreversible|unknown) ;;
    *) fail 'malformed: --reversibility must be reversible, irreversible, or unknown' ;;
  esac
  [ "$(field_one "$pending" expires)" -gt 0 ] 2>/dev/null || fail '--expires must be an epoch'
  for k in $multi_keys; do
    [ "$(field_values "$pending" "$k" | grep -c .)" -ge 1 ] \
      || fail "--$k is required at least once"
  done

  session=$(fm_away_session_id)
  if [ -z "$session" ] || ! fm_away_valid_session_id "$session"; then
    fail 'no away session is open, so a ruling request has nothing to bind to'
  fi

  id="rr-$task-$key"
  FM_RULING_ID=$id
  dir="$(ruling_root "$session")/$id"

  {
    printf 'schema\t%s\n' "$FM_RULING_SCHEMA"
    printf 'request\t%s\n' "$id"
    printf 'session\t%s\n' "$session"
    printf 'task\t%s\n' "$task"
    printf 'tier\t%s\n' "$tier"
    printf 'repo\t%s\n' "$(fm_away_clean_field "$repo")"
    printf 'baseline\t%s\n' "$baseline"
    cat "$pending"
  } > "$pending.final" || fail 'could not assemble the request'

  if [ -f "$dir/request" ]; then
    ledger=$(fm_away_ledger_path "$session")
    if cmp -s "$dir/request" "$pending.final" \
      && [ -f "$dir/evidence" ] \
      && ruling_request_event_exists "$ledger" "$id"; then
      rm -f "$pending.final"
      printf '%s\n' "$id"
      return 0
    fi
    if cmp -s "$dir/request" "$pending.final"; then
      rm -f "$pending.final"
      fail "request $id exists without complete evidence and ledger publication"
    fi
    rm -f "$pending.final"
    fail "request $id already exists with different content; use a new decision key"
  fi

  [ -z "$evidence_file" ] || [ -f "$evidence_file" ] \
    || fail "evidence file does not exist: $evidence_file"
  mkdir -p "$(dirname "$dir")" || fail "could not create $(dirname "$dir")"
  stage=$(mktemp -d "$(dirname "$dir")/.${id}.pending.XXXXXX") \
    || fail 'could not stage the ruling request'
  mv "$pending.final" "$stage/request" || { rm -rf "$stage"; fail 'could not stage the request'; }
  # Untrusted supporting text is stored verbatim and separately. It is never
  # parsed here, and no field of it is ever compared, matched, or executed.
  if [ -n "$evidence_file" ]; then
    cp "$evidence_file" "$stage/evidence" || { rm -rf "$stage"; fail 'could not stage untrusted evidence'; }
  else
    : > "$stage/evidence" || { rm -rf "$stage"; fail 'could not stage empty evidence'; }
  fi
  [ "${FM_RULING_TEST_PUBLISH_FAIL:-0}" != 1 ] \
    || { rm -rf "$stage"; fail 'could not publish the ruling request'; }
  mv "$stage" "$dir" || { rm -rf "$stage"; fail 'could not publish the ruling request'; }
  [ "${FM_RULING_TEST_LEDGER_FAIL:-0}" != 1 ] \
    || fail 'could not complete ruling-request publication'
  fm_away_ledger_append "$session" ruling-request \
    "request=$id" "task=$task" "tier=$tier" "baseline=$baseline" \
    || fail 'could not complete ruling-request publication'
  printf '%s\n' "$id"
}

ruling_request_event_exists() {  # <ledger> <request-id>
  awk -F '\t' -v request="request=$2" \
    '$2 == "ruling-request" { for (i = 3; i <= NF; i++) if ($i == request) found=1 } END { exit !found }' \
    "$1" 2>/dev/null
}

# --- validate ---------------------------------------------------------------

# 0 when a value carries a shell metacharacter. Applied to exactly the fields
# firstmate would otherwise turn into a platform action, so an advisor cannot
# smuggle a command into one even though nothing here would run it.
has_shell_metacharacter() {  # <value>
  # shellcheck disable=SC1003 # The literal backslash is deliberate, not an escape.
  case "$1" in
    *';'*|*'|'*|*'&'*|*'`'*|*'$'*|*'('*|*')'*|*'<'*|*'>'*|*'\'*|*'"'*|*"'"*) return 0 ;;
  esac
  return 1
}

command_validate() {
  local id='' repo='' response='' session dir request live digest accepted
  local keys unknown k count value ledger already_accepted=0 pending_response pending_accepted

  id=${1:-}
  [ -n "$id" ] || fail 'a request id is required'
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --repo) shift; repo=${1:-} ;;
      --response) shift; response=${1:-} ;;
      *) fail "unknown option: $1" ;;
    esac
    shift
  done
  fm_away_valid_session_id "$id" || fail 'request id must be a privacy-safe slug'
  FM_RULING_ID=$id
  [ -n "$repo" ] || fail '--repo is required so the live baseline is read, never typed'
  [ -n "$response" ] || fail '--response is required'

  session=$(fm_away_session_id)
  if [ -z "$session" ] || ! fm_away_valid_session_id "$session"; then
    fail 'no away session is open'
  fi
  dir="$(ruling_root "$session")/$id"
  request="$dir/request"
  [ -f "$request" ] || fail "no such ruling request: $id"
  ledger=$(fm_away_ledger_path "$session")
  if [ ! -f "$dir/evidence" ] || ! ruling_request_event_exists "$ledger" "$id"; then
    reject malformed "ruling request $id lacks complete evidence publication"
  fi

  [ -f "$response" ] || reject malformed "response file does not exist: $response"
  [ -s "$response" ] || reject malformed 'response is empty'
  # Every line must be "<key>\t<value>" with a known key. An unknown or
  # structurally wrong line is malformed, never silently ignored.
  keys=$(awk -F '\t' 'NF < 2 { print "STRUCTURE"; exit } { print $1 }' "$response")
  case "$keys" in
    *STRUCTURE*) reject malformed 'response has a line that is not <key><tab><value>' ;;
  esac
  unknown=$(printf '%s\n' "$keys" | while IFS= read -r k; do
    [ -n "$k" ] || continue
    in_word_list "$k" "$FM_RULING_RESPONSE_SINGLE" && continue
    in_word_list "$k" "$FM_RULING_RESPONSE_MULTI" && continue
    printf '%s\n' "$k"
  done)
  # `waives` is refused by the higher-rule check below rather than as an unknown
  # key, so the reason a response was refused is the accurate one.
  unknown=$(printf '%s\n' "$unknown" | grep -v '^waives$' | grep -v '^$' || true)
  [ -z "$unknown" ] || reject malformed "response carries unknown key(s): $(printf '%s' "$unknown" | tr '\n' ' ')"
  for k in $FM_RULING_RESPONSE_SINGLE; do
    count=$(field_values "$response" "$k" | grep -c . || true)
    [ "$count" = 1 ] || reject malformed "response must carry exactly one $k (found $count)"
  done

  # Shell-metacharacter refusal comes before any other use of these values.
  for k in action verification; do
    value=$(field_one "$response" "$k")
    has_shell_metacharacter "$value" \
      && reject shell-content "response field $k carries shell metacharacters and is refused unexecuted"
  done
  while IFS= read -r value; do
    [ -n "$value" ] || continue
    has_shell_metacharacter "$value" \
      && reject shell-content 'a response precondition carries shell metacharacters and is refused unexecuted'
  done <<EOF
$(field_values "$response" precondition)
EOF

  digest=$(sha256_file "$response")
  if [ -f "$dir/accepted" ]; then
    accepted=$(field_one "$dir/accepted" digest)
    [ "$accepted" = "$digest" ] \
      || reject duplicate "a different response was already accepted for $id"
    if [ ! -f "$dir/response" ] \
      || [ "$(sha256_file "$dir/response")" != "$digest" ] \
      || ! ruling_response_event_exists "$ledger" "$id" "$digest"; then
      reject malformed "accepted response for $id lacks complete evidence publication"
    fi
    already_accepted=1
  fi

  [ "$(field_one "$response" request)" = "$id" ] \
    || reject id-mismatch 'response request id does not match this request'
  [ "$(field_one "$response" session)" = "$session" ] \
    || reject id-mismatch 'response session id does not match the open away session'

  live=$(fm_away_baseline "$repo") \
    || reject precondition-unsatisfied "could not determine the live repository baseline: $repo"
  [ "$(field_one "$request" baseline)" = "$live" ] \
    || reject stale-baseline 'the request was raised against a superseded commit'
  [ "$(field_one "$response" baseline)" = "$live" ] \
    || reject stale-baseline 'the response is bound to a different commit than the live baseline'

  [ "$(date +%s)" -le "$(field_one "$request" expires)" ] \
    || reject expired 'the request expiry has passed'

  # Authority: an operator-reserved question answered as delegated authority is
  # the exact expansion this validation exists to catch.
  value=$(field_one "$response" authority)
  case "$value" in
    delegated|operator-reserved) ;;
    *) reject malformed "response authority must be delegated or operator-reserved: $value" ;;
  esac
  if [ "$(field_one "$request" tier)" = D3 ] && [ "$value" = delegated ]; then
    reject authority-expansion 'an operator-reserved request cannot be answered as delegated authority'
  fi
  value=$(field_one "$response" action)
  field_values "$request" authorized-action | grep -Fqx "$value" \
    || reject authority-expansion "recommended action is outside the authorized action boundary: $value"

  # Higher-order rules are declared by the request; a response may never waive
  # one, so any waives line at all is a contradiction.
  if field_values "$response" waives | grep -q .; then
    reject higher-rule-contradiction "response attempts to waive: $(field_values "$response" waives | tr '\n' ' ')"
  fi

  while IFS= read -r value; do
    [ -n "$value" ] || continue
    field_values "$request" verifiable-precondition | grep -Fqx "$value" \
      || reject precondition-unverifiable "firstmate cannot deterministically check: $value"
  done <<EOF
$(field_values "$response" precondition)
EOF

  while IFS= read -r value; do
    [ -n "$value" ] || continue
    fm_away_precondition_satisfied "$request" "$repo" "$value" \
      || reject precondition-unsatisfied "request-declared checker is unknown, false, or undetermined: $value"
  done <<EOF
$(field_values "$request" verifiable-precondition)
EOF

  value=$(field_one "$response" verification)
  field_values "$request" available-verification | grep -Fqx "$value" \
    || reject verification-unavailable "no deterministic verification is available for: $value"

  if [ "$already_accepted" -eq 1 ]; then
    record_dynamic_verification "$dir/accepted" "$live" \
      || fail 'could not record dynamic verification'
    printf 'valid %s (already accepted)\n' "$id"
    return 0
  fi

  pending_response=$(mktemp "$dir/.response.pending.XXXXXX") \
    || fail 'could not stage the accepted response'
  pending_accepted=$(mktemp "$dir/.accepted.pending.XXXXXX") \
    || { rm -f "$pending_response"; fail 'could not stage acceptance'; }
  cp "$response" "$pending_response" \
    || { rm -f "$pending_response" "$pending_accepted"; fail 'could not stage the accepted response'; }
  {
    printf 'digest\t%s\n' "$digest"
    printf 'accepted\t%s\n' "$(date +%s)"
    printf 'baseline\t%s\n' "$live"
    printf 'verified\t%s\n' "$(date +%s)"
  } > "$pending_accepted" \
    || { rm -f "$pending_response" "$pending_accepted"; fail 'could not stage acceptance'; }
  if ! ruling_response_event_exists "$ledger" "$id" "$digest"; then
    [ "${FM_RULING_TEST_RESPONSE_LEDGER_FAIL:-0}" != 1 ] \
      || { rm -f "$pending_response" "$pending_accepted"; fail 'could not record the accepted response'; }
    fm_away_ledger_append "$session" ruling-response \
      "request=$id" "authority=$(field_one "$response" authority)" \
      "action=$(field_one "$response" action)" "digest=$digest" \
      || { rm -f "$pending_response" "$pending_accepted"; fail 'could not record the accepted response'; }
  fi
  [ "${FM_RULING_TEST_ACCEPT_PUBLISH_FAIL:-0}" != 1 ] \
    || { rm -f "$pending_response" "$pending_accepted"; fail 'could not publish the accepted response'; }
  mv "$pending_response" "$dir/response" \
    || { rm -f "$pending_response" "$pending_accepted"; fail 'could not publish the accepted response'; }
  mv "$pending_accepted" "$dir/accepted" \
    || { rm -f "$pending_accepted"; fail 'could not publish acceptance'; }
  printf 'valid %s\n' "$id"
}

record_dynamic_verification() {  # <accepted-file> <baseline>
  local accepted_file=$1 baseline=$2 pending digest accepted_at
  digest=$(field_one "$accepted_file" digest)
  accepted_at=$(field_one "$accepted_file" accepted)
  pending=$(mktemp "$(dirname "$accepted_file")/.accepted.verify.XXXXXX") || return 1
  {
    printf 'digest\t%s\n' "$digest"
    printf 'accepted\t%s\n' "$accepted_at"
    printf 'baseline\t%s\n' "$baseline"
    printf 'verified\t%s\n' "$(date +%s)"
  } > "$pending" || { rm -f "$pending"; return 1; }
  mv "$pending" "$accepted_file" || { rm -f "$pending"; return 1; }
}

ruling_response_event_exists() {  # <ledger> <request-id> <digest>
  awk -F '\t' -v request="request=$2" -v digest="digest=$3" '
    $2 == "ruling-response" {
      has_request=0
      has_digest=0
      for (i = 3; i <= NF; i++) {
        if ($i == request) has_request=1
        if ($i == digest) has_digest=1
      }
      if (has_request && has_digest) found=1
    }
    END { exit !found }
  ' "$1" 2>/dev/null
}

command_show() {
  local id=${1:-} session dir
  [ -n "$id" ] || fail 'a request id is required'
  session=$(fm_away_session_id)
  [ -n "$session" ] || fail 'no away session is open'
  dir="$(ruling_root "$session")/$id"
  [ -f "$dir/request" ] || fail "no such ruling request: $id"
  cat "$dir/request"
}

command_schema() {
  printf 'request-single\t%s\n' "$FM_RULING_REQUEST_SINGLE"
  printf 'request-multi\t%s\n' "$FM_RULING_REQUEST_MULTI"
  printf 'response-single\t%s\n' "$FM_RULING_RESPONSE_SINGLE"
  printf 'response-multi\t%s\n' "$FM_RULING_RESPONSE_MULTI"
}

case "${1:-}" in
  create) shift; command_create "$@" ;;
  validate) shift; command_validate "$@" ;;
  show) shift; command_show "$@" ;;
  schema) command_schema ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
