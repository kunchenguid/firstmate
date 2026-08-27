#!/usr/bin/env bash
# fm-fleet-health.sh - read-only fleet operational health checker.
#
# Output contract: default human view, `--json` prints one object with schema
# `fm-fleet-health.v1`. The command consumes `bin/fm-fleet-snapshot.sh --json`
# once and existing owner helpers for facts the snapshot does not carry. It
# does not acquire the session lock, drain wakes, arm watchers, steer, relaunch,
# acknowledge records, or otherwise repair anything.
#
# The checker is not scheduled or activated automatically.
#
# Findings are mechanically provable Firstmate operational failures: dead or
# missing local agents, a Codex worker whose pane shows the exact resume banner
# or a bare shell while the task is still in flight, a scaffold-contracted stop signal
# with no later status append or steering inbox activity for
# FM_FLEET_HEALTH_HANDOFF_STALE_SECS (default 1800), unavailable or invalid
# secondmate summaries, broken or overdue reply delivery, aged unacknowledged
# steering-inbox messages, inconsistent active-work inventory, terminal workers
# that still have a live endpoint, missing required result listeners, and
# unhealthy supervision continuity when `fm_watcher_supervision_verdict` can
# establish it.
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
#   0  healthy: no findings
#   1  actionable: at least one high-confidence finding
#   2  usage error
#   3  inconclusive/incomplete: evidence is unavailable or checking did not finish
#
# Bounds: FM_FLEET_HEALTH_TIMEOUT (default 120) bounds the complete check.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-timeout-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-classify-lib.sh"
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
FM_FLEET_HEALTH_HANDOFF_STALE_SECS (default 1800) is the age after a contracted
stop status with no later status append or steering-inbox activity that
becomes a missed-handoff finding.
EOF
}

OUTPUT_MODE=human
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --json) OUTPUT_MODE=json ;;
  "") ;;
  *) usage >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || { usage >&2; exit 2; }

command -v jq >/dev/null 2>&1 || { echo "fm-fleet-health: jq not found" >&2; exit 3; }

FM_FLEET_HEALTH_TIMEOUT=${FM_FLEET_HEALTH_TIMEOUT:-120}
case "$FM_FLEET_HEALTH_TIMEOUT" in
  ''|*[!0-9]*|0)
    echo "fm-fleet-health: FM_FLEET_HEALTH_TIMEOUT must be a positive integer" >&2
    exit 2
    ;;
esac

if [ "${FM_FLEET_HEALTH_TIMED_WORKER:-0}" != 1 ]; then
  WRAPPED_RC=0
  WRAPPED_OUTPUT=$(FM_FLEET_HEALTH_TIMED_WORKER=1 \
    fm_run_timed "$FM_FLEET_HEALTH_TIMEOUT" "$0" "$@") || WRAPPED_RC=$?
  if [ "$WRAPPED_RC" -eq 124 ]; then
    NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    if [ "$OUTPUT_MODE" = json ]; then
      jq -n --arg generated "$NOW" --arg home "$FM_HOME" \
        '{schema:"fm-fleet-health.v1",generated:$generated,fm_home:$home,status:"incomplete",snapshot_generated:null,reason:"fleet health check timed out",findings:[]}'
    else
      printf '# Fleet Health\nStatus: incomplete\nHome: %s\nfleet health check timed out\n' "$FM_HOME"
    fi
    exit 3
  fi
  if [ "$WRAPPED_RC" -eq 2 ]; then
    exit 2
  fi
  if [ "$OUTPUT_MODE" = json ] \
    && ! printf '%s' "$WRAPPED_OUTPUT" | jq -e '.schema == "fm-fleet-health.v1"' >/dev/null 2>&1; then
    NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    jq -n --arg generated "$NOW" --arg home "$FM_HOME" \
      '{schema:"fm-fleet-health.v1",generated:$generated,fm_home:$home,status:"incomplete",snapshot_generated:null,reason:"fleet health check failed",findings:[]}'
    exit 3
  fi
  if [ "$OUTPUT_MODE" != json ] && [ -z "$WRAPPED_OUTPUT" ] && [ "$WRAPPED_RC" -ne 0 ]; then
    printf '# Fleet Health\nStatus: incomplete\nHome: %s\nfleet health check failed\n' "$FM_HOME"
    exit 3
  fi
  printf '%s\n' "$WRAPPED_OUTPUT"
  exit "$WRAPPED_RC"
