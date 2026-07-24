#!/usr/bin/env bash
# fm-sync-treehouse-upstream.sh - refresh the Codebase treehouse mirror from upstream.
#
# What it does:
#   Fetches new commits, branches, and tags from the canonical upstream
#   github.com/kunchenguid/treehouse and pushes them into the internal mirror
#   code.byted.org/obric/treehouse that firstmate builds treehouse from
#   (bin/fm-install-treehouse.sh). It is additive and idempotent: it never
#   deletes Codebase-only refs (it neither mirror-pushes nor prunes), drops
#   GitHub-only pull refs before pushing, and re-running with nothing new is a
#   no-op. A
#   non-fast-forward branch or tag update is reported and NOT forced, so a
#   rewritten upstream history stops for a human instead of clobbering the mirror.
#
# What it deliberately does NOT do:
#   It never changes which treehouse version firstmate installs. The install pin
#   lives in bin/fm-install-treehouse.sh (FM_TREEHOUSE_CI_VERSION / _TAG /
#   _COMMIT). Upgrading treehouse stays a separate, deliberate edit there; this
#   sync only makes newer upstream tags and commits AVAILABLE in the mirror. It
#   also never touches anything under projects/ or this firstmate repo.
#
# When to use:
#   Periodically, or right before bumping the treehouse pin, so the mirror
#   carries the tag/commit you intend to pin. Requires push access to the
#   Codebase mirror and network reach to both hosts (run it inside the corp
#   network). This is a manual helper; it is not wired into any cron or CI.
#
# Usage:
#   fm-sync-treehouse-upstream.sh [--dry-run]
#
# Env:
#   FM_TREEHOUSE_UPSTREAM_REPO  override the upstream source (default: GitHub upstream)
#   FM_TREEHOUSE_MIRROR_REPO    override the Codebase mirror  (default: obric/treehouse)
set -eu

# provenance: the canonical open-source upstream this mirror tracks.
UPSTREAM=${FM_TREEHOUSE_UPSTREAM_REPO:-https://github.com/kunchenguid/treehouse.git}
MIRROR=${FM_TREEHOUSE_MIRROR_REPO:-https://code.byted.org/obric/treehouse.git}

die() {
  printf 'fm-sync-treehouse-upstream.sh: %s\n' "$*" >&2
  exit 1
}

DRY_RUN=
case "${1:-}" in
  --dry-run) DRY_RUN=1 ;;
  '') ;;
  *) printf 'usage: fm-sync-treehouse-upstream.sh [--dry-run]\n' >&2; exit 2 ;;
esac

command -v git >/dev/null 2>&1 || die "git is required"

# Push additively (never a mirror push). Fast-forward only: a rejected
# non-fast-forward is surfaced by the caller, never forced.
do_push() {
  local refspec=$1
  if [ -n "$DRY_RUN" ]; then
    git -C "$WORK/up.git" push --dry-run "$MIRROR" "$refspec"
  else
    git -C "$WORK/up.git" push "$MIRROR" "$refspec"
  fi
}

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-treehouse-sync.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

printf 'fm-sync-treehouse-upstream.sh: mirroring %s -> %s\n' "$UPSTREAM" "$MIRROR" >&2
git clone --mirror "$UPSTREAM" "$WORK/up.git" >/dev/null 2>&1 \
  || die "could not mirror-clone upstream $UPSTREAM"

# Drop GitHub-only pull refs (refs/pull/*): they are forge metadata, not branches
# or tags, and must never be pushed into the Codebase mirror.
git -C "$WORK/up.git" for-each-ref --format='%(refname)' 'refs/pull/*' \
  | while IFS= read -r ref; do
      [ -n "$ref" ] || continue
      git -C "$WORK/up.git" update-ref -d "$ref"
    done

printf 'fm-sync-treehouse-upstream.sh: pushing branches\n' >&2
do_push 'refs/heads/*:refs/heads/*' \
  || die "branch push rejected (non-fast-forward upstream rewrite?); investigate, do not force"
printf 'fm-sync-treehouse-upstream.sh: pushing tags\n' >&2
do_push 'refs/tags/*:refs/tags/*' \
  || die "tag push rejected (a tag moved upstream?); investigate, do not force"

printf 'fm-sync-treehouse-upstream.sh: mirror sync complete%s\n' \
  "${DRY_RUN:+ (dry run)}" >&2
