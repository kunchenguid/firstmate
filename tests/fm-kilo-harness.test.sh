#!/usr/bin/env bash
# tests/fm-kilo-harness.test.sh - the portable regression for the kilo
# (Kilo Code) adapter: detection, session-lock identity, tmux liveness
# classification, control mechanics, the rendered-tail busy fallback, and the
# spawn launch line for crewmates and secondmates.
#
# kilo's identity, launch, and lifecycle checks are HARNESS-DEPENDENT: their
# verdicts come from what the vendor emits (a process name, a rendered footer).
# This suite pins the LOGIC with real processes and a fake tmux, so CI enforces
# it with no kilo installed; FM_KILO_SIGNALS_LIVE=1
# tests/fm-kilo-signals-live-e2e.test.sh is the live guard that catches vendor
# drift against a real kilo. Neither replaces the other.
#
# The load-bearing contracts:
#   1. kilo publishes no marker of its own and exports OPENCODE=1 from its
#      OpenCode lineage; neither is a marker. The anchored process name `kilo`
#      is the ancestry evidence, and kilocode or a bare `kilo` mention never
#      identify.
#   2. FM_KILO_HARNESS=kilo is a precedence override that needs a real kilo
#      ancestor: it beats an inherited CLAUDECODE under kilo and is inert when
#      it leaks into a process whose ancestry holds no kilo.
#   3. Interrupt is a double Escape, no clear key, no ack source, and /exit;
#      kilo is a full adapter (secondmate allowed), unlike the crewmate-only
#      muse/gemini/rovo/agy/devin.
#   4. The busy fallback matches the pinned `esc interrupt` footer alone; the
#      free-floating word `interrupt` and the mid-interrupt `esc again to
#      interrupt` must never read busy, and the signature is harness-scoped.
#   5. Every kilo launch carries FM_KILO_HARNESS=kilo, clears foreign markers,
#      runs `kilo --auto --prompt`, passes --model, never passes --worktree or
#      an effort flag (the base TUI has none), and arms no busy wiring.
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
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-kilo-harness)

# bin/fm-harness.sh checks verified ENV markers before ancestry. A suite run
# from inside another harness inherits those markers, which outrank the fake
# ancestry the detection cases set up. Drop the ambient markers so the asserted
# verdict does not depend on which harness launched the suite.
unset CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS \
  ATLASSIAN_AGENT_TYPE ROVODEV_CLI GEMINI_CLI AGENT FM_OMP_HARNESS FM_KILO_HARNESS OPENCODE

test_kilo_ancestry_detects_the_native_command_name() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/anc-native")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' '/opt/homebrew/Cellar/kilo/7.8.8/libexec/kilo'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" = kilo ] \
    || fail "a natively-named kilo command must be detected by ancestry, got '$out'"
  pass "fm-harness.sh: ancestry detects a natively-named kilo command"
}

