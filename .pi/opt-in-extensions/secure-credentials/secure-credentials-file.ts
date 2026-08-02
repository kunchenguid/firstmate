import { constants } from "node:fs";
import { chmod, lstat, mkdtemp, open, rename, rmdir, unlink } from "node:fs/promises";
import { basename, dirname, parse, resolve } from "node:path";

import { withFileMutationQueue } from "@earendil-works/pi-coding-agent";

/** A safe filesystem error that never includes file contents or secret values. */
export class SecureCredentialsFileError extends Error {
	constructor(message: string) {
		super(`Secure credentials file error: ${message}`);
		this.name = "SecureCredentialsFileError";
	}
}

/** A non-blocking lock result for one destination file. */
export interface SecureCredentialsLockResult<T> {
	/** True when this operation acquired and released the destination lock. */
	locked: boolean;
	/** The callback result when the lock was acquired. */
	value?: T;
}

/** The safe snapshot used for compare-before-write and rollback. */
export interface SecureCredentialsFileSnapshot {
	/** Whether the destination existed when it was read. */
	exists: boolean;
	/** The original bytes, kept only for the active transaction. */
	bytes: Buffer;
	/** The original private mode when the destination existed. */
	mode?: number;
	/** The number of assignments for each environment-style key. */
	keyOccurrences: Map<string, number>;
}

/** Serialize a key change without shell interpolation or a multiline value. */
export function serializeSecureCredentialValue(value: string): string {
	if (value.includes("\n") || value.includes("\r")) {
		throw new SecureCredentialsFileError("credential values must be single-line");
	}
	return JSON.stringify(value);
}

/** Queue the complete destination mutation window for this local file. */
export function withSecureCredentialsFileQueue<T>(
	filePath: string,
	callback: () => Promise<T>,
): Promise<T> {
	return withFileMutationQueue(resolve(filePath), callback);
}

/** Acquire a private non-blocking lock directory for a destination file. */
export async function withSecureCredentialsDestinationLock<T>(
	filePath: string,
	callback: () => Promise<T>,
): Promise<SecureCredentialsLockResult<T>> {
	const absolutePath = resolve(filePath);
	const parentDirectory = dirname(absolutePath);
	await validateSecureCredentialsParentDirectory(parentDirectory);
	const lockPath = `${absolutePath}.lock`;

	try {
		await mkdirPrivateLockDirectory(lockPath);
	} catch (error) {
		if (isErrorCode(error, "EEXIST")) return { locked: false };
		throw new SecureCredentialsFileError("the destination lock could not be created");
	}

	try {
		return { locked: true, value: await callback() };
	} finally {
		await rmdir(lockPath);
	}
}

/** Read and validate one private destination without returning its value to callers. */
export async function readSecureCredentialsFile(filePath: string): Promise<SecureCredentialsFileSnapshot> {
	const absolutePath = resolve(filePath);
	await validateSecureCredentialsParentDirectory(dirname(absolutePath));

	let handle: Awaited<ReturnType<typeof open>> | undefined;
	try {
		const noFollow = (constants as { O_NOFOLLOW?: number }).O_NOFOLLOW ?? 0;
		handle = await open(absolutePath, constants.O_RDONLY | noFollow);
		const metadata = await handle.stat();
		validatePrivateCredentialFileMetadata(metadata);
		const bytes = await handle.readFile();
		const text = decodeCredentialFile(bytes);
		return {
			exists: true,
			bytes,
			mode: metadata.mode & 0o777,
			keyOccurrences: countSecureCredentialKeys(text),
		};
	} catch (error) {
		if (isErrorCode(error, "ENOENT")) {
			return { exists: false, bytes: Buffer.alloc(0), keyOccurrences: new Map() };
		}
		if (error instanceof SecureCredentialsFileError) throw error;
		throw new SecureCredentialsFileError("the destination could not be read");
	} finally {
		await handle?.close().catch(() => undefined);
	}
}

