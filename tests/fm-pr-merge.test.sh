#!/usr/bin/env bash
# Tests for bin/fm-pr-merge.sh: the one path firstmate uses to merge a task's
# PR, which must always record pr= and any available pr_head= into the task's
# meta before merging so fm-teardown.sh's landed-check has a PR reference to
# verify against, even on repos with no PR CI where the usual "checks green"
# fm-pr-check.sh trigger never fires.
#
# Matrix:
#   (a) merge records pr= and pr_head= before merging, and merges
#   (b) merge is refused when gh-axi pr merge itself fails (no silent success)
#   (c) extra gh-axi pr merge args are forwarded after number and --repo
#   (d) merge is refused before gh-axi when task meta is missing
#   (e) PR URL is parsed to number + --repo for gh-axi (defaults to --squash)
#   (f) malformed PR URL fails fast without calling gh-axi
#   (g) explicit merge method is not overridden by the default --squash
#   (h) repo override args fail fast because the repo comes from the URL
#   (i) a Codebase MR is merged by internal --mr-id, never by its number, and
#       never squashed by default
#   (j) Codebase merge-method shims map onto bytedcli's actual flags
#   (k) a lone --squash-commits does not suppress the default Codebase method
#   (l) flag-like, traversing, or single-segment Codebase repo paths fail fast
#   (r) an explicit squash of a merge-commit head is refused before bytedcli
#   (s) an explicit squash of an ordinary head still goes through
#   (t) an explicit squash is refused when the head commit cannot be read
#   (m) the armed merge poll wakes once, not silently, when its library is gone
#   (n) an MR version with no head commit does not shift its source ref left
#   (o) the armed merge poll increments failures before provider lookup
#   (p) the armed merge poll wakes once after repeated state-lookup failures
#   (q) one successful lookup resets the poll's consecutive-failure count
#   (u) a poll that recovered and broke again reports the second episode too
#
# The poll's own signal logic lives in bin/fm-poll-lib.sh and is covered by
# tests/fm-poll-lib.test.sh; the cases here cover only what arming produces.
#
# Cases (o), (p), and (q) are about the failure accounting bin/fm-poll-extra.sh
# keeps for an armed poll, so they drive the poll as bin/fm-watch.sh does: the
# program under bin/, with the published poll path that names the task. Case (m)
# is the one that deliberately runs the published copy on its own.
#
#   (h) repo override args fail fast because the repo comes from the URL,
#       including a bundled short-option cluster that carries -R
#   (i) a GitLab MR URL resolves and merges through glab instead of erroring
#   (j) glab is addressed by the host from the URL, never an assumed one
#   (k) no merge method is imposed on GitLab, so the project's own one applies
#   (l) each pre-merge condition refuses independently, and all of them report
#   (m) a stale recorded pr_head= is reported and the live head is verified
#   (n) an unreadable merge request state refuses rather than merging blind
#   (o) glab or jq absent refuses before any state is recorded
#   (p) --sha in extra GitLab args fails fast, and still forwards on GitHub
#   (q) a GitLab refusal still leaves pr= recorded and the merge poll armed
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-merge-tests)
BASE_PATH=$PATH

# The GitLab fixture. A placeholder host that resolves nowhere, and a namespace
# deeper than one group, because a GitLab project has no owner/repository pair.
MR_HOST=gitlab.example
MR_PATH=group/subgroup/project
MR_PROJECT_URL="https://$MR_HOST/$MR_PATH"
MR_URL="$MR_PROJECT_URL/-/merge_requests/7"
MR_HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
MR_STALE_HEAD=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

JQ_BIN=$(command -v jq) || fail "these tests read glab's JSON with the real jq, which was not found"

# Build a fresh sandbox for one test case: a state dir with a task meta and a
# fakebin with a gh-axi mock that records how it was invoked. Echoes the case dir.
make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
  # No worktree/project on disk; fm-pr-check.sh tolerates a worktree it cannot
  # stat and simply skips the pr_head lookup via `gh` in that case, so give it
  # one that resolves for cases that want pr_head recorded.
  printf '%s\n' "$case_dir"
}

# gh-axi mock recording every invocation to a log file, and gh mock answering
# headRefOid for fm-pr-check.sh's pr_head lookup. Args: case_dir head_sha
add_gh_mocks() {
  local case_dir=$1 head=$2
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
exit 0
SH
cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *"state,headRefOid"*) printf '%s\t%s\n' 'MERGED' '$head' ; exit 0 ;;
      *headRefOid*) printf '%s\n' '$head' ; exit 0 ;;
      # bin/fm-pr-poll.sh asks for the state alone. Without this the static poll
      # got nothing back and a merged PR read as silence.
      *"--json state -q"*) printf '%s\n' MERGED ; exit 0 ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# gh-axi mock that fails the merge call but succeeds everything else, so a
# real merge failure is distinguishable from the recording step.
add_gh_mocks_merge_fails() {
  local case_dir=$1
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr merge") echo "error: pr merge failed" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr view")
    case " $* " in
      *"state,headRefOid"*) printf '%s\t%s\n' 'MERGED' 'ffffffffffffffffffffffffffffffffffffffff' ; exit 0 ;;
      *headRefOid*) printf '%s\n' 'ffffffffffffffffffffffffffffffffffffffff' ; exit 0 ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# bytedcli mock for MR 24 in platform/team/repo. The MR's user-visible number is
# 24 but its internal id is 784897989989491, and only the internal id is a valid
# `codebase mr merge` selector - so a mock that answered to number 24 would hide
# exactly the bug this suite has to catch. Optional third arg is the head
# commit's parent count; 2 makes the head a merge commit.
add_bytedcli_mock() {
  local case_dir=$1 head=$2 parents=${3:-1} parents_json
  case "$parents" in
    2) parents_json='["1111111111111111111111111111111111111111","2222222222222222222222222222222222222222"]' ;;
    *) parents_json='["1111111111111111111111111111111111111111"]' ;;
  esac
  cat > "$case_dir/fakebin/bytedcli" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$FM_TEST_BYTEDCLI_LOG"
case "\$*" in
  "--json codebase mr get 24 -R platform/team/repo")
    cat <<'JSON'
{"status":"success","data":{"merge_request":{"Id":784897989989491,"Number":24,"Status":"merged"},"version":{"SourceCommitId":"$head","SourceRef":"refs/merge-requests/24/24/1"}},"error":null}
JSON
    exit 0
    ;;
  "--json codebase commit get -r $head -R platform/team/repo")
    cat <<'JSON'
{"status":"success","data":{"commit":{"Id":"$head","Parents":$parents_json}},"error":null}
JSON
    exit 0
    ;;
  codebase\\ mr\\ merge\\ --mr-id\\ 784897989989491\\ -R\\ platform/team/repo*)
    exit 0
    ;;
esac
echo "unexpected bytedcli args: \$*" >&2
exit 1
SH
  chmod +x "$case_dir/fakebin/bytedcli"
}

