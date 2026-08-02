import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { Text } from "@earendil-works/pi-tui";
import { Type } from "typebox";

import {
	readSecureCredentialsManifest,
	resolveSecureCredentialsManifestPath,
	isSecureCredentialKeyName,
	SecureCredentialsManifestError,
} from "./secure-credentials-manifest.ts";
import {
	buildSecureCredentialsFileContent,
	readSecureCredentialsFile,
	removeSecureCredentialsFileIfUnchanged,
	SecureCredentialsFileError,
	withSecureCredentialsDestinationLock,
	withSecureCredentialsFileQueue,
	writeSecureCredentialsFileAtomically,
	type SecureCredentialsFileSnapshot,
} from "./secure-credentials-file.ts";
import type {
	SecureCredentialInputOutcome,
	SecureCredentialOverwriteOutcome,
	SecureCredentialResult,
	SecureCredentialsDestination,
	SecureCredentialsManifest,
	SecureCredentialsRequest,
	SecureCredentialsToolDetails,
} from "./secure-credentials-contract.ts";
import { SecureCredentialInputPage, SecureCredentialOverwritePage } from "./secure-credentials-ui.ts";

const SecureCredentialsRequestSchema = Type.Object({
	keys: Type.Array(Type.String({ description: "Allowlisted credential key names only" }), {
		minItems: 1,
		description: "Key names from the operator-owned manifest",
	}),
});

type SecureCredentialsToolCallbacks = {
	setActiveDialog: (cancel: () => void) => void;
	clearActiveDialog: (cancel: () => void) => void;
};

type ResolvedCredentialRequest = {
	key: string;
	destination: SecureCredentialsDestination;
};

/** Register the secure credential collector with the supplied TUI-only lifecycle callbacks. */
export function createSecureCredentialsTool(callbacks: SecureCredentialsToolCallbacks) {
	return {
		name: "secure_credentials_collect",
		label: "Secure Credentials",
		description:
			"Collect values for allowlisted credential key names in the specialist TUI and write only operator-manifest destinations.",
		promptSnippet: "Collect allowlisted credential values without returning secret text",
		promptGuidelines: [
			"Use secure_credentials_collect only with key names from the operator-owned manifest.",
			"Never place paths, commands, sinks, or credential values in secure_credentials_collect arguments.",
		],
		parameters: SecureCredentialsRequestSchema,
		executionMode: "sequential" as const,

		async execute(
			_toolCallId: string,
			params: SecureCredentialsRequest,
			signal: AbortSignal | undefined,
			_onUpdate: unknown,
			ctx: ExtensionContext,
		) {
			if (ctx.mode !== "tui") {
				throw new Error("Secure credentials collection requires TUI mode.");
			}

			const cancellation = createCancellationSignal(signal, ctx.signal);
			const removeActiveCollection = installActiveDialog(callbacks, cancellation.cancel);
			let resolvedRequests: ResolvedCredentialRequest[] | undefined;
			try {
				const manifestPath = resolveSecureCredentialsManifestPath(ctx.cwd);
				const manifest = await readSecureCredentialsManifest(manifestPath);
				resolvedRequests = resolveSecureCredentialRequests(params.keys, manifest);
				if (cancellation.signal.aborted) {
					return buildSecureCredentialsToolResult(buildCancelledDetails(resolvedRequests, new Map()));
				}
				const requests = resolvedRequests;
				const destinations = uniqueDestinations(requests);

				const execution = await withCredentialDestinationQueues(
					destinations,
					0,
					() =>
						withCredentialDestinationLocks(
							destinations,
							requests,
							0,
							() =>
								collectAndApplyCredentialChanges(
									requests,
									cancellation.signal,
									ctx,
									callbacks,
								),
						),
				);

				return buildSecureCredentialsToolResult(execution);
			} catch (error) {
				if (cancellation.signal.aborted && resolvedRequests) {
					return buildSecureCredentialsToolResult(buildCancelledDetails(resolvedRequests, new Map()));
				}
				if (error instanceof SecureCredentialsManifestError || error instanceof SecureCredentialsFileError) {
					throw error;
				}
				throw new Error("Secure credentials collection failed.");
			} finally {
				removeActiveCollection();
				cancellation.dispose();
			}
		},

		renderCall(args: SecureCredentialsRequest, theme: { fg: (color: string, text: string) => string; bold: (text: string) => string }) {
			const keys = Array.isArray(args?.keys) ? args.keys.filter((key): key is string => typeof key === "string") : [];
			const label = theme.fg("toolTitle", theme.bold("secure_credentials_collect"));
			const requested = keys.length > 0 ? theme.fg("muted", ` ${keys.join(", ")}`) : "";
			return new Text(label + requested, 0, 0);
		},

		renderResult(
			result: { details?: unknown },
			_options: unknown,
			theme: { fg: (color: string, text: string) => string },
		) {
			const details = result.details as SecureCredentialsToolDetails | undefined;
			if (!details || !Array.isArray(details.results)) {
				return new Text(theme.fg("error", "Secure credentials collection failed."), 0, 0);
			}
			const lines = details.results.map((item) => {
				const color = item.status === "applied" ? "success" : item.status === "cancelled" ? "warning" : "muted";
				return theme.fg(color, `${item.key} ${item.destination} ${item.status}`);
			});
			return new Text(lines.join("\n"), 0, 0);
		},
	};
}

