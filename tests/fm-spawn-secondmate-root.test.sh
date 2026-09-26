#!/usr/bin/env bash
# tests/fm-spawn-secondmate-root.test.sh - a second mate on herdr starts in its
# herdr workspace's root directory (docs/configuration.md "Second-mate working
# directory").
#
# Drives the real bin/fm-spawn.sh against a canned, stateful fake `herdr` CLI -
# never a real herdr session. The fake reports the session's socket path, and
# the session.json beside it carries each workspace's identity_cwd, exactly
# where real herdr persists it. The launch the pane receives is then EXECUTED
# with `claude` replaced by a probe, so assertions read what the agent would
# have started with, not the command text.
#
# Covers: a workspace root that differs from the home, a workspace that reports
# no root, a root the trust store refuses (home fallback), a harness that
# cannot carry the home's contract (refused before any tab exists), a relaunch
# into an adopted pane, and Firstmate script home resolution from the foreign
# working directory.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "skip: node not found (required by bin/fm-claude-trust.sh)"; exit 0; }

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-secondmate-root)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
# Every task id a case below spawns. Listed here rather than collected in
# new_case, which runs inside $(...) and so cannot append to a parent array.
TASK_IDS=(smr1 smr2 smr3 smr4 smr5 smr6 smr7)
cleanup() {
  local id
  # Each spawn owns /tmp/fm-<id> and stages its launch file in
  # /tmp/fm-<id>+<home-token>.
  for id in "${TASK_IDS[@]}"; do rm -rf -- "/tmp/fm-$id" "/tmp/fm-$id"+*; done
  fm_test_remove_tree "$TMP_ROOT"
}
trap cleanup EXIT

make_herdr_stub() {  # <case-dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat >"$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
printf '%s\n' "$*" >>"$D/herdr-log"
case "${1:-} ${2:-}" in
  'status --json')
    printf '{"client":{"version":"0.9.0","protocol":22},"server":{"running":true}}\n'
    exit 0 ;;
  'server '*) exit 0 ;;
  'session list')
    printf '{"sessions":[{"name":"fmlab","running":true,"socket_path":"%s/herdr-data/herdr.sock"}]}\n' "$D"
    exit 0 ;;
  'workspace list')
    printf '{"result":{"workspaces":[{"workspace_id":"wsroot","label":"%s","focused":false}]}}\n' "$(cat "$D/ws-label")"
    exit 0 ;;
  'workspace create')
    printf 'workspace create\n' >>"$D/forbidden"
    printf '{"result":{"workspace":{"workspace_id":"wsnew"},"tab":{"tab_id":"seedtab"}}}\n'
    exit 0 ;;
  'tab list')
    printf '{"result":{"tabs":[]}}\n'
    exit 0 ;;
  'tab create')
    # Record the directory herdr would open the new pane in.
    shift 2
    while [ "$#" -gt 0 ]; do
      [ "$1" != --cwd ] || printf '%s' "$2" >"$D/cwd"
      shift
    done
    printf 'created\n' >>"$D/tab-created"
    printf '%s' '%9' >"$D/pane"
    printf '{"result":{"tab":{"tab_id":"tabnew"},"root_pane":{"pane_id":"%%9"}}}\n'
    exit 0 ;;
  'pane get')
    if [ "${3:-}" = "$(cat "$D/pane")" ]; then
      printf '{"result":{"pane":{"pane_id":"%s","foreground_cwd":"%s"}}}\n' "${3:-}" "$(cat "$D/cwd")"
    else
      printf '{"error":{"code":"pane_not_found"}}\n'
    fi
    exit 0 ;;
  'agent get')
    if [ -f "$D/agent-live" ]; then
      printf '{"result":{"agent":{"agent":"claude","agent_status":"working"}}}\n'
    else
      printf '{"error":{"code":"agent_not_found"}}\n'
    fi
    exit 0 ;;
  'pane process-info')
    printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"%s","shell_pid":4242,"foreground_processes":[{"pid":4243,"name":"claude","argv":["claude"],"cmdline":"claude"}]}}}\n' "$(cat "$D/pane")"
    exit 0 ;;
  'pane run' | 'pane send-text')
    payload=${4:-}
    case "$payload" in
      ". '"*"'") staged=${payload#". '"}; staged=${staged%"'"}; [ ! -f "$staged" ] || payload=$(cat "$staged") ;;
    esac
    printf '%s\n' "$payload" >>"$D/sent"
    case "$payload" in
      "cd -- '"*"'") dir=${payload#"cd -- '"}; printf '%s' "${dir%"'"}" >"$D/cwd" ;;
      *'encode launch-brief'*) printf '%s' "$payload" >"$D/launch"; : >"$D/agent-live" ;;
    esac
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/herdr"
  # The launch's own harness probe: reports where it started and what it got.
  cat >"$fb/claude" <<'SH'
