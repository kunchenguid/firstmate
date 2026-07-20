// Linear adapter.
//
// The production Linear personal API key (`lin_api_...`) is accepted by
// Linear's GraphQL API, not by `https://mcp.linear.app/mcp`. The rendered
// broker path is therefore a stdio relay with a read-first GraphQL tool surface.
// The OAuth refresh/proxy machinery is kept out of rendered configs but the
// adapter still understands old bearer records so explicit proxy experiments do
// not lose their refresh path.

import { nowMs } from '../store.ts'
import type { CredentialRecord, ProviderAdapter, RelayTool } from '../types.ts'

const DEFAULT_REFRESH_MARGIN_MS = 60_000

const LINEAR_TOOLS = [
    tool('linear_viewer', 'Read the authenticated Linear viewer.', {}),
    tool('linear_list_teams', 'List Linear teams visible to the authenticated user.', {
        first: numberProp('Maximum teams to return. Default 50, max 100.'),
    }),
    tool('linear_search_issues', 'Search Linear issues by title or description.', {
        query: { type: 'string' },
        teamId: { type: 'string' },
        first: numberProp('Maximum issues to return. Default 25, max 50.'),
    }),
    tool('linear_get_issue', 'Read one Linear issue by id, UUID, or identifier.', {
        id: { type: 'string' },
    }),
    tool('linear_get_issue_comments', 'Read comments for one Linear issue.', {
        id: { type: 'string' },
        first: numberProp('Maximum comments to return. Default 25, max 50.'),
    }),
    tool('linear_set_issue_status', 'Update one Linear issue workflow state/status.', {
        issueId: requiredStringProp('Linear issue id, UUID, or identifier.'),
        stateId: requiredStringProp('Linear workflow state id to set.'),
    }),
    tool('linear_set_issue_team', 'Move one Linear issue to another team.', {
        issueId: requiredStringProp('Linear issue id, UUID, or identifier.'),
        teamId: requiredStringProp('Linear team id to set.'),
    }),
    tool('linear_set_issue_project', 'Set the project for one Linear issue.', {
        issueId: requiredStringProp('Linear issue id, UUID, or identifier.'),
        projectId: requiredStringProp('Linear project id to set.'),
    }),
    tool('linear_set_issue_assignee', 'Set the assignee for one Linear issue.', {
        issueId: requiredStringProp('Linear issue id, UUID, or identifier.'),
        assigneeId: requiredStringProp('Linear user id to set as assignee.'),
    }),
    tool('linear_update_issue_labels', 'Add and/or remove labels on one Linear issue.', {
        issueId: requiredStringProp('Linear issue id, UUID, or identifier.'),
        addLabelIds: stringArrayProp('Linear label ids to add.'),
        removeLabelIds: stringArrayProp('Linear label ids to remove.'),
    }),
    tool('linear_link_issue_pr', 'Attach a pull request URL to one Linear issue.', {
        issueId: requiredStringProp('Linear issue id, UUID, or identifier.'),
        prUrl: requiredStringProp('Pull request URL to attach.'),
        title: { type: 'string', description: 'Optional attachment title. Default "Pull request".' },
    }),
    tool('linear_add_issue_comment', 'Add a comment to one Linear issue.', {
        issueId: requiredStringProp('Linear issue id, UUID, or identifier.'),
        body: requiredStringProp('Comment body.'),
    }),
    tool('linear_cancel_issue', 'Cancel one Linear issue by moving it to its team canceled state.', {
        issueId: requiredStringProp('Linear issue id, UUID, or identifier.'),
    }),
] as const satisfies readonly RelayTool[]

