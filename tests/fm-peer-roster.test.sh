#!/usr/bin/env bash
# Behavioral fixture for the deterministic peer roster (v2): parked workers,
# stale rows, keyed blocked decisions, secondmate children, the on_captain
# section, and proof that no free-text fragments survive into posture.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-peer-roster)
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
trap fm_test_cleanup EXIT
export FM_HOME="$TMP_ROOT/home" FIXTURE="$TMP_ROOT/fixture" HERDR_SESSION=default
mkdir -p "$FM_HOME/state/peers" "$FM_HOME/data" "$FIXTURE"
# bd is stubbed by PATH below; the fixture must never accidentally reach a
# real store from this tmp home.
printf 'alice\tAlice\nbob\tBob\ncharlie\tCharlie\n' > "$FM_HOME/state/peers/peers.tsv"
now=$(date +%s)
# An open keyed `blocked` line is what flips alice's posture - `note` never
# opens a key (the open-key pass only looks at blocked/needs-decision).
printf 'blocked [at=%s] [key=build]: work underway\n' "$now" > "$FM_HOME/state/peers/alice.log"
printf 'done [at=1]: old task\n' > "$FM_HOME/state/peers/bob.log"

# A worker whose status declares `paused` is parked.
cat > "$FM_HOME/state/parked-worker.meta" <<'META'
backend=herdr
window=default:w1:p9
endpoint_task_id=parked-worker
kind=ship
mode=direct-PR
META
earlier=$((now - 100))
printf 'working [at=%s]: exploring\npaused [at=%s]: waiting on platform kstage\n' "$earlier" "$now" > "$FM_HOME/state/parked-worker.status"

# A worker whose latest line is an open keyed need is blocked deterministically.
cat > "$FM_HOME/state/blocked-worker.meta" <<'META'
backend=herdr
window=default:w1:p10
endpoint_task_id=blocked-worker
kind=ship
META
earlier=$((now - 60))
printf 'blocked [at=%s] [key=gcloud-auth]: waiting on login\nnote [at=%s]: subsequent chatter\n' "$earlier" "$now" > "$FM_HOME/state/blocked-worker.status"

# A secondmate home with its own state and a live child.
mkdir -p "$TMP_ROOT/mate-home/state" "$TMP_ROOT/mate-home/data"
printf '# Backlog\n\n## Queued\n- [ ] t1 - Sample (kind: ship) (since 2026-10-12) (hold: fm-hold-v1:c2FtcGxl) (hold-kind: captain)\n' > "$TMP_ROOT/mate-home/data/backlog.md"
printf '%s\n' "- platform - Sample secondmate. (home: $TMP_ROOT/mate-home; scope: sample scope)" > "$FM_HOME/data/secondmates.md"
cat > "$TMP_ROOT/mate-home/state/child-one.meta" <<'META'
backend=herdr
window=default:w1:p11
endpoint_task_id=child-one
kind=ship
worktree=/tmp/child-one
META
earlier=$((now - 30))
printf 'working [at=%s]: on the secondmate lane\n' "$earlier" > "$TMP_ROOT/mate-home/state/child-one.status"
cat > "$TMP_ROOT/mate-home/state/stale-child.meta" <<'META'
backend=herdr
window=default:w1:p12
endpoint_task_id=stale-child
kind=ship
META
earlier=$((now - 7200))
printf 'note [at=%s]: seven-thousand seconds ago\n' "$earlier" > "$TMP_ROOT/mate-home/state/stale-child.status"
touch -t "$(date -r "$earlier" '+%Y%m%d%H%M.%S')" "$TMP_ROOT/mate-home/state/stale-child.status"

