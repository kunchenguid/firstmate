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
  local bin out omp_ancestor=0 pid
  bin=$(make_named_shells "$TMP_ROOT/named")
  while IFS= read -r pid; do
    [ "$(ps -o comm= -p "$pid" 2>/dev/null | tr -d " ")" = omp ] && omp_ancestor=1
  done <<EOF
$(fm_harness_ancestry_pids || true)
EOF
  # shellcheck disable=SC2016 # the quoted body expands inside the named shell
  out=$(env -u CLAUDECODE -u FM_OMP_HARNESS -u PI_CODING_AGENT -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
    "$bin/omp" -c '"$1"; :' _ "$HARNESS")
  [ "$out" = omp ] || fail "a process named omp must detect as omp, got '$out'"
  # A decoy launched under the test's own OMP parent genuinely has an omp
  # ancestor, so test the anchored-name boundary directly and expect ancestry
  # detection to preserve the real outer OMP identity.
  for decoy in ompd comp; do
    ! fm_harness_process_matches "$decoy" '' \
      || fail "'$decoy' merely contains omp and must not match by name"
    if [ "$omp_ancestor" -eq 0 ]; then
      # shellcheck disable=SC2016 # the quoted body expands inside the named shell
      out=$(env -u CLAUDECODE -u FM_OMP_HARNESS -u PI_CODING_AGENT -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
        "$bin/$decoy" -c '"$1"; :' _ "$HARNESS")
      [ "$out" != omp ] || fail "'$decoy' merely contains omp and must not detect as omp"
    fi
  done
  # The marker beats an inherited CLAUDECODE only under a real omp ancestor.
  # shellcheck disable=SC2016 # the quoted body expands inside the named shell
  out=$(env -u PI_CODING_AGENT -u CURSOR_AGENT -u CURSOR_INVOKED_AS CLAUDECODE=1 FM_OMP_HARNESS=omp \
    "$bin/omp" -c '"$1"; :' _ "$HARNESS")
  [ "$out" = omp ] || fail "FM_OMP_HARNESS under an omp ancestor must outrank an inherited CLAUDECODE, got '$out'"
  # A worker with no OMP ancestor must not be relabeled by a leaked marker.
  # When this suite itself runs under OMP, the worker has a genuine ancestor
  # and omp is the correct result under the ancestry contract.
  # shellcheck disable=SC2016 # the quoted body expands inside the named shell
  out=$(env -u PI_CODING_AGENT -u CURSOR_AGENT -u CURSOR_INVOKED_AS CLAUDECODE=1 FM_OMP_HARNESS=omp \
    bash -c '"$1"; :' _ "$HARNESS")
  if [ "$omp_ancestor" -eq 1 ]; then
    [ "$out" = omp ] || fail "a worker under an omp ancestor must detect as omp, got '$out'"
  else
    [ "$out" = claude ] || fail "a leaked FM_OMP_HARNESS without an omp ancestor must not relabel a claude worker, got '$out'"
  fi
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

# --- 4. Control, composer, supervision model -----------------------------------

