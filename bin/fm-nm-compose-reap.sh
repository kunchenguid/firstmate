#!/usr/bin/env bash
# Reap Docker Compose projects left behind by vanished no-mistakes worktrees.
#
# Usage: fm-nm-compose-reap.sh
#
# The no-mistakes worktree root is derived from this checkout's local
# `no-mistakes` remote (`<data-root>/repos/<repo-id>.git`).
# FM_NM_WORKTREE_ROOT may name an explicit root for tests.
#
# A Compose project is eligible only when every container currently carrying
# that project label also carries a working-dir label below the exact
# no-mistakes worktree root, and every one of those worktrees is gone.
# Eligibility is re-read immediately before deletion so a live sibling prevents
# the whole project from being touched.
#
# Cleanup removes only the explicitly revalidated container IDs and the network
# IDs carrying that same Compose project label.
# It never runs a Docker prune and never removes volumes or images.
# Silence means there was nothing eligible or this checkout has no local
# no-mistakes worktree root.
# A successful repair prints one BOOTSTRAP_INFO line with project, container,
# and network counts; every inventory or cleanup failure prints a
# NO_MISTAKES_DOCKER diagnostic and returns nonzero.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_NM_REAP_TMP=

resolve_worktree_root() {
  local remote repos data_root
  if [ -n "${FM_NM_WORKTREE_ROOT:-}" ]; then
    [ -d "$FM_NM_WORKTREE_ROOT" ] || return 1
    (cd "$FM_NM_WORKTREE_ROOT" && pwd -P)
    return
  fi
  remote=$(git -C "$FM_ROOT" remote get-url no-mistakes 2>/dev/null) || return 1
  case "$remote" in /*/repos/*.git) ;; *) return 1 ;; esac
  repos=${remote%/*}
  [ "${repos##*/}" = repos ] || return 1
  data_root=${repos%/*}
  [ -d "$data_root/worktrees" ] || return 1
  (cd "$data_root/worktrees" && pwd -P)
}

inventory() {
  docker container ls -a \
    --filter label=com.docker.compose.project \
    --filter label=com.docker.compose.project.working_dir \
    --format '{{.ID}}\t{{.Label "com.docker.compose.project"}}\t{{.Label "com.docker.compose.project.working_dir"}}'
}

project_inventory() { # <project>
  docker container ls -a \
    --filter "label=com.docker.compose.project=$1" \
    --format '{{.ID}}\t{{.Label "com.docker.compose.project"}}\t{{.Label "com.docker.compose.project.working_dir"}}'
}

main() {
  local worktree_root tmp inventory_file candidates_file project_file network_file
  local id project project_label working_dir extra safe live project_containers project_networks
  local removed_projects=0 removed_containers=0 removed_networks=0 failures=0
  local -a ids network_ids

  command -v docker >/dev/null 2>&1 || return 0
  worktree_root=$(resolve_worktree_root) || return 0
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-nm-compose-reap.XXXXXX") || {
    printf 'NO_MISTAKES_DOCKER: could not create private inventory directory\n'
    return 1
  }
  FM_NM_REAP_TMP=$tmp
  trap 'rm -rf "$FM_NM_REAP_TMP"' EXIT
  inventory_file="$tmp/inventory"
  candidates_file="$tmp/candidates"

  if ! inventory > "$inventory_file" 2>/dev/null; then
    printf 'NO_MISTAKES_DOCKER: skipped orphan Compose sweep because Docker inventory failed\n'
    return 1
  fi
  : > "$candidates_file"
  while IFS=$'\t' read -r id project working_dir extra; do
    case "$working_dir" in
      "$worktree_root"/*)
        if [ -n "$extra" ]; then
          printf 'NO_MISTAKES_DOCKER: ignored malformed container inventory below the no-mistakes worktree root\n'
          failures=$((failures + 1))
          continue
        fi
        case "$id" in
          ''|*[!A-Fa-f0-9]*)
            printf 'NO_MISTAKES_DOCKER: ignored malformed container inventory below the no-mistakes worktree root\n'
            failures=$((failures + 1))
            continue
            ;;
        esac
        case "$project" in
          ''|*[!A-Za-z0-9_.-]*)
            printf 'NO_MISTAKES_DOCKER: ignored malformed container inventory below the no-mistakes worktree root\n'
            failures=$((failures + 1))
            continue
            ;;
        esac
        [ -d "$working_dir" ] || printf '%s\n' "$project" >> "$candidates_file"
        ;;
    esac
  done < "$inventory_file"
  LC_ALL=C sort -u "$candidates_file" -o "$candidates_file"

  while IFS= read -r project; do
    [ -n "$project" ] || continue
    project_file="$tmp/project"
    if ! project_inventory "$project" > "$project_file" 2>/dev/null; then
      printf 'NO_MISTAKES_DOCKER: project %s was not removed because revalidation failed\n' "$project"
      failures=$((failures + 1))
      continue
    fi
    safe=1
    live=0
    ids=()
    while IFS=$'\t' read -r id project_label working_dir extra; do
      [ -z "$extra" ] || { safe=0; break; }
      case "$id" in ''|*[!A-Fa-f0-9]*) safe=0; break ;; esac
      [ "$project_label" = "$project" ] || { safe=0; break; }
      case "$working_dir" in
        "$worktree_root"/*) [ ! -d "$working_dir" ] || live=1 ;;
        *) safe=0 ;;
      esac
      [ "$safe" -eq 1 ] || break
      ids+=("$id")
    done < "$project_file"
    if [ "$safe" -ne 1 ]; then
      printf 'NO_MISTAKES_DOCKER: project %s was not removed because its current container labels are unsafe\n' "$project"
      failures=$((failures + 1))
      continue
    fi
    [ "$live" -eq 0 ] || continue
    [ "$safe" -eq 1 ] && [ "${#ids[@]}" -gt 0 ] || continue

    project_containers=${#ids[@]}
    if ! docker container rm --force "${ids[@]}" >/dev/null 2>&1; then
      printf 'NO_MISTAKES_DOCKER: project %s was not fully removed because container cleanup failed\n' "$project"
      failures=$((failures + 1))
      continue
    fi
    removed_projects=$((removed_projects + 1))
    removed_containers=$((removed_containers + project_containers))

    network_file="$tmp/networks"
    if ! docker network ls --filter "label=com.docker.compose.project=$project" \
      --format '{{.ID}}' > "$network_file" 2>/dev/null; then
      printf 'NO_MISTAKES_DOCKER: project %s containers were removed but its network inventory failed\n' "$project"
      failures=$((failures + 1))
      continue
    fi
    network_ids=()
    while IFS= read -r id; do
      case "$id" in
        ''|*[!A-Fa-f0-9]*)
          printf 'NO_MISTAKES_DOCKER: project %s containers were removed but its network inventory was malformed\n' "$project"
          failures=$((failures + 1))
          continue
          ;;
      esac
      network_ids+=("$id")
    done < "$network_file"
    project_networks=${#network_ids[@]}
    if [ "$project_networks" -gt 0 ]; then
      if docker network rm "${network_ids[@]}" >/dev/null 2>&1; then
        removed_networks=$((removed_networks + project_networks))
      else
        printf 'NO_MISTAKES_DOCKER: project %s containers were removed but its network cleanup failed\n' "$project"
        failures=$((failures + 1))
      fi
    fi
  done < "$candidates_file"

  if [ "$removed_projects" -gt 0 ]; then
    printf 'BOOTSTRAP_INFO: removed %s orphaned no-mistakes Compose project(s), %s container(s), and %s network(s)\n' \
      "$removed_projects" "$removed_containers" "$removed_networks"
  fi
  [ "$failures" -eq 0 ]
}

main "$@"
