#!/usr/bin/env bash
# Behavior tests for the read-only leftover-state audit and its heartbeat surface
# (the fleet snapshot's hygiene field and the fleet view's Cleanup section).
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

AUDIT="$ROOT/bin/fm-hygiene-audit.sh"
SNAPSHOT="$ROOT/bin/fm-fleet-snapshot.sh"
VIEW="$ROOT/bin/fm-fleet-view.sh"
TMP_ROOT=$(fm_test_tmproot fm-hygiene-audit)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
fm_git_identity

# A fake gh that records every call and answers `pr list` from $FAKE_GH_PRS.
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fakebin")
cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FAKE_GH_LOG:?}"
case "$1 $2" in
  "pr list") [ -f "${FAKE_GH_PRS:-}" ] && cat "$FAKE_GH_PRS" ;;
esac
exit 0
SH
chmod +x "$FAKEBIN/gh"
export PATH="$FAKEBIN:$PATH"
export FAKE_GH_LOG="$TMP_ROOT/gh.log"
: > "$FAKE_GH_LOG"

make_home() {  # <name>: home with projects/alpha cloned from a bare origin
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  fm_git_init_commit "$TMP_ROOT/$1-seed"
  git clone --quiet --bare "$TMP_ROOT/$1-seed" "$TMP_ROOT/$1-origin.git"
  git clone --quiet "file://$TMP_ROOT/$1-origin.git" "$home/projects/alpha"
  printf '%s\n' "$home"
}

audit() {  # <home> [args...]
  local home=$1
  shift
  FM_HOME="$home" FM_ROOT_OVERRIDE='' "$AUDIT" "$@"
}

commit_file() {  # <repo> <file> <content> <message>
  printf '%s\n' "$3" > "$1/$2"
  git -C "$1" add "$2"
  git -C "$1" commit -qm "$4"
}

classes() {  # <json>
  printf '%s\n' "$1" | jq -r '[.findings[] | "\(.class):\(.branch // .task // .repo)"] | sort | join(",")'
}

# --- clean home ------------------------------------------------------------------

HOME_CLEAN=$(make_home clean)
out=$(audit "$HOME_CLEAN")
assert_equals "" "$out" "clean home prints no cleanup lines"
json=$(audit "$HOME_CLEAN" --json)
assert_equals "fm-hygiene-audit.v1" "$(printf '%s' "$json" | jq -r .schema)" "schema is declared"
assert_equals "0" "$(printf '%s' "$json" | jq '.findings | length')" "clean home has no findings"
assert_equals "1" "$(printf '%s' "$json" | jq .repos_scanned)" "the project clone is scanned"
pass "a clean home reports nothing"

# --- slot claims and shared copies -------------------------------------------------

HOME_CLAIM=$(make_home claim)
REPO=$HOME_CLAIM/projects/alpha
POOL=$TMP_ROOT/claim-pool
mkdir -p "$POOL/1" "$POOL/2" "$POOL/3"
git -C "$REPO" worktree add --quiet --detach "$POOL/1/alpha"
git -C "$REPO" worktree add --quiet --detach "$POOL/2/alpha"
git -C "$REPO" worktree add --quiet --detach "$POOL/3/alpha"
printf 'task=newer-task\nhome=%s\n' "$HOME_CLAIM" > "$POOL/1/.fm-slot-owner"
printf 'garbage\n' > "$POOL/2/.fm-slot-owner"
printf 'task=mine\nhome=%s\n' "$HOME_CLAIM" > "$POOL/3/.fm-slot-owner"
fm_write_meta "$HOME_CLAIM/state/stale-task.meta" "worktree=$POOL/1/alpha" "project=$REPO" kind=ship
fm_write_meta "$HOME_CLAIM/state/odd-task.meta" "worktree=$POOL/2/alpha" "project=$REPO" kind=ship
fm_write_meta "$HOME_CLAIM/state/mine.meta" "worktree=$POOL/3/alpha" "project=$REPO" kind=ship
fm_write_meta "$HOME_CLAIM/state/twin.meta" "worktree=$POOL/3/alpha" "project=$REPO" kind=ship
json=$(audit "$HOME_CLAIM" --json)
assert_equals "shared-copy:mine,slot-claim-unreadable:odd-task,slot-claimed-by-other:stale-task,slot-claimed-by-other:twin" \
  "$(printf '%s' "$json" | jq -r '[.findings[] | "\(.class):\(.task)"] | sort | join(",")')" \
  "stale, unreadable, and shared claims are each reported once; a matching claim is not"
assert_contains "$(printf '%s' "$json" | jq -r '.findings[] | select(.task == "stale-task") | .detail')" \
  "names task newer-task" "the stale claim names its current claimant"
