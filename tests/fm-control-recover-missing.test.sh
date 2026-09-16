#!/usr/bin/env bash
# fm-control.sh recover-missing: the transactional recreate-the-terminal verb.
#
# The verb exists for a task whose recorded terminal is GONE rather than dead:
# `relaunch` refuses a missing endpoint and fm-spawn --relaunch adopts only a
# surviving agent-free one, so neither can bring such a task back. These tests
# drive the real script end to end against a stubbed session provider (no real
# agent), pinning:
#   1. The success path: a missing endpoint is recreated under the recorded
#      handle, the launch is handed to the existing owner, and the task keeps
#      its endpoint, worktree, and instructions - now carrying the note.
#   2. Every refusal the operation promises, each of which must leave the
#      durable record and the instructions byte-identical: a live or ambiguous
#      endpoint, an absent or dirty local copy, and a pool slot claimed by
#      another task or carrying an unreadable claim.
#   3. The runtime is not switchable here: --harness/--model/--effort and
#      --account-slot belong to `relaunch`, and recovery continues the recorded
#      profile - including the subscription account the record names, so a
#      rescue never quietly falls back to the ambient one.
#   4. The backends recovery refuses, and what it tells the operator when the
#      launch handoff fails after the terminal is already back.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-control-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-trace-context-lib.sh"

CONTROL="$ROOT/bin/fm-control.sh"

TMP_ROOT=$(fm_test_tmproot fm-control-recover-missing)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
TASK_TMPS=()

recover_cleanup() {
  local d
  for d in "${TASK_TMPS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
  rm -rf "$TMP_ROOT"
}
trap recover_cleanup EXIT

# The same lifecycle-modelling tmux stub the relaunch suite uses, plus a real
# new-window: the window inventory in $D/windows is what decides missing vs
# present, and creating the window puts the recorded name back and leaves a
# bare shell in it (agent-free), which is exactly the state fm-spawn --relaunch
# requires before it adopts the endpoint.
make_tmux_stub() {  # <dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    payload=${1:-}
    if [ "$literal" = 1 ]; then
      printf '%s\n' "$payload" >> "$D/literal"
      case "$payload" in
        *'encode launch-brief'*) cat "$D/becomes" > "$D/command" ;;
      esac
    else
      printf '%s\n' "$payload" >> "$D/keys"
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *cursor_y*) printf '1\n'; exit 0 ;;
        *pane_current_command*)
          # A just-created pane is still running its login shell's rc files,
          # and each command they start owns the pane tty's foreground process
          # group for a moment. $D/busy-reads is how many reads report one of
          # those (classified `other`, so the endpoint reads `ambiguous`)
          # before the shell reaches its prompt.
          busy=$(cat "$D/busy-reads" 2>/dev/null || printf '0')
          if [ "${busy:-0}" -gt 0 ] 2>/dev/null; then
            printf '%s\n' "$((busy - 1))" > "$D/busy-reads"
            printf 'node\n'
            exit 0
          fi
          cat "$D/command"; printf '\n'; exit 0 ;;
        *pane_current_path*) cat "$D/cwd"; printf '\n'; exit 0 ;;
      esac
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane)
    printf '╭────╮\n│    │\n╰────╯\n'
    exit 0 ;;
  new-window)
    [ -z "${FM_FAKE_NEW_WINDOW_FAIL:-}" ] || { echo "can't create window" >&2; exit 1; }
    name=
    while [ $# -gt 0 ]; do
      case "$1" in
        -n) name=${2:-}; shift 2 ;;
        *) shift ;;
      esac
    done
    printf '%s\n' "$name" >> "$D/windows"
    printf '%s\n' "$name" >> "$D/created-windows"
    # A freshly created window holds a bare shell: agent-free, not missing.
    printf 'zsh' > "$D/command"
    printf '%s\n' "${FM_FAKE_SHELL_BUSY_READS:-0}" > "$D/busy-reads"
    printf '@999\n'
    exit 0 ;;
  set-window-option) exit 0 ;;
  has-session)
    shift
    ses=
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) ses=${2:-}; shift 2 ;;
        *) shift ;;
      esac
    done
    # Real tmux treats a leading '=' as "match this name exactly".
    ses=${ses#=}
    grep -qxF "$ses" "$D/sessions" 2>/dev/null && exit 0
    echo "can't find session: $ses" >&2
    exit 1 ;;
  new-session)
    [ -z "${FM_FAKE_NEW_SESSION_FAIL:-}" ] || { echo "create session failed" >&2; exit 1; }
    shift
    ses=
    while [ $# -gt 0 ]; do
      case "$1" in
        -s) ses=${2:-}; shift 2 ;;
        -c) shift 2 ;;
        *) shift ;;
      esac
    done
    printf '%s\n' "$ses" >> "$D/sessions"
    printf '%s\n' "$ses" >> "$D/created-sessions"
    exit 0 ;;
  list-windows)
    shift
    ses=
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) ses=${2:-}; shift 2 ;;
        *) shift ;;
      esac
    done
    ses=${ses#=}
    if ! grep -qxF "$ses" "$D/sessions" 2>/dev/null; then
      # Exactly what real tmux writes when the whole session is gone; the
      # recovery-grade classifier reads this as `missing`.
      echo "can't find session: $ses" >&2
      exit 1
    fi
    [ -f "$D/windows" ] && cat "$D/windows"
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
}

