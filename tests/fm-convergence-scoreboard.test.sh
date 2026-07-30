#!/usr/bin/env bash
# Behavior tests for the deterministic, read-only convergence scoreboard.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCOREBOARD="$ROOT/bin/fm-convergence-scoreboard.sh"
TMP_ROOT=$(fm_test_tmproot fm-convergence-scoreboard)
fm_git_identity

make_fixture() {
  local repo="$TMP_ROOT/repo"
  mkdir -p "$repo/bin" "$repo/docs"
  git -C "$repo" init -q -b main
  printf 'base\n' > "$repo/AGENTS.md"
  printf 'old\nstay\n' > "$repo/bin/tool.sh"
  printf 'remove\n' > "$repo/docs/guide.md"
  git -C "$repo" add AGENTS.md bin/tool.sh docs/guide.md
  git -C "$repo" commit -qm "chore: seed fixture"
  git -C "$repo" branch upstream

  git -C "$repo" checkout -qb local
  printf 'base\nlocal\n' > "$repo/AGENTS.md"
  printf 'new\nstay\n' > "$repo/bin/tool.sh"
  mkdir -p "$repo/tests"
  printf 'one\ntwo\n' > "$repo/tests/example.test.sh"
  git -C "$repo" rm -q docs/guide.md
  git -C "$repo" add AGENTS.md bin/tool.sh tests/example.test.sh
  git -C "$repo" commit -qm "feat: add local delivery"
  printf 'version = 1\n' > "$repo/.tasks.toml"
  printf 'other\n' > "$repo/misc.txt"
  git -C "$repo" add .tasks.toml misc.txt
  git -C "$repo" commit -qm "fix: finish local delivery"

  git -C "$repo" checkout -q upstream
  printf 'upstream\n' > "$repo/upstream.txt"
  git -C "$repo" add upstream.txt
  git -C "$repo" commit -qm "feat: advance upstream"
  git -C "$repo" checkout -q local
  printf '%s\n' "$repo"
}

run_scoreboard() {
  local repo=$1
  shift
  (
    cd "$repo" || exit 1
    "$SCOREBOARD" "$@"
  )
}

assert_no_trailing_newline() {
  local file=$1 label=$2 last_byte
  [ -s "$file" ] || fail "$label was empty"
  last_byte=$(tail -c 1 "$file" | od -An -tuC | tr -d '[:space:]')
  [ "$last_byte" != "10" ] || fail "$label ended with a newline"
}

test_deterministic_scoreboard() {
  local repo local_sha upstream_sha base_sha before after out rerun expected
  repo=$(make_fixture)
  local_sha=$(git -C "$repo" rev-parse local)
  upstream_sha=$(git -C "$repo" rev-parse upstream)
  base_sha=$(git -C "$repo" merge-base upstream local)
  before=$(git -C "$repo" show-ref)

  out=$(run_scoreboard "$repo" local upstream)
  rerun=$(run_scoreboard "$repo" local upstream)
  after=$(git -C "$repo" show-ref)

  expected=$(printf '%s\n' \
    'schema: "fm-convergence-scoreboard.v1"' \
    'local:' \
    '  ref: "local"' \
    "  commit: \"$local_sha\"" \
    'upstream:' \
    '  ref: "upstream"' \
    "  commit: \"$upstream_sha\"" \
    'commits:' \
    '  ahead: 2' \
    '  behind: 1' \
    '  first_parent_deliveries: 2' \
    'diff:' \
    "  base_commit: \"$base_sha\"" \
    '  changed_files: 6' \
    '  insertions: 6' \
    '  deletions: 2' \
    '  net_lines: 4' \
    'file_groups[6]{name,changed_files,insertions,deletions,net_lines}:' \
    '  "agent-runtime",1,1,0,1' \
    '  "automation",1,1,1,0' \
    '  "tests",1,2,0,2' \
    '  "documentation",1,0,1,-1' \
    '  "configuration",1,1,0,1' \
    '  "other",1,1,0,1')

  [ "$out" = "$expected" ] || fail "scoreboard output differs from the deterministic TOON contract:$'\n'$out"
  [ "$rerun" = "$out" ] || fail "identical refs produced different scoreboard output"
  [ "$after" = "$before" ] || fail "scoreboard mutated repository refs"
  [ -z "$(git -C "$repo" status --porcelain)" ] || fail "scoreboard dirtied the fixture worktree"
  pass "scoreboard reports reproducible graph, delivery, diff, and file-group metrics without mutation"
}

