// Slack adapter — SHAPE 2: stdio relay that reads a rotated token per request.
//
// Generalizes packages/agent-sandbox-image/scripts/lindy-slack-relay.js: the
// client spawns a local stdio MCP process with NO token in its config; the
// process reads the current Slack token from the store/file on every tool call,
// so a rotation takes effect with zero restart. The sandbox itself never holds
// a long-lived Slack bot token — here the broker store plays the role the
// cred-puller's rotated token file plays there.
//
// `connect slack --token` stores a static user/bot token. `login slack` stores
// firstmate-owned OAuth material and, when Slack token rotation is enabled,
// refreshes the single-use refresh token chain here.

import { readFileSync } from 'node:fs'

import { nowMs } from '../store.ts'
import type { CredentialRecord, ProviderAdapter } from '../types.ts'

export const SLACK_ALLOWED_METHODS = [
    'auth.test',
    'team.info',
    'users.info',
    'users.lookupByEmail',
    'users.list',
    'conversations.info',
    'conversations.list',
    'conversations.members',
    'conversations.history',
    'conversations.replies',
    'reactions.get',
    'reactions.add',
    'chat.postMessage',
    'chat.update',
    'search.messages',
    'search.files',
    'search.all',
] as const

const TOKEN_REFRESH_MARGIN_MS = 5 * 60_000

export function makeSlackAdapter(opts: {
    // Upstream Slack (Web API) base the relay calls.
    apiBaseUrl: string
    // Optional external file the bot token is rotated into (mirrors the
    // cred-puller writing ~/.lindy/...token). If set, refresh() re-reads it.
    tokenFile?: string
    // Optional env var fallback. Historical configs used SLACK_BOT_TOKEN; the
    // broker now treats Slack credentials as general user-or-bot tokens.
    envVar?: string
}): ProviderAdapter {
    function readExternalToken(): string | null {
        if (opts.tokenFile) {
            try {
                const raw = readFileSync(opts.tokenFile, 'utf8').trim()
                if (raw) return raw
            } catch {
                // fall through to env
            }
        }
        if (opts.envVar && process.env[opts.envVar]) return process.env[opts.envVar]!.trim()
        if (process.env.SLACK_BOT_TOKEN) return process.env.SLACK_BOT_TOKEN.trim()
        return null
    }

    return {
        key: 'slack',
        shape: 'stdio-relay',
        upstreamUrl: opts.apiBaseUrl,
        allowedMethods: SLACK_ALLOWED_METHODS,

        needsRefresh(record) {
            // If the external source has a token that differs from what's
            // stored, pull it in. Otherwise only refresh when we have nothing.
            const external = readExternalToken()
            const currentToken = slackToken(record)
            if (!record || !currentToken) return true
            if (external !== null && external !== currentToken) return true
            if (record.refresh?.token && record.expiresAt !== undefined) {
                return record.expiresAt - nowMs() <= TOKEN_REFRESH_MARGIN_MS
            }
            return false
        },

        async refresh(current) {
            const external = readExternalToken()
            if (external) {
                return {
                    provider: 'slack',
                    access: { token: external },
                    expiresAt: undefined,
                    updatedAt: nowMs(),
                }
            }
            if (current?.refresh?.token && current.expiresAt !== undefined) {
                return refreshSlackOAuth(opts.apiBaseUrl, current)
            }
            const token = slackToken(current)
            if (!token) {
                throw new Error(
                    'slack: no token in file or env; run `broker connect slack --token ...` or `broker login slack`'
                )
            }
            return {
                provider: 'slack',
                access: { token },
                expiresAt: undefined,
                updatedAt: nowMs(),
            }
        },

        authHeaders(record) {
            const token = slackToken(record)
            if (!token) throw new Error('slack: missing token')
            return { authorization: `Bearer ${token}` }
        },

        allowMethod(method) {
            return (SLACK_ALLOWED_METHODS as readonly string[]).includes(method)
        },
    } satisfies ProviderAdapter
}

function slackToken(record: CredentialRecord | null | undefined): string {
    return record?.access.token ?? record?.access.botToken ?? ''
}

async function refreshSlackOAuth(apiBaseUrl: string, current: CredentialRecord): Promise<CredentialRecord> {
    const clientId = current.access.clientId ?? process.env.BROKER_SLACK_CLIENT_ID
    const clientSecret = current.access.clientSecret ?? process.env.BROKER_SLACK_CLIENT_SECRET
    if (!clientId || !clientSecret) {
        throw new Error('slack: rotated token needs client id/secret from broker store or env')
    }
    const form = new URLSearchParams({
        grant_type: 'refresh_token',
        refresh_token: current.refresh!.token,
        client_id: clientId,
        client_secret: clientSecret,
    })
    const res = await fetch(`${apiBaseUrl.replace(/\/$/, '')}/oauth.v2.access`, {
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
        throw new Error(`slack OAuth refresh failed: HTTP ${res.status} ${body.error ?? 'unknown'}`)
    }
    const accessToken = body.authed_user?.access_token ?? body.access_token
    const refreshToken = body.authed_user?.refresh_token ?? body.refresh_token
    if (!accessToken) throw new Error('slack OAuth refresh response did not include an access token')
    return {
        provider: 'slack',
        access: { token: accessToken, clientId, clientSecret },
        refresh: refreshToken ? { token: refreshToken, model: 'single-use' } : current.refresh,
        expiresAt: nowMs() + (body.authed_user?.expires_in ?? body.expires_in ?? 43_200) * 1000,
        updatedAt: nowMs(),
    }
}