# new_case <name> [id] -> echoes a case dir whose endpoint currently holds a
# live claude agent. A test that wants the MISSING precondition calls
# make_endpoint_missing.
new_case() {
  local id=${2:-t1} dir="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/fake"
  : > "$dir/fake/literal"
  : > "$dir/fake/keys"
  : > "$dir/fake/created-windows"
  printf 'claude' > "$dir/fake/command"
  printf 'claude' > "$dir/fake/becomes"
  printf '%s\n' "fm-$id" > "$dir/fake/windows"
  printf 'fmses\n' > "$dir/fake/sessions"
  : > "$dir/fake/created-sessions"
  make_tmux_stub "$dir"
  printf '%s\n' "$dir"
}

# add_ship_task <case-dir> <id> [worktree]: a claude ship task recorded on the
# tmux endpoint fmses:fm-<id>. The worktree defaults to <case-dir>/wt; a pool
# case passes its slot checkout instead.
add_ship_task() {
  local dir=$1 id=$2 wt=${3:-$1/wt}
  local home="$dir/home" proj="$dir/proj"
  fm_git_worktree "$proj" "$wt" "task-$id"
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise missing-endpoint recovery for $id.

## Firstmate spec
Recreate the terminal without touching the local copy.
EOF
  {
    echo "window=fmses:fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$wt"
    echo "project=$proj"
    echo "harness=claude"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "tasktmp=/tmp/fm-$id"
    echo "model=default"
    echo "effort=default"
  } > "$home/state/$id.meta"
  printf '%s' "$wt" > "$dir/fake/cwd"
  TASK_TMPS+=("/tmp/fm-$id")
}

# Drop the recorded window out of the session inventory: tmux's recovery-grade
# classifier reports `missing` for a window the session does not list.
make_endpoint_missing() {  # <case-dir>
  rm -f "$1/fake/windows"
  : > "$1/fake/windows"
}

# Drop the whole SESSION out of the server inventory: the recorded window is
# gone with it, and tmux answers the classifier's window listing with "can't
# find session", which is the second shape that reads `missing`. This is the
# shape a task records as window=<session>:fm-<id> when that session no longer
# exists on the machine at all.
make_session_missing() {  # <case-dir>
  : > "$1/fake/sessions"
  : > "$1/fake/windows"
}

# A Treehouse pool slot, shaped the way fm_treehouse_pool_slot recognizes one:
# <pool>/treehouse-state.json beside <pool>/<slot>/<checkout>, with the slot's
# Firstmate ownership claim at <pool>/<slot>/.fm-slot-owner.
pool_slot_worktree() {  # <case-dir>
  local pool="$1/pool"
  mkdir -p "$pool/1"
  printf '{}\n' > "$pool/treehouse-state.json"
  printf '%s\n' "$pool/1/checkout"
}

# A home whose account-slot registry binds one claude slot to a local
# credential store. fm_account_slot_resolve reads the registry and the store
# alone - no quota evidence is consulted for an explicitly recorded slot - so
# this fixture stays to the local binding the rescue actually re-resolves.
configure_recover_slots() { # <case-dir>
  local home="$1/home" claude_store="$1/claude-profile"
  mkdir -p "$home/config" "$claude_store"
  chmod 700 "$home/config" "$claude_store"
  printf '{}\n' > "$claude_store/.credentials.json"
  chmod 600 "$claude_store/.credentials.json"
  cat > "$home/config/account-slots.json" <<JSON
{"version":1,"slots":{
  "claude-a":{"harness":"claude","storePath":"$claude_store","expectedAccountId":"test-account"}
}}
JSON
  chmod 600 "$home/config/account-slots.json"
}

run_control() {  # <case-dir> <args...>
  local dir=$1; shift
  # A claude spawn pre-registers workspace trust in the launching user's own
  # store (bin/fm-claude-trust.sh), and recovery reaches it through
  # fm-spawn.sh; without a throwaway HOME this suite would write the
  # developer's real ~/.claude.json.
  mkdir -p "$dir/user-home"
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    HOME="$dir/user-home" CLAUDE_CONFIG_DIR='' \
    FM_SPAWN_NO_GUARD=1 GROK_HOME="$dir/grokhome" \
    FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT="${FM_CONTROL_EXIT_WAIT:-0.05}" \
    FM_CONTROL_LAUNCH_WAIT=0.05 \
    FM_FAKE_NEW_WINDOW_FAIL="${FM_FAKE_NEW_WINDOW_FAIL:-}" \
    FM_FAKE_NEW_SESSION_FAIL="${FM_FAKE_NEW_SESSION_FAIL:-}" \
    FM_FAKE_SHELL_BUSY_READS="${FM_FAKE_SHELL_BUSY_READS:-0}" \
    "$CONTROL" "$@" 2>&1
}

meta_field() {  # <case-dir> <id> <key>
  grep "^$3=" "$1/home/state/$2.meta" | tail -1 | cut -d= -f2-
}

journal_field() {  # <case-dir> <id> <key>
  grep "^$3=" "$1/home/state/$2.control-relaunch" | tail -1 | cut -d= -f2-
}

# --- 1. the missing-terminal success path -----------------------------------

