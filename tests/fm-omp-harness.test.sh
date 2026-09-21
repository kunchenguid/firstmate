#!/usr/bin/env bash
# tests/fm-omp-harness.test.sh - the portable regression for the omp (Oh My Pi)
# adapter: detection, session-lock identity, tmux liveness classification, the
# spawn launch line and worker posture overlay, pre-launch model validation, the
# per-task busy-state extension, the extension supervision model and ownership
# proof, and the two tracked primary extensions driven over a fake omp API.
#
# omp's identity, launch, and lifecycle checks are HARNESS-DEPENDENT: their
# verdicts come from what the vendor emits (a process name, a settings schema,
# an extension event). This suite pins the LOGIC with real processes, a fake
# omp binary, and a plain Node host, so CI enforces it with no omp installed;
# FM_OMP_LIVE_E2E=1 tests/fm-omp-primary-live-e2e.test.sh is the live guard that
# catches vendor drift against a real omp. Neither replaces the other.
#
# The load-bearing contracts:
#   1. omp publishes no marker; the anchored process name `omp` is the ancestry
#      evidence, and ompd/comp never identify.
#   2. FM_OMP_HARNESS=omp is a precedence override that needs a real omp
#      ancestor: it beats an inherited CLAUDECODE under omp and is inert when it
#      leaks into a worker whose ancestry holds no omp.
#   3. Every omp launch clears foreign markers, carries the tracked posture
#      overlay, --auto-approve, --cwd, and (for a crewmate) one -e pointing at
#      state/<id>.omp-ext.ts; a secondmate launch names no -e at all.
#   4. A <provider>/<id> model is validated only when `omp models --json` lists
#      that provider; an unlisted provider passes through with a notice.
#   5. Busy state: agent_start is busy, agent_end with willContinue stays busy,
#      a plain agent_end is idle, turn_end is a notification only.
#   6. The turn-end guard extension compels one continuation on exit 2 and
#      stands down when the payload already carries stop_hook_active.
#   7. The watch extension arms through fm_watch_arm_omp and delivers an
#      actionable close as one follow-up.
#   8. An omp SHIP spawn is a durable coordinator: the intake clock names one
#      implementation agent (stored in the record, reused across relaunches),
#      the launch carries FM_ALLOW_SUBAGENT=1, the brief names the coordinator
#      scope, the extension gates the task tool to one non-isolated item for
#      the recorded agent, and the overlay pins one child, no grandchild, and
#      a shared worktree.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=bin/fm-composer-lib.sh
. "$ROOT/bin/fm-composer-lib.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$ROOT/bin/fm-control-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$ROOT/bin/fm-session-lock-lib.sh"

HARNESS="$ROOT/bin/fm-harness.sh"
TMP_ROOT=$(fm_test_tmproot fm-omp-harness)
export NODE_NO_WARNINGS=1

# A process whose kernel-recorded identity is the bare name `omp`: a SYMLINK to
# the system shell, never a copy (a copied platform binary fails macOS code
# signing). macOS reports the symlink name through `ps -o comm=`, which is the
# exact signal under test. Every `-c` body below ends in a no-op so bash does
# not exec-optimize the single command away and replace the named process.
make_named_shells() {  # <dir> -> echoes <bindir>
  local dir=$1 name
  mkdir -p "$dir"
  for name in omp ompd comp; do
    ln -sf /bin/bash "$dir/$name"
  done
  printf '%s' "$dir"
}

# --- 1. Detection --------------------------------------------------------------

test_detection_anchored_name_and_marker_precedence() {
  local bin out
  bin=$(make_named_shells "$TMP_ROOT/named")
  # shellcheck disable=SC2016 # the quoted body expands inside the named shell
  out=$(env -u CLAUDECODE -u FM_OMP_HARNESS -u PI_CODING_AGENT -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
    "$bin/omp" -c '"$1"; :' _ "$HARNESS")
  [ "$out" = omp ] || fail "a process named omp must detect as omp, got '$out'"
  for decoy in ompd comp; do
    # shellcheck disable=SC2016 # the quoted body expands inside the named shell
    out=$(env -u CLAUDECODE -u FM_OMP_HARNESS -u PI_CODING_AGENT -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
      "$bin/$decoy" -c '"$1"; :' _ "$HARNESS")
    [ "$out" != omp ] || fail "'$decoy' merely contains omp and must not detect as omp"
  done
  # The marker beats an inherited CLAUDECODE only under a real omp ancestor.
  # shellcheck disable=SC2016 # the quoted body expands inside the named shell
  out=$(env -u PI_CODING_AGENT -u CURSOR_AGENT -u CURSOR_INVOKED_AS CLAUDECODE=1 FM_OMP_HARNESS=omp \
    "$bin/omp" -c '"$1"; :' _ "$HARNESS")
  [ "$out" = omp ] || fail "FM_OMP_HARNESS under an omp ancestor must outrank an inherited CLAUDECODE, got '$out'"
  # ...and is inert when it leaks into a worker with no omp ancestor.
  # shellcheck disable=SC2016 # the quoted body expands inside the named shell
  out=$(env -u PI_CODING_AGENT -u CURSOR_AGENT -u CURSOR_INVOKED_AS CLAUDECODE=1 FM_OMP_HARNESS=omp \
    bash -c '"$1"; :' _ "$HARNESS")
  [ "$out" = claude ] || fail "a leaked FM_OMP_HARNESS without an omp ancestor must not relabel a claude worker, got '$out'"
  pass "fm-harness: omp detects by its anchored name; the marker is a precedence override that needs real omp ancestry"
}

test_lock_identity_and_liveness_classification() {
  fm_harness_process_matches omp '' || fail "session-lock identity must accept the exact omp name"
  fm_harness_process_matches /usr/local/bin/omp 'omp --cwd /x' || fail "session-lock identity must accept an omp path"
  ! fm_harness_process_matches ompd '' || fail "session-lock identity must not accept ompd"
  ! fm_harness_process_matches comp '' || fail "session-lock identity must not accept comp"
  # shellcheck source=bin/fm-backend.sh
  . "$ROOT/bin/fm-backend.sh"
  fm_backend_source tmux || fail "fm_backend_source tmux failed"
  [ "$(fm_agent_process_classify_name omp)" = agent ] || fail "tmux liveness must classify omp as an agent"
  [ "$(fm_agent_process_classify_name /opt/omp/bin/omp)" = agent ] || fail "tmux liveness must classify an omp path as an agent"
  [ "$(fm_agent_process_classify_name ompd)" != agent ] || fail "tmux liveness must not classify ompd as an agent"
  [ "$(fm_agent_process_classify_name comp)" != agent ] || fail "tmux liveness must not classify comp as an agent"
  pass "session lock and tmux liveness: omp is anchored, decoys stay out"
}

# --- 2. Launch ---------------------------------------------------------------

# A fake omp that answers `models --json` with a two-provider catalog and exits
# 0 for everything else (the launch itself is only recorded by the fake tmux).
make_fake_omp() {  # <fakebin>
  cat > "$1/omp" <<'SH'
#!/usr/bin/env bash
case "$1" in
  models)
    printf '%s\n' '{"models":[{"provider":"openai-codex","id":"gpt-6-astra","selector":"openai-codex/gpt-6-astra"},{"provider":"ollama","id":"qwen3:8b","selector":"ollama/qwen3:8b"}]}'
    ;;
esac
exit 0
SH
  chmod +x "$1/omp"
}

