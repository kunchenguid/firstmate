#!/usr/bin/env bash
# bin/fm-project-script-lib.sh - ONE owner for the "a project opts in by
# publishing a script" contract.
#
# Some guarantees only the project can answer: whether a pooled working copy
# still has an owner (`check:worktree-custody`, bin/fm-teardown.sh), or which
# delivered copies it is safe to release back to the pool
# (`pool:release-delivered`, bin/fm-spawn.sh). Firstmate never implements those
# verdicts; it asks the project, and only when the project published one.
#
# The contract, stated once:
#   - Opt-in is presence of that exact key in any Git-proven package.json view:
#     the working file when its path exists in the index or HEAD, the index, or
#     HEAD. An untracked manifest publishes nothing. Absence is confirmed only
#     when every available published view omits the key; an unavailable
#     repository or unreadable published view is unconfirmable.
#   - The manifest, not a grep, is authoritative. A project that looks like it
#     published one but cannot be read is reported as UNCONFIRMED, and each
#     caller applies its own policy - a safety gate refuses, housekeeping warns.
#   - The runner is whichever package manager the project's own lockfile
#     selects, and extra arguments reach the script the way that manager passes
#     them (pnpm directly, npm and yarn behind `--`).
#
# Callers source this file; it defines functions only.

# shellcheck source=bin/fm-timeout-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-timeout-lib.sh"

FM_PROJECT_SCRIPT_DECLARED=0
FM_PROJECT_SCRIPT_ABSENT=1
FM_PROJECT_SCRIPT_UNCONFIRMED=2
FM_PROJECT_SCRIPT_INVALID_TIMEOUT=125
FM_PROJECT_SCRIPT_CANONICAL_UNAVAILABLE=126

fm_project_manifest_script_verdict() {  # <script>
  node -e 'const fs=require("fs"); const p=JSON.parse(fs.readFileSync(0, "utf8")); process.stdout.write(p.scripts && Object.prototype.hasOwnProperty.call(p.scripts, process.argv[1]) ? "declared" : "absent");' \
    "$1"
}

# Does <dir> publish <script>? Prints nothing.
#   0 declared, 1 absent, 2 unconfirmable.
fm_project_script_declared() {  # <dir> <script>
  local dir=$1 script=$2 verdict repo_top dir_real repo_real index_entry head_entry manifest unconfirmed=0
  [ -d "$dir" ] || return "$FM_PROJECT_SCRIPT_UNCONFIRMED"
  repo_top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) \
    || return "$FM_PROJECT_SCRIPT_UNCONFIRMED"
  dir_real=$(cd "$dir" 2>/dev/null && pwd -P) \
    || return "$FM_PROJECT_SCRIPT_UNCONFIRMED"
  repo_real=$(cd "$repo_top" 2>/dev/null && pwd -P) \
    || return "$FM_PROJECT_SCRIPT_UNCONFIRMED"
  [ "$dir_real" = "$repo_real" ] || return "$FM_PROJECT_SCRIPT_UNCONFIRMED"
  git -C "$dir" rev-parse --verify HEAD >/dev/null 2>&1 \
    || return "$FM_PROJECT_SCRIPT_UNCONFIRMED"
  index_entry=$(git -C "$dir" ls-files --stage -- package.json 2>/dev/null) \
    || return "$FM_PROJECT_SCRIPT_UNCONFIRMED"
  head_entry=$(git -C "$dir" ls-tree --name-only HEAD -- package.json 2>/dev/null) \
    || return "$FM_PROJECT_SCRIPT_UNCONFIRMED"
  [ -n "$index_entry" ] || [ -n "$head_entry" ] \
    || return "$FM_PROJECT_SCRIPT_ABSENT"
  command -v node >/dev/null 2>&1 || return "$FM_PROJECT_SCRIPT_UNCONFIRMED"

  if [ -e "$dir/package.json" ] || [ -L "$dir/package.json" ]; then
    if [ -f "$dir/package.json" ] && [ ! -L "$dir/package.json" ]; then
      if verdict=$(fm_project_manifest_script_verdict "$script" < "$dir/package.json" 2>/dev/null); then
        case "$verdict" in
          declared) return "$FM_PROJECT_SCRIPT_DECLARED" ;;
          absent) ;;
          *) unconfirmed=1 ;;
        esac
      else
        unconfirmed=1
      fi
    else
      unconfirmed=1
    fi
  fi

  if [ -n "$index_entry" ]; then
    if manifest=$(git -C "$dir" show :package.json 2>/dev/null) \
      && verdict=$(printf '%s' "$manifest" | fm_project_manifest_script_verdict "$script" 2>/dev/null); then
      case "$verdict" in
        declared) return "$FM_PROJECT_SCRIPT_DECLARED" ;;
        absent) ;;
        *) unconfirmed=1 ;;
      esac
    else
      unconfirmed=1
    fi
  fi

  if [ -n "$head_entry" ]; then
    if manifest=$(git -C "$dir" show HEAD:package.json 2>/dev/null) \
      && verdict=$(printf '%s' "$manifest" | fm_project_manifest_script_verdict "$script" 2>/dev/null); then
      case "$verdict" in
        declared) return "$FM_PROJECT_SCRIPT_DECLARED" ;;
        absent) ;;
        *) unconfirmed=1 ;;
      esac
    else
      unconfirmed=1
    fi
  fi

  [ "$unconfirmed" -eq 0 ] || return "$FM_PROJECT_SCRIPT_UNCONFIRMED"
  return "$FM_PROJECT_SCRIPT_ABSENT"
}

