#!/usr/bin/env bash
# Opt-in real-Pi regression for a post-start AGENTS.md update followed by
# compaction. It runs an isolated Herdr session, throwaway Firstmate checkout,
# and scratch FM_HOME, so it never drives the caller's Pi session or fleet.
#
# The portable session-start tests own baseline and output logic. This guard
# proves the vendor-dependent fact they cannot: Pi's actual session_compact
# event delivers the current complete instruction file into the rebuilt model
# context after the native cached session-start copy would otherwise persist.
#
# Run after Pi upgrades and before recording refreshed verification evidence:
#
#   FM_SESSIONSTART_INSTRUCTION_REFRESH_LIVE_E2E=1 \
#     tests/fm-sessionstart-instruction-refresh-live-e2e.test.sh
#
# To reproduce a historical stale implementation before verifying the fixed
# branch, select a ref that lacks this change and expect the old marker:
#
#   FM_SESSIONSTART_INSTRUCTION_REFRESH_LIVE_E2E=1 \
#   FM_SESSIONSTART_INSTRUCTION_REFRESH_REF=origin/main \
#   FM_SESSIONSTART_INSTRUCTION_REFRESH_EXPECT=stale \
#     tests/fm-sessionstart-instruction-refresh-live-e2e.test.sh
#
# This costs real Pi model turns and requires its normal authenticated profile.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_SESSIONSTART_INSTRUCTION_REFRESH_LIVE_E2E pi herdr jq git

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane
HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
CLEAN_PATH=$PATH
SESSION=$("$HELPER" name "${FM_HERDR_LAB_TASK:-instruction-refresh}") || exit 1
PANE=
LAB=${TMPDIR:-/tmp}
LAB="${LAB%/}/fm-sessionstart-instruction-refresh-live-e2e.$$"
PROJECT="$LAB/project"
PI_SESSION="$LAB/pi-session.jsonl"
HOME_DIR="$LAB/home"
NONCE=$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')
OLD_MARKER="AGENTS_MARKER=old-$NONCE"
NEW_MARKER="AGENTS_MARKER=new-$NONCE"
READY_MARKER="INSTRUCTION_REFRESH_READY=$NONCE"
TEST_REF=${FM_SESSIONSTART_INSTRUCTION_REFRESH_REF:-HEAD}
TEST_COMMIT=$(git -C "$ROOT" rev-parse --verify "$TEST_REF^{commit}" 2>/dev/null) || {
  printf 'not ok - could not resolve isolated test ref %s\n' "$TEST_REF" >&2
  exit 2
}
EXPECTATION=${FM_SESSIONSTART_INSTRUCTION_REFRESH_EXPECT:-updated}
case "$EXPECTATION" in
  updated|stale) ;;
  *) printf 'not ok - expected FM_SESSIONSTART_INSTRUCTION_REFRESH_EXPECT=updated or stale, got: %s\n' "$EXPECTATION" >&2; exit 2 ;;
esac

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

capture() {
  "$HELPER" run "$SESSION" pane read "$PANE" --source recent --lines 500 2>/dev/null || true
}

wait_for_text() {  # <text> [attempts]
  local expected=$1 attempts=${2:-90} attempt=0
  while [ "$attempt" -lt "$attempts" ]; do
    capture | grep -Fq "$expected" && return 0
    sleep 2
    attempt=$((attempt + 1))
  done
  return 1
}

wait_for_file() {  # <path> [attempts]
  local path=$1 attempts=${2:-90} attempt=0
  while [ "$attempt" -lt "$attempts" ]; do
    [ -s "$path" ] && return 0
    sleep 2
    attempt=$((attempt + 1))
  done
  return 1
}

# Read completed assistant messages, not the echoed prompt or an in-flight
# partial response. Compacting after a prompt echo can abort the very turn
# intended to push the cached instruction out of the recent context window.
answer_count() {  # <exact answer or response suffix>
  [ -f "$PI_SESSION" ] || { printf '0'; return; }
  jq -rs --arg expected "$1" '
    [.[] | select(.type == "message") | .message
      | select(.role == "assistant" and .stopReason == "stop")
      | [.content[]? | select(.type == "text") | .text] | join("\n")
      | select(endswith($expected))] | length
  ' "$PI_SESSION" 2>/dev/null || printf '0'
}

