#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

unset TASKS_AXI_BACKEND || :

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-sol-cap)
HAVE_TASKS_AXI=0
command -v tasks-axi >/dev/null 2>&1 && HAVE_TASKS_AXI=1

# --- fixture ----------------------------------------------------------------

write_brief() {  # <home> <id>
  mkdir -p "$1/data/$2"
  cat > "$1/data/$2/brief.md" <<IFEOF
# Task
## Captain's intent
Run a Sol-routed task for $2.

## Firstmate spec
Exercise the Sol session ceiling.

# Definition of done
Delivery contract: mode=no-mistakes
IFEOF
}

add_item() {  # <home> <id>
  [ "$HAVE_TASKS_AXI" = 1 ] || return 0
  tasks-axi add "$2" "item for $2" --kind ship --file "$1/data/backlog.md" >/dev/null
}

# A Firstmate home with a dispatch table naming the two Sol rows the fleet
# files under gpt-6, plus one GLM row, and a brief for every named task.
# The capped-session guard is OFF unless the captain declares it, so the
# fixture home carries the declaration that opts it in: the ceiling it
# enforces and the model ids that ceiling covers.
make_home() {  # <home> [task-id...]
  local home=$1 id
  shift
  mkdir -p "$home/state" "$home/config" "$home/data" "$home/projects"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' codex > "$home/config/crew-harness"
  cat > "$home/config/crew-dispatch.json" <<'J'
{"rules":[
 {"when":"Rated complexity 8.","use":{"harness":"codex","model":"gpt-6.1-sol","effort":"medium"}},
 {"when":"Rated complexity 7 when every GLM lane is working.","use":{"harness":"codex","model":"gpt-6.1-sol","effort":"medium"}},
 {"when":"Rated complexity 6.","use":{"harness":"codex","model":"gpt-6-sol","effort":"medium"}},
 {"when":"GLM lanes route themselves.","use":{"harness":"codex","model":"gpt-5.6-luna","effort":"low"}}
]}
J
  cat > "$home/config/sol-cap" <<'SOL'
max=4
models=gpt-6.1-sol|gpt-6-sol
SOL
  if [ "$HAVE_TASKS_AXI" = 1 ]; then
    printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' \
      > "$home/data/backlog.md"
    cat > "$home/.tasks.toml" <<'TOML'
backend = "markdown"

[markdown]
path = "data/backlog.md"
TOML
  fi
  for id in "$@"; do
    write_brief "$home" "$id"
    add_item "$home" "$id"
  done
}

make_case() {  # <name> [task-id...]
  local name=$1 case_dir fakebin
  shift
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir"
  fakebin=$(fm_fakebin "$case_dir")
  : > "$case_dir/calls.log"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_CALL_LOG"
window_file="$FM_FAKE_CALL_LOG.window"
case "${1:-}" in
  display-message)
    case "$*" in
    *"#{pane_current_path}"*)
      printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
      ;;
    *)
      printf 'firstmate\n'
      ;;
    esac
    ;;
  list-windows) [ ! -s "$window_file" ] || cat "$window_file" ;;
  list-panes) printf '%s\n' "${FM_TEST_PANE_PID:-0}" ;;
  new-window)
    name=
    previous=
    for arg in "$@"; do
      [ "$previous" = -n ] && name=$arg
      previous=$arg
    done
    grep -Fqx -- "$name" "$window_file" 2>/dev/null || printf '%s\n' "$name" >> "$window_file"
    ;;
  kill-window)
    [ "${FM_TEST_CLOSE_FAIL:-0}" != 1 ] || exit 1
    target=
    previous=
    for arg in "$@"; do
      [ "$previous" = -t ] && target=$arg
      previous=$arg
    done
    target=${target##*:}
    target=${target#=}
    grep -Fvx -- "$target" "$window_file" 2>/dev/null > "$window_file.tmp" || true
    mv "$window_file.tmp" "$window_file"
    ;;
  has-session|new-session) : ;;
  send-keys)
    # A spawn types a short line sourcing its staged launch file, so record the
    # staged command itself: what the pane shell would source is what a launch
    # assertion needs, not the short source line. Other literals are ignored.
    previous=
    for arg in "$@"; do
      if [ "$previous" = -l ]; then
        case "$arg" in
          ". '"*"'")
            staged=${arg#". '"}
            staged=${staged%"'"}
            if [ -f "$staged" ]; then
              cat "$staged" >> "$FM_FAKE_CALL_LOG.launch"
              printf '%s\n' "$staged" >> "$FM_FAKE_CALL_LOG.launchpath"
            fi
            ;;
        esac
      fi
      previous=$arg
    done
    ;;
esac
exit 0
SH
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf 'treehouse %s\n' "$*" >> "$FM_FAKE_CALL_LOG"
exit 0
SH
  chmod +x "$fakebin/tmux" "$fakebin/treehouse"
  fm_fake_exit0 "$fakebin" gh gh-axi no-mistakes
  fm_git_init_commit "$case_dir/project"
  fm_git_add_origin "$case_dir/project" "$case_dir/project.origin.git"
  make_home "$case_dir/home" "$@"
  printf '%s\n' "$case_dir"
}

write_sol_row() {  # <home> <id> <start-epoch> [pid] [model]
  local home=$1 id=$2 start=$3 pid=${4:-0} model=${5:-gpt-6.1-sol}
  printf '%s\t%s\t%s\t%s\n' "$id" "$model" "$start" "$pid" >> "$home/state/sol-sessions.tsv"
}

registry_row_field() {  # <case-dir> <id> <field 2=model 4=pid>
  awk -F'\t' -v id="$2" -v col="$3" '$1 == id {print $col; exit}' \
    "$1/home/state/sol-sessions.tsv"
}

registry_has_row() {  # <case-dir> <id> <model>
  grep -Fq "$(printf '%s\t%s\t' "$2" "$3")" "$1/home/state/sol-sessions.tsv"
}

new_worktree() {  # <case-dir> <name>
  git -C "$1/project" worktree add --quiet -b "wt-$2" "$1/wt-$2"
  printf '%s\n' "$1/wt-$2"
}

