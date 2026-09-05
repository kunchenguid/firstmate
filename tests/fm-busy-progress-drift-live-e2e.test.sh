#!/usr/bin/env bash
# tests/fm-busy-progress-drift-live-e2e.test.sh - opt-in drift guard proving
# each INSTALLED harness still renders progress counters that
# bin/fm-progress-lib.sh can read AND can see advance.
#
# Why this file exists. The busy-but-no-progress report
# (busy_progress_check in bin/fm-watch.sh) measures a worker's advance from
# numbers the harness VENDOR renders and can restyle in any release. If a
# release drops its token meter, renames it into a shape the library does not
# match, or replaces it with a number that never rises, the report does not fail
# loudly - it goes quiet for that harness and falls back to the hour-long
# completed-turn bound, which is exactly the gap the report was built to close.
# A stubbed pane cannot see that happen: it can only confirm the fixture already
# written into the stub. Only a real harness can.
#
# The portable counterpart, tests/fm-progress-lib.test.sh, pins the library's
# logic in CI everywhere. This guard answers the other half of the question and
# needs real binaries and real credentials, which standard CI has neither of, so
# it is opt-in and on-demand. Run it after any harness upgrade and before
# trusting the per-harness evidence in docs/verification/runtime-backends.md.
#
# Cost: one short real turn per installed harness, sampled repeatedly while it
# runs. That is the smallest turn that can produce an advancing counter at all,
# and it is the price of not silently losing supervision coverage.
set -u

if [ "${FM_BUSY_PROGRESS_DRIFT:-0}" != 1 ]; then
  echo "skip: set FM_BUSY_PROGRESS_DRIFT=1 to run the installed-harness progress-counter drift guard"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

command -v tmux >/dev/null 2>&1 || fail "tmux not found"
REAL_TMUX=$(command -v tmux)
SOCKET="fm-progress-drift-$$"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-progress-drift.XXXXXX")
SESSION=drift

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
. "$ROOT/bin/fm-progress-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-cursor-lib.sh"

"$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -n control -c "$LAB/wt" \
  || fail "could not start the private tmux server"

# Mirrors bin/fm-spawn.sh's own resolution order, so this guard covers the same
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
  if [ "$harness" = cursor ]; then
    fm_cursor_resolve_binary 2>/dev/null && return 0
    return 1
  fi
  return 1
}

# Harnesses this repo already holds recorded rendered-counter evidence for (the
# `- 234 tokens` / `- 1.1k tokens` footers in
# docs/verification/runtime-backends.md and tests/fm-tmux-submit-busy.test.sh).
# Losing counters on one of these is a REGRESSION in supervision coverage and
# fails the guard. Every other installed harness is observed and reported, and
# an observation that its counters do advance is what promotes it into this
# list, in the same commit that records the evidence.
EXPECTED_COUNTERS=" claude "

CHECKED=0
SKIPPED=
WITH_COUNTERS=
WITHOUT_COUNTERS=

for harness in claude codex opencode pi pi-signed grok kimi cursor muse; do
  if ! bin_path=$(resolve_harness_binary "$harness"); then
    SKIPPED="$SKIPPED $harness"
    note "skip: $harness is not installed on this machine, so its counters are unverified here"
    continue
  fi
  version=$("$bin_path" --version 2>/dev/null | head -1 | tr -d '\r') || version=
  [ -n "$version" ] || version="unknown"

  target="$SESSION:$harness"
  launch_args=""
  [ "$harness" = cursor ] && launch_args="--trust"
  # shellcheck disable=SC2086  # deliberate: an empty value must add no argument
  "$REAL_TMUX" -L "$SOCKET" new-window -d -t "$SESSION:" -n "$harness" -c "$LAB/wt" -- "$bin_path" $launch_args \
    || fail "$harness ($version): could not launch a window for the counter probe"

  # Let the composer settle, then ask for the shortest real turn there is. The
  # counters only exist while a turn is in flight, which is precisely when the
  # watcher samples them.
  sleep 8
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$target" "count from one to twenty" >/dev/null 2>&1 || true
  sleep 1
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$target" Enter >/dev/null 2>&1 || true

  # Sample repeatedly across the turn, exactly as the watcher does, and require
  # what the report actually depends on: one reading is only a counter SHAPE,
  # and busy_progress_check arms solely when fm_progress_advanced sees a kind at
  # a strictly higher value in a later reading. A harness whose readable numbers
  # never rise - a context-left percentage that only falls, or transcript text
  # that merely differs - is permanently unarmable, so stopping at the first
  # reading would report coverage this repo does not have.
  #
  # The pair tested is the one the watcher tests: CONSECUTIVE readings, its
  # stored previous counters against the current poll's. fm_progress_advanced
  # only compares a kind present in BOTH readings, so a footer that gains its
  # token meter after its context meter would never satisfy a fixed baseline;
  # the first readable sample is kept only as an ADDITIONAL chance, for a kind
  # that renders intermittently and so is missing from one neighbour.
  found=
  shaped=
  first=
  prev_reading=
  sample=
  for _ in $(seq 1 40); do
    sample=$("$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$target" 2>/dev/null || true)
    if reading=$(fm_progress_counters "$sample"); then
      reading=$(printf '%s' "$reading" | tr '\n' ' ')
      [ -n "$shaped" ] || shaped=$reading
      if [ -n "$prev_reading" ] && fm_progress_advanced "$prev_reading" "$reading"; then
        found="$prev_reading -> $reading"
        break
      fi
      if [ -n "$first" ] && fm_progress_advanced "$first" "$reading"; then
        found="$first -> $reading"
        break
      fi
      [ -n "$first" ] || first=$reading
      prev_reading=$reading
    fi
    sleep 1
  done

  if [ -n "$found" ]; then
    WITH_COUNTERS="$WITH_COUNTERS $harness"
    note "$harness $version: renders progress counters observed advancing [$found]"
    pass "progress counters: $harness $version renders a progress counter observed advancing"
  else
    WITHOUT_COUNTERS="$WITHOUT_COUNTERS $harness"
    if [ -n "$shaped" ]; then
      detail="rendered counter-shaped text [$shaped] but no counter bin/fm-progress-lib.sh reads was observed RISING across a real turn, so busy_progress_check can never arm on it"
    else
      detail="rendered no counter bin/fm-progress-lib.sh can read during a real turn"
    fi
    case "$EXPECTED_COUNTERS" in
      *" $harness "*)
        fail "PROGRESS-COUNTER DRIFT: $harness $version $detail, though this repo's recorded evidence says its counters used to advance. The busy-but-no-progress report is silently blind for this harness and falls back to the hour-long completed-turn bound. Last pane sampled:
$sample"
        ;;
      *)
        note "$harness $version: $detail; this harness keeps the completed-turn bound as its only backstop"
        pass "progress counters: $harness $version observed (no advancing counter, recorded as an admitted blind spot)"
        ;;
    esac
  fi
  CHECKED=$((CHECKED + 1))
done

[ "$CHECKED" -gt 0 ] || fail \
  "no verified harness is installed here, so this run proved nothing; install at least one harness before trusting a pass"

[ -n "$WITH_COUNTERS" ] || note \
  "no installed harness was observed advancing a readable counter: the busy-but-no-progress report can measure nothing on this machine"
note "advances counters:${WITH_COUNTERS:- none}"
note "advances none:${WITHOUT_COUNTERS:- none}"
if [ -n "$SKIPPED" ]; then
  note "unverified on this machine (not installed):$SKIPPED"
fi
note "checked $CHECKED installed harness(es)"

cleanup_all
trap - EXIT