test_recover_missing_recreates_the_terminal_and_launches_the_replacement() {
  local dir out rc brief_before
  dir=$(new_case success rm1)
  add_ship_task "$dir" rm1
  brief_before=$(cat "$dir/home/data/rm1/brief.md")
  make_endpoint_missing "$dir"

  out=$(run_control "$dir" rm1 recover-missing --note "the terminal was closed out from under it"); rc=$?
  expect_code 0 "$rc" "recovering a missing endpoint should succeed"$'\n'"$out"
  assert_contains "$out" "recovered rm1 harness=claude from=claude" "the outcome should name the recovered task and its runtime"
  assert_contains "$out" "endpoint=fmses:fm-rm1" "the outcome should name the recreated endpoint"

  assert_grep "fm-rm1" "$dir/fake/created-windows" "the missing terminal should have been recreated under its recorded name"
  assert_grep "encode launch-brief" "$dir/fake/literal" "the launch should have been handed to the existing owner"

  [ "$(meta_field "$dir" rm1 window)" = "fmses:fm-rm1" ] \
    || fail "the recreated endpoint must keep the recorded handle"
  [ "$(meta_field "$dir" rm1 worktree)" = "$dir/wt" ] \
    || fail "the local copy must be reused, never reallocated"
  [ "$(meta_field "$dir" rm1 harness)" = claude ] || fail "the recorded harness must survive recovery"
  [ "$(meta_field "$dir" rm1 kind)" = ship ] || fail "kind must survive recovery"
  [ "$(journal_field "$dir" rm1 phase)" = complete ] \
    || fail "the transaction journal should end complete"
  assert_grep "the terminal was closed out from under it" "$dir/home/data/rm1/brief.md" \
    "the progress note must land in the instructions the replacement reads"
  case "$(cat "$dir/home/data/rm1/brief.md")" in
    "$brief_before"*) : ;;
    *) fail "recovery must append to the original instructions, never rewrite them" ;;
  esac
  pass "fm-control recover-missing: a missing terminal is recreated under its recorded handle and relaunched"
}

test_recover_missing_waits_for_the_recreated_shell_to_settle() {
  local dir out rc
  dir=$(new_case cold-start rm21)
  add_ship_task "$dir" rm21
  make_endpoint_missing "$dir"

  # A cold rescue on a real machine: the recreated pane's login shell is still
  # running its rc files, so the endpoint reads `ambiguous` for a while. The
  # launch owner takes ONE un-retried state read and requires `dead`, so
  # handing the terminal over before it settles fails the whole rescue.
  out=$(FM_FAKE_SHELL_BUSY_READS=4 FM_CONTROL_EXIT_WAIT=5 \
    run_control "$dir" rm21 recover-missing --note "the terminal was closed out from under it"); rc=$?
  expect_code 0 "$rc" "a still-starting shell must not fail the rescue"$'\n'"$out"
  assert_contains "$out" "recovered rm21 harness=claude" "the rescue should complete in one command"
  assert_grep "encode launch-brief" "$dir/fake/literal" \
    "the launch should have been handed over only once the terminal read agent-free"
  [ "$(journal_field "$dir" rm21 phase)" = complete ] \
    || fail "the transaction journal should end complete"
  pass "fm-control recover-missing: a recreated terminal whose shell is still starting is waited out, not handed over"
}

test_recover_missing_refuses_a_terminal_that_never_settles() {
  local dir out rc
  dir=$(new_case never-settles rm22)
  add_ship_task "$dir" rm22
  make_endpoint_missing "$dir"

  # The recreated pane never reaches an agent-free shell within the budget.
  out=$(FM_FAKE_SHELL_BUSY_READS=100000 run_control "$dir" rm22 recover-missing --note "recover"); rc=$?
  expect_code 1 "$rc" "a terminal that never settles must refuse"$'\n'"$out"
  assert_contains "$out" "did not settle to an agent-free shell" \
    "the refusal should name what it waited for"
  ! grep -Fq "encode launch-brief" "$dir/fake/literal" \
    || fail "an unsettled terminal must never be handed to the launch owner"
  pass "fm-control recover-missing: a recreated terminal that never goes agent-free refuses instead of launching into it"
}

# --- 2. refusals ------------------------------------------------------------

# assert_nothing_changed <case-dir> <id> <meta-before> <brief-before>
assert_nothing_changed() {
  local dir=$1 id=$2 meta_before=$3 brief_before=$4
  [ "$(cat "$dir/home/state/$id.meta")" = "$meta_before" ] \
    || fail "a refused recovery must leave the durable record byte-identical"
  [ "$(cat "$dir/home/data/$id/brief.md")" = "$brief_before" ] \
    || fail "a refused recovery must leave the instructions byte-identical"
  [ ! -s "$dir/fake/created-windows" ] \
    || fail "a refused recovery must not create a terminal"
  ! grep -Fq "encode launch-brief" "$dir/fake/literal" \
    || fail "a refused recovery must not launch an agent"
}

test_recover_missing_refuses_a_live_endpoint() {
  local dir out rc meta_before brief_before
  dir=$(new_case alive rm2)
  add_ship_task "$dir" rm2
  meta_before=$(cat "$dir/home/state/rm2.meta")
  brief_before=$(cat "$dir/home/data/rm2/brief.md")

  out=$(run_control "$dir" rm2 recover-missing --note "recover"); rc=$?
  expect_code 1 "$rc" "a live endpoint must refuse"$'\n'"$out"
  assert_contains "$out" "endpoint reads 'alive'" "the refusal should name the observed state"
  assert_nothing_changed "$dir" rm2 "$meta_before" "$brief_before"
  pass "fm-control recover-missing: a live endpoint refuses and changes nothing"
}

test_recover_missing_refuses_an_ambiguous_endpoint() {
  local dir out rc meta_before brief_before
  dir=$(new_case ambiguous rm3)
  add_ship_task "$dir" rm3
  # A foreground process that is neither a known agent nor a shell: the
  # classifier can prove neither presence nor absence of an agent.
  printf 'mystery' > "$dir/fake/command"
  meta_before=$(cat "$dir/home/state/rm3.meta")
  brief_before=$(cat "$dir/home/data/rm3/brief.md")

  out=$(run_control "$dir" rm3 recover-missing --note "recover"); rc=$?
  expect_code 1 "$rc" "an ambiguous endpoint must refuse"$'\n'"$out"
  assert_contains "$out" "endpoint reads 'ambiguous'" "the refusal should name the observed state"
  assert_nothing_changed "$dir" rm3 "$meta_before" "$brief_before"
  pass "fm-control recover-missing: an ambiguous endpoint refuses and changes nothing"
}

