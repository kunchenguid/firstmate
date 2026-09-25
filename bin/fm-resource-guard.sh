#!/usr/bin/env bash
# Central per-task resource-budget and bounded-review policy evaluator.
#
# Usage:
#   fm-resource-guard.sh start <task-id> --provider <provider> [--account-key <key>]
#     [--model <model>] [--scope <quota-scope>]... [--snapshot <path|->]
#     [--tranche-points <points>] [--attribution <exact|dominant|shared|unknown>]
#     [--concurrent-task <task-id>]... [--interval <seconds>] [--no-monitor]
#     [--now <epoch>]
#   fm-resource-guard.sh check <task-id> [--snapshot <path|->] [--monitor] [--now <epoch>]
#   fm-resource-guard.sh milestone <task-id> --type <checks-green|report-accepted|branch-landed|pr-merged>
#     [--snapshot <path|->] [--now <epoch>]
#   fm-resource-guard.sh dispatch <task-id> [--rollback <dispatched-at>] [--now <epoch>]
#   fm-resource-guard.sh pause <task-id> [--pre-dispatch] [--now <epoch>]
#   fm-resource-guard.sh bind-authority <task-id> <captain-hold-task-id>
#   fm-resource-guard.sh resume <task-id> --authority-task <captain-hold-task-id>
#     --decision-file <path> [--snapshot <path|->] [--now <epoch>]
#   fm-resource-guard.sh review <task-id> <creator|critic|failure|correction|delta|final|redesign|rescope>
#     --head <git-sha> --actor <privacy-safe-id> --provider <provider> --family <model-family>
#     [--theme <privacy-safe-id>] [--same-family-reason <privacy-safe-id>] [--now <epoch>]
#   fm-resource-guard.sh monitor <task-id> [--interval <seconds>]
#   fm-resource-guard.sh retire <task-id>
#   fm-resource-guard.sh status <task-id>
#   fm-resource-guard.sh worker-overlay <task-id>
#
# `start` captures a minimized task-start snapshot from quota-axi, writes the
# task-bound fm.task-resource-budget.v1 record, emits one private
# fm.resource-event.v1 baseline event, and registers a process-event monitor.
# The caller supplies provider/account/model/scope identity established at task
# intake; this command never guesses a provider from a harness or model name.
# With no explicit scope it applies provider-wide all_models/all_products plus
# an exact model/product scope when present. Every concrete window named by
# those scopes is evaluated independently, including overlapping account-wide
# and named-model windows; the strictest active floor wins.
#
# Defaults are a 30-point reserve and a 15-point per-window task burn limit.
# A window at six hours or less to reset may use a 15-point reserve, and a
# window at two hours or less may use a 5-point reserve, only when every
# applicable scope reports runway=through_reset and the current measured
# remaining points can cover the declared bounded tranche without crossing the
# temporary floor. Equality is safe: a tranche ending exactly at its floor does
# not cross it. Unknown reset or runway evidence keeps the 30-point floor.
#
# `check` performs one deterministic evaluation. A missing, ambiguous, stale,
# or malformed measurement becomes telemetry_unavailable rather than an
# invented percentage. Under `--monitor` a failed or malformed quota read is
# recorded as a telemetry_read_failed pause over the last known baseline; a
# plain check refuses it without mutating state. A known reserve crossing, 15-point burn, abnormal burn,
# shared/unknown-attribution threshold, unavailable telemetry, or bounded-review
# circuit breaker creates a durable pause-pending record and evaluation. The
# monitor only wakes supervision; it never interrupts a worker or a branch-owning
# validation run. `pause` finalizes the stop only after the worker's own latest
# status event says `paused` with an [at=<epoch>] no older than the pause
# request, which is the supported safe ownership boundary. Every budget starts
# in the durable `pre_dispatch` lifecycle. fm-spawn moves it to `dispatched`
# exactly once through `dispatch` (active budgets only) before launch delivery,
# and rolls that transition back with its `--rollback <dispatched-at>` token if
# the spawn fails before the worker command is delivered. While the lifecycle is
# still `pre_dispatch` no worker exists to stop, so `pause --pre-dispatch`
# finalizes any pending pause at the pre-dispatch boundary without a worker
# event; once dispatched, worker safe-boundary evidence is mandatory. It never invokes
# interrupt, stash, reset, checkout, clean, or force. Every authorized return to
# active (captain resume, near-reset auto-resume, redesign, re-scope) re-arms
# the one per-task monitor registration, and a finalized reserve pause keeps it
# armed so the near-reset proof stays observable.
#
# A finalized ordinary reserve pause may auto-resume only when a later check
# proves that a 15/5 near-reset floor makes the remaining bounded tranche safe.
# Every other pause stays closed until `resume` verifies a unique captain-held
# authority task was answered through bin/fm-captain-hold.sh, verifies the
# supplied decision file has the same durable digest, and reads exactly one
# `resource_budget_points=<number>` line (plus an optional
# `resource_tranche_points=<number>` line) from those captain words. Reserve
# floors never change through a revised budget. When the pause is unavailable
# or reset-discontinuous telemetry, that captain answer also starts a fresh
# versioned baseline from current valid telemetry; it refuses when the current
# snapshot cannot establish one. No prompt, chat, credential,
# token stream, decision text, or project content is copied into guard state.
#
# The review ledger enforces one creator pass, one independent critic pass, one
# accepted correction pass, one focused delta review of the corrected head, and
# an independent full review of the final head. A second consecutive failure
# with the same privacy-safe theme pauses the lane (repeated_review_theme), and
# any failure after the correction pauses it (review_loop_exhausted), so
# alternating themes cannot loop. Either stop is refused further review until
# `redesign` or `rescope` is recorded, or the ordinary captain resume path
# supplies a revised budget. Review records contain only actor ids,
# theme slugs, and exact heads.
#
# Private local records:
#   state/<task>.resource-budget.json       current task budget and review ledger
#   state/<task>.resource-pause.json        latest pause request/outcome
#   data/resource-events/YYYY-MM.jsonl      finalized append-only Hub input
#   data/burn-evaluations/<task>-<id>.json  immutable trigger evaluation
#
# Existing JSONL is parsed and schema-checked before an append. Corrupt or
# hostile local input is never evaluated as shell and blocks only publication;
# the budget decision is staged until publication succeeds. Event ids are
# deterministic, so an exact retry is idempotent. Files are private (0700 dirs,
# 0600 files) and local. This command performs no hosted telemetry, merge,
# deployment, or external write other than the read-only quota-axi query and
# process-event registration it explicitly documents.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-quota-axi-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-quota-axi-lib.sh"

BUDGET_SCHEMA=fm.task-resource-budget.v1
PAUSE_SCHEMA=fm.resource-pause.v1
EVENT_SCHEMA=fm.resource-event.v1
EVALUATION_SCHEMA=fm.burn-evaluation.v1
REVIEW_SCHEMA=fm.bounded-review.v1
DEFAULT_RESERVE=30
DEFAULT_BURN=15
DEFAULT_TRANCHE=15
DEFAULT_INTERVAL=60

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
  exit 2
}

die() { printf 'error: %s\n' "$1" >&2; exit 1; }