make_spawn_case() {  # <name> <harness> <id>
  local name=$1 harness=$2 id=$3 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" claude)
  make_fake_omp "$fakebin"
  fm_test_spawn_home "$home" "$harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_test_spawn_brief "$home" "$id"
  : > "$case_dir/launch.log"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$case_dir/launch.log"
}

read_case_record() {
  # shellcheck disable=SC2034 # CASE_DIR is part of the shared record shape
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$1
EOF
}

run_scout_spawn() {  # <home> <wt> <fakebin> <launch-log> <spawn-args...>
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  FM_FAKE_LAUNCH_LOG="$launchlog" fm_test_run_spawn "$home" "$wt" "$fakebin" "$@" --scout
}

test_spawn_launch_line_and_worker_wiring() {
  local rec id=omp-launch-q1 out status launch state
  rec=$(make_spawn_case launch omp "$id")
  read_case_record "$rec"
  out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness omp --model openai-codex/gpt-6-astra --effort medium)
  status=$?
  expect_code 0 "$status" "omp scout spawn should succeed: $out"
  assert_contains "$out" "spawned $id harness=omp" "spawn did not report the omp harness"
  state="$HOME_DIR/state"
  assert_grep "harness=omp" "$state/$id.meta" "meta missing harness=omp"
  assert_grep "model=openai-codex/gpt-6-astra" "$state/$id.meta" "meta missing the pinned model"
  assert_grep "effort=medium" "$state/$id.meta" "meta missing the pinned effort"
  assert_present "$state/$id.omp-ext.ts" "omp spawn did not write the per-task extension"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS -u GEMINI_CLI -u CURSOR_AGENT -u CURSOR_INVOKED_AS FM_OMP_HARNESS=omp OMP_SKIP_SETUP=1 '$FAKEBIN_DIR/omp'" \
    "omp launch did not clear foreign markers and establish its own at the launch boundary"
  assert_contains "$launch" "--config '$ROOT/.omp/fm-worker-overlay.yml' --auto-approve --cwd '$WT_DIR'" \
    "omp launch did not carry the tracked posture overlay, --auto-approve, and the pinned working directory"
  assert_contains "$launch" "--model 'openai-codex/gpt-6-astra' --thinking 'medium' -e '$state/$id.omp-ext.ts'" \
    "omp launch did not pass the model, thinking level, and the state-resident worker extension"
  assert_contains "$launch" "encode launch-brief < '$HOME_DIR/data/$id/launch-brief.md'" "omp launch lost the canonical typed launch-brief envelope"
  case "$launch" in
    *"FM_ALLOW_SUBAGENT=1"*) fail "an omp scout launch must not carry the ship coordinator's guard escape: $launch" ;;
  esac
  case "$launch" in
    *"-e '$state/$id.omp-ext.ts' \"\$("*) ;;
    *) fail "omp launch must keep exactly one positional brief after the extension flag: $launch" ;;
  esac
  [ "$(fm_busy_classify tmux fake:w omp "$id" "$state")" = "busy fm-spawn" ] \
    || fail "omp spawn must seed the busy-state contract"
  pass "fm-spawn: the omp launch line clears markers, pins posture, and wires the state-resident extension"
}

test_spawn_model_validation_scoped_to_listed_providers() {
  local rec id out status
  rec=$(make_spawn_case model-refused omp omp-model-refused-q2)
  read_case_record "$rec"
  id=omp-model-refused-q2
  out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness omp --model openai-codex/gpt-nope)
  status=$?
  expect_code 1 "$status" "a model absent from a listed provider must refuse"
  assert_contains "$out" "is not listed by 'omp models --json' although provider 'openai-codex' is" "refusal did not name the listing evidence"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused spawn must publish no record"

  rec=$(make_spawn_case model-bridge omp omp-model-bridge-q3)
  read_case_record "$rec"
  id=omp-model-bridge-q3
  out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness omp --model claude-bridge/claude-opus-4-8)
  status=$?
  expect_code 0 "$status" "an extension-registered provider must pass through: $out"
  assert_contains "$out" "notice: omp provider 'claude-bridge' is not in 'omp models --json'" "pass-through did not state its reason"
  assert_contains "$(cat "$LAUNCH_LOG")" "--model 'claude-bridge/claude-opus-4-8'" "pass-through model did not reach the launch line"

  rec=$(make_spawn_case model-fuzzy omp omp-model-fuzzy-q4)
  read_case_record "$rec"
  id=omp-model-fuzzy-q4
  out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness omp --model astra)
  status=$?
  expect_code 0 "$status" "a bare fuzzy pattern is omp's own matcher's job: $out"
  pass "fm-spawn: omp model validation is scoped to providers the listing can prove"
}

test_secondmate_launch_relies_on_discovery() {
  # A seeded secondmate home, launched for real through fm-spawn on omp: the
  # launch must carry the posture overlay and pin --cwd to the home, and must
  # name NO -e, because omp auto-discovers the home's tracked .omp/extensions
  # and a file named both ways loads twice.
  local world home fakebin launchlog out status launch
  world="$TMP_ROOT/secondmate"
  home="$world/sm"
  mkdir -p "$world/home/state" "$world/home/data" "$world/home/config" "$home/bin" "$home/data"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf 'sm\n' > "$home/.fm-secondmate-home"
  printf 'charter\n' > "$home/data/charter.md"
  fakebin=$(make_spawn_fakebin "$world/fake" claude)
  make_fake_omp "$fakebin"
  launchlog="$world/launch.log"
  : > "$launchlog"
  # FM_BACKEND=tmux pins the fake tmux even where the developer shell carries a
  # live Herdr environment; without it auto-detection would spawn a real pane.
  out=$(PATH="$fakebin:$PATH" TMUX='fake,1,0' FM_BACKEND=tmux CLAUDECODE=1 \
    FM_ROOT_OVERRIDE='' FM_HOME="$world/home" \
    FM_STATE_OVERRIDE="$world/home/state" FM_DATA_OVERRIDE="$world/home/data" \
    FM_PROJECTS_OVERRIDE="$world/home/projects" FM_CONFIG_OVERRIDE="$world/home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_LAUNCH_LOG="$launchlog" \
    "$ROOT/bin/fm-spawn.sh" sm "$home" omp --secondmate 2>&1)
  status=$?
  expect_code 0 "$status" "omp secondmate spawn should succeed: $out"
  assert_grep "harness=omp" "$world/home/state/sm.meta" "secondmate meta missing harness=omp"
  launch=$(cat "$launchlog")
  case "$launch" in
    *" -e "*) fail "an omp secondmate launch must name no -e: omp auto-discovers .omp/extensions and a file named both ways loads twice: $launch" ;;
  esac
  assert_contains "$launch" "--config '$ROOT/.omp/fm-worker-overlay.yml' --auto-approve --cwd '$home'" "secondmate launch lost the posture overlay or the pinned home directory: $launch"
  assert_contains "$launch" "FM_OMP_HARNESS=omp OMP_SKIP_SETUP=1 '$fakebin/omp'" "secondmate launch lost the omp marker or executable"
  case "$launch" in
    *"FM_ALLOW_SUBAGENT=1"*) fail "an omp secondmate launch must not carry the ship coordinator's guard escape: $launch" ;;
  esac
  assert_contains "$launch" "FM_SUPERVISION_MODEL=extension" "an omp secondmate must run the extension supervision model"
  assert_absent "$world/home/state/sm.omp-ext.ts" "a secondmate must not receive a per-task worker extension"
  pass "fm-spawn: a real omp secondmate launch relies on auto-discovery while crewmates load one -e"
}

