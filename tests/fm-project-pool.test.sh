#!/usr/bin/env bash
# Tests for bin/fm-project-pool.sh, the per-home treehouse worktree pool config.
#
# The bug these exist for: treehouse keys its worktree pool by
# ($HOME, origin remote URL) - $HOME/.treehouse/<basename>-<sha256(url)[:6]> -
# and that key has no home dimension. The primary home and each secondmate home
# keep their OWN clone of the same repo, all with the same origin URL, so on one
# machine they resolve to ONE pool. A pool slot is a `git worktree add` from
# whichever clone was cwd when the slot was created and stays bound to it, so a
# home can be handed a worktree of ANOTHER home's clone. Reproduced against a
# scratch pool on treehouse v2.1.0 (2026-08-11, Linux): home B ran
# `treehouse get` from its own clone, received .../proj-dbc838/1/proj, and that
# worktree's .git read "gitdir: <home A's clone>/.git/worktrees/proj".
# bin/fm-spawn.sh's isolation guard refuses to launch on such a worktree, which
# leaves the work undispatchable until the shared pool itself is split.
#
# These cover everything provable without a live treehouse pool: the per-home
# root derivation, what apply writes, the cases it must refuse rather than
# overwrite, the detect-only report, the backfill, and the fact that both
# clone-creating paths actually call the chokepoint. The pool handout itself is
# treehouse's behavior and is verified live, not here.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

POOL="$ROOT/bin/fm-project-pool.sh"
TMP_ROOT=$(fm_test_tmproot fm-project-pool-tests)
fm_git_identity

# A fake $HOME, so nothing in this suite can read or write the real pool area.
FAKE_HOME="$TMP_ROOT/home"
mkdir -p "$FAKE_HOME"

pool() {  # run the script with the sandboxed HOME and no inherited FM_HOME
  ( unset FM_HOME; HOME="$FAKE_HOME" "$POOL" "$@" )
}

# make_home <name> [secondmate-id]: a directory shaped like a firstmate home.
make_home() {
  local name=$1 id=${2:-} home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  : >"$home/AGENTS.md"
  mkdir -p "$home/bin"
  [ -z "$id" ] || printf '%s\n' "$id" >"$home/.fm-secondmate-home"
  printf '%s\n' "$home"
}

# make_clone <home> <project>: a clone of the SHARED origin, so two homes'
# clones carry the identical origin URL - the condition that collapses them onto
# one pool.
ORIGIN="$TMP_ROOT/origin.git"
fm_git_init_commit "$TMP_ROOT/seed"
git clone --quiet --bare "$TMP_ROOT/seed" "$ORIGIN"
make_clone() {
  local home=$1 project=$2 dst
  dst="$home/projects/$project"
  git clone --quiet "$ORIGIN" "$dst"
  printf '%s\n' "$dst"
}

config_root() {  # <clone> -> the root= value in its treehouse.toml
  sed -n 's/^root[[:space:]]*=[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' "$1/treehouse.toml" | head -1
}

HOME_A=$(make_home homeA)
HOME_B=$(make_home homeB sub1)
CLONE_A=$(make_clone "$HOME_A" proj)
CLONE_B=$(make_clone "$HOME_B" proj)

# --- root derivation --------------------------------------------------------

ROOT_A=$(pool root --home "$HOME_A") || fail "root failed for homeA"
ROOT_B=$(pool root --home "$HOME_B") || fail "root failed for homeB"

[ "$ROOT_A" != "$ROOT_B" ] \
  || fail "two homes must not share a pool root (both got $ROOT_A)"
pass "each home derives its own pool root"

case "$ROOT_A" in
  "$FAKE_HOME"/.treehouse-homes/firstmate-*) ;;
  *) fail "primary pool root should sit under \$HOME/.treehouse-homes with a firstmate- tag, got $ROOT_A" ;;
esac
case "$ROOT_B" in
  "$FAKE_HOME"/.treehouse-homes/2ndmate-sub1-*) ;;
  *) fail "secondmate pool root should carry its 2ndmate-<id> tag, got $ROOT_B" ;;
esac
pass "pool roots reuse the shared home-tag naming and sit outside the home"

[ "$(pool root --home "$HOME_A")" = "$ROOT_A" ] \
  || fail "pool root derivation must be stable across runs"
pass "pool root derivation is stable"

# --- apply ------------------------------------------------------------------

pool apply "$CLONE_A" >/dev/null 2>&1 || fail "apply failed for $CLONE_A"
[ -f "$CLONE_A/treehouse.toml" ] || fail "apply wrote no treehouse.toml"
[ "$(config_root "$CLONE_A")" = "$ROOT_A" ] \
  || fail "apply wrote root '$(config_root "$CLONE_A")', expected $ROOT_A"
pass "apply writes the owning home's pool root, derived from the clone's location"

