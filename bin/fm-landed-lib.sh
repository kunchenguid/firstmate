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
# A closed row is never actively held: tasks-axi clears the held flag when a
# task closes, but a non-release answer keeps hold-kind and the hold reason.
# Merge approval removes those annotations through the release contract before
# cleanup records the merged PR or local-only landing, so either artifact on a
# Done captain-hold row is not a delivery. A retained scout closes with its
# hold-kind intact, so its recorded report remains a delivery.
#
# The distinction that decides the section is delivery: Recently Landed is
# merged PRs, completed scouts, and finished local-only merges. A closed row
# whose artifact matches its merged, reported, or done completion verb is a
# delivery whoever approved it. A retained scout is identified by its kind and
# recorded report because its title links do not change what it delivers. A
# captain question remains kind captain when it closes, so it is never rendered
# as shipped work even when its text names an artifact. Older kindless local-only
# completions cannot be distinguished from answered calls and stay out; merged
# PRs and reported scouts remain distinct.
#
# The sole compatibility fallback keeps a structured Done row whose three
# parsed artifact fields are absent when it does not retain hold-kind captain.
# That preserves rows closed before artifact-aware selection without admitting
# answered captain calls.

# shellcheck disable=SC2034 # Output global, read by the sourcing caller.
FM_LANDED_JQ_DEFS='
  def retained_scout_report:
    .kind == "scout"
    and .hold_kind == "captain"
    and (.report_path // null) != null;
  def landed_artifact:
    if retained_scout_report then (.report_path // null)
    elif .completion.verb == "merged" then (.pr_url // null)
    elif .completion.verb == "reported" then (.report_path // null)
    elif .completion.verb == "done" then (.local_note // null)
    else null
    end;
  def landed_delivery:
    retained_scout_report
    or (.kind != "captain"
      and .hold_kind != "captain"
      and .completion.verb == "merged"
      and (.pr_url // null) != null)
    or (.kind != "captain"
      and .completion.verb == "reported"
      and (.report_path // null) != null)
    or ((.kind // null) != null
      and .kind != "captain"
      and .hold_kind != "captain"
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
