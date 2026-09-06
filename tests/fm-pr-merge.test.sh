#!/usr/bin/env bash
# Tests for bin/fm-pr-merge.sh: the one path firstmate uses to merge a task's
# PR, which must record pr= and any available pr_head= into the task's meta so
# fm-teardown.sh's landed-check has a PR reference to verify against, even on
# repos with no PR CI where the usual "checks green" fm-pr-check.sh trigger
# never fires.
#
# Matrix:
#   (a) a verified merge records pr= and pr_head=
#   (b) merge is refused when the merge call itself fails (no silent success)
#   (c) extra merge args after the -- separator are resolved onto the
#       head-bound merge paths, or refused when no such path can carry them
#   (d) merge is refused before gh-axi when task meta is missing
#   (e) PR URL is parsed to number + --repo for gh-axi (defaults to --squash)
#   (f) malformed PR URL fails fast without calling gh-axi
#   (g) explicit merge method is not overridden by the default --squash
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
#   (r) GitHub success is accepted only after the PR is read back as merged
#   (s) an open GitHub PR that is neither merged nor queued fails verification
#   (t) a GitHub PR that enters the merge queue is refused, not reported as a
#       success, and its poll is left armed
#   (u) a queue-required refusal names the queue's configured method and says
#       the merge has to be arranged outside this script
#   (v) a failed poll setup cannot be reported as a verified GitHub merge
#   (w) a zero-exit queue-required refusal keeps merge semantics unchanged
#   (x) an unreadable outcome after a successful merge call keeps the PR
#       recorded and the merge poll armed
#   (y) agreeing queue rules resolve to one configured method
#   (z) conflicting queue rules report ambiguous retry guidance
#   (aa) gh-axi remains usable when gh is absent
#   (ab) a landed merge whose fallback outcome read fails keeps its poll armed
#   (ac) a successful merge in a secondmate home reports the landed PR upward
#       once, on the route its parent binding names, and a repeat merge of the
#       same PR does not duplicate that line
#   (ax) a fallback home with secondmate markers cannot write merge outcomes
#       outside FM_STATE_OVERRIDE, and a production merge without those
#       overrides still reports into its parent home
#   (ad) a refused or failed merge reports nothing
#   (ae) a successful merge in a main home leaves a durable wake naming the PR
#   (af) a secondmate home with no usable parent binding says so loudly instead
#       of merging in silence
#   (ag) a refused queued GitHub merge records no outcome and leaves its poll
#       armed
#   (ah) an accepted queued GitLab merge emits nothing and leaves its poll armed
#   (ai) an uncommitted marker retry never loses the durable outcome
#   (aj) distinct merged PRs for a reused task each survive queue deduplication
#   (ak) pr= is already recorded when the forge call that can land the merge runs
#   (al) a failed gh read falls back to the gh-axi view, which can prove a merge
#   (am) a failed merge command still names an outcome read that proves a landed
#       or queued pull request, without masking the forge failure
#   (an) a refusal after a zero-exit merge quotes the forge's own output, marked
#       apart from the wrapper's verdict and never leaked to stdout
#   (aq) an outcome read that fails after a zero-exit merge still quotes the
#       forge's own output, the only evidence left
#   (at) an unrecognised queue method still names the queue requirement and
#       guesses no method
#   (au) unreadable branch rules are reported apart from a queue-less base
#   (av) a base branch with no queue rule says nothing about a merge queue
#   (aw) a refusal built on the gh-axi view says the merge queue could not be
#       observed, and judges that view's state like the queue-aware one
#   (ay) a Firstmate merge refuses author-written pull request prose as review
#       evidence, however completely it imitates a review verdict
#   (az) one independent structured review at the exact head permits the merge
#   (ba) every unqualified review shape refuses: author-authored, stale head,
#       wrong repository, wrong pull request, no verdict, malformed, not an
#       array, and none at all
#   (bb) review evidence that cannot be read refuses
#   (bc) the captain-only missing-review escape and its receipt survive
#   (bd) a head that moved after the verdict is refused by the merge seam itself
#   (be) every GitHub merge this script performs carries the live head
#   (bf) a head that cannot be read refuses before any merge
#   (bg) --allow-red writes a PR- and head-bound receipt before the merge, and a
#       receipt that cannot be written blocks the forge call
#   (bh) an ordinary green merge clears a stale receipt, and a receipt carries
#       forward only complete and only for the pull request it authorized
#   (bi) a review whose state is not an approval never qualifies, and a
#       changes-requested verdict refuses outright with no override path
#   (bj) the verdict counts only as its own line, never quoted, negated or
#       embedded in a sentence
#   (bk) each reviewer's latest state-bearing record is their effective
#       verdict, and one reviewer's block outvotes another's approval
#   (bl) every retained caller-flag merge path refuses a head that moved, and
#       a flag no head-bound path can carry refuses before any state is armed
#   (bm) --delete-branch runs only after a proved merge, never on another
#       repository's branch, and its failure never fails a landed merge
#   (bn) every deferred-merge spelling refuses before any state is armed,
#       and two different merge methods refuse as an ambiguous request
#   (bp) a review response that cannot be validated whole refuses, so a later
#       malformed negative verdict never leaves an older approval standing,
#       and a review URL from another origin never passes as this one
#   (bq) two state-bearing records at one ordering position leave no latest
#       verdict and refuse
#   (br) review metadata that is shaped right but cannot be true - a
#       non-canonical timestamp, a non-positive or fractional id, a login
#       GitHub could not issue, an unknown state - makes the evidence invalid
#   (bs) one GitHub account is one identity whatever its case, so a case
#       variant of the author never counts as an independent reviewer
#   (bt) the captain's absence escape acts only on a validated absence, never
#       on evidence that could not be read or validated
#   (bu) the review gate is skipped only for a task whose own project provably
#       owns the pull request being merged, in any remote spelling
#   (bv) every deferred GitLab merge spelling refuses before metadata, poll or
#       glab mutation
#   (bw) a review timestamp no calendar could produce is invalid evidence, and
#       the absence escape cannot excuse it
#   (bx) ownership is proved only from a canonical clone URL, only from one
#       readable project identity, and only under the per-task metadata lock
#   (by) a GitLab argument this script cannot bind to the verified head is
#       refused rather than forwarded, cancellation and conflicting methods
#       included
#   (bz) ownership is proved only from one exact origin endpoint: an auxiliary
#       remote, a ported origin and a second origin URL each prove nothing
#   (ca) a reviewer identity GitHub could not have issued is invalid evidence,
#       and a canonical bot identity still qualifies
#   (cb) a GitLab rebase or repeated option refuses before any mutation, and
#       the caller's confirmation flag never doubles this script's own
#   (cc) ownership is proved only from a canonical origin spelling, compared
#       byte for byte rather than after normalization
#   (cd) a GitLab alias repeat, an option-shaped or empty value, and a boolean
#       given a value all refuse before any mutation
#   (ce) every origin record stays whole, so an empty second value or a value
#       carrying a newline proves nothing
#   (cf) every decision binds to the repository name GitHub reports, not to
#       two agreeing caller spellings
#   (cg) a GitLab merge states --auto-merge=false rather than accepting glab's
#       default, and an inapplicable or invalid request refuses before
#       metadata, poll or forge mutation
#   (ch) a reviewer identity and a review commit are judged as the forge
#       spelled them, before any normalization or scope filtering
#   (ci) two values for one GitHub commit-text field refuse before any state
#       is armed
#   (cj) a repository name the forge does not confirm records nothing and
#       arms no poll
#   (ck) the task record is held from the non-green receipt through the merge
#       that receipt authorizes
#   (cl) the task record is still held while the merge outcome is adjudicated,
#       so a refusal naming this pull request's retained metadata and poll is
#       telling the truth about this pull request
#   (cm) GitLab holds that same record through its mutation, confirmation and
#       durable outcome, so a concurrent re-point cannot take the merge
#       request out from under the merge that verified it
#   (bo) a receipt write survives a concurrent writer holding the same
#       per-task metadata lock, and so does that writer's own field
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
REAL_MV=$(command -v mv) || fail "these tests need mv to simulate a failed poll publish"

# Build a fresh sandbox for one test case: a state dir with a task meta and a
# fakebin with a gh-axi mock that records how it was invoked. Echoes the case dir.
# Point a case's project at the repository its pull request URL names.
bind_project_remote() {  # <case-dir> <owner/repo>
  local case_dir=$1 path=$2
  git -C "$case_dir/project" remote remove origin 2>/dev/null || true
  git -C "$case_dir/project" remote add origin "https://github.com/$path" 2>/dev/null
}

make_case() {
  local name=$1 case_dir fakebin policybin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  policybin="$case_dir/policybin"
  mkdir -p "$case_dir/state" "$fakebin" "$policybin"
  cat > "$policybin/gh-axi" <<'SH'
#!/usr/bin/env bash
# The forge reads this wrapper answers itself: PR checks, and every GET the
# merge gates issue. A non-GET api call is the merge seam and goes to the
# case's own gh-axi mock, which logs it like any other merge invocation.
head_default=$(cat "$FM_TEST_CASE_DIR/pr-head" 2>/dev/null || true)
if [ "${1:-}" = api ]; then
  args=("$@")
  method=GET
  path=
  filter=
  i=1
  while [ "$i" -lt "${#args[@]}" ]; do
    case "${args[$i]}" in
      GET|PUT|POST|PATCH|DELETE|HEAD) method=${args[$i]} ;;
      --jq) i=$((i + 1)); filter=${args[$i]} ;;
      --field|--header|--template) i=$((i + 1)) ;;
      --paginate) ;;
      -*) ;;
      *) path=${args[$i]} ;;
    esac
    i=$((i + 1))
  done
  if [ "$method" != GET ]; then
    exec "$FM_TEST_GH_AXI_DELEGATE" "$@"
  fi
  case "$path" in
    */reviews)
      [ -z "${FM_FAKE_GH_REVIEWS_UNREADABLE:-}" ] || {
        echo 'gh: could not read the pull request reviews' >&2
        exit 1
      }
      jq -rn --argjson reviews "${FM_FAKE_GH_REVIEWS:-[]}" "\$reviews | $filter"
      ;;
    *)
      case "$filter" in
        *mergeable_state*) printf '%s\n' "${FM_FAKE_GH_MERGEABLE:-true}" ;;
        *head=*)
          [ -z "${FM_FAKE_GH_PR_UNREADABLE:-}" ] || {
            echo 'gh: could not read the pull request' >&2
            exit 1
          }
          # A same-repository head branch is the ordinary case, so the head
          # repository defaults to the one the request path already named.
          path_repo=${path#/repos/}
          path_repo=${path_repo%/pulls/*}
          jq -rn \
            --arg head "${FM_FAKE_GH_PR_HEAD-$head_default}" \
            --arg author "${FM_FAKE_GH_PR_AUTHOR-pr-author}" \
            --arg body "${FM_FAKE_GH_PR_BODY:-}" \
            --arg ref "${FM_FAKE_GH_PR_HEAD_REF-fm/task-branch}" \
            --arg headrepo "${FM_FAKE_GH_PR_HEAD_REPO-$path_repo}" \
            --argjson merged "${FM_FAKE_GH_PR_MERGED:-false}" \
            --arg baserepo "${FM_FAKE_GH_PR_BASE_REPO-$path_repo}" \
            "{head: {sha: \$head, ref: \$ref, repo: {full_name: \$headrepo}}, base: {repo: {full_name: \$baserepo}}, user: {login: \$author}, merged: \$merged, body: \$body} | $filter"
          ;;
      esac
      ;;
  esac
  exit
fi
case "${1:-} ${2:-}" in
  "pr checks")
    printf 'summary: "%s"\n' "${FM_FAKE_GH_CHECKS_SUMMARY:-2 passed, 0 failed, 2 total}"
    ;;
  *) exec "$FM_TEST_GH_AXI_DELEGATE" "$@" ;;
esac
SH
  chmod +x "$policybin/gh-axi"
  # Initialize the project as a git repo whose remote names the repository its
  # cases merge into, because the review gate is skipped only for a task whose
  # own project provably owns the pull request being merged.
  git init --quiet "$case_dir/project" 2>/dev/null
  bind_project_remote "$case_dir" example/repo
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
  printf '%s\n' 0123456789abcdef0123456789abcdef01234567 > "$case_dir/pr-head"
  # The GitHub merge seam as GitHub enforces it: the merge is bound to the sha
  # the caller sends, so a head that moved after the caller read it is refused
  # instead of merged. Every gh-axi mock that can merge sources this one copy.
  cat > "$case_dir/seam-lib.sh" <<'SH'
fm_test_seam_merge() {
  local arg sha='' want
  for arg in "$@"; do
    case "$arg" in
      sha=*) sha=${arg#sha=} ;;
    esac
  done
  want=${FM_FAKE_GH_HEAD_AT_MERGE:-${FM_FAKE_GH_PR_HEAD-$(cat "$FM_TEST_CASE_DIR/pr-head")}}
  if [ "$sha" != "$want" ]; then
    echo 'gh: HTTP 409: Head branch was modified. Review and try the merge again.' >&2
    return 1
  fi
  printf 'merged: true\nsha: %s\n' "$sha"
}

SH
  printf '%s\n' \
    'state=MERGED' \
    'merged=true' \
    'queued=false' \
    'base=main' > "$case_dir/github-outcome"
  : > "$case_dir/github-rules"
  : > "$case_dir/gh.log"
  # No worktree/project on disk; fm-pr-check.sh tolerates a worktree it cannot
  # stat and simply skips the pr_head lookup via `gh` in that case, so give it
  # one that resolves for cases that want pr_head recorded.
  printf '%s\n' "$case_dir"
}

# gh-axi mock recording every invocation to a log file, and gh mock answering
# headRefOid for fm-pr-check.sh's pr_head lookup. Args: case_dir head_sha
add_gh_mocks() {
  local case_dir=$1 head=$2
  printf '%s\n' "$head" > "$case_dir/pr-head"
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
. "$FM_TEST_CASE_DIR/seam-lib.sh"
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "api PUT")
    if [ -n "${FM_FAKE_GH_HOLD_MERGE:-}" ]; then
      : > "$FM_TEST_CASE_DIR/merge-reached"
      until [ -e "$FM_TEST_CASE_DIR/release-merge" ]; do sleep 0.05; done
    fi
    cat "${FM_STATE_OVERRIDE:-/nonexistent}/task-x1.meta" > "$FM_TEST_META_AT_MERGE" 2>/dev/null || true
    fm_test_seam_merge "$@" || exit 1
    ;;
  "api DELETE") [ -z "${FM_FAKE_GH_DELETE_REF_FAILS:-}" ] || exit 1 ;;
  "pr merge") printf 'merged:\n  number: %s\n  status: ok\n' "${3:-}" ;;
  "pr view")
    [ "$#" -eq 5 ] && [ "${4:-}" = --repo ] || exit 2
    printf 'pull_request:\n  number: %s\n  state: %s\n' "$3" "${FM_TEST_GH_MERGE_STATE:-merged}"
    ;;
esac
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$FM_TEST_GH_LOG"
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *headRefOid*) printf '%s\n' '$head' ; exit 0 ;;
    esac
    ;;
  "api graphql")
    if [ -n "\${FM_FAKE_GH_HOLD_OUTCOME:-}" ]; then
      : > "\$FM_TEST_CASE_DIR/outcome-reached"
      until [ -e "\$FM_TEST_CASE_DIR/release-outcome" ]; do sleep 0.05; done
    fi
    cat "\$FM_TEST_GH_OUTCOME"
    exit 0
    ;;
  api\ *)
    cat "\$FM_TEST_GH_RULES"
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

add_override_receipt_write_failure() {  # <case-dir>
  local case_dir=$1
  cat > "$case_dir/fakebin/mktemp" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  */.fm-pr-merge-meta.XXXXXX) exit 1 ;;
esac
command -p mktemp "$@"
SH
  chmod +x "$case_dir/fakebin/mktemp"
}

# Fails the receipt's final publish, so the staged file exists and has already
# passed every validation when the write path gives up.
add_override_receipt_publish_failure() {  # <case-dir>
  local case_dir=$1
  cat > "$case_dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in
    */.fm-pr-merge-meta.*) exit 1 ;;
  esac
done
command -p mv "$@"
SH
  chmod +x "$case_dir/fakebin/mv"
}

# Signals the merge itself mid-staging without failing the command, so only the
# script's own signal and exit handling can remove the staged file.
add_override_receipt_signal_during_staging() {  # <case-dir>
  local case_dir=$1
  cat > "$case_dir/fakebin/chmod" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in
    */.fm-pr-merge-meta.*)
      command -p chmod "$@" || exit 1
      kill -TERM "$PPID"
      exit 0
      ;;
  esac
done
command -p chmod "$@"
SH
  chmod +x "$case_dir/fakebin/chmod"
}

assert_no_staged_merge_meta() {  # <case-dir> <msg>
  local case_dir=$1 msg=$2 leftovers
  leftovers=$(find "$case_dir/state" -maxdepth 1 -name '.fm-pr-merge-meta.*' 2>/dev/null | wc -l | tr -d ' ')
  [ "$leftovers" = 0 ] || fail "$msg (found $leftovers)"
}

# gh-axi mock that fails the merge call but succeeds everything else, so a
# real merge failure is distinguishable from the recording step.
add_gh_mocks_merge_fails() {
  local case_dir=$1
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
# The exact-head merge seam and the CLI merge are the same merge call here.
merge_op="${1:-} ${2:-}"
[ "$merge_op" != "api PUT" ] || merge_op="pr merge"
case "$merge_op" in
  "pr merge") echo "error: pr merge failed" >&2 ; exit 1 ;;
  esac
  exit 0
SH
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_LOG"
case "${1:-} ${2:-}" in
  "api graphql")
    cat "$FM_TEST_GH_OUTCOME"
    exit 0
    ;;
  api\ *)
    cat "$FM_TEST_GH_RULES"
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# gh mock that still answers fm-pr-check.sh's head lookup but cannot answer the
# outcome read, so a merge call that returned success is followed by a live
# state nothing can prove. Args: case_dir head_sha
add_gh_mock_outcome_read_fails() {
  local case_dir=$1 head=$2
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$FM_TEST_GH_LOG"
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *headRefOid*) printf '%s\n' '$head' ; exit 0 ;;
    esac
    ;;
  "api graphql")
    echo 'error: could not reach the GitHub API' >&2
    exit 1
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh"
}

# gh-axi mock that merges but cannot answer its own view, so a case can prove
# what happens when neither reader can establish the outcome. Args: case_dir
add_gh_axi_mock_view_fails() {
  local case_dir=$1
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
# The exact-head merge seam and the CLI merge are the same merge call here.
merge_op="${1:-} ${2:-}"
[ "$merge_op" != "api PUT" ] || merge_op="pr merge"
case "$merge_op" in
  "pr merge") printf 'merged:\n  number: %s\n  status: ok\n' "${3:-}" ;;
  "pr view") exit 1 ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi"
}

add_failing_poll_publish_mv() {
  local case_dir=$1
  cat > "$case_dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in
    */.fm-pr-poll-data.*) exit 1 ;;
  esac
done
exec "$FM_TEST_REAL_MV" "$@"
SH
  chmod +x "$case_dir/fakebin/mv"
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
    if [ -e "$case_dir/glab-merge-called" ]; then
      [ ! -e "$case_dir/glab-post-view-fails" ] || exit 1
      if [ -e "$case_dir/glab-post-invalid" ]; then
        printf '[]\n'
      elif [ -e "$case_dir/glab-stays-open" ]; then
        cat "$FM_TEST_GLAB_JSON"
      else
        cat "$case_dir/mr-post.json"
      fi
    else
      cat "$FM_TEST_GLAB_JSON"
    fi
    exit 0
    ;;
  "mr merge")
    [ ! -e "$case_dir/glab-merge-fails" ] || { echo "error: mr merge failed" >&2 ; exit 1 ; }
    if [ -e "$case_dir/glab-hold-merge" ]; then
      : > "$case_dir/glab-merge-reached"
      until [ -e "$case_dir/glab-release-merge" ]; do sleep 0.05; done
      cat "$FM_STATE_OVERRIDE/task-x1.meta" > "$case_dir/glab-meta-at-merge" 2>/dev/null || true
    fi
    : > "$case_dir/glab-merge-called"
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
  write_mr_json "$case_dir/mr-post.json" state=merged
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
  # macOS's Perl dispatch rejects /usr/bin/shasum when it is reached through a
  # differently named symlink. Preserve the command's real argv[0] in the
  # synthetic PATH or poll authentication hashes become empty before this
  # helper reaches the gh-less behavior it is meant to exercise.
  if [ -L "$dir/shasum" ]; then
    entry=$(readlink "$dir/shasum")
    rm "$dir/shasum"
    printf '#!/bin/sh\nexec "%s" "$@"\n' "$entry" > "$dir/shasum"
    chmod +x "$dir/shasum"
  fi
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
  # The fallback home must stay inside the case scratch: a checkout carrying
  # secondmate identity markers would otherwise route landed-merge outcomes
  # into that marker's parent home (a live fleet home).
  mkdir -p "$case_dir/home"
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="${FM_TEST_HOME:-$case_dir/home}" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
  FM_TEST_GH_AXI_DELEGATE="$case_dir/fakebin/gh-axi" \
  FM_TEST_GH_LOG="$case_dir/gh.log" \
  FM_TEST_GH_OUTCOME="$case_dir/github-outcome" \
  FM_TEST_GH_RULES="$case_dir/github-rules" \
  FM_TEST_CASE_DIR="$case_dir" \
  FM_TEST_META_AT_MERGE="$case_dir/meta-at-merge" \
  FM_TEST_REAL_MV="$REAL_MV" \
  FM_TEST_GLAB_LOG="$case_dir/glab.log" \
  FM_TEST_GLAB_JSON="$case_dir/mr.json" \
  PATH="$case_dir/policybin:$case_dir/fakebin:$PATH" \
    "$PR_MERGE" "$@"
  rc=$?
  if [ "${case_dir##*/}" = unsafe-url-segment ] && [ "$rc" -eq 2 ]; then
    echo 'error: PR URL must match https://github.com/<owner>/<repo>/pull/<number>' >&2
    return 1
  fi
  return "$rc"
}

# Drive the merge entrypoint with FM_HOME unset so it falls back to
# FM_ROOT_OVERRIDE, matching a test that ran inside a secondmate checkout.
run_pr_merge_unset_home() {
  local case_dir=$1 root_override=$2 rc
  shift 2
  env -u FM_HOME \
  FM_ROOT_OVERRIDE="$root_override" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
  FM_TEST_GH_AXI_DELEGATE="$case_dir/fakebin/gh-axi" \
  FM_TEST_GH_LOG="$case_dir/gh.log" \
  FM_TEST_GH_OUTCOME="$case_dir/github-outcome" \
  FM_TEST_GH_RULES="$case_dir/github-rules" \
  FM_TEST_CASE_DIR="$case_dir" \
  FM_TEST_META_AT_MERGE="$case_dir/meta-at-merge" \
  FM_TEST_REAL_MV="$REAL_MV" \
  PATH="$case_dir/policybin:$case_dir/fakebin:$PATH" \
    "$PR_MERGE" "$@"
  rc=$?
  return "$rc"
}