wait_for_answer() {  # <answer> [attempts] [minimum-count]
  local expected=$1 attempts=${2:-120} minimum=${3:-1} attempt=0 count
  while [ "$attempt" -lt "$attempts" ]; do
    count=$(answer_count "$expected")
    [ "$count" -ge "$minimum" ] && return 0
    sleep 2
    attempt=$((attempt + 1))
  done
  return 1
}

send_line() {  # <text>
  "$HELPER" run "$SESSION" pane send-text "$PANE" "$1"
  sleep 1
  "$HELPER" run "$SESSION" pane send-keys "$PANE" Enter
}

cleanup() {
  PATH="$CLEAN_PATH" "$HELPER" teardown "$SESSION" || exit 1
  rm -rf "$LAB"
}
trap cleanup EXIT INT TERM

mkdir -p "$LAB"
git clone --quiet --no-hardlinks "$ROOT" "$PROJECT" || fail "could not create isolated Firstmate checkout"
git -C "$PROJECT" checkout -q -B main "$TEST_COMMIT" \
  || fail "could not check out isolated test ref $TEST_REF ($TEST_COMMIT)"
git -C "$PROJECT" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main \
  || fail "could not set the isolated checkout's default branch"
if [ "$TEST_REF" = HEAD ]; then
  git -C "$ROOT" diff --binary HEAD | git -C "$PROJECT" apply --allow-empty
fi
git -C "$PROJECT" config user.email fmtest@example.invalid
git -C "$PROJECT" config user.name fmtest
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config"
# Preserve the production wrapper's argv and exec it unchanged, while recording
# the Pi extension's actual event source in this scratch home for the E2E gate.
mv "$PROJECT/bin/fm-sessionstart-run.sh" "$PROJECT/bin/.fm-sessionstart-run.real.sh"
cat > "$PROJECT/bin/fm-sessionstart-run.sh" <<'SH'
#!/usr/bin/env bash
set -o pipefail
set -u
state="${FM_HOME:?}/state"
printf 'argv=%s pi=%s root=%s home=%s\n' "$*" "${PI_CODING_AGENT:-absent}" "${FM_ROOT_OVERRIDE:-absent}" "${FM_HOME:-absent}" \
  >> "$state/.sessionstart-e2e-sources"
"$(dirname "$0")/.fm-sessionstart-run.real.sh" "$@" | tee -a "$state/.sessionstart-e2e-output"
exit "${PIPESTATUS[0]}"
SH
chmod +x "$PROJECT/bin/fm-sessionstart-run.sh"
cat > "$PROJECT/AGENTS.md" <<EOF
When asked exactly "Which validation contract marker is active?", reply with exactly "$OLD_MARKER" and no other text.
EOF
git -C "$PROJECT" add AGENTS.md
git -C "$PROJECT" commit -q -m "test: initial instruction contract" || fail "could not commit initial instruction contract"
printf '%s\n' '{"compaction":{"keepRecentTokens":200}}' > "$PROJECT/.pi/settings.json"

"$HELPER" provision "$SESSION" || fail 'could not provision isolated Herdr lab'
herdr_test_guard_cli "$SESSION" "$LAB/shim" "$HELPER" || fail 'lab guard failed'
export PATH="$LAB/shim:$PATH" HERDR_SESSION="$SESSION"
created=$("$HELPER" run "$SESSION" workspace create --cwd "$PROJECT" --label instruction-refresh --no-focus) \
  || fail 'could not start isolated Pi session'
PANE=$(printf '%s' "$created" | jq -r '.result.root_pane.pane_id // empty')
[ -n "$PANE" ] || fail 'could not start isolated Pi session'
"$HELPER" run "$SESSION" terminal session control "$PANE" --cols 160 --rows 44 </dev/null >/dev/null || fail 'could not size lab viewport'
printf -v launch '%q ' env "FM_HOME=$HOME_DIR" "FM_ROOT_OVERRIDE=$PROJECT" \
  pi --approve --no-tools --session "$PI_SESSION" -e "$PROJECT/.pi/extensions/fm-primary-turnend-guard.ts"
"$HELPER" run "$SESSION" pane run "$PANE" "$launch" || fail 'could not start isolated Pi session'

# Pi may ask for project trust before project-local context files and extensions
# take effect. Accept only the isolated lab's prompt, then wait for the old
# instruction's observable behavior rather than assuming startup completed.
for _ in $(seq 1 30); do
  if capture | grep -qiE 'trust (this|the|parent)?[[:space:]]*(folder|project)'; then
    "$HELPER" run "$SESSION" pane send-keys "$PANE" Enter
  fi
  sleep 1
