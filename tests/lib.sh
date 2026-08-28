#!/usr/bin/env bash
# tests/lib.sh - shared primitives for firstmate behavior tests.
#
# Source this from a test file:
#   # shellcheck source=tests/lib.sh
#   . "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
#
# It provides the boilerplate every test file used to re-roll: ok/not-ok
# reporters, a self-cleaning temp root, fakebin/PATH-shim helpers, deterministic
# git identity and fixture builders, state/<id>.meta writers, and the common
# string/exit-code/file assertions. It deliberately does NOT bundle the
# behavior-specific fake tmux/treehouse/no-mistakes mocks: those encode terminal
# and lifecycle assumptions that differ per suite and belong with the tests that
# own them.
#
# ROOT is exported as the firstmate repo root (this file lives in tests/), so a
# sourcing test can use "$ROOT/bin/..." without recomputing it.

# Idempotent guard: behavior-area helper files (secondmate-helpers.sh,
# wake-helpers.sh) source this library for ROOT/fail/pass, and the test that
# includes them may also source it directly. Re-sourcing must not wipe the
# registered-cleanup array or reset state.
if [ -n "${FM_TEST_LIB_SOURCED:-}" ]; then
  return 0
fi
FM_TEST_LIB_SOURCED=1

# Exempt firstmate's own test suite from the gate-lifecycle refusal
# (bin/fm-gate-refuse-lib.sh). The no-mistakes gate runs this suite FROM a gate
# worktree - the exact environment that guard refuses - so without this every
# test that drives the real fm-spawn/fm-send/fm-teardown would be refused during
# firstmate's own validation. A confused gate agent never sources this helper, so
# the boundary against the real hazard is unaffected. tests/fm-gate-refuse.test.sh
# strips this to verify real refusal.
export FM_GATE_REFUSE_BYPASS=1

# Resolve the repo root from this library's own location. Consumed by sourcing
# test files, not by this library, so it reads as "unused" here.
# shellcheck disable=SC2034
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- reporters --------------------------------------------------------------

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

# --- self-cleaning temp root ------------------------------------------------
#
# fm_test_tmproot <prefix> echoes a fresh temp dir and registers it for removal
# on EXIT/INT/TERM. A test file that needs extra teardown (e.g. killing a
# daemon) should define its own EXIT trap and call fm_test_cleanup from inside
# it so registered dirs are still removed.
#
# The call site is almost always `TMP_ROOT=$(fm_test_tmproot prefix)`, which
# forks a subshell to capture stdout. Anything that function does to the
# current shell's state - an array append, a trap - dies with that subshell
# and never reaches the real caller, so registration cannot go through
# in-process state. `$$` is the one thing bash keeps stable across that
# boundary (it always resolves to the invoking shell's PID, not the
# subshell's - see `man bash` on `$$`), so fm_test_tmproot records the
# directory in a `$$`-keyed registry file instead, and the trap that reaps
# that file is armed once, here, at source time - which always runs in the
# real caller, never a subshell.

FM_TEST_CLEANUP_DIRS=()
FM_TEST_CLEANUP_REGISTRY=$(mktemp "${TMPDIR:-/tmp}/.fm-test-cleanup.$$.XXXXXX") || return 1

fm_test_pid_identity() {
  local pid=$1
  FM_STATE_OVERRIDE="${TMPDIR:-/tmp}" bash -c \
    '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$pid"
}

FM_TEST_OWNER_IDENTITY=$(fm_test_pid_identity "$$") || {
  rm -f "$FM_TEST_CLEANUP_REGISTRY"
  return 1
}

fm_test_cleanup() {
  local d
  for d in "${FM_TEST_CLEANUP_DIRS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
  if [ -f "$FM_TEST_CLEANUP_REGISTRY" ]; then
    while IFS= read -r d; do
      [ -n "$d" ] && rm -rf "$d"
    done < "$FM_TEST_CLEANUP_REGISTRY"
    rm -f "$FM_TEST_CLEANUP_REGISTRY"
  fi
}

fm_test_tmproot() {
  local prefix=${1:-fm-test} root
  root=$(mktemp -d "${TMPDIR:-/tmp}/${prefix}.XXXXXX") || return 1
  if ! printf '%s\n%s\n' "$$" "$FM_TEST_OWNER_IDENTITY" > "$root/.fm-test-fixture" ||
    ! printf '%s\n' "$root" >> "$FM_TEST_CLEANUP_REGISTRY"; then
    rm -rf "$root"
    return 1
  fi
  printf '%s\n' "$root"
}

