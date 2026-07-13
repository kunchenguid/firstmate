#!/usr/bin/env bash
# Behavior tests for the no-mistakes GATE-agent fleet-lifecycle refusal.
#
# A confused no-mistakes gate agent runs inside a firstmate checkout, adopts the
# captain identity from AGENTS.md, and reaches for fm-spawn/fm-send/fm-teardown.
# bin/fm-gate-refuse-lib.sh is the firstmate capability-removal half: sourced at
# the top of those three entrypoints and called before any fleet mutation, it
# fails closed on either of two independent signals:
#   1. NO_MISTAKES_GATE set in the environment (the marker no-mistakes stamps);
#   2. the current worktree's git-common-dir resolves under a no-mistakes gate
#      repo (.../.no-mistakes/repos/*.git) - the unspoofable backstop, which
#      still refuses even if the marker was tampered/unset.
# A normal firstmate session (real primary, real crew worktree) has NEITHER
# signal and is completely unaffected.
#
# Each entrypoint is exercised in three scenarios, isolating exactly ONE signal:
#   - env-marker refuse : neutral cwd + NO_MISTAKES_GATE set      -> exit 3, no mutation
#   - path-backstop refuse: gate-worktree cwd + marker UNSET      -> exit 3, no mutation
#   - no-regression      : neutral cwd + marker UNSET             -> succeeds, no gate error
# The marker is UNSET explicitly in the no-regression/backstop runs (env -u) and
# those runs stand in a controlled NON-gate repo, so the suite is hermetic even
# when it is itself executed inside the real no-mistakes gate (whose process has
# NO_MISTAKES_GATE=1 and a gate-worktree cwd).
#
# Finally, assert firstmate's TRACKED .no-mistakes.yaml parses and sets
# disable_project_settings: true (the trusted-only opt-out that neutralizes gate
# agents' project instructions on the no-mistakes side).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GATE_LIB="$ROOT/bin/fm-gate-refuse-lib.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
SEND="$ROOT/bin/fm-send.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"

TMP=$(fm_test_tmproot fm-gate-refuse)
fm_git_identity fmtest fmtest@example.invalid

# The env marker's exact stderr fragment (the primary signal).
ENV_MSG='NO_MISTAKES_GATE set'
# The git-common-dir backstop's exact stderr fragment (the unspoofable signal).
PATH_MSG='no-mistakes gate worktree'

# --- shared fixtures --------------------------------------------------------

# make_gate_worktree <root> -> echoes a worktree whose git-common-dir is
# <root>/.no-mistakes/repos/<id>.git, reproducing no-mistakes' gate topology
# (<NM_HOME>/repos/<id>.git + <NM_HOME>/worktrees/<id>/<run>).
make_gate_worktree() {
  local root=$1 id=016d88035d58 run=01KXC3SD5NZYMERGDS68Z1C8ER seed
  mkdir -p "$root/.no-mistakes/repos"
  git init -q --bare "$root/origin.git"
  seed=$(mktemp -d "$TMP/gate-seed.XXXXXX")
  git init -q -b main "$seed"
  git -C "$seed" commit -q --allow-empty -m init
  git -C "$seed" push -q "$root/origin.git" HEAD:refs/heads/main
  rm -rf "$seed"
  git clone -q --bare "$root/origin.git" "$root/.no-mistakes/repos/$id.git"
  git -C "$root/.no-mistakes/repos/$id.git" worktree add --detach \
    "$root/.no-mistakes/worktrees/$id/$run" main >/dev/null 2>&1
  printf '%s\n' "$root/.no-mistakes/worktrees/$id/$run"
}

# make_normal_repo <dir> -> echoes a plain (non-gate) git repo to stand in for a
# normal primary/crew checkout: its git-common-dir is <dir>/.git, never a gate.
make_normal_repo() {
  local dir=$1
  git init -q -b main "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  printf '%s\n' "$dir"
}

