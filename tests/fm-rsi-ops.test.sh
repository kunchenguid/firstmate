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

test_classifier_allows_additive_tests() {
  local base candidate output lane
  base=$(git -C "$REPO" rev-parse HEAD)
  printf 'assert new_result is true\n' > "$REPO/additive_test.py"
  candidate=$(commit_fixture test-additive)
  output=$("$ROOT/bin/fm-rsi-classify-diff.sh" "$REPO" "$base" "$candidate")
  lane=$(printf '%s' "$output" | jq -r .lane)
  [ "$lane" = fast ] || fail "additive test diff was not fast: $output"
  pass "fm-rsi-classify-diff: permits additive tests"
}

test_classifier_rejects_case_variants_and_sensitive_paths() {
  local base candidate output
  base=$(git -C "$REPO" rev-parse HEAD)
  mkdir -p "$REPO/api" "$REPO/.github/workflows" "$REPO/AUTH"
  printf 'enabled = True\n' > "$REPO/api/server.py"
  printf 'name: deploy\n' > "$REPO/.github/workflows/deploy.yml"
  printf 'window.enabled = true;\n' > "$REPO/APP.JS"
  printf '<SCRIPT>window.enabled = true;</SCRIPT>\n' > "$REPO/PAGE.HTML"
  printf 'body { color: navy; }\n' > "$REPO/AUTH/theme.CSS"
  candidate=$(commit_fixture case-and-sensitive)
  output=$("$ROOT/bin/fm-rsi-classify-diff.sh" "$REPO" "$base" "$candidate")
  [ "$(printf '%s' "$output" | jq -r .lane)" = full ] || fail "case and sensitive diff was not full: $output"
  printf '%s' "$output" | jq -e '.reasons | index("behavior_file:api/server.py") != null' >/dev/null \
    || fail "Python behavior classification omitted evidence: $output"
  printf '%s' "$output" | jq -e '.reasons | index("behavior_file:APP.JS") != null' >/dev/null \
    || fail "uppercase JavaScript classification omitted evidence: $output"
  printf '%s' "$output" | jq -e '.reasons | index("script_touch:PAGE.HTML") != null' >/dev/null \
    || fail "uppercase HTML script classification omitted evidence: $output"
  printf '%s' "$output" | jq -e '.reasons | index("sensitive_path:.github/workflows/deploy.yml") != null' >/dev/null \
    || fail "workflow classification omitted sensitive-path evidence: $output"
  printf '%s' "$output" | jq -e '.reasons | index("sensitive_path:AUTH/theme.CSS") != null' >/dev/null \
    || fail "case-insensitive sensitive-path classification omitted evidence: $output"
  pass "fm-rsi-classify-diff: rejects behavior and sensitive path variants"
}

test_classifier_preserves_unusual_paths() {
  local base candidate output path
  path='café.js'
  base=$(git -C "$REPO" rev-parse HEAD)
  printf 'window.enabled = true;\n' > "$REPO/$path"
  candidate=$(commit_fixture unusual-path)
  output=$("$ROOT/bin/fm-rsi-classify-diff.sh" "$REPO" "$base" "$candidate")
  [ "$(printf '%s' "$output" | jq -r .lane)" = full ] || fail "unusual behavior path was not full: $output"
  [ "$(printf '%s' "$output" | jq -r '.files[0]')" = "$path" ] || fail "unusual path was not preserved: $output"
  printf '%s' "$output" | jq -e --arg reason "behavior_file:$path" '.reasons | index($reason) != null' >/dev/null \
    || fail "unusual behavior path omitted evidence: $output"
  pass "fm-rsi-classify-diff: preserves unusual Git paths"
}

test_classifier_freezes_moving_refs() {
  local moving_repo shim_dir real_git base frozen advanced output
  moving_repo="$TMP_ROOT/moving-repo"
  shim_dir="$TMP_ROOT/git-shim"
  real_git=$(command -v git)
  mkdir -p "$moving_repo" "$shim_dir"
  git -C "$moving_repo" init -q
  git -C "$moving_repo" config user.email tests@example.invalid
  git -C "$moving_repo" config user.name tests
  printf 'body { color: black; }\n' > "$moving_repo/style.css"
  git -C "$moving_repo" add .
  git -C "$moving_repo" commit -qm base
  base=$(git -C "$moving_repo" rev-parse HEAD)
  printf 'body { color: navy; }\n' > "$moving_repo/style.css"
  git -C "$moving_repo" commit -qam presentation
  frozen=$(git -C "$moving_repo" rev-parse HEAD)
  printf 'window.enabled = true;\n' > "$moving_repo/behavior.js"
  git -C "$moving_repo" add .
  git -C "$moving_repo" commit -qm behavior
  advanced=$(git -C "$moving_repo" rev-parse HEAD)
  git -C "$moving_repo" update-ref refs/heads/candidate "$frozen"
  cat > "$shim_dir/git" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = -C ] && [ "${2:-}" = "$MUTATION_REPO" ] && [ "${3:-}" = rev-parse ] && [ "${6:-}" = 'candidate^{commit}' ]; then
  resolved=$("$REAL_GIT" "$@") || exit $?
  printf '%s\n' "$resolved"
  "$REAL_GIT" -C "$MUTATION_REPO" update-ref refs/heads/candidate "$ADVANCED_SHA"
  exit 0
