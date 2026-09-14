def bar($value; $max):
  if ($max // 0) <= 0 then "              "
  elif ($value | type) != "number" then "              "
  else
    (($value // 0) as $v | ($max // 1) as $m |
     (((14 * $v) + ($m / 2)) / $m | floor | if . > 14 then 14 elif . < 0 then 0 else . end) as $filled |
     ("█" * $filled) + ("░" * (14 - $filled)))
  end;

# Public-safe boundary for every free-text field: control characters stripped,
# token-shaped secrets redacted, Slack mrkdwn escaped (mentions cannot render),
# backticks removed (no fence breakout), whitespace collapsed, capped.
def sanitize_text($text):
  ($text // "")
  | gsub("[[:cntrl:]]"; "")
  | gsub("(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9_]{20,}"; "<redacted>")
  | gsub("github_pat_[A-Za-z0-9_]{20,}"; "<redacted>")
  | gsub("glpat-[A-Za-z0-9_-]{20,}"; "<redacted>")
  | gsub("sk-[A-Za-z0-9_-]{20,}"; "<redacted>")
  | gsub("xox[bap]-[A-Za-z0-9-]{10,}"; "<redacted>")
  | gsub("AKIA[0-9A-Z]{16}"; "<redacted>")
  | gsub("AIza[0-9A-Za-z_-]{35}"; "<redacted>")
  | gsub("eyJ[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}"; "<redacted>")
  | gsub("npm_[A-Za-z0-9]{36}"; "<redacted>")
  | gsub("-----BEGIN [A-Z ]*PRIVATE KEY-----[^-]*-----END [A-Z ]*PRIVATE KEY-----"; "<redacted>")
  | gsub("[A-Za-z0-9_+/-]{32,}={0,2}"; "<redacted>")
  | gsub("&"; "&amp;")
  | gsub("<"; "&lt;")
  | gsub(">"; "&gt;")
  | gsub("`"; "")
  | gsub("\\s+"; " ")
  | gsub("^ | $"; "")
  | .[0:160];

def typed_null: if . == "-" or . == "none" or . == "" then null else . end;

# tasks-axi rows arrive decoded from the tool's TOON table by the shell
# boundary; validate types here and refuse the whole report on any malformed
# row rather than guessing.
def backlog_row($r):
  if ($r | type) != "object"
     or ((($r.id // "") | type) != "string")
     or (($r.id | test("^[A-Za-z0-9][A-Za-z0-9._-]*$")) | not)
     or ((($r.state // "") | type) != "string")
     or ((($r.kind // "") | type) != "string")
     or ((($r.title // "") | type) != "string")
  then error("malformed backlog row")
  else {
    id: ($r.id | sanitize_text(.)),
    state: $r.state,
    kind: $r.kind,
    repo: (($r.repo // "-") | typed_null),
    title: $r.title,
    blocked_by: (($r.blocked_by // "none") | typed_null),
    hold_kind: (($r.hold_kind // "-") | typed_null),
    hold_reason: (($r.hold_reason // "-") | typed_null),
    hold_until: (($r.hold_until // "-") | typed_null)
  } end;

# Split a status cell into segments on ` / ` or `; ` separators that sit
# OUTSIDE parentheses (real ledger rows carry notes such as
# "fixed (PR 359, 18:51; b56 retired)").
def split_status_segments($cell):
  reduce ($cell | explode[]) as $ch (
    {parts: [], current: "", depth: 0};
    if $ch == 40 then .depth += 1 | .current += "("
    elif $ch == 41 then .depth -= 1 | .current += ")"
    elif (.depth == 0) and (($ch == 47) or ($ch == 59)) then
      .parts += [.current] | .current = ""
    else .current += ($ch | [.] | implode) end
  ) | .parts + [.current];

# One segment: an exact status token with an optional `for`/`by` qualifier and
# an optional parenthesized note. Prefix claims such as
# "fixed totally-unverified" do not match.
def status_segment_token($seg):
  ($seg | gsub("^\\s+|\\s+$"; "")) as $s |
  if ($s | test("^(open|researching|fixed|verified|regressed|hotfixed)( (for|by) [^();]+)?( \\([^()]*\\))?$"))
  then ($s | split(" ") | .[0])
  else "invalid" end;

def quarantine_status($raw):
  (split_status_segments($raw) | map(status_segment_token(.))) as $tokens |
  if ($tokens | index("invalid")) != null or ($tokens | length) == 0 then "invalid"
  elif ($tokens | index("researching")) != null then "researching"
  elif ($tokens | index("open")) != null or ($tokens | index("regressed")) != null then "open"
  else "fixed" end;

# Strict ledger parse over one exact schema: the five-column header is
# required, evidence carries a leading count, statuses follow the segment
# grammar above, owner and window are required prose, and conflicting
# duplicates invalidate the ledger.
def parse_quarantine($text):
  ($text | split("\n")) as $lines |
  reduce $lines[] as $line (
    {classes: [], in_reinforced: false, invalid: false, header_seen: false, in_table: false};
    if .invalid then .
    elif ($line | test("^# Reinforced")) then .in_reinforced = true
    elif .in_reinforced then .
    elif ($line | test("^\\|") | not) then .in_table = false
    else
      ($line | split("|") | map(gsub("^\\s+|\\s+$"; ""))) as $cells |
      if ($cells | length) != 7 or ($cells[0] | length) != 0 or ($cells[6] | length) != 0 then
        .invalid = true
      elif $cells[1] == "Class" then
        if (($cells[2] == "Occurrences (evidence)") and ($cells[3] == "Status")
            and ($cells[4] == "Owner / plan") and ($cells[5] == "Verification window"))
        then .header_seen = true | .in_table = true
        else .invalid = true
        end
      elif (.in_table | not) then .
      elif ($cells[1] // "" | test("^-+$")) then .
      elif ($cells | length) < 6 or ($cells[1] | length) == 0 then .invalid = true
      else
        (quarantine_status($cells[3])) as $status |
        if $status == "invalid"
           or (($cells[2] | test("^[1-9][0-9]*\\+?( .*)?$")) | not)
           or (($cells[4] | test("^-?$")) or ($cells[4] | length) == 0)
           or (($cells[5] | test("^-?$")) or ($cells[5] | length) == 0)
        then .invalid = true
        else
          .classes += [{
            name: $cells[1],
            status: $status,
            fixed: ($status == "fixed"),
            researching: ($status == "researching"),
            open: ($status == "open")
          }]
        end
      end
    end
  ) as $parsed |
  if ($parsed.header_seen | not) then $parsed + {invalid: true}
  elif $parsed.invalid then $parsed
  else
    ($parsed.classes | group_by(.name)) as $groups |
    if ([$groups[] | select(length > 1) | select((unique | length) > 1)] | length) > 0
    then $parsed + {invalid: true}
    else $parsed + {classes: [$groups[] | .[0]]}
    end
  end;

# A provider percentage is meaningful only for the intended aggregate scope
# with a complete known observation; anything else is unknown.
def quota_pct($provider; $fresh):
  if ($fresh | not) then "unknown"
  else
    (.providers // [] | map(select(.provider == $provider)) | .[0]) as $row |
    if $row == null then "unknown"
    elif $row.quotaSemantics.status != "known" then "unknown"
    else
      ([$row.quotaSemantics.effectiveAvailability[]? | select(.scope == "all_models")]) as $agg |
      if ($agg | length) != 1 then "unknown"
      elif $agg[0].status != "known"
           or ($agg[0].effectivePercentRemaining | type) != "number"
           or $agg[0].effectivePercentRemaining < 0
           or $agg[0].effectivePercentRemaining > 100 then "unknown"
      else $agg[0].effectivePercentRemaining
      end
    end
  end;

# Lifecycle classification over the bytes appended since the consumed
# position: every new row must be safely classifiable or the whole lifecycle
# snapshot renders unknown (no silent drops). Seat operations require the full
# producer identity envelope; only successful operations count.
def life_classify($line; $now_epoch):
  (try ($line | fromjson) catch null) as $r |
  if $r == null then {poison: true}
  elif ($r | type) != "object" then {poison: true}
  elif (($r.ts // null) | type) != "number" then {poison: true}
  elif ($r.ts / 1000 | floor) > ($now_epoch + 60) then {poison: true}
  elif (($r.op // "") | length) == 0 then {poison: true}
  elif ($r.op == "spawn" or $r.op == "teardown") then
    if (($r.taskId // null) | type) != "string" or ($r.taskId | length) == 0
       or (($r.operationId // null) | type) != "string" or ($r.operationId | length) == 0
       or (($r.status // null) | type) != "number" then {poison: true}
    elif $r.status == 0 then {poison: false, count: true, op: $r.op, id: $r.operationId}
    else {poison: false, count: false}
    end
  else {poison: false, count: false}
  end;

def merged_row_ok($r; $now_epoch; $repo):
  ($r | type) == "object"
  and (($r.number // null) | type) == "number"
  and ($r.number | floor) == $r.number
  and $r.number > 0 and $r.number < 100000000
  and (($r.url // null) | type) == "string"
  and ($r.url == "https://github.com/\($repo)/pull/\($r.number)")
  and (($r.mergedAt // null) | type) == "string"
  and (try (($r.mergedAt | fromdateiso8601) <= ($now_epoch + 60)) catch false)
  and ((($r.title // "") | type) == "string");

($now_epoch // 0) as $now_epoch |
($last_epoch // 0) as $last_epoch |
($seen_ids // []) as $seen_ids |
($merged_reported // []) as $merged_reported |
(parse_quarantine($quarantine)) as $q |
$q.classes as $classes |
(if $q.invalid then "unknown" else null end) as $quarantine_invalid |
([$in_flight[0].tasks[]? | backlog_row(.)]) as $in_flight_all |
([$ready[0].ready[]? | backlog_row(.)]) as $ready_all |
([$queued[0].tasks[]? | backlog_row(.)]) as $queued_all |
# The decoded collection must match the requested collection.
(if ([$in_flight_all[] | select(.state != "in_flight")] | length) > 0 then error("in-flight listing carried a foreign state") else 0 end) as $_ |
(if ([$ready_all[] | select(.state != "queued")] | length) > 0 then error("ready listing carried a foreign state") else 0 end) as $_ |
(if ([$queued_all[] | select(.state != "queued")] | length) > 0 then error("queued listing carried a foreign state") else 0 end) as $_ |
# Holds live on typed hold fields of the regular collections; no separate
# held-state collection is trusted to agree with them.
([$in_flight_all + $queued_all | .[] | select(.hold_kind != null)]) as $held_rows |
$in_flight_all as $in_flight_rows |
$ready_all as $ready_rows |
(if $quarantine_invalid == "unknown" then "unknown" else ($classes | map(select(.fixed)) | length | tostring) end) as $fixed_display |
(if $quarantine_invalid == "unknown" then "unknown" else ($classes | map(select(.open or .researching)) | length | tostring) end) as $owned_display |
(if $quarantine_invalid == "unknown" then null
 else {fixed: ($classes | map(select(.fixed)) | length),
       denominator: (($classes | map(select(.fixed)) | length) + ($classes | map(select(.open or .researching)) | length))}
 end) as $landed |
(($quota[0].generatedAt // null) as $gen |
  if $gen == null then false
  else (try (($now_epoch - ($gen | fromdateiso8601)) as $age | ($age >= -60 and $age <= 3600)) catch false)
  end) as $quota_fresh |
($quota[0] | quota_pct("codex"; $quota_fresh)) as $codex_pct |
($quota[0] | quota_pct("cursor"; $quota_fresh)) as $cursor_pct |
($quota[0] | quota_pct("kimi"; $quota_fresh)) as $kimi_pct |
([$lifecycle_delta | split("\n")[] | select(length > 0) | life_classify(.; $now_epoch)]) as $life_rows |
(if ([$life_rows[] | select(.poison)] | length) > 0 then true else false end) as $lifecycle_poisoned |
(if $lifecycle_poisoned then [] else [$life_rows[] | select(.count) | select(.id as $i | ($seen_ids | index($i)) | not)] end) as $life_new |
(if $lifecycle_poisoned then $seen_ids
 else (($seen_ids + [$life_new[] | .id]) | unique | .[-1000:]) end) as $new_seen_ids |
(if $lifecycle_poisoned then "unknown" else ([$life_new[] | select(.op == "spawn")] | length | tostring) end) as $seats_started |
(if $lifecycle_poisoned then "unknown" else ([$life_new[] | select(.op == "teardown")] | length | tostring) end) as $seats_retired |
([$merged_prs[0][]? | select(.mergedAt != null)]) as $merged_candidates |
(if ([$merged_candidates[] | select(merged_row_ok(.; $now_epoch; $repo) | not)] | length) > 0
    or (($merged_candidates | group_by(.number) | map(select((unique | length) > 1)) | length) > 0)
 then true else false end) as $merged_invalid |
(if $merged_invalid then []
 else [$merged_candidates[]
       # Identity-backed overlap: the window reaches before the committed
       # boundary so a merge the previous query missed is retried, and the
       # reported-number set deduplicates what the last post already carried.
       | select((.mergedAt | fromdateiso8601) >= ($last_epoch - 300))
       | {number, url, mergedAt, title: sanitize_text(.title)}]
      | unique_by(.number) | sort_by(.mergedAt) end) as $merged_window |
([$merged_window[] | select(.number as $n | ($merged_reported | index($n)) | not)]) as $merged_since |
# Retain the dedupe union for the full overlap window: prior reported numbers
# stay while their rows remain in the window, this run's render joins them.
(if $merged_invalid then $merged_reported
 else ([$merged_reported[] | select(. as $n | [$merged_window[] | .number] | index($n) != null)]
       + [$merged_since[] | .number] | unique) end) as $new_merged_reported |
(if ([$in_flight_rows[] | select(.blocked_by != null)] | length) > 0 then "blocked" else "unknown" end) as $status_level |
([$held_rows[] | select(.hold_kind == "captain") |
   .id + (if .hold_reason != null then ": " + sanitize_text(.hold_reason) else "" end)
     + (if .hold_until != null then " (until " + (.hold_until | sanitize_text(.)) + ")" else "" end)]) as $waiting |
{
  program: (sanitize_text($program)),
  mention: $mention,
  header_time: ($now_ms / 1000 | strftime("%d %b %H:%M")),
  header_time_iso: ($now_ms / 1000 | strftime("%Y-%m-%dT%H:%M:%SZ")),
  status_level: $status_level,
  waiting: $waiting,
  fixed_display: $fixed_display,
  fixed_denominator: (if $landed == null then "unknown" else ($landed.denominator | tostring) end),
  seats_started: $seats_started,
  seats_retired: $seats_retired,
  lifecycle_poisoned: $lifecycle_poisoned,
  smoke_label: "unknown",
  quiet_label: "unknown",
  codex_pct: $codex_pct,
  cursor_pct: $cursor_pct,
  kimi_pct: $kimi_pct,
  class_total: (if $quarantine_invalid == "unknown" then "unknown" else ($classes | length | tostring) end),
  ledger_fixed: $fixed_display,
  ledger_owned: $owned_display,
  ledger_scouts: (if $quarantine_invalid == "unknown" then "unknown" else ($classes | map(select(.researching)) | length | tostring) end),
  ledger_watch: (if $quarantine_invalid == "unknown" then "unknown" else ($classes | map(select(.open)) | length | tostring) end),
  merged_invalid: $merged_invalid,
  merged_since: $merged_since,
  new_merged_reported: $new_merged_reported,
  new_seen_ids: $new_seen_ids,
  new_flaw_classes: "unknown",
  has_delta_activity: ((($merged_since | length) > 0)
    or (($seats_started | type) == "string" and $seats_started != "unknown" and ($seats_started | tonumber) > 0)
    or (($seats_retired | type) == "string" and $seats_retired != "unknown" and ($seats_retired | tonumber) > 0)),
  focus_text: "unknown (no typed focus record).",
  queue_fact: (
    (if ($ready_rows | length) == 0 then "The ready queue is empty."
     else "Ready queue: \($ready_rows[0].id) (\(sanitize_text($ready_rows[0].title))) leads \($ready_rows | length) queued item(s)." end)
    + (if ([$in_flight_rows[] | select(.blocked_by != null)] | length) == 0 then ""
       else " Blocked in flight: " + ([$in_flight_rows[] | select(.blocked_by != null) | .id + " by " + sanitize_text(.blocked_by)] | join("; ")) + "." end)
  ),
  next_steps: (
    if ($ready_rows | length) == 0 then ["none queued"]
    else [$ready_rows[:5][] | .id + " (" + sanitize_text(.kind) + ", " + sanitize_text(.repo // "unknown") + ")" ] end
  ),
  parked: (
    if ($held_rows | length) == 0 then ["none"]
    else [$held_rows[] | .id + " (" + sanitize_text(.kind) + ", " + sanitize_text(.repo // "unknown") + ")"
          + " (held " + sanitize_text(.hold_kind // "unknown")
          + (if .hold_reason != null then ": " + sanitize_text(.hold_reason) else "" end)
          + (if .hold_until != null then "; until " + (.hold_until | sanitize_text(.)) else "" end) + ")"] end
  ),
  bars: {
    fixed: (if $landed == null then bar(null; 0) else bar($landed.fixed; $landed.denominator) end),
    seats: bar(null; 0),
    smoke: bar(null; 0),
    quiet: bar(null; 0),
    codex: (if ($codex_pct | type) == "number" then bar($codex_pct; 100) else bar(null; 0) end),
    cursor: (if ($cursor_pct | type) == "number" then bar($cursor_pct; 100) else bar(null; 0) end),
    kimi: (if ($kimi_pct | type) == "number" then bar($kimi_pct; 100) else bar(null; 0) end)
  }
}
