#!/usr/bin/env bash
# fm-flux-skills-verify.sh - verify the pinned fluxcd/agent-skills vendor tree.
#
# Network-free: compares the committed vendor tree to MANIFEST and CHECKSUMS.sha256,
# and refuses excluded or unexpected skill directories.
#
# Usage:
#   fm-flux-skills-verify.sh
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
VENDOR_ROOT="$ROOT/skills/vendor/fluxcd-agent-skills"
MANIFEST="$VENDOR_ROOT/MANIFEST"
CHECKSUMS="$VENDOR_ROOT/CHECKSUMS.sha256"

die() {
  printf 'fm-flux-skills-verify: %s\n' "$1" >&2
  exit 1
}

[ -f "$MANIFEST" ] || die "missing MANIFEST at $MANIFEST"
[ -f "$CHECKSUMS" ] || die "missing CHECKSUMS.sha256 at $CHECKSUMS"
[ -f "$VENDOR_ROOT/NOTICE.md" ] || die 'missing NOTICE.md'

# shellcheck disable=SC1090
. <(sed -n 's/^\([A-Za-z0-9_]*\)=\(.*\)$/\1="\2"/p' "$MANIFEST")

: "${source_repo:=}"
: "${source_url:=}"
: "${license:=}"
: "${upstream_tag:=}"
: "${upstream_commit:=}"
: "${adopted_skills:=}"
: "${excluded_skills:=}"

[ "$source_repo" = fluxcd/agent-skills ] || die "unexpected source_repo: $source_repo"
[ "$source_url" = https://github.com/fluxcd/agent-skills ] || die "unexpected source_url: $source_url"
[ "$license" = Apache-2.0 ] || die "unexpected license: $license"
[ -n "$upstream_tag" ] || die 'upstream_tag is empty'
[ -n "$upstream_commit" ] || die 'upstream_commit is empty'

read -r -a adopted <<<"$adopted_skills"
read -r -a excluded <<<"$excluded_skills"
[ "${#adopted[@]}" -gt 0 ] || die 'adopted_skills is empty'

for skill in "${excluded[@]}"; do
  [ ! -e "$VENDOR_ROOT/$skill" ] || die "excluded skill is present: $skill"
done

for skill in "${adopted[@]}"; do
  [ -f "$VENDOR_ROOT/$skill/SKILL.md" ] || die "adopted skill missing SKILL.md: $skill"
done

while IFS= read -r entry; do
  case "$entry" in
    ''|'#'*) continue ;;
  esac
  expected_hash=${entry%% *}
  relpath=${entry#*  }
  [ -f "$VENDOR_ROOT/$relpath" ] || die "checksum entry missing file: $relpath"
  actual_hash=$(sha256sum "$VENDOR_ROOT/$relpath" | awk '{print $1}')
  [ "$actual_hash" = "$expected_hash" ] || die "checksum mismatch for $relpath"
done <"$CHECKSUMS"

while IFS= read -r top; do
  base=${top##*/}
  case "$base" in
    MANIFEST|CHECKSUMS.sha256|NOTICE.md) continue ;;
  esac
  found=0
  for skill in "${adopted[@]}"; do
    if [ "$base" = "$skill" ]; then
      found=1
      break
    fi
  done
  [ "$found" -eq 1 ] || die "unexpected top-level vendor entry: $base"
done < <(find "$VENDOR_ROOT" -mindepth 1 -maxdepth 1 \( -type d -o -type f \) -printf '%f\n' | LC_ALL=C sort)

for skill in "${excluded[@]}"; do
  [ ! -d "$ROOT/.agents/skills/$skill" ] || die "excluded skill exposed under .agents/skills: $skill"
  [ ! -d "$ROOT/skills/$skill" ] || die "excluded skill exposed under skills/: $skill"
done

printf 'fm-flux-skills-verify: ok %s %s (%s); skills: %s\n' \
  "$source_repo" "$upstream_tag" "$upstream_commit" "${adopted[*]}"
