---
name: logrocket-sessions
description: >-
  Pull LogRocket session data and investigate user-reported issues through the LogRocket API.
  Load before answering a captain request to check LogRocket sessions, replay recordings, query session errors, or investigate what users experienced in an app.
user-invocable: false
metadata:
  internal: true
---

# logrocket-sessions

Use this skill whenever the captain asks to pull, query, or investigate LogRocket session data (session replays, console errors, network failures, user journeys, issue triage).

The single owner of the LogRocket API procedure is this skill and the helper script it references.
Do not restate the endpoint mechanics elsewhere.

## The token

The API token is stored at `config/logrocket-token` under the active firstmate home (captain-private, gitignored).

It is the full working form `pat:<org>:<app>:<secret>` and must be sent verbatim as `Authorization: token <token>`.

The `pat:` prefix is mandatory: the same token without it is rejected with `Missing request authorization`.

Never print, commit, or copy the token into any tracked file or chat log.
If `config/logrocket-token` is missing, ask the captain for a token from LogRocket Settings (<https://app.logrocket.com/r/settings/general>) and store it as `pat:<org>:<app>:<secret>`.

## Registered apps

| App | Token prefix org:app | Notes |
| --- | --- | --- |
| PVA Portal UI Front End (`Pva.Portal.UI`) | `louisville-pva-portal-ui-front-end:louisville-pva-portal-ui-front-end` | `LogRocket.init('louisville-pva-portal-ui-front-end/louisville-pva-portal-ui-front-end')` in `src/main.ts`. Active token verified and session access confirmed. |
| PVA Portal Web (+ Cloud) (`Pva.Portal.Web`) | `pva-portal-web:back-end-project` | `LogRocket.init('pva-portal-web/back-end-project')` in `main.ts`. Needs separate token prefix; active token does not grant access. |
| County Clerk Tax Appeal UI (`CountyClerk.TaxAppeal.UI`) | `countyclerk:countyclerk` | `LogRocket.init('countyclerk/countyclerk')` in `app.component.ts`. Needs separate token prefix; active token does not grant access. |
| Conference UI (`Pva.Conference.UI`) | `ermkte:conference-ui-2022` | `logRocket.init?.('ermkte/conference-ui-2022')` in `app.component.ts`. Needs separate token prefix; active token does not grant access. |

A token created for one app only authorizes that app; a new app needs its own token.
Only list or query apps whose token mapping matches the active token prefix.

## Access verification

The active `config/logrocket-token` matches `louisville-pva-portal-ui-front-end:louisville-pva-portal-ui-front-end` (PVA Portal UI Front End) at <https://app.logrocket.com/louisville-pva-portal-ui-front-end/louisville-pva-portal-ui-front-end>.
Live query and session access were successfully verified for this app via Ask Galileo.
Whenever asked which LogRocket sessions or apps are accessible, check the active token prefix in `config/logrocket-token` and confirm access only for the matching app identity.
Do not claim access for PVA Portal Web (`pva-portal-web:back-end-project`), County Clerk, or Conference UI under the current PVA Portal UI Front End token.

## Quick path: helper script

`bin/fm-logrocket-galileo.sh "<natural language query>"` sends the query to Ask Galileo, polls to completion, and prints the final answer.

Example queries that work well:

- "List the most recent sessions from the past 14 days that contain errors, with session ID, date, user email, URL, and a summary of the console errors or network failures."
- "Analyze the 25 most recent sessions and identify any with console errors, uncaught JavaScript exceptions, or failed network requests (HTTP 4xx/5xx). Report what the user was doing and the exact error."
- "How many sessions were recorded in the past 14 days and what are the 10 most recent, with user and starting URL?"

Options: `--poll <chatID>` continues a prior query, `--raw` prints the full JSON, `--timeout <s>` and `--interval <s>` tune polling.

A `thinking` response takes roughly 1 to 3 minutes to complete.

Known limitation: Issues and metrics filters are often forward-only, so an empty issue count does not prove sessions are clean.
Ask Galileo to watch and analyze specific sessions instead.

## Manual API surface

Base URL: `https://api.logrocket.com/v1/orgs/<org>/apps/<app>` where `<org>` and `<app>` come from the token prefix.

- `POST /ask-galileo/` with `{"message": "<query>"}` returns `{"chatID": "...", "status": "thinking"}`.
- `GET /ask-galileo/?id=<chatID>` polls until `completed` or `error`.
- `POST /highlights/` with `{"userEmail": "..."}` summarizes a user's recent sessions (needs an API key from Settings > API Keys, not the PAT).
- `GET /audit/logs/?limit=10` lists audit-log entries (same API-key requirement).

Session URLs in answers use the form `https://app.logrocket.com/<org>/<app>/s/<session-id>`.
Share full session URLs with the captain so they can open the replay.

## Troubleshooting

- `Missing request authorization`: the `pat:` prefix is missing or the token belongs to a different app.
- `token signature is invalid` (with Bearer): wrong auth scheme, use `Authorization: token`.
- Query returns 0 issues but sessions exist: issue/metric filters can be forward-only, analyze sessions directly instead.
- Galileo keeps polling with no result: wait up to 10 minutes, then retry with `--poll <chatID>`.
