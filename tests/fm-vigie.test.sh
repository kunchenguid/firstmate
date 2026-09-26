#!/usr/bin/env bash
# Behavioral tests for the bounded native-source Vigie digest.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

VIGIE="$ROOT/bin/fm-vigie.sh"
SUCCESS="$ROOT/tests/fixtures/vigie/hermes-success.sh"
FAILURE="$ROOT/tests/fixtures/vigie/hermes-failure.sh"
TMP_ROOT=$(fm_test_tmproot fm-vigie)
SNAPSHOT="$TMP_ROOT/snapshot.sh"
TOOL="$TMP_ROOT/tool-update.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

cat > "$SNAPSHOT" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{
  "schema":"fm-fleet-snapshot.v1",
  "generated":"2026-09-10T15:00:00Z",
  "backlog":{"present":true,"records":[
    {"id":"hold:1","state":"Held","captain_actionable":true,"hold_age_days":21,"title":"Choisir canal"},
    {"id":"blocked%1","state":"Queued","blocked_by_ids":["dep:2","dep:1","dep:1"],"title":"Bloqué","age_days":17},
    {"id":"pr:1","state":"Queued","pr_url":"https://example.test/pull/1","title":"Relire PR","age_days":20}
  ]},
  "tasks":[
    {"id":"run:1","endpoint":{"agent_alive":false,"observed_at":"2026-09-08T15:00:00Z"},"age_days":2,"hints":{"open_decisions":[{"key":"client:1","summary":"Choisir le canal","age_days":16}]}}
  ],
  "secondmate_current":{"records":[{"id":"mate:1","decisions_open":[{"key":"scope:1","summary":"Choisir le scope","hold_age_days":15}]}]},
  "client_gates":[{"id":"gate:1","title":"Valider client","status":"pending","due":"2026-09-01","age_days":20}],
  "credential_evidence":[{"id":"gh:main","source":"GitHub","status":"unknown","observed_at":"2026-09-09T00:00:00Z","age_days":1,"secret":"must-not-leak"}],
  "pending_services":[{"id":"update:1","title":"Décider mise à jour","status":"pending","reason":"release","age_days":20}]
}'
SH
cat > "$TOOL" <<'SH'
#!/usr/bin/env bash
[ "${FM_TOOL_UPDATE_READ_ONLY:-}" = 1 ] || { printf 'read-only mode missing\n' >&2; exit 65; }
printf '%s\n' '{"alerts":[{"tool_id":"hermes:agent","installed_version":"1.0","available_version":"1.1","status":"update_available","observed_at":"2026-09-10T14:00:00Z"}]}'
SH
chmod +x "$SNAPSHOT" "$TOOL" "$SUCCESS" "$FAILURE"

run_vigie() {
  HERMES_KANBAN_TASK='task:1' \
  FM_FLEET_SNAPSHOT_BIN="$SNAPSHOT" \
  FM_VIGIE_HERMES_BIN="$SUCCESS" \
  FM_VIGIE_TOOL_UPDATE_BIN="$TOOL" \
  FM_VIGIE_NOW='2026-09-10T15:00:00Z' \
  "$VIGIE" "$@"
}

out=$(run_vigie --json) || fail "native success digest failed"
printf '%s\n' "$out" | jq -e '
  .schema == "fm-vigie.v1" and .generated == "2026-09-10T15:00:00Z" and
  .recommendation_total == (.observed_keys | length) and
  (.native | keys | length) == 12 and
  .native["hermes.kanban.stats"].status == "observed" and
  .native["firstmate.watched_tools"].observed_at == "2026-09-10T14:00:00Z" and
  .native["firstmate.dossier"].reason_code == "no_registered_reader" and
  .native["firstmate.reflex"].reason_code == "no_registered_reader" and
  (all(.observations[]; has("key") and has("category") and has("status") and has("source_id") and has("source_identity") and has("age_days") and has("observed_at") and (.evidence|type)=="array" and (.unknowns|type)=="array"))
