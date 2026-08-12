#!/usr/bin/env bash
# Behavior tests for the worktree-tangle guards.
#
# Firstmate is a treehouse-pooled git repo of itself: linked worktrees and
# secondmate homes all sit at a detached HEAD on the default branch, while the
# PRIMARY checkout (FM_ROOT) is a normal checkout on a real branch. The "tangle"
# is a crewmate branching/committing in the primary instead of its own worktree,
# stranding the primary on a feature branch. Two guards cover it:
#   GUARD 1 (prevention) - the brief asserts isolation before its branch step, and
#            fm-spawn refuses to launch unless the resolved worktree is isolated
#            AND belongs to the target project (same git common dir - a mere
#            "git root distinct from the primary" can be an unrelated repo).
#   GUARD 2 (detection)  - fm-guard and fm-bootstrap alarm when the primary is on
#            a feature branch, and stay silent on the default branch or detached.
# These cases pin: the shared lib's branch classification, the fm-guard banner,
# the fm-bootstrap problem line, the brief assertion ordering, and the fm-spawn
# abort - all hermetic over temp git repos and fakebins.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-tangle-lib.sh
. "$ROOT/bin/fm-tangle-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-tangle-guard)
fm_git_identity fmtest fmtest@example.invalid

# A fresh git repo on `main` with one commit. Echoes its path.
make_repo() {
  local dir=$1
  git init -q -b main "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  printf '%s\n' "$dir"
}

# --- shared lib: branch classification --------------------------------------

# fm_primary_tangle_branch is the whole scoping decision: a NAMED non-default
# branch is the tangle; the default branch and detached HEAD are healthy.
test_lib_classification() {
  local repo n=0 label state branch expect out
  repo=$(make_repo "$TMP_ROOT/lib-repo")
  while IFS='|' read -r label state branch expect; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    case "$state" in
      default)  git -C "$repo" checkout -q main ;;
      feature)  git -C "$repo" checkout -q -B "$branch" ;;
      detached) git -C "$repo" checkout -q main; git -C "$repo" checkout -q --detach ;;
    esac
    out=$(fm_primary_tangle_branch "$repo" || true)
    [ "$out" = "$expect" ] || fail "$label: expected tangle='$expect', got '$out'"
  done <<'ROWS'
on the default branch is healthy|default||
on a feature branch is the tangle|feature|fm/readme-restructure-d3|fm/readme-restructure-d3
detached HEAD on default is healthy (worktrees, secondmate homes)|detached||
ROWS
  # A non-git directory is not a tangle and must not error.
  out=$(fm_primary_tangle_branch "$TMP_ROOT" || true)
  [ -z "$out" ] || fail "non-git dir wrongly reported a tangle: '$out'"
  pass "fm_primary_tangle_branch: feature branch alarms; default/detached/non-git stay silent"
}

# --- GUARD 2a: fm-guard banner ----------------------------------------------

run_guard() {
  # Scope the guard to a temp repo as the primary checkout; state lives under it.
  FM_ROOT_OVERRIDE="$1" FM_HOME="$1" "$ROOT/bin/fm-guard.sh" 2>&1
}

test_guard_banner() {
  local repo out
  repo=$(make_repo "$TMP_ROOT/guard-repo")

  out=$(run_guard "$repo")
  assert_not_contains "$out" "WORKTREE TANGLE" "guard alarmed while primary was on main"

  git -C "$repo" checkout -q --detach
  out=$(run_guard "$repo")
  assert_not_contains "$out" "WORKTREE TANGLE" "guard alarmed on a detached HEAD (legitimate worktree state)"

  git -C "$repo" checkout -q -B fm/tangle-aa1
  out=$(run_guard "$repo")
  assert_contains "$out" "WORKTREE TANGLE" "guard did not alarm on a feature branch in the primary"
  assert_contains "$out" "fm/tangle-aa1" "guard banner did not name the offending branch"
  assert_contains "$out" "checkout main" "guard banner did not print the restore remediation"
  pass "fm-guard: bordered tangle banner fires only for a feature branch in the primary"
}

