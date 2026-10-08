#!/usr/bin/env bash
# Credentialed Polytoken worker guard. Opt in with FM_POLYTOKEN_SIGNALS_LIVE=1.
# Drives the real Firstmate verbs end to end in a private tmux server: the
# launch is bin/fm-spawn.sh's generated polytoken command (so a broken launch
# template fails here), the steer is bin/fm-send.sh, the interrupt, relaunch,
# and exit are bin/fm-control.sh, and liveness is the tmux backend's own
# agent-state read. Only worktree allocation uses a fixture (a `treehouse`
# stand-in that enters a prepared worktree). Also proves `polytoken print
# models` discovery, detection from a real tool subprocess, and the hook-driven
# busy open/close on real turns. Runs the cheap zai/glm-5.3-flash model at low
# effort, per the adapter's verification plan.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

fm_live_gate opt-in FM_POLYTOKEN_SIGNALS_LIVE polytoken tmux jq curl git

# shellcheck source=bin/fm-polytoken-lib.sh
. "$ROOT/bin/fm-polytoken-lib.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
# shellcheck source=bin/fm-composer-lib.sh
. "$ROOT/bin/fm-composer-lib.sh"

POLYTOKEN_BIN=$(fm_polytoken_binary 2>/dev/null) || POLYTOKEN_BIN=
[ -n "$POLYTOKEN_BIN" ] || fail "polytoken is not installed"
VERSION=$("$POLYTOKEN_BIN" --version 2>/dev/null || echo unknown)
REAL_TMUX=$(command -v tmux)
SOCKET="fm-polytoken-signals-$$"
ID=ptguard
LAB=

cleanup() {
  local meta sid
  if [ -n "$LAB" ]; then
    meta="$LAB/fm/state/$ID.meta"
    sid=$(awk -F= '$1 == "polytoken_session" { v = substr($0, index($0, "=") + 1) } END { print v }' "$meta" 2>/dev/null)
    if [ -n "$sid" ]; then
      HOME="$LAB/user-home" "$POLYTOKEN_BIN" --config-dir "$LAB/fm/state/$ID.polytoken-config" \
        reap "$sid" --force --sessions-dir "$LAB/fm/state/$ID.polytoken-sessions" >/dev/null 2>&1 || true
    fi
  fi
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -z "$LAB" ] || { chmod -R u+w "$LAB" 2>/dev/null; rm -rf -- "$LAB"; }
}

fail() {
  printf 'not ok - %s: %s\n' "$VERSION" "$1" >&2
  exit 1
}

# Model discovery is part of the verified surface: the guard launches on the
# cheap model's low-effort reference, which a live catalog must still list as
# a selectable form (the exact validation fm-spawn performs at intake).
discovered_ref=$(fm_polytoken_model_ref "$POLYTOKEN_BIN" zai/glm-5.3-flash low 2>/dev/null)
[ "$discovered_ref" = 'zai/glm-5.3-flash(low)' ] \
  || fail "'polytoken print models' no longer lists zai/glm-5.3-flash(low) (got '${discovered_ref:-none}')"
pass "$VERSION: the live model catalog still lists the cheap low-effort reference"

GLOBAL_CFG="${XDG_CONFIG_HOME:-$HOME/.config}/polytoken/config.yaml"
LICENSE_ACCEPT="${XDG_DATA_HOME:-$HOME/.local/share}/polytoken/license-acceptance.json"
[ -f "$GLOBAL_CFG" ] || fail "no global polytoken config at $GLOBAL_CFG to stage for the lab"
# The license acceptance the operator already granted lives in the data home
# keyed by revision. This lab isolates HOME, so the operator's existing record
# is staged as a copy - never extended, and never answered by pressing the
# dialog - because a lab without it would park on exactly the blocker the
# fleet treats as blocked.
[ -f "$LICENSE_ACCEPT" ] \
  || fail "no operator license acceptance at $LICENSE_ACCEPT; the fleet itself would be blocked on the first-start dialog, and the guard refuses to accept anything on the operator's behalf"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-polytoken-signals.XXXXXX") || fail "could not create the isolated polytoken lab"
LAB=$(cd "$LAB" && pwd -P)
trap cleanup EXIT