grep -qxF '/treehouse.toml' "$CLONE_A/.git/info/exclude" \
  || fail "apply did not add an anchored /treehouse.toml to the clone's git exclude file"
pass "apply excludes the config from git, anchored to the repo root"

[ -z "$(git -C "$CLONE_A" status --porcelain)" ] \
  || fail "the pool config leaked into the clone's git surface: $(git -C "$CLONE_A" status --porcelain)"
pass "git status in the clone is clean after apply"

git -C "$CLONE_A" worktree add --quiet -b wt-clean "$TMP_ROOT/wt-clean"
[ -z "$(git -C "$TMP_ROOT/wt-clean" status --porcelain)" ] \
  || fail "git status in a worktree of the clone is dirty: $(git -C "$TMP_ROOT/wt-clean" status --porcelain)"
pass "git status in a worktree cut from the clone is clean too"

pool apply "$CLONE_A" >/dev/null 2>&1 || fail "second apply failed; it must be idempotent"
[ "$(grep -cxF '/treehouse.toml' "$CLONE_A/.git/info/exclude")" = 1 ] \
  || fail "re-apply duplicated the git exclude entry"
pass "apply is idempotent"

# An explicit --home wins over the clone's location: bin/fm-spawn.sh passes the
# dispatching home, and bin/fm-home-seed.sh passes the child home because it runs
# in the parent's process.
pool apply "$CLONE_B" --home "$HOME_B" >/dev/null 2>&1 || fail "apply --home failed"
[ "$(config_root "$CLONE_B")" = "$ROOT_B" ] \
  || fail "apply --home wrote $(config_root "$CLONE_B"), expected $ROOT_B"
[ "$(config_root "$CLONE_A")" != "$(config_root "$CLONE_B")" ] \
  || fail "two homes' clones of the same repo still name one pool root"
pass "two homes cloning one repo end up with different pool roots"

# A config left behind by another home is repaired, not trusted.
printf '# Managed by firstmate: bin/fm-project-pool.sh\nroot = "%s"\n' "$ROOT_B" >"$CLONE_A/treehouse.toml"
pool apply "$CLONE_A" >/dev/null 2>&1 || fail "apply failed on a stale config"
[ "$(config_root "$CLONE_A")" = "$ROOT_A" ] || fail "apply did not repair a stale pool root"
pass "apply repairs a config naming another home's pool root"

# --- refusals ---------------------------------------------------------------

CLONE_TRACKED=$(make_clone "$HOME_A" tracked)
printf 'root = "/somewhere"\n' >"$CLONE_TRACKED/treehouse.toml"
git -C "$CLONE_TRACKED" add treehouse.toml
git -C "$CLONE_TRACKED" -c user.name=t -c user.email=t@t commit -qm "own config"
out=$(pool apply "$CLONE_TRACKED" 2>&1) && fail "apply must refuse a project that commits its own treehouse.toml"
case "$out" in
  *"commits its own treehouse.toml"*) ;;
  *) fail "tracked-config refusal did not name the reason: $out" ;;
esac
[ "$(sed -n 's/^root[[:space:]]*=[[:space:]]*"\(.*\)"$/\1/p' "$CLONE_TRACKED/treehouse.toml")" = /somewhere ] \
  || fail "apply overwrote tracked project content"
pass "apply refuses, and does not overwrite, a treehouse.toml the project commits"

CLONE_FOREIGN=$(make_clone "$HOME_A" foreign)
printf 'root = "/elsewhere"\n' >"$CLONE_FOREIGN/treehouse.toml"
out=$(pool apply "$CLONE_FOREIGN" 2>&1) && fail "apply must refuse an unmarked treehouse.toml"
case "$out" in
  *"firstmate did not write"*) ;;
  *) fail "foreign-config refusal did not name the reason: $out" ;;
esac
[ "$(sed -n 's/^root[[:space:]]*=[[:space:]]*"\(.*\)"$/\1/p' "$CLONE_FOREIGN/treehouse.toml")" = /elsewhere ] \
  || fail "apply overwrote a treehouse.toml it did not write"
pass "apply refuses, and does not overwrite, a treehouse.toml firstmate did not write"

out=$(pool apply "$TMP_ROOT/wt-clean" 2>&1) && fail "apply must refuse a linked worktree"
case "$out" in
  *"linked worktree"*) ;;
  *) fail "linked-worktree refusal did not name the reason: $out" ;;
esac
pass "apply refuses a linked worktree, whose pool the source clone already decides"

mkdir -p "$TMP_ROOT/notgit"
out=$(pool apply "$TMP_ROOT/notgit" 2>&1) && fail "apply must refuse a non-repository"
case "$out" in
  *"not a git repository"*) ;;
  *) fail "non-repository refusal did not name the reason: $out" ;;
esac
pass "apply refuses a directory that is not a git repository"

# --- check ------------------------------------------------------------------

