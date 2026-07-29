#!/usr/bin/env bash
# fm-model-verify.sh - live entitlement probes and local price-drift checks for
# the models config/models.json says this home routes to.
# Usage: fm-model-verify.sh [--all] [--model <provider/model>] [--drift-only]
#                           [--dry-run] [--force-probe] [--json] [--timeout <s>]
#          Default: probe only routed models whose recorded evidence is older
#          than their observation level's interval, then run the price-drift
#          comparison. Prints ONE line per model that needs firstmate's attention
#          and nothing at all when everything is current - it runs on the
#          session-start path, so silence is the normal outcome.
#        --all         probe every routed model regardless of its interval.
#        --model       probe exactly this model, ignoring the interval.
#        --drift-only  skip probing entirely; only compare stored prices.
#        --dry-run     print what would be probed, probe nothing.
#        --force-probe probe a model the zero-budget cost decision refuses; the
#                      only override, and it announces itself on stdout.
#        --json        emit the health record to stdout instead of the summary.
#        --timeout     hard ceiling in seconds for the whole sweep (default 90).
#          Exits 0 when everything is current, 2 when any line was printed.
#
# NO PROBE WITHOUT A COST VERDICT. Every probe path, including an explicit
# --model, consults fm_model_zero_budget_decision before issuing a live request:
# the instrument that catches an entitlement error is itself a billable act on a
# metered provider, which is why cost class is established before entitlement
# and not after. A typed --model is not authorization to spend money - under the
# zero-budget rule spending is never implied, only explicitly flagged, and the
# flag is --force-probe.
#
# WHY BOTH CHECKS, FOREVER. The two things that decay are not properties of the
# model - they are properties of the ACCOUNT and of the provider's price list, and
# both change without warning. A model can be perfectly stable while its
# entitlement is revoked and its price is raised. So observation never reaches
# zero: at the maintenance floor these two checks still run.
#   1. The entitlement probe catches a routed model this account cannot actually
#      use. That failure has happened here: a model was configured from a
#      plausible name, never probed, and every dispatch to that tier failed at
#      launch until an investigation found it.
#   2. The price-drift check is the ONLY thing that can catch a repricing,
#      because a name-based allowlist is structurally blind to it. It is a local
#      file read and costs nothing.
#
# STDIN IS ALWAYS CLOSED ON A PROBE. `pi -p` can hang indefinitely with stdin
# open. A wedged probe inside the session-start path would present to supervision
# as a stale session - the monitor becoming the fault - so every probe redirects
# from /dev/null and additionally runs under `timeout`.
#
# THIS SCRIPT NEVER WRITES config/models.json. Availability is volatile and lives
# in state/model-health.json; the registry's status is a durable ROUTING decision.
# Conflating them would make every transient outage permanently degrade the
# routing table, which is exactly the failure the demotion policy is built to
# avoid. A rate-limited model is unavailable, not demoted.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-model-registry-lib.sh
. "$SCRIPT_DIR/fm-model-registry-lib.sh"

ALL=0
ONE=
DRIFT_ONLY=0
DRY_RUN=0
FORCE_PROBE=0
AS_JSON=0
TOTAL_TIMEOUT=90
PROBE_TIMEOUT=25

want=
for a in "$@"; do
  if [ -n "$want" ]; then
    case "$want" in
      model)   ONE=$a ;;
      timeout) TOTAL_TIMEOUT=$a ;;
    esac
    want=
    continue
  fi
  case "$a" in
    --all) ALL=1 ;;
    --model) want=model ;;
    --model=*) ONE=${a#--model=} ;;
    --drift-only) DRIFT_ONLY=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --force-probe) FORCE_PROBE=1 ;;
    --json) AS_JSON=1 ;;
    --timeout) want=timeout ;;
    --timeout=*) TOTAL_TIMEOUT=${a#--timeout=} ;;
    *) echo "error: unknown argument '$a'" >&2; exit 1 ;;
  esac
