#!/usr/bin/env bash
# Security and regression tests for canonical PR parsing, static merge polls,
# private atomic artifacts, authenticated custom checks, and teardown cleanup.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-pr-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-check-lib.sh"

PR_CHECK="$ROOT/bin/fm-pr-check.sh"
PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
POLL="$ROOT/bin/fm-pr-poll.sh"
WATCH="$ROOT/bin/fm-watch.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
REGISTER="$ROOT/bin/fm-check-register.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-check-security)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
REAL_CP=$(command -v cp)
REAL_MV=$(command -v mv)
REAL_STAT=$(command -v stat)
REAL_CHMOD=$(command -v chmod)
# The merge path reads a merge request's JSON with the real jq, and BASE_PATH is
# deliberately restricted, so a case that needs jq exposes this one rather than
# depending on the host keeping jq in one of those four directories.
REAL_JQ=$(command -v jq) || fail "these tests read glab's JSON with the real jq, which was not found"

ack_watcher_cycle() {  # <state>
  local state=$1 err sequence generation
  err="$state/.test-wake-drain.err"
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-drain.sh" >/dev/null 2> "$err" || return 1
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  rm -f "$err"
  [ -n "$sequence" ] && [ -n "$generation" ] || return 1
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-drain.sh" --ack-through "$sequence" \
    --recovery-generation "$generation"
}

file_mode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1"
  else
    stat -c %a "$1"
  fi
}

process_is_live_non_zombie() {
  local pid=$1 stat
  kill -0 "$pid" 2>/dev/null || return 1
  stat=$(ps -p "$pid" -o stat= 2>/dev/null || true)
  case "$stat" in
    Z*) return 1 ;;
  esac
  return 0
}

LINK_KIND=
LINK_TARGET=
LINK_CONTENT=
LINK_MODE=
make_private_symlink() {
  local base=$1 destination=$2 kind=$3
  LINK_KIND=$kind
  LINK_TARGET="$base/target-$kind"
  LINK_CONTENT=
  LINK_MODE=
  case "$kind" in
    regular)
      LINK_CONTENT='external sentinel'
      printf '%s\n' "$LINK_CONTENT" > "$LINK_TARGET"
      chmod 0644 "$LINK_TARGET"
      LINK_MODE=644
      ;;
    dangling)
      rm -f "$LINK_TARGET"
      ;;
    directory)
      mkdir "$LINK_TARGET"
      printf 'outside\n' > "$LINK_TARGET/keep"
      chmod 0755 "$LINK_TARGET"
      LINK_MODE=755
      ;;
    *) fail "unknown symlink fixture kind" ;;
  esac
  ln -s "$LINK_TARGET" "$destination"
}

assert_private_symlink_unchanged() {
  local link=$1
  [ -L "$link" ] || fail "private destination symlink was replaced"
  case "$LINK_KIND" in
    regular)
      [ "$(cat "$LINK_TARGET")" = "$LINK_CONTENT" ] || fail "external regular target content changed"
      [ "$(file_mode "$LINK_TARGET")" = "$LINK_MODE" ] || fail "external regular target mode changed"
      ;;
    dangling)
      [ ! -e "$LINK_TARGET" ] || fail "dangling target was created"
      ;;
    directory)
      [ -f "$LINK_TARGET/keep" ] || fail "external directory target contents changed"
      [ "$(file_mode "$LINK_TARGET")" = "$LINK_MODE" ] || fail "external directory target mode changed"
      ;;
  esac
}

state_snapshot() {
  local state=$1 file
  (
    cd "$state" || exit 1
    find . \( -type f -o -type l \) -print | LC_ALL=C sort | while IFS= read -r file; do
      if [ -L "$file" ]; then
        printf 'link %s %s\n' "$file" "$(readlink "$file")"
      else
        printf 'file %s %s ' "$file" "$(file_mode "$file")"
        shasum -a 256 "$file" | awk '{print $1}'
      fi
    done
  )
}

make_case() {
  local name=$1 dir fakebin fake_root
  dir="$TMP_ROOT/$name"
  fakebin="$dir/fakebin"
  fake_root="$dir/root"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config" "$dir/wt" "$fakebin" "$fake_root/bin"
  cat > "$fake_root/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
printf 'guard\n' >> "$FM_TEST_GUARD_LOG"
SH
  chmod +x "$fake_root/bin/fm-guard.sh"
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_LOG"
case "${1:-} ${2:-}" in
  "api graphql")
    printf '%s\n' \
      'state=MERGED' \
      'merged=true' \
      'queued=false' \
      'base=main'
    exit 0
    ;;
esac
case " $* " in
  *" headRefOid "*) printf '%s\n' "${FM_TEST_GH_HEAD:-0123456789abcdef0123456789abcdef01234567}" ;;
  *" headRefName "*) printf '%s\n' "${FM_TEST_GH_BRANCH:-fm/task-a}" ;;
  *" state "*)
    [ "${FM_TEST_GH_FAIL:-0}" = 0 ] || exit 1
    [ "${FM_TEST_GH_SLEEP:-0}" = 0 ] || sleep "$FM_TEST_GH_SLEEP"
    printf '%s\n' "${FM_TEST_GH_STATE:-OPEN}"
    ;;
esac
SH
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr view")
    [ "$#" -eq 5 ] && [ "${4:-}" = --repo ] || exit 2
    printf 'pull_request:\n  number: %s\n  state: %s\n' "$3" "${FM_TEST_GH_MERGE_STATE:-merged}"
    ;;
esac
exit "${FM_TEST_GH_AXI_RC:-0}"
SH
  # Plain glab, reproducing the real CLI's contract: its field output on stdout
  # and exit 0 on success, and a non-zero exit with no stdout on any failure.
  cat > "$fakebin/glab" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GLAB_LOG"
[ "${FM_TEST_GLAB_FAIL:-0}" = 0 ] || exit 1
[ "${FM_TEST_GLAB_SLEEP:-0}" = 0 ] || sleep "$FM_TEST_GLAB_SLEEP"
printf 'title:\tfixture merge request\nstate:\t%s\nauthor:\tsomeone\n' "${FM_TEST_GLAB_STATE:-opened}"
SH
  chmod +x "$fakebin/gh" "$fakebin/gh-axi" "$fakebin/glab"
  : > "$dir/gh.log"
  : > "$dir/gh-axi.log"
  : > "$dir/glab.log"
  : > "$dir/guard.log"
  printf '%s\n' "$dir"
}

write_task_meta() {
  local dir=$1 id=${2:-task-a}
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$dir/wt" \
    "project=$dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
}

write_poll_meta() {
  local state=$1 id=$2 url=$3
  fm_write_meta "$state/$id.meta" \
    "window=fm-$id" \
    "pr=$url"
}


run_check_entry() {
  local dir=$1
  shift
  FM_ROOT_OVERRIDE="$dir/root" FM_HOME="$dir/home" \
    FM_TEST_GUARD_LOG="$dir/guard.log" FM_TEST_GH_LOG="$dir/gh.log" \
    FM_TEST_GH_AXI_LOG="$dir/gh-axi.log" FM_TEST_GLAB_LOG="$dir/glab.log" \
    PATH="$dir/fakebin:$BASE_PATH" \
    "$PR_CHECK" "$@"
}

run_merge_entry() {
  local dir=$1
  shift
  FM_ROOT_OVERRIDE="$dir/root" FM_HOME="$dir/home" \
    FM_TEST_GUARD_LOG="$dir/guard.log" FM_TEST_GH_LOG="$dir/gh.log" \
    FM_TEST_GH_AXI_LOG="$dir/gh-axi.log" FM_TEST_GLAB_LOG="$dir/glab.log" \
    PATH="$dir/fakebin:$BASE_PATH" \
    "$PR_MERGE" "$@"
}

# shellcheck disable=SC2016 # Literal rejected URL bytes are parser test data.
INVALID_URLS=(
  'https://gitlab.com/single/-/merge_requests/1'
  'https://gitlab.com/g/p/-/merge_requests/0'
  'https://gitlab.com/g/p/-/merge_requests/01'
  'https://GitLab.com/g/p/-/merge_requests/1'
  'https://gitlab.com:443/g/p/-/merge_requests/1'
  'https://user@gitlab.com/g/p/-/merge_requests/1'
  'https://gitlab.com/g/p/-/merge_requests/1/'
  'https://gitlab.com/-/p/-/merge_requests/1'
  'https://gitlab.com/g/p.git/-/merge_requests/1'
  'https://gitlab.com/g/p.atom/-/merge_requests/1'
  'https://gitlab.com/g/p/-/merge_requests/1?x=1'
  'https://gitlab.com/g/p/-/merge_requests/1#note'
  'https://gitlab.com/g/p/-/issues/1'
  'https://gitlab.com//p/-/merge_requests/1'
  'https://.gitlab.com/g/p/-/merge_requests/1'
  'https://gitlab.com./g/p/-/merge_requests/1'
  'http://gitlab.com/g/p/-/merge_requests/1'
  'https://github.com/o/r/pull/1/'
  ' https://github.com/o/r/pull/1'
  'https://github.com/o/r/pull/1 '
  'https://github.com/o /r/pull/1'
  $'https://github.com/o/r/pull/1\t'
  $'https://github.com/o/r/pull/1\r'
  $'https://github.com/o/r/pull/1\nnext'
  $'https://github.com/o/r/pull/1\r\nnext'
  $'https://github.com/o/r/pull/1\001'
  $'https://github.com/o/r/pull/1\033'
  $'https://github.com/o/r/pull/1\177'
  'https://user@github.com/o/r/pull/1'
  'https://user:pass@github.com/o/r/pull/1'
  'https://github.com:443/o/r/pull/1'
  'https://github.com/o%2Fr/pull/1'
  'https://github.com/o/r%2Fz/pull/1'
  'https://github.com/o/r/pull/1%3Fq'
  'https://github.com/o/r/pull/1%23f'
  'https://github.com/o/r/pull/1%24x'
  'https://github.com/o/r/pull/1%28x%29'
  'https://github.com/o/r/pull/1%60x'
  'https://github.com/o/r/pull/1%0D'
  'https://github.com/o/r/pull/1%0A'
  'https://github.com/o/r/pull/1%252Fz'
  'https://github.com//r/pull/1'
  'https://github.com/o//pull/1'
  'https://github.com/o/r//1'
  'https://github.com/o/r/1'
  'https://github.com/o/r/pull/'
  'https://github.com/-owner/r/pull/1'
  'https://github.com/owner-/r/pull/1'
  'https://github.com/owner--name/r/pull/1'
  'https://github.com/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/r/pull/1'
  'https://github.com/o/./pull/1'
  'https://github.com/o/../pull/1'
  'https://github.com/o/r+z/pull/1'
  'https://github.com/o/r/pull/+1'
  'https://github.com/o/r/pull/0'
  'https://github.com/o/r/pull/-1'
  'https://github.com/o/r/pull/01'
  'https://github.com/o/r/pull/0x1'
  'https://github.com/o/r/pull/1e2'
  'https://github.com/o/r/pull/1.0'
  'https://github.com/o/r/issues/1'
  'https://github.com/o/r/x/pull/1'
  'https://github.com/o/r/pull/1/files'
  'https://github.com/o/r/pull/1?q=x'
  'https://github.com/o/r/pull/1#f'
  'https://github.com.evil/o/r/pull/1'
  'https://evilgithub.com/o/r/pull/1'
  'https://gıthub.com/o/r/pull/1'
  'https://xn--gthub-3va.com/o/r/pull/1'
  'http://github.com/o/r/pull/1'
  'ssh://github.com/o/r/pull/1'
  'git://github.com/o/r/pull/1'
  'file://github.com/o/r/pull/1'
  '//github.com/o/r/pull/1'
  'HTTPS://github.com/o/r/pull/1'
  'https://GitHub.com/o/r/pull/1'
  'https://github.com/o$/r/pull/1'
  'https://github.com/o(/r/pull/1'
  'https://github.com/o)/r/pull/1'
  'https://github.com/o`/r/pull/1'
  'https://github.com/o/r`/pull/1'
  'https://github.com/o/r/pull/1`'
  "https://github.com/o/'r'/pull/1"
  'https://github.com/o/"r"/pull/1'
  'https://github.com/o/'\''"r"'\''/pull/1'
  "https://github.com/o/r/pull/1'"
  'https://github.com/o/r/pull/1"'
)

# shellcheck disable=SC2016 # Literal shell syntax is task-ID test data.
INVALID_IDS=(
  '../escape'
  'a/b'
  '.'
  '..'
  '.task'
  'task a'
  $'task\ta'
  $'task\na'
  'task*'
  "task'a"
  'task"a'
  'task;a'
  'task$a'
)

# shellcheck disable=SC2016 # Literal shell syntax is task-ID test data.
UNSAFE_LIFECYCLE_IDS=(
  '../escape'
  'a/b'
  '.'
  '..'
  '.task'
  'task a'
  $'task\ta'
  $'task\na'
  'task*'
  "task'a"
  'task"a'
  'task;a'
  'task$a'
)