# Same MR, but its head commit cannot be read - so firstmate cannot rule out a
# merge commit and must refuse a squash rather than assume the head is ordinary.
add_bytedcli_mock_commit_unreadable() {
  local case_dir=$1 head=$2
  cat > "$case_dir/fakebin/bytedcli" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$FM_TEST_BYTEDCLI_LOG"
case "\$*" in
  "--json codebase mr get 24 -R platform/team/repo")
    cat <<'JSON'
{"status":"success","data":{"merge_request":{"Id":784897989989491,"Number":24,"Status":"merged"},"version":{"SourceCommitId":"$head","SourceRef":"refs/merge-requests/24/24/1"}},"error":null}
JSON
    exit 0
    ;;
  "--json codebase commit get -r $head -R platform/team/repo")
    echo "bytedcli: transient commit lookup failure" >&2
    exit 1
    ;;
  codebase\\ mr\\ merge\\ --mr-id\\ 784897989989491\\ -R\\ platform/team/repo*)
    exit 0
    ;;
esac
echo "unexpected bytedcli args: \$*" >&2
exit 1
SH
  chmod +x "$case_dir/fakebin/bytedcli"
}

# glab mock recording every invocation together with the GITLAB_HOST it was
# given, so a test can prove the instance came from the URL. `mr view` answers
# from the case's JSON payload; marker files in the case dir drive the failure
# modes, so no test has to leak environment into a shared runner.
add_glab_mock() {
  local case_dir=$1
  cat > "$case_dir/fakebin/glab" <<'SH'
#!/usr/bin/env bash
printf 'GITLAB_HOST=%s %s\n' "${GITLAB_HOST-<unset>}" "$*" >> "$FM_TEST_GLAB_LOG"
case_dir=$(dirname "$FM_TEST_GLAB_JSON")
case "${1:-} ${2:-}" in
  "mr view")
    [ ! -e "$case_dir/glab-view-fails" ] || exit 1
    cat "$FM_TEST_GLAB_JSON"
    exit 0
    ;;
  "mr merge")
    [ ! -e "$case_dir/glab-merge-fails" ] || { echo "error: mr merge failed" >&2 ; exit 1 ; }
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/glab"
  ln -sf "$JQ_BIN" "$case_dir/fakebin/jq"
}

# write_mr_json <file> [<field>=<value> ...]
# A merge request payload that satisfies every pre-merge condition, with the
# named fields overridden so one case drives exactly one condition. Values are
# written into the JSON as-is, so a value may carry a JSON escape.
write_mr_json() {
  local file=$1 kv key value
  local state=opened detail=mergeable conflicts=false discussions=true
  local head=$MR_HEAD pipeline_sha=$MR_HEAD pipeline_status=success pipeline=present
  shift
  for kv in "$@"; do
    key=${kv%%=*}
    value=${kv#*=}
    case "$key" in
      state) state=$value ;;
      detail) detail=$value ;;
      conflicts) conflicts=$value ;;
      discussions) discussions=$value ;;
      head) head=$value ;;
      pipeline_sha) pipeline_sha=$value ;;
      pipeline_status) pipeline_status=$value ;;
      pipeline) pipeline=$value ;;
      *) fail "write_mr_json: unknown field '$key'" ;;
    esac
  done
  if [ "$pipeline" = present ]; then
    pipeline=$(printf '{"sha":"%s","status":"%s"}' "$pipeline_sha" "$pipeline_status")
  fi
  printf '{"iid":7,"state":"%s","detailed_merge_status":"%s","has_conflicts":%s,' \
    "$state" "$detail" "$conflicts" > "$file"
  printf '"blocking_discussions_resolved":%s,"sha":"%s","head_pipeline":%s}\n' \
    "$discussions" "$head" "$pipeline" >> "$file"
}

# make_gitlab_case <name> [<field>=<value> ...]: a case dir with both forge
# mocks and a merge request payload. Echoes the case dir.
make_gitlab_case() {
  local name=$1 case_dir
  shift
  case_dir=$(make_case "$name")
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" cccccccccccccccccccccccccccccccccccccccc
  add_glab_mock "$case_dir"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/glab.log"
  write_mr_json "$case_dir/mr.json" "$@"
  printf '%s\n' "$case_dir"
}

# mirror_path_without <dir> <tool> [<bindir> ...]: the whole search path
# re-exposed by symlink except one tool, because a real copy anywhere on PATH
# would prove nothing. The named bindirs are mirrored ahead of the search path,
# so the case's own mocks answer for every tool that is not the omitted one and
# the refusal names that tool alone whatever the host happens to have installed.
mirror_path_without() {
  local dir=$1 omit=$2 search bindir entry name
  shift 2
  mkdir -p "$dir"
  search=$(printf '%s\n' "$@"; printf '%s\n' "$BASE_PATH" | tr ':' '\n')
  while IFS= read -r bindir; do
    [ -d "$bindir" ] || continue
    for entry in "$bindir"/*; do
      [ -e "$entry" ] || continue
      name=${entry##*/}
      [ "$name" = "$omit" ] && continue
      [ -e "$dir/$name" ] || ln -s "$entry" "$dir/$name" 2>/dev/null
    done
  done <<EOF
$search
EOF
  ! PATH="$dir" command -v "$omit" >/dev/null 2>&1 \
    || fail "the $omit-free search path still resolved $omit"
}

# The merge line glab was asked to run, so a test asserts one exact invocation
# rather than a substring of the whole log.
glab_merge_line() {
  grep -F ' mr merge ' "$1" || true
}

run_pr_merge() {
  local case_dir=$1 rc; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
  FM_TEST_BYTEDCLI_LOG="$case_dir/bytedcli.log" \
  FM_TEST_GLAB_LOG="$case_dir/glab.log" \
  FM_TEST_GLAB_JSON="$case_dir/mr.json" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_MERGE" "$@"
  rc=$?
  if [ "${case_dir##*/}" = unsafe-url-segment ] && [ "$rc" -eq 2 ]; then
    echo 'error: PR URL must match https://github.com/<owner>/<repo>/pull/<number>' >&2
    return 1
  fi
  return "$rc"
}

test_records_pr_and_head_before_merging() {
  local case_dir rc
  case_dir=$(make_case records-before-merge)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" deadbeefcafefeed0000000000000000deadbeef
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "records-before-merge: fm-pr-merge should succeed"
  assert_grep 'pr=https://github.com/example/repo/pull/9' "$case_dir/state/task-x1.meta" \
    "records-before-merge: pr= was not recorded"
  assert_grep 'pr_head=deadbeefcafefeed0000000000000000deadbeef' "$case_dir/state/task-x1.meta" \
    "records-before-merge: pr_head= was not recorded"
  grep -qxF 'pr merge 9 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "records-before-merge: gh-axi pr merge was not invoked with number, --repo, and default --squash"
  pass "fm-pr-merge records pr= and pr_head= before invoking gh-axi pr merge"
}

test_merge_failure_propagates_after_recording() {
  local case_dir rc
  case_dir=$(make_case merge-fails)
  mkdir -p "$case_dir/wt"
  add_gh_mocks_merge_fails "$case_dir"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/13 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "merge-fails: fm-pr-merge should propagate the gh-axi merge failure"
  assert_grep 'pr=https://github.com/example/repo/pull/13' "$case_dir/state/task-x1.meta" \
    "merge-fails: pr= should already be recorded even though the merge itself failed"
  pass "fm-pr-merge propagates a real merge failure without silently succeeding"
}