test_secondmate_config_pinned_model_is_validated() {
  # The same seeded secondmate home, but the harness and model come from the
  # primary's config/secondmate-harness rather than the command line: the
  # durable pin lands on MODEL after the harness case arm, so an unlisted id
  # under a listed provider must still be refused before endpoint creation.
  local world home fakebin launchlog out status
  world="$TMP_ROOT/secondmate-config-model"
  home="$world/sm"
  mkdir -p "$world/home/state" "$world/home/data" "$world/home/config" "$home/bin" "$home/data"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf 'sm\n' > "$home/.fm-secondmate-home"
  printf 'charter\n' > "$home/data/charter.md"
  printf 'omp openai-codex/gpt-nope\n' > "$world/home/config/secondmate-harness"
  fakebin=$(make_spawn_fakebin "$world/fake" claude)
  make_fake_omp "$fakebin"
  launchlog="$world/launch.log"
  : > "$launchlog"
  out=$(PATH="$fakebin:$PATH" TMUX='fake,1,0' FM_BACKEND=tmux CLAUDECODE=1 \
    FM_ROOT_OVERRIDE='' FM_HOME="$world/home" \
    FM_STATE_OVERRIDE="$world/home/state" FM_DATA_OVERRIDE="$world/home/data" \
    FM_PROJECTS_OVERRIDE="$world/home/projects" FM_CONFIG_OVERRIDE="$world/home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_LAUNCH_LOG="$launchlog" \
    "$ROOT/bin/fm-spawn.sh" sm "$home" --secondmate 2>&1)
  status=$?
  expect_code 1 "$status" "a config-pinned unlisted omp model must refuse the secondmate spawn: $out"
  assert_contains "$out" "omp model 'openai-codex/gpt-nope' is not listed by 'omp models --json' although provider 'openai-codex' is" \
    "the refusal did not name the config-pinned model under its listed provider: $out"
  assert_absent "$world/home/state/sm.meta" "a refused secondmate spawn must publish no sm.meta"
  [ ! -s "$launchlog" ] || fail "a refused secondmate spawn must record no launch: $(cat "$launchlog")"
  pass "fm-spawn: the config/secondmate-harness model pin is validated against the omp catalog before launch"
}

# --- 3. Busy state -------------------------------------------------------------

drive_omp_ext() {  # <ext-path> <mode>
  EXT_PATH="$1" MODE="$2" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
const mod = await import(pathToFileURL(process.env.EXT_PATH).href);
const handlers = {};
mod.default({ on: (name, fn) => { handlers[name] = fn; } });
// ctx.isIdle() reads false at a natural TUI agent_end on omp; the extension
// must go idle on a plain agent_end regardless of it.
const ctx = { isIdle: () => false };
switch (process.env.MODE) {
  case "handlers": console.log(Object.keys(handlers).sort().join(" ")); break;
  case "agent-start": await handlers["agent_start"]({ type: "agent_start" }, ctx); break;
  case "end-continuing": await handlers["agent_end"]({ type: "agent_end", willContinue: true }, ctx); break;
  case "end-final": await handlers["agent_end"]({ type: "agent_end" }, ctx); break;
  case "turn-end": await handlers["turn_end"]({ type: "turn_end", turnIndex: 0 }, ctx); break;
  default: throw new Error("unknown mode " + process.env.MODE);
}
if (process.env.MODE === "turn-end") {
  await new Promise((resolve) => setTimeout(resolve, 200));
}
EOF
}

test_busy_extension_lifecycle() {
  local rec id=omp-busy-q5 out state ext
  rec=$(make_spawn_case busy omp "$id")
  read_case_record "$rec"
  out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness omp)
  expect_code 0 $? "omp spawn should succeed: $out"
  state="$HOME_DIR/state"
  ext="$state/$id.omp-ext.ts"
  assert_present "$ext" "omp spawn did not write the per-task extension"
  out=$(drive_omp_ext "$ext" handlers) || fail "handler listing failed: $out"
  case " $out " in
    *" agent_settled "*) fail "the omp extension must not listen for agent_settled (omp has no such event)" ;;
  esac
  for handler in agent_start agent_end turn_end; do
    case " $out " in
      *" $handler "*) ;;
      *) fail "the omp extension must register $handler, got '$out'" ;;
    esac
  done

  rm -f "$state/$id.turn-ended"
  out=$(drive_omp_ext "$ext" turn-end) || fail "turn_end drive failed: $out"
  [ -f "$state/$id.turn-ended" ] || fail "turn_end no longer touches the notification marker"
  [ "$(fm_busy_classify tmux fake:w omp "$id" "$state")" = "busy fm-spawn" ] || fail "turn_end must stay a notification, not a state edge"

  out=$(drive_omp_ext "$ext" agent-start) || fail "agent_start drive failed: $out"
  [ "$(fm_busy_classify tmux fake:w omp "$id" "$state")" = "busy omp-ext" ] || fail "agent_start must classify 'busy omp-ext'"

  out=$(drive_omp_ext "$ext" end-continuing) || fail "continuing agent_end drive failed: $out"
  [ "$(fm_busy_classify tmux fake:w omp "$id" "$state")" = "busy omp-ext" ] || fail "agent_end with willContinue must stay busy (a session_stop continuation is coming)"

  out=$(drive_omp_ext "$ext" end-final) || fail "final agent_end drive failed: $out"
  [ "$(fm_busy_classify tmux fake:w omp "$id" "$state")" = "idle omp-ext" ] || fail "a plain agent_end must classify 'idle omp-ext'"

  # A record from another harness's writer is never trusted for omp.
  fm_busy_source_trusted omp pi-ext && fail "omp must not trust the Pi extension's records"
  fm_busy_source_trusted omp omp-ext || fail "omp must trust its own extension's records"
  pass "omp extension: agent_start busy, willContinue stays busy, plain agent_end idle, turn_end a notification"
}

# --- 3b. The omp ship coordinator ---------------------------------------------
#
# An omp SHIP spawn is a durable coordinator: it resolves one named
# implementation child from the Israel clock at intake, stores it in the task
# record, renders it into the launch brief, carries the subagent guard's
# FM_ALLOW_SUBAGENT=1 escape, and its extension admits exactly one
# non-isolated task item for that agent. FM_SPAWN_OMP_CLOCK is the injected
# deterministic time; no test reads the machine clock.

drive_omp_task_gate() {  # <ext-path> <tool-name> <input-json> -> verdict JSON
  EXT_PATH="$1" TOOL_NAME="$2" INPUT_JSON="$3" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
const mod = await import(pathToFileURL(process.env.EXT_PATH).href);
const handlers = {};
mod.default({ on: (name, fn) => { handlers[name] = fn; } });
if (!handlers["tool_call"]) throw new Error("the extension registered no tool_call handler");
const verdict = await handlers["tool_call"](
  { type: "tool_call", toolName: process.env.TOOL_NAME, input: JSON.parse(process.env.INPUT_JSON) }, {});
console.log(JSON.stringify(verdict ?? {}));
EOF
}

run_ship_spawn() {  # <home> <wt> <fakebin> <launch-log> <clock> <id> <project> [extra-args...]
  local home=$1 wt=$2 fakebin=$3 launchlog=$4 clock=$5 id=$6 project=$7
  shift 7
  FM_SPAWN_OMP_CLOCK="$clock" FM_FAKE_LAUNCH_LOG="$launchlog" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$project" --harness omp --mode no-mistakes --yolo off "$@"
}