# Peers: bob's latest report has no timestamp, so the roster must not fabricate
# one; charlie is unmatched by Herdr so its activity stays unknown; alice is
# fresh but should not float past her unresolved `build` key.
printf '{"result":{"pane":{"workspace_id":"w1","pane_id":"w1:p0"}}}' > "$FIXTURE/current.json"
cat > "$FIXTURE/tabs.json" <<'JSON'
{"result":{"tabs":[
  {"tab_id":"w1:t1","workspace_id":"w1","label":"Alice"},
  {"tab_id":"w1:t2","workspace_id":"w1","label":"Bob"},
  {"tab_id":"w1:t3","workspace_id":"w1","label":"fm-parked-worker"},
  {"tab_id":"w1:t4","workspace_id":"w1","label":"fm-blocked-worker"},
  {"tab_id":"w1:t5","workspace_id":"w1","label":"fm-child-one"},
  {"tab_id":"w1:t6","workspace_id":"w1","label":"fm-stale-child"}
]}}
JSON
cat > "$FIXTURE/agents.json" <<'JSON'
{"result":{"agents":[
  {"tab_id":"w1:t1","workspace_id":"w1","pane_id":"w1:p1","agent_status":"working"},
  {"tab_id":"w1:t2","workspace_id":"w1","pane_id":"w1:p2","agent_status":"done"},
  {"tab_id":"w1:t3","workspace_id":"w1","pane_id":"w1:p9","agent_status":"working"},
  {"tab_id":"w1:t4","workspace_id":"w1","pane_id":"w1:p10","agent_status":"working"},
  {"tab_id":"w1:t5","workspace_id":"w1","pane_id":"w1:p11","agent_status":"working"}
]}}
JSON
cat > "$FIXTURE/issues.json" <<'JSON'
[
  {"id":"b1","title":"Build work","status":"open","assignee":"alice","labels":["agents"]},
  {"id":"b2","title":"Alice Title-Case Label","status":"open","assignee":"Alice","labels":["agents"]},
  {"id":"b3","title":"Platform work","status":"open","assignee":"Platform","labels":["platform"]},
  {"id":"b4","title":"Captain call","status":"open","assignee":"Jubin John","labels":["captain","decision"]},
  {"id":"b5","title":"Done work","status":"in_progress","assignee":"alice","labels":["agents"]}
]
JSON

FAKEBIN=$(fm_fakebin "$TMP_ROOT")
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
printf 'herdr %s\n' "$*" >> "$FIXTURE/calls"
case "$*" in
  'pane current --session default') cat "$FIXTURE/current.json" ;;
  'tab list --workspace w1 --session default') cat "$FIXTURE/tabs.json" ;;
  'agent list --session default') cat "$FIXTURE/agents.json" ;;
  *) exit 4 ;;
esac
SH
cat > "$FAKEBIN/bd" <<'SH'
#!/usr/bin/env bash
printf 'bd %s\n' "$*" >> "$FIXTURE/calls"
case "$*" in
  '--readonly --sandbox --json list --status open --limit 0') [ ! -e "$FIXTURE/bd-fails" ] || exit 3; cat "$FIXTURE/issues.json" ;;
  *) exit 4 ;;
esac
SH
chmod +x "$FAKEBIN/herdr" "$FAKEBIN/bd"
export PATH="$FAKEBIN:$PATH"
# The roster chdirs to BD's board when FM_BOARD is set; without it the script
# inherits the caller's cwd, which points nowhere real. The fixture must give
# bd an explicit board marker so it cannot accidentally hit a real board.
export FM_BOARD="$FIXTURE"

ROSTER="$ROOT/bin/fm-peer-roster.sh"

# 1. Parked worker posture takes precedence over the pane's `working` activity.
"$ROSTER" --json > "$FIXTURE/out"
jq -e '
  ([.agents[] | select(.name == "parked-worker")][0]
    | .kind == "ship" and .posture == "parked" and .activity == "working"
    and .open_keys == [] and (.latest_line | contains("paused"))) and
  ([.agents[] | select(.name == "blocked-worker")][0]
    | .posture == "blocked" and .activity == "working"
    and .open_keys == ["gcloud-auth"]
    and (.latest_line | contains("gcloud-auth") | not))
' "$FIXTURE/out" >/dev/null || fail 'parked and blocked postures not honored over live activity'
pass 'parked and keyed-blocked postures ride over pane activity'

