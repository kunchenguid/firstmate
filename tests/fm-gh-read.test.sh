#!/usr/bin/env bash
# tests/fm-gh-read.test.sh - the Cursor worker GitHub read helper.
#
# The helper is built from the tracked source through bin/fm-gh-read.sh with
# an absolute fake target compiled in its place. The fake target records its
# argv, environment, parent pid, and stdin, so every case proves exactly what
# the helper would hand the hardened gh, and every denial proves the target
# never started. Nothing here contacts Automic Vault, the hardened gh, or
# GitHub.
#
# The load-bearing contracts:
#   1. Every allowed shape reaches the target byte for byte, as a child of the
#      helper, with stdin from /dev/null and only the constructed environment.
#   2. Every mutation of an allowed shape - at any position, as an equals
#      form, or as a duplicate - is denied with exit 64 before the target runs.
#   3. Writes, disclosure, aliases, extensions, downloads, logs, generic REST,
#      and GraphQL are denied before the target runs.
#   4. The product build is reproducible, and verify rejects a test build.
#   5. The native router sends only accepted reads to the helper and preserves
#      generic attended GitHub operations.
#   6. Only a Cursor ship or scout launch gains the protected PATH directory;
#      other harnesses, Cursor secondmates, and the pane shell are unchanged,
#      and an unsafe directory refuses the Cursor launch.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=bin/fm-gh-read-lib.sh
. "$ROOT/bin/fm-gh-read-lib.sh"

TOOL="$ROOT/bin/fm-gh-read.sh"
TMP_ROOT=$(fm_test_tmproot fm-gh-read)
LOG="$TMP_ROOT/target-log"
FAKE_TARGET="$TMP_ROOT/fake-gh"
HELPER="$TMP_ROOT/fm-gh-read"
ROUTER="$TMP_ROOT/fm-gh-read-route"
GENERIC_TARGET="$TMP_ROOT/generic-gh"
mkdir -p "$LOG"

command -v cc >/dev/null 2>&1 || fail "a C compiler (cc) is required to build the helper under test"

# The fake target is native too, so nothing a shell exports on its own can
# blur the environment it records.
cat > "$TMP_ROOT/fake-gh.c" <<EOF
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
extern char **environ;
static FILE *open_log(const char *name) {
  char path[4096];
  snprintf(path, sizeof(path), "%s/%s", "$LOG", name);
  return fopen(path, "w");
}
int main(int argc, char **argv) {
  FILE *f;
  char buf[8];
  int i;
  f = open_log("argv");
  for (i = 1; i < argc; i++) fprintf(f, "%s\n", argv[i]);
  fclose(f);
  f = open_log("env");
  for (i = 0; environ[i] != NULL; i++) fprintf(f, "%s\n", environ[i]);
  fclose(f);
  f = open_log("ppid");
  fprintf(f, "%d\n", (int)getppid());
  fclose(f);
  f = open_log("stdin");
  fprintf(f, "%d\n", (int)read(0, buf, sizeof(buf)));
  fclose(f);
  f = open_log("fd9");
  fprintf(f, "%s\n", fcntl(9, F_GETFD) == -1 ? "closed" : "open");
  fclose(f);
  for (i = 1; i < argc; i++) if (strcmp(argv[i], "4242") == 0) return 7;
  return 0;
}
EOF
cc -o "$FAKE_TARGET" "$TMP_ROOT/fake-gh.c" || fail "could not build the fake target"
"$TOOL" build --out "$HELPER" --fake-target "$FAKE_TARGET" >"$TMP_ROOT/build.out" ||
  fail "the helper did not build: $(cat "$TMP_ROOT/build.out")"
cat >"$GENERIC_TARGET" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$FM_TEST_GENERIC_LOG"
SH
chmod +x "$GENERIC_TARGET"
"$TOOL" build-router --out "$ROUTER" --helper-target "$HELPER" \
  --generic-target "$GENERIC_TARGET" >/dev/null || fail "the native router did not build"
# The enrolled payload has Hardened Runtime, which ignores caller DYLD_* .
# The test build is unsigned, so without this the hostile caller environment
# would abort the helper itself before policy runs.
if [ "$(uname)" = Darwin ] && command -v codesign >/dev/null 2>&1; then
  codesign --force --sign - --options runtime -- "$HELPER" >/dev/null 2>&1 ||
    fail "could not ad-hoc sign the test helper with Hardened Runtime"