/** Load and register the collector only after a TUI session has started. */
export default function secureCredentialsExtension(pi: ExtensionAPI): void {
	const activeDialog = createActiveDialogController();
	let registered = false;

	pi.on("session_start", async (_event, ctx) => {
		if (ctx.mode !== "tui" || registered) return;
		pi.registerTool(
			createSecureCredentialsTool({
				setActiveDialog: activeDialog.set,
				clearActiveDialog: activeDialog.clear,
			}),
		);
		registered = true;
	});

	pi.on("session_shutdown", async () => {
		activeDialog.cancel();
	});
}

async function collectAndApplyCredentialChanges(
	requests: ResolvedCredentialRequest[],
	signal: AbortSignal,
	ctx: ExtensionContext,
	callbacks: SecureCredentialsToolCallbacks,
): Promise<SecureCredentialsToolDetails> {
	const snapshots = new Map<string, SecureCredentialsFileSnapshot>();
	for (const destination of uniqueDestinations(requests)) {
		const snapshot = await readSecureCredentialsFile(destination.path);
		for (const request of requestsForDestination(requests, destination)) {
			if ((snapshot.keyOccurrences.get(request.key) ?? 0) > 1) {
				throw new SecureCredentialsFileError("duplicate key assignments must be resolved before collection");
			}
		}
		snapshots.set(destination.id, snapshot);
	}

	const statuses = new Map<string, SecureCredentialResult["status"]>();
	const values = new Map<string, string>();
	try {
		for (const request of requests) {
			if (signal.aborted) {
				return buildCancelledDetails(requests, statuses);
			}
			const snapshot = snapshots.get(request.destination.id);
			if (!snapshot) throw new SecureCredentialsFileError("destination snapshot is missing");
			const alreadyExists = (snapshot.keyOccurrences.get(request.key) ?? 0) === 1;

			if (alreadyExists) {
				const overwrite = await showOverwritePage(request, signal, ctx, callbacks);
				if (overwrite.kind === "cancelled") {
					return buildCancelledDetails(requests, statuses);
				}
				if (overwrite.kind === "skip") {
					statuses.set(request.key, "skipped");
					continue;
				}
			}

			const input = await showCredentialInputPage(request, signal, ctx, callbacks);
			if (input.kind === "cancelled") {
				return buildCancelledDetails(requests, statuses);
			}
			values.set(request.key, input.value);
			statuses.set(request.key, "applied");
		}

		if (signal.aborted) {
			return buildCancelledDetails(requests, statuses);
		}
		const writes = buildCredentialWrites(requests, snapshots, values);
		if (writes.length > 0) await commitCredentialWrites(writes);
		return buildSecureCredentialDetails(requests, statuses);
	} finally {
		values.clear();
	}
}

async function showCredentialInputPage(
	request: ResolvedCredentialRequest,
	signal: AbortSignal,
	ctx: ExtensionContext,
	callbacks: SecureCredentialsToolCallbacks,
): Promise<SecureCredentialInputOutcome> {
	if (signal.aborted) return { kind: "cancelled" };
	let finish: ((outcome: SecureCredentialInputOutcome) => void) | undefined;
	const cancel = () => finish?.({ kind: "cancelled" });
	const removeActive = installActiveDialog(callbacks, cancel);
	const abort = () => cancel();
	signal.addEventListener("abort", abort, { once: true });
	try {
		const result = await ctx.ui.custom<SecureCredentialInputOutcome>((tui, theme, _keybindings, done) => {
			finish = done;
			return new SecureCredentialInputPage(
				request.key,
				request.destination.id,
				theme,
				() => tui.requestRender(),
				done,
			);
		});
		return result ?? { kind: "cancelled" };
	} finally {
		signal.removeEventListener("abort", abort);
		removeActive();
	}
}