slug_valid() {
  case "${1-}" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
}
provider_valid() {
  local LC_ALL=C
  [[ "${1-}" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]
}
number_valid() {
  local LC_ALL=C
  [[ "${1-}" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 1
  jq -en --arg n "$1" '($n | tonumber) >= 0 and ($n | tonumber) <= 100' >/dev/null 2>&1
}
positive_number() {
  number_valid "${1-}" || return 1
  jq -en --arg n "$1" '($n | tonumber) > 0' >/dev/null 2>&1
}
positive_int() { case "${1-}" in ''|*[!0-9]*|0) return 1 ;; *) return 0 ;; esac; }
epoch_valid() { case "${1-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

require_tools() {
  command -v jq >/dev/null 2>&1 || die "jq is required"
  command -v shasum >/dev/null 2>&1 || command -v sha256sum >/dev/null 2>&1 \
    || die "shasum or sha256sum is required"
}

sha256_text() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  else
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  fi
}

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

epoch_iso() {
  local value=$1
  if date -u -r "$value" '+%Y-%m-%dT%H:%M:%SZ' >/dev/null 2>&1; then
    date -u -r "$value" '+%Y-%m-%dT%H:%M:%SZ'
  else
    date -u -d "@$value" '+%Y-%m-%dT%H:%M:%SZ'
  fi
}

now_resolve() {
  local value=${1:-}
  [ -n "$value" ] || value=$(date +%s)
  epoch_valid "$value" || die "--now needs Unix epoch seconds"
  printf '%s' "$value"
}

private_dir() {
  local path=$1
  if [ -e "$path" ] || [ -L "$path" ]; then
    [ -d "$path" ] && [ ! -L "$path" ] || die "private path is not a real directory: $path"
    [ -O "$path" ] || die "private directory is not owned by this user: $path"
  else
    (umask 077; mkdir -p "$path") || die "cannot create private directory: $path"
  fi
  chmod 700 "$path" 2>/dev/null || die "cannot make private directory mode 0700: $path"
}

safe_regular_or_absent() {
  local path=$1
  [ ! -e "$path" ] && [ ! -L "$path" ] && return 0
  [ -f "$path" ] && [ ! -L "$path" ] && [ -O "$path" ]
}

atomic_json_write() {
  local path=$1 json=$2 dir tmp
  dir=${path%/*}
  private_dir "$dir"
  safe_regular_or_absent "$path" || die "refusing unsafe record path: $path"
  tmp=$(umask 077; mktemp "$dir/.resource.XXXXXX") || die "cannot stage resource record"
  if ! printf '%s\n' "$json" | jq -e -c . >"$tmp" 2>/dev/null; then
    rm -f "$tmp"
    die "cannot serialize resource record"
  fi
  chmod 600 "$tmp" || { rm -f "$tmp"; die "cannot protect staged resource record"; }
  mv -f "$tmp" "$path" || { rm -f "$tmp"; die "cannot publish resource record: $path"; }
}

budget_path() { printf '%s/%s.resource-budget.json' "$STATE" "$1"; }
pause_path() { printf '%s/%s.resource-pause.json' "$STATE" "$1"; }
review_path() { printf '%s/%s.resource-review.json' "$STATE" "$1"; }
lock_path() { printf '%s/.resource-%s.lock' "$STATE" "$1"; }

LOCK_DIR=
EVENT_LOCK_DIR=
lock_acquire() {
  local id=$1 attempts=0 owner
  private_dir "$STATE"
  LOCK_DIR=$(lock_path "$id")
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    [ -d "$LOCK_DIR" ] && [ ! -L "$LOCK_DIR" ] || die "resource lock is unsafe: $LOCK_DIR"
    owner=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
    case "$owner" in
      ''|*[!0-9]*) ;;
      *) kill -0 "$owner" 2>/dev/null || { rm -rf "$LOCK_DIR" 2>/dev/null || true; continue; } ;;
    esac
    attempts=$((attempts + 1))
    [ "$attempts" -lt 100 ] || die "resource record is busy for task $id"
    sleep 0.1
  done
  printf '%s\n' "$$" >"$LOCK_DIR/pid" || die "cannot bind resource lock"
}

lock_release() {
  [ -n "$LOCK_DIR" ] || return 0
  if [ "$(cat "$LOCK_DIR/pid" 2>/dev/null || true)" = "$$" ]; then
    rm -f "$LOCK_DIR/pid" 2>/dev/null || true
    rmdir "$LOCK_DIR" 2>/dev/null || true
  fi
  LOCK_DIR=
}

event_lock_acquire() {
  local attempts=0 owner
  EVENT_LOCK_DIR="$STATE/.resource-events.lock"
  while ! mkdir "$EVENT_LOCK_DIR" 2>/dev/null; do
    [ -d "$EVENT_LOCK_DIR" ] && [ ! -L "$EVENT_LOCK_DIR" ] \
      || die "resource event lock is unsafe: $EVENT_LOCK_DIR"
    owner=$(cat "$EVENT_LOCK_DIR/pid" 2>/dev/null || true)
    case "$owner" in
      ''|*[!0-9]*) ;;
      *) kill -0 "$owner" 2>/dev/null || { rm -rf "$EVENT_LOCK_DIR" 2>/dev/null || true; continue; } ;;
    esac
    attempts=$((attempts + 1))
    [ "$attempts" -lt 100 ] || die "resource event journal is busy"
    sleep 0.1
  done
  printf '%s\n' "$$" >"$EVENT_LOCK_DIR/pid" || die "cannot bind resource event lock"
}

event_lock_release() {
  [ -n "$EVENT_LOCK_DIR" ] || return 0
  if [ "$(cat "$EVENT_LOCK_DIR/pid" 2>/dev/null || true)" = "$$" ]; then
    rm -f "$EVENT_LOCK_DIR/pid" 2>/dev/null || true
    rmdir "$EVENT_LOCK_DIR" 2>/dev/null || true
  fi
  EVENT_LOCK_DIR=
}

cleanup_locks() {
  event_lock_release
  lock_release
}
trap cleanup_locks EXIT

load_budget() {
  local id=$1 path
  path=$(budget_path "$id")
  [ -f "$path" ] && [ ! -L "$path" ] || die "resource budget does not exist for task $id"
  BUDGET=$(jq -ce --arg schema "$BUDGET_SCHEMA" --arg task "$id" '
    select(.schema == $schema and .task_id == $task and
      (.provider | type) == "string" and
      (.guard_state | IN("active", "pause_pending", "paused", "retired")) and
      (.windows | type) == "array" and
      (.review | type) == "object")
  ' "$path" 2>/dev/null) || die "resource budget is corrupt or incompatible for task $id"
}

snapshot_read() {
  local source=${1:-} out
  if [ -n "$source" ]; then
    if [ "$source" = - ]; then
      out=$(cat) || die "cannot read quota snapshot from stdin"
    else
      [ -f "$source" ] && [ ! -L "$source" ] || die "snapshot is not a regular file: $source"
      out=$(cat -- "$source") || die "cannot read quota snapshot: $source"
    fi
  else
    fm_quota_axi_compatible || die "quota-axi is missing or below the compatibility floor"
    out=$(quota-axi --json </dev/null 2>/dev/null) || die "quota-axi --json failed"
  fi
  [ -n "$out" ] || die "quota snapshot is empty"
  printf '%s\n' "$out" | fm_quota_json_valid || die "quota snapshot failed the shared schema validator"
  # The shared validator owns availability. This stricter local check owns only
  # the concrete windows this policy spends.
  printf '%s\n' "$out" | jq -e '
    def rfc3339_epoch:
      try (
        capture("^(?<y>[0-9]{4})-(?<mo>[0-9]{2})-(?<d>[0-9]{2})T(?<h>[0-9]{2}):(?<mi>[0-9]{2}):(?<s>[0-9]{2})(?:[.][0-9]+)?(?<zone>Z|(?<sign>[+-])(?<oh>[0-9]{2}):(?<om>[0-9]{2}))$") as $c |
        ($c.y|tonumber) as $y | ($c.mo|tonumber) as $mo | ($c.d|tonumber) as $d |
        ($c.h|tonumber) as $h | ($c.mi|tonumber) as $mi | ($c.s|tonumber) as $sec |
        (if $c.zone == "Z" then 0
         else (((($c.oh|tonumber) * 60 + ($c.om|tonumber)) * 60) *
           (if $c.sign == "+" then 1 else -1 end)) end) as $offset |
        if $mo < 1 or $mo > 12 or $d < 1 or $d > 31 or $h > 23 or $mi > 59 or $sec > 59 or
           ($c.zone != "Z" and (($c.oh|tonumber) > 23 or ($c.om|tonumber) > 59))
        then null
        else ([$y,($mo - 1),$d,$h,$mi,$sec,0,0] | mktime) as $local |
          ($local | gmtime) as $normalized |
          if $normalized[0] != $y or $normalized[1] != ($mo - 1) or $normalized[2] != $d or
             $normalized[3] != $h or $normalized[4] != $mi or $normalized[5] != $sec
          then null else $local - $offset end
        end
      ) catch null;
    all(.providers[];
      ((.windows // []) | type) == "array" and
      all((.windows // [])[];
        type == "object" and
        (.id | type) == "string" and (.id | length) > 0 and
        ((.id | test("^[A-Za-z0-9._:-]+$"))) and
        ((has("percentRemaining") | not) or
          ((.percentRemaining | type) == "number" and .percentRemaining >= 0 and .percentRemaining <= 100)) and
        ((has("resetsAt") | not) or .resetsAt == null or
          ((.resetsAt | type) == "string" and
           (.resetsAt | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:[.][0-9]+)?(?:Z|[+-][0-9]{2}:[0-9]{2})$")) and
           ((.resetsAt | rfc3339_epoch) != null)))) and
      (((.windows // []) | map(.id) | length) == (((.windows // []) | map(.id) | unique | length))) and
      all(.quotaSemantics.effectiveAvailability[]?;
        ((.boundedBy // []) | type) == "array" and
        all((.boundedBy // [])[]; type == "string" and length > 0)))
  ' >/dev/null 2>&1 || die "quota snapshot has malformed concrete window evidence"
  SNAPSHOT=$out
}

scopes_json_from_array() {
  if [ "$#" -eq 0 ]; then printf '[]\n'; return; fi
  printf '%s\n' "$@" | jq -Rsc 'split("\n") | map(select(length > 0)) | unique | sort'
}

concurrent_json_from_array() {
  if [ "$#" -eq 0 ]; then printf '[]\n'; return; fi
  printf '%s\n' "$@" | jq -Rsc 'split("\n") | map(select(length > 0)) | unique | sort'
}

# Build the minimized baseline without retaining quota-axi's raw provider data.
build_baseline_budget() {
  local id=$1 provider=$2 account=$3 model=$4 scopes_json=$5 attribution=$6 concurrent_json=$7
  local tranche=$8 interval=$9 now=${10} ts budget_id snapshot_hash
  ts=$(epoch_iso "$now") || die "cannot render timestamp"
  snapshot_hash=$(sha256_text "$SNAPSHOT")
  budget_id=$(sha256_text "$id|$provider|$account|$model|$scopes_json|$now|$snapshot_hash")
  printf '%s\n' "$SNAPSHOT" | jq -ce \
    --arg schema "$BUDGET_SCHEMA" --arg review_schema "$REVIEW_SCHEMA" \
    --arg task "$id" --arg provider "$provider" --arg account "$account" \
    --arg model "$model" --argjson wanted "$scopes_json" \
    --arg attribution "$attribution" --argjson concurrent "$concurrent_json" \
    --argjson reserve "$DEFAULT_RESERVE" --argjson burn "$DEFAULT_BURN" \
    --arg tranche "$tranche" --argjson interval "$interval" --argjson now "$now" \
    --arg ts "$ts" --arg budget_id "$budget_id" '
    def row:
      ([.providers[] | select(.provider == $provider)]) as $rows |
      if (.schemaVersion == 6) then
        if $account != "" then ([$rows[] | select(.accountKey == $account)] | first // null)
        elif ($rows | length) == 1 then $rows[0]
        elif ([$rows[] | select(.accountKey == "default")] | length) == 1 then
          ([$rows[] | select(.accountKey == "default")] | first)
        else null end
      else ($rows | first // null) end;
    def model_token: ($model | split("/") | last | sub("^model:"; "") | sub("^product:"; ""));
    def account_safe($r):
      ($r == null or ($r.accountKey // null) == null or
       (($r.accountKey | type) == "string" and ($r.accountKey | test("^[A-Za-z0-9._:-]+$"))));
    def selected($r):
      ($r.quotaSemantics.effectiveAvailability // []) as $all |
      if ($wanted | length) > 0 then
        [$wanted[] as $scope | ($all[]? | select(.scope == $scope))]
      else
        [$all[]? | select(
          .scope == "all_models" or .scope == "all_products" or
          (model_token != "" and model_token != "default" and
            (.scope == ("model:" + model_token) or
             .scope == ("product:" + model_token) or
             .scope == model_token)))]
      end;
    row as $r |
    (if $r == null then [] else selected($r) end) as $selected |
    (if $r == null then [] else ($r.windows // []) end) as $windows |
    ([$selected[]?.boundedBy[]?] | unique | sort) as $window_ids |
    ([$window_ids[] as $wid |
      ($windows[]? | select(.id == $wid)) as $w |
      {
        id: $wid,
        label: $wid,
        baseline_remaining_points: ($w.percentRemaining // null),
        current_remaining_points: ($w.percentRemaining // null),
        resets_at: ($w.resetsAt // null),
        applicable_scopes: ([$selected[] | select((.boundedBy // []) | index($wid)) | .scope] | unique | sort),
        runway_statuses: ([$selected[] | select((.boundedBy // []) | index($wid)) | (.runway.status // "unknown")] | unique | sort),
        burn_points: 0,
        reserve_floor_points: $reserve,
        near_reset_release: false
      }
    ]) as $budget_windows |
    ([
      (if $r == null then "provider_or_account_ambiguous" else empty end),
      (if account_safe($r) | not then "account_key_not_privacy_safe" else empty end),
      (if ($selected | length) == 0 then "applicable_scopes_unavailable" else empty end),
      (if ($wanted | length) > 0 and (($selected | map(.scope) | unique | sort) != ($wanted | unique | sort)) then "requested_scope_unavailable" else empty end),
      (if any($selected[]?; .status != "known") then "applicable_scope_unknown" else empty end),
      (if any($selected[]?; ((.boundedBy // []) | length) == 0) then "window_binding_unavailable" else empty end),
      (if ($window_ids | length) != ($budget_windows | length) then "concrete_window_unavailable" else empty end),
      (if any($budget_windows[]?; (.baseline_remaining_points | type) != "number") then "window_remaining_unavailable" else empty end)
    ] | unique) as $telemetry_reasons |
    {
      schema: $schema,
      budget_id: $budget_id,
      revision: 1,
      task_id: $task,
      declared_at: $ts,
      declared_epoch: $now,
      provider: $provider,
      account_key: (if $r == null then (if $account == "" then null else $account end)
        elif account_safe($r) then ($r.accountKey // null) else null end),
      model: (if $model == "" or $model == "default" then null else $model end),
      requested_scopes: $wanted,
      applicable_scopes: ([$selected[]?.scope] | unique | sort),
      reserve_floor_points: $reserve,
      pause_after_points: $burn,
      tranche_points: ($tranche | tonumber),
      monitor_interval_seconds: $interval,
      attribution_confidence: $attribution,
      concurrent_tasks: $concurrent,
      telemetry_status: (if ($telemetry_reasons | length) == 0 then "known" else "unavailable" end),
      baseline_telemetry_reasons: $telemetry_reasons,
      telemetry_reasons: $telemetry_reasons,
      guard_state: "active",
      dispatch_state: "pre_dispatch",
      decision_reason: null,
      windows: $budget_windows,
      review: {
        schema: $review_schema,
        creator: null,
        critic: null,
        corrections: [],
        deltas: [],
        failures: [],
        final: null,
        last_failure_theme: null,
        consecutive_same_theme_failures: 0,
        post_correction_failures: 0,
        redesigns: [],
        captain_budget_revisions: []
      }
    }
  ' 2>/dev/null || die "cannot select task quota evidence"
}

# Evaluate the current concrete windows against the task baseline. This pure jq
# program is the single numeric policy boundary used by start/check/monitor.
evaluate_budget() {
  local budget=$1 now=$2 kind=$3 milestone=${4:-} failure=${5:-} snapshot
  local ts
  ts=$(epoch_iso "$now") || die "cannot render timestamp"
  snapshot=${SNAPSHOT-}
  [ -z "$failure" ] || snapshot='{}'
  printf '%s\n%s\n' "$budget" "$snapshot" | jq -sce \
    --arg event_schema "$EVENT_SCHEMA" --arg eval_schema "$EVALUATION_SCHEMA" \
    --arg pause_schema "$PAUSE_SCHEMA" --arg kind "$kind" --arg milestone "$milestone" \
    --arg failure "$failure" --arg ts "$ts" --argjson now "$now" '
    .[0] as $b | .[1] as $s |
    def row:
      ([$s.providers[] | select(.provider == $b.provider)]) as $rows |
      if ($s.schemaVersion == 6) then
        if $b.account_key != null then ([$rows[] | select(.accountKey == $b.account_key)] | first // null)
        elif ($rows | length) == 1 then $rows[0]
        elif ([$rows[] | select(.accountKey == "default")] | length) == 1 then
          ([$rows[] | select(.accountKey == "default")] | first)
        else null end
      else ($rows | first // null) end;
    def rfc3339_epoch:
      try (
        capture("^(?<y>[0-9]{4})-(?<mo>[0-9]{2})-(?<d>[0-9]{2})T(?<h>[0-9]{2}):(?<mi>[0-9]{2}):(?<s>[0-9]{2})(?:[.][0-9]+)?(?<zone>Z|(?<sign>[+-])(?<oh>[0-9]{2}):(?<om>[0-9]{2}))$") as $c |
        ($c.y|tonumber) as $y | ($c.mo|tonumber) as $mo | ($c.d|tonumber) as $d |
        ($c.h|tonumber) as $h | ($c.mi|tonumber) as $mi | ($c.s|tonumber) as $sec |
        (if $c.zone == "Z" then 0
         else (((($c.oh|tonumber) * 60 + ($c.om|tonumber)) * 60) *
           (if $c.sign == "+" then 1 else -1 end)) end) as $offset |
        if $mo < 1 or $mo > 12 or $d < 1 or $d > 31 or $h > 23 or $mi > 59 or $sec > 59 or
           ($c.zone != "Z" and (($c.oh|tonumber) > 23 or ($c.om|tonumber) > 59))
        then null else ([$y,($mo - 1),$d,$h,$mi,$sec,0,0] | mktime) - $offset end
      ) catch null;
    def reset_epoch($value):
      if ($value | type) == "string" then ($value | rfc3339_epoch) else null end;
    def runway_safe($statuses):
      ($statuses | length) > 0 and all($statuses[]; . == "through_reset");
    def scope_rows($r):
      [($r.quotaSemantics.effectiveAvailability // [])[]? |
       select(.scope as $scope | $b.applicable_scopes | index($scope))];
    def window_eval($r; $base):
      (($r.windows // []) | map(select(.id == $base.id)) | first // null) as $w |
      (scope_rows($r) | map(select((.boundedBy // []) | index($base.id)))) as $scopes |
      ([$scopes[]? | (.runway.status // "unknown")] | unique | sort) as $runways |
      (if $w == null then null else ($w.percentRemaining // null) end) as $remaining |
      (if $w == null then null else ($w.resetsAt // null) end) as $reset |
      (reset_epoch($reset)) as $reset_epoch |
      (if $reset_epoch == null then null else ($reset_epoch - $now) end) as $to_reset |
      ($base.resets_at == $reset) as $reset_continuity |
      (if $reset_continuity and ($remaining | type) == "number" and ($base.baseline_remaining_points | type) == "number"
       then ([0, ($base.baseline_remaining_points - $remaining)] | max) else null end) as $burn |
      (if ($burn | type) == "number" then ([$b.pause_after_points - $burn, 0] | max) else $b.tranche_points end) as $remaining_budget |
      ([$b.tranche_points, $remaining_budget] | min) as $bounded_tranche |
      (if $to_reset != null and $to_reset >= 0 and $to_reset <= 7200 and
           runway_safe($runways) and ($remaining | type) == "number" and
           ($remaining - $bounded_tranche) >= 5 then 5
       elif $to_reset != null and $to_reset >= 0 and $to_reset <= 21600 and
           runway_safe($runways) and ($remaining | type) == "number" and
           ($remaining - $bounded_tranche) >= 15 then 15
       else $b.reserve_floor_points end) as $floor |
      {
        id: $base.id,
        label: $base.label,
        baseline_remaining_points: $base.baseline_remaining_points,
        current_remaining_points: $remaining,
        resets_at: $base.resets_at,
        current_resets_at: $reset,
        seconds_to_reset: $to_reset,
        applicable_scopes: $base.applicable_scopes,
        runway_statuses: $runways,
        burn_points: $burn,
        reserve_floor_points: $floor,
        near_reset_release: ($floor < $b.reserve_floor_points),
        bounded_tranche_points: $bounded_tranche,
        reset_continuity: $reset_continuity,
        telemetry_known: (
          $w != null and $reset_continuity and ($remaining | type) == "number" and
          ($scopes | length) > 0 and all($scopes[]; .status == "known"))
      };
    (if $failure != "" then null else row end) as $r |
    (if $failure != "" then
       [$b.windows[] | . + {current_remaining_points: null, burn_points: null, telemetry_known: false}]
     elif $r == null then [] else [$b.windows[] | window_eval($r; .)] end) as $windows |
    ([
      (if $failure != "" then $failure
       elif $r == null then "provider_or_account_ambiguous" else empty end),
      (if ($windows | length) != ($b.windows | length) then "concrete_window_unavailable" else empty end),
      (if any($windows[]?; .reset_continuity == false) then "window_reset_changed" else empty end),
      (if any($windows[]?; .telemetry_known == false) then "window_telemetry_unavailable" else empty end)
    ] | unique) as $current_telemetry_reasons |
    ((($b.baseline_telemetry_reasons // []) + $current_telemetry_reasons) | unique) as $telemetry_reasons |
    ([ $windows[]? | select((.burn_points | type) == "number") | .burn_points ] | max // 0) as $max_burn |
    ([ $windows[]? | select(.near_reset_release) | .reserve_floor_points ] | min // $b.reserve_floor_points) as $lowest_floor |
    (if ($telemetry_reasons | length) > 0 then "telemetry_unavailable"
     elif $max_burn > $b.pause_after_points then "abnormal_burn"
     elif (($b.attribution_confidence == "shared" or $b.attribution_confidence == "unknown") and
           $max_burn >= $b.pause_after_points) then "attribution_uncertain"
     elif $max_burn >= $b.pause_after_points then "burn_limit"
     elif any($windows[]; (.current_remaining_points - .bounded_tranche_points) < .reserve_floor_points) then "reserve_floor"
     else null end) as $reason |
    (if $reason == null then "active" else "pause_pending" end) as $candidate_state |
    (($b.guard_state == "paused" or $b.guard_state == "pause_pending") and
      $b.decision_reason == "reserve_floor" and $reason == null and $lowest_floor < $b.reserve_floor_points) as $auto_resume |
    (if ($b.guard_state == "paused" or $b.guard_state == "pause_pending") and ($auto_resume | not)
     then $b.guard_state else $candidate_state end) as $state |
    (($b.guard_state == "paused" or $b.guard_state == "pause_pending") and
      $b.decision_reason == "reserve_floor" and $reason != null and $reason != "reserve_floor") as $escalated |
    (if ($b.guard_state == "paused" or $b.guard_state == "pause_pending") and ($auto_resume | not)
     then (if $escalated then $reason else $b.decision_reason end) else $reason end) as $effective_reason |
    ($b + {
      windows: $windows,
      telemetry_status: (if ($telemetry_reasons | length) == 0 then "known" else "unavailable" end),
      telemetry_reasons: $telemetry_reasons,
      guard_state: $state,
      decision_reason: $effective_reason,
      checked_at: $ts,
      checked_epoch: $now
    }) as $updated |
    {
      updated_budget: $updated,
      decision: {
        state: $state,
        reason: $effective_reason,
        auto_resumed: $auto_resume,
        escalated: $escalated,
        safe_boundary_required: ($state == "pause_pending"),
        resume_required: (if $state == "active" then "none"
          elif $effective_reason == "reserve_floor" then "auto_near_reset_or_captain"
          else "captain_decision_or_redesign" end),
        attribution_confidence: $b.attribution_confidence,
        concurrent_tasks: $b.concurrent_tasks,
        max_observed_burn_points: $max_burn,
        strictest_active_floor_points: ([ $windows[]?.reserve_floor_points ] | max // $b.reserve_floor_points)
      },
      event_base: {
        schema: $event_schema,
        ts: $ts,
        kind: $kind,
        task_id: $b.task_id,
        budget_id: $b.budget_id,
        budget_revision: $b.revision,
        provider: $b.provider,
        account_key: $b.account_key,
        model: $b.model,
        source: "quota-axi",
        attribution_confidence: $b.attribution_confidence,
        concurrent_tasks: $b.concurrent_tasks,
        windows: $windows,
        decision: {
          state: $state,
          reason: $effective_reason,
          auto_resumed: $auto_resume,
          resume_required: (if $state == "active" then "none"
            elif $effective_reason == "reserve_floor" then "auto_near_reset_or_captain"
            else "captain_decision_or_redesign" end)
        },
        milestone: (if $milestone == "" then null else {type: $milestone} end)
      },
      evaluation_base: {
        schema: $eval_schema,
        task_id: $b.task_id,
        trigger_ts: $ts,
        trigger: $effective_reason,
        budget_id: $b.budget_id,
        budget_revision: $b.revision,
        windows: $windows,
        measured_delta: {
          unit: "quota_points",
          value: $max_burn,
          confidence: $b.attribution_confidence
        },
        concurrent_tasks: $b.concurrent_tasks,
        pause_action: "safe_boundary_pending",
        resume: {
          required: (if $effective_reason == "reserve_floor" then "auto_near_reset_or_captain" else "captain_decision_or_redesign" end),
          authority_task: null,
          decision_digest: null
        }
      },
      pause_base: {
        schema: $pause_schema,
        task_id: $b.task_id,
        requested_at: $ts,
        raised_by: $kind,
        reason: $effective_reason,
        state: $state,
        safe_boundary: null,
        budget_id: $b.budget_id,
        budget_revision: $b.revision,
        authority_task: null,
        authority_lifecycle: null,
        authority_decision_digest: null,
        resume_authority: null
      }
    }
  ' || die "cannot evaluate current quota evidence"
}

event_file_for_ts() {
  local ts=$1 month
  month=${ts%%T*}
  month=${month%-*}
  printf '%s/resource-events/%s.jsonl' "$DATA" "$month"
}

journal_seal_path() { printf '%s/.%s.sha256' "${1%/*}" "${1##*/}"; }

# Record the whole-file digest of a journal whose every line was just verified
# or written here, so later appends re-verify per-line event ids only when the
# journal bytes changed outside this owner.
journal_seal() {
  local path=$1 seal tmp
  seal=$(journal_seal_path "$path")
  safe_regular_or_absent "$seal" || die "refusing unsafe resource event seal: $seal"
  if [ ! -e "$path" ]; then
    rm -f "$seal" || die "cannot retire resource event seal: $seal"
    return 0
  fi
  tmp=$(umask 077; mktemp "${path%/*}/.seal.XXXXXX") || die "cannot stage resource event seal"
  if ! { sha256_file "$path" >"$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$seal"; }; then
    rm -f "$tmp"
    die "cannot publish resource event seal: $seal"
  fi
}

journal_sealed() {
  local path=$1 seal
  seal=$(journal_seal_path "$path")
  [ -f "$seal" ] && [ ! -L "$seal" ] && [ -O "$seal" ] || return 1
  [ "$(cat "$seal" 2>/dev/null)" = "$(sha256_file "$path")" ]
}

validate_event_journal() {
  local path=$1
  safe_regular_or_absent "$path" || return 1
  [ -e "$path" ] || return 0
  [ "$(wc -c <"$path" | tr -d ' ')" -le 10485760 ] || return 1
  journal_sealed "$path" && return 0
  jq -Rse --arg schema "$EVENT_SCHEMA" '
    split("\n")[:-1] as $lines |
    ($lines | length) > 0 and
    all($lines[];
      . as $line |
      ($line | length) > 0 and
      ((try ($line | fromjson) catch null) as $e |
       $e != null and $e.schema == $schema and
       ($e.event_id | type) == "string" and ($e.event_id | test("^[0-9a-f]{64}$")) and
       ($e.ts | type) == "string" and ((try ($e.ts | fromdateiso8601) catch null) != null) and
       ($e.kind | type) == "string" and
       ($e.task_id | type) == "string"))
  ' "$path" >/dev/null 2>&1 || return 1
  paste <(jq -r '.event_id' "$path") <(jq -cS 'del(.event_id)' "$path") |
    while IFS=$'\t' read -r actual canonical; do
      [ -n "$canonical" ] && [ "$(sha256_text "$canonical")" = "$actual" ] || exit 1
    done || return 1
  journal_seal "$path"
}

prune_event_retention() {
  local event_ts=$1 cutoff path tmp count
  cutoff=$(jq -nr --arg ts "$event_ts" '($ts | fromdateiso8601) - (90 * 86400)') \
    || die "cannot calculate resource-event retention horizon"
  for path in "$DATA/resource-events/"*.jsonl; do
    [ -e "$path" ] || [ -L "$path" ] || continue
    validate_event_journal "$path" \
      || die "resource event journal is corrupt or unsafe: $path"
    tmp=$(umask 077; mktemp "${path%/*}/.retention.XXXXXX") \
      || die "cannot stage resource-event retention"
    jq -c --argjson cutoff "$cutoff" 'select((.ts | fromdateiso8601) >= $cutoff)' "$path" >"$tmp" \
      || { rm -f "$tmp"; die "cannot apply resource-event retention"; }
    chmod 600 "$tmp" || { rm -f "$tmp"; die "cannot protect retained resource events"; }
    count=$(wc -c <"$tmp" | tr -d ' ')
    if [ "$count" -eq 0 ]; then
      rm -f "$tmp" "$path" || die "cannot retire expired resource events"
    elif cmp -s "$tmp" "$path"; then
      rm -f "$tmp"
      continue
    else
      mv -f "$tmp" "$path" || { rm -f "$tmp"; die "cannot publish retained resource events"; }
    fi
    journal_seal "$path"
  done
}

append_event() {
  local event=$1 ts path dir id line tmp
  ts=$(printf '%s\n' "$event" | jq -r '.ts')
  path=$(event_file_for_ts "$ts")
  dir=${path%/*}
  private_dir "$dir"
  event_lock_acquire
  prune_event_retention "$ts"
  validate_event_journal "$path" || die "resource event journal is corrupt or unsafe: $path"
  line=$(printf '%s\n' "$event" | jq -cS 'del(.event_id)') || die "cannot canonicalize resource event"
  id=$(sha256_text "$line")
  event=$(printf '%s\n' "$event" | jq -cS --arg id "$id" '.event_id = $id') || die "cannot identify resource event"
  if [ -e "$path" ] && jq -Rre --arg id "$id" 'fromjson? | select(.event_id == $id) | .event_id' "$path" 2>/dev/null | grep -qx "$id"; then
    EVENT_ID=$id
    event_lock_release
    return 0
  fi
  tmp=$(umask 077; mktemp "$dir/.events.XXXXXX") || die "cannot stage resource event journal"
  if [ -e "$path" ]; then
    cat "$path" >"$tmp" || { rm -f "$tmp"; die "cannot stage existing resource events"; }
  fi
  printf '%s\n' "$event" >>"$tmp" || { rm -f "$tmp"; die "cannot stage resource event"; }
  chmod 600 "$tmp" || { rm -f "$tmp"; die "cannot protect resource event journal"; }
  mv -f "$tmp" "$path" || { rm -f "$tmp"; die "cannot publish resource event journal"; }
  journal_seal "$path"
  EVENT_ID=$id
  event_lock_release
}

publish_evaluation() {
  local id=$1 evaluation=$2 eval_id path
  eval_id=$(sha256_text "$(printf '%s\n' "$evaluation" | jq -cS .)")
  evaluation=$(printf '%s\n' "$evaluation" | jq -cS --arg id "$eval_id" '.evaluation_id = $id')
  path="$DATA/burn-evaluations/$id-$eval_id.json"
  if [ -e "$path" ]; then
    [ -f "$path" ] && [ ! -L "$path" ] || die "unsafe burn evaluation path: $path"
    [ "$(jq -cS . "$path" 2>/dev/null)" = "$evaluation" ] || die "burn evaluation id collision: $path"
  else
    atomic_json_write "$path" "$evaluation"
  fi
  EVALUATION_ID=$eval_id
}

apply_evaluation() {
  local id=$1 result=$2 emit=$3 budget event reason state previous_state previous_reason pause evaluation
  budget=$(printf '%s\n' "$result" | jq -c '.updated_budget')
  state=$(printf '%s\n' "$result" | jq -r '.decision.state')
  reason=$(printf '%s\n' "$result" | jq -r '.decision.reason // ""')
  previous_state=$(printf '%s\n' "$BUDGET" | jq -r '.guard_state')
  previous_reason=$(printf '%s\n' "$BUDGET" | jq -r '.decision_reason // ""')
  event=$(printf '%s\n' "$result" | jq -c '.event_base')

  # Baseline, milestone, any decision transition, and auto-resume are finalized
  # events. Healthy monitor polls only update the bounded current snapshot.
  if [ "$emit" = 1 ] || [ "$state:$reason" != "$previous_state:$previous_reason" ] \
    || [ "$(printf '%s\n' "$result" | jq -r '.decision.auto_resumed')" = true ]; then
    append_event "$event"
  fi
  if [ "$state" = pause_pending ] && [ "$previous_state" != pause_pending ] && [ "$previous_state" != paused ]; then
    evaluation=$(printf '%s\n' "$result" | jq -c '.evaluation_base')
    publish_evaluation "$id" "$evaluation"
    pause=$(printf '%s\n' "$result" | jq -c --arg event "$EVENT_ID" --arg eval "$EVALUATION_ID" \
      '.pause_base + {trigger_event_id: $event, evaluation_id: $eval}')
    atomic_json_write "$(pause_path "$id")" "$pause"
  elif [ "$(printf '%s\n' "$result" | jq -r '.decision.escalated')" = true ] && [ -f "$(pause_path "$id")" ]; then
    # An escalation keeps the original request identity, time, origin, and
    # boundary evidence; only the current reason and its evidence change.
    evaluation=$(printf '%s\n' "$result" | jq -c '.evaluation_base')
    publish_evaluation "$id" "$evaluation"
    pause=$(jq -ce --arg ts "$(printf '%s\n' "$result" | jq -r '.event_base.ts')" --arg reason "$reason" \
      --arg event "$EVENT_ID" --arg eval "$EVALUATION_ID" '
      .reason_history = (((.reason_history // []) + [{reason: .reason, until: $ts}]) | .[-8:]) |
      .reason=$reason | .escalated_at=$ts | .escalation_event_id=$event | .escalation_evaluation_id=$eval' \
      "$(pause_path "$id")") || die "cannot record resource pause escalation"
    atomic_json_write "$(pause_path "$id")" "$pause"
  elif [ "$(printf '%s\n' "$result" | jq -r '.decision.auto_resumed')" = true ]; then
    if [ -f "$(pause_path "$id")" ]; then
      pause=$(jq -ce --arg ts "$(printf '%s\n' "$result" | jq -r '.event_base.ts')" \
        --arg event "$EVENT_ID" '.state="resumed" | .resumed_at=$ts | .resume_authority="auto_near_reset" | .resume_event_id=$event' \
        "$(pause_path "$id")") || die "cannot update automatic resume outcome"
      atomic_json_write "$(pause_path "$id")" "$pause"
    fi
  fi
  atomic_json_write "$(budget_path "$id")" "$budget"
  BUDGET=$budget
  if [ "$(printf '%s\n' "$result" | jq -r '.decision.auto_resumed')" = true ] && [ "$MONITOR_MODE" != 1 ]; then
    rearm_monitor "$id"
  fi
  printf '%s\n' "$result" | jq -c '.decision'
  [ "$state" = active ] && return 0
  return 3
}

register_monitor() {
  local id=$1 interval=$2 source
  source="resource-$id"
  "$SCRIPT_DIR/fm-procevent.sh" register resource "$source" -- \
    "$SCRIPT_DIR/fm-procevent-resource.sh" poll "$id" --interval "$interval" >/dev/null \
    || die "cannot register resource monitor for task $id"
}

# One registration per task source id: re-registering the same argv replaces
# the record rather than adding a second monitor.
rearm_monitor() {
  local id=$1
  [ "$(printf '%s\n' "$BUDGET" | jq -r 'if .monitor_enabled == false then "off" else "on" end')" = on ] || return 0
  register_monitor "$id" "$(printf '%s\n' "$BUDGET" | jq -r '.monitor_interval_seconds')"
}

cmd_start() {
  local id=${1:-} provider='' account='' model=default snapshot='' tranche=$DEFAULT_TRANCHE
  local attribution=unknown interval=$DEFAULT_INTERVAL no_monitor=0 now_arg='' now scopes_json concurrent_json budget result
  local -a scopes=() concurrent=()
  slug_valid "$id" || die "task id must be a privacy-safe slug"
  shift || true
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --provider) [ -n "${2-}" ] || die "--provider needs a value"; provider=$2; shift 2 ;;
      --account-key) [ -n "${2-}" ] || die "--account-key needs a value"; account=$2; shift 2 ;;
      --model) [ -n "${2-}" ] || die "--model needs a value"; model=$2; shift 2 ;;
      --scope) [ -n "${2-}" ] || die "--scope needs a value"; scopes+=("$2"); shift 2 ;;
      --snapshot) [ -n "${2-}" ] || die "--snapshot needs a path"; snapshot=$2; shift 2 ;;
      --tranche-points) positive_number "${2-}" || die "--tranche-points needs a number greater than 0 and at most 100"; tranche=$2; shift 2 ;;
      --attribution) attribution=${2-}; shift 2 ;;
      --concurrent-task) slug_valid "${2-}" || die "--concurrent-task needs a privacy-safe task id"; concurrent+=("$2"); shift 2 ;;
      --interval) positive_int "${2-}" || die "--interval needs positive integer seconds"; interval=$2; shift 2 ;;
      --no-monitor) no_monitor=1; shift ;;
      --now) now_arg=${2-}; shift 2 ;;
      *) usage ;;
    esac
  done
  provider_valid "$provider" || die "--provider needs a canonical quota provider id"
  case "$account" in *[!A-Za-z0-9._:-]*) die "--account-key contains unsafe characters" ;; esac
  case "$model" in *[!A-Za-z0-9._:/-]*) die "--model contains unsafe characters" ;; esac
  case "$attribution" in exact|dominant|shared|unknown) ;; *) die "--attribution must be exact, dominant, shared, or unknown" ;; esac
  if [ "${#concurrent[@]}" -gt 0 ] && [ "$attribution" = exact ]; then
    die "exact attribution contradicts declared concurrent tasks"
  fi
  local scope
  if [ "${#scopes[@]}" -gt 0 ]; then
    for scope in "${scopes[@]}"; do
      case "$scope" in ''|*[!A-Za-z0-9._:-]*) die "quota scope contains unsafe characters: $scope" ;; esac
    done
  fi
  now=$(now_resolve "$now_arg")
  snapshot_read "$snapshot"
  if [ "${#scopes[@]}" -gt 0 ]; then
    scopes_json=$(scopes_json_from_array "${scopes[@]}")
  else
    scopes_json='[]'
  fi
  if [ "${#concurrent[@]}" -gt 0 ]; then
    concurrent_json=$(concurrent_json_from_array "${concurrent[@]}")
  else
    concurrent_json='[]'
  fi
  budget=$(build_baseline_budget "$id" "$provider" "$account" "$model" "$scopes_json" \
    "$attribution" "$concurrent_json" "$tranche" "$interval" "$now")
  budget=$(printf '%s\n' "$budget" | jq -c --argjson enabled "$([ "$no_monitor" = 1 ] && echo false || echo true)" \
    '.monitor_enabled=$enabled')

  lock_acquire "$id"
  if [ -e "$(budget_path "$id")" ]; then
    load_budget "$id"
    if [ "$(printf '%s\n' "$BUDGET" | jq -r '.budget_id')" \
      = "$(printf '%s\n' "$budget" | jq -r '.budget_id')" ]; then
      if [ "$no_monitor" != 1 ] && [ "$(printf '%s\n' "$BUDGET" | jq -r '.guard_state')" = active ]; then
        register_monitor "$id" "$interval"
      fi
      printf '%s\n' "$BUDGET" | jq -c '{state:.guard_state, reason:.decision_reason, idempotent:true}'
      return 0
    fi
    die "resource budget already exists with different task-start evidence for task $id"
  fi
  BUDGET=$budget
  result=$(evaluate_budget "$budget" "$now" task_baseline)
  if apply_evaluation "$id" "$result" 1; then
    [ "$no_monitor" = 1 ] || register_monitor "$id" "$interval"
    return 0
  fi
  return 3
}

MONITOR_MODE=0
parse_snapshot_now() {
  SNAPSHOT_ARG=
  NOW_ARG=
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --snapshot) [ -n "${2-}" ] || die "--snapshot needs a path"; SNAPSHOT_ARG=$2; shift 2 ;;
      --now) NOW_ARG=${2-}; shift 2 ;;
      --monitor) MONITOR_MODE=1; shift ;;
      *) usage ;;
    esac
  done
}

cmd_check() {
  local id=${1:-} now result snapshot failure=''
  slug_valid "$id" || die "task id must be a privacy-safe slug"
  shift || true
  parse_snapshot_now "$@"
  now=$(now_resolve "$NOW_ARG")
  if [ "$MONITOR_MODE" = 1 ]; then
    # A monitor must never retire on a bad read while the budget stays active:
    # unavailable or malformed telemetry becomes a cooperative pause instead.
    if snapshot=$(snapshot_read "$SNAPSHOT_ARG" 2>/dev/null && printf '%s' "$SNAPSHOT"); then
      SNAPSHOT=$snapshot
    else
      failure=telemetry_read_failed
    fi
  else
    snapshot_read "$SNAPSHOT_ARG"
  fi
  lock_acquire "$id"
  load_budget "$id"
  result=$(evaluate_budget "$BUDGET" "$now" window_snapshot '' "$failure")
  apply_evaluation "$id" "$result" 0
}

cmd_milestone() {
  local id=${1:-} type='' snapshot='' now_arg='' now result
  slug_valid "$id" || die "task id must be a privacy-safe slug"
  shift || true
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --type) type=${2-}; shift 2 ;;
      --snapshot) snapshot=${2-}; shift 2 ;;
      --now) now_arg=${2-}; shift 2 ;;
      *) usage ;;
    esac
  done
  case "$type" in checks-green|report-accepted|branch-landed|pr-merged) ;; *) die "unsupported milestone type: $type" ;; esac
  now=$(now_resolve "$now_arg")
  snapshot_read "$snapshot"
  lock_acquire "$id"
  load_budget "$id"
  result=$(evaluate_budget "$BUDGET" "$now" task_milestone "$type")
  apply_evaluation "$id" "$result" 1
}

# Prints "<verb> <at-epoch>" for the newest status event; the epoch is empty
# when that event carries no [at=<epoch>] stamp.
latest_status_event() {
  local path=$1
  [ -f "$path" ] || return 1
  awk '
    /^[[:space:]]*(working|needs-decision|blocked|paused|done|failed|resolved)([[:space:]]+\[|[[:space:]]*:)/ {
      line=$0; sub(/^[[:space:]]*/, "", line); v=line; sub(/[[:space:]:\[].*$/, "", v); verb=v
      at=""
      if (match(line, /\[at=[0-9]+\]/)) at=substr(line, RSTART + 4, RLENGTH - 5)
    }
    END { if (verb != "") print verb " " at; else exit 1 }
  ' "$path"
}

cmd_pause() {
  local id=${1:-} now_arg='' now budget pause event status_verb='' status_at='' requested ts
  local pre_dispatch=0 boundary=worker_reported
  slug_valid "$id" || die "task id must be a privacy-safe slug"
  shift || true
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --now) now_arg=${2-}; shift 2 ;;
      --pre-dispatch) pre_dispatch=1; shift ;;
      *) usage ;;
    esac
  done
  now=$(now_resolve "$now_arg")
  ts=$(epoch_iso "$now")
  lock_acquire "$id"
  load_budget "$id"
  [ "$(printf '%s\n' "$BUDGET" | jq -r '.guard_state')" = pause_pending ] \
    || die "task $id has no resource pause pending"
  read -r status_verb status_at <<<"$(latest_status_event "$STATE/$id.status" || true)" || true
  pause=$(jq -ce --arg schema "$PAUSE_SCHEMA" --arg task "$id" 'select(.schema == $schema and .task_id == $task)' \
    "$(pause_path "$id")" 2>/dev/null) || die "resource pause record is corrupt for task $id"
  if [ "$pre_dispatch" = 1 ]; then
    [ "$(printf '%s\n' "$BUDGET" | jq -r '.dispatch_state // "dispatched"')" = pre_dispatch ] \
      || die "task $id has been dispatched; wait for the worker's safe boundary"
    [ -z "$status_verb" ] \
      || die "task $id already has worker status; wait for the worker's safe boundary"
    boundary=pre_dispatch
  else
    [ "$status_verb" = paused ] \
      || die "task $id has not reported a safe paused boundary; no lifecycle action was taken"
    requested=$(printf '%s\n' "$pause" | jq -er '.requested_at | fromdateiso8601') \
      || die "resource pause record has no request time for task $id"
    epoch_valid "$status_at" && [ "$status_at" -ge "$requested" ] \
      || die "task $id's paused event predates the resource pause request; no lifecycle action was taken"
  fi
  budget=$(printf '%s\n' "$BUDGET" | jq -c --arg ts "$ts" '.guard_state="paused" | .paused_at=$ts')
  event=$(printf '%s\n' "$budget" | jq -c --arg schema "$EVENT_SCHEMA" --arg ts "$ts" --arg boundary "$boundary" '
    {
      schema:$schema, ts:$ts, kind:"pause", task_id:.task_id,
      budget_id:.budget_id, budget_revision:.revision, provider:.provider,
      account_key:.account_key, model:.model, source:"resource-guard",
      attribution_confidence:.attribution_confidence, concurrent_tasks:.concurrent_tasks,
      windows:.windows,
      decision:{state:"paused", reason:.decision_reason, safe_boundary:$boundary,
        resume_required:(if .decision_reason == "reserve_floor" then "auto_near_reset_or_captain" else "captain_decision_or_redesign" end)},
      milestone:null
    }')
  append_event "$event"
  pause=$(printf '%s\n' "$pause" | jq -c --arg ts "$ts" --arg event "$EVENT_ID" --arg boundary "$boundary" \
    '.state="paused" | .safe_boundary=$boundary | .paused_at=$ts | .pause_event_id=$event')
  atomic_json_write "$(pause_path "$id")" "$pause"
  atomic_json_write "$(budget_path "$id")" "$budget"
  BUDGET=$budget
  # Only the proven near-reset rule can reopen a reserve pause, so keep one
  # monitor watching for that proof.
  if [ "$(printf '%s\n' "$budget" | jq -r '.decision_reason')" = reserve_floor ]; then
    rearm_monitor "$id"
  fi
  printf 'paused: %s reason=%s\n' "$id" "$(printf '%s\n' "$budget" | jq -r '.decision_reason')"
}

