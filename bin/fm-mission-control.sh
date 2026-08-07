#!/usr/bin/env bash
# fm-mission-control.sh - render the mission control board as self-contained HTML.
#
# Phase 1 is READ-ONLY: it renders live fleet state and writes one HTML file.
# It acquires no lock, drains no wakes, arms no watcher, and mutates no fleet
# state. The only file it writes is its own output.
#
# This command does not parse fleet state itself. Like bin/fm-fleet-view.sh it
# shells out to bin/fm-fleet-snapshot.sh --json once and renders that stable
# contract, so current_state, backlog roles, captain actionability, and
# secondmate current state keep exactly one owner. Two inputs come from outside
# the snapshot because the snapshot does not own them: data/projects.md is the
# delivery-posture registry, and `quota-axi --json` is the live allowance
# reading. Task-record age and last-update times come from the task's own
# state/<id>.meta and state/<id>.status modification times, which the snapshot
# does not expose.
#
# The board never invents a completion percentage or an ETA. Progress judgement
# belongs to firstmate, so each active task renders a clearly labelled empty
# slot that phase 2 populates with a firstmate-supplied note.
#
# Paths resolve from the ACTIVE home: the snapshot's own roots.state and
# roots.data are used verbatim, so FM_HOME and the FM_*_OVERRIDE variables are
# honoured without a second resolution here.
#
# Usage:
#   fm-mission-control.sh                  write <state>/mission-control.html
#   fm-mission-control.sh --out <path>     write to an explicit path
#   fm-mission-control.sh --stdout         print the HTML instead of writing
#   fm-mission-control.sh --no-quota       skip the quota-axi allowance read
#   fm-mission-control.sh --refresh <sec>  self-reload interval (default 25)
#   fm-mission-control.sh --snapshot <f>   render a captured snapshot JSON file
#   fm-mission-control.sh -h|--help        usage
#
# Environment:
#   FM_MISSION_CONTROL_NOW_EPOCH  fix "now" for deterministic rendering.
#   FM_MISSION_CONTROL_QUOTA_JSON path to a captured quota-axi --json payload,
#                                 used instead of running quota-axi.
#
# Exit codes: 0 rendered, 1 runtime failure, 2 usage error.
#
# Output is written through a temporary file and renamed into place, so a
# browser refreshing on its own cadence never reads a half-written board.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SNAPSHOT_CMD="$SCRIPT_DIR/fm-fleet-snapshot.sh"

usage() {
  sed -n '/^# Usage:/,/^# Exit codes/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

die() { echo "fm-mission-control: $1" >&2; exit "${2:-1}"; }

OUT=""
TO_STDOUT=0
WITH_QUOTA=1
REFRESH=25
SNAPSHOT_FILE=""

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --out) [ $# -ge 2 ] || die "--out needs a path" 2; OUT=$2; shift 2 ;;
    --stdout) TO_STDOUT=1; shift ;;
    --no-quota) WITH_QUOTA=0; shift ;;
    --refresh)
      [ $# -ge 2 ] || die "--refresh needs seconds" 2
      case "$2" in ''|*[!0-9]*|0) die "--refresh must be a positive integer" 2 ;; esac
      REFRESH=$2; shift 2 ;;
    --snapshot)
      [ $# -ge 2 ] || die "--snapshot needs a file" 2
      SNAPSHOT_FILE=$2; shift 2 ;;
    *) usage >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 || die "jq not found"

if [ -n "$SNAPSHOT_FILE" ]; then
  [ -r "$SNAPSHOT_FILE" ] || die "snapshot file not readable: $SNAPSHOT_FILE"
  SNAPSHOT=$(cat "$SNAPSHOT_FILE") || die "could not read $SNAPSHOT_FILE"
else
  SNAPSHOT=$("$SNAPSHOT_CMD" --json) || die "fleet snapshot failed"
fi
printf '%s' "$SNAPSHOT" | jq -e 'type == "object" and has("tasks")' >/dev/null 2>&1 \
  || die "fleet snapshot did not return the expected object"

STATE_DIR=$(printf '%s' "$SNAPSHOT" | jq -r '.roots.state // ""')
DATA_DIR=$(printf '%s' "$SNAPSHOT" | jq -r '.roots.data // ""')

NOW=${FM_MISSION_CONTROL_NOW_EPOCH:-$(date +%s)}
case "$NOW" in ''|*[!0-9]*) NOW=$(date +%s) ;; esac

# Modification time of one file, or empty when it is absent or unreadable.
# BSD and GNU stat need separate invocations: `stat -f` asks GNU stat for
# FILESYSTEM status and succeeds with output that is not a timestamp at all, so
# a "try one, fall back to the other" chain reads the wrong thing on Linux
# rather than failing over. A non-numeric answer degrades to no time rather
# than breaking the render.
file_mtime() {  # <path>
  local mtime
  [ -e "$1" ] || return 0
  if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
    mtime=$(stat -f '%m' "$1" 2>/dev/null) || return 0
  else
    mtime=$(stat -c '%Y' "$1" 2>/dev/null) || return 0
  fi
  case "$mtime" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s\n' "$mtime"
}

