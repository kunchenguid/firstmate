# shellcheck shell=bash
# Shared "what belongs in Recently Landed" rule.
# Usage: . bin/fm-landed-lib.sh; splice "$FM_LANDED_JQ_DEFS" ahead of a jq
# program, then select backlog rows with `landed_record`.
#
# ONE OWNER for the landed selector. Recently Landed is assembled from two
# separate jq programs - bin/fm-bearings-snapshot.sh projects this home's own
# Done rows, and bin/fm-fleet-snapshot.sh projects each secondmate home's Done
# rows into the roll-up that the same section merges in. Both answer the one
# question "is this closed row a delivery the captain should see", so the rule
# lives here and neither program restates it.
#
# A closed row is never held: tasks-axi clears the held flag when a task closes
# and keeps hold-kind and the hold reason as the record of the call that was
# made. So a captain hold-kind on a Done row marks work the captain personally
# routed, not work that closed while still waiting on him, and treating the
# marker itself as the exclusion drops exactly the deliveries he approved.
#
# The distinction that decides the section is delivery: Recently Landed is
# merged PRs, completed scouts, and finished local-only merges. A closed row
# that carries one of those normalized completion artifacts is a delivery
# whoever approved it, while a referenced artifact is not completion evidence.
# legacy_landed_fallback preserves the old hold-based rule only for rows without
# provenance. Such a row cannot distinguish an approved merge from a rejected
# task carrying the same bullet artifact; the boundary record removes that
# ambiguity going forward.

# shellcheck disable=SC2034 # Output global, read by the sourcing caller.
FM_COMPLETION_JQ_DEFS='
  def completion_record:
    . as $line
    | if startswith("<!-- firstmate-completion.v1 ") and endswith(" -->") then
        (sub("^<!-- firstmate-completion\\.v1 "; "")
         | sub(" -->$"; "")
         | fromjson?) as $record
        | select($record | type == "object" and keys == ["value"]
          and (.value | type == "string") and (.value | length > 0))
        | {line:$line,value:$record.value,format:"v1"}
      elif startswith("Deliverable of the finished work: ") then
        {line:$line,value:(sub("^Deliverable of the finished work: "; "")),format:"legacy"}
      else empty end;
  def delivery_values($lines):
    ([ $lines[] | completion_record ]
     | if length > 0 then [.[-1].value] else [] end);
'

fm_completion_last_record_field() {  # <line|value|format> <decoded-body>
  local field=$1 body=$2
  printf '%s\n' "$body" | jq -Rrs --arg field "$field" "$FM_COMPLETION_JQ_DEFS"'
    split("\n")
    | [ .[] | completion_record ]
    | if length > 0 then .[-1][$field] else "" end
  '
}

# shellcheck disable=SC2034 # Output global, read by the sourcing caller.
FM_LANDED_JQ_DEFS=$FM_COMPLETION_JQ_DEFS'
  def landed_delivery:
    ((.pr_url // null) != null)
    or ((.report_path // null) != null)
    or ((.local_note // null) != null);
  def legacy_landed_fallback:
    .delivery_provenance != true
    and (.hold_kind != "captain" or landed_delivery);
  def landed_record:
    .state == "done" and .structured
    and ((.delivery_provenance == true and landed_delivery)
         or legacy_landed_fallback);
'
