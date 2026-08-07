# reasonix-herdr — dispatching reasonix through a visible Herdr pane

Reached from [`SKILL.md`](../SKILL.md) when task = reasonix-dispatch and engine = herdr.

## Overview

The underlying tool (`/home/adrian/dev/subagent-factory/tools/reasonix-herdr-axi`) bridges `reasonix` and Herdr. It has two modes, both opening a new visible Herdr pane, since reasonix isn't in Herdr's native agent-detection list (`codex`/`claude`/`pi`/`opencode`/`omp`):

- **`dispatch` (default for real work, as of 2026-07-22)** — runs plain `reasonix-axi run` in the pane with a shell sentinel to detect completion. This is a genuine, interactive-capable foreground CLI process attached to a real PTY — if it ever asks a question live, you can answer it directly (see "Answering a live question" below). It correctly respects `[permissions] mode = "allow"` for ordinary tool calls, so most real work (file writes, migrations, actual coding tasks) sails through without stopping. Blind to `blocked` state in Herdr's own status field (nothing reports it), but that matters less than it used to since dispatch-mode tasks rarely actually block.
- **`watch`** — runs `reasonix serve` (its HTTP+SSE mode) in the pane, submits the prompt over `POST /submit`, and consumes the `GET /events` SSE stream to drive Herdr's status in real time: `turn_started`→`working`, `approval_request`/`ask_request`→`blocked` (pending question surfaced via `--state-label`), `turn_done`→`idle`. Good for live status visibility on read-mostly/research tasks. **Structural dead end for anything that can trigger an approval/ask request**: `reasonix serve` is a headless HTTP+SSE server — there is no CLI in this tool (or apparently in `reasonix serve` itself) to POST an actual approval decision back to it. A `watch` that goes `blocked` will sit there, correctly reporting `blocked`, until the full `--timeout` elapses and it's abandoned — the accurate status doesn't help you unblock it. Confirmed live 2026-07-22: a task hit `blocked: "approve: explore -"` (likely a subagent/profile-launch gate, not a plain reader tool call, since `[permissions] mode = "allow"` should cover plain readers) with no way to answer it short of closing the pane.

Facts to keep in mind:

