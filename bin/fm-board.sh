#!/usr/bin/env bash
# fm-board.sh - render the operator board as one self-contained HTML artifact.
#
# The board is the four-column operator surface: Waiting on you, Under way,
# Queued, and Landed.
# It exists because that surface was being hand-written per refresh, which made
# every board a fresh transcription of state that had already moved.
#
# This command does not parse fleet state itself.
# Like bin/fm-fleet-view.sh it shells out to bin/fm-fleet-snapshot.sh --json and
# renders that stable structured contract, so the snapshot stays the one owner of
# what the fleet currently is.
#
# THE SEAM. The script owns everything mechanically derivable from durable state
# and nothing else:
#   Under way   one card per live direct report, from its recorded metadata plus
#               the current state bin/fm-crew-state.sh reports, stamped with the
#               time that state was read.
#   Queued      queued backlog items with their unresolved blockers and date gates.
#   Landed      recent completions with their delivery artifact, including the
#               landings rolled up from delegated homes.
#   Waiting on you, the mechanical half: work with a locally recorded pull request,
#               captain-held queued items, and every unresolved decision key folded
#               out of the durable status logs, here and in every delegated home.
#               A delegated home the snapshot could not read whole is named rather
#               than reported as holding nothing.
#
# The script does NOT derive the judgment half.
# Option lists, recommendations, the reasoning for preferring one option, and the
# chores only the operator can do are written per decision and cannot be inferred
# from a status line, so they arrive through --cards as authored input that is
# merged into the Waiting-on-you column alongside the mechanical cards.
# See BOARD CARDS in --help for that format; it is validated, never trusted.
#
# A decision key present in the durable logs with no authored card still renders,
# marked as not yet elaborated. Silence about a pending decision is the one
# failure this board must not have, so an unelaborated key is never dropped.
#
# The artifact is self-contained: one file, no CDN, no sibling assets, so it opens
# from disk on any device whether or not a viewer is running. Every rendered string
# is HTML-escaped, and paths under the operator's home are reduced to ~ before
# rendering; the write is refused outright if the home path survives into the output.
#
# Read-only with respect to the fleet: no lock, no wake queue, no mutation, and no
# network. It writes only its own artifact and prints that path.
# It never polls: arming the artifact as a wake source is a separate step, owned by
# bin/fm-procevent.sh and its Lavish adapter.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

usage() {
  cat <<'EOF'
usage: fm-board.sh [options]

Render the operator board from live fleet state and print the artifact path.

Options:
  --cards <file>     authored Waiting-on-you cards (see BOARD CARDS below)
  --out <path>       artifact path (default: $FM_HOME/.lavish/board.html)
  --snapshot <file>  render a saved `fm-fleet-snapshot.sh --json` instead of
                     taking a fresh snapshot; "-" reads stdin
  --landed <n>       how many recent landings to show (default: 8)
  --title <text>     page title (default: The Bridge)
  --stale-mins <n>   minutes of age after which the board warns it is stale;
                     twice that marks it too old to trust (default: 30)
  -h, --help         this help

BOARD CARDS

  A line-oriented text file. Blank lines and lines starting with # are ignored.
  Each card opens with a type header and is followed by `field: value` lines.
  Repeatable fields keep the order they are written in. Values are single-line.

    [decision]
    key: mesh-note                 required, identifies the answer; slug only
    binds: listen-collapse-a30:default
                                   optional; the durable decision this elaborates,
                                   written as <task-id>:<decision-key>
    title: One word, whenever      required
    tag: listening screen          optional badge
    body: A paragraph.             repeatable
    warn: Three rounds on one theme.
                                   repeatable; renders as a callout
    option: ship | **Ship it** - one paragraph recording a measured fact
                                   repeatable, at least one; `<value> | <label>`,
                                   where the value is a slug and the label is
                                   everything after the first ' | '
    recommend: ship                optional; must name one of this card's options
    footnote: Why not the other one today ...
                                   repeatable; small print under the options

    [chores]
    title: Only you can do these   optional
    item: **Tier-2 listening session.** 22 clips staged.
                                   repeatable, at least one
    footnote: No pull request waiting on a merge.
                                   optional

  Labels, bodies, items, warnings and footnotes take a small inline markup:
  **bold**, *italic*, and `code`. Everything else is escaped, so authored text
  can never inject markup of its own. Backticks must be balanced.

  The file is validated as a whole before anything is written: an unknown field,
  a card missing a required field, a duplicate key, an option value that is not a
  slug, a recommendation that names no option, or a `binds` naming a decision the
  durable logs do not have all refuse the render rather than producing a partial
  board. A decision open in a delegated home is bound as <home>/<task-id>:<key>.
EOF
}

die() { printf 'fm-board: %s\n' "$1" >&2; exit 1; }
usage_error() { printf 'fm-board: %s\n' "$1" >&2; usage >&2; exit 2; }

CARDS_FILE=""
OUT=""
SNAPSHOT_FILE=""
LANDED=8
TITLE="The Bridge"
STALE_MINS=30