test_control_composer_and_model_tables() {
  [ "$(fm_control_exit_command omp)" = /quit ] || fail "omp exit command must be /quit"
  [ "$(fm_control_interrupt_key omp)" = Escape ] || fail "omp interrupt key must be Escape"
  [ "$(fm_control_interrupt_repeat omp)" = 1 ] || fail "omp interrupts on a single press"
  [ -z "$(fm_control_interrupt_clear_key omp)" ] || fail "omp leaves its composer empty and needs no clear key"
  [ "$(fm_control_harness_wiring_paths omp /wt /st id1)" = "/st/id1.omp-ext.ts" ] || fail "omp wiring path must be the state-resident extension"
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
  cat > "$repo/bin/fm-sessionstart-run.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${FM_TEST_SESSION_PID:?}" > "${FM_HOME:?}/state/.lock"
printf 'OMP DIGEST source=%s\n' "$2"
SH
  chmod +x "$repo/bin/"*.sh
  out=$(FM_GUARD_LOG="$TMP_ROOT/guard/guard.log" FM_HOME="$home" EXT="$repo/.omp/extensions/fm-primary-turnend-guard.ts" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { readFileSync, existsSync } from "node:fs";
process.env.FM_TEST_SESSION_PID = String(process.pid);
const handlers = new Map();
const pi = { on(e, h) { handlers.set(e, h); }, sendMessage() {} };
const mod = await import(pathToFileURL(process.env.EXT).href);
mod.default(pi);
const markerPath = `${process.env.FM_HOME}/state/.omp-turnend-extension-loaded`;
if (existsSync(`${process.env.FM_HOME}/state/.lock`)) throw new Error("fresh startup must begin without a lock");
if (readFileSync(markerPath, "utf8").split("\n")[1] !== String(process.pid)) throw new Error("pre-lock marker must record its loader");
for (const name of ["session_start", "before_agent_start", "session_compact", "session_shutdown", "tool_call", "session_stop"]) {
  if (!handlers.has(name)) throw new Error(`${name} handler was not registered`);
}
if (handlers.has("agent_settled")) throw new Error("omp guard must not listen for agent_settled");
const ctx = { sessionManager: { getSessionId: () => "s1" } };
handlers.get("session_start")({ type: "session_start" }, ctx);
const first = await handlers.get("before_agent_start")({ type: "before_agent_start", prompt: "hi" }, ctx);
if (!first?.message?.content?.includes("FIRSTMATE_OP: v1 session-start: OMP DIGEST source=startup")) throw new Error(`first start did not deliver a startup digest: ${JSON.stringify(first)}`);
if (first.message.display !== false || first.message.customType !== "firstmate-sessionstart-nudge") throw new Error("digest message lost its persistent shape");
if (readFileSync(markerPath, "utf8").split("\n")[1] !== process.env.FM_TEST_SESSION_PID) throw new Error("startup must publish the newly acquired ancestor lock identity");
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
  # A merged poll retires its own check script before it emits the wake
  # (bin/fm-watch.sh), while the task's own record still exists, so the fixture
  # stands up that record: the close names live work and must be delivered.
  printf 'window=default:w1A:p1\nharness=omp\n' > "$home/state/merged.meta"
  # The first arm child closes with one actionable reason; every successor
  # stays up, so exactly one wake exists to consume.
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'watcher: started pid=%s (beacon 0s) recovery-generation=gen-1\n' "$$"
if [ ! -e "${FM_HOME:?}/state/.e2e-fired" ]; then
  : > "$FM_HOME/state/.e2e-fired"
  sleep 1
  printf 'check: %s/state/merged.check.sh: merged\n' "$FM_HOME"
  exit 0
fi
: > "$FM_HOME/state/.e2e-rearmed"
exec sleep 30
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
if (!sent[0].m.startsWith(`⁣FIRSTMATE_OP: v1 watcher: FIRSTMATE WATCHER WAKE: check: ${process.env.FM_HOME}/state/merged.check.sh: merged`)) throw new Error(`unexpected wake text: ${sent[0].m}`);
if (!existsSync(`${process.env.FM_HOME}/state/.e2e-rearmed`)) throw new Error("ordinary close did not re-arm after its retired check script was reported");
if (!sent[0].m.includes("After handling the drain output, proactively summarize to the captain any decision, blocker, failure, terminal outcome, or review-ready result before running the printed acknowledgement.")) throw new Error(`wake did not require a proactive captain-facing summary before acknowledgement: ${sent[0].m}`);
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

test_watch_extension_bounds_replacement_handoff() {
  local repo home out status
  repo="$TMP_ROOT/handoff/repo"; home="$TMP_ROOT/handoff/home"
  install_omp_extension_fixture "$repo"
  mkdir -p "$home/state"
  # The arm child starts, confirms a handling delivery, and stays up: the only
  # wakes this case produces are the records already in the handoff store.
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
case "$*" in *--handling-delivered*) exit 0 ;; esac
printf 'watcher: started pid=%s (beacon 0s) recovery-generation=gen-1\n' "$$"
exec sleep 30
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_OMP_ARM_READY_TIMEOUT_MS=3000 FM_WATCH_REARM_RETRY_LIMIT=1 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 \
    EXT="$repo/.omp/extensions/fm-primary-omp-watch.ts" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { existsSync, mkdirSync, readFileSync, unlinkSync, writeFileSync } from "node:fs";
const home = process.env.FM_HOME;
const handoffPath = `${home}/state/extensions/omp-primary-watch/session-replacement-actionable.json`;
const readHandoff = () => JSON.parse(readFileSync(handoffPath, "utf8")).pending;
const seqOf = (pending) => pending.map((item) => Number(/handoff-case-([0-9]+)/.exec(item.message)[1]));
mkdirSync(`${home}/state/extensions/omp-primary-watch`, { recursive: true });
writeFileSync(`${home}/state/.lock`, `${process.pid}\n`);
const now = Date.now();
const record = (ageMs, seq) => ({
  version: 1,
  token: `${process.pid}-${now - ageMs}-${seq}`,
  message: `signal: handoff-case-${seq}.turn-ended`,
  predecessorArmPid: "1",
});
// Two records too old to still be the pending close they were written for, and
// more fresh records than the store is allowed to carry.
const seeded = [record(3600000, 1), record(1800000, 2)];
for (let i = 0; i < 40; i += 1) seeded.push(record(0, 100 + i));
writeFileSync(handoffPath, `${JSON.stringify({ version: 2, pending: seeded })}\n`);
let removeBeforeDelivery = "";
const handlers = new Map(); const sent = [];
const pi = {
  on(e, h) { handlers.set(e, h); },
  registerCommand() {},
  registerTool() {},
  sendUserMessage(m, o) {
    sent.push({ m, o });
    if (removeBeforeDelivery) {
      unlinkSync(removeBeforeDelivery);
      removeBeforeDelivery = "";
    }
    return undefined;
  },
};
const mod = await import(pathToFileURL(process.env.EXT).href);
mod.default(pi);
await handlers.get("session_start")({ type: "session_start" }, {});
await new Promise((resolve) => setTimeout(resolve, 750));
const replayed = readHandoff();
if (replayed.length !== 32) throw new Error(`the store must be pruned to its cap at load, saw ${replayed.length} records`);
const seqs = seqOf(replayed);
if (seqs[0] !== 108 || seqs[seqs.length - 1] !== 139) throw new Error(`the store must keep the newest bounded records, saw ${seqs.join(",")}`);
if (seqs.some((seq) => seq < 100)) throw new Error("a record too old to be a pending close survived the load prune");
if (sent.length !== 32) throw new Error(`the replacement must replay the bounded store exactly, saw ${sent.length} wakes`);
for (const wake of sent) {
  const seq = Number(/handoff-case-([0-9]+)/.exec(wake.m)[1]);
  if (seq < 100) throw new Error(`a record that can no longer be pending was replayed: ${wake.m}`);
}
// Consuming one replayed wake removes exactly that record from the store.
await handlers.get("before_agent_start")({ type: "before_agent_start", prompt: sent[0].m }, {});
const afterConsume = readHandoff();
if (afterConsume.length !== 31) throw new Error(`a consumed record must leave the store, saw ${afterConsume.length} records`);
if (seqOf(afterConsume).includes(108)) throw new Error("the consumed record rode the store again");
const sentBeforeRestart = sent.length;
await handlers.get("session_shutdown")({}, {});
await handlers.get("session_start")({ type: "session_start" }, {});
await new Promise((resolve) => setTimeout(resolve, 500));
const restarted = sent.slice(sentBeforeRestart).map((wake) => wake.m);
if (restarted.some((message) => message.includes("handoff-case-108"))) {
  throw new Error(`a consumed close was re-delivered after restart: ${restarted.join(" | ")}`);
}
if (readHandoff().length !== 31) throw new Error("restart must preserve only the bounded pending records");
await handlers.get("session_shutdown")({}, {});
// A store holding nothing but records that can no longer be the pending close
// they were written for must clear itself and replay nothing.
writeFileSync(handoffPath, `${JSON.stringify({ version: 2, pending: [record(7200000, 500), record(3600000, 501)] })}\n`);
const deliveredBefore = sent.length;
await handlers.get("session_start")({ type: "session_start" }, {});
await new Promise((resolve) => setTimeout(resolve, 500));
if (sent.length !== deliveredBefore) throw new Error(`a stale-only store replayed ${sent.length - deliveredBefore} wakes into the replacement session`);
if (existsSync(handoffPath)) throw new Error("a stale-only store must be cleared at session start");
await handlers.get("session_shutdown")({}, {});
// Admission rejects missing runtime metadata and missing check scripts. The
// second live record then loses its state file after admission but before its
// delivery turn, proving delivery revalidates the same eligibility rule.
for (const id of ["live-first", "stale-during-delivery"]) {
  writeFileSync(`${home}/state/${id}.status`, "busy\n");
  writeFileSync(`${home}/state/${id}.meta`, "runtime\n");
}
writeFileSync(`${home}/state/no-runtime.status`, "done\n");
const referenced = [record(0, 600), record(0, 601), record(0, 602), record(0, 603)];
referenced[0].message = `signal: ${home}/state/live-first.status`;
referenced[1].message = `signal: ${home}/state/stale-during-delivery.status`;
referenced[2].message = `signal: ${home}/state/no-runtime.status`;
referenced[3].message = `check: ${home}/state/missing.check.sh: complete`;
writeFileSync(handoffPath, `${JSON.stringify({ version: 2, pending: referenced })}\n`);
removeBeforeDelivery = `${home}/state/stale-during-delivery.status`;
const referencedBefore = sent.length;
await handlers.get("session_start")({ type: "session_start" }, {});
await new Promise((resolve) => setTimeout(resolve, 750));
if (sent.length !== referencedBefore + 1 || !sent.at(-1).m.includes("live-first.status")) {
  throw new Error(`replacement replayed finished referenced work: ${sent.slice(referencedBefore).map((wake) => wake.m).join(" | ")}`);
}
if (!existsSync(handoffPath) || readHandoff().length !== 1) throw new Error("only the delivered live referenced record may remain pending consumption");
await handlers.get("session_shutdown")({}, {});
writeFileSync(`${process.env.FM_ROOT_OVERRIDE}/bin/fm-watch-arm.sh`, `#!/usr/bin/env bash
case "$*" in *--handling-delivered*) exit 0 ;; esac
touch "$FM_HOME/state/arm-waiting"
while [ ! -e "$FM_HOME/state/arm-release" ]; do sleep 0.02; done
printf 'watcher: started pid=%s (beacon 0s) recovery-generation=gen-1\\n' "$$"
exec sleep 30
`);
const waitUntil = async (predicate, label) => {
  const deadline = Date.now() + 2000;
  while (!predicate()) {
    if (Date.now() >= deadline) throw new Error(`timed out waiting for ${label}`);
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
};
const restoringPath = `${home}/state/finishes-during-restoration.status`;
writeFileSync(restoringPath, "busy\n");
writeFileSync(`${home}/state/finishes-during-restoration.meta`, "runtime\n");
const restoring = record(0, 700);
restoring.message = `signal: ${restoringPath}`;
writeFileSync(handoffPath, `${JSON.stringify({ version: 2, pending: [restoring] })}\n`);
const beforeRestoration = sent.length;
await handlers.get("session_start")({ type: "session_start" }, {});
await waitUntil(() => existsSync(`${home}/state/arm-waiting`), "blocked arm readiness");
if (readHandoff().length !== 1 || sent.length !== beforeRestoration) throw new Error("live handoff must remain pending while readiness is blocked");
unlinkSync(restoringPath);
writeFileSync(`${home}/state/arm-release`, "ready\n");
await waitUntil(() => !existsSync(handoffPath) || sent.length > beforeRestoration, "restoration settlement");
if (sent.length !== beforeRestoration) throw new Error("work finished during restoration was replayed at the send boundary");
if (existsSync(handoffPath)) throw new Error("finished work must leave the replacement handoff store");
await handlers.get("session_shutdown")({}, {});
if (existsSync(handoffPath)) throw new Error("shutdown resurrected work dropped at the send boundary");
const coordinator = globalThis.__firstmateOmpWatchReplacements.get(handoffPath);
for (let i = 0; i < 40; i += 1) coordinator.pending.push(record(0, 800 + i));
const beforeInProcess = sent.length;
await handlers.get("session_start")({ type: "session_start" }, {});
await waitUntil(() => sent.length >= beforeInProcess + 32, "bounded in-process replay");
if (sent.length !== beforeInProcess + 32) throw new Error(`in-process replacement replay was not capped: ${sent.length - beforeInProcess}`);
const inProcessSeqs = sent.slice(beforeInProcess).map((wake) => Number(/handoff-case-([0-9]+)/.exec(wake.m)[1]));
if (inProcessSeqs[0] !== 808 || inProcessSeqs.at(-1) !== 839) throw new Error(`in-process replacement kept the wrong bounded records: ${inProcessSeqs.join(",")}`);
await handlers.get("session_shutdown")({}, {});
if (readHandoff().length !== 32) throw new Error("shutdown must persist only the bounded in-process replacement set");
for (const mode of ["restoration", "confirmation"]) {
  unlinkSync(`${home}/state/arm-waiting`);
  unlinkSync(`${home}/state/arm-release`);
  writeFileSync(`${process.env.FM_ROOT_OVERRIDE}/bin/fm-watch-arm.sh`, `#!/usr/bin/env bash
case "$*" in *--handling-delivered*) exit 1 ;; esac
touch "$FM_HOME/state/arm-waiting"
while [ ! -e "$FM_HOME/state/arm-release" ]; do sleep 0.02; done
${mode === "restoration" ? "exit 1" : "printf 'watcher: started pid=%s (beacon 0s) recovery-generation=gen-1\\n' \"$$\""}
exec sleep 30
`);
  const failedPath = `${home}/state/finished-before-${mode}.status`;
  writeFileSync(failedPath, "busy\n");
  writeFileSync(`${home}/state/finished-before-${mode}.meta`, "runtime\n");
  const failedRecord = record(0, mode === "restoration" ? 900 : 901);
  failedRecord.message = `signal: ${failedPath}`;
  writeFileSync(handoffPath, `${JSON.stringify({ version: 2, pending: [failedRecord] })}\n`);
  const beforeFailure = sent.length;
  await handlers.get("session_start")({ type: "session_start" }, {});
  await waitUntil(() => existsSync(`${home}/state/arm-waiting`), `${mode} arm startup`);
  unlinkSync(failedPath);
  writeFileSync(`${home}/state/arm-release`, "ready\n");
  await waitUntil(() => !existsSync(handoffPath), `${mode} stale handoff cleanup`);
  const notices = sent.slice(beforeFailure);
  const expectedFailure = mode === "restoration" ? "could not restore watcher continuity after 1 retries" : "handling delivery confirmation was rejected";
  if (notices.length !== 1 || !notices[0].m.includes(expectedFailure)) throw new Error(`${mode} failure was not surfaced independently: ${JSON.stringify(notices)}`);
  if (notices[0].m.includes(failedPath)) throw new Error(`${mode} failure replayed stale work`);
  await handlers.get("session_shutdown")({}, {});
  if (existsSync(handoffPath)) throw new Error(`${mode} failure resurrected stale work`);
}
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "omp watch replacement handoff bounds: $out"
  [ -z "$out" ] || fail "omp watch replacement handoff test printed output: $out"
  pass ".omp watch extension: the replacement handoff is capped and fresh, an old close is dropped at session start, and a genuinely pending close still replays once"
}

test_omp_startup_binds_loaded_markers() {
  local repo home bin mode out status script
  repo="$TMP_ROOT/startup/repo"
  install_omp_extension_fixture "$repo"
  cp -R "$ROOT/bin/." "$repo/bin/"
  mkdir -p "$repo/fakebin"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$repo/fakebin/tasks-axi"
  chmod +x "$repo/fakebin/tasks-axi"
  for script in fm-bootstrap.sh fm-startup-network.sh fm-home-summary-refresh.sh fm-herdr-session-cleanup.sh fm-wake-drain.sh; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$repo/bin/$script"
  done
  : > "$repo/AGENTS.md"
  git init -q -b main "$repo"
  bin=$(make_named_shells "$TMP_ROOT/startup/bin")
  cat > "$repo/drive.mjs" <<'EOF'
import { pathToFileURL } from "node:url";
import { readFileSync, existsSync, unlinkSync } from "node:fs";
import { spawnSync } from "node:child_process";
const root = process.env.FM_ROOT_OVERRIDE;
const state = `${process.env.FM_HOME}/state`;
if (process.env.MODE !== "startup") process.argv.push(process.env.MODE);
const handlers = new Map();
const api = { on(e, h) { handlers.set(e, h); }, sendMessage() {} };
await import(pathToFileURL(`${root}/.omp/extensions/fm-primary-omp-watch.ts`).href)
  .then(({ default: load }) => load({ on() {}, registerCommand() {}, registerTool() {}, sendUserMessage() {} }));
await import(pathToFileURL(`${root}/.omp/extensions/fm-primary-turnend-guard.ts`).href)
  .then(({ default: load }) => load(api));
const markers = [".omp-watch-extension-loaded", ".omp-turnend-extension-loaded"];
if (existsSync(`${state}/.lock`)) throw new Error("startup fixture already owns a lock");
for (const name of markers) {
  if (readFileSync(`${state}/${name}`, "utf8").split("\n")[1] !== String(process.pid)) throw new Error("pre-lock marker did not record the loader");
}
const ctx = { sessionManager: { getSessionId: () => "startup" } };
handlers.get("session_start")({}, ctx);
const result = await handlers.get("before_agent_start")({ prompt: "hi" }, ctx);
let digest = result?.message?.content ?? "";
if (process.env.MODE !== "startup") {
  if (existsSync(`${state}/.lock`)) throw new Error("resume must defer lock acquisition to the agent");
  if (!digest.includes("Run `bin/fm-session-start.sh` now")) throw new Error(`resume nudge missing: ${digest}`);
  const run = spawnSync(`${root}/bin/fm-session-start.sh`, { encoding: "utf8" });
  if (run.status !== 0) throw new Error(`agent startup failed: ${run.stderr}`);
  digest = run.stdout;
}
if (!digest.includes("primary harness: omp")) throw new Error(`OMP startup was not exercised: ${digest}`);
if (digest.includes("OMP_WATCH_EXTENSION: not loaded")) throw new Error("startup incorrectly reported loaded extensions missing");
const lockPid = readFileSync(`${state}/.lock`, "utf8").trim();
if (lockPid !== String(process.ppid)) throw new Error(`startup did not lock the outer harness: ${lockPid}`);
for (const name of markers) {
  if (readFileSync(`${state}/${name}`, "utf8").split("\n")[1] !== lockPid) throw new Error("startup did not bind the loader to its owning ancestor");
}
const proof = spawnSync("bash", ["-c", '. "$1/bin/fm-wake-lib.sh"; fm_omp_extension_owns_supervision "$2" "$1"', "_", root, state]);
if (proof.status !== 0) throw new Error("startup did not establish extension-pair ownership");
unlinkSync(`${state}/.omp-turnend-extension-loaded`);
const missing = spawnSync(`${root}/bin/fm-session-start.sh`, ["--reemit"], { encoding: "utf8" });
if (!missing.stdout.includes("OMP_WATCH_EXTENSION: not loaded") || existsSync(`${state}/.omp-turnend-extension-loaded`)) throw new Error("startup fabricated evidence for an unloaded guard");
await handlers.get("session_shutdown")({}, {});
EOF
  for mode in startup --resume --continue -r -c; do
    home="$TMP_ROOT/startup/$mode"
    mkdir -p "$home/state" "$home/data" "$home/config"
    printf 'manual\n' > "$home/config/backlog-backend"
    # shellcheck disable=SC2016 # Variables expand in the child shell.
    out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS \
      FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_OMP_HARNESS=omp MODE="$mode" \
      FM_SESSION_START_STAGE_FILE="$home/state/stage" \
      PATH="$repo/fakebin:$PATH" "$bin/omp" -c 'node "$1/drive.mjs"; result=$?; exit "$result"' _ "$repo" 2>&1)
    status=$?
    expect_code 0 "$status" "OMP $mode startup marker binding: $out"
    [ -z "$out" ] || fail "OMP $mode startup printed output: $out"
  done
  pass "OMP native and agent-driven resume/continue startup bind loaded markers before diagnostics"
}

test_omp_markers_record_outer_omp_ancestor() {
  local repo home bin driver omp_pid out status
  repo="$TMP_ROOT/nested/repo"; home="$TMP_ROOT/nested/home"
  install_omp_extension_fixture "$repo"
  mkdir -p "$home/state"
  driver="$TMP_ROOT/nested/drive.mjs"
  cat > "$driver" <<'EOF'
import { pathToFileURL } from "node:url";
const noop = { on() {}, registerCommand() {}, registerTool() {}, sendUserMessage() {} };
await import(pathToFileURL(process.env.WATCH_EXT).href).then(({ default: load }) => load(noop));
await import(pathToFileURL(process.env.GUARD_EXT).href).then(({ default: load }) => load(noop));
EOF
  bin=$(make_named_shells "$TMP_ROOT/nested/bin")
  # shellcheck disable=SC2016 # Variables expand in the child shell.
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" WATCH_EXT="$repo/.omp/extensions/fm-primary-omp-watch.ts" GUARD_EXT="$repo/.omp/extensions/fm-primary-turnend-guard.ts" \
    "$bin/omp" -c 'printf "%s\n" "$$" > "$1/state/.lock"; node "$2"' _ "$home" "$driver" 2>&1)
  status=$?
  expect_code 0 "$status" "nested omp marker writer: $out"
  [ -z "$out" ] || fail "nested omp marker writer printed output: $out"
  omp_pid=$(cat "$home/state/.lock")
  [ -n "$omp_pid" ] || fail "nested omp wrapper did not record its pid"
  for marker in .omp-watch-extension-loaded .omp-turnend-extension-loaded; do
    [ "$(sed -n '2p' "$home/state/$marker")" = "$omp_pid" ] \
      || fail "$marker must record outer omp pid $omp_pid, got $(sed -n '2p' "$home/state/$marker")"
  done
  pass "omp extension markers record the outer lock-owning omp ancestor from a nested worker"
}

# A close must be replayed or delivered only while the work it names can still
# exist. Two distinct holes let dead work re-announce itself: the guard returned
# true unconditionally for any kind it could not resolve (stale/heartbeat), and
# it was gated on the replacement set, so an ordinary in-memory re-delivery of a
# finished close skipped it entirely. Both cases below assert the drop, and both
# also assert that genuinely live work still gets through, so the fix cannot
# pass by suppressing everything.
test_watch_extension_gates_close_liveness() {
  local repo home out status
  repo="$TMP_ROOT/liveness/repo"; home="$TMP_ROOT/liveness/home"
  install_omp_extension_fixture "$repo"
  mkdir -p "$home/state"
  # The arm child starts, confirms a handling delivery, and stays up: this case
  # produces no wakes of its own, so every delivery observed is a replay.
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
case "$*" in *--handling-delivered*) exit 0 ;; esac
printf 'watcher: started pid=%s (beacon 0s) recovery-generation=gen-1\n' "$$"
exec sleep 30
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_OMP_ARM_READY_TIMEOUT_MS=3000 FM_WATCH_REARM_RETRY_LIMIT=1 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 \
    EXT="$repo/.omp/extensions/fm-primary-omp-watch.ts" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
const home = process.env.FM_HOME;
const state = `${home}/state`;
const handoffPath = `${state}/extensions/omp-primary-watch/session-replacement-actionable.json`;
mkdirSync(`${state}/extensions/omp-primary-watch`, { recursive: true });
writeFileSync(`${state}/.lock`, `${process.pid}\n`);
const record = (seq, message) => ({
  version: 1,
  token: `${process.pid}-${Date.now()}-${seq}`,
  message,
  predecessorArmPid: "1",
});
const readHandoff = () => JSON.parse(readFileSync(handoffPath, "utf8")).pending;
const handlers = new Map(); const sent = [];
const pi = {
  on(e, h) { handlers.set(e, h); },
  registerCommand() {},
  registerTool() {},
  sendUserMessage(m, o) { sent.push({ m, o }); return undefined; },
};
// Live work the guard must still admit: a task with a meta, a task-scoped check
// whose script a merged poll already retired (bin/fm-watch.sh retires before it
// wakes), and the fleet-scoped bare heartbeat.
writeFileSync(`${state}/live-signal-q1.turn-ended`, "turn ended\n");
writeFileSync(`${state}/live-signal-q1.meta`, "window=default:w5A:p1\nharness=omp\n");
writeFileSync(`${state}/live-stale-q1.meta`, "window=default:w6B:p1\nharness=omp\n");
writeFileSync(`${state}/live-check-q1.meta`, "window=default:w7C:p1\nharness=omp\n");
// A status file whose task record was already removed, and a status path with
// both halves present, to show signal resolution still checks both. This is the
// pair that proves the channel-log exemption stays narrow: `orphan-q1.status` is
// an ordinary torn-down task log and must still be dropped, while the
// home-scoped parent-channel log beside it must stay live (see record 11).
writeFileSync(`${state}/orphan-q1.status`, "done\n");
// Two live tasks whose ids are repo-valid but start with a non-alphanumeric
// character: the creation alphabet in bin/fm-pr-lib.sh accepts a leading '_' and
// '-', so a close naming either one names live work and must still be delivered.
writeFileSync(`${state}/_underscore-q1.turn-ended`, "turn ended\n");
writeFileSync(`${state}/_underscore-q1.meta`, "window=default:wAA:p1\nharness=omp\n");
writeFileSync(`${state}/-dash-q1.status`, "done\n");
writeFileSync(`${state}/-dash-q1.meta`, "window=default:wAB:p1\nharness=omp\n");
// A remote secondmate home parent-channel log: state-resident, appended by the
// parent-channel publishers, and carrying no task meta by construction
// (bin/fm-parent-channel-lib.sh owns its destination).
writeFileSync(`${state}/parent-replies.status`, "done [key=merged-q1]: child finished\n");
const seeded = [
  record(1, "stale: default:w4Z:p2"),
  record(2, "stale: default:w4Z:p2 (idle 900s, possible wedge, escalation 2)"),
  record(3, "heartbeat"),
  record(4, "heartbeat: default:w9Z:p1"),
  record(5, `signal: ${state}/dead-signal-q1.turn-ended`),
  record(6, `signal: ${state}/live-signal-q1.turn-ended`),
  record(7, `signal: ${state}/orphan-q1.status`),
  record(8, `check: ${state}/dead-check-q1.check.sh: merged`),
  record(9, `check: ${state}/live-check-q1.check.sh: merged`),
  record(10, "stale: default:w6B:p1"),
  record(11, `signal: ${state}/parent-replies.status`),
  record(12, `signal: ${state}/_underscore-q1.turn-ended`),
  record(13, `signal: ${state}/-dash-q1.status`),
  record(14, "stale: default:wAB:p1"),
];
writeFileSync(handoffPath, `${JSON.stringify({ version: 2, pending: seeded })}\n`);
const mod = await import(pathToFileURL(process.env.EXT).href);
mod.default(pi);
await handlers.get("session_start")({ type: "session_start" }, {});
await new Promise((resolve) => setTimeout(resolve, 750));
const replayed = sent.map((wake) => wake.m);
const sawAny = (needle) => replayed.some((text) => text.includes(needle));
// Hole 1: an unresolvable stale close for a task with no meta is dead work.
if (sawAny("stale: default:w4Z:p2")) {
  throw new Error(`a stale close for a task with no meta was replayed: ${JSON.stringify(replayed)}`);
}
// The suffixed heartbeat names a window too, so it resolves the same way.
if (sawAny("heartbeat: default:w9Z:p1")) throw new Error("a windowed heartbeat for a missing task was replayed");
// Both dead state references, in each shape the guard resolves.
if (sawAny("dead-signal-q1")) throw new Error("a signal close whose referenced files are gone was replayed");
if (sawAny("orphan-q1.status")) throw new Error("a signal close whose task record was removed was replayed");
if (sawAny("dead-check-q1")) throw new Error("a check close for a task with no meta and no script was replayed");
// Live work still gets through, each exactly once.
for (const [needle, label] of [
  ["stale: default:w6B:p1", "a stale close for a window whose task still exists"],
  [`signal: ${state}/live-signal-q1.turn-ended`, "a live signal close"],
  [`check: ${state}/live-check-q1.check.sh: merged`, "a check close whose task record still exists"],
  ["heartbeat", "the fleet-scoped heartbeat"],
  // F2: the home-scoped parent-channel log has no task meta by construction, so
  // the guard must exempt it by name while still dropping the torn-down task log
  // above. Before the fix this close was dropped, losing the routed parent reply;
  // after it, this one case flips to replayed while `orphan-q1.status` above
  // stays dropped.
  [`signal: ${state}/parent-replies.status`, "a signal close naming the home-scoped parent-channel log"],
  // F1: the guard alphabet must mirror the creation alphabet in bin/fm-pr-lib.sh.
  // A leading '_' or '-' is a repo-valid task id, so both closes name live work
  // and must deliver; requiring an alphanumeric first character dropped them.
  [`signal: ${state}/_underscore-q1.turn-ended`, "a signal close for a task id starting with underscore"],
  [`signal: ${state}/-dash-q1.status`, "a signal close for a task id starting with dash"],
  ["stale: default:wAB:p1", "a stale close for a window whose task id starts with dash"],
]) {
  const count = replayed.filter((text) => text.includes(needle)).length;
  if (count !== 1) throw new Error(`${label} must replay exactly once, saw ${count}: ${JSON.stringify(replayed)}`);
}
if (readHandoff().length !== 8) throw new Error(`dead closes must leave the store, saw ${readHandoff().length} records`);
// Consuming a live replayed close removes exactly that record: a genuinely
// pending close still replays once across a replacement and is not duplicated.
const liveText = sent.find((wake) => wake.m.includes("live-signal-q1.turn-ended")).m;
await handlers.get("before_agent_start")({ type: "before_agent_start", prompt: liveText }, {});
if (readHandoff().length !== 7) throw new Error(`a consumed close must leave the store, saw ${readHandoff().length} records`);
if (readHandoff().some((item) => item.message.includes("live-signal-q1"))) throw new Error("the consumed close rode the store again");
await handlers.get("session_shutdown")({}, {});
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "omp watch close liveness: $out"
  [ -z "$out" ] || fail "omp watch close liveness test printed output: $out"
  pass ".omp watch extension: a close for finished work is dropped for every kind, while live work still replays exactly once"
}

