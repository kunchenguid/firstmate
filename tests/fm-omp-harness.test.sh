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
  [ "$(fm_backend_tmux_classify_process_name omp)" = agent ] || fail "tmux liveness must classify omp as an agent"
  [ "$(fm_backend_tmux_classify_process_name /opt/omp/bin/omp)" = agent ] || fail "tmux liveness must classify an omp path as an agent"
  [ "$(fm_backend_tmux_classify_process_name ompd)" != agent ] || fail "tmux liveness must not classify ompd as an agent"
  [ "$(fm_backend_tmux_classify_process_name comp)" != agent ] || fail "tmux liveness must not classify comp as an agent"
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
test_control_composer_and_model_tables
test_ownership_proof_is_omp_keyed
test_turnend_guard_extension_compels_one_continuation
test_watch_extension_arms_and_delivers
