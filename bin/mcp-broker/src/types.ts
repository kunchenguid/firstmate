// Core types for the firstmate MCP auth broker prototype.
//
// This generalizes the Lindy sandbox credential architecture (central pack +
// per-provider refresh semantics + per-harness renderers + localhost auth
// injection) into a standalone, harness-agnostic broker. See ../README.md and
// the report for the mapping back to lndev / the sandbox scripts.

// A single provider's live credential material as held by the broker.
//
// `access` is the material a request needs RIGHT NOW (bearer, bot token, api
// keys). It is the only thing an auth-injecting proxy/relay ever stamps onto an
// upstream request.
//
// `refresh` is the SECRET rotation material. It is held ONLY by the broker and
// is NEVER rendered into any MCP client config — this is the whole point of the
// server-side-refresh design: a rotating (single-use) refresh token copied into
// N shells invalidates itself. Mirrors claudeAuth/index.ts splitting the
// refresh token from the shell-facing access pack.
export type CredentialRecord = {
    provider: string
    access: Record<string, string>
    refresh?: { token: string; model: RefreshTokenModel }
    // epoch ms; when the access material stops working. undefined => unknown /
    // externally-rotated (Slack shape reads a file, so the broker doesn't track
    // expiry itself).
    expiresAt?: number
    updatedAt: number
}

// Copied verbatim from the sandbox harness adapter (harness/types.ts:14). The
// danger of naively distributing rotating refresh tokens is exactly why the
// broker holds them centrally.
export type RefreshTokenModel = 'single-use' | 'reusable' | 'unknown'

// The two representative wire shapes a remote tool can take.
//   http-proxy : remote Streamable-HTTP MCP behind an expiring OAuth bearer.
//                Broker runs a loopback reverse proxy that injects a FRESH
//                bearer per request. (Linear shape.)
//   stdio-relay: the client spawns a local stdio process; that process reads a
//                rotated token per request and calls an upstream API. (Slack
//                shape.)
export type ProviderShape = 'http-proxy' | 'stdio-relay'

export type RelayTool = {
    name: string
    description: string
    inputSchema: Record<string, unknown>
}

export type RelayToolResult = {
    content: Array<{ type: 'text'; text: string }>
    isError?: boolean
}

export type RelayToolCall = {
    name: string
    args: Record<string, unknown>
    record: CredentialRecord
}

// A provider adapter is the one place per-integration behavior lives. Adding a
// provider = adding one of these + registering it. Everything else (store,
// refresher loop, renderers, proxy, relay) is generic.
export type ProviderAdapter = {
    key: string
    shape: ProviderShape
    // For http-proxy: the remote MCP endpoint the proxy forwards to.
    // For stdio-relay: the upstream API base the relay calls.
    upstreamUrl: string

    // True when `access` is missing/expired and refresh() should run before the
    // next request is served.
    needsRefresh(record: CredentialRecord | null): boolean

    // Produce a fresh record. May mint a new access token from a refresh token
    // (Linear), or simply re-read an externally-rotated token file/env (Slack).
    // The broker persists whatever this returns. Returning rotated `refresh`
    // material is how single-use refresh tokens survive.
    refresh(current: CredentialRecord | null): Promise<CredentialRecord>

    // Build the auth material to stamp onto an upstream request from the live
    // access record. Kept separate from the record so the same record can be
    // rendered as an HTTP header (proxy) or an env/arg (relay).
    authHeaders(record: CredentialRecord): Record<string, string>

    // Optional server-side method guard for generic stdio passthrough relays.
    // Slack uses this to keep the long-tail Web API bridge on a known surface.
    allowMethod?: (method: string) => boolean
    allowedMethods?: readonly string[]

    // Optional first-class read tool surface for stdio relays. When omitted,
    // relay.ts exposes the prototype generic `<provider>_call` passthrough.
    relayTools?: readonly RelayTool[]
    handleRelayTool?: (call: RelayToolCall) => Promise<RelayToolResult>
}

// Where a rendered config should point the client. Filled in by the broker
// runtime (proxy port for http-proxy providers, relay path for stdio-relay).
export type RenderEndpoint =
    | { shape: 'http-proxy'; loopbackUrl: string }
    | { shape: 'stdio-relay'; command: string; args: readonly string[] }
