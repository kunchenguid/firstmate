#!/usr/bin/env bash
# Behavior tests for the mode=no-mistakes gate rule in bin/fm-git-push-guard.sh.
# Every wrapper case pushes with real git through a hooks directory installed by
# bin/fm-git-strip-ai-trailers.sh --push-guard, the way a fleet pane does, and
# asserts the exit status and which bare repository ended up holding the ref.
# The red cases replay the push shapes recorded in the Codex transcripts behind
# the direct-push incidents (kunchenguid/firstmate#7921, #7923, #7929,
# kunchenguid/no-mistakes#1641, kunchenguid/quota-axi#361), plus the command
# spellings a command-line parser missed.
set -u

# A fleet pane already carries GIT_CONFIG core.hooksPath. These cases set that
# override themselves, so drop the inherited one before any git command.
unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 GIT_CONFIG_PARAMETERS

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

GUARD="$ROOT/bin/fm-git-push-guard.sh"
STRIP="$ROOT/bin/fm-git-strip-ai-trailers.sh"
TMP_ROOT=$(fm_test_tmproot fm-git-push-guard-gate)
fm_git_identity fmtest fmtest@example.invalid

with_hooks() {  # <hooks-dir> <command...>
  local hooks=$1
  shift
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=$hooks "$@"
}

# make_gate <dir>: a bare repository carrying the no-mistakes gate stamp, the
# structural fact the rule keys on (no-mistakes writes it at `no-mistakes init`).
make_gate() {
  git init -q --bare "$1"
  printf 'v2:fixture\n' >"$1/no-mistakes-gate-config"
}

# fixture <name>: a project with a bare upstream origin, a bare fork (the push
# target the gate publishes to), a stamped gate, a worktree on fm/up-t1 with one
# commit, remotes origin, fork and no-mistakes, and the gate guard installed.
# Sets FX_WT, FX_HOOKS, FX_FORK, FX_GATE, FX_BRANCH, FX_DIR.
fixture() {
  local name=$1 policy=${2:-gate} guard
  FX_DIR="$TMP_ROOT/$name"
  FX_BRANCH=fm/up-t1
  fm_git_worktree "$FX_DIR/repo" "$FX_DIR/wt" "$FX_BRANCH"
  FX_WT="$FX_DIR/wt"
  FX_FORK="$FX_DIR/fork.git"
  FX_GATE="$FX_DIR/nm-home/repos/abc123.git"
  git init -q --bare "$FX_FORK"
  make_gate "$FX_GATE"
  git -C "$FX_WT" remote add fork "file://$FX_FORK"
  git -C "$FX_WT" remote add no-mistakes "$FX_GATE"
  git -C "$FX_WT" commit -q --allow-empty -m 'the task change'
  guard="$FX_DIR/guard"
  FX_HOOKS="$FX_DIR/hooks"
  if [ "$policy" = unguarded ]; then
    "$STRIP" install "$FX_HOOKS" "$FX_WT" || fail "unguarded hook installation failed"
    return
  fi
  "$GUARD" write-gate "$guard" || fail "write-gate failed"
  "$STRIP" install --push-guard "$guard" "$FX_HOOKS" "$FX_WT" || fail "install --push-guard failed"
}

# run_in <dir> <command...>: run a command from <dir> inside the pane
# environment; sets PUSH_OUT and PUSH_RC.
run_in() {
  local dir=$1
  shift
  PUSH_OUT=$(cd "$dir" && with_hooks "$FX_HOOKS" "$@" 2>&1)
  PUSH_RC=$?
}

refused() {  # <label> <bare-repo> <ref>
  [ "$PUSH_RC" -ne 0 ] || fail "$1 was accepted"
  assert_contains "$PUSH_OUT" "fm-git-push-guard: refused:" "$1 was refused without the guard naming itself"
  assert_contains "$PUSH_OUT" "not a no-mistakes gate" "$1 was refused without naming the gate rule"
  if git -C "$2" rev-parse --verify --quiet "$3" >/dev/null; then
    fail "$1 still reached the remote as $3"
  fi
}