GATE_WT=$(make_gate_worktree "$TMP/gate")
NORMAL_CWD=$(make_normal_repo "$TMP/normal-cwd")

# --- the shared helper, tested directly -------------------------------------

# run_guard_lib <cwd> [set|empty] : from <cwd>, source the lib and call the guard under
# set -eu in a subshell (proving set -eu safety). NO_MISTAKES_GATE is unset first;
# a literal "set" second argument re-exports it, so callers pick the signal under
# test. Echoes combined output; the guard's exit is the caller's $?.
run_guard_lib() {
  local cwd=$1 marker=${2:-unset}
  (
    cd "$cwd" || exit 111
    unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS
    case "$marker" in
      set) export NO_MISTAKES_GATE=1 ;;
      empty) export NO_MISTAKES_GATE= ;;
    esac
    set -eu
    # shellcheck source=bin/fm-gate-refuse-lib.sh
    . "$GATE_LIB"
    fm_refuse_if_gate_agent
  ) 2>&1
}

test_helper_env_marker_refuses() {
  local out rc
  out=$(run_guard_lib "$NORMAL_CWD" set); rc=$?
  expect_code 3 "$rc" "helper: env marker must exit 3"
  assert_contains "$out" "$ENV_MSG" "helper: env-marker refusal message"
  pass "fm-gate-refuse-lib: refuses when NO_MISTAKES_GATE is set"
}

test_helper_empty_env_marker_refuses() {
  local out rc
  out=$(run_guard_lib "$NORMAL_CWD" empty); rc=$?
  expect_code 3 "$rc" "helper: empty env marker must exit 3"
  assert_contains "$out" "$ENV_MSG" "helper: empty env-marker refusal message"
  pass "fm-gate-refuse-lib: refuses when NO_MISTAKES_GATE is set empty"
}

test_helper_path_backstop_refuses() {
  local out rc
  # Marker UNSET: only the git-common-dir backstop can fire here.
  out=$(run_guard_lib "$GATE_WT"); rc=$?
  expect_code 3 "$rc" "helper: gate worktree must exit 3 even with the marker unset"
  assert_contains "$out" "$PATH_MSG" "helper: path-backstop refusal message"
  assert_not_contains "$out" "$ENV_MSG" "helper: backstop must not be attributed to the env marker"
  pass "fm-gate-refuse-lib: refuses from a gate worktree via git-common-dir (marker unset)"
}

test_helper_normal_is_noop() {
  local out rc
  out=$(run_guard_lib "$NORMAL_CWD"); rc=$?
  expect_code 0 "$rc" "helper: a normal session (neither signal) must not refuse"
  [ -z "$out" ] || fail "helper: normal session printed output: $out"
  pass "fm-gate-refuse-lib: no-op for a normal session (neither signal, set -eu clean)"
}

# --- fm-spawn ---------------------------------------------------------------

# A fake tmux/treehouse so fm-spawn resolves the crew worktree from a controlled
# pane path and completes without a live terminal (mirrors tests/fm-tangle-guard).
make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|send-keys|set-window-option) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# run_spawn <cwd> <home> <id> <proj> <pane> <fakebin> [ASSIGN...] -> combined output
run_spawn() {
  local cwd=$1 home=$2 id=$3 proj=$4 pane=$5 fakebin=$6; shift 6
  mkdir -p "$home/data/$id"
  printf 'brief\n' > "$home/data/$id/brief.md"
  ( cd "$cwd" && env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS \
      "FM_ROOT_OVERRIDE=" "FM_HOME=$home" \
      "FM_STATE_OVERRIDE=$home/state" "FM_DATA_OVERRIDE=$home/data" \
      "FM_PROJECTS_OVERRIDE=$home/projects" "FM_CONFIG_OVERRIDE=$home/config" \
      "FM_SPAWN_NO_GUARD=1" "FM_FAKE_PANE_PATH=$pane" "TMUX=fake,1,0" \
      "PATH=$fakebin:$PATH" "$@" \
      "$SPAWN" "$id" "$proj" codex ) 2>&1
}

