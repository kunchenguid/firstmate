#!/usr/bin/env bash
# G1: threshold selection. A captain sentinel at total>=185k is selected for
# restart; a crew sentinel at used_pct>=50 is selected; sub-threshold sentinels
# are not. Mutation (LEDGER_MUTATE=1): drop the captain total below the floor — a
# correct fm_ctx_select then stops selecting it, so the assertion fails (proving
# the test is keyed to the real threshold behavior, not vacuous).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-context-watch.sh
. "$ROOT/bin/fm-context-watch.sh"

STATE=$(mktemp -d "${TMPDIR:-/tmp}/fm-ctx-g1.XXXXXX")
trap 'rm -rf "$STATE"' EXIT

write_ctx() {  # <key> <role> <total> <pct>
  printf '{"window":"%s","tmux_target":"%%9","role":"%s","total_tokens":%s,"used_pct":%s,"exceeds_200k":false,"managed":true,"ts":0}' \
    "$1" "$2" "$3" "$4" > "$STATE/ctx-$1.json"
}

CAP_TOTAL=190000
[ "${LEDGER_MUTATE:-}" = 1 ] && CAP_TOTAL=170000   # mutation: below the 185k floor

write_ctx caphot   captain "$CAP_TOTAL" 95
write_ctx capcold  captain 170000       80
write_ctx crewhot  crew    50000        60
write_ctx crewcold crew    30000        40

sel=$(fm_ctx_select "$STATE")

printf '%s\n' "$sel" | grep -qx caphot   || fail "captain over floor must be selected (got: $sel)"
printf '%s\n' "$sel" | grep -qx capcold  && fail "captain under floor must NOT be selected"
printf '%s\n' "$sel" | grep -qx crewhot  || fail "crew over 50% must be selected (got: $sel)"
printf '%s\n' "$sel" | grep -qx crewcold && fail "crew under 50% must NOT be selected"

pass "G1 threshold selection (captain>=185k, crew>=50%)"
