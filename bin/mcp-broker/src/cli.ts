#!/usr/bin/env node
// firstmate MCP auth broker — CLI entrypoint.
//
// Subcommands:
//   connect <provider> [--refresh-token T | --token T]  seed a credential
//   refresh [provider]                                  refresh one/all now
//   status                                              list stored records (redacted)
//   render <claude|codex|pi> [--out PATH]               emit client config (no secrets)
//   proxy <provider>                                    run the loopback auth proxy (http-proxy shape)
//   relay <provider>                                    run the stdio MCP relay (stdio-relay shape)
//   login slack                                         run loopback Slack user OAuth
//   call <provider> <tool> [--args JSON]                 run one broker-authenticated tool call
//   verify <provider>                                   run read-only real-API credential checks
//
// This same binary is what a rendered stdio-relay config spawns
// (`node cli.ts relay slack`), so the relayCmd passed to renderers is this file.

import { randomBytes } from 'node:crypto'
import { readFileSync } from 'node:fs'
import { createServer } from 'node:http'
import { fileURLToPath } from 'node:url'

import { BROKER_HOME, buildRegistry, LINEAR_PROXY_PORT } from './config.ts'
import { verifyDatadog } from './providers/datadog.ts'
import {
    assertNoCredentialMaterial,
    callAdapterTool,
    redactCredentialMaterial,
} from './calls.ts'
import { startAuthProxy } from './proxy.ts'
import { ensureFresh, refreshAll } from './refresher.ts'
import { runStdioRelay } from './relay.ts'
import { renderClaude, renderCodex, renderPi } from './renderers/index.ts'
import { CredentialStore, nowMs } from './store.ts'
import type { ProviderAdapter } from './types.ts'

const SELF = fileURLToPath(import.meta.url)
const RELAY_ENTRY = process.env.BROKER_RELAY_ENTRY ?? SELF

function getArg(flag: string): string | undefined {
    const i = process.argv.indexOf(flag)
    return i !== -1 ? process.argv[i + 1] : undefined
}

function requireAdapter(registry: Map<string, ProviderAdapter>, key: string): ProviderAdapter {
    const a = registry.get(key)
    if (!a) {
        process.stderr.write(
            `unknown provider: ${key}. known: ${[...registry.keys()].join(', ')}\n`
        )
        process.exit(2)
    }
    return a
}

