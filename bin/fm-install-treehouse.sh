#!/usr/bin/env bash
# fm-install-treehouse.sh - build and install CI's pinned Treehouse from source.
#
# Used only by the required real-Herdr CI lane for E2E scripts that genuinely
# need treehouse (spawn worktree acquisition). Firstmate builds treehouse from
# its Codebase source mirror rather than downloading a prebuilt GitHub release
# binary, because Codebase releases cannot host binary attachments. Same pin
# discipline as before: an exact tag AND the exact commit that tag must resolve
# to, never a floating latest. Build-time dependency integrity is guaranteed by
# the checked-out repo's go.sum.
#
# Source of truth is code.byted.org/obric/treehouse, kept in step with the
# github.com/kunchenguid/treehouse upstream by bin/fm-sync-treehouse-upstream.sh.
# The clone URL is overridable via FM_TREEHOUSE_SRC_REPO for environments that
# cannot reach code.byted.org: the required real-Herdr lane runs on GitHub's
# public runners, which cannot reach the internal host, so that lane points this
# at the identical github.com mirror instead. Both mirrors carry the same commit
# for v2.0.1, so the commit-SHA pin below verifies either source.
#
# Usage:
#   fm-install-treehouse.sh <destination-directory>
#
# Env:
#   FM_TREEHOUSE_SRC_REPO  override the clone URL (default: the Codebase mirror)
#   FM_TREEHOUSE_GO        override the go binary name/path (default: go)
#
# Requires a Go 1.25+ toolchain and git. Pins Treehouse v2.0.1, the version
# exercised by the local real-Herdr suite. Bumping the pin is a deliberate,
# separate change here (tag AND commit); the upstream sync script never bumps it.
set -eu

FM_TREEHOUSE_CI_VERSION=2.0.1
FM_TREEHOUSE_CI_TAG="v${FM_TREEHOUSE_CI_VERSION}"
# Exact commit the v2.0.1 tag resolves to in both mirrors. Verified after clone
# so a moved or forged tag cannot substitute different source.
FM_TREEHOUSE_CI_COMMIT=5b8ecdec49034fe6861d63b8ea331490bb14c946
FM_TREEHOUSE_SRC_REPO=${FM_TREEHOUSE_SRC_REPO:-https://code.byted.org/obric/treehouse.git}
GO=${FM_TREEHOUSE_GO:-go}

die() {
  printf 'fm-install-treehouse.sh: %s\n' "$*" >&2
  exit 1
}

DESTINATION=${1:?usage: fm-install-treehouse.sh <destination-directory>}

# Toolchain preflight. Building from source needs Go 1.25+ and git; there is no
# floating package-manager fallback.
command -v "$GO" >/dev/null 2>&1 \
  || die "Go toolchain not found (need Go 1.25+); install go and re-run, or set FM_TREEHOUSE_GO"
command -v git >/dev/null 2>&1 || die "git is required to fetch the pinned Treehouse source"

go_version=$("$GO" version 2>/dev/null | awk '{print $3}' | sed 's/^go//')
case "$go_version" in
  ''|*[!0-9.]*) die "could not parse '$GO version' output" ;;
esac
lowest=$(printf '%s\n1.25\n' "$go_version" | sort -V | head -n1)
[ "$lowest" = "1.25" ] \
  || die "Go $go_version is older than the required 1.25 toolchain"

TMP=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/fm-treehouse.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
SRC="$TMP/src"

printf 'fm-install-treehouse.sh: cloning %s at %s\n' "$FM_TREEHOUSE_SRC_REPO" "$FM_TREEHOUSE_CI_TAG" >&2
git -c advice.detachedHead=false clone --depth 1 --branch "$FM_TREEHOUSE_CI_TAG" \
  "$FM_TREEHOUSE_SRC_REPO" "$SRC" \
  || die "could not clone $FM_TREEHOUSE_SRC_REPO at tag $FM_TREEHOUSE_CI_TAG"

# Integrity pin: the checked-out commit must be exactly the verified v2.0.1 commit.
actual_commit=$(git -C "$SRC" rev-parse HEAD)
[ "$actual_commit" = "$FM_TREEHOUSE_CI_COMMIT" ] \
  || die "tag $FM_TREEHOUSE_CI_TAG resolved to $actual_commit, expected pinned $FM_TREEHOUSE_CI_COMMIT"

# Build from source with the version baked in via ldflags, exactly as the
# upstream Makefile's `build` target does (make build VERSION=v2.0.1).
printf 'fm-install-treehouse.sh: building treehouse %s from source\n' "$FM_TREEHOUSE_CI_TAG" >&2
( cd "$SRC" && "$GO" build -ldflags "-X main.version=${FM_TREEHOUSE_CI_TAG}" -o treehouse . ) \
  || die "go build failed for treehouse $FM_TREEHOUSE_CI_TAG"
[ -f "$SRC/treehouse" ] || die "build did not produce a treehouse binary"

mkdir -p "$DESTINATION"
install -m 0755 "$SRC/treehouse" "$DESTINATION/treehouse"

installed_version=$("$DESTINATION/treehouse" --version 2>/dev/null | tr -d '[:space:]')
# treehouse prints "v2.0.1" (leading v) on --version; the ldflags inject it.
case "$installed_version" in
  "v${FM_TREEHOUSE_CI_VERSION}"|"${FM_TREEHOUSE_CI_VERSION}") ;;
  *)
    die "installed treehouse version is '${installed_version:-<empty>}', expected exact pin v${FM_TREEHOUSE_CI_VERSION}"
    ;;
esac

printf 'fm-install-treehouse.sh: installed treehouse %s to %s\n' \
  "$installed_version" "$DESTINATION/treehouse" >&2
"$DESTINATION/treehouse" --version
