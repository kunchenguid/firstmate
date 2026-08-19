#!/usr/bin/env bash
# Behavior tests for T3 primary supervision (bind, Desktop stand-down,
# supervision model, ready-gated send helpers) with a mocked t3cli.
# Live e2e against a real T3 server is opt-in: FM_T3_PRIMARY_LIVE_E2E=1.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-t3-primary)
fm_git_identity fmtest fmtest@example.invalid

FAKEBIN=$(fm_fakebin "$TMP_ROOT/fakebin")

# Mock t3cli: controlled by files under $MOCK_T3
MOCK_T3="$TMP_ROOT/mock-t3"
mkdir -p "$MOCK_T3"
cat > "$FAKEBIN/t3cli" <<'EOF'
#!/usr/bin/env bash
set -u
ROOT=${FM_T3_MOCK_ROOT:?}
cmd=$1
shift || true
case "$cmd" in
  auth)
    cat "$ROOT/auth.json"
    exit 0
    ;;
  list)
    cat "$ROOT/list.json"
    exit 0
    ;;
  show)
    thread=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --thread) thread=$2; shift 2 ;;
        *) shift ;;
      esac
    done
    if [ -f "$ROOT/show-$thread.json" ]; then
      cat "$ROOT/show-$thread.json"
      exit 0
    fi
    echo "Thread $thread was not found" >&2
    exit 1
    ;;
  send)
    thread=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --thread) thread=$2; shift 2 ;;
        --format) shift 2 ;;
        --) shift; break ;;
        -*) shift ;;
        *) break ;;
      esac
    done
    msg=$*
    printf '%s\t%s\n' "$thread" "$msg" >> "$ROOT/sent.log"
    status=$(cat "$ROOT/status" 2>/dev/null || printf ready)
    if [ "$status" = running ]; then
      # Still accept (real t3cli queues); record only.
      printf '{"threadId":"%s","thread":{"session":{"status":"running"}}}\n' "$thread"
      exit 0
    fi
    printf '{"threadId":"%s","thread":{"session":{"status":"running"}}}\n' "$thread"
    exit 0
    ;;
  *)
    echo "unexpected t3cli $cmd" >&2
    exit 2
    ;;
esac
EOF
chmod +x "$FAKEBIN/t3cli"
export PATH="$FAKEBIN:$PATH"
export FM_T3_MOCK_ROOT="$MOCK_T3"

printf '%s\n' '{"authenticated":true,"role":"owner"}' > "$MOCK_T3/auth.json"
printf '%s\n' 'ready' > "$MOCK_T3/status"

THREAD=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
SID=11111111-2222-3333-4444-555555555555
printf '%s\n' "[{
  \"id\": \"$THREAD\",
  \"latestTurn\": {\"assistantMessageId\": \"assistant:assistant:$SID:runtime:x:segment:0\"},
  \"session\": {\"status\": \"ready\"}
}]" > "$MOCK_T3/list.json"
printf '%s\n' "{
  \"id\": \"$THREAD\",
  \"projectId\": \"proj-1\",
  \"status\": \"ready\",
  \"session\": {\"threadId\": \"$THREAD\", \"status\": \"ready\"}
}" > "$MOCK_T3/show-$THREAD.json"

