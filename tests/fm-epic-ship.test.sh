#!/usr/bin/env bash
# tests/fm-epic-ship.test.sh - the 2-PR epic gitflow ship.
#
# Exercises the real script against a real git clone with a real (bare) origin so
# the branch/ancestry/merge-conflict logic is proven end to end, not asserted
# against source. gh-axi and fm-project-mode.sh --branches are stubbed (the
# --branches accessor lands with gflow-01/03, not on this base), driven by env so
# each case picks its own registry answer and PR-list result. git is real.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SHIP="$ROOT/bin/fm-epic-ship.sh"
TMP_ROOT=$(fm_test_tmproot fm-epic-ship)
fm_git_identity

# --- stub bin: fm-project-mode.sh (--branches) and gh-axi -------------------
STUBBIN="$TMP_ROOT/stubbin"
mkdir -p "$STUBBIN"

# fm-project-mode.sh --branches <project> -> "$FM_STUB_BRANCHES" (e.g. "main" or
# "master release"). Any other invocation exits 0.
cat > "$STUBBIN/fm-project-mode.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --branches ]; then printf '%s\n' "${FM_STUB_BRANCHES:-}"; exit 0; fi
exit 0
SH
chmod +x "$STUBBIN/fm-project-mode.sh"

# gh-axi stub. `pr list` echoes $GH_LIST_URL (empty = no PR open). `pr create`
# records its argv to $GH_CREATE_LOG and prints a deterministic URL derived from
# the counter file so each created PR has a distinct number.
cat > "$STUBBIN/gh-axi" <<'SH'
#!/usr/bin/env bash
sub=${2:-}
case "$1 $sub" in
  "pr list")
    [ -n "${GH_LIST_URL:-}" ] && printf '  ..,"%s"\n' "$GH_LIST_URL"
    exit 0 ;;
  "pr create")
    printf 'create %s\n' "$*" >> "${GH_CREATE_LOG:-/dev/null}"
    n=1
    if [ -n "${GH_PR_COUNTER:-}" ]; then
      n=$(( $(cat "$GH_PR_COUNTER" 2>/dev/null || echo 0) + 1 ))
      printf '%s' "$n" > "$GH_PR_COUNTER"
    fi
    printf 'https://github.com/acme/proj/pull/%s\n' "$n"
    exit 0 ;;
esac
exit 0
SH
chmod +x "$STUBBIN/gh-axi"

export FM_PROJECT_MODE_BIN="$STUBBIN/fm-project-mode.sh"
export FM_GH_BIN="$STUBBIN/gh-axi"
export GH_PR_COUNTER="$TMP_ROOT/pr-counter"

# --- fixture builders -------------------------------------------------------
# Each case gets its own origin + clone so branch state never leaks between them.
new_repo() {  # <name> -> echoes CLONE path; creates bare origin with main + one commit
  local name=$1
  local src="$TMP_ROOT/$name.src" origin="$TMP_ROOT/$name.git" clone="$TMP_ROOT/$name"
  fm_git_init_commit "$src"
  git -C "$src" branch -m main
  git clone --quiet --bare "$src" "$origin"
  git clone --quiet "$origin" "$clone"
  printf '%s\n' "$clone"
}

# commit_on <clone> <branch> <file> <content>: create/switch <branch>, add a
# commit, push it to origin. Leaves the clone on <branch>.
commit_on() {
  local clone=$1 branch=$2 file=$3 content=$4
  git -C "$clone" checkout -q -B "$branch"
  printf '%s\n' "$content" > "$clone/$file"
  git -C "$clone" add "$file"
  git -C "$clone" -c user.name=t -c user.email=t@t.invalid commit -qm "$branch:$file"
  git -C "$clone" push -q origin "$branch"
}

# Default FM_HOME to a throwaway so best-effort recording never writes into the
# real repo; the recording case overrides FM_HOME with its own fixture home.
run() { FM_HOME="${FM_HOME:-$TMP_ROOT/nohome}" GH_LIST_URL="${GH_LIST_URL:-}" \
  GH_CREATE_LOG="${GH_CREATE_LOG:-/dev/null}" FM_STUB_BRANCHES="$FM_STUB_BRANCHES" "$SHIP" "$@"; }

