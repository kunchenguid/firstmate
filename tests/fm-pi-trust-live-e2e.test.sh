#!/usr/bin/env bash
# Opt-in credentialed proof that Pi shows its project-trust dialog in a fresh
# linked worktree, that --approve bypasses it for one run without persisting a
# decision, and that a fresh worker reaches its initial brief with no dialog
# after bin/fm-pi-trust.sh records the path in an isolated copy of Pi's store.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_PI_TRUST_LIVE_E2E pi tmux git node

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT=$(fm_test_tmproot fm-pi-trust-live)
SOCKET="fm-pi-trust-live-$$"
PROJECT="$TMP_ROOT/project"
CONTROL="$TMP_ROOT/control"
FLAG="$TMP_ROOT/flag"
TREATMENT="$TMP_ROOT/treatment"
AGENT_DIR="$TMP_ROOT/pi-agent"
MODEL=${FM_PI_TRUST_LIVE_MODEL:-}
PI_VERSION=$(pi --version)
MODEL_ARGS=()
[ -z "$MODEL" ] || MODEL_ARGS=(--model "$MODEL")

cleanup() {
  tmux -L "$SOCKET" kill-server 2>/dev/null || true
}
trap cleanup EXIT

capture() {
  tmux -L "$SOCKET" capture-pane -p -t "$1:0.0" -S -200 2>/dev/null || true
}

wait_for_text() {
  local session=$1 text=$2 i=0
  while [ "$i" -lt 120 ]; do
    capture "$session" | grep -Fq "$text" && return 0
    sleep 0.5
    i=$((i + 1))
  done
  capture "$session" >&2
  return 1
}

mkdir -p "$PROJECT/.pi/skills/trust-proof" "$AGENT_DIR"
printf '%s\n' '---' 'name: trust-proof' 'description: Trigger Pi project trust in the live guard.' '---' '# Trust proof' \
  > "$PROJECT/.pi/skills/trust-proof/SKILL.md"
printf 'fixture\n' > "$PROJECT/fixture"
git -C "$PROJECT" init -q
git -C "$PROJECT" config user.name 'Firstmate live test'
git -C "$PROJECT" config user.email firstmate-live@example.invalid
git -C "$PROJECT" add .
git -C "$PROJECT" commit -qm init
git -C "$PROJECT" worktree add -q -b trust-control "$CONTROL"
git -C "$PROJECT" worktree add -q -b trust-flag "$FLAG"
git -C "$PROJECT" worktree add -q -b trust-treatment "$TREATMENT"

# Keep credentials and model settings available while isolating the trust file.
for file in auth.json models.json settings.json; do
  [ ! -f "$HOME/.pi/agent/$file" ] || cp "$HOME/.pi/agent/$file" "$AGENT_DIR/$file"
done

# Control: an unseen linked worktree with project-local resources must stop on
# Pi's real trust dialog before any prompt can be processed.
tmux -L "$SOCKET" new-session -d -x 150 -y 44 -s control -c "$CONTROL" -- \
  env PI_CODING_AGENT_DIR="$AGENT_DIR" PI_OFFLINE=1 pi --no-session --no-context-files --no-extensions --no-skills
wait_for_text control 'Trust project folder?' || fail "Pi $PI_VERSION did not show the project-trust dialog in the unregistered control worktree"
capture control | grep -Fq "$CONTROL" || fail "Pi's trust dialog did not name the control worktree"
printf 'ok - real Pi %s shows the project-trust dialog in an unregistered linked worktree\n' "$PI_VERSION"
tmux -L "$SOCKET" kill-session -t control

# Candidate A: --approve must process the initial brief without showing the
# dialog, and its documented one-run decision must not appear in trust.json.
tmux -L "$SOCKET" new-session -d -x 150 -y 44 -s flag -c "$FLAG" -- \
  env PI_CODING_AGENT_DIR="$AGENT_DIR" PI_OFFLINE=1 pi --approve --no-session --no-context-files --no-extensions --no-skills \
  "${MODEL_ARGS[@]}" --thinking minimal 'Reply with the word formed by joining BRIEF and REACHED with a hyphen.'
wait_for_text flag 'BRIEF-REACHED' || fail "Pi $PI_VERSION did not process the --approve brief"
capture flag | grep -Fq 'Trust project folder?' \
  && fail "Pi $PI_VERSION showed the project-trust dialog despite --approve"
if [ -f "$AGENT_DIR/trust.json" ]; then
  node -e '
    const fs = require("node:fs");
    const store = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    process.exit(store[process.argv[2]] === undefined ? 0 : 1);
  ' "$AGENT_DIR/trust.json" "$FLAG" || fail "Pi persisted the --approve decision that should apply only to one run"
fi
printf 'ok - real Pi %s --approve bypasses the dialog for one run without persisting trust\n' "$PI_VERSION"
tmux -L "$SOCKET" kill-session -t flag

# Candidate B: record the fresh sibling through the production helper, then
# pass an initial brief. The expected reply does not occur in the prompt, so
# seeing it proves Pi processed the brief. Pane history proves the dialog never
# rendered.
PI_CODING_AGENT_DIR="$AGENT_DIR" "$ROOT/bin/fm-pi-trust.sh" "$TREATMENT" "$PROJECT" >/dev/null \
  || fail "fm-pi-trust.sh could not register the treatment worktree"
tmux -L "$SOCKET" new-session -d -x 150 -y 44 -s treatment -c "$TREATMENT" -- \
  env PI_CODING_AGENT_DIR="$AGENT_DIR" PI_OFFLINE=1 pi --no-session --no-context-files --no-extensions --no-skills \
  "${MODEL_ARGS[@]}" --thinking minimal 'Reply with the word formed by joining BRIEF and REACHED with a hyphen.'
wait_for_text treatment 'BRIEF-REACHED' || fail "Pi $PI_VERSION did not process the treatment brief"
capture treatment | grep -Fq 'Trust project folder?' \
  && fail "Pi $PI_VERSION still showed the project-trust dialog after pre-registration"
node -e '
  const fs = require("node:fs");
  const store = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  process.exit(store[process.argv[2]] === true ? 0 : 1);
' "$AGENT_DIR/trust.json" "$TREATMENT" || fail "Pi's isolated trust store lost the treatment entry"
printf 'ok - real Pi %s reaches its brief without the trust dialog after pre-registration\n' "$PI_VERSION"