cmd_dispatch() {
  local id=${1:-} rollback='' now_arg='' now ts budget current
  slug_valid "$id" || die "task id must be a privacy-safe slug"
  shift || true
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --rollback) [ -n "${2-}" ] || die "--rollback needs the dispatched-at token"; rollback=$2; shift 2 ;;
      --now) now_arg=${2-}; shift 2 ;;
      *) usage ;;
    esac
  done
  lock_acquire "$id"
  load_budget "$id"
  current=$(printf '%s\n' "$BUDGET" | jq -r '.dispatch_state // "dispatched"')
  if [ -n "$rollback" ]; then
    if [ "$current" = dispatched ] && [ "$(printf '%s\n' "$BUDGET" | jq -r '.dispatched_at // ""')" = "$rollback" ]; then
      budget=$(printf '%s\n' "$BUDGET" | jq -c '.dispatch_state="pre_dispatch" | del(.dispatched_at)')
      atomic_json_write "$(budget_path "$id")" "$budget"
      printf 'dispatch-rolled-back: %s\n' "$id"
    else
      printf 'dispatch-unchanged: %s\n' "$id"
    fi
    return 0
  fi
  if [ "$(printf '%s\n' "$BUDGET" | jq -r '.guard_state')" != active ]; then
    printf 'error: task %s resource budget is %s; do not dispatch until the guard authorizes it\n' \
      "$id" "$(printf '%s\n' "$BUDGET" | jq -r '.guard_state')" >&2
    exit 3
  fi
  if [ "$current" = dispatched ]; then
    rearm_monitor "$id"
    printf 'already-dispatched: %s at=%s\n' "$id" "$(printf '%s\n' "$BUDGET" | jq -r '.dispatched_at // ""')"
    return 0
  fi
  now=$(now_resolve "$now_arg")
  ts=$(epoch_iso "$now")
  budget=$(printf '%s\n' "$BUDGET" | jq -c --arg ts "$ts" '.dispatch_state="dispatched" | .dispatched_at=$ts')
  atomic_json_write "$(budget_path "$id")" "$budget"
  BUDGET=$budget
  rearm_monitor "$id"
  printf 'dispatched: %s at=%s\n' "$id" "$ts"
}

