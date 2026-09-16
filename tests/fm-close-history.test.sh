#!/usr/bin/env bash
# Deterministic close/history lifecycle tests: review, refusal, archival,
# backend removal, lookup/search, callsign cooldown, batching, and cleanup reuse.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CLOSE="$ROOT/bin/fm-close.sh"
HISTORY="$ROOT/bin/fm-history.sh"
TASKS="$ROOT/bin/fm-tasks.sh"
AXI="$ROOT/bin/fm-tasks-axi.sh"
TMP_ROOT=$(fm_test_tmproot fm-close-history)
command -v tasks-axi >/dev/null 2>&1 || { printf 'ok - skipped: tasks-axi is required\n'; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  cat > "$home/.tasks.toml" <<'EOF'
backend = "markdown"

[markdown]
path = "data/backlog.md"
archive = "data/done-archive.md"
done_keep = 50
EOF
  printf '%s\n' "$home"
}

add_done() {  # <home> <id> <title>
  FM_HOME="$1" "$AXI" add "$2" "$3" --kind ship --repo sample >/dev/null \
    || fail "could not add $2"
  FM_HOME="$1" "$AXI" "done" "$2" --note "local main" >/dev/null \
    || fail "could not complete $2"
}

accept_for_close() {  # <home> <id>
  FM_HOME="$1" FM_ROOT_OVERRIDE="$ROOT" FM_TASK_LIFECYCLE_NOW=2026-09-16T10:00:00Z \
    "$ROOT/bin/fm-task-lifecycle.sh" review-start "$2" >/dev/null || fail "could not start review for $2"
  FM_HOME="$1" FM_ROOT_OVERRIDE="$ROOT" FM_TASK_LIFECYCLE_NOW=2026-09-16T10:01:00Z \
    "$ROOT/bin/fm-task-lifecycle.sh" accept "$2" --actor test-reviewer --evidence "review passed" --route close >/dev/null \
    || fail "could not accept $2"
}

row_exists() { FM_HOME="$1" "$AXI" show "$2" >/dev/null 2>&1; }

# Review mode renders the exact proposal, including its temporary callsign
# preview, without persisting that callsign, writing an archive, or changing the backlog.
home=$(make_home review)
add_done "$home" review-task "Review closure behavior"
mkdir -p "$home/data/review-task"
printf 'implementation instructions\n' > "$home/data/review-task/brief.md"
before=$(cksum "$home/data/backlog.md")
out=$(FM_HOME="$home" "$CLOSE" --review review-closure-behavior) || fail "review-only close by generated name failed: $out"
assert_contains "$out" "Proposed closure: review-closure-behavior (review-task, t1)" \
  "review did not print the proposed canonical disposition"
assert_contains "$out" "Lifecycle blocker:" "review did not identify missing acceptance"
assert_contains "$out" "Review only: nothing changed." "review did not identify its read-only result"
[ "$before" = "$(cksum "$home/data/backlog.md")" ] || fail "review mutated the backlog"
assert_absent "$home/state/task-callsigns.tsv" "review allocated a private short reference"
assert_absent "$home/data/closed-tasks" "review created a closed-task archive"
row_exists "$home" review-task || fail "review removed the current task"
pass "close --review is a non-mutating closure proposal"

# Normal close archives useful task material, explicit acceptance, and the compact
# structured record, removes only the selected Done row, and makes it searchable.
accept_for_close "$home" review-task
out=$(FM_HOME="$home" "$CLOSE" review-task) || fail "normal close failed: $out"
closure="$home/data/closed-tasks/review-task/closure.json"
[ -f "$closure" ] || fail "normal close did not publish a closure record"
[ -f "$home/data/closed-tasks/review-task/brief.md" ] || fail "task instructions were not retained"
[ -f "$home/data/closed-tasks/review-task/task.txt" ] || fail "backlog notes were not retained"
[ -f "$home/data/closed-tasks/review-task/notes.md" ] || fail "task body was not retained"
if row_exists "$home" review-task; then fail "closed task remained in the current backlog"; fi
json=$(FM_HOME="$home" "$HISTORY" --json review-task) || fail "canonical history lookup failed"
printf '%s\n' "$json" | jq -e '
  length == 1
  and .[0].id == "review-task"
  and .[0].name == "review-closure-behavior"
  and .[0].project == "sample"
  and .[0].kind == "ship"
  and .[0].version == 2
  and .[0].disposition == "closed"
  and .[0].result == "Delivered to local main"
  and .[0].lifecycle.acceptance.actor == "test-reviewer"
  and .[0].lifecycle.acceptance.route == "close"
  and (. [0].dates.completed != null)
  and (. [0].dates.closed != null)
  and (. [0].retainedKnowledge | index("data/closed-tasks/review-task/brief.md") != null)
