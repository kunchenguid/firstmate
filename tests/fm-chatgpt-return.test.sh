#!/usr/bin/env bash
# Behavior tests for the ChatGPT-bound captain-facing return transport.
# Covers primary-only atomic write, secondmate refusal, crewmate live-path
# refusal, and the count/list QA that caught the four-vs-three PR report.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RETURN="$ROOT/bin/fm-chatgpt-return.sh"
TMP_ROOT=$(fm_test_tmproot fm-chatgpt-return)
NOW=2026-09-12T15:04:05Z

make_home() {  # <name>
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '# Seeded Firstmate home\n' > "$home/AGENTS.md"
  printf '%s\n' "$home"
}

write_return() {  # <home> <dest> extra args...
  local home=$1 dest=$2
  shift 2
  FM_HOME="$home" FM_CHATGPT_RETURN_PATH="$dest" FM_CHATGPT_RETURN_NOW="$NOW" \
    "$RETURN" write "$@"
}

test_write_assembles_and_replaces() {
  local home dest out
  home=$(make_home primary)
  dest=$TMP_ROOT/inbox/FIRST_MATE_TO_CHATGPT.md
  printf 'Ship completed.\n' > "$TMP_ROOT/body1.md"
  out=$(write_return "$home" "$dest" --status complete \
    --return-file "$TMP_ROOT/body1.md" \
    --task follow-on-packet \
    --artifact "$TMP_ROOT/body1.md" \
    --blocker "publish the live page") || fail "primary write failed"
  assert_equals "$dest" "$out" "write did not print the destination"
  assert_present "$dest" "write did not create the transport file"
  assert_grep "Generated: $NOW" "$dest" "missing timestamp"
  assert_grep "Originating task/packet: follow-on-packet" "$dest" "missing task"
  assert_grep "Result/status: complete" "$dest" "missing status"
  assert_grep "Ship completed." "$dest" "missing concise return"
  assert_grep "$TMP_ROOT/body1.md" "$dest" "missing artifact path"
  assert_grep "publish the live page" "$dest" "missing blocker"
  assert_grep "CLEAR_SAFE: YES" "$dest" "missing Clear Safety footer"
  printf 'Second return.\n' > "$TMP_ROOT/body2.md"
  write_return "$home" "$dest" --status complete \
    --return-file "$TMP_ROOT/body2.md" >/dev/null \
    || fail "replacement write failed"
  assert_grep "Second return." "$dest" "replacement lost the new return"
  assert_no_grep "Ship completed." "$dest" "replacement kept the previous return"
  pass "primary write is complete, atomic replace, and ChatGPT-bound"
}

test_secondmate_refuses() {
  local home dest
  home=$(make_home mate)
  printf 'mate\n' > "$home/.fm-secondmate-home"
  dest=$TMP_ROOT/inbox-mate/FIRST_MATE_TO_CHATGPT.md
  printf 'Should not land.\n' > "$TMP_ROOT/mate-body.md"
  if write_return "$home" "$dest" --status complete \
    --return-file "$TMP_ROOT/mate-body.md" \
    > "$TMP_ROOT/mate.out" 2> "$TMP_ROOT/mate.err"; then
    fail "a secondmate home wrote the ChatGPT return"
  fi
  assert_grep "secondmate homes must not write" "$TMP_ROOT/mate.err" \
    "secondmate refusal did not name the boundary"
  assert_absent "$dest" "secondmate write created the transport file"
  pass "secondmate homes cannot overwrite the ChatGPT return"
}

test_crewmate_live_path_refuses() {
  local home
  home=$(make_home crew)
  printf 'Should not land.\n' > "$TMP_ROOT/crew-body.md"
  if FM_HOME="$home" FM_TASK_ID=followon-decision-filter \
    FM_CHATGPT_RETURN_NOW="$NOW" \
    "$RETURN" write --status complete --return-file "$TMP_ROOT/crew-body.md" \
    > "$TMP_ROOT/crew.out" 2> "$TMP_ROOT/crew.err"; then
    fail "a task worker wrote the live ChatGPT return"
  fi
  assert_grep "must not write the live ChatGPT return" "$TMP_ROOT/crew.err" \
    "crewmate live-path refusal did not name the boundary"
  pass "a task worker cannot write the live ChatGPT return"
}

