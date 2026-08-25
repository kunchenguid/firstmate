#!/usr/bin/env bash
# Opt-in real-Pi regression for a post-start AGENTS.md update followed by
# compaction. It runs an isolated tmux server, throwaway Firstmate checkout,
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

if [ "${FM_SESSIONSTART_INSTRUCTION_REFRESH_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_SESSIONSTART_INSTRUCTION_REFRESH_LIVE_E2E=1 to run the isolated real-Pi instruction-refresh regression"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMUX_SOCKET="fm-sessionstart-instruction-refresh-$$"
TMUX_SESSION="instruction-refresh"
LAB=${TMPDIR:-/tmp}
LAB="${LAB%/}/fm-sessionstart-instruction-refresh-live-e2e.$$"
PROJECT="$LAB/project"
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
  tmux -L "$TMUX_SOCKET" capture-pane -p -t "$TMUX_SESSION" -S -500 2>/dev/null || true
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

wait_for_line_count() {  # <text> <minimum-count> [attempts]
  local expected=$1 minimum=$2 attempts=${3:-90} attempt=0 count
  while [ "$attempt" -lt "$attempts" ]; do
    count=$(capture | grep -Fc "$expected" || true)
    [ "$count" -ge "$minimum" ] && return 0
    sleep 2
    attempt=$((attempt + 1))
  done
  return 1
}

send_line() {  # <text>
  tmux -L "$TMUX_SOCKET" send-keys -t "$TMUX_SESSION" -l "$1"
  sleep 1
  tmux -L "$TMUX_SOCKET" send-keys -t "$TMUX_SESSION" Enter
}

cleanup() {
  tmux -L "$TMUX_SOCKET" kill-server >/dev/null 2>&1 || true
  rm -rf "$LAB"
}
trap cleanup EXIT INT TERM

command -v pi >/dev/null 2>&1 || fail "pi not found"
command -v tmux >/dev/null 2>&1 || fail "tmux not found"
command -v git >/dev/null 2>&1 || fail "git not found"

mkdir -p "$LAB"
git clone --quiet --no-hardlinks "$ROOT" "$PROJECT" || fail "could not create isolated Firstmate checkout"
git -C "$PROJECT" checkout -q -B main "$TEST_COMMIT" \
  || fail "could not check out isolated test ref $TEST_REF ($TEST_COMMIT)"
git -C "$PROJECT" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main \
  || fail "could not set the isolated checkout's default branch"
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

tmux -L "$TMUX_SOCKET" new-session -d -s "$TMUX_SESSION" -c "$PROJECT" -x 220 -y 55 \
  -e "FM_HOME=$HOME_DIR" -e "FM_ROOT_OVERRIDE=$PROJECT" -e "FM_GATE_REFUSE_BYPASS=1" \
  pi --no-tools -e "$PROJECT/.pi/extensions/fm-primary-turnend-guard.ts" \
  || fail "could not start isolated Pi session"

# Pi may ask for project trust before project-local context files and extensions
# take effect. Accept only the isolated lab's prompt, then wait for the old
# instruction's observable behavior rather than assuming startup completed.
for _ in $(seq 1 30); do
  if capture | grep -qiE 'trust (this|the|parent)?[[:space:]]*(folder|project)'; then
    tmux -L "$TMUX_SOCKET" send-keys -t "$TMUX_SESSION" Enter
  fi
  sleep 1
done

send_line 'Which validation contract marker is active?'
wait_for_text "$OLD_MARKER" 120 || {
  capture >&2
  fail "Pi did not apply the initial AGENTS.md contract"
}
wait_for_file "$HOME_DIR/state/.sessionstart-e2e-sources" 120 || {
  capture >&2
  fail "Pi extension did not invoke the real session-start wrapper"
}
grep -Fqx -- 'argv=--source startup pi=true root='"$PROJECT"' home='"$HOME_DIR" "$HOME_DIR/state/.sessionstart-e2e-sources" >/dev/null || {
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
wait_for_text "$READY_MARKER" 360 || {
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
  wait_for_text "$NEW_MARKER" 120 || {
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
  old_reply_count=$(capture | grep -Fc "$OLD_MARKER" || true)
  send_line 'Which validation contract marker is active?'
  wait_for_line_count "$OLD_MARKER" "$((old_reply_count + 1))" 120 || {
    capture >&2
    fail "stale reference did not preserve the original AGENTS.md contract after compaction"
  }
  pass "Pi $(pi --version 2>/dev/null | head -n 1) reproduces stale AGENTS.md after a real compact"
fi
echo "# fm-sessionstart-instruction-refresh-live-e2e.test.sh: all live assertions passed"
