#!/usr/bin/env bash
# Live drift guard for the Polytoken CLI adapter's vendor-controlled surface:
# process identity, the generated worker config and facet, the hook-driven busy
# contract on a real turn, the rendered busy row, the REST interrupt, and the
# /quit exit.
# Opt-in because it submits real prompts on a real provider credential (the
# cheap zai/glm-5.3-flash model, per the adapter's verification plan).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REAL_TMUX=$(command -v tmux 2>/dev/null || true)
LAB=
SOCKET="fm-polytoken-signals-$$"
SESSION=polytoken-signals
TARGET="$SESSION:worker"

cleanup() {
  if [ -n "$LAB" ] && [ -n "${POLYTOKEN_BIN:-}" ] && [ -n "${POLYTOKEN_SESSION_ID:-}" ]; then
    "$POLYTOKEN_BIN" --config-dir "$LAB/state/ptguard.polytoken-config" \
      reap "$POLYTOKEN_SESSION_ID" --force \
      --sessions-dir "$LAB/state/ptguard.polytoken-sessions" >/dev/null 2>&1 || true
  fi
  [ -n "$REAL_TMUX" ] && "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -z "$LAB" ] || rm -rf -- "$LAB"
}

fail() {
  printf 'not ok - %s\n' "$1" >&2
  cleanup
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

fm_live_gate opt-in FM_POLYTOKEN_SIGNALS_LIVE polytoken tmux

# shellcheck source=/dev/null
. "$ROOT/bin/fm-polytoken-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-composer-lib.sh"

POLYTOKEN_BIN=$(fm_polytoken_binary 2>/dev/null) || POLYTOKEN_BIN=
[ -n "$POLYTOKEN_BIN" ] || fail "polytoken is not installed"
POLYTOKEN_VERSION=$("$POLYTOKEN_BIN" --version 2>/dev/null || echo unknown)

# Model discovery is part of the verified surface: the guard launches on the
# cheap model's low-effort reference, which a live catalog must still list as
# a selectable form (the exact validation fm-spawn performs at intake).
discovered_ref=$(fm_polytoken_model_ref "$POLYTOKEN_BIN" zai/glm-5.3-flash low 2>/dev/null)
[ "$discovered_ref" = 'zai/glm-5.3-flash(low)' ] \
  || fail "$POLYTOKEN_VERSION: 'polytoken print models' no longer lists zai/glm-5.3-flash(low) (got '${discovered_ref:-none}')"
pass "$POLYTOKEN_VERSION: the live model catalog still lists the cheap low-effort reference"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-polytoken-signals.XXXXXX") || fail "could not create the isolated polytoken lab"
trap cleanup EXIT

# The worker runs under a throwaway HOME whose XDG config stages a copy of the
# operator's global polytoken config, so every write the daemon or TUI makes -
# session trees, logs, even a TUI crash log - lands inside the lab, never the
# operator's real store, and the config mirror's source is the staged copy.
mkdir -p "$LAB/home/.config" "$LAB/workspace" "$LAB/state" "$LAB/logs" \
  || fail "could not shape the isolated polytoken lab"
GLOBAL_CFG="${XDG_CONFIG_HOME:-$HOME/.config}/polytoken/config.yaml"
[ -f "$GLOBAL_CFG" ] || fail "no global polytoken config at $GLOBAL_CFG to stage for the lab"
mkdir -p "$LAB/home/.config/polytoken"
cp "$GLOBAL_CFG" "$LAB/home/.config/polytoken/config.yaml" \
  || fail "could not stage the polytoken config copy"
# The license acceptance the operator already granted lives in the data home
# keyed by revision (~/.local/share/polytoken/license-acceptance.json, found
# live during this verification). A fleet launch reads it through the
# operator's real HOME, so it never auto-accepts anything; this lab isolates
# HOME, so the operator's existing record is staged as a copy - never
# extended, and never answered by pressing the dialog - because a lab without
# it would park on exactly the blocker the fleet treats as blocked.
LICENSE_ACCEPT="${XDG_DATA_HOME:-$HOME/.local/share}/polytoken/license-acceptance.json"
[ -f "$LICENSE_ACCEPT" ] \
  || fail "no operator license acceptance at $LICENSE_ACCEPT; the fleet itself would be blocked on the first-start dialog, and the guard refuses to accept anything on the operator's behalf"
mkdir -p "$LAB/home/.local/share/polytoken"
cp "$LICENSE_ACCEPT" "$LAB/home/.local/share/polytoken/license-acceptance.json" \
  || fail "could not stage the operator license acceptance copy"
WORKSPACE=$(cd "$LAB/workspace" && pwd -P) || fail "could not resolve the lab workspace"
STATE_REAL=$(cd "$LAB/state" && pwd -P) || fail "could not resolve the lab state"

# The real generated worker wiring, exactly as fm-spawn arms it: the busy
# contract, the config dir (mirrored operator config with the unattended
# posture enforced), the worker facet, the no-argv busy writer, and the
# worktree hook layer binding the three verified events.
ID=ptguard
GEN=$("$ROOT/bin/fm-busy-event.sh" arm "$STATE_REAL" "$ID" 2>/dev/null) \
  || fail "could not arm the busy contract in the lab"
XDG_CONFIG_HOME="$LAB/home/.config" HOME="$LAB/home" \
  fm_polytoken_write_config "$(fm_polytoken_config_dir "$STATE_REAL" "$ID")" \
  || fail "could not generate the worker config dir"
fm_polytoken_write_facet "$WORKSPACE" "$STATE_REAL/$ID.inbox" \
  || fail "could not generate the worker facet"
fm_polytoken_write_busy_script "$ROOT" "$STATE_REAL" "$ID" "$GEN" "$STATE_REAL/$ID.turn-ended" \
  || fail "could not generate the busy writer"
fm_polytoken_write_hooks "$WORKSPACE" "$(fm_polytoken_busy_script "$STATE_REAL" "$ID")" \
  || fail "could not generate the worktree hook layer"
CFG_DIR=$(fm_polytoken_config_dir "$STATE_REAL" "$ID")
SESSIONS_ROOT=$(fm_polytoken_sessions_root "$STATE_REAL" "$ID")
POLYTOKEN_SESSION_ID=

"$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -n worker -c "$WORKSPACE" \
  || fail "could not start the isolated tmux server"

capture() {
  "$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$TARGET" -S -100 2>/dev/null || true
}

type_line() {
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l "$1" \
    || fail "could not type into the polytoken pane"
}

press_enter() {
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter \
    || fail "could not send Enter to the polytoken pane"
}

# The launch prompt asks for a computed answer (12345+67890=80235) so the
# awaited token never appears in the echoed launch line itself. The model
# reference is single-quoted exactly as the spawn's model flag builder emits
# it, because the parenthesized effort form is shell syntax when unquoted.
type_line "HOME=\"$LAB/home\" XDG_CONFIG_HOME=\"$LAB/home/.config\" $POLYTOKEN_BIN --config-dir \"$CFG_DIR\" new --facet firstmate-worker --facets-dir \"$WORKSPACE/.polytoken/facets\" --sessions-dir \"$SESSIONS_ROOT\" --log-dir \"$LAB/logs\" --model 'zai/glm-5.3-flash(low)' --prompt \"Add 12345 and 67890. Reply with exactly the sum and nothing else\""
press_enter

# The footer and switch banner are the live proof the generated config and
# facet took effect: the enforced bypass posture renders in the footer (both
# the early full form and the compressed settled form), and the worker facet
# renders in the early footer's facet field and in the "Facet switched" banner
# that stays in the scrollback, so the guard accepts either surface for it.
facet_seen=
bypass_seen=
for _ in $(seq 1 120); do
  screen=$(capture)
  case "$screen" in
    *"perms: bypass"*) bypass_seen=1 ;;
  esac
  case "$screen" in
    *firstmate-worker*) facet_seen=1 ;;
  esac
  if [ -n "$facet_seen" ] && [ -n "$bypass_seen" ]; then
    break
  fi
  sleep 0.5