test_crewmate_explicit_live_path_refuses() {
  local home
  home=$(make_home crew-explicit)
  printf 'Should not land.\n' > "$TMP_ROOT/crew-explicit-body.md"
  if FM_HOME="$home" FM_TASK_ID=followon-decision-filter \
    FM_CHATGPT_RETURN_PATH="$HOME/inbox/FIRST_MATE_TO_CHATGPT.md" \
    FM_CHATGPT_RETURN_NOW="$NOW" \
    "$RETURN" write --status complete \
    --return-file "$TMP_ROOT/crew-explicit-body.md" \
    > "$TMP_ROOT/crew-explicit.out" 2> "$TMP_ROOT/crew-explicit.err"; then
    fail "a task worker wrote the live path by passing it explicitly"
  fi
  assert_grep "must not write the live ChatGPT return" "$TMP_ROOT/crew-explicit.err" \
    "explicit-live-path refusal did not name the boundary"
  pass "a task worker cannot bypass the guard by passing the live path explicitly"
}

test_crewmate_equivalent_path_spellings_refuse() {
  local home live_default symlink_path variant
  home=$(make_home crew-variant)
  live_default="$HOME/inbox/FIRST_MATE_TO_CHATGPT.md"
  symlink_path="$TMP_ROOT/crew-variant-symlink.md"
  ln -s "$live_default" "$symlink_path"
  for variant in \
    "$HOME/inbox/./FIRST_MATE_TO_CHATGPT.md" \
    "$HOME//inbox/FIRST_MATE_TO_CHATGPT.md" \
    "$HOME/inbox/../inbox/FIRST_MATE_TO_CHATGPT.md" \
    "$symlink_path"; do
    printf 'Should not land.\n' > "$TMP_ROOT/crew-variant-body.md"
    if FM_HOME="$home" FM_TASK_ID=followon-decision-filter \
      FM_CHATGPT_RETURN_PATH="$variant" \
      FM_CHATGPT_RETURN_NOW="$NOW" \
      "$RETURN" write --status complete \
      --return-file "$TMP_ROOT/crew-variant-body.md" \
      > "$TMP_ROOT/crew-variant.out" 2> "$TMP_ROOT/crew-variant.err"; then
      fail "a task worker wrote the live path via the spelling: $variant"
    fi
    assert_grep "must not write the live ChatGPT return" "$TMP_ROOT/crew-variant.err" \
      "equivalent-path refusal did not name the boundary for: $variant"
  done
  pass "a task worker cannot bypass the guard via an equivalent path spelling"
}

test_verify_agrees_inline_and_rejects_four_vs_three() {
  local ok bad
  ok=$TMP_ROOT/ok.md
  bad=$TMP_ROOT/bad.md
  cat > "$ok" <<'EOF'
All four governance/content PRs from this packet are merged (#32, #33, #34, and now #6).
EOF
  "$RETURN" verify --file "$ok" >/dev/null \
    || fail "inline four-PR glance failed QA"
  cat > "$bad" <<'EOF'
Four PRs landed in brentwarnes-repo/ai-work-proof-engine-governance, all merged:

- **PR #32** - Proof-WIP retirement, HUMAN_PROJECT_TRACKER refresh,
  Idea Gate / Roadmap Gate rebuild.
- **PR #33** - North-Star documents
- **PR #34** - Idea Gate machine enforcement
EOF
  if "$RETURN" verify --file "$bad" > "$TMP_ROOT/bad.out" 2> "$TMP_ROOT/bad.err"; then
    fail "four-claimed three-listed report passed QA"
  fi
  assert_grep "claimed 4 PRs but listed 3 items" "$TMP_ROOT/bad.err" \
    "QA did not name the four-vs-three disagreement"
  pass "enumerated PR counts must agree with listed items"
}

test_write_refuses_disagreeing_body() {
  local home dest
  home=$(make_home qa)
  dest=$TMP_ROOT/inbox-qa/FIRST_MATE_TO_CHATGPT.md
  mkdir -p "$(dirname "$dest")"
  printf 'prior\n' > "$dest"
  cat > "$TMP_ROOT/bad-body.md" <<'EOF'
Four PRs landed in the governance repo:

- **PR #32**
- **PR #33**
- **PR #34**
EOF
  if write_return "$home" "$dest" --status complete \
    --return-file "$TMP_ROOT/bad-body.md" \
    > "$TMP_ROOT/qa.out" 2> "$TMP_ROOT/qa.err"; then
    fail "write published a disagreeing completion report"
  fi
  assert_grep "claimed 4 PRs but listed 3 items" "$TMP_ROOT/qa.err" \
    "write QA did not name the disagreement"
  assert_grep "prior" "$dest" "failed write replaced the previous transport"
  pass "write refuses a return whose enumerated counts disagree"
}

test_verify_agrees_inline_and_rejects_four_vs_three
test_write_assembles_and_replaces
test_secondmate_refuses
test_crewmate_live_path_refuses
test_crewmate_explicit_live_path_refuses
test_crewmate_equivalent_path_spellings_refuse
test_write_refuses_disagreeing_body
