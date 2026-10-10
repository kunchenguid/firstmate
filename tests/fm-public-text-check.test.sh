#!/usr/bin/env bash
# Exercise exact outgoing publication text and the generated worker command.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-dod-lib.sh
. "$ROOT/bin/fm-dod-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-public-text-check)
CHECK="$ROOT/bin/fm-public-text-check.sh"

# shellcheck disable=SC2016 # Markdown backticks are literal publication input.
unsafe=(
  'Private proof: /Users/example/private/report.md'
  '`/home/example/proof.txt`'
  'Evidence at /private/var/folders/example/report.md'
  'Evidence: /tmp/example/proof.md'
  'Evidence: /workspace/firstmate/data/task/report.md'
  'Evidence: file:///Users/example/proof.md'
  'Evidence: ~/private/report.md'
  'Evidence: C:\Users\example\proof.md'
  'Evidence: \\example\private\proof.md'
  'Private proof: data/example-task/report.md'
  'Private evidence: state/example-task.status'
  'Evidence: .no-mistakes/runs/example/proof.md'
  'Evidence: http://localhost:8080/proof'
  'Evidence: https://proof.local/report'
  'Private proof: report.md'
)
for text in "${unsafe[@]}"; do
  printf '%s\n' "$text" > "$TMP_ROOT/input"
  cp "$TMP_ROOT/input" "$TMP_ROOT/before"
  if "$CHECK" "$TMP_ROOT/input" > "$TMP_ROOT/out" 2> "$TMP_ROOT/err"; then
    fail "accepted private reference"
  fi
  cmp -s "$TMP_ROOT/input" "$TMP_ROOT/before" || fail "mutated private evidence"
  assert_grep 'line 1' "$TMP_ROOT/err" 'missing location-only diagnostic'
  grep -Fq "$text" "$TMP_ROOT/err" && fail "echoed sensitive input"
done
pass "private references are rejected without disclosure or mutation"

cat > "$TMP_ROOT/public" <<'EOF'
Benchmarks passed 50 iterations with zero failed oracle comparisons.
Source: tests/benchmark.test.sh; state/parser.go; data/schema/report.md.
Public proof: https://github.com/example/repo/actions/runs/123
Public URL paths stay intact: https://example.org/home/example/report.md
Intended system examples: /usr/bin/env, /etc/hosts and /dev/null.
Web route example: /api/v1/users.
EOF
"$CHECK" "$TMP_ROOT/public" || fail 'valid public explanation rejected'
"$CHECK" - < "$TMP_ROOT/public" || fail 'stdin public explanation rejected'
pass "repository paths, public URLs, system examples and useful facts survive"

# Consume the command from the rendered delivery instructions, not source bytes.
for mode in direct-PR no-mistakes; do
  fm_dod_block "$mode" example-task > "$TMP_ROOT/$mode.md"
  command=$(awk '/owns the public-evidence policy/ { sub(/^`/, ""); sub(/`.*/, ""); print; exit }' "$TMP_ROOT/$mode.md")
  [ -n "$command" ] || fail "$mode omitted the publication check"
  if printf '%s\n' 'Private proof: /Users/example/private/report.md' | bash -c "$command -" > "$TMP_ROOT/out" 2> "$TMP_ROOT/err"; then
    fail "$mode generated command accepted private proof"
  fi
  bash -c "$command -" < "$TMP_ROOT/public" || fail "$mode generated command rejected public facts"
done
pass "both generated delivery paths execute the same publication policy"

# The real public reply interface must refuse before recording or transport.
for method in answer followup; do
  home="$TMP_ROOT/$method"
  mkdir -p "$home"
  args=()
  [ "$method" = answer ] || args=(--followup)
  if FM_HOME="$home" FMX_DRY_RUN=1 "$ROOT/bin/fm-x-reply.sh" example-request "${args[@]}" \
    'Private proof: /Users/example/private/report.md' > "$TMP_ROOT/out" 2> "$TMP_ROOT/err"; then
    fail "$method accepted private proof"
  fi
  [ ! -e "$home/state/x-outbox" ] || fail "$method recorded unsafe outbound text"
  ! grep -q '/Users/example' "$TMP_ROOT/err" || fail "$method disclosed rejected text"
  FM_HOME="$home" FMX_DRY_RUN=1 FMX_REPLY_PLATFORM=x FMX_REPLY_MAX_CHARS=280 \
    "$ROOT/bin/fm-x-reply.sh" example-request "${args[@]}" \
    'Benchmark: 50 iterations passed without oracle mismatches.' > "$TMP_ROOT/out" 2> "$TMP_ROOT/err" \
    || fail "$method refused useful public validation"
done
pass "answer and followup refuse private text before their publication boundary"
