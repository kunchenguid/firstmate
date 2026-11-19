# bin/fm-crew-panel.jq - the renderer behind bin/fm-crew-panel.sh.
#
# Input: {snap, extra}. snap is one fm-fleet-snapshot.sh --json document.
# extra maps a task id to the per-task records the script gathered:
#   events   [{state, at, text, key}] parsed status lines, oldest first
#   steers   [{at, text}] task inbox messages, oldest first
#   review   the raw `no-mistakes axi status` text of the task's run, or null
#   model    the model named in the task's meta record, or null
#   verify_report  true when data/<id>-verify/report.md exists
# Arguments: $W (panel width in columns), $now (epoch), $name (crew name),
# $color ("1" for ANSI color), $task (task id, or "" for the fleet panel),
# $human (the gate component that means a human decision).
#
# Output: the panel lines. No line is wider than $W columns, and the script
# never relies on the terminal to wrap a line.

def rep($s; $k): if $k <= 0 then "" else ([range(0; $k)] | map($s) | join("")) end;
def fit($t; $n): ($t // "") as $s | if $n <= 0 then "" elif ($s | length) > $n then $s[0:$n - 1] + "…" else $s end;
def maxv($a; $b): if $a > $b then $a else $b end;
def minv($a; $b): if $a < $b then $a else $b end;
def age($s):
  if $s == null then "?"
  else ($s | floor | maxv(.; 0)) as $x
  | if $x < 60 then "\($x)s"
    elif $x < 3600 then "\($x / 60 | floor)m"
    elif $x < 86400 then ($x / 3600 | floor) as $h | ($x % 3600 / 60 | floor) as $m
      | if $m == 0 then "\($h)h" else "\($h)h \($m)m" end
    else "\($x / 86400 | floor)d" end
  end;
def since($at): if $at == null then null else $now - $at end;
def clock($at): if $at == null then "--:--" else ($at | localtime | strftime("%H:%M")) end;
def today: $now | localtime | strftime("%Y-%m-%d");

# --- line model ---------------------------------------------------------------
# A line is an array of [class, text] segments. Classes: s gray, g green,
# y yellow, b blue, c cyan, v magenta, r red, d dim, w and k bold; a class may
# hold several space-separated names.
def code($cls):
  ($cls | split(" ") | map(select(. != "")) | map(
    {"s":"90","g":"32","y":"33","b":"34","c":"36","v":"35","r":"31","d":"2","w":"1","k":"1"}[.] // empty
  ) | unique) as $codes
  | if ($codes | length) == 0 then "" else "\u001b[" + ($codes | join(";")) + "m" end;
def paint: map(
    if $color == "1" and (code(.[0]) != "") then code(.[0]) + .[1] + "\u001b[0m" else .[1] end
  ) | join("");

# One line of width $w: left text, and right text pushed to the last column.
# The right text is cut first when both cannot fit; the left text keeps at
# least a few columns.
def lr($w; $l; $lc; $r; $rc):
  ($l // "") as $l0 | ($r // "") as $r0
  | ($w - 1 - minv(($l0 | length); 10)) as $rmax
  | (if ($r0 | length) <= $rmax then $r0 elif $rmax >= 4 then fit($r0; $rmax) else "" end) as $r1
  | (if $r1 == "" then $w else $w - ($r1 | length) - 1 end) as $room
  | fit($l0; $room) as $l1
  | if $r1 == "" then [[$lc, $l1]]
    else [[$lc, $l1], ["", rep(" "; $w - ($l1 | length) - ($r1 | length))], [$rc, $r1]] end;

# --- task facts ---------------------------------------------------------------
def tasks: [.snap.tasks[]? | select(.kind != "secondmate")];
def spawn_at($t): ([($t.spawn_gen // "") | scan("^s([0-9]+)")[0]] | first) as $e | if $e then ($e | tonumber) else null end;
def evs($x): ($x.events // []);
def last_of($x; $states): [evs($x)[] | select(.state as $s | $states | index($s))] | last;
def project($t): ($t.backlog.repo // (($t.project // "") | split("/") | last) // "");
def subtitle($t): [project($t), ($t.backlog.title // empty)] | map(select(. != null and . != "")) | join(" · ");
def detail($t): ($t.current_state.detail // "");
def needs($t): ($t.hints.pending_decision == true) or (detail($t) | split(" · ") | any(. == $human));
def done($t): $t.current_state.state == "done";
def pr_num($t): ([($t.pr.url // "") | scan("/pull/([0-9]+)")[0]] | first);
def pr_label($t): if pr_num($t) then "PR #\(pr_num($t))" else "PR" end;
def risk($t):
  ([($t.backlog.body_lines // [])[] | select(test("^verifier: ")) | sub("^verifier: "; "") | sub(" *\\(.*$"; "")] | last) as $r
  | if $r == null or $r == "" or $r == "none" then null else $r end;
def updated_age($t):
  [ $t.paths.status_log.last_event.age_seconds, $t.step.current.age_seconds ] | map(select(. != null)) | min;
def question($t; $x):
  (($t.hints.open_decisions // []) | map(.summary // empty) | last) as $s
  | if $s != null and $s != "" then $s else (last_of($x; ["needs-decision"]).text // "a decision") end;

# --- no-mistakes run (raw `axi status` text) ----------------------------------
def unq: if startswith("\"") then (try fromjson catch .[1:-1]) else . end;
def toon_scalar($raw; $key):
  ([($raw // "") | split("\n")[] | select(test("^\\s*" + $key + ": ")) | sub("^\\s*" + $key + ": "; "")] | first) as $v
  | if $v == null then null else ($v | unq) end;
def toon_table($raw; $name):
  (($raw // "") | split("\n")) as $L
  | ([range(0; $L | length) | select($L[.] | test("^\\s*" + $name + "\\[[0-9]+\\]\\{[^}]*\\}:\\s*$"))] | first) as $i
  | if $i == null then []
    else ($L[$i] | capture("\\{(?<f>[^}]*)\\}").f | split(",")) as $fields
    | ($L[$i] | capture("^(?<i>\\s*)").i | length) as $ind
    | ([range($i + 1; $L | length) | select(($L[.] | test("^\\s{" + (($ind + 1) | tostring) + ",}\\S")) | not)] | first // ($L | length)) as $end
    | [ $L[$i + 1:$end][]
        | sub("^\\s+"; "")
        | [ scan("(\"(?:[^\"\\\\]|\\\\.)*\"|[^,]*)(?:,|$)") | .[0] ] as $vals
        | [range(0; $fields | length) | {key: $fields[.], value: (($vals[.] // "") | unq)}] | from_entries ]
    end;
def step_label($s): {"intent":"intent","rebase":"rebase","review":"review","test":"tests","document":"docs","lint":"lint","push":"push","pr":"PR","ci":"CI"}[$s] // $s;
def step_verb($s; $status):
  if $status == "fixing" then "Review: fix the findings"
  elif $status == "awaiting_approval" or $status == "fix_review" then "Review: findings wait for an answer"
  else {"intent":"Review: read the intent","rebase":"Review: rebase the branch","review":"Review: review the code",
        "test":"Review: run the tests","document":"Review: check the docs","lint":"Review: run the linters",
        "push":"Review: push the branch","pr":"Review: open the PR","ci":"Review: wait for CI"}[$s] // ("Review: " + $s) end;
def short_dur($d): if ($d // "") == "" then null else ($d | (capture("^(?<v>[0-9]+[a-z]+)").v // .)) end;
def review($t; $x):
  ($x.review // null) as $raw
  | if $raw == null or $raw == "" then null
    elif (toon_scalar($raw; "branch") // "") != ($t.branch // "") then null
    else toon_table($raw; "steps") as $steps
    | if ($steps | length) == 0 then null
      else toon_table($raw; "active_steps") as $active
      | ($steps | map(select(.status == "completed" or .status == "skipped")) | length) as $ndone
      | ([$steps[] | select(.status | IN("running","fixing","awaiting_approval","fix_review","ci"))] | first) as $cur
      | { steps: $steps, total: ($steps | length), ndone: $ndone,
          n: ($ndone + (if $cur then 1 else 0 end)), cur: $cur,
          cur_for: (if $cur then short_dur(([$active[] | select(.step == $cur.step)] | first).active_for) else null end),
          findings: ([$steps[] | (.findings // "0") | tonumber? // 0] | add // 0),
          status: toon_scalar($raw; "status") }
      end
    end;

# --- the verifier for a ship ---------------------------------------------------
def vtask($root; $t): [$root.snap.tasks[]? | select(.id == $t.id + "-verify")] | first;
def vstate($v): if $v == null then null else $v.current_state.state end;
def vlive($v): $v != null and ((vstate($v) | IN("done","failed")) | not);
def scenarios($t): ($t.step.scenarios // []);
def vresult($t; $x; $v):
  if $v != null then
    (scenarios($v)) as $sc
    | if vlive($v) then "running"
      elif vstate($v) == "failed" or ($sc | any(.result == "fail")) then "failed"
      elif ($sc | length) > 0 and ($sc | all(.result == "pass")) then "passed"
      else "done" end
  elif $x.verify_report == true then "report"
  else null end;

# --- phase ---------------------------------------------------------------------
def noreply($t): ($t.endpoint.exists == false) and ((done($t)) | not);
# A scout's report is the latest word until newer work starts: a non-done status
# line after the last done line, a plan recorded after it, or a live busy state.
def newer_work($t; $x):
  (last_of($x; ["done"]).at) as $d
  | ($t.current_state.state == "working")
    or ($d != null and ((evs($x) | any(.state != "done" and .at != null and .at > $d))
                        or (($t.step.plan_recorded_at // 0) > $d)));
def phase($t; $x; $v):
  if needs($t) then "needs"
  elif $t.current_state.state == "failed" then "failed"
  elif $t.current_state.state == "blocked" then "blocked"
  elif $t.kind == "ship" and vlive($v) and (noreply($t) | not) then "verifying"
  elif $t.kind == "ship" and done($t) then "ready"
  elif $t.kind == "scout" and (done($t) or ($t.paths.report.present == true and (newer_work($t; $x) | not))) then "report"
  elif noreply($t) then "noreply"
  elif $t.current_state.source == "run-step" then "checking"
  elif $t.step != null or (evs($x) | length) > 0 then "working"
  else "starting" end;
def group($p): {"needs":0,"failed":1,"blocked":1,"noreply":1,"ready":2,"report":2,"verifying":3,"checking":3,"working":4,"starting":5}[$p];
def pcolor($p): {"needs":"y","failed":"r","blocked":"r","noreply":"r","ready":"v","report":"v","verifying":"c","checking":"b","working":"g","starting":"s"}[$p];
def plabel($p; $t):
  {"needs":"◆ NEEDS YOU","failed":"✕ FAILED","blocked":"✕ BLOCKED","noreply":"✕ NO REPLY",
   "ready":(if $t.pr.url then "✓ PR READY" else "✓ READY" end),"report":"◇ REPORT READY",
   "verifying":"◈ VERIFYING","checking":"◐ CHECKING","working":"● WORKING","starting":"○ STARTING"}[$p];
# A verifier scout shows inside its ship's card unless it needs attention itself.
def folded($t; $root):
  ($t.kind == "scout") and ($t.id | endswith("-verify"))
  and ([$root.snap.tasks[]? | select(.id == ($t.id | sub("-verify$"; "")) and .kind == "ship")] | length) > 0
  and ((phase($t; ($root.extra[$t.id] // {}); null)) | IN("needs","failed","blocked","noreply") | not);

# --- the fleet card -----------------------------------------------------------
def cw: $W - 1;
def cl($bar; $l; $lc; $r; $rc): [[$bar + " k", "▌"]] + lr(cw; $l; $lc; $r; $rc);
def cbar($bar; $n; $m):
  "\($n)/\($m)" as $nm
  | (minv(($W * 28 / 44 | floor); cw - ($nm | length) - 1)) as $cells
  | if $cells < 4 or $m < 1 then cl($bar; $nm; "w"; ""; "")
    else (minv($cells; ($cells * $n / $m + 0.5 | floor))) as $f
    | [[$bar + " k", "▌"], [$bar, rep("█"; $f)], ["d", rep("░"; $cells - $f)],
       ["", rep(" "; cw - $cells - ($nm | length))], ["w", $nm]] end;
def wrap($s; $n):
  reduce (($s // "") | split(" ") | map(select(. != ""))[]) as $wd ([""];
    if (.[-1] | length) == 0 then .[-1] = fit($wd; $n)
    elif ((.[-1] | length) + 1 + ($wd | length)) <= $n then .[-1] += " " + $wd
    else . + [fit($wd; $n)] end);
def card($root; $t):
  ($root.extra[$t.id] // {}) as $x
  | vtask($root; $t) as $v0
  | (if $v0 != null and folded($v0; $root) then $v0 else null end) as $v
  | phase($t; $x; $v) as $p | pcolor($p) as $c
  | ([cl($c; $t.id; "w"; plabel($p; $t); $c + " k"), cl($c; subtitle($t); "d"; ""; "")]
     + (if $p == "starting" then
          [cl($c; "reading the instructions"; "d"; ""; ""), cl($c; "started " + age(since(spawn_at($t))) + " ago"; "d"; ""; "")]
        elif $p == "working" then
          (if $t.step.current then
             [cbar($c; $t.step.current.n; $t.step.current.m),
              (if $t.current_state.state == "paused" then cl($c; "paused: " + ($t.paths.status_log.last_event.note // ""); "y"; ""; "")
               else cl($c; $t.step.current.name; ""; ""; "") end),
              cl($c; "on step " + age($t.step.current.age_seconds); "d"; "updated " + age(updated_age($t)) + " ago"; "d")]
           elif ($t.step.plan // null) != null then
             [cbar($c; 0; ($t.step.plan | length)),
              cl($c; "next: " + $t.step.plan[0].name; ""; ""; ""),
              cl($c; "started " + age(since(spawn_at($t))) + " ago"; "d"; "updated " + age(updated_age($t)) + " ago"; "d")]
           else
             [cl($c; "no step reported yet"; "d"; ""; ""),
              cl($c; "started " + age(since(spawn_at($t))) + " ago"; "d"; "updated " + age(updated_age($t)) + " ago"; "d")]
           end)
        elif $p == "needs" then
          (wrap("? " + question($t; $x); cw)) as $q
          | [cl($c; $q[0]; "y"; ""; "")]
            + (if ($q | length) > 1 then [cl($c; "  " + ([$q[1:][]] | join(" ")); "y"; ""; "")] else [] end)
            + [cl($c; "waiting " + age(since(last_of($x; ["needs-decision"]).at)); "d"; "answer in chat"; "d")]
        elif $p == "checking" then
          review($t; $x) as $r
          | if $r != null then
              [cbar($c; $r.n; $r.total),
               cl($c; (if $r.cur then step_verb($r.cur.step; $r.cur.status) else "Review: next step" end); ""; ""; ""),
               cl($c; "on step " + ($r.cur_for // "?"); "d"; "updated " + age(updated_age($t)) + " ago"; "d")]
            else
              [cl($c; "Review: " + (detail($t) | split(" · ")[0]); ""; ""; ""),
               cl($c; "updated " + age(updated_age($t)) + " ago"; "d"; ""; "")]
            end
        elif $p == "verifying" then
          (if $v.step.current then [cbar($c; $v.step.current.n; $v.step.current.m)]
           elif ($v.step.plan // null) != null then [cbar($c; 0; ($v.step.plan | length))]
           else [] end)
          + [cl($c; "Verifier: " + ($v.step.current.name // "starting"); ""; ""; ""),
             cl($c; pr_label($t) + " green"; "d"; (if risk($t) then "risk: " + risk($t) else "" end); "d")]
        elif $p == "ready" then
          vresult($t; $x; $v0) as $vr
          | [cl($c; (if $t.pr.url then pr_label($t) + " · checks green" else "branch ready to land" end); ""; ""; ""),
             cl($c; "ready " + age(since(last_of($x; ["done"]).at) // $t.paths.status_log.last_event.age_seconds); "d";
                (if $vr == "failed" then "verifier failed" else "waits for your merge" end);
                (if $vr == "failed" then "r" else "d" end))]
        elif $p == "report" then
          (($t.hints.open_decisions // []) | length) as $k
          | [cl($c; "report saved" + (if $k > 0 then " · \($k) call" + (if $k > 1 then "s" else "" end) + " for you" else "" end); ""; ""; ""),
             cl($c; "ready " + age(since(last_of($x; ["done"]).at) // $t.paths.status_log.last_event.age_seconds); "d"; "read it in chat"; "d")]
        elif $p == "noreply" then
          [cl($c; "no change for " + age(updated_age($t) // since(spawn_at($t))); "r"; ""; ""),
           cl($c; (if $t.step.current then "last step \($t.step.current.n)/\($t.step.current.m) \($t.step.current.name)" else "no step reported" end); "d"; ""; "")]
        else
          [cl($c; ($t.paths.status_log.last_event.note // $p); "r"; ""; ""),
           cl($c; $p + " " + age($t.paths.status_log.last_event.age_seconds) + " ago"; "d"; "first mate checks it"; "d")]
        end)) as $lines
  | {group: group($p), at: (spawn_at($t) // 0), id: $t.id, phase: $p, lines: $lines};

def fleet:
  . as $root
  | [tasks[] | select(folded(.; $root) | not) | card($root; .)] | sort_by(.group, .at, .id) as $cards
  | ($root.snap.backlog.records // []) as $recs
  | ([$recs[] | select(.state == "queued")] | length) as $queued
  | (([$recs[] | select(.captain_actionable == true)] | length) + ([$cards[] | select(.phase == "needs")] | length)) as $calls
  | ([$recs[] | select(.state == "done" and .completion.date == today)] | length) as $today
  | ("\($cards | length) live · " + clock($now)) as $hr
  | [ (if $W < 10 then [["c k", fit("crew"; $W)]] else [["c k", "crew"], ["", " "]] + lr($W - 5; $name; ""; $hr; "d") end),
      [["d", rep("─"; $W)]] ]
    + (if ($cards | length) == 0 then [[["d", fit("no workers under way"; $W)]]]
       else [$cards | to_entries[] | (if .key > 0 then [[]] else [] end) + .value.lines | .[]] end)
    + [ [["d", rep("─"; $W)]],
        [["d", fit("queued \($queued) · your calls \($calls)" + (if $today > 0 then " · done today \($today)" else "" end); $W)]] ];

# --- the worker panel ---------------------------------------------------------
def rw: $W - 2;
def row($l; $lc; $r; $rc): lr(rw; $l; $lc; $r; $rc);
def sec($t; $r; $rc): row($t; "d w"; $r; $rc);
def hr: [["d", rep("─"; rw)]];
# Durations of each plan step from the step record: a step ends where the
# next recorded step starts; the current step runs until now.
def step_times($t; $past):
  ($t.step.history // []) as $h
  | reduce range(0; $h | length) as $i ({};
      ($h[$i]) as $e
      | (if $i + 1 < ($h | length) then $h[$i + 1].started_at
         elif $past then null
         else $now end) as $end
      | .["\($e.n)"] = (if $end == null then null else age($end - $e.started_at) end));
def plan_names($t):
  if ($t.step.plan // null) != null then $t.step.plan
  elif $t.step.current then
    ($t.step.history // []) as $h
    | [range(1; $t.step.current.m + 1) as $k
       | {n: $k, name: (([$h[] | select(.n == $k) | .name] | last) // "step \($k)")}]
  else null end;
def plan_rows($t; $past; $c):
  plan_names($t) as $plan
  | if $plan == null then []
    else ($t.step.current.n // 0) as $cur | step_times($t; $past) as $tm
    | [ $plan[] | .n as $k
        | if $past or $k < $cur then row(" ✓ \($k) \(.name)"; "g"; $tm["\($k)"] // ""; "d")
          elif $k == $cur then row(" ▶ \($k) \(.name)"; $c + " k"; $tm["\($k)"] // ""; "d")
          else row(" · \($k) \(.name)"; "d"; ""; "") end ]
    end;
def plan_sec($t; $past; $c; $compress):
  plan_names($t) as $plan
  | if $plan == null then []
    else ($plan | length) as $m
    | if $past then [sec("PLAN"; "\($m)/\($m) done"; "g")]
        + (if $compress then
             ([($t.step.history // [])[] | .started_at] | min) as $first
             | [row(" ✓ all \($m) steps" + (if $first then " · " + age(([$t.step.history[-1].started_at, $now] | max) - $first) else "" end); "g"; ""; "")]
           else plan_rows($t; true; $c) end)
      else [sec("PLAN"; "\($t.step.current.n // 0)/\($m)"; "w")] + plan_rows($t; false; $c) end
    end;
def packed($items; $cls):
  # Pack short items onto as few rows as the width allows.
  (reduce $items[] as $it ([""];
     if (.[-1] | length) == 0 then .[-1] = " " + $it
     elif ((.[-1] | length) + 2 + ($it | length)) <= rw then .[-1] += "  " + $it
     else . + [" " + $it] end)) as $rows
  | [$rows[] | select(. != "") | row(.; $cls; ""; "")];
def review_sec($t; $r; $c; $compress):
  if $r == null then []
  elif $r.ndone == $r.total then
    [sec("REVIEW"; "\($r.total)/\($r.total) done"; "g")]
    + (if $compress and $t.pr.url then [row(" ✓ " + pr_label($t) + " open · checks green"; "g"; ""; "")]
       else [row(" ✓ all \($r.total) steps passed"; "g"; ""; "")]
         + (if $r.findings > 0 then [row(" \($r.findings) finding" + (if $r.findings > 1 then "s" else "" end) + " in the run"; "d"; ""; "")] else [] end)
       end)
  else
    [sec("REVIEW"; "\($r.n)/\($r.total)"; "w")]
    + packed([$r.steps[] | select(.status == "completed" or .status == "skipped") | "✓ " + step_label(.step)]; "g")
    + (if $r.cur then [row(" ▶ " + step_label($r.cur.step) + (if $r.cur.status == "fixing" then " (fixing)" else "" end); $c + " k"; $r.cur_for // ""; "d")] else [] end)
    + packed([$r.steps[] | select(.status | IN("completed","skipped","running","fixing","awaiting_approval","fix_review","ci") | not) | "· " + step_label(.step)]; "d")
  end;
def scen_sec($sc; $c):
  if ($sc | length) == 0 then []
  else ([$sc[] | select(.result == "pass")] | length) as $np
  | ([$sc[] | select(.result == "fail")] | length) as $nf
  | [sec("SCENARIOS"; "\($np) pass · \($nf) fail"; (if $nf > 0 then "r" else "g" end))]
    + [$sc[] | if .result == "pass" then row(" ✓ " + .name; "g"; ""; "")
               elif .result == "fail" then row(" ✕ " + .name; "r"; ""; "")
               else row(" ▶ " + .name; $c; ""; "") end]
  end;
def url_rows($u):
  if ($u | length) <= rw - 1 then [row(" " + $u; "c"; ""; "")]
  else ($u | sub("^https?://"; "")) as $s
  | if ($s | length) <= rw - 1 then [row(" " + $s; "c"; ""; "")]
    else [range(0; ($s | length); rw - 1) as $i | row(" " + $s[$i:$i + rw - 1]; "c"; ""; "")] end
  end;
def events_rows($t; $x):
  (evs($x)) as $e
  | ([ (if spawn_at($t) then {at: spawn_at($t), text: "started", cls: "d"} else empty end) ]
     + [ $e[] | select(.at != null)
         | {at, cls: ({"needs-decision":"y","failed":"r","blocked":"r","paused":"y","done":"g"}[.state] // "d"),
            text: (if .state == "needs-decision" then "asked a question"
                   elif .state == "resolved" then "got the answer"
                   elif .state == "working" then .text
                   else .state + ": " + .text end)} ]
     + [ # A steer after an open question is the answer to it.
         ($e | map(select(.state == "needs-decision" and .at != null))) as $qs
         | $qs[] | .at as $qa
         | select(([$e[] | select(.state == "resolved" and (.at // 0) >= $qa)] | length) == 0)
         | ([($x.steers // [])[] | select(.at != null and .at >= $qa)] | first) as $s
         | select($s != null) | {at: $s.at, text: "got the answer", cls: "d"} ]
    ) | sort_by(.at) | .[-5:]
  | map(row(" " + clock(.at) + " " + .text; .cls; ""; ""));
def worker($root; $t):
  ($root.extra[$t.id] // {}) as $x
  | vtask($root; $t) as $v0
  | (if $v0 != null and folded($v0; $root) then $v0 else null end) as $v
  | phase($t; $x; $v) as $p | pcolor($p) as $c
  | ($p | IN("checking","verifying","ready","report")) as $past
  | review($t; $x) as $r
  | vresult($t; $x; $v0) as $vr
  | ([row($t.id; "w"; plabel($p; $t); $c + " k"), row(subtitle($t); "d"; ""; "")]) as $head
  | (if $p == "needs" then
       [sec("QUESTION FOR YOU"; "waiting " + age(since(last_of($x; ["needs-decision"]).at)); "y")]
       + (wrap(question($t; $x); rw - 1)[0:6] | map(row(" " + .; "y"; ""; "")))
       + [row(" Answer in the fleet tab."; "d"; ""; "")]
     else [] end) as $question
  | plan_sec($t; $past; $c; $p == "verifying") as $plan
  | ([($x.steers // [])[-3:][] | row(" " + clock(.at) + " " + ((.text // "") | split("\n") | map(select(. != "")) | join(" ")); ""; ""; "")]
     | if length > 0 then [sec("FROM FIRST MATE"; ""; "")] + . else [] end) as $steers
  | (events_rows($t; $x) | if length > 0 then [sec("EVENTS"; ""; "")] + . else [] end) as $events
  | review_sec($t; $r; $c; $p == "verifying") as $review
  | (if $v != null then
       [sec("VERIFIER · pstack"; (if $v.step.current then "\($v.step.current.n)/\($v.step.current.m)" elif $v.step.plan then "0/\($v.step.plan | length)" else "" end); "w"),
        row(" " + ([(if risk($t) then "risk: " + risk($t) else empty end), (($root.extra[$v.id] // {}).model // $v.harness // empty)] | join(" · ")); "d"; ""; "")]
       + plan_rows($v; (vlive($v) | not); "c")
     else [] end) as $verifier
  | scen_sec((if $v != null then scenarios($v) else scenarios($t) end); "c") as $scen
  | (if $t.pr.url then
       [sec("PR"; ""; "")] + url_rows($t.pr.url)
       + (if $p == "ready" or (detail($t) | startswith("checks green")) then [row(" checks   green"; "g"; ""; "")]
          elif detail($t) == "ci running" then [row(" checks   running"; "b"; ""; "")]
          elif $t.current_state.state == "failed" then [row(" checks   failed"; "r"; ""; "")]
          else [] end)
       + (if $vr == "passed" then [row(" verifier passed · report saved"; "g"; ""; "")]
          elif $vr == "failed" then [row(" verifier failed · read the report"; "r"; ""; "")]
          elif $vr == "running" then [row(" verifier running"; "c"; ""; "")]
          elif $vr == "done" or $vr == "report" then [row(" verifier report saved"; "d"; ""; "")]
          else [] end)
       + (if $p == "ready" then [row(" waits for your merge in the fleet tab"; "d"; ""; "")] else [] end)
     else [] end) as $prsec
  | (spawn_at($t)) as $sa
  | ( if $p == "verifying" then
        [row(" merge ask waits for the verifier"; "d"; ""; ""), row(" verifier tab: " + $v.id; "d"; ""; "")]
      elif $p == "ready" then
        [row(" ready " + age(since(last_of($x; ["done"]).at) // $t.paths.status_log.last_event.age_seconds)
             + (if $sa then " · running " + age($now - $sa) else "" end); "d"; ""; "")]
      else
        (if $t.kind == "ship" and $t.branch then [row(" branch  " + $t.branch; "d"; ""; "")] else [] end)
        + (if $t.kind == "ship" then
             [row(" PR      " + (if $t.pr.url then pr_label($t) elif $p == "checking" then "opens after the review" else "none yet" end); "d"; ""; "")]
           else [] end)
        + (if $t.kind == "scout" then [row(" report  " + (if $t.paths.report.present then "saved · read it in chat" else "not written yet" end); "d"; ""; "")] else [] end)
        + (if $p == "working" and $t.mode == "no-mistakes" and plan_names($t) then
             [row(" review  automatic, after step \(plan_names($t) | length)"; "d"; ""; "")] else [] end)
        + (if $sa and ($p | IN("working","needs","starting","checking")) then
             [row(" started " + clock($sa) + " · running " + age($now - $sa); "d"; ""; "")] else [] end)
        + (if $p | IN("noreply","failed","blocked") then
             [row(" last change " + age(updated_age($t) // since($sa)) + " ago"; "d"; ""; "")] else [] end)
      end
      | if length > 0 then [sec("WORK"; ""; "")] + . else [] end ) as $work
  | ( if $p == "ready" then [$prsec, $plan, $steers, $events, $review, $verifier, $scen, $work]
      elif $p == "verifying" then [$question, ($plan + $review), $steers, $events, $verifier, $scen, $prsec, $work]
      else [$question, $plan, $steers, $events, $review, $verifier, $scen, $prsec, $work] end ) as $secs
  | [$head[], ($secs[] | select(length > 0) | (hr, .[]))]
  | map([[$c + " k", "▌"], ["", " "]] + .);

# A new plan replaces the old one: the earlier plan's step starts are not part
# of it, and a step start that predates the new plan is not its current step.
def own_plan_step:
  if . == null or .plan_recorded_at == null then .
  else .plan_recorded_at as $pa
  | .history |= map(select(.started_at >= $pa))
  | if .current != null and .current.started_at < $pa then .current = null else . end end;
def render:
  .snap.tasks |= (if . == null then . else map(if .step != null then .step |= own_plan_step else . end) end)
  | if $task == "" then fleet
  else . as $root
  | ([$root.snap.tasks[]? | select(.id == $task)] | first) as $t
  | if $t == null then [[["d", fit("No worker \($task) in this home."; $W)]], [["d", fit("Its tab closes with it."; $W)]]]
    else worker($root; $t) end
  end;

render[] | paint