' >/dev/null || fail "native source-run or observation schema is incomplete: $out"
printf '%s\n' "$out" | jq -e '
  ["firstmate.fleet_snapshot","hermes.kanban.task","hermes.kanban.stats","hermes.kanban.notify_list","hermes.monitoring.status","hermes.insights.day","hermes.doctor","hermes.cron.list","hermes.cron.doctor","firstmate.watched_tools"] as $sources |
  all($sources[]; . as $source | ($out.native[$source].status == "observed" or $out.native[$source].status == "empty"))
' --argjson out "$out" >/dev/null || fail "not every executable producer supplied successful fixture evidence"
printf '%s\n' "$out" | jq -e '
  (.observed_keys | index("pr:pr%3A1")) and
  (.observed_keys | index("decision:task:run%3A1:client%3A1")) and
  (.observed_keys | index("decision:secondmate:mate%3A1:scope%3A1")) and
  (.observed_keys | index("blocked:blocked%251")) and
  (.observed_keys | index("cron:job%3A1:missing_script")) and
  (.observed_keys | index("tool-update:hermes%3Aagent")) and
  ([.observations[] | select(.key=="kanban:ready")][0].age_days == 3)
' >/dev/null || fail "stable identities or authoritative age evidence missing: $out"
printf '%s\n' "$out" | grep -F 'must-not-leak' >/dev/null && fail "credential secret leaked"

fr=$(run_vigie --fr) || fail "French surface failed"
printf '%s\n' "$fr" | grep -F 'Vigie quotidienne (' >/dev/null || fail "French heading missing"
printf '%s\n' "$fr" | grep -F 'plafond 10)' >/dev/null || fail "French cap missing"
printf '%s\n' "$fr" | grep -F 'Relire la PR pr:1 : Relire PR, âge : 20 j' >/dev/null || fail "French PR template missing"
printf '%s\n' "$fr" | grep -F 'Débloquer blocked%1 : dépend de dep:1, dep:2, âge : 17 j' >/dev/null || fail "French blocker template missing"
printf '%s\n' "$fr" | grep -F 'Livraison : pilote approuvé uniquement ; bureau futur non activé ; planification désactivée.' >/dev/null || fail "French footer missing"
fr_all=$(FM_VIGIE_MAX=50 run_vigie --fr) || fail "complete French surface failed"
for label in "Relire la PR" "Traiter l’étape client" "Décider" "Vérifier les éléments d’accès" "Résoudre l’attente" "Répondre au blocage capitaine" "Débloquer" "Inspecter le worker" "Examiner la file Kanban"; do
  printf '%s\n' "$fr_all" | grep -F -- "$label" >/dev/null || fail "French category template missing: $label"
done

baseline="$TMP_ROOT/baseline.json"
printf '%s\n' "$out" | jq '.observed_keys += ["credential:doctor:retired"] | .recommendations = [.recommendations[0]]' > "$baseline"
event=$(FM_VIGIE_MAX=1 run_vigie --json --daily --event "$baseline") || fail "bounded event digest failed"
printf '%s\n' "$event" | jq -e '
  .recommendations|length == 1
' >/dev/null || fail "display cap ignored"
printf '%s\n' "$event" | jq -e '
  .recommendation_total > 1 and
  (.changes.resolved | index("credential:doctor:retired")) and
  (.changes.resurfaced | index("pr:pr%3A1")) and
  (.observed_keys | index("pr:pr%3A1"))
' >/dev/null || fail "uncapped deltas or age resurfacing are wrong: $event"

indeterminate_baseline="$TMP_ROOT/indeterminate.json"
printf '%s\n' '{"observed_keys":["credential:doctor:minimax-oauth"],"recommendations":[{"key":"credential:doctor:minimax-oauth","evidence":[{"source_id":"hermes.doctor"}]}]}' > "$indeterminate_baseline"
indeterminate=$(FM_FLEET_SNAPSHOT_BIN="$SNAPSHOT" FM_VIGIE_HERMES_BIN="$FAILURE" FM_VIGIE_TOOL_UPDATE_BIN=/missing VIGIE_FIXTURE_FAILURE=nonzero "$VIGIE" --json --event "$indeterminate_baseline") || fail "indeterminate-source digest failed"
printf '%s\n' "$indeterminate" | jq -e '.changes.resolved == [] and ([.changes.indeterminate[].key] | index("credential:doctor:minimax-oauth"))' >/dev/null || fail "unavailable current source falsely resolved a prior key"

