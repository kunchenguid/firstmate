import { ensureFresh } from './refresher.ts'
import type { CredentialStore } from './store.ts'
import type { CredentialRecord, ProviderAdapter } from './types.ts'

export type AdapterToolCallResult = {
    output: unknown
    rawText: string
    isError: boolean
    status: number
}

export async function callAdapterTool(opts: {
    store: CredentialStore
    adapter: ProviderAdapter
    tool: string
    args?: Record<string, unknown>
}): Promise<AdapterToolCallResult> {
    const { store, adapter, tool, args = {} } = opts
    assertToolAllowed(adapter, tool)

    const record = await ensureFresh(store, adapter)
    const headers = { 'content-type': 'application/json', ...adapter.authHeaders(record) }

    if (adapter.handleRelayTool) {
        const result = await adapter.handleRelayTool({ name: tool, args, record })
        const rawText = result.content[0]?.text ?? ''
        return {
            output: parseJsonOrText(rawText),
            rawText,
            isError: Boolean(result.isError),
            status: result.isError ? 1 : 0,
        }
    }

    if (adapter.shape === 'stdio-relay') {
        const res = await fetch(`${adapter.upstreamUrl}/${tool}`, {
            method: 'POST',
            headers,
            body: JSON.stringify(args),
        })
        const rawText = await res.text()
        return {
            output: parseJsonOrText(rawText),
            rawText,
            isError: !res.ok,
            status: res.status,
        }
    }

    const res = await fetch(adapter.upstreamUrl, {
        method: 'POST',
        headers,
        body: JSON.stringify({
            jsonrpc: '2.0',
            id: 1,
            method: 'tools/call',
            params: { name: tool, arguments: args },
        }),
    })
    const rawText = await res.text()
    const rpc = parseJsonOrText(rawText) as {
        result?: unknown
        error?: { message?: string; code?: number }
    }
    const isError = !res.ok || Boolean(rpc.error)
    return {
        output: rpc.result ?? rpc,
        rawText,
        isError,
        status: res.status,
    }
}

export function assertToolAllowed(adapter: ProviderAdapter, tool: string): void {
    if (!tool) throw new Error('missing tool')
    if (adapter.relayTools && !adapter.relayTools.some((relayTool) => relayTool.name === tool)) {
        throw new Error(`unknown tool: ${tool}`)
    }
    if (adapter.allowMethod && !adapter.allowMethod(tool)) {
        const allowed = adapter.allowedMethods?.join(', ') ?? 'none'
        throw new Error(
            `${adapter.key}: tool "${tool}" is not allowed by broker allowlist; allowed: ${allowed}`
        )
    }
}

export function redactCredentialMaterial(value: unknown, record: CredentialRecord | null): unknown {
    const secrets = credentialSecretValues(record)
    return redactValue(value, secrets)
}

export function assertNoCredentialMaterial(text: string, record: CredentialRecord | null): void {
    const leaked = credentialSecretValues(record).find((secret) => text.includes(secret))
    if (leaked) {
        throw new Error('broker refused to print provider output containing credential material')
    }
}

function parseJsonOrText(text: string): unknown {
    try {
        return JSON.parse(text) as unknown
    } catch {
        return text
    }
}

function credentialSecretValues(record: CredentialRecord | null): string[] {
    if (!record) return []
    const values = [...Object.values(record.access)]
    if (record.refresh?.token) values.push(record.refresh.token)
    return values.filter((v) => v.length >= 4)
}

function redactValue(value: unknown, secrets: string[]): unknown {
    if (typeof value === 'string') {
        return secrets.reduce((s, secret) => s.split(secret).join('[REDACTED]'), value)
    }
    if (Array.isArray(value)) return value.map((entry) => redactValue(entry, secrets))
    if (!value || typeof value !== 'object') return value

    const redacted: Record<string, unknown> = {}
    for (const [key, entry] of Object.entries(value)) {
        redacted[key] = isSensitiveKey(key) ? '[REDACTED]' : redactValue(entry, secrets)
    }
    return redacted
}

function isSensitiveKey(key: string): boolean {
    return /token|secret|authorization|api_?key|bearer|password|credential/i.test(key)
}