H="$LAB/fm"
U="$LAB/user-home"
PROJ="$LAB/project"
WT="$LAB/wt"
fm_test_spawn_home "$H" polytoken
fm_git_worktree "$PROJ" "$WT" polytoken-live >/dev/null 2>&1 || fail "could not create the lab worktree"
mkdir -p "$U/.config/polytoken" "$U/.local/share/polytoken" "$LAB/bin"
cp "$GLOBAL_CFG" "$U/.config/polytoken/config.yaml" || fail "could not stage the polytoken config copy"
cp "$LICENSE_ACCEPT" "$U/.local/share/polytoken/license-acceptance.json" \
  || fail "could not stage the operator license acceptance copy"
fm_test_spawn_brief "$H" "$ID" "Runtime verification only: compute 12345 plus 67890 using your shell tool and write only the result into answer.txt. Then use your shell tool to run 'bash $ROOT/bin/fm-harness.sh' and write its output to harness.txt. Do no other work, do not commit, and do not delegate."

# Every backend read and write lands on this guard's private server, and the
# pane's `treehouse get` enters the prepared worktree in a subshell exactly as
# the real tool does.
printf '#!/bin/sh\nexec "%s" -L "%s" "$@"\n' "$REAL_TMUX" "$SOCKET" > "$LAB/bin/tmux"
# shellcheck disable=SC2016 # the single-quoted shim expands its own argument
printf '#!/bin/sh\n[ "${1:-}" = get ] || exit 0\ncd "%s" && exec /bin/bash --noprofile --norc\n' "$WT" > "$LAB/bin/treehouse"
chmod +x "$LAB/bin/tmux" "$LAB/bin/treehouse"
export PATH="$LAB/bin:$PATH" FM_HOME="$H" HOME="$U" XDG_CONFIG_HOME="$U/.config" XDG_DATA_HOME="$U/.local/share"
unset TMUX FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
tmux -f /dev/null new-session -d -s firstmate -n lab -x 160 -y 50 "/bin/bash --noprofile --norc" \
  || fail "could not start the isolated tmux server"
tmux set-option -g default-command "/bin/bash --noprofile --norc" >/dev/null \
  || fail "could not pin the lab shell"

META="$H/state/$ID.meta"
meta_value() { awk -F= -v k="$1" '$1 == k { v = substr($0, index($0, "=") + 1) } END { print v }' "$META"; }
record() { fm_busy_record_read "$H/state" "$ID" 2>/dev/null || true; }
wait_file() {
  local path=$1 i
  for i in $(seq 1 480); do [ -s "$path" ] && return 0; sleep 0.5; done
  fail "timed out waiting for ${path##*/}"
}
wait_record() {  # <prefix> <what>
  local i
  for i in $(seq 1 240); do
    case "$(record)" in "$1"*) return 0 ;; esac
    sleep 0.5
  done
  fail "$2 (last record '$(record)')"
}

# The launch is fm-spawn's own generated command; its readiness gate already
# requires the session to surface in `polytoken sessions` and a hook-written
# busy record before the spawn reports success.
FM_SPAWN_NO_GUARD=1 "$ROOT/bin/fm-spawn.sh" "$ID" "$PROJ" --scout --harness polytoken \
  --model zai/glm-5.3-flash --effort low > "$LAB/spawn.log" 2>&1 \
  || fail "fm-spawn's generated polytoken launch failed: $(cat "$LAB/spawn.log")"
TARGET=$(meta_value window)
SESSION1=$(meta_value polytoken_session)
[ -n "$TARGET" ] || fail "the spawn recorded no endpoint"
[ -n "$SESSION1" ] && [ -n "$(meta_value polytoken_port)" ] && [ -n "$(meta_value polytoken_credential)" ] \
  || fail "the spawn did not bind the session id, port, and credential into task metadata"
capture() { tmux capture-pane -p -t "$TARGET" -S -200 2>/dev/null || true; }
[ "$(fm_backend_agent_state tmux "$TARGET")" = alive ] \
  || fail "the tmux backend does not classify the spawned polytoken worker alive"
screen=$(capture)
case "$screen" in *firstmate-worker*) ;; *) fail "the spawned pane never showed the generated worker facet" ;; esac
case "$screen" in *"perms: bypass"*) ;; *) fail "the spawned pane never rendered the enforced bypass posture" ;; esac
pass "$VERSION: fm-spawn's generated launch starts a bound, alive worker on the generated config and facet"

