#!/usr/bin/env bash
# Behavior tests for the ChatGPT-bound captain-facing return transport.
# Covers primary-only atomic write (including a simulated interrupted write),
# secondmate refusal, crewmate live-path refusal through equivalent spellings
# and through a dangling symlink, cross-repo PR-identity dedup, and the
# count/list QA that caught the four-vs-three PR report.
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
  assert_equals "$(realpath -m -- "$dest")" "$out" "write did not print the canonical destination"
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

# Atomicity: a crash exactly at the rename step must never leave the
# destination truncated or replaced by a partial file. Simulate it with a PATH
# shim that fails only the specific mv into the .fm-chatgpt-return.* staging
# name atomic_replace uses (every other mv, including any the test fixtures
# themselves rely on, passes through to the real mv unchanged), then confirm
# the destination still holds its untouched prior content and no stray staged
# temp file was left behind in the inbox directory.
test_interrupted_write_never_truncates_destination() {
  local home dest fakebin real_mv
  home=$(make_home atomic)
  dest=$TMP_ROOT/inbox-atomic/FIRST_MATE_TO_CHATGPT.md
  mkdir -p "$(dirname "$dest")"
  printf 'Prior stable return.\n' > "$dest"
  real_mv=$(command -v mv)
  fakebin=$(fm_fakebin "$TMP_ROOT/atomic-shim")
  cat > "$fakebin/mv" <<SH
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in
    *.fm-chatgpt-return.*) exit 1 ;;
  esac
done
exec "$real_mv" "\$@"
SH
  chmod +x "$fakebin/mv"
  printf 'Should never land.\n' > "$TMP_ROOT/atomic-body.md"
  if PATH="$fakebin:$PATH" write_return "$home" "$dest" --status complete \
    --return-file "$TMP_ROOT/atomic-body.md" \
    > "$TMP_ROOT/atomic.out" 2> "$TMP_ROOT/atomic.err"; then
    fail "write reported success despite the failed rename step"
  fi
  assert_grep "could not replace" "$TMP_ROOT/atomic.err" \
    "failure did not name the replace step"
  assert_grep "Prior stable return." "$dest" \
    "a failed rename corrupted or truncated the live destination"
  assert_no_grep "Should never land." "$dest" \
    "a failed rename let new content reach the live destination"
  local leftover
  leftover=$(find "$(dirname "$dest")" -maxdepth 1 -name '.fm-chatgpt-return.*' 2>/dev/null)
  assert_equals "" "$leftover" "a failed rename left a stray staged temp file behind"
  pass "a crash at the rename step leaves the prior destination content intact and stages no debris"
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
  if FM_HOME="$home" FM_TASK_ID=overnight-local-control-repair \
    FM_CHATGPT_RETURN_NOW="$NOW" \
    "$RETURN" write --status complete --return-file "$TMP_ROOT/crew-body.md" \
    > "$TMP_ROOT/crew.out" 2> "$TMP_ROOT/crew.err"; then
    fail "a task worker wrote the live ChatGPT return"
  fi
  assert_grep "must not write the live ChatGPT return" "$TMP_ROOT/crew.err" \
    "crewmate live-path refusal did not name the boundary"
  pass "a task worker cannot write the live ChatGPT return"
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
    if FM_HOME="$home" FM_TASK_ID=overnight-local-control-repair \
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

