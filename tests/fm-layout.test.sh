#!/usr/bin/env bash
# fm-layout.sh — orchestrator dashboard layout behavior.
#
# Covers, against a REAL tmux on a private socket (never the captain's session):
#   1. Worker discovery from state/*.meta: live windows only, secondmates and
#      windowless/stale metas excluded; repo from project=, label from the id.
#   2. fm_layout_label: random-suffix strip and FM_LAYOUT_LABEL_MAX truncation.
#   3. assign/slots round-trip, rejection of a non-worker, and slot clearing.
#   4. arrange geometry: orchestrator preserved + active, one summary pane, three
#      slot panes, @fm_layout marker, slots autofilled without spawning work.
#   5. Re-running arrange is idempotent (still 5 panes) and never kills workers.
#   6. arrange refuses a worker window and a window with unexpected panes (no
#      --force), leaving everything intact.
#   7. The summary pane renders terse bullets; a watch pane mirrors its worker.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v tmux >/dev/null 2>&1 || { echo "1..0 # SKIP tmux not available"; exit 0; }
REAL_TMUX=$(command -v tmux)
LAYOUT="$ROOT/bin/fm-layout.sh"
PANE="$ROOT/bin/fm-watch-pane.sh"

TMP=$(fm_test_tmproot fm-layout)
SOCK="fmlayout-test-$$"
STATE="$TMP/state"
mkdir -p "$STATE" "$TMP/shim"

TM() { "$REAL_TMUX" -L "$SOCK" "$@"; }

# tmux shim so fm-layout's internal `tmux` calls hit our private socket.
cat > "$TMP/shim/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCK" "\$@"
SH
chmod +x "$TMP/shim/tmux"

# Self-contained cleanup that always returns 0: fm_test_tmproot registered its dir
# inside a $(...) subshell, so the parent's cleanup array is empty here. Returning
# non-zero from an EXIT trap that runs as the script falls off the end would become
# the script's exit status, so end on a zero-status command.
cleanup_layout() {
  TM kill-server 2>/dev/null || true
  rm -rf "$TMP"
  return 0
}
trap cleanup_layout EXIT

export PATH="$TMP/shim:$PATH"
export FM_STATE_OVERRIDE="$STATE" FM_HOME="$TMP" FM_LAYOUT_ALLOW_NO_TMUX=1

meta() {  # <id> <window> <project> <kind>
  cat > "$STATE/$1.meta" <<EOF
window=$2
project=$3
kind=$4
EOF
}

# --- fleet: orchestrator window + worker windows --------------------------
TM new-session -d -s itest -n opencode -x 200 -y 60
TM new-window -t itest -n fm-alpha-aa  'while :; do echo alpha-line; sleep 1; done'
TM new-window -t itest -n fm-beta-bb   'while :; do echo beta-line; sleep 1; done'
TM new-window -t itest -n fm-gamma-cc  'while :; do echo gamma-line; sleep 1; done'
TM new-window -t itest -n fm-second-dd 'while :; do echo second-line; sleep 1; done'

meta alpha-aa  itest:fm-alpha-aa  /x/projects/scrub-cx-engine ship
meta beta-bb   itest:fm-beta-bb   /x/projects/portals-cx      scout
meta gamma-cc  itest:fm-gamma-cc  /x/projects/synct_utility   ship
meta second-dd itest:fm-second-dd /x/projects/secret          secondmate
# Stale meta: its window does not exist on the socket.
meta stale-zz  itest:fm-stale-zz  /x/projects/gone            ship

ORCH_WIN=$(TM list-windows -t itest -F '#{window_id} #{window_name}' | awk '$2=="opencode"{print $1}')
ALPHA_WIN=$(TM list-windows -t itest -F '#{window_id} #{window_name}' | awk '$2=="fm-alpha-aa"{print $1}')