test_spawn_refuses_and_admits() {
  local home proj fakebin wt out rc
  home="$TMP/spawn-home"; mkdir -p "$home/data"
  proj=$(make_normal_repo "$TMP/spawn-proj")
  fakebin=$(make_spawn_fakebin "$TMP/spawn-fake")
  wt="$TMP/spawn-wt"
  git -C "$proj" worktree add -q --detach "$wt" >/dev/null 2>&1

  # env-marker refuse: neutral cwd, marker set.
  out=$(run_spawn "$NORMAL_CWD" "$home" spawn-envmark "$proj" "$wt" "$fakebin" NO_MISTAKES_GATE=1); rc=$?
  expect_code 3 "$rc" "spawn: NO_MISTAKES_GATE must refuse"
  assert_contains "$out" "$ENV_MSG" "spawn: env-marker refusal message"
  assert_absent "$home/state/spawn-envmark.meta" "spawn: refused env-marker launch must not record meta"

  # path-backstop refuse: gate-worktree cwd, marker UNSET.
  out=$(run_spawn "$GATE_WT" "$home" spawn-backstop "$proj" "$wt" "$fakebin"); rc=$?
  expect_code 3 "$rc" "spawn: gate-worktree cwd must refuse with the marker unset"
  assert_contains "$out" "$PATH_MSG" "spawn: path-backstop refusal message"
  assert_absent "$home/state/spawn-backstop.meta" "spawn: refused backstop launch must not record meta"

  # no-regression: neutral cwd, marker UNSET, genuine isolated worktree.
  out=$(run_spawn "$NORMAL_CWD" "$home" spawn-ok "$proj" "$wt" "$fakebin"); rc=$?
  expect_code 0 "$rc" "spawn: a normal session must still spawn"
  assert_contains "$out" "spawned spawn-ok" "spawn: normal launch should report success"
  assert_not_contains "$out" "$ENV_MSG" "spawn: normal launch must not print the gate refusal"
  assert_not_contains "$out" "$PATH_MSG" "spawn: normal launch must not print the backstop refusal"
  assert_present "$home/state/spawn-ok.meta" "spawn: normal launch should record meta"
  pass "fm-spawn: refuses on marker and gate-worktree backstop; a normal crew spawn is unaffected"
}

# --- fm-send ----------------------------------------------------------------

# A fake tmux that logs send-keys to FM_TMUX_LOG and reports live endpoints
# (mirrors tests/fm-send-strict), so a successful send is observable and a
# refused one leaves an empty log (proving no message was typed).
make_send_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift; literal=0; target=
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) target=$2; shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    printf 'send-keys target=%s literal=%s arg=%s\n' "$target" "$literal" "${1:-}" >> "$FM_TMUX_LOG"
    exit 0 ;;
  display-message) printf '%%1\n'; exit 0 ;;
  capture-pane) printf '\xe2\x94\x82 \xe2\x94\x82\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/sleep"
  chmod +x "$fakebin/sleep"
  printf '%s\n' "$fakebin"
}

# run_send <cwd> <home> <fakebin> <log> <target> <text> [ASSIGN...] -> combined output
run_send() {
  local cwd=$1 home=$2 fakebin=$3 log=$4 target=$5 text=$6; shift 6
  ( cd "$cwd" && env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS \
      "PATH=$fakebin:$PATH" "FM_HOME=$home" "FM_ROOT_OVERRIDE=$home" \
      "FM_TMUX_LOG=$log" "FM_SEND_SETTLE=0" "$@" \
      "$SEND" "$target" "$text" ) 2>&1
}

