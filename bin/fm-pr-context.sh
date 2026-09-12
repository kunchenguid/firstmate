#!/usr/bin/env bash
# Write or validate a durable PR handoff at data/<task>/pr-context.md.
# Usage: fm-pr-context.sh write <task> < context.json
#        fm-pr-context.sh validate <task> [--json]
#        fm-pr-context.sh --help
#
# write reads exactly one JSON object from stdin, validates before mutation,
# then atomically replaces a private Markdown file with one canonical JSON block.
# validate rejects incomplete or noncanonical files; --json exports the validated
# object for consumers so they do not need a second Markdown parser.
# Neither command executes evidence, accesses the forge, or grants merge authority.
# This is completeness validation, not proof that commands ran or the PR is green.
# The last recorded run of both oracle.command and pre_push_command must exit 0;
# earlier red runs remain in tests as evidence. Record successful results for
# this head, not a prior revision.
# repo is the head checkout's owner/repository (may differ from the PR target).
# Empty arrays explicitly mean no open threads or deferred items; missing arrays
# are invalid. Thread/defer strings should include their stable URL or identifier
# and enough detail to resume. Store command strings as data, never source/eval them.
# FM_HOME selects the owning home; FM_DATA_OVERRIDE selects its data directory.
# schema=1 and task=<task> are added by write when absent and checked when present.
# Required input example (replace the head and command evidence with real values):
# {
#   "pr_url": "https://github.com/example/project/pull/12",
#   "head": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
#   "repo": "example/project",
#   "branch": "fm/change",
#   "oracle": {"name": "acceptance", "command": "bin/check"},
#   "tests": [{"command": "bin/check", "exit_code": 0}],
#   "open_review_threads": [],
#   "deferred_items": [],
#   "pre_push_command": "bin/check",
#   "merge_authority": "human-merge"
# }
# merge_authority is human-merge or fm-merge; it records the assigned policy,
# never promotes a human-merge project to automatic merge.
set -eu
umask 077
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() { awk 'NR==1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"; }
die() { printf 'error: PR context: %s\n' "$*" >&2; exit 1; }
case "${1:-}" in -h|--help) usage; exit 0 ;; esac
[ "$#" -ge 2 ] && [ "$#" -le 3 ] || { usage >&2; exit 2; }
action=$1 id=$2
case "$action:${3:-}" in write:|validate:|validate:--json) ;; *) usage >&2; exit 2 ;; esac
fm_pr_task_id_valid "$id" || die "unsafe task id"
command -v jq >/dev/null || die "jq is required"
command -v git >/dev/null || die "git is required"

# Refuse linked descendants of the explicit data root, including a linked root.
# Ancestors of an explicit override are the operator's chosen trust boundary.
resolve_store() {
  [ ! -L "$DATA" ] || die "linked data directory"
  if [ "$action" = write ]; then mkdir -p -- "$DATA"; fi
  DATA=$(CDPATH='' cd -- "$DATA" && pwd -P) || die "missing data directory"
  dir="$DATA/$id"
  path="$dir/pr-context.md"
  [ ! -L "$dir" ] || die "linked task directory"
  fm_pr_regular_destination_or_absent "$path" || die "context must be an ordinary single-link file"
}

render() { printf '%s\n' '# PR context v1' '' '```json' "$1" '```'; }
if [ "$action" = write ]; then
  raw=$(jq -se 'if length == 1 and (.[0] | type) == "object" then .[0] else error("expected one object") end') \
    || die "expected one JSON object on stdin"
else
  resolve_store
  [ -d "$dir" ] || die "missing task directory"
  fm_pr_private_file_valid "$path" 600 "$(fm_pr_file_device "$dir")" || die "missing or unsafe context file"
  saved=$(cat "$path") || die "cannot read context"
  raw=$(printf '%s\n' "$saved" | awk 'NR>3 {if (previous != "") print previous; previous=$0}')
fi

json=$(printf '%s\n' "$raw" | jq -eS --arg task "$id" --arg action "$action" '
  def text: type == "string" and test("\\S") and
    (test("\\{\\{|^\\s*(TODO|TBD|unknown|none)\\s*$"; "i") | not);
  def strings: type == "array" and all(.[]; text);
  if $action == "write" then {schema:1, task:$task} + . else . end |
  if (
    type == "object" and
    (keys == (["schema","task","pr_url","head","repo","branch","oracle","tests",
      "open_review_threads","deferred_items","pre_push_command","merge_authority"] | sort)) and
    .schema == 1 and .task == $task and
    ([.pr_url,.head,.repo,.branch,.pre_push_command] | all(.[]; text)) and
    (.oracle | type == "object" and keys == ["command","name"] and (.name | text) and (.command | text)) and
    (.tests | type == "array" and length > 0 and all(.[];
      type == "object" and keys == ["command","exit_code"] and (.command | text) and
      (.exit_code | type == "number" and . == floor and . >= 0 and . <= 255))) and
    (.open_review_threads | strings) and (.deferred_items | strings) and
    (.merge_authority == "human-merge" or .merge_authority == "fm-merge")
  ) then . else error("incomplete or malformed context fields") end |
  .oracle.command as $oracle | .pre_push_command as $prepush |
  if ([.tests[] | select(.command == $oracle)] | last | .exit_code) == 0 and
     ([.tests[] | select(.command == $prepush)] | last | .exit_code) == 0
  then . else error("last oracle and pre-push results must exit 0") end
') || die "incomplete snapshot; see --help"
fm_pr_url_parse "$(printf '%s' "$json" | jq -r .pr_url)" || die "invalid PR URL"
[ "$FM_PR_PROVIDER" = github ] || die "context handoff currently supports GitHub only"
fm_pr_url_parse "https://github.com/$(printf '%s' "$json" | jq -r .repo)/pull/1" || die "invalid checkout repository"
fm_pr_head_valid "$(printf '%s' "$json" | jq -r .head)" || die "exact head is required"
branch=$(printf '%s' "$json" | jq -r .branch)
git check-ref-format "refs/heads/$branch" >/dev/null 2>&1 || die "invalid branch"
git check-ref-format --branch "$branch" >/dev/null 2>&1 || die "invalid branch"

if [ "$action" = validate ]; then
  [ "$saved" = "$(render "$json")" ] || die "noncanonical or ambiguous snapshot; rewrite with write"
  if [ "${3:-}" = --json ]; then printf '%s\n' "$json"; else printf 'valid: %s\n' "$path"; fi
  exit 0
fi
resolve_store
mkdir -p -- "$dir"
[ ! -L "$dir" ] || die "linked task directory"
fm_pr_regular_destination_or_absent "$path" || die "unsafe context destination"
tmp=$(mktemp "$dir/.pr-context.XXXXXX") || die "cannot stage context"
trap 'rm -f -- "$tmp"' EXIT
render "$json" > "$tmp"
chmod 0600 "$tmp"
mv -f -- "$tmp" "$path"
printf '%s\n' "$path"