trap fm_test_cleanup EXIT
trap 'fm_test_cleanup; exit 130' INT
trap 'fm_test_cleanup; exit 143' TERM

# fm_test_reap_orphans: best-effort sweep for fixture roots left behind by a
# prior run that was killed hard enough to skip the traps above (e.g. a
# SIGKILL timeout). Only removes directories carrying the .fm-test-fixture
# marker fm_test_tmproot writes, so it never touches unrelated fm-* tmp dirs
# from real (non-test) firstmate commands. The marker identifies the owning
# shell across PID reuse, so the same live owner always wins over the age
# fallback for dead or unowned roots.
FM_TEST_ORPHAN_MAX_AGE_SECONDS=${FM_TEST_ORPHAN_MAX_AGE_SECONDS:-3600}

fm_test_reap_orphans() {
  local marker dir mtime now owner_pid owner_identity current_identity
  now=$(date +%s)
  for marker in "${TMPDIR:-/tmp}"/fm-*/.fm-test-fixture; do
    [ -e "$marker" ] || continue
    owner_pid=$(sed -n '1p' "$marker" 2>/dev/null) || owner_pid=
    owner_identity=$(sed -n '2,$p' "$marker" 2>/dev/null) || owner_identity=
    case "$owner_pid" in
      '' | *[!0-9]*) ;;
      *)
        current_identity=$(fm_test_pid_identity "$owner_pid" 2>/dev/null) || current_identity=
        if [ -n "$owner_identity" ] && [ "$current_identity" = "$owner_identity" ]; then
          continue
        fi
        ;;
    esac
    mtime=$(stat -c %Y "$marker" 2>/dev/null || stat -f %m "$marker" 2>/dev/null) || continue
    [ $((now - mtime)) -ge "$FM_TEST_ORPHAN_MAX_AGE_SECONDS" ] || continue
    dir=$(dirname "$marker")
    rm -rf "$dir"
  done
}

fm_test_reap_orphans

# --- fakebin / PATH shims ---------------------------------------------------
#
# fm_fakebin <dir> creates <dir>/fakebin and echoes it; prepend it to PATH to
# shadow real tools with stubs. fm_fake_exit0 drops trivial exit-0 stubs for the
# named tools into a fakebin dir. fm_fake_version_tool drops a stub for a tool
# whose installed version bootstrap gates, so a fixture cannot be reported as an
# unparseable build simply for answering `--version` with nothing.

fm_fakebin() {
  local dir=$1 fakebin="$1/fakebin"
  mkdir -p "$fakebin"
  printf '%s\n' "$fakebin"
}

fm_fake_exit0() {
  local fakebin=$1 tool
  shift
  for tool in "$@"; do
    cat > "$fakebin/$tool" <<'SH'
#!/usr/bin/env bash
exit 0
SH
    chmod +x "$fakebin/$tool"
  done
}

# fm_fake_version_tool <fakebin> <tool> <override-env-var> <default-version>
# The stub answers `--version` with <override-env-var> when that variable is set
# and non-empty, and with <default-version> otherwise; every other invocation
# exits 0. A case that needs to drive a version floor exports the variable.
fm_fake_version_tool() {
  local fakebin=$1 tool=$2 override=$3 default=$4
  cat > "$fakebin/$tool" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = --version ]; then
  printf '%s\n' "\${$override:-$default}"
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/$tool"
}

# --- deterministic git identity and fixtures --------------------------------

# fm_git_identity [name] [email]: export a fixed author/committer identity so
# fixture commits never depend on the host git config.
fm_git_identity() {
  export GIT_AUTHOR_NAME=${1:-fmtest} GIT_AUTHOR_EMAIL=${2:-fmtest@example.invalid}
  export GIT_COMMITTER_NAME=$GIT_AUTHOR_NAME GIT_COMMITTER_EMAIL=$GIT_AUTHOR_EMAIL
}

# fm_git_init_commit <dir>: create a git repo at <dir> with a README and one
# commit. Uses an inline identity so it works whether or not fm_git_identity was
# called.
fm_git_init_commit() {
  local dir=$1
  mkdir -p "$dir"
  git -C "$dir" init -q
  printf '# %s\n' "$(basename "$dir")" > "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
}