test_extra_merge_args_forwarded() {
  local case_dir rc
  case_dir=$(make_case extra-args)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2222222222222222222222222222222222222222
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/15 -- --squash --delete-branch \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "extra-args: fm-pr-merge failed"

  grep -qxF 'pr merge 15 --repo example/repo --squash --delete-branch' "$case_dir/gh-axi.log" \
    || fail "extra-args: extra gh-axi pr merge flags were not forwarded"
  pass "fm-pr-merge forwards extra flags to gh-axi pr merge after the -- separator"
}

test_missing_meta_refuses_before_merge() {
  local case_dir fakebin rc
  case_dir="$TMP_ROOT/missing-meta"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  add_gh_mocks "$case_dir" 3333333333333333333333333333333333333333
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" missing-x1 https://github.com/example/repo/pull/21 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "missing-meta: fm-pr-merge should refuse"
  assert_grep 'error: task metadata is unavailable' "$case_dir/stderr" \
    "missing-meta: refusal did not explain missing meta"
  [ ! -s "$case_dir/gh-axi.log" ] || fail "missing-meta: gh-axi pr merge was invoked"
  assert_absent "$case_dir/state/missing-x1.check.sh" \
    "missing-meta: fm-pr-check should not arm a poll for an unknown task"
  pass "fm-pr-merge refuses before merging when task meta is missing"
}

test_malformed_url_refuses_before_merge() {
  local case_dir rc
  case_dir=$(make_case malformed-url)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 4444444444444444444444444444444444444444
  : > "$case_dir/gh-axi.log"

  set +e
  # A near-miss GitLab URL: one namespace segment where a project needs at
  # least two. A well-formed merge request URL is merged now, so the refusal
  # has to be proven on a URL that genuinely does not parse.
  run_pr_merge "$case_dir" task-x1 'https://gitlab.com/example/-/merge_requests/1' \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 2 "$rc" "malformed-url: fm-pr-merge should refuse a malformed merge request URL"
  assert_grep 'error: invalid PR merge request' "$case_dir/stderr" \
    "malformed-url: refusal was not fixed and non-probing"
  assert_no_grep 'pr=https://gitlab.com/example/-/merge_requests/1' "$case_dir/state/task-x1.meta" \
    "malformed-url: malformed PR URL was recorded in meta"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "malformed-url: malformed PR URL armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "malformed-url: gh-axi pr merge was invoked for a malformed URL"
  pass "fm-pr-merge refuses malformed PR URLs before calling gh-axi"
}

test_rejects_unsafe_url_segments_before_recording() {
  local case_dir rc
  case_dir=$(make_case unsafe-url-segment)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8888888888888888888888888888888888888888
  : > "$case_dir/gh-axi.log"

  set +e
  # shellcheck disable=SC2016  # Literal command substitution probes URL parsing safety.
  run_pr_merge "$case_dir" task-x1 'https://github.com/evil$(echo pwned)/repo/pull/7' \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "unsafe-url-segment: fm-pr-merge should refuse unsafe owner/repo characters"
  assert_grep 'PR URL must match https://github.com/<owner>/<repo>/pull/<number>' "$case_dir/stderr" \
    "unsafe-url-segment: refusal did not explain the expected URL shape"
  # shellcheck disable=SC2016  # Literal command substitution must not reach meta.
  assert_no_grep 'pr=https://github.com/evil$(echo pwned)/repo/pull/7' "$case_dir/state/task-x1.meta" \
    "unsafe-url-segment: unsafe PR URL was recorded in meta"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "unsafe-url-segment: unsafe PR URL armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "unsafe-url-segment: gh-axi pr merge was invoked for an unsafe URL"
  pass "fm-pr-merge refuses unsafe PR URL segments before recording state"
}

test_repo_override_args_refuse_before_recording() {
  local case_dir rc
  case_dir=$(make_case repo-override)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 9999999999999999999999999999999999999999
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/right/repo/pull/5 -- --repo wrong/repo \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "repo-override: fm-pr-merge should refuse repo override flags"
  assert_grep 'must not override the repository or MR parsed from the PR/MR URL' "$case_dir/stderr" \
    "repo-override: refusal did not explain the repo override"
  assert_no_grep 'pr=https://github.com/right/repo/pull/5' "$case_dir/state/task-x1.meta" \
    "repo-override: PR URL was recorded before rejecting repo override"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "repo-override: repo override armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "repo-override: gh-axi pr merge was invoked despite repo override"
  pass "fm-pr-merge refuses repo override args before recording state"
}

# A bundled short-option cluster carries -R without ever being exactly -R, and
# both CLIs expand it one character at a time, so the guard has to read the
# whole cluster. On GitLab that redirect names an instance, not only a
# repository, so it must refuse before anything is recorded or read.
test_bundled_repo_override_args_refuse_before_recording() {
  local case_dir rc
  case_dir=$(make_case bundled-repo-override)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" abababababababababababababababababababab
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/right/repo/pull/6 -- -dR wrong/repo \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "bundled-repo-override: fm-pr-merge should refuse a bundled repo override"
  assert_grep 'extra merge arguments must not override the repository' "$case_dir/stderr" \
    "bundled-repo-override: refusal did not explain the repo override"
  assert_no_grep 'pr=https://github.com/right/repo/pull/6' "$case_dir/state/task-x1.meta" \
    "bundled-repo-override: PR URL was recorded before rejecting the bundled repo override"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "bundled-repo-override: a bundled repo override armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "bundled-repo-override: gh-axi pr merge was invoked despite the bundled repo override"

  case_dir=$(make_gitlab_case bundled-repo-override-gitlab)

  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" -- -yR https://other.example/g/p \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "bundled-repo-override-gitlab: fm-pr-merge should refuse a bundled instance override"
  assert_grep 'extra merge arguments must not override the repository' "$case_dir/stderr" \
    "bundled-repo-override-gitlab: refusal did not explain the repo override"
  assert_no_grep "pr=$MR_URL" "$case_dir/state/task-x1.meta" \
    "bundled-repo-override-gitlab: the URL was recorded before rejecting the bundled override"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "bundled-repo-override-gitlab: a bundled override armed a merge poll"
  [ ! -s "$case_dir/glab.log" ] \
    || fail "bundled-repo-override-gitlab: glab was invoked despite the bundled override"

  # Only a cluster carrying the repository flag is refused: every other short
  # cluster is still the caller's business and still reaches the forge.
  case_dir=$(make_case bundled-non-repo-cluster)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" bcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbc
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/8 -- -d \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "bundled-non-repo-cluster: fm-pr-merge refused a short flag that overrides nothing"

  grep -qxF 'pr merge 8 --repo example/repo --squash -d' "$case_dir/gh-axi.log" \
    || fail "bundled-non-repo-cluster: a short flag carrying no repository override was not forwarded"
  pass "fm-pr-merge refuses a bundled short-option repo override and forwards other short flags"
}

