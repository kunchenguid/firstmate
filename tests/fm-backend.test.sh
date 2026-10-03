#!/usr/bin/env bash
# Herdr-only selection and legacy metadata identity; no live terminal calls.
set -u
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
TMP_ROOT=$(fm_test_tmproot fm-backend)

test_backend_selection() {
  local cfg="$TMP_ROOT/config" backend
  mkdir -p "$cfg"
  [ "$(FM_BACKEND='' FM_BACKEND_CONFIG_DIR="$cfg" fm_backend_name)" = herdr ] || fail 'new default is not Herdr'
  for backend in tmux orca cmux zellij unknown; do
    printf '%s\n' "$backend" > "$cfg/backend"
    [ "$(FM_BACKEND='' FM_BACKEND_CONFIG_DIR="$cfg" fm_backend_name)" = "$backend" ] || fail 'explicit config was coerced'
    [ "$(FM_BACKEND=herdr FM_BACKEND_CONFIG_DIR="$cfg" fm_backend_name)" = herdr ] || fail 'environment did not override config'
    fm_backend_validate_spawn "$backend" >/dev/null 2>&1 && fail "accepted $backend"
  done
  rm "$cfg/backend"
  [ "$(TMUX=stale CMUX_WORKSPACE_ID=stale ZELLIJ=1 HERDR_ENV=1 FM_BACKEND='' FM_BACKEND_CONFIG_DIR="$cfg" fm_backend_name)" = herdr ] || fail 'retired environment changed new intake'
  fm_backend_validate_spawn herdr || fail 'valid Herdr refused'
  pass 'backend selection: Herdr default, explicit override precedence, retired settings refuse'
}

test_backend_source_shell_portable() {
  local out status
  # zsh does not word-split unquoted expansions; sourcing fm-backend.sh from
  # an interactive zsh session must still recognize known backend names.
  if command -v zsh >/dev/null 2>&1; then
    zsh -c "cd '$ROOT' && source bin/fm-backend.sh && fm_backend_source herdr && whence -w fm_backend_herdr_capture >/dev/null" 2>/dev/null \
      || fail "zsh: fm_backend_source herdr should load the adapter when sourced"
    out=$(zsh -c "cd '$ROOT' && source bin/fm-backend.sh && fm_backend_source bogus" 2>&1) \
      && fail "zsh: fm_backend_source bogus should fail"
    assert_contains "$out" "unknown backend 'bogus'" \
      "zsh: fm_backend_source did not reject bogus with the expected error"
    pass "zsh: fm_backend_source recognizes known backends and rejects unknown ones"
  else
    pass "zsh: shell-portable backend matching skipped (zsh not found)"
  fi

  bash -c "cd '$ROOT' && source bin/fm-backend.sh && fm_backend_source herdr && declare -F fm_backend_herdr_capture >/dev/null" 2>/dev/null \
    || fail "bash: fm_backend_source herdr should load the adapter when sourced"
  out=$(bash -c "cd '$ROOT' && source bin/fm-backend.sh && fm_backend_source bogus" 2>&1) \
    && fail "bash: fm_backend_source bogus should fail"
  assert_contains "$out" "unknown backend 'bogus'" \
    "bash: fm_backend_source did not reject bogus with the expected error"
  pass "bash: fm_backend_source recognizes known backends and rejects unknown ones"
}

test_meta_get_and_backend_of_meta() {
  local meta=$TMP_ROOT/meta-get.meta edge=$TMP_ROOT/meta-get-edge.meta
  fm_write_meta "$meta" "window=firstmate:fm-x1" "harness=pi"
  [ "$(fm_meta_get "$meta" window)" = "firstmate:fm-x1" ] || fail "fm_meta_get did not read window="
  [ "$(fm_meta_get "$meta" missing)" = "" ] || fail "fm_meta_get should print nothing for an absent key"
  [ "$(fm_backend_of_meta "$meta")" = tmux ] || fail "fm_backend_of_meta should default absent backend= to tmux"

  printf 'backend=tmux\n' >> "$meta"
  [ "$(fm_backend_of_meta "$meta")" = tmux ] || fail "fm_backend_of_meta should read an explicit backend=tmux"

  printf 'token=first\ntoken=last=value' > "$edge"
  [ "$(fm_meta_get "$edge" token)" = "last=value" ] \
    || fail "fm_meta_get did not preserve last-value or no-final-newline semantics"

  pass "fm_meta_get / fm_backend_of_meta: read last key=value and default backend to tmux"
}

