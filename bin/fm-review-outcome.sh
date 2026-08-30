#!/usr/bin/env bash
# Own the private append-only review-outcome ledger and its read surfaces.
#
# Usage:
#   fm-review-outcome.sh append --payload <json>
#     Validate and append one typed review-outcome row to
#     FM_HOME/data/review-outcomes.jsonl. FM_HOME must be set explicitly;
#     an unset FM_HOME is refused, never defaulted.
#   fm-review-outcome.sh sheet [--from <bound>] [--to <bound>] [--format json]
#     Emit a canonical view of every ledger row, optionally filtered to a UTC
#     window and accompanied by a per-window summary when both bounds are set.
#     A bound is a UTC RFC3339 timestamp or a bare YYYY-MM-DD date; a bare date
#     on --to covers that whole day. Anything else is refused rather than
#     silently narrowing the window.
#
# New rows validate against docs/telemetry-schema.md. A payload that does not
# satisfy the review-ledger contract is refused with a named reason. The ledger
# is append-only: refused appends leave the file byte-identical.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2034 # FM_ROOT reserved for parity with other ledger owners.
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
SCHEMA_VERSION=4

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

die() {
  echo "error: review outcome: $*" >&2
  exit 1
}

require_fm_home() {
  [ -n "${FM_HOME+x}" ] || die "FM_HOME is not set"
  [ -n "$FM_HOME" ] || die "FM_HOME is not set"
}

path_mode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1" 2>/dev/null
  else
    stat -c %a "$1" 2>/dev/null
  fi
}

validate_private_file() {
  local path=$1 label=$2
  [ ! -L "$path" ] || die "$label is a symlink"
  [ -e "$path" ] || return 0
  [ -f "$path" ] || die "$label is not a regular non-symlink file"
  [ "$(path_mode "$path")" = 600 ] || die "$label mode must be 600"
}

canonical_json() {
  printf '%s' "$1" | jq -ceS -s 'if length == 1 then .[0] else error("payload must contain exactly one JSON document") end' 2>/dev/null \
    || die "malformed JSON payload"
}

require_valid_utc_timestamp() {
  local flag=$1 value=$2 message
  message=${3:-"$flag must be a valid UTC RFC3339 timestamp"}
  if ! node - "$value" <<'NODE'
const value=process.argv[2] || '';
const match=value.match(/^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(\.\d+)?Z$/);
if (!match) process.exit(1);
const [, year, month, day, hour, minute, second]=match;
const date=new Date(value);
if (!Number.isFinite(date.getTime()) ||
    date.getUTCFullYear() !== Number(year) ||
    date.getUTCMonth() + 1 !== Number(month) ||
    date.getUTCDate() !== Number(day) ||
    date.getUTCHours() !== Number(hour) ||
    date.getUTCMinutes() !== Number(minute) ||
    date.getUTCSeconds() !== Number(second)) {
  process.exit(1);
}
NODE
  then
    die "$message"
  fi
}