require_value() {  # <flag> <count>
  [ "$2" -gt 1 ] || usage_error "$1 requires a value"
}
# Counts reach jq as --argjson, where a leading zero is not valid JSON, so the
# canonical form is settled here where a complaint can still name the flag.
COUNT_VALUE=0
require_count() {  # <flag> <value>
  case "$2" in
    ''|*[!0-9]*) usage_error "$1 must be a non-negative integer" ;;
  esac
  COUNT_VALUE=$2
  while [ "${#COUNT_VALUE}" -gt 1 ]; do
    case "$COUNT_VALUE" in
      0*) COUNT_VALUE=${COUNT_VALUE#0} ;;
      *) break ;;
    esac
  done
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --cards) require_value --cards "$#"; CARDS_FILE=$2; shift 2 ;;
    --out) require_value --out "$#"; OUT=$2; shift 2 ;;
    --snapshot) require_value --snapshot "$#"; SNAPSHOT_FILE=$2; shift 2 ;;
    --landed) require_value --landed "$#"; require_count --landed "$2"; LANDED=$COUNT_VALUE; shift 2 ;;
    --title) require_value --title "$#"; TITLE=$2; shift 2 ;;
    --stale-mins)
      require_value --stale-mins "$#"
      case "$2" in ''|*[!0-9]*) usage_error "--stale-mins must be a positive integer" ;; esac
      require_count --stale-mins "$2"
      [ "$COUNT_VALUE" != 0 ] || usage_error "--stale-mins must be a positive integer"
      STALE_MINS=$COUNT_VALUE; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage_error "unknown option: $1" ;;
  esac
done

command -v jq >/dev/null 2>&1 || die "jq not found"

[ -n "$OUT" ] || OUT="$FM_HOME/.lavish/board.html"

# --- snapshot ---------------------------------------------------------------

if [ -n "$SNAPSHOT_FILE" ]; then
  if [ "$SNAPSHOT_FILE" = - ]; then
    SNAPSHOT=$(cat)
  else
    [ -f "$SNAPSHOT_FILE" ] || die "snapshot file not found: $SNAPSHOT_FILE"
    SNAPSHOT=$(cat "$SNAPSHOT_FILE")
  fi
  printf '%s' "$SNAPSHOT" | jq -e 'type == "object" and has("tasks") and has("backlog")' >/dev/null 2>&1 \
    || die "snapshot file is not an fm-fleet-snapshot object: $SNAPSHOT_FILE"
else
  SNAPSHOT=$("$SCRIPT_DIR/fm-fleet-snapshot.sh" --json) || die "fleet snapshot failed"
fi

