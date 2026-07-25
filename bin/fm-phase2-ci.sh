#!/usr/bin/env bash
# Inspect GitHub Actions for a task's commit/PR and optionally open a repair task.
# Usage:
#   fm-phase2-ci.sh record <task-id> <sha>
#   fm-phase2-ci.sh wait <task-id> [--repo owner/name] [--timeout 600]
#   fm-phase2-ci.sh logs <run-id> [--repo owner/name]
#   fm-phase2-ci.sh repair <task-id> --from-run <run-id> [--repo owner/name]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
export FM_HOME
REG="$FM_HOME/bin/fm-phase2-registry.sh"
CMD="${1:?}"
shift

case "$CMD" in
  record)
    TID="${1:?}"; SHA="${2:?}"
    "$REG" set "$TID" --field "commit_sha=$SHA"
    "$FM_HOME/bin/fm-phase2-event.sh" commit_created --task "$TID" --dedupe "commit-$SHA" --payload "{\"sha\":\"$SHA\"}"
    ;;
  wait)
    TID="${1:?}"; shift
    REPO=""; TIMEOUT=600
    while [ $# -gt 0 ]; do
      case "$1" in
        --repo) REPO="${2:?}"; shift 2 ;;
        --timeout) TIMEOUT="${2:?}"; shift 2 ;;
        *) shift ;;
      esac
    done
    SHA=$("$REG" get-task "$TID" | python3 -c "import json,sys; print(json.load(sys.stdin).get('commit_sha',''))")
    [ -n "$SHA" ] || { echo "no commit_sha on task" >&2; exit 1; }
    REPO_ARGS=()
    [ -n "$REPO" ] && REPO_ARGS=(-R "$REPO")
    "$FM_HOME/bin/fm-phase2-event.sh" ci_started --task "$TID" --dedupe "ci-start-$SHA" --payload "{\"sha\":\"$SHA\"}"
    deadline=$((SECONDS + TIMEOUT))
    RUN_ID=""
    CONCLUSION=""
    while [ "$SECONDS" -lt "$deadline" ]; do
      JSON=$(gh run list --commit "$SHA" "${REPO_ARGS[@]}" --limit 5 --json databaseId,conclusion,status,name,url 2>/dev/null || echo '[]')
      RUN_ID=$(printf '%s' "$JSON" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d[0]['databaseId'] if d else '')")
      STATUS=$(printf '%s' "$JSON" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d[0].get('status','') if d else '')")
      CONCLUSION=$(printf '%s' "$JSON" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d[0].get('conclusion','') if d else '')")
      if [ "$STATUS" = "completed" ]; then
        break
      fi
      sleep 15
    done
    "$REG" set "$TID" --field "ci_run=${RUN_ID}"
    "$FM_HOME/bin/fm-phase2-event.sh" ci_completed --task "$TID" --dedupe "ci-done-$SHA-$CONCLUSION" \
      --payload "{\"run_id\":\"$RUN_ID\",\"conclusion\":\"$CONCLUSION\"}"
    echo "{\"run_id\":\"$RUN_ID\",\"conclusion\":\"$CONCLUSION\",\"sha\":\"$SHA\"}"
    if [ "$CONCLUSION" != "success" ]; then
      "$REG" transition "$TID" implementing --reason "ci_failed" --field "next_action=ci_repair" || true
      exit 1
    fi
    "$REG" transition "$TID" approved --reason "ci_green" || \
      "$REG" transition "$TID" awaiting_ci --reason "ci_green_waiting_gate" || true
    ;;
  logs)
    RUN="${1:?}"; shift
    REPO=""
    while [ $# -gt 0 ]; do case "$1" in --repo) REPO="${2:?}"; shift 2 ;; *) shift ;; esac; done
    REPO_ARGS=(); [ -n "$REPO" ] && REPO_ARGS=(-R "$REPO")
    gh run view "$RUN" "${REPO_ARGS[@]}" --log-failed 2>/dev/null | head -n 400
    ;;
  repair)
    TID="${1:?}"; shift
    RUN=""; REPO=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --from-run) RUN="${2:?}"; shift 2 ;;
        --repo) REPO="${2:?}"; shift 2 ;;
        *) shift ;;
      esac
    done
    RID="repair-${TID}-$(date +%s | tail -c 5)"
    "$FM_HOME/bin/fm-phase2-packet.sh" "$RID" --title "CI repair for $TID" --objective "Fix CI failure from run $RUN"
    PROG=$("$REG" get-task "$TID" | python3 -c "import json,sys; print(json.load(sys.stdin)['programme_id'])")
    "$REG" add-task "$RID" "$PROG" "CI repair for $TID" --worker-type backend_engineer --priority 10 --dep "$TID" \
      --packet-dir "$FM_HOME/data/$RID/packet" || \
      "$REG" add-task "$RID" "$PROG" "CI repair for $TID" --worker-type backend_engineer --priority 10 \
        --packet-dir "$FM_HOME/data/$RID/packet"
    # repair should not wait on parent merged — clear bad dep by transitioning parent note
    mkdir -p "$FM_HOME/data/$RID/packet"
    {
      echo "# CI failure context"
      echo "Parent task: $TID"
      echo "Run: $RUN"
      echo "Repo: $REPO"
    } > "$FM_HOME/data/$RID/packet/CONTEXT.md"
    if [ -n "$RUN" ]; then
      "$FM_HOME/bin/fm-phase2-ci.sh" logs "$RUN" ${REPO:+--repo "$REPO"} > "$FM_HOME/data/$RID/packet/ci-failed.log" || true
    fi
    "$REG" transition "$RID" ready --reason "ci_repair_created"
    "$FM_HOME/bin/fm-phase2-event.sh" repair_task_created --task "$RID" --dedupe "repair-$TID-$RUN" \
      --payload "{\"parent\":\"$TID\",\"run\":\"$RUN\"}"
    echo "repair_task=$RID"
    ;;
  *)
    echo "unknown command" >&2
    exit 2
    ;;
esac
