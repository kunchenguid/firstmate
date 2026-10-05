# Task, report, and agent journal viewer

`fm-jsonl-viewer.mjs` provides a read-only browser dashboard for one Firstmate home's tasks, canonical task documents, ShortTask journals, and supervision-branch sessions.
Task discovery and classification use the structured fleet snapshot, current backlog, and configured Done archive rather than the last status-log line.
The only content artifacts it exposes are `state/short-agents/<short-id>/journal.jsonl`, `state/branch-session/*.jsonl`, and canonical `data/<task>/report.md` or `data/<task>/brief.md` files below the selected canonical home.
It does not expose arbitrary paths, follow symlinks, modify a journal or task document, or offer chat and lifecycle controls.

## Start the viewer

Create an unpredictable token with at least 16 bytes in a private file, then run the server from the tracked Firstmate checkout.
The server requires the token file to be absolute, owned by the current user, regular, not a symlink, and grant no permissions to group or other users.
It does not print the token or put it in a URL.

```sh
umask 077
openssl rand -hex 32 > /absolute/private/path/jsonl-viewer.token
FM_HOME=/absolute/path/to/firstmate-home \
FM_JSONL_VIEWER_TOKEN_FILE=/absolute/private/path/jsonl-viewer.token \
node bin/fm-jsonl-viewer.mjs
```

`FM_JSONL_VIEWER_TOKEN` remains available for an ephemeral token supplied directly by a secret manager, but it cannot be combined with `FM_JSONL_VIEWER_TOKEN_FILE`.

The default listener is `0.0.0.0:17847`.
Override it with `--host` and `--port`, or `FM_JSONL_VIEWER_HOST` and `FM_JSONL_VIEWER_PORT`.
The server provides plain HTTP without TLS termination.
Binding to every interface can expose private conversations, tool output, and the bearer token to the network, so do not expose it to an untrusted network and put remote access behind an existing private tunnel or TLS reverse proxy.

Open `http://SERVER:17847/` and enter the token on the dedicated login page.
After authentication, the Viewer keeps each reading task on a distinct route and layout:

| Page | Route | Layout and purpose |
|---|---|---|
| Dashboard | `/dashboard` | A collapsible task-list sidebar beside the selected task's identity, state, brief, or report |
| Reports | `/reports` and `/report/<task-id>` | A report library beside a focused Markdown reading surface |
| Supervisor Work Journal | `/journal/supervisor` and `/journal/supervisor/<session-id>` | A session list beside filters, pagination, follow controls, and chronological work-log entries |

The top navigation switches among these authenticated pages without mixing login controls into the work area.
The task sidebar can collapse and reopen without clearing the selected task, and narrow screens stack the list above the reading area so navigation remains available.
Selected task, report, and journal identities are encoded in the route, so direct links, reload, and browser back and forward restore the same reading context after authentication.
Legacy bookmarks to `/` continue to open the login flow and then land on the Dashboard.
The dashboard renders one status card for each status currently present in the task list, with `Needs reconciliation` tasks included in the `Completed` card.
Each status card count uses the same search scope as the task list, and activating a card filters the list to that display group; `View all tasks` clears the status filter.
Completed records remain available through the task list and report view without being relabelled as archived.
An explicitly archived task remains in the archived or cancelled group when its retained remote state is nonterminal or ambiguous, and the dashboard labels that remote status as unconfirmed without implying cancellation or success.
Status cards use the backend-provided display status shown on each task card, while the Dashboard's `Completed` card counts and filters both `Completed` and `Needs reconciliation` tasks.
The list ordering keeps `Completed` and `Needs reconciliation` tasks together, while the task cards retain their individual backend-provided status labels.

The viewer does not use retained rich lifecycle records as an ordinary task source. It may read a valid historical `archived` fact only to keep an already explicit stop labelled `Cancelled`; malformed or non-archived legacy records are ignored and never require reconciliation.
Each task shows explicit Brief and Report selectors, enables every canonical document that is actually available, and labels unavailable document types instead of inventing content.
The initial selection remains the canonical report when present and otherwise the canonical brief.
Tasks with a canonical report also provide an explicit Read full report action that navigates to the dedicated report route without changing the canonical task identity.
The page sends the token only in the `Authorization` header for protected APIs.
By default the token stays in page memory.
Selecting **Remember access token** stores the validated token in same-origin browser local storage so that the page can reconnect after reload.
Anyone using that browser profile can then use the saved token, so leave the option off on shared devices and use **Forget / log out** to remove both saved and in-memory authorization.
If browser storage is unavailable, login still works for the current page and the page reports that it could not persist the token.
Rejected or expired saved credentials are removed instead of being retried.
The page starts from a clearly labelled recent tail for a large journal, can reload from byte zero, supports text and role/type filters, and polls for complete appended lines without a page reload.
The selected agent session displays its records newest first on initial load, reload, pagination, and live append while preserving the content order inside each record and the source JSONL bytes.
Task status and selected task documents refresh automatically while dashboard refresh is enabled.
Before the first task snapshot succeeds, counts show dashes instead of authoritative zeros, and the task lists distinguish loading and failure from a genuinely empty category.
Background task refresh keeps the last loaded counts and selection visible, while session selection and journal event reads remain available during task loading.
Repeated task overview reads within a short bounded freshness window reuse the last successful snapshot.
After that window, the viewer returns the last successful snapshot immediately with its age and background-refresh state instead of hiding useful task data behind a full inventory read.
While that generation remains current, subsequent dashboard polls return only freshness metadata and retain the existing Sidebar nodes instead of retransferring and rebuilding the unchanged task inventory.
A background refresh atomically replaces the complete snapshot only after it succeeds; failures remain visible without replacing the last successful task data, while a process with no successful snapshot still reports the read as unavailable.
All reader-facing timestamps are rendered in the fixed Asia/Shanghai time zone and labelled UTC+8; stored timestamps remain unchanged.
Standalone task reports are labelled by task and refresh automatically while follow mode is enabled.
Rendered reports and task briefs support headings, paragraphs, lists, blockquotes, tables, fenced code, and safe web or email links, with the complete plain source available below them.

## Reading boundaries

A final line without a newline remains pending until the writer completes it.
Malformed JSON is shown as a parse error with its original text rather than being dropped.
Valid lines up to 8 MiB are returned whole; a larger line is represented by an explicit omitted-line record with its byte count instead of silently clipped content.
Rotation and detectable truncation add an explicit boundary while the browser retains previously displayed events.

The viewer uses only local bundled HTML, JavaScript, and CSS.
Log text is inserted with browser text nodes, so journal content is never executed as HTML.
Report and task-brief Markdown is converted into explicit browser nodes without accepting raw HTML, dangerous link schemes, or image loads.
Task documents larger than 8 MiB are refused rather than truncated.

Run `bin/fm-test-run.sh tests/fm-jsonl-viewer.test.sh` for the portable authenticated task, report, and journal behavior suite.
Run `FM_JSONL_VIEWER_BROWSER_LIVE=1 bin/fm-test-run.sh tests/fm-jsonl-viewer-browser-live-e2e.test.sh` when the existing local Chrome CDP endpoint is available at `127.0.0.1:9333`.
The browser guard opens and closes only its own page and never launches or closes Chrome.
