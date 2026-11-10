#!/usr/bin/env bash
# Live guard for bin/fm-busy-lib.sh's launch-prompt backstop (live-harness-optin
# family). Per .agents/skills/firstmate-coding-guidelines "Harness-dependent
# checks", a classifier built on vendor-rendered dialog text must be proven
# against the REAL installed harness, because a stub can only confirm the
# assumption already written into the stub - and this guard exists because that
# assumption was wrong once already: an initial Pi signature, sourced only from
# the installed binary's own UI strings ("Project trust", an internal panel
# title never rendered as the dialog's own heading), silently never matched the
# real screen ("Trust project folder?") until this guard's first live run
# caught it.
#
# For each of claude, pi (covering pi-signed and omp, which share Pi's engine
# and trust gate), and gemini that is actually installed, this drives the REAL
# binary in an isolated tmux server into its genuine interactive launch prompt
# (a fresh untrusted worktree carrying a project-local trust-requiring
# resource for claude and pi, a fresh credential-less environment for gemini),
# captures the pane with the exact production shape (bin/fm-backend.sh's
# fm_backend_tmux_capture: `tmux capture-pane -p -S -40`), arms a scratch
# busy-state record exactly as fm-spawn.sh does at launch, and requires
# fm_busy_classify to report `unknown launch-prompt` instead of the record's
# seeded `busy fm-spawn`. No prompt is ever submitted and no dialog is ever
# answered (Escape only, never Enter), so no model tokens are spent and no
# operator credential store is written to. An absent harness binary is
# reported explicitly and skipped rather than silently passing over it; a run
# that checked nothing fails.
#
# Precondition: this machine's default `claude` config must already be past
# first-run onboarding (a subscription or API key already selected, and a
# theme already chosen) - the guard targets a brand-new SCRATCH WORKTREE under
# the operator's own already-onboarded config, exactly the shape a real
# crewmate spawn produces, never a fresh CLAUDE_CONFIG_DIR. An unonboarded
# machine reports that precondition explicitly rather than failing the
# signature.
#
# Run explicitly with FM_LAUNCH_PROMPT_SIGNALS_LIVE=1. Refresh
# docs/verification/runtime-backends.md ("Launch-prompt backstop signatures")
# from this guard's output after any of claude/pi/gemini upgrades.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REAL_TMUX=$(command -v tmux 2>/dev/null || true)
SOCKET="fm-launch-prompt-$$"
CHECKED=0
LABS=()

note() { printf '# %s\n' "$1"; }
pass() { printf 'ok - %s\n' "$1"; }

cleanup_all() {
  [ -z "${REAL_TMUX:-}" ] || "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  local lab
  for lab in "${LABS[@]:-}"; do
    [ -z "$lab" ] || rm -rf -- "$lab"
  done
}
trap cleanup_all EXIT

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }

fm_live_gate opt-in FM_LAUNCH_PROMPT_SIGNALS_LIVE tmux

# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"
EV="$ROOT/bin/fm-busy-event.sh"

# watcher_gate_not_busy: exercise the watcher's production absorb predicate on
# the same real pane capture. The custom tmux socket is intentionally not the
# watcher's default socket, so this checks the pure semantic gate with the
# recorded target while the harness itself remains a real live pane.
watcher_gate_not_busy() {  # <lab> <state> <target> <harness> <tail>
  local lab=$1 state=$2 target=$3 harness=$4 tail=$5
  mkdir -p "$lab/config"
  printf 'window=%s\nbackend=tmux\nharness=%s\n' "$target" "$harness" > "$state/t1.meta"
  FM_ROOT_OVERRIDE="$ROOT"
  FM_HOME="$lab"
  FM_STATE_OVERRIDE="$state"
  FM_CONFIG_OVERRIDE="$lab/config"
  export FM_ROOT_OVERRIDE FM_HOME FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE
  # shellcheck source=bin/fm-watch.sh
  . "$ROOT/bin/fm-watch.sh"
  if window_is_busy "$target" "$tail"; then
    fail "$harness: the watcher still treats the real parked prompt as busy"
  fi
}