# Diagnosed defect #1 (dangling-symlink canonicalization): a naive per-component
# canonicalizer that gives up and falls back to the literal path the instant it
# meets a symlink whose target does not (yet) exist would let a task worker
# alias the live default through a dangling symlink and have the guard see two
# "different" paths, even though both ultimately name the live file. `realpath
# -m` must still resolve through the dangling hop to the live file's own
# canonical path, so this must refuse exactly like the direct live path does.
test_crewmate_dangling_symlink_to_live_path_refuses() {
  local home fake_home dangling
  home=$(make_home crew-dangling)
  # Use a fake $HOME for this invocation only, never the real captain $HOME:
  # the live default is derived from $HOME at script start, so overriding it
  # here lets the test put the live default's own leaf file in a state it
  # controls (absent) without ever touching real captain data.
  fake_home=$TMP_ROOT/crew-dangling-fake-home
  mkdir -p "$fake_home"
  dangling="$TMP_ROOT/crew-dangling-symlink.md"
  # The live default ($fake_home/inbox/FIRST_MATE_TO_CHATGPT.md) does not
  # exist, so this symlink to it is dangling at the moment the guard runs -
  # the exact case a full-existence-requiring canonicalizer mishandles.
  assert_absent "$fake_home/inbox/FIRST_MATE_TO_CHATGPT.md" \
    "test setup assumption violated: the fake live default already exists"
  ln -s "$fake_home/inbox/FIRST_MATE_TO_CHATGPT.md" "$dangling"
  printf 'Should not land.\n' > "$TMP_ROOT/crew-dangling-body.md"
  if HOME="$fake_home" FM_HOME="$home" FM_TASK_ID=overnight-local-control-repair \
    FM_CHATGPT_RETURN_PATH="$dangling" \
    FM_CHATGPT_RETURN_NOW="$NOW" \
    "$RETURN" write --status complete \
    --return-file "$TMP_ROOT/crew-dangling-body.md" \
    > "$TMP_ROOT/crew-dangling.out" 2> "$TMP_ROOT/crew-dangling.err"; then
    fail "a task worker wrote the live path via a dangling symlink alias"
  fi
  assert_grep "must not write the live ChatGPT return" "$TMP_ROOT/crew-dangling.err" \
    "dangling-symlink alias refusal did not name the boundary"
  assert_absent "$fake_home/inbox/FIRST_MATE_TO_CHATGPT.md" \
    "the dangling-symlink bypass actually created the live file"
  pass "a task worker cannot bypass the guard via a dangling symlink to the live path"
}

# Diagnosed defect #3 (FM_TASK_ID trust gap): FM_TASK_ID is an optional,
# caller-controlled environment variable, so a task worker invoked through an
# environment-clearing wrapper (or one that simply forgets to set it) could
# previously write the live default path unchallenged. The fix adds a second,
# non-caller-controlled signal: the script's own root must be a genuine
# primary checkout (fm_primary_scope_matches), not a linked task worktree -
# exactly the topology every real spawned task runs in. This builds a real
# git worktree fixture (matching production: a bare origin, a primary
# checkout, and a linked worktree sharing its git dir) to prove the refusal
# fires from worktree identity alone, with FM_TASK_ID deliberately unset.
test_worktree_root_refuses_live_path_even_without_task_id() {
  local repo worktree fake_home
  repo=$TMP_ROOT/worktree-fixture-repo
  worktree=$TMP_ROOT/worktree-fixture-worktree
  fake_home=$TMP_ROOT/worktree-fixture-fake-home
  mkdir -p "$fake_home"
  fm_git_worktree "$repo" "$worktree" task-branch
  mkdir -p "$worktree/bin" "$worktree/state"
  printf '# Worktree fixture\n' > "$worktree/AGENTS.md"
  printf 'Should not land.\n' > "$TMP_ROOT/worktree-fixture-body.md"
  if env -u FM_TASK_ID HOME="$fake_home" FM_HOME="$worktree" FM_ROOT_OVERRIDE="$worktree" \
    FM_STATE_OVERRIDE="$worktree/state" FM_CHATGPT_RETURN_NOW="$NOW" \
    "$RETURN" write --status complete \
    --return-file "$TMP_ROOT/worktree-fixture-body.md" \
    > "$TMP_ROOT/worktree-fixture.out" 2> "$TMP_ROOT/worktree-fixture.err"; then
    fail "a linked-worktree root wrote the live ChatGPT return with FM_TASK_ID unset"
  fi
  assert_grep "must not write the live ChatGPT return" "$TMP_ROOT/worktree-fixture.err" \
    "worktree-identity refusal did not name the boundary"
  assert_absent "$fake_home/inbox/FIRST_MATE_TO_CHATGPT.md" \
    "the worktree bypass actually created the live file"
  pass "a linked task worktree is refused from the live path even with FM_TASK_ID unset"
}