# Hole 2: the guard was reached only for replacement closes, so an ordinary
# in-memory pending close - one this very session created from its own arm
# child - was delivered with no liveness check at all. Drive that exact path:
# an arm child reports work that is already gone, and a live one alongside it.
test_watch_extension_gates_non_replacement_delivery() {
  local repo home out status
  repo="$TMP_ROOT/live-path/repo"; home="$TMP_ROOT/live-path/home"
  install_omp_extension_fixture "$repo"
  mkdir -p "$home/state"
  # The first arm child reports dead work on one run and live work on the next;
  # every successor stays up, so the only deliveries are those two closes.
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
case "$*" in *--handling-delivered*) exit 0 ;; esac
printf 'watcher: started pid=%s (beacon 0s) recovery-generation=gen-1\n' "$$"
if [ ! -e "${FM_HOME:?}/state/.e2e-dead-fired" ]; then
  : > "$FM_HOME/state/.e2e-dead-fired"
  sleep 1
  printf 'signal: %s/state/dead-arm-q1.turn-ended\n' "$FM_HOME"
  exit 0
fi
if [ ! -e "${FM_HOME:?}/state/.e2e-live-fired" ]; then
  : > "$FM_HOME/state/.e2e-live-fired"
  sleep 1
  printf 'signal: %s/state/live-arm-q1.turn-ended\n' "$FM_HOME"
  exit 0
