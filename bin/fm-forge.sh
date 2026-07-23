#!/usr/bin/env bash
# Provider-neutral forge helper for repository detection and PR operations.
# Canonical identity is owned by bin/fm-pr-lib.sh; provider dispatch and all
# Gitea HTTP/auth mechanics are owned by bin/fm-forge-lib.sh.
#
# Gitea uses private config/gitea and config/gitea-token files under the
# effective FirstMate config directory. docs/configuration.md owns their exact
# schema, permission checks, origin binding, and token-custody contract.
#
# Usage:
#   fm-forge.sh provider <repository-dir>
#   fm-forge.sh canonical-repo <repository-dir>
#   fm-forge.sh pr-create <repository-dir> --head <branch> --base <branch>
#     --title <title> [--body <text> | --body-file <path>]
#   fm-forge.sh pr-state <canonical-pr-url>
#   fm-forge.sh pr-head <canonical-pr-url>
#   fm-forge.sh pr-merged <canonical-pr-url>
#   fm-forge.sh pr-reviews <canonical-gitea-pr-url>
#   fm-forge.sh pr-checks <canonical-gitea-pr-url>
#
# pr-create uses gh-axi for GitHub, glab for GitLab, and the authenticated API
# client for configured Gitea repositories. It prints the forge's canonical PR
# URL on success and stops on an unsupported or ambiguous response.
# Merge is intentionally absent: all task PR merges must go through
# bin/fm-pr-merge.sh's approval-recording path.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-forge-lib.sh
. "$SCRIPT_DIR/fm-forge-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  echo "error: ${FM_FORGE_ERROR:-forge operation failed}" >&2
  exit 1
}

command_name=${1:-}
case "$command_name" in
  -h|--help) usage; exit 0 ;;
  provider|canonical-repo)
    [ "$#" -eq 2 ] || { usage >&2; exit 2; }
    fm_forge_repo_from_dir "$2" || fail
    if [ "$command_name" = provider ]; then
      printf '%s\n' "$FM_FORGE_REPO_PROVIDER"
    else
      printf '%s\n' "$FM_FORGE_REPO_URL"
    fi
    ;;
  pr-state|pr-head|pr-merged|pr-reviews|pr-checks)
    [ "$#" -eq 2 ] || { usage >&2; exit 2; }
    case "$command_name" in
      pr-state) fm_forge_pr_state "$2" || fail ;;
      pr-head) fm_forge_pr_head "$2" || fail ;;
      pr-merged) fm_forge_pr_merged "$2" || fail ;;
      pr-reviews) fm_forge_gitea_pr_reviews "$2" || fail ;;
      pr-checks) fm_forge_gitea_pr_checks "$2" || fail ;;
    esac
    ;;
  pr-create)
    [ "$#" -ge 2 ] || { usage >&2; exit 2; }
    repo_dir=$2
    shift 2
    head=''
    base=''
    title=''
    body=''
    body_file=''
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --head|--base|--title|--body|--body-file)
          [ "$#" -ge 2 ] || { usage >&2; exit 2; }
          case "$1" in
            --head) head=$2 ;;
            --base) base=$2 ;;
            --title) title=$2 ;;
            --body) body=$2 ;;
            --body-file) body_file=$2 ;;
          esac
          shift 2
          ;;
        *) usage >&2; exit 2 ;;
      esac
    done
    [ -n "$head" ] && [ -n "$base" ] && [ -n "$title" ] \
      || { usage >&2; exit 2; }
    [ -z "$body" ] || [ -z "$body_file" ] \
      || { echo "error: --body and --body-file are mutually exclusive" >&2; exit 2; }
    if [ -n "$body_file" ]; then
      [ -f "$body_file" ] && [ ! -L "$body_file" ] \
        || { echo "error: PR body file is unavailable" >&2; exit 1; }
      body=$(cat "$body_file") || { echo "error: PR body file cannot be read" >&2; exit 1; }
    fi
    fm_forge_repo_from_dir "$repo_dir" || fail
    case "$FM_FORGE_REPO_PROVIDER" in
      github)
        (cd "$repo_dir" && gh-axi pr create --head "$head" --base "$base" --title "$title" --body "$body")
        ;;
      gitlab)
        command -v glab >/dev/null 2>&1 || { FM_FORGE_ERROR="GitLab PR creation requires glab"; fail; }
        glab mr create -R "$FM_FORGE_REPO_URL" --source-branch "$head" \
          --target-branch "$base" --title "$title" --description "$body" --yes
        ;;
      gitea) fm_forge_gitea_pr_create "$repo_dir" "$head" "$base" "$title" "$body" || fail ;;
      *) FM_FORGE_ERROR="repository provider is unsupported"; fail ;;
    esac
    ;;
  *) usage >&2; exit 2 ;;
esac