accepted() {  # <label> <bare-repo> <ref>
  [ "$PUSH_RC" -eq 0 ] || fail "$1 was refused: $PUSH_OUT"
  git -C "$2" rev-parse --verify --quiet "$3" >/dev/null || fail "$1 did not land as $3"
}

test_unguarded_pushes_reproduce_the_incidents() {
  local clone
  fixture unguarded unguarded
  run_in "$TMP_ROOT" git -C "$FX_WT" push "file://$FX_FORK" HEAD:refs/heads/by-url-C
  accepted "the old git -C URL path" "$FX_FORK" refs/heads/by-url-C
  run_in "$FX_WT" git push "file://$FX_FORK" HEAD:refs/heads/by-url
  accepted "the old URL path" "$FX_FORK" refs/heads/by-url
  clone="$FX_DIR/delivery"
  git clone -q "$FX_WT" "$clone"
  git -C "$clone" remote add fork "file://$FX_FORK"
  git -C "$clone" remote add no-mistakes "$FX_GATE"
  run_in "$TMP_ROOT" git -C "$clone" push fork HEAD:refs/heads/from-clone
  accepted "the old delivery-clone path" "$FX_FORK" refs/heads/from-clone
  # shellcheck disable=SC2016 # Expanded in the child shell.
  run_in "$TMP_ROOT" bash -c 'cd "$1" && git push fork HEAD:refs/heads/after-cd' _ "$FX_WT"
  accepted "the old cd && git push path" "$FX_FORK" refs/heads/after-cd
  run_in "$FX_WT" git -c push.default=current push fork HEAD:refs/heads/with-config
  accepted "the old git -c path" "$FX_FORK" refs/heads/with-config
  run_in "$FX_WT" env git push fork HEAD:refs/heads/with-env
  accepted "the old env git path" "$FX_FORK" refs/heads/with-env
  pass "gate guard: the unguarded hook setup reproduces the direct-push and parser-miss cases"
}

test_recorded_bypass_shapes_are_refused() {
  fixture recorded
  # firstmate#7921, #7923 (twice), no-mistakes#1641: git -C <worktree> push
  # <fork URL> HEAD:refs/heads/<task branch>, issued from another directory.
  run_in "$TMP_ROOT" git -C "$FX_WT" push "file://$FX_FORK" "HEAD:refs/heads/$FX_BRANCH"
  refused "git -C <worktree> push <fork URL> (7921, 7923, 1641)" "$FX_FORK" "refs/heads/$FX_BRANCH"
  # firstmate#7929: git push '<fork URL>' HEAD:refs/heads/<task branch> from the worktree.
  run_in "$FX_WT" git push "file://$FX_FORK" "HEAD:refs/heads/$FX_BRANCH"
  refused "git push <fork URL> from the worktree (7929)" "$FX_FORK" "refs/heads/$FX_BRANCH"
  git -C "$FX_WT" remote set-url no-mistakes "file://$FX_FORK"
  run_in "$FX_WT" git push no-mistakes "HEAD:refs/heads/$FX_BRANCH"
  refused "a fork remote named no-mistakes" "$FX_FORK" "refs/heads/$FX_BRANCH"
  pass "gate guard: the recorded URL pushes to the fork are refused"
}