- Every call costs real money (same per-call cost as `reasonix-axi`) **and** creates a real, visible Herdr pane. Don't reach for this when the user doesn't actually want to watch the task — use `references/reasonix-headless.md` (headless) when visibility doesn't matter.
- Default timeout is 600s for both commands.
- **`dispatch`'s `--timeout` bug (found + FIXED 2026-07-22): it never reached `reasonix-axi run`.** `dispatch`'s `--timeout` only ever bounded how long `reasonix-herdr-axi` itself waited for the pane's completion sentinel — `reasonix-axi run` has its own separate `--timeout` (default 600s) that was never receiving the forwarded value. A task bigger than 10 minutes would get silently killed by that internal default regardless of what you passed to `dispatch`. Confirmed live: a 12-file migration task died at `duration_ms: 600002` with `status: error` despite `--timeout 3600` on the `dispatch` call. **A `status: error` whose `duration_ms` lands suspiciously close to 600000 (or your last-known-good default) is very likely this exact failure mode, not a real task error** — check before treating it as a genuine failure. Fixed in `src/commands/dispatch.ts` (now forwards the same seconds value as `--timeout` to `reasonix-axi run`), rebuilt, live-verified.
- **Answering a live question in a `dispatch` pane**: since it's a real PTY, use `herdr pane read <pane_id> --source recent-unwrapped` to see what it's asking, then `herdr pane send-text <pane_id> "<answer>"` followed by `herdr pane send-keys <pane_id> Enter` to respond — same as typing into the terminal yourself. This does NOT work for `watch` panes (see above — headless server, nothing reads stdin).
- **`watch` mode's `--custom-status` bug (found 2026-07-21) is FIXED (2026-07-22).** It failed immediately against herdr 0.7.4 with `error: "herdr pane report-metadata failed: unknown option: --custom-status", code: HERDR_FAILED` — that version of `herdr pane report-metadata` only accepts `--state-label STATUS=TEXT`, no free-standing `--custom-status` flag. Fixed in `src/herdr.ts`'s `reportCustomStatus` (now takes a `state: AgentState` param, calls `--state-label ${state}=${text}`), rebuilt, live-verified. Unrelated to the approval-gate dead-end above — that's a design limitation, not a bug, and isn't fixed by this.
- **Long dispatches must be detached**, same lesson as `references/reasonix-headless.md`'s Step 3.5: running `reasonix-herdr-axi dispatch "..."` as a plain foreground Bash tool call is subject to the harness's own timeout (confirmed: a 10-minute call died mid-task with no reasonix-side error, `--timeout 900` passed to the CLI notwithstanding — the harness's own limit killed it first). For anything expected to take more than a couple minutes, background the call (`... > /tmp/some.log 2>&1 &` or the harness's own background-run option) and poll `reasonix-herdr-axi status <pane_id>` / tail the log instead of blocking a single tool call on it.
- **Long or special-character-heavy prompts: load from a file, don't inline a double-quoted string.** Confirmed live 2026-07-22: wrapping a long prompt in double quotes inside a Bash tool call, where the prompt itself contains backtick-quoted code spans (e.g. `` `npm run dev` `` for markdown formatting), makes the shell perform command substitution on those backticks *before* the string ever reaches `reasonix-herdr-axi` — actually executing `npm run dev` and hanging on it for as long as that command runs (a dev server never exits, so this hung indefinitely; zero reasonix cost was incurred since the dispatch never actually started). Fix: write the prompt to a file, then pass it as `"$(cat /path/to/prompt.txt)"` — command substitution output is inserted verbatim and is never re-parsed for further expansion, so backticks/quotes/dollar-signs inside the file are always safe regardless of content.
- **A killed `dispatch` (or `watch`) can still leave real, coherent work uncommitted** — same as a killed headless dispatch. Confirmed twice: once from a harness-level kill (7-file implementation, uncommitted), once from the `--timeout` bug above (a 9-file panel-shell architecture, uncommitted, cut off mid-migration). Always `git status`/`git diff` and review before redispatching. **To resume a killed session, prefer `--resume <exact-session-path>` over `--continue`** — `--continue` resumes the *newest* saved session, which can silently be the wrong one if any other reasonix call (even an unrelated verification ping) happened afterward. Find the right file with `find ~/.reasonix/projects/-<project-path-with-dashes>/sessions -iname "*<timestamp-or-session-id>*"` (the session id is in the failed/timed-out run's own JSON output, e.g. `session_id: 20260722-062827.338351146-deepseek-flash` → look for `.jsonl` under `~/.reasonix/projects/.../sessions/`), then `reasonix-herdr-axi dispatch "<followup prompt telling it what's already done and what's left>" --resume <path> --copy --dir <path> --timeout <seconds>`.
- The prompt must be self-contained, same discipline as any subagent dispatch — reasonix has none of the conversation's context.

## Step 1 — Dispatch or watch?

IF the task does or might do real work (file writes, edits, running commands, an actual implementation task) — i.e. most dispatches:
→ Use `reasonix-herdr-axi dispatch "<self-contained prompt>" [--dir <path>] [--model <name>] [--timeout <seconds>]` (load the prompt from a file via `"$(cat ...)"` if it's long or has backticks/quotes — see Overview). This is the default now: `--timeout` correctly reaches `reasonix-axi run` (fixed 2026-07-22), it respects `[permissions] mode = "allow"` for ordinary tool calls so it rarely actually blocks, and if it *does* ask something live you can answer it directly via `herdr pane send-text`/`send-keys` (see Overview) — unlike `watch`, which cannot be answered at all.

ELSE IF the task is read-only/research-flavored and you specifically want live Herdr status visibility (working/blocked/idle) while it runs, AND it's genuinely unlikely to need any approval:
→ `reasonix-herdr-axi watch "<self-contained prompt>" [--dir <path>] [--model <name>] [--timeout <seconds>]`. If it goes `blocked`, there is currently no way to unblock it — close the pane and redispatch via `dispatch` instead rather than waiting out the timeout.

IF the response's `watch.status`/`dispatch.status` is `"success"`:
→ treat the relayed text as the answer — verify anything load-bearing before acting on it, same discipline as any subagent report. Don't assume it's correct just because it succeeded.

**Don't rely solely on either mode's own self-reported status.** Independently confirm via plain `herdr` commands when it matters — `herdr pane list`/`herdr pane get <id>` for status, `herdr pane read <id> --source recent-unwrapped` to read the pane's actual terminal output — before ever deciding to redispatch a task whose outcome seems unclear. This matters most on ambiguous outcomes (a timeout, an unexpected error, a harness-level kill) where trusting the wrapper's own report at face value risks double-paying for a task that's actually still running or already finished. `watch` mode's real-time `reportAgentState` calls DO make `herdr`'s own `agent_status` field trustworthy now that the bug is fixed (it's explicitly set via the herdr API, not inferred from TUI pattern-matching reasonix isn't in Herdr's native detection list for) — but a fresh direct pane read costs nothing and removes any doubt.

ELSE IF `"error"`:
→ read the relayed text/`error` field for why. Don't retry blindly — fix the prompt and redispatch once, or fall back to doing the task directly.

ELSE IF `"timeout"`:
→ go to Step 3.

## Step 2 — Check on a pane later

Run: `reasonix-herdr-axi status <pane_id>` for one pane, or `reasonix-herdr-axi list` to see every reasonix pane in the current Herdr workspace.

`agent_status` will be `working` (still running), `idle` (finished, pane currently focused/seen), or `done` (finished, pane was in the background when it completed) — `idle` and `done` are the same underlying state, just seen vs. unseen. Neither `status` nor `list` currently surfaces the task's final `exit_code` — only `dispatch`'s own immediate return does (see Step 3's limitation).

## Step 3 — A dispatch or watch timed out

IF it was a `watch` timeout:
→ check `status <pane_id>` — the Herdr status is trustworthy here (unlike `dispatch`): `working` means genuinely still running, `blocked` means it's sitting on an approval/question you haven't answered (read `custom_status` for what it's asking). Either way, the `reasonix serve` process is still alive with the port still bound — there is currently no CLI command to reconnect and submit a follow-up or re-subscribe, so treat it as unrecoverable *through this tool* for now, but don't tell the user the outcome is unknown — the status IS known, just not resumable yet. Offer to dispatch a fresh, standalone task instead.

ELSE (it was a `dispatch` timeout, OR a `status: error` whose `duration_ms` looks like a disguised timeout — see Overview):
→ Check the working tree first (`git status`/`git diff`) — real, coherent work is often already there uncommitted.
→ Find the exact session file rather than trusting `--continue` (which resumes the *newest* session, not necessarily this one): the failed run's own output includes `session_id: <timestamp>-<model>`; find its `.jsonl` under `~/.reasonix/projects/-<project-path-with-dashes>/sessions/`.
→ Redispatch with `reasonix-herdr-axi dispatch "<followup prompt describing what's already done and what's left>" --resume <exact-path> --copy --dir <path> --timeout <bigger seconds>` in a fresh pane, rather than starting from scratch.

## Notes for future updates

| Question | Action |
|---|---|
| New failure mode not covered? | Add it to Step 1 or Step 3 |
| A `watch resume`-style command landed (reconnect to a still-running `reasonix serve` after timeout)? | Update Step 3's `watch` branch and the Overview's known-limitation note with the real usage |
| Cost or timing behaved differently than documented? | Update the Overview |
| SSE event schema changed upstream (new/renamed `kind` values)? | Update the Overview's event→state mapping |

If anything changed, snapshot the parent skill (`../SKILL.md` → `../SKILL.v<N+1>.md`) and add a row to `../VERSIONING.md`.
