#!/usr/bin/env bash
# tests/fm-claude-local-harness.test.sh - the portable regression for the
# claude-local adapter's OPT-IN and SCOPE gates.
#
# claude-local is the verified `claude` CLI pinned to a locally served model. It
# is deliberately NOT a second harness implementation: it reuses claude's binary,
# composer shape, trust dialog, and lifecycle hooks, and reaches the verified
# tables through the `claude*` prefix rule that bin/fm-control-lib.sh already
# owns. What is new, and what this suite pins, is the set of refusals - because
# every failure they prevent is SILENT. A task that reaches this runtime by
# accident is not visibly broken, it is just slow and worse, which is exactly
# the class of failure a gate has to catch instead of a reviewer.
#
# The load-bearing contracts:
#   1. Opt-in only: a home-wide default (config/crew-harness) must NEVER select
#      it, while an explicit per-spawn argument may.
#   2. It is a crewmate/scout adapter: a secondmate launch is refused, in the
#      spawn AND in the control plane that decides a relaunch before stopping
#      the running agent.
#   3. It is never the no-mistakes pipeline.
#   4. The model id is the endpoint's own catalog id and is never guessed.
#   5. It inherits, rather than re-implements, claude's verified control family
#      and semantic busy source.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

# shellcheck source=bin/fm-control-lib.sh
. "$ROOT/bin/fm-control-lib.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=bin/fm-composer-lib.sh
. "$ROOT/bin/fm-composer-lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-claude-local-harness)

# A world whose fm-local-model endpoint is a real file:// catalog, so the spawn
# gates run against a reachable endpoint rather than being skipped. The suite is
# about the REFUSALS, so the endpoint is deliberately healthy: a gate that only
# fires because the endpoint is down would prove nothing.
make_world() {  # <name> -> echoes "<home> <fakebin> <endpoint> <case-dir>"
  local name=$1 case_dir home fakebin dir
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" gh gh-axi)
  dir="$case_dir/endpoint/api/v0"
  mkdir -p "$dir"
  cat > "$dir/models" <<'EOF'
{"object":"list","data":[
 {"id":"local-coder","object":"model","type":"llm","state":"loaded","max_context_length":262144,"loaded_context_length":131072}
]}
EOF
  printf '%s %s file://%s %s\n' "$home" "$fakebin" "$case_dir/endpoint" "$case_dir"
}

set_model_state() {  # <case-dir> <state> <loaded-context-length>
  local case_dir=$1 state=$2 ctx=$3
  cat > "$case_dir/endpoint/api/v0/models" <<EOF
{"object":"list","data":[
 {"id":"local-coder","object":"model","type":"llm","state":"$state","max_context_length":262144,"loaded_context_length":$ctx}
]}
EOF
}

# run_spawn <home> <fakebin> <endpoint> [args...]
# Captures combined output into the file named by RUN_OUT and RETURNS the
# spawn's exit status. It deliberately does not print to stdout: a caller that
# wrote `out=$(run_spawn ...)` would run this in a subshell, where an exit
# status assigned to a variable never reaches the caller and every refusal
# silently reads as success.
# FM_LOCAL_MODEL_HARNESS_BASELINE is pinned low so the headroom check is
# satisfied and the gate under test is the one that fires.
RUN_OUT=
run_spawn() {
  local home=$1 fakebin=$2 endpoint=$3
  shift 3
  RUN_OUT="$TMP_ROOT/spawn-out.$$"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_LOCAL_MODEL_ENDPOINT="$endpoint" FM_LOCAL_MODEL_HARNESS_BASELINE=1000 \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" > "$RUN_OUT" 2>&1
}

# The gate that matters most: a home-wide crew default must not be able to put
# every crewmate on the captain's laptop. The contrast is the assertion - the
# SAME home, the SAME task, refused when the harness comes from config and
# accepted past that gate when it is named explicitly.
test_home_default_cannot_select_it() {
  local home fakebin endpoint case_dir id out
  read -r home fakebin endpoint case_dir <<<"$(make_world default)"
  id="cl-default-x1"
  fm_test_spawn_brief "$home" "$id" "tiny brief"
  printf 'claude-local\n' > "$home/config/crew-harness"

  run_spawn "$home" "$fakebin" "$endpoint" "$id" "$home/projects" --scout \
    && fail "config/crew-harness was allowed to select claude-local"
  out=$(cat "$RUN_OUT")
  case "$out" in
    *"opt-in only"*) : ;;
    *) fail "the home-default refusal did not name the opt-in boundary: $out" ;;
  esac
  case "$out" in
    *crew-harness*) : ;;
    *) fail "the refusal did not name the default that tried to select it: $out" ;;
  esac

  # Same home, same config, same task - but named explicitly. This must get PAST
  # the opt-in gate. The project path is deliberately one that does not exist, so
  # the spawn stops at the next check instead of running a real launch: the
  # assertion is only that the opt-in refusal is gone, and the run still has to
  # end for the suite to finish.
  run_spawn "$home" "$fakebin" "$endpoint" "$id" "$case_dir/no-such-project" --scout \
    --harness claude-local --model local-coder || true
  out=$(cat "$RUN_OUT")
  case "$out" in
    *"opt-in only"*) fail "an explicit per-spawn harness was still refused as a default: $out" ;;
  esac

  pass "a home-wide default cannot select claude-local, while an explicit per-spawn harness can"
}

