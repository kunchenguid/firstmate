#!/usr/bin/env bash
# Topic index path refusal, AGENTS.md marker match, and the 3200-word ceiling.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INDEX="$ROOT/bin/fm-contract-index.sh"
TMP_ROOT=$(fm_test_tmproot fm-contract-index)

write_topics() {  # <name> <path-cell>
  local file=$TMP_ROOT/$1.tsv
  printf '%s\n' $'id\ttrigger\tpath' >"$file"
  printf $'%s\t%s\n' $'sample\ta real trigger' "$2" >>"$file"
  printf '%s\n' "$file"
}

expect_refuse() {  # <path-cell> <label>
  local file out err code
  file=$(write_topics "$2" "$1")
  err=$TMP_ROOT/$2.err
  out=$("$INDEX" --check "$file" 2>"$err")
  code=$?
  assert_not_equals 0 "$code" "$2 was accepted"
  assert_equals '' "$out" "$2 wrote a table"
  assert_contains "$(cat "$err")" "refuse path: $1" "$2 did not refuse the path"
}

test_tracked_topics_match_agents_index() {
  local out err code words agents
  err=$TMP_ROOT/tracked.err
  out=$("$INDEX" --check 2>"$err")
  code=$?
  assert_equals 0 "$code" "tracked topics failed check"
  assert_equals '' "$out" "check printed a marker diff"
  assert_equals '' "$(cat "$err")" "check wrote an error"
  out=$("$INDEX" render 2>"$err")
  assert_contains "$out" '| quota-array | a matched profile array must be ranked | .agents/skills/quota-array-dispatch/SKILL.md |' \
    "render dropped the quota-array topic"
  assert_contains "$out" '| harness-dispatch | before spawn, recovery, or choosing among a dispatch-profile array | .agents/contract/harness-dispatch.md |' \
    "render dropped the harness-dispatch topic"
  assert_contains "$out" '| task-lifecycle | filing, holding, dispatching, or merging when the skill triggers above do not already apply | .agents/contract/task-lifecycle.md |' \
    "render dropped the task-lifecycle topic"
  assert_contains "$out" '| captain-voice | a captain-facing reply needs the internal-to-outcome glossary | .agents/contract/captain-voice.md |' \
    "render dropped the captain-voice topic"
  assert_contains "$out" '| supervision-wake | a wake kind is not covered by the emitted supervision block | .agents/contract/supervision-wake.md |' \
    "render dropped the supervision-wake topic"
  assert_contains "$out" '| layout | locating or changing home, config, data, state, or project paths | .agents/skills/operational-home-layout/SKILL.md |' \
    "render dropped the layout topic"
  agents=$(cat "$ROOT/AGENTS.md")
  assert_contains "$agents" '| harness-dispatch | before spawn, recovery, or choosing among a dispatch-profile array | .agents/contract/harness-dispatch.md |' \
    "AGENTS.md index omitted harness-dispatch"
  assert_contains "$agents" '<!-- fm-contract-index:begin -->' "AGENTS.md lost the index begin marker"
  assert_contains "$agents" '<!-- fm-contract-index:end -->' "AGENTS.md lost the index end marker"
  words=$(wc -w <"$ROOT/AGENTS.md" | tr -d '[:space:]')
  [ "$words" -le 3200 ] || fail "AGENTS.md is $words words"
  pass "tracked topics match the AGENTS.md index under the word ceiling"
}

test_check_rejects_drift_and_ceiling() {
  local copy err out code words file
  copy=$TMP_ROOT/agents.md
  err=$TMP_ROOT/agents.err
  {
    printf '%s\n' '<!-- fm-contract-index:begin -->'
    "$INDEX" render
    printf '%s\n' '<!-- fm-contract-index:end -->'
  } >"$copy"
  export FM_CONTRACT_AGENTS=$copy
  out=$("$INDEX" --check 2>"$err")
  code=$?
  assert_equals 0 "$code" "a matching copy failed check"
  assert_equals '' "$out" "a matching copy printed a table"
  sed 's|harness-dispatch.md|harness-dispatch-drift.md|' "$copy" >"$TMP_ROOT/drift.md"
  mv "$TMP_ROOT/drift.md" "$copy"
  out=$("$INDEX" --check 2>"$err")
  code=$?
  assert_not_equals 0 "$code" "a drifted index was accepted"
  assert_equals '' "$out" "a drifted index printed a table"
  assert_contains "$(cat "$err")" 'AGENTS.md contract index drifted' "drift was not reported"
  {
    printf '%s\n' '<!-- fm-contract-index:begin -->'
    "$INDEX" render
    printf '%s\n' '<!-- fm-contract-index:end -->'
    python3 -c 'print("pad " * 3300, end="")'
  } >"$copy"
  out=$("$INDEX" --check 2>"$err")
  code=$?
  words=$(wc -w <"$copy" | tr -d '[:space:]')
  assert_not_equals 0 "$code" "a file over 3200 words was accepted"
  assert_equals '' "$out" "a fat file printed a table"
  assert_contains "$(cat "$err")" "fm-contract-index: AGENTS.md is $words words; ceiling is 3200" \
    "the ceiling message did not name the word count"
  printf '%s\n' 'no markers here' >"$copy"
  out=$("$INDEX" --check 2>"$err")
  code=$?
  assert_not_equals 0 "$code" "missing markers were accepted"
  assert_contains "$(cat "$err")" 'AGENTS.md contract index markers missing or repeated' \
    "missing markers were not reported"
  file=$(write_topics ok-with-broken-agents '.agents/skills/quota-array-dispatch/SKILL.md')
  out=$("$INDEX" --check "$file" 2>"$err")
  code=$?
  assert_equals 0 "$code" "an explicit topic table consulted AGENTS.md"
  assert_equals '' "$out" "an explicit topic table printed a table"
  unset FM_CONTRACT_AGENTS
  pass "check rejects a drifted index, a file over 3200 words, and missing markers"
}

test_refuse_escaping_paths() {
  local home_path missing file out err code
  expect_refuse '/etc/passwd' absolute
  expect_refuse '.agents/../../bin/fm-lock.sh' dotdot
  # shellcheck disable=SC2016 # The topic cell is a literal dollar path.
  expect_refuse '$HOME/secret' dollar
  expect_refuse 'state/.afk' state
  expect_refuse 'data/captain.md' data
  home_path=${HOME}/.agents/skills/quota-array-dispatch/SKILL.md
  expect_refuse "$home_path" home
  missing=$(write_topics missing '.agents/skills/does-not-exist/SKILL.md')
  err=$TMP_ROOT/missing.err
  out=$("$INDEX" --check "$missing" 2>"$err")
  code=$?
  assert_not_equals 0 "$code" "missing path was accepted"
  assert_contains "$(cat "$err")" 'refuse path: .agents/skills/does-not-exist/SKILL.md' \
    "missing path was not refused"
  file=$(write_topics ok '.agents/skills/quota-array-dispatch/SKILL.md')
  out=$("$INDEX" --check "$file" 2>"$TMP_ROOT/ok.err")
  code=$?
  assert_equals 0 "$code" "skill path that exists was refused"
  assert_equals '' "$out" "accepted topic check printed a table"
  pass "index refuses absolute, parent, dollar, home, state, data, and missing paths"
}

test_tracked_topics_match_agents_index
test_refuse_escaping_paths
test_check_rejects_drift_and_ceiling
