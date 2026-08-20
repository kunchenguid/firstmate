#!/usr/bin/env bash
# Converge user-installed skills into one canonical cross-harness layout.
#
# The canonical content store is $HOME/.agents/skills. Claude Code and Codex
# receive relative per-skill links in their user skill roots. Gemini, OpenCode,
# and Pi discover the canonical store natively, so verified duplicates in their
# legacy user roots are removed. Codex's vendor-owned skills/.system entry and
# plugin installations are never inspected or changed.
#
# Every local run performs a complete read-only preflight before acting. Dry-run
# is the default; --apply is the only mutation switch. A conflict, unsafe or
# broken link, special file, malformed skill directory, unexpected root entry,
# overlapping managed roots, or ambiguous tree refuses the whole run before any
# mutation. Skill trees may contain directories and regular files only and must
# include SKILL.md.
#
# Preflight refusal is total: nothing is mutated. Once --apply begins executing
# the accepted plan, each step is re-verified against the live filesystem and a
# step that no longer matches the plan stops the run there, leaving the earlier
# steps applied. Each step is individually safe and convergent, so rerunning the
# command after resolving the interference replans from the current state.
#
# Remote operation is routed only through a registered remote secondmate record
# and bin/fm-on.sh, which binds the configured SSH host, code root, and remote
# home without fallback. It executes this same tracked script in the remote
# account. Plugin distribution remains a separate operation.
#
# Usage:
#   fm-user-skill-sync.sh [--dry-run|--apply]
#   fm-user-skill-sync.sh --remote <secondmate-id|ssh-alias> [--dry-run|--apply]
#
# Environment:
#   HOME        Absolute user home whose skill roots are reconciled.
#   CODEX_HOME  Optional absolute Codex home (default: $HOME/.codex).
#
# Managed user roots:
#   $HOME/.agents/skills                 canonical content
#   $HOME/.claude/skills                 relative links
#   ${CODEX_HOME:-$HOME/.codex}/skills   relative links; .system preserved
#   $HOME/.gemini/skills                 duplicate cleanup only
#   $HOME/.config/opencode/skills        duplicate cleanup only
#   $HOME/.opencode/skills               duplicate cleanup only
#   $HOME/.pi/agent/skills               duplicate cleanup only
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MODE=dry-run
ACTION_SET=0
REMOTE=

usage() {
  sed -n '2,/^set -eu$/p' "$0" | sed '/^set -eu$/d; s/^# \{0,1\}//'
}

die() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)
      [ "$ACTION_SET" -eq 0 ] || die "choose exactly one of --dry-run or --apply"
      MODE=dry-run
      ACTION_SET=1
      ;;
    --apply)
      [ "$ACTION_SET" -eq 0 ] || die "choose exactly one of --dry-run or --apply"
      MODE=apply
      ACTION_SET=1
      ;;
    --remote)
      [ "$#" -ge 2 ] || die "--remote requires a registered secondmate id or SSH alias"
      [ -z "$REMOTE" ] || die "--remote may be specified only once"
      REMOTE=$2
      shift
      ;;
    --help|-h) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

if [ -n "$REMOTE" ]; then
  case "$REMOTE" in ''|-*|*[!A-Za-z0-9._-]*) die "unsafe remote route: $REMOTE" ;; esac
  if [ "$MODE" = apply ]; then
    exec "$SCRIPT_DIR/fm-on.sh" "$REMOTE" fm-user-skill-sync.sh --apply
  fi
  exec "$SCRIPT_DIR/fm-on.sh" "$REMOTE" fm-user-skill-sync.sh --dry-run
fi

