#!/usr/bin/env bash
# Runner for the Telegram terminal mirror bot's acceptance tests
# (tests/fm-telegram-mirror.test.py drives the real bin/fm-telegram.py process
# against a fake Telegram API, a fake Pi extension, and a fake local Parakeet).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found for the Telegram mirror test"; exit 0; }

DRIVER="$ROOT/tests/fm-telegram-mirror.test.py"
OUT=$(mktemp "${TMPDIR:-/tmp}/fm-telegram-mirror.XXXXXX")
trap 'rm -f "$OUT"' EXIT

# Bounded: a wedged fixture must fail the suite, never stall it.
if ! timeout 600 python3 "$DRIVER" >"$OUT" 2>&1; then
  cat "$OUT" >&2
  fail "bin/fm-telegram.py acceptance tests failed or timed out"
fi

pass "the Telegram mirror bot pairs to one chat, starts every process with mirror mode on, mirrors terminal and reply text, queues Telegram text to Pi in order, and drives the voice send, edit, and cancel flow"
