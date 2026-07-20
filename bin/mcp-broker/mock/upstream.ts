// Mock upstreams for the demo — stand in for real Linear/Slack when no real
// credentials are discoverable locally (they aren't; the Linear/Slack MCPs in
// this environment are claude.ai-managed OAuth, not a bearer we can extract).
//
// Simulates the two hard properties the broker exists to handle:
//   1. Linear MCP: bearer tokens EXPIRE. The MCP endpoint 401s an expired/wrong
//      bearer WITH a WWW-Authenticate challenge (the thing the proxy strips).
//   2. OAuth token endpoint: exchanging a refresh token issues a short-lived
//      access token AND ROTATES the refresh token (single-use) — invalidating
//      the old one, exactly the failure mode that forces server-side refresh.
//   3. Slack Web API: 401s a wrong/rotated bot token; accepts the current one.

import http from 'node:http'

const PORT = Number(process.env.BROKER_MOCK_PORT ?? 8790)
// How long a freshly-minted Linear access token lives (short, to demo refresh).
const ACCESS_TTL_MS = Number(process.env.BROKER_MOCK_ACCESS_TTL_MS ?? 3000)

type Issued = { expiresAt: number }
// Live Linear access tokens the mock has issued -> their expiry.
const linearAccess = new Map<string, Issued>()
// Valid (unused) Linear refresh tokens. Single-use: consuming one invalidates it.
const linearRefresh = new Set<string>(['seed-refresh-token-0'])
let refreshCounter = 0
let accessCounter = 0

// The Slack bot token the mock currently accepts. An external rotator (the demo)
// flips this and writes the new value to the broker's token file.
let slackBotToken = process.env.BROKER_MOCK_SLACK_TOKEN ?? 'xoxb-mock-0'
export function setSlackBotToken(t: string): void {
    slackBotToken = t
}

function readBody(req: http.IncomingMessage): Promise<string> {
    return new Promise((resolve) => {
        let b = ''
        req.on('data', (c) => (b += c))
        req.on('end', () => resolve(b))
    })
}

function bearer(req: http.IncomingMessage): string | null {
    const h = req.headers.authorization
    if (!h || Array.isArray(h)) return null
    const m = /^Bearer (.+)$/.exec(h)
    return m ? m[1] : null
}

function authHeader(req: http.IncomingMessage): string {
    const h = req.headers.authorization
    return typeof h === 'string' ? h : ''
}

