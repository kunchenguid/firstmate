#!/usr/bin/env bash
# fm-doctor.sh - check that this firstmate home is set up and working. Read-only.
#
# Usage: fm-doctor.sh [--json] [--area <name>] [--network]
#
# WHAT IT IS. An on-demand aggregation and verdict layer over facts other
# scripts already own. It detects nothing itself: every check is either a line
# prefix bin/fm-bootstrap.sh prints, a bare bootstrap token, or a read-only
# owner verb (status or report). docs/doctor-checks.json is the inventory that
# says, per check, which owner fact to read and how to present it: area,
# severity, and a fix hint. Adding a check means adding one inventory entry; a
# new detection belongs in its owner, normally a bootstrap detect line, so every
# session start gets it too.
#
# READ-ONLY. The doctor never sweeps, repairs, writes state or config, or spawns
# anything. Bootstrap runs only with FM_BOOTSTRAP_DETECT_ONLY=1 (the inventory
# validation refuses a bootstrap source without it) and FM_BOOTSTRAP_NETWORK=skip,
# so no network step runs. Every other source must be a read-only owner verb.
# Sources the inventory marks "network": true run only under --network: a fresh
# bootstrap detect-only `only` phase, which is exactly the `gh auth status`
# probe, and the last bin/fm-startup-network.sh report, whose republished
# bootstrap lines answer the other network-phase checks without a network call.
# Every child runs under bin/fm-timeout-lib.sh's hard bound: the inventory's
# per-source or per-verb timeout, or FM_DOCTOR_TIMEOUT when that is a positive
# integer. Output carries owner lines only, never auth output or secrets.
#
# CHECK ORDER AND BUILT-IN CHECKS.
#   doctor/jq            jq is required; without it the doctor prints a plain
#                        fail and exits 1.
#   doctor/inventory     the inventory validates (version, areas, unique ids and
#                        prefixes, known areas and kinds, owner commands that
#                        exist under bin/, bootstrap sources in detect-only
#                        mode). An invalid inventory stops the run with exit 1.
#   doctor/<source>      each source that ran finished inside its bound with
#                        exit 0; stderr is attached as evidence.
#   doctor/unmapped-line every stdout line of a bootstrap source starts with a
#                        prefix or token the inventory maps; an unknown line
#                        fails, so a new prefix can never pass silently.
# Then every inventory check in inventory order:
#   line/token  status is the entry's severity (or the first matching rule) when
#               the source printed the prefix, ok when it finished without it,
#               and skip for a sweep-phase prefix that a detect-only run cannot
#               print, or for a network-phase check without --network. A "scan"
#               source (the network report) may also print lines the inventory
#               does not map; its optional "complete" ERE must match one line
#               before an absent prefix counts as ok.
#   verb        the first rule that matches decides: exit (exit status), match
#               (an ERE against any stdout or stderr line), or field+equals (a dotted JSON
#               path); otherwise the entry's default, or warn. A verb that hits
#               its bound is warn.
# Statuses: ok, warn, fail, info, skip. The verdict is fail when any check
# fails, warn when any warns, ok otherwise.
#
# OUTPUT. TOON by default (bin/fm-toon-lib.sh): home, verdict, summary, every
# check with one line of evidence, findings (the fix for each warn or fail), and
# help. --json prints the full model (schema fm-doctor.v1) with every evidence
# line per check. --area <name> runs only that area's checks; the built-in
# checks always run. --network adds the network sources above.
#
# EXIT. 0 when no check failed (warnings allowed); 1 when a check failed,
# including a doctor-internal failure; 2 for a usage error, including an
# unknown area.
#
# ENVIRONMENT. FM_HOME selects the home as for every firstmate script.
# FM_DOCTOR_INVENTORY names another inventory file (tests use it).
# FM_DOCTOR_TIMEOUT overrides every bound with one positive integer of seconds.
set -u

usage() {
  cat <<'EOF'
fm-doctor.sh - check that this firstmate home is set up and working. Read-only.

Usage: fm-doctor.sh [--json] [--area <name>] [--network]
  --json         full structured output (default is TOON)
  --area <name>  run one area from docs/doctor-checks.json
  --network      add a fresh GitHub auth probe and the last network report
Exit:  0 no check failed; 1 a check failed; 2 usage error.
Full contract: the header of bin/fm-doctor.sh.
EOF
}