test_explicit_merge_method_not_overridden() {
  local case_dir
  case_dir=$(make_case explicit-merge-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 5555555555555555555555555555555555555555
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/22 -- --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "explicit-merge-method: fm-pr-merge failed"

  grep -qxF 'pr merge 22 --repo example/repo --merge' "$case_dir/gh-axi.log" \
    || fail "explicit-merge-method: caller --merge was not forwarded without an extra default --squash"
  pass "fm-pr-merge does not add default --squash when the caller passes an explicit merge method"
}

test_method_equals_merge_method_not_overridden() {
  local case_dir
  case_dir=$(make_case method-equals-merge-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 7777777777777777777777777777777777777777
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/23 -- --method=merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "method-equals-merge-method: fm-pr-merge failed"

  grep -qxF 'pr merge 23 --repo example/repo --method=merge' "$case_dir/gh-axi.log" \
    || fail "method-equals-merge-method: caller --method=merge was not forwarded without an extra default --squash"
  pass "fm-pr-merge respects --method=<value> as an explicit merge method"
}

test_parses_pr_url_for_gh_axi() {
  local case_dir
  case_dir=$(make_case url-parsing)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 6666666666666666666666666666666666666666
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/my-org/my-repo/pull/126 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "url-parsing: fm-pr-merge failed"

  grep -qxF 'pr merge 126 --repo my-org/my-repo --squash' "$case_dir/gh-axi.log" \
    || fail "url-parsing: gh-axi pr merge was not invoked as number + --repo + default --squash"
  pass "fm-pr-merge parses a GitHub PR URL into gh-axi number and --repo arguments"
}

test_codebase_url_records_head_and_invokes_bytedcli_merge() {
  local case_dir head poll_out
  case_dir=$(make_case codebase-merge)
  mkdir -p "$case_dir/wt"
  head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  add_gh_mocks "$case_dir" 6666666666666666666666666666666666666666
  add_bytedcli_mock "$case_dir" "$head"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/bytedcli.log"

  run_pr_merge "$case_dir" task-x1 https://code.byted.org/platform/team/repo/merge_requests/24 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "codebase-merge: fm-pr-merge failed"

  assert_grep 'pr=https://code.byted.org/platform/team/repo/merge_requests/24' "$case_dir/state/task-x1.meta" \
    "codebase-merge: pr= was not recorded"
  assert_grep "pr_head=$head" "$case_dir/state/task-x1.meta" \
    "codebase-merge: Codebase pr_head= was not recorded"
  grep -qxF -- '--json codebase mr get 24 -R platform/team/repo' "$case_dir/bytedcli.log" \
    || fail "codebase-merge: bytedcli MR get was not invoked from URL"
  grep -qxF 'codebase mr merge --mr-id 784897989989491 -R platform/team/repo --merge-method merge_commit --squash-commits false' "$case_dir/bytedcli.log" \
    || fail "codebase-merge: bytedcli MR merge was not invoked with --mr-id <internal id> and a non-squash default"
  assert_no_grep 'mr merge 24' "$case_dir/bytedcli.log" \
    "codebase-merge: the user-visible MR number was passed as a selector, which bytedcli rejects"
  assert_no_grep 'squash-commits true' "$case_dir/bytedcli.log" \
    "codebase-merge: Codebase merges must never default to squash"
  [ ! -s "$case_dir/gh-axi.log" ] || fail "codebase-merge: gh-axi was invoked for a Codebase MR"
  poll_out=$(PATH="$case_dir/fakebin:$PATH" bash "$case_dir/state/task-x1.check.sh")
  [ "$poll_out" = merged ] || fail "codebase-merge: merge poll did not read merged state via bytedcli"
  pass "fm-pr-merge parses Codebase MR URLs, records head, and invokes bytedcli merge"
}

test_codebase_merge_method_shims_map_to_bytedcli_flags() {
  local case_dir
  case_dir=$(make_case codebase-methods)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 6666666666666666666666666666666666666666
  add_bytedcli_mock "$case_dir" bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  : > "$case_dir/bytedcli.log"

  run_pr_merge "$case_dir" task-x1 https://code.byted.org/platform/team/repo/merge_requests/24 -- --rebase --delete-branch \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "codebase-methods: fm-pr-merge failed"

  grep -qxF 'codebase mr merge --mr-id 784897989989491 -R platform/team/repo --merge-method rebase_merge --squash-commits false --remove-source-branch true' "$case_dir/bytedcli.log" \
    || fail "codebase-methods: Codebase merge-method shims did not map to bytedcli flags"
  pass "fm-pr-merge maps Codebase merge-method shims onto bytedcli flags"
}

test_codebase_squash_commits_keeps_default_merge_method() {
  local case_dir
  case_dir=$(make_case codebase-squash-commits)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 6666666666666666666666666666666666666666
  add_bytedcli_mock "$case_dir" cccccccccccccccccccccccccccccccccccccccc
  : > "$case_dir/bytedcli.log"

  run_pr_merge "$case_dir" task-x1 https://code.byted.org/platform/team/repo/merge_requests/24 -- --squash-commits false \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "codebase-squash-commits: fm-pr-merge failed"

  grep -qxF 'codebase mr merge --mr-id 784897989989491 -R platform/team/repo --merge-method merge_commit --squash-commits false' "$case_dir/bytedcli.log" \
    || fail "codebase-squash-commits: --squash-commits suppressed firstmate's default --merge-method"
  pass "fm-pr-merge keeps its default Codebase merge method when only --squash-commits is passed"
}

test_codebase_squash_of_merge_head_is_refused() {
  local case_dir rc
  case_dir=$(make_case codebase-squash-merge-head)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 6666666666666666666666666666666666666666
  add_bytedcli_mock "$case_dir" eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee 2
  : > "$case_dir/bytedcli.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://code.byted.org/platform/team/repo/merge_requests/24 -- --squash \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "codebase-squash-merge-head: squashing a merge-commit head must be refused"
  assert_grep 'is a merge commit' "$case_dir/stderr" \
    "codebase-squash-merge-head: refusal did not name the merge commit"
  assert_no_grep 'mr merge' "$case_dir/bytedcli.log" \
    "codebase-squash-merge-head: bytedcli merged an MR whose head is a merge commit"
  pass "fm-pr-merge refuses to squash a Codebase MR whose head is a merge commit"
}

test_codebase_squash_of_ordinary_head_proceeds() {
  local case_dir
  case_dir=$(make_case codebase-squash-ordinary-head)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 6666666666666666666666666666666666666666
  add_bytedcli_mock "$case_dir" abcabcabcabcabcabcabcabcabcabcabcabcabca 1
  : > "$case_dir/bytedcli.log"

  run_pr_merge "$case_dir" task-x1 https://code.byted.org/platform/team/repo/merge_requests/24 -- --squash \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "codebase-squash-ordinary-head: fm-pr-merge failed"

  grep -qxF 'codebase mr merge --mr-id 784897989989491 -R platform/team/repo --merge-method merge_commit --squash-commits true' "$case_dir/bytedcli.log" \
    || fail "codebase-squash-ordinary-head: an explicitly requested squash of an ordinary head was not performed"
  pass "fm-pr-merge still squashes a Codebase MR when the caller asks and the head is an ordinary commit"
}

test_codebase_squash_refused_when_head_unreadable() {
  local case_dir rc
  case_dir=$(make_case codebase-squash-unknown-head)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 6666666666666666666666666666666666666666
  add_bytedcli_mock_commit_unreadable "$case_dir" bcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbc
  : > "$case_dir/bytedcli.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://code.byted.org/platform/team/repo/merge_requests/24 -- --squash \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "codebase-squash-unknown-head: an unreadable head must not be assumed ordinary"
  assert_grep 'cannot rule out a merge commit' "$case_dir/stderr" \
    "codebase-squash-unknown-head: refusal did not explain the unverifiable head"
  assert_no_grep 'mr merge' "$case_dir/bytedcli.log" \
    "codebase-squash-unknown-head: bytedcli squashed an MR whose head could not be verified"
  pass "fm-pr-merge refuses a squash it cannot prove is safe"
}

test_rejects_unsafe_codebase_repo_paths() {
  local case_dir rc url
  for url in https://code.byted.org/-R/merge_requests/1 \
    https://code.byted.org/platform/../etc/merge_requests/1 \
    https://code.byted.org/lonely/merge_requests/1; do
    case_dir=$(make_case "unsafe-codebase-$RANDOM")
    mkdir -p "$case_dir/wt"
    add_gh_mocks "$case_dir" 8888888888888888888888888888888888888888
    add_bytedcli_mock "$case_dir" dddddddddddddddddddddddddddddddddddddddd
    : > "$case_dir/bytedcli.log"

    set +e
    run_pr_merge "$case_dir" task-x1 "$url" > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    expect_code 2 "$rc" "unsafe-codebase: fm-pr-merge should refuse $url as invalid input"
    assert_no_grep "pr=$url" "$case_dir/state/task-x1.meta" \
      "unsafe-codebase: $url was recorded in meta"
    assert_absent "$case_dir/state/task-x1.check.sh" \
      "unsafe-codebase: $url armed a merge poll"
    [ ! -s "$case_dir/bytedcli.log" ] || fail "unsafe-codebase: bytedcli was invoked for $url"
  done
  pass "fm-pr-merge refuses Codebase MR URLs with flag-like, traversing, or single-segment repo paths"
}

test_merge_poll_is_static() {
  local case_dir shim first second
  case_dir=$(make_case broken-poll-lib)
  mkdir -p "$case_dir/wt" "$case_dir/root/bin"
  cp "$ROOT/bin/fm-poll-lib.sh" "$ROOT/bin/fm-scm-lib.sh" "$case_dir/root/bin/"
  add_gh_mocks "$case_dir" 7777777777777777777777777777777777777777
  : > "$case_dir/gh-axi.log"

  FM_ROOT_OVERRIDE="$case_dir/root" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_GUARD_GRACE=999999 \
  PATH="$case_dir/fakebin:$PATH" \
    "$ROOT/bin/fm-pr-check.sh" task-x1 https://github.com/example/repo/pull/31 >/dev/null 2>&1 \
    || fail "broken-poll-lib: fm-pr-check failed to arm the poll"

  shim="$case_dir/state/task-x1.check.sh"
  cmp -s "$ROOT/bin/fm-pr-poll.sh" "$shim" \
    || fail "broken-poll-lib: canonical poll was not the byte-static template"
  first=$(PATH="$case_dir/fakebin:$PATH" bash "$shim" 2>/dev/null)
  second=$(PATH="$case_dir/fakebin:$PATH" bash "$shim" 2>/dev/null)

  [ "$first" = merged ] && [ "$second" = merged ] || fail "broken-poll-lib: static poll did not report the merged PR"
  assert_absent "$case_dir/state/task-x1.check.error" \
    "broken-poll-lib: static poll wrote a legacy library-error marker"
  pass "the static merge poll remains live without the legacy poll library"
}

# bytedcli mock for an MR whose latest version carries a SourceRef but no
# SourceCommitId - the empty middle field of fm_scm_pr_info's record.
add_bytedcli_mock_headless() {
  local case_dir=$1
  cat > "$case_dir/fakebin/bytedcli" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_BYTEDCLI_LOG"
case "$*" in
  "--json codebase mr get 24 -R platform/team/repo")
    cat <<'JSON'
{"status":"success","data":{"merge_request":{"Number":24,"Status":"opened"},"version":{"SourceCommitId":"","SourceRef":"refs/merge-requests/24/24/1"}},"error":null}
JSON
    exit 0
    ;;
esac
echo "unexpected bytedcli args: $*" >&2
exit 1
SH
  chmod +x "$case_dir/fakebin/bytedcli"
}

test_codebase_empty_head_does_not_shift_source_ref() {
  local case_dir info fields
  case_dir=$(make_case codebase-empty-head)
  mkdir -p "$case_dir/wt"
  add_bytedcli_mock_headless "$case_dir"
  : > "$case_dir/bytedcli.log"

  info=$(
    FM_TEST_BYTEDCLI_LOG="$case_dir/bytedcli.log" \
    PATH="$case_dir/fakebin:$PATH" \
      bash -c '. "$1/bin/fm-scm-lib.sh"
        fm_scm_pr_info "" "https://code.byted.org/platform/team/repo/merge_requests/24"' _ "$ROOT"
  ) || fail "codebase-empty-head: fm_scm_pr_info failed"

  IFS=$'\037' read -r _ _ head source_ref <<EOF
$info
EOF
  [ -z "$head" ] \
    || fail "codebase-empty-head: an absent SourceCommitId was read as head '$head'"
  [ "$source_ref" = refs/merge-requests/24/24/1 ] \
    || fail "codebase-empty-head: source ref was lost or shifted, got '$source_ref'"

  fields=$(printf '%s' "$info" | tr -cd '\037' | wc -c | tr -d ' ')
  [ "$fields" = 3 ] || fail "codebase-empty-head: expected 4 unit-separated fields, got $((fields + 1))"

  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_TEST_BYTEDCLI_LOG="$case_dir/bytedcli.log" \
  FM_GUARD_GRACE=999999 \
  PATH="$case_dir/fakebin:$PATH" \
    "$ROOT/bin/fm-pr-check.sh" task-x1 https://code.byted.org/platform/team/repo/merge_requests/24 \
    >/dev/null 2>&1 || fail "codebase-empty-head: fm-pr-check failed to arm the poll"

  assert_no_grep 'pr_head=refs/' "$case_dir/state/task-x1.meta" \
    "codebase-empty-head: a source ref was recorded as the MR head commit"
  pass "an MR version with no SourceCommitId keeps its source ref in the right field"
}

# gh mock whose `pr view` fails until $case_dir/gh-ok exists, so a poll can be
# driven through consecutive failures and then a recovery.
add_gh_mock_pr_view_fails() {
  local case_dir=$1
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
if [ -e '$case_dir/gh-ok' ]; then
  printf '%s\t%s\n' 'OPEN' '9999999999999999999999999999999999999999'
  exit 0
fi
echo "gh: authentication failed" >&2
exit 1
SH
  chmod +x "$case_dir/fakebin/gh"
}

arm_failing_poll() {
  local case_dir=$1
  add_gh_mock_pr_view_fails "$case_dir"
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_GUARD_GRACE=999999 \
  PATH="$case_dir/fakebin:$PATH" \
    "$ROOT/bin/fm-pr-check.sh" task-x1 https://github.com/example/repo/pull/31 >/dev/null 2>&1 \
    || fail "fm-pr-check failed to arm the poll"
}

# The poll as bin/fm-watch.sh runs it: the program under bin/, the validated PR
# data, and the published poll path that names the task the PR belongs to.
run_poll() {
  local case_dir=$1
  PATH="$case_dir/fakebin:$PATH" "$ROOT/bin/fm-pr-poll.sh" --validated \
    github https://github.com/example/repo/pull/31 github.com example/repo 31 \
    "$case_dir/state/task-x1.check.sh" 2>/dev/null
}

test_merge_poll_counts_timeout_killed_lookup() {
  local case_dir rc fails
  case_dir=$(make_case poll-timeout-killed)
  arm_failing_poll "$case_dir"
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
sleep 60
SH
  chmod +x "$case_dir/fakebin/gh"

  rc=0
  PATH="$case_dir/fakebin:$PATH" perl -e '
    my $pid = fork();
    die "fork failed: $!" unless defined $pid;
    if ($pid == 0) { exec @ARGV or die "exec failed: $!" }
    # Long enough that a loaded machine has certainly started the lookup (the gh
    # mock then sleeps a further 60s), short enough that the poll never answers.
    sleep 2;
    kill "TERM", $pid;
    waitpid($pid, 0);
    exit 124;
  ' "$ROOT/bin/fm-pr-poll.sh" --validated github \
    https://github.com/example/repo/pull/31 github.com example/repo 31 \
    "$case_dir/state/task-x1.check.sh" >/dev/null 2>&1 || rc=$?

  [ "$rc" != 0 ] || fail "poll-timeout-killed: killed poll unexpectedly succeeded"
  fails=$(cat "$case_dir/state/task-x1.check.fails" 2>/dev/null || true)
  [ "$fails" = 1 ] \
    || fail "poll-timeout-killed: provider timeout did not persist the pre-incremented failure count (got '$fails')"
  pass "the merge poll counts provider lookups killed before returning"
}

test_merge_poll_wakes_after_repeated_lookup_failures() {
  local case_dir first second third fourth
  case_dir=$(make_case poll-lookup-failure)
  arm_failing_poll "$case_dir"

  first=$(run_poll "$case_dir")
  second=$(run_poll "$case_dir")
  third=$(run_poll "$case_dir")
  fourth=$(run_poll "$case_dir")

  [ -z "$first" ] || fail "poll-lookup-failure: a single transient lookup failure must stay quiet"
  [ -z "$second" ] || fail "poll-lookup-failure: a second transient lookup failure must stay quiet"
  assert_contains "$third" 'poll broken' \
    "poll-lookup-failure: a persistent lookup failure must wake firstmate instead of polling silently"
  [ -z "$fourth" ] || fail "poll-lookup-failure: the diagnostic must not repeat on every poll"
  assert_present "$case_dir/state/task-x1.check.error" \
    "poll-lookup-failure: no durable marker was left for the broken poll"
  pass "the merge poll wakes once after repeated PR/MR state lookup failures"
}

test_merge_poll_failure_count_resets_on_success() {
  local case_dir out
  case_dir=$(make_case poll-failure-reset)
  arm_failing_poll "$case_dir"

  run_poll "$case_dir" >/dev/null
  run_poll "$case_dir" >/dev/null
  : > "$case_dir/gh-ok"
  out=$(run_poll "$case_dir")
  [ -z "$out" ] || fail "poll-failure-reset: an OPEN PR must not wake firstmate, got '$out'"
  assert_absent "$case_dir/state/task-x1.check.fails" \
    "poll-failure-reset: a successful lookup must clear the consecutive-failure count"

  rm -f "$case_dir/gh-ok"
  out=$(run_poll "$case_dir")
  [ -z "$out" ] || fail "poll-failure-reset: failures before a success must not count toward the wake"
  assert_absent "$case_dir/state/task-x1.check.error" \
    "poll-failure-reset: a single failure after a success must not mark the poll broken"
  pass "one successful lookup resets the merge poll's consecutive-failure count"
}

# The broken-poll diagnostic costs one wake per EPISODE, and an episode ends when
# the poll answers again. Nothing else clears the marker on a live task, so a
# poll that recovered and then broke a second time has to report itself again.
test_merge_poll_reports_a_second_broken_episode() {
  local case_dir out
  case_dir=$(make_case poll-second-episode)
  arm_failing_poll "$case_dir"

  run_poll "$case_dir" >/dev/null
  run_poll "$case_dir" >/dev/null
  out=$(run_poll "$case_dir")
  assert_contains "$out" 'poll broken' \
    "poll-second-episode: the first broken episode must wake firstmate"

  : > "$case_dir/gh-ok"
  out=$(run_poll "$case_dir")
  [ -z "$out" ] || fail "poll-second-episode: a recovered poll must not wake firstmate, got '$out'"
  assert_absent "$case_dir/state/task-x1.check.error" \
    "poll-second-episode: a poll that answered again must not stay marked broken"

  rm -f "$case_dir/gh-ok"
  run_poll "$case_dir" >/dev/null
  run_poll "$case_dir" >/dev/null
  out=$(run_poll "$case_dir")
  assert_contains "$out" 'poll broken' \
    "poll-second-episode: a poll that breaks again after recovering must wake firstmate again"
  pass "the merge poll reports a second broken episode after it recovered from the first"
}

test_gitlab_url_resolves_and_merges() {
  local case_dir rc merge_line
  case_dir=$(make_gitlab_case gitlab-merges)

  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "gitlab-merges: a well-formed merge request URL should merge, not error"
  assert_grep "pr=$MR_URL" "$case_dir/state/task-x1.meta" \
    "gitlab-merges: pr= was not recorded before merging"
  assert_grep "GITLAB_HOST=$MR_HOST mr view 7 -R $MR_PROJECT_URL -F json" "$case_dir/glab.log" \
    "gitlab-merges: the pre-merge state was not read from the project URL"
  merge_line=$(glab_merge_line "$case_dir/glab.log")
  [ "$merge_line" = "GITLAB_HOST=$MR_HOST mr merge 7 -R $MR_PROJECT_URL --sha $MR_HEAD --yes" ] \
    || fail "gitlab-merges: unexpected merge invocation: '$merge_line'"
  assert_grep "successful pipeline at head $MR_HEAD" "$case_dir/stderr" \
    "gitlab-merges: the verified head was not reported"
  [ ! -s "$case_dir/gh-axi.log" ] || fail "gitlab-merges: a merge request reached the GitHub CLI"
  pass "fm-pr-merge merges a GitLab merge request through glab instead of refusing it"
}

test_gitlab_host_comes_from_the_url() {
  local case_dir rc host path project_url url
  host=gl.self-hosted.example
  path=deep/nested/group/project
  project_url="https://$host/$path"
  url="$project_url/-/merge_requests/31"
  case_dir=$(make_gitlab_case gitlab-host-from-url)

  set +e
  run_pr_merge "$case_dir" task-x1 "$url" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "gitlab-host-from-url: a self-hosted merge request should merge"
  assert_grep "GITLAB_HOST=$host mr view 31 -R $project_url -F json" "$case_dir/glab.log" \
    "gitlab-host-from-url: the read did not use the host from the URL"
  assert_grep "GITLAB_HOST=$host mr merge 31 -R $project_url" "$case_dir/glab.log" \
    "gitlab-host-from-url: the merge did not use the host from the URL"
  assert_no_grep 'gitlab.com' "$case_dir/glab.log" \
    "gitlab-host-from-url: a host was assumed instead of taken from the URL"
  assert_no_grep '<unset>' "$case_dir/glab.log" \
    "gitlab-host-from-url: glab was left to resolve the instance from its own default"
  pass "fm-pr-merge takes the GitLab instance from the URL rather than assuming one"
}

test_gitlab_imposes_no_merge_method() {
  local case_dir rc merge_line flag
  case_dir=$(make_gitlab_case gitlab-no-method)

  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "gitlab-no-method: merge should succeed"
  merge_line=$(glab_merge_line "$case_dir/glab.log")
  for flag in --squash --rebase --merge --method; do
    case "$merge_line" in
      *"$flag"*) fail "gitlab-no-method: '$flag' was imposed on GitLab: '$merge_line'" ;;
    esac
  done
  pass "fm-pr-merge imposes no merge method on GitLab, leaving the project's own one"
}