fi
exec sleep 30
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_OMP_ARM_READY_TIMEOUT_MS=3000 FM_WATCH_REARM_RETRY_LIMIT=1 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 \
    EXT="$repo/.omp/extensions/fm-primary-omp-watch.ts" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { mkdirSync, writeFileSync } from "node:fs";
const state = `${process.env.FM_HOME}/state`;
mkdirSync(state, { recursive: true });
writeFileSync(`${state}/.lock`, `${process.pid}\n`);
// Only one of the two referenced tasks exists: the other is finished work whose
// files are already gone, exactly as a dead pane leaves nothing behind.
writeFileSync(`${state}/live-arm-q1.turn-ended`, "turn ended\n");
writeFileSync(`${state}/live-arm-q1.meta`, "window=default:w8D:p1\nharness=omp\n");
const handlers = new Map(); const sent = [];
const pi = {
  on(e, h) { handlers.set(e, h); },
  registerCommand() {},
  registerTool() {},
  sendUserMessage(m, o) { sent.push({ m, o }); return undefined; },
};
const mod = await import(pathToFileURL(process.env.EXT).href);
mod.default(pi);
await handlers.get("session_start")({ type: "session_start" }, {});
const waitUntil = async (predicate, label) => {
  const deadline = Date.now() + 4000;
  while (!predicate()) {
    if (Date.now() >= deadline) throw new Error(`timed out waiting for ${label}`);
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
};
await waitUntil(() => sent.length >= 1, "the live non-replacement close");
if (sent.some((wake) => wake.m.includes("dead-arm-q1"))) {
  throw new Error(`a finished close on the non-replacement path was delivered: ${JSON.stringify(sent.map((wake) => wake.m))}`);
}
if (!sent.some((wake) => wake.m.includes("live-arm-q1.turn-ended"))) {
  throw new Error(`a live close on the non-replacement path was not delivered: ${JSON.stringify(sent.map((wake) => wake.m))}`);
}
if (sent.filter((wake) => wake.m.includes("live-arm-q1")).length !== 1) {
  throw new Error("the live non-replacement close was delivered more than once");
}
await handlers.get("session_shutdown")({}, {});
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "omp watch non-replacement liveness: $out"
  [ -z "$out" ] || fail "omp watch non-replacement liveness test printed output: $out"
  pass ".omp watch extension: an ordinary non-replacement close is liveness-checked too, and live work still delivers"
}

