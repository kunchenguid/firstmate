#!/usr/bin/env bash
# tests/fm-busy-signature-drift-live-e2e.test.sh - opt-in drift guard proving the
# delivery-only rendered busy signatures in bin/fm-tmux-lib.sh still separate a
# real idle pane from a real active turn, for every INSTALLED harness.
#
# Why this file exists: the rendered busy verdict comes from footer and spinner
# text the harness vendor controls and changes without notice, and both
# directions of drift are damaging. A signature that stops matching an active
# turn lets firstmate inject into a live turn; a signature that starts matching
# an idle pane defers delivery forever, which is the away-mode wedge. Claude Code
# has already moved this surface twice: 2.1.221 rendered `esc to interrupt` while
# idle, and by 2.1.223 the elapsed spinner row was only intermittently rendered
# while that same affordance was present for the whole turn. A table transcribed
# from a previous release cannot see either move, and neither can a stubbed pane.
#
# Unlike the liveness drift guard, proving the BUSY half requires a real turn, so
# this guard does spend a small number of model tokens per installed harness. The
# prompt is deliberately tiny. The idle half spends none.
#
# Standard CI has no harness binaries or credentials, so this real-harness guard
# is opt-in and on-demand. The portable counterpart in
# tests/fm-tmux-submit-busy.test.sh pins the classifier logic in CI. Run this
# guard after any harness upgrade and before trusting refreshed evidence in
# docs/verification/runtime-backends.md.
set -u

if [ "${FM_BUSY_SIGNATURE_DRIFT:-0}" != 1 ]; then
  echo "skip: set FM_BUSY_SIGNATURE_DRIFT=1 to run the installed-harness busy signature drift guard"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

command -v tmux >/dev/null 2>&1 || fail "tmux not found"
REAL_TMUX=$(command -v tmux)
SOCKET="fm-busy-drift-$$"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-busy-drift.XXXXXX")
SESSION=busydrift

cleanup_all() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -n "${LAB:-}" ] && rm -rf "$LAB"
}
trap cleanup_all EXIT

mkdir -p "$LAB/wt"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-tmux-lib.sh"

"$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -n control -c "$LAB/wt" \
  || fail "could not start the private tmux server"

# Mirror bin/fm-spawn.sh's own resolution order so this guard covers the same
# binary firstmate would actually launch.
resolve_harness_binary() {  # <harness>
  local harness=$1 candidate
  candidate=$(command -v "$harness" 2>/dev/null || true)
  if [ -n "$candidate" ] && [ -x "$candidate" ]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  if [ "$harness" = kimi ] && [ -n "${HOME:-}" ] && [ -x "$HOME/.kimi-code/bin/kimi" ]; then
    printf '%s\n' "$HOME/.kimi-code/bin/kimi"
    return 0
  fi
  return 1
}

capture_tail() {  # <target>
  "$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$1" 2>/dev/null \
    | grep -v '^[[:space:]]*$' | tail -12
}

rendered_busy() {  # <target> <harness>
  capture_tail "$1" | fm_busy_lines_match "$2"
}

CHECKED=0
SKIPPED=
UNVERIFIED=

# A harness this guard cannot drive to a real turn proves nothing about its
# signature, in either direction. Record it loudly and move on: masking it as a
# pass would be dishonest, and failing the whole run on it would hide the
# harnesses that CAN be verified. Genuine signature drift still fails hard.
undrivable() {  # <harness> <version> <why>
  UNVERIFIED="$UNVERIFIED $1"
  note "UNVERIFIED: $1 ($2) could not be driven to a real turn ($3), so its active-turn signature is unproven here. This is a harness-driving limitation, NOT evidence of signature drift."
}