async function showOverwritePage(
	request: ResolvedCredentialRequest,
	signal: AbortSignal,
	ctx: ExtensionContext,
	callbacks: SecureCredentialsToolCallbacks,
): Promise<SecureCredentialOverwriteOutcome> {
	if (signal.aborted) return { kind: "cancelled" };
	let finish: ((outcome: SecureCredentialOverwriteOutcome) => void) | undefined;
	const cancel = () => finish?.({ kind: "cancelled" });
	const removeActive = installActiveDialog(callbacks, cancel);
	const abort = () => cancel();
	signal.addEventListener("abort", abort, { once: true });
	try {
		const result = await ctx.ui.custom<SecureCredentialOverwriteOutcome>((tui, theme, _keybindings, done) => {
			finish = done;
			return new SecureCredentialOverwritePage(
				request.key,
				request.destination.id,
				theme,
				() => tui.requestRender(),
				done,
			);
		});
		return result ?? { kind: "cancelled" };
	} finally {
		signal.removeEventListener("abort", abort);
		removeActive();
	}
}

function buildCredentialWrites(
	requests: ResolvedCredentialRequest[],
	snapshots: Map<string, SecureCredentialsFileSnapshot>,
	values: Map<string, string>,
): CredentialWrite[] {
	const writes: CredentialWrite[] = [];
	for (const destination of uniqueDestinations(requests)) {
		const snapshot = snapshots.get(destination.id);
		if (!snapshot) throw new SecureCredentialsFileError("destination snapshot is missing");
		const changes = new Map<string, string>();
		for (const request of requestsForDestination(requests, destination)) {
			const value = values.get(request.key);
			if (value !== undefined) changes.set(request.key, value);
		}
		if (changes.size === 0) continue;
		writes.push({
			destination,
			snapshot,
			nextBytes: buildSecureCredentialsFileContent(snapshot, changes),
		});
	}
	return writes;
}

interface CredentialWrite {
	destination: SecureCredentialsDestination;
	snapshot: SecureCredentialsFileSnapshot;
	nextBytes: Buffer;
}

async function commitCredentialWrites(writes: CredentialWrite[]): Promise<void> {
	const committed: CredentialWrite[] = [];
	try {
		for (const write of writes) {
			await writeSecureCredentialsFileAtomically(write.destination.path, write.snapshot, write.nextBytes);
			committed.push(write);
		}
	} catch {
		for (const write of committed.reverse()) {
			try {
				if (write.snapshot.exists) {
					const current = await readSecureCredentialsFile(write.destination.path);
					await writeSecureCredentialsFileAtomically(write.destination.path, current, write.snapshot.bytes);
				} else {
					await removeSecureCredentialsFileIfUnchanged(
						write.destination.path,
						write.snapshot,
						write.nextBytes,
					);
				}
			} catch {
				continue;
			}
		}
		throw new SecureCredentialsFileError("the credential transaction was rolled back");
	}
}

async function withCredentialDestinationQueues<T>(
	destinations: SecureCredentialsDestination[],
	index: number,
	callback: () => Promise<T>,
): Promise<T> {
	if (index >= destinations.length) return callback();
	return withSecureCredentialsFileQueue(destinations[index]!.path, () =>
		withCredentialDestinationQueues(destinations, index + 1, callback),
	);
}

async function withCredentialDestinationLocks(
	destinations: SecureCredentialsDestination[],
	requests: ResolvedCredentialRequest[],
	index: number,
	callback: () => Promise<SecureCredentialsToolDetails>,
): Promise<SecureCredentialsToolDetails> {
	if (index >= destinations.length) return callback();
	const lock = await withSecureCredentialsDestinationLock(destinations[index]!.path, () =>
		withCredentialDestinationLocks(destinations, requests, index + 1, callback),
	);
	if (!lock.locked) {
		return buildSkippedDetailsForRequests(requests);
	}
	return lock.value!;
}

