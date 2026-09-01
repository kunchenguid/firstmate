#!/usr/bin/env bash
# fm-workstream-snapshot.sh - compact, bounded, TOON-by-default workstream projection.
#
# A thin wrapper OVER the canonical bin/fm-fleet-snapshot.sh, sibling to
# bin/fm-bearings-snapshot.sh. It does not parse fleet state itself: it shells
# out to `fm-fleet-snapshot.sh --json`, projects that complete structured
# contract into workstream groupings, and renders TOON at the output boundary
# (bin/fm-toon-lib.sh owns the shared encoder). The internal data model stays
# JSON (`--json` prints it verbatim); TOON and JSON are parity representations
# of the same projected model.
#
# LOCAL-ONLY, ALWAYS: every invocation makes ZERO GitHub/network/auth calls,
# and the projection is main-home only (secondmate homes are not sampled; the
# omission is disclosed). Task current-state truth stays with the canonical
# snapshot's bin/fm-crew-state.sh read; this wrapper never re-reads state files.
#
# WORKSTREAM DERIVATION (the backlog has no workstream field; the convention is
# umbrella tasks plus edges, and this header is its one owner):
#   - An umbrella task is a structured backlog row with kind=program, done or
#     not: a finished umbrella keeps its workstream, so its members stay
#     anchored to it instead of scattering into the unassigned lane.
#     Its id is the workstream id, its title the workstream name, and its body
#     (first indented lines under the row) the intended-outcome line.
#   - Members are claimed in three deterministic passes, first claim wins, with
#     umbrellas considered in backlog order:
#       1. id prefix: a task whose id starts with "<umbrella-id>-".
#       2. direct edge: a task whose blocked-by list names the umbrella id.
#       3. fixpoint expansion: a task connected by any blocked-by edge (either
#          direction) to an already-claimed task joins that task's workstream;
#          when neighbors disagree, the workstream whose umbrella comes first
#          in the backlog wins.
#   - Tasks claimed by no workstream land in the explicit "unassigned" lane,
#     which is a real workstreams[] entry with its own counts and `more` and is
#     never subject to the FM_WS_STREAMS cap (done tasks outside every
#     workstream are dropped, with disclosure).
#
# TASK STATE (one value per board task, first match wins):
#   done      backlog Done.
#   decision  captain_actionable (waiting on the captain now).
#   held      in-flight and held (current_role=held).
#   review    a live worker record exists and a PR is recorded for it.
#   active    a live worker record exists, or backlog In flight.
#   queued    everything else.
#
# BOARD-VS-REALITY DIVERGENCE (`divergence[]`): a backlog row still Queued
# while a live worker record exists (queued-but-live), a backlog In-flight row
# with no worker record (in-flight-no-worker, from the canonical
# main_inventory), and a live worker record with no structured backlog row
# (worker-not-on-board).
#
# Flags:
#   (default)        compact projection, TOON, local-only
#   --json           the same projected model as JSON (machine/debug; parity form)
#   --all-tasks      lift the per-workstream and unassigned task-row caps
#   --all-edges      include every dependency edge
#   --all-decisions  include prose-deferred captain holds
#   -h,--help        usage
#
# Bounds (positive integers, overridable for tests / large fleets):
#   FM_WS_STREAMS (12), FM_WS_TASKS (30 per workstream), FM_WS_UNASSIGNED (20),
#   FM_WS_EDGES (80), FM_WS_DECISIONS (20), FM_WS_AGENTS (20),
#   FM_WS_DIVERGENCE (20).
#
# Output contract: `fm-workstream.v1`. Read-only; no locks, no mutation.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLEET="$SCRIPT_DIR/fm-fleet-snapshot.sh"
# shellcheck source=bin/fm-toon-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-toon-lib.sh"

FM_WS_STREAMS=${FM_WS_STREAMS:-12}
FM_WS_TASKS=${FM_WS_TASKS:-30}
FM_WS_UNASSIGNED=${FM_WS_UNASSIGNED:-20}
FM_WS_EDGES=${FM_WS_EDGES:-80}
FM_WS_DECISIONS=${FM_WS_DECISIONS:-20}
FM_WS_AGENTS=${FM_WS_AGENTS:-20}
FM_WS_DIVERGENCE=${FM_WS_DIVERGENCE:-20}
validate_bound() {  # <name> <value>
  case "$2" in ''|*[!0-9]*|0) echo "fm-workstream-snapshot: $1 must be a positive integer" >&2; exit 2 ;; esac
}
validate_bound FM_WS_STREAMS "$FM_WS_STREAMS"
validate_bound FM_WS_TASKS "$FM_WS_TASKS"
validate_bound FM_WS_UNASSIGNED "$FM_WS_UNASSIGNED"
validate_bound FM_WS_EDGES "$FM_WS_EDGES"
validate_bound FM_WS_DECISIONS "$FM_WS_DECISIONS"
validate_bound FM_WS_AGENTS "$FM_WS_AGENTS"
validate_bound FM_WS_DIVERGENCE "$FM_WS_DIVERGENCE"

