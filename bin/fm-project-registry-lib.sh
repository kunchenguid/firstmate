#!/usr/bin/env bash
# fm-project-registry-lib.sh - single owner of where a data/projects.md entry's
# project name starts and ends, so every reader of the project registry agrees
# on which line belongs to which project, including a name that contains spaces.
#
# bin/fm-project-mode.sh's header owns the rest of the line format and the
# bracketed annotation tokens. This file owns only the name, with these rules:
#
#   Lookup (a queried name n): a line belongs to n when it starts with "- " n,
#   compared literally (never as a regex or a whitespace-split field), and the
#   text right after n is empty or starts with " [" or " - ". So "foo bar"
#   matches "- foo bar ..." and "Acme - Site" matches "- Acme - Site [...] ...",
#   while a "foo" query never matches "- foo bar ...".
#   Enumeration (no queried name): an entry line starts with "- ", and its name
#   is the text after that up to the first literal " [" or " - ", or to the end
#   of the line when neither follows.
#
#   Known ambiguity: a queried name that is a leading prefix of a longer
#   registered name followed by " - " (querying "Acme" against "- Acme - Site
#   ...") matches that longer row, and the enumeration lists such a name only up
#   to its first " - " ("Acme").
#
#   Seeding (a name copied into a secondmate home's registry): a name that
#   contains " - " or " [" cannot be told apart from a description or an
#   annotation, so fm_project_registry_name_ok refuses it and bin/fm-home-seed.sh
#   calls it before it touches anything. A name with plain spaces is fine. The
#   remote seed and provisioner already accept only names without spaces.
#   Removal (a reseed dropping the entries for the seeded names): every line
#   that belongs to a seeded name under the lookup rule is removed, so the
#   reseed replaces that entry instead of duplicating it.
#
# Sourced, not executed. It defines:
#   FM_PROJECT_REGISTRY_AWK   awk source to prepend to an awk program:
#                             fm_registry_match(line, n) returns 1 when line is
#                             the entry for n under the lookup rule and sets
#                             FM_REG_AFTER to the rest of the line after n;
#                             fm_registry_name(line) returns the entry's name
#                             under the enumeration rule ("" for a non-entry).
#   fm_project_registry_line <file|-> <name>    print the first entry for <name>;
#                                               status 1 when there is none
#   fm_project_registry_names <file|->          print every registered name, one
#                                               per line
#   fm_project_registry_name_ok <name>          status 0 when <name> can be
#                                               seeded; otherwise print why to
#                                               stderr and return 1
#   fm_project_registry_without <file|-> <name>...
#                                               print the input minus the entries
#                                               for the given names

# shellcheck disable=SC2016 # awk source, expanded by awk rather than the shell
FM_PROJECT_REGISTRY_AWK='
function fm_registry_match(line, n,   prefix, plen, after) {
  FM_REG_AFTER = "";
  if (n == "") return 0;
  prefix = "- " n; plen = length(prefix);
  if (substr(line, 1, plen) != prefix) return 0;
  after = substr(line, plen + 1);
  if (after != "" && substr(after, 1, 2) != " [" && substr(after, 1, 3) != " - ") return 0;
  FM_REG_AFTER = after;
  return 1;
}
function fm_registry_name(line,   rest, b, d, e) {
  if (substr(line, 1, 2) != "- ") return "";
  rest = substr(line, 3);
  b = index(rest, " ["); d = index(rest, " - ");
  e = (b && (!d || b < d)) ? b : d;
  return e ? substr(rest, 1, e - 1) : rest;
}
'

fm_project_registry_line() {  # <file|-> <name>
  awk -v n="$2" "$FM_PROJECT_REGISTRY_AWK"'
    fm_registry_match($0, n) { print; found = 1; exit }
    END { exit (found ? 0 : 1) }
  ' "$1"
}

fm_project_registry_names() {  # <file|->
  awk "$FM_PROJECT_REGISTRY_AWK"'
    { name = fm_registry_name($0); if (name != "") print name }
  ' "$1"
}

fm_project_registry_name_ok() {  # <name>
  case "$1" in
    *' - '*|*' ['*)
      echo "error: project $1 contains \" - \" or \" [\", which the project registry cannot tell apart from a description or annotation; rename the project (directory and registry entry) without that sequence and seed again" >&2
      return 1 ;;
  esac
}

fm_project_registry_without() {  # <file|-> <name>...
  local file=$1 names
  shift
  names=$(printf '%s\n' "$@" | awk '{ printf "%s%s", sep, $0; sep="\034" }')
  awk -v names="$names" "$FM_PROJECT_REGISTRY_AWK"'
    BEGIN { k = split(names, a, "\034") }
    { for (i = 1; i <= k; i++) if (fm_registry_match($0, a[i])) next; print }
  ' "$file"
}
