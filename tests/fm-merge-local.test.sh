#!/usr/bin/env bash
# tests/fm-merge-local.test.sh - the guarded landing for a local-only ship task.
#
# A local-only project's canonical copy is a folder outside projects/, so the
# landing has two stages: fast-forward the clone's default branch, then carry
# that branch into the folder the clone names as its origin. This suite drives
# real git repositories through both stages, because the whole contract is about
# what git does to a working copy someone else is using.
#
# Every refusal here has to leave the origin folder byte-identical, so each
# refusing case asserts the folder's own commit and its uncommitted work
# afterwards rather than only the exit status.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MERGE="$ROOT/bin/fm-merge-local.sh"
TMP_ROOT=$(fm_test_tmproot fm-merge-local)

git_q() { git -C "$1" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' "${@:2}"; }

commit_file() {  # <repo> <path> <content> <message>
  printf '%s\n' "$3" > "$1/$2"
  git_q "$1" add -A
  git_q "$1" commit -qm "$4"
}

# The captain's own folder (a git repo with no remote at all, outside projects/),
# a home whose clone of it is the project, and a task meta pointing at that clone.
# Echoes "<home>|<origin-folder>|<clone>".
make_landing() {  # <name>
  local name=$1 base home origin clone
  mkdir -p "$TMP_ROOT/$name"
  # Canonical paths throughout: the landing resolves the origin folder with
  # `pwd -P`, so a symlinked temp root would otherwise make every reported path
  # disagree with the fixture's own.
  base=$(cd "$TMP_ROOT/$name" && pwd -P)
  home="$base/home"
  origin="$base/JobSearch"
  clone="$home/projects/JobSearch"
  mkdir -p "$home/data" "$home/state" "$home/projects" "$origin"
  git_q "$origin" init -q -b main
  commit_file "$origin" CV.tex "cv first draft" initial
  git clone --quiet "$origin" "$clone"
  printf '%s\n' '- JobSearch [local-only +yolo] - the cycle (added 2026-07-29)' > "$home/data/projects.md"
  printf '%s\n' "$home|$origin|$clone"
}

# A finished crewmate branch left behind exactly as a local-only worker leaves it:
# committed on fm/<id>, never pushed, with the clone back on its default branch.
ready_branch() {  # <home> <clone> <id> <path> <content>
  local home=$1 clone=$2 id=$3 path=$4 content=$5
  git_q "$clone" checkout -q -b "fm/$id" main
  commit_file "$clone" "$path" "$content" "work for $id"
  git_q "$clone" checkout -q main
  printf 'project=%s\nmode=local-only\nkind=ship\n' "$clone" > "$home/state/$id.meta"
}

run_merge() {  # <home> <id>; stdout and stderr merged, guard banners stripped
  local home=$1 id=$2
  FM_HOME="$home" "$MERGE" "$id" 2>&1 | grep -v '^●' | grep -v '^WARNING: watcher'
  return "${PIPESTATUS[0]}"
}

head_of() { git -C "$1" rev-parse --verify "refs/heads/${2:-main}"; }

test_landing_reaches_the_origin_folder() {
  local home origin clone out before_head
  IFS='|' read -r home origin clone <<EOF
$(make_landing reaches)
EOF
  ready_branch "$home" "$clone" task-a Cover.tex "the cover letter"

  # The folder is dirty the way a folder someone works in always is, but on
  # paths the landing never touches, so the carry must still go through.
  printf '%s\n' "notes in progress" > "$origin/Notes.md"
  printf '%s\n' "cv edited by hand" > "$origin/CV.tex"
  before_head=$(head_of "$origin")

  out=$(run_merge "$home" task-a) || fail "landing refused a clean fast-forward: $out"

  [ -f "$origin/Cover.tex" ] || fail "the landed file never reached the origin folder"
  [ "$(head_of "$origin")" = "$(head_of "$clone")" ] \
    || fail "the origin folder is not at the landed commit"
  [ "$(head_of "$origin")" != "$before_head" ] || fail "the origin folder never moved"
  case "$out" in
    *"carried main into $origin"*) ;;
    *) fail "landing did not report carrying the branch into the origin folder: $out" ;;
  esac
  # His own uncommitted work is the thing this must never touch.
  [ "$(cat "$origin/CV.tex")" = "cv edited by hand" ] || fail "the landing overwrote an uncommitted edit"
  [ -f "$origin/Notes.md" ] || fail "the landing removed an untracked file"
  pass "an approved landing carries the change into the project's own folder"
}

test_landing_is_idempotent() {
  local home origin clone out landed
  IFS='|' read -r home origin clone <<EOF
$(make_landing idempotent)
EOF
  ready_branch "$home" "$clone" task-b Cover.tex "the cover letter"
  run_merge "$home" task-b >/dev/null || fail "first landing failed"
  landed=$(head_of "$origin")

  out=$(run_merge "$home" task-b) || fail "a repeat landing refused instead of converging: $out"
  case "$out" in
    *"already current"*) ;;
    *) fail "a repeat landing did not report the folder as already current: $out" ;;
  esac
  [ "$(head_of "$origin")" = "$landed" ] || fail "a repeat landing moved the origin folder again"
  pass "a repeated landing converges instead of refusing or re-merging"
}