export function makeLinearAdapter(opts: {
    graphqlUrl: string
    tokenUrl: string
    clientId?: string
    refreshMarginMs?: number
}): ProviderAdapter {
    const REFRESH_MARGIN_MS = opts.refreshMarginMs ?? DEFAULT_REFRESH_MARGIN_MS
    return {
        key: 'linear',
        shape: 'stdio-relay',
        upstreamUrl: opts.graphqlUrl,
        relayTools: LINEAR_TOOLS,

        needsRefresh(record) {
            if (record?.access.apiKey) return false
            if (!record || !record.access.bearer) return true
            if (record.expiresAt === undefined) return false
            return record.expiresAt - nowMs() <= REFRESH_MARGIN_MS
        },

        async refresh(current) {
            const refreshToken = current?.refresh?.token
            if (!refreshToken) {
                throw new Error('linear: no personal API key; run `broker connect linear --api-key ...`')
            }
            const res = await fetch(opts.tokenUrl, {
                method: 'POST',
                headers: { 'content-type': 'application/json' },
                body: JSON.stringify({
                    grant_type: 'refresh_token',
                    refresh_token: refreshToken,
                    client_id: opts.clientId ?? 'firstmate-broker',
                }),
            })
            if (!res.ok) {
                throw new Error(`linear token refresh failed: ${res.status} ${await res.text()}`)
            }
            const body = (await res.json()) as {
                access_token: string
                expires_in: number
                refresh_token?: string
            }
            return {
                provider: 'linear',
                access: { bearer: body.access_token },
                refresh: {
                    token: body.refresh_token ?? refreshToken,
                    model: body.refresh_token ? 'single-use' : 'reusable',
                },
                expiresAt: nowMs() + body.expires_in * 1000,
                updatedAt: nowMs(),
            }
        },

        authHeaders(record) {
            if (record.access.apiKey) return { authorization: record.access.apiKey }
            return { authorization: `Bearer ${record.access.bearer}` }
        },

        async handleRelayTool({ name, args, record }) {
            const gql = makeGraphql(opts.graphqlUrl, this.authHeaders(record))
            switch (name) {
                case 'linear_viewer':
                    return jsonResult(
                        await gql('query Viewer { viewer { id name email displayName } }')
                    )
                case 'linear_list_teams':
                    return jsonResult(
                        await gql(
                            `query Teams($first: Int!) {
                                teams(first: $first) {
                                    nodes { id key name description private archivedAt createdAt updatedAt }
                                }
                            }`,
                            { first: clampInt(args.first, 50, 1, 100) }
                        )
                    )
                case 'linear_search_issues': {
                    const query = stringArg(args.query)
                    const first = clampInt(args.first, 25, 1, 50)
                    const filter = buildIssueFilter(query, stringArg(args.teamId))
                    return jsonResult(
                        await gql(
                            `query SearchIssues($first: Int!, $filter: IssueFilter) {
                                issues(first: $first, filter: $filter, orderBy: updatedAt) {
                                    nodes {
                                        id identifier title url priority estimate createdAt updatedAt
                                        state { id name type }
                                        team { id key name }
                                        assignee { id name email }
                                    }
                                }
                            }`,
                            { first, filter }
                        )
                    )
                }
                case 'linear_get_issue':
                    return jsonResult(
                        await gql(
                            `query Issue($id: String!) {
                                issue(id: $id) {
                                    id identifier title description url branchName priority estimate
                                    createdAt updatedAt completedAt canceledAt archivedAt
                                    state { id name type }
                                    team { id key name }
                                    assignee { id name email }
                                    creator { id name email }
                                    labels { nodes { id name color } }
                                }
                            }`,
                            { id: requireString(args.id, 'id') }
                        )
                    )
                case 'linear_get_issue_comments':
                    return jsonResult(
                        await gql(
                            `query IssueComments($id: String!, $first: Int!) {
                                issue(id: $id) {
                                    id identifier title
                                    comments(first: $first) {
                                        nodes {
                                            id body createdAt updatedAt editedAt
                                            user { id name email }
                                        }
                                    }
                                }
                            }`,
                            { id: requireString(args.id, 'id'), first: clampInt(args.first, 25, 1, 50) }
                        )
                    )
                case 'linear_set_issue_status': {
                    requireWriteKeys(args, ['issueId', 'stateId'])
                    return jsonResult(
                        await updateIssue(gql, requireIssueId(args), {
                            stateId: requireString(args.stateId, 'stateId'),
                        })
                    )
                }
                case 'linear_set_issue_team': {
                    requireWriteKeys(args, ['issueId', 'teamId'])
                    return jsonResult(
                        await updateIssue(gql, requireIssueId(args), {
                            teamId: requireString(args.teamId, 'teamId'),
                        })
                    )
                }
                case 'linear_set_issue_project': {
                    requireWriteKeys(args, ['issueId', 'projectId'])
                    return jsonResult(
                        await updateIssue(gql, requireIssueId(args), {
                            projectId: requireString(args.projectId, 'projectId'),
                        })
                    )
                }
                case 'linear_set_issue_assignee': {
                    requireWriteKeys(args, ['issueId', 'assigneeId'])
                    return jsonResult(
                        await updateIssue(gql, requireIssueId(args), {
                            assigneeId: requireString(args.assigneeId, 'assigneeId'),
                        })
                    )
                }
                case 'linear_update_issue_labels': {
                    requireWriteKeys(args, ['issueId', 'addLabelIds', 'removeLabelIds'])
                    const addLabelIds = optionalStringArray(args.addLabelIds, 'addLabelIds')
                    const removeLabelIds = optionalStringArray(args.removeLabelIds, 'removeLabelIds')
                    if (addLabelIds.length === 0 && removeLabelIds.length === 0) {
                        throw new Error('linear_update_issue_labels requires addLabelIds or removeLabelIds')
                    }
                    for (const labelId of addLabelIds) {
                        if (removeLabelIds.includes(labelId)) {
                            throw new Error(`label id "${labelId}" cannot be both added and removed`)
                        }
                    }
                    return jsonResult(
                        await updateIssue(gql, requireIssueId(args), {
                            addedLabelIds: addLabelIds.length > 0 ? addLabelIds : undefined,
                            removedLabelIds: removeLabelIds.length > 0 ? removeLabelIds : undefined,
                        })
                    )
                }
                case 'linear_link_issue_pr': {
                    requireWriteKeys(args, ['issueId', 'prUrl', 'title'])
                    return jsonResult(
                        await gql(
                            `mutation LinkIssuePr($issueId: String!, $url: String!, $title: String) {
                                attachmentLinkURL(issueId: $issueId, url: $url, title: $title) {
                                    success
                                    attachment { id title url issue { id identifier title url } }
                                }
                            }`,
                            {
                                issueId: requireIssueId(args),
                                url: requireHttpUrl(args.prUrl, 'prUrl'),
                                title: stringArg(args.title) || 'Pull request',
                            }
                        )
                    )
                }
                case 'linear_add_issue_comment': {
                    requireWriteKeys(args, ['issueId', 'body'])
                    return jsonResult(
                        await gql(
                            `mutation AddIssueComment($input: CommentCreateInput!) {
                                commentCreate(input: $input) {
                                    success
                                    comment {
                                        id body createdAt updatedAt
                                        issue { id identifier title url }
                                        user { id name email }
                                    }
                                }
                            }`,
                            {
                                input: {
                                    issueId: requireIssueId(args),
                                    body: requireString(args.body, 'body'),
                                },
                            }
                        )
                    )
                }
                case 'linear_cancel_issue': {
                    requireWriteKeys(args, ['issueId'])
                    const issueId = requireIssueId(args)
                    const data = (await gql(
                        `query IssueCancellationState($id: String!) {
                            issue(id: $id) {
                                id identifier title
                                team {
                                    id key name
                                    states(first: 100) { nodes { id name type } }
                                }
                            }
                        }`,
                        { id: issueId }
                    )) as {
                        issue?: {
                            team?: { states?: { nodes?: Array<{ id?: string; name?: string; type?: string }> } }
                        } | null
                    }
                    const states = data.issue?.team?.states?.nodes ?? []
                    const canceled = states.find((state) => state.type?.toLowerCase() === 'canceled')
                    if (!canceled?.id) {
                        throw new Error(`linear_cancel_issue could not find a canceled workflow state for "${issueId}"`)
                    }
                    return jsonResult(await updateIssue(gql, issueId, { stateId: canceled.id }))
                }
                default:
                    throw new Error(`linear: unsupported tool ${name}`)
            }
        },
    } satisfies ProviderAdapter
}