test_recover_missing_refuses_an_absent_local_copy() {
  local dir out rc meta_before brief_before
  dir=$(new_case absent-wt rm4)
  add_ship_task "$dir" rm4
  make_endpoint_missing "$dir"
  meta_before=$(cat "$dir/home/state/rm4.meta")
  brief_before=$(cat "$dir/home/data/rm4/brief.md")
  rm -rf "$dir/wt"

  out=$(run_control "$dir" rm4 recover-missing --note "recover"); rc=$?
  expect_code 1 "$rc" "an absent local copy must refuse"$'\n'"$out"
  assert_contains "$out" "is absent; refusing to recover without the local copy" \
    "the refusal should name the missing local copy"
  assert_nothing_changed "$dir" rm4 "$meta_before" "$brief_before"
  pass "fm-control recover-missing: an unavailable local copy refuses rather than reallocating one"
}

test_recover_missing_refuses_a_dirty_local_copy() {
  local dir out rc meta_before brief_before
  dir=$(new_case dirty rm5)
  add_ship_task "$dir" rm5
  make_endpoint_missing "$dir"
  meta_before=$(cat "$dir/home/state/rm5.meta")
  brief_before=$(cat "$dir/home/data/rm5/brief.md")
  : > "$dir/wt/dirty.txt"
  git -C "$dir/wt" add dirty.txt

  out=$(run_control "$dir" rm5 recover-missing --note "recover"); rc=$?
  expect_code 1 "$rc" "a dirty local copy must refuse"$'\n'"$out"
  assert_contains "$out" "uncommitted changes; refusing to recover rather than cleaning it" \
    "the refusal should say it will not clean the copy"
  assert_nothing_changed "$dir" rm5 "$meta_before" "$brief_before"
  pass "fm-control recover-missing: a dirty local copy refuses rather than resetting it"
}

test_recover_missing_refuses_a_pool_slot_owned_by_another_task() {
  local dir wt out rc meta_before brief_before
  dir=$(new_case slot-other rm6)
  wt=$(pool_slot_worktree "$dir")
  add_ship_task "$dir" rm6 "$wt"
  make_endpoint_missing "$dir"
  printf 'task=%s\nhome=%s\n' other-task "$dir/home" > "$(dirname "$wt")/.fm-slot-owner"
  meta_before=$(cat "$dir/home/state/rm6.meta")
  brief_before=$(cat "$dir/home/data/rm6/brief.md")

  out=$(run_control "$dir" rm6 recover-missing --note "recover"); rc=$?
  expect_code 1 "$rc" "a reassigned pool slot must refuse"$'\n'"$out"
  assert_contains "$out" "claimed by task other-task" "the refusal should name the claiming task"
  assert_nothing_changed "$dir" rm6 "$meta_before" "$brief_before"
  pass "fm-control recover-missing: a pool slot claimed by another task refuses rather than tangling ownership"
}

test_recover_missing_refuses_an_unreadable_pool_slot_claim() {
  local dir wt out rc meta_before brief_before
  dir=$(new_case slot-unsafe rm7)
  wt=$(pool_slot_worktree "$dir")
  add_ship_task "$dir" rm7 "$wt"
  make_endpoint_missing "$dir"
  # A claim that exists but names no task at all: unreadable, not absent.
  printf 'home=%s\n' "$dir/home" > "$(dirname "$wt")/.fm-slot-owner"
  meta_before=$(cat "$dir/home/state/rm7.meta")
  brief_before=$(cat "$dir/home/data/rm7/brief.md")

  out=$(run_control "$dir" rm7 recover-missing --note "recover"); rc=$?
  expect_code 1 "$rc" "an unreadable pool-slot claim must refuse"$'\n'"$out"
  assert_contains "$out" "unreadable owner claim" "the refusal should name the unreadable claim"
  assert_nothing_changed "$dir" rm7 "$meta_before" "$brief_before"
  pass "fm-control recover-missing: an unreadable pool-slot claim refuses rather than risking a conflict"
}

test_recover_missing_keeps_its_own_pool_slot() {
  local dir wt out rc
  dir=$(new_case slot-mine rm8)
  wt=$(pool_slot_worktree "$dir")
  add_ship_task "$dir" rm8 "$wt"
  make_endpoint_missing "$dir"
  printf 'task=%s\nhome=%s\n' rm8 "$dir/home" > "$(dirname "$wt")/.fm-slot-owner"

  out=$(run_control "$dir" rm8 recover-missing --note "recover"); rc=$?
  expect_code 0 "$rc" "a task's own pool slot should recover"$'\n'"$out"
  [ "$(meta_field "$dir" rm8 worktree)" = "$wt" ] \
    || fail "the recovered task must keep its own pool slot"
  [ "$(cat "$(dirname "$wt")/.fm-slot-owner")" = "$(printf 'task=rm8\nhome=%s' "$dir/home")" ] \
    || fail "recovery must leave the slot's own ownership claim untouched"
  pass "fm-control recover-missing: a task's own pool slot recovers with its claim untouched"
}

