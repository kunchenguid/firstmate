#!/usr/bin/env bash
# Shared project-root and project-path resolution for the project-local home
# model (docs/configuration.md "Project-local homes, the launcher, and the
# projects root").
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
#     registrations), then - in a config/projects-root home - the projects
#     root itself when it is a git work-tree root named <alias> (the repo a
#     per-project `firstmate init` registers), then <projects-root>/<alias>
#     (in a config/projects-root home only when it is its own git work-tree
#     root, so a same-named package directory inside a per-project repo never
#     shadows the repo), then the legacy <home>/projects/<alias>;
#   - an alias that resolves nowhere passes through unchanged so callers keep
#     their existing not-a-directory handling.
#
# data/project-paths.json is a flat JSON object {"<alias>": "<absolute-path>"}
# for projects that live outside the projects root. Both readers refuse a value
# that is not an absolute path, because a relative one would resolve against
# whatever directory the caller happens to be in. jq is used when present; the
# fallback reader accepts only the flat object form and refuses aliases or paths
# containing a double quote or backslash, which the format forbids.

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
  # Trim leading/trailing whitespace only; a path with interior whitespace is
  # rejected loudly rather than silently mangled into a different directory.
  line=$(sed -n '1p' "$file" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  if [ -z "$line" ] || [ "$(wc -l < "$file" | tr -d '[:space:]')" -gt 1 ] \
      || [ -n "$(sed -n '2p' "$file" | tr -d '[:space:]')" ]; then
    echo "error: $file must contain exactly one path line" >&2
    return 1
  fi
  case "$line" in
    *[[:space:]]*)
      echo "error: $file contains whitespace inside the path" >&2
      return 1
      ;;
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
    jq -e 'type == "object" and (all(.[]; type == "string" and startswith("/")))' "$manifest" >/dev/null 2>&1 || {
      echo "error: $manifest must be a flat JSON object of alias -> absolute path" >&2
      return 1
    }
    jq -r 'to_entries[] | .key + "\t" + .value' "$manifest"
    return 0
  fi
  # The document is read whole and consumed pair by pair, so the one-line and
  # the pretty-printed forms of the same flat object mean the same thing here
  # as they do to jq.
  awk -v file="$manifest" '
    function bad() {
      printf "error: %s must be a flat JSON object of alias -> absolute path\n", file > "/dev/stderr"
      exit 1
    }
    { doc = doc $0 "\n" }
    END {
      if (!match(doc, /^[[:space:]]*[{]/)) bad()
      doc = substr(doc, RSTART + RLENGTH)
      if (match(doc, /^[[:space:]]*[}][[:space:]]*$/)) exit 0
      while (1) {
        if (!match(doc, /^[[:space:]]*"[^"\\]+"[[:space:]]*:[[:space:]]*"\/[^"\\]*"/)) bad()
        pair = substr(doc, RSTART, RLENGTH)
        doc = substr(doc, RSTART + RLENGTH)
        key = pair
        sub(/^[[:space:]]*"/, "", key)
        sub(/"[[:space:]]*:.*/, "", key)
        val = pair
        sub(/^[[:space:]]*"[^"\\]*"[[:space:]]*:[[:space:]]*"/, "", val)
        sub(/"$/, "", val)
        print key "\t" val
        if (match(doc, /^[[:space:]]*,/)) {
          doc = substr(doc, RSTART + RLENGTH)
          continue
        }
        if (match(doc, /^[[:space:]]*[}][[:space:]]*$/)) exit 0
        bad()
      }
    }
  ' "$manifest"
}

# fm_project_manifest_lookup <data> <alias>: print the registered absolute
# path for <alias>, or nothing. A duplicated alias takes its LAST value, the
# way jq reads the same document, so both readers name the same directory.
fm_project_manifest_lookup() {
  local data=$1 alias=$2 pairs key val found=''
  case "$alias" in
    *\"*|*\\*)
      echo "error: project alias contains a byte the manifest cannot hold: $alias" >&2
      return 1
      ;;
  esac
  pairs=$(fm_project_manifest_pairs "$data") || return 1
  while IFS=$'\t' read -r key val; do
    [ -n "$key" ] || continue
    if [ "$key" = "$alias" ]; then
      found=$val
    fi
  done <<< "$pairs"
  [ -z "$found" ] || printf '%s\n' "$found"
}

# fm_project_registered_aliases <data>: print every registered alias, one per
# line, sorted and deduplicated: data/projects.md entries plus
# data/project-paths.json keys.
fm_project_registered_aliases() {
  local data=$1 manifest pairs=''
  manifest=$(fm_project_manifest_path "$data")
  if [ -f "$manifest" ]; then
    pairs=$(fm_project_manifest_pairs "$data") || return 1
  fi
  {
    if [ -f "$data/projects.md" ]; then
      awk '$1 == "-" && $2 != "" { print $2 }' "$data/projects.md"
    fi
    if [ -n "$pairs" ]; then
      printf '%s\n' "$pairs" | cut -f1
    fi
  } | sort -u
}