cmd_bind_authority() {
  local id=${1:-} authority=${2:-} pause identity updated
  slug_valid "$id" || die "task id must be a privacy-safe slug"
  slug_valid "$authority" || die "authority task id must be a privacy-safe slug"
  [ "$#" -eq 2 ] || usage
  lock_acquire "$id"
  load_budget "$id"
  [ "$(printf '%s\n' "$BUDGET" | jq -r '.guard_state')" = paused ] \
    || die "task $id is not safely paused"
  identity=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
    "$SCRIPT_DIR/fm-captain-hold.sh" open "$authority" --identity 2>/dev/null) \
    || die "authority task $authority is not actively held for the captain"
  [ -n "$identity" ] || die "authority task $authority exposed no lifecycle identity"
  pause=$(jq -ce --arg schema "$PAUSE_SCHEMA" --arg task "$id" 'select(.schema == $schema and .task_id == $task)' \
    "$(pause_path "$id")" 2>/dev/null) || die "resource pause record is corrupt for task $id"
  if [ "$(printf '%s\n' "$pause" | jq -r '.authority_task // ""')" != "" ]; then
    [ "$(printf '%s\n' "$pause" | jq -r '.authority_task')" = "$authority" ] \
      && [ "$(printf '%s\n' "$pause" | jq -r '.authority_lifecycle')" = "$identity" ] \
      || die "resource pause is already bound to a different captain authority lifecycle"
    printf 'authority-bound: %s %s (idempotent)\n' "$id" "$authority"
    return 0
  fi
  updated=$(printf '%s\n' "$pause" | jq -c --arg authority "$authority" --arg identity "$identity" \
    '.authority_task=$authority | .authority_lifecycle=$identity')
  atomic_json_write "$(pause_path "$id")" "$updated"
  printf 'authority-bound: %s %s\n' "$id" "$authority"
}

