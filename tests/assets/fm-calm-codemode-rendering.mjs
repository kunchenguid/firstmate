/** Verify Codemode presentation through Calm's extension API and Pi's real components. */
import assert from "node:assert/strict";
import { readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const packageRoot = process.env.PI_PACKAGE_DIR;
const { ToolExecutionComponent } = await import(pathToFileURL(`${packageRoot}/dist/modes/interactive/components/tool-execution.js`));
const { initTheme, theme } = await import(pathToFileURL(`${packageRoot}/dist/modes/interactive/theme/theme.js`));
const { Container, Text, setCapabilities } = await import(pathToFileURL(`${process.env.PI_TUI_PACKAGE_DIR}/dist/index.js`));
const extension = await import(pathToFileURL(process.env.EXT));
const visibility = await import(pathToFileURL(process.env.VISIBILITY));
initTheme("dark");
setCapabilities({ images: null, trueColor: true, hyperlinks: false });

/** Ignore unrelated presentation notifications in this isolated fixture. */
function ignoreNotification() {}

/** Capture only supported extension registrations and presentation lifecycle effects. */
function registerCalm(supported = true, hasUI = true) {
  const handlers = new Map();
  const tools = [];
  const warnings = [];
  let resolver;
  let command;
  let terminalInput;
  let editorText = "";
  const pi = {
    events: { emit: ignoreNotification },
    /** Capture lifecycle binding for a real session-start simulation. */
    on(name, callback) { handlers.set(name, callback); },
    /** Record execution registrations to reject a same-name Codemode replacement. */
    registerTool(tool) { tools.push(tool); },
    /** Expose only Codemode metadata, never an executable replacement. */
    getAllTools() { return [{ name: "codemode" }]; },
    registerEntryRenderer: ignoreNotification,
    /** Capture Calm's supported toggle command. */
    registerCommand(name, registration) { if (name === "calm") command = registration; },
    ...(supported ? {
      /** Model supported registration or an explicit presentation-capability refusal. */
      registerToolRenderer(callback) {
        if (supported === "refused") throw new Error("test renderer capability refused");
        resolver = callback;
      },
    } : {}),
  };
  const ui = {
    /** Return the current export/share command for the submit hook. */
    getEditorText: () => editorText,
    /** Start with Pi's ordinary collapsed presentation. */
    getToolsExpanded: () => false,
    /** Capture the exact terminal-input adapter and return its disposal callback. */
    onTerminalInput(callback) {
      terminalInput = callback;
      return ignoreNotification;
    },
    setHiddenThinkingLabel: ignoreNotification,
    setStatus: ignoreNotification,
    setToolsExpanded: ignoreNotification,
    setWorkingVisible: ignoreNotification,
    /** Record user-visible capability diagnostics. */
    notify(message) { warnings.push(message); },
  };
  extension.default(pi);
  handlers.get("session_start")({}, { ui, hasUI });
  return { resolver, tools, warnings, command, ui,
    /** Exercise the same submit hook exports and shares use, without publication. */
    submit(text) {
      editorText = text;
      terminalInput("\r");
      editorText = "";
    },
  };
}

/** Construct a real row without running a tool or reading any private store. */
function row(renderers, args = { code: 'text(await tools.read({path:"sample.txt"}));\ntext(await tools.fm_branch_outcomes({recent:2}));' }, options = {}) {
  const component = new ToolExecutionComponent("codemode", "parent", args, { showImages: false, ...options }, renderers, { requestRender: ignoreNotification }, process.cwd());
  component.markExecutionStarted();
  component.setArgsComplete();
  return component;
}

const calm = registerCalm();
assert.equal(typeof calm.resolver, "function");
assert(!calm.tools.some((tool) => tool.name === "codemode"), "Calm claimed the executing tool");
const foreign = {
  /** Leave an unrelated tool's own call renderer intact. */
  renderCall: () => new Text("FOREIGN", 0, 0),
};
assert.equal(calm.resolver("unrelated_tool", () => foreign), foreign);
assert.equal(calm.resolver("unregistered_tool", () => undefined), undefined);

const calls = Array.from({ length: 10 }, (_, index) => ({ name: index % 2 ? "fm_branch_outcomes" : "read", args: JSON.stringify({ recent: index }), status: "ok", durationMs: 17, cost: 0.002 }));
const result = { content: [{ type: "text", text: "Script completed\nWall time 0.01 seconds\nOutput:\n" }, { type: "text", text: Array.from({ length: 18 }, (_, index) => `RAW_OUTPUT_${index}`).join("\n") }], details: { calls }, isError: false };
const serialized = JSON.stringify(result);
const presentations = [];
try {
  const { codemodeRenderers } = await import(pathToFileURL(`${packageRoot}/dist/extensions/codemode/renderer.js`));
  presentations.push(codemodeRenderers);
} catch (error) {
  if (error.code !== "ERR_MODULE_NOT_FOUND") throw error;
  console.log("skip: installed Pi has no Codemode renderer; synthetic capability coverage still runs");
}
presentations.push({
  renderShell: "self",
  /** Exercise a downstream self-framed renderer without recreating its output. */
  renderCall(args, _theme, context) {
    const component = context.lastComponent ?? new Container();
    component.clear();
    component.addChild(new Text(`SELF_CALL ${args.code}`, 0, 0));
    return component;
  },
  /** Preserve downstream result options and component reuse. */
  renderResult(result, options, _theme, context) {
    const component = context.lastComponent ?? new Container();
    component.clear();
    component.addChild(new Text(`${options.expanded}:${options.isPartial}:${result.content[1].text}`, 0, 0));
    return component;
  },
});
for (const original of presentations) {
  for (const outputPad of [0, 1]) {
    const wrapped = row(calm.resolver("codemode", () => original), undefined, { outputPad });
    const stock = row(original, undefined, { outputPad });
    for (const partial of [true, false]) {
      for (const expanded of [false, true, false]) {
        visibility.setCalmPresentation(false);
        stock.updateResult(result, partial);
        wrapped.updateResult(result, partial);
        stock.setExpanded(expanded);
        wrapped.setExpanded(expanded);
        for (const width of [24, 80, 160]) assert.deepEqual(wrapped.render(width), stock.render(width), `stock parity width=${width} expanded=${expanded} partial=${partial}`);
        visibility.setCalmPresentation(true);
        wrapped.invalidate();
        assert.deepEqual(wrapped.render(80), [], "Calm left a row or gap");
        visibility.setCalmPresentation(false);
        wrapped.invalidate();
        assert.deepEqual(wrapped.render(80), stock.render(80), "toggle changed stock restoration");
      }
    }
  }
}
assert.equal(JSON.stringify(result), serialized, "presentation mutated results or nested calls");
if (presentations.length > 1) {
  const { createToolHtmlRenderer } = await import(pathToFileURL(`${packageRoot}/dist/core/export-html/tool-renderer.js`));
  const original = presentations[0];
  visibility.setCalmPresentation(true);
  for (const command of ["/export test.html", "/share"]) {
    calm.submit(command);
    const live = row(calm.resolver("codemode", () => original));
    const lookup = () => calm.resolver("codemode", () => original);
    const exporter = createToolHtmlRenderer({ getToolDefinition: lookup, getToolRenderers: lookup, theme, cwd: process.cwd() });
    const stockExporter = createToolHtmlRenderer({ getToolDefinition: () => original, getToolRenderers: () => original, theme, cwd: process.cwd() });
    const args = { code: 'text(await tools.fm_branch_outcomes({recent:2}));' };
    const exportedCall = exporter.renderCall(command, "codemode", args);
    assert.equal(exportedCall, stockExporter.renderCall(command, "codemode", args), `${command} changed stock call rendering`);
    assert(exportedCall.includes("tools.fm_branch_outcomes"));
    const exportedResult = exporter.renderResult(command, "codemode", result.content, result.details, false);
    assert.deepEqual(exportedResult, stockExporter.renderResult(command, "codemode", result.content, result.details, false), `${command} changed stock result rendering`);
    assert(exportedResult.expanded.includes("RAW_OUTPUT_17"));
    await new Promise(resolve => setTimeout(resolve, 0));
    live.updateResult(result);
    assert.deepEqual(live.render(80), [], `a row constructed during ${command} stayed visible`);
  }
  setCapabilities({ images: "iterm2", trueColor: true, hyperlinks: false });
  const image = row(calm.resolver("codemode", () => original), undefined, { showImages: true });
  image.updateResult({ ...result, content: [{ type: "image", mimeType: "image/png", data: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jR1kAAAAASUVORK5CYII=" }] });
  assert(image.render(80).join("\n").includes("\x1b]1337;File="), "Calm hid an image outside the renderer slots");
}
const diagnostics = [];
const originalError = console.error;
console.error = (message) => diagnostics.push(message);
try {
  visibility.setCalmPresentation(true);
  assert.equal(calm.resolver("codemode", () => foreign), foreign);
  assert.equal(calm.resolver("codemode", () => foreign), foreign);
  assert.equal(calm.warnings.length, 1);
  assert.match(calm.warnings[0], /installed call\/result renderers are unavailable/);
  const unsupported = registerCalm(false);
  assert(unsupported.command && unsupported.tools.length === 7);
  assert.equal(unsupported.warnings.length, 1);
  assert.match(unsupported.warnings[0], /pi.registerToolRenderer\(\) is unavailable/);
  const refused = registerCalm("refused");
  assert(refused.command);
  assert.equal(refused.warnings.length, 1);
  assert.match(refused.warnings[0], /test renderer capability refused/);
  writeFileSync(`${process.env.FM_HOME}/config/calm`, "off\n");
  const startedOff = registerCalm(false);
  assert.equal(startedOff.warnings.length, 0, "Calm off disclosed an inactive limitation");
  await startedOff.command.handler("", { ui: startedOff.ui });
  assert.equal(startedOff.warnings.length, 1, "first activation did not disclose the missing API");
  assert.deepEqual(diagnostics, [], "a TUI capability warning was duplicated as raw stderr");
  registerCalm(false, false);
  assert.equal(diagnostics.length, 1, "a session without UI lost its capability disclosure");
  assert.match(diagnostics[0], /pi.registerToolRenderer\(\) is unavailable/);
} finally {
  console.error = originalError;
}
assert.equal(readFileSync(`${process.env.FM_HOME}/config/calm`, "utf8"), "on\n");
console.log("ok - Codemode renderer capability probes, zero-height calls/results, stock framing and expansion, downstream renderers, unrelated tools and immutable results");
