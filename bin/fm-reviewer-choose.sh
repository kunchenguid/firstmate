#!/usr/bin/env bash
# Resolve one quota-aware reviewer from an ordered candidate list with failover.
#
# Usage:
#   fm-reviewer-choose.sh --author <harness:model> --snapshot <path>
#     --candidate <harness[:model][@provider]>... [--needs-approval <harness[:model]>]...
#     [--approved <harness[:model]>]... [--record <path>]
#
# Reads one already-captured quota-axi default TOON or JSON snapshot from the
# required --snapshot file; there is no stdin spelling. Candidates are given
# in preference order with --candidate only; bare positional arguments are
# rejected as unknown options. The ordered list comes from review
# configuration (the matching crew-dispatch review rule, in its listed order),
# never from this script, so no model substitution is hardcoded here. --author
# names the harness:model that produced the head under review and is required:
# a reviewer must be non-author.
#
# A candidate is <harness>[:<model>] with an optional @<provider> suffix
# carrying the explicit quota-axi provider family the review configuration
# established for that profile (the crew-dispatch `provider` field). Without
# the suffix the candidate's quota is read from its harness's primary provider
# family, exactly as bin/fm-quota-choose.sh does. A bare harness is a
# legitimate crew-dispatch profile with no `model`: it resolves to that
# harness's own default model exactly as bin/fm-quota-choose.sh resolves it,
# is measured on the provider-wide scopes only, and is printed and recorded as
# "<harness> default" so the caller pins the harness alone.
#
# For each candidate in order, three gates apply. The non-author gate compares
# underlying model identity rather than spelling: the model token with any
# leading "model:" scope prefix and any vendor path prefix removed, compared
# case-insensitively, so claude:claude-sonnet-5 and pi:anthropic/claude-sonnet-5
# are the same author, as are codex:codex_bengalfox and
# codex:model:codex_bengalfox. The rule fails closed: two spellings that may
# denote the same underlying model are treated as the same identity and the
# candidate is skipped as the author, and a bare-harness candidate whose
# default model is unknown is the author whenever its harness is the author's
# harness. The approval gate skips a candidate
# listed in --needs-approval unless it is also listed in --approved, both
# matched on the exact harness:model pin, so a reviewer that needs an explicit
# captain decision is never selected silently. The quota gate probes
# bin/fm-quota-choose.sh against the same snapshot, so quota eligibility stays
# owned by the existing ordered-fallback machinery: a candidate is
# quota-eligible only when its applicable quota has a known effective percent
# remaining greater than zero and no exhausted_now runway. When the candidate
# declares @<provider>, the probe is keyed to that provider's rows (its
# provider-wide scopes plus the model or product scope of the bare model id),
# never to the harness's primary family, so pi:anthropic/claude-sonnet-5@claude
# is measured against the claude row and not the pi row.
#
# Quota the helper cannot measure is disclosed uncertainty, not a veto, and
# is never reported as exhaustion: a supported harness with no quota-axi
# provider mapping (gemini, rovo, agy, or an omp model outside its mapped
# prefixes), a declared provider no mapped harness measures, or a mapped
# provider whose row exposes no measurable applicable scope in the snapshot
# (quotaSemantics unknown with no window, as cursor reports) keeps the
# candidate eligible but defers it behind every measured-eligible candidate.
# quota-ineligible is reserved for measured evidence: an exhausted_now runway
# or a known zero effective percent remaining. Such a candidate prints
# "deferred: <candidate> quota-unmeasured (<why>)" in listed order and is
# selected only when no measured candidate passes every gate, with one
# "unmeasured: <candidate> <why>" line before the reviewer line so the
# uncertainty is on the record. Selection never aborts on an unmeasured
# candidate.
#
# Output on stdout is the durable switch record. Each skipped candidate prints
# "skipped: <candidate> <reason>" with reason author, needs-approval, or
# quota-ineligible, in listed order. A selection then prints
# "reviewer: <harness> <model>" and exits 0. When no candidate passes every
# gate and no unmeasured candidate remains, the same skipped lines print
# followed by one truthful "park: no eligible reviewer (...)" line naming
# each candidate and its reason, and the script exits 1: park only when
# nothing is eligible or unexhausted, never a silent retry in place. Usage and snapshot errors print "error: ..."
# on stderr and exit 2; a rejected snapshot aborts as an error and is never
# reported as a park.
#
# --record <path> appends one line per resolution to a durable record file:
# "reviewer-choose <epoch> selected <harness> <model>" or
# "reviewer-choose <epoch> parked", each followed by " skipped
# <candidate>=<reason>,...", and a selection made on unmeasured quota carries
# " unmeasured <candidate>" before the skipped segment. The record file must
# already be writable; it is never created in a missing directory.
#
# This script is deterministic and safe: it captures no new quota snapshot,
# performs no side effects except the optional record append, and exits nonzero
# when the environment would lead to an unsafe selection. Effort is not part
# of selection: quota and authorship depend on harness and model only, so the
# caller applies the selected reviewer's configured effort when pinning it.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHOOSE="$SCRIPT_DIR/fm-quota-choose.sh"

