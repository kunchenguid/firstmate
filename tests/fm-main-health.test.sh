#!/usr/bin/env bash
# tests/fm-main-health.test.sh - regression for bin/fm-main-health.sh, the
# derive-at-use main-health check: a fast, live GitHub Actions read a worker can
# run before blaming its own branch for a failing check, replacing the manual
# "reproduce it on the untouched baseline" step with one bounded API call.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"

MAIN_HEALTH="$ROOT/bin/fm-main-health.sh"
TMP_ROOT=$(fm_test_tmproot fm-main-health-tests)
BASE_PATH=$PATH

# make_repo <name> [remote-url]: a bare git checkout with an origin remote and a
# default branch, so fm_default_branch resolves without needing a real fetch.
make_repo() {
  local name=$1 remote=${2:-https://github.com/acme/widgets.git} dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir"
  git -C "$dir" init -q -b main
  git -C "$dir" remote add origin "$remote"
  printf 'x\n' > "$dir/x"
  git -C "$dir" add x
  git -C "$dir" -c user.email=t@example.com -c user.name=t commit -q -m init
  printf '%s\n' "$dir"
}

# make_fake_gh <fakebin> <sha> <check-runs-json>: a `gh` stub whose
# `api .../commits/<default>` call resolves to <sha> and whose
# `api .../commits/<sha>/check-runs` call prints <check-runs-json> verbatim,
# recording every invocation so a case can assert both the parsed verdict and
# the exact repo/commit it queried.
make_fake_gh() {
  local fakebin=$1 sha=$2 checkruns=$3
  cat > "$fakebin/gh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$fakebin/gh.log"
case " \$* " in
  *"check-runs"*) printf '%s\n' '$checkruns' ;;
  *" api "*) printf '%s\n' '$sha' ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/gh"
}

# make_fake_glab <fakebin> <sha> <last-pipeline-json>: a `glab` stub whose
# `api projects/<enc>/repository/commits/<default>` call answers a commit
# object naming <sha> and <last-pipeline-json> as its last_pipeline field
# (a JSON object or the literal `null`), recording every invocation together
# with the GITLAB_HOST it was given so a case can assert the host and the
# percent-encoded project path came from the parsed origin, never an assumed
# default.
make_fake_glab() {
  local fakebin=$1 sha=$2 pipeline=$3
  cat > "$fakebin/glab" <<SH
#!/usr/bin/env bash
printf '%s\n' "GITLAB_HOST=\${GITLAB_HOST:-<unset>} \$*" >> "$fakebin/glab.log"
case " \$* " in
  *" api "*) printf '{"id":"%s","last_pipeline":%s}\n' "$sha" '$pipeline' ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/glab"
}

# path_without <dir> <omit-tool>: a fresh PATH entry symlinking every real tool
# reachable through BASE_PATH except <omit-tool>, so a case can simulate that
# one tool being absent without depending on what happens to be installed on
# the host running the suite.
path_without() {
  local dir=$1 omit=$2 bindir entry name
  mkdir -p "$dir"
  while IFS= read -r bindir; do
    [ -d "$bindir" ] || continue
    for entry in "$bindir"/*; do
      [ -e "$entry" ] || continue
      name=${entry##*/}
      [ "$name" = "$omit" ] && continue
      [ -e "$dir/$name" ] || ln -s "$entry" "$dir/$name" 2>/dev/null
    done
  done <<EOF
$(printf '%s' "$BASE_PATH" | tr ':' '\n')
EOF
  ! PATH="$dir" command -v "$omit" >/dev/null 2>&1 \
    || fail "the $omit-free search path still resolved $omit"
}

test_green_when_every_check_run_succeeded() {
  local dir fakebin out rc
  dir=$(make_repo green)
  fakebin=$(fm_fakebin "$TMP_ROOT/green-case")
  make_fake_gh "$fakebin" abc123 '[{"status":"completed","conclusion":"success"},{"status":"completed","conclusion":"success"}]'
  set +e
  out=$(PATH="$fakebin:$PATH" "$MAIN_HEALTH" "$dir" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "a healthy default branch was not reported as exit 0: $out"
  case "$out" in
    GREEN:*acme/widgets@main*abc123*) ;;
    *) fail "the GREEN verdict did not name the repo, branch and sha: $out" ;;
  esac
  grep -qF -- "repos/acme/widgets/commits/main" "$fakebin/gh.log" \
    || fail "the check did not resolve the default branch's HEAD commit"
  grep -qF -- "repos/acme/widgets/commits/abc123/check-runs" "$fakebin/gh.log" \
    || fail "the check did not query check-runs for the resolved HEAD commit"
  pass "a default branch whose every check run succeeded reports GREEN and exits 0"
}