validate_append_payload() {
  local payload=$1
  local missing
  missing=$(printf '%s' "$payload" | jq -r --argjson schemaVersion "$SCHEMA_VERSION" '
    def present($root; $k):
      ($root[$k] // null) as $v
      | if $k == "pr" then
          ($v | type) == "number" and ($v >= 1) and ($v == ($v | floor))
        elif $k == "schemaVersion" then
          $v == $schemaVersion
        elif $k == "timestamp" then
          ($v | type) == "string"
        elif $k == "repository" then
          ($v | type) == "string"
          and (($v // "") | test("^[^/[:space:]]+/[^/[:space:]]+$"))
        else
          ($v | type) == "string" and ($v | length) >= 1
        end;
    . as $root
    | ["schemaVersion","taskId","repository","pr","roundKind","timestamp","status"]
    | map(select(present($root; .) | not))
    | .[]
  ' 2>/dev/null) || die "malformed JSON payload"

  if [ -n "$missing" ]; then
    while IFS= read -r field; do
      [ -n "$field" ] || continue
      die "missing required field: $field"
    done <<EOF
$missing
EOF
  fi

  require_valid_utc_timestamp timestamp "$(printf '%s' "$payload" | jq -r '.timestamp')"

  printf '%s' "$payload" | jq -e '
    def oneof($a): . as $v | ($a|index($v))!=null;
    .status | oneof(["posted","abandoned-unposted","blocked","superseded","no-round"])
  ' >/dev/null 2>&1 || {
    local status
    status=$(printf '%s' "$payload" | jq -r '.status // empty')
    if [ -z "$status" ]; then
      die "missing required field: status"
    fi
    die "status outside closed enum: $status"
  }

  local metrics_err
  metrics_err=$(printf '%s' "$payload" | jq -r '
    def nnint:
      type == "number" and (isnan | not) and . >= 0 and (. == floor);
    def oneof($a): . as $v | ($a | index($v)) != null;
    if (has("metricsUnavailable") and (.metricsUnavailable | type) != "boolean") then
      "bad-metrics-unavailable-type:" + (.metricsUnavailable | type)
    elif .metricsUnavailable == true then
      . as $root
      | (["candidates", "kills", "survivors", "agreement"]
         | map(. as $field | select($root | has($field)))) as $typed
      | (
          (if ($typed | length) > 0 then $typed[] | "mixed-unavailable:" + . else empty end),
          (if (($root.metricsUnavailableReason | type) != "string") or (($root.metricsUnavailableReason | length) < 1) then
             "missing:metricsUnavailableReason"
           elif ($root.metricsUnavailableReason | oneof(["no-round", "abandoned-before-compile"]) | not) then
             "bad-reason:" + $root.metricsUnavailableReason
           else
             empty
           end)
        )
    else
      . as $root
      | if (has("metricsUnavailableReason") and .metricsUnavailableReason != null) then
          ["mixed-available-reason"]
        else
          (
            ["candidates", "kills", "survivors"]
            | map(select($root[.] | nnint | not) | "missing:" + .)
          )
          + (
              if ($root.agreement | type) != "string" or ($root.agreement | length) < 1 then
                ["missing:agreement"]
              elif ($root.agreement | oneof(["unanimous", "majority", "split", "not-applicable"]) | not) then
                ["bad-agreement:" + $root.agreement]
              else
                []
              end
            )
        end
      | .[]
    end
  ' 2>/dev/null) || die "malformed JSON payload"

  if [ -n "$metrics_err" ]; then
    while IFS= read -r item; do
      [ -n "$item" ] || continue
      case "$item" in
        missing:*)
          die "missing required field: ${item#missing:}"
          ;;
        bad-reason:*)
          die "metricsUnavailableReason outside closed enum: ${item#bad-reason:}"
          ;;
        bad-agreement:*)
          die "agreement outside closed enum: ${item#bad-agreement:}"
          ;;
        mixed-unavailable:*)
          die "metricsUnavailable cannot be combined with typed metric field: ${item#mixed-unavailable:}"
          ;;
        mixed-available-reason)
          die "metricsUnavailableReason must be null when metrics are available"
          ;;
        bad-metrics-unavailable-type:*)
          die "metricsUnavailable must be boolean: ${item#bad-metrics-unavailable-type:}"
          ;;
        *)
          die "invalid metrics: $item"
          ;;
      esac
    done <<EOF
$metrics_err
EOF
  fi
}

validate_ledger_for_write() {
  local ledger=$1
  [ ! -L "$ledger" ] || die "ledger is a symlink"
  [ ! -e "$ledger" ] || [ -f "$ledger" ] || die "ledger is not a regular non-symlink file"
  if [ -e "$ledger" ] && [ "$(path_mode "$ledger")" != 600 ]; then
    chmod 0600 "$ledger" 2>/dev/null || die "ledger mode could not be tightened to 600"
  fi
}

durable_append() {
  local ledger=$1 event=$2
  node - "$ledger" "$event" <<'NODE'
const fs=require('fs');
const [path,event]=process.argv.slice(2);
const fd=fs.openSync(path,fs.constants.O_RDWR|fs.constants.O_CREAT|fs.constants.O_APPEND,0o600);
try {
  const stat=fs.fstatSync(fd);
  let separator='';
  if (stat.size > 0) {
    const tail=Buffer.alloc(1);
    fs.readSync(fd,tail,0,1,stat.size-1);
    separator=tail[0] === 0x0a ? '' : '\n';
  }
  fs.writeSync(fd,separator+event+'\n',null,'utf8');
  fs.fsyncSync(fd);
} finally { fs.closeSync(fd); }
NODE
  chmod 0600 "$ledger"
}

