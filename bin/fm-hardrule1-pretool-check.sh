#!/usr/bin/env bash
# AGY (Antigravity CLI) PreToolUse gate for Hard Rule 1: firstmate never writes
# to `projects/`.
#
# Registered in the tracked .agents/hooks.json under the "PreToolUse" event with
# the matcher `write_to_file|replace_file_content|multi_replace_file_content|run_command`.
# AGY sends the tool call as JSON on stdin (`toolCall.name` + `toolCall.args`,
# camelCase) and reads exactly one decision object from stdout; the exit status
# is not a decision channel on AGY, so this script always exits 0 and always
# prints a decision object:
#   deny  {"decision":"deny","reason":"Hard Rule 1: Firstmate is strictly
#          forbidden from directly editing projects/."}
#   allow {"decision":"allow"}
#
# Enforced surface (Phase 1, documented in references/harness/agy.md):
#   1. write-tool targets: every target path carried by
#      write_to_file / replace_file_content / multi_replace_file_content -
#      `TargetFile` (and the Filepath/FilePath/file_path spellings) anywhere
#      inside toolCall.args, including the per-operation objects nested in a
#      multi-edit - resolved against the command cwd when relative.
#   2. run_command working directory: `Cwd` (or cwd / WorkingDirectory) inside
#      toolCall.args, else the payload's workspacePaths[0], else the checkout
#      root. A command whose working directory lies under `projects/` is a
#      state-changing command under `projects/` - its effects land in the clone.
#   Free-form shell path arguments on the CommandLine are deliberately out of
#   scope: firstmate's own guarded scripts legitimately reference projects/
#   paths from the home (git -C projects/... sync and refresh), and the model's
#   file mutation path is the write tools, which ARE enforced.
#
# Paths are compared lexically (collapsed slashes, `.` and `..` segments) with
# no symlink resolution, the same granularity as the other tracked seatbelts.
# Deny fires when the resolved target equals <home>/projects or sits below it;
# the guard is inert (allow) when the checkout has no projects/ directory at
# all, which is also what makes it a silent no-op in task worktrees.
#
# Captain-approved escape: FM_ALLOW_PROJECTS_WRITE=1 in the hook environment
# deliberately allows everything, mirroring FM_ALLOW_SUBAGENT=1 in
# bin/fm-subagent-pretool-check.sh. Only a concrete, current captain approval
# for a specific project operation should set it.
#
# Fail-open: empty or malformed stdin, a missing jq, or an unresolvable target
# always allow, exactly like every other tracked PreToolUse seatbelt - a broken
# transport must never block the whole session on uncertainty.
#
# Usage:
#   <PreToolUse JSON on stdin> | bin/fm-hardrule1-pretool-check.sh
set -u

allow() {
  printf '{"decision":"allow"}\n'
  exit 0
}

deny() {
  printf '{"decision":"deny","reason":"Hard Rule 1: Firstmate is strictly forbidden from directly editing projects/."}\n'
  exit 0
}

PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || allow
command -v jq >/dev/null 2>&1 || allow
[ "${FM_ALLOW_PROJECTS_WRITE:-}" = "1" ] && allow

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
PROJECTS="$FM_ROOT/projects"
[ -d "$PROJECTS" ] || allow

# Lexical path normalization: absolute path -> collapsed form with the working
# directory prefix; "." and ".." segments resolved textually; runs of slashes
# collapsed. Prints the normalized path or nothing on failure.
norm_abs() {  # <path> <base>
  local raw=$1 base=$2 out='' seg rest
  case "$base" in /*) ;; *) return 1 ;; esac
  case "$raw" in
    "" ) return 1 ;;
    "~" | "~"/*) raw="${HOME:-}/"${raw#"~"} ;;
  esac
  case "$raw" in
    /*) rest=$raw ;;
    *) rest="$base/$raw" ;;
  esac
  case "$rest" in /*) ;; *) return 1 ;; esac
  rest=${rest#/}
  while [ -n "$rest" ]; do
    seg=${rest%%/*}
    case "$rest" in
      */*) rest=${rest#*/} ;;
      *) rest='' ;;
    esac
    case "$seg" in
      ''|.) ;;
      ..)
        out=${out%/*}
        ;;
      *) out="$out/$seg" ;;
    esac
  done
  [ -n "$out" ] || out=/
  printf '%s\n' "$out"
}

# True when normalized path $1 equals $2 or sits lexically below it.
path_is_under() {  # <norm-path> <norm-prefix>
  local p=$1 prefix=$2
  [ "$p" = "$prefix" ] && return 0
  case "$p" in
    "$prefix"/*) return 0 ;;
  esac
  return 1
}

PROJECTS_NORM=$(norm_abs "$PROJECTS" /) || allow
CWD_NORM="$FM_ROOT"

# Resolve the command working directory (run_command only).
resolve_cwd() {
  local cwd
  cwd=$(printf '%s' "$PAYLOAD" | jq -r '
    .toolCall.args.Cwd // .toolCall.args.cwd // .toolCall.args.WorkingDirectory
    // .workspacePaths[0] // empty
  ' 2>/dev/null) || cwd=
  case "$cwd" in
    ""|null) cwd=$FM_ROOT ;;
  esac
  CWD_NORM=$(norm_abs "$cwd" "$FM_ROOT")
  [ -n "$CWD_NORM" ] || CWD_NORM=$FM_ROOT
}

TOOL=$(printf '%s' "$PAYLOAD" | jq -r '.toolCall.name // empty' 2>/dev/null) || TOOL=
case "$TOOL" in
  '') allow ;;
esac
TOOL=$(printf '%s' "$TOOL" | tr '[:upper:]' '[:lower:]')

case "$TOOL" in
  write_to_file|replace_file_content|multi_replace_file_content)
    # Every target carried anywhere inside the write tool's args: the top-level
    # TargetFile and its Filepath/FilePath/file_path spellings, plus the
    # per-operation targets nested in a multi-edit. Resolve each against the
    # command cwd; deny when any lands under projects/.
    resolve_cwd
    TARGETS=$(printf '%s' "$PAYLOAD" | jq -r '
      [.. | objects
        | (.TargetFile // .Filepath // .FilePath // .file_path // empty)
        | select(type == "string" and length > 0)] | unique[]
    ' 2>/dev/null) || TARGETS=
    if [ -n "$TARGETS" ]; then
      while IFS= read -r target; do
        [ -n "$target" ] || continue
        norm=$(norm_abs "$target" "${CWD_NORM:-$FM_ROOT}") || continue
        path_is_under "$norm" "$PROJECTS_NORM" && deny
      done <<EOF
$TARGETS
EOF
    fi
    allow
    ;;
  run_command)
    resolve_cwd
    path_is_under "$CWD_NORM" "$PROJECTS_NORM" && deny
    allow
    ;;
  *)
    allow
    ;;
esac
