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
# test_installed_artifacts_are_all_removed, which RUNS fm-spawn's real install
# tail per harness and proves every file it actually wrote is hidden from git
# and cleared by the production removers - so a future rename that updates only
# the installer fails this suite instead of silently leaking again.
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
    "pi's state artifact must appear in the union as the task id plus its suffix"
  pass "pi-signed shares pi's adapter, and pi's artifact stays outside the worktree"
}

test_union_is_deduplicated_and_id_substituted() {
  local union
  union=$(fm_harness_state_artifacts_all task-42)
  assert_contains "$union" 'task-42.grok-turnend-token' "grok state artifact missing from the union"
  assert_contains "$union" 'task-42.kimi-turnend-token' "kimi state artifact missing from the union"
  [ "$(printf '%s\n' "$union" | sort | uniq -d | wc -l)" -eq 0 ] \
    || fail "the state union contains duplicates"
  [ "$(fm_harness_worktree_artifacts_all | sort | uniq -d | wc -l)" -eq 0 ] \
    || fail "the worktree union contains duplicates"

  # The main teardown id is charset-guarded, but orca child ids come from
  # basename and are not, so name derivation must stay byte-exact even for the
  # bytes substitution engines treat specially (& \ " '): a hostile id must
  # derive exactly as many names as a plain one, each the id itself followed
  # by a non-empty suffix.
  local nasty nasty_union rel
  nasty='child-&-\1\-"-'\''-x'
  nasty_union=$(fm_harness_state_artifacts_all "$nasty")
  [ "$(printf '%s\n' "$nasty_union" | wc -l)" -eq "$(printf '%s\n' "$union" | wc -l)" ] \
    || fail "a hostile id changed how many state artifact names derive"
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    case "$rel" in
      "$nasty"?*) : ;;
      *) fail "state artifact '$rel' is not the hostile id plus a suffix" ;;
    esac
  done <<EOF
$nasty_union
EOF

  pass "artifact unions are deduplicated and derive names from the task id"
}

# --- the drift guard ---------------------------------------------------------

