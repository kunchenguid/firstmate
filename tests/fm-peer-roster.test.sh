#!/usr/bin/env bash
# Behavioral fixture for the read-only Herdr/Beads peer roster.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-peer-roster)
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
trap fm_test_cleanup EXIT
export FM_HOME="$TMP_ROOT/home" FIXTURE="$TMP_ROOT/fixture" HERDR_SESSION=default
mkdir -p "$FM_HOME/state/peers" "$FIXTURE"
printf 'alice\tAlice\nbob\tBob\ncharlie\tCharlie\n' > "$FM_HOME/state/peers/peers.tsv"
now=$(date +%s)
printf 'note [at=%s] [key=build]: work underway\n' "$now" > "$FM_HOME/state/peers/alice.log"
printf 'done [at=1]: old task\n' > "$FM_HOME/state/peers/bob.log"
cat > "$FM_HOME/state/job.meta" <<'META'
backend=herdr
herdr_session=default
herdr_tab_id=w1:t3
window=default:w1:p3
endpoint_task_id=job
META
cat > "$FIXTURE/current.json" <<'JSON'
{"result":{"pane":{"workspace_id":"w1","pane_id":"w1:p0"}}}
JSON
cat > "$FIXTURE/tabs.json" <<'JSON'
{"result":{"tabs":[{"tab_id":"w1:t1","workspace_id":"w1","label":"◐ Alice"},{"tab_id":"w1:t2","workspace_id":"w1","label":"Bob"},{"tab_id":"w1:t3","workspace_id":"w1","label":"fm-job"},{"tab_id":"w1:t4","workspace_id":"w1","label":"Stranger"}]}}
JSON
cat > "$FIXTURE/agents.json" <<'JSON'
{"result":{"agents":[{"tab_id":"w1:t1","workspace_id":"w1","pane_id":"w1:p1","agent_status":"working"},{"tab_id":"w1:t2","workspace_id":"w1","pane_id":"w1:p2","agent_status":"idle"},{"tab_id":"w1:t3","workspace_id":"w1","pane_id":"w1:p3","agent_status":"working"},{"tab_id":"w1:t4","workspace_id":"w1","pane_id":"w1:p4","agent_status":"idle"},{"tab_id":"w2:t1","workspace_id":"w2","pane_id":"w2:p1","agent_status":"working"}]}}
JSON
cat > "$FIXTURE/issues.json" <<'JSON'
[
  {"id":"b1","title":"Build","status":"in_progress","assignee":"alice","labels":["auditless"],"dependency_count":1,"dependencies":[{"type":"blocks","depends_on_id":"b2"}]},
  {"id":"b2","title":"Need deploy","status":"open","assignee":"other","labels":["platform"],"dependency_count":0},
  {"id":"b3","title":"Unowned","status":"open","labels":["usga"],"dependency_count":0},
  {"id":"b4","title":"Follow-up","status":"open","assignee":"bob","labels":["bridge"],"dependency_count":1,"dependencies":[{"type":"blocks","depends_on_id":"b5"}]},
  {"id":"b5","title":"Finished","status":"closed","labels":["bridge"],"dependency_count":0},
  {"id":"b6","title":"Stale reference","status":"open","assignee":"alice","labels":["auditless"],"dependency_count":1,"dependencies":[{"type":"blocks","depends_on_id":"missing"}]},
  {"id":"b7","title":"Label alias","status":"open","assignee":"Alice","labels":["agents"],"dependency_count":0},
  {"id":"b8","title":"Wait","status":"open","assignee":"alice","labels":["auditless"],"dependency_count":0,"dependencies":[{"type":"waits-for","depends_on_id":"b2"}]},
  {"id":"b9","title":"Conditional","status":"open","assignee":"alice","labels":["auditless"],"dependency_count":0,"dependencies":[{"type":"conditional-blocks","depends_on_id":"b2"}]},
  {"id":"b10","title":"Deleted blocker","status":"open","assignee":"charlie","labels":["bridge"],"dependency_count":1,"dependencies":[{"type":"blocks","depends_on_id":"b11"}]},
  {"id":"b11","title":"Deleted","status":"tombstone","labels":["bridge"],"dependency_count":0}
]
JSON
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
printf 'herdr %s\n' "$*" >> "$FIXTURE/calls"
case "$*" in
  'pane current --session default') cat "$FIXTURE/current.json" ;;
  'tab list --workspace w1 --session default') cat "$FIXTURE/tabs.json" ;;
  'agent list --session default') [ ! -e "$FIXTURE/herdr-fails" ] || exit 3; cat "$FIXTURE/agents.json" ;;
  *) exit 4 ;;
