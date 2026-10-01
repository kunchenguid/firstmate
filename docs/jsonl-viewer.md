# Agent journal and task report viewer

`fm-jsonl-viewer.mjs` provides a read-only browser view of one Firstmate home's ShortTask journals, supervision-branch sessions, and canonical task reports.
It reads only `state/short-agents/<short-id>/journal.jsonl`, `state/branch-session/*.jsonl`, and `data/<task>/report.md` below the selected canonical home.
It does not expose arbitrary paths, follow symlinks, modify a journal or report, or offer chat and lifecycle controls.

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

Open `http://SERVER:17847/`, enter the token in the page, and choose a journal or task report.
The token stays in page memory and is sent only in the `Authorization` header for protected APIs.
The page starts from a clearly labelled recent tail for a large journal, can reload from byte zero, supports text and role/type filters, and polls for complete appended lines without a page reload.
Task reports are labelled by task and refresh automatically while follow mode is enabled.
The rendered report view supports headings, paragraphs, lists, blockquotes, tables, fenced code, and safe web or email links, with the complete plain source available below it.

## Reading boundaries

A final line without a newline remains pending until the writer completes it.
Malformed JSON is shown as a parse error with its original text rather than being dropped.
Valid lines up to 8 MiB are returned whole; a larger line is represented by an explicit omitted-line record with its byte count instead of silently clipped content.
Rotation and detectable truncation add an explicit boundary while the browser retains previously displayed events.

The viewer uses only local bundled HTML, JavaScript, and CSS.
Log text is inserted with browser text nodes, so journal content is never executed as HTML.
Report Markdown is converted into explicit browser nodes without accepting raw HTML, dangerous link schemes, or image loads.
Reports larger than 8 MiB are refused rather than truncated.

Run `bin/fm-test-run.sh tests/fm-jsonl-viewer.test.sh` for the portable HTTP behavior suite.
Run `FM_JSONL_VIEWER_BROWSER_LIVE=1 bin/fm-test-run.sh tests/fm-jsonl-viewer-browser-live-e2e.test.sh` when the existing local Chrome CDP endpoint is available at `127.0.0.1:9333`.
The browser guard opens and closes only its own page and never launches or closes Chrome.