# Per-task record and last-update times keyed by task id. The snapshot's
# observed_at fields are observation times, not task times, so these come from
# the task's own durable records instead.
TIMES=$(
  printf '%s' "$SNAPSHOT" | jq -r '.tasks[]?.id' | while IFS= read -r id; do
    [ -n "$id" ] || continue
    start=$(file_mtime "$STATE_DIR/$id.meta")
    last=$(file_mtime "$STATE_DIR/$id.status")
    printf '%s\t%s\t%s\n' "$id" "${start:-}" "${last:-}"
  done | jq -R -s '
    split("\n") | map(select(length > 0) | split("\t")) |
    map({key: .[0], value: {
      start: (if (.[1] // "") == "" then null else (.[1] | tonumber) end),
      last:  (if (.[2] // "") == "" then null else (.[2] | tonumber) end)}}) |
    from_entries'
) || die "could not read task times"

PROJECTS_RAW=""
PROJECTS_PRESENT=false
if [ -n "$DATA_DIR" ] && [ -r "$DATA_DIR/projects.md" ]; then
  PROJECTS_RAW=$(cat "$DATA_DIR/projects.md") || PROJECTS_RAW=""
  PROJECTS_PRESENT=true
fi

# Allowance gauges are best-effort: an absent, failing, or non-JSON quota-axi
# renders as an explicit "unavailable" note, never as an empty zero gauge.
QUOTA='null'
QUOTA_NOTE="not requested"
if [ "$WITH_QUOTA" = 1 ]; then
  quota_raw=""
  if [ -n "${FM_MISSION_CONTROL_QUOTA_JSON:-}" ]; then
    if [ -r "$FM_MISSION_CONTROL_QUOTA_JSON" ]; then
      quota_raw=$(cat "$FM_MISSION_CONTROL_QUOTA_JSON" 2>/dev/null) || quota_raw=""
      QUOTA_NOTE="captured payload unreadable"
    else
      QUOTA_NOTE="captured payload not found"
    fi
  elif command -v quota-axi >/dev/null 2>&1; then
    quota_raw=$(quota-axi --json 2>/dev/null </dev/null) || quota_raw=""
    QUOTA_NOTE="quota-axi returned no usable reading"
  else
    QUOTA_NOTE="quota-axi not installed"
  fi
  if [ -n "$quota_raw" ] && printf '%s' "$quota_raw" | jq -e 'type == "object"' >/dev/null 2>&1; then
    QUOTA=$quota_raw
    QUOTA_NOTE=""
  fi
fi

HTML=$(
  printf '%s' "$SNAPSHOT" | jq -r \
    --argjson quota "$QUOTA" \
    --argjson times "$TIMES" \
    --arg quota_note "$QUOTA_NOTE" \
    --arg projects_raw "$PROJECTS_RAW" \
    --argjson projects_present "$PROJECTS_PRESENT" \
    --argjson now "$NOW" \
    --argjson refresh "$REFRESH" '

# --------------------------------------------------------------------------
# Escaping rule: every value that came from fleet state, the registry, or the
# allowance reading is interpolated through an @html format string, which
# escapes interpolations but not the surrounding literal markup. Fragments are
# joined with "+" and never interpolated into another @html string, so nothing
# is ever escaped twice.
# --------------------------------------------------------------------------
def dash($v): if ($v // "") == "" then "-" else ($v | tostring) end;

def ago($epoch):
  if $epoch == null then null
  else ($now - $epoch) as $d |
    if $d < 0 then "just now"
    elif $d < 60 then "\($d)s"
    elif $d < 3600 then "\(($d / 60) | floor)m"
    elif $d < 86400 then "\(($d / 3600) | floor)h \((($d % 3600) / 60) | floor)m"
    else "\(($d / 86400) | floor)d \((($d % 86400) / 3600) | floor)h"
    end
  end;

# A backlog row may record its repo as a bare name or as a full clone path.
# Both name the same project, so both are reduced to the registry name: it is
# what the rollup matches on and what fits inside a card.
def short_repo:
  if (. // "") == "" then ""
  elif test("/") then (split("/") | map(select(length > 0)) | last // "")
  else . end;

def repo_of:
  (.backlog.repo // "" | short_repo) as $r |
  if $r != "" then $r
  elif (.project // "") != "" then (.project | short_repo)
  else "" end;

def state_tone:
  if . == null then "unknown"
  elif test("fail|error|cancel"; "i") then "alert"
  elif test("block"; "i") then "alert"
  elif test("decision|approval|review"; "i") then "warn"
  elif test("done|passed|green|merged"; "i") then "good"
  elif test("work|running|fix|check|busy"; "i") then "live"
  elif test("paus|idle|wait"; "i") then "calm"
  else "unknown" end;

# ---------------------------------------------------------------- registry --
def registry:
  if $projects_present | not then []
  else
    ($projects_raw | split("\n")) |
    map(select(test("^- \\S")) |
      (capture("^- (?<name>\\S+) \\[(?<mode>[^\\]]*)\\] - (?<desc>.*)$") // null) |
      select(. != null) |
      {name, mode: (.mode | sub(" *\\+yolo"; "")), yolo: (.mode | test("\\+yolo")), desc}) |
    map(select(.name != null))
  end;

registry as $registry |
($registry | map({key: .name, value: .}) | from_entries) as $registry_by_name |
def yolo_for($repo): ($registry_by_name[$repo // ""].yolo // false);

(.tasks // []) as $tasks |
(.backlog.records // []) as $records |
(.backlog.present == true) as $backlog_present |
($tasks | map(select(.kind != "secondmate"))) as $work_tasks |
($tasks | map(select(.kind == "secondmate"))) as $secondmate_tasks |
(.secondmate_current.records // []) as $sm_records |
(.secondmate_current.registry // {}) as $sm_registry |
(($sm_registry.available == true)
  and ($sm_registry.complete == true)
  and ($sm_registry.input_truncated != true)
  and ($sm_registry.records_truncated != true)) as $sm_registry_complete |

# ------------------------------------------------------- waiting on you ----
# Three canonical sources, each tagged with the home it came from: main-home
# captain-actionable backlog rows, tasks whose PR is recorded and awaiting a
# merge or review call, and captain-held decisions inside a secondmate home
# (which never appear in this home'"'"'s backlog).
($records | map(select(.captain_actionable == true)) | map({
  kind: "decision",
  home: "main",
  id: .id,
  title: (.title // .raw),
  detail: (.hold_reason // .blocked_reason // ""),
  repo: (.repo // "" | short_repo),
  link: (.pr_url // .report_path // (.links // [])[0] // null)
})) as $waiting_decisions |

($work_tasks | map(select((.pr.url // "") != "")) | map(. as $t | {
  kind: "pr",
  home: "main",
  id: $t.id,
  title: ($t.backlog.title // $t.id),
  detail: ($t.current_state.state // "unknown"),
  repo: ($t | repo_of),
  yolo: ($t | repo_of | yolo_for(.)),
  link: $t.pr.url
})) as $waiting_prs |

($sm_records | map(. as $sm |
  ($sm.decisions_open // []) | map({
    kind: "decision",
    home: ($sm.id // "secondmate"),
    id: (.id // .key),
    title: (.summary // .key // "decision"),
    detail: (.reason // ""),
    repo: "",
    link: null
  })) | add // []) as $waiting_secondmate |

($sm_records | map(. as $sm |
  (($sm.decisions_open // []) | length) as $shown |
  ([($sm.omitted // [])[] | select(.surface == "decisions_open") | (.count // 0)] | add // 0) as $omitted |
  ([($sm.counts.decisions_open // $shown), ($shown + $omitted), $shown] | max) as $total |
  select($total > $shown) |
  {
    kind: "incomplete",
    home: ($sm.id // "secondmate"),
    id: (($sm.id // "secondmate") + "/omitted-decisions"),
    title: "Additional captain decisions are not shown",
    detail: ("Snapshot shows \($shown) of \($total) decisions. Inspect this secondmate home for all \($total - $shown) omitted decisions."),
    repo: "",
    link: null,
    omitted_count: ($total - $shown)
  })) as $waiting_secondmate_omitted |

((.secondmate_current.truncated // 0) | if . < 0 then 0 else . end) as $sm_truncated |
(if $sm_truncated > 0 then [{
  kind: "incomplete",
  home: "secondmates",
  id: "secondmate-current/truncated",
  title: "Secondmate decision scan is incomplete",
  detail: ("Snapshot omitted \($sm_truncated) secondmate record(s). Inspect the full fleet state before concluding that no other captain decisions are waiting."),
  repo: "",
  link: null
}] else [] end) as $waiting_secondmate_truncated |

(if $sm_registry_complete then [] else [{
  kind: "incomplete",
  home: "secondmates",
  id: "secondmate-registry/incomplete",
  title: "Secondmate registry scan is incomplete",
  detail: (if $sm_registry.available != true
    then ("Registered secondmate table is unavailable: \($sm_registry.reason // "unknown reason"). Additional homes and captain decisions may be missing.")
    else ("Registered secondmate table was bounded or incomplete\(if (($sm_registry.reasons // []) | length) > 0 then " (\(($sm_registry.reasons // []) | join(", ")))" else "" end). Additional homes and captain decisions may be missing.")
    end),
  repo: "",
  link: null
}] end) as $waiting_secondmate_registry |

($sm_records | map(select(
  .registered == true
  and ((.provenance.selected // "") != "structured-home")) | {
    kind: "incomplete",
    home: (.id // "secondmate"),
    id: ((.id // "secondmate") + "/decisions-unavailable"),
    title: "Registered secondmate decisions are unavailable",
    detail: ("Captain decisions for this registered secondmate could not be read: \(.current.reason // "structured home unavailable"). Inspect the secondmate home before concluding that nothing is waiting."),
    repo: "",
    link: null
  })) as $waiting_secondmate_unavailable |

(if $backlog_present then [] else [{
  kind: "incomplete",
  home: "main",
  id: "main/backlog-unavailable",
  title: "Main backlog is unavailable",
  detail: "Captain decisions from the main backlog cannot be counted. Restore or inspect the backlog before concluding that nothing is waiting.",
  repo: "",
  link: null
}] end) as $waiting_backlog_unavailable |

($waiting_decisions + $waiting_secondmate) as $waiting_calls |
($waiting_calls + $waiting_prs) as $waiting |
($waiting_secondmate_omitted + $waiting_secondmate_truncated + $waiting_secondmate_registry + $waiting_secondmate_unavailable + $waiting_backlog_unavailable) as $waiting_notices |
(($waiting | length) + ($waiting_secondmate_omitted | map(.omitted_count) | add // 0)) as $waiting_count |
((($backlog_present | not)
  or $sm_truncated > 0
  or ($waiting_secondmate_omitted | length) > 0
  or ($waiting_secondmate_registry | length) > 0
  or ($waiting_secondmate_unavailable | length) > 0)) as $waiting_incomplete |

# ----------------------------------------------------------- fleet health --
($work_tasks | map(select(
  ((.current_state.state // "") | test("block|fail|error|cancel"; "i"))
  or (.hints.blocked_event == true)))) as $unhealthy |
($records | map(select(.state != "done" and ((.unresolved_blocker_ids // []) | length) > 0))) as $blocked_items |

# ------------------------------------------------------------- rollup ------
($registry | map(. as $p |
  ($records | map(select((.repo // "" | short_repo) == $p.name))) as $rows |
  {
    name: $p.name,
    mode: $p.mode,
    yolo: $p.yolo,
    active: ($work_tasks | map(select((. | repo_of) == $p.name)) | length),
    queued: ($rows | map(select(.state == "queued")) | length),
    in_flight: ($rows | map(select(.state == "in_flight")) | length),
    waiting: ($rows | map(select(.captain_actionable == true)) | length),
    done: ($rows | map(select(.state == "done")) | length)
  })) as $rollup |

($records | map(select(.state == "done")) | .[0:8]) as $shipped |

# ------------------------------------------------------------- fragments ---
def card_waiting:
  . as $w |
  ($w.link // "") as $link |
  (if $w.kind == "pr" then (if $w.yolo then "merge call (autonomous)" else "review or merge" end)
   elif $w.kind == "incomplete" then "incomplete scan"
   else "decision" end) as $badge |
  (@html "<article class=\"call \($w.kind)\">
     <header><span class=\"badge\">\($badge)</span>")
  + (if ($w.home // "main") == "main" then ""
     else (@html "<span class=\"home\">\($w.home)</span>") end)
  + (if ($w.repo // "") == "" then ""
     else (@html "<span class=\"repo\">\($w.repo)</span>") end)
  + (@html "</header>
     <h3>\($w.title)</h3>")
  + (if ($w.detail // "") == "" then "" else (@html "<p class=\"why\">\($w.detail)</p>") end)
  + (if $link == "" or $link == null then "" else (@html "<a class=\"link\" href=\"\($link)\">\($link)</a>") end)
  + (@html "<footer class=\"mono\">\($w.id)</footer></article>");

def card_task:
  . as $t |
  ($times[$t.id] // {}) as $tm |
  ($t.current_state.state // "unknown") as $st |
  ($t.paths.status_log.last_event.raw // "") as $last |
  (@html "<article class=\"task tone-\($st | state_tone)\">
     <header>
       <span class=\"dot\"></span>
       <span class=\"state\">\($st)</span>
       <span class=\"kindtag\">\(dash($t.kind))</span>
       <span class=\"repo\">\(dash($t | repo_of))</span>
     </header>
     <h3>\(dash($t.backlog.title // $t.id))</h3>
     <dl class=\"facts\">
       <div><dt>phase</dt><dd>\(dash($t.current_state.detail // $t.current_state.source))</dd></div>
       <div><dt>task record age</dt><dd>\(dash(ago($tm.start)))</dd></div>
       <div><dt>last update</dt><dd>\(dash(if $tm.last == null then null else (ago($tm.last) + " ago") end))</dd></div>
       <div><dt>runtime</dt><dd>\(dash($t.backend))\(if ($t.harness // "") != "" then " / " else "" end)\(dash($t.harness))</dd></div>
     </dl>")
  + (if $last == "" then "" else (@html "<p class=\"lastline mono\">\($last)</p>") end)
  + "<p class=\"slot\" data-slot=\"progress-note\">progress note - populated by firstmate in phase 2</p>"
  + (@html "<footer class=\"mono\">\($t.id) \(dash($t.mode))\(if ($t.yolo // "") == "on" then " +yolo" else "" end)</footer></article>");

def gauge($label; $pct; $note):
  (if $pct == null then "muted"
   elif $pct <= 15 then "alert"
   elif $pct <= 35 then "warn"
   else "good" end) as $tone |
  (@html "<div class=\"gauge tone-\($tone)\">
     <div class=\"glabel\"><span>\($label)</span><span class=\"mono\">\(if $pct == null then "-" else "\($pct)%" end)</span></div>
     <div class=\"bar\"><i style=\"width:\(if $pct == null then 0 else $pct end)%\"></i></div>
     <div class=\"gnote\">\($note)</div>
   </div>");

def quota_block:
  if $quota == null then
    (@html "<p class=\"empty\">Allowance unavailable - \($quota_note).</p>")
  else
    (($quota.providers // []) | map(. as $p |
      $p + {wins: (($p.windows // []) | map(select((.percentRemaining // null) != null)))})) as $providers |
    ($providers | map(select((.wins | length) > 0))) as $measured |
    ($providers | map(select((.wins | length) == 0))) as $unmeasured |
    # A provider with no readable window is a sign-in or reporting gap, not an
    # exhausted allowance, so it never renders as an empty zero gauge.
    (($measured | map(. as $p |
      ($p.wins | map(gauge(("\($p.label // $p.provider) / \(.label // .id)");
                           (.percentRemaining | floor);
                           ("resets \(.resetsAt // "-")"))) | add)) | add) // "")
    + (if ($unmeasured | length) == 0 then ""
       else "<ul class=\"unmeasured\">"
         + (($unmeasured | map(. as $p |
             (@html "<li><span>\($p.label // $p.provider)</span><span class=\"mono\">\($p.state.error // $p.state.status // "no window reported")</span></li>")) | add) // "")
         + "</ul>" end)
    + (if ($providers | length) == 0 then "<p class=\"empty\">No allowance providers reported.</p>" else "" end)
  end;

def secondmate_block:
  (if $sm_registry_complete then ""
   else "<p class=\"empty\">Secondmate registry state is incomplete, so registered homes may be missing.</p>" end)
  + (if ($sm_records | length) == 0 and (($sm_registry.records // []) | length) == 0 then
    (if $sm_registry_complete then "<p class=\"empty\">No second mates registered.</p>" else "" end)
  else
    ($sm_records | map(. as $sm |
      ($secondmate_tasks | map(select(.id == $sm.id)) | first) as $task |
      ($sm.current.state // "unknown") as $st |
      ((.registered != true) or ((.provenance.selected // "") == "structured-home")) as $decisions_available |
      (($sm.decisions_open // []) | length) as $decisions_shown |
      ([($sm.omitted // [])[] | select(.surface == "decisions_open") | (.count // 0)] | add // 0) as $decisions_omitted |
      ([($sm.counts.decisions_open // $decisions_shown), ($decisions_shown + $decisions_omitted), $decisions_shown] | max) as $decisions |
      (($sm.active_children // []) | length) as $children |
      (@html "<article class=\"secondmate\">
        <header><span class=\"dot\"></span><h3>\($sm.id)</h3><span class=\"state\">\($st)</span></header>
        <dl class=\"facts\">
          <div><dt>routed work</dt><dd>\(if $children == 0 then "none - idle is healthy" else "\($children) under way" end)</dd></div>
          <div><dt>your decisions</dt><dd>\(if ($decisions_available | not) then "unavailable" elif $decisions == 0 then "none" elif $decisions > $decisions_shown then "\($decisions) waiting (\($decisions_shown) shown)" else "\($decisions) waiting" end)</dd></div>
          <div><dt>reachable</dt><dd>\(if ($task.endpoint.exists // false) then "yes" else ($task.endpoint.agent_alive // "unknown") end)</dd></div>
        </dl>")
      + (if ($sm.current.reason // "") == "" then "" else (@html "<p class=\"why\">\($sm.current.reason)</p>") end)
      + (@html "<footer class=\"mono\">\(dash($sm.home))</footer></article>")) | add // "")
  end);

# ------------------------------------------------------------------ page ---
"<!doctype html>
<html lang=\"en\"><head>
<meta charset=\"utf-8\">
<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">
<meta http-equiv=\"refresh\" content=\"" + ($refresh | tostring) + "\">
<title>Firstmate Mission Control</title>
<style>
:root{
  --bg:#05080c; --bg2:#080d13; --panel:#0c141d; --panel2:#101a25;
  --line:#1a2836; --line2:#243546;
  --ink:#dbe7f2; --dim:#7b90a5; --faint:#4d6076;
  --teal:#2ee7bd; --amber:#ffb545; --red:#ff5470; --violet:#9b8cff;
  --mono:ui-monospace,SFMono-Regular,\"SF Mono\",Menlo,Consolas,monospace;
}
*{box-sizing:border-box;min-width:0}
html,body{margin:0;padding:0}
body{
  background:
    radial-gradient(1100px 620px at 12% -8%, #0d2030 0%, transparent 62%),
    radial-gradient(900px 520px at 92% 4%, #131028 0%, transparent 58%),
    var(--bg);
  color:var(--ink);
  font:15px/1.5 ui-sans-serif,-apple-system,\"Segoe UI\",Inter,system-ui,sans-serif;
  -webkit-font-smoothing:antialiased;
  padding:0 0 56px;
}
.mono{font-family:var(--mono)}
a{color:var(--teal);text-decoration:none;word-break:break-all}
a:hover{text-decoration:underline}
.wrap{max-width:1500px;margin:0 auto;padding:0 22px}

/* ---- top bar ---- */
.top{
  position:sticky;top:0;z-index:20;
  background:linear-gradient(180deg,rgba(5,8,12,.97),rgba(5,8,12,.82));
  border-bottom:1px solid var(--line);
  backdrop-filter:blur(9px);
}
.top .wrap{display:flex;align-items:center;gap:18px;flex-wrap:wrap;padding-top:14px;padding-bottom:14px}
.brand{display:flex;align-items:baseline;gap:10px;font-weight:700;letter-spacing:.16em;text-transform:uppercase;font-size:13px}
.brand b{color:var(--teal);letter-spacing:.2em}
.brand span{color:var(--faint)}
.live{display:flex;align-items:center;gap:8px;font-family:var(--mono);font-size:12px;color:var(--dim)}
.pulse{width:8px;height:8px;border-radius:50%;background:var(--teal);box-shadow:0 0 0 0 rgba(46,231,189,.6);animation:p 2.4s infinite}
.stale .pulse{background:var(--amber);animation:none}
@keyframes p{0%{box-shadow:0 0 0 0 rgba(46,231,189,.55)}70%{box-shadow:0 0 0 9px rgba(46,231,189,0)}100%{box-shadow:0 0 0 0 rgba(46,231,189,0)}}
.top .spacer{flex:1}
.counts{display:flex;gap:8px;flex-wrap:wrap}
.pill{font-family:var(--mono);font-size:11.5px;letter-spacing:.06em;padding:4px 10px;border-radius:999px;border:1px solid var(--line2);color:var(--dim);background:var(--panel)}
.pill b{color:var(--ink)}
.pill.hot{border-color:rgba(255,84,112,.55);color:#ffd7de}
.pill.hot b{color:var(--red)}

/* ---- sections ---- */
section{margin-top:30px}
h2{
  display:flex;align-items:center;gap:12px;flex-wrap:wrap;
  font-size:12.5px;letter-spacing:.2em;text-transform:uppercase;color:var(--dim);
  margin:0 0 14px;font-weight:700;
}
h2 .rule{flex:1;height:1px;background:linear-gradient(90deg,var(--line2),transparent);min-width:24px}
h2 .n{font-family:var(--mono);color:var(--faint);letter-spacing:0}
h2 .scope{font-size:10.5px;letter-spacing:.06em;text-transform:none;color:var(--faint);font-weight:400}
.empty{color:var(--faint);font-size:13.5px;margin:0;padding:14px 16px;border:1px dashed var(--line2);border-radius:10px}

/* ---- waiting on you ---- */
.alert{
  border:1px solid rgba(255,84,112,.42);
  border-radius:16px;
  background:linear-gradient(180deg,rgba(255,84,112,.10),rgba(255,84,112,.02) 60%,transparent),var(--panel);
  box-shadow:0 0 0 1px rgba(255,84,112,.08),0 24px 60px -34px rgba(255,84,112,.5);
  padding:20px 20px 22px;margin-top:26px;
}
.alert.clear{border-color:var(--line2);background:var(--panel);box-shadow:none}
.alert h2{color:#ffb9c4;font-size:14px;letter-spacing:.22em;margin-bottom:16px}
.alert.clear h2{color:var(--dim)}
.calls{display:grid;grid-template-columns:repeat(auto-fill,minmax(330px,1fr));gap:12px}
.call{
  border:1px solid var(--line2);border-left:3px solid var(--red);
  border-radius:11px;background:var(--panel2);padding:13px 15px;
  display:flex;flex-direction:column;gap:8px;
}
.call.pr{border-left-color:var(--amber)}
.call header{display:flex;align-items:center;gap:8px;flex-wrap:wrap;font-size:11px;letter-spacing:.09em;text-transform:uppercase}
.badge{font-family:var(--mono);color:#ffd7de;background:rgba(255,84,112,.14);border:1px solid rgba(255,84,112,.34);border-radius:5px;padding:2px 7px}
.call.pr .badge{color:#ffe2ba;background:rgba(255,181,69,.13);border-color:rgba(255,181,69,.34)}
.home{color:var(--violet);font-family:var(--mono);border:1px solid rgba(155,140,255,.32);border-radius:5px;padding:1px 6px;overflow-wrap:anywhere}
.repo{color:var(--dim);font-family:var(--mono);overflow-wrap:anywhere}
.call h3{margin:0;font-size:15.5px;line-height:1.35;font-weight:620}
.why{margin:0;color:var(--dim);font-size:13px;line-height:1.5}
.call .link{font-family:var(--mono);font-size:12.5px}
.call footer,.task footer,.secondmate footer{color:var(--faint);font-size:11px;margin-top:2px;overflow-wrap:anywhere}

/* ---- main grid ---- */
.grid{display:grid;grid-template-columns:minmax(0,2fr) minmax(0,1fr);gap:26px;align-items:start}
.cards{display:grid;grid-template-columns:repeat(auto-fill,minmax(340px,1fr));gap:13px}
.task,.secondmate{
  border:1px solid var(--line);border-radius:12px;background:var(--panel);
  padding:14px 16px;display:flex;flex-direction:column;gap:10px;position:relative;overflow:hidden;
}
.task::before{content:\"\";position:absolute;inset:0 auto 0 0;width:2px;background:var(--faint)}
.task.tone-live::before{background:var(--teal)}
.task.tone-warn::before{background:var(--amber)}
.task.tone-alert::before{background:var(--red)}
.task.tone-good::before{background:var(--teal)}
.task.tone-calm::before{background:var(--violet)}
.task header,.secondmate header{display:flex;align-items:center;gap:9px;flex-wrap:wrap;font-size:11px;letter-spacing:.09em;text-transform:uppercase}
.dot{width:7px;height:7px;border-radius:50%;background:var(--faint);flex:none}
.tone-live .dot{background:var(--teal);box-shadow:0 0 8px rgba(46,231,189,.8)}
.tone-warn .dot{background:var(--amber);box-shadow:0 0 8px rgba(255,181,69,.7)}
.tone-alert .dot{background:var(--red);box-shadow:0 0 8px rgba(255,84,112,.7)}
.tone-good .dot{background:var(--teal)}
.state{font-family:var(--mono);color:var(--ink);font-weight:600}
.kindtag{font-family:var(--mono);color:var(--faint);border:1px solid var(--line2);border-radius:5px;padding:1px 6px}
.task h3,.secondmate h3{margin:0;font-size:15px;line-height:1.35;font-weight:600}
.secondmate h3{text-transform:none;letter-spacing:0;font-size:15px}
.facts{display:grid;grid-template-columns:repeat(auto-fit,minmax(118px,1fr));gap:8px 14px;margin:0}
.facts div{min-width:0}
.facts dt{font-size:10px;letter-spacing:.11em;text-transform:uppercase;color:var(--faint)}
.facts dd{margin:2px 0 0;font-family:var(--mono);font-size:12.5px;color:var(--ink);overflow-wrap:anywhere}
.lastline{
  margin:0;font-size:12px;color:var(--dim);background:var(--bg2);
  border:1px solid var(--line);border-radius:8px;padding:8px 10px;
  overflow-wrap:anywhere;max-height:5.4em;overflow:hidden;
}
.slot{
  margin:0;font-size:11px;letter-spacing:.05em;color:var(--faint);
  border:1px dashed var(--line2);border-radius:8px;padding:7px 10px;background:rgba(155,140,255,.045);
}

/* ---- rail ---- */
.rail{display:flex;flex-direction:column;gap:26px}
.panel{border:1px solid var(--line);border-radius:12px;background:var(--panel);padding:15px 16px}
.gauge{margin-bottom:13px}
.gauge:last-child{margin-bottom:0}
.glabel{display:flex;justify-content:space-between;gap:10px;font-size:11.5px;color:var(--dim);margin-bottom:6px}
.glabel span:first-child{overflow-wrap:anywhere}
.glabel .mono{color:var(--ink);font-weight:600;flex:none}
.bar{height:6px;border-radius:4px;background:var(--bg2);border:1px solid var(--line);overflow:hidden}
.bar i{display:block;height:100%;background:var(--teal)}
.tone-warn .bar i{background:var(--amber)}
.tone-alert .bar i{background:var(--red)}
.tone-muted .bar i{background:var(--faint)}
.gnote{font-size:10.5px;color:var(--faint);margin-top:5px;font-family:var(--mono);overflow-wrap:anywhere}
.unmeasured{margin:14px 0 0;padding:12px 0 0;border-top:1px solid var(--line);list-style:none}
.unmeasured li{display:flex;justify-content:space-between;gap:12px;font-size:11.5px;color:var(--dim);margin-bottom:6px}
.unmeasured li:last-child{margin-bottom:0}
.unmeasured .mono{color:var(--faint);font-size:10.5px;text-align:right;overflow-wrap:anywhere}
.health li{margin-bottom:9px;color:var(--dim);font-size:13px;list-style:none}
.health ul{margin:0;padding:0}
.health b{color:var(--red);font-family:var(--mono);font-weight:600}
.health .warnid{color:var(--amber);font-family:var(--mono)}

/* ---- tables / strips ---- */
.tablewrap{overflow-x:auto;border:1px solid var(--line);border-radius:12px;background:var(--panel)}
table{border-collapse:collapse;width:100%;font-size:13px}
th{
  text-align:left;font-size:10px;letter-spacing:.13em;text-transform:uppercase;color:var(--faint);
  font-weight:600;padding:11px 14px;border-bottom:1px solid var(--line);white-space:nowrap;
}
td{padding:10px 14px;border-bottom:1px solid rgba(26,40,54,.6);vertical-align:top}
tr:last-child td{border-bottom:none}
td.num{font-family:var(--mono);text-align:right;width:1%;white-space:nowrap}
td.num.zero{color:var(--faint)}
td.hot{color:var(--red);font-weight:600}
.tag{font-family:var(--mono);font-size:10.5px;border:1px solid var(--line2);border-radius:5px;padding:1px 6px;color:var(--dim);white-space:nowrap}
.tag.yolo{color:#bff4e6;border-color:rgba(46,231,189,.4);background:rgba(46,231,189,.08)}
.shipped{display:grid;grid-template-columns:repeat(auto-fill,minmax(330px,1fr));gap:11px}
.ship{border:1px solid var(--line);border-left:3px solid var(--teal);border-radius:10px;background:var(--panel);padding:12px 14px}
.ship h4{margin:0 0 6px;font-size:14px;font-weight:580;line-height:1.35}
.ship .meta{font-family:var(--mono);font-size:11px;color:var(--faint);display:flex;gap:9px;flex-wrap:wrap;margin-bottom:6px}
.ship a{font-family:var(--mono);font-size:12px}
footer.foot{margin-top:34px;color:var(--faint);font-size:11.5px;font-family:var(--mono);overflow-wrap:anywhere}

@media (max-width:1080px){ .grid{grid-template-columns:minmax(0,1fr)} }
@media (max-width:640px){
  .wrap{padding:0 13px}
  .calls,.cards,.shipped{grid-template-columns:minmax(0,1fr)}
  .top .wrap{gap:10px}
  .brand{font-size:11.5px}
  .alert{padding:15px 14px 16px;border-radius:13px}
}
</style>
</head><body>

<div class=\"top\" id=\"top\"><div class=\"wrap\">
  <div class=\"brand\"><b>Firstmate</b> <span>//</span> Mission Control</div>
  <div class=\"live\"><span class=\"pulse\"></span><span id=\"age\">rendered "
+ (@html "\(.generated)") + "</span></div>
  <div class=\"spacer\"></div>
  <div class=\"counts\">"
+ (if $waiting_incomplete
   then (@html "<span class=\"pill hot\"><b>\($waiting_count)+</b> waiting known</span>")
   elif $waiting_count > 0
   then (@html "<span class=\"pill hot\"><b>\($waiting_count)</b> waiting on you</span>")
   else "<span class=\"pill\"><b>0</b> waiting on you</span>" end)
+ (@html "<span class=\"pill\"><b>\($work_tasks | length)</b> under way</span>")
+ (if $backlog_present
   then (@html "<span class=\"pill\"><b>\($records | map(select(.state == "queued")) | length)</b> queued</span>")
   else "<span class=\"pill hot\"><b>?</b> queued - backlog unavailable</span>" end)
+ (@html "<span class=\"pill\"><b>\($rollup | length)</b> projects</span>")
+ "</div>
</div></div>

<div class=\"wrap\">

<section class=\"alert" + (if $waiting_count == 0 and ($waiting_incomplete | not) then " clear" else "" end) + "\">
  <h2>" + (if $waiting_incomplete then "&#9888; Waiting status incomplete" elif $waiting_count == 0 then "&#9989; Nothing waiting on you" else "&#9888; Waiting on you" end)
+ (@html "<span class=\"n\">\($waiting_count)\(if $waiting_incomplete then "+ known" else "" end)</span>") + "<i class=\"rule\"></i></h2>"
+ (if $waiting_count == 0 and ($waiting_incomplete | not)
   then "<p class=\"empty\">No decisions, reviews, or merges need the captain right now.</p>"
   else "<div class=\"calls\">" + (($waiting_notices | map(card_waiting) | add) // "")
        + (($waiting_calls | map(card_waiting) | add) // "")
        + (($waiting_prs | map(card_waiting) | add) // "") + "</div>" end)
+ "</section>

<div class=\"grid\">
<div>
  <section>
    <h2>&#128295; In progress" + (@html "<span class=\"n\">\($work_tasks | length)</span>") + "<i class=\"rule\"></i></h2>"
+ (if ($work_tasks | length) == 0
   then "<p class=\"empty\">No work under way.</p>"
   else "<div class=\"cards\">" + (($work_tasks | map(card_task) | add) // "") + "</div>" end)
+ "  </section>

  <section>
    <h2>&#9989; Recently shipped" + (if $backlog_present then (@html "<span class=\"n\">\($shipped | length)</span>") else "<span class=\"n\">unavailable</span>" end) + "<i class=\"rule\"></i></h2>"
+ (if ($backlog_present | not)
   then "<p class=\"empty\">Recently shipped is unavailable because the backlog could not be read.</p>"
   elif ($shipped | length) == 0
   then "<p class=\"empty\">Nothing landed yet.</p>"
   else "<div class=\"shipped\">" + (($shipped | map(. as $d |
     (@html "<article class=\"ship\">
        <h4>\(dash($d.title // $d.raw))</h4>
        <div class=\"meta\"><span>\(dash(($d.repo // "") | short_repo))</span><span>\(dash($d.completion.verb // "done"))</span><span>\(dash($d.completion.date))</span></div>")
     + ((($d.pr_url // $d.report_path // ($d.links // [])[0]) // "") as $l |
        if $l == "" then "" else (@html "<a href=\"\($l)\">\($l)</a>") end)
     + "</article>") | add) // "") + "</div>" end)
+ "  </section>

  <section>
    <h2>&#128506; Projects" + (@html "<span class=\"n\">\($rollup | length)</span>")
+ "<span class=\"scope\">registered projects only</span><i class=\"rule\"></i></h2>"
+ (if ($rollup | length) == 0
   then "<p class=\"empty\">No project registry found - firstmate rebuilds it from the clones.</p>"
   else (if $backlog_present then "" else "<p class=\"empty\">Backlog-derived project counts are unavailable.</p>" end)
   + "<div class=\"tablewrap\"><table><thead><tr>
     <th>Project</th><th>Delivery</th><th class=\"num\">Active</th><th class=\"num\">In flight</th>
     <th class=\"num\">Queued</th><th class=\"num\">Waiting</th><th class=\"num\">Shipped</th></tr></thead><tbody>"
   + (($rollup | map(. as $p |
       "<tr>" + (@html "<td><span class=\"mono\">\($p.name)</span></td>
        <td><span class=\"tag\">\($p.mode)</span>")
       + (if $p.yolo then "<span class=\"tag yolo\">+yolo</span>" else "" end) + "</td>"
       + (@html "<td class=\"num\(if $p.active == 0 then " zero" else "" end)\">\($p.active)</td>")
       + (if $backlog_present then (@html "<td class=\"num\(if $p.in_flight == 0 then " zero" else "" end)\">\($p.in_flight)</td>
          <td class=\"num\(if $p.queued == 0 then " zero" else "" end)\">\($p.queued)</td>
          <td class=\"num\(if $p.waiting == 0 then " zero" else " hot" end)\">\($p.waiting)</td>
          <td class=\"num\(if $p.done == 0 then " zero" else "" end)\">\($p.done)</td>")
          else "<td class=\"num zero\">-</td><td class=\"num zero\">-</td><td class=\"num zero\">-</td><td class=\"num zero\">-</td>" end)
       + "</tr>") | add) // "")
   + "</tbody></table></div>" end)
+ "  </section>
</div>

<div class=\"rail\">
  <section>
    <h2>&#128678; Fleet health<i class=\"rule\"></i></h2>
    <div class=\"panel health\">"
+ (if ($backlog_present | not)
   then "<p class=\"empty\">Backlog health is unavailable because the backlog could not be read.</p>"
     + (if ($unhealthy | length) == 0 then "" else "<ul>"
       + (($unhealthy | map(. as $t |
           (@html "<li><b>\($t.current_state.state // "blocked")</b> \($t.id)<br><span class=\"mono\">\(dash($t.paths.status_log.last_event.raw))</span></li>")) | add) // "")
       + "</ul>" end)
   elif ($unhealthy | length) == 0 and ($blocked_items | length) == 0
   then "<p class=\"empty\">Nothing blocked or failed.</p>"
   else "<ul>"
     + (($unhealthy | map(. as $t |
         (@html "<li><b>\($t.current_state.state // "blocked")</b> \($t.id)<br><span class=\"mono\">\(dash($t.paths.status_log.last_event.raw))</span></li>")) | add) // "")
     + (($blocked_items | map(. as $r |
         (@html "<li><span class=\"warnid\">waiting on \(($r.unresolved_blocker_ids // []) | join(", "))</span><br>\(dash($r.title // $r.raw))</li>")) | add) // "")
     + "</ul>" end)
+ "    </div>
  </section>

  <section>
    <h2>&#9889; Allowance<i class=\"rule\"></i></h2>
    <div class=\"panel\">" + quota_block + "</div>
  </section>

  <section>
    <h2>&#129504; Second mates<i class=\"rule\"></i></h2>" + secondmate_block + "
  </section>
</div>
</div>

" + (@html "<footer class=\"foot\">home \(.fm_home) &middot; snapshot \(.schema) &middot; rendered \(.generated) &middot; self-reload \($refresh)s &middot; phase 1 read-only board</footer>")
+ "
</div>

<script>
(function () {
  var rendered = " + (.generated | @json | gsub("<"; "\\u003c")) + ";
  var stamp = Date.parse(rendered);
  var age = document.getElementById(\"age\");
  var top = document.getElementById(\"top\");
  function tick() {
    if (isNaN(stamp)) { return; }
    var s = Math.max(0, Math.round((Date.now() - stamp) / 1000));
    var text = s < 60 ? s + \"s ago\"
      : s < 3600 ? Math.floor(s / 60) + \"m ago\"
      : Math.floor(s / 3600) + \"h \" + Math.floor((s % 3600) / 60) + \"m ago\";
    age.textContent = \"live \" + String.fromCharCode(183) + \" refreshed \" + text;
    top.className = s > " + (($refresh * 4) | tostring) + " ? \"top stale\" : \"top\";
  }
  tick();
  setInterval(tick, 1000);
}());
</script>
</body></html>
"
'
) || die "rendering failed"

if [ "$TO_STDOUT" = 1 ]; then
  printf '%s\n' "$HTML"
  exit 0
fi

if [ -z "$OUT" ]; then
  [ -n "$STATE_DIR" ] || die "snapshot reported no state directory; pass --out"
  OUT="$STATE_DIR/mission-control.html"
fi

OUT_DIR=$(dirname "$OUT")
mkdir -p "$OUT_DIR" || die "could not create $OUT_DIR"
TMP="$OUT_DIR/.$(basename "$OUT").$$.tmp"
printf '%s\n' "$HTML" > "$TMP" || { rm -f "$TMP"; die "could not write $TMP"; }
mv -f "$TMP" "$OUT" || { rm -f "$TMP"; die "could not move board into $OUT"; }
printf '%s\n' "$OUT"