test_scratch_clone_named_fork_remote_is_refused() {
  local clone
  fixture clone
  # quota-axi#361: a delivery clone in the system temp directory with remotes
  # no-mistakes, origin and fork; git -C <clone> push fork HEAD:refs/heads/<branch>.
  clone="$FX_DIR/delivery"
  git clone -q "$FX_WT" "$clone"
  git -C "$clone" checkout -q -B "$FX_BRANCH" origin/"$FX_BRANCH" 2>/dev/null || git -C "$clone" checkout -q -B "$FX_BRANCH"
  git -C "$clone" remote add fork "file://$FX_FORK"
  git -C "$clone" remote add no-mistakes "$FX_GATE"
  run_in "$TMP_ROOT" git -C "$clone" push fork "HEAD:refs/heads/$FX_BRANCH"
  refused "git -C <scratch clone> push fork (361)" "$FX_FORK" "refs/heads/$FX_BRANCH"
  # A clone that never ran no-mistakes init is refused too: the rule needs no
  # gate remote in the pushing repository.
  git -C "$clone" remote remove no-mistakes
  run_in "$clone" git push fork "HEAD:refs/heads/$FX_BRANCH"
  refused "a push from a clone without a gate remote" "$FX_FORK" "refs/heads/$FX_BRANCH"
  pass "gate guard: a scratch delivery clone cannot push to the fork, with or without a gate remote"
}

test_command_spellings_a_parser_missed_are_refused() {
  fixture spellings
  # shellcheck disable=SC2016 # $1 and $2 expand in the child shell on purpose
  run_in "$TMP_ROOT" bash -c 'cd "$1" && git push fork "HEAD:refs/heads/$2"' _ "$FX_WT" "$FX_BRANCH"
  refused "cd X && git push" "$FX_FORK" "refs/heads/$FX_BRANCH"
  run_in "$FX_WT" git -c push.default=current push fork "HEAD:refs/heads/$FX_BRANCH"
  refused "git -c k=v push" "$FX_FORK" "refs/heads/$FX_BRANCH"
  run_in "$FX_WT" env git push fork "HEAD:refs/heads/$FX_BRANCH"
  refused "env git push" "$FX_FORK" "refs/heads/$FX_BRANCH"
  run_in "$FX_WT" env GIT_TRACE=0 git push fork "HEAD:refs/heads/$FX_BRANCH"
  refused "GIT_TRACE=0 git push" "$FX_FORK" "refs/heads/$FX_BRANCH"
  run_in "$FX_WT" git push origin HEAD:refs/heads/other
  refused "a push to origin under another branch name" "$FX_DIR/repo.origin.git" refs/heads/other
  pass "gate guard: cd &&, git -c, env git, an env prefix and another branch name are all refused"
}

test_gate_pushes_are_accepted() {
  fixture gate
  run_in "$FX_WT" git push no-mistakes "HEAD:refs/heads/$FX_BRANCH"
  accepted "git push no-mistakes" "$FX_GATE" "refs/heads/$FX_BRANCH"
  git -C "$FX_WT" commit -q --allow-empty -m 'second change'
  git -C "$FX_GATE" config receive.advertisePushOptions true
  run_in "$FX_WT" git push -o no-mistakes.intent=x no-mistakes "HEAD:refs/heads/$FX_BRANCH"
  accepted "a gate push with options" "$FX_GATE" "refs/heads/$FX_BRANCH"
  git -C "$FX_WT" commit -q --allow-empty -m 'third change'
  run_in "$TMP_ROOT" git -C "$FX_WT" push "file://$FX_GATE" "HEAD:refs/heads/$FX_BRANCH"
  accepted "a push to the gate by file:// URL" "$FX_GATE" "refs/heads/$FX_BRANCH"
  run_in "$FX_DIR" git -C wt push ../nm-home/repos/abc123.git HEAD:refs/heads/relative
  accepted "a relative gate path" "$FX_GATE" refs/heads/relative
  pass "gate guard: pushes to the stamped gate pass by name, with options, by URL and by path"
}