# --- 1. discovery ----------------------------------------------------------
workers=$("$LAYOUT" workers)
assert_contains "$workers" "scrub-cx-engine	alpha" "alpha worker discovered with repo+label"
assert_contains "$workers" "portals-cx	beta" "beta worker discovered"
assert_contains "$workers" "synct_utility	gamma" "gamma worker discovered"
assert_not_contains "$workers" "secret" "secondmate excluded from workers"
assert_not_contains "$workers" "gone" "stale (windowless) meta excluded from workers"
[ "$(printf '%s\n' "$workers" | grep -c .)" -eq 3 ] || fail "expected exactly 3 live workers"
pass "discovery lists only live, non-secondmate workers with repo+label"

# --- 2. label humanization -------------------------------------------------
. "$ROOT/bin/fm-layout-lib.sh"
[ "$(fm_layout_label scrub-pajamas-refactor-y8)" = "scrub pajamas refactor" ] \
  || fail "label should strip suffix and space words"
[ "$(FM_LAYOUT_LABEL_MAX=10 fm_layout_label very-long-feature-name-q9)" = "very long…" ] \
  || fail "label should truncate to FM_LAYOUT_LABEL_MAX with an ellipsis"
pass "label strips the random suffix and truncates to fit"

# --- 3. assign / slots / reject / clear ------------------------------------
"$LAYOUT" assign 1 itest:fm-gamma-cc >/dev/null
"$LAYOUT" assign 2 itest:fm-alpha-aa >/dev/null
slots=$("$LAYOUT" slots)
assert_contains "$slots" "itest:fm-gamma-cc" "slot 1 holds the assigned worker"
assert_contains "$slots" "itest:fm-alpha-aa" "slot 2 holds the assigned worker"

set +e
out=$("$LAYOUT" assign 3 itest:fm-nope-xx 2>&1); rc=$?
set -e
expect_code 1 "$rc" "assigning a non-worker fails"
assert_contains "$out" "not a live worker" "reject explains the worker is not live"

"$LAYOUT" assign 2 - >/dev/null
slots=$("$LAYOUT" slots)
assert_not_contains "$slots" "itest:fm-alpha-aa" "clearing a slot removes its worker"
pass "assign/slots round-trip, non-worker rejection, and clear all work"

# Reset slot files so arrange's autofill starts clean.
rm -f "$STATE"/.layout-slot-*

# --- 4. arrange geometry ---------------------------------------------------
"$LAYOUT" arrange --window "$ORCH_WIN" >/dev/null
sleep 1
roles=$(TM list-panes -t "$ORCH_WIN" -F '#{@fm_role}' | sort | tr '\n' ' ')
assert_contains "$roles" "orchestrator" "orchestrator pane tagged"
assert_contains "$roles" "summary" "summary pane created"
assert_contains "$roles" "slot:1 slot:2 slot:3" "three watch slots created"
[ "$(TM list-panes -t "$ORCH_WIN" | grep -c .)" -eq 5 ] || fail "expected 5 panes after arrange"
active_role=$(TM display-message -p -t "$ORCH_WIN" '#{@fm_role}')
[ "$active_role" = orchestrator ] || fail "orchestrator pane must stay active/focused"
[ "$(TM show -w -t "$ORCH_WIN" -v @fm_layout)" = 1 ] || fail "@fm_layout marker should be set"
# Autofill: 3 live workers fill all 3 slots; no work was spawned to fill them.
filled=$(grep -l . "$STATE"/.layout-slot-1 "$STATE"/.layout-slot-2 "$STATE"/.layout-slot-3 2>/dev/null | grep -c .)
[ "$filled" -eq 3 ] || fail "expected all 3 slots autofilled from the 3 live workers"
pass "arrange builds command column + 3 slots, preserves the active orchestrator pane"

# --- 5. idempotent re-run, workers untouched -------------------------------
"$LAYOUT" arrange --window "$ORCH_WIN" >/dev/null
sleep 1
[ "$(TM list-panes -t "$ORCH_WIN" | grep -c .)" -eq 5 ] || fail "re-run should keep 5 panes"
for w in fm-alpha-aa fm-beta-bb fm-gamma-cc; do
  TM list-windows -t itest -F '#{window_name}' | grep -Fxq "$w" \
    || fail "worker window $w must survive arrange"
done
pass "re-running arrange is idempotent and leaves worker windows intact"