test_parser_matrix() {
  local id row url owner repo number
  while IFS='|' read -r url owner repo number; do
    [ -n "$url" ] || continue
    fm_pr_url_parse "$url" || fail "parser rejected canonical URL"
    [ "$FM_PR_URL" = "$url" ] || fail "parser changed canonical URL"
    [ "$FM_PR_OWNER" = "$owner" ] || fail "parser returned wrong owner"
    [ "$FM_PR_REPO" = "$repo" ] || fail "parser returned wrong repository"
    [ "$FM_PR_NUMBER" = "$number" ] || fail "parser returned wrong PR number"
  done <<'EOF'
https://github.com/a/b/pull/1|a|b|1
https://github.com/my-org/repo/pull/42|my-org|repo|42
https://github.com/Owner/repo-name_with.parts/pull/123456|Owner|repo-name_with.parts|123456
EOF
  while IFS='|' read -r url host path number; do
    [ -n "$url" ] || continue
    fm_pr_url_parse "$url" || fail "parser rejected a canonical merge request URL"
    [ "$FM_PR_PROVIDER" = gitlab ] || fail "parser did not tag a merge request URL as gitlab"
    [ "$FM_PR_URL" = "$url" ] || fail "parser changed a canonical merge request URL"
    [ "$FM_PR_HOST" = "$host" ] || fail "parser returned wrong GitLab host"
    [ "$FM_PR_PATH" = "$path" ] || fail "parser returned wrong GitLab project path"
    [ "$FM_PR_NUMBER" = "$number" ] || fail "parser returned wrong merge request number"
    [ -z "$FM_PR_OWNER" ] && [ -z "$FM_PR_REPO" ] \
      || fail "parser set GitHub owner/repository for a merge request URL"
  done <<'EOF'
https://gitlab.com/group/project/-/merge_requests/1|gitlab.com|group/project|1
https://gitlab.com/group/sub/deep/project/-/merge_requests/42|gitlab.com|group/sub/deep/project|42
https://gitlab.example.co.uk/g/p/-/merge_requests/7|gitlab.example.co.uk|g/p|7
https://code.internal/team/tools/ci-runner/-/merge_requests/123456|code.internal|team/tools/ci-runner|123456
EOF
  fm_pr_url_parse https://github.com/a/b/pull/1 || fail "parser rejected canonical URL"
  [ "$FM_PR_PROVIDER" = github ] || fail "parser did not tag a pull request URL as github"
  [ "$FM_PR_HOST" = github.com ] || fail "parser returned wrong GitHub host"
  [ "$FM_PR_PATH" = a/b ] || fail "parser returned wrong GitHub project path"
  for row in "${INVALID_URLS[@]}"; do
    ! fm_pr_url_parse "$row" || fail "parser accepted a rejected raw-byte URL class"
  done
  for id in -task task- task--a Task-a task_a task.a; do
    fm_pr_task_id_valid "$id" || fail "task ID validator rejected a safe lifecycle-compatible slug"
  done
  fm_task_id_creation_valid _noncanonical \
    || fail "creation validator rejected a task ID after its reserved namespace moved"
  id=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  fm_pr_task_id_valid "$id" || fail "operational validator rejected a path-safe legacy task ID"
  ! fm_task_id_creation_valid "$id" || fail "creation validator accepted an overlong task ID"
  pass "raw-byte parser accepts canonical URLs and rejects the complete adversarial matrix"
}

test_invalid_entrypoints_have_zero_side_effects() {
  local dir before after value rc
  dir=$(make_case invalid-entrypoints)
  write_task_meta "$dir"
  printf 'existing-check\n' > "$dir/home/state/task-a.check.sh"
  printf 'existing-data\n' > "$dir/home/state/task-a.pr-poll"
  chmod 0600 "$dir/home/state/task-a.check.sh" "$dir/home/state/task-a.pr-poll"

  for value in "${INVALID_URLS[@]}"; do
    before=$(state_snapshot "$dir/home/state")
    set +e
    run_check_entry "$dir" task-a "$value" > "$dir/stdout" 2> "$dir/stderr"
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "direct entrypoint accepted invalid URL"
    [ "$(cat "$dir/stderr")" = 'error: invalid PR check request' ] || fail "direct invalid URL diagnostic was not fixed"
    after=$(state_snapshot "$dir/home/state")
    [ "$after" = "$before" ] || fail "direct invalid URL changed prior state"
  done

  for value in "${INVALID_IDS[@]}"; do
    before=$(state_snapshot "$dir/home/state")
    set +e
    run_check_entry "$dir" "$value" https://github.com/o/r/pull/1 > "$dir/stdout" 2> "$dir/stderr"
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "direct entrypoint accepted invalid task ID"
    after=$(state_snapshot "$dir/home/state")
    [ "$after" = "$before" ] || fail "invalid task ID changed state or traversed a path"
  done

  for value in "${INVALID_URLS[@]}"; do
    before=$(state_snapshot "$dir/home/state")
    set +e
    run_merge_entry "$dir" task-a "$value" > "$dir/stdout" 2> "$dir/stderr"
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "merge entrypoint accepted invalid URL"
    [ "$(cat "$dir/stderr")" = 'error: invalid PR merge request' ] || fail "merge invalid URL diagnostic was not fixed"
    after=$(state_snapshot "$dir/home/state")
    [ "$after" = "$before" ] || fail "merge invalid URL changed prior state"
  done

  for value in "${INVALID_IDS[@]}"; do
    before=$(state_snapshot "$dir/home/state")
    set +e
    run_merge_entry "$dir" "$value" https://github.com/o/r/pull/1 > "$dir/stdout" 2> "$dir/stderr"
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "merge entrypoint accepted invalid task ID"
    after=$(state_snapshot "$dir/home/state")
    [ "$after" = "$before" ] || fail "merge invalid task ID changed state"
  done

  for value in "${UNSAFE_LIFECYCLE_IDS[@]}"; do
    before=$(state_snapshot "$dir/home/state")
    set +e
    FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$dir/root" FM_TEST_GUARD_LOG="$dir/guard.log" \
      "$TEARDOWN" "$value" --force > "$dir/stdout" 2> "$dir/stderr"
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "teardown accepted invalid task ID"
    [ "$(cat "$dir/stderr")" = 'error: invalid teardown request' ] \
      || fail "teardown invalid task ID diagnostic was not fixed"
    after=$(state_snapshot "$dir/home/state")
    [ "$after" = "$before" ] || fail "teardown invalid task ID changed state"
  done

  set +e
  run_check_entry "$dir" > /dev/null 2> "$dir/stderr"; rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "direct entrypoint accepted zero arguments"
  set +e
  run_check_entry "$dir" task-a https://github.com/o/r/pull/1 extra > /dev/null 2> "$dir/stderr"; rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "direct entrypoint accepted extra arguments"
  set +e
  run_merge_entry "$dir" > /dev/null 2> "$dir/stderr"; rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "merge entrypoint accepted zero arguments"

  [ ! -s "$dir/gh.log" ] || fail "invalid direct or merge data called gh"
  [ ! -s "$dir/gh-axi.log" ] || fail "invalid direct or merge data called gh-axi"
  [ ! -s "$dir/guard.log" ] || fail "invalid direct or merge data called the guard"
  [ ! -e "$TMP_ROOT/escape.check.sh" ] || fail "task traversal wrote outside state"
  pass "PR and teardown entrypoints reject invalid arguments before every side effect"
}

test_valid_recording_and_merge_derivation() {
  local dir expected sidecar count rc
  dir=$(make_case valid-recording)
  write_task_meta "$dir"
  expected=0123456789abcdef0123456789abcdef01234567
  FM_TEST_GH_HEAD=$expected run_check_entry "$dir" task-a https://github.com/my-org/repo_name.with-dots/pull/37 \
    > "$dir/stdout" 2> "$dir/stderr" || fail "valid direct check failed"

  grep -qxF 'pr=https://github.com/my-org/repo_name.with-dots/pull/37' "$dir/home/state/task-a.meta" \
    || fail "canonical pr metadata was not exact"
  grep -qxF "pr_head=$expected" "$dir/home/state/task-a.meta" || fail "PR head metadata was not exact"
  cmp -s "$POLL" "$dir/home/state/task-a.check.sh" || fail "published check was not byte-for-byte static"
  [ "$(file_mode "$dir/home/state/task-a.check.sh")" = 600 ] || fail "published check mode was not 0600"
  [ "$(file_mode "$dir/home/state/task-a.pr-poll")" = 600 ] || fail "published sidecar mode was not 0600"
  [ "$(file_mode "$dir/home/state/task-a.pr-poll-registration")" = 600 ] \
    || fail "published registration mode was not 0600"
  [ "$(fm_pr_file_link_count "$dir/home/state/task-a.check.sh")" = 1 ] \
    && [ "$(fm_pr_file_link_count "$dir/home/state/task-a.pr-poll")" = 1 ] \
    && [ "$(fm_pr_file_link_count "$dir/home/state/task-a.pr-poll-registration")" = 1 ] \
    || fail "published poll artifacts were not single-link files"
  fm_pr_poll_artifacts_valid "$dir/home/state" task-a "$POLL" \
    || fail "published poll provenance or metadata binding was invalid"
  sidecar=$(cat "$dir/home/state/task-a.pr-poll")
  [ "$sidecar" = $'github\nhttps://github.com/my-org/repo_name.with-dots/pull/37\ngithub.com\nmy-org/repo_name.with-dots\n37' ] \
    || fail "published sidecar bytes were not exact"

  FM_TEST_GH_HEAD=$expected run_check_entry "$dir" task-a https://github.com/my-org/repo_name.with-dots/pull/37 \
    >/dev/null 2>/dev/null || fail "valid duplicate check failed"
  count=$(grep -c '^pr=' "$dir/home/state/task-a.meta")
  [ "$count" -eq 1 ] || fail "duplicate pr metadata was appended"
  count=$(grep -c '^pr_head=' "$dir/home/state/task-a.meta")
  [ "$count" -eq 1 ] || fail "duplicate pr_head metadata was appended"

  : > "$dir/gh-axi.log"
  run_merge_entry "$dir" task-a https://github.com/my-org/repo_name.with-dots/pull/37 -- --merge \
    >/dev/null 2>/dev/null || fail "valid merge wrapper failed"
  grep -qxF 'pr merge 37 --repo my-org/repo_name.with-dots --merge' "$dir/gh-axi.log" \
    || fail "merge wrapper did not preserve repository derivation and method"
  # A merge this home performed leaves its own durable outcome, so the poll's
  # confirmation is no longer the first the captain hears of it. Acknowledge that
  # record before the watcher cycle below, which is what still retires the poll.
  assert_grep 'https://github.com/my-org/repo_name.with-dots/pull/37' "$dir/home/state/.wake-queue" \
    "a merge this home performed left no durable outcome"
  ack_watcher_cycle "$dir/home/state" || fail "merge outcome acknowledgement failed"
  # With the merge already reported, the poll's own detection is a duplicate the
  # watcher absorbs, so this cycle needs its own reason to end.
  add_stop_custom_check "$dir"
  set +e
  FM_TEST_GH_STATE=MERGED run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/merged-watch.out" 2> "$dir/merged-watch.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "guarded merge poll retirement failed: $(cat "$dir/merged-watch.err")"
  assert_poll_absent "$dir/home/state" task-a
  assert_no_grep "merged-task-a" "$dir/home/state/.wake-queue" \
    "the drained self-merge outcome was republished by its poll"
  grep -qxF 'pr=https://github.com/my-org/repo_name.with-dots/pull/37' "$dir/home/state/task-a.meta" \
    || fail "guarded merge retirement removed pr metadata"
  grep -qxF "pr_head=$expected" "$dir/home/state/task-a.meta" \
    || fail "guarded merge retirement removed pr_head metadata"

  dir=$(make_case newline-head)
  write_task_meta "$dir"
  FM_TEST_GH_HEAD=$'0123456789abcdef0123456789abcdef01234567\nwindow=unexpected' \
    run_check_entry "$dir" task-a https://github.com/o/r/pull/2 >/dev/null 2>/dev/null \
    || fail "valid check with malformed remote head failed"
  assert_no_grep 'pr_head=' "$dir/home/state/task-a.meta" "multiline PR head reached metadata"
  assert_no_grep 'window=unexpected' "$dir/home/state/task-a.meta" "newline metadata key was injected"

  dir=$(make_case lifecycle-compatible-id)
  write_task_meta "$dir" Task_A.1
  FM_TEST_GH_BRANCH=fm/Task_A.1 run_merge_entry "$dir" Task_A.1 https://github.com/o/r/pull/3 \
    > "$dir/stdout" 2> "$dir/stderr" \
    || fail "safe lifecycle-compatible task ID could not use the PR merge flow"
  fm_pr_poll_artifacts_valid "$dir/home/state" Task_A.1 "$POLL" \
    || fail "safe lifecycle-compatible task ID did not publish an authenticated poll"
  rm -rf "$dir/wt"
  cat > "$dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod 0700 "$dir/fakebin/tmux"
  touch "$dir/home/state/.last-watcher-beat"
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" PATH="$dir/fakebin:$BASE_PATH" \
    "$TEARDOWN" Task_A.1 --force > "$dir/teardown.out" 2> "$dir/teardown.err" \
    || fail "safe lifecycle-compatible task ID could not be torn down"
  [ ! -e "$dir/home/state/Task_A.1.meta" ] \
    || fail "safe lifecycle-compatible task teardown retained metadata"

  for id in _noncanonical aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; do
    dir=$(make_case "legacy-teardown-${id:0:12}")
    fm_write_meta "$dir/home/state/$id.meta" \
      "window=firstmate:fm-$id" \
      "endpoint_task_id=$id" \
      "worktree=$dir/missing-worktree" \
      "project=$dir/project" \
      'kind=ship' \
      'mode=local-only'
    cat > "$dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
    chmod 0700 "$dir/fakebin/tmux"
    touch "$dir/home/state/.last-watcher-beat"
    mkdir "$dir/home/state/$id.check.sh"
    set +e
    FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" PATH="$dir/fakebin:$BASE_PATH" \
      "$TEARDOWN" "$id" --force > "$dir/unsafe-teardown.out" 2> "$dir/unsafe-teardown.err"
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "legacy task teardown accepted an unsafe direct artifact"
    [ -e "$dir/home/state/$id.meta" ] \
      || fail "legacy task teardown mutated lifecycle state before artifact refusal"
    [ -d "$dir/home/state/$id.check.sh" ] \
      || fail "legacy task teardown changed the unsafe direct artifact"
    rmdir "$dir/home/state/$id.check.sh"
    FM_HOME="$dir/home" "$ROOT/bin/fm-x-link.sh" "$id" req-legacy \
      --carry-count 0 --carry-ts 1700000000 --carry-platform x --carry-max 280 \
      > "$dir/x-link.out" 2> "$dir/x-link.err" \
      || fail "path-safe legacy task ID could not link an X request"
    FM_TEST_GH_BRANCH="fm/$id" run_merge_entry "$dir" "$id" https://github.com/o/r/pull/4 \
      > "$dir/merge.out" 2> "$dir/merge.err" \
      || fail "path-safe legacy task ID could not use the PR merge flow"
    fm_pr_poll_artifacts_valid "$dir/home/state" "$id" "$POLL" \
      || fail "path-safe legacy task ID did not publish an authenticated poll"
    FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" PATH="$dir/fakebin:$BASE_PATH" \
      "$TEARDOWN" "$id" --force > "$dir/teardown.out" 2> "$dir/teardown.err" \
      || fail "legacy path-safe task ID could not be torn down"
    [ ! -e "$dir/home/state/$id.meta" ] || fail "legacy task teardown retained metadata"
  done
  pass "valid direct and merge flows record exact metadata and reject multiline head metadata"
}

