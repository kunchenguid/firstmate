#!/usr/bin/env bash
# fm-jq-lib.sh - the single owner of passing document-sized JSON to jq.
#
# Sourced, never executed.
#
# jq binds --argjson and --arg values through argv, and Linux caps a SINGLE
# argv string at MAX_ARG_STRLEN (128 KiB) independently of the far larger total
# ARG_MAX, so a document-sized value passed that way makes jq die with E2BIG the
# moment the document outgrows that one cap. The failure is total rather than
# degraded: the whole command aborts, so a home whose backlog, task set, or
# cross-home aggregate crosses the threshold loses the command entirely.
#
#   fm_jq_docs <name> <json> [<name> <json>]... -- <jq-arg>...
#       Streams each document in on jq's own input and binds it to $<name>, then
#       runs jq with the remaining arguments. The last jq argument is the filter,
#       and this prefixes the bindings onto it, so a filter body reading
#       $backlog is unchanged from its --argjson form. Callers pass -n, because
#       the documents occupy jq's input stream. Exit status and stdout are jq's;
#       a caller error returns 2 before jq runs.
#
# The rule this exists to hold: argv carries only values with a fixed structural
# bound - scalars, booleans, and {path,present} objects - while every value whose
# size follows file, log, backlog, or fleet content goes through fm_jq_docs.
set -u

fm_jq_docs() {
  local names=() docs=() prefix='' i last args
  while [ "$#" -gt 0 ] && [ "$1" != '--' ]; do
    if [ "$#" -lt 2 ]; then
      echo "fm-jq-lib: fm_jq_docs got no value for document '$1'" >&2
      return 2
    fi
    names[${#names[@]}]=$1
    docs[${#docs[@]}]=$2
    shift 2
  done
  if [ "${1:-}" != '--' ] || [ "${#names[@]}" -eq 0 ] || [ "$#" -lt 2 ]; then
    echo "fm-jq-lib: fm_jq_docs needs at least one document and -- <jq-arg>..." >&2
    return 2
  fi
  shift
  i=0
  while [ "$i" -lt "${#names[@]}" ]; do
    prefix="$prefix(\$fm_jq_docs[$i]) as \$${names[$i]} | "
    i=$((i + 1))
  done
  args=("$@")
  last=$((${#args[@]} - 1))
  args[last]="[inputs] as \$fm_jq_docs | $prefix${args[last]}"
  printf '%s\n' "${docs[@]}" | jq "${args[@]}"
}