test_failed_recreation_rolls_the_progress_note_back() {
  local dir out rc meta_before brief_before
  dir=$(new_case recreate-fail rm11)
  add_ship_task "$dir" rm11
  make_endpoint_missing "$dir"
  meta_before=$(cat "$dir/home/state/rm11.meta")
  brief_before=$(cat "$dir/home/data/rm11/brief.md")

  # The note is appended to the instructions BEFORE the terminal is recreated,
  # and the agent is never touched in any phase of a recovery, so a recreation
  # that fails must put the instructions back. Otherwise every retry after the
  # operator fixes the session provider stacks another progress note.
  out=$(FM_FAKE_NEW_WINDOW_FAIL=1 run_control "$dir" rm11 recover-missing --note "first attempt"); rc=$?
  expect_code 1 "$rc" "a failed recreation must refuse"$'\n'"$out"
  assert_contains "$out" "failed while recreating the terminal" "the refusal should name the phase it failed in"
  [ "$(cat "$dir/home/data/rm11/brief.md")" = "$brief_before" ] \
    || fail "a failed recreation must roll the progress note back out of the instructions"
  [ "$(cat "$dir/home/state/rm11.meta")" = "$meta_before" ] \
    || fail "a failed recreation must restore the prior durable record"

  out=$(run_control "$dir" rm11 recover-missing --note "second attempt"); rc=$?
  expect_code 0 "$rc" "the retry after the provider recovers should succeed"$'\n'"$out"
  [ "$(grep -c '^## Progress note' "$dir/home/data/rm11/brief.md")" = 1 ] \
    || fail "a retry must leave exactly one progress note in the instructions"
  assert_no_grep "first attempt" "$dir/home/data/rm11/brief.md" \
    "the rolled-back attempt's note must not survive into the retry"
  pass "fm-control recover-missing: a failed recreation rolls the progress note back so retries do not stack"
}

test_launch_failure_never_claims_an_agent_was_stopped() {
  local dir out rc before
  dir=$(new_case launch-fail rm12)
  add_ship_task "$dir" rm12
  make_endpoint_missing "$dir"
  before=$(cat "$dir/home/state/rm12.meta")
  # The recreated shell reports a cwd outside the recorded local copy, so the
  # launch owner refuses AFTER the terminal has already been recreated.
  printf '%s' "$dir/proj" > "$dir/fake/cwd"

  out=$(run_control "$dir" rm12 recover-missing --note "carry this forward"); rc=$?
  expect_code 1 "$rc" "a failed launch handoff should fail closed"$'\n'"$out"
  assert_grep "fm-rm12" "$dir/fake/created-windows" "the terminal should already have been recreated"
  assert_contains "$out" "no agent was ever stopped" \
    "the failure must not claim a recovery stopped an agent it never touched"
  assert_contains "$out" "retry with 'relaunch'" \
    "the failure should name the verb that acts on the bare shell it left behind"
  assert_contains "$out" "$dir/wt" "the failure should say where the work is preserved"
  [ "$(cat "$dir/home/state/rm12.meta")" = "$before" ] \
    || fail "a failed launch handoff must keep the prior durable record"
  [ "$(journal_field "$dir" rm12 phase)" = "failed:launching" ] \
    || fail "the journal should record the failed phase"
  assert_grep "carry this forward" "$dir/home/data/rm12/brief.md" \
    "the progress note must survive a post-recreation failure so the retry still has it"
  pass "fm-control recover-missing: a failed launch handoff reports the bare shell it left, not a stop that never happened"
}

test_recover_missing_refuses_a_backend_it_cannot_recreate_on() {
  local dir out rc meta_before brief_before
  dir=$(new_case herdr-backend rm13)
  add_ship_task "$dir" rm13
  # A herdr record: its classifier is recovery-grade, so the refusal has to come
  # from the recreation side rather than from the agent-state gate.
  {
    echo "backend=herdr"
    echo "herdr_session=hses"
    echo "herdr_workspace_id=ws1"
    echo "herdr_tab_id=t1"
    echo "herdr_pane_id=p1"
  } >> "$dir/home/state/rm13.meta"
  sed -i.bak 's|^window=.*|window=hses:p1|' "$dir/home/state/rm13.meta"
  rm -f "$dir/home/state/rm13.meta.bak"
  meta_before=$(cat "$dir/home/state/rm13.meta")
  brief_before=$(cat "$dir/home/data/rm13/brief.md")

  out=$(run_control "$dir" rm13 recover-missing --note "recover"); rc=$?
  expect_code 1 "$rc" "a backend with no recreation support must refuse"$'\n'"$out"
  assert_contains "$out" "no supported way to recreate an endpoint with the recorded identity" \
    "the refusal should name what the backend cannot do"
  assert_nothing_changed "$dir" rm13 "$meta_before" "$brief_before"
  pass "fm-control recover-missing: a backend that cannot recreate the recorded endpoint refuses before anything changes"
}

test_recover_missing_refusal_names_the_postcondition_it_cannot_prove() {
  local dir out rc meta_before brief_before
  dir=$(new_case no-classifier rm14)
  add_ship_task "$dir" rm14
  {
    echo "backend=zellij"
    echo "zellij_session=zses"
    echo "zellij_tab_id=1"
    echo "zellij_pane_id=7"
  } >> "$dir/home/state/rm14.meta"
  sed -i.bak 's|^window=.*|window=zses:7|' "$dir/home/state/rm14.meta"
  rm -f "$dir/home/state/rm14.meta.bak"
  meta_before=$(cat "$dir/home/state/rm14.meta")
  brief_before=$(cat "$dir/home/data/rm14/brief.md")

  out=$(run_control "$dir" rm14 recover-missing --note "recover"); rc=$?
  expect_code 1 "$rc" "a backend with no recovery-grade classifier must refuse"$'\n'"$out"
  assert_contains "$out" "no recovery-grade agent-state classifier" "the refusal should name the missing capability"
  assert_contains "$out" "cannot prove the endpoint is actually missing" \
    "recovery never stops an agent, so the refusal must name the postcondition it really cannot prove"
  assert_nothing_changed "$dir" rm14 "$meta_before" "$brief_before"
  pass "fm-control recover-missing: an unclassifiable backend refuses on the postcondition recovery actually needs"
}

