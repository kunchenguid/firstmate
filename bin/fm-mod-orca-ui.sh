#!/usr/bin/env bash
# bin/fm-mod-orca-ui.sh - patch ~/.config/orca/profiles/local-default/orca-data.json
# so firstmate-spawned worktrees appear in orca's sidebar.
#
# Why: orca's GUI discovers worktrees via `git worktree list` from registered
# repos and gates their visibility with the `externalWorktreeVisibility` setting
# (default "hide"). When firstmate creates a worktree via `git worktree add` +
# fmod createOrAttach, orca sees it as external and hides it by default, so
# the captain cannot see the dispatched crewmate in the sidebar. This script
# writes a worktreeMeta entry that mirrors orca's own format, bypassing the
# visibility gate - orca trusts worktreeMeta entries regardless of the
# externalWorktreeVisibility knob.
#
# Why this is separate from bin/backends/orca.sh: the data model (orca's
# profile JSON schema, key format, instanceId layout) is its own concern and
# will outlive the orca backend; keeping the helper factored makes it
# testable in isolation and reusable by anything else that needs to register
# orca worktrees (e.g. a future bin/fm-mod-orca-import.sh for projects the
# captain dragged into orca by hand).
#
# Usage:
#   bin/fm-mod-orca-ui.sh register <worktree-path> --parent-path <project-path>
#       Look up the orca session for the project at <project-path> (NOT the
#       worktree's git-common-dir: firstmate's projects/ copy and the captain's
#       Desktop copy are sibling clones and only one is registered with orca),
#       write a worktreeMeta entry. Print the new worktreeKey on stdout.
#   bin/fm-mod-orca-ui.sh register <worktree-path> --parent-key <repo-key>
#       <repo-key> is the "uuid::path" form of the orca session id, bypassing
#       the daemon lookup. Useful when the caller already resolved it.
#   bin/fm-mod-orca-ui.sh unregister <worktree-key>
#       Remove the entry with that exact key (matches what `register` printed).
#       Exit 0 if removed, exit 0 also if absent (idempotent).
#   bin/fm-mod-orca-ui.sh unregister-path <worktree-path> --parent-path <project-path>
#       Same as `unregister` but takes a worktree path + parent path and
#       computes the key.
#   bin/fm-mod-orca-ui.sh list
#       Print every worktreeMeta key, one per line.
#   bin/fm-mod-orca-ui.sh show <worktree-key>
#       Print the JSON object for one entry.
#
# Env:
#   FM_ORCA_DATA_FILE   override path to orca-data.json (default
#                       ${XDG_CONFIG_HOME:-$HOME/.config}/orca/profiles/local-default/orca-data.json)
#   FM_ORCA_FMOD        fmod binary (default bin/fmod next to this script's parent)
#   FM_ORCA_INSTANCE_ID  override the UUID v4 used as instanceId (tests use this)
#
# Exit codes:
#   0  success (or already-absent for unregister)
#   1  invalid invocation: missing wt path, missing --parent-path/--parent-key, or wt path is not a directory
#   2  orca-data.json missing
#   3  orca-data.json is malformed
#   4  parent repo not registered with orca (no matching orca session)
#   5  atomic write failed

set -eu

SCRIPT_DIR=$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
FMOD="${FM_ORCA_FMOD:-$SCRIPT_DIR/fmod}"
ORCA_DATA_FILE="${FM_ORCA_DATA_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/orca/profiles/local-default/orca-data.json}"

usage() {
  # Header: lines 2 through (but not including) the # Exit codes: header.
  # Exit-codes body: from # Exit codes: until the next blank line or EOF,
  # skipping the header line itself to avoid emitting "Exit codes:" twice.
  {
    sed -n '2,/^# Exit codes:$/p' "$0" | grep '^#' | sed 's/^# \?//'
    sed -n '/^# Exit codes:$/,$p' "$0" \
      | sed '1d' | grep '^#' | sed 's/^# \?//'
  } | sed '/^$/d'
}

require_orca_data() {
  [ -f "$ORCA_DATA_FILE" ] || { echo "error: orca-data.json not found at $ORCA_DATA_FILE" >&2; exit 2; }
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$ORCA_DATA_FILE" >/dev/null 2>&1 \
    || { echo "error: malformed JSON in $ORCA_DATA_FILE" >&2; exit 3; }
}