json_field() { printf '%s\n' "$1" | jq -cr "$2"; }

# A captain-authorized resume after unavailable or reset-discontinuous
# telemetry starts a fresh versioned baseline from the current valid snapshot.
# Burn across the discontinuity stays unmeasured; it is never estimated.
captain_rebaseline() {
  local budget=$1 id=$2 now=$3 ts=$4 authority=$5 digest=$6 fresh
  fresh=$(build_baseline_budget "$id" "$(json_field "$budget" .provider)" \
    "$(json_field "$budget" '.account_key // ""')" "$(json_field "$budget" '.model // "default"')" \
    "$(json_field "$budget" .requested_scopes)" "$(json_field "$budget" .attribution_confidence)" \
    "$(json_field "$budget" .concurrent_tasks)" "$(json_field "$budget" .tranche_points)" \
    "$(json_field "$budget" .monitor_interval_seconds)" "$now")
  [ "$(printf '%s\n' "$fresh" | jq -r '.baseline_telemetry_reasons | length')" = 0 ] \
    || die "current telemetry cannot establish a fresh baseline; the captain answer was not spent"
  jq -cn --argjson b "$budget" --argjson f "$fresh" --arg ts "$ts" --argjson now "$now" \
    --arg authority "$authority" --arg digest "$digest" '
    $b + {
      applicable_scopes: $f.applicable_scopes,
      windows: $f.windows,
      baseline_telemetry_reasons: [],
      telemetry_reasons: [],
      telemetry_status: "known",
      rebaselined_at: $ts,
      rebaselined_epoch: $now,
      rebaselines: (($b.rebaselines // []) + [{
        at: $ts, revision: $b.revision, discarded_reasons: ($b.telemetry_reasons // []),
        authority_task: $authority, decision_digest: $digest}])
    }'
}

