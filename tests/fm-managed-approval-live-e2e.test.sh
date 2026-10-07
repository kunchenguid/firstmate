#!/usr/bin/env bash
# Opt-in live managed-policy probe. The classifier verdict must come from real
# current CLIs, not a synthetic vendor transcript. Runs only where the operator
# expects the policy described in docs/verification/runtime-backends.md.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_MANAGED_APPROVAL_LIVE tmux codex claude
TMP_ROOT=$(fm_test_tmproot fm-managed-approval-live)
CODEX_VERSION=$(codex --version)
CLAUDE_VERSION=$(claude --version)
SOCKET="fm-managed-approval-$$"
cleanup() {
  tmux -L "$SOCKET" kill-server 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
PROMPT='You are a launch-mode verification worker, not a supervisor. Do not run session startup, supervise, or delegate. Run pwd -P exactly once with your shell tool, then reply OK. Do not edit files.'
printf 'exec env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS FM_TASK_ID=managed-approval-live-probe codex --dangerously-bypass-approvals-and-sandbox --disable hooks %q\n' "$PROMPT" > "$TMP_ROOT/codex-launch.sh"
tmux -L "$SOCKET" -f /dev/null new-session -d -s probe -x 180 -y 48 -c "$ROOT" -- bash --noprofile --norc
tmux -L "$SOCKET" set-option -w -t probe remain-on-exit on
printf -v RAW_SINK 'cat > %q' "$TMP_ROOT/codex.raw"
tmux -L "$SOCKET" pipe-pane -t probe "$RAW_SINK"
printf -v LAUNCH 'exec bash %q' "$TMP_ROOT/codex-launch.sh"
tmux -L "$SOCKET" send-keys -t probe -l -- "$LAUNCH"
tmux -L "$SOCKET" send-keys -t probe Enter
deadline=$(( $(date +%s) + 120 ))
while :; do
  tmux -L "$SOCKET" capture-pane -p -t probe > "$TMP_ROOT/codex.txt"
  if "$ROOT/bin/fm-approval-failover.sh" classify codex < "$TMP_ROOT/codex.txt" >/dev/null; then
    break
  fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    tail -c 6000 "$TMP_ROOT/codex.raw" >&2
    fail "codex $CODEX_VERSION: managed bypass did not show the recognized approval prompt in a rendered viewport"
  fi
  sleep 1
done
printf 'ok - %s live bypass refusal matches the approval classifier\n' "$CODEX_VERSION"
tmux -L "$SOCKET" kill-server
# Print mode exercises the actual policy request without sending shell tools.
env -u CLAUDECODE FM_TASK_ID=managed-approval-live-probe claude -p \
  --dangerously-skip-permissions --output-format text 'Reply OK without tools.' > "$TMP_ROOT/claude.txt" 2>&1 || true
"$ROOT/bin/fm-approval-failover.sh" classify claude < "$TMP_ROOT/claude.txt" >/dev/null \
  || fail "claude $CLAUDE_VERSION: managed bypass did not expose the policy 403; generic auth errors must not cause failover"
printf 'ok - %s live policy refusal matches the 403 classifier\n' "$CLAUDE_VERSION"
echo "# all fm-managed-approval-live-e2e tests passed"
