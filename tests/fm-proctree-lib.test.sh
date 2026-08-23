#!/usr/bin/env bash
# tests/fm-proctree-lib.test.sh - the one owner of parent-chain climbing must
# climb real processes correctly:
#
#   1. The visitor sees the start pid first; accessors read real kernel facts
#      (comm of a live sleep is "sleep").
#   2. A climb from a nested child reaches a named ancestor within the bound
#      and succeeds; the same climb with max-hops 1 fails (bound enforced).
#   3. A never-matching visitor fails at the init boundary instead of looping.
#   4. A visitor returning 2 stops the climb as a failure immediately.
#
# Real processes only - no fakes; the chain is this test's own children.
# shellcheck disable=SC2015 # ok/fail are echo-only, so `A && ok || fail` cannot misfire.
# shellcheck disable=SC2329 # visitor functions are invoked indirectly by fm_proctree_climb.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=bin/fm-proctree-lib.sh
. "$REPO/bin/fm-proctree-lib.sh"

FAILS=0
fail() { echo "FAIL: $1" >&2; FAILS=$((FAILS + 1)); }
ok() { echo "ok: $1"; }

# Build a real chain: this test -> outer bash -> inner bash -> sleep.
# The trailing `true` in each layer keeps bash from exec-ing its single
# command away, so the chain really nests instead of collapsing.
bash -c 'bash -c "sleep 60; true"; true' &
OUTER=$!
trap 'kill "$OUTER" 2>/dev/null; pkill -P "$OUTER" 2>/dev/null' EXIT
INNER=""
SLEEPER=""
for _ in $(seq 1 50); do
  INNER=$(pgrep -P "$OUTER" | head -1 || true)
  [ -n "$INNER" ] && SLEEPER=$(pgrep -P "$INNER" | head -1 || true)
  [ -n "$SLEEPER" ] && break
  sleep 0.1
done
[ -n "$SLEEPER" ] || { echo "could not build the process chain" >&2; exit 1; }

# --- 1. accessors and first-visit pid --------------------------------------
[ "$(fm_proctree_comm "$SLEEPER")" = "sleep" ] && ok "comm accessor reads the real kernel name" \
  || fail "comm accessor must read 'sleep' (got '$(fm_proctree_comm "$SLEEPER")')"
FIRST_SEEN=""
_first_visit() { FIRST_SEEN=$1; return 0; }
fm_proctree_climb "$SLEEPER" 5 _first_visit >/dev/null
[ "$FIRST_SEEN" = "$SLEEPER" ] && ok "the visitor sees the start pid first" \
  || fail "the visitor must see the start pid first"

# --- 2. reach a named ancestor; the hop bound is enforced -------------------
_match_outer() { [ "$1" = "$OUTER" ] && return 0; return 1; }
if fm_proctree_climb "$SLEEPER" 5 _match_outer; then
  ok "the climb reaches the outer ancestor within the bound"
else
  fail "the climb must reach the outer ancestor (sleeper=$SLEEPER outer=$OUTER)"
fi
if fm_proctree_climb "$SLEEPER" 1 _match_outer; then
  fail "max-hops 1 must not reach an ancestor two levels up"
else
  ok "the hop bound is enforced"
fi

# --- 3. a never-matching visitor ends at the init boundary ------------------
_never() { return 1; }
if fm_proctree_climb "$SLEEPER" 64 _never; then
  fail "a never-matching visitor must fail"
else
  ok "a never-matching visitor fails at the init boundary"
fi

# --- 4. visitor code 2 stops as failure immediately -------------------------
VISITS=0
_abort() { VISITS=$((VISITS + 1)); return 2; }
if fm_proctree_climb "$SLEEPER" 5 _abort; then
  fail "visitor code 2 must fail the climb"
else
  [ "$VISITS" = 1 ] && ok "visitor code 2 stops after one visit" \
    || fail "visitor code 2 must stop immediately (visits=$VISITS)"
fi

echo
if [ "$FAILS" -eq 0 ]; then
  echo "fm-proctree-lib.test.sh: all checks passed"
  exit 0
fi
echo "fm-proctree-lib.test.sh: $FAILS check(s) FAILED"
exit 1
