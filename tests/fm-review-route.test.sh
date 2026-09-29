#!/usr/bin/env bash
# Behavioral review routing and round-cap regression through the public CLI.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-review-route)
mkdir -p "$TMP_ROOT/bin" "$TMP_ROOT/home/state"
cp "$ROOT/bin/fm-review-route.sh" "$TMP_ROOT/bin/fm-review-route.sh"
ln -s "$ROOT/bin/fm-pr-lib.sh" "$TMP_ROOT/bin/fm-pr-lib.sh"
ln -s "$ROOT/bin/fm-wake-lib.sh" "$TMP_ROOT/bin/fm-wake-lib.sh"
ln -s "$ROOT/bin/fm-path-lib.sh" "$TMP_ROOT/bin/fm-path-lib.sh"
cat > "$TMP_ROOT/bin/fm-send.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_SEND_LOG"
[ "${FM_TEST_SEND_FAIL:-0}" = 0 ]
SH
chmod +x "$TMP_ROOT/bin/fm-send.sh" "$TMP_ROOT/bin/fm-review-route.sh"
STATE="$TMP_ROOT/home/state"
printf 'kind=ship\nyolo=on\n' > "$STATE/build.meta"
printf 'kind=secondmate\n' > "$STATE/reviewer.meta"
chmod 600 "$STATE"/*.meta
SEND_LOG="$TMP_ROOT/send.log"
export FM_TEST_SEND_LOG="$SEND_LOG"
route() { FM_HOME="$TMP_ROOT/home" FM_STATE_OVERRIDE="$STATE" bash "$TMP_ROOT/bin/fm-review-route.sh" "$@"; }
HEAD_A=0123456789abcdef0123456789abcdef01234567
HEAD_B=1123456789abcdef0123456789abcdef01234567
HEAD_C=2123456789abcdef0123456789abcdef01234567
PR=https://github.com/o/r/pull/7

route configure build security reviewer codex >/dev/null || fail 'could not configure review'
printf 'working [at=1]: build done commit=%s\n' "$HEAD_A" > "$STATE/build.status"
route scan build >/dev/null || fail 'build commit did not route review'
[ "$(wc -l < "$SEND_LOG")" -eq 1 ] || fail 'first review was not delivered exactly once'
route scan build >/dev/null || fail 'identical head was refused'
[ "$(wc -l < "$SEND_LOG")" -eq 1 ] || fail 'identical head sent another request'

printf 'pr=%s\npr_head=%s\n' "$PR" "$HEAD_B" >> "$STATE/build.meta"
route scan build >/dev/null || fail 'new PR head did not route a review'
[ "$(wc -l < "$SEND_LOG")" -eq 2 ] || fail 'changed head did not cause exactly one new request'
sed "s/pr_head=$HEAD_B/pr_head=$HEAD_C/" "$STATE/build.meta" > "$STATE/build.meta.tmp"
mv "$STATE/build.meta.tmp" "$STATE/build.meta"
if route scan build > "$TMP_ROOT/cap.out" 2>&1; then fail 'third review without a finding was accepted'; fi
[ "$(wc -l < "$SEND_LOG")" -eq 2 ] || fail 'review cap sent a third request'
[ -f "$STATE/build.review-cap-escalated" ] || fail 'review cap did not escalate'
route request build "$PR" "$HEAD_C" security codex correctness-17 'blocking correctness regression in settlement' >/dev/null \
  || fail 'named blocking correctness exception was refused'
[ "$(wc -l < "$SEND_LOG")" -eq 3 ] || fail 'blocking finding did not route one exception'
route request build "$PR" "$HEAD_C" security codex correctness-17 'blocking correctness regression in settlement' >/dev/null \
  || fail 'repeated exception was refused'
[ "$(wc -l < "$SEND_LOG")" -eq 3 ] || fail 'repeated exception sent again'
printf 'kind=ship\nyolo=on\n' > "$STATE/fix.meta"
chmod 600 "$STATE/fix.meta"
: > "$SEND_LOG"
route configure fix security reviewer codex >/dev/null || fail 'could not configure fix review'
printf 'pr=%s\npr_head=%s\n' "$PR" "$HEAD_A" >> "$STATE/fix.meta"
route scan fix >/dev/null || fail 'registered PR head did not route review'
printf 'working [at=2]: build done commit=%s\n' "$HEAD_B" > "$STATE/fix.status"
route scan fix >/dev/null || fail 'pushed fix commit after PR registration did not route'
[ "$(wc -l < "$SEND_LOG")" -eq 2 ] || fail 'stale recorded PR head suppressed the fix commit review'
grep -q "$HEAD_B" "$SEND_LOG" || fail 'fix commit review did not name its exact head'
route scan fix >/dev/null || fail 'routed fix head was refused on rescan'
[ "$(wc -l < "$SEND_LOG")" -eq 2 ] || fail 'rescan routed an already reviewed head'

printf 'kind=ship\npr=%s\npr_head=%s\n' "$PR" "$HEAD_A" > "$STATE/manual.meta"
chmod 600 "$STATE/manual.meta"
: > "$SEND_LOG"
route configure manual security reviewer codex >/dev/null || fail 'could not configure manual review'
route request manual "$PR" "$HEAD_C" security codex >/dev/null \
  || fail 'manual request for a head newer than the recorded PR head was refused'
grep -q "$HEAD_C" "$SEND_LOG" || fail 'manual request did not route its exact head'

pass 'review dispatch binds exact heads, deduplicates receipts, and caps ordinary rounds at two'