assert_equals "action" "$(printf '%s' "$json" | jq -r '[.findings[].severity] | unique | join(",")')" \
  "claim findings are supervisor-actionable"
pass "stale, unreadable, and shared copy claims are reported"

# --- dirty copies no task owns ---------------------------------------------------

HOME_DIRTY=$(make_home dirty)
REPO=$HOME_DIRTY/projects/alpha
git -C "$REPO" worktree add --quiet --detach "$TMP_ROOT/dirty-pool/1/alpha"
git -C "$REPO" worktree add --quiet --detach "$TMP_ROOT/dirty-pool/2/alpha"
git -C "$REPO" worktree add --quiet --detach "$TMP_ROOT/dirty-pool/3/alpha"
printf 'edit\n' >> "$TMP_ROOT/dirty-pool/1/alpha/README.md"
mkdir -p "$TMP_ROOT/dirty-pool/2/alpha/.claude"
printf '{}\n' > "$TMP_ROOT/dirty-pool/2/alpha/.claude/settings.json"
printf 'edit\n' >> "$TMP_ROOT/dirty-pool/3/alpha/README.md"
fm_write_meta "$HOME_DIRTY/state/busy.meta" "worktree=$TMP_ROOT/dirty-pool/3/alpha" "project=$REPO" kind=ship
git -C "$REPO" worktree add --quiet --detach "$TMP_ROOT/dirty-pool/4/alpha"
printf 'edit\n' >> "$TMP_ROOT/dirty-pool/4/alpha/README.md"
fm_write_secondmate_meta "$HOME_DIRTY/state/mate.meta" "$TMP_ROOT/dirty-pool/4/alpha"
json=$(audit "$HOME_DIRTY" --json)
assert_equals "1" "$(printf '%s' "$json" | jq '[.findings[] | select(.class == "dirty-orphan-copy")] | length')" \
  "only the unowned copy with real edits is reported; a task copy and a secondmate home are owned"
assert_contains "$(printf '%s' "$json" | jq -r '.findings[] | select(.class == "dirty-orphan-copy") | .path')" \
  "dirty-pool/1/alpha" "the dirty orphan copy is named"
[ -n "$(git -C "$TMP_ROOT/dirty-pool/1/alpha" status --porcelain)" ] || fail "the audit changed the dirty copy"
pass "dirty copies no task owns are reported and left untouched"

# --- fm/* branches -----------------------------------------------------------------

HOME_BR=$(make_home branches)
REPO=$HOME_BR/projects/alpha
base=$(git -C "$REPO" rev-parse HEAD)

# Genuinely unlanded, unowned work.
git -C "$REPO" checkout -q -b fm/lost "$base"
commit_file "$REPO" lost.txt lost "lost work"
# Unlanded but owned by a live task record.
git -C "$REPO" checkout -q -b fm/live "$base"
commit_file "$REPO" live.txt live "live work"
fm_write_meta "$HOME_BR/state/live.meta" "project=$REPO" kind=ship
# Pushed, so not a leftover finding.
git -C "$REPO" checkout -q -b fm/pushed "$base"
commit_file "$REPO" pushed.txt pushed "pushed work"
git -C "$REPO" push -q origin fm/pushed
git -C "$REPO" push -q origin --delete fm/pushed 2>/dev/null || true
git -C "$REPO" push -q origin fm/pushed
# Landed by a squash under a different commit, after which main moved on.
git -C "$REPO" checkout -q -b fm/squashed "$base"
commit_file "$REPO" sq.txt one "squash part one"
commit_file "$REPO" sq.txt two "squash part two"
# Landed as a patch-equivalent cherry-pick.
git -C "$REPO" checkout -q -b fm/picked "$base"
commit_file "$REPO" picked.txt picked "picked work"
picked=$(git -C "$REPO" rev-parse HEAD)
# Merged into main and pushed with it, so its commits are on a remote.
git -C "$REPO" checkout -q -b fm/merged "$base"
commit_file "$REPO" merged.txt merged "merged work"
merged=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" checkout -q main
git -C "$REPO" merge -q --ff-only "$merged"
git -C "$REPO" merge -q --squash fm/squashed >/dev/null 2>&1
git -C "$REPO" commit -qm "squashed landing"
git -C "$REPO" cherry-pick "$picked" >/dev/null
commit_file "$REPO" later.txt later "unrelated later work"
git -C "$REPO" push -q origin main
# A local-only clone with no remote: a branch merged into local main is landed.
fm_git_init_commit "$HOME_BR/projects/beta"
git -C "$HOME_BR/projects/beta" checkout -q -b fm/local
commit_file "$HOME_BR/projects/beta" local.txt local "local-only work"
git -C "$HOME_BR/projects/beta" checkout -q main
git -C "$HOME_BR/projects/beta" merge -q --ff-only fm/local

