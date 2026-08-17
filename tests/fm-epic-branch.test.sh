#!/usr/bin/env bash
# tests/fm-epic-branch.test.sh - cutting and verifying epic/<slug> branches.
#
# Exercises the real script against a real git clone with a real (bare) origin,
# so the never-clobber and idempotency guarantees are proven end to end, not
# asserted against the script's source. A fixture home carries a projects.md the
# --branches accessor reads and a clone the script pushes to.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EPIC="$ROOT/bin/fm-epic-branch.sh"
TMP_ROOT=$(fm_test_tmproot fm-epic-branch)

# --- fixture: a home with one registered project cloned from a bare origin ----
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/data" "$HOME_DIR/projects"

# Bare origin on branch main with one commit.
SRC="$TMP_ROOT/src"
fm_git_init_commit "$SRC"
git -C "$SRC" branch -m main
ORIGIN="$TMP_ROOT/proj.git"
git clone --quiet --bare "$SRC" "$ORIGIN"

# The clone the script operates on (origin = the bare repo).
CLONE="$HOME_DIR/projects/proj"
git clone --quiet "$ORIGIN" "$CLONE"
# A second clone whose registry entry declares NO production branch, so the
# undeclared-production refusal is reached past clone resolution, not before it.
git clone --quiet "$ORIGIN" "$HOME_DIR/projects/nobranch"

# Registry the --branches accessor parses. production declared = main.
cat > "$HOME_DIR/data/projects.md" <<'EOF'
# Projects
- proj [local-only production=main] - test fixture (added 260101)
- nobranch [local-only] - production undeclared (added 260101)
EOF

run() { FM_HOME="$HOME_DIR" "$EPIC" "$@"; }

origin_epic_sha() { git -C "$ORIGIN" rev-parse --verify --quiet "refs/heads/epic/$1" 2>/dev/null; }
origin_main_sha() { git -C "$ORIGIN" rev-parse --verify --quiet refs/heads/main; }

# --- verify before create: missing -> fail -----------------------------------
run verify demo proj && fail "verify passed for a non-existent epic branch"
pass "verify fails when epic/<slug> is absent"

# --- create: cuts epic/<slug> from production and pushes ----------------------
run create demo proj || fail "create failed on a fresh epic"
[ "$(origin_epic_sha demo)" = "$(origin_main_sha)" ] || fail "epic/demo not at production tip after create"
pass "create cuts epic/<slug> from production at its tip"

run verify demo proj || fail "verify failed right after create"
pass "verify passes after create"

# --- create is idempotent: re-run at production is a safe no-op ---------------
before=$(origin_epic_sha demo)
run create demo proj || fail "idempotent re-run refused"
[ "$(origin_epic_sha demo)" = "$before" ] || fail "re-run moved epic/demo"
pass "re-run at production is a safe no-op"

# --- epic ahead of production: still a no-op (production is an ancestor) ------
# Advance epic/demo on origin (a story commit), leaving it ahead of main.
AHEAD="$TMP_ROOT/ahead"
git clone --quiet --branch "epic/demo" "$ORIGIN" "$AHEAD"
printf 'story\n' > "$AHEAD/story.txt"
git -C "$AHEAD" add story.txt
git -C "$AHEAD" -c user.name=t -c user.email=t@t.invalid commit -qm story
git -C "$AHEAD" push --quiet origin "epic/demo"
ahead_sha=$(origin_epic_sha demo)
run create demo proj || fail "create refused an epic that is ahead of production"
[ "$(origin_epic_sha demo)" = "$ahead_sha" ] || fail "create moved an ahead epic"
pass "epic ahead of production stays untouched (no-op)"

# --- production moves ahead: epic now behind -> REFUSE, never clobber ---------
BUMP="$TMP_ROOT/bump"
git clone --quiet "$ORIGIN" "$BUMP"
printf 'more\n' > "$BUMP/more.txt"
git -C "$BUMP" add more.txt
git -C "$BUMP" -c user.name=t -c user.email=t@t.invalid commit -qm bump
git -C "$BUMP" push --quiet origin main
frozen=$(origin_epic_sha demo)
run create demo proj && fail "create clobbered/moved an epic behind production"
[ "$(origin_epic_sha demo)" = "$frozen" ] || fail "refused create still moved epic/demo"
pass "epic behind/diverged from production is refused (never clobber)"

# --- undeclared production -> refuse, points back to registration -------------
run create demo nobranch && fail "create proceeded with production undeclared"
pass "create refuses when production is undeclared"

# --- bad slug is rejected before touching git --------------------------------
run create 'bad slug' proj && fail "create accepted an invalid slug"
run verify -x proj && fail "verify accepted a dash-leading slug"
pass "invalid epic slugs are rejected"

# --- unknown project -> clean error ------------------------------------------
run verify demo does-not-exist && fail "verify accepted an unknown project"
pass "unknown project is a clean failure"
