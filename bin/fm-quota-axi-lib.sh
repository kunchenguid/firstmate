# shellcheck shell=bash
# Shared quota-axi compatibility floor for the bootstrap diagnostic.
# Usage: . bin/fm-quota-axi-lib.sh
#
# FM_QUOTA_AXI_MIN follows the axi-family floor policy owned beside the floor
# constants in bin/fm-bootstrap.sh.
#
# This file is the single owner of that version number. bin/fm-bootstrap.sh
# turns a failing check into the operator-facing MISSING diagnostic, which is
# what keeps an older build from reaching a dispatch intake at all.

FM_QUOTA_AXI_MIN=0.1.29
FM_QUOTA_PROVIDER_ID_RE='^[a-z0-9]+(-[a-z0-9]+)*\z'

fm_quota_axi_compatible() {
  local timeout=${1:-} output parts major minor patch extra
  local min_major min_minor min_patch min_extra
  command -v quota-axi >/dev/null 2>&1 || return 1
  if [ -n "$timeout" ]; then
    case "$timeout" in
      ''|*[!0-9]*|0) return 1 ;;
    esac
    [ "$(type -t fm_run_timed)" = function ] || return 1
    output=$(fm_run_timed "$timeout" quota-axi --version 2>/dev/null </dev/null) || return 1
  else
    output=$(quota-axi --version 2>/dev/null </dev/null) || return 1
  fi
  parts=$(printf '%s\n' "$output" |
    sed -n 's/.*\([0-9][0-9]*\)\.\([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1 \2 \3/p' |
    head -1)
  IFS=' ' read -r major minor patch extra <<< "$parts"
  # An unparseable version is incompatible, never assumed current, so a
  # development or vendored build cannot pass a floor it was never checked against.
  [ -n "$major" ] && [ -n "$minor" ] && [ -n "$patch" ] && [ -z "$extra" ] || return 1
  # The floor is compared from FM_QUOTA_AXI_MIN so bumping it needs one edit.
  IFS='.' read -r min_major min_minor min_patch min_extra <<< "$FM_QUOTA_AXI_MIN"
  [ -n "$min_major" ] && [ -n "$min_minor" ] && [ -n "$min_patch" ] && [ -z "$min_extra" ] || return 1
  [ "$major" -gt "$min_major" ] && return 0
  [ "$major" -eq "$min_major" ] || return 1
  [ "$minor" -gt "$min_minor" ] && return 0
  [ "$minor" -eq "$min_minor" ] || return 1
  [ "$patch" -ge "$min_patch" ]
}

fm_quota_json_valid() {
  jq -se --arg provider_re "$FM_QUOTA_PROVIDER_ID_RE" '
    length == 1 and
    (.[0] | type) == "object" and
    (.[0] |
      .schemaVersion == 5 and
      (.providers | type) == "array" and
      (([.providers[].provider] | length) == ([.providers[].provider] | unique | length)) and
      all(.providers[];
      (.provider | type) == "string" and
      (.provider | test($provider_re)) and
      (.quotaSemantics | type) == "object" and
      (.quotaSemantics.status as $semantics_status |
        (["known", "partial", "unknown"] | index($semantics_status)) != null and
        (.quotaSemantics.effectiveAvailability | type) == "array" and
        (if $semantics_status == "known" then
           ((.quotaSemantics.effectiveAvailability | length) > 0 and
            all(.quotaSemantics.effectiveAvailability[];
              .status == "known" or .status == "unknown"
            ))
         elif $semantics_status == "unknown" then
           all(.quotaSemantics.effectiveAvailability[]; .status == "unknown")
         else true
         end) and
        all(.quotaSemantics.effectiveAvailability[];
          type == "object" and
          (.scope | type) == "string" and
          (.scope | length) > 0 and
          ((.scope | test("^\\s|\\s$")) | not) and
          ((.status == "known" and
            (.runway.status as $runway_status |
            ((.effectivePercentRemaining | type) == "number" and
             .effectivePercentRemaining >= 0 and
             .effectivePercentRemaining <= 100 and
             (.runway | type) == "object" and
             ($runway_status | type) == "string" and
             (["through_reset", "projected_exhaustion", "exhausted_now", "unknown"] |
               index($runway_status)) != null))) or
           (.status == "unknown" and
            (has("effectivePercentRemaining") | not) and
            ((has("runway") | not) or
             ((.runway | type) == "object" and
              (.runway.status as $unknown_runway_status |
               (["unknown", "exhausted_now"] | index($unknown_runway_status)) != null)))))
        )
      )
    )
    )
  ' >/dev/null 2>&1
}

fm_quota_single_provider_table() {
  printf '%s\n' \
    'claude claude' \
    'codex codex' \
    'grok grok' \
    'kimi kimi' \
    'cursor cursor' \
    'agy agy' \
    'muse meta'
}

fm_quota_single_provider_for_harness() {
  local harness provider
  while read -r harness provider; do
    if [ "$harness" = "$1" ]; then
      printf '%s\n' "$provider"
      return 0
    fi
  done < <(fm_quota_single_provider_table)
  return 1
}

fm_quota_provider_for_harness() {
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

# fm_quota_snapshot_json reads one quota-axi default TOON or schema-5 JSON
# snapshot on stdin and prints the validated schema-5 JSON on stdout. On a
# rejected snapshot it prints the rejection reason on stdout instead and
# returns 1, so a caller can report it verbatim.
fm_quota_snapshot_json() {
  local snapshot json schema
  snapshot=$(cat)
  if printf '%s\n' "$snapshot" | jq -e 'type == "object"' >/dev/null 2>&1; then
    json=$snapshot
    schema=$(printf '%s\n' "$json" | jq -r '.schemaVersion // empty' 2>/dev/null) || schema=
    case "$schema" in
      5) ;;
      '') { printf 'quota-axi json missing schemaVersion
  '; return 1; } ;;
      *) { printf 'unsupported quota-axi schema version: %s
  ' "$schema"; return 1; } ;;
    esac
  else
    json=$(printf '%s\n' "$snapshot" | jq -Rse '
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
    ' 2>/dev/null) || { printf 'invalid quota-axi snapshot\n'; return 1; }
  fi

  printf '%s\n' "$json" | fm_quota_json_valid || { printf 'invalid quota-axi provider data\n'; return 1; }
    printf '%s\n' "$json"
}

# fm_quota_effective_for_provider_model <provider> <model> reads validated
# schema-5 JSON on stdin and prints the most constraining applicable quota
# evidence for the provider/model tuple, including provider-wide and exact
# model or product scopes; {status: "unknown"} means nothing measurable
# applies.
fm_quota_effective_for_provider_model() {
  local provider=$1 model=${2:-default}
  jq -c --arg provider "$provider" --arg model "$model" '
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