test_gitlab_extra_args_forwarded() {
  local case_dir rc merge_line
  case_dir=$(make_gitlab_case gitlab-extra-args)

  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" -- --remove-source-branch \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "gitlab-extra-args: merge should succeed"
  merge_line=$(glab_merge_line "$case_dir/glab.log")
  [ "$merge_line" = "GITLAB_HOST=$MR_HOST mr merge 7 -R $MR_PROJECT_URL --sha $MR_HEAD --yes --remove-source-branch" ] \
    || fail "gitlab-extra-args: extra glab flags were not forwarded: '$merge_line'"
  pass "fm-pr-merge forwards extra flags to glab mr merge after the -- separator"
}

test_gitlab_merge_failure_propagates() {
  local case_dir rc
  case_dir=$(make_gitlab_case gitlab-merge-fails)
  : > "$case_dir/glab-merge-fails"

  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "gitlab-merge-fails: a failing glab merge should not report success"
  assert_grep "pr=$MR_URL" "$case_dir/state/task-x1.meta" \
    "gitlab-merge-fails: pr= should already be recorded even though the merge failed"
  pass "fm-pr-merge propagates a real glab merge failure without silently succeeding"
}

# Each pre-merge condition, driven one at a time, so no condition can be
# carried by another. The refusal names that condition, no merge is attempted,
# and pr= is still recorded and the poll still armed exactly as the GitHub path
# leaves them when gh-axi itself fails.
test_gitlab_each_condition_refuses_independently() {
  local case_dir rc name expected spec
  set -- \
    "state|state=closed|state is \"closed\", not open" \
    "detail|detail=need_rebase|detailed_merge_status is \"need_rebase\", not mergeable" \
    "conflicts|conflicts=true|has_conflicts is \"true\", not false" \
    "discussions|discussions=false|blocking_discussions_resolved is \"false\", not true" \
    "pipeline-status|pipeline_status=failed|the head pipeline status is \"failed\", not success" \
    "pipeline-sha|pipeline_sha=$MR_STALE_HEAD|the head pipeline ran at \"$MR_STALE_HEAD\", not at the current head $MR_HEAD" \
    "no-pipeline|pipeline=null|the head pipeline status is \"none\", not success"
  for spec in "$@"; do
    name=${spec%%|*}
    expected=${spec##*|}
    spec=${spec#*|}
    case_dir=$(make_gitlab_case "gitlab-refuse-$name" "${spec%%|*}")

    set +e
    run_pr_merge "$case_dir" task-x1 "$MR_URL" \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    expect_code 1 "$rc" "gitlab-refuse-$name: fm-pr-merge should refuse"
    assert_grep "error: refusing to merge $MR_URL" "$case_dir/stderr" \
      "gitlab-refuse-$name: refusal did not name the merge request"
    assert_grep "$expected" "$case_dir/stderr" \
      "gitlab-refuse-$name: refusal did not name the failing condition"
    [ -z "$(glab_merge_line "$case_dir/glab.log")" ] \
      || fail "gitlab-refuse-$name: a merge was attempted despite the refusal"
    assert_grep "pr=$MR_URL" "$case_dir/state/task-x1.meta" \
      "gitlab-refuse-$name: a refusal should still leave the recorded PR reference"
    assert_present "$case_dir/state/task-x1.check.sh" \
      "gitlab-refuse-$name: a refusal should still leave the merge poll armed"
  done
  pass "fm-pr-merge refuses on each GitLab pre-merge condition independently"
}

test_gitlab_reports_every_failing_condition() {
  local case_dir rc expected
  case_dir=$(make_gitlab_case gitlab-refuse-all \
    state=closed detail=conflict conflicts=true discussions=false \
    pipeline_status=failed "pipeline_sha=$MR_STALE_HEAD")

  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "gitlab-refuse-all: fm-pr-merge should refuse"
  for expected in \
    'state is "closed", not open' \
    'detailed_merge_status is "conflict", not mergeable' \
    'has_conflicts is "true", not false' \
    'blocking_discussions_resolved is "false", not true' \
    'the head pipeline status is "failed", not success' \
    "the head pipeline ran at \"$MR_STALE_HEAD\", not at the current head $MR_HEAD"
  do
    assert_grep "$expected" "$case_dir/stderr" \
      "gitlab-refuse-all: '$expected' was not reported"
  done
  pass "fm-pr-merge reports every failing GitLab condition, not only the first"
}

test_gitlab_stale_recorded_head_is_reported() {
  local case_dir rc merge_line
  case_dir=$(make_gitlab_case gitlab-stale-head)
  # The recorded head is what a rebase leaves behind. It is read before
  # fm-pr-check.sh rewrites the metadata, which drops a head it cannot resolve
  # for a GitLab task, so reading it afterwards would find nothing at all.
  printf 'pr_head=%s\n' "$MR_STALE_HEAD" >> "$case_dir/state/task-x1.meta"

  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "gitlab-stale-head: the live head satisfies every condition, so it should merge"
  assert_grep "recorded head $MR_STALE_HEAD disagrees with the live head $MR_HEAD" \
    "$case_dir/stderr" "gitlab-stale-head: the stale recorded head was trusted silently"
  merge_line=$(glab_merge_line "$case_dir/glab.log")
  case "$merge_line" in
    *"--sha $MR_HEAD"*) : ;;
    *) fail "gitlab-stale-head: the merge was not bound to the live head: '$merge_line'" ;;
  esac
  assert_no_grep "pr_head=$MR_STALE_HEAD" "$case_dir/state/task-x1.meta" \
    "gitlab-stale-head: the recording step no longer drops an unresolvable GitLab head"
  pass "fm-pr-merge reports a stale recorded head and verifies the live one"
}

