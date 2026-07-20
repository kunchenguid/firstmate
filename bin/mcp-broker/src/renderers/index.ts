// Config renderers — the "per-harness config rendering" primitive. Given the
// registry + broker runtime endpoints, emit ready-to-use MCP client config for
// each harness. CRITICAL invariant: NO secret ever appears in rendered output.
//   - http-proxy providers render a loopback URL with no Authorization header.
//   - stdio-relay providers render a spawn line (command+args) with no token.
// The bearer/bot-token lives only in the store; the proxy/relay inject it.
//
// Generalizes lindy-mcp-overlay.sh (which rendered Claude .claude.json +
// Codex config.toml) — but the sandbox version baked bearers into the config;
// this broker deliberately does not, pushing every provider through loopback.

import { LINEAR_PROXY_PORT } from '../config.ts'
import type { ProviderAdapter, RenderEndpoint } from '../types.ts'

// Resolve where a client should point for a given provider.
export function endpointFor(adapter: ProviderAdapter, relayCmd: string): RenderEndpoint {
    if (adapter.shape === 'http-proxy') {
        return { shape: 'http-proxy', loopbackUrl: `http://127.0.0.1:${LINEAR_PROXY_PORT}/mcp` }
    }
    // stdio-relay: spawn `node <relay-entry> relay <provider>`.
    if (!relayCmd.endsWith('.ts')) {
        return {
            shape: 'stdio-relay',
            command: relayCmd,
            args: ['relay', adapter.key],
        }
    }
    return {
        shape: 'stdio-relay',
        command: 'node',
        args: [relayCmd, 'relay', adapter.key],
    }
}

// Claude Code `.mcp.json` shape: { mcpServers: { <name>: {...} } }
export function renderClaude(
    registry: Map<string, ProviderAdapter>,
    relayCmd: string,
    relayEnv: Record<string, string> = {}
): { mcpServers: Record<string, unknown> } {
    const mcpServers: Record<string, unknown> = {}
    for (const adapter of registry.values()) {
        const ep = endpointFor(adapter, relayCmd)
        mcpServers[adapter.key] =
            ep.shape === 'http-proxy'
                ? { type: 'http', url: ep.loopbackUrl }
                : { type: 'stdio', command: ep.command, args: ep.args, env: relayEnv }
    }
    return { mcpServers }
}

// Codex `config.toml` shape: [mcp_servers.<name>] blocks. HTTP servers need
// `experimental_use_rmcp_client=true` for streamable HTTP (per the project's
// .codex/config.toml note).
export function renderCodex(
    registry: Map<string, ProviderAdapter>,
    relayCmd: string,
    relayEnv: Record<string, string> = {}
): string {
    const lines: string[] = []
    let anyHttp = false
    for (const adapter of registry.values()) {
        const ep = endpointFor(adapter, relayCmd)
        lines.push(`[mcp_servers.${adapter.key}]`)
        if (ep.shape === 'http-proxy') {
            anyHttp = true
            lines.push(`url = "${ep.loopbackUrl}"`, `startup_timeout_sec = 60`)
        } else {
            lines.push(`command = "${ep.command}"`)
            lines.push(
                `args = [${ep.args.map((a) => `"${tomlEscape(a)}"`).join(', ')}]`,
                `startup_timeout_sec = 30`
            )
            if (Object.keys(relayEnv).length > 0) {
                lines.push('', `[mcp_servers.${adapter.key}.env]`)
                for (const [key, value] of Object.entries(relayEnv).sort()) {
                    lines.push(`${key} = "${tomlEscape(value)}"`)
                }
            }
        }
        lines.push('')
    }
    const header = anyHttp
        ? '# streamable-HTTP MCP requires this in Codex:\nexperimental_use_rmcp_client = true\n\n'
        : ''
    return header + lines.join('\n')
}

// pi (`~/.pi/agent`-style) shape. pi's config is JSON-ish; use the same
// mcpServers map as Claude — cheap to render, same no-secret invariant.
export function renderPi(
    registry: Map<string, ProviderAdapter>,
    relayCmd: string,
    relayEnv: Record<string, string> = {}
): { mcpServers: Record<string, unknown> } {
    return renderClaude(registry, relayCmd, relayEnv)
}

function tomlEscape(v: string): string {
    return v.replace(/\\/g, '\\\\').replace(/"/g, '\\"')
}