# --- ship-gate fixtures (G-ship-1/2) ----------------------------------------
# The completeness + no-mistakes-green gates read an epic dir under FM_HOME. Most
# cases only exercise the gitflow, so they use a home whose epic has NO kind:ship
# stories (completeness passes vacuously) and records green at the epic tip.
HCOUNT=0
epic_home() {  # <slug> [<epic-sha>] -> echoes FM_HOME; epic dir with optional green
  local slug=$1 sha=${2:-} home dir
  HCOUNT=$((HCOUNT + 1))
  home="$TMP_ROOT/home-$slug-$HCOUNT"
  dir="$home/data/plans/260820-epic-$slug"
  mkdir -p "$dir"
  printf -- '---\nepic: %s\ntitle: t\n---\n' "$slug" > "$dir/epic.md"
  [ -n "$sha" ] && printf '%s  # test green\n' "$sha" > "$dir/no-mistakes-green"
  printf '%s\n' "$home"
}
epic_dir_of() { printf '%s\n' "$1/data/plans/260820-epic-$2"; }  # <home> <slug>
add_story() {  # <epic-dir> <id> <repo>
  mkdir -p "$1/stories"
  printf -- '---\nid: %s\nepic: x\nrepo: %s\nkind: ship\ngate: false\n---\n' "$2" "$3" > "$1/stories/$2.md"
}
tip() { git -C "$1" rev-parse "$2"; }  # <clone> <ref> -> sha

# ===========================================================================
# help + arg validation
# ===========================================================================
out=$("$SHIP" --help); expect_code 0 $? "--help exits 0"
assert_contains "$out" "2-PR gitflow" "--help describes the flow"

"$SHIP" >/dev/null 2>&1 && fail "no args should be a usage error"
expect_code 2 $? "missing args -> usage exit 2"
pass "help and arg validation"

# invalid slug rejected (before any network)
FM_STUB_BRANCHES="main" "$SHIP" 'bad slug' proj >/dev/null 2>&1 && fail "spaced slug accepted"
pass "invalid epic slug rejected"

# ===========================================================================
# missing epic branch -> refuse, point at fm-epic-branch.sh
# ===========================================================================
FM_STUB_BRANCHES="main"
C=$(new_repo missing)
err=$(FM_STUB_BRANCHES=main "$SHIP" demo "$C" 2>&1) && fail "shipped with no epic branch"
assert_contains "$err" "fm-epic-branch.sh create" "missing epic branch points at the cut command"
pass "missing epic/<slug> refuses and guides to cut it"

# ===========================================================================
# no staging: single production PR
# ===========================================================================
C=$(new_repo nostg)
commit_on "$C" "epic/demo" epic.txt "epic work"
FM_STUB_BRANCHES="main"; export GH_LIST_URL=""
H=$(epic_home demo "$(tip "$C" epic/demo)")
LOG="$TMP_ROOT/nostg.create.log"; : > "$LOG"
out=$(FM_HOME="$H" GH_CREATE_LOG="$LOG" run demo "$C") || fail "no-staging ship failed"
assert_contains "$out" "production PR (epic/demo -> main)" "reports the production PR"
assert_contains "$out" "/pull/" "production PR URL reported"
assert_grep "--base main --head epic/demo" "$LOG" "created epic/demo -> main"
assert_no_grep "release" "$LOG" "no staging PR when staging undeclared"
pass "no staging -> one production PR"

# idempotent: an already-open PR is reported, not duplicated
: > "$LOG"
out=$(GH_LIST_URL="https://github.com/acme/proj/pull/77" GH_CREATE_LOG="$LOG" run demo "$C") \
  || fail "idempotent re-run failed"
assert_contains "$out" "pull/77" "existing open PR reported"
assert_no_grep "create" "$LOG" "no pr create when one is already open"
pass "existing head->base PR is reported, never duplicated"