fi

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

snapshot_shape_valid() {
  local shape_valid=false classification
  if printf '%s' "$1" | jq -e '
    def nullable($expected): (. == null or type == $expected);
    def nullable_key($key; $expected): has($key)
      and (.[ $key ] == null or (.[ $key] | type) == $expected);
    def enum($values): . as $value | ($values | index($value)) != null;
    def task_state_valid: enum(["working","parked","done","blocked","paused","failed","unknown"]);
    def secondmate_state_valid: enum(["active_child_work","captain_decision","externally_held","no_active_work","unknown"]);
    def endpoint_agent_state_valid: enum(["not_checked","not_collected","alive","dead","missing","ambiguous","unreadable","unverified"]);
    def endpoint_agent_alive_valid: enum(["not_checked","not_collected","alive","dead","unknown"]);
    def endpoint_probe_valid: enum(["none","local","remote","skipped"]);
    def task_valid:
      type == "object"
      and (.id | type) == "string"
      and (.kind | type) == "string"
      and nullable_key("remote"; "object")
      and (.current_state | type) == "object"
      and (.current_state.state | type) == "string"
      and (.current_state.state | task_state_valid)
      and (.endpoint | type) == "object"
      and (.endpoint | nullable_key("exists"; "boolean"))
      and (.endpoint.agent_state | type) == "string"
      and (.endpoint.agent_state | endpoint_agent_state_valid)
      and (.endpoint.agent_alive | type) == "string"
      and (.endpoint.agent_alive | endpoint_agent_alive_valid)
      and (.endpoint.probe | type) == "string"
      and (.endpoint.probe | endpoint_probe_valid)
      and (.endpoint.codex_session | type) == "object"
      and (.endpoint.codex_session.collected | type) == "boolean"
      and (.endpoint.codex_session | nullable_key("reason"; "string"))
      and (.endpoint.codex_session | nullable_key("resume_banner"; "boolean"))
      and (.paths | type) == "object"
      and (.paths.status_log | type) == "object"
      and (.paths.status_log.last_event | type) == "object"
      and (.paths.status_log.last_event.state | type) == "string"
      and (.paths.status_log.last_event.handoff_required | type) == "boolean"
      and (.paths.status_log.last_event | nullable_key("mtime_epoch"; "number"))
      and (.pr | type) == "object"
      and (.pr | nullable_key("url"; "string"))
      and (.pr.source | type) == "string";
    def secondmate_valid:
      type == "object"
      and (.id | type) == "string"
      and (.current | type) == "object"
      and (.current.state | type) == "string"
      and (.current.state | secondmate_state_valid)
      and (.current | nullable_key("failure_kind"; "string"));
    type == "object"
    and .schema == "fm-fleet-snapshot.v1"
    and (.generated | type) == "string"
    and (.fm_home | type) == "string"
    and (.roots | type) == "object"
    and (.roots.fm_root | type) == "string"
    and (.roots.state | type) == "string"
    and (.roots.data | type) == "string"
    and (.roots.config | type) == "string"
    and (.roots.projects | type) == "string"
    and (.backlog | type) == "object"
    and (.backlog.path | type) == "string"
    and (.backlog.present | type) == "boolean"
    and (.backlog.records | type) == "array"
    and (.backlog.records | all(.[]; type == "object"))
    and (.tasks | type) == "array"
    and (.tasks | all(.[]; task_valid))
    and (.scout_reports | type) == "array"
    and (.scout_reports | all(.[]; type == "object"
      and (.id | type) == "string"
      and (.path | type) == "string"
      and (.kind | type) == "string"))
    and (.collection | type) == "object"
    and (.collection.state | type) == "object"
    and (.collection.state.present | type) == "boolean"
    and (.collection.state.available | type) == "boolean"
    and (.collection.state.invalid_metadata_count | type) == "number"
    and (.collection.state.invalid_metadata | type) == "array"
    and (.main_inventory | type) == "object"
    and (.main_inventory.valid | type) == "boolean"
    and (.main_inventory.reason | nullable("string"))
    and (.secondmate_current | type) == "object"
    and (.secondmate_current.records | type) == "array"
    and (.secondmate_current.records | all(.[]; secondmate_valid))
    and (.secondmate_current.truncated | type) == "number"
    and (.secondmate_current.registry | type) == "object"
    and (.secondmate_current.registry.available | type) == "boolean"
    and (.secondmate_current.registry.complete | type) == "boolean"
    and (.secondmate_current.registry.input_truncated | type) == "boolean"
    and (.secondmate_current.registry.records_truncated | type) == "boolean"
    and (.secondmate_landed | type) == "object"
    and (.secondmate_landed.records | type) == "array"
    and (.secondmate_landed.truncated | type) == "array"
    and (.secondmate_landed.unreadable | type) == "array"
    and (.secondmate_landed.partial | type) == "array"
    and (.secondmate_guidance | type) == "object"
    and (.secondmate_guidance.note | type) == "string"
  ' >/dev/null 2>&1; then
    shape_valid=true
  fi
  classification=$(fm_evidence_classify true "$shape_valid")
  [ "$classification" = available ]
}

