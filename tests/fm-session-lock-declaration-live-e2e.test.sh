#!/usr/bin/env bash
# tests/fm-session-lock-declaration-live-e2e.test.sh - opt-in drift guard proving
# a real Claude Code session still declares its own process to the processes it
# spawns, which is what bin/fm-session-lock-lib.sh records as the session-lock
# identity.
#
# Why this file exists: under a session-hosting daemon the process table cannot
# tell an async hook running FOR a session apart from a background session
# launched BY it - both chains are harness-named end to end with no gap. The only
# signal that separates them is the harness's own declaration, so the writer
# prefers it. That makes a vendor-controlled surface load-bearing: if Claude Code
# stopped setting CLAUDE_PID, or started letting an inherited value through, the
# writer would silently fall back to recording the launching session's pid again
# and a background session's supervision would go inert mid-session.
#
# The guard therefore asserts the property that actually matters, not just that
# the variable exists: the session is launched with a DELIBERATELY WRONG
# CLAUDE_PID in its environment, and the value the harness reports inside its own
# SessionStart hook must be the session's own live process instead. A stub agent
# cannot prove that; only the real harness can.
#
# Standard CI has no harness binary and no credentials, so this is opt-in and
# on-demand. tests/fm-session-lock-ancestry.test.sh pins the same logic portably
# in CI with real processes and no harness. Run this guard after every Claude Code
# upgrade and before trusting refreshed evidence in
# docs/verification/runtime-backends.md.
#
# Two real sessions are exercised, because they are different shapes and only the
# second is the one the fix exists for:
#   - a print-mode session, whose hook runs directly under it, and
#   - a real background agent (claude --bg), whose hook runs several harness-named
#     hops below the shared session-hosting daemon. Without a declaration the
#     writer would record that DAEMON as this session's identity - a process
#     shared by every background session in the home, which outlives any one of
#     them.
# Each runs one turn with a one-word prompt, the smallest real session that fires
# a hook. That token cost is deliberate: the alternative is a check that can only
# confirm the assumption already written into its own stub.
set -u

if [ "${FM_SESSION_LOCK_DECLARATION_DRIFT:-0}" != 1 ]; then
  echo "skip: set FM_SESSION_LOCK_DECLARATION_DRIFT=1 to run the installed-harness session-declaration drift guard"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

LAB=
cleanup_all() { [ -n "${LAB:-}" ] && rm -rf "$LAB"; }
fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

CLAUDE_BIN=$(command -v claude 2>/dev/null || true)
[ -n "$CLAUDE_BIN" ] && [ -x "$CLAUDE_BIN" ] \
  || fail "claude is not installed, so this guard verified nothing; install it or run the portable counterpart instead"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-session-lock-declaration.XXXXXX") || fail "could not create the lab directory"
trap cleanup_all EXIT

VERSION=$("$CLAUDE_BIN" --version 2>/dev/null | head -1)
note "claude: ${VERSION:-unknown version} ($CLAUDE_BIN)"

# A pid no live process can hold, planted in the launch environment. The harness
# must override it; anything that lets it through is the drift this guard exists
# to catch.
POISON=2147483646

# The lab is a plain directory, never a firstmate home, so the only hook that can
# run is this guard's own reporter.
setup_lab_shape() {  # <shape>
  local shape=$1
  mkdir -p "$LAB/$shape/.claude" "$LAB/$shape/out"
  cat > "$LAB/$shape/report.sh" <<SH
#!/usr/bin/env bash
{
  printf 'declared=%s\n' "\${CLAUDE_PID:-none}"
  . "$ROOT/bin/fm-session-lock-lib.sh"
  printf 'lib_declared=%s\n' "\$(fm_harness_declared_session_pid || echo none)"
  printf 'writer_identity=%s\n' "\$(fm_harness_ancestry_pid || echo none)"
  printf 'ancestry=%s\n' "\$(fm_harness_ancestry_pids | tr '\\n' ' ')"
} > "$LAB/$shape/out/report.txt" 2>&1
exit 0
SH
  chmod +x "$LAB/$shape/report.sh"
  printf '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"%s"}]}]}}\n' \
    "$LAB/$shape/report.sh" > "$LAB/$shape/.claude/settings.json"
}

read_field() {  # <shape> <field>
  sed -n "s/^$2=//p" "$LAB/$1/out/report.txt" | head -1
}

