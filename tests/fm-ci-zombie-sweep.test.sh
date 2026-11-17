#!/usr/bin/env bash
# Behavior of bin/fm-ci-zombie-sweep.sh: runs older than the age limit are
# listed in a dry run, cancelled only with --apply, and only for this fork.
# A PATH stub stands in for gh and logs every call.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SWEEP="$ROOT/bin/fm-ci-zombie-sweep.sh"
TMP_ROOT=$(fm_test_tmproot fm-ci-zombie-sweep)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
export STUB_LOG="$TMP_ROOT/calls.log"
NOW=1800000000   # pinned clock
iso() { perl -MPOSIX=strftime -e 'print strftime("%Y-%m-%dT%H:%M:%SZ", gmtime($ARGV[0])), "\n"' "$1"; }
OLD=$(iso $((NOW - 5 * 86400)))
EDGE=$(iso $((NOW - 25 * 3600)))
FRESH=$(iso $((NOW - 3600)))

cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
case "$*" in
  "api rate_limit"*) printf '%s\n' "${STUB_REMAINING:-4000}" ;;
  *"status=queued"*)
    printf '101\tqueued\t%s\tCI\n102\tqueued\t%s\tCI\n103\tqueued\t%s\tCI\n' "$STUB_OLD" "$STUB_FRESH" "$STUB_EDGE" ;;
  *"status=waiting"*) ;;
  *"status=in_progress"*) printf '104\tin_progress\t%s\tNightly\n' "$STUB_OLD" ;;
  "api -X POST "*"/cancel") [ "${STUB_CANCEL_FAIL:-}" != "${4##*/runs/}" ] || exit 1 ;;
  *) exit 1 ;;
esac
SH
chmod +x "$FAKEBIN/gh"

run_sweep() {  # <args...>; sets OUT, RC
  : > "$STUB_LOG"
  RC=0
  OUT=$(PATH="$FAKEBIN:$PATH" FM_CI_SWEEP_NOW=$NOW STUB_OLD="$OLD" STUB_EDGE="$EDGE" STUB_FRESH="$FRESH" \
    "$SWEEP" "$@" 2>&1) || RC=$?
}

# Dry run: lists every run over 24h, writes nothing to the forge.
run_sweep
[ "$RC" -eq 0 ] || fail "dry run exited $RC: $OUT"
assert_contains "$OUT" "would-cancel: 101 queued 120h CI" "the 5-day-old queued run was not listed"
assert_contains "$OUT" "would-cancel: 103 queued 25h CI" "the 25h-old queued run was not listed"
assert_contains "$OUT" "would-cancel: 104 in_progress 120h Nightly" "the stuck in-progress run was not listed"
assert_not_contains "$OUT" "102" "a run under the age limit was listed"
assert_contains "$OUT" "mode=dry-run" "the dry-run summary is missing"
assert_contains "$OUT" "found=3 cancelled=0" "the dry-run counts are wrong: $OUT"
assert_not_contains "$(cat "$STUB_LOG")" "POST" "the dry run cancelled something"
pass "a dry run lists zombie runs over 24h and cancels nothing"

# A longer limit narrows the set.
run_sweep --max-age-hours 48
assert_contains "$OUT" "found=2 cancelled=0" "--max-age-hours 48 should keep only the 5-day-old runs: $OUT"
pass "--max-age-hours changes the zombie threshold"

# Apply cancels exactly the zombies.
run_sweep --apply
[ "$RC" -eq 0 ] || fail "apply exited $RC: $OUT"
assert_contains "$OUT" "cancelled: 101 queued" "run 101 was not cancelled"
assert_contains "$OUT" "found=3 cancelled=3 failed=0" "the apply counts are wrong: $OUT"
posts=$(grep -c '^api -X POST ' "$STUB_LOG")
assert_equals 3 "$posts" "apply must cancel exactly the three zombies"
assert_not_contains "$(cat "$STUB_LOG")" "runs/102/" "a fresh run was cancelled"
pass "--apply cancels exactly the zombie runs"

# A failed cancel is reported and fails the sweep.
RC=0
: > "$STUB_LOG"
OUT=$(PATH="$FAKEBIN:$PATH" FM_CI_SWEEP_NOW=$NOW STUB_OLD="$OLD" STUB_EDGE="$EDGE" STUB_FRESH="$FRESH" STUB_CANCEL_FAIL=104/cancel \
  "$SWEEP" --apply 2>&1) || RC=$?
[ "$RC" -ne 0 ] || fail "a failed cancel did not fail the sweep"
assert_contains "$OUT" "cancel-failed: 104" "the failed cancel was not reported"
pass "a failed cancel is reported and fails the sweep"

# Scope: only this fork, refused before any forge call.
for other in miko-systems/miko NoMistakes/firstmate doitdigital0495/other; do
  run_sweep --repo "$other" --apply
  [ "$RC" -ne 0 ] || fail "a sweep of $other was accepted"
  assert_contains "$OUT" "scoped to doitdigital0495/firstmate only" "the scope refusal did not name the fork"
  [ ! -s "$STUB_LOG" ] || fail "a refused repo still reached gh: $(cat "$STUB_LOG")"
done
run_sweep --repo doitdigital0495/firstmate
[ "$RC" -eq 0 ] || fail "an explicit fork repo was refused: $OUT"
pass "the sweep is scoped to the fork and refuses any other repository before calling gh"

# A low REST budget holds the sweep.
RC=0
: > "$STUB_LOG"
OUT=$(PATH="$FAKEBIN:$PATH" FM_CI_SWEEP_NOW=$NOW STUB_REMAINING=120 "$SWEEP" --apply 2>&1) || RC=$?
[ "$RC" -eq 0 ] || fail "a held sweep should exit 0: $OUT"
assert_contains "$OUT" "held: REST budget 120" "the low-budget hold was not reported"
assert_not_contains "$(cat "$STUB_LOG")" "actions/runs" "a held sweep still listed runs"
pass "a low REST budget holds the sweep"

run_sweep --bogus
[ "$RC" -eq 2 ] || fail "an unknown option exited $RC, not 2"
run_sweep --max-age-hours 0
[ "$RC" -ne 0 ] || fail "a zero age limit was accepted"
pass "bad arguments are refused"