case "${1:-}" in
  -h | --help)
    usage
    exit 0
    ;;
esac

FORMAT=toon
AREA=""
NETWORK=0
while [ $# -gt 0 ]; do
  case "$1" in
    --json) FORMAT=json ;;
    --network) NETWORK=1 ;;
    --area)
      [ $# -ge 2 ] && [ -n "$2" ] || { echo "fm-doctor.sh: --area needs a name" >&2; usage >&2; exit 2; }
      AREA=$2
      shift
      ;;
    --area=*)
      AREA=${1#--area=}
      [ -n "$AREA" ] || { echo "fm-doctor.sh: --area needs a name" >&2; usage >&2; exit 2; }
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "fm-doctor.sh: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Owners always come from this script's own code root, so FM_ROOT_OVERRIDE (which
# the children inherit unchanged) can never point the doctor at other scripts.
CODE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$CODE_ROOT}}"
export FM_HOME
INVENTORY=${FM_DOCTOR_INVENTORY:-$CODE_ROOT/docs/doctor-checks.json}

if ! command -v jq >/dev/null 2>&1; then
  if [ "$FORMAT" = json ]; then
    printf '{"schema":"fm-doctor.v1","verdict":"fail","checks":[{"id":"doctor/jq","area":"doctor","status":"fail","evidence":"jq not found on PATH","fix":"Install jq; the doctor needs it to read its inventory."}]}\n'
  else
    printf 'verdict: fail\nchecks[1]{id,status,evidence}:\n  doctor/jq,fail,jq not found on PATH\nfindings[1]{id,fix}:\n  doctor/jq,Install jq; the doctor needs it to read its inventory.\n'
  fi
  exit 1
fi

# shellcheck source=bin/fm-timeout-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-toon-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-toon-lib.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-doctor.XXXXXX") || { echo "fm-doctor.sh: cannot create a scratch directory" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT

# --- inventory validation ----------------------------------------------------
# Structure first, in jq; then every owner path the structure names must be an
# executable file under bin/ of the code root, which also keeps an edited
# inventory from naming anything outside firstmate's own scripts.
validate_inventory() {  # <inventory> <root> -> errors on stdout, one per line
  local inventory=$1 root=$2 path
  if ! jq -e 'type == "object"' "$inventory" >/dev/null 2>&1; then
    printf 'inventory %s is missing or is not a JSON object\n' "$inventory"
    return 0
  fi
  jq -r '
    def statuses: ["ok", "warn", "fail", "info"];
    def posint: type == "number" and . >= 1 and floor == .;
    def strs: type == "array" and length > 0 and all(.[]; type == "string" and length > 0);
    (.areas // []) as $areas
    | (.sources // {}) as $src
    | (if .version != 1 then "version must be 1" else empty end),
      (if (.areas | strs | not) then "areas must be a non-empty string array"
       elif (.areas | unique | length) != (.areas | length) then "areas must not repeat"
       else empty end),
      (if (.sources | type) != "object" then "sources must be an object"
       else ($src | to_entries[] | .key as $k | .value
         | (if (.command | strs | not) then "source \($k): command must be a non-empty string array" else empty end),
           (if ((.env // {}) | type) != "object" or any((.env // {})[]; type != "string") then "source \($k): env must map names to strings" else empty end),
           (if (.timeout | posint | not) then "source \($k): timeout must be a positive integer" else empty end),
           (if (.command[0]? == "bin/fm-bootstrap.sh") and (.env.FM_BOOTSTRAP_DETECT_ONLY? != "1") then "source \($k): bin/fm-bootstrap.sh must run with FM_BOOTSTRAP_DETECT_ONLY=1" else empty end),
           (if any(.network, .scan; . != null and type != "boolean") then "source \($k): network and scan must be booleans" else empty end),
           (if .complete != null and (.complete | type) != "string" then "source \($k): complete must be a string" else empty end))
       end),
      (if (.checks | type) != "array" or (.checks | length) == 0 then "checks must be a non-empty array"
       else
         (.checks | map(select(type == "object" and (.id | type) == "string")) | group_by(.id)[] | select(length > 1) | "duplicate check id \(.[0].id)"),
         (.checks | map(select(type == "object" and (.prefix | type) == "string")) | group_by(.prefix)[] | select(length > 1) | "prefix \(.[0].prefix) is mapped by more than one check"),
         (.checks[] | (if type == "object" then (.id // "<no id>") else "<not an object>" end) as $id
           | if type != "object" then "check \($id): must be an object" else
             (if (.id | type) != "string" or (.id | test("^[a-z0-9-]+/[a-z0-9-]+$") | not) then "check \($id): id must be <area>/<name>" else empty end),
             (.area as $a | if any($areas[]; . == $a) | not then "check \($id): unknown area \($a)" else empty end),
             (if (.id | type) == "string" and (.id | split("/")[0]) != .area then "check \($id): id must start with its area" else empty end),
             (if ((.fix | type) != "string") or (.fix | length) == 0 then "check \($id): fix must be a non-empty string" else empty end),
             (if .kind == "line" or .kind == "token" then
                (if (.prefix | type) != "string" or (.prefix | test("^[A-Z][A-Z0-9_]*$") | not) then "check \($id): prefix must be an upper-case token" else empty end),
                (if ([.phase] | inside(["local", "network", "sweep"]) | not) then "check \($id): phase must be local, network, or sweep" else empty end),
                (if ([.severity] | inside(statuses) | not) then "check \($id): severity must be one of \(statuses | join(", "))" else empty end),
                (if (.owner | type) != "string" then "check \($id): owner is missing" else empty end),
                (if .phase != "sweep" and (.source == null) then "check \($id): a local or network check needs a source" else empty end),
                (if .phase == "sweep" and (.source != null) then "check \($id): a sweep-phase check has no source" else empty end),
                (if .source != null and $src[.source?] != null and (.phase == "network") != ($src[.source].network == true) then "check \($id): phase must match the network flag of its source" else empty end),
                (if .source != null and ($src[.source?] == null) then "check \($id): unknown source \(.source)" else empty end),
                (if .rules != null and ((.rules | type) != "array" or any(.rules[]; (.match | type) != "string" or ([.status] | inside(statuses) | not))) then "check \($id): line rules need match and status" else empty end)
              elif .kind == "verb" then
                (if (.command | strs | not) then "check \($id): command must be a non-empty string array" else empty end),
                (if (.timeout | posint | not) then "check \($id): timeout must be a positive integer" else empty end),
                (if ([.parse] | inside(["text", "json"]) | not) then "check \($id): parse must be text or json" else empty end),
                (if .default != null and ([.default] | inside(statuses) | not) then "check \($id): default must be one of \(statuses | join(", "))" else empty end),
                (if (.rules | type) != "array" or (.rules | length) == 0 then "check \($id): verb rules must be a non-empty array"
                 else (.rules[] | select(
                   ([.status] | inside(statuses) | not)
                   or ([has("match"), has("exit"), has("field")] | map(select(.)) | length) != 1
                   or (has("match") and (.match | type) != "string")
                   or (has("exit") and (.exit | type) != "number")
                   or (has("field") and ((.field | type) != "string" or (.equals | type) != "string")))
                   | "check \($id): each verb rule needs a status and exactly one of match, exit, or field+equals") end)
              else "check \($id): kind must be line, token, or verb" end)
           end)
       end)
  ' "$inventory" 2>/dev/null || printf 'inventory %s could not be validated\n' "$inventory"
  jq -r '
    [ (.sources // {} | to_entries[] | .value.command[0]?),
      (.checks // [] | .[]? | objects | (.owner?, .command[0]?)) ]
    | map(select(type == "string")) | unique[]
  ' "$inventory" 2>/dev/null | while IFS= read -r path; do
    case "$path" in
      bin/*..* | bin/*[!A-Za-z0-9._/-]*) printf 'owner %s is not a plain path under bin/\n' "$path" ;;
      bin/?*)
        [ -f "$root/$path" ] && [ -x "$root/$path" ] || printf 'owner %s does not exist or is not executable\n' "$path"
        ;;
      *) printf 'owner %s is not under bin/\n' "$path" ;;
    esac
  done
}

INVENTORY_ERRORS=$(validate_inventory "$INVENTORY" "$CODE_ROOT")
if [ -z "$INVENTORY_ERRORS" ] && [ -n "$AREA" ] \
  && ! jq -e --arg a "$AREA" 'any(.areas[]; . == $a)' "$INVENTORY" >/dev/null; then
  printf 'fm-doctor.sh: unknown area %s (known: %s)\n' "$AREA" \
    "$(jq -r '.areas | join(", ")' "$INVENTORY")" >&2
  exit 2
fi

bound() {  # <inventory-timeout>
  case "${FM_DOCTOR_TIMEOUT:-}" in
    '' | *[!0-9]* | 0) printf '%s\n' "$1" ;;
    *) printf '%s\n' "$FM_DOCTOR_TIMEOUT" ;;
  esac
}

# run_owner <fact-file> <timeout> <env-json> <command-json>: run one owner
# command under its bound and record {rc, timedout, timeout, stdout, stderr}.
run_owner() {
  local fact=$1 timeout=$2 env_json=$3 command_json=$4 rc=0 line
  local -a envs=("FM_HOME=$FM_HOME") argv=()
  while IFS= read -r line; do
    envs+=("$line")
  done < <(printf '%s' "$env_json" | jq -r 'to_entries[] | "\(.key)=\(.value)"')
  while IFS= read -r line; do
    argv+=("$line")
  done < <(printf '%s' "$command_json" | jq -r '.[]')
  argv[0]="$CODE_ROOT/${argv[0]}"
  timeout=$(bound "$timeout")
  fm_run_timed "$timeout" env "${envs[@]}" "${argv[@]}" \
    >"$fact.out" 2>"$fact.err" </dev/null || rc=$?
  jq -n --rawfile out "$fact.out" --rawfile err "$fact.err" \
    --argjson rc "$rc" --argjson timeout "$timeout" \
    --argjson timedout "$(fm_timed_out "$rc" && echo true || echo false)" \
    '{rc: $rc, timedout: $timedout, timeout: $timeout, stdout: $out, stderr: $err}' >"$fact.json"
}

# --- run the selected sources and verbs --------------------------------------
mkdir -p "$WORK/sources" "$WORK/verbs"
if [ -z "$INVENTORY_ERRORS" ]; then
  jq -r --arg area "$AREA" --argjson network "$NETWORK" '
    .sources as $src
    | [ .checks[] | select($area == "" or $area == "doctor" or .area == $area)
        | select(.kind != "verb" and .phase != "sweep") | .source ]
      + (if $area == "" or $area == "doctor" then ($src | keys) else [] end)
    | map(select($network == 1 or $src[.].network != true))
    | unique[] | . as $k
    | [$k, ($src[$k].timeout | tostring), ($src[$k].env // {} | tojson), ($src[$k].command | tojson)] | join("\t")
  ' "$INVENTORY" > "$WORK/source-plan"
  while IFS="$(printf '\t')" read -r id timeout env_json command_json; do
    [ -n "$id" ] || continue
    run_owner "$WORK/sources/$id" "$timeout" "$env_json" "$command_json"
  done < "$WORK/source-plan"
  jq -r --arg area "$AREA" '
    .checks | to_entries[] | select(.value.kind == "verb")
    | select($area == "" or .value.area == $area)
    | [(.key | tostring), (.value.timeout | tostring), "{}", (.value.command | tojson)] | join("\t")
  ' "$INVENTORY" > "$WORK/verb-plan"
  while IFS="$(printf '\t')" read -r index timeout env_json command_json; do
    [ -n "$index" ] || continue
    run_owner "$WORK/verbs/$index" "$timeout" "$env_json" "$command_json"
  done < "$WORK/verb-plan"
fi

# Combine every recorded fact into one object keyed by source id or check index.
facts_of() {  # <dir>
  local f first=1
  printf '{'
  for f in "$1"/*.json; do
    [ -e "$f" ] || continue
    [ "$first" -eq 1 ] || printf ','
    first=0
    printf '%s:' "$(basename "$f" .json | jq -R .)"
    cat "$f"
  done
  printf '}'
}
facts_of "$WORK/sources" > "$WORK/sources.json"
facts_of "$WORK/verbs" > "$WORK/verbs.json"
printf '%s' "$INVENTORY_ERRORS" > "$WORK/inventory-errors"
if [ -n "$INVENTORY_ERRORS" ]; then
  printf '{"checks":[],"sources":{}}' > "$WORK/inventory.json"
else
  cp "$INVENTORY" "$WORK/inventory.json"
fi

# --- facts -> checks -> model --------------------------------------------------
MODEL=$(jq -n \
  --slurpfile inv "$WORK/inventory.json" \
  --slurpfile sources "$WORK/sources.json" \
  --slurpfile verbs "$WORK/verbs.json" \
  --rawfile inverr "$WORK/inventory-errors" \
  --arg area "$AREA" --arg home "$FM_HOME" --argjson network "$NETWORK" '
  def trunc: if length > 200 then .[0:197] + "..." else . end;
  def lines_of: split("\n") | map(select(length > 0));
  def rank: {"fail": 3, "warn": 2, "info": 1, "ok": 0, "skip": 0}[.];
  def worst: if length == 0 then "ok" else max_by(rank) end;
  def evidence_of($hits): ($hits[0] | trunc) + (if ($hits | length) > 1 then " (+\($hits | length - 1) more)" else "" end);
  $inv[0] as $inv | $sources[0] as $src | $verbs[0] as $verbs
  | ($inverr | lines_of) as $errs
  | ([$inv.checks[] | select(.kind != "verb") | .prefix]) as $known
  | def line_status($c; $line): (first(($c.rules // [])[] | select(. as $r | $line | test($r.match)) | .status) // $c.severity);
    def line_check($c):
      if $c.phase == "sweep" then
        {status: "skip", evidence: "printed only by the locked session-start sweep; read the session-start digest"}
      elif $c.phase == "network" and $network != 1 then
        {status: "skip", evidence: "network check; run fm-doctor.sh --network"}
      elif $src[$c.source] == null then {status: "skip", evidence: "source \($c.source) did not run"}
      else $src[$c.source] as $s | $inv.sources[$c.source].complete as $complete
        | ($s.stdout | lines_of | map(select(if $c.kind == "token" then . == $c.prefix else startswith($c.prefix + ":") end))) as $hits
        | if ($hits | length) > 0 then
            {status: ([$hits[] | line_status($c; .)] | worst), evidence: evidence_of($hits), detail: $hits}
          elif $s.rc != 0 then {status: "skip", evidence: "source \($c.source) did not finish; see doctor/\($c.source)"}
          elif $complete != null and (any($s.stdout | lines_of | .[]; test($complete)) | not) then
            {status: "skip", evidence: "no finished network report covers this check: " + ($s.stdout | lines_of | .[0] // "empty" | trunc)}
          else {status: "ok", evidence: "none reported"} end
      end;
    def rule_hit($v; $json):
      if has("exit") then $v.rc == .exit
      elif has("match") then .match as $m | any(($v.stdout | lines_of) + ($v.stderr | lines_of) | .[]; test($m))
      else .field as $f | .equals as $e | ($json != null) and (($json | getpath($f | split(".")) | tostring) == $e)
      end;
    def verb_check($c; $v):
      if $v == null then {status: "skip", evidence: "owner did not run"}
      elif $v.timedout then {status: "warn", evidence: "\($c.command | join(" ")) did not answer within \($v.timeout)s"}
      else
        (if $c.parse == "json" then (try ($v.stdout | fromjson) catch null) else null end) as $json
        | ((first($c.rules[] | select(rule_hit($v; $json)) | .status)) // ($c.default // "warn")) as $status
        | (if $c.parse == "json" and $json != null then
             [$c.rules[] | select(has("field")) | .field] | unique
             | map(. as $f | "\($f)=\($json | getpath($f | split(".")) | tostring)") | join(" ")
           else (($v.stdout | lines_of) + ($v.stderr | lines_of) | .[0] // "exit \($v.rc), no output") end) as $ev
        | {status: $status, evidence: ($ev | trunc),
           detail: (($v.stdout | lines_of) + ($v.stderr | lines_of | map("stderr: " + .)))}
      end;
  ( [ {id: "doctor/jq", area: "doctor", status: "ok", evidence: "jq on PATH", owner: "bin/fm-doctor.sh", fix: "Install jq; the doctor needs it to read its inventory."},
      (if ($errs | length) > 0 then
         {id: "doctor/inventory", area: "doctor", status: "fail", evidence: evidence_of($errs), detail: $errs, owner: "bin/fm-doctor.sh", fix: "Correct docs/doctor-checks.json; every other check is unknown until it validates."}
       else
         {id: "doctor/inventory", area: "doctor", status: "ok", evidence: "\($inv.checks | length) checks valid", owner: "bin/fm-doctor.sh", fix: "Correct docs/doctor-checks.json."}
       end) ]
    + [ $src | to_entries[] | .key as $k | .value as $s
        | {id: "doctor/\($k)", area: "doctor", owner: $inv.sources[$k].command[0],
           fix: "Rerun \($inv.sources[$k].command[0]) by hand to see why it did not finish.",
           detail: ($s.stderr | lines_of | map("stderr: " + .))}
        + (if $s.timedout then {status: "fail", evidence: "did not finish within \($s.timeout)s"}
           elif $s.rc != 0 then {status: "fail", evidence: "exit \($s.rc)" + (($s.stderr | lines_of | .[0] // "") | if . == "" then "" else ": " + . end | trunc)}
           elif ($s.stderr | lines_of | length) > 0 then {status: "info", evidence: ("stderr: " + ($s.stderr | lines_of | .[0]) | trunc)}
           else {status: "ok", evidence: "finished, exit 0"} end) ]
    + (if ($src | length) > 0 then
         ([ $src | to_entries[] | select($inv.sources[.key].scan != true) | .value.stdout | lines_of[]
            | select((capture("^(?<p>[A-Z][A-Z0-9_]*)(:|$)").p // "") as $p | ($known | index([$p])) == null) ]) as $unmapped
         | [ {id: "doctor/unmapped-line", area: "doctor", owner: "bin/fm-doctor.sh",
              fix: "Map the new prefix in docs/doctor-checks.json and handle it in the bootstrap-diagnostics skill."}
             + (if ($unmapped | length) > 0 then {status: "fail", evidence: evidence_of($unmapped), detail: $unmapped}
                else {status: "ok", evidence: "every bootstrap line is mapped"} end) ]
       else [] end)
    | map(select($area == "" or $area == "doctor" or .id == "doctor/inventory" or .status != "ok")) )
  + [ $inv.checks | to_entries[] | .key as $i | .value as $c
      | select($area == "" or $c.area == $area)
      | {id: $c.id, area: $c.area, owner: ($c.owner // $c.command[0]), fix: $c.fix}
        + (if $c.kind == "verb" then verb_check($c; $verbs[$i | tostring]) else line_check($c) end) ]
  | . as $checks
  | ([$checks[].status] | worst) as $worst
  | {schema: "fm-doctor.v1", home: $home, area: (if $area == "" then null else $area end),
     verdict: (if $worst == "fail" then "fail" elif $worst == "warn" then "warn" else "ok" end),
     counts: (reduce ("ok", "warn", "fail", "info", "skip") as $s ({}; .[$s] = ([$checks[] | select(.status == $s)] | length))),
     checks: $checks}
') || { echo "fm-doctor.sh: could not build the report" >&2; exit 1; }

if [ "$FORMAT" = json ]; then
  printf '%s\n' "$MODEL"
else
  TOON=$(printf '%s\n' "$MODEL" | jq --argjson network "$NETWORK" '
    . as $m
    | [.checks[] | select(.status == "warn" or .status == "fail")] as $findings
    | {home: .home, verdict: .verdict,
       summary: "\(.counts.fail) fail, \(.counts.warn) warn, \(.counts.ok) ok, \(.counts.info) info, \(.counts.skip) skip",
       checks: [.checks[] | {id, status, evidence}],
       findings: [$findings[] | {id, fix}],
       help: ((if ($findings | length) == 0 then ["No findings: nothing needs action"]
               else ["Apply each fix through its owner command; never edit captain-owned files to clear a finding"] end)
              + (if $network == 1 then [] else ["Run fm-doctor.sh --network to add the GitHub auth probe and the last network report"] end)
              + ["Run fm-doctor.sh --json for every evidence line"])}
  ' | fm_toon_render) || { echo "fm-doctor.sh: TOON rendering failed" >&2; exit 1; }
  printf '%s\n' "$TOON"
fi

[ "$(printf '%s\n' "$MODEL" | jq -r .verdict)" != fail ]