export function startMockUpstream(): Promise<http.Server> {
    const server = http.createServer(async (req, res) => {
        const url = new URL(req.url ?? '/', `http://127.0.0.1:${PORT}`)

        // --- OAuth token endpoint: refresh_token grant, rotates refresh token ---
        if (url.pathname === '/oauth/token' && req.method === 'POST') {
            const body = JSON.parse((await readBody(req)) || '{}') as { refresh_token?: string }
            const rt = body.refresh_token ?? ''
            if (!linearRefresh.has(rt)) {
                res.writeHead(400, { 'content-type': 'application/json' })
                res.end(
                    JSON.stringify({
                        error: 'invalid_grant',
                        detail: 'refresh token unknown or already used',
                    })
                )
                return
            }
            linearRefresh.delete(rt) // single-use
            const access = `linear-access-${accessCounter++}`
            const newRefresh = `rotated-refresh-token-${++refreshCounter}`
            linearAccess.set(access, { expiresAt: Date.now() + ACCESS_TTL_MS })
            linearRefresh.add(newRefresh)
            res.writeHead(200, { 'content-type': 'application/json' })
            res.end(
                JSON.stringify({
                    access_token: access,
                    expires_in: Math.round(ACCESS_TTL_MS / 1000),
                    refresh_token: newRefresh,
                })
            )
            return
        }

        // --- Linear remote MCP (Streamable-HTTP JSON-RPC) requiring a bearer ---
        if (url.pathname === '/linear/mcp' && req.method === 'POST') {
            const tok = bearer(req)
            const issued = tok ? linearAccess.get(tok) : undefined
            if (!issued || issued.expiresAt < Date.now()) {
                // Real Linear MCP sends this challenge — the proxy MUST strip it.
                res.writeHead(401, {
                    'content-type': 'application/json',
                    'www-authenticate':
                        'Bearer resource_metadata="https://mcp.linear.app/.well-known/oauth-protected-resource"',
                })
                res.end(
                    JSON.stringify({
                        jsonrpc: '2.0',
                        error: { code: -32_001, message: 'unauthorized' },
                    })
                )
                return
            }
            const rpc = JSON.parse((await readBody(req)) || '{}') as {
                id?: number
                method?: string
                params?: {
                    name?: string
                    arguments?: { query?: string }
                }
            }
            if (rpc.method === 'tools/call') {
                const tool = rpc.params?.name ?? ''
                let result: unknown
                if (tool === 'linear_viewer') {
                    result = {
                        id: 'mock-viewer-1',
                        name: 'Mock Viewer',
                        servedWithToken: tok,
                    }
                } else if (tool === 'linear_search_issues') {
                    result = {
                        issues: [
                            {
                                id: 'LIN-1',
                                title: `Mock issue for ${rpc.params?.arguments?.query ?? 'all'}`,
                            },
                        ],
                        servedWithToken: tok,
                    }
                } else {
                    res.writeHead(200, {
                        'content-type': 'application/json',
                        'mcp-session-id': 'mock-session-1',
                    })
                    res.end(
                        JSON.stringify({
                            jsonrpc: '2.0',
                            id: rpc.id ?? 1,
                            error: { code: -32_601, message: `unknown tool: ${tool}` },
                        })
                    )
                    return
                }
                res.writeHead(200, {
                    'content-type': 'application/json',
                    'mcp-session-id': 'mock-session-1',
                })
                res.end(JSON.stringify({ jsonrpc: '2.0', id: rpc.id ?? 1, result }))
                return
            }
            res.writeHead(200, {
                'content-type': 'application/json',
                'mcp-session-id': 'mock-session-1',
            })
            res.end(
                JSON.stringify({
                    jsonrpc: '2.0',
                    id: rpc.id ?? 1,
                    result: { ok: true, echo: rpc.method ?? null, servedWithToken: tok },
                })
            )
            return
        }

        // --- Linear GraphQL API accepting personal API keys ---
        if (url.pathname === '/linear/graphql' && req.method === 'POST') {
            const authorization = authHeader(req)
            if (authorization !== 'lin_api_mock' && !linearAccess.has(bearer(req) ?? '')) {
                res.writeHead(401, { 'content-type': 'application/json' })
                res.end(JSON.stringify({ errors: [{ message: 'invalid_token' }] }))
                return
            }
            const rpc = JSON.parse((await readBody(req)) || '{}') as { query?: string; variables?: Record<string, unknown> }
            const query = rpc.query ?? ''
            const variables = rpc.variables ?? {}
            const input = (variables.input ?? {}) as Record<string, unknown>
            let data: unknown
            if (query.includes('issueUpdate')) {
                const stateId = String(input.stateId ?? 'state-todo')
                const isCanceled = stateId === 'state-canceled'
                data = {
                    issueUpdate: {
                        success: true,
                        issue: {
                            id: variables.id ?? 'issue-1',
                            identifier: 'ENG-1',
                            title: 'Mock issue',
                            url: 'https://linear.app/lindy/issue/ENG-1/mock',
                            updatedAt: '2026-07-08T12:00:00.000Z',
                            canceledAt: isCanceled ? '2026-07-08T12:00:00.000Z' : null,
                            state: {
                                id: stateId,
                                name: isCanceled ? 'Canceled' : 'In Progress',
                                type: isCanceled ? 'canceled' : 'started',
                            },
                            team: {
                                id: input.teamId ?? 'team-1',
                                key: input.teamId === 'team-2' ? 'OPS' : 'ENG',
                                name: input.teamId === 'team-2' ? 'Operations' : 'Engineering',
                            },
                            project: input.projectId ? { id: input.projectId, name: 'Mock project' } : null,
                            assignee: input.assigneeId
                                ? { id: input.assigneeId, name: 'Mock assignee', email: 'assignee@example.com' }
                                : null,
                            labels: {
                                nodes: [
                                    ...((input.addedLabelIds as string[] | undefined) ?? []).map((id) => ({
                                        id,
                                        name: `Label ${id}`,
                                        color: '#00ff00',
                                    })),
                                ],
                            },
                        },
                    },
                }
            } else if (query.includes('commentCreate')) {
                data = {
                    commentCreate: {
                        success: true,
                        comment: {
                            id: 'comment-write-1',
                            body: input.body ?? '',
                            createdAt: '2026-07-08T12:00:00.000Z',
                            updatedAt: '2026-07-08T12:00:00.000Z',
                            issue: {
                                id: input.issueId ?? 'issue-1',
                                identifier: 'ENG-1',
                                title: 'Mock issue',
                                url: 'https://linear.app/lindy/issue/ENG-1/mock',
                            },
                            user: { id: 'viewer-1', name: 'Tim', email: 'tim@lindy.ai' },
                        },
                    },
                }
            } else if (query.includes('attachmentLinkURL')) {
                data = {
                    attachmentLinkURL: {
                        success: true,
                        attachment: {
                            id: 'attachment-1',
                            title: variables.title ?? 'Pull request',
                            url: variables.url,
                            issue: {
                                id: variables.issueId ?? 'issue-1',
                                identifier: 'ENG-1',
                                title: 'Mock issue',
                                url: 'https://linear.app/lindy/issue/ENG-1/mock',
                            },
                        },
                    },
                }
            } else if (query.includes('IssueCancellationState')) {
                data = {
                    issue: {
                        id: variables.id ?? 'issue-1',
                        identifier: 'ENG-1',
                        title: 'Mock issue',
                        team: {
                            id: 'team-1',
                            key: 'ENG',
                            name: 'Engineering',
                            states: {
                                nodes: [
                                    { id: 'state-todo', name: 'Todo', type: 'unstarted' },
                                    { id: 'state-canceled', name: 'Canceled', type: 'canceled' },
                                ],
                            },
                        },
                    },
                }
            } else if (query.includes('viewer')) {
                data = { viewer: { id: 'viewer-1', name: 'Tim', email: 'tim@lindy.ai' } }
            } else if (query.includes('teams')) {
                data = { teams: { nodes: [{ id: 'team-1', key: 'ENG', name: 'Engineering' }] } }
            } else if (query.includes('comments')) {
                data = {
                    issue: {
                        id: rpc.variables?.id ?? 'issue-1',
                        identifier: 'ENG-1',
                        title: 'Mock issue',
                        comments: { nodes: [{ id: 'comment-1', body: 'read-only comment', user: { name: 'Tim' } }] },
                    },
                }
            } else if (query.includes('issue(')) {
                data = {
                    issue: {
                        id: rpc.variables?.id ?? 'issue-1',
                        identifier: 'ENG-1',
                        title: 'Mock issue',
                        url: 'https://linear.app/lindy/issue/ENG-1/mock',
                        state: { name: 'Todo' },
                        team: { key: 'ENG', name: 'Engineering' },
                    },
                }
            } else {
                data = {
                    issues: {
                        nodes: [
                            {
                                id: 'issue-1',
                                identifier: 'ENG-1',
                                title: 'Mock issue',
                                url: 'https://linear.app/lindy/issue/ENG-1/mock',
                                state: { name: 'Todo' },
                                team: { key: 'ENG', name: 'Engineering' },
                            },
                        ],
                    },
                }
            }
            res.writeHead(200, { 'content-type': 'application/json' })
            res.end(JSON.stringify({ data }))
            return
        }

        // --- Slack Web API: 401 wrong token, else ok ---
        if (url.pathname.startsWith('/slack/api/') && req.method === 'POST') {
            const tok = bearer(req)
            if (tok !== slackBotToken) {
                res.writeHead(401, { 'content-type': 'application/json' })
                res.end(JSON.stringify({ ok: false, error: 'invalid_auth' }))
                return
            }
            const method = url.pathname.replace('/slack/api/', '')
            res.writeHead(200, { 'content-type': 'application/json' })
            res.end(JSON.stringify({ ok: true, method, servedWithToken: tok }))
            return
        }

        // --- Sentry API ---
        if (url.pathname.startsWith('/sentry/api/0/') && req.method === 'GET') {
            if (authHeader(req) !== 'Bearer sentry_mock') {
                res.writeHead(401, { 'content-type': 'application/json' })
                res.end(JSON.stringify({ detail: 'Invalid token' }))
                return
            }
            res.writeHead(200, { 'content-type': 'application/json' })
            if (url.pathname === '/sentry/api/0/organizations/') {
                res.end(JSON.stringify([{ slug: 'lindy', name: 'Lindy' }]))
            } else if (url.pathname === '/sentry/api/0/projects/') {
                res.end(JSON.stringify([{ slug: 'web', name: 'web', organization: { slug: 'lindy' } }]))
            } else if (url.pathname.endsWith('/issues/')) {
                res.end(JSON.stringify([{ id: '100', title: 'Mock issue', shortId: 'WEB-1' }]))
            } else if (url.pathname.endsWith('/events/')) {
                res.end(JSON.stringify([{ id: 'event-1', title: 'Mock event' }]))
            } else if (url.pathname.includes('/issues/100/')) {
                res.end(JSON.stringify({ id: '100', title: 'Mock issue', status: 'unresolved' }))
            } else {
                res.end(JSON.stringify({ ok: true, path: url.pathname }))
            }
            return
        }

        // --- Datadog API ---
        if (url.pathname.startsWith('/datadog/api/')) {
            if (req.headers['dd-api-key'] !== 'dd_api_mock' || req.headers['dd-application-key'] !== 'dd_app_mock') {
                res.writeHead(403, { 'content-type': 'application/json' })
                res.end(JSON.stringify({ errors: ['Forbidden'] }))
                return
            }
            res.writeHead(200, { 'content-type': 'application/json' })
            if (url.pathname === '/datadog/api/v1/validate') {
                res.end(JSON.stringify({ valid: true }))
            } else if (url.pathname === '/datadog/api/v2/current_user') {
                res.end(JSON.stringify({ data: { id: 'user-1', attributes: { email: 'tim@lindy.ai' } } }))
            } else if (url.pathname === '/datadog/api/v1/monitor') {
                res.end(JSON.stringify([{ id: 42, name: 'mock monitor' }]))
            } else if (url.pathname === '/datadog/api/v1/monitor/42') {
                res.end(JSON.stringify({ id: 42, name: 'mock monitor' }))
            } else if (url.pathname === '/datadog/api/v1/query') {
                res.end(JSON.stringify({ status: 'ok', series: [] }))
            } else if (url.pathname === '/datadog/api/v2/logs/events/search') {
                res.end(JSON.stringify({ data: [] }))
            } else if (url.pathname === '/datadog/api/v1/events') {
                res.end(JSON.stringify({ events: [] }))
            } else {
                res.end(JSON.stringify({ ok: true, path: url.pathname }))
            }
            return
        }

        // --- Mongo read-only mock used by the broker's internal relay tests ---
        if (url.pathname.startsWith('/mongo/') && req.method === 'POST') {
            const op = JSON.parse((await readBody(req)) || '{}') as { kind?: string; collection?: string }
            res.writeHead(200, { 'content-type': 'application/json' })
            if (op.kind === 'listCollections') {
                res.end(JSON.stringify({ database: 'prod', collections: [{ name: 'users' }, { name: 'organizations' }] }))
            } else if (op.kind === 'find') {
                res.end(JSON.stringify({ database: 'prod', collection: op.collection, count: 1, documents: [{ _id: 'mock-id' }] }))
            } else if (op.kind === 'aggregate') {
                res.end(JSON.stringify({ database: 'prod', collection: op.collection, count: 1, documents: [{ count: 7 }] }))
            } else {
                res.end(JSON.stringify({ error: 'unknown op' }))
            }
            return
        }

        res.writeHead(404, { 'content-type': 'application/json' })
        res.end(JSON.stringify({ error: 'not_found', path: url.pathname }))
    })

    return new Promise((resolve) => {
        server.listen(PORT, '127.0.0.1', () => resolve(server))
    })
}

// Allow running standalone: `node mock/upstream.ts`
if (process.argv[1] && process.argv[1].endsWith('upstream.ts')) {
    void startMockUpstream().then(() => process.stdout.write(`mock upstream on :${PORT}\n`))
}
