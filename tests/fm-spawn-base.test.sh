#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh's data/<id>/base -> state/<id>.meta base= promotion.
#
# This promotion is the one link in an otherwise fail-closed feature that could
# disarm it silently: fm-brief.sh writes the sidecar and fm-pr-check.sh reads meta,
# but if the branch name never makes the hop between them, fm-pr-check finds no
# base= and the wrong-base guard is skipped entirely - restoring the exact incident
# the guard exists to prevent, with no diagnostic. Both ends were covered; this is
# the middle.
#
# Matrix:
#   (a) sidecar present -> meta records base=<branch>
#   (b) no sidecar (the common case) -> meta records no base= line at all
#   (c) empty sidecar -> loud refusal, raised before any window or worktree exists
#   (d) an accepted spawn does create both, so (c)'s assertions are live
#   (e) a secondmate never carries a task base, even with a stray sidecar
#   (f) a declared base origin does not have -> the same early, loud refusal
#
# A promoted base also carries the base's tip on origin (base_sha=), resolved while
# the base necessarily still exists. That is the fact fm-pr-check.sh needs once the
# branch is deleted from origin, where absence alone cannot say whether the base
# merged (harmless) or was abandoned (its unmerged commits replayed on the PR head).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-base)

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  # Logs every invocation to $FM_TEST_TMUX_LOG so a test can assert what the spawn
  # actually created. The window is a tmux new-window, and the worktree lease is a
  # `treehouse get` typed into the pane via send-keys, so both are visible here.
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
[ -z "${FM_TEST_TMUX_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_TEST_TMUX_LOG"
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# Build a spawn case: an isolated firstmate home, a real project + git worktree, and
# a brief for the task. base is written to the data/<id>/base sidecar when non-empty;
# pass "empty" to write the sidecar with no branch name in it.
#
# The project gets a real origin with a feature/base branch on it, because a based
# spawn resolves the base's tip from origin and records it as base_sha= - the durable
# fact fm-pr-check.sh needs to tell a merged base from an abandoned one once the
# branch itself is deleted. origin_base names the branch actually created on origin,
# so a case can declare a base origin does NOT have.
make_spawn_case() {
  local name=$1 id=$2 base=${3:-} origin_base=${4:-feature/base} case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'claude\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  make_project_origin "$case_dir" "$proj" "$origin_base"
  touch "$home/state/.last-watcher-beat"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  case "$base" in
    '') ;;
    empty) : > "$home/data/$id/base" ;;
    *) printf '%s\n' "$base" > "$home/data/$id/base" ;;
  esac
  printf '%s|%s|%s|%s|%s\n' "$case_dir" "$home" "$proj" "$wt" "$fakebin"
}

# Give the project clone a real origin carrying <origin_base>, so `git ls-remote` in
# the spawn resolves a tip for it. Pass an empty origin_base for an origin with no
# feature branch at all.
make_project_origin() {
  local case_dir=$1 proj=$2 origin_base=$3 origin
  origin="$case_dir/origin.git"
  git init -q --bare "$origin"
  git -C "$proj" remote add origin "$origin"
  git -C "$proj" push -q origin HEAD:refs/heads/main
  [ -z "$origin_base" ] || git -C "$proj" push -q origin "HEAD:refs/heads/$origin_base"
  git -C "$proj" fetch -q origin
}

read_case_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

