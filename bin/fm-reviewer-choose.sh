#!/usr/bin/env bash
# Resolve one quota-aware reviewer from an ordered candidate list with failover.
#
# Usage:
#   fm-reviewer-choose.sh --author <harness:model> [--snapshot <path>]
#     [--candidate <harness:model>]... [--needs-approval <harness:model>]...
#     [--approved <harness:model>]... [--record <path>]
#
# Reads one already-captured quota-axi default TOON or JSON snapshot from the
# provided file, or from stdin when --snapshot is omitted. Candidates are given
# in preference order with --candidate or as positional harness:model arguments;
# the ordered list comes from review configuration, never from this script, so
# no model substitution is hardcoded here. --author names the harness:model
# that produced the head under review and is required: a reviewer must be
# non-author.
#
# For each candidate in order, three gates apply. The non-author gate skips a
# candidate whose harness and model equal --author (a leading "model:" token is
# ignored on both sides, matching the quota scope rule). The approval gate
# skips a candidate listed in --needs-approval unless it is also listed in
# --approved, so a reviewer that needs an explicit captain decision is never
# selected silently. The quota gate probes bin/fm-quota-choose.sh with that one
# candidate against the same snapshot, so quota eligibility stays owned by the
# existing ordered-fallback machinery: a candidate is quota-eligible only when
# its applicable quota has a known effective percent remaining greater than
# zero and no exhausted_now runway. The first candidate that passes all three
# gates is selected.
#
# Output on stdout is the durable switch record. Each skipped candidate prints
# "skipped: <candidate> <reason>" with reason author, needs-approval, or
# quota-ineligible, in listed order. A selection then prints
# "reviewer: <harness> <model>" and exits 0. When no candidate passes every
# gate, the same skipped lines print followed by one truthful
# "park: no eligible reviewer (...)" line naming each candidate and its reason,
# and the script exits 1: park only when nothing is eligible or unexhausted,
# never a silent retry in place. Usage and snapshot errors print "error: ..."
# on stderr and exit 2; a rejected snapshot aborts as an error and is never
# reported as a park.
#
# --record <path> appends one line per resolution to a durable record file:
# "reviewer-choose <epoch> selected <harness> <model>" or
# "reviewer-choose <epoch> parked", each followed by " skipped
# <candidate>=<reason>,...". The record file must already be writable; it is
# never created in a missing directory.
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
    --) shift; break ;;
    -*) die "unknown option: $1" ;;
    *) CANDIDATES+=("$1") ; shift ;;
  esac
done

while [ "$#" -gt 0 ]; do
  CANDIDATES+=("$1"); shift
done

[ -n "$AUTHOR" ] || die "--author <harness:model> is required"
[ "${#CANDIDATES[@]}" -gt 0 ] || die "no candidates supplied"

# A candidate is <harness>:<model> with an explicit model: a reviewer pin
# names both, so unlike bin/fm-quota-choose.sh a bare harness is rejected.
# Reject empty parts and characters that cannot form a safe token, using the
# same token alphabet as that helper.
valid_candidate() {
  case "$1" in
    ''|:*|*[!A-Za-z0-9._/:-]*) return 1 ;;
  esac
  [ "${1%%:*}" != "$1" ] || return 1
  [ -n "${1#*:}" ] || return 1
  return 0
}

for c in "$AUTHOR" "${CANDIDATES[@]}" "${NEEDS_APPROVAL[@]}" "${APPROVED[@]}"; do
  valid_candidate "$c" || die "invalid candidate: $c"
done

for c in "$AUTHOR" "${CANDIDATES[@]}" "${NEEDS_APPROVAL[@]}" "${APPROVED[@]}"; do
  harness=${c%%:*}
  model=${c#*:}
  fm_control_harness_supported "$harness" || die "unknown harness: $harness"
  fm_quota_provider_for_harness "$harness" "$model" >/dev/null || case "$harness" in
    omp) die "omp quota mapping covers only the openai-codex and claude-bridge prefixes: $model" ;;
    *) die "unknown harness: $harness" ;;
  esac
done

# Materialize the snapshot once so single-candidate probes below all read the
# same quota state without consuming stdin more than once.
SNAPSHOT_FILE=
if [ -n "$SNAPSHOT_SOURCE" ]; then
  [ -f "$SNAPSHOT_SOURCE" ] && [ ! -L "$SNAPSHOT_SOURCE" ] || die "snapshot is not a regular file: $SNAPSHOT_SOURCE"
  SNAPSHOT_FILE=$SNAPSHOT_SOURCE
else
  [ ! -t 0 ] || die "quota snapshot is required on stdin or with --snapshot"
  SNAPSHOT_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-reviewer-choose.XXXXXX") || die "could not create temporary snapshot file"
  trap 'rm -f "$SNAPSHOT_FILE"' EXIT INT TERM
  cat > "$SNAPSHOT_FILE" || die "cannot read quota snapshot from stdin"
fi
[ -s "$SNAPSHOT_FILE" ] || die "empty quota snapshot"

# identity_key <harness:model> prints the non-author comparison key: the
# harness plus the model with a leading "model:" scope prefix removed, so
# "codex:model:codex_bengalfox" and "codex:codex_bengalfox" count as the same
# author the way the quota scope rule treats them as the same model.
identity_key() {
  local harness=${1%%:*} rest=${1#*:}
  rest=${rest#model:}
  printf '%s:%s\n' "$harness" "$rest"
}

AUTHOR_KEY=$(identity_key "$AUTHOR")

in_list() {  # <key> <entries...>
  local want=$1
  shift
  local entry
  for entry in "$@"; do
    [ "$(identity_key "$entry")" = "$want" ] && return 0
  done
  return 1
}

[ -x "$CHOOSE" ] || die "quota chooser not executable: $CHOOSE"

SKIPPED=()
SKIP_REASONS=()
probe_out=
probe_err=
selected=

for c in "${CANDIDATES[@]}"; do
  harness=${c%%:*}
  model=${c#*:}
  key=$(identity_key "$c")
  reason=
  if [ "$key" = "$AUTHOR_KEY" ]; then
    reason=author
  elif in_list "$key" "${NEEDS_APPROVAL[@]}" && ! in_list "$key" "${APPROVED[@]}"; then
    reason=needs-approval
  else
    probe_err_file=$(mktemp "${TMPDIR:-/tmp}/fm-reviewer-choose-probe.XXXXXX") || die "could not create temporary probe file"
    if probe_out=$("$CHOOSE" --snapshot "$SNAPSHOT_FILE" --candidate "$harness:$model" 2>"$probe_err_file"); then
      rm -f "$probe_err_file"
      selected="$probe_out"
      break
    else
      rc=$?
      probe_err=$(cat -- "$probe_err_file")
      rm -f "$probe_err_file"
      if [ "$rc" -eq 2 ]; then
        printf 'error: quota snapshot rejected for %s: %s\n' "$c" "$probe_err" >&2
        exit 2
      fi
      reason=quota-ineligible
    fi
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

if [ -n "$selected" ]; then
  printf 'reviewer: %s\n' "$selected"
  if [ -n "$RECORD" ]; then
    printf 'reviewer-choose %s selected %s skipped %s\n' "$epoch" "$selected" "$skip_summary" >> "$RECORD" \
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
