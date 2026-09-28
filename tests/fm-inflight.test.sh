#!/usr/bin/env bash
# Behavior tests for the turn-time in-flight view and the notable-item helper.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INFLIGHT="$ROOT/bin/fm-inflight.sh"
NOTE="$ROOT/bin/fm-note.sh"
BRIEF="$ROOT/bin/fm-brief.sh"
TMP_ROOT=$(fm_test_tmproot fm-inflight)

export PARLAY_AGENT_HOME="$TMP_ROOT/.parlay-absent"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

OPEN_JSON='[{"id":"task-1","title":"Fleet work one","status":"open"},{"id":"task-2","title":"Fleet work two","status":"in_progress"},{"id":"task-3","title":"Fleet work three","status":"blocked"},{"id":"task-4","title":"Fleet work four","status":"open"},{"id":"task-5","title":"Fleet work five","status":"open"},{"id":"task-6","title":"Fleet work six","status":"open"},{"id":"task-7","title":"Fleet work seven","status":"open"},{"id":"task-8","title":"Fleet work eight","status":"open"},{"id":"task-9","title":"Fleet work nine","status":"open"}]'
CLOSED_JSON='[{"id":"task-old","title":"Older landing","status":"closed","closed_at":"2026-09-20T10:00:00Z"},{"id":"task-new","title":"Newer landing","status":"closed","closed_at":"2026-09-27T10:00:00Z"}]'
GATES_JSON='[{"id":"task-g1","title":"Gate: human","description":"Ad-hoc gate blocking task-1","status":"open","issue_type":"gate","await_type":"human"}]'

make_store_fakebin() {  # <dir> [missing-store]
  local fb missing=${2:-}
  fb=$(fm_fakebin "$1")
  for store in task review robots projects workflows inbox; do
    [ "$store" = "$missing" ] && continue
    cat > "$fb/$store" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = "gate" ]; then
  printf '%s\n' '$GATES_JSON'
  exit 0
fi
case " \$* " in
  *" closed "*) printf '%s\n' '$CLOSED_JSON' ;;
  *) printf '%s\n' '$OPEN_JSON' ;;
esac
exit 0
SH
  done
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fb/parlay" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows) printf 'ship-task: ignored\n' ;;
  display-message) printf '%%1\n' ;;
  capture-pane) printf 'work in progress\nesc to interrupt\n' ;;
