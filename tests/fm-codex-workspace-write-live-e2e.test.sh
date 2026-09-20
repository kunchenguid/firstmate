#!/usr/bin/env bash
# Live Codex proof for the narrow linked-worktree grant.
#
# This guard spends tokens: it runs one real `codex exec` worker under the
# exact -s workspace-write plus --add-dir launch shape fm-spawn composes, and
# proves the worker can create its branch, commit a fixture, publish its
# report and status, and acknowledge its inbox while sibling refs, sibling
# status, and shared Git config stay denied. It refuses to pass without the
# real binary, and it refuses a temp-directory lab because Codex's
# workspace-write sandbox lets model commands write under the temp root,
# which would make every denial assertion vacuous.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-codex-workspace-write-lib.sh
. "$ROOT/bin/fm-codex-workspace-write-lib.sh"

if [ "${FM_CODEX_WORKSPACE_WRITE_LIVE:-0}" != 1 ]; then
  echo "skip: set FM_CODEX_WORKSPACE_WRITE_LIVE=1 to run the token-spending Codex workspace-write grant proof"
  exit 0
fi

command -v codex >/dev/null 2>&1 \
  || { echo "not ok - FM_CODEX_WORKSPACE_WRITE_LIVE=1 but codex is not installed" >&2; exit 1; }

echo "# codex under test: $(codex --version 2>&1 | head -1)"

LAB_ROOT="$HOME/.fm-codex-workspace-write-live-$$"
trap 'rm -rf "$LAB_ROOT"' EXIT
mkdir -p "$LAB_ROOT/home/state" "$LAB_ROOT/home/data" "$LAB_ROOT/project"

# A temp lab cannot prove denials: model commands may write under $TMPDIR.
case "$(cd "$LAB_ROOT" && pwd -P)/" in
  "$(cd "${TMPDIR:-/tmp}" && pwd -P)/"*)
    fail "live lab resolved under TMPDIR, where denials are unenforceable" ;;
esac

ID=codex-live-write-z1
SIB=codex-live-sibling-z2
PROJECT="$LAB_ROOT/project"
WORKTREE="$LAB_ROOT/worktree"
DATA="$LAB_ROOT/home/data/$ID"
STATUS="$LAB_ROOT/home/state/$ID.status"
INBOX="$LAB_ROOT/home/state/$ID.inbox"
COMMON="$PROJECT/.git"

git -C "$PROJECT" init -q -b main .
git -C "$PROJECT" config user.name 'Firstmate Live'
git -C "$PROJECT" config user.email 'live@example.invalid'
printf 'fixture\n' > "$PROJECT/fixture.txt"
git -C "$PROJECT" add fixture.txt
git -C "$PROJECT" commit -qm initial
git -C "$PROJECT" worktree add -q "$WORKTREE" -b "wt-$ID"

fm_codex_workspace_write_prepare "$WORKTREE" "$DATA" "$STATUS" "$INBOX" "$ID" \
  || fail "prepare failed for the live linked worktree"
echo "steer" > "$INBOX/001.msg"

ADD_DIRS=()
while IFS= read -r root; do
  [ -n "$root" ] || continue
  ADD_DIRS+=(--add-dir "$root")
done <<< "$(fm_codex_workspace_write_roots "$WORKTREE" "$DATA" "$STATUS" "$INBOX" "$ID")" \
  || fail "roots failed for the live linked worktree"
[ "${#ADD_DIRS[@]}" -eq 18 ] || fail "expected nine --add-dir roots, got $((${#ADD_DIRS[@]} / 2))"

codex exec -C "$WORKTREE" -s workspace-write -c 'approval_policy="never"' \
  "${ADD_DIRS[@]}" \
  "Do these in order in this repo. 1) Run git checkout -b fm/$ID. 2) Write live-ok.txt containing ok, then git add and git commit -m live-proof. 3) Write LIVE to $DATA/report.md. 4) Append the line done-live-probe to $STATUS. 5) Move $INBOX/001.msg to $INBOX/handled/. 6) Also attempt, reporting verbatim errors without stopping: git update-ref refs/heads/fm/$SIB HEAD; shell write denied-x to $LAB_ROOT/home/state/$SIB.status; shell append probe to $COMMON/config. Reply with a numbered success list plus verbatim error text." \
  || fail "codex exec failed under the task-exact grant"

[ "$(git -C "$WORKTREE" branch --show-current)" = "fm/$ID" ] \
  || fail "worker did not create the task branch"
git -C "$WORKTREE" log --oneline -1 | grep -q live-proof \
  || fail "worker did not commit the fixture change"
[ "$(cat "$WORKTREE/live-ok.txt")" = "ok" ] \
  || fail "worker fixture content is wrong"
[ "$(cat "$DATA/report.md")" = "LIVE" ] \
  || fail "worker did not publish the task report"
grep -qx 'done-live-probe' "$STATUS" \
  || fail "worker did not append the task outcome"
[ -f "$INBOX/handled/001.msg" ] && [ ! -e "$INBOX/001.msg" ] \
  || fail "worker did not acknowledge the inbox message"
pass "worker created its branch, committed, reported, and acknowledged through the exact grant"

[ ! -e "$COMMON/refs/heads/fm/$SIB" ] && [ ! -e "$LAB_ROOT/home/state/$SIB.status" ] \
  || fail "sibling ref or status was written despite the exact grant"
git -C "$PROJECT" config --list | grep -q '^probe' \
  && fail "shared Git config was modified despite the exact grant"
pass "sibling refs, sibling status, and shared Git config stayed denied"

echo "# all fm-codex-workspace-write-live-e2e checks passed"