# check_harness: launch <harness> (checked with fm_busy_classify, which may
# differ from the tmux <session> name when several harnesses share one real
# binary) via <cmd...> into a fresh worktree carrying <extra-file>
# (path,content - empty means none), wait up to 15s for <expect-regex> to
# render, capture the pane the production way, arm a scratch busy-state
# record, and require the launch-prompt backstop to classify it unknown
# launch-prompt. Never answers the dialog: Escape only, never Enter.
#
# Writes the captured tail to <tail-out> rather than returning it on stdout:
# a caller that needs the tail (the Pi case, which reuses it for pi-signed and
# omp) must NOT wrap this whole function in a command substitution just to
# capture that output, because `fail` calls `exit`, and `exit` inside a
# `$(...)` subshell only ends that subshell - a real failure would be silently
# swallowed there instead of failing the guard.
check_harness() {  # <harness> <session> <extra-path> <extra-content> <expect-regex> <tail-out> <cmd...>
  local harness=$1 session=$2 extra_path=$3 extra_content=$4 expect=$5 tail_out=$6
  local target="$session:w" lab state tail out
  shift 6
  lab=$(mktemp -d "${TMPDIR:-/tmp}/fm-launch-prompt-$harness.XXXXXX") || fail "$harness: could not create the isolated lab"
  LABS+=("$lab")
  mkdir -p "$lab/wt"
  git -C "$lab/wt" init -q || fail "$harness: could not initialize the isolated worktree"
  if [ -n "$extra_path" ]; then
    mkdir -p "$lab/wt/$(dirname "$extra_path")"
    printf '%s' "$extra_content" > "$lab/wt/$extra_path"
  fi

  "$REAL_TMUX" -L "$SOCKET" new-session -d -s "$session" -n w -c "$lab/wt" -- "$@" \
    || fail "$harness: could not launch the real binary"

  tail=''
  for _ in $(seq 1 75); do
    tail=$("$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$target" -S -40 2>/dev/null) || true
    printf '%s' "$tail" | grep -qiE "$expect" && break
    sleep 0.2
  done
  if ! printf '%s' "$tail" | grep -qiE "$expect"; then
    "$REAL_TMUX" -L "$SOCKET" kill-session -t "$session" >/dev/null 2>&1 || true
    fail "$harness: the real launch never rendered its expected prompt ('$expect') within 15s - captured tail:
$tail"
  fi

  state="$lab/state"
  mkdir -p "$state"
  "$EV" arm "$state" t1 >/dev/null || fail "$harness: could not arm the scratch busy-state record"
  out=$(fm_busy_classify tmux w1 "$harness" t1 "$state" "$tail")
  [ "$out" = "unknown launch-prompt" ] \
    || fail "$harness: real launch parked on its prompt classified '$out', expected 'unknown launch-prompt'"
  watcher_gate_not_busy "$lab" "$state" "$target" "$harness" "$tail"

  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$target" Escape >/dev/null 2>&1 || true
  "$REAL_TMUX" -L "$SOCKET" kill-session -t "$session" >/dev/null 2>&1 || true
  CHECKED=$((CHECKED + 1))
  [ -z "$tail_out" ] || printf '%s' "$tail" > "$tail_out"
}

CLAUDE_BIN=$(command -v claude 2>/dev/null || true)
if [ -x "${CLAUDE_BIN:-}" ]; then
  VERSION_OUT=$("$CLAUDE_BIN" --version 2>&1) || fail "claude --version failed: $VERSION_OUT"
  note "live claude version: $VERSION_OUT"
  check_harness claude fm-lp-claude-$$ '' '' \
    'Is this a project you created or one you trust' '' \
    "$CLAUDE_BIN" --dangerously-skip-permissions hello
  pass "claude: a real launch parked on its own rendered trust dialog surfaces through the watcher gate"
else
  note "claude not installed - launch-prompt signature not checked"
fi

PI_BIN=$(command -v pi 2>/dev/null || true)
if [ -x "${PI_BIN:-}" ]; then
  VERSION_OUT=$("$PI_BIN" --version 2>&1) || fail "pi --version failed: $VERSION_OUT"
  note "live pi version: $VERSION_OUT"
  # A fresh, isolated HOME is required so pi's own trust store has no prior
  # decision for this scratch worktree; a project-local .pi/extensions/ file
  # is what actually gates a fresh worktree behind the dialog (pi only asks
  # when the directory holds a trust-requiring resource), exactly the shape
  # fm-spawn.sh's own pi launch always carries.
  PI_HOME_LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-launch-prompt-pi-home.XXXXXX") || fail "pi: could not create the isolated HOME"
  LABS+=("$PI_HOME_LAB")
  PI_TAIL_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-launch-prompt-pi-tail.XXXXXX") || fail "pi: could not create the tail capture file"
  LABS+=("$PI_TAIL_FILE")
  check_harness pi fm-lp-pi-$$ '.pi/extensions/dummy.ts' 'export default {};' \
    'Trust project folder' "$PI_TAIL_FILE" \
    env HOME="$PI_HOME_LAB" "$PI_BIN" hello
  # pi-signed and omp share Pi's engine and the same project-trust gate
  # (fm_busy_launch_prompt_parked), so the one real capture also proves them,
  # each against its own freshly armed fm-spawn seed record.
  for h in pi-signed omp; do
    hstate=$(mktemp -d "${TMPDIR:-/tmp}/fm-launch-prompt-$h.XXXXXX") || fail "$h: could not create the isolated state dir"
    LABS+=("$hstate")
    "$EV" arm "$hstate" t1 >/dev/null || fail "$h: could not arm the scratch busy-state record"
    out=$(fm_busy_classify tmux w1 "$h" t1 "$hstate" "$(cat "$PI_TAIL_FILE")")
    [ "$out" = "unknown launch-prompt" ] \
      || fail "$h: the same real Pi trust-dialog capture classified '$out', expected 'unknown launch-prompt'"
  done
  pass "pi, pi-signed, omp: a real Pi-engine launch parked on its own rendered trust dialog surfaces through the watcher gate"
else
  note "pi not installed - launch-prompt signature not checked"
fi

GEMINI_BIN=$(command -v gemini 2>/dev/null || true)
if [ -x "${GEMINI_BIN:-}" ]; then
  VERSION_OUT=$("$GEMINI_BIN" --version 2>&1) || fail "gemini --version failed: $VERSION_OUT"
  note "live gemini version: $VERSION_OUT"
  check_harness gemini fm-lp-gemini-$$ '' '' \
    'How would you like to authenticate for this project|Do you trust the files in this folder|Enter Gemini API Key' '' \
    env GEMINI_CLI_TRUST_WORKSPACE=true GEMINI_API_KEY= "$GEMINI_BIN" -y hello
  pass "gemini: a real launch parked on its own rendered auth or trust dialog surfaces through the watcher gate"
else
  note "gemini not installed - launch-prompt signature not checked"
fi

[ "$CHECKED" -gt 0 ] || fail "no installed harness could be checked; this run verified nothing"
note "checked $CHECKED launch-prompt signature(s) against real installed binaries"
cleanup_all
trap - EXIT
