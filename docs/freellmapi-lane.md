# FreeLLMAPI lane

This document owns the fleet's usage policy for the optional FreeLLMAPI bulk/research lane.
`bin/fm-freellmapi.sh` is the single owner of the mechanics (install, start, status, seed-keys, stop); read its header and `--help` for exact commands and the secret-safety contract.
The lane is opt-in tooling only: nothing in firstmate dispatches to it automatically, and enabling it for any routing or profile path is a separate captain decision.

## What this lane is

FreeLLMAPI (https://github.com/tashfeenahmed/freellmapi, MIT) is a third-party local proxy that pools free-tier LLM provider keys behind one OpenAI-compatible endpoint on localhost, with automatic fallback across providers.
The fleet's verified evaluation of the upstream project - repo authenticity, key handling, prompt egress, realistic capacity - is `data/freellmapi-koeajo/report.md` (scout, 2026-07-24); this document does not restate it.
The install is pinned to the exact audited commit `526c8634` (2026-07-20); the pin changes only after re-verifying a new commit the way that report did.

## Allowed and forbidden use

Allowed - non-sensitive bulk and research work only:

- Summaries and classification over public material (public READMEs, issues, docs).
- Scout-style probe calls and cheap first drafts that a primary model later reviews.
- Experiments that need volume more than quality.

Forbidden - always:

- Any sensitive content: captain data, project source code that is not public, credentials, personal data, strategy.
- Use as a substitute for the primary model in real project work.
- Exposing the service beyond this machine: no `0.0.0.0`, no port forwarding, no tunnel, no reverse proxy.
- Paid production provider keys; the lane takes free-tier keys only.

Every prompt sent through the lane goes to third-party free providers, and some keyless providers may use prompts for training.
Treat everything sent through the lane as visible to those third parties.

## Known risks (stated, not hidden)

- The pinned dependency tree reported 21 npm audit vulnerabilities (3 critical, 7 high, 9 moderate, 2 low) on 2026-07-24, and `npm ci` executes dependency install scripts.
- Free-tier models follow instructions unreliably and empty completions are common; capacity numbers in upstream marketing are catalog-label sums, not deliverable throughput.
- Provider terms of service constrain use (for example NVIDIA free tier is eval-only); the lane operator remains responsible for respecting them.

`fm-freellmapi.sh install` restates the vulnerability findings on every run and refuses to proceed without `--accept-risks`.

## Running the lane

- Install once: `bin/fm-freellmapi.sh install --accept-risks` (pinned fetch, lockfile-pinned `npm ci`, build).
- Start: `bin/fm-freellmapi.sh start` - generates the mandatory `ENCRYPTION_KEY` on first start (never printed), binds to `127.0.0.1` only, and refuses to stay up unless the loopback-only binding is verified.
- Seed provider keys from the fleet's gitignored `.env`: `bin/fm-freellmapi.sh seed-keys google=GEMINI_API_KEY` - values travel via stdin and environment only, never argv or output.
- Check: `bin/fm-freellmapi.sh status`; stop: `bin/fm-freellmapi.sh stop`.
- Everything the lane stores (checkout, database, generated secrets, runtime records) lives under `$FM_HOME/data/freellmapi/`, which is gitignored and mode 0700.

Catalog sync to `api.freellmapi.co` is disabled by default so the lane has zero background egress; `start --catalog-sync` opts in to the signed metadata-only sync described in the scout report.

## Disabling and removing the lane

- Disable: `bin/fm-freellmapi.sh stop`; the lane stays installed but nothing runs and nothing routes to it.
- Remove completely: stop the service, then delete `$FM_HOME/data/freellmapi/`.
- Removal deletes the generated `ENCRYPTION_KEY` and with it access to every provider key stored in the lane's database; the original key material in the fleet `.env` is untouched.
