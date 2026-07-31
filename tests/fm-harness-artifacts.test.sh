#!/usr/bin/env bash
# tests/fm-harness-artifacts.test.sh - the per-harness turn-end / busy-state
# artifact inventory is ONE owner, and every consumer reads it.
#
# Regression origin. OpenCode's wiring file was renamed
# .opencode/plugins/fm-turn-end.js -> .opencode/plugins/fm-busy-state.js. The
# installer and two of bin/fm-teardown.sh's FOUR worktree removal blocks were
# updated; the orca-child block and the ORDINARY task block were not. Both kept
# removing a name fm-spawn no longer writes, so on the ordinary teardown path an
# OpenCode task cleaned nothing and leaked the plugin into a worktree treehouse
# then returned to the pool. The dirty-check allowlist was a seventh independent
# spelling and never covered .opencode/ at all.
#
# The structural guard is what these tests assert: the paths live in
# bin/harnesses/<name>.sh, and spawn's exclude plus every teardown removal path
# derive from that one list. The strongest case here is
# test_installed_artifacts_are_all_removed, which reads the paths fm-spawn
# actually writes out of fm-spawn itself and proves each is removed - so a future
# rename that updates only the installer fails this suite instead of silently
# leaking again.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-harness-adapter.sh"

TMP_ROOT=$(fm_test_tmproot fm-harness-artifacts)

ADAPTER_HARNESSES="claude codex opencode pi pi-signed grok kimi"

# --- inventory shape ---------------------------------------------------------

test_every_known_harness_resolves_an_adapter() {
  local h
  for h in $ADAPTER_HARNESSES; do
    fm_harness_is_known "$h" || fail "fm_harness_is_known rejected verified harness '$h'"
    fm_harness_source "$h" || fail "fm_harness_source failed for '$h'"
    # Both lists must be DECLARED, though either may be empty: codex writes
    # nothing, and pi writes only outside the worktree. An undeclared list means
    # an adapter was added without stating its artifacts, which is exactly the
    # silence this suite exists to prevent.
    fm_harness_worktree_artifacts "$h" >/dev/null \
      || fail "harness '$h' does not declare a worktree artifact list"
  done
  fm_harness_worktree_artifacts nosuch-harness >/dev/null 2>&1 \
    && fail "an unregistered harness must not resolve an artifact list"

  # kimi is a crewmate harness but deliberately NOT a primary one.
  fm_harness_is_primary kimi \
    && fail "kimi must not be a primary harness: README lists six and there is no kimi supervision protocol"
  fm_harness_is_primary claude \
    || fail "claude must be a primary harness"

  pass "every verified harness resolves an adapter and declares its artifacts"
}

test_pi_signed_shares_the_pi_adapter() {
  [ "$(fm_harness_adapter_name pi-signed)" = pi ] \
    || fail "pi-signed must resolve to the pi adapter"
  [ "$(fm_harness_worktree_artifacts pi)" = "$(fm_harness_worktree_artifacts pi-signed)" ] \
    || fail "pi and pi-signed must resolve one artifact list"
  # pi's wiring lives OUTSIDE the worktree to dodge Pi's project-trust gate, so
  # an empty worktree list with a non-empty state list is the correct shape.
  [ -z "$(fm_harness_worktree_artifacts pi)" ] \
    || fail "pi must declare no worktree artifacts; its extension lives in the state dir"
  assert_contains "$(fm_harness_state_artifacts_all demo)" 'demo.pi-ext.ts' \
    "pi's state artifact must appear in the union with the task id substituted"
  pass "pi-signed shares pi's adapter, and pi's artifact stays outside the worktree"
}

test_union_is_deduplicated_and_id_substituted() {
  local union
  union=$(fm_harness_state_artifacts_all task-42)
  assert_contains "$union" 'task-42.grok-turnend-token' "grok state artifact missing from the union"
  assert_contains "$union" 'task-42.kimi-turnend-token' "kimi state artifact missing from the union"
  assert_not_contains "$union" '@ID@' "the @ID@ placeholder was not substituted"
  [ "$(printf '%s\n' "$union" | sort | uniq -d | wc -l)" -eq 0 ] \
    || fail "the state union contains duplicates"
  [ "$(fm_harness_worktree_artifacts_all | sort | uniq -d | wc -l)" -eq 0 ] \
    || fail "the worktree union contains duplicates"
  pass "artifact unions are deduplicated and substitute the task id"
}