done
[ -z "$want" ] || { echo "error: --$want requires a value" >&2; exit 1; }
case "$TOTAL_TIMEOUT" in
  ''|*[!0-9]*) echo "error: --timeout must be a whole number of seconds" >&2; exit 1 ;;
esac

REG="$CONFIG/models.json"
[ -f "$REG" ] || { [ "$AS_JSON" = 1 ] && echo '{}'; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "MODEL_VERIFY: jq is required and not installed"; exit 0; }

if ! err=$(fm_model_registry_validate "$REG"); then
  echo "MODEL_REGISTRY: invalid config/models.json - $err"
  exit 0
fi

HEALTH="$STATE/model-health.json"
NOW_EPOCH=$(date -u +%s)
NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# ---------------------------------------------------------------------------
# Select the models to probe
# ---------------------------------------------------------------------------
# A model is due when its recorded probe evidence is older than the interval its
# observation level names. Interval-gating is what keeps this affordable on the
# session-start path: in the steady state nothing is due and the sweep costs one
# file read.
select_due() {
  local out rc
  # Bind .key/.value to variables BEFORE any `x | y` pipe: inside a pipe the
  # input rebinds, so `select(approved | index(.value.status))` would index the
  # approved ARRAY rather than the entry. That mistake fails the whole query, and
  # a swallowed failure here would read as "nothing is due" - a sweep that never
  # probes while appearing healthy. Hence the explicit rc check below.
  out=$(jq -r --argjson now "$NOW_EPOCH" --argjson all "$ALL" '
    def secs($iso):
      ($iso // "") as $t
      | if ($t | length) == 0 then null
        else (try ($t | sub("Z$"; "+0000") | strptime("%Y-%m-%dT%H:%M:%S%z") | mktime) catch null)
        end;
    def approved: ["approved-primary","approved-fallback","approved-specialist"];
    . as $r
    | ($r.models // {}) | to_entries[]
    | .key as $k | .value as $e
    | ($e.status? // "") as $st
    | select(approved | index($st))
    | (($r.observation?.levels?[($e.observation_level? // "O4")]?.probe_max_age_days?) // 1) as $maxd
    | (secs($e.evidence?.probe?.at?)) as $at
    | select($all == 1 or $at == null or (($now - $at) > ($maxd * 86400)))
    | [$k, ($e.harness? // "pi"), ($e.provider? // ($k | split("/")[0])),
       ($e.model_id? // ($k | split("/") | .[1:] | join("/")))]
    | @tsv
  ' "$REG" 2>&1)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "MODEL_VERIFY: could not determine which models are due for a probe: $out" >&2
    return 1
  fi
  printf '%s\n' "$out"
}

if [ -n "$ONE" ]; then
  DUE=$(jq -r --arg k "$ONE" '
    (.models[$k]? // null) as $e
    | if $e == null then empty
      else [$k, ($e.harness? // "pi"), ($e.provider? // ($k | split("/")[0])),
            ($e.model_id? // ($k | split("/") | .[1:] | join("/")))] | @tsv end' "$REG" 2>/dev/null || true)
  if [ -z "$DUE" ]; then
    echo "MODEL_VERIFY: $ONE is not in config/models.json"
    exit 1
  fi
else
  DUE=$(select_due) || exit 2
fi

# ---------------------------------------------------------------------------
# Cost gate: no live request without a zero-budget verdict
# ---------------------------------------------------------------------------
# The probe that catches an entitlement error is itself a billable act on a
# metered provider, which is why cost class is established BEFORE entitlement
# and not after. Both paths land here - the interval-gated sweep and an explicit
# --model - because a typed model name is not authorization to spend money. A
# refused model is skipped entirely: no request is issued and its prior health
# record is left untouched. --force-probe is the only override, and it announces
# itself so an authorized billable probe is never invisible in the output.
NEEDS_ACTION=0
if [ "$DRIFT_ONLY" != 1 ] && [ -n "$DUE" ]; then
  ALLOWED=
  while IFS=$'\t' read -r key harness provider model_id; do
    [ -n "$key" ] || continue
    if reason=$(fm_model_zero_budget_decision "$key"); then
      ALLOWED="${ALLOWED}${key}"$'\t'"${harness}"$'\t'"${provider}"$'\t'"${model_id}"$'\n'
    elif [ "$FORCE_PROBE" = 1 ]; then
      echo "MODEL_VERIFY: --force-probe overrides the cost refusal for $key - this probe is a billable act: $reason"
      ALLOWED="${ALLOWED}${key}"$'\t'"${harness}"$'\t'"${provider}"$'\t'"${model_id}"$'\n'
    else
      echo "MODEL_VERIFY: refusing to probe $key - $reason (--force-probe is the only override)"
      NEEDS_ACTION=1
    fi
  done <<EOF
$DUE
EOF
  DUE=$ALLOWED
fi

# ---------------------------------------------------------------------------
# Probe
# ---------------------------------------------------------------------------
# One probe. Prints "<key>\t<shape>\t<rc>\t<latency>\t<first line of output>".
# stdin closed (</dev/null) AND bounded by `timeout` - two independent reasons
# this cannot wedge the caller.
probe_one() {
  local key=$1 harness=$2 provider=$3 model_id=$4 out rc t0 t1 lat shape
  if [ "$harness" != pi ] && [ "$harness" != pi-signed ]; then
    printf '%s\t%s\t\t\t%s\n' "$key" 'unprobeable' "no verified probe path for harness $harness"
    return 0
  fi
  if ! command -v "$harness" >/dev/null 2>&1; then
    printf '%s\t%s\t\t\t%s\n' "$key" 'unprobeable' "$harness is not installed"
    return 0
  fi
  t0=$(date +%s)
  out=$(timeout "$PROBE_TIMEOUT" "$harness" -p --provider "$provider" --model "$model_id" \
        --no-tools --no-session --thinking off 'Reply with the single word: ok' \
        </dev/null 2>&1)
  rc=$?
  t1=$(date +%s)
  lat=$((t1 - t0))
  if [ "$rc" = 124 ]; then
    printf '%s\t%s\t%s\t%s\t%s\n' "$key" 'timeout' "$rc" "$lat" "probe exceeded ${PROBE_TIMEOUT}s"
    return 0
  fi
  shape=$(fm_model_probe_classify "$rc" "$out")
  printf '%s\t%s\t%s\t%s\t%s\n' "$key" "$shape" "$rc" "$lat" "$(printf '%s' "$out" | head -1)"
}

RESULTS=
if [ "$DRIFT_ONLY" != 1 ] && [ -n "$DUE" ]; then
  if [ "$DRY_RUN" = 1 ]; then
    while IFS=$'\t' read -r key harness provider model_id; do
      [ -n "$key" ] || continue
      echo "MODEL_VERIFY: would probe $key via $harness ($provider/$model_id)"
    done <<EOF
$DUE
EOF
    exit 0
  fi
  TMPD=$(mktemp -d "${TMPDIR:-/tmp}/fm-model-verify.XXXXXX") || exit 1
  trap 'rm -rf "$TMPD"' EXIT
  n=0
  while IFS=$'\t' read -r key harness provider model_id; do
    [ -n "$key" ] || continue
    n=$((n + 1))
    probe_one "$key" "$harness" "$provider" "$model_id" > "$TMPD/$n.out" 2>/dev/null &
  done <<EOF
$DUE
EOF
  # Hard total ceiling for the whole sweep: reap whatever finished by the
  # deadline rather than waiting on a straggler. An unfinished probe simply
  # leaves that model's prior health record untouched.
  deadline=$((NOW_EPOCH + TOTAL_TIMEOUT))
  while [ -n "$(jobs -pr)" ]; do
    [ "$(date +%s)" -lt "$deadline" ] || break
    sleep 1
  done
  for pid in $(jobs -pr); do kill "$pid" 2>/dev/null || true; done
  wait 2>/dev/null || true
  RESULTS=$(cat "$TMPD"/*.out 2>/dev/null || true)
fi

# ---------------------------------------------------------------------------
# Merge into the volatile health record
# ---------------------------------------------------------------------------
mkdir -p "$STATE"
[ -f "$HEALTH" ] || printf '{"models":{}}\n' > "$HEALTH"
if ! jq -e . "$HEALTH" >/dev/null 2>&1; then
  printf '{"models":{}}\n' > "$HEALTH"
fi

if [ -n "$RESULTS" ]; then
  merged=$(printf '%s\n' "$RESULTS" | jq -R -s --arg at "$NOW_ISO" --slurpfile prior "$HEALTH" '
    ($prior[0] // {"models":{}}) as $p
    | [ split("\n")[] | select(length > 0) | split("\t")
        | { key: .[0],
            value: { shape: .[1], rc: (.[2] | tonumber? // null),
                     latency_s: (.[3] | tonumber? // null),
                     detail: (.[4] // ""), at: $at } } ]
    | from_entries
    | . as $new
    | reduce ($new | to_entries[]) as $e
        ($p; .models[$e.key] = (
          ($p.models[$e.key]? // {}) as $old
          | ($e.value.shape) as $shape
          | $e.value
            + { state: (if $shape == "ok" then "available"
                        elif $shape == "unprobeable" then ($old.state? // "unknown")
                        else "unavailable" end),
                consecutive_failures: (
                  if $shape == "ok" then 0
                  elif $shape == "unprobeable" then ($old.consecutive_failures? // 0)
                  else (($old.consecutive_failures? // 0) + 1) end) }
        ))
    | .updated_at = $at
  ')
  printf '%s\n' "$merged" > "$HEALTH"
fi

if [ "$AS_JSON" = 1 ]; then
  cat "$HEALTH"
  exit 0
fi

# ---------------------------------------------------------------------------
# Report only what firstmate should act on
# ---------------------------------------------------------------------------
if [ -n "$RESULTS" ]; then
  while IFS=$'\t' read -r key shape rc lat detail; do
    [ -n "$key" ] || continue
    case "$shape" in
      ok) ;;
      unprobeable)
        echo "MODEL_VERIFY: $key could not be probed - $detail"
        NEEDS_ACTION=1
        ;;
      entitlement-refused)
        echo "MODEL_VERIFY: $key is REFUSED by the provider for this account - it must not be routed to: $detail"
        NEEDS_ACTION=1
        ;;
      unknown-model)
        echo "MODEL_VERIFY: $key was not recognised by its provider (identity error, not an outage): $detail"
        NEEDS_ACTION=1
        ;;
      client-error)
        echo "MODEL_VERIFY: $key failed locally before the request left the machine (configuration error): $detail"
        NEEDS_ACTION=1
        ;;
      timeout)
        echo "MODEL_VERIFY: $key probe timed out after ${PROBE_TIMEOUT}s"
        NEEDS_ACTION=1
        ;;
      *)
        echo "MODEL_VERIFY: $key probe returned an unrecognised result (rc=$rc, ${lat}s): $detail"
        NEEDS_ACTION=1
        ;;
    esac
  done <<EOF
$RESULTS
EOF
fi

drift=$(fm_model_price_drift "$REG" || true)
if [ -n "$drift" ]; then
  printf '%s\n' "$drift"
  NEEDS_ACTION=1
fi

# Exit 2 when anything was printed, so a caller can branch on the result without
# re-parsing the lines. Bootstrap deliberately ignores this and treats the printed
# lines as the signal, matching every other detect-only check there.
[ "$NEEDS_ACTION" = 0 ] || exit 2
exit 0
