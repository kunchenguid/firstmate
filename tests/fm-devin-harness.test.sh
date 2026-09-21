#!/usr/bin/env bash
# Behavior tests for the verified Devin CLI crewmate/scout adapter.
#
# The facts pinned here are the ones a devin release could silently change and
# the ones a wrong guess would make dangerous:
#   1. devin publishes no harness-identity marker of its own (DEVIN_* values
#      are inherited launch configuration, CHISEL_SESSION_DB is a sessions-db
#      path, AI_AGENT=devin_* is ambient multiplexer state), so detection is
#      ancestry alone on the anchored process name
#      `devin`, which a structural ancestor proves over a retained CLAUDECODE.
#   2. The anchored match must never claim unrelated commands containing the
#      fragment, and `devin` stays out of the session-lock name vocabulary
#      with the other crewmate-only adapters.
#   3. The launch carries the brief as a positional prompt behind `--` with
#      --config (the firstmate-owned per-task config), --permission-mode
#      bypass, and --model; a requested model a reachable `devin models list
#      --format json` omits refuses loudly instead of wedging a pane, while a
#      hung or unreachable listing is cut off and never blocks; effort stays
#      in task metadata under the record-and-omit contract.
#   4. A fresh worktree would park devin on its workspace-trust dialog, so the
#      spawn pre-registers the worktree in devin's own trusted_paths store
#      through bin/fm-devin-trust.sh (scope-refused for anything but a linked
#      worktree of the project) and the post-launch gate is the backstop: it
#      answers a dialog that renders anyway exactly once, never counts the
#      fm-spawn seed as ready (only `busy devin-hook` proves the hooks live),
#      and fails the spawn with endpoint cleanup when the brief cannot be
#      confirmed to run in the worktree.
#   5. devin is a crewmate/scout adapter only: a secondmate launch is refused,
#      and a raw devin-shaped launch receives no busy wiring or turn-end hook.
#   6. The busy lifecycle is SessionStart/UserPromptSubmit open, Stop/SessionEnd
#      close; Stop fires on normal completion only, never on a manual
#      double-Escape interrupt, so the record survives an interrupt like
#      Claude's until the next hook event settles it.
#   7. The composer contract is the bare `❭` (U+276D) glyph row with the dim
#      idle/busy placeholders; the interrupt is double Escape and the exit is
#      /exit with a SessionEnd reason of prompt_input_exit.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

# bin/fm-harness.sh checks verified ENV markers before ancestry. A suite run
# from inside another harness inherits those markers, which outrank the fake
# ancestry the detection cases set up. Drop the ambient markers so the asserted
# verdict does not depend on which harness launched the suite.
unset CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS \
  ATLASSIAN_AGENT_TYPE ROVODEV_CLI GEMINI_CLI AGENT FM_OMP_HARNESS AI_AGENT \
  DEVIN_MODEL DEVIN_PERMISSION_MODE DEVIN_SANDBOX CHISEL_SESSION_DB

# shellcheck source=/dev/null
. "$ROOT/bin/fm-control-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-composer-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-agent-process-lib.sh"

HARNESS="$ROOT/bin/fm-harness.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TRUST="$ROOT/bin/fm-devin-trust.sh"
TMP_ROOT=$(fm_test_tmproot fm-devin-harness)

test_devin_ancestry_detects_the_native_command_name() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/anc-native")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' '/home/u/.local/share/devin/cli/_versions/3000.10.31/bin/devin'; exit 0 ;;
  *"args="*) printf '%s\n' '/home/u/.local/share/devin/cli/_versions/3000.10.31/bin/devin --config x.json -- "hi"'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" = devin ] \
    || fail "a natively-named devin command must be detected by ancestry, got '$out'"
  pass "fm-harness.sh: ancestry detects a natively-named devin command"
}

