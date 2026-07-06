#!/usr/bin/env bash
# Behavior tests for `fm-spawn.sh --reuse-worktree <id>` - the agent-swap half of
# the context-handoff feature. It relaunches a FRESH agent on the EXISTING
# worktree/branch recorded in state/<id>.meta, seeded with data/<id>/handoff.md,
# WITHOUT running treehouse get and WITHOUT destroying the worktree.
#
# The happy path runs the real fm-spawn.sh over a throwaway home with a stubbed
# tmux (records what would be sent to the pane) and a `treehouse` stub that screams
# if ever called, so the "never runs treehouse get" guarantee is proven, not
# assumed. No real tmux/treehouse/harness is launched.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP=$(fm_test_tmproot fm-spawn-reuse)
fm_git_identity fmtest fmtest@example.invalid

HOME_DIR="$TMP/home"
STATE="$HOME_DIR/state"
DATA="$HOME_DIR/data"
PROJ="$TMP/proj"
WT="$TMP/wt"
ID=reuse-demo-k9
mkdir -p "$TMP" "$STATE" "$DATA"
# WT is a real LINKED worktree of PROJ on the task branch, exactly like a live
# crewmate worktree: fm-spawn's exclude_path relies on git returning an absolute
# git-path, which only holds for a linked worktree (not a standalone repo).
fm_git_init_commit "$PROJ"
git -C "$PROJ" worktree add --quiet -b "fm/$ID" "$WT"

# Fresh, valid meta + brief + handoff for the happy-path and most error cases.
write_meta() {  # [worktree-override] [kind-override]
  local wt=${1:-$WT} kind=${2:-ship}
  fm_write_meta "$STATE/$ID.meta" \
    "window=firstmate:fm-$ID" \
    "worktree=$wt" \
    "project=$PROJ" \
    "harness=claude" \
    "kind=$kind" \
    "mode=no-mistakes" \
    "yolo=off" \
    "tasktmp=/tmp/fm-$ID" \
    "model=default" \
    "effort=default"
}
mkdir -p "$DATA/$ID"
printf '# Original brief\nShip the feature.\n' > "$DATA/$ID/brief.md"

run_reuse() {  # <extra-args...> -> sets OUT/RC; runs with the temp home + PATH stubs
  OUT=$(cd "$ROOT" && FM_SPAWN_NO_GUARD=1 \
    FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" FM_PROJECTS_OVERRIDE="$PROJ" \
    PATH="$STUBBIN:$PATH" \
    "$SPAWN" "$ID" --reuse-worktree "$@" 2>&1); RC=$?
  return 0
}

# --- PATH stubs: a screaming treehouse + a scriptable tmux -------------------
STUBBIN="$TMP/stubbin"
mkdir -p "$STUBBIN"
cat > "$STUBBIN/treehouse" <<'SH'
#!/usr/bin/env bash
echo "TREEHOUSE-CALLED: $*" >> "$STUB_TREEHOUSE_LOG"
exit 0
SH
cat > "$STUBBIN/tmux" <<'SH'
#!/usr/bin/env bash
case "$1" in
  has-session) exit 1 ;;
  new-session) exit 0 ;;
  list-windows) exit 0 ;;
  new-window) echo "new-window $*" >> "$STUB_TMUX_LOG"; exit 0 ;;
  send-keys) echo "send-keys $*" >> "$STUB_SEND_LOG"; exit 0 ;;
  display-message) echo "firstmate" ;;
  *) : ;;
esac
exit 0
SH
chmod +x "$STUBBIN/treehouse" "$STUBBIN/tmux"
export STUB_TMUX_LOG="$TMP/tmux.log" STUB_SEND_LOG="$TMP/send.log" STUB_TREEHOUSE_LOG="$TMP/treehouse.log"
export TMUX=  # force the dedicated-session container path in the stub
unset TMUX

# ============================ error paths ===================================

# no meta
rm -f "$STATE/$ID.meta"
run_reuse
expect_code 1 "$RC" "missing meta aborts"
assert_contains "$OUT" "no meta for $ID" "missing-meta error names the id"
pass "error: missing meta"

# recorded worktree gone
write_meta "$TMP/gone-wt"
printf 'dump\n' > "$DATA/$ID/handoff.md"
run_reuse
expect_code 1 "$RC" "vanished worktree aborts"
assert_contains "$OUT" "worktree is gone" "vanished-worktree error is explicit"
pass "error: recorded worktree gone"

# no handoff dump
write_meta
rm -f "$DATA/$ID/handoff.md"
run_reuse
expect_code 1 "$RC" "missing handoff dump aborts"
assert_contains "$OUT" "no handoff dump" "missing-handoff error is explicit"
pass "error: missing handoff dump"

