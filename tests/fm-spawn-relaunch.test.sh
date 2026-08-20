#!/usr/bin/env bash
# tests/fm-spawn-relaunch.test.sh - placement recovery for a relaunch whose
# launcher pane died with the endpoint it is recovering.
#
# Placement has two halves, and a relaunch needs both. WHICH WORKSPACE the
# replacement lands in is the first; WHICH DIRECTORY its shell starts in is the
# second, and the one the worktree assertion measures. Cases 1-7 cover the
# workspace half. Cases 8-9 cover the directory half: the replacement must be
# created in the worktree the task already has, and a replacement that lands
# anywhere else must still be refused.
#
# fm-spawn.sh --relaunch presents the task's OWN recorded pane as the launcher,
# so a replacement lands back in the workspace the task already lived in. When
# the endpoint is provably absent that pane is gone too, so
# fm_backend_herdr_launcher_identity cannot read it and refuses - leaving the
# exact case --relaunch exists for with no way through, and with the workspace
# it needed sitting unread in the task's own durable record.
#
# fm_backend_herdr_relaunch_placement is the only path out of that refusal.
# These tests pin both halves of it: that a relaunch with proof recovers, and
# that every case WITHOUT proof still refuses rather than guessing at
# placement.
#
# Layer 1 (canned fake herdr CLI + real jq) drives
# fm_backend_herdr_workspace_ensure directly, the function that owns both the
# refusal and the recovery. Layer 2 drives the real bin/fm-spawn.sh --relaunch
# to prove the recovery input is actually handed over on that path, rather than
# being a backend capability nothing reaches.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/herdr-test-safety.sh
. "$(dirname "${BASH_SOURCE[0]}")/herdr-test-safety.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

# These cases script a canned fake CLI, and each sets the pane identity it
# means to exercise. A Herdr pane identity leaked in from the developer's own
# terminal would otherwise resolve a launcher this fake never models.
herdr_forget_inherited_pane

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-relaunch)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)

SESSION=fmtest
SOCKET=/tmp/fm-herdr-relaunch-unit/fmtest.sock
DEAD_PANE=wD:p7Y
RECORDED_WS=wD

