import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { chmod, cp, mkdir, mkdtemp, readFile, readdir, symlink, writeFile, link, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const sourceDirectory = fileURLToPath(new URL("./", import.meta.url));
const piPackageRoot = join(spawnSync("npm", ["root", "-g"], { encoding: "utf8" }).stdout.trim(), "@earendil-works", "pi-coding-agent");
const { visibleWidth } = await import(pathToFileURL(join(piPackageRoot, "node_modules/@earendil-works/pi-tui/dist/index.js")).href);
const manifestEnvironmentName = "WAYFINDER_SECURE_CREDENTIALS_MANIFEST";
const canarySecret = "CANARY_SECRET_VALUE_SHOULD_NOT_ESCAPE";

let testCount = 0;

function pass(message) {
	testCount += 1;
	console.log(`ok - ${message}`);
}

function assertNoSecret(value, label) {
	const serialized = typeof value === "string" ? value : JSON.stringify(value);
	assert.equal(serialized.includes(canarySecret), false, `${label} exposed the canary`);
}

async function createFixture(name) {
	const root = await mkdtemp(join(tmpdir(), `secure-credentials-${name}-`));
	await mkdir(join(root, "node_modules/@earendil-works"), { recursive: true });
	await writeFile(join(root, "package.json"), '{"type":"module"}\n');
	await symlink(piPackageRoot, join(root, "node_modules/@earendil-works/pi-coding-agent"));
	await symlink(join(piPackageRoot, "node_modules/@earendil-works/pi-tui"), join(root, "node_modules/@earendil-works/pi-tui"));
	await symlink(join(piPackageRoot, "node_modules/@earendil-works/pi-ai"), join(root, "node_modules/@earendil-works/pi-ai"));
	await symlink(join(piPackageRoot, "node_modules/typebox"), join(root, "node_modules/typebox"));
	await cp(sourceDirectory, join(root, "secure-credentials"), { recursive: true });
	return root;
}

async function createWorkspace(name, destinations, options = {}) {
	const root = await createFixture(name);
	const privateDirectory = join(root, "private");
	await mkdir(privateDirectory, { recursive: true });
	await chmod(privateDirectory, options.privateMode ?? 0o700);
	const manifestPath = join(privateDirectory, "manifest.json");
	const manifest = {
		version: 1,
		destinations: destinations.map((destination) => ({
			id: destination.id,
			path: destination.path ?? `${destination.id}.env`,
			keys: destination.keys,
		})),
	};
	await writeFile(manifestPath, JSON.stringify(manifest, null, 2) + "\n");
	await chmod(manifestPath, 0o600);
	return { root, privateDirectory, manifestPath };
}

async function createHarness(workspace, actionSets = [], options = {}) {
	const extensionPath = join(workspace.root, "secure-credentials/index.ts");
	const module = await import(`${pathToFileURL(extensionPath).href}?test=${Date.now()}-${Math.random()}`);
	const handlers = new Map();
	let tool;
	let customCalls = 0;
	let lastComponent;
	const renderWidths = options.renderWidths ?? [];
	const theme = {
		fg: (_color, text) => text,
		bold: (text) => text,
	};
	const tui = { requestRender() {} };
	const pi = {
		on(name, handler) {
			handlers.set(name, handler);
		},
		registerTool(candidate) {
			tool = candidate;
		},
	};
	module.default(pi);
	const sessionStart = handlers.get("session_start");
	assert.equal(typeof sessionStart, "function", "extension did not register session_start");
	const mode = options.mode ?? "tui";
	await sessionStart({ reason: "startup" }, { mode });

	const previousManifest = process.env[manifestEnvironmentName];
	process.env[manifestEnvironmentName] = workspace.manifestPath;
	const ui = {
		async custom(factory) {
			customCalls += 1;
			let resolveDialog;
			let settled = false;
			const resultPromise = new Promise((resolve) => {
				resolveDialog = resolve;
			});
			const done = (value) => {
				if (settled) return;
				settled = true;
				resolveDialog(value);
			};
			lastComponent = factory(tui, theme, {}, done);
			if (typeof lastComponent.focused === "boolean") lastComponent.focused = true;
			const width = renderWidths[customCalls - 1];
			if (width !== undefined) {
				const lines = lastComponent.render(width);
				for (const line of lines) {
					assert.ok(visibleWidth(line) <= width, `TUI line exceeded width ${width}`);
				}
				options.onRender?.(lines, lastComponent, customCalls);
			}
			const actions = actionSets.shift();
			if (typeof actions === "function") await actions(lastComponent, done);
			else for (const action of actions ?? []) lastComponent.handleInput(action);
			const result = await resultPromise;
			lastComponent.dispose?.();
			return result;
		},
	};
	const context = {
		mode,
		cwd: workspace.root,
		signal: options.signal,
		ui,
	};
	return {
		tool,
		handlers,
		context,
		get customCalls() {
			return customCalls;
		},
		get lastComponent() {
			return lastComponent;
		},
		async finish() {
			if (previousManifest === undefined) delete process.env[manifestEnvironmentName];
			else process.env[manifestEnvironmentName] = previousManifest;
		},
	};
}

async function executeCollection(workspace, actionSets, options = {}) {
	const harness = await createHarness(workspace, actionSets, options);
	try {
		const result = await harness.tool.execute("test-call", { keys: options.keys ?? [workspace.key] }, undefined, undefined, harness.context);
		return { result, harness };
	} finally {
		await harness.finish();
	}
}

async function assertRejectsCollection(workspace, options = {}) {
	const harness = await createHarness(workspace, options.actionSets ?? [], options);
	try {
		await assert.rejects(
			() => harness.tool.execute("test-call", { keys: options.keys ?? [workspace.key] }, undefined, undefined, harness.context),
			/secure credentials/i,
		);
	} finally {
		await harness.finish();
	}
}

async function testTuiRegistrationAndModeRefusal() {
	const workspace = await createWorkspace("registration", [{ id: "local", keys: ["REGISTRATION_KEY"] }]);
	workspace.key = "REGISTRATION_KEY";
	const tuiHarness = await createHarness(workspace, [["\r"]]);
	assert.equal(tuiHarness.tool.name, "secure_credentials_collect");
	assert.equal(tuiHarness.tool.executionMode, "sequential");
	assert.deepEqual(Object.keys(tuiHarness.tool.parameters.properties), ["keys"]);
	assert.equal(tuiHarness.tool.promptSnippet.includes("secret text"), true);
	await tuiHarness.finish();

	for (const mode of ["rpc", "print", "json"]) {
		const harness = await createHarness(workspace, [], { mode });
		assert.equal(harness.tool, undefined, `tool registered in ${mode} mode`);
		await harness.finish();
	}
	pass("registration is discoverable only in TUI mode and the schema accepts key names only");
}

async function testNewFileAndSecretBoundaries() {
	const workspace = await createWorkspace("new-file", [{ id: "local", keys: ["NEW_FILE_KEY"] }]);
	workspace.key = "NEW_FILE_KEY";
	const destination = join(workspace.privateDirectory, "local.env");
	const logs = [];
	const errors = [];
	const oldLog = console.log;
	const oldError = console.error;
	const oldWrite = process.stderr.write;
	console.log = (...args) => logs.push(args.join(" "));
	console.error = (...args) => errors.push(args.join(" "));
	process.stderr.write = (...args) => {
		errors.push(String(args[0]));
		return true;
	};
	const oldEnvironment = process.env.NEW_FILE_KEY;
	delete process.env.NEW_FILE_KEY;
	try {
		const { result, harness } = await executeCollection(workspace, [[canarySecret, "\r"]], {
			keys: ["NEW_FILE_KEY"],
			renderWidths: [18],
			onRender(lines, component) {
				assert.equal(lines.join("\n").includes("\x1b_pi:c\x07"), true, "focused page omitted the IME marker");
				assert.equal(lines.join("\n").includes(canarySecret), false, "focused page rendered the canary");
				component.handleInput("\x1b[C");
			},
		});
		assert.deepEqual(result, {
			content: [{ type: "text", text: "NEW_FILE_KEY local applied" }],
			details: { results: [{ key: "NEW_FILE_KEY", destination: "local", status: "applied" }] },
		});
		assert.equal(harness.customCalls, 1);
		const content = await readFile(destination, "utf8");
		assert.equal(content.includes(canarySecret), true);
		assert.equal((await stat(destination)).mode & 0o777, 0o600);
		assert.equal(process.env.NEW_FILE_KEY, undefined);
		const sessionJsonl = JSON.stringify({ type: "message", message: { role: "toolResult", ...result } });
		assertNoSecret(sessionJsonl, "session JSONL");
		assertNoSecret(result, "tool result");
		const rendered = harness.tool.renderResult(result, {}, { fg: (_color, text) => text }, {});
		assertNoSecret(rendered.render(120).join("\n"), "renderer");
		assertNoSecret(process.argv.join(" "), "argv");
		assertNoSecret(logs, "logs");
		assertNoSecret(errors, "stderr");
	} finally {
		if (oldEnvironment === undefined) delete process.env.NEW_FILE_KEY;
		else process.env.NEW_FILE_KEY = oldEnvironment;
		console.log = oldLog;
		console.error = oldError;
		process.stderr.write = oldWrite;
	}
	pass("new files use mode 0600 and the canary stays out of every returned or rendered artifact");
}

async function testExistingValueAndAtomicReplacement() {
	const workspace = await createWorkspace("overwrite", [{ id: "local", keys: ["OVERWRITE_KEY"] }]);
	workspace.key = "OVERWRITE_KEY";
	const destination = join(workspace.privateDirectory, "local.env");
	const original = "KEEP=one\r\nOVERWRITE_KEY=old\r\nTAIL=three\r\n";
	await writeFile(destination, original);
	await chmod(destination, 0o600);
	const first = await executeCollection(workspace, [["\r"]], { keys: ["OVERWRITE_KEY"] });
	assert.deepEqual(first.result.details.results[0], { key: "OVERWRITE_KEY", destination: "local", status: "skipped" });
	assert.equal(await readFile(destination, "utf8"), original);
	const second = await executeCollection(workspace, [["\x1b[C", "\r"], [canarySecret, "\r"]], { keys: ["OVERWRITE_KEY"] });
	assert.deepEqual(second.result.details.results[0], { key: "OVERWRITE_KEY", destination: "local", status: "applied" });
	const updated = await readFile(destination, "utf8");
	assert.equal(updated.includes(canarySecret), true);
	assert.equal(updated.includes("KEEP=one\r\n"), true);
	assert.equal(updated.includes("TAIL=three\r\n"), true);
	assert.equal(updated.includes("OVERWRITE_KEY=old"), false);
	assert.equal((await stat(destination)).mode & 0o777, 0o600);
	assert.equal((await readdir(workspace.privateDirectory)).some((entry) => entry.startsWith(".secure-credentials-")), false);
	pass("existing values stay unchanged by default and replacement preserves unrelated bytes atomically");
}

async function testAllowlistsAndManifestTraversal() {
	const workspace = await createWorkspace("allowlist", [{ id: "local", keys: ["ALLOWED_KEY"] }]);
	workspace.key = "ALLOWED_KEY";
	const harness = await createHarness(workspace, []);
	try {
		await assert.rejects(
			() => harness.tool.execute("test-call", { keys: ["NOT_ALLOWED"] }, undefined, undefined, harness.context),
			/allowlisted/i,
		);
		assert.equal(harness.customCalls, 0);
	} finally {
		await harness.finish();
	}
	const duplicateRequestHarness = await createHarness(workspace, []);
	try {
		await assert.rejects(
			() => duplicateRequestHarness.tool.execute("test-call", { keys: ["ALLOWED_KEY", "ALLOWED_KEY"] }, undefined, undefined, duplicateRequestHarness.context),
			/duplicate/i,
		);
	} finally {
		await duplicateRequestHarness.finish();
	}
	const traversal = await createWorkspace("traversal", [{ id: "escape", path: "../escape.env", keys: ["TRAVERSAL_KEY"] }]);
	traversal.key = "TRAVERSAL_KEY";
	await assertRejectsCollection(traversal, { keys: ["TRAVERSAL_KEY"] });
	const absolute = await createWorkspace("absolute", [{ id: "local", keys: ["ABSOLUTE_KEY"] }]);
	absolute.key = "ABSOLUTE_KEY";
	const absoluteDestination = join(absolute.privateDirectory, "absolute.env");
	const absoluteManifest = JSON.parse(await readFile(absolute.manifestPath, "utf8"));
	absoluteManifest.destinations[0].path = absoluteDestination;
	await writeFile(absolute.manifestPath, JSON.stringify(absoluteManifest, null, 2) + "\n");
	await chmod(absolute.manifestPath, 0o600);
	const absoluteResult = await executeCollection(absolute, [["ABSOLUTE_VALUE", "\r"]], { keys: ["ABSOLUTE_KEY"] });
	assert.deepEqual(absoluteResult.result.details.results, [{ key: "ABSOLUTE_KEY", destination: "local", status: "applied" }]);
	const duplicateManifest = await createWorkspace("manifest-duplicate", [
		{ id: "one", keys: ["DUPLICATE_MANIFEST_KEY"] },
		{ id: "two", keys: ["DUPLICATE_MANIFEST_KEY"] },
	]);
	duplicateManifest.key = "DUPLICATE_MANIFEST_KEY";
	await assertRejectsCollection(duplicateManifest, { keys: ["DUPLICATE_MANIFEST_KEY"] });
	pass("unknown keys, duplicate requests, manifest duplicates, traversal, and unambiguous absolute paths are covered");
}

async function testSymlinkHardlinkModesAndReadFailures() {
	const symlinkWorkspace = await createWorkspace("symlink", [{ id: "local", path: "link.env", keys: ["SYMLINK_KEY"] }]);
	symlinkWorkspace.key = "SYMLINK_KEY";
	const realFile = join(symlinkWorkspace.privateDirectory, "real.env");
	await writeFile(realFile, "SYMLINK_KEY=old\n");
	await chmod(realFile, 0o600);
	await symlink(realFile, join(symlinkWorkspace.privateDirectory, "link.env"));
	await assertRejectsCollection(symlinkWorkspace, { keys: ["SYMLINK_KEY"] });

	const hardlinkWorkspace = await createWorkspace("hardlink", [{ id: "local", path: "linked.env", keys: ["HARDLINK_KEY"] }]);
	hardlinkWorkspace.key = "HARDLINK_KEY";
	const source = join(hardlinkWorkspace.privateDirectory, "source.env");
	await writeFile(source, "HARDLINK_KEY=old\n");
	await chmod(source, 0o600);
	await link(source, join(hardlinkWorkspace.privateDirectory, "linked.env"));
	await assertRejectsCollection(hardlinkWorkspace, { keys: ["HARDLINK_KEY"] });

	const modeWorkspace = await createWorkspace("mode", [{ id: "local", path: "permissive.env", keys: ["MODE_KEY"] }]);
	modeWorkspace.key = "MODE_KEY";
	const permissive = join(modeWorkspace.privateDirectory, "permissive.env");
	await writeFile(permissive, "MODE_KEY=old\n");
	await chmod(permissive, 0o644);
	await assertRejectsCollection(modeWorkspace, { keys: ["MODE_KEY"] });

	const parentWorkspace = await createWorkspace("parent-symlink", [{ id: "local", path: "linked-dir/secret.env", keys: ["PARENT_KEY"] }]);
	parentWorkspace.key = "PARENT_KEY";
	const safeParent = join(parentWorkspace.root, "safe-parent");
	await mkdir(safeParent);
	await chmod(safeParent, 0o700);
	await symlink(safeParent, join(parentWorkspace.privateDirectory, "linked-dir"));
	await assertRejectsCollection(parentWorkspace, { keys: ["PARENT_KEY"] });

	const readFailureWorkspace = await createWorkspace("read-failure", [{ id: "local", path: "directory.env", keys: ["READ_FAILURE_KEY"] }]);
	readFailureWorkspace.key = "READ_FAILURE_KEY";
	await mkdir(join(readFailureWorkspace.privateDirectory, "directory.env"));
	await chmod(join(readFailureWorkspace.privateDirectory, "directory.env"), 0o700);
	await assertRejectsCollection(readFailureWorkspace, { keys: ["READ_FAILURE_KEY"] });
	pass("symlinks, hardlinks, permissive files, symlinked parents, and read failures stop before collection");
}

async function testDuplicateKeysAndLockContention() {
	const duplicateWorkspace = await createWorkspace("duplicate", [{ id: "local", keys: ["DUPLICATE_KEY"] }]);
	duplicateWorkspace.key = "DUPLICATE_KEY";
	const duplicateFile = join(duplicateWorkspace.privateDirectory, "local.env");
	const duplicateBytes = "DUPLICATE_KEY=one\nDUPLICATE_KEY=two\n";
	await writeFile(duplicateFile, duplicateBytes);
	await chmod(duplicateFile, 0o600);
	await assertRejectsCollection(duplicateWorkspace, { keys: ["DUPLICATE_KEY"] });
	assert.equal(await readFile(duplicateFile, "utf8"), duplicateBytes);

	const lockWorkspace = await createWorkspace("lock", [{ id: "local", keys: ["LOCK_KEY"] }]);
	lockWorkspace.key = "LOCK_KEY";
	const lockPath = join(lockWorkspace.privateDirectory, "local.env.lock");
	await mkdir(lockPath);
	await chmod(lockPath, 0o700);
	const locked = await executeCollection(lockWorkspace, [[canarySecret, "\r"]], { keys: ["LOCK_KEY"] });
	assert.deepEqual(locked.result.details.results, [{ key: "LOCK_KEY", destination: "local", status: "skipped" }]);
	assert.equal(locked.harness.customCalls, 0);
	assert.equal(await stat(join(lockWorkspace.privateDirectory, "local.env")).then(() => true).catch(() => false), false);
	pass("duplicate assignments fail safely and lock contention skips without collecting input");
}

async function testCancellationAbortAndMultiplePages() {
	const cancellationWorkspace = await createWorkspace("cancel", [
		{ id: "local", keys: ["FIRST_KEY", "SECOND_KEY"] },
	]);
	cancellationWorkspace.key = "FIRST_KEY";
	const cancelResult = await executeCollection(cancellationWorkspace, [[canarySecret, "\r"], ["\x1b"]], {
		keys: ["FIRST_KEY", "SECOND_KEY"],
		renderWidths: [9, 9],
	});
	assert.deepEqual(cancelResult.result.details.results, [
		{ key: "FIRST_KEY", destination: "local", status: "cancelled" },
		{ key: "SECOND_KEY", destination: "local", status: "cancelled" },
	]);
	assert.equal(await stat(join(cancellationWorkspace.privateDirectory, "local.env")).then(() => true).catch(() => false), false);
	assert.equal(cancelResult.harness.customCalls, 2);

	const abortWorkspace = await createWorkspace("abort", [{ id: "local", keys: ["ABORT_KEY"] }]);
	abortWorkspace.key = "ABORT_KEY";
	const controller = new AbortController();
	const abortResult = await executeCollection(
		abortWorkspace,
		[(component) => {
			assert.equal(component.render(12).join("\n").includes("\x1b_pi:c\x07"), true);
			controller.abort();
		}],
		{ keys: ["ABORT_KEY"], signal: controller.signal },
	);
	assert.deepEqual(abortResult.result.details.results, [{ key: "ABORT_KEY", destination: "local", status: "cancelled" }]);
	assert.equal(await stat(join(abortWorkspace.privateDirectory, "local.env")).then(() => true).catch(() => false), false);
	pass("multiple pages, Escape, narrow widths, and AbortSignal cancellation leave no partial file");
}

async function testReloadCleanup() {
	const workspace = await createWorkspace("reload", [{ id: "local", keys: ["RELOAD_KEY"] }]);
	workspace.key = "RELOAD_KEY";
	const harness = await createHarness(workspace, [() => undefined], { keys: ["RELOAD_KEY"] });
	const pending = harness.tool.execute("test-call", { keys: ["RELOAD_KEY"] }, undefined, undefined, harness.context);
	await new Promise((resolve) => setImmediate(resolve));
	await harness.handlers.get("session_shutdown")({ reason: "reload" }, harness.context);
	const result = await pending;
	assert.deepEqual(result.details.results, [{ key: "RELOAD_KEY", destination: "local", status: "cancelled" }]);
	assert.equal(await stat(join(workspace.privateDirectory, "local.env")).then(() => true).catch(() => false), false);
	await harness.finish();
	pass("session shutdown cleanup cancels an active page without leaving a destination file");
}

async function findJsonlWithText(directory, text) {
	for (const entry of await readdir(directory, { withFileTypes: true })) {
		const entryPath = join(directory, entry.name);
		if (entry.isDirectory()) {
			const nested = await findJsonlWithText(entryPath, text);
			if (nested) return nested;
		} else if (entry.name.endsWith(".jsonl") && (await readFile(entryPath, "utf8")).includes(text)) {
			return entryPath;
		}
	}
	return undefined;
}

function shellQuote(value) {
	return `'${value.replaceAll("'", "'\\''")}'`;
}

async function testRealPiTuiSecretBoundary() {
	const workspace = await createWorkspace("real-tui", [{ id: "local", keys: ["E2E_KEY"] }]);
	const sessionsDirectory = join(workspace.root, "sessions");
	await mkdir(sessionsDirectory, { recursive: true });
	const destination = join(workspace.privateDirectory, "local.env");
	const driverPath = join(workspace.root, "driver.ts");
	const environmentObservation = join(workspace.root, "environment-observation.txt");
	const argvObservation = join(workspace.root, "argv-observation.txt");
	const tuiLog = join(workspace.root, "tui.log");
	await writeFile(
		driverPath,
		'import { createAssistantMessageEventStream } from "@earendil-works/pi-ai";\n' +
			'import { writeFileSync } from "node:fs";\n' +
			'export default function (pi) {\n' +
			'  pi.registerProvider("secure-e2e", {\n' +
			'    baseUrl: "http://127.0.0.1",\n' +
			'    apiKey: "test-only",\n' +
			'    api: "openai-completions",\n' +
			'    models: [{ id: "deterministic", name: "deterministic", reasoning: false, input: ["text"], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 4096, maxTokens: 128 }],\n' +
			'    streamSimple(model, context) {\n' +
			'      const stream = createAssistantMessageEventStream();\n' +
			'      const hasToolResult = context.messages.some((message) => message.role === "toolResult");\n' +
			'      const output = { role: "assistant", content: [], api: model.api, provider: model.provider, model: model.id, usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } }, stopReason: "pending", timestamp: Date.now() };\n' +
			'      queueMicrotask(() => {\n' +
			'        stream.push({ type: "start", partial: output });\n' +
			'        if (!hasToolResult) {\n' +
			'          const call = { type: "toolCall", id: "secure-e2e-call", name: "secure_credentials_collect", arguments: { keys: ["E2E_KEY"] } };\n' +
			'          output.content.push(call);\n' +
			'          output.stopReason = "toolUse";\n' +
			'          stream.push({ type: "toolcall_start", contentIndex: 0, partial: output });\n' +
			'          stream.push({ type: "toolcall_end", contentIndex: 0, toolCall: call, partial: output });\n' +
			'          stream.push({ type: "done", reason: "toolUse", message: output });\n' +
			'        } else {\n' +
			'          const text = "E2E_COMPLETE";\n' +
			'          output.content.push({ type: "text", text });\n' +
			'          output.stopReason = "stop";\n' +
			'          stream.push({ type: "text_start", contentIndex: 0, partial: output });\n' +
			'          stream.push({ type: "text_delta", contentIndex: 0, delta: text, partial: output });\n' +
			'          stream.push({ type: "text_end", contentIndex: 0, content: text, partial: output });\n' +
			'          stream.push({ type: "done", reason: "stop", message: output });\n' +
			'        }\n' +
			'        stream.end();\n' +
			'      });\n' +
			'      return stream;\n' +
			'    },\n' +
			'  });\n' +
			'  pi.on("session_shutdown", () => {\n' +
			'    writeFileSync(process.env.E2E_ENV_OBSERVATION, process.env.E2E_KEY ?? "<unset>");\n' +
			'    writeFileSync(process.env.E2E_ARGV_OBSERVATION, process.argv.join("\\u0000"));\n' +
			'  });\n' +
			'}\n',
	);

	const socket = `secure-credentials-e2e-${process.pid}`;
	const sessionName = `secure-credentials-${process.pid}`;
	const piCommand = [
		"env",
		`E2E_ENV_OBSERVATION=${shellQuote(environmentObservation)}`,
		`E2E_ARGV_OBSERVATION=${shellQuote(argvObservation)}`,
		`WAYFINDER_SECURE_CREDENTIALS_MANIFEST=${shellQuote(workspace.manifestPath)}`,
		`PI_TUI_WRITE_LOG=${shellQuote(tuiLog)}`,
		"PI_OFFLINE=1",
		"pi",
		"--session-dir",
		shellQuote(sessionsDirectory),
		"--no-context-files",
		"--no-skills",
		"--no-prompt-templates",
		"--no-extensions",
		"--approve",
		"-e",
		shellQuote(join(workspace.root, "secure-credentials/index.ts")),
		"-e",
		shellQuote(driverPath),
		"--provider",
		"secure-e2e",
		"--model",
		"deterministic",
		"begin",
	].join(" ");
	try {
		const started = spawnSync("tmux", ["-L", socket, "new-session", "-d", "-s", sessionName, "-x", "80", "-y", "24", `cd ${shellQuote(workspace.root)} && ${piCommand}`], {
			encoding: "utf8",
		});
		assert.equal(started.status, 0, started.stderr);
		let pane = "";
		for (let attempt = 0; attempt < 200; attempt += 1) {
			pane = spawnSync("tmux", ["-L", socket, "capture-pane", "-p", "-t", sessionName, "-S", "-200"], { encoding: "utf8" }).stdout;
			if (pane.includes("Credential key: E2E_KEY")) break;
			await new Promise((resolve) => setTimeout(resolve, 50));
		}
		assert.equal(pane.includes("Credential key: E2E_KEY"), true, pane);
		spawnSync("tmux", ["-L", socket, "send-keys", "-t", sessionName, "-l", canarySecret], { encoding: "utf8" });
		spawnSync("tmux", ["-L", socket, "send-keys", "-t", sessionName, "Enter"], { encoding: "utf8" });
		const sessionFilePromise = (async () => {
			for (let attempt = 0; attempt < 240; attempt += 1) {
				const sessionFile = await findJsonlWithText(sessionsDirectory, "E2E_COMPLETE");
				if (sessionFile) return sessionFile;
				await new Promise((resolve) => setTimeout(resolve, 50));
			}
			return undefined;
		})();
		const sessionFile = await sessionFilePromise;
		assert.ok(sessionFile, "Pi did not finish the deterministic TUI session");
		pane = spawnSync("tmux", ["-L", socket, "capture-pane", "-p", "-t", sessionName, "-S", "-300"], { encoding: "utf8" }).stdout;
		assertNoSecret(pane, "Pi TUI pane");
		assertNoSecret(await readFile(sessionFile, "utf8"), "real Pi session JSONL");
		assert.equal((await stat(destination)).mode & 0o777, 0o600);
		assert.equal((await readFile(destination, "utf8")).includes(canarySecret), true);
		spawnSync("tmux", ["-L", socket, "send-keys", "-t", sessionName, "C-d"], { encoding: "utf8" });
		let observedEnvironment;
		for (let attempt = 0; attempt < 200; attempt += 1) {
			try {
				observedEnvironment = await readFile(environmentObservation, "utf8");
				break;
			} catch {
				await new Promise((resolve) => setTimeout(resolve, 50));
			}
		}
		assert.ok(observedEnvironment !== undefined, "Pi did not emit the shutdown environment observation");
		assertNoSecret(observedEnvironment, "Pi process environment");
		assertNoSecret(await readFile(argvObservation, "utf8"), "Pi argv");
		assertNoSecret(await readFile(tuiLog, "utf8"), "Pi TUI write log");
		pass("real Pi TUI collection keeps the canary out of the pane, session JSONL, environment, argv, and TUI log");
	} finally {
		spawnSync("tmux", ["-L", socket, "kill-session", "-t", sessionName], { encoding: "utf8" });
	}
}

async function testPlainPiDoesNotDiscoverExtension() {
	const root = await createFixture("plain-launch");
	const probePath = join(root, "probe.ts");
	const outputPath = join(root, "tool-names.json");
	await writeFile(
		probePath,
		'import { writeFileSync } from "node:fs";\n' +
			'export default function (pi) {\n' +
			'  pi.on("session_start", (_event, ctx) => {\n' +
			'    writeFileSync(process.env.PROBE_OUTPUT, JSON.stringify(pi.getAllTools().map((tool) => tool.name)));\n' +
			'    ctx.shutdown();\n' +
			'  });\n' +
			'}\n',
	);
	const child = spawnSync(
		"pi",
		[
			"--mode",
			"rpc",
			"--no-session",
			"--no-context-files",
			"--no-skills",
			"--no-prompt-templates",
			"--approve",
			"--offline",
			"-e",
			probePath,
		],
		{
			cwd: root,
			encoding: "utf8",
			timeout: 30000,
			env: { ...process.env, PROBE_OUTPUT: outputPath },
		},
	);
	assert.equal(child.error, undefined, child.error?.message);
	assert.equal(child.status, 0, child.stderr);
	const names = JSON.parse(await readFile(outputPath, "utf8"));
	assert.equal(names.includes("secure_credentials_collect"), false);
	pass("an ordinary Pi launch does not auto-discover the opt-in extension outside .pi/extensions");
}

await testTuiRegistrationAndModeRefusal();
await testNewFileAndSecretBoundaries();
await testExistingValueAndAtomicReplacement();
await testAllowlistsAndManifestTraversal();
await testSymlinkHardlinkModesAndReadFailures();
await testDuplicateKeysAndLockContention();
await testCancellationAbortAndMultiplePages();
await testReloadCleanup();
await testRealPiTuiSecretBoundary();
await testPlainPiDoesNotDiscoverExtension();
console.log(`secure-credentials tests: ${testCount} passed`);