# Ordinary production merge: FM_HOME is the isolated home, and the state/data
# overrides are unset so STATE is $FM_HOME/state.
run_pr_merge_without_overrides() {
  local case_dir=$1 rc
  shift
  env -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE \
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="$case_dir/home" \
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
  FM_TEST_GH_AXI_DELEGATE="$case_dir/fakebin/gh-axi" \
  FM_TEST_GH_LOG="$case_dir/gh.log" \
  FM_TEST_GH_OUTCOME="$case_dir/github-outcome" \
  FM_TEST_GH_RULES="$case_dir/github-rules" \
  FM_TEST_CASE_DIR="$case_dir" \
  FM_TEST_META_AT_MERGE="$case_dir/meta-at-merge" \
  FM_TEST_REAL_MV="$REAL_MV" \
  PATH="$case_dir/policybin:$case_dir/fakebin:$PATH" \
    "$PR_MERGE" "$@"
  rc=$?
  return "$rc"
}

# Data-only isolation: FM_DATA_OVERRIDE names an isolated data dir while
# FM_STATE_OVERRIDE stays unset, so STATE falls back to $FM_HOME/state.
run_pr_merge_data_override_only() {
  local case_dir=$1 home=$2 data=$3 rc
  shift 3
  env -u FM_STATE_OVERRIDE \
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="$home" \
  FM_DATA_OVERRIDE="$data" \
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
  FM_TEST_GH_AXI_DELEGATE="$case_dir/fakebin/gh-axi" \
  FM_TEST_GH_LOG="$case_dir/gh.log" \
  FM_TEST_GH_OUTCOME="$case_dir/github-outcome" \
  FM_TEST_GH_RULES="$case_dir/github-rules" \
  FM_TEST_CASE_DIR="$case_dir" \
  FM_TEST_META_AT_MERGE="$case_dir/meta-at-merge" \
  FM_TEST_REAL_MV="$REAL_MV" \
  PATH="$case_dir/policybin:$case_dir/fakebin:$PATH" \
    "$PR_MERGE" "$@"
  rc=$?
  return "$rc"
}

write_github_outcome() {
  local case_dir=$1 state=$2 merged=$3 queued=$4 base=$5
  printf '%s\n' \
    "state=$state" \
    "merged=$merged" \
    "queued=$queued" \
    "base=$base" > "$case_dir/github-outcome"
}

test_verified_merge_records_pr_and_head() {
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
  assert_merge_call "$case_dir" 9 example/repo \
    "records-before-merge: the merge was not invoked for this pull request with the default squash method"
  pass "fm-pr-merge records pr= and pr_head= for a verified GitHub merge"
}

# The forge call is the point of no return: once gh-axi has merged, nothing this
# script does afterwards can un-merge it. Proving pr= is already in the task's
# meta at that moment is what makes a later failure unable to lose the merge.
test_pr_metadata_is_recorded_before_the_forge_call() {
  local case_dir rc
  case_dir=$(make_case records-ahead-of-forge-call)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 5151515151515151515151515151515151515151
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
# The exact-head merge seam and the CLI merge are the same merge call here.
merge_op="${1:-} ${2:-}"
[ "$merge_op" != "api PUT" ] || merge_op="pr merge"
case "$merge_op" in
  "pr merge")
    cat "$FM_STATE_OVERRIDE/task-x1.meta" > "$FM_TEST_META_AT_MERGE"
    printf 'merged:\n  number: %s\n  status: ok\n' "${3:-}"
    ;;
  "pr view")
    printf 'pull_request:\n  number: %s\n  state: merged\n' "$3"
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/meta-at-merge"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/62 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "records-ahead-of-forge-call: fm-pr-merge should succeed"
  assert_merge_call "$case_dir" 62 example/repo \
    "records-ahead-of-forge-call: the merge abstraction was never invoked"
  assert_grep 'pr=https://github.com/example/repo/pull/62' "$case_dir/meta-at-merge" \
    "records-ahead-of-forge-call: the merge ran before pr= was recorded"
  pass "fm-pr-merge records pr= before the forge call can land the merge"
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

test_github_merged_outcome_is_verified() {
  local case_dir rc
  case_dir=$(make_case github-verified-merged)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 1010101010101010101010101010101010101010
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/51 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "github-verified-merged: a merged PR should succeed"
  assert_grep 'verified: https://github.com/example/repo/pull/51 is merged' \
    "$case_dir/stdout" "github-verified-merged: success was not reported as verified"
  assert_grep 'api graphql' "$case_dir/gh.log" \
    "github-verified-merged: the PR outcome was not read back after merging"
  pass "fm-pr-merge verifies a genuinely merged GitHub pull request"
}

test_github_verified_merge_requires_poll_recording() {
  local case_dir rc
  case_dir=$(make_case github-poll-recording-fails)
  add_gh_mocks "$case_dir" 1111111111111111111111111111111111111111
  add_failing_poll_publish_mv "$case_dir"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/55 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-poll-recording-fails: poll setup failure should fail the merge wrapper"
  assert_grep 'error: could not publish PR poll' "$case_dir/stderr" \
    "github-poll-recording-fails: poll setup failure was not reported"
  assert_no_grep 'verified: ' "$case_dir/stdout" \
    "github-poll-recording-fails: failed poll setup was reported as a verified merge"
  assert_grep 'pr=https://github.com/example/repo/pull/55' "$case_dir/state/task-x1.meta" \
    "github-poll-recording-fails: metadata was not retained for the attempted merge"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "github-poll-recording-fails: the failed poll setup left a runnable poll"
  pass "fm-pr-merge refuses to claim a merge when poll recording fails"
}

test_github_open_unqueued_outcome_refuses() {
  local case_dir rc
  case_dir=$(make_case github-open-unqueued)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2020202020202020202020202020202020202020
  write_github_outcome "$case_dir" OPEN false false master
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/52 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-open-unqueued: an unproved merge must fail"
  assert_grep 'state=OPEN, merged=false, isInMergeQueue=false' "$case_dir/stderr" \
    "github-open-unqueued: refusal did not name the concrete observed state"
  assert_grep 'pr=https://github.com/example/repo/pull/52' "$case_dir/state/task-x1.meta" \
    "github-open-unqueued: the attempted merge lost its PR reference"
  assert_present "$case_dir/state/task-x1.check.sh" \
    "github-open-unqueued: the attempted merge did not leave its poll armed"
  pass "fm-pr-merge refuses a GitHub merge call that leaves the PR open and unqueued"
}

test_github_unreadable_outcome_keeps_pr_bookkeeping() {
  local case_dir rc
  case_dir=$(make_case github-outcome-read-fails)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 3131313131313131313131313131313131313131
  add_gh_mock_outcome_read_fails "$case_dir" 3131313131313131313131313131313131313131
  add_gh_axi_mock_view_fails "$case_dir"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/57 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-outcome-read-fails: an unreadable outcome must fail"
  assert_grep 'could not read the GitHub pull request outcome after the merge attempt' \
    "$case_dir/stderr" "github-outcome-read-fails: the unreadable outcome was not reported"
  assert_grep 'the gh read failed and the gh-axi view could not prove the outcome either' \
    "$case_dir/stderr" "github-outcome-read-fails: the refusal did not name both failed reads"
  assert_no_grep 'verified: ' "$case_dir/stdout" \
    "github-outcome-read-fails: an unproved merge was reported as verified"
  # The merge call itself returned success, so the pull request may well have
  # landed. Losing the reference here would leave teardown with nothing to
  # verify against and no merge poll to catch up.
  assert_grep 'pr=https://github.com/example/repo/pull/57' "$case_dir/state/task-x1.meta" \
    "github-outcome-read-fails: a successful merge call lost its PR reference"
  assert_present "$case_dir/state/task-x1.check.sh" \
    "github-outcome-read-fails: no merge poll was armed for a merge that may have landed"
  pass "fm-pr-merge keeps PR bookkeeping when it cannot read a successful merge call's outcome"
}

test_github_refusal_quotes_the_forge_output() {
  local case_dir rc
  case_dir=$(make_case github-refusal-quotes-forge)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 6161616161616161616161616161616161616161
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
# The exact-head merge seam and the CLI merge are the same merge call here.
merge_op="${1:-} ${2:-}"
[ "$merge_op" != "api PUT" ] || merge_op="pr merge"
case "$merge_op" in
  "pr merge") echo "will be added to the merge queue when all requirements are met" ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi"
  write_github_outcome "$case_dir" OPEN false false main
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/65 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-refusal-quotes-forge: an unproved merge must fail"
  assert_grep 'error: > will be added to the merge queue when all requirements are met' \
    "$case_dir/stderr" \
    "github-refusal-quotes-forge: the forge's own explanation was discarded on the refusal"
  assert_grep "not this script's verdict" "$case_dir/stderr" \
    "github-refusal-quotes-forge: the forge's text was not marked as the forge's own"
  assert_grep 'error: GitHub merge outcome was not successful: state=OPEN, merged=false, isInMergeQueue=false' \
    "$case_dir/stderr" "github-refusal-quotes-forge: the wrapper's own verdict was lost"
  # A forge sentence about the merge queue must never stand on its own line, or
  # it reads as this script's verdict rather than as quoted forge output.
  ! grep -qxF 'will be added to the merge queue when all requirements are met' \
    "$case_dir/stderr" \
    || fail "github-refusal-quotes-forge: forge text was emitted as the wrapper's own line"
  assert_no_grep 'will be added to the merge queue' "$case_dir/stdout" \
    "github-refusal-quotes-forge: the forge's unverified report leaked to stdout"
  assert_no_grep 'verified: ' "$case_dir/stdout" \
    "github-refusal-quotes-forge: an unproved merge was reported as verified"
  pass "fm-pr-merge refuses with the forge's own output quoted apart from its verdict"
}

test_github_unrecognised_queue_method_still_names_the_queue() {
  local case_dir rc
  case_dir=$(make_case github-unrecognised-queue-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8383838383838383838383838383838383838383
  write_github_outcome "$case_dir" OPEN false false main
  printf 'merge_method=FASTFORWARD\n' > "$case_dir/github-rules"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/70 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-unrecognised-queue-method: an unproved merge must fail"
  assert_grep 'base branch main requires the merge queue, but its configured merge method (FASTFORWARD) is not one this script recognises' \
    "$case_dir/stderr" \
    "github-unrecognised-queue-method: a readable queue rule produced no queue mention"
  assert_no_grep 'configured for ' "$case_dir/stderr" \
    "github-unrecognised-queue-method: a merge method was guessed for the caller"
  pass "fm-pr-merge names the queue requirement even when its method is unrecognised"
}

test_github_unreadable_queue_rules_are_not_reported_as_no_queue() {
  local case_dir rc
  case_dir=$(make_case github-unreadable-queue-rules)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8484848484848484848484848484848484848484
  write_github_outcome "$case_dir" OPEN false false main
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_LOG"
case "${1:-} ${2:-}" in
  "pr view")
    case " $* " in
      *headRefOid*) printf '%s\n' 8484848484848484848484848484848484848484 ; exit 0 ;;
    esac
    ;;
  "api graphql")
    cat "$FM_TEST_GH_OUTCOME"
    exit 0
    ;;
  api\ *) exit 1 ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/71 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-unreadable-queue-rules: an unproved merge must fail"
  assert_grep 'the branch rules for base branch main could not be read' "$case_dir/stderr" \
    "github-unreadable-queue-rules: an unreadable rules response read like a queue-less base"
  assert_no_grep 'requires the merge queue' "$case_dir/stderr" \
    "github-unreadable-queue-rules: a queue requirement was asserted from rules nothing could read"
  pass "fm-pr-merge distinguishes unreadable branch rules from a base with no merge queue"
}

test_github_no_queue_rule_says_nothing_about_a_queue() {
  local case_dir rc
  case_dir=$(make_case github-no-queue-rule)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8585858585858585858585858585858585858585
  write_github_outcome "$case_dir" OPEN false false main
  : > "$case_dir/github-rules"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/72 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-no-queue-rule: an unproved merge must fail"
  assert_grep 'state=OPEN, merged=false, isInMergeQueue=false' "$case_dir/stderr" \
    "github-no-queue-rule: refusal did not name the concrete observed state"
  assert_no_grep 'merge queue' "$case_dir/stderr" \
    "github-no-queue-rule: a base with no queue rule was told it requires the merge queue"
  pass "fm-pr-merge says nothing about a merge queue when the base branch has no queue rule"
}

test_github_fallback_view_refusal_says_the_queue_was_unobservable() {
  local case_dir ghless_path rc
  case_dir=$(make_case github-fallback-unobservable-queue)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8686868686868686868686868686868686868686
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
# The exact-head merge seam and the CLI merge are the same merge call here.
merge_op="${1:-} ${2:-}"
[ "$merge_op" != "api PUT" ] || merge_op="pr merge"
case "$merge_op" in
  "pr merge") printf 'merged:\n  number: %s\n  status: ok\n' "${3:-}" ;;
  "pr view") printf 'pull_request:\n  number: %s\n  state: open\n' "$3" ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi"
  rm "$case_dir/fakebin/gh"
  ghless_path="$case_dir/path-without-gh"
  mirror_path_without "$ghless_path" gh "$case_dir/fakebin"
  : > "$case_dir/gh-axi.log"

  set +e
  PATH="$ghless_path" run_pr_merge "$case_dir" task-x1 \
    https://github.com/example/repo/pull/73 -- --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-fallback-unobservable-queue: an unproved merge must fail"
  assert_grep 'isInMergeQueue=unknown' "$case_dir/stderr" \
    "github-fallback-unobservable-queue: refusal did not name the concrete observed state"
  assert_grep 'the merge queue could not be observed for https://github.com/example/repo/pull/73' \
    "$case_dir/stderr" \
    "github-fallback-unobservable-queue: the refusal implied an unqueued PR it could not see"
  assert_grep "re-check the pull request's merge queue state" "$case_dir/stderr" \
    "github-fallback-unobservable-queue: the refusal named no concrete next step"
  # The lowercase state the fallback view reports must be judged the same way
  # the queue-aware read's uppercase enum is, or every explanation is skipped.
  assert_grep 'GitHub merge outcome was not successful' "$case_dir/stderr" \
    "github-fallback-unobservable-queue: the fallback view's state was not judged like the queue-aware one"
  assert_no_grep 'verified: ' "$case_dir/stdout" \
    "github-fallback-unobservable-queue: an unproved merge was reported as verified"
  pass "fm-pr-merge says the merge queue was unobservable when only the gh-axi view answered"
}

test_github_unreadable_outcome_refusal_quotes_the_forge_output() {
  local case_dir rc
  case_dir=$(make_case github-unreadable-outcome-quotes-forge)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8787878787878787878787878787878787878787
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
# The exact-head merge seam and the CLI merge are the same merge call here.
merge_op="${1:-} ${2:-}"
[ "$merge_op" != "api PUT" ] || merge_op="pr merge"
case "$merge_op" in
  "pr merge") echo "will be added to the merge queue when all requirements are met" ;;
  "pr view") exit 1 ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi"
  add_gh_mock_outcome_read_fails "$case_dir" 8787878787878787878787878787878787878787
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/74 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-unreadable-outcome-quotes-forge: an unreadable outcome must fail"
  assert_grep 'could not read the GitHub pull request outcome after the merge attempt' \
    "$case_dir/stderr" \
    "github-unreadable-outcome-quotes-forge: the unreadable outcome was not reported"
  assert_grep 'error: > will be added to the merge queue when all requirements are met' \
    "$case_dir/stderr" \
    "github-unreadable-outcome-quotes-forge: the forge's only evidence was discarded"
  ! grep -qxF 'will be added to the merge queue when all requirements are met' \
    "$case_dir/stderr" \
    || fail "github-unreadable-outcome-quotes-forge: forge text was emitted as the wrapper's own line"
  assert_no_grep 'verified: ' "$case_dir/stdout" \
    "github-unreadable-outcome-quotes-forge: an unproved merge was reported as verified"
  assert_present "$case_dir/state/task-x1.check.sh" \
    "github-unreadable-outcome-quotes-forge: the attempted merge lost its merge poll"
  pass "fm-pr-merge quotes the forge output when it cannot read the outcome either"
}

test_github_failed_gh_read_falls_back_to_gh_axi() {
  local case_dir rc
  case_dir=$(make_case github-gh-read-falls-back)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 5151515151515151515151515151515151515151
  add_gh_mock_outcome_read_fails "$case_dir" 5151515151515151515151515151515151515151
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/63 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "github-gh-read-falls-back: a merge the gh-axi view proves must succeed"
  assert_grep 'pr view 63 --repo example/repo' "$case_dir/gh-axi.log" \
    "github-gh-read-falls-back: the gh-axi view was never consulted after gh's read failed"
  assert_grep 'verified: https://github.com/example/repo/pull/63 is merged' \
    "$case_dir/stdout" "github-gh-read-falls-back: the proven merge was not reported"
  assert_grep 'pr=https://github.com/example/repo/pull/63' "$case_dir/state/task-x1.meta" \
    "github-gh-read-falls-back: the merged PR was not recorded for teardown"
  pass "fm-pr-merge falls back to the gh-axi view when gh's read fails"
}

test_github_failed_merge_names_an_observed_landed_state() {
  local case_dir rc
  case_dir=$(make_case github-failed-merge-actually-landed)
  mkdir -p "$case_dir/wt"
  add_gh_mocks_merge_fails "$case_dir"
  write_github_outcome "$case_dir" MERGED true false main
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/64 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-failed-merge-actually-landed: the forge failure must still fail the wrapper"
  assert_grep 'error: pr merge failed' "$case_dir/stderr" \
    "github-failed-merge-actually-landed: the original forge error was masked"
  assert_grep 'state=MERGED, merged=true, isInMergeQueue=false' "$case_dir/stderr" \
    "github-failed-merge-actually-landed: the observed landed state was never named"
  assert_no_grep 'verified: ' "$case_dir/stdout" \
    "github-failed-merge-actually-landed: a failed merge command was reported as verified"
  assert_grep 'pr=https://github.com/example/repo/pull/64' "$case_dir/state/task-x1.meta" \
    "github-failed-merge-actually-landed: the landed PR lost its reference"
  pass "fm-pr-merge names a landed state hiding behind a failed GitHub merge command"
}

test_github_without_gh_still_uses_gh_axi_merge() {
  local case_dir ghless_path rc
  case_dir=$(make_case github-without-gh)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 4141414141414141414141414141414141414141
  rm "$case_dir/fakebin/gh"
  ghless_path="$case_dir/path-without-gh"
  mirror_path_without "$ghless_path" gh "$case_dir/fakebin"
  : > "$case_dir/gh-axi.log"

  set +e
  PATH="$ghless_path" run_pr_merge "$case_dir" task-x1 \
    https://github.com/example/repo/pull/60 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "github-without-gh: gh-axi can prove a landed merge without gh"
  assert_merge_call "$case_dir" 60 example/repo \
    "github-without-gh: the configured merge abstraction was not invoked"
  assert_grep 'pr view 60 --repo example/repo' "$case_dir/gh-axi.log" \
    "github-without-gh: the gh-axi fallback did not verify the landed state"
  assert_grep 'verified: https://github.com/example/repo/pull/60 is merged' \
    "$case_dir/stdout" "github-without-gh: the fallback did not report the proven merge"
  pass "fm-pr-merge reaches and verifies the gh-axi merge path without gh"
}

test_github_without_gh_failed_read_keeps_bookkeeping() {
  local case_dir ghless_path rc
  case_dir=$(make_case github-without-gh-read-fails)
  mkdir -p "$case_dir/wt"
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
# The exact-head merge seam and the CLI merge are the same merge call here.
merge_op="${1:-} ${2:-}"
[ "$merge_op" != "api PUT" ] || merge_op="pr merge"
case "$merge_op" in
  "pr merge") exit 0 ;;
  "pr view") exit 1 ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi"
  ghless_path="$case_dir/path-without-gh"
  mirror_path_without "$ghless_path" gh "$case_dir/fakebin"
  : > "$case_dir/gh-axi.log"

  set +e
  PATH="$ghless_path" run_pr_merge "$case_dir" task-x1 \
    https://github.com/example/repo/pull/61 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-without-gh-read-fails: an unreadable outcome must fail"
  assert_merge_call "$case_dir" 61 example/repo \
    "github-without-gh-read-fails: the merge call did not happen before the failed read"
  assert_grep 'could not read the GitHub pull request outcome after the merge attempt' \
    "$case_dir/stderr" "github-without-gh-read-fails: the failed read was not reported"
  assert_grep 'pr=https://github.com/example/repo/pull/61' "$case_dir/state/task-x1.meta" \
    "github-without-gh-read-fails: a landed merge lost its PR metadata"
  assert_present "$case_dir/state/task-x1.check.sh" \
    "github-without-gh-read-fails: a landed merge lost its merge poll"
  pass "fm-pr-merge preserves bookkeeping when gh is absent and the fallback read fails"
}

test_github_zero_exit_queue_required_refuses_with_exact_retry() {
  local case_dir rc
  case_dir=$(make_case github-zero-exit-queue-required)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2121212121212121212121212121212121212121
  write_github_outcome "$case_dir" OPEN false false 'release/2026'
  printf 'merge_method=REBASE\n' > "$case_dir/github-rules"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/56 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-zero-exit-queue-required: an unproved merge must fail"
  assert_grep 'state=OPEN, merged=false, isInMergeQueue=false' "$case_dir/stderr" \
    "github-zero-exit-queue-required: refusal did not name the concrete observed state"
  assert_grep 'base branch release/2026 requires the merge queue, configured for rebase' "$case_dir/stderr" \
    "github-zero-exit-queue-required: refusal did not name the queue requirement"
  assert_grep 'arranged outside it' "$case_dir/stderr" \
    "github-zero-exit-queue-required: refusal did not say the queued merge cannot be head-bound here"
  assert_no_grep '--auto' "$case_dir/stderr" \
    "github-zero-exit-queue-required: the refusal recommended a deferred merge this script refuses"
  assert_grep 'api --paginate repos/example/repo/rules/branches/release%2F2026' "$case_dir/gh.log" \
    "github-zero-exit-queue-required: queue rules were not read with pagination and encoded branch path"
  assert_merge_call "$case_dir" 56 example/repo \
    "github-zero-exit-queue-required: the attempted merge was changed unexpectedly"
  [ "$(wc -l < "$case_dir/gh-axi.log" | tr -d '[:space:]')" = 1 ] \
    || fail "github-zero-exit-queue-required: the wrapper attempted more than one merge"
  assert_no_grep '--auto' "$case_dir/gh-axi.log" \
    "github-zero-exit-queue-required: queue flags were auto-applied to the attempted merge"
  assert_grep 'pr=https://github.com/example/repo/pull/56' "$case_dir/state/task-x1.meta" \
    "github-zero-exit-queue-required: the attempted merge lost its PR reference"
  assert_present "$case_dir/state/task-x1.check.sh" \
    "github-zero-exit-queue-required: the attempted merge did not leave its poll armed"
  pass "fm-pr-merge reports exact queue retry flags after a zero-exit false success"
}

