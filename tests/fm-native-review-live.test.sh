#!/usr/bin/env bash
# Opt-in credentialed smoke test for the installed configured Codex native
# reviewer. It uses an isolated temporary repository and never changes a
# project checkout:
#   FM_NATIVE_REVIEW_LIVE=codex FM_NATIVE_REVIEW_MODEL=<model> \
#     FM_NATIVE_REVIEW_EFFORT=<effort> tests/fm-native-review-live.test.sh
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HARNESS=${FM_NATIVE_REVIEW_LIVE:-}
case "$HARNESS" in
  '') skip "set FM_NATIVE_REVIEW_LIVE=codex with model and effort for the credentialed native-review smoke test" ;;
  codex) ;;
  *) fail "FM_NATIVE_REVIEW_LIVE must be codex" ;;
esac
command -v "$HARNESS" >/dev/null 2>&1 || fail "$HARNESS is not installed"
MODEL=${FM_NATIVE_REVIEW_MODEL:-}
EFFORT=${FM_NATIVE_REVIEW_EFFORT:-}
[ -n "$MODEL" ] && [ -n "$EFFORT" ] || fail "FM_NATIVE_REVIEW_MODEL and FM_NATIVE_REVIEW_EFFORT are required"

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
  --base "$base" --candidate "$candidate" --output "$output" \
  --review-harness "$HARNESS" --model "$MODEL" --effort "$EFFORT"
assert_grep "Reviewer harness: \`$HARNESS\`" "$output" "live evidence omitted the installed reviewer harness"
assert_grep "Reviewer model: \`$MODEL\`" "$output" "live evidence omitted the explicit reviewer model"
assert_grep "Reviewer effort: \`$EFFORT\`" "$output" "live evidence omitted the effective reviewer effort"
assert_grep "reasoning effort: $EFFORT" "$output" "installed reviewer did not apply the selected effort"
assert_grep "Candidate: \`$candidate\`" "$output" "live evidence omitted the exact candidate"
assert_grep 'INTENT_CONFORMANCE: pass' "$output" "installed reviewer did not pass the isolated candidate"
pass "installed $HARNESS native review binds identity, intent, and final response"