# fm_project_is_git_root <dir>: true when <dir> is the root of its own git
# work tree, not merely a directory nested inside one.
fm_project_is_git_root() {
  local dir=$1 top
  [ -d "$dir" ] || return 1
  top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || return 1
  [ "$top" = "$(cd "$dir" && pwd -P)" ]
}

# fm_project_resolve <home> <config> <data> <arg>: resolve a project argument
# to a directory path per the contract in this file's header. Prints the
# resolved path (or the argument unchanged when nothing resolves it).
fm_project_resolve() {
  local home=$1 config=$2 data=$3 arg=$4 projects candidate mapped
  case "$arg" in
    projects/?*)
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
  if fm_projects_root_is_custom "$config"; then
    if [ "$(basename "$projects")" = "$arg" ] && fm_project_is_git_root "$projects"; then
      printf '%s\n' "$projects"
      return 0
    fi
    if fm_project_is_git_root "$projects/$arg"; then
      printf '%s\n' "$projects/$arg"
      return 0
    fi
  elif [ -d "$projects/$arg" ]; then
    printf '%s\n' "$projects/$arg"
    return 0
  fi
  if [ -d "$home/projects/$arg" ]; then
    printf '%s\n' "$home/projects/$arg"
    return 0
  fi
  printf '%s\n' "$arg"
}

# fm_project_sync_candidate <home> <config> <data> <alias>: the directory a
# refresh acts on for one REGISTERED alias. An alias the resolver does not
# resolve still yields its sibling path when that directory exists, so the
# refresh reports what is actually wrong with it; only a name that resolves to
# nothing at all yields EMPTY, never the cwd-relative name the caller might
# mistake for a directory of its own. Every caller that turns a registered
# alias into a path to sync goes through here, so the whole-fleet and
# single-project forms cannot drift on what "registered but unusable" means.
fm_project_sync_candidate() {
  local home=$1 config=$2 data=$3 alias=$4 resolved projects
  resolved=$(fm_project_resolve "$home" "$config" "$data" "$alias") || return 1
  if [ "$resolved" != "$alias" ]; then
    printf '%s\n' "$resolved"
    return 0
  fi
  projects=$(fm_projects_root "$home" "$config") || return 1
  [ -d "$projects/$alias" ] || return 0
  printf '%s\n' "$projects/$alias"
}

# fm_project_sync_candidate_pairs <home> <config> <data>: print the projects a
# whole-fleet refresh may touch as "alias<TAB>path" lines. A
# config/projects-root home enumerates only REGISTERED aliases (discovery is
# not authority), each through fm_project_sync_candidate. Every other home
# keeps the legacy direct-children glob, including unregistered clones, with
# an empty alias.
fm_project_sync_candidate_pairs() {
  local home=$1 config=$2 data=$3 projects alias candidate aliases proj
  if fm_projects_root_is_custom "$config"; then
    aliases=$(fm_project_registered_aliases "$data") || return 1
    while IFS= read -r alias; do
      [ -n "$alias" ] || continue
      candidate=$(fm_project_sync_candidate "$home" "$config" "$data" "$alias") || return 1
      printf '%s\t%s\n' "$alias" "$candidate"
    done <<< "$aliases"
    return 0
  fi
  projects=$(fm_projects_root "$home" "$config") || return 1
  [ -d "$projects" ] || return 0
  for proj in "$projects"/*; do
    [ -e "$proj" ] || continue
    [ -d "$proj" ] || continue
    printf '\t%s\n' "$proj"
  done
}

# fm_project_sync_candidates <home> <config> <data>: print only the paths of
# fm_project_sync_candidate_pairs, one per line.
fm_project_sync_candidates() {
  local pairs
  pairs=$(fm_project_sync_candidate_pairs "$@") || return 1
  [ -n "$pairs" ] || return 0
  printf '%s\n' "$pairs" | cut -f2-
}

# fm_project_discover <projects-root>: print the basename of every direct
# child that is the root of its own git work tree - the discoverable sibling
# repos of an org root. Discovery is not authority: these names are intake and
# registry-rebuild input, never a mutation list. A projects root that is not a
# directory fails loudly, because callers rebuild a registry from this list and
# an empty success would read as "this org has no siblings".
fm_project_discover() {
  local root=$1 child top
  [ -d "$root" ] || {
    echo "error: projects root is not a directory: $root" >&2
    return 1
  }
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
    [ "$resolved" != "$alias" ] || continue
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