done
[ -n "$bypass_seen" ] \
  || fail "$POLYTOKEN_VERSION: the real pane never rendered the enforced bypass posture in its footer"
[ -n "$facet_seen" ] \
  || fail "$POLYTOKEN_VERSION: the real pane never showed the worker facet"
pass "$POLYTOKEN_VERSION: the generated config and facet carry the real worker pane"

# The busy contract opens on the real brief turn: pre_user_prompt fires the
# moment the auto-submitted prompt is accepted, so even a fast model leaves a
# catchable busy record.
busy_opened=
for _ in $(seq 1 120); do
  record=$(fm_busy_record_read "$STATE_REAL" "$ID" 2>/dev/null) || record=
  case "$record" in
    "busy polytoken-hook "*) busy_opened=1; break ;;
  esac
  sleep 0.5
done
[ -n "$busy_opened" ] \
  || fail "$POLYTOKEN_VERSION: the real turn never opened the busy record through the generated hook"
pass "$POLYTOKEN_VERSION: the generated hook opens the busy record on a real turn"

reply=
for _ in $(seq 1 240); do
  screen=$(capture)
  case "$screen" in
    *80235*|*80,235*) reply=1; break ;;
  esac
  sleep 0.5
done
[ -n "$reply" ] || fail "$POLYTOKEN_VERSION: the real worker never answered its launch prompt"
pass "$POLYTOKEN_VERSION: the real worker processed its launch prompt"

