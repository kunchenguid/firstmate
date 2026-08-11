#!/usr/bin/env bash
# Manage the strict opt-in Fast Repair delivery path.
# Usage:
#   fm-fast-repair.sh is-request <request>
#   fm-fast-repair.sh intake <task-id> --request 'fast-repair: <task>' \
#     --reproduction reproduced --reproduction-revision <commit> --root-cause confirmed --isolation isolated \
#     --schema none --authentication none --authorization none --secrets none \
#     --financial none --legal none --side-effects none
#   fm-fast-repair.sh eligible <task-id> [--worktree <path>]
#   fm-fast-repair.sh evidence <task-id> --regression-test <runner-family> --focused-test <runner-family>
#   fm-fast-repair.sh publish-pr <task-id> --title <text> --body-file <path> [--base <branch>] [--head <branch>]
#   fm-fast-repair.sh broader <task-id> --test <runner-family>
#   fm-fast-repair.sh progress <task-id> [--local-only]
#   fm-fast-repair.sh ready <task-id>
#
# `fast-repair:` is the only accepted request prefix, and it must be followed by
# one space and a non-empty request. `intake` records a typed, private evidence
# record only when all three positive facts use their exact proof values and all
# seven risk exclusions equal `none`. Any missing or different value
# refuses Fast Repair before a task can use this delivery mode; firstmate then
# uses normal intake for that request.
#
# A Fast Repair spawn must use mode=fast-repair, yolo=off, and the built-in
# Codex gpt-5.6-luna medium profile. `evidence` executes named regression and
# focused-module runner families through the supported test runner and records
# their result. `publish-pr` refuses
# until both passed, then opens and registers a direct PR. `broader` is run
# after publication while PR checks run concurrently, and its family must differ
# from the focused family already proven before the PR. `ready` refuses until the
# broader test family and all PR checks are green. `progress` prints only a changed
# actionable state for the watcher's Fast-Repair-only cadence. `progress
# --local-only` reads just this home's own broader-test record and never contacts
# the forge, so the watcher can keep following a still-running broader family
# after it has stopped polling PR checks.
#
# `eligible --worktree` is the dispatch-time gate, so it proves only what exists
# before the crewmate branches and commits: a clean worktree of the task's own
# repository whose history already holds the recorded reproduction commit. The
# `fm/<id>` branch binding and the strictly-older reproduction revision are
# proofs about the tested head and are enforced by every gate after dispatch.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
TASK_WORKTREE=
TASK_BRANCH=
TASK_HEAD=
TEST_RUNNER=
TEST_RUNNER_ARTIFACT=
REPRODUCTION_REVISION=
REGRESSION_SELECTOR=
REGRESSION_ARTIFACT=
BODY_FILE=
FAST_REPAIR_TMP_SANDBOX=
FAST_REPAIR_TMP_OUTPUT=

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

# The two temporaries this script creates are anonymous - a mkstemp suffix with
# no task id - so teardown's per-task globs can never reclaim them, and the
# reproduction sandbox is a full object copy of the project. Both are therefore
# owned here for the whole life of the process: whichever one is live when the
# run ends, however it ends, is removed.
fast_repair_temp_cleanup() {
  local sandbox=$FAST_REPAIR_TMP_SANDBOX output=$FAST_REPAIR_TMP_OUTPUT
  FAST_REPAIR_TMP_SANDBOX=
  FAST_REPAIR_TMP_OUTPUT=
  [ -z "$output" ] || rm -f "$output" || true
  [ -z "$sandbox" ] || rm -rf "$sandbox" || true
  return 0
}

# The single owner of retiring the reproduction sandbox, so every exit path of
# the witness both removes the clone and drops it from the cleanup handler.
fast_repair_sandbox_remove() {
  local sandbox=$FAST_REPAIR_TMP_SANDBOX
  FAST_REPAIR_TMP_SANDBOX=
  [ -z "$sandbox" ] || rm -rf "$sandbox" || true
  return 0
}

# Re-raise with the default disposition so callers still read a killed-by-signal
# wait status rather than a plain exit code.
fast_repair_signal_cleanup() { # <signal>
  local sig=$1
  fast_repair_temp_cleanup
  trap - EXIT "$sig"
  kill -s "$sig" $$ 2>/dev/null || exit 1
  exit 1
}

trap fast_repair_temp_cleanup EXIT
trap 'fast_repair_signal_cleanup HUP' HUP
trap 'fast_repair_signal_cleanup INT' INT
trap 'fast_repair_signal_cleanup TERM' TERM

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

fail() {
  printf 'fast-repair refused: %s\n' "$*" >&2
  exit 2
}

task_id_valid() {
  fm_task_id_creation_valid "$1"
}

regular_file() {
  [ -f "$1" ] && [ ! -L "$1" ]
}

task_worktree_for() {
  local meta worktree root
  meta="$STATE/$1.meta"
  regular_file "$meta" || return 1
  worktree=$(field_get "$meta" worktree)
  [ -n "$worktree" ] && [ -d "$worktree" ] || return 1
  root=$(git -C "$worktree" rev-parse --show-toplevel 2>/dev/null) || return 1
  root=$(cd "$root" && pwd -P) || return 1
  [ "$root" = "$(cd "$worktree" && pwd -P)" ] || return 1
  TASK_WORKTREE=$root
}

task_revision_for() {
  task_worktree_for "$1" || return 1
  task_revision_at_worktree "$TASK_WORKTREE"
}