# --- GUARD 2b: fm-bootstrap problem line ------------------------------------

run_bootstrap() {
  # No projects/ under the home keeps fleet sync inert; grep isolates the line.
  FM_ROOT_OVERRIDE="$1" FM_HOME="$1" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null
}

test_bootstrap_line() {
  local repo out
  repo=$(make_repo "$TMP_ROOT/bootstrap-repo")

  out=$(run_bootstrap "$repo" | grep '^TANGLE:' || true)
  [ -z "$out" ] || fail "bootstrap emitted a TANGLE line while on main: $out"

  git -C "$repo" checkout -q --detach
  out=$(run_bootstrap "$repo" | grep '^TANGLE:' || true)
  [ -z "$out" ] || fail "bootstrap emitted a TANGLE line on a detached HEAD: $out"

  git -C "$repo" checkout -q -B fm/tangle-bb2
  out=$(run_bootstrap "$repo" | grep '^TANGLE:' || true)
  assert_contains "$out" "fm/tangle-bb2" "bootstrap did not report the tangled branch"
  assert_contains "$out" "checkout main" "bootstrap TANGLE line lacked the restore remediation"
  pass "fm-bootstrap: TANGLE problem line fires only for a feature branch in the primary"
}

# --- GUARD 1a: brief isolation assertion ------------------------------------

# The generated ship brief must carry the isolation assertion AHEAD of the
# `git checkout -b` step, so the crewmate verifies its worktree before branching.
test_brief_assertion_precedes_branch() {
  local home brief iso br
  home="$TMP_ROOT/brief-home"
  mkdir -p "$home/data"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" tangle-brief-cc3 alpha >/dev/null 2>&1
  brief="$home/data/tangle-brief-cc3/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  assert_grep "blocked: launched in primary checkout, not an isolated worktree" "$brief" \
    "brief is missing the isolation blocked-status contract"
  assert_grep "The path check is authoritative" "$brief" \
    "brief must make the path check authoritative"
  assert_no_grep "A reliable test that you are in a linked worktree" "$brief" \
    "brief must not present git-dir/common-dir as decisive"
  assert_no_grep "they are identical in the primary checkout" "$brief" \
    "brief must not claim the primary checkout has identical git dirs"
  iso=$(grep -n 'launched in primary checkout, not an isolated worktree' "$brief" | head -1 | cut -d: -f1)
  br=$(grep -n 'git checkout -b fm/' "$brief" | head -1 | cut -d: -f1)
  if [ -z "$iso" ] || [ -z "$br" ]; then
    fail "brief missing assertion ($iso) or branch step ($br)"
  fi
  [ "$iso" -lt "$br" ] || fail "isolation assertion (line $iso) must precede the branch step (line $br)"
  pass "fm-brief: ship brief asserts worktree isolation before the branch step"
}

# --- GUARD 1b: fm-spawn isolation abort -------------------------------------

# A fake tmux that reports FM_FAKE_PANE_PATH as the post-`treehouse get` pane cwd
# (so the spawn's worktree-resolution loop resolves to a path we control), names
# the session on '#S', and swallows window ops. Echoes the fakebin dir.
make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*)
    if [ -n "${FM_FAKE_PANE_SEQ:-}" ] && [ -s "$FM_FAKE_PANE_SEQ" ]; then
      head -n 1 "$FM_FAKE_PANE_SEQ"
      if [ "$(wc -l < "$FM_FAKE_PANE_SEQ")" -gt 1 ]; then
        tail -n +2 "$FM_FAKE_PANE_SEQ" > "$FM_FAKE_PANE_SEQ.next" && mv "$FM_FAKE_PANE_SEQ.next" "$FM_FAKE_PANE_SEQ"
      fi
      exit 0
    fi
    printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message)
    case "$*" in
      *"#{window_name}"*) cat "$FM_FAKE_TMUX_STATE" ;;
      *) printf 'firstmate\n' ;;
    esac
    exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|send-keys) exit 0 ;;
  kill-window) printf 'kill-window\n' >> "${FM_TMUX_REC:-/dev/null}"; exit 0 ;;
  new-window) printf '%s\n' '@42'; exit 0 ;;
  set-window-option) exit 0 ;;
  rename-window) printf '%s\n' "${@: -1}" > "$FM_FAKE_TMUX_STATE"; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

