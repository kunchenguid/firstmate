#!/usr/bin/env bash
set -u

if [ "${FM_PI_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_PI_LIVE_E2E=1 to run the installed-Pi Calm conflict regression"
  exit 0
fi

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v node >/dev/null 2>&1 || fail "node not found"
command -v pi >/dev/null 2>&1 || fail "pi not found"

PI_PACKAGE_DIR=${FM_PI_PACKAGE_DIR:-}
if [ -z "$PI_PACKAGE_DIR" ] && command -v pnpm >/dev/null 2>&1; then
  PI_PACKAGE_DIR=$(pnpm ls -g --parseable @earendil-works/pi-coding-agent 2>/dev/null | tail -n 1)
fi
if [ -z "$PI_PACKAGE_DIR" ] || [ ! -f "$PI_PACKAGE_DIR/package.json" ]; then
  PI_PACKAGE_DIR="$(npm root -g 2>/dev/null)/@earendil-works/pi-coding-agent"
fi
[ -f "$PI_PACKAGE_DIR/package.json" ] || fail "installed Pi package not found"

PI_DEPENDENCY_DIR="$PI_PACKAGE_DIR/node_modules"
if [ ! -e "$PI_DEPENDENCY_DIR/@earendil-works/pi-tui" ]; then
  PI_DEPENDENCY_DIR="$(dirname "$(dirname "$PI_PACKAGE_DIR")")/.pnpm/node_modules"
fi
[ -e "$PI_DEPENDENCY_DIR/@earendil-works/pi-tui" ] || fail "installed pi-tui package not found"
[ -e "$PI_DEPENDENCY_DIR/typebox" ] || fail "installed typebox package not found"

PI_VERSION=$(node -p "require('$PI_PACKAGE_DIR/package.json').version")
[ -n "$PI_VERSION" ] || fail "installed Pi version unavailable"

TMP_ROOT=$(fm_test_tmproot fm-calm-pi-conflict-live-e2e)
PROJECT="$TMP_ROOT/project"
AGENT_DIR="$TMP_ROOT/agent"
FM_HOME_DIR="$TMP_ROOT/home"
mkdir -p "$PROJECT/.pi/extensions/lib" "$PROJECT/node_modules/@earendil-works" "$AGENT_DIR" "$FM_HOME_DIR/config"
cp "$ROOT/.pi/extensions/fm-calm.ts" "$PROJECT/.pi/extensions/fm-calm.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-assistant-layout.ts" "$PROJECT/.pi/extensions/lib/fm-calm-assistant-layout.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-operational-user-layout.ts" "$PROJECT/.pi/extensions/lib/fm-calm-operational-user-layout.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-visibility.ts" "$PROJECT/.pi/extensions/lib/fm-calm-visibility.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-working-ship.ts" "$PROJECT/.pi/extensions/lib/fm-calm-working-ship.ts"
cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$PROJECT/.pi/extensions/lib/fm-operational-input.ts"
ln -s "$PI_PACKAGE_DIR" "$PROJECT/node_modules/@earendil-works/pi-coding-agent"
ln -s "$PI_DEPENDENCY_DIR/@earendil-works/pi-tui" "$PROJECT/node_modules/@earendil-works/pi-tui"
ln -s "$PI_DEPENDENCY_DIR/typebox" "$PROJECT/node_modules/typebox"
printf '%s\n' '{"type":"module"}' >"$PROJECT/package.json"
printf '%s\n' on >"$FM_HOME_DIR/config/calm"
cat >"$PROJECT/.pi/extensions/pdf-reader.ts" <<'TS'
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

const component = (text: string) => ({
  invalidate() {},
  render() {
    return [text];
  },
});

export default function (pi: ExtensionAPI): void {
  pi.registerTool({
    name: "read",
    label: "Foreign PDF reader",
    description: "FOREIGN_PDF_DESCRIPTION",
    promptSnippet: "FOREIGN_PDF_PROMPT_SNIPPET",
    promptGuidelines: ["FOREIGN_PDF_PROMPT_GUIDELINE"],
    parameters: Type.Object({
      path: Type.String({ description: "FOREIGN_PDF_PATH_PARAMETER" }),
    }),
    renderShell: "self",
    async execute(_toolCallId, params) {
      return {
        content: [{ type: "text", text: `FOREIGN_PDF_EXECUTION:${params.path}` }],
        details: {},
      };
    },
    renderCall() {
      return component("FOREIGN_PDF_RENDER_CALL");
    },
    renderResult() {
      return component("FOREIGN_PDF_RENDER_RESULT");
    },
  });
}
TS

OUTPUT_FILE="$TMP_ROOT/node-output"
(cd "$PROJECT" && \
  AGENT_DIR="$AGENT_DIR" \
  CALM_EXT="$PROJECT/.pi/extensions/fm-calm.ts" \
  PDF_EXT="$PROJECT/.pi/extensions/pdf-reader.ts" \
  FM_HOME="$FM_HOME_DIR" \
  PI_PACKAGE_DIR="$PI_PACKAGE_DIR" \
  node --input-type=module) >"$OUTPUT_FILE" 2>&1 <<'JS'
import { pathToFileURL } from "node:url";

const packageRoot = process.env.PI_PACKAGE_DIR;
const {
  createAgentSession,
  DefaultResourceLoader,
  SessionManager,
} = await import(pathToFileURL(`${packageRoot}/dist/index.js`).href);

const loader = new DefaultResourceLoader({
  cwd: process.cwd(),
  agentDir: process.env.AGENT_DIR,
  additionalExtensionPaths: [process.env.CALM_EXT, process.env.PDF_EXT],
  noExtensions: true,
  noSkills: true,
  noPromptTemplates: true,
  noThemes: true,
  noContextFiles: true,
});
await loader.reload();
const loaded = loader.getExtensions();
if (loaded.extensions.length !== 2) {
  throw new Error(`Pi did not load both extensions: ${JSON.stringify(loaded.errors)}`);
}
if (loaded.errors.some(({ error }) => error.includes('Tool "read" conflicts'))) {
  throw new Error(`Calm contested read during Pi extension discovery: ${JSON.stringify(loaded.errors)}`);
}

const { session } = await createAgentSession({
  cwd: process.cwd(),
  agentDir: process.env.AGENT_DIR,
  resourceLoader: loader,
  sessionManager: SessionManager.inMemory(process.cwd()),
});
const diagnostics = [];
const originalConsoleError = console.error;
console.error = (...args) => diagnostics.push(args.join(" "));
await session.bindExtensions({});
console.error = originalConsoleError;
if (!diagnostics.some((line) => line.includes('built-in "read"'))) {
  throw new Error(`Calm did not diagnose the real PDF read conflict: ${JSON.stringify(diagnostics)}`);
}

const info = session.getAllTools().find((tool) => tool.name === "read");
if (!info || !info.sourceInfo.path.endsWith("pdf-reader.ts")) {
  throw new Error(`Pi did not keep the PDF extension as read owner: ${JSON.stringify(info)}`);
}
if (
  info.description !== "FOREIGN_PDF_DESCRIPTION" ||
  !JSON.stringify(info.parameters).includes("FOREIGN_PDF_PATH_PARAMETER") ||
  JSON.stringify(info.promptGuidelines) !== JSON.stringify(["FOREIGN_PDF_PROMPT_GUIDELINE"])
) {
  throw new Error(`Pi did not keep the PDF reader prompt metadata: ${JSON.stringify(info)}`);
}
if (!session.systemPrompt.includes("FOREIGN_PDF_PROMPT_SNIPPET")) {
  throw new Error("Pi did not keep the PDF reader prompt snippet in the active system prompt");
}

const definition = session.getToolDefinition("read");
if (!definition || definition.label !== "Foreign PDF reader" || definition.renderShell !== "self") {
  throw new Error("Pi did not select the complete PDF read definition");
}
const execution = await definition.execute("pdf-read", { path: "paper.pdf" }, undefined, undefined, {});
if (execution.content[0]?.text !== "FOREIGN_PDF_EXECUTION:paper.pdf") {
  throw new Error(`Pi selected the wrong read execution: ${JSON.stringify(execution)}`);
}
const callRows = definition.renderCall?.({ path: "paper.pdf" }, {}, {}).render(120);
const resultRows = definition.renderResult?.(execution, {}, {}, {}).render(120);
if (JSON.stringify(callRows) !== JSON.stringify(["FOREIGN_PDF_RENDER_CALL"])) {
  throw new Error(`Pi selected the wrong read call renderer: ${JSON.stringify(callRows)}`);
}
if (JSON.stringify(resultRows) !== JSON.stringify(["FOREIGN_PDF_RENDER_RESULT"])) {
  throw new Error(`Pi selected the wrong read result renderer: ${JSON.stringify(resultRows)}`);
}

for (const name of ["bash", "edit", "write", "grep", "find", "ls"]) {
  const tool = session.getAllTools().find((candidate) => candidate.name === name);
  if (!tool?.sourceInfo.path.endsWith("fm-calm.ts")) {
    throw new Error(`Calm did not wrap uncontested built-in ${name}: ${JSON.stringify(tool)}`);
  }
}
session.dispose();
JS
STATUS=$?
OUT=$(cat "$OUTPUT_FILE")
[ "$STATUS" -eq 0 ] || fail "Pi persisted-Calm duplicate-read path failed: $OUT"
[ -z "$OUT" ] || fail "Pi persisted-Calm duplicate-read test printed output: $OUT"
pass "Pi $PI_VERSION real runtime kept persisted Calm from contesting PDF read and preserved its execution, prompt metadata, and renderers"
