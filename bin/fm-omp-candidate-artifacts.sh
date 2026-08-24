#!/usr/bin/env bash
set -eu

usage() {
  echo "usage: fm-omp-candidate-artifacts.sh config <output> | extension <output> <busy-event> <state> <task-id> <generation> <turn-ended>" >&2
  exit 2
}

atomic_publish() {
  local destination=$1 temporary=$2
  mv -f -- "$temporary" "$destination"
}

javascript_literal() {
  node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$1"
}

render_config() {
  local destination=$1 temporary
  temporary=$(mktemp "${destination}.tmp.XXXXXX") || exit 1
  if ! printf '%s\n' '{"retry":{"modelFallback":false,"usageAwareFallback":false,"fallbackChains":{}}}' > "$temporary"; then
    rm -f -- "$temporary"
    exit 1
  fi
  atomic_publish "$destination" "$temporary"
}

render_extension() {
  local destination=$1 busy_event=$2 state=$3 task_id=$4 generation=$5 turn_ended=$6
  local temporary busy_event_js state_js task_id_js generation_js turn_ended_js
  busy_event_js=$(javascript_literal "$busy_event") || exit 1
  state_js=$(javascript_literal "$state") || exit 1
  task_id_js=$(javascript_literal "$task_id") || exit 1
  generation_js=$(javascript_literal "$generation") || exit 1
  turn_ended_js=$(javascript_literal "$turn_ended") || exit 1
  temporary=$(mktemp "${destination}.tmp.XXXXXX") || exit 1
  if ! cat > "$temporary" <<EOF
import { execFile } from "node:child_process";
const busyEvent = (state: string, event: string) =>
  new Promise<void>((resolve) => {
    execFile($busy_event_js, [
      "apply", $state_js, $task_id_js, state,
      "--gen", $generation_js, "--source", "omp-ext", "--event", event,
    ], () => resolve());
  });
export default function (omp: any) {
  omp.on("agent_start", () => busyEvent("busy", "agent-start"));
  const settled = (event: any, ctx: any) => {
    if (event && event.willContinue === true) return;
    if (ctx && typeof ctx.isIdle === "function" && !ctx.isIdle()) return;
    return busyEvent("idle", "agent-end");
  };
  for (const name of ["agent_end", "agent_settled"]) {
    try {
      omp.on(name, settled);
    } catch (_err) {
    }
  }
  omp.on("turn_end", () => execFile("touch", [$turn_ended_js]));
}
EOF
  then
    rm -f -- "$temporary"
    exit 1
  fi
  atomic_publish "$destination" "$temporary"
}

case "${1:-}" in
  config)
    [ "$#" -eq 2 ] || usage
    render_config "$2"
    ;;
  extension)
    [ "$#" -eq 7 ] || usage
    render_extension "$2" "$3" "$4" "$5" "$6" "$7"
    ;;
  *) usage ;;
esac
