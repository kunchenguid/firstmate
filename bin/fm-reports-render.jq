# Markdown -> HTML for fm-reports-page.sh; that script's header owns the
# generator contract and this file owns the rendered subset.
#
# Input:  [{id, file, updated, ts, md}]            the report rows, md raw
#         $dec [{sources, tasks}]                  fm-reports-decisions.jq's output
# Output: {sources: [...],
#          entries: [{id, kind, title, file, updated, ts, html}]}  newest first
#
# ONE LIST, TWO KINDS OF ENTRY. A decision group whose `target` names a report
# of this home is rendered into that report's own entry, under the report. One
# that gated no report here becomes an entry of its own, kind "decision", so it
# inherits the list, the search, the sorting, and a stable anchor with no
# special case anywhere. That entry opens with its task's title as its heading,
# because it has no report to supply one and an open pane without a title reads
# as if the page lost it.
#
# A decision's own markup is built here too, from the same escaped-first
# renderer, so a captain's words can no more become markup than a report's can.
# Headings inside a decision are rendered with an id prefix: a report's own
# heading ids stay exactly what they were, and no decision can take an id a
# report's in-page link already points at.
#
# NOTHING FROM A REPORT EVER BECOMES MARKUP BY ACCIDENT. Every line is HTML
# escaped first, and only this file's own constructions add tags afterwards, so
# raw HTML in a report is shown as text, exactly as markdown-it's html:false
# does in the reference implementation.
#
# Inline rendering runs in stages over {s, hold}: a stage that has produced
# final markup parks it in `hold` and leaves "<index>" behind, so a
# later stage can never look inside a code span or an href. unpark restores the
# parked markup at the end, repeating while a restored fragment still carries a
# placeholder of its own (a link whose text contained code).
#
# A line ending in two or more spaces is commonmark's hard break and becomes
# <br>, which the reports of this fleet use heavily for stacked one-line facts.
# The substitution runs after code spans are parked, so a break inside a code
# span stays literal, and trailing spaces at the very end of a block are
# dropped rather than left as a dangling break.

def htmlesc:
  gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;") | gsub("\""; "&quot;");

# Heading id, following mdit-py-plugins' anchors slugify: trim, lowercase,
# spaces to dashes, then drop everything that is not a word character or dash.
# German umlauts are lowercased explicitly because ascii_downcase cannot.
def slugify:
  gsub("^[[:space:]]+|[[:space:]]+$"; "")
  | gsub("Ä"; "ä") | gsub("Ö"; "ö") | gsub("Ü"; "ü")
  | ascii_downcase
  | gsub("[[:space:]]"; "-")
  | gsub("[^\\w-]"; "");

# Inline markdown out of a heading, for the list title and the window title.
def clean_inline:
  gsub("!?\\[(?<t>[^\\]]*)\\]\\([^)]*\\)"; "\(.t)")
  | gsub("`|\\*|~~"; "")
  | gsub("^[[:space:]]+|[[:space:]]+$"; "");

def decode_url_entities:
  gsub("(?i)&#(?<n>x[0-9a-f]+|[0-9]+);?"; . as $m
    | ($m.n | ascii_downcase
       | if startswith("x") then .[1:] | explode
         | reduce .[] as $d (0; . * 16 +
             (if $d <= 57 then $d - 48 else $d - 87 end))
         else tonumber end) as $cp
    | if $cp > 0 and $cp <= 1114111 then [$cp] | implode else " " end)
  | gsub("(?i)&colon;"; ":")
  | gsub("(?i)&tab;"; "\t")
  | gsub("(?i)&newline;"; "\n");

def unsafe_url($url; $image):
  ($url
   | gsub("(?i)&amp;"; "&")
   | decode_url_entities
   | explode | map(select(. > 32 and (. < 127 or . > 159))) | implode
   | ascii_downcase) as $check
  | if ($check | test("^(javascript|vbscript|file):")) then true
    elif ($check | test("^data:")) then
      (if $image then ($check | test("^data:image/(png|gif|jpeg|webp|avif);")) else false end) | not
    else false end;