hidden_indeterminate_baseline="$TMP_ROOT/hidden-indeterminate.json"
printf '%s\n' '{"observed_keys":["credential:doctor:hidden-prior"],"recommendations":[]}' > "$hidden_indeterminate_baseline"
hidden_indeterminate=$(FM_FLEET_SNAPSHOT_BIN="$SNAPSHOT" FM_VIGIE_HERMES_BIN="$FAILURE" FM_VIGIE_TOOL_UPDATE_BIN=/missing VIGIE_FIXTURE_FAILURE=nonzero "$VIGIE" --json --event "$hidden_indeterminate_baseline") || fail "hidden indeterminate-source digest failed"
printf '%s\n' "$hidden_indeterminate" | jq -e '.changes.resolved == [] and (.changes.indeterminate == [{"key":"credential:doctor:hidden-prior","reason_code":"nonzero_exit","source_id":"hermes.doctor"}])' >/dev/null || fail "uncapped prior key without displayed recommendation was falsely resolved"

legacy_observation_baseline="$TMP_ROOT/legacy-observation.json"
printf '%s\n' '{"observations":[{"key":"kanban:ready","source_id":"hermes.kanban.stats","actionable":false}],"recommendations":[]}' > "$legacy_observation_baseline"
legacy_observation=$(run_vigie --json --event "$legacy_observation_baseline") || fail "legacy observation baseline digest failed"
printf '%s\n' "$legacy_observation" | jq -e '(.changes.new | index("kanban:ready")) and (.unknowns | index("baseline_uncapped_keys_unavailable"))' >/dev/null || fail "non-recommendation legacy observation suppressed a new recommendation"

duplicate_keys_baseline="$TMP_ROOT/duplicate-keys.json"
printf '%s\n' '{"observed_keys":["kanban:ready","kanban:ready"],"recommendations":[]}' > "$duplicate_keys_baseline"
duplicate_keys=$(run_vigie --json --event "$duplicate_keys_baseline") || fail "duplicate prior-key digest failed"
printf '%s\n' "$duplicate_keys" | jq -e '(.changes.new | index("kanban:ready")) and .changes.resolved == [] and (.unknowns | index("baseline_uncapped_keys_unavailable"))' >/dev/null || fail "duplicate prior observed keys incorrectly enabled resolutions"

ranking_baseline="$TMP_ROOT/ranking-cap-baseline.json"
printf '%s\n' '{"observed_keys":["hold:hold%3A1"],"recommendations":[]}' > "$ranking_baseline"
ranking_cap=$(FM_VIGIE_SOURCE_RECORD_MAX=1 FM_VIGIE_MAX=50 run_vigie --json --event "$ranking_baseline") || fail "delta-cap ranking digest failed"
printf '%s\n' "$ranking_cap" | jq -e '.changes.meta.new.total > 1 and .changes.meta.new.truncated and ([.recommendations[].key] | index("kanban:ready")) < ([.recommendations[].key] | index("hold:hold%3A1"))' >/dev/null || fail "delta array cap changed recommendation ranking"

source_capped=$(FM_VIGIE_SOURCE_RECORD_MAX=1 run_vigie --json) || fail "source-record capped digest failed"
printf '%s\n' "$source_capped" | jq -e '([.observations[] | select(.source_id=="firstmate.fleet_snapshot")] | length)==1 and ([.observations[] | select(.key=="hold:hold%3A1")] | length)==1' >/dev/null || fail "source record cap was not enforced across snapshot arrays"
source_cap_baseline="$TMP_ROOT/source-cap-baseline.json"
printf '%s\n' '{"observed_keys":["blocked:blocked%251"],"recommendations":[]}' > "$source_cap_baseline"
source_cap_delta=$(FM_VIGIE_SOURCE_RECORD_MAX=1 run_vigie --json --event "$source_cap_baseline") || fail "source-record cap delta digest failed"
printf '%s\n' "$source_cap_delta" | jq -e '.native["firstmate.fleet_snapshot"].status == "unknown" and .native["firstmate.fleet_snapshot"].reason_code == "record_cap_reached" and .changes.resolved == [] and (.changes.indeterminate == [{"key":"blocked:blocked%251","reason_code":"record_cap_reached","source_id":"firstmate.fleet_snapshot"}])' >/dev/null || fail "source record cap caused a false resolution"

