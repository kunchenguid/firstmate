#!/usr/bin/env bash
# Opt-in credentialed Codex regression proving explicit writable roots preserve
# the narrow worker boundary while enabling Firstmate status, report, linked
# worktree Git operations, and a read-only no-mistakes socket connection under
# an effective workspace-write sandbox.
set -u

if [ "${FM_CODEX_WRITABLE_ROOTS_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_CODEX_WRITABLE_ROOTS_LIVE_E2E=1 to run the Codex writable-roots regression"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

command -v codex >/dev/null 2>&1 || fail "codex not found"
command -v no-mistakes >/dev/null 2>&1 || fail "no-mistakes not found"

if [ -n "${NM_HOME:-}" ]; then
  NO_MISTAKES_CANDIDATE=$NM_HOME
elif [ -n "${HOME:-}" ]; then
  NO_MISTAKES_CANDIDATE="$HOME/.no-mistakes"
else
  fail "neither NM_HOME nor HOME can select the no-mistakes root"
fi
NO_MISTAKES_ROOT=$(CDPATH='' cd -- "$NO_MISTAKES_CANDIDATE" 2>/dev/null && pwd -P) \
  || fail "the selected no-mistakes root is not an existing directory"
[ -S "$NO_MISTAKES_ROOT/socket" ] || fail "the selected no-mistakes root has no live Unix socket"
export NM_HOME=$NO_MISTAKES_ROOT

LAB="${TMPDIR:-/tmp}/fm-codex-writable-roots-live-e2e.$$"
HOME_LAB="$ROOT/.codex-writable-roots-live-e2e-home.$$"
PROJECT="$LAB/project"
WORKTREE="$LAB/worktree"
STATE="$HOME_LAB/state"
REPORT="$HOME_LAB/data/proof-task"
SIBLING="$HOME_LAB/data/sibling-task"
CONTROL_TRANSCRIPT="$LAB/control.jsonl"
PROOF_TRANSCRIPT="$LAB/proof.jsonl"
CODEX_VERSION=$(codex --version)
# shellcheck disable=SC2016 # Backticks are literal prompt markup.
CONTROL_PROMPT='Run exactly `./control.sh`. Do not alter it. Reply with its final output marker.'
# shellcheck disable=SC2016 # Backticks are literal prompt markup.
PROOF_PROMPT='Run exactly `./probe.sh`. Do not alter it. Reply with its final output marker.'

cleanup() {
  rm -rf "$LAB" "$HOME_LAB"
}
trap cleanup EXIT

mkdir -p "$PROJECT" "$STATE" "$REPORT" "$SIBLING"
git -C "$PROJECT" init -q -b main
printf 'fixture\n' > "$PROJECT/README.md"
git -C "$PROJECT" add README.md
git -C "$PROJECT" commit -q -m "Initialize writable-roots fixture"
git -C "$PROJECT" worktree add -q --detach "$WORKTREE"

cat > "$WORKTREE/control.sh" <<SH
#!/usr/bin/env bash
socket_out=; socket_status=0
socket_out=\$(NO_MISTAKES_TELEMETRY=off \
  NO_MISTAKES_NO_UPDATE_CHECK=1 no-mistakes axi 2>&1) || socket_status=\$?
if [ "\$socket_status" -eq 0 ]; then
  echo CONTROL_SOCKET_UNEXPECTED_CONNECT
  exit 90
fi
case "\$socket_out" in
  *'connect: operation not permitted'*) ;;
  *) echo CONTROL_SOCKET_WRONG_ERROR; exit 90 ;;
esac
if printf 'unexpected\n' >> '$STATE/proof.status'; then
  echo CONTROL_UNEXPECTED_WRITE
  exit 91
fi
echo CONTROL_DENIED
SH
chmod +x "$WORKTREE/control.sh"

(
  cd "$WORKTREE" || exit 1
  codex exec \
    --dangerously-bypass-hook-trust \
    --sandbox workspace-write \
    --skip-git-repo-check \
    -c 'approval_policy="never"' \
    -c 'model_reasoning_effort="low"' \
    --json \
    "$CONTROL_PROMPT"
) > "$CONTROL_TRANSCRIPT" 2>&1 || fail "Codex control turn failed: $(tail -20 "$CONTROL_TRANSCRIPT")"

grep -F 'CONTROL_DENIED' "$CONTROL_TRANSCRIPT" >/dev/null \
  || fail "control without additional roots did not prove the parent-home write denial"
[ ! -e "$STATE/proof.status" ] || fail "control unexpectedly wrote the parent-home status file"

cat > "$WORKTREE/probe.sh" <<SH
#!/usr/bin/env bash
set -eu
if ! NO_MISTAKES_TELEMETRY=off \
  NO_MISTAKES_NO_UPDATE_CHECK=1 no-mistakes axi >/dev/null 2>&1; then
  echo NO_MISTAKES_SOCKET_CONNECT_FAILED
  exit 93
fi
git switch -c fm/codex-writable-roots-live-proof
printf 'proof\n' > proof.txt
git add proof.txt
git commit -q -m 'Prove Codex writable roots'
printf 'running: proof\n' >> '$STATE/proof.status'
printf 'report: proof\n' > '$REPORT/report.md'
if printf 'unexpected\n' > '$SIBLING/escape.txt'; then
  echo SIBLING_WRITE_UNEXPECTED
  exit 92
fi
echo WRITABLE_ROOTS_AND_SOCKET_PROOF_OK
SH
chmod +x "$WORKTREE/probe.sh"

(
  cd "$WORKTREE" || exit 1
  codex exec \
    --dangerously-bypass-hook-trust \
    --sandbox workspace-write \
    --add-dir "$STATE" \
    --add-dir "$PROJECT/.git" \
    --add-dir "$REPORT" \
    --add-dir "$NO_MISTAKES_ROOT" \
    --skip-git-repo-check \
    -c 'approval_policy="never"' \
    -c 'model_reasoning_effort="low"' \
    --json \
    "$PROOF_PROMPT"
) > "$PROOF_TRANSCRIPT" 2>&1 || fail "Codex writable-roots turn failed: $(tail -20 "$PROOF_TRANSCRIPT")"

grep -F 'WRITABLE_ROOTS_AND_SOCKET_PROOF_OK' "$PROOF_TRANSCRIPT" >/dev/null \
  || fail "Codex transcript omitted the writable-roots and socket success marker"
grep -Fqx 'running: proof' "$STATE/proof.status" \
  || fail "Codex did not append the authorized status file"
grep -Fqx 'report: proof' "$REPORT/report.md" \
  || fail "Codex did not write the task-local report"
[ ! -e "$SIBLING/escape.txt" ] \
  || fail "Codex escaped the task-local report root into sibling data"
[ "$(git -C "$WORKTREE" branch --show-current)" = fm/codex-writable-roots-live-proof ] \
  || fail "Codex did not create the linked-worktree branch"
[ "$(git -C "$WORKTREE" log -1 --format=%s)" = 'Prove Codex writable roots' ] \
  || fail "Codex did not create the linked-worktree commit"

printf 'ok - %s live E2E proved narrow Codex worker writable roots and read-only no-mistakes socket access\n' "$CODEX_VERSION"