test_attributes_are_scoped_to_local_ref() {
  local repo expected from_worktree from_info
  repo=$TMP_ROOT/repo

  git -C "$repo" checkout -qb local-attributed local
  printf 'misc.txt -diff\n' > "$repo/.gitattributes"
  git -C "$repo" add .gitattributes
  git -C "$repo" commit -qm "test: add local measurement attributes"
  expected=$(run_scoreboard "$repo" local-attributed upstream)
  assert_contains "$expected" '  changed_files: 7' \
    "the local commit attribute fixture should add one changed file"
  assert_contains "$expected" '  "other",2,1,0,1' \
    "the local commit should classify its marked binary path with zero line changes"

  git -C "$repo" checkout -qb ambient-attributes upstream
  printf '* -diff\n' > "$repo/.gitattributes"
  git -C "$repo" add .gitattributes
  git -C "$repo" commit -qm "test: add unrelated worktree attributes"
  from_worktree=$(run_scoreboard "$repo" local-attributed upstream)
  [ "$from_worktree" = "$expected" ] \
    || fail "ambient worktree attributes changed metrics for the same explicit refs"

  printf '* diff\n' > "$repo/.git/info/attributes"
  from_info=$(run_scoreboard "$repo" local-attributed upstream)
  [ "$from_info" = "$expected" ] \
    || fail "ambient info attributes changed metrics for the same explicit refs"
  rm -f "$repo/.git/info/attributes"
  git -C "$repo" checkout -q local
  pass "scoreboard derives attributes from the explicit local ref, not ambient repository state"
}

test_tab_prefixed_path_is_not_documentation() {
  local repo tab_path out
  repo=$TMP_ROOT/repo
  tab_path=$'\tdocs/tab-prefixed.md'

  git -C "$repo" checkout -qb tab-path local
  mkdir -p "$repo/${tab_path%/*}"
  printf 'tab path\n' > "$repo/$tab_path"
  git -C "$repo" add -- "$tab_path"
  git -C "$repo" commit -qm "test: add tab-prefixed path"

  out=$(run_scoreboard "$repo" tab-path upstream)
  assert_contains "$out" '  "documentation",1,0,1,-1' \
    "a leading tab must not turn a non-documentation path into documentation"
  assert_contains "$out" '  "other",2,2,0,2' \
    "a tab-prefixed docs path should remain in the other group"
  git -C "$repo" checkout -q local
  pass "scoreboard preserves leading tabs when classifying changed paths"
}

test_git_environment_is_allowlisted() {
  local repo decoy expected out shim_dir real_git source_format ambient_format
  local ambient_shallow ambient_graft
  repo=$TMP_ROOT/repo
  decoy=$TMP_ROOT/decoy
  shim_dir=$TMP_ROOT/git-shim
  ambient_shallow=$TMP_ROOT/ambient-shallow
  ambient_graft=$TMP_ROOT/ambient-graft
  real_git=$(command -v git)
  source_format=$(git -C "$repo" rev-parse --show-object-format=storage)
  case "$source_format" in
    sha1) ambient_format=sha256 ;;
    sha256) ambient_format=sha1 ;;
    *) fail "unsupported fixture object format: $source_format" ;;
  esac

  git init -q -b main "$decoy"
  printf 'decoy\n' > "$decoy/README.md"
  git -C "$decoy" add README.md
  git -C "$decoy" commit -qm "test: seed decoy"
  git -C "$repo" rev-parse local > "$ambient_shallow"
  printf '%s %s\n' \
    "$(git -C "$repo" rev-parse local)" \
    "$(git -C "$repo" rev-parse upstream)" \
    > "$ambient_graft"
  mkdir -p "$shim_dir"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' "[ \"\${GIT_OPTIONAL_LOCKS-}\" = 0 ] || exit 91"
    printf '%s\n' "[ \"\${GIT_NO_LAZY_FETCH-}\" = 1 ] || exit 92"
    printf '%s\n' "[ -z \"\${GIT_NAMESPACE-}\" ] || exit 93"
    printf '%s\n' "[ -z \"\${SCOREBOARD_AMBIENT_SENTINEL-}\" ] || exit 94"
    printf '%s\n' "[ -z \"\${REAL_GIT-}\" ] || exit 95"
    printf "[ \"\${HOME-}\" = %q ] || exit 96\n" "${HOME-}"
    printf 'exec %q "$@"\n' "$real_git"
  } > "$shim_dir/git"
  chmod +x "$shim_dir/git"

  expected=$(run_scoreboard "$repo" local upstream)
  out=$(
    cd "$repo" || exit 1
    PATH="$shim_dir:$PATH" \
      REAL_GIT="$real_git" \
      GIT_DIR="$decoy/.git" \
      GIT_WORK_TREE="$decoy" \
      GIT_CONFIG_PARAMETERS="'core.warnAmbiguousRefs'='false'" \
      GIT_SHALLOW_FILE="$ambient_shallow" \
      GIT_GRAFT_FILE="$ambient_graft" \
      GIT_DEFAULT_HASH="$ambient_format" \
      GIT_NAMESPACE=ambient \
      GIT_OPTIONAL_LOCKS=1 \
      GIT_NO_LAZY_FETCH=0 \
      SCOREBOARD_AMBIENT_SENTINEL=present \
      "$SCOREBOARD" local upstream
  )

  [ "$out" = "$expected" ] \
    || fail "ambient Git repository or mutation settings changed the explicit-ref measurement"
  pass "scoreboard allowlists the complete Git execution environment"
}

