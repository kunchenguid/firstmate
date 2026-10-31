/** Verify Codemode presentation through Calm's extension API and Pi's real components. */
import assert from "node:assert/strict";
import { readFileSync, writeFileSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { pathToFileURL } from "node:url";

const packageRoot = process.env.PI_PACKAGE_DIR;
const { ToolExecutionComponent } = await import(pathToFileURL(`${packageRoot}/dist/modes/interactive/components/tool-execution.js`));
const { getEditorTheme, initTheme, theme } = await import(pathToFileURL(`${packageRoot}/dist/modes/interactive/theme/theme.js`));
const { BUILTIN_SLASH_COMMANDS } = await import(pathToFileURL(`${packageRoot}/dist/core/slash-commands.js`));
const { CombinedAutocompleteProvider, Container, Editor, Text, setCapabilities } = await import(pathToFileURL(`${process.env.PI_TUI_PACKAGE_DIR}/dist/index.js`));
const extension = await import(pathToFileURL(process.env.EXT));
const visibility = await import(pathToFileURL(process.env.VISIBILITY));
initTheme("dark");
setCapabilities({ images: null, trueColor: true, hyperlinks: false });

/** Ignore unrelated presentation notifications in this isolated fixture. */
function ignoreNotification() {}

/** Let the editor's asynchronous autocomplete request settle, failing instead of hanging. */
async function waitForAutocomplete(editor) {
  for (let attempt = 0; attempt < 100 && !editor.isShowingAutocomplete(); attempt++) {
    await new Promise(resolve => setTimeout(resolve, 1));
  }
  assert(editor.isShowingAutocomplete(), "Pi's editor never opened slash-command autocomplete");
}

/** Capture only supported extension registrations and presentation lifecycle effects. */
function registerCalm(supported = true, hasUI = true) {
  const handlers = new Map();
  const tools = [];
  const warnings = [];
  const autocompleteWrappers = [];
  const editor = new Editor({ requestRender: ignoreNotification, terminal: { rows: 44, columns: 120 } }, getEditorTheme());
  let resolver;
  let command;
  let terminalInput;
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
    /** Read the real editor the way Pi's interactive mode does. */
    getEditorText: () => editor.getExpandedText(),
    /** Collect autocomplete wrappers for Pi's stacking order over its built-in slash commands. */
    addAutocompleteProvider(wrapper) { autocompleteWrappers.push(wrapper); },
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
  const builtInProvider = new CombinedAutocompleteProvider(BUILTIN_SLASH_COMMANDS, process.cwd());
  editor.setAutocompleteProvider(autocompleteWrappers.reduce((provider, wrap) => wrap(provider), builtInProvider));
  /** Deliver one key in Pi's TUI order: terminal input listeners, then the focused editor. */
  function press(key) {
    terminalInput(key);
    editor.handleInput(key);
  }
  return { resolver, tools, warnings, command, ui,
    /**
     * Type a command and press Enter, optionally after slash autocomplete opens and Down selects another item.
     * The dispatch callback runs inside the editor's submit, where Pi runs /export and /share, without publication.
     */
    async submit(text, { autocomplete = false, down = 0, dispatch = ignoreNotification } = {}) {
      let submission;
      editor.onSubmit = (submitted) => { submission = { text: submitted, rendering: dispatch() }; };
      for (const key of text) press(key);
      if (autocomplete) await waitForAutocomplete(editor);
      for (let move = 0; move < down; move++) press("\x1b[B");
      press("\r");
      return submission;
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
// Both rows render Pi's elapsed timer, so they share one frozen clock instead of depending on host speed.
const systemNow = Date.now;
const frozenNow = systemNow();
Date.now = () => frozenNow;
try {
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
} finally {
  Date.now = systemNow;
}
assert.equal(JSON.stringify(result), serialized, "presentation mutated results or nested calls");
if (presentations.length > 1) {
  const { createToolHtmlRenderer } = await import(pathToFileURL(`${packageRoot}/dist/core/export-html/tool-renderer.js`));
  const original = presentations[0];
  const lookup = () => calm.resolver("codemode", () => original);
  const exporter = createToolHtmlRenderer({ getToolDefinition: lookup, getToolRenderers: lookup, theme, cwd: process.cwd() });
  const stockExporter = createToolHtmlRenderer({ getToolDefinition: () => original, getToolRenderers: () => original, theme, cwd: process.cwd() });
  const exportArgs = { code: 'text(await tools.fm_branch_outcomes({recent:2}));' };
  /** Render one Codemode entry the way Pi's /export and /share handlers do. */
  const exportCodemode = (renderer) => ({
    call: renderer.renderCall("exported", "codemode", exportArgs),
    result: renderer.renderResult("exported", "codemode", result.content, result.details, false),
  });
  const stockExport = exportCodemode(stockExporter);
  assert(stockExport.call.includes("tools.fm_branch_outcomes"));
  assert(stockExport.result.expanded.includes("RAW_OUTPUT_17"));
  const { createReadToolDefinition } = await import(pathToFileURL(`${packageRoot}/dist/core/tools/index.js`));
  const readTool = calm.tools.find((tool) => tool.name === "read");
  const stockRead = createReadToolDefinition(process.cwd());
  const readArgs = { path: "sample.txt" };
  const readResult = { content: [{ type: "text", text: "READ_PRIVATE" }], details: {}, isError: false };
  /** Render one read entry the way Pi's /export and /share handlers do. */
  const exportRead = (definition) => {
    const renderer = createToolHtmlRenderer({ getToolDefinition: () => definition, getToolRenderers: () => definition, theme, cwd: process.cwd() });
    return {
      call: renderer.renderCall("exported-read", "read", readArgs),
      result: renderer.renderResult("exported-read", "read", readResult.content, readResult.details, false),
    };
  };
  const stockReadExport = exportRead(stockRead);
  assert(stockReadExport.result.expanded.includes("READ_PRIVATE"));
  const submissions = [
    { typed: "/export test.html", submitted: "/export test.html", exports: true },
    { typed: "/share", submitted: "/share", exports: true },
    { typed: "/export", autocomplete: true, submitted: "/export", exports: true },
    { typed: "/exp", autocomplete: true, submitted: "/export", exports: true },
    { typed: "/sha", autocomplete: true, submitted: "/share", exports: true },
    { typed: "/s", autocomplete: true, down: 2, submitted: "/share", exports: true },
    { typed: "/s", autocomplete: true, submitted: "/settings", exports: false },
    { typed: "/ses", autocomplete: true, submitted: "/session", exports: false },
  ];
  for (const calmActive of [true, false]) {
    visibility.setCalmPresentation(calmActive);
    const live = row(lookup());
    live.updateResult(result);
    const liveRead = new ToolExecutionComponent("read", "live-read", readArgs, { showImages: false }, readTool, { requestRender: ignoreNotification }, process.cwd());
    liveRead.markExecutionStarted();
    liveRead.setArgsComplete();
    liveRead.updateResult(readResult);
    const presented = live.render(80);
    const presentedRead = liveRead.render(80);
    assert.equal(presented.length === 0, calmActive, "the live Codemode row ignored Calm");
    assert.equal(presentedRead.length === 0, calmActive, "the live read row ignored Calm");
    for (const { typed, submitted, exports, ...keys } of submissions) {
      const label = `${typed}${keys.autocomplete ? " via autocomplete" : ""} with Calm ${calmActive ? "on" : "off"}`;
      let constructed;
      const submission = await calm.submit(typed, { ...keys,
        /** Redraw and construct live rows, then export, all inside the submission. */
        dispatch() {
          live.invalidate();
          liveRead.invalidate();
          const redrawn = { codemode: live.render(80), read: liveRead.render(80) };
          constructed = row(lookup());
          return { redrawn, exported: exportCodemode(exporter), exportedRead: exportRead(readTool) };
        },
      });
      assert.equal(submission?.text, submitted, `${label} submitted the wrong command`);
      assert.deepEqual(submission.rendering.exported, stockExport, `${label} changed stock Codemode export/share output`);
      assert.deepEqual(submission.rendering.redrawn.codemode, presented, `${label} changed a live Codemode row`);
      if (exports) assert.deepEqual(submission.rendering.exportedRead, stockReadExport, `${label} changed stock read export/share output`);
      else assert.deepEqual(submission.rendering.redrawn.read, presentedRead, `${label} rendered live rows as if exporting`);
      await new Promise(resolve => setTimeout(resolve, 0));
      assert.deepEqual(live.render(80), presented, `${label} did not keep the live Codemode row`);
      assert.deepEqual(liveRead.render(80), presentedRead, `${label} did not restore the live read row`);
      constructed.updateResult(result);
      assert.deepEqual(constructed.render(80), presented, `a row constructed during ${label} lost Calm's presentation`);
    }
    for (const [typed, autocomplete] of [["/share", false], ["/sha", true]]) {
      const label = `delayed ${typed}${autocomplete ? " via autocomplete" : ""} with Calm ${calmActive ? "on" : "off"}`;
      let finishAuth;
      const auth = new Promise(resolve => { finishAuth = resolve; });
      const submission = await calm.submit(typed, { autocomplete,
        /** Await credentials and real file I/O before the HTML export, as Pi's share can. */
        dispatch: () => auth.then(() => readFile(process.env.EXT)).then(() => exportCodemode(exporter)),
      });
      assert.equal(submission?.text, "/share", `${label} submitted the wrong command`);
      await new Promise(resolve => setTimeout(resolve, 0));
      live.invalidate();
      assert.deepEqual(live.render(80), presented, `${label} changed a live Codemode row while sharing`);
      const constructed = row(lookup());
      constructed.updateResult(result);
      assert.deepEqual(constructed.render(80), presented, `a row constructed during ${label} lost Calm's presentation`);
      finishAuth();
      assert.deepEqual(await submission.rendering, stockExport, `${label} changed stock Codemode share output`);
      assert.deepEqual(live.render(80), presented, `${label} changed a live Codemode row after sharing`);
    }
  }
  assert.equal(JSON.stringify(result), serialized, "export or share mutated results or nested calls");
  visibility.setCalmPresentation(true);
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
