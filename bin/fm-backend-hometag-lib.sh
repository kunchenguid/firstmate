#!/usr/bin/env bash
# bin/fm-backend-hometag-lib.sh - shared home-tag and reader-path validation
# for machine-global namespaces with no native per-home split: cmux's workspace
# list, zellij's shared session tab bar, and reader task roots under /tmp.
# Without the tag, equal task ids in distinct homes can address the same
# backend endpoint or disposable reader storage.
#
# fm_backend_hometag() derives a short, stable tag: a readable prefix
# ("firstmate" for the primary home, "2ndmate-<id>" for a secondmate home
# carrying .fm-secondmate-home) plus a short hash of the resolved FM_ROOT
# path, so distinct installations - including multiple primaries on one
# machine - never collide in the shared namespace. Callers source this file
# AFTER resolving their own
# FM_HOME/FM_ROOT fallbacks (both adapters already do this for their own
# purposes before any other function runs).
#
# Moving/relocating a firstmate installation changes its FM_ROOT path and
# therefore its tag; titles created under the old tag simply stop matching -
# an accepted limitation, no worse than the existing fact that a task's
# recorded absolute worktree path does not survive a move either.

FM_BACKEND_HOMETAG_SECONDMATE_MARKER=".fm-secondmate-home"

fm_backend_hometag() {
  local marker="$FM_HOME/$FM_BACKEND_HOMETAG_SECONDMATE_MARKER" id prefix root hash
  if [ -f "$marker" ]; then
    id=$(tr -d '[:space:]' < "$marker" 2>/dev/null)
    if [ -n "$id" ]; then
      prefix="2ndmate-$id"
    else
      prefix="firstmate"
    fi
  else
    prefix="firstmate"
  fi
  root=$(cd "$FM_ROOT" 2>/dev/null && pwd -P) || root=$FM_ROOT
  if command -v shasum >/dev/null 2>&1; then
    hash=$(printf '%s' "$root" | shasum -a 256 | awk '{print substr($1,1,8)}')
  elif command -v sha256sum >/dev/null 2>&1; then
    hash=$(printf '%s' "$root" | sha256sum | awk '{print substr($1,1,8)}')
  else
    hash=$(printf '%s' "$root" | cksum | awk '{printf "%08x", $1}')
  fi
  printf '%s-%s' "$prefix" "$hash"
}

# fm_reader_task_tmp() is the single owner of a reader task's temp-root
# spelling. fm-spawn records it as tasktmp= and fm-teardown recomputes it as
# the destruction anchor it refuses to deviate from, even under --force; two
# independent spellings would make every already-spawned reader permanently
# untearable-down the moment one side changed. It sets FM_READER_TASK_TMP on
# success and returns non-zero when the derived tag cannot safely name a
# directory, leaving FM_READER_TASK_TMP_HOMETAG for the caller's diagnostic.
FM_READER_TASK_TMP=
FM_READER_TASK_TMP_HOMETAG=

fm_reader_task_tmp() {  # <task-id>
  local id=$1
  FM_READER_TASK_TMP=
  FM_READER_TASK_TMP_HOMETAG=$(fm_backend_hometag)
  case "$FM_READER_TASK_TMP_HOMETAG" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  # shellcheck disable=SC2034 # Output global consumed by scripts sourcing this library.
  FM_READER_TASK_TMP="/tmp/fm-$FM_READER_TASK_TMP_HOMETAG-$id"
}