test_resolve_selector_three_forms() {
  local state=$TMP_ROOT/resolve-state out
  mkdir -p "$state"
  fm_write_meta "$state/task1.meta" "window=firstmate:fm-task1"
  fm_write_meta "$state/dotfiles-d6.meta" "window=default:wA:p2" "backend=herdr"
  fm_write_meta "$state/fm-turnend-all-harnesses-v9.meta" "window=default:wB:p3" "backend=herdr"

  [ "$(fm_backend_resolve_selector 'sess:win' "$state")" = "sess:win" ] \
    || fail "explicit session:window should be used as-is"

  [ "$(fm_backend_resolve_selector 'dotfiles-d6' "$state")" = "default:wA:p2" ] \
    || fail "bare non-fm task id should resolve through exact metadata"
  [ "$(fm_backend_of_selector 'dotfiles-d6' 'default:wA:p2' "$state")" = herdr ] \
    || fail "bare non-fm task id should use its recorded backend"
  [ "$(fm_backend_expected_label_of_selector 'dotfiles-d6' "$state")" = "fm-dotfiles-d6" ] \
    || fail "bare non-fm task id should report the spawned fm-<id> label"

  [ "$(fm_backend_resolve_selector 'fm-turnend-all-harnesses-v9' "$state")" = "default:wB:p3" ] \
    || fail "exact fm-* task id should resolve through its exact metadata"
  [ "$(fm_backend_of_selector 'fm-turnend-all-harnesses-v9' 'default:wB:p3' "$state")" = herdr ] \
    || fail "exact fm-* task id should use exact metadata without stripping fm-"
  [ "$(fm_backend_expected_label_of_selector 'fm-turnend-all-harnesses-v9' "$state")" = "fm-fm-turnend-all-harnesses-v9" ] \
    || fail "exact fm-* task id should report the spawned fm-<id> label"

  [ "$(fm_backend_resolve_selector 'fm-task1' "$state")" = "firstmate:fm-task1" ] \
    || fail "legacy fm-<id> label should resolve through <id>.meta's window="
  [ "$(fm_backend_expected_label_of_selector 'fm-task1' "$state")" = "fm-task1" ] \
    || fail "legacy fm-<id> label should preserve its backend label"

  out=$(fm_backend_resolve_selector 'fm-missing' "$state" 2>&1) && fail "fm-<id> with no meta should fail"
  assert_contains "$out" "no metadata for fm-missing" "missing-meta error text changed"

  out=$(fm_backend_resolve_selector 'adhoc' "$state" 2>&1) && fail 'ad hoc discovery must refuse'
  assert_contains "$out" 'no recorded endpoint' 'ad hoc refusal should explain missing identity'
  pass 'selectors: literal identity, exact task id, legacy label, missing-record refusal'

}