SILENT_TOOL="$TMP_ROOT/silent-tool.sh"
cat > "$SILENT_TOOL" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$SILENT_TOOL"
silent_tool=$(FM_FLEET_SNAPSHOT_BIN="$SNAPSHOT" FM_VIGIE_HERMES_BIN="$SUCCESS" FM_VIGIE_TOOL_UPDATE_BIN="$SILENT_TOOL" HERMES_KANBAN_TASK='' "$VIGIE" --json) || fail "silent watched-tool digest failed"
printf '%s\n' "$silent_tool" | jq -e '.native["firstmate.watched_tools"].status == "unknown" and .native["firstmate.watched_tools"].reason_code == "silent_completion_not_complete"' >/dev/null || fail "silent watched-tool completion was not classified as unknown"

SILENT_NOTIFY="$TMP_ROOT/silent-notify.sh"
cat > "$SILENT_NOTIFY" <<SH
#!/usr/bin/env bash
if [ "\$*" = "kanban notify-list" ]; then
  exit 0
fi
exec "$SUCCESS" "\$@"
SH
chmod +x "$SILENT_NOTIFY"
silent_notify=$(FM_FLEET_SNAPSHOT_BIN="$SNAPSHOT" FM_VIGIE_HERMES_BIN="$SILENT_NOTIFY" FM_VIGIE_TOOL_UPDATE_BIN="$TOOL" HERMES_KANBAN_TASK=task:1 "$VIGIE" --json) || fail "silent notification-list digest failed"
printf '%s\n' "$silent_notify" | jq -e '.native["hermes.kanban.notify_list"].status == "unknown" and .native["hermes.kanban.notify_list"].reason_code == "silent_completion_not_complete"' >/dev/null || fail "silent notification list was classified as complete empty evidence"

normalizer=$(python3 - "$ROOT" <<'PY'
import importlib.util
import json
import pathlib
import sys

sys.dont_write_bytecode = True
path = pathlib.Path(sys.argv[1]) / "bin" / "fm_vigie.py"
spec = importlib.util.spec_from_file_location("fm_vigie", path)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)

def row(key, category, source, value, age):
    return module.observation(
        key, category, source, value, value, "fixture", {"source_id": source, "value": value},
        "2026-09-10T15:00:00Z", action=f"act:{value}", age_days=age,
    )

rows = [
    row("duplicate-key", "ready_pr", "source.a", "a", 3),
    row("duplicate-key", "ready_pr", "source.b", "b", 4),
    row("collision-key", "ready_pr", "source.a", "a", 1),
    row("collision-key", "client_gate", "source.b", "b", 1),
]
print(json.dumps(module.merge_observations(rows), sort_keys=True))
PY
) || fail "normalizer executable probe failed"
printf '%s\n' "$normalizer" | jq -e '
  ([.[] | select(.key=="duplicate-key")] | length) == 1 and
  ([.[] | select(.key=="duplicate-key")][0].evidence | length) == 2 and
  ([.[] | select(.key=="duplicate-key")][0].age_days == null) and
  ([.[] | select(.key=="duplicate-key")][0].unknowns | index("conflicting_authoritative_age")) and
  ([.[] | select(.key=="collision-key")] | length) == 1 and
  ([.[] | select(.key=="collision-key")][0].category == "identity_collision") and
  ([.[] | select(.key=="collision-key")][0].actionable == false) and
  ([.[] | select(.key=="collision-key")][0].unknowns | index("conflicting_category_identity"))
' >/dev/null || fail "duplicate merge, authoritative age conflict, or identity collision semantics failed"

