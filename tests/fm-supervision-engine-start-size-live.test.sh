#!/usr/bin/env bash
# tests/fm-supervision-engine-start-size-live.test.sh - live guard: the
# supervision host's headless engine, the middle step between a monitoring
# script and the main session, starts small, and a regression fails.
#
# Token-free and default-on (fm_live_gate). The guard drives the real engine
# launch path, bin/fm-supervision-engine-lib.sh's fm_supervision_engine_turn,
# with the generated branch prompt (bin/fm-branch-prompt.sh), through a wrapper
# that replaces only the turn's message with Claude Code's `/context` command,
# which is answered locally. Every other flag is the library's own, so what is
# measured is the context the engine's first call would carry. The guard fails
# naming the Claude Code version when the estimate exceeds
# FM_ENGINE_START_BUDGET tokens (default 18000).
#
# Measured on Claude Code 2.1.325: /context estimates 16.2k; one real engine
# turn's first call read 17,097 tokens (2 fresh + 17,095 cache write). The
# design target is under 15,000; the gap is recorded in
# docs/verification/runtime-backends.md.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_LIVE_ENGINE_START_SIZE claude jq

TMP_ROOT=$(fm_test_tmproot fm-engine-start-size)
BUDGET=${FM_ENGINE_START_BUDGET:-18000}
REAL_CLAUDE=$(command -v claude)
CLAUDE_VERSION=$(claude --version 2>/dev/null | head -1)

cat >"$TMP_ROOT/claude" <<SH
#!/usr/bin/env bash
# Pass every argument through unchanged except the -p message.
args=()
while [ \$# -gt 0 ]; do
  if [ "\$1" = -p ]; then args+=(-p /context); shift 2; continue; fi
  args+=("\$1"); shift
done
exec "$REAL_CLAUDE" "\${args[@]}"
SH
chmod +x "$TMP_ROOT/claude"

mkdir -p "$TMP_ROOT/home/state" "$TMP_ROOT/home/config" "$TMP_ROOT/home/data"
bash "$ROOT/bin/fm-branch-prompt.sh" >"$TMP_ROOT/prompt" || fail "the branch prompt could not be generated"
printf 'unused: the wrapper replaces this message\n' >"$TMP_ROOT/msg"

# shellcheck disable=SC2016 # the single-quoted script expands in its own shell
out=$(env FM_HOME="$TMP_ROOT/home" STATE="$TMP_ROOT/home/state" FM_ROOT="$ROOT" \
  FM_SUPERVISION_ENGINE_CLAUDE_BIN="$TMP_ROOT/claude" bash -c '
    . "$1/bin/fm-wake-lib.sh"
    . "$1/bin/fm-timeout-lib.sh"
    . "$1/bin/fm-supervision-engine-lib.sh"
    fm_supervision_engine_turn claude "${FM_LIVE_ENGINE_MODEL:-sonnet}" "$2/prompt" "$2/msg" "$(uuidgen | tr A-Z a-z)" new 300 "$2/result" "$2/errors"
  ' _ "$ROOT" "$TMP_ROOT" 2>&1) || fail "claude $CLAUDE_VERSION: the engine launch failed: $out $(tail -3 "$TMP_ROOT/errors" 2>/dev/null)"

text=$(jq -r '.result // empty' "$TMP_ROOT/result" 2>/dev/null)
size=$(printf '%s\n' "$text" | sed -n 's/^\*\*Tokens:\*\* *\([0-9.]*\)\([kK]\{0,1\}\) *\/.*/\1 \2/p' | head -1)
[ -n "$size" ] || fail "claude $CLAUDE_VERSION: /context printed no Tokens line through the engine path; the live signal moved: $(head -c 400 "$TMP_ROOT/result")"
tokens=$(printf '%s\n' "$size" | awk '{ v = $1; if ($2 == "k" || $2 == "K") v *= 1000; printf "%d", v }')
printf '# engine start (claude %s): %s tokens estimated, budget %s\n' "$CLAUDE_VERSION" "$tokens" "$BUDGET"
printf '%s\n' "$text" | sed -n '/^| Category/,/^$/p' | sed 's/^/# /'
[ "$tokens" -le "$BUDGET" ] || fail "claude $CLAUDE_VERSION: the engine's first call grew to $tokens tokens, over the $BUDGET budget"
pass "claude $CLAUDE_VERSION: the supervision engine starts at $tokens tokens, within the $BUDGET budget"
