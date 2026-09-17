#!/usr/bin/env bash
# Shared project-root and project-path resolution for the project-local home
# model (docs/configuration.md "Projects root and project resolution").
#
# This file is sourced; it has no side effects on source and defines no
# variables of its own. Every function takes the home, config, and data
# directories as explicit arguments so callers keep their own FM_*_OVERRIDE
# resolution.
#
# Projects root precedence, resolved by fm_projects_root:
#   1. FM_PROJECTS_OVERRIDE (verbatim, as before)
#   2. <config>/projects-root - one line holding a relative or absolute path;
#      relative resolves against the home directory. `firstmate init --org`
#      writes `..`, making the org root's sibling directories the projects
#      root. A malformed file (missing, unreadable, non-regular, symlinked,
#      empty, multi-line, or carrying a control byte) fails loudly rather than
#      silently falling back, because a half-read root would point the fleet
#      at the wrong directories.
#   3. <home>/projects (the legacy default)
#
# Discovery is not authority: a home whose projects root came from
# config/projects-root treats sibling directories as DISCOVERABLE only.
# fm_project_sync_candidates enumerates registered aliases (data/projects.md
# plus data/project-paths.json) resolved through fm_project_resolve; a home
# without config/projects-root keeps the legacy direct-children glob, so
# existing homes behave exactly as before.
#
# fm_project_resolve owns the central alias -> path contract:
#   - an argument containing a slash other than the projects/<name> form is a
#     path and passes through unchanged;
#   - projects/<name> prefers the legacy <home>/projects/<name> clone, then
#     resolves <name> as an alias;
#   - a bare alias resolves through data/project-paths.json (non-sibling
#     registrations), then <projects-root>/<alias>, then the legacy
#     <home>/projects/<alias>;
#   - an alias that resolves nowhere passes through unchanged so callers keep
#     their existing not-a-directory handling.
#
# data/project-paths.json is a flat JSON object {"<alias>": "<absolute-path>"}
# for projects that live outside the projects root. jq is used when present;
# the fallback reader accepts only the flat object form and refuses aliases or
# paths containing a double quote or backslash, which the format forbids.

# fm_projects_root <home> <config>: print the effective projects root.
fm_projects_root() {
  local home=$1 config=$2 file line
  if [ -n "${FM_PROJECTS_OVERRIDE:-}" ]; then
    printf '%s\n' "$FM_PROJECTS_OVERRIDE"
    return 0
  fi
  file="$config/projects-root"
  if [ ! -e "$file" ] && [ ! -L "$file" ]; then
    printf '%s\n' "$home/projects"
    return 0
  fi
  if [ -L "$file" ] || [ ! -f "$file" ]; then
    echo "error: $file must be a regular file" >&2
    return 1
  fi
  [ -r "$file" ] || { echo "error: $file is not readable" >&2; return 1; }
  line=$(sed -n '1p' "$file" | tr -d '[:space:]')
  if [ -z "$line" ] || [ "$(wc -l < "$file" | tr -d '[:space:]')" -gt 1 ] \
      || [ -n "$(sed -n '2p' "$file" | tr -d '[:space:]')" ]; then
    echo "error: $file must contain exactly one path line" >&2
    return 1
  fi
  case "$line" in
    *[![:print:]]*)
      echo "error: $file contains a non-printable byte" >&2
      return 1
      ;;
  esac
  local root
  case "$line" in
    /*) root=$line ;;
    *) root=$home/$line ;;
  esac
  # Canonicalize when the root exists so downstream path comparisons (labels,
  # ancestor checks) never see a literal "..".
  if [ -d "$root" ]; then
    (cd "$root" && pwd -P)
  else
    printf '%s\n' "$root"
  fi
}

# fm_projects_root_is_custom <config>: true when config/projects-root selects
# the projects root (the org-model marker). FM_PROJECTS_OVERRIDE is a
# process-local override and does not make the home org-shaped.
fm_projects_root_is_custom() {
  local config=$1
  [ -f "$config/projects-root" ] && [ ! -L "$config/projects-root" ]
}

# fm_project_manifest_path <data>: print the non-sibling manifest path.
fm_project_manifest_path() {
  printf '%s\n' "$1/project-paths.json"
}

# fm_project_manifest_pairs <data>: print every manifest entry as
# "alias<TAB>path", one per line. A malformed manifest fails loudly.
fm_project_manifest_pairs() {
  local data=$1 manifest
  manifest=$(fm_project_manifest_path "$data")
  [ -f "$manifest" ] || return 0
  if command -v jq >/dev/null 2>&1; then
    jq -e 'type == "object" and (all(.[]; type == "string"))' "$manifest" >/dev/null 2>&1 || {
      echo "error: $manifest must be a flat JSON object of alias -> path" >&2
      return 1
    }
    jq -r 'to_entries[] | .key + "\t" + .value' "$manifest"
    return 0
  fi
  awk -v file="$manifest" '
    {
      line = $0
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
      if (line == "{" || line == "}" || line == "") next
      # one "alias": "path" pair per line, optional trailing comma
      if (line !~ /^"[^"\\]+"[[:space:]]*:[[:space:]]*"[^"\\]*"[[:space:]]*,?$/) {
        printf "error: %s must be a flat JSON object of alias -> path\n", file > "/dev/stderr"
        exit 1
      }
      sub(/^"/, "", line)
      key = line
      sub(/"[[:space:]]*:.*/, "", key)
      val = line
      sub(/^[^"]*"[[:space:]]*:[[:space:]]*"/, "", val)
      sub(/"[[:space:]]*,?$/, "", val)
      print key "\t" val
    }
  ' "$manifest"
}

# fm_project_manifest_lookup <data> <alias>: print the registered absolute
# path for <alias>, or nothing.
fm_project_manifest_lookup() {
  local data=$1 alias=$2 pairs key val
  case "$alias" in
    *'"'*|*'\'*)
      echo "error: project alias contains a byte the manifest cannot hold: $alias" >&2
      return 1
      ;;
  esac
  pairs=$(fm_project_manifest_pairs "$data") || return 1
  while IFS=$'\t' read -r key val; do
    [ -n "$key" ] || continue
    if [ "$key" = "$alias" ]; then
      printf '%s\n' "$val"
      return 0
    fi
  done <<< "$pairs"
}

# fm_project_registered_aliases <data>: print every registered alias, one per
# line, sorted and deduplicated: data/projects.md entries plus
# data/project-paths.json keys.
fm_project_registered_aliases() {
  local data=$1 manifest
  manifest=$(fm_project_manifest_path "$data")
  {
    if [ -f "$data/projects.md" ]; then
      awk '$1 == "-" && $2 != "" { print $2 }' "$data/projects.md"
    fi
    if [ -f "$manifest" ]; then
      fm_project_manifest_pairs "$data" | cut -f1
    fi
  } | sort -u
}

# fm_project_resolve <home> <config> <data> <arg>: resolve a project argument
# to a directory path per the contract in this file's header. Prints the
# resolved path (or the argument unchanged when nothing resolves it).
fm_project_resolve() {
  local home=$1 config=$2 data=$3 arg=$4 projects candidate mapped
  case "$arg" in
    projects/*)
      candidate="$home/projects/${arg#projects/}"
      if [ -d "$candidate" ]; then
        printf '%s\n' "$candidate"
        return 0
      fi
      arg=${arg#projects/}
      ;;
    */*)
      printf '%s\n' "$arg"
      return 0
      ;;
  esac
  case "$arg" in
    ''|.|..|*'$'*|*'`'*)
      printf '%s\n' "$arg"
      return 0
      ;;
  esac
  mapped=$(fm_project_manifest_lookup "$data" "$arg") || return 1
  if [ -n "$mapped" ]; then
    printf '%s\n' "$mapped"
    return 0
  fi
  projects=$(fm_projects_root "$home" "$config") || return 1
  if [ -d "$projects/$arg" ]; then
    printf '%s\n' "$projects/$arg"
    return 0
  fi
  if [ -d "$home/projects/$arg" ]; then
    printf '%s\n' "$home/projects/$arg"
    return 0
  fi
  printf '%s\n' "$arg"
}