# resolve_parent_session_uuid <parent-project-path>
# Returns the leading project UUID portion of the orca session id for the
# project at <parent-project-path> (e.g. "04bef15a-4a22-4b26-96fb-374e6fc8d71d").
# Echoes it on stdout, exits 4 if the project has no orca session.
# We do NOT walk the worktree's git-common-dir: firstmate's projects/ copy and
# the captain's Desktop copy are sibling clones of the same repo, but only one
# is registered with orca. The caller MUST pass the actual orca-registered path.
#
# Fallback chain (each step tried before failing):
#  1. Exact match against fmod list session paths (trailing-slash tolerant,
#     both sides realpath'd).
#  2. Match by git-common-dir: the parent's git-common-dir (the .git dir of
#     the bare repo that all sibling clones share) often matches the captain's
#     registered clone's git-common-dir even when the cwd paths differ. This
#     covers the firstmate/projects/ vs captain/Desktop/ case where both have
#     the same .git directory underneath.
#  3. Match by repository basename + parent path basename. Last-ditch: if
#     the repo's basename matches, assume it's the same project.
resolve_parent_session_uuid() {
  local parent_path=$1

  # 1+2: try fmod list with a python script that walks exact-path first,
  # then git-common-dir, then basename.
  local uuid
  uuid=$("$FMOD" list 2>/dev/null | python3 -c "
import json, sys, os, subprocess
data = json.load(sys.stdin)
parent = os.path.realpath(sys.argv[1]).rstrip('/')
parent_basename = os.path.basename(parent)

def git_common(p):
    try:
        return subprocess.check_output(['git', '-C', p, 'rev-parse', '--git-common-dir'], text_with_errors=False, stderr=subprocess.DEVNULL).strip()
    except Exception:
        return ''
parent_gcd = git_common(parent)
parent_gcd_real = os.path.realpath(parent_gcd) if parent_gcd else ''

for s in data:
    sid = s.get('sessionId', '')
    if '::' not in sid: continue
    head, rest = sid.split('::', 1)
    p = rest.split('@@', 1)[0].rstrip('/')
    p_real = os.path.realpath(p) if os.path.isdir(p) else p
    if p_real == parent:
        print(head); sys.exit(0)
    if parent_gcd_real and os.path.isdir(p):
        s_gcd = git_common(p)
        if s_gcd and os.path.realpath(s_gcd) == parent_gcd_real:
            print(head); sys.exit(0)
    # basename match - last-ditch
    if os.path.basename(p) == parent_basename and parent_basename:
        print(head); sys.exit(0)
sys.exit(1)
" "$parent_path" 2>/dev/null) || { echo "error: parent repo $parent_path has no orca session" >&2; exit 4; }
  printf '%s' "$uuid"
}

# worktree_key <wt-path> <project-uuid>
worktree_key() {
  printf '%s::%s' "$2" "$1"
}

# new_instance_id
new_instance_id() {
  if [ -n "${FM_ORCA_INSTANCE_ID:-}" ]; then
    printf '%s' "$FM_ORCA_INSTANCE_ID"
    return
  fi
  python3 -c 'import uuid; print(uuid.uuid4())'
}

# atomic_write_orca_data <python-script-args...>
# Runs python3 with the script, expects it to print "ok" or non-zero.
atomic_write_orca_data() {
  local rc lockdir tmpfile
  # Concurrent-caller protection: serialize via a mkdir lock (atomic on
  # POSIX). Two parallel secondmate-home spawns would otherwise do a
  # read-modify-write race even with a unique tmp filename, losing one
  # update. mkdir is the standard portable one-shot lock; rmdir on exit
  # releases it. The lockdir is bounded to a 30-second wait so a SIGKILL'd
  # holder does not wedge every subsequent call.
  lockdir="${ORCA_DATA_FILE}.lock"
  local -i waited=0 max_wait=600   # ~30s at 0.05s sleep
  until mkdir "$lockdir" 2>/dev/null; do
    sleep 0.05
    waited=$((waited + 1))
    if [ "$waited" -ge "$max_wait" ]; then
      echo "error: ${ORCA_DATA_FILE}.lock held longer than 30s; a previous caller likely crashed mid-write" >&2
      exit 5
    fi
  done
  tmpfile=$(mktemp "${ORCA_DATA_FILE}.tmp.XXXXXX") || {
    rmdir "$lockdir" 2>/dev/null || true
    echo "error: mktemp failed" >&2; exit 5
  }
  # Trap uses %q to make the path values safe for shell interpolation,
  # since $ORCA_DATA_FILE is configurable via FM_ORCA_DATA_FILE.
  trap "rm -f $(printf %q "$tmpfile"); rmdir $(printf %q "$lockdir") 2>/dev/null || true" EXIT
  # Pass the unique tmp path via env so the python heredoc writes to a
  # caller-owned filename (not a hardcoded path + '.tmp' that would
  # collide if the lock were ever bypassed).
  if ORCA_DATA_FILE="$ORCA_DATA_FILE" ORCA_DATA_TMP="$tmpfile" \
     python3 - "$@" <<'PY'
import json, os, sys
path = os.environ['ORCA_DATA_FILE']
tmp = os.environ['ORCA_DATA_TMP']
mode = sys.argv[1]
with open(path) as f:
    d = json.load(f)
d.setdefault('worktreeMeta', {})
if mode == 'register':
    key, instance_id, project_id, host_id, project_host_setup_id, sort_order, last_activity_at = sys.argv[2:]
    d['worktreeMeta'][key] = {
        "instanceId": instance_id,
        "displayName": "",
        "comment": "",
        "linkedIssue": None,
        "linkedPR": None,
        "linkedLinearIssue": None,
        "linkedGitLabMR": None,
        "linkedGitLabIssue": None,
        "linkedBitbucketPR": None,
        "linkedAzureDevOpsPR": None,
        "linkedGiteaPR": None,
        "isArchived": False,
        "isUnread": False,
        "isPinned": False,
        "sortOrder": int(sort_order),
        "lastActivityAt": int(last_activity_at),
        "workspaceStatus": "in-progress",
        "projectId": project_id,
        "hostId": host_id,
        "projectHostSetupId": project_host_setup_id,
    }
elif mode == 'unregister':
    key = sys.argv[2]
    d['worktreeMeta'].pop(key, None)
else:
    print(f'error: unknown mode {mode}', file=sys.stderr); sys.exit(2)
# Atomic rename: write to a unique tmp path then rename. POSIX guarantees
# rename atomicity on a single filesystem, so concurrent callers see either
# the pre-write or post-write content for any given path - never a partial.
with open(tmp, 'w') as f:
    json.dump(d, f, indent=2, sort_keys=True)
    f.write('\n')
os.replace(tmp, path)
PY
  then
    rm -f "$tmpfile"
    rmdir "$lockdir" 2>/dev/null || true
    trap - EXIT
    return 0
  fi
  rc=$?
  rm -f "$tmpfile"
  rmdir "$lockdir" 2>/dev/null || true
  trap - EXIT
  echo "error: atomic write to $ORCA_DATA_FILE failed (rc=$rc)" >&2
  exit 5
}

cmd_register() {
  local wt= parent_path= parent_key=
  while [ $# -gt 0 ]; do
    case "$1" in
      --parent-path) parent_path=$2; shift 2 ;;
      --parent-key)  parent_key=$2;  shift 2 ;;
      *) wt=$1; shift ;;
    esac
  done
  [ -d "$wt" ] || { echo "error: not a directory: $wt" >&2; exit 1; }
  [ -n "$parent_path$parent_key" ] || { echo "error: register requires --parent-path or --parent-key" >&2; exit 1; }
  require_orca_data
  local uuid key instance_id now_ms
  if [ -n "$parent_key" ]; then
    uuid=${parent_key%%::*}
  else
    uuid=$(resolve_parent_session_uuid "$parent_path")
  fi
  key=$(worktree_key "$wt" "$uuid")
  instance_id=$(new_instance_id)
  now_ms=$(($(date +%s) * 1000))
  atomic_write_orca_data register "$key" "$instance_id" "repo:$uuid" "local" "$uuid" "$now_ms" "$now_ms"
  printf '%s' "$key"
}