test_installed_artifacts_are_all_removed() {
  local spawn harness case_dir proj wt state home grok_home scratch id
  local before after installed state_before state_after state_installed baseline
  local control dirty rel out rc install_block spawn_helpers
  local total_installed=0 total_state_installed=0
  spawn="$ROOT/bin/fm-spawn.sh"

  # fm-spawn's REAL install tail: busy-state arming, the per-harness wiring
  # writes, and the exclusion call. It is executed here per harness rather than
  # restated or read back as text, so whatever the installer actually writes
  # must survive the install -> exclude -> remove loop to pass. Only the
  # harness binary launch is out of reach; nothing below stubs a write.
  # shellcheck disable=SC2016  # single quotes are deliberate: the anchor is the
  # literal $KIND guard line in fm-spawn's source.
  install_block=$(sed -n '/^if \[ "\$KIND" != secondmate \]; then$/,/^fi$/p' "$spawn")
  [ -n "$install_block" ] || fail "could not locate fm-spawn's harness install block; its anchors are stale"
  spawn_helpers=$(sed -n '/^shell_quote()/,/^}/p;/^json_escape()/,/^}/p;/^exclude_path()/,/^}/p;/^exclude_harness_artifacts()/,/^}/p' "$spawn")
  [ -n "$spawn_helpers" ] || fail "could not locate fm-spawn's helper functions; their anchors are stale"

  # shellcheck disable=SC1090  # deliberate: extracting the production removers under test
  eval "$(sed -n '/^remove_harness_worktree_artifacts()/,/^}/p;/^remove_harness_state_artifacts()/,/^}/p' "$ROOT/bin/fm-teardown.sh")"

  # Sourced here rather than inside the install subshell: the subshell inherits
  # the functions, and following the lib from a subshell makes shellcheck read
  # its function-local harness/state/id as clobbering the loop variables.
  # shellcheck source=bin/fm-busy-lib.sh
  . "$ROOT/bin/fm-busy-lib.sh"

  for harness in $ADAPTER_HARNESSES; do
    case_dir="$TMP_ROOT/drift-$harness"
    proj="$case_dir/proj"; wt="$case_dir/wt"; state="$case_dir/state"
    home="$case_dir/home"; grok_home="$case_dir/grok"; scratch="$case_dir/busy-baseline"
    # Grok and Kimi never arm the busy contract, so their ids can carry the
    # bytes substitution engines treat specially (& \ " '); the removal below
    # must still resolve their state tokens byte-exactly.
    case "$harness" in
      grok|kimi) id='drift-&-\1-"-'\''-x' ;;
      *) id="drift-$harness-x" ;;
    esac
    fm_git_worktree "$proj" "$wt" "fm/drift-$harness"
    mkdir -p "$state" "$scratch" "$home/.kimi-code/fm-turn-end.d" "$grok_home"

    # The per-task busy files that arming ALONE creates are generic records
    # owned by retire_busy_state, not harness artifacts, so they are learned
    # empirically here and subtracted rather than named.
    "$ROOT/bin/fm-busy-event.sh" arm "$scratch" "$id" >/dev/null 2>&1 || true
    baseline=$(cd "$scratch" && find . -type f | LC_ALL=C sort)

    before=$(cd "$wt" && find . -type f | LC_ALL=C sort)
    state_before=$(cd "$state" && find . -type f | LC_ALL=C sort)

    out=$(
      exec 2>&1
      set -e
      HOME=$home GROK_HOME=$grok_home
      export HOME GROK_HOME
      # shellcheck disable=SC2034  # read by the eval'd production block below
      FM_ROOT=$ROOT KIND=task HARNESS=$harness WT=$wt STATE=$state ID=$id
      STATE_REAL=$(cd "$state" && pwd -P)
      # shellcheck disable=SC2034  # read by the eval'd production block below
      TURNEND="$STATE_REAL/$id.turn-ended"
      eval "$spawn_helpers"
      eval "$install_block"
    ); rc=$?
    expect_code 0 "$rc" "fm-spawn's install block failed for $harness:"$'\n'"$out"

    # Whatever the installer wrote, the exclusion path must hide it from git;
    # an installed-but-undeclared artifact surfaces as an untracked file here.
    dirty=$(git -C "$wt" status --porcelain)
    [ -z "$dirty" ] \
      || fail "after install and exclusion for $harness, git still sees untracked files - fm-spawn writes an artifact its adapter does not declare:"$'\n'"$dirty"

    after=$(cd "$wt" && find . -type f | LC_ALL=C sort)
    state_after=$(cd "$state" && find . -type f | LC_ALL=C sort)
    installed=$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after"))
    state_installed=$(comm -13 <(printf '%s\n' "$state_before") <(printf '%s\n' "$state_after"))

    control="$wt/crewmate-$RANDOM$RANDOM.txt"
    printf 'unlanded work\n' > "$control"

    remove_harness_worktree_artifacts "$wt"
    remove_harness_state_artifacts "$state" "$id"

    while IFS= read -r rel; do
      [ -n "$rel" ] || continue
      assert_absent "$wt/${rel#./}" "fm-spawn installed '$rel' for $harness but the removal path left it behind"
      total_installed=$((total_installed + 1))
    done <<EOF
$installed
EOF
    while IFS= read -r rel; do
      [ -n "$rel" ] || continue
      printf '%s\n' "$baseline" | grep -qxF "$rel" && continue
      assert_absent "$state/${rel#./}" "fm-spawn wrote state artifact '$rel' for $harness but the removal path left it behind"
      total_state_installed=$((total_state_installed + 1))
    done <<EOF
$state_installed
EOF
    assert_present "$control" "the removal path deleted a crewmate's real file for $harness"
  done

  # If the block extraction or the install arms ever go stale, the loop above
  # degenerates into asserting nothing; refuse that silently-green shape.
  [ "$total_installed" -ge 1 ] \
    || fail "no harness installed any worktree artifact; the install-block extraction went stale"
  [ "$total_state_installed" -ge 1 ] \
    || fail "no harness installed any state artifact; the install-block extraction went stale"

  pass "every artifact the real installer writes is excluded from git and removed by the production removers"
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