# make_herdr_fakebin: a canned `herdr` stub keyed on the QUERY rather than on
# call order - `pane get` is answered from $FM_HERDR_RESPONSES/pane-get.out
# (with an optional pane-get.exit for a call the real CLI fails), `workspace
# list` from workspace-list.out, and so on. Keying on the query is what makes
# these cases faithful: a real herdr answers the same question the same way
# however many times it is asked, and both the placement refusal and the
# absence proof below read the same pane. A call-numbered fake would instead
# couple every assertion to exactly how many probes the adapter happens to
# make, so removing a probe would shift every later answer and fail the suite
# for a reason unrelated to the guard being removed. Every invocation is logged
# unit-separated to $FM_HERDR_LOG, matching the adapter's own unit tests.
make_herdr_fakebin() {  # <dir> -> echoes fakebin dir
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
LOG="${FM_HERDR_LOG:?}"
RESP="${FM_HERDR_RESPONSES:?}"
{
  printf 'HERDR_SESSION=%s' "${HERDR_SESSION:-}"
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$LOG"
if [ "${1:-}" = status ] && [ "${2:-}" = --json ]; then
  printf '{"client":{"version":"0.7.1","protocol":14},"server":{"running":true}}\n'
  exit 0
fi
key="${1:-}-${2:-}"
[ -f "$RESP/$key.out" ] && cat "$RESP/$key.out"
if [ -f "$RESP/$key.exit" ]; then
  exit "$(cat "$RESP/$key.exit")"
fi
exit 0
SH
  chmod +x "$fb/herdr"
  printf '%s\n' "$fb"
}

# new_placement_case: one response directory modelling the destroyed-launcher
# situation every case here starts from - the session's socket resolves, and
# reading the launcher pane fails exactly the way the real CLI fails for a pane
# that no longer exists (a pane_not_found body AND a non-zero exit).
new_placement_case() {  # <name> -> echoes <dir>
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/responses"
  : > "$dir/log"
  make_herdr_fakebin "$dir" >/dev/null
  printf '{"sessions":[{"name":"%s","running":true,"socket_path":"%s"}]}\n' \
    "$SESSION" "$SOCKET" > "$dir/responses/session-list.out"
  printf '{"error":{"code":"pane_not_found","message":"pane %s not found"}}\n' \
    "$DEAD_PANE" > "$dir/responses/pane-get.out"
  printf '1\n' > "$dir/responses/pane-get.exit"
  printf '{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate"},{"workspace_id":"%s","label":"firstmate"}]}}\n' \
    "$RECORDED_WS" > "$dir/responses/workspace-list.out"
  printf '%s\n' "$dir"
}

# run_ensure: fm_backend_herdr_workspace_ensure for a crewmate of this home,
# launched from the destroyed pane, with whatever recovery input the case opted
# in to. Echoes stdout and stderr together; the caller checks the exit code.
run_ensure() {  # <dir> [<recorded-session> <recorded-workspace>]
  local dir=$1 rec_ses=${2:-} rec_ws=${3:-}
  ( PATH="$dir/fakebin:$PATH" \
    FM_HERDR_LOG="$dir/log" FM_HERDR_RESPONSES="$dir/responses" \
    HERDR_ENV=1 HERDR_PANE_ID="$DEAD_PANE" HERDR_SESSION="$SESSION" \
    HERDR_SOCKET_PATH="$SOCKET" \
    FM_BACKEND_HERDR_RELAUNCH_SESSION="$rec_ses" \
    FM_BACKEND_HERDR_RELAUNCH_WORKSPACE_ID="$rec_ws" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_workspace_ensure "$1" /tmp' \
    "$ROOT" "$SESSION" 2>&1 )
}

# --- 1. the gap this task exists to close ------------------------------------

test_relaunch_recovers_the_recorded_workspace() {
  local dir out rc
  # The default fixture is already this case: the pane is provably gone and the
  # recorded workspace is still live, alongside a same-labeled sibling that a
  # label search could just as easily have picked.
  dir=$(new_placement_case recovers)
  out=$(run_ensure "$dir" "$SESSION" "$RECORDED_WS"); rc=$?
  expect_code 0 "$rc" "a relaunch whose launcher pane is provably gone must recover its recorded placement"
  assert_contains "$out" "$RECORDED_WS" "the recovered placement should be the task's own recorded workspace"
  assert_contains "$out" "provably gone" "a recovered placement must announce why it was recovered"
  assert_contains "$out" "recorded workspace" "a recovered placement must announce what it recovered to"
  assert_not_contains "$(cat "$dir/log")" $'\x1f''workspace'$'\x1f''create' \
    "recovery must reuse the recorded workspace, never mint a fresh one"
  pass "workspace_ensure: a relaunch recovers placement from the task's own recorded workspace when its launcher pane is provably gone"
}

# --- 2. mutation check: "I could not check" is never "it is gone" ------------

test_relaunch_refuses_a_pane_that_is_only_unreadable() {
  local dir out rc
  dir=$(new_placement_case unreadable)
  # The pane read fails for a reason that does NOT prove absence - the same
  # boundary --relaunch itself draws between 'missing' and 'unreadable'. The
  # recorded workspace is deliberately still present, so the ONLY thing
  # standing between this case and a recovered placement is that proof.
  printf '{"error":{"code":"internal_error","message":"server busy"}}\n' \
    > "$dir/responses/pane-get.out"
  out=$(run_ensure "$dir" "$SESSION" "$RECORDED_WS"); rc=$?
  expect_code 3 "$rc" "an unreadable launcher pane must keep the placement refusal"
  assert_contains "$out" "refusing to place a worker" "the original refusal must survive an unproven absence"
  assert_not_contains "$out" "provably gone" "an unreadable pane must never be announced as recovered"
  pass "workspace_ensure: an unreadable launcher pane is not a gone one, and still refuses placement"
}

# --- 3. nothing left to recover to -------------------------------------------

test_relaunch_refuses_when_the_recorded_workspace_is_gone() {
  local dir out rc
  dir=$(new_placement_case workspace-gone)
  # The whole workspace went with the pane, so the record points at nothing -
  # but a same-labeled workspace remains, which is exactly what a placement
  # that degraded to a label search would settle on.
  printf '{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate"}]}}\n' \
    > "$dir/responses/workspace-list.out"
  out=$(run_ensure "$dir" "$SESSION" "$RECORDED_WS"); rc=$?
  expect_code 3 "$rc" "a recorded workspace that is no longer present must keep the refusal"
  assert_contains "$out" "refusing to place a worker" "the original refusal must survive a missing recorded workspace"
  assert_not_contains "$(cat "$dir/log")" $'\x1f''workspace'$'\x1f''create' \
    "a failed recovery must refuse, never fall through to minting a workspace"
  pass "workspace_ensure: a recorded workspace that no longer exists refuses rather than placing the worker elsewhere"
}

# --- 4. a recorded id from another session names a different workspace -------

test_relaunch_refuses_a_recorded_workspace_from_another_session() {
  local dir out rc
  # Herdr workspace ids restart at the same low values in every session, so this
  # recorded id resolves to a real - but unrelated - workspace in the session
  # being spawned into. Everything else about the case would recover.
  dir=$(new_placement_case cross-session)
  out=$(run_ensure "$dir" other-session "$RECORDED_WS"); rc=$?
  expect_code 3 "$rc" "a recorded placement from another herdr session must keep the refusal"
  assert_contains "$out" "refusing to place a worker" "the original refusal must survive a cross-session record"
  assert_not_contains "$out" "provably gone" "a cross-session record must never be announced as recovered"
  pass "workspace_ensure: a recorded workspace from another session is not this session's workspace, and refuses"
}

# --- 5. the refusal is unchanged for everything that is not a relaunch -------

test_a_fresh_spawn_still_refuses_a_dead_launcher_pane() {
  local dir out rc
  # No recovery input at all: this is an ordinary spawn from a broken pane,
  # with a live same-labeled workspace sitting right there to be adopted.
  dir=$(new_placement_case fresh-spawn)
  out=$(run_ensure "$dir"); rc=$?
  expect_code 3 "$rc" "an ordinary spawn from an unreadable pane must still refuse"
  assert_contains "$out" "refusing to place a worker" "the pre-existing refusal must be untouched for a fresh spawn"
  assert_not_contains "$out" "provably gone" "a fresh spawn has no recorded placement and must never recover one"
  pass "workspace_ensure: a spawn that is not a relaunch keeps the original refusal exactly"
}

# --- Layer 2: the recovery input actually reaches the backend ----------------
#
# The cases above pin what fm_backend_herdr_workspace_ensure does with a
# recorded placement. These pin that bin/fm-spawn.sh --relaunch hands one over,
# which is the difference between a capability and a fix: the reported incident
# had the workspace it needed sitting in the task's own record and never
# consulted it. Both cases replay that incident's exact shape - a destroyed
# pane wD:p7Y whose task recorded workspace wD.
#
# make_spawn_case builds a real project, a real worktree, a real task record,
# and a fake herdr keyed on the PANE ASKED FOR, so the destroyed pane and the
# replacement pane can answer differently in the same run.
make_spawn_case() {  # <name> <recorded-workspace-still-live: yes|no> [honour-cwd: yes|no] -> echoes <dir>
  local name=$1 live=$2 honour=${3:-yes} id=rl-p1 dir workspaces
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/fakebin" "$dir/home/state" "$dir/home/data/$id"
  : > "$dir/log"
  fm_git_worktree "$dir/proj" "$dir/wt" "task-$id"
  printf '# brief for %s\n\nDo the thing.\n' "$id" > "$dir/home/data/$id/brief.md"
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=$SESSION:$DEAD_PANE" \
    "endpoint_task_id=$id" \
    "worktree=$dir/wt" \
    "project=$dir/proj" \
    "harness=claude" \
    "kind=ship" \
    "mode=direct-PR" \
    "yolo=off" \
    "backend=herdr" \
    "herdr_session=$SESSION" \
    "herdr_workspace_id=$RECORDED_WS" \
    "herdr_tab_id=$RECORDED_WS:t7" \
    "herdr_pane_id=$DEAD_PANE" \
    "model=default" \
    "effort=default"
  if [ "$live" = yes ]; then
    workspaces='{"workspace_id":"w1","label":"firstmate"},{"workspace_id":"'$RECORDED_WS'","label":"firstmate"}'
  else
    # The workspace went with the pane. A same-labeled one remains, so a
    # placement that degraded to a label search would happily adopt it.
    workspaces='{"workspace_id":"w1","label":"firstmate"}'
  fi
  cat > "$dir/fakebin/herdr" <<SH
#!/usr/bin/env bash
set -u
printf 'CALL' >> "\$FM_HERDR_LOG"
for a in "\$@"; do printf '\x1f%s' "\$a"; done >> "\$FM_HERDR_LOG"
printf '\n' >> "\$FM_HERDR_LOG"
case "\${1:-}-\${2:-}" in
  status---json)
    printf '{"client":{"version":"0.7.1","protocol":14},"server":{"running":true}}\n' ;;
  session-list)
    printf '{"sessions":[{"name":"$SESSION","running":true,"socket_path":"$SOCKET"}]}\n' ;;
  pane-get)
    if [ "\${3:-}" = "$DEAD_PANE" ]; then
      printf '{"error":{"code":"pane_not_found","message":"pane gone"}}\n'
      exit 1
    fi
    # A pane reports the directory it was CREATED in. Answering with the
    # worktree unconditionally would model a backend that places every pane
    # correctly no matter what it was asked for, which is exactly the
    # assumption under test.
    started="$dir/proj"
    [ ! -f "$dir/created-cwd" ] || started=\$(cat "$dir/created-cwd")
    printf '{"result":{"pane":{"pane_id":"\${3:-}","tab_id":"$RECORDED_WS:t9","workspace_id":"$RECORDED_WS","cwd":"'"\$started"'","foreground_cwd":"'"\$started"'"}}}\n' ;;
  workspace-list)
    printf '{"result":{"workspaces":[$workspaces]}}\n' ;;
  tab-list)
    printf '{"result":{"tabs":[]}}\n' ;;
  tab-create)
    want=""
    prev=""
    for a in "\$@"; do
      [ "\$prev" != "--cwd" ] || want=\$a
      prev=\$a
    done
    if [ "$honour" = yes ]; then
      printf '%s' "\$want" > "$dir/created-cwd"
    else
      # A backend that took the request and placed the pane somewhere else
      # anyway. The relaunch must refuse, not adopt it.
      printf '%s' "$dir/proj" > "$dir/created-cwd"
    fi
    printf '{"result":{"tab":{"tab_id":"$RECORDED_WS:t9"},"root_pane":{"pane_id":"$RECORDED_WS:p9"}}}\n' ;;
  agent-get)
    printf '{"error":{"code":"agent_not_found","message":"none"}}\n' ;;
