#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-web-inbox)
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/state"
export FM_HOME="$HOME_DIR"
WEB_INBOX="$ROOT/bin/fm-web-inbox.sh"

python3 - "$HOME_DIR/state/.inbox" <<'PY'
import json, sys
rows = [
    {"id":"typed-1", "ts":"2026-01-01T00:00:00Z", "channel":"typed", "text":"Summarize the release notes"},
    {"id":"click-2", "ts":"2026-01-01T00:01:00Z", "channel":"click", "text":"Approve the reviewed change", "ref":{"task":"task-1", "sha":"a" * 40}},
]
with open(sys.argv[1], "w", encoding="utf-8") as stream:
    for row in rows:
        stream.write(json.dumps(row, separators=(",", ":")) + "\n")
    stream.write('{"id":"partial"}')
PY

pending=0
"$WEB_INBOX" pending || pending=$?
[ "$pending" -eq 0 ] || fail "complete browser messages should be pending"
drain=$("$WEB_INBOX" drain) || fail "drain should read pending browser messages"
printf '%s\n' "$drain" | grep -q '"id":"typed-1"' || fail "first message was not returned"
printf '%s\n' "$drain" | grep -q '"id":"click-2"' || fail "second message was not returned"
! printf '%s\n' "$drain" | grep -q 'partial' || fail "an unterminated line must not be returned"

first_offset=$(printf '%s\n' "$drain" | sed -n '1s/.*"offset":\([0-9]*\).*/\1/p')
second_offset=$(printf '%s\n' "$drain" | sed -n '2s/.*"offset":\([0-9]*\).*/\1/p')
[ -n "$first_offset" ] && [ -n "$second_offset" ] || fail "drain offsets are missing"
if "$WEB_INBOX" ack click-2 "$second_offset" >/dev/null 2>&1; then fail "out-of-order acknowledgement must fail"; fi
if "$WEB_INBOX" ack typed-1 "$second_offset" >/dev/null 2>&1; then fail "mismatched offset must fail"; fi
"$WEB_INBOX" reply typed-1 answer "The release fixes startup." || fail "reply should append to outbox"
"$WEB_INBOX" reply typed-1 answer "The release fixes startup." || fail "identical retry should be idempotent"
if "$WEB_INBOX" reply typed-1 fyi "different reply" >/dev/null 2>&1; then fail "a second different reply must fail"; fi

python3 - "$HOME_DIR/state/.outbox" <<'PY'
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
assert len(rows) == 1
assert rows[0]["in_reply_to"] == "typed-1"
assert rows[0]["kind"] == "answer"
assert rows[0]["text"] == "The release fixes startup."
PY

"$WEB_INBOX" ack typed-1 "$first_offset" || fail "first row should acknowledge"
seen=$(cat "$HOME_DIR/state/.inbox.seen")
[ "$seen" = "$first_offset" ] || fail "acknowledgement cursor should equal the first line end"
remaining=$("$WEB_INBOX" drain)
printf '%s\n' "$remaining" | grep -q '"id":"click-2"' || fail "second row should remain pending"
"$WEB_INBOX" ack click-2 "$second_offset" || fail "second row should acknowledge"
pending=0
"$WEB_INBOX" pending || pending=$?
[ "$pending" -eq 1 ] || fail "partial trailing line must not keep the mailbox pending"

rm "$HOME_DIR/state/.inbox.seen"
ln -s "$TMP_ROOT/missing" "$HOME_DIR/state/.inbox.seen"
if "$WEB_INBOX" ack typed-1 "$first_offset" >/dev/null 2>&1; then fail "symlink cursor must be refused"; fi

pass "browser mailbox reads complete rows, enforces ordered acknowledgements, and writes correlated replies"