run_spawn() {  # <case-dir> <home> <pane-path> <args...>
  local case_dir=$1 home=$2 pane=$3
  shift 3
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_BACKEND=tmux FM_TEST_PANE_PID="$FM_SOL_TEST_LIVE_PID" \
    FM_FAKE_PANE_PATH="$pane" FM_FAKE_CALL_LOG="$case_dir/calls.log" \
    PATH="$case_dir/fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

spawn_sol_ship() {  # <case-dir> <id> [model] [pane-path]
  local case_dir=$1 id=$2 model=${3:-gpt-6.1-sol} pane=${4:-}
  [ -n "$pane" ] || pane=$(new_worktree "$case_dir" "$id")
  run_spawn "$case_dir" "$case_dir/home" "$pane" \
    "$id" "$case_dir/project" --harness codex --model "$model" --mode no-mistakes --yolo off
}

# A raw launch command carrying pane-shell-only syntax, the escape hatch a
# capped launch must not reinterpret: `$(cat <(...))` is process substitution,
# which POSIX sh rejects outright, so a launch that reaches the worker at all
# was parsed by the pane's own shell. It records the argv it was handed, so two
# launches can be compared by the invocation they produced.
# shellcheck disable=SC2016 # the pane shell expands this text, not this file.
FM_SOL_TEST_RAW='codex --brief "$(cat <(printf %s pane-syntax))"'

# The stand-ins a raw launch needs: a `paneshell` that is the same bash the
# uncapped case would run but named like the pane it stands in for, because the
# handoff reads the sourcing shell's executable name from the process tree now
# that the staged line carries no report of its own, and a `codex` that records
# the argv it received plus the interpreter that ran it.
add_raw_launch_probe() {  # <case-dir>
  local fakebin=$1/fakebin
  cp "$(command -v bash)" "$fakebin/paneshell"
  cat > "$fakebin/codex" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_INVOCATION_LOG.argv"
printf '%s\n' "$(basename -- "$(ps -o comm= -p "$PPID" 2>/dev/null)")" >> "$FM_FAKE_INVOCATION_LOG.shell"
SH
  chmod +x "$fakebin/paneshell" "$fakebin/codex"
}

spawn_raw_ship() {  # <case-dir> <id> [raw-command]
  local case_dir=$1 id=$2 raw=${3:-$FM_SOL_TEST_RAW} pane
  pane=$(new_worktree "$case_dir" "$id")
  FM_FAKE_INVOCATION_LOG="$case_dir/invocation" \
    run_spawn "$case_dir" "$case_dir/home" "$pane" \
      "$id" "$case_dir/project" --harness "$raw" --model gpt-6.1-sol --mode no-mistakes --yolo off
}

# A fish pane's launch command: `(printf ...)` is fish's command substitution,
# which a POSIX shell rejects, so a launch that reaches the worker at all was
# parsed by fish.
# shellcheck disable=SC2016 # the pane shell expands this text, not this file.
FM_SOL_TEST_FISH_RAW='codex --brief (printf %s fish-pane)'

# Run the staged launch the way its pane would: source the very file the pane
# received, from the pane-shell stand-in. Sourcing rather than `-c` is what keeps
# the stand-in in the process tree, which is how the handoff names it.
run_staged_launch() {  # <case-dir>
  local case_dir=$1 file
  file=$(staged_launch_file "$case_dir")
  [ -n "$file" ] || fail "the spawn for $case_dir staged no launch file"
  (cd "$case_dir/project" &&
    FM_FAKE_INVOCATION_LOG="$case_dir/invocation" \
      PATH="$case_dir/fakebin:$PATH" "$case_dir/fakebin/paneshell" -c ". \"\$1\"" _ "$file") 2>&1
}

# The staged launch line a spawn handed the pane, i.e. what the pane shell
# would source. The fake tmux records one per send-keys of a source line.
staged_launch_line() {  # <case-dir>
  tail -1 "$1/calls.log.launch" 2>/dev/null || true
}

# The staged launch file itself, as the pane was told to source it.
staged_launch_file() {  # <case-dir>
  tail -1 "$1/calls.log.launchpath" 2>/dev/null || true
}

call_count() { wc -l < "$1/calls.log" | tr -d ' '; }

worktree_list() { git -C "$1/project" worktree list --porcelain; }

# Everything a refused spawn must not have created for <id>; <worktrees-before>
# is worktree_list taken before the spawn.
assert_nothing_created() {  # <case-dir> <id> <calls-before> <worktrees-before>
  local case_dir=$1 id=$2 before=$3 worktrees=$4 after
  assert_absent "$case_dir/home/state/$id.meta" "a refused spawn published a task record for $id"
  assert_absent "$case_dir/home/data/$id/launch-brief.md" "a refused spawn rendered a launch brief for $id"
  after=$(call_count "$case_dir")
  [ "$after" -eq "$before" ] ||
    fail "a refused spawn touched the terminal or worktree pool for $id: $(tail -n +"$((before + 1))" "$case_dir/calls.log")"
  assert_equals "$worktrees" "$(worktree_list "$case_dir")" "a refused spawn left a git worktree for $id"
}

FM_SOL_TEST_LIVE_PID=$$

fresh_start() {
  date +%s
}

# --- cases ------------------------------------------------------------------

test_under_cap_sol_spawn_launches_and_claims_its_slot() {
  local case_dir out pid
  case_dir=$(make_case under-cap task-c)
  write_sol_row "$case_dir/home" live-a "$(fresh_start)"
  write_sol_row "$case_dir/home" live-b "$(fresh_start)"
  write_sol_row "$case_dir/home" live-c "$(fresh_start)"
  out=$(spawn_sol_ship "$case_dir" task-c) || fail "an under-cap Sol spawn was refused: $out"
  assert_contains "$out" "spawned task-c" "an under-cap Sol spawn did not launch the worker"
  kill -0 "$FM_SOL_TEST_LIVE_PID" 2>/dev/null || fail "the test's pane pid is not alive"
  pid=$(registry_row_field "$case_dir" task-c 4)
  [ "$pid" = 0 ] ||
    fail "a launched Sol session's registry row kept its reservation pid: $pid"
  registry_has_row "$case_dir" task-c gpt-6.1-sol ||
    fail "a launched Sol session did not claim its registry row"
  pass "a Sol delivery under the ceiling retains a conservative claim"
}

# The ceiling refuses the fifth concurrent Sol dispatch with one actionable
# error naming each active session and its age, and the refusal leaves no
# task record, no rendered brief, no endpoint touch, and no worktree behind.
# The ceiling gates admission only: it must never change the command a capped
# launch runs. Uncapped, the pane shell sources the raw command line; capped,
# the same bytes ride behind the reservation handoff, which hands them back to
# that same shell. Both launches must therefore produce one identical worker
# invocation, and the capped one must run under the pane's shell rather than a
# substituted interpreter, which is what process substitution proves here.
test_capped_launch_keeps_the_uncapped_command_invocation() {
  local capped_case uncapped_case out capped_line uncapped_line rc=0
  capped_case=$(make_case launch-shape-capped task-c)
  uncapped_case=$(make_case launch-shape-uncapped task-c)
  # The control case is the same dispatch with the guard inert, so the only
  # difference between the two staged lines is the admission handoff.
  rm -f "$uncapped_case/home/config/sol-cap"
  add_raw_launch_probe "$capped_case"
  add_raw_launch_probe "$uncapped_case"
  out=$(spawn_raw_ship "$uncapped_case" task-c) || fail "the uncapped raw launch was refused: $out"
  uncapped_line=$(staged_launch_line "$uncapped_case")
  assert_contains "$uncapped_line" "$FM_SOL_TEST_RAW" \
    "an uncapped launch no longer stages the raw command unchanged"
  out=$(spawn_raw_ship "$capped_case" task-c) || fail "the capped raw launch was refused: $out"
  capped_line=$(staged_launch_line "$capped_case")
  [ "$capped_line" != "$uncapped_line" ] ||
    fail "a capped launch staged no admission handoff: $capped_line"
  assert_contains "$capped_line" "$FM_SOL_TEST_RAW" \
    "a capped launch rewrote the raw command instead of handing it through"
  run_staged_launch "$uncapped_case" || rc=$?
  expect_code 0 "$rc" "the uncapped staged line did not run"
  rc=0
  run_staged_launch "$capped_case" || rc=$?
  expect_code 0 "$rc" "the capped staged line did not run: $(cat "$capped_case/invocation.shell" 2>/dev/null)"
  assert_equals "--brief pane-syntax" "$(cat "$uncapped_case/invocation.argv")" \
    "the uncapped launch did not run the raw command it staged"
  assert_equals "$(cat "$uncapped_case/invocation.argv")" "$(cat "$capped_case/invocation.argv")" \
    "a capped launch changed the command a raw launch runs"
  assert_equals paneshell "$(cat "$capped_case/invocation.shell")" \
    "a capped launch handed the command to an interpreter other than the pane shell"
  [ "$(registry_row_field "$capped_case" task-c 4)" != 0 ] ||
    fail "the capped launch did not transfer its reservation to the worker's process"
  pass "a capped launch runs the uncapped command unchanged under the pane shell"
}

# Fish has no $0, so a staged capped launch that named the pane shell with a
# shell expression would leave the handoff without the pane's identity and fall
# back to another interpreter. This case sources the very staged file with fish
# and compares the worker invocation against the uncapped control, so the handoff
# has to reach the same shell and the same bytes. Without fish the live case
# cannot run; the emitted handoff is checked for the expressions fish cannot
# parse and the live case is reported as skipped rather than claimed.
test_capped_launch_survives_a_fish_pane() {
  local capped_case uncapped_case out fish_bin line handoff rc=0
  capped_case=$(make_case launch-fish-capped task-c)
  uncapped_case=$(make_case launch-fish-uncapped task-c)
  rm -f "$uncapped_case/home/config/sol-cap"
  add_raw_launch_probe "$capped_case"
  add_raw_launch_probe "$uncapped_case"
  out=$(spawn_raw_ship "$uncapped_case" task-c "$FM_SOL_TEST_FISH_RAW") ||
    fail "the uncapped fish launch was refused: $out"
  out=$(spawn_raw_ship "$capped_case" task-c "$FM_SOL_TEST_FISH_RAW") ||
    fail "the capped fish launch was refused: $out"
  line=$(staged_launch_line "$capped_case")
  assert_contains "$line" "$FM_SOL_TEST_FISH_RAW" \
    "a capped fish launch rewrote the command instead of handing it through"
  fish_bin=$(command -v fish 2>/dev/null) || fish_bin=
  if [ -z "$fish_bin" ]; then
    handoff=${line%%"$FM_SOL_TEST_FISH_RAW"*}
    # shellcheck disable=SC2016 # these are literal shell tokens fish rejects.
    case "$handoff" in
      *'$0'* | *'$('* | *'${'* | *'`'*)
        fail "the capped launch handoff uses a shell expression fish cannot parse: $handoff" ;;
    esac
    echo "skip: fish not found (fish pane launch); only a static handoff check ran"
    pass "the capped launch handoff carries no syntax fish rejects"
    return
  fi
  out=$(run_staged_launch_in_fish "$uncapped_case" "$fish_bin") || rc=$?
  expect_code 0 "$rc" "a fish pane could not source the uncapped launch: $out"
  assert_equals "--brief fish-pane" "$(cat "$uncapped_case/invocation.argv")" \
    "the uncapped fish launch did not run the command it staged"
  assert_equals fish "$(cat "$uncapped_case/invocation.shell")" \
    "the uncapped fish launch did not run under fish"
  rc=0
  out=$(run_staged_launch_in_fish "$capped_case" "$fish_bin") || rc=$?
  expect_code 0 "$rc" "a fish pane could not source the capped launch: $out"
  assert_equals "$(cat "$uncapped_case/invocation.argv")" "$(cat "$capped_case/invocation.argv")" \
    "a capped launch changed the command a fish pane runs"
  assert_equals fish "$(cat "$capped_case/invocation.shell")" \
    "a capped launch handed the command to an interpreter other than the fish pane"
  [ "$(registry_row_field "$capped_case" task-c 4)" != 0 ] ||
    fail "the capped fish launch did not transfer its reservation to the worker's process"
  pass "a capped launch runs the uncapped command unchanged in a fish pane"
}

# Source the staged launch file in fish, with the login shell pinned away so a
# handoff that failed to name fish cannot silently inherit it.
run_staged_launch_in_fish() {  # <case-dir> <fish>
  local case_dir=$1 fish_bin=$2 file
  file=$(staged_launch_file "$case_dir")
  [ -n "$file" ] || fail "the spawn for $case_dir staged no launch file"
  (cd "$case_dir/project" &&
    env -u SHELL FM_FAKE_INVOCATION_LOG="$case_dir/invocation" \
      PATH="$case_dir/fakebin:$PATH" "$fish_bin" -c "source \$argv[1]" "$file") 2>&1
}

# The handoff still needs an interpreter when the pane shell cannot be named, so
# an unusable report falls back to a shell that runs every generated launch line
# and a POSIX-only one survives it.
test_run_launch_falls_back_when_the_pane_shell_is_unusable() {
  local case_dir out rc=0
  case_dir=$(make_case launch-fallback task-c)
  write_sol_row "$case_dir/home" task-c "$(fresh_start)"
  out=$(FM_HOME="$case_dir/home" SHELL='' bash "$ROOT/bin/fm-sol-cap-lib.sh" \
    run-launch task-c "$case_dir/home/state" 'printf %s fallback-ran' /nonexistent/pane-shell) || rc=$?
  expect_code 0 "$rc" "an unresolvable pane shell refused the launch"
  assert_contains "$out" fallback-ran "an unresolvable pane shell did not fall back to a working shell"
  pass "an unnamed pane shell falls back to a shell that runs the launch line"
}

test_cap_refuses_the_fifth_and_names_its_sessions() {
  local case_dir out before rc=0
  case_dir=$(make_case at-cap task-c)
  write_sol_row "$case_dir/home" s1 "$(fresh_start)"
  write_sol_row "$case_dir/home" s2 "$(fresh_start)"
  write_sol_row "$case_dir/home" s3 "$(fresh_start)"
  write_sol_row "$case_dir/home" s4 "$(fresh_start)" 0 gpt-6-sol
  before=$(call_count "$case_dir")
  worktrees=$(worktree_list "$case_dir")
  out=$(spawn_sol_ship "$case_dir" task-c gpt-6.1-sol "$case_dir/unused") || rc=$?
  expect_code 1 "$rc" "a spawn at the Sol ceiling was not refused: $out"
  assert_contains "$out" "Sol ceiling reached" "the refusal did not name the Sol ceiling"
  assert_contains "$out" "task-c (codex, gpt-6.1-sol) was refused" \
    "the refusal did not name the refused dispatch's task and model"
  assert_contains "$out" "s1 (gpt-6.1-sol" "the refusal did not name active session s1"
  assert_contains "$out" "s4 (gpt-6-sol" "the refusal did not name the gpt-6-sol session"
  assert_contains "$out" "age" "the refusal did not name the active sessions' ages"
  assert_contains "$out" "config/sol-cap" "the refusal did not name the ceiling's override file"
  assert_nothing_created "$case_dir" task-c "$before" "$worktrees"
  pass "a dispatch at the ceiling is refused, naming sessions and ages, and creates nothing"
}

test_stale_entries_do_not_count() {
  local case_dir out old sleep_lab
  case_dir=$(make_case stale task-c)
  write_sol_row "$case_dir/home" s1 "$(fresh_start)"
  write_sol_row "$case_dir/home" s2 "$(fresh_start)"
  write_sol_row "$case_dir/home" s3 "$(fresh_start)"
  old=$(( "$(fresh_start)" - 21601 ))
  write_sol_row "$case_dir/home" aged-junk "$old" 99999999
  sleep_lab=99999998
  write_sol_row "$case_dir/home" dead-junk "$(fresh_start)" "$sleep_lab"
  out=$(spawn_sol_ship "$case_dir" task-c) || fail "a spawn whose ceiling has stale room was refused: $out"
  assert_contains "$out" "spawned task-c" "a spawn freed by stale entries did not launch"
  # Both stale rows are pruned out; the three live rows plus the new claim
  # are what is left.
  [ ! "$(registry_row_field "$case_dir" aged-junk 1)" ] ||
    fail "a stale-by-age row stayed in the registry"
  [ ! "$(registry_row_field "$case_dir" dead-junk 1)" ] ||
    fail "a stale-by-dead-pid row stayed in the registry"
  [ "$(wc -l < "$case_dir/home/state/sol-sessions.tsv" | tr -d ' ')" -eq 4 ] ||
    fail "the registry did not end with 3 live rows plus the new claim"
  pass "dead workers are pruned regardless of age"
}