type GraphqlCall = ReturnType<typeof makeGraphql>

async function updateIssue(
    gql: GraphqlCall,
    id: string,
    input: Record<string, unknown>
): Promise<unknown> {
    return gql(
        `mutation IssueUpdate($id: String!, $input: IssueUpdateInput!) {
            issueUpdate(id: $id, input: $input) {
                success
                issue {
                    id identifier title url updatedAt canceledAt
                    state { id name type }
                    team { id key name }
                    project { id name }
                    assignee { id name email }
                    labels { nodes { id name color } }
                }
            }
        }`,
        { id, input: dropUndefined(input) }
    )
}

function makeGraphql(url: string, authHeaders: Record<string, string>) {
    return async (query: string, variables?: Record<string, unknown>): Promise<unknown> => {
        const res = await fetch(url, {
            method: 'POST',
            headers: { 'content-type': 'application/json', ...authHeaders },
            body: JSON.stringify({ query, variables }),
        })
        const body = (await res.json()) as { data?: unknown; errors?: unknown }
        if (!res.ok || body.errors) {
            throw new Error(`linear GraphQL failed: HTTP ${res.status} ${JSON.stringify(body.errors)}`)
        }
        return body.data
    }
}

function buildIssueFilter(query: string, teamId: string): Record<string, unknown> | undefined {
    const clauses: Record<string, unknown>[] = []
    if (query) {
        clauses.push(
            { title: { containsIgnoreCase: query } },
            { description: { containsIgnoreCase: query } },
            { identifier: { containsIgnoreCase: query } }
        )
    }
    const filter: Record<string, unknown> = {}
    if (clauses.length > 0) filter.or = clauses
    if (teamId) filter.team = { id: { eq: teamId } }
    return Object.keys(filter).length > 0 ? filter : undefined
}