esac
exit 0
SH
  chmod +x "$fb"/*
  printf '%s\n' "$fb"
}

make_home() {  # <name>
  local home=$TMP_ROOT/$1 gen
  mkdir -p "$home/state" "$home/data" "$home/projects" "$home/config"
  fm_write_meta "$home/state/ship-task.meta" \
    "window=firstmate:fm-ship-task" \
    "worktree=$home/projects/alpha-worktree" \
    "project=alpha" \
    "harness=claude" \
    "kind=ship" \
    "mode=direct-PR" \
    "yolo=off"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$home/state" ship-task)
  "$ROOT/bin/fm-busy-event.sh" apply "$home/state" ship-task busy --gen "$gen" \
    --source claude-hook --event user-prompt-submit
  printf '%s\n' "$home"
}

# 1. Full render: all four sections from durable records.
HOME1=$(make_home home1)
FB1=$(make_store_fakebin "$TMP_ROOT/fb1")
OUT=$(FM_HOME="$HOME1" PATH="$FB1:$PATH" "$INFLIGHT" --since 2026-09-01T00:00:00Z) || fail "inflight exited nonzero"
assert_contains "$OUT" "## Live workers" "live section"
assert_contains "$OUT" "## Open beads" "open section"
assert_contains "$OUT" "## Recently landed" "landed section"
assert_contains "$OUT" "## Awaiting you" "awaiting section"
assert_contains "$OUT" "ship-task" "live worker id"
assert_contains "$OUT" "alpha" "live worker project"
assert_contains "$OUT" "task-1 [open] Fleet work one" "open bead row"
assert_contains "$OUT" "task-new Newer landing" "landed row"
assert_contains "$OUT" "task-g1 Ad-hoc gate blocking task-1" "held gate row"

# 2. Bounded with disclosed remainder: 9 open rows at limit 8.
assert_contains "$OUT" "(+1 more - run task list for the rest)" "open overflow disclosure"

# 3. Landed newest-first: task-new must precede task-old.
new_line=$(printf '%s' "$OUT" | grep -n "task-new Newer landing" | head -1 | cut -d: -f1)
old_line=$(printf '%s' "$OUT" | grep -n "task-old Older landing" | head -1 | cut -d: -f1)
[ -n "$new_line" ] && [ -n "$old_line" ] && [ "$new_line" -lt "$old_line" ] \
  || fail "landed rows not newest-first (new=$new_line old=$old_line)"

# 4. A missing store is disclosed, never silently omitted.
FB2=$(make_store_fakebin "$TMP_ROOT/fb2" inbox)
PATH_NO_INBOX="$FB2"
OLDIFS=$IFS; IFS=:
for d in $PATH; do
  [ -x "$d/inbox" ] && continue
  PATH_NO_INBOX="$PATH_NO_INBOX:$d"
done
IFS=$OLDIFS
OUT2=$(FM_HOME="$HOME1" PATH="$PATH_NO_INBOX" "$INFLIGHT" --since 2026-09-01T00:00:00Z 2>&1) || fail "inflight exited nonzero without inbox"
assert_contains "$OUT2" "unavailable: inbox CLI not installed" "missing store disclosure"

# 5. fm-note files with the fleet label and prints the id.
FB3=$(fm_fakebin "$TMP_ROOT/fb3")
cat > "$FB3/task" <<SH
#!/usr/bin/env bash
printf 'ARGS:%s\n' "\$*" >> "$TMP_ROOT/note-args"
printf 'task-zz9\n'
SH
chmod +x "$FB3/task"
NOTE_OUT=$(PATH="$FB3:$PATH" "$NOTE" task "A notable feature") || fail "fm-note exited nonzero"
assert_contains "$NOTE_OUT" "task-zz9" "note prints bead id"
NOTE_ARGS=$(cat "$TMP_ROOT/note-args")
assert_contains "$NOTE_ARGS" "fleet:firstmate" "note carries the fleet label"
assert_contains "$NOTE_ARGS" "A notable feature" "note carries the title"

# 6. fm-note usage failures.
PATH="$FB3:$PATH" "$NOTE" task >/dev/null 2>&1
expect_code 2 "$?" "fm-note without title"
PATH="$FB3:$PATH" "$NOTE" nosuchstore "Title" >/dev/null 2>&1
expect_code 2 "$?" "fm-note with unknown store"
"$NOTE" --help >/dev/null 2>&1
expect_code 0 "$?" "fm-note --help"

# 7. Ship and scout scaffolds carry the notable-item rule (behavior through
# the scaffolding executable, not source-byte matching).
SHOME=$TMP_ROOT/briefhome
mkdir -p "$SHOME/data" "$SHOME/state" "$SHOME/config" "$SHOME/projects"
FM_HOME="$SHOME" "$BRIEF" rule-ship /tmp --mode direct-PR >/dev/null 2>&1 \
  || fail "ship scaffold failed"
SHIP_BRIEF=$(cat "$SHOME/data/rule-ship/brief.md")
assert_contains "$SHIP_BRIEF" "# Notable-item beads" "ship brief rule section"
assert_contains "$SHIP_BRIEF" "fm-note.sh" "ship brief points at the helper"
FM_HOME="$SHOME" "$BRIEF" rule-scout /tmp --scout >/dev/null 2>&1 \
  || fail "scout scaffold failed"
SCOUT_BRIEF=$(cat "$SHOME/data/rule-scout/brief.md")
assert_contains "$SCOUT_BRIEF" "# Notable-item beads" "scout brief rule section"

pass "fm-inflight"
