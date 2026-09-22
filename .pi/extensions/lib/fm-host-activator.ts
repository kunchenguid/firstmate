import { spawnSync } from "node:child_process";
import { existsSync, readFileSync, realpathSync } from "node:fs";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export type FirstmateHostConfig = {
	fmRoot: string;
	fmHome: string;
	hostRoot: string;
	backend: string;
};

type ExtensionFactory = (pi: ExtensionAPI) => void | Promise<void>;

const policyMarker = "<!-- firstmate-host-supervisor-policy -->";

function physicalPath(path: string): string | undefined {
	try {
		return realpathSync(path);
	} catch {
		return undefined;
	}
}

function refuse(pi: ExtensionAPI, reason: string): void {
	const message = `FirstMate host activation refused: ${reason}`;
	console.error(message);
	pi.on("session_start", (_event, ctx) => {
		ctx.ui.setStatus(
			"firstmate-host",
			ctx.ui.theme.fg("error", "FirstMate inactive"),
		);
		ctx.ui.notify(message, "error");
	});
}

function validateConfig(config: FirstmateHostConfig): string | undefined {
	if (physicalPath(config.fmRoot) !== config.fmRoot)
		return `invalid FirstMate root ${config.fmRoot}`;
	if (physicalPath(config.fmHome) !== config.fmHome)
		return `invalid FirstMate home ${config.fmHome}`;
	if (physicalPath(config.hostRoot) !== config.hostRoot)
		return `invalid host root ${config.hostRoot}`;
	if (config.fmRoot === config.hostRoot)
		return "FirstMate root and host root must differ";
	if (!existsSync(resolve(config.hostRoot, "AGENTS.md")))
		return `host root has no AGENTS.md: ${config.hostRoot}`;
	if (!existsSync(resolve(config.fmRoot, "AGENTS.md")))
		return `FirstMate root has no AGENTS.md: ${config.fmRoot}`;

	const result = spawnSync(
		"bash",
		[
			"-c",
			'. "$1/bin/fm-host-root-lib.sh" && fm_host_root_assert_operational_roots "$3" "$1" "$4" && . "$1/bin/fm-backend.sh" && fm_backend_validate_spawn "$2"',
			"fm-host-activator",
			config.fmRoot,
			config.backend,
			config.hostRoot,
			config.fmHome,
		],
		{
			encoding: "utf8",
			env: {
				...process.env,
				FM_ROOT_OVERRIDE: config.fmRoot,
				FM_HOME: config.fmHome,
				FM_HOST_ROOT: config.hostRoot,
				FM_BACKEND: config.backend,
			},
		},
	);
	if (result.status !== 0)
		return result.stderr.trim() || `invalid backend ${config.backend}`;
	return undefined;
}

async function loadExtension(pi: ExtensionAPI, path: string): Promise<void> {
	const module = (await import(pathToFileURL(path).href)) as {
		default?: ExtensionFactory;
	};
	if (typeof module.default !== "function")
		throw new Error(`extension has no default factory: ${path}`);
	await module.default(pi);
}

export default async function activateFirstmateHost(
	pi: ExtensionAPI,
	config: FirstmateHostConfig,
): Promise<void> {
	if (
		process.env.FM_TARGET_WORKTREE ||
		physicalPath(process.cwd()) !== config.hostRoot
	)
		return;

	const invalid = validateConfig(config);
	if (invalid) {
		refuse(pi, invalid);
		return;
	}

	const expectedEnvironment: Record<string, string> = {
		FM_ROOT_OVERRIDE: config.fmRoot,
		FM_HOME: config.fmHome,
		FM_HOST_ROOT: config.hostRoot,
		FM_BACKEND: config.backend,
	};
	for (const [name, expected] of Object.entries(expectedEnvironment)) {
		const ambient = process.env[name];
		if (ambient !== undefined && ambient !== "" && ambient !== expected) {
			refuse(pi, `${name} is already set to a conflicting value`);
			return;
		}
	}
	Object.assign(process.env, expectedEnvironment);

	const supervisorPolicy = readFileSync(
		resolve(config.fmRoot, "AGENTS.md"),
		"utf8",
	).trimEnd();
	pi.on("resources_discover", () => ({
		skillPaths: [resolve(config.fmRoot, ".agents/skills")],
	}));
	pi.on("before_agent_start", (event) => {
		if (event.systemPrompt.includes(policyMarker)) return;
		return {
			systemPrompt: `${event.systemPrompt}\n\n${policyMarker}\n# FirstMate host supervisor policy\n\nThe host context above remains authoritative for host identity, lifecycle, and cwd.\nApply the following FirstMate supervisor policy additively.\n\n${supervisorPolicy}`,
		};
	});
	pi.on("session_start", (_event, ctx) => {
		ctx.ui.setStatus(
			"firstmate-host",
			ctx.ui.theme.fg("accent", "FirstMate active"),
		);
	});
	pi.on("session_shutdown", (_event, ctx) => {
		ctx.ui.setStatus("firstmate-host", undefined);
	});

	await loadExtension(
		pi,
		resolve(config.fmRoot, ".pi/extensions/fm-primary-turnend-guard.ts"),
	);
	await loadExtension(
		pi,
		resolve(config.fmRoot, ".pi/extensions/fm-primary-pi-watch.ts"),
	);
}