# empty handoff dump
: > "$DATA/$ID/handoff.md"
run_reuse
expect_code 1 "$RC" "empty handoff dump aborts"
assert_contains "$OUT" "handoff dump is empty" "empty-handoff error is explicit"
pass "error: empty handoff dump"

# extra positional
printf 'dump\n' > "$DATA/$ID/handoff.md"
run_reuse projects/proj
expect_code 1 "$RC" "extra positional aborts"
assert_contains "$OUT" "takes only <id>" "extra-positional error is explicit"
pass "error: extra positional rejected"

# secondmate meta
write_meta "$WT" secondmate
run_reuse
expect_code 1 "$RC" "secondmate task rejected"
assert_contains "$OUT" "is a secondmate" "secondmate reuse is refused"
pass "error: secondmate meta rejected"

# --secondmate combined with --reuse-worktree
write_meta
run_reuse_secondmate() {
  OUT=$(cd "$ROOT" && FM_SPAWN_NO_GUARD=1 \
    FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" FM_PROJECTS_OVERRIDE="$PROJ" \
    PATH="$STUBBIN:$PATH" \
    "$SPAWN" "$ID" --reuse-worktree --secondmate 2>&1); RC=$?
}
run_reuse_secondmate
expect_code 1 "$RC" "--reuse-worktree + --secondmate rejected"
assert_contains "$OUT" "cannot be combined with --secondmate" "combo refused"
pass "error: --reuse-worktree + --secondmate refused"

# ============================ happy path ====================================
write_meta
printf 'HANDOFF: decisions D, files F, remaining R\n' > "$DATA/$ID/handoff.md"
# seed stale signals so we can prove they are reset for the fresh agent
printf '999999\n' > "$STATE/$ID.context"
touch "$STATE/$ID.turn-ended"
: > "$STUB_TMUX_LOG"; : > "$STUB_SEND_LOG"; rm -f "$STUB_TREEHOUSE_LOG"
rm -f "$WT/.claude/settings.local.json" "$STATE/$ID.reuse-brief.md"

run_reuse
expect_code 0 "$RC" "happy-path reuse succeeds"
assert_contains "$OUT" "spawned $ID" "prints the spawned line"

# treehouse get is NEVER used
assert_absent "$STUB_TREEHOUSE_LOG" "treehouse binary is never invoked on reuse"
assert_no_grep "treehouse get" "$STUB_SEND_LOG" "'treehouse get' is never sent to the pane"

# the new pane opens directly in the existing worktree (no treehouse get to move it)
assert_grep "$WT" "$STUB_TMUX_LOG" "new-window opens in the existing worktree"

# the launch is seeded with the composed reuse-brief, not the bare original
assert_grep "$ID.reuse-brief.md" "$STUB_SEND_LOG" "launch reads the composed reuse-brief"
assert_present "$STATE/$ID.reuse-brief.md" "composed reuse-brief is written"
assert_grep "Original brief" "$STATE/$ID.reuse-brief.md" "reuse-brief carries the original brief"
assert_grep "resume from here" "$STATE/$ID.reuse-brief.md" "reuse-brief has the resume preamble"
assert_grep "HANDOFF: decisions D" "$STATE/$ID.reuse-brief.md" "reuse-brief carries the handoff dump"

# stale context + turn-ended are reset for the fresh agent
assert_absent "$STATE/$ID.context" "previous context signal is cleared"
assert_absent "$STATE/$ID.turn-ended" "previous turn-end marker is cleared"

# meta keeps worktree/project/kind/mode/yolo; window is rewritten
assert_grep "worktree=$WT" "$STATE/$ID.meta" "meta keeps the worktree"
assert_grep "project=$PROJ" "$STATE/$ID.meta" "meta keeps the project"
assert_grep "kind=ship" "$STATE/$ID.meta" "meta keeps the kind"
assert_grep "mode=no-mistakes" "$STATE/$ID.meta" "meta keeps the delivery mode"
assert_grep "yolo=off" "$STATE/$ID.meta" "meta keeps the yolo posture"

# the claude Stop hook is wired to fm-ctx-hook.sh (turn-end + context recording)
assert_present "$WT/.claude/settings.local.json" "claude Stop hook is re-installed"
assert_grep "fm-ctx-hook.sh" "$WT/.claude/settings.local.json" "Stop hook runs fm-ctx-hook.sh"
assert_grep "$ID.context" "$WT/.claude/settings.local.json" "Stop hook records to state/<id>.context"
pass "happy path: fresh agent on same worktree, no treehouse get, brief+context wired"

pass "fm-spawn --reuse-worktree: all cases"
