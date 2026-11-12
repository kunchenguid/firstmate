#!/usr/bin/env bash
# tests/fm-home-seed-origin.test.sh - the local seed path refuses an origin git
# would execute, and still clones an ordinary one.
#
# bin/fm-home-seed.sh clones each project from the active home using the origin
# recorded in that clone's own .git/config. That origin is data rather than a
# constant, and git runs a remote-helper transport such as "ext::<command>" as a
# command, so the URL has to clear fm_project_origin_safe before it reaches
# `git clone` and the options have to be terminated with `--`.
#
# tests/fm-project-origin.test.sh covers the validator itself, including a
# fixture that demonstrates git really does execute an ext:: origin.
# tests/fm-remote-secondmate-lifecycle-e2e.test.sh covers the refusal on the
# remote path. This file is the local path, which had no coverage: a regression
# that dropped the guard here would have left both of those green.
#
# What this asserts is that the refusal happens *before* git is reached, which
# is the property the guard owns. Whether git would then have executed the
# transport depends on the cloning host's protocol configuration - on a host
# with protocol.ext.allow unset, git refuses it too, with "transport 'ext' not
# allowed". fm-project-origin-lib.sh says why that cannot be relied on: the
# sending home cannot see the cloning host's configuration.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/secondmate-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/secondmate-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-home-seed-origin)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
PARENT="$TMP_ROOT/parent"

make_firstmate_git_root "$PARENT"
mkdir -p "$PARENT/data" "$PARENT/projects" "$PARENT/config"
fm_git_init_commit "$PARENT/projects/alpha"
fm_git_add_origin "$PARENT/projects/alpha" "$TMP_ROOT/alpha.git"
cat > "$PARENT/data/projects.md" <<'EOF'
- alpha [direct-PR] - alpha project (added 2026-10-01)
EOF

seed() { # <id> <home> -> captures output in SEED_OUT, status in SEED_RC
  set +e
  SEED_OUT=$(
    FM_HOME="$PARENT" \
    FM_SECONDMATE_CHARTER='Origin guard charter.' \
    FM_SECONDMATE_SCOPE='origin guard' \
    "$ROOT/bin/fm-home-seed.sh" "$1" "$2" alpha 2>&1
  )
  SEED_RC=$?
  set -e
}

# --- the control: an ordinary origin still clones -----------------------------
# Without this, the refusal below could pass simply because seeding never works
# in this fixture, and the guard would be unproven.
seed seed-ok "$TMP_ROOT/home-ok"
[ "$SEED_RC" -eq 0 ] || fail "seeding a project with an ordinary origin failed: $SEED_OUT"
assert_present "$TMP_ROOT/home-ok/projects/alpha" "an accepted origin did not produce a project clone"
pass "an ordinary file:// origin still clones through the local seed path"

# --- the guard: an origin git would execute is refused -------------------------
git -C "$PARENT/projects/alpha" remote set-url origin 'ext::sh -c id'
seed seed-unsafe "$TMP_ROOT/home-unsafe"
[ "$SEED_RC" -ne 0 ] || fail "seeding accepted a remote-helper origin git would execute: $SEED_OUT"
assert_contains "$SEED_OUT" 'not an accepted clone URL' \
  "the refusal did not name the reason the origin was rejected"
assert_absent "$TMP_ROOT/home-unsafe/projects/alpha" \
  "the unsafe origin still produced a project clone"
pass "an ext:: origin is refused before git clone runs"

# --- and an option-shaped origin cannot be absorbed as a flag ------------------
# Written through `git config` because `git remote set-url` refuses an
# option-shaped value itself - which is the point: a .git/config can still
# hold one, and that is where the seed path reads it from. The value is
# scp-like so normalize_origin_url passes it through unchanged (a colon-free
# value would be canonicalized to an absolute path first) and the guard sees
# the leading dash itself.
git -C "$PARENT/projects/alpha" config remote.origin.url '-oProxyCommand=touch:x'
seed seed-flag "$TMP_ROOT/home-flag"
[ "$SEED_RC" -ne 0 ] || fail "seeding accepted an option-shaped origin: $SEED_OUT"
assert_contains "$SEED_OUT" 'not an accepted clone URL' \
  "the refusal did not name the reason the option-shaped origin was rejected"
assert_absent "$TMP_ROOT/home-flag/projects/alpha" "the option-shaped origin still produced a clone"
pass "an option-shaped origin is refused before git clone runs"

fm_test_cleanup "$TMP_ROOT"
