#!/usr/bin/env bash
# tests/fm-git-guard.test.sh - proves both duties of bin/fm-git-guard.sh:
#
#   1. HR1 path lock: a write under <primary-home>/projects/ is refused from
#      the primary firstmate session, and FM_HR1_AUSNAHME=O-<id> both admits
#      it and writes a Tor-Log line naming the order.
#   2. HR3' salvage tor: a destructive git command (force push, branch -D)
#      earns a bundle under data/salvage/ before being allowed through; when
#      the target cannot be resolved to a repo, the command is refused
#      instead of running with no recovery point; reflog expire and rm on the
#      salvage store itself are refused outright, with the same
#      FM_SALVAGE_DISCARD=O-<id> escape.
#
# Every case runs twice where it matters: red without state/.tor-git-scharf
# (the transitional arm-flag), green with it - so the flag is proven load-
# bearing, not just present. Everything runs against a throwaway TMP tree;
# nothing touches the real repo's state/ or data/.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$REPO/bin/fm-git-guard.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export GIT_AUTHOR_NAME="fm-git-guard test" GIT_AUTHOR_EMAIL="test@example.invalid"
export GIT_COMMITTER_NAME="fm-git-guard test" GIT_COMMITTER_EMAIL="test@example.invalid"

FAILS=0
fail() { echo "FAIL: $1" >&2; FAILS=$((FAILS + 1)); }
ok() { echo "ok: $1"; }

# --- fixtures ---------------------------------------------------------------
# HOME_A: a fixture PRIMARY firstmate checkout - carries AGENTS.md and bin/
# (the signature fm-git-guard.sh looks for) and is a plain, non-worktree repo.
HOME_A="$TMP/home"
mkdir -p "$HOME_A/state" "$HOME_A/data" "$HOME_A/projects" "$HOME_A/bin"
echo "# fixture" > "$HOME_A/AGENTS.md"
git -C "$HOME_A" init -q -b main
git -C "$HOME_A" commit -q --allow-empty -m "fixture root"
FLAG="$HOME_A/state/.tor-git-scharf"
TOR_LOG="$HOME_A/state/tor-log/git-guard.jsonl"

# WORK_REPO: an ordinary (non-primary) repo, used for the HR3' salvage cases -
# HR3' is deliberately NOT scoped to the primary session.
WORK_REPO="$TMP/work-repo"
mkdir -p "$WORK_REPO"
git -C "$WORK_REPO" init -q -b main
echo hello > "$WORK_REPO/f.txt"
git -C "$WORK_REPO" add f.txt
git -C "$WORK_REPO" commit -q -m "seed"

# NOTGIT: a plain directory, not a git repo at all - forces bundle resolution
# to fail so the "bundle failure denies" path is exercised deterministically.
NOTGIT="$TMP/notgit"
mkdir -p "$NOTGIT"

run() { FM_HOME="$HOME_A" "$GUARD" --command "$1" --cwd "${2:-$HOME_A}" --claude 2>"$TMP/stderr"; echo $?; }
last_stderr() { cat "$TMP/stderr" 2>/dev/null; }

HR1_WRITE_CMD='echo x > '"$HOME_A"'/projects/some-clone/notes.md'
FORCE_PUSH_CMD='git push --force origin main'
BRANCH_DELETE_CMD='git branch -D somebranch'
RESET_HARD_CMD='git reset --hard'
SALVAGE_RM_CMD='rm -rf '"$HOME_A"'/data/salvage'

# --- 0. flag absent: the transitional arm-flag makes every case a silent
#        allow, HR1 write and HR3' destructive command alike --------------
rc=$(run "$HR1_WRITE_CMD" "$HOME_A")
[ "$rc" -eq 0 ] && [ -z "$(last_stderr)" ] || fail "flag absent: HR1 write must allow silently (rc=$rc stderr='$(last_stderr)')"
rc=$(run "$FORCE_PUSH_CMD" "$WORK_REPO")
[ "$rc" -eq 0 ] || fail "flag absent: force-push must allow (rc=$rc)"
[ ! -d "$HOME_A/data/salvage" ] || [ -z "$(find "$HOME_A/data/salvage" -type f 2>/dev/null)" ] \
  || fail "flag absent: no bundle may be written while the gate is unarmed"
ok "flag absent: every case allows silently, no bundle, no log"

# arm the gate for everything below
mkdir -p "$(dirname "$FLAG")"
: > "$FLAG"

# --- 1. HR1 path lock -------------------------------------------------------
rc=$(run "$HR1_WRITE_CMD" "$HOME_A")
if [ "$rc" -eq 2 ] && last_stderr | grep -q 'HR1'; then
  ok "HR1: a write under projects/ from the primary session is denied, citing HR1"
else
  fail "HR1: expected deny citing HR1 (rc=$rc stderr='$(last_stderr)')"