test_kilo_ancestry_rejects_unrelated_mentions() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/anc-negatives")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' "${FAKE_PS_COMM:?}"; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"

  out=$(FAKE_PS_COMM=kilocode PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" != kilo ] \
    || fail "an unrelated kilocode command must not detect kilo, got '$out'"
  out=$(FAKE_PS_COMM=bash PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" != kilo ] \
    || fail "a bare shell must not detect kilo, got '$out'"
  pass "fm-harness.sh: ancestry rejects unrelated kilo mentions"
}

test_kilo_claims_no_fork_lineage_or_inherited_marker() {
  local fakebin out
  # Blind the real ancestry (a suite can run under a real kilo) so the asserted
  # verdict comes from the marker under test, never from the test runner's own
  # process tree.
  fakebin=$(fm_fakebin "$TMP_ROOT/anc-leak")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' node; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  # OPENCODE=1 is the fork lineage, not an identity marker: on its own, over
  # ancestry that holds no kilo, it must never claim kilo.
  out=$(OPENCODE=1 PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" != kilo ] \
    || fail "an inherited OPENCODE=1 must never claim the kilo identity, got '$out'"
  # FM_KILO_HARNESS=kilo leaking into a worker whose ancestry holds no kilo is
  # inert: the fake ps proves no kilo ancestor.
  out=$(FM_KILO_HARNESS=kilo PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" != kilo ] \
    || fail "FM_KILO_HARNESS without a kilo ancestor must be inert, got '$out'"
  # Drive the hazard the other way: kilo does not clear an inherited CLAUDECODE,
  # so a structural kilo ancestor must outrank the retained marker.
  fakebin=$(fm_fakebin "$TMP_ROOT/anc-claude")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' kilo; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(CLAUDECODE=1 PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" = kilo ] \
    || fail "a structural kilo ancestor must outrank an inherited CLAUDECODE, got '$out'"
  pass "fm-harness.sh: no fork-lineage or inherited marker claims the kilo identity"
}

test_kilo_control_mechanics_are_the_verified_ones() {
  fm_control_harness_supported kilo || fail "kilo must be a supported control harness"
  [ "$(fm_control_harness_family kilo)" = kilo ] || fail "kilo must map to its own family"
  fm_control_harness_supports_kind kilo scout || fail "kilo must run scouts"
  fm_control_harness_supports_kind kilo ship || fail "kilo must run ships"
  fm_control_harness_supports_kind kilo secondmate || fail "kilo must be allowed as a secondmate"
  [ "$(fm_control_interrupt_key kilo)" = Escape ] || fail "kilo must interrupt on Escape"
  [ "$(fm_control_interrupt_repeat kilo)" = 2 ] || fail "kilo must interrupt on a double Escape"
  [ -z "$(fm_control_interrupt_clear_key kilo)" ] || fail "kilo must need no clear key"
  [ "$(fm_control_interrupt_ack_source kilo)" = none ] || fail "kilo must have no ack source"
  [ "$(fm_control_exit_command kilo)" = /exit ] || fail "kilo must exit on /exit"
  pass "fm-control-lib: kilo mechanics are Escape twice, no clear key, and /exit"
}

test_kilo_busy_tail_needs_the_pinned_footer() {
  printf 'turn running\nKilo Gateway  max   esc interrupt   ctrl+t variants\n' | fm_busy_kilo_tail_busy \
    || fail "the esc-interrupt footer must read busy"
  printf 'idle\nAsk anything...\n' | fm_busy_kilo_tail_busy \
    && fail "an idle composer must not read busy" || true
  printf 'the worker said interrupt now\n' | fm_busy_kilo_tail_busy \
    && fail "the free-floating word interrupt alone must not read busy" || true
  printf 'Kilo Gateway  max   esc again to interrupt   ctrl+t variants\n' | fm_busy_kilo_tail_busy \
    && fail "the mid-interrupt esc-again footer must not read busy" || true
  printf 'idle\nAsk anything...\n' | fm_busy_lines_match kilo \
    && fail "the delivery guard must not acknowledge on an idle footer" || true
  pass "fm-busy-lib: only the pinned esc-interrupt footer carries the kilo busy verdict"
}

test_kilo_busy_signatures_are_harness_scoped() {
  printf 'esc interrupt\n' | fm_busy_lines_match kilo \
    || fail "harness=kilo must match its own esc token"
  printf 'esc interrupt\n' | fm_busy_lines_match grok \
    && fail "harness=grok must never borrow kilo's esc token" || true
  printf 'Ctrl+c:cancel\n' | fm_busy_lines_match kilo \
    && fail "harness=kilo must never borrow grok's token" || true
  printf 'esc interrupt\n' | fm_busy_lines_match spaceship \
    && fail "an unverified harness must match nothing" || true
  pass "fm-composer-lib: kilo delivery signatures never cross harnesses"
}

test_kilo_classify_reports_unknown_when_the_marker_scrolls_out() {
  local statedir busy idle
  statedir="$TMP_ROOT/classify"; mkdir -p "$statedir"
  busy=$(fm_busy_classify tmux fake:win kilo kilo-case-1 "$statedir" 'turn running
Kilo Gateway  max   esc interrupt   ctrl+t variants')
  [ "$busy" = "busy kilo-regex" ] || fail "a busy tail must classify busy kilo-regex, got '$busy'"
  idle=$(fm_busy_classify tmux fake:win kilo kilo-case-2 "$statedir" 'reply landed
Ask anything...')
  [ "$idle" = "unknown kilo-regex" ] || fail "a scrolled-out marker must classify unknown, got '$idle'"
  pass "fm-busy-lib: kilo classifies busy on its marker and unknown without it"
}

test_kilo_tmux_names_the_native_binary_an_agent() {
  local got
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-backend.sh"
  fm_backend_source tmux || fail "fm_backend_source tmux failed"
  got=$(fm_agent_process_classify_name kilo)
  [ "$got" = agent ] || fail "tmux liveness must read the kilo binary as an agent, got '$got'"
  got=$(fm_agent_process_classify_name kilocode)
  [ "$got" = other ] || fail "tmux liveness must not read kilocode as an agent, got '$got'"
  got=$(fm_agent_process_classify_name bash)
  [ "$got" = shell ] || fail "tmux liveness must still read bash as a shell, got '$got'"
  pass "bin/fm-agent-process-lib.sh: kilo is an agent, fragments are not"
}

# --- spawn ------------------------------------------------------------------

make_spawn_case() {  # <name> <id> -> record
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" kilo
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

test_kilo_launch_shape_records_model_and_omits_effort_and_worktree() {
  local rec id out status launch meta
  id="kilo-launch-k1-$$"
  rec=$(make_spawn_case launch "$id")
  read_case_record "$rec"
  out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --harness kilo --model anthropic/claude-sonnet-4-8 --effort high)
  status=$?
  expect_code 0 "$status" "kilo scout spawn should succeed: $out"
  assert_contains "$out" "spawned $id harness=kilo" "spawn did not report the kilo harness"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "FM_KILO_HARNESS=kilo kilo --auto --prompt" \
    "kilo launch did not establish its marker and use --auto --prompt"
  assert_contains "$launch" "env -u CLAUDECODE" "kilo launch did not clear the inherited launcher marker"
  assert_contains "$launch" "-u FM_OMP_HARNESS -u ATLASSIAN_AGENT_TYPE -u ROVODEV_CLI" \
    "kilo launch did not clear every foreign marker"
  assert_contains "$launch" "--model 'anthropic/claude-sonnet-4-8'" "kilo launch did not carry the requested model"
  assert_not_contains "$launch" "--worktree" "kilo launch must never pass --worktree"
  assert_not_contains "$launch" "--effort" "kilo launch must never pass an effort flag"
  assert_not_contains "$launch" "__BRIEF__" "kilo launch left its brief placeholder unsubstituted"
  assert_not_contains "$launch" "__MODELFLAG__" "kilo launch left its model placeholder unsubstituted"
  meta="$HOME_DIR/state/$id.meta"
  assert_grep 'harness=kilo' "$meta" "kilo meta did not record its harness"
  assert_grep 'model=anthropic/claude-sonnet-4-8' "$meta" "kilo meta did not record its model"
  assert_grep 'effort=high' "$meta" "kilo meta did not retain the recorded effort axis"
  pass "fm-spawn: kilo launch carries the brief and model, clears markers, and omits effort and worktree"
}

test_kilo_spawn_arms_no_busy_wiring() {
  local rec id out status state
  id="kilo-nowiring-k2-$$"
  rec=$(make_spawn_case nowiring "$id")
  read_case_record "$rec"
  out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness kilo)
  status=$?
  expect_code 0 "$status" "kilo spawn should succeed: $out"
  state="$HOME_DIR/state"
  [ -e "$state/$id.busy-gen" ] && fail "kilo spawn armed a busy generation nothing could clear" || true
  pass "fm-spawn: kilo arms no busy wiring (rendered-tail fallback only)"
}

test_kilo_secondmate_launch_uses_the_persistent_model() {
  local world home fakebin launchlog out status launch
  world="$TMP_ROOT/secondmate"
  home="$world/sm"
  mkdir -p "$world/home/state" "$world/home/data" "$world/home/config" "$home/bin" "$home/data"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf 'sm\n' > "$home/.fm-secondmate-home"
  printf 'charter\n' > "$home/data/charter.md"
  printf '%s\n' 'projects/' 'state/' 'data/' 'config/' '.no-mistakes/' > "$home/.gitignore"
  git -C "$home" init -q -b main
  fakebin=$(make_spawn_fakebin "$world/fake")
  launchlog="$world/launch.log"
  : > "$launchlog"
  out=$(PATH="$fakebin:$PATH" TMUX='fake,1,0' FM_BACKEND=tmux \
    FM_ROOT_OVERRIDE='' FM_HOME="$world/home" \
    FM_STATE_OVERRIDE="$world/home/state" FM_DATA_OVERRIDE="$world/home/data" \
    FM_PROJECTS_OVERRIDE="$world/home/projects" FM_CONFIG_OVERRIDE="$world/home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_LAUNCH_LOG="$launchlog" \
    "$SPAWN" sm "$home" kilo --secondmate 2>&1)
  status=$?
  expect_code 0 "$status" "kilo secondmate spawn should succeed: $out"
  assert_grep "harness=kilo" "$world/home/state/sm.meta" "secondmate meta missing harness=kilo"
  launch=$(cat "$launchlog")
  assert_contains "$launch" "FM_SUPERVISION_MODEL=persistent" \
    "a kilo secondmate must run the persistent supervision model"
  assert_contains "$launch" "FM_KILO_HARNESS=kilo kilo --auto --prompt" \
    "kilo secondmate launch lost its marker or launch shape"
  pass "fm-spawn: a real kilo secondmate launch runs the persistent supervision model"
}

# A secondmate home runs a primary firstmate session and must get plugin-owned
# supervision exactly like the main primary. Its home is a linked git worktree
# (git-dir != git-common-dir), so the plain-checkout test alone would exempt it;
# only the valid .fm-secondmate-home marker force-includes it, mirroring
# bin/fm-primary-scope-lib.sh's fm_primary_root_matches that the turn-end guard
# already uses.
test_kilo_watch_arm_arms_in_a_secondmate_home() {
  local plugin base home log out status
  plugin="$ROOT/.kilo/plugin/fm-primary-watch-arm.js"
  base="$TMP_ROOT/kilo-secondmate-base"
  home="$TMP_ROOT/kilo-secondmate-home"
  log="$TMP_ROOT/kilo-secondmate-arm.log"
  fm_git_worktree "$base" "$home" fm/kilo-secondmate-home
  mkdir -p "$home/bin" "$home/state" "$home/config"
  : > "$home/AGENTS.md"
  printf 'sm-kilo-1\n' > "$home/.fm-secondmate-home"
  cp "$ROOT/bin/fm-supervision-lib.sh" "$home/bin/fm-supervision-lib.sh"
  cp "$ROOT/bin/fm-primary-scope-lib.sh" "$home/bin/fm-primary-scope-lib.sh"
  : > "$home/state/task.meta"
  cat > "$home/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm\n' >> "${FM_ARM_LOG:?}"
printf 'watcher: healthy pid=1 (beacon 0s)\n'
SH
  chmod +x "$home/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" WORKTREE="$home" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" FM_ARM_LOG="$log" node 2>&1 <<'EOF'
import { existsSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const client = { session: { promptAsync: async () => {} } };
await mod.default.server({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
writeFileSync(`${process.env.FM_STATE_OVERRIDE}/.lock`, `${process.pid}\n`);
const status = await globalThis.__firstmateKiloWatchArm.ensureArmed("session-test", client);
if (status === "not-primary") {
  console.error("kilo watch arm refused a genuine secondmate home as not-primary");
  process.exit(1);
}
for (let i = 0; i < 250 && !existsSync(process.env.FM_ARM_LOG); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 20));
}
if (!existsSync(process.env.FM_ARM_LOG)) {
  console.error(`kilo watch arm did not run in a secondmate home (status ${status})`);
  process.exit(1);
}
EOF
)
  status=$?
  expect_code 0 "$status" "kilo watch-arm must arm in a genuine secondmate home ($out)"
  [ -z "$out" ] || fail "kilo secondmate-arm test printed output: $out"
  pass "kilo watch-arm arms in a home carrying a valid .fm-secondmate-home"
}

# The .kilo guard port makes the same write-to-child-stdin as its OpenCode
# sibling. A child free to exit without reading makes that write fail with
# EPIPE, and an unhandled stdin 'error' event takes the whole host process
# down. The blind-turn text here is larger than a pipe buffer, so the write to
# an encoder that refuses the input cannot complete: the guard must report the
# refusal by staying silent, not by killing the session.
test_kilo_turnend_guard_survives_an_encoder_that_never_reads_stdin() {
  local guard_plugin repo guard_log out status
  guard_plugin="$ROOT/.kilo/plugin/fm-primary-turnend-guard.js"
  repo="$TMP_ROOT/kilo-guard-encoder-root"
  guard_log="$TMP_ROOT/kilo-guard-encoder-guard.log"
  mkdir -p "$repo/bin"
  cat > "$repo/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
printf 'guard\n' >> "${FM_GUARD_LOG:?}"
printf 'watcher: FAILED - %s\n' "$(head -c 200000 /dev/zero | tr '\0' 'x')" >&2
exit 2
SH
  cat > "$repo/bin/fm-operational-input.sh" <<'SH'
#!/usr/bin/env bash
printf 'operational-input: refused\n' >&2
exit 1
SH
  chmod +x "$repo/bin/fm-turnend-guard.sh" "$repo/bin/fm-operational-input.sh"
  out=$(GUARD_PLUGIN="$guard_plugin" WORKTREE="$repo" FM_GUARD_LOG="$guard_log" node 2>&1 <<'EOF'
import { existsSync } from "node:fs";
import { pathToFileURL } from "node:url";

const guardMod = await import(pathToFileURL(process.env.GUARD_PLUGIN).href);
let prompts = 0;
const client = { session: { promptAsync: async () => { prompts += 1; } } };
const guardHooks = await guardMod.default.server({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
await guardHooks.event({ event: { type: "session.idle", properties: { sessionID: "session-test" } } });
if (!existsSync(process.env.FM_GUARD_LOG)) {
  console.error("turn-end guard did not run");
  process.exit(1);
}
if (prompts !== 0) {
  console.error(`guard prompted ${prompts} times despite an encoder that refused the input`);
  process.exit(1);
}
EOF
)
  status=$?
  expect_code 0 "$status" "kilo turn-end guard must survive an encoder that never reads its stdin ($out)"
  [ -z "$out" ] || fail "kilo guard encoder test printed output: $out"
  pass "kilo turn-end guard survives an encoder that never reads stdin"
}

test_kilo_ancestry_detects_the_native_command_name
test_kilo_ancestry_rejects_unrelated_mentions
test_kilo_claims_no_fork_lineage_or_inherited_marker
test_kilo_control_mechanics_are_the_verified_ones
test_kilo_busy_tail_needs_the_pinned_footer
test_kilo_busy_signatures_are_harness_scoped
test_kilo_classify_reports_unknown_when_the_marker_scrolls_out
test_kilo_tmux_names_the_native_binary_an_agent
test_kilo_launch_shape_records_model_and_omits_effort_and_worktree
test_kilo_spawn_arms_no_busy_wiring
test_kilo_secondmate_launch_uses_the_persistent_model
test_kilo_watch_arm_arms_in_a_secondmate_home
test_kilo_turnend_guard_survives_an_encoder_that_never_reads_stdin