collect_supervision_json() {
  local state=$1 watch=$2 needed available ok reason model
  fm_supervision_status "$state" >/dev/null
  needed=$FM_SUP_NEEDED
  fm_watcher_supervision_verdict "$state" "$watch"
  available=$FM_WATCHER_VERDICT_AVAILABLE
  if [ "$available" != true ]; then
    ok=false
    reason=unreadable
  elif [ "$FM_WATCHER_VERDICT_OK" = true ]; then
    ok=true
    reason=null
  else
    ok=false
    reason=$FM_WATCHER_VERDICT_REASON
  fi
  model=$(fm_supervision_model)
  jq -n \
    --argjson needed "$( [ "$needed" = true ] && printf true || printf false )" \
    --argjson available "$( [ "$available" = true ] && printf true || printf false )" \
    --argjson ok "$( [ "$ok" = true ] && printf true || printf false )" \
    --arg reason "${reason:-}" \
    --arg model "$model" \
    '{
      available:$available,
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
if ! snapshot_shape_valid "$SNAPSHOT" >/dev/null 2>&1; then
  if [ "$OUTPUT_MODE" = json ]; then
    jq -n --arg generated "$NOW" --arg home "$FM_HOME" \
      '{schema:"fm-fleet-health.v1",generated:$generated,fm_home:$home,status:"incomplete",snapshot_generated:null,reason:"fleet snapshot was malformed",findings:[]}'
  else
    printf '# Fleet Health\nStatus: incomplete\nHome: %s\nfleet snapshot was malformed\n' "$FM_HOME"
  fi
  exit 3
fi

PENDING_JSON=$(fm_pending_reply_open_json "$STATE") \
  || PENDING_JSON='{"available":false,"now_epoch":null,"invalid_count":0,"records":[]}'
INBOX_JSON=$(fm_task_inbox_unhandled_json "$STATE") \
  || INBOX_JSON='{"available":false,"invalid_count":0,"unreadable_count":0,"records":[]}'
LISTENERS_JSON=$(fm_procevent_listeners_json "$STATE") \
  || LISTENERS_JSON='{"available":false,"records":[]}'
PR_JSON=$(fm_pr_poll_listeners_json "$STATE" "$SCRIPT_DIR/fm-pr-poll.sh") \
  || PR_JSON='{"available":false,"records":[]}'
SUPERVISION_JSON=$(collect_supervision_json "$STATE" "$SCRIPT_DIR/fm-watch.sh") \
  || SUPERVISION_JSON='{"available":false,"needed":false,"ok":false,"reason":null,"model":null}'

INBOX_GRACE=$(fm_task_inbox_grace_secs)
HANDOFF_STALE=${FM_FLEET_HEALTH_HANDOFF_STALE_SECS:-1800}
case "$HANDOFF_STALE" in
  ''|*[!0-9]*)
    echo "fm-fleet-health: FM_FLEET_HEALTH_HANDOFF_STALE_SECS must be a non-negative integer" >&2
    exit 2
    ;;
esac
INBOX_ACTIVITY_JSON=$(fm_task_inbox_latest_activity_json "$STATE") \
  || INBOX_ACTIVITY_JSON='{"available":false,"root_available":false,"records":[]}'
NOW_EPOCH=$(date +%s)
case "$NOW_EPOCH" in
  ''|*[!0-9]*) NOW_EPOCH=0 ;;
esac