test_red_when_any_check_run_failed() {
  local dir fakebin out rc
  dir=$(make_repo red)
  fakebin=$(fm_fakebin "$TMP_ROOT/red-case")
  make_fake_gh "$fakebin" deadbee '[{"status":"completed","conclusion":"success"},{"status":"completed","conclusion":"failure"}]'
  set +e
  out=$(PATH="$fakebin:$PATH" "$MAIN_HEALTH" "$dir" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "a failing default branch was not reported as exit 1: $out"
  case "$out" in
    RED:*acme/widgets@main*deadbee*) ;;
    *) fail "the RED verdict did not name the repo, branch and sha: $out" ;;
  esac
  pass "a default branch with any failing check run reports RED and exits 1, even when other checks passed"
}

test_red_when_a_check_run_never_started() {
  local dir fakebin out rc
  dir=$(make_repo startupfailure)
  fakebin=$(fm_fakebin "$TMP_ROOT/startup-failure-case")
  make_fake_gh "$fakebin" bad5eed '[{"status":"completed","conclusion":"success"},{"status":"completed","conclusion":"startup_failure"}]'
  set +e
  out=$(PATH="$fakebin:$PATH" "$MAIN_HEALTH" "$dir" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "a check run that never started (startup_failure) was not reported as exit 1: $out"
  case "$out" in
    RED:*bad5eed*) ;;
    *) fail "the RED verdict did not name the sha: $out" ;;
  esac
  pass "a check run that never started (startup_failure) reports RED, not a false GREEN"
}

test_pending_when_any_check_run_has_not_finished() {
  local dir fakebin out rc
  dir=$(make_repo pending)
  fakebin=$(fm_fakebin "$TMP_ROOT/pending-case")
  make_fake_gh "$fakebin" cafefee '[{"status":"completed","conclusion":"success"},{"status":"in_progress","conclusion":null}]'
  set +e
  out=$(PATH="$fakebin:$PATH" "$MAIN_HEALTH" "$dir" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "an in-progress default branch check run was not reported as exit 0: $out"
  case "$out" in
    PENDING:*cafefee*) ;;
    *) fail "the PENDING verdict did not name the sha: $out" ;;
  esac
  pass "a default branch with any unfinished check run reports PENDING and exits 0, never GREEN or RED"
}

test_unrelated_workflow_does_not_hide_a_failing_one() {
  local dir fakebin out rc
  dir=$(make_repo multiworkflow)
  fakebin=$(fm_fakebin "$TMP_ROOT/multiworkflow-case")
  # A CI workflow that failed plus an unrelated, later-completing nightly
  # workflow that succeeded: the aggregate must still be RED. The old
  # `gh run list --limit 1` approach picked whichever workflow run started most
  # recently, so an unrelated passing run could mask this exact failure.
  make_fake_gh "$fakebin" f00d '[{"status":"completed","conclusion":"failure"},{"status":"completed","conclusion":"success"}]'
  set +e
  out=$(PATH="$fakebin:$PATH" "$MAIN_HEALTH" "$dir" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "a failing CI workflow was masked by an unrelated passing workflow: $out"
  case "$out" in
    RED:*f00d*) ;;
    *) fail "the RED verdict did not name the sha: $out" ;;
  esac
  pass "a failing workflow's check run is never hidden behind an unrelated workflow's success"
}

test_unknown_when_no_check_runs_exist() {
  local dir fakebin out rc
  dir=$(make_repo norun)
  fakebin=$(fm_fakebin "$TMP_ROOT/norun-case")
  make_fake_gh "$fakebin" abc999 '[]'
  set +e
  out=$(PATH="$fakebin:$PATH" "$MAIN_HEALTH" "$dir" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "no check runs at all was not reported as exit 2 (cannot determine): $out"
  case "$out" in
    GREEN:*|RED:*) fail "an unknown verdict must never be reported as GREEN or RED: $out" ;;
  esac
  pass "no check runs at all is reported as undetermined (exit 2), never GREEN or RED"
}

