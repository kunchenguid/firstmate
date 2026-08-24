# Verification: fleet browser analytics-beacon block

Active empirical evidence for the default-on browser analytics block.
[`docs/browser-guard.md`](../browser-guard.md) owns the operating facts; this record owns how they were established and what is still unproven.

## Subject

| Field | Value |
|---|---|
| Tool | `chrome-devtools-axi` |
| Version | `0.1.29` |
| Verified | 2026-08-24 |
| Platform | Linux x86_64 (headless Chrome, the fleet default) |

## What a stub cannot see

The block relies on vendor behavior that only a real browser confirms: that headless Chrome honors `--proxy-pac-url` as a `data:` URL, routes a blocked host to a dead proxy with no `DIRECT` fallback so the request fails, and leaves everything else reachable.
Two headless facts were established during design and are the reason the guard blocks by host rather than by path:

- Chrome strips the path from HTTPS URLs before a PAC script sees them, so a `*/ingest*` path rule silently never matches over HTTPS. Observed directly: with a path-based PAC, `https://eu.i.posthog.com` (host match) was blocked while `https://birdied.app/ingest/e/` (path match) was reached.
- Headless Chrome does not load extensions. A `--load-extension` content script never ran, so a `declarativeNetRequest` path rule is not available either.

## Verified facts

The live guard `tests/fm-browser-guard-block-live-e2e.test.sh` was run against a local server and a local logging proxy, so no request left the machine.

```
$ FM_BROWSER_GUARD_LIVE=1 bash tests/fm-browser-guard-block-live-e2e.test.sh
ok - live: guard flag blocks birdied apex, its /ingest beacon, and PostHog cloud while normal traffic still flows
ok - live: without the block, the analytics request is delivered (opt-out opens it)
# live browser analytics guard verified against 0.1.29
```

Case 1 opens the real headless browser with the exact flag `bin/fm-browser-guard.sh chrome-args` emits and probes five URLs from the page.
`http://birdied.app/` (force-upgraded to HTTPS by the HSTS-preloaded `.app` TLD), `https://birdied.app/ingest/e/`, `https://eu.i.posthog.com/e/`, and `https://posthog.com/` were each blocked; a same-origin request to the local server was reached and recorded in the server's hit log.
The blocked probes were routed to the dead proxy `127.0.0.1:9`, so none reached birdied or PostHog.

Case 2 opens the browser with no block, routing through a local logging proxy, and navigates to `http://birdied.app/ingest/optout-probe`.
The proxy recorded a `CONNECT birdied.app:443` entry, proving the analytics request is delivered when the block is absent, and that the block is what stops it.
The proxy closes the tunnel without connecting out, so this too never egressed.

## What is not covered here

- This record covers the local headless fleet browser only. The hosted or cloud browser session that produced the original production pollution (en-US, San Jose egress, Chrome 139 to 151) is out of local tooling's reach and is a separate escalated decision.
- The spawn injection and the host-decision logic are pinned portably in `tests/fm-browser-guard.test.sh`, which runs in CI without a browser; this record does not re-establish them.

## Refresh

Re-run the command above after a `chrome-devtools-axi` upgrade and update the version and date in this record.
