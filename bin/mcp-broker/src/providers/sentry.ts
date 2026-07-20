import { nowMs } from '../store.ts'
import type { CredentialRecord, ProviderAdapter, RelayTool } from '../types.ts'

const SENTRY_TOOLS = [
    tool('sentry_list_projects', 'List Sentry projects visible to the token.', {
        organizationSlug: { type: 'string', description: 'Optional organization slug.' },
    }),
    tool('sentry_list_project_issues', 'List issues for a Sentry project.', {
        organizationSlug: { type: 'string' },
        projectSlug: { type: 'string' },
        query: { type: 'string' },
        statsPeriod: { type: 'string', description: 'Example: 14d, 24h, 1h.' },
        limit: { type: 'number' },
    }),
    tool('sentry_list_project_events', 'List events for a Sentry project.', {
        organizationSlug: { type: 'string' },
        projectSlug: { type: 'string' },
        query: { type: 'string' },
        limit: { type: 'number' },
    }),
    tool('sentry_get_issue', 'Read one Sentry issue by numeric issue id.', {
        issueId: { type: 'string' },
    }),
    tool('sentry_list_issue_events', 'List events for one Sentry issue.', {
        issueId: { type: 'string' },
        limit: { type: 'number' },
    }),
] as const satisfies readonly RelayTool[]

export function makeSentryAdapter(opts: { apiBaseUrl: string }): ProviderAdapter {
    const apiBase = opts.apiBaseUrl.replace(/\/$/, '')
    return {
        key: 'sentry',
        shape: 'stdio-relay',
        upstreamUrl: apiBase,
        relayTools: SENTRY_TOOLS,

        needsRefresh(record: CredentialRecord | null) {
            return !record?.access.token
        },

        async refresh(current) {
            const token = current?.access.token
            if (!token) {
                throw new Error('sentry: no token; run `broker connect sentry --token ...`')
            }
            return {
                provider: 'sentry',
                access: { token },
                updatedAt: nowMs(),
            }
        },

        authHeaders(record) {
            return { authorization: `Bearer ${record.access.token}` }
        },

        async handleRelayTool({ name, args, record }) {
            const api = makeApi(apiBase, this.authHeaders(record))
            switch (name) {
                case 'sentry_list_projects': {
                    const org = stringArg(args.organizationSlug)
                    return jsonResult(await api.get(org ? `/organizations/${org}/projects/` : '/projects/'))
                }
                case 'sentry_list_project_issues': {
                    const params = new URLSearchParams()
                    if (stringArg(args.query)) params.set('query', stringArg(args.query))
                    if (stringArg(args.statsPeriod)) params.set('statsPeriod', stringArg(args.statsPeriod))
                    params.set('limit', String(clampInt(args.limit, 25, 1, 100)))
                    return jsonResult(
                        await api.get(
                            `/projects/${requireString(args.organizationSlug, 'organizationSlug')}/${requireString(args.projectSlug, 'projectSlug')}/issues/?${params}`
                        )
                    )
                }
                case 'sentry_list_project_events': {
                    const params = new URLSearchParams()
                    if (stringArg(args.query)) params.set('query', stringArg(args.query))
                    params.set('per_page', String(clampInt(args.limit, 10, 1, 50)))
                    return jsonResult(
                        await api.get(
                            `/projects/${requireString(args.organizationSlug, 'organizationSlug')}/${requireString(args.projectSlug, 'projectSlug')}/events/?${params}`
                        )
                    )
                }
                case 'sentry_get_issue':
                    return jsonResult(await api.get(`/issues/${requireString(args.issueId, 'issueId')}/`))
                case 'sentry_list_issue_events': {
                    const params = new URLSearchParams()
                    params.set('per_page', String(clampInt(args.limit, 10, 1, 50)))
                    return jsonResult(
                        await api.get(`/issues/${requireString(args.issueId, 'issueId')}/events/?${params}`)
                    )
                }
                default:
                    throw new Error(`sentry: unsupported tool ${name}`)
            }
        },
    } satisfies ProviderAdapter
}

export async function verifySentryToken(apiBaseUrl: string, token: string): Promise<unknown> {
    const api = makeApi(apiBaseUrl.replace(/\/$/, ''), { authorization: `Bearer ${token}` })
    return api.get('/organizations/')
}

function makeApi(base: string, headers: Record<string, string>) {
    return {
        async get(path: string): Promise<unknown> {
            const res = await fetch(`${base}${path}`, { headers })
            const text = await res.text()
            if (!res.ok) throw new Error(`sentry API failed: HTTP ${res.status} ${text.slice(0, 300)}`)
            return parseJson(text)
        },
    }
}

function tool(name: string, description: string, properties: Record<string, unknown>): RelayTool {
    return {
        name,
        description,
        inputSchema: { type: 'object', properties },
    }
}

function jsonResult(value: unknown) {
    return { content: [{ type: 'text' as const, text: JSON.stringify(value, null, 2) }] }
}

function parseJson(text: string): unknown {
    try {
        return JSON.parse(text)
    } catch {
        return text
    }
}

function stringArg(v: unknown): string {
    return typeof v === 'string' ? v.trim() : ''
}

function requireString(v: unknown, name: string): string {
    const s = stringArg(v)
    if (!s) throw new Error(`missing required argument "${name}"`)
    return encodeURIComponent(s)
}

function clampInt(v: unknown, fallback: number, min: number, max: number): number {
    const n = typeof v === 'number' ? v : Number(v)
    if (!Number.isFinite(n)) return fallback
    return Math.max(min, Math.min(max, Math.floor(n)))
}