run_watcher_bounded() {
  local home=$1 fakebin=$2 check_interval=${FM_TEST_CHECK_INTERVAL:-0} watch_root=${FM_TEST_WATCH_ROOT:-$ROOT}
  shift 2
  perl -e 'my $pid=fork; die unless defined $pid; if (!$pid) { exec @ARGV } local $SIG{ALRM}=sub { kill "TERM", $pid; waitpid $pid, 0; exit 124 }; alarm 10; waitpid $pid, 0; alarm 0; exit($? >> 8)' \
    env FM_HOME="$home" FM_ROOT_OVERRIDE="$watch_root" FM_CHECK_INTERVAL="$check_interval" FM_CHECK_TIMEOUT=1 \
      FM_POLL=0.02 FM_HEARTBEAT=999999 FM_SIGNAL_GRACE=0 PATH="$fakebin:$BASE_PATH" "$WATCH" "$@"
}

test_rejected_metacharacter_bytes_are_inert() {
  local dir family rc before after
  dir=$(make_case rejected-metacharacters)
  write_task_meta "$dir"
  write_poll_meta "$dir/home/state" safe-check https://github.com/o/r/pull/99
  families=(
    'https://github.com/o$/r/pull/1'
    'https://github.com/o(/r/pull/1'
    'https://github.com/o)/r/pull/1'
    'https://github.com/o`/r/pull/1'
  )
  for family in "${families[@]}"; do
    rm -f "$dir/home/state/task-a.check.sh" "$dir/home/state/task-a.pr-poll"
    set +e
    run_check_entry "$dir" task-a "$family" > /dev/null 2> "$dir/stderr"
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "rejected metacharacter byte was accepted"
    [ ! -e "$dir/home/state/task-a.check.sh" ] || fail "rejected input left a runnable task check"
    [ ! -e "$dir/home/state/task-a.pr-poll" ] || fail "rejected input left a sidecar"
    fm_pr_poll_prepare "$dir/home/state" safe-check github https://github.com/o/r/pull/99 github.com o/r 99 "$POLL" \
      || fail "could not prepare bounded watcher poll"
    fm_pr_poll_publish_prepared || fail "could not publish bounded watcher poll"

    set +e
    FM_TEST_GH_STATE=MERGED run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/watch.out" 2> "$dir/watch.err"
    rc=$?
    set -e
    [ "$rc" -eq 0 ] || fail "bounded watcher did not complete through the authenticated poll"
    rm -f "$dir/home/state/.last-check"
  done

  FM_TEST_GH_STATE=OPEN run_check_entry "$dir" task-a https://github.com/o/r/pull/1 >/dev/null 2>/dev/null \
    || fail "could not seed a prior valid static poll"
  before=$(state_snapshot "$dir/home/state")
  set +e
  run_check_entry "$dir" task-a "${families[0]}" >/dev/null 2>/dev/null
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "rejected replacement was accepted"
  after=$(state_snapshot "$dir/home/state")
  [ "$after" = "$before" ] || fail "rejected replacement changed a prior valid static poll"
  pass "rejected metacharacter bytes remain inert at generation and watcher time"
}

make_poll_fixture() {
  local dir=$1
  cp "$POLL" "$dir/home/state/task-a.check.sh"
  printf '%s\n%s\n%s\n%s\n%s\n' \
    github https://github.com/o/r/pull/1 github.com o/r 1 > "$dir/home/state/task-a.pr-poll"
  chmod 0600 "$dir/home/state/task-a.check.sh" "$dir/home/state/task-a.pr-poll"
}

run_poll() {
  local dir=$1
  FM_TEST_GH_LOG="$dir/gh.log" FM_TEST_GLAB_LOG="$dir/glab.log" \
    PATH="$dir/fakebin:$BASE_PATH" \
    bash "$dir/home/state/task-a.check.sh"
}

test_static_poll_contract() {
  local dir state out rc
  dir=$(make_case poll-contract)
  make_poll_fixture "$dir"

  for state in OPEN CLOSED EMPTY MALFORMED; do
    case "$state" in
      EMPTY) value= ;;
      MALFORMED) value='not-a-state' ;;
      *) value=$state ;;
    esac
    out=$(FM_TEST_GH_STATE="$value" run_poll "$dir")
    [ -z "$out" ] || fail "static poll emitted for non-merged state"
  done
  out=$(FM_TEST_GH_STATE=MERGED run_poll "$dir")
  [ "$out" = merged ] || fail "static poll did not emit exactly one merged line"
  out=$(FM_TEST_GH_FAIL=1 run_poll "$dir")
  [ -z "$out" ] || fail "static poll emitted after gh failure"

  mv "$dir/home/state/task-a.pr-poll" "$dir/home/state/task-a.pr-poll.missing"
  out=$(run_poll "$dir")
  [ -z "$out" ] || fail "static poll emitted with missing sidecar"
  mv "$dir/home/state/task-a.pr-poll.missing" "$dir/home/state/task-a.pr-poll"
  printf '%s\n%s\n%s\n%s\n%s\n%s\n' github https://github.com/o/r/pull/1 github.com o/r 1 extra > "$dir/home/state/task-a.pr-poll"
  out=$(FM_TEST_GH_STATE=MERGED run_poll "$dir")
  [ -z "$out" ] || fail "static poll emitted with multiline sidecar"
  printf '%s\n%s\n%s\n%s\n%s\n' github https://github.com/o/r/pull/1x github.com o/r 1x > "$dir/home/state/task-a.pr-poll"
  out=$(FM_TEST_GH_STATE=MERGED run_poll "$dir")
  [ -z "$out" ] || fail "static poll emitted with malformed numeric data"

  make_poll_fixture "$dir"
  set +e
  out=$(FM_STATE_OVERRIDE="$dir/home/state" FM_CHECK_TIMEOUT=1 FM_TEST_GH_LOG="$dir/gh.log" \
    FM_TEST_GH_SLEEP=3 PATH="$dir/fakebin:$BASE_PATH" \
    bash -c '. "$1"; run_check "$2"' bash "$WATCH" "$dir/home/state/task-a.check.sh")
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "watcher run_check timeout wrapper failed"
  [ -z "$out" ] || fail "timed-out static poll emitted output"

  write_poll_meta "$dir/home/state" task-a https://github.com/o/r/pull/1
  fm_pr_poll_prepare "$dir/home/state" task-a github https://github.com/o/r/pull/1 github.com o/r 1 "$POLL" \
    || fail "could not prepare authenticated watcher poll"
  fm_pr_poll_publish_prepared || fail "could not publish authenticated watcher poll"
  rm -f "$dir/home/state/.last-check"
  set +e
  FM_TEST_GH_STATE=MERGED run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/watch.out" 2> "$dir/watch.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "watcher did not surface merged poll"
  [ "$(grep -c '^check: .*: merged$' "$dir/watch.out")" -eq 1 ] || fail "watcher did not convert merged output into exactly one wake"
  pass "static poll is silent except for one merged line and remains watcher-bounded"
}

test_atomic_interruption_leaves_no_partial_artifact() {
  local dir rc
  dir=$(make_case interrupted-write)
  write_task_meta "$dir"
  cat > "$dir/fakebin/cp" <<SH
#!/usr/bin/env bash
'$REAL_CP' "\$@" || exit 1
kill -TERM "\$PPID"
exit 0
SH
  chmod +x "$dir/fakebin/cp"

  set +e
  run_check_entry "$dir" task-a https://github.com/o/r/pull/1 > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "interrupted publication unexpectedly succeeded"
  [ ! -e "$dir/home/state/task-a.check.sh" ] || fail "interrupted publication left a runnable check"
  [ ! -e "$dir/home/state/task-a.pr-poll" ] || fail "interrupted publication left a sidecar"
  [ ! -e "$dir/home/state/task-a.pr-poll-registration" ] \
    || fail "interrupted publication left a registration"
  ! find "$dir/home/state" -name '.fm-pr-poll-*' -print | grep . >/dev/null \
    || fail "interrupted publication left temporary files"
  assert_no_grep 'pr=' "$dir/home/state/task-a.meta" "interrupted preparation changed metadata"
  pass "interrupted atomic preparation cleans private temporaries and publishes nothing"
}

test_concurrent_watcher_sees_only_complete_publication() {
  local n dir direct_pid rc i
  n=1
  while [ "$n" -le 3 ]; do
    dir=$(make_case "concurrent-$n")
    write_task_meta "$dir"
    cat > "$dir/fakebin/cp" <<SH
#!/usr/bin/env bash
'$REAL_CP' "\$@" || exit 1
sleep 0.3
SH
    chmod +x "$dir/fakebin/cp"

    FM_TEST_GH_HEAD=0123456789abcdef0123456789abcdef01234567 \
      run_check_entry "$dir" task-a https://github.com/o/r/pull/1 > "$dir/direct.out" 2> "$dir/direct.err" &
    direct_pid=$!
    i=0
    while [ "$i" -lt 100 ] && ! find "$dir/home/state" -name '.fm-pr-poll-check.*' -print | grep . >/dev/null; do
      sleep 0.01
      i=$((i + 1))
    done
    [ "$i" -lt 100 ] || fail "atomic publication did not reach staged check"

    set +e
    FM_TEST_GH_STATE=MERGED run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/watch.out" 2> "$dir/watch.err"
    rc=$?
    set -e
    wait "$direct_pid" || fail "concurrent direct arming failed"
    [ "$rc" -eq 0 ] || fail "concurrent watcher did not complete"
    grep -q '^check: .*: merged$' "$dir/watch.out" || fail "concurrent watcher never saw complete poll"
    [ ! -s "$dir/watch.err" ] || fail "concurrent watcher observed a partial artifact error"
    if [ -e "$dir/home/state/task-a.check.sh" ]; then
      cmp -s "$POLL" "$dir/home/state/task-a.check.sh" || fail "concurrent publication check bytes changed"
      [ "$(file_mode "$dir/home/state/task-a.check.sh")" = 600 ] || fail "concurrent check mode was not private"
      [ "$(file_mode "$dir/home/state/task-a.pr-poll")" = 600 ] || fail "concurrent sidecar mode was not private"
      [ "$(file_mode "$dir/home/state/task-a.pr-poll-registration")" = 600 ] \
        || fail "concurrent registration mode was not private"
      fm_pr_poll_artifacts_valid "$dir/home/state" task-a "$POLL" \
        || fail "concurrent publication did not leave canonical provenance"
    else
      assert_poll_absent "$dir/home/state" task-a
    fi
    n=$((n + 1))
  done
  pass "concurrent watchers observe only complete private poll publications"
}

test_poll_publication_refuses_unsafe_destinations() {
  local artifact kind dir state destination
  for artifact in task-a.pr-poll task-a.pr-poll-registration task-a.check.sh; do
    for kind in regular dangling directory; do
      dir=$(make_case "poll-path-${artifact//./-}-$kind")
      state="$dir/home/state"
      fm_pr_poll_prepare "$state" task-a github https://github.com/o/r/pull/1 github.com o/r 1 "$POLL" \
        || fail "could not stage poll symlink refusal fixture"
      destination="$state/$artifact"
      make_private_symlink "$dir" "$destination" "$kind"
      if fm_pr_poll_publish_prepared; then
        fail "poll publication accepted a private destination symlink"
      fi
      fm_pr_poll_cleanup
      assert_private_symlink_unchanged "$destination"
      [ ! -e "$state/task-a.pr-poll" ] || [ "$artifact" = task-a.pr-poll ] \
        || fail "check destination refusal published the sidecar"
    done

    dir=$(make_case "poll-path-${artifact//./-}-direct-directory")
    state="$dir/home/state"
    fm_pr_poll_prepare "$state" task-a github https://github.com/o/r/pull/1 github.com o/r 1 "$POLL" \
      || fail "could not stage poll directory refusal fixture"
    destination="$state/$artifact"
    mkdir "$destination"
    if fm_pr_poll_publish_prepared; then
      fail "poll publication accepted a directory destination"
    fi
    fm_pr_poll_cleanup
    [ -d "$destination" ] || fail "poll publication replaced a directory destination"
    [ -z "$(find "$destination" -mindepth 1 -maxdepth 1 -print)" ] \
      || fail "poll publication wrote inside a directory destination"
  done
  pass "poll publication paths refuse symlinks and directories"
}