# 2. Stale child, secondmate child rows, exact-label join, and the captain hold
# on the secondmate's own backlog.
jq -e '
  ([.agents[] | select(.name == "stale-child")][0]
    | .kind == "secondmate-child" and .activity == "unknown"
    and .posture == "idle-stale" and .beads_state == "ok"
    and .latest_age_s > 3600) and
  ([.agents[] | select(.name == "child-one")][0]
    | .kind == "secondmate-child" and .activity == "working"
    and .posture == "working" and .beads_state == "ok") and
  ([.agents[] | select(.name == "platform")][0]
    | .kind == "secondmate" and .beads == ["b3"]) and
  ([.agents[] | select(.name == "alice")][0]
    | .kind == "peer" and .posture == "blocked" and .open_keys == ["build"]
    and (.beads | sort) == ["b1","b2","b5"]) and
  ([.agents[] | select(.name == "bob")][0]
    | .posture == "idle-stale" and (.latest_age_s | tostring | startswith("1791")))
' "$FIXTURE/out" >/dev/null || { jq '.agents[] | {name, kind, activity, posture, latest_age_s}' "$FIXTURE/out" >&2; fail 'stale, secondmate-child, or parent rows misclassified'; }
pass 'secondmate home, stale-child, parent, and exact assignee join land'

# 3. On-captain section: captain-label beads plus the home's captain holds.
jq -e '
  .on_captain.beads == [{"id":"b4","title":"Captain call"}] and
  ([.on_captain.holds[] | select(.task == "t1")] | length == 0)
' "$FIXTURE/out" >/dev/null || fail 'captain beads or hold surface missing'
pass 'on_captain surfaces captain-label beads and reports holds (none in this home)'

# 4. No free-text fragment leaks into open_keys or posture.
jq -e '
  ([.agents[] | select(.name == "blockfrag")] | length == 0) and
  ([.agents[] | .open_keys[]?] | map(select(test("^(the|a|for|access|backend|exclusive)$"))) | length == 0)
' "$FIXTURE/out" >/dev/null || fail 'free-text fragment leaked into open_keys'
pass 'no free-text fragments appear as keys'

# 5. An in-progress bead assigned through the title-cased alias joins the row.
jq -e '([.agents[] | select(.name == "alice")][0]
    | .beads | any(. == "b5"))' \
  "$FIXTURE/out" >/dev/null || fail 'title-cased in_progress bead did not join'
pass 'in_progress beads join via deterministic aliases'

# 6. Keyed blocked survives a later done when the resolved line is missing.
printf 'blocked [at=%s] [key=proof]: waiting on proof\ndone [at=%s]: other proof finished\n' "$now" "$now" > "$FM_HOME/state/peers/bob.log"
"$ROSTER" --json > "$FIXTURE/out"
jq -e '([.agents[] | select(.name == "bob")][0]
    | .posture == "blocked" and .open_keys == ["proof"])' \
  "$FIXTURE/out" >/dev/null || fail 'done without resolved closed the request'
pass 'open keyed request survives a later done line'

# 7. A malformed peer registry (row with the wrong column count) keeps the
# agent's identity unknown - it must not fabricate answers about one peer
# being vs another.
mv "$FM_HOME/state/peers/peers.tsv" "$FIXTURE/peers.tsv"
printf 'alice-without-label\n' > "$FM_HOME/state/peers/peers.tsv"
if "$ROSTER" --json > "$FIXTURE/out"; then fail 'partial read exited successfully'; fi
jq -e '.partial == true and .sources.peers == "unknown" and
       (.errors | length) > 0' "$FIXTURE/out" >/dev/null || fail 'malformed registry did not stay partial'
rm "$FM_HOME/state/peers/peers.tsv"
mv "$FIXTURE/peers.tsv" "$FM_HOME/state/peers/peers.tsv"
pass 'malformed registry stays partial'

# 8. A bd failure says so and surfaces partial. Posture stays whatever status
# files already tell it; it never secretly becomes idle.
MV_TS="$FM_HOME/state/peers/alice.log"
printf 'note [at=%s]: fresh without keys\n' "$now" > "$MV_TS"
touch "$FIXTURE/bd-fails"
if "$ROSTER" --json > "$FIXTURE/out"; then fail 'failing bd exited successfully'; fi
jq -e '.partial == true and .sources.beads == "unknown" and
        ([.agents[] | select(.beads_state == "unknown")] | length) > 0' \
  "$FIXTURE/out" >/dev/null || fail 'bd failure not surfaced as partial unknown'
rm "$FIXTURE/bd-fails"
pass 'bd failure surfaces partial, bead_state unknown, not a fake idle'