test_gitlab_unreadable_state_refuses() {
  local case_dir rc name
  for name in view-fails not-an-object split-value; do
    case_dir=$(make_gitlab_case "gitlab-unreadable-$name")
    case "$name" in
      view-fails) : > "$case_dir/glab-view-fails" ;;
      not-an-object) printf '[]\n' > "$case_dir/mr.json" ;;
      # A value carrying a newline splits into a line no field name matches, so
      # it must refuse rather than be truncated into a value a check accepts.
      split-value) write_mr_json "$case_dir/mr.json" 'state=opened\nnot-a-field' ;;
    esac

    set +e
    run_pr_merge "$case_dir" task-x1 "$MR_URL" \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    expect_code 1 "$rc" "gitlab-unreadable-$name: fm-pr-merge should refuse"
    assert_grep 'could not read the GitLab merge request state before merging' \
      "$case_dir/stderr" "gitlab-unreadable-$name: refusal did not name the unreadable state"
    [ -z "$(glab_merge_line "$case_dir/glab.log")" ] \
      || fail "gitlab-unreadable-$name: a merge was attempted on an unreadable state"
  done
  pass "fm-pr-merge refuses an unreadable GitLab merge request state rather than merging blind"
}

test_gitlab_invalid_head_refuses() {
  local case_dir rc
  case_dir=$(make_gitlab_case gitlab-invalid-head head=not-a-sha)

  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "gitlab-invalid-head: fm-pr-merge should refuse"
  assert_grep 'could not read the GitLab merge request head commit before merging' \
    "$case_dir/stderr" "gitlab-invalid-head: refusal did not name the unreadable head"
  [ -z "$(glab_merge_line "$case_dir/glab.log")" ] \
    || fail "gitlab-invalid-head: a merge was bound to a head that is not a commit"
  pass "fm-pr-merge refuses a GitLab head commit it cannot validate"
}

