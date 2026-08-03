# shellcheck shell=bash
# Record which dispatch ROUTE and capability FLOOR a task was spawned at.
#
# This is a SENSOR, not a policy layer. It reads values that routing policy has
# already assigned and writes them into state/<id>.meta at spawn. It matches no
# rule, chooses no profile, enforces no floor, and changes no routing behavior.
# Routing policy - which route a task belongs to, what floor that route requires,
# and how either is identified - is owned by config/crew-dispatch.json and the
# firstmate agent that reads it (docs/configuration.md "Crew dispatch profiles").
#
# WHY it exists: run-time capability intervention may never lower a task's
# original capability floor, and an escalation cannot be checked against a floor
# that was never written down. Recording the floor is the prerequisite for
# checking one. Nothing reads these fields yet.
#
# Usage: . bin/fm-dispatch-record-lib.sh
#
# Public entry point:
#   fm_dispatch_record_lines <config-dir> <declared-route>
#     Prints exactly three meta lines, in order and always non-empty:
#       route=<id|unknown>
#       floor=<id|unknown>
#       policy_revision=<value|unknown>
#     It ALWAYS returns 0: a missing, unreadable, or malformed dispatch config
#     records `unknown` and never aborts a spawn.
#
# Resolution, and the distinction that must survive:
#   <declared-route> is the route the DISPATCHER matched, passed to
#   bin/fm-spawn.sh as --route. Firstmate is the only thing that matches a
#   natural-language dispatch rule, so the route is declared rather than
#   inferred here; guessing which rule produced a given harness/model/effort
#   triple would be a second, weaker owner of route identity.
#     - A rule's route id resolves that rule's `floor`.
#     - The reserved token `default` means the dispatch matched NO rule and fell
#       through to the config's `default` profile; its `route` and `floor` are
#       recorded, so "resolved to the default" stays a positive fact.
#     - Anything that cannot be resolved records the literal token `unknown`:
#       no route declared, no dispatch config, no jq, a route absent from the
#       config, a route whose rules disagree about the floor, or a value that
#       fails the identifier check below.
#   `unknown` is written explicitly and is never omitted, blank, or carried over
#   from another task, because a field that is populated only on the happy path
#   makes a floor LOOK recorded while under-reporting it - worse than having no
#   field at all, since later escalation logic would trust it.
#
# Fields read (all optional; absent means `unknown`, never an error):
#   .rules[].route   .rules[].floor   .default.route   .default.floor
#   ._policy.version   recorded verbatim as policy_revision
#
# A route or floor id must match FM_DISPATCH_ID_RE. policy_revision is prose, so
# it is only reduced to its first line with control characters stripped; it is
# never truncated, because a shortened revision string is a different revision
# string that still compares equal to nothing.

# The reserved declared-route token meaning "matched no rule, took the default".
FM_DISPATCH_DEFAULT_ROUTE=default
# The reserved recorded value meaning "could not be resolved".
FM_DISPATCH_UNKNOWN=unknown
# Route and floor identifiers: a printable, single-token id. Deliberately narrow
# so nothing that could break a key=value meta line - whitespace, a newline, a
# control character - is ever recorded as an identity.
FM_DISPATCH_ID_RE='^[A-Za-z0-9][A-Za-z0-9._:+/-]{0,127}$'

# fm_dispatch_id_valid <value>: true when <value> is a usable route/floor id.
# Matched with bash's own [[ =~ ]] rather than grep, because grep applies the
# anchors per LINE: a value whose first line is a valid id and whose second line
# is a forged `kind=secondmate` would pass a grep check and then split the
# key=value record in two.
fm_dispatch_id_valid() {
  [ -n "${1:-}" ] || return 1
  [[ $1 =~ $FM_DISPATCH_ID_RE ]]
}

# _fm_dispatch_query <config-file> <jq-filter> [jq-arg...]: echo the filter's
# string result, or nothing when jq is unavailable, the file is unreadable, the
# JSON is malformed, or the value is absent/null/empty.
_fm_dispatch_query() {
  local file=$1 filter=$2 out
  shift 2
  command -v jq >/dev/null 2>&1 || return 0
  [ -f "$file" ] && [ -r "$file" ] || return 0
  out=$(jq -r "$@" "$filter" < "$file" 2>/dev/null) || return 0
  [ "$out" = null ] && return 0
  printf '%s' "$out"
}

# _fm_dispatch_id_or_unknown <value>: echo <value> when it is a valid id, else
# the unknown token.
_fm_dispatch_id_or_unknown() {
  if fm_dispatch_id_valid "${1:-}"; then printf '%s' "$1"; else printf '%s' "$FM_DISPATCH_UNKNOWN"; fi
}

# fm_dispatch_record_lines <config-dir> <declared-route>
fm_dispatch_record_lines() {
  local config_dir=${1:-} declared=${2:-} file route floor revision
  file="$config_dir/crew-dispatch.json"

  if [ -z "$declared" ]; then
    # Nothing was declared, so no rule identity exists to resolve. Falling back
    # to the config's default here would record a route this dispatch never
    # took, which is the one failure mode this field must not have.
    route=$FM_DISPATCH_UNKNOWN
    floor=$FM_DISPATCH_UNKNOWN
  elif [ "$declared" = "$FM_DISPATCH_DEFAULT_ROUTE" ]; then
    route=$(_fm_dispatch_id_or_unknown "$(_fm_dispatch_query "$file" '.default.route // empty')")
    floor=$(_fm_dispatch_id_or_unknown "$(_fm_dispatch_query "$file" '.default.floor // empty')")
  else
    route=$(_fm_dispatch_id_or_unknown "$declared")
    # One distinct floor across every rule carrying this route id. Rules that
    # disagree make the floor genuinely ambiguous, and an ambiguous floor is
    # unknown rather than whichever rule happened to be listed first.
    # shellcheck disable=SC2016  # $r is a jq variable bound by --arg, not a shell one
    floor=$(_fm_dispatch_id_or_unknown "$(_fm_dispatch_query "$file" \
      '[.rules[]? | select(.route == $r) | .floor // empty] | unique | if length == 1 then .[0] else empty end' \
      --arg r "$declared")")
  fi

  # First line only, every remaining control character folded to a space, runs of
  # whitespace collapsed, ends trimmed. Enough to keep the key=value record
  # intact and comparable, and deliberately no truncation.
  revision=$(_fm_dispatch_query "$file" '._policy.version // empty')
  if [ -n "$revision" ]; then
    revision=${revision%%$'\n'*}
    revision=$(printf '%s' "$revision" | tr '\000-\037\177' ' ' | tr -s ' ')
    revision=${revision#" "}
    revision=${revision%" "}
  fi
  [ -n "$revision" ] || revision=$FM_DISPATCH_UNKNOWN

  printf 'route=%s\n' "$route"
  printf 'floor=%s\n' "$floor"
  printf 'policy_revision=%s\n' "$revision"
}
