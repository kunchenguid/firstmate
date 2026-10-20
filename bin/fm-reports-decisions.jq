# Recorded captain decisions of one home -> the decision groups the reports page
# shows. bin/fm-reports-decisions.sh owns the collection contract; this file
# owns what counts as a decision and which report one belongs to.
#
# Input, all by argument so that no path is read here:
#   $store    [text]   one `tasks-axi show <id> --full` record per live task
#   $files    [{source, text}]  the markdown backlog and archive files, in
#                               descending authority
#   $reports  [id]     the report ids that exist as data/<id>/report.md
#   $notes    [{name, state, note}]  the source notes the shell already decided
#
# Output: {sources: [{name, state, note}], tasks: [group]}, newest group first,
#   group = {id, title, target, ts, when, question, items}
#   item  = {state: "decided" | "open" | "reconciled", key, digest, mode, words}
#
# WHAT COUNTS AS A DECISION. bin/fm-captain-hold.sh writes exactly three outcome
# forms: `Captain decision:` for the captain's answer, `Reconciliation evidence:`
# inside a reconciled resolution block, and a timestamped `Captain hold
# reconciled:` note outside a resolution block. The older fm-decision-hold.sh
# wrote the captain-decision form too. A resolution block also carries a marker,
# a `Decision digest:` checksum, and a resolution mode.
# That checksum is the identity, so one block reached through the store AND
# through an archive file is ONE decision, and a block repeated across archive
# snapshots is shown once. Blocks keep document order, which is newest first
# because fm-captain-hold prepends.
#
# A task held for the captain that carries no such block still holds the answer
# as plain body prose - the older records of this fleet look that way - and
# contributes one item keyed by its task id, so the archive snapshots of that
# one task collapse into one item instead of multiplying. A captain hold that is
# still waiting contributes an open item instead of a decided one.
#
# NOTHING IS REPAIRED, ONLY READ. The one exception is a body whose line breaks
# came back escaped as literal backslash-n runs. That damage is already in the
# stored record; without undoing it for this read the whole block collapses into
# one unparsable line. The stored record itself is never written.

def trim: gsub("^[[:space:]]+|[[:space:]]+$"; "");

def blank: . == null or . == "" or . == "-" or . == "none";

def val: if blank then null else . end;

# --- the configured store ----------------------------------------------------
# A TOON `  key: value` field, where a quoted value is a JSON string literal and
# "-" or "none" is that field being empty.