esac
exit 0
SH
  chmod +x "$dir/fakebin/herdr"
  printf '%s\n' "$dir"
}

run_spawn_relaunch() {  # <dir> -> echoes combined output; caller checks $?
  local dir=$1
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_HERDR_LOG="$dir/log" \
    FM_SPAWN_NO_GUARD=1 \
    HERDR_ENV=1 HERDR_SESSION="$SESSION" HERDR_SOCKET_PATH="$SOCKET" \
    "$SPAWN" rl-p1 --relaunch --harness claude 2>&1
}

# --- 6. the reported incident, end to end ------------------------------------

test_spawn_relaunch_recovers_a_destroyed_pane() {
  local dir out rc
  dir=$(make_spawn_case spawn-recovers yes)
  out=$(run_spawn_relaunch "$dir"); rc=$?
  expect_code 0 "$rc" "a relaunch whose pane was destroyed must complete, not dead-end on placement"
  assert_contains "$out" "provably absent" "the relaunch should still report the endpoint as provably absent"
  assert_contains "$out" "could not be read" "the destroyed launcher pane should still be reported"
  assert_contains "$out" "recorded workspace '$RECORDED_WS'" \
    "the recovery must name the workspace it placed the replacement in"
  assert_contains "$(cat "$dir/log")" $'\x1f''tab'$'\x1f''create'$'\x1f''--workspace'$'\x1f'"$RECORDED_WS" \
    "the replacement tab must be created in the task's own recorded workspace"
  assert_contains "$(cat "$dir/home/state/rl-p1.meta")" "herdr_workspace_id=$RECORDED_WS" \
    "the replacement record must still name the workspace the task lives in"
  assert_not_contains "$(cat "$dir/home/state/rl-p1.meta")" "herdr_pane_id=$DEAD_PANE" \
    "the replacement record must point at the new pane, not the destroyed one"
  pass "fm-spawn --relaunch: recovers a task whose pane was destroyed, placing the replacement back in its own workspace"
}