fi

rc=$(run "FM_HR1_AUSNAHME=O-77 $HR1_WRITE_CMD" "$HOME_A")
if [ "$rc" -eq 0 ]; then
  ok "HR1: FM_HR1_AUSNAHME=O-77 admits exactly this one write"
else
  fail "HR1: the FM_HR1_AUSNAHME escape must allow (rc=$rc stderr='$(last_stderr)')"
fi
if [ -f "$TOR_LOG" ] && grep -q '"regel":"HR1"' "$TOR_LOG" && grep -q 'O-77' "$TOR_LOG"; then
  ok "HR1: the exception writes a Tor-Log line naming order O-77"
else
  fail "HR1: expected a Tor-Log line for HR1 naming O-77 in $TOR_LOG"
fi

rc=$(run 'rg foo '"$HOME_A"'/projects/' "$HOME_A")
[ "$rc" -eq 0 ] || fail "HR1: a read-only rg over projects/ must allow (rc=$rc stderr='$(last_stderr)')"
ok "HR1: read-only inspection of projects/ (rg) always allows"

# --- 2. HR3' salvage - destructive commands earn a bundle, then pass -------
bundle_count() { find "$HOME_A/data/salvage" -maxdepth 1 -name '*.bundle' 2>/dev/null | wc -l | tr -d '[:space:]'; }

before=$(bundle_count)
rc=$(run "$FORCE_PUSH_CMD" "$WORK_REPO")
after=$(bundle_count)
if [ "$rc" -eq 0 ] && [ "$after" -eq $((before + 1)) ]; then
  ok "HR3': force-push earns a salvage bundle and is then allowed"
else
  fail "HR3': force-push expected allow + 1 new bundle (rc=$rc before=$before after=$after)"
fi
newest=$(find "$HOME_A/data/salvage" -maxdepth 1 -name '*-work-repo-*.bundle' 2>/dev/null | head -1)
[ -n "$newest" ] && [ -s "$newest" ] || fail "HR3': expected a non-empty bundle named for work-repo"

before=$(bundle_count)
rc=$(run "$BRANCH_DELETE_CMD" "$WORK_REPO")
after=$(bundle_count)
if [ "$rc" -eq 0 ] && [ "$after" -eq $((before + 1)) ]; then
  ok "HR3': branch -D earns a salvage bundle and is then allowed"
else
  fail "HR3': branch -D expected allow + 1 new bundle (rc=$rc before=$before after=$after)"
fi

# --- 3. HR3' salvage - bundle failure denies instead of running blind ------
rc=$(run "$RESET_HARD_CMD" "$NOTGIT")
if [ "$rc" -eq 2 ] && last_stderr | grep -q 'HR3-salvage'; then
  ok "HR3': reset --hard with no resolvable repo denies instead of running unsalvaged"
else
  fail "HR3': expected deny citing HR3-salvage for an unresolvable target (rc=$rc stderr='$(last_stderr)')"
fi

# --- 4. HR3' reflog expire - refused outright, escape shared with salvage-discard
rc=$(run "git reflog expire --all" "$WORK_REPO")
if [ "$rc" -eq 2 ] && last_stderr | grep -q 'HR3-reflog-expire'; then
  ok "HR3': git reflog expire is refused outright"
else
  fail "HR3': expected deny citing HR3-reflog-expire (rc=$rc stderr='$(last_stderr)')"
fi
rc=$(run "FM_SALVAGE_DISCARD=O-9 git reflog expire --all" "$WORK_REPO")
[ "$rc" -eq 0 ] || fail "HR3': FM_SALVAGE_DISCARD=O-9 must admit reflog expire (rc=$rc stderr='$(last_stderr)')"
ok "HR3': FM_SALVAGE_DISCARD=O-9 admits exactly this one reflog expire"

# --- 5. HR3' salvage-discard - rm on the salvage store itself --------------
rc=$(run "$SALVAGE_RM_CMD" "$HOME_A")
if [ "$rc" -eq 2 ] && last_stderr | grep -q 'HR3-salvage-discard'; then
  ok "HR3': rm on the salvage store itself is refused"
else
  fail "HR3': expected deny citing HR3-salvage-discard (rc=$rc stderr='$(last_stderr)')"
fi
rc=$(run "FM_SALVAGE_DISCARD=O-9 $SALVAGE_RM_CMD" "$HOME_A")
[ "$rc" -eq 0 ] || fail "HR3': FM_SALVAGE_DISCARD=O-9 must admit discarding the salvage store (rc=$rc stderr='$(last_stderr)')"
ok "HR3': FM_SALVAGE_DISCARD=O-9 admits exactly this one salvage discard"

if [ "$FAILS" -gt 0 ]; then
  echo "$FAILS failure(s)" >&2
  exit 1
fi
echo "all git-guard checks passed"
