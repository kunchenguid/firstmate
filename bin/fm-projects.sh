#!/usr/bin/env bash
# Project discovery and resolution for this home (bin/fm-projects-lib.sh owns
# the contract; docs/configuration.md "Project-local homes, the launcher, and
# the projects root" owns the schema).
#
# Usage:
#   fm-projects.sh root                 print the effective projects root
#   fm-projects.sh org                  exit 0 when config/projects-root selects
#                                       the projects root, 1 otherwise
#   fm-projects.sh discover             list discoverable sibling repo names
#                                       under the projects root (never a
#                                       mutation list: discovery is not
#                                       authority)
#   fm-projects.sh aliases              list every registered project alias
#                                       (data/projects.md plus
#                                       data/project-paths.json keys)
#   fm-projects.sh resolve <arg>        resolve a project argument to a path
#   fm-projects.sh name <arg> <path>    print the stable project name for a
#                                       spawn argument and its resolved path
#   fm-projects.sh summary              the derived org summary the session-start
#                                       digest carries for an org launch: per
#                                       registered alias (at most
#                                       FM_PROJECTS_SUMMARY_MAX, default 25)
#                                       one line with name, registered delivery
#                                       mode, main language, and in-flight
#                                       tasks, plus a second line with the
#                                       first line of its own AGENTS.md or
#                                       CLAUDE.md; then the discoverable
#                                       unregistered sibling repos by name,
#                                       with an offer to register them.
#                                       Read-only; derived fresh on every call.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-projects-lib.sh
. "$SCRIPT_DIR/fm-projects-lib.sh"

usage() {
  echo "usage: fm-projects.sh root|org|discover|aliases|resolve <arg>|name <arg> <path>|summary" >&2
}