# A non-Sol model never touches the ceiling: a GLM-routed dispatch passes a
# full ceiling and leaves the registry byte-identical except for nothing.
test_non_sol_model_never_claims_a_slot() {
  local case_dir out before rc=0
  case_dir=$(make_case glm task-c)
  write_sol_row "$case_dir/home" s1 "$(fresh_start)"
  write_sol_row "$case_dir/home" s2 "$(fresh_start)"
  write_sol_row "$case_dir/home" s3 "$(fresh_start)"
  write_sol_row "$case_dir/home" s4 "$(fresh_start)"
  write_sol_row "$case_dir/home" task-c 1 "$$"
  cp "$case_dir/home/state/sol-sessions.tsv" "$TMP_ROOT/glm-registry-before.tsv"
  mkdir "$case_dir/home/state/.sol-cap.lock"
  printf '%s\n' "$$" > "$case_dir/home/state/.sol-cap.lock/pid"
  out=$(spawn_sol_ship "$case_dir" task-c gpt-5.6-luna) || rc=$?
  expect_code 0 "$rc" "a non-Sol dispatch was refused by the Sol ceiling: $out"
  assert_contains "$out" "spawned task-c" "a non-Sol dispatch did not launch"
  assert_equals "$(cat "$TMP_ROOT/glm-registry-before.tsv")" \
    "$(cat "$case_dir/home/state/sol-sessions.tsv")" \
    "a non-Sol dispatch changed the Sol registry"
  pass "a non-Sol model dispatch passes a full ceiling and touches no registry row"
}

# The ceiling is the captain's own declaration: config/sol-cap names the
# value the guard enforces and the models it covers, and the guard is inert
# without that file.
test_config_sol_cap_declares_the_ceiling() {
  local case_dir out before rc=0
  case_dir=$(make_case override task-c)
  write_sol_row "$case_dir/home" s1 "$(fresh_start)"
  write_sol_row "$case_dir/home" s2 "$(fresh_start)"
  printf 'max=4\nceiling=2\nmodels=gpt-6.1-sol|gpt-6-sol\n' > "$case_dir/home/config/sol-cap"
  before=$(call_count "$case_dir")
  worktrees=$(worktree_list "$case_dir")
  out=$(spawn_sol_ship "$case_dir" task-c gpt-6.1-sol "$case_dir/unused") || rc=$?
  expect_code 1 "$rc" "a spawn over its declared ceiling was not refused: $out"
  assert_contains "$out" "this ceiling is 2" "the refusal did not use the declared ceiling"
  assert_nothing_created "$case_dir" task-c "$before" "$worktrees"
  pass "config/sol-cap declares the ceiling the guard enforces"
}

# A home that never declared a ceiling has none: the guard reserves nothing,
# counts nothing, and leaves the registry untouched even when the declared
# models are already at their ceiling.
test_no_declaration_leaves_the_guard_inert() {
  local case_dir out rc=0
  case_dir=$(make_case inert task-c)
  rm -f -- "$case_dir/home/config/sol-cap"
  write_sol_row "$case_dir/home" s1 "$(fresh_start)"
  write_sol_row "$case_dir/home" s2 "$(fresh_start)"
  write_sol_row "$case_dir/home" s3 "$(fresh_start)"
  write_sol_row "$case_dir/home" s4 "$(fresh_start)"
  cp "$case_dir/home/state/sol-sessions.tsv" "$TMP_ROOT/inert-registry-before.tsv"
  out=$(spawn_sol_ship "$case_dir" task-c) || rc=$?
  expect_code 0 "$rc" "a home that declared no ceiling was refused: $out"
  assert_contains "$out" "spawned task-c" "a home that declared no ceiling did not dispatch"
  assert_equals "$(cat "$TMP_ROOT/inert-registry-before.tsv")" \
    "$(cat "$case_dir/home/state/sol-sessions.tsv")" \
    "a home that declared no ceiling changed the registry"
  pass "a home that declared no ceiling has no ceiling, no reservation, and no registry row"
}

# The declared model set is exactly what the captain wrote: a model the
# declaration does not name is never capped, and a declared pattern covers
# the model ids the captain matched on.
test_declared_model_set_is_the_only_capped_set() {
  local case_dir out
  case_dir=$(make_case model-set task-c)
  printf 'max=2\nmodel-pattern=^gpt-[0-9.]+-sol$\n' > "$case_dir/home/config/sol-cap"
  out=$(lib_refuse_claim "$case_dir" task-c gpt-6.1-sol) || fail "a declared pattern did not cover its model: $out"
  assert_equals "$out" "claimed" "a declared pattern did not claim its model"
  out=$(lib_refuse_claim "$case_dir" task-d gpt-5.6-luna) || fail "an undeclared model was refused: $out"
  assert_equals "$out" "not-capped" "an undeclared model was capped"
  printf 'max=1\nmodel-pattern=^gpt-[0-9.]+-sol$\n' > "$case_dir/home/config/sol-cap"
  write_sol_row "$case_dir/home" live "$(fresh_start)" 0
  out=$(lib_refuse_claim "$case_dir" task-e gpt-6-sol) || true
  assert_contains "$out" "ceiling reached" "the declared ceiling was not enforced"
  # A declared pattern that begins with a dash is a pattern, not a grep
  # option: an option-shaped pattern would silently cover nothing.
  printf 'max=1\nmodel-pattern=-sol$\n' > "$case_dir/home/config/sol-cap"
  out=$(lib_refuse_claim "$case_dir" task-f gpt-6-sol) || true
  assert_contains "$out" "ceiling reached" "a dash-leading declared pattern matched nothing"
  pass "only the models the captain declared are capped, by exact id or by declared pattern"
}



# A replacement dispatched onto a model the declaration no longer covers must
# not leave the prior incarnation's row behind: that row names this task's id
# while describing a session that has exited, and adoption skips it, so a
# later declaration would leave the replacement uncounted.
test_a_replacement_on_an_excluded_model_invalidates_the_prior_row() {
  local case_dir out
  case_dir=$(make_case excluded-replacement task-c)
  write_sol_row "$case_dir/home" task-c "$(fresh_start)" 99999999
  fm_write_meta "$case_dir/home/state/task-c.meta" "model=gpt-6.1-sol" "kind=ship"
  printf 'max=4\nmodels=gpt-6-sol\n' > "$case_dir/home/config/sol-cap"
  out=$(lib_refuse_claim "$case_dir" task-c gpt-6.1-sol) || fail "the dispatch was refused: $out"
  assert_equals "$out" "not-capped" "an excluded model claimed a slot"
  assert_equals "$(registry_row_field "$case_dir" task-c 4)" "-3" \
    "a replacement on an excluded model did not mark the prior incarnation's row superseded"
  pass "a replacement on an excluded model marks the prior incarnation's row superseded"
}

# A row marked superseded by a replacement is resolved by the next adoption:
# the row is the prior incarnation's, and the metadata names the worker that
# holds the slot now.
test_the_adoption_resolves_a_superseded_row() {
  local case_dir state
  case_dir=$(make_case superseded)
  state=$case_dir/home/state
  FM_HOME=$case_dir/home
  . "$ROOT/bin/fm-wake-lib.sh"
  . "$ROOT/bin/fm-secondmate-registry-lib.sh"
  . "$ROOT/bin/fm-sol-cap-lib.sh"
  fm_backend_of_meta() { printf tmux; }
  fm_backend_target_of_meta() { printf '%s' "${1##*/}"; }
  fm_backend_agent_state() { printf alive; }
  fm_write_meta "$state/one.meta" "model=gpt-6.1-sol" "kind=ship"
  printf 'one\tgpt-6.1-sol\t1\t-3\n' > "$state/sol-sessions.tsv"
  fm_sol_cap_active_count "$state" || fail "the adoption failed"
  [ "$(registry_row_field "$case_dir" one 4)" = "-2" ] || fail "the superseded row was not resolved"
  pass "the adoption resolves a superseded row into the live incarnation it names"
}

# A replacement that never completes must not consume capacity: the row it
# marked superseded claims no slot, so the next capped dispatch still fits.
test_an_abandoned_replacement_consumes_no_capacity() {
  local case_dir out
  case_dir=$(make_case abandoned task-c)
  # A confirmed cleanup left a stopped row and removed the task's metadata.
  write_sol_row "$case_dir/home" task-c "$(fresh_start)" -1
  rm -f -- "$case_dir/home/config/sol-cap"
  out=$(lib_refuse_claim "$case_dir" task-c gpt-6.1-sol) || fail "the dispatch was refused: $out"
  assert_equals "$(registry_row_field "$case_dir" task-c 4)" "-3" \
    "the abandoned replacement did not mark the prior incarnation's row"
  printf 'max=1\nmodels=gpt-6.1-sol\n' > "$case_dir/home/config/sol-cap"
  out=$(lib_refuse_claim "$case_dir" task-d gpt-6.1-sol) || fail "an abandoned replacement consumed the capacity: $out"
  assert_equals "$out" "claimed" "an abandoned replacement consumed the capacity"
  pass "an abandoned replacement leaves no capacity behind"
}

# A row whose session is still live holds its slot: a dispatch that has not
# displaced that session yet must not release its occupancy.
test_a_live_row_is_not_superseded() {
  local case_dir out
  case_dir=$(make_case live-row task-c)
  write_sol_row "$case_dir/home" task-c "$(fresh_start)" 0
  fm_write_meta "$case_dir/home/state/task-c.meta" "model=gpt-6.1-sol" "kind=ship"
  rm -f -- "$case_dir/home/config/sol-cap"
  out=$(lib_refuse_claim "$case_dir" task-c gpt-6.1-sol) || fail "the dispatch was refused: $out"
  assert_equals "0" "$(registry_row_field "$case_dir" task-c 4)" \
    "a dispatch that displaced no session released its occupancy"
  pass "a live row is not superseded by a dispatch that displaced no session"
}

# The admission boundary may stay busy past the brief wait an invalidation
# allows: another live process holds it while a fresh process drives the
# replacement. The uncapped replacement must still continue, and the
# invalidation it could not apply itself must survive as a pending marker that
# the next admission applies under the boundary before it counts, or the live
# replacement would sit behind a row that claims no slot.
#
# Start the boundary hold, drive the excluded-model replacement of task-c, and
# return with the pending marker recorded and the declaration restored. Fails
# when the replacement was refused, when the busy boundary let it rewrite the
# registry, or when it lost the invalidation.
busy_boundary_replacement() {  # <case-dir>
  local case_dir=$1 lock=$1/home/state/.sol-cap.lock out
  mkdir "$lock" || fail "the test could not hold the admission boundary"
  printf '%s\n' "$$" > "$lock/pid"
  # The declaration excludes the replacement's model, so the replacement
  # reserves no slot and its invalidation is the best-effort path.
  printf 'max=4\nmodels=gpt-6-sol\n' > "$case_dir/home/config/sol-cap"
  out=$(lib_refuse_claim "$case_dir" task-c gpt-6.1-sol) || {
    rm -rf -- "$lock"
    fail "a busy admission boundary refused an uncapped replacement: $out"
  }
  assert_equals "$out" "not-capped" "an uncapped replacement claimed a slot"
  rm -rf -- "$lock"
  assert_equals "-1" "$(registry_row_field "$case_dir" task-c 4)" \
    "a busy admission boundary let the invalidation rewrite the registry outside it"
  assert_present "$case_dir/home/state/.sol-cap-supersede-task-c" \
    "a busy admission boundary lost the replacement's pending invalidation"
  # The declaration is restored to cover the replacement, so the next
  # admission must resolve the marker rather than leave the row behind.
  printf 'max=4\nmodels=gpt-6.1-sol\n' > "$case_dir/home/config/sol-cap"
}

