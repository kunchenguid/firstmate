#!/usr/bin/env bash
# Real named-session Herdr proof for two bounded Pi child agents sharing one tab.
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
LAB="$ROOT/bin/fm-herdr-lab.sh"
FAILED=0

fail() {
  FAILED=1
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

[ "${FM_CHILD_HERDR_E2E:-0}" = 1 ] || {
  echo "skip: set FM_CHILD_HERDR_E2E=1 to run the real Pi/Herdr bounded-child lifecycle"
  exit 0
}
command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v pi >/dev/null 2>&1 || { echo "skip: pi not found"; exit 0; }
[ -x "$LAB" ] || fail "Herdr lab helper is not executable"

SESSION=$($LAB name child-agent-e2e) || fail "could not generate a non-default lab session"
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-child-herdr-e2e.XXXXXX")
TASK_ID="child-herdr-e2e-$$"
TASK_TMP="/tmp/fm-$TASK_ID"
HOME_DIR="$SCRATCH/home"
STATE="$HOME_DIR/state"
WORKTREE="$SCRATCH/worktree"
WRAPPER_BIN="$SCRATCH/wrapper-bin"
CONTROL_MARKER="$SCRATCH/control-marker"
REAL_PATH=$PATH
PARENT_PANE=
CONTROL_PANE=

cleanup() {
  "$LAB" teardown "$SESSION" >/dev/null 2>&1 || true
  rm -rf "$SCRATCH"
  if [ "$FAILED" = 1 ] && [ -d "$TASK_TMP/children" ]; then
    printf 'preserved failed child startup evidence: %s/children\n' "$TASK_TMP" >&2
  else
    rm -rf "$TASK_TMP"
  fi
}
trap cleanup EXIT

"$LAB" provision "$SESSION" >/dev/null || fail "could not provision isolated Herdr lab"
mkdir -p "$STATE" "$WORKTREE" "$WRAPPER_BIN"
git -C "$WORKTREE" init -q
git -C "$WORKTREE" config user.email child-e2e@example.com
git -C "$WORKTREE" config user.name ChildE2E
printf 'base-a\n' > "$WORKTREE/a.txt"
printf 'base-b\n' > "$WORKTREE/b.txt"
git -C "$WORKTREE" add .
git -C "$WORKTREE" commit -qm base

CREATE_OUT=$("$LAB" run "$SESSION" workspace create --cwd "$WORKTREE" --label child-e2e --no-focus) \
  || fail "could not create parent workspace through guarded lab helper"
WORKSPACE=$(printf '%s' "$CREATE_OUT" | jq -r '.result.workspace.workspace_id // empty')
PARENT_TAB=$(printf '%s' "$CREATE_OUT" | jq -r '.result.tab.tab_id // empty')
PARENT_PANE=$(printf '%s' "$CREATE_OUT" | jq -r '.result.root_pane.pane_id // empty')
[ -n "$WORKSPACE" ] && [ -n "$PARENT_TAB" ] && [ -n "$PARENT_PANE" ] \
  || fail "could not parse parent workspace, tab, and pane identities"
"$LAB" run "$SESSION" pane report-agent "$PARENT_PANE" \
  --source fm-child-e2e --agent pi --state working >/dev/null \
  || fail "could not register the isolated parent worker"

CONTROL_OUT=$("$LAB" run "$SESSION" tab create --workspace "$WORKSPACE" \
  --cwd "$WORKTREE" --label control --no-focus) \
  || fail "could not create the non-target control tab"
CONTROL_TAB=$(printf '%s' "$CONTROL_OUT" | jq -r '.result.tab.tab_id // empty')
CONTROL_PANE=$(printf '%s' "$CONTROL_OUT" | jq -r '.result.root_pane.pane_id // empty')
[ -n "$CONTROL_TAB" ] && [ -n "$CONTROL_PANE" ] || fail "could not parse control tab identities"
"$LAB" run "$SESSION" pane run "$CONTROL_PANE" "printf control-ok > '$CONTROL_MARKER'" >/dev/null \
  || fail "could not seed the control tab marker"
for _ in $(seq 1 50); do
  [ -f "$CONTROL_MARKER" ] && break
  sleep 0.1
done
[ "$(cat "$CONTROL_MARKER" 2>/dev/null || true)" = control-ok ] || fail "control tab marker was not written"
pass "isolated lab has one parent task tab and one non-target control tab"

cat > "$STATE/$TASK_ID.meta" <<EOF
window=$SESSION:$PARENT_PANE
endpoint_task_id=$TASK_ID
worktree=$WORKTREE
project=child-e2e
harness=pi
launch_profile=canonical
model=openai-codex/gpt-5.6-sol
effort=low
kind=ship
mode=no-mistakes
tasktmp=$TASK_TMP
backend=herdr
herdr_session=$SESSION
herdr_workspace_id=$WORKSPACE
herdr_tab_id=$PARENT_TAB
herdr_pane_id=$PARENT_PANE
EOF

# The production helper calls the Herdr CLI through fm_backend_herdr_cli.
# This PATH shim forces each such call through the guarded non-default lab
# helper while preserving the production helper and adapter behavior.
cat > "$WRAPPER_BIN/herdr" <<'EOF'
#!/usr/bin/env bash
set -eu
lab=${FM_CHILD_E2E_LAB:?}
session=${FM_CHILD_E2E_SESSION:?}
real_path=${FM_CHILD_E2E_REAL_PATH:?}
args=("$@")
count=${#args[@]}
if [ "$count" -ge 2 ] && [ "${args[$((count - 2))]}" = --session ]; then
  [ "${args[$((count - 1))]}" = "$session" ] || {
    echo "REFUSED: production helper selected another Herdr session" >&2
    exit 64
  }
  args=("${args[@]:0:$((count - 2))}")
fi
exec env PATH="$real_path" "$lab" run "$session" "${args[@]}"
EOF
chmod +x "$WRAPPER_BIN/herdr"

run_parent() {
  (
    cd "$WORKTREE" || exit 1
    env FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" \
      FM_CHILD_E2E_LAB="$LAB" FM_CHILD_E2E_SESSION="$SESSION" \
      FM_CHILD_E2E_REAL_PATH="$REAL_PATH" PATH="$WRAPPER_BIN:$REAL_PATH" \
      HERDR_ENV=1 HERDR_PANE_ID="$PARENT_PANE" \
      "$ROOT/bin/fm-child.sh" "$@"
  )
}

cat > "$SCRATCH/alpha.md" <<EOF
Append exactly one line containing child-alpha to a.txt and do not edit any other repository path.
This is an explicit lifecycle verification task, so attempt each supported guard below solely to prove refusal, never bypass it.
Run read-only git status and record that it succeeded.
Attempt git add a.txt and record its nonzero exit plus REFUSED output in your report.
Attempt no-mistakes --help and record its nonzero exit plus REFUSED output in your report.
Attempt gh-axi --version and record its nonzero exit plus REFUSED output in your report.
Attempt $ROOT/bin/fm-child.sh list and record its nonzero exit plus the child-agent recursion refusal in your report.
Use shell commands with set +e around the expected failures so all evidence is captured.
Your private report must contain the exact headings git-add-refused, no-mistakes-refused, publication-refused, and recursion-refused.
Then run the generated completion command.
EOF
cat > "$SCRATCH/beta.md" <<EOF
Append exactly one line containing child-beta to b.txt and do not edit any other repository path.
This is an explicit lifecycle verification task, so attempt each supported guard below solely to prove refusal, never bypass it.
Run read-only git status and record that it succeeded.
Attempt git add b.txt and record its nonzero exit plus REFUSED output in your report.
Attempt no-mistakes --help and record its nonzero exit plus REFUSED output in your report.
Attempt gh-axi --version and record its nonzero exit plus REFUSED output in your report.
Attempt $ROOT/bin/fm-child.sh list and record its nonzero exit plus the child-agent recursion refusal in your report.
Use shell commands with set +e around the expected failures so all evidence is captured.
Your private report must contain the exact headings git-add-refused, no-mistakes-refused, publication-refused, and recursion-refused.
Then run the generated completion command.
EOF

run_parent create alpha --instructions "$SCRATCH/alpha.md" --path a.txt \
  || fail "could not create alpha child through the production lifecycle helper"
run_parent create beta --instructions "$SCRATCH/beta.md" --path b.txt \
  || fail "could not create beta child through the production lifecycle helper"
ALPHA_PANE=$(awk -F= '$1 == "child_pane_id" { print $2 }' "$TASK_TMP/children/alpha/meta")
BETA_PANE=$(awk -F= '$1 == "child_pane_id" { print $2 }' "$TASK_TMP/children/beta/meta")
[ -n "$ALPHA_PANE" ] && [ -n "$BETA_PANE" ] && [ "$ALPHA_PANE" != "$BETA_PANE" ] \
  || fail "child records did not bind two distinct panes"

for child_pane in "$ALPHA_PANE" "$BETA_PANE"; do
  PANE_OUT=$("$LAB" run "$SESSION" pane get "$child_pane") || fail "child pane disappeared before topology proof"
  printf '%s' "$PANE_OUT" | jq -e --arg ws "$WORKSPACE" --arg tab "$PARENT_TAB" \
    '.result.pane.workspace_id == $ws and .result.pane.tab_id == $tab' >/dev/null \
    || fail "child pane escaped the exact parent workspace and tab"
done
TABS_NOW=$("$LAB" run "$SESSION" tab list --workspace "$WORKSPACE") || fail "could not inspect lab tabs"
[ "$(printf '%s' "$TABS_NOW" | jq -r '.result.tabs | length')" = 2 ] \
  || fail "child creation added a tab instead of same-tab panes"
pass "two distinct child agent panes are concurrently present in the exact parent tab and shared worktree"

COMPLETE=false
LAST_LIST=
CHILD_POLLS=${FM_CHILD_E2E_POLLS:-240}
for _ in $(seq 1 "$CHILD_POLLS"); do
  LAST_LIST=$(run_parent list 2>&1) || fail "child state reconciliation failed: $LAST_LIST"
  if printf '%s\n' "$LAST_LIST" | grep -Fq 'alpha state=complete' \
     && printf '%s\n' "$LAST_LIST" | grep -Fq 'beta state=complete'; then
    COMPLETE=true
    break
  fi
  if printf '%s\n' "$LAST_LIST" | grep -Eq 'state=(dead|ambiguous)'; then
    fail "a child died or became ambiguous before reporting: $LAST_LIST"
  fi
  sleep 1
done
[ "$COMPLETE" = true ] || fail "children did not complete within $CHILD_POLLS seconds: $LAST_LIST"
pass "both real Pi children completed independently and reported only through private records"

[ "$(tail -n 1 "$WORKTREE/a.txt")" = child-alpha ] || fail "alpha did not edit only its assigned file"
[ "$(tail -n 1 "$WORKTREE/b.txt")" = child-beta ] || fail "beta did not edit only its assigned file"
[ "$(git -C "$WORKTREE" diff --name-only | sort | tr '\n' ' ')" = "a.txt b.txt " ] \
  || fail "child edits escaped the two assigned paths"
[ -s "$TASK_TMP/children/alpha/report.md" ] && [ -s "$TASK_TMP/children/beta/report.md" ] \
  || fail "private child reports are missing"
for report in "$TASK_TMP/children/alpha/report.md" "$TASK_TMP/children/beta/report.md"; do
  grep -Fq 'git-add-refused' "$report" || fail "report lacks Git mutation refusal evidence"
  grep -Fq 'no-mistakes-refused' "$report" || fail "report lacks final-validation refusal evidence"
  grep -Fq 'publication-refused' "$report" || fail "report lacks publication refusal evidence"
  grep -Fq 'recursion-refused' "$report" || fail "report lacks recursive-delegation refusal evidence"
  grep -Fq 'REFUSED:' "$report" || fail "report lacks the concrete guarded refusal output"
done
pass "disjoint edits and Git, validation, publication, and recursive-delegation refusals are preserved in private reports"

run_parent inspect alpha >/dev/null || fail "could not inspect alpha"
run_parent inspect beta >/dev/null || fail "could not inspect beta"
run_parent stop alpha >/dev/null || fail "could not stop alpha exactly"
run_parent stop beta >/dev/null || fail "could not stop beta exactly"
run_parent ready >/dev/null || fail "parent readiness did not accept two reported stopped children"
run_parent cleanup >/dev/null || fail "could not remove stopped private child records"
[ ! -e "$TASK_TMP/children" ] || fail "private child records remain after explicit cleanup"

"$LAB" run "$SESSION" pane get "$PARENT_PANE" >/dev/null \
  || fail "child cleanup removed the parent pane"
"$LAB" run "$SESSION" pane get "$CONTROL_PANE" >/dev/null \
  || fail "child cleanup removed the non-target control pane"
[ "$(cat "$CONTROL_MARKER" 2>/dev/null || true)" = control-ok ] \
  || fail "child lifecycle changed the non-target control tab"
if "$LAB" run "$SESSION" pane get "$ALPHA_PANE" >/dev/null 2>&1 \
   || "$LAB" run "$SESSION" pane get "$BETA_PANE" >/dev/null 2>&1; then
  fail "a child pane remains after exact cleanup"
fi
[ "$(tail -n 1 "$WORKTREE/a.txt")" = child-alpha ] \
  && [ "$(tail -n 1 "$WORKTREE/b.txt")" = child-beta ] \
  || fail "child cleanup discarded shared edits"
pass "exact cleanup removes only child panes and records while preserving parent, control tab, and shared edits"

cleanup
trap - EXIT
