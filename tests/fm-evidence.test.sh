#!/usr/bin/env bash
# Behavior tests for bin/fm-evidence.sh, the custodian write-through that copies
# a task's surviving artifact directory into a separate evidence repository.
#
# The load-bearing contract here is the asymmetry between the commit and the
# push. The local commit is what guarantees custody, so it decides the exit
# code; the push is best-effort, so it never does. Collapsing those into one
# success path would make preserving evidence and reclaiming a worktree block
# each other, so several tests below pin the two halves separately and
# deliberately resist being simplified into one.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-evidence)
fm_git_identity

# A firstmate home plus a destination repository, wired together unless
# `--no-config` asks for the opted-out case. Echoes the home path.
make_home() {  # <name> [--no-config]
  local opt=${2:-} home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/config" "$home/evidence"
  git -C "$home/evidence" init -q
  git -C "$home/evidence" config user.name 'Firstmate Tests'
  git -C "$home/evidence" config user.email 'tests@example.invalid'
  if [ "$opt" != --no-config ]; then
    printf '%s\n' "$home/evidence" > "$home/config/evidence-repo"
  fi
  printf '%s\n' "$home"
}

# A task artifact directory with one small file, as every task has.
make_task() {  # <home> <task-id>
  mkdir -p "$1/data/$2"
  printf 'findings\n' > "$1/data/$2/report.md"
}

run_evidence() {  # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" "$ROOT/bin/fm-evidence.sh" "$@" 2>&1
}

# A gh-axi stub reporting the given visibility, in the real command's shape.
fake_gh_axi() {  # <fakebin> <visibility>
  cat > "$1/gh-axi" <<SH
#!/usr/bin/env bash
printf 'repo:\n  name: fleet-evidence\n  visibility: $2\n'
SH
  chmod +x "$1/gh-axi"
}

# A home that never opted in must behave exactly as one that has never heard of
# the feature: no output, no destination, and a clean exit that lets teardown
# proceed.
test_absent_config_is_a_silent_no_op() {
  local home out rc
  home=$(make_home optout --no-config)
  make_task "$home" quiet-task

  out=$(run_evidence "$home" preserve quiet-task)
  rc=$?

  expect_code 0 "$rc" "preserve without config/evidence-repo"
  [ -z "$out" ] || fail "opted-out home printed output: $out"
  [ -z "$(git -C "$home/evidence" log --oneline 2>/dev/null)" ] \
    || fail "opted-out home wrote a commit to the destination"
  pass "fm-evidence: a home without config/evidence-repo is a silent no-op"
}