test_fail_closed_invocation() {
  local repo out err rc
  repo=$TMP_ROOT/repo

  set +e
  out=$(run_scoreboard "$repo" 2>"$TMP_ROOT/no-args.err")
  rc=$?
  set -e
  err=$(cat "$TMP_ROOT/no-args.err")
  expect_code 2 "$rc" "missing refs"
  assert_contains "$out" 'error: "expected exactly <local-ref> and <upstream-ref>"' \
    "missing refs should emit one structured usage error"
  assert_contains "$out" 'usage: "bin/fm-convergence-scoreboard.sh <local-ref> <upstream-ref>"' \
    "usage failure should include the complete correction"
  [ -z "$err" ] || fail "usage failure leaked diagnostics to stderr: $err"

  set +e
  out=$(run_scoreboard "$repo" --unknown upstream 2>"$TMP_ROOT/unknown.err")
  rc=$?
  set -e
  expect_code 2 "$rc" "unknown flag"
  assert_contains "$out" 'error: "unknown flag or invalid local ref: --unknown"' \
    "unknown flag should be named"

  git -C "$repo" branch ambiguous local
  git -C "$repo" tag ambiguous local
  set +e
  out=$(run_scoreboard "$repo" ambiguous upstream 2>"$TMP_ROOT/ambiguous.err")
  rc=$?
  set -e
  err=$(cat "$TMP_ROOT/ambiguous.err")
  expect_code 1 "$rc" "ambiguous local ref"
  assert_contains "$out" 'error: "local ref name is ambiguous: ambiguous"' \
    "ambiguous local ref should fail instead of following Git ref precedence"
  assert_contains "$out" 'Use a fully qualified ref such as refs/heads/<name>' \
    "ambiguous local ref should provide the deterministic correction"
  [ -z "$err" ] || fail "ambiguous ref failure leaked diagnostics to stderr: $err"
  set +e
  out=$(
    cd "$repo" || exit 1
    GIT_CONFIG_PARAMETERS="'core.warnAmbiguousRefs'='false'" \
      "$SCOREBOARD" ambiguous upstream
  )
  rc=$?
  set -e
  expect_code 1 "$rc" "ambiguous local ref with warnings disabled"
  assert_contains "$out" 'error: "local ref name is ambiguous: ambiguous"' \
    "ambient warning configuration must not suppress ambiguity rejection"
  run_scoreboard "$repo" refs/heads/ambiguous upstream >/dev/null \
    || fail "fully qualified local ref did not resolve the reported ambiguity"

  git -C "$repo" branch ambiguous-upstream upstream
  git -C "$repo" tag ambiguous-upstream upstream
  set +e
  out=$(run_scoreboard "$repo" local ambiguous-upstream)
  rc=$?
  set -e
  expect_code 1 "$rc" "ambiguous upstream ref"
  assert_contains "$out" 'error: "upstream ref name is ambiguous: ambiguous-upstream"' \
    "ambiguous upstream ref should fail instead of following Git ref precedence"

  set +e
  out=$(run_scoreboard "$repo" missing upstream 2>"$TMP_ROOT/missing.err")
  rc=$?
  set -e
  expect_code 1 "$rc" "missing local ref"
  assert_contains "$out" 'local ref is missing, unfetched, or does not resolve to one commit: missing' \
    "missing local ref should be actionable"
  assert_contains "$out" 'Fetch or create the local ref explicitly' \
    "missing local ref should provide the correction"

  printf 'dirty\n' > "$repo/untracked.txt"
  set +e
  out=$(run_scoreboard "$repo" local upstream 2>"$TMP_ROOT/dirty.err")
  rc=$?
  set -e
  expect_code 1 "$rc" "dirty worktree"
  assert_contains "$out" 'error: "current worktree is dirty"' \
    "dirty invocation should fail before measuring refs"
  rm "$repo/untracked.txt"
  pass "scoreboard rejects missing, unknown, unfetched, and dirty invocation state"
}