fm_reader_recorded_scratch_validate() {  # <task-id> <recorded-tasktmp> <recorded-scratch>
  local id=$1 recorded_tasktmp=$2 recorded_scratch=$3 expected_scratch scratch_real
  fm_reader_task_tmp "$id" || {
    echo "error: reader home identity '$FM_READER_TASK_TMP_HOMETAG' is not safe for a task temp root; refusing to relaunch" >&2
    return 1
  }
  [ "$recorded_tasktmp" = "$FM_READER_TASK_TMP" ] || {
    echo "error: task $id's recorded reader tasktmp '${recorded_tasktmp:-none}' does not match its canonical task root $FM_READER_TASK_TMP; refusing to relaunch" >&2
    return 1
  }
  [ ! -L "$FM_READER_TASK_TMP" ] && [ ! -L "$FM_READER_TASK_TMP/scratch" ] || {
    echo "error: task $id's canonical reader scratch sits behind a symlink; refusing to relaunch" >&2
    return 1
  }
  expected_scratch=$(cd "$FM_READER_TASK_TMP/scratch" 2>/dev/null && pwd -P) || {
    echo "error: task $id's canonical reader scratch $FM_READER_TASK_TMP/scratch is missing or cannot be resolved; refusing to relaunch" >&2
    return 1
  }
  scratch_real=$(cd "$recorded_scratch" 2>/dev/null && pwd -P) || {
    echo "error: task $id's recorded reader scratch $recorded_scratch cannot be resolved; refusing to relaunch" >&2
    return 1
  }
  [ "$scratch_real" = "$expected_scratch" ] || {
    echo "error: task $id's recorded reader scratch $scratch_real does not match its canonical scratch $expected_scratch; refusing to relaunch" >&2
    return 1
  }
}

