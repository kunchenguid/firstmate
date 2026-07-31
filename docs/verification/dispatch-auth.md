# Dispatch authentication verification

Audience: maintainer verification.

This record supports the current selected-surface authentication guarantee in `bin/fm-auth-preflight.sh` and the dispatch rules in `.agents/skills/quota-array-dispatch/SKILL.md`.
It records only facts that must be re-established when a producer or vendor version changes.
Task chronology, incident transcripts, and credential metadata stay in private reports or PR evidence.

## Producer schema the surface resolution depends on

Verified 2026-07-30 against quota-axi 0.1.16.

`quota-axi auth --json` reports each provider's credential sources independently, which is what lets a candidate be scoped to the one surface it actually authenticates through:

```json
{
  "provider": "grok",
  "sources": [
    { "source": "auth-json", "path": "<home>/.grok/auth.json", "status": "available" },
    { "source": "pi:xai", "status": "available" }
  ]
}
```

Observed source statuses are `available`, `expired` (with an `error` slug), and `missing`.
`quota-axi --provider grok --json` carries `state.authStatus` with the values `usable`, `expired_refreshable`, and `unusable`, alongside `state.sourcesTried`.

Neither field exists before 0.1.16, so a surface cannot be scoped on an older build.
`bin/fm-bootstrap.sh` enforces that floor and `bin/fm-auth-preflight.sh` refuses rather than emitting an unscoped verdict.

OpenCode is a verified harness, but this producer schema does not model the selected OpenCode credential surface.
When its model has a valid provider/model relationship, the preflight emits `authStatus=unknown`, `headroom=unknown`, `reason=no-auth-evidence`, and `eligible=yes` without selecting a quota provider or probing another harness.
Malformed OpenCode model relationships and unverified harnesses remain ineligible.

Grok also reports `credits.remaining: 0` alongside `percentRemaining: 42` on a healthy account.
That zero is a prepaid balance, not the subscription window, and is never headroom.

## Standalone Grok discovery probe

Verified 2026-07-30 on `grok 0.2.112 (9bbd559437aa) [stable]`.

```sh
grok --version
grok models   # stdin closed, single attempt, hard-bounded
```

Observed:

- `grok models` exits `0` and its first stdout line is `You are logged in with grok.com.` for an authenticated session.
- The documented unauthenticated first line is `You are not authenticated.`, also with exit status `0`.
- Because the status is `0` in both cases, the exit status is not a verdict; only the literal first stdout line is examined, and a blank first line does not authenticate.
- `~/.grok/auth.json` was byte-identical across the authenticated run (`mtime`, `size`, and mode `0600` unchanged), so the probe is a read in that path.

These discriminator strings are un-owned vendor UI text.
`bin/fm-auth-preflight.sh` pins the verified version, reports `probeVersionVerified=no` when the running CLI differs, and classifies any unrecognized first line as `indeterminate` rather than authenticated.
Re-run the two commands above and update this section when the pinned version changes.

## Regression coverage

`tests/fm-auth-preflight.test.sh` drives the real script against nonsecret fixtures shaped like the output above.
It asserts the emitted verdict and, separately, which vendor CLIs were launched, so a Pi/xAI candidate reaching the Grok CLI fails the suite.
It also asserts that mixed known and unknown scopes remain unknown and that every resolved candidate receives exactly one post-preflight quota retry.
`tests/fm-bootstrap.test.sh` owns the quota-axi version-floor diagnostic.
