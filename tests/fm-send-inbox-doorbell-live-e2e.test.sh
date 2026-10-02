#!/usr/bin/env bash
# tests/fm-send-inbox-doorbell-live-e2e.test.sh - the live doorbell guard
# (live-harness-optin family).
#
# The steering inbox's one behavioral assumption is that a real worker agent
# follows the constant self-describing doorbell line: list the inbox, read and
# act on its records in numeric order, then mv each into handled/. A stub can
# only confirm the assumption already
# written into the stub, so per .agents/skills/firstmate-coding-guidelines
# this is proven against every INSTALLED verified harness: each is launched
# idle in an isolated Herdr lab, steered through the REAL fm-send (durable
# record + doorbell), and must both ACT on the instruction (create a named
# file) and ACKNOWLEDGE it (the mv into handled/), failing loudly with the
# harness name and version.
#
# Run explicitly with FM_SEND_INBOX_LIVE_E2E=1. This test spends a small
# number of real model tokens per installed harness (one short turn each) -
# authorized by the harness-dependent-checks rule. An absent harness is
# reported explicitly and skipped; a run that verified nothing fails rather
# than passing vacuously. Restrict with
# FM_SEND_INBOX_LIVE_HARNESSES="codex traex" when needed, and tune the
# per-harness wait with FM_SEND_INBOX_LIVE_TIMEOUT (seconds, default 240).
# Record the dated per-harness result in
# docs/verification/runtime-backends.md ("Steering-inbox doorbell").
#
# Codex and TraeX use disposable authenticated homes with no shared daemon or
# hooks. Ordinary delivery is one native Herdr prompt, so the guard does not
# suspend a TUI, inspect its transcript, or send a recovery Enter.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fm_live_gate opt-in FM_SEND_INBOX_LIVE_E2E herdr jq

unset NO_MISTAKES_GATE

# shellcheck source=tests/herdr-test-safety.sh
. "$(dirname "${BASH_SOURCE[0]}")/herdr-test-safety.sh"
herdr_forget_inherited_pane
HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
CLEAN_PATH=$PATH
SESSION=$("$HELPER" name "${FM_HERDR_LAB_TASK:-inbox-doorbell}") || exit 1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-inbox-live.XXXXXX")
TIMEOUT=${FM_SEND_INBOX_LIVE_TIMEOUT:-240}
CHECKED=0
FAILED=0
pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }
cleanup() {
  PATH="$CLEAN_PATH" "$HELPER" teardown "$SESSION" || exit 1
  rm -rf "$LAB"
}
trap cleanup EXIT
"$HELPER" provision "$SESSION" || exit 1
herdr_test_guard_cli "$SESSION" "$LAB/shim" "$HELPER" || exit 1
export PATH="$LAB/shim:$PATH" HERDR_SESSION="$SESSION"
# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
# shellcheck source=bin/fm-task-inbox-lib.sh
. "$ROOT/bin/fm-task-inbox-lib.sh"
fm_backend_source herdr || fail 'could not load Herdr'
CONTAINER_RAW=$(fm_backend_herdr_container_ensure "$ROOT") || fail 'lab container failed'
CONTAINER=${CONTAINER_RAW%%$'\t'*}

harness_version() {  # <binary>
  "$1" --version 2>/dev/null | head -1 || printf 'version-unknown'
}

# Launch <name> idle with its unattended-autonomy flags (the same posture
# bin/fm-spawn.sh uses), so the doorbell-triggered shell actions need no
# interactive approval.
launch_cmd() {  # <name> <home> <play>
  case "$1" in
    codex)
      printf 'env CODEX_HOME=%q codex --no-daemon --dangerously-bypass-approvals-and-sandbox -c features.hooks=false -C %q' "$2/codex-home" "$3" ;;
    traex)
      printf 'env TRAE_HOME=%q FM_TRAEX_HARNESS=traex traex -y --model Seed-Evolving -c model_reasoning_effort="high"' "$2/trae-home" ;;
    pi) printf '%s' "$1" ;;
    *) return 1 ;;
  esac
}

