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
# It runs one print-mode turn with a one-word prompt, which is the smallest real
# session that fires a hook. That token cost is deliberate: the alternative is a
# check that can only confirm the assumption already written into its own stub.
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
mkdir -p "$LAB/.claude" "$LAB/out"

cat > "$LAB/report.sh" <<SH
#!/usr/bin/env bash
{
  printf 'declared=%s\n' "\${CLAUDE_PID:-none}"
  . "$ROOT/bin/fm-session-lock-lib.sh"
  printf 'lib_declared=%s\n' "\$(fm_harness_declared_session_pid || echo none)"
  printf 'writer_identity=%s\n' "\$(fm_harness_ancestry_pid || echo none)"
  printf 'ancestry=%s\n' "\$(fm_harness_ancestry_pids | tr '\\n' ' ')"
} > "$LAB/out/report.txt" 2>&1
exit 0
SH
chmod +x "$LAB/report.sh"

cat > "$LAB/.claude/settings.json" <<SH
{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"$LAB/report.sh"}]}]}}
SH

( cd "$LAB" && CLAUDE_PID="$POISON" timeout 300 "$CLAUDE_BIN" \
    -p 'Reply with the single word: ok' --dangerously-skip-permissions >"$LAB/out/turn.log" 2>&1 ) || true

[ -s "$LAB/out/report.txt" ] \
  || fail "the real session never ran its own SessionStart hook, so nothing was verified: $(tail -3 "$LAB/out/turn.log" 2>/dev/null)"

read_field() { sed -n "s/^$1=//p" "$LAB/out/report.txt" | head -1; }
DECLARED=$(read_field declared)
LIB_DECLARED=$(read_field lib_declared)
WRITER=$(read_field writer_identity)
ANCESTRY=$(read_field ancestry)

case "$DECLARED" in
  ''|none|*[!0-9]*)
    fail "claude ${VERSION:-?} no longer declares a numeric session pid to its own hooks (got '$DECLARED'); the session-lock writer has silently fallen back to the launching session's pid"
    ;;
esac
[ "$DECLARED" != "$POISON" ] \
  || fail "claude ${VERSION:-?} passed an INHERITED CLAUDE_PID through to its own hook instead of declaring the session; the writer can no longer tell a background session from a worker of the session above it"
[ "$LIB_DECLARED" = "$DECLARED" ] \
  || fail "the library read '$LIB_DECLARED' where the harness declared '$DECLARED'"
[ "$WRITER" = "$DECLARED" ] \
  || fail "claude ${VERSION:-?}: the session-lock writer recorded '$WRITER' instead of the declared session pid '$DECLARED'; ancestry was: $ANCESTRY"
case " $ANCESTRY " in
  *" $DECLARED "*) : ;;
  *) fail "claude ${VERSION:-?}: the declared session pid '$DECLARED' was not in the hook's own harness ancestry ($ANCESTRY), so the writer's membership check rejected it and fell back" ;;
esac

note "declared session pid $DECLARED overrode the planted $POISON; ancestry was: $ANCESTRY"
pass "session-lock: claude ${VERSION:-?} declares its own session process to the processes it spawns, and the writer records it"
