#!/usr/bin/env bash
# tests/fm-turnend-captain-comms-live-e2e.test.sh - opt-in live guard proving
# every INSTALLED harness actually surfaces the non-blocking captain-facing
# reply length warning that bin/fm-turnend-guard.sh emits at turn end.
#
# Why this file exists: whether a warning reaches the captain is decided by
# something the vendor emits and renders - the turn-end payload shape a Stop
# hook receives, and whether that harness displays a hook's `systemMessage`,
# a Pi custom message, or an OpenCode TUI toast. A stub adapter can only
# confirm the assumption already written into the stub, so
# docs/turnend-guard.md must not state a per-harness delivery surface that only
# this guard can establish. The portable counterpart in
# tests/fm-turnend-guard.test.sh pins the guard's own decision logic in CI,
# where no harness binary or credential exists.
#
# This guard spends model tokens: each installed harness answers one prompt that
# forces a reply longer than the captain comms line cap, and the rendered pane
# is then read for the warning. Run it after every harness upgrade and before
# refreshing the per-harness rows in docs/verification/supervision.md.
set -u

if [ "${FM_TURNEND_CAPTAIN_COMMS_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_TURNEND_CAPTAIN_COMMS_LIVE_E2E=1 to run the installed-harness captain reply warning guard"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
unset NO_MISTAKES_GATE

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

command -v tmux >/dev/null 2>&1 || fail "tmux not found"
command -v jq >/dev/null 2>&1 || fail "jq not found"

REAL_TMUX=$(command -v tmux)
SOCKET="fm-captain-comms-live-$$"
SESSION=captaincomms
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-captain-comms-live.XXXXXX")

cleanup_all() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -n "${LAB:-}" ] && rm -rf "$LAB"
}
trap cleanup_all EXIT

# The reply the harness is asked to produce. Twenty lines is comfortably over
# the shared twelve-line default owned by bin/fm-slack-lib.sh.
#
# REPLY_COMPLETE_MARKER is what proves the model actually finished an over-cap
# reply, so it must be text the prompt itself cannot contain: every TUI harness
# echoes the prompt into the pane, and a precondition that the echoed prompt
# satisfies would report every short, slow, or refused answer as a delivery
# regression. The prompt therefore describes the line format without ever
# spelling the final line out.
OVERSIZED_PROMPT='Reply with exactly twenty lines and nothing else. Do not use any tool. Each line must be the text LINE- followed by that line number zero-padded to two digits.'
REPLY_COMPLETE_MARKER='LINE-20'
WARNING_MARKER='CAPTAIN COMMS WARNING'
# A harness that validates Stop hook stdout reports a failed hook rather than
# rendering anything. That is a different outcome from simply not displaying,
# and every harness is checked for it, so a rejection can never be misreported
# as delivery drift.
HOOK_REJECTION_MARKERS='Stop hook \(failed\)|hook returned invalid|invalid stop hook'

# Whether a harness has a non-blocking surface that accepts the guard's stdout
# envelope is a measured fact, not an assumption. Codex was measured rejecting
# the envelope, and Grok's Stop stdout schema has never been measured at all, so
# both tracked registrations tell the guard that channel has no reader; what
# this run proves for them is that the turn end stays clean, not that a warning
# appeared. Promote a row to `display` only after a live run establishes it.
warning_surface_for() {  # <harness>
  case "$1" in
    codex|grok) printf '%s\n' none ;;
    *) printf '%s\n' display ;;
  esac
}

case "$OVERSIZED_PROMPT" in
  *"$REPLY_COMPLETE_MARKER"*)
    echo "not ok - the reply-completion marker must not appear in the echoed prompt" >&2
    exit 1
    ;;
esac

