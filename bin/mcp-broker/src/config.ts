// Broker runtime config + provider registry. All endpoints default to mock
// upstreams (see ../mock/upstream.ts) but are env-overridable so the SAME code
// points at real Linear/Slack when credentials exist.

import { homedir } from 'node:os'
import { join } from 'node:path'

import { makeDatadogAdapter } from './providers/datadog.ts'
import { makeLinearAdapter } from './providers/linear.ts'
import { makeMongoAdapter } from './providers/mongo.ts'
import { makeSentryAdapter } from './providers/sentry.ts'
import { makeSlackAdapter } from './providers/slack.ts'
import type { ProviderAdapter } from './types.ts'

// Broker home: where the store + rendered configs live. Kept under the
// prototype dir / an explicit env so we never touch ~/.claude, ~/.codex, ~/.pi.
export const BROKER_HOME = process.env.BROKER_HOME ?? join(process.cwd(), '.broker-home')

// Loopback port the Linear http-proxy listens on. Client config points here.
export const LINEAR_PROXY_PORT = Number(process.env.BROKER_LINEAR_PROXY_PORT ?? 8791)
export const LINEAR_GRAPHQL_URL =
    process.env.BROKER_LINEAR_GRAPHQL_URL ?? 'https://api.linear.app/graphql'
export const SENTRY_API_URL = process.env.BROKER_SENTRY_API_URL ?? 'https://sentry.io/api/0'
export const DATADOG_API_URL = process.env.BROKER_DATADOG_API_URL ?? 'https://api.datadoghq.com/api'

// Mock upstream endpoints are opt-in. Production defaults point at real APIs.
const MOCK_BASE = process.env.BROKER_MOCK_BASE

export function buildRegistry(): Map<string, ProviderAdapter> {
    const linear = makeLinearAdapter({
        graphqlUrl:
            process.env.BROKER_LINEAR_GRAPHQL_URL ??
            (MOCK_BASE ? `${MOCK_BASE}/linear/graphql` : LINEAR_GRAPHQL_URL),
        tokenUrl:
            process.env.BROKER_LINEAR_TOKEN_URL ??
            (MOCK_BASE ? `${MOCK_BASE}/oauth/token` : 'https://linear.app/oauth/token'),
    })
    const slack = makeSlackAdapter({
        apiBaseUrl:
            process.env.BROKER_SLACK_API_URL ??
            (MOCK_BASE ? `${MOCK_BASE}/slack/api` : 'https://slack.com/api'),
        tokenFile: process.env.BROKER_SLACK_TOKEN_FILE,
        envVar: 'SLACK_TOKEN',
    })
    const sentry = makeSentryAdapter({
        apiBaseUrl:
            process.env.BROKER_SENTRY_API_URL ??
            (MOCK_BASE ? `${MOCK_BASE}/sentry/api/0` : SENTRY_API_URL),
    })
    const datadog = makeDatadogAdapter({
        apiBaseUrl:
            process.env.BROKER_DATADOG_API_URL ??
            (MOCK_BASE ? `${MOCK_BASE}/datadog/api` : DATADOG_API_URL),
    })
    const mongo = makeMongoAdapter({
        mockUrl: process.env.BROKER_MONGO_MOCK_URL,
    })
    return new Map([
        [linear.key, linear],
        [slack.key, slack],
        [sentry.key, sentry],
        [datadog.key, datadog],
        [mongo.key, mongo],
    ])
}