function tool(name: string, description: string, properties: Record<string, unknown>): RelayTool {
    const required = Object.keys(properties).filter(
        (key) => isRecord(properties[key]) && properties[key].required === true
    )
    const schemaProperties = Object.fromEntries(
        Object.entries(properties).map(([key, prop]) => {
            if (!isRecord(prop) || prop.required !== true) return [key, prop]
            const { required: _required, ...rest } = prop
            return [key, rest]
        })
    )
    return {
        name,
        description,
        inputSchema: {
            type: 'object',
            properties: schemaProperties,
            required,
        },
    }
}

function numberProp(description: string): Record<string, unknown> {
    return { type: 'number', description }
}

function requiredStringProp(description: string): Record<string, unknown> {
    return { type: 'string', description, required: true }
}

function stringArrayProp(description: string): Record<string, unknown> {
    return {
        type: 'array',
        description,
        items: { type: 'string' },
        uniqueItems: true,
    }
}

function jsonResult(value: unknown) {
    return { content: [{ type: 'text' as const, text: JSON.stringify(value, null, 2) }] }
}

function isRecord(v: unknown): v is Record<string, unknown> {
    return !!v && typeof v === 'object' && !Array.isArray(v)
}

function dropUndefined(input: Record<string, unknown>): Record<string, unknown> {
    return Object.fromEntries(Object.entries(input).filter(([, value]) => value !== undefined))
}

function stringArg(v: unknown): string {
    return typeof v === 'string' ? v.trim() : ''
}

function requireString(v: unknown, name: string): string {
    if (Array.isArray(v)) throw new Error(`"${name}" must be a single string`)
    const s = stringArg(v)
    if (!s) throw new Error(`missing required argument "${name}"`)
    return s
}

function requireHttpUrl(v: unknown, name: string): string {
    const url = requireString(v, name)
    let parsed: URL
    try {
        parsed = new URL(url)
    } catch {
        throw new Error(`"${name}" must be a valid http(s) URL`)
    }
    if (parsed.protocol !== 'https:' && parsed.protocol !== 'http:') {
        throw new Error(`"${name}" must be a valid http(s) URL`)
    }
    return url
}

function requireIssueId(args: Record<string, unknown>): string {
    if (Object.prototype.hasOwnProperty.call(args, 'issueIds')) {
        throw new Error('bulk issue operations are not allowed; pass one issueId')
    }
    return requireString(args.issueId, 'issueId')
}

function requireWriteKeys(args: Record<string, unknown>, allowed: readonly string[]): void {
    if (Object.prototype.hasOwnProperty.call(args, 'issueIds')) {
        throw new Error('bulk issue operations are not allowed; pass one issueId')
    }
    const allowedSet = new Set(allowed)
    const unknown = Object.keys(args).filter((key) => !allowedSet.has(key))
    if (unknown.length > 0) {
        throw new Error(`unsupported argument(s): ${unknown.join(', ')}`)
    }
}

function optionalStringArray(v: unknown, name: string): string[] {
    if (v === undefined) return []
    if (!Array.isArray(v)) throw new Error(`"${name}" must be an array of strings`)
    const out = v.map((item, index) => {
        const s = stringArg(item)
        if (!s) throw new Error(`"${name}[${index}]" must be a non-empty string`)
        return s
    })
    return [...new Set(out)]
}

function clampInt(v: unknown, fallback: number, min: number, max: number): number {
    const n = typeof v === 'number' ? v : Number(v)
    if (!Number.isFinite(n)) return fallback
    return Math.max(min, Math.min(max, Math.floor(n)))
}