test_devin_ancestry_rejects_unrelated_mentions() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/anc-negatives")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' "${FAKE_PS_COMM:?}"; exit 0 ;;
  *"args="*) printf '%s\n' "${FAKE_PS_ARGS:?}"; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"

  out=$(FAKE_PS_COMM=devin-helper FAKE_PS_ARGS='devin-helper --serve' \
    PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" != devin ] \
    || fail "a devin-helper command must not detect devin, got '$out'"

  out=$(FAKE_PS_COMM=xdevin FAKE_PS_ARGS='xdevin --serve' \
    PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" != devin ] \
    || fail "an xdevin command must not detect devin, got '$out'"

  out=$(FAKE_PS_COMM=bash FAKE_PS_ARGS='bash -c "devin --help"' \
    PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" != devin ] \
    || fail "a later shell argument naming devin must not detect devin, got '$out'"
  pass "fm-harness.sh: ancestry rejects unrelated devin mentions"
}

test_devin_claims_no_inherited_launcher_marker() {
  local fakebin out
  # DEVIN_* values are launch configuration, not identity: a pane that merely
  # inherits them from its launcher must never read as devin.
  out=$(DEVIN_PERMISSION_MODE=bypass DEVIN_MODEL=opus DEVIN_SANDBOX=1 "$HARNESS")
  [ "$out" != devin ] \
    || fail "inherited DEVIN_* configuration must never claim the devin identity, got '$out'"
  out=$(CHISEL_SESSION_DB=/tmp/sessions.db "$HARNESS")
  [ "$out" != devin ] \
    || fail "a sessions-db path must never claim the devin identity, got '$out'"
  # AI_AGENT=devin_<version>_agent is set on live devin TUIs (observed,
  # 3000.11.1) AND inherited fleet-wide from a multiplexer started under one,
  # so it is ambient launcher state, never identity: an opencode worker under
  # this fleet carries it without being devin.
  out=$(AI_AGENT=devin_3000-11-1_agent "$HARNESS")
  [ "$out" != devin ] \
    || fail "an inherited AI_AGENT value must never claim the devin identity, got '$out'"
  out=$(AGENT=1 "$HARNESS")
  [ "$out" != devin ] \
    || fail "an inherited AGENT=1 must never claim the devin identity, got '$out'"
  # Drive the hazard the other way: devin does not clear an inherited
  # CLAUDECODE, so a structural devin ancestor must still outrank the retained
  # marker rather than being renamed away from it. Pin both halves so neither
  # can rot silently.
  fakebin=$(fm_fakebin "$TMP_ROOT/anc-claude")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' devin; exit 0 ;;
  *"args="*) printf '%s\n' 'devin --config x.json -- "hi"'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(CLAUDECODE=1 PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" = devin ] \
    || fail "a structural devin ancestor must outrank an inherited CLAUDECODE, got '$out'"
  pass "fm-harness.sh: no inherited launcher marker claims the devin identity"
}

test_devin_control_mechanics_are_the_verified_ones() {
  fm_control_harness_supported devin || fail "devin must be a supported control harness"
  [ "$(fm_control_harness_family devin)" = devin ] || fail "devin must map to its own family"
  fm_control_harness_supports_kind devin scout || fail "devin must run scouts"
  fm_control_harness_supports_kind devin ship || fail "devin must run ships"
  fm_control_harness_supports_kind devin secondmate \
    && fail "devin must refuse secondmates" || true
  [ "$(fm_control_interrupt_key devin)" = Escape ] || fail "devin must interrupt on Escape"
  [ "$(fm_control_interrupt_repeat devin)" = 2 ] || fail "devin must interrupt on a double press"
  [ -z "$(fm_control_interrupt_clear_key devin)" ] || fail "devin must need no clear key"
  [ "$(fm_control_interrupt_ack_source devin)" = none ] || fail "devin must have no ack source"
  [ "$(fm_control_exit_command devin)" = /exit ] || fail "devin must exit on /exit"
  [ "$(fm_control_harness_wiring_paths devin /wt /state t1)" = /state/t1.devin-config.json ] \
    || fail "devin wiring must retire exactly the per-task config file"
  pass "fm-control-lib: devin mechanics are double Escape, no clear key, and /exit"
}

test_devin_busy_source_is_trusted_and_scoped() {
  [ "$(fm_busy_sources_for_harness devin)" = "devin-hook fm-spawn fm-interrupt fm-recovery" ] \
    || fail "devin must trust exactly its hook plus the firstmate-owned sources, got '$(fm_busy_sources_for_harness devin)'"
  fm_busy_source_trusted devin devin-hook || fail "devin-hook must be trusted for harness=devin"
  fm_busy_source_trusted grok devin-hook \
    && fail "devin-hook must never classify a grok task" || true
  fm_busy_source_trusted devin claude-hook \
    && fail "claude-hook must never classify a devin task" || true
  [ "$(fm_busy_sources_for_harness claude)" = "claude-hook fm-spawn fm-interrupt fm-recovery" ] \
    || fail "the devin addition must not move claude's sources, got '$(fm_busy_sources_for_harness claude)'"
  pass "fm-busy-lib: devin trusts devin-hook, scoped to its own harness"
}

test_devin_tmux_names_the_native_binary_an_agent() {
  local got
  got=$(fm_agent_process_classify_name devin)
  [ "$got" = agent ] || fail "tmux liveness must read the devin binary as an agent, got '$got'"
  got=$(fm_agent_process_classify_name devin-helper)
  [ "$got" = other ] || fail "tmux liveness must not read devin-helper as an agent, got '$got'"
  got=$(fm_agent_process_classify_name xdevin)
  [ "$got" = other ] || fail "tmux liveness must not read xdevin as an agent, got '$got'"
  got=$(fm_agent_process_classify_name bash)
  [ "$got" = shell ] || fail "tmux liveness must still read bash as a shell, got '$got'"
  pass "bin/fm-agent-process-lib.sh: devin is an agent, fragments are not"
}

test_devin_composer_contract_is_the_bare_glyph_row() {
  local out
  case "$FM_COMPOSER_AGENT_PROMPT_GLYPHS" in
    *"❭"*) : ;;
    *) fail "the ❭ glyph must be a declared agent prompt glyph" ;;
  esac
  out=$(fm_composer_classify_content 0 '❭' '' sensitive '❭' 0 1)
  [ "$out" = empty ] || fail "a bare ❭ row must read empty, got '$out'"
  out=$(fm_composer_classify_content 0 '❭ hello typed probe' '' sensitive '❭ hello typed probe' 0 1)
  [ "$out" = pending ] || fail "typed text on the ❭ row must read pending, got '$out'"
  fm_composer_idle_matches 'Ask Devin to build features, fix bugs, or work on your code' \
    "$FM_COMPOSER_IDLE_RE_DEFAULT" insensitive \
    || fail "the idle placeholder must match the fleet idle set"
  fm_composer_idle_matches 'Guide Devin while it works' \
    "$FM_COMPOSER_IDLE_RE_DEFAULT" insensitive \
    || fail "the busy placeholder must match the fleet idle set"
  pass "fm-composer-lib: the ❭ glyph row and both devin placeholders classify"
}

make_devin_trust_case() {  # <name> -> "<case>|<home>|<proj>|<wt>"
  local name=$1 case_dir proj wt home
  case_dir="$TMP_ROOT/trust-$name"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  home="$case_dir/home"
  mkdir -p "$home"
  fm_git_worktree "$proj" "$wt" "wt-trust-$name"
  printf '%s\n' "$case_dir|$home|$proj|$wt"
}

read_devin_trust_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR <<EOF
$1
EOF
}

run_devin_trust() {  # <home> <worktree> <project>
  XDG_DATA_HOME= XDG_CONFIG_HOME= HOME="$1" "$TRUST" "$2" "$3" 2>&1
}

devin_trusted_paths() {  # <store>
  node -e 'const fs=require("node:fs");const j=fs.existsSync(process.argv[1])?JSON.parse(fs.readFileSync(process.argv[1],"utf8")):{};for(const p of (j.trusted_paths||[]))console.log(p);' "$1"
}

assert_devin_trusted() {  # <store> <path> <msg>
  devin_trusted_paths "$1" | grep -Fqx "$2" || fail "$3"
}

assert_devin_not_trusted() {  # <store> <path> <msg>
  devin_trusted_paths "$1" | grep -Fqx "$2" && fail "$3"
  return 0
}