test_unknown_when_no_github_remote() {
  local dir fakebin out rc
  dir=$(make_repo norigin)
  git -C "$dir" remote remove origin
  fakebin=$(fm_fakebin "$TMP_ROOT/norigin-case")
  make_fake_gh "$fakebin" abc999 '[]'
  set +e
  out=$(PATH="$fakebin:$PATH" "$MAIN_HEALTH" "$dir" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "a project with no origin remote was not reported as exit 2: $out"
  [ ! -e "$fakebin/gh.log" ] || fail "a missing remote must fail before ever calling gh"
  pass "a project with no GitHub origin remote is undetermined (exit 2) without ever calling gh"
}

test_gitlab_green_when_pipeline_succeeded() {
  local dir fakebin out rc
  dir=$(make_repo gitlab-green https://gitlab.example.com/group/sub/widgets.git)
  fakebin=$(fm_fakebin "$TMP_ROOT/gitlab-green-case")
  make_fake_glab "$fakebin" g00d '{"status":"success","web_url":"https://gitlab.example.com/group/sub/widgets/-/pipelines/1"}'
  set +e
  out=$(PATH="$fakebin:$PATH" "$MAIN_HEALTH" "$dir" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "a healthy GitLab default branch was not reported as exit 0: $out"
  case "$out" in
    GREEN:*gitlab.example.com/group/sub/widgets@main*g00d*) ;;
    *) fail "the GREEN verdict did not name the host, project, branch and sha: $out" ;;
  esac
  grep -qF -- "GITLAB_HOST=gitlab.example.com api projects/group%2Fsub%2Fwidgets/repository/commits/main -R https://gitlab.example.com/group/sub/widgets" \
    "$fakebin/glab.log" \
    || fail "the check did not query GitLab with the host and percent-encoded path from the parsed origin: $(cat "$fakebin/glab.log")"
  pass "a GitLab default branch whose pipeline succeeded reports GREEN and exits 0, addressed by the parsed host and project path"
}

test_gitlab_red_when_pipeline_failed() {
  local dir fakebin out rc
  dir=$(make_repo gitlab-red https://gitlab.example.com/group/widgets.git)
  fakebin=$(fm_fakebin "$TMP_ROOT/gitlab-red-case")
  make_fake_glab "$fakebin" dead1 '{"status":"failed","web_url":"https://gitlab.example.com/group/widgets/-/pipelines/2"}'
  set +e
  out=$(PATH="$fakebin:$PATH" "$MAIN_HEALTH" "$dir" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "a failing GitLab default branch was not reported as exit 1: $out"
  case "$out" in
    RED:*dead1*) ;;
    *) fail "the RED verdict did not name the sha: $out" ;;
  esac
  pass "a GitLab default branch with a failed pipeline reports RED and exits 1"
}

test_gitlab_pending_when_pipeline_has_not_finished() {
  local dir fakebin out rc
  dir=$(make_repo gitlab-pending https://gitlab.example.com/group/widgets.git)
  fakebin=$(fm_fakebin "$TMP_ROOT/gitlab-pending-case")
  make_fake_glab "$fakebin" cafe2 '{"status":"running","web_url":"https://gitlab.example.com/group/widgets/-/pipelines/3"}'
  set +e
  out=$(PATH="$fakebin:$PATH" "$MAIN_HEALTH" "$dir" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "a running GitLab pipeline was not reported as exit 0: $out"
  case "$out" in
    PENDING:*cafe2*) ;;
    *) fail "the PENDING verdict did not name the sha: $out" ;;
  esac
  pass "a GitLab default branch with a running pipeline reports PENDING and exits 0, never GREEN or RED"
}

test_gitlab_unknown_when_no_pipeline_ever_ran() {
  local dir fakebin out rc
  dir=$(make_repo gitlab-norun https://gitlab.example.com/group/widgets.git)
  fakebin=$(fm_fakebin "$TMP_ROOT/gitlab-norun-case")
  make_fake_glab "$fakebin" ab999 null
  set +e
  out=$(PATH="$fakebin:$PATH" "$MAIN_HEALTH" "$dir" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "no GitLab pipeline at all was not reported as exit 2 (cannot determine): $out"
  case "$out" in
    GREEN:*|RED:*) fail "an unknown GitLab verdict must never be reported as GREEN or RED: $out" ;;
  esac
  pass "no GitLab pipeline at all is reported as undetermined (exit 2), never GREEN or RED"
}

test_gitlab_missing_glab_refuses_before_any_call() {
  local dir nopath out rc
  dir=$(make_repo gitlab-noglab https://gitlab.example.com/group/widgets.git)
  nopath="$TMP_ROOT/gitlab-noglab-path"
  path_without "$nopath" glab
  set +e
  out=$(PATH="$nopath" "$MAIN_HEALTH" "$dir" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "a GitLab origin with no glab on PATH was not reported as exit 2: $out"
  case "$out" in
    *"requires glab on PATH"*) ;;
    *) fail "the refusal did not name the missing glab tool: $out" ;;
  esac
  pass "a GitLab origin with no glab on PATH is undetermined (exit 2) and names the missing tool"
}

test_green_when_every_check_run_succeeded
test_red_when_any_check_run_failed
test_red_when_a_check_run_never_started
test_pending_when_any_check_run_has_not_finished
test_unrelated_workflow_does_not_hide_a_failing_one
test_unknown_when_no_check_runs_exist
test_unknown_when_no_github_remote
test_gitlab_green_when_pipeline_succeeded
test_gitlab_red_when_pipeline_failed
test_gitlab_pending_when_pipeline_has_not_finished
test_gitlab_unknown_when_no_pipeline_ever_ran
test_gitlab_missing_glab_refuses_before_any_call