test_diff_failure_is_not_silent() {
  local repo blob object_path backup out rc
  repo=$TMP_ROOT/repo
  blob=$(git -C "$repo" rev-parse upstream:docs/guide.md)
  object_path="$repo/.git/objects/${blob:0:2}/${blob:2}"
  backup="$TMP_ROOT/missing-blob.backup"
  [ -f "$object_path" ] || fail "diff failure fixture blob is not loose"
  mv "$object_path" "$backup"

  set +e
  out=$(run_scoreboard "$repo" local upstream)
  rc=$?
  set -e

  mv "$backup" "$object_path"
  expect_code 1 "$rc" "unavailable diff object"
  assert_contains "$out" 'error: "cannot calculate diff metrics between the resolved refs"' \
    "a failed diff must not produce plausible zero metrics"
  assert_contains "$out" 'Verify that all repository objects are available locally' \
    "a failed diff should provide the deterministic correction"
  pass "scoreboard fails loudly when resolved commits cannot produce diff metrics"
}

test_toon_documents_have_no_trailing_newline() {
  local repo rc
  repo=$TMP_ROOT/repo

  run_scoreboard "$repo" local upstream > "$TMP_ROOT/success.toon"
  assert_no_trailing_newline "$TMP_ROOT/success.toon" "success output"

  run_scoreboard "$repo" --help > "$TMP_ROOT/help.toon"
  assert_no_trailing_newline "$TMP_ROOT/help.toon" "help output"

  set +e
  run_scoreboard "$repo" > "$TMP_ROOT/usage-error.toon"
  rc=$?
  set -e
  expect_code 2 "$rc" "usage output"
  assert_no_trailing_newline "$TMP_ROOT/usage-error.toon" "usage error output"

  set +e
  run_scoreboard "$repo" missing upstream > "$TMP_ROOT/measure-error.toon"
  rc=$?
  set -e
  expect_code 1 "$rc" "measurement error output"
  assert_no_trailing_newline "$TMP_ROOT/measure-error.toon" "measurement error output"
  pass "scoreboard emits every TOON document without a trailing newline"
}

test_help_without_home() {
  local out err rc

  set +e
  out=$(env -u HOME "$SCOREBOARD" --help 2>"$TMP_ROOT/help-unset-home.err")
  rc=$?
  set -e
  err=$(cat "$TMP_ROOT/help-unset-home.err")

  expect_code 0 "$rc" "help without HOME"
  assert_contains "$out" "bin: \"$SCOREBOARD\"" \
    "help without HOME should report the absolute executable path"
  [ -z "$err" ] || fail "help without HOME leaked diagnostics to stderr: $err"
  pass "scoreboard help is deterministic when HOME is unset"
}

test_toon_control_characters_are_escaped() {
  local repo control_ref out rc
  repo=$TMP_ROOT/repo
  control_ref=$'missing\001\b\f\033\177ref'

  set +e
  out=$(run_scoreboard "$repo" "$control_ref" upstream)
  rc=$?
  set -e

  expect_code 1 "$rc" "control characters in a missing ref"
  assert_contains "$out" 'missing\u0001\u0008\u000c\u001b\u007fref' \
    "structured errors should escape non-short-form TOON control characters"
  [[ "$out" != *$'\001'* && "$out" != *$'\b'* && "$out" != *$'\f'* \
    && "$out" != *$'\033'* && "$out" != *$'\177'* ]] \
    || fail "structured error output retained a raw control character"
  pass "scoreboard escapes every unsupported control character in TOON strings"
}

test_deterministic_scoreboard
test_attributes_are_scoped_to_local_ref
test_tab_prefixed_path_is_not_documentation
test_git_environment_is_allowlisted
test_fail_closed_invocation
test_diff_failure_is_not_silent
test_toon_documents_have_no_trailing_newline
test_help_without_home
test_toon_control_characters_are_escaped