test_send_refuses_and_admits() {
  local home fakebin log out rc
  home="$TMP/send-home"; mkdir -p "$home/state"
  fakebin=$(make_send_fakebin "$TMP/send-fake")
  log="$TMP/send-tmux.log"
  fm_write_meta "$home/state/lane-ok.meta" "window=sess:fm-lane-ok" "kind=ship" "harness=codex"

  # env-marker refuse.
  : > "$log"
  out=$(run_send "$NORMAL_CWD" "$home" "$fakebin" "$log" fm-lane-ok "hello captain" NO_MISTAKES_GATE=1); rc=$?
  expect_code 3 "$rc" "send: NO_MISTAKES_GATE must refuse"
  assert_contains "$out" "$ENV_MSG" "send: env-marker refusal message"
  [ ! -s "$log" ] || fail "send: refused env-marker send still typed to the endpoint"$'\n'"$(cat "$log")"

  # path-backstop refuse (marker UNSET).
  : > "$log"
  out=$(run_send "$GATE_WT" "$home" "$fakebin" "$log" fm-lane-ok "hello captain"); rc=$?
  expect_code 3 "$rc" "send: gate-worktree cwd must refuse with the marker unset"
  assert_contains "$out" "$PATH_MSG" "send: path-backstop refusal message"
  [ ! -s "$log" ] || fail "send: refused backstop send still typed to the endpoint"$'\n'"$(cat "$log")"

  # no-regression.
  : > "$log"
  out=$(run_send "$NORMAL_CWD" "$home" "$fakebin" "$log" fm-lane-ok "hello captain"); rc=$?
  expect_code 0 "$rc" "send: a normal session must still send"
  assert_not_contains "$out" "$ENV_MSG" "send: normal send must not print the gate refusal"
  assert_not_contains "$out" "$PATH_MSG" "send: normal send must not print the backstop refusal"
  assert_contains "$(cat "$log")" "target=sess:fm-lane-ok literal=1 arg=hello captain" "send: normal send should type the text"
  pass "fm-send: refuses on marker and gate-worktree backstop; a normal steer is unaffected"
}

# --- fm-teardown ------------------------------------------------------------

# make_teardown_case <name> -> echoes a case dir holding a LANDED no-mistakes ship
# task (HEAD reachable from origin), so a normal teardown genuinely succeeds and a
# refused one leaves the task untouched (mirrors tests/fm-teardown make_case).
make_teardown_case() {
  local name=$1 case_dir fakebin t
  case_dir="$TMP/$name"; fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$case_dir/config" "$fakebin"
  for t in treehouse tmux; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/$t"
    chmod +x "$fakebin/$t"
  done
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []"; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2; exit 1 ;;
esac
exit 0
SH
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr view") echo "error: pull request not found" >&2; exit 1 ;;
esac
exit 0
SH
  chmod +x "$fakebin/gh-axi" "$fakebin/gh"
  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$case_dir/origin.git" "$case_dir/_seed" 2>/dev/null
  git -C "$case_dir/_seed" commit -q --allow-empty -m "origin baseline"
  git -C "$case_dir/_seed" push -q origin main
  rm -rf "$case_dir/_seed"
  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" remote set-head origin main 2>/dev/null || true
  git -C "$case_dir/project" worktree add -q -b fm/task-x1 "$case_dir/wt" main
  git -C "$case_dir/wt" commit -q --allow-empty -m "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" "worktree=$case_dir/wt" "project=$case_dir/project" \
    "kind=ship" "mode=no-mistakes"
  touch "$case_dir/state/.last-watcher-beat"
  printf '%s\n' "$case_dir"
}

# run_teardown <cwd> <case_dir> [ASSIGN...] -> combined output
run_teardown() {
  local cwd=$1 case_dir=$2; shift 2
  ( cd "$cwd" && env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS \
      "FM_ROOT_OVERRIDE=$ROOT" "FM_STATE_OVERRIDE=$case_dir/state" \
      "FM_CONFIG_OVERRIDE=$case_dir/config" "PATH=$case_dir/fakebin:$PATH" "$@" \
      "$TEARDOWN" task-x1 ) 2>&1
}