test_backend_of_selector_matches_explicit_target_meta() {
  local state=$TMP_ROOT/backend-selector-state
  mkdir -p "$state"
  fm_write_meta "$state/herdr-task.meta" "window=default:w1:p2" "backend=herdr"
  fm_write_meta "$state/dotfiles-d6.meta" "window=default:wA:p2" "backend=herdr"
  fm_write_meta "$state/fm-turnend-all-harnesses-v9.meta" "window=default:wB:p3" "backend=herdr"
  fm_write_meta "$state/tmux-task.meta" "window=firstmate:fm-tmux-task"
  fm_write_meta "$state/custom-window-task.meta" "window=custom-window"
  fm_write_meta "$state/orca-task.meta" "window=fm-orca-task" "terminal=term-orca-task" "backend=orca"

  [ "$(fm_backend_of_selector 'dotfiles-d6' 'default:wA:p2' "$state")" = herdr ] \
    || fail "bare non-fm task id selector should use its recorded backend"
  [ "$(fm_backend_of_selector 'fm-turnend-all-harnesses-v9' 'default:wB:p3' "$state")" = herdr ] \
    || fail "exact fm-* task id selector should use exact metadata before legacy stripping"
  [ "$(fm_backend_of_selector 'fm-herdr-task' 'default:w1:p2' "$state")" = herdr ] \
    || fail "legacy fm-<id> selector should use its recorded backend"
  [ "$(fm_backend_resolve_selector 'fm-orca-task' "$state")" = term-orca-task ] \
    || fail "Orca fm-<id> selector should resolve to terminal=, not window="
  [ "$(fm_backend_resolve_selector 'term-orca-task' "$state")" = term-orca-task ] \
    || fail "raw Orca terminal selector should resolve through metadata"
  [ "$(fm_backend_resolve_selector 'custom-window' "$state")" = custom-window ] \
    || fail "raw window selector matching metadata should not require tmux fallback"
  [ "$(fm_backend_of_selector 'term-orca-task' 'term-orca-task' "$state")" = orca ] \
    || fail "matching an explicit Orca terminal handle should inherit metadata backend"
  [ "$(fm_backend_of_selector 'default:w1:p2' 'default:w1:p2' "$state")" = herdr ] \
    || fail "explicit backend target matching metadata should use that task's backend"
  [ "$(fm_backend_of_selector 'firstmate:fm-tmux-task' 'firstmate:fm-tmux-task' "$state")" = tmux ] \
    || fail "explicit tmux-shaped target with absent backend= should default to tmux"
  [ "$(fm_backend_of_selector 'manual:outside' 'manual:outside' "$state")" = tmux ] \
    || fail "explicit target with no matching metadata should keep the tmux compatibility default"

  pass "fm_backend_of_selector: exact task ids, legacy fm-<id> labels, and matching explicit targets inherit metadata backend"
}

test_spawn_symlinked_project_prefix() {
  local mode base home project worktree fakebin out rc initial
  for mode in physical logical; do
    base="$TMP_ROOT/symlink-$mode"
    mkdir -p "$base/real"
    ln -s "$base/real" "$base/link"
    project="$base/link/project"; worktree="$base/worktree"; home="$base/home"
    fm_git_worktree "$base/real/project" "$worktree" "fm/symlink-$mode"
    fm_test_spawn_home "$home" pi
    fm_test_spawn_brief "$home" "symlink-$mode"
    fakebin=$(fm_test_make_spawn_fakebin "$base/fake" pi)
    mv "$fakebin/herdr" "$fakebin/herdr-fixture"
    cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
if [ "$1 ${2:-}" = 'pane get' ]; then
  count_file="$(dirname "$0")/path-reads"
  count=0; [ ! -f "$count_file" ] || count=$(cat "$count_file")
  count=$((count + 1)); printf '%s\n' "$count" > "$count_file"
  if [ "$count" = 1 ]; then export FM_FAKE_PANE_PATH="$FM_INITIAL_PATH"; fi
fi
exec "$(dirname "$0")/herdr-fixture" "$@"
SH
    chmod +x "$fakebin/herdr"
    if [ "$mode" = physical ]; then initial=$(cd "$project" && pwd -P); else initial=$project; fi
    out=$(FM_INITIAL_PATH="$initial" fm_test_run_spawn "$home" "$worktree" "$fakebin" "symlink-$mode" "$project" pi --mode review-PR --yolo off); rc=$?
    expect_code 0 "$rc" "symlinked project isolation failed ($mode): $out"
    assert_contains "$out" "worktree=$worktree" 'spawn failed to leave initial project path'
    [ "$(cat "$fakebin/path-reads")" -ge 2 ] || fail 'fixture did not exercise initial and acquired cwd'
  done
  pass 'spawn canonicalizes physical/logical symlink prefixes before accepting acquired worktree'
}

test_backend_selection
test_backend_source_shell_portable
test_meta_get_and_backend_of_meta
test_resolve_selector_three_forms
test_backend_of_selector_matches_explicit_target_meta
test_spawn_symlinked_project_prefix