[ -n "${HOME:-}" ] || die "HOME is required"
case "$HOME" in /*) ;; *) die "HOME must be absolute: $HOME" ;; esac
[ -d "$HOME" ] && [ ! -L "$HOME" ] || die "HOME must be a real directory: $HOME"
case "/$HOME/" in */../*|*/./*) die "HOME contains traversal components: $HOME" ;; esac
case "$HOME" in *$'\n'*|*$'\r'*|*$'\t'*) die "HOME must not contain control characters" ;; esac
HOME=$(cd "$HOME" && pwd -P)
CODEX_ROOT=${CODEX_HOME:-$HOME/.codex}
while case "$CODEX_ROOT" in *'//'*) true ;; *) false ;; esac; do
  CODEX_ROOT=${CODEX_ROOT//\/\//\/}
done
case "$CODEX_ROOT" in /*) ;; *) die "CODEX_HOME must be absolute: $CODEX_ROOT" ;; esac
case "/$CODEX_ROOT/" in */../*|*/./*) die "CODEX_HOME contains traversal components: $CODEX_ROOT" ;; esac
case "$CODEX_ROOT" in *$'\n'*|*$'\r'*|*$'\t'*) die "CODEX_HOME must not contain control characters" ;; esac

physicalize_path() {
  local probe=$1 suffix='' base parent physical
  while [ ! -e "$probe" ] && [ ! -L "$probe" ]; do
    base=${probe##*/}
    parent=${probe%/*}
    [ -n "$parent" ] || parent=/
    suffix="/$base$suffix"
    probe=$parent
  done
  [ -d "$probe" ] || die "existing CODEX_HOME ancestor is not a directory: $probe"
  physical=$(cd "$probe" && pwd -P) || die "cannot resolve CODEX_HOME ancestor: $probe"
  printf '%s%s\n' "$physical" "$suffix"
}
CODEX_ROOT=$(physicalize_path "$CODEX_ROOT")

CANON="$HOME/.agents/skills"
CLAUDE="$HOME/.claude/skills"
CODEX="$CODEX_ROOT/skills"
GEMINI="$HOME/.gemini/skills"
OPENCODE_CONFIG="$HOME/.config/opencode/skills"
OPENCODE_LEGACY="$HOME/.opencode/skills"
PI="$HOME/.pi/agent/skills"

# Each managed root must be a distinct, non-overlapping path, otherwise one root
# would be scanned under two ownership roles and planned against itself.
MANAGED_ROLES="canonical claude codex gemini opencode-config opencode-legacy pi"
managed_root_for_role() {
  case $1 in
    canonical) printf '%s\n' "$CANON" ;;
    claude) printf '%s\n' "$CLAUDE" ;;
    codex) printf '%s\n' "$CODEX" ;;
    gemini) printf '%s\n' "$GEMINI" ;;
    opencode-config) printf '%s\n' "$OPENCODE_CONFIG" ;;
    opencode-legacy) printf '%s\n' "$OPENCODE_LEGACY" ;;
    pi) printf '%s\n' "$PI" ;;
    *) die "internal error: unknown managed root role $1" ;;
  esac
}
for role_a in $MANAGED_ROLES; do
  for role_b in $MANAGED_ROLES; do
    [ "$role_a" != "$role_b" ] || continue
    root_a=$(managed_root_for_role "$role_a")
    root_b=$(managed_root_for_role "$role_b")
    [ "$root_a" != "$root_b" ] \
      || die "managed skill roots $role_a and $role_b resolve to the same path: $root_a"
    case "$root_b/" in
      "$root_a"/*) die "managed skill root $role_b is nested inside $role_a: $root_b" ;;
    esac
  done
done

for parent in \
  "$HOME/.agents" "$HOME/.claude" "$HOME/.gemini" "$HOME/.config" \
  "$HOME/.config/opencode" "$HOME/.opencode" "$HOME/.pi" "$HOME/.pi/agent" \
  "$CODEX_ROOT"; do
  [ ! -L "$parent" ] || die "managed skill parent must not be a link: $parent"
  [ ! -e "$parent" ] || [ -d "$parent" ] || die "managed skill parent is not a directory: $parent"
done

# The operator command owns user homes only. Refuse a synthetic HOME or
# CODEX_HOME that points its managed roots into this repository.
for managed in "$CANON" "$CLAUDE" "$CODEX" "$GEMINI" "$OPENCODE_CONFIG" "$OPENCODE_LEGACY" "$PI"; do
  case "$managed/" in "$ROOT/"*) die "managed user root overlaps the Firstmate repository: $managed" ;; esac
done

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-user-skill-sync.XXXXXX") || die "cannot create preflight workspace"
trap 'rm -rf "$TMP"' EXIT INT TERM
INVENTORY="$TMP/inventory"
ROOT_LINKS="$TMP/root-links"
PLAN="$TMP/plan"
: > "$INVENTORY"
: > "$ROOT_LINKS"
: > "$PLAN"

validate_skill_tree() {
  local skill=$1 bad
  [ -f "$skill/SKILL.md" ] && [ ! -L "$skill/SKILL.md" ] || die "skill lacks a regular SKILL.md: $skill"
  bad=$(find -P "$skill" ! -type d ! -type f -print -quit 2>/dev/null) || die "cannot inspect skill tree: $skill"
  [ -z "$bad" ] || die "skill tree contains a link or special entry: $bad"
}

physical_dir() {
  (cd "$1" 2>/dev/null && pwd -P)
}

verify_link_to_canonical() {
  local path=$1 name=$2 resolved expected
  [ -e "$path" ] || die "broken skill link: $path"
  [ -d "$path" ] || die "skill link does not resolve to a directory: $path"
  resolved=$(physical_dir "$path") || die "cannot resolve skill link: $path"
  expected=$(physical_dir "$CANON/$name") || die "skill link has no established canonical target: $path"
  [ "$resolved" = "$expected" ] || die "unsafe skill link points outside the canonical store: $path"
}

scan_root() {
  local role=$1 root=$2 entry name resolved expected
  if [ -L "$root" ]; then
    [ "$role" != canonical ] || die "canonical skill root must be a real directory: $root"
    [ -e "$root" ] || die "broken managed skill root link: $root"
    resolved=$(physical_dir "$root") || die "cannot resolve managed skill root link: $root"
    expected=$(physical_dir "$CANON") || die "managed root link has no established canonical store: $root"
    [ "$resolved" = "$expected" ] || die "unsafe managed skill root link points outside the canonical store: $root"
    printf '%s\t%s\n' "$role" "$root" >> "$ROOT_LINKS"
    return 0
  fi
  [ ! -e "$root" ] || [ -d "$root" ] || die "managed skill root is not a directory: $root"
  [ -d "$root" ] || return 0
  for entry in "$root"/* "$root"/.[!.]* "$root"/..?*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    name=${entry##*/}
    [ "$name" = .system ] && [ "$role" = codex ] && continue
    case "$name" in ''|.|..|*[!A-Za-z0-9._-]*) die "unexpected entry name in managed skill root: $entry" ;; esac
    if [ -L "$entry" ]; then
      [ "$role" != canonical ] || die "canonical skill entry must not be a link: $entry"
      verify_link_to_canonical "$entry" "$name"
      printf '%s\tlink\t%s\t%s\n' "$name" "$entry" "$role" >> "$INVENTORY"
    elif [ -d "$entry" ]; then
      validate_skill_tree "$entry"
      printf '%s\treal\t%s\t%s\n' "$name" "$entry" "$role" >> "$INVENTORY"
    else
      die "unexpected entry in managed skill root: $entry"
    fi
  done
}

