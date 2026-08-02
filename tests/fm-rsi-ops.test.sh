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

test_classifier_rejects_mdx_and_all_script_tag_forms() {
  local base candidate output
  base=$(git -C "$REPO" rev-parse HEAD)
  printf 'export const enabled = true\n\n# Executable MDX\n' > "$REPO/page.mdx"
  printf '.. raw:: html\n\n   <script src="app.js"></script>\n' > "$REPO/guide.rst"
  printf '<svg><script href="app.js"/></svg>\n' > "$REPO/icon.svg"
  printf '<svg><svg:script href="app.js"/></svg>\n' > "$REPO/namespaced.svg"
  printf '<main><script src="app.js">\n' > "$REPO/fragment.html"
  candidate=$(commit_fixture executable-markup)
  output=$("$ROOT/bin/fm-rsi-classify-diff.sh" "$REPO" "$base" "$candidate")
  [ "$(printf '%s' "$output" | jq -r .lane)" = full ] || fail "executable markup diff was not full: $output"
  printf '%s' "$output" | jq -e '.reasons | index("behavior_file:page.mdx") != null' >/dev/null \
    || fail "executable MDX classification omitted evidence: $output"
  printf '%s' "$output" | jq -e '.reasons | index("script_touch:guide.rst") != null' >/dev/null \
    || fail "raw RST script classification omitted evidence: $output"
  printf '%s' "$output" | jq -e '.reasons | index("script_touch:icon.svg") != null' >/dev/null \
    || fail "self-closing SVG script classification omitted evidence: $output"
  printf '%s' "$output" | jq -e '.reasons | index("script_touch:namespaced.svg") != null' >/dev/null \
    || fail "namespaced SVG script classification omitted evidence: $output"
  printf '%s' "$output" | jq -e '.reasons | index("script_touch:fragment.html") != null' >/dev/null \
    || fail "unmatched HTML script classification omitted evidence: $output"
  pass "fm-rsi-classify-diff: rejects MDX and every script tag form"
}

test_classifier_rejects_script_relocation() {
  local base candidate output
  printf '<head><script src="app.js"></script></head><body></body>\n' > "$REPO/relocated.html"
  base=$(commit_fixture script-position-base)
  printf '<head></head><body><script src="app.js"></script></body>\n' > "$REPO/relocated.html"
  candidate=$(commit_fixture script-position-candidate)
  output=$("$ROOT/bin/fm-rsi-classify-diff.sh" "$REPO" "$base" "$candidate")
  [ "$(printf '%s' "$output" | jq -r .lane)" = full ] || fail "relocated script diff was not full: $output"
  printf '%s' "$output" | jq -e '.reasons | index("script_touch:relocated.html") != null' >/dev/null \
    || fail "relocated script classification omitted evidence: $output"
  pass "fm-rsi-classify-diff: rejects script relocation"
}

test_classifier_rejects_non_regular_entries() {
  local gitlink_repo base candidate output
  gitlink_repo="$TMP_ROOT/gitlink-repo"
  mkdir -p "$gitlink_repo"
  git -C "$gitlink_repo" init -q
  git -C "$gitlink_repo" config user.email tests@example.invalid
  git -C "$gitlink_repo" config user.name tests
  printf 'base\n' > "$gitlink_repo/readme.txt"
  git -C "$gitlink_repo" add .
  git -C "$gitlink_repo" commit -qm base
  base=$(git -C "$gitlink_repo" rev-parse HEAD)
  git -C "$gitlink_repo" update-index --add --cacheinfo 160000 "$base" manual.md
  git -C "$gitlink_repo" commit -qm gitlink
  candidate=$(git -C "$gitlink_repo" rev-parse HEAD)
  output=$("$ROOT/bin/fm-rsi-classify-diff.sh" "$gitlink_repo" "$base" "$candidate")
  [ "$(printf '%s' "$output" | jq -r .lane)" = full ] || fail "gitlink diff was not full: $output"
  printf '%s' "$output" | jq -e '.reasons | index("non_regular_entry:manual.md") != null' >/dev/null \
    || fail "gitlink classification omitted non-regular evidence: $output"
  pass "fm-rsi-classify-diff: rejects non-regular tree entries"
}