# --- 6. refusals -----------------------------------------------------------
set +e
out=$("$LAYOUT" arrange --window "$ALPHA_WIN" 2>&1); rc=$?
set -e
expect_code 1 "$rc" "arranging a worker window is refused"
assert_contains "$out" "worker window" "refusal names the worker-window reason"

TM new-window -t itest -n messy 'sleep 600'
MESSY_WIN=$(TM list-windows -t itest -F '#{window_id} #{window_name}' | awk '$2=="messy"{print $1}')
TM split-window -t "$MESSY_WIN" 'sleep 600'
set +e
out=$("$LAYOUT" arrange --window "$MESSY_WIN" 2>&1); rc=$?
set -e
expect_code 1 "$rc" "arranging a window with unexpected panes is refused"
assert_contains "$out" "unexpected pane" "refusal names the unexpected-pane reason"
[ "$(TM list-panes -t "$MESSY_WIN" | grep -c .)" -eq 2 ] || fail "refused window must keep its panes"
pass "arrange refuses worker windows and unexpected panes without destroying anything"

# --- 7. rendered content ---------------------------------------------------
summary=$(FM_LAYOUT_ONCE=1 FM_LAYOUT_STATE="$STATE" "$PANE" summary | sed 's/\x1b\[[0-9;]*m//g')
assert_contains "$summary" "active workers" "summary has a header"
assert_contains "$summary" "• scrub-cx-engine - alpha" "summary shows a terse repo/label bullet"

"$LAYOUT" assign 1 itest:fm-beta-bb >/dev/null
slot=$(FM_LAYOUT_ONCE=1 FM_LAYOUT_STATE="$STATE" TMUX_PANE="" "$PANE" 1 | sed 's/\x1b\[[0-9;]*m//g')
assert_contains "$slot" "portals-cx · beta" "watch pane header shows the assigned worker"
assert_contains "$slot" "beta-line" "watch pane mirrors the live worker's output"
pass "summary renders terse bullets and a watch pane mirrors its worker"

# --- 8. worker-reference shortcut (#-style picker) -------------------------
# fm_layout_ref reference formats (lib already sourced above).
[ "$(fm_layout_ref firstmate:fm-foo-k9)" = "fm-foo-k9" ] \
  || fail "ref default (window) format should be the bare window name"
[ "$(fm_layout_ref firstmate:fm-foo-k9 window)" = "fm-foo-k9" ] \
  || fail "ref window format should be the bare window name"
[ "$(fm_layout_ref firstmate:fm-foo-k9 target)" = "firstmate:fm-foo-k9" ] \
  || fail "ref target format should be the session:window"
[ "$(fm_layout_ref firstmate:fm-foo-k9 select)" = "tmux select-window -t firstmate:fm-foo-k9" ] \
  || fail "ref select format should be a runnable tmux command"

# `ref --print` lists every live worker with its reference token.
refs=$("$LAYOUT" ref --print -p dummy)
assert_contains "$refs" "itest:fm-alpha-aa" "ref --print lists the alpha worker reference"
assert_contains "$refs" "itest:fm-gamma-cc" "ref --print lists the gamma worker reference"
assert_not_contains "$refs" "fm-second-dd" "ref --print excludes the secondmate"

# insert-ref types the chosen worker's reference into a composer pane.
TM new-window -t itest -n composer 'cat'
CPANE=$(TM list-panes -t itest:composer -F '#{pane_id}')
"$LAYOUT" insert-ref -p "$CPANE" -w itest:fm-beta-bb
sleep 0.4
typed=$(TM capture-pane -p -t "$CPANE")
assert_contains "$typed" "fm-beta-bb" "insert-ref types the worker reference into the composer pane"

# insert-ref refuses a dead worker - nothing typed.
"$LAYOUT" insert-ref -p "$CPANE" -w itest:fm-nope-zz >/dev/null 2>&1 || true
sleep 0.2
typed2=$(TM capture-pane -p -t "$CPANE")
assert_not_contains "$typed2" "fm-nope-zz" "insert-ref never types a dead worker reference"
pass "worker-reference picker resolves refs and types them into the composer"

echo "# all fm-layout tests passed"