fi

PW_HOME=$(eval "printf '%s' ~$(id -un)")

# Run the helper with a hostile caller environment and stdin.
# Sets RUN_STATUS and RUN_PID.
run_helper() {
  rm -f "$LOG"/*
  printf 'caller-secret-stdin\n' >"$TMP_ROOT/stdin"
  env -i HOME=/tmp/evil-home GH_TOKEN=caller-token GITHUB_TOKEN=caller-token \
    GH_ENTERPRISE_TOKEN=caller-token GH_HOST=evil.example GH_REPO=evil/repo \
    GH_CONFIG_DIR=/tmp/evil-config XDG_CONFIG_HOME=/tmp/evil-xdg \
    NODE_OPTIONS=--require=/tmp/evil.js DYLD_INSERT_LIBRARIES=/tmp/evil.dylib \
    LD_PRELOAD=/tmp/evil.so GH_DEBUG=api GH_PAGER=/tmp/evil-pager PAGER=/tmp/evil-pager \
    HTTPS_PROXY=http://evil.example:1 SSL_CERT_FILE=/tmp/evil.pem \
    FM_ALLOW_WRITE=1 CURSOR_AGENT=1 PATH=/tmp/evil-bin \
    "$HELPER" "$@" <"$TMP_ROOT/stdin" >"$TMP_ROOT/out" 2>"$TMP_ROOT/err" 9<"$TMP_ROOT/stdin" &
  RUN_PID=$!
  wait "$RUN_PID"
  RUN_STATUS=$?
}

expect_allowed() {
  local label=$1 expected env_keys
  shift
  run_helper "$@"
  expect_code 0 "$RUN_STATUS" "allowed shape '$label' ($(cat "$TMP_ROOT/err"))"
  expected=$(printf '%s\n' "$@")
  assert_equals "$expected" "$(cat "$LOG/argv")" "target argv for '$label'"
  assert_equals "$RUN_PID" "$(cat "$LOG/ppid")" "the helper must be the target's parent for '$label'"
  assert_equals 0 "$(cat "$LOG/stdin")" "target stdin must be /dev/null for '$label'"
  env_keys=$(sed 's/=.*//' "$LOG/env" | LC_ALL=C sort | tr '\n' ' ')
  assert_equals "GH_NO_EXTENSION_UPDATE_NOTIFIER GH_NO_UPDATE_NOTIFIER GH_PAGER GH_PROMPT_DISABLED GH_SPINNER_DISABLED HOME LOGNAME PATH USER " \
    "$env_keys" "target environment keys for '$label'"
  assert_grep "HOME=$PW_HOME" "$LOG/env" "HOME must come from the account database for '$label'"
  assert_grep "PATH=/usr/bin:/bin:/usr/sbin:/sbin" "$LOG/env" "PATH must be the fixed system path for '$label'"
  assert_grep "GH_PAGER=" "$LOG/env" "the pager must be disabled for '$label'"
  if [ "$(uname)" = Darwin ]; then
    assert_equals closed "$(cat "$LOG/fd9")" "inherited descriptors must be closed for '$label'"
  fi
}

expect_denied() {
  local label=$1
  shift
  run_helper "$@"
  expect_code 64 "$RUN_STATUS" "denied shape '$label'"
  assert_contains "$(cat "$TMP_ROOT/err")" "fm-gh-read: denied:" "denial reason for '$label'"
  [ ! -e "$LOG/argv" ] || fail "the target started for denied shape '$label'"
}