UNKNOWN="$TMP_ROOT/unknown.sh"
cat > "$UNKNOWN" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"schema":"fm-fleet-snapshot.v1","generated":"2026-09-10T15:00:00Z","backlog":{"present":false},"tasks":[]}'
SH
chmod +x "$UNKNOWN"
unknown=$(FM_FLEET_SNAPSHOT_BIN="$UNKNOWN" FM_VIGIE_HERMES_BIN="$SUCCESS" FM_VIGIE_TOOL_UPDATE_BIN=/missing HERMES_KANBAN_TASK='' "$VIGIE" --json) || fail "unknown digest failed"
printf '%s\n' "$unknown" | jq -e '
  .inventory.ready_prs.status == "unknown" and
  .inventory.client_gates.status == "unknown" and
  .inventory.keyed_decisions.status == "unknown" and
  .native["hermes.kanban.task"].reason_code == "task_id_not_supplied" and
  .native["firstmate.watched_tools"].reason_code == "command_missing"
' >/dev/null || fail "absent evidence was not preserved as unknown/unavailable: $unknown"

EMPTY="$TMP_ROOT/empty.sh"
cat > "$EMPTY" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"schema":"fm-fleet-snapshot.v1","generated":"2026-09-10T15:00:00Z","backlog":{"present":true,"records":[]},"tasks":[],"secondmate_current":{"records":[]},"ready_prs":[],"client_gates":[],"credential_evidence":[],"pending_services":[]}'
SH
chmod +x "$EMPTY"
empty=$(FM_FLEET_SNAPSHOT_BIN="$EMPTY" FM_VIGIE_HERMES_BIN="$SUCCESS" FM_VIGIE_TOOL_UPDATE_BIN="$TOOL" HERMES_KANBAN_TASK='' "$VIGIE" --json) || fail "empty digest failed"
printf '%s\n' "$empty" | jq -e '.inventory.ready_prs.status == "empty" and .inventory.client_gates.status == "empty"' >/dev/null || fail "explicit empty arrays not preserved"

missing_status=0
missing=$(FM_FLEET_SNAPSHOT_BIN=/missing FM_VIGIE_HERMES_BIN=/missing FM_VIGIE_TOOL_UPDATE_BIN=/missing HERMES_KANBAN_TASK=task:1 "$VIGIE" --json) || missing_status=$?
[ "$missing_status" -ne 0 ] || fail "all-missing producers should exit nonzero"
printf '%s\n' "$missing" | jq -e '
  all(.native[]; .status == "unavailable" or .status == "unknown") and
  all(["firstmate.fleet_snapshot","hermes.kanban.task","hermes.kanban.stats","hermes.kanban.notify_list","hermes.monitoring.status","hermes.insights.day","hermes.doctor","hermes.cron.list","hermes.cron.doctor","firstmate.watched_tools"][]; . as $source | $missing.native[$source].reason_code == "command_missing")
' --argjson missing "$missing" >/dev/null || fail "missing executable producers not unavailable"

nonzero=$(FM_FLEET_SNAPSHOT_BIN="$SNAPSHOT" FM_VIGIE_HERMES_BIN="$FAILURE" FM_VIGIE_TOOL_UPDATE_BIN="$TOOL" HERMES_KANBAN_TASK=task:1 VIGIE_FIXTURE_FAILURE=nonzero "$VIGIE" --json) || fail "nonzero-source digest failed"
printf '%s\n' "$nonzero" | jq -e '
  all(["hermes.kanban.task","hermes.kanban.stats","hermes.kanban.notify_list","hermes.monitoring.status","hermes.insights.day","hermes.doctor","hermes.cron.list","hermes.cron.doctor"][]; . as $source | $nonzero.native[$source].reason_code == "nonzero_exit" and $nonzero.native[$source].exit_code == 7 and ($nonzero.native[$source].stdout|contains("stdout")) and ($nonzero.native[$source].stderr|contains("stderr")))
' --argjson nonzero "$nonzero" >/dev/null || fail "nonzero Hermes producer provenance missing"

