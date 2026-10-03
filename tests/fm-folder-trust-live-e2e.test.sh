#!/usr/bin/env bash
# Live guard for the trust decision a fresh worktree would otherwise make a human
# answer: the codex "Trust this folder?" dialog and the pi "Trust project folder?"
# prompt.
#
# Both verdicts come from the installed harnesses, not from a stub. What this
# protects is a vendor-owned surface: the exact key codex reads folder trust from,
# and the exact flag pi treats as a per-run trust decision. A fake can only
# confirm the assumption written into it, so this replays the REAL launch flags
# firstmate builds (captured from a spawn driven through a fake pane, the
# tests/fm-codex-hook-layer-live-e2e.test.sh shape) against the installed
# binaries in a throwaway config root and fresh directories, and reads the
# rendered pane.
#
# Five facts are pinned, three for Codex and two for Pi, with controls:
#   codex  an unregistered fresh worktree renders the dialog (the fixture really
#          is trust-gated, so the pass below cannot go vacuous)
#   codex  bin/fm-codex-trust.sh, run first, removes it
#   codex  trusting an ancestor above the repository root leaves the dialog
#          standing
#   pi     an untrusted fresh directory renders the prompt with the launch flags
#          minus pi's own trust flag
#   pi     the same flags as firstmate actually launches them, which carry
#          --approve, render no prompt and reach the running editor
#
# It spends no model tokens: every harness is started with no positional prompt,
# so nothing reaches a model, and it runs by default wherever codex, pi, and tmux
# are installed. Each runtime's cases self-skip with a recorded reason when its
# selected credential store has no readable login; the other runtime still runs.
set -u

CODEX_AUTH_FILE="${CODEX_HOME:-$HOME/.codex}/auth.json"
PI_AUTH_DIR="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

fm_live_gate default-on FM_FOLDER_TRUST_LIVE codex pi tmux

CODEX_VERSION=$(codex --version 2>&1 | head -1)
PI_VERSION=$(pi --version 2>&1 | head -1)
TMP_ROOT=$(fm_test_tmproot fm-folder-trust-live)
TMUX_SOCKET="$TMP_ROOT/tmux.sock"
SESSIONS=()

cleanup() {
  local sess
  for sess in "${SESSIONS[@]}"; do
    tmux -S "$TMUX_SOCKET" kill-session -t "$sess" 2>/dev/null || true
  done
  tmux -S "$TMUX_SOCKET" kill-server 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
trap 'exit 131' QUIT

open_pane() {  # <name> <dir> <command...>: start one harness in a fresh pane
  local name=$1 dir=$2
  shift 2
  local sess="fmft-$name"
  tmux -S "$TMUX_SOCKET" new-session -d -s "$sess" -x 160 -y 45 -c "$dir" \
    "$*" || fail "could not open the test-owned pane $sess"
  SESSIONS+=("$sess")
  OPENED_SESSION=$sess
}

pane_text() {  # <session>: the visible viewport, whitespace-collapsed
  tmux -S "$TMUX_SOCKET" capture-pane -pt "$1" -S -60 2>/dev/null | tr -s ' \n' '  ' || true
}

# read_pane <session>: the viewport with any vendor update nag dismissed. Both
# harnesses can render a first-launch "update available" modal stacked ON TOP of
# the dialog under test, so a capture that does not clear the stack first can
# report a dialog that is really there as absent.
read_pane() {
  local sess=$1 text='' attempts=0
  while [ "$attempts" -lt 3 ]; do
    attempts=$((attempts + 1))
    text=$(pane_text "$sess")
    case $text in
      *'Update available'* | *'Update Available'* | *'Release notes'*)
        tmux -S "$TMUX_SOCKET" send-keys -t "$sess" Escape 2>/dev/null || true
        sleep 1
        continue
        ;;
    esac
    break
  done
  printf '%s' "$text"
}

# wait_for_pane <session> <matcher-fn> [seconds]: poll until the pane satisfies
# <matcher-fn> or the budget runs out; echoes the last capture either way.
wait_for_pane() {
  local sess=$1 matcher=$2 budget=${3:-25} waited=0 text
  while [ "$waited" -lt "$budget" ]; do
    text=$(read_pane "$sess")
    if "$matcher" "$text"; then
      printf '%s' "$text"
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
  printf '%s' "${text:-}"
  return 1
}

see_codex_dialog() {
  case $1 in
    *'Trust this folder?'*) return 0 ;;
  esac
  return 1
}

see_codex_running() {
  case $1 in
    *'Trust this folder?'*) return 1 ;;
  esac
  case $1 in
    *'› '*) ;;
    *) return 1 ;;
  esac
  case $1 in
    *'Ask Codex to do anything'* | *'? for shortcuts'*) return 0 ;;
  esac
  return 1
}

see_pi_prompt() {
  case $1 in
    *'Trust project folder?'*) return 0 ;;
  esac
  return 1
}

see_pi_started() {
  case $1 in
    *'Trust project folder?'*) return 1 ;;
  esac
  # Two independent startup signals, so no single vendor string is load-bearing.
  case $1 in
    *'escape interrupt'*) return 0 ;;
    *'ctrl+o'*) return 0 ;;
  esac
  return 1
}

