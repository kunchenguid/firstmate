#!/usr/bin/env bash
# Shared Linear client for firstmate's mirror of data/backlog.md (fm-linear-pr-link.sh
# and fm-linear-refresh.sh). Linear is a BROWSABLE VIEW, never a gate: the backlog
# stays authoritative, and every call site here must degrade quietly.
#
# Opt-in exactly like X mode: a non-empty LINEAR_API_KEY in the firstmate home's
# gitignored .env (or the environment) turns it on. Absent, every entry point is a
# hard no-op that prints what did not happen and succeeds.
#
# The join between a firstmate task and its Linear issue is the FIRST LINE of the
# issue description, written by the original mirror as a markdown code span:
#   `firstmate: <task-id>`
# Backticks are stripped before comparison, so a plain "firstmate: <id>" first line
# joins too. Nothing else - not the branch name, not the title - is load-bearing.
#
# This file is sourced, never executed. It defines:
#   fml_env_get <key> <file>     - read one KEY=VALUE from a .env-style file
#   fml_load_config              - resolve FML_KEY/FML_API/FML_TEAM/FML_MAGIC/FML_TIMEOUT
#   fml_available                - 0 when configured and curl+jq exist, else 1
#   fml_unavailable_reason       - one-line reason fml_available returned 1
#   fml_graphql <query> <vars-json> <body-file> [timeout] - POST one GraphQL request
#   fml_mutation_succeeded <body-file> <field> - verify a mutation payload succeeded
#   fml_marker_id <first-line>   - task id from a description's first line, or empty
#   fml_find_issue <task-id>     - locate the mirrored issue for one task id
#   fml_reference_line <identifier> - the exact magic-word line firstmate appends
#   fml_body_links <body-file> <identifier> - 0 when the PR body already links it
#   fml_append_reference <body-file> <identifier> <out-file> - additive body write
# Callers must have FM_HOME set before calling fml_load_config.
#
# GraphQL documents below are single-quoted on purpose: $id and friends inside
# them are GraphQL variables, not shell expansions.
# shellcheck disable=SC2016