test_classifier_overrides_submodule_ignore() {
  local gitlink_repo initial gitlink_base candidate output
  gitlink_repo="$TMP_ROOT/gitlink-ignore-repo"
  mkdir -p "$gitlink_repo"
  git -C "$gitlink_repo" init -q
  git -C "$gitlink_repo" config user.email tests@example.invalid
  git -C "$gitlink_repo" config user.name tests
  printf 'base\n' > "$gitlink_repo/readme.txt"
  git -C "$gitlink_repo" add .
  git -C "$gitlink_repo" commit -qm initial
  initial=$(git -C "$gitlink_repo" rev-parse HEAD)
  git -C "$gitlink_repo" update-index --add --cacheinfo 160000 "$initial" manual.md
  printf 'body { color: black; }\n' > "$gitlink_repo/style.css"
  git -C "$gitlink_repo" add style.css
  git -C "$gitlink_repo" commit -qm gitlink-base
  gitlink_base=$(git -C "$gitlink_repo" rev-parse HEAD)
  git -C "$gitlink_repo" update-index --cacheinfo 160000 "$gitlink_base" manual.md
  printf 'body { color: navy; }\n' > "$gitlink_repo/style.css"
  git -C "$gitlink_repo" add style.css
  git -C "$gitlink_repo" commit -qm gitlink-candidate
  candidate=$(git -C "$gitlink_repo" rev-parse HEAD)
  git -C "$gitlink_repo" config diff.ignoreSubmodules all
  output=$("$ROOT/bin/fm-rsi-classify-diff.sh" "$gitlink_repo" "$gitlink_base" "$candidate")
  [ "$(printf '%s' "$output" | jq -r .lane)" = full ] || fail "ignored gitlink update was not full: $output"
  printf '%s' "$output" | jq -e '.files | index("manual.md") != null' >/dev/null \
    || fail "submodule-ignore config hid the gitlink from evidence: $output"
  printf '%s' "$output" | jq -e '.reasons | index("non_regular_entry:manual.md") != null' >/dev/null \
    || fail "ignored gitlink update omitted non-regular evidence: $output"
  pass "fm-rsi-classify-diff: overrides ambient submodule ignore"
}

test_classifier_disables_textconv_for_tests() {
  local textconv_repo filter base candidate output
  textconv_repo="$TMP_ROOT/textconv-repo"
  filter="$TMP_ROOT/textconv-constant.sh"
  mkdir -p "$textconv_repo"
  git -C "$textconv_repo" init -q
  git -C "$textconv_repo" config user.email tests@example.invalid
  git -C "$textconv_repo" config user.name tests
  printf '#!/usr/bin/env bash\nprintf "constant\\n"\n' > "$filter"
  chmod +x "$filter"
  git -C "$textconv_repo" config diff.constant.textconv "$filter"
  printf '*.test.txt diff=constant\n' > "$textconv_repo/.gitattributes"
  printf 'assert first\nassert second\n' > "$textconv_repo/safety.test.txt"
  git -C "$textconv_repo" add .
  git -C "$textconv_repo" commit -qm test-base
  base=$(git -C "$textconv_repo" rev-parse HEAD)
  printf 'assert first\n' > "$textconv_repo/safety.test.txt"
  git -C "$textconv_repo" commit -qam test-candidate
  candidate=$(git -C "$textconv_repo" rev-parse HEAD)
  output=$("$ROOT/bin/fm-rsi-classify-diff.sh" "$textconv_repo" "$base" "$candidate")
  [ "$(printf '%s' "$output" | jq -r .lane)" = full ] || fail "textconv-hidden test deletion was not full: $output"
  printf '%s' "$output" | jq -e '.reasons | index("test_not_additive:safety.test.txt") != null' >/dev/null \
    || fail "raw test deletion omitted additive-only evidence: $output"
  pass "fm-rsi-classify-diff: disables textconv for test evidence"
}