# fm_git_add_origin <repo> <bare>: clone <repo> bare into <bare> and register it
# as <repo>'s origin via a file:// URL (so later clones resolve an absolute path).
fm_git_add_origin() {
  local repo=$1 remote=$2 remote_abs
  git clone --quiet --bare "$repo" "$remote"
  remote_abs=$(cd "$remote" && pwd)
  git -C "$repo" remote add origin "file://$remote_abs"
}

# fm_git_worktree <repo> <worktree> <branch>: initialize <repo> with one commit
# and a local bare origin, then add a worktree on a fresh branch.
fm_git_worktree() {
  local repo=$1 worktree=$2 branch=$3
  fm_git_init_commit "$repo"
  fm_git_add_origin "$repo" "$repo.origin.git"
  git -C "$repo" worktree add --quiet -b "$branch" "$worktree"
}

# --- state/<id>.meta writers ------------------------------------------------

# fm_write_meta <file> <key=val> ...: write the given key=val lines to a meta
# file (truncating any prior content).
fm_write_meta() {
  local file=$1 kv
  shift
  : > "$file"
  for kv in "$@"; do
    printf '%s\n' "$kv" >> "$file"
  done
}

# fm_write_secondmate_meta <file> <home> [window] [projects] [harness]: write the
# standard kind=secondmate meta block used across the secondmate suites. Window
# defaults to firstmate:fm-<id>, projects defaults to alpha, and harness defaults
# to echo to match the common case.
fm_write_secondmate_meta() {
  local file=$1 home=$2 id window projects=${4:-alpha} harness=${5:-echo}
  id=$(basename "$file" .meta)
  window=${3:-firstmate:fm-$id}
  fm_write_meta "$file" \
    "window=$window" \
    "endpoint_task_id=$id" \
    "worktree=$home" \
    "project=$home" \
    "harness=$harness" \
    "kind=secondmate" \
    "mode=secondmate" \
    "yolo=off" \
    "home=$home" \
    "projects=$projects"
}

# --- common assertions ------------------------------------------------------

# assert_contains <haystack> <needle> <msg>
assert_contains() {
  case "$1" in
    *"$2"*) : ;;
    *) fail "$3 (missing: '$2')"$'\n'"--- output ---"$'\n'"$1" ;;
  esac
}

# assert_not_contains <haystack> <needle> <msg>
assert_not_contains() {
  case "$1" in
    *"$2"*) fail "$3 (unexpected: '$2')"$'\n'"--- output ---"$'\n'"$1" ;;
    *) : ;;
  esac
}

# expect_code <expected> <actual> <label>
expect_code() {
  local expected=$1 actual=$2 label=$3
  [ "$actual" = "$expected" ] || fail "$label: expected exit $expected, got $actual"
}

# assert_grep <pattern> <file> <msg>: fixed-string grep must match in <file>.
# `--` guards patterns that begin with '-' (e.g. backlog/registry lines).
assert_grep() {
  grep -F -- "$1" "$2" >/dev/null || fail "$3"
}

# assert_no_grep <pattern> <file> <msg>: fixed-string grep must NOT match.
assert_no_grep() {
  ! grep -F -- "$1" "$2" >/dev/null || fail "$3"
}

# assert_absent <path> <msg>: path must not exist.
assert_absent() {
  [ ! -e "$1" ] || fail "$2"
}

# assert_present <path> <msg>: path must exist.
assert_present() {
  [ -e "$1" ] || fail "$2"
}