# The next admission after a pending invalidation runs from a fresh process
# against the real registry, declaration, and marker files; the endpoint state
# this fixture cannot provide is stubbed, as the adoption cases above do.
# Prints "claimed" or the refusal message.
admit_after_pending() {  # <case-dir> <id> <model>
  local case_dir=$1 id=$2 model=$3
  (
    FM_HOME=$case_dir/home
    . "$ROOT/bin/fm-wake-lib.sh"
    . "$ROOT/bin/fm-secondmate-registry-lib.sh"
    . "$ROOT/bin/fm-sol-cap-lib.sh"
    fm_backend_of_meta() { printf tmux; }
    fm_backend_target_of_meta() { printf '%s' "${1##*/}"; }
    fm_backend_agent_state() { printf alive; }
    if ! fm_sol_cap_refuse_and_claim "$id" ship codex "$model" \
      "$case_dir/home/config" "$case_dir/home/state"; then
      printf '%s\n' "$FM_SOL_CAP_REFUSAL"
      exit 1
    fi
    printf '%s\n' claimed
  )
}

test_a_busy_boundary_replacement_lands_its_pending_supersede() {
  local case_dir out
  case_dir=$(make_case pending-supersede task-c task-d)
  write_sol_row "$case_dir/home" task-c "$(fresh_start)" -1
  fm_write_meta "$case_dir/home/state/task-c.meta" "model=gpt-6.1-sol" "kind=ship"
  busy_boundary_replacement "$case_dir"
  out=$(admit_after_pending "$case_dir" task-d gpt-6.1-sol) ||
    fail "the next admission failed: $out"
  assert_equals "$out" "claimed" "the next admission did not claim its own slot"
  assert_absent "$case_dir/home/state/.sol-cap-supersede-task-c" \
    "the pending invalidation survived the next admission"
  assert_equals "-2" "$(registry_row_field "$case_dir" task-c 4)" \
    "the next admission did not supersede the prior incarnation's row"
  pass "a busy admission boundary keeps the invalidation pending and the next admission supersedes the prior row"
}

test_pending_publication_is_invisible_until_rename() (
  local case_dir state
  case_dir=$(make_case pending-publication task-c)
  state=$case_dir/home/state
  FM_HOME=$case_dir/home
  . "$ROOT/bin/fm-wake-lib.sh"
  . "$ROOT/bin/fm-secondmate-registry-lib.sh"
  . "$ROOT/bin/fm-sol-cap-lib.sh"
  write_sol_row "$FM_HOME" task-c 1 -1
  mv() {
    fm_sol_cap_apply_pending_supersedes "$state" || return 1
    assert_equals "-1" "$(registry_row_field "$case_dir" task-c 4)" "admission consumed an unpublished marker"
    command mv "$@"
  }
  fm_sol_cap_supersede_pending "$state" task-c 1 -1 || fail "admission removed the staged marker"
  unset -f mv
  assert_present "$state/.sol-cap-supersede-task-c" "publication lost its marker"
  fm_sol_cap_apply_pending_supersedes "$state" || fail "the published marker could not be applied"
  assert_equals "-3" "$(registry_row_field "$case_dir" task-c 4)" "the published marker did not supersede its row"
  assert_absent "$state/.sol-cap-supersede-task-c" "the applied marker was not cleared"
  pass "admission cannot consume marker staging before atomic publication"
)

test_pending_publication_failure_is_reported() (
  local case_dir
  case_dir=$(make_case pending-publication-failure task-c)
  FM_HOME=$case_dir/home
  . "$ROOT/bin/fm-wake-lib.sh"
  . "$ROOT/bin/fm-secondmate-registry-lib.sh"
  . "$ROOT/bin/fm-sol-cap-lib.sh"
  write_sol_row "$FM_HOME" task-c 1 -1
  rm "$FM_HOME/config/sol-cap"
  fm_sol_cap_lock_try_briefly() { return 1; }
  mv() { return 1; }
  if fm_sol_cap_refuse_and_claim task-c ship codex gpt-6.1-sol "$FM_HOME/config" "$FM_HOME/state"; then
    fail "failed marker publication silently allowed an uncounted replacement"
  fi
  assert_contains "$FM_SOL_CAP_REFUSAL" "$FM_HOME/state" "publication failure omitted its affected state directory"
  assert_contains "$FM_SOL_CAP_REFUSAL" "permissions and free space" "publication failure omitted recovery guidance"
  assert_equals "-1" "$(registry_row_field "$case_dir" task-c 4)" "publication failure rewrote the registry"
  pass "failed marker publication reports the unavailable count"
)

test_a_busy_boundary_supersede_keeps_another_claims_row() {
  local case_dir out holder holder_pid replacement admission i
  case_dir=$(make_case pending-supersede-other task-c task-d)
  write_sol_row "$case_dir/home" task-c "$(fresh_start)" -1
  fm_write_meta "$case_dir/home/state/task-c.meta" "model=gpt-6.1-sol" "kind=ship"
  printf 'max=2\nmodels=gpt-6-sol\n' > "$case_dir/home/config/sol-cap"
  (
    FM_HOME=$case_dir/home
    . "$ROOT/bin/fm-wake-lib.sh"
    # Stock macOS Bash 3.2 has no BASHPID, so a holder that read it under `set -u`
    # would die before touching `held` and fail the case on a supported shell.
    # fm_current_pid owns that probe, and unsetting the variable here keeps this
    # case exercising the Bash 3.2 path on every host, not only on macOS.
    unset BASHPID
    fm_current_pid holder_pid || exit 1
    mkdir "$case_dir/home/state/.sol-cap.lock" || exit 1
    printf '%s\n' "$holder_pid" > "$case_dir/home/state/.sol-cap.lock/pid"
    touch "$case_dir/held"
    for ((i=0; i<400; i++)); do
      [ ! -e "$case_dir/release" ] || break
      sleep 0.05
    done
    rm -rf -- "$case_dir/home/state/.sol-cap.lock"
  ) &
  holder=$!
  for ((i=0; i<200; i++)); do
    [ ! -e "$case_dir/held" ] || break
    sleep 0.05
  done
  assert_present "$case_dir/held" "the live process did not hold the boundary"
  holder_pid=$(cat "$case_dir/home/state/.sol-cap.lock/pid" 2>/dev/null || true)
  if [ -z "$holder_pid" ] || [ "$holder_pid" = "$$" ] || ! kill -0 "$holder_pid" 2>/dev/null; then
    fail "the boundary names '$holder_pid' rather than the live process holding it"
  fi
  lib_refuse_claim "$case_dir" task-c gpt-6.1-sol > "$case_dir/replacement.out" &
  replacement=$!
  for ((i=0; i<200; i++)); do
    [ ! -e "$case_dir/home/state/.sol-cap-supersede-task-c" ] || break
    sleep 0.05
  done
  assert_present "$case_dir/home/state/.sol-cap-supersede-task-c" "the replacement did not publish its marker"
  assert_present "$case_dir/home/state/.sol-cap.lock" "the marker was not published while the boundary was held"
  wait "$replacement" || fail "the uncapped replacement failed"
  assert_equals "$(cat "$case_dir/replacement.out")" "not-capped" "contention refused the replacement"
  assert_equals "-1" "$(registry_row_field "$case_dir" task-c 4)" "the replacement rewrote the locked registry"
  printf 'max=2\nmodels=gpt-6.1-sol\n' > "$case_dir/home/config/sol-cap"
  (
    touch "$case_dir/admission-started"
    admit_after_pending "$case_dir" task-d gpt-6.1-sol > "$case_dir/admission.out"
  ) &
  admission=$!
  for ((i=0; i<200; i++)); do
    [ ! -e "$case_dir/admission-started" ] || break
    sleep 0.05
  done
  assert_present "$case_dir/admission-started" "the concurrent admission did not start"
  [ ! -s "$case_dir/admission.out" ] || fail "admission passed the held boundary"
  touch "$case_dir/release"
  wait "$holder" || fail "the boundary holder failed"
  wait "$admission" || fail "the concurrent admission failed"
  assert_equals "$(cat "$case_dir/admission.out")" "claimed" "the concurrent admission did not claim"
  assert_equals "-2" "$(registry_row_field "$case_dir" task-c 4)" "the prior row did not resolve to the replacement"
  assert_equals "gpt-6.1-sol" "$(registry_row_field "$case_dir" task-d 2)" "the concurrent claim was dropped"
  assert_absent "$case_dir/home/state/.sol-cap-supersede-task-c" "the published marker was not consumed"
  out=$(admit_after_pending "$case_dir" task-e gpt-6.1-sol) || true
  assert_contains "$out" "ceiling reached" "the concurrent sequence exceeded the ceiling"
  pass "a concurrent admission preserves its claim while applying a pending invalidation"
}

test_a_busy_boundary_replacement_counts_at_the_ceiling() {
  local case_dir out
  case_dir=$(make_case pending-supersede-ceiling task-c task-e)
  write_sol_row "$case_dir/home" task-c "$(fresh_start)" -1
  fm_write_meta "$case_dir/home/state/task-c.meta" "model=gpt-6.1-sol" "kind=ship"
  busy_boundary_replacement "$case_dir"
  printf 'max=1\nmodels=gpt-6.1-sol\n' > "$case_dir/home/config/sol-cap"
  out=$(admit_after_pending "$case_dir" task-e gpt-6.1-sol) || true
  assert_contains "$out" "ceiling reached" \
    "a capped dispatch counted above the ceiling after a busy-boundary replacement"
  assert_equals "-2" "$(registry_row_field "$case_dir" task-c 4)" \
    "the replacement the busy boundary hid was not counted"
  pass "a busy-boundary replacement holds its slot at the next ceiling decision"
}

# A superseded row whose current incarnation claims no slot is resolved: the
# prior incarnation's occupancy must not count forever.
test_an_uncapped_incarnation_resolves_a_superseded_row() {
  local case_dir state
  case_dir=$(make_case superseded-uncapped)
  state=$case_dir/home/state
  FM_HOME=$case_dir/home
  . "$ROOT/bin/fm-wake-lib.sh"
  . "$ROOT/bin/fm-secondmate-registry-lib.sh"
  . "$ROOT/bin/fm-sol-cap-lib.sh"
  fm_backend_of_meta() { printf tmux; }
  fm_backend_target_of_meta() { printf '%s' "${1##*/}"; }
  fm_backend_agent_state() { printf alive; }
  fm_write_meta "$state/one.meta" "model=glm-5" "kind=ship"
  printf 'one\tgpt-6.1-sol\t1\t-3\n' > "$state/sol-sessions.tsv"
  fm_sol_cap_active_count "$state" || fail "the adoption failed"
  [ ! "$(registry_row_field "$case_dir" one 1)" ] ||
    fail "a superseded row for an uncapped incarnation was not resolved"
  pass "an uncapped incarnation resolves the superseded row it replaced"
}

# A replacement dispatched while the guard is off must not leave the prior
# incarnation's row behind: that row names this task's id while describing a
# session that has exited, and adoption skips it, so a later declaration would
# leave the replacement uncounted.
test_a_replacement_while_the_guard_is_off_invalidates_the_prior_row() {
  local case_dir out
  case_dir=$(make_case off-replacement task-c)
  write_sol_row "$case_dir/home" task-c "$(fresh_start)" 99999999
  fm_write_meta "$case_dir/home/state/task-c.meta" "model=gpt-6.1-sol" "kind=ship"
  rm -f -- "$case_dir/home/config/sol-cap"
  out=$(lib_refuse_claim "$case_dir" task-c gpt-6.1-sol) || fail "the dispatch was refused: $out"
  assert_equals "$out" "not-capped" "an undeclared home claimed a slot"
  assert_equals "$(registry_row_field "$case_dir" task-c 4)" "-3" \
    "a replacement while the guard is off did not mark the prior incarnation's row superseded"
  pass "a replacement while the guard is off marks the prior incarnation's row superseded"
}