# Every durable open decision, as the identifiers an authored card may bind to,
# and the validation domain for a card's `binds` field. A decision held in a
# delegated home is namespaced by that home so the two sets cannot collide; the
# renderer folds both into the same column off the same identity.
# This read decides what an authored `binds` may name, so it must never fail
# quietly: an empty domain would turn a genuinely open decision into the refusal
# "there are no open decisions right now", which is the silence the board exists
# to prevent, arriving through the error path.
DURABLE_KEYS=$(printf '%s' "$SNAPSHOT" | jq -r '
  ([ .tasks[]? | select(.kind != "secondmate") | . as $t
     | ((.hints.open_decisions // []) | if type == "array" then . else [] end)[]
     | select(type == "object" and .key != null)
     | "\($t.id):\(.key)" ]
   + [ .secondmate_current.records[]? | . as $m
       | ((.decisions_open // []) | if type == "array" then . else [] end)[]
       | select(type == "object" and .id != null and .key != null)
       | "\($m.id)/\(.id):\(.key)" ])
  | unique | .[]') \
  || die "could not read the open decisions this snapshot holds, so a card's 'binds' cannot be checked against them"

# --- authored cards ---------------------------------------------------------
#
# Parsed and validated here, where a problem can name the file and line, then
# handed to the renderer as structured records. Nothing is written before the
# whole file validates.

CARDS_ROWS=""

parse_cards() {  # <file>
  local file=$1 line lineno=0 idx=0 field value type="" rows="" known
  local -a keys=() opts=() recommends=() reclines=() bindvals=() bindlines=()
  local -a have_title=() have_option=() have_item=() have_key=() blocklines=() types=()

  card_error() { printf 'fm-board: %s:%s: %s\n' "$file" "$1" "$2" >&2; exit 2; }

  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    line=${line%$'\r'}
    case "$line" in
      ''|'#'*) continue ;;
      '['*']')
        type=${line#'['}
        type=${type%']'}
        case "$type" in
          decision|chores) ;;
          *) card_error "$lineno" "unknown card type: [$type] (expected [decision] or [chores])" ;;
        esac
        idx=$((idx + 1))
        keys+=("") ; have_title+=(0) ; have_option+=(0) ; have_item+=(0) ; have_key+=(0)
        blocklines+=("$lineno") ; types+=("$type")
        rows+="$idx"$'\t'"type"$'\t'"$type"$'\n'
        continue
        ;;
    esac

    [ "$idx" -gt 0 ] || card_error "$lineno" "field outside any card; open one with [decision] or [chores]"

    case "$line" in
      *:*) ;;
      *) card_error "$lineno" "not a field line; expected '<field>: <value>'" ;;
    esac
    field=${line%%:*}
    value=${line#*:}
    value=${value# }
    # Trim surrounding whitespace so an authored line's indentation never leaks.
    value=${value#"${value%%[![:space:]]*}"}
    value=${value%"${value##*[![:space:]]}"}
    case "$field" in
      ''|*[!a-z]*) card_error "$lineno" "not a field name: '$field'" ;;
    esac
    [ -n "$value" ] || card_error "$lineno" "field '$field' has an empty value"

    # Inline markup is only ever applied to authored text, so only authored text
    # has to have balanced backticks.
    case "$field" in
      body|warn|option|footnote|item|title)
        local ticks
        ticks=${value//[!\`]/}
        [ $(( ${#ticks} % 2 )) -eq 0 ] || card_error "$lineno" "unbalanced backtick in '$field'"
        ;;
    esac

    if [ "$type" = decision ]; then
      case "$field" in
        key|binds|title|tag|body|warn|option|recommend|footnote) ;;
        *) card_error "$lineno" "unknown field for [decision]: '$field'" ;;
      esac
    else
      case "$field" in
        title|item|footnote) ;;
        *) card_error "$lineno" "unknown field for [chores]: '$field'" ;;
      esac
    fi

    case "$field" in
      key)
        [ "${have_key[idx-1]}" = 0 ] || card_error "$lineno" "duplicate 'key' in one card"
        case "$value" in
          *[!A-Za-z0-9._-]*|-*|.*) card_error "$lineno" "key must be a slug of letters, digits, '.', '_' or '-': '$value'" ;;
        esac
        local seen
        for seen in "${keys[@]}"; do
          [ "$seen" = "$value" ] && card_error "$lineno" "duplicate key across cards: '$value'"
        done
        keys[idx-1]=$value
        have_key[idx-1]=1
        ;;
      title)
        [ "${have_title[idx-1]}" = 0 ] || card_error "$lineno" "duplicate 'title' in one card"
        have_title[idx-1]=1
        ;;
      option)
        case "$value" in
          *' | '*) ;;
          *) card_error "$lineno" "option must be '<value> | <label>'" ;;
        esac
        local optval optlabel
        optval=${value%% | *}
        optlabel=${value#* | }
        [ -n "$optval" ] || card_error "$lineno" "option has an empty value"
        [ -n "$optlabel" ] || card_error "$lineno" "option has an empty label"
        # The value is an identifier that has to survive into the answer payload
        # unchanged, so it is held to the same slug shape as a card key.
        case "$optval" in
          *[!A-Za-z0-9._-]*|-*|.*) card_error "$lineno" "option value must be a slug of letters, digits, '.', '_' or '-': '$optval'" ;;
        esac
        for seen in ${opts[@]+"${opts[@]}"}; do
          [ "$seen" = "$idx/$optval" ] && card_error "$lineno" "duplicate option value in one card: '$optval'"
        done
        opts+=("$idx/$optval")
        have_option[idx-1]=1
        ;;
      recommend)
        recommends+=("$idx/$value")
        reclines+=("$lineno")
        ;;
      binds)
        bindvals+=("$value")
        bindlines+=("$lineno")
        ;;
      item)
        have_item[idx-1]=1
        ;;
    esac
    rows+="$idx"$'\t'"$field"$'\t'"$value"$'\n'
  done < "$file"

  # Whole-file checks, once every card is known.
  local i n rec recidx recval bind
  n=$idx
  i=1
  while [ "$i" -le "$n" ]; do
    if [ "${types[i-1]}" = decision ]; then
      [ "${have_key[i-1]}" = 1 ] || card_error "${blocklines[i-1]}" "this [decision] is missing a 'key'"
      [ "${have_title[i-1]}" = 1 ] || card_error "${blocklines[i-1]}" "[decision] ${keys[i-1]} is missing a 'title'"
      [ "${have_option[i-1]}" = 1 ] || card_error "${blocklines[i-1]}" "[decision] ${keys[i-1]} has no 'option'"
    else
      [ "${have_item[i-1]}" = 1 ] || card_error "${blocklines[i-1]}" "this [chores] card has no 'item'"
    fi
    i=$((i + 1))
  done

  i=0
  for rec in ${recommends[@]+"${recommends[@]}"}; do
    i=$((i + 1))
    recidx=${rec%%/*}
    recval=${rec#*/}
    local found=0 seen2
    for seen2 in ${opts[@]+"${opts[@]}"}; do
      [ "$seen2" = "$recidx/$recval" ] && found=1
    done
    [ "$found" = 1 ] || card_error "${reclines[i-1]}" "recommend names no option of this card: '$recval'"
  done

  i=0
  for bind in ${bindvals[@]+"${bindvals[@]}"}; do
    i=$((i + 1))
    if ! printf '%s\n' "$DURABLE_KEYS" | grep -qxF "$bind"; then
      printf 'fm-board: %s:%s: binds names no open decision: %s\n' "$file" "${bindlines[i-1]}" "$bind" >&2
      if [ -n "$DURABLE_KEYS" ]; then
        printf 'fm-board: open decisions are:\n' >&2
        while IFS= read -r known; do
          [ -n "$known" ] && printf '  %s\n' "$known" >&2
        done <<EOF
$DURABLE_KEYS
EOF
      else
        printf 'fm-board: there are no open decisions right now\n' >&2
      fi
      exit 2
    fi
  done

  printf '%s' "$rows"
}

if [ -n "$CARDS_FILE" ]; then
  [ -f "$CARDS_FILE" ] || die "cards file not found: $CARDS_FILE"
  CARDS_ROWS=$(parse_cards "$CARDS_FILE") || exit $?
fi

CARDS_JSON=$(printf '%s' "$CARDS_ROWS" | jq -R -s '
  def rows:
    split("\n")
    | map(select(length > 0))
    | map(capture("^(?<i>[0-9]+)\t(?<f>[a-z]+)\t(?<v>.*)$"));
  def field($f): (map(select(.f == $f) | .v) | .[0]);
  def fields($f): (map(select(.f == $f) | .v));
  rows
  | group_by(.i | tonumber)
  | map({
      type: field("type"),
      key: field("key"),
      binds: field("binds"),
      title: field("title"),
      tag: field("tag"),
      body: fields("body"),
      warn: fields("warn"),
      footnote: fields("footnote"),
      item: fields("item"),
      recommend: field("recommend"),
      options: (fields("option") | map(
        split(" | ")
        | { value: .[0], label: (.[1:] | join(" | ")) }
      ))
    })
') || die "could not assemble the authored cards"

# --- render -----------------------------------------------------------------

REDACT_HOME=${HOME:-}
case "$REDACT_HOME" in ''|/) REDACT_HOME="" ;; esac
SNAPSHOT_HOME=$(printf '%s' "$SNAPSHOT" | jq -r '.fm_home // ""') \
  || die "could not read the snapshot's own home path, so the leak boundary cannot be enforced"