test_live_artifact_single_link_and_privacy_validation() {
  local artifact dir state alias rc
  for artifact in check.sh pr-poll pr-poll-registration; do
    dir=$(make_case "single-link-live-${artifact//./-}")
    state="$dir/home/state"
    write_task_meta "$dir"
    run_check_entry "$dir" task-a https://github.com/o/r/pull/10 >/dev/null 2>/dev/null \
      || fail "could not publish $artifact hard-link fixture"
    fm_pr_poll_artifacts_valid "$state" task-a "$POLL" \
      || fail "$artifact fixture was not initially authenticated"
    alias="$dir/$artifact.alias"
    ln "$state/task-a.$artifact" "$alias"
    if [ "$artifact" = pr-poll ]; then
      printf '%s\n%s\n%s\n%s\n' https://github.com/o/r/pull/11 o r 11 > "$alias"
    fi
    ! fm_pr_poll_artifacts_valid "$state" task-a "$POLL" \
      || fail "$artifact hard link remained authenticated"
    [ -e "$alias" ] || fail "$artifact hard-link refusal removed the external alias"
  done

  dir=$(make_case single-link-custom-check-registration)
  state="$dir/home/state"
  printf '#!/usr/bin/env bash\nprintf "custom-ready\\n"\n' > "$state/custom.check.sh"
  chmod 0700 "$state/custom.check.sh"
  alias="$dir/custom-check.alias"
  ln "$state/custom.check.sh" "$alias"
  set +e
  FM_HOME="$dir/home" "$REGISTER" custom > "$dir/register.out" 2> "$dir/register.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "custom check registration accepted a hard-linked source"
  [ ! -e "$state/custom.check-trust" ] || fail "rejected hard-linked custom check received a trust record"
  rm -f "$alias"
  FM_HOME="$dir/home" "$REGISTER" custom >/dev/null \
    || fail "could not register the custom check single-link fixture"
  ln "$state/custom.check.sh" "$alias"
  ! fm_custom_check_registered "$state" custom \
    || fail "registered custom check remained authenticated after source hard-linking"
  ! fm_custom_check_snapshot_prepare "$state" custom \
    || fail "watcher snapshot accepted a hard-linked custom check source"
  fm_custom_check_snapshot_cleanup
  rm -f "$alias"
  alias="$dir/custom-trust.alias"
  ln "$state/custom.check-trust" "$alias"
  ! fm_custom_check_registered "$state" custom \
    || fail "hard-linked custom check trust remained authenticated"
  ! fm_custom_check_snapshot_prepare "$state" custom \
    || fail "watcher snapshot accepted a hard-linked custom check trust record"
  fm_custom_check_snapshot_cleanup
  [ -e "$alias" ] || fail "custom-check hard-link refusal removed the external alias"

  dir=$(make_case private-custom-check-source)
  state="$dir/home/state"
  printf '#!/usr/bin/env bash\nprintf "custom-ready\\n"\n' > "$state/custom.check.sh"
  chmod 0755 "$state/custom.check.sh"
  set +e
  FM_HOME="$dir/home" "$REGISTER" custom > "$dir/register.out" 2> "$dir/register.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "custom check registration accepted a non-private source"
  [ ! -e "$state/custom.check-trust" ] || fail "non-private custom check received a trust record"
  chmod 0700 "$state/custom.check.sh"
  FM_HOME="$dir/home" "$REGISTER" custom >/dev/null \
    || fail "could not register private custom check fixture"
  chmod 0755 "$state/custom.check.sh"
  ! fm_custom_check_registered "$state" custom \
    || fail "registered custom check remained authenticated after becoming non-private"
  ! fm_custom_check_snapshot_prepare "$state" custom \
    || fail "watcher snapshot accepted a non-private custom check source"
  fm_custom_check_snapshot_cleanup
  pass "live poll and custom-check artifacts require private single-link files"
}

install_final_publication_fault() {
  local dir=$1
  cat > "$dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
last=${!#}
"${FM_TEST_REAL_MV:?}" "$@" || exit $?
[ "$last" = "${FM_TEST_FINAL_PATH:?}" ] || exit 0
case "${FM_TEST_FINAL_ACTION:?}" in
  type)
    rm -f -- "$last"
    ln -s "${FM_TEST_FAULT_LINK_TARGET:?}" "$last"
    ;;
  mode) "${FM_TEST_REAL_CHMOD:?}" 0644 "$last" ;;
  content) printf 'faulted final bytes\n' > "$last" ;;
  device) : > "${FM_TEST_FAULT_GATE:?}" ;;
  *) exit 2 ;;
esac
SH
  cat > "$dir/fakebin/stat" <<'SH'
#!/usr/bin/env bash
last=${!#}
if [ "$last" = "${FM_TEST_FINAL_PATH:-}" ] && [ -e "${FM_TEST_FAULT_GATE:-/nonexistent}" ]; then
  case " $* " in
    *" %d "*) printf '%s\n' 999999; exit 0 ;;
  esac
fi
exec "${FM_TEST_REAL_STAT:?}" "$@"
SH
  chmod +x "$dir/fakebin/mv" "$dir/fakebin/stat"
}

assert_no_final_poll() {
  local state=$1
  [ ! -e "$state/task-a.check.sh" ] && [ ! -L "$state/task-a.check.sh" ] \
    || fail "failed publication left a runnable check name"
  [ ! -e "$state/task-a.pr-poll" ] && [ ! -L "$state/task-a.pr-poll" ] \
    || fail "failed publication left a sidecar name"
  [ ! -e "$state/task-a.pr-poll-registration" ] && [ ! -L "$state/task-a.pr-poll-registration" ] \
    || fail "failed publication left a registration name"
}

test_postrename_poll_validation_revokes_and_retries() {
  local artifact action dir state destination link_target gate
  for artifact in data registration check; do
    for action in type mode device content; do
      dir=$(make_case "poll-final-$artifact-$action")
      state="$dir/home/state"
      write_poll_meta "$state" task-a https://github.com/o/r/pull/1
      fm_pr_poll_prepare "$state" task-a github https://github.com/o/r/pull/1 github.com o/r 1 "$POLL" \
        || fail "could not prepare prior poll"
      fm_pr_poll_publish_prepared || fail "could not publish prior poll"
      write_poll_meta "$state" task-a https://github.com/o/r/pull/2
      fm_pr_poll_prepare "$state" task-a github https://github.com/o/r/pull/2 github.com o/r 2 "$POLL" \
        || fail "could not stage replacement poll"
      case "$artifact" in
        data) destination="$state/task-a.pr-poll" ;;
        registration) destination="$state/task-a.pr-poll-registration" ;;
        check) destination="$state/task-a.check.sh" ;;
      esac
      link_target="$dir/external-sentinel"
      gate="$dir/device-fault"
      printf 'external sentinel\n' > "$link_target"
      chmod 0644 "$link_target"
      install_final_publication_fault "$dir"
      if FM_TEST_FINAL_PATH="$destination" FM_TEST_FINAL_ACTION="$action" \
        FM_TEST_FAULT_LINK_TARGET="$link_target" FM_TEST_FAULT_GATE="$gate" \
        FM_TEST_REAL_MV="$REAL_MV" FM_TEST_REAL_STAT="$REAL_STAT" FM_TEST_REAL_CHMOD="$REAL_CHMOD" \
        PATH="$dir/fakebin:$BASE_PATH" fm_pr_poll_publish_prepared; then
        fail "post-rename $artifact $action fault was reported as success"
      fi
      fm_pr_poll_cleanup
      assert_no_final_poll "$state"
      [ "$(cat "$link_target")" = 'external sentinel' ] || fail "poll type fault changed an external target"
      [ "$(file_mode "$link_target")" = 644 ] || fail "poll type fault changed an external target mode"

      fm_pr_poll_prepare "$state" task-a github https://github.com/o/r/pull/2 github.com o/r 2 "$POLL" \
        || fail "could not prepare poll retry"
      PATH="$BASE_PATH" fm_pr_poll_publish_prepared || fail "poll retry did not recover after final validation fault"
      fm_pr_poll_artifacts_valid "$state" task-a "$POLL" || fail "poll retry did not publish a valid pair"
    done
  done
  pass "post-rename poll validation faults revoke both names and allow a clean retry"
}

test_bootstrap_leaves_unauthenticated_checks() {
  local dir state
  dir=$(make_case bootstrap-no-legacy-rewrite)
  state="$dir/home/state"
  fm_write_meta "$state/task-a.meta" \
    'window=fm-task-a' \
    'pr=https://github.com/o/r/pull/11'
  printf 'legacy bytes\n' > "$state/task-a.check.sh"
  chmod 0700 "$state/task-a.check.sh"

  mkdir -p "$dir/home/config"
  printf '%s\n' manual > "$dir/home/config/backlog-backend"
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_BOOTSTRAP_NETWORK=skip \
    PATH="$dir/fakebin:$BASE_PATH" \
    "$ROOT/bin/fm-bootstrap.sh" > "$dir/bootstrap.out" 2> "$dir/bootstrap.err" \
    || fail "bootstrap failed after migration retirement"
  [ "$(cat "$state/task-a.check.sh")" = 'legacy bytes' ] \
    || fail "bootstrap rewrote an unauthenticated check after migration retirement"
  assert_no_grep 'PR_CHECK_MIGRATION' "$dir/bootstrap.out" \
    "bootstrap still emitted a retired migration diagnostic on stdout"
  assert_no_grep 'PR_CHECK_MIGRATION' "$dir/bootstrap.err" \
    "bootstrap still emitted a retired migration diagnostic on stderr"
  pass "bootstrap does not rewrite unauthenticated checks or emit retired migration diagnostics"
}

