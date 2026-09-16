#!/usr/bin/env bash
# Ingest a CHECKPOINT_RECEIPT=<json> line, printed by
# agentlab-shared-memory's scripts/publish-firstmate-checkpoint.sh, into this
# task's durable receipt log (bin/fm-preservation-lib.sh owns the log format
# and fm_preservation_verify, the gate every lifecycle check calls).
#
# This script never talks to git or the network itself: it only records what
# the publisher already pushed, so the later gate can independently re-verify
# it. Recording a receipt is not verification and grants no authority by
# itself.
#
# Usage: fm-preservation-record.sh <task-id> --home <home> [--durable-branch <branch>]
#          [--app-branch <branch>] [--app-head <sha>]
#        Reads the publisher's full stdout (or a bare CHECKPOINT_RECEIPT=<json>
#        line, or a bare JSON object) on stdin.
#   <task-id>          the firstmate task this checkpoint belongs to.
#   --home             the AgentLab home slug the checkpoint was published
#                       under (e.g. firstmate-home, or a secondmate's own home
#                       slug); required so the receipt records which home's
#                       checkpoints/artifacts tree it lives in.
#   --durable-branch   the AgentLab branch the commit must be reachable from
#                       (default: main).
#   --app-branch       this task's application-repo branch name, if any.
#   --app-head         this task's application-repo branch head SHA at
#                       checkpoint time; omit for a pre-worktree initial
#                       checkpoint.
# Prints the recorded receipt as compact JSON on success.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

# shellcheck source=bin/fm-preservation-lib.sh
. "$SCRIPT_DIR/fm-preservation-lib.sh"

AGENTLAB_HOME=
DURABLE_BRANCH=main
APP_BRANCH=
APP_HEAD=
POS=()
want_value=
for a in "$@"; do
  if [ -n "$want_value" ]; then
    case "$want_value" in
      home) AGENTLAB_HOME=$a ;;
      durable-branch) DURABLE_BRANCH=$a ;;
      app-branch) APP_BRANCH=$a ;;
      app-head) APP_HEAD=$a ;;
    esac
    want_value=
    continue
  fi
  case "$a" in
    --home) want_value=home ;;
    --home=*) AGENTLAB_HOME=${a#--home=} ;;
    --durable-branch) want_value=durable-branch ;;
    --durable-branch=*) DURABLE_BRANCH=${a#--durable-branch=} ;;
    --app-branch) want_value=app-branch ;;
    --app-branch=*) APP_BRANCH=${a#--app-branch=} ;;
    --app-head) want_value=app-head ;;
    --app-head=*) APP_HEAD=${a#--app-head=} ;;
    *) POS+=("$a") ;;
  esac
done
[ -z "$want_value" ] || { echo "error: --$want_value requires a value" >&2; exit 1; }
[ "${#POS[@]}" -ge 1 ] || { echo "usage: fm-preservation-record.sh <task-id> --home <home> [--durable-branch <branch>] [--app-branch <branch>] [--app-head <sha>]" >&2; exit 1; }
ID=${POS[0]}
[ -n "$AGENTLAB_HOME" ] || { echo "error: --home is required (the AgentLab home slug this checkpoint was published under)" >&2; exit 1; }

INPUT=$(cat)
RECEIPT_LINE=$(printf '%s\n' "$INPUT" | grep -m1 '^CHECKPOINT_RECEIPT=' || true)
if [ -n "$RECEIPT_LINE" ]; then
  RECEIPT_JSON=${RECEIPT_LINE#CHECKPOINT_RECEIPT=}
else
  RECEIPT_JSON=$INPUT
fi

RECORDED=$(node -e '
  let receipt;
  try {
    receipt = JSON.parse(process.argv[1]);
  } catch (e) {
    process.stderr.write("error: could not parse a CHECKPOINT_RECEIPT JSON object from input: " + e.message + "\n");
    process.exit(1);
  }
  const id = process.argv[2];
  const home = process.argv[3];
  const branch = process.argv[4];
  const appBranch = process.argv[5];
  const appHeadArg = process.argv[6];
  const required = ["kind", "task", "commit", "path", "timestamp"];
  for (const field of required) {
    if (receipt[field] === undefined || receipt[field] === null) {
      process.stderr.write("error: CHECKPOINT_RECEIPT is missing required field: " + field + "\n");
      process.exit(1);
    }
  }
  if (!["initial", "update", "final"].includes(receipt.kind)) {
    process.stderr.write("error: CHECKPOINT_RECEIPT.kind must be initial, update, or final (got " + receipt.kind + ")\n");
    process.exit(1);
  }
  if (receipt.task !== id) {
    process.stderr.write("error: CHECKPOINT_RECEIPT.task (" + receipt.task + ") does not match task id argument (" + id + ")\n");
    process.exit(1);
  }
  const out = {
    kind: receipt.kind,
    task: receipt.task,
    home,
    commit: receipt.commit,
    path: receipt.path,
    branch,
    app_branch: appBranch || "",
    app_head: appHeadArg || receipt.app_head || "",
    timestamp: receipt.timestamp,
    recorded_at: new Date().toISOString().replace(/\.\d+Z$/, "Z"),
  };
  process.stdout.write(JSON.stringify(out));
' "$RECEIPT_JSON" "$ID" "$AGENTLAB_HOME" "$DURABLE_BRANCH" "$APP_BRANCH" "$APP_HEAD")

fm_preservation_append_line "$STATE" "$ID" "$RECORDED"
printf '%s\n' "$RECORDED"
