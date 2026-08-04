#!/usr/bin/env bash
# tests/fm-composer-empty-drift-live-e2e.test.sh - opt-in drift guard proving
# every INSTALLED harness's genuinely EMPTY composer is still classified `empty`
# by the shared composer-content owner (bin/fm-composer-lib.sh), and that the
# same reader still calls a composer holding typed text `pending`.
#
# Why this file exists (task fm-send-false-negative-herdr): the empty/pending
# verdict is decided from bytes the harness vendor chooses and changes without
# notice. Claude 2.x began padding its empty composer with U+00A0 NO-BREAK SPACE
# instead of an ASCII space; every trim in the reader is ASCII-only under the
# fleet's C locale, so the pad survived and EVERY claude composer - idle, empty,
# nothing typed - classified as `pending`. Nothing failed loudly. The away-mode
# injector silently deferred every escalation on a claude pane, and `fm-send` to
# a busy claude pane reported a swallowed Enter for steers that had landed,
# which invited resends that duplicated the message in the harness's own queue.
#
# A regression only a real harness release can cause needs a check that runs
# real harnesses. A stubbed agent can only confirm the padding already written
# into the stub, and a table of glyphs transcribed from a previous release ages
# into a false claim. The portable counterparts pin the classifier logic in CI:
# tests/fm-composer-lib.test.sh (the shared verdict, including U+00A0) and
# tests/fm-backend-herdr.test.sh (the herdr reader over captured real bytes).
#
# BOTH directions are asserted per harness, because they fail for different
# reasons and a one-directional guard is worse than none: an empty composer must
# read `empty` (under-normalizing revives the silent defer), and a composer
# holding typed text must read `pending` (over-normalizing would let the
# injector type over a human's unsent input).
#
# ORDER IS LOAD-BEARING. `empty` is asserted only AFTER the probe text has been
# seen in the pane and then deleted, never against a freshly launched window: a
# pane that has not drawn anything yet is blank, and a blank pane classifies
# `empty` for the trivial reason that there is nothing on it. Asserting `empty`
# first therefore passes in milliseconds against a harness that never started,
# proving nothing. Seeing the probe arrive is also what separates a live
# composer from a harness parked on a trust or login prompt, which accepts no
# typed text and would otherwise be mistaken for one.
#
# WHAT THIS GUARD CANNOT SEE: it reads panes through `tmux capture-pane`, which
# normalizes the trailing composer padding away - verified 2026-08-04, a claude
# 2.1.220 composer that herdr's `pane read --format ansi` returns as
# `e2 9d af c2 a0` arrives here as `e2 9d af 20`. The U+00A0 defect that
# motivated this file is therefore invisible on the tmux capture path and is
# pinned instead by the byte-exact real-capture fixtures in
# tests/fm-backend-herdr.test.sh. A live guard over herdr's own reader needs a
# herdr lab session and belongs to a Herdr-lifecycle-authorized task.
#
# Each harness is launched bare, with no prompt, and Enter is NEVER sent, so
# this consumes no model tokens. The launch uses whatever credentials the
# harness already has.
#
# Standard CI has no harness binaries or credentials, so this real-harness guard
# is opt-in and on-demand. Run it after any harness upgrade and before trusting
# refreshed per-harness evidence in docs/verification/runtime-backends.md.
set -u

if [ "${FM_COMPOSER_EMPTY_DRIFT:-0}" != 1 ]; then
  echo "skip: set FM_COMPOSER_EMPTY_DRIFT=1 to run the installed-harness empty-composer drift guard"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

command -v tmux >/dev/null 2>&1 || fail "tmux not found"
REAL_TMUX=$(command -v tmux)
SOCKET="fm-composer-drift-$$"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-composer-drift.XXXXXX")
SESSION=drift

cleanup_all() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -n "${LAB:-}" ] && rm -rf "$LAB"
}
trap cleanup_all EXIT

mkdir -p "$LAB/shim"
cat > "$LAB/shim/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$LAB/shim/tmux"
PATH="$LAB/shim:$PATH"
export PATH

# shellcheck source=/dev/null
. "$ROOT/bin/fm-tmux-lib.sh"

"$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -n control -c "$ROOT" \
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

# Poll <target> until its composer reads <want>, up to <tries> 0.2s samples.
# Echoes the LAST observed verdict so a failure can name what the reader saw.
await_composer_state() {  # <target> <want> <tries>
  local target=$1 want=$2 tries=$3 state='' i
  for ((i = 0; i < tries; i++)); do
    state=$(fm_tmux_composer_state "$target")
    [ "$state" = "$want" ] && break
    sleep 0.2
  done
  printf '%s' "$state"
}

# Poll until the probe text is present (<want>=1) or gone (<want>=0) from the
# visible pane. This is the readiness proof the state assertions rest on: it is
# the only evidence that our keystrokes reached a real input surface rather than
# a trust prompt, a login screen, or a window that has drawn nothing yet.
await_probe_visible() {  # <target> <want> <tries>
  local target=$1 want=$2 tries=$3 i seen
  for ((i = 0; i < tries; i++)); do
    if tmux capture-pane -p -t "$target" 2>/dev/null | grep -qF "$PROBE"; then
      seen=1
    else
      seen=0
    fi
    [ "$seen" = "$want" ] && return 0
    sleep 0.2
  done
  return 1
}

# A probe that no harness renders as ghost/placeholder text and that no idle
# regex matches, so `pending` can only come from the reader seeing real input.
PROBE='fm-composer-drift-probe'

CHECKED=0
SKIPPED=
UNEXERCISED=

