#!/usr/bin/env bash
# tests/fm-spawn-brief-argv.test.sh - the launch command must never expand a
# brief's own text into the agent process's argv.
#
# Why this is a safety regression and not a style preference: a command
# substitution's result becomes one argv element, so a brief expanded into the
# launch line is readable in every `ps` listing on the host and, worse, is
# MATCHABLE. A crewmate clearing stray project processes with the ordinary
# `pkill -f <pattern>` or `ps | grep <pattern> | xargs kill` idiom then matches
# sibling agents whose briefs merely mention that pattern and terminates them.
# On 2026-08-29 one such sweep for a project's own script name killed four
# working crewmates at once, every one of them matched only through its brief.
#
# These cases run the REAL launch command bin/fm-spawn.sh emits, against a
# stand-in harness that records the argv it actually received, so the assertion
# is on observed process arguments rather than on the script's source.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-brief-argv)

# A word no launch scaffold would ever contain on its own: it can only reach
# argv by way of the brief body.
SENTINEL=zzsweepnoisesentinelzz

# Fake tmux: answers the pane-path query and logs each literal send-keys payload.
make_fakebin() {
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
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      shift
      skip_next=
      for a in "$@"; do
        if [ -n "$skip_next" ]; then skip_next=; continue; fi
        case "$a" in
          -t) skip_next=1; continue ;;
          -l) continue ;;
          Enter|C-m) continue ;;
          *) printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG" ;;
        esac
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# A stand-in for the harness binary that records the argv it was handed, one
# element per line, then exits. This is what turns "what does the launch line
# expand to" into an observable process fact.
install_argv_recorder() {  # <fakebin> <argv-log> <tool>...
  local fakebin=$1 log=$2 tool
  shift 2
  for tool in "$@"; do
    cat > "$fakebin/$tool" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$log"
exit 0
SH
    chmod +x "$fakebin/$tool"
  done
}

