---
name: playstudio-agent-loop
description: >-
  Agent-only PlayStudio agent-turn driver for Firstmate mates.
  Load before driving PlayStudio workspace agent turns without manual UI typing,
  running the blackjack multi-turn fixture, or calling entry-shell / runs BFF
  verbs (ensureSession, newProject, sendTurn, waitSettled, snapshotMessages,
  listCheckpoints, revertMessage, undoRestore).
user-invocable: false
metadata:
  internal: true
---

# playstudio-agent-loop

Load this before driving PlayStudio agent turns from a Firstmate mate session.

Drive the browser BFF with a cookie-attached Chrome session.
Do **not** call agent-host `:8081`.
Do **not** use password login or retired `demo-session` / `smoke.spec.ts` paths.

Authoritative product contracts live in PlayStudio (`next-app/lib/entry-shell/http.ts`, `next-app/lib/run-stream-ui/client.ts`).
This skill owns Firstmate mate procedure and the colocated driver only.

## Preconditions

1. Local PlayStudio stack healthy:
   - `GET http://localhost:3000/api/healthz` → `ok:true`
   - `GET http://127.0.0.1:8081/health` → `status:ok` (preflight only; never drive turns here)
2. Chrome attach with an Entra session already present (or completable interactively):
   - Prefer `CHROME_DEVTOOLS_AXI_AUTO_CONNECT=1` against the captain's SSO'd Chrome (remote debugging enabled).
   - Or `CHROME_DEVTOOLS_AXI_USER_DATA_DIR=...` / `CHROME_DEVTOOLS_AXI_BROWSER_URL=http://127.0.0.1:9222`.
3. Same-origin page context on `http://localhost:3000` so `fetch` carries `ps_entry_session` and CSRF `Origin`/`Referer`.

If studio-web or agent-host is down after a main pull, stop and report `blocked:` with the local restart command the captain's PlayStudio checkout already documents - do not invent stack ownership.

If agent turns fail with an expired AWS SSO token, refresh the PlayStudio runtime profile (see that checkout's `.env.runtime.local` / `AWS_PROFILE`) via `aws sso login --profile <profile>`, then retry - do not put credentials in the skill or transcripts.

If `ensureSession` stays `authenticated:false`, open `/sign-in`, let the human complete Entra (including MFA), and retry.
Never invent credentials.

## Driver

Colocated CLI (mechanics owner for flags and exit codes):

```sh
.agents/skills/playstudio-agent-loop/ps-agent-loop.sh --help
```

Set `FM_HOME` to the Firstmate home when writing artifacts (default prefers the captain home `data/playstudio-agent-loop/`, which is gitignored).

Suggested attach:

```sh
export CHROME_DEVTOOLS_AXI_AUTO_CONNECT=1
export CHROME_DEVTOOLS_AXI_SESSION=playstudio-agent-loop
export FM_HOME="${FM_HOME:-$HOME/projects/firstmate}"   # or this home's path
```

## Verbs

| Verb | Behavior |
|---|---|
| `preflight` | Health-check studio-web + agent-host |
| `ensureSession` | Attach Chrome; poll `GET /api/entry-shell/session` until `authenticated:true` |
| `newProject` | `POST /api/entry-shell/projects` → `{ project, workspaceUrl }` |
| `openWorkspace` | Navigate workspace URL; optional `POST /api/runs/session` |
| `sendTurn` | `POST /api/runs/start` with `{ projectId, prompt, sessionId? }` → `{ runId, sessionId }` |
| `waitSettled` | In-page SSE on `GET /api/runs/{runId}/stream` until `part.type === "done"` or `error` (mirrors `client.ts`) |
| `snapshotMessages` | Read accumulated SSE frames from the wait job (no public message list API) |
| `listCheckpoints` | Thin wrapper: `GET /api/runs/history` (may 501 when sandbox/history unavailable) |
| `revertMessage` | Thin wrapper: `POST /api/runs/restore` with `mode:"revert"` |
| `undoRestore` | Thin wrapper: `POST /api/runs/restore/undo` |
| `fixture-blackjack` | End-to-end multi-turn proof driver |

Reuse `sessionId` from the first `sendTurn` on every later turn.
Serialize turns: never start the next turn before `waitSettled` returns.

## Blackjack fixture

```sh
.agents/skills/playstudio-agent-loop/ps-agent-loop.sh fixture-blackjack
```

Flow:

1. `preflight` + `ensureSession`
2. Scratch project with a simple blackjack + How to Play prompt
3. Open workspace
4. Base turn, then feature turns on the same `sessionId` (double-down, stats, theme)
5. Write transcript under `$FM_HOME/data/playstudio-agent-loop/blackjack-<utc>/`

Artifact files (private, gitignored under `data/`):

- `preflight.json`, `session.json`, `project.json`
- `turn-N-start.json`, `turn-N-settle.json`
- `transcript.jsonl`, `summary.json`

Do not commit secrets, cookies, or raw auth material.

## Hard refusals

- No `POST /api/entry-shell/auth/demo-session`
- No password form automation
- No direct calls to `http://127.0.0.1:8081` for turns
- No PlayStudio primary-checkout edits from this Firstmate skill ship (optional PlayStudio `.cursor/skills` pointer is a follow-up)

## Follow-ups

- Full revert soak asserting history/SSE after `revertMessage`
- Optional thin PlayStudio `.cursor/skills/playstudio-agent-loop` pointer to this Firstmate skill
