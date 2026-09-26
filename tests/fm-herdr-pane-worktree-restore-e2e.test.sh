#!/usr/bin/env bash
# tests/fm-herdr-pane-worktree-restore-e2e.test.sh - real-herdr regression test
# for where a worker comes back after a Herdr server restart.
#
# Herdr saves each pane's CREATION cwd plus the agent session last reported in
# it, and on a restart respawns the pane in that cwd and types the agent's own
# resume command there (`claude --resume <id>`; `[session]
# resume_agents_on_restore` is on by default). So a worker comes back in the
# directory its pane was created in, whatever its shell moved to afterwards.
# This pins, through the full bin/fm-spawn.sh path and the real binary:
#
#   1. A fresh flat spawn and a fresh presentation-projection spawn each create
#      their pane in the task's leased worktree, so Herdr saves the worktree.
#   2. A stop and fresh start of the session restores the pane there and
#      resumes the recorded agent session in the worktree.
#   3. A relaunch replaces the pane with a fresh one in the worktree, so the
#      saved cwd stays the worktree and the next restart resumes the
#      replacement's conversation, not the previous one.
#   4. A spawn that aborts after taking its lease and pane leaves neither.
#
# No real harness runs and no model tokens are spent. A stub named `claude` on
# the lab server's PATH records the directory and arguments it was started
# with, and the agent session is reported through Herdr's own
# `pane report-agent-session` under Herdr's claude source, which is what the
# restore path reads. A probe pane proves the stub is the `claude` a restored
# pane resolves before anything is restored, so a real Claude is never resumed.
#
# Every Herdr call goes through bin/fm-herdr-lab.sh on a private named lab
# session; the live default session is never touched.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }
command -v treehouse >/dev/null 2>&1 || { echo "skip: treehouse not found (required by fm-spawn.sh)"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-herdr-pane-wt.XXXXXX")
# The Treehouse pool lives inside this scratch root. Treehouse ignores its pool
# in whichever repository encloses it, so the root is its own repository and
# that ignore entry never lands in the repository running this test.
git -C "$TMP_ROOT" init -q
export TREEHOUSE_ROOT="$TMP_ROOT/pool"
HERDR_LAB_HELPER="$ROOT/bin/fm-herdr-lab.sh"
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fm-herdr-pane-wt) || {
  rm -rf "$TMP_ROOT"
  printf 'not ok - could not generate an isolated Herdr lab session name\n' >&2
  exit 1
}
export HERDR_SESSION="$HERDR_LAB_SESSION"
ABORT_ID="pwabort$$"
FLAT_ID="pwflat$$"
PRES_ID="pwpres$$"
PROJ="$TMP_ROOT/proj"
TAB=$'\t'

# The lab server, and so every pane it spawns or restores, inherits this PATH.
FAKEBIN="$TMP_ROOT/fakebin"
CALLS="$TMP_ROOT/claude-calls.log"
mkdir -p "$FAKEBIN"
: > "$CALLS"
cat > "$FAKEBIN/claude" <<EOF
#!/usr/bin/env bash
printf '%s\t%s\n' "\$(pwd -P)" "\$*" >> '$CALLS'
exec sleep 900
EOF
cat > "$FAKEBIN/codex" <<'EOF'
#!/usr/bin/env bash
exec sleep 900
EOF
chmod +x "$FAKEBIN/claude" "$FAKEBIN/codex"
export PATH="$FAKEBIN:$PATH"