#!/usr/bin/env bash
printf 'cwd=%s\n' "$(pwd -P)"
printf 'fm_home=%s\n' "${FM_HOME-}"
printf 'path_first=%s\n' "${PATH%%:*}"
for a in "$@"; do printf 'arg=%s\n' "$a"; done
SH
  chmod +x "$fb/claude"
}

# new_case <name> <id>: a primary home, a seeded second-mate home, and a
# separate directory standing in for the herdr workspace root.
new_case() {  # <name> <id>
  local dir="$TMP_ROOT/$1" id=$2 home sm
  home="$dir/home"
  sm="$dir/smhome"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects" \
    "$sm/state" "$sm/data" "$sm/config" "$sm/projects" "$sm/bin" "$sm/.claude" \
    "$dir/root" "$dir/fake/herdr-data" "$dir/user-home"
  touch "$home/state/.last-watcher-beat"
  printf 'off\n' >"$sm/config/herdr-presentation-spaces"
  printf '# second mate home contract\nOperate from this home.\n' >"$sm/AGENTS.md"
  printf '%s\n' "$id" >"$sm/.fm-secondmate-home"
  printf 'Charter for %s: idle until routed work arrives.\n' "$id" >"$sm/data/charter.md"
  # The home's tracked hooks, in the shape the firstmate repo ships them.
  cat >"$sm/.claude/settings.json" <<'JSON'
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"exec \"$CLAUDE_PROJECT_DIR\"/bin/fm-turnend-guard.sh --claude"}]}]}}
JSON
  printf '%s\n' 'projects/' 'state/' 'data/' 'config/' >"$sm/.gitignore"
  git -C "$sm" init -q -b main
  printf '# workspace root project\n' >"$dir/root/CLAUDE.md"
  printf '2ndmate-%s' "$id" >"$dir/fake/ws-label"
  printf '%s' '%none' >"$dir/fake/pane"
  : >"$dir/fake/herdr-log"
  make_herdr_stub "$dir"
  printf '%s\n' "$dir"
}

# write_session_root <case-dir> <workspace-id> <root>: the session.json herdr
# persists beside its socket, naming that workspace's identity_cwd.
write_session_root() {
  jq -n --arg id "$2" --arg root "$3" \
    '{workspaces:[{id:"wsother",identity_cwd:"/"},{id:$id,identity_cwd:$root}]}' \
    >"$1/fake/herdr-data/session.json"
}

run_spawn() {  # <case-dir> <args...>
  local dir=$1
  shift
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SOCKET_PATH -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
    -u TMUX HERDR_SESSION=fmlab \
    PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    HOME="$dir/user-home" CLAUDE_CONFIG_DIR='' FM_SPAWN_NO_GUARD=1 \
    FM_SKIP_SECONDMATE_SYNC=1 FM_SKIP_SECONDMATE_INHERIT=1 \
    "$SPAWN" "$@" 2>&1
}