# The retained list is bounded by age, not only by live work. An undelivered
# close that has outlived its replacement window must be retired rather than
# re-delivered when a later close runs the same pipeline: the live replays named
# panes that had since been reused by other tasks, so their work still existed
# and a liveness-only predicate passed them - the age bound is what rejects
# them. The fresh close alongside it proves the bound does not suppress real
# work.
test_watch_extension_retires_aged_retained_close() {
  local repo home out status
  repo="$TMP_ROOT/aged/repo"; home="$TMP_ROOT/aged/home"
  install_omp_extension_fixture "$repo"
  mkdir -p "$home/state"
  # The first arm child reports one close and exits; a successor reports the next
  # one and then stays up, so the only deliveries are those closes.
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
case "$*" in *--handling-delivered*) exit 0 ;; esac
printf 'watcher: started pid=%s (beacon 0s) recovery-generation=gen-1\n' "$$"
if [ ! -e "${FM_HOME:?}/state/.aged-fired" ]; then
  : > "$FM_HOME/state/.aged-fired"
  printf 'signal: %s/state/aged-q1.turn-ended\n' "$FM_HOME"
  exit 0
fi
if [ ! -e "${FM_HOME:?}/state/.fresh-fired" ]; then
  : > "$FM_HOME/state/.fresh-fired"
  sleep 1
  printf 'signal: %s/state/fresh-q1.turn-ended\n' "$FM_HOME"
  exit 0