# --- fixture: one project, one fresh linked worktree of it ------------------

CASE="$TMP_ROOT/case"
PROJ="$CASE/project"
WT="$CASE/wt"
PI_WT="$CASE/pi-wt"
fm_git_worktree "$PROJ" "$WT" "wt-live"
printf '{}\n' > "$TMP_ROOT/treehouse-state.json"
# pi gates a directory on .pi resources or an ancestor .agents/skills; a firstmate
# worktree has both, so the fixture carries the same shape.
mkdir -p "$PI_WT/.pi/extensions" "$PI_WT/.agents/skills"
printf '{}\n' > "$PROJ/.pi-settings-marker"

CODEX_HOME_DIR="$CASE/codex-home"

# capture_launch <name> <harness> -> the literal command firstmate sent the pane
capture_launch() {
  local name=$1 harness=$2
  local case_dir="$CASE/spawn-$name" fakebin
  fakebin=$(fm_test_make_spawn_fakebin "$CASE/fake-$name" "$harness")
  fm_test_spawn_home "$case_dir/home" "$harness"
  fm_test_spawn_brief "$case_dir/home" "$name"
  : > "$case_dir/launch.log"
  printf '%s\n' "$fakebin/$harness" > "$case_dir/executable"
  FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" \
    fm_test_run_spawn "$case_dir/home" "$WT" "$fakebin" "$name" "$PROJ" \
    --mode no-mistakes --yolo off >/dev/null 2>&1 ||
    fail "$CODEX_VERSION/$PI_VERSION: fm-spawn could not build a $harness crewmate launch"
  cat "$case_dir/launch.log"
}

# global_flags <launcher> <launch>: the launcher's own arguments, everything
# before the positional brief, so the guard can replay the configuration without
# spending a model turn.
global_flags() {
  python3 - "$1" "$2" <<'PY'
import shlex
import sys
launcher, launch = sys.argv[1:]
prefix, marker, _ = launch.partition('"$(')
if not marker:
    sys.exit("the captured launch has no positional brief boundary")
words = shlex.split(prefix)
if words.count(launcher) != 1:
    sys.exit("the captured launch does not name the expected executable exactly once")
flags = words[words.index(launcher) + 1:]
arity = {
    "--dangerously-bypass-approvals-and-sandbox": 0,
    "--disable": 1,
    "-c": 1,
    "--model": 1,
    "--tui-mode": 1,
    "--approve": 0,
    "--thinking": 1,
    "-e": 1,
}
i = 0
while i < len(flags):
    count = arity.get(flags[i])
    if count is None or i + count >= len(flags):
        sys.exit("refusing replay arguments containing an unknown option or positional prompt")
    i += count + 1
if not flags or not flags[0].startswith("-"):
    sys.exit("replayed arguments must begin with a flag, never an executable path")
print(shlex.join(flags))
PY
}

# --- codex ------------------------------------------------------------------

test_codex_dialog_gates_an_unregistered_worktree() {
  local sess text
  open_pane codex-control "$WT" "env CODEX_HOME=$(printf '%q' "$CODEX_HOME_DIR") codex $CODEX_FLAGS"
  sess=$OPENED_SESSION
  text=$(wait_for_pane "$sess" see_codex_dialog 30)
  see_codex_dialog "$text" ||
    fail "codex $CODEX_VERSION showed no folder-trust dialog in an unregistered fresh worktree, so this fixture proves nothing: $text"
  pass "live: codex $CODEX_VERSION gates an unregistered fresh worktree on the folder-trust dialog"
}

test_codex_trust_script_removes_the_dialog() {
  local out sess text
  out=$(CODEX_HOME="$CODEX_HOME_DIR" "$ROOT/bin/fm-codex-trust.sh" "$WT" "$PROJ" 2>&1) ||
    fail "fm-codex-trust.sh refused a legitimate fresh worktree: $out"
  assert_contains "$out" "$PROJ" "the registration did not report the repository root: $out"
  assert_contains "$(cat "$CODEX_HOME_DIR/config.toml")" "[projects.\"$PROJ\"]" \
    "codex did not read the entry this guard wrote, and the pane below says so"
  open_pane codex-registered "$WT" "env CODEX_HOME=$(printf '%q' "$CODEX_HOME_DIR") codex $CODEX_FLAGS"
  sess=$OPENED_SESSION
  text=$(wait_for_pane "$sess" see_codex_running 30)
  see_codex_running "$text" ||
    fail "codex $CODEX_VERSION still shows the folder-trust dialog after bin/fm-codex-trust.sh registered $PROJ: $text"
  pass "live: codex $CODEX_VERSION launches into a pre-registered fresh worktree with no dialog"
}