test_devin_trust_registers_the_logical_and_resolved_worktree_paths() {
  local rec store out link
  rec=$(make_devin_trust_case fresh)
  read_devin_trust_case "$rec"
  store="$HOME_DIR/.local/share/devin/cli/trusted_workspaces.json"
  mkdir -p "$(dirname "$store")"
  printf '%s\n' '{"theme_mode":"dark","trusted_paths":["/home/someone/elsewhere"]}' > "$store"
  link="$CASE_DIR/wt-link"
  ln -s "$WT_DIR" "$link"
  out=$(run_devin_trust "$HOME_DIR" "$link" "$PROJ_DIR") || fail "a fresh linked worktree must be trusted: $out"
  assert_devin_trusted "$store" "$link" "the logical (symlinked) pane path was not registered"
  assert_devin_trusted "$store" "$WT_DIR" "the resolved worktree path was not registered alongside the logical one"
  assert_devin_trusted "$store" "/home/someone/elsewhere" "registration dropped an existing trusted_paths entry"
  [ "$(node -e 'console.log(JSON.stringify(JSON.parse(require("node:fs").readFileSync(process.argv[1],"utf8")).theme_mode));' "$store")" = '"dark"' ] \
    || fail "registration did not preserve an unrelated store key"
  out=$(run_devin_trust "$HOME_DIR" "$link" "$PROJ_DIR") || fail "repeat registration must succeed: $out"
  [ "$(devin_trusted_paths "$store" | grep -Fcx "$WT_DIR")" -eq 1 ] \
    || fail "repeat registration duplicated the worktree entry"
  pass "fm-devin-trust.sh: registers the logical and resolved worktree paths and preserves the store"
}

test_devin_trust_creates_a_missing_store() {
  local rec store out
  rec=$(make_devin_trust_case nostore)
  read_devin_trust_case "$rec"
  store="$HOME_DIR/.local/share/devin/cli/trusted_workspaces.json"
  out=$(run_devin_trust "$HOME_DIR" "$WT_DIR" "$PROJ_DIR") || fail "a missing store must be created: $out"
  [ -f "$store" ] || fail "no trust store was created at $store"
  assert_devin_trusted "$store" "$WT_DIR" "the worktree was not registered in the created store"
  pass "fm-devin-trust.sh: creates devin's trust store when none exists"
}

test_devin_trust_honours_xdg_data_home() {
  local rec store out xdg
  rec=$(make_devin_trust_case xdg)
  read_devin_trust_case "$rec"
  xdg="$CASE_DIR/xdg-data"
  mkdir -p "$xdg"
  store="$xdg/devin/cli/trusted_workspaces.json"
  out=$(HOME="$HOME_DIR" XDG_DATA_HOME="$xdg" XDG_CONFIG_HOME= "$TRUST" "$WT_DIR" "$PROJ_DIR" 2>&1) \
    || fail "registration under XDG_DATA_HOME must succeed: $out"
  [ -f "$store" ] || fail "no trust store was created under XDG_DATA_HOME at $store"
  assert_devin_trusted "$store" "$WT_DIR" "the worktree was not registered in the XDG store"
  [ ! -e "$HOME_DIR/.local/share/devin/cli/trusted_workspaces.json" ] \
    || fail "registration created a store outside XDG_DATA_HOME"
  pass "fm-devin-trust.sh: resolves the store under XDG_DATA_HOME like devin does"
}

test_devin_trust_refuses_out_of_scope_paths() {
  local rec store out rc plain before after
  rec=$(make_devin_trust_case scope)
  read_devin_trust_case "$rec"
  store="$HOME_DIR/.local/share/devin/cli/trusted_workspaces.json"
  mkdir -p "$(dirname "$store")"
  printf '%s\n' '{"trusted_paths":[]}' > "$store"
  rc=0; out=$(run_devin_trust "$HOME_DIR" "$PROJ_DIR" "$PROJ_DIR") || rc=$?
  [ "$rc" -ne 0 ] || fail "the primary checkout must be refused"
  assert_contains "$out" "primary checkout" "primary-checkout refusal lacked its reason"
  assert_devin_not_trusted "$store" "$PROJ_DIR" "a refused primary checkout was still registered"
  rc=0; out=$(run_devin_trust "$HOME_DIR" "$HOME_DIR" "$PROJ_DIR") || rc=$?
  [ "$rc" -ne 0 ] || fail "the home directory must be refused"
  assert_devin_not_trusted "$store" "$HOME_DIR" "a refused home directory was still registered"
  plain="$CASE_DIR/plain"; mkdir -p "$plain"
  rc=0; out=$(run_devin_trust "$HOME_DIR" "$plain" "$PROJ_DIR") || rc=$?
  [ "$rc" -ne 0 ] || fail "a plain directory must be refused"
  assert_devin_not_trusted "$store" "$plain" "a refused plain directory was still registered"
  rc=0; out=$(run_devin_trust "$HOME_DIR" "$WT_DIR/.git" "$PROJ_DIR") || rc=$?
  [ "$rc" -ne 0 ] || fail "a path below the worktree root must be refused"
  printf '%s\n' '{not json' > "$store"
  before=$(cat "$store")
  rc=0; out=$(run_devin_trust "$HOME_DIR" "$WT_DIR" "$PROJ_DIR") || rc=$?
  [ "$rc" -ne 0 ] || fail "an unparseable store must be refused"
  after=$(cat "$store")
  [ "$before" = "$after" ] || fail "an unparseable store was rewritten"
  pass "fm-devin-trust.sh: refuses every out-of-scope path and never rewrites a broken store"
}

# --- spawn-world ------------------------------------------------------------
# The fake tmux renders a devin-shaped screen that advances through
# launched -> (trust dialog ->) hook-busy as the real spawn drives it, so the
# launch command, the pre-registration, the single Enter that answers a
# dialog, and the readiness gate are exercised through their real code paths.
# Whether the dialog renders is decided the way devin decides it: the pane
# path is looked up in the trusted_paths array of the store the spawn just
# wrote. FM_FAKE_DEVIN_IGNORE_TRUST=1 models a vendor that stopped honouring
# the store; FM_FAKE_DEVIN_NO_DIALOG=1 models a pane that never shows the
# dialog even though firstmate could not register the path (a busy verdict
# with no proof of where the turn runs); FM_FAKE_DEVIN_STUCK=1 models a
# session whose hooks never fire.
# The hook-busy state is produced the way a real session produces it: when
# the launch literal arrives, the fake extracts the --config file, runs its
# SessionStart hook command through sh, and so records `busy devin-hook`
# through the real writer - the exact verdict the readiness gate requires.
# The same happens for the Enter that answers a rendered dialog, modelling
# the session start that follows the answer.
DEVIN_MODELS_JSON='{"families":[{"family_label":"Claude Opus","slug":"claude-opus","aliases":["opus"],"variants":[{"model_uid":"claude-opus-medium"}]},{"family_label":"SWE","slug":"swe-1","aliases":["swe"],"variants":[{"model_uid":"swe-1-fast"}]}]}'

