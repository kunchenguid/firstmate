#!/usr/bin/env bash
# Turn captured UI screenshots into PR-embeddable markdown by uploading them as
# GitHub *release assets* and printing image markdown that renders inline in a
# pull request or issue body. It serves both delivery paths: a direct-PR
# crewmate folds the printed markdown into its own `gh-axi pr create
# --body-file`, while for a no-mistakes PR the crewmate produces the markdown
# during its turn and firstmate appends it to the opened PR body with `embed`.
#
# Why release assets (empirical record and versions in docs/pr-screenshots.md):
# GitHub renders ![](https://github.com/<o>/<r>/releases/download/<tag>/<file>)
# as a direct inline <img>, and browsers decode and paint the bytes even though
# GitHub serves the asset as application/octet-stream with an attachment
# disposition. Assets live in GitHub release storage, NOT the git object store,
# so nothing bloats the code branches or main history, no new repo or external
# host is needed, and the upload works with a normal `repo`-scoped token (no
# browser session, unlike GitHub's web user-attachments upload).
#
# Modes:
#   fm-pr-screenshots.sh [options] <image>...
#       Upload each image as a release asset under a dedicated prerelease and
#       print PR-embeddable markdown to stdout.
#       --repo <owner/repo>  target repo (default: parsed from the cwd git
#                            `origin` remote)
#       --tag <tag>          release holding the assets (default: fm-pr-assets)
#       --namespace <ns>     asset-filename prefix keeping assets unique across
#                            tasks (default: sanitized current git branch, e.g.
#                            fm/<id> -> fm-<id>)
#       --title <text>       markdown section heading (default: Screenshots)
#       --no-heading         emit only the image lines, no heading
#       --dry-run            skip all network; print the exact markdown built
#                            from deterministic release-download URLs
#
#   fm-pr-screenshots.sh embed [--dry-run] <pr-url> <markdown-file>
#       Append <markdown-file> to the PR's current body (fetch body, concatenate,
#       `gh-axi pr edit --body-file`). Idempotent: skips if the marker is already
#       in the body. --dry-run prints the composed body instead of editing.
#
# The download URL is fully deterministic from (owner, repo, tag, asset-name),
# so --dry-run prints byte-identical markdown to a live run without uploading.
# Uploads and PR-body edits are project writes, so a crewmate (never firstmate)
# runs the upload mode; firstmate runs only `embed`, a PR-body edit that is part
# of its normal PR handling.
set -eu

MARKER='<!-- fm-pr-screenshots -->'

usage() {
  # Lines 2-42 are the header comment block; line 43 begins the code (set -eu).
  sed -n '2,42p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# Collapse anything outside the GitHub-safe asset-name set to a single dash.
sanitize() {
  printf '%s' "$1" | LC_ALL=C sed 's/[^A-Za-z0-9._-]/-/g'
}

# Parse owner/repo from the cwd git `origin` remote, ssh or https form.
derive_repo() {
  local url
  url=$(git remote get-url origin 2>/dev/null) || return 1
  url=${url%.git}
  case "$url" in
    git@github.com:*)          printf '%s\n' "${url#git@github.com:}" ;;
    ssh://git@github.com/*)    printf '%s\n' "${url#ssh://git@github.com/}" ;;
    https://github.com/*)      printf '%s\n' "${url#https://github.com/}" ;;
    *) return 1 ;;
  esac
}

