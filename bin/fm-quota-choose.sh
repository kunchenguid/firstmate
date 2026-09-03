#!/usr/bin/env bash
# Choose the first quota-eligible candidate from a ranked list.
#
# Usage:
#   fm-quota-choose.sh [--snapshot <path>] [--candidate <harness:model>]...
#
# Reads one already-captured quota-axi default TOON or JSON snapshot from the
# provided file, or from stdin when --snapshot is omitted. For each --candidate
# in order, it maps <harness> and, for OMP, the model's explicit vendor prefix
# to a quota-axi provider family, then applies the provider-wide scopes and
# exact model or product scopes for <model>. A candidate
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
# Multi-provider limitation: this helper maps most harnesses to one primary
# provider family. OMP is the exception because its canonical model ids include
# the provider (`anthropic/...`, `openai/...`, and so on), so using a fabricated
# `omp` provider would make every real quota-axi snapshot look unknown. For
# other multi-provider harnesses, use this helper only when its candidate order and every candidate's provider is the harness's primary family.
# Authoritative routing, including catalog-backed provider discovery, is owned
# by AGENTS.md section 4 and the quota-array-dispatch skill.
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
                    runway: {status: .[4]}
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

# provider_for_candidate <harness> <model>
# Map a candidate to the provider names quota-axi actually emits. OMP has no
# provider row of its own: its canonical `vendor/model` id supplies the family.
# An unknown OMP vendor prints nothing so the candidate fails closed.
provider_for_candidate() {
  local harness=$1 model=${2:-default} vendor
  if [ "$harness" = omp ]; then
    model=${model#model:}
    case "$model" in
      */*) vendor=${model%%/*} ;;
      *) return 0 ;;
    esac
    case "$vendor" in
      anthropic) printf 'claude\n' ;;
      openai) printf 'codex\n' ;;
      xai) printf 'grok\n' ;;
      kimi|moonshot|moonshotai) printf 'kimi\n' ;;
      meta) printf 'meta\n' ;;
    esac
    return 0
  fi
  case "$harness" in
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

quota_model_for_candidate() {
  local harness=$1 model=${2:-default}
  model=${model#model:}
  if [ "$harness" = omp ]; then
    case "$model" in */*) model=${model#*/} ;; esac
  fi
  printf '%s\n' "$model"
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
  provider_for_candidate "$harness" "$model" >/dev/null || die "unknown harness: $harness"
done

chosen="none"
for c in "${CANDIDATES[@]}"; do
  harness=${c%%:*}
  model=${c#*:}
  [ "$model" = "$c" ] && model="default"
  provider=$(provider_for_candidate "$harness" "$model")
  quota_model=$(quota_model_for_candidate "$harness" "$model")
  effective=$(effective_for_provider_model "$provider" "$quota_model")
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