test_a_stamped_sibling_does_not_authorize_the_destination() {
  local other kind
  fixture sibling
  for kind in bare worktree; do
    other="$FX_DIR/other-$kind"
    if [ "$kind" = bare ]; then
      git init -q --bare "$other"
    else
      git init -q "$other"
    fi
    make_gate "$other.git"
    run_in "$FX_WT" git push "$other" HEAD:refs/heads/sibling
    refused "an unstamped $kind repo with a stamped .git sibling" "$other" refs/heads/sibling
  done
  pass "gate guard: a stamped sibling cannot authorize an unstamped destination"
}

test_gate_publication_passes() {
  local wt
  fixture publish
  # The daemon publishes the reviewed head from a worktree of the gate's own
  # bare repository; a daemon that inherited a pane's environment carries the
  # pane's hooks directory, so (g2) must let it push to the fork.
  run_in "$FX_WT" git push no-mistakes "HEAD:refs/heads/$FX_BRANCH"
  accepted "seeding the gate" "$FX_GATE" "refs/heads/$FX_BRANCH"
  wt="$FX_DIR/nm-home/worktrees/run1"
  git -C "$FX_GATE" worktree add -q "$wt" "$FX_BRANCH"
  run_in "$wt" git push "file://$FX_FORK" "HEAD:refs/heads/$FX_BRANCH"
  accepted "the gate publishing its run" "$FX_FORK" "refs/heads/$FX_BRANCH"
  pass "gate guard: the gate's own publication from its worktree reaches the fork"
}

test_repository_pre_push_still_chains() {
  local hooks_dir marker
  fixture chain
  hooks_dir=$(git -C "$FX_WT" rev-parse --path-format=absolute --git-path hooks)
  mkdir -p "$hooks_dir"
  marker="$FX_DIR/pre-push-ran"
  cat >"$hooks_dir/pre-push" <<EOF
#!/usr/bin/env bash
cat >"$marker"
[ ! -e "$FX_DIR/block" ]
EOF
  chmod +x "$hooks_dir/pre-push"
  run_in "$FX_WT" git push no-mistakes "HEAD:refs/heads/$FX_BRANCH"
  accepted "a gate push with a passing repository hook" "$FX_GATE" "refs/heads/$FX_BRANCH"
  assert_contains "$(cat "$marker")" "refs/heads/$FX_BRANCH" "the repository pre-push hook did not receive git's ref lines"
  rm -f "$marker"
  : >"$FX_DIR/block"
  git -C "$FX_WT" commit -q --allow-empty -m 'second change'
  run_in "$FX_WT" git push no-mistakes "HEAD:refs/heads/$FX_BRANCH"
  [ "$PUSH_RC" -ne 0 ] || fail "a failing repository pre-push hook no longer blocks a gate push"
  rm -f "$marker"
  run_in "$FX_WT" git push fork "HEAD:refs/heads/$FX_BRANCH"
  [ "$PUSH_RC" -ne 0 ] || fail "a fork push was accepted"
  assert_absent "$marker" "the repository pre-push hook ran even though the guard refused"
  pass "gate guard: the repository's own pre-push hook runs after the guard passes and still blocks"
}

test_direct_guard_calls() {
  local guard out rc
  guard="$TMP_ROOT/direct-guard"
  "$GUARD" write-gate "$guard" || fail "write-gate failed"
  # Network URLs are refused before git would ever connect; the wrapper cases
  # above prove the hook path, these prove the rule for https and ssh forms.
  for url in https://github.com/example/fork.git git@github.com:example/fork.git ssh://git@github.com/example/fork.git; do
    out=$(cd "$TMP_ROOT" && printf 'HEAD 1 refs/heads/fm/up-t1 0\n' | "$GUARD" "$guard" "$url" "$url" 2>&1)
    rc=$?
    [ "$rc" -ne 0 ] || fail "the gate guard accepted $url"
    assert_contains "$out" "not a no-mistakes gate" "$url was refused without naming the gate rule"
  done
  pass "gate guard: https and ssh fork URLs are refused"
}

