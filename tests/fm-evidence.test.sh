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

# A gh-axi stub reporting one named slug as public and every other slug as
# private, for the case where a remote's destinations do not agree.
fake_gh_axi_public_slug() {  # <fakebin> <public-slug>
  cat > "$1/gh-axi" <<SH
#!/usr/bin/env bash
slug=\${*: -1}
if [ "\$slug" = '$2' ]; then
  printf 'repo:\n  name: fleet-evidence\n  visibility: public\n'
else
  printf 'repo:\n  name: fleet-evidence\n  visibility: private\n'
fi
SH
  chmod +x "$1/gh-axi"
}

# An ssh stub that answers any host with one local bare repository, so a push to
# a real github.com URL can be exercised without a network. Echoes the command
# to hand to git through GIT_SSH_COMMAND.
fake_ssh_to_bare() {  # <fakebin> <bare>
  cat > "$1/ssh-to-bare" <<SH
#!/usr/bin/env bash
exec git receive-pack '$2'
SH
  chmod +x "$1/ssh-to-bare"
  printf '%s\n' "$1/ssh-to-bare"
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
  # A github.com host alias that resolves nowhere: the visibility precondition
  # is satisfied, so the push is really attempted and really fails.
  git -C "$home/evidence" remote add origin "ssh://git@github.com-offline/owner/name.git"
  fakebin=$(fm_fakebin "$home")
  fake_gh_axi "$fakebin" private

  out=$(PATH="$fakebin:$PATH" run_evidence "$home" preserve offline-task)
  rc=$?

  expect_code 0 "$rc" "preserve with an unreachable remote must still succeed"
  assert_contains "$out" "committed locally" "no explanation that custody was still achieved"
  assert_contains "$out" "the push did not succeed" "the attempted push was not reported as failed"
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
# does publish. The remote is a github.com URL because that is the only host
# whose visibility can be established; ssh is stubbed so the push still lands in
# a local bare repository.
test_private_destination_pushes() {
  local home fakebin bare ssh out
  home=$(make_home private-dest)
  make_task "$home" shipped-task
  bare="$TMP_ROOT/private-dest/owner/name.git"
  mkdir -p "$(dirname "$bare")"
  git init -q --bare "$bare"
  git -C "$home/evidence" remote add origin "ssh://git@github.com/owner/name.git"
  fakebin=$(fm_fakebin "$home")
  fake_gh_axi "$fakebin" private
  ssh=$(fake_ssh_to_bare "$fakebin" "$bare")

  out=$(PATH="$fakebin:$PATH" GIT_SSH_COMMAND="$ssh" run_evidence "$home" preserve shipped-task)
  assert_contains "$out" "pushed evidence" "a verified-private destination did not push"
  assert_contains "$(git --git-dir="$bare" ls-tree -r --name-only HEAD)" \
    "shipped-task/report.md" "the evidence never reached the remote"
  pass "fm-evidence: a verified-private destination is pushed"
}

# The visibility precondition only protects anything while it describes the
# repository the push would really reach. A non-GitHub destination cannot be
# checked at all, so it must skip the push rather than be authorized by whatever
# github.com repository happens to share its owner and name.
test_non_github_remote_skips_the_push() {
  local home fakebin bare ssh out rc
  home=$(make_home elsewhere)
  make_task "$home" offsite-task
  bare="$TMP_ROOT/elsewhere/acme/evidence.git"
  mkdir -p "$(dirname "$bare")"
  git init -q --bare "$bare"
  git -C "$home/evidence" remote add origin "ssh://git@gitlab.company.example/acme/evidence.git"
  fakebin=$(fm_fakebin "$home")
  # A gh-axi that reports private for any slug it is asked about, exactly as a
  # captain's own same-named private repository would.
  fake_gh_axi "$fakebin" private
  ssh=$(fake_ssh_to_bare "$fakebin" "$bare")

  out=$(PATH="$fakebin:$PATH" GIT_SSH_COMMAND="$ssh" run_evidence "$home" preserve offsite-task)
  rc=$?

  expect_code 0 "$rc" "a skipped push must not fail custody"
  assert_contains "$out" "gitlab.company.example" "the skipped push did not name the host it could not check"
  assert_not_contains "$out" "pushed evidence" "evidence was pushed to a host whose visibility was never established"
  [ -z "$(git --git-dir="$bare" ls-tree -r --name-only HEAD 2>/dev/null)" ] \
    || fail "unredacted evidence reached a remote that was never verified private"
  assert_contains "$(git -C "$home/evidence" ls-files)" "offsite-task/report.md" \
    "skipping the push also lost the local commit"
  pass "fm-evidence: a destination on another host skips the push and keeps custody"
}

# A remote can carry several push URLs, and a push then publishes to all of them
# at once, so a second destination on an unverifiable host disqualifies the whole
# push rather than riding along behind the first one's confirmation.
test_extra_non_github_pushurl_skips_the_push() {
  local home fakebin bare ssh out rc
  home=$(make_home mirrored)
  make_task "$home" mirrored-task
  bare="$TMP_ROOT/mirrored/owner/name.git"
  mkdir -p "$(dirname "$bare")"
  git init -q --bare "$bare"
  git -C "$home/evidence" remote add origin "ssh://git@github.com/owner/name.git"
  git -C "$home/evidence" remote set-url --add --push origin "ssh://git@github.com/owner/name.git"
  git -C "$home/evidence" remote set-url --add --push origin "ssh://git@gitlab.company.example/acme/evidence.git"
  fakebin=$(fm_fakebin "$home")
  fake_gh_axi "$fakebin" private
  ssh=$(fake_ssh_to_bare "$fakebin" "$bare")

  out=$(PATH="$fakebin:$PATH" GIT_SSH_COMMAND="$ssh" run_evidence "$home" preserve mirrored-task)
  rc=$?

  expect_code 0 "$rc" "a skipped push must not fail custody"
  assert_contains "$out" "gitlab.company.example" "the second push destination was never checked"
  assert_not_contains "$out" "pushed evidence" "evidence was pushed while one destination was unverifiable"
  [ -z "$(git --git-dir="$bare" ls-tree -r --name-only HEAD 2>/dev/null)" ] \
    || fail "evidence reached the verified destination of a push that also targets an unverified one"
  assert_contains "$(git -C "$home/evidence" ls-files)" "mirrored-task/report.md" \
    "skipping the push also lost the local commit"
  pass "fm-evidence: an unverifiable second push destination skips the whole push"
}

# The same rule by visibility rather than by host: every destination has to be
# private, so a public mirror alongside a private one refuses the push.
test_public_pushurl_among_private_refuses_the_push() {
  local home fakebin bare ssh out rc
  home=$(make_home mixed-visibility)
  make_task "$home" mixed-task
  bare="$TMP_ROOT/mixed-visibility/owner/name.git"
  mkdir -p "$(dirname "$bare")"
  git init -q --bare "$bare"
  git -C "$home/evidence" remote add origin "ssh://git@github.com/owner/name.git"
  git -C "$home/evidence" remote set-url --add --push origin "ssh://git@github.com/owner/name.git"
  git -C "$home/evidence" remote set-url --add --push origin "ssh://git@github.com/owner/mirror.git"
  fakebin=$(fm_fakebin "$home")
  fake_gh_axi_public_slug "$fakebin" owner/mirror
  ssh=$(fake_ssh_to_bare "$fakebin" "$bare")

  out=$(PATH="$fakebin:$PATH" GIT_SSH_COMMAND="$ssh" run_evidence "$home" preserve mixed-task)
  rc=$?

  expect_code 0 "$rc" "a refused push must not fail custody"
  assert_contains "$out" "REFUSED to push" "a public mirror among the destinations was not refused"
  assert_not_contains "$out" "pushed evidence" "evidence was pushed while one destination was public"
  [ -z "$(git --git-dir="$bare" ls-tree -r --name-only HEAD 2>/dev/null)" ] \
    || fail "unredacted evidence reached a push that also targets a public repository"
  assert_contains "$(git -C "$home/evidence" ls-files)" "mixed-task/report.md" \
    "refusing the push also lost the local commit"
  pass "fm-evidence: a public destination among private ones refuses the whole push"
}

# The staged-artifact check compares two path listings, so an ordinary awkward
# name - a space, a nested directory - must not read as an artifact that never
# reached the index and cost custody.
test_awkward_paths_are_recognized_as_staged() {
  local home out rc tracked
  home=$(make_home awkward)
  make_task "$home" spaced-task
  mkdir -p "$home/data/spaced-task/run 1"
  printf 'measured\n' > "$home/data/spaced-task/run 1/probe report.md"
  printf 'measured\n' > "$home/data/spaced-task/z-last.md"

  out=$(run_evidence "$home" preserve spaced-task)
  rc=$?

  expect_code 0 "$rc" "artifacts with spaces in their paths reported custody failure"
  assert_not_contains "$out" "not fully staged" "a staged artifact was reported as missing from the index"
  tracked=$(git -C "$home/evidence" ls-files)
  assert_contains "$tracked" "spaced-task/run 1/probe report.md" "the awkward path was not committed"
  pass "fm-evidence: artifacts with spaces in their paths are recognized as staged"
}

# Custody is a claim about what was committed, so the destination's ignore rules
# must not be able to drop an artifact out from under it.
test_ignored_artifact_is_still_committed() {
  local home out tracked
  home=$(make_home ignoring)
  make_task "$home" logged-task
  printf '*.log\ntmp/\n' > "$home/evidence/.gitignore"
  printf 'probe output\n' > "$home/data/logged-task/probe.log"

  out=$(run_evidence "$home" preserve logged-task)

  tracked=$(git -C "$home/evidence" ls-files)
  assert_contains "$tracked" "logged-task/probe.log" \
    "an artifact matched by the destination's ignore rules was never committed"
  assert_contains "$out" "committed 2 artifact(s)" "the count claimed did not match what was committed"
  pass "fm-evidence: the destination's ignore rules cannot drop an artifact from custody"
}

# A read-only artifact is ordinary for a captured fixture, and teardown runs this
# repeatedly across a fleet, so re-copying one must not fail and cost custody.
test_read_only_artifact_survives_a_repeat_preserve() {
  local home out rc
  home=$(make_home readonly)
  make_task "$home" fixture-task
  printf 'captured\n' > "$home/data/fixture-task/fixture.bin"
  chmod 444 "$home/data/fixture-task/fixture.bin"

  run_evidence "$home" preserve fixture-task >/dev/null
  out=$(run_evidence "$home" preserve fixture-task)
  rc=$?

  expect_code 0 "$rc" "a repeat preserve over a read-only artifact must not fail"
  assert_contains "$out" "already current" "the unchanged repeat was not reported as such"
  assert_not_contains "$out" "Permission denied" "re-copying a read-only artifact was refused"
  assert_not_contains "$out" "cannot copy" "re-copying a read-only artifact failed"
  assert_contains "$(git -C "$home/evidence" ls-files)" "fixture-task/fixture.bin" \
    "the read-only artifact was never committed"
  pass "fm-evidence: a read-only artifact can be preserved twice"
}

# The other half of the same rule: a copy that could not happen must reach the
# caller as custody failure, because the alternative is a claim of custody over
# material that was never written.
test_failed_copy_reports_custody_failure() {
  local home dest out rc
  home=$(make_home nocopy)
  make_task "$home" blocked-task

  run_evidence "$home" preserve blocked-task >/dev/null
  dest=$(run_evidence "$home" path blocked-task)
  # A second artifact appears, and the destination can no longer take a new file.
  printf 'measured\n' > "$home/data/blocked-task/probe.out"
  chmod 555 "$dest"

  out=$(run_evidence "$home" preserve blocked-task)
  rc=$?
  chmod 755 "$dest"

  [ "$rc" -ne 0 ] || fail "a copy that could not happen reported custody achieved"
  assert_contains "$out" "cannot copy" "the failed copy gave no actionable reason"
  pass "fm-evidence: a copy that cannot happen reports custody failure"
}

# A symlink is how corpus-scale material is referenced without duplicating it, so
# it is recorded rather than followed - but recorded it must be, because a silent
# omission would leave the evidence record incomplete with nothing to show it.
test_symlink_artifact_is_recorded_in_the_manifest() {
  local home dest manifest tracked
  home=$(make_home symlinks)
  make_task "$home" linked-task
  mkdir -p "$TMP_ROOT/corpus"
  printf 'huge\n' > "$TMP_ROOT/corpus/frames.bin"
  ln -s "$TMP_ROOT/corpus" "$home/data/linked-task/corpus"

  run_evidence "$home" preserve linked-task >/dev/null

  dest=$(run_evidence "$home" path linked-task)
  manifest=$(cat "$dest/EVIDENCE-MANIFEST.txt")
  assert_contains "$manifest" "symlink" "the symlink was left out of the manifest"
  assert_contains "$manifest" "corpus -> $TMP_ROOT/corpus" "the manifest lost the symlink's target"
  assert_absent "$dest/corpus" "the symlink was followed instead of recorded"
  tracked=$(git -C "$home/evidence" ls-files)
  assert_not_contains "$tracked" "linked-task/corpus/" "the symlink's target was committed as content"
  pass "fm-evidence: a symlinked artifact is recorded in the manifest, never followed"
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
test_non_github_remote_skips_the_push
test_extra_non_github_pushurl_skips_the_push
test_public_pushurl_among_private_refuses_the_push
test_unverifiable_visibility_skips_the_push
test_awkward_paths_are_recognized_as_staged
test_ignored_artifact_is_still_committed
test_read_only_artifact_survives_a_repeat_preserve
test_failed_copy_reports_custody_failure
test_symlink_artifact_is_recorded_in_the_manifest
test_repeat_preserve_is_idempotent
test_task_without_artifacts_is_not_an_error