timed=$(FM_FLEET_SNAPSHOT_BIN="$SNAPSHOT" FM_VIGIE_HERMES_BIN="$FAILURE" FM_VIGIE_TOOL_UPDATE_BIN="$TOOL" HERMES_KANBAN_TASK=task:1 FM_VIGIE_NATIVE_TIMEOUT=1 VIGIE_FIXTURE_FAILURE=timeout "$VIGIE" --json) || fail "timeout-source digest failed"
printf '%s\n' "$timed" | jq -e '
  all(["hermes.kanban.task","hermes.kanban.stats","hermes.kanban.notify_list","hermes.monitoring.status","hermes.insights.day","hermes.doctor","hermes.cron.list","hermes.cron.doctor"][]; . as $source | $timed.native[$source].reason_code == "timeout" and $timed.native[$source].timed_out)
' --argjson timed "$timed" >/dev/null || fail "timeout Hermes producer provenance missing"

invalid=$(FM_FLEET_SNAPSHOT_BIN="$SNAPSHOT" FM_VIGIE_HERMES_BIN="$FAILURE" FM_VIGIE_TOOL_UPDATE_BIN="$TOOL" HERMES_KANBAN_TASK=task:1 VIGIE_FIXTURE_FAILURE=invalid-json "$VIGIE" --json) || fail "invalid-json source digest failed"
printf '%s\n' "$invalid" | jq -e '
  .native["hermes.kanban.task"].reason_code == "invalid_json" and
  .native["hermes.kanban.stats"].reason_code == "invalid_json" and
  all(["hermes.kanban.notify_list","hermes.monitoring.status","hermes.insights.day","hermes.doctor","hermes.cron.list","hermes.cron.doctor"][]; . as $source | $invalid.native[$source].status == "unknown")
' --argjson invalid "$invalid" >/dev/null || fail "malformed or unparseable Hermes producer provenance missing"

snapshot_nonzero=$(FM_FLEET_SNAPSHOT_BIN="$FAILURE" FM_VIGIE_HERMES_BIN="$SUCCESS" FM_VIGIE_TOOL_UPDATE_BIN="$TOOL" HERMES_KANBAN_TASK=task:1 VIGIE_FIXTURE_FAILURE=nonzero "$VIGIE" --json) || fail "snapshot nonzero digest failed"
printf '%s\n' "$snapshot_nonzero" | jq -e '.native["firstmate.fleet_snapshot"].status == "unavailable" and .native["firstmate.fleet_snapshot"].reason_code == "nonzero_exit" and .native["firstmate.fleet_snapshot"].exit_code == 7' >/dev/null || fail "snapshot nonzero provenance missing"

snapshot_timeout=$(FM_FLEET_SNAPSHOT_BIN="$FAILURE" FM_VIGIE_HERMES_BIN="$SUCCESS" FM_VIGIE_TOOL_UPDATE_BIN="$TOOL" HERMES_KANBAN_TASK=task:1 FM_VIGIE_NATIVE_TIMEOUT=1 VIGIE_FIXTURE_FAILURE=timeout "$VIGIE" --json) || fail "snapshot timeout digest failed"
printf '%s\n' "$snapshot_timeout" | jq -e '.native["firstmate.fleet_snapshot"].status == "unavailable" and .native["firstmate.fleet_snapshot"].reason_code == "timeout" and .native["firstmate.fleet_snapshot"].timed_out' >/dev/null || fail "snapshot timeout provenance missing"

snapshot_malformed=$(FM_FLEET_SNAPSHOT_BIN="$FAILURE" FM_VIGIE_HERMES_BIN="$SUCCESS" FM_VIGIE_TOOL_UPDATE_BIN="$TOOL" HERMES_KANBAN_TASK=task:1 VIGIE_FIXTURE_FAILURE=invalid-json "$VIGIE" --json) || fail "snapshot malformed digest failed"
printf '%s\n' "$snapshot_malformed" | jq -e '.native["firstmate.fleet_snapshot"].status == "unavailable" and .native["firstmate.fleet_snapshot"].reason_code == "invalid_json"' >/dev/null || fail "snapshot malformed provenance missing"