esac
SH
cat > "$FAKEBIN/bd" <<'SH'
#!/usr/bin/env bash
printf 'bd %s\n' "$*" >> "$FIXTURE/calls"
case "$*" in
  '--readonly --sandbox where --json') [ ! -e "$FIXTURE/bd-fails" ] || exit 3; printf '{"path":"fixture-board"}\n' ;;
  '--readonly --sandbox list --all --include-gates --include-infra --limit 0 --json') cat "$FIXTURE/issues.json" ;;
  *) exit 4 ;;
esac
SH
chmod +x "$FAKEBIN/herdr" "$FAKEBIN/bd"
export PATH="$FAKEBIN:$PATH"
ROSTER="$ROOT/bin/fm-peer-roster.sh"
"$ROSTER" --json > "$FIXTURE/out"
jq -e '.sources == {"herdr":"ok","beads":"ok","peers":"ok"} and .partial == false and
  .workspace == "w1" and .board == "fixture-board" and
  ([.peers[] | select(.name == "alice")][0] | .activity == "working" and .work_evidence == "blocked" and .report.freshness == "fresh" and
    [.beads[] | select(.id == "b1")][0].dependency_state == "blocked" and
    [.beads[] | select(.id == "b1")][0].dependencies[0].status == "open" and
    [.beads[] | select(.id == "b6")][0].dependency_state == "unknown" and
    [.beads[] | select(.id == "b8")][0].dependency_state == "blocked" and
    [.beads[] | select(.id == "b8")][0].dependencies[0].type == "waits-for" and
    [.beads[] | select(.id == "b9")][0].dependency_state == "unknown") and
  ([.peers[] | select(.name == "bob")][0] | .activity == "idle" and .work_evidence == "unknown" and .report.freshness == "stale" and
    [.beads[] | select(.id == "b4")][0].dependency_state == "clear") and
  ([.peers[] | select(.name == "charlie")][0] | .resolution == "unavailable" and .work_evidence == "unknown" and .report.freshness == "missing" and
    [.beads[] | select(.id == "b10")][0].dependency_state == "unknown" and
    [.beads[] | select(.id == "b10")][0].dependencies[0].status == "unknown") and
  [.managed_tabs[].workers[]] == ["job"] and [.unregistered_tabs[].label] == ["Stranger"] and
  [.unassigned_beads[].id] == ["b3"] and [.other_assigned_beads[].id] == ["b2","b7"]' "$FIXTURE/out" >/dev/null || fail 'roster failed to separate activity, reports, exact ownership and dependencies'
pass 'current agent inventory, managed workers, exact assignment and blockers remain distinct'
"$ROSTER" > "$FIXTURE/human"
[ "$(wc -l < "$FIXTURE/human")" -lt 30 ] || fail 'default roster not concise'

# An open blocked or needs-decision request key outweighs fresh, dependency-clear beads.
printf 'needs-decision [at=1] [key=gcloud-auth]: waiting on login\nnote [at=%s]: still here\n' "$now" > "$FM_HOME/state/peers/bob.log"
"$ROSTER" --json > "$FIXTURE/out"
jq -e '[.peers[] | select(.name == "bob")][0] | .work_evidence == "blocked" and .report.open_keys == ["gcloud-auth"] and .report.freshness == "fresh"' \
  "$FIXTURE/out" >/dev/null || fail 'open request key reported as tracked work'
printf 'resolved [at=%s] [key=other]: unrelated\n' "$now" >> "$FM_HOME/state/peers/bob.log"
"$ROSTER" --json > "$FIXTURE/out"
jq -e '[.peers[] | select(.name == "bob")][0] | .work_evidence == "blocked" and .report.open_keys == ["gcloud-auth"]' \
  "$FIXTURE/out" >/dev/null || fail 'resolved line for a different key closed the request'