# A primary-shaped scratch checkout carrying the repository's own tracked hook
# registrations, so each harness reaches the real guard through the real wiring
# rather than through a fixture written by this test.
build_home() {  # <dir>
  local dir=$1 file
  mkdir -p "$dir/bin" "$dir/state" "$dir/docs"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  for file in fm-turnend-guard.sh fm-turnend-guard-grok.sh fm-operational-input.sh \
    fm-slack-lib.sh fm-x-lib.sh fm-supervision-instructions.sh fm-harness.sh \
    fm-primary-scope-lib.sh fm-supervision-lib.sh fm-wake-lib.sh fm-sessionstart-nudge.sh \
    fm-claude-stop-autoarm.sh fm-arm-pretool-check.sh fm-cd-pretool-check.sh; do
    [ -f "$ROOT/bin/$file" ] || continue
    cp "$ROOT/bin/$file" "$dir/bin/$file"
    chmod +x "$dir/bin/$file"
  done
  cp -R "$ROOT/docs/supervision-protocols" "$dir/docs/supervision-protocols"
  for file in .claude .codex .grok .opencode .pi; do
    [ -e "$ROOT/$file" ] || continue
    cp -R "$ROOT/$file" "$dir/$file"
  done
}

capture() {  # <window>
  "$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$SESSION:$1" -S -400 2>/dev/null || true
}

wait_for_text() {  # <window> <text> [attempts]
  local window=$1 expected=$2 attempts=${3:-360} i=0
  while [ "$i" -lt "$attempts" ]; do
    capture "$window" | grep -Fq "$expected" && return 0
    sleep 0.5
    i=$((i + 1))
  done
  return 1
}

launch() {  # <window> <workdir> <command...>
  local window=$1 workdir=$2
  shift 2
  "$REAL_TMUX" -L "$SOCKET" new-window -d -t "$SESSION:" -n "$window" -c "$workdir" -- "$@"
}

# A harness launched in a scratch checkout it has never seen asks the operator
# to trust the directory before it will run a turn. Accepting through the TUI
# keeps that consent inside this run: pre-seeding the harness's own user-level
# config would mutate state outside the test.
TRUST_GATE_PROMPTS='I trust this folder|Do you trust the contents of this directory|trust the contents of this folder|Trust project folder\?'
HOOK_TRUST_GATE_PROMPT='Hooks need review'

# A harness launched in a scratch checkout it has never seen gates the first
# turn behind one or more operator consent prompts: the directory itself, and
# on Codex the project hooks this guard exists to exercise. Answering them
# through the TUI keeps that consent inside this run, where pre-seeding a
# harness's own user-level config would mutate state outside the test.
dismiss_startup_gates() {  # <window>
  local window=$1 i=0 answered=0 pane
  while [ "$i" -lt 120 ] && [ "$answered" -lt 4 ]; do
    pane=$(capture "$window")
    if printf '%s' "$pane" | grep -Fq "$HOOK_TRUST_GATE_PROMPT"; then
      # "Trust all and continue" is the second option; the guard is worthless
      # if the hooks it measures are declined.
      "$REAL_TMUX" -L "$SOCKET" send-keys -t "$SESSION:$window" Down
      "$REAL_TMUX" -L "$SOCKET" send-keys -t "$SESSION:$window" Enter
      answered=$((answered + 1))
      sleep 2
      i=$((i + 4))
      continue
    fi
    if printf '%s' "$pane" | grep -Eq "$TRUST_GATE_PROMPTS"; then
      "$REAL_TMUX" -L "$SOCKET" send-keys -t "$SESSION:$window" Enter
      answered=$((answered + 1))
      sleep 2
      i=$((i + 4))
      continue
    fi
    sleep 0.5
    i=$((i + 1))
  done
  return 0
}

harness_version() {  # <binary>
  local version
  version=$("$1" --version 2>/dev/null | head -1 | tr -d '\r') || version=
  [ -n "$version" ] || version=unknown
  printf '%s\n' "$version"
}

CHECKED=0
SKIPPED=