def emph:
  gsub("\\*\\*(?<x>[^*]+)\\*\\*"; "<strong>\(.x)</strong>")
  | gsub("(?<![A-Za-z0-9_])__(?<x>[^_]+)__(?![A-Za-z0-9_])"; "<strong>\(.x)</strong>")
  | gsub("\\*(?<x>[^*]+)\\*"; "<em>\(.x)</em>")
  | gsub("(?<![A-Za-z0-9_])_(?<x>[^_]+)_(?![A-Za-z0-9_])"; "<em>\(.x)</em>")
  | gsub("~~(?<x>[^~]+)~~"; "<del>\(.x)</del>");

# Bare URLs become links (markdown-it's linkify). Already-built links are parked
# by then, so no href is ever rewritten. A URL never ends on punctuation that
# reads as sentence punctuation.
def linkify:
  gsub("(?<p>^|[[:space:](\\[])(?<u>https?://[^[:space:]<>()\\[\\]\"'\\u0001]*[^[:space:]<>()\\[\\]\"'\\u0001.,;:!?])";
       "\(.p)<a href=\"\(.u)\">\(.u)</a>");

def park($markup):  # {s, hold} -> placeholder appended to s, markup kept aside
  .s += ("" + ((.hold | length) | tostring) + "")
  | .hold += [$markup];

# Code spans by backtick run: an opening run of n backticks closes on the next
# run of exactly n, which is what lets a report write a double-backtick span
# containing single backticks without losing either.
def inline_code:
  .s as $t
  | reduce ([$t | match("`+"; "g")][]) as $r
      ({cur: 0, open: null, s: "", hold: .hold};
        if .open == null then .open = $r
        elif $r.length == .open.length then
          .s += $t[(.cur):(.open.offset)]
          | park("<code>" + ($t[(.open.offset + .open.length):($r.offset)] | gsub("^ | $"; "")) + "</code>")
          | .cur = ($r.offset + $r.length)
          | .open = null
        else . end)
  | {s: (.s + $t[(.cur):]), hold: .hold};