fi
exec sleep 30
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_OMP_ARM_READY_TIMEOUT_MS=3000 FM_WATCH_REARM_RETRY_LIMIT=1 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_OMP_HANDOFF_TTL_MS=200 \
    EXT="$repo/.omp/extensions/fm-primary-omp-watch.ts" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { mkdirSync, writeFileSync } from "node:fs";
const state = `${process.env.FM_HOME}/state`;
mkdirSync(state, { recursive: true });
writeFileSync(`${state}/.lock`, `${process.pid}\n`);
// Both closes name live work: the first is held back only because omp rejects
// its follow-up, which is what leaves it retained in memory to age out.
for (const id of ["aged-q1", "fresh-q1"]) {
  writeFileSync(`${state}/${id}.turn-ended`, "turn ended\n");
  writeFileSync(`${state}/${id}.meta`, "window=default:w1B:p1\nharness=omp\n");
}
const handlers = new Map(); const sent = [];
let rejectAged = true;
const pi = {
  on(e, h) { handlers.set(e, h); },
  registerCommand() {},
  registerTool() {},
  sendUserMessage(m, o) {
    // Only the retained aged close follow-up is rejected, so it stays in memory
    // undelivered. Every other send, including a composed failure notice, takes
    // its ordinary path and cannot absorb this rejection.
    if (rejectAged && m.includes("aged-q1.turn-ended")) {
      rejectAged = false;
      throw new Error("omp rejected the follow-up");
    }
    sent.push({ m, o });
    return undefined;
  },
};
const mod = await import(pathToFileURL(process.env.EXT).href);
mod.default(pi);
await handlers.get("session_start")({ type: "session_start" }, {});
const waitUntil = async (predicate, label) => {
  const deadline = Date.now() + 6000;
  while (!predicate()) {
    if (Date.now() >= deadline) throw new Error(`timed out waiting for ${label}`);
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
};
await waitUntil(() => sent.some((wake) => wake.m.includes("fresh-q1")), "the fresh close");
if (sent.some((wake) => wake.m.includes("aged-q1"))) {
  throw new Error(`a close that outlived its replacement window was re-delivered: ${JSON.stringify(sent.map((wake) => wake.m))}`);
}
if (sent.filter((wake) => wake.m.includes("fresh-q1")).length !== 1) {
  throw new Error(`the live close must deliver exactly once: ${JSON.stringify(sent.map((wake) => wake.m))}`);
}
await handlers.get("session_shutdown")({}, {});
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "omp watch aged retained close: $out"
  [ -z "$out" ] || fail "omp watch aged retained close test printed output: $out"
  pass ".omp watch extension: a close that outlived its replacement window is retired instead of re-delivered, while live work still delivers"
}