resolution_field() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -1; }

decision_budget_value() {
  local file=$1 key=$2 count value
  count=$(grep -Ec "^${key}=[0-9]+([.][0-9]+)?$" "$file" 2>/dev/null || true)
  [ "$count" -eq 1 ] || return 1
  value=$(sed -n "s/^${key}=//p" "$file")
  positive_number "$value" || return 1
  printf '%s' "$value"
}

cmd_resume() {
  local id=${1:-} authority='' decision_file='' snapshot='' now_arg='' now ts pause durable digest expected decision_text
  local points tranche budget result event resolution mode pause_reason rebaselined=false
  slug_valid "$id" || die "task id must be a privacy-safe slug"
  shift || true
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --authority-task) authority=${2-}; shift 2 ;;
      --decision-file) decision_file=${2-}; shift 2 ;;
      --snapshot) snapshot=${2-}; shift 2 ;;
      --now) now_arg=${2-}; shift 2 ;;
      *) usage ;;
    esac
  done
  slug_valid "$authority" || die "--authority-task needs a privacy-safe task id"
  [ -f "$decision_file" ] && [ ! -L "$decision_file" ] || die "--decision-file must be a regular file"
  [ "$(wc -c <"$decision_file" | tr -d ' ')" -le 8192 ] || die "decision file exceeds the captain-answer bound"
  points=$(decision_budget_value "$decision_file" resource_budget_points) \
    || die "captain decision needs exactly one resource_budget_points=<number> line"
  tranche=$(decision_budget_value "$decision_file" resource_tranche_points 2>/dev/null || true)
  decision_text=$(cat "$decision_file") || die "cannot read decision file"
  [ -n "$decision_text" ] || die "decision file must not be empty"
  digest=$(sha256_text "$decision_text")
  now=$(now_resolve "$now_arg")
  ts=$(epoch_iso "$now")
  snapshot_read "$snapshot"
  lock_acquire "$id"
  load_budget "$id"
  [ "$(printf '%s\n' "$BUDGET" | jq -r '.guard_state')" = paused ] \
    || die "task $id is not safely paused"
  pause=$(jq -ce --arg schema "$PAUSE_SCHEMA" --arg task "$id" 'select(.schema == $schema and .task_id == $task)' \
    "$(pause_path "$id")" 2>/dev/null) || die "resource pause record is corrupt for task $id"
  [ "$(printf '%s\n' "$pause" | jq -r '.authority_task // ""')" = "$authority" ] \
    || die "resource pause is not bound to authority task $authority"
  expected=$(printf '%s\n' "$pause" | jq -r '.authority_lifecycle // ""')
  pause_reason=$(printf '%s\n' "$pause" | jq -r '.reason')
  resolution=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
    "$SCRIPT_DIR/fm-captain-hold.sh" resolution "$authority" --lifecycle "$expected" 2>/dev/null) \
    || die "captain authority task $authority has no matching durable answer"
  durable=$(resolution_field "$resolution" decision_digest)
  mode=$(resolution_field "$resolution" mode)
  [ "$mode" = answered ] || die "captain authority task $authority resolved with mode $mode, not answered"
  [ -n "$durable" ] && [ "$durable" = "$digest" ] \
    || die "decision file does not match the durable captain answer on $authority"

  budget=$(printf '%s\n' "$BUDGET" | jq -c --arg points "$points" --arg tranche "$tranche" --arg ts "$ts" \
    --arg pause_reason "$pause_reason" --arg authority "$authority" --arg digest "$digest" '
     .revision += 1 |
     .pause_after_points=($points|tonumber) |
     (if $tranche != "" then .tranche_points=($tranche|tonumber) else . end) |
     (if $pause_reason == "repeated_review_theme" or $pause_reason == "review_loop_exhausted" then
       .review.captain_budget_revisions += [{at:$ts,authority_task:$authority,decision_digest:$digest}] |
       .review.creator=null | .review.critic=null | .review.corrections=[] |
       .review.deltas=[] | .review.failures=[] | .review.final=null | .review.last_failure_theme=null |
       .review.consecutive_same_theme_failures=0 | .review.post_correction_failures=0
      else . end) |
     .guard_state="active" | .decision_reason=null | .revised_at=$ts')
  BUDGET=$budget
  result=$(evaluate_budget "$budget" "$now" resume)
  if [ "$(printf '%s\n' "$result" | jq -r '.decision.reason // ""')" = telemetry_unavailable ]; then
    budget=$(captain_rebaseline "$budget" "$id" "$now" "$ts" "$authority" "$digest")
    rebaselined=true
    BUDGET=$budget
    result=$(evaluate_budget "$budget" "$now" resume)
  fi
  if [ "$(printf '%s\n' "$result" | jq -r '.decision.state')" != active ]; then
    die "revised budget still crosses an active reserve or telemetry boundary"
  fi
  event=$(printf '%s\n' "$result" | jq -c --arg authority "$authority" --arg digest "$digest" \
    --argjson rebaselined "$rebaselined" \
    '.event_base | .kind="resume" | .decision.resume_authority="captain" |
     .decision.authority_task=$authority | .decision.decision_digest=$digest |
     .decision.rebaselined=$rebaselined')
  append_event "$event"
  budget=$(printf '%s\n' "$result" | jq -c '.updated_budget')
  pause=$(printf '%s\n' "$pause" | jq -c --arg ts "$ts" --arg event "$EVENT_ID" --arg digest "$digest" \
    '.state="resumed" | .resumed_at=$ts | .resume_authority="captain" |
     .authority_decision_digest=$digest | .resume_event_id=$event')
  atomic_json_write "$(pause_path "$id")" "$pause"
  atomic_json_write "$(budget_path "$id")" "$budget"
  BUDGET=$budget
  rearm_monitor "$id"
  printf 'resumed: %s revision=%s\n' "$id" "$(printf '%s\n' "$budget" | jq -r '.revision')"
}

review_event() {
  local budget=$1 now=$2 phase=$3 head=$4 actor=$5 theme=$6 state=$7 reason=$8 provider=$9 family=${10} same_reason=${11}
  local ts event
  ts=$(epoch_iso "$now")
  event=$(printf '%s\n' "$budget" | jq -c --arg schema "$EVENT_SCHEMA" --arg ts "$ts" \
    --arg phase "$phase" --arg head "$head" --arg actor "$actor" --arg theme "$theme" \
    --arg state "$state" --arg reason "$reason" --arg review_provider "$provider" \
    --arg family "$family" --arg same_reason "$same_reason" '
    {
      schema:$schema, ts:$ts, kind:"review_policy", task_id:.task_id,
      budget_id:.budget_id, budget_revision:.revision, provider:.provider,
      account_key:.account_key, model:.model, source:"resource-guard",
      attribution_confidence:.attribution_confidence, concurrent_tasks:.concurrent_tasks,
      windows:[], decision:{state:$state, reason:(if $reason == "" then null else $reason end),
        resume_required:(if $state == "active" then "none" else "redesign_rescope_or_captain" end)},
      milestone:{type:$phase, head:$head, actor:$actor, provider:$review_provider, model_family:$family,
        same_family_reason:(if $same_reason == "" then null else $same_reason end),
        theme:(if $theme == "" then null else $theme end)}
    }')
  append_event "$event"
}

cmd_review() {
  local id=${1:-} phase=${2:-} head='' actor='' theme='' provider='' family='' same_reason=''
  local now_arg='' now ts budget review state reason='' creator creator_head creator_actor creator_provider creator_family
  local failure_stage
  slug_valid "$id" || die "task id must be a privacy-safe slug"
  shift 2 2>/dev/null || true
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --head) head=${2-}; shift 2 ;;
      --actor) actor=${2-}; shift 2 ;;
      --theme) theme=${2-}; shift 2 ;;
      --provider) provider=${2-}; shift 2 ;;
      --family) family=${2-}; shift 2 ;;
      --same-family-reason) same_reason=${2-}; shift 2 ;;
      --now) now_arg=${2-}; shift 2 ;;
      *) usage ;;
    esac
  done
  case "$phase" in creator|critic|failure|correction|delta|final|redesign|rescope) ;; *) die "unknown review phase: $phase" ;; esac
  case "$head" in ''|*[!0-9a-fA-F]*) die "--head needs a hexadecimal git object id" ;; esac
  [ "${#head}" -ge 7 ] && [ "${#head}" -le 64 ] || die "--head length is invalid"
  slug_valid "$actor" || die "--actor needs a privacy-safe independent-session id"
  provider_valid "$provider" || die "--provider needs a canonical provider id"
  slug_valid "$family" || die "--family needs a privacy-safe model-family id"
  [ -z "$same_reason" ] || slug_valid "$same_reason" \
    || die "--same-family-reason must be a privacy-safe reason slug"
  if [ "$phase" = failure ] || [ "$phase" = correction ] || [ "$phase" = redesign ] || [ "$phase" = rescope ]; then
    slug_valid "$theme" || die "--theme is required for $phase"
  elif [ -n "$theme" ]; then
    slug_valid "$theme" || die "--theme must be privacy-safe"
  fi
  now=$(now_resolve "$now_arg")
  ts=$(epoch_iso "$now")
  lock_acquire "$id"
  load_budget "$id"
  review=$(printf '%s\n' "$BUDGET" | jq -c '.review')
  state=$(printf '%s\n' "$BUDGET" | jq -r '.guard_state')
  [ "$(printf '%s\n' "$review" | jq -r '.final // empty')" = "" ] \
    || die "final review is already durable; the review ledger is closed"
  if [ "$phase" = failure ]; then
    if printf '%s\n' "$review" | jq -e --arg head "$head" \
      --arg actor "$actor" --arg provider "$provider" --arg family "$family" --arg theme "$theme" '
      any((.failures // [])[];
        .head == $head and .actor == $actor and
        .provider == $provider and .model_family == $family and .theme == $theme)' >/dev/null; then
      printf 'review-recorded: %s failure (idempotent)\n' "$id"
      return 0
    fi
    if [ "$(printf '%s\n' "$review" | jq -r '.deltas | length')" -gt 0 ]; then
      failure_stage="delta"
    else
      failure_stage=critic
    fi
  fi
  if [ "$state" = paused ] || [ "$state" = pause_pending ]; then
    case "$phase:$(printf '%s\n' "$BUDGET" | jq -r '.decision_reason // ""')" in
      redesign:repeated_review_theme|rescope:repeated_review_theme) ;;
      redesign:review_loop_exhausted|rescope:review_loop_exhausted) ;;
      *) die "task $id is resource-paused; review work cannot advance" ;;
    esac
  fi

  case "$phase" in
    creator)
      if [ "$(printf '%s\n' "$review" | jq -r '.creator // empty')" != "" ]; then
        printf '%s\n' "$review" | jq -e --arg head "$head" --arg actor "$actor" \
          --arg provider "$provider" --arg family "$family" \
          '.creator.head == $head and .creator.actor == $actor and
           .creator.provider == $provider and .creator.model_family == $family' >/dev/null \
          || die "creator pass is already recorded; a second creator pass is outside the bounded protocol"
        printf 'review-recorded: %s creator (idempotent)\n' "$id"
        return 0
      fi
      review=$(printf '%s\n' "$review" | jq -c --arg head "$head" --arg actor "$actor" --arg ts "$ts" \
        --arg provider "$provider" --arg family "$family" \
        '.creator={head:$head,actor:$actor,provider:$provider,model_family:$family,at:$ts}')
      ;;
    critic)
      creator=$(printf '%s\n' "$review" | jq -r '.creator.actor // ""')
      creator_head=$(printf '%s\n' "$review" | jq -r '.creator.head // ""')
      [ -n "$creator" ] || die "critic pass requires a recorded creator pass"
      [ "$actor" != "$creator" ] || die "critic must be an independent session from the creator"
      [ "$head" = "$creator_head" ] || die "first independent critic must review the frozen creator head"
      creator_provider=$(printf '%s\n' "$review" | jq -r '.creator.provider')
      creator_family=$(printf '%s\n' "$review" | jq -r '.creator.model_family')
      if [ "$provider:$family" = "$creator_provider:$creator_family" ] && [ -z "$same_reason" ]; then
        die "same provider/model-family critic requires --same-family-reason"
      fi
      [ "$(printf '%s\n' "$review" | jq -r '.critic // empty')" = "" ] \
        || die "independent critic pass is already recorded"
      review=$(printf '%s\n' "$review" | jq -c --arg head "$head" --arg actor "$actor" --arg ts "$ts" \
        --arg provider "$provider" --arg family "$family" --arg same "$same_reason" \
        '.critic={head:$head,actor:$actor,provider:$provider,model_family:$family,
          same_family_reason:(if $same=="" then null else $same end),at:$ts,scope:"full"}')
      ;;
    failure)
      [ "$(printf '%s\n' "$review" | jq -r '.critic // empty')" != "" ] \
        || die "review failure requires a recorded independent critic"
      if [ "$(printf '%s\n' "$review" | jq -r '.deltas | length')" -gt 0 ]; then
        printf '%s\n' "$review" | jq -e --arg head "$head" --arg actor "$actor" \
          --arg provider "$provider" --arg family "$family" '
          .deltas[-1].head == $head and .deltas[-1].actor == $actor and
          .deltas[-1].provider == $provider and .deltas[-1].model_family == $family' >/dev/null \
          || die "review failure does not match the latest focused delta review"
      else
        printf '%s\n' "$review" | jq -e --arg head "$head" --arg actor "$actor" \
          --arg provider "$provider" --arg family "$family" '
          .critic.head == $head and .critic.actor == $actor and
          .critic.provider == $provider and .critic.model_family == $family' >/dev/null \
          || die "review failure does not match the independent critic pass"
      fi
      review=$(printf '%s\n' "$review" | jq -c --arg stage "$failure_stage" --arg head "$head" \
        --arg actor "$actor" --arg provider "$provider" --arg family "$family" --arg theme "$theme" --arg ts "$ts" '
        .failures = ((.failures // []) + [{stage:$stage,head:$head,actor:$actor,provider:$provider,
          model_family:$family,theme:$theme,at:$ts}])')
      if [ "$(printf '%s\n' "$review" | jq -r '.last_failure_theme // ""')" = "$theme" ]; then
        review=$(printf '%s\n' "$review" | jq -c '.consecutive_same_theme_failures += 1')
      else
        review=$(printf '%s\n' "$review" | jq -c --arg theme "$theme" \
          '.last_failure_theme=$theme | .consecutive_same_theme_failures=1')
      fi
      if [ "$(printf '%s\n' "$review" | jq -r '.corrections | length')" -gt 0 ]; then
        review=$(printf '%s\n' "$review" | jq -c '.post_correction_failures = ((.post_correction_failures // 0) + 1)')
      fi
      if [ "$(printf '%s\n' "$review" | jq -r '.consecutive_same_theme_failures')" -ge 2 ]; then
        state=pause_pending
        reason=repeated_review_theme
      elif [ "$(printf '%s\n' "$review" | jq -r '.post_correction_failures // 0')" -ge 1 ]; then
        state=pause_pending
        reason=review_loop_exhausted
      fi
      ;;
    correction)
      [ "$(printf '%s\n' "$review" | jq -r '.critic // empty')" != "" ] \
        || die "correction requires the independent critic pass"
      [ "$(printf '%s\n' "$review" | jq -r '.consecutive_same_theme_failures')" -eq 1 ] \
        || die "correction requires exactly one current review failure"
      [ "$(printf '%s\n' "$review" | jq -r '.last_failure_theme')" = "$theme" ] \
        || die "correction theme does not match the current failure"
      [ "$actor" = "$(printf '%s\n' "$review" | jq -r '.creator.actor')" ] \
        || die "the creator session owns the one accepted correction pass"
      [ "$provider:$family" = "$(printf '%s\n' "$review" | jq -r '.creator | (.provider + ":" + .model_family)')" ] \
        || die "the accepted correction must stay with the recorded creator provider/model family"
      [ "$(printf '%s\n' "$review" | jq -r '.corrections | length')" -eq 0 ] \
        || die "one accepted correction pass is already spent; redesign, re-scope, or obtain a captain decision"
      [ "$head" != "$(printf '%s\n' "$review" | jq -r '.creator.head')" ] \
        || die "correction head must differ from the frozen creator head"
      review=$(printf '%s\n' "$review" | jq -c --arg head "$head" --arg actor "$actor" --arg theme "$theme" --arg ts "$ts" \
        --arg provider "$provider" --arg family "$family" \
        '.corrections += [{head:$head,actor:$actor,provider:$provider,model_family:$family,theme:$theme,at:$ts}]')
      ;;
    delta)
      [ "$(printf '%s\n' "$review" | jq -r '.corrections | length')" -eq 1 ] \
        || die "delta review requires the one accepted correction pass"
      [ "$head" = "$(printf '%s\n' "$review" | jq -r '.corrections[0].head')" ] \
        || die "the focused delta review must cover the accepted correction head"
      if [ "$(printf '%s\n' "$review" | jq -r '.deltas | length')" -gt 0 ]; then
        printf '%s\n' "$review" | jq -e --arg head "$head" --arg actor "$actor" \
          --arg provider "$provider" --arg family "$family" '
          .deltas[0].head == $head and .deltas[0].actor == $actor and
          .deltas[0].provider == $provider and .deltas[0].model_family == $family' >/dev/null \
          || die "the one focused delta review is already spent; continue to the final full review"
        printf 'review-recorded: %s delta (idempotent)\n' "$id"
        return 0
      fi
      [ "$actor" != "$(printf '%s\n' "$review" | jq -r '.creator.actor')" ] \
        || die "delta reviewer must be independent from the creator"
      creator_provider=$(printf '%s\n' "$review" | jq -r '.creator.provider')
      creator_family=$(printf '%s\n' "$review" | jq -r '.creator.model_family')
      if [ "$provider:$family" = "$creator_provider:$creator_family" ] && [ -z "$same_reason" ]; then
        die "same provider/model-family delta review requires --same-family-reason"
      fi
      review=$(printf '%s\n' "$review" | jq -c --arg head "$head" --arg actor "$actor" --arg theme "$theme" --arg ts "$ts" \
        --arg provider "$provider" --arg family "$family" --arg same "$same_reason" \
        '.deltas += [{head:$head,actor:$actor,provider:$provider,model_family:$family,
          same_family_reason:(if $same=="" then null else $same end),
          theme:(if $theme=="" then null else $theme end),at:$ts,scope:"focused"}]')
      ;;
    final)
      creator_actor=$(printf '%s\n' "$review" | jq -r '.creator.actor // ""')
      creator_head=$(printf '%s\n' "$review" | jq -r '.creator.head // ""')
      [ -n "$creator_actor" ] || die "final review requires the creator pass"
      [ "$(printf '%s\n' "$review" | jq -r '.critic // empty')" != "" ] \
        || die "final review requires the independent critic pass"
      if [ "$(printf '%s\n' "$review" | jq -r '.corrections | length')" -eq 0 ]; then
        [ "$(printf '%s\n' "$review" | jq -r '.consecutive_same_theme_failures')" -eq 0 ] \
          || die "final review cannot bypass an unresolved critic failure"
        [ "$head" = "$creator_head" ] \
          || die "an uncorrected final review must cover the frozen creator head"
      else
        [ "$(printf '%s\n' "$review" | jq -r '.corrections | length')" -eq 1 ] \
          || die "final review requires exactly one accepted correction pass"
        [ "$(printf '%s\n' "$review" | jq -r '.deltas | length')" -eq 1 ] \
          || die "a corrected final head requires its focused delta review"
        [ "$(printf '%s\n' "$review" | jq -r '.post_correction_failures // 0')" -eq 0 ] \
          || die "final review cannot bypass a failed correction or delta review"
        [ "$head" = "$(printf '%s\n' "$review" | jq -r '.corrections[0].head')" ] \
          || die "final review must cover the corrected head"
        [ "$head" = "$(printf '%s\n' "$review" | jq -r '.deltas[0].head')" ] \
          || die "final review must cover the delta-reviewed head"
      fi
      [ "$actor" != "$creator_actor" ] || die "final review must be an independent session"
      creator_provider=$(printf '%s\n' "$review" | jq -r '.creator.provider')
      creator_family=$(printf '%s\n' "$review" | jq -r '.creator.model_family')
      if [ "$provider:$family" = "$creator_provider:$creator_family" ] && [ -z "$same_reason" ]; then
        die "same provider/model-family final review requires --same-family-reason"
      fi
      [ "$(printf '%s\n' "$review" | jq -r '.critic.head // ""')" = "$creator_head" ] \
        || die "final review requires the critic of the frozen creator head"
      [ "$(printf '%s\n' "$review" | jq -r '.final // empty')" = "" ] \
        || die "final independent review is already recorded"
      review=$(printf '%s\n' "$review" | jq -c --arg head "$head" --arg actor "$actor" --arg ts "$ts" \
        --arg provider "$provider" --arg family "$family" --arg same "$same_reason" \
        '.final={head:$head,actor:$actor,provider:$provider,model_family:$family,
          same_family_reason:(if $same=="" then null else $same end),at:$ts,scope:"full"}')
      ;;
    redesign|rescope)
      case "$(printf '%s\n' "$BUDGET" | jq -r '.decision_reason // ""')" in
        repeated_review_theme|review_loop_exhausted) ;;
        *) die "$phase is only the circuit-breaker resolution after a stopped review loop" ;;
      esac
      [ "$(printf '%s\n' "$review" | jq -r '.last_failure_theme // ""')" = "$theme" ] \
        || die "$phase theme does not match the stopped review loop"
      review=$(printf '%s\n' "$review" | jq -c --arg kind "$phase" --arg head "$head" --arg actor "$actor" --arg theme "$theme" --arg ts "$ts" \
        --arg provider "$provider" --arg family "$family" '
        .redesigns += [{kind:$kind,head:$head,actor:$actor,provider:$provider,model_family:$family,theme:$theme,at:$ts}] |
        .creator={head:$head,actor:$actor,provider:$provider,model_family:$family,at:$ts} | .critic=null |
        .corrections=[] | .deltas=[] | .failures=[] | .final=null |
        .last_failure_theme=null | .consecutive_same_theme_failures=0 | .post_correction_failures=0')
      state=active
      reason=''
      ;;
  esac

  budget=$(printf '%s\n' "$BUDGET" | jq -c --argjson review "$review" --arg state "$state" --arg reason "$reason" \
    '.review=$review | .guard_state=$state | .decision_reason=(if $reason=="" then null else $reason end)')
  review_event "$budget" "$now" "$phase" "$head" "$actor" "$theme" "$state" "$reason" \
    "$provider" "$family" "$same_reason"
  if [ "$state" = pause_pending ]; then
    local evaluation pause
    evaluation=$(printf '%s\n' "$budget" | jq -c --arg schema "$EVALUATION_SCHEMA" --arg ts "$ts" --arg theme "$theme" \
      --arg reason "$reason" '
      {schema:$schema,task_id:.task_id,trigger_ts:$ts,trigger:$reason,
       budget_id:.budget_id,budget_revision:.revision,windows:[],
       measured_delta:{unit:"review_failures",
         value:(if $reason == "repeated_review_theme" then .review.consecutive_same_theme_failures
                else .review.post_correction_failures end),confidence:"exact"},
       concurrent_tasks:.concurrent_tasks,pause_action:"safe_boundary_pending",
       review:{theme:$theme,consecutive_failures:.review.consecutive_same_theme_failures,
         post_correction_failures:.review.post_correction_failures},
       resume:{required:"redesign_rescope_or_captain",authority_task:null,decision_digest:null}}')
    publish_evaluation "$id" "$evaluation"
    pause=$(printf '%s\n' "$budget" | jq -c --arg schema "$PAUSE_SCHEMA" --arg ts "$ts" --arg event "$EVENT_ID" --arg eval "$EVALUATION_ID" \
      --arg reason "$reason" '
      {schema:$schema,task_id:.task_id,requested_at:$ts,reason:$reason,state:"pause_pending",
       safe_boundary:null,budget_id:.budget_id,budget_revision:.revision,trigger_event_id:$event,evaluation_id:$eval,
       authority_task:null,authority_lifecycle:null,authority_decision_digest:null,resume_authority:null}')
    atomic_json_write "$(pause_path "$id")" "$pause"
  elif { [ "$phase" = redesign ] || [ "$phase" = rescope ]; } && [ -f "$(pause_path "$id")" ]; then
    pause=$(jq -ce --arg ts "$ts" --arg event "$EVENT_ID" --arg phase "$phase" \
      '.state="resumed" | .resumed_at=$ts | .resume_authority=$phase | .resume_event_id=$event' \
      "$(pause_path "$id")") || die "cannot record review circuit-breaker resolution"
    atomic_json_write "$(pause_path "$id")" "$pause"
  fi
  atomic_json_write "$(budget_path "$id")" "$budget"
  if [ "$phase" = redesign ] || [ "$phase" = rescope ]; then
    BUDGET=$budget
    rearm_monitor "$id"
  fi
  printf 'review-recorded: %s %s state=%s\n' "$id" "$phase" "$state"
  [ "$state" = active ] || return 3
}

cmd_monitor() {
  local id=${1:-} interval='' out rc failures=0 delay backoff path
  slug_valid "$id" || die "task id must be a privacy-safe slug"
  shift || true
  while [ "$#" -gt 0 ]; do
    case "$1" in --interval) positive_int "${2-}" || die "--interval needs positive integer seconds"; interval=$2; shift 2 ;; *) usage ;; esac
  done
  if [ -z "$interval" ]; then
    load_budget "$id"
    interval=$(printf '%s\n' "$BUDGET" | jq -r '.monitor_interval_seconds')
  fi
  positive_int "$interval" || die "resource budget has invalid monitor interval"
  path=$(budget_path "$id")
  delay=$interval
  while :; do
    sleep "$delay"
    delay=$interval
    if [ ! -e "$path" ] && [ ! -L "$path" ] || [ "$(jq -r '.guard_state' "$path" 2>/dev/null)" = retired ]; then
      printf 'resource: %s\n' "$id"
      printf 'status: retired\n'
      return 0
    fi
    rc=0
    out=$("$0" check "$id" --monitor 2>/dev/null) || rc=$?
    case "$rc" in
      0)
        failures=0
        if [ "$(printf '%s\n' "$out" | jq -r '.auto_resumed' 2>/dev/null)" = true ]; then
          printf 'resource: %s\n' "$id"
          printf 'status: resumed\n'
          printf 'decision: %s\n' "$out"
          printf 'action: the proven near-reset floor reopened the budget; tell the worker it may resume\n'
          return 0
        fi
        ;;
      3)
        failures=0
        case "$(printf '%s\n' "$out" | jq -r '"\(.state):\(.reason)"' 2>/dev/null)" in
          paused:reserve_floor) continue ;;
          paused:*)
            printf 'resource: %s\n' "$id"
            printf 'status: awaiting-authority\n'
            printf 'decision: %s\n' "$out"
            printf 'action: the lane stays paused until a captain decision, redesign, or re-scope\n'
            return 0
            ;;
        esac
        printf 'resource: %s\n' "$id"
        printf 'status: pause-required\n'
        printf 'decision: %s\n' "$out"
        printf 'action: ask the worker to stop at its next safe boundary, then run fm-resource-guard.sh pause %s\n' "$id"
        return 0
        ;;
      *)
        # Local errors such as lock contention retry with bounded backoff. The
        # error result is not terminal, so the source stays registered and the
        # runner restarts this monitor after supervision sees it.
        failures=$((failures + 1))
        if [ "$failures" -lt 3 ]; then
          backoff=$((interval << failures))
          [ "$backoff" -le 300 ] || backoff=300
          [ "$backoff" -ge "$interval" ] || backoff=$interval
          delay=$backoff
          continue
        fi
        printf 'resource: %s\n' "$id"
        printf 'status: error\n'
        printf 'detail: resource guard check failed %s consecutive times without exposing quota payloads\n' "$failures"
        printf 'action: run fm-resource-guard.sh status %s and repair the named lock or local record; the monitor stays registered\n' "$id"
        return 0
        ;;
    esac
  done
}