snapshot_truncated=$(FM_FLEET_SNAPSHOT_BIN="$FAILURE" FM_VIGIE_HERMES_BIN="$SUCCESS" FM_VIGIE_TOOL_UPDATE_BIN="$TOOL" HERMES_KANBAN_TASK=task:1 FM_VIGIE_NATIVE_MAX_BYTES=256 VIGIE_FIXTURE_FAILURE=oversized "$VIGIE" --json) || fail "snapshot truncated digest failed"
printf '%s\n' "$snapshot_truncated" | jq -e '.native["firstmate.fleet_snapshot"].status == "unknown" and .native["firstmate.fleet_snapshot"].reason_code == "output_truncated" and .native["firstmate.fleet_snapshot"].stdout_truncated' >/dev/null || fail "snapshot truncation provenance missing"

tool_nonzero=$(FM_FLEET_SNAPSHOT_BIN="$SNAPSHOT" FM_VIGIE_HERMES_BIN="$SUCCESS" FM_VIGIE_TOOL_UPDATE_BIN="$FAILURE" HERMES_KANBAN_TASK=task:1 VIGIE_FIXTURE_FAILURE=nonzero "$VIGIE" --json) || fail "watched-tool nonzero digest failed"
printf '%s\n' "$tool_nonzero" | jq -e '.native["firstmate.watched_tools"].status == "unavailable" and .native["firstmate.watched_tools"].reason_code == "nonzero_exit" and .native["firstmate.watched_tools"].exit_code == 7' >/dev/null || fail "watched-tool nonzero provenance missing"

tool_timeout=$(FM_FLEET_SNAPSHOT_BIN="$SNAPSHOT" FM_VIGIE_HERMES_BIN="$SUCCESS" FM_VIGIE_TOOL_UPDATE_BIN="$FAILURE" HERMES_KANBAN_TASK=task:1 FM_VIGIE_NATIVE_TIMEOUT=1 VIGIE_FIXTURE_FAILURE=timeout "$VIGIE" --json) || fail "watched-tool timeout digest failed"
printf '%s\n' "$tool_timeout" | jq -e '.native["firstmate.watched_tools"].status == "unavailable" and .native["firstmate.watched_tools"].reason_code == "timeout" and .native["firstmate.watched_tools"].timed_out' >/dev/null || fail "watched-tool timeout provenance missing"

tool_malformed=$(FM_FLEET_SNAPSHOT_BIN="$SNAPSHOT" FM_VIGIE_HERMES_BIN="$SUCCESS" FM_VIGIE_TOOL_UPDATE_BIN="$FAILURE" HERMES_KANBAN_TASK=task:1 VIGIE_FIXTURE_FAILURE=invalid-json "$VIGIE" --json) || fail "watched-tool malformed digest failed"
printf '%s\n' "$tool_malformed" | jq -e '.native["firstmate.watched_tools"].status == "unavailable" and .native["firstmate.watched_tools"].reason_code == "invalid_json"' >/dev/null || fail "watched-tool malformed provenance missing"

tool_truncated=$(FM_FLEET_SNAPSHOT_BIN="$SNAPSHOT" FM_VIGIE_HERMES_BIN="$SUCCESS" FM_VIGIE_TOOL_UPDATE_BIN="$FAILURE" HERMES_KANBAN_TASK=task:1 FM_VIGIE_NATIVE_MAX_BYTES=256 VIGIE_FIXTURE_FAILURE=oversized "$VIGIE" --json) || fail "watched-tool truncated digest failed"
printf '%s\n' "$tool_truncated" | jq -e '.native["firstmate.watched_tools"].status == "unknown" and .native["firstmate.watched_tools"].reason_code == "output_truncated" and .native["firstmate.watched_tools"].stdout_truncated' >/dev/null || fail "watched-tool truncation provenance missing"