# A failure notice reports one continuity episode, so it is surfaced exactly
# once. surfaceFailure sends without a pending close and therefore never reached
# the consumption or liveness discipline that retires actionable wakes: with the
# retry counter left exhausted, every later close of the same generation
# re-composed the identical text, which is what put four byte-identical notices
# on the captain hours after the watcher was healthy again. Phase A pins that
# exactly-once behavior on a closed episode; phase B proves the fix does not go
# further than the defect and silence a genuinely new episode.
test_watch_extension_reports_failure_once_per_episode() {
  local repo home out status
  repo="$TMP_ROOT/failure/repo"; home="$TMP_ROOT/failure/home"
  install_omp_extension_fixture "$repo"
  mkdir -p "$home/state"
  # The arm child reads its mode from a file the test rewrites: "fail" prints the
  # same failure line every time, so each exhaustion composes byte-identical text,
  # and "restored" verifies a live watcher and stays up, which is the readiness
  # proof that ends an episode.
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
case "$*" in *--handling-delivered*) exit 0 ;; esac
mode=$(cat "${FM_HOME:?}/state/arm-mode" 2>/dev/null || printf fail)
if [ "$mode" = restored ]; then
  printf 'watcher: started pid=%s (beacon 0s) recovery-generation=gen-2\n' "$$"
  printf '%s\n' "$$" > "$FM_HOME/state/arm-child.pid"
  exec sleep 30