wait_file "$WT/answer.txt"
wait_file "$WT/harness.txt"
[ "$(tr -d '[:space:]' < "$WT/answer.txt")" = 80235 ] || fail "the launch brief did not execute"
[ "$(tr -d '[:space:]' < "$WT/harness.txt")" = polytoken ] \
  || fail "fm-harness.sh did not detect polytoken from a real tool subprocess (got '$(cat "$WT/harness.txt")')"
pass "$VERSION: the brief ran and fm-harness.sh detects polytoken from a real tool subprocess"
wait_record "idle polytoken-hook " "the finished brief turn never closed the busy record through the stop hook"
[ -f "$H/state/$ID.turn-ended" ] || fail "the stop hook never touched the turn-ended marker"
pass "$VERSION: the stop hook closes the busy record and touches the turn-ended marker"

"$ROOT/bin/fm-send.sh" "$ID" 'Runtime interrupt verification: run sleep 90 in your shell tool and wait for it to finish. Do not respond before it finishes.' \
  > "$LAB/send.log" 2>&1 || fail "fm-send could not steer the worker: $(cat "$LAB/send.log")"
wait_record "busy polytoken-hook " "the steered turn never opened the busy record through the generated hook"
busy_row=
for _ in $(seq 1 120); do
  if capture | fm_busy_lines_match polytoken; then busy_row=1; break; fi
  sleep 0.5
done
[ -n "$busy_row" ] || fail "the running turn never rendered the pinned busy row"
pass "$VERSION: fm-send steers a real turn that opens the busy record and renders the busy row"

"$ROOT/bin/fm-control.sh" "$ID" interrupt > "$LAB/interrupt.log" 2>&1 \
  || fail "fm-control interrupt failed: $(cat "$LAB/interrupt.log")"
grep -q 'cancel=cancelled' "$LAB/interrupt.log" \
  || fail "fm-control interrupt did not report a settled cancel: $(cat "$LAB/interrupt.log")"
case "$(record)" in "idle "*) ;; *) fail "the interrupt did not close the busy record (got '$(record)')" ;; esac
canceled_row=
for _ in $(seq 1 60); do
  case "$(capture)" in *"Canceled after"*) canceled_row=1; break ;; esac
  sleep 0.5
done
[ -n "$canceled_row" ] || fail "the cancelled turn never rendered its Canceled row"
[ "$(fm_backend_agent_state tmux "$TARGET")" = alive ] || fail "the interrupt did not leave the worker alive"
pass "$VERSION: fm-control interrupt cancels the real turn over REST and leaves the worker alive"

"$ROOT/bin/fm-control.sh" "$ID" relaunch \
  --note 'Runtime relaunch verification: compute 17 times 29 with your shell tool and write only the result to relaunched.txt. Do no other work.' \
  > "$LAB/relaunch.log" 2>&1 || fail "fm-control relaunch failed: $(cat "$LAB/relaunch.log")"
SESSION2=$(meta_value polytoken_session)
[ -n "$SESSION2" ] && [ "$SESSION2" != "$SESSION1" ] \
  || fail "the relaunch did not bind a fresh polytoken session (was '$SESSION1', now '${SESSION2:-none}')"
[ "$(fm_backend_agent_state tmux "$TARGET")" = alive ] \
  || fail "the tmux backend does not classify the relaunched worker alive"
wait_file "$WT/relaunched.txt"
[ "$(tr -d '[:space:]' < "$WT/relaunched.txt")" = 493 ] || fail "the relaunched worker did not act on its note"
pass "$VERSION: fm-control relaunch replaces the worker through the generated launch and rebinds its session"

wait_record "idle polytoken-hook " "the relaunched worker's turn never closed the busy record"
"$ROOT/bin/fm-control.sh" "$ID" exit > "$LAB/exit.log" 2>&1 \
  || fail "fm-control exit failed: $(cat "$LAB/exit.log")"
[ "$(fm_backend_agent_state tmux "$TARGET")" = dead ] \
  || fail "the tmux backend does not classify the exited worker dead"
pass "$VERSION: fm-control exit stops the real worker and the backend reads it dead"