test_github_closed_unqueued_outcome_omits_retry_flags() {
  local case_dir rc
  case_dir=$(make_case github-closed-unqueued)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2323232323232323232323232323232323232323
  write_github_outcome "$case_dir" CLOSED false false master
  printf 'merge_method=MERGE\n' > "$case_dir/github-rules"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/57 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-closed-unqueued: an unproved merge must fail"
  assert_grep 'state=CLOSED, merged=false, isInMergeQueue=false' "$case_dir/stderr" \
    "github-closed-unqueued: refusal did not name the concrete observed state"
  assert_no_grep 'requires the merge queue' "$case_dir/stderr" \
    "github-closed-unqueued: closed PR received unusable queue guidance"
  assert_no_grep 'configured for ' "$case_dir/stderr" \
    "github-closed-unqueued: closed PR received queue guidance"
  assert_grep 'pr=https://github.com/example/repo/pull/57' "$case_dir/state/task-x1.meta" \
    "github-closed-unqueued: the attempted merge lost its PR reference"
  assert_present "$case_dir/state/task-x1.check.sh" \
    "github-closed-unqueued: the attempted merge did not leave its poll armed"
  pass "fm-pr-merge omits merge-queue retry guidance for a closed GitHub PR"
}

test_github_queued_outcome_is_refused() {
  local case_dir rc
  case_dir=$(make_case github-verified-queued)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 3030303030303030303030303030303030303030
  write_github_outcome "$case_dir" OPEN false true master
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/53 -- --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  # The queue lands whatever the head is when it reaches the pull request, so a
  # queue entry proves nothing about the commit this run verified.
  expect_code 1 "$rc" "github-verified-queued: a queued PR was reported as a success"
  assert_no_grep 'verified: ' "$case_dir/stdout" \
    "github-verified-queued: a queue entry was reported as a verified outcome"
  assert_grep 'entered the merge queue instead of merging' "$case_dir/stderr" \
    "github-verified-queued: the refusal did not say why a queue entry proves nothing"
  assert_grep 'pr=https://github.com/example/repo/pull/53' "$case_dir/state/task-x1.meta" \
    "github-verified-queued: the queued PR was not recorded for teardown"
  assert_present "$case_dir/state/task-x1.check.sh" \
    "github-verified-queued: the refused queue entry did not leave its poll armed"
  pass "fm-pr-merge refuses a GitHub merge-queue entry as an unproved outcome"
}

test_github_queue_required_refusal_names_retry_flags() {
  local case_dir rc
  case_dir=$(make_case github-queue-required)
  mkdir -p "$case_dir/wt"
  add_gh_mocks_merge_fails "$case_dir"
  write_github_outcome "$case_dir" OPEN false false master
  printf 'merge_method=MERGE\n' > "$case_dir/github-rules"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/54 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-queue-required: an incompatible direct merge must fail"
  assert_grep 'error: pr merge failed' "$case_dir/stderr" \
    "github-queue-required: the original forge failure was not preserved"
  assert_grep 'base branch master requires the merge queue' "$case_dir/stderr" \
    "github-queue-required: refusal did not name the queue requirement"
  assert_grep 'configured for merge' "$case_dir/stderr" \
    "github-queue-required: refusal did not name the queue's configured method"
  assert_no_grep '--auto' "$case_dir/stderr" \
    "github-queue-required: the refusal recommended a deferred merge this script refuses"
  assert_merge_call "$case_dir" 54 example/repo \
    "github-queue-required: the wrapper silently changed the attempted merge semantics"
  assert_present "$case_dir/state/task-x1.check.sh" \
    "github-queue-required: the failed forge call did not leave the merge poll armed"
  pass "fm-pr-merge explains how to retry with the required GitHub merge queue method"
}

test_github_agreeing_queue_rules_keep_retry_guidance() {
  local case_dir rc
  case_dir=$(make_case github-agreeing-queue-rules)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2424242424242424242424242424242424242424
  write_github_outcome "$case_dir" OPEN false false main
  printf 'merge_method=REBASE\nmerge_method=REBASE\n' > "$case_dir/github-rules"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/58 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-agreeing-queue-rules: an unproved merge must fail"
  assert_grep 'base branch main requires the merge queue' "$case_dir/stderr" \
    "github-agreeing-queue-rules: refusal did not name the queue requirement"
  assert_grep 'configured for rebase' "$case_dir/stderr" \
    "github-agreeing-queue-rules: agreeing rules did not resolve to one configured method"
  assert_no_grep 'conflicting configured merge methods' "$case_dir/stderr" \
    "github-agreeing-queue-rules: agreeing rules were reported as conflicting"
  pass "fm-pr-merge aggregates agreeing merge-queue rules"
}

test_github_conflicting_queue_rules_report_ambiguity() {
  local case_dir rc
  case_dir=$(make_case github-conflicting-queue-rules)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2525252525252525252525252525252525252525
  write_github_outcome "$case_dir" OPEN false false main
  printf 'merge_method=MERGE\nmerge_method=SQUASH\nmerge_method=SQUASH\n' \
    > "$case_dir/github-rules"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/59 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-conflicting-queue-rules: an unproved merge must fail"
  assert_grep 'base branch main requires the merge queue and has conflicting configured merge methods (MERGE, SQUASH)' \
    "$case_dir/stderr" \
    "github-conflicting-queue-rules: conflicting methods were not named"
  assert_no_grep 'configured for ' "$case_dir/stderr" \
    "github-conflicting-queue-rules: one method was chosen out of conflicting rules"
  assert_no_grep 'SQUASH, SQUASH' "$case_dir/stderr" \
    "github-conflicting-queue-rules: a repeated queue method was named twice"
  pass "fm-pr-merge reports ambiguity for conflicting merge-queue rules"
}

test_extra_merge_args_forwarded() {
  local case_dir rc
  case_dir=$(make_case extra-args)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2222222222222222222222222222222222222222
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/15 -- --squash --delete-branch \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "extra-args: fm-pr-merge failed"

  assert_merge_call "$case_dir" 15 example/repo \
    "extra-args: the caller's merge method did not reach the head-bound seam"
  assert_grep 'api DELETE /repos/example/repo/git/refs/heads/' "$case_dir/gh-axi.log" \
    "extra-args: the caller's branch deletion was dropped"
  pass "fm-pr-merge resolves extra flags after the -- separator onto the head-bound seam"
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
  assert_no_merge_call "$case_dir" \
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
  assert_no_merge_call "$case_dir" \
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
  assert_grep 'extra merge arguments must not override the repository' "$case_dir/stderr" \
    "repo-override: refusal did not explain the repo override"
  assert_no_grep 'pr=https://github.com/right/repo/pull/5' "$case_dir/state/task-x1.meta" \
    "repo-override: PR URL was recorded before rejecting repo override"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "repo-override: repo override armed a merge poll"
  assert_no_merge_call "$case_dir" \
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
  assert_no_merge_call "$case_dir" \
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

  assert_merge_call "$case_dir" 8 example/repo \
    "bundled-non-repo-cluster: the merge did not reach the head-bound seam"
  assert_grep 'api DELETE /repos/example/repo/git/refs/heads/' "$case_dir/gh-axi.log" \
    "bundled-non-repo-cluster: a short flag carrying no repository override was dropped"
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

  assert_merge_call "$case_dir" 22 example/repo \
    "explicit-merge-method: caller --merge did not replace the default squash method" merge
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

  assert_merge_call "$case_dir" 23 example/repo \
    "method-equals-merge-method: caller --method=merge did not replace the default squash method" merge
  pass "fm-pr-merge respects --method=<value> as an explicit merge method"
}

test_parses_pr_url_for_gh_axi() {
  local case_dir
  case_dir=$(make_case url-parsing)
  bind_project_remote "$case_dir" my-org/my-repo
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 6666666666666666666666666666666666666666
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/my-org/my-repo/pull/126 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "url-parsing: fm-pr-merge failed"

  assert_merge_call "$case_dir" 126 my-org/my-repo \
    "url-parsing: gh-axi pr merge was not invoked as number + --repo + default --squash"
  pass "fm-pr-merge parses a GitHub PR URL into gh-axi number and --repo arguments"
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
  [ "$merge_line" = "GITLAB_HOST=$MR_HOST mr merge 7 -R $MR_PROJECT_URL --sha $MR_HEAD --auto-merge=false --yes" ] \
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
  [ "$merge_line" = "GITLAB_HOST=$MR_HOST mr merge 7 -R $MR_PROJECT_URL --sha $MR_HEAD --auto-merge=false --yes --remove-source-branch" ] \
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

test_gitlab_mergeability_requires_boolean_fields() {
  local case_dir rc name field
  for name in conflicts discussions; do
    case "$name" in
      conflicts) field='conflicts="false"' ;;
      discussions) field='discussions="true"' ;;
    esac
    case_dir=$(make_gitlab_case "gitlab-non-boolean-$name" "$field")

    set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    expect_code 1 "$rc" "gitlab-non-boolean-$name: malformed mergeability data must refuse"
    assert_grep 'could not read the GitLab merge request state before merging' \
      "$case_dir/stderr" "gitlab-non-boolean-$name: malformed mergeability data was accepted"
    [ -z "$(glab_merge_line "$case_dir/glab.log")" ] \
      || fail "gitlab-non-boolean-$name: a merge was attempted on malformed mergeability data"
  done
  pass "fm-pr-merge rejects non-boolean GitLab mergeability fields"
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

    mkdir -p "$case_dir/home"
    set +e
    FM_ROOT_OVERRIDE="$ROOT" \
    FM_HOME="$case_dir/home" \
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

test_github_sha_arg_refuses_like_gitlab() {
  local case_dir rc
  case_dir=$(make_case github-sha-arg)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" dddddddddddddddddddddddddddddddddddddddd
  : > "$case_dir/gh-axi.log"

  # The head comes only from the live read on both forges, so a caller --sha is
  # refused here for the same reason it always was on GitLab.
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/44 -- --sha abc123 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-sha-arg: a caller head override was accepted on GitHub"
  assert_no_merge_call "$case_dir" \
    "github-sha-arg: merge ran with a caller-supplied head"
  pass "fm-pr-merge refuses a caller head override on GitHub as it does on GitLab"
}

# --- durable merge outcome ---------------------------------------------------
# A merge that lands must leave a record outside the merging agent's memory.
# bin/fm-merge-outcome-lib.sh owns where that record goes; these cases pin the
# behavior through the real merge entrypoint.

# make_home_case <name> [<route> [<parent-home>]]: a case dir whose home is a
# secondmate home bound to a parent, or a plain main home when no route is
# given. Echoes the case dir; the home is "$case_dir/home".
make_home_case() {
  local name=$1 route=${2:-} parent=${3:-} case_dir home
  case_dir=$(make_case "$name")
  home="$case_dir/home"
  mkdir -p "$home" "$case_dir/wt"
  if [ -n "$route" ]; then
    printf '%s\n' mate-x >"$home/.fm-secondmate-home"
    {
      printf 'schema=fm-secondmate-parent.v1\n'
      printf 'route=%s\n' "$route"
      [ "$route" != local ] || printf 'parent_home=%s\n' "$parent"
    } >"$home/.fm-secondmate-parent"
  fi
  printf '%s\n' "$case_dir"
}

parent_reply_lines() {  # <file> <url>
  grep -c -F "$2" "$1" 2>/dev/null || true
}

test_secondmate_merge_reports_upward_once() {
  local case_dir replies url
  url=https://github.com/example/repo/pull/61
  case_dir=$(make_home_case secondmate-merge-reports remote)
  add_gh_mocks "$case_dir" 5555555555555555555555555555555555555555
  : >"$case_dir/gh-axi.log"
  replies="$case_dir/state/parent-replies.status"

  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    >"$case_dir/stdout" 2>"$case_dir/stderr" || fail "secondmate-merge-reports: merge failed"

  assert_grep "done [key=merged-task-x1]: merged task-x1 $url" "$replies" \
    "secondmate-merge-reports: the landed PR was not reported upward"
  [ "$(grep -c 'merged-task-x1' "$replies")" -eq 1 ] \
    || fail "secondmate-merge-reports: one merge produced more than one upward merge line"
  # The merge path registers the PR first, and that registration publishes the
  # child's ready line on the same channel from fm-pr-check itself.
  assert_grep "done [key=child-pr-task-x1]: child task-x1 PR ready: $url" "$replies" \
    "secondmate-merge-reports: the registration's ready line was not reported upward"

  # The same merge again: the forge accepts it in this fixture, so only the
  # at-most-once contract can keep the parent from being told twice.
  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    >"$case_dir/stdout2" 2>"$case_dir/stderr2" || fail "secondmate-merge-reports: repeat merge failed"
  [ "$(grep -c 'merged-task-x1' "$replies")" -eq 1 ] \
    || fail "secondmate-merge-reports: a repeat merge of the same PR duplicated the upward line"
  [ "$(parent_reply_lines "$replies" "$url")" -eq 2 ] \
    || fail "secondmate-merge-reports: a repeat merge changed the upward lines: $(cat "$replies")"
  pass "a merge a secondmate home performs itself is reported upward exactly once"
}

test_secondmate_merge_reports_on_the_local_route() {
  local case_dir parent_status url
  url=https://github.com/example/repo/pull/62
  case_dir=$(make_home_case secondmate-merge-local local "$TMP_ROOT/secondmate-merge-local/state/parent-home")
  mkdir -p "$TMP_ROOT/secondmate-merge-local/state/parent-home/state"
  add_gh_mocks "$case_dir" 6666666666666666666666666666666666666666
  : >"$case_dir/gh-axi.log"
  parent_status="$TMP_ROOT/secondmate-merge-local/state/parent-home/state/mate-x.status"

  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    >"$case_dir/stdout" 2>"$case_dir/stderr" || fail "secondmate-merge-local: merge failed"

  assert_grep "done [key=merged-task-x1]: merged task-x1 $url" "$parent_status" \
    "secondmate-merge-local: the landed PR did not reach the parent home's channel"
  [ ! -e "$case_dir/state/parent-replies.status" ] \
    || fail "secondmate-merge-local: a local-route report also wrote the remote reply channel"
  pass "a locally routed secondmate home reports the landed PR into its parent's own channel"
}

# Regression: when FM_HOME is unset, the merge entrypoint falls back to
# FM_ROOT_OVERRIDE (the checkout). A checkout carrying secondmate identity
# markers then routes the landed-merge line into that marker's parent_home,
# which can be a live fleet home. The case must never read or write the
# repository checkout's own markers; the fixture checkout lives inside the
# case directory, and the simulated parent sits outside FM_STATE_OVERRIDE.
test_fallback_home_never_routes_outcomes_through_ambient_markers() {
  local case_dir url fallback_home live_parent leaked_status
  url=https://github.com/example/repo/pull/78
  case_dir=$(make_case fallback-home-isolation)
  add_gh_mocks "$case_dir" 7878787878787878787878787878787878787878
  : >"$case_dir/gh-axi.log"

  live_parent="$case_dir/live-parent"
  mkdir -p "$live_parent/state"
  fallback_home="$case_dir/fallback-checkout"
  mkdir -p "$fallback_home"
  git init --quiet "$fallback_home"
  ln -s "$ROOT/bin" "$fallback_home/bin"
  printf '%s\n' mate-leak > "$fallback_home/.fm-secondmate-home"
  {
    printf 'schema=fm-secondmate-parent.v1\n'
    printf 'route=local\n'
    printf 'parent_home=%s\n' "$live_parent"
  } > "$fallback_home/.fm-secondmate-parent"
  leaked_status="$live_parent/state/mate-leak.status"

  run_pr_merge_unset_home "$case_dir" "$fallback_home" task-x1 "$url" \
    >"$case_dir/stdout" 2>"$case_dir/stderr" \
    || fail "fallback-home-isolation: merge failed"

  assert_absent "$leaked_status" \
    "fallback-home-isolation: the fallback home routed a landed-merge outcome outside FM_STATE_OVERRIDE"
  assert_grep 'refusing a test-time write outside FM_STATE_OVERRIDE/FM_DATA_OVERRIDE' \
    "$case_dir/stderr" \
    "fallback-home-isolation: the outside write was not refused"
  pass "the merge entrypoint's fallback home never reports outcomes through ambient identity markers"
}

test_fallback_home_never_escapes_the_override_through_dot_components() {
  local case_dir url fallback_home live_parent leaked_status
  url=https://github.com/example/repo/pull/80
  case_dir=$(make_case dot-component-escape)
  add_gh_mocks "$case_dir" 8080808080808080808080808080808080808080
  : >"$case_dir/gh-axi.log"

  live_parent="$case_dir/live-parent"
  mkdir -p "$live_parent/state"
  fallback_home="$case_dir/fallback-checkout"
  mkdir -p "$fallback_home"
  git init --quiet "$fallback_home"
  ln -s "$ROOT/bin" "$fallback_home/bin"
  printf '%s\n' mate-dots > "$fallback_home/.fm-secondmate-home"
  # parent_home reaches the live parent by walking back out of the override, so
  # the destination is lexically inside FM_STATE_OVERRIDE but resolves outside.
  {
    printf 'schema=fm-secondmate-parent.v1\n'
    printf 'route=local\n'
    printf 'parent_home=%s\n' "$case_dir/state/missing/../../live-parent"
  } > "$fallback_home/.fm-secondmate-parent"
  leaked_status="$live_parent/state/mate-dots.status"

  run_pr_merge_unset_home "$case_dir" "$fallback_home" task-x1 "$url" \
    >"$case_dir/stdout" 2>"$case_dir/stderr" \
    || fail "dot-component-escape: merge failed"

  assert_absent "$leaked_status" \
    "dot-component-escape: a dot-component path routed a landed-merge outcome outside FM_STATE_OVERRIDE"
  assert_absent "$case_dir/state/missing" \
    "dot-component-escape: the refused write still created directories inside the override"
  assert_grep 'refusing a test-time write outside FM_STATE_OVERRIDE/FM_DATA_OVERRIDE' \
    "$case_dir/stderr" \
    "dot-component-escape: the escaping write was not refused"
  pass "an unresolved dot component cannot carry a landed-merge outcome outside the override"
}

test_data_only_override_never_writes_into_the_live_home_state() {
  local case_dir live_home url rc
  url=https://github.com/example/repo/pull/81
  case_dir=$(make_case data-only-override)
  add_gh_mocks "$case_dir" 8181818181818181818181818181818181818181
  : >"$case_dir/gh-axi.log"

  # FM_STATE_OVERRIDE is unset, so STATE falls back to this home's state dir.
  # It stands in for the live primary home: nothing in this flow may write there.
  live_home="$case_dir/live-home"
  mkdir -p "$live_home/state" "$case_dir/isolated-data"
  cp "$case_dir/state/task-x1.meta" "$live_home/state/task-x1.meta"

  set +e
  run_pr_merge_data_override_only "$case_dir" "$live_home" "$case_dir/isolated-data" \
    task-x1 "$url" >"$case_dir/stdout" 2>"$case_dir/stderr"
  rc=$?
  set -e

  # The merge itself landed, so the entrypoint still exits 0 and reports the
  # unrecorded outcome loudly; only the writes must stay out of the live home.
  expect_code 0 "$rc" "data-only-override: a landed merge should still exit 0"
  assert_grep 'refusing a test-time write outside FM_STATE_OVERRIDE/FM_DATA_OVERRIDE' \
    "$case_dir/stderr" \
    "data-only-override: the outside state write was not refused"
  assert_grep "actionable: merged $url but could not record the outcome for supervision" \
    "$case_dir/stderr" \
    "data-only-override: the refused record was not reported loudly"
  assert_absent "$live_home/state/.wake-queue" \
    "data-only-override: a fabricated merge wake landed in the live home"
  assert_absent "$live_home/state/.wake-queue.seq" \
    "data-only-override: a wake sequence file landed in the live home"
  assert_absent "$live_home/state/.watcher-down" \
    "data-only-override: a watcher recovery marker landed in the live home"
  assert_absent "$live_home/state/task-x1.pr-poll-merge-notified" \
    "data-only-override: a merge notification marker landed in the live home"
  pass "FM_DATA_OVERRIDE alone never lets the merge report write into the live home state"
}

test_local_route_parent_write_without_overrides_still_lands() {
  local case_dir parent_status url
  url=https://github.com/example/repo/pull/79
  case_dir=$(make_case production-parent-write)
  add_gh_mocks "$case_dir" 7979797979797979797979797979797979797979
  : >"$case_dir/gh-axi.log"
  mkdir -p "$case_dir/home/state" "$case_dir/parent/state"
  mv "$case_dir/state/task-x1.meta" "$case_dir/home/state/task-x1.meta"
  printf '%s\n' mate-x > "$case_dir/home/.fm-secondmate-home"
  {
    printf 'schema=fm-secondmate-parent.v1\n'
    printf 'route=local\n'
    printf 'parent_home=%s\n' "$case_dir/parent"
  } > "$case_dir/home/.fm-secondmate-parent"
  parent_status="$case_dir/parent/state/mate-x.status"

  run_pr_merge_without_overrides "$case_dir" task-x1 "$url" \
    >"$case_dir/stdout" 2>"$case_dir/stderr" \
    || fail "production-parent-write: merge failed"

  assert_grep "done [key=merged-task-x1]: merged task-x1 $url" "$parent_status" \
    "production-parent-write: a production merge did not report into the parent home"
  pass "a merge without state/data overrides still reports into the parent home"
}

test_failed_merge_reports_nothing() {
  local case_dir rc
  case_dir=$(make_home_case failed-merge-silent remote)
  add_gh_mocks_merge_fails "$case_dir"
  : >"$case_dir/gh-axi.log"

  set +e
  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/63 \
    >"$case_dir/stdout" 2>"$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "failed-merge-silent: a failed merge should propagate"
  # The registration's ready line is a fact of its own; only a merge line
  # would misreport the unlanded merge.
  assert_no_grep 'merged-task-x1' "$case_dir/state/parent-replies.status" \
    "failed-merge-silent: a merge that never landed was reported as landed"
  pass "a refused or failed merge reports no outcome"
}

test_gitlab_refusal_reports_nothing() {
  local case_dir rc
  case_dir=$(make_gitlab_case gitlab-refusal-silent state=merged)
  mkdir -p "$case_dir/home"
  printf '%s\n' mate-x >"$case_dir/home/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=remote\n' >"$case_dir/home/.fm-secondmate-parent"

  set +e
  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$MR_URL" \
    >"$case_dir/stdout" 2>"$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "gitlab-refusal-silent: a refused GitLab merge should exit non-zero"
  # Registration succeeds before the later GitLab pre-merge refusal, so the
  # PR-ready fact is expected; only a merged outcome would be false.
  assert_no_grep 'merged-task-x1' "$case_dir/state/parent-replies.status" \
    "gitlab-refusal-silent: a refused merge request was reported as landed"
  pass "a GitLab merge refused before the forge call reports no outcome"
}

test_gitlab_merge_reports_upward() {
  local case_dir url
  case_dir=$(make_gitlab_case gitlab-merge-reports)
  mkdir -p "$case_dir/home"
  printf '%s\n' mate-x >"$case_dir/home/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=remote\n' >"$case_dir/home/.fm-secondmate-parent"
  url=$MR_URL

  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    >"$case_dir/stdout" 2>"$case_dir/stderr" || fail "gitlab-merge-reports: merge failed"

  assert_grep "done [key=merged-task-x1]: merged task-x1 $url" \
    "$case_dir/state/parent-replies.status" \
    "gitlab-merge-reports: a landed merge request was not reported upward"
  pass "a landed GitLab merge request is reported upward on the same channel"
}