# The turn end closes the record through the stop hook, which is the pair's
# other half on a real pane.
idle_closed=
for _ in $(seq 1 120); do
  record=$(fm_busy_record_read "$STATE_REAL" "$ID" 2>/dev/null) || record=
  case "$record" in
    "idle polytoken-hook "*) idle_closed=1; break ;;
  esac
  sleep 0.5
done
[ -n "$idle_closed" ] \
  || fail "$POLYTOKEN_VERSION: the finished turn never closed the busy record through the stop hook"
pass "$POLYTOKEN_VERSION: the stop hook closes the busy record on turn end"
[ -f "$STATE_REAL/$ID.turn-ended" ] \
  || fail "$POLYTOKEN_VERSION: the stop hook never touched the turn-ended notification marker"
pass "$POLYTOKEN_VERSION: the stop hook touches the turn-ended marker"

# Detection from a real tool subprocess: the worker's own shell tool runs the
# real detector, whose ancestry walk must name polytoken from inside the
# session it is working for.
type_line "Use your shell tool to run the command: bash $ROOT/bin/fm-harness.sh - exit code and output only, no other text."
press_enter
detected=
for _ in $(seq 1 240); do
  screen=$(capture)
  case "$screen" in
    *polytoken*) detected=1; break ;;
  esac
  sleep 0.5
done
[ -n "$detected" ] \
  || fail "$POLYTOKEN_VERSION: fm-harness.sh never detected polytoken from inside a real tool subprocess"
pass "$POLYTOKEN_VERSION: fm-harness.sh detects polytoken from a real tool subprocess"

# A genuinely long turn proves the rendered busy row and the REST interrupt:
# the row must match the pinned delivery signature while in flight, and the
# cancel must settle the turn with its typed acknowledgement. No interrupt key
# exists, so nothing but the REST verb is ever sent.
type_line "Write a 1500-word essay on the history of glass"
press_enter
busy_row=
for _ in $(seq 1 120); do
  screen=$(capture)
  if printf '%s' "$screen" | fm_busy_lines_match polytoken; then busy_row=1; break; fi
  sleep 0.5
done
[ -n "$busy_row" ] \
  || fail "$POLYTOKEN_VERSION: the real long turn never rendered the Running-for busy row"
pass "$POLYTOKEN_VERSION: the real busy row matches the pinned delivery signature"

discovered=
for _ in $(seq 1 40); do
  found=$(fm_polytoken_session_for_project "$POLYTOKEN_BIN" "$CFG_DIR" "$SESSIONS_ROOT" "$WORKSPACE" 2>/dev/null) || found=
  if [ -n "$found" ]; then
    IFS=$'\t' read -r POLYTOKEN_SESSION_ID POLYTOKEN_PORT POLYTOKEN_CREDENTIAL _ <<EOF
$found
EOF
    discovered=1
    break
  fi
  sleep 0.5
done
[ -n "$discovered" ] \
  || fail "$POLYTOKEN_VERSION: the live session never surfaced through sessions --format json"
token=$(fm_polytoken_credential_token "$POLYTOKEN_CREDENTIAL" 2>/dev/null) || token=
[ -n "$token" ] || fail "$POLYTOKEN_VERSION: the live session credential could not be read"
cancel=$(fm_polytoken_interrupt "$POLYTOKEN_PORT" "$token" 15 2>/dev/null)
[ "$cancel" = cancelled ] \
  || fail "$POLYTOKEN_VERSION: the REST interrupt never settled the running turn (got '${cancel:-none}')"
pass "$POLYTOKEN_VERSION: the REST interrupt cancels and settles a real turn"
canceled_row=
for _ in $(seq 1 60); do
  screen=$(capture)
  case "$screen" in
    *"Canceled after"*) canceled_row=1; break ;;
  esac
  sleep 0.5
done
[ -n "$canceled_row" ] \
  || fail "$POLYTOKEN_VERSION: the cancelled turn never rendered its Canceled row"
pass "$POLYTOKEN_VERSION: the cancelled turn renders its Canceled row"

# The exit is the /quit keyplane: the palette accepts the preselected row, the
# TUI exits, and the pane falls back to its shell.
type_line "/quit"
press_enter
gone=
for _ in $(seq 1 120); do
  current=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$TARGET" '#{pane_current_command}' 2>/dev/null || true)
  case "$current" in
    *polytoken*) sleep 0.5 ;;
    *) gone=1; break ;;
  esac
done
[ -n "$gone" ] || fail "$POLYTOKEN_VERSION: /quit never stopped the real polytoken TUI"
pass "$POLYTOKEN_VERSION: /quit stops the real polytoken TUI"

cleanup
trap - EXIT
