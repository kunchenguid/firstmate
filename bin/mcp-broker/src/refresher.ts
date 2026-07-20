// Generic refresher — the "provider refresher interface" driver. Given the
// store + registry, brings every provider's record up to date by calling its
// adapter.refresh() when adapter.needsRefresh() says so, and persists the
// result. Callable one-shot (before rendering / before a request) or on a loop.
//
// Generalizes lindy-cred-puller.sh: per-provider cadence + refresh, minus the
// Secret-Manager plumbing. The proxy/relay ALSO call ensureFresh per request so
// a token is never served stale even between loop ticks.

import { withFileLock, type CredentialStore } from './store.ts'
import type { CredentialRecord, ProviderAdapter } from './types.ts'

export async function ensureFresh(
    store: CredentialStore,
    adapter: ProviderAdapter
): Promise<CredentialRecord> {
    return withFileLock(store.refreshLockPath(adapter.key), async () => {
        const current = store.get(adapter.key)
        if (!adapter.needsRefresh(current)) {
            if (!current) throw new Error(`${adapter.key}: no credential record`)
            return current
        }
        const next = await adapter.refresh(current)
        store.put(next)
        return next
    })
}

export async function refreshAll(
    store: CredentialStore,
    registry: Map<string, ProviderAdapter>
): Promise<void> {
    for (const adapter of registry.values()) {
        try {
            await ensureFresh(store, adapter)
        } catch (error) {
            // Never let one provider's failure stall the others; never log the
            // token itself.
            process.stderr.write(`[refresher] ${adapter.key}: ${(error as Error).message}\n`)
        }
    }
}