CLEANED=0
cleanup_all() {
  local wt status=0
  [ "$CLEANED" = 0 ] || return 0
  CLEANED=1
  while IFS= read -r wt; do
    [ -z "$wt" ] || (cd "$PROJ" && treehouse return --force "$wt") >/dev/null 2>&1
  done < <(sed -n 's/^worktree=//p' "$TMP_ROOT"/*/state/*.meta 2>/dev/null)
  "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || status=$?
  rm -rf "/tmp/fm-$ABORT_ID" "/tmp/fm-$FLAT_ID" "/tmp/fm-$PRES_ID"
  find "$TMP_ROOT" -type d -exec chmod u+rwx {} + 2>/dev/null
  rm -rf "$TMP_ROOT"
  return "$status"
}
trap cleanup_all EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" || fail "could not provision isolated Herdr lab session"

lab() { "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }

SESSION_FILE=$(lab session list --json 2>/dev/null \
  | jq -r --arg s "$HERDR_LAB_SESSION" '.sessions[]? | select(.name == $s) | .session_dir' 2>/dev/null)/session.json
[ "$SESSION_FILE" != /session.json ] || fail "could not read the lab session's directory"

restart_lab() {
  "$HERDR_LAB_HELPER" stop "$HERDR_LAB_SESSION" >/dev/null || fail "could not stop the lab session"
  "$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" >/dev/null || fail "could not start the lab session again"
}

pane_field() {  # <pane> <field>
  lab pane get "$1" 2>/dev/null | jq -r --arg f "$2" '.result.pane[$f] // empty' 2>/dev/null
}

pane_gone() {  # <pane>
  [ "$(lab pane get "$1" 2>&1 | jq -r '.error.code // empty' 2>/dev/null)" = pane_not_found ]
}

# The saved panes whose cwd is <dir>, as "<cwd>\t<agent session or ->" lines.
saved_panes_in() {  # <dir>
  jq -r --arg d "$1" '
    .workspaces[].tabs[].panes[] | select(.cwd == $d)
    | [.cwd, (.agent_session.value // "-")] | @tsv
  ' "$SESSION_FILE" 2>/dev/null
}

# Herdr persists on a debounce of about thirty seconds.
wait_saved() {  # <dir> <expected saved_panes_in output>
  local _i
  for _i in $(seq 1 90); do
    [ "$(saved_panes_in "$1")" != "$2" ] || return 0
    sleep 1
  done
  return 1
}

wait_call() {  # <line>
  local _i
  for _i in $(seq 1 100); do
    grep -Fxq "$1" "$CALLS" && return 0
    sleep 0.2
  done
  return 1
}

report_session() {  # <pane> <session-id>
  lab pane report-agent "$1" --source herdr:claude --agent claude --state idle \
    --agent-session-id "$2" >/dev/null 2>&1 || fail "could not report an agent on $1"
  lab pane report-agent-session "$1" --source herdr:claude --agent claude \
    --agent-session-id "$2" >/dev/null 2>&1 || fail "could not report agent session $2 on $1"
}

stop_foreground() {  # <pane>
  local pid
  pid=$(lab pane process-info --pane "$1" 2>/dev/null \
    | jq -r '.result.process_info.foreground_processes[0].pid // empty' 2>/dev/null)
  [ -n "$pid" ] || fail "could not read the foreground process of $1"
  kill "$pid" 2>/dev/null || fail "could not stop the foreground process of $1"
}

# --- safety probe: the stub is what a restored pane resolves as claude -------

PROBE_OUT="$TMP_ROOT/probe.out"
PROBE=$(lab workspace create --cwd "$TMP_ROOT" --label probe --no-focus 2>/dev/null \
  | jq -r '.result.root_pane.pane_id // empty')
[ -n "$PROBE" ] || fail "could not create the probe pane"
lab pane run "$PROBE" "command -v claude > '$PROBE_OUT'" >/dev/null 2>&1 || fail "could not run the probe"
for _ in $(seq 1 50); do [ -s "$PROBE_OUT" ] && break; sleep 0.1; done
[ "$(cat "$PROBE_OUT" 2>/dev/null)" = "$FAKEBIN/claude" ] \
  || fail "a lab pane resolves claude to '$(cat "$PROBE_OUT" 2>/dev/null)', not the stub; refusing to restore anything that could resume a real Claude"
lab workspace close "$(pane_field "$PROBE" workspace_id)" >/dev/null 2>&1 || true

# --- scratch world ------------------------------------------------------------

mkdir -p "$PROJ"
git -C "$PROJ" init -q
printf '# proj\n' > "$PROJ/README.md"
git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
git clone --quiet --bare "$PROJ" "$TMP_ROOT/proj.origin.git"
git -C "$PROJ" remote add origin "file://$TMP_ROOT/proj.origin.git"
PROJ_REAL=$(cd "$PROJ" && pwd -P)
pool_status() { (cd "$PROJ" && treehouse status) 2>/dev/null; }

make_home() {  # <home> <presentation-setting>
  mkdir -p "$1/state" "$1/config"
  printf '%s\n' "$2" > "$1/config/herdr-presentation-spaces"
}
FLAT_HOME="$TMP_ROOT/flat-home"; make_home "$FLAT_HOME" off
PRES_HOME="$TMP_ROOT/pres-home"; make_home "$PRES_HOME" on

spawn_task() {  # <home> <id>
  mkdir -p "$1/data/$2"
  cat > "$1/data/$2/brief.md" <<EOF
# Task
## Captain's intent
Exercise where the $2 worker comes back after a Herdr restart.

## Firstmate spec
Keep the lab isolated.
EOF
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SOCKET_PATH HERDR_SESSION="$HERDR_LAB_SESSION" \
    FM_SPAWN_NO_GUARD=1 FM_HOME="$1" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-spawn.sh" "$2" "$PROJ" "sh -c 'exec claude first'" --backend herdr \
    --mode no-mistakes --yolo off >"$TMP_ROOT/$2.out" 2>"$TMP_ROOT/$2.err"
}

meta_get() {  # <home> <id> <key>
  sed -n "s/^$3=//p" "$1/state/$2.meta" 2>/dev/null | tail -1
}

# --- 1 and 2: fresh spawns save and restore their worktree --------------------

declare -A TASK_WT TASK_PANE
for spec in "$FLAT_HOME $FLAT_ID flat" "$PRES_HOME $PRES_ID projected"; do
  read -r home id shape <<EOF
$spec
EOF
  spawn_task "$home" "$id" || fail "the $shape spawn failed"$'\n'"$(cat "$TMP_ROOT/$id.err")"
  wt=$(meta_get "$home" "$id" worktree)
  pane=$(meta_get "$home" "$id" herdr_pane_id)
  [ -n "$wt" ] && [ -n "$pane" ] || fail "the $shape spawn recorded no worktree or pane"
  wt_real=$(cd "$wt" && pwd -P)
  [ "$wt_real" != "$PROJ_REAL" ] || fail "the $shape spawn recorded the primary checkout as its worktree"
  # treehouse status abbreviates the home directory to ~.
  pool_status | grep -F "${wt/#$HOME/\~} " | grep -Fq "(held by $id)" \
    || fail "the $shape spawn's worktree is not leased to its task: $(pool_status)"
  [ "$(pane_field "$pane" cwd)" = "$wt_real" ] \
    || fail "the $shape spawn created its pane in '$(pane_field "$pane" cwd)', not its worktree '$wt_real'"
  wait_call "$wt_real${TAB}first" || fail "the $shape worker did not start in its worktree: $(cat "$CALLS")"
  report_session "$pane" "sess-$id-1"
  TASK_WT[$id]=$wt_real
  TASK_PANE[$id]=$pane
done
pass "real herdr: fresh flat and projected spawns create their pane in the task's leased worktree"

for id in "$FLAT_ID" "$PRES_ID"; do
  wt=${TASK_WT[$id]}
  wait_saved "$wt" "$wt${TAB}sess-$id-1" \
    || fail "Herdr did not save $id's pane in its worktree with its session: $(saved_panes_in "$wt")"
done
pass "real herdr: Herdr saves each fresh worker's pane in its worktree"

restart_lab
for id in "$FLAT_ID" "$PRES_ID"; do
  wt=${TASK_WT[$id]}
  pane=${TASK_PANE[$id]}
  wait_call "$wt${TAB}--resume sess-$id-1" \
    || fail "after a restart Herdr did not resume $id in its worktree: $(cat "$CALLS")"
  [ "$(pane_field "$pane" cwd)" = "$wt" ] || fail "after a restart $id's pane is in '$(pane_field "$pane" cwd)'"
done
grep -Fq "$PROJ_REAL${TAB}" "$CALLS" && fail "a worker was resumed in the primary checkout: $(cat "$CALLS")"
pass "real herdr: a server restart restores and resumes every worker in its worktree"

# --- 3: relaunch keeps the worktree and the replacement's conversation --------

id=$FLAT_ID
home=$FLAT_HOME
wt=${TASK_WT[$id]}
old_pane=${TASK_PANE[$id]}
old_ws=$(meta_get "$home" "$id" herdr_workspace_id)
stop_foreground "$old_pane"
env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SOCKET_PATH HERDR_SESSION="$HERDR_LAB_SESSION" \
  FM_SPAWN_NO_GUARD=1 FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-spawn.sh" "$id" --relaunch --harness codex >"$TMP_ROOT/relaunch.out" 2>"$TMP_ROOT/relaunch.err" \
  || fail "the relaunch failed"$'\n'"$(cat "$TMP_ROOT/relaunch.err")"
new_pane=$(meta_get "$home" "$id" herdr_pane_id)
[ -n "$new_pane" ] && [ "$new_pane" != "$old_pane" ] || fail "the relaunch kept pane '$old_pane' instead of replacing it"
[ "$(meta_get "$home" "$id" window)" = "$HERDR_LAB_SESSION:$new_pane" ] || fail "the relaunch record does not name its replacement pane"
[ "$(meta_get "$home" "$id" herdr_workspace_id)" = "$old_ws" ] || fail "the relaunch moved the task to another workspace"
[ "$(pane_field "$new_pane" workspace_id)" = "$old_ws" ] || fail "the replacement pane is not in the task's workspace"
[ "$(meta_get "$home" "$id" worktree)" = "$wt" ] || fail "the relaunch changed the task's worktree"
pane_gone "$old_pane" || fail "the relaunch left the superseded pane $old_pane open"
[ "$(pane_field "$new_pane" cwd)" = "$wt" ] || fail "the replacement pane was created in '$(pane_field "$new_pane" cwd)', not the worktree"
[ "$(lab tab get "$(pane_field "$new_pane" tab_id)" 2>/dev/null | jq -r '.result.tab.label')" = "fm-$id" ] \
  || fail "the replacement tab does not carry the task label"
pass "real herdr: a relaunch replaces the pane in the same workspace, created in the worktree"

report_session "$new_pane" "sess-$id-2"
wait_saved "$wt" "$wt${TAB}sess-$id-2" \
  || fail "after the relaunch Herdr saved '$(saved_panes_in "$wt")' rather than only the replacement's session in the worktree"
: > "$CALLS"
restart_lab
wait_call "$wt${TAB}--resume sess-$id-2" \
  || fail "after a restart the relaunched worker was not resumed with its own conversation in its worktree: $(cat "$CALLS")"
grep -Fq -- "--resume sess-$id-1" "$CALLS" && fail "a restart resumed the conversation from before the relaunch: $(cat "$CALLS")"
pass "real herdr: after a relaunch a restart resumes the replacement's conversation in the worktree"

# --- 4: an aborted spawn leaves no lease and no pane --------------------------

# The per-task temp root is refused when it is not a private directory, which
# aborts the spawn after its lease, pane, and slot claim exist.
: > "/tmp/fm-$ABORT_ID"
if spawn_task "$FLAT_HOME" "$ABORT_ID"; then
  fail "the spawn with an unusable temp root should have aborted"
fi
rm -f "/tmp/fm-$ABORT_ID"
grep -Fq "not a private directory" "$TMP_ROOT/$ABORT_ID.err" \
  || fail "the spawn aborted for an unexpected reason: $(cat "$TMP_ROOT/$ABORT_ID.err")"
[ ! -e "$FLAT_HOME/state/$ABORT_ID.meta" ] || fail "the aborted spawn left a task record"
pool_status | grep -Fq "held by $ABORT_ID" \
  && fail "the aborted spawn left its worktree leased: $(pool_status)"
[ -z "$(lab tab list 2>/dev/null | jq -r --arg l "fm-$ABORT_ID" '.result.tabs[]? | select(.label == $l) | .tab_id')" ] \
  || fail "the aborted spawn left its pane open"
pass "real herdr: a spawn that aborts after taking its lease and pane returns the lease and closes the pane"