EVALUATED=$(jq -n \
  --arg generated "$NOW" \
  --argjson snapshot "$SNAPSHOT" \
  --argjson pending "$PENDING_JSON" \
  --argjson inbox "$INBOX_JSON" \
  --argjson inbox_activity "$INBOX_ACTIVITY_JSON" \
  --argjson listeners "$LISTENERS_JSON" \
  --argjson prs "$PR_JSON" \
  --argjson supervision "$SUPERVISION_JSON" \
  --argjson inbox_grace "$INBOX_GRACE" \
  --argjson handoff_stale "$HANDOFF_STALE" \
  --argjson now_epoch "$NOW_EPOCH" \
  '
  def finding($kind; $subject; $severity; $confidence; $evidence; $cause; $count):
    {kind:$kind,subject:$subject,severity:$severity,confidence:$confidence,
     evidence:$evidence,cause:$cause,count:$count,
     fingerprint_key:($kind + "\t" + $subject + "\t" + $cause)};
  def remote($t): ($t.remote != null);
  def probe($t): ($t.endpoint.probe // "none");
  def alive($t): ($t.endpoint.agent_alive // "not_checked");
  def agent_state($t): ($t.endpoint.agent_state //
    (if alive($t) == "alive" then "alive"
     elif alive($t) == "dead" and $t.endpoint.exists == false then "missing"
     elif alive($t) == "dead" then "dead"
     elif alive($t) == "not_collected" then "not_collected"
     else "unreadable" end));
  def exists($t): $t.endpoint.exists;
  def terminal_state($s): ($s == "done" or $s == "failed");
  def codex_harness($t): (($t.harness // "") | startswith("codex"));
  def resume_banner($t): ($t.endpoint.codex_session.resume_banner == true);
  def codex_capture_inconclusive($t):
    (codex_harness($t)
     and exists($t) == true
     and (terminal_state($t.current_state.state) | not)
     and ((agent_state($t) == "dead" or agent_state($t) == "missing") | not)
     and $t.endpoint.codex_session.collected == false);
  def inbox_last($id):
    ([ $inbox_activity.records[]? | select(.task_id == $id) | .last_epoch ]
     | if length == 0 then null else max end);
  def inbox_activity_available($id):
    ([ $inbox_activity.records[]? | select(.task_id == $id) | .available ]
     | if length == 0 then ($inbox_activity.root_available // false) else all end);
  ($pending.now_epoch // 0) as $now
  | [
      (if $pending.available == false then
        finding("pending-reply-inconclusive";"pending-replies";"notice";"inconclusive";
                "pending-reply records could not be read";"unreadable";1)
      else empty end),
      (if ($pending.invalid_count // 0) > 0 then
        finding("pending-reply-inconclusive";"pending-replies";"notice";"inconclusive";
                (($pending.invalid_count | tostring) + " pending-reply record(s) are invalid");
                "invalid";$pending.invalid_count)
      else empty end),
      (if $inbox.available == false then
        finding("steering-inbox-inconclusive";"steering-inbox";"notice";"inconclusive";
                "steering-inbox records could not be read";"unreadable";1)
      else empty end),
      (if ($inbox.invalid_count // 0) > 0 then
        finding("steering-inbox-inconclusive";"steering-inbox";"notice";"inconclusive";
                (($inbox.invalid_count | tostring) + " steering-inbox record(s) are invalid");
                "invalid";$inbox.invalid_count)
      else empty end),
      (if ($inbox.unreadable_count // 0) > 0 then
        finding("steering-inbox-inconclusive";"steering-inbox";"notice";"inconclusive";
                (($inbox.unreadable_count | tostring) + " steering-inbox record(s) could not be aged");
                "unreadable-record";$inbox.unreadable_count)
      else empty end),
      (if ($inbox_activity.invalid_count // 0) > 0 then
        finding("steering-inbox-inconclusive";"steering-inbox";"notice";"inconclusive";
                (($inbox_activity.invalid_count | tostring) + " steering-inbox activity record(s) are invalid");
                "activity-invalid";$inbox_activity.invalid_count)
      else empty end),
      (if ($inbox_activity.unreadable_count // 0) > 0 then
        finding("steering-inbox-inconclusive";"steering-inbox";"notice";"inconclusive";
                (($inbox_activity.unreadable_count | tostring) + " steering-inbox activity record(s) could not be read or aged");
                "activity-unreadable";$inbox_activity.unreadable_count)
      else empty end),
      (if $listeners.available == false then
        finding("result-listener-inconclusive";"procevent";"notice";"inconclusive";
                "process-event registrations could not be read";"unreadable";1)
      else empty end),
      (if $prs.available == false then
        finding("result-listener-inconclusive";"pr-polls";"notice";"inconclusive";
                ((if ($prs.invalid_count // 0) > 0 then
                    ($prs.invalid_count | tostring) + " invalid PR-listener artifact(s)"
                  else ""
                  end)
                 + (if ($prs.unreadable_count // 0) > 0 then
                    (if ($prs.invalid_count // 0) > 0 then "; " else "" end)
                    + ($prs.unreadable_count | tostring) + " unreadable PR-listener artifact(s)"
                  else ""
                  end)
                 + (if ($prs.metadata_invalid_count // 0) > 0 then
                    (if (($prs.invalid_count // 0) + ($prs.unreadable_count // 0)) > 0 then "; " else "" end)
                    + ($prs.metadata_invalid_count | tostring) + " current PR metadata record(s) are invalid"
                  else ""
                  end)
                 | if . == "" then "PR-listener registrations could not be read" else . end);
                (if ($prs.metadata_invalid_count // 0) > 0 then "invalid-pr-metadata" else "unreadable" end);
                (($prs.invalid_count // 0) + ($prs.unreadable_count // 0) + ($prs.metadata_invalid_count // 0)))
      else empty end),
      (if $snapshot.collection.state.available == false then
        finding("fleet-inventory-inconclusive";"state";"notice";"inconclusive";
                ($snapshot.collection.state.reason // "fleet state could not be inventoried");
                "unavailable";1)
      else empty end),
      (if ($snapshot.collection.state.invalid_metadata_count // 0) > 0 then
        finding("fleet-inventory-inconclusive";"metadata";"notice";"inconclusive";
                (($snapshot.collection.state.invalid_metadata_count | tostring) + " task metadata entrie(s) are invalid or unreadable");
                "invalid-metadata";$snapshot.collection.state.invalid_metadata_count)
      else empty end),
      (if $supervision.needed == true and $supervision.available == false then
        finding("supervision-inconclusive";"supervision";"notice";"inconclusive";
                "supervision continuity could not be established";"unreadable";1)
      else empty end),
      (([
          ($snapshot.tasks[]?
            | select(remote(.) and (probe(.) == "skipped" or agent_state(.) == "not_collected" or agent_state(.) == "unreadable"))
            | {id:.id}),
          ($snapshot.secondmate_current.records[]?
            | select(.current.state == "unknown")
            | select((.current.failure_kind // "unknown") == "not_collected")
            | {id:.id})
        ]
        | group_by(.id)[]) as $g
        | finding("remote-liveness-inconclusive";$g[0].id;"notice";"inconclusive";
                  "remote liveness or summary was not collected; a local placeholder is not remote evidence";
                  "not_collected";($g | length))),
      ($snapshot.tasks[]?
        | select(remote(.) | not)
        | select(.kind != "secondmate")
        | select(agent_state(.) == "dead" or agent_state(.) == "missing")
        | select(terminal_state(.current_state.state) | not)
        | select((codex_harness(.) and exists(.) == true and agent_state(.) == "dead") | not)
        | finding("dead-direct-report";.id;"error";"high";
                  (if agent_state(.) == "missing" then "recorded endpoint is absent while current state is " + .current_state.state
                   else "direct-report agent is dead while its endpoint remains present" end);
                  agent_state(.);1)),
      ($snapshot.tasks[]?
        | select(remote(.) | not)
        | select(.kind != "secondmate")
        | select(codex_harness(.))
        | select(terminal_state(.current_state.state) | not)
        | select(resume_banner(.) or (exists(.) == true and agent_state(.) == "dead"))
        | finding("dead-codex-session";.id;"error";"high";
                  (if resume_banner(.) then "Codex session exited; pane contains the resume banner"
                   else "Codex session exited; endpoint pane is a bare shell" end);
                  (if resume_banner(.) then "resume-banner" else "bare-shell" end);1)),
      ($snapshot.tasks[]?
        | select(remote(.) | not)
        | select(.kind != "secondmate")
        | select(agent_state(.) == "ambiguous" or agent_state(.) == "unreadable"
                 or agent_state(.) == "unverified" or agent_state(.) == "not_checked"
                 or codex_capture_inconclusive(.))
        | select(resume_banner(.) | not)
        | finding("endpoint-inconclusive";.id;"notice";"inconclusive";
                  "agent or endpoint liveness could not be established";agent_state(.);1)),
      ($snapshot.tasks[]?
        | select(remote(.) | not)
        | select(.kind != "secondmate")
        | select(agent_state(.) == "alive")
        | select(.current_state.state == "unknown")
        | select(resume_banner(.) | not)
        | finding("current-state-inconclusive";.id;"notice";"inconclusive";
                  "worker lifecycle state could not be established";"unknown";1)),
      ($snapshot.tasks[]?
        | select(.kind == "secondmate")
        | select(remote(.) | not)
        | select(agent_state(.) == "dead" or agent_state(.) == "missing")
        | finding("dead-secondmate";.id;"error";"high";
                  (if agent_state(.) == "missing" then "recorded secondmate endpoint is absent"
                   else "secondmate agent is dead" end);
                  agent_state(.);1)),
      ($snapshot.tasks[]?
        | select(.kind == "secondmate")
        | select(remote(.) | not)
        | select(agent_state(.) == "ambiguous" or agent_state(.) == "unreadable"
                 or agent_state(.) == "unverified" or agent_state(.) == "not_checked")
        | finding("endpoint-inconclusive";.id;"notice";"inconclusive";
                  "secondmate liveness could not be established";agent_state(.);1)),
      ($snapshot.tasks[]?
        | select(remote(.))
        | select(probe(.) == "remote" and (agent_state(.) == "dead" or agent_state(.) == "missing"))
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
        | ($row.current.reason // "secondmate current state is unknown") as $reason
        | ($row.current.failure_kind // "unknown") as $failure
        | if $failure == "not_collected" then
            empty
          elif $failure == "timeout" then
            finding("secondmate-summary-unavailable";$row.id;"warning";"high";
                    $reason;"timeout";1)
          elif $failure == "invalid" then
            finding("secondmate-summary-invalid";$row.id;"error";"high";
                    $reason;"invalid";1)
          elif $failure == "child_unavailable" then
            finding("secondmate-summary-inconclusive";$row.id;"notice";"inconclusive";
                    $reason;"child_unavailable";1)
          elif $failure == "registry_incomplete" then
            finding("secondmate-summary-inconclusive";$row.id;"notice";"inconclusive";
                    $reason;"registry_incomplete";1)
          elif $failure == "unavailable" then
            finding("secondmate-summary-unavailable";$row.id;"warning";"high";
                    $reason;"unavailable";1)
          else
            finding("secondmate-summary-inconclusive";$row.id;"notice";"inconclusive";
                    ($reason | if . == "" then "secondmate current state is unknown" else . end);
                    "unknown";1)
          end),
      (if ($snapshot.secondmate_current.registry.available == false) then
        finding("secondmate-summary-inconclusive";"secondmate-registry";"notice";"inconclusive";
                ($snapshot.secondmate_current.registry.reason // "registered secondmate table is unavailable");
                "registry";1)
      else empty end),
      (if (($snapshot.secondmate_current.truncated // 0) > 0
           or $snapshot.secondmate_current.registry.complete == false
           or $snapshot.secondmate_current.registry.input_truncated == true
           or $snapshot.secondmate_current.registry.records_truncated == true) then
        finding("secondmate-summary-inconclusive";"secondmate-inventory";"notice";"inconclusive";
                "bounded secondmate inventory omitted records or source data";"truncated";
                (($snapshot.secondmate_current.truncated // 0) + 1))
      else empty end),
      ((($pending.records // [])
        | map(select(.phase == "delivery_unknown" or .phase == "recovery_failed" or .phase == "recovery_unknown"
                     or .recovery_verdict == "orphaned" or .recovery_verdict == "failed"
                     or .recovery_verdict == "unknown"))
        | group_by(.task_id)[]) as $g
        | ($g | length) as $n
        | ($g[0].task_id) as $task
        | finding("pending-reply-broken";$task;"error";"high";
                  ("broken reply delivery (" + ([ $g[].phase ] | unique | join(", ")) + ")");
                  "broken";$n)),
      ((($pending.records // [])
        | map(select(.recovery_verdict == "unreadable"))
        | group_by(.task_id)[]) as $g
        | ($g | length) as $n
        | finding("pending-reply-inconclusive";$g[0].task_id;"notice";"inconclusive";
                  "recovery sender or delivery identity could not be established";
                  "recovery-unreadable";$n)),
      ((($pending.records // [])
        | map(select(.phase != "escalated"))
        | map(select(
            (.phase == "awaiting_report" and .request_turn_completed_epoch != null
             and $now != 0 and (($now - .request_turn_completed_epoch) >= .grace_secs))
            or (.phase == "recovery_sent" and .recovery_turn_completed_epoch != null
                and $now != 0 and (($now - .recovery_turn_completed_epoch) >= .grace_secs))
          ))
        | group_by(.task_id)[]) as $g
        | ($g | length) as $n
        | finding("pending-reply-overdue";$g[0].task_id;"warning";"high";
                  "reply delivery is overdue by at least its recorded pending-reply grace";
                  "overdue";$n)),
      ((($inbox.records // [])
        | map(select(.age_seconds != null and .age_seconds >= $inbox_grace))
        | group_by(.task_id)[]) as $g
        | ($g | length) as $n
        | finding("steering-inbox-aged";$g[0].task_id;"warning";"high";
                  ($n|tostring) + " unacknowledged steering message(s) older than grace (" + ($inbox_grace|tostring) + "s)";
                  "aged";$n)),
      ($snapshot.tasks[]?
        | select(.kind != "secondmate")
        | select(.paths.status_log.last_event.handoff_required == true)
        | . as $t
        | ($t.paths.status_log.last_event.mtime_epoch) as $mtime
        | if ($mtime == null or $now_epoch == 0) then
            finding("missed-handoff-inconclusive";$t.id;"notice";"inconclusive";
                    "done-signal age could not be established";"mtime-unavailable";1)
          elif ($now_epoch - $mtime) < $handoff_stale then
            empty
          elif inbox_activity_available($t.id) == false then
            finding("missed-handoff-inconclusive";$t.id;"notice";"inconclusive";
                    "steering-inbox activity after the handoff signal could not be established";
                    "inbox-activity-unavailable";1)
          elif ((inbox_last($t.id) != null) and (inbox_last($t.id) >= $mtime)) then
            empty
          else
            finding("missed-handoff";$t.id;"warning";"high";
                    ("worker signaled done with no later status append or steering message for at least "
                     + ($handoff_stale|tostring) + "s");
                    "stale-done";1)
          end),
      ($snapshot.tasks[]?
        | select(.kind == "ship")
        | select((.pr.url // null) != null)
        | select(.pr.source == "meta")
        | select($prs.available == true)
        | .id as $id
        | if .current_state.state == "unknown" then
            finding("result-listener-inconclusive";$id;"notice";"inconclusive";
                    "worker lifecycle state is unknown, so PR-listener requirement cannot be established";
                    "worker-state-unknown";1)
          elif (.current_state.state == "working"
                or .current_state.state == "parked"
                or .current_state.state == "blocked"
                or .current_state.state == "paused")
               and (any($prs.records[]?;
                        .id == $id and (.armed == true or .terminal_notified == true)) | not) then
            finding("result-listener-missing";$id;"error";"high";
                    "in-flight ship with a recorded PR has no armed merge-poll listener";
                    "pr-poll";1)
          else empty end),
      (($listeners.records // [])[]
        | select(.owner == "missing" or .owner == "stale" or .owner == "orphaned")
        | finding("result-listener-missing";.id;"error";"high";
                  ("process-event source has no live result listener (owner=" + .owner + ")");
                  .owner;1)),
      (($listeners.records // [])[]
        | select(.owner == "uncertain" or .owner == "unreadable" or .owner == "invalid")
        | finding("result-listener-inconclusive";.id;"notice";"inconclusive";
                  "process-event listener liveness or registration could not be established";.owner;1)),
      (if $supervision.needed == true and $supervision.available == true
          and $supervision.ok == false then
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
  | ($findings | any(.confidence == "inconclusive")) as $inconclusive
  | $base
  | .findings = $findings
  | .status = (if $inconclusive then "inconclusive" elif $actionable then "actionable" else "healthy" end)
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
