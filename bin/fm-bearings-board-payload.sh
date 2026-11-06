#!/usr/bin/env bash
# fm-bearings-board-payload.sh - build the /bearings lavish board payload.
#
# The board has one shape every session because this script, not the invoking
# agent, maps the fleet snapshot onto the fm-bearings-board.v1 payload that
# bin/fm-bearings-board.sh `build` validates and renders. The same snapshot
# always yields the same payload; the agent's only optional input is a copy
# overlay carrying short authored copy.
#
# Usage:
#   fm-bearings-board-payload.sh [--snapshot <file|->] [--copy <file>] [--include-prs]
#
# The payload goes to stdout. With no --snapshot the script runs
# `fm-bearings-snapshot.sh --json` itself (--include-prs is passed through);
# with --snapshot it reads that JSON from the file or stdin instead.
#
# Mapping (snapshot field -> board section):
#   decisions_open  -> captains_call: one `decision` card per captain-held task id,
#                      titled from the row's `title`, `about` from its `reason`,
#                      `pr_url` and `repo` from the PR the task recorded, and a
#                      freeform answer box (a card with no authored options). The
#                      snapshot already buckets holds, so every row is a live call.
#   in_flight       -> underway: every row except state `done`, in snapshot order,
#                      with the projected `name`.
#   landed          -> landed: every row; `pr_url` and `repo` come from the
#                      artifact or recorded PR when it is one.
#   gates           -> charted: one row per gate; `(main-inventory)` and
#                      `(return-catchup)` become warning rows (kind warning, never
#                      dispatchable), and a gate with neither blocker nor hold
#                      reason is the only dispatchable row.
#   secondmates, secondmate_reconcile
#                   -> charted warning rows for a home whose books disagree
#                      (`reconcile-<id>`) or whose state is unavailable
#                      (`unavailable-<id>`).
#   omitted         -> charted_more, from the `gates showing N of M` surface.
#
# Copy overlay (--copy): a JSON object whose optional maps are keyed by the row
# key or id they refine, so a missing entry leaves the deterministic default.
#   captains_call  {"<key>": {title, about, decide, detail, options, recommend_value,
#                   type, close, risk, pr_url, subject, freeform_hint, allow_freeform,
#                   repo} | null}   (null drops the card)
#   captains_call_extra  [<call item>, ...]   merge and credential cards, appended
#   underway       {"<id>": {repo}}
#   landed         {"<id>": {repo, pr_url, subject}}
#   charted        {"<id>": {title, reason, repo, dispatchable, filed}}
# An unknown map or field is refused, so the payload shape cannot drift through
# the overlay. An entry whose key matches no row is reported on stderr and ignored.
# `dispatchable` is ignored on a warning row, and `reconcile` is never accepted as
# an option value (`build` injects it).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-bearings-board-payload: %s\n' "$*" >&2
  exit 1
}

SNAPSHOT=""
COPY=""
INCLUDE_PRS=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --snapshot) shift; [ "$#" -gt 0 ] || fail "--snapshot needs a file or -"; SNAPSHOT=$1 ;;
    --copy) shift; [ "$#" -gt 0 ] || fail "--copy needs a file"; COPY=$1 ;;
    --include-prs) INCLUDE_PRS=1 ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
  shift
done

command -v jq >/dev/null 2>&1 || fail "jq is required"

if [ -z "$SNAPSHOT" ]; then
  if [ "$INCLUDE_PRS" = 1 ]; then
    SNAP_JSON=$("$SCRIPT_DIR/fm-bearings-snapshot.sh" --json --include-prs) || fail "snapshot failed"
  else
    SNAP_JSON=$("$SCRIPT_DIR/fm-bearings-snapshot.sh" --json) || fail "snapshot failed"
  fi
elif [ "$SNAPSHOT" = - ]; then
  SNAP_JSON=$(cat)
else
  [ -r "$SNAPSHOT" ] || fail "cannot read snapshot: $SNAPSHOT"
  SNAP_JSON=$(cat "$SNAPSHOT")