test_landing_refuses_uncommitted_work_on_a_path_it_would_change() {
  local home origin clone out before_head
  IFS='|' read -r home origin clone <<EOF
$(make_landing collide)
EOF
  ready_branch "$home" "$clone" task-c CV.tex "cv rebuilt by the worker"
  printf '%s\n' "cv the captain is still editing" > "$origin/CV.tex"
  before_head=$(head_of "$origin")

  if out=$(run_merge "$home" task-c); then
    fail "landing proceeded over uncommitted work on a path it changes: $out"
  fi
  case "$out" in
    *REFUSED*"uncommitted work on paths this landing would change"*"CV.tex"*) ;;
    *) fail "refusal did not name the colliding path: $out" ;;
  esac
  [ "$(cat "$origin/CV.tex")" = "cv the captain is still editing" ] \
    || fail "the refused landing still overwrote the uncommitted edit"
  [ "$(head_of "$origin")" = "$before_head" ] || fail "the refused landing still moved the origin folder"
  # Stage one is a separate, already-approved merge, so it stands.
  [ "$(head_of "$clone")" != "$before_head" ] || fail "the clone's own default branch never advanced"
  pass "landing refuses when uncommitted work sits on a path it would change"
}

test_landing_refuses_an_untracked_file_it_would_overwrite() {
  local home origin clone out before_head
  IFS='|' read -r home origin clone <<EOF
$(make_landing untracked)
EOF
  ready_branch "$home" "$clone" task-d Cover.tex "the cover letter"
  printf '%s\n' "a draft the captain wrote himself" > "$origin/Cover.tex"
  before_head=$(head_of "$origin")

  if out=$(run_merge "$home" task-d); then
    fail "landing proceeded over an untracked file it would overwrite: $out"
  fi
  case "$out" in
    *REFUSED*"Cover.tex"*) ;;
    *) fail "refusal did not name the untracked path: $out" ;;
  esac
  [ "$(cat "$origin/Cover.tex")" = "a draft the captain wrote himself" ] \
    || fail "the refused landing still overwrote the untracked file"
  [ "$(head_of "$origin")" = "$before_head" ] || fail "the refused landing still moved the origin folder"
  pass "landing refuses when an untracked file would be overwritten"
}

test_landing_refuses_a_folder_on_another_branch() {
  local home origin clone out before_head
  IFS='|' read -r home origin clone <<EOF
$(make_landing offbranch)
EOF
  ready_branch "$home" "$clone" task-e Cover.tex "the cover letter"
  git_q "$origin" checkout -q -b drafting
  before_head=$(head_of "$origin" drafting)

  if out=$(run_merge "$home" task-e); then
    fail "landing changed a folder that was on another branch: $out"
  fi
  case "$out" in
    *REFUSED*"is on 'drafting', not 'main'"*) ;;
    *) fail "refusal did not name the branch the folder is on: $out" ;;
  esac
  [ "$(head_of "$origin" drafting)" = "$before_head" ] || fail "the refused landing still moved the folder"
  [ ! -f "$origin/Cover.tex" ] || fail "the refused landing still wrote into the folder"
  pass "landing refuses a folder that is not on the project's default branch"
}

test_landing_refuses_when_the_folder_has_its_own_commits() {
  local home origin clone out before_head
  IFS='|' read -r home origin clone <<EOF
$(make_landing diverged)
EOF
  ready_branch "$home" "$clone" task-f Cover.tex "the cover letter"
  commit_file "$origin" Diary.md "written straight into his own folder" "his own work"
  before_head=$(head_of "$origin")

  if out=$(run_merge "$home" task-f); then
    fail "landing was not a fast-forward yet still proceeded: $out"
  fi
  case "$out" in
    *REFUSED*"has commits on main"*"not a fast-forward"*) ;;
    *) fail "refusal did not explain the divergence: $out" ;;
  esac
  [ "$(head_of "$origin")" = "$before_head" ] || fail "the refused landing still moved the origin folder"
  [ -f "$origin/Diary.md" ] || fail "the refused landing disturbed the folder's own commit"
  pass "landing refuses rather than forcing when the folder has its own commits"
}

test_landing_refuses_an_origin_that_is_not_a_work_tree_root() {
  local home origin clone out nested
  IFS='|' read -r home origin clone <<EOF
$(make_landing nested)
EOF
  ready_branch "$home" "$clone" task-g Cover.tex "the cover letter"
  # A subdirectory of a repository is not that repository, and git will happily
  # answer for the enclosing one, so this must be refused rather than landed
  # into a repository nobody named.
  nested="$origin/Applications"
  mkdir -p "$nested"
  git -C "$clone" remote set-url origin "$nested"

  if out=$(run_merge "$home" task-g); then
    fail "landing accepted an origin that is only a directory inside a repository: $out"
  fi
  case "$out" in
    *REFUSED*"not the root of a git work tree"*) ;;
    *) fail "refusal did not explain the non-root origin: $out" ;;
  esac
  [ ! -f "$nested/Cover.tex" ] || fail "the refused landing still wrote into the nested directory"
  pass "landing refuses an origin that is not a work-tree root"
}