# The store key is the whole point of the control above: codex persists the entry
# for the repository root, so an entry for a directory merely above that root must
# NOT suppress the dialog. If a release starts walking ancestors, this fails and
# the "one entry per project" claim has to be revisited.
test_codex_root_entry_is_the_narrow_key() {
  local above="$CASE/ancestor" above_home="$CASE/codex-home-above" sess text
  mkdir -p "$above" "$above_home"
  printf 'check_for_update_on_startup = false\n\n[projects."%s"]\ntrust_level = "trusted"\n' "$above" \
    > "$above_home/config.toml"
  ln -s "$CODEX_AUTH_FILE" "$above_home/auth.json"
  fm_git_worktree "$above/repository" "$above/worktrees/fresh" other-wt
  open_pane codex-above "$above/worktrees/fresh" \
    "env CODEX_HOME=$(printf '%q' "$above_home") codex $CODEX_FLAGS"
  sess=$OPENED_SESSION
  text=$(wait_for_pane "$sess" see_codex_dialog 30)
  see_codex_dialog "$text" ||
    fail "codex $CODEX_VERSION stopped asking for a directory whose only registered ancestor is above the repository root; the one-entry-per-project scope claim needs re-reviewing: $text"
  pass "live: codex $CODEX_VERSION keys folder trust on the repository root, not an ancestor"
}

# --- pi ---------------------------------------------------------------------

# A throwaway pi root, seeded with the operator's own credentials and model
# catalog so pi reaches its editor instead of failing on a provider, and starting
# with no trust.json at all so the trust decision is genuinely undecided.
PI_ROOT="$CASE/pi-root"

test_pi_prompt_gates_an_untrusted_directory() {
  local sess text
  open_pane pi-control "$PI_WT" "env PI_CODING_AGENT_DIR=$(printf '%q' "$PI_ROOT") pi ${PI_FLAGS/--approve/}"
  sess=$OPENED_SESSION
  text=$(wait_for_pane "$sess" see_pi_prompt 30)
  see_pi_prompt "$text" ||
    fail "pi $PI_VERSION showed no project-trust prompt in an untrusted fresh directory, so this fixture proves nothing: $text"
  pass "live: pi $PI_VERSION gates an untrusted fresh directory on the project-trust prompt"
}

test_pi_launch_flag_reaches_the_editor_with_no_prompt() {
  local sess text
  [ -f "$PI_ROOT/trust.json" ] && fail "pi wrote a trust store unprompted, so --approve is persisting: $(cat "$PI_ROOT/trust.json")"
  open_pane pi-approved "$PI_WT" "env PI_CODING_AGENT_DIR=$(printf '%q' "$PI_ROOT") pi $PI_FLAGS"
  sess=$OPENED_SESSION
  text=$(wait_for_pane "$sess" see_pi_started 30)
  see_pi_started "$text" ||
    fail "pi $PI_VERSION with firstmate's own launch flags showed no editor and no prompt, so the verdict is unknown: $text"
  [ -f "$PI_ROOT/trust.json" ] &&
    fail "pi persisted a trust decision from --approve; the per-run flag must write nothing: $(cat "$PI_ROOT/trust.json")"
  pass "live: pi $PI_VERSION launches with --approve, shows no prompt, and persists nothing"
}

if [ -r "$CODEX_AUTH_FILE" ]; then
  # Codex needs a login to reach its composer; an auth-less start cannot prove
  # that folder trust was accepted. All replay writes stay in this test store.
  mkdir -p "$CODEX_HOME_DIR"
  ln -s "$CODEX_AUTH_FILE" "$CODEX_HOME_DIR/auth.json"
  # Silence the update nag so the only modal is the one under test.
  printf 'check_for_update_on_startup = false\n' > "$CODEX_HOME_DIR/config.toml"
  CODEX_LAUNCH=$(capture_launch codex-live codex)
  CODEX_FLAGS=$(global_flags codex "$CODEX_LAUNCH") || fail "refusing unsafe Codex replay flags"
  test_codex_dialog_gates_an_unregistered_worktree
  test_codex_trust_script_removes_the_dialog
  test_codex_root_entry_is_the_narrow_key
else
  printf 'skip: live: codex folder trust: no readable login at %s\n' "$CODEX_AUTH_FILE"
fi

if [ -r "$PI_AUTH_DIR/auth.json" ]; then
  mkdir -p "$PI_ROOT"
  ln -s "$PI_AUTH_DIR/auth.json" "$PI_ROOT/auth.json"
  [ ! -f "$PI_AUTH_DIR/models.json" ] || ln -s "$PI_AUTH_DIR/models.json" "$PI_ROOT/models.json"
  PI_LAUNCH=$(capture_launch pi-live pi)
  PI_FLAGS=$(global_flags "$(cat "$CASE/spawn-pi-live/executable")" "$PI_LAUNCH") || fail "refusing unsafe Pi replay flags"
  case $PI_FLAGS in
    -*--approve* | --approve*) ;;
    *) fail "the captured pi launch lost its trust flag, so the guard would prove nothing: $PI_LAUNCH" ;;
  esac
  test_pi_prompt_gates_an_untrusted_directory
  test_pi_launch_flag_reaches_the_editor_with_no_prompt
else
  printf 'skip: live: pi project trust: no readable login at %s/auth.json\n' "$PI_AUTH_DIR"
fi