fm_reader_validate_descendant_symlinks() {  # <canonical-scratch-dir>
  local scratch=$1 links link raw_target target_real
  links=$(find "$scratch" -type l -print 2>/dev/null) || {
    echo "error: reader scratch directory $scratch could not be inspected for descendant symlinks; refusing to launch - a reader must never be able to write a tracked file" >&2
    return 1
  }
  while IFS= read -r link || [ -n "$link" ]; do
    [ -n "$link" ] || continue
    raw_target=$(readlink "$link" 2>/dev/null) || {
      echo "error: reader scratch directory $scratch contains an unsafe symlink at $link whose target cannot be read; refusing to launch - a reader must never be able to write a tracked file" >&2
      return 1
    }
    case "$raw_target" in
      /*)
        echo "error: reader scratch directory $scratch contains an unsafe symlink at $link that uses an absolute target; refusing to launch - a reader must never be able to write a tracked file" >&2
        return 1
        ;;
    esac
    target_real=$(realpath "$link" 2>/dev/null) || {
      echo "error: reader scratch directory $scratch contains an unsafe symlink at $link whose target cannot be resolved; refusing to launch - a reader must never be able to write a tracked file" >&2
      return 1
    }
    [ -e "$target_real" ] || {
      echo "error: reader scratch directory $scratch contains an unsafe symlink at $link whose target cannot be resolved; refusing to launch - a reader must never be able to write a tracked file" >&2
      return 1
    }
    case "$target_real" in
      "$scratch"|"$scratch"/*) ;;
      *)
        echo "error: reader scratch directory $scratch contains an unsafe symlink at $link that resolves outside its canonical root; refusing to launch - a reader must never be able to write a tracked file" >&2
        return 1
        ;;
    esac
  done <<EOF
$(printf '%s\n' "$links" | LC_ALL=C sort)
EOF
}

FM_READER_VALIDATED_SCRATCH=

fm_reader_scratch_validate() {  # <scratch-dir> <project-dir>
  local scratch=$1 project=$2 scratch_real project_real inside_work_tree inside_git_dir descendant_git
  FM_READER_VALIDATED_SCRATCH=
  scratch_real=$(cd "$scratch" 2>/dev/null && pwd -P) || {
    echo "error: reader scratch directory cannot be resolved: $scratch; refusing to launch" >&2
    return 1
  }
  project_real=$(cd "$project" 2>/dev/null && pwd -P) || {
    echo "error: reader project directory cannot be resolved: $project; refusing to launch" >&2
    return 1
  }
  case "$scratch_real" in
    "$project_real"|"$project_real"/*)
      echo "error: reader scratch directory $scratch_real resolves into the primary checkout $project_real; refusing to launch - a reader must never be able to write a tracked file" >&2
      return 1
      ;;
  esac
  inside_work_tree=$(git -C "$scratch_real" rev-parse --is-inside-work-tree 2>/dev/null) || inside_work_tree=false
  inside_git_dir=$(git -C "$scratch_real" rev-parse --is-inside-git-dir 2>/dev/null) || inside_git_dir=false
  if [ "$inside_work_tree" = true ] || [ "$inside_git_dir" = true ]; then
    echo "error: reader scratch directory $scratch_real is inside a git checkout or git dir; refusing to launch - a reader must never be able to write a tracked file" >&2
    return 1
  fi
  fm_reader_validate_descendant_symlinks "$scratch_real" || return 1
  descendant_git=$(find "$scratch_real" -name .git -print -quit 2>/dev/null) || {
    echo "error: reader scratch directory $scratch_real could not be inspected for descendant git metadata; refusing to launch - a reader must never be able to write a tracked file" >&2
    return 1
  }
  if [ -n "$descendant_git" ]; then
    echo "error: reader scratch directory $scratch_real contains a git checkout at $descendant_git; refusing to launch - a reader must never be able to write a tracked file" >&2
    return 1
  fi
  # shellcheck disable=SC2034 # Output global consumed by scripts sourcing this library.
  FM_READER_VALIDATED_SCRATCH=$scratch_real
}

FM_READER_SANDBOX_PLATFORM=
FM_READER_SANDBOX_BIN=
FM_READER_SANDBOX_PROFILE=
FM_READER_REPORT_DIR=
FM_READER_STATE_DIR=

fm_reader_sandbox_preflight() {  # <project-dir> <scratch-dir> <report-dir> <state-dir>
  local project=$1 scratch=$2 report=$3 state=$4 project_real scratch_real report_real state_real platform sandbox_bin profile
  project_real=$(cd "$project" 2>/dev/null && pwd -P) || return 1
  scratch_real=$(cd "$scratch" 2>/dev/null && pwd -P) || return 1
  report_real=$(cd "$report" 2>/dev/null && pwd -P) || return 1
  state_real=$(cd "$state" 2>/dev/null && pwd -P) || return 1
  case "$report_real" in
    "$project_real")
      echo "error: reader report directory cannot be the project root; refusing to launch without process-level write confinement" >&2
      return 1
      ;;
  esac
  case "$state_real" in
    "$project_real")
      echo "error: reader state directory cannot be the project root; refusing to launch without process-level write confinement" >&2
      return 1
      ;;
  esac
  platform=$(uname -s)
  case "$platform" in
    Darwin)
      sandbox_bin=$(command -v sandbox-exec 2>/dev/null || true)
      [ -n "$sandbox_bin" ] || {
        echo "error: sandbox-exec is required for reader process confinement on macOS; refusing to launch" >&2
        return 1
      }
      profile='(version 1)(allow default)(deny file-write* (subpath (param "PROJECT")))(allow file-write* (subpath (param "SCRATCH")))(allow file-write* (subpath (param "REPORT")))(allow file-write* (subpath (param "STATE")))'
      "$sandbox_bin" -D "PROJECT=$project_real" -D "SCRATCH=$scratch_real" \
        -D "REPORT=$report_real" -D "STATE=$state_real" -p "$profile" /usr/bin/true >/dev/null 2>&1 || {
        echo "error: sandbox-exec could not establish reader process confinement; refusing to launch" >&2
        return 1
      }
      ;;
    Linux)
      sandbox_bin=$(command -v bwrap 2>/dev/null || true)
      [ -n "$sandbox_bin" ] || {
        echo "error: bwrap is required for reader process confinement on Linux; refusing to launch" >&2
        return 1
      }
      "$sandbox_bin" --die-with-parent --cap-drop ALL --bind / / --dev-bind /dev /dev \
        --ro-bind "$project_real" "$project_real" -- /bin/true >/dev/null 2>&1 || {
        echo "error: bwrap could not establish reader process confinement; refusing to launch" >&2
        return 1
      }
      ;;
    *)
      echo "error: reader process confinement is unsupported on $platform; refusing to launch" >&2
      return 1
      ;;
  esac
  # shellcheck disable=SC2034 # Output global consumed by scripts sourcing this library.
  FM_READER_SANDBOX_PLATFORM=$platform
  # shellcheck disable=SC2034 # Output global consumed by scripts sourcing this library.
  FM_READER_SANDBOX_BIN=$sandbox_bin
  # shellcheck disable=SC2034 # Output global consumed by scripts sourcing this library.
  FM_READER_SANDBOX_PROFILE=${profile:-}
  # shellcheck disable=SC2034 # Output global consumed by scripts sourcing this library.
  FM_READER_REPORT_DIR=$report_real
  # shellcheck disable=SC2034 # Output global consumed by scripts sourcing this library.
  FM_READER_STATE_DIR=$state_real
}
