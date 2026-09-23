#!/usr/bin/env bash
# fm-dispatch-replay.sh - calibrate typed dispatch resolution against known
# cases: replay labeled briefs through bin/fm-dispatch-resolve.sh, and score
# recorded rule answers under the clear gate.
#
# Usage:
#   fm-dispatch-replay.sh run --cases <file> --out <jsonl> --max-calls <n>
#       [--rules <crew-dispatch.json>]
#   fm-dispatch-replay.sh score [--margin <t>[,<t>...]] [--rows] <jsonl>...
#
# run: one bin/fm-dispatch-resolve.sh call per case, in file order, stopping
#   before the call that would exceed --max-calls, and appends one JSON line per
#   call to --out: {case, brief, project, expected, status, rule, confidence,
#   probabilities, reason}. Every call spends one live Jev request under the
#   resolver's own opt-in gate and settings; the resolver's shadow log is
#   forced off so a replay never writes $FM_HOME/state/jev-dispatch-shadow.jsonl.
#   --rules replays a candidate rules file without touching the home's
#   config/crew-dispatch.json (it becomes the only file in a private
#   FM_CONFIG_OVERRIDE directory). Before the first call, --out is append-opened
#   and must not resolve to the cases file, candidate rules file, or any case
#   brief; resolver configuration errors or an opt-out stop the run with exit
#   2 rather than emitting a row. Screen briefs before replaying them: the
#   resolver sends the brief text, so never list a brief that carries secrets
#   or private personal data.
#   Cases file: one case per line, tab-separated
#     <case-id> <brief-path> <project or -> <expected rules, |-separated, or ->
#   Blank lines and lines starting with # are skipped. A relative brief path
#   resolves against the cases file's directory.
#
# score: reads JSON lines that carry a rule-answer `probabilities` object -
#   the resolver's shadow log and `run` output both qualify - and, for each
#   threshold, applies the resolver's clear gate (see docs/configuration.md
#   "Typed dispatch resolution"), and compares it with the former fixed 0.6
#   derived-confidence gate. Rows with an `expected` label also count
#   `wrong`: rows that pass the gate with a pick outside the label. The pick
#   is the row's recorded `rule` (the rule the resolver answered), or the
#   most probable option when a row records none. The
#   margin arithmetic is bin/fm-jev-lib.sh's jev_choice_top2, the same
#   definition the resolver gates on. Default threshold: the resolver's
#   effective FM_JEV_DISPATCH_MARGIN. --rows prints one line per row.
#   Rows without a probabilities object (error outcomes) are counted as
#   skipped. score makes no network call.
#
# Output (stdout, TOON-style):
#   run:   replay-run: calls=<n> written=<n> stopped=<budget|none>
#   score: replay-score: rows=<n> labeled=<n> skipped=<n>
#            gate: confidence>=0.6 ambiguous=<n> pass=<n> wrong=<n>
#            gate: margin>=<t> ambiguous=<n> pass=<n> wrong=<n>
#          --rows adds per row:
#            row: <case> first=<recorded rule or argmax> top=<most probable> second=<runner-up> margin=<top gap> confidence=<c>
#              expected=<labels|-> margin-gate@<t>=<pass|ambiguous> ... verdict@<t>=<ok|wrong|-> ...
# Exit: 0 on success, 2 on usage error, unreadable input, or missing jq.
# docs/configuration.md "Typed dispatch resolution" owns the calibration
# contract this tool supports.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
RESOLVER="$SCRIPT_DIR/fm-dispatch-resolve.sh"
REPLAY_CFG_DIR=''

replay_cleanup() {
  [ -n "$REPLAY_CFG_DIR" ] && rm -rf -- "$REPLAY_CFG_DIR"
}

# shellcheck source=bin/fm-env-lib.sh
. "$SCRIPT_DIR/fm-env-lib.sh"
# shellcheck source=bin/fm-jev-lib.sh
. "$SCRIPT_DIR/fm-jev-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 2; }
usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

command -v jq >/dev/null 2>&1 || die "jq required"