cmd_unregister() {
  local key=$1
  require_orca_data
  atomic_write_orca_data unregister "$key"
}

cmd_unregister_path() {
  local wt= parent_path=
  while [ $# -gt 0 ]; do
    case "$1" in
      --parent-path) parent_path=$2; shift 2 ;;
      *) wt=$1; shift ;;
    esac
  done
  [ -d "$wt" ] || { echo "error: not a directory: $wt" >&2; exit 1; }
  [ -n "$parent_path" ] || { echo "error: unregister-path requires --parent-path" >&2; exit 1; }
  require_orca_data
  local uuid key
  uuid=$(resolve_parent_session_uuid "$parent_path")
  key=$(worktree_key "$wt" "$uuid")
  atomic_write_orca_data unregister "$key"
}

cmd_list() {
  require_orca_data
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); [print(k) for k in d.get("worktreeMeta", {}).keys()]' "$ORCA_DATA_FILE"
}

cmd_show() {
  local key=$1
  require_orca_data
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); v=d.get("worktreeMeta", {}).get(sys.argv[2]); print(json.dumps(v, indent=2, sort_keys=True) if v else "(none)")' "$ORCA_DATA_FILE" "$key"
}

case "${1:-}" in
  register)          shift; cmd_register "$@" ;;
  unregister)        shift; cmd_unregister "$@" ;;
  unregister-path)   shift; cmd_unregister_path "$@" ;;
  list)              cmd_list ;;
  show)              shift; cmd_show "$@" ;;
  -h|--help|help|"") usage ;;
  *) echo "error: unknown command '$1'" >&2; usage >&2; exit 1 ;;
esac
