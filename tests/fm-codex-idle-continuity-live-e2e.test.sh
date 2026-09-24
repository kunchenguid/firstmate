#!/usr/bin/env bash
# Opt-in credentialed check: a real Codex Stop reaches idle continuity and
# re-arms a single-shot source after the turn is allowed to end.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_CODEX_LIVE_E2E codex

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB="$ROOT/.codex-idle-live.$$"
PROJECT="$LAB/project"
HOME_DIR="$LAB/fmhome"
LOG="$LAB/hits"
SRC="$LAB/source.sh"
TRANSCRIPT="$LAB/codex.jsonl"
CODEX_VERSION=$(codex --version)

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }

cleanup() {
  if [ -d "$HOME_DIR/state" ]; then
    FM_HOME="$HOME_DIR" "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
  fi
  rm -rf "$LAB"
}
trap cleanup EXIT

mkdir -p "$LAB" "$HOME_DIR/state"
git clone -q "$ROOT" "$PROJECT"
cp "$ROOT/bin/fm-codex-idle-continuity.sh" "$PROJECT/bin/fm-codex-idle-continuity.sh"
cp "$ROOT/.codex/hooks.json" "$PROJECT/.codex/hooks.json"
chmod +x "$PROJECT/bin/fm-codex-idle-continuity.sh"
cat > "$SRC" <<EOF
#!/bin/sh
printf 'x\n' >> '$LOG'
EOF
chmod +x "$SRC"
fm_test_track_procevent_home "$HOME_DIR"
FM_HOME="$HOME_DIR" "$ROOT/bin/fm-procevent.sh" register lavish shot -- "$SRC" >/dev/null \
  || fail "could not register the live source"
FM_HOME="$HOME_DIR" "$ROOT/bin/fm-procevent.sh" reconcile >/dev/null \
  || fail "initial live reconcile failed"
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  list=$(FM_HOME="$HOME_DIR" "$ROOT/bin/fm-procevent.sh" list 2>/dev/null || true)
  printf '%s\n' "$list" | grep -F 'none' >/dev/null && break
  sleep 0.3
done
before=$(wc -l < "$LOG" | tr -d ' ')
[ "$before" -ge 1 ] || fail "live source did not run before Codex started"

(
  cd "$PROJECT" || exit 1
  FM_HOME="$HOME_DIR" FM_POLL=1 codex exec \
    --dangerously-bypass-hook-trust \
    --dangerously-bypass-approvals-and-sandbox \
    --skip-git-repo-check \
    -c 'model_reasoning_effort="low"' \
    --json \
    'Reply with exactly IDLE-OK. Do not call tools.'
) > "$TRANSCRIPT" 2>&1 || fail "Codex exec failed: $(tail -20 "$TRANSCRIPT")"

after=$(wc -l < "$LOG" | tr -d ' ')
[ "$after" -gt "$before" ] || fail "Codex Stop did not re-arm the ownerless source ($before -> $after)"
printf 'ok - %s Stop re-armed an ownerless source across the idle boundary\n' "$CODEX_VERSION"
