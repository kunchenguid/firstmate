import { spawn } from 'node:child_process'
import { createInterface } from 'node:readline'

import { nowMs } from '../store.ts'
import type { CredentialRecord, ProviderAdapter, RelayTool } from '../types.ts'

const MONGO_TOOLS = [
    tool('mongo_list_collections', 'List collections for the URI default database or a named database.', {
        database: { type: 'string' },
    }),
    tool('mongo_find', 'Run a capped read-only find query.', {
        database: { type: 'string' },
        collection: { type: 'string' },
        filter: { type: 'object' },
        projection: { type: 'object' },
        limit: { type: 'number', description: 'Default 10, max 100.' },
    }),
    tool('mongo_aggregate', 'Run a capped read-only aggregation pipeline.', {
        database: { type: 'string' },
        collection: { type: 'string' },
        pipeline: { type: 'array' },
        limit: { type: 'number', description: 'Default 10, max 100.' },
    }),
] as const satisfies readonly RelayTool[]

export function makeMongoAdapter(opts: { mockUrl?: string }): ProviderAdapter {
    return {
        key: 'mongo',
        shape: 'stdio-relay',
        upstreamUrl: opts.mockUrl ?? 'mongodb-driver',
        relayTools: MONGO_TOOLS,

        needsRefresh(record: CredentialRecord | null) {
            return !record?.access.uri
        },

        async refresh(current) {
            if (!current?.access.uri) {
                throw new Error('mongo: no URI; run `broker connect mongo --uri-file <path>`')
            }
            return { provider: 'mongo', access: { uri: current.access.uri }, updatedAt: nowMs() }
        },

        authHeaders() {
            return {}
        },

        async handleRelayTool({ name, args, record }) {
            const op = buildOperation(name, args)
            if (opts.mockUrl) return jsonResult(await callMock(opts.mockUrl, op))
            return runMongoMcp(record.access.uri, op)
        },
    } satisfies ProviderAdapter
}