cmd_append() {
  local payload=${1:-}
  [ -n "$payload" ] || die "append requires --payload"
  require_fm_home
  local data="$FM_HOME/data"
  local ledger="$data/review-outcomes.jsonl"
  [ ! -L "$data" ] || die "data directory is a symlink"
  [ ! -e "$data" ] || [ -d "$data" ] \
    || die "data directory is not a directory"
  mkdir -p "$data"
  validate_private_file "$ledger" ledger
  validate_ledger_for_write "$ledger"
  payload=$(canonical_json "$payload")
  validate_append_payload "$payload"
  durable_append "$ledger" "$payload"
}

review_sheet_filter() {
  cat <<'JQ'
def nnint:
  type == "number" and (isnan | not) and . >= 0 and (. == floor);
def oneof($a): . as $v | ($a | index($v)) != null;
def typed_status_table:
  {
    "posted": "posted",
    "abandoned-unposted": "abandoned-unposted",
    "blocked": "blocked",
    "superseded": "superseded",
    "no-round": "no-round"
  };
def v3_status_table:
  {
    "posted": "posted",
    "completed": "posted",
    "completed-posted": "posted",
    "posted-clean": "posted",
    "passed": "posted",
    "abandoned-unposted": "abandoned-unposted",
    "abandoned-unposted-draft": "abandoned-unposted",
    "abandoned-unposted-head-moved": "abandoned-unposted",
    "abandoned-unposted-merged": "abandoned-unposted",
    "abandoned-unposted-route-satisfied": "abandoned-unposted",
    "completed-unposted": "abandoned-unposted",
    "no-round": "no-round",
    "superseded-no-post": "superseded",
    "completed-merged-before-publication": "superseded"
  };
def v1_result_table:
  {
    "posted-zero-findings": "posted",
    "clean-exact-head-comment": "posted",
    "posted-one-p2-finding": "posted",
    "posted-one-p2": "posted",
    "posted-clean": "posted",
    "approved-round-complete": "posted",
    "retired-merged-closed": "superseded",
    "stability-required-no-publication": "no-round",
    "private-two-p1-no-post": "no-round",
    "eligibility-skipped-merged": "no-round"
  };
def table_lookup($table; $value):
  if ($value | type) == "string" then $table[$value] else null end;
def legacy_spelling:
  if .schemaVersion == 4 then null
  elif .schemaVersion == 1 and ((.result | type) == "string") and ((.result | length) > 0) then .result
  elif ((.status | type) == "string") and ((.status | length) > 0) then .status
  elif ((.result | type) == "string") and ((.result | length) > 0) then .result
  else null
  end;
def canonical_status:
  if .schemaVersion == 4 then table_lookup(typed_status_table; .status) // "legacy-unclassified"
  elif .schemaVersion == 1 then table_lookup(v1_result_table; .result) // "legacy-unclassified"
  elif .schemaVersion == 3 then table_lookup(v3_status_table; .status) // "legacy-unclassified"
  else "legacy-unclassified"
  end;
def unavailable:
  {
    candidates: null,
    kills: null,
    survivors: null,
    agreement: null,
    metricsUnavailable: true,
    metricsUnavailableReason: "legacy-shape"
  };
def typed_metrics:
  if .metricsUnavailable == true then
    {
      candidates: null,
      kills: null,
      survivors: null,
      agreement: null,
      metricsUnavailable: true,
      metricsUnavailableReason: .metricsUnavailableReason
    }
  elif (has("metricsUnavailable") and (.metricsUnavailable | type) != "boolean") then
    unavailable
  elif ((.candidates | nnint)
        and (.kills | nnint)
        and (.survivors | nnint)
        and ((.agreement | type) == "string")
        and ((.agreement | length) >= 1)
        and (.agreement | oneof(["unanimous", "majority", "split", "not-applicable"]))) then
    {
      candidates,
      kills,
      survivors,
      agreement,
      metricsUnavailable: false,
      metricsUnavailableReason: null
    }
  else
    unavailable
  end;
def v1_metrics:
  if (.compiler | type) != "object" then
    unavailable
  else
    ((.compiler.killCount // .compiler.strictKillCount) as $kills
     | .compiler.survivorCount as $survivors
     | if ($kills | nnint) and ($survivors | nnint) then
         {
           candidates: (
             if (.candidateCounts | type) == "object" and (.candidateCounts.raw | nnint) then
               .candidateCounts.raw
             else
               null
             end
           ),
           kills: $kills,
           survivors: $survivors,
           agreement: (if (.compiler.agreement | type) == "string" then .compiler.agreement else null end),
           metricsUnavailable: false,
           metricsUnavailableReason: null
         }
       else
         unavailable
       end)
  end;
def v3_metrics:
  if (.rulings | type) != "object" then
    unavailable
  elif ((.rulings.kills | type) == "array") and ((.rulings.survivors | type) == "array") then
    {
      candidates: (
        if (.accounting | type) == "object" and (.accounting.candidatesUnique | nnint) then
          .accounting.candidatesUnique
        else
          null
        end
      ),
      kills: (.rulings.kills | length),
      survivors: (.rulings.survivors | length),
      agreement: null,
      metricsUnavailable: false,
      metricsUnavailableReason: null
    }
  else
    unavailable
  end;
def metrics:
  if .schemaVersion == 4 then
    if table_lookup(typed_status_table; .status) == null then unavailable else typed_metrics end
  elif canonical_status == "legacy-unclassified" then unavailable
  elif .schemaVersion == 1 then v1_metrics
  elif .schemaVersion == 3 then v3_metrics
  else unavailable
  end;
def round_date:
  if (.timestamp | type) == "string" then .timestamp
  elif (.completedAt | type) == "string" then .completedAt
  else null
  end;
def fraction_digits:
  (. // "") | if startswith(".") then .[1:] else . end;
def leap_year($year):
  ($year % 4 == 0) and (($year % 100 != 0) or ($year % 400 == 0));
def days_before_year($year):
  (($year - 1) * 365)
  + (((($year - 1) / 4) | floor))
  - (((($year - 1) / 100) | floor))
  + (((($year - 1) / 400) | floor));
def zone_offset_seconds($zone):
  if $zone == "Z" then 0
  else
    (($zone[1:3] | tonumber) * 3600 + ($zone[4:6] | tonumber))
    | if $zone[0:1] == "-" then 0 - . else . end
  end;
def zone_parts($zone):
  if $zone == "Z" then {hours: 0, minutes: 0}
  else {hours: ($zone[1:3] | tonumber), minutes: ($zone[4:6] | tonumber)}
  end;
def timestamp_parts($value):
  ($value | capture("^(?<year>[0-9]{4})-(?<month>[0-9]{2})-(?<day>[0-9]{2})T(?<hour>[0-9]{2}):(?<minute>[0-9]{2}):(?<second>[0-9]{2})(?<fraction>\\.[0-9]+)?(?<zone>Z|[+-][0-9]{2}:[0-9]{2})$")) as $parts
  | ($parts.year | tonumber) as $year
  | ($parts.month | tonumber) as $month
  | ($parts.day | tonumber) as $day
  | ($parts.hour | tonumber) as $hour
  | ($parts.minute | tonumber) as $minute
  | ($parts.second | tonumber) as $second
  | (zone_parts($parts.zone)) as $zone
  | if $month < 1 or $month > 12
     or $day < 1
     or $hour > 23
     or $minute > 59
     or $second > 59
     or $zone.hours > 23
     or $zone.minutes > 59 then
      error("invalid timestamp")
    else
      ([31, (if leap_year($year) then 29 else 28 end), 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
       | .[$month - 1]) as $month_days
      | ([0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334]
         | .[$month - 1]) as $month_offset
      | if $day > $month_days then
          error("invalid timestamp")
        else
          ($month_offset + (if $month > 2 and leap_year($year) then 1 else 0 end) + $day - 1) as $day_index
          | (((days_before_year($year) - days_before_year(1970) + $day_index) * 86400)
             + ($hour * 3600) + ($minute * 60) + $second
             - zone_offset_seconds($parts.zone)) as $seconds
          | {seconds: $seconds, fraction: ($parts.fraction | fraction_digits)}
        end
    end;
def timestamp_fraction_width:
  (timestamp_parts(.) | .fraction | length);
def zero_fraction($width):
  "0" * $width;
def instant_key($value; $width):
  (timestamp_parts($value)) as $parts
  | [$parts.seconds,
     ($parts.fraction + (zero_fraction($width - ($parts.fraction | length))))];
def bound_key($value; $width; $upper_date):
  if ($value | length) == 10 then
    (timestamp_parts($value + "T00:00:00Z")) as $parts
    | [$parts.seconds + (if $upper_date then 86400 else 0 end), zero_fraction($width)]
  else
    instant_key($value; $width)
  end;
def row:
  canonical_status as $status
  | legacy_spelling as $legacy
  | metrics as $m
  | {
      status: $status,
      legacyStatus: (if .schemaVersion == 4 then null else $legacy end),
      candidates: $m.candidates,
      kills: $m.kills,
      survivors: $m.survivors,
      agreement: $m.agreement,
      metricsUnavailable: $m.metricsUnavailable,
      metricsUnavailableReason: $m.metricsUnavailableReason,
      roundDate: round_date
    };
def row_from_json:
  fromjson as $value
  | if ($value | type) == "object" then $value | row
    else error("ledger row must be an object")
    end;
JQ
}

require_review_bound() {
  local flag=$1 value=$2
  [ -n "$value" ] || return 0
  if printf '%s' "$value" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?Z$'; then
    require_valid_utc_timestamp "$flag" "$value" \
      "$flag must be a UTC RFC3339 timestamp or a bare YYYY-MM-DD date"
  elif printf '%s' "$value" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'; then
    require_valid_utc_timestamp "$flag" "${value}T00:00:00Z" \
      "$flag must be a UTC RFC3339 timestamp or a bare YYYY-MM-DD date"
  else
    die "$flag must be a UTC RFC3339 timestamp or a bare YYYY-MM-DD date"
  fi
}

require_ordered_review_window() {
  local from=$1 to=$2 lower
  [ -n "$from" ] && [ -n "$to" ] || return 0
  if [ "${#to}" -eq 10 ]; then
    lower=${from:0:10}
    [ ! "$to" \< "$lower" ] || die "--from must not be later than --to"
  elif [ "${#from}" -eq 10 ]; then
    [ ! "$to" \< "$from" ] || die "--from must not be later than --to"
  elif ! node - "$from" "$to" <<'NODE'
const [from,to]=process.argv.slice(2);
const parse=value=>{
  const match=value.match(/^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(?:\.(\d+))?Z$/);
  return {base:match[1], fraction:match[2] || ''};
};
const left=parse(from);
const right=parse(to);
const width=Math.max(left.fraction.length,right.fraction.length);
const key=parts=>parts.base+(width === 0 ? '' : `.${parts.fraction.padEnd(width,'0')}`);
if (key(left) > key(right)) process.exit(1);
NODE
  then
    die "--from must not be later than --to"
  fi
}

require_complete_review_window() {
  local from=$1 to=$2
  if { [ -n "$from" ] && [ -z "$to" ]; } || { [ -z "$from" ] && [ -n "$to" ]; }; then
    die "--from and --to must be supplied together"
  fi
}

cmd_sheet() {
  local format=${1:-json} from=${2:-} to=${3:-}
  require_fm_home
  case "$format" in
    json) ;;
    *) die "sheet format must be json" ;;
  esac
  local ledger="$FM_HOME/data/review-outcomes.jsonl"
  [ ! -L "$FM_HOME/data" ] || die "data directory is a symlink"
  [ ! -e "$FM_HOME/data" ] || [ -d "$FM_HOME/data" ] \
    || die "data directory is not a directory"
  [ ! -L "$ledger" ] || die "ledger is a symlink"
  if [ ! -e "$ledger" ]; then
    if [ -n "$from" ] && [ -n "$to" ]; then
      printf '{"rows":[],"summary":{"rounds":0,"posted":0,"abandonedUnposted":0,"blocked":0,"superseded":0,"noRound":0,"legacyUnclassified":0,"undated":0,"metricsUnavailable":0,"kills":0,"survivors":0,"killRate":null}}\n'
    else
      printf '[]\n'
    fi
    return
  fi
  [ -f "$ledger" ] || die "ledger is not a regular non-symlink file"
  if [ -n "$from" ] && [ -n "$to" ]; then
    jq -Rcs --arg from "$from" --arg to "$to" "$(review_sheet_filter)"'
      split("\n") | map(select(length > 0) | row_from_json) as $rows
      | ([$rows[] | .roundDate] + [$from, $to]
         | map(select(type == "string" and length > 10) | timestamp_fraction_width)
         | max // 0) as $fraction_width
      | ($from | bound_key(.; $fraction_width; false)) as $from_key
      | ($to | bound_key(.; $fraction_width; true)) as $to_key
      | def in_window($d; $width):
          ($from=="" or
            (instant_key($d; $width) >= $from_key))
          and
          ($to=="" or
            (if ($to|length)==10 then (instant_key($d; $width) < $to_key)
             else (instant_key($d; $width) <= $to_key) end));
      ($rows | map(select(.roundDate != null) | select(in_window(.roundDate; $fraction_width)))) as $win
      | ($rows | map(select(.roundDate == null))) as $undated
      | ($win | map(select(.metricsUnavailable == true))) as $mu
      | ($win | map(select(.metricsUnavailable != true))) as $metric
      | {
          rows: ($rows | map(del(.roundDate))),
          summary: {
            rounds: ($win | length),
            posted: ($win | map(select(.status=="posted")) | length),
            abandonedUnposted: ($win | map(select(.status=="abandoned-unposted")) | length),
            blocked: ($win | map(select(.status=="blocked")) | length),
            superseded: ($win | map(select(.status=="superseded")) | length),
            noRound: ($win | map(select(.status=="no-round")) | length),
            legacyUnclassified: ($win | map(select(.status=="legacy-unclassified")) | length),
            undated: ($undated | length),
            metricsUnavailable: ($mu | length),
            kills: ($metric | map(.kills // 0) | add // 0),
            survivors: ($metric | map(.survivors // 0) | add // 0),
            killRate: (
              ($metric | map(.kills // 0) | add // 0) as $k
              | ($metric | map(.survivors // 0) | add // 0) as $s
              | if ($k + $s) == 0 then null else ($k / ($k + $s)) end
            )
          }
        }
    ' "$ledger" || die "ledger contains malformed JSON"
  else
    jq -Rcs "$(review_sheet_filter)"'split("\n") | map(select(length > 0) | row_from_json) | map(del(.roundDate))' "$ledger" \
      || die "ledger contains malformed JSON"
  fi
}

CMD=${1:-}
shift 2>/dev/null || true

case "$CMD" in
  append)
    PAYLOAD=''
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --payload)
          [ -n "${2+x}" ] && [ -n "$2" ] || die "append --payload requires a value"
          PAYLOAD=$2
          shift 2
          ;;
        --help|-h) usage; exit 0 ;;
        *) die "unknown argument $1" ;;
      esac
    done
    cmd_append "$PAYLOAD"
    ;;
  sheet)
    FORMAT=json
    FROM=''
    TO=''
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --format)
          [ -n "${2+x}" ] && [ -n "$2" ] || die "sheet --format requires a value"
          FORMAT=$2
          shift 2
          ;;
        --from)
          [ -n "${2+x}" ] && [ -n "$2" ] || die "sheet --from requires a value"
          FROM=$2
          shift 2
          ;;
        --to)
          [ -n "${2+x}" ] && [ -n "$2" ] || die "sheet --to requires a value"
          TO=$2
          shift 2
          ;;
        --help|-h)
          usage
          exit 0
          ;;
        *)
          die "unknown argument $1"
          ;;
      esac
    done
    require_review_bound --from "$FROM"
    require_review_bound --to "$TO"
    require_complete_review_window "$FROM" "$TO"
    require_ordered_review_window "$FROM" "$TO"
    cmd_sheet "$FORMAT" "$FROM" "$TO"
    ;;
  --help|-h|'')
    usage
    ;;
  *)
    die "unknown command: $CMD"
    ;;
esac