# A secondmate is a firstmate instance needing a primary supervision protocol.
# claude-local has no primary evidence, so both the spawn and the control plane
# refuse it - the control plane matters because it decides a RELAUNCH before the
# running agent has been stopped.
test_secondmate_is_refused_in_both_planes() {
  local home fakebin endpoint case_dir id out
  read -r home fakebin endpoint case_dir <<<"$(make_world secondmate)"
  id="cl-secondmate-x1"
  fm_test_spawn_brief "$home" "$id" "charter"

  run_spawn "$home" "$fakebin" "$endpoint" "$id" claude-local --secondmate --model local-coder \
    && fail "claude-local was accepted as a secondmate harness"
  out=$(cat "$RUN_OUT")
  case "$out" in
    *"crewmate/scout adapter only"*) : ;;
    *) fail "the secondmate refusal did not explain the boundary: $out" ;;
  esac

  fm_control_harness_supports_kind claude-local secondmate \
    && fail "the control plane let claude-local claim a secondmate relaunch"
  fm_control_harness_supports_kind claude-local ship \
    || fail "the control plane must still allow claude-local for ordinary work"

  pass "claude-local is refused as a secondmate by both the spawn and the control plane"
}

# no-mistakes is firstmate's highest-rigor route and runs long, repeated,
# large-context review and fix turns. The other two delivery modes are not
# blocked, so the assertion is that the refusal is specific to no-mistakes
# rather than a blanket ban on shipping.
test_no_mistakes_mode_is_refused() {
  local home fakebin endpoint case_dir id out
  read -r home fakebin endpoint case_dir <<<"$(make_world nomistakes)"
  id="cl-nm-x1"
  fm_test_spawn_brief "$home" "$id" "tiny brief"

  run_spawn "$home" "$fakebin" "$endpoint" "$id" "$home/projects" \
    --mode no-mistakes --yolo off --harness claude-local --model local-coder \
    && fail "claude-local was accepted for no-mistakes shipping work"
  out=$(cat "$RUN_OUT")
  case "$out" in
    *"not verified for no-mistakes"*) : ;;
    *) fail "the no-mistakes refusal did not name the boundary: $out" ;;
  esac

  run_spawn "$home" "$fakebin" "$endpoint" "$id" "$case_dir/no-such-project" \
    --mode direct-PR --yolo off --harness claude-local --model local-coder || true
  out=$(cat "$RUN_OUT")
  case "$out" in
    *"not verified for no-mistakes"*) fail "direct-PR was wrongly caught by the no-mistakes gate: $out" ;;
  esac

  pass "claude-local is refused for no-mistakes work and only for it"
}

# The endpoint serves whatever model is loaded regardless of the id a request
# names (verified against LM Studio 2026-09-01), so an omitted model id cannot
# be quietly filled in from a default - it has to be refused.
test_missing_model_is_refused() {
  local home fakebin endpoint case_dir id out
  read -r home fakebin endpoint case_dir <<<"$(make_world model)"
  id="cl-model-x1"
  fm_test_spawn_brief "$home" "$id" "tiny brief"

  run_spawn "$home" "$fakebin" "$endpoint" "$id" "$home/projects" --scout --harness claude-local \
    && fail "claude-local launched without an explicit model id"
  out=$(cat "$RUN_OUT")
  case "$out" in
    *"requires an explicit --model"*) : ;;
    *) fail "the missing-model refusal was not actionable: $out" ;;
  esac
  pass "claude-local refuses to guess which local model it is talking to"
}