# Build the same policy/request/candidate/decision evidence a routed caller must
# produce, then reserve the exact selected tuple. Test-only serialization keeps
# concurrent cap tests from racing their shared policy fixture.
fm_test_reserve_bound() {
  local root=$1 home=$2 state=$3 task=$4 generation=$5 profile=$6 provider=$7 lane=$8 account=$9
  local task_class=${10} work_type=${11} risk=${12} mode=${13} harness=${14} model=${15} effort=${16} now=${17}
  shift 17
  local config="$home/config/crew-dispatch.json" evidence="$home/.test-route-evidence/$task-$generation-$profile-$provider-$lane-$account-$task_class-$work_type-$risk-$mode" lock="$home/.test-policy.lock"
  local policy_tmp profile_json
  mkdir -p "$home/config" "$evidence"
  while ! mkdir "$lock" 2>/dev/null; do :; done
  if [ -s "$config" ] && jq -e '.schemaVersion == 2' "$config" >/dev/null 2>&1; then
    profile_json=$(jq -cn --arg harness "$harness" --arg model "$model" --arg provider "$provider" \
      --arg lane "$lane" --arg account "$account" --arg workType "$work_type" --arg effort "$effort" '
      {harness:$harness,model:$model,provider:$provider,lane:$lane,reasoningClass:"strong",workTypes:[$workType]}
      + (if ($harness == "claude" or $harness == "codex") then {account:$account} else {} end)
      + (if $effort == "none" then {} else {effort:$effort} end)')
    if ! jq -e --arg mode "$mode" --arg profile "$profile" --argjson value "$profile_json" \
      '(.routing.mode // "automatic") == $mode and .profiles[$profile] == $value' "$config" >/dev/null; then
      policy_tmp=$(mktemp "$home/config/.policy.XXXXXX")
      jq --arg mode "$mode" --arg profile "$profile" --argjson value "$profile_json" \
        '.routing.mode=$mode | .profiles[$profile]=$value | .default=([.default[]? | select(. != $profile)] + [$profile])' \
        "$config" >"$policy_tmp" && mv "$policy_tmp" "$config"
    fi
  else
    profile_json=$(jq -cn --arg harness "$harness" --arg model "$model" --arg provider "$provider" \
      --arg lane "$lane" --arg account "$account" --arg workType "$work_type" --arg effort "$effort" '
      {harness:$harness,model:$model,provider:$provider,lane:$lane,reasoningClass:"strong",workTypes:[$workType]}
      + (if ($harness == "claude" or $harness == "codex") then {account:$account} else {} end)
      + (if $effort == "none" then {} else {effort:$effort} end)')
    jq -n --arg mode "$mode" --arg profile "$profile" --argjson value "$profile_json" \
      '{schemaVersion:2,routing:{mode:$mode},profiles:{($profile):$value},default:[$profile]}' >"$config"
  fi
  rmdir "$lock"
  if [ ! -s "$evidence/decision.json" ]; then
    jq -n --arg task "$task" --arg class "$task_class" --arg workType "$work_type" --arg risk "$risk" \
      '{taskId:$task,taskClass:$class,workType:$workType,risk:$risk,independent:false,requestedWorkers:1,requiredReasoningClass:"strong",estimatedSeconds:60}' >"$evidence/request.json"
    jq -n --arg profile "$profile" --arg harness "$harness" --arg model "$model" --arg provider "$provider" \
      --arg lane "$lane" --arg account "$account" \
      '[{profile:$profile,harness:$harness,model:$model,provider:$provider,lane:$lane,account:$account,fitTier:3,reasoningClass:"strong",catalogSupported:true,authState:"usable",spendPriority:1,runwaySeconds:1000,activeLane:0,historySuccesses:0,historyAttempts:0,costTier:1}]' >"$evidence/candidates.json"
    FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$root/bin/fm-route.sh" select \
      --request "$evidence/request.json" --candidates "$evidence/candidates.json" --now "$now" >"$evidence/decision.json" || return 1
  fi
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$root/bin/fm-route.sh" reserve \
    --task "$task" --generation "$generation" --profile "$profile" --provider "$provider" --lane "$lane" \
    --account "$account" --class "$task_class" --work-type "$work_type" --risk "$risk" --mode "$mode" \
    --request "$evidence/request.json" --candidates "$evidence/candidates.json" --decision "$evidence/decision.json" \
    --now "$now" "$@"
}
# fm_test_path_without <dir> <name...>: build a private PATH directory that
# exposes the host's ordinary executables except for explicitly absent tools.
# Missing-tool fixtures use this instead of appending /usr/bin or /bin, where a
# developer workstation may have the very dependency the fixture removes.
fm_test_path_without() {
  local target=$1 source_path=${FM_TEST_BASE_PATH:-$PATH} dir candidate name excluded excluded_name
  shift
  mkdir -p "$target"
  while IFS= read -r dir; do
    [ -d "$dir" ] || continue
    for candidate in "$dir"/*; do
      [ -f "$candidate" ] && [ -x "$candidate" ] || continue
      name=${candidate##*/}
      excluded=0
      for excluded_name in "$@"; do
        if [ "$name" = "$excluded_name" ]; then
          excluded=1
          break
        fi
      done
      [ "$excluded" -eq 0 ] || continue
      [ -e "$target/$name" ] || ln -s "$candidate" "$target/$name"
    done
  done <<EOF
$(printf '%s' "$source_path" | tr ':' '\n')
EOF
  printf '%s\n' "$target"
}