# Each entry names the harness, the tracked delivery surface the warning is
# expected to reach, and the launch argv shape bin/fm-spawn.sh uses for it.
run_harness_case() {  # <harness>
  local harness=$1 bin_path version home window
  bin_path=$(command -v "$harness" 2>/dev/null || true)
  if [ -z "$bin_path" ] || [ ! -x "$bin_path" ]; then
    SKIPPED="$SKIPPED $harness"
    note "skip: $harness is not installed on this machine, so its warning delivery is unverified here"
    return 0
  fi
  version=$(harness_version "$bin_path")
  home="$LAB/$harness"
  build_home "$home"
  window=$harness

  case "$harness" in
    claude)
      launch "$window" "$home" env "FM_HOME=$home" "CLAUDE_PROJECT_DIR=$home" \
        CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false \
        "$bin_path" --dangerously-skip-permissions "$OVERSIZED_PROMPT"
      ;;
    codex)
      launch "$window" "$home" env "FM_HOME=$home" \
        "$bin_path" --dangerously-bypass-approvals-and-sandbox "$OVERSIZED_PROMPT"
      ;;
    grok)
      launch "$window" "$home" env "FM_HOME=$home" "GROK_WORKSPACE_ROOT=$home" \
        "$bin_path" --always-approve "$OVERSIZED_PROMPT"
      ;;
    opencode)
      launch "$window" "$home" env "FM_HOME=$home" \
        'OPENCODE_CONFIG_CONTENT={"permission":{"*":"allow"}}' \
        OPENCODE_DISABLE_AUTOUPDATE=1 \
        "$bin_path" --prompt "$OVERSIZED_PROMPT"
      ;;
    pi)
      launch "$window" "$home" env "FM_HOME=$home" \
        "$bin_path" -e "$home/.pi/extensions/fm-primary-turnend-guard.ts" "$OVERSIZED_PROMPT"
      ;;
    *)
      fail "no launch shape is recorded for harness $harness"
      ;;
  esac

  dismiss_startup_gates "$window"

  # The reply must genuinely exceed the cap before any verdict about delivery
  # is meaningful; a short or refused answer proves nothing either way.
  wait_for_text "$window" "$REPLY_COMPLETE_MARKER" 360 || {
    capture "$window" >&2
    fail "$harness $version: never completed the twenty-line reply this guard measures, so nothing about warning delivery was tested"
  }

  # Every harness, whatever surface it is expected to have, must not be made to
  # report a failed turn-end hook by this guard.
  sleep 5
  if capture "$window" | grep -Eq "$HOOK_REJECTION_MARKERS"; then
    capture "$window" >&2
    fail "TURN-END SEMANTICS REGRESSION: $harness $version rejected the guard's turn-end hook output. Declare FM_TURNEND_STDOUT_SINK=none in this harness's tracked registration before the guard writes to a channel it validates."
  fi

  if [ "$(warning_surface_for "$harness")" = none ]; then
    note "$harness $version: no non-blocking warning surface; turn end stayed clean"
    pass "captain comms warning containment: $harness $version"
    CHECKED=$((CHECKED + 1))
    return 0
  fi

  if ! wait_for_text "$window" "$WARNING_MARKER" 120; then
    capture "$window" >&2
    fail "CAPTAIN COMMS WARNING DELIVERY DRIFT: $harness $version completed an over-cap captain-facing reply, but its turn-end surface never displayed the guard's warning. docs/turnend-guard.md's delivery claim for this harness is no longer true; re-establish the surface in the adapter before restoring that claim."
  fi

  note "$harness $version: displayed the captain reply length warning at turn end"
  pass "captain comms warning delivery: $harness $version"
  CHECKED=$((CHECKED + 1))
}

"$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -n control -c "$LAB" \
  || fail "could not start the private tmux server"

for harness in claude codex grok opencode pi; do
  run_harness_case "$harness"
done

[ "$CHECKED" -gt 0 ] || fail \
  "no supported harness is installed here, so this run proved nothing; install at least one harness before trusting a pass"

if [ -n "$SKIPPED" ]; then
  note "unverified on this machine (not installed):$SKIPPED"
fi
note "checked $CHECKED installed harness(es)"

cleanup_all
trap - EXIT
