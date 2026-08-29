#!/usr/bin/env bash
# I2: the spawn hard gate. With a brief present, a ship spawn must refuse when
# state/<id>.intake is missing or ends in revise (WARDROOM banner, no side
# effects); proceed-last and --scout pass the gate (and then fail later in the
# spawn machinery for unrelated fixture reasons - asserted only as "no WARDROOM
# refusal"); FM_INTAKE_OVERRIDE=1 bypasses loudly.
# Mutation (LEDGER_MUTATE=1): with revise as the last intake, the test asserts
# the spawn gets PAST the wardroom (no refusal banner) - a correct gate refuses.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-intake-lib.sh
. "$ROOT/bin/fm-intake-lib.sh"

TMP=$(fm_test_tmproot fm-wd-i2)
HOME_DIR="$TMP/home"
mkdir -p "$HOME_DIR/data/i2task" "$HOME_DIR/state" "$HOME_DIR/projects/alpha"
printf '# Task\nDo the thing.\n' > "$HOME_DIR/data/i2task/brief.md"
S="$HOME_DIR/state"

# Every spawn below pins the harness explicitly. Ambient harness detection is an
# environment fact (CLAUDECODE, process ancestry), and where it resolves to
# 'unknown' - CI runners - fm-spawn dies on the missing launch template before it
# ever reaches the wardroom gate this suite is testing.
run_spawn() {  # <extra-env...> -- <spawn-args...>
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' \
    FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' FM_SPAWN_NO_GUARD=1 \
    "$@" 2>&1
}

# 1. ship + brief + no intake -> WARDROOM refusal
out=$(run_spawn "$ROOT/bin/fm-spawn.sh" i2task projects/alpha codex); code=$?
[ "$code" -ne 0 ] || fail "ship spawn without intake must exit non-zero"
assert_contains "$out" "WARDROOM" "refusal shows the Wardroom banner"
assert_contains "$out" "REFUSED" "refusal is explicit"

# 2. revise-last -> refusal (mutation: expects to get past the gate)
fm_intake_append "$S" i2task panel "lens none stub"
fm_intake_append "$S" i2task revise "needs work"
out=$(run_spawn "$ROOT/bin/fm-spawn.sh" i2task projects/alpha codex); code=$?
[ "$code" -ne 0 ] || fail "spawn must still exit non-zero"
if [ "${LEDGER_MUTATE:-}" = 1 ]; then
  assert_not_contains "$out" "REFUSED" "MUTATION: revise-last expected to pass the wardroom"
else
  assert_contains "$out" "REFUSED" "revise-last must refuse"
fi

# 3. proceed-last -> passes the gate (later fixture failure is fine, but not a wardroom one)
fm_intake_append "$S" i2task proceed "vetted"
out=$(run_spawn "$ROOT/bin/fm-spawn.sh" i2task projects/alpha codex) || true
assert_not_contains "$out" "REFUSED" "proceed-last must pass the wardroom gate"

# 4. scout exempt: no intake for a different id, --scout passes the gate
mkdir -p "$HOME_DIR/data/i2scout"
printf '# Task\nScout it.\n' > "$HOME_DIR/data/i2scout/brief.md"
out=$(run_spawn "$ROOT/bin/fm-spawn.sh" i2scout projects/alpha codex --scout) || true
assert_not_contains "$out" "REFUSED" "scout spawn must be exempt from the wardroom"

# 5. override bypasses loudly (fresh ship id, no intake)
mkdir -p "$HOME_DIR/data/i2ovr"
printf '# Task\nShip it.\n' > "$HOME_DIR/data/i2ovr/brief.md"
out=$(FM_INTAKE_OVERRIDE=1 run_spawn "$ROOT/bin/fm-spawn.sh" i2ovr projects/alpha codex) || true
assert_contains "$out" "OVERRIDE" "override prints the warning banner"
assert_not_contains "$out" "REFUSED" "override must not refuse"

pass "I2 spawn hard gate"