/** Build the next destination bytes while preserving unrelated lines byte-for-byte. */
export function buildSecureCredentialsFileContent(
	snapshot: SecureCredentialsFileSnapshot,
	changes: ReadonlyMap<string, string>,
): Buffer {
	const text = decodeCredentialFile(snapshot.bytes);
	const lines = splitSecureCredentialsLines(text);
	const serialized = new Map<string, string>();
	for (const [key, value] of changes) {
		serialized.set(key, serializeSecureCredentialValue(value));
	}

	const replaced = new Set<string>();
	const output: string[] = [];
	for (const line of lines) {
		const assignment = parseSecureCredentialsAssignment(line.body);
		if (!assignment || !serialized.has(assignment.key)) {
			output.push(line.body + line.ending);
			continue;
		}
		if ((snapshot.keyOccurrences.get(assignment.key) ?? 0) !== 1) {
			throw new SecureCredentialsFileError("duplicate key assignments must be resolved before writing");
		}
		output.push(
			`${assignment.prefix}${assignment.key}${assignment.separator}${serialized.get(assignment.key)}${line.ending}`,
		);
		replaced.add(assignment.key);
	}

	const lineEnding = findSecureCredentialsLineEnding(lines);
	for (const [key, value] of serialized) {
		if (replaced.has(key)) continue;
		const current = output.join("");
		if (current.length > 0 && !current.endsWith("\n") && !current.endsWith("\r")) {
			output.push(lineEnding);
		}
		output.push(`${key}=${value}${lineEnding}`);
		replaced.add(key);
	}

	return Buffer.from(output.join(""), "utf8");
}

/** Write destination bytes through a private temporary file and atomic rename. */
export async function writeSecureCredentialsFileAtomically(
	filePath: string,
	expected: SecureCredentialsFileSnapshot,
	nextBytes: Buffer,
): Promise<void> {
	const absolutePath = resolve(filePath);
	await validateSecureCredentialsParentDirectory(dirname(absolutePath));
	const current = await readSecureCredentialsFile(absolutePath);
	if (current.exists !== expected.exists || !current.bytes.equals(expected.bytes)) {
		throw new SecureCredentialsFileError("the destination changed during collection");
	}

	let temporaryDirectory: string | undefined;
	let temporaryPath: string | undefined;
	let handle: Awaited<ReturnType<typeof open>> | undefined;
	try {
		temporaryDirectory = await mkdtemp(`${dirname(absolutePath)}/.secure-credentials-`);
		await chmod(temporaryDirectory, 0o700);
		temporaryPath = `${temporaryDirectory}/${basename(absolutePath)}`;
		handle = await open(
			temporaryPath,
			constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL,
			0o600,
		);
		await handle.writeFile(nextBytes);
		await handle.sync();
		await handle.close();
		handle = undefined;
		await rename(temporaryPath, absolutePath);
		temporaryPath = undefined;
		await syncSecureCredentialsDirectory(dirname(absolutePath));

		const written = await readSecureCredentialsFile(absolutePath);
		if (!written.exists || written.mode !== 0o600 || !written.bytes.equals(nextBytes)) {
			throw new SecureCredentialsFileError("the atomic destination write did not verify");
		}
	} catch (error) {
		if (error instanceof SecureCredentialsFileError) throw error;
		throw new SecureCredentialsFileError("the atomic destination write failed");
	} finally {
		await handle?.close().catch(() => undefined);
		if (temporaryPath) await unlink(temporaryPath).catch(() => undefined);
		if (temporaryDirectory) await rmdir(temporaryDirectory).catch(() => undefined);
	}
}

/** Remove a newly created destination during a failed multi-file transaction. */
export async function removeSecureCredentialsFileIfUnchanged(
	filePath: string,
	expected: SecureCredentialsFileSnapshot,
	createdBytes: Buffer,
): Promise<void> {
	if (expected.exists) {
		throw new SecureCredentialsFileError("rollback expected a newly created destination");
	}
	const absolutePath = resolve(filePath);
	const current = await readSecureCredentialsFile(absolutePath);
	if (!current.exists) return;
	if (!current.bytes.equals(createdBytes)) {
		throw new SecureCredentialsFileError("the newly created destination changed before rollback");
	}
	await unlink(absolutePath);
	await syncSecureCredentialsDirectory(dirname(absolutePath));
}

async function validateSecureCredentialsParentDirectory(directoryPath: string): Promise<void> {
	const absoluteDirectory = resolve(directoryPath);
	const root = parse(absoluteDirectory).root;
	let current = root;
	const parts = absoluteDirectory.slice(root.length).split(/[\\/]/u).filter(Boolean);
	for (const part of parts) {
		current = `${current}${current.endsWith("/") || current.endsWith("\\") ? "" : "/"}${part}`;
		let metadata;
		try {
			metadata = await lstat(current);
		} catch {
			throw new SecureCredentialsFileError("the destination directory does not exist");
		}
		if (metadata.isSymbolicLink() || !metadata.isDirectory()) {
			throw new SecureCredentialsFileError("destination path components must be ordinary directories");
		}
	}

	const metadata = await lstat(absoluteDirectory).catch(() => undefined);
	if (!metadata || metadata.isSymbolicLink() || !metadata.isDirectory()) {
		throw new SecureCredentialsFileError("the destination parent must be an ordinary directory");
	}
	if ((metadata.mode & 0o077) !== 0) {
		throw new SecureCredentialsFileError("the destination parent must be private");
	}
	assertCurrentOwner(metadata.uid, "the destination parent");
}

