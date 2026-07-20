// Generic stdio MCP relay for `stdio-relay`-shape providers. Directly
// generalizes lindy-slack-relay.js's MCP mode: a minimal JSON-RPC 2.0 server
// over stdio that, per tool call, reads the CURRENT token from the store
// (refreshing via the adapter if the external source rotated it) and proxies an
// authenticated call to the upstream API. The spawning client never sees a
// token — it's injected here at request time, so rotation needs no restart.
//
// The relay exposes one generic passthrough tool `<provider>_call`:
//   { method: string, params?: object }  ->  POST <upstreamUrl>/<method>
// which is enough to prove the auth-injection/rotation property. A production
// relay would expose the provider's real tool surface (slack_post, etc.).

import { createInterface } from 'node:readline'

import { callAdapterTool } from './calls.ts'
import { ensureFresh } from './refresher.ts'
import type { CredentialStore } from './store.ts'
import type { ProviderAdapter } from './types.ts'

type JsonRpcReq = { jsonrpc: '2.0'; id?: number | string | null; method: string; params?: unknown }

export function runStdioRelay(opts: { store: CredentialStore; adapter: ProviderAdapter }): void {
    const { store, adapter } = opts
    const toolName = `${adapter.key}_call`
    const relayTools =
        adapter.relayTools ??
        ([
            {
                name: toolName,
                description: `Authenticated passthrough to ${adapter.key} upstream. Token injected per-call from the broker store.`,
                inputSchema: {
                    type: 'object',
                    properties: {
                        method: { type: 'string' },
                        params: { type: 'object' },
                    },
                    required: ['method'],
                },
            },
        ] as const)
    const rl = createInterface({ input: process.stdin })

    rl.on('line', (line) => {
        void handleLine(line)
    })

    async function handleLine(line: string): Promise<void> {
        const trimmed = line.trim()
        if (!trimmed) return
        let req: JsonRpcReq
        try {
            req = JSON.parse(trimmed) as JsonRpcReq
        } catch {
            return
        }
        try {
            const result = await dispatch(req)
            if (req.id !== undefined) reply({ jsonrpc: '2.0', id: req.id ?? null, result })
        } catch (error) {
            if (req.id !== undefined) {
                reply({
                    jsonrpc: '2.0',
                    id: req.id ?? null,
                    error: { code: -32_000, message: (error as Error).message },
                })
            }
        }
    }

    async function dispatch(req: JsonRpcReq): Promise<unknown> {
        if (req.method === 'initialize') {
            return {
                protocolVersion: '2024-11-05',
                serverInfo: { name: `firstmate-broker-relay:${adapter.key}`, version: '0.1.0' },
                capabilities: { tools: {} },
            }
        }
        if (req.method === 'tools/list') {
            return { tools: relayTools }
        }
        if (req.method === 'tools/call') {
            const params = (req.params ?? {}) as {
                name?: string
                arguments?: Record<string, unknown>
            }
            if (!relayTools.some((tool) => tool.name === params.name)) {
                throw new Error(`unknown tool: ${params.name}`)
            }
            const args = params.arguments ?? {}
            if (adapter.handleRelayTool) {
                const record = await ensureFresh(store, adapter)
                return adapter.handleRelayTool({ name: String(params.name), args, record })
            }
            if (params.name !== toolName) throw new Error(`unknown tool: ${params.name}`)
            const upstreamMethod = String(args.method ?? '')
            if (!upstreamMethod) throw new Error('missing "method" argument')

            const result = await callAdapterTool({
                store,
                adapter,
                tool: upstreamMethod,
                args: args.params ?? {},
            })
            return {
                content: [{ type: 'text', text: result.rawText }],
                isError: result.isError,
            }
        }
        throw new Error(`unsupported method: ${req.method}`)
    }

    function reply(obj: unknown): void {
        process.stdout.write(JSON.stringify(obj) + '\n')
    }
}