for harness in claude codex opencode pi pi-signed grok kimi; do
  if ! bin_path=$(resolve_harness_binary "$harness"); then
    SKIPPED="$SKIPPED $harness"
    note "skip: $harness is not installed on this machine, so its busy signature is unverified here"
    continue
  fi

  version=$("$bin_path" --version 2>/dev/null | head -1 | tr -d '\r') || version=
  [ -n "$version" ] || version="unknown"

  target="$SESSION:$harness"
  "$REAL_TMUX" -L "$SOCKET" new-window -d -t "$SESSION:" -n "$harness" -c "$LAB/wt" -- "$bin_path" \
    || fail "$harness ($version): could not launch a window for the busy signature probe"

  # Settle, answering a first-run workspace-trust prompt if one appears. The
  # lab directory is a throwaway created by this guard.
  settled=0
  for _ in $(seq 1 150); do
    tail=$(capture_tail "$target")
    case "$tail" in
      *'trust this folder'*|*'Do you trust'*)
        "$REAL_TMUX" -L "$SOCKET" send-keys -t "$target" Enter
        ;;
    esac
    if printf '%s' "$tail" | grep -qE '❯|>|Type a message|for agents|bypass permissions'; then
      settled=1
      break
    fi
    sleep 0.2
  done
  if [ "$settled" != 1 ]; then
    undrivable "$harness" "$version" "the pane never presented a composer"
    continue
  fi

  # --- idle half: a settled pane with no turn running must NOT read busy -------
  if rendered_busy "$target" "$harness"; then
    fail "BUSY SIGNATURE DRIFT (idle): $harness $version renders a settled, idle pane as BUSY. Delivery to this harness will defer forever, which is the away-mode wedge. Observed tail:
$(capture_tail "$target")
Narrow this harness's signature in bin/fm-tmux-lib.sh so the idle footer no longer matches."
  fi
  note "$harness $version: idle tail classifies idle"

  # --- busy half: a real turn must read busy ----------------------------------
  # Type the prompt and CONFIRM it reached the composer before submitting.
  # Without that confirmation a prompt that never landed looks exactly like a
  # signature that never matched, and this guard would report a false drift.
  PROMPT='Count from 1 to 40, one number per line, no commentary.'
  typed=0
  for _ in 1 2 3; do
    "$REAL_TMUX" -L "$SOCKET" send-keys -t "$target" "$PROMPT"
    for _ in $(seq 1 16); do
      if capture_tail "$target" | grep -qF 'Count from 1 to 40'; then
        typed=1
        break
      fi
      sleep 0.5
    done
    [ "$typed" = 1 ] && break
  done
  if [ "$typed" != 1 ]; then
    undrivable "$harness" "$version" "the probe prompt never reached the composer"
    continue
  fi

  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$target" Enter

  # A turn is under way once the composer has given the prompt back up.
  submitted=0
  for _ in $(seq 1 50); do
    capture_tail "$target" | grep -qF 'Count from 1 to 40' || { submitted=1; break; }
    rendered_busy "$target" "$harness" && { submitted=1; break; }
    sleep 0.2
  done
  if [ "$submitted" != 1 ]; then
    undrivable "$harness" "$version" "the probe prompt stayed in the composer after Enter, so no turn started"
    continue
  fi

  observed_busy=0
  for _ in $(seq 1 150); do
    if rendered_busy "$target" "$harness"; then
      observed_busy=1
      break
    fi
    sleep 0.2
  done

  if [ "$observed_busy" = 1 ]; then
    pass "busy signature: $harness $version separates idle from an active turn"
  else
    fail "BUSY SIGNATURE DRIFT (active): $harness $version never rendered a signature this guard recognizes during a real turn. Supervision will read an active turn as idle and can inject mid-turn. Observed tail:
$(capture_tail "$target")
Teach bin/fm-tmux-lib.sh the active-turn signature this release actually renders."
  fi

  CHECKED=$((CHECKED + 1))
done

[ "$CHECKED" -gt 0 ] || fail \
  "no installed harness could be driven to a real turn, so this run proved nothing about any busy signature; do not record its result as evidence"

if [ -n "$SKIPPED" ]; then
  note "not installed on this machine:$SKIPPED"
fi
if [ -n "$UNVERIFIED" ]; then
  note "installed but undrivable here, signature unproven:$UNVERIFIED"
fi
note "fully verified $CHECKED installed harness(es)"

cleanup_all
trap - EXIT