# shellcheck source=bin/fm-quota-axi-lib.sh
. "$SCRIPT_DIR/fm-quota-axi-lib.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$SCRIPT_DIR/fm-control-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 2; }
usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "${BASH_SOURCE[0]}"
  exit 2
}

CANDIDATES=()
NEEDS_APPROVAL=()
APPROVED=()
AUTHOR=
SNAPSHOT_SOURCE=
RECORD=

while [ "$#" -gt 0 ]; do
  case "$1" in
    --author)
      [ -n "${2-}" ] || die "--author needs a value"
      [ -z "$AUTHOR" ] || die "--author given twice"
      AUTHOR=$2
      shift 2
      ;;
    --snapshot)
      [ -n "${2-}" ] || die "--snapshot needs a path"
      SNAPSHOT_SOURCE=$2
      shift 2
      ;;
    --candidate)
      [ -n "${2-}" ] || die "--candidate needs a value"
      CANDIDATES+=("$2")
      shift 2
      ;;
    --needs-approval)
      [ -n "${2-}" ] || die "--needs-approval needs a value"
      NEEDS_APPROVAL+=("$2")
      shift 2
      ;;
    --approved)
      [ -n "${2-}" ] || die "--approved needs a value"
      APPROVED+=("$2")
      shift 2
      ;;
    --record)
      [ -n "${2-}" ] || die "--record needs a path"
      RECORD=$2
      shift 2
      ;;
    -h|--help|help) usage ;;
    *) die "unknown option: $1" ;;
  esac
done

[ -n "$AUTHOR" ] || die "--author <harness:model> is required"
[ -n "$SNAPSHOT_SOURCE" ] || die "--snapshot <path> is required"
[ "${#CANDIDATES[@]}" -gt 0 ] || die "no candidates supplied"

# pin_of <candidate> prints the harness:model part; provider_of prints the
# declared @provider or nothing.
pin_of() { printf '%s\n' "${1%%@*}"; }
provider_of() {
  case "$1" in
    *@*) printf '%s\n' "${1#*@}" ;;
    *) printf '\n' ;;
  esac
}

# A pin is <harness>[:<model>]: a bare harness is a profile with no model,
# as bin/fm-quota-choose.sh accepts it, while "harness:" with an empty model
# is malformed. Reject empty parts and characters that cannot form a safe
# token, using the same token alphabet as that helper. The author must name
# its model. A declared provider must match the crew-dispatch provider id
# pattern.
valid_pin() {
  case "$1" in
    ''|:*|*:|*[!A-Za-z0-9._/:-]*) return 1 ;;
  esac
  return 0
}
pin_model() {
  case "$1" in
    *:*) printf '%s\n' "${1#*:}" ;;
    *) printf '\n' ;;
  esac
}
valid_provider() {
  case "$1" in
    ''|-*|*-|*--*|*[!a-z0-9-]*) return 1 ;;
  esac
  return 0
}

valid_pin "$AUTHOR" && [ -n "$(pin_model "$AUTHOR")" ] || die "invalid author: $AUTHOR"
for c in "${CANDIDATES[@]}"; do
  case "$c" in
    *@*@*) die "invalid candidate: $c" ;;
    *@*) valid_provider "$(provider_of "$c")" || die "invalid candidate provider: $c" ;;
  esac
  valid_pin "$(pin_of "$c")" || die "invalid candidate: $c"