scan_root canonical "$CANON"
scan_root claude "$CLAUDE"
scan_root codex "$CODEX"
scan_root gemini "$GEMINI"
scan_root opencode "$OPENCODE_CONFIG"
scan_root opencode "$OPENCODE_LEGACY"
scan_root pi "$PI"

relative_path() {
  local from=${1#/} to=${2#/} first_from first_to up=
  while [ -n "$from" ] && [ -n "$to" ]; do
    first_from=${from%%/*}
    first_to=${to%%/*}
    [ "$first_from" = "$first_to" ] || break
    if [ "$from" = "$first_from" ]; then from=; else from=${from#*/}; fi
    if [ "$to" = "$first_to" ]; then to=; else to=${to#*/}; fi
  done
  while [ -n "$from" ]; do
    first_from=${from%%/*}
    up="${up}../"
    if [ "$from" = "$first_from" ]; then from=; else from=${from#*/}; fi
  done
  printf '%s%s\n' "$up" "$to"
}

plan() {
  printf '%s\t%s\t%s\n' "$1" "$2" "${3:-}" >> "$PLAN"
}

# Replace only whole-root links already proven to resolve to the canonical
# store. Link-based native roots are removed; Claude and Codex become real roots
# containing the required relative per-skill links.
while IFS=$'\t' read -r role root; do
  [ -n "$root" ] || continue
  plan unlink-root "$root"
  case "$role" in claude|codex) plan mkdir "$root" ;; esac
done < "$ROOT_LINKS"

# Root creation is part of convergence even for an empty skill collection.
[ -d "$CANON" ] || plan mkdir "$CANON"
[ -d "$CLAUDE" ] || [ -L "$CLAUDE" ] || plan mkdir "$CLAUDE"
[ -d "$CODEX" ] || [ -L "$CODEX" ] || plan mkdir "$CODEX"

cut -f1 "$INVENTORY" | LC_ALL=C sort -u > "$TMP/names"
while IFS= read -r name; do
  [ -n "$name" ] || continue
  canonical=$(awk -F '\t' -v n="$name" '$1==n && $4=="canonical" {print $3; exit}' "$INVENTORY")
  baseline=$canonical
  if [ -z "$baseline" ]; then
    baseline=$(awk -F '\t' -v n="$name" '$1==n && $2=="real" {print $3; exit}' "$INVENTORY")
    [ -n "$baseline" ] || die "skill has links but no real owned copy: $name"
    plan copy "$baseline" "$CANON/$name"
  fi

  while IFS=$'\t' read -r inv_name kind path role; do
    [ "$inv_name" = "$name" ] || continue
    if [ "$kind" = real ] && [ "$path" != "$baseline" ]; then
      diff -qr "$baseline" "$path" >/dev/null 2>&1 || die "conflicting skill trees for '$name': $baseline and $path"
    fi
  done < "$INVENTORY"

  while IFS=$'\t' read -r inv_name kind path role; do
    [ "$inv_name" = "$name" ] || continue
    [ "$role" != canonical ] || continue
    case "$role" in
      claude|codex)
        target="$CANON/$name"
        rel=$(relative_path "${path%/*}" "$target")
        if [ "$kind" = link ] && [ "$(readlink "$path")" = "$rel" ]; then
          continue
        fi
        plan remove "$path"
        plan link "$rel" "$path"
        ;;
      gemini|opencode|pi)
        plan remove "$path"
        ;;
      *) die "internal error: unknown skill-root role $role" ;;
    esac
  done < "$INVENTORY"

  if ! awk -F '\t' -v n="$name" '$1==n && $4=="claude" {found=1} END {exit !found}' "$INVENTORY"; then
    plan link "$(relative_path "$CLAUDE" "$CANON/$name")" "$CLAUDE/$name"
  fi
  if ! awk -F '\t' -v n="$name" '$1==n && $4=="codex" {found=1} END {exit !found}' "$INVENTORY"; then
    plan link "$(relative_path "$CODEX" "$CANON/$name")" "$CODEX/$name"
  fi
