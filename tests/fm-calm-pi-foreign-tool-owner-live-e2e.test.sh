#!/usr/bin/env bash
# Default-on live guard for Calm's built-in tool rows when another Pi extension already
# owns the same built-in name (a sandbox, an approval gate, a remote-exec wrapper).
#
# Calm must hide the seven built-in tool rows without owning any of them: a real Pi must
# start with Calm already on next to a global extension that registers "bash" (Pi refuses to
# start when two extensions register one tool name), the first /calm in a Calm-off session
# must not warn that another extension provides "bash", the "bash" row must collapse and
# return with the toggle, and the other extension must keep owning and executing "bash".
#
# No model turn reaches any provider: a local faux provider scripts one bash call, one read
# call, and a final reply. Scratch FM_HOME, project, Pi agent directory, session directory,
# and a private tmux socket; nothing global is touched.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_CALM_PI_FOREIGN_TOOL_LIVE pi tmux node

PI_VERSION=$(pi --version 2>/dev/null || printf 'unknown')
SOCKET="fm-calm-foreign-tool-$$"
SESSION=calm-foreign-tool
TMP_ROOT=$(fm_test_tmproot fm-calm-foreign-tool)
PROJECT="$TMP_ROOT/project"
AGENT="$TMP_ROOT/agent"
OWNERS_OUT="$TMP_ROOT/owners.json"
mkdir -p "$PROJECT/.pi/extensions/lib" "$AGENT/extensions" "$TMP_ROOT/sessions"

cleanup() {
  tmux -L "$SOCKET" kill-server 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup EXIT

fm_git_init_commit "$PROJECT"
cp "$ROOT/.pi/extensions/fm-calm.ts" "$PROJECT/.pi/extensions/"
for lib in \
  fm-calm-assistant-layout fm-calm-operational-user-layout fm-calm-pending-operational-layout \
  fm-calm-preservation fm-calm-tool-layout fm-calm-visibility fm-calm-working-ship \
  fm-calm-working-ship-sprite fm-operational-input; do
  cp -L "$ROOT/.pi/extensions/lib/$lib.ts" "$PROJECT/.pi/extensions/lib/"
done

# A user-scope extension that owns "bash" exactly as a sandbox or approval gate would.
cat >"$AGENT/extensions/foreign-bash.ts" <<'TS'
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

export default function (pi: ExtensionAPI): void {
  pi.registerTool({
    name: "bash",
    label: "foreign bash",
    description: "Run a shell command through the foreign extension.",
    parameters: Type.Object({ command: Type.String() }),
    async execute() {
      return { content: [{ type: "text", text: "FOREIGN_BASH_OUTPUT" }], details: undefined };
    },
  });
}
TS

cat >"$PROJECT/probe.ts" <<'TS'
import { writeFileSync } from "node:fs";
import { createFauxCore, fauxAssistantMessage, fauxText, fauxToolCall } from "@earendil-works/pi-ai";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI): void {
  const faux = createFauxCore({
    api: "foreign-tool-probe-api",
    provider: "foreign-tool-probe",
    models: [{
      id: "deterministic",
      name: "Calm foreign-tool probe",
      reasoning: false,
      input: ["text"],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      contextWindow: 4096,
      maxTokens: 128,
    }],
    tokenSize: { min: 1, max: 1 },
  });
  pi.registerProvider("foreign-tool-probe", {
    baseUrl: "http://127.0.0.1/unused",
    apiKey: "test-only",
    api: faux.api,
    models: faux.models,
    streamSimple: faux.streamSimple,
  });
  pi.registerCommand("probe-owners", {
    description: "Record which extension owns bash and read.",
    handler: async () => {
      const owners = pi.getAllTools()
        .filter((tool) => tool.name === "bash" || tool.name === "read")
        .map((tool) => ({ name: tool.name, source: tool.sourceInfo.source, path: tool.sourceInfo.path }));
      writeFileSync(process.env.OWNERS_OUT as string, JSON.stringify(owners));
    },
  });
  pi.registerCommand("probe-run", {
    description: "Run one bash call and one read call, then reply.",
    handler: async (_args, ctx) => {
      const model = ctx.modelRegistry.find("foreign-tool-probe", "deterministic");
      if (!model || !(await pi.setModel(model))) throw new Error("probe model unavailable");
      faux.setResponses([
        fauxAssistantMessage([fauxToolCall("bash", { command: "echo FOREIGN_BASH_COMMAND" }, { id: "bash_probe" })], { stopReason: "toolUse" }),
        fauxAssistantMessage([fauxToolCall("read", { path: "README.md" }, { id: "read_probe" })], { stopReason: "toolUse" }),
        fauxAssistantMessage([fauxText("PROBE_FINAL_REPLY")]),
      ]);
      pi.sendUserMessage("PROBE_PROMPT");
    },
  });
}
TS

pane() { tmux -L "$SOCKET" capture-pane -p -t "$SESSION" 2>/dev/null; }