CAPPED_TOOL="$TMP_ROOT/capped-tool.sh"
cat > "$CAPPED_TOOL" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"alerts":[{"tool_id":"first","status":"update_available"},{"tool_id":"hidden","status":"update_available"}]}'
SH
chmod +x "$CAPPED_TOOL"
capped_tool_baseline="$TMP_ROOT/capped-tool-baseline.json"
printf '%s\n' '{"observed_keys":["tool-update:hidden"],"recommendations":[]}' > "$capped_tool_baseline"
capped_tool=$(FM_FLEET_SNAPSHOT_BIN="$EMPTY" FM_VIGIE_HERMES_BIN="$SUCCESS" FM_VIGIE_TOOL_UPDATE_BIN="$CAPPED_TOOL" HERMES_KANBAN_TASK=task:1 FM_VIGIE_SOURCE_RECORD_MAX=1 "$VIGIE" --json --event "$capped_tool_baseline") || fail "capped watched-tool digest failed"
printf '%s\n' "$capped_tool" | jq -e '.native["firstmate.watched_tools"].status == "unknown" and .native["firstmate.watched_tools"].reason_code == "record_cap_reached" and .changes.resolved == [] and (.changes.indeterminate == [{"key":"tool-update:hidden","reason_code":"record_cap_reached","source_id":"firstmate.watched_tools"}])' >/dev/null || fail "watched-tool record cap caused a false resolution"

STDERR_HERMES="$TMP_ROOT/stderr-hermes.sh"
cat > "$STDERR_HERMES" <<SH
#!/usr/bin/env bash
"$SUCCESS" "\$@"
status=\$?
python3 -c 'import sys; print("x" * 5000, file=sys.stderr)'
exit \$status
SH
STDERR_TOOL="$TMP_ROOT/stderr-tool.sh"
cat > "$STDERR_TOOL" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"alerts":[]}'
python3 -c 'import sys; print("x" * 5000, file=sys.stderr)'
SH
chmod +x "$STDERR_HERMES" "$STDERR_TOOL"
stderr_truncated=$(FM_FLEET_SNAPSHOT_BIN="$EMPTY" FM_VIGIE_HERMES_BIN="$STDERR_HERMES" FM_VIGIE_TOOL_UPDATE_BIN="$STDERR_TOOL" HERMES_KANBAN_TASK=task:1 FM_VIGIE_NATIVE_MAX_BYTES=256 "$VIGIE" --json) || fail "stderr-truncated digest failed"
printf '%s\n' "$stderr_truncated" | jq -e '.native["hermes.kanban.stats"].status == "unknown" and .native["hermes.kanban.stats"].reason_code == "output_truncated" and .native["hermes.kanban.stats"].stderr_truncated and .native["firstmate.watched_tools"].status == "unknown" and .native["firstmate.watched_tools"].reason_code == "output_truncated" and .native["firstmate.watched_tools"].stderr_truncated' >/dev/null || fail "stderr truncation was overwritten by successful parsing"

oversized_status=0
oversized=$(FM_FLEET_SNAPSHOT_BIN="$SNAPSHOT" FM_VIGIE_HERMES_BIN="$FAILURE" FM_VIGIE_TOOL_UPDATE_BIN=/missing FM_VIGIE_NATIVE_MAX_BYTES=64 VIGIE_FIXTURE_FAILURE=oversized "$VIGIE" --json) || oversized_status=$?
[ "$oversized_status" -ne 0 ] || fail "all-truncated producers should exit nonzero"
printf '%s\n' "$oversized" | jq -e '.native["hermes.doctor"].stdout_truncated and (.native["hermes.doctor"].stdout|length)==64 and .native["hermes.doctor"].status == "unknown"' >/dev/null || fail "native byte cap missing"

$VIGIE --help >/dev/null || fail "help failed"
before=$(find "$TMP_ROOT" -type f -print0 | sort -z | xargs -0 sha256sum; sha256sum "$SUCCESS" "$FAILURE")
repo_before=$(find "$ROOT" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum)
files_before=$(find "$TMP_ROOT" -type f -printf '%P\n' | sort)
run_vigie --json --event "$baseline" >/dev/null || fail "repeat read-only digest failed"
after=$(find "$TMP_ROOT" -type f -print0 | sort -z | xargs -0 sha256sum; sha256sum "$SUCCESS" "$FAILURE")
repo_after=$(find "$ROOT" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum)
files_after=$(find "$TMP_ROOT" -type f -printf '%P\n' | sort)
[ "$before" = "$after" ] || fail "digest mutated a fixture or baseline"
[ "$files_before" = "$files_after" ] || fail "digest created files in fixture tree"
[ "$repo_before" = "$repo_after" ] || fail "digest wrote outside the test-owned fixture tree"

pass "verified native-source JSON, failure, delta, French, and read-only surfaces"