function redact(v: string): string {
    if (/^mongodb(?:\+srv)?:\/\//.test(v)) return '<redacted-mongodb-uri>'
    if (v.length <= 8) return '***'
    return `${v.slice(0, 4)}…${v.slice(-2)}`
}

async function main(): Promise<void> {
    const [cmd, arg] = process.argv.slice(2)
    const store = new CredentialStore(BROKER_HOME)
    const registry = buildRegistry()

    switch (cmd) {
        case 'connect': {
            const adapter = requireAdapter(registry, arg!)
            switch (adapter.key) {
                case 'linear': {
                    const apiKey = getArg('--api-key')
                    const rt = getArg('--refresh-token')
                    if (apiKey) {
                        store.put({
                            provider: adapter.key,
                            access: { apiKey },
                            updatedAt: nowMs(),
                        })
                    } else {
                        if (!rt) throw new Error('connect linear needs --api-key')
                        store.put({
                            provider: adapter.key,
                            access: {},
                            refresh: { token: rt, model: 'single-use' },
                            updatedAt: nowMs(),
                        })
                        await ensureFresh(store, adapter)
                    }
                    break
                }
                case 'slack': {
                    const tok = getArg('--token')
                    if (tok) {
                        store.put({
                            provider: adapter.key,
                            access: { token: tok },
                            updatedAt: nowMs(),
                        })
                    } else {
                        await ensureFresh(store, adapter)
                    }
                    break
                }
                case 'sentry': {
                    const tok = getArg('--token')
                    if (!tok) throw new Error('connect sentry needs --token')
                    store.put({
                        provider: adapter.key,
                        access: { token: tok },
                        updatedAt: nowMs(),
                    })
                    break
                }
                case 'datadog': {
                    const apiKey = getArg('--api-key')
                    const appKey = getArg('--app-key') ?? getArg('--application-key')
                    if (!apiKey || !appKey) {
                        throw new Error('connect datadog needs --api-key and --app-key')
                    }
                    store.put({
                        provider: adapter.key,
                        access: { apiKey, appKey },
                        updatedAt: nowMs(),
                    })
                    break
                }
                case 'mongo': {
                    const uri = getArg('--uri') ?? readUriFromFile(getArg('--uri-file'), getArg('--env-name'))
                    if (!uri) {
                        throw new Error(
                            'connect mongo needs --uri or --uri-file <path> [--env-name PRODUCTION_MONGODB_URI_READONLY]'
                        )
                    }
                    store.put({
                        provider: adapter.key,
                        access: { uri },
                        updatedAt: nowMs(),
                    })
                    break
                }
                default: {
                    const tok = getArg('--token')
                    if (tok) {
                        store.put({
                            provider: adapter.key,
                            access: { token: tok },
                            updatedAt: nowMs(),
                        })
                    } else {
                        await ensureFresh(store, adapter)
                    }
                }
            }
            process.stdout.write(`connected ${adapter.key}\n`)
            break
        }
        case 'login': {
            if (arg !== 'slack') throw new Error('login slack')
            await loginSlack(store)
            break
        }
        case 'refresh': {
            if (arg) await ensureFresh(store, requireAdapter(registry, arg))
            else await refreshAll(store, registry)
            process.stdout.write('refreshed\n')
            break
        }
        case 'status': {
            for (const adapter of registry.values()) {
                const r = store.get(adapter.key)
                if (!r) {
                    process.stdout.write(
                        `${adapter.key.padEnd(8)} (not connected) shape=${adapter.shape}\n`
                    )
                    continue
                }
                const access = Object.entries(r.access)
                    .map(([k, v]) => `${k}=${redact(v)}`)
                    .join(' ')
                const exp = r.expiresAt ? `${Math.round((r.expiresAt - nowMs()) / 1000)}s` : 'n/a'
                const hasRt = r.refresh ? `refresh=${r.refresh.model}` : 'refresh=none'
                process.stdout.write(
                    `${adapter.key.padEnd(8)} shape=${adapter.shape} ${access} expiresIn=${exp} ${hasRt}\n`
                )
            }
            break
        }
        case 'render': {
            const target = arg
            let out: string
            switch (target) {
                case 'claude': {
                    out = JSON.stringify(renderClaude(registry, RELAY_ENTRY, renderEnv()), null, 2)
                    break
                }
                case 'codex': {
                    out = renderCodex(registry, RELAY_ENTRY, renderEnv())
                    break
                }
                case 'pi': {
                    out = JSON.stringify(renderPi(registry, RELAY_ENTRY, renderEnv()), null, 2)
                    break
                }
                default:
                    throw new Error('render <claude|codex|pi>')
            }
            const outPath = getArg('--out')
            if (outPath) {
                const { writeFileSync } = await import('node:fs')
                writeFileSync(outPath, out + '\n', { mode: 0o600 })
                process.stdout.write(`wrote ${target} config -> ${outPath}\n`)
            } else {
                process.stdout.write(out + '\n')
            }
            break
        }
        case 'proxy': {
            const adapter = requireAdapter(registry, arg!)
            if (adapter.shape !== 'http-proxy')
                throw new Error(`${adapter.key} is not an http-proxy provider`)
            await startAuthProxy({
                store,
                adapter,
                port: LINEAR_PROXY_PORT,
                onLog: (msg, meta) =>
                    process.stderr.write(
                        `[proxy:${adapter.key}] ${msg}${meta ? ' ' + JSON.stringify(meta) : ''}\n`
                    ),
            })
            // keep alive
            await new Promise(() => {})
            break
        }
        case 'relay': {
            const adapter = requireAdapter(registry, arg!)
            if (adapter.shape !== 'stdio-relay')
                throw new Error(`${adapter.key} is not a stdio-relay provider`)
            runStdioRelay({ store, adapter })
            break
        }
        case 'call': {
            const provider = arg
            const tool = process.argv[4]
            if (!provider || !tool) throw new Error('call <provider> <tool> [--args <json>]')
            const adapter = requireAdapter(registry, provider)
            const result = await callAdapterTool({
                store,
                adapter,
                tool,
                args: parseArgsJson(getArg('--args')),
            })
            const record = store.get(adapter.key)
            const output = redactCredentialMaterial(result.output, record)
            const json = JSON.stringify(output, null, 2)
            assertNoCredentialMaterial(json, record)
            if (result.isError) {
                throw new Error(
                    `${adapter.key}: tool "${tool}" failed: ${describeCallFailure(output, result.status)}`
                )
            }
            process.stdout.write(json + '\n')
            break
        }
        case 'verify': {
            const adapter = requireAdapter(registry, arg!)
            switch (arg) {
                case 'linear':
                    await verifyLinear(store, adapter)
                    break
                case 'slack':
                    await verifySlack(store, adapter)
                    break
                case 'sentry':
                    await verifySentry(store, adapter)
                    break
                case 'datadog':
                    await verifyDatadogCreds(store, adapter)
                    break
                case 'mongo':
                    await verifyMongo(store, adapter)
                    break
                default:
                    throw new Error('verify <linear|slack|sentry|datadog|mongo>')
            }
            break
        }
        default:
            process.stdout.write(
                'usage: cli.ts <connect|login|refresh|status|render|proxy|relay|call|verify> ...\n'
            )
            process.exit(cmd ? 2 : 0)
    }
}

function parseArgsJson(raw: string | undefined): Record<string, unknown> {
    if (!raw) return {}
    let parsed: unknown
    try {
        parsed = JSON.parse(raw) as unknown
    } catch (error) {
        throw new Error(`--args must be valid JSON: ${(error as Error).message}`)
    }
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
        throw new Error('--args must be a JSON object')
    }
    return parsed as Record<string, unknown>
}