fi
printf 'watcher: FAILED - arm cycle could not confirm a fresh watcher beacon\n'
exit 1
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  printf 'fail\n' > "$home/state/arm-mode"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_OMP_ARM_READY_TIMEOUT_MS=3000 FM_WATCH_REARM_RETRY_LIMIT=1 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 \
    EXT="$repo/.omp/extensions/fm-primary-omp-watch.ts" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
const state = `${process.env.FM_HOME}/state`;
mkdirSync(state, { recursive: true });
writeFileSync(`${state}/.lock`, `${process.pid}\n`);
const handlers = new Map(); const sent = [];
let tool = null;
const pi = {
  on(e, h) { handlers.set(e, h); },
  registerCommand() {},
  registerTool(t) { tool = t; },
  sendUserMessage(m, o) { sent.push({ m, o }); return undefined; },
};
const mod = await import(pathToFileURL(process.env.EXT).href);
mod.default(pi);
const waitUntil = async (predicate, label) => {
  const deadline = Date.now() + 8000;
  while (!predicate()) {
    if (Date.now() >= deadline) throw new Error(`timed out waiting for ${label}`);
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
};
const exhaustNotices = () => sent.filter((wake) => wake.m.includes("could not restore watcher continuity"));
await handlers.get("session_start")({ type: "session_start" }, {});
// Phase A: the retry ladder exhausts against a watcher that never comes up, so
// the episode reports once.
await tool.execute();
await waitUntil(() => exhaustNotices().length >= 1, "the first exhaustion notice");
if (exhaustNotices().length !== 1) throw new Error(`the episode must report exactly once: ${JSON.stringify(sent.map((wake) => wake.m))}`);
const episodeNotice = exhaustNotices()[0].m;
// The counter stays exhausted, so each later failing close belongs to the same,
// already-answered episode and composes that exact text again. Drive two more
// repair cycles and demand the notice is not re-surfaced.
for (let cycle = 0; cycle < 2; cycle += 1) {
  await tool.execute();
  await new Promise((resolve) => setTimeout(resolve, 600));
}
if (sent.filter((wake) => wake.m === episodeNotice).length !== 1) {
  throw new Error(`a byte-identical failure notice was re-surfaced: ${JSON.stringify(sent.map((wake) => wake.m))}`);
}
if (exhaustNotices().length !== 1) {
  throw new Error(`one episode emitted ${exhaustNotices().length} notices: ${JSON.stringify(exhaustNotices().map((wake) => wake.m))}`);
}
// Phase B: a successor verifiably restores continuity, which clears the closed
// episode memory. Ending that verified watcher with the failure mode restored
// is then a genuinely new episode, and it must report again - the fix must not
// go past the defect and silence real failures. The composed text legitimately
// differs (this close is a killed successor rather than a failed start), so this
// asserts the second report exists rather than matching the first byte for byte.
writeFileSync(`${state}/arm-mode`, "restored\n");
await tool.execute();
await waitUntil(() => {
  try { return Number(readFileSync(`${state}/arm-child.pid`, "utf8").trim()) > 0; } catch { return false; }
}, "the restored successor");
if (exhaustNotices().length !== 1) throw new Error("a verified restoration must not itself report an exhaustion failure");
writeFileSync(`${state}/arm-mode`, "fail\n");
process.kill(Number(readFileSync(`${state}/arm-child.pid`, "utf8").trim()), "SIGTERM");
await waitUntil(() => exhaustNotices().length >= 2, "the fresh episode notice");
if (exhaustNotices().length !== 2) {
  throw new Error(`a new episode must report exactly one more notice, saw ${exhaustNotices().length}: ${JSON.stringify(exhaustNotices().map((wake) => wake.m))}`);
}
await handlers.get("session_shutdown")({}, {});
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "omp watch failure notice: $out"
  [ -z "$out" ] || fail "omp watch failure notice test printed output: $out"
  pass ".omp watch extension: a failure notice reports once per episode, and a verified restoration still reports a new one"
}

test_detection_anchored_name_and_marker_precedence
test_omp_startup_binds_loaded_markers
test_omp_markers_record_outer_omp_ancestor
test_lock_identity_and_liveness_classification
test_spawn_launch_line_and_worker_wiring
test_spawn_model_validation_scoped_to_listed_providers
test_secondmate_launch_relies_on_discovery
test_secondmate_config_pinned_model_is_validated
test_busy_extension_lifecycle
test_control_composer_and_model_tables
test_ownership_proof_is_omp_keyed
test_turnend_guard_extension_compels_one_continuation
test_watch_extension_arms_and_delivers
test_watch_extension_bounds_replacement_handoff
test_watch_extension_gates_close_liveness
test_watch_extension_gates_non_replacement_delivery
test_watch_extension_retires_aged_retained_close
test_watch_extension_reports_failure_once_per_episode
