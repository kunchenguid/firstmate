# Task, report, and agent journal viewer

`fm-jsonl-viewer.mjs` provides a read-only browser dashboard for one Firstmate home's tasks, canonical task documents, ShortTask journals, and supervision-branch sessions.
Task discovery and classification use the structured fleet snapshot, task lifecycle disposition, current backlog, and configured Done archive rather than the last status-log line.
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

Open `http://SERVER:17847/`, enter the token in the page, and choose the task dashboard, a journal, or a task report.
The dashboard separates processing, waiting or blocked, completed, and archived or cancelled tasks.
`Processing` counts tasks marked active, in flight, or working only when no hold condition applies.
`Waiting or blocked` counts tasks that are queued, parked, explicitly blocked, waiting on a dependency or open decision, or need lifecycle reconciliation, so they are excluded from `Processing` even if another current record still says working.
Each task opens its canonical Markdown report when present, otherwise its canonical brief, and labels which document type is shown.
Tasks with a canonical report also provide an explicit Open task report action that switches to the report view without changing the canonical task identity.
The page sends the token only in the `Authorization` header for protected APIs.
By default the token stays in page memory.
Selecting **Remember access token** stores the validated token in same-origin browser local storage so that the page can reconnect after reload.
Anyone using that browser profile can then use the saved token, so leave the option off on shared devices and use **Forget / log out** to remove both saved and in-memory authorization.
If browser storage is unavailable, login still works for the current page and the page reports that it could not persist the token.
Rejected or expired saved credentials are removed instead of being retried.
The page starts from a clearly labelled recent tail for a large journal, can reload from byte zero, supports text and role/type filters, and polls for complete appended lines without a page reload.
Task status and selected task documents refresh automatically while dashboard refresh is enabled.
Before the first task snapshot succeeds, counts show dashes instead of authoritative zeros, and the task lists distinguish loading and failure from a genuinely empty category.
Background task refresh keeps the last loaded counts and selection visible, while session selection and journal event reads remain available during task loading.
Repeated task overview reads within a short bounded freshness window reuse the last successful snapshot and show the cache age, while refresh failures remain visible without replacing the last successful task data.
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
