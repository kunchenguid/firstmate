#!/usr/bin/env bash
# Behavior tests for the gh base-repo pin.
#
# A firstmate home usually runs from a FORK: `origin` is the fork the fleet ships
# to, `upstream` is the fork parent - a third party's repo. With no remote
# carrying `gh-resolved`, gh resolves the base repo by remote NAME and prefers
# `upstream`, so default gh/gh-axi calls silently read the parent project and a
# default-targeted `gh pr create` proposes our branch to it. fm-gh-resolve.sh
# pins `remote.origin.gh-resolved=base`, and fm-bootstrap runs it.
#
# These cases pin the whole contract hermetically over temp git repos, with no
# gh and no network: the repair, its idempotence, every no-op that protects a
# deliberate choice, the constraint that no remote is ever touched, the
# detect-only/locked split in fm-bootstrap, and the two inheritance facts that
# decide whether the fix survives - a linked worktree DOES inherit the pin, a
# fresh clone does NOT and is re-pinned by the next bootstrap.
#
# One extra case probes the vendor contract itself (that gh honors the key we
# write). It needs a real, authenticated gh, so it announces a skip instead of
# passing silently when gh is absent or logged out; the structural cases above
# always run, so this script never passes having checked nothing.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RESOLVE="$ROOT/bin/fm-gh-resolve.sh"
TMP_ROOT=$(fm_test_tmproot fm-gh-resolve)
fm_git_identity fmtest fmtest@example.invalid

note() { printf '# %s\n' "$1"; }

# A repo with one commit and the given "<remote>=<url>" pairs. Echoes its path.
make_repo() {
  local dir=$1 pair
  shift
  git init -q -b main "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  for pair in "$@"; do
    git -C "$dir" remote add "${pair%%=*}" "${pair#*=}"
  done
  printf '%s\n' "$dir"
}

pin_of() {
  git -C "$1" config --get remote.origin.gh-resolved 2>/dev/null || true
}

# The remote inventory (names and URLs) the script must never disturb.
remotes_fingerprint() {
  git -C "$1" remote -v 2>/dev/null | sort
}

ORIGIN_URL=https://github.com/VirtualRoboticHands/firstmate
PARENT_URL=https://github.com/kunchenguid/firstmate

# --- the repair, and what it must leave alone -------------------------------

test_pins_the_fork_and_touches_nothing_else() {
  local repo before after out
  repo=$(make_repo "$TMP_ROOT/fork" "origin=$ORIGIN_URL" "upstream=$PARENT_URL")
  before=$(remotes_fingerprint "$repo")

  [ -z "$(pin_of "$repo")" ] || fail "a fresh fork checkout should start unpinned"

  out=$("$RESOLVE" "$repo")
  assert_contains "$out" "VirtualRoboticHands/firstmate" "repair did not name the fork it pinned"
  [ "$(pin_of "$repo")" = base ] || fail "repair did not pin origin as the base repo"

  after=$(remotes_fingerprint "$repo")
  [ "$before" = "$after" ] || fail "repair changed the remote inventory:
$before
--- became ---
$after"
  # The one config key is the entire write: upstream must carry nothing.
  [ -z "$(git -C "$repo" config --get remote.upstream.gh-resolved || true)" ] \
    || fail "repair wrote a gh-resolved key onto the upstream remote"

  # Idempotent: a second run is silent and writes no second value.
  out=$("$RESOLVE" "$repo")
  [ -z "$out" ] || fail "a second repair run should print nothing, got: $out"
  [ "$(git -C "$repo" config --get-all remote.origin.gh-resolved | wc -l)" -eq 1 ] \
    || fail "repair added a duplicate gh-resolved value"
  pass "fm-gh-resolve: pins origin as gh's base repo, writes only that key, and is idempotent"
}

# A pin already in place is an operator's deliberate choice - including one that
# deliberately targets the parent to contribute upstream. Never overwrite it.
test_preserves_a_deliberate_choice() {
  local repo out
  repo=$(make_repo "$TMP_ROOT/deliberate" "origin=$ORIGIN_URL" "upstream=$PARENT_URL")
  git -C "$repo" config remote.upstream.gh-resolved base

  out=$("$RESOLVE" "$repo")
  [ -z "$out" ] || fail "repair should stay silent over a deliberate pin, got: $out"
  [ "$(git -C "$repo" config --get remote.upstream.gh-resolved)" = base ] \
    || fail "repair disturbed a deliberate upstream pin"
  [ -z "$(pin_of "$repo")" ] || fail "repair overrode a deliberate upstream pin with origin"

  out=$("$RESOLVE" --check "$repo")
  [ -z "$out" ] || fail "--check should stay silent over a deliberate pin, got: $out"
  pass "fm-gh-resolve: a deliberate existing pin - including one aimed at the parent - is never overwritten"
}