done
for c in "${NEEDS_APPROVAL[@]}" "${APPROVED[@]}"; do
  valid_pin "$c" || die "invalid candidate: $c"
done

for c in "$AUTHOR" "${CANDIDATES[@]}" "${NEEDS_APPROVAL[@]}" "${APPROVED[@]}"; do
  pin=$(pin_of "$c")
  fm_control_harness_supported "${pin%%:*}" || die "unknown harness: ${pin%%:*}"
done

[ -f "$SNAPSHOT_SOURCE" ] && [ ! -L "$SNAPSHOT_SOURCE" ] || die "snapshot is not a regular file: $SNAPSHOT_SOURCE"
[ -s "$SNAPSHOT_SOURCE" ] || die "empty quota snapshot"
QUOTA_JSON=$(fm_quota_snapshot_json < "$SNAPSHOT_SOURCE") || die "quota snapshot rejected: $QUOTA_JSON"

# model_identity <harness:model> prints the underlying-model comparison key
# used by the non-author gate: the model with a leading "model:" scope prefix
# and any vendor path prefix removed, lowercased, harness dropped.
model_identity() {
  local rest
  rest=$(pin_model "$1")
  rest=${rest#model:}
  rest=${rest##*/}
  printf '%s\n' "$rest" | tr '[:upper:]' '[:lower:]'
}

# pin_key <harness:model> prints the approval comparison key: the exact pin
# with only a leading "model:" scope prefix removed.
pin_key() {
  local harness=${1%%:*} rest
  rest=$(pin_model "$1")
  rest=${rest#model:}
  printf '%s:%s\n' "$harness" "$rest"
}

AUTHOR_IDENTITY=$(model_identity "$AUTHOR")
AUTHOR_HARNESS=${AUTHOR%%:*}

# is_author <harness:model or harness> fails closed: a candidate with an
# unknown default model is the author whenever it runs on the author's harness.
is_author() {
  local model
  model=$(pin_model "$1")
  if [ -z "$model" ]; then
    [ "${1%%:*}" = "$AUTHOR_HARNESS" ]
  else
    [ "$(model_identity "$1")" = "$AUTHOR_IDENTITY" ]
  fi
}

in_list() {  # <pin key> <entries...>
  local want=$1
  shift
  local entry
  for entry in "$@"; do
    [ "$(pin_key "$entry")" = "$want" ] && return 0
  done
  return 1
}

# probe_harness_for_provider <provider> prints a harness whose primary quota
# family in fm_quota_provider_for_harness is that provider, so the chooser
# probe reads the declared provider's rows. Fails when no mapped harness
# measures that provider.
probe_harness_for_provider() {
  local want=$1 h
  while read -r h; do
    [ "$(fm_quota_provider_for_harness "$h" 2>/dev/null)" = "$want" ] || continue
    printf '%s\n' "$h"
    return 0
  done < <(fm_control_harnesses)
  return 1
}

# probe_target <candidate> prints the harness[:model] the chooser is probed
# with, or prints a reason on failure when the candidate's quota is
# unmeasurable before any probe.
probe_target() {
  local pin provider harness model family probe_harness
  pin=$(pin_of "$1")
  provider=$(provider_of "$1")
  harness=${pin%%:*}
  model=$(pin_model "$pin")
  if [ -z "$provider" ]; then
    if fm_quota_provider_for_harness "$harness" "$model" >/dev/null; then
      printf '%s\n' "$pin"
      return 0
    fi
    case "$harness" in
      omp) printf 'omp model %s is outside the openai-codex and claude-bridge quota prefixes\n' "$model" ;;
      *) printf 'harness %s has no quota-axi provider mapping\n' "$harness" ;;
    esac
    return 1
  fi
  family=$(fm_quota_provider_for_harness "$harness" "$model" 2>/dev/null) || family=
  if [ "$family" = "$provider" ]; then
    printf '%s\n' "$pin"
    return 0
  fi
  if probe_harness=$(probe_harness_for_provider "$provider"); then
    if [ -n "$model" ]; then
      printf '%s:%s\n' "$probe_harness" "${model##*/}"
    else
      printf '%s\n' "$probe_harness"
    fi
    return 0
  fi
  printf 'provider %s has no quota-axi provider mapping\n' "$provider"
  return 1
}

[ -x "$CHOOSE" ] || die "quota chooser not executable: $CHOOSE"

# unmeasured_reason <probe target> prints why a failed chooser probe carries
# no measured evidence, or nothing when the probe failed on measured
# exhaustion. It applies the same provider/scope rule the chooser applied.
unmeasured_reason() {
  local harness=${1%%:*} model provider scope_model status
  model=$(pin_model "$1")
  provider=$(fm_quota_provider_for_harness "$harness" "$model") || return 0
  scope_model=${model:-default}
  [ "$harness" != omp ] || scope_model=${model#*/}
  status=$(printf '%s\n' "$QUOTA_JSON" \
    | fm_quota_effective_for_provider_model "$provider" "$scope_model" \
    | jq -r 'if (.runway.status // "") == "exhausted_now" then "exhausted" else (.status // "unknown") end')
  [ "$status" = unknown ] || return 0
  printf 'provider %s exposes no measured quota for %s\n' "$provider" "$scope_model"
}

SKIPPED=()
SKIP_REASONS=()
DEFERRED=()
DEFERRED_WHY=()
selected=

for c in "${CANDIDATES[@]}"; do
  pin=$(pin_of "$c")
  key=$(pin_key "$pin")
  reason=
  why=
  if is_author "$pin"; then
    reason=author
  elif in_list "$key" "${NEEDS_APPROVAL[@]}" && ! in_list "$key" "${APPROVED[@]}"; then
    reason=needs-approval
  elif ! target=$(probe_target "$c"); then
    why=$target
  elif probe_out=$("$CHOOSE" --snapshot "$SNAPSHOT_SOURCE" --candidate "$target" 2>&1); then
    selected="${pin%%:*} $(pin_model "$pin")"
    selected=${selected% }
    [ -n "$(pin_model "$pin")" ] || selected="$selected default"
    break
  else
    rc=$?
    if [ "$rc" -eq 2 ]; then
      printf 'error: quota snapshot rejected for %s: %s\n' "$c" "$probe_out" >&2
      exit 2
    fi
    why=$(unmeasured_reason "$target")
    [ -n "$why" ] || reason=quota-ineligible
  fi
  if [ -n "$why" ]; then
    DEFERRED+=("$c")
    DEFERRED_WHY+=("$why")
    printf 'deferred: %s quota-unmeasured (%s)\n' "$c" "$why"
    continue
  fi
  SKIPPED+=("$c")
  SKIP_REASONS+=("$reason")
  printf 'skipped: %s %s\n' "$c" "$reason"
done

skip_summary=
i=0
for c in "${SKIPPED[@]}"; do
  [ -z "$skip_summary" ] || skip_summary="$skip_summary, "
  skip_summary="$skip_summary$c=${SKIP_REASONS[$i]}"
  i=$((i + 1))
done

epoch=$(date +%s)

unmeasured=
if [ -z "$selected" ] && [ "${#DEFERRED[@]}" -gt 0 ]; then
  unmeasured=${DEFERRED[0]}
  pin=$(pin_of "$unmeasured")
  selected="${pin%%:*} $(pin_model "$pin")"
  selected=${selected% }
  [ -n "$(pin_model "$pin")" ] || selected="$selected default"
  printf 'unmeasured: %s %s\n' "$unmeasured" "${DEFERRED_WHY[0]}"
fi

if [ -n "$selected" ]; then
  printf 'reviewer: %s\n' "$selected"
  if [ -n "$RECORD" ]; then
    record="reviewer-choose $epoch selected $selected"
    [ -z "$unmeasured" ] || record="$record unmeasured $unmeasured"
    printf '%s skipped %s\n' "$record" "$skip_summary" >> "$RECORD" \
      || die "cannot append record file: $RECORD"
  fi
  exit 0
fi

printf 'park: no eligible reviewer (%s)\n' "$skip_summary"
if [ -n "$RECORD" ]; then
  printf 'reviewer-choose %s parked skipped %s\n' "$epoch" "$skip_summary" >> "$RECORD" \
    || die "cannot append record file: $RECORD"
fi
exit 1