# Read the value of KEY from a .env-style file: last assignment wins; tolerates a
# leading "export ", surrounding whitespace, and one layer of matching single or
# double quotes. Prints nothing (and succeeds) when the file or key is absent, so
# callers can treat empty output as "unset".
fml_env_get() {
  local key=$1 file=$2 line val
  [ -f "$file" ] || return 0
  line=$(grep -E "^[[:space:]]*(export[[:space:]]+)?${key}=" "$file" 2>/dev/null | tail -n1) || return 0
  [ -n "$line" ] || return 0
  val=${line#*=}
  val=${val#"${val%%[![:space:]]*}"}   # strip leading whitespace
  val=${val%"${val##*[![:space:]]}"}   # strip trailing whitespace (incl. CR)
  case "$val" in
    \"*\") val=${val#\"}; val=${val%\"} ;;
    \'*\') val=${val#\'}; val=${val%\'} ;;
  esac
  printf '%s' "$val"
}

# Resolve the Linear settings into FML_KEY, FML_API, FML_TEAM, FML_MAGIC and
# FML_TIMEOUT. An explicit environment variable always wins over the .env file.
#
# LINEAR_API_KEY    the only required value; absent means Linear support is inert
# LINEAR_API_URL    defaults to Linear's production GraphQL endpoint
# LINEAR_TEAM_KEY   optional team key (e.g. PSY) scoping refresh; lookup ignores it
# LINEAR_MAGIC_WORD defaults to "Part of" - see fml_reference_line for why a
#                   NON-CLOSING magic word is the default
# LINEAR_TIMEOUT    per-request curl timeout in seconds, floor 1, default 10; the
#                   PR path lowers it further so a slow Linear can never delay a
#                   PR from being checked.
fml_load_config() {
  local env_file="${FM_LINEAR_ENV_FILE:-${FM_HOME:-}/.env}" raw
  if [ -n "${LINEAR_API_KEY+x}" ]; then
    FML_KEY=${LINEAR_API_KEY-}
  else
    FML_KEY=$(fml_env_get LINEAR_API_KEY "$env_file")
  fi
  if [ -n "${LINEAR_API_URL+x}" ]; then
    FML_API=${LINEAR_API_URL-}
  else
    FML_API=$(fml_env_get LINEAR_API_URL "$env_file")
  fi
  [ -n "$FML_API" ] || FML_API="https://api.linear.app/graphql"
  # shellcheck disable=SC2034 # FML_TEAM is read by callers (fm-linear-refresh.sh) after sourcing.
  if [ -n "${LINEAR_TEAM_KEY+x}" ]; then
    FML_TEAM=${LINEAR_TEAM_KEY-}
  else
    FML_TEAM=$(fml_env_get LINEAR_TEAM_KEY "$env_file")
  fi
  if [ -n "${LINEAR_MAGIC_WORD+x}" ]; then
    FML_MAGIC=${LINEAR_MAGIC_WORD-}
  else
    FML_MAGIC=$(fml_env_get LINEAR_MAGIC_WORD "$env_file")
  fi
  [ -n "$FML_MAGIC" ] || FML_MAGIC="Part of"
  if [ -n "${LINEAR_TIMEOUT+x}" ]; then
    raw=${LINEAR_TIMEOUT-}
  else
    raw=$(fml_env_get LINEAR_TIMEOUT "$env_file")
  fi
  case "$raw" in ''|*[!0-9]*) raw=10 ;; esac
  [ "$raw" -ge 1 ] 2>/dev/null || raw=10
  # shellcheck disable=SC2034 # read by callers after sourcing.
  FML_TIMEOUT=$raw
}

# Why "Part of" and not "Fixes": both are magic words Linear recognizes in a PR
# body, but a CLOSING word ("fixes", "closes", "resolves", ...) also drives the
# issue's status on merge. The captain's 2026-08-02 decision makes data/backlog.md
# authoritative and Linear a regenerated view, and fm-linear-refresh.sh owns the
# Done transition. A non-closing word links without a second writer competing for
# status. Set LINEAR_MAGIC_WORD to a closing word to opt into merge automation.
fml_reference_line() {
  printf '%s %s' "${FML_MAGIC:-Part of}" "$1"
}

fml_unavailable_reason() {
  if [ -z "${FML_KEY:-}" ]; then
    printf 'no LINEAR_API_KEY configured'
    return 0
  fi
  command -v curl >/dev/null 2>&1 || { printf 'curl not found'; return 0; }
  command -v jq >/dev/null 2>&1 || { printf 'jq not found'; return 0; }
  printf 'available'
}

# 0 when Linear support is configured and its dependencies exist, 1 otherwise.
# Requires fml_load_config to have run.
fml_available() {
  [ -n "${FML_KEY:-}" ] || return 1
  command -v curl >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1
}

# Write the Authorization header to a 0600 temp file and print its path.
# Linear personal API keys ("lin_api_...") are sent as the bare header value;
# OAuth access tokens need the Bearer scheme.
fml_auth_header_file() {
  local file scheme=
  case "$FML_KEY" in
    *$'\n'*|*$'\r'*) return 1 ;;
    lin_oauth_*|Bearer\ *) scheme=Bearer ;;
  esac
  file=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-linear-auth.XXXXXX") || return 1
  chmod 600 "$file" 2>/dev/null || { rm -f "$file"; return 1; }
  if [ "$scheme" = Bearer ]; then
    printf 'Authorization: Bearer %s\n' "${FML_KEY#Bearer }" > "$file" || { rm -f "$file"; return 1; }
  else
    printf 'Authorization: %s\n' "$FML_KEY" > "$file" || { rm -f "$file"; return 1; }
  fi
  printf '%s\n' "$file"
}