test_spawn_installs_only_the_selected_ship_policy() {
  local mode keep harness forge forge_words gated name dir home project pool fakebin id out rc log prefix
  for name in gated-codex gated-keep-codex gated-claude gated-forgejo gerrit gerrit-keep direct direct-keep local; do
    mode=no-mistakes keep=0 harness=codex forge=none gated=1
    case "$name" in
      gated-keep-codex) keep=1 ;;
      gated-claude) harness=claude ;;
      gated-forgejo) forge=forgejo ;;
      gerrit) forge=gerrit ;;
      gerrit-keep) forge=gerrit keep=1 ;;
      direct) mode=direct-PR ;;
      direct-keep) mode=direct-PR keep=1 ;;
      local) mode=local-only ;;
    esac
    [ "$mode" = no-mistakes ] && [ "$forge" != gerrit ] || gated=0
    forge_words=
    [ "$forge" = none ] || forge_words=" forge=$forge"
    dir="$TMP_ROOT/spawn-$name"
    home="$dir/home" project="$dir/project" pool="$dir/pool"
    id="gate-$name" log="$dir/launch.log"
    fakebin=$(make_spawn_fakebin "$dir/fake" codex claude)
    fm_test_fake_no_mistakes "$fakebin"
    mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
    printf '%s\n' "$harness" >"$home/config/crew-harness"
    printf -- '- project [%s%s] - fixture\n' "$mode" "$forge_words" >"$home/data/projects.md"
    touch "$home/state/.last-watcher-beat"
    [ "$keep" = 0 ] || touch "$home/config/keep-ai-trailers"
    fm_git_worktree "$project" "$pool" "pool-$name"
    cat >"$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Ship a change.

## Firstmate spec
Exercise the selected push policy.

# Definition of done
Delivery contract: mode=$mode$forge_words
Ship branch: fm/$id
EOF
    out=$(FM_FAKE_LAUNCH_LOG="$log" fm_test_run_spawn "$home" "$pool" "$fakebin" \
      "$id" "$project" --mode "$mode" --yolo off); rc=$?
    expect_code 0 "$rc" "$name spawn failed: $out"
    prefix=
    if [ "$keep" = 0 ] || [ "$gated" = 1 ]; then
      prefix=$(fm_test_launch_git_prefix "$(cat "$log")") || fail "$name lacks its Git environment"
    fi
    # Execute the actual generated pane prefix, without a harness or real terminal.
    PUSH_OUT=$(eval "$prefix"
      git -C "$pool" push origin "HEAD:refs/heads/fm/$id" 2>&1)
    PUSH_RC=$?
    if [ "$gated" = 1 ]; then
      refused "$name fork push" "$project.origin.git" "refs/heads/fm/$id"
      make_gate "$dir/gate.git"
      out=$(eval "$prefix"
        git -C "$pool" push "$dir/gate.git" "HEAD:refs/heads/fm/$id" 2>&1); rc=$?
      expect_code 0 "$rc" "$name gate push failed: $out"
    else
      accepted "$name ordinary push" "$project.origin.git" "refs/heads/fm/$id"
      if [ "$forge" = gerrit ]; then
        out=$(eval "$prefix"
          git -C "$pool" push origin HEAD:refs/for/main 2>&1); rc=$?
        expect_code 0 "$rc" "$name Gerrit publication failed: $out"
        git -C "$project.origin.git" rev-parse --verify refs/for/main >/dev/null || fail "$name did not publish the review ref"
      fi
    fi
  done
  pass "gate guard: spawn protects no-mistakes Claude/Codex ships with either trailer setting and preserves other ship modes"
}