# The verified adapters, in the order .agents/skills/harness-adapters/SKILL.md
# records them. An adapter that gains a verified launch path belongs here too.
for harness in claude codex opencode pi pi-signed grok kimi; do
  if ! bin_path=$(resolve_harness_binary "$harness"); then
    SKIPPED="$SKIPPED $harness"
    note "skip: $harness is not installed on this machine, so its composer shape is unverified here"
    continue
  fi

  version=$("$bin_path" --version 2>/dev/null | head -1 | tr -d '\r') || version=
  [ -n "$version" ] || version="unknown"

  # Launched in the firstmate repo, NOT a scratch directory: a harness meeting a
  # directory for the first time opens a trust prompt instead of a session, and
  # this guard needs a real composer to read. The repo is a directory any
  # operator running this guard already works in. Nothing is typed but the probe
  # and its BackSpaces, and Enter is never sent.
  target="$SESSION:$harness"
  "$REAL_TMUX" -L "$SOCKET" new-window -d -t "$SESSION:" -n "$harness" -c "$ROOT" -- "$bin_path" \
    || fail "$harness ($version): could not launch a window for the composer probe"

  # Let the harness draw before typing at it: keystrokes sent to a TUI that has
  # not started yet are simply lost, and the retype below would mask that.
  for ((settle = 0; settle < 300; settle++)); do
    [ -n "$("$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$target" 2>/dev/null | tr -d '[:space:]')" ] && break
    sleep 0.2
  done

  # Readiness, then the PENDING direction: type the probe and require it to
  # actually appear on screen before any verdict is trusted.
  # Enter is never sent, so the probe stays unsubmitted and costs no tokens.
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$target" -l "$PROBE" \
    || fail "$harness ($version): could not type the composer probe"
  # A harness that never shows the probe never reached an input surface at all -
  # it is parked on a trust, login, or update prompt. That is an unexercised
  # harness, not a classifier verdict, so it is recorded as UNVERIFIED and named
  # in the summary rather than failed: an operator with one unauthenticated
  # harness must still be able to get a meaningful run out of the others. The
  # verdict assertions below stay hard failures, and a run that exercised
  # NOTHING still refuses to pass.
  if ! await_probe_visible "$target" 1 150; then
    UNEXERCISED="$UNEXERCISED $harness/$version"
    note "UNVERIFIED: $harness $version never showed the typed probe '$PROBE', so it never reached a composer. The usual cause is a trust, login, or update prompt instead of a session. Inspect with 'tmux -L $SOCKET capture-pane -p -t $target', then authenticate or dismiss the prompt and re-run to cover this harness."
    "$REAL_TMUX" -L "$SOCKET" kill-window -t "$target" >/dev/null 2>&1 || true
    continue
  fi

  state=$(await_composer_state "$target" pending 50)
  [ "$state" = pending ] || fail \
    "PENDING-COMPOSER DRIFT: $harness $version classifies a composer visibly holding the typed probe '$PROBE' as '$state', not 'pending'. The reader can no longer see real unsent input on this harness, so the away-mode injector would type over a human's unsubmitted message and a swallowed Enter would be reported as delivered. Capture the row with 'tmux -L $SOCKET capture-pane -e -p -t $target' and check what bin/fm-composer-lib.sh is stripping from it."

  # The EMPTY direction: delete the probe, one BackSpace per character, and
  # require the now-empty composer to read empty. BackSpace rather than a keybind
  # because no keybinding is portable across every harness, and never Enter.
  for ((k = 0; k < ${#PROBE}; k++)); do
    "$REAL_TMUX" -L "$SOCKET" send-keys -t "$target" BSpace 2>/dev/null || true
  done
  await_probe_visible "$target" 0 150 || fail \
    "$harness ($version): the composer probe '$PROBE' survived ${#PROBE} BackSpace keys, so the emptiness assertion below would not have been testing an empty composer. Inspect with 'tmux -L $SOCKET capture-pane -p -t $target'."

  state=$(await_composer_state "$target" empty 50)
  [ "$state" = empty ] || fail \
    "EMPTY-COMPOSER DRIFT: $harness $version classifies a composer we just emptied as '$state', not 'empty'. Every consumer of this verdict now treats an idle $harness pane as holding unsent human input: the away-mode injector will defer every escalation against it, and a send to a busy pane will report a swallowed Enter for a steer that landed. Capture the row with 'tmux -L $SOCKET capture-pane -e -p -t $target' and teach bin/fm-composer-lib.sh what this release leaves in an empty composer - FM_COMPOSER_BLANKS for a non-ASCII pad, the idle regex for placeholder text."

  note "$harness $version: typed probe reads pending, emptied composer reads empty"
  pass "composer emptiness: $harness $version classifies pending and empty correctly"
  CHECKED=$((CHECKED + 1))

  "$REAL_TMUX" -L "$SOCKET" kill-window -t "$target" >/dev/null 2>&1 || true
done

[ "$CHECKED" -gt 0 ] || fail \
  "this run exercised NO harness, so it proved nothing about the composer reader. Not installed:${SKIPPED:- none}. Installed but never reached a composer:${UNEXERCISED:- none}. Install or authenticate at least one harness before trusting a pass."

if [ -n "$SKIPPED" ]; then
  note "unverified on this machine (not installed):$SKIPPED"
fi
if [ -n "$UNEXERCISED" ]; then
  note "unverified on this machine (installed but never reached a composer):$UNEXERCISED"
fi
note "exercised $CHECKED installed harness(es)"

cleanup_all
trap - EXIT