# ===========================================================================
# staging (clean): staging PR first, production withheld
# ===========================================================================
C=$(new_repo stgclean)
# staging branch cut from main, then epic adds a non-conflicting file.
commit_on "$C" "release" stg.txt "staging base"
git -C "$C" checkout -q main
commit_on "$C" "epic/demo" feature.txt "new feature"
FM_STUB_BRANCHES="main release"
export GH_LIST_URL=""
H=$(epic_home demo "$(tip "$C" epic/demo)")
LOG="$TMP_ROOT/stgclean.create.log"; : > "$LOG"
out=$(FM_HOME="$H" FM_STUB_BRANCHES="main release" GH_CREATE_LOG="$LOG" run demo "$C") || fail "staging ship failed"
assert_contains "$out" "staging PR (epic/demo -> release)" "opens the staging test vehicle first"
assert_contains "$out" "after this staging PR merges" "withholds the production PR until staging merges"
assert_grep "--base release --head epic/demo" "$LOG" "created epic/demo -> release"
assert_no_grep "--base main" "$LOG" "production PR not opened yet"
pass "staging clean -> staging PR first, production withheld"

# ===========================================================================
# staging merged (epic is an ancestor of staging) -> production PR opens
# ===========================================================================
# Merge epic/demo into release on origin (the test vehicle merged), then re-run.
git -C "$C" checkout -q release
git -C "$C" merge -q --no-ff epic/demo -m "merge epic/demo into release"
git -C "$C" push -q origin release
: > "$LOG"
out=$(FM_HOME="$H" FM_STUB_BRANCHES="main release" GH_CREATE_LOG="$LOG" run demo "$C") || fail "post-merge ship failed"
assert_contains "$out" "production PR (epic/demo -> main)" "opens production once staging contains the epic"
assert_grep "--base main --head epic/demo" "$LOG" "created epic/demo -> main after staging merged"
pass "staging merged -> production PR opens (git-ancestry gate)"

# ===========================================================================
# staging conflict: cut resolve-epic/<slug>, withhold the PR until resolved
# ===========================================================================
C=$(new_repo stgconf)
# Both staging and epic edit the SAME file divergently -> merge conflict.
commit_on "$C" "release" shared.txt "staging version"
git -C "$C" checkout -q main
commit_on "$C" "epic/demo" shared.txt "epic version"
LOG="$TMP_ROOT/stgconf.create.log"; : > "$LOG"
out=$(FM_STUB_BRANCHES="main release" GH_LIST_URL="" GH_CREATE_LOG="$LOG" run demo "$C") \
  || fail "conflict-path ship errored"
assert_contains "$out" "conflicts with release" "detects the staging conflict"
assert_contains "$out" "resolve-epic/demo" "names the resolve branch"
git -C "$C" fetch -q origin
git -C "$C" rev-parse --verify --quiet "refs/remotes/origin/resolve-epic/demo" >/dev/null \
  || fail "resolve-epic/demo was not cut on origin"
assert_no_grep "create" "$LOG" "no staging PR while conflict is unresolved"
pass "staging conflict -> resolve-epic cut, PR withheld"

# After a human resolves on resolve-epic (merge epic in, resolve), the staging PR
# opens from resolve-epic/demo.
git -C "$C" checkout -q -B resolve-epic/demo origin/resolve-epic/demo
git -C "$C" -c user.name=t -c user.email=t@t.invalid merge -q -X ours epic/demo -m "resolve" || true
git -C "$C" push -q origin resolve-epic/demo
H=$(epic_home demo "$(tip "$C" epic/demo)")
: > "$LOG"
out=$(FM_HOME="$H" FM_STUB_BRANCHES="main release" GH_LIST_URL="" GH_CREATE_LOG="$LOG" run demo "$C") \
  || fail "post-resolve ship errored"
assert_contains "$out" "staging PR (resolve-epic/demo -> release)" "opens staging PR from the resolve branch"
assert_grep "--base release --head resolve-epic/demo" "$LOG" "staging PR head is resolve-epic/demo"
pass "resolved conflict -> staging PR opens from resolve-epic/<slug>"

# ===========================================================================
# dry-run: no PR is created, commands are printed
# ===========================================================================
C=$(new_repo dry)
commit_on "$C" "epic/demo" f.txt "work"
H=$(epic_home demo "$(tip "$C" epic/demo)")
LOG="$TMP_ROOT/dry.create.log"; : > "$LOG"
out=$(FM_HOME="$H" FM_STUB_BRANCHES="main" GH_LIST_URL="" GH_CREATE_LOG="$LOG" run demo "$C" --dry-run 2>&1) \
  || fail "dry-run errored"
