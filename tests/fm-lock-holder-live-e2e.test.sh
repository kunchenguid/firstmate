#!/usr/bin/env bash
# Default-on live guard for naming a Claude-shaped session-lock holder.
#
# bin/fm-session-lock-lib.sh's fm_session_lock_holder_lines reads the vendor's
# `claude agents --json` rows (pid, sessionId, kind, name, status, and a
# background row's short id and state) to name the holder in a lock refusal
# and in `fm-lock.sh status`. A stub can only confirm the shape written into
# it, so this guard asks the REAL installed claude for its rows, checks the
# fields the lookup depends on, and drives the real fm-lock.sh status against
# a throwaway home whose lock records a real listed session. It fails naming
# the Claude Code version rather than letting the lookup degrade quietly into
# today's unnamed diagnostic.
#
# `claude agents --json` is read-only and submits no prompt, so the shared live
# gate runs this guard by default wherever claude and jq exist. Rerun it after
# every Claude Code upgrade and before trusting a refreshed
# docs/verification/runtime-backends.md "Session-lock holder naming" entry.
# shellcheck disable=SC2016 # single quotes are deliberate: $FM_LOCK expands inside the fake session
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_LOCK_HOLDER_LIVE_E2E claude jq

TMP_ROOT=$(fm_test_tmproot fm-lock-holder-live)
VERSION=$(claude --version 2>/dev/null | head -n 1)
[ -n "$VERSION" ] || VERSION=unknown

rows=$(claude agents --json 2>/dev/null </dev/null) \
  || fail "claude $VERSION: claude agents --json exited non-zero"
printf '%s' "$rows" | jq -e 'type == "array"' >/dev/null 2>&1 \
  || fail "claude $VERSION: claude agents --json is no longer a JSON array"

# The session running this guard must have a row; any background row is also
# checked, because only a background row carries the short id and state the
# stop command depends on. With no row at all there is nothing to name.
selected=''
if [ -n "${CLAUDE_PID:-}" ]; then
  self_row=$(printf '%s' "$rows" | jq -c --arg pid "$CLAUDE_PID" '[ .[] | select((.pid | tostring) == $pid) ][0] // empty')
  [ -n "$self_row" ] || fail "claude $VERSION: the running session (CLAUDE_PID=$CLAUDE_PID) has no claude agents row"
  selected=$self_row
fi
background_row=$(printf '%s' "$rows" | jq -c '[ .[] | select(.kind == "background") ][0] // empty')
[ -z "$background_row" ] || selected=$(printf '%s\n%s' "$selected" "$background_row")
[ -n "$selected" ] || selected=$(printf '%s' "$rows" | jq -c '.[0] // empty')
if [ -z "$selected" ]; then
  echo "skip: live: claude $VERSION lists no session, so no holder could be named"
  exit 0
fi

fakebin=$(fm_fakebin "$TMP_ROOT/asker")
ln -s /bin/bash "$fakebin/claude"

checked=''
check_row() {  # <row-json>
  local row=$1 pid sid kind id home out
  printf '%s' "$row" | jq -e '
    (.pid | type == "number") and (.sessionId | type == "string")
    and (.kind == "interactive" or .kind == "background")
    and (.name | type == "string") and (.status | type == "string")
    and (if .kind == "background" then (.id | type == "string") and (.state | type == "string") else true end)
  ' >/dev/null || fail "claude $VERSION: a claude agents row lost a field the holder lookup reads: $row"
  pid=$(printf '%s' "$row" | jq -r '.pid')
  sid=$(printf '%s' "$row" | jq -r '.sessionId')
  kind=$(printf '%s' "$row" | jq -r '.kind')
  id=$(printf '%s' "$row" | jq -r '.id // empty')

  home="$TMP_ROOT/home-$pid"
  mkdir -p "$home/state"
  printf '%s\n' "$pid" > "$home/state/.lock"
  printf '%s\n' "$sid" > "$home/state/.lock-session"
  # Ask from inside a separate fake Claude session so the answer is "another
  # session" whatever session runs this guard.
  out=$(env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID FM_HOME="$home" FM_LOCK="$ROOT/bin/fm-lock.sh" \
    "$fakebin/claude" -c '"$FM_LOCK" status 2>&1; :')

  assert_contains "$out" "lock: held by live harness pid $pid (another session; session $sid)" \
    "claude $VERSION: status did not classify the real listed session as another session's live lock"
  assert_contains "$out" "lock holder: Claude Code $kind session \"" \
    "claude $VERSION: the real $kind session was not named from its claude agents row"
  if [ "$kind" = background ]; then
    assert_contains "$out" "claude stop $id" "claude $VERSION: the real background session's stop command is missing"
  fi
  assert_not_contains "$out" "lists no session" "claude $VERSION: a listed session was reported as unlisted"
  printf '# claude %s: named a real %s session from claude agents --json\n' "$VERSION" "$kind"
  checked="$checked $kind"
}

while IFS= read -r row; do
  [ -n "$row" ] && check_row "$row"
done <<EOF
$selected
EOF
[ -n "$checked" ] || fail "claude $VERSION: no session row was checked"
pass "lock holder: claude $VERSION names real session-lock holders from claude agents --json (checked:$checked)"