test_custom_snapshot_cleanup_on_signal() {
  local dir state child_pid_file pid child_pid i rc
  dir=$(make_case custom-snapshot-signal)
  state="$dir/home/state"
  child_pid_file="$dir/custom-child.pid"
  # shellcheck disable=SC2016  # The generated child expands $$ when it runs.
  printf '%s\n' '#!/usr/bin/env bash' 'trap "" TERM' \
    'printf "%s\n" "$$" > "$FM_TEST_CUSTOM_CHILD_PID"' 'while :; do sleep 1; done' \
    > "$state/custom.check.sh"
  chmod 0700 "$state/custom.check.sh"
  cat > "$dir/fakebin/timeout" <<'SH'
#!/usr/bin/env bash
shift
"$@" &
child=$!
trap 'kill -TERM "$child" 2>/dev/null; exit 124' TERM
wait "$child"
SH
  chmod 0700 "$dir/fakebin/timeout"
  FM_HOME="$dir/home" "$REGISTER" custom >/dev/null \
    || fail "could not register signal cleanup custom check"

  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_POLL=0 FM_CHECK_INTERVAL=0 \
    FM_SIGNAL_GRACE=0 FM_TEST_CUSTOM_CHILD_PID="$child_pid_file" \
    PATH="$dir/fakebin:$BASE_PATH" "$WATCH" \
    > "$dir/watch.out" 2> "$dir/watch.err" &
  pid=$!
  i=0
  while [ "$i" -lt 100 ]; do
    [ -s "$child_pid_file" ] && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.02
    i=$((i + 1))
  done
  [ -s "$child_pid_file" ] || fail "watcher did not start the custom check child"
  find "$state" -maxdepth 1 -name '.fm-custom-check.*' -print | grep . >/dev/null \
    || fail "watcher did not create the custom check snapshot"
  child_pid=$(cat "$child_pid_file")
  kill -TERM "$pid" 2>/dev/null || fail "could not signal watcher during custom check"
  i=0
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 100 ]; do
    sleep 0.02
    i=$((i + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "signaled watcher did not exit promptly"
  fi
  rc=0
  wait "$pid" || rc=$?
  [ "$rc" -ne 0 ] || fail "signaled watcher exited successfully"
  ! kill -0 "$child_pid" 2>/dev/null || fail "signaled watcher left the custom check child running"
  ! find "$state" -maxdepth 1 -name '.fm-custom-check.*' -print | grep . >/dev/null \
    || fail "signaled watcher left a private custom check snapshot"
  ! find "$state" -maxdepth 1 -name '.fm-check-output.*' -print | grep . >/dev/null \
    || fail "signaled watcher left a private check output file"
  [ ! -e "$state/.watch.lock/pid" ] || fail "signaled watcher left its singleton lock"
  pass "watcher signals promptly stop custom checks and clean private state"
}

test_returned_custom_check_descendants_are_drained() {
  local backend dir state fakebin ready direct_done child_pid_file sentinel watcher_pid child_pid i rc alive force_fallback
  for backend in installed-timeout fallback-timeout; do
    dir=$(make_case "returned-custom-descendant-$backend")
    state="$dir/home/state"
    fakebin="$dir/fakebin"
    ready="$dir/descendant-ready"
    direct_done="$dir/direct-check-done"
    child_pid_file="$dir/descendant.pid"
    sentinel="$dir/descendant-sentinel"
    cat > "$state/custom.check.sh" <<'SH'
#!/usr/bin/env bash
perl -e '$SIG{TERM}="IGNORE"; open my $ready, ">", $ENV{FM_TEST_DESCENDANT_READY} or die $!; print {$ready} "ready\n"; close $ready; select undef, undef, undef, 4; open my $sentinel, ">", $ENV{FM_TEST_DESCENDANT_SENTINEL} or die $!; print {$sentinel} "late\n"; close $sentinel; select undef, undef, undef, 1' &
printf '%s\n' "$!" > "$FM_TEST_DESCENDANT_PID"
while [ ! -s "$FM_TEST_DESCENDANT_READY" ]; do sleep 0.01; done
: > "$FM_TEST_DIRECT_DONE"
SH
    chmod 0700 "$state/custom.check.sh"
    FM_HOME="$dir/home" "$REGISTER" custom >/dev/null \
      || fail "could not register $backend returned-descendant check"
    if [ "$backend" = installed-timeout ]; then
      cat > "$fakebin/timeout" <<'SH'
#!/usr/bin/env bash
shift
exec "$@"
SH
      chmod 0700 "$fakebin/timeout"
      force_fallback=0
    else
      rm -f "$fakebin/timeout" "$fakebin/gtimeout"
      force_fallback=1
    fi

    FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_POLL=0.1 FM_CHECK_INTERVAL=999999 \
      FM_CHECK_TIMEOUT=10 FM_HEARTBEAT=999999 FM_SIGNAL_GRACE=0 \
      FM_CHECK_FORCE_FALLBACK="$force_fallback" FM_TEST_DESCENDANT_READY="$ready" \
      FM_TEST_DESCENDANT_SENTINEL="$sentinel" FM_TEST_DESCENDANT_PID="$child_pid_file" \
      FM_TEST_DIRECT_DONE="$direct_done" PATH="$fakebin:$BASE_PATH" "$WATCH" \
      > "$dir/watch.out" 2> "$dir/watch.err" &
    watcher_pid=$!
    i=0
    while [ "$i" -lt 200 ]; do
      [ -s "$ready" ] && [ -s "$child_pid_file" ] && [ -e "$direct_done" ] \
        && [ -e "$state/.last-check" ] && break
      kill -0 "$watcher_pid" 2>/dev/null || break
      sleep 0.02
      i=$((i + 1))
    done
    [ -s "$ready" ] && [ -s "$child_pid_file" ] && [ -e "$direct_done" ] \
      && [ -e "$state/.last-check" ] \
      || fail "$backend watcher did not complete the direct custom check"
    child_pid=$(cat "$child_pid_file")
    kill -TERM "$watcher_pid" 2>/dev/null || fail "could not stop $backend watcher"
    i=0
    while process_is_live_non_zombie "$watcher_pid" && [ "$i" -lt 150 ]; do
      sleep 0.02
      i=$((i + 1))
    done
    if process_is_live_non_zombie "$watcher_pid"; then
      kill -KILL "$watcher_pid" 2>/dev/null || true
      wait "$watcher_pid" 2>/dev/null || true
      kill -KILL "$child_pid" 2>/dev/null || true
      fail "$backend watcher did not stop after the direct check returned"
    fi
    rc=0
    wait "$watcher_pid" || rc=$?
    [ "$rc" -ne 0 ] || fail "$backend signaled watcher exited successfully"
    alive=0
    process_is_live_non_zombie "$child_pid" && alive=1
    [ "$alive" -eq 0 ] || kill -KILL "$child_pid" 2>/dev/null || true
    wait "$child_pid" 2>/dev/null || true
    [ "$alive" -eq 0 ] || fail "$backend watcher left a returned check descendant alive"
    [ ! -e "$sentinel" ] || fail "$backend returned check descendant reached its sentinel"
    ! find "$state" -maxdepth 1 -name '.fm-custom-check.*' -print | grep . >/dev/null \
      || fail "$backend watcher left a private custom check snapshot"
    ! find "$state" -maxdepth 1 -name '.fm-check-output.*' -print | grep . >/dev/null \
      || fail "$backend watcher left a private check output file"
    [ ! -e "$state/.watch.lock/pid" ] || fail "$backend watcher left its singleton lock"
  done
  pass "returned custom check descendants are drained on installed and fallback timeout paths"
}

test_teardown_removes_poll_artifacts() {
  local dir fakebin artifact counterpart rc
  dir=$(make_case teardown-cleanup)
  fakebin="$dir/fakebin"
  fm_write_meta "$dir/home/state/task-a.meta" \
    'window=firstmate:fm-task-a' \
    'endpoint_task_id=task-a' \
    "worktree=$dir/missing-worktree" \
    "project=$dir/project" \
    'kind=ship' \
    'mode=local-only'
  printf 'check\n' > "$dir/home/state/task-a.check.sh"
  printf 'data\n' > "$dir/home/state/task-a.pr-poll"
  printf 'registration\n' > "$dir/home/state/task-a.pr-poll-registration"
  printf 'trust\n' > "$dir/home/state/task-a.check-trust"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/tmux"
  touch "$dir/home/state/.last-watcher-beat"

  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" PATH="$fakebin:$BASE_PATH" \
    "$TEARDOWN" task-a --force > "$dir/teardown.out" 2> "$dir/teardown.err" \
    || fail "teardown cleanup fixture failed"
  [ ! -e "$dir/home/state/task-a.check.sh" ] || fail "teardown left the runnable check"
  [ ! -e "$dir/home/state/task-a.pr-poll" ] || fail "teardown left the sidecar"
  [ ! -e "$dir/home/state/task-a.pr-poll-registration" ] || fail "teardown left the PR poll registration"
  [ ! -e "$dir/home/state/task-a.check-trust" ] || fail "teardown left the custom check registration"

  dir=$(make_case teardown-retirement-receipt)
  fakebin="$dir/fakebin"
  fm_write_meta "$dir/home/state/task-a.meta" \
    'window=firstmate:fm-task-a' \
    'endpoint_task_id=task-a' \
    "worktree=$dir/missing-worktree" \
    "project=$dir/project" \
    'kind=ship' \
    'mode=local-only' \
    'pr=https://github.com/o/r/pull/18'
  seed_canonical_poll "$dir" task-a https://github.com/o/r/pull/18
  fm_pr_poll_snapshot_capture "$dir/home/state" task-a "$POLL" \
    || fail "could not snapshot teardown receipt fixture"
  fm_pr_poll_retirement_publish "$dir/home/state" task-a "$POLL" merged \
    || fail "could not publish teardown receipt fixture"
  rm -f "$dir/home/state/task-a.check.sh"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/tmux"
  touch "$dir/home/state/.last-watcher-beat"
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" PATH="$fakebin:$BASE_PATH" \
    "$TEARDOWN" task-a --force > "$dir/teardown.out" 2> "$dir/teardown.err" \
    || fail "teardown could not finish a valid crash-left retirement receipt"
  assert_poll_absent "$dir/home/state" task-a
  [ ! -e "$dir/home/state/task-a.meta" ] || fail "receipt-aware teardown left task metadata"

  for artifact in check.sh pr-poll; do
    dir=$(make_case "teardown-final-directory-${artifact//./-}")
    fakebin="$dir/fakebin"
    fm_write_meta "$dir/home/state/task-a.meta" \
      'window=firstmate:fm-task-a' \
      'endpoint_task_id=task-a' \
      "worktree=$dir/missing-worktree" \
      "project=$dir/project" \
      'kind=ship' \
      'mode=local-only'
    if [ "$artifact" = check.sh ]; then
      counterpart=pr-poll
    else
      counterpart=check.sh
    fi
    mkdir "$dir/home/state/task-a.$artifact"
    printf 'directory sentinel\n' > "$dir/home/state/task-a.$artifact/sentinel"
    printf 'counterpart sentinel\n' > "$dir/home/state/task-a.$counterpart"
    cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_FAKE_TMUX_LOG:?}"
exit 0
SH
    chmod +x "$fakebin/tmux"
    touch "$dir/home/state/.last-watcher-beat"
    set +e
    FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_FAKE_TMUX_LOG="$dir/tmux.log" \
      PATH="$fakebin:$BASE_PATH" "$TEARDOWN" task-a --force \
      > "$dir/teardown.out" 2> "$dir/teardown.err"
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "teardown accepted a directory-shaped $artifact"
    [ -e "$dir/home/state/task-a.meta" ] || fail "teardown removed metadata before $artifact refusal"
    [ "$(cat "$dir/home/state/task-a.$artifact/sentinel")" = 'directory sentinel' ] \
      || fail "teardown changed the directory-shaped $artifact"
    [ "$(cat "$dir/home/state/task-a.$counterpart")" = 'counterpart sentinel' ] \
      || fail "teardown removed the counterpart before $artifact refusal"
    grep -F 'kill-window' "$dir/tmux.log" >/dev/null 2>&1 \
      && fail "teardown killed the endpoint before $artifact refusal"
  done

  pass "teardown removes safe poll artifacts and refuses directory-shaped check files without traversal"
}