test_recover_missing_refuses_a_basename_harness_without_naming_a_rejected_flag() {
  local dir out rc meta_before brief_before
  dir=$(new_case basename-harness rm15)
  add_ship_task "$dir" rm15
  make_endpoint_missing "$dir"
  # A task launched from a raw command records that command's basename, whose
  # launch line cannot be reconstructed from the canonical adapter name.
  sed -i.bak 's|^harness=.*|harness=grok-2|' "$dir/home/state/rm15.meta"
  rm -f "$dir/home/state/rm15.meta.bak"
  meta_before=$(cat "$dir/home/state/rm15.meta")
  brief_before=$(cat "$dir/home/data/rm15/brief.md")

  out=$(run_control "$dir" rm15 recover-missing --note "recover"); rc=$?
  expect_code 1 "$rc" "an unreconstructable recorded harness must refuse"$'\n'"$out"
  assert_contains "$out" "cannot be reconstructed from its recorded basename" \
    "the refusal should name why the recorded runtime cannot be continued"
  case "$out" in
    *"Pass an explicit --harness"*)
      fail "recovery rejects --harness, so its refusal must not tell the operator to pass one" ;;
  esac
  assert_nothing_changed "$dir" rm15 "$meta_before" "$brief_before"
  pass "fm-control recover-missing: an unreconstructable recorded harness refuses without naming a flag the verb rejects"
}

# --- 3. the runtime is not switchable here ----------------------------------

test_recover_missing_rejects_runtime_switch_flags() {
  local dir out rc flag
  dir=$(new_case profile rm9)
  add_ship_task "$dir" rm9
  make_endpoint_missing "$dir"

  for flag in "--harness codex" "--model opus" "--effort high" "--account-slot claude-a"; do
    # shellcheck disable=SC2086 # the flag pair is deliberately split.
    out=$(run_control "$dir" rm9 recover-missing --note "recover" $flag); rc=$?
    expect_code 1 "$rc" "recover-missing must reject '$flag'"$'\n'"$out"
    assert_contains "$out" "apply to 'relaunch' only" "the refusal should point at the relaunch verb"
  done
  [ ! -s "$dir/fake/created-windows" ] || fail "a rejected flag must not create a terminal"
  pass "fm-control recover-missing: runtime-switch flags belong to relaunch and are refused here"
}

test_recover_missing_requires_a_note_for_a_ship_task() {
  local dir out rc
  dir=$(new_case no-note rm10)
  add_ship_task "$dir" rm10
  make_endpoint_missing "$dir"

  out=$(run_control "$dir" rm10 recover-missing); rc=$?
  expect_code 1 "$rc" "a ship recovery without a note must refuse"$'\n'"$out"
  assert_contains "$out" "requires --note" "the refusal should name the missing note"
  [ ! -s "$dir/fake/created-windows" ] || fail "a refused recovery must not create a terminal"
  pass "fm-control recover-missing: a ship task's recovery requires the progress note"
}

# --- 4. the second missing shape: the whole session is gone -----------------

test_recover_missing_recreates_a_gone_session_before_the_window() {
  local dir out rc
  dir=$(new_case gone-session rm16)
  add_ship_task "$dir" rm16
  make_session_missing "$dir"

  out=$(run_control "$dir" rm16 recover-missing --note "the whole session went away"); rc=$?
  expect_code 0 "$rc" "a task whose whole session is gone should recover"$'\n'"$out"
  assert_contains "$out" "recovered rm16 harness=claude from=claude" \
    "the outcome should name the recovered task and its runtime"
  assert_contains "$out" "endpoint=fmses:fm-rm16" \
    "the recreated endpoint must keep the recorded handle, session included"

  assert_grep "fmses" "$dir/fake/created-sessions" \
    "the gone session must be recreated under its exact recorded name"
  assert_grep "fm-rm16" "$dir/fake/created-windows" \
    "the task window must then be recreated inside it"
  assert_grep "encode launch-brief" "$dir/fake/literal" \
    "the launch should still be handed to the existing owner"

  [ "$(meta_field "$dir" rm16 window)" = "fmses:fm-rm16" ] \
    || fail "recreating the session must not rewrite the recorded endpoint"
  [ "$(meta_field "$dir" rm16 worktree)" = "$dir/wt" ] \
    || fail "the local copy must be reused, never reallocated"
  [ "$(journal_field "$dir" rm16 phase)" = complete ] \
    || fail "the transaction journal should end complete"
  pass "fm-control recover-missing: a whole gone session is recreated under its recorded name, then the task window"
}

test_recover_missing_does_not_recreate_a_session_that_is_still_alive() {
  local dir out rc
  dir=$(new_case live-session rm17)
  add_ship_task "$dir" rm17
  # Only the WINDOW is gone here; the session is still listed.
  make_endpoint_missing "$dir"

  out=$(run_control "$dir" rm17 recover-missing --note "only the window went away"); rc=$?
  expect_code 0 "$rc" "a missing window in a live session should recover"$'\n'"$out"
  [ ! -s "$dir/fake/created-sessions" ] \
    || fail "a session that still exists must be left exactly as it is, not recreated"
  assert_grep "fm-rm17" "$dir/fake/created-windows" \
    "the task window must still be recreated"
  pass "fm-control recover-missing: a surviving session is left untouched and only the window comes back"
}

