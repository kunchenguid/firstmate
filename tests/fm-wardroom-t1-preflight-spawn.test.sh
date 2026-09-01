#!/usr/bin/env bash
# T1-preflight-spawn: the spawn hard gate. A brief naming work the crewmate
# cannot do must stop fm-spawn BEFORE anything is created - no pane, no
# worktree, no meta - and the refusal must name the offender, since the whole
# point is to save the diagnosis cycle as well as the run. The gate runs AHEAD
# of the intake council (it needs no model, and the council exempts scouts) and
# covers scouts as well as ship tasks. Secondmates are exempt: their brief is a
# charter and their home is a firstmate home, where data/ and state/ are theirs.
# A clean brief gets through untouched, and FM_PREFLIGHT_OVERRIDE=1 bypasses
# loudly.
# Mutation (LEDGER_MUTATE=1): the refusal assertions are inverted to demand that
# the offending brief SPAWNS - a correct gate refuses it, so the gate goes red
# exactly when the spawn hook still works.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/secondmate-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/secondmate-helpers.sh"
# shellcheck source=bin/fm-intake-lib.sh
. "$ROOT/bin/fm-intake-lib.sh"

FIX="$ROOT/tests/fixtures/preflight"
TMP=$(fm_test_tmproot fm-wd-t1-pfs)
HOME_DIR="$TMP/home"
S="$HOME_DIR/state"
mkdir -p "$HOME_DIR/data" "$S" "$HOME_DIR/projects"

# The project is a real git repo with firstmate's own ignore shape, so the
# gitignored rule has something real to ask.
PROJ="$HOME_DIR/projects/alpha"
mkdir -p "$PROJ"
git -C "$PROJ" init -q
printf 'projects/\nstate/\ndata/\n' > "$PROJ/.gitignore"
git -C "$PROJ" add -A >/dev/null
git -C "$PROJ" -c user.email=t@example.invalid -c user.name=t commit -qm init >/dev/null

# Reaching the real herdr binary prints this and exits 97 (tests/denybin/herdr).
# A refusal that never prints it is proof the spawn stopped before it touched
# any surface at all.
HERDR_MARKER="reached the REAL herdr binary"

# Every spawn pins the harness explicitly: ambient harness detection resolves to
# 'unknown' on a CI runner, and fm-spawn would then die on the missing launch
# template before reaching the gate under test.
run_spawn() {
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' \
    FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' FM_SPAWN_NO_GUARD=1 \
    "$@" 2>&1
}

plant() {  # <id> <fixture>
  mkdir -p "$HOME_DIR/data/$1"
  sed "s/fixture-k3/$1/g" "$FIX/$2.md" > "$HOME_DIR/data/$1/brief.md"
}

# 1. A ship brief naming a gitignored path is refused, by name, before anything
#    is created - and BEFORE the wardroom, which would otherwise have refused it
#    for a different reason and hidden this one.
plant pfgit-k3 gitignored
out=$(run_spawn "$ROOT/bin/fm-spawn.sh" pfgit-k3 projects/alpha codex); code=$?
if [ "${LEDGER_MUTATE:-}" = 1 ]; then
  assert_not_contains "$out" "PREFLIGHT" "MUTATION: the offending ship brief expected to spawn"
else
  [ "$code" -ne 0 ] || fail "a ship spawn on an impossible brief must exit non-zero"
  assert_contains "$out" "PREFLIGHT" "the refusal shows the preflight banner"
  assert_contains "$out" "REFUSED" "the refusal is explicit"
  assert_contains "$out" "data/command-center-roadmap.md" "the refusal names the offending path"
  assert_contains "$out" "gitignored" "the refusal says why"
  assert_not_contains "$out" "WARDROOM" "the preflight runs ahead of the intake council"
  assert_not_contains "$out" "$HERDR_MARKER" "nothing may be created before the refusal"
  assert_absent "$S/pfgit-k3.meta" "a refused spawn records no meta"
fi

# 2. Every other rule refuses at the spawn too, each naming its own offender.
plant pfpri-k3 primary-checkout
out=$(run_spawn "$ROOT/bin/fm-spawn.sh" pfpri-k3 projects/alpha codex) || true
assert_contains "$out" "primary-checkout" "the primary-checkout rule refuses at the spawn"
assert_contains "$out" "/firstmate/AGENTS.md" "it names the offending path"

plant pflea-k3 pool-lease
out=$(run_spawn "$ROOT/bin/fm-spawn.sh" pflea-k3 projects/alpha codex) || true
assert_contains "$out" "pool-lease" "the pool-lease rule refuses at the spawn"
assert_contains "$out" "fm-home-seed.sh" "it names the offending command"

plant pfred-k3 status-redirect
out=$(run_spawn "$ROOT/bin/fm-spawn.sh" pfred-k3 projects/alpha codex) || true
assert_contains "$out" "status-redirect" "the status-redirect rule refuses at the spawn"
assert_contains "$out" "fm-status.sh" "it names the verb the brief must teach"

# 3. SCOUTS ARE COVERED. The intake council exempts them, so without this the
#    third defect - a scout told to "test" a pool-leasing command - would still
#    reach a live pane.
plant pfscout-k3 pool-lease
out=$(run_spawn "$ROOT/bin/fm-spawn.sh" pfscout-k3 projects/alpha codex --scout) || true
assert_contains "$out" "PREFLIGHT" "a scout spawn is preflighted too"
assert_absent "$S/pfscout-k3.meta" "a refused scout spawn records no meta"

# 4. THE CLEAN BRIEF GETS THROUGH. Without this the gate could be satisfied by a
#    preflight that refuses every spawn, which is worse than no preflight.
plant pfok-k3 clean
fm_intake_append "$S" pfok-k3 proceed "vetted"
out=$(run_spawn "$ROOT/bin/fm-spawn.sh" pfok-k3 projects/alpha codex) || true
assert_not_contains "$out" "REFUSED" "a clean ship brief must pass the preflight and the wardroom"

plant pflook-k3 lookalike
out=$(run_spawn "$ROOT/bin/fm-spawn.sh" pflook-k3 projects/alpha codex --scout) || true
assert_not_contains "$out" "PREFLIGHT" "a lookalike scout brief must pass the preflight"

# 5. The captain's bypass is loud and logged, never silent.
plant pfovr-k3 gitignored
fm_intake_append "$S" pfovr-k3 proceed "vetted"
out=$(FM_PREFLIGHT_OVERRIDE=1 run_spawn "$ROOT/bin/fm-spawn.sh" pfovr-k3 projects/alpha codex) || true
assert_contains "$out" "PREFLIGHT OVERRIDE" "the override prints its own banner"
assert_not_contains "$out" "REFUSED" "the override must not refuse"

# 6. Secondmates are exempt: their home is a firstmate home, where the paths a
#    crewmate cannot touch are exactly the ones they operate.
SUB="$TMP/subhome"
mark_firstmate_home "$SUB"
mkdir -p "$SUB/data" "$SUB/state"
sed 's/fixture-k3/pfsub-k3/g' "$FIX/gitignored.md" > "$SUB/data/charter.md"
out=$(run_spawn "$ROOT/bin/fm-spawn.sh" pfsub-k3 "$SUB" codex --secondmate) || true
assert_not_contains "$out" "PREFLIGHT" "a secondmate charter is exempt from the preflight"

pass "T1 preflight spawn gate: refuses before anything is created, names the offender, lets clean work through"
