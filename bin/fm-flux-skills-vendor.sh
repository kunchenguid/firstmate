#!/usr/bin/env bash
# fm-flux-skills-vendor.sh - refresh the pinned fluxcd/agent-skills vendor tree.
#
# Maintainer-only: clones upstream at a verified tag, copies only the adopted
# skills, records identity and per-file checksums, and refuses excluded skills.
# Routine CI verifies the committed tree with fm-flux-skills-verify.sh instead.
#
# Usage:
#   fm-flux-skills-vendor.sh [--tag <tag>] [--dry-run]
#
# Defaults:
#   --tag v0.2.0
#
# Environment:
#   FM_FLUX_SKILLS_VENDOR_TMP   optional temp parent for the clone
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
VENDOR_ROOT="$ROOT/skills/vendor/fluxcd-agent-skills"
SOURCE_REPO=fluxcd/agent-skills
SOURCE_URL=https://github.com/fluxcd/agent-skills
LICENSE=Apache-2.0
ADOPTED_SKILLS=(gitops-knowledge gitops-repo-audit)
EXCLUDED_SKILLS=(gitops-cluster-debug)
TAG=v0.2.0
DRY_RUN=0

usage() {
  cat <<'EOF'
fm-flux-skills-vendor.sh - refresh the pinned fluxcd/agent-skills vendor tree.

Usage:
  fm-flux-skills-vendor.sh [--tag <tag>] [--dry-run]

Options:
  --tag <tag>   upstream git tag to adopt (default: v0.2.0)
  --dry-run     verify upstream identity and print actions without writing
EOF
}

die() {
  printf 'fm-flux-skills-vendor: %s\n' "$1" >&2
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --tag)
      [ $# -ge 2 ] || die '--tag requires a value'
      TAG=$2
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

command -v git >/dev/null 2>&1 || die 'git is required'
command -v gh >/dev/null 2>&1 || die 'gh is required for upstream identity checks'

full_name=$(gh api "repos/$SOURCE_REPO" --jq '.full_name')
[ "$full_name" = "$SOURCE_REPO" ] || die "upstream identity mismatch: expected $SOURCE_REPO, got $full_name"

commit=$(gh api "repos/$SOURCE_REPO/git/ref/tags/$TAG" --jq '.object.sha' 2>/dev/null || true)
if [ -z "$commit" ]; then
  die "tag $TAG not found on $SOURCE_REPO"
fi
if [ "$(gh api "repos/$SOURCE_REPO/git/tags/$commit" --jq '.object.type' 2>/dev/null || true)" = commit ]; then
  commit=$(gh api "repos/$SOURCE_REPO/git/tags/$commit" --jq '.object.sha')
fi

license=$(gh api --method GET "repos/$SOURCE_REPO/license" -f "ref=$commit" --jq '.license.spdx_id // empty')
[ "$license" = "$LICENSE" ] || die "upstream license mismatch at $commit: expected $LICENSE, got ${license:-<none>}"

tmp_parent=${FM_FLUX_SKILLS_VENDOR_TMP:-$(mktemp -d)}
cleanup() {
  [ -n "${clone_dir:-}" ] && [ -d "$clone_dir" ] && rm -rf "$clone_dir"
}
trap cleanup EXIT
clone_dir=$(mktemp -d "$tmp_parent/fm-flux-skills-vendor.XXXXXX")
git clone --depth 1 --branch "$TAG" "$SOURCE_URL.git" "$clone_dir" >/dev/null 2>&1 \
  || die "failed to clone $SOURCE_URL at tag $TAG"

actual_commit=$(git -C "$clone_dir" rev-parse HEAD)
[ "$actual_commit" = "$commit" ] || die "tag $TAG resolves to $commit, clone HEAD is $actual_commit"

for skill in "${ADOPTED_SKILLS[@]}"; do
  [ -d "$clone_dir/skills/$skill" ] || die "adopted skill missing upstream: $skill"
  symlink=$(find "$clone_dir/skills/$skill" -type l -print -quit)
  [ -z "$symlink" ] || die "adopted skill contains a symbolic link: ${symlink#"$clone_dir/skills/"}"
done
[ -f "$clone_dir/LICENSE" ] || die 'upstream LICENSE is missing'
[ ! -L "$clone_dir/LICENSE" ] || die 'upstream LICENSE is a symbolic link'

if [ "$DRY_RUN" -eq 1 ]; then
  printf 'dry-run: would vendor %s at %s (%s)\n' "$SOURCE_REPO" "$TAG" "$commit"
  printf 'dry-run: adopted skills: %s\n' "${ADOPTED_SKILLS[*]}"
  exit 0
fi

mkdir -p "$VENDOR_ROOT"
cp "$clone_dir/LICENSE" "$VENDOR_ROOT/LICENSE"
for skill in "${ADOPTED_SKILLS[@]}"; do
  rm -rf "${VENDOR_ROOT:?}/$skill"
  cp -a "$clone_dir/skills/$skill" "$VENDOR_ROOT/$skill"
done

for skill in "${EXCLUDED_SKILLS[@]}"; do
  rm -rf "${VENDOR_ROOT:?}/$skill"
done

cat >"$VENDOR_ROOT/MANIFEST" <<EOF
source_repo=$SOURCE_REPO
source_url=$SOURCE_URL
license=$LICENSE
upstream_tag=$TAG
upstream_commit=$commit
adopted_skills=${ADOPTED_SKILLS[*]}
excluded_skills=${EXCLUDED_SKILLS[*]}
EOF

{
  printf '# SHA-256 checksums for skills/vendor/fluxcd-agent-skills\n'
  (
    cd "$VENDOR_ROOT"
    find LICENSE "${ADOPTED_SKILLS[@]}" -type f | LC_ALL=C sort | while IFS= read -r relpath; do
      sha256sum "$relpath"
    done
  ) | awk '{print $1 "  " $2}'
} >"$VENDOR_ROOT/CHECKSUMS.sha256"

cat >"$VENDOR_ROOT/NOTICE.md" <<EOF
# Third-party notice: fluxcd/agent-skills

This directory vendors a subset of the official Flux CD agent skills from
[$SOURCE_REPO]($SOURCE_URL) at tag \`$TAG\` (commit \`$commit\`).

- License: $LICENSE
- Adopted skills: ${ADOPTED_SKILLS[*]}
- Excluded skills: ${EXCLUDED_SKILLS[*]} (not installed or exposed by firstmate)

Retain this notice and the upstream license when refreshing the vendor tree.
The authoritative adoption record is \`MANIFEST\`; routine verification uses
\`bin/fm-flux-skills-verify.sh\`.
EOF

printf 'fm-flux-skills-vendor: refreshed %s at %s (%s)\n' "$SOURCE_REPO" "$TAG" "$commit"
