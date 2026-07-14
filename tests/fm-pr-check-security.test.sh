#!/usr/bin/env bash
# Security and regression tests for canonical PR parsing, static merge polls,
# private atomic artifacts, non-executing migration, and teardown cleanup.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-pr-lib.sh disable=SC1091
. "$ROOT/bin/fm-pr-lib.sh"

PR_CHECK="$ROOT/bin/fm-pr-check.sh"
PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
MIGRATE="$ROOT/bin/fm-pr-check-migrate.sh"
POLL="$ROOT/bin/fm-pr-poll.sh"
WATCH="$ROOT/bin/fm-watch.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-check-security)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
REAL_CP=$(command -v cp)
REAL_MV=$(command -v mv)
REAL_BASENAME=$(command -v basename)

file_mode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1"
  else
    stat -c %a "$1"
  fi
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
case " $* " in
  *" headRefOid "*) printf '%s\n' "${FM_TEST_GH_HEAD:-0123456789abcdef0123456789abcdef01234567}" ;;
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
exit "${FM_TEST_GH_AXI_RC:-0}"
SH
  chmod +x "$fakebin/gh" "$fakebin/gh-axi"
  : > "$dir/gh.log"
  : > "$dir/gh-axi.log"
  : > "$dir/guard.log"
  printf '%s\n' "$dir"
}

write_task_meta() {
  local dir=$1 id=${2:-task-a}
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=fm-$id" \
    "worktree=$dir/wt" \
    "project=$dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
}

write_ambiguous_poll() {
  local dir=$1 id=${2:-task-a}
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=fm-$id" \
    'pr=https://github.com/o/r/pull/10' \
    'window=unexpected-after-pr'
  printf 'legacy ambiguous bytes\n' > "$dir/home/state/$id.check.sh"
}

write_watcher_lock() {
  local state=$1 home=$2 pid=$3 identity
  rm -rf "$state/.watch.lock"
  mkdir "$state/.watch.lock"
  identity=$(LC_ALL=C ps -p "$pid" -o lstart= -o command= 2>/dev/null | sed 's/^[[:space:]]*//')
  [ -n "$identity" ] || fail "could not capture fake older-watcher identity"
  printf '%s\n' "$pid" > "$state/.watch.lock/pid"
  printf '%s\n' "$home" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$state/.watch.lock/pid-identity"
}