make_relaunch_stub() {  # <fakebin-dir> <window-name>
  cat > "$1/tmux" <<SH
#!/usr/bin/env bash
set -u
case "\$*" in
  *'#{pane_current_path}'*) printf '%s\n' "\${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "\${1:-}" in
  send-keys)
    prev=
    for a in "\$@"; do
      if [ "\$prev" = "-l" ]; then printf '%s\n' "\$a" >> "\${FM_FAKE_LAUNCH_LOG:-/dev/null}"; fi
      prev=\$a
    done
    exit 0 ;;
  display-message)
    for a in "\$@"; do
      case "\$a" in
        *pane_current_command*) printf 'zsh\n'; exit 0 ;;
      esac
    done
    printf 'firstmate\n'; exit 0 ;;
  list-windows) printf '%s\n' "$2"; exit 0 ;;
esac
exit 0
SH
  chmod +x "$1/tmux"
}

test_ship_coordinator_launch_meta_and_gate() {
  local rec id=omp-ship-coord-q6 out status state launch ext gate_verdict
  rec=$(make_spawn_case ship-coord omp "$id")
  read_case_record "$rec"
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" 08:59 "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "omp ship spawn at 08:59 should succeed: $out"
  state="$HOME_DIR/state"
  [ "$(sed -n 's/^omp_worker_agent=//p' "$state/$id.meta")" = off-peak-hours-worker ] \
    || fail "the 08:59 intake must record off-peak-hours-worker in the task record: $(cat "$state/$id.meta")"
  launch=$(cat "$LAUNCH_LOG")
  case "$launch" in
    *"FM_ALLOW_SUBAGENT=1 "*) ;;
    *) fail "an omp ship launch must carry the subagent guard's launch-time escape: $launch" ;;
  esac
  case "$launch" in
    *"FM_ALLOW_SUBAGENT=1 FM_OMP_HARNESS=omp"*) ;;
    *) fail "the escape must ride the env assignment prefix next to the harness marker: $launch" ;;
  esac
  assert_grep 'durable coordinator' "$HOME_DIR/data/$id/launch-brief.md" "the ship launch brief must announce the coordinator role"
  assert_grep 'must not write or repair source code' "$HOME_DIR/data/$id/launch-brief.md" "the launch brief must forbid direct implementation"
  assert_grep 'off-peak-hours-worker' "$HOME_DIR/data/$id/launch-brief.md" "the launch brief must name the selected implementation agent"
  # The extension's own bytes are never asserted: the drives below prove the
  # pinned agent and the registered handler behaviorally. An allow case must be
  # exactly {} so a missing handler or a crashed child fails instead of reading
  # as a pass.
  ext="$state/$id.omp-ext.ts"
  gate_verdict=$(drive_omp_task_gate "$ext" task '{"tasks":[{"agent":"off-peak-hours-worker","prompt":"implement"}]}')
  [ "$gate_verdict" = "{}" ] \
    || fail "a single non-isolated item for the recorded agent must pass untouched: $gate_verdict"
  gate_verdict=$(drive_omp_task_gate "$ext" task '{"tasks":[{"agent":"peak-hours-worker"}]}')
  [ "$(printf '%s' "$gate_verdict" | jq -r '.block // empty')" = "true" ] \
    || fail "the wrong agent must be blocked: $gate_verdict"
  printf '%s' "$gate_verdict" | jq -e '.reason | test("metadata-selected")' >/dev/null \
    || fail "the wrong-agent refusal must name the metadata-selected agent: $gate_verdict"
  gate_verdict=$(drive_omp_task_gate "$ext" task '{"tasks":[{"prompt":"implement"}]}')
  [ "$(printf '%s' "$gate_verdict" | jq -r '.block // empty')" = "true" ] \
    || fail "a missing agent must be blocked: $gate_verdict"
  gate_verdict=$(drive_omp_task_gate "$ext" task '{"tasks":[{"agent":"off-peak-hours-worker"},{"agent":"off-peak-hours-worker"}]}')
  [ "$(printf '%s' "$gate_verdict" | jq -r '.block // empty')" = "true" ] \
    || fail "two task items must be blocked: $gate_verdict"
  printf '%s' "$gate_verdict" | jq -e '.reason | test("exactly one task item")' >/dev/null \
    || fail "the multi-item refusal must explain the one-item rule: $gate_verdict"
  gate_verdict=$(drive_omp_task_gate "$ext" task '{"tasks":[{"agent":"off-peak-hours-worker","isolated":true}]}')
  [ "$(printf '%s' "$gate_verdict" | jq -r '.block // empty')" = "true" ] \
    || fail "an isolated child must be blocked: $gate_verdict"
  printf '%s' "$gate_verdict" | jq -e '.reason | test("existing worktree")' >/dev/null \
    || fail "the isolated refusal must explain the shared-worktree rule: $gate_verdict"
  gate_verdict=$(drive_omp_task_gate "$ext" task '{"tasks":[]}')
  [ "$(printf '%s' "$gate_verdict" | jq -r '.block // empty')" = "true" ] \
    || fail "an empty task list must be blocked: $gate_verdict"
  # omp's runtime also accepts the flat single-item shape while task.batch is on
  # (omp://tools/task.md "Inputs"), so the gate must read that shape's item too
  # instead of refusing a legitimate single non-isolated spawn.
  gate_verdict=$(drive_omp_task_gate "$ext" task '{"agent":"off-peak-hours-worker","task":"implement"}')
  [ "$gate_verdict" = "{}" ] \
    || fail "a flat single-item call for the recorded agent must pass untouched: $gate_verdict"
  gate_verdict=$(drive_omp_task_gate "$ext" task '{"agent":"peak-hours-worker","task":"implement"}')
  [ "$(printf '%s' "$gate_verdict" | jq -r '.block // empty')" = "true" ] \
    || fail "a flat call naming the wrong agent must be blocked: $gate_verdict"
  printf '%s' "$gate_verdict" | jq -e '.reason | test("metadata-selected")' >/dev/null \
    || fail "the flat wrong-agent refusal must name the metadata-selected agent: $gate_verdict"
  gate_verdict=$(drive_omp_task_gate "$ext" bash '{"command":"ls"}')
  [ "$gate_verdict" = "{}" ] || fail "a bash call must pass the gate untouched: $gate_verdict"
  # omp's eval tool exposes agent() and workpool(), which would create a child the
  # task gate never sees (omp://tools/eval.md "Prelude helpers"), so eval is
  # closed for the coordinator as a whole.
  gate_verdict=$(drive_omp_task_gate "$ext" eval '{"language":"py","code":"h = agent(\"do work\", agent=\"off-peak-hours-worker\")"}')
  [ "$(printf '%s' "$gate_verdict" | jq -r '.block // empty')" = "true" ] \
    || fail "an eval call must be blocked for the coordinator: $gate_verdict"
  printf '%s' "$gate_verdict" | jq -e '.reason | test("agent\\(\\) and workpool\\(\\)")' >/dev/null \
    || fail "the eval refusal must name the helpers it closes: $gate_verdict"
  printf '%s' "$gate_verdict" | jq -e '.reason | test("read, grep, glob, bash, and lsp")' >/dev/null \
    || fail "the eval refusal must direct ordinary work to the approved tools: $gate_verdict"
  printf '%s' "$gate_verdict" | jq -e --arg a "off-peak-hours-worker" '.reason | test($a)' >/dev/null \
    || fail "the eval refusal must name the selected agent: $gate_verdict"
  # The block is on the tool, not on any spelling inside a cell.
  gate_verdict=$(drive_omp_task_gate "$ext" eval '{"language":"js","code":"return 1 + 1"}')
  [ "$(printf '%s' "$gate_verdict" | jq -r '.block // empty')" = "true" ] \
    || fail "even an innocent eval cell must be blocked, since the tool is closed as a whole: $gate_verdict"
  # Ordinary coordinator work still passes.
  for tool_input in 'read:{"path":"README.md"}' 'grep:{"pattern":"x"}' 'glob:{"pattern":"*.sh"}' 'lsp:{"action":"symbols"}'; do
    tool_name=${tool_input%%:*}
    input_json=${tool_input#*:}
    gate_verdict=$(drive_omp_task_gate "$ext" "$tool_name" "$input_json")
    [ "$gate_verdict" = "{}" ] || fail "an ordinary $tool_name call must pass the gate untouched: $gate_verdict"
  done
  pass "fm-spawn: the omp ship coordinator records off-peak at 08:59, carries the guard escape, and gates the task tool to one named child"
}