# --- the drift guard ---------------------------------------------------------

test_installed_artifacts_are_all_removed() {
  local spawn teardown installed rel missed=
  spawn="$ROOT/bin/fm-spawn.sh"
  teardown="$ROOT/bin/fm-teardown.sh"

  # Every worktree path fm-spawn actually writes, read out of fm-spawn itself
  # rather than restated here, so this cannot rot into agreeing with a stale
  # copy of the truth. Only REDIRECTION targets count: `mkdir -p "$WT/.claude"`
  # creates a directory to write into, not an artifact to remove.
  # shellcheck disable=SC2016  # single quotes are deliberate: these patterns match
  # the LITERAL string $WT in fm-spawn's source, not this shell's variable.
  installed=$(grep -oE '> *"\$WT/\.[A-Za-z0-9._/-]+"' "$spawn" \
    | sed -e 's|^> *"\$WT/||' -e 's|"$||' | LC_ALL=C sort -u)
  [ -n "$installed" ] || fail "found no worktree artifacts written by fm-spawn.sh; the extraction pattern is stale"

  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    fm_harness_worktree_artifacts_all | grep -qxF "$rel" \
      || missed="$missed$rel"$'\n'
  done <<EOF
$installed
EOF
  [ -z "$missed" ] \
    || fail "fm-spawn writes worktree artifacts no adapter declares, so teardown will not remove them:"$'\n'"$missed"

  # And the removal paths must all go through the one owner rather than
  # hand-listing paths again.
  [ "$(grep -c 'remove_harness_worktree_artifacts "' "$teardown")" -ge 4 ] \
    || fail "not every teardown worktree removal path routes through remove_harness_worktree_artifacts"
  # shellcheck disable=SC2016  # single quotes are deliberate: matches the literal
  # "$WT/" text in fm-teardown's source.
  grep -qE 'rm -f "\$(WT|child_wt)/\.(claude|opencode|fm-)' "$teardown" \
    && fail "fm-teardown still hand-lists harness artifact paths; they belong to bin/harnesses/"

  pass "every worktree artifact fm-spawn writes is declared by an adapter and removed through the one owner"
}

test_dirty_allowlist_covers_every_artifact_and_nothing_else() {
  local re rel
  re=$(fm_harness_dirty_allow_re)
  [ -n "$re" ] || fail "fm_harness_dirty_allow_re produced nothing"

  # Every declared artifact must be ignored in the form git actually reports:
  # an entirely untracked directory is reported as its top-level prefix.
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    local reported=$rel
    case "$rel" in */*) reported="${rel%%/*}/" ;; esac
    printf '?? %s\n' "$reported" | grep -qE "^\?\? ($re)" \
      || fail "the dirty allowlist does not ignore firstmate's own artifact '$reported'"
  done <<EOF
$(fm_harness_worktree_artifacts_all)
EOF

  # The regression that motivated this: .opencode/ was never in the allowlist.
  printf '?? .opencode/\n' | grep -qE "^\?\? ($re)" \
    || fail "the dirty allowlist must ignore .opencode/"

  # It must NOT swallow real work, and the literals must stay regex-escaped so a
  # dot cannot widen the match into a genuinely dirty path.
  local dirty
  for dirty in 'src/real-work.py' 'AGENTS.md' 'Xclaude/' 'Xopencode/' '.fm-grok-turnendX'; do
    printf '?? %s\n' "$dirty" | grep -qE "^\?\? ($re)" \
      && fail "the dirty allowlist wrongly ignores '$dirty', weakening the unlanded-work check"
  done

  pass "the dirty allowlist covers every declared artifact, stays escaped, and never ignores real work"
}

test_glob_variant_harness_still_excludes_artifacts() {
  local repo wt excl union rel out
  # fm-spawn's install arms match by GLOB and the raw-launch escape hatch can
  # produce variant names, so exclusion must resolve the same way installation
  # does - exact FM_HARNESS_KNOWN membership would skip the exclude while the
  # install arm still writes the file.
  [ "$(fm_harness_launch_adapter_name claude-nightly)" = claude ] \
    || fail "claude-nightly must resolve to the claude adapter, matching the claude* install arm"
  [ "$(fm_harness_launch_adapter_name opencode-beta)" = opencode ] \
    || fail "opencode-beta must resolve to the opencode adapter"
  [ "$(fm_harness_launch_adapter_name pi-signed)" = pi ] \
    || fail "pi-signed must resolve to the pi adapter"
  fm_harness_launch_adapter_name pinocchio >/dev/null 2>&1 \
    && fail "pi's install arm is exact (pi|pi-signed); pinocchio must not resolve to it"
  fm_harness_launch_adapter_name mystery-agent >/dev/null 2>&1 \
    && fail "an unmatched harness name must not resolve an adapter"

  repo="$TMP_ROOT/excl-repo"; wt="$TMP_ROOT/excl-wt"
  fm_git_worktree "$repo" "$wt" fm/excl
  excl=$(git -C "$wt" rev-parse --git-path info/exclude)

  # shellcheck disable=SC1090  # deliberate: extracting the production excluders under test
  eval "$(sed -n '/^exclude_path()/,/^}/p;/^exclude_harness_artifacts()/,/^}/p' "$ROOT/bin/fm-spawn.sh")"

  WT=$wt
  out=$(exclude_harness_artifacts claude-nightly 2>&1) \
    || fail "exclude_harness_artifacts failed for a glob-variant harness name"
  grep -qxF '.claude/settings.local.json' "$excl" \
    || fail "a glob-variant harness (claude-nightly) did not exclude claude's artifact, leaking it into the crewmate's git view"

  # A name no install arm matches excludes the full UNION rather than nothing
  # (an entry for a file that never appears is inert; excluding nothing leaks),
  # and reports the miss instead of swallowing it.
  out=$(exclude_harness_artifacts mystery-agent 2>&1) \
    || fail "exclude_harness_artifacts failed for an unmatched harness name"
  assert_contains "$out" 'notice' "an unmatched harness name must be reported, not silently skipped"
  union=$(fm_harness_worktree_artifacts_all)
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    grep -qxF "$rel" "$excl" \
      || fail "an unmatched harness name must exclude the full union; '$rel' is missing"
  done <<EOF
$union
EOF

  pass "glob-variant and unmatched harness names still exclude their artifacts"
}

test_missing_dirty_allowlist_derivation_refuses_teardown() {
  local repo passing out rc
  repo="$TMP_ROOT/refuse-wt"
  fm_git_init_commit "$repo"
  printf 'unfinished\n' > "$repo/real-work.py"

  # shellcheck disable=SC1090  # deliberate: extracting the production safety check under test
  eval "$(sed -n '/^validate_worktree_teardown_safety()/,/^}/p' "$ROOT/bin/fm-teardown.sh")"
  worktree_safety_blocked_by_lock() { return 1; }
  # shellcheck disable=SC2034  # read by the extracted fm-teardown function under test
  TEARDOWN_WORKTREE_SAFETY_LOCK_BLOCKED=90
  # shellcheck disable=SC2034  # read by the extracted fm-teardown function under test
  WT=$repo FORCE='' KIND=ship MODE=github PROJ=$repo

  # An empty derivation once collapsed the filter to '^\?\? ()', which matches
  # EVERY untracked line - real work included - and let teardown sail past the
  # uncommitted-work check. It must refuse instead.
  # shellcheck disable=SC2329  # invoked indirectly by the production function under test; the override simulates a failed derivation
  out=$(fm_harness_dirty_allow_re() { :; }; validate_worktree_teardown_safety 2>&1); rc=$?
  [ "$rc" -ne 0 ] \
    || fail "an empty allowlist derivation must refuse teardown, not filter away every untracked file"
  assert_contains "$out" 'REFUSED' "the empty-derivation refusal must be an explicit REFUSED"
  assert_contains "$out" 'allowlist' "the refusal must name the missing artifact allowlist"

  # A failing derivation must refuse the same way.
  # shellcheck disable=SC2329  # invoked indirectly by the production function under test; the override simulates a failed derivation
  out=$(fm_harness_dirty_allow_re() { return 1; }; validate_worktree_teardown_safety 2>&1); rc=$?
  [ "$rc" -ne 0 ] \
    || fail "a failing allowlist derivation must refuse teardown"
  assert_contains "$out" 'REFUSED' "the failed-derivation refusal must be an explicit REFUSED"

  # With the real derivation, a worktree whose only untracked files are
  # firstmate's own wiring still tears down.
  passing="$TMP_ROOT/pass-wt"
  fm_git_init_commit "$passing"
  fm_git_add_origin "$passing" "$TMP_ROOT/pass-origin"
  git -C "$passing" fetch -q origin
  mkdir -p "$passing/.claude"
  printf '{}\n' > "$passing/.claude/settings.local.json"
  # shellcheck disable=SC2034  # read by the extracted fm-teardown function under test
  WT=$passing
  out=$(validate_worktree_teardown_safety 2>&1); rc=$?
  [ "$rc" -eq 0 ] \
    || fail "the safety check must still pass when only firstmate wiring is untracked: $out"

  pass "an empty or failed allowlist derivation refuses teardown instead of ignoring real work"
}

test_teardown_removes_artifacts_from_a_real_worktree() {
  local wt state rel
  wt="$TMP_ROOT/wt"; state="$TMP_ROOT/state"
  mkdir -p "$wt" "$state"

  # Materialize every declared artifact, then run the production removers.
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    mkdir -p "$wt/$(dirname "$rel")"
    printf 'wiring\n' > "$wt/$rel"
  done <<EOF
$(fm_harness_worktree_artifacts_all)
EOF
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    printf 'wiring\n' > "$state/$rel"
  done <<EOF
$(fm_harness_state_artifacts_all t1)
EOF
  # A real crewmate file that must survive.
  printf 'work\n' > "$wt/real-work.txt"

  # Source the production removers without executing fm-teardown's main flow.
  # shellcheck disable=SC1090  # deliberate: extracting the two functions under test
  eval "$(sed -n '/^remove_harness_worktree_artifacts()/,/^}/p;/^remove_harness_state_artifacts()/,/^}/p' "$ROOT/bin/fm-teardown.sh")"

  remove_harness_worktree_artifacts "$wt"
  remove_harness_state_artifacts "$state" t1

  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    assert_absent "$wt/$rel" "teardown left the worktree artifact '$rel' behind"
  done <<EOF
$(fm_harness_worktree_artifacts_all)
EOF
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    assert_absent "$state/$rel" "teardown left the state artifact '$rel' behind"
  done <<EOF
$(fm_harness_state_artifacts_all t1)
EOF
  assert_present "$wt/real-work.txt" "teardown removed a real crewmate file"

  # A missing worktree, or a missing file, must be a quiet no-op rather than an error.
  remove_harness_worktree_artifacts "$TMP_ROOT/does-not-exist" \
    || fail "removing artifacts from a missing worktree must be a no-op"
  remove_harness_worktree_artifacts "$wt" \
    || fail "removing already-removed artifacts must be a no-op"

  pass "the production removers clear every declared artifact, spare real work, and no-op safely"
}

test_every_known_harness_resolves_an_adapter
test_pi_signed_shares_the_pi_adapter
test_union_is_deduplicated_and_id_substituted
test_installed_artifacts_are_all_removed
test_dirty_allowlist_covers_every_artifact_and_nothing_else
test_glob_variant_harness_still_excludes_artifacts
test_missing_dirty_allowlist_derivation_refuses_teardown
test_teardown_removes_artifacts_from_a_real_worktree

printf 'all fm-harness-artifacts tests passed\n'
