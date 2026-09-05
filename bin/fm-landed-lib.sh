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
# whose artifact matches its merged, reported, or done completion verb is a
# delivery whoever approved it. A captain question remains kind captain when it
# closes, so it is never rendered as shipped work even when its text names an
# artifact. Older kindless local-only completions cannot be distinguished from
# answered calls and stay out; merged PRs and reported scouts remain distinct.

# shellcheck disable=SC2034 # Output global, read by the sourcing caller.
FM_LANDED_JQ_DEFS='
  def landed_artifact:
    if .completion.verb == "merged" then (.pr_url // null)
    elif .completion.verb == "reported" then (.report_path // null)
    elif .completion.verb == "done" then (.local_note // null)
    else null
    end;
  def landed_delivery:
    (.kind != "captain"
      and .completion.verb == "merged"
      and (.pr_url // null) != null)
    or (.kind != "captain"
      and .completion.verb == "reported"
      and (.report_path // null) != null)
    or ((.kind // null) != null
      and .kind != "captain"
      and .completion.verb == "done"
      and (.local_note // null) != null);
  def landed_record:
    .state == "done" and .structured
    and (landed_delivery
      or (.hold_kind != "captain"
        and (.pr_url // null) == null
        and (.report_path // null) == null
        and (.local_note // null) == null));
'