# fml_graphql <query> <variables-json> <body-file> [timeout]: POST one GraphQL
# request; the response body lands in <body-file>. Returns 0 only on a 2xx that
# carries no "errors" array, so callers never have to distinguish transport
# failure from a GraphQL-level failure - both are "Linear did not answer".
# Exit codes: 1 unusable input/auth, 4 transport failure, 5 non-2xx, 6 GraphQL errors.
fml_graphql() (
  local query=$1 vars=${2:-'{}'} body_file=$3 timeout=${4:-${FML_TIMEOUT:-10}}
  local payload auth_header_file code rc
  payload=$(mktemp "${TMPDIR:-/tmp}/fm-linear-payload.XXXXXX") || return 1
  auth_header_file=$(fml_auth_header_file) || { rm -f "$payload"; return 1; }
  trap 'rm -f "$payload" "$auth_header_file"' EXIT
  trap 'rm -f "$payload" "$auth_header_file"; exit 143' HUP INT TERM
  if ! jq -cn --arg q "$query" --argjson v "$vars" '{query:$q, variables:$v}' > "$payload" 2>/dev/null; then
    return 1
  fi
  code=$(curl -m "$timeout" -s -o "$body_file" -w '%{http_code}' \
    -X POST \
    -H "@$auth_header_file" \
    -H 'Content-Type: application/json' \
    --data-binary "@$payload" \
    "$FML_API" 2>/dev/null)
  rc=$?
  [ "$rc" = 0 ] || return 4
  case "$code" in
    2[0-9][0-9]) ;;
    *) return 5 ;;
  esac
  jq -e 'has("errors") | not' "$body_file" >/dev/null 2>&1 || return 6
  return 0
)

fml_mutation_succeeded() {
  local body_file=$1 field=$2
  jq -e --arg field "$field" '.data[$field].success == true' "$body_file" >/dev/null 2>&1
}