fi

COPY_JSON='{}'
if [ -n "$COPY" ]; then
  [ -r "$COPY" ] || fail "cannot read copy overlay: $COPY"
  COPY_JSON=$(cat "$COPY")
fi

printf '%s\n' "$SNAP_JSON" | jq -e '.schema == "fm-bearings.v1"' >/dev/null 2>&1 \
  || fail "input is not an fm-bearings.v1 snapshot"
printf '%s\n' "$COPY_JSON" | jq -e 'type == "object"' >/dev/null 2>&1 \
  || fail "copy overlay is not a JSON object"

overlay_errors=$(printf '%s\n' "$COPY_JSON" | jq -r '
  { captains_call: ["title","about","decide","detail","options","recommend_value","type","close",
                    "risk","pr_url","subject","freeform_hint","allow_freeform","repo"],
    underway: ["repo"],
    landed: ["repo","pr_url","subject"],
    charted: ["title","reason","repo","dispatchable","filed"] } as $allowed
  | ( keys[] | select(. as $k | ["captains_call","captains_call_extra","underway","landed","charted"]
                              | index($k) | not) | "unknown section: \(.)" ),
    ( . as $c | $allowed | to_entries[] | .key as $sec | .value as $ok
      | ($c[$sec] // {}) | to_entries[] | select(.value != null) | .key as $id
      | .value | keys[] | select(. as $f | $ok | index($f) | not)
      | "\($sec).\($id) has unknown field: \(.)" ),
    ( (.captains_call // {}) | to_entries[] | select(.value != null) | .value.options[]?
      | select(.value == "reconcile") | "captains_call options may not author reconcile" ),
    ( (.captains_call_extra // [])[] | .options[]? | select(.value == "reconcile")
      | "captains_call_extra options may not author reconcile" )
' 2>&1) || fail "copy overlay is malformed: $overlay_errors"
[ -z "$overlay_errors" ] || fail "copy overlay refused: $(printf '%s' "$overlay_errors" | head -n1)"

jq -n --argjson snap "$SNAP_JSON" --argjson copy "$COPY_JSON" '
  def card_fields: ["title","about","decide","detail","options","recommend_value","type","close",
                    "risk","pr_url","subject","freeform_hint","allow_freeform","repo"];
  def underway_fields: ["repo"];
  def landed_fields: ["repo","pr_url","subject"];
  def charted_fields: ["title","reason","repo","dispatchable","filed"];

  def https_url: type == "string" and test("^https://[^[:space:]]+$");
  def repo_of_url:
    if https_url | not then null
    elif test("^https://[^/]+/[^/]+/[^/]+/(pull|issues)/") then
      capture("^https://[^/]+/[^/]+/(?<r>[^/]+)/(pull|issues)/").r
    elif test("^https://[^/]+/.+/[^/]+/-/") then
      capture("^https://[^/]+/.+/(?<r>[^/]+)/-/").r
    else null end;
  def nz($d): if . == null or . == "" or . == "-" then $d else . end;
  def pr_for($id; $contrib; $recorded):
    ( ([$contrib[] | select(.task == $id) | .url][0])
      // ([$recorded[] | select(.id == $id) | .url][0]) ) as $u
    | if ($u | https_url) then $u else null end;
  def overlay($section; $id; $allowed):
    (($copy[$section] // {})[$id] // {}) | with_entries(select(.key as $k | $allowed | index($k)));

  ($snap.contributions.captain // []) as $contrib
  | ($snap.recorded_prs // []) as $recorded
  | ($snap.in_flight // []) as $in_flight
  | ($snap.landed // []) as $landed_rows
  | (($snap.omitted // []) | map(.surface)) as $omitted

  | ( [ $snap.decisions_open[]? ]
      | reduce .[] as $d ([]; if (map(.key) | index($d.key)) then . else . + [$d] end)
      | map(
          . as $d
          | pr_for($d.id; $contrib; $recorded) as $pr
          | ( {
              key: $d.key,
              type: "decision",
              repo: ( ($pr | repo_of_url)
                      // ([$in_flight[] | select(.id == $d.id or .id == $d.key) | .repo][0])
                      // null ),
              title: (($d.title // $d.summary // $d.key) | nz($d.key)),
              options: [],
              allow_freeform: true,
              freeform_hint: "answer in your own words (say later to defer)"
            }
            + (if ($d.reason | nz(null)) != null then {about: $d.reason} else {} end)
            + (if $pr != null then {pr_url: $pr} else {} end) )
          + overlay("captains_call"; $d.key; card_fields)
          | . as $card
          | select((($copy.captains_call // {}) | has($d.key) | not)
                   or ($copy.captains_call[$d.key] != null))
          | $card )
    ) as $cards
  | ($cards + ($copy.captains_call_extra // [])) as $captains_call

  | ( [ $in_flight[] | select(.state != "done") | . as $r
        | { id, name: (.name | nz($r.id)), repo: (.repo // null),
            state: (.state | nz("unknown")), doing: (.doing | nz("-")),
            kind: (.kind | nz("task")) }
          + overlay("underway"; .id; underway_fields) ] ) as $underway

  | ( [ $landed_rows[]
        | . as $r
        | (if (.artifact | https_url) then .artifact else pr_for(.id; $contrib; $recorded) end) as $pr
        | { id, repo: ($pr | repo_of_url), what: (.what | nz($r.id)), owner: (.owner | nz("(main)")) }
          + (if $pr != null then {pr_url: $pr} else {} end)
          + overlay("landed"; .id; landed_fields) ] ) as $landed

  | ( [ $snap.gates[]?
        | . as $r | (.id | test("^\\(")) as $synthetic
        | { id: (.id | gsub("^\\(|\\)$"; "")),
            repo: null,
            title: (.title | nz($r.id)),
            reason: ($r.reason | nz("")),
            dispatchable: (($synthetic | not) and ($r.blocked_by | nz("")) == "" and ($r.reason | nz("")) == ""),
            filed: (.filed // null) }
          + (if $synthetic then {kind: "warning"} else {kind: "queued"} end)
        | if .kind == "warning" then .dispatchable = false else . end
        | . as $row
        | . + overlay("charted"; $row.id; charted_fields)
        | if .kind == "warning" then .dispatchable = false else . end
        | if .filed == null then del(.filed) else . end ] ) as $gate_rows

  | ( ($snap.secondmate_reconcile // [])
      | map(select(.kind != null) | {key: .id, value: .}) | from_entries ) as $mismatch
  | ( [ ($snap.secondmates // [])[]
        | . as $m
        | if $mismatch[$m.id] != null then
            { id: ("reconcile-" + $m.id), repo: null,
              title: ($m.id + " books disagree with its task records"),
              reason: ($mismatch[$m.id].kind + ": " + (($mismatch[$m.id].ids // []) | join(", "))),
              dispatchable: false, kind: "warning" }
          elif $m.state == "unknown" then
            { id: ("unavailable-" + ($m.id | gsub("[()]"; ""))), repo: null,
              title: ($m.id + " state unavailable"),
              reason: ($m.reason | nz("state unknown")),
              dispatchable: false, kind: "warning" }
          else empty end
        | . as $row | . + overlay("charted"; $row.id; charted_fields)
        | .dispatchable = false ] ) as $home_rows

  | ( [ $omitted[] | capture("^gates showing (?<n>[0-9]+) of (?<m>[0-9]+)$")? ]
      | (.[0] // null) ) as $gates_cut

  | ($gate_rows + $home_rows) as $charted

  | { schema: "fm-bearings-board.v1",
      home: $snap.home,
      generated: $snap.generated,
      prs_live: (($snap.prs // "") | startswith("checked")),
      captains_call: $captains_call,
      underway: $underway,
      landed: $landed,
      charted: $charted }
    + (if $gates_cut != null then {charted_more: (($gates_cut.m | tonumber) - ($gates_cut.n | tonumber))} else {} end)
' || fail "could not build the payload"
