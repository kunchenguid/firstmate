# Fleet browser analytics-beacon block

Every fleet browser session runs through `chrome-devtools-axi`.
A session that lands on birdied production can fire PostHog analytics beacons that pollute the production project, and brief text alone cannot prevent that because a task can forget it.
So the block is structural: `bin/fm-spawn.sh` injects a launch flag into every crewmate pane before the agent starts, and the block is on by default with no brief text required.

`bin/fm-browser-guard.sh` owns the blocklist and emits the flag; read its `--help` for the exact subcommands.

## What is blocked

The guard blocks by host, routing matched hosts to a dead local proxy so the request fails without leaving the machine, and leaves everything else reachable:

- `posthog.com` and any `*.posthog.com` host (direct PostHog cloud ingest and app).
- `birdied.app` and `www.birdied.app`, the birdied production apex.

Staging and preview subdomains (for example `staging.birdied.app`), localhost, and every non-birdied site stay reachable.
A beacon aimed at the production apex from a staging page is still blocked, because the beacon is a separate request to `birdied.app`, while the staging page itself loads normally.

## Why host-level and not path-level

birdied routes its production web analytics through a first-party reverse proxy on its own domain (`EXPO_PUBLIC_POSTHOG_HOST=https://birdied.app/ingest`, HTTPS) specifically to dodge tracker blockers.
The obvious fix would be to block only the `/ingest` path and keep the rest of `birdied.app` loadable, but that is not possible in the headless browser the fleet runs:

- Chrome strips the path from HTTPS URLs before passing them to a proxy auto-config (PAC) script, so a PAC can only see the host for HTTPS and a per-path rule silently never matches.
- Headless Chrome does not load extensions, so a `declarativeNetRequest` rule (which does see full HTTPS URLs) cannot be used either.
- A forward proxy cannot see the path inside an HTTPS `CONNECT` tunnel without terminating TLS with an installed certificate authority.

So the only headless-viable way to stop the first-party `/ingest` beacon is to block its host.
The cost is that the fleet cannot load the production apex page itself; crewmates should work against localhost, staging, or preview instead, and the opt-out below covers a deliberate production visit.

## Opt-out

The opt-out is explicit, loud, and documented, for a genuine analytics-testing task or a deliberate production-apex visit.
Set `FM_BROWSER_ALLOW_ANALYTICS=1` in the environment the spawn runs in.
`fm-spawn` then skips the injection, prints a notice to firstmate, and sends a visible disabled marker into the crewmate pane.

For a direct or manual `chrome-devtools-axi` shell that firstmate or the captain runs outside a crewmate spawn, compose the flag with `eval "$(bin/fm-browser-guard.sh env)"`; it preserves any existing `CHROME_DEVTOOLS_AXI_CHROME_ARGS` value such as GPU flags.

## Coverage and known gaps

- The structural default covers crewmate browser sessions, which is where the fleet's automated sweeps run. A direct or manual `chrome-devtools-axi` invocation outside a crewmate spawn is not auto-protected; use the `env` composition above.
- Playwright configurations that ship inside individual project repositories are outside this repository's reach. This block does not reach them; a project that needs the same protection must add it in its own config, and this document does not claim otherwise.
- The offending production sweep fingerprints as a hosted or cloud browser session (en-US, San Jose egress, Chrome 139 to 151) that local tooling cannot reach. This block closes the local-fleet hole only; the hosted-browser hole is a separate captain decision, escalated on its own.

## Verification

`tests/fm-browser-guard.test.sh` pins the host decisions, the flag format, and the spawn injection with no browser, so CI enforces the logic.
`tests/fm-browser-guard-block-live-e2e.test.sh` proves the emitted flag actually blocks the requests in the real headless browser; it is opt-in behind `FM_BROWSER_GUARD_LIVE=1`.
Run the live guard after a `chrome-devtools-axi` upgrade and record the result in [`docs/verification/browser-guard.md`](verification/browser-guard.md).