test_queued_gitlab_merge_leaves_the_poll_armed() {
  local case_dir rc
  case_dir=$(make_gitlab_case queued-gitlab-merge)
  mkdir -p "$case_dir/home"
  : >"$case_dir/glab-stays-open"

  set +e
  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$MR_URL" \
    >"$case_dir/stdout" 2>"$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "queued-gitlab-merge: unconfirmed merge should exit non-zero"
  assert_grep 'landed state is opened' "$case_dir/stderr" \
    "queued-gitlab-merge: the unconfirmed state was not named"
  assert_absent "$case_dir/state/.wake-queue" \
    "queued-gitlab-merge: a queued merge was reported as landed"
  [ -f "$case_dir/state/task-x1.check.sh" ] \
    || fail "queued-gitlab-merge: the merge poll was not left armed"
  [ ! -e "$case_dir/state/task-x1.pr-poll-merge-notified" ] \
    || fail "queued-gitlab-merge: a queued merge was marked as reported"
  pass "a queued GitLab merge stays silent and leaves confirmation to the armed poll"
}

test_gitlab_post_merge_confirmation_failures_leave_poll_armed() {
  local case_dir rc name marker
  for name in unreadable invalid; do
    case_dir=$(make_gitlab_case "gitlab-post-confirm-$name")
    marker="glab-post-view-fails"
    [ "$name" = unreadable ] || marker="glab-post-invalid"
    : > "$case_dir/$marker"

    set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    expect_code 2 "$rc" "gitlab-post-confirm-$name: confirmation failure should propagate"
    assert_grep 'landed state could not be confirmed' "$case_dir/stderr" \
      "gitlab-post-confirm-$name: confirmation failure was not reported"
    [ -f "$case_dir/state/task-x1.check.sh" ] \
      || fail "gitlab-post-confirm-$name: the merge poll was not left armed"
    [ ! -e "$case_dir/state/task-x1.pr-poll-merge-notified" ] \
      || fail "gitlab-post-confirm-$name: an unconfirmed merge was marked as reported"
  done
  pass "GitLab confirmation failures propagate while their polls remain armed"
}

test_main_home_merge_leaves_a_durable_wake() {
  local case_dir url
  url=https://github.com/example/repo/pull/64
  case_dir=$(make_home_case main-merge-wake)
  add_gh_mocks "$case_dir" 7777777777777777777777777777777777777777
  : >"$case_dir/gh-axi.log"

  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    >"$case_dir/stdout" 2>"$case_dir/stderr" || fail "main-merge-wake: merge failed"

  assert_grep "$url" "$case_dir/state/.wake-queue" \
    "main-merge-wake: a merge this home performed left no durable record naming the PR"
  [ "$(grep -c -F "$url" "$case_dir/state/.wake-queue")" -eq 1 ] \
    || fail "main-merge-wake: one merge produced more than one durable record"
  assert_absent "$case_dir/state/parent-replies.status" \
    "main-merge-wake: a main home wrote a parent reply channel it does not have"
  pass "a merge a main home performs itself leaves one durable wake naming the PR"
}

test_queued_github_merge_leaves_the_poll_armed() {
  local case_dir url rc
  url=https://github.com/example/repo/pull/66
  case_dir=$(make_home_case queued-github-merge)
  add_gh_mocks "$case_dir" 9999999999999999999999999999999999999999
  write_github_outcome "$case_dir" OPEN false true main
  : >"$case_dir/gh-axi.log"

  set +e
  FM_TEST_GH_MERGE_STATE=open FM_TEST_HOME="$case_dir/home" \
    run_pr_merge "$case_dir" task-x1 "$url" \
      >"$case_dir/stdout" 2>"$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "queued-github-merge: a queued merge was reported as a success"
  assert_absent "$case_dir/state/.wake-queue" \
    "queued-github-merge: a queued merge was reported as landed"
  [ -f "$case_dir/state/task-x1.check.sh" ] \
    || fail "queued-github-merge: the merge poll was not left armed"
  [ ! -e "$case_dir/state/task-x1.pr-poll-merge-notified" ] \
    || fail "queued-github-merge: a queued merge was marked as reported"
  pass "a queued GitHub merge records no landed outcome and leaves its poll armed"
}

test_distinct_merged_prs_keep_distinct_wakes() {
  local case_dir first_url second_url
  first_url=https://github.com/example/repo/pull/68
  second_url=https://github.com/example/repo/pull/69
  case_dir=$(make_home_case distinct-merge-wakes)
  add_gh_mocks "$case_dir" bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  : >"$case_dir/gh-axi.log"

  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$first_url" \
    >"$case_dir/stdout-1" 2>"$case_dir/stderr-1" \
    || fail "distinct-merge-wakes: first merge failed"
  rm -f "$case_dir/state/task-x1.check.sh" \
    "$case_dir/state/task-x1.pr-poll" \
    "$case_dir/state/task-x1.pr-poll-registration"
  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$second_url" \
    >"$case_dir/stdout-2" 2>"$case_dir/stderr-2" \
    || fail "distinct-merge-wakes: second merge failed"

  [ "$(grep -c -F "$first_url" "$case_dir/state/.wake-queue")" -eq 1 ] \
    || fail "distinct-merge-wakes: first merge wake was missing or duplicated"
  [ "$(grep -c -F "$second_url" "$case_dir/state/.wake-queue")" -eq 1 ] \
    || fail "distinct-merge-wakes: second merge wake was missing or duplicated"
  FM_STATE_OVERRIDE="$case_dir/state" "$ROOT/bin/fm-wake-drain.sh" \
    >"$case_dir/drain.out" 2>"$case_dir/drain.err" \
    || fail "distinct-merge-wakes: wake drain failed"
  assert_grep "$first_url" "$case_dir/drain.out" \
    "distinct-merge-wakes: queue deduplication collapsed the first PR"
  assert_grep "$second_url" "$case_dir/drain.out" \
    "distinct-merge-wakes: queue deduplication collapsed the second PR"
  pass "distinct merged PRs for one task retain distinct captain-facing wakes"
}

test_uncommitted_marker_retry_is_never_silent() {
  local case_dir url count rc
  url=https://github.com/example/repo/pull/67
  case_dir=$(make_home_case uncommitted-wake-retry)
  add_gh_mocks "$case_dir" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  : >"$case_dir/gh-axi.log"
  cat >"$case_dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
case "${!#}" in
  *.pr-poll-merge-notified)
    if mkdir "$FM_TEST_MARKER_FAILURE.claim" 2>/dev/null; then
      exit 1
    fi
    ;;
esac
exec "$FM_TEST_REAL_MV" "$@"
SH
  chmod +x "$case_dir/fakebin/mv"
  export FM_TEST_MARKER_FAILURE="$case_dir/marker-failure"
  export FM_TEST_REAL_MV
  FM_TEST_REAL_MV=$(command -v mv)

  set +e
  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    >"$case_dir/stdout-1" 2>"$case_dir/stderr-1"
  rc=$?
  set -e
  expect_code 0 "$rc" "uncommitted-wake-retry: the merge itself landed and must not be reported as failed"
  assert_grep 'could not record the outcome' "$case_dir/stderr-1" \
    "uncommitted-wake-retry: failed marker commit was not loud"
  [ -f "$case_dir/state/task-x1.check.sh" ] \
    || fail "uncommitted-wake-retry: failed commit disarmed the retry poll"
  count=$(grep -c -F "$url" "$case_dir/state/.wake-queue")
  [ "$count" -ge 1 ] \
    || fail "uncommitted-wake-retry: failed marker commit lost the durable outcome"
  [ ! -e "$case_dir/state/task-x1.pr-poll-merge-notified" ] \
    || fail "uncommitted-wake-retry: failed marker commit was treated as complete"

  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    >"$case_dir/stdout-2" 2>"$case_dir/stderr-2" \
    || fail "uncommitted-wake-retry: retry failed"
  unset FM_TEST_MARKER_FAILURE FM_TEST_REAL_MV
  count=$(grep -c -F "$url" "$case_dir/state/.wake-queue")
  [ "$count" -ge 1 ] \
    || fail "uncommitted-wake-retry: retry left the merge silent"
  [ -f "$case_dir/state/task-x1.pr-poll-merge-notified" ] \
    || fail "uncommitted-wake-retry: retry did not commit the canonical marker"
  pass "an uncommitted marker retry preserves at least one durable outcome"
}

test_secondmate_without_parent_binding_is_loud() {
  local case_dir rc url
  url=https://github.com/example/repo/pull/65
  case_dir=$(make_home_case unbound-secondmate)
  add_gh_mocks "$case_dir" 8888888888888888888888888888888888888888
  : >"$case_dir/gh-axi.log"
  # A secondmate identity with no parent binding: exactly the seeding gap that
  # let three real merges land in silence.
  printf '%s\n' mate-x >"$case_dir/home/.fm-secondmate-home"

  set +e
  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    >"$case_dir/stdout" 2>"$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "unbound-secondmate: the merge itself landed and must not be reported as failed"
  assert_grep 'could not report it upward' "$case_dir/stderr" \
    "unbound-secondmate: a merge that could not be reported upward said nothing about it"
  assert_absent "$case_dir/state/.wake-queue" \
    "unbound-secondmate: a secondmate home fell back to the main-home record"
  pass "a secondmate home that cannot report upward says so instead of merging in silence"
}


test_non_green_pr_requires_explicit_override() {
  local case_dir rc
  case_dir=$(make_case non-green)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  : > "$case_dir/gh-axi.log"

  set +e
  FM_FAKE_GH_CHECKS_SUMMARY='2 passed, 1 failed, 3 total' FM_FAKE_GH_MERGEABLE=false \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/12 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "non-green: fm-pr-merge should refuse"
  assert_grep 'error: refusing to merge non-green PR' "$case_dir/stderr" \
    "non-green: refusal did not explain the safety guard"
  assert_no_merge_call "$case_dir" \
    "non-green: gh-axi pr merge was invoked"

  : > "$case_dir/gh-axi.log"
  FM_FAKE_GH_CHECKS_SUMMARY='2 passed, 1 failed, 3 total' FM_FAKE_GH_MERGEABLE=false \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/12 --allow-red \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "non-green: explicit override did not permit the merge"
  assert_merge_call "$case_dir" 12 example/repo \
    "non-green: --allow-red was forwarded or merge did not run"
  pass "fm-pr-merge refuses a non-green PR unless --allow-red is explicit"
}

make_firstmate_review_case() {  # <name>
  local case_dir
  case_dir=$(make_case "$1")
  mkdir -p "$case_dir/wt"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$ROOT" \
    "kind=ship" \
    "mode=no-mistakes"
  add_gh_mocks "$case_dir" abcdefabcdefabcdefabcdefabcdefabcdefabcd
  : > "$case_dir/gh-axi.log"
  printf '%s\n' "$case_dir"
}

test_firstmate_merge_clears_a_stale_missing_review_receipt() {
  local case_dir
  case_dir=$(make_firstmate_review_case firstmate-review-passed)
  printf '%s\n' \
    'pr=https://github.com/example/firstmate/pull/127' \
    'missing_review_override_ts=2026-08-14T23:59:59Z' \
    >> "$case_dir/state/task-x1.meta"

  FM_FAKE_GH_REVIEWS="$(review_payload reviewer-one "$FM_REVIEW_HEAD" "$FM_REVIEW_LGTM")" \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/firstmate/pull/127 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "firstmate-review-passed: a qualifying review did not permit the merge"
  assert_merge_call "$case_dir" 127 example/firstmate \
    "firstmate-review-passed: merge did not run after the review qualified"
  assert_no_grep 'missing_review_override_ts=' "$case_dir/state/task-x1.meta" \
    "firstmate-review-passed: ordinary merge retained a stale override receipt"
  pass "fm-pr-merge clears a stale missing-review receipt on a reviewed merge"
}

# A merge attempt that refuses still refreshes PR identity through
# fm-pr-check.sh first. Only the ordinary reviewed merge retires the receipt, so
# a refusal in between must leave the authorized override on the record.
test_firstmate_merge_preserves_override_receipt_across_identity_refresh() {
  local case_dir rc
  case_dir=$(make_firstmate_review_case firstmate-review-receipt-preserved)
  printf '%s\n' \
    'pr=https://github.com/example/firstmate/pull/127' \
    'missing_review_override_ts=2026-08-14T23:59:59Z' \
    >> "$case_dir/state/task-x1.meta"

  set +e
  FM_FAKE_GH_REVIEWS="$(review_payload reviewer-one "$FM_REVIEW_HEAD" "$FM_REVIEW_LGTM")" \
  FM_FAKE_GH_CHECKS_SUMMARY='2 passed, 1 failed, 3 total' FM_FAKE_GH_MERGEABLE=false \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/firstmate/pull/127 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "firstmate-review-receipt-preserved: non-green PR should refuse"
  assert_no_merge_call "$case_dir" \
    "firstmate-review-receipt-preserved: merge ran on a non-green PR"
  grep -qxF 'pr=https://github.com/example/firstmate/pull/127' "$case_dir/state/task-x1.meta" \
    || fail "firstmate-review-receipt-preserved: PR identity was not refreshed"
  assert_grep 'missing_review_override_ts=2026-08-14T23:59:59Z' "$case_dir/state/task-x1.meta" \
    "firstmate-review-receipt-preserved: identity refresh dropped the authorized override receipt"
  pass "fm-pr-merge preserves an override receipt across a PR identity refresh"
}

# The override was authorized against one pull request. Re-pointing the task at
# a different one must not carry that authorization onto a PR that never had it.
test_firstmate_merge_drops_override_receipt_when_the_pr_changes() {
  local case_dir rc
  case_dir=$(make_firstmate_review_case firstmate-review-receipt-other-pr)
  printf '%s\n' \
    'pr=https://github.com/example/firstmate/pull/127' \
    'missing_review_override_ts=2026-08-14T23:59:59Z' \
    >> "$case_dir/state/task-x1.meta"

  set +e
  FM_FAKE_GH_REVIEWS="$(review_payload reviewer-one "$FM_REVIEW_HEAD" "$FM_REVIEW_LGTM")" \
  FM_FAKE_GH_CHECKS_SUMMARY='2 passed, 1 failed, 3 total' FM_FAKE_GH_MERGEABLE=false \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/firstmate/pull/931 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "firstmate-review-receipt-other-pr: non-green PR should refuse"
  grep -qxF 'pr=https://github.com/example/firstmate/pull/931' "$case_dir/state/task-x1.meta" \
    || fail "firstmate-review-receipt-other-pr: PR identity was not re-pointed"
  assert_no_grep 'missing_review_override_ts=' "$case_dir/state/task-x1.meta" \
    "firstmate-review-receipt-other-pr: an override authorized for another PR was carried forward"
  assert_grep 'https://github.com/example/firstmate/pull/127' "$case_dir/stderr" \
    "firstmate-review-receipt-other-pr: the discarded authorization did not name the PR it was granted for"
  assert_grep 'https://github.com/example/firstmate/pull/931' "$case_dir/stderr" \
    "firstmate-review-receipt-other-pr: the notice did not name the PR that now needs its own authorization"
  pass "fm-pr-merge drops an override receipt when the task re-points at another PR"
}

# The same authorization, refreshed against the PR it was granted for, must
# survive without the discard notice: the notice reports a real loss, not noise
# on every refresh.
test_firstmate_merge_keeps_a_same_pr_receipt_without_a_discard_notice() {
  local case_dir rc
  case_dir=$(make_firstmate_review_case firstmate-review-receipt-same-pr-quiet)
  printf '%s\n' \
    'pr=https://github.com/example/firstmate/pull/127' \
    'missing_review_override_ts=2026-08-14T23:59:59Z' \
    >> "$case_dir/state/task-x1.meta"

  set +e
  FM_FAKE_GH_REVIEWS="$(review_payload reviewer-one "$FM_REVIEW_HEAD" "$FM_REVIEW_LGTM")" \
  FM_FAKE_GH_CHECKS_SUMMARY='2 passed, 1 failed, 3 total' FM_FAKE_GH_MERGEABLE=false \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/firstmate/pull/127 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "firstmate-review-receipt-same-pr-quiet: non-green PR should refuse"
  assert_grep 'missing_review_override_ts=2026-08-14T23:59:59Z' "$case_dir/state/task-x1.meta" \
    "firstmate-review-receipt-same-pr-quiet: the authorization for this PR was dropped"
  assert_no_grep 'discarding the captain-authorized missing-Review override' "$case_dir/stderr" \
    "firstmate-review-receipt-same-pr-quiet: a surviving authorization was reported as discarded"
  pass "fm-pr-merge keeps a same-PR override receipt and reports no discard"
}

test_firstmate_merge_removes_staged_receipt_when_publish_fails() {
  local case_dir rc
  case_dir=$(make_firstmate_review_case firstmate-review-override-publish-fails)
  add_override_receipt_publish_failure "$case_dir"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/firstmate/pull/127 --allow-missing-review \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "firstmate-review-override-publish-fails: merge should refuse"
  assert_grep 'could not record the captain-authorized missing-Review override' \
    "$case_dir/stderr" "firstmate-review-override-publish-fails: refusal did not name the receipt failure"
  assert_no_merge_call "$case_dir" \
    "firstmate-review-override-publish-fails: merge ran without a durable override receipt"
  assert_no_grep 'missing_review_override_ts=' "$case_dir/state/task-x1.meta" \
    "firstmate-review-override-publish-fails: failed publish left a false receipt"
  assert_no_staged_merge_meta "$case_dir" \
    "firstmate-review-override-publish-fails: staged metadata was left behind in state/"
  pass "fm-pr-merge removes its staged metadata when the receipt publish fails"
}

# The merge and check scripts both install an EXIT trap that would hide a leak,
# so the library's own promise - it never leaves a staged file behind for a
# caller to sweep up - is only observable with no trap installed at all.
test_meta_rewrite_removes_its_staged_file_without_a_caller_trap() {
  local case_dir rc
  case_dir=$(make_case meta-rewrite-self-cleanup)
  printf '%s\n' 'window=fm-task-x1' 'pr=https://github.com/example/firstmate/pull/127' \
    > "$case_dir/state/task-x1.meta"
  chmod 0600 "$case_dir/state/task-x1.meta"

  set +e
  bash -c '
    . "$1/bin/fm-pr-lib.sh"
    refuse_identity() { return 1; }
    fm_pr_meta_rewrite "$2/state/task-x1.meta" "$2/state" .fm-pr-merge-meta \
      pr:missing_review_override_ts refuse_identity \
      "pr=https://github.com/example/firstmate/pull/127"
  ' _ "$ROOT" "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "meta-rewrite-self-cleanup: a refused identity check should fail the rewrite"
  assert_no_staged_merge_meta "$case_dir" \
    "meta-rewrite-self-cleanup: the rewrite left its staged file for a caller trap to sweep up"
  pass "fm_pr_meta_rewrite removes its own staged metadata with no caller trap installed"
}

test_firstmate_merge_removes_staged_receipt_when_interrupted() {
  local case_dir rc
  case_dir=$(make_firstmate_review_case firstmate-review-override-interrupted)
  add_override_receipt_signal_during_staging "$case_dir"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/firstmate/pull/127 --allow-missing-review \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "firstmate-review-override-interrupted: a signal during staging should refuse"
  assert_no_merge_call "$case_dir" \
    "firstmate-review-override-interrupted: merge ran after the run was interrupted"
  assert_no_staged_merge_meta "$case_dir" \
    "firstmate-review-override-interrupted: interrupted staging left metadata in state/"
  pass "fm-pr-merge removes its staged metadata when interrupted mid-write"
}

# An absent or unresolvable project= is "cannot tell", not "another project":
# a broken meta must not be a silent way past the Review receipt guard.
test_firstmate_merge_guards_unresolvable_project() {
  local case_dir rc
  case_dir=$(make_firstmate_review_case firstmate-review-unresolvable-project)
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/vanished-project" \
    "kind=ship" \
    "mode=no-mistakes"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/firstmate/pull/127 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "firstmate-review-unresolvable-project: unresolvable project should refuse"
  assert_grep "could not resolve this task's project as a repository" "$case_dir/stderr" \
    "firstmate-review-unresolvable-project: the unresolvable project was not disclosed"
  assert_no_merge_call "$case_dir" \
    "firstmate-review-unresolvable-project: merge ran without a Review receipt"
  pass "fm-pr-merge guards a task whose project cannot be resolved"
}

test_other_project_merge_skips_the_review_guard() {
  local case_dir
  case_dir=$(make_case other-project-unguarded)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/31 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "other-project-unguarded: a task in another repository should merge without a Review receipt"
  assert_merge_call "$case_dir" 31 example/repo \
    "other-project-unguarded: merge did not run for a task outside this repository"
  assert_no_grep "could not resolve this task's project" "$case_dir/stderr" \
    "other-project-unguarded: a resolvable other project was reported as unresolvable"
  pass "fm-pr-merge leaves another repository's merge unguarded"
}

test_firstmate_merge_missing_review_requires_distinct_override() {
  local case_dir rc
  case_dir=$(make_firstmate_review_case firstmate-review-override)

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/firstmate/pull/127 --allow-red \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "firstmate-review-override: --allow-red must not authorize a missing Review"
  assert_no_merge_call "$case_dir" \
    "firstmate-review-override: --allow-red bypassed the distinct Review guard"

  : > "$case_dir/gh-axi.log"
  run_pr_merge "$case_dir" task-x1 https://github.com/example/firstmate/pull/127 --allow-missing-review \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "firstmate-review-override: explicit missing-Review override did not permit the merge"
  assert_grep 'captain-authorized override: merging Firstmate PR without an independent review' \
    "$case_dir/stderr" "firstmate-review-override: override was not disclosed"
  grep -Eq '^missing_review_override_ts=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' \
    "$case_dir/state/task-x1.meta" \
    || fail "firstmate-review-override: durable override receipt was not recorded"
  [ "$(grep -c '^missing_review_override_ts=' "$case_dir/state/task-x1.meta")" -eq 1 ] \
    || fail "firstmate-review-override: durable override receipt was not singular"
  assert_merge_call "$case_dir" 127 example/firstmate \
    "firstmate-review-override: override was forwarded or merge did not run"
  pass "fm-pr-merge requires a distinct captain-authorized override for a missing Review"
}

test_firstmate_merge_refuses_when_override_receipt_cannot_be_written() {
  local case_dir rc
  case_dir=$(make_firstmate_review_case firstmate-review-override-write-fails)
  add_override_receipt_write_failure "$case_dir"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/firstmate/pull/127 --allow-missing-review \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "firstmate-review-override-write-fails: merge should refuse"
  assert_grep 'could not record the captain-authorized missing-Review override' \
    "$case_dir/stderr" "firstmate-review-override-write-fails: refusal did not name the receipt failure"
  assert_no_merge_call "$case_dir" \
    "firstmate-review-override-write-fails: merge ran without a durable override receipt"
  assert_no_grep 'missing_review_override_ts=' "$case_dir/state/task-x1.meta" \
    "firstmate-review-override-write-fails: failed write left a false receipt"
  pass "fm-pr-merge fails closed when its override receipt cannot be written"
}

# --- independent exact-head review evidence ---------------------------------
# The Firstmate merge gate's trust root is the structured review record the
# forge keeps, never the pull request body the change's own author writes.