test_ship_coordinator_nine_oclock_boundary_and_nonomp_ship() {
  local rec id out state launch
  rec=$(make_spawn_case ship-nine omp omp-ship-nine-q7)
  read_case_record "$rec"
  id=omp-ship-nine-q7
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" 09:00 "$id" "$PROJ_DIR")
  expect_code 0 $? "omp ship spawn at 09:00 should succeed: $out"
  state="$HOME_DIR/state"
  [ "$(sed -n 's/^omp_worker_agent=//p' "$state/$id.meta")" = peak-hours-worker ] \
    || fail "the 09:00 intake must record peak-hours-worker: $(cat "$state/$id.meta")"

  rec=$(make_spawn_case ship-claude claude omp-ship-claude-q8)
  read_case_record "$rec"
  id=omp-ship-claude-q8
  out=$(FM_SPAWN_OMP_CLOCK=08:59 FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" --harness claude --mode no-mistakes --yolo off)
  expect_code 0 $? "a claude ship spawn should succeed: $out"
  launch=$(cat "$LAUNCH_LOG")
  case "$launch" in
    *"FM_ALLOW_SUBAGENT=1"*) fail "a non-omp ship launch must never carry the omp coordinator's guard escape: $launch" ;;
  esac
  assert_absent "$state/omp-ship-claude-q8.omp-ext.ts" "a non-omp ship must not receive an omp extension"
  assert_absent "$state/omp-ship-claude-q8.omp-coordinator.yml" "a non-omp ship must not receive an omp coordinator config"
  [ -f "$state/$id.meta" ] && grep -q '^omp_worker_agent=' "$state/$id.meta" \
    && fail "a non-omp ship must record no omp_worker_agent"
  pass "fm-spawn: 09:00 intake records peak-hours-worker and non-omp ships carry no coordinator wiring"
}

test_omp_scout_and_secondmate_carry_no_coordinator_config() {
  local rec id launch out
  # An omp SCOUT and an omp SECONDMATE both load the shared worker overlay, so
  # neither may receive the ship-only coordinator config or its task-tool pins.
  id=omp-scout-nocfg-q12
  rec=$(make_spawn_case scout-nocfg omp "$id")
  read_case_record "$rec"
  out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness omp)
  expect_code 0 $? "an omp scout spawn should succeed: $out"
  assert_absent "$HOME_DIR/state/$id.omp-coordinator.yml" "an omp scout must receive no coordinator config"
  # A scout has no coordinator gate at all, so its extension must register no
  # tool_call handler: eval and task stay exactly as omp ships them.
  local handlers
  handlers=$(EXT_PATH="$HOME_DIR/state/$id.omp-ext.ts" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
const mod = await import(pathToFileURL(process.env.EXT_PATH).href);
const names = [];
mod.default({ on: (name) => { names.push(name); } });
console.log(names.join(","));
EOF
)
  case "$handlers" in
    *tool_call*) fail "an omp scout extension must register no tool_call gate: $handlers" ;;
  esac
  case "$handlers" in
    *agent_start*) ;;
    *) fail "an omp scout extension must still register its busy-state handlers: $handlers" ;;
  esac
  launch=$(cat "$LAUNCH_LOG")
  case "$launch" in
    *".omp-coordinator.yml"*) fail "an omp scout launch must not pass a coordinator config: $launch" ;;
    *"FM_ALLOW_SUBAGENT=1"*) fail "an omp scout must not carry the ship coordinator's guard escape: $launch" ;;
  esac
  assert_contains "$launch" "--config '$ROOT/.omp/fm-worker-overlay.yml' --auto-approve" \
    "an omp scout must still load exactly the shared worker overlay: $launch"

  local world home fakebin launchlog
  world="$TMP_ROOT/secondmate-nocfg"
  home="$world/sm"
  mkdir -p "$world/home/state" "$world/home/data" "$world/home/config" "$home/bin" "$home/data"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf 'sm\n' > "$home/.fm-secondmate-home"
  printf 'charter\n' > "$home/data/charter.md"
  fakebin=$(make_spawn_fakebin "$world/fake" claude)
  make_fake_omp "$fakebin"
  launchlog="$world/launch.log"
  : > "$launchlog"
  # FM_BACKEND=tmux pins the fake tmux even where the developer shell carries a
  # live Herdr environment; without it auto-detection would spawn a real pane.
  out=$(PATH="$fakebin:$PATH" TMUX='fake,1,0' FM_BACKEND=tmux CLAUDECODE=1 \
    FM_ROOT_OVERRIDE='' FM_HOME="$world/home" \
    FM_STATE_OVERRIDE="$world/home/state" FM_DATA_OVERRIDE="$world/home/data" \
    FM_PROJECTS_OVERRIDE="$world/home/projects" FM_CONFIG_OVERRIDE="$world/home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_LAUNCH_LOG="$launchlog" \
    "$ROOT/bin/fm-spawn.sh" sm "$home" omp --secondmate 2>&1)
  expect_code 0 $? "an omp secondmate spawn should succeed: $out"
  assert_absent "$world/home/state/sm.omp-coordinator.yml" "an omp secondmate must receive no coordinator config"
  launch=$(cat "$launchlog")
  case "$launch" in
    *".omp-coordinator.yml"*) fail "an omp secondmate launch must not pass a coordinator config: $launch" ;;
  esac
  pass "fm-spawn: omp scouts and secondmates receive no coordinator config"
}

