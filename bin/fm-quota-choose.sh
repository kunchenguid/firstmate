#!/usr/bin/env bash
# Choose the first quota-eligible candidate from a ranked list.
#
# Usage:
#   fm-quota-choose.sh [--snapshot <path>] [--candidate <harness:model>]...
#
# Reads one already-captured quota-axi default TOON or JSON snapshot from the
# provided file, or from stdin when --snapshot is omitted. For each --candidate
# in order, it maps <harness> to its primary provider family, then applies the
# provider-wide scopes and exact model or product scopes for <model>. A candidate
# is eligible only when no applicable runway is `exhausted_now` and its known
# effective percent remaining is greater than zero. The first eligible
# candidate is printed as "<harness> <model>" and the script exits 0.
# If no candidate is quota-eligible, it prints "none" and exits 1.
#
# Candidates are accepted as `--candidate <harness:model>` or as positional
# colon-separated arguments, with earlier candidates preferred.
# This script is deterministic and safe: it performs no side effects and exits
# nonzero when the environment would lead to an unsafe dispatch.
#
# The helper is the canonical worker-side selection used after the agent has
# already run `quota-axi` for its model selection. It never replaces the agent's
# reasoning-class or runway-feasibility gates; it only answers which ordered
# candidate remains eligible under the captured quota evidence.
#
# Multi-provider limitation: this helper maps each harness to ONE primary
# provider family (fm_quota_provider_for_harness in bin/fm-quota-axi-lib.sh)
# and checks quota for that
# family only. Some harnesses can run models from several providers - for
# example, Pi and OpenCode may dispatch xAI, Anthropic, or other models - so a
# candidate whose established provider differs from the harness's primary family
# is checked against the wrong quota row. This is an accepted limitation of the
# optional helper. Authoritative multi-provider routing - including provider
# discovery from the harness catalog and quota matching by that explicit
# provider - is owned by AGENTS.md section 4 and the quota-array-dispatch skill,
# not by this helper. Use this helper only when the brief already fixed the
# candidate order and every candidate's provider is the harness's primary family.
#
# omp (Oh My Pi) has no single primary family, so its candidate model prefix
# selects the family: openai-codex/<id> checks the codex row and
# claude-bridge/<id> checks the claude row, each against the bare <id> for
# model: and product: scopes. Any other or absent prefix is refused up front,
# the same shape as an unknown harness, because no quota-axi row measures it.
# quota-axi reports Codex quota unavailable on this host because omp carries
# its own Codex login, so an openai-codex candidate reads as unknown quota here
# and is never selected on this host; its runway is disclosed uncertainty for
# the agent-side gates, not measured headroom.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
SNAPSHOT_SOURCE=

while [ "$#" -gt 0 ]; do
  case "$1" in
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
    -h|--help|help) usage ;;
    --) shift; break ;;
    -*) die "unknown option: $1" ;;
    *) CANDIDATES+=("$1") ; shift ;;
  esac
done

# Positional args after an explicit -- are also candidates.
while [ "$#" -gt 0 ]; do
  CANDIDATES+=("$1"); shift
done

[ "${#CANDIDATES[@]}" -gt 0 ] || die "no candidates supplied"

# A candidate is <harness>:<model>. A bare harness with no colon means the
# default model. Reject empty harnesses and characters that cannot form a safe
# token. A colon-separated model is legal (e.g. model:codex_bengalfox).
for c in "${CANDIDATES[@]}"; do
  case "$c" in
    ''|:*|*[!A-Za-z0-9._/:-]*) die "invalid candidate: $c" ;;
  esac
done

if [ -n "$SNAPSHOT_SOURCE" ]; then
  [ -f "$SNAPSHOT_SOURCE" ] && [ ! -L "$SNAPSHOT_SOURCE" ] || die "snapshot is not a regular file: $SNAPSHOT_SOURCE"
  QUOTA_SNAPSHOT=$(cat -- "$SNAPSHOT_SOURCE") || die "cannot read snapshot: $SNAPSHOT_SOURCE"
else
  [ ! -t 0 ] || die "quota snapshot is required on stdin or with --snapshot"
  QUOTA_SNAPSHOT=$(cat) || die "cannot read quota snapshot from stdin"
fi
[ -n "$QUOTA_SNAPSHOT" ] || die "empty quota snapshot"

QUOTA_JSON=$(printf '%s\n' "$QUOTA_SNAPSHOT" | fm_quota_snapshot_json) || die "$QUOTA_JSON"

# provider_for_harness <harness> [<model>]
# The harness -> primary provider family table is owned by
# fm_quota_provider_for_harness in bin/fm-quota-axi-lib.sh; see the header
# limitation note for why one family per harness is all this helper checks.
provider_for_harness() {
  fm_quota_provider_for_harness "$@"
}

# effective_for_provider_model <provider> <model>
# Owned by fm_quota_effective_for_provider_model in bin/fm-quota-axi-lib.sh.
effective_for_provider_model() {
  printf '%s\n' "$QUOTA_JSON" | fm_quota_effective_for_provider_model "$@"
}

for c in "${CANDIDATES[@]}"; do
  harness=${c%%:*}
  model=${c#*:}
  [ "$model" = "$c" ] && model="default"
  [ -n "$model" ] || die "invalid candidate: $c"
  fm_control_harness_supported "$harness" || die "unknown harness: $harness"
  provider_for_harness "$harness" "$model" >/dev/null || case "$harness" in
    omp) die "omp quota mapping covers only the openai-codex and claude-bridge prefixes: $model" ;;
    *) die "unknown harness: $harness" ;;
  esac
done

chosen="none"
for c in "${CANDIDATES[@]}"; do
  harness=${c%%:*}
  model=${c#*:}
  [ "$model" = "$c" ] && model="default"
  provider=$(provider_for_harness "$harness" "$model")
  scope_model=$model
  [ "$harness" != omp ] || scope_model=${model#*/}
  effective=$(effective_for_provider_model "$provider" "$scope_model")
  if [ -z "$effective" ] || [ "$effective" = "null" ]; then
    continue
  fi
  if printf '%s\n' "$effective" | jq -e '
    if (.runway.status // "") == "exhausted_now" then false
    elif .status == "unknown" then false
    else
      .effectivePercentRemaining as $remaining |
      (($remaining | type) == "number") and
      ($remaining > 0) and
      ((.runway.status // "") != "exhausted_now")
    end
  ' >/dev/null 2>&1; then
    chosen="$harness $model"
    break
  fi
done

printf '%s\n' "$chosen"
[ "$chosen" != "none" ]
