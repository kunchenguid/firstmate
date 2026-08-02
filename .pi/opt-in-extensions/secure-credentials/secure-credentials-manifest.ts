import { constants } from "node:fs";
import { lstat, open } from "node:fs/promises";
import { dirname, isAbsolute, parse, relative, resolve, sep } from "node:path";

import type {
	SecureCredentialsDestination,
	SecureCredentialsManifest,
} from "./secure-credentials-contract.ts";

/** The operator environment variable that selects the manifest file. */
export const SECURE_CREDENTIALS_MANIFEST_ENV = "WAYFINDER_SECURE_CREDENTIALS_MANIFEST";

const SECURE_CREDENTIAL_KEY_PATTERN = /^[A-Za-z_][A-Za-z0-9_]*$/u;
const SECURE_CREDENTIAL_DESTINATION_ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]*$/u;
const SECURE_CREDENTIAL_MANIFEST_MODE_MASK = 0o022;

/** A safe configuration error that never includes file contents or secret values. */
export class SecureCredentialsManifestError extends Error {
	constructor(message: string) {
		super(`Secure credentials manifest error: ${message}`);
		this.name = "SecureCredentialsManifestError";
	}
}

/** Check whether a string is a valid environment-style credential key name. */
export function isSecureCredentialKeyName(value: string): boolean {
	return SECURE_CREDENTIAL_KEY_PATTERN.test(value);
}

/** Check whether a string is a safe operator-defined logical destination name. */
export function isSecureCredentialDestinationId(value: string): boolean {
	return SECURE_CREDENTIAL_DESTINATION_ID_PATTERN.test(value);
}

/** Resolve the operator-selected manifest without accepting a model-supplied path. */
export function resolveSecureCredentialsManifestPath(
	cwd: string,
	environment: Readonly<Record<string, string | undefined>> = process.env,
): string {
	const configuredPath = environment[SECURE_CREDENTIALS_MANIFEST_ENV];
	if (!configuredPath) {
		throw new SecureCredentialsManifestError(
			`set ${SECURE_CREDENTIALS_MANIFEST_ENV} before starting the specialist TUI session`,
		);
	}
	if (configuredPath.includes("\0")) {
		throw new SecureCredentialsManifestError("the configured manifest path contains a NUL byte");
	}
	return resolve(cwd, configuredPath);
}

/** Read and validate the private operator-owned allowlist manifest. */
export async function readSecureCredentialsManifest(
	manifestPath: string,
): Promise<SecureCredentialsManifest> {
	const absolutePath = resolve(manifestPath);
	let handle: Awaited<ReturnType<typeof open>> | undefined;
	try {
		await validateSecureCredentialsManifestParent(dirname(absolutePath));
		const metadata = await lstat(absolutePath);
		if (metadata.isSymbolicLink()) {
			throw new SecureCredentialsManifestError("the manifest must not be a symlink");
		}
		if (!metadata.isFile() || metadata.nlink !== 1) {
			throw new SecureCredentialsManifestError("the manifest must be one ordinary file with one link");
		}
		if ((metadata.mode & SECURE_CREDENTIAL_MANIFEST_MODE_MASK) !== 0) {
			throw new SecureCredentialsManifestError("the manifest must not be group or world writable");
		}
		assertCurrentOwner(metadata.uid, "the manifest");

		const noFollow = (constants as { O_NOFOLLOW?: number }).O_NOFOLLOW ?? 0;
		handle = await open(absolutePath, constants.O_RDONLY | noFollow);
		const openedMetadata = await handle.stat();
		if (openedMetadata.isSymbolicLink() || !openedMetadata.isFile() || openedMetadata.nlink !== 1) {
			throw new SecureCredentialsManifestError("the manifest changed to a non-ordinary file");
		}
		assertCurrentOwner(openedMetadata.uid, "the manifest");
		const bytes = await handle.readFile();
		const text = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
		return parseSecureCredentialsManifest(text, absolutePath);
	} catch (error) {
		if (error instanceof SecureCredentialsManifestError) throw error;
		throw new SecureCredentialsManifestError("the manifest could not be read");
	} finally {
		await handle?.close().catch(() => undefined);
	}
}