' >/dev/null || fail "closure record omitted required history fields: $json"
by_name=$(FM_HOME="$home" "$HISTORY" --json review-closure-behavior) || fail "name history lookup failed"
[ "$(printf '%s\n' "$by_name" | jq -r '.[0].id')" = review-task ] || fail "history name resolved incorrectly"
searched=$(FM_HOME="$home" "$HISTORY" --json --search "LOCAL MAIN") || fail "history search failed"
[ "$(printf '%s\n' "$searched" | jq 'length')" -eq 1 ] || fail "history search did not find the result"
mkdir -p "$home/data/closed-tasks/prepared-task"
jq '.id="prepared-task" | .name="prepared-task-name" | .disposition="prepared"' "$closure" \
  > "$home/data/closed-tasks/prepared-task/closure.json"
visible=$(FM_HOME="$home" "$HISTORY" --json) || fail "history rejected a valid prepared recovery record"
[ "$(printf '%s\n' "$visible" | jq 'length')" -eq 1 ] || fail "history exposed a prepared closure"
if FM_HOME="$home" "$HISTORY" --json prepared-task >/dev/null 2>&1; then fail "prepared closure was searchable"; fi
current=$(FM_HOME="$home" "$TASKS" --json) || fail "current task table failed after close"
[ "$(printf '%s\n' "$current" | jq 'length')" -eq 0 ] || fail "closed work remained in /tasks"
pass "normal close durably archives material, removes current work, and feeds searchable history"

# Canonical retry is idempotent and preserves the original closure timestamp.
closed_at=$(jq -r '.dates.closed' "$closure")
out=$(FM_HOME="$home" "$CLOSE" review-task) || fail "idempotent close retry failed: $out"
assert_contains "$out" "already closed: review-task" "idempotent retry did not report the disposition"
[ "$closed_at" = "$(jq -r '.dates.closed' "$closure")" ] || fail "idempotent retry changed the close date"
pass "close retry by canonical id is idempotent"

# Non-Done work and orphaned live resources refuse before an archive or backlog
# mutation. The resource case proves close never substitutes direct deletion for
# the existing guarded cleanup path.
refusal=$(make_home refusal)
FM_HOME="$refusal" "$AXI" add queued-task "Queued task" --kind ship --repo sample >/dev/null
if FM_HOME="$refusal" "$CLOSE" queued-task >"$refusal/queued.out" 2>&1; then fail "queued task closed"; fi
assert_grep "is not Done" "$refusal/queued.out" "queued refusal did not name the terminal-state requirement"
add_done "$refusal" resource-task "Resource cleanup task"
accept_for_close "$refusal" resource-task
printf '#!/usr/bin/env bash\n' > "$refusal/state/resource-task.check.sh"
chmod 0700 "$refusal/state/resource-task.check.sh"
if FM_HOME="$refusal" "$CLOSE" resource-task >"$refusal/resource.out" 2>&1; then fail "task with an orphaned resource closed"; fi
assert_grep "reconcile guarded cleanup" "$refusal/resource.out" "resource refusal did not route through guarded cleanup"
[ -f "$refusal/state/resource-task.check.sh" ] || fail "close directly deleted a remaining resource"
assert_absent "$refusal/data/closed-tasks/resource-task" "a refused close published history"
row_exists "$refusal" resource-task || fail "a refused close removed its backlog row"
manual=$(make_home manual-owner)
add_done "$manual" manual-task "Manual owner task"
printf 'manual\n' > "$manual/config/backlog-backend"
if FM_HOME="$manual" "$CLOSE" manual-task >"$manual/manual.out" 2>&1; then fail "manual-backend task closed automatically"; fi
assert_grep "automatic closure is unavailable" "$manual/manual.out" "manual-backend refusal did not name the missing mutation owner"
row_exists "$manual" manual-task || fail "manual-backend refusal removed its backlog row"
assert_absent "$manual/data/closed-tasks" "manual-backend refusal prepared an archive"
pass "close refuses nonterminal, unsafe-cleanup, and ownerless mutation cases"

# A mixed batch independently lands successes while preserving failed rows.
batch=$(make_home batch)
add_done "$batch" batch-good "Batch good task"
accept_for_close "$batch" batch-good
FM_HOME="$batch" "$AXI" add batch-wait "Batch waiting task" --kind ship --repo sample >/dev/null
if FM_HOME="$batch" "$CLOSE" batch-good batch-wait >"$batch/batch.out" 2>&1; then fail "partial batch reported complete success"; fi
[ -f "$batch/data/closed-tasks/batch-good/closure.json" ] || fail "successful batch member was rolled back"
if row_exists "$batch" batch-good; then fail "successful batch member remained current"; fi
row_exists "$batch" batch-wait || fail "failed batch member was removed"
assert_absent "$batch/data/closed-tasks/batch-wait" "failed batch member was archived"
pass "bounded batch closure isolates success from failure"