test_gitlab_missing_tool_refuses_before_recording() {
  local case_dir rc tool other
  for tool in glab jq; do
    if [ "$tool" = glab ]; then other=jq; else other=glab; fi
    case_dir=$(make_gitlab_case "gitlab-no-$tool")
    mirror_path_without "$case_dir/no$tool" "$tool" "$case_dir/fakebin"
    # One tool absent, the other still answered by this case's own mock, so the
    # refusal names exactly one tool on a host that ships neither.
    PATH="$case_dir/no$tool" command -v "$other" >/dev/null 2>&1 \
      || fail "gitlab-no-$tool: the $tool-free search path lost the $other mock as well"

    set +e
    FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$case_dir/state" \
    FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
    FM_TEST_GLAB_LOG="$case_dir/glab.log" \
    FM_TEST_GLAB_JSON="$case_dir/mr.json" \
    PATH="$case_dir/no$tool" \
      "$PR_MERGE" task-x1 "$MR_URL" > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    expect_code 1 "$rc" "gitlab-no-$tool: fm-pr-merge should refuse"
    assert_grep "error: merging a GitLab merge request requires $tool on PATH" \
      "$case_dir/stderr" "gitlab-no-$tool: refusal did not name the missing tool"
    assert_no_grep "pr=$MR_URL" "$case_dir/state/task-x1.meta" \
      "gitlab-no-$tool: a PR reference was recorded despite the missing tool"
    assert_absent "$case_dir/state/task-x1.check.sh" \
      "gitlab-no-$tool: a merge poll was armed despite the missing tool"
  done
  pass "fm-pr-merge refuses before recording anything when glab or jq is absent"
}