assert_valid_migration_marker() {
  local marker=$1
  [ -f "$marker" ] && [ ! -L "$marker" ] || fail "migration success did not publish an ordinary marker"
  [ "$(file_mode "$marker")" = 600 ] || fail "migration marker mode was not 0600"
  grep -qxF fm-pr-check-migration-v1 "$marker" || fail "migration marker bytes were not exact"
  [ "$(awk 'END { print NR + 0 }' "$marker")" -eq 1 ] || fail "migration marker had extra records"
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

run_check_entry() {
  local dir=$1
  shift
  FM_ROOT_OVERRIDE="$dir/root" FM_HOME="$dir/home" \
    FM_TEST_GUARD_LOG="$dir/guard.log" FM_TEST_GH_LOG="$dir/gh.log" \
    FM_TEST_GH_AXI_LOG="$dir/gh-axi.log" PATH="$dir/fakebin:$BASE_PATH" \
    "$PR_CHECK" "$@"
}

run_merge_entry() {
  local dir=$1
  shift
  FM_ROOT_OVERRIDE="$dir/root" FM_HOME="$dir/home" \
    FM_TEST_GUARD_LOG="$dir/guard.log" FM_TEST_GH_LOG="$dir/gh.log" \
    FM_TEST_GH_AXI_LOG="$dir/gh-axi.log" PATH="$dir/fakebin:$BASE_PATH" \
    "$PR_MERGE" "$@"
}

# shellcheck disable=SC2016 # Literal shell syntax is parser test data.
INVALID_URLS=(
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
  'https://github.com/o$(x)/r/pull/1'
  'https://github.com/o/r$(x)/pull/1'
  'https://github.com/o/r/pull/1$(x)'
  'https://github.com/o`x`/r/pull/1'
  'https://github.com/o/r`x`/pull/1'
  'https://github.com/o/r/pull/1`x`'
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
  '-task'
  'task-'
  'task--a'
  'Task-a'
  'task_a'
  'task a'
  $'task\ta'
  $'task\na'
  'task*'
  "task'a"
  'task"a'
  'task;a'
  'task$a'
  'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
)

test_parser_matrix() {
  local row url owner repo number
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
  for row in "${INVALID_URLS[@]}"; do
    ! fm_pr_url_parse "$row" || fail "parser accepted a rejected raw-byte URL class"
  done
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
  pass "direct and merge entrypoints reject invalid arguments before every side effect"
}

test_valid_recording_and_merge_derivation() {
  local dir expected sidecar count
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
  sidecar=$(cat "$dir/home/state/task-a.pr-poll")
  [ "$sidecar" = $'https://github.com/my-org/repo_name.with-dots/pull/37\nmy-org\nrepo_name.with-dots\n37' ] \
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

  dir=$(make_case newline-head)
  write_task_meta "$dir"
  FM_TEST_GH_HEAD=$'0123456789abcdef0123456789abcdef01234567\nwindow=unexpected' \
    run_check_entry "$dir" task-a https://github.com/o/r/pull/2 >/dev/null 2>/dev/null \
    || fail "valid check with malformed remote head failed"
  assert_no_grep 'pr_head=' "$dir/home/state/task-a.meta" "multiline PR head reached metadata"
  assert_no_grep 'window=unexpected' "$dir/home/state/task-a.meta" "newline metadata key was injected"
  pass "valid direct and merge flows record exact metadata and reject multiline head metadata"
}

run_watcher_bounded() {
  local home=$1 fakebin=$2
  shift 2
  perl -e 'my $pid=fork; die unless defined $pid; if (!$pid) { exec @ARGV } local $SIG{ALRM}=sub { kill "TERM", $pid; waitpid $pid, 0; exit 124 }; alarm 5; waitpid $pid, 0; alarm 0; exit($? >> 8)' \
    env FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_CHECK_INTERVAL=0 FM_CHECK_TIMEOUT=1 \
      FM_POLL=0.02 FM_HEARTBEAT=999999 FM_SIGNAL_GRACE=0 PATH="$fakebin:$BASE_PATH" "$WATCH" "$@"
}

test_delayed_execution_families_are_inert() {
  local dir marker family rc before after
  dir=$(make_case delayed-families)
  marker="$dir/marker"
  write_task_meta "$dir"
  families=(
    "https://github.com/o/r/pull/1\$(printf x > '$marker')"
    "https://github.com/o/r/pull/1\`printf x > '$marker'\`"
  )
  for family in "${families[@]}"; do
    rm -f "$marker" "$dir/home/state/task-a.check.sh" "$dir/home/state/task-a.pr-poll"
    set +e
    run_check_entry "$dir" task-a "$family" > /dev/null 2> "$dir/stderr"
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "delayed-execution family was accepted"
    [ ! -e "$marker" ] || fail "marker appeared during generation"
    [ ! -e "$dir/home/state/task-a.check.sh" ] || fail "rejected input left a runnable task check"
    [ ! -e "$dir/home/state/task-a.pr-poll" ] || fail "rejected input left a sidecar"

    cat > "$dir/home/state/x-watch.check.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' stop
SH
    chmod 0700 "$dir/home/state/x-watch.check.sh"
    set +e
    run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/watch.out" 2> "$dir/watch.err"
    rc=$?
    set -e
    [ "$rc" -eq 0 ] || fail "bounded watcher did not complete through the X shim"
    [ ! -e "$marker" ] || fail "marker appeared at watcher time"
    rm -f "$dir/home/state/x-watch.check.sh" "$dir/home/state/.last-check"
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
  [ ! -e "$marker" ] || fail "prior valid poll case created a marker"
  pass "delayed-execution families remain inert at generation and watcher time"
}

make_poll_fixture() {
  local dir=$1
  cp "$POLL" "$dir/home/state/task-a.check.sh"
  printf '%s\n%s\n%s\n%s\n' \
    https://github.com/o/r/pull/1 o r 1 > "$dir/home/state/task-a.pr-poll"
  chmod 0600 "$dir/home/state/task-a.check.sh" "$dir/home/state/task-a.pr-poll"
}

run_poll() {
  local dir=$1
  FM_TEST_GH_LOG="$dir/gh.log" PATH="$dir/fakebin:$BASE_PATH" \
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
  printf '%s\n%s\n%s\n%s\n%s\n' https://github.com/o/r/pull/1 o r 1 extra > "$dir/home/state/task-a.pr-poll"
  out=$(FM_TEST_GH_STATE=MERGED run_poll "$dir")
  [ -z "$out" ] || fail "static poll emitted with multiline sidecar"
  printf '%s\n%s\n%s\n%s\n' https://github.com/o/r/pull/1x o r 1x > "$dir/home/state/task-a.pr-poll"
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
    cmp -s "$POLL" "$dir/home/state/task-a.check.sh" || fail "concurrent publication check bytes changed"
    [ "$(file_mode "$dir/home/state/task-a.check.sh")" = 600 ] || fail "concurrent check mode was not private"
    [ "$(file_mode "$dir/home/state/task-a.pr-poll")" = 600 ] || fail "concurrent sidecar mode was not private"
    n=$((n + 1))
  done
  pass "concurrent watchers observe only complete private poll publications"
}

test_migration_excludes_older_watcher_before_scan() {
  local dir state gate sentinel older_pid rc
  dir=$(make_case migration-pause-before-scan)
  state="$dir/home/state"
  gate="$dir/scan-started"
  sentinel="$dir/legacy-ran"
  fm_write_meta "$state/task-a.meta" \
    'window=fm-task-a' \
    'pr=https://github.com/o/r/pull/9'
  cat > "$state/task-a.check.sh" <<SH
#!/usr/bin/env bash
printf 'seen\n' > '$sentinel'
SH
  (
    while [ ! -e "$gate" ]; do sleep 0.01; done
    bash "$state/task-a.check.sh"
    while :; do sleep 1; done
  ) &
  older_pid=$!
  write_watcher_lock "$state" "$dir/home" "$older_pid"
  cat > "$dir/fakebin/basename" <<SH
#!/usr/bin/env bash
: > '$gate'
sleep 0.3
exec '$REAL_BASENAME' "\$@"
SH
  chmod +x "$dir/fakebin/basename"

  set +e
  FM_HOME="$dir/home" PATH="$dir/fakebin:$BASE_PATH" "$MIGRATE" > "$dir/migrate.out" 2> "$dir/migrate.err"
  rc=$?
  set -e
  wait "$older_pid" 2>/dev/null || true
  [ "$rc" -eq 0 ] || fail "pause-before-scan migration failed"
  [ ! -e "$sentinel" ] || fail "older watcher ran a legacy check during migration startup"
  [ -e "$gate" ] || fail "migration never reached its under-lock check scan"
  assert_valid_migration_marker "$state/.pr-check-migration-v1"
  cmp -s "$POLL" "$state/task-a.check.sh" || fail "pause-before-scan migration did not rebuild the poll"

  dir=$(make_case migration-pause-no-check)
  state="$dir/home/state"
  ( while :; do sleep 1; done ) &
  older_pid=$!
  write_watcher_lock "$state" "$dir/home" "$older_pid"
  set +e
  FM_HOME="$dir/home" PATH="$dir/fakebin:$BASE_PATH" "$MIGRATE" > "$dir/migrate.out" 2> "$dir/migrate.err"
  rc=$?
  set -e
  wait "$older_pid" 2>/dev/null || true
  [ "$rc" -eq 0 ] || fail "no-check older-watcher migration failed"
  ! kill -0 "$older_pid" 2>/dev/null || fail "no-check migration left the older watcher running"
  assert_valid_migration_marker "$state/.pr-check-migration-v1"
  pass "migration pauses older watchers and acquires exclusion before its first scan or marker"
}

test_private_artifact_paths_refuse_symlinks_and_directories() {
  local artifact kind dir state destination rc
  for artifact in task-a.pr-poll task-a.check.sh; do
    for kind in regular dangling directory; do
      dir=$(make_case "poll-path-${artifact//./-}-$kind")
      state="$dir/home/state"
      fm_pr_poll_prepare "$state" task-a https://github.com/o/r/pull/1 o r 1 "$POLL" \
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
    fm_pr_poll_prepare "$state" task-a https://github.com/o/r/pull/1 o r 1 "$POLL" \
      || fail "could not stage poll directory refusal fixture"
    destination="$state/$artifact"
    mkdir "$destination"
    if fm_pr_poll_publish_prepared; then
      fail "poll publication accepted a directory destination"
    fi
    fm_pr_poll_cleanup
    [ -d "$destination" ] || fail "poll publication replaced a directory destination"
    [ -z "$(find "$destination" -mindepth 1 -maxdepth 1 -print)" ] || fail "poll publication wrote inside a directory destination"
  done

  for artifact in marker log quarantine; do
    for kind in regular dangling directory; do
      dir=$(make_case "migration-path-$artifact-$kind")
      state="$dir/home/state"
      case "$artifact" in
        marker)
          destination="$state/.pr-check-migration-v1"
          ;;
        log)
          write_ambiguous_poll "$dir"
          destination="$state/.pr-check-migration.log"
          ;;
        quarantine)
          write_ambiguous_poll "$dir"
          destination="$state/.pr-check-quarantine"
          ;;
      esac
      make_private_symlink "$dir" "$destination" "$kind"
      set +e
      FM_HOME="$dir/home" PATH="$dir/fakebin:$BASE_PATH" "$MIGRATE" > "$dir/migrate.out" 2> "$dir/migrate.err"
      rc=$?
      set -e
      [ "$rc" -ne 0 ] || fail "migration accepted a symlinked private $artifact path"
      assert_private_symlink_unchanged "$destination"
      [ ! -e "$state/.pr-check-migration-v1" ] || [ -L "$state/.pr-check-migration-v1" ] \
        || fail "failed private-path migration published a completion marker"
    done
  done

  for artifact in marker log; do
    dir=$(make_case "migration-path-$artifact-direct-directory")
    state="$dir/home/state"
    if [ "$artifact" = marker ]; then
      destination="$state/.pr-check-migration-v1"
    else
      write_ambiguous_poll "$dir"
      destination="$state/.pr-check-migration.log"
    fi
    mkdir "$destination"
    set +e
    FM_HOME="$dir/home" PATH="$dir/fakebin:$BASE_PATH" "$MIGRATE" > "$dir/migrate.out" 2> "$dir/migrate.err"
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "migration accepted a directory $artifact destination"
    [ -d "$destination" ] || fail "migration replaced a directory $artifact destination"
    [ -z "$(find "$destination" -mindepth 1 -maxdepth 1 -print)" ] || fail "migration wrote inside a directory $artifact destination"
    [ ! -f "$state/.pr-check-migration-v1" ] || fail "failed directory-path migration published a marker"
  done
  pass "poll, marker, diagnostic, and quarantine paths refuse symlinks and directories"
}