def toon_record:
  reduce (split("\n")[]) as $l ({};
    ($l | capture("^  (?<k>[a-z_]+): (?<v>.*)$") // null) as $m
    | if $m == null then .
      else .[$m.k] = ($m.v | if startswith("\"") then (try fromjson catch .) else . end)
      end);

# --- the markdown backlog and archive files ----------------------------------
# All three carry one shape: a `- [ ]` or `- [x]` task line whose body is the
# two-space indented lines that follow, grouped under `## ` sections that an
# archive file dates.

# A task line ends in the tag groups tasks-axi appends, and those are not part
# of the title. They come in two shapes: `(name: value)` for every keyed tag,
# and `(word date)` for the four dated ones. The dated words are listed by name
# rather than matched as "any word", because a title may legitimately end in an
# ordinary parenthesis - "(siehe oben)" must survive, "(merged 2026-10-11)"
# must not. A new tasks-axi tag has to be added here, or it shows up raw in the
# list title and in the entry heading.
def strip_tags:
  (" \\((?:[a-z][a-z-]*:|(?:done|since|merged|reported) )[^()]*\\)$") as $tag
  | until(test($tag) | not; sub($tag; ""));

def tag($name):
  (capture("\\(" + $name + ": (?<v>[^)]*)\\)") // null)
  | if . == null then null else (.v | trim) end;

def md_tasks:
  reduce (split("\n")[]) as $l ({tasks: [], cur: null, archived: null};
      if ($l | test("^## Archived ")) then
        .archived = ($l | sub("^## Archived +"; "") | trim)
      elif ($l | test("^- \\[[ xX]\\] ")) then
        (if .cur == null then . else .tasks += [.cur] end)
        | .cur = {head: ($l | sub("^- \\[[ xX]\\] "; "")), body: [], archived: .archived}
      elif ($l | test("^#")) then
        (if .cur == null then . else .tasks += [.cur] | .cur = null end)
      elif ($l | test("^  ")) or ($l == "") then
        (if .cur == null then . else .cur.body += [($l | sub("^  "; ""))] end)
      else
        (if .cur == null then . else .tasks += [.cur] | .cur = null end)
      end)
  | (if .cur == null then .tasks else .tasks + [.cur] end)
  | to_entries
  | map(.key as $record | .value
        | (.head | capture("^(?<id>[^ ]+)(?: - (?<rest>.*))?$") // {id: .head, rest: null}) as $c
        | ($c.rest // "") as $rest
        | {id: $c.id,
           record: $record,
           title: ($rest | strip_tags | trim),
           closed: (($rest | capture("\\(done (?<v>[0-9][0-9-]*)\\)") // null)
                    | if . == null then null else .v end),
           hold_kind: ($rest | tag("hold-kind")),
           kind: ($rest | tag("kind")),
           archived: .archived,
           body: (.body | join("\n") | trim)});

# --- timestamps --------------------------------------------------------------
# A decision block carries no time of its own, so a group is dated by what the
# record does carry: the close date, else the hold-set stamp, else the archive
# section's date. Everything is read as UTC so two homes order one page alike.

def epoch_of:
  (val // "" | trim) as $t
  | if $t == "" then null
    else (try ($t | sub("Z$"; "") | sub("T"; " ")
               | (if test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$") then . + " 00:00:00" else . end)
               | strptime("%Y-%m-%d %H:%M:%S") | mktime)
          catch null)
    end;

# --- decision blocks ---------------------------------------------------------

# A body that shows the damage gets its escaped line breaks and quotes read
# back; anything else is passed through byte for byte.
def normalize_escapes:
  if test("Resolution recorded by fm-[a-z-]+\\.\\\\+n")
  then gsub("\\\\+n"; "\n") | gsub("\\\\+\""; "\"")
  else . end;

# jq anchors ^ and $ to the whole string, so every pattern that means "a line
# of this body" says (?m) explicitly.
def field($name):
  (capture("(?m)^" + $name + ": (?<v>.*)$") // null)
  | if . == null then null else (.v | trim | val) end;

def words_of:
  (index("Captain decision:") // index("Reconciliation evidence:")) as $i
  | if $i == null then ""
    else (.[($i + (if .[$i:($i + 17)] == "Captain decision:" then 17 else 24 end)):]
          | sub("^\n"; "") | trim) end;

def reconciled_notes:
  [match("(?ms)^Captain hold reconciled: (?<stamp>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z)\nReconcile request: [^\\n]*\n(?<note>.*?)(?=\\n\\nCaptain hold reconciled:|\\z)"; "g")
   | {state: "reconciled", key: .captures[0].string,
      digest: null, mode: null, words: (.captures[1].string | trim)}];

def blocks_of:
  . as $t
  | [match("(?m)^Resolution recorded by fm-[a-z-]+\\.$"; "g")] as $ms
  | [ range(0; ($ms | length)) as $i
      | $t[($ms[$i].offset + $ms[$i].length):
           (if $i + 1 < ($ms | length) then $ms[$i + 1].offset else ($t | length) end)] ]
  | map({digest: field("Decision digest"),
         mode: (field("Resolution mode") // field("Routed identities")),
         state: (if (field("Resolution mode") // "") == "reconciled"
                 then "reconciled" else "decided" end),
         words: words_of})
  | map(select(.digest != null or .words != ""));

def dedupe:
  reduce .[] as $b ({seen: {}, out: []};
    (($b.digest // $b.key)) as $k
    | if .seen[$k] then . else .seen[$k] = true | .out += [$b] end)
  | .out;

# --- one task record, from either source, -> one group ----------------------

def group_of:
  . as $task
  | ((.body // "") | normalize_escapes | trim) as $body
  | ($body | field("Captain hold set")) as $holdset
  | {id: .id,
     rank: .rank,
     title: ((.title | val) // .id),
     origin: ($body | field("Captain hold origin")),
     question: (.hold_reason | val),
     closed: (.closed | val),
     held: (((.hold_kind | val) == "captain") or ((.kind | val) == "captain") or ($holdset != null)),
     ts: ((.closed | epoch_of) // ($holdset | epoch_of) // (.archived | epoch_of)),
     body: $body,
     blocks: ($body | blocks_of | to_entries
              | map(.value + {key: (.value.digest //
                  ("undigested-" + ($task.source | tostring) + "-" + ($task.record | tostring) + "-" + (.key | tostring)))})),
     notes: ($body | reconciled_notes),
     haystack: (((.title // "") + "\n" + ((.links // "") | tostring) + "\n" + $body))};

# The report a group belongs to, in the order the plan fixed: the same id, then
# a report whose own path the record names, then the recorded hold origin.
def target_of($reports):
  . as $g
  | if ($reports | index($g.id)) then $g.id
    else (first($reports[] | . as $r
                | select($g.haystack | contains("data/" + $r + "/report.md"))) // null) as $named
      | if $named != null then $named
        elif ($g.origin != null) and ($reports | index($g.origin)) then $g.origin
        else null end
    end;

# --- assemble ----------------------------------------------------------------

[ ($store | to_entries[] | .key as $record | .value | toon_record
     | . + {rank: 0, source: "store", record: $record}),
  ($files | to_entries[] | .key as $i | .value as $source
     | $source.text | md_tasks[] | . + {rank: ($i + 1), source: $source.source}) ]
| map(group_of)
| map(select((.id // "") != ""))
| map(select(((.blocks | length) > 0)
             or (.held and (((.question // "") != "") or (.body != "")))))
| group_by(.id)
| map(sort_by(.rank)
      | . as $same
      | {id: $same[0].id,
         title: ([$same[] | select(.title != .id) | .title][0] // $same[0].id),
         origin: ([$same[] | .origin | select(. != null)][0] // null),
         question: ([$same[] | .question | select(. != null)][0] // null),
         closed: ([$same[] | .closed | select(. != null)][0] // null),
         ts: ([$same[] | .ts | select(. != null)][0] // 0),
         body: ([$same[] | select(.body != "") | .body][0] // ""),
         haystack: ([$same[] | .haystack] | join("\n")),
         blocks: ([$same[] | .blocks[]] | dedupe),
         notes: ([$same[] | .notes[]] | unique_by(.key))})
| map(. + {target: target_of($reports)})
| map(. as $g
      | {id: $g.id,
         title: $g.title,
         target: $g.target,
         ts: $g.ts,
         when: (if $g.ts == 0 then null else ($g.ts | strftime("%d.%m.%Y")) end),
         question: $g.question,
         items: ([$g.blocks[]
                  | {state: .state, key: .key,
                     digest: .digest, mode: .mode, words: .words}]
                 + $g.notes
                 + (if ($g.blocks | length) == 0 and ($g.notes | length) == 0 and $g.body != ""
                    then [{state: (if $g.closed == null then "open" else "decided" end),
                           key: $g.id, digest: null, mode: null, words: $g.body}]
                    elif ($g.blocks | length) == 0 and ($g.notes | length) == 0
                    then [{state: "open", key: $g.id, digest: null, mode: null, words: ""}]
                    else [] end))})
| sort_by(-.ts)
| {sources: $notes, tasks: .}
