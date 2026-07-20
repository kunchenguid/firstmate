// End-to-end demo proving the broker v2 claims:
//
//   credential store -> rendered configs (no secrets) -> stdio MCP relay ->
//   provider-specific read tools -> auth material injected only inside broker.
//
// Everything uses the committed mock upstream except the relay process itself,
// which is spawned exactly as MCP clients spawn it.

import { spawn } from 'node:child_process'
import { mkdtempSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { createInterface } from 'node:readline'
import { fileURLToPath } from 'node:url'

import { setSlackBotToken, startMockUpstream } from '../mock/upstream.ts'
import { makeDatadogAdapter } from '../src/providers/datadog.ts'
import { makeLinearAdapter } from '../src/providers/linear.ts'
import { makeMongoAdapter } from '../src/providers/mongo.ts'
import { makeSentryAdapter } from '../src/providers/sentry.ts'
import { makeSlackAdapter } from '../src/providers/slack.ts'
import { ensureFresh } from '../src/refresher.ts'
import { renderClaude, renderCodex, renderPi } from '../src/renderers/index.ts'
import { CredentialStore, nowMs } from '../src/store.ts'
import type { ProviderAdapter } from '../src/types.ts'

const MOCK_PORT = Number(process.env.BROKER_MOCK_PORT ?? 8790)
const HERE = fileURLToPath(new URL('.', import.meta.url))
const CLI = join(HERE, '..', 'src', 'cli.ts')

let step = 0
function say(msg: string): void {
    process.stdout.write(`\n${'='.repeat(72)}\n[STEP ${++step}] ${msg}\n${'='.repeat(72)}\n`)
}
function ok(msg: string): void {
    process.stdout.write(`  ✓ ${msg}\n`)
}
function fail(msg: string): never {
    process.stdout.write(`  ✗ ${msg}\n`)
    throw new Error(`ASSERTION FAILED: ${msg}`)
}
function assert(cond: unknown, msg: string): void {
    if (cond) ok(msg)
    else fail(msg)
}

async function main(): Promise<void> {
    const home = mkdtempSync(join(tmpdir(), 'mcp-broker-v2-'))
    const slackTokenFile = join(home, 'slack.token')
    process.stdout.write(`broker home (scratch): ${home}\n`)

    const store = new CredentialStore(home)
    const mock = await startMockUpstream()
    ok(`mock upstream listening on :${MOCK_PORT}`)

    const mockBase = `http://127.0.0.1:${MOCK_PORT}`
    const linear = makeLinearAdapter({
        graphqlUrl: `${mockBase}/linear/graphql`,
        tokenUrl: `${mockBase}/oauth/token`,
    })
    const slack = makeSlackAdapter({
        apiBaseUrl: `${mockBase}/slack/api`,
        tokenFile: slackTokenFile,
    })
    const sentry = makeSentryAdapter({ apiBaseUrl: `${mockBase}/sentry/api/0` })
    const datadog = makeDatadogAdapter({ apiBaseUrl: `${mockBase}/datadog/api` })
    const mongo = makeMongoAdapter({ mockUrl: mockBase })
    const registry = new Map<string, ProviderAdapter>(
        [linear, slack, sentry, datadog, mongo].map((adapter) => [adapter.key, adapter])
    )

    say('Store credentials in the central store (0600)')
    store.put({ provider: 'linear', access: { apiKey: 'lin_api_mock' }, updatedAt: nowMs() })
    writeFileSync(slackTokenFile, 'xoxp-mock-0', { mode: 0o600 })
    setSlackBotToken('xoxp-mock-0')
    await ensureFresh(store, slack)
    store.put({ provider: 'sentry', access: { token: 'sentry_mock' }, updatedAt: nowMs() })
    store.put({
        provider: 'datadog',
        access: { apiKey: 'dd_api_mock', appKey: 'dd_app_mock' },
        updatedAt: nowMs(),
    })
    store.put({
        provider: 'mongo',
        access: { uri: 'mongodb+srv://user:password@cluster.example/prod' },
        updatedAt: nowMs(),
    })
    const { execSync } = await import('node:child_process')
    const perms = execSync(`stat -f '%A' '${store.filePath}'`).toString().trim()
    assert(perms === '600', `store file mode is 0600 (got ${perms})`)

    say('Render claude/codex/pi config and assert the no-secret invariant')
    const relayEnv = {
        BROKER_HOME: home,
        BROKER_MOCK_BASE: mockBase,
        BROKER_SLACK_TOKEN_FILE: slackTokenFile,
        BROKER_MONGO_MOCK_URL: mockBase,
    }
    const claudeCfg = renderClaude(registry, CLI, relayEnv)
    const codexCfg = renderCodex(registry, CLI, relayEnv)
    const piCfg = renderPi(registry, CLI, relayEnv)
    const rendered = JSON.stringify(claudeCfg, null, 2) + codexCfg + JSON.stringify(piCfg, null, 2)
    process.stdout.write(`\n--- claude .mcp.json ---\n${JSON.stringify(claudeCfg, null, 2)}\n`)
    process.stdout.write(`\n--- codex config.toml ---\n${codexCfg}\n`)
    process.stdout.write(`--- pi config ---\n${JSON.stringify(piCfg, null, 2)}\n`)
    const secretPattern = /lin_api_|xox|sk-ant|mongodb:\/\/|mongodb\+srv:\/\/|DD-API|dd[a-f0-9]{32}|sentry_mock|dd_api_mock|dd_app_mock/
    assert(!secretPattern.test(rendered), 'rendered configs contain no token, URI, or API-key material')
    assert(!rendered.includes('8791'), 'rendered configs do not include the old Linear proxy port')
    for (const provider of ['linear', 'slack', 'sentry', 'datadog', 'mongo']) {
        assert(
            (claudeCfg.mcpServers[provider] as { type: string }).type === 'stdio',
            `${provider} renders as stdio`
        )
    }

    say('Call each provider through its broker stdio relay')
    const relayEnvFull = {
        ...process.env,
        BROKER_HOME: home,
        BROKER_MOCK_BASE: mockBase,
        BROKER_SLACK_TOKEN_FILE: slackTokenFile,
        BROKER_MONGO_MOCK_URL: mockBase,
    }
    const linearViewer = await relayTool(relayEnvFull, 'linear', 'linear_viewer', {})
    assert(linearViewer.viewer?.email === 'tim@lindy.ai', 'Linear GraphQL viewer returned mock user')
    const linearStatus = await relayTool(relayEnvFull, 'linear', 'linear_set_issue_status', {
        issueId: 'issue-1',
        stateId: 'state-started',
    })
    assert(
        linearStatus.issueUpdate?.issue?.state?.id === 'state-started',
        'Linear issue status update mutation succeeded'
    )
    const linearTeam = await relayTool(relayEnvFull, 'linear', 'linear_set_issue_team', {
        issueId: 'issue-1',
        teamId: 'team-2',
    })
    assert(linearTeam.issueUpdate?.issue?.team?.id === 'team-2', 'Linear issue team update mutation succeeded')
    const linearProject = await relayTool(relayEnvFull, 'linear', 'linear_set_issue_project', {
        issueId: 'issue-1',
        projectId: 'project-1',
    })
    assert(
        linearProject.issueUpdate?.issue?.project?.id === 'project-1',
        'Linear issue project update mutation succeeded'
    )
    const linearAssignee = await relayTool(relayEnvFull, 'linear', 'linear_set_issue_assignee', {
        issueId: 'issue-1',
        assigneeId: 'user-2',
    })
    assert(
        linearAssignee.issueUpdate?.issue?.assignee?.id === 'user-2',
        'Linear issue assignee update mutation succeeded'
    )
    const linearLabels = await relayTool(relayEnvFull, 'linear', 'linear_update_issue_labels', {
        issueId: 'issue-1',
        addLabelIds: ['label-new'],
        removeLabelIds: ['label-old'],
    })
    assert(
        linearLabels.issueUpdate?.issue?.labels?.nodes?.some((label: { id?: string }) => label.id === 'label-new'),
        'Linear issue label add/remove mutation succeeded'
    )
    const linearPr = await relayTool(relayEnvFull, 'linear', 'linear_link_issue_pr', {
        issueId: 'issue-1',
        prUrl: 'https://github.com/lindy-ai/app/pull/123',
        title: 'PR #123',
    })
    assert(
        linearPr.attachmentLinkURL?.attachment?.url === 'https://github.com/lindy-ai/app/pull/123',
        'Linear issue PR attachment mutation succeeded'
    )
    const linearComment = await relayTool(relayEnvFull, 'linear', 'linear_add_issue_comment', {
        issueId: 'issue-1',
        body: 'Broker write test comment',
    })
    assert(
        linearComment.commentCreate?.comment?.body === 'Broker write test comment',
        'Linear issue comment mutation succeeded'
    )
    const linearCancel = await relayTool(relayEnvFull, 'linear', 'linear_cancel_issue', {
        issueId: 'issue-1',
    })
    assert(
        linearCancel.issueUpdate?.issue?.state?.type === 'canceled',
        'Linear issue cancel mutation moved to canceled state'
    )
    const rejectedMutation = await relayToolResponse(
        relayEnvFull,
        'linear',
        'linear_issue_batch_update',
        { issueIds: ['issue-1', 'issue-2'], stateId: 'state-started' },
        { expectAdvertised: false }
    )
    assert(
        rejectedMutation.error?.message?.includes('unknown tool'),
        'Linear rejects non-allowlisted mutation tools'
    )
    const rejectedBulk = await relayToolResponse(relayEnvFull, 'linear', 'linear_set_issue_status', {
        issueIds: ['issue-1', 'issue-2'],
        stateId: 'state-started',
    })
    assert(
        rejectedBulk.error?.message?.includes('bulk issue operations are not allowed'),
        'Linear write tools reject bulk issue arguments'
    )
    assert(
        !secretPattern.test(
            JSON.stringify([
                linearStatus,
                linearTeam,
                linearProject,
                linearAssignee,
                linearLabels,
                linearPr,
                linearComment,
                linearCancel,
                rejectedMutation,
                rejectedBulk,
            ])
        ),
        'Linear write relay responses contain no token, URI, or API-key material'
    )
    const sentryProjects = await relayTool(relayEnvFull, 'sentry', 'sentry_list_projects', {})
    assert(Array.isArray(sentryProjects) && sentryProjects[0]?.slug === 'web', 'Sentry projects read succeeded')
    const monitors = await relayTool(relayEnvFull, 'datadog', 'datadog_list_monitors', {})
    assert(Array.isArray(monitors) && monitors[0]?.id === 42, 'Datadog monitors read succeeded')
    const collections = await relayTool(relayEnvFull, 'mongo', 'mongo_list_collections', {})
    assert(collections.collections?.length === 2, 'Mongo list collections read succeeded')

    say('Slack relay keeps the legacy allowlisted passthrough and rotates token field name')
    const slackAuth = await relayTool(relayEnvFull, 'slack', 'slack_call', {
        method: 'auth.test',
        params: {},
    })
    assert(slackAuth.ok === true && slackAuth.servedWithToken === 'xoxp-mock-0', 'Slack auth.test succeeded')
    setSlackBotToken('xoxp-mock-1')
    writeFileSync(slackTokenFile, 'xoxp-mock-1', { mode: 0o600 })
    const slackRotated = await relayTool(relayEnvFull, 'slack', 'slack_call', {
        method: 'team.info',
        params: {},
    })
    assert(slackRotated.ok === true && slackRotated.servedWithToken === 'xoxp-mock-1', 'Slack token rotated without config change')

    say('ALL ASSERTIONS PASSED')
    mock.close()
    process.stdout.write('\nDemo complete.\n')
    process.exit(0)
}

async function relayTool(
    env: NodeJS.ProcessEnv,
    provider: string,
    name: string,
    args: Record<string, unknown>
): Promise<any> {
    const call = await relayToolResponse(env, provider, name, args)
    if (call.error) throw new Error(`${provider}.${name}: ${call.error.message}`)
    const text = call.result.content[0].text
    return JSON.parse(text)
}

async function relayToolResponse(
    env: NodeJS.ProcessEnv,
    provider: string,
    name: string,
    args: Record<string, unknown>,
    opts: { expectAdvertised?: boolean } = {}
): Promise<any> {
    const relay = spawn('node', [CLI, 'relay', provider], {
        env,
        stdio: ['pipe', 'pipe', 'inherit'],
    })
    const relayRl = createInterface({ input: relay.stdout })
    const pending = new Map<number, (v: unknown) => void>()
    relayRl.on('line', (line) => {
        try {
            const msg = JSON.parse(line) as { id?: number }
            if (typeof msg.id === 'number' && pending.has(msg.id)) {
                pending.get(msg.id)!(msg)
                pending.delete(msg.id)
            }
        } catch {
            /* ignore non-JSON */
        }
    })
    function rpc(id: number, method: string, params?: unknown): Promise<any> {
        return new Promise((resolve) => {
            pending.set(id, resolve)
            relay.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n')
        })
    }
    const initRes = await rpc(1, 'initialize')
    assert(
        initRes.result?.serverInfo?.name === `firstmate-broker-relay:${provider}`,
        `${provider} relay initialized`
    )
    const listRes = await rpc(2, 'tools/list')
    const advertised = listRes.result?.tools?.some((tool: { name: string }) => tool.name === name)
    if (opts.expectAdvertised === false) {
        assert(!advertised, `${provider} does not advertise ${name}`)
    } else {
        assert(advertised, `${provider} advertises ${name}`)
    }
    const call = await rpc(3, 'tools/call', { name, arguments: args })
    relay.kill()
    return call
}

main().catch((error) => {
    process.stderr.write(`\nDEMO FAILED: ${(error as Error).stack}\n`)
    process.exit(1)
})