# A reused row follows the current declaration: a session admitted on a model
# the captain has since dropped holds no capacity, and the reuse must
# reconcile the row's model instead of keeping the dropped one.
test_a_reused_row_follows_the_current_declaration() {
  local case_dir out
  case_dir=$(make_case reuse-model task-c)
  write_sol_row "$case_dir/home" task-c "$(fresh_start)" 0 gpt-6-sol
  printf 'max=4\nmodels=gpt-6.1-sol\n' > "$case_dir/home/config/sol-cap"
  out=$(
    . "$ROOT/bin/fm-wake-lib.sh"
    . "$ROOT/bin/fm-secondmate-registry-lib.sh"
    . "$ROOT/bin/fm-sol-cap-lib.sh"
    FM_HOME="$case_dir/home"
    fm_sol_cap_refuse_and_claim task-c secondmate codex gpt-6.1-sol \
      "$case_dir/home/config" "$case_dir/home/state" reuse || { echo "$FM_SOL_CAP_REFUSAL"; exit 1; }
    echo "claimed"
  ) || fail "the reuse was refused: $out"
  assert_equals "$out" "claimed" "the reuse did not claim the slot"
  assert_equals "$(registry_row_field "$case_dir" task-c 2)" "gpt-6.1-sol" \
    "the reused row kept a model the declaration no longer covers"
  pass "a reused row follows the current declaration and its model is reconciled"
}

# The declaration the documentation ships must parse as written: an example
# a captain copies has to be a valid declaration, not a refusal.
test_the_documented_declaration_parses() {
  local case_dir out
  case_dir=$(make_case documented)
  awk '/^# config\/sol-cap$/{f=1} f{print} f&&/^```$/{exit}' "$ROOT/docs/configuration.md" \
    | sed '$d' > "$case_dir/home/config/sol-cap"
  [ -s "$case_dir/home/config/sol-cap" ] || fail "the documented declaration was not found in docs/configuration.md"
  out=$(FM_HOME="$case_dir/home" "$ROOT/bin/fm-sol-cap-lib.sh" status "$case_dir/home/config") ||
    fail "the documented declaration did not parse: $out"
  assert_contains "$out" "max=" "the documented declaration did not report its maximum"
  assert_contains "$out" "ceiling=" "the documented declaration did not report its ceiling"
  assert_contains "$out" "models=" "the documented declaration did not report its model set"
  pass "the declaration documented in docs/configuration.md parses as written"
}

# A home that drops its declaration owns no capped occupancy: its stored rows
# stay as evidence, but they neither count against another home's ceiling nor
# make its own sessions hold a slot.
test_a_home_that_drops_its_declaration_owns_no_occupancy() {
  local case_dir out root mate
  case_dir=$(make_case drop-declaration)
  root=$case_dir/home
  mate=$case_dir/mate
  make_home "$mate"
  printf '%s\n' schema=fm-secondmate-parent.v1 route=local "parent_home=$root" > "$mate/.fm-secondmate-parent"
  printf -- '- mate - local mate (home: %s; scope: work; projects: project; added 2026-09-01)\n' "$mate" > "$root/data/secondmates.md"
  for i in 1 2 3 4; do write_sol_row "$mate" "mate-$i" "$(fresh_start)" 0; done
  rm -f -- "$mate/config/sol-cap"
  out=$(lib_refuse_claim "$case_dir" next gpt-6.1-sol) || fail "a home that dropped its declaration still refused: $out"
  assert_equals "$out" "claimed" "a home that dropped its declaration still held occupancy"
  if (
    . "$ROOT/bin/fm-wake-lib.sh"
    . "$ROOT/bin/fm-secondmate-registry-lib.sh"
    . "$ROOT/bin/fm-sol-cap-lib.sh"
    fm_sol_cap_has_owned_occupancy mate-1 "$mate/state"
  ); then
    fail "a home that dropped its declaration still owned a capped session"
  fi
  [ "$(grep -c . "$mate/state/sol-sessions.tsv")" -eq 4 ] ||
    fail "a home that dropped its declaration lost its stored rows"
  pass "a home that dropped its declaration owns no occupancy and keeps its rows as evidence"
}

# --- direct library contract -------------------------------------------------

# The ceiling's session-key semantics and loud-config refusals cannot be
# reached through a single fresh spawn, so these cases drive the same contract
# through bin/fm-sol-cap-lib.sh's CLI seam against the fixture registry the
# spawn cases read.
lib_refuse_claim() {  # <case-dir> <id> <model>
  local case_dir=$1 id=$2 model=$3 out
  out=$(FM_HOME="$case_dir/home" "$ROOT/bin/fm-sol-cap-lib.sh" \
    refuse-claim "$id" ship codex "$model" "$case_dir/home/config" "$case_dir/home/state") || {
    printf '%s\n' "$out"
    return 1
  }
  printf '%s\n' "$out"
}

lib_record_actual() {  # <case-dir> <id> <model>
  local case_dir=$1 id=$2 model=$3 out
  out=$(FM_HOME="$case_dir/home" "$ROOT/bin/fm-sol-cap-lib.sh" \
    record-actual "$id" "$model" "$case_dir/home/state") || {
    printf '%s\n' "$out"
    return 1
  }
  printf '%s\n' "$out"
}

test_non_sol_report_bypasses_admission_without_occupancy() {
  local case_dir model stopped_pid dead_pid
  case_dir=$(make_case record-non-sol task-c)
  for model in glm-5 qwen3; do
    (
      . "$ROOT/bin/fm-sol-cap-lib.sh"
      fm_sol_cap_admission_lock_path() { return 91; }
      fm_sol_cap_record_actual task-c "$model" "$case_dir/home/state"
    ) || fail "a non-Sol report depended on the admission boundary"
  done
  [ ! -e "$case_dir/home/state/sol-sessions.tsv" ] ||
    fail "a non-Sol report created a Sol registry"
  write_sol_row "$case_dir/home" task-c "$(fresh_start)" 0
  if (
    . "$ROOT/bin/fm-sol-cap-lib.sh"
    fm_sol_cap_admission_lock_path() { return 91; }
    fm_sol_cap_record_actual task-c glm-5 "$case_dir/home/state"
  ); then
    fail "an existing Sol claim bypassed the admission boundary"
  fi
  assert_equals "$(registry_row_field "$case_dir" task-c 4)" 0 \
    "a refused transition released existing occupancy"
  printf 'model=gpt-6.1-sol\n' > "$case_dir/home/state/task-c.meta"
  bash -c 'exit 0' &
  dead_pid=$!
  wait "$dead_pid"
  for stopped_pid in -1 "$dead_pid"; do
    printf 'task-c\tgpt-6.1-sol\t%s\t%s\n' "$(fresh_start)" "$stopped_pid" > "$case_dir/home/state/sol-sessions.tsv"
    (
      . "$ROOT/bin/fm-wake-lib.sh"
      . "$ROOT/bin/fm-sol-cap-lib.sh"
      fm_sol_cap_lock_acquire() { return 91; }
      fm_sol_cap_admission_lock_path() { return 91; }
      fm_sol_cap_record_actual task-c glm-5 "$case_dir/home/state" || exit 1
      fm_sol_cap_record_actual task-c qwen3 "$case_dir/home/state" || exit 1
      fm_sol_cap_promote task-c remove "$case_dir/home/state" || exit 1
      fm_sol_cap_reconcile_local task-c "$case_dir/home/state" || exit 1
      fm_sol_cap_reconcile_remote task-c "$case_dir/home/state" "$case_dir/probe" || exit 1
      if fm_sol_cap_record_actual task-c gpt-6.1-sol "$case_dir/home/state"; then
        exit 1
      fi
    ) || fail "stop evidence depended on admission or a new Sol report bypassed it"
    assert_equals "$(registry_row_field "$case_dir" task-c 4)" "$stopped_pid" \
      "a stopped non-Sol retry lost its stop evidence"
  done
  pass "non-Sol reports bypass admission only without owned Sol occupancy"
}

registry_row_count() {  # <case-dir>
  grep -c . "$1/home/state/sol-sessions.tsv" || true
}

# A saved own row (the shape a relaunch replaces) is not counted against its
# task id: three live rows and its own stale row leave room, and the claim
# replaces the row with a fresh start epoch instead of appending a second row
# for one session id.
test_relaunched_session_id_replaces_its_own_row() {
  local case_dir out own_start
  case_dir=$(make_case relaunch task-c)
  write_sol_row "$case_dir/home" task-c "$(( "$(fresh_start)" - 43201 ))" 99999999
  write_sol_row "$case_dir/home" live-a "$(fresh_start)"
  write_sol_row "$case_dir/home" live-b "$(fresh_start)"
  write_sol_row "$case_dir/home" live-c "$(fresh_start)"
  out=$(lib_refuse_claim "$case_dir" task-c gpt-6.1-sol) ||
    fail "the replace claim was refused: $out"
  assert_equals "$out" "claimed" "the relaunched task id was counted against its own row"
  [ "$(wc -l < "$case_dir/home/state/sol-sessions.tsv" | tr -d ' ')" -eq 4 ] ||
    fail "the replace claim left two rows for one session id"
  own_start=$(registry_row_field "$case_dir" task-c 3)
  [ "$own_start" -ge "$(( "$(fresh_start)" - 60 ))" ] ||
    fail "the replaced own row kept its old start epoch: $own_start"
  pass "a relaunched task id replaces its own registry row instead of counting itself"
}

# A remote launch that reuses a live endpoint reports the model the endpoint
# actually runs, so a Sol report from a dispatch admission did not classify as
# Sol claims real live occupancy: the worker becomes visible to the next
# dispatch's count instead of hiding a fifth concurrent Sol session.
test_reused_live_sol_endpoint_records_occupancy_at_publication() {
  local case_dir out
  case_dir=$(make_case record-actual task-c)
  write_sol_row "$case_dir/home" live-a "$(fresh_start)"
  write_sol_row "$case_dir/home" live-b "$(fresh_start)"
  write_sol_row "$case_dir/home" live-c "$(fresh_start)"
  out=$(lib_record_actual "$case_dir" task-c gpt-6.1-sol) ||
    fail "a reused live Sol endpoint's reported model was not recorded: $out"
  assert_equals "$out" "recorded" "record-actual did not confirm the claim"
  assert_equals "$(registry_row_field "$case_dir" task-c 4)" "0" \
    "the reused endpoint's Sol report was not recorded as live occupancy"
  out=$(lib_refuse_claim "$case_dir" task-d gpt-6.1-sol) &&
    fail "a new Sol dispatch did not count the reused endpoint's occupancy: $out"
  assert_contains "$out" "this ceiling is 4" \
    "the refusal did not credit the re-recorded endpoint against the ceiling"
  pass "a reused live Sol endpoint's reported model claims its occupancy"
}