# Closing retires the short reference. A newly added task skips that reference
# during cooldown, while a deterministic zero-cooldown sync proves later reuse.
calls=$(make_home callsigns)
add_done "$calls" old-task "Old callsign task"
accept_for_close "$calls" old-task
first=$(FM_HOME="$calls" "$TASKS" --json) || fail "could not allocate the initial reference"
[ "$(printf '%s\n' "$first" | jq -r '.[0].ref')" = t1 ] || fail "initial task did not receive t1"
FM_HOME="$calls" "$CLOSE" t1 >/dev/null || fail "close did not accept an active temporary reference"
FM_HOME="$calls" "$AXI" add cooling-task "Cooling callsign task" --kind ship --repo sample >/dev/null
cooling=$(FM_HOME="$calls" "$TASKS" --json) || fail "could not allocate around the cooling tombstone"
[ "$(printf '%s\n' "$cooling" | jq -r '.[0].ref')" = t2 ] || fail "t1 was immediately reused during cooldown"
FM_HOME="$calls" "$AXI" add reusable-task "Reusable callsign task" --kind ship --repo sample >/dev/null
reused=$(FM_CALLSIGN_REUSE_COOLDOWN_SECS=0 FM_HOME="$calls" "$TASKS" --json) || fail "post-cooldown allocation failed"
[ "$(printf '%s\n' "$reused" | jq -r '.[] | select(.id == "reusable-task") | .ref')" = t1 ] \
  || fail "the oldest retired reference was not reused after cooldown"
if FM_HOME="$calls" "$HISTORY" --json t1 >/dev/null 2>&1; then fail "history accepted a retired temporary reference"; fi
pass "closure enforces callsign cooldown and history uses stable identities"

# Existing dependent work is linked into history and detached through tasks-axi
# before source removal, so the archival disposition does not strand relations.
links=$(make_home followups)
add_done "$links" source-task "Source task"
accept_for_close "$links" source-task
FM_HOME="$links" "$AXI" add follow-task "Authorized follow task" --kind ship --repo sample --blocked-by source-task >/dev/null
FM_HOME="$links" "$CLOSE" source-task >/dev/null || fail "close with existing follow-up failed"
[ "$(FM_HOME="$links" "$AXI" show follow-task --full | sed -n 's/^  deps: *//p')" = none ] \
  || fail "configured backlog owner retained a relation to the removed source"
follow_json=$(FM_HOME="$links" "$HISTORY" --json source-task)
printf '%s\n' "$follow_json" | jq -e '.[0].followUps == ["follow-task"]' >/dev/null \
  || fail "closure did not preserve its follow-up link"
pass "closure composes backlog relationships into durable follow-up links"

# A terminal task record still present is cleaned through fm-teardown.sh. The
# fake backend records that guarded endpoint cleanup ran; close itself never
# deletes the record or resource directly.
cleanup=$(make_home cleanup)
fakebin="$cleanup/fakebin"
mkdir -p "$fakebin" "$cleanup/data/cleanup-task"
add_done "$cleanup" cleanup-task "Cleanup composition task"
accept_for_close "$cleanup" cleanup-task
cat > "$cleanup/state/cleanup-task.meta" <<EOF
window=firstmate:fm-cleanup-task
endpoint_task_id=cleanup-task
worktree=$cleanup/absent-worktree
project=$cleanup/absent-project
harness=claude
kind=ship
mode=local-only
yolo=off
spawn_gen=spawn-cleanup
started_at=2026-09-15T10:11:12Z
backend=tmux
EOF
printf 'done: ready in branch fm/cleanup-task\n' > "$cleanup/state/cleanup-task.status"
cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_FAKE_TMUX_LOG:?}"
case "${1:-}" in
  display-message) printf '%%1\n' ;;
  capture-pane) printf 'all quiet\n> \n' ;;
  list-windows) : ;;
esac
exit 0
SH
cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in daemon) printf 'daemon running (pid 4242)\n' ;; esac
exit 0
SH
for tool in treehouse gh gh-axi lsof; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/$tool"
done
chmod +x "$fakebin"/*
log="$cleanup/tmux.log"
review_cleanup=$(FM_HOME="$cleanup" "$CLOSE" --review cleanup-task) \
  || fail "review rejected a task whose normal close can run guarded cleanup"
assert_contains "$review_cleanup" "Cleanup: guarded cleanup is still required before archival." \
  "review did not propose the existing cleanup path"
[ -f "$cleanup/state/cleanup-task.meta" ] || fail "review mutated the live task record"
assert_absent "$log" "review invoked endpoint cleanup"
FM_TEARDOWN_GUARD_DONE=1 FM_FAKE_TMUX_LOG="$log" PATH="$fakebin:$PATH" \
  FM_HOME="$cleanup" "$CLOSE" cleanup-task >/dev/null || fail "close did not compose guarded cleanup"
assert_absent "$cleanup/state/cleanup-task.meta" "guarded cleanup left the task record"
assert_grep "kill-window" "$log" "close did not delegate endpoint retirement to teardown"
cleanup_closure="$cleanup/data/closed-tasks/cleanup-task/closure.json"
[ -f "$cleanup_closure" ] || fail "cleanup-composed close did not archive"
[ "$(jq -r '.dates.started' "$cleanup_closure")" = "2026-09-15T10:11:12Z" ] \
  || fail "closure did not retain the authoritative task start date"
pass "close composes the existing guarded cleanup path"
