#!/usr/bin/env bash
# Azure DevOps Boards REST helpers for the board-automation daemon
# (bin/fm-board-daemon.sh). Every call is ONE short-lived curl parsed with a
# single python3 pass, so a poll cycle stays cheap (see the CPU-safety notes in
# docs/board-automation/README.md). The full-access PAT (ADO_PAT_FULL_ACCESS) is read
# from the environment - the daemon sources it from ~/.env - and is NEVER
# printed: the auth header is built on the fly and only handed to curl.
#
# Board coordinates default to the live "Hadrien FirstMate" board and are all
# env-overridable so the same code can point at a test board:
#   FM_BOARD_ORG_URL       collection/project base, e.g. https://dev.azure.com/talroo/Product
#   FM_BOARD_AREA_PATH     work-item area path (single backslash), e.g. Product\Hadrien FirstMate
#   FM_BOARD_COLUMN_FIELD  the board Kanban.Column reference name
#   FM_BOARD_LANE_FIELD    the board Kanban.Lane reference name
#   FM_BOARD_API_VERSION   REST api-version (default 7.0)
#   FM_BOARD_CURL_TIMEOUT  per-call --max-time seconds (default 25)

FM_BOARD_ORG_URL="${FM_BOARD_ORG_URL:-https://dev.azure.com/talroo/Product}"
# Single backslash between project and team-area, as the board stores it.
FM_BOARD_AREA_PATH="${FM_BOARD_AREA_PATH:-Product\\Hadrien FirstMate}"
FM_BOARD_COLUMN_FIELD="${FM_BOARD_COLUMN_FIELD:-WEF_BABA3EEA87FD424E9CFBCA5DBD7D9953_Kanban.Column}"
FM_BOARD_LANE_FIELD="${FM_BOARD_LANE_FIELD:-WEF_BABA3EEA87FD424E9CFBCA5DBD7D9953_Kanban.Lane}"
FM_BOARD_API_VERSION="${FM_BOARD_API_VERSION:-7.0}"
FM_BOARD_CURL_TIMEOUT="${FM_BOARD_CURL_TIMEOUT:-25}"

# Prints the Basic auth header value. Returns non-zero (and prints nothing) when
# the PAT is not in the environment, so callers can flag a config problem
# instead of firing an unauthenticated request. Keep the result out of any log.
fm_board_auth_header() {
  [ -n "${ADO_PAT_FULL_ACCESS:-}" ] || return 1
  printf 'Authorization: Basic %s' "$(printf ':%s' "$ADO_PAT_FULL_ACCESS" | base64 | tr -d '\n')"
}

# fm_board_curl <method> <url> [json-body]
# One short-lived request. Content-Type defaults to application/json; override
# with FM_BOARD_CONTENT_TYPE (json-patch writes need application/json-patch+json).
# On an HTTP error status curl still prints the body but this returns non-zero so
# the caller does not treat an error payload as data.
fm_board_curl() {
  local method=$1 url=$2 data=${3:-} auth ctype
  auth=$(fm_board_auth_header) || return 3
  ctype="${FM_BOARD_CONTENT_TYPE:-application/json}"
  if [ -n "$data" ]; then
    curl -sS --fail-with-body --max-time "$FM_BOARD_CURL_TIMEOUT" \
      -X "$method" -H "$auth" -H "Content-Type: $ctype" "$url" -d "$data"
  else
    curl -sS --fail-with-body --max-time "$FM_BOARD_CURL_TIMEOUT" \
      -X "$method" -H "$auth" "$url"
  fi
}

# Reads a batch-workitems JSON payload ({"value":[{"fields":{...}},...]}) on
# stdin and prints one TSV row per card:
#   id \t state \t column \t lane \t tags \t title
# Tabs/newlines in free-text fields are flattened to spaces so the TSV parses
# cleanly downstream. The column/lane reference names come from the environment.
fm_board_parse_cards() {
  # NOTE: uses `python3 -c` (not `python3 - <<HEREDOC`) precisely because this
  # reads the CARD DATA from stdin - a heredoc would itself occupy stdin and
  # python would parse the script text instead of the payload.
  FM_BOARD_COLUMN_FIELD="$FM_BOARD_COLUMN_FIELD" \
  FM_BOARD_LANE_FIELD="$FM_BOARD_LANE_FIELD" \
  python3 -c '
import sys, os, json
col = os.environ["FM_BOARD_COLUMN_FIELD"]
lane = os.environ["FM_BOARD_LANE_FIELD"]
def flat(v):
    if v is None:
        return ""
    return " ".join(str(v).replace("\t", " ").split("\n"))
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(4)
for w in d.get("value", []):
    f = w.get("fields", {})
    row = [
        str(f.get("System.Id", w.get("id", ""))),
        flat(f.get("System.State")),
        flat(f.get(col)),
        flat(f.get(lane)),
        flat(f.get("System.Tags")),
        flat(f.get("System.Title")),
    ]
    print("\t".join(row))
'
}

