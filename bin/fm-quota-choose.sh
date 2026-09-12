#!/usr/bin/env bash
# Choose the quota-eligible candidate with the highest known spendPriority.
#
# Usage:
#   fm-quota-choose.sh [--snapshot <path>] [--ordered] [--candidate <harness:model>]...
#
# Reads one already-captured quota-axi default TOON or JSON snapshot from the
# provided file, or from stdin when --snapshot is omitted. For each --candidate
# it maps <harness> to its primary provider family, then applies the
# provider-wide scopes and exact model or product scopes for <model>. The <model>
# token is matched exactly against the `model:` and `product:` scope suffixes,
# so pass the token the snapshot actually uses when quota-axi names a model
# window differently from the dispatch id - for example claude:fable rather
# than claude:claude-fable-5-1. A candidate is eligible only when no applicable
# runway is `exhausted_now` and its known effective percent remaining is
# greater than zero.
#
# Among the eligible candidates the helper ranks by known `spendPriority`, read
# from the tightest applicable scope: the exact model or product row when one
# applies, otherwise the provider-wide row. A higher known scalar is better.
# Where several rows share that tightest scope, the lowest known scalar is used.
# A candidate whose tightest scope publishes no known scalar - absent, `unknown`,
# or unmeasurable - stays eligible but ranks below every known value and never
# breaks a tie. A present-but-unknown model or product row is never backfilled
# from the provider-wide row, because quota-axi reports that tighter scope as
# unmeasurable rather than healthy.
#
# The single highest-ranked candidate is printed as "<harness> <model>" and the
# script exits 0. When two or more candidates share the highest known scalar the
# helper refuses to break the tie: it prints "tie <harness> <model>" for each
# tied candidate, one per line, and exits 3, and the caller escalates that choice
# rather than resolving it by order. When two or more candidates are eligible
# and none has a known scalar there is nothing comparable to rank on, so the
# helper escalates exactly like an exact tie: "tie <harness> <model>" for every
# eligible candidate and exit 3, never a pick by argument order. A single
# eligible candidate is printed as "<harness> <model>" with exit 0 whether or
# not its scalar is known. If no candidate is quota-eligible, it prints "none"
# and exits 1.
#
# --ordered restores first-eligible selection in argument order, for a caller
# whose candidate order is a deliberate preference rather than an array to rank.
#
# Candidates are accepted as `--candidate <harness:model>` or as positional
# colon-separated arguments.
# This script is deterministic and safe: it performs no side effects and exits
# nonzero when the environment would lead to an unsafe dispatch.
#
# The helper is the canonical worker-side selection used after the agent has
# already run `quota-axi` for its model selection. It never replaces the agent's
# reasoning-class or runway-feasibility gates; it only answers which candidate
# the captured quota evidence selects among those the agent already accepted.
#
# Multi-provider limitation: this helper maps each harness to ONE primary
# provider family (see provider_for_harness below) and checks quota for that
# family only. Some harnesses can run models from several providers - for
# example, Pi and OpenCode may dispatch xAI, Anthropic, or other models - so a
# candidate whose established provider differs from the harness's primary family
# is checked against the wrong quota row. This is an accepted limitation of the
# optional helper. Authoritative multi-provider routing - including provider
# discovery from the harness catalog and quota matching by that explicit
# provider - is owned by AGENTS.md section 4 and the quota-array-dispatch skill,
# not by this helper. Use this helper only when every candidate's provider is
# the harness's primary family.
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
ORDERED=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --snapshot)
      [ -n "${2-}" ] || die "--snapshot needs a path"
      SNAPSHOT_SOURCE=$2
      shift 2
      ;;
    --ordered)
      ORDERED=1
      shift
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

