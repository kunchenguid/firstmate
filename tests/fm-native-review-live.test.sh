#!/usr/bin/env bash
# Opt-in credentialed smoke test for the installed Codex/TraeX native-review
# interfaces. It uses isolated temporary repositories and never changes a
# project checkout. Run one harness at a time:
#   FM_NATIVE_REVIEW_LIVE=codex tests/fm-native-review-live.test.sh
#   FM_NATIVE_REVIEW_LIVE=traex tests/fm-native-review-live.test.sh
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HARNESS=${FM_NATIVE_REVIEW_LIVE:-}
case "$HARNESS" in
  '') skip "set FM_NATIVE_REVIEW_LIVE=codex or traex for the credentialed native-review smoke test" ;;
  codex|traex) ;;
  *) fail "FM_NATIVE_REVIEW_LIVE must be codex or traex" ;;
esac
command -v "$HARNESS" >/dev/null 2>&1 || fail "$HARNESS is not installed"

TMP_ROOT=$(fm_test_tmproot "fm-native-review-live-$HARNESS")
home="$TMP_ROOT/home"
repo="$TMP_ROOT/repo"
mkdir -p "$home/data/live-review" "$home/state" "$repo"
git -C "$repo" init -q
git -C "$repo" config user.email test@example.com
git -C "$repo" config user.name test
printf 'base\n' > "$repo/value.txt"
git -C "$repo" add value.txt
git -C "$repo" commit -qm base
base=$(git -C "$repo" rev-parse HEAD)
printf 'candidate\n' >> "$repo/value.txt"
git -C "$repo" commit -qam candidate
candidate=$(git -C "$repo" rev-parse HEAD)
printf 'worktree=%s\nharness=%s\n' "$repo" "$HARNESS" > "$home/state/live-review.meta"
cat > "$home/data/live-review/brief.md" <<'EOF'
# Task
## Captain's intent
Verify the installed native review interface on an isolated trivial change.

## Firstmate spec
Report only concrete correctness issues and bind the exact base and candidate.
EOF

output="$home/data/live-review/evidence.md"
FM_HOME="$home" "$ROOT/bin/fm-native-review.sh" live-review \
  --base "$base" --candidate "$candidate" --output "$output"
assert_grep "Harness: \`$HARNESS\`" "$output" "live evidence omitted the installed harness"
assert_grep "Candidate: \`$candidate\`" "$output" "live evidence omitted the exact candidate"
assert_grep 'INTENT_CONFORMANCE: pass' "$output" "installed reviewer did not pass the isolated candidate"
pass "installed $HARNESS native review binds identity, intent, and final response"