# When the endpoint's confirmed route reports it does not run a Sol model, the
# task's Sol claim releases whether or not this dispatch claimed it: a runtime
# switch whose own release was lost cannot leave its Sol incarnation counted
# forever, and a live non-Sol worker never occupies a slot.
test_non_sol_report_releases_a_stale_claim() {
  local case_dir out
  case_dir=$(make_case record-release task-c)
  write_sol_row "$case_dir/home" task-c "$(fresh_start)"
  out=$(lib_record_actual "$case_dir" task-c gpt-5.6-luna) ||
    fail "a non-Sol reported model did not release the task's Sol claim: $out"
  assert_equals "$out" "recorded" "the release did not confirm"
  [ "$(registry_row_count "$case_dir")" -eq 0 ] ||
    fail "the released claim left its row live-countable"
  pass "a non-Sol reported model releases the task's stale Sol claim"
}

# An adopted uncertain claim is the admission boundary's own recheckable
# occupancy: the confirmed route reporting Sol never rewrites it into a
# permanent pid-0 claim whose liveness no later admission may recheck.
test_adopted_uncertain_claim_survives_reported_sol() {
  local case_dir out old_start
  case_dir=$(make_case record-adopted task-c)
  old_start=$(( "$(fresh_start)" - 43201 ))
  write_sol_row "$case_dir/home" task-c "$old_start" -2
  out=$(lib_record_actual "$case_dir" task-c gpt-6.1-sol) ||
    fail "a Sol report under an adopted uncertain claim failed: $out"
  assert_equals "$out" "recorded" "the keep case did not confirm"
  assert_equals "$(registry_row_field "$case_dir" task-c 4)" "-2" \
    "the Sol report rewrote an adopted uncertain claim into a permanent one"
  assert_equals "$(registry_row_field "$case_dir" task-c 3)" "$old_start" \
    "the Sol report reset the adopted claim's start epoch"
  pass "a confirmed Sol report preserves an adopted uncertain claim's reconciliation"
}

# A Sol report under a dispatch that already claimed the task leaves the live
# claim untouched instead of rewriting it: no double claim, no lost start.
test_sol_report_under_an_existing_claim_keeps_the_row() {
  local case_dir out old_start
  case_dir=$(make_case record-keep task-c)
  old_start=$(( "$(fresh_start)" - 43201 ))
  write_sol_row "$case_dir/home" task-c "$old_start" 0 claude-sonnet
  out=$(lib_record_actual "$case_dir" task-c gpt-6-sol) ||
    fail "a Sol report under an existing claim failed: $out"
  assert_equals "$out" "recorded" "the keep case did not confirm"
  assert_equals "$(registry_row_field "$case_dir" task-c 3)" "$old_start" \
    "a Sol report under an existing claim rewrote the live row"
  assert_equals "$(registry_row_field "$case_dir" task-c 4)" "0" \
    "a Sol report under an existing claim rewrote the live claim's pid"
  assert_equals "$(registry_row_field "$case_dir" task-c 2)" "gpt-6-sol" \
    "a Sol report under an existing claim did not reconcile the recorded model"
  pass "a Sol report under an existing claim keeps the claim and reconciles the model"
}

# A row whose model the captain has dropped from the declaration holds no
# capacity: the count does not see that row either, so treating it as
# occupancy would make the release path wait on a slot that does not exist.
test_a_row_whose_model_was_dropped_holds_no_occupancy() {
  local case_dir
  case_dir=$(make_case dropped-model task-c)
  write_sol_row "$case_dir/home" task-c "$(fresh_start)" 0 gpt-6-sol
  printf 'max=4\nmodels=gpt-6.1-sol\n' > "$case_dir/home/config/sol-cap"
  if (
    . "$ROOT/bin/fm-wake-lib.sh"
    . "$ROOT/bin/fm-secondmate-registry-lib.sh"
    . "$ROOT/bin/fm-sol-cap-lib.sh"
    FM_HOME="$case_dir/home"
    fm_sol_cap_has_owned_occupancy task-c "$case_dir/home/state"
  ); then
    fail "a row whose model the declaration dropped still held occupancy"
  fi
  pass "a row whose model the declaration dropped holds no occupancy"
}

# A structured row that cannot prove its session key refuses every dispatch
# with the row named: staleness is release, but a malformed row is a loud
# refusal, because skipping one could free a slot another session holds.
test_malformed_registry_row_refuses_loudly() {
  local case_dir out
  case_dir=$(make_case malformed task-c)
  write_sol_row "$case_dir/home" bad "not-an-epoch"
  out=$(lib_refuse_claim "$case_dir" task-c gpt-6.1-sol) || true
  assert_contains "$out" "malformed row" "a malformed registry row did not refuse loudly"
  assert_contains "$out" "not-an-epoch" "the loud refusal did not name the malformed row"
  pass "a malformed registry row refuses every Sol dispatch and names the row"
}

# A declaration that is malformed refuses instead of guessing, and every
# refusal names the file and the problem.
test_malformed_declaration_refuses_loudly() {
  local case_dir out
  case_dir=$(make_case unreadable task-c)
  write_sol_row "$case_dir/home" fresh "$(fresh_start)"
  printf 'max=4\nceiling=four\nmodels=gpt-6.1-sol\n' > "$case_dir/home/config/sol-cap"
  out=$(lib_refuse_claim "$case_dir" task-c gpt-6.1-sol) || true
  assert_contains "$out" "ceiling unavailable" "a malformed declaration did not refuse"
  assert_contains "$out" "config/sol-cap" "the refusal did not name the declaration file"
  assert_contains "$out" "ceiling" "the refusal did not name the malformed key"
  printf 'max=4\n' > "$case_dir/home/config/sol-cap"
  out=$(lib_refuse_claim "$case_dir" task-c gpt-6.1-sol) || true
  assert_contains "$out" "models or model-pattern" "a declaration that names no model was accepted"
  printf 'max=4\nmodels=gpt-6.1-sol\nceiling=5\n' > "$case_dir/home/config/sol-cap"
  out=$(lib_refuse_claim "$case_dir" task-c gpt-6.1-sol) || true
  assert_contains "$out" "1 through 4" "a ceiling above the declared maximum was accepted"
  printf 'max=4\nmodels=gpt-6.1-sol\nunknown=1\n' > "$case_dir/home/config/sol-cap"
  out=$(lib_refuse_claim "$case_dir" task-c gpt-6.1-sol) || true
  assert_contains "$out" "unknown key" "an unknown declaration key was accepted"
  # An out-of-range count makes a numeric comparison error out, and an
  # erroring comparison reads as "not greater": the declaration must be
  # refused before any comparison runs.
  printf 'max=4\nmodels=gpt-6.1-sol\nceiling=18446744073709551616\n' > "$case_dir/home/config/sol-cap"
  out=$(lib_refuse_claim "$case_dir" task-c gpt-6.1-sol) || true
  assert_contains "$out" "ceiling unavailable" "an out-of-range ceiling was accepted"
  printf 'max=18446744073709551616\nmodels=gpt-6.1-sol\n' > "$case_dir/home/config/sol-cap"
  out=$(lib_refuse_claim "$case_dir" task-c gpt-6.1-sol) || true
  assert_contains "$out" "ceiling unavailable" "an out-of-range maximum was accepted"
  printf 'max=4\nmodels=gpt-6.1-sol\nmodel-pattern=*bad(\n' > "$case_dir/home/config/sol-cap"
  out=$(lib_refuse_claim "$case_dir" task-c gpt-6.1-sol) || true
  assert_contains "$out" "unusable model-pattern" "an unusable declared pattern was accepted"
  # A declaration the guard cannot read leaves the guard unable to know its
  # own scope, so it refuses rather than admitting a model it might have
  # been asked to cap. The refusal names the file and the problem.
  printf 'max=4\nceiling=four\nmodels=gpt-6.1-sol\n' > "$case_dir/home/config/sol-cap"
  out=$(lib_refuse_claim "$case_dir" task-uncapped gpt-5.6-luna) || true
  assert_contains "$out" "ceiling unavailable" "a malformed declaration let an uncapped model through"
  assert_contains "$out" "config/sol-cap" "the refusal did not name the declaration file"
  pass "a malformed declaration refuses loudly instead of falling back to a default"
}

test_review_regressions() {
  local case_dir out rc=0 worker i
  case_dir=$(make_case review docs)
  write_sol_row "$case_dir/home" build-docs 1 "$$"
  out=$(lib_refuse_claim "$case_dir" docs gpt-6.1-sol) || fail "$out"
  [ "$(registry_row_field "$case_dir" build-docs 4)" = "$$" ] || fail "suffix collision removed live worker"
  FM_HOME="$case_dir/home" bash "$ROOT/bin/fm-sol-cap-lib.sh" run docs "$case_dir/home/state" sleep 30 &
  worker=$!
  for ((i=0; i<100; i++)); do
    [ "$(registry_row_field "$case_dir" docs 4)" = "$worker" ] && break
    sleep 0.02
  done
  [ "$(registry_row_field "$case_dir" docs 4)" = "$worker" ] || fail "worker did not acquire reservation"
  kill "$worker"
  wait "$worker" 2>/dev/null || true
  out=$(lib_refuse_claim "$case_dir" another gpt-6.1-sol) || fail "$out"
  [ -z "$(registry_row_field "$case_dir" docs 4)" ] || fail "exited worker retained occupancy"
  for i in 1 2 3; do write_sol_row "$case_dir/home" "old-$i" 1 "$$"; done
  rc=0
  out=$(lib_refuse_claim "$case_dir" fifth gpt-6.1-sol) || rc=$?
  expect_code 1 "$rc" "live old workers did not hold ceiling"
  printf 'max=4\nmodels=gpt-6.1-sol|gpt-6-sol\nceiling=5\n' > "$case_dir/home/config/sol-cap"
  rc=0
  FM_HOME="$case_dir/home" bash "$ROOT/bin/fm-sol-cap-lib.sh" ceiling "$case_dir/home/config" >/dev/null || rc=$?
  expect_code 1 "$rc" "ceiling above four was accepted"
  printf 'max=4\nmodels=gpt-6.1-sol|gpt-6-sol\n' > "$case_dir/home/config/sol-cap"
  printf '{broken\n' > "$case_dir/home/config/crew-dispatch.json"
  out=$(lib_refuse_claim "$case_dir" glm glm-5) || fail "GLM blocked by a dispatch table the guard does not read: $out"
  out=$(lib_refuse_claim "$case_dir" qwen qwen3) || fail "qwen blocked by a dispatch table the guard does not read: $out"
  pass "exact identities, worker lifetime, live age, bounded declarations and non-Sol isolation"
}

test_shared_home_admission() {
  local case_dir root mate out rc=0 a b successes=0 i
  case_dir=$(make_case shared)
  root=$case_dir/home
  mate=$case_dir/mate
  make_home "$mate"
  printf '%s\n' schema=fm-secondmate-parent.v1 route=local "parent_home=$root" > "$mate/.fm-secondmate-parent"
  printf -- '- mate - local mate (home: %s; scope: work; projects: project; added 2026-09-01)\n' "$mate" > "$root/data/secondmates.md"
  for i in 1 2 3; do write_sol_row "$root" "live-$i" 1 "$$"; done
  write_sol_row "$mate" same 1 "$$"
  out=$(lib_refuse_claim "$case_dir" same gpt-6.1-sol) || rc=$?
  expect_code 1 "$rc" "same id in another home was excluded"
  rm "$mate/state/sol-sessions.tsv"
  (
    . "$ROOT/bin/fm-wake-lib.sh"
    . "$ROOT/bin/fm-secondmate-registry-lib.sh"
    . "$ROOT/bin/fm-sol-cap-lib.sh"
    FM_HOME=$root
    fm_sol_cap_refuse_and_claim root-task ship codex gpt-6.1-sol "$root/config" "$root/state"
  ) > "$case_dir/root.out" 2>&1 &
  # shellcheck disable=SC2031 # This is the immediately preceding background job in this shell.
  a=$!
  (
    . "$ROOT/bin/fm-wake-lib.sh"
    . "$ROOT/bin/fm-secondmate-registry-lib.sh"
    . "$ROOT/bin/fm-sol-cap-lib.sh"
    FM_HOME=$mate
    fm_sol_cap_refuse_and_claim mate-task ship codex gpt-6.1-sol "$mate/config" "$mate/state"
  ) > "$case_dir/mate.out" 2>&1 &
  # shellcheck disable=SC2031 # This is the immediately preceding background job in this shell.
  b=$!
  wait "$a" && successes=$((successes + 1))
  wait "$b" && successes=$((successes + 1))
  [ "$successes" = 1 ] || fail "concurrent homes admitted $successes workers into one slot"
  pass "local homes share admission lock and preserve distinct task identities"
}