test_teardown_refuses_and_admits() {
  local case_dir out rc

  # env-marker refuse: a genuinely-landed task is still refused; nothing is torn down.
  case_dir=$(make_teardown_case teardown-envmark)
  out=$(run_teardown "$NORMAL_CWD" "$case_dir" NO_MISTAKES_GATE=1); rc=$?
  expect_code 3 "$rc" "teardown: NO_MISTAKES_GATE must refuse"
  assert_contains "$out" "$ENV_MSG" "teardown: env-marker refusal message"
  assert_present "$case_dir/state/task-x1.meta" "teardown: refused env-marker teardown must leave the task"

  # path-backstop refuse (marker UNSET).
  case_dir=$(make_teardown_case teardown-backstop)
  out=$(run_teardown "$GATE_WT" "$case_dir"); rc=$?
  expect_code 3 "$rc" "teardown: gate-worktree cwd must refuse with the marker unset"
  assert_contains "$out" "$PATH_MSG" "teardown: path-backstop refusal message"
  assert_present "$case_dir/state/task-x1.meta" "teardown: refused backstop teardown must leave the task"

  # no-regression: a normal session tears down the landed task.
  case_dir=$(make_teardown_case teardown-ok)
  out=$(run_teardown "$NORMAL_CWD" "$case_dir"); rc=$?
  expect_code 0 "$rc" "teardown: a normal session must still tear down landed work"
  assert_not_contains "$out" "$ENV_MSG" "teardown: normal teardown must not print the gate refusal"
  assert_not_contains "$out" "$PATH_MSG" "teardown: normal teardown must not print the backstop refusal"
  assert_not_contains "$out" "REFUSED" "teardown: normal teardown of landed work must not refuse"
  pass "fm-teardown: refuses on marker and gate-worktree backstop; a normal teardown is unaffected"
}

# --- tracked .no-mistakes.yaml ----------------------------------------------

test_no_mistakes_yaml_disables_project_settings() {
  local file="$ROOT/.no-mistakes.yaml" val tab
  assert_present "$file" "tracked .no-mistakes.yaml is missing"
  git -C "$ROOT" ls-files --error-unmatch .no-mistakes.yaml >/dev/null 2>&1 \
    || fail ".no-mistakes.yaml is not tracked by git"

  # Parse with a real YAML loader and assert the field is boolean true, so a
  # malformed file or a stringy "true" fails where a naive grep would pass.
  if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
    val=$(python3 -c 'import yaml,sys; print(yaml.safe_load(open(sys.argv[1])).get("disable_project_settings"))' "$file") \
      || fail ".no-mistakes.yaml did not parse as YAML (python3)"
    [ "$val" = "True" ] || fail "disable_project_settings is not boolean true (python3 read: $val)"
  elif command -v ruby >/dev/null 2>&1; then
    ruby -ryaml -e 'exit((YAML.safe_load(File.read(ARGV[0]))["disable_project_settings"] == true) ? 0 : 1)' "$file" \
      || fail ".no-mistakes.yaml did not parse or disable_project_settings != true (ruby)"
  else
    # No YAML loader: fall back to a strict structural check - no tab indentation
    # (YAML forbids it) and the top-level key mapped to the bare boolean true.
    tab=$(printf '\t')
    case "$(cat "$file")" in
      *"$tab"*) fail ".no-mistakes.yaml uses a tab (invalid YAML indentation)" ;;
    esac
    grep -qxE 'disable_project_settings:[[:space:]]+true' "$file" \
      || fail "top-level 'disable_project_settings: true' not found in .no-mistakes.yaml"
  fi
  pass ".no-mistakes.yaml parses and sets disable_project_settings: true (trusted-only gate opt-out)"
}

test_helper_env_marker_refuses
test_helper_empty_env_marker_refuses
test_helper_path_backstop_refuses
test_helper_normal_is_noop
test_spawn_refuses_and_admits
test_send_refuses_and_admits
test_teardown_refuses_and_admits
test_no_mistakes_yaml_disables_project_settings