task_worktree_clean() { # <worktree>
  local worktree=$1 path rel output
  local paths=(.)
  for path in "$STATE" "$DATA"; do
    case "$path" in
      "$worktree"/*)
        rel=${path#"$worktree"/}
        paths+=(":(exclude,top)$rel")
        ;;
    esac
  done
  output=$(git -C "$worktree" status --porcelain=v1 --untracked-files=all -- "${paths[@]}" 2>/dev/null) || return 1
  [ -z "$output" ]
}

# The identity every Fast Repair gate needs: the path is a real git worktree
# root, its HEAD resolves, and nothing outside this home's own state and data is
# modified. TASK_BRANCH is left empty on a detached HEAD, which is exactly the
# state firstmate hands a freshly pooled task worktree before the crewmate has
# created its `fm/<id>` branch.
task_head_at_worktree() {
  local worktree=$1 root
  [ -d "$worktree" ] || return 1
  root=$(git -C "$worktree" rev-parse --show-toplevel 2>/dev/null) || return 1
  root=$(cd "$root" && pwd -P) || return 1
  [ "$root" = "$(cd "$worktree" && pwd -P)" ] || return 1
  TASK_WORKTREE=$root
  TASK_BRANCH=$(git -C "$TASK_WORKTREE" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  TASK_HEAD=$(git -C "$TASK_WORKTREE" rev-parse --verify HEAD 2>/dev/null) || return 1
  task_worktree_clean "$TASK_WORKTREE"
}

# The tested-head identity: everything above plus the named branch every
# evidence, publication, broader, and readiness record binds itself to. A
# detached HEAD carries no branch to bind, so it is refused here.
task_revision_at_worktree() {
  task_head_at_worktree "$1" || return 1
  [ -n "$TASK_BRANCH" ] || return 1
}

# Evidence logs and records are private to this home. The umask is scoped to the
# creation itself so it never reaches the caller-supplied test commands, whose
# own output files must keep the permissions their build or suite intends.
private_truncate() { # <path>
  ( umask 077; : > "$1" ) && chmod 600 "$1"
}

private_write() { # <path>, content on stdin
  ( umask 077; cat > "$1" ) && chmod 600 "$1"
}

field_get() { # <file> <field>
  sed -n "s/^$2=//p" "$1" | head -n 1
}

request_valid() {
  case "$1" in
    fast-repair:\ ?*) ;;
    *) return 1 ;;
  esac
  case "$1" in *$'\n'*|*$'\r'*) return 1 ;; esac
  case "${1#fast-repair: }" in
    *[![:space:]]*) ;;
    *) return 1 ;;
  esac
}

# The one rule for a proven positive fact and for an excluded risk. intake
# writes a record only when these hold, and every later gate re-checks the
# stored record against these same predicates, so a record can never satisfy a
# consumer that intake itself would have refused.
positive_fact_valid() { # <field> <value>
  case "$1:$2" in
    reproduction:reproduced|root_cause:confirmed|isolation:isolated) return 0 ;;
    *) return 1 ;;
  esac
}

risk_excluded() { [ "$1" = none ]; }

test_runner_valid() {
  local parent resolved rel=bin/fm-test-run.sh artifact
  [ -n "$TASK_WORKTREE" ] || return 1
  parent=$(dirname "$TASK_WORKTREE/$rel")
  resolved=$(cd "$parent" 2>/dev/null && pwd -P) || return 1
  resolved="$resolved/$(basename "$rel")"
  [ "$resolved" = "$TASK_WORKTREE/$rel" ] || return 1
  regular_file "$resolved" && [ -x "$resolved" ] || return 1
  [ "$(git -C "$TASK_WORKTREE" cat-file -t "$TASK_HEAD:$rel" 2>/dev/null || true)" = blob ] || return 1
  git -C "$TASK_WORKTREE" diff --no-ext-diff --quiet "$TASK_HEAD" -- ":(literal)$rel" || return 1
  artifact=$(git -C "$TASK_WORKTREE" ls-tree "$TASK_HEAD" -- "$rel" 2>/dev/null | awk '{print $1 ":" $2 ":" $3}') || return 1
  case "$artifact" in 100755:blob:*) ;; *) return 1 ;; esac
  TEST_RUNNER=$resolved
  TEST_RUNNER_ARTIFACT="${artifact%%:blob:*}:${artifact#*:blob:}"
}

runner_family_valid() {
  local family=$1
  case "$family" in ''|*[!A-Za-z0-9_-]*|*'--'*) return 1 ;; esac
  test_runner_valid || return 1
  "$TEST_RUNNER" --list-families 2>/dev/null | grep -Fx "$family" >/dev/null
}

# One shape for one concept: a commit id here is the same identity the forge
# validator already owns, so SHA-1 and SHA-256 object formats are both accepted.
reproduction_revision_valid() {
  fm_pr_head_valid "${1-}"
}

# What is knowable before the repair commit exists: the recorded revision is a
# real commit in this worktree's own history at or below its HEAD. A task
# worktree that has just been pooled sits exactly at the reproduction commit, so
# the ancestry here is inclusive.
reproduction_revision_recorded() {
  local id=$1 revision
  revision=$(field_get "$(eligibility_file "$id")" reproduction_revision)
  reproduction_revision_valid "$revision" || return 1
  git -C "$TASK_WORKTREE" cat-file -e "$revision^{commit}" 2>/dev/null || return 1
  git -C "$TASK_WORKTREE" merge-base --is-ancestor "$revision" "$TASK_HEAD" || return 1
  REPRODUCTION_REVISION=$revision
}

# The tested-head proof: the repair itself must sit above the reproduction, so
# the recorded revision can no longer be the commit being tested. Only gates
# that run after the repair commit exists may require this.
reproduction_revision_for() {
  reproduction_revision_recorded "$1" || return 1
  [ "$REPRODUCTION_REVISION" != "$TASK_HEAD" ] || return 1
}

runner_selected_tests() { # <family>
  "$TEST_RUNNER" --list --family "$1" 2>/dev/null
}

runner_selected_test_valid() { # <path>
  local path=$1 parent resolved
  case "$path" in tests/*.test.sh) ;; *) return 1 ;; esac
  parent=$(dirname "$TASK_WORKTREE/$path")
  resolved=$(cd "$parent" 2>/dev/null && pwd -P) || return 1
  resolved="$resolved/$(basename "$path")"
  [ "$resolved" = "$TASK_WORKTREE/$path" ] || return 1
  regular_file "$resolved" || return 1
  [ "$(git -C "$TASK_WORKTREE" cat-file -t "$TASK_HEAD:$path" 2>/dev/null || true)" = blob ] || return 1
  git -C "$TASK_WORKTREE" diff --no-ext-diff --quiet "$TASK_HEAD" -- ":(literal)$path" || return 1
}

regression_test_valid() { # <task-id> <family>
  local id=$1 family=$2 selected path artifact new_count=0
  runner_family_valid "$family" || return 1
  reproduction_revision_for "$id" || return 1
  selected=$(runner_selected_tests "$family") || return 1
  [ -n "$selected" ] || return 1
  REGRESSION_SELECTOR=
  REGRESSION_ARTIFACT=
  while IFS= read -r path; do
    [ -n "$path" ] || return 1
    runner_selected_test_valid "$path" || return 1
    git -C "$TASK_WORKTREE" cat-file -e "$REPRODUCTION_REVISION:$path" 2>/dev/null && continue
    artifact=$(git -C "$TASK_WORKTREE" ls-tree "$TASK_HEAD" -- "$path" 2>/dev/null | awk '{print $1 ":" $2 ":" $3}') || return 1
    case "$artifact" in 100755:blob:*) ;; *) return 1 ;; esac
    new_count=$((new_count + 1))
    REGRESSION_SELECTOR=$path
    REGRESSION_ARTIFACT="${artifact%%:blob:*}:${artifact#*:blob:}"
  done <<EOF
$selected
EOF
  [ "$new_count" -eq 1 ]
}

runner_family_artifacts_valid() { # <family>
  local selected path
  runner_family_valid "$1" || return 1
  selected=$(runner_selected_tests "$1") || return 1
  [ -n "$selected" ] || return 1
  while IFS= read -r path; do
    [ -n "$path" ] || return 1
    runner_selected_test_valid "$path" || return 1
  done <<EOF
$selected
EOF
}

focused_test_valid() { runner_family_artifacts_valid "$1"; }

recorded_focused_test() { # <task-id>
  local f
  f=$(tests_file "$1")
  regular_file "$f" || return 1
  field_get "$f" focused_test
}

# "Broader" is a coverage claim, not a second run of the module the early PR was
# already published on. The family must be supported with bound artifacts AND
# different from the focused family recorded in the evidence record, and every
# later consumer of the broader record re-checks that same rule.
broader_test_valid() { # <task-id> <family>
  local id=$1 family=$2 focused
  runner_family_artifacts_valid "$family" || return 1
  focused=$(recorded_focused_test "$id") || return 1
  [ -n "$focused" ] || return 1
  [ "$family" != "$focused" ]
}

# The one owner of how a runner invocation is classified. Every Fast Repair
# gate - the reproduction witness, the regression run at the tested head, the
# focused family, and the broader family - differs only in the argv it hands the
# tracked runner, so the typed begin/end, skip, and exit rules live here once.
run_typed() { # <worktree> <pass|fail> <log> <runner-arg>...
  local worktree=$1 expected=$2 log=$3 output status
  shift 3
  output=$(mktemp "$STATE/.fast-repair-test-output.XXXXXX") || return 1
  FAST_REPAIR_TMP_OUTPUT=$output
  chmod 600 "$output" || { rm -f "$output"; FAST_REPAIR_TMP_OUTPUT=; return 1; }
  if ( cd "$worktree" && "$worktree/bin/fm-test-run.sh" "$@" ) >"$output" 2>&1; then
    status=0
  else
    status=1
  fi
  cat "$output" >> "$log" || status=1
  if awk -v expected="$expected" -v status="$status" '
      $1 == "FM_TEST_BEGIN" { began = 1 }
      $1 == "FM_TEST_END" && $0 ~ /(^|[[:space:]])gate_skip=true([[:space:]]|$)/ { skipped = 1 }
      $1 == "FM_TEST_END" && $4 == "exit=0" { passed = 1 }
      $1 == "FM_TEST_END" && $4 != "exit=0" { failed = 1 }
      END {
        if (expected == "pass") exit !(status == 0 && began && passed && !skipped)
        exit !(status != 0 && began && failed && !skipped)
      }
    ' "$output"; then
    rm -f "$output"
    FAST_REPAIR_TMP_OUTPUT=
    return 0
  fi
  rm -f "$output"
  FAST_REPAIR_TMP_OUTPUT=
  return 1
}

run_typed_test() { # <worktree> <family> <pass|fail> <log>
  run_typed "$1" "$3" "$4" --family "$2"
}

run_typed_selector() { # <worktree> <selector> <pass|fail> <log>
  run_typed "$1" "$3" "$4" "$2"
}

regression_witness_valid() { # <family> <selector> <artifact> <log>
  local family=$1 selector=$2 artifact=$3 log=$4 sandbox sandbox_root parent resolved component target mode file_mode oid runner_oid selected
  local components=()
  case "$artifact" in 100755:*) ;; *) return 1 ;; esac
  mode=${artifact%%:*}
  file_mode=${mode#100}
  oid=${artifact#*:}
  sandbox=$(mktemp -d "$STATE/.fast-repair-reproduction.XXXXXX") || return 1
  FAST_REPAIR_TMP_SANDBOX=$sandbox
  rmdir "$sandbox" || { fast_repair_sandbox_remove; return 1; }
  if ! git clone --quiet --no-hardlinks "$TASK_WORKTREE" "$sandbox" \
    || ! git -C "$sandbox" checkout --quiet --detach "$REPRODUCTION_REVISION"; then
    fast_repair_sandbox_remove
    return 1
  fi
  sandbox_root=$(cd "$sandbox" && pwd -P) || { fast_repair_sandbox_remove; return 1; }
  for parent in "$(dirname "$selector")" bin; do
    target=$sandbox
    IFS=/ read -r -a components <<< "$parent"
    for component in "${components[@]+"${components[@]}"}"; do
      [ -n "$component" ] || continue
      target="$target/$component"
      [ -e "$target" ] || mkdir "$target" || { fast_repair_sandbox_remove; return 1; }
      resolved=$(cd "$target" && pwd -P) || { fast_repair_sandbox_remove; return 1; }
      case "$resolved" in "$sandbox_root"|"$sandbox_root"/*) ;; *) fast_repair_sandbox_remove; return 1 ;; esac
    done
  done
  runner_oid=${TEST_RUNNER_ARTIFACT#*:}
  if ! git -C "$TASK_WORKTREE" show "$TASK_HEAD:bin/fm-test-run.sh" > "$sandbox/bin/fm-test-run.sh" \
    || ! chmod 755 "$sandbox/bin/fm-test-run.sh" \
    || ! [ "$(git -C "$sandbox" hash-object bin/fm-test-run.sh)" = "$runner_oid" ] \
    || ! git -C "$TASK_WORKTREE" show "$TASK_HEAD:$selector" > "$sandbox/$selector" \
    || ! chmod "$file_mode" "$sandbox/$selector" \
    || ! [ "$(git -C "$sandbox" hash-object "$selector")" = "$oid" ]; then
    fast_repair_sandbox_remove
    return 1
  fi
  selected=$(cd "$sandbox" && ./bin/fm-test-run.sh --list --family "$family" 2>/dev/null) || {
    fast_repair_sandbox_remove
    return 1
  }
  if ! printf '%s\n' "$selected" | grep -Fx "$selector" >/dev/null \
    || ! run_typed_selector "$sandbox" "$selector" fail "$log"; then
    fast_repair_sandbox_remove
    return 1
  fi
  fast_repair_sandbox_remove
}

eligibility_file() { printf '%s/%s/fast-repair-eligibility\n' "$DATA" "$1"; }
tests_file() { printf '%s/%s.fast-repair-tests\n' "$STATE" "$1"; }

body_file_valid() {
  local path=$1 parent resolved
  [ -n "$path" ] || return 1
  parent=$(dirname "$path")
  resolved=$(cd "$parent" 2>/dev/null && pwd -P) || return 1
  resolved="$resolved/$(basename "$path")"
  regular_file "$resolved" || return 1
  BODY_FILE=$resolved
}

require_fast_repair_meta() {
  local id meta
  id=$1
  meta="$STATE/$id.meta"
  regular_file "$meta" || fail "task $id has no safe metadata record"
  [ "$(field_get "$meta" mode)" = fast-repair ] || fail "task $id is not a Fast Repair task"
  [ "$(field_get "$meta" fast_repair)" = eligible ] || fail "task $id has no eligible Fast Repair result"
}

eligibility_valid() {
  local id=$1 f request positive risk
  f=$(eligibility_file "$id")
  regular_file "$f" || return 1
  [ "$(wc -l < "$f" | tr -d '[:space:]')" = 13 ] || return 1
  request=$(field_get "$f" request)
  request_valid "$request" || return 1
  [ "$(grep -c '^request=' "$f")" = 1 ] || return 1
  reproduction_revision_valid "$(field_get "$f" reproduction_revision)" || return 1
  [ "$(grep -c '^reproduction_revision=' "$f")" = 1 ] || return 1
  case "$(field_get "$f" lifecycle)" in ?*[!A-Za-z0-9._-]*|'') return 1 ;; esac
  [ "$(grep -c '^lifecycle=' "$f")" = 1 ] || return 1
  for positive in reproduction root_cause isolation; do
    positive_fact_valid "$positive" "$(field_get "$f" "$positive")" || return 1
    [ "$(grep -c "^$positive=" "$f")" = 1 ] || return 1
  done
  for risk in schema authentication authorization secrets financial legal side_effects; do
    risk_excluded "$(field_get "$f" "$risk")" || return 1
    [ "$(grep -c "^$risk=" "$f")" = 1 ] || return 1
  done
}

tests_passed() {
  local id=$1 f regression_test regression_selector regression_artifact regression_runner regression_reproduction regression_head focused_test reproduction_revision worktree branch head
  f=$(tests_file "$id")
  regular_file "$f" || return 1
  task_revision_for "$id" || return 1
  regression_test=$(field_get "$f" regression_test)
  regression_selector=$(field_get "$f" regression_selector)
  regression_artifact=$(field_get "$f" regression_artifact)
  regression_runner=$(field_get "$f" regression_runner)
  regression_reproduction=$(field_get "$f" regression_reproduction)
  regression_head=$(field_get "$f" regression_head)
  focused_test=$(field_get "$f" focused_test)
  reproduction_revision=$(field_get "$f" reproduction_revision)
  worktree=$(field_get "$f" worktree)
  branch=$(field_get "$f" branch)
  head=$(field_get "$f" head)
  reproduction_revision_for "$id" || return 1
  regression_test_valid "$id" "$regression_test" || return 1
  focused_test_valid "$focused_test" || return 1
  [ "$reproduction_revision" = "$REPRODUCTION_REVISION" ] || return 1
  [ "$regression_selector" = "$REGRESSION_SELECTOR" ] || return 1
  [ "$regression_artifact" = "$REGRESSION_ARTIFACT" ] || return 1
  [ "$regression_runner" = "$TEST_RUNNER_ARTIFACT" ] || return 1
  [ "$regression_reproduction" = failed ] || return 1
  [ "$regression_head" = passed ] || return 1
  [ "$worktree" = "$TASK_WORKTREE" ] || return 1
  [ "$branch" = "$TASK_BRANCH" ] || return 1
  [ "$head" = "$TASK_HEAD" ] || return 1
  [ "$(wc -l < "$f" | tr -d '[:space:]')" = 13 ] || return 1
  [ "$(grep -c '^regression=passed$' "$f")" = 1 ] || return 1
  [ "$(grep -c '^focused=passed$' "$f")" = 1 ] || return 1
  [ "$(grep -Fxc "regression_test=$regression_test" "$f")" = 1 ] || return 1
  [ "$(grep -Fxc "regression_selector=$regression_selector" "$f")" = 1 ] || return 1
  [ "$(grep -Fxc "regression_artifact=$regression_artifact" "$f")" = 1 ] || return 1
  [ "$(grep -Fxc "regression_runner=$regression_runner" "$f")" = 1 ] || return 1
  [ "$(grep -c '^regression_reproduction=failed$' "$f")" = 1 ] || return 1
  [ "$(grep -c '^regression_head=passed$' "$f")" = 1 ] || return 1
  [ "$(grep -Fxc "focused_test=$focused_test" "$f")" = 1 ] || return 1
  [ "$(grep -Fxc "reproduction_revision=$reproduction_revision" "$f")" = 1 ] || return 1
  [ "$(grep -Fxc "worktree=$worktree" "$f")" = 1 ] || return 1
  [ "$(grep -Fxc "branch=$branch" "$f")" = 1 ] || return 1
  [ "$(grep -Fxc "head=$head" "$f")" = 1 ]
}

broader_passed() {
  local id=$1 f broader_test broader_runner worktree branch head
  f="$STATE/$id.fast-repair-broader"
  regular_file "$f" || return 1
  task_revision_for "$id" || return 1
  broader_test=$(field_get "$f" broader_test)
  broader_runner=$(field_get "$f" broader_runner)
  worktree=$(field_get "$f" worktree)
  branch=$(field_get "$f" branch)
  head=$(field_get "$f" head)
  broader_test_valid "$id" "$broader_test" || return 1
  [ "$broader_runner" = "$TEST_RUNNER_ARTIFACT" ] || return 1
  [ "$worktree" = "$TASK_WORKTREE" ] || return 1
  [ "$branch" = "$TASK_BRANCH" ] || return 1
  [ "$head" = "$TASK_HEAD" ] || return 1
  [ "$(wc -l < "$f" | tr -d '[:space:]')" = 6 ] || return 1
  [ "$(grep -c '^broader=passed$' "$f")" = 1 ] || return 1
  [ "$(grep -Fxc "broader_test=$broader_test" "$f")" = 1 ] || return 1
  [ "$(grep -Fxc "broader_runner=$broader_runner" "$f")" = 1 ] || return 1
  [ "$(grep -Fxc "worktree=$worktree" "$f")" = 1 ] || return 1
  [ "$(grep -Fxc "branch=$branch" "$f")" = 1 ] || return 1
  [ "$(grep -Fxc "head=$head" "$f")" = 1 ]
}

pr_head_matches_tested() {
  local id=$1 meta pr_head remote_head
  task_revision_for "$id" || return 1
  meta="$STATE/$id.meta"
  pr_identity_for "$id" || return 1
  pr_head=$(field_get "$meta" pr_head)
  fm_pr_head_valid "$pr_head" || return 1
  [ "$(grep -Fxc "pr_head=$pr_head" "$meta")" = 1 ] || return 1
  [ "$pr_head" = "$TASK_HEAD" ] || return 1
  [ "$FM_PR_PROVIDER" = github ] || return 1
  command -v gh >/dev/null 2>&1 || return 1
  remote_head=$(cd "$TASK_WORKTREE" && gh pr view "$FM_PR_URL" --json headRefOid -q .headRefOid 2>/dev/null) || return 1
  fm_pr_head_valid "$remote_head" || return 1
  [ "$remote_head" = "$TASK_HEAD" ]
}

# The recorded pr= URL is re-parsed with the shared strict forge validator, so
# the repository and number always come from that one canonical record instead
# of from the caller's working directory. Fast Repair publishes through
# gh-axi, so only a GitHub pull request can be read here. On success the
# FM_PR_* identity of the shared parser is set for the caller.
pr_identity_for() {
  local meta url
  meta="$STATE/$1.meta"
  regular_file "$meta" || return 1
  url=$(field_get "$meta" pr)
  fm_pr_url_parse "$url" || return 1
  [ "$FM_PR_PROVIDER" = github ]
}

checks_summary() { # <number> <owner/repo>
  local raw
  command -v gh-axi >/dev/null 2>&1 || return 1
  raw=$(gh-axi pr checks "$1" --repo "$2" 2>/dev/null | sed -n 's/^summary: *//p' | head -n 1)
  # gh-axi renders its fields as TOON, which double-quotes every value holding a
  # comma, so the rollup summary always arrives quoted.
  case "$raw" in
    '"'*'"') raw=${raw#\"}; raw=${raw%\"} ;;
  esac
  printf '%s\n' "$raw"
}