# Assert the whole property for one shape: the harness declared a live process of
# its own instead of the planted value, the library reads the same thing, that pid
# is inside the hook's own harness ancestry, and the writer records it. Results go
# to SHAPE_* rather than stdout, so a diagnostic line can never be captured as a
# pid by a caller.
SHAPE_DECLARED=
SHAPE_ANCESTRY=
SHAPE_OUTERMOST=
assert_shape() {  # <shape> <description>
  local shape=$1 what=$2 declared lib_declared writer ancestry outermost
  [ -s "$LAB/$shape/out/report.txt" ] \
    || fail "$what: the real session never ran its own SessionStart hook, so nothing was verified: $(tail -3 "$LAB/$shape/out/turn.log" 2>/dev/null)"
  declared=$(read_field "$shape" declared)
  lib_declared=$(read_field "$shape" lib_declared)
  writer=$(read_field "$shape" writer_identity)
  ancestry=$(read_field "$shape" ancestry)

  case "$declared" in
    ''|none|*[!0-9]*)
      fail "$what: claude ${VERSION:-?} no longer declares a numeric session pid to its own hooks (got '$declared'); session-lock identity has silently fallen back to the outermost pid of the ancestry"
      ;;
  esac
  [ "$declared" != "$POISON" ] \
    || fail "$what: claude ${VERSION:-?} passed an INHERITED CLAUDE_PID through to its own hook instead of declaring the session; the writer can no longer tell a session from the plumbing above it"
  [ "$lib_declared" = "$declared" ] \
    || fail "$what: the library read '$lib_declared' where the harness declared '$declared'"
  [ "$writer" = "$declared" ] \
    || fail "$what: the session-lock writer recorded '$writer' instead of the declared session pid '$declared'; ancestry was: $ancestry"
  case " $ancestry " in
    *" $declared "*) : ;;
    *) fail "$what: the declared session pid '$declared' was not in the hook's own harness ancestry ($ancestry), so the writer's membership check rejected it and fell back" ;;
  esac
  outermost=$(printf '%s' "$ancestry" | awk '{print $NF}')
  SHAPE_DECLARED=$declared
  SHAPE_ANCESTRY=$ancestry
  SHAPE_OUTERMOST=$outermost
  note "$what: declared $declared, ancestry [$ancestry], planted $POISON"
}

# --- shape 1: a print-mode session, hook directly beneath it ------------------
setup_lab_shape print
( cd "$LAB/print" && CLAUDE_PID="$POISON" timeout 300 "$CLAUDE_BIN" \
    -p 'Reply with the single word: ok' --dangerously-skip-permissions \
    >"$LAB/print/out/turn.log" 2>&1 ) || true
assert_shape print "print-mode session"

# --- shape 2: a real background agent under the session-hosting daemon --------
BG_ID=
stop_background_agent() {
  [ -n "${BG_ID:-}" ] || return 0
  "$CLAUDE_BIN" stop "$BG_ID" >/dev/null 2>&1 || true
  BG_ID=
}
trap 'stop_background_agent; cleanup_all' EXIT

setup_lab_shape background
( cd "$LAB/background" && CLAUDE_PID="$POISON" timeout 300 "$CLAUDE_BIN" \
    --bg 'Reply with the single word: ok' --dangerously-skip-permissions \
    >"$LAB/background/out/turn.log" 2>&1 ) || true
BG_ID=$(sed -n 's/^backgrounded[^a-f0-9]*\([0-9a-f][0-9a-f]*\).*/\1/p' "$LAB/background/out/turn.log" | head -1)

i=0
while [ "$i" -lt 120 ] && [ ! -s "$LAB/background/out/report.txt" ]; do
  sleep 1
  i=$((i + 1))
done
assert_shape background "background agent"
BG_OUTERMOST=$SHAPE_OUTERMOST
BG_DECLARED=$SHAPE_DECLARED
BG_ANCESTRY=$SHAPE_ANCESTRY

# The shape only proves anything if the background session really did sit below
# harness-named plumbing. If the chain is one hop, this run did not exercise the
# case the fix exists for and must say so rather than passing vacuously.
[ "$BG_OUTERMOST" != "$BG_DECLARED" ] \
  || fail "background agent: the hook's harness ancestry was a single process ($BG_ANCESTRY), so this run never exercised a daemon-hosted session and proved nothing about it"
note "background agent: without the declaration the writer would have recorded $BG_OUTERMOST, the shared plumbing above this session"

stop_background_agent
pass "session-lock: claude ${VERSION:-?} declares its own session process in both a print-mode and a daemon-hosted background session, and the writer records it"