# The positive counterpart: a genuine non-worktree primary checkout, with
# FM_TASK_ID unset, is still allowed to write its own live default path -
# fm_primary_scope_matches must not turn into a blanket refusal.
test_genuine_primary_root_may_write_live_path() {
  local primary dest
  primary=$TMP_ROOT/primary-fixture-repo
  fm_git_init_commit "$primary"
  mkdir -p "$primary/bin" "$primary/state"
  printf '# Primary fixture\n' > "$primary/AGENTS.md"
  dest="$primary/inbox/FIRST_MATE_TO_CHATGPT.md"
  printf 'Real primary return.\n' > "$TMP_ROOT/primary-fixture-body.md"
  # HOME is overridden so the script's own DEFAULT_RETURN_PATH (derived from
  # $HOME) resolves under this fixture, and --return-path is deliberately
  # omitted so the write targets that real default, not a test-chosen path.
  env -u FM_TASK_ID HOME="$primary" FM_HOME="$primary" FM_ROOT_OVERRIDE="$primary" \
    FM_STATE_OVERRIDE="$primary/state" FM_CHATGPT_RETURN_NOW="$NOW" \
    "$RETURN" write --status complete \
    --return-file "$TMP_ROOT/primary-fixture-body.md" >/dev/null \
    || fail "a genuine primary checkout could not write its own live default path"
  assert_present "$dest" "the genuine primary's write did not land"
  pass "a genuine non-worktree primary checkout may still write its own live default path"
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

# Diagnosed defect #2 (repo-identity dedup): a return spanning two repos can
# legitimately mention "#6" once per repo. Deduping by bare number alone
# collapses those into one item and would wrongly fail a correct "two PRs"
# claim; deduping by repo+number must count them as two distinct items.
test_verify_cross_repo_same_number_not_conflated() {
  local ok
  ok=$TMP_ROOT/cross-repo.md
  cat > "$ok" <<'EOF'
Two PRs landed across two repos:

- **owner-a/repo-one#6** - fix the parser
- **owner-a/repo-two#6** - fix the renderer
EOF
  "$RETURN" verify --file "$ok" >/dev/null \
    || fail "cross-repo PR#6/PR#6 report was wrongly rejected as under-counted"
  pass "verify counts the same PR number in two different repos as two items"
}

test_verify_bare_mentions_still_dedup_within_one_repo() {
  local ok
  ok=$TMP_ROOT/same-repo.md
  cat > "$ok" <<'EOF'
One PR landed: https://github.com/owner-a/repo-one/pull/6 (also referenced as #6 above).
EOF
  "$RETURN" verify --file "$ok" >/dev/null \
    || fail "a URL and its own bare #N mention were wrongly counted as two items"
  pass "a repo-qualified reference and its own bare mention still collapse to one item"
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

# Diagnosed defect #4 (PR-count/list QA gap): a claimed count with a list of
# title-only bullets naming no PR number must still be checked against the
# bullet count, not waved through because collect_pr_ids found nothing.
test_verify_rejects_title_only_bullets_undercounting_the_claim() {
  local bad
  bad=$TMP_ROOT/title-only.md
  cat > "$bad" <<'EOF'
Three PRs landed:

- Fix the parser
- Fix the renderer
EOF
  if "$RETURN" verify --file "$bad" > "$TMP_ROOT/title-only.out" 2> "$TMP_ROOT/title-only.err"; then
    fail "a claim of three PRs with only two title-only bullets passed QA"
  fi
  assert_grep "claimed 3 PRs but listed 2 items" "$TMP_ROOT/title-only.err" \
    "QA did not fall back to counting title-only bullets"
  pass "verify counts title-only list bullets when no PR identity is present"
}

test_verify_agrees_inline_and_rejects_four_vs_three
test_verify_cross_repo_same_number_not_conflated
test_verify_bare_mentions_still_dedup_within_one_repo
test_verify_rejects_title_only_bullets_undercounting_the_claim
test_write_assembles_and_replaces
test_interrupted_write_never_truncates_destination
test_secondmate_refuses
test_crewmate_live_path_refuses
test_crewmate_equivalent_path_spellings_refuse
test_crewmate_dangling_symlink_to_live_path_refuses
test_worktree_root_refuses_live_path_even_without_task_id
test_genuine_primary_root_may_write_live_path
test_write_refuses_disagreeing_body