assert_contains "$out" "[dry-run]" "dry-run announces itself"
assert_contains "$out" "pr create" "dry-run prints the gh create command"
assert_no_grep "create" "$LOG" "dry-run does not actually create a PR"
pass "dry-run prints commands without opening a PR"

# ===========================================================================
# epic recording: a matching epic dir gets a ships.md line
# ===========================================================================
C=$(new_repo rec)
commit_on "$C" "epic/gflow" r.txt "work"
HOME_DIR="$TMP_ROOT/rechome"
mkdir -p "$HOME_DIR/data/plans/260817-2007-epic-gflow-x"
cat > "$HOME_DIR/data/plans/260817-2007-epic-gflow-x/epic.md" <<'EOF'
---
epic: gflow
title: test
---
EOF
# The completeness + green gates read this epic dir: no stories -> complete
# vacuously; record green at the epic tip so the delivery PR opens.
printf '%s  # test green\n' "$(tip "$C" epic/gflow)" \
  > "$HOME_DIR/data/plans/260817-2007-epic-gflow-x/no-mistakes-green"
LOG="$TMP_ROOT/rec.create.log"; : > "$LOG"
FM_STUB_BRANCHES="main" GH_LIST_URL="" GH_CREATE_LOG="$LOG" FM_HOME="$HOME_DIR" \
  FM_STUB_BRANCHES="main" "$SHIP" gflow "$C" >/dev/null || fail "recording ship failed"
assert_present "$HOME_DIR/data/plans/260817-2007-epic-gflow-x/ships.md" "ships.md recorded"
assert_grep "delivery" "$HOME_DIR/data/plans/260817-2007-epic-gflow-x/ships.md" "ships.md has the delivery line"
pass "opened PR is recorded to the epic's ships.md"

# ===========================================================================
# ship gate G-ship-1: refuse an INCOMPLETE epic (a kind:ship story for this repo
# is absent from the epic branch), naming the unmerged story.
# ===========================================================================
C=$(new_repo incomplete)
git -C "$C" checkout -q -B epic/demo
printf 'a\n' > "$C/a.txt"; git -C "$C" add a.txt
git -C "$C" -c user.name=t -c user.email=t@t.invalid commit -qm "feat: first story (st-01)"
git -C "$C" push -q origin epic/demo
H=$(epic_home demo "$(tip "$C" epic/demo)")
D=$(epic_dir_of "$H" demo)
add_story "$D" "st-01-alpha" "$C"   # landed: (st-01) is in the epic log
add_story "$D" "st-02-beta"  "$C"   # NOT landed: no st-02 commit
LOG="$TMP_ROOT/incomplete.create.log"; : > "$LOG"
err=$(FM_HOME="$H" FM_STUB_BRANCHES="main" GH_LIST_URL="" GH_CREATE_LOG="$LOG" \
  run demo "$C" --dry-run 2>&1) && fail "shipped an incomplete epic"
assert_contains "$err" "INCOMPLETE" "refuses an incomplete epic"
assert_contains "$err" "st-02" "names the unmerged story"
assert_no_grep "st-01" <(printf '%s\n' "$err") "landed story st-01 is not reported missing"
assert_no_grep "create" "$LOG" "no PR created for an incomplete epic"
pass "G-ship-1: incomplete epic refuses, naming the unmerged story"

# ===========================================================================
# ship gate G-ship-2: a COMPLETE epic with NO no-mistakes-green evidence refuses,
# fail-closed (evidence surface absent).
# ===========================================================================
C=$(new_repo nogreen)
git -C "$C" checkout -q -B epic/demo
printf 'a\n' > "$C/a.txt"; git -C "$C" add a.txt
git -C "$C" -c user.name=t -c user.email=t@t.invalid commit -qm "feat: only story (st-01)"
git -C "$C" push -q origin epic/demo
H=$(epic_home demo)   # no green sha recorded
D=$(epic_dir_of "$H" demo)
add_story "$D" "st-01-alpha" "$C"
LOG="$TMP_ROOT/nogreen.create.log"; : > "$LOG"
err=$(FM_HOME="$H" FM_STUB_BRANCHES="main" GH_LIST_URL="" GH_CREATE_LOG="$LOG" \
  run demo "$C" --dry-run 2>&1) && fail "shipped without no-mistakes-green evidence"