# fml_marker_id <first-line>: print the task id a mirrored description's first
# line encodes, or nothing. Strips backticks and whitespace, so both
# "`firstmate: 010-x`" (what the mirror writes) and "firstmate: 010-x" join.
fml_marker_id() {
  local line=$1
  line=${line//\`/}
  line=${line%$'\r'}
  line=${line#"${line%%[![:space:]]*}"}
  line=${line%"${line##*[![:space:]]}"}
  case "$line" in
    firstmate:*) ;;
    *) return 0 ;;
  esac
  line=${line#firstmate:}
  line=${line#"${line%%[![:space:]]*}"}
  line=${line%"${line##*[![:space:]]}"}
  case "$line" in
    *[[:space:]]*) return 0 ;;   # a first line with more words is not a marker
  esac
  printf '%s' "$line"
}

# The jq filter that turns a Linear issues query result into one TSV row per
# issue whose description's FIRST LINE is exactly the "firstmate: <id>" marker.
# Columns: task-id, identifier, issue uuid, url, status name, status type.
# Backtick stripping and the exact first-line match mirror fml_marker_id, so a
# description merely MENTIONING a task id elsewhere never counts as a join.
FML_ROWS_FILTER='
  def marker_id:
    (. // "") | split("\n")[0] | gsub("`"; "") | gsub("^\\s+|\\s+$"; "")
    | if startswith("firstmate:")
      then (.[10:] | gsub("^\\s+|\\s+$"; ""))
      else "" end
    | if test("\\s") then "" else . end;
  .data.issues.nodes[]
  | (.description | marker_id) as $id
  | select($id != "")
  | [$id, .identifier, .id, .url, (.state.name // ""), (.state.type // "")]
  | @tsv
'

# fml_find_issue <task-id>: print one TSV row (see FML_ROWS_FILTER, minus the
# leading task id) for the mirrored issue joined to <task-id>.
# Exit 0 with output = found; exit 1 = Linear answered and has no such issue;
# exit 2 = Linear could not be asked (callers must treat this as "unknown", never
# as "no issue"). The server-side filter narrows the fetch; the exact first-line
# match happens here, so "004" never matches "004-something-else".
fml_find_issue() {
  local id=$1 body vars rc rows
  fml_available || return 2
  body=$(mktemp "${TMPDIR:-/tmp}/fm-linear-find.XXXXXX") || return 2
  vars=$(jq -cn --arg needle "firstmate: $id" '{needle:$needle}') || { rm -f "$body"; return 2; }
  # shellcheck disable=SC2016 # GraphQL variables, not shell expansions.
  fml_graphql 'query fmFind($needle: String!) {
    issues(filter: { description: { contains: $needle } }, first: 50) {
      nodes { id identifier url description state { name type } }
    }
  }' "$vars" "$body" "${FML_TIMEOUT:-10}"
  rc=$?
  # The server-side description filter is only an optimisation. If Linear ever
  # rejects it, fall back to scanning recent issues and matching here, so a
  # schema change degrades to "slower" rather than "silently never links".
  if [ "$rc" = 6 ]; then
    # shellcheck disable=SC2016
    fml_graphql 'query fmFindAll {
      issues(first: 250, orderBy: updatedAt) {
        nodes { id identifier url description state { name type } }
      }
    }' '{}' "$body" "${FML_TIMEOUT:-10}"
    rc=$?
  fi
  if [ "$rc" != 0 ]; then rm -f "$body"; return 2; fi
  rows=$(jq -r "$FML_ROWS_FILTER" "$body" 2>/dev/null | awk -F'\t' -v id="$id" '$1 == id {print $2 "\t" $3 "\t" $4 "\t" $5 "\t" $6}')
  rm -f "$body"
  [ -n "$rows" ] || return 1
  printf '%s\n' "$rows" | head -n1
}

# fml_body_links <body-file> <identifier>: 0 when the PR body already carries a
# real reference. Two independent signals, either of which means "leave it
# alone": firstmate's own marker comment, or a magic word followed by the
# identifier (someone - the author, the pipeline - already linked it).
# This is what makes running the PR check twice add the reference exactly once.
#
# A BARE mention of the identifier deliberately does NOT count. Linear only
# links from a PR body when a magic word precedes the ID, so treating any
# occurrence as "already linked" would silently skip a PR that merely discusses
# the issue - which is exactly what this feature's own PR does, quoting its
# issue id in prose. The list form ("Fixes ENG-1, DES-5 and ENG-2") and a
# configured LINEAR_MAGIC_WORD are both recognised.
fml_body_links() {
  local body_file=$1 ident=$2 words
  grep -qF -- '<!-- firstmate:linear -->' "$body_file" 2>/dev/null && return 0
  words='close[sd]?|closing|fix|fixe[sd]|fixing|resolve[sd]?|resolving'
  words="$words|complete[sd]?|completing|implement|implements|implemented|implementing|linear issue"
  words="$words|refs?|references|part of|related to|relates to|contributes to|towards?"
  if [ -n "${FML_MAGIC:-}" ]; then
    words="$words|$(printf '%s' "$FML_MAGIC" | sed 's/[][\.*^$(){}?+|/]/\\&/g')"
  fi
  grep -qiE -- "(^|[^A-Za-z0-9_-])(${words})[[:space:]]+([A-Za-z0-9_-]+[,[:space:]]+(and[[:space:]]+)?)*${ident}([^A-Za-z0-9_-]|$)" \
    "$body_file" 2>/dev/null && return 0
  return 1
}

# fml_append_reference <body-file> <identifier> <out-file>: write <body-file> and
# then the reference block to <out-file>. STRICTLY ADDITIVE by construction - the
# original bytes are copied first and never parsed, rewritten, or reordered, so
# the validation pipeline's evidence record in the PR body survives untouched.
# Callers must still verify the prefix before pushing (fm-linear-pr-link.sh does).
fml_append_reference() {
  local body_file=$1 ident=$2 out=$3
  cat "$body_file" > "$out" || return 1
  # Guarantee the block starts on its own line even if the body had no trailing
  # newline; a body that already ends blank does not gain a third blank line.
  [ -s "$body_file" ] && printf '\n\n' >> "$out"
  {
    printf '<!-- firstmate:linear -->\n'
    fml_reference_line "$ident"
    printf '\n'
  } >> "$out" || return 1
}