printf 'resolved [at=%s] [key=gcloud-auth]: logged in\n' "$now" >> "$FM_HOME/state/peers/bob.log"
"$ROSTER" --json > "$FIXTURE/out"
jq -e '[.peers[] | select(.name == "bob")][0] | .work_evidence == "tracked" and .report.open_keys == []' \
  "$FIXTURE/out" >/dev/null || fail 'matching resolved line left the request open'
printf 'blocked [at=%s] [key=fm-zfi]: waiting on proof\ndone [at=%s]: other proof finished\n' "$now" "$now" > "$FM_HOME/state/peers/bob.log"
"$ROSTER" --json > "$FIXTURE/out"
jq -e '[.peers[] | select(.name == "bob")][0] | .work_evidence == "blocked" and .report.open_keys == ["fm-zfi"] and .report.freshness == "fresh"' \
  "$FIXTURE/out" >/dev/null || fail 'done line without a matching resolved closed the request'
printf 'blocked [key=fm-l1v at=1]: waiting on review\n' > "$FM_HOME/state/peers/bob.log"
"$ROSTER" --json > "$FIXTURE/out"
jq -e '[.peers[] | select(.name == "bob")][0] | .work_evidence == "blocked" and .report.open_keys == ["fm-l1v"]' \
  "$FIXTURE/out" >/dev/null || fail 'combined key tag did not open the request'
printf 'resolved [key=fm-l1v at=%s]: reviewed\n' "$now" >> "$FM_HOME/state/peers/bob.log"
"$ROSTER" --json > "$FIXTURE/out"
jq -e '[.peers[] | select(.name == "bob")][0] | .work_evidence != "blocked" and .report.open_keys == []' \
  "$FIXTURE/out" >/dev/null || fail 'combined-form resolved line did not match its blocked key'
printf 'blocked [at=1] [key=runner-github-app]: waiting on app install\nneeds-decision [at=%s] [key=runner-idle-stop]: stop idle runner?\n' "$now" > "$FM_HOME/state/peers/bob.log"
"$ROSTER" --json > "$FIXTURE/out"
jq -e '[.peers[] | select(.name == "bob")][0] | .work_evidence == "blocked" and .report.open_keys == ["runner-github-app","runner-idle-stop"]' \
  "$FIXTURE/out" >/dev/null || fail 'two open requests were not both listed'
"$ROSTER" > "$FIXTURE/human"
grep -q '^bob: matched activity=idle work=blocked open=runner-github-app,runner-idle-stop ' "$FIXTURE/human" || fail 'default view omitted the open request keys'
printf 'resolved [at=%s] [key=runner-idle-stop]: keep it\n' "$now" >> "$FM_HOME/state/peers/bob.log"
"$ROSTER" --json > "$FIXTURE/out"
jq -e '[.peers[] | select(.name == "bob")][0] | .work_evidence == "blocked" and .report.open_keys == ["runner-github-app"] and .report.freshness == "fresh"' \
  "$FIXTURE/out" >/dev/null || fail 'resolving the newer request hid the older open request'
"$ROSTER" > "$FIXTURE/human"
grep -q '^bob: matched activity=idle work=blocked open=runner-github-app ' "$FIXTURE/human" || fail 'default view did not drop the resolved key'
grep -q '^alice: matched activity=working work=blocked report=' "$FIXTURE/human" || fail 'default view printed open keys for a peer without open requests'
printf 'done [at=1]: old task\n' > "$FM_HOME/state/peers/bob.log"
pass 'unresolved peer request keeps work evidence blocked until its matching resolved line'

# A reused tab id with a different agent pane is not a Firstmate worker.
cp "$FM_HOME/state/job.meta" "$FIXTURE/job.meta"
printf 'window=default:w1:p9\n' >> "$FM_HOME/state/job.meta"
"$ROSTER" --json > "$FIXTURE/out"
jq -e '.managed_tabs == [] and
  [.unregistered_tabs[] | select(.tab_id == "w1:t3")][0].resolution == "unmapped"' "$FIXTURE/out" >/dev/null || fail 'stale worker metadata claimed a new pane'
cp "$FIXTURE/job.meta" "$FM_HOME/state/job.meta"
pass 'managed worker identification requires current tab and pane identity'

# A split tab with one managed worker still exposes its unmanaged agent.
cp "$FIXTURE/agents.json" "$FIXTURE/agents.saved.json"
jq '.result.agents += [{"tab_id":"w1:t3","workspace_id":"w1","pane_id":"w1:p8","agent_status":"idle"}]' \
  "$FIXTURE/agents.saved.json" > "$FIXTURE/agents.json"
