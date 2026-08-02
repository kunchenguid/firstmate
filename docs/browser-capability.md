# Browser capability

Firstmate has a disabled-by-default browser custody command at `bin/fm-browser.sh`.
It is the only supported entry point for Firstmate-owned browser sessions.
Do not use raw `agent-browser`, raw `chrome-devtools-axi`, Chrome profiles, CDP endpoints, or browser extensions as substitutes for this owner.

## Current supported behavior

The current core is intentionally conservative.
It can create public-ephemeral plans and run mocked lifecycle tests when `FM_BROWSER_MOCK_ENGINE=1` and an enabled test policy are present.
It refuses real browser launch.
It refuses authenticated, durable, personal-profile, private/local/admin, upload/download/capture, extension, and write-capable modes.

## Configuration

Browser policy is local and gitignored at `config/browser-policy.json`.
Absent policy means disabled.
The current schema is:

```json
{
  "schema": "fm-browser-policy.v1",
  "enabled": false,
  "maxActiveSessions": 1,
  "anonymousIdleSeconds": 1200,
  "anonymousHardSeconds": 7200,
  "defaultExpiry": "alert-only",
  "allowedAuthClasses": ["anonymous"]
}
```

Setting `enabled` to true does not enable real browser launch in this core.
It enables only the mocked lifecycle used by portable tests unless a later verification record says a real engine mode is supported.

## Basic commands

Inspect capabilities:

```sh
bin/fm-browser.sh capabilities --json
```

Plan an anonymous public browser session:

```sh
bin/fm-browser.sh plan --task demo --origin https://example.com --allow-origin https://www.iana.org --json
```

Inspect existing local browser records:

```sh
bin/fm-browser.sh inspect --all --json
```

Reconcile after restart without taking action:

```sh
bin/fm-browser.sh reconcile --all --inspect-only --json
```

## Refusals to expect

A real `open` refuses unless a later verified engine mode is implemented.
Private and local origins refuse before any engine execution.
Write-capable actions refuse in v1.
Typing requires `--value-file` so page text is not passed on the command line.
A task with an unclean browser binding blocks task cleanup until `bin/fm-browser.sh close --handle <handle>` succeeds or the record is inspected and resolved.

## Future proof stages

The next supported stage is an opt-in public visible smoke on the Mac Mini.
That smoke must prove exact owned foreground visibility, `https://example.com` to IANA navigation, default refusal of a private/local URL and forbidden verb, exact cleanup, and repeated-cycle no-growth evidence.
Authenticated LinkedIn analytics is a later stage and must not be claimed from this disabled core.