assert_contains "$err" "no-mistakes-green" "refuses without green evidence"
assert_no_grep "create" "$LOG" "no PR created without green evidence"
pass "G-ship-2: complete-but-not-green epic refuses (fail-closed)"

# stale green (recorded at a different sha than the current epic tip) still refuses.
printf '%s  # stale\n' "0000000000000000000000000000000000000000" > "$D/no-mistakes-green"
err=$(FM_HOME="$H" FM_STUB_BRANCHES="main" GH_LIST_URL="" GH_CREATE_LOG="$LOG" \
  run demo "$C" --dry-run 2>&1) && fail "shipped on stale green evidence"
assert_contains "$err" "no-mistakes-green" "stale green (wrong sha) refuses"
pass "G-ship-2: green bound to the epic tip - a stale sha does not authorize ship"

# ===========================================================================
# both gates pass: complete + green -> opens the PR (dry-run).
# ===========================================================================
C=$(new_repo greenok)
git -C "$C" checkout -q -B epic/demo
printf 'a\n' > "$C/a.txt"; git -C "$C" add a.txt
git -C "$C" -c user.name=t -c user.email=t@t.invalid commit -qm "feat: the story (st-01)"
git -C "$C" push -q origin epic/demo
H=$(epic_home demo "$(tip "$C" epic/demo)")
D=$(epic_dir_of "$H" demo)
add_story "$D" "st-01-alpha" "$C"
LOG="$TMP_ROOT/greenok.create.log"; : > "$LOG"
out=$(FM_HOME="$H" FM_STUB_BRANCHES="main" GH_LIST_URL="" GH_CREATE_LOG="$LOG" \
  run demo "$C" --dry-run 2>&1) || fail "complete+green ship refused"
assert_contains "$out" "pr create" "complete+green opens the PR (dry-run)"
pass "complete + green -> the ship PR opens"

# a story for a DIFFERENT repo does not gate this repo's ship.
add_story "$D" "st-99-other" "some-other-repo"
out=$(FM_HOME="$H" FM_STUB_BRANCHES="main" GH_LIST_URL="" GH_CREATE_LOG="$LOG" \
  run demo "$C" --dry-run 2>&1) || fail "other-repo story wrongly gated this ship"
assert_contains "$out" "pr create" "another repo's story is not required on this repo's epic branch"
pass "completeness is scoped to this repo's kind:ship stories"

# ===========================================================================
# --allow-incomplete: single logged bypass for both gates.
# ===========================================================================
C=$(new_repo bypass)
git -C "$C" checkout -q -B epic/demo
printf 'a\n' > "$C/a.txt"; git -C "$C" add a.txt
git -C "$C" -c user.name=t -c user.email=t@t.invalid commit -qm "feat: partial (st-01)"
git -C "$C" push -q origin epic/demo
H=$(epic_home demo)   # incomplete AND no green
D=$(epic_dir_of "$H" demo)
add_story "$D" "st-01-alpha" "$C"
add_story "$D" "st-02-beta"  "$C"   # unmerged
LOG="$TMP_ROOT/bypass.create.log"; : > "$LOG"
out=$(FM_HOME="$H" FM_STUB_BRANCHES="main" GH_LIST_URL="" GH_CREATE_LOG="$LOG" \
  run demo "$C" --allow-incomplete 2>&1) || fail "--allow-incomplete did not ship"
assert_contains "$out" "--allow-incomplete" "bypass announces itself"
assert_grep "--base main --head epic/demo" "$LOG" "bypass opens the PR despite incomplete+not-green"
assert_present "$D/ships.md" "bypass logged a ships.md line"
assert_grep "BYPASS" "$D/ships.md" "bypass ship is logged"
pass "--allow-incomplete bypasses both gates and logs"

pass "all fm-epic-ship cases passed"