install_mv_fault() {
  local dir=$1
  cat > "$dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
matched=0
for arg in "$@"; do
  case "$arg" in
    *"${FM_TEST_MV_MATCH:?}"*) matched=1 ;;
  esac
done
if [ "$matched" -eq 1 ]; then
  case "${FM_TEST_MV_ACTION:?}" in
    fail) exit 1 ;;
    signal)
      kill -TERM "$PPID"
      sleep 0.1
      exit 1
      ;;
  esac
fi
exec "$FM_TEST_REAL_MV" "$@"
SH
  chmod +x "$dir/fakebin/mv"
}

test_marker_and_diagnostic_rename_fail_closed() {
  local action dir state rc
  for action in fail signal; do
    dir=$(make_case "marker-rename-$action")
    state="$dir/home/state"
    install_mv_fault "$dir"
    set +e
    FM_TEST_MV_MATCH=.fm-pr-check-migration. FM_TEST_MV_ACTION="$action" FM_TEST_REAL_MV="$REAL_MV" \
      FM_HOME="$dir/home" PATH="$dir/fakebin:$BASE_PATH" "$MIGRATE" > "$dir/migrate.out" 2> "$dir/migrate.err"
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "marker rename $action was reported as success"
    [ ! -e "$state/.pr-check-migration-v1" ] || fail "marker rename $action left a completion marker"
    ! find "$state" -name '.fm-pr-check-migration.*' -print | grep . >/dev/null \
      || fail "marker rename $action left a staged marker"

    dir=$(make_case "diagnostic-rename-$action")
    state="$dir/home/state"
    write_ambiguous_poll "$dir"
    install_mv_fault "$dir"
    set +e
    FM_TEST_MV_MATCH=.fm-pr-check-log. FM_TEST_MV_ACTION="$action" FM_TEST_REAL_MV="$REAL_MV" \
      FM_HOME="$dir/home" PATH="$dir/fakebin:$BASE_PATH" "$MIGRATE" > "$dir/migrate.out" 2> "$dir/migrate.err"
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "diagnostic rename $action was reported as success"
    [ ! -e "$state/.pr-check-migration-v1" ] || fail "diagnostic rename $action published a completion marker"
    [ ! -e "$state/.pr-check-migration.log" ] || fail "diagnostic rename $action published a partial log"
    ! find "$state" -name '.fm-pr-check-log.*' -print | grep . >/dev/null \
      || fail "diagnostic rename $action left a staged log"
  done
  pass "marker and diagnostic rename errors and signals fail closed without partial publication"
}