# Wait for the lab harness to look steerable before the measurement.
# This fixture-only readiness observation is not a production send gate; the
# native prompt path itself does not read the composer.
wait_ready() {  # <window>
  local win=$1 i=0 budget=60 verdict dismissed=0 screen
  while [ "$i" -lt "$budget" ]; do
    verdict=$(fm_backend_composer_state herdr "$SESSION:$win")
    [ "$verdict" = empty ] && return 0
    i=$((i + 1))
    # Dismiss one non-trust startup modal (update prompts), as the composer
    # matrix guard does; never Enter, which could accept an upgrade.
    if [ "$dismissed" -eq 0 ] && [ "$i" -ge $((budget / 3)) ]; then
      screen=$(fm_backend_capture herdr "$SESSION:$win" 2>/dev/null || true)
      if ! printf '%s\n' "$screen" | grep -qi 'trust'; then
        fm_backend_send_key herdr "$SESSION:$win" Escape 2>/dev/null || true
      fi
      dismissed=1
    fi
    sleep 1
  done
  case "$verdict" in
    pending) return 1 ;;
  esac
  return 2
}

check_harness_doorbell() {  # <name>
  local name=$1 version cmd win home task acted rec handled i ready_rc ids tab workspace play body
  version=$(harness_version "$name")
  home="$LAB/$name-home"
  play="$home/play"
  mkdir -p "$home/state" "$play"
  git -C "$home" init -q -b main || { FAILED=1; return 0; }
  printf '%s\n' 'You are an isolated input fixture. Only act on the harmless local inbox, then move its messages into handled/. Never inspect production, supervise, or delegate.' > "$play/AGENTS.md"
  if [ "$name" = codex ]; then
    mkdir -p "$home/codex-home"
    if [ ! -f "${CODEX_HOME:-$HOME/.codex}/auth.json" ]; then
      FAILED=1; printf 'not ok - codex (%s): local authentication unavailable\n' "$version" >&2; return 0
    fi
    cp "${CODEX_HOME:-$HOME/.codex}/auth.json" "$home/codex-home/auth.json"
    chmod 600 "$home/codex-home/auth.json"
    printf 'model = "gpt-6.1-sol"\nmodel_reasoning_effort = "high"\n[projects."%s"]\ntrust_level = "trusted"\n' "$play" > "$home/codex-home/config.toml"
  elif [ "$name" = traex ]; then
    mkdir -p "$home/trae-home/cli"
    if [ ! -f "${TRAE_HOME:-$HOME/.trae}/cli/auth.json" ]; then
      FAILED=1; printf 'not ok - traex (%s): local authentication unavailable\n' "$version" >&2; return 0
    fi
    cp "${TRAE_HOME:-$HOME/.trae}/cli/auth.json" "$home/trae-home/cli/auth.json"
    chmod 600 "$home/trae-home/cli/auth.json"
  fi
  cmd=$(launch_cmd "$name" "$home" "$play") || { note "no launch recipe for $name"; return 0; }
  task="live-$name"
  acted="$LAB/acted-$name"
  ids=$(fm_backend_herdr_create_task "$CONTAINER" "fm-$task" "$play") || { FAILED=1; return 0; }
  read -r tab win <<< "$ids"
  workspace=${win%%:*}
  fm_backend_herdr_send_text_line "$SESSION:$win" "exec $cmd" \
    || { FAILED=1; printf 'not ok - %s (%s): launch failed\n' "$name" "$version" >&2; return 0; }
  if [ "$name" = traex ]; then
    i=0
    while [ "$i" -lt 60 ]; do
      screen=$(fm_backend_capture herdr "$SESSION:$win" 40 2>/dev/null || true)
      case "$screen" in
        *'Trusting the directory'*'Yes, continue'*'No, quit'*) break ;;
      esac
      sleep 0.5
      i=$((i + 1))
    done
    case "$screen" in
      *'Trusting the directory'*'Yes, continue'*'No, quit'*)
        fm_backend_send_key herdr "$SESSION:$win" Enter \
          || { FAILED=1; printf 'not ok - %s (%s): verified trust acceptance failed\n' "$name" "$version" >&2; return 0; }
        ;;
      *)
        FAILED=1; printf 'not ok - %s (%s): exact trust chooser was not observed\n' "$name" "$version" >&2; return 0 ;;
    esac
  fi
  wait_ready "$win"; ready_rc=$?
  if [ "$ready_rc" -eq 1 ]; then
    FAILED=1
    printf 'not ok - %s (%s): composer stayed visibly pending; the pane is not steerable\n' "$name" "$version" >&2
    fm_backend_capture herdr "$SESSION:$win" 2>/dev/null | grep '[^[:space:]]' | tail -6 | sed 's/^/#   /' >&2
    fm_backend_kill herdr "$SESSION:$win" 2>/dev/null || true
    return 0
  fi
  [ "$ready_rc" -eq 0 ] || note "$name ($version): idle composer never classified empty; proceeding as production does (advisory check skips only on pending)"
  printf 'window=%s:%s\nkind=ship\nharness=%s\nbackend=herdr\nendpoint_task_id=%s\nherdr_session=%s\nherdr_workspace_id=%s\nherdr_tab_id=%s\nherdr_pane_id=%s\nworktree=%s\nproject=%s\n' \
    "$SESSION" "$win" "$name" "$task" "$SESSION" "$workspace" "$tab" "$win" "$play" "$play" > "$home/state/$task.meta"
  body="Firstmate live check: run exactly this shell command now: touch $acted - then follow the mv instruction you were given for this message. Reply with one short line."
  if ! FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$ROOT/bin/fm-send.sh" "$task" "$body" >/dev/null 2>&1; then
    FAILED=1
    printf 'not ok - %s (%s): fm-send refused the live steer\n' "$name" "$version" >&2
    fm_backend_kill herdr "$SESSION:$win" 2>/dev/null || true
    return 0
  fi
  rec="$home/state/$task.inbox/001.msg"
  handled="$home/state/$task.inbox/handled/001.msg"
  [ -f "$rec" ] || {
    FAILED=1
    printf 'not ok - %s (%s): fm-send left no durable inbox record\n' "$name" "$version" >&2
    fm_backend_kill herdr "$SESSION:$win" 2>/dev/null || true
    return 0
  }
  i=0
  while [ "$i" -lt "$TIMEOUT" ]; do
    [ -f "$handled" ] && [ -e "$acted" ] && break
    # Halfway through, play the watcher's role once: re-ring an unacknowledged
    # message so a doorbell swallowed by a startup or update modal recovers
    # exactly as the production re-ring ladder recovers it.
    if [ "$name" != codex ] && [ "$i" -eq $((TIMEOUT / 2)) ] && [ -f "$rec" ]; then
      fm_task_inbox_ring herdr "$SESSION:$win" "$rec" || true
      note "$name ($version): re-rang the doorbell once (watcher's role) at ${i}s"
    fi
    sleep 1
    i=$((i + 1))
  done
  if [ -f "$handled" ] && [ -e "$acted" ]; then
    CHECKED=$((CHECKED + 1))
    pass "$name ($version): the doorbell reached a real worker, which acted and acked with the mv"
    pass "$name ($version): native prompt submission required no transcript receipt or recovery Enter"
  else
    FAILED=1
    printf 'not ok - %s (%s): doorbell not honored within %ss (acted=%s acked=%s)\n' \
      "$name" "$version" "$TIMEOUT" "$([ -e "$acted" ] && echo yes || echo no)" \
      "$([ -f "$handled" ] && echo yes || echo no)" >&2
    fm_backend_capture herdr "$SESSION:$win" 2>/dev/null | grep '[^[:space:]]' | tail -10 | sed 's/^/#   /' >&2
  fi
  fm_backend_kill herdr "$SESSION:$win" 2>/dev/null || true
}

HARNESSES=${FM_SEND_INBOX_LIVE_HARNESSES:-'codex traex'}
for h in $HARNESSES; do
  if command -v "$h" >/dev/null 2>&1; then
    check_harness_doorbell "$h"
  else
    note "harness absent, not verified here: $h"
  fi
done

if [ "$FAILED" -ne 0 ]; then
  printf 'not ok - live steering-inbox doorbell guard found failures above\n' >&2
  exit 1
fi
if [ "$CHECKED" -eq 0 ]; then
  printf 'not ok - live steering-inbox doorbell guard verified nothing (no harness installed?)\n' >&2
  exit 1
fi
pass "live steering-inbox doorbell guard: $CHECKED harness(es) honored the doorbell contract"
