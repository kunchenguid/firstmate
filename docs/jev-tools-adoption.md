# Jev tools for this repository

The project-scoped Claude Code plugin `jev-safe` bundles pinned copies of the
fast-jev-compaction and winnow function hooks. `.mcp.json` registers the pinned
jev-mcp server. `bin/fm-jev-sessionstart.sh` loads `TYPESAFE_API_KEY` through
Firstmate's `.env` reader, starts the local scanner, and starts winnow. The MCP
launcher uses the same key reader and a Node fetch preloader. No credential is
stored in tracked settings.

The Jev MCP launcher and SessionStart hook require their pinned submodule
checkouts. Initialize them in a fresh clone with
`git submodule update --init .claude/upstreams/jev-mcp .claude/upstreams/winnow`;
each launcher prints its recovery instruction when its required files are
missing.

Before an attempted Jev request, the local gate runs Yelp detect-secrets on the
request body and rejects references to configured sensitive paths, including
`.env`, `state/`, `config/`, captain data, and health and finance pipeline
paths. It also rejects ordinary health-related terms and medical-context
phrases in the request body. That content filter is best-effort and is not a
complete detector for free-text health information. Rejected or unavailable
checks use each tool's fallback behavior. The focused tests independently cover
a synthetic GitHub-key-shaped string, clean text naming `data/captain.md`, and
synthetic health text.

Each Jev caller runs the shared scanner as a local child process before sending
the request body. No local HTTP listener receives payloads, so a port collision
cannot impersonate the safety gate.

The plugin and MCP server registrations are active. The path gate does not
establish coverage for shell-quoted paths assembled at execution (e.g. Bash
ANSI-C `$'...'` escapes) or Python paths assembled wholly inside a call
expression (e.g. string concatenation); both are structural limits of static
text matching, not fixable by extending the same parser, and were independently
verified as unfixable-by-this-mechanism on 2026-09-26. Layer-2 (this path gate)
is a supplementary, best-effort filter over literal path tokens, not an
execution-aware sandbox; layer-1 Yelp detect-secrets remains the actual
secret-detection control. The canonical 25-fixture set and remaining account
quota were unavailable; quota consumption for the synthetic sample is
reported below, but remaining quota was not exposed by the tools.

## Pinned upstream revisions

| Tool | Upstream revision |
|---|---|
| fast-jev-compaction | `e3f262a7f4d42bd8dd32ced30d26176f7cb545b0` |
| jev-mcp | `82720dfb3626b25807f3f58c6a8f77836cbdec4e` |
| winnow | `51d80b945c74c8384bc47fa817179f668289afd8` |

The plugin's vendored hook sources come from the first and third revisions
above; they add the local safety gate at the HTTP boundary. The full upstream
checkouts remain in `.claude/upstreams/` for provenance and updates.

## Authorized synthetic validation sample

The canonical 25-fixture set referenced by the IMAC HANDOFF was not found in
the repository or its `projects/IMAC` tree. Under the task decision, these
synthetic checks are the authorized substitute for this task, but they do not
claim a canonical fixture comparison. They used only synthetic text; no secret
or personal information was included in an allowed request. One request was
measured for each tool:

| Tool | Jev latency | Billable input tokens | Output tokens | Estimated input cost | Outcome |
|---|---:|---:|---:|---:|---|
| jev-mcp (`jev_verify`) | 1,780 ms end to end | 453 | 46 | $0.0000190 | verified synthetic claim |
| fast-jev-compaction | 505 ms Jev request; 775 ms total | 578 | 40 | $0.0000243 | compacted synthetic transcript |
| winnow | 701 ms judging; 2,226 ms end to end | 6,784 | not persisted by its event log | $0.0002849 | unchanged result (`nothing_to_prune`) |

Estimated cost uses TypeSafe's published $42 per billion input tokens; output
tokens are currently free. The three requests consumed 7,815 reported input
tokens. Remaining account quota was not exposed by the tools. The winnow event
log records input token use but not output token use.

## Safe-default checks

- `tests/fm-jev-safety-gate.test.sh` blocks the synthetic key and the excluded
  path independently; `tests/fm-jev-hook-guards.test.mjs` verifies fast-jev's
  unset-key and mocked-401 fallbacks and winnow's path-blocked pass-through.
- Upstream tests passed with `TYPESAFE_API_KEY` unset: jev-mcp 223 tests,
  fast-jev-compaction 29 tests, and winnow 80 tests. The test implementations
  exercise API error handling with mocks; no invalid credential was sent to
  TypeSafe.
- A successful fixture call verifies the scanner allowed only synthetic
  content. This sample does not establish complete PII detection for arbitrary
  content; sensitive source paths are rejected before content is sent.