test_ship_relaunch_reuses_stored_agent_across_clock_window() {
  local rec id=omp-ship-relaunch-q9 out status state window relaunch_stub relaunch_log gate_verdict
  rec=$(make_spawn_case ship-relaunch omp "$id")
  read_case_record "$rec"
  state="$HOME_DIR/state"
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" 08:59 "$id" "$PROJ_DIR")
  expect_code 0 $? "the 08:59 fresh spawn should succeed: $out"
  [ "$(sed -n 's/^omp_worker_agent=//p' "$state/$id.meta")" = off-peak-hours-worker ] \
    || fail "the fresh spawn must record off-peak-hours-worker"

  # A relaunch at 10:00 (the peak window) must reuse the stored off-peak name:
  # intake time, not recovery time, owns the choice.
  window=$(sed -n 's/^window=//p' "$state/$id.meta")
  relaunch_stub="$TMP_ROOT/relaunch-bin-$id"
  mkdir -p "$relaunch_stub"
  make_relaunch_stub "$relaunch_stub" "${window##*:}"
  cp "$FAKEBIN_DIR/omp" "$relaunch_stub/omp"
  relaunch_log="$CASE_DIR/relaunch.log"
  : > "$relaunch_log"
  out=$(FM_SPAWN_OMP_CLOCK=10:00 FM_FAKE_LAUNCH_LOG="$relaunch_log" \
    PATH="$relaunch_stub:$PATH" FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="${TMUX:-fake,1,0}" \
    "$ROOT/bin/fm-spawn.sh" "$id" --relaunch 2>&1)
  status=$?
  expect_code 0 "$status" "the omp ship relaunch should succeed: $out"
  [ "$(sed -n 's/^omp_worker_agent=//p' "$state/$id.meta" | tail -1)" = off-peak-hours-worker ] \
    || fail "the relaunch must reuse the stored agent across the clock window: $(cat "$state/$id.meta")"
  [ "$(grep -c '^omp_worker_agent=' "$state/$id.meta")" = 1 ] \
    || fail "the relaunched record must keep exactly one omp_worker_agent line"
  assert_grep 'off-peak-hours-worker' "$HOME_DIR/data/$id/launch-brief.md" "the relaunched brief must keep naming the stored agent"
  # The relaunched extension still admits the STORED agent and still refuses
  # the other window's agent, which is the behavioral form of "the relaunch
  # reused what intake chose".
  gate_verdict=$(drive_omp_task_gate "$state/$id.omp-ext.ts" task '{"tasks":[{"agent":"off-peak-hours-worker"}]}')
  [ "$gate_verdict" = "{}" ] \
    || fail "the relaunched extension must still admit the stored agent: $gate_verdict"
  gate_verdict=$(drive_omp_task_gate "$state/$id.omp-ext.ts" task '{"tasks":[{"agent":"peak-hours-worker"}]}')
  [ "$(printf '%s' "$gate_verdict" | jq -r '.block // empty')" = "true" ] \
    || fail "the relaunched extension must still refuse the other window's agent: $gate_verdict"
  case "$(cat "$relaunch_log")" in
    *"FM_ALLOW_SUBAGENT=1 "*) ;;
    *) fail "the relaunched omp ship must still carry the guard escape: $(cat "$relaunch_log")" ;;
  esac
  pass "fm-spawn: an omp ship relaunch in the opposite clock window reuses the intake-selected agent"
}

test_worker_overlay_pins_task_shape() {
  local cfg="$ROOT/.omp/fm-worker-overlay.yml"
  # The shared overlay is loaded by EVERY omp role, so it must carry no task-tool
  # limit at all: those keys belong to the coordinator role alone.
  assert_no_grep 'task:' "$cfg" "the shared worker overlay must not pin task-tool settings for scouts and secondmates"
  assert_no_grep 'maxConcurrency' "$cfg" "the shared worker overlay must not pin one-child concurrency for every omp role"
  assert_no_grep 'maxRecursionDepth' "$cfg" "the shared worker overlay must not pin child depth for every omp role"
  assert_no_grep 'isolation' "$cfg" "the shared worker overlay must not pin isolation for every omp role"

  # A ship launch writes the coordinator config into its own task state and
  # passes it as a second --config; a scout or secondmate never receives either.
  local id=omp-coord-cfg-q10 rec launch state coordcfg
  rec=$(make_spawn_case ship-coordcfg omp "$id")
  read_case_record "$rec"
  run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" 08:59 "$id" "$PROJ_DIR" >/dev/null || fail "ship spawn failed"
  state="$HOME_DIR/state"
  coordcfg="$state/$id.omp-coordinator.yml"
  assert_present "$coordcfg" "an omp ship launch must write its task-owned coordinator config"
  assert_grep 'maxConcurrency: 1' "$coordcfg" "the coordinator config must pin one-child concurrency"
  assert_grep 'maxRecursionDepth: 1' "$coordcfg" "the coordinator config must allow exactly one child level and forbid fan-out"
  assert_grep 'isolation:' "$coordcfg" "the coordinator config must pin the isolation block"
  assert_grep 'enabled: false' "$coordcfg" "the coordinator config must keep the one child in the shared worktree"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "--config '$ROOT/.omp/fm-worker-overlay.yml' --config '$coordcfg'" \
    "an omp ship launch must pass the coordinator config as a second --config: $launch"

  local scout_id=omp-coord-scout-q11
  rec=$(make_spawn_case ship-coordcfg-scout omp "$scout_id")
  read_case_record "$rec"
  run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$scout_id" "$PROJ_DIR" --harness omp >/dev/null || fail "scout spawn failed"
  assert_absent "$HOME_DIR/state/$scout_id.omp-coordinator.yml" "an omp scout must receive no coordinator config"
  launch=$(cat "$LAUNCH_LOG")
  case "$launch" in
    *".omp-coordinator.yml"*) fail "an omp scout launch must not pass a coordinator config: $launch" ;;
  esac
  pass "omp ship-only coordinator config: one child, no grandchild, shared worktree, absent for scouts"
}

# --- 4. Control, composer, supervision model -----------------------------------

