#!/usr/bin/env bash
# fm-fleet-health.sh - read-only fleet operational health checker.
#
# Output contract: default human view, `--json` prints one object with schema
# `fm-fleet-health.v1`. The command consumes `bin/fm-fleet-snapshot.sh --json`
# once and existing owner helpers for facts the snapshot does not carry. It
# does not acquire the session lock, drain wakes, arm watchers, steer, relaunch,
# acknowledge records, or otherwise repair anything.
#
# Activation is not in this phase. The smallest later integration is a custom
# watcher slow-check that runs this command and prints one line only when the
# high-confidence fingerprint set changes, so a finding enters the durable wake
# queue and unchanged repeats stay quiet. Cron and Herdr composer injection add
# no recovery the wake queue and watcher continuity do not already provide.
#
# Findings are mechanically provable Firstmate operational failures: dead or
# missing local agents, unavailable or invalid secondmate summaries, broken or
# overdue reply delivery, aged unacknowledged steering-inbox messages,
# inconsistent active-work inventory, terminal workers that still have a live
# endpoint, missing required result listeners, and unhealthy supervision
# continuity when `fm_watcher_supervision_verdict` can establish it.
# Product decisions, ordinary external waits, and historical status events are
# out of scope. Unavailable evidence is `inconclusive`, never healthy and never
# definitely broken. A remote task's local placeholder window is never remote
# liveness; the default collection sets FM_SNAPSHOT_REMOTE_PROBES=0 so this
# command makes no SSH or GitHub calls.
#
# Each finding has kind, subject, evidence, severity, confidence, count, and a
# deterministic fingerprint (sha256 of kind, subject, and cause). Repeated
# symptoms for one owner/cause collapse to one finding.
#
# Exit status:
#   0  healthy: no high-confidence findings (inconclusive rows may still print)
#   1  actionable: at least one high-confidence finding
#   2  usage error
#   3  incomplete: the checker failed or could not finish
#
# Bounds: FM_FLEET_HEALTH_TIMEOUT (default 120) bounds snapshot collection.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-timeout-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-pending-reply-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-pending-reply-lib.sh"
# shellcheck source=bin/fm-task-inbox-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-task-inbox-lib.sh"
# shellcheck source=bin/fm-supervision-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-supervision-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-procevent-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-procevent-lib.sh"

usage() {
  cat <<'EOF'
usage: fm-fleet-health.sh [--json]

Print a read-only operational health report for this Firstmate home.
JSON is the stable machine-readable output contract.

The checker consumes fm-fleet-snapshot.sh --json once, with remote SSH probes
disabled by default, and never mutates fleet state.
EOF
}

OUTPUT_MODE=human
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --json) OUTPUT_MODE=json ;;
  "") ;;
  *) usage >&2; exit 2 ;;
esac

command -v jq >/dev/null 2>&1 || { echo "fm-fleet-health: jq not found" >&2; exit 3; }

FM_FLEET_HEALTH_TIMEOUT=${FM_FLEET_HEALTH_TIMEOUT:-120}
case "$FM_FLEET_HEALTH_TIMEOUT" in
  ''|*[!0-9]*|0)
    echo "fm-fleet-health: FM_FLEET_HEALTH_TIMEOUT must be a positive integer" >&2
    exit 2
    ;;
esac

fingerprint_hex() {
  local key=$1 digest
  if command -v shasum >/dev/null 2>&1; then
    digest=$(printf '%s' "$key" | shasum -a 256 | awk '{print $1}')
  elif command -v sha256sum >/dev/null 2>&1; then
    digest=$(printf '%s' "$key" | sha256sum | awk '{print $1}')
  else
    return 1
  fi
  case "$digest" in
    *[!0-9a-f]*) return 1 ;;
  esac
  [ "${#digest}" -eq 64 ] || return 1
  printf 'sha256:%s' "$digest"
}

