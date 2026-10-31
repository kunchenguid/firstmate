#!/usr/bin/env bash
# Resolve a folder to one registered project coordinator, without launching a session.
# Usage: FM_HOME=<primary-home> fm-entry.sh inspect|context <folder>
#        FM_HOME=<primary-home> fm-entry.sh send <folder> --request-id <id> -- <text>
# Folder entry is a client of the existing primary, never a second supervisor.
# inspect emits JSON. context emits the role boundary, route and disk profession.
# send uses fm-inbox.sh note (including its idempotence/receipt contract); the
# primary verifies scope and delegates to its registered secondmate normally.
# No command acquires a session lock, reads a child endpoint namespace or
# changes a model, charter, profile, delivery policy or secondmate selection.
# config/project-entry.json and its defaults are owned by docs/configuration.md.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "${1:-}" = --help ]; then sed -n '2,/^set -eu/p' "$0" | sed '$d;s/^# *//'; exit 0; fi
die() { printf 'ENTRY_INVALID: %s\n' "$*" >&2; exit 1; }
[ -z "${FM_TASK_ID:-}" ] || die 'worker launch contract takes precedence; no supervisor entry'
[ -n "${FM_HOME:-}" ] && [ -d "$FM_HOME" ] || die 'set FM_HOME to the existing primary home'
[ ! -f "$FM_HOME/.fm-secondmate-home" ] || die 'use the parent primary home for project entry'
command -v jq >/dev/null || die 'jq is required'
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
DATA=${FM_DATA_OVERRIDE:-$FM_HOME/data}
CONFIG=${FM_CONFIG_OVERRIDE:-$FM_HOME/config}
PROJECTS=${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}
mode=${1:-}; folder=${2:-}; shift "$(( $# >= 2 ? 2 : $# ))"
case "$mode" in inspect|context|send) ;; *) die 'expected inspect, context or send' ;; esac
[ -d "$folder" ] || die 'folder does not exist'
common_dir() {
  local repo=$1 dir
  dir=$(git -C "$repo" rev-parse --git-common-dir 2>/dev/null) || return 1
  case "$dir" in /*) ;; *) dir="$repo/$dir" ;; esac
  (cd "$dir" && pwd -P)
}
actual=$(common_dir "$folder") || die 'folder is not a Git project'
reg="$DATA/projects.md"
[ -f "$reg" ] && [ ! -L "$reg" ] || die 'primary project registry is missing or unsafe'
names=$(awk '/^- / {s=substr($0,3); sub(/ \[.*$/, "", s); sub(/ - .*$/, "", s); print s}' "$reg")
project=''; project_path=''; count=0
while IFS= read -r name; do
  case "$name" in ''|*[!A-Za-z0-9._-]*|.|..) continue ;; esac
  path="$PROJECTS/$name"
  key=$(common_dir "$path" 2>/dev/null || true)
  if [ "$key" = "$actual" ]; then project=$name; project_path=$path; count=$((count+1)); fi
done <<< "$names"
[ "$count" -eq 1 ] || die "folder resolves to $count registered projects; require one canonical registry binding"
owner=main; owner_home=$FM_HOME; scope='Primary routing and supervision'
config="$CONFIG/project-entry.json"
if [ -e "$config" ] || [ -L "$config" ]; then
  [ -f "$config" ] && [ ! -L "$config" ] && [ "$(wc -c < "$config")" -le 65536 ] || die 'unsafe entry configuration'
  jq -e 'type=="object" and (keys-["schema_version","owners"]|length)==0 and .schema_version==1 and (.owners|type)=="object" and (.owners|to_entries|all(.[]; (.key|test("^[A-Za-z0-9][A-Za-z0-9._-]*$")) and (.value|type)=="string" and (.value|test("^[A-Za-z0-9][A-Za-z0-9._-]*$"))))' "$config" >/dev/null 2>&1 || die 'malformed entry configuration'
  jq --stream -s -e '[.[] | select(length==2) | .[0]] | length == (unique | length)' "$config" >/dev/null 2>&1 || die 'duplicate entry configuration keys'
  owner=$(jq -r --arg p "$project" '.owners[$p] // "main"' "$config")
fi
if [ "$owner" != main ]; then
  secondmate_registry_line_for_id "$DATA/secondmates.md" "$owner" || die "no unique secondmate binding for $owner"
  owner_home=$SECONDMATE_REGISTRY_HOME; scope=$SECONDMATE_REGISTRY_SCOPE
  [ -f "$DATA/$owner/brief.md" ] && [ ! -L "$DATA/$owner/brief.md" ] || die "missing parent-owned charter for $owner"
fi
case "$mode" in
  inspect)
    [ $# -eq 0 ] || die 'unexpected inspect arguments'
    jq -n --arg project "$project" --arg path "$project_path" --arg owner "$owner" --arg home "$owner_home" --arg gateway "$FM_HOME" --arg scope "$scope" '{project:$project,project_path:$path,owner:$owner,owner_home:$home,gateway_home:$gateway,scope:$scope,role:"entry-client",delivery:"primary-inbox"}'
    ;;
  context)
    [ $# -eq 0 ] || die 'unexpected context arguments'
    printf 'PROJECT ENTRY: %s\nOwner: %s\nScope: %s\nPrimary gateway: %s\n' "$project" "$owner" "$scope" "$FM_HOME"
    printf 'You are an entry client, not another supervisor. Relay requests through fm-entry.sh send with a stable request id.\n'
    printf 'The primary owns routing, validates charter scope, and uses its existing parent channel for secondmate delegation.\n'
    printf 'Do not acquire another fleet lock, spawn a supervisor or address the user from a secondmate.\n'
    printf 'Disk profession below describes the primary; it grants this client no operational authority.\n'
    FM_HOME="$FM_HOME" bash "$SCRIPT_DIR/fm-profile.sh" context
    ;;
  send)
    [ "${1:-}" = --request-id ] && [ -n "${2:-}" ] || die 'send requires a stable --request-id'
    request=$2; shift 2
    [ "${1:-}" = -- ] || die 'use -- before the request text'
    shift; [ $# -gt 0 ] || die 'request text is empty'
    printf -v body 'Project entry: %s\nRequested coordinator: %s\nValidate current charter scope and route through the existing parent channel.\n\n%s' "$project" "$owner" "$*"
    FM_HOME="$FM_HOME" bash "$SCRIPT_DIR/fm-inbox.sh" note --request-id "$request" --json -- "$body"
    ;;
esac