replay_default_margin() {
  local v=${FM_JEV_DISPATCH_MARGIN:-}
  [ -n "$v" ] || v=$(fmx_env_get FM_JEV_DISPATCH_MARGIN "$FM_HOME/.env")
  [ -n "$v" ] || v=$(awk -F= '/^DEFAULT_MARGIN=/ { print $2; exit }' "$RESOLVER")
  printf '%s' "$v"
}

replay_canonical_path() {
  local path=$1 dir base target hops=0
  case "$path" in /*) ;; *) path="$(pwd -P)/$path" ;; esac
  dir=$(CDPATH='' cd "$(dirname "$path")" 2>/dev/null && pwd -P) || return 1
  base=$(basename "$path")
  while [ -L "$dir/$base" ]; do
    [ "$hops" -lt 64 ] || return 1
    target=$(readlink "$dir/$base" 2>/dev/null) || return 1
    case "$target" in
      /*) path=$target ;;
      *) path="$dir/$target" ;;
    esac
    dir=$(CDPATH='' cd "$(dirname "$path")" 2>/dev/null && pwd -P) || return 1
    base=$(basename "$path")
    hops=$((hops + 1))
  done
  printf '%s/%s\n' "$dir" "$base"
}

replay_same_file() {
  [ "$1" = "$2" ] || [ "$1" -ef "$2" ]
}

replay_run() {
  local cases='' out='' max='' rules='' cases_dir cases_real out_real rules_real brief_real calls=0 written=0 stopped=none
  local id brief project expected text line status rule confidence probs reason resolver_stderr resolver_status case_index
  local -a case_ids=() case_briefs=() case_projects=() case_expected=() case_brief_reals=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --cases) [ $# -ge 2 ] || die "--cases needs a value"; cases=$2; shift 2 ;;
      --out) [ $# -ge 2 ] || die "--out needs a value"; out=$2; shift 2 ;;
      --max-calls) [ $# -ge 2 ] || die "--max-calls needs a value"; max=$2; shift 2 ;;
      --rules) [ $# -ge 2 ] || die "--rules needs a value"; rules=$2; shift 2 ;;
      *) die "unknown run argument: $1" ;;
    esac
  done
  [ -n "$cases" ] || die "run needs --cases"
  [ -n "$out" ] || die "run needs --out"
  case "$max" in ''|*[!0-9]*) die "run needs --max-calls <non-negative integer>" ;; esac
  [ -r "$cases" ] || die "cases file not readable: $cases"
  cases_dir=$(CDPATH='' cd "$(dirname "$cases")" 2>/dev/null && pwd -P) || die "cases file not readable: $cases"
  cases_real=$(replay_canonical_path "$cases") || die "cases file not readable: $cases"
  rules_real=''
  if [ -n "$rules" ]; then
    [ -r "$rules" ] || die "rules file not readable: $rules"
    rules_real=$(replay_canonical_path "$rules") || die "rules file not readable: $rules"
  fi
  while IFS=$'\t' read -r id brief project expected || [ -n "$id" ]; do
    case "$id" in ''|'#'*) continue ;; esac
    [ -n "$brief" ] || die "case $id has no brief path"
    case "$brief" in /*) ;; *) brief="$cases_dir/$brief" ;; esac
    [ -r "$brief" ] || die "case $id brief not readable: $brief"
    brief_real=$(replay_canonical_path "$brief") || die "case $id brief not readable: $brief"
    [ "$project" = - ] && project=''
    [ "${expected:--}" = - ] && expected=''
    case_ids+=("$id")
    case_briefs+=("$brief")
    case_projects+=("$project")
    case_expected+=("$expected")
    case_brief_reals+=("$brief_real")
  done < "$cases"
  out_real=$(replay_canonical_path "$out") || die "could not append to $out"
  if replay_same_file "$out_real" "$cases_real"; then
    die "--out conflicts with cases file: $cases"
  fi
  if [ -n "$rules_real" ] && replay_same_file "$out_real" "$rules_real"; then
    die "--out conflicts with --rules file: $rules"
  fi
  for ((case_index = 0; case_index < ${#case_ids[@]}; case_index++)); do
    if replay_same_file "$out_real" "${case_brief_reals[$case_index]}"; then
      die "--out conflicts with brief for case ${case_ids[$case_index]}: ${case_briefs[$case_index]}"
    fi
  done
  : >> "$out" || die "could not append to $out"
  if [ -n "$rules" ]; then
    REPLAY_CFG_DIR=$(mktemp -d) || die "mktemp failed"
    trap replay_cleanup EXIT
    cp "$rules" "$REPLAY_CFG_DIR/crew-dispatch.json" || die "could not stage rules file"
  fi
  for ((case_index = 0; case_index < ${#case_ids[@]}; case_index++)); do
    id=${case_ids[$case_index]}
    brief=${case_briefs[$case_index]}
    project=${case_projects[$case_index]}
    expected=${case_expected[$case_index]}
    if [ "$calls" -ge "$max" ]; then
      stopped=budget
      break
    fi
    calls=$((calls + 1))
    resolver_stderr=$(mktemp) || die "mktemp failed"
    if [ -n "$REPLAY_CFG_DIR" ]; then
      text=$(FM_HOME="$FM_HOME" FM_JEV_DISPATCH_SHADOW=0 FM_CONFIG_OVERRIDE="$REPLAY_CFG_DIR" "$RESOLVER" "$brief" --project "$project" 2>"$resolver_stderr")
      resolver_status=$?
    else
      text=$(FM_HOME="$FM_HOME" FM_JEV_DISPATCH_SHADOW=0 "$RESOLVER" "$brief" --project "$project" 2>"$resolver_stderr")
      resolver_status=$?
    fi
    if [ "$resolver_status" -ne 0 ] || grep -Fq 'dispatch-resolve: off' "$resolver_stderr"; then
      cat "$resolver_stderr" >&2
      rm -f "$resolver_stderr"
      exit 2
    fi
    rm -f "$resolver_stderr"
    status=$(awk '/^  status: / { print $2; exit }' <<<"$text")
    rule=$(awk '/^  rule: / { print $2; exit }' <<<"$text")
    confidence=$(awk '/^  rule: / { print $NF; exit }' <<<"$text")
    reason=$(awk '/^  reason: / { sub(/^  reason: /, ""); print; exit }' <<<"$text")
    line=$(awk '/^  probabilities: / { sub(/^  probabilities: /, ""); print; exit }' <<<"$text")
    probs=$(printf '%s' "$line" | jq -Rc 'split(" ") | map(select(length > 0) | split("=") | {key: .[0], value: (.[1] | tonumber? // null)}) | if length > 0 then from_entries else null end' 2>/dev/null) || probs=null
    [ -n "$probs" ] || probs=null
    jq -nc --arg case "$id" --arg brief "$brief" --arg project "$project" --arg expected "$expected" \
      --arg status "${status:-error}" --arg rule "$rule" --arg confidence "$confidence" \
      --argjson probabilities "$probs" --arg reason "$reason" '{
        case: $case, brief: $brief, project: $project,
        expected: (if $expected == "" then null else ($expected | split("|")) end),
        status: $status, rule: (if $rule == "" then null else $rule end),
        confidence: ($confidence | tonumber? // null),
        probabilities: $probabilities,
        reason: (if $reason == "" then null else $reason end)
      }' >> "$out" || die "could not append to $out"
    written=$((written + 1))
    printf 'case %s: %s %s\n' "$id" "${status:-error}" "${rule:--}" >&2
  done
  printf 'replay-run: calls=%s written=%s stopped=%s\n' "$calls" "$written" "$stopped"
}

replay_score() {
  local margins='' rows=0 files=() f normalized_margins='' margin
  local -a threshold_values=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --margin) [ $# -ge 2 ] || die "--margin needs a value"; margins=$2; shift 2 ;;
      --rows) rows=1; shift ;;
      -*) die "unknown score flag: $1" ;;
      *) files+=("$1"); shift ;;
    esac
  done
  [ "${#files[@]}" -gt 0 ] || die "score needs at least one JSONL file"
  for f in "${files[@]}"; do
    [ -r "$f" ] || die "input not readable: $f"
  done
  [ -n "$margins" ] || margins=$(replay_default_margin)
  printf '%s' "$margins" | awk -F, '{ for (i = 1; i <= NF; i++) if (!($i ~ /^(0|1)?(\.[0-9]+)?$/ && $i ~ /[0-9]/ && $i + 0 > 0 && $i + 0 <= 1)) exit 1 }' \
    || die "--margin needs comma-separated numbers in (0, 1]"
  IFS=, read -r -a threshold_values <<< "$margins"
  for margin in "${threshold_values[@]}"; do
    case "$margin" in .*) margin="0$margin" ;; esac
    normalized_margins="${normalized_margins:+$normalized_margins,}$margin"
  done
  margins=$normalized_margins
  cat "${files[@]}" | jq -rs --arg margins "$margins" --argjson rows "$rows" "$FM_JEV_CHOICE_TOP2_JQ"'
    def valid: (.probabilities | type) == "object" and (.probabilities | length) > 0
      and all(.probabilities[]; type == "number");
    # The 1e-9 tolerance matches the resolver: two-decimal gaps such as 0.7 - 0.3 compute just below the threshold in binary floating point.
    def gate_pass($row; $threshold): $row.first == $row.top.first and (($row.top.raw_margin + 1e-9) >= $threshold);
    def verdict($row; $pass):
      if ($row.expected | type) != "array" then "-"
      elif ($pass | not) then "-"
      elif ($row.expected | index($row.first)) != null then "ok"
      else "wrong" end;
    def gate_field($row; $threshold):
      "margin-gate@\($threshold)=" + (if gate_pass($row; $threshold) then "pass" else "ambiguous" end);
    def verdict_field($row; $threshold):
      "verdict@\($threshold)=\(verdict($row; gate_pass($row; $threshold)))";
    def tally($rs; $label; pass_fn):
      ($rs | map(. as $r | $r + {pass: ($r | pass_fn)})) as $g
      | "  gate: \($label) ambiguous=\([$g[] | select(.pass | not)] | length) pass=\([$g[] | select(.pass)] | length) wrong=\([$g[] | select(verdict(.; .pass) == "wrong")] | length)";
    (map(select(valid)) | to_entries | map((.value.probabilities | jev_choice_top2) as $top
      | .value + {top: $top, first: (if (.value.rule | type) == "string" then .value.rule else $top.first end), idx: (.key + 1)})) as $rs
    | ($margins | split(",") | map(tonumber)) as $ts
    | "replay-score: rows=\($rs | length) labeled=\([$rs[] | select((.expected | type) == "array")] | length) skipped=\(length - ($rs | length))",
      tally($rs; "confidence>=0.6"; (.confidence // 0) >= 0.6),
      ($ts[] as $t | tally($rs; "margin>=\($t)"; gate_pass(.; $t))),
      (if $rows == 1 then
         ($rs[] | . as $r
          | ($ts | map(gate_field($r; .)) | join(" ")) as $gates
          | ($ts | map(verdict_field($r; .)) | join(" ")) as $verdicts
          | [
              "  row: " + ($r.case // ("#" + ($r.idx | tostring)))
                + " first=" + $r.first
                + " top=" + $r.top.first
                + " second=" + ($r.top.second // "-")
                + " margin=" + ($r.top.margin | tostring)
                + " confidence=" + (($r.confidence // "-") | tostring)
                + " expected=" + (if ($r.expected | type) == "array" then ($r.expected | join("|")) else "-" end),
              $gates,
              $verdicts
            ] | join(" "))
       else empty end)
  ' || die "could not score input (not JSON lines?)"
}

[ $# -gt 0 ] || { usage; exit 2; }
case "$1" in
  run) shift; replay_run "$@" ;;
  score) shift; replay_score "$@" ;;
  -h|--help) usage ;;
  *) die "unknown command: $1 (see --help)" ;;
esac