done

wait_for_text 'gpt-' 120 || fail 'Pi model footer did not become ready'
send_line 'Which validation contract marker is active?'
wait_for_answer "$OLD_MARKER" 120 || {
  capture >&2
  fail "Pi did not apply the initial AGENTS.md contract"
}
wait_for_file "$HOME_DIR/state/.sessionstart-e2e-sources" 120 || {
  capture >&2
  fail "Pi extension did not invoke the real session-start wrapper"
}
grep -Fqx -- 'argv=--source startup --pi-prerequisite pi=true root='"$PROJECT"' home='"$HOME_DIR" "$HOME_DIR/state/.sessionstart-e2e-sources" >/dev/null || {
  capture >&2
  printf '# Pi session-start sources:\n' >&2
  cat "$HOME_DIR/state/.sessionstart-e2e-sources" >&2
  fail "Pi E2E did not begin from true source=startup"
}
if [ "$EXPECTATION" = updated ]; then
  wait_for_file "$HOME_DIR/state/.session-start-agents-baseline" 120 || {
    capture >&2
    printf '# Pi session-start sources:\n' >&2
    cat "$HOME_DIR/state/.sessionstart-e2e-sources" >&2
    printf '# isolated state files:\n' >&2
    find "$HOME_DIR/state" -maxdepth 1 -type f -print -exec sh -c 'printf "%s: " "$1"; head -n 2 "$1"' _ {} \; >&2
    fail "Pi did not complete true-start instruction baseline recording"
  }
else
  [ ! -e "$HOME_DIR/state/.session-start-agents-baseline" ] \
    || fail "stale reference unexpectedly recorded an instruction baseline"
fi

cat > "$PROJECT/AGENTS.md" <<EOF
When asked exactly "Which validation contract marker is active?", reply with exactly "$NEW_MARKER" and no other text.
EOF
git -C "$PROJECT" add AGENTS.md
git -C "$PROJECT" commit -q -m "test: updated instruction contract" || fail "could not commit updated instruction contract"

send_line "Write at least 1800 words of varied prose about maintaining reliable session state. End with exactly $READY_MARKER."
wait_for_answer "$READY_MARKER" 360 || {
  capture >&2
  fail "Pi did not complete the substantial pre-compaction turn"
}
sleep 3
send_line /compact
wait_for_text 'Compacted from' 120 || {
  capture >&2
  fail "Pi did not complete a real compaction"
}

if [ "$EXPECTATION" = updated ]; then
  send_line 'Which validation contract marker is active?'
  wait_for_answer "$NEW_MARKER" 120 || {
    capture >&2
    printf '# compact delivery records:\n' >&2
    grep -F -A5 -B2 'CURRENT AGENTS.md - INSTRUCTION REFRESH' "$HOME_DIR/state/.sessionstart-e2e-output" >&2 || true
    printf '# session-start invocation records:\n' >&2
    cat "$HOME_DIR/state/.sessionstart-e2e-sources" >&2
    fail "Pi retained the stale session-start AGENTS.md contract after compaction"
  }
  [ -f "$HOME_DIR/state/.session-start-agents-baseline" ] \
    || fail "Pi startup did not record the true-start instruction baseline"
  [ "$(sed -n '2p' "$HOME_DIR/state/.session-start-agents-baseline")" != "$(shasum -a 256 "$PROJECT/AGENTS.md" | awk '{print "sha256:" $1}')" ] \
    || fail "Pi compaction rewrote the true-start instruction baseline"
  pass "Pi $(pi --version 2>/dev/null | head -n 1) re-injects updated AGENTS.md after a real compact in an isolated session"
else
  old_reply_count=$(answer_count "$OLD_MARKER")
  send_line 'Which validation contract marker is active?'
  wait_for_answer "$OLD_MARKER" 120 "$((old_reply_count + 1))" || {
    capture >&2
    fail "stale reference did not preserve the original AGENTS.md contract after compaction"
  }
  pass "Pi $(pi --version 2>/dev/null | head -n 1) reproduces stale AGENTS.md after a real compact"
fi
echo "# fm-sessionstart-instruction-refresh-live-e2e.test.sh: all live assertions passed"