test_nonexecuting_migration() {
  local dir state marker x_before x_after snap_before snap_after rc
  dir=$(make_case migration)
  state="$dir/home/state"
  marker="$dir/legacy-marker"
  fm_write_meta "$state/task-a.meta" \
    'window=fm-task-a' \
    'worktree=/private/unused' \
    'pr=https://github.com/o/r/pull/9'
  printf 'printf legacy > %q\n' "$marker" > "$state/task-a.check.sh"
  chmod 0644 "$state/task-a.check.sh"
  cat > "$state/x-watch.check.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' x
SH
  chmod 0755 "$state/x-watch.check.sh"
  x_before=$(state_snapshot "$state" | grep 'x-watch.check.sh')

  FM_HOME="$dir/home" "$MIGRATE" > "$dir/migrate.out" 2> "$dir/migrate.err" \
    || fail "canonical legacy migration failed"
  [ ! -e "$marker" ] || fail "migration executed legacy bytes"
  cmp -s "$POLL" "$state/task-a.check.sh" || fail "migration did not rebuild a canonical static poll"
  [ "$(file_mode "$state/task-a.check.sh")" = 600 ] || fail "migrated check mode was not 0600"
  [ "$(file_mode "$state/task-a.pr-poll")" = 600 ] || fail "migrated sidecar mode was not 0600"
  assert_valid_migration_marker "$state/.pr-check-migration-v1"
  find "$state/.pr-check-quarantine" -name 'task-a.check.*' -type f | grep . >/dev/null \
    || fail "legacy check was not quarantined"
  x_after=$(state_snapshot "$state" | grep 'x-watch.check.sh')
  [ "$x_after" = "$x_before" ] || fail "migration changed the X-mode shim"

  snap_before=$(state_snapshot "$state")
  FM_HOME="$dir/home" "$MIGRATE" > "$dir/migrate-2.out" 2> "$dir/migrate-2.err" \
    || fail "idempotent migration rerun failed"
  snap_after=$(state_snapshot "$state")
  [ "$snap_after" = "$snap_before" ] || fail "migration rerun changed state"
  printf 'trusted custom check bytes\n' > "$state/custom.check.sh"
  snap_before=$(state_snapshot "$state")
  FM_HOME="$dir/home" "$MIGRATE" >/dev/null 2>/dev/null || fail "completed migration rerun failed"
  snap_after=$(state_snapshot "$state")
  [ "$snap_after" = "$snap_before" ] || fail "completed migration changed a later custom check"

  dir=$(make_case migration-ambiguous)
  state="$dir/home/state"
  fm_write_meta "$state/task-b.meta" \
    'window=fm-task-b' \
    'pr=https://github.com/o/r/pull/10' \
    'window=injected-after-pr'
  printf 'legacy ambiguous bytes\n' > "$state/task-b.check.sh"
  FM_HOME="$dir/home" "$MIGRATE" > "$dir/migrate.out" 2> "$dir/migrate.err" \
    || fail "ambiguous migration failed to quarantine"
  [ ! -e "$state/task-b.check.sh" ] || fail "ambiguous migration left a runnable check"
  [ ! -e "$state/task-b.pr-poll" ] || fail "ambiguous migration built a sidecar"
  find "$state/.pr-check-quarantine" -name 'task-b.check.*' -type f | grep . >/dev/null \
    || fail "ambiguous poll was not quarantined"
  [ "$(file_mode "$state/.pr-check-migration.log")" = 600 ] || fail "migration diagnostics were not private"
  assert_grep 'task task-b: poll metadata is ambiguous or invalid' "$state/.pr-check-migration.log" \
    "migration diagnostic was not actionable"
  assert_valid_migration_marker "$state/.pr-check-migration-v1"

  dir=$(make_case migration-invalid-id)
  state="$dir/home/state"
  printf 'legacy invalid-id bytes\n' > "$state/bad_id.check.sh"
  set +e
  FM_HOME="$dir/home" "$MIGRATE" > "$dir/migrate.out" 2> "$dir/migrate.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "noncanonical artifact migration failed"
  [ ! -e "$state/bad_id.check.sh" ] || fail "noncanonical artifact remained runnable"
  assert_grep 'noncanonical task artifact' "$state/.pr-check-migration.log" \
    "noncanonical artifact diagnostic was missing"
  assert_valid_migration_marker "$state/.pr-check-migration-v1"
  pass "migration never executes legacy checks, preserves X mode, quarantines ambiguity, and is idempotent"
}

