#!/usr/bin/env bash
# Opt-in real Herdr lab proof for the council lane's hard read-only boundary.
# It launches only a stub process and never calls a model provider.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ "${FM_COUNCIL_HERDR_E2E:-0}" != 1 ]; then
  echo "skip: set FM_COUNCIL_HERDR_E2E=1 for the guarded council Herdr lab proof"
  exit 0
fi
command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
[ "$(uname -s)-$(uname -m)" = Linux-x86_64 ] || { echo "skip: the council lane is Linux x86_64-only"; exit 0; }

HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name firstmate-council-mvp-pi-gpt56sol-u9)
TMP_ROOT=$(fm_test_tmproot fm-council-herdr)
SOURCE="$TMP_ROOT/source"
VIEW="$TMP_ROOT/view"
LANE="$TMP_ROOT/lane"
OTHER="$TMP_ROOT/other"
mkdir -p "$SOURCE" "$VIEW" "$LANE" "$OTHER"
printf 'source-private\n' > "$SOURCE/code"
printf 'fixed-view\n' > "$VIEW/code"
printf 'competing-answer\n' > "$OTHER/answer"

cleanup() {
  "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION"
  fm_test_cleanup
}
trap cleanup EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"

created=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" \
  workspace create --cwd "$LANE" --label fm-council-readonly-stub --no-focus)
workspace=$(jq -r '.result.workspace.workspace_id // empty' <<<"$created")
tab=$(jq -r '.result.tab.tab_id // empty' <<<"$created")
pane=$(jq -r '.result.root_pane.pane_id // empty' <<<"$created")
[ -n "$workspace" ] && [ -n "$tab" ] && [ -n "$pane" ] \
  || fail "real Herdr workspace create omitted exact endpoint IDs"
member_label="fm-council-member-readonly-stub"
"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" tab rename "$tab" "$member_label" >/dev/null
tab_info=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" tab get "$tab")
[ "$(jq -r '.result.tab.label' <<<"$tab_info")" = "$member_label" ] || fail "real Herdr tab lost its exact ownership label"

# shellcheck disable=SC2016  # positional parameters expand inside the sandboxed shell
printf -v command '%q ' \
  "$ROOT/bin/fm-council-sandbox.py" \
  --home "$LANE" \
  --readable "$VIEW" \
  --allow-exec /bin/sh \
  --allow-exec /bin/cat \
  --allow-exec /usr/bin/python3 \
  -- /bin/sh -c '
    {
      cat "$1/code" > "$2/read-view"
      if echo mutate > "$1/code"; then echo view-write-bad > "$2/view-write"; else echo view-write-denied > "$2/view-write"; fi
      if cat "$3/code" > "$2/source-read"; then echo source-read-bad > "$2/source-status"; else echo source-read-denied > "$2/source-status"; fi
      if echo mutate > "$3/code"; then echo source-write-bad >> "$2/source-status"; else echo source-write-denied >> "$2/source-status"; fi
      if cat "$4/answer" > "$2/other-answer"; then echo answer-read-bad > "$2/answer-status"; else echo answer-read-denied > "$2/answer-status"; fi
      if /usr/bin/python3 -c "import socket; socket.socket(socket.AF_UNIX)"; then echo unix-socket-bad > "$2/socket-status"; else echo unix-socket-denied > "$2/socket-status"; fi
      if /usr/bin/python3 -c "import socket; socket.socket(socket.AF_INET).close()"; then echo tcp-socket-allowed > "$2/tcp-status"; else echo tcp-socket-bad > "$2/tcp-status"; fi
      printf ready > "$2/ready"
    } 2> "$2/denials"
  ' sh "$VIEW" "$LANE" "$SOURCE" "$OTHER"
"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane run "$pane" "$command" >/dev/null

attempt=0
while [ ! -f "$LANE/ready" ] && [ "$attempt" -lt 100 ]; do
  sleep 0.1
  attempt=$((attempt + 1))
done
assert_present "$LANE/ready" "real Herdr stub did not finish the sandbox probe"
[ "$(cat "$LANE/read-view")" = fixed-view ] || fail "real Herdr lane could not read its fixed view"
[ "$(cat "$LANE/view-write")" = view-write-denied ] || fail "real Herdr lane wrote its fixed view"
assert_grep source-read-denied "$LANE/source-status" "real Herdr lane read the source project"
assert_grep source-write-denied "$LANE/source-status" "real Herdr lane wrote the source project"
[ "$(cat "$LANE/answer-status")" = answer-read-denied ] || fail "real Herdr lane read a competing answer"
[ "$(cat "$LANE/socket-status")" = unix-socket-denied ] || fail "real Herdr lane could open a terminal-control socket channel"
[ "$(cat "$LANE/tcp-status")" = tcp-socket-allowed ] || fail "real Herdr lane blocked provider-style TCP sockets"
[ "$(cat "$SOURCE/code")" = source-private ] || fail "real Herdr lane changed source bytes"

current=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane get "$pane")
[ "$(jq -r '.result.pane.workspace_id' <<<"$current")" = "$workspace" ] || fail "real Herdr pane moved to another workspace"
[ "$(jq -r '.result.pane.tab_id' <<<"$current")" = "$tab" ] || fail "real Herdr pane moved to another tab"
"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane close "$pane" >/dev/null
if "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane get "$pane" >/dev/null 2>&1; then
  fail "exact council stub pane remained after exact close"
fi

pass "real Herdr lab: exact council lane lifecycle enforces read-only source/view, answer isolation, and terminal-socket denial without a provider call"