test_retry_and_confirmed_stop() {
  local case_dir out rc=0 id=retry before
  case_dir=$(make_case retry)
  write_sol_row "$case_dir/home" "$id" 1 0
  write_sol_row "$case_dir/home" build-retry 1 0
  before=$(cat "$case_dir/home/state/sol-sessions.tsv")
  out=$(lib_refuse_claim "$case_dir" "$id" gpt-6.1-sol) || rc=$?
  expect_code 1 "$rc" "retry replaced uncertain occupancy"
  assert_equals "$before" "$(cat "$case_dir/home/state/sol-sessions.tsv")" "retry changed existing occupancy"
  out=$(lib_refuse_claim "$case_dir" "$id" glm-5) || fail "$out"
  assert_equals "$id" "$(registry_row_field "$case_dir" "$id" 1)" "non-Sol retry released the occupancy"
  printf 'manual\n' > "$case_dir/home/config/backlog-backend"
  fm_write_meta "$case_dir/home/state/$id.meta" "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "worktree=$case_dir/nonexistent-worktree" "project=$case_dir/nonexistent-project" "kind=ship" "mode=no-mistakes"
  printf 'fm-%s\n' "$id" > "$case_dir/calls.log.window"
  rc=0
  out=$(FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_TEST_CLOSE_FAIL=1 \
    FM_FAKE_CALL_LOG="$case_dir/calls.log" PATH="$case_dir/fakebin:$PATH" \
    bash "$ROOT/bin/fm-teardown.sh" "$id" --force 2>&1) || rc=$?
  assert_equals "$id" "$(registry_row_field "$case_dir" "$id" 1)" "unconfirmed close released occupancy"
  fm_write_meta "$case_dir/home/state/$id.meta" "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "worktree=$case_dir/nonexistent-worktree" "project=$case_dir/nonexistent-project" "kind=ship" "mode=no-mistakes"
  out=$(FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_FAKE_CALL_LOG="$case_dir/calls.log" PATH="$case_dir/fakebin:$PATH" \
    bash "$ROOT/bin/fm-teardown.sh" "$id" --force 2>&1) || fail "confirmed teardown failed: $out"
  [ -z "$(registry_row_field "$case_dir" "$id" 4)" ] || fail "confirmed teardown retained occupancy"
  [ "$(registry_row_field "$case_dir" build-retry 4)" = 0 ] || fail "teardown removed sibling occupancy"
  pass "retries preserve occupancy and only confirmed teardown releases it"
}

test_remote_ownership_and_recovery() (
  local case_dir out rc=0 i scripts state
  case_dir=$(make_case remote-owner)
  state=$case_dir/home/state
  mkdir -p "$state/parent-route"
  printf '%s\n' schema=fm-secondmate-parent.v1 route=remote > "$case_dir/home/.fm-secondmate-parent"
  . "$ROOT/bin/fm-wake-lib.sh"
  . "$ROOT/bin/fm-secondmate-registry-lib.sh"
  . "$ROOT/bin/fm-sol-cap-lib.sh"
  FM_HOME=$case_dir/home
  write_sol_row "$case_dir/home" crew-a 1 "$$"
  write_sol_row "$case_dir/home" crew-b 1 "$$"
  printf 'mate\tgpt-6.1-sol\t1\t0\n' > "$state/parent-route/sol-sessions.tsv"
  fm_sol_cap_active_count "$state/parent-route" || fail "nested count failed"
  expect_code 3 "$FM_SOL_COUNT" "nested route did not count itself and crew exactly once"
  write_sol_row "$case_dir/home" crew-c 1 "$$"
  fm_sol_cap_refuse_and_claim fifth ship codex gpt-6.1-sol "$case_dir/home/config" "$state" && fail "crew bypassed mate occupancy"
  FM_HOME=$ROOT
  fm_sol_cap_refuse_and_claim fifth ship codex gpt-6.1-sol "$case_dir/home/config" "$state/parent-route" && fail "nested route bypassed crew occupancy"
  FM_HOME=$case_dir/home
  scripts=$case_dir/probe
  mkdir "$scripts"
  cat > "$scripts/fm-on.sh" <<'SH'
#!/usr/bin/env bash
printf 'probe diagnostic\n%s\n' "$TEST_REMOTE_STATE"
exit "${TEST_REMOTE_RC:-0}"
SH
  chmod +x "$scripts/fm-on.sh"
  touch "$state/mate.meta"
  for i in alive unreadable ambiguous dead missing; do
    printf 'mate\tgpt-6.1-sol\t1\t0\n' > "$state/sol-sessions.tsv"
    TEST_REMOTE_STATE=$i fm_sol_cap_reconcile_remote mate "$state" "$scripts" || fail "remote reconciliation failed"
    out=$(registry_row_field "$case_dir" mate 4)
    case "$i" in
      dead|missing) [ -z "$out" ] || fail "proven-stopped remote claim survived" ;;
      *) [ "$out" = 0 ] || fail "uncertain/live claim was removed" ;;
    esac
  done
  printf 'mate\tgpt-6.1-sol\t1\t0\n' > "$state/sol-sessions.tsv"
  TEST_REMOTE_STATE=dead TEST_REMOTE_RC=255 fm_sol_cap_reconcile_remote mate "$state" "$scripts"
  [ "$(registry_row_field "$case_dir" mate 4)" = 0 ] || fail "transport failure released remote claim"
  pass "remote parent-route ownership shares the ceiling and recovery preserves uncertain claims"
)

test_stopped_local_and_unpublished_remote_recovery() (
  local case_dir state observed_state absence_response out i
  case_dir=$(make_case stopped-local)
  state=$case_dir/home/state
  FM_HOME=$case_dir/home
  . "$ROOT/bin/fm-wake-lib.sh"
  . "$ROOT/bin/fm-secondmate-registry-lib.sh"
  . "$ROOT/bin/fm-sol-cap-lib.sh"
  fm_backend_of_meta() { printf tmux; }
  fm_backend_target_of_meta() { printf 'firstmate:fm-mate'; }
  fm_backend_agent_state() { printf '%s' "$observed_state"; }
  fm_control_endpoint_absence_verdict() { printf '%s' "$absence_response"; }
  touch "$state/mate.meta"
  for i in dead alive unreadable; do
    observed_state=$i
    printf 'mate\tgpt-6.1-sol\t1\t0\n' > "$state/sol-sessions.tsv"
    fm_sol_cap_reconcile_local mate "$state" || fail "local reconciliation failed"
    out=$(registry_row_field "$case_dir" mate 4)
    case "$i" in
      dead) [ -z "$out" ] || fail "dead local conservative claim survived" ;;
      *) [ "$out" = 0 ] || fail "unproven local stop released occupancy" ;;
    esac
  done
  observed_state=missing absence_response=unknown
  fm_sol_cap_reconcile_local mate "$state"
  [ "$(registry_row_field "$case_dir" mate 4)" = 0 ] || fail "ambiguous absence released occupancy"
  absence_response=gone
  fm_sol_cap_reconcile_local mate "$state"
  fm_sol_cap_refuse_and_claim mate secondmate claude default "$case_dir/home/config" "$state" || fail "cleared model was refused"
  [ -z "$FM_SOL_CLAIM_CREATED" ] || fail "cleared model reserved Sol occupancy"
  mkdir "$case_dir/probe"
  cat > "$case_dir/probe/fm-on.sh" <<'SH'
#!/usr/bin/env bash
printf 'dead\n'
SH
  chmod +x "$case_dir/probe/fm-on.sh"
  rm "$state/mate.meta"
  printf 'mate\tgpt-6.1-sol\t1\t0\n' > "$state/sol-sessions.tsv"
  fm_sol_cap_reconcile_remote mate "$state" "$case_dir/probe" || fail "unpublished route reconciliation failed"
  [ -z "$(registry_row_field "$case_dir" mate 4)" ] || fail "missing parent metadata blocked proven-stop reconciliation"
  pass "proven local stops and unpublished remote recovery release conservative occupancy"
)

test_unpinned_worker_exempt_from_broad_ceiling() (
  local case_dir state declaration
  case_dir=$(make_case unpinned)
  state=$case_dir/home/state
  FM_HOME=$case_dir/home
  . "$ROOT/bin/fm-wake-lib.sh"
  . "$ROOT/bin/fm-secondmate-registry-lib.sh"
  . "$ROOT/bin/fm-sol-cap-lib.sh"
  fm_backend_of_meta() { printf tmux; }
  fm_backend_target_of_meta() { printf 'firstmate:fm-unpinned'; }
  fm_backend_agent_state() { printf alive; }
  for declaration in 'model-pattern=.*' 'models=default|gpt-6.1-sol'; do
    printf 'max=1\n%s\n' "$declaration" > "$case_dir/home/config/sol-cap"
    fm_sol_cap_refuse_and_claim unpinned ship codex default "$case_dir/home/config" "$state" || fail "unpinned admission refused"
    [ -z "$FM_SOL_CLAIM_CREATED" ] || fail "unpinned admission claimed occupancy"
    fm_write_meta "$state/unpinned.meta" "model=default" "kind=ship"
    fm_sol_cap_refuse_and_claim pinned ship codex gpt-6.1-sol "$case_dir/home/config" "$state" || fail "$FM_SOL_CAP_REFUSAL"
    [ -z "$(registry_row_field "$case_dir" unpinned 4)" ] || fail "unpinned worker was adopted"
    [ "$(registry_row_field "$case_dir" pinned 4)" = "$$" ] || fail "pinned worker did not claim capacity"
    fm_sol_cap_refuse_and_claim overflow ship codex gpt-6.1-sol "$case_dir/home/config" "$state" && fail "pinned worker bypassed ceiling"
    fm_sol_cap_promote pinned remove "$state" || fail "pinned claim release failed"
  done
  pass "unpinned workers remain exempt during broad-pattern and explicit-list adoption"
)