# The whole design rests on claude-local INHERITING claude's verified tables
# rather than carrying its own copy of them. If either of these stops holding,
# the adapter has silently grown a second implementation of a shape the shared
# owner is supposed to own.
test_it_inherits_claudes_verified_tables() {
  local family sources
  family=$(fm_control_harness_family claude-local) \
    || fail "claude-local resolved to no control family at all"
  [ "$family" = claude ] \
    || fail "claude-local must resolve to the claude control family, got '$family'"

  fm_control_harness_supported claude-local \
    || fail "claude-local must be a supported control adapter"

  sources=$(fm_busy_sources_for_harness claude-local)
  case "$sources" in
    *claude-hook*) : ;;
    *) fail "claude-local must trust claude's semantic busy source, got '$sources'" ;;
  esac
  # And it must not have been handed a source that belongs to another adapter.
  case "$sources" in
    *opencode-plugin*|*pi-ext*) fail "claude-local trusts a foreign adapter's source: $sources" ;;
  esac

  pass "claude-local inherits claude's control family and semantic busy source"
}

test_it_uses_claudes_shared_busy_signature() {
  local busy_tail idle_tail
  busy_tail='working  esc to interrupt'
  idle_tail='ready for the next instruction'

  printf '%s' "$busy_tail" | fm_busy_lines_match claude \
    || fail "claude did not classify its known busy tail as busy"
  printf '%s' "$busy_tail" | fm_busy_lines_match claude-local \
    || fail "claude-local did not classify claude's known busy tail as busy"
  if printf '%s' "$idle_tail" | fm_busy_lines_match claude; then
    fail "claude classified an idle tail as busy"
  fi
  if printf '%s' "$idle_tail" | fm_busy_lines_match claude-local; then
    fail "claude-local classified an idle tail as busy"
  fi

  pass "claude and claude-local classify the same busy and idle tails identically"
}

test_spawn_arms_an_executable_eviction_check() {
  local home fakebin endpoint case_dir project worktree id out status
  read -r home fakebin endpoint case_dir <<<"$(make_world watcher)"
  id="cl-watcher-x1"
  project="$case_dir/project"
  worktree="$case_dir/worktree"
  fm_test_spawn_brief "$home" "$id" "tiny brief"
  fm_git_worktree "$project" "$worktree" "fm/$id"

  status=0
  FM_FAKE_PANE_PATH="$worktree" run_spawn "$home" "$fakebin" "$endpoint" \
    "$id" "$project" --scout --harness claude-local --model local-coder || status=$?
  [ "$status" -eq 0 ] || fail "claude-local spawn did not arm its watcher check: $(cat "$RUN_OUT")"
  assert_present "$home/state/$id.check.sh" "claude-local spawn did not register a watcher check"
  assert_present "$home/state/$id.check-trust" "claude-local spawn did not bind its watcher check"

  set_model_state "$case_dir" not-loaded 0
  status=0
  run_check "$home/state/$id.check.sh" alive "$id" || status=$?
  out=$(cat "$CHECK_OUT")
  [ "$status" -eq 0 ] || fail "the registered watcher check did not run"
  case "$out" in
    blocked:*"no longer loaded"*) : ;;
    *) fail "the registered watcher check did not report eviction: '$out'" ;;
  esac
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] \
    || fail "the registered watcher check must print exactly one wake line"

  pass "a claude-local spawn registers an executable watcher check that reports eviction"
}


# The bounded launch context lives in the canonical template. A raw launch
# command is the unverified-adapter escape hatch and would run whatever it
# names verbatim, so a raw command whose executable is called claude-local
# would pass the local-model gates and then launch with no endpoint pin, no
# model pin, and no context bound. It is refused, and the refusal names the
# form that does carry the bounds.
test_raw_claude_local_command_is_refused() {
  local home fakebin endpoint case_dir id out
  read -r home fakebin endpoint case_dir <<<"$(make_world raw)"
  id="cl-raw-x1"
  fm_test_spawn_brief "$home" "$id" "tiny brief"

  run_spawn "$home" "$fakebin" "$endpoint" "$id" "$home/projects" \
    "claude-local --model local-coder" --scout \
    && fail "a raw claude-local launch command was accepted"
  out=$(cat "$RUN_OUT")
  case "$out" in
    *"bypasses the bounded local-model launch context"*) : ;;
    *) fail "the raw-command refusal did not name the bound it protects: $out" ;;
  esac
  case "$out" in
    *"--harness claude-local"*) : ;;
    *) fail "the raw-command refusal did not name the harness form to use instead: $out" ;;
  esac
  [ ! -e "$home/state/$id.meta" ] && [ ! -e "$home/state/$id.check.sh" ] \
    || fail "a refused raw claude-local command left task state behind"

  pass "a raw launch command named claude-local is refused in favour of the harness form"
}