function resolveSecureCredentialRequests(
	keys: string[],
	manifest: SecureCredentialsManifest,
): ResolvedCredentialRequest[] {
	if (!Array.isArray(keys) || keys.length === 0) {
		throw new SecureCredentialsManifestError("the request must contain at least one key name");
	}
	const byKey = new Map<string, SecureCredentialsDestination>();
	for (const destination of manifest.destinations) {
		for (const key of destination.keys) byKey.set(key, destination);
	}
	const seen = new Set<string>();
	return keys.map((key) => {
		if (typeof key !== "string" || !isSecureCredentialKeyName(key)) {
			throw new SecureCredentialsManifestError("the request contains an invalid key name");
		}
		if (seen.has(key)) throw new SecureCredentialsManifestError("the request contains a duplicate key name");
		seen.add(key);
		const destination = byKey.get(key);
		if (!destination) throw new SecureCredentialsManifestError(`key ${key} is not allowlisted`);
		return { key, destination };
	});
}

function uniqueDestinations(requests: ResolvedCredentialRequest[]): SecureCredentialsDestination[] {
	const byId = new Map<string, SecureCredentialsDestination>();
	for (const request of requests) byId.set(request.destination.id, request.destination);
	return [...byId.values()].sort((left, right) => left.path.localeCompare(right.path));
}

function requestsForDestination(
	requests: ResolvedCredentialRequest[],
	destination: SecureCredentialsDestination,
): ResolvedCredentialRequest[] {
	return requests.filter((request) => request.destination.id === destination.id);
}

function buildSecureCredentialsToolResult(details: SecureCredentialsToolDetails): {
	content: [{ type: "text"; text: string }];
	details: SecureCredentialsToolDetails;
} {
	const text = details.results
		.map((result) => `${result.key} ${result.destination} ${result.status}`)
		.join("\n");
	return { content: [{ type: "text", text }], details };
}

function buildSecureCredentialDetails(
	requests: ResolvedCredentialRequest[],
	statuses: Map<string, SecureCredentialResult["status"]>,
): SecureCredentialsToolDetails {
	return {
		results: requests.map((request) => ({
			key: request.key,
			destination: request.destination.id,
			status: statuses.get(request.key) ?? "skipped",
		})),
	};
}

function buildCancelledDetails(
	requests: ResolvedCredentialRequest[],
	statuses: Map<string, SecureCredentialResult["status"]>,
): SecureCredentialsToolDetails {
	return {
		results: requests.map((request) => ({
			key: request.key,
			destination: request.destination.id,
			status: statuses.get(request.key) === "skipped" ? "skipped" : "cancelled",
		})),
	};
}

function buildSkippedDetailsForRequests(requests: ResolvedCredentialRequest[]): SecureCredentialsToolDetails {
	return {
		results: requests.map((request) => ({
			key: request.key,
			destination: request.destination.id,
			status: "skipped" as const,
		})),
	};
}

function installActiveDialog(
	callbacks: SecureCredentialsToolCallbacks,
	cancel: () => void,
): () => void {
	callbacks.setActiveDialog(cancel);
	return () => callbacks.clearActiveDialog(cancel);
}

function createActiveDialogController(): {
	set: (cancel: () => void) => void;
	clear: (cancel: () => void) => void;
	cancel: () => void;
} {
	const activeCancels = new Set<() => void>();
	return {
		set(cancel) {
			activeCancels.add(cancel);
		},
		clear(cancel) {
			activeCancels.delete(cancel);
		},
		cancel() {
			for (const cancel of [...activeCancels]) cancel();
		},
	};
}

function createCancellationSignal(
	toolSignal: AbortSignal | undefined,
	contextSignal: AbortSignal | undefined,
): { signal: AbortSignal; cancel: () => void; dispose: () => void } {
	const controller = new AbortController();
	const relays: Array<() => void> = [];
	for (const source of [toolSignal, contextSignal]) {
		if (!source) continue;
		const relay = () => controller.abort();
		if (source.aborted) controller.abort();
		else {
			source.addEventListener("abort", relay, { once: true });
			relays.push(() => source.removeEventListener("abort", relay));
		}
	}
	return {
		signal: controller.signal,
		cancel: () => controller.abort(),
		dispose: () => relays.forEach((remove) => remove()),
	};
}