fm_project_script_manager() {  # <dir>
  local dir=$1
  if [ -f "$dir/pnpm-lock.yaml" ]; then printf 'pnpm\n'
  elif [ -f "$dir/yarn.lock" ]; then printf 'yarn\n'
  else printf 'npm\n'
  fi
}

fm_project_script_timeout_valid() {  # <seconds>
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    *[1-9]*) return 0 ;;
    *) return 1 ;;
  esac
}

# Run <dir>'s <script> with <timeout> seconds and any extra arguments,
# preserving its stdout, stderr, and exit status. Exit 127 means the selected
# package manager is not installed, which no caller may read as a verdict.
fm_project_script_run() {  # <dir> <script> <timeout> [args...]
  local dir=$1 script=$2 timeout_secs=$3 manager
  shift 3
  fm_project_script_timeout_valid "$timeout_secs" \
    || return "$FM_PROJECT_SCRIPT_INVALID_TIMEOUT"
  manager=$(fm_project_script_manager "$dir")
  command -v "$manager" >/dev/null 2>&1 || return 127
  local -a argv
  argv=("$manager" run "$script")
  if [ "$#" -gt 0 ]; then
    # pnpm forwards trailing arguments to the script; npm and yarn need `--`.
    [ "$manager" = pnpm ] || argv+=(--)
    argv+=("$@")
  fi
  ( cd "$dir" && fm_run_timed "$timeout_secs" "${argv[@]}" )
}

fm_project_script_run_canonical_head() (  # <dir> <script> <timeout> [args...]
  local dir=$1 script=$2 timeout_secs=$3 head manifest verdict git_dir tmp_root archive source rc=0
  shift 3
  fm_project_script_timeout_valid "$timeout_secs" \
    || return "$FM_PROJECT_SCRIPT_INVALID_TIMEOUT"
  [ -d "$dir" ] || return "$FM_PROJECT_SCRIPT_CANONICAL_UNAVAILABLE"
  head=$(git -C "$dir" rev-parse --verify 'HEAD^{commit}' 2>/dev/null) \
    || return "$FM_PROJECT_SCRIPT_CANONICAL_UNAVAILABLE"
  manifest=$(git -C "$dir" show "$head:package.json" 2>/dev/null) \
    || return "$FM_PROJECT_SCRIPT_CANONICAL_UNAVAILABLE"
  verdict=$(printf '%s' "$manifest" | fm_project_manifest_script_verdict "$script" 2>/dev/null) \
    || return "$FM_PROJECT_SCRIPT_CANONICAL_UNAVAILABLE"
  [ "$verdict" = declared ] || return "$FM_PROJECT_SCRIPT_CANONICAL_UNAVAILABLE"
  command -v tar >/dev/null 2>&1 || return "$FM_PROJECT_SCRIPT_CANONICAL_UNAVAILABLE"
  git_dir=$(git -C "$dir" rev-parse --absolute-git-dir 2>/dev/null) \
    || return "$FM_PROJECT_SCRIPT_CANONICAL_UNAVAILABLE"
  [ -d "$git_dir" ] || return "$FM_PROJECT_SCRIPT_CANONICAL_UNAVAILABLE"
  tmp_root=$(mktemp -d "$git_dir/fm-project-script.XXXXXX") \
    || return "$FM_PROJECT_SCRIPT_CANONICAL_UNAVAILABLE"
  trap 'rm -rf -- "$tmp_root"' EXIT
  trap 'exit "$FM_PROJECT_SCRIPT_CANONICAL_UNAVAILABLE"' HUP INT TERM
  archive="$tmp_root/source.tar"
  source="$tmp_root/source"
  mkdir "$source" || return "$FM_PROJECT_SCRIPT_CANONICAL_UNAVAILABLE"
  git -C "$dir" archive --format=tar --output="$archive" "$head" 2>/dev/null \
    || return "$FM_PROJECT_SCRIPT_CANONICAL_UNAVAILABLE"
  tar -xf "$archive" -C "$source" 2>/dev/null \
    || return "$FM_PROJECT_SCRIPT_CANONICAL_UNAVAILABLE"
  rm -f -- "$archive" || return "$FM_PROJECT_SCRIPT_CANONICAL_UNAVAILABLE"
  if [ -d "$dir/node_modules" ] && [ ! -e "$source/node_modules" ]; then
    ln -s "$dir/node_modules" "$source/node_modules" \
      || return "$FM_PROJECT_SCRIPT_CANONICAL_UNAVAILABLE"
  fi
  fm_project_script_run "$source" "$script" "$timeout_secs" "$@" || rc=$?
  return "$rc"
)