# --- 7. and still refuses when there is nothing to recover to ----------------

test_spawn_relaunch_refuses_when_there_is_nothing_to_recover_to() {
  local dir out rc
  dir=$(make_spawn_case spawn-refuses no)
  out=$(run_spawn_relaunch "$dir"); rc=$?
  expect_code 1 "$rc" "a relaunch with no live recorded workspace must refuse, not place the worker elsewhere"
  assert_contains "$out" "refusing to place a worker" "the refusal must survive all the way to the caller"
  assert_not_contains "$(cat "$dir/log")" $'\x1f''tab'$'\x1f''create' \
    "a refused placement must never create the task's tab anywhere"
  pass "fm-spawn --relaunch: still refuses a destroyed pane whose recorded workspace is gone too"
}

# --- 8. the replacement comes up in the worktree the task already has --------
#
# Placement into the right WORKSPACE (above) still left the replacement pane
# starting wherever a fresh spawn starts: the project directory. A fresh spawn
# recovers from that by running `treehouse get`, which acquires a worktree and
# moves the shell into it. A relaunch must not do that - a second copy for one
# task is the hazard the worktree assertion exists to prevent - and nothing else
# moved the pane, so the assertion refused every replacement it created.
#
# The replacement is created directly in the recorded worktree instead. That
# also matters beyond recovery: `projects/` entries are commonly symlinks into
# real working checkouts, so a replacement that starts in the project starts in
# the captain's own checkout.
test_spawn_relaunch_starts_the_replacement_in_the_recorded_worktree() {
  local dir out rc wt
  dir=$(make_spawn_case spawn-enters-worktree yes)
  wt="$dir/wt"
  out=$(run_spawn_relaunch "$dir"); rc=$?
  expect_code 0 "$rc" "a replacement created in the recorded worktree must satisfy the worktree assertion"
  assert_not_contains "$out" "refusing to relaunch an agent outside" \
    "the worktree assertion must have nothing left to refuse"
  assert_contains "$(cat "$dir/log")" $'\x1f''--cwd'$'\x1f'"$wt" \
    "the replacement endpoint must be created in the task's own recorded worktree"
  assert_not_contains "$(cat "$dir/log")" $'\x1f''--cwd'$'\x1f'"$dir/proj" \
    "no endpoint for this task may be created in the project directory"
  assert_contains "$(cat "$dir/created-cwd")" "$wt" \
    "the replacement pane must actually report the recorded worktree as its cwd"
  assert_not_contains "$out" "treehouse get" \
    "a relaunch must enter the recorded worktree, never acquire another one"
  assert_contains "$(cat "$dir/home/state/rl-p1.meta")" "worktree=$wt" \
    "the replacement must still be recorded against the one worktree holding its work"
  pass "fm-spawn --relaunch: starts the replacement inside the task's recorded worktree"
}