function describeCallFailure(output: unknown, status: number): string {
    if (output && typeof output === 'object') {
        const maybe = output as {
            error?: string | { message?: string; code?: number }
            ok?: boolean
        }
        if (typeof maybe.error === 'string') return `HTTP ${status} ${maybe.error}`
        if (maybe.error && typeof maybe.error === 'object') {
            const code = maybe.error.code === undefined ? '' : `${maybe.error.code} `
            return `HTTP ${status} ${code}${maybe.error.message ?? 'unknown error'}`
        }
        if (maybe.ok === false) return `HTTP ${status} ${JSON.stringify(output)}`
    }
    if (typeof output === 'string') return `HTTP ${status} ${output}`
    return `HTTP ${status} ${JSON.stringify(output)}`
}

function renderEnv(): Record<string, string> {
    const env: Record<string, string> = {}
    for (const key of [
        'BROKER_HOME',
        'BROKER_LINEAR_GRAPHQL_URL',
        'BROKER_SLACK_API_URL',
        'BROKER_SLACK_TOKEN_FILE',
        'BROKER_SENTRY_API_URL',
        'BROKER_DATADOG_API_URL',
        'BROKER_MONGO_MOCK_URL',
        'BROKER_MOCK_BASE',
    ]) {
        if (process.env[key]) env[key] = process.env[key]!
    }
    return env
}

async function verifyLinear(store: CredentialStore, adapter: ProviderAdapter): Promise<void> {
    const record = await ensureFresh(store, adapter)
    const result = await adapter.handleRelayTool!({ name: 'linear_viewer', args: {}, record })
    const body = JSON.parse(result.content[0].text) as {
        viewer?: { id?: string; name?: string; email?: string }
    }
    if (!body.viewer?.id) throw new Error('linear verify failed: viewer missing')
    const viewer = body.viewer
    process.stdout.write(
        `linear viewer ok id=${viewer.id} name=${viewer.name ?? 'unknown'} email=${viewer.email ?? 'unknown'}\n`
    )
}