test_adopt_preserved_workers() (
  local case_dir state i out rc=0
  case_dir=$(make_case adopt)
  state=$case_dir/home/state
  FM_HOME=$case_dir/home
  . "$ROOT/bin/fm-wake-lib.sh"
  . "$ROOT/bin/fm-secondmate-registry-lib.sh"
  . "$ROOT/bin/fm-sol-cap-lib.sh"
  fm_backend_of_meta() { printf tmux; }
  fm_backend_target_of_meta() { printf '%s' "${1##*/}"; }
  fm_backend_agent_state() {
    case "$2" in stopped.meta) printf dead ;; uncertain.meta) printf unreadable ;; *) printf alive ;; esac
  }
  for i in one two three uncertain stopped; do
    fm_write_meta "$state/$i.meta" "window=firstmate:fm-$i" "model=gpt-6.1-sol" "kind=ship"
  done
  fm_write_meta "$state/glm.meta" "model=glm-5" "kind=ship"
  fm_sol_cap_refuse_and_claim fifth ship codex gpt-6.1-sol "$case_dir/home/config" "$state" || rc=$?
  expect_code 1 "$rc" "preserved workers were invisible during admission"
  [ "$(wc -l < "$state/sol-sessions.tsv")" -eq 5 ] || fail "adoption did not count live and uncertain workers"
  [ "$(registry_row_field "$case_dir" stopped 4)" = -1 ] || fail "proven stop was not retained"
  [ -z "$(registry_row_field "$case_dir" glm 4)" ] || fail "GLM worker was adopted"
  fm_sol_cap_refuse_and_claim fifth ship codex gpt-6.1-sol "$case_dir/home/config" "$state" && fail "repeat admission ignored adopted workers"
  [ "$(wc -l < "$state/sol-sessions.tsv")" -eq 5 ] || fail "repeated adoption duplicated registry rows"
  rm "$state/one.meta"
  fm_sol_cap_promote one remove "$state" || fail "fixture stop could not release occupancy"
  fm_sol_cap_refuse_and_claim fifth ship codex gpt-6.1-sol "$case_dir/home/config" "$state" || fail "$FM_SOL_CAP_REFUSAL"
  [ "$(wc -l < "$state/sol-sessions.tsv")" -eq 5 ] || fail "admission after confirmed stop did not retain four slots"
  pass "admission adopts preserved live or uncertain Sol workers without duplicating or counting stopped/non-Sol workers"
)

test_retained_stop_evidence() (
  local case_dir state i
  case_dir=$(make_case stop-evidence)
  state=$case_dir/home/state
  FM_HOME=$case_dir/home
  . "$ROOT/bin/fm-wake-lib.sh"
  . "$ROOT/bin/fm-secondmate-registry-lib.sh"
  . "$ROOT/bin/fm-sol-cap-lib.sh"
  fm_backend_of_meta() { printf cmux; }
  fm_backend_target_of_meta() { printf 'workspace:surface'; }
  fm_backend_agent_state() { printf unverified; }
  for i in one two three four; do
    fm_write_meta "$state/$i.meta" "model=gpt-6.1-sol" "kind=ship"
    write_sol_row "$case_dir/home" "$i" 1 99999999
  done
  fm_sol_cap_refuse_and_claim next ship codex gpt-6.1-sol "$case_dir/home/config" "$state" || fail "$FM_SOL_CAP_REFUSAL"
  fm_sol_cap_refuse_and_claim next ship codex gpt-6.1-sol "$case_dir/home/config" "$state" reuse || fail "dead workers were resurrected"
  write_sol_row "$case_dir/home" explicit 1 0
  fm_write_meta "$state/explicit.meta" "model=gpt-6.1-sol"
  fm_sol_cap_promote explicit remove "$state" || fail "confirmed-stop release failed"
  [ "$(registry_row_field "$case_dir" explicit 4)" = -1 ] || fail "confirmed stop was forgotten"
  fm_sol_cap_refuse_and_claim later ship codex gpt-6.1-sol "$case_dir/home/config" "$state" || fail "confirmed stopped worker was resurrected"
  pass "pruning and explicit release preserve stop evidence while metadata survives"
)

test_unregistered_stop_evidence() (
  local case_dir state mode id
  case_dir=$(make_case legacy-stop)
  state=$case_dir/home/state
  FM_HOME=$case_dir/home
  . "$ROOT/bin/fm-wake-lib.sh"
  . "$ROOT/bin/fm-secondmate-registry-lib.sh"
  . "$ROOT/bin/fm-sol-cap-lib.sh"
  fm_backend_of_meta() { printf cmux; }
  fm_backend_target_of_meta() { printf 'workspace:surface'; }
  fm_backend_agent_state() { printf dead; }
  mkdir "$case_dir/probe"
  cat > "$case_dir/probe/fm-on.sh" <<'SH'
#!/usr/bin/env bash
printf 'dead\n'
SH
  chmod +x "$case_dir/probe/fm-on.sh"
  for mode in release local remote; do
    id=legacy-$mode
    fm_write_meta "$state/$id.meta" "model=gpt-6.1-sol" "kind=ship"
    case "$mode" in
      release) fm_sol_cap_promote "$id" remove "$state" || fail "unregistered stop could not be recorded" ;;
      local) fm_sol_cap_reconcile_local "$id" "$state" || fail "unregistered local reconciliation failed" ;;
      remote) fm_sol_cap_reconcile_remote "$id" "$state" "$case_dir/probe" || fail "unregistered remote reconciliation failed" ;;
    esac
    [ "$(registry_row_field "$case_dir" "$id" 4)" = -1 ] || fail "$mode forgot an unregistered confirmed stop"
  done
  fm_backend_agent_state() { printf unverified; }
  fm_sol_cap_refuse_and_claim fresh ship codex gpt-6.1-sol "$case_dir/home/config" "$state" || fail "legacy stopped tasks were re-adopted"
  fm_sol_cap_refuse_and_claim fresh ship codex gpt-6.1-sol "$case_dir/home/config" "$state" reuse || fail "repeat adoption forgot legacy stops"
  for mode in release local remote; do
    [ "$(registry_row_field "$case_dir" "legacy-$mode" 4)" = -1 ] || fail "adoption replaced $mode stop evidence"
  done
  pass "confirmed-stop paths remember legacy workers with missing registries or rows"
)

test_adopted_worker_exit() (
  local case_dir state i adopted_state
  case_dir=$(make_case adopted-exit)
  state=$case_dir/home/state
  FM_HOME=$case_dir/home
  . "$ROOT/bin/fm-wake-lib.sh"
  . "$ROOT/bin/fm-secondmate-registry-lib.sh"
  . "$ROOT/bin/fm-sol-cap-lib.sh"
  fm_backend_of_meta() { printf tmux; }
  fm_backend_target_of_meta() { printf '%s' "${1##*/}"; }
  fm_backend_agent_state() { printf '%s' "$adopted_state"; }
  for i in one two three four; do
    fm_write_meta "$state/$i.meta" "model=gpt-6.1-sol"
  done
  adopted_state=alive
  fm_sol_cap_config "$case_dir/home/config" || fail "declaration failed"
  fm_sol_cap_active_count "$state" || fail "adoption failed"
  [ "$FM_SOL_COUNT" = 4 ] || fail "live workers not adopted"
  adopted_state=dead
  fm_lock_try_acquire "$state/.spawn-one.lock" || fail "delivery lock failed"
  fm_sol_cap_active_count "$state" || fail "exit reconciliation failed"
  [ "$FM_SOL_COUNT" = 1 ] || fail "stop proof lost or in-flight delivery released"
  fm_lock_release "$state/.spawn-one.lock"
  adopted_state=unverified
  fm_sol_cap_active_count "$state" || fail "uncertain reconciliation failed"
  [ "$FM_SOL_COUNT" = 1 ] || fail "uncertain claim lost or stopped workers resurrected"
  adopted_state=dead
  fm_sol_cap_refuse_and_claim fresh ship codex gpt-6.1-sol "$case_dir/home/config" "$state" || fail "$FM_SOL_CAP_REFUSAL"
  for i in one two three four; do
    [ "$(registry_row_field "$case_dir" "$i" 4)" = -1 ] || fail "stop marker lost"
  done
  pass "adopted exits free capacity while uncertain and in-flight claims remain"
)

test_queued_delivery_reservation() (
  local case_dir state i
  case_dir=$(make_case queued-delivery)
  state=$case_dir/home/state
  FM_HOME=$case_dir/home
  . "$ROOT/bin/fm-wake-lib.sh"
  . "$ROOT/bin/fm-secondmate-registry-lib.sh"
  . "$ROOT/bin/fm-sol-cap-lib.sh"
  fm_backend_of_meta() { printf tmux; }
  fm_backend_target_of_meta() { printf shell; }
  fm_backend_agent_state() { printf dead; }
  for i in one two three; do
    write_sol_row "$FM_HOME" "$i" 1 "$$"
  done
  (
    fm_sol_cap_refuse_and_claim queued ship codex gpt-6.1-sol "$FM_HOME/config" "$state" || fail "$FM_SOL_CAP_REFUSAL"
    fm_sol_cap_promote queued 0 "$state" || fail "delivery reservation failed"
    fm_write_meta "$state/queued.meta" "model=gpt-6.1-sol"
  ) || fail "spawning process failed"
  fm_sol_cap_refuse_and_claim fifth ship codex gpt-6.1-sol "$FM_HOME/config" "$state" && fail "queued delivery was released by shell probe"
  [ "$(registry_row_field "$case_dir" queued 4)" = 0 ] || fail "delivery reservation changed"
  fm_sol_cap_promote queued "$$" "$state" || fail "late launcher promotion failed"
  fm_sol_cap_refuse_and_claim fifth ship codex gpt-6.1-sol "$FM_HOME/config" "$state" && fail "late launcher exceeded ceiling"
  pass "queued delivery retains occupancy after spawning process exits"
)

test_queued_delivery_reservation

test_adopted_worker_exit

test_unregistered_stop_evidence
test_retained_stop_evidence
test_unpinned_worker_exempt_from_broad_ceiling
test_adopt_preserved_workers
test_stopped_local_and_unpublished_remote_recovery
test_remote_ownership_and_recovery
test_retry_and_confirmed_stop
test_shared_home_admission
test_review_regressions
test_under_cap_sol_spawn_launches_and_claims_its_slot
test_capped_launch_keeps_the_uncapped_command_invocation
test_capped_launch_survives_a_fish_pane
test_run_launch_falls_back_when_the_pane_shell_is_unusable
test_cap_refuses_the_fifth_and_names_its_sessions
test_stale_entries_do_not_count
test_non_sol_model_never_claims_a_slot
test_config_sol_cap_declares_the_ceiling
test_no_declaration_leaves_the_guard_inert
test_declared_model_set_is_the_only_capped_set
test_the_documented_declaration_parses
test_a_home_that_drops_its_declaration_owns_no_occupancy
test_a_reused_row_follows_the_current_declaration
test_a_row_whose_model_was_dropped_holds_no_occupancy
test_a_replacement_while_the_guard_is_off_invalidates_the_prior_row
test_a_replacement_on_an_excluded_model_invalidates_the_prior_row
test_the_adoption_resolves_a_superseded_row
test_an_uncapped_incarnation_resolves_a_superseded_row
test_an_abandoned_replacement_consumes_no_capacity
test_a_live_row_is_not_superseded
test_a_busy_boundary_replacement_lands_its_pending_supersede
test_pending_publication_is_invisible_until_rename
test_pending_publication_failure_is_reported
test_a_busy_boundary_supersede_keeps_another_claims_row
test_a_busy_boundary_replacement_counts_at_the_ceiling
test_relaunched_session_id_replaces_its_own_row
test_reused_live_sol_endpoint_records_occupancy_at_publication
test_non_sol_report_releases_a_stale_claim
test_adopted_uncertain_claim_survives_reported_sol
test_sol_report_under_an_existing_claim_keeps_the_row
test_malformed_registry_row_refuses_loudly
test_malformed_declaration_refuses_loudly

test_non_sol_report_bypasses_admission_without_occupancy