# Opting in commits the artifacts under a path keyed by home then task, and the
# same path is derivable from the task alone through `path`.
test_preserve_commits_under_a_derivable_path() {
  local home out rc dest tracked
  home=$(make_home commits)
  make_task "$home" alpha-task

  out=$(run_evidence "$home" preserve alpha-task)
  rc=$?
  expect_code 0 "$rc" "preserve with a configured destination"

  dest=$(run_evidence "$home" path alpha-task)
  [ -d "$dest" ] || fail "preserve did not create the destination $dest"
  case "$dest" in
    "$home"/evidence/*/alpha-task) : ;;
    *) fail "destination is not <repo>/<home>/<task>: $dest" ;;
  esac

  tracked=$(git -C "$home/evidence" ls-files)
  assert_contains "$tracked" "alpha-task/report.md" "the artifact was not committed"
  assert_contains "$tracked" "alpha-task/EVIDENCE-MANIFEST.txt" "no manifest was committed"
  pass "fm-evidence: preserve commits artifacts under a path derivable from the task"
}

# Two homes using the same task id must not collide, which is what makes the
# layout safe for concurrent work across secondmate homes.
test_home_identity_separates_colliding_task_ids() {
  local one two dest_one dest_two
  one=$(make_home home-one)
  two=$(make_home home-two)
  make_task "$one" same-id
  make_task "$two" same-id

  dest_one=$(run_evidence "$one" path same-id)
  dest_two=$(run_evidence "$two" path same-id)

  [ "$(basename "$(dirname "$dest_one")")" != "$(basename "$(dirname "$dest_two")")" ] \
    || fail "two homes derived the same evidence path segment for one task id"
  pass "fm-evidence: home identity keeps colliding task ids apart"
}

# Corpus-scale material is described, never carried: over the boundary the
# content must stay out of git history while the record stays in the manifest.
test_oversize_artifacts_are_manifest_only() {
  local home tracked manifest
  home=$(make_home sizes)
  make_task "$home" big-task
  printf '64\n' > "$home/config/evidence-max-direct-bytes"
  head -c 4096 /dev/zero | tr '\0' 'x' > "$home/data/big-task/corpus.bin"

  run_evidence "$home" preserve big-task >/dev/null

  tracked=$(git -C "$home/evidence" ls-files)
  assert_contains "$tracked" "big-task/report.md" "the small artifact was not committed"
  assert_not_contains "$tracked" "big-task/corpus.bin" \
    "an over-limit artifact was committed as content instead of a manifest record"

  manifest=$(cat "$(run_evidence "$home" path big-task)/EVIDENCE-MANIFEST.txt")
  assert_contains "$manifest" "manifest-only" "the manifest did not record the oversize artifact"
  assert_contains "$manifest" "4096 corpus.bin" "the manifest lost the oversize artifact's size"
  assert_contains "$manifest" "committed" "the manifest did not record the committed artifact"
  pass "fm-evidence: artifacts over the limit are recorded by hash and size, never committed"
}

# A misconfigured destination must be loud. Falling back to the disabled path
# would silently discard evidence exactly when the operator believed it was
# being kept.
test_broken_configuration_is_loud() {
  local home out rc
  home=$(make_home broken)
  make_task "$home" any-task

  printf '%s\n' "$TMP_ROOT/does-not-exist" > "$home/config/evidence-repo"
  out=$(run_evidence "$home" preserve any-task)
  rc=$?
  [ "$rc" -ne 0 ] || fail "a destination that does not exist was accepted silently"
  assert_contains "$out" "names no directory" "missing destination gave no actionable reason"

  printf 'relative/path\n' > "$home/config/evidence-repo"
  out=$(run_evidence "$home" preserve any-task)
  rc=$?
  [ "$rc" -ne 0 ] || fail "a relative destination was accepted"
  assert_contains "$out" "absolute path" "relative destination gave no actionable reason"

  mkdir -p "$TMP_ROOT/not-a-repo"
  printf '%s\n' "$TMP_ROOT/not-a-repo" > "$home/config/evidence-repo"
  out=$(run_evidence "$home" preserve any-task)
  rc=$?
  [ "$rc" -ne 0 ] || fail "a destination that is not a git repository was accepted"
  assert_contains "$out" "not a git repository" "non-repository gave no actionable reason"
  pass "fm-evidence: a configured but unusable destination fails loudly"
}

# CUSTODY vs PUSH, half one: an unreachable remote must still report success,
# because the local commit already achieved custody. If this ever fails, a
# machine with no network can no longer reclaim a worktree.
test_unreachable_remote_still_succeeds_with_evidence_committed() {
  local home out rc fakebin
  home=$(make_home unreachable)
  make_task "$home" offline-task
  git -C "$home/evidence" remote add origin "ssh://git@github.invalid/owner/name.git"
  fakebin=$(fm_fakebin "$home")
  fake_gh_axi "$fakebin" private

  out=$(PATH="$fakebin:$PATH" run_evidence "$home" preserve offline-task)
  rc=$?

  expect_code 0 "$rc" "preserve with an unreachable remote must still succeed"
  assert_contains "$out" "committed locally" "no explanation that custody was still achieved"
  assert_contains "$(git -C "$home/evidence" ls-files)" "offline-task/report.md" \
    "the evidence was not committed when the push failed"
  pass "fm-evidence: an unreachable remote leaves evidence committed and still succeeds"
}

# CUSTODY vs PUSH, half two: a failed commit is the one failure that matters,
# because it means the evidence was never preserved and the caller must not
# destroy the source.
test_failed_commit_reports_custody_failure() {
  local home out rc
  home=$(make_home nocommit)
  make_task "$home" doomed-task
  # No identity and no way to obtain one: the commit cannot be created.
  git -C "$home/evidence" config --unset user.name
  git -C "$home/evidence" config --unset user.email

  out=$(HOME="$TMP_ROOT/nocommit" GIT_AUTHOR_NAME='' GIT_AUTHOR_EMAIL='' \
    GIT_COMMITTER_NAME='' GIT_COMMITTER_EMAIL='' GIT_CONFIG_GLOBAL=/dev/null \
    GIT_CONFIG_SYSTEM=/dev/null EMAIL='' \
    FM_HOME="$home" "$ROOT/bin/fm-evidence.sh" preserve doomed-task 2>&1)
  rc=$?

  [ "$rc" -ne 0 ] || fail "a failed commit reported success, so custody was claimed without evidence"
  assert_contains "$out" "commit" "custody failure gave no actionable reason"
  pass "fm-evidence: a failed commit reports custody failure so the caller keeps the source"
}

# Unredacted evidence is safe only while the destination is private, so a
# destination that is not private must refuse the push - and still keep the
# local commit, because refusing to publish is not a reason to lose custody.
test_public_destination_refuses_the_push() {
  local home out rc fakebin
  home=$(make_home public-dest)
  make_task "$home" exposed-task
  git -C "$home/evidence" remote add origin "ssh://git@github.com-personal/owner/name.git"
  fakebin=$(fm_fakebin "$home")
  fake_gh_axi "$fakebin" public

  out=$(PATH="$fakebin:$PATH" run_evidence "$home" preserve exposed-task)
  rc=$?

  expect_code 0 "$rc" "a refused push must not fail custody"
  assert_contains "$out" "REFUSED to push" "a public destination was not refused"
  assert_contains "$out" "private" "the refusal did not name the precondition it protects"
  assert_contains "$(git -C "$home/evidence" ls-files)" "exposed-task/report.md" \
    "refusing the push also lost the local commit"
  pass "fm-evidence: a destination that is not private refuses the push and keeps custody"
}

# The push happens only when visibility is confirmed private, and then it really
# does publish.
test_private_destination_pushes() {
  local home fakebin bare out
  home=$(make_home private-dest)
  make_task "$home" shipped-task
  bare="$TMP_ROOT/private-dest/owner/name.git"
  mkdir -p "$(dirname "$bare")"
  git init -q --bare "$bare"
  git -C "$home/evidence" remote add origin "file://$bare"
  fakebin=$(fm_fakebin "$home")
  fake_gh_axi "$fakebin" private

  out=$(PATH="$fakebin:$PATH" run_evidence "$home" preserve shipped-task)
  assert_contains "$out" "pushed evidence" "a verified-private destination did not push"
  assert_contains "$(git --git-dir="$bare" ls-tree -r --name-only HEAD)" \
    "shipped-task/report.md" "the evidence never reached the remote"
  pass "fm-evidence: a verified-private destination is pushed"
}

# Without any way to establish visibility the push is skipped rather than
# risked, and custody still holds.
test_unverifiable_visibility_skips_the_push() {
  local home out rc
  home=$(make_home unverifiable)
  make_task "$home" unknown-task
  git -C "$home/evidence" remote add origin "ssh://git@github.com-personal/owner/name.git"

  # No gh-axi on PATH at all.
  out=$(PATH="$TMP_ROOT/empty-path-dir:/usr/bin:/bin" run_evidence "$home" preserve unknown-task)
  rc=$?

  expect_code 0 "$rc" "unverifiable visibility must not fail custody"
  assert_contains "$out" "could not be verified" "the skipped push was not explained"
  assert_contains "$(git -C "$home/evidence" ls-files)" "unknown-task/report.md" \
    "custody was lost when visibility could not be checked"
  pass "fm-evidence: unverifiable visibility skips the push and keeps custody"
}

# Teardown runs this repeatedly across a fleet, so a second run over unchanged
# artifacts must not fail or pile up empty commits.
test_repeat_preserve_is_idempotent() {
  local home before after out
  home=$(make_home idempotent)
  make_task "$home" repeat-task

  run_evidence "$home" preserve repeat-task >/dev/null
  before=$(git -C "$home/evidence" rev-list --count HEAD)
  out=$(run_evidence "$home" preserve repeat-task)
  after=$(git -C "$home/evidence" rev-list --count HEAD)

  [ "$before" = "$after" ] || fail "a repeat preserve added a commit with nothing changed"
  assert_contains "$out" "already current" "the unchanged repeat was not reported as such"
  pass "fm-evidence: preserving unchanged artifacts twice adds no commit"
}

# A task with no artifact directory is ordinary, not an error.
test_task_without_artifacts_is_not_an_error() {
  local home out rc
  home=$(make_home empty-task-home)

  out=$(run_evidence "$home" preserve never-ran)
  rc=$?

  expect_code 0 "$rc" "a task with no artifacts must not fail"
  assert_contains "$out" "no artifacts" "the empty case was not explained"
  pass "fm-evidence: a task with no artifacts preserves nothing and succeeds"
}

test_absent_config_is_a_silent_no_op
test_preserve_commits_under_a_derivable_path
test_home_identity_separates_colliding_task_ids
test_oversize_artifacts_are_manifest_only
test_broken_configuration_is_loud
test_unreachable_remote_still_succeeds_with_evidence_committed
test_failed_commit_reports_custody_failure
test_public_destination_refuses_the_push
test_private_destination_pushes
test_unverifiable_visibility_skips_the_push
test_repeat_preserve_is_idempotent
test_task_without_artifacts_is_not_an_error