make_devin_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_FAKE_TMUX_CALL_LOG"
state=$(cat "$FM_FAKE_DEVIN_STATE" 2>/dev/null || true)
fire_session_start() {
  [ "${FM_FAKE_DEVIN_STUCK:-0}" = 1 ] && return 0
  literal=$1
  case "$literal" in
    *--config*)
      cfg=${literal#*--config }
      cfg=${cfg%% *}
      case "$cfg" in
        \'*\') cfg=${cfg#\'}; cfg=${cfg%\'} ;;
      esac
      [ -f "$cfg" ] || return 0
      cmd=$(node -e 'console.log(JSON.parse(require("node:fs").readFileSync(process.argv[1],"utf8")).hooks.SessionStart[0].hooks[0].command);' "$cfg" 2>/dev/null) || return 0
      sh -c "$cmd" >/dev/null 2>&1 || true
      ;;
  esac
}
fake_screen() {
  case "$state" in
    dialog)
      printf 'devin\n\n/tmp/fake-worktree\n\n ✱ Do you trust the authors of this directory?\n   For security, devin should not be run in directories with untrusted content.\n\n ❭ 1 Yes, trust\n · 2 No, exit\n\n ↓↑ to select · ↵ to choose · esc to quit\n'
      ;;
    *)
      printf 'shell starting\n$ \n'
      ;;
  esac
}
fake_path_trusted() {
  [ "${FM_FAKE_DEVIN_IGNORE_TRUST:-0}" = 1 ] && return 1
  node -e 'const fs=require("node:fs");let j={};try{j=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));}catch(e){process.exit(1);}process.exit(Array.isArray(j.trusted_paths)&&j.trusted_paths.includes(process.argv[2])?0:1);' \
    "$FM_FAKE_DEVIN_TRUST_STORE" "$FM_FAKE_PANE_PATH"
}
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "$FM_FAKE_PANE_PATH"; exit 0 ;;
  *"#{cursor_y}"*) printf '1\n'; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window|set-window-option) exit 0 ;;
  send-keys)
    literal=
    prev=
    for arg in "$@"; do
      if [ "$prev" = -l ]; then literal=$arg; break; fi
      prev=$arg
    done
    if [ -n "$literal" ]; then
      case "$literal" in
        ". '"*"'") staged=${literal#". '"}; staged=${staged%"'"}; [ ! -f "$staged" ] || literal=$(cat "$staged") ;;
      esac
      case "$literal" in
        *--config*devin-config*)
          printf '%s\n' "$literal" >> "$FM_FAKE_LAUNCH_LOG"
          printf 'launched\n' > "$FM_FAKE_DEVIN_STATE"
          fire_session_start "$literal"
          ;;
        *)
          [ -n "${FM_FAKE_LAUNCH_LOG:-}" ] && printf '%s\n' "$literal" >> "$FM_FAKE_LAUNCH_LOG"
          ;;
      esac
      exit 0
    fi
    case " $* " in
      *' Enter '*)
        case "$state" in
          launched)
            if [ "${FM_FAKE_DEVIN_NO_DIALOG:-0}" = 1 ]; then
              :
            elif fake_path_trusted; then
              fire_session_start "$(cat "$FM_FAKE_LAUNCH_LOG" 2>/dev/null | head -n 1)"
            else
              printf 'dialog\n' > "$FM_FAKE_DEVIN_STATE"
            fi
            ;;
          dialog)
            printf 'launched-answered\n' > "$FM_FAKE_DEVIN_STATE"
            fire_session_start "$(cat "$FM_FAKE_LAUNCH_LOG" 2>/dev/null | head -n 1)"
            ;;
        esac
        ;;
    esac
    exit 0
    ;;
  capture-pane) fake_screen; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/devin" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = models ]; then
  if [ "${FM_FAKE_DEVIN_MODELS_FAIL:-0}" = 1 ]; then exit 3; fi
  if [ "${FM_FAKE_DEVIN_MODELS_HANG:-0}" = 1 ]; then sleep 30; exit 0; fi
  # NOTE: the default below must stay in the quoted '-word' form: the bare
  # ${VAR:-{}} parses as ${VAR:-{} plus a literal closing brace and would
  # append a stray `}` to every listing, failing the model's JSON parse.
  models_json=${FM_FAKE_DEVIN_MODELS_JSON-'{}'}
  printf '%s\n' "$models_json"
  exit 0
fi
echo "fake devin must never execute" >&2
exit 9
SH
  chmod +x "$fakebin/devin"
  printf '%s\n' "$fakebin"
}

make_devin_spawn_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_devin_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  cat > "$home/data/$id/brief.md" <<'EOF'
# Task
## Captain's intent
Exercise Devin dispatch.

## Firstmate spec
Verify launch and delivery behavior.
EOF
  printf 'devin\n' > "$home/config/crew-harness"
  touch "$home/state/.last-watcher-beat"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  : > "$case_dir/launch.log"
  : > "$case_dir/tmux-calls.log"
  : > "$case_dir/devin.state"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

read_devin_spawn_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

# The spawn drives the real bin/fm-devin-trust.sh, the real per-task config
# merge, and the fake tmux's trust lookup under this base PATH, and the fake
# fires the real SessionStart hook command, so node and jq reach every layer.
# Runners do not keep them in the system bin dirs, so carry the directories
# the invoking environment resolves them from.
NODE_BIN=$(command -v node) || fail "test needs node"
NODE_BIN_DIR=$(dirname "$NODE_BIN")
BASE_PATH=${FM_TEST_BASE_PATH:-$NODE_BIN_DIR:/usr/bin:/bin:/usr/sbin:/sbin}