collect_pr_listeners_json() {
  local state=$1 f id records='[]'
  if [ ! -d "$state" ]; then
    jq -n '{available:true,records:[]}'
    return 0
  fi
  if [ ! -r "$state" ]; then
    jq -n '{available:false,records:[]}'
    return 0
  fi
  for f in "$state"/*.check.sh; do
    [ -f "$f" ] || continue
    id=$(basename "$f" .check.sh)
    case "$id" in
      x-watch|tool-updates) continue ;;
    esac
    records=$(jq -n --argjson records "$records" --arg id "$id" \
      '$records + [{id:$id,armed:true}]')
  done
  jq -n --argjson records "$records" '{available:true,records:$records}'
}

collect_supervision_json() {
  local state=$1 watch=$2 needed ok reason model
  fm_supervision_status "$state" >/dev/null
  needed=$FM_SUP_NEEDED
  fm_watcher_supervision_verdict "$state" "$watch"
  if [ "$FM_WATCHER_VERDICT_OK" = true ]; then
    ok=true
    reason=null
  else
    ok=false
    reason=$FM_WATCHER_VERDICT_REASON
  fi
  model=$(fm_supervision_model)
  jq -n \
    --argjson needed "$( [ "$needed" = true ] && printf true || printf false )" \
    --argjson ok "$( [ "$ok" = true ] && printf true || printf false )" \
    --arg reason "${reason:-}" \
    --arg model "$model" \
    '{
      available:true,
      needed:$needed,
      ok:$ok,
      reason:(if $reason == "null" or $reason == "" then null else $reason end),
      model:$model
    }'
}

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
SNAPSHOT_RC=0
SNAPSHOT=$(
  FM_SNAPSHOT_REMOTE_PROBES=0 \
    fm_run_timed "$FM_FLEET_HEALTH_TIMEOUT" \
    "$SCRIPT_DIR/fm-fleet-snapshot.sh" --json
) || SNAPSHOT_RC=$?
if [ "$SNAPSHOT_RC" -ne 0 ]; then
  reason="fleet snapshot failed"
  [ "$SNAPSHOT_RC" -eq 124 ] && reason="fleet snapshot timed out"
  if [ "$OUTPUT_MODE" = json ]; then
    jq -n --arg generated "$NOW" --arg home "$FM_HOME" --arg reason "$reason" \
      '{schema:"fm-fleet-health.v1",generated:$generated,fm_home:$home,status:"incomplete",snapshot_generated:null,reason:$reason,findings:[]}'
  else
    printf '# Fleet Health\nStatus: incomplete\nHome: %s\n%s\n' "$FM_HOME" "$reason"
  fi
  exit 3
fi
if ! printf '%s' "$SNAPSHOT" | jq -e '.schema == "fm-fleet-snapshot.v1"' >/dev/null 2>&1; then
  if [ "$OUTPUT_MODE" = json ]; then
    jq -n --arg generated "$NOW" --arg home "$FM_HOME" \
      '{schema:"fm-fleet-health.v1",generated:$generated,fm_home:$home,status:"incomplete",snapshot_generated:null,reason:"fleet snapshot was malformed",findings:[]}'
  else
    printf '# Fleet Health\nStatus: incomplete\nHome: %s\nfleet snapshot was malformed\n' "$FM_HOME"
  fi
  exit 3
fi

PENDING_JSON=$(fm_pending_reply_open_json "$STATE") \
  || PENDING_JSON='{"available":false,"now_epoch":null,"records":[]}'
INBOX_JSON=$(fm_task_inbox_unhandled_json "$STATE") \
  || INBOX_JSON='{"available":false,"records":[]}'
LISTENERS_JSON=$(fm_procevent_listeners_json "$STATE") \
  || LISTENERS_JSON='{"available":false,"records":[]}'
PR_JSON=$(collect_pr_listeners_json "$STATE") \
  || PR_JSON='{"available":false,"records":[]}'
SUPERVISION_JSON=$(collect_supervision_json "$STATE" "$SCRIPT_DIR/fm-watch.sh") \
  || SUPERVISION_JSON='{"available":false,"needed":false,"ok":false,"reason":null,"model":null}'

PENDING_GRACE=$(fm_pending_reply_grace_secs)
INBOX_GRACE=$(fm_task_inbox_grace_secs)

EVALUATED=$(jq -n \
  --arg generated "$NOW" \
  --argjson snapshot "$SNAPSHOT" \
  --argjson pending "$PENDING_JSON" \
  --argjson inbox "$INBOX_JSON" \
  --argjson listeners "$LISTENERS_JSON" \
  --argjson prs "$PR_JSON" \
  --argjson supervision "$SUPERVISION_JSON" \
  --argjson pending_grace "$PENDING_GRACE" \
  --argjson inbox_grace "$INBOX_GRACE" \
  '
  def finding($kind; $subject; $severity; $confidence; $evidence; $cause; $count):
    {kind:$kind,subject:$subject,severity:$severity,confidence:$confidence,
     evidence:$evidence,cause:$cause,count:$count,
     fingerprint_key:($kind + "\t" + $subject + "\t" + $cause)};
  def remote($t): ($t.remote != null);
  def probe($t): ($t.endpoint.probe // "none");
  def alive($t): ($t.endpoint.agent_alive // "not_checked");
  def exists($t): $t.endpoint.exists;
  def terminal_state($s): ($s == "done" or $s == "failed");
  def skip_wait($s): ($s == "parked" or $s == "paused" or $s == "blocked");
  ($pending.now_epoch // 0) as $now
  | [
      (if $pending.available == false then
        finding("pending-reply-inconclusive";"pending-replies";"notice";"inconclusive";
                "pending-reply records could not be read";"unreadable";1)
      else empty end),
      (if $inbox.available == false then
        finding("steering-inbox-inconclusive";"steering-inbox";"notice";"inconclusive";
                "steering-inbox records could not be read";"unreadable";1)
      else empty end),
      (if $listeners.available == false then
        finding("result-listener-inconclusive";"procevent";"notice";"inconclusive";
                "process-event registrations could not be read";"unreadable";1)
      else empty end),
      (if $supervision.available == false then
        finding("supervision-inconclusive";"supervision";"notice";"inconclusive";
                "supervision continuity could not be established";"unreadable";1)
      else empty end),
      ($snapshot.tasks[]?
        | select(remote(.) and (probe(.) == "skipped" or alive(.) == "not_collected" or alive(.) == "unknown"))
        | finding("remote-liveness-inconclusive";.id;"notice";"inconclusive";
                  "remote liveness was not collected; a local placeholder is not remote evidence";
                  "not_collected";1)),
      ($snapshot.tasks[]?
        | select(remote(.) | not)
        | select(.kind != "secondmate")
        | select(exists(.) == false)
        | select(terminal_state(.current_state.state) | not)
        | finding("dead-direct-report";.id;"error";"high";
                  ("recorded endpoint is absent while current state is " + .current_state.state);
                  "absent";1)),
      ($snapshot.tasks[]?
        | select(remote(.) | not)
        | select(.kind != "secondmate")
        | select(exists(.) == null)
        | select(terminal_state(.current_state.state) | not)
        | finding("endpoint-inconclusive";.id;"notice";"inconclusive";
                  "endpoint presence could not be established";"unknown";1)),
      ($snapshot.tasks[]?
        | select(.kind == "secondmate")
        | select(remote(.) | not)
        | select(alive(.) == "dead" or exists(.) == false)
        | finding("dead-secondmate";.id;"error";"high";
                  (if exists(.) == false then "recorded secondmate endpoint is absent"
                   else "secondmate agent is dead" end);
                  (if exists(.) == false then "absent" else "dead" end);1)),
      ($snapshot.tasks[]?
        | select(.kind == "secondmate")
        | select(remote(.) | not)
        | select(alive(.) == "unknown" or (alive(.) == "not_checked" and exists(.) == null))
        | finding("endpoint-inconclusive";.id;"notice";"inconclusive";
                  "secondmate liveness could not be established";"unknown";1)),
      ($snapshot.tasks[]?
        | select(remote(.))
        | select(probe(.) == "remote" and alive(.) == "dead")
        | finding("dead-secondmate";.id;"error";"high";
                  "remote secondmate agent is dead";"remote-dead";1)),
      ($snapshot.tasks[]?
        | select(.kind != "secondmate")
        | select(terminal_state(.current_state.state))
        | select(exists(.) == true)
        | finding("terminal-needs-cleanup";.id;"warning";"high";
                  ("worker is " + .current_state.state + " but its endpoint is still present");
                  .current_state.state;1)),
      (if $snapshot.main_inventory.valid == false then
        finding("inventory-inconsistent";"main";"error";"high";
                ("active-work inventory is inconsistent: " + ($snapshot.main_inventory.reason // "unknown reason"));
                ($snapshot.main_inventory.reason // "invalid");1)
      else empty end),
      ($snapshot.secondmate_current.records[]?
        | select(.current.state == "unknown")
        | . as $row
        | (($row.current.reason // "") ) as $reason
        | if ($reason | test("not collected")) then
            empty
          elif ($reason | test("timed out")) then
            finding("secondmate-summary-unavailable";$row.id;"warning";"high";
                    $reason;"timeout";1)
          elif ($reason | test("invalid home|malformed|invalid remote|not registered")) then
            finding("secondmate-summary-invalid";$row.id;"error";"high";
                    $reason;"invalid";1)
          elif ($reason | test("child current state unavailable")) then
            finding("secondmate-summary-inconclusive";$row.id;"notice";"inconclusive";
                    $reason;"child_unavailable";1)
          elif ($reason | test("failed|unreadable|unavailable")) then
            finding("secondmate-summary-unavailable";$row.id;"warning";"high";
                    $reason;"unavailable";1)
          else
            finding("secondmate-summary-inconclusive";$row.id;"notice";"inconclusive";
                    ($reason | if . == "" then "secondmate current state is unknown" else . end);
                    "unknown";1)
          end),
      (if ($snapshot.secondmate_current.registry.available == false) then
        finding("secondmate-summary-unavailable";"secondmate-registry";"warning";"high";
                ($snapshot.secondmate_current.registry.reason // "registered secondmate table is unavailable");
                "registry";1)
      else empty end),
      ((($pending.records // [])
        | map(select(.phase == "delivery_unknown" or .phase == "recovery_failed" or .phase == "recovery_unknown"))
        | group_by(.task_id)[]) as $g
        | ($g | length) as $n
        | ($g[0].task_id) as $task
        | finding("pending-reply-broken";$task;"error";"high";
                  ("broken reply delivery (" + ([ $g[].phase ] | unique | join(", ")) + ")");
                  "broken";$n)),
      ((($pending.records // [])
        | map(select(.phase != "escalated"))
        | map(select(
            (.phase == "awaiting_report" and .request_turn_completed_epoch != null
             and $now != 0 and (($now - .request_turn_completed_epoch) >= $pending_grace))
            or (.phase == "recovery_sent" and .recovery_turn_completed_epoch != null
                and $now != 0 and (($now - .recovery_turn_completed_epoch) >= $pending_grace))
          ))
        | group_by(.task_id)[]) as $g
        | ($g | length) as $n
        | finding("pending-reply-overdue";$g[0].task_id;"warning";"high";
                  ("reply delivery is overdue by at least the pending-reply grace (" + ($pending_grace|tostring) + "s)");
                  "overdue";$n)),
      ((($inbox.records // [])
        | map(select(.age_seconds != null and .age_seconds >= $inbox_grace))
        | group_by(.task_id)[]) as $g
        | ($g | length) as $n
        | finding("steering-inbox-aged";$g[0].task_id;"warning";"high";
                  ($n|tostring) + " unacknowledged steering message(s) older than grace (" + ($inbox_grace|tostring) + "s)";
                  "aged";$n)),
      ($snapshot.tasks[]?
        | select(.kind == "ship")
        | select((.pr.url // null) != null)
        | select(terminal_state(.current_state.state) | not)
        | select(skip_wait(.current_state.state) | not)
        | .id as $id
        | select([$prs.records[]?.id] | index($id) | not)
        | finding("result-listener-missing";$id;"error";"high";
                  "in-flight ship with a recorded PR has no armed merge-poll listener";
                  "pr-poll";1)),
      (($listeners.records // [])[]
        | select(.owner == "missing" or .owner == "stale" or .owner == "orphaned")
        | finding("result-listener-missing";.id;"error";"high";
                  ("process-event source has no live result listener (owner=" + .owner + ")");
                  .owner;1)),
      (($listeners.records // [])[]
        | select(.owner == "uncertain")
        | finding("result-listener-inconclusive";.id;"notice";"inconclusive";
                  "process-event listener liveness could not be established";"uncertain";1)),
      (if $supervision.needed == true and $supervision.ok == false then
        finding("supervision-unhealthy";"supervision";"error";"high";
                ("supervision is required but unhealthy (" + ($supervision.reason // "unknown") + ")");
                ($supervision.reason // "unhealthy");1)
      else empty end)
    ]
  | sort_by([.kind,.subject,.cause])
  | {
      schema:"fm-fleet-health.v1",
      generated:$generated,
      fm_home:$snapshot.fm_home,
      snapshot_generated:$snapshot.generated,
      findings:.
    }
') || {
  echo "fm-fleet-health: evaluation failed" >&2
  exit 3
}

FINDINGS_OUT='[]'
while IFS= read -r row; do
  [ -n "$row" ] || continue
  key=$(printf '%s' "$row" | jq -r '.fingerprint_key')
  fp=$(fingerprint_hex "$key") || {
    echo "fm-fleet-health: fingerprint hash unavailable" >&2
    exit 3
  }
  FINDINGS_OUT=$(jq -n --argjson acc "$FINDINGS_OUT" --argjson row "$row" --arg fp "$fp" \
    '$acc + [$row | del(.fingerprint_key,.cause) + {fingerprint:$fp}]')
done < <(printf '%s' "$EVALUATED" | jq -c '.findings[]?')

REPORT=$(jq -n \
  --argjson base "$EVALUATED" \
  --argjson findings "$FINDINGS_OUT" '
  ($findings | any(.confidence == "high")) as $actionable
  | $base
  | .findings = $findings
  | .status = (if $actionable then "actionable" else "healthy" end)
')

if [ "$OUTPUT_MODE" = json ]; then
  printf '%s\n' "$REPORT"
else
  printf '%s\n' "$REPORT" | jq -r '
    "# Fleet Health",
    "Status: \(.status)",
    "Home: \(.fm_home)",
    "Snapshot: \(.snapshot_generated)",
    "",
    (if (.findings | length) == 0 then "No operational findings." else "## Findings" end),
    (.findings[]? | "- [\(.severity)/\(.confidence)] \(.kind)  \(.subject)",
     "  \(.evidence)",
     "  fingerprint: \(.fingerprint)")
  '
fi

STATUS=$(printf '%s' "$REPORT" | jq -r '.status')
case "$STATUS" in
  healthy) exit 0 ;;
  actionable) exit 1 ;;
  *) exit 3 ;;
esac