# One allowed shape per line, space separated. Values never contain spaces.
ALLOWED_SHAPES='repo view kunchenguid/firstmate
repo view kunchenguid/firstmate --json name,description
pr list --json number,title,state,author,headRefName,isDraft --state open --limit 30 --repo owner/repo
pr list --json number,title --state all --limit 1000 --label bug --label docs --assignee @me --author octo-cat --base main --head fm/fix-1 --draft --repo o/r
pr view 42 --json number,title,statusCheckRollup --repo owner/repo.name
pr checks 42 --required --json name,state,bucket --repo o/r
issue list --json number,title,state,author,createdAt --limit 30 --repo o/r
issue list --json number --limit 1 --state closed --label bug --assignee octocat --author @me --milestone v1.2 --search sort:updated-desc --repo o/r
issue view 7 --json number,title,body --repo o/r
run list --json databaseId,status --limit 10 --workflow ci.yml --branch main --status completed --event pull_request --user octocat --commit 0123abc --repo o/r
run view 123456789 --repo o/r
run view --job 987 --json databaseId --repo o/r
run view 5 --job 6 --json jobs --repo o/r
workflow list --json id,name,state,path --limit 20 --all --repo o/r
workflow view ci.yml --repo o/r
workflow view 12345 --repo o/r'

test_every_allowed_shape_reaches_the_target_exactly() {
  local line count=0
  local -a args
  while IFS= read -r line; do
    read -ra args <<<"$line"
    expect_allowed "$line" "${args[@]}"
    count=$((count + 1))
  done <<<"$ALLOWED_SHAPES"
  [ "$count" -ge 16 ] || fail "the allowed-shape table shrank to $count cases"
  pass "all $count allowed shapes reach the fake target byte for byte, as its parent, with a scrubbed environment"
}

test_target_exit_status_is_propagated() {
  run_helper pr view 4242 --repo o/r
  expect_code 7 "$RUN_STATUS" "the target's exit status must pass through"
  pass "the target's exit status passes through unchanged"
}