export function redactedMongoUri(uri: string): string {
    try {
        const url = new URL(uri)
        const host = url.host
        const db = url.pathname && url.pathname !== '/' ? url.pathname.replace(/^\//, '') : '<default-db>'
        return `${url.protocol}//<redacted>@${host}/${db}`
    } catch {
        return '<redacted-mongodb-uri>'
    }
}

function buildOperation(name: string, args: Record<string, unknown>): Record<string, unknown> {
    switch (name) {
        case 'mongo_list_collections':
            return { kind: 'listCollections', database: stringArg(args.database) || undefined }
        case 'mongo_find': {
            rejectDangerousQuery(args.filter)
            return {
                kind: 'find',
                database: stringArg(args.database) || undefined,
                collection: requireString(args.collection, 'collection'),
                filter: objectArg(args.filter, 'filter', {}),
                projection: objectArg(args.projection, 'projection', undefined),
                limit: clampInt(args.limit, 10, 1, 100),
            }
        }
        case 'mongo_aggregate': {
            const pipeline = arrayArg(args.pipeline, 'pipeline', [])
            rejectDangerousPipeline(pipeline)
            return {
                kind: 'aggregate',
                database: stringArg(args.database) || undefined,
                collection: requireString(args.collection, 'collection'),
                pipeline,
                limit: clampInt(args.limit, 10, 1, 100),
            }
        }
        default:
            throw new Error(`mongo: unsupported tool ${name}`)
    }
}

async function runMongoMcp(uri: string, op: Record<string, unknown>) {
    const mapped = mapToMongoMcp(uri, op)
    const commandLine = process.env.BROKER_MONGO_MCP_COMMAND
    const [command, ...args] = commandLine
        ? commandLine.split(/\s+/).filter(Boolean)
        : ['npx', '-y', 'mongodb-mcp']
    const child = spawn(command, args, {
        env: {
            ...process.env,
            MONGODB_URI: uri,
            // Defense-in-depth signal for MCP servers that honor it. The selected
            // default package is read-only and rejects write aggregation stages.
            MONGODB_READ_ONLY: 'true',
        },
        stdio: ['pipe', 'pipe', 'pipe'],
    })
    const rl = createInterface({ input: child.stdout })
    const pending = new Map<number, (v: unknown) => void>()
    let stderr = ''
    child.stderr.on('data', (chunk) => {
        stderr += String(chunk)
    })
    rl.on('line', (line) => {
        try {
            const msg = JSON.parse(line) as { id?: number }
            if (typeof msg.id === 'number' && pending.has(msg.id)) {
                pending.get(msg.id)!(msg)
                pending.delete(msg.id)
            }
        } catch {
            /* ignore non-JSON */
        }
    })
    function rpc(id: number, method: string, params?: unknown): Promise<any> {
        return new Promise((resolve, reject) => {
            const timer = setTimeout(() => {
                pending.delete(id)
                reject(new Error(`mongodb-mcp timed out waiting for ${method}`))
            }, 55_000)
            pending.set(id, (value) => {
                clearTimeout(timer)
                resolve(value)
            })
            child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n')
        })
    }
    const timeout = setTimeout(() => {
        child.kill()
    }, 60_000)
    try {
        const init = await rpc(1, 'initialize', {
            protocolVersion: '2024-11-05',
            capabilities: {},
            clientInfo: { name: 'firstmate-mcp-broker', version: '0.1.0' },
        })
        if (init.error) throw new Error(init.error.message)
        const call = await rpc(2, 'tools/call', mapped)
        if (call.error) throw new Error(call.error.message)
        return call.result
    } catch (error) {
        throw new Error(redactMongoSecrets(stderr || (error as Error).message))
    } finally {
        clearTimeout(timeout)
        child.kill()
    }
}

function mapToMongoMcp(uri: string, op: Record<string, unknown>): { name: string; arguments: Record<string, unknown> } {
    const database = String(op.database ?? defaultDatabaseFromUri(uri))
    if (op.kind === 'listCollections') {
        return { name: 'list_collections', arguments: { database } }
    }
    if (op.kind === 'find') {
        const pipeline: unknown[] = [{ $match: op.filter ?? {} }]
        if (op.projection) pipeline.push({ $project: op.projection })
        pipeline.push({ $limit: op.limit })
        return {
            name: 'run_aggregation',
            arguments: { database, collection: op.collection, pipeline },
        }
    }
    if (op.kind === 'aggregate') {
        const pipeline = [...(op.pipeline as unknown[]), { $limit: op.limit }]
        return {
            name: 'run_aggregation',
            arguments: { database, collection: op.collection, pipeline },
        }
    }
    throw new Error('unknown mongo op')
}

function defaultDatabaseFromUri(uri: string): string {
    try {
        const parsed = new URL(uri)
        const database = decodeURIComponent(parsed.pathname.replace(/^\//, '')).trim()
        if (database) return database
    } catch {
        // handled below
    }
    throw new Error('mongo database argument is required when URI has no default database')
}

async function callMock(base: string, op: Record<string, unknown>): Promise<unknown> {
    const res = await fetch(`${base.replace(/\/$/, '')}/mongo/${String(op.kind)}`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify(op),
    })
    const text = await res.text()
    if (!res.ok) throw new Error(`mongo mock failed: HTTP ${res.status} ${text}`)
    return JSON.parse(text)
}

function rejectDangerousPipeline(pipeline: unknown[]): void {
    const writeStages = new Set(['$out', '$merge'])
    for (const stage of pipeline) {
        if (!stage || typeof stage !== 'object' || Array.isArray(stage)) {
            throw new Error('mongo_aggregate pipeline must contain stage objects')
        }
        for (const key of Object.keys(stage)) {
            if (writeStages.has(key)) throw new Error(`mongo_aggregate rejects write stage ${key}`)
        }
        rejectDangerousQuery(stage)
    }
}

function rejectDangerousQuery(value: unknown): void {
    if (!value || typeof value !== 'object') return
    if (Array.isArray(value)) {
        for (const item of value) rejectDangerousQuery(item)
        return
    }
    for (const [key, child] of Object.entries(value)) {
        if (key === '$where' || key === '$function' || key === '$accumulator') {
            throw new Error(`mongo query rejects server-side code operator ${key}`)
        }
        rejectDangerousQuery(child)
    }
}

function redactMongoSecrets(text: string): string {
    return text.replace(/mongodb(?:\+srv)?:\/\/[^\s"'`]+/g, '<redacted-mongodb-uri>')
}

function tool(name: string, description: string, properties: Record<string, unknown>): RelayTool {
    return { name, description, inputSchema: { type: 'object', properties } }
}

function jsonResult(value: unknown) {
    return { content: [{ type: 'text' as const, text: JSON.stringify(value, null, 2) }] }
}

function stringArg(v: unknown): string {
    return typeof v === 'string' ? v.trim() : ''
}

function requireString(v: unknown, name: string): string {
    const s = stringArg(v)
    if (!s) throw new Error(`missing required argument "${name}"`)
    return s
}

function objectArg(
    v: unknown,
    name: string,
    fallback: Record<string, unknown> | undefined
): Record<string, unknown> | undefined {
    if (v === undefined || v === null) return fallback
    if (typeof v !== 'object' || Array.isArray(v)) throw new Error(`${name} must be an object`)
    return v as Record<string, unknown>
}

function arrayArg(v: unknown, name: string, fallback: unknown[]): unknown[] {
    if (v === undefined || v === null) return fallback
    if (!Array.isArray(v)) throw new Error(`${name} must be an array`)
    return v
}

function clampInt(v: unknown, fallback: number, min: number, max: number): number {
    const n = typeof v === 'number' ? v : Number(v)
    if (!Number.isFinite(n)) return fallback
    return Math.max(min, Math.min(max, Math.floor(n)))
}