install_scripts() {
  local dir=$1 f
  mkdir -p "$dir/bin" "$dir/docs/supervision-protocols" "$dir/config" "$dir/state"
  for f in fm-t3-primary-lib.sh fm-t3-primary-bind.sh fm-t3-primary-park.sh \
           fm-turnend-guard-cursor.sh fm-turnend-guard.sh \
           fm-primary-scope-lib.sh fm-supervision-lib.sh fm-wake-lib.sh \
           fm-session-lock-lib.sh fm-cursor-lib.sh fm-operational-input.sh \
           fm-supervision-instructions.sh fm-harness.sh fm-lock.sh \
           fm-watch-arm.sh fm-watch.sh; do
    [ -f "$ROOT/bin/$f" ] || continue
    cp "$ROOT/bin/$f" "$dir/bin/$f"
  done
  cp "$ROOT/docs/supervision-protocols/"*.md "$dir/docs/supervision-protocols/" 2>/dev/null || true
  chmod +x "$dir"/bin/*.sh
}

make_home() {
  local dir=$1
  mkdir -p "$dir/state" "$dir/config"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  install_scripts "$dir"
  printf '%s\n' "$dir"
}

# --- inactive without opt-in ---
HOME1=$(make_home "$TMP_ROOT/home1")
out=$(FM_HOME="$HOME1" FM_STATE_OVERRIDE="$HOME1/state" FM_CONFIG_OVERRIDE="$HOME1/config" \
  "$HOME1/bin/fm-t3-primary-bind.sh" 2>&1) || fail "bind inactive should exit 0: $out"
printf '%s\n' "$out" | grep -q 'inactive' || fail "expected inactive: $out"

# --- bind with opt-in + session match ---
HOME2=$(make_home "$TMP_ROOT/home2")
: > "$HOME2/config/t3-primary"
out=$(CURSOR_CONVERSATION_ID="$SID" FM_HOME="$HOME2" FM_STATE_OVERRIDE="$HOME2/state" FM_CONFIG_OVERRIDE="$HOME2/config" \
  "$HOME2/bin/fm-t3-primary-bind.sh" 2>&1) || fail "bind failed: $out"
grep -q "thread=$THREAD" <<<"$out" || fail "bind output missing thread: $out"
grep -q "^thread_id=$THREAD$" "$HOME2/state/.t3-primary-binding" || fail "binding file missing thread"
grep -q "^cursor_session_id=$SID$" "$HOME2/state/.t3-primary-binding" || fail "binding file missing session"

# --- supervision model persistent when bound ---
# shellcheck source=bin/fm-wake-lib.sh
STATE="$HOME2/state" FM_HOME="$HOME2" FM_STATE_OVERRIDE="$HOME2/state" \
  . "$HOME2/bin/fm-wake-lib.sh"
model=$(FM_HOME="$HOME2" FM_STATE_OVERRIDE="$HOME2/state" STATE="$HOME2/state" \
  bash -c '. "'"$HOME2"'/bin/fm-wake-lib.sh"; fm_supervision_model')
[ "$model" = persistent ] || fail "expected persistent model, got $model"

# --- Desktop cursor park stands down when bound ---
payload='{"session_id":"sess","loop_count":0,"status":"completed","hook_event_name":"stop","cursor_version":"x"}'
# Without session lock the park exits 0 anyway; binding stand-down is earlier.
# Prove binding path exits 0 with empty follow-up even if supervision would be needed.
mkdir -p "$HOME2/state"
printf '1\n' > "$HOME2/state/.lock"
out=$(printf '%s' "$payload" | FM_HOME="$HOME2" FM_STATE_OVERRIDE="$HOME2/state" \
  "$HOME2/bin/fm-turnend-guard-cursor.sh" 2>/dev/null || true)
[ -z "$out" ] || fail "expected empty stand-down output, got: $out"

# --- unbound home: binding is what flips model to persistent ---
HOME3=$(make_home "$TMP_ROOT/home3")
[ ! -f "$HOME3/state/.t3-primary-binding" ] || fail "unexpected binding"
printf 'thread_id=%s\ncursor_session_id=%s\nbound_at=1\nbound_by=test\nseq=1\n' "$THREAD" "$SID" \
  > "$HOME3/state/.t3-primary-binding"
model_bound=$(STATE="$HOME3/state" FM_HOME="$HOME3" bash -c '. "'"$HOME3"'/bin/fm-wake-lib.sh"; fm_supervision_model')
[ "$model_bound" = persistent ] || fail "bound home should be persistent, got $model_bound"

# --- wait_ready stands down on running ---
# shellcheck source=bin/fm-t3-primary-lib.sh
. "$HOME2/bin/fm-t3-primary-lib.sh"
printf '%s\n' "{
  \"id\": \"$THREAD\",
  \"session\": {\"status\": \"running\"}
}" > "$MOCK_T3/show-$THREAD.json"
fm_t3_primary_wait_ready "$THREAD" 2
rc=$?
[ "$rc" -eq 2 ] || fail "expected wait_ready rc=2 on running, got $rc"

# restore ready
printf '%s\n' "{
  \"id\": \"$THREAD\",
  \"projectId\": \"proj-1\",
  \"status\": \"ready\",
  \"session\": {\"threadId\": \"$THREAD\", \"status\": \"ready\"}
}" > "$MOCK_T3/show-$THREAD.json"
fm_t3_primary_wait_ready "$THREAD" 5
rc=$?
[ "$rc" -eq 0 ] || fail "expected wait_ready rc=0 on ready, got $rc"

# --- encode + send records message ---
: > "$MOCK_T3/sent.log"
body=$(fm_t3_primary_encode_followup watcher "test wake body")
printf '%s' "$body" | grep -q 'FIRSTMATE_OP' || fail "encoded body missing operational mark"
fm_t3_primary_send "$THREAD" "$body" >/dev/null
grep -q "$THREAD" "$MOCK_T3/sent.log" || fail "send not logged"

# --- supervision instructions pick t3 protocol when bound ---
out=$(FM_HOME="$HOME2" FM_STATE_OVERRIDE="$HOME2/state" FM_CONFIG_OVERRIDE="$HOME2/config" \
  "$HOME2/bin/fm-supervision-instructions.sh" --harness cursor 2>&1)
printf '%s\n' "$out" | grep -q 't3 host' || fail "expected t3 host label: $out"
printf '%s\n' "$out" | grep -q 'fm-t3-primary-park' || fail "expected t3 park mention: $out"

# --- clear ---
FM_HOME="$HOME2" FM_STATE_OVERRIDE="$HOME2/state" "$HOME2/bin/fm-t3-primary-bind.sh" --clear >/dev/null
[ ! -f "$HOME2/state/.t3-primary-binding" ] || fail "binding not cleared"

pass "fm-t3-primary tests"