test_recover_missing_refuses_when_the_session_cannot_be_recreated() {
  local dir out rc meta_before brief_before
  dir=$(new_case session-fail rm18)
  add_ship_task "$dir" rm18
  make_session_missing "$dir"
  meta_before=$(cat "$dir/home/state/rm18.meta")
  brief_before=$(cat "$dir/home/data/rm18/brief.md")

  out=$(FM_FAKE_NEW_SESSION_FAIL=1 run_control "$dir" rm18 recover-missing --note "recover"); rc=$?
  expect_code 1 "$rc" "an unrecreatable session must refuse"$'\n'"$out"
  assert_contains "$out" "recorded tmux session 'fmses' is gone and could not be recreated" \
    "the refusal should name the session it could not bring back"
  [ ! -s "$dir/fake/created-windows" ] \
    || fail "a refused session recreation must not go on to create a window"
  [ "$(cat "$dir/home/state/rm18.meta")" = "$meta_before" ] \
    || fail "a refused recovery must leave the durable record byte-identical"
  [ "$(cat "$dir/home/data/rm18/brief.md")" = "$brief_before" ] \
    || fail "a refused recovery must roll the progress note back"
  ! grep -Fq "encode launch-brief" "$dir/fake/literal" \
    || fail "a refused recovery must not launch an agent"
  pass "fm-control recover-missing: a session that cannot be recreated refuses and leaves everything in place"
}

# --- 5. every identity axis comes from the task's own record ----------------

test_recover_missing_freezes_the_recorded_profile_for_a_secondmate() {
  local dir home out rc
  dir=$(new_case smfreeze sm9)
  home="$dir/home"
  mkdir -p "$home/config" "$home/data/sm9"
  # The durable pin names a DIFFERENT runtime than the record. A relaunch
  # re-resolves this pin on purpose; a recovery must not, because it continues
  # the same run in the same terminal.
  printf 'codex some-model high\n' > "$home/config/secondmate-harness"
  printf '# secondmate brief\n' > "$home/data/sm9/brief.md"
  fm_git_worktree "$dir/proj" "$dir/smhome" sm-branch
  mkdir -p "$dir/smhome/state" "$dir/smhome/data" "$dir/smhome/bin"
  printf 'sm9\n' > "$dir/smhome/.fm-secondmate-home"
  printf '# agents\n' > "$dir/smhome/AGENTS.md"
  # Recovery refuses a dirty local copy, so the secondmate home has to be a
  # committed checkout rather than the scratch tree a relaunch case can get
  # away with. The identity is inline because tests/git-config-helpers.sh takes
  # the host's global and system config away from every fixture: a bare commit
  # is then left with Git's own <user>@<hostname> guess, which a developer
  # machine supplies and a CI runner whose hostname carries no domain does not.
  # Without it the commit fails, the two staged files stay staged, and this case
  # fails on the dirty-copy refusal instead of exercising the profile freeze.
  git -C "$dir/smhome" add -A
  git -C "$dir/smhome" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit --quiet -m "secondmate home" \
    || fail "the secondmate home fixture could not be committed"
  {
    echo "window=fmses:fm-sm9"
    echo "endpoint_task_id=sm9"
    echo "worktree=$dir/smhome"
    echo "project=$dir/smhome"
    echo "harness=claude"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "model=opus"
    echo "effort=xhigh"
    echo "home=$dir/smhome"
  } > "$home/state/sm9.meta"
  printf '%s' "$dir/smhome" > "$dir/fake/cwd"
  make_endpoint_missing "$dir"

  out=$(run_control "$dir" sm9 recover-missing); rc=$?
  expect_code 0 "$rc" "a secondmate with a missing endpoint should recover"$'\n'"$out"
  assert_contains "$out" "harness=claude from=claude" \
    "recovery must continue the RECORDED harness, not the configured pin"
  assert_contains "$out" "model=opus effort=xhigh" \
    "recovery must continue the recorded model and effort, not reset them to the pin's"
  [ "$(journal_field "$dir" sm9 to_harness)" = claude ] \
    || fail "the journal should record the recorded harness, got '$(journal_field "$dir" sm9 to_harness)'"
  [ "$(journal_field "$dir" sm9 to_model)" = opus ] \
    || fail "the journal should record the recorded model, got '$(journal_field "$dir" sm9 to_model)'"
  [ "$(journal_field "$dir" sm9 to_effort)" = xhigh ] \
    || fail "the journal should record the recorded effort, got '$(journal_field "$dir" sm9 to_effort)'"
  pass "fm-control recover-missing: a secondmate's recorded harness, model and effort survive a differing configured pin"
}

# --- 6. which local-copy dirt actually blocks a rescue -----------------------

test_recover_missing_accepts_a_worktree_holding_only_spawn_leftovers() {
  local dir out rc
  dir=$(new_case spawn-dirt rm19)
  add_ship_task "$dir" rm19
  make_endpoint_missing "$dir"
  # What a previous incarnation's own spawn leaves behind. These are not the
  # task's work, and refusing them would block recovery for exactly the tasks
  # this verb exists to rescue.
  mkdir -p "$dir/wt/.claude"
  printf '{}\n' > "$dir/wt/.claude/settings.local.json"

  out=$(run_control "$dir" rm19 recover-missing --note "recover"); rc=$?
  expect_code 0 "$rc" "a worktree dirty only with spawn leftovers should recover"$'\n'"$out"
  assert_grep "fm-rm19" "$dir/fake/created-windows" "the terminal should have been recreated"
  pass "fm-control recover-missing: a worktree holding only the previous spawn's own leftovers still recovers"
}