/** Parse a manifest string and resolve every destination relative to its manifest file. */
export function parseSecureCredentialsManifest(
	text: string,
	manifestPath: string,
): SecureCredentialsManifest {
	let value: unknown;
	try {
		value = JSON.parse(text) as unknown;
	} catch {
		throw new SecureCredentialsManifestError("the manifest is not valid JSON");
	}

	if (!isRecord(value) || value.version !== 1 || !Array.isArray(value.destinations)) {
		throw new SecureCredentialsManifestError("the manifest must contain version 1 and destinations");
	}

	const manifestDirectory = dirname(resolve(manifestPath));
	const destinations: SecureCredentialsDestination[] = [];
	const seenIds = new Set<string>();
	const seenPaths = new Set<string>();
	const seenKeys = new Set<string>();

	for (const candidate of value.destinations) {
		if (!isRecord(candidate)) {
			throw new SecureCredentialsManifestError("each destination must be an object");
		}
		const id = candidate.id;
		const rawPath = candidate.path;
		const keys = candidate.keys;
		if (
			typeof id !== "string" ||
			!isSecureCredentialDestinationId(id) ||
			typeof rawPath !== "string" ||
			rawPath.length === 0 ||
			rawPath.includes("\0") ||
			!Array.isArray(keys) ||
			keys.length === 0 ||
			!keys.every((key): key is string => typeof key === "string")
		) {
			throw new SecureCredentialsManifestError("each destination needs a safe id, path, and key list");
		}
		if (seenIds.has(id)) {
			throw new SecureCredentialsManifestError("destination ids must be unique");
		}
		seenIds.add(id);

		const destinationPath = resolveManifestDestinationPath(manifestDirectory, rawPath);
		if (seenPaths.has(destinationPath)) {
			throw new SecureCredentialsManifestError("destination paths must be unique");
		}
		seenPaths.add(destinationPath);
		if (destinationPath === resolve(manifestPath)) {
			throw new SecureCredentialsManifestError("the manifest cannot also be a credential destination");
		}

		const uniqueKeys = new Set<string>();
		for (const key of keys) {
			if (!isSecureCredentialKeyName(key)) {
				throw new SecureCredentialsManifestError("credential key names must use environment-style characters");
			}
			if (uniqueKeys.has(key) || seenKeys.has(key)) {
				throw new SecureCredentialsManifestError("credential key names must be unique across destinations");
			}
			uniqueKeys.add(key);
			seenKeys.add(key);
		}

		destinations.push({ id, path: destinationPath, keys: [...uniqueKeys] });
	}

	if (destinations.length === 0) {
		throw new SecureCredentialsManifestError("the manifest must allow at least one destination");
	}

	return { version: 1, destinations };
}

/** Resolve only operator-manifest paths and reject relative traversal outside the manifest directory. */
function resolveManifestDestinationPath(manifestDirectory: string, rawPath: string): string {
	if (isAbsolute(rawPath)) return resolve(rawPath);
	const destinationPath = resolve(manifestDirectory, rawPath);
	const escaped = relative(manifestDirectory, destinationPath);
	if (escaped === ".." || escaped.startsWith(`..${sep}`) || isAbsolute(escaped)) {
		throw new SecureCredentialsManifestError("relative destination paths must stay under the manifest directory");
	}
	return destinationPath;
}

function isRecord(value: unknown): value is Record<string, unknown> {
	return typeof value === "object" && value !== null && !Array.isArray(value);
}

async function validateSecureCredentialsManifestParent(directoryPath: string): Promise<void> {
	const absoluteDirectory = resolve(directoryPath);
	const root = parse(absoluteDirectory).root;
	let current = root;
	const parts = absoluteDirectory.slice(root.length).split(/[\\/]/u).filter(Boolean);
	for (const part of parts) {
		current = `${current}${current.endsWith("/") || current.endsWith("\\") ? "" : "/"}${part}`;
		const metadata = await lstat(current).catch(() => undefined);
		if (!metadata || metadata.isSymbolicLink() || !metadata.isDirectory()) {
			throw new SecureCredentialsManifestError("manifest path components must be ordinary directories");
		}
	}
	const metadata = await lstat(absoluteDirectory).catch(() => undefined);
	if (!metadata || metadata.isSymbolicLink() || !metadata.isDirectory()) {
		throw new SecureCredentialsManifestError("the manifest parent must be an ordinary directory");
	}
	if ((metadata.mode & 0o077) !== 0) {
		throw new SecureCredentialsManifestError("the manifest parent must be private");
	}
	assertCurrentOwner(metadata.uid, "the manifest parent");
}

function assertCurrentOwner(uid: number | undefined, subject: string): void {
	if (typeof process.getuid !== "function" || uid === undefined) return;
	if (uid !== process.getuid()) {
		throw new SecureCredentialsManifestError(`${subject} must belong to the current operator`);
	}
}