# gh-axi renders the rollup as ["<n> passed","<n> failed", "<n> skipped" when
# non-zero, "<n> pending" when non-zero, "<n> total"], so a green PR omits the
# pending segment entirely and a substring test on the rendered string both
# misses green and reads "10 failed, 0 pending" as green. The counts are
# therefore extracted and compared numerically, and any segment, label, or
# total this does not recognize stays unknown rather than becoming green.
#
# gh-axi's own classifier folds SKIPPED, CANCELLED, EXPECTED and NEUTRAL-state
# runs into one "skipped" count, so a cancelled workflow is indistinguishable
# from a deliberately skipped job. A partial skip alongside real passes is
# ordinary CI and stays green, but a rollup where nothing passed at all has
# proven nothing and is never green.
checks_state() { # <summary> -> green|failed|pending|unknown
  local rest=${1-} part count label
  local passed='' failed='' total='' skipped=0 pending=0
  [ -n "$rest" ] || { printf 'unknown\n'; return 0; }
  while [ -n "$rest" ]; do
    case "$rest" in
      *', '*) part=${rest%%, *}; rest=${rest#*, } ;;
      *) part=$rest; rest= ;;
    esac
    case "$part" in *' '*) ;; *) printf 'unknown\n'; return 0 ;; esac
    count=${part%% *}
    label=${part#* }
    case "$count" in ''|*[!0-9]*) printf 'unknown\n'; return 0 ;; esac
    case "$label" in
      passed) passed=$count ;;
      failed) failed=$count ;;
      skipped) skipped=$count ;;
      pending) pending=$count ;;
      total) total=$count ;;
      *) printf 'unknown\n'; return 0 ;;
    esac
  done
  [ -n "$passed" ] && [ -n "$failed" ] && [ -n "$total" ] || { printf 'unknown\n'; return 0; }
  [ "$total" -gt 0 ] || { printf 'unknown\n'; return 0; }
  [ "$((passed + failed + skipped + pending))" -eq "$total" ] || { printf 'unknown\n'; return 0; }
  if [ "$failed" -gt 0 ]; then
    printf 'failed\n'
  elif [ "$pending" -gt 0 ]; then
    printf 'pending\n'
  elif [ "$passed" -eq 0 ]; then
    printf 'unknown\n'
  else
    printf 'green\n'
  fi
}