async function verifySlack(store: CredentialStore, adapter: ProviderAdapter): Promise<void> {
    const record = await ensureFresh(store, adapter)
    const res = await fetch(`${adapter.upstreamUrl}/auth.test`, {
        method: 'POST',
        headers: { 'content-type': 'application/json', ...adapter.authHeaders(record) },
        body: '{}',
    })
    const body = (await res.json()) as {
        ok?: boolean
        team?: string
        team_id?: string
        user?: string
        user_id?: string
        bot_id?: string
        error?: string
    }
    if (!res.ok || !body.ok) {
        throw new Error(`slack auth.test failed: HTTP ${res.status} ${body.error ?? 'unknown'}`)
    }
    process.stdout.write(
        `slack auth.test ok team=${body.team ?? body.team_id ?? 'unknown'} user=${body.user ?? body.user_id ?? body.bot_id ?? 'unknown'}\n`
    )
}

async function verifySentry(store: CredentialStore, adapter: ProviderAdapter): Promise<void> {
    const record = await ensureFresh(store, adapter)
    const res = await fetch(`${adapter.upstreamUrl}/organizations/`, {
        headers: adapter.authHeaders(record),
    })
    const text = await res.text()
    if (!res.ok) throw new Error(`sentry verify failed: HTTP ${res.status} ${text.slice(0, 200)}`)
    const orgs = JSON.parse(text) as Array<{ slug?: string; name?: string }>
    process.stdout.write(`sentry ok organizations=${orgs.length}\n`)
}

async function verifyDatadogCreds(store: CredentialStore, adapter: ProviderAdapter): Promise<void> {
    const record = await ensureFresh(store, adapter)
    const result = await verifyDatadog(adapter.upstreamUrl, adapter.authHeaders(record))
    process.stdout.write(`datadog ok ${JSON.stringify(result)}\n`)
}

async function verifyMongo(store: CredentialStore, adapter: ProviderAdapter): Promise<void> {
    const database = getArg('--database')
    const record = await ensureFresh(store, adapter)
    const result = await adapter.handleRelayTool!({
        name: 'mongo_list_collections',
        args: { database },
        record,
    })
    const parsed = JSON.parse(result.content[0].text) as
        | unknown[]
        | { database?: string; collections?: unknown[] }
    const count = Array.isArray(parsed) ? parsed.length : (parsed.collections?.length ?? 0)
    const dbName = Array.isArray(parsed) ? (database ?? 'default') : (parsed.database ?? database ?? 'default')
    process.stdout.write(`mongo ok database=${dbName} collections=${count}\n`)
}

function readUriFromFile(path: string | undefined, envName: string | undefined): string | undefined {
    if (!path) return undefined
    const raw = readFileSync(path, 'utf8')
    const wanted = envName ?? 'PRODUCTION_MONGODB_URI_READONLY'
    for (const line of raw.split(/\r?\n/)) {
        const trimmed = line.trim()
        if (!trimmed || trimmed.startsWith('#')) continue
        const match = /^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/.exec(trimmed)
        if (match && match[1] === wanted) return unquoteEnv(match[2])
    }
    const direct = raw.trim()
    return direct.startsWith('mongodb://') || direct.startsWith('mongodb+srv://') ? direct : undefined
}

function unquoteEnv(value: string): string {
    const trimmed = value.trim()
    if (
        (trimmed.startsWith('"') && trimmed.endsWith('"')) ||
        (trimmed.startsWith("'") && trimmed.endsWith("'"))
    ) {
        return trimmed.slice(1, -1)
    }
    return trimmed
}

