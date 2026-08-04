#!/usr/bin/env bash
# tests/fm-wedge-status-row-drift-live-e2e.test.sh - opt-in drift guard proving
# every INSTALLED harness still renders a status row that
# bin/fm-classify-lib.sh's status_row_shows_work recognizes while the harness is
# actually working.
#
# Why this file exists: a stale pane's wedge timer expiring is not proof of a
# wedge, so before raising a possible-wedge alarm both supervisors re-read the
# crew for fresh evidence it is still working. The authoritative evidence is the
# pipeline's own run step, which needs no harness cooperation. The second,
# independent source - for a scout, a crew that has not started validating, or a
# crew whose no-mistakes call cannot be reached - is the harness's own rendered
# status row, and rendered output is a surface the vendor changes without
# notice. A stub agent can only confirm the signature already transcribed into
# the stub, so this signature has to be read off real harnesses.
#
# Drift here is not a safety failure: the row can only DEFER an escalation, never
# raise one, an active run still defers on its own, and a deferral is bounded by
# FM_WEDGE_ACTIVITY_DEFER_MAX. A drifted signature therefore reverts a harness to
# the old false-positive behavior rather than silencing a genuine wedge. That is
# still worth catching, because the false positives it reintroduces each cost a
# whole supervision turn to triage by hand.
#
# Unlike the liveness drift guard, this one must make each harness WORK for a few
# seconds, so it submits one short prompt per installed harness and spends a
# small number of model tokens against whatever credentials the harness already
# has. It stops each harness the moment its row is recognized.
#
# Standard CI has no harness binaries or credentials, so this real-harness guard
# is opt-in and on-demand. The portable counterpart in
# tests/fm-watch-triage.test.sh pins the classifier logic in CI. Run this guard
# after any harness upgrade and before trusting refreshed evidence in
# docs/verification/runtime-backends.md.
set -u

if [ "${FM_WEDGE_STATUS_ROW_DRIFT:-0}" != 1 ]; then
  echo "skip: set FM_WEDGE_STATUS_ROW_DRIFT=1 to run the installed-harness wedge status-row drift guard"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

command -v tmux >/dev/null 2>&1 || fail "tmux not found"
REAL_TMUX=$(command -v tmux)
SOCKET="fm-wedge-row-drift-$$"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-wedge-row-drift.XXXXXX")
SESSION=rowdrift

# Long enough that every harness renders an in-progress row, short enough that a
# hung or unauthenticated harness fails the guard instead of stalling it.
WORK_PROMPT=${FM_WEDGE_ROW_PROMPT:-'Count from 1 to 60, one number per line, with no other text.'}
WORK_WAIT_TICKS=${FM_WEDGE_ROW_WAIT_TICKS:-120}   # 0.5s each

cleanup_all() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -n "${LAB:-}" ] && rm -rf "$LAB"
}
trap cleanup_all EXIT

mkdir -p "$LAB/shim" "$LAB/wt"
cat > "$LAB/shim/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$LAB/shim/tmux"
PATH="$LAB/shim:$PATH"
export PATH

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-classify-lib.sh"
fm_backend_source tmux || fail "fm_backend_source tmux failed"

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

CHECKED=0
SKIPPED=

# The verified adapters, in the order .agents/skills/harness-adapters/SKILL.md
# records them. An adapter that gains a verified launch path belongs here too.
for harness in claude codex opencode pi pi-signed grok kimi; do
  if ! bin_path=$(resolve_harness_binary "$harness"); then
    SKIPPED="$SKIPPED $harness"
    note "skip: $harness is not installed on this machine, so its status row is unverified here"
    continue
  fi

  version=$("$bin_path" --version 2>/dev/null | head -1 | tr -d '\r') || version=
  [ -n "$version" ] || version="unknown"

  target="$SESSION:$harness"
  "$REAL_TMUX" -L "$SOCKET" new-window -d -t "$SESSION:" -n "$harness" -c "$LAB/wt" -- "$bin_path" \
    || fail "$harness ($version): could not launch a window for the status-row probe"

  state=
  for _ in $(seq 1 300); do
    state=$(fm_backend_agent_state tmux "$target")
    [ "$state" = alive ] && break
    sleep 0.2
  done
  [ "$state" = alive ] || fail \
    "$harness $version: the probe window never came up alive (state '$state'), so no status row could be read"

  fm_backend_send_text_submit tmux "$target" "$WORK_PROMPT" 3 0.4 1 >/dev/null 2>&1 \
    || fail "$harness $version: could not submit the probe prompt, so no working status row could be observed"

  matched=0
  last_tail=
  for _ in $(seq 1 "$WORK_WAIT_TICKS"); do
    last_tail=$(fm_backend_capture tmux "$target" 40 2>/dev/null) || last_tail=
    if [ -n "$last_tail" ] && printf '%s\n' "$last_tail" | status_row_shows_work; then
      matched=1
      break
    fi
    sleep 0.5
  done

  # Stop the harness as soon as the verdict is in, so a passing probe spends the
  # least model time it can.
  fm_backend_kill tmux "$target" >/dev/null 2>&1 || true

  [ "$matched" = 1 ] || fail \
"STATUS-ROW DRIFT: $harness $version rendered no row that status_row_shows_work recognizes while it was working.
Wedge escalations for this harness lose their second evidence source and fall back to run-step evidence alone, so a crew with no active pipeline run raises false possible-wedge alarms again.
Last captured footer:
$(printf '%s\n' "$last_tail" | grep -v '^[[:space:]]*$' | tail -6)
Teach bin/fm-classify-lib.sh's FM_CLASSIFY_WORK_ROW_RE_DEFAULT the in-progress row this release actually renders, then refresh docs/verification/runtime-backends.md."

  note "$harness $version: matched status row [$(printf '%s\n' "$last_tail" | grep -v '^[[:space:]]*$' | tail -1)]"
  pass "wedge status row: $harness $version renders a recognized working row"
  CHECKED=$((CHECKED + 1))
done

[ "$CHECKED" -gt 0 ] || fail \
  "no verified harness is installed here, so this run proved nothing; install at least one harness before trusting a pass"

if [ -n "$SKIPPED" ]; then
  note "unverified on this machine (not installed):$SKIPPED"
fi
note "checked $CHECKED installed harness(es)"

cleanup_all
trap - EXIT