FM_REVIEW_API_URL=https://api.github.com/repos/example/firstmate/pulls/127
FM_REVIEW_HEAD=abcdefabcdefabcdefabcdefabcdefabcdefabcd
FM_REVIEW_LGTM='LGTM ready for merge'

# One review record in the shape the reviews endpoint returns.
# Args: login commit_id body [state [submitted_at [id [pull_request_url]]]]
review_record() {
  local login=$1 commit=$2 body=$3 state=${4:-APPROVED}
  local submitted=${5:-2026-09-05T10:00:00Z} id=${6:-1} url=${7:-$FM_REVIEW_API_URL}
  jq -nc --arg login "$login" --arg commit "$commit" --arg body "$body" \
    --arg state "$state" --arg submitted "$submitted" --argjson id "$id" --arg url "$url" \
    '{state: $state, user: {login: $login}, commit_id: $commit, body: $body,
      submitted_at: $submitted, id: $id, pull_request_url: $url}'
}

# The canonical reviews URL for a pull request other than the fixture's own.
review_api_url() {  # <owner/repo> <number>
  printf 'https://api.github.com/repos/%s/pulls/%s\n' "$1" "$2"
}

# A one-record reviews payload, the ordinary qualifying shape.
review_payload() {
  local login=$1 commit=$2 body=$3 url=${4:-$FM_REVIEW_API_URL}
  jq -nc --argjson r "$(review_record "$login" "$commit" "$body" APPROVED 2026-09-05T10:00:00Z 1 "$url")" '[$r]'
}

# A reviews payload built from records already rendered by review_record.
review_payload_of() {
  local joined='' record
  for record in "$@"; do
    joined="${joined:+$joined,}$record"
  done
  printf '[%s]\n' "$joined"
}

# Neither merge spelling ran: the exact-head API seam nor the CLI merge.
assert_no_merge_call() {  # <case-dir> <msg>
  local case_dir=$1 msg=$2
  ! grep -Eq '^(pr merge |api PUT )' "$case_dir/gh-axi.log" || fail "$msg"
}

# The merge reached the forge for this pull request, bound to some live head.
assert_merge_call() {  # <case-dir> <number> <owner/repo> <msg> [<method>]
  local case_dir=$1 number=$2 repo=$3 msg=$4 method=${5:-squash}
  grep -Eq "^api PUT /repos/$repo/pulls/$number/merge --field sha=[0-9a-f]{40} --field merge_method=$method( |$)" \
    "$case_dir/gh-axi.log" || fail "$msg"
}

# The merge reached the forge through the seam that carries the reviewed head.
assert_merge_seam_call() {  # <case-dir> <number> <owner/repo> <head> <msg>
  local case_dir=$1 number=$2 repo=$3 head=$4 msg=$5
  grep -qxF "api PUT /repos/$repo/pulls/$number/merge --field sha=$head --field merge_method=squash" \
    "$case_dir/gh-axi.log" || fail "$msg"
}

test_firstmate_merge_refuses_author_written_review_prose() {
  local case_dir rc
  case_dir=$(make_firstmate_review_case firstmate-review-author-prose)

  set +e
  FM_FAKE_GH_PR_BODY="<summary>✅ **Review** - passed</summary> $FM_REVIEW_LGTM" \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/firstmate/pull/127 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "firstmate-review-author-prose: author-written body prose satisfied the review gate"
  assert_grep 'refusing Firstmate merge without an independent review' "$case_dir/stderr" \
    "firstmate-review-author-prose: refusal did not name the missing independent review"
  assert_no_merge_call "$case_dir" \
    "firstmate-review-author-prose: merge ran on the strength of the author's own prose"
  pass "fm-pr-merge refuses a Firstmate merge backed only by author-written body prose"
}

test_firstmate_merge_accepts_exact_head_independent_review() {
  local case_dir
  case_dir=$(make_firstmate_review_case firstmate-review-independent)

  FM_FAKE_GH_REVIEWS="$(review_payload reviewer-one "$FM_REVIEW_HEAD" "$FM_REVIEW_LGTM")" \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/firstmate/pull/127 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "firstmate-review-independent: an exact-head independent review did not permit the merge"

  assert_merge_seam_call "$case_dir" 127 example/firstmate "$FM_REVIEW_HEAD" \
    "firstmate-review-independent: the merge did not reach the exact-head seam"
  pass "fm-pr-merge accepts one independent structured review at the exact head"
}