test_invocation_name_does_not_change_policy() {
  local link="$TMP_ROOT/path-bin/gh"
  mkdir -p "$TMP_ROOT/path-bin"
  ln -sf "$HELPER" "$link"
  rm -f "$LOG"/*
  "$link" pr create --title x >/dev/null 2>&1
  expect_code 64 "$?" "a helper invoked as gh must still deny writes"
  [ ! -e "$LOG/argv" ] || fail "the target started for a write invoked through a gh link"
  "$link" pr view 1 --repo o/r >/dev/null 2>&1
  expect_code 0 "$?" "a helper invoked as gh must still allow reads"
  pass "invoking the helper through a link named gh changes nothing"
}

test_mutations_at_every_position_are_denied() {
  local line i n m count=0 mutated
  local -a args trial
  local -a mutations=(--hostname -R --web --jq '' --template --paginate -)
  while IFS= read -r line; do
    read -ra args <<<"$line"
    n=${#args[@]}
    for ((i = 0; i < n; i++)); do
      for m in "${mutations[@]}"; do
        trial=("${args[@]}")
        trial[i]=$m
        expect_denied "$line: position $i replaced by '$m'" "${trial[@]}"
        count=$((count + 1))
      done
    done
    for ((i = 0; i <= n; i++)); do
      for mutated in '--hostname evil.example' '--web' '-R o/r' '--repo=o/r' '--' '--help'; do
        read -ra trial <<<"$mutated"
        trial=("${args[@]:0:i}" "${trial[@]}" "${args[@]:i}")
        expect_denied "$line: '$mutated' inserted at $i" "${trial[@]}"
        count=$((count + 1))
      done
    done
  done <<<"$ALLOWED_SHAPES"
  pass "$count positional replacements and insertions are all denied before the target starts"
}

test_equals_and_duplicate_forms_are_denied() {
  local line i n count=0
  local -a args trial
  while IFS= read -r line; do
    read -ra args <<<"$line"
    n=${#args[@]}
    for ((i = 2; i < n; i++)); do
      case "${args[i]}" in --*) ;; *) continue ;; esac
      if [ $((i + 1)) -lt "$n" ] && [ "${args[i + 1]#-}" = "${args[i + 1]}" ] &&
        [ "${args[i]}" != --draft ] && [ "${args[i]}" != --archived ] &&
        [ "${args[i]}" != --required ] && [ "${args[i]}" != --all ]; then
        trial=("${args[@]:0:i}" "${args[i]}=${args[i + 1]}" "${args[@]:i+2}")
        expect_denied "$line: equals form of ${args[i]}" "${trial[@]}"
        count=$((count + 1))
        [ "${args[i]}" = --label ] && continue
        trial=("${args[@]}" "${args[i]}" "${args[i + 1]}")
      else
        trial=("${args[@]}" "${args[i]}")
      fi
      expect_denied "$line: duplicate ${args[i]}" "${trial[@]}"
      count=$((count + 1))
    done
  done <<<"$ALLOWED_SHAPES"
  expect_denied "duplicate PR selector" pr view 1 2
  expect_denied "duplicate repository selector" repo view o/r o/s
  expect_denied "duplicate run selector" run view 1 2
  trial=(pr list --repo o/r)
  for ((i = 0; i < 20; i++)); do trial+=(--label "l$i"); done
  expect_allowed "twenty labels" "${trial[@]}"
  trial+=(--label l20)
  expect_denied "twenty-one labels" "${trial[@]}"
  pass "$count equals and duplicate forms, duplicate selectors, and label overflow are denied"
}

test_malformed_selectors_and_limits_are_denied() {
  local value
  for value in owner owner/name/extra github.com/owner/name https://github.com/o/r o/r.git -o/r o//r \
    /r o/ o/.. o/. own--er/r owner-/r "o/r x" "o/r;x" o/r%2F "$(printf 'o/r\nx')" \
    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/r; do
    expect_denied "repository selector '$value'" pr list --repo "$value"
    expect_denied "repo view selector '$value'" repo view "$value"
  done
  expect_allowed "a 39-character owner" pr list --repo aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/r
  for value in 0 -1 1001 01 1e3 abc 10000 " 5" +5 99999999999999999999; do
    expect_denied "limit '$value'" pr list --limit "$value"
  done
  expect_allowed "the largest limit" issue list --limit 1000 --repo o/r
  for value in 0 -5 12a 042 1.5 12345678901234567890 "#1" https://github.com/o/r/pull/1; do
    expect_denied "PR selector '$value'" pr view "$value"
    expect_denied "run selector '$value'" run view "$value"
  done
  expect_denied "a missing PR selector" pr view
  expect_denied "a missing issue selector" issue view --json number
  expect_denied "a run view with neither id nor job" run view --json jobs
  expect_denied "a missing workflow selector" workflow view
  expect_denied "a trailing option with no value" pr list --repo
  expect_denied "empty fields" pr view 1 --json ''
  expect_denied "a field expression" pr view 1 --json 'number,.[0]'
  expect_denied "an empty field" pr view 1 --json number,,title
  expect_denied "an unknown state" pr list --state draft
  expect_denied "a merged issue state" issue list --state merged
  expect_denied "a free-form issue search" issue list --search 'is:open secret'
  expect_denied "repository listing has no repository selector" repo list
  expect_denied "an uppercase commit" run list --commit ABCDEF1
  expect_denied "a short commit" run list --commit abc
  expect_denied "an unknown run status" run list --status exploded
  expect_denied "an option-shaped label" pr list --label --web
  expect_denied "a control byte in a label" pr list --label "$(printf 'a\tb')"
  expect_denied "an invalid login" pr list --author 'bad login'
  pass "malformed repositories, limits, selectors, fields, and enum values are denied"
}

test_every_shape_requires_a_repository() {
  expect_denied "repo view without a repository" repo view
  expect_denied "repository listing without a repository" repo list octocat
  expect_denied "PR list without a repository" pr list
  expect_denied "PR view without a repository" pr view 1
  expect_denied "PR checks without a repository" pr checks 1
  expect_denied "issue list without a repository" issue list
  expect_denied "issue view without a repository" issue view 1
  expect_denied "run list without a repository" run list
  expect_denied "run view without a repository" run view 1
  expect_denied "workflow list without a repository" workflow list
  expect_denied "workflow view without a repository" workflow view ci.yml
  pass "every accepted shape refuses ambient repository and host context"
}

test_writes_and_disclosure_are_denied() {
  local line
  local -a args
  while IFS= read -r line; do
    read -ra args <<<"$line"
    expect_denied "$line" "${args[@]}"
  done <<'EOF'
pr create --title x --body y
pr edit 1 --title x
pr merge 1 --squash
pr comment 1 --body x
pr close 1
pr reopen 1
pr ready 1
pr review 1 --approve
pr checkout 1
pr diff 1
pr view 1 --web
pr view 1 --comments
pr list --jq .
pr view 1 --template x
pr checks 1 --watch
issue create --title x
issue comment 1 --body x
issue close 1
issue edit 1 --add-label x
issue transfer 1 o/r
run rerun 1
run cancel 1
run delete 1
run watch 1
run download 1
run view 1 --log
run view 1 --log-failed
workflow run ci.yml
workflow enable ci.yml
workflow disable ci.yml
release list
release view v1
release create v1
release download v1
repo clone o/r
repo fork o/r
repo delete o/r --yes
repo edit o/r --visibility public
alias set x pr
alias list
extension install owner/gh-x
extension list
auth token
auth status
auth git-credential get
auth login
api repos/o/r
api graphql -f query=x
api -X POST repos/o/r/issues
secret list
secret set X
variable list
search prs x
gist list
browse
config get git_protocol
status
codespace list
--help
--version
help
EOF
  expect_denied "no arguments at all"
  expect_denied "a family with no verb" pr
  pass "writes, disclosure, aliases, extensions, logs, downloads, and generic API forms are denied before the target"
}

test_product_build_is_reproducible_and_verify_rejects_test_builds() {
  local a="$TMP_ROOT/product-a" b="$TMP_ROOT/product-b" out status
  "$TOOL" build --out "$a" >/dev/null || fail "product build failed"
  "$TOOL" build --out "$b" >/dev/null || fail "second product build failed"
  cmp -s "$a" "$b" || fail "two product builds of the same source differ"
  out=$("$TOOL" verify --payload "$a" 2>&1)
  assert_contains "$out" "payload      ok" "verify must accept a product build of the tracked source"
  out=$("$TOOL" verify --payload "$HELPER" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "verify must fail for a fake-target build"
  assert_contains "$out" "payload      FAIL" "verify must name the payload mismatch for a fake-target build"
  assert_contains "$out" "gate         unverified" "verify must not claim Gate attribution without evidence"
  pass "the product build is reproducible and verify rejects a fake-target build"
}

test_verify_gate_evidence() {
  local cmd="$TMP_ROOT/cmd-link" payload="$TMP_ROOT/product-a" out
  out=$("$TOOL" verify --payload "$payload" --command "$cmd" 2>&1)
  assert_contains "$out" "command      FAIL" "a missing command link must fail"
  assert_contains "$out" "gate         unverified" "Gate attribution must require manual App confirmation"
  out=$("$TOOL" verify --payload "$payload" --history "$TMP_ROOT/untrusted.json" 2>&1)
  assert_contains "$out" "unknown verify argument: --history" "unstructured history must not be accepted as Gate evidence"
  pass "verify leaves Gate attribution for manual App confirmation"
}

test_plan_and_install_path_are_guarded() {
  local out status before after
  before=$(ls -A "$TMP_ROOT")
  out=$(FM_GH_READ_CURSOR_DIR_OVERRIDE="$TMP_ROOT/no-such-dir" "$TOOL" plan 2>&1)
  expect_code 0 "$?" "plan"
  after=$(ls -A "$TMP_ROOT")
  assert_equals "$before" "$after" "plan must not create anything"
  assert_contains "$out" "absent:" "plan must report the absent Cursor PATH directory"
  assert_contains "$out" "Launcher Bundle" "plan must name the attended enrollment step"
  out=$("$TOOL" install-path --command /usr/local/bin/fm-gh-read </dev/null 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "install-path must refuse without an attended terminal"
  out=$(FM_GH_READ_CURSOR_DIR_OVERRIDE="$TMP_ROOT/x" "$TOOL" install-path --command /usr/local/bin/fm-gh-read </dev/null 2>&1)
  assert_contains "$out" "refuses FM_GH_READ_CURSOR_DIR_OVERRIDE" "install-path must never honor the test seam"
  pass "plan changes nothing and install-path refuses unattended or redirected runs"
}

# A user-owned stand-in for the protected directory, through the test seam.
make_cursor_dir() {  # <name> -> echoes dir
  local dir="$TMP_ROOT/cursor/$1"
  mkdir -p "$dir" "$TMP_ROOT/cursor/cmd"
  chmod 0755 "$TMP_ROOT/cursor" "$dir" "$TMP_ROOT/cursor/cmd"
  cp "$ROUTER" "$dir/gh"
  chmod 0755 "$dir/gh"
  printf '%s\n' "$dir"
}

test_cursor_path_dir_checks() {
  local dir out
  FM_GH_READ_CURSOR_DIR_OVERRIDE="$TMP_ROOT/cursor/absent" fm_gh_read_cursor_path_dir >/dev/null 2>&1
  expect_code 1 "$?" "an absent directory"
  dir=$(make_cursor_dir good)
  out=$(FM_GH_READ_CURSOR_DIR_OVERRIDE="$dir" fm_gh_read_cursor_path_dir)
  expect_code 0 "$?" "a protected directory"
  assert_equals "$dir" "$out" "the verified directory"

  dir=$(make_cursor_dir group-writable)
  chmod 0775 "$dir"
  FM_GH_READ_CURSOR_DIR_OVERRIDE="$dir" fm_gh_read_cursor_path_dir >/dev/null 2>&1
  expect_code 2 "$?" "a group-writable directory"

  dir=$(make_cursor_dir extra)
  touch "$dir/gh-axi"
  FM_GH_READ_CURSOR_DIR_OVERRIDE="$dir" fm_gh_read_cursor_path_dir >/dev/null 2>&1
  expect_code 2 "$?" "a directory with a second entry"

  dir=$(make_cursor_dir not-executable)
  chmod 0644 "$dir/gh"
  FM_GH_READ_CURSOR_DIR_OVERRIDE="$dir" fm_gh_read_cursor_path_dir >/dev/null 2>&1
  expect_code 2 "$?" "a non-executable router"

  ln -s "$TMP_ROOT/cursor/good" "$TMP_ROOT/cursor/dir-link"
  FM_GH_READ_CURSOR_DIR_OVERRIDE="$TMP_ROOT/cursor/dir-link" fm_gh_read_cursor_path_dir >/dev/null 2>&1
  expect_code 2 "$?" "a directory that is itself a link"
  pass "the Cursor PATH directory is honored only when every hop is protected"
}

test_router_preserves_attended_generic_path() {
  local generic_log="$TMP_ROOT/generic.log"
  rm -f "$generic_log" "$LOG/argv"
  FM_TEST_GENERIC_LOG="$generic_log" "$ROUTER" pr view 42 --repo o/r >/dev/null
  assert_equals $'pr\nview\n42\n--repo\no/r' "$(cat "$LOG/argv")" \
    "an accepted closed read must reach the enrolled helper"
  [ ! -e "$generic_log" ] || fail "an accepted closed read reached generic gh"

  rm -f "$generic_log" "$LOG/argv"
  FM_TEST_GENERIC_LOG="$generic_log" "$ROUTER" pr create --title x >/dev/null
  assert_equals $'pr\ncreate\n--title\nx' "$(cat "$generic_log")" \
    "a direct-PR write must use generic attended gh"
  [ ! -e "$LOG/argv" ] || fail "a write reached the enrolled helper"

  rm -f "$generic_log" "$LOG/argv"
  FM_TEST_GENERIC_LOG="$generic_log" "$ROUTER" pr view https://github.com/o/r/pull/42 --json isDraft >/dev/null
  assert_equals $'pr\nview\nhttps://github.com/o/r/pull/42\n--json\nisDraft' "$(cat "$generic_log")" \
    "an instructed URL-selector read must use generic attended gh"
  [ ! -e "$LOG/argv" ] || fail "a URL-selector form reached the enrolled helper"

  rm -f "$generic_log" "$LOG/argv"
  FM_TEST_GENERIC_LOG="$generic_log" "$ROUTER" api graphql -f query=x >/dev/null
  [ ! -e "$LOG/argv" ] || fail "a helper-denied API form gained automatic authority"
  assert_grep 'api' "$generic_log" "a helper-denied form must remain on generic attended gh"
  pass "the router isolates automatic reads from attended generic GitHub operations"
}

# --- spawn routing -----------------------------------------------------------

make_spawn_case() {  # <name> <harness> <id> -> "home|project|worktree|fakebin|launchlog|panelog"
  local name=$1 harness=$2 id=$3 case_dir fakebin
  case_dir="$TMP_ROOT/spawn/$name"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake" claude pi codex)
  cat > "$fakebin/cursor-agent" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --list-models ]; then
  printf '%s\n' 'Available models' 'cursor-grok-4.5-high - Grok 4.5 High'
fi
exit 0
SH
  chmod +x "$fakebin/cursor-agent"
  fm_test_spawn_home "$case_dir/home" "$harness"
  fm_git_worktree "$case_dir/project" "$case_dir/wt" "wt-$name"
  fm_test_spawn_brief "$case_dir/home" "$id"
  printf '%s\n' "$case_dir/home|$case_dir/project|$case_dir/wt|$fakebin|$case_dir/launch.log|$case_dir/pane.log"
}

run_case_spawn() {  # <record> <id> <cursor-dir> [spawn args...]
  local rec=$1 id=$2 dir=$3 home proj wt fakebin launchlog panelog
  shift 3
  IFS='|' read -r home proj wt fakebin launchlog panelog <<<"$rec"
  : >"$launchlog"
  : >"$panelog"
  FM_GH_READ_CURSOR_DIR_OVERRIDE="$dir" FM_FAKE_LAUNCH_LOG="$launchlog" FM_FAKE_PANE_LOG="$panelog" \
    GROK_HOME="$home/grok-home" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" "$@"
}

test_spawn_routes_only_cursor_workers() {
  local dir rec launch panes out status quoted
  dir=$(make_cursor_dir spawn-good)
  quoted="PATH='$dir':\"\$PATH\" env -u CLAUDECODE"

  rec=$(make_spawn_case cursor-ship cursor gh-read-cursor-ship-a1)
  out=$(run_case_spawn "$rec" gh-read-cursor-ship-a1 "$dir" --mode no-mistakes --yolo off)
  expect_code 0 "$?" "cursor ship spawn: $out"
  launch=$(cat "$TMP_ROOT/spawn/cursor-ship/launch.log")
  panes=$(cat "$TMP_ROOT/spawn/cursor-ship/pane.log")
  assert_contains "$launch" "$quoted" "a Cursor ship launch must prepend the protected helper directory"
  assert_not_contains "$panes" "$dir" "the pane shell must not receive the helper directory"

  rec=$(make_spawn_case cursor-scout cursor gh-read-cursor-scout-a2)
  out=$(run_case_spawn "$rec" gh-read-cursor-scout-a2 "$dir" --scout)
  expect_code 0 "$?" "cursor scout spawn: $out"
  assert_contains "$(cat "$TMP_ROOT/spawn/cursor-scout/launch.log")" "$quoted" \
    "a Cursor scout launch must prepend the protected helper directory"

  rec=$(make_spawn_case cursor-absent cursor gh-read-cursor-absent-a3)
  out=$(run_case_spawn "$rec" gh-read-cursor-absent-a3 "$TMP_ROOT/cursor/none" --mode no-mistakes --yolo off)
  expect_code 0 "$?" "cursor spawn without the directory: $out"
  launch=$(cat "$TMP_ROOT/spawn/cursor-absent/launch.log")
  assert_contains "$launch" "env -u CLAUDECODE" "the Cursor launch must still be delivered"
  assert_not_contains "$launch" "PATH=" "an absent directory must leave the Cursor launch unchanged"

  for harness in claude pi codex; do
    rec=$(make_spawn_case "other-$harness" "$harness" "gh-read-other-$harness-a4")
    out=$(run_case_spawn "$rec" "gh-read-other-$harness-a4" "$dir" --mode no-mistakes --yolo off)
    status=$?
    launch=$(cat "$TMP_ROOT/spawn/other-$harness/launch.log")
    [ -n "$launch" ] || fail "$harness spawn delivered no launch (exit $status): $out"
    assert_not_contains "$launch" "$dir" "a $harness launch must never gain the helper directory"
  done
  pass "only Cursor ship and scout launches prepend the helper directory; the pane shell and other harnesses are unchanged"
}

test_parser_runs_before_the_target() {
  local missing="$TMP_ROOT/no-such-target" helper="$TMP_ROOT/missing-target-helper"
  "$TOOL" build --out "$helper" --fake-target "$missing" >/dev/null || fail "missing-target helper did not build"
  rm -f "$LOG"/*
  "$helper" pr create --title x >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"
  expect_code 64 "$?" "deny must happen before a missing target is spawned"
  assert_contains "$(cat "$TMP_ROOT/err")" "denied:" "parser denial"
  assert_not_contains "$(cat "$TMP_ROOT/err")" "cannot start" "a denial must not attempt posix_spawn"
  [ ! -e "$missing" ] || fail "a denial must not create the target"
  [ ! -e "$LOG/argv" ] || fail "the missing target cannot have started"
  "$helper" pr view 1 --repo o/r >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"
  expect_code 70 "$?" "an allowed shape against a missing target fails at spawn"
  assert_contains "$(cat "$TMP_ROOT/err")" "cannot start" "an allowed shape must reach posix_spawn"
  pass "the parser denies before posix_spawn; only an allowed shape attempts the target"
}

test_spawn_does_not_route_cursor_secondmates() {
  local dir rec home proj wt fakebin launchlog panelog sm out
  dir=$(make_cursor_dir spawn-sm)
  rec=$(make_spawn_case cursor-sm cursor gh-read-cursor-sm-a7)
  IFS='|' read -r home proj wt fakebin launchlog panelog <<<"$rec"
  sm="$TMP_ROOT/spawn/cursor-sm/secondmate-home"
  mkdir -p "$sm/bin" "$sm/data" "$sm/state" "$sm/config"
  printf '# Firstmate\n' >"$sm/AGENTS.md"
  printf '%s\n' gh-read-cursor-sm-a7 >"$sm/.fm-secondmate-home"
  printf 'charter\n' >"$sm/data/charter.md"
  : >"$launchlog"
  : >"$panelog"
  out=$(FM_GH_READ_CURSOR_DIR_OVERRIDE="$dir" FM_FAKE_LAUNCH_LOG="$launchlog" FM_FAKE_PANE_LOG="$panelog" \
    GROK_HOME="$home/grok-home" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" gh-read-cursor-sm-a7 "$sm" --secondmate)
  expect_code 0 "$?" "cursor secondmate spawn: $out"
  assert_not_contains "$(cat "$launchlog")" "$dir" "a Cursor secondmate must keep the generic gh"
  pass "Cursor secondmates do not prepend the helper directory"
}

test_spawn_refuses_an_unsafe_cursor_dir() {
  local dir rec out status
  dir=$(make_cursor_dir spawn-unsafe)
  chmod 0777 "$dir"
  rec=$(make_spawn_case cursor-unsafe cursor gh-read-cursor-unsafe-a5)
  out=$(run_case_spawn "$rec" gh-read-cursor-unsafe-a5 "$dir" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "an unsafe helper directory must refuse the Cursor launch"
  assert_contains "$out" "GitHub read helper directory is unsafe" "the refusal must name the unsafe directory"
  [ ! -s "$TMP_ROOT/spawn/cursor-unsafe/launch.log" ] || fail "no launch may be delivered after the refusal"
  rec=$(make_spawn_case claude-unsafe claude gh-read-claude-unsafe-a6)
  out=$(run_case_spawn "$rec" gh-read-claude-unsafe-a6 "$dir" --mode no-mistakes --yolo off)
  expect_code 0 "$?" "a claude spawn must not consult the Cursor helper directory: $out"
  pass "an unsafe helper directory refuses only the Cursor launch"
}

test_every_allowed_shape_reaches_the_target_exactly
test_target_exit_status_is_propagated
test_invocation_name_does_not_change_policy
test_mutations_at_every_position_are_denied
test_equals_and_duplicate_forms_are_denied
test_malformed_selectors_and_limits_are_denied
test_every_shape_requires_a_repository
test_writes_and_disclosure_are_denied
test_product_build_is_reproducible_and_verify_rejects_test_builds
test_verify_gate_evidence
test_plan_and_install_path_are_guarded
test_cursor_path_dir_checks
test_router_preserves_attended_generic_path
test_parser_runs_before_the_target
test_spawn_routes_only_cursor_workers
test_spawn_does_not_route_cursor_secondmates
test_spawn_refuses_an_unsafe_cursor_dir