async function loginSlack(store: CredentialStore): Promise<void> {
    const clientId = getArg('--client-id') ?? process.env.BROKER_SLACK_CLIENT_ID
    const clientSecret =
        getArg('--client-secret') ??
        readSecretFile(getArg('--client-secret-file')) ??
        process.env.BROKER_SLACK_CLIENT_SECRET
    if (!clientId || !clientSecret) {
        throw new Error(
            'login slack needs --client-id and --client-secret-file (or BROKER_SLACK_CLIENT_ID/BROKER_SLACK_CLIENT_SECRET)'
        )
    }
    const port = Number(getArg('--port') ?? 18765)
    const redirectUri =
        getArg('--redirect-uri') ?? `http://127.0.0.1:${port}/slack/oauth/callback`
    const state = randomBytes(24).toString('hex')
    const scopes =
        getArg('--user-scope') ??
        [
            'team:read',
            'channels:read',
            'groups:read',
            'im:read',
            'mpim:read',
            'channels:history',
            'groups:history',
            'im:history',
            'mpim:history',
            'users:read',
            'users:read.email',
            'reactions:read',
            'search:read.public',
            'search:read.private',
            'search:read.files',
            'search:read.users',
        ].join(',')
    const authorize = new URL('https://slack.com/oauth/v2/authorize')
    authorize.searchParams.set('client_id', clientId)
    authorize.searchParams.set('user_scope', scopes)
    authorize.searchParams.set('redirect_uri', redirectUri)
    authorize.searchParams.set('state', state)

    process.stdout.write(`Open this Slack OAuth URL and approve the app:\n${authorize.href}\n`)
    process.stdout.write(`Waiting for callback on ${redirectUri}\n`)

    const code = await waitForOAuthCallback(port, redirectUri, state)
    const token = await exchangeSlackCode(clientId, clientSecret, code, redirectUri)
    store.put(token)
    process.stdout.write('connected slack via OAuth\n')
}

function readSecretFile(path: string | undefined): string | undefined {
    return path ? readFileSync(path, 'utf8').trim() : undefined
}

function waitForOAuthCallback(port: number, redirectUri: string, state: string): Promise<string> {
    const expectedPath = new URL(redirectUri).pathname
    return new Promise((resolve, reject) => {
        const server = createServer((req, res) => {
            const url = new URL(req.url ?? '/', `http://127.0.0.1:${port}`)
            if (url.pathname !== expectedPath) {
                res.writeHead(404)
                res.end('not found')
                return
            }
            const gotState = url.searchParams.get('state')
            const code = url.searchParams.get('code')
            const error = url.searchParams.get('error')
            if (error || gotState !== state || !code) {
                res.writeHead(400, { 'content-type': 'text/plain' })
                res.end('Slack OAuth failed. Return to firstmate for details.')
                server.close()
                reject(new Error(`slack OAuth callback failed: ${error ?? 'state/code mismatch'}`))
                return
            }
            res.writeHead(200, { 'content-type': 'text/plain' })
            res.end('Slack OAuth connected. You can close this tab.')
            server.close()
            resolve(code)
        })
        server.on('error', reject)
        server.listen(port, '127.0.0.1')
    })
}

async function exchangeSlackCode(
    clientId: string,
    clientSecret: string,
    code: string,
    redirectUri: string
) {
    const form = new URLSearchParams({
        client_id: clientId,
        client_secret: clientSecret,
        code,
        redirect_uri: redirectUri,
    })
    const res = await fetch('https://slack.com/api/oauth.v2.access', {
        method: 'POST',
        headers: { 'content-type': 'application/x-www-form-urlencoded' },
        body: form.toString(),
    })
    const body = (await res.json()) as {
        ok?: boolean
        error?: string
        access_token?: string
        refresh_token?: string
        expires_in?: number
        authed_user?: {
            access_token?: string
            refresh_token?: string
            expires_in?: number
        }
    }
    if (!res.ok || !body.ok) {
        throw new Error(`slack OAuth exchange failed: HTTP ${res.status} ${body.error ?? 'unknown'}`)
    }
    const accessToken = body.authed_user?.access_token ?? body.access_token
    const refreshToken = body.authed_user?.refresh_token ?? body.refresh_token
    if (!accessToken) throw new Error('slack OAuth response did not include a user access token')
    return {
        provider: 'slack',
        access: refreshToken
            ? { token: accessToken, clientId, clientSecret }
            : { token: accessToken },
        refresh: refreshToken ? { token: refreshToken, model: 'single-use' as const } : undefined,
        expiresAt: refreshToken
            ? nowMs() + (body.authed_user?.expires_in ?? body.expires_in ?? 43_200) * 1000
            : undefined,
        updatedAt: nowMs(),
    }
}

main().catch((error) => {
    process.stderr.write(`error: ${(error as Error).message}\n`)
    process.exit(1)
})