test_firstmate_merge_refuses_unqualified_review_evidence() {
  local case_dir reviews label i=0
  # Each payload fails exactly one requirement, so no case can pass for the
  # reason another one was meant to prove.
  local -a cases=(
    "author-authored:$(review_payload pr-author "$FM_REVIEW_HEAD" "$FM_REVIEW_LGTM")"
    "stale-head:$(review_payload reviewer-one 1111111111111111111111111111111111111111 "$FM_REVIEW_LGTM")"
    "no-verdict:$(review_payload reviewer-one "$FM_REVIEW_HEAD" 'looks fine to me')"
    "commented-only:$(review_payload_of "$(review_record reviewer-one "$FM_REVIEW_HEAD" "$FM_REVIEW_LGTM" COMMENTED)")"
    "empty:[]"
  )
  local entry rc
  for entry in "${cases[@]}"; do
    label=${entry%%:*}
    reviews=${entry#*:}
    i=$((i + 1))
    case_dir=$(make_firstmate_review_case "firstmate-review-unqualified-$i")

    set +e
    FM_FAKE_GH_REVIEWS="$reviews" \
      run_pr_merge "$case_dir" task-x1 https://github.com/example/firstmate/pull/127 \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    expect_code 1 "$rc" "firstmate-review-unqualified/$label: unqualified review evidence permitted the merge"
    assert_grep 'refusing Firstmate merge without an independent review' "$case_dir/stderr" \
      "firstmate-review-unqualified/$label: refusal did not name the missing independent review"
    assert_no_merge_call "$case_dir" \
      "firstmate-review-unqualified/$label: merge ran on unqualified review evidence"
  done
  pass "fm-pr-merge refuses every unqualified shape of GitHub review evidence"
}

test_firstmate_merge_refuses_unreadable_review_evidence() {
  local case_dir rc
  case_dir=$(make_firstmate_review_case firstmate-review-unreadable)

  set +e
  FM_FAKE_GH_REVIEWS_UNREADABLE=1 \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/firstmate/pull/127 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "firstmate-review-unreadable: unreadable review evidence permitted the merge"
  assert_grep 'could not be read or validated' "$case_dir/stderr" \
    "firstmate-review-unreadable: an unreadable endpoint was not distinguished from an absence"
  assert_no_merge_call "$case_dir" \
    "firstmate-review-unreadable: merge ran without readable review evidence"
  pass "fm-pr-merge refuses when the GitHub review evidence cannot be read"
}

test_firstmate_merge_missing_review_override_still_escapes() {
  local case_dir
  case_dir=$(make_firstmate_review_case firstmate-review-structured-override)

  run_pr_merge "$case_dir" task-x1 https://github.com/example/firstmate/pull/127 --allow-missing-review \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "firstmate-review-structured-override: the captain-authorized escape did not permit the merge"

  assert_merge_seam_call "$case_dir" 127 example/firstmate "$FM_REVIEW_HEAD" \
    "firstmate-review-structured-override: the override merge did not reach the exact-head seam"
  grep -Eq '^missing_review_override_ts=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' \
    "$case_dir/state/task-x1.meta" \
    || fail "firstmate-review-structured-override: no durable override receipt was recorded"
  pass "fm-pr-merge keeps the captain-only missing-review escape and its receipt"
}

# --- exact-head merge fence --------------------------------------------------

test_github_merge_refuses_a_head_that_moved_after_the_verdict() {
  local case_dir rc
  case_dir=$(make_firstmate_review_case firstmate-head-moved)

  set +e
  FM_FAKE_GH_REVIEWS="$(review_payload reviewer-one "$FM_REVIEW_HEAD" "$FM_REVIEW_LGTM")" \
  FM_FAKE_GH_HEAD_AT_MERGE=2222222222222222222222222222222222222222 \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/firstmate/pull/127 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  [ "$rc" -ne 0 ] || fail "firstmate-head-moved: a head that moved before the merge was merged anyway"
  assert_merge_seam_call "$case_dir" 127 example/firstmate "$FM_REVIEW_HEAD" \
    "firstmate-head-moved: the reviewed head never reached the merge seam"
  assert_grep 'Head branch was modified' "$case_dir/stderr" \
    "firstmate-head-moved: the forge's own head refusal was not surfaced"
  pass "fm-pr-merge lets the GitHub merge seam refuse a head that moved after the verdict"
}

test_github_merge_carries_the_live_head_for_any_project() {
  local case_dir
  case_dir=$(make_case github-head-fence-any-project)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 3131313131313131313131313131313131313131
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/91 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "github-head-fence-any-project: an unchanged head did not merge"

  assert_merge_seam_call "$case_dir" 91 example/repo 3131313131313131313131313131313131313131 \
    "github-head-fence-any-project: the merge did not carry the live head"
  pass "fm-pr-merge binds every GitHub merge it performs to the live head"
}

test_github_merge_refuses_an_unreadable_head() {
  local case_dir rc
  case_dir=$(make_case github-head-unreadable)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 3232323232323232323232323232323232323232
  : > "$case_dir/gh-axi.log"

  set +e
  FM_FAKE_GH_PR_UNREADABLE=1 \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/92 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-head-unreadable: an unreadable head permitted the merge"
  assert_no_merge_call "$case_dir" \
    "github-head-unreadable: merge ran without a readable head to bind it to"
  pass "fm-pr-merge refuses a GitHub merge whose head it cannot read"
}

# --- captain-authorized non-green override receipt --------------------------

test_allow_red_records_a_bound_override_receipt_before_the_merge() {
  local case_dir
  case_dir=$(make_case allow-red-receipt)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 4141414141414141414141414141414141414141
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/meta-at-merge"

  FM_FAKE_GH_CHECKS_SUMMARY='2 passed, 1 failed, 3 total' FM_FAKE_GH_MERGEABLE=false \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/93 --allow-red \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "allow-red-receipt: the captain-authorized override did not permit the merge"

  assert_grep 'red_override_pr=https://github.com/example/repo/pull/93' "$case_dir/meta-at-merge" \
    "allow-red-receipt: the receipt was not bound to the exact PR before the merge"
  assert_grep 'red_override_head=4141414141414141414141414141414141414141' "$case_dir/meta-at-merge" \
    "allow-red-receipt: the receipt was not bound to the exact live head before the merge"
  assert_grep 'red_override_condition=' "$case_dir/meta-at-merge" \
    "allow-red-receipt: the receipt did not record the observed non-green condition"
  grep -Eq '^red_override_ts=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' \
    "$case_dir/meta-at-merge" \
    || fail "allow-red-receipt: the receipt carried no override timestamp before the merge"
  pass "fm-pr-merge records a PR- and head-bound non-green override receipt before merging"
}

test_allow_red_refuses_when_the_receipt_cannot_be_written() {
  local case_dir rc
  case_dir=$(make_case allow-red-receipt-write-fails)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 4242424242424242424242424242424242424242
  add_override_receipt_write_failure "$case_dir"
  : > "$case_dir/gh-axi.log"

  set +e
  FM_FAKE_GH_CHECKS_SUMMARY='2 passed, 1 failed, 3 total' FM_FAKE_GH_MERGEABLE=false \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/94 --allow-red \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "allow-red-receipt-write-fails: merge should refuse without a durable receipt"
  assert_grep 'could not record the captain-authorized non-green merge override' "$case_dir/stderr" \
    "allow-red-receipt-write-fails: refusal did not name the receipt failure"
  assert_no_merge_call "$case_dir" \
    "allow-red-receipt-write-fails: merge ran without a durable override receipt"
  assert_no_grep 'red_override_' "$case_dir/state/task-x1.meta" \
    "allow-red-receipt-write-fails: a failed write left a false receipt"
  pass "fm-pr-merge fails closed when the non-green override receipt cannot be written"
}

test_green_merge_clears_a_stale_red_override_receipt() {
  local case_dir
  case_dir=$(make_case allow-red-receipt-cleared)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 4343434343434343434343434343434343434343
  printf '%s\n' \
    'pr=https://github.com/example/repo/pull/95' \
    'red_override_ts=2026-08-14T23:59:59Z' \
    'red_override_pr=https://github.com/example/repo/pull/95' \
    'red_override_head=0000000000000000000000000000000000000000' \
    'red_override_condition=checks not green' \
    >> "$case_dir/state/task-x1.meta"
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/95 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "allow-red-receipt-cleared: an ordinary green merge failed"

  assert_no_grep 'red_override_' "$case_dir/state/task-x1.meta" \
    "allow-red-receipt-cleared: an ordinary green merge kept a stale override receipt"
  pass "fm-pr-merge clears a stale non-green override receipt on an ordinary green merge"
}
test_red_override_receipt_survives_an_identity_refresh() {
  local case_dir rc
  case_dir=$(make_case allow-red-receipt-preserved)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 4444444444444444444444444444444444444444
  printf '%s\n' \
    'pr=https://github.com/example/repo/pull/96' \
    'red_override_ts=2026-08-14T23:59:59Z' \
    'red_override_pr=https://github.com/example/repo/pull/96' \
    'red_override_head=4444444444444444444444444444444444444444' \
    'red_override_condition=checks not green' \
    >> "$case_dir/state/task-x1.meta"
  : > "$case_dir/gh-axi.log"

  set +e
  FM_FAKE_GH_CHECKS_SUMMARY='2 passed, 1 failed, 3 total' FM_FAKE_GH_MERGEABLE=false \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/96 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "allow-red-receipt-preserved: a non-green PR without --allow-red should refuse"
  assert_present "$case_dir/state/task-x1.check.sh" \
    "allow-red-receipt-preserved: the identity refresh never completed, so nothing was carried across one"
  assert_grep 'red_override_ts=2026-08-14T23:59:59Z' "$case_dir/state/task-x1.meta" \
    "allow-red-receipt-preserved: the identity refresh dropped the authorized override receipt"
  assert_grep 'red_override_condition=checks not green' "$case_dir/state/task-x1.meta" \
    "allow-red-receipt-preserved: the receipt lost the condition it was authorized against"
  pass "fm-pr-merge preserves a non-green override receipt across a PR identity refresh"
}

test_red_override_receipt_is_dropped_when_the_pr_changes() {
  local case_dir rc
  case_dir=$(make_case allow-red-receipt-other-pr)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 4545454545454545454545454545454545454545
  printf '%s\n' \
    'pr=https://github.com/example/repo/pull/97' \
    'red_override_ts=2026-08-14T23:59:59Z' \
    'red_override_pr=https://github.com/example/repo/pull/97' \
    'red_override_head=4545454545454545454545454545454545454545' \
    'red_override_condition=checks not green' \
    >> "$case_dir/state/task-x1.meta"
  : > "$case_dir/gh-axi.log"

  set +e
  FM_FAKE_GH_CHECKS_SUMMARY='2 passed, 1 failed, 3 total' FM_FAKE_GH_MERGEABLE=false \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/981 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "allow-red-receipt-other-pr: a non-green PR without --allow-red should refuse"
  assert_no_grep 'red_override_' "$case_dir/state/task-x1.meta" \
    "allow-red-receipt-other-pr: an override authorized for another PR was carried forward"
  assert_grep 'https://github.com/example/repo/pull/97' "$case_dir/stderr" \
    "allow-red-receipt-other-pr: the discarded authorization did not name the PR it was granted for"
  pass "fm-pr-merge drops a non-green override receipt when the task re-points at another PR"
}
test_partial_red_override_receipt_is_not_carried_forward() {
  local case_dir rc
  case_dir=$(make_case allow-red-receipt-partial)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 4646464646464646464646464646464646464646
  printf '%s\n' \
    'pr=https://github.com/example/repo/pull/98' \
    'red_override_ts=2026-08-14T23:59:59Z' \
    'red_override_pr=https://github.com/example/repo/pull/98' \
    >> "$case_dir/state/task-x1.meta"
  : > "$case_dir/gh-axi.log"

  set +e
  FM_FAKE_GH_CHECKS_SUMMARY='2 passed, 1 failed, 3 total' FM_FAKE_GH_MERGEABLE=false \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/98 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "allow-red-receipt-partial: a non-green PR without --allow-red should refuse"
  assert_no_grep 'red_override_' "$case_dir/state/task-x1.meta" \
    "allow-red-receipt-partial: half a receipt was carried forward as an authorization"
  pass "fm-pr-merge carries a non-green override receipt forward only as a complete record"
}
# The metadata lock is the established serialization owner for one task's
# record. Any writer that honours it must be honoured back, so this races the
# receipt against a writer holding that same lock and requires both updates to
# survive. The race is deterministic: the merge only starts once the lock is
# demonstrably held, and the holder publishes on a visible delay.
test_red_override_receipt_survives_a_concurrent_metadata_writer() {
  local case_dir writer_pid lock
  case_dir=$(make_case allow-red-receipt-race)
  mkdir -p "$case_dir/wt" "$case_dir/home"
  add_gh_mocks "$case_dir" 4747474747474747474747474747474747474747
  printf '%s\n' 'pr=https://github.com/example/repo/pull/99' \
    >> "$case_dir/state/task-x1.meta"
  : > "$case_dir/gh-axi.log"

  bash -c '
    . "$1/bin/fm-wake-lib.sh"
    meta=$2/task-x1.meta
    lock=$(fm_meta_lock_path "$meta") || exit 1
    fm_lock_acquire_wait "$lock"
    staged=$2/writer-staged
    { grep -v "^x_request=" "$meta" || true; } > "$staged"
    printf "x_request=race-1\n" >> "$staged"
    sleep 2
    mv -f "$staged" "$meta"
    chmod 0600 "$meta"
    fm_lock_release "$lock"
  ' _ "$ROOT" "$case_dir/state" &
  writer_pid=$!
  lock="$case_dir/state/.meta-task-x1.lock"
  until [ -e "$lock" ]; do sleep 0.05; done

  FM_FAKE_GH_CHECKS_SUMMARY='2 passed, 1 failed, 3 total' FM_FAKE_GH_MERGEABLE=false \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/99 --allow-red \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "allow-red-receipt-race: the authorized non-green merge failed"
  wait "$writer_pid" || fail "allow-red-receipt-race: the concurrent metadata writer failed"

  assert_grep 'x_request=race-1' "$case_dir/state/task-x1.meta" \
    "allow-red-receipt-race: the receipt write erased the concurrent writer's field"
  assert_grep 'red_override_ts=' "$case_dir/state/task-x1.meta" \
    "allow-red-receipt-race: the concurrent writer erased the authorized receipt"
  assert_grep 'red_override_head=4747474747474747474747474747474747474747' \
    "$case_dir/state/task-x1.meta" \
    "allow-red-receipt-race: the surviving receipt lost its head binding"
  pass "fm-pr-merge serializes its receipt write against a concurrent metadata writer"
}
# --- review adjudication ------------------------------------------------------
# The gate resolves reviews the way GitHub does, so a reviewer's standing at the
# exact head decides the merge rather than the presence of matching text.

test_firstmate_merge_refuses_a_non_approving_review_verdict() {
  local case_dir reviews label entry rc i=0
  local -a cases=(
    "changes-requested:$(review_payload_of "$(review_record reviewer-one "$FM_REVIEW_HEAD" "$FM_REVIEW_LGTM" CHANGES_REQUESTED)")"
    "dismissed:$(review_payload_of "$(review_record reviewer-one "$FM_REVIEW_HEAD" "$FM_REVIEW_LGTM" DISMISSED)")"
    "commented-only:$(review_payload_of "$(review_record reviewer-one "$FM_REVIEW_HEAD" "$FM_REVIEW_LGTM" COMMENTED)")"
    "pending:$(review_payload_of "$(review_record reviewer-one "$FM_REVIEW_HEAD" "$FM_REVIEW_LGTM" PENDING)")"
    "missing-state:[{\"user\":{\"login\":\"reviewer-one\"},\"commit_id\":\"$FM_REVIEW_HEAD\",\"body\":\"$FM_REVIEW_LGTM\",\"submitted_at\":\"2026-09-05T10:00:00Z\",\"id\":1,\"pull_request_url\":\"$FM_REVIEW_API_URL\"}]"
  )
  for entry in "${cases[@]}"; do
    label=${entry%%:*}
    reviews=${entry#*:}
    i=$((i + 1))
    case_dir=$(make_firstmate_review_case "firstmate-review-nonapproving-$i")

    set +e
    FM_FAKE_GH_REVIEWS="$reviews" \
      run_pr_merge "$case_dir" task-x1 https://github.com/example/firstmate/pull/127 \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    expect_code 1 "$rc" "firstmate-review-nonapproving/$label: a non-approving verdict permitted the merge"
    assert_no_merge_call "$case_dir" \
      "firstmate-review-nonapproving/$label: merge ran without an approving verdict"
  done
  pass "fm-pr-merge refuses a review whose state is not an approval"
}

test_firstmate_merge_refuses_a_changes_requested_verdict_outright() {
  local case_dir rc
  case_dir=$(make_firstmate_review_case firstmate-review-blocked)

  set +e
  FM_FAKE_GH_REVIEWS="$(review_payload_of \
    "$(review_record reviewer-one "$FM_REVIEW_HEAD" "$FM_REVIEW_LGTM" CHANGES_REQUESTED)")" \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/firstmate/pull/127 --allow-missing-review \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "firstmate-review-blocked: the missing-review escape overruled a reviewer asking for changes"
  assert_grep 'requests changes' "$case_dir/stderr" \
    "firstmate-review-blocked: the refusal did not name the blocking verdict"
  assert_no_merge_call "$case_dir" \
    "firstmate-review-blocked: merge ran while a reviewer had requested changes"
  assert_no_grep 'missing_review_override_ts=' "$case_dir/state/task-x1.meta" \
    "firstmate-review-blocked: a blocking verdict was recorded as a missing-review override"
  pass "fm-pr-merge refuses a changes-requested verdict outright, with no override path"
}

test_firstmate_merge_requires_the_verdict_on_its_own_line() {
  local case_dir body label entry rc i=0
  local -a cases=(
    "quoted:> $FM_REVIEW_LGTM"
    "negated:This is not $FM_REVIEW_LGTM yet, please fix the gate first."
    "embedded:I would say \"$FM_REVIEW_LGTM\" once the tests land."
    "prefixed:almost $FM_REVIEW_LGTM"
  )
  for entry in "${cases[@]}"; do
    label=${entry%%:*}
    body=${entry#*:}
    i=$((i + 1))
    case_dir=$(make_firstmate_review_case "firstmate-review-substring-$i")

    set +e
    FM_FAKE_GH_REVIEWS="$(review_payload reviewer-one "$FM_REVIEW_HEAD" "$body")" \
      run_pr_merge "$case_dir" task-x1 https://github.com/example/firstmate/pull/127 \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    expect_code 1 "$rc" "firstmate-review-substring/$label: verdict text inside a sentence authorized the merge"
    assert_no_merge_call "$case_dir" \
      "firstmate-review-substring/$label: merge ran on verdict text that was never a verdict"
  done

  # The same words on their own line, among other prose, still authorize it.
  case_dir=$(make_firstmate_review_case firstmate-review-standalone-line)
  FM_FAKE_GH_REVIEWS="$(review_payload reviewer-one "$FM_REVIEW_HEAD" \
    "Checked the fence and the receipt.

$FM_REVIEW_LGTM
")" \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/firstmate/pull/127 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "firstmate-review-standalone-line: a standalone verdict line did not permit the merge"
  assert_merge_call "$case_dir" 127 example/firstmate \
    "firstmate-review-standalone-line: the merge did not reach the head-bound seam"
  pass "fm-pr-merge requires the verdict as its own line, not as a substring"
}

test_firstmate_merge_uses_each_reviewer_latest_effective_verdict() {
  local case_dir rc

  # A reviewer who asked for changes and then approved at the same head has an
  # effective verdict of approved.
  case_dir=$(make_firstmate_review_case firstmate-review-latest-approves)
  FM_FAKE_GH_REVIEWS="$(review_payload_of \
    "$(review_record reviewer-one "$FM_REVIEW_HEAD" 'please fix the fence' CHANGES_REQUESTED 2026-09-05T10:00:00Z 1)" \
    "$(review_record reviewer-one "$FM_REVIEW_HEAD" "$FM_REVIEW_LGTM" APPROVED 2026-09-05T11:00:00Z 2)")" \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/firstmate/pull/127 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "firstmate-review-latest-approves: a later approval did not supersede the earlier request for changes"
  assert_merge_call "$case_dir" 127 example/firstmate \
    "firstmate-review-latest-approves: the merge did not reach the head-bound seam"

  # A later comment does not clear a standing approval.
  case_dir=$(make_firstmate_review_case firstmate-review-later-comment)
  FM_FAKE_GH_REVIEWS="$(review_payload_of \
    "$(review_record reviewer-one "$FM_REVIEW_HEAD" "$FM_REVIEW_LGTM" APPROVED 2026-09-05T10:00:00Z 1)" \
    "$(review_record reviewer-one "$FM_REVIEW_HEAD" 'one more thought' COMMENTED 2026-09-05T11:00:00Z 2)")" \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/firstmate/pull/127 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "firstmate-review-later-comment: a later comment cleared a standing approval"

  # An approval followed by a request for changes is blocked.
  case_dir=$(make_firstmate_review_case firstmate-review-latest-blocks)
  set +e
  FM_FAKE_GH_REVIEWS="$(review_payload_of \
    "$(review_record reviewer-one "$FM_REVIEW_HEAD" "$FM_REVIEW_LGTM" APPROVED 2026-09-05T10:00:00Z 1)" \
    "$(review_record reviewer-one "$FM_REVIEW_HEAD" 'found a defect' CHANGES_REQUESTED 2026-09-05T11:00:00Z 2)")" \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/firstmate/pull/127 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "firstmate-review-latest-blocks: a superseded approval still authorized the merge"
  assert_no_merge_call "$case_dir" \
    "firstmate-review-latest-blocks: merge ran after the reviewer withdrew the approval"

  # A second reviewer asking for changes blocks a colleague's approval.
  case_dir=$(make_firstmate_review_case firstmate-review-conflicting)
  set +e
  FM_FAKE_GH_REVIEWS="$(review_payload_of \
    "$(review_record reviewer-one "$FM_REVIEW_HEAD" "$FM_REVIEW_LGTM" APPROVED 2026-09-05T10:00:00Z 1)" \
    "$(review_record reviewer-two "$FM_REVIEW_HEAD" 'this is not ready' CHANGES_REQUESTED 2026-09-05T09:00:00Z 2)")" \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/firstmate/pull/127 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "firstmate-review-conflicting: an approval outvoted a standing request for changes"
  assert_no_merge_call "$case_dir" \
    "firstmate-review-conflicting: merge ran on conflicting exact-head evidence"
  pass "fm-pr-merge adjudicates each reviewer's latest effective verdict"
}
test_firstmate_merge_refuses_a_malformed_review_payload_outright() {
  local case_dir reviews label entry rc i=0
  # A malformed record is not filtered away: dropping it would let a later
  # negative verdict vanish and leave an older approval standing, so the whole
  # response refuses instead.
  local approval
  approval=$(review_record reviewer-one "$FM_REVIEW_HEAD" "$FM_REVIEW_LGTM" APPROVED 2026-09-05T10:00:00Z 1)
  local -a cases=(
    "malformed-later-negative:$(review_payload_of "$approval" "{\"state\":\"CHANGES_REQUESTED\",\"user\":{\"login\":\"reviewer-one\"},\"commit_id\":\"$FM_REVIEW_HEAD\",\"body\":12,\"submitted_at\":\"2026-09-05T11:00:00Z\",\"id\":2,\"pull_request_url\":\"$FM_REVIEW_API_URL\"}")"
    "later-negative-no-timestamp:$(review_payload_of "$approval" "{\"state\":\"CHANGES_REQUESTED\",\"user\":{\"login\":\"reviewer-one\"},\"commit_id\":\"$FM_REVIEW_HEAD\",\"body\":\"needs work\",\"submitted_at\":null,\"id\":2,\"pull_request_url\":\"$FM_REVIEW_API_URL\"}")"
    "later-negative-no-id:$(review_payload_of "$approval" "{\"state\":\"CHANGES_REQUESTED\",\"user\":{\"login\":\"reviewer-one\"},\"commit_id\":\"$FM_REVIEW_HEAD\",\"body\":\"needs work\",\"submitted_at\":\"2026-09-05T11:00:00Z\",\"id\":\"2\",\"pull_request_url\":\"$FM_REVIEW_API_URL\"}")"
    "later-negative-no-reviewer:$(review_payload_of "$approval" "{\"state\":\"CHANGES_REQUESTED\",\"user\":null,\"commit_id\":\"$FM_REVIEW_HEAD\",\"body\":\"needs work\",\"submitted_at\":\"2026-09-05T11:00:00Z\",\"id\":2,\"pull_request_url\":\"$FM_REVIEW_API_URL\"}")"
    "wrong-origin:$(review_payload reviewer-one "$FM_REVIEW_HEAD" "$FM_REVIEW_LGTM" https://attacker.invalid/repos/example/firstmate/pulls/127)"
    "wrong-origin-later-negative:$(review_payload_of "$approval" "{\"state\":\"CHANGES_REQUESTED\",\"user\":{\"login\":\"reviewer-one\"},\"commit_id\":\"$FM_REVIEW_HEAD\",\"body\":\"needs work\",\"submitted_at\":\"2026-09-05T11:00:00Z\",\"id\":2,\"pull_request_url\":\"https://attacker.invalid/repos/example/firstmate/pulls/127\"}")"
  )
  for entry in "${cases[@]}"; do
    label=${entry%%:*}
    reviews=${entry#*:}
    i=$((i + 1))
    case_dir=$(make_firstmate_review_case "firstmate-review-payload-$i")

    set +e
    FM_FAKE_GH_REVIEWS="$reviews" \
      run_pr_merge "$case_dir" task-x1 https://github.com/example/firstmate/pull/127 \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    expect_code 1 "$rc" "firstmate-review-payload/$label: a malformed review response authorized the merge"
    assert_grep 'could not be read or validated' "$case_dir/stderr" \
      "firstmate-review-payload/$label: invalid evidence was not distinguished from an absence"
    assert_no_merge_call "$case_dir" \
      "firstmate-review-payload/$label: merge ran on a review response that could not be read whole"
  done
  pass "fm-pr-merge refuses a review response it cannot validate whole"
}

test_firstmate_merge_refuses_ambiguously_ordered_reviews() {
  local case_dir rc
  case_dir=$(make_firstmate_review_case firstmate-review-ambiguous-order)

  set +e
  FM_FAKE_GH_REVIEWS="$(review_payload_of \
    "$(review_record reviewer-one "$FM_REVIEW_HEAD" "$FM_REVIEW_LGTM" APPROVED 2026-09-05T10:00:00Z 1)" \
    "$(review_record reviewer-one "$FM_REVIEW_HEAD" 'found a defect' CHANGES_REQUESTED 2026-09-05T10:00:00Z 1)")" \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/firstmate/pull/127 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "firstmate-review-ambiguous-order: two records at one position still produced a verdict"
  assert_grep 'share one ordering position' "$case_dir/stderr" \
    "firstmate-review-ambiguous-order: the refusal did not name the ambiguity"
  assert_no_merge_call "$case_dir" \
    "firstmate-review-ambiguous-order: merge ran with no readable latest verdict"
  pass "fm-pr-merge refuses reviews with no readable latest verdict"
}
test_firstmate_merge_refuses_semantically_malformed_review_metadata() {
  local case_dir reviews label entry rc i=0
  # Type-shaped but semantically impossible metadata is still evidence the gate
  # cannot trust, so each of these makes the response invalid rather than
  # qualifying or quietly dropping out of the adjudication.
  local -a cases=(
    "malformed-timestamp:$(review_payload_of "$(review_record reviewer-one "$FM_REVIEW_HEAD" "$FM_REVIEW_LGTM" APPROVED 'yesterday afternoon' 1)")"
    "fractional-id:$(review_payload_of "$(review_record reviewer-one "$FM_REVIEW_HEAD" "$FM_REVIEW_LGTM" APPROVED 2026-09-05T10:00:00Z 1.5)")"
    "zero-id:$(review_payload_of "$(review_record reviewer-one "$FM_REVIEW_HEAD" "$FM_REVIEW_LGTM" APPROVED 2026-09-05T10:00:00Z 0)")"
    "negative-id:$(review_payload_of "$(review_record reviewer-one "$FM_REVIEW_HEAD" "$FM_REVIEW_LGTM" APPROVED 2026-09-05T10:00:00Z -1)")"
    "malformed-login:$(review_payload_of "$(review_record 'reviewer one/../admin' "$FM_REVIEW_HEAD" "$FM_REVIEW_LGTM")")"
    "unknown-state:$(review_payload_of "$(review_record reviewer-one "$FM_REVIEW_HEAD" "$FM_REVIEW_LGTM" ENDORSED)")"
  )
  for entry in "${cases[@]}"; do
    label=${entry%%:*}
    reviews=${entry#*:}
    i=$((i + 1))
    case_dir=$(make_firstmate_review_case "firstmate-review-semantic-$i")

    set +e
    FM_FAKE_GH_REVIEWS="$reviews" \
      run_pr_merge "$case_dir" task-x1 https://github.com/example/firstmate/pull/127 \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    expect_code 1 "$rc" "firstmate-review-semantic/$label: unusable review metadata authorized the merge"
    assert_no_merge_call "$case_dir" \
      "firstmate-review-semantic/$label: merge ran on review metadata the gate cannot trust"
  done
  pass "fm-pr-merge refuses review metadata that is shaped right but cannot be true"
}

test_firstmate_merge_treats_a_case_variant_author_as_the_author() {
  local case_dir rc
  # GitHub account names are case-insensitive, so the author cannot vouch for
  # their own change by writing their login differently.
  case_dir=$(make_firstmate_review_case firstmate-review-case-variant-author)

  set +e
  FM_FAKE_GH_PR_AUTHOR=pr-author \
  FM_FAKE_GH_REVIEWS="$(review_payload PR-AUTHOR "$FM_REVIEW_HEAD" "$FM_REVIEW_LGTM")" \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/firstmate/pull/127 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "firstmate-review-case-variant-author: the author approved their own change"
  assert_grep 'without an independent review' "$case_dir/stderr" \
    "firstmate-review-case-variant-author: the refusal did not name the missing independent review"
  assert_no_merge_call "$case_dir" \
    "firstmate-review-case-variant-author: merge ran on the author's own approval"

  # The same reviewer's own case variants are one account, not two reviewers.
  case_dir=$(make_firstmate_review_case firstmate-review-case-variant-reviewer)
  set +e
  FM_FAKE_GH_REVIEWS="$(review_payload_of \
    "$(review_record Reviewer-One "$FM_REVIEW_HEAD" "$FM_REVIEW_LGTM" APPROVED 2026-09-05T10:00:00Z 1)" \
    "$(review_record reviewer-one "$FM_REVIEW_HEAD" 'found a defect' CHANGES_REQUESTED 2026-09-05T11:00:00Z 2)")" \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/firstmate/pull/127 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "firstmate-review-case-variant-reviewer: a case variant split one reviewer into two"
  assert_grep 'requests changes' "$case_dir/stderr" \
    "firstmate-review-case-variant-reviewer: the reviewer's later verdict did not supersede the earlier one"
  pass "fm-pr-merge treats one GitHub account as one identity whatever its case"
}

test_firstmate_merge_override_never_excuses_unreadable_evidence() {
  local case_dir reviews label entry rc i=0
  # The captain's escape is for a pull request the forge says no one reviewed.
  # Evidence that could not be read or validated is not that, so the escape
  # cannot stand in for it.
  local -a cases=(
    "malformed:[{\"state\":\"APPROVED\",\"user\":{\"login\":\"reviewer-one\"},\"commit_id\":\"$FM_REVIEW_HEAD\",\"body\":12,\"submitted_at\":\"2026-09-05T10:00:00Z\",\"id\":1,\"pull_request_url\":\"$FM_REVIEW_API_URL\"}]"
    "wrong-origin:$(review_payload reviewer-one "$FM_REVIEW_HEAD" "$FM_REVIEW_LGTM" https://attacker.invalid/repos/example/firstmate/pulls/127)"
    "not-an-array:{\"body\": \"$FM_REVIEW_LGTM\"}"
  )
  for entry in "${cases[@]}"; do
    label=${entry%%:*}
    reviews=${entry#*:}
    i=$((i + 1))
    case_dir=$(make_firstmate_review_case "firstmate-review-override-invalid-$i")

    set +e
    FM_FAKE_GH_REVIEWS="$reviews" \
      run_pr_merge "$case_dir" task-x1 https://github.com/example/firstmate/pull/127 --allow-missing-review \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    expect_code 1 "$rc" "firstmate-review-override-invalid/$label: the absence escape excused unreadable evidence"
    assert_grep 'could not be read or validated' "$case_dir/stderr" \
      "firstmate-review-override-invalid/$label: the refusal did not distinguish invalid evidence from absence"
    assert_no_merge_call "$case_dir" \
      "firstmate-review-override-invalid/$label: merge ran on evidence nothing could validate"
    assert_no_grep 'missing_review_override_ts=' "$case_dir/state/task-x1.meta" \
      "firstmate-review-override-invalid/$label: invalid evidence was recorded as an authorized absence"
  done

  # An unreadable reviews endpoint is the same class of failure.
  case_dir=$(make_firstmate_review_case firstmate-review-override-unavailable)
  set +e
  FM_FAKE_GH_REVIEWS_UNREADABLE=1 \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/firstmate/pull/127 --allow-missing-review \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "firstmate-review-override-unavailable: the absence escape excused an unreadable endpoint"
  assert_no_merge_call "$case_dir" \
    "firstmate-review-override-unavailable: merge ran without reaching the review evidence at all"

  # A successfully read, empty review list is the absence the escape is for.
  case_dir=$(make_firstmate_review_case firstmate-review-override-empty)
  FM_FAKE_GH_REVIEWS='[]' \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/firstmate/pull/127 --allow-missing-review \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "firstmate-review-override-empty: the escape no longer covers a validated absence"
  assert_merge_call "$case_dir" 127 example/firstmate \
    "firstmate-review-override-empty: the authorized merge did not reach the head-bound seam"
  pass "fm-pr-merge lets the absence escape act only on a validated absence"
}
test_review_guard_applies_unless_the_project_owns_the_pull_request() {
  local case_dir rc

  # A task from another repository paired with a Firstmate pull request is not
  # another repository's merge: the task never proves it owns this one.
  case_dir=$(make_case cross-project-firstmate-pr)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" abcdefabcdefabcdefabcdefabcdefabcdefabcd
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/firstmate/pull/127 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "cross-project-firstmate-pr: another project's task removed the review gate"
  assert_grep 'not proved to belong to it' "$case_dir/stderr" \
    "cross-project-firstmate-pr: the refusal did not name the missing task-to-repository binding"
  assert_no_merge_call "$case_dir" \
    "cross-project-firstmate-pr: merge ran with the review gate skipped by a foreign task"

  # A project that names no remote at all cannot prove ownership either.
  case_dir=$(make_case remoteless-project)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd
  git -C "$case_dir/project" remote remove origin 2>/dev/null || true
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/32 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "remoteless-project: an unbindable project still skipped the review gate"
  assert_no_merge_call "$case_dir" \
    "remoteless-project: merge ran without proving the project owns the pull request"

  # The canonical ssh spelling of the same repository still proves ownership.
  case_dir=$(make_case ssh-remote-project)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" dededededededededededededededededededede
  git -C "$case_dir/project" remote remove origin 2>/dev/null || true
  git -C "$case_dir/project" remote add origin 'git@github.com:example/repo.git' 2>/dev/null
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/33 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "ssh-remote-project: the canonical ssh origin was not recognised"
  assert_merge_call "$case_dir" 33 example/repo \
    "ssh-remote-project: the proved-ownership merge did not run"
  pass "fm-pr-merge skips the review gate only for a project that owns the pull request"
}

test_gitlab_refuses_every_deferred_merge_spelling() {
  local case_dir rc label entry flags i=0
  local -a cases=(
    'auto-merge:--auto-merge'
    'auto-merge-value:--auto-merge=true'
    'when-pipeline-succeeds:--when-pipeline-succeeds'
  )
  for entry in "${cases[@]}"; do
    label=${entry%%:*}
    flags=${entry#*:}
    i=$((i + 1))
    case_dir=$(make_gitlab_case "gitlab-deferred-$i")
    : > "$case_dir/glab.log"

    set +e
    # shellcheck disable=SC2086  # each fixture names its own argument list.
    run_pr_merge "$case_dir" task-x1 "$MR_URL" -- $flags \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    expect_code 1 "$rc" "gitlab-deferred/$label: a deferred GitLab merge was accepted"
    assert_no_grep 'mr merge' "$case_dir/glab.log" \
      "gitlab-deferred/$label: a deferred request reached the forge before refusing"
    assert_absent "$case_dir/state/task-x1.check.sh" \
      "gitlab-deferred/$label: a refused deferred merge still armed a poll"
    assert_no_grep "pr=$MR_URL" "$case_dir/state/task-x1.meta" \
      "gitlab-deferred/$label: a refused deferred merge still recorded PR metadata"
    assert_grep 'bind to the head it verified' "$case_dir/stderr" \
      "gitlab-deferred/$label: the refusal did not say why deferring is refused"
  done
  pass "fm-pr-merge refuses every deferred GitLab merge spelling before any mutation"
}
test_review_guard_ignores_a_remote_that_names_no_repository() {
  local case_dir rc
  # A URL the canonical origin owner refuses names no repository, so it can
  # never stand in as proof that this project owns the pull request.
  case_dir=$(make_case lookalike-remote)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" efefefefefefefefefefefefefefefefefefefef
  git -C "$case_dir/project" remote add bypass \
    'https://github.com:not-a-port/example/firstmate' 2>/dev/null
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/firstmate/pull/127 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "lookalike-remote: a malformed remote proved ownership"
  assert_grep 'not proved to belong to it' "$case_dir/stderr" \
    "lookalike-remote: the refusal did not name the missing task-to-repository binding"
  assert_no_merge_call "$case_dir" \
    "lookalike-remote: merge ran with the review gate skipped by a malformed remote"
  pass "fm-pr-merge proves repository ownership only from a canonical clone URL"
}

test_review_guard_requires_one_readable_project_identity() {
  local case_dir rc
  # Two project records are two answers to one question, so the run has no
  # exact-task snapshot to decide an exemption from.
  case_dir=$(make_case duplicate-project-identity)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0
  printf 'project=%s\n' "$case_dir/project" >> "$case_dir/state/task-x1.meta"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/35 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "duplicate-project-identity: an ambiguous task identity still exempted the merge"
  assert_grep 'exactly one project' "$case_dir/stderr" \
    "duplicate-project-identity: the refusal did not name the ambiguous identity"
  assert_no_merge_call "$case_dir" \
    "duplicate-project-identity: merge ran without one readable project identity"
  pass "fm-pr-merge requires one readable project identity before exempting a merge"
}

# The ownership decision is a metadata read, so it takes the same per-task lock
# every metadata writer uses. This case is a non-regression guard rather than a
# red-to-green regression: it holds that lock across a rewrite and requires the
# decision to reflect the project the writer committed, with the writer's own
# field intact. It cannot discriminate the lock itself, because the PR-identity
# transaction immediately before the decision already waits on the same lock,
# so an unserialized read would still land after this writer published.
test_review_guard_decides_from_the_committed_task_identity() {
  local case_dir writer_pid lock rc
  case_dir=$(make_case review-guard-lock)
  mkdir -p "$case_dir/wt" "$case_dir/home"
  add_gh_mocks "$case_dir" f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1
  git init --quiet "$case_dir/other-project" 2>/dev/null
  git -C "$case_dir/other-project" remote add origin \
    https://github.com/somewhere/else 2>/dev/null
  : > "$case_dir/gh-axi.log"

  bash -c '
    . "$1/bin/fm-wake-lib.sh"
    meta=$2/task-x1.meta
    lock=$(fm_meta_lock_path "$meta") || exit 1
    fm_lock_acquire_wait "$lock"
    staged=$2/writer-staged
    { grep -v "^project=" "$meta" || true; } > "$staged"
    printf "project=%s\n" "$3" >> "$staged"
    printf "x_request=guard-race\n" >> "$staged"
    sleep 2
    mv -f "$staged" "$meta"
    chmod 0600 "$meta"
    fm_lock_release "$lock"
  ' _ "$ROOT" "$case_dir/state" "$case_dir/other-project" &
  writer_pid=$!
  lock="$case_dir/state/.meta-task-x1.lock"
  until [ -e "$lock" ]; do sleep 0.05; done

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/36 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  wait "$writer_pid" || fail "review-guard-lock: the concurrent metadata writer failed"

  expect_code 1 "$rc" "review-guard-lock: the exemption was decided from a project the writer had replaced"
  assert_grep 'x_request=guard-race' "$case_dir/state/task-x1.meta" \
    "review-guard-lock: the concurrent writer's field did not survive"
  assert_grep "project=$case_dir/other-project" "$case_dir/state/task-x1.meta" \
    "review-guard-lock: the writer's committed project identity did not survive"
  assert_no_merge_call "$case_dir" \
    "review-guard-lock: merge ran on an exemption decided before the writer committed"
  pass "fm-pr-merge decides repository ownership from the committed task identity"
}

test_gitlab_refuses_arguments_it_cannot_bind() {
  local case_dir rc label entry flags i=0
  local -a cases=(
    'cancel-auto:--cancel-auto-merge'
    'conflicting-methods:--squash --rebase'
    'unknown-flag:--admin'
  )
  for entry in "${cases[@]}"; do
    label=${entry%%:*}
    flags=${entry#*:}
    i=$((i + 1))
    case_dir=$(make_gitlab_case "gitlab-unbindable-$i")
    : > "$case_dir/glab.log"

    set +e
    # shellcheck disable=SC2086  # each fixture names its own argument list.
    run_pr_merge "$case_dir" task-x1 "$MR_URL" -- $flags \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    expect_code 1 "$rc" "gitlab-unbindable/$label: an argument this script cannot bind was forwarded"
    assert_no_grep 'mr merge' "$case_dir/glab.log" \
      "gitlab-unbindable/$label: the argument reached the forge before refusing"
    assert_absent "$case_dir/state/task-x1.check.sh" \
      "gitlab-unbindable/$label: a refused argument still armed a poll"
    assert_no_grep "pr=$MR_URL" "$case_dir/state/task-x1.meta" \
      "gitlab-unbindable/$label: a refused argument still recorded PR metadata"
  done
  pass "fm-pr-merge refuses GitLab arguments it cannot bind to the verified head"
}
test_review_guard_proves_ownership_only_from_the_exact_origin() {
  local case_dir rc

  # An auxiliary remote is ordinary configuration anyone can add, so it can
  # never answer the question the origin answers.
  case_dir=$(make_case alternate-remote)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" f2f2f2f2f2f2f2f2f2f2f2f2f2f2f2f2f2f2f2f2
  git -C "$case_dir/project" remote add bypass \
    https://github.com/example/firstmate 2>/dev/null
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/firstmate/pull/127 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "alternate-remote: a non-origin remote proved ownership"
  assert_grep 'project origin is not' "$case_dir/stderr" \
    "alternate-remote: the refusal did not name the origin requirement"
  assert_no_merge_call "$case_dir" \
    "alternate-remote: merge ran with the review gate skipped by an auxiliary remote"

  # A port names a different endpoint even when host and path read the same.
  case_dir=$(make_case ported-origin)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" f3f3f3f3f3f3f3f3f3f3f3f3f3f3f3f3f3f3f3f3
  git -C "$case_dir/project" remote remove origin 2>/dev/null || true
  git -C "$case_dir/project" remote add origin \
    https://github.com:1234/example/firstmate 2>/dev/null
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/firstmate/pull/127 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "ported-origin: another endpoint on the same host proved ownership"
  assert_no_merge_call "$case_dir" \
    "ported-origin: merge ran with the review gate skipped by a ported origin"

  # A second origin URL is two answers to one question.
  case_dir=$(make_case two-origin-urls)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" f4f4f4f4f4f4f4f4f4f4f4f4f4f4f4f4f4f4f4f4
  git -C "$case_dir/project" config --add remote.origin.url \
    https://github.com/example/repo 2>/dev/null
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/37 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "two-origin-urls: an origin with two values still proved ownership"
  assert_no_merge_call "$case_dir" \
    "two-origin-urls: merge ran without one readable origin"
  pass "fm-pr-merge proves repository ownership only from one exact origin endpoint"
}

test_firstmate_merge_refuses_logins_github_could_not_issue() {
  local case_dir login label entry rc i=0
  # The pull request owner grammar this repository already enforces is the one
  # a reviewer identity has to satisfy too.
  local -a cases=(
    'underscore:reviewer_one'
    'dot:reviewer.one'
    'leading-hyphen:-reviewer'
    'trailing-hyphen:reviewer-'
    'double-hyphen:reviewer--one'
    'overlong:abcdefghijklmnopqrstuvwxyzabcdefghijklmn'
  )
  for entry in "${cases[@]}"; do
    label=${entry%%:*}
    login=${entry#*:}
    i=$((i + 1))
    case_dir=$(make_firstmate_review_case "firstmate-review-login-$i")

    set +e
    FM_FAKE_GH_REVIEWS="$(review_payload "$login" "$FM_REVIEW_HEAD" "$FM_REVIEW_LGTM")" \
      run_pr_merge "$case_dir" task-x1 https://github.com/example/firstmate/pull/127 \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    expect_code 1 "$rc" "firstmate-review-login/$label: a login GitHub could not issue authorized the merge"
    assert_grep 'could not be read or validated' "$case_dir/stderr" \
      "firstmate-review-login/$label: a malformed identity was not treated as invalid evidence"
    assert_no_merge_call "$case_dir" \
      "firstmate-review-login/$label: merge ran on a reviewer identity GitHub could not issue"
  done

  # The captain's absence escape cannot excuse one either.
  case_dir=$(make_firstmate_review_case firstmate-review-login-override)
  set +e
  FM_FAKE_GH_REVIEWS="$(review_payload reviewer--one "$FM_REVIEW_HEAD" "$FM_REVIEW_LGTM")" \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/firstmate/pull/127 --allow-missing-review \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "firstmate-review-login-override: the absence escape excused a malformed identity"
  assert_no_merge_call "$case_dir" \
    "firstmate-review-login-override: merge ran on evidence with an impossible reviewer"
  assert_no_grep 'missing_review_override_ts=' "$case_dir/state/task-x1.meta" \
    "firstmate-review-login-override: a malformed identity was recorded as an authorized absence"

  # An app's reviews keep their bot suffix on an otherwise canonical name.
  case_dir=$(make_firstmate_review_case firstmate-review-login-bot)
  FM_FAKE_GH_REVIEWS="$(review_payload 'dependabot[bot]' "$FM_REVIEW_HEAD" "$FM_REVIEW_LGTM")" \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/firstmate/pull/127 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "firstmate-review-login-bot: a canonical bot identity was refused"
  assert_merge_call "$case_dir" 127 example/firstmate \
    "firstmate-review-login-bot: the qualifying bot review did not reach the head-bound seam"
  pass "fm-pr-merge accepts only reviewer identities GitHub could have issued"
}

test_gitlab_refuses_a_rebase_or_a_repeated_option() {
  local case_dir rc label entry flags i=0
  local -a cases=(
    'rebase:--rebase'
    'repeat-squash:--squash --squash'
    'repeat-message:--message one --message two'
    'repeat-remove:--remove-source-branch --remove-source-branch'
    'repeat-yes:--yes --yes'
  )
  for entry in "${cases[@]}"; do
    label=${entry%%:*}
    flags=${entry#*:}
    i=$((i + 1))
    case_dir=$(make_gitlab_case "gitlab-repeat-$i")
    : > "$case_dir/glab.log"

    set +e
    # shellcheck disable=SC2086  # each fixture names its own argument list.
    run_pr_merge "$case_dir" task-x1 "$MR_URL" -- $flags \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    expect_code 1 "$rc" "gitlab-repeat/$label: an ambiguous or head-replacing request was forwarded"
    assert_no_grep 'mr merge' "$case_dir/glab.log" \
      "gitlab-repeat/$label: the request reached the forge before refusing"
    assert_absent "$case_dir/state/task-x1.check.sh" \
      "gitlab-repeat/$label: a refused request still armed a poll"
    assert_no_grep "pr=$MR_URL" "$case_dir/state/task-x1.meta" \
      "gitlab-repeat/$label: a refused request still recorded PR metadata"
  done

  # The caller's own confirmation flag is consumed, never repeated at the seam.
  local merge_line
  case_dir=$(make_gitlab_case gitlab-caller-yes)
  : > "$case_dir/glab.log"
  run_pr_merge "$case_dir" task-x1 "$MR_URL" -- --yes --squash \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "gitlab-caller-yes: a single caller confirmation flag was refused"
  merge_line=$(glab_merge_line "$case_dir/glab.log")
  [ "$merge_line" = "GITLAB_HOST=$MR_HOST mr merge 7 -R $MR_PROJECT_URL --sha $MR_HEAD --auto-merge=false --yes --squash" ] \
    || fail "gitlab-caller-yes: the caller's confirmation flag was forwarded beside this script's own: '$merge_line'"
  pass "fm-pr-merge refuses a GitLab rebase or repeated option and never doubles a flag"
}
test_review_guard_requires_a_canonical_origin_spelling() {
  local case_dir rc label entry url i=0
  # The exemption decides whether a mandatory review is skipped, so the origin
  # is compared byte for byte: a URL that merely normalizes to the right
  # repository is a different value, not the same repository.
  local -a cases=(
    'credentials:https://user:secret@github.com/example/repo'
    'upper-host:https://GITHUB.com/example/repo'
    'upper-path:https://github.com/Example/Repo'
    'insecure-scheme:http://github.com/example/repo'
    'noncanonical-scp:git@GitHub.com:Example/Repo.git'
    'trailing-git-slash:https://github.com/example/repo.git/'
  )
  for entry in "${cases[@]}"; do
    label=${entry%%:*}
    url=${entry#*:}
    i=$((i + 1))
    case_dir=$(make_case "noncanonical-origin-$i")
    mkdir -p "$case_dir/wt"
    add_gh_mocks "$case_dir" f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5
    git -C "$case_dir/project" remote remove origin 2>/dev/null || true
    git -C "$case_dir/project" remote add origin "$url" 2>/dev/null
    : > "$case_dir/gh-axi.log"

    set +e
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/38 \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    expect_code 1 "$rc" "noncanonical-origin/$label: a noncanonical origin proved ownership"
    assert_grep 'project origin is not' "$case_dir/stderr" \
      "noncanonical-origin/$label: the refusal did not name the origin requirement"
    assert_no_merge_call "$case_dir" \
      "noncanonical-origin/$label: merge ran with the review gate skipped by a lookalike origin"
  done

  # The canonical https spelling, with or without the .git suffix git itself
  # writes, is what ownership means.
  for url in https://github.com/example/repo https://github.com/example/repo.git; do
    i=$((i + 1))
    case_dir=$(make_case "canonical-origin-$i")
    mkdir -p "$case_dir/wt"
    add_gh_mocks "$case_dir" f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6f6
    git -C "$case_dir/project" remote remove origin 2>/dev/null || true
    git -C "$case_dir/project" remote add origin "$url" 2>/dev/null
    : > "$case_dir/gh-axi.log"

    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/39 \
      > "$case_dir/stdout" 2> "$case_dir/stderr" \
      || fail "canonical-origin: the canonical origin $url was not recognised"
    assert_merge_call "$case_dir" 39 example/repo \
      "canonical-origin: the proved-ownership merge did not run for $url"
  done
  pass "fm-pr-merge proves ownership only from a canonical origin spelling"
}

test_gitlab_refuses_alias_repeats_and_option_shaped_values() {
  local case_dir rc label entry flags i=0
  # An alias is the same operation as its long form, and a value position is
  # not a hiding place for an option this script refuses by name.
  local -a cases=(
    'alias-repeat:--remove-source-branch -d'
    'value-rebase:--message --rebase'
    'value-deferred:--message --auto-merge'
    'value-cancel:--message --cancel-auto-merge'
    'value-deferred-squash-message:--squash-message --when-pipeline-succeeds'
    'invalid-bool:--squash=garbage'
    'empty-value:--message='
    'yes-alias-repeat:--yes -y'
  )
  for entry in "${cases[@]}"; do
    label=${entry%%:*}
    flags=${entry#*:}
    i=$((i + 1))
    case_dir=$(make_gitlab_case "gitlab-confusion-$i")
    : > "$case_dir/glab.log"

    set +e
    # shellcheck disable=SC2086  # each fixture names its own argument list.
    run_pr_merge "$case_dir" task-x1 "$MR_URL" -- $flags \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    expect_code 1 "$rc" "gitlab-confusion/$label: an ambiguous or disguised request was forwarded"
    assert_no_grep 'mr merge' "$case_dir/glab.log" \
      "gitlab-confusion/$label: the request reached the forge before refusing"
    assert_absent "$case_dir/state/task-x1.check.sh" \
      "gitlab-confusion/$label: a refused request still armed a poll"
    assert_no_grep "pr=$MR_URL" "$case_dir/state/task-x1.meta" \
      "gitlab-confusion/$label: a refused request still recorded PR metadata"
  done

  # An ordinary value is still forwarded, as the caller's own words.
  local merge_line
  case_dir=$(make_gitlab_case gitlab-message-value)
  : > "$case_dir/glab.log"
  run_pr_merge "$case_dir" task-x1 "$MR_URL" -- --message 'land it' \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "gitlab-message-value: an ordinary commit message was refused"
  merge_line=$(glab_merge_line "$case_dir/glab.log")
  [ "$merge_line" = "GITLAB_HOST=$MR_HOST mr merge 7 -R $MR_PROJECT_URL --sha $MR_HEAD --auto-merge=false --yes --message land it" ] \
    || fail "gitlab-message-value: the caller's message did not reach the forge unchanged: '$merge_line'"
  pass "fm-pr-merge refuses GitLab alias repeats and option-shaped values"
}
test_review_guard_preserves_every_origin_record() {
  local case_dir rc label entry i=0
  # Command substitution strips trailing newlines, so a second empty origin and
  # a value carrying a newline both look like one clean value unless the
  # records keep their own terminators.
  for entry in empty-second trailing-newline; do
    label=$entry
    i=$((i + 1))
    case_dir=$(make_case "origin-records-$i")
    mkdir -p "$case_dir/wt"
    add_gh_mocks "$case_dir" f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7
    case "$label" in
      empty-second)
        git -C "$case_dir/project" config --add remote.origin.url '' 2>/dev/null
        ;;
      trailing-newline)
        git -C "$case_dir/project" config --unset-all remote.origin.url 2>/dev/null || true
        git -C "$case_dir/project" config --add remote.origin.url \
          'https://github.com/example/repo
' 2>/dev/null
        ;;
    esac
    : > "$case_dir/gh-axi.log"

    set +e
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/40 \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    expect_code 1 "$rc" "origin-records/$label: a malformed origin record proved ownership"
    assert_no_merge_call "$case_dir" \
      "origin-records/$label: merge ran with the review gate skipped by a collapsed origin record"
  done
  pass "fm-pr-merge keeps every origin record whole when deciding ownership"
}

test_merge_binds_to_the_repository_name_the_forge_reports() {
  local case_dir rc
  # GitHub repository names are case-insensitive, so two agreeing caller
  # strings are not evidence of how the repository is named.
  case_dir=$(make_case matched-case-variant)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8f8
  git -C "$case_dir/project" remote remove origin 2>/dev/null || true
  git -C "$case_dir/project" remote add origin https://github.com/Example/Repo 2>/dev/null
  : > "$case_dir/gh-axi.log"

  set +e
  FM_FAKE_GH_PR_BASE_REPO=example/repo \
    run_pr_merge "$case_dir" task-x1 https://github.com/Example/Repo/pull/41 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "matched-case-variant: two agreeing caller spellings became the repository identity"
  assert_grep 'which GitHub reports as example/repo' "$case_dir/stderr" \
    "matched-case-variant: the refusal did not name the forge's own repository identity"
  assert_no_merge_call "$case_dir" \
    "matched-case-variant: merge ran on a repository name the forge did not confirm"
  pass "fm-pr-merge binds every decision to the repository name GitHub reports"
}

test_gitlab_merge_states_immediate_mode() {
  local case_dir merge_line
  # glab enables auto-merge by default whenever the merge request has a
  # pipeline, so the wrapper has to say otherwise on every merge.
  case_dir=$(make_gitlab_case gitlab-immediate-mode)
  : > "$case_dir/glab.log"

  run_pr_merge "$case_dir" task-x1 "$MR_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "gitlab-immediate-mode: an ordinary GitLab merge failed"

  merge_line=$(glab_merge_line "$case_dir/glab.log")
  case "$merge_line" in
    *" --auto-merge=false "*) ;;
    *) fail "gitlab-immediate-mode: the merge did not state immediate mode: '$merge_line'" ;;
  esac
  pass "fm-pr-merge states GitLab immediate mode rather than accepting its default"
}

test_gitlab_refuses_inapplicable_and_invalid_requests() {
  local case_dir rc label entry i=0
  local -a cases=(
    'allow-red:--allow-red'
    'allow-missing-review:--allow-missing-review'
    'subject:-- --subject title'
    'squash-message-without-squash:-- --squash-message message'
  )
  local args
  for entry in "${cases[@]}"; do
    label=${entry%%:*}
    args=${entry#*:}
    i=$((i + 1))
    case_dir=$(make_gitlab_case "gitlab-inapplicable-$i")
    : > "$case_dir/glab.log"

    set +e
    # shellcheck disable=SC2086  # each fixture names its own argument list.
    run_pr_merge "$case_dir" task-x1 "$MR_URL" $args \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    expect_code 1 "$rc" "gitlab-inapplicable/$label: an inapplicable or invalid request was accepted"
    assert_no_grep 'mr merge' "$case_dir/glab.log" \
      "gitlab-inapplicable/$label: the request reached the forge before refusing"
    assert_absent "$case_dir/state/task-x1.check.sh" \
      "gitlab-inapplicable/$label: a refused request still armed a poll"
    assert_no_grep "pr=$MR_URL" "$case_dir/state/task-x1.meta" \
      "gitlab-inapplicable/$label: a refused request still recorded PR metadata"
  done

  # A squash message alongside its squash is the supported combination.
  local merge_line
  case_dir=$(make_gitlab_case gitlab-squash-message)
  : > "$case_dir/glab.log"
  run_pr_merge "$case_dir" task-x1 "$MR_URL" -- --squash --squash-message tidy \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "gitlab-squash-message: a squash message with its squash was refused"
  merge_line=$(glab_merge_line "$case_dir/glab.log")
  [ "$merge_line" = "GITLAB_HOST=$MR_HOST mr merge 7 -R $MR_PROJECT_URL --sha $MR_HEAD --auto-merge=false --yes --squash --squash-message tidy" ] \
    || fail "gitlab-squash-message: the supported combination did not reach the forge unchanged: '$merge_line'"
  pass "fm-pr-merge refuses GitLab requests it cannot apply, before recording anything"
}
test_firstmate_merge_validates_raw_review_identity() {
  local case_dir rc
  # Lowercasing a login is an adjudication convenience, not evidence: a suffix
  # the forge does not write is still one the forge did not write.
  case_dir=$(make_firstmate_review_case firstmate-review-uppercase-bot)

  set +e
  FM_FAKE_GH_REVIEWS="$(review_payload 'dependabot[BOT]' "$FM_REVIEW_HEAD" "$FM_REVIEW_LGTM")" \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/firstmate/pull/127 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "firstmate-review-uppercase-bot: normalization turned an impossible login into a valid one"
  assert_grep 'could not be read or validated' "$case_dir/stderr" \
    "firstmate-review-uppercase-bot: the raw identity was not treated as invalid evidence"
  assert_no_merge_call "$case_dir" \
    "firstmate-review-uppercase-bot: merge ran on a login GitHub could not have issued"

  # The absence escape cannot excuse it either.
  case_dir=$(make_firstmate_review_case firstmate-review-uppercase-bot-override)
  set +e
  FM_FAKE_GH_REVIEWS="$(review_payload 'dependabot[BOT]' "$FM_REVIEW_HEAD" "$FM_REVIEW_LGTM")" \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/firstmate/pull/127 --allow-missing-review \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "firstmate-review-uppercase-bot-override: the absence escape excused a raw identity failure"
  assert_no_grep 'missing_review_override_ts=' "$case_dir/state/task-x1.meta" \
    "firstmate-review-uppercase-bot-override: an impossible login was recorded as an authorized absence"
  pass "fm-pr-merge judges a reviewer identity as the forge spelled it"
}

test_firstmate_merge_validates_every_review_commit() {
  local case_dir rc
  # A commit identifier the forge could not have issued is unreadable evidence,
  # not evidence about some other head.
  case_dir=$(make_firstmate_review_case firstmate-review-malformed-commit)

  set +e
  FM_FAKE_GH_REVIEWS="$(review_payload reviewer-one 'not-a-sha' "$FM_REVIEW_LGTM")" \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/firstmate/pull/127 --allow-missing-review \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "firstmate-review-malformed-commit: a malformed commit became an overridable absence"
  assert_no_merge_call "$case_dir" \
    "firstmate-review-malformed-commit: merge ran on evidence with no readable commit"
  assert_no_grep 'missing_review_override_ts=' "$case_dir/state/task-x1.meta" \
    "firstmate-review-malformed-commit: invalid evidence was recorded as an authorized absence"

  # A malformed later negative verdict cannot vanish behind an older approval.
  case_dir=$(make_firstmate_review_case firstmate-review-malformed-later-commit)
  set +e
  FM_FAKE_GH_REVIEWS="$(review_payload_of \
    "$(review_record reviewer-one "$FM_REVIEW_HEAD" "$FM_REVIEW_LGTM" APPROVED 2026-09-05T10:00:00Z 1)" \
    "$(review_record reviewer-one 'not-a-sha' 'found a defect' CHANGES_REQUESTED 2026-09-05T11:00:00Z 2)")" \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/firstmate/pull/127 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "firstmate-review-malformed-later-commit: a malformed negative verdict was filtered away"
  assert_no_merge_call "$case_dir" \
    "firstmate-review-malformed-later-commit: merge ran on a superseded approval"
  pass "fm-pr-merge refuses a review commit GitHub could not have issued"
}

test_github_refuses_repeated_commit_text_options() {
  local case_dir rc label entry flags i=0
  local -a cases=(
    'subject-twice:--subject first --subject second'
    'body-twice:--body first --body second'
    'body-mixed-form:--body first --body-file /dev/null'
  )
  for entry in "${cases[@]}"; do
    label=${entry%%:*}
    flags=${entry#*:}
    i=$((i + 1))
    case_dir=$(make_case "github-commit-text-$i")
    mkdir -p "$case_dir/wt"
    add_gh_mocks "$case_dir" f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9f9
    : > "$case_dir/gh-axi.log"

    set +e
    # shellcheck disable=SC2086  # each fixture names its own argument list.
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/42 -- $flags \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    expect_code 1 "$rc" "github-commit-text/$label: two values for one commit field were resolved silently"
    assert_grep 'more than once' "$case_dir/stderr" \
      "github-commit-text/$label: the refusal did not name the ambiguity"
    assert_no_merge_call "$case_dir" \
      "github-commit-text/$label: merge ran with ambiguous commit text"
    assert_absent "$case_dir/state/task-x1.check.sh" \
      "github-commit-text/$label: an ambiguous request still armed a poll"
  done
  pass "fm-pr-merge refuses two values for one GitHub commit-text field"
}

test_github_case_mismatch_records_nothing() {
  local case_dir rc
  # A request the forge does not confirm must leave the task exactly as it was.
  case_dir=$(make_case case-mismatch-records-nothing)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" fafafafafafafafafafafafafafafafafafafafa
  printf '%s\n' 'pr=https://github.com/example/repo/pull/1' \
    >> "$case_dir/state/task-x1.meta"
  : > "$case_dir/gh-axi.log"

  set +e
  FM_FAKE_GH_PR_BASE_REPO=example/repo \
    run_pr_merge "$case_dir" task-x1 https://github.com/Example/Repo/pull/92 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "case-mismatch-records-nothing: a rejected identity was accepted"
  assert_no_merge_call "$case_dir" \
    "case-mismatch-records-nothing: merge ran on a repository name the forge did not confirm"
  assert_grep 'pr=https://github.com/example/repo/pull/1' "$case_dir/state/task-x1.meta" \
    "case-mismatch-records-nothing: the rejected request re-pointed the task"
  assert_no_grep 'pr=https://github.com/Example/Repo/pull/92' "$case_dir/state/task-x1.meta" \
    "case-mismatch-records-nothing: the rejected identity was recorded"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "case-mismatch-records-nothing: the rejected identity armed a poll"
  pass "fm-pr-merge records nothing for an identity the forge does not confirm"
}

# The receipt authorizes one merge of one pull request, so the task cannot be
# re-pointed between writing it and the mutation it authorizes. This pauses the
# forge seam after the receipt is written, has the public PR-recording
# entrypoint try to re-point the task at another pull request - which also
# drops this receipt - and requires that attempt to be blocked until the merge
# has consumed what authorized it.
test_red_receipt_holds_the_task_through_the_merge() {
  local case_dir repoint_pid rc
  case_dir=$(make_case receipt-through-merge)
  mkdir -p "$case_dir/wt" "$case_dir/home"
  add_gh_mocks "$case_dir" fbfbfbfbfbfbfbfbfbfbfbfbfbfbfbfbfbfbfbfb
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/meta-at-merge"

  set +e
  FM_FAKE_GH_HOLD_MERGE=1 \
  FM_FAKE_GH_CHECKS_SUMMARY='2 passed, 1 failed, 3 total' FM_FAKE_GH_MERGEABLE=false \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/43 --allow-red \
    > "$case_dir/stdout" 2> "$case_dir/stderr" &
  local merge_pid=$!
  set -e
  until [ -e "$case_dir/merge-reached" ]; do sleep 0.05; done

  # The receipt is written and the merge is at the forge boundary. A concurrent
  # re-point must not land in this window.
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$case_dir/home" FM_STATE_OVERRIDE="$case_dir/state" \
  PATH="$case_dir/policybin:$case_dir/fakebin:$PATH" \
    "$ROOT/bin/fm-pr-check.sh" task-x1 https://github.com/example/repo/pull/999 \
    > "$case_dir/repoint.out" 2> "$case_dir/repoint.err" &
  repoint_pid=$!
  sleep 1
  : > "$case_dir/release-merge"

  wait "$merge_pid" || rc=$?
  wait "$repoint_pid" >/dev/null 2>&1 || true

  assert_grep 'red_override_head=fbfbfbfbfbfbfbfbfbfbfbfbfbfbfbfbfbfbfbfb' "$case_dir/meta-at-merge" \
    "receipt-through-merge: the merge did not carry the receipt it was authorized by"
  assert_grep 'pr=https://github.com/example/repo/pull/43' "$case_dir/meta-at-merge" \
    "receipt-through-merge: the task was re-pointed before the merge consumed its receipt"
  assert_no_grep 'pr=https://github.com/example/repo/pull/999' "$case_dir/meta-at-merge" \
    "receipt-through-merge: another pull request replaced this one at the mutation"
  pass "fm-pr-merge holds the task record from its receipt through the merge"
}
# A refusal that says this pull request's metadata and poll remain recorded has
# to be true of this pull request. This pauses the outcome read after a
# successful mutation, has the public PR-recording entrypoint try to re-point
# the task, and requires that attempt to stay blocked until outcome handling
# has finished with the record it is reporting against.
test_outcome_adjudication_holds_the_task_record() {
  local case_dir merge_pid repoint_pid
  case_dir=$(make_case outcome-through-adjudication)
  mkdir -p "$case_dir/wt" "$case_dir/home"
  add_gh_mocks "$case_dir" fcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfcfc
  : > "$case_dir/gh-axi.log"

  set +e
  FM_FAKE_GH_HOLD_OUTCOME=1 \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/44 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" &
  merge_pid=$!
  set -e
  until [ -e "$case_dir/outcome-reached" ]; do sleep 0.05; done

  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$case_dir/home" FM_STATE_OVERRIDE="$case_dir/state" \
  PATH="$case_dir/policybin:$case_dir/fakebin:$PATH" \
    "$ROOT/bin/fm-pr-check.sh" task-x1 https://github.com/example/repo/pull/999 \
    > "$case_dir/repoint.out" 2> "$case_dir/repoint.err" &
  repoint_pid=$!
  sleep 1

  # The mutation has happened and its outcome is being judged: the task must
  # still be the one this run merged.
  assert_grep 'pr=https://github.com/example/repo/pull/44' "$case_dir/state/task-x1.meta" \
    "outcome-through-adjudication: the task was re-pointed while its outcome was being judged"
  assert_no_grep 'pr=https://github.com/example/repo/pull/999' "$case_dir/state/task-x1.meta" \
    "outcome-through-adjudication: another pull request replaced this one during adjudication"

  : > "$case_dir/release-outcome"
  wait "$merge_pid" || fail "outcome-through-adjudication: the merge failed"
  wait "$repoint_pid" >/dev/null 2>&1 || true

  assert_grep 'verified: https://github.com/example/repo/pull/44 is merged' "$case_dir/stdout" \
    "outcome-through-adjudication: the landed merge was not reported"
  pass "fm-pr-merge holds the task record through its own outcome adjudication"
}
# GitLab takes the same transaction GitHub does, for the same reason: the merge
# request this run verified has to still be the one the task names when the
# merge lands and when its outcome is reported. This pauses the forge mutation,
# has the public PR-recording entrypoint try to re-point the task, and requires
# that attempt to stay blocked until GitLab outcome handling has finished.
test_gitlab_merge_holds_the_task_record() {
  local case_dir merge_pid repoint_pid
  case_dir=$(make_gitlab_case gitlab-holds-task-record)
  mkdir -p "$case_dir/home"
  : > "$case_dir/glab.log"
  : > "$case_dir/glab-hold-merge"

  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr" &
  merge_pid=$!
  set -e
  until [ -e "$case_dir/glab-merge-reached" ]; do sleep 0.05; done

  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$case_dir/home" FM_STATE_OVERRIDE="$case_dir/state" \
  PATH="$case_dir/policybin:$case_dir/fakebin:$PATH" \
    "$ROOT/bin/fm-pr-check.sh" task-x1 https://github.com/example/repo/pull/999 \
    > "$case_dir/repoint.out" 2> "$case_dir/repoint.err" &
  repoint_pid=$!
  sleep 1

  assert_grep "pr=$MR_URL" "$case_dir/state/task-x1.meta" \
    "gitlab-holds-task-record: the task was re-pointed while its merge was in flight"
  assert_no_grep 'pr=https://github.com/example/repo/pull/999' "$case_dir/state/task-x1.meta" \
    "gitlab-holds-task-record: another pull request replaced this merge request at the mutation"

  : > "$case_dir/glab-release-merge"
  wait "$merge_pid" || fail "gitlab-holds-task-record: the merge failed"
  wait "$repoint_pid" >/dev/null 2>&1 || true

  assert_grep "pr=$MR_URL" "$case_dir/glab-meta-at-merge" \
    "gitlab-holds-task-record: the record at the mutation named another pull request"
  pass "fm-pr-merge holds the task record through a GitLab merge and its outcome"
}

test_firstmate_merge_refuses_calendar_invalid_review_timestamps() {
  local case_dir label entry stamp rc i=0
  # A timestamp shaped like the forge's own is not necessarily one it could
  # issue; only a value a real UTC parser round-trips byte for byte is.
  local -a stamps=(
    'invalid-month:2026-13-05T10:00:00Z'
    'invalid-day:2026-02-30T10:00:00Z'
    'invalid-hour:2026-09-05T24:00:00Z'
    'invalid-minute:2026-09-05T10:60:00Z'
    'invalid-second:2026-09-05T10:00:61Z'
    'impossible:2026-99-99T99:99:99Z'
  )
  for entry in "${stamps[@]}"; do
    label=${entry%%:*}
    stamp=${entry#*:}
    i=$((i + 1))
    case_dir=$(make_firstmate_review_case "firstmate-review-calendar-$i")

    set +e
    FM_FAKE_GH_REVIEWS="$(review_payload_of \
      "$(review_record reviewer-one "$FM_REVIEW_HEAD" "$FM_REVIEW_LGTM" APPROVED "$stamp" 1)")" \
      run_pr_merge "$case_dir" task-x1 https://github.com/example/firstmate/pull/127 \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    expect_code 1 "$rc" "firstmate-review-calendar/$label: an impossible timestamp authorized the merge"
    assert_grep 'could not be read or validated' "$case_dir/stderr" \
      "firstmate-review-calendar/$label: an impossible timestamp was not treated as invalid evidence"
    assert_no_merge_call "$case_dir" \
      "firstmate-review-calendar/$label: merge ran on evidence with no chronological meaning"
  done

  # The captain's absence escape cannot excuse it either.
  case_dir=$(make_firstmate_review_case firstmate-review-calendar-override)
  set +e
  FM_FAKE_GH_REVIEWS="$(review_payload_of \
    "$(review_record reviewer-one "$FM_REVIEW_HEAD" 'found a defect' CHANGES_REQUESTED 2026-02-30T10:00:00Z 1)")" \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/firstmate/pull/127 --allow-missing-review \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "firstmate-review-calendar-override: the absence escape excused an impossible timestamp"
  assert_no_merge_call "$case_dir" \
    "firstmate-review-calendar-override: merge ran on an unreadable negative verdict"
  assert_no_grep 'missing_review_override_ts=' "$case_dir/state/task-x1.meta" \
    "firstmate-review-calendar-override: invalid evidence was recorded as an authorized absence"
  pass "fm-pr-merge refuses review timestamps no calendar could produce"
}

# --- caller merge flags -------------------------------------------------------
# Every caller flag that still reaches the forge reaches it on a head-bound
# path, so a head that moved after the verdict refuses on that path too.

test_github_every_caller_flag_path_refuses_a_moved_head() {
  local case_dir rc label entry i=0
  local -a cases=(
    'squash-delete:--squash --delete-branch'
    'short-delete:-d'
    'explicit-merge:--merge'
    'method-equals:--method=merge'
    'commit-text:--subject release --body notes'
  )
  local flags
  for entry in "${cases[@]}"; do
    label=${entry%%:*}
    flags=${entry#*:}
    i=$((i + 1))
    case_dir=$(make_case "github-moved-head-$i")
    mkdir -p "$case_dir/wt"
    add_gh_mocks "$case_dir" 5757575757575757575757575757575757575757
    : > "$case_dir/gh-axi.log"

    set +e
    # shellcheck disable=SC2086  # each fixture names its own argument list.
    FM_FAKE_GH_HEAD_AT_MERGE=5858585858585858585858585858585858585858 \
      run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/71 -- $flags \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    [ "$rc" -ne 0 ] \
      || fail "github-moved-head/$label: a head that moved before the merge was merged anyway"
    assert_no_grep '^pr merge ' "$case_dir/gh-axi.log" \
      "github-moved-head/$label: the merge fell back to the unfenced CLI path"
    assert_grep '5757575757575757575757575757575757575757' "$case_dir/gh-axi.log" \
      "github-moved-head/$label: the reviewed head never reached the forge call"
  done
  pass "fm-pr-merge binds every caller-flag merge path to the reviewed head"
}

test_github_refuses_a_merge_flag_it_cannot_bind() {
  local case_dir rc label entry i=0
  local -a cases=(
    'sha-override:--sha abc123'
    'unknown-flag:--admin'
    'unknown-cluster:-yf'
    'deferred:--auto --merge'
    'disable-deferred:--disable-auto'
    'bad-method:--method octopus'
  )
  local flags
  for entry in "${cases[@]}"; do
    label=${entry%%:*}
    flags=${entry#*:}
    i=$((i + 1))
    case_dir=$(make_case "github-unbindable-$i")
    mkdir -p "$case_dir/wt"
    add_gh_mocks "$case_dir" 5959595959595959595959595959595959595959
    : > "$case_dir/gh-axi.log"

    set +e
    # shellcheck disable=SC2086  # each fixture names its own argument list.
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/72 -- $flags \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    expect_code 1 "$rc" "github-unbindable/$label: an unbindable merge flag was accepted"
    assert_no_merge_call "$case_dir" \
      "github-unbindable/$label: merge ran with a flag no head-bound path can carry"
    assert_absent "$case_dir/state/task-x1.check.sh" \
      "github-unbindable/$label: an unbindable flag armed a merge poll before refusing"
  done
  pass "fm-pr-merge refuses a GitHub merge flag it cannot bind to the reviewed head"
}

test_github_delete_branch_runs_only_after_a_proved_merge() {
  local case_dir rc

  case_dir=$(make_case github-delete-branch)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 6060606060606060606060606060606060606060
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/73 -- --delete-branch \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "github-delete-branch: a head-bound merge with --delete-branch failed"

  assert_merge_call "$case_dir" 73 example/repo \
    "github-delete-branch: the merge did not reach the head-bound seam"
  assert_grep 'api DELETE /repos/example/repo/git/refs/heads/fm/task-branch' "$case_dir/gh-axi.log" \
    "github-delete-branch: the head branch was not deleted after the merge"
  grep -n 'api DELETE' "$case_dir/gh-axi.log" | head -1 | grep -q '^2:' \
    || fail "github-delete-branch: the branch deletion did not follow the merge call"

  # A fork's head branch is not this repository's to delete.
  case_dir=$(make_case github-delete-branch-fork)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 6161616161616161616161616161616161616161
  : > "$case_dir/gh-axi.log"

  FM_FAKE_GH_PR_HEAD_REPO=someone-else/repo \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/74 -- --delete-branch \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "github-delete-branch-fork: the merge itself failed"
  assert_no_grep 'api DELETE' "$case_dir/gh-axi.log" \
    "github-delete-branch-fork: a branch in another repository was deleted"
  assert_grep 'belongs to someone-else/repo' "$case_dir/stderr" \
    "github-delete-branch-fork: the skipped deletion was not reported"

  # A failed deletion is reported and never turns a landed merge into a failure.
  case_dir=$(make_case github-delete-branch-fails)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 6262626262626262626262626262626262626262
  : > "$case_dir/gh-axi.log"

  set +e
  FM_FAKE_GH_DELETE_REF_FAILS=1 \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/75 -- --delete-branch \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 0 "$rc" "github-delete-branch-fails: a failed deletion turned a landed merge into a failure"
  assert_grep 'could not delete head branch' "$case_dir/stderr" \
    "github-delete-branch-fails: the failed deletion was not reported"
  pass "fm-pr-merge deletes a head branch only after a proved merge, and never another repository's"
}

test_github_refuses_every_deferred_merge_spelling() {
  local case_dir rc label entry flags i=0
  # A deferred merge lands whatever the head is when the forge reaches it, so
  # every spelling refuses here rather than merging immediately or arming a
  # merge nothing can bind to the reviewed commit.
  local -a cases=(
    'auto:--auto --merge'
    'auto-true:--auto=true --merge'
    'auto-false:--auto=false --merge'
    'auto-garbage:--auto=maybe --merge'
    'disable-auto:--disable-auto --merge'
  )
  for entry in "${cases[@]}"; do
    label=${entry%%:*}
    flags=${entry#*:}
    i=$((i + 1))
    case_dir=$(make_case "github-deferred-merge-$i")
    mkdir -p "$case_dir/wt"
    add_gh_mocks "$case_dir" 6363636363636363636363636363636363636363
    : > "$case_dir/gh-axi.log"

    set +e
    # shellcheck disable=SC2086  # each fixture names its own argument list.
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/76 -- $flags \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    expect_code 1 "$rc" "github-deferred-merge/$label: a deferred-merge flag was accepted"
    assert_no_merge_call "$case_dir" \
      "github-deferred-merge/$label: a deferred-merge flag reached a merge"
    assert_absent "$case_dir/state/task-x1.check.sh" \
      "github-deferred-merge/$label: a refused deferred merge still armed a poll"
    assert_grep 'bind to the reviewed head' "$case_dir/stderr" \
      "github-deferred-merge/$label: the refusal did not say why deferring is refused"
  done
  pass "fm-pr-merge refuses every deferred-merge spelling before anything is armed"
}

test_github_refuses_two_different_merge_methods() {
  local case_dir rc
  case_dir=$(make_case github-conflicting-methods)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 6565656565656565656565656565656565656565
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/77 -- --merge --squash \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-conflicting-methods: an ambiguous method request was accepted"
  assert_grep 'name two different merge methods' "$case_dir/stderr" \
    "github-conflicting-methods: the refusal did not name the ambiguity"
  assert_no_merge_call "$case_dir" \
    "github-conflicting-methods: one of two conflicting methods was silently chosen"

  # Naming the same method twice is not ambiguous and still merges.
  case_dir=$(make_case github-repeated-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 6666666666666666666666666666666666666666
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/78 -- --merge --method=merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "github-repeated-method: an unambiguous repeated method was refused"
  assert_merge_call "$case_dir" 78 example/repo \
    "github-repeated-method: the repeated method did not reach the head-bound seam" merge
  pass "fm-pr-merge refuses two different merge methods and accepts an exact repeat"
}


test_github_zero_exit_queue_required_refuses_with_exact_retry
test_github_closed_unqueued_outcome_omits_retry_flags
test_github_agreeing_queue_rules_keep_retry_guidance
test_github_conflicting_queue_rules_report_ambiguity
test_verified_merge_records_pr_and_head
test_pr_metadata_is_recorded_before_the_forge_call
test_merge_failure_propagates_after_recording
test_github_open_unqueued_outcome_refuses
test_github_unreadable_outcome_keeps_pr_bookkeeping
test_github_refusal_quotes_the_forge_output
test_github_unreadable_outcome_refusal_quotes_the_forge_output
test_github_unrecognised_queue_method_still_names_the_queue
test_github_unreadable_queue_rules_are_not_reported_as_no_queue
test_github_no_queue_rule_says_nothing_about_a_queue
test_github_fallback_view_refusal_says_the_queue_was_unobservable
test_github_failed_gh_read_falls_back_to_gh_axi
test_github_failed_merge_names_an_observed_landed_state
test_github_without_gh_still_uses_gh_axi_merge
test_github_without_gh_failed_read_keeps_bookkeeping
test_github_merged_outcome_is_verified
test_github_verified_merge_requires_poll_recording
test_github_queued_outcome_is_refused
test_github_queue_required_refusal_names_retry_flags
test_extra_merge_args_forwarded
test_missing_meta_refuses_before_merge
test_malformed_url_refuses_before_merge
test_rejects_unsafe_url_segments_before_recording
test_repo_override_args_refuse_before_recording
test_bundled_repo_override_args_refuse_before_recording
test_explicit_merge_method_not_overridden
test_method_equals_merge_method_not_overridden
test_parses_pr_url_for_gh_axi
test_github_sha_arg_refuses_like_gitlab
test_gitlab_url_resolves_and_merges
test_gitlab_host_comes_from_the_url
test_gitlab_imposes_no_merge_method
test_gitlab_extra_args_forwarded
test_gitlab_merge_failure_propagates
test_gitlab_each_condition_refuses_independently
test_gitlab_mergeability_requires_boolean_fields
test_gitlab_reports_every_failing_condition
test_gitlab_stale_recorded_head_is_reported
test_gitlab_unreadable_state_refuses
test_gitlab_invalid_head_refuses
test_gitlab_missing_tool_refuses_before_recording
test_gitlab_head_override_args_refuse_before_recording
test_secondmate_merge_reports_upward_once
test_secondmate_merge_reports_on_the_local_route
test_fallback_home_never_routes_outcomes_through_ambient_markers
test_fallback_home_never_escapes_the_override_through_dot_components
test_data_only_override_never_writes_into_the_live_home_state
test_local_route_parent_write_without_overrides_still_lands
test_gitlab_merge_reports_upward
test_queued_gitlab_merge_leaves_the_poll_armed
test_gitlab_post_merge_confirmation_failures_leave_poll_armed
test_failed_merge_reports_nothing
test_gitlab_refusal_reports_nothing
test_main_home_merge_leaves_a_durable_wake
test_queued_github_merge_leaves_the_poll_armed
test_distinct_merged_prs_keep_distinct_wakes
test_uncommitted_marker_retry_is_never_silent
test_secondmate_without_parent_binding_is_loud
test_non_green_pr_requires_explicit_override
test_firstmate_merge_clears_a_stale_missing_review_receipt
test_firstmate_merge_missing_review_requires_distinct_override
test_firstmate_merge_refuses_when_override_receipt_cannot_be_written
test_firstmate_merge_preserves_override_receipt_across_identity_refresh
test_firstmate_merge_drops_override_receipt_when_the_pr_changes
test_firstmate_merge_keeps_a_same_pr_receipt_without_a_discard_notice
test_firstmate_merge_removes_staged_receipt_when_publish_fails
test_meta_rewrite_removes_its_staged_file_without_a_caller_trap
test_firstmate_merge_removes_staged_receipt_when_interrupted
test_firstmate_merge_guards_unresolvable_project
test_other_project_merge_skips_the_review_guard
test_firstmate_merge_refuses_author_written_review_prose
test_firstmate_merge_accepts_exact_head_independent_review
test_firstmate_merge_refuses_unqualified_review_evidence
test_firstmate_merge_refuses_unreadable_review_evidence
test_firstmate_merge_missing_review_override_still_escapes
test_github_merge_refuses_a_head_that_moved_after_the_verdict
test_github_merge_carries_the_live_head_for_any_project
test_github_merge_refuses_an_unreadable_head
test_allow_red_records_a_bound_override_receipt_before_the_merge
test_allow_red_refuses_when_the_receipt_cannot_be_written
test_green_merge_clears_a_stale_red_override_receipt
test_red_override_receipt_survives_an_identity_refresh
test_red_override_receipt_is_dropped_when_the_pr_changes
test_partial_red_override_receipt_is_not_carried_forward
test_red_override_receipt_survives_a_concurrent_metadata_writer
test_firstmate_merge_refuses_a_non_approving_review_verdict
test_firstmate_merge_refuses_a_changes_requested_verdict_outright
test_firstmate_merge_requires_the_verdict_on_its_own_line
test_firstmate_merge_uses_each_reviewer_latest_effective_verdict
test_firstmate_merge_refuses_a_malformed_review_payload_outright
test_firstmate_merge_refuses_ambiguously_ordered_reviews
test_firstmate_merge_refuses_semantically_malformed_review_metadata
test_firstmate_merge_treats_a_case_variant_author_as_the_author
test_firstmate_merge_override_never_excuses_unreadable_evidence
test_review_guard_applies_unless_the_project_owns_the_pull_request
test_gitlab_refuses_every_deferred_merge_spelling
test_review_guard_ignores_a_remote_that_names_no_repository
test_review_guard_requires_one_readable_project_identity
test_review_guard_decides_from_the_committed_task_identity
test_gitlab_refuses_arguments_it_cannot_bind
test_review_guard_proves_ownership_only_from_the_exact_origin
test_firstmate_merge_refuses_logins_github_could_not_issue
test_gitlab_refuses_a_rebase_or_a_repeated_option
test_review_guard_requires_a_canonical_origin_spelling
test_gitlab_refuses_alias_repeats_and_option_shaped_values
test_review_guard_preserves_every_origin_record
test_merge_binds_to_the_repository_name_the_forge_reports
test_gitlab_merge_states_immediate_mode
test_gitlab_refuses_inapplicable_and_invalid_requests
test_firstmate_merge_validates_raw_review_identity
test_firstmate_merge_validates_every_review_commit
test_github_refuses_repeated_commit_text_options
test_github_case_mismatch_records_nothing
test_red_receipt_holds_the_task_through_the_merge
test_outcome_adjudication_holds_the_task_record
test_gitlab_merge_holds_the_task_record
test_firstmate_merge_refuses_calendar_invalid_review_timestamps
test_github_every_caller_flag_path_refuses_a_moved_head
test_github_refuses_a_merge_flag_it_cannot_bind
test_github_delete_branch_runs_only_after_a_proved_merge
test_github_refuses_every_deferred_merge_spelling
test_github_refuses_two_different_merge_methods