# --- 9. and the assertion still refuses a replacement placed elsewhere -------
#
# The fix makes the assertion's precondition true; it must not make the
# assertion vacuous. A backend that accepts the request and puts the pane
# somewhere else anyway still has to be refused, because the alternative is an
# agent running in a directory that is not the one holding its work.
test_spawn_relaunch_refuses_a_replacement_placed_outside_the_worktree() {
  local dir out rc
  dir=$(make_spawn_case spawn-misplaced yes no)
  out=$(run_spawn_relaunch "$dir"); rc=$?
  expect_code 1 "$rc" "a replacement that did not land in the recorded worktree must refuse"
  assert_contains "$out" "refusing to relaunch an agent outside the copy holding its work" \
    "the refusal must name what it is protecting"
  assert_contains "$out" "$dir/wt" "the refusal must name the recorded worktree it expected"
  pass "fm-spawn --relaunch: still refuses when the replacement did not land in the recorded worktree"
}

test_relaunch_recovers_the_recorded_workspace
test_relaunch_refuses_a_pane_that_is_only_unreadable
test_relaunch_refuses_when_the_recorded_workspace_is_gone
test_relaunch_refuses_a_recorded_workspace_from_another_session
test_a_fresh_spawn_still_refuses_a_dead_launcher_pane
test_spawn_relaunch_recovers_a_destroyed_pane
test_spawn_relaunch_refuses_when_there_is_nothing_to_recover_to
test_spawn_relaunch_starts_the_replacement_in_the_recorded_worktree
test_spawn_relaunch_refuses_a_replacement_placed_outside_the_worktree

echo "all tests passed"
