# firstmate MCP auth broker

Firstmate's harness-agnostic MCP credential broker keeps integration secrets in one local `BROKER_HOME` store and renders MCP client configs with no secrets.
Every rendered provider is a stdio relay in broker v2, so the MCP client starts `fm-mcp-broker relay <provider>` and the broker injects credentials at call time.

## Providers

| Provider | Credential | Relay surface |
|---|---|---|
| Linear | Personal API key in the broker store | GraphQL-backed read tools plus single-issue write tools: `linear_viewer`, `linear_search_issues`, `linear_get_issue`, `linear_list_teams`, `linear_get_issue_comments`, `linear_set_issue_status`, `linear_set_issue_team`, `linear_set_issue_project`, `linear_set_issue_assignee`, `linear_update_issue_labels`, `linear_link_issue_pr`, `linear_add_issue_comment`, `linear_cancel_issue` |
| Slack | Static user/bot token or firstmate-owned user OAuth token | Allowlisted Web API passthrough tool `slack_call` |
| Sentry | Sentry auth token | Read tools for projects, project issues/events, issue details, and issue events |
| Datadog | API key plus application key | Read tools for monitors, metrics queries, logs search, and events |
| Mongo | Production read-only MongoDB URI | Read-only tools for collection listing, capped find, and capped aggregation |

Linear intentionally no longer renders the old loopback proxy path.
The personal API key works against `https://api.linear.app/graphql`; `https://mcp.linear.app/mcp` rejects it because that endpoint expects OAuth.

## Requirements

- Node 23.6 or newer.
- No checked-in dependencies or build step.
- `npx mongodb-mcp` availability for live Mongo reads when the broker uses the default Mongo relay path.

## CLI

```sh
export BROKER_HOME=/Users/twaldin/firstmate/data/mcp-broker/home

bin/fm-mcp-broker connect linear --api-key '<LINEAR_PERSONAL_API_KEY>'
bin/fm-mcp-broker connect slack --token '<SLACK_USER_OR_BOT_TOKEN>'
bin/fm-mcp-broker connect sentry --token '<SENTRY_AUTH_TOKEN>'
bin/fm-mcp-broker connect datadog --api-key '<DATADOG_API_KEY>' --app-key '<DATADOG_APPLICATION_KEY>'
bin/fm-mcp-broker connect mongo --uri-file /Users/twaldin/work/lindy/.env.local

bin/fm-mcp-broker login slack --client-id '<SLACK_CLIENT_ID>' --client-secret-file /path/to/client-secret
bin/fm-mcp-broker status
bin/fm-mcp-broker render claude
bin/fm-mcp-broker render codex
bin/fm-mcp-broker render pi
bin/fm-mcp-broker call linear linear_viewer
bin/fm-mcp-broker call linear linear_search_issues --args '{"query":"triage"}'
bin/fm-mcp-broker call slack auth.test
bin/fm-mcp-broker verify linear
bin/fm-mcp-broker verify slack
bin/fm-mcp-broker verify sentry
bin/fm-mcp-broker verify datadog
bin/fm-mcp-broker verify mongo --database lindy
```

`connect slack --token` remains the manual seed path and stores the value under the general `token` field.
Existing stores that still contain the old `botToken` field are read and migrated on refresh.

`call <provider> <tool> [--args JSON]` performs one request through the same adapter dispatch path as the stdio relay, enforces registered relay tools or provider method allowlists, refreshes credentials with `ensureFresh`, prints only the JSON result, and redacts known credential material before stdout.

## Slack OAuth

Create a Slack app owned by firstmate and configure a redirect URI matching the command you will run, for example `http://127.0.0.1:18765/slack/oauth/callback`.
Request user scopes for the read tools first: `team:read`, channel/group/im/mpim read and history scopes, `users:read`, `users:read.email`, `reactions:read`, and search scopes if the workspace grants them.
Run `bin/fm-mcp-broker login slack --client-id '<SLACK_CLIENT_ID>' --client-secret-file /path/to/client-secret --port 18765`.
Open the printed Slack OAuth URL and approve the app in the browser.
Slack redirects to the local callback, and the broker stores the resulting user token in `BROKER_HOME`.
If Slack token rotation is enabled, the broker stores the refresh token chain and client secret in `BROKER_HOME` and refreshes it server-side.

## Rendering

Rendered configs contain only the relay command, relay arguments, and non-secret environment such as `BROKER_HOME`.
They never contain API keys, Slack tokens, Sentry tokens, Datadog keys, or MongoDB URIs.
Set `BROKER_RELAY_ENTRY` before `render` when producing configs for another firstmate home or a secondmate home.

## Testing

```sh
tests/fm-mcp-broker.test.sh
node --check bin/mcp-broker/src/*.ts bin/mcp-broker/src/providers/*.ts bin/mcp-broker/src/renderers/*.ts bin/mcp-broker/demo/e2e.ts bin/mcp-broker/mock/upstream.ts
shellcheck -x bin/fm-mcp-broker tests/fm-mcp-broker.test.sh
```

The e2e test uses `BROKER_MOCK_BASE` and a committed mock upstream to cover every adapter without contacting production APIs.
The live production checks are intentionally separate because Sentry and Datadog credentials may not be present yet.