# Nothing to disambiguate means nothing to write.
test_no_op_when_unambiguous() {
  local repo n=0 label spec out
  while IFS='|' read -r label spec; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    repo="$TMP_ROOT/noop-$n"
    # shellcheck disable=SC2086 # spec is a deliberate word-split remote list
    make_repo "$repo" $spec >/dev/null
    out=$("$RESOLVE" "$repo")
    [ -z "$out" ] || fail "$label: expected silence, got: $out"
    [ -z "$(pin_of "$repo")" ] || fail "$label: should not have written a pin"
  done <<ROWS
only origin, no parent to confuse gh|origin=$ORIGIN_URL
no remotes at all|
second remote is not on a GitHub host|origin=$ORIGIN_URL fork2=https://gitlab.com/someone/firstmate.git
both remotes are non-GitHub|a=https://gitlab.com/x/y.git b=https://bitbucket.org/x/y.git
ROWS
  # A path that is not a git work tree is silent and successful, not an error.
  out=$("$RESOLVE" "$TMP_ROOT"); expect_code 0 $? "a non-git path should exit 0"
  [ -z "$out" ] || fail "a non-git path should print nothing, got: $out"
  pass "fm-gh-resolve: silent no-op for one GitHub remote, non-GitHub remotes, and a non-git path"
}

# Ambiguous but unpinnable: report it rather than guessing a base repo.
test_reports_when_origin_is_unusable() {
  local repo out
  repo=$(make_repo "$TMP_ROOT/no-origin" \
    "upstream=$PARENT_URL" "mirror=https://github.com/someone/firstmate.git")
  out=$("$RESOLVE" "$repo")
  assert_contains "$out" "GH_RESOLVE:" "an unpinnable checkout should report a GH_RESOLVE line"
  assert_contains "$out" "no GitHub 'origin'" "the report did not name the missing GitHub origin"
  [ -z "$(pin_of "$repo")" ] || fail "should not have invented a pin without a GitHub origin"
  pass "fm-gh-resolve: reports an ambiguous checkout with no GitHub origin instead of guessing"
}

# --check is the read-only session's path and must never write.
test_check_never_writes() {
  local repo out
  repo=$(make_repo "$TMP_ROOT/check" "origin=$ORIGIN_URL" "upstream=$PARENT_URL")
  out=$("$RESOLVE" --check "$repo"); expect_code 0 $? "--check should exit 0"
  assert_contains "$out" "GH_RESOLVE:" "--check did not report an unpinned ambiguous checkout"
  assert_contains "$out" "VirtualRoboticHands/firstmate" "--check did not name the intended base repo"
  [ -z "$(pin_of "$repo")" ] || fail "--check wrote a pin"

  # After a repair, --check has nothing left to say.
  "$RESOLVE" "$repo" >/dev/null
  out=$("$RESOLVE" --check "$repo")
  [ -z "$out" ] || fail "--check should be silent once pinned, got: $out"
  pass "fm-gh-resolve: --check reports without writing, and goes quiet once pinned"
}

# scp-like and https URLs, with and without .git, all name the same repo.
test_url_forms() {
  local repo n=0 label url
  while IFS='|' read -r label url; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    repo="$TMP_ROOT/url-$n"
    make_repo "$repo" "origin=$url" "upstream=$PARENT_URL" >/dev/null
    "$RESOLVE" "$repo" >/dev/null
    [ "$(pin_of "$repo")" = base ] || fail "$label: origin was not recognized as a GitHub remote"
  done <<'ROWS'
https without .git|https://github.com/VirtualRoboticHands/firstmate
https with .git|https://github.com/VirtualRoboticHands/firstmate.git
scp-like ssh|git@github.com:VirtualRoboticHands/firstmate.git
ssh:// URL with port|ssh://git@github.com:22/VirtualRoboticHands/firstmate.git
ROWS
  pass "fm-gh-resolve: recognizes https, scp-like, and ssh:// GitHub remotes"
}

# --- fm-bootstrap wiring: warn when read-only, pin when locked --------------

# run_bootstrap <repo> [detect-only]: run fm-bootstrap with <repo> standing in for
# the primary checkout. No projects/ under the home keeps fleet sync inert.
run_bootstrap() {
  env FM_ROOT_OVERRIDE="$1" FM_HOME="$1" \
    FM_BOOTSTRAP_DETECT_ONLY="$([ "${2:-}" = detect-only ] && echo 1 || echo 0)" \
    "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null
}