test_bootstrap_migrates_before_other_mutations() {
  local dir state
  dir=$(make_case bootstrap-boundary)
  state="$dir/home/state"
  fm_write_meta "$state/task-a.meta" \
    'window=fm-task-a' \
    'pr=https://github.com/o/r/pull/11'
  printf 'legacy bytes\n' > "$state/task-a.check.sh"

  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" PATH="$dir/fakebin:$BASE_PATH" \
    "$ROOT/bin/fm-bootstrap.sh" > "$dir/bootstrap.out" 2> "$dir/bootstrap.err" \
    || fail "bootstrap boundary failed"
  cmp -s "$POLL" "$state/task-a.check.sh" || fail "bootstrap did not migrate the legacy poll"
  [ "$(file_mode "$state/task-a.check.sh")" = 600 ] || fail "bootstrap migration did not publish privately"
  pass "bootstrap runs the non-executing migration at the locked session boundary"
}

test_teardown_removes_poll_artifacts() {
  local dir fakebin
  dir=$(make_case teardown-cleanup)
  fakebin="$dir/fakebin"
  fm_write_meta "$dir/home/state/task-a.meta" \
    'window=fm-task-a' \
    "worktree=$dir/missing-worktree" \
    "project=$dir/project" \
    'kind=ship' \
    'mode=local-only'
  printf 'check\n' > "$dir/home/state/task-a.check.sh"
  printf 'data\n' > "$dir/home/state/task-a.pr-poll"
  mkdir -p "$dir/home/state/.pr-check-quarantine"
  printf 'legacy\n' > "$dir/home/state/.pr-check-quarantine/task-a.check.abc123"
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
  ! find "$dir/home/state/.pr-check-quarantine" -name 'task-a.*' -print 2>/dev/null | grep . >/dev/null \
    || fail "teardown left task quarantine artifacts"
  pass "teardown removes checks, sidecars, and task quarantine artifacts"
}

test_parser_matrix
test_invalid_entrypoints_have_zero_side_effects
test_valid_recording_and_merge_derivation
test_delayed_execution_families_are_inert
test_static_poll_contract
test_atomic_interruption_leaves_no_partial_artifact
test_concurrent_watcher_sees_only_complete_publication
test_migration_excludes_older_watcher_before_scan
test_private_artifact_paths_refuse_symlinks_and_directories
test_marker_and_diagnostic_rename_fail_closed
test_nonexecuting_migration
test_bootstrap_migrates_before_other_mutations
test_teardown_removes_poll_artifacts