json=$(audit "$HOME_BR" --json)
assert_equals "landed-branch:fm/local,landed-branch:fm/picked,landed-branch:fm/squashed,unlanded-branch:fm/lost" \
  "$(classes "$json")" "landed leftovers separate from genuinely unlanded work; owned and pushed branches are skipped"
assert_contains "$(printf '%s' "$json" | jq -r '.findings[] | select(.branch == "fm/local") | .evidence')" \
  "contained in main" "a branch merged into a local-only default branch is landed"
assert_equals "action" "$(printf '%s' "$json" | jq -r '.findings[] | select(.class == "unlanded-branch") | .severity')" \
  "unlanded work is actionable"
assert_equals "info,info,info" "$(printf '%s' "$json" | jq -r '[.findings[] | select(.class == "landed-branch") | .severity] | join(",")')" \
  "landed leftovers are informational"
assert_equals "lost" "$(printf '%s' "$json" | jq -r '.findings[] | select(.class == "unlanded-branch") | .task')" \
  "the branch's task id is reported"
assert_contains "$(printf '%s' "$json" | jq -r '.findings[] | select(.branch == "fm/squashed") | .evidence')" \
  "squash" "a squash landing is recognized from content"
assert_contains "$(printf '%s' "$json" | jq -r '.findings[] | select(.branch == "fm/picked") | .evidence')" \
  "patch-equivalent" "a cherry-picked landing is recognized as patch-equivalent"
text=$(audit "$HOME_BR")
assert_contains "$text" "CLEANUP action unlanded-branch: alpha fm/lost 1 commit(s)" "text form names the unlanded branch"
assert_equals "" "$(cat "$FAKE_GH_LOG")" "the default audit makes no network call"
git -C "$REPO" rev-parse --verify -q fm/lost >/dev/null || fail "the audit deleted a branch"
pass "unowned unpushed branches split into landed leftovers and unlanded work offline"

# --- merged pull request, gated behind --pr-lookup and then cached ----------------

HOME_PR=$(make_home pr)
REPO=$HOME_PR/projects/alpha
base=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" checkout -q -b fm/rebased "$base"
commit_file "$REPO" rebased.txt rebased "rebased work"
tip=$(git -C "$REPO" rev-parse HEAD)
# The pipeline rebased the branch onto newer main and added a fix before the PR.
git -C "$REPO" checkout -q main
commit_file "$REPO" other.txt other "other main work"
git -C "$REPO" push -q origin main
git -C "$REPO" checkout -q -b pr-head main
git -C "$REPO" cherry-pick "$tip" >/dev/null
commit_file "$REPO" rebased.txt fixed "pipeline fix"
pr_head=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" checkout -q main
git -C "$REPO" branch -q -D pr-head
# The landing is a squash that main then changed again, so offline checks cannot prove it.
commit_file "$REPO" rebased.txt "fixed and changed again" "squash landing then more"
git -C "$REPO" push -q origin main
printf 'https://example.invalid/pull/7\t%s\n' "$pr_head" > "$TMP_ROOT/prs.tsv"
export FAKE_GH_PRS="$TMP_ROOT/prs.tsv"
: > "$FAKE_GH_LOG"

json=$(audit "$HOME_PR" --json)
assert_equals "unlanded-branch:fm/rebased" "$(classes "$json")" "without --pr-lookup the branch reads unlanded"
assert_equals "" "$(cat "$FAKE_GH_LOG")" "without --pr-lookup no gh call is made"
json=$(audit "$HOME_PR" --json --pr-lookup)
assert_equals "landed-branch:fm/rebased" "$(classes "$json")" "a merged PR carrying the rebased commit proves the landing"
assert_contains "$(printf '%s' "$json" | jq -r '.findings[0].evidence')" "https://example.invalid/pull/7" "the PR is the evidence"
assert_contains "$(cat "$FAKE_GH_LOG")" "pr list --state merged --head fm/rebased" "the lookup asks for merged PRs from the head branch"
: > "$FAKE_GH_LOG"
json=$(audit "$HOME_PR" --json)
assert_equals "landed-branch:fm/rebased" "$(classes "$json")" "a confirmed landing is remembered offline"
assert_equals "" "$(cat "$FAKE_GH_LOG")" "the remembered landing needs no network call"
git -C "$REPO" checkout -q fm/rebased
commit_file "$REPO" extra.txt extra "new unlanded work"
git -C "$REPO" checkout -q main
json=$(audit "$HOME_PR" --json)
assert_equals "unlanded-branch:fm/rebased" "$(classes "$json")" "a moved tip no longer matches its remembered landing"
FM_HYGIENE_PR_LOOKUPS=1 audit "$HOME_PR" --json --pr-lookup >/dev/null
assert_equals "1" "$(grep -c 'pr list' "$FAKE_GH_LOG")" "PR lookups stay within their bound"
pass "merged-PR landings are gated behind --pr-lookup, bounded, and remembered per tip"
unset FAKE_GH_PRS