CLONE_BARE=$(make_clone "$HOME_A" bare)
out=$(pool check --home "$HOME_A")
case "$out" in
  *"PROJECT_POOL: $CLONE_BARE has no home-scoped worktree pool config"*) ;;
  *) fail "check did not report the unconfigured clone: $out" ;;
esac
case "$out" in
  *"$CLONE_TRACKED commits its own treehouse.toml"*) ;;
  *) fail "check did not report the project-owned config: $out" ;;
esac
case "$out" in
  *"$CLONE_FOREIGN has a treehouse.toml firstmate did not write"*) ;;
  *) fail "check did not report the foreign config: $out" ;;
esac
case "$out" in
  *"$CLONE_A"*) fail "check reported an already-isolated clone: $out" ;;
esac
pass "check reports exactly the clones that still share a pool"

pool apply "$CLONE_BARE" >/dev/null 2>&1 || fail "apply failed for $CLONE_BARE"
rm -rf "$CLONE_TRACKED" "$CLONE_FOREIGN"
[ -z "$(pool check --home "$HOME_A")" ] || fail "check must be silent once every clone is isolated"
pass "check is silent when nothing is left to repair"

# --- check --all over locally registered secondmate homes -------------------

CLONE_B2=$(make_clone "$HOME_B" second)
cat >"$HOME_A/data/secondmates.md" <<EOF
- sub1 - local domain (home: $HOME_B; scope: things; projects: proj; added 2026-08-11)
- far1 - remote domain (home: /nonexistent/elsewhere; machine: otherbox; scope: things; projects: proj; added 2026-08-11)
EOF
out=$(pool check --home "$HOME_A" --all)
case "$out" in
  *"$CLONE_B2"*) ;;
  *) fail "check --all did not reach the local secondmate home's clone: $out" ;;
esac
case "$out" in
  *"/nonexistent/elsewhere"*) fail "check --all must skip a home on another machine: $out" ;;
esac
pass "check --all sweeps local secondmate homes and skips homes on other machines"

# --- backfill ---------------------------------------------------------------

CLONE_C=$(make_clone "$HOME_A" third)
out=$(pool backfill --home "$HOME_A" --dry-run)
case "$out" in
  *"would    $CLONE_C (absent)"*) ;;
  *) fail "dry-run backfill did not name the clone it would repair: $out" ;;
esac
[ ! -f "$CLONE_C/treehouse.toml" ] || fail "dry-run backfill wrote a config"
pass "backfill --dry-run reports without changing anything"

out=$(pool backfill --home "$HOME_A") || fail "backfill failed"
[ "$(config_root "$CLONE_C")" = "$ROOT_A" ] || fail "backfill did not isolate $CLONE_C"
case "$out" in
  *"applied  $CLONE_C (absent)"*) ;;
  *) fail "backfill did not report what it applied: $out" ;;
esac
pass "backfill gives every clone of a home its own pool"

# A worktree already checked out of the old shared pool is reported, never moved,
# pruned, destroyed, or returned.
git -C "$CLONE_B" worktree add --quiet -b legacy "$TMP_ROOT/legacy-pool/1/proj"
rm -f "$CLONE_B/treehouse.toml"
out=$(pool backfill --home "$HOME_B") || fail "backfill failed for homeB"
case "$out" in
  *"legacy worktree still checked out from the old shared pool, left untouched: $TMP_ROOT/legacy-pool/1/proj"*) ;;
  *) fail "backfill did not report the pre-existing worktree: $out" ;;
esac
[ -d "$TMP_ROOT/legacy-pool/1/proj" ] || fail "backfill removed a pre-existing worktree"
pass "backfill reports worktrees from the old shared pool and leaves them in place"

# --- wiring -----------------------------------------------------------------
#
# Both clone-creating paths must call the one chokepoint. A second copy of this
# logic anywhere is the failure this asserts against.

grep -q 'fm-project-pool.sh" apply' "$ROOT/bin/fm-home-seed.sh" \
  || fail "bin/fm-home-seed.sh does not call the pool chokepoint after cloning a secondmate's project"
pass "the secondmate seed calls the chokepoint"

grep -q 'fm-project-pool.sh" apply' "$ROOT/bin/fm-spawn.sh" \
  || fail "bin/fm-spawn.sh does not apply the pool config before treehouse get"
pass "every spawn applies the pool config, so a clone made by hand repairs itself"

grep -q 'fm-project-pool.sh" check' "$ROOT/bin/fm-bootstrap.sh" \
  || fail "bin/fm-bootstrap.sh does not run the detect-only pool check"
pass "session-start bootstrap reports clones that still share a pool"

grep -q 'fm-project-pool.sh' "$ROOT/AGENTS.md" \
  || fail "AGENTS.md does not name the pool config as a sanctioned write under projects/"
pass "the projects/ write exception is recorded in AGENTS.md"