run_spawn() {
  local home=$1 id=$2 proj=$3 pane=$4 fakebin=$5
  mkdir -p "$home/data/$id"
  printf 'brief\n' > "$home/data/$id/brief.md"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$pane" FM_FAKE_PANE_SEQ="${FM_FAKE_PANE_SEQ:-}" \
    FM_SPAWN_WT_WAIT_SECS=3 FM_FAKE_TMUX_STATE="$home/tmux-window-name" TMUX="fake,1,0" \
    PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" codex 2>&1
}

test_spawn_isolation_abort() {
  local home proj fakebin out status
  home="$TMP_ROOT/spawn-home"
  mkdir -p "$home/data"
  proj=$(make_repo "$TMP_ROOT/spawn-proj")
  fakebin=$(make_spawn_fakebin "$TMP_ROOT/spawn-fake")
  # A genuine isolated linked worktree of the project, detached on the default.
  git -C "$proj" worktree add -q --detach "$TMP_ROOT/spawn-wt" >/dev/null 2>&1
  mkdir -p "$TMP_ROOT/spawn-notgit" "$proj/sub"

  # Abort: the pane resolves to a plain non-git directory (not a worktree at all).
  out=$(run_spawn "$home" abort-notgit-dd4 "$proj" "$TMP_ROOT/spawn-notgit" "$fakebin"); status=$?
  expect_code 1 "$status" "spawn into a non-worktree dir should abort"
  assert_contains "$out" "did not yield an isolated worktree" "non-worktree spawn lacked the isolation error"
  # A lease WAS acquired before the isolation check failed, so the abort keeps a
  # recoverable record instead of dropping the lease on the floor.
  assert_present "$home/state/abort-notgit-dd4.meta" \
    "aborted spawn dropped the recoverable record for its acquired lease"
  assert_grep "spawn_state=aborted" "$home/state/abort-notgit-dd4.meta" \
    "recoverable abort meta is not marked aborted"
  assert_grep "worktree=$TMP_ROOT/spawn-notgit" "$home/state/abort-notgit-dd4.meta" \
    "recoverable abort meta lost the leased worktree line"

  # Abort: the pane resolves INTO the primary checkout (a subdir of PROJ_ABS).
  out=$(run_spawn "$home" abort-primary-ee5 "$proj" "$proj/sub" "$fakebin"); status=$?
  expect_code 1 "$status" "spawn landing inside the primary checkout should abort"
  assert_contains "$out" "did not yield an isolated worktree" "primary-checkout spawn lacked the isolation error"

  # Proceed: the pane resolves to a genuine, isolated worktree.
  out=$(run_spawn "$home" ok-isolated-ff6 "$proj" "$TMP_ROOT/spawn-wt" "$fakebin"); status=$?
  expect_code 0 "$status" "spawn into a genuine isolated worktree should succeed"
  assert_contains "$out" "spawned ok-isolated-ff6" "isolated spawn did not report success"
  assert_not_contains "$out" "did not yield an isolated worktree" "isolated spawn wrongly tripped the guard"
  pass "fm-spawn: aborts unless the resolved worktree is a genuine, isolated worktree"
}