run_spawn() {
  local home=$1 wt=$2 fakebin=$3
  shift 3
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_TEST_TMUX_LOG="${FM_TEST_TMUX_LOG:-}" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

test_sidecar_is_promoted_into_meta() {
  local rec id out status origin_sha
  id=spawn-base-b1
  rec=$(make_spawn_case promote "$id" feature/admin-dashboard feature/admin-dashboard)
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "promote: spawn with a base sidecar should succeed"$'\n'"$out"
  assert_grep "base=feature/admin-dashboard" "$HOME_DIR/state/$id.meta" \
    "promote: the declared base never reached meta, so fm-pr-check would skip the wrong-base guard"
  origin_sha=$(git -C "$CASE_DIR/origin.git" rev-parse refs/heads/feature/admin-dashboard)
  assert_grep "base_sha=$origin_sha" "$HOME_DIR/state/$id.meta" \
    "promote: the base's tip on origin was not recorded, so a base later deleted from origin could not be told merged from abandoned"
  pass "fm-spawn promotes the data/<id>/base sidecar into meta as base= and records the base's tip as base_sha="
}

# base_sha= is what makes the absent-base decision SOUND rather than a guess, so the
# spawn must refuse a base origin does not have instead of recording base= with no
# tip to verify against later. It is also the cheapest possible place to catch a
# mistyped base: before a crewmate spends a run on it.
test_base_missing_from_origin_refuses_before_creating_anything() {
  local rec id out status log
  id=spawn-base-b6
  rec=$(make_spawn_case nosuchbase "$id" feature/typo feature/base)
  read_case_record "$rec"
  log="$CASE_DIR/tmux.log"
  : > "$log"

  out=$(FM_TEST_TMUX_LOG="$log" run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "nosuchbase: a base that does not exist on origin must refuse, not spawn with an unverifiable base"
  assert_contains "$out" "no such branch exists on origin" "nosuchbase: refusal did not explain the missing base branch"
  assert_absent "$HOME_DIR/state/$id.meta" "nosuchbase: refusal should happen before meta is written"
  assert_no_grep "new-window" "$log" \
    "nosuchbase: the refusal created a backend window it then abandoned, with no meta to reconcile it"
  assert_no_grep "treehouse get" "$log" \
    "nosuchbase: the refusal leased a task worktree it then abandoned, with no meta to release it"
  pass "fm-spawn refuses a declared base origin does not have, before any window or worktree exists"
}

test_no_sidecar_writes_no_base_key() {
  local rec id out status
  id=spawn-base-b2
  rec=$(make_spawn_case nosidecar "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "nosidecar: an ordinary spawn should succeed"$'\n'"$out"
  # Fixed-string, unanchored: assert_no_grep is grep -F, so a "^base=" pattern
  # would search for a literal caret and pass no matter what meta holds. No other
  # meta key contains "base=" as a substring, so this is both live and precise.
  assert_no_grep "base=" "$HOME_DIR/state/$id.meta" \
    "nosidecar: a task with no declared base must not gain a base= line"
  pass "fm-spawn writes no base= for the common no-declared-base task"
}

# The refusal is fail-closed, so it must also be cheap: it has to fire BEFORE the
# backend window and the treehouse worktree lease are acquired. Refusing after
# them - but before meta is written, as it did originally - strands both with no
# state/<id>.meta, and every reconciliation path (recovery, fm-teardown.sh) keys
# off meta, so nothing could ever clean them up but a human.
test_empty_sidecar_refuses_before_creating_anything() {
  local rec id out status log
  id=spawn-base-b3
  rec=$(make_spawn_case emptysidecar "$id" empty)
  read_case_record "$rec"
  log="$CASE_DIR/tmux.log"
  : > "$log"

  out=$(FM_TEST_TMUX_LOG="$log" run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "emptysidecar: a base declaration that cannot be recorded must refuse, not spawn unguarded"
  assert_contains "$out" "declares no branch" "emptysidecar: refusal did not explain the unusable sidecar"
  assert_absent "$HOME_DIR/state/$id.meta" "emptysidecar: refusal should happen before meta is written"
  assert_no_grep "new-window" "$log" \
    "emptysidecar: the refusal created a backend window it then abandoned, with no meta to reconcile it"
  assert_no_grep "treehouse get" "$log" \
    "emptysidecar: the refusal leased a task worktree it then abandoned, with no meta to release it"
  pass "fm-spawn refuses an unusable base sidecar before any window or worktree exists (nothing stranded)"
}

# The same spawn path, one character different in the sidecar, must still create
# the window and take the lease - so the assertions above are pinning the refusal,
# not an inert log.
test_a_good_spawn_does_create_the_window_and_worktree() {
  local rec id out status log
  id=spawn-base-b5
  rec=$(make_spawn_case createscheck "$id" feature/x feature/x)
  read_case_record "$rec"
  log="$CASE_DIR/tmux.log"
  : > "$log"

  out=$(FM_TEST_TMUX_LOG="$log" run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "createscheck: a well-formed based spawn should succeed"$'\n'"$out"
  assert_grep "new-window" "$log" "createscheck: the spawn never created a window, so the refusal test proves nothing"
  assert_grep "treehouse get" "$log" "createscheck: the spawn never leased a worktree, so the refusal test proves nothing"
  pass "fm-spawn does create the window and worktree on an accepted spawn (the leak assertions are live)"
}

test_secondmate_ignores_a_stray_base_sidecar() {
  local rec id out status home
  id=spawn-base-sm4
  rec=$(make_spawn_case secondmate "$id" feature/x feature/x)
  read_case_record "$rec"
  home="$CASE_DIR/sm-home"
  mkdir -p "$home/bin" "$home/data"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  printf 'charter for %s\n' "$id" > "$home/data/charter.md"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$home" --secondmate)
  status=$?
  expect_code 0 "$status" "secondmate: spawn should succeed"$'\n'"$out"
  assert_no_grep "base=" "$HOME_DIR/state/$id.meta" \
    "secondmate: a persistent supervisor has no task base and must never record one"
  pass "fm-spawn never records base= for a secondmate"
}

test_sidecar_is_promoted_into_meta
test_no_sidecar_writes_no_base_key
test_empty_sidecar_refuses_before_creating_anything
test_base_missing_from_origin_refuses_before_creating_anything
test_a_good_spawn_does_create_the_window_and_worktree
test_secondmate_ignores_a_stray_base_sidecar