command=${1:-}
[ -n "$command" ] || { usage >&2; exit 2; }
shift || true

case "$command" in
  -h|--help|help) usage; exit 0 ;;
  is-request)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    request_valid "$1"
    ;;
  intake)
    id=${1:-}
    shift || true
    task_id_valid "$id" || fail "task id is missing or invalid"
    request=
    reproduction=
    reproduction_revision=
    root_cause=
    isolation=
    schema=
    authentication=
    authorization=
    secrets=
    financial=
    legal=
    side_effects=
    while [ "$#" -gt 0 ]; do
      key=$1
      shift
      [ "$#" -gt 0 ] || fail "$key needs an explicit value"
      value=$1
      shift
      case "$key" in
        --request) request=$value ;;
        --reproduction) reproduction=$value ;;
        --reproduction-revision) reproduction_revision=$value ;;
        --root-cause) root_cause=$value ;;
        --isolation) isolation=$value ;;
        --schema) schema=$value ;;
        --authentication) authentication=$value ;;
        --authorization) authorization=$value ;;
        --secrets) secrets=$value ;;
        --financial) financial=$value ;;
        --legal) legal=$value ;;
        --side-effects) side_effects=$value ;;
        *) fail "unknown intake evidence flag $key" ;;
      esac
    done
    request_valid "$request" || fail "request does not use the exact 'fast-repair: ' prefix"
    for field in reproduction root_cause isolation; do
      eval "value=\${$field}"
      positive_fact_valid "$field" "$value" \
        || fail "$field must equal its exact typed proof value"
    done
    reproduction_revision_valid "$reproduction_revision" \
      || fail "reproduction-revision must be a lowercase commit SHA"
    for field in schema authentication authorization secrets financial legal side_effects; do
      eval "value=\${$field}"
      risk_excluded "$value" || fail "$field is not explicitly proven none"
    done
    lifecycle="$(date +%s)-$$-$RANDOM"
    dir="$DATA/$id"
    mkdir -p "$dir"
    tmp="$dir/.fast-repair-eligibility.$$"
    umask 077
    {
      printf 'request=%s\n' "$request"
      printf 'reproduction=%s\n' "$reproduction"
      printf 'reproduction_revision=%s\n' "$reproduction_revision"
      printf 'lifecycle=%s\n' "$lifecycle"
      printf 'root_cause=%s\n' "$root_cause"
      printf 'isolation=%s\n' "$isolation"
      printf 'schema=%s\n' "$schema"
      printf 'authentication=%s\n' "$authentication"
      printf 'authorization=%s\n' "$authorization"
      printf 'secrets=%s\n' "$secrets"
      printf 'financial=%s\n' "$financial"
      printf 'legal=%s\n' "$legal"
      printf 'side_effects=%s\n' "$side_effects"
    } > "$tmp"
    chmod 600 "$tmp"
    mv -f "$tmp" "$(eligibility_file "$id")"
    printf 'fast-repair eligible: %s\n' "$id"
    ;;
  eligible)
    id=${1:-}
    shift || true
    task_id_valid "$id" || fail "task id is missing or invalid"
    worktree=
    if [ "$#" -gt 0 ]; then
      [ "$#" -eq 2 ] && [ "$1" = --worktree ] || { usage >&2; exit 2; }
      worktree=$2
    fi
    if ! eligibility_valid "$id"; then
      fail "eligibility evidence is absent, incomplete, or no longer valid for $id"
    fi
    # This runs at dispatch, before the crewmate has created its branch or made
    # the repair commit, so it proves only what exists then: a clean worktree of
    # this task's own repository whose history already carries the recorded
    # reproduction commit. The branch and the strictly-older reproduction
    # revision are proofs about the tested head, and stay in evidence,
    # publish-pr, broader, and ready where that head is real.
    if [ -n "$worktree" ] && ! task_head_at_worktree "$worktree"; then
      fail "task $id has no safe git worktree for reproduction proof"
    fi
    if [ -n "$worktree" ] && ! reproduction_revision_recorded "$id"; then
      fail "reproduction revision is unknown or not an ancestor of the task worktree head"
    fi
    printf 'fast-repair eligible: %s\n' "$id"
    ;;
  evidence)
    id=${1:-}
    shift || true
    task_id_valid "$id" || fail "task id is missing or invalid"
    regression_test=
    focused_test=
    while [ "$#" -gt 0 ]; do
      key=$1
      shift
      [ "$#" -gt 0 ] || fail "$key needs a value"
      value=$1
      shift
      case "$key" in
        --regression-test) regression_test=$value ;;
        --focused-test) focused_test=$value ;;
        *) fail "unknown test evidence flag $key" ;;
      esac
    done
    require_fast_repair_meta "$id"
    eligibility_valid "$id" || fail "eligibility evidence is absent or invalid"
    task_revision_for "$id" || fail "task $id has no safe git worktree at its metadata path"
    reproduction_revision_for "$id" \
      || fail "reproduction revision is unknown, current, or not an ancestor of the task head"
    regression_test_valid "$id" "$regression_test" \
      || fail "regression-test must name one new tracked runner selector"
    focused_test_valid "$focused_test" \
      || fail "focused-test must name a supported bin/fm-test-run.sh family"
    [ "$regression_test" != "$focused_test" ] \
      || fail "regression-test and focused-test must name different test selectors"
    mkdir -p "$STATE"
    log="$STATE/$id.fast-repair-tests.log"
    record="$STATE/.$id.fast-repair-tests.$$"
    private_truncate "$log" || fail "the evidence log could not be created"
    if regression_witness_valid "$regression_test" "$REGRESSION_SELECTOR" "$REGRESSION_ARTIFACT" "$log"; then regression_reproduction=failed; else regression_reproduction=unproven; fi
    if [ "$regression_reproduction" = failed ] \
      && run_typed_selector "$TASK_WORKTREE" "$REGRESSION_SELECTOR" pass "$log"; then regression_head=passed; else regression_head=failed; fi
    if [ "$regression_reproduction" = failed ] && [ "$regression_head" = passed ]; then regression_result=passed; else regression_result=failed; fi
    if [ "$regression_result" = passed ] && run_typed_test "$TASK_WORKTREE" "$focused_test" pass "$log"; then focused_result=passed; else focused_result=failed; fi
    {
      printf 'regression=%s\n' "$regression_result"
      printf 'regression_test=%s\n' "$regression_test"
      printf 'regression_selector=%s\n' "$REGRESSION_SELECTOR"
      printf 'regression_artifact=%s\n' "$REGRESSION_ARTIFACT"
      printf 'regression_runner=%s\n' "$TEST_RUNNER_ARTIFACT"
      printf 'regression_reproduction=%s\n' "$regression_reproduction"
      printf 'regression_head=%s\n' "$regression_head"
      printf 'focused=%s\n' "$focused_result"
      printf 'focused_test=%s\n' "$focused_test"
      printf 'reproduction_revision=%s\n' "$REPRODUCTION_REVISION"
      printf 'worktree=%s\n' "$TASK_WORKTREE"
      printf 'branch=%s\n' "$TASK_BRANCH"
      printf 'head=%s\n' "$TASK_HEAD"
    } | private_write "$record" || fail "the evidence record could not be written"
    mv -f "$record" "$(tests_file "$id")"
    tests_passed "$id" || fail "regression or focused-module evidence failed; PR publication remains blocked"
    printf 'fast-repair focused evidence passed: %s\n' "$id"
    ;;
  publish-pr)
    id=${1:-}
    shift || true
    task_id_valid "$id" || fail "task id is missing or invalid"
    title=
    body_file=
    base=
    head=
    while [ "$#" -gt 0 ]; do
      key=$1
      shift
      [ "$#" -gt 0 ] || fail "$key needs a value"
      value=$1
      shift
      case "$key" in
        --title) title=$value ;;
        --body-file) body_file=$value ;;
        --base) base=$value ;;
        --head) head=$value ;;
        *) fail "unknown PR flag $key" ;;
      esac
    done
    require_fast_repair_meta "$id"
    eligibility_valid "$id" || fail "eligibility evidence is absent or invalid"
    tests_passed "$id" || fail "focused evidence is absent or failed; direct PR publication is blocked"
    [ -z "$head" ] || [ "$head" = "$TASK_BRANCH" ] \
      || fail "--head must equal the tested task branch $TASK_BRANCH"
    if [ -z "$title" ] || ! body_file_valid "$body_file"; then
      fail "a title and safe body file are required"
    fi
    args=(pr create --title "$title" --body-file "$BODY_FILE")
    [ -z "$base" ] || args+=(--base "$base")
    args+=(--head "$TASK_BRANCH")
    out=$(cd "$TASK_WORKTREE" && gh-axi "${args[@]}") || exit $?
    printf '%s\n' "$out"
    url=$(printf '%s\n' "$out" | grep -Eo 'https://github\.com/[^[:space:]]+/pull/[0-9]+' | head -n 1 || true)
    [ -n "$url" ] || fail "PR creation returned no GitHub pull-request URL"
    "$SCRIPT_DIR/fm-pr-check.sh" "$id" "$url" >/dev/null
    pr_head_matches_tested "$id" \
      || fail "registered PR head does not match the exact tested task commit"
    printf 'fast-repair PR opened: %s\n' "$url"
    ;;
  broader)
    id=${1:-}
    shift || true
    task_id_valid "$id" || fail "task id is missing or invalid"
    [ "${1:-}" = --test ] && [ "$#" -eq 2 ] || fail "broader requires exactly --test <runner-family>"
    broader_test=$2
    require_fast_repair_meta "$id"
    eligibility_valid "$id" || fail "eligibility evidence is absent or invalid"
    tests_passed "$id" || fail "focused evidence is absent or failed"
    task_revision_for "$id" || fail "task $id has no safe git worktree at its metadata path"
    pr_identity_for "$id" || fail "broader tests start only after the direct PR is registered"
    broader_test_valid "$id" "$broader_test" \
      || fail "broader-test must name a supported runner family with bound artifacts that is not the focused family already proven before the PR"
    log="$STATE/$id.fast-repair-broader.log"
    record="$STATE/.$id.fast-repair-broader.$$"
    private_truncate "$log" || fail "the broader-test log could not be created"
    if run_typed_test "$TASK_WORKTREE" "$broader_test" pass "$log"; then result=passed; else result=failed; fi
    {
      printf 'broader=%s\n' "$result"
      printf 'broader_test=%s\n' "$broader_test"
      printf 'broader_runner=%s\n' "$TEST_RUNNER_ARTIFACT"
      printf 'worktree=%s\n' "$TASK_WORKTREE"
      printf 'branch=%s\n' "$TASK_BRANCH"
      printf 'head=%s\n' "$TASK_HEAD"
    } | private_write "$record" \
      || fail "the broader-test record could not be written"
    mv -f "$record" "$STATE/$id.fast-repair-broader"
    [ "$result" = passed ] || fail "broader tests failed after PR publication; inspect $log and report the open PR as not green"
    printf 'fast-repair broader tests passed: %s\n' "$id"
    ;;
  progress)
    id=${1:-}
    shift || true
    local_only=0
    if [ "$#" -gt 0 ]; then
      [ "$#" -eq 1 ] && [ "$1" = --local-only ] || { usage >&2; exit 2; }
      local_only=1
    fi
    task_id_valid "$id" || fail "task id is missing or invalid"
    require_fast_repair_meta "$id"
    eligibility_valid "$id" || fail "eligibility evidence is absent or invalid"
    if regular_file "$STATE/$id.fast-repair-broader" && [ "$(field_get "$STATE/$id.fast-repair-broader" broader)" = failed ]; then
      printf 'fast-repair %s broader-tests-failed\n' "$id"
      exit 0
    fi
    [ "$local_only" -eq 0 ] || exit 0
    pr_identity_for "$id" 2>/dev/null || exit 0
    summary=$(checks_summary "$FM_PR_NUMBER" "$FM_PR_OWNER/$FM_PR_REPO" 2>/dev/null || true)
    state=$(checks_state "$summary")
    case "$state" in
      failed) printf 'fast-repair %s pr-checks-failed: %s\n' "$id" "$summary" ;;
      green) printf 'fast-repair %s pr-checks-green: %s\n' "$id" "$summary" ;;
    esac
    ;;
  ready)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    id=$1
    task_id_valid "$id" || fail "task id is missing or invalid"
    require_fast_repair_meta "$id"
    eligibility_valid "$id" || fail "eligibility evidence is absent or invalid"
    tests_passed "$id" || fail "focused evidence is absent or failed"
    broader_passed "$id" || fail "broader tests are not passed"
    pr_head_matches_tested "$id" || fail "registered PR head does not match the exact tested task commit"
    pr_identity_for "$id" || fail "no registered Fast Repair PR"
    summary=$(checks_summary "$FM_PR_NUMBER" "$FM_PR_OWNER/$FM_PR_REPO") || fail "PR checks could not be read"
    [ -n "$summary" ] || fail "PR checks could not be read"
    [ "$(checks_state "$summary")" = green ] || fail "PR checks are not green: $summary"
    printf 'fast-repair ready: %s (%s)\n' "$FM_PR_URL" "$summary"
    ;;
  *) usage >&2; exit 2 ;;
esac