"$ROSTER" --json > "$FIXTURE/out"
jq -e '[.managed_tabs[].pane_ids[]] == ["w1:p3"] and
  [.unregistered_tabs[] | select(.tab_id == "w1:t3")][0].pane_ids == ["w1:p8"]' "$FIXTURE/out" >/dev/null || fail 'mixed tab hid the hand-launched occupant'
cp "$FIXTURE/agents.saved.json" "$FIXTURE/agents.json"
pass 'split tab preserves unmanaged agent visibility'

# Ambiguous label resolution never attributes a pane to a specific peer.
cat > "$FIXTURE/tabs.json" <<'JSON'
{"result":{"tabs":[{"tab_id":"w1:t1","workspace_id":"w1","label":"Alice"},{"tab_id":"w1:t2","workspace_id":"w1","label":"Alice"}]}}
JSON
"$ROSTER" --json > "$FIXTURE/out"
jq -e '[.peers[] | select(.name == "alice")][0].resolution == "ambiguous" and
  ([.unregistered_tabs[] | select(.resolution == "ambiguous")] | length) == 2' "$FIXTURE/out" >/dev/null || fail 'duplicate tab labels silently resolved'
pass 'ambiguous agent tabs remain unresolved'

# A board read failure leaves the visible agent inventory intact.
touch "$FIXTURE/bd-fails"
if "$ROSTER" --json > "$FIXTURE/out"; then fail 'missing board exited successfully'; fi
jq -e '.sources.herdr == "ok" and .sources.beads == "unknown" and
  [.peers[] | select(.name == "alice")][0].resolution == "ambiguous" and
  [.peers[].beads_state] == ["unknown","unknown","unknown"] and .unassigned_beads == []' "$FIXTURE/out" >/dev/null || fail 'board failure hid the live inventory'
rm "$FIXTURE/bd-fails"
pass 'failed Beads read preserves visible Herdr evidence'

# Missing registration does not turn all observed tabs into known unowned peers.
mv "$FM_HOME/state/peers/peers.tsv" "$FIXTURE/peers.tsv"
if "$ROSTER" --json > "$FIXTURE/out"; then fail 'missing registry exited successfully'; fi
jq -e '.sources.peers == "unknown" and .sources.herdr == "ok" and
  [.unregistered_tabs[].resolution] == ["unknown","unknown"]' "$FIXTURE/out" >/dev/null || fail 'missing registry fabricated unowned agent tabs'
mv "$FIXTURE/peers.tsv" "$FM_HOME/state/peers/peers.tsv"
pass 'missing peer registry cannot claim unowned tabs'

# Unreadable worker metadata leaves peer ownership unknown, not hand-launched.
mkdir "$FM_HOME/state/bad.meta"
if "$ROSTER" --json > "$FIXTURE/out"; then fail 'unreadable metadata exited successfully'; fi
jq -e '.sources.peers == "unknown" and [.peers[].resolution] == ["unknown","unknown","unknown"] and
  [.unregistered_tabs[].resolution] == ["unknown","unknown"]' "$FIXTURE/out" >/dev/null || fail 'unreadable worker record fabricated peer ownership'
rmdir "$FM_HOME/state/bad.meta"
pass 'unreadable worker metadata cannot claim a hand-launched agent'

# A source failure cannot silently turn the inventory or dependency view empty.
touch "$FIXTURE/herdr-fails" "$FIXTURE/bd-fails"
if "$ROSTER" --json > "$FIXTURE/out"; then fail 'partial read exited successfully'; fi
jq -e '.partial == true and .sources.herdr == "unknown" and .sources.beads == "unknown" and
  [.peers[].resolution] == ["unknown","unknown","unknown"] and
  [.peers[].beads_state] == ["unknown","unknown","unknown"] and
  (.errors | length) == 2' "$FIXTURE/out" >/dev/null || fail 'failed reads misrepresented as empty or available'
pass 'unavailable Herdr/Beads reads produce explicit partial unknown state'

# Stubs reject any command not on the observation allowlist, including writes.
[ "$(wc -l < "$FIXTURE/calls")" -eq 93 ] || fail 'unexpected observation command count'
pass 'all CLI calls stayed on read-only observation paths'