fi
exec "$REAL_GIT" "$@"
EOF
  chmod +x "$shim_dir/git"
  output=$(PATH="$shim_dir:$PATH" REAL_GIT="$real_git" MUTATION_REPO="$moving_repo" ADVANCED_SHA="$advanced" \
    "$ROOT/bin/fm-rsi-classify-diff.sh" "$moving_repo" "$base" candidate)
  [ "$(printf '%s' "$output" | jq -r .lane)" = fast ] || fail "moving ref changed the classified diff: $output"
  [ "$(git -C "$moving_repo" rev-parse candidate)" = "$advanced" ] || fail "moving-ref fixture did not advance candidate"
  pass "fm-rsi-classify-diff: freezes moving refs before classification"
}

test_canary() {
  local fixture output status candidate_sha positive
  fixture="$TMP_ROOT/canary.html"
  candidate_sha=0123456789012345678901234567890123456789
  positive="build-sha=$candidate_sha"
  printf '<meta name="build" content="%s">\n' "$positive" > "$fixture"
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
  output=$(PATH="$TMP_ROOT/bin:$PATH" CURL_FIXTURE="$fixture" "$ROOT/bin/fm-rsi-canary-bcs.sh" --candidate-sha "$candidate_sha" --positive "$positive" --attempts 1 --retry-seconds 0)
  [ "$(printf '%s' "$output" | jq -r .result)" = ok ] || fail "positive and negative canary did not pass: $output"
  printf 'gtag("config", "bad");\n' >> "$fixture"
  PATH="$TMP_ROOT/bin:$PATH" CURL_FIXTURE="$fixture" "$ROOT/bin/fm-rsi-canary-bcs.sh" --candidate-sha "$candidate_sha" --positive "$positive" --attempts 1 --retry-seconds 0 > "$TMP_ROOT/canary.out" || status=$?
  status=${status:-0}
  [ "$status" -eq 1 ] || fail "negative regression canary did not fail (exit $status)"
  [ "$(jq -r .result "$TMP_ROOT/canary.out")" = fail ] || fail "failed canary did not record fail result"
  pass "fm-rsi-canary-bcs: requires positive evidence and rejects a negative regression"
}

test_canary_validates_candidate_binding_and_regex() {
  local candidate_sha positive status
  candidate_sha=0123456789012345678901234567890123456789
  positive="build-sha=$candidate_sha"
  status=0
  "$ROOT/bin/fm-rsi-canary-bcs.sh" --candidate-sha "${candidate_sha}0" --positive "build-sha=${candidate_sha}0" --attempts 1 --retry-seconds 0 \
    > "$TMP_ROOT/canary-invalid-sha.out" 2> "$TMP_ROOT/canary-invalid-sha.err" || status=$?
  [ "$status" -eq 2 ] || fail "invalid full SHA length was accepted (exit $status)"
  status=0
  "$ROOT/bin/fm-rsi-canary-bcs.sh" --candidate-sha "$candidate_sha" --positive unrelated-marker --attempts 1 --retry-seconds 0 \
    > "$TMP_ROOT/canary-unbound.out" 2> "$TMP_ROOT/canary-unbound.err" || status=$?
  [ "$status" -eq 2 ] || fail "unbound positive marker was accepted (exit $status)"
  status=0
  "$ROOT/bin/fm-rsi-canary-bcs.sh" --candidate-sha "$candidate_sha" --positive "$positive" --negative-regex '[' --attempts 1 --retry-seconds 0 \
    > "$TMP_ROOT/canary-invalid-regex.out" 2> "$TMP_ROOT/canary-invalid-regex.err" || status=$?
  [ "$status" -eq 2 ] || fail "invalid negative regex was accepted (exit $status)"
  pass "fm-rsi-canary-bcs: validates candidate binding and negative regex"
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
test_classifier_allows_additive_tests
test_classifier_rejects_case_variants_and_sensitive_paths
test_classifier_preserves_unusual_paths
test_classifier_freezes_moving_refs
test_canary
test_canary_validates_candidate_binding_and_regex
test_ledger