test_classifier_disables_replacement_refs() {
  local replacement_repo base candidate replacement output
  replacement_repo="$TMP_ROOT/replacement-repo"
  mkdir -p "$replacement_repo"
  git -C "$replacement_repo" init -q
  git -C "$replacement_repo" config user.email tests@example.invalid
  git -C "$replacement_repo" config user.name tests
  printf 'body { color: black; }\n' > "$replacement_repo/style.css"
  git -C "$replacement_repo" add .
  git -C "$replacement_repo" commit -qm base
  base=$(git -C "$replacement_repo" rev-parse HEAD)
  printf 'body { color: navy; }\n' > "$replacement_repo/style.css"
  git -C "$replacement_repo" commit -qam candidate
  candidate=$(git -C "$replacement_repo" rev-parse HEAD)
  git -C "$replacement_repo" checkout -q --detach "$base"
  printf 'body { color: navy; }\n' > "$replacement_repo/style.css"
  printf 'window.enabled = true;\n' > "$replacement_repo/behavior.js"
  git -C "$replacement_repo" add .
  git -C "$replacement_repo" commit -qm replacement
  replacement=$(git -C "$replacement_repo" rev-parse HEAD)
  git -C "$replacement_repo" replace "$candidate" "$replacement"
  output=$("$ROOT/bin/fm-rsi-classify-diff.sh" "$replacement_repo" "$base" "$candidate")
  [ "$(printf '%s' "$output" | jq -r .lane)" = fast ] || fail "replacement ref changed frozen diff evidence: $output"
  [ "$(printf '%s' "$output" | jq -r '.files | join(",")')" = style.css ] \
    || fail "replacement ref injected paths into frozen diff evidence: $output"
  pass "fm-rsi-classify-diff: disables replacement refs for all evidence"
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
  local candidate_sha positive multiline_fixture multiline_positive status
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
  multiline_fixture="$TMP_ROOT/canary-multiline.html"
  printf 'unrelated body\n' > "$multiline_fixture"
  multiline_positive="${positive}"$'\n'
  PATH="$TMP_ROOT/bin:$PATH" CURL_FIXTURE="$multiline_fixture" \
    "$ROOT/bin/fm-rsi-canary-bcs.sh" --candidate-sha "$candidate_sha" --positive "$multiline_positive" --attempts 1 --retry-seconds 0 \
    > "$TMP_ROOT/canary-multiline.out" 2> "$TMP_ROOT/canary-multiline.err" || status=$?
  [ "$status" -eq 2 ] || fail "multiline positive marker was accepted (exit $status)"
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

test_ledger_validates_full_sha_lengths() {
  local home ledger candidate_sha64 output status
  home="$TMP_ROOT/ledger-sha-validation"
  ledger="$home/data/rsi-events.jsonl"
  status=0
  FM_HOME="$home" "$ROOT/bin/fm-rsi-ledger-append.sh" rsi-job bcs 01234567890123456789012345678901234567890 failed fail evidence://gate \
    > "$TMP_ROOT/ledger-invalid-sha.out" 2> "$TMP_ROOT/ledger-invalid-sha.err" || status=$?
  [ "$status" -eq 2 ] || fail "invalid ledger SHA length was accepted (exit $status)"
  [ ! -e "$ledger" ] || fail "invalid ledger SHA created or changed the append-only ledger"
  candidate_sha64=0123456789012345678901234567890123456789012345678901234567890123
  output=$(FM_HOME="$home" "$ROOT/bin/fm-rsi-ledger-append.sh" rsi-job bcs "$candidate_sha64" failed fail evidence://gate)
  [ "$(printf '%s' "$output" | jq -r .candidate_sha)" = "$candidate_sha64" ] || fail "64-character ledger SHA was not preserved"
  pass "fm-rsi-ledger-append: accepts only exact full SHA lengths"
}

test_classifier
test_classifier_rejects_non_additive_tests
test_classifier_allows_additive_tests
test_classifier_rejects_case_variants_and_sensitive_paths
test_classifier_rejects_mdx_and_all_script_tag_forms
test_classifier_rejects_script_relocation
test_classifier_rejects_non_regular_entries
test_classifier_overrides_submodule_ignore
test_classifier_disables_textconv_for_tests
test_classifier_disables_replacement_refs
test_classifier_preserves_unusual_paths
test_classifier_freezes_moving_refs
test_canary
test_canary_validates_candidate_binding_and_regex
test_ledger
test_ledger_validates_full_sha_lengths