test_spawn_wrong_project_worktree_aborts() {
  local home proj unrelated unrelated_wt fakebin rec out status
  home="$TMP_ROOT/spawn-wrong-project-home"
  mkdir -p "$home/data"
  proj=$(make_repo "$TMP_ROOT/spawn-target-project")
  unrelated=$(make_repo "$TMP_ROOT/spawn-unrelated-project")
  unrelated_wt="$TMP_ROOT/spawn-unrelated-worktree"
  git -C "$unrelated" worktree add -q --detach "$unrelated_wt" >/dev/null 2>&1
  fakebin=$(make_spawn_fakebin "$TMP_ROOT/spawn-wrong-project-fake")
  rec="$TMP_ROOT/spawn-wrong-project-tmux.log"

  out=$(FM_TMUX_REC="$rec" run_spawn "$home" wrong-project-gg7 "$proj" "$unrelated" "$fakebin"); status=$?
  expect_code 1 "$status" "spawn into an unrelated project checkout should abort"
  assert_contains "$out" "DIFFERENT repo" "wrong-project abort lacked the repo identity reason"
  assert_contains "$out" "spawn-target-project" "wrong-project abort lacked expected project identity"
  assert_present "$home/state/wrong-project-gg7.meta" \
    "wrong-project abort dropped the recoverable record for its acquired lease"
  assert_grep "spawn_state=aborted" "$home/state/wrong-project-gg7.meta" \
    "wrong-project abort meta is not marked aborted"
  assert_grep "kill-window" "$rec" "wrong-project abort must kill the fresh window"

  : > "$rec"
  out=$(FM_TMUX_REC="$rec" run_spawn "$home" wrong-project-wt-hh8 "$proj" "$unrelated_wt" "$fakebin"); status=$?
  expect_code 1 "$status" "spawn into an unrelated project's linked worktree should abort"
  assert_contains "$out" "DIFFERENT repo" "wrong-project worktree abort lacked the repo identity reason"
  assert_present "$home/state/wrong-project-wt-hh8.meta" \
    "wrong-project worktree abort dropped the recoverable record for its acquired lease"
  assert_grep "spawn_state=aborted" "$home/state/wrong-project-wt-hh8.meta" \
    "wrong-project worktree abort meta is not marked aborted"
  assert_grep "kill-window" "$rec" "wrong-project worktree abort must kill the fresh window"
  pass "fm-spawn: rejects unrelated project checkouts and linked worktrees"
}

test_spawn_transient_wrong_project_path_recovers() {
  local home proj unrelated target_wt fakebin rec seq out status
  home="$TMP_ROOT/spawn-transient-home"
  mkdir -p "$home/data"
  proj=$(make_repo "$TMP_ROOT/spawn-transient-target")
  unrelated=$(make_repo "$TMP_ROOT/spawn-transient-unrelated")
  target_wt="$TMP_ROOT/spawn-transient-wt"
  git -C "$proj" worktree add -q --detach "$target_wt" >/dev/null 2>&1
  fakebin=$(make_spawn_fakebin "$TMP_ROOT/spawn-transient-fake")
  rec="$TMP_ROOT/spawn-transient-tmux.log"
  seq="$TMP_ROOT/spawn-transient-pane-seq"
  printf '%s\n%s\n' "$unrelated" "$target_wt" > "$seq"

  out=$(FM_FAKE_PANE_SEQ="$seq" FM_TMUX_REC="$rec" run_spawn "$home" transient-project-ii9 "$proj" "" "$fakebin"); status=$?
  expect_code 0 "$status" "a transient unrelated path must be ignored until the target worktree settles"
  assert_contains "$out" "spawned transient-project-ii9" "transient-path spawn did not report success"
  assert_grep "worktree=$target_wt" "$home/state/transient-project-ii9.meta" \
    "spawn must record the settled target worktree"
  pass "fm-spawn: transient unrelated cwd is not accepted before target worktree"
}

test_lib_classification
test_guard_banner
test_bootstrap_line
test_brief_assertion_precedes_branch
test_spawn_isolation_abort
test_spawn_wrong_project_worktree_aborts
test_spawn_transient_wrong_project_path_recovers