# registry_mode <alias>: the bracketed annotation of the alias's data/projects.md
# line, "no-mistakes" for a legacy unannotated line, or "unrecorded" when only
# data/project-paths.json registers it.
registry_mode() {
  local alias=$1 mode
  [ -f "$DATA/projects.md" ] || { echo unrecorded; return 0; }
  mode=$(awk -v n="$alias" '
    $1 == "-" && $2 == n {
      if ($3 ~ /^\[/) {
        s = ""
        for (i = 3; i <= NF; i++) { s = s (s == "" ? "" : " ") $i; if ($i ~ /\]$/) break }
        gsub(/^\[|\]$/, "", s)
        print s
      } else {
        print "no-mistakes"
      }
      exit
    }
  ' "$DATA/projects.md")
  printf '%s\n' "${mode:-unrecorded}"
}

# main_language <dir>: the language most tracked files are written in, by file
# extension over at most the first 20000 tracked paths; "unknown" when no
# tracked file has a recognized source extension.
main_language() {
  git -C "$1" ls-files 2>/dev/null | head -n 20000 | awk '
    BEGIN {
      split("sh:Shell bash:Shell zsh:Shell py:Python ts:TypeScript tsx:TypeScript mts:TypeScript cts:TypeScript js:JavaScript jsx:JavaScript mjs:JavaScript cjs:JavaScript go:Go rs:Rust java:Java kt:Kotlin kts:Kotlin rb:Ruby php:PHP c:C h:C cc:C++ cpp:C++ cxx:C++ hpp:C++ hh:C++ cs:C# swift:Swift m:Objective-C mm:Objective-C scala:Scala dart:Dart ex:Elixir exs:Elixir erl:Erlang lua:Lua r:R jl:Julia hs:Haskell ml:OCaml clj:Clojure zig:Zig nim:Nim vue:Vue svelte:Svelte html:HTML css:CSS scss:CSS sql:SQL tf:Terraform nix:Nix ps1:PowerShell pl:Perl", pairs, " ")
      for (i in pairs) { split(pairs[i], kv, ":"); lang[kv[1]] = kv[2] }
    }
    {
      n = split($0, parts, "/"); base = parts[n]
      if (base !~ /\./) next
      ext = tolower(base); sub(/^.*\./, "", ext)
      if (ext in lang) count[lang[ext]]++
    }
    END {
      best = ""; top = 0
      for (l in count) if (count[l] > top || (count[l] == top && l < best)) { best = l; top = count[l] }
      print (best == "" ? "unknown" : best)
    }
  '
}

# first_instruction_line <dir>: the first non-blank line of the directory's own
# AGENTS.md, else of a CLAUDE.md that is more than an @AGENTS.md pointer.
first_instruction_line() {
  local dir=$1 f line
  for f in AGENTS.md CLAUDE.md; do
    [ -f "$dir/$f" ] || continue
    line=$(grep -v -E '^[[:space:]]*(<!--.*-->)?[[:space:]]*$' "$dir/$f" 2>/dev/null | sed -n '1p') || line=
    [ -n "$line" ] || continue
    [ "$line" != "@AGENTS.md" ] || continue
    printf '%s: %s\n' "$f" "$line" | cut -c1-200
    return 0
  done
  echo "no AGENTS.md or CLAUDE.md"
}

# in_flight <alias> <path>: "<count>" or "<count> (<id>, ...)" of the task
# records in this home that name the project, secondmates excluded.
in_flight() {
  local alias=$1 path=$2 meta id kind pname proj ids='' n=0
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    kind=$(sed -n 's/^kind=//p' "$meta" | sed -n '1p')
    [ "$kind" != secondmate ] || continue
    pname=$(sed -n 's/^project_name=//p' "$meta" | sed -n '1p')
    proj=$(sed -n 's/^project=//p' "$meta" | sed -n '1p')
    [ "$pname" = "$alias" ] || { [ -z "$pname" ] && [ "$proj" = "$path" ]; } || continue
    id=$(basename "$meta" .meta)
    n=$((n + 1))
    [ "$n" -gt 3 ] || ids="${ids:+$ids, }$id"
  done
  if [ "$n" -eq 0 ]; then
    echo none
  elif [ "$n" -gt 3 ]; then
    echo "$n ($ids, ...)"
  else
    echo "$n ($ids)"
  fi
}

cmd_summary() {
  local max=${FM_PROJECTS_SUMMARY_MAX:-25} aliases alias path real shown=0 total=0 root
  local registered_paths='' name names='' unreg=0
  case "$max" in '' | *[!0-9]* | 0) max=25 ;; esac
  aliases=$(fm_project_registered_aliases "$DATA") || return 1
  while IFS= read -r alias; do
    [ -n "$alias" ] || continue
    total=$((total + 1))
    path=$(fm_project_resolve "$FM_HOME" "$CONFIG" "$DATA" "$alias") || return 1
    real=''
    if [ "$path" != "$alias" ] && [ -d "$path" ]; then
      real=$(cd "$path" && pwd -P)
      registered_paths="$registered_paths$real"$'\n'
    fi
    [ "$shown" -lt "$max" ] || continue
    shown=$((shown + 1))
    if [ -z "$real" ]; then
      printf -- '- %s [%s] - missing: resolves to no directory\n' "$alias" "$(registry_mode "$alias")"
      continue
    fi
    printf -- '- %s [%s] - %s - in flight: %s\n' "$alias" "$(registry_mode "$alias")" \
      "$(main_language "$real")" "$(in_flight "$alias" "$real")"
    printf '  %s\n' "$(first_instruction_line "$real")"
  done <<< "$aliases"
  [ "$total" -gt 0 ] || echo "(no registered projects)"
  [ "$total" -le "$max" ] || echo "(... and $((total - max)) more registered; see data/projects.md)"
  fm_projects_root_is_custom "$CONFIG" || return 0
  root=$(fm_projects_root "$FM_HOME" "$CONFIG") || return 1
  [ -d "$root" ] || return 0
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    real=$(cd "$root/$name" && pwd -P) || continue
    printf '%s' "$registered_paths" | grep -Fxq -- "$real" && continue
    unreg=$((unreg + 1))
    [ "$unreg" -le "$max" ] || continue
    names="${names:+$names, }$name"
  done < <(fm_project_discover "$root")
  [ "$unreg" -gt 0 ] || return 0
  [ "$unreg" -le "$max" ] || names="$names, ... and $((unreg - max)) more"
  printf 'Unregistered sibling repos (offer the captain to register them; project-management owns registration): %s\n' "$names"
}

case "${1:-}" in
  root)
    [ $# -eq 1 ] || { usage; exit 1; }
    fm_projects_root "$FM_HOME" "$CONFIG"
    ;;
  org)
    [ $# -eq 1 ] || { usage; exit 1; }
    fm_projects_root_is_custom "$CONFIG"
    ;;
  discover)
    [ $# -eq 1 ] || { usage; exit 1; }
    PROJECTS_ROOT=$(fm_projects_root "$FM_HOME" "$CONFIG") || exit 1
    fm_project_discover "$PROJECTS_ROOT"
    ;;
  aliases)
    [ $# -eq 1 ] || { usage; exit 1; }
    fm_project_registered_aliases "$DATA"
    ;;
  resolve)
    [ $# -eq 2 ] || { usage; exit 1; }
    fm_project_resolve "$FM_HOME" "$CONFIG" "$DATA" "$2"
    ;;
  name)
    [ $# -eq 3 ] || { usage; exit 1; }
    fm_project_name_for "$FM_HOME" "$CONFIG" "$DATA" "$2" "$3"
    ;;
  summary)
    [ $# -eq 1 ] || { usage; exit 1; }
    cmd_summary
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    usage
    exit 1
    ;;
esac