test_recover_missing_refuses_an_untracked_source_file() {
  local dir out rc meta_before brief_before
  dir=$(new_case untracked-src rm20)
  add_ship_task "$dir" rm20
  make_endpoint_missing "$dir"
  meta_before=$(cat "$dir/home/state/rm20.meta")
  brief_before=$(cat "$dir/home/data/rm20/brief.md")
  # Untracked, but real unlanded work rather than a spawn leftover.
  printf 'work in progress\n' > "$dir/wt/new-source.sh"

  out=$(run_control "$dir" rm20 recover-missing --note "recover"); rc=$?
  expect_code 1 "$rc" "an untracked source file must refuse"$'\n'"$out"
  assert_contains "$out" "uncommitted changes; refusing to recover rather than cleaning it" \
    "the refusal should say it will not clean the copy"
  assert_nothing_changed "$dir" rm20 "$meta_before" "$brief_before"
  pass "fm-control recover-missing: untracked work that is not a spawn leftover still refuses"
}

test_recover_missing_preserves_the_recorded_account_slot() {
  local dir out rc
  dir=$(new_case account-slot rm20)
  add_ship_task "$dir" rm20
  configure_recover_slots "$dir"
  printf 'account_slot=claude-a\n' >> "$dir/home/state/rm20.meta"
  make_endpoint_missing "$dir"

  out=$(run_control "$dir" rm20 recover-missing --note "the terminal was closed out from under it"); rc=$?
  expect_code 0 "$rc" "recovering a slotted task should succeed"$'\n'"$out"
  assert_contains "$out" "account_slot=claude-a" "the outcome should name the account the rescue continued on"
  assert_equals claude-a "$(meta_field "$dir" rm20 account_slot)" "recovery dropped the recorded account slot"
  assert_contains "$(cat "$dir/fake/literal")" "CLAUDE_CONFIG_DIR='$dir/claude-profile'" \
    "the recovered launch did not bind the recorded slot's store"
  assert_not_contains "$out" "$dir/claude-profile" "the outcome leaked the account's credential path"
  assert_not_contains "$out" "test-account" "the outcome leaked the account identity"
  assert_not_contains "$(cat "$dir/home/state/rm20.control-relaunch")" "$dir/claude-profile" \
    "the transaction journal leaked the account's credential path"
  assert_not_contains "$(cat "$dir/home/state/rm20.control-relaunch")" "test-account" \
    "the transaction journal leaked the account identity"
  pass "fm-control recover-missing: the recorded account slot survives the rescue, by logical id alone"
}

test_recover_missing_refuses_a_slot_its_home_no_longer_binds() {
  local dir out rc
  dir=$(new_case account-slot-gone rm21)
  add_ship_task "$dir" rm21
  configure_recover_slots "$dir"
  printf 'account_slot=claude-a\n' >> "$dir/home/state/rm21.meta"
  rm -f "$dir/home/config/account-slots.json"
  make_endpoint_missing "$dir"

  out=$(run_control "$dir" rm21 recover-missing --note "recover"); rc=$?
  expect_code 1 "$rc" "a recovery whose account binding is gone must refuse"$'\n'"$out"
  assert_contains "$out" "config/account-slots.json is missing" "the refusal should name the missing local binding"
  [ ! -s "$dir/fake/created-windows" ] || fail "a refused recovery must not create a terminal"
  assert_equals claude-a "$(meta_field "$dir" rm21 account_slot)" "a refusal must leave the durable record untouched"
  pass "fm-control recover-missing: an unbindable account slot refuses instead of falling back to the ambient account"
}

test_recover_missing_recreates_a_gone_session_before_the_window
test_recover_missing_does_not_recreate_a_session_that_is_still_alive
test_recover_missing_refuses_when_the_session_cannot_be_recreated
test_recover_missing_freezes_the_recorded_profile_for_a_secondmate
test_recover_missing_accepts_a_worktree_holding_only_spawn_leftovers
test_recover_missing_refuses_an_untracked_source_file
test_recover_missing_recreates_the_terminal_and_launches_the_replacement
test_recover_missing_waits_for_the_recreated_shell_to_settle
test_recover_missing_refuses_a_terminal_that_never_settles
test_recover_missing_refuses_a_live_endpoint
test_recover_missing_refuses_an_ambiguous_endpoint
test_recover_missing_refuses_an_absent_local_copy
test_recover_missing_refuses_a_dirty_local_copy
test_recover_missing_refuses_a_pool_slot_owned_by_another_task
test_recover_missing_refuses_an_unreadable_pool_slot_claim
test_recover_missing_keeps_its_own_pool_slot
test_failed_recreation_rolls_the_progress_note_back
test_launch_failure_never_claims_an_agent_was_stopped
test_recover_missing_refuses_a_backend_it_cannot_recreate_on
test_recover_missing_refusal_names_the_postcondition_it_cannot_prove
test_recover_missing_refuses_a_basename_harness_without_naming_a_rejected_flag
test_recover_missing_rejects_runtime_switch_flags
test_recover_missing_requires_a_note_for_a_ship_task
test_recover_missing_preserves_the_recorded_account_slot
test_recover_missing_refuses_a_slot_its_home_no_longer_binds
echo "PASS: fm-control-recover-missing"
