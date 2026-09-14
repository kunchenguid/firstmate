# shellcheck shell=bash
# The recorded task-launch base: the branch every fresh Firstmate ship or scout
# worktree for one project is reset to before its worker branches.
#
# It exists for repositories whose integration branch is not their default
# branch (default main, integration dev): without a recorded base, every fresh
# worktree is reset to origin's default branch, so the pull request a worker
# opens is based on the wrong branch and conflicts with the integration branch.
#
# One file, one owner. Under a home's config directory,
# config/project-base-<project-name> holds exactly one token, the branch name,
# where <project-name> is the project directory's own basename - the same value
# bin/fm-spawn.sh derives and bin/fm-brief.sh receives as its repo argument.
# bin/fm-brief.sh describes the intended base in its Setup statement; the brief
# never sets the base. See docs/configuration.md "Task launch base" for spawn's
# resolution order and .agents/skills/project-management/SKILL.md for intake.
#
# Usage: . bin/fm-project-base-lib.sh
#
# fm_project_base_read <file>:
#   status 0, a branch name on stdout - the recorded base, trimmed
#   status 0, empty stdout            - the file is absent or blank, so the
#                                       caller falls through to its own default
#   status 1, an error on stderr      - the file is present but unusable, so the
#                                       caller refuses instead of guessing
# A blank first token is read as absence rather than as a branch, and any second
# nonblank line or embedded whitespace is refused, so a malformed file is never
# silently truncated into a real branch name.
fm_project_base_read() {  # <file>
  local file=$1 value
  if [ ! -e "$file" ] && [ ! -L "$file" ]; then
    return 0
  fi
  if [ ! -f "$file" ]; then
    echo "error: $file must be a readable regular file holding one branch name" >&2
    return 1
  fi
  value=$(sed -n 's/^[[:space:]]*//; s/[[:space:]]*$//; /^$/d; p' "$file" 2>/dev/null) || {
    echo "error: could not read the recorded launch base from $file" >&2
    return 1
  }
  case $value in
    '') return 0 ;;
    *[[:space:]]*)
      echo "error: $file must hold one branch name, not '$value'" >&2
      return 1
      ;;
  esac
  printf '%s\n' "$value"
}