# The GitLab watch must follow a merge request exactly as the GitHub watch
# follows a pull request, on any instance, and must never turn an unreadable
# merge request into a merge. Its evidence against the public fixture project
# https://gitlab.com/KarotKris/gitlab-merge-watch-fixture is in
# docs/gitlab-merge-watch.md; this exercises the same paths hermetically.
test_gitlab_merge_watch() {
  local dir state out rc url value noglab entry bindir name
  dir=$(make_case gitlab-merge-watch)
  state="$dir/home/state"
  url=https://gitlab.example/group/subgroup/project/-/merge_requests/7

  write_poll_meta "$state" task-a "$url"
  fm_pr_poll_prepare "$state" task-a gitlab "$url" gitlab.example group/subgroup/project 7 "$POLL" \
    || fail "could not prepare a GitLab poll"
  fm_pr_poll_publish_prepared || fail "could not publish a GitLab poll"
  fm_pr_poll_artifacts_valid "$state" task-a "$POLL" \
    || fail "published GitLab poll provenance or metadata binding was invalid"
  [ "$(cat "$state/task-a.pr-poll")" = "gitlab
$url
gitlab.example
group/subgroup/project
7" ] || fail "published GitLab sidecar bytes were not exact"

  # Only an exact merged state wakes firstmate. Every other reading, including
  # an unreadable merge request and a changed output format, stays silent.
  for value in opened closed locked '' not-a-state MERGED merged-but-not; do
    out=$(FM_TEST_GLAB_STATE="$value" run_poll "$dir")
    [ -z "$out" ] || fail "GitLab poll emitted for a non-merged state"
  done
  out=$(FM_TEST_GLAB_STATE=merged run_poll "$dir")
  [ "$out" = merged ] || fail "GitLab poll did not emit exactly one merged line"
  out=$(FM_TEST_GLAB_FAIL=1 run_poll "$dir")
  [ -z "$out" ] || fail "GitLab poll emitted after a glab failure"

  # glab is addressed by project URL and merge request number, never by the
  # merge request URL, which the real CLI resolves through the current git
  # repository the watcher does not have.
  grep -qF -- "mr view 7 -R https://gitlab.example/group/subgroup/project" "$dir/glab.log" \
    || fail "GitLab poll did not address glab by project URL and merge request number"
  ! grep -qF -- "$url" "$dir/glab.log" \
    || fail "GitLab poll passed a merge request URL to glab"

  # An absent CLI must produce no wake rather than a false merge. The whole
  # search path is mirrored without glab, because a real glab anywhere on
  # PATH would make this prove nothing.
  noglab="$dir/noglab"
  mkdir -p "$noglab"
  while IFS= read -r bindir; do
    [ -d "$bindir" ] || continue
    for entry in "$bindir"/*; do
      [ -e "$entry" ] || continue
      name=$(basename "$entry")
      [ "$name" = glab ] && continue
      [ -e "$noglab/$name" ] || ln -s "$entry" "$noglab/$name" 2>/dev/null
    done
  done <<EOF
$dir/fakebin
$(printf '%s\n' "$BASE_PATH" | tr ':' '\n')
EOF
  ! PATH="$noglab" command -v glab >/dev/null 2>&1 \
    || fail "the glab-free search path still resolved glab"
  out=$(FM_TEST_GLAB_STATE=merged FM_TEST_GH_LOG="$dir/gh.log" FM_TEST_GLAB_LOG="$dir/glab.log" \
    PATH="$noglab" \
    bash "$state/task-a.check.sh")
  [ -z "$out" ] || fail "GitLab poll emitted with glab absent from PATH"

  # A doctored sidecar cannot redirect the poll: the stored parts must rebuild
  # the stored URL exactly.
  printf '%s\n%s\n%s\n%s\n%s\n' gitlab "$url" elsewhere.example group/subgroup/project 7 \
    > "$state/task-a.pr-poll"
  out=$(FM_TEST_GLAB_STATE=merged run_poll "$dir")
  [ -z "$out" ] || fail "GitLab poll emitted for a sidecar whose host was swapped"
  printf '%s\n%s\n%s\n%s\n%s\n' gitlab "$url" gitlab.example group/subgroup/other 7 \
    > "$state/task-a.pr-poll"
  out=$(FM_TEST_GLAB_STATE=merged run_poll "$dir")
  [ -z "$out" ] || fail "GitLab poll emitted for a sidecar whose project was swapped"

  # Arming is where a missing CLI can still be reported, so it refuses there.
  write_task_meta "$dir" task-b
  set +e
  out=$(FM_ROOT_OVERRIDE="$dir/root" FM_HOME="$dir/home" \
    FM_TEST_GUARD_LOG="$dir/guard.log" PATH="$noglab" \
    "$PR_CHECK" task-b "$url" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "arming a GitLab watch succeeded with glab absent"
  case "$out" in
    *"requires glab on PATH"*) ;;
    *) fail "arming a GitLab watch with glab absent did not report the missing CLI" ;;
  esac
  [ ! -e "$state/task-b.check.sh" ] || fail "refused GitLab arming left a poll armed"

  # The merge path addresses the forge the URL names, and never the other one.
  # This fixture's glab answers with the field output the poll reads (not
  # JSON), so bin/fm-pr-check.sh's own branch-identity read of the same -F
  # json call cannot parse it either, and the merge path's PR-metadata step
  # refuses before ever reaching gitlab_verify_mergeable.
  write_task_meta "$dir" task-c
  : > "$dir/glab.log"
  # The merge path needs jq before it reads anything, so this case supplies it
  # and the refusal below is the unreadable branch/state rather than a missing
  # tool.
  ln -sf "$REAL_JQ" "$dir/fakebin/jq"
  set +e
  run_merge_entry "$dir" task-c "$url" >/dev/null 2> "$dir/merge-c.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "merge wrapper merged a GitLab merge request it could not read"
  grep -qF "could not read PR $url's head branch" "$dir/merge-c.err" \
    || fail "merge wrapper refused for some reason other than the branch it could not read"
  [ ! -s "$dir/gh-axi.log" ] || fail "merge wrapper reached the GitHub CLI for a GitLab URL"
  grep -qF "mr view 7 -R https://gitlab.example/group/subgroup/project" "$dir/glab.log" \
    || fail "merge wrapper did not read the merge request through glab at its own instance"
  ! grep -qF ' mr merge ' "$dir/glab.log" \
    || fail "merge wrapper merged despite an unreadable merge request state"

  pass "GitLab merge requests are followed on any instance and never wake falsely"
}

seed_canonical_poll() {
  local dir=$1 id=$2 url=$3 template=${4:-$POLL} state provider host path number
  state="$dir/home/state"
  fm_pr_url_parse "$url" || fail "retirement fixture URL was invalid"
  provider=$FM_PR_PROVIDER
  host=$FM_PR_HOST
  path=$FM_PR_PATH
  number=$FM_PR_NUMBER
  fm_pr_poll_prepare "$state" "$id" "$provider" "$url" "$host" "$path" "$number" "$template" \
    || fail "could not prepare retirement fixture"
  fm_pr_poll_publish_prepared || fail "could not publish retirement fixture"
}

add_stop_custom_check() {
  local dir=$1 state
  state="$dir/home/state"
  printf '#!/usr/bin/env bash\nprintf "stop-cycle\\n"\n' > "$state/z-stop.check.sh"
  chmod 0700 "$state/z-stop.check.sh"
  FM_HOME="$dir/home" "$REGISTER" z-stop >/dev/null \
    || fail "could not register stop-cycle custom check"
}

assert_poll_absent() {
  local state=$1 id=$2 suffix
  for suffix in check.sh pr-poll pr-poll-registration pr-poll-retirement; do
    [ ! -e "$state/$id.$suffix" ] && [ ! -L "$state/$id.$suffix" ] \
      || fail "retired poll left $id.$suffix"
  done
}

poll_artifact_snapshot() {
  local state=$1 id=$2 suffix path
  for suffix in check.sh pr-poll pr-poll-registration pr-poll-retirement meta; do
    path="$state/$id.$suffix"
    [ -e "$path" ] || [ -L "$path" ] || continue
    if [ -L "$path" ]; then
      printf 'link %s %s\n' "$suffix" "$(readlink "$path")"
    elif [ -f "$path" ]; then
      printf 'file %s %s ' "$suffix" "$(file_mode "$path")"
      shasum -a 256 "$path" | awk '{print $1}'
    else
      printf 'other %s\n' "$suffix"
    fi
  done
}

test_merged_poll_retires_once() {
  local dir state rc first second meta_before
  dir=$(make_case merged-retirement-once)
  state="$dir/home/state"
  write_poll_meta "$state" task-a https://github.com/o/r/pull/1
  meta_before=$(cat "$state/task-a.meta")
  seed_canonical_poll "$dir" task-a https://github.com/o/r/pull/1
  add_stop_custom_check "$dir"

  set +e
  FM_TEST_GH_STATE=MERGED run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/watch-1.out" 2> "$dir/watch-1.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "merged retirement watcher failed: $(cat "$dir/watch-1.err")"
  first=$(cat "$dir/watch-1.out")
  case "$first" in check:*task-a.check.sh:*merged) ;; *) fail "first merged notification was not preserved: $first" ;; esac
  ack_watcher_cycle "$state" || fail "first merged notification handling acknowledgement failed"
  assert_poll_absent "$state" task-a
  [ "$(cat "$state/task-a.meta")" = "$meta_before" ] || fail "merged retirement changed canonical metadata"

  rm -f "$state/.last-check"
  set +e
  FM_TEST_GH_STATE=MERGED run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/watch-2.out" 2> "$dir/watch-2.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "second watcher cycle failed: $(cat "$dir/watch-2.err")"
  second=$(cat "$dir/watch-2.out")
  case "$second" in check:*z-stop.check.sh:*stop-cycle) ;; *) fail "second cycle did not reach the control check: $second" ;; esac
  ! grep -F 'task-a.check.sh: merged' "$dir/watch-2.out" >/dev/null \
    || fail "retired merged poll executed a second time"
  ! grep "$(printf '\tcheck\ttask-a.check.sh\t')" "$state/.wake-queue" >/dev/null 2>&1 \
    || fail "handled merged notification remained queued after acknowledgement"
  pass "validated merged polls notify once and retire before the next watcher cycle"
}

# A poll's own retirement state is scoped to ONE registration, so it cannot by
# itself catch a poll re-registered for a task whose merge was already
# surfaced (e.g. bin/fm-pr-check.sh re-armed after the fact). The per-task
# merge-notified marker (bin/fm-pr-lib.sh) is what stops that re-registration
# from producing a second main-blocking wake for the identical merge, while a
# genuinely first notification (test_merged_poll_retires_once above) still
# reaches main.
test_merged_poll_reregistration_after_notification_is_absorbed() {
  local dir state rc first
  dir=$(make_case merged-reregistration-absorbed)
  state="$dir/home/state"
  write_poll_meta "$state" task-a https://github.com/o/r/pull/1
  seed_canonical_poll "$dir" task-a https://github.com/o/r/pull/1
  add_stop_custom_check "$dir"

  set +e
  FM_TEST_GH_STATE=MERGED run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/watch-1.out" 2> "$dir/watch-1.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "first merged watcher cycle failed: $(cat "$dir/watch-1.err")"
  first=$(cat "$dir/watch-1.out")
  case "$first" in check:*task-a.check.sh:*merged) ;; *) fail "first merge confirmation was not delivered: $first" ;; esac
  ack_watcher_cycle "$state" || fail "first merge confirmation acknowledgement failed"
  assert_poll_absent "$state" task-a
  [ -f "$state/task-a.pr-poll-merge-notified" ] || fail "the merge-notified marker was not recorded"

  # Re-registration: fm-pr-check.sh re-armed for a task whose PR is already
  # merged (a fresh check.sh/pr-poll/pr-poll-registration, a distinct
  # retirement identity from the one just retired).
  seed_canonical_poll "$dir" task-a https://github.com/o/r/pull/1
  rm -f "$state/.last-check"

  set +e
  FM_TEST_GH_STATE=MERGED run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/watch-2.out" 2> "$dir/watch-2.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "second watcher cycle failed: $(cat "$dir/watch-2.err")"
  case "$(cat "$dir/watch-2.out")" in
    check:*z-stop.check.sh:*stop-cycle) ;;
    *) fail "the re-registered duplicate did not fall through to the next check: $(cat "$dir/watch-2.out")" ;;
  esac
  ! grep -F 'task-a.check.sh: merged' "$dir/watch-2.out" >/dev/null \
    || fail "a repeat identical merged poll opened a main-blocking row: $(cat "$dir/watch-2.out")"
  ! grep "$(printf '\tcheck\ttask-a.check.sh\t')" "$state/.wake-queue" >/dev/null 2>&1 \
    || fail "the absorbed duplicate merge notice was queued as a main-blocking row"
  assert_poll_absent "$state" task-a
  pass "a repeat identical merged poll for an already-notified task is absorbed, never queued as a main-blocking row"
}

# The captain merging a PR himself on the forge is the same outcome as a merge
# this home performed: bin/fm-merge-outcome-lib.sh carries both to the parent on
# the one reply channel, so no second watch path exists for the captain's case.
# The poll's own durable row still lands here, because the mate that owns the
# task still has to act on it.
seed_secondmate_home() {  # <dir> [<route>]
  local dir=$1 route=${2:-remote}
  printf '%s\n' mate-x > "$dir/home/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=%s\n' "$route" \
    > "$dir/home/.fm-secondmate-parent"
}

test_merged_poll_retries_a_failed_upward_report() {
  local dir state rc replies url
  url=https://github.com/o/r/pull/1
  dir=$(make_case merged-poll-upward-retry)
  state="$dir/home/state"
  replies="$state/parent-replies.status"
  printf '%s\n' mate-x > "$dir/home/.fm-secondmate-home"
  write_poll_meta "$state" task-a "$url"
  seed_canonical_poll "$dir" task-a "$url"
  add_stop_custom_check "$dir"

  set +e
  FM_TEST_GH_STATE=MERGED run_watcher_bounded "$dir/home" "$dir/fakebin" \
    > "$dir/watch-1.out" 2> "$dir/watch-1.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "merged-poll-upward-retry: failed report did not keep the watcher loud"
  [ -f "$state/task-a.check.sh" ] \
    || fail "merged-poll-upward-retry: failed report retired its retry poll"
  [ ! -e "$state/task-a.pr-poll-merge-notified" ] \
    || fail "merged-poll-upward-retry: failed report was marked notified"
  [ ! -e "$replies" ] \
    || fail "merged-poll-upward-retry: failed report wrote a parent reply"

  printf 'schema=fm-secondmate-parent.v1\nroute=remote\n' \
    > "$dir/home/.fm-secondmate-parent"
  rm -f "$state/.last-check"
  set +e
  FM_TEST_GH_STATE=MERGED run_watcher_bounded "$dir/home" "$dir/fakebin" \
    > "$dir/watch-2.out" 2> "$dir/watch-2.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "merged-poll-upward-retry: retry failed: $(cat "$dir/watch-2.err")"
  if [ ! -e "$replies" ]; then
    ack_watcher_cycle "$state" \
      || fail "merged-poll-upward-retry: recovery acknowledgement failed"
    rm -f "$state/.last-check"
    set +e
    FM_TEST_GH_STATE=MERGED run_watcher_bounded "$dir/home" "$dir/fakebin" \
      > "$dir/watch-3.out" 2> "$dir/watch-3.err"
    rc=$?
    set -e
    [ "$rc" -eq 0 ] || fail "merged-poll-upward-retry: post-recovery retry failed: $(cat "$dir/watch-3.err")"
  fi
  assert_grep "done [key=merged-task-a]: merged task-a $url" "$replies" \
    "merged-poll-upward-retry: repaired binding did not receive the retry"
  assert_poll_absent "$state" task-a
  pass "a failed upward merge report keeps its poll armed for repair and retry"
}

test_self_merge_and_poll_publish_one_outcome() {
  local dir state replies url rc
  url=https://github.com/o/r/pull/1

  # Interleaving one: self publication commits before the poll observes the
  # merge, so the poll absorbs the committed identity without reporting again.
  dir=$(make_case merge-outcome-committed)
  state="$dir/home/state"
  replies="$state/parent-replies.status"
  seed_secondmate_home "$dir"
  write_task_meta "$dir" task-a
  run_check_entry "$dir" task-a "$url" >/dev/null 2>"$dir/seed.err" \
    || fail "merge-outcome-committed: could not arm merge poll"
  run_merge_entry "$dir" task-a "$url" >"$dir/merge.out" 2>"$dir/merge.err" \
    || fail "merge-outcome-committed: merge entrypoint failed: $(cat "$dir/merge.err")"
  add_stop_custom_check "$dir"
  set +e
  FM_TEST_GH_STATE=MERGED run_watcher_bounded "$dir/home" "$dir/fakebin" \
    >"$dir/watch.out" 2>"$dir/watch.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] \
    || fail "merge-outcome-committed: watcher failed: $(cat "$dir/watch.err")"
  [ "$(grep -c -F "done [key=merged-task-a]: merged task-a $url" "$replies")" -eq 1 ] \
    || fail "merge-outcome-committed: self and poll reports produced duplicate merge outcomes"
  assert_no_grep "check: $state/task-a.check.sh: merged" "$state/.wake-queue" \
    "merge-outcome-committed: absorbed poll published a second outcome"
  assert_poll_absent "$state" task-a

  # Interleaving two: self publication lands but its marker commit fails. After
  # that outcome is drained, the still-armed poll must publish it again rather
  # than treating the interrupted attempt as complete and going silent.
  dir=$(make_case merge-outcome-uncommitted)
  state="$dir/home/state"
  write_task_meta "$dir" task-a
  run_check_entry "$dir" task-a "$url" >/dev/null 2>"$dir/seed.err" \
    || fail "merge-outcome-uncommitted: could not arm merge poll"
  cat >"$dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *pr-poll-merge-notified*) exit 1 ;;
esac
exec "$FM_TEST_REAL_MV" "$@"
SH
  chmod +x "$dir/fakebin/mv"
  set +e
  FM_TEST_REAL_MV="$REAL_MV" run_merge_entry "$dir" task-a "$url" \
    >"$dir/merge.out" 2>"$dir/merge.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] \
    || fail "merge-outcome-uncommitted: landed merge was reported as failed"
  assert_grep "$url" "$state/.wake-queue" \
    "merge-outcome-uncommitted: interrupted publication emitted no outcome"
  [ ! -e "$state/task-a.pr-poll-merge-notified" ] \
    || fail "merge-outcome-uncommitted: failed marker commit was treated as complete"
  ack_watcher_cycle "$state" \
    || fail "merge-outcome-uncommitted: could not drain the first outcome"
  assert_no_grep "$url" "$state/.wake-queue" \
    "merge-outcome-uncommitted: first outcome remained queued after its drain"
  rm -f "$dir/fakebin/mv" "$state/.last-check"

  set +e
  FM_TEST_GH_STATE=MERGED run_watcher_bounded "$dir/home" "$dir/fakebin" \
    >"$dir/watch.out" 2>"$dir/watch.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] \
    || fail "merge-outcome-uncommitted: poll retry failed: $(cat "$dir/watch.err")"
  case "$(cat "$dir/watch.out")" in
    check:*task-a.check.sh:*merged) ;;
    *) fail "merge-outcome-uncommitted: poll retry did not re-emit the outcome" ;;
  esac
  assert_grep "$url" "$state/.wake-queue" \
    "merge-outcome-uncommitted: drained outcome was not durably re-emitted"
  fm_pr_poll_merge_already_notified "$state" task-a github github.com o/r 1 \
    || fail "merge-outcome-uncommitted: successful retry did not commit the marker"
  assert_poll_absent "$state" task-a
  pass "staged self-merge and poll interleavings are never silent"
}

test_merged_poll_reports_upward_from_a_secondmate_home_once() {
  local dir state rc replies url
  url=https://github.com/o/r/pull/1
  dir=$(make_case merged-poll-upward)
  state="$dir/home/state"
  replies="$state/parent-replies.status"
  seed_secondmate_home "$dir"
  write_poll_meta "$state" task-a "$url"
  seed_canonical_poll "$dir" task-a "$url"
  add_stop_custom_check "$dir"

  set +e
  FM_TEST_GH_STATE=MERGED run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/watch-1.out" 2> "$dir/watch-1.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "merged-poll-upward: watcher failed: $(cat "$dir/watch-1.err")"
  case "$(cat "$dir/watch-1.out")" in
    check:*task-a.check.sh:*merged) ;;
    *) fail "merged-poll-upward: the poll's own row was lost: $(cat "$dir/watch-1.out")" ;;
  esac
  assert_grep "done [key=merged-task-a]: merged task-a $url" "$replies" \
    "merged-poll-upward: a merge this home did not perform was never reported upward"
  [ "$(grep -c -F "$url" "$replies")" -eq 1 ] \
    || fail "merged-poll-upward: one detected merge produced more than one upward line"
  ack_watcher_cycle "$state" || fail "merged-poll-upward: acknowledgement failed"

  # Re-registered for the same, already-reported merge: the absorbed duplicate
  # must not tell the parent a second time either.
  seed_canonical_poll "$dir" task-a "$url"
  rm -f "$state/.last-check"
  set +e
  FM_TEST_GH_STATE=MERGED run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/watch-2.out" 2> "$dir/watch-2.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "merged-poll-upward: second watcher cycle failed: $(cat "$dir/watch-2.err")"
  [ "$(grep -c -F "$url" "$replies")" -eq 1 ] \
    || fail "merged-poll-upward: an absorbed duplicate detection reported the merge again"
  pass "a merge detected by the poll is reported upward from a secondmate home exactly once"
}

test_different_merged_pr_for_same_task_is_not_absorbed() {
  local dir state rc
  dir=$(make_case different-merged-pr-not-absorbed)
  state="$dir/home/state"
  write_poll_meta "$state" task-a https://github.com/o/r/pull/1
  seed_canonical_poll "$dir" task-a https://github.com/o/r/pull/1

  set +e
  FM_TEST_GH_STATE=MERGED run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/watch-1.out" 2> "$dir/watch-1.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "first merged watcher cycle failed: $(cat "$dir/watch-1.err")"
  case "$(cat "$dir/watch-1.out")" in
    check:*task-a.check.sh:*merged) ;;
    *) fail "first PR merge confirmation was not delivered: $(cat "$dir/watch-1.out")" ;;
  esac
  ack_watcher_cycle "$state" || fail "first PR merge confirmation acknowledgement failed"
  assert_poll_absent "$state" task-a

  write_poll_meta "$state" task-a https://github.com/o/r/pull/2
  seed_canonical_poll "$dir" task-a https://github.com/o/r/pull/2
  rm -f "$state/.last-check"

  set +e
  FM_TEST_GH_STATE=MERGED run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/watch-2.out" 2> "$dir/watch-2.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "different-PR watcher cycle failed: $(cat "$dir/watch-2.err")"
  case "$(cat "$dir/watch-2.out")" in
    check:*task-a.check.sh:*merged) ;;
    *) fail "a different PR merge was absorbed: $(cat "$dir/watch-2.out")" ;;
  esac
  grep -F "$(printf '\tcheck\tmerged-task-a-https://github.com/o/r/pull/2\t')" \
    "$state/.wake-queue" >/dev/null 2>&1 \
    || fail "the different PR merge did not create a main-blocking wake row"
  fm_pr_poll_merge_already_notified "$state" task-a github github.com o/r 2 \
    || fail "the marker was not advanced to the different PR identity"
  ! fm_pr_poll_merge_already_notified "$state" task-a github github.com o/r 1 \
    || fail "the marker still matched the superseded PR identity"
  assert_poll_absent "$state" task-a
  pass "a different merged PR for the same task gets its own first notification"
}

test_persistent_secondmate_retirement_is_poll_only() {
  local dir state meta_before status_before registry_before endpoint_before rc
  dir=$(make_case merged-retirement-secondmate)
  state="$dir/home/state"
  fm_write_meta "$state/domain.meta" \
    'window=session:fm-domain' \
    "worktree=$dir/secondmate-home" \
    "project=$dir/project" \
    'kind=secondmate' \
    'mode=secondmate' \
    'backend=tmux' \
    "home=$dir/secondmate-home" \
    'pr=https://github.com/o/r/pull/2' \
    'pr_head=0123456789abcdef0123456789abcdef01234567'
  mkdir -p "$dir/secondmate-home"
  printf 'working: persistent endpoint remains healthy\n' > "$state/domain.status"
  printf -- '- domain | scope: test | home: %s\n' "$dir/secondmate-home" > "$dir/home/data/secondmates.md"
  printf 'endpoint-alive\n' > "$dir/endpoint-sentinel"
  meta_before=$(shasum -a 256 "$state/domain.meta")
  status_before=$(shasum -a 256 "$state/domain.status")
  registry_before=$(shasum -a 256 "$dir/home/data/secondmates.md")
  endpoint_before=$(shasum -a 256 "$dir/endpoint-sentinel")
  seed_canonical_poll "$dir" domain https://github.com/o/r/pull/2

  set +e
  FM_TEST_GH_STATE=MERGED run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/watch.out" 2> "$dir/watch.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "persistent secondmate merged watcher failed: $(cat "$dir/watch.err")"
  assert_poll_absent "$state" domain
  [ "$(shasum -a 256 "$state/domain.meta")" = "$meta_before" ] || fail "retirement changed secondmate metadata"
  [ "$(shasum -a 256 "$state/domain.status")" = "$status_before" ] || fail "retirement changed secondmate status"
  [ "$(shasum -a 256 "$dir/home/data/secondmates.md")" = "$registry_before" ] || fail "retirement changed secondmate registry"
  [ "$(shasum -a 256 "$dir/endpoint-sentinel")" = "$endpoint_before" ] || fail "retirement changed secondmate endpoint evidence"
  [ -d "$dir/secondmate-home" ] || fail "retirement removed the persistent secondmate home"
  pass "merged poll retirement preserves every persistent secondmate lifecycle artifact"
}

test_retirement_crash_recovery() {
  local dir state rc raw_count drain_count historical_poll

  dir=$(make_case retirement-after-queue)
  state="$dir/home/state"
  write_poll_meta "$state" task-a https://github.com/o/r/pull/3
  seed_canonical_poll "$dir" task-a https://github.com/o/r/pull/3
  FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_wake_append check "$2" "$3"' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$state/task-a.check.sh" "check: $state/task-a.check.sh: merged" \
    || fail "could not seed post-queue crash"
  FM_TEST_GH_STATE=MERGED run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/recovery.out" 2> "$dir/recovery.err" \
    || fail "post-queue crash recovery wake failed: $(cat "$dir/recovery.err")"
  grep -F 'check: rearm-resurface' "$dir/recovery.out" >/dev/null \
    || fail "post-queue crash did not surface its durable recovery first"
  ack_watcher_cycle "$state" || fail "post-queue crash recovery acknowledgement failed"
  set +e
  FM_TEST_GH_STATE=MERGED run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/watch.out" 2> "$dir/watch.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "post-queue retry watcher failed: $(cat "$dir/watch.err")"
  assert_poll_absent "$state" task-a
  raw_count=$(grep -cF "$(printf '\tcheck\tmerged-task-a-https://github.com/o/r/pull/3\t')" \
    "$state/.wake-queue" || true)
  [ "$raw_count" -eq 1 ] || fail "post-queue retry did not publish exactly one new terminal row"
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-wake-drain.sh" > "$dir/drain.out" 2>/dev/null
  drain_count=$(grep -cF "$(printf '\tcheck\tmerged-task-a-https://github.com/o/r/pull/3\t')" \
    "$dir/drain.out" || true)
  [ "$drain_count" -eq 1 ] || fail "same-key crash retry rows did not deduplicate at drain"

  dir=$(make_case retirement-after-receipt)
  state="$dir/home/state"
  write_poll_meta "$state" task-a https://github.com/o/r/pull/4
  seed_canonical_poll "$dir" task-a https://github.com/o/r/pull/4
  fm_pr_poll_snapshot_capture "$state" task-a "$POLL" || fail "could not snapshot receipt crash fixture"
  fm_pr_poll_retirement_publish "$state" task-a "$POLL" merged || fail "could not publish crash receipt"
  add_stop_custom_check "$dir"
  set +e
  FM_TEST_GH_STATE=MERGED run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/restart.out" 2> "$dir/restart.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "receipt recovery watcher failed: $(cat "$dir/restart.err")"
  assert_poll_absent "$state" task-a
  ! grep -F 'task-a.check.sh: merged' "$dir/restart.out" >/dev/null || fail "receipt recovery duplicated the terminal wake"

  dir=$(make_case retirement-after-check-removal)
  state="$dir/home/state"
  write_poll_meta "$state" task-a https://github.com/o/r/pull/5
  seed_canonical_poll "$dir" task-a https://github.com/o/r/pull/5
  fm_pr_poll_snapshot_capture "$state" task-a "$POLL" || fail "could not snapshot partial removal fixture"
  fm_pr_poll_retirement_publish "$state" task-a "$POLL" merged || fail "could not publish partial removal receipt"
  rm -f "$state/task-a.check.sh"
  add_stop_custom_check "$dir"
  set +e
  FM_TEST_GH_STATE=MERGED run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/restart.out" 2> "$dir/restart.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "post-check-removal restart failed: $(cat "$dir/restart.err")"
  case "$(cat "$dir/restart.out")" in check:*z-stop.check.sh:*stop-cycle) ;; *) fail "post-check-removal restart did not reach the control check" ;; esac
  assert_poll_absent "$state" task-a
  fm_pr_poll_retirement_recover_one "$state" task-a "$POLL" || fail "completed retirement was not idempotent"

  dir=$(make_case retirement-after-registration-removal)
  state="$dir/home/state"
  write_poll_meta "$state" task-a https://github.com/o/r/pull/5
  seed_canonical_poll "$dir" task-a https://github.com/o/r/pull/5
  fm_pr_poll_snapshot_capture "$state" task-a "$POLL" || fail "could not snapshot sidecar-removal fixture"
  fm_pr_poll_retirement_publish "$state" task-a "$POLL" merged || fail "could not publish sidecar-removal receipt"
  rm -f "$state/task-a.check.sh" "$state/task-a.pr-poll-registration"
  add_stop_custom_check "$dir"
  set +e
  FM_TEST_GH_STATE=MERGED run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/restart.out" 2> "$dir/restart.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "post-registration-removal restart failed: $(cat "$dir/restart.err")"
  case "$(cat "$dir/restart.out")" in check:*z-stop.check.sh:*stop-cycle) ;; *) fail "post-registration-removal restart did not reach the control check" ;; esac
  assert_poll_absent "$state" task-a

  dir=$(make_case retirement-before-receipt-removal)
  state="$dir/home/state"
  write_poll_meta "$state" task-a https://github.com/o/r/pull/5
  seed_canonical_poll "$dir" task-a https://github.com/o/r/pull/5
  fm_pr_poll_snapshot_capture "$state" task-a "$POLL" || fail "could not snapshot receipt-only fixture"
  fm_pr_poll_retirement_publish "$state" task-a "$POLL" merged || fail "could not publish receipt-only fixture"
  rm -f "$state/task-a.check.sh" "$state/task-a.pr-poll-registration" "$state/task-a.pr-poll"
  add_stop_custom_check "$dir"
  set +e
  FM_TEST_GH_STATE=MERGED run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/restart.out" 2> "$dir/restart.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "receipt-only restart failed: $(cat "$dir/restart.err")"
  case "$(cat "$dir/restart.out")" in check:*z-stop.check.sh:*stop-cycle) ;; *) fail "receipt-only restart did not reach the control check" ;; esac
  assert_poll_absent "$state" task-a

  dir=$(make_case retirement-after-template-update)
  state="$dir/home/state"
  historical_poll="$dir/historical-fm-pr-poll.sh"
  cp "$POLL" "$historical_poll"
  printf '\n' >> "$historical_poll"
  chmod 0600 "$historical_poll"
  write_poll_meta "$state" task-a https://github.com/o/r/pull/22
  seed_canonical_poll "$dir" task-a https://github.com/o/r/pull/22 "$historical_poll"
  FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_wake_append check "$2" "$3"' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$state/task-a.check.sh" "check: $state/task-a.check.sh: merged" \
    || fail "could not seed pre-update terminal wake"
  fm_pr_poll_snapshot_capture "$state" task-a "$historical_poll" \
    || fail "could not snapshot pre-update retirement fixture"
  fm_pr_poll_retirement_publish "$state" task-a "$historical_poll" merged \
    || fail "could not publish pre-update retirement receipt"
  add_stop_custom_check "$dir"
  FM_TEST_GH_STATE=MERGED run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/template-recovery.out" 2> "$dir/template-recovery.err" \
    || fail "template-update recovery wake failed: $(cat "$dir/template-recovery.err")"
  grep -F 'check: rearm-resurface' "$dir/template-recovery.out" >/dev/null \
    || fail "template-update recovery did not surface its durable wake first"
  ack_watcher_cycle "$state" || fail "template-update recovery acknowledgement failed"
  set +e
  FM_TEST_GH_STATE=MERGED run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/restart.out" 2> "$dir/restart.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "template-update recovery watcher failed: $(cat "$dir/restart.err")"
  case "$(cat "$dir/restart.out")" in check:*z-stop.check.sh:*stop-cycle) ;; *) fail "template-update recovery did not reach the control check" ;; esac
  [ ! -s "$dir/gh.log" ] || fail "template-update migration rebuilt and queried the retired poll"
  ! grep "$(printf '\tcheck\ttask-a.check.sh\t')" "$state/.wake-queue" >/dev/null 2>&1 \
    || fail "template-update recovery left the handled terminal wake queued"
  assert_poll_absent "$state" task-a
  pass "queue, receipt, and every fixed-path removal crash point recover without loss or repeated execution"
}

test_external_merge_transition_retires_only_terminal_poll() {
  local dir state before rc label
  dir=$(make_case external-merge-transition)
  state="$dir/home/state"
  write_poll_meta "$state" task-a https://github.com/o/r/pull/19
  seed_canonical_poll "$dir" task-a https://github.com/o/r/pull/19
  add_stop_custom_check "$dir"
  before=$(poll_artifact_snapshot "$state" task-a)

  for label in open-green open-red closed-unmerged forge-error malformed; do
    rm -f "$state/.last-check"
    set +e
    case "$label" in
      open-green|open-red)
        FM_TEST_GH_STATE=OPEN run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/$label.out" 2> "$dir/$label.err"
        ;;
      closed-unmerged)
        FM_TEST_GH_STATE=CLOSED run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/$label.out" 2> "$dir/$label.err"
        ;;
      forge-error)
        FM_TEST_GH_FAIL=1 run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/$label.out" 2> "$dir/$label.err"
        ;;
      malformed)
        FM_TEST_GH_STATE=NOT_A_FORGE_STATE run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/$label.out" 2> "$dir/$label.err"
        ;;
    esac
    rc=$?
    set -e
    [ "$rc" -eq 0 ] || fail "$label watcher cycle failed: $(cat "$dir/$label.err")"
    case "$(cat "$dir/$label.out")" in check:*z-stop.check.sh:*stop-cycle) ;; *) fail "$label did not reach the control check" ;; esac
    [ "$(poll_artifact_snapshot "$state" task-a)" = "$before" ] || fail "$label changed the armed poll"
    ack_watcher_cycle "$state" || fail "$label control wake acknowledgement failed"
  done

  rm -f "$state/z-stop.check.sh" "$state/z-stop.check-trust" "$state/.last-check"
  set +e
  FM_TEST_GH_STATE=MERGED run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/merged.out" 2> "$dir/merged.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "external merged transition failed: $(cat "$dir/merged.err")"
  case "$(cat "$dir/merged.out")" in check:*task-a.check.sh:*merged) ;; *) fail "external merge did not preserve its notification" ;; esac
  assert_poll_absent "$state" task-a
  pass "open/red, closed-unmerged, malformed, and forge errors remain armed until an exact merged transition"
}

test_retirement_refuses_replacement_and_nonterminal_results() {
  local dir state before rc replacement_check replacement_data replacement_registration replacement_meta
  local historical_poll current_poll
  dir=$(make_case retirement-replacement)
  state="$dir/home/state"
  write_poll_meta "$state" task-a https://github.com/o/r/pull/6
  seed_canonical_poll "$dir" task-a https://github.com/o/r/pull/6
  fm_pr_poll_snapshot_capture "$state" task-a "$POLL" || fail "could not snapshot replacement fixture"
  write_poll_meta "$state" task-a https://github.com/o/r/pull/7
  seed_canonical_poll "$dir" task-a https://github.com/o/r/pull/7
  before=$(state_snapshot "$state")
  fm_pr_poll_retirement_publish "$state" task-a "$POLL" merged \
    && fail "stale terminal snapshot retired a replacement poll"
  [ "$(state_snapshot "$state")" = "$before" ] || fail "snapshot mismatch changed replacement artifacts"
  fm_pr_poll_artifacts_valid "$state" task-a "$POLL" || fail "replacement poll was not left canonical"

  fm_pr_poll_snapshot_capture "$state" task-a "$POLL" || fail "could not snapshot nonterminal fixture"
  for result in OPEN CLOSED ERROR 'merged extra'; do
    fm_pr_poll_retirement_publish "$state" task-a "$POLL" "$result" \
      && fail "nonterminal result '$result' received retirement authority"
  done
  [ "$(state_snapshot "$state")" = "$before" ] || fail "nonterminal result changed canonical artifacts"

  printf '# tamper\n' >> "$state/task-a.check.sh"
  before=$(state_snapshot "$state")
  fm_pr_poll_retirement_publish "$state" task-a "$POLL" merged \
    && fail "tampered check received a retirement receipt"
  [ "$(state_snapshot "$state")" = "$before" ] || fail "tampered retirement attempt changed state"

  dir=$(make_case retirement-rearm-race)
  state="$dir/home/state"
  write_poll_meta "$state" task-a https://github.com/o/r/pull/20
  seed_canonical_poll "$dir" task-a https://github.com/o/r/pull/20
  fm_pr_poll_snapshot_capture "$state" task-a "$POLL" || fail "could not snapshot rearm-race fixture"
  fm_pr_poll_retirement_publish "$state" task-a "$POLL" merged || fail "could not publish rearm-race receipt"
  write_poll_meta "$state" task-a https://github.com/o/r/pull/21
  seed_canonical_poll "$dir" task-a https://github.com/o/r/pull/21
  replacement_check=$(shasum -a 256 "$state/task-a.check.sh")
  replacement_data=$(shasum -a 256 "$state/task-a.pr-poll")
  replacement_registration=$(shasum -a 256 "$state/task-a.pr-poll-registration")
  replacement_meta=$(shasum -a 256 "$state/task-a.meta")
  fm_pr_poll_retirement_recover_one "$state" task-a "$POLL" || fail "stale receipt did not yield to a canonical replacement"
  [ ! -e "$state/task-a.pr-poll-retirement" ] || fail "stale receipt survived canonical replacement recovery"
  [ "$(shasum -a 256 "$state/task-a.check.sh")" = "$replacement_check" ] || fail "stale receipt changed replacement check"
  [ "$(shasum -a 256 "$state/task-a.pr-poll")" = "$replacement_data" ] || fail "stale receipt changed replacement data"
  [ "$(shasum -a 256 "$state/task-a.pr-poll-registration")" = "$replacement_registration" ] || fail "stale receipt changed replacement registration"
  [ "$(shasum -a 256 "$state/task-a.meta")" = "$replacement_meta" ] || fail "stale receipt changed replacement metadata"
  fm_pr_poll_artifacts_valid "$state" task-a "$POLL" || fail "replacement poll lost canonical provenance"

  dir=$(make_case retirement-template-update-rearm-race)
  state="$dir/home/state"
  historical_poll="$dir/historical-fm-pr-poll.sh"
  current_poll="$dir/current-fm-pr-poll.sh"
  cp "$POLL" "$historical_poll"
  cp "$POLL" "$current_poll"
  printf '\n' >> "$current_poll"
  chmod 0600 "$historical_poll" "$current_poll"
  write_poll_meta "$state" task-a https://github.com/o/r/pull/23
  seed_canonical_poll "$dir" task-a https://github.com/o/r/pull/23 "$historical_poll"
  fm_pr_poll_snapshot_capture "$state" task-a "$historical_poll" \
    || fail "could not snapshot pre-update rearm fixture"
  fm_pr_poll_retirement_publish "$state" task-a "$historical_poll" merged \
    || fail "could not publish pre-update rearm receipt"
  write_poll_meta "$state" task-a https://github.com/o/r/pull/24
  seed_canonical_poll "$dir" task-a https://github.com/o/r/pull/24 "$current_poll"
  replacement_check=$(shasum -a 256 "$state/task-a.check.sh")
  replacement_data=$(shasum -a 256 "$state/task-a.pr-poll")
  replacement_registration=$(shasum -a 256 "$state/task-a.pr-poll-registration")
  replacement_meta=$(shasum -a 256 "$state/task-a.meta")
  fm_pr_poll_retirement_recover_one "$state" task-a "$current_poll" \
    || fail "template update blocked stale receipt recovery"
  [ ! -e "$state/task-a.pr-poll-retirement" ] || fail "pre-update receipt survived canonical replacement recovery"
  [ "$(shasum -a 256 "$state/task-a.check.sh")" = "$replacement_check" ] || fail "pre-update receipt changed replacement check"
  [ "$(shasum -a 256 "$state/task-a.pr-poll")" = "$replacement_data" ] || fail "pre-update receipt changed replacement data"
  [ "$(shasum -a 256 "$state/task-a.pr-poll-registration")" = "$replacement_registration" ] || fail "pre-update receipt changed replacement registration"
  [ "$(shasum -a 256 "$state/task-a.meta")" = "$replacement_meta" ] || fail "pre-update receipt changed replacement metadata"
  fm_pr_poll_artifacts_valid "$state" task-a "$current_poll" || fail "updated replacement poll lost canonical provenance"

  dir=$(make_case custom-merged-not-retired)
  state="$dir/home/state"
  printf '#!/usr/bin/env bash\nprintf "merged\\n"\n' > "$state/custom.check.sh"
  chmod 0700 "$state/custom.check.sh"
  FM_HOME="$dir/home" "$REGISTER" custom >/dev/null || fail "could not register merged custom check"
  set +e
  run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/custom.out" 2> "$dir/custom.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "merged custom watcher failed: $(cat "$dir/custom.err")"
  [ -f "$state/custom.check.sh" ] && [ -f "$state/custom.check-trust" ] \
    || fail "custom merged output was retired as a PR poll"
  [ ! -e "$state/custom.pr-poll-retirement" ] || fail "custom check received a PR receipt"
  pass "replacement, nonterminal, tampered, and custom results receive no deletion authority"
}

test_retirement_queue_failure_and_receipt_tampering() {
  local dir state before rc external
  dir=$(make_case retirement-queue-failure)
  state="$dir/home/state"
  write_poll_meta "$state" task-a https://github.com/o/r/pull/8
  seed_canonical_poll "$dir" task-a https://github.com/o/r/pull/8
  # Fail sequence publication without making the queue itself look non-empty:
  # a directory at .wake-queue would now (correctly) trigger re-arm recovery
  # before the poll runs, so it no longer exercises the terminal append path.
  mkdir "$state/.wake-queue.seq"
  before=$(poll_artifact_snapshot "$state" task-a)
  set +e
  FM_TEST_GH_LOG="$dir/gh.log" FM_TEST_GH_STATE=MERGED \
    run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/watch.out" 2> "$dir/watch.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "watcher retired despite queue publication failure"
  [ -s "$dir/gh.log" ] || fail "queue failure fixture did not reach the authenticated poll"
  [ "$(poll_artifact_snapshot "$state" task-a)" = "$before" ] || fail "queue failure changed poll artifacts"
  [ ! -e "$state/task-a.pr-poll-retirement" ] || fail "queue failure published a receipt"

  dir=$(make_case retirement-receipt-tamper)
  state="$dir/home/state"
  write_poll_meta "$state" task-a https://github.com/o/r/pull/9
  seed_canonical_poll "$dir" task-a https://github.com/o/r/pull/9
  fm_pr_poll_snapshot_capture "$state" task-a "$POLL" || fail "could not snapshot receipt tamper fixture"
  fm_pr_poll_retirement_publish "$state" task-a "$POLL" merged || fail "could not publish receipt tamper fixture"
  printf 'extra\n' >> "$state/task-a.pr-poll-retirement"
  before=$(state_snapshot "$state")
  fm_pr_poll_retirement_recover_one "$state" task-a "$POLL" \
    && fail "malformed receipt authorized poll deletion"
  [ "$(state_snapshot "$state")" = "$before" ] || fail "malformed receipt changed poll state"
  set +e
  run_check_entry "$dir" task-a https://github.com/o/r/pull/10 > "$dir/rearm.out" 2> "$dir/rearm.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "rearm accepted an invalid pending retirement receipt"
  [ "$(cat "$dir/rearm.err")" = 'error: pending PR poll retirement could not be validated' ] \
    || fail "rearm did not report the invalid pending receipt"
  [ "$(state_snapshot "$state")" = "$before" ] || fail "refused rearm changed poll state"

  rm -f "$state/task-a.pr-poll-retirement"
  external="$dir/external-receipt"
  printf 'external\n' > "$external"
  ln -s "$external" "$state/task-a.pr-poll-retirement"
  before=$(state_snapshot "$state")
  fm_pr_poll_retirement_recover_one "$state" task-a "$POLL" \
    && fail "receipt symlink authorized poll deletion"
  [ "$(state_snapshot "$state")" = "$before" ] || fail "receipt symlink changed poll state"
  [ "$(cat "$external")" = external ] || fail "receipt symlink target was changed"
  pass "queue failure and untrusted receipts preserve canonical poll evidence"
}

test_gitlab_merged_poll_retires() {
  local dir state url rc
  dir=$(make_case gitlab-merged-retirement)
  state="$dir/home/state"
  url=https://gitlab.example/group/subgroup/project/-/merge_requests/17
  write_poll_meta "$state" task-a "$url"
  seed_canonical_poll "$dir" task-a "$url"
  set +e
  FM_TEST_GLAB_STATE=merged run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/watch.out" 2> "$dir/watch.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "GitLab merged retirement watcher failed: $(cat "$dir/watch.err")"
  case "$(cat "$dir/watch.out")" in check:*task-a.check.sh:*merged) ;; *) fail "GitLab merged wake was missing" ;; esac
  assert_poll_absent "$state" task-a
  grep -qxF "pr=$url" "$state/task-a.meta" || fail "GitLab retirement removed canonical metadata"
  pass "GitHub and GitLab exact merged results share one retirement path"
}

test_parser_matrix
test_gitlab_merge_watch
test_merged_poll_retires_once
test_merged_poll_reregistration_after_notification_is_absorbed
test_merged_poll_retries_a_failed_upward_report
test_self_merge_and_poll_publish_one_outcome
test_merged_poll_reports_upward_from_a_secondmate_home_once
test_different_merged_pr_for_same_task_is_not_absorbed
test_persistent_secondmate_retirement_is_poll_only
test_retirement_crash_recovery
test_external_merge_transition_retires_only_terminal_poll
test_retirement_refuses_replacement_and_nonterminal_results
test_retirement_queue_failure_and_receipt_tampering
test_gitlab_merged_poll_retires
test_invalid_entrypoints_have_zero_side_effects
test_valid_recording_and_merge_derivation
test_rejected_metacharacter_bytes_are_inert
test_static_poll_contract
test_atomic_interruption_leaves_no_partial_artifact
test_concurrent_watcher_sees_only_complete_publication
test_poll_publication_refuses_unsafe_destinations
test_live_artifact_single_link_and_privacy_validation
test_postrename_poll_validation_revokes_and_retries
test_bootstrap_leaves_unauthenticated_checks
test_custom_snapshot_cleanup_on_signal
test_returned_custom_check_descendants_are_drained
test_teardown_removes_poll_artifacts
