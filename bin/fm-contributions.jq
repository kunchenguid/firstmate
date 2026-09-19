# Projection for fm-contributions.sh; its header owns the record contract.
def canonical_url:
  type == "string" and (test("^https://github.com/[A-Za-z0-9-]+/[A-Za-z0-9._-]+/(pull|issues)/[1-9][0-9]*$")
    or test("^https://[A-Za-z0-9.-]+/[A-Za-z0-9._/-]+/-/merge_requests/[1-9][0-9]*$"));
def sha: type == "string" and test("^[a-fA-F0-9]{40}$");
def valid_record:
  try (.schema == "fm-contributions.v1" and (.task | type == "string")
  and (.records | type == "array")
  and all(.records[]; (.url | canonical_url) and (.kind == "pr" or .kind == "issue")
    and (.pending | type == "array") and (.seen | type == "array")
    and all(.pending[]; (.token | type == "string" and length > 0))
    and all(.seen[]; type == "string")
    and ((.notified // []) | type == "array" and all(.[]; type == "string"))
    and (.error == null or (.error | type == "string"))
    and (.checked_at == null or (.checked_at | fromdateiso8601 | type == "number"))
    and (.attempted_at == null or (.attempted_at | fromdateiso8601 | type == "number"))
    and (.unmeasured == null or (.unmeasured | type == "number"))
    and (.verdict == null or (.verdict | (.head | sha) and (.source | type == "string")
      and (.actor | IN("captain","fleet","maintainer","nobody")) and (.summary | type == "string")))
    and (.observation == null or (.kind as $kind | .observation |
      (.state | IN("open","closed","merged")) and (.checks | type == "array")
      and (.reviews | type == "array") and (.events | type == "array")
      and all(.checks[]; (.name | type == "string" and length > 0)
        and (.status | type == "string") and (.conclusion == null or (.conclusion | type == "string")))
      and (if $kind == "pr" then (.head | sha) and (.draft | type == "boolean")
        and (.mergeable | IN("mergeable","conflicting","unknown")) and (.can_merge | type == "boolean")
        and (.review_decision | IN("","APPROVED","CHANGES_REQUESTED","REVIEW_REQUIRED"))
        else (.ready | type == "boolean") end))))) catch false;
def known($input; $saved):
  ([($input.tasks // [])[] | select(.kind != "secondmate")
     | select(.pr.url | canonical_url) | {task:.id,url:.pr.url}]
   + [($input.backlog.records // [])[] | select(.structured == true) as $task
      | ($task.links // [])[] | select(canonical_url) | {task:$task.id,url:.}]
   + [$saved[] | .task as $task | .records[] | {task:$task,url}])
  | unique_by([.task,.url]);
def latest_checks:
  group_by(.name) | map(sort_by([(.started_at // ""),(.id // 0)]) | last);
def projected($input; $saved; $now; $max_age):
  known($input; $saved) as $known
  | [$known[] as $k
    | ([$saved[] | select(.task == $k.task) | .records[] | select(.url == $k.url)] | first) as $record
    | ([$input.backlog.records[]? | select(.structured and
         (.id == $k.task or ((.links // []) | index($k.url)) != null))
         | select(.hold_bucket == "live")] | first) as $hold
    | ([$input.tasks[]? | select(.id == $k.task and .pr.url == $k.url)
       | {head:(.pr.head | select(. != null and . != "")), merge_authority:(.merge_authority // "unknown")}] | first) as $task
    | ($task.head // null) as $recorded_head
    | ($task.merge_authority // "unknown") as $merge_authority
    | ($record.observation // {}) as $o
    | (if $record.error == null and $record.observation != null and ($o.head | sha) then $o.head else null end) as $observed_head
    | (($record.checked_at // "") | try fromdateiso8601 catch null) as $checked
    # A merged or closed observation is final; poll never re-reads it, so it never expires.
    | ($record.error == null and ($o.state | IN("merged","closed"))) as $final
    | (($final or ($checked != null and ($now - $checked) >= 0 and ($now - $checked) <= $max_age))
       and (if $record.kind == "pr" then $observed_head != null
            else $record.error == null and $record.observation != null end)
       and ($k.url | startswith("https://github.com/"))) as $fresh
    | (($o.checks // []) | latest_checks) as $checks
    | [$checks[] | select(.status == "completed" and (.conclusion == null or .conclusion == ""))] as $no_verdict
    | [$checks[] | select(.status != "completed")] as $pending
    | [$checks[] | select(.status == "completed" and .conclusion != null
        and .conclusion != "" and (.conclusion | IN("success","skipped","neutral") | not))] as $failed
    | (($record.verdict != null) and $observed_head != null and ($record.verdict.head != $observed_head)) as $stale
    | (if $record.verdict == null then null
       else $record.verdict + {freshness:(if $stale then "STALE" elif $fresh then "current" else "unverified" end)} end) as $verdict
    | ([$o.reviews[]? | select(.state != "COMMENTED")] | group_by(.user.login)
       | map(sort_by([.submitted_at,.id]) | last)
       | map(. + {freshness:(if $observed_head != null and .commit_id != $observed_head then "STALE" elif $fresh then "current" else "unverified" end)})) as $reviews
    | (if ($k.url | startswith("https://github.com/") | not) then
         {actor:"unmeasured",reason:"unsupported forge; coverage is unmeasured"}
       elif $o.state == "merged" or $o.state == "closed" then
         if $fresh then {actor:"nobody",reason:("forge reports " + $o.state)}
         else {actor:"fleet",reason:"terminal observation needs refresh"} end
       elif $hold != null then {actor:"captain",reason:$hold.hold_reason,hold:$hold.id}
       elif $fresh | not then {actor:"fleet",reason:($record.error // "contribution not recently checked")}
       elif $stale then {actor:"fleet",reason:"STALE maintainer verdict; reassess the current head"}
       elif ($record.pending | length) > 0 then {actor:"fleet",reason:"incoming maintainer signal needs triage"}
       elif $record.kind == "issue" then
         if $o.ready then {actor:"fleet",reason:"filed issue is ready-for-pr"}
         else {actor:"maintainer",reason:"awaiting issue triage"} end
       elif $o.draft then {actor:"fleet",reason:"draft delivery"}
       elif $o.mergeable != "mergeable" then {actor:"fleet",reason:("mergeability " + ($o.mergeable // "unknown"))}
       elif ($failed | length) > 0 then {actor:"fleet",reason:"checks failed"}
       elif ($no_verdict | length) > 0 or (($o.absent_checks // []) | length) > 0 then
         {actor:"fleet",reason:"check lane has no verdict"}
       elif ($checks | length) == 0 then {actor:"fleet",reason:"no reported checks; readiness unconfirmed"}
       elif ($pending | length) > 0 then {actor:"fleet",reason:"checks still running"}
       elif $o.review_decision == "CHANGES_REQUESTED" then {actor:"fleet",reason:"forge requests changes"}
       elif $verdict != null and $verdict.actor == "fleet" then {actor:"fleet",reason:$verdict.summary}
       elif $verdict != null and $verdict.actor == "captain" then
         {actor:"fleet",reason:"record the unresolved arbitration as a captain hold"}
       elif $o.review_decision == "REVIEW_REQUIRED" then {actor:"maintainer",reason:"review required"}
       elif $o.can_merge == true and ($merge_authority == "yolo" or $merge_authority == "away-grant") then
         {actor:"fleet",reason:"checks green; merge is authorized by delivery posture"}
       elif $o.can_merge == true then {actor:"captain",reason:"checks green; merge approval needed"}
       else {actor:"maintainer",reason:"delivery awaits the maintainer"} end) as $action
    | $k + {kind:($record.kind // (if ($k.url | contains("/issues/")) then "issue" else "pr" end)),
         checked_at:$record.checked_at,checked:$fresh,final:$final,head:($observed_head // $recorded_head // $o.head),verdict:$verdict,reviews:$reviews,
         distinct_checks:($checks | length),missing_verdicts:(($no_verdict | length) + (($o.absent_checks // []) | length)),
         pending_checks:($pending | length),failed_checks:($failed | length),
         stale_verdicts:((if $stale then 1 else 0 end) + ([$reviews[] | select(.freshness == "STALE")] | length)),
         signals:($record.pending // [])} + $action]
  # Multiple filed tasks may own the same URL. Retain every owner but count a
  # contribution once; any live arbitration wins over action-free duplicates.
  | group_by(.url)
  | map(. as $owners | sort_by(if .actor == "captain" then 0 elif .actor == "fleet" then 1 else 2 end) | first
      | . + {tasks:($owners | map(.task) | unique)});
def summary($rows; $errors):
  {known:($rows | length),checked:([$rows[] | select(.checked)] | length),
   counts:{captain:([$rows[] | select(.actor == "captain")] | length),
     fleet:([$rows[] | select(.actor == "fleet")] | length),
     maintainer:([$rows[] | select(.actor == "maintainer")] | length),
     nobody:([$rows[] | select(.actor == "nobody")] | length)},
   unmeasured:([$rows[] | select(.actor == "unmeasured")] | length),
   complete:($errors == 0 and all($rows[]; .checked)),
   proven_clear:($errors == 0 and all($rows[]; .checked and .actor != "captain")),
   stale_verdicts:([$rows[].stale_verdicts] | add // 0),
   missing_verdicts:([$rows[].missing_verdicts] | add // 0),
   unreadable_records:$errors,
   valid_until:([$rows[] | select(.final | not) | .checked_at | try (fromdateiso8601) catch 0] | min // 0),
   captain:[$rows[] | select(.actor == "captain") | {task,url,kind,head,reason:(.reason[:240]),hold,
     verdict_freshness:.verdict.freshness,verdict_head:.verdict.head,verdict_source:.verdict.source,checked_at}]};