if printf '%s\n' "$QUOTA_SNAPSHOT" | jq -e 'type == "object"' >/dev/null 2>&1; then
  QUOTA_JSON=$QUOTA_SNAPSHOT
  schema=$(printf '%s\n' "$QUOTA_JSON" | jq -r '.schemaVersion // empty' 2>/dev/null) || schema=
  case "$schema" in
    5) ;;
    '') die "quota-axi json missing schemaVersion" ;;
    *) die "unsupported quota-axi schema version: $schema" ;;
  esac
else
  QUOTA_JSON=$(printf '%s\n' "$QUOTA_SNAPSHOT" | jq -Rse '
    def valid_preamble:
      ((length == 2) and
       (.[0] | test("^bin: (quota-axi|.*/quota-axi)$")) and
       (.[1] | test("^generatedAt: .+$"))) or
      ((length == 3) and
       (.[0] | test("^bin: (quota-axi|.*/quota-axi)$")) and
       (.[1] | test("^description: .+$")) and
       (.[2] | test("^generatedAt: .+$")));
    def valid_zero_head:
      (length == 0) or valid_preamble;
    def valid_help_tail:
      if length == 0 then true
      else
        (.[0] | capture("^help\\[(?<count>[0-9]+)\\]:$").count | tonumber) as $count |
        (.[1:] | length) == $count and all(.[1:][]; startswith("  "))
      end;
    def decoded_fields:
      def parse($remaining; $fields):
        if $remaining == "" then $fields
        elif ($remaining | startswith("\"")) then
          ($remaining | capture("^(?<field>\"(?:\\\\.|[^\"])*\")(?<rest>,.*|)$")) as $match |
          ($match.field | fromjson) as $field |
          if $match.rest == "," then $fields + [$field, ""]
          else parse(($match.rest | sub("^,"; "")); $fields + [$field])
          end
        else
          ($remaining | capture("^(?<field>[^,\"]*)(?<rest>,.*|)$")) as $match |
          if $match.rest == "," then $fields + [$match.field, ""]
          else parse(($match.rest | sub("^,"; "")); $fields + [$match.field])
          end
        end;
      parse(.; []);
    def decoded_row:
      sub("^  "; "") | decoded_fields;
    def valid_rows($field_count):
      all(.[];
        startswith("  ") and
        ((decoded_row | length) == $field_count) and
        all(decoded_row[]; length > 0)
      );
    def valid_attention_entries:
      type == "array" and
      all(.[];
        type == "object" and
        (.provider | type) == "string" and
        (.provider | test("^[a-z0-9]+(-[a-z0-9]+)*$")) and
        (.scope | type) == "string" and
        (.scope | length) > 0 and
        ((.scope | test("^\\s|\\s$")) | not) and
        (.kind | type) == "string" and (.kind | length) > 0 and
        (.detail | type) == "string" and (.detail | length) > 0 and
        (.remedy | type) == "string" and (.remedy | length) > 0
      );
    def attention_availability:
      if .kind == "headroom_unknown" and (.detail | contains("exhausted_now")) then
        if (.detail | test("(^| · )exhausted_now limited by .+$")) then
          {scope: .scope, status: "unknown", runway: {status: "exhausted_now"}}
        else error("invalid exhausted headroom attention")
        end
      else empty
      end;
    def unknown_providers($entries):
      $entries |
      group_by(.provider) |
      map({
        provider: .[0].provider,
        quotaSemantics: {
          status: "unknown",
          effectiveAvailability: [.[] | attention_availability]
        }
      });
    def exhaustion_count:
      if . == "exhaustion[0]:" or . == "exhaustion: []" then 0
      else
        capture("^exhaustion\\[(?<count>[1-9][0-9]*)\\]\\{provider,scope,usableRunwaySeconds,projectedExhaustedAt,limitingWindowId\\}:$").count |
        tonumber
      end;
    def attention_count:
      if . == "attention[0]:" or . == "attention: []" then 0
      else
        capture("^attention\\[(?<count>[1-9][0-9]*)\\]\\{provider,scope,kind,detail,remedy\\}:$").count |
        tonumber
      end;
    (split("\n") | map(select(length > 0))) as $lines |
    ($lines | map(. == "quota[0]:" or . == "quota: []") | index(true)) as $zero_index |
    if $zero_index != null then
      ($lines[:$zero_index]) as $head |
      if ($head | valid_zero_head) then
        ($lines[($zero_index + 1):]) as $tail |
        if ($tail | length) >= 2 and
             ($tail[0] == "exhaustion[0]:" or $tail[0] == "exhaustion: []") then
          if ($tail[1] == "attention[0]:" or $tail[1] == "attention: []") and
             ($tail[2:] | valid_help_tail) then
            {schemaVersion: 5, providers: []}
          elif ($tail[1] | test("^attention\\[[1-9][0-9]*\\]\\{provider,scope,kind,detail,remedy\\}:$")) then
            ($tail[1] | attention_count) as $attention_count |
            ($tail[2:(2 + $attention_count)]) as $attention_rows |
            if ($attention_rows | length) == $attention_count and
               ($attention_rows | valid_rows(5)) and
               ($tail[(2 + $attention_count):] | valid_help_tail) then
              ($attention_rows | map(decoded_row | {
                provider: .[0], scope: .[1], kind: .[2], detail: .[3], remedy: .[4]
              })) as $entries |
              if ($entries | valid_attention_entries) then
                {schemaVersion: 5, providers: unknown_providers($entries)}
              else error("invalid zero-row attention identities")
              end
            else error("invalid zero-row attention section")
            end
          elif ($tail[1] | startswith("attention: ")) then
            ($tail[1] | sub("^attention: "; "") | fromjson) as $entries |
            if ($entries | valid_attention_entries) and
               ($tail[2:] | valid_help_tail) then
              {schemaVersion: 5, providers: unknown_providers($entries)}
            else error("invalid zero-row attention array")
            end
          else error("invalid zero-row attention section")
          end
        else error("invalid zero-row quota sections")
        end
      else error("invalid zero-row quota header")
      end
    else
      ($lines | map(test("^quota\\[[1-9][0-9]*\\]\\{provider,scope,effectivePercentRemaining,spendPriority,runway,confidence,limitedBy,resetsAt\\}:$")) | index(true)) as $quota_index |
      if $quota_index == null then error("missing quota section")
      else
        ($lines[:$quota_index]) as $head |
        ($lines[$quota_index] | capture("^quota\\[(?<count>[1-9][0-9]*)\\]").count | tonumber) as $quota_count |
        ($lines[($quota_index + 1):($quota_index + 1 + $quota_count)]) as $quota_lines |
        ($quota_index + 1 + $quota_count) as $exhaustion_index |
        ($lines[$exhaustion_index] | exhaustion_count) as $exhaustion_count |
        ($lines[($exhaustion_index + 1):($exhaustion_index + 1 + $exhaustion_count)]) as $exhaustion_rows |
        ($exhaustion_index + 1 + $exhaustion_count) as $attention_index |
        ($lines[$attention_index] | attention_count) as $attention_count |
        ($lines[($attention_index + 1):($attention_index + 1 + $attention_count)]) as $attention_rows |
        ($lines[($attention_index + 1 + $attention_count):]) as $tail |
        if (($head | valid_preamble) | not) or
           ($quota_lines | length) != $quota_count or
           (($quota_lines | valid_rows(8)) | not) or
           ($exhaustion_rows | length) != $exhaustion_count or
           (($exhaustion_rows | valid_rows(5)) | not) or
           ($attention_rows | length) != $attention_count or
           (($attention_rows | valid_rows(5)) | not) or
           (($tail | valid_help_tail) | not) then
          error("invalid quota-axi TOON envelope")
        else
          ($quota_lines | map(decoded_row)) as $rows |
          ($attention_rows | map(decoded_row | {
            provider: .[0], scope: .[1], kind: .[2], detail: .[3], remedy: .[4]
          })) as $attention_entries |
          if (($attention_entries | valid_attention_entries) | not) then error("invalid attention identities")
          elif any($rows[]; length != 8) then error("invalid quota rows")
          else
            {
              schemaVersion: 5,
              providers: (($rows |
                map({
                  provider: .[0],
                  availability: {
                    scope: .[1],
                    status: "known",
                    effectivePercentRemaining: (.[2] | tonumber),
                    runway: {status: .[4]},
                    selection: (
                      .[3] as $spend_priority |
                      if ($spend_priority | test("^-?[0-9]+(\\.[0-9]+)?$")) then
                        {status: "known", spendPriority: ($spend_priority | tonumber)}
                      else {status: "unknown"}
                      end
                    )
                  }
                })) +
                ($attention_entries | map(. as $entry | {
                  provider: $entry.provider,
                  availability: ([$entry | attention_availability] | first // null)
                })) |
                group_by(.provider) |
                map({
                  provider: .[0].provider,
                  quotaSemantics: {
                    status: (if any(.[]; .availability.status == "known") then "known" else "unknown" end),
                    effectiveAvailability: [.[].availability | select(. != null)]
                  }
                })
              )
            }
          end
        end
      end
    end
  ' 2>/dev/null) || die "invalid quota-axi snapshot"
fi

printf '%s\n' "$QUOTA_JSON" | fm_quota_json_valid || die "invalid quota-axi provider data"

# provider_for_harness <harness> [<model>]
# Map a firstmate harness name to its primary quota-axi provider family.
# Multi-provider harnesses (Pi, OpenCode) map to their primary family only; see
# the header limitation note. omp is keyed on the candidate model prefix instead
# and has no family for any other prefix (see the header). Authoritative
# multi-provider routing is owned by AGENTS.md section 4 and the
# quota-array-dispatch skill, not this helper.
provider_for_harness() {
  case "$1" in
    omp)
      case "${2:-}" in
        openai-codex/*)  printf 'codex\n' ;;
        claude-bridge/*) printf 'claude\n' ;;
        *)               return 1 ;;
      esac
      ;;
    claude)       printf 'claude\n' ;;
    codex)        printf 'codex\n' ;;
    opencode)     printf 'codex\n' ;;
    pi|pi-signed) printf 'pi\n' ;;
    grok)         printf 'grok\n' ;;
    kimi)         printf 'kimi\n' ;;
    cursor)       printf 'cursor\n' ;;
    muse)         printf 'meta\n' ;;
    *)            return 1 ;;
  esac
}

# effective_for_provider_model <provider> <model>
# Print the most constraining applicable quota evidence for the provider/model
# tuple, including provider-wide and exact model or product scopes.
effective_for_provider_model() {
  local provider=$1 model=${2:-default}
  printf '%s\n' "$QUOTA_JSON" | jq -c --arg provider "$provider" --arg model "$model" '
    ($model | sub("^model:"; "")) as $model_token |
    ([.providers[]? | select(.provider == $provider)] | first) as $p |
    if ($p // null) == null then {status: "unknown"}
    else ($p.quotaSemantics.effectiveAvailability // []) |
    map(select(.scope as $scope |
      $scope == "all_models" or $scope == "all_products" or
      ($model_token != "" and $model_token != "default" and
       (($scope | startswith("model:")) or ($scope | startswith("product:"))) and
       ($model_token == ($scope | sub("^(model|product):"; ""))))
    )) as $applicable |
    ($applicable | map(select(.status == "known"))) as $known |
    if ($applicable | length) == 0 then {status: "unknown"}
    elif any($applicable[]; (.runway.status // "") == "exhausted_now") then
      ($applicable | map(select((.runway.status // "") == "exhausted_now")) | first)
    elif ($known | length) == 0 then {status: "unknown"}
    elif any($known[]; .effectivePercentRemaining == 0) then
      ($known | map(select(.effectivePercentRemaining == 0)) | first)
    else ($known | min_by(.effectivePercentRemaining))
    end
    end
  ' 2>/dev/null
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

# spend_priority_for_provider_model <provider> <model>
# Print the ranking scalar for the tightest applicable scope, or `unknown` when
# that scope publishes no comparable number. The tightest scope is the exact
# model or product row when one applies, otherwise the provider-wide row; a
# present-but-unknown tighter row is never backfilled from the wider one. Where
# several rows share the tightest scope, the lowest known scalar is printed.
spend_priority_for_provider_model() {
  local provider=$1 model=${2:-default}
  printf '%s\n' "$QUOTA_JSON" | jq -r --arg provider "$provider" --arg model "$model" '
    ($model | sub("^model:"; "")) as $model_token |
    ([.providers[]? | select(.provider == $provider)] | first) as $p |
    if ($p // null) == null then "unknown"
    else ($p.quotaSemantics.effectiveAvailability // []) |
    map(select(.scope as $scope |
      $scope == "all_models" or $scope == "all_products" or
      ($model_token != "" and $model_token != "default" and
       (($scope | startswith("model:")) or ($scope | startswith("product:"))) and
       ($model_token == ($scope | sub("^(model|product):"; ""))))
    )) as $applicable |
    ($applicable | map(select(
      (.scope | startswith("model:")) or (.scope | startswith("product:"))
    ))) as $named |
    (if ($named | length) > 0 then $named else $applicable end) as $tightest |
    ($tightest | map(
      select(.selection.status == "known" and (.selection.spendPriority | type) == "number") |
      .selection.spendPriority
    )) as $known |
    if ($known | length) == 0 then "unknown" else ($known | min | tostring) end
    end
  ' 2>/dev/null
}

ELIGIBLE_LABEL=()
ELIGIBLE_PRIORITY=()
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
    ELIGIBLE_LABEL+=("$harness $model")
    # --ordered keeps the caller's own preference, so the first eligible
    # candidate wins and no ranking scalar is read.
    [ "$ORDERED" = 0 ] || break
    priority=$(spend_priority_for_provider_model "$provider" "$scope_model")
    [ -n "$priority" ] || priority=unknown
    ELIGIBLE_PRIORITY+=("$priority")
  fi
done

if [ "${#ELIGIBLE_LABEL[@]}" -eq 0 ]; then
  printf 'none\n'
  exit 1
fi

if [ "$ORDERED" = 1 ]; then
  printf '%s\n' "${ELIGIBLE_LABEL[0]}"
  exit 0
fi

# Rank the eligible candidates by highest known spendPriority. Candidates whose
# tightest scope has no known scalar are excluded from the comparison entirely,
# so they can neither win against a known value nor create a tie.
best=$(
  for i in "${!ELIGIBLE_PRIORITY[@]}"; do
    [ "${ELIGIBLE_PRIORITY[$i]}" = unknown ] ||
      printf '%s %s\n' "$i" "${ELIGIBLE_PRIORITY[$i]}"
  done | awk '
    NR == 1 || $2 > top { top = $2; list = $1; next }
    $2 == top { list = list " " $1 }
    END { if (NR > 0) print list }
  '
)

# No comparable scalar anywhere: there is nothing to rank on, so every eligible
# candidate is escalated as a tie rather than picked by argument order.
[ -n "$best" ] || best="${!ELIGIBLE_LABEL[*]}"

read -r -a BEST_INDEXES <<< "$best"
if [ "${#BEST_INDEXES[@]}" -gt 1 ]; then
  for i in "${BEST_INDEXES[@]}"; do
    printf 'tie %s\n' "${ELIGIBLE_LABEL[$i]}"
  done
  exit 3
fi

printf '%s\n' "${ELIGIBLE_LABEL[${BEST_INDEXES[0]}]}"
exit 0
