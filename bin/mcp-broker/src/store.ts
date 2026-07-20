// Central credential store — the "credential authority" from the report's
// generalizable-primitives list (item 1). File-based, one JSON doc per broker
// home, every write atomic + mode 0600.
//
// Generalizes: lndev keychain.rs fallback file (atomic tmp+rename, 0o600) and
// the sandbox's per-provider tokens.env files, collapsed into one store keyed
// by provider. No OS keychain here (prototype), but the write path mirrors
// keychain.rs::write_private_file exactly.

import {
    chmodSync,
    mkdirSync,
    readFileSync,
    renameSync,
    rmSync,
    statSync,
    writeFileSync,
} from 'node:fs'
import { dirname, join } from 'node:path'

import type { CredentialRecord } from './types.ts'

type StoreFile = { version: 1; records: Record<string, CredentialRecord> }

export class CredentialStore {
    private readonly path: string

    constructor(home: string) {
        this.path = join(home, 'credentials.json')
        mkdirSync(dirname(this.path), { recursive: true })
    }

    get filePath(): string {
        return this.path
    }

    refreshLockPath(provider: string): string {
        const safeProvider = provider.replace(/[^A-Za-z0-9._-]/g, '_')
        return join(dirname(this.path), `${safeProvider}.refresh.lock`)
    }

    private read(): StoreFile {
        try {
            const raw = readFileSync(this.path, 'utf8')
            const parsed = JSON.parse(raw) as StoreFile
            if (parsed.version !== 1 || typeof parsed.records !== 'object') {
                throw new Error('corrupt store; move it aside and re-connect')
            }
            return parsed
        } catch (error) {
            if ((error as NodeJS.ErrnoException).code === 'ENOENT') {
                return { version: 1, records: {} }
            }
            throw error
        }
    }

    // Atomic: write to a pid-suffixed tmp with 0600, then rename over the target.
    // Rename is atomic on the same fs, so a concurrent reader never sees a
    // half-written file. Same shape as keychain.rs write_fallback.
    private write(data: StoreFile): void {
        const tmp = `${this.path}.${process.pid}.tmp`
        writeFileSync(tmp, JSON.stringify(data, null, 2), { mode: 0o600 })
        chmodSync(tmp, 0o600)
        renameSync(tmp, this.path)
        chmodSync(this.path, 0o600)
    }

    get(provider: string): CredentialRecord | null {
        return this.read().records[provider] ?? null
    }

    list(): CredentialRecord[] {
        return Object.values(this.read().records)
    }

    put(record: CredentialRecord): void {
        const data = this.read()
        data.records[record.provider] = { ...record, updatedAt: nowMs() }
        this.write(data)
    }

    delete(provider: string): void {
        const data = this.read()
        if (delete data.records[provider]) this.write(data)
    }
}

// Centralized clock so the demo can be deterministic if needed; Date.now is fine
// for a runnable prototype.
export function nowMs(): number {
    return Date.now()
}

export async function withFileLock<T>(lockPath: string, fn: () => Promise<T>): Promise<T> {
    const timeoutMs = Number(process.env.BROKER_LOCK_TIMEOUT_MS ?? 10_000)
    const staleMs = Number(process.env.BROKER_LOCK_STALE_MS ?? 60_000)
    const start = nowMs()

    while (true) {
        try {
            mkdirSync(lockPath, { mode: 0o700 })
            writeFileSync(join(lockPath, 'owner'), `${process.pid}\n`, { mode: 0o600 })
            break
        } catch (error) {
            const code = (error as NodeJS.ErrnoException).code
            if (code !== 'EEXIST') throw error
            try {
                const st = statSync(lockPath)
                if (nowMs() - st.mtimeMs > staleMs) {
                    rmSync(lockPath, { recursive: true, force: true })
                    continue
                }
            } catch {
                continue
            }
            if (nowMs() - start > timeoutMs) {
                throw new Error(`timed out waiting for refresh lock ${lockPath}`)
            }
            await sleep(50)
        }
    }

    try {
        return await fn()
    } finally {
        rmSync(lockPath, { recursive: true, force: true })
    }
}

function sleep(ms: number): Promise<void> {
    return new Promise((resolve) => setTimeout(resolve, ms))
}
