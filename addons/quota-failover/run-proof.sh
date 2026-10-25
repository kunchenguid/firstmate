#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
evidence=${DONE_DONE_EVIDENCE_ROOT:?}
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
home=$tmp/home; stub=$tmp/bin
mkdir -p "$home/state" "$home/config" "$home/bin" "$stub"
cat >"$home/bin/fm-stub-lib.sh" <<'LIB'
fm_meta_get() { sed -n "s|^$2=||p" "$1" | tail -n 1; }
fm_backend_of_meta() { echo fixture; }
fm_backend_target_of_meta() { fm_meta_get "$1" endpoint_task_id; }
fm_backend_visible_capture() { [ ! -f "$FM_HOME/state/$2.screen" ] || cat "$FM_HOME/state/$2.screen"; return 0; }
fm_busy_classify_meta() { echo 'idle no-busy-record'; }
fm_busy_record_read() { echo ''; }
FM_QUOTA_ROW_JQ='def quota_lane($harness; $model): ""; def quota_row($snapshot; $provider; $lane): null;'
fm_quota_json_valid() { jq -e '.schemaVersion == 5 and (.providers | type) == "array"' >/dev/null 2>&1; }
fm_quota_single_provider_for_harness() { return 1; }
fm_parent_channel_report() { :; }
fm_run_timed() { shift; "$@"; }
LIB
for lib in fm-backend.sh fm-busy-lib.sh fm-quota-axi-lib.sh fm-parent-channel-lib.sh; do ln -s fm-stub-lib.sh "$home/bin/$lib"; done
cat >"$home/bin/fm-control.sh" <<'CONTROL'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FM_HOME/state/control.log"
CONTROL
cat >"$home/bin/fm-crew-state.sh" <<'CREW'
#!/usr/bin/env bash
echo 'state: working · source: fixture'
CREW
cat >"$stub/quota-axi" <<'QUOTA'
#!/usr/bin/env bash
echo '{"schemaVersion":5,"providers":[]}'
QUOTA
cat >"$stub/claude" <<'CLAUDE'
#!/usr/bin/env bash
if [ "${CLAUDE_LIMIT:-}" = yes ]; then echo "You've hit your usage limit for your plan; try again in 3h"; exit 1; fi
echo PONG
CLAUDE
chmod +x "$home/bin/fm-control.sh" "$home/bin/fm-crew-state.sh" "$stub/quota-axi" "$stub/claude"
cat >"$home/config/crew-dispatch.json" <<'DISPATCH'
{"rules":[],"default":[{"harness":"claude","model":"claude-haiku-5-5"}]}
DISPATCH
printf 'endpoint_task_id=cw\nharness=claude\nmodel=claude-haiku-5-5\nkind=crewmate\nspawn_gen=s0.cw\n' >"$home/state/cw.meta"
printf 'quota exhausted' >"$home/state/cw.screen"
: >"$home/state/quota-failover.log"
export PATH="$stub:$PATH" QUOTA_FAILOVER_TEST_SECS=1 QUOTA_FAILOVER_PROBE_SECS=0 QUOTA_FAILOVER_RETEST_SECS=0 QUOTA_FAILOVER_STALL_SECS=0
"$repo/quota-failover/quota-failover" "$home"
cp "$home/state/cw.screen" "$evidence/wrapper-text.txt"
cp "$home/config/crew-dispatch.json" "$evidence/after-wrapper.json"
if ! jq -e '.default[0].model == "claude-haiku-5-5"' "$home/config/crew-dispatch.json" >/dev/null; then echo 'wrapper text unexpectedly removed route' >&2; exit 1; fi
cp "$home/state/quota-failover.log" "$evidence/wrapper-log.txt"
: >"$home/state/quota-failover.log"
printf "%s\n" "You've hit your usage limit for your plan; try again in 3h" >"$home/state/cw.screen"
cp "$home/state/cw.screen" "$evidence/real-limit-banner.txt"
CLAUDE_LIMIT=yes "$repo/quota-failover/quota-failover" "$home"
cp "$home/config/crew-dispatch.json" "$evidence/after-limit-banner.json"
cp "$home/state/quota-failover-dead.json" "$evidence/dead-routes.json"
cp "$home/state/quota-failover.log" "$evidence/limit-log.txt"
jq -e '.default | length == 0' "$home/config/crew-dispatch.json" >/dev/null
jq -e 'any(.[]; .model == "claude-haiku-5-5")' "$home/state/quota-failover-dead.json" >/dev/null
jq -n --arg wrapperScreen "$(cat "$evidence/wrapper-text.txt")" --slurpfile wrapperDispatch "$evidence/after-wrapper.json" --rawfile wrapperLog "$evidence/wrapper-log.txt" --arg limitScreen "$(cat "$evidence/real-limit-banner.txt")" --slurpfile limitDispatch "$evidence/after-limit-banner.json" --slurpfile dead "$evidence/dead-routes.json" --rawfile limitLog "$evidence/limit-log.txt" '{wrapper_case:{screen:$wrapperScreen,dispatch:$wrapperDispatch[0],log:$wrapperLog,route_retained:($wrapperDispatch[0].default[0].model == "claude-haiku-5-5")},limit_case:{screen:$limitScreen,probe:{command:"claude -p --model claude-haiku-5-5",exit:1,output:"You\u0027ve hit your usage limit for your plan; try again in 3h"},dispatch:$limitDispatch[0],dead_routes:$dead[0],log:$limitLog,route_removed:(($limitDispatch[0].default|length)==0 and any($dead[0][]; .model=="claude-haiku-5-5"))}}' >"$evidence/result.json"
printf 'PASS: wrapper screen retained route; real limit banner plus confirming one-line probe removed route.\n'