case "$SNAPSHOT_HOME" in /) SNAPSHOT_HOME="" ;; esac

# The board now reads delegated state, so a delegated home's path is on the same
# leak boundary as the operator's own: reduced per field, and refused if it
# survives.
MATE_HOMES=$(printf '%s' "$SNAPSHOT" | jq -c '
  ([ .secondmate_current.records[]? | .home ] + [ .secondmate_landed.records[]? | .home ])
  | map(select(type == "string" and . != "" and . != "/")) | unique') \
  || die "could not read the delegated home paths, so the leak boundary cannot be enforced"

# The renderer is a quoted heredoc rather than an inline argument: the emitted
# page carries JavaScript full of single quotes, which no single-quoted shell
# string can hold.
RENDER=$(cat <<'JQ_RENDER'

# --- text safety ------------------------------------------------------------
# Absolute paths under the operator home are reduced before anything is escaped,
# so no rendered string carries the account layout. split/join is a literal
# replacement, never a pattern.
def redact:
  (if . == null then "" else tostring end)
  | reduce $mates[] as $m (.; split($m) | join("~/…"))
  | (if ($fmhome | length) > 0 and ($fmhome != $home) then split($fmhome) | join("~/…") else . end)
  | (if ($home | length) > 0 then split($home) | join("~") else . end);

# Snapshot-derived prose is escaped and never marked up: it was not authored as
# markup, so an asterisk in it is an asterisk.
def esc: redact | @html;

def emphasis:
  gsub("\\*\\*(?<t>[^*]+)\\*\\*"; "<strong>\(.t)</strong>")
  | gsub("\\*(?<t>[^*]+)\\*"; "<em>\(.t)</em>");

# Authored text takes the documented inline subset. Backticks are balanced by the
# parser, so odd segments of the split are exactly the code spans, and emphasis
# is never applied inside one.
def md:
  esc
  | split("`")
  | to_entries
  | map(if (.key % 2) == 1 then "<code>" + .value + "</code>" else (.value | emphasis) end)
  | join("");

def clip($n): if (. | length) > $n then (.[0:$n] | rtrimstr(" ")) + "…" else . end;

# Bounded snapshot prose. The cut lands after redaction and before escaping, so
# it can neither split an entity nor spend the budget on escape expansion, and a
# home path can never be cut into a fragment the leak guard would not recognise.
def escn($n): redact | clip($n) | @html;

def basename: (. // "") | split("/") | last // "";
def hhmm: (. // "") | (try (fromdateiso8601 | strflocaltime("%H:%M")) catch "");
def when($iso): ($iso | hhmm) as $t | (if $t == "" then "" else "state as of " + $t end);

# --- model ------------------------------------------------------------------

. as $s
| ($s.generated | (try fromdateiso8601 catch 0)) as $gen_epoch
| [$s.tasks[]? | select(.kind != "secondmate")] as $work
| [$s.backlog.records[]? | select(.structured)] as $records

# Waiting on you, mechanical half.
#
# A decision held in a delegated home is a pending decision like any other, and
# the board already reaches into delegated state for its landings, so the two
# sources are folded into one list off one identity. A delegated entry carries
# the home it came from; a main-home entry carries no home.
# A delegated entry's `summary` carries two different things depending on how the
# snapshot built it, so which slot it belongs in is read off the entry's own kind
# rather than guessed from the text. A captain hold carries the item title in
# `summary` and the hold reason in `reason`; a status decision carries the
# decision text in `summary` and no reason. Either way the heading names the work
# and the body carries what is actually being decided, so no card says the same
# thing twice and nothing the snapshot carried is dropped.
| ( [ $work[]
    | . as $t
    | ((.hints.open_decisions // []) | if type == "array" then . else [] end)[]
    | select(type == "object")
    | { kind: "decision",
        id: "\($t.id):\(.key)",
        home: null,
        task: $t.id,
        task_title: ($t.backlog.title // $t.id),
        project: ($t.project | basename),
        verb: .verb,
        summary: .summary } ]
  + [ $s.secondmate_current.records[]?
      | . as $m
      | ((.decisions_open // []) | if type == "array" then . else [] end)[]
      | select(type == "object" and .id != null and .key != null)
      | . as $e
      | (($e.source // "") == "backlog" or ($e.verb // "") == "captain-hold") as $held
      | { kind: "decision",
          id: "\($m.id)/\($e.id):\($e.key)",
          home: $m.id,
          task: $e.id,
          task_title: (if $held then (($e.summary // $e.id) | tostring) else ($e.id | tostring) end),
          project: ($m.id | tostring),
          verb: ($e.verb // "needs-decision"),
          summary: (if $held then (($e.reason // "") | tostring) else (($e.summary // "") | tostring) end) } ] ) as $durable

# A delegated home the snapshot could not read whole cannot be reported as
# holding no decisions, so what was not read is stated rather than assumed.
| ( [ $s.secondmate_current.records[]?
    | select((.provenance.selected // "") != "structured-home")
    | { id: (.id | tostring), reason: ((.current.reason // "state unavailable") | tostring) } ]
  + [ $s.secondmate_current.records[]?
      | . as $m
      | ((.omitted // []) | if type == "array" then . else [] end)[]
      | select(type == "object" and .surface == "decisions_open")
      | { id: ($m.id | tostring),
          reason: "\(.count) more open decisions than this snapshot carries" } ] ) as $unread_homes
| [ $work[]
    | select(.pr.url != null)
    | { id: .id,
        title: (.backlog.title // .id),
        project: (.project | basename),
        url: .pr.url,
        state: .current_state.state } ] as $prs
| [ $records[]
    | select(.state == "queued" and (.captain_actionable == true or .hold_kind == "captain"))
    | { id: .id, title: .title, reason: .hold_reason } ] as $held

# Authored cards, and which durable decisions they elaborate.
| [ $cards[] | select(.type == "decision") ] as $authored
| [ $authored[] | select(.binds != null) | .binds ] as $bound
| [ $durable[] | select(.id as $d | ($bound | index($d)) | not) ] as $unelaborated
| [ $cards[] | select(.type == "chores") ] as $chores

# --- fragments --------------------------------------------------------------

| def option_html($card):
    [ $card.options[]
      | "<label class=\"opt\">"
        + "<input type=\"radio\" name=\"\($card.key | esc)\""
        + " data-question=\"\($card.title | esc)\""
        + (if $card.binds != null then " data-binds=\"\($card.binds | esc)\"" else "" end)
        + " value=\"\(.value | esc)\">"
        + "<span>\(.label | md)"
        + (if $card.recommend == .value then " <span class=\"pill pill-primary\">my pick</span>" else "" end)
        + "</span></label>" ] | join("");

  def authored_card($c):
    "<article class=\"card accent-primary\">"
    + "<div class=\"card-head\"><h3>\($c.title | md)</h3>"
    + (if $c.tag != null then "<span class=\"pill\">\($c.tag | esc)</span>" else "" end)
    + "</div>"
    + ([$c.body[] | "<p>\(. | md)</p>"] | join(""))
    + ([$c.warn[] | "<p class=\"callout\">\(. | md)</p>"] | join(""))
    + "<div class=\"opts\">\(option_html($c))</div>"
    + ([$c.footnote[] | "<p class=\"fine\">\(. | md)</p>"] | join(""))
    + "</article>";

  def unelaborated_card($d):
    "<article class=\"card accent-warning\">"
    + "<div class=\"card-head\"><h3>\($d.task_title | escn(90))</h3>"
    + "<span class=\"pill\">\($d.project | esc)</span></div>"
    + "<p class=\"fine\">Open decision <code>\($d.id | esc)</code> &middot; \($d.verb | esc)"
    + (if $d.home != null then " &middot; held in delegated home \($d.home | esc)" else "" end)
    + "</p>"
    + (if ($d.summary // "") != "" then "<p>\($d.summary | escn(700))</p>" else "" end)
    + "<p class=\"callout\">Not written up yet - there are no options on this card. "
    + "Ask for it to be laid out before answering.</p>"
    + "</article>";

  def unread_homes_card:
    "<article class=\"card accent-warning\">"
    + "<div class=\"card-head\"><h3>Delegated homes this snapshot could not read whole</h3></div>"
    + "<ul>"
    + ([ $unread_homes[]
         | "<li><strong>\(.id | escn(120))</strong>"
           + "<span class=\"sub\">\(.reason | escn(160))</span></li>" ] | join(""))
    + "</ul>"
    + "<p class=\"fine\">These homes are not being reported as holding nothing. "
    + "Ask for a fresh board once they read cleanly.</p>"
    + "</article>";

  def pr_card:
    "<article class=\"card accent-info\">"
    + "<div class=\"card-head\"><h3>Waiting for your merge</h3></div>"
    + "<ul>"
    + ([ $prs[]
         | "<li><strong>\(.title | escn(110))</strong> "
           + "<span class=\"pill\">\(.project | esc)</span><br>"
           + "<a href=\"\(.url | esc)\">\(.url | esc)</a></li>" ] | join(""))
    + "</ul>"
    + "<p class=\"fine\">Recorded locally. This board takes no snapshot of the forge, "
    + "so it does not know whether one of these has already been merged.</p>"
    + "</article>";

  def held_card:
    "<article class=\"card accent-warning\">"
    + "<div class=\"card-head\"><h3>Held for your word</h3></div>"
    + "<ul>"
    + ([ $held[]
         | "<li><strong>\(.title | escn(140))</strong>"
           + (if .reason != null then "<span class=\"sub\">\(.reason | escn(160))</span>" else "" end)
           + "</li>" ] | join(""))
    + "</ul></article>";

  def chores_card($c):
    "<article class=\"card accent-warning\">"
    + "<div class=\"card-head\"><h3>\(($c.title // "Only you can do these") | md)</h3></div>"
    + "<ul>" + ([$c.item[] | "<li>\(. | md)</li>"] | join("")) + "</ul>"
    + ([$c.footnote[] | "<p class=\"fine\">\(. | md)</p>"] | join(""))
    + "</article>";

  def state_class($st):
    { working: "dot-working", parked: "dot-parked", blocked: "dot-blocked",
      paused: "dot-paused", done: "dot-done", failed: "dot-failed" }[$st] // "dot-unknown";

  def underway_card($t):
    "<article class=\"card\">"
    + "<div class=\"card-head\">"
    + "<span class=\"dot \(state_class($t.current_state.state))\" title=\"\($t.current_state.state | esc)\"></span>"
    + "<h3>\(($t.backlog.title // $t.id) | escn(90))</h3>"
    + "<span class=\"pill\">\(($t.project | basename) | esc)</span></div>"
    + "<p>\($t.current_state.state | esc)"
    + (if ($t.current_state.detail // "") != "" then " - \($t.current_state.detail | escn(160))" else "" end)
    + (if (($t.hints.open_decisions // []) | length) > 0 then " <strong>Holding for your call.</strong>" else "" end)
    + "</p>"
    + "<p class=\"fine age\">\(when($t.current_state.observed_at) | esc)"
    + (if ($t.current_state.freshness // "fresh") != "fresh" then " (stale read)" else "" end)
    + "</p></article>";

  def queued_item($r):
    # capture yields nothing when it does not match, which would drop the whole
    # row; collecting it keeps a gateless item rendering.
    ([($r.raw // "") | capture("hold-until: (?<d>[0-9-]+)") | .d] | .[0]) as $until
    | "<div class=\"row\(if $r.hold_reason != null or $until != null then " dim" else "" end)\">"
      + "<strong>\($r.title | escn(200))</strong>"
      + (if (($r.unresolved_blocker_ids // []) | length) > 0
         then "<span class=\"sub\">waits on \(($r.unresolved_blocker_ids | join(", ")) | esc)</span>"
         else "" end)
      + (if $until != null
         then "<span class=\"sub\">held until \($until | esc)</span>"
         else "" end)
      + (if $r.hold_reason != null
         then "<span class=\"sub\">\($r.hold_reason | escn(120))</span>"
         else "" end)
      + "</div>";

  def landed_item($r):
    "<div class=\"row\"><strong>\($r.title | escn(140))</strong>"
    + (if $r.home_id != null then " <span class=\"pill\">\($r.home_id | esc)</span>" else "" end)
    + (if $r.pr_url != null
       then "<span class=\"sub\"><a href=\"\($r.pr_url | esc)\">\($r.pr_url | esc)</a></span>"
       elif $r.report_path != null
       then "<span class=\"sub\">findings recorded: \($r.report_path | esc)</span>"
       else "" end)
    + (if ($r.completion.verb // null) != null
       then "<span class=\"sub\">\($r.completion.verb | esc)\(if $r.completion.date != null then " " + ($r.completion.date | esc) else "" end)</span>"
       else "" end)
    + "</div>";

# --- page -------------------------------------------------------------------

  [ $records[] | select(.state == "queued")
    | select((.captain_actionable == true or .hold_kind == "captain") | not) ] as $queued

# The two landed sources arrive ordered differently - the main backlog in file
# order, a delegated home already newest-first - so the union is put on one
# deterministic key before it is bounded. Otherwise the bound is a cut through
# file order and a recent delegated landing falls past it.
| ([ $records[] | select(.state == "done") ]
   + [ $s.secondmate_landed.records[]? ]
   | sort_by([((.completion.date // "") | tostring), ((.id // "") | tostring)])
   | reverse) as $landed_all
| ($landed_all[0:$landed]) as $landed_shown

# The Waiting-on-you column, cards and count from one list. The count is every
# entry actually waiting, not every card: a card listing five pull requests is
# five things to do, the same as five chores. The empty state is read off the
# rendered cards, so it cannot claim nothing is waiting while a card sits under
# it.
| ( [ $authored[] | { html: authored_card(.), n: 1 } ]
  + [ $unelaborated[] | { html: unelaborated_card(.), n: 1 } ]
  + (if ($prs | length) > 0 then [ { html: pr_card, n: ($prs | length) } ] else [] end)
  + (if ($held | length) > 0 then [ { html: held_card, n: ($held | length) } ] else [] end)
  + (if ($unread_homes | length) > 0
     then [ { html: unread_homes_card, n: ($unread_homes | length) } ] else [] end)
  + [ $chores[] | { html: chores_card(.), n: (.item | length) } ] ) as $waiting
| ($waiting | map(.html) | join("")) as $waiting_html
| ($waiting | map(.n) | add // 0) as $waiting_count

| "<!doctype html>
<html lang=\"en\">
<head>
<meta charset=\"utf-8\">
<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">
<title>\($title | esc)</title>
<style>
*,*::before,*::after{box-sizing:border-box}
:root{
  --bg:#eef1f6;--surface:#fff;--ink:#182030;--ink-soft:#333c4d;--muted:#5c6577;--line:#dde2ea;
  --primary:#4553c8;--primary-soft:#eceefb;--warning:#9a6510;--warning-soft:#fdf3e2;
  --info:#0d6f84;--info-soft:#e6f3f6;--error:#b02a1f;--ok:#2c7a4f;--shadow:0 1px 2px rgba(20,26,40,.08),0 1px 8px rgba(20,26,40,.05);
}
@media (prefers-color-scheme:dark){
  :root{
    --bg:#12161f;--surface:#1b212d;--ink:#e6e9f0;--ink-soft:#c8cedb;--muted:#9aa3b4;--line:#2a3140;
    --primary:#8d9bff;--primary-soft:#232a49;--warning:#e0a95c;--warning-soft:#2e2718;
    --info:#6fc7d8;--info-soft:#162b31;--error:#f08b80;--ok:#79c79b;--shadow:none;
  }
}
html{-webkit-text-size-adjust:100%}
body{margin:0;background:var(--bg);color:var(--ink);
  font:15px/1.5 ui-sans-serif,system-ui,-apple-system,\"Segoe UI\",Roboto,Helvetica,Arial,sans-serif}
a{color:var(--primary)}
code{font:12.5px/1.45 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;
  background:var(--primary-soft);padding:.1em .35em;border-radius:4px;overflow-wrap:anywhere}
header{position:sticky;top:0;z-index:20;background:var(--surface);border-bottom:1px solid var(--line)}
.bar{max-width:1600px;margin:0 auto;padding:12px 20px;display:flex;flex-wrap:wrap;align-items:center;gap:12px}
.bar h1{margin:0;font-size:17px;font-weight:600;line-height:1.2}
.bar .meta{margin:2px 0 0;font-size:12px;color:var(--muted)}
.age{font-variant-numeric:tabular-nums}
.grow{flex:1;min-width:0}
#pending{font-size:12px;color:var(--muted)}
button{font:inherit;font-size:13px;font-weight:600;padding:7px 14px;border-radius:7px;border:1px solid transparent;
  background:var(--primary);color:#fff;cursor:pointer}
button[disabled]{opacity:.45;cursor:default}
main{max-width:1600px;margin:0 auto;padding:20px;display:grid;gap:20px}
@media (min-width:1080px){main{grid-template-columns:1.5fr 1fr 1fr}}
section{display:flex;flex-direction:column;gap:12px;min-width:0}
h2{margin:0;font-size:12px;font-weight:600;letter-spacing:.08em;text-transform:uppercase;color:var(--muted)}
.head{display:flex;align-items:center;gap:8px;flex-wrap:wrap}
.card{background:var(--surface);border-radius:10px;box-shadow:var(--shadow);padding:16px;
  display:flex;flex-direction:column;gap:10px;min-width:0;border:1px solid var(--line)}
.accent-primary{border-left:4px solid var(--primary)}
.accent-warning{border-left:4px solid var(--warning)}
.accent-info{border-left:4px solid var(--info)}
.card-head{display:flex;align-items:flex-start;gap:8px}
.card h3{margin:0;font-size:14px;font-weight:600;flex:1;min-width:0;overflow-wrap:anywhere}
.card p{margin:0;font-size:14px;color:var(--ink-soft);overflow-wrap:anywhere}
.card ul{margin:0;padding-left:18px;display:flex;flex-direction:column;gap:8px;
  font-size:14px;color:var(--ink-soft)}
.card li{overflow-wrap:anywhere}
.card p.fine,p.fine{font-size:12px;color:var(--muted)}
.card p.callout,p.callout{font-size:13px;background:var(--warning-soft);color:var(--warning);
  padding:8px 10px;border-radius:6px}
.pill{flex:none;font-size:11px;padding:2px 8px;border-radius:999px;background:var(--line);color:var(--muted);white-space:nowrap}
.pill-primary{background:var(--primary-soft);color:var(--primary)}
.count{background:var(--primary);color:#fff}
.dot{flex:none;width:9px;height:9px;border-radius:50%;margin-top:5px;background:var(--muted)}
.dot-working{background:var(--primary)}.dot-parked{background:var(--warning)}
.dot-blocked{background:var(--error)}.dot-paused{background:var(--info)}
.dot-done{background:var(--ok)}.dot-failed{background:var(--error)}
.opts{display:flex;flex-direction:column;gap:6px}
.opt{position:relative;display:block;border:1px solid var(--line);border-radius:7px;
  padding:9px 11px;font-size:13.5px;cursor:pointer;overflow-wrap:anywhere}
.opt input{position:absolute;opacity:0;pointer-events:none}
.opt:hover{border-color:var(--primary)}
.opt.picked{border-color:var(--primary);box-shadow:0 0 0 1px var(--primary);background:var(--primary-soft)}
.rows{background:var(--surface);border:1px solid var(--line);border-radius:10px;box-shadow:var(--shadow);
  padding:16px;display:flex;flex-direction:column;gap:12px;font-size:14px;min-width:0}
.row{display:flex;flex-direction:column;gap:2px;overflow-wrap:anywhere}
.row.dim{opacity:.6}
.sub{font-size:12px;color:var(--muted)}
.empty{font-size:13px;color:var(--muted)}
.stale .meta{color:var(--warning);font-weight:600}
.expired .meta{color:var(--error);font-weight:600}
</style>
</head>
<body>
<header id=\"top\">
  <div class=\"bar\">
    <div class=\"grow\">
      <h1>\($title | esc)</h1>
      <p class=\"meta\">as of <span class=\"age\">\($s.generated | hhmm)</span> &middot;
        <span class=\"age\" id=\"age\">just now</span> - a snapshot, not a live feed</p>
    </div>
    <div id=\"pending\"></div>
    <button id=\"send\" disabled>Send answers</button>
  </div>
</header>

<main>
  <section>
    <div class=\"head\"><h2>Waiting on you</h2>" +
    (if $waiting_count > 0
     then "<span class=\"pill count\">\($waiting_count) \(if $waiting_count == 1 then "item" else "items" end)</span>"
     else "" end) + "</div>" +
    (if ($waiting | length) == 0
     then "<p class=\"empty\">Nothing is waiting on you.</p>" else "" end) +
    $waiting_html +
"  </section>

  <section>
    <h2>Under way</h2>" +
    (if ($work | length) == 0 then "<p class=\"empty\">Nothing under way.</p>" else "" end) +
    ([$work[] | underway_card(.)] | join("")) +
"  </section>

  <section>
    <h2>Queued</h2>" +
    (if ($queued | length) == 0
     then "<p class=\"empty\">Nothing queued.</p>"
     else "<div class=\"rows\">" + ([$queued[] | queued_item(.)] | join("")) + "</div>" end) +
"    <h2>Landed</h2>" +
    (if ($landed_shown | length) == 0
     then (if ($landed_all | length) == 0
           then "<p class=\"empty\">Nothing landed yet.</p>"
           else "<p class=\"empty\">\($landed_all | length) landings, none shown at this setting.</p>" end)
     else "<div class=\"rows\">" + ([$landed_shown[] | landed_item(.)] | join(""))
          + (if ($landed_all | length) > ($landed_shown | length)
             then "<p class=\"fine\">\(($landed_all | length) - ($landed_shown | length)) older landings not shown.</p>"
             else "" end)
          + "</div>" end) +
"  </section>
</main>

<script>
(function () {
  var generated = \($gen_epoch) * 1000;
  var staleMins = \($stale);
  var answers = {};
  var sendBtn = document.getElementById('send');
  var pending = document.getElementById('pending');
  var age = document.getElementById('age');
  var hdr = document.getElementById('top');

  function tick() {
    var mins = Math.floor((Date.now() - generated) / 60000);
    age.textContent = mins < 1 ? 'just now'
      : mins === 1 ? '1 minute old'
      : mins < 90 ? mins + ' minutes old'
      : Math.round(mins / 60) + ' hours old';
    hdr.classList.toggle('stale', mins >= staleMins && mins < staleMins * 2);
    hdr.classList.toggle('expired', mins >= staleMins * 2);
    if (mins >= staleMins * 2) {
      age.textContent += ' - too old to trust, ask for a fresh board';
    } else if (mins >= staleMins) {
      age.textContent += ' - going stale';
    }
  }
  tick();
  setInterval(tick, 20000);

  function refresh() {
    var n = Object.keys(answers).length;
    sendBtn.disabled = n === 0;
    sendBtn.textContent = 'Send answers';
    pending.textContent = n === 0 ? '' : (n === 1 ? '1 answer ready' : n + ' answers ready');
  }

  Array.prototype.forEach.call(document.querySelectorAll('.opt input[type=radio]'), function (input) {
    input.addEventListener('change', function () {
      var label = input.closest('.opt');
      Array.prototype.forEach.call(
        document.querySelectorAll('.opt input[name=\"' + input.name + '\"]'),
        function (sib) { sib.closest('.opt').classList.remove('picked'); });
      label.classList.add('picked');
      answers[input.name] = {
        question: input.getAttribute('data-question') || input.name,
        binds: input.getAttribute('data-binds') || null,
        answer: input.value
      };
      refresh();
    });
  });

  sendBtn.addEventListener('click', function () {
    var keys = Object.keys(answers);
    if (!keys.length) return;
    // One answer per line: a separator an answer can contain would make the
    // prompt ambiguous, and an ambiguous answer is worse than none.
    var lines = keys.map(function (k) {
      var a = answers[k];
      return k + (a.binds ? ' [' + a.binds + ']' : '') + ' (' + a.question + '): ' + a.answer;
    });
    var text = lines.join('\\n');
    var payload = { tag: 'board-answers', text: text, data: { answers: JSON.parse(JSON.stringify(answers)) } };
    if (window.lavish && typeof window.lavish.queuePrompt === 'function') {
      window.lavish.queuePrompt('Answers from the board:\\n' + text, payload);
      window.lavish.sendQueuedPrompts();
      pending.textContent = 'on its way';
    } else {
      pending.textContent = 'no review session attached - answers copied instead';
      if (navigator.clipboard) { navigator.clipboard.writeText(text).catch(function () {}); }
      return;
    }
    keys.forEach(function (k) { delete answers[k]; });
    Array.prototype.forEach.call(document.querySelectorAll('.opt input[type=radio]:checked'), function (i) {
      i.checked = false;
      i.closest('.opt').classList.remove('picked');
    });
    Array.prototype.forEach.call(document.querySelectorAll('.opt.picked'), function (l) { l.classList.remove('picked'); });
    sendBtn.disabled = true;
    sendBtn.textContent = 'Sent - ready for more';
  });

  refresh();
})();
</script>
</body>
</html>
"
JQ_RENDER
)

HTML=$(printf '%s' "$SNAPSHOT" | jq -r \
  --argjson cards "$CARDS_JSON" \
  --arg title "$TITLE" \
  --argjson landed "$LANDED" \
  --argjson stale "$STALE_MINS" \
  --arg home "$REDACT_HOME" \
  --arg fmhome "$SNAPSHOT_HOME" \
  --argjson mates "$MATE_HOMES" \
  "$RENDER") || die "rendering the board failed"

# --- write ------------------------------------------------------------------

OUT_DIR=$(dirname "$OUT")
mkdir -p "$OUT_DIR" || die "cannot create the artifact directory: $OUT_DIR"

TMP="$OUT.tmp.$$"
printf '%s\n' "$HTML" > "$TMP" || { rm -f "$TMP"; die "cannot write: $TMP"; }

# The last guard on the leak boundary: redaction runs per field, so a field that
# escaped it must never reach the operator's screen or a shared link. Every home
# the render touched is checked, not just the account home: FM_HOME can sit
# outside it, and a delegated home can sit outside both.
while IFS= read -r guarded; do
  [ -n "$guarded" ] || continue
  if grep -qF -- "$guarded" "$TMP"; then
    rm -f "$TMP"
    die "refusing to write the board: a home path survived redaction"
  fi
done <<EOF
$REDACT_HOME
$SNAPSHOT_HOME
$(printf '%s' "$MATE_HOMES" | jq -r '.[]')
EOF

mv -f "$TMP" "$OUT" || { rm -f "$TMP"; die "cannot write: $OUT"; }
printf '%s\n' "$OUT"