test_gitlab_head_override_args_refuse_before_recording() {
  local case_dir rc
  case_dir=$(make_gitlab_case gitlab-head-override)

  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" -- --sha "$MR_STALE_HEAD" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "gitlab-head-override: fm-pr-merge should refuse a caller head override"
  assert_grep 'extra merge arguments must not override the head commit' "$case_dir/stderr" \
    "gitlab-head-override: refusal did not explain the head override"
  assert_no_grep "pr=$MR_URL" "$case_dir/state/task-x1.meta" \
    "gitlab-head-override: the URL was recorded before rejecting the head override"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "gitlab-head-override: a head override armed a merge poll"
  [ ! -s "$case_dir/glab.log" ] || fail "gitlab-head-override: glab was invoked despite the head override"
  pass "fm-pr-merge refuses a GitLab head override before recording state"
}

test_github_still_forwards_sha_arg() {
  local case_dir
  case_dir=$(make_case github-sha-arg)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" dddddddddddddddddddddddddddddddddddddddd
  : > "$case_dir/gh-axi.log"

  # --sha is rejected only where the head is firstmate's to determine. GitHub's
  # extra args are the caller's business exactly as they were.
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/44 -- --sha abc123 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "github-sha-arg: fm-pr-merge failed"

  grep -qxF 'pr merge 44 --repo example/repo --squash --sha abc123' "$case_dir/gh-axi.log" \
    || fail "github-sha-arg: the GitHub path stopped forwarding a caller --sha"
  pass "fm-pr-merge leaves GitHub extra-arg handling unchanged, including --sha"
}

test_records_pr_and_head_before_merging
test_merge_failure_propagates_after_recording
test_extra_merge_args_forwarded
test_missing_meta_refuses_before_merge
test_malformed_url_refuses_before_merge
test_rejects_unsafe_url_segments_before_recording
test_repo_override_args_refuse_before_recording
test_bundled_repo_override_args_refuse_before_recording
test_explicit_merge_method_not_overridden
test_method_equals_merge_method_not_overridden
test_parses_pr_url_for_gh_axi
test_codebase_url_records_head_and_invokes_bytedcli_merge
test_codebase_merge_method_shims_map_to_bytedcli_flags
test_codebase_squash_commits_keeps_default_merge_method
test_codebase_squash_of_merge_head_is_refused
test_codebase_squash_of_ordinary_head_proceeds
test_codebase_squash_refused_when_head_unreadable
test_rejects_unsafe_codebase_repo_paths
test_merge_poll_is_static
test_codebase_empty_head_does_not_shift_source_ref
test_merge_poll_counts_timeout_killed_lookup
test_merge_poll_wakes_after_repeated_lookup_failures
test_merge_poll_failure_count_resets_on_success
test_merge_poll_reports_a_second_broken_episode
test_github_still_forwards_sha_arg
test_gitlab_url_resolves_and_merges
test_gitlab_host_comes_from_the_url
test_gitlab_imposes_no_merge_method
test_gitlab_extra_args_forwarded
test_gitlab_merge_failure_propagates
test_gitlab_each_condition_refuses_independently
test_gitlab_reports_every_failing_condition
test_gitlab_stale_recorded_head_is_reported
test_gitlab_unreadable_state_refuses
test_gitlab_invalid_head_refuses
test_gitlab_missing_tool_refuses_before_recording
test_gitlab_head_override_args_refuse_before_recording
