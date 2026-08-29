#!/usr/bin/env bash
# tests/fm-allowance-park-live-e2e.test.sh - opt-in drift guard for
# allowance-park detection (bin/fm-allowance-lib.sh) against every INSTALLED
# harness that has a verified signature.
#
# Why this file exists: the verdict is read from two surfaces the vendor
# controls - the layout and contents of its own session store, and the notice it
# renders around its prompt. Both change without notice, and both fail silently:
# a store that moved makes the structural signal return "not parked" forever, and
# a healthy pane that starts matching the rendered signature makes every worker
# look parked. Neither shows up in the portable suite, because a fixture can only
# confirm the assumption already written into the fixture.
#
# What this guard proves, per installed harness, with NO model tokens spent:
#
#   1. firstmate still resolves that harness's session store for a real worker
#      launched in a real worktree - the derivation the structural signal depends
#      on entirely.
#   2. a real, healthy, unparked worker is NOT classified as parked, from either
#      signal, against its actual rendered pane.
#
# What it deliberately does NOT prove: that a REAL refusal still writes the
# fields the structural signal matches. Forcing one means exhausting the account
# allowance, which is the outage this whole change exists to shorten. That half
# is evidence, not a test: docs/verification/supervision.md records the observed
# refusal records, and refreshing it means capturing the next real refusal rather
# than provoking one.
#
# Standard CI has no harness binaries or credentials, so this is opt-in and
# on-demand. Run it after any harness upgrade and before trusting the refreshed
# per-harness evidence. The portable counterpart in tests/fm-allowance-park.test.sh
# pins the classifier logic everywhere else.
set -u

if [ "${FM_ALLOWANCE_PARK_DRIFT:-0}" != 1 ]; then
  echo "skip: set FM_ALLOWANCE_PARK_DRIFT=1 to run the installed-harness allowance-park drift guard"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

command -v tmux >/dev/null 2>&1 || fail "tmux not found"
REAL_TMUX=$(command -v tmux)
SOCKET="fm-allowance-drift-$$"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-allowance-drift.XXXXXX")
SESSION=drift

# Sessions started here leave a store behind in the operator's own harness
# config, named after this run's throwaway lab directory. Remove exactly those,
# never anything else: the name embeds $LAB, so it cannot collide with a real
# worker's store.
cleanup_stores() {
  local harness dir
  [ -n "${LAB:-}" ] || return 0
  for harness in ${ALL_HARNESSES:-}; do
    dir=$(harness_store_dir "$harness" "$LAB/wt-$harness" 2>/dev/null) || continue
    case "$dir" in
      */projects/*"$(printf '%s' "$LAB" | tr '/.' '--')"*) rm -rf "$dir" ;;
    esac
  done
}

cleanup_all() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  cleanup_stores
  [ -n "${LAB:-}" ] && rm -rf "$LAB"
}
trap cleanup_all EXIT

# shellcheck source=/dev/null
. "$ROOT/bin/fm-allowance-lib.sh"

mkdir -p "$LAB/wt"
"$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -n control -c "$LAB/wt" \
  || fail "could not start the private tmux server"

# Every harness firstmate can dispatch, so an adapter that GAINS a signature is
# covered the moment fm_allowance_harness_verified admits it, and one that has
# none is reported as deliberately unsupported rather than skipped in silence.
ALL_HARNESSES="claude codex opencode pi grok kimi cursor muse"

harness_version() {  # <binary>
  "$1" --version 2>/dev/null | head -1 | tr -d '\r' || true
}

# The one place this guard knows how to find a harness's own session store. A
# harness with a verified signature and no entry here is a gap, not a pass.
harness_store_dir() {  # <harness> <worktree>
  case "$1" in
    claude*) _fm_allowance_claude_project_dir "$2" ;;
    *) return 1 ;;
  esac
}

CHECKED=0
SUPPORTED=0

for harness in $ALL_HARNESSES; do
  bin=$(command -v "$harness" 2>/dev/null || true)
  if [ -z "$bin" ]; then
    note "$harness: not installed, nothing to check"
    continue
  fi
  CHECKED=$((CHECKED + 1))
  version=$(harness_version "$bin")
  if ! fm_allowance_harness_verified "$harness"; then
    # Deliberate: an adapter with no verified signature must behave exactly as it
    # did before this check existed. Assert that rather than skipping, so a
    # signature added without evidence cannot slip through as "untested".
    if fm_allowance_park_detail "$harness" "$LAB/wt" "You've hit your session limit · resets 3am (UTC)" >/dev/null; then
      fail "$harness ($version) parked on a signature it has no verified evidence for"
    fi
    note "$harness ($version): no verified signature, deliberately never parks"
    continue
  fi
  SUPPORTED=$((SUPPORTED + 1))

  wt="$LAB/wt-$harness"
  mkdir -p "$wt"
  win="live-$harness"
  "$REAL_TMUX" -L "$SOCKET" new-window -d -t "$SESSION" -n "$win" -c "$wt" \
    || fail "$harness ($version): could not open a pane"
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$SESSION:$win" "cd $(printf '%q' "$wt") && $(printf '%q' "$bin")" Enter
  # A first launch in a fresh directory asks its own trust question; answering it
  # is what gets the session far enough to create its store. No prompt follows, so
  # no model tokens are spent.
  sleep 8
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$SESSION:$win" Enter
  sleep 12

  pane=$("$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$SESSION:$win" 2>/dev/null || true)
  [ -n "$pane" ] || fail "$harness ($version): captured an empty pane, so nothing below was actually checked"

  # 1. the store derivation still lands where the harness actually writes
  store=$(harness_store_dir "$harness" "$wt") \
    || fail "$harness ($version): has a verified signature but no known session store, so the structural signal is unreachable"
  [ -d "$store" ] \
    || fail "$harness ($version): session store not found at $store - the structural signal would silently report every worker unparked"

  # 2. a real, healthy worker is not classified as parked, from either signal
  if detail=$(fm_allowance_park_detail "$harness" "$wt" "$pane"); then
    fail "$harness ($version): a live, unparked worker was classified as parked ($detail) - every worker would surface as parked on the allowance"
  fi

  pass "$harness ($version): store resolves at $store and a healthy worker is not read as parked"
done

[ "$CHECKED" -gt 0 ] \
  || fail "no harness was installed, so this guard checked nothing - do not read it as a pass"
[ "$SUPPORTED" -gt 0 ] \
  || fail "no installed harness has a verified allowance signature, so nothing was actually exercised"

note "refusal-record evidence is not exercised here; see docs/verification/supervision.md"
pass "every installed harness with a verified allowance signature was exercised"
