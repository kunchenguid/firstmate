#!/usr/bin/env bash
# Render the dormant OMP candidate's isolated settings and launch artifacts.
# Usage:
#   fm-omp-candidate-artifacts.sh prepare <agent-dir> <cwd>
#   fm-omp-candidate-artifacts.sh manifest <agent-dir> <cwd> <binary> <model> <extension>
#   fm-omp-candidate-artifacts.sh launch-template
#   fm-omp-candidate-artifacts.sh validate-submission <text>
#   fm-omp-candidate-artifacts.sh extension <output> <busy-event> <state> <task-id> <generation> <turn-ended>
# `prepare` creates a new agent directory containing config.yml and a new,
# empty launch cwd. `manifest` emits the requested environment boundary and argv
# as JSON, including the flags that request disabled built-in tools and LSP;
# `launch-template` emits the same boundary with spawn-time placeholders.
# `validate-submission` rejects text whose first non-whitespace character would
# enter OMP's slash-command or bang-command parser.
# `extension` writes the First Mate busy-state adapter to <output>. Persistent
# config and extension files are rendered beside their destinations and renamed
# atomically. No mode starts OMP, opens a session, or calls a provider.
set -eu

OMP_RETRY_JSON='{"modelFallback":false,"usageAwareFallback":false,"fallbackChains":{}}'
OMP_AST_EDIT_JSON='{"enabled":false}'

usage() {
  echo "usage: fm-omp-candidate-artifacts.sh prepare <agent-dir> <cwd> | manifest <agent-dir> <cwd> <binary> <model> <extension> | launch-template | validate-submission <text> | extension <output> <busy-event> <state> <task-id> <generation> <turn-ended>" >&2
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
  if ! printf '%s\n' "{\"retry\":$OMP_RETRY_JSON,\"astEdit\":$OMP_AST_EDIT_JSON}" > "$temporary"; then
    rm -f -- "$temporary"
    exit 1
  fi
  atomic_publish "$destination" "$temporary"
}

prepare_isolated_settings() {
  local agent_dir=$1 cwd=$2
  if [ -e "$agent_dir" ] || [ -L "$agent_dir" ] || [ -e "$cwd" ] || [ -L "$cwd" ]; then
    echo "error: candidate OMP isolation directories already exist" >&2
    return 1
  fi
  mkdir -p "$agent_dir" "$cwd" || return 1
  if ! render_config "$agent_dir/config.yml"; then
    rmdir "$cwd" "$agent_dir" 2>/dev/null || true
    return 1
  fi
}

render_manifest() {
  local agent_dir=$1 cwd=$2 binary=$3 model=$4 extension=$5
  OMP_AGENT_DIR=$agent_dir OMP_CWD=$cwd OMP_BINARY=$binary \
    OMP_MODEL=$model OMP_EXTENSION=$extension node <<'NODE'
const manifest = {
  unsetEnvironment: [
    "CLAUDECODE", "PI_CODING_AGENT", "PI_CONFIG_FILES", "OMP_PROFILE", "PI_PROFILE", "GROK_AGENT",
    "FM_PI_HARNESS", "CURSOR_AGENT", "CURSOR_INVOKED_AS", "TRACEPARENT",
  ],
  environment: {
    FM_OMP_HARNESS: "1",
    PI_CODING_AGENT_DIR: process.env.OMP_AGENT_DIR,
  },
  argv: [
    process.env.OMP_BINARY,
    "--cwd", process.env.OMP_CWD,
    "--approval-mode", "yolo",
    "--no-title",
    "--no-extensions",
    "--no-skills",
    "--no-lsp",
    "--no-tools",
    "--model", process.env.OMP_MODEL,
    "-e", process.env.OMP_EXTENSION,
  ],
};
process.stdout.write(JSON.stringify(manifest));
NODE
}

render_launch_template() {
  render_manifest __OMPAGENTDIR__ __OMPCWD__ __OMPBIN__ __OMPMODEL__ __OMPEXT__ \
    | node -e '
const fs = require("node:fs");
const manifest = JSON.parse(fs.readFileSync(0, "utf8"));
const words = ["env"];
for (const name of manifest.unsetEnvironment) words.push("-u", name);
for (const [name, value] of Object.entries(manifest.environment)) words.push(name + "=" + value);
words.push(...manifest.argv);
const dollar = String.fromCharCode(36);
process.stdout.write(words.join(" ") + " \"" + dollar + "(__OPINPUT__ encode launch-brief < __BRIEF__)\"");
'
}

validate_submission() {
  OMP_SUBMISSION=$1 node <<'NODE'
const input = process.env.OMP_SUBMISSION || "";
const command = input.trimStart();
if (command.startsWith("/") || command.startsWith("!")) {
  process.stderr.write("error: OMP candidate refuses slash and bang command input; use First Mate control for lifecycle actions\n");
  process.exit(1);
}
NODE
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
  prepare)
    [ "$#" -eq 3 ] || usage
    prepare_isolated_settings "$2" "$3"
    ;;
  manifest)
    [ "$#" -eq 6 ] || usage
    render_manifest "$2" "$3" "$4" "$5" "$6"
    ;;
  launch-template)
    [ "$#" -eq 1 ] || usage
    render_launch_template
    ;;
  validate-submission)
    [ "$#" -eq 2 ] || usage
    validate_submission "$2"
    ;;
  extension)
    [ "$#" -eq 7 ] || usage
    render_extension "$2" "$3" "$4" "$5" "$6" "$7"
    ;;
  *) usage ;;
esac
