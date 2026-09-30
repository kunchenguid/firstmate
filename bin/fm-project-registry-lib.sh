#!/usr/bin/env bash
# fm-project-registry-lib.sh - single owner of where a data/projects.md entry's
# project name starts and ends, so every reader of the project registry agrees
# on which line belongs to which project, including a name that contains spaces.
#
# bin/fm-project-mode.sh's header owns the rest of the line format and the
# bracketed annotation tokens. This file owns only the name, with two rules:
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
#   Removal (a reseed dropping the entries for selected names): removal never
#   deletes a line that may belong to another project, because a duplicate line
#   is recoverable and a lost registration or posture is not. A line matching a
#   selected name n under the lookup rule is kept when (1) a longer known name
#   (the caller passes the home's clone names and the names being seeded) also
#   matches it, since the line is that name's entry; or (2) the text after n
#   starts with " - " and a " [" follows later ("- foo bar - baz [local-only]
#   ..." for n "foo bar"), since the dashed part may belong to a longer name;
#   that line is kept with a warning on stderr. Otherwise (the text after n is
#   empty, starts with " [", or starts with " - " with no later " [") the line
#   is removed.
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
#   fm_project_registry_without <file|-> <known> <name>...
#                                               print the input minus the entries
#                                               for the given names under the
#                                               removal rule; <known> is a
#                                               newline-separated list of other
#                                               known project names

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

fm_project_registry_without() {  # <file|-> <known> <name>...
  local file=$1 known=$2 names
  shift 2
  names=$(printf '%s\n' "$@" | awk '{ printf "%s%s", sep, $0; sep="\034" }')
  known=$(printf '%s\n' "$known" | awk 'NF { printf "%s%s", sep, $0; sep="\034" }')
  awk -v names="$names" -v known="$known" "$FM_PROJECT_REGISTRY_AWK"'
    BEGIN { k = split(names, a, "\034"); kk = split(known, m, "\034"); for (i = 1; i <= k; i++) m[++kk] = a[i] }
    function fm_registry_owned(line, n,   after, j) {
      if (!fm_registry_match(line, n)) return 0;
      after = FM_REG_AFTER;
      if (substr(after, 1, 3) != " - ") return 1;
      for (j = 1; j <= kk; j++)
        if (length(m[j]) > length(n) && fm_registry_match(line, m[j])) return 0;
      if (!index(substr(after, 4), " [")) return 1;
      print "warning: keeping registry line that may belong to a longer project name than " n ": " line > "/dev/stderr";
      return 0;
    }
    { for (i = 1; i <= k; i++) if (fm_registry_owned($0, a[i])) next; print }
  ' "$file"
}
