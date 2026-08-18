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
[ -f "$VENDOR_ROOT/LICENSE" ] || die 'missing upstream LICENSE'
[ ! -L "$VENDOR_ROOT/LICENSE" ] || die 'upstream LICENSE is a symbolic link'

declare -A manifest=()
while IFS='=' read -r key value; do
  [ -n "$key" ] || die 'manifest contains an empty key'
  case "$key" in
    source_repo|source_url|license|upstream_tag|upstream_commit|adopted_skills|excluded_skills) ;;
    *) die "unexpected manifest key: $key" ;;
  esac
  [ -z "${manifest[$key]+x}" ] || die "duplicate manifest key: $key"
  manifest[$key]=$value
done <"$MANIFEST"

for key in source_repo source_url license upstream_tag upstream_commit adopted_skills excluded_skills; do
  [ -n "${manifest[$key]:-}" ] || die "manifest key is empty or missing: $key"
done

source_repo=${manifest[source_repo]}
source_url=${manifest[source_url]}
license=${manifest[license]}
upstream_tag=${manifest[upstream_tag]}
upstream_commit=${manifest[upstream_commit]}
adopted_skills=${manifest[adopted_skills]}
excluded_skills=${manifest[excluded_skills]}

[ "$source_repo" = fluxcd/agent-skills ] || die "unexpected source_repo: $source_repo"
[ "$source_url" = https://github.com/fluxcd/agent-skills ] || die "unexpected source_url: $source_url"
[ "$license" = Apache-2.0 ] || die "unexpected license: $license"
[ "$upstream_tag" = v0.2.0 ] || die "unexpected upstream_tag: $upstream_tag"
[ "$upstream_commit" = 9b05787530a3e200a9ac031fc8a477566e0b7adc ] \
  || die "unexpected upstream_commit: $upstream_commit"
[ "$adopted_skills" = 'gitops-knowledge gitops-repo-audit' ] \
  || die "unexpected adopted_skills: $adopted_skills"
[ "$excluded_skills" = gitops-cluster-debug ] \
  || die "unexpected excluded_skills: $excluded_skills"

read -r -a adopted <<<"$adopted_skills"
read -r -a excluded <<<"$excluded_skills"
[ "${#adopted[@]}" -gt 0 ] || die 'adopted_skills is empty'

for skill in "${excluded[@]}"; do
  [ ! -e "$VENDOR_ROOT/$skill" ] || die "excluded skill is present: $skill"
done

for skill in "${adopted[@]}"; do
  [ -f "$VENDOR_ROOT/$skill/SKILL.md" ] || die "adopted skill missing SKILL.md: $skill"
  symlink=$(find "$VENDOR_ROOT/$skill" -type l -print -quit)
  [ -z "$symlink" ] || die "adopted skill contains a symbolic link: ${symlink#"$VENDOR_ROOT/"}"
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

checksum_inventory=$(mktemp)
vendor_inventory=$(mktemp)
cleanup() {
  rm -f "$checksum_inventory" "$vendor_inventory"
}
trap cleanup EXIT
sed -n 's/^[[:xdigit:]]\{64\}  //p' "$CHECKSUMS" | LC_ALL=C sort >"$checksum_inventory"
(
  cd "$VENDOR_ROOT"
  find LICENSE "${adopted[@]}" -type f -print | LC_ALL=C sort
) >"$vendor_inventory"
cmp -s "$checksum_inventory" "$vendor_inventory" \
  || die 'checksum inventory does not match adopted skill files'

while IFS= read -r top; do
  base=${top##*/}
  case "$base" in
    MANIFEST|CHECKSUMS.sha256|LICENSE|NOTICE.md) continue ;;
  esac
  found=0
  for skill in "${adopted[@]}"; do
    if [ "$base" = "$skill" ]; then
      found=1
      break
    fi
  done
  [ "$found" -eq 1 ] || die "unexpected top-level vendor entry: $base"
done < <(find "$VENDOR_ROOT" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort)

for skill in "${excluded[@]}"; do
  [ ! -d "$ROOT/.agents/skills/$skill" ] || die "excluded skill exposed under .agents/skills: $skill"
  [ ! -d "$ROOT/skills/$skill" ] || die "excluded skill exposed under skills/: $skill"
done

printf 'fm-flux-skills-verify: ok %s %s (%s); skills: %s\n' \
  "$source_repo" "$upstream_tag" "$upstream_commit" "${adopted[*]}"