# run_launch <case-dir>: execute the launch the pane received, from the
# directory herdr opened that pane in, with the claude probe on PATH.
run_launch() {
  local dir=$1
  (cd "$(cat "$dir/fake/cwd")" &&
    env -i HOME="$dir/user-home" PATH="$dir/fakebin:/usr/bin:/bin:/usr/sbin:/sbin" TERM=xterm \
      /bin/sh -c "$(cat "$dir/fake/launch")")
}

test_root_present_starts_in_the_workspace_root() {
  local dir out rc=0 probe settings contract
  dir=$(new_case root-present smr1)
  write_session_root "$dir" wsroot "$dir/root"

  out=$(run_spawn "$dir" smr1 "$dir/smhome" claude --secondmate --backend herdr) || rc=$?
  expect_code 0 "$rc" "a claude second mate with a workspace root should spawn"$'\n'"$out"$'\n'"$(cat "$dir/fake/herdr-log")"
  [ ! -e "$dir/fake/forbidden" ] || fail "an existing workspace must be adopted, not created"
  assert_equals "$dir/root" "$(cat "$dir/fake/cwd")" "herdr should open the second mate's tab in the workspace root"

  probe=$(run_launch "$dir") || fail "the emitted launch did not run: $probe"
  assert_contains "$probe" "cwd=$dir/root" "the agent should start in the workspace root"
  assert_contains "$probe" "fm_home=$dir/smhome" "the agent's FM_HOME should name its own home"
  assert_equals "path_first=$dir/smhome/bin" "$(grep '^path_first=' <<<"$probe")" \
    "the home's bin should lead PATH"
  assert_contains "$probe" $'arg=--add-dir\narg='"$dir/smhome" "the home should be added so its skills load"
  assert_contains "$probe" $'arg=--setting-sources\narg=user' \
    "the workspace root's own project hooks must not load beside the home's"

  settings=$(grep -A1 '^arg=--settings$' <<<"$probe" | tail -1)
  settings=${settings#arg=}
  [ -f "$settings" ] || fail "--settings should name a generated file, got '$settings'"
  assert_contains "$(jq -r '.hooks.Stop[0].hooks[0].command' "$settings")" "'$dir/smhome'/bin/fm-turnend-guard.sh" \
    "the home's Stop hook should be pinned to the home, not the working directory"
  assert_equals off "$(jq -r '.feedbackDrafts' "$settings")" "the per-launch settings keys should still apply"
  assert_equals false "$(jq -r '.attribution.sessionUrl' "$settings")" "attribution should stay off"

  contract=$(grep -A1 '^arg=--append-system-prompt-file$' <<<"$probe" | tail -1)
  contract=${contract#arg=}
  [ -f "$contract" ] || fail "--append-system-prompt-file should name a generated contract, got '$contract'"
  assert_contains "$(cat "$contract")" "Operate from this home." "the contract should carry the home's AGENTS.md"
  assert_contains "$(cat "$contract")" "Your Firstmate home is $dir/smhome" "the contract should name the home"
  assert_contains "$(grep -A1 '^arg=' <<<"$probe" | tail -1)" "launch-brief" \
    "the charter should still arrive as the first message"

  assert_equals true "$(jq -r --arg p "$dir/root" '.projects[$p].hasTrustDialogAccepted' "$dir/user-home/.claude.json")" \
    "the workspace root should be pre-registered as trusted so the pane does not wedge"
  assert_equals "worktree=$dir/smhome" "$(grep '^worktree=' "$dir/home/state/smr1.meta")" \
    "the task record should still name the home"
  pass "a second mate whose workspace reports a root starts there with its home's contract, skills, hooks, and FM_HOME"
}

test_root_absent_keeps_the_home_launch() {
  local dir out rc=0 probe
  dir=$(new_case root-absent smr2)
  write_session_root "$dir" wsunrelated "$dir/root"

  out=$(run_spawn "$dir" smr2 "$dir/smhome" claude --secondmate --backend herdr) || rc=$?
  expect_code 0 "$rc" "a second mate whose workspace reports no root should spawn"$'\n'"$out"
  assert_equals "$dir/smhome" "$(cat "$dir/fake/cwd")" "with no root, the tab should open in the home as before"
  probe=$(run_launch "$dir") || fail "the emitted launch did not run: $probe"
  assert_contains "$probe" "cwd=$dir/smhome" "with no root, the agent should start in its home"
  assert_not_contains "$probe" "arg=--add-dir" "with no root, the launch should carry no root flags"
  assert_not_contains "$probe" "arg=--setting-sources" "with no root, project settings should load as before"
  assert_contains "$probe" 'arg={"feedbackDrafts":"off","attribution":{"commit":"","pr":"","sessionUrl":false}}' \
    "with no root, the inline per-launch settings should be unchanged"
  assert_not_contains "$(cat "$dir/fake/launch")" "smhome/bin'"':' "with no root, PATH should be left alone"

  # A root that IS the home is the same as no root.
  dir=$(new_case root-is-home smr3)
  write_session_root "$dir" wsroot "$dir/smhome"
  rc=0
  out=$(run_spawn "$dir" smr3 "$dir/smhome" claude --secondmate --backend herdr) || rc=$?
  expect_code 0 "$rc" "a second mate whose root is its home should spawn"$'\n'"$out"
  probe=$(run_launch "$dir") || fail "the emitted launch did not run: $probe"
  assert_not_contains "$probe" "arg=--add-dir" "a root equal to the home should change nothing"
  pass "a workspace with no root, or with the home as its root, keeps the home launch unchanged"
}

test_untrustable_root_falls_back_to_the_home() {
  local dir out rc=0 probe
  dir=$(new_case root-user-home smr6)
  write_session_root "$dir" wsroot "$dir/user-home"
  out=$(run_spawn "$dir" smr6 "$dir/smhome" claude --secondmate --backend herdr) || rc=$?
  expect_code 0 "$rc" "a second mate whose workspace root is the user's home should still spawn"$'\n'"$out"
  assert_equals 1 "$(grep -c "^warning: secondmate smr6's herdr workspace root $dir/user-home" <<<"$out")" \
    "the fallback should warn exactly once, naming the root"
  assert_equals 1 "$(grep -c '^tab create' "$dir/fake/herdr-log")" "exactly one tab should be opened"
  assert_equals "$dir/smhome" "$(cat "$dir/fake/cwd")" "the tab should be opened in the home, never in the untrustable root"
  probe=$(run_launch "$dir") || fail "the emitted launch did not run: $probe"
  assert_contains "$probe" "cwd=$dir/smhome" "the agent should start in its home"
  assert_not_contains "$probe" "arg=--add-dir" "the home launch should carry no root flags"
  assert_equals null "$(jq -r --arg p "$dir/user-home" '.projects[$p]' "$dir/user-home/.claude.json" 2>/dev/null || echo null)" \
    "the user's home must never be registered as trusted"

  # A codex second mate whose root is the filesystem root falls back too,
  # rather than refusing.
  dir=$(new_case root-slash smr7)
  write_session_root "$dir" wsroot /
  rc=0
  out=$(run_spawn "$dir" smr7 "$dir/smhome" codex --secondmate --backend herdr) || rc=$?
  expect_code 0 "$rc" "a second mate whose workspace root is / should still spawn"$'\n'"$out"
  assert_contains "$out" "warning: secondmate smr7's herdr workspace root / " "the fallback should warn"
  assert_not_contains "$out" "has no verified way" "a fallback to the home is not a refusal"
  assert_equals "$dir/smhome" "$(cat "$dir/fake/cwd")" "the tab should be opened in the home"
  pass "a workspace root at the user's home or / falls back to the home with one warning before any tab"
}

test_unsupported_harness_refuses_before_any_tab() {
  local dir out rc=0
  dir=$(new_case root-codex smr4)
  write_session_root "$dir" wsroot "$dir/root"
  out=$(run_spawn "$dir" smr4 "$dir/smhome" codex --secondmate --backend herdr) || rc=$?
  expect_code 1 "$rc" "a codex second mate with a foreign workspace root should refuse"$'\n'"$out"
  assert_contains "$out" "has no verified way to load the second mate's firstmate contract" \
    "the refusal should say why"
  [ ! -e "$dir/fake/tab-created" ] || fail "a refused launch must not open a tab"
  [ ! -e "$dir/fake/launch" ] || fail "a refused launch must not start an agent"
  pass "a harness that cannot carry the home's contract refuses before any tab is opened"
}

test_relaunch_moves_the_adopted_pane_to_the_root() {
  local dir out rc=0 probe
  dir=$(new_case relaunch smr5)
  write_session_root "$dir" wsroot "$dir/root"
  # A second mate already recorded on herdr, whose pane sits in its home with
  # no agent: the shape a relaunch adopts.
  {
    echo "window=fmlab:%7"
    echo "endpoint_task_id=smr5"
    echo "worktree=$dir/smhome"
    echo "home=$dir/smhome"
    echo "project=$dir/smhome"
    echo "harness=claude"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "tasktmp=/tmp/fm-smr5"
    echo "model=default"
    echo "effort=default"
    echo "backend=herdr"
    echo "herdr_session=fmlab"
    echo "herdr_workspace_id=wsroot"
    echo "herdr_tab_id=tab1"
    echo "herdr_pane_id=%7"
  } >"$dir/home/state/smr5.meta"
  printf '%s' '%7' >"$dir/fake/pane"
  printf '%s' "$dir/smhome" >"$dir/fake/cwd"

  out=$(run_spawn "$dir" smr5 --relaunch) || rc=$?
  expect_code 0 "$rc" "a second mate relaunch should succeed"$'\n'"$out"$'\n'"$(cat "$dir/fake/herdr-log")"
  assert_contains "$(cat "$dir/fake/sent")" "cd -- '$dir/root'" "the adopted pane should be moved to the workspace root"
  [ ! -e "$dir/fake/tab-created" ] || fail "a relaunch into a live pane must not open a second tab"
  probe=$(run_launch "$dir") || fail "the emitted launch did not run: $probe"
  assert_contains "$probe" "cwd=$dir/root" "the relaunched agent should start in the workspace root"
  assert_contains "$probe" "fm_home=$dir/smhome" "the relaunched agent should keep its home"
  assert_contains "$probe" "arg=--append-system-prompt-file" "the relaunch should carry the home's contract"
  pass "a relaunch moves the adopted pane to the workspace root and carries the home's contract"
}

test_scripts_resolve_the_home_from_fm_home_in_a_foreign_cwd() {
  local dir home root out
  dir="$TMP_ROOT/foreign-cwd"
  home="$dir/home"
  root="$dir/root"
  mkdir -p "$home/state" "$root/state"
  # A decoy lock in the working directory's own state/ must never be read.
  printf '%s\n' 999991 >"$root/state/.lock"
  printf '%s\n' 999992 >"$home/state/.lock"
  out=$(cd "$root" && FM_HOME="$home" FM_ROOT_OVERRIDE='' "$ROOT/bin/fm-lock.sh" status 2>&1)
  assert_contains "$out" 999992 "fm-lock.sh should read the lock in FM_HOME"
  assert_not_contains "$out" 999991 "fm-lock.sh must not read the working directory's state"
  pass "a Firstmate script run from a foreign working directory resolves its home from FM_HOME"
}

test_root_present_starts_in_the_workspace_root
test_root_absent_keeps_the_home_launch
test_untrustable_root_falls_back_to_the_home
test_unsupported_harness_refuses_before_any_tab
test_relaunch_moves_the_adopted_pane_to_the_root
test_scripts_resolve_the_home_from_fm_home_in_a_foreign_cwd