# Lists every card in the configured area path as TSV rows (see
# fm_board_parse_cards for the columns). This is the daemon's single board read
# per cycle: one WIQL POST to enumerate ids, then batch workitems GET(s) for the
# fields - chunked at 200 ids (the batch API cap) so a growing board still works.
# Prints nothing and returns 0 when the area has no items; returns non-zero on a
# query/transport error so the caller can skip the cycle rather than treat an
# empty result as "board cleared".
fm_board_list_cards() {
  local wiql_body ids fields
  wiql_body=$(FM_BOARD_AREA_PATH="$FM_BOARD_AREA_PATH" python3 - <<'PY'
import os, json
area = os.environ["FM_BOARD_AREA_PATH"]
q = "SELECT [System.Id] FROM WorkItems WHERE [System.AreaPath] = '%s'" % area
print(json.dumps({"query": q}))
PY
)
  local wiql_resp
  wiql_resp=$(fm_board_curl POST \
    "$FM_BOARD_ORG_URL/_apis/wit/wiql?api-version=$FM_BOARD_API_VERSION" \
    "$wiql_body") || return 5
  ids=$(printf '%s' "$wiql_resp" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(4)
print(",".join(str(w["id"]) for w in d.get("workItems", [])))') || return 4
  [ -n "$ids" ] || return 0

  fields="System.Id,System.State,System.Title,System.Tags,$FM_BOARD_COLUMN_FIELD,$FM_BOARD_LANE_FIELD"
  # Chunk ids into groups of 200 (batch workitems cap). awk emits one
  # comma-joined chunk per line; each chunk is one GET whose payload is parsed
  # straight to TSV, so chunks concatenate transparently.
  local chunk rc=0
  while IFS= read -r chunk; do
    [ -n "$chunk" ] || continue
    fm_board_curl GET \
      "$FM_BOARD_ORG_URL/_apis/wit/workitems?ids=$chunk&fields=$fields&api-version=$FM_BOARD_API_VERSION" \
      | fm_board_parse_cards || rc=$?
  done < <(printf '%s' "$ids" | tr ',' '\n' \
    | awk 'NR%200==1{if(b!="")print b; b=$0; next}{b=b","$0} END{if(b!="")print b}')
  return "$rc"
}

# fm_board_get_item <id> - raw work-item JSON (single item, all default fields
# plus relations). Callers parse what they need with python.
fm_board_get_item() {
  local id=$1
  fm_board_curl GET \
    "$FM_BOARD_ORG_URL/_apis/wit/workitems/$id?\$expand=relations&api-version=$FM_BOARD_API_VERSION"
}

# fm_board_set_column <id> <column-value> - move a card to another board column
# by patching the Kanban.Column field (the board columns that share one
# System.State are distinguished only by this field). Best-effort; returns
# curl's status. Not used on the daemon's spawn path (agents move their own
# cards at milestones), but provided for completeness and tests.
fm_board_set_column() {
  local id=$1 col=$2 body
  body=$(FM_BOARD_COLUMN_FIELD="$FM_BOARD_COLUMN_FIELD" FM_BOARD_COL_VALUE="$col" python3 - <<'PY'
import os, json
print(json.dumps([{
    "op": "add",
    "path": "/fields/%s" % os.environ["FM_BOARD_COLUMN_FIELD"],
    "value": os.environ["FM_BOARD_COL_VALUE"],
}]))
PY
)
  FM_BOARD_CONTENT_TYPE='application/json-patch+json' fm_board_curl PATCH \
    "$FM_BOARD_ORG_URL/_apis/wit/workitems/$id?api-version=$FM_BOARD_API_VERSION" "$body" >/dev/null
}

# fm_board_add_comment <id> <text> - post a discussion comment on a card so a
# daemon action is visible on the board. Best-effort. The comments API is under
# a -preview api-version.
fm_board_add_comment() {
  local id=$1 text=$2 body
  body=$(FM_BOARD_COMMENT_TEXT="$text" python3 - <<'PY'
import os, json
print(json.dumps({"text": os.environ["FM_BOARD_COMMENT_TEXT"]}))
PY
)
  fm_board_curl POST \
    "$FM_BOARD_ORG_URL/_apis/wit/workItems/$id/comments?api-version=7.0-preview.3" \
    "$body" >/dev/null
}