test_promotion_installs_the_gate_policy_or_refuses() {
  local forge forge_words keep dir home project pool fakebin id log prefix out rc
  for forge in none forgejo gerrit; do
    forge_words=
    [ "$forge" = none ] || forge_words=" forge=$forge"
    for keep in 0 1; do
      dir="$TMP_ROOT/promote-$forge-$keep"
      home="$dir/home" project="$dir/project" pool="$dir/pool"
      id="promote-$forge-$keep" log="$dir/launch.log"
      fakebin=$(make_spawn_fakebin "$dir/fake" codex)
      fm_test_fake_no_mistakes "$fakebin"
      mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
      printf 'codex\n' >"$home/config/crew-harness"
      printf -- '- project [no-mistakes%s] - fixture\n' "$forge_words" >"$home/data/projects.md"
      touch "$home/state/.last-watcher-beat"
      [ "$keep" = 0 ] || touch "$home/config/keep-ai-trailers"
      fm_git_worktree "$project" "$pool" "pool-$id"
      cat >"$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Investigate the delivery path.

## Firstmate spec
Report the result.
EOF
      out=$(FM_FAKE_LAUNCH_LOG="$log" fm_test_run_spawn "$home" "$pool" "$fakebin" \
        "$id" "$project" --scout); rc=$?
      expect_code 0 "$rc" "$id scout spawn failed: $out"
      prefix=
      [ "$keep" = 1 ] || prefix=$(fm_test_launch_git_prefix "$(cat "$log")")
      PUSH_OUT=$(eval "$prefix"
        git -C "$pool" push origin HEAD:refs/heads/scout-probe 2>&1)
      PUSH_RC=$?
      accepted "$id scout push" "$project.origin.git" refs/heads/scout-probe
      cp "$home/data/$id/brief.md" "$dir/scout-brief"
      out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
        "$ROOT/bin/fm-promote.sh" "$id" --mode no-mistakes --yolo off 2>&1); rc=$?
      if [ "$keep" = 1 ] && [ "$forge" != gerrit ]; then
        expect_code 1 "$rc" "$id promotion without a pane hooksPath succeeded"
        assert_contains "$out" "launched without the per-task Git hooksPath" "$id refusal did not name the missing protection"
        assert_grep 'kind=scout' "$home/state/$id.meta" "$id refusal promoted the task"
        cmp -s "$dir/scout-brief" "$home/data/$id/brief.md" || fail "$id refusal changed the brief"
        assert_absent "$home/data/$id/ship-instructions.md" "$id refusal published ship instructions"
        continue
      fi
      expect_code 0 "$rc" "$id promotion failed: $out"
      assert_grep 'kind=ship' "$home/state/$id.meta" "$id was not promoted"
      PUSH_OUT=$(eval "$prefix"
        git -C "$pool" push origin HEAD:refs/heads/ship-probe 2>&1)
      PUSH_RC=$?
      if [ "$forge" = gerrit ]; then
        accepted "$id Gerrit ship push" "$project.origin.git" refs/heads/ship-probe
      else
        refused "$id promoted ship push" "$project.origin.git" refs/heads/ship-probe
        make_gate "$dir/gate.git"
        out=$(eval "$prefix"
          git -C "$pool" push "$dir/gate.git" "HEAD:refs/heads/fm/$id" 2>&1); rc=$?
        expect_code 0 "$rc" "$id gate submission failed: $out"
        git -C "$dir/gate.git" rev-parse --verify "refs/heads/fm/$id" >/dev/null || fail "$id gate received no branch"
      fi
    done
  done
  pass "gate guard: promotion protects existing pane hooks, refuses missing hooks, and preserves Gerrit"
}

fm_test_run \
  test_unguarded_pushes_reproduce_the_incidents \
  test_recorded_bypass_shapes_are_refused \
  test_scratch_clone_named_fork_remote_is_refused \
  test_command_spellings_a_parser_missed_are_refused \
  test_gate_pushes_are_accepted \
  test_a_stamped_sibling_does_not_authorize_the_destination \
  test_gate_publication_passes \
  test_repository_pre_push_still_chains \
  test_direct_guard_calls \
  test_spawn_installs_only_the_selected_ship_policy \
  test_promotion_installs_the_gate_policy_or_refuses