run_devin_spawn() {
  local case_dir=$1 home=$2 proj=$3 wt=$4 fakebin=$5 id=$6
  shift 6
  XDG_DATA_HOME= XDG_CONFIG_HOME= HOME="$home" FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" \
    FM_FAKE_TMUX_CALL_LOG="$case_dir/tmux-calls.log" \
    FM_FAKE_DEVIN_STATE="$case_dir/devin.state" \
    FM_FAKE_DEVIN_TRUST_STORE="$home/.local/share/devin/cli/trusted_workspaces.json" \
    FM_FAKE_DEVIN_MODELS_JSON="$DEVIN_MODELS_JSON" \
    FM_FAKE_DEVIN_MODELS_FAIL="${FM_FAKE_DEVIN_MODELS_FAIL:-0}" \
    FM_FAKE_DEVIN_MODELS_HANG="${FM_FAKE_DEVIN_MODELS_HANG:-0}" \
    FM_FAKE_DEVIN_IGNORE_TRUST="${FM_FAKE_DEVIN_IGNORE_TRUST:-0}" \
    FM_FAKE_DEVIN_NO_DIALOG="${FM_FAKE_DEVIN_NO_DIALOG:-0}" \
    FM_FAKE_DEVIN_STUCK="${FM_FAKE_DEVIN_STUCK:-0}" \
    FM_DEVIN_READY_POLLS=6 FM_DEVIN_POLL_INTERVAL=0 FM_DEVIN_MODELS_TIMEOUT=${FM_DEVIN_MODELS_TIMEOUT:-1} \
    PATH="$fakebin:$BASE_PATH" \
    "$SPAWN" "$id" "$proj" --harness devin --mode no-mistakes --yolo off "$@" 2>&1
}

# Bare Enter key presses only: shell setup rides its Enter on the typed text
# (`send-keys -t <target> export X=Y Enter`), while the launch submit and the
# trust-dialog answer are lone key sends (`send-keys -t <target> Enter`).
count_enter_sends() {  # <tmux-call-log>
  grep -c '^send-keys -t [^ ]* Enter$' "$1" || true
}