def inline_links:
  .s as $t
  | reduce ([$t | match("(?<bang>!?)\\[(?<txt>[^\\]]*)\\]\\((?<url>[^)[:space:]]*)\\)"; "g")][]) as $m
      ({cur: 0, s: "", hold: .hold};
        ($m.captures[0].string // "") as $bang
        | ($m.captures[1].string // "") as $txt
        | ($m.captures[2].string // "") as $url
        | if $m.offset < .cur then .
          else
            .s += $t[(.cur):($m.offset)]
            | park(if unsafe_url($url; ($bang == "!")) then
                (if $bang == "!" then ($txt | gsub("[0-9]+"; "")) else ($txt | emph) end)
              elif $bang == "!"
                then "<img src=\"" + $url + "\" alt=\"" + ($txt | gsub("[0-9]+"; "")) + "\" loading=\"lazy\">"
                else "<a href=\"" + $url + "\">" + ($txt | emph) + "</a>" end)
            | .cur = ($m.offset + $m.length)
          end)
  | {s: (.s + $t[(.cur):]), hold: .hold};

# commonmark hard break: two or more spaces before a newline.
def hard_breaks:
  gsub("[ ]{2,}\n"; "<br>\n") | gsub("[ ]+$"; "");

def unpark:
  .hold as $hold
  | .s
  | until(test("") | not; gsub("(?<n>[0-9]+)"; $hold[(.n | tonumber)]));

# One run of inline markdown -> HTML.
def inline:
  {s: htmlesc, hold: []}
  | inline_code
  | .s |= hard_breaks
  | inline_links
  | .s |= (emph | linkify)
  | unpark;

# --- block level -------------------------------------------------------------
# One pass over the lines. A construct that needs the next line to be decided (a
# table header, a blank line inside a list) is held in the state instead of
# looked ahead at, so the pass stays single and total.

def indent_of: (match("^ *") | .length);

def list_marker:
  if test("^ *([-*+])[[:space:]]+") then
    {t: "ul", ind: indent_of, text: sub("^ *[-*+][[:space:]]+"; "")}
  elif test("^ *[0-9]+[.)][[:space:]]+") then
    {t: "ol", ind: indent_of, text: sub("^ *[0-9]+[.)][[:space:]]+"; "")}
  else null end;

def is_table_rule:
  test("^[[:space:]]*\\|?[[:space:]]*:?-+:?[[:space:]]*(\\|[[:space:]]*:?-+:?[[:space:]]*)*\\|?[[:space:]]*$")
  and test("-");

def table_cells:
  sub("^[[:space:]]*\\|"; "") | sub("\\|[[:space:]]*$"; "")
  | [splits("\\|")] | map(gsub("^[[:space:]]+|[[:space:]]+$"; ""));

def align_of:
  if test("^:.*:$") then "center"
  elif test("^:") then "left"
  elif test(":$") then "right"
  else "" end;

def cell_open($tag; $align):
  "<" + $tag + (if $align == "" then "" else " style=\"text-align:" + $align + "\"" end) + ">";

# The fence run of a fence line, leading indent skipped. The indent is matched
# as part of ONE pattern rather than stripped first: jq 1.6 explodes a gsub
# whose pattern can match the empty string, and "^[[:space:]]*" can.
def fence_of:
  match("^[[:space:]]*(`{3,}|~{3,})") | .captures[0].string;

def fence_lang:
  gsub("^[[:space:]]*(`{3,}|~{3,})"; "")
  | gsub("^[[:space:]]+|[[:space:]]+$"; "")
  | (split(" ")[0] // "");

def code_block($code):
  "<pre><code"
  + (if $code.lang == "" then "" else " class=\"language-" + ($code.lang | htmlesc) + "\"" end)
  + ">" + (($code.lines | join("\n")) | htmlesc) + "\n</code></pre>";

def flush_para:
  if (.para | length) > 0
  then .out += ["<p>" + (.para | join("\n") | inline) + "</p>"] | .para = []
  else . end;

def flush_quote:
  if (.quote | length) > 0
  then .out += ["<blockquote><p>" + (.quote | join("\n") | inline) + "</p></blockquote>"] | .quote = []
  else . end;

def flush_item:
  if .item == null then .
  else .out += [(.item | join("\n") | inline) + "</li>"] | .item = null end;

def flush_parent_item:
  if .item == null then .
  else .out += [(.item | join("\n") | inline)] | .item = null | .stack[-1].item_open = true end;

def pop_list:
  flush_item | .out += ["</" + .stack[-1].t + ">"] | .stack |= .[0:-1]
  | if (.stack | length) > 0 and .stack[-1].item_open
    then .out += ["</li>"] | .stack[-1].item_open = false
    else . end;

def close_lists($to_ind):
  until((.stack | length) == 0 or .stack[-1].ind <= $to_ind; pop_list);

def close_all_lists:
  until((.stack | length) == 0; pop_list);

def flush_table:
  if .table == null then .
  else
    (.table) as $t
    | .out += ["<table><thead><tr>"
        + ([range(0; ($t.head | length)) as $i
            | cell_open("th"; ($t.align[$i] // "")) + ($t.head[$i] | inline) + "</th>"] | join(""))
        + "</tr></thead>"
        + (if ($t.rows | length) == 0 then ""
           else "<tbody>"
             + ([$t.rows[] as $row
                 | "<tr>" + ([range(0; ($t.head | length)) as $i
                     | cell_open("td"; ($t.align[$i] // "")) + (($row[$i] // "") | inline) + "</td>"] | join(""))
                 + "</tr>"] | join(""))
             + "</tbody>" end)
        + "</table>"]
    | .table = null
  end;

def flush_candidate:
  if .cand == null then . else .para += [.cand] | .cand = null end;

# Everything open except a list, which survives a blank line.
def flush_inline_blocks:
  flush_candidate | flush_para | flush_quote | flush_table;

# Heading ids are unique inside one report, so an in-report link can never be
# ambiguous; a repeated heading gets -1, -2, ... as markdown-it's anchors do.
def heading_key($raw):
  ($raw | clean_inline | slugify) as $base
  | if $base == "" then "abschnitt" else $base end;

def md_to_html($idprefix):
  (gsub("\r"; "") | gsub(""; "") | split("\n")) as $lines
  | reduce $lines[] as $line
      ({out: [], para: [], quote: [], item: null, stack: [], table: null, cand: null,
        code: null, seen: {}, blank: false};

        # inside a fenced code block nothing is markdown
        if .code != null then
          if ($line | test("^[[:space:]]*(`{3,}|~{3,})[[:space:]]*$"))
             and (($line | fence_of | .[0:1]) == (.code.fence | .[0:1]))
             and (($line | fence_of | length) >= (.code.fence | length))
          then .out += [code_block(.code)] | .code = null
          else .code.lines += [$line] end

        # fence open
        elif ($line | test("^[[:space:]]*(`{3,}|~{3,})")) then
          flush_inline_blocks
          | close_all_lists
          | .blank = false
          | .code = {fence: ($line | fence_of), lang: ($line | fence_lang), lines: []}

        # blank line: closes everything but a list, which may continue
        elif ($line | test("^[[:space:]]*$")) then
          flush_inline_blocks | .blank = true

        # ATX heading
        elif ($line | test("^#{1,6}[ \\t]+")) then
          flush_inline_blocks | close_all_lists | .blank = false
          | ($line | match("^#{1,6}") | .string | length) as $lvl
          | ($line | sub("^#{1,6}[ \\t]+"; "") | sub("[ \\t]+#+[ \\t]*$"; "")) as $raw
          | heading_key($raw) as $key
          | ((.seen[$key]) // 0) as $n
          | (if $n == 0 then $key else $key + "-" + ($n | tostring) end) as $id
          | .seen[$key] = ($n + 1)
          | .out += ["<h" + ($lvl | tostring) + " id=\"" + (($idprefix + $id) | htmlesc) + "\">"
              + ($raw | inline) + "</h" + ($lvl | tostring) + ">"]

        # thematic break
        elif ($line | test("^[[:space:]]*(-{3,}|\\*{3,}|_{3,})[[:space:]]*$")) then
          flush_inline_blocks | close_all_lists | .blank = false | .out += ["<hr>"]

        # blockquote
        elif ($line | test("^[[:space:]]*>")) then
          flush_candidate | flush_para | flush_table | close_all_lists | .blank = false
          | .quote += [($line | sub("^[[:space:]]*> ?"; ""))]

        # table: a pipe line is held until the next line says whether it was a header
        elif .cand != null and ($line | is_table_rule) then
          .table = {head: (.cand | table_cells),
                    align: ($line | table_cells | map(align_of)),
                    rows: []}
          | .cand = null | .blank = false

        elif .table != null and ($line | test("\\|")) and ($line | list_marker) == null then
          .table.rows += [($line | table_cells)] | .blank = false

        elif ($line | test("^[[:space:]]*\\|")) and ($line | list_marker) == null then
          flush_candidate | flush_table | .cand = $line | .blank = false

        # list item
        elif ($line | list_marker) != null then
          ($line | list_marker) as $m
          | flush_candidate | flush_para | flush_quote | flush_table | .blank = false
          | close_lists($m.ind)
          | (if (.stack | length) == 0 or .stack[-1].ind < $m.ind
             then flush_parent_item | .out += ["<" + $m.t + ">"] | .stack += [{t: $m.t, ind: $m.ind, item_open: false}]
             elif .stack[-1].t != $m.t
             then flush_item | .out += ["</" + .stack[-1].t + ">", "<" + $m.t + ">"]
               | .stack = (.stack | .[0:-1]) + [{t: $m.t, ind: $m.ind}]
             else flush_item end)
          | .item = [$m.text]
          | .out += ["<li>"]

        # continuation of an open list item
        elif (.stack | length) > 0 and .item != null and ($line | indent_of) > .stack[-1].ind then
          .item += [($line | gsub("^[[:space:]]+"; ""))] | .blank = false

        # plain paragraph line
        else
          flush_candidate | flush_table
          | (if .blank then close_all_lists else . end)
          | .blank = false
          | (if .item != null then .item += [($line | gsub("^[[:space:]]+"; ""))]
             else .para += [$line] end)
        end)

  # end of input: close whatever is still open
  | (if .code != null then .out += [code_block(.code)] | .code = null else . end)
  | flush_inline_blocks
  | close_all_lists
  | .out | join("\n");

def title_of($md; $id):
  (($md | gsub("\\r"; "") | split("\n") | .[0] | (match("^#[ \\t]+(?<t>.+)$") // null)) as $m
   | if $m == null then "" else ($m.captures[0].string // "") end
   | clean_inline) as $t
  | if $t == "" then $id else $t end;

# --- decisions ---------------------------------------------------------------
# One entry's decision groups -> the section that follows the report. A group
# names its own task, so a report that several tasks gated shows which decision
# came from which task; a decision-only entry leaves that heading out because
# the entry already IS that task.

def dec_meta($state; $mode; $digest):
  "<p class=\"dec-meta\"><span class=\"dec-state\">" + ($state | htmlesc) + "</span>"
  + (if ($mode // "") == "" then "" else " &middot; resolution " + ($mode | htmlesc) end)
  + (if ($digest // "") == "" then ""
     else " &middot; checksum <code>" + ($digest[0:12] | htmlesc) + "</code>" end)
  + "</p>";

def dec_group($gi; $self):
  . as $g
  | "<section class=\"dec-group\">"
    + (if $g.id == $self then ""
       else "<h3 id=\"entscheidung-" + ($g.id | htmlesc) + "\">" + ($g.title | htmlesc) + "</h3>"
       end)
    + "<p class=\"dec-where\">task <code>" + ($g.id | htmlesc) + "</code>"
    + (if ($g.when // "") == "" then "" else " &middot; " + ($g.when | htmlesc) end)
    + "</p>"
    + (if ($g.question // "") == "" then ""
       else "<div class=\"dec-q\"><p class=\"dec-label\">Question put to the captain</p>"
            + ($g.question | md_to_html("f" + ($gi | tostring) + "-")) + "</div>"
       end)
    + ([$g.items | to_entries[]
        | .key as $ii | .value as $it
        | "<div class=\"dec-item dec-" + ($it.state | htmlesc) + "\">"
          + dec_meta($it.state; $it.mode; $it.digest)
          + (if ($it.words // "") == "" then ""
             else ($it.words | md_to_html("e" + ($gi | tostring) + "x" + ($ii | tostring) + "-"))
             end)
          + "</div>"] | join(""))
    + "</section>";

def decisions_html($self):
  if (. // [] | length) == 0 then ""
  else "<section class=\"dec\"><h2 id=\"decisions\">Decisions</h2>"
       + ([to_entries[] | .key as $gi | .value | dec_group($gi; $self)] | join(""))
       + "</section>"
  end;

def entry:
  . as $e
  | {id: $e.id,
     kind: $e.kind,
     file: $e.file,
     updated: $e.updated,
     ts: $e.ts,
     title: (if $e.kind == "decision"
             then ((($e.groups // [])[0].title // $e.id))
             else title_of($e.md; $e.id) end),
     html: ((if ($e.md // "") == ""
             then "<h1>" + ((($e.groups // [])[0].title // $e.id) | htmlesc) + "</h1>"
             else ($e.md | md_to_html("")) end)
            + (($e.groups // []) | decisions_html($e.id)))};

(($dec[0]) // {sources: [], tasks: []}) as $d
| . as $reports
| {sources: ($d.sources // []),
   entries:
     (([$reports[] | . as $r
        | $r + {kind: "report", groups: [$d.tasks[] | select(.target == $r.id)]}]
       + [$d.tasks[] | select(.target == null) | . as $g
          | {id: $g.id, kind: "decision", file: null, updated: ($g.when // ""),
             ts: ($g.ts // 0), md: "", groups: [$g]}])
      | map(entry)
      | sort_by(-.ts))}
