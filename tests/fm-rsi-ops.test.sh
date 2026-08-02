#!/usr/bin/env bash
# Behavior tests for the RSI W1 classifier, canary, and append-only ledger.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-rsi-ops)
REPO="$TMP_ROOT/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email tests@example.invalid
git -C "$REPO" config user.name tests

commit_fixture() {
  git -C "$REPO" add .
  git -C "$REPO" commit -qm "$1"
  git -C "$REPO" rev-parse HEAD
}

test_classifier() {
  local base candidate output lane
  printf '<main>base</main>\n' > "$REPO/page.html"
  printf 'body { color: black; }\n' > "$REPO/style.css"
  base=$(commit_fixture base)
  printf 'body { color: navy; }\n' > "$REPO/style.css"
  candidate=$(commit_fixture presentation)
  output=$("$ROOT/bin/fm-rsi-classify-diff.sh" "$REPO" "$base" "$candidate")
  lane=$(printf '%s' "$output" | jq -r .lane)
  [ "$lane" = fast ] || fail "presentation-only diff was not fast: $output"

  base=$candidate
  printf 'export const state = true;\n' > "$REPO/behavior.ts"
  candidate=$(commit_fixture behavior)
  output=$("$ROOT/bin/fm-rsi-classify-diff.sh" "$REPO" "$base" "$candidate")
  lane=$(printf '%s' "$output" | jq -r .lane)
  [ "$lane" = full ] || fail "TypeScript diff was not full: $output"
  printf '%s' "$output" | jq -e '.reasons[] == "behavior_file:behavior.ts"' >/dev/null \
    || fail "TypeScript classification omitted behavior evidence: $output"

  base=$candidate
  printf '<main><script>window.enabled = true;</script></main>\n' > "$REPO/page.html"
  candidate=$(commit_fixture script)
  output=$("$ROOT/bin/fm-rsi-classify-diff.sh" "$REPO" "$base" "$candidate")
  lane=$(printf '%s' "$output" | jq -r .lane)
  [ "$lane" = full ] || fail "HTML script change was not full: $output"
  printf '%s' "$output" | jq -e '.reasons[] == "script_touch:page.html"' >/dev/null \
    || fail "HTML script classification omitted script evidence: $output"
  pass "fm-rsi-classify-diff: classifies presentation, behavior, and script changes from the diff"
}

test_classifier_rejects_non_additive_tests() {
  local base candidate output lane
  printf 'assert result is true\n' > "$REPO/safety_test.py"
  base=$(commit_fixture test-base)
  printf 'assert result is false\n' > "$REPO/safety_test.py"
  candidate=$(commit_fixture test-weaken)
  output=$("$ROOT/bin/fm-rsi-classify-diff.sh" "$REPO" "$base" "$candidate")
  lane=$(printf '%s' "$output" | jq -r .lane)
  [ "$lane" = full ] || fail "weakened test diff was not full: $output"
  printf '%s' "$output" | jq -e '.reasons[] == "test_not_additive:safety_test.py"' >/dev/null \
    || fail "test classification omitted additive-only evidence: $output"
  pass "fm-rsi-classify-diff: rejects changed test assertions from the fast lane"
}

test_canary() {
  local fixture output status
  fixture="$TMP_ROOT/canary.html"
  printf '<meta name="build" content="sha-123">\n' > "$fixture"
  mkdir -p "$TMP_ROOT/bin"
  cat > "$TMP_ROOT/bin/curl" <<'EOF'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) cp "$CURL_FIXTURE" "$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf 200
EOF
  chmod +x "$TMP_ROOT/bin/curl"
  output=$(PATH="$TMP_ROOT/bin:$PATH" CURL_FIXTURE="$fixture" "$ROOT/bin/fm-rsi-canary-bcs.sh" --candidate-sha 0123456789012345678901234567890123456789 --positive sha-123 --attempts 1 --retry-seconds 0)
  [ "$(printf '%s' "$output" | jq -r .result)" = ok ] || fail "positive and negative canary did not pass: $output"
  printf 'gtag("config", "bad");\n' >> "$fixture"
  PATH="$TMP_ROOT/bin:$PATH" CURL_FIXTURE="$fixture" "$ROOT/bin/fm-rsi-canary-bcs.sh" --candidate-sha 0123456789012345678901234567890123456789 --positive sha-123 --attempts 1 --retry-seconds 0 > "$TMP_ROOT/canary.out" || status=$?
  status=${status:-0}
  [ "$status" -eq 1 ] || fail "negative regression canary did not fail (exit $status)"
  [ "$(jq -r .result "$TMP_ROOT/canary.out")" = fail ] || fail "failed canary did not record fail result"
  pass "fm-rsi-canary-bcs: requires positive evidence and rejects a negative regression"
}

test_ledger() {
  local home ledger output
  home="$TMP_ROOT/home"
  ledger="$home/data/rsi-events.jsonl"
  output=$(FM_HOME="$home" "$ROOT/bin/fm-rsi-ledger-append.sh" rsi-job bcs 0123456789012345678901234567890123456789 failed fail evidence://gate "gate failed")
  [ -f "$ledger" ] || fail "ledger helper did not create its FM_HOME ledger"
  [ "$(wc -l < "$ledger" | tr -d ' ')" = 1 ] || fail "ledger helper did not append exactly one row"
  [ "$(printf '%s' "$output" | jq -r .observer)" = firstmate ] || fail "ledger helper did not record firstmate observer"
  [ "$(jq -r .kind "$ledger")" = failed ] || fail "ledger helper did not preserve failed event kind"
  pass "fm-rsi-ledger-append: appends one firstmate-observed failed event"
}

test_classifier
test_classifier_rejects_non_additive_tests
test_canary
test_ledger