usage() {
  cat <<'EOF'
usage: fm-workstream-snapshot.sh [--json] [--all-tasks] [--all-edges]
                                 [--all-decisions]

Compact workstream projection over fm-fleet-snapshot.sh. TOON by default.
Always LOCAL-ONLY (no network) and main-home only.
Workstreams come from umbrella tasks (kind=program) plus id prefixes and
blocked-by edges; unclaimed tasks land in the explicit "unassigned" lane.
The script header owns the exact derivation, state, and divergence rules.
EOF
}

FORMAT=toon
ALL_TASKS=0
ALL_EDGES=0
ALL_DECISIONS=0
while [ $# -gt 0 ]; do
  case "$1" in
    --json) FORMAT=json ;;
    --all-tasks) ALL_TASKS=1 ;;
    --all-edges) ALL_EDGES=1 ;;
    --all-decisions) ALL_DECISIONS=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

command -v jq >/dev/null 2>&1 || { echo "fm-workstream-snapshot: jq not found" >&2; exit 1; }

# The deterministic return-catch-up owner must clear before this or any other
# ordinary captain request proceeds.
"$SCRIPT_DIR/fm-afk-return.sh" guard || exit $?

NOW=${FM_WS_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
SNAP=$(FM_SNAPSHOT_NOW="$NOW" FM_SNAPSHOT_SECONDMATES=0 "$FLEET" --json) || exit $?
HOME_LABEL=$(printf '%s' "$SNAP" | jq -er '.fm_home | strings | split("/") | (.[-2:] | join("/"))') \
  || { echo "fm-workstream-snapshot: invalid canonical snapshot" >&2; exit 1; }

MODEL=$(printf '%s' "$SNAP" | jq \
  --arg home "$HOME_LABEL" \
  --arg now "$NOW" \
  --argjson streams_n "$FM_WS_STREAMS" \
  --argjson tasks_n "$FM_WS_TASKS" \
  --argjson unassigned_n "$FM_WS_UNASSIGNED" \
  --argjson edges_n "$FM_WS_EDGES" \
  --argjson decisions_n "$FM_WS_DECISIONS" \
  --argjson agents_n "$FM_WS_AGENTS" \
  --argjson divergence_n "$FM_WS_DIVERGENCE" \
  --argjson all_tasks "$ALL_TASKS" \
  --argjson all_edges "$ALL_EDGES" \
  --argjson all_decisions "$ALL_DECISIONS" '
  def trunc($n): if . == null then null else
    (tostring | gsub("\\s+"; " ") | if (length > $n) then (.[:$n] + "…") else . end) end;

  ([.backlog.records[]? | select(.structured)]) as $recs
  | ([.tasks[]? | select(.kind != "secondmate")]) as $live
  | ($live | map({key:.id, value:.}) | from_entries) as $live_map
  | ($recs | map({key:.id, value:.}) | from_entries) as $by_id
  | ([$recs[] | select(.kind == "program")]) as $umbrellas
  | ($umbrellas | to_entries | map({key:.value.id, value:.key}) | from_entries) as $uidx
  # Grouping candidates: every structured non-umbrella row, in backlog order.
  | ([$recs[] | select(.kind != "program" and ($uidx[.id] == null)) | .id]) as $cands
  # Undirected blocked-by neighbor map over structured rows.
  | (reduce $recs[] as $r ({};
       reduce ($r.blocked_by_ids[]?) as $b (.;
         .[$r.id] = ((.[$r.id] // []) + [$b])
         | .[$b] = ((.[$b] // []) + [$r.id])))) as $nbr
  # Pass 1: id-prefix claims, umbrella order.
  | (reduce $umbrellas[] as $u ({};
       . as $acc
       | reduce ($cands[] | select(startswith($u.id + "-"))) as $tid ($acc;
           if (.[$tid] // null) != null then . else .[$tid] = $u.id end))) as $a1
  # Pass 2: direct blocked-by edge to the umbrella itself.
  | (reduce $umbrellas[] as $u ($a1;
       . as $acc
       | reduce ($cands[] | select((($by_id[.].blocked_by_ids // []) | index($u.id)) != null)) as $tid ($acc;
           if (.[$tid] // null) != null then . else .[$tid] = $u.id end))) as $a2
  # Pass 3: fixpoint expansion along blocked-by edges; ties go to the
  # workstream whose umbrella comes first in the backlog.
  | (
      def expand:
        . as $a
        | reduce $cands[] as $tid ($a;
            if (.[$tid] // null) != null then .
            else ([ ($nbr[$tid] // [])[] as $n | ($a[$n] // empty) ]
                  | unique | sort_by($uidx[.])) as $ws
            | if ($ws | length) > 0 then .[$tid] = $ws[0] else . end end);
      def fix: . as $prev | expand | if . == $prev then . else fix end;
      $a2 | fix
    ) as $assign
  # One board-task row; the script header owns the state precedence.
  | def task_state($r):
      if $r.state == "done" then "done"
      elif $r.captain_actionable == true then "decision"
      elif $r.current_role == "held" then "held"
      elif $live_map[$r.id] != null then
        (if ($live_map[$r.id].pr.url // null) != null then "review" else "active" end)
      elif $r.state == "in_flight" then "active"
      else "queued" end;
    def task_row($r; $ws):
      ($live_map[$r.id]) as $l
      | {id: $r.id, ws: $ws, state: task_state($r),
         title: (($r.title // $r.id) | trunc(160)),
         doing: ((($l.current_state.detail // "") as $d
                  | if $d != "" then $d else ($l.hints.last_event_text // "") end)
                 | trunc(120)),
         contract: (($r.body_excerpt // "") | trunc(240)),
         agent_state: ($l.current_state.state // ""),
         pr_url: ($l.pr.url // $r.pr_url // null)};
    def state_rank: {decision:0, held:1, active:2, review:3, queued:4, done:5}[.] // 6;
    def state_counts: {done: (map(select(.state == "done")) | length),
                       review: (map(select(.state == "review")) | length),
                       active: (map(select(.state == "active")) | length),
                       held: (map(select(.state == "held")) | length),
                       decision: (map(select(.state == "decision")) | length),
                       queued: (map(select(.state == "queued")) | length)};
  ($umbrellas
   | map(. as $u
     | [ $recs[] | select($assign[.id] == $u.id) ] as $members
     | ($members | map(task_row(.; $u.id))) as $rows
     | ($rows | sort_by([(.state | state_rank)])) as $sorted
     | {id: $u.id,
        name: (($u.title // $u.id) | trunc(90)),
        outcome: (($u.body_excerpt // $u.title // "") | trunc(240)),
        actionable: ($u.captain_actionable == true),
        counts: ($rows | state_counts),
        rows: (if $all_tasks == 1 then $sorted else $sorted[:$tasks_n] end),
        more: (if $all_tasks == 1 then 0 else (($rows | length) - ($sorted[:$tasks_n] | length)) end)})) as $streams_all
  | ([ $recs[]
       | select(.kind != "program" and ($uidx[.id] == null) and ($assign[.id] // null) == null and .state != "done") ]) as $unassigned_recs
  | ($unassigned_recs | map(task_row(.; "unassigned")) | sort_by([(.state | state_rank)])) as $unassigned_rows_all
  | ($unassigned_rows_all | state_counts) as $un_counts
  | ([ $recs[] | select(.kind != "program" and ($uidx[.id] == null) and ($assign[.id] // null) == null and .state == "done") ] | length) as $dropped_done
  | (if $all_tasks == 1 then $unassigned_rows_all else $unassigned_rows_all[:$unassigned_n] end) as $unassigned_rows
  | (if ($streams_all | length) > $streams_n then $streams_all[:$streams_n] else $streams_all end) as $streams
  | ($streams | map(.rows[]) + $unassigned_rows) as $rows_included
  | ($rows_included | map({key:.id, value:true}) | from_entries) as $included
  | ([ $rows_included[] as $r
       | ($by_id[$r.id].blocked_by_ids // [])[] as $b
       | select($included[$b] == true)
       | {from: $b, to: $r.id,
          ws: ((($assign[$b] // "unassigned") == ($assign[$r.id] // "unassigned"))
               as $same | if $same then ($assign[$r.id] // "unassigned") else "cross" end)} ]
     | unique_by([.from, .to])) as $edges_all
  | ([ $recs[]
       | select(.captain_actionable == true)
       | select(($all_decisions == 1) or (.deferred_marker != true))
       | {id, ws: (if $uidx[.id] != null then .id else ($assign[.id] // "unassigned") end),
          summary: (((.title // .id) + ": " + (.hold_reason // "")) | trunc(120))} ]) as $decisions_all
  | ([ $recs[] | select(.captain_actionable == true and .deferred_marker == true) ] | length) as $decisions_deferred
  | ([ $live[]
       | {id, ws: ($assign[.id] // (if $uidx[.id] != null then .id else "unassigned" end)),
          state: (.current_state.state // "unknown"),
          doing: (((.current_state.detail // "") as $d
                   | if $d != "" then $d else (.hints.last_event_text // "") end)
                  | trunc(90))} ]) as $agents_all
  | ([ $recs[] | select(.state == "queued" and $live_map[.id] != null)
       | {id, kind: "queued-but-live",
          note: "the backlog still has this queued, but a live worker record exists"} ]
     + [ (.main_inventory.orphan_in_flight // [])[]
         | (if type == "object" then .id else . end) as $oid
         | {id: $oid, kind: "in-flight-no-worker",
            note: "the backlog has this in flight, but no worker record exists"} ]
     + [ $live[] | select($by_id[.id] == null)
         | {id, kind: "worker-not-on-board",
            note: "a live worker record exists with no structured backlog row"} ]) as $divergence_all
  | {
      schema: "fm-workstream.v1",
      home: $home,
      generated: $now,
      workstreams: (($streams | map({id, name, outcome, actionable,
        total: (.counts | add), done: .counts.done, review: .counts.review,
        active: .counts.active, held: .counts.held, decision: .counts.decision,
        queued: .counts.queued, more: .more}))
        + (if ($unassigned_rows_all | length) > 0 then
             [{id: "unassigned", name: "Unassigned",
               outcome: "Tasks claimed by no workstream.",
               actionable: false,
               total: ($un_counts | add), done: $un_counts.done,
               review: $un_counts.review, active: $un_counts.active,
               held: $un_counts.held, decision: $un_counts.decision,
               queued: $un_counts.queued,
               more: (($unassigned_rows_all | length) - ($unassigned_rows | length))}]
           else [] end)),
      tasks: $rows_included,
      edges: (if $all_edges == 1 then $edges_all else $edges_all[:$edges_n] end),
      decisions: ($decisions_all[:$decisions_n]),
      agents: ($agents_all[:$agents_n]),
      divergence: ($divergence_all[:$divergence_n])
    }
  | . + {omitted: (
      [ {surface:"secondmate homes not sampled; this board is main-home only", reveal:"/bearings covers the fleet"},
        (if ($streams_all | length) > ($streams | length) then {surface:("workstreams showing \($streams | length) of \($streams_all | length)"), reveal:"raise FM_WS_STREAMS"} else empty end),
        (([$streams[] | select(.more > 0)] | length) as $capped
         | if $capped > 0 then {surface:("task rows capped in \($capped) workstream(s)"), reveal:"--all-tasks"} else empty end),
        (if ($unassigned_rows_all | length) > ($unassigned_rows | length) then {surface:("unassigned tasks showing \($unassigned_rows | length) of \($unassigned_rows_all | length)"), reveal:"--all-tasks"} else empty end),
        (if $dropped_done > 0 then {surface:("done tasks outside every workstream dropped: \($dropped_done)"), reveal:"tasks-axi list --state done"} else empty end),
        (if $all_edges == 0 and ($edges_all | length) > $edges_n then {surface:("edges showing \($edges_n) of \($edges_all | length)"), reveal:"--all-edges"} else empty end),
        (if ($decisions_all | length) > $decisions_n then {surface:("decisions showing \($decisions_n) of \($decisions_all | length)"), reveal:"raise FM_WS_DECISIONS"} else empty end),
        (if $all_decisions == 0 and $decisions_deferred > 0 then {surface:("captain holds marked deferred or superseded: \($decisions_deferred)"), reveal:"--all-decisions"} else empty end),
        (if ($agents_all | length) > $agents_n then {surface:("agents showing \($agents_n) of \($agents_all | length)"), reveal:"raise FM_WS_AGENTS"} else empty end),
        (if ($divergence_all | length) > $divergence_n then {surface:("divergence showing \($divergence_n) of \($divergence_all | length)"), reveal:"raise FM_WS_DIVERGENCE"} else empty end) ]) }
') || { echo "fm-workstream-snapshot: projection failed" >&2; exit 1; }

if [ "$FORMAT" = json ]; then
  printf '%s\n' "$MODEL"
  exit 0
fi

# The tasks table is the one nested surface; flatten nothing - every model
# array already holds uniform scalar objects, so the shared encoder applies.
TOON=$(printf '%s\n' "$MODEL" | fm_toon_render) \
  || { echo "fm-workstream-snapshot: TOON rendering failed" >&2; exit 1; }
printf '%s\n' "$TOON"