done < "$TMP/names"

if [ ! -s "$PLAN" ]; then
  printf 'user skills already converged; no changes\n'
  exit 0
fi

if [ "$MODE" = dry-run ]; then
  printf 'DRY RUN - no changes made\n'
else
  printf 'APPLY\n'
fi
while IFS=$'\t' read -r action first second; do
  case "$action" in
    mkdir) printf '%s %s\n' "$action" "$first" ;;
    copy) printf '%s %s -> %s\n' "$action" "$first" "$second" ;;
    remove|unlink-root) printf '%s %s\n' "$action" "$first" ;;
    link) printf 'link %s -> %s\n' "$second" "$first" ;;
  esac
done < "$PLAN"

[ "$MODE" = apply ] || exit 0

remove_verified_duplicate() {
  local path=$1 name canonical
  name=${path##*/}
  canonical="$CANON/$name"
  [ -d "$canonical" ] && [ ! -L "$canonical" ] || die "canonical skill changed after preflight: $canonical"
  if [ -L "$path" ]; then
    verify_link_to_canonical "$path" "$name"
  elif [ -d "$path" ]; then
    validate_skill_tree "$path"
    diff -qr "$canonical" "$path" >/dev/null 2>&1 || die "duplicate changed after preflight: $path"
  else
    die "duplicate changed type after preflight: $path"
  fi
  rm -rf "$path"
}

while IFS=$'\t' read -r action first second; do
  case "$action" in
    mkdir) mkdir -p "$first" ;;
    copy)
      [ ! -e "$second" ] && [ ! -L "$second" ] || die "destination appeared after preflight: $second"
      mkdir -p "${second%/*}"
      cp -R "$first" "$second"
      ;;
    remove) remove_verified_duplicate "$first" ;;
    unlink-root)
      [ -L "$first" ] && [ -e "$first" ] || die "managed root link changed after preflight: $first"
      [ "$(physical_dir "$first")" = "$(physical_dir "$CANON")" ] \
        || die "managed root link changed target after preflight: $first"
      rm "$first"
      ;;
    link)
      [ ! -e "$second" ] && [ ! -L "$second" ] || die "link destination appeared after preflight: $second"
      ln -s "$first" "$second"
      ;;
    *) die "internal error: unknown planned action $action" ;;
  esac
done < "$PLAN"
printf 'user skills converged\n'