test_landing_refuses_a_missing_origin_folder() {
  local home origin clone out
  IFS='|' read -r home origin clone <<EOF
$(make_landing missing)
EOF
  ready_branch "$home" "$clone" task-h Cover.tex "the cover letter"
  git -C "$clone" remote set-url origin "$origin-gone"

  if out=$(run_merge "$home" task-h); then
    fail "landing accepted an origin folder that does not exist: $out"
  fi
  case "$out" in
    *REFUSED*"is missing"*) ;;
    *) fail "refusal did not report the missing origin folder: $out" ;;
  esac
  pass "landing refuses when the origin folder is gone"
}

test_landing_reports_when_the_clone_is_the_only_copy() {
  local home origin clone out
  IFS='|' read -r home origin clone <<EOF
$(make_landing solo)
EOF
  ready_branch "$home" "$clone" task-i Cover.tex "the cover letter"
  git -C "$clone" remote remove origin

  out=$(run_merge "$home" task-i) || fail "landing failed for a clone that is the only copy: $out"
  case "$out" in
    *"has no origin, so this clone is the project's only copy"*) ;;
    *) fail "landing did not report where it ended: $out" ;;
  esac
  [ "$(head_of "$clone")" != "$(head_of "$origin")" ] || fail "fixture did not isolate the clone"
  pass "a local-only project with no origin lands in its clone and says so"
}

test_landing_reports_a_bare_origin() {
  local home origin clone out bare
  IFS='|' read -r home origin clone <<EOF
$(make_landing bare)
EOF
  ready_branch "$home" "$clone" task-j Cover.tex "the cover letter"
  mkdir -p "$TMP_ROOT/bare"
  bare="$(cd "$TMP_ROOT/bare" && pwd -P)/JobSearch.git"
  git clone --quiet --bare "$origin" "$bare"
  git -C "$clone" remote set-url origin "$bare"

  out=$(run_merge "$home" task-j) || fail "landing failed for a bare origin: $out"
  case "$out" in
    *"is a bare repository with no working copy to update"*) ;;
    *) fail "landing did not report the bare origin: $out" ;;
  esac
  [ "$(head_of "$bare")" = "$(head_of "$origin")" ] || fail "the landing wrote into a bare origin"
  pass "a bare origin has no working copy, so the landing ends at the clone and says so"
}

test_landing_reports_a_remote_origin_url() {
  local home origin clone out
  IFS='|' read -r home origin clone <<EOF
$(make_landing remoteurl)
EOF
  ready_branch "$home" "$clone" task-k Cover.tex "the cover letter"
  git -C "$clone" remote set-url origin "https://example.invalid/owner/JobSearch.git"

  out=$(run_merge "$home" task-k) || fail "landing failed for a non-local origin: $out"
  case "$out" in
    *"is not a folder on this machine"*) ;;
    *) fail "landing did not report the non-local origin: $out" ;;
  esac
  [ "$(head_of "$origin")" != "$(head_of "$clone")" ] || fail "fixture did not isolate the folder"
  pass "an origin on another host is not a folder to carry into, and the landing says so"
}

test_landing_still_refuses_a_task_that_is_not_local_only() {
  local home origin clone out
  IFS='|' read -r home origin clone <<EOF
$(make_landing wrongmode)
EOF
  ready_branch "$home" "$clone" task-l Cover.tex "the cover letter"
  printf 'project=%s\nmode=no-mistakes\nkind=ship\n' "$clone" > "$home/state/task-l.meta"

  if out=$(run_merge "$home" task-l); then
    fail "the local landing path accepted a task that ships through a PR: $out"
  fi
  case "$out" in
    *"not local-only"*) ;;
    *) fail "refusal did not name the task's delivery mode: $out" ;;
  esac
  [ ! -f "$origin/Cover.tex" ] || fail "a non-local-only task still reached the origin folder"
  pass "the local landing path still refuses any task that is not local-only"
}

test_landing_reaches_the_origin_folder
test_landing_is_idempotent
test_landing_refuses_uncommitted_work_on_a_path_it_would_change
test_landing_refuses_an_untracked_file_it_would_overwrite
test_landing_refuses_a_folder_on_another_branch
test_landing_refuses_when_the_folder_has_its_own_commits
test_landing_refuses_an_origin_that_is_not_a_work_tree_root
test_landing_refuses_a_missing_origin_folder
test_landing_reports_when_the_clone_is_the_only_copy
test_landing_reports_a_bare_origin
test_landing_reports_a_remote_origin_url
test_landing_still_refuses_a_task_that_is_not_local_only