function validatePrivateCredentialFileMetadata(metadata: Awaited<ReturnType<typeof lstat>>): void {
	if (metadata.isSymbolicLink() || !metadata.isFile() || metadata.nlink !== 1) {
		throw new SecureCredentialsFileError("the destination must be one ordinary file with one link");
	}
	if ((metadata.mode & 0o077) !== 0 || (metadata.mode & 0o200) === 0) {
		throw new SecureCredentialsFileError("the destination file must be private and owner-writable");
	}
	assertCurrentOwner(metadata.uid, "the destination file");
}

function decodeCredentialFile(bytes: Buffer): string {
	try {
		return new TextDecoder("utf-8", { fatal: true }).decode(bytes);
	} catch {
		throw new SecureCredentialsFileError("the destination is not valid UTF-8 text");
	}
}

interface SecureCredentialsLine {
	body: string;
	ending: string;
}

interface SecureCredentialsAssignment {
	prefix: string;
	key: string;
	separator: string;
}

function splitSecureCredentialsLines(text: string): SecureCredentialsLine[] {
	const lines: SecureCredentialsLine[] = [];
	let start = 0;
	for (let index = 0; index < text.length; index += 1) {
		const char = text[index];
		if (char !== "\n" && char !== "\r") continue;
		const ending = char === "\r" && text[index + 1] === "\n" ? "\r\n" : char;
		const end = ending === "\r\n" ? index + 2 : index + 1;
		lines.push({ body: text.slice(start, index), ending });
		start = end;
		if (ending === "\r\n") index += 1;
	}
	if (start < text.length || lines.length === 0) {
		lines.push({ body: text.slice(start), ending: "" });
	}
	return lines;
}

function parseSecureCredentialsAssignment(line: string): SecureCredentialsAssignment & { key: string } | undefined {
	const match = /^([ \t]*(?:export[ \t]+)?)([A-Za-z_][A-Za-z0-9_]*)([ \t]*=[ \t]*)(.*)$/u.exec(line);
	if (!match) return undefined;
	return { prefix: match[1] ?? "", key: match[2] ?? "", separator: match[3] ?? "" };
}

function countSecureCredentialKeys(text: string): Map<string, number> {
	const occurrences = new Map<string, number>();
	for (const line of splitSecureCredentialsLines(text)) {
		const assignment = parseSecureCredentialsAssignment(line.body);
		if (!assignment) continue;
		occurrences.set(assignment.key, (occurrences.get(assignment.key) ?? 0) + 1);
	}
	return occurrences;
}

function findSecureCredentialsLineEnding(lines: SecureCredentialsLine[]): string {
	return lines.find((line) => line.ending.length > 0)?.ending ?? "\n";
}

async function mkdirPrivateLockDirectory(lockPath: string): Promise<void> {
	const { mkdir } = await import("node:fs/promises");
	await mkdir(lockPath, { mode: 0o700 });
}

async function syncSecureCredentialsDirectory(directoryPath: string): Promise<void> {
	let handle: Awaited<ReturnType<typeof open>> | undefined;
	try {
		handle = await open(directoryPath, constants.O_RDONLY);
		await handle.sync();
	} catch (error) {
		if (!isIgnorableDirectorySyncError(error)) {
			throw new SecureCredentialsFileError("the destination directory could not be synchronized");
		}
	} finally {
		await handle?.close().catch(() => undefined);
	}
}

function isIgnorableDirectorySyncError(error: unknown): boolean {
	return ["EBADF", "EISDIR", "EINVAL", "ENOTSUP", "EPERM"].some((code) => isErrorCode(error, code));
}

function isErrorCode(error: unknown, code: string): boolean {
	return typeof error === "object" && error !== null && "code" in error && error.code === code;
}

function assertCurrentOwner(uid: number | undefined, subject: string): void {
	if (typeof process.getuid !== "function" || uid === undefined) return;
	if (uid !== process.getuid()) {
		throw new SecureCredentialsFileError(`${subject} must belong to the current operator`);
	}
}