cmd_retire() {
  local id=${1:-} budget event ts now source
  slug_valid "$id" || die "task id must be a privacy-safe slug"
  [ "$#" -eq 1 ] || usage
  lock_acquire "$id"
  load_budget "$id"
  source="resource-$id"
  "$SCRIPT_DIR/fm-procevent.sh" retire "$source" --if-matches resource -- \
    "$SCRIPT_DIR/fm-procevent-resource.sh" poll "$id" --interval "$(printf '%s\n' "$BUDGET" | jq -r '.monitor_interval_seconds')" \
    >/dev/null 2>&1 || die "cannot retire resource monitor for task $id"
  if [ "$(printf '%s\n' "$BUDGET" | jq -r '.retire_event_id // ""')" != "" ]; then
    printf 'retired: %s (idempotent)\n' "$id"
    return 0
  fi
  ts=$(printf '%s\n' "$BUDGET" | jq -r '.retired_at // ""')
  if [ -z "$ts" ]; then
    now=$(date +%s); ts=$(epoch_iso "$now")
  fi
  budget=$(printf '%s\n' "$BUDGET" | jq -c --arg ts "$ts" '.guard_state="retired" | .retired_at=$ts')
  # Publish the retirement timestamp before its event. If event publication is
  # interrupted, retry uses the same timestamp and therefore the same event id.
  atomic_json_write "$(budget_path "$id")" "$budget"
  event=$(printf '%s\n' "$budget" | jq -c --arg schema "$EVENT_SCHEMA" --arg ts "$ts" '
    {schema:$schema,ts:$ts,kind:"retire",task_id:.task_id,budget_id:.budget_id,budget_revision:.revision,
     provider:.provider,account_key:.account_key,model:.model,source:"resource-guard",
     attribution_confidence:.attribution_confidence,concurrent_tasks:.concurrent_tasks,windows:.windows,
     decision:{state:"retired",reason:null,resume_required:"none"},milestone:null}')
  append_event "$event"
  budget=$(printf '%s\n' "$budget" | jq -c --arg event "$EVENT_ID" '.retire_event_id=$event')
  atomic_json_write "$(budget_path "$id")" "$budget"
  printf 'retired: %s\n' "$id"
}

cmd_status() {
  local id=${1:-}
  slug_valid "$id" || die "task id must be a privacy-safe slug"
  [ "$#" -eq 1 ] || usage
  load_budget "$id"
  printf '%s\n' "$BUDGET" | jq -c '{schema,task_id,budget_id,revision,provider,account_key,model,guard_state,dispatch_state,decision_reason,telemetry_status,attribution_confidence,concurrent_tasks,windows,review}'
}

cmd_worker_overlay() {
  local id=${1:-}
  slug_valid "$id" || die "task id must be a privacy-safe slug"
  [ "$#" -eq 1 ] || usage
  load_budget "$id"
  if [ "$(printf '%s\n' "$BUDGET" | jq -r '.guard_state')" != active ]; then
    printf 'error: task %s resource budget is %s; do not dispatch until the guard authorizes it\n' \
      "$id" "$(printf '%s\n' "$BUDGET" | jq -r '.guard_state')" >&2
    exit 3
  fi
  cat <<'EOF'

# Resource budget boundary
This task has a task-bound resource budget monitored outside your turn.
At every natural checkpoint, read and acknowledge any waiting steering message before beginning another creator, review, correction, or validation pass.
If a resource-pause instruction arrives, preserve every file and branch and stop at the next safe ownership boundary.
Never force, stash, reset, discard, or interrupt a branch-owning validation run to satisfy that request; let its current action reach a supported gate or return custody first.
At that boundary append the required `paused [at=<epoch>]: resource guard safe boundary reached` event and stop work.
Do not resume from elapsed time, recovered quota, or your own judgment; resume only after firstmate says the durable guard has authorized it.
Use one creator pass, one independent critic pass, one accepted correction pass, one focused delta review of the corrected head, and a complete independent review of the final head.
Use a different provider or model family for independent review whenever feasible, and record the concrete exception when it is not.
Any failure after the accepted correction, or a second consecutive failure of the same theme, stops the loop for redesign, re-scope, or a captain-authorized revised budget.
EOF
}

require_tools
case "${1-}" in
  start) shift; cmd_start "$@" ;;
  check) shift; cmd_check "$@" ;;
  milestone) shift; cmd_milestone "$@" ;;
  dispatch) shift; cmd_dispatch "$@" ;;
  pause) shift; cmd_pause "$@" ;;
  bind-authority) shift; cmd_bind_authority "$@" ;;
  resume) shift; cmd_resume "$@" ;;
  review) shift; cmd_review "$@" ;;
  monitor) shift; cmd_monitor "$@" ;;
  retire) shift; cmd_retire "$@" ;;
  status) shift; cmd_status "$@" ;;
  worker-overlay) shift; cmd_worker_overlay "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
