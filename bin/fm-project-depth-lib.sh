#!/usr/bin/env bash
# Shared shallow-project detection and repair for startup fleet refreshes and
# fresh worker spawns.
#
# fm_project_unshallow_if_needed <project-dir>
#   Prints nothing and returns 0 when the repository is already complete.
#   When shallow, fetches the missing history from origin, verifies the shallow
#   marker cleared, then prints "unshallowed repository history (N -> M commits)".
#   On inspection or repair failure, prints one concise reason and returns 1.

fm_project_depth_first_line() {  # <text>
  printf '%s\n' "$1" | sed -n '1s/[[:space:]]\{1,\}/ /g;1p'
}

fm_project_depth_count() {  # <project-dir>
  local project=$1 ref branch
  ref=$(git -C "$project" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -z "$ref" ]; then
    for branch in main master; do
      if git -C "$project" rev-parse --verify --quiet "origin/$branch^{commit}" >/dev/null; then
        ref="origin/$branch"
        break
      fi
    done
  fi
  [ -n "$ref" ] || ref=HEAD
  git -C "$project" rev-list --count "$ref" 2>/dev/null || printf 'unknown\n'
}

fm_project_unshallow_if_needed() {  # <project-dir>
  local project=$1 shallow before after fetch_output inspect_output
  if ! inspect_output=$(git -C "$project" rev-parse --is-shallow-repository 2>&1); then
    printf 'could not inspect repository depth: %s\n' "$(fm_project_depth_first_line "$inspect_output")"
    return 1
  fi
  shallow=$(fm_project_depth_first_line "$inspect_output")
  case "$shallow" in
    false) return 0 ;;
    true) ;;
    *)
      printf 'could not inspect repository depth: unexpected git result %s\n' "$shallow"
      return 1
      ;;
  esac

  before=$(fm_project_depth_count "$project")
  # This repair is safe to run automatically: it only adds the missing history
  # objects, does not touch the worktree, move local branches, or discard
  # anything, and the shallow check makes repeated runs idempotent.
  if ! fetch_output=$(git -C "$project" fetch --unshallow origin 2>&1); then
    # Another concurrent additive repair may have won the race after our check.
    # Treat that as success only when Git now proves the repository is complete.
    if [ "$(git -C "$project" rev-parse --is-shallow-repository 2>/dev/null || true)" != false ]; then
      printf 'could not unshallow repository history at %s commits: %s\n' \
        "$before" "$(fm_project_depth_first_line "$fetch_output")"
      return 1
    fi
  fi
  if [ "$(git -C "$project" rev-parse --is-shallow-repository 2>/dev/null || true)" != false ]; then
    printf 'unshallow fetch finished but the repository is still shallow at %s commits\n' "$before"
    return 1
  fi
  after=$(fm_project_depth_count "$project")
  printf 'unshallowed repository history (%s -> %s commits)\n' "$before" "$after"
}