# fm_project_sync_candidates <home> <config> <data>: print the project paths a
# whole-fleet refresh may touch. A config/projects-root home enumerates only
# REGISTERED aliases (discovery is not authority); every other home keeps the
# legacy direct-children glob, including unregistered clones.
fm_project_sync_candidates() {
  local home=$1 config=$2 data=$3 projects alias resolved aliases proj
  if fm_projects_root_is_custom "$config"; then
    aliases=$(fm_project_registered_aliases "$data") || return 1
    while IFS= read -r alias; do
      [ -n "$alias" ] || continue
      resolved=$(fm_project_resolve "$home" "$config" "$data" "$alias") || return 1
      printf '%s\n' "$resolved"
    done <<< "$aliases"
    return 0
  fi
  projects=$(fm_projects_root "$home" "$config") || return 1
  [ -d "$projects" ] || return 0
  for proj in "$projects"/*; do
    [ -e "$proj" ] || continue
    [ -d "$proj" ] || continue
    printf '%s\n' "$proj"
  done
}

# fm_project_discover <projects-root>: print the basename of every direct
# child that is the root of its own git work tree - the discoverable sibling
# repos of an org root. Discovery is not authority: these names are intake and
# registry-rebuild input, never a mutation list.
fm_project_discover() {
  local root=$1 child top
  [ -d "$root" ] || return 0
  for child in "$root"/*; do
    [ -d "$child" ] || continue
    top=$(git -C "$child" rev-parse --show-toplevel 2>/dev/null) || continue
    [ "$top" = "$(cd "$child" && pwd -P)" ] || continue
    basename "$child"
  done
}

# fm_project_alias_for_path <home> <config> <data> <path>: print the
# registered alias whose resolved path is <path>, or nothing.
fm_project_alias_for_path() {
  local home=$1 config=$2 data=$3 path=$4 alias resolved target aliases
  target=$(cd "$path" 2>/dev/null && pwd -P) || target=$path
  aliases=$(fm_project_registered_aliases "$data") || return 1
  while IFS= read -r alias; do
    [ -n "$alias" ] || continue
    resolved=$(fm_project_resolve "$home" "$config" "$data" "$alias") || return 1
    resolved=$(cd "$resolved" 2>/dev/null && pwd -P) || continue
    if [ "$resolved" = "$target" ]; then
      printf '%s\n' "$alias"
      return 0
    fi
  done <<< "$aliases"
}

# fm_project_name_for <home> <config> <data> <arg> <abs-path>: the stable
# project name recorded in task metadata and used for registry lookups.
# A bare alias or projects/<name> argument keeps that name; a path argument
# uses its registered alias when one resolves to it, else its basename.
fm_project_name_for() {
  local home=$1 config=$2 data=$3 arg=$4 abs=$5 alias
  case "$arg" in
    projects/*)
      printf '%s\n' "${arg#projects/}"
      return 0
      ;;
    */*) ;;
    *)
      printf '%s\n' "$arg"
      return 0
      ;;
  esac
  alias=$(fm_project_alias_for_path "$home" "$config" "$data" "$abs") || return 1
  if [ -n "$alias" ]; then
    printf '%s\n' "$alias"
  else
    basename "$abs"
  fi
}