parse_pr_url() {
  local url=$1
  if [[ "$url" =~ ^https://github\.com/([A-Za-z0-9][A-Za-z0-9-]{0,38})/([A-Za-z0-9._-]+)/pull/([0-9]+)/?$ ]] \
     && [[ "${BASH_REMATCH[1]}" != *- ]]; then
    PR_OWNER="${BASH_REMATCH[1]}"
    PR_REPO="${BASH_REMATCH[2]}"
    PR_NUMBER="${BASH_REMATCH[3]}"
    return 0
  fi
  echo "error: PR URL must match https://github.com/<owner>/<repo>/pull/<number> (got: $url)" >&2
  return 1
}

embed_mode() {
  local dry=0
  if [ "${1:-}" = --dry-run ]; then dry=1; shift; fi
  local pr_url=${1:-} md_file=${2:-}
  if [ -z "$pr_url" ] || [ -z "$md_file" ]; then
    echo "usage: fm-pr-screenshots.sh embed [--dry-run] <pr-url> <markdown-file>" >&2
    exit 2
  fi
  [ -f "$md_file" ] || { echo "error: markdown file not found: $md_file" >&2; exit 1; }
  parse_pr_url "$pr_url" || exit 1

  # Distinguish a genuinely empty body (read succeeds, empty string) from a
  # failed read (network or rate limit). Swallowing the failure would let an
  # empty `current` overwrite the whole PR description with just the block.
  local current
  if ! current=$(gh pr view "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" --json body -q .body 2>/dev/null); then
    echo "error: could not read the current body of $PR_OWNER/$PR_REPO#$PR_NUMBER (network or rate limit?); refusing to overwrite the PR body" >&2
    exit 1
  fi
  if printf '%s' "$current" | grep -qF "$MARKER"; then
    echo "already embedded (marker present in PR body); nothing to do" >&2
    return 0
  fi

  local body_file
  body_file=$(mktemp)
  # Preserve the existing body, then a blank separator, then the screenshots block.
  { printf '%s' "$current"; printf '\n\n'; cat "$md_file"; } > "$body_file"
  if [ "$dry" -eq 1 ]; then
    cat "$body_file"
    rm -f "$body_file"
    return 0
  fi
  gh-axi pr edit "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" --body-file "$body_file"
  rm -f "$body_file"
}

upload_mode() {
  local repo="" tag="fm-pr-assets" namespace="" title="Screenshots" heading=1 dry=0
  local images=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo)        repo=${2:?--repo needs a value}; shift 2 ;;
      --repo=*)      repo=${1#*=}; shift ;;
      --tag)         tag=${2:?--tag needs a value}; shift 2 ;;
      --tag=*)       tag=${1#*=}; shift ;;
      --namespace)   namespace=${2:?--namespace needs a value}; shift 2 ;;
      --namespace=*) namespace=${1#*=}; shift ;;
      --title)       title=${2:?--title needs a value}; shift 2 ;;
      --title=*)     title=${1#*=}; shift ;;
      --no-heading)  heading=0; shift ;;
      --dry-run)     dry=1; shift ;;
      -h|--help)     usage; exit 0 ;;
      --)            shift; while [ $# -gt 0 ]; do images+=("$1"); shift; done ;;
      -*)            echo "error: unknown option: $1" >&2; exit 2 ;;
      *)             images+=("$1"); shift ;;
    esac
  done
  [ ${#images[@]} -gt 0 ] || { echo "error: no image files given" >&2; usage >&2; exit 2; }

  if [ -z "$repo" ]; then
    repo=$(derive_repo) || { echo "error: --repo not given and could not derive owner/repo from the cwd git origin remote" >&2; exit 1; }
  fi
  [[ "$repo" =~ ^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9._-]+$ ]] || { echo "error: --repo must be owner/repo (got: $repo)" >&2; exit 1; }

  if [ -z "$namespace" ]; then
    local branch
    branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
    if [ -n "$branch" ] && [ "$branch" != HEAD ]; then namespace=$branch; fi
  fi
  [ -n "$namespace" ] || { echo "error: --namespace not given and no current git branch to derive it from" >&2; exit 1; }
  local ns
  ns=$(sanitize "$namespace")

  local img
  for img in "${images[@]}"; do
    [ -f "$img" ] || { echo "error: image not found: $img" >&2; exit 1; }
  done

  # Stage each image under its final asset name so the upload controls the
  # asset name (and thus the URL); gh release upload names an asset after the
  # uploaded file's basename, not a #label. Refuse duplicate asset names.
  local staging
  staging=$(mktemp -d)
  # shellcheck disable=SC2064
  trap "rm -rf '$staging'" EXIT
  local staged=() lines=() seen=" "
  for img in "${images[@]}"; do
    local base asset alt url
    base=$(basename "$img")
    asset="${ns}-$(sanitize "$base")"
    case "$seen" in
      *" $asset "*) echo "error: two images map to the same asset name '$asset'; rename so basenames are unique" >&2; exit 1 ;;
    esac
    seen="$seen$asset "
    alt="${base%.*}"
    url="https://github.com/$repo/releases/download/$tag/$asset"
    cp "$img" "$staging/$asset"
    staged+=("$staging/$asset")
    lines+=("![${alt}](${url})")
  done

  if [ "$dry" -eq 0 ]; then
    if ! gh release view "$tag" --repo "$repo" >/dev/null 2>&1; then
      # Prerelease so it never claims the repo's "Latest release" slot. Tolerate
      # a concurrent creator: the upload below still lands on the now-existing release.
      gh release create "$tag" --repo "$repo" --prerelease \
        --title "Firstmate PR screenshots" \
        --notes "Automated asset store for screenshots embedded in pull requests by firstmate. Not a software release." \
        >/dev/null 2>&1 || true
    fi
    gh release upload "$tag" --repo "$repo" --clobber "${staged[@]}" >/dev/null
  fi

  if [ "$heading" -eq 1 ]; then
    printf '## %s\n\n' "$title"
  fi
  printf '%s\n' "$MARKER"
  local line
  for line in "${lines[@]}"; do
    printf '%s\n' "$line"
  done
}

case "${1:-}" in
  embed)      shift; embed_mode "$@" ;;
  -h|--help)  usage; exit 0 ;;
  *)          upload_mode "$@" ;;
esac