# A tmux and ps pair that answers the endpoint's agent-state classifier with
# exactly one verdict per FM_FAKE_AGENT value: `alive` shows the window with a
# claude foreground process, `missing` reports the session gone, and
# `unreadable` fails the inventory with an unclassifiable error.
make_agent_state_fakebin() {  # <dir> -> echoes the fakebin path
  local fakebin
  fakebin=$(fm_fakebin "$1")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  list-windows)
    case "${FM_FAKE_AGENT:-}" in
      alive) printf 'fm-%s\n' "$FM_FAKE_TASK"; exit 0 ;;
      missing) printf "can't find session: firstmate\n" >&2; exit 1 ;;
      *) printf 'inventory unavailable\n' >&2; exit 1 ;;
    esac
    ;;
  display-message)
    case "$*" in
      *pane_tty*) printf '/dev/ttyfake\n' ;;
      *pane_current_command*) printf 'claude\n' ;;
      *) printf 'firstmate\n' ;;
    esac
    exit 0
    ;;
esac
exit 0
SH
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" -t "*) printf '1 1 1 claude\n' ;;
  *" -p "*) printf 'claude\n' ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux" "$fakebin/ps"
  printf '%s\n' "$fakebin"
}

# run_check <check> <agent-verdict> <id>
# Runs the registered check with the endpoint answering <agent-verdict>.
# Captures its stdout into the file named by CHECK_OUT and RETURNS the check's
# exit status, for the same reason run_spawn does not print.
CHECK_OUT=
run_check() {
  local check=$1 verdict=$2 id=$3 agentbin
  agentbin=$(make_agent_state_fakebin "$TMP_ROOT/agent-$verdict-$id")
  CHECK_OUT="$TMP_ROOT/check-out.$$"
  PATH="$agentbin:$PATH" FM_FAKE_AGENT="$verdict" FM_FAKE_TASK="$id" "$check" > "$CHECK_OUT"
}

# The watcher exists to make a stall under a LIVE worker loud. An ordinary
# idle unload after the worker has finished is not a stall, and wake() has no
# dedup, so that case must be silent. The asymmetry is deliberate: silence
# needs a CONFIDENT dead verdict. An endpoint that cannot be read, combined
# with an evicted model, is exactly when a silent stall is most likely, so the
# unknown verdict stays loud. All three are asserted because a check that was
# disabled outright would pass the silence half alone.
test_eviction_check_is_gated_on_worker_liveness() {
  local home fakebin endpoint case_dir project worktree id check out status
  read -r home fakebin endpoint case_dir <<<"$(make_world liveness)"
  id="cl-live-x1"
  project="$case_dir/project"
  worktree="$case_dir/worktree"
  fm_test_spawn_brief "$home" "$id" "tiny brief"
  fm_git_worktree "$project" "$worktree" "fm/$id"
  status=0
  FM_FAKE_PANE_PATH="$worktree" run_spawn "$home" "$fakebin" "$endpoint" \
    "$id" "$project" --scout --harness claude-local --model local-coder || status=$?
  [ "$status" -eq 0 ] || fail "claude-local spawn did not arm its watcher check: $(cat "$RUN_OUT")"
  check="$home/state/$id.check.sh"
  set_model_state "$case_dir" not-loaded 0

  run_check "$check" alive "$id" || fail "the check did not run against a live worker"
  out=$(cat "$CHECK_OUT")
  case "$out" in
    blocked:*"no longer loaded"*) : ;;
    *) fail "an evicted model under a live worker must stay loud, got: '$out'" ;;
  esac
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] \
    || fail "the live-worker alarm must be exactly one line"

  run_check "$check" missing "$id" || fail "the check must exit cleanly for a confidently dead worker"
  out=$(cat "$CHECK_OUT")
  [ -z "$out" ] || fail "an idle unload after the worker is gone must be silent, got: '$out'"

  run_check "$check" unreadable "$id" || fail "the check did not run against an unreadable endpoint"
  out=$(cat "$CHECK_OUT")
  case "$out" in
    blocked:*"no longer loaded"*) : ;;
    *) fail "an evicted model under an unreadable endpoint must stay loud, got: '$out'" ;;
  esac

  set_model_state "$case_dir" loaded 131072
  run_check "$check" alive "$id" || fail "the check did not run against a loaded model"
  out=$(cat "$CHECK_OUT")
  [ -z "$out" ] || fail "a loaded model under a live worker must be silent, got: '$out'"

  pass "the eviction check is silent only for a confidently dead worker and loud for alive and unknown"
}

test_home_default_cannot_select_it
test_secondmate_is_refused_in_both_planes
test_no_mistakes_mode_is_refused
test_missing_model_is_refused
test_it_inherits_claudes_verified_tables
test_it_uses_claudes_shared_busy_signature
test_spawn_arms_an_executable_eviction_check
test_raw_claude_local_command_is_refused
test_eviction_check_is_gated_on_worker_liveness