# start_pi <on|off>: a fresh Pi with the tracked Calm extension auto-discovered from the
# project and the foreign bash extension auto-discovered from the agent directory.
start_pi() {
  local preference=$1
  tmux -L "$SOCKET" kill-server 2>/dev/null || true
  rm -rf "${TMP_ROOT:?}/home"
  mkdir -p "$TMP_ROOT/home/config"
  printf '%s\n' "$preference" >"$TMP_ROOT/home/config/calm"
  rm -f "$OWNERS_OUT"
  tmux -L "$SOCKET" new-session -d -s "$SESSION" -x 160 -y 40 \
    "cd '$PROJECT' && env FM_HOME='$TMP_ROOT/home' PI_CODING_AGENT_DIR='$AGENT' OWNERS_OUT='$OWNERS_OUT' PI_OFFLINE=1 pi --approve --no-context-files --no-skills --no-prompt-templates -e ./probe.ts --session-dir '$TMP_ROOT/sessions'; printf 'PI_EXIT=%s\\n' \"\$?\"; sleep 30"
  local i=0
  until pane | grep -Fq 'probe.ts'; do
    i=$((i + 1))
    [ "$i" -lt 300 ] || fail "Pi $PI_VERSION never reached its composer with Calm $preference beside a foreign bash extension: $(pane)"
    pane | grep -Fq 'PI_EXIT=' && fail "Pi $PI_VERSION exited at startup with Calm $preference beside a foreign bash extension: $(pane)"
    sleep 0.05
  done
}

send() {
  tmux -L "$SOCKET" send-keys -t "$SESSION" -l "$1"
  sleep 0.3
  tmux -L "$SOCKET" send-keys -t "$SESSION" Enter
}

wait_for() {
  local text=$1 context=$2 i=0
  until pane | grep -Fq -- "$text"; do
    i=$((i + 1))
    [ "$i" -lt 300 ] || fail "Pi $PI_VERSION: $context (missing: '$text'): $(pane)"
    sleep 0.05
  done
}

wait_for_absent() {
  local text=$1 context=$2 i=0
  while pane | grep -Fq -- "$text"; do
    i=$((i + 1))
    [ "$i" -lt 300 ] || fail "Pi $PI_VERSION: $context (still shown: '$text'): $(pane)"
    sleep 0.05
  done
}

# Calm on at session start, beside a foreign bash owner: Pi must start.
start_pi on
pass "Pi $PI_VERSION starts with Calm already on beside a foreign extension that owns bash"

send '/probe-run'
wait_for 'PROBE_FINAL_REPLY' "the scripted turn never finished with Calm on"
pane | grep -Fq 'FOREIGN_BASH_COMMAND' && fail "Calm on left the bash row visible beside a foreign bash owner: $(pane)"
pane | grep -Fq 'FOREIGN_BASH_OUTPUT' && fail "Calm on left the foreign bash output visible: $(pane)"
pane | grep -Fq 'read README.md' && fail "Calm on left the read row visible: $(pane)"
pass "Calm on hides the bash row of a foreign bash owner and the read row"

send '/probe-owners'
i=0
until [ -s "$OWNERS_OUT" ]; do
  i=$((i + 1))
  [ "$i" -lt 100 ] || fail "Pi $PI_VERSION never recorded tool owners: $(pane)"
  sleep 0.05
done
owners=$(cat "$OWNERS_OUT")
case "$owners" in
  *'"name":"bash","source":"auto","path":"'*'foreign-bash.ts"'*) ;;
  *) fail "Calm took ownership of bash from the foreign extension: $owners" ;;
esac
case "$owners" in
  *'"name":"read","source":"builtin"'*) ;;
  *) fail "Calm registered a read tool instead of only hiding its row: $owners" ;;
esac
pass "Calm registers no built-in tool: the foreign extension keeps bash and Pi keeps read"

# Calm off at session start, then the first /calm: no ownership warning, rows collapse and return.
start_pi off
send '/probe-run'
wait_for 'PROBE_FINAL_REPLY' "the scripted turn never finished with Calm off"
wait_for 'FOREIGN_BASH_OUTPUT' "Calm off did not show the foreign bash output"
wait_for 'read README.md' "Calm off did not show the read row"

send '/calm'
wait_for_absent 'FOREIGN_BASH_OUTPUT' "the first /calm did not collapse the bash row already on screen"
wait_for_absent 'read README.md' "the first /calm did not collapse the read row already on screen"
pane | grep -Fq 'already provided by another extension' && fail "the first /calm warned about a foreign bash owner: $(pane)"
pass "The first /calm collapses rows already on screen and shows no ownership warning"

send '/calm'
wait_for 'FOREIGN_BASH_OUTPUT' "turning Calm off did not restore the foreign bash row"
wait_for 'read README.md' "turning Calm off did not restore the read row"
pass "Turning Calm off restores the bash and read rows"