make_case() {  # <name> <harness>
  local name=$1 harness=$2 case_dir home proj wt fakebin launchlog id
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf '%s\n' "$harness" > "$home/config/crew-harness"
  printf '%s\n' "$$" > "$home/state/.lock"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  id=$name-z1
  mkdir -p "$home/data/$id"
  # A brief shaped like a real one: multi-line prose that names a project
  # script, exactly the kind of word an agent greps for when cleaning up.
  cat > "$home/data/$id/brief.md" <<BRIEF
# Task
Re-baseline the figure and report the margin.
Run \`npm run measure:$SENTINEL\` on both bodies before you commit.
BRIEF
  printf '%s\n' "$home|$proj|$wt|$fakebin|$launchlog|$id"
}

run_spawn() {  # <home> <wt> <fakebin> <launchlog> <spawn args...>
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  : > "$launchlog"
  env FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$launchlog" PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" --mode no-mistakes --yolo off 2>&1
}

# The launch line as the pane's shell would run it, with the harness replaced by
# the argv recorder. Prints nothing; leaves the recorded argv in <argv-log>.
execute_launch_line() {  # <launchlog> <argv-log> <fakebin> <harness-tool>
  local launchlog=$1 argvlog=$2 fakebin=$3 tool=$4 line
  line=$(grep -F "$tool " "$launchlog" | tail -1)
  [ -n "$line" ] || return 1
  : > "$argvlog"
  install_argv_recorder "$fakebin" "$argvlog" "$tool"
  ( PATH="$fakebin:$PATH" bash -c "$line" >/dev/null 2>&1 ) || true
  [ -s "$argvlog" ]
}

read_case() {
  IFS='|' read -r HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG CASE_ID <<EOF
$1
EOF
}

# --- cases ------------------------------------------------------------------

# The core regression, run through the real spawn path and the real launch line.
test_brief_body_never_reaches_agent_argv() {
  local rec out argvlog
  rec=$(make_case argv claude)
  read_case "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$CASE_ID" "$PROJ_DIR" claude) || fail "spawn failed: $out"

  argvlog="$TMP_ROOT/argv/claude.argv"
  mkdir -p "$(dirname "$argvlog")"
  execute_launch_line "$LAUNCH_LOG" "$argvlog" "$FAKEBIN_DIR" claude \
    || fail "could not execute the emitted launch line for claude"

  grep -Fq "$SENTINEL" "$HOME_DIR/data/$CASE_ID/brief.md" \
    || fail "fixture brief must contain the sentinel or the case proves nothing"
  if grep -Fq "$SENTINEL" "$argvlog"; then
    fail "brief body reached the agent's argv: a sibling crewmate's \`pkill -f $SENTINEL\` would kill this agent"
  fi
  grep -Fq 'Read the brief at' "$argvlog" \
    || fail "argv must still carry the pointer instruction (got: $(cat "$argvlog"))"
  grep -Fq "$HOME_DIR/data/$CASE_ID/brief.md" "$argvlog" \
    || fail "argv pointer must name the brief's absolute path"
  pass "claude launch argv carries a pointer, never the brief body"
}

# The pointer instruction the agent receives has to be present and imperative,
# because with the body gone it is the only thing that reaches the model first.
test_pointer_is_a_complete_instruction() {
  local rec out argvlog prompt
  rec=$(make_case pointer claude)
  read_case "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$CASE_ID" "$PROJ_DIR" claude) || fail "spawn failed: $out"
  argvlog="$TMP_ROOT/argv/pointer.argv"
  mkdir -p "$(dirname "$argvlog")"
  execute_launch_line "$LAUNCH_LOG" "$argvlog" "$FAKEBIN_DIR" claude \
    || fail "could not execute the emitted launch line"
  prompt=$(grep -F 'Read the brief at' "$argvlog" | tail -1)
  case "$prompt" in
    *"follow it exactly"*) ;;
    *) fail "pointer must tell the agent to follow the brief (got: $prompt)" ;;
  esac
  case "$prompt" in
    *"without waiting"*) ;;
    *) fail "pointer must tell the agent not to wait for further input (got: $prompt)" ;;
  esac
  # The operational marker still has to survive: the pointer is firstmate input,
  # not captain input, and downstream classification reads that marker.
  printf '%s' "$prompt" | "$ROOT/bin/fm-operational-input.sh" kind \
    | grep -Fqx launch-brief \
    || fail "pointer must still be encoded as a launch-brief operational input"
  pass "pointer prompt is a complete, correctly marked launch-brief instruction"
}

# Every harness that takes a positional prompt shares the same hazard, so the
# guarantee is asserted per harness rather than for claude alone.
test_every_prompt_bearing_harness_is_covered() {
  local harness rec out argvlog tool
  for harness in claude codex opencode grok; do
    rec=$(make_case "h-$harness" "$harness")
    read_case "$rec"
    case "$harness" in
      *) tool=$harness ;;
    esac
    fm_fake_exit0 "$FAKEBIN_DIR" "$tool"
    out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
      "$CASE_ID" "$PROJ_DIR" "$harness") || { echo "# skip $harness: $out"; continue; }
    argvlog="$TMP_ROOT/argv/$harness.argv"
    mkdir -p "$(dirname "$argvlog")"
    execute_launch_line "$LAUNCH_LOG" "$argvlog" "$FAKEBIN_DIR" "$tool" \
      || fail "could not execute the emitted launch line for $harness"
    if grep -Fq "$SENTINEL" "$argvlog"; then
      fail "$harness: brief body reached the agent's argv"
    fi
    grep -Fq 'Read the brief at' "$argvlog" \
      || fail "$harness: argv lost the pointer instruction"
  done
  pass "no prompt-bearing harness expands the brief body into argv"
}

test_raw_launch_uses_pointer_and_refuses_brief_expansion() {
  local rec out argvlog raw_launch
  rec=$(make_case raw-pointer raw-harness)
  read_case "$rec"
  fm_fake_exit0 "$FAKEBIN_DIR" raw-harness
  raw_launch='raw-harness "$(__OPINPUT__ encode launch-brief < __BRIEFPOINTER__)"'
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$CASE_ID" "$PROJ_DIR" "$raw_launch") || fail "raw pointer spawn failed: $out"
  argvlog="$TMP_ROOT/argv/raw-harness.argv"
  mkdir -p "$(dirname "$argvlog")"
  execute_launch_line "$LAUNCH_LOG" "$argvlog" "$FAKEBIN_DIR" raw-harness \
    || fail "could not execute the emitted raw launch line"
  grep -Fq 'Read the brief at' "$argvlog" \
    || fail "raw launch argv lost the pointer instruction"
  grep -Fq "$HOME_DIR/data/$CASE_ID/brief.md" "$argvlog" \
    || fail "raw launch pointer did not name the absolute brief path"
  if grep -Fq "$SENTINEL" "$argvlog"; then
    fail "raw launch expanded the brief body into agent argv"
  fi

  rec=$(make_case raw-brief raw-harness)
  read_case "$rec"
  raw_launch='raw-harness "$(__OPINPUT__ encode launch-brief < __BRIEF__)"'
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$CASE_ID" "$PROJ_DIR" "$raw_launch") \
    && fail "raw launch accepted __BRIEF__ as prompt input"
  case "$out" in
    *"use __BRIEFPOINTER__ for the prompt argument"*) ;;
    *) fail "raw __BRIEF__ refusal did not name the pointer contract (got: $out)" ;;
  esac
  [ ! -s "$LAUNCH_LOG" ] \
    || fail "raw __BRIEF__ refusal emitted a launch command"
  pass "raw launches use the pointer contract and refuse brief-body expansion"
}

# An unwritable pointer must stop the spawn. Launching anyway would hand the
# agent an empty prompt and leave a silently idle worker holding a worktree.
test_unwritable_pointer_refuses_the_spawn() {
  local rec out
  rec=$(make_case refuse claude)
  read_case "$rec"
  # Obstruct exactly the pointer path and nothing else: a directory in its place
  # fails the write while every other spawn step still works, so the case proves
  # the pointer guard rather than some earlier unrelated failure.
  mkdir -p "$HOME_DIR/state/$CASE_ID.launch-pointer"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$CASE_ID" "$PROJ_DIR" claude) \
    && fail "spawn must refuse when the launch pointer cannot be written"
  case "$out" in
    *"launch-brief pointer"*) ;;
    *) fail "refusal must name the launch pointer (got: $out)" ;;
  esac
  pass "an unwritable launch pointer refuses the spawn instead of launching empty"
}

test_brief_body_never_reaches_agent_argv
test_pointer_is_a_complete_instruction
test_every_prompt_bearing_harness_is_covered
test_raw_launch_uses_pointer_and_refuses_brief_expansion
test_unwritable_pointer_refuses_the_spawn

echo "# all fm-spawn-brief-argv tests passed"