# --- clone lag ---------------------------------------------------------------------

HOME_LAG=$(make_home lag)
REPO=$HOME_LAG/projects/alpha
git clone --quiet "file://$TMP_ROOT/lag-origin.git" "$TMP_ROOT/lag-other"
commit_file "$TMP_ROOT/lag-other" a.txt a "upstream one"
commit_file "$TMP_ROOT/lag-other" b.txt b "upstream two"
git -C "$TMP_ROOT/lag-other" push -q origin main
git -C "$REPO" fetch -q origin
json=$(audit "$HOME_LAG" --json)
assert_equals "clone-behind" "$(printf '%s' "$json" | jq -r '[.findings[].class] | join(",")')" "a lagging clone is reported"
assert_equals "routine 2" "$(printf '%s' "$json" | jq -r '.findings[0] | "\(.severity) \(.commits)"')" \
  "clone lag is a routine refresh item with its commit count"
assert_contains "$(printf '%s' "$json" | jq -r '.findings[0].detail')" "bin/fm-fleet-sync.sh alpha" "the refresh path is named"
assert_equals "$(git -C "$REPO" rev-parse origin/main~2)" "$(git -C "$REPO" rev-parse main)" "the audit does not refresh the clone"
pass "clone lag is a routine refresh item"

# --- bounds --------------------------------------------------------------------------

json=$(FM_HYGIENE_MAX_FINDINGS=1 audit "$HOME_BR" --json)
assert_equals "1 3 unlanded-branch" "$(printf '%s' "$json" | jq -r '"\(.findings | length) \(.truncated) \(.findings[0].class)"')" \
  "the finding cap keeps the most severe finding and counts the rest"
rc=0
FM_HOME="$HOME_BR" FM_HYGIENE_BRANCH_LIMIT=abc "$AUDIT" --json >/dev/null 2>&1 || rc=$?
expect_code 2 "$rc" "an invalid bound is refused"
pass "findings are bounded and bounds are validated"

# --- heartbeat surface: fleet snapshot and view --------------------------------------

cat > "$HOME_BR/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] lost - Recover lost work (repo: alpha) (kind: ship) (since 2026-09-01)

## Done
EOF
snap=$(FM_HOME="$HOME_BR" FM_ROOT_OVERRIDE='' "$SNAPSHOT" --json)
assert_equals "true" "$(printf '%s' "$snap" | jq -r .hygiene.available)" "the snapshot carries the audit"
assert_equals "lost" "$(printf '%s' "$snap" | jq -r '.hygiene.findings[] | select(.class == "unlanded-branch") | .backlog.id')" \
  "an unlanded branch is joined to its backlog item"
view=$(FM_HOME="$HOME_BR" FM_ROOT_OVERRIDE='' "$VIEW")
assert_contains "$view" "## Cleanup" "the fleet view has a Cleanup section"
assert_contains "$view" "| action | unlanded-branch | alpha | fm/lost | lost | 1 |" "the unlanded branch is a Cleanup row"
assert_contains "$view" "backlog lost is queued" "the row names the owning backlog item"
assert_contains "$view" "3 unowned local branch(es) already landed" "landed leftovers collapse to one count line"
assert_not_contains "$view" "| info |" "landed leftovers are not rows"
view=$(FM_HOME="$HOME_CLEAN" FM_ROOT_OVERRIDE='' "$VIEW")
assert_contains "$view" "No leftover state needs cleanup." "a clean fleet says so"
snap=$(FM_HOME="$HOME_BR" FM_ROOT_OVERRIDE='' FM_HYGIENE_BRANCH_LIMIT=abc "$SNAPSHOT" --json)
assert_equals "false audit failed" "$(printf '%s' "$snap" | jq -r '"\(.hygiene.available) \(.hygiene.reason)"')" \
  "an audit failure is disclosed without failing the snapshot"
view=$(FM_HOME="$HOME_BR" FM_ROOT_OVERRIDE='' FM_HYGIENE_BRANCH_LIMIT=abc "$VIEW")
assert_contains "$view" "Leftover-state audit unavailable: audit failed." "the view discloses an unavailable audit"
pass "the heartbeat fleet view surfaces cleanup findings from the snapshot"