test_devin_launch_carries_the_brief_with_model_and_autonomy() {
  local id rec out rc launch meta config
  id="devin-launch-z1-$$"
  rec=$(make_devin_spawn_case launch "$id")
  read_devin_spawn_record "$rec"
  out=$(run_devin_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" \
    --model opus --effort low)
  rc=$?
  expect_code 0 "$rc" "devin spawn with a listed model should succeed"
  assert_contains "$out" "spawned $id harness=devin" "devin spawn did not report success"
  launch=$(cat "$CASE_DIR/launch.log")
  assert_contains "$launch" "$FAKEBIN_DIR/devin" "devin launch did not pin the resolved absolute binary"
  assert_contains "$launch" "--config" "devin launch did not point at the per-task config"
  assert_contains "$launch" "$HOME_DIR/state/$id.devin-config.json" "devin launch did not carry the per-task config path"
  assert_contains "$launch" "--permission-mode bypass" "devin launch omitted unattended autonomy"
  assert_contains "$launch" "--model 'opus'" "devin launch did not carry the requested model"
  assert_contains "$launch" "encode launch-brief" "devin launch did not carry the brief encoder"
  assert_contains "$launch" "env -u CLAUDECODE" "devin launch did not clear the inherited launcher marker"
  assert_contains "$launch" "env -u CURSOR_AGENT" "devin launch did not clear the peer markers"
  assert_not_contains "$launch" "__DEVINBIN__" "devin launch left its binary placeholder unsubstituted"
  assert_not_contains "$launch" "__DEVINCONFIG__" "devin launch left its config placeholder unsubstituted"
  assert_not_contains "$launch" "__MODELFLAG__" "devin launch left its model placeholder unsubstituted"
  assert_not_contains "$launch" "__BRIEF__" "devin launch left its brief placeholder unsubstituted"
  assert_not_contains "$launch" "--effort" "devin launch passed an effort flag devin does not accept"
  assert_not_contains "$launch" "--thinking" "devin launch passed a thinking flag devin does not accept"
  config="$HOME_DIR/state/$id.devin-config.json"
  assert_present "$config" "devin spawn did not write the per-task config"
  for ev in SessionStart UserPromptSubmit Stop SessionEnd; do
    assert_contains "$(cat "$config")" "\"$ev\"" "devin config lacks the $ev hook"
  done
  assert_contains "$(cat "$config")" "devin-hook" "devin config hooks do not carry the busy source"
  assert_contains "$(cat "$config")" "$id" "devin config hooks do not bind this task id"
  assert_absent "$WT_DIR/.devin/config.local.json" "devin spawn must not write the worktree's local config"
  assert_absent "$WT_DIR/.devin/hooks.v1.json" "devin spawn must not write the worktree's hooks file"
  meta="$HOME_DIR/state/$id.meta"
  assert_grep 'harness=devin' "$meta" "devin meta did not record its harness"
  assert_grep 'model=opus' "$meta" "devin meta did not record its model"
  assert_grep 'effort=low' "$meta" "devin meta did not record its effort"
  [ "$(cat "$CASE_DIR/devin.state")" = launched ] \
    || fail "the fake session never reached its launched state"
  assert_not_contains "$(cat "$CASE_DIR/tmux-calls.log")" "kill-window" \
    "a successful devin spawn must never tear down the endpoint it just launched"
  pass "fm-spawn: devin launch carries brief, model, and autonomy with cleared markers and a per-task config"
}

test_devin_config_merge_preserves_the_user_config() {
  local id rec out rc config
  id="devin-merge-z2-$$"
  rec=$(make_devin_spawn_case merge "$id")
  read_devin_spawn_record "$rec"
  mkdir -p "$HOME_DIR/.config/devin"
  printf '%s\n' '{"theme_mode":"dark","permissions":{"allow":["Read(**)"]},"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"echo project-hook"}]}]}}' \
    > "$HOME_DIR/.config/devin/config.json"
  out=$(run_devin_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id")
  rc=$?
  expect_code 0 "$rc" "devin spawn with a user config should succeed"
  config="$HOME_DIR/state/$id.devin-config.json"
  assert_contains "$(cat "$config")" '"theme_mode": "dark"' "devin config dropped the user theme"
  assert_contains "$(cat "$config")" 'Read(**)' "devin config dropped the user permissions"
  assert_contains "$(cat "$config")" 'echo project-hook' "devin config dropped the user's own Stop hook"
  [ "$(node -e 'console.log(JSON.parse(require("node:fs").readFileSync(process.argv[1],"utf8")).hooks.Stop.length);' "$config")" = 2 ] \
    || fail "the user Stop hook and firstmate's Stop hook must merge, not override"
  assert_contains "$(cat "$HOME_DIR/.config/devin/config.json")" 'echo project-hook' \
    "the user config itself must be untouched"
  assert_not_contains "$(cat "$HOME_DIR/.config/devin/config.json")" "devin-hook" \
    "firstmate's hooks leaked into the user's own config"
  pass "fm-spawn: devin merges its hooks into an opaque user-config copy"
}

test_devin_unparseable_user_config_refuses() {
  local id rec out rc
  id="devin-badconfig-z3-$$"
  rec=$(make_devin_spawn_case badconfig "$id")
  read_devin_spawn_record "$rec"
  mkdir -p "$HOME_DIR/.config/devin"
  printf '%s\n' '{not json' > "$HOME_DIR/.config/devin/config.json"
  rc=0
  out=$(run_devin_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "an unparseable user config should refuse the spawn"
  assert_contains "$out" "not usable" "unparseable user config refusal lacked its concrete reason"
  [ -s "$CASE_DIR/launch.log" ] && fail "an unparseable user config created a launch command" || true
  pass "fm-spawn: an unparseable devin user config refuses before pane creation"
}

test_devin_hooks_semantic_lifecycle() {
  local id rec out rc state config cmd
  id="devin-hooks-z4-$$"
  rec=$(make_devin_spawn_case hooks "$id")
  read_devin_spawn_record "$rec"
  out=$(run_devin_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id")
  rc=$?
  expect_code 0 "$rc" "devin spawn should succeed: $out"
  state="$HOME_DIR/state"
  config="$state/$id.devin-config.json"
  run_devin_hook() {
    cmd=$(node -e 'console.log(JSON.parse(require("node:fs").readFileSync(process.argv[1],"utf8")).hooks[process.argv[2]][0].hooks[0].command);' "$config" "$1")
    [ -n "$cmd" ] || fail "no $1 hook command in $config"
    sh -c "$cmd"
  }
  out=$(fm_busy_classify tmux fake:w devin "$id" "$state")
  [ "$out" = "busy devin-hook" ] || fail "the fake session start must classify 'busy devin-hook', got '$out'"

  rm -f "$state/$id.turn-ended"
  run_devin_hook Stop || fail "Stop hook command failed"
  [ -f "$state/$id.turn-ended" ] || fail "Stop no longer touches the notification marker"
  out=$(fm_busy_classify tmux fake:w devin "$id" "$state")
  [ "$out" = "idle devin-hook" ] || fail "Stop must classify 'idle devin-hook', got '$out'"

  run_devin_hook UserPromptSubmit || fail "UserPromptSubmit hook command failed"
  out=$(fm_busy_classify tmux fake:w devin "$id" "$state")
  [ "$out" = "busy devin-hook" ] || fail "UserPromptSubmit must classify 'busy devin-hook', got '$out'"

  run_devin_hook SessionEnd || fail "SessionEnd hook command failed"
  out=$(fm_busy_classify tmux fake:w devin "$id" "$state")
  [ "$out" = "idle devin-hook" ] || fail "SessionEnd must classify idle, got '$out'"
  run_devin_hook SessionEnd >/dev/null || fail "a repeated SessionEnd must still exit 0"
  out=$(fm_busy_classify tmux fake:w devin "$id" "$state")
  [ "$out" = "idle devin-hook" ] || fail "a repeated SessionEnd must stay idle, got '$out'"
  pass "devin hooks open on SessionStart/UserPromptSubmit and close on Stop and a repeated SessionEnd"
}

test_devin_hooks_stale_incarnation_harmless() {
  local id rec out rc state config cmd
  id="devin-stale-z5-$$"
  rec=$(make_devin_spawn_case stale "$id")
  read_devin_spawn_record "$rec"
  out=$(run_devin_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id")
  rc=$?
  expect_code 0 "$rc" "devin spawn should succeed: $out"
  state="$HOME_DIR/state"
  config="$state/$id.devin-config.json"
  "$ROOT/bin/fm-busy-event.sh" arm "$state" "$id" >/dev/null
  cmd=$(node -e 'console.log(JSON.parse(require("node:fs").readFileSync(process.argv[1],"utf8")).hooks.UserPromptSubmit[0].hooks[0].command);' "$config")
  sh -c "$cmd" >/dev/null \
    || fail "a stale-gen hook must still exit 0 so devin's lifecycle is never broken"
  out=$(fm_busy_classify tmux fake:w devin "$id" "$state")
  [ "$out" = "busy fm-spawn" ] || fail "a stale-gen hook event must not change state, got '$out'"
  pass "devin hook events from a superseded incarnation are rejected without breaking the hook"
}

test_devin_effort_is_recorded_but_omitted() {
  local id rec out rc launch meta
  id="devin-effort-z6-$$"
  rec=$(make_devin_spawn_case effort "$id")
  read_devin_spawn_record "$rec"
  out=$(run_devin_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" \
    --effort xhigh)
  rc=$?
  expect_code 0 "$rc" "devin spawn with an effort should still succeed"
  launch=$(cat "$CASE_DIR/launch.log")
  assert_not_contains "$launch" "--effort" "devin launch passed a known-bad effort value"
  meta="$HOME_DIR/state/$id.meta"
  assert_grep 'effort=xhigh' "$meta" "devin meta did not retain the effort axis"
  pass "fm-spawn: devin omits effort from the launch but records it in task metadata"
}

test_devin_unlisted_model_refuses_before_pane_creation() {
  local id rec out rc
  id="devin-badmodel-z7-$$"
  rec=$(make_devin_spawn_case badmodel "$id")
  read_devin_spawn_record "$rec"
  rc=0
  out=$(run_devin_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" \
    --model claude-opus-99) || rc=$?
  [ "$rc" -ne 0 ] || fail "an unlisted devin model should refuse the spawn"
  assert_contains "$out" "not listed by 'devin models list --format json'" "unlisted model refusal lacked its concrete reason"
  [ -s "$CASE_DIR/launch.log" ] && fail "an unlisted model created a launch command" || true
  pass "fm-spawn: an unlisted devin model refuses before pane creation"
}

test_devin_unreachable_listing_launches_unvalidated() {
  local id rec out rc
  id="devin-nolisting-z8-$$"
  rec=$(make_devin_spawn_case nolisting "$id")
  read_devin_spawn_record "$rec"
  rc=0
  out=$(FM_FAKE_DEVIN_MODELS_FAIL=1 run_devin_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" \
    "$FAKEBIN_DIR" "$id" --model opus) || rc=$?
  expect_code 0 "$rc" "an unreachable model listing must not block the spawn"
  [ -s "$CASE_DIR/launch.log" ] || fail "an unreachable listing produced no launch command"
  assert_contains "$out" "listing is unreachable" "an unreachable listing launched without its notice"
  pass "fm-spawn: an unreachable devin listing establishes nothing and launches"
}

test_devin_hung_listing_is_cut_off_and_launches() {
  local id rec out rc started elapsed
  id="devin-hanglisting-z9-$$"
  rec=$(make_devin_spawn_case hanglisting "$id")
  read_devin_spawn_record "$rec"
  rc=0
  started=$(date +%s)
  out=$(FM_FAKE_DEVIN_MODELS_HANG=1 run_devin_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" \
    "$FAKEBIN_DIR" "$id" --model opus) || rc=$?
  elapsed=$(( $(date +%s) - started ))
  expect_code 0 "$rc" "a hung model listing must not block the spawn"
  [ "$elapsed" -lt 20 ] || fail "the model probe was not cut off by its bound (took ${elapsed}s)"
  assert_contains "$out" "did not answer within 1s" "a hung listing launched without its timeout notice"
  [ -s "$CASE_DIR/launch.log" ] || fail "a hung listing produced no launch command"
  assert_contains "$(cat "$CASE_DIR/launch.log")" "--model 'opus'" \
    "a hung listing dropped the requested model instead of launching it unvalidated"
  pass "fm-spawn: a hung devin listing is cut off by the shared bound and launches unvalidated"
}

test_devin_zero_model_timeout_is_clamped_to_the_default_bound() {
  local id rec out rc started elapsed
  id="devin-zerobound-z10-$$"
  rec=$(make_devin_spawn_case zerobound "$id")
  read_devin_spawn_record "$rec"
  rc=0
  started=$(date +%s)
  out=$(FM_FAKE_DEVIN_MODELS_HANG=1 FM_DEVIN_MODELS_TIMEOUT=0 \
    run_devin_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" \
    "$FAKEBIN_DIR" "$id" --model opus) || rc=$?
  elapsed=$(( $(date +%s) - started ))
  expect_code 0 "$rc" "a hung listing with a zero bound must not block the spawn"
  # The clamped 15s probe plus spawn overhead (trust pre-registration, config
  # merge, readiness gate) runs ~25s; a disabled deadline would let the 30s
  # sleeper run out, so 35s still separates the two.
  [ "$elapsed" -lt 35 ] || fail "a zero model bound disabled the deadline (took ${elapsed}s)"
  assert_contains "$out" "did not answer within 15s" \
    "a zero model bound was not clamped to the documented default"
  [ -s "$CASE_DIR/launch.log" ] || fail "a zero model bound produced no launch command"
  pass "fm-spawn: a zero FM_DEVIN_MODELS_TIMEOUT is clamped to the default bound"
}

test_devin_fresh_worktree_is_pre_trusted_and_launches_without_a_dialog() {
  local id rec out rc enters store
  id="devin-trust-z11-$$"
  rec=$(make_devin_spawn_case trust "$id")
  read_devin_spawn_record "$rec"
  store="$HOME_DIR/.local/share/devin/cli/trusted_workspaces.json"
  out=$(run_devin_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id")
  rc=$?
  expect_code 0 "$rc" "a devin spawn into a fresh worktree should succeed"
  assert_contains "$out" "spawned $id harness=devin" "devin spawn did not report success"
  assert_not_contains "$out" "could not pre-register" "a legitimate worktree failed trust pre-registration"
  assert_devin_trusted "$store" "$WT_DIR" "the spawn did not pre-register the worktree in devin's trust store"
  enters=$(count_enter_sends "$CASE_DIR/tmux-calls.log")
  [ "$enters" -eq 1 ] \
    || fail "a pre-trusted worktree must receive only the launch Enter, got $enters Enter sends"
  assert_not_contains "$(cat "$CASE_DIR/tmux-calls.log")" "kill-window" \
    "a successful devin spawn must never tear down the endpoint it just launched"
  pass "fm-spawn: devin pre-registers the worktree and launches straight into hook-busy"
}

test_devin_dialog_despite_registration_is_answered_once() {
  local id rec out rc enters
  id="devin-vendor-z12-$$"
  rec=$(make_devin_spawn_case vendor-dialog "$id")
  read_devin_spawn_record "$rec"
  out=$(FM_FAKE_DEVIN_IGNORE_TRUST=1 run_devin_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" \
    "$FAKEBIN_DIR" "$id")
  rc=$?
  expect_code 0 "$rc" "a devin spawn whose dialog renders despite registration should succeed"
  enters=$(count_enter_sends "$CASE_DIR/tmux-calls.log")
  [ "$enters" -eq 2 ] \
    || fail "expected exactly one launch Enter plus one trust-dialog Enter, got $enters Enter sends"
  pass "fm-spawn: devin answers a dialog that renders anyway exactly once, then confirms hook-busy"
}

test_devin_unregistered_path_without_a_dialog_fails_the_spawn() {
  local id rec out rc store
  id="devin-nodialog-z13-$$"
  rec=$(make_devin_spawn_case nodialog "$id")
  read_devin_spawn_record "$rec"
  store="$HOME_DIR/.local/share/devin/cli"
  mkdir -p "$store"
  mkdir -p "$store/trusted_workspaces.json"
  rc=0
  out=$(FM_FAKE_DEVIN_NO_DIALOG=1 run_devin_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" \
    "$FAKEBIN_DIR" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "a missing dialog on an unregistered path must not pass the gate"
  assert_contains "$out" "could not pre-register devin workspace trust" \
    "a broken store did not surface the registration warning"
  assert_contains "$out" "never showed its workspace-trust dialog on an unregistered worktree" \
    "the failure did not name the unconfirmed workspace"
  assert_not_contains "$out" "spawned $id" "an unconfirmed workspace still reported a successful spawn"
  [ "$(count_enter_sends "$CASE_DIR/tmux-calls.log")" -eq 1 ] \
    || fail "the gate must not send Enter into a pane that shows no dialog"
  assert_contains "$(cat "$CASE_DIR/tmux-calls.log")" "kill-window" \
    "a failed devin readiness gate left its launched endpoint running"
  assert_grep 'failed: devin never showed its workspace-trust dialog' <(sed -E 's/ \[at=[0-9]+\]//' "$HOME_DIR/state/$id.status") \
    "a failed devin readiness gate did not record the failure in the task status"
  pass "fm-spawn: a missing dialog on an unregistered path fails and closes the endpoint"
}

test_devin_pre_trusted_path_that_never_turns_hook_busy_fails_the_spawn() {
  local id rec out rc
  id="devin-stuck-z14-$$"
  rec=$(make_devin_spawn_case stuck "$id")
  read_devin_spawn_record "$rec"
  rc=0
  out=$(FM_FAKE_DEVIN_STUCK=1 run_devin_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" \
    "$FAKEBIN_DIR" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "a session whose hooks never fire must fail the spawn"
  assert_contains "$out" "did not start processing its brief in the pre-trusted worktree" \
    "a stuck session failed without its concrete reason"
  assert_contains "$(cat "$CASE_DIR/tmux-calls.log")" "kill-window" \
    "a failed devin readiness gate left its launched endpoint running"
  pass "fm-spawn: a pre-trusted session that never turns hook-busy fails the spawn and closes the endpoint"
}

test_devin_missing_binary_refuses_before_pane_creation() {
  local id rec out rc
  id="devin-missing-z15-$$"
  rec=$(make_devin_spawn_case missing "$id")
  read_devin_spawn_record "$rec"
  rm "$FAKEBIN_DIR/devin"
  rc=0
  out=$(run_devin_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "a missing devin executable should refuse the spawn"
  assert_contains "$out" "devin executable not found on PATH" "missing devin diagnostic lacked its concrete reason"
  [ -s "$CASE_DIR/launch.log" ] && fail "a missing devin executable created a launch command" || true
  pass "fm-spawn: a missing devin executable refuses before pane creation"
}

test_devin_secondmate_is_refused() {
  local id rec out rc
  id="devin-secondmate-z16-$$"
  rec=$(make_devin_spawn_case secondmate-refuse "$id")
  read_devin_spawn_record "$rec"
  rc=0
  out=$(HOME="$HOME_DIR" FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 PATH="$FAKEBIN_DIR:$BASE_PATH" \
    "$SPAWN" "$id" --secondmate devin 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a devin secondmate spawn should be refused"
  assert_contains "$out" "devin is a verified crewmate/scout adapter only" \
    "devin secondmate refusal lacked its concrete reason"
  pass "fm-spawn: devin cannot be launched as a secondmate"
}

test_devin_raw_launch_has_no_semantic_wiring() {
  local id rec out rc state
  id="devin-raw-z17-$$"
  rec=$(make_devin_spawn_case raw "$id")
  read_devin_spawn_record "$rec"
  out=$(XDG_DATA_HOME= XDG_CONFIG_HOME= HOME="$HOME_DIR" FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$CASE_DIR/launch.log" \
    FM_FAKE_TMUX_CALL_LOG="$CASE_DIR/tmux-calls.log" \
    FM_FAKE_DEVIN_STATE="$CASE_DIR/devin.state" \
    FM_FAKE_DEVIN_TRUST_STORE="$HOME_DIR/.local/share/devin/cli/trusted_workspaces.json" \
    FM_DEVIN_READY_POLLS=6 FM_DEVIN_POLL_INTERVAL=0 \
    PATH="$FAKEBIN_DIR:$BASE_PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" "devin --config /tmp/x -- 'raw probe'" --mode no-mistakes --yolo off 2>&1)
  rc=$?
  expect_code 0 "$rc" "raw devin spawn should succeed: $out"
  state="$HOME_DIR/state"
  assert_absent "$state/$id.busy-gen" "raw devin launch must not arm a busy generation"
  assert_absent "$state/$id.devin-config.json" "raw devin launch must not write hook config"
  out=$(fm_busy_classify tmux fake:w devin "$id" "$state")
  [ "$out" = "unknown missing" ] || fail "raw devin launch must classify unknown, got '$out'"
  pass "fm-spawn: a raw devin launch remains unwired and classifies unknown"
}

test_devin_ancestry_detects_the_native_command_name
test_devin_ancestry_rejects_unrelated_mentions
test_devin_claims_no_inherited_launcher_marker
test_devin_control_mechanics_are_the_verified_ones
test_devin_busy_source_is_trusted_and_scoped
test_devin_tmux_names_the_native_binary_an_agent
test_devin_composer_contract_is_the_bare_glyph_row
test_devin_trust_registers_the_logical_and_resolved_worktree_paths
test_devin_trust_creates_a_missing_store
test_devin_trust_honours_xdg_data_home
test_devin_trust_refuses_out_of_scope_paths
test_devin_launch_carries_the_brief_with_model_and_autonomy
test_devin_config_merge_preserves_the_user_config
test_devin_unparseable_user_config_refuses
test_devin_hooks_semantic_lifecycle
test_devin_hooks_stale_incarnation_harmless
test_devin_effort_is_recorded_but_omitted
test_devin_unlisted_model_refuses_before_pane_creation
test_devin_unreachable_listing_launches_unvalidated
test_devin_hung_listing_is_cut_off_and_launches
test_devin_zero_model_timeout_is_clamped_to_the_default_bound
test_devin_fresh_worktree_is_pre_trusted_and_launches_without_a_dialog
test_devin_dialog_despite_registration_is_answered_once
test_devin_unregistered_path_without_a_dialog_fails_the_spawn
test_devin_pre_trusted_path_that_never_turns_hook_busy_fails_the_spawn
test_devin_missing_binary_refuses_before_pane_creation
test_devin_secondmate_is_refused
test_devin_raw_launch_has_no_semantic_wiring

echo "all fm-devin-harness tests passed"
