// Generic localhost auth-injecting reverse proxy for `http-proxy`-shape
// providers. Directly generalizes lindy-linear-mcp-proxy.js: not hardcoded to
// Linear — the adapter supplies the upstream URL, the refresh semantics, and
// the header material.
//
// Per request it: (1) ensures the store's token is fresh (refreshing via the
// adapter if within the expiry margin), (2) forwards to the upstream with the
// injected Authorization header, (3) strips WWW-Authenticate so a transient 401
// stays a plain retriable failure instead of latching the MCP client into RFC
// 9728 OAuth-discovery against the loopback URL.

import http from 'node:http'
import https from 'node:https'

import { ensureFresh } from './refresher.ts'
import type { CredentialStore } from './store.ts'
import type { ProviderAdapter } from './types.ts'

const STRIP_REQUEST_HEADERS = new Set([
    'host',
    'authorization',
    'connection',
    'keep-alive',
    'proxy-authenticate',
    'proxy-authorization',
    'te',
    'trailer',
    'transfer-encoding',
    'upgrade',
])

export function startAuthProxy(opts: {
    store: CredentialStore
    adapter: ProviderAdapter
    port: number
    onLog?: (msg: string, meta?: Record<string, unknown>) => void
}): Promise<http.Server> {
    const { store, adapter, port } = opts
    const upstream = new URL(adapter.upstreamUrl)
    const client = upstream.protocol === 'https:' ? https : http
    const log = opts.onLog ?? (() => {})

    const server = http.createServer((clientReq, clientRes) => {
        // Fresh token per request — the entire reason this proxy exists.
        void (async () => {
            let headers: Record<string, string>
            try {
                const record = await ensureFresh(store, adapter)
                headers = adapter.authHeaders(record)
            } catch (error) {
                log('no fresh token; refusing request', { error: (error as Error).message })
                sendError(clientRes, 503, `${adapter.key}-proxy-no-token`)
                return
            }

            const forwardHeaders: Record<string, string | string[]> = {}
            for (const [name, value] of Object.entries(clientReq.headers)) {
                if (!STRIP_REQUEST_HEADERS.has(name.toLowerCase()) && value !== undefined) {
                    forwardHeaders[name] = value
                }
            }
            forwardHeaders.host = upstream.host
            for (const [k, v] of Object.entries(headers)) forwardHeaders[k] = v

            const upstreamReq = client.request(
                {
                    protocol: upstream.protocol,
                    hostname: upstream.hostname,
                    port: upstream.port || (upstream.protocol === 'https:' ? 443 : 80),
                    // Single-endpoint MCP: always hit the upstream's own path.
                    path: upstream.pathname + upstream.search,
                    method: clientReq.method,
                    headers: forwardHeaders,
                },
                (upstreamRes) => {
                    const outHeaders = { ...upstreamRes.headers }
                    // See lindy-linear-mcp-proxy.js: forwarding this challenge
                    // sends the client into protected-resource discovery that
                    // can never match the loopback URL -> unrecoverable.
                    if (outHeaders['www-authenticate'] !== undefined) {
                        delete outHeaders['www-authenticate']
                        log('stripped upstream WWW-Authenticate', {
                            status: upstreamRes.statusCode,
                        })
                    }
                    clientRes.writeHead(upstreamRes.statusCode ?? 502, outHeaders)
                    upstreamRes.pipe(clientRes)
                }
            )
            upstreamReq.on('error', (error) => {
                log('upstream request failed', { error: String(error) })
                sendError(clientRes, 502, `${adapter.key}-proxy-upstream-error`)
            })
            clientReq.pipe(upstreamReq)
            clientReq.on('error', () => upstreamReq.destroy())
        })()
    })

    return new Promise((resolve, reject) => {
        server.on('error', reject)
        server.listen(port, '127.0.0.1', () => {
            log('listening', { port, upstream: upstream.href, provider: adapter.key })
            resolve(server)
        })
    })
}

function sendError(res: http.ServerResponse, status: number, code: string): void {
    if (!res.headersSent) res.writeHead(status, { 'content-type': 'application/json' })
    res.end(JSON.stringify({ error: code }))
}