test_control_composer_and_model_tables() {
  [ "$(fm_control_exit_command omp)" = /quit ] || fail "omp exit command must be /quit"
  [ "$(fm_control_interrupt_key omp)" = Escape ] || fail "omp interrupt key must be Escape"
  [ "$(fm_control_interrupt_repeat omp)" = 1 ] || fail "omp interrupts on a single press"
  [ -z "$(fm_control_interrupt_clear_key omp)" ] || fail "omp leaves its composer empty and needs no clear key"
  [ "$(fm_control_harness_wiring_paths omp /wt /st id1)" = "/st/id1.omp-ext.ts
/st/id1.omp-coordinator.yml" ] || fail "omp wiring paths must be the state-resident extension plus the ship-only coordinator config"
  printf 'Working…\n' | fm_busy_lines_match omp || fail "omp busy regex must match the TUI ellipsis form"
  printf 'Working...\n' | fm_busy_lines_match omp && fail "omp busy regex must not match the three-dot form no supervised pane renders"
  printf ' ⠧ 11s  · gpt-6-astra\n' | fm_busy_lines_match omp || fail "omp busy regex must match the braille spinner plus elapsed cell"
  printf ' ⣾ 3s  · gpt-6-astra\n' | fm_busy_lines_match omp || fail "omp busy regex must match the status-set spinner frames, not only the activity set"
  printf ' 󰵗  · gpt-6-astra · 36.7%%/41K\n' | fm_busy_lines_match omp && fail "an idle omp status row must not read busy"
  printf 'esc to interrupt\n' | fm_busy_lines_match omp && fail "omp must not borrow Claude's footer"
  local bin out
  bin=$(make_named_shells "$TMP_ROOT/named-model")
  # shellcheck disable=SC2016 # the quoted body expands inside the named shell
  out=$(env -u CLAUDECODE -u FM_OMP_HARNESS -u PI_CODING_AGENT -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u FM_SUPERVISION_MODEL \
    "$bin/omp" -c '. "$1"; fm_supervision_model' _ "$ROOT/bin/fm-wake-lib.sh")
  [ "$out" = extension ] || fail "an omp primary must run the extension supervision model, got '$out'"
  pass "control, composer, and supervision-model tables carry omp's verified values"
}

# --- 5. Ownership proof --------------------------------------------------------

# Stand up the durable evidence a live omp session leaves behind: both tracked
# extensions under the case root and one marker per extension recording that
# build plus the session pid in state/.lock.
record_omp_session() {  # <root> <home> <session-pid> [omit] [drift]
  local root=$1 home=$2 session_pid=$3 omit=${4:-} drift=${5:-} pair source marker version
  mkdir -p "$root/.omp/extensions" "$home/state"
  for pair in \
    "fm-primary-omp-watch.ts:.omp-watch-extension-loaded:watch" \
    "fm-primary-turnend-guard.ts:.omp-turnend-extension-loaded:turnend"; do
    source=${pair%%:*}
    marker=${pair#*:}; marker=${marker%%:*}
    printf '// %s\n' "${pair##*:}" > "$root/.omp/extensions/$source"
    [ "$omit" = "${pair##*:}" ] && continue
    if [ "$drift" = "${pair##*:}" ]; then
      version="sha256:0000000000000000000000000000000000000000000000000000000000000000"
    else
      version=$(bash -c '. "$1"; fm_pi_extension_version "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$root/.omp/extensions/$source") || return 1
    fi
    printf '%s\n%s\n' "$version" "$session_pid" > "$home/state/$marker"
  done
  printf '%s\n' "$session_pid" > "$home/state/.lock"
}

owns() {  # <root> <home>
  bash -c '. "$1"; fm_omp_extension_owns_supervision "$2" "$3"' _ "$ROOT/bin/fm-wake-lib.sh" "$2/state" "$1"
}

test_ownership_proof_is_omp_keyed() {
  local root home pid
  sleep 60 &
  pid=$!
  root="$TMP_ROOT/own/root"; home="$TMP_ROOT/own/home"
  record_omp_session "$root" "$home" "$pid" || fail "could not record the omp session"
  owns "$root" "$home" || fail "a live session that loaded both omp extensions must own supervision"
  bash -c '. "$1"; fm_pi_extension_owns_supervision "$2" "$3"' _ "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$root" \
    && fail "omp markers must never satisfy the Pi proof"
  bash -c '. "$1"; fm_extension_owns_supervision "$2" "$3"' _ "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$root" \
    || fail "the shared extension proof must accept the omp pair"

  root="$TMP_ROOT/own-drift/root"; home="$TMP_ROOT/own-drift/home"
  record_omp_session "$root" "$home" "$pid" "" watch || fail "could not record the drifted session"
  owns "$root" "$home" && fail "a session that loaded an older watch build must not own supervision"
  root="$TMP_ROOT/own-omit/root"; home="$TMP_ROOT/own-omit/home"
  record_omp_session "$root" "$home" "$pid" turnend || fail "could not record the partial session"
  owns "$root" "$home" && fail "a session missing the turn-end guard extension must not own supervision"
  root="$TMP_ROOT/own-dead/root"; home="$TMP_ROOT/own-dead/home"
  record_omp_session "$root" "$home" "$pid" || fail "could not record the dead session"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  owns "$root" "$home" && fail "a dead session must not own supervision"

  # The pull-guard verdict tolerates the extension's own hand-off only with the proof.
  sleep 60 &
  pid=$!
  root="$TMP_ROOT/own-verdict/root"; home="$TMP_ROOT/own-verdict/home"
  record_omp_session "$root" "$home" "$pid" || fail "could not record the verdict session"
  touch "$home/state/.last-watcher-beat"
  local verdict
  verdict=$(FM_SUPERVISION_MODEL=extension FM_HOME="$home" bash -c '
    . "$1"; fm_watcher_supervision_verdict "$2" "$3" 999 "$4" "$5"; printf "%s %s" "$FM_WATCHER_VERDICT_OK" "$FM_WATCHER_VERDICT_REASON"' \
    _ "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$root/bin/fm-watch.sh" "$home" "$root")
  [ "${verdict%% *}" = true ] || fail "an unheld lock with a fresh beacon and the omp proof must be healthy, got '$verdict'"
  rm -f "$home/state/.omp-turnend-extension-loaded"
  verdict=$(FM_SUPERVISION_MODEL=extension FM_HOME="$home" bash -c '
    . "$1"; fm_watcher_supervision_verdict "$2" "$3" 999 "$4" "$5"; printf "%s %s" "$FM_WATCHER_VERDICT_OK" "$FM_WATCHER_VERDICT_REASON"' \
    _ "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$root/bin/fm-watch.sh" "$home" "$root")
  [ "$verdict" = "false no-watcher" ] || fail "without the proof the same hand-off must alarm as no-watcher, got '$verdict'"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  pass "fm-wake-lib: the omp ownership proof is keyed on its own extensions and gates the hand-off tolerance"
}

# --- 6. The tracked primary extensions over a fake omp API ----------------------

install_omp_extension_fixture() {  # <repo>
  local repo=$1
  mkdir -p "$repo/.omp/extensions" "$repo/.pi/extensions/lib" "$repo/bin" "$repo/node_modules/typebox"
  cp "$ROOT/.omp/extensions/fm-primary-turnend-guard.ts" "$ROOT/.omp/extensions/fm-primary-omp-watch.ts" "$repo/.omp/extensions/"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$ROOT/.pi/extensions/lib/fm-sessionstart-supervisor.mjs" "$repo/.pi/extensions/lib/"
  cp "$ROOT/bin/fm-operational-input.sh" "$repo/bin/"
  chmod +x "$repo/bin/fm-operational-input.sh"
  printf '{"name":"typebox","type":"module","exports":"./index.js"}\n' > "$repo/node_modules/typebox/package.json"
  printf 'export const Type = { Object(p) { return { type: "object", properties: p }; } };\n' > "$repo/node_modules/typebox/index.js"
}

test_turnend_guard_extension_compels_one_continuation() {
  local repo home out status
  repo="$TMP_ROOT/guard/repo"; home="$TMP_ROOT/guard/home"
  install_omp_extension_fixture "$repo"
  mkdir -p "$home/state"
  cat > "$repo/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
payload=$(cat); printf '%s\n' "$payload" >> "${FM_GUARD_LOG:?}"
case "$payload" in *'"stop_hook_active":true'*) exit 0 ;; esac
printf 'guard says: repair with fm_watch_arm_omp\n' >&2; exit 2
SH
  cat > "$repo/bin/fm-arm-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
case "$*" in *fm-watch-arm.sh*'&'*) printf 'fm watcher-arm seatbelt: blocked\n' >&2; exit 2 ;; esac; exit 0
SH
  printf '#!/usr/bin/env bash\nexit 0\n' > "$repo/bin/fm-cd-pretool-check.sh"
  # shellcheck disable=SC2016 # $2 expands in the generated script
  printf '#!/usr/bin/env bash\nprintf "OMP DIGEST source=%%s\\n" "$2"\n' > "$repo/bin/fm-sessionstart-run.sh"
  chmod +x "$repo/bin/"*.sh
  out=$(FM_GUARD_LOG="$TMP_ROOT/guard/guard.log" FM_HOME="$home" EXT="$repo/.omp/extensions/fm-primary-turnend-guard.ts" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { readFileSync, existsSync } from "node:fs";
const handlers = new Map();
const pi = { on(e, h) { handlers.set(e, h); }, sendMessage() {} };
const mod = await import(pathToFileURL(process.env.EXT).href);
mod.default(pi);
for (const name of ["session_start", "before_agent_start", "session_compact", "session_shutdown", "tool_call", "session_stop"]) {
  if (!handlers.has(name)) throw new Error(`${name} handler was not registered`);
}
if (handlers.has("agent_settled")) throw new Error("omp guard must not listen for agent_settled");
const ctx = { sessionManager: { getSessionId: () => "s1" } };
handlers.get("session_start")({ type: "session_start" }, ctx);
const first = await handlers.get("before_agent_start")({ type: "before_agent_start", prompt: "hi" }, ctx);
if (!first?.message?.content?.includes("FIRSTMATE_OP: v1 session-start: OMP DIGEST source=startup")) throw new Error(`first start did not deliver a startup digest: ${JSON.stringify(first)}`);
if (first.message.display !== false || first.message.customType !== "firstmate-sessionstart-nudge") throw new Error("digest message lost its persistent shape");
// A later in-process session_start is a replacement and maps to clear.
handlers.get("session_start")({ type: "session_start" }, ctx);
const second = await handlers.get("before_agent_start")({ type: "before_agent_start", prompt: "hi" }, ctx);
if (!second?.message?.content?.includes("source=clear")) throw new Error(`in-process replacement did not map to clear: ${JSON.stringify(second)}`);
const allowed = await handlers.get("tool_call")({ type: "tool_call", toolName: "bash", input: { command: "ls" } }, {});
if (allowed.block) throw new Error("an ordinary command was blocked");
const blocked = await handlers.get("tool_call")({ type: "tool_call", toolName: "bash", input: { command: "bin/fm-watch-arm.sh &" } }, {});
if (blocked.block !== true || !blocked.reason.includes("seatbelt")) throw new Error(`backgrounded arm was not blocked: ${JSON.stringify(blocked)}`);
const r1 = await handlers.get("session_stop")({ type: "session_stop", stop_hook_active: false }, {});
if (r1?.continue !== true) throw new Error(`guard exit 2 did not compel a continuation: ${JSON.stringify(r1)}`);
if (!r1.additionalContext.startsWith("⁣FIRSTMATE_OP: v1 turn-end-guard: ")) throw new Error(`continuation context is not typed operational input: ${r1.additionalContext}`);
if (!r1.additionalContext.includes("TURN WOULD END BLIND") || !r1.additionalContext.includes("repair with fm_watch_arm_omp")) throw new Error("continuation dropped the guard text");
const r2 = await handlers.get("session_stop")({ type: "session_stop", stop_hook_active: true }, {});
if (r2 !== undefined) throw new Error(`the flagged second stop must stand down, got ${JSON.stringify(r2)}`);
const payloads = readFileSync(process.env.FM_GUARD_LOG, "utf8").trim().split("\n");
if (payloads.join("|") !== '{"stop_hook_active":false}|{"stop_hook_active":true}') throw new Error(`guard payloads were ${payloads.join("|")}`);
if (!existsSync(`${process.env.FM_HOME}/state/.omp-turnend-extension-loaded`)) throw new Error("loaded marker was not written");
await handlers.get("session_shutdown")({}, {});
EOF
)
  status=$?
  expect_code 0 "$status" "omp turn-end guard extension contract: $out"
  [ -z "$out" ] || fail "omp guard extension test printed output: $out"
  pass ".omp turn-end guard: digest delivery, seatbelt block, one compelled continuation, flagged stop stands down"
}

test_watch_extension_arms_and_delivers() {
  local repo home out status
  repo="$TMP_ROOT/watch/repo"; home="$TMP_ROOT/watch/home"
  install_omp_extension_fixture "$repo"
  mkdir -p "$home/state"
  # The first arm child closes with one actionable reason; every successor
  # stays up, so exactly one wake exists to consume.
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'watcher: started pid=%s (beacon 0s) recovery-generation=gen-1\n' "$$"
if [ ! -e "${FM_HOME:?}/state/.e2e-fired" ]; then
  : > "$FM_HOME/state/.e2e-fired"
  sleep 1
  printf 'signal: omp-e2e done\n'
  exit 0
fi
sleep 30
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_OMP_ARM_READY_TIMEOUT_MS=3000 FM_WATCH_REARM_RETRY_LIMIT=1 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 \
    EXT="$repo/.omp/extensions/fm-primary-omp-watch.ts" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { writeFileSync, existsSync, readFileSync } from "node:fs";
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const handlers = new Map(); let tool = null; let command = null; const sent = [];
const pi = {
  on(e, h) { handlers.set(e, h); },
  registerCommand(n, o) { if (n === "fm-watch-arm-omp") command = o.handler; },
  registerTool(t) { tool = t; },
  // omp sendUserMessage returns synchronously, not a promise.
  sendUserMessage(m, o) { sent.push({ m, o }); return undefined; },
};
const mod = await import(pathToFileURL(process.env.EXT).href);
mod.default(pi);
if (!tool || tool.name !== "fm_watch_arm_omp") throw new Error("fm_watch_arm_omp was not registered");
if (!command) throw new Error("/fm-watch-arm-omp was not registered");
if (tool.parameters?.type !== "object") throw new Error("tool parameters must be an empty object schema");
const result = await tool.execute();
if (!/^watcher: started omp extension arm child 1;/.test(result.content[0].text)) throw new Error(`unexpected arm result: ${result.content[0].text}`);
const marker = readFileSync(`${process.env.FM_HOME}/state/.omp-watch-extension-loaded`, "utf8").split("\n");
if (marker[1] !== String(process.pid)) throw new Error("loaded marker must record the session pid");
const again = await tool.execute();
if (!/^watcher: unchanged - omp extension already owns an arm child/.test(again.content[0].text)) throw new Error(`redundant arm was not an ownership no-op: ${again.content[0].text}`);
await new Promise((r) => setTimeout(r, 2500));
if (sent.length !== 1) throw new Error(`expected one follow-up wake, saw ${sent.length}: ${JSON.stringify(sent)}`);
if (!sent[0].m.startsWith("⁣FIRSTMATE_OP: v1 watcher: FIRSTMATE WATCHER WAKE: signal: omp-e2e done")) throw new Error(`unexpected wake text: ${sent[0].m}`);
if (sent[0].o?.deliverAs !== "followUp") throw new Error("wake must be delivered as a follow-up");
// The wake is consumed when omp starts the next run with that exact prompt.
await handlers.get("before_agent_start")({ type: "before_agent_start", prompt: sent[0].m }, {});
await handlers.get("session_shutdown")({}, {});
if (existsSync(`${process.env.FM_HOME}/state/extensions/omp-primary-watch/session-replacement-actionable.json`)) throw new Error("a consumed wake must not ride the replacement handoff");
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "omp watch extension contract: $out"
  [ -z "$out" ] || fail "omp watch extension test printed output: $out"
  pass ".omp watch extension: fm_watch_arm_omp arms once, repeats as a no-op, and delivers an actionable close as one follow-up"
}

test_detection_anchored_name_and_marker_precedence
test_lock_identity_and_liveness_classification
test_spawn_launch_line_and_worker_wiring
test_spawn_model_validation_scoped_to_listed_providers
test_secondmate_launch_relies_on_discovery
test_secondmate_config_pinned_model_is_validated
test_busy_extension_lifecycle
test_ship_coordinator_launch_meta_and_gate
test_ship_coordinator_nine_oclock_boundary_and_nonomp_ship
test_omp_scout_and_secondmate_carry_no_coordinator_config
test_ship_relaunch_reuses_stored_agent_across_clock_window
test_worker_overlay_pins_task_shape
test_control_composer_and_model_tables
test_ownership_proof_is_omp_keyed
test_turnend_guard_extension_compels_one_continuation
test_watch_extension_arms_and_delivers
