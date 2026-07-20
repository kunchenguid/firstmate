import { nowMs } from '../store.ts'
import type { CredentialRecord, ProviderAdapter, RelayTool } from '../types.ts'

const DATADOG_TOOLS = [
    tool('datadog_list_monitors', 'List Datadog monitors.', {
        groupStates: { type: 'string', description: 'Optional Datadog group_states value.' },
        name: { type: 'string', description: 'Optional monitor name filter.' },
        tags: { type: 'string', description: 'Optional comma-separated tag filter.' },
    }),
    tool('datadog_get_monitor', 'Read one Datadog monitor by id.', {
        monitorId: { type: 'number' },
    }),
    tool('datadog_query_metrics', 'Query Datadog metrics over a bounded time range.', {
        query: { type: 'string' },
        from: { type: 'number', description: 'Unix seconds. Default: one hour ago.' },
        to: { type: 'number', description: 'Unix seconds. Default: now.' },
    }),
    tool('datadog_search_logs', 'Search Datadog logs with a small capped limit.', {
        query: { type: 'string' },
        from: { type: 'string', description: 'ISO timestamp or relative value accepted by Datadog.' },
        to: { type: 'string', description: 'ISO timestamp or relative value accepted by Datadog.' },
        limit: { type: 'number' },
    }),
    tool('datadog_list_events', 'List Datadog events over a bounded time range.', {
        start: { type: 'number', description: 'Unix seconds. Default: one hour ago.' },
        end: { type: 'number', description: 'Unix seconds. Default: now.' },
        tags: { type: 'string' },
    }),
] as const satisfies readonly RelayTool[]

export function makeDatadogAdapter(opts: { apiBaseUrl: string }): ProviderAdapter {
    const apiBase = opts.apiBaseUrl.replace(/\/$/, '')
    return {
        key: 'datadog',
        shape: 'stdio-relay',
        upstreamUrl: apiBase,
        relayTools: DATADOG_TOOLS,

        needsRefresh(record: CredentialRecord | null) {
            return !record?.access.apiKey || !record?.access.appKey
        },

        async refresh(current) {
            if (!current?.access.apiKey || !current.access.appKey) {
                throw new Error(
                    'datadog: no API/application key pair; run `broker connect datadog --api-key ... --app-key ...`'
                )
            }
            return { provider: 'datadog', access: current.access, updatedAt: nowMs() }
        },

        authHeaders(record) {
            return {
                'DD-API-KEY': record.access.apiKey,
                'DD-APPLICATION-KEY': record.access.appKey,
            }
        },

        async handleRelayTool({ name, args, record }) {
            const api = makeApi(apiBase, this.authHeaders(record))
            switch (name) {
                case 'datadog_list_monitors': {
                    const params = new URLSearchParams()
                    if (stringArg(args.groupStates)) params.set('group_states', stringArg(args.groupStates))
                    if (stringArg(args.name)) params.set('name', stringArg(args.name))
                    if (stringArg(args.tags)) params.set('tags', stringArg(args.tags))
                    return jsonResult(await api.get(`/v1/monitor?${params}`))
                }
                case 'datadog_get_monitor':
                    return jsonResult(await api.get(`/v1/monitor/${requireInt(args.monitorId, 'monitorId')}`))
                case 'datadog_query_metrics': {
                    const now = Math.floor(Date.now() / 1000)
                    const to = intArg(args.to, now)
                    const from = intArg(args.from, to - 3600)
                    const params = new URLSearchParams({
                        from: String(from),
                        to: String(to),
                        query: requireString(args.query, 'query'),
                    })
                    return jsonResult(await api.get(`/v1/query?${params}`))
                }
                case 'datadog_search_logs': {
                    const body = {
                        filter: {
                            query: stringArg(args.query) || '*',
                            from: stringArg(args.from) || 'now-15m',
                            to: stringArg(args.to) || 'now',
                        },
                        page: { limit: clampInt(args.limit, 10, 1, 100) },
                    }
                    return jsonResult(await api.post('/v2/logs/events/search', body))
                }
                case 'datadog_list_events': {
                    const now = Math.floor(Date.now() / 1000)
                    const end = intArg(args.end, now)
                    const start = intArg(args.start, end - 3600)
                    const params = new URLSearchParams({ start: String(start), end: String(end) })
                    if (stringArg(args.tags)) params.set('tags', stringArg(args.tags))
                    return jsonResult(await api.get(`/v1/events?${params}`))
                }
                default:
                    throw new Error(`datadog: unsupported tool ${name}`)
            }
        },
    } satisfies ProviderAdapter
}

export async function verifyDatadog(apiBaseUrl: string, headers: Record<string, string>): Promise<unknown> {
    const api = makeApi(apiBaseUrl.replace(/\/$/, ''), headers)
    const validate = await api.get('/v1/validate')
    let currentUser: unknown = null
    try {
        currentUser = await api.get('/v2/current_user')
    } catch (error) {
        currentUser = { warning: (error as Error).message }
    }
    return { validate, currentUser }
}

function makeApi(base: string, headers: Record<string, string>) {
    return {
        async get(path: string): Promise<unknown> {
            const res = await fetch(`${base}${path}`, { headers })
            return parseResponse('datadog API', res)
        },
        async post(path: string, body: unknown): Promise<unknown> {
            const res = await fetch(`${base}${path}`, {
                method: 'POST',
                headers: { 'content-type': 'application/json', ...headers },
                body: JSON.stringify(body),
            })
            return parseResponse('datadog API', res)
        },
    }
}

async function parseResponse(label: string, res: Response): Promise<unknown> {
    const text = await res.text()
    if (!res.ok) throw new Error(`${label} failed: HTTP ${res.status} ${text.slice(0, 300)}`)
    try {
        return JSON.parse(text)
    } catch {
        return text
    }
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

function intArg(v: unknown, fallback: number): number {
    const n = typeof v === 'number' ? v : Number(v)
    return Number.isFinite(n) ? Math.floor(n) : fallback
}

function requireInt(v: unknown, name: string): number {
    const n = intArg(v, NaN)
    if (!Number.isFinite(n)) throw new Error(`missing required integer argument "${name}"`)
    return n
}

function clampInt(v: unknown, fallback: number, min: number, max: number): number {
    const n = intArg(v, fallback)
    if (!Number.isFinite(n)) return fallback
    return Math.max(min, Math.min(max, Math.floor(n)))
}