test_bootstrap_wiring() {
  local repo out
  repo=$(make_repo "$TMP_ROOT/bootstrap" "origin=$ORIGIN_URL" "upstream=$PARENT_URL")

  # Detect-only stands in for a lock-refused session: it must warn, not repair.
  out=$(run_bootstrap "$repo" detect-only | grep '^GH_RESOLVE:' || true)
  assert_contains "$out" "VirtualRoboticHands/firstmate" "detect-only bootstrap did not warn about the unpinned base repo"
  [ -z "$(pin_of "$repo")" ] || fail "detect-only bootstrap wrote a pin; a read-only session must not mutate"

  # A locked session repairs it, and says so.
  out=$(run_bootstrap "$repo" | grep -E '^(GH_RESOLVE|BOOTSTRAP_INFO): ' || true)
  assert_contains "$out" "pinned gh base repo to VirtualRoboticHands/firstmate" \
    "locked bootstrap did not report the pin it made"
  [ "$(pin_of "$repo")" = base ] || fail "locked bootstrap did not pin the base repo"

  # Once pinned, both modes are quiet.
  out=$(run_bootstrap "$repo" | grep '^GH_RESOLVE:' || true)
  [ -z "$out" ] || fail "locked bootstrap kept warning after pinning: $out"
  out=$(run_bootstrap "$repo" detect-only | grep '^GH_RESOLVE:' || true)
  [ -z "$out" ] || fail "detect-only bootstrap kept warning after pinning: $out"
  pass "fm-bootstrap: warns in detect-only, pins when locked, and goes quiet afterwards"
}

# --- does the fix survive? the two inheritance facts ------------------------

# The pin lives in local git config, which linked worktrees share and clones do
# not. Both halves are asserted here so neither claim can rot into a guess.
test_inheritance() {
  local repo wt clone out
  repo=$(make_repo "$TMP_ROOT/inherit" "origin=$ORIGIN_URL" "upstream=$PARENT_URL")
  "$RESOLVE" "$repo" >/dev/null
  [ "$(pin_of "$repo")" = base ] || fail "setup: repo was not pinned"

  # A linked worktree - how every crewmate works on firstmate - reads the same
  # .git/config, so it inherits the pin with no extra step.
  wt="$TMP_ROOT/inherit-wt"
  git -C "$repo" worktree add -q --detach "$wt" >/dev/null 2>&1
  [ "$(pin_of "$wt")" = base ] || fail "a linked worktree did not inherit the pin"
  out=$("$RESOLVE" --check "$wt")
  [ -z "$out" ] || fail "--check warned inside an inheriting worktree, got: $out"

  # A fresh clone does NOT inherit it: git clone carries no local config. This is
  # the honest limit of the config value, and the reason the repair is wired into
  # bootstrap rather than done once by hand.
  clone="$TMP_ROOT/inherit-clone"
  git clone -q "$repo" "$clone" 2>/dev/null
  git -C "$clone" remote set-url origin "$ORIGIN_URL"
  git -C "$clone" remote add upstream "$PARENT_URL"
  [ -z "$(pin_of "$clone")" ] || fail "a fresh clone unexpectedly carried the pin; the survival claim needs revisiting"
  out=$("$RESOLVE" --check "$clone")
  assert_contains "$out" "GH_RESOLVE:" "a fresh clone should be reported as unpinned"

  # ...and the next locked bootstrap in that clone pins it, which is what makes
  # the fix durable across clones.
  run_bootstrap "$clone" >/dev/null
  [ "$(pin_of "$clone")" = base ] || fail "bootstrap did not re-pin a fresh clone"
  pass "survival: a linked worktree inherits the pin; a fresh clone does not, and bootstrap re-pins it"
}

# --- vendor contract: gh must actually honor the key we write ---------------

# Everything above is structural. This one case proves the premise - that gh
# resolves the base repo from `remote.origin.gh-resolved` - against real gh.
# `gh repo set-default --view` reads config but still requires auth, so an
# unauthenticated machine (ordinary CI) is announced as a skip, never a pass.
test_gh_honors_the_pin() {
  local repo out
  if ! command -v gh >/dev/null 2>&1; then
    note "SKIP gh vendor probe: gh is not installed on this machine"
    return 0
  fi
  if ! gh auth status >/dev/null 2>&1; then
    note "SKIP gh vendor probe: gh is installed but not authenticated"
    return 0
  fi
  repo=$(make_repo "$TMP_ROOT/vendor" "origin=$ORIGIN_URL" "upstream=$PARENT_URL")
  "$RESOLVE" "$repo" >/dev/null
  out=$(git -C "$repo" rev-parse --show-toplevel >/dev/null && cd "$repo" && gh repo set-default --view 2>&1)
  assert_contains "$out" "VirtualRoboticHands/firstmate" \
    "gh $(gh --version | head -1 | awk '{print $3}') did not resolve the base repo from the pinned key"
  pass "gh honors remote.origin.gh-resolved: the fork, not the fork parent, is the base repo"
}

test_pins_the_fork_and_touches_nothing_else
test_preserves_a_deliberate_choice
test_no_op_when_unambiguous
test_reports_when_origin_is_unusable
test_check_never_writes
test_url_forms
test_bootstrap_wiring
test_inheritance
test_gh_honors_the_pin
