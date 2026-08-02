# Claude context compaction recovery

This document is the authoritative contract and empirical record for Firstmate's Claude Code context-compaction bridge.

## Contract

Tracked `.claude/settings.json` registers `bin/fm-autocompact.sh capture` for `PreCompact` and `bin/fm-autocompact.sh recover` for `SessionStart` with matcher `compact`.
The capture phase first atomically replaces `data/autocompact-resume.md` with the same deterministic view of durable fleet state used before judgment capture was added.
The anchor includes the full backlog, every in-flight `state/*.meta` file, and the complete local-only bearings projection with current task state, open decisions, held queued work, recorded PRs, reports, endpoint health, task paths, and next actions.
Hook payload parsing does not require `jq`; when `jq` is unavailable, capture logs a loud limitation and publishes the complete raw backlog and metadata while marking the derived bearings projection unavailable.
The deterministic phase makes no GitHub or other network call.
An in-scope capture failure exits 2 and blocks compaction rather than silently crossing the boundary without a fresh anchor.

After the deterministic anchor is durable, capture runs `bin/fm-autocompact-judgment.py` as an additive judgment phase.
The worker extracts human-visible user and assistant text plus prior compact summaries from the hook's `transcript_path`, snapshots the current private-memory and backlog destinations, and supplies those snapshots with the canonical `stow`, knowledge-routing, and `memory-hygiene` contracts to a separate Claude process.
That process runs with safe mode, no tools, no session persistence, a structured-output schema, and no inherited `CLAUDECODE` or project-hook environment.
The transcript is untrusted evidence rather than executable instructions.
The model may propose exact inspect-then-update edits only for `data/captain.md`, `data/learnings.md`, and `data/backlog.md`.
Knowledge that belongs in a project `AGENTS.md` or shared tracked Firstmate material is routed to backlog work for later normal delivery; the hook never writes a project or tracked Firstmate file.

The worker validates the path allowlist, edit count, edit sizes, exact old text, uniqueness, final file sizes, and result consistency before publication.
It takes a nonblocking home-local judgment lock, then compares every changed destination with its original snapshot under the shared data-writer lock immediately before staging the transaction journal and publishing the replacements.
If a destination changed while the model was running, no proposed change is published.
Accepted destination files are written to same-directory mode-0600 temporary files, fsynced, and atomically replaced.
This prevents a concurrent Firstmate write from being overwritten or a partial destination file from being exposed.

The anchor is deliberately published first with a plain `Judgment capture: FAILED` warning as its absolute first line.
Only a completed worker can atomically upgrade that line to `COMPLETE` or `LIMITED`.
A missing runtime, unreadable transcript, rejected model result, worker error, timeout, concurrent destination change, or outer hook kill therefore leaves a loud statement that captain preferences, corrections, and operational learnings may have been lost.
Any publication that reached a destination before failing is labeled `FAILED - PARTIAL` and never `COMPLETE`, even when journal recovery restores the prior consistent generation.
Judgment failure returns success from the capture hook after preserving that warning, so compaction degrades to the already-durable deterministic bridge instead of consuming the whole hook timeout or discarding fleet state.
Deterministic capture failures retain their existing exit-2 blocking behavior.

After compaction, Claude Code emits a new `SessionStart` event with `source=compact` before the next model request.
The recovery phase prints the fresh anchor and the output of `bin/fm-session-start.sh` to stdout.
If its compact-scoped hook payload is unreadable or invalid, recovery prints a loud warning and still emits durable context; only a successfully parsed non-compact `SessionStart` is a silent no-op.
Claude Code adds that stdout to the compacted context, so Firstmate receives the normal lock, bootstrap, wake-queue, backlog, task, status-tail, endpoint, and supervision reconciliation before it resumes.
That injected digest is the resumed session's single session-start pass; Firstmate does not run `bin/fm-session-start.sh` again after control returns to the model.
The compact summary is explicitly treated as lossy and subordinate to those durable sources.
The normal session-start digest reads any newly routed captain preference, fleet learning, or backlog update on the far side, while the anchor states whether transcript judgment completed.

The tracked hook is inert in a non-Firstmate repository and in an unmarked linked crewmate or scout worktree.
A valid secondmate home is in scope because it is a Firstmate primary in its own home.
The existing `Stop` and `PreToolUse` hooks remain separate and unchanged.

## Bounded judgment budget

Claude Code 2.1.220 documents a 600-second default timeout for ordinary command hooks and permits a per-handler timeout in seconds.
The tracked `PreCompact` handler pins a smaller 180-second outer budget instead of relying on that default.
The judgment subprocess gets 120 seconds and is launched in its own process group; on deadline, the worker terminates the group, waits two seconds, and force-kills any survivor.
That leaves 60 seconds of explicit outer headroom for the deterministic bearings capture, transcript extraction, validation, atomic publication, and anchor-status update.
The transcript scan is capped at 100 MiB, individual records at 1 MiB, the complete model input at 600,000 bytes, the result at 12 edits, and every destination at a type-specific size limit.
When transcript content must be truncated to fit that bound, accepted findings may still be routed but the anchor says `LIMITED` and warns that knowledge may have been lost.
Tool and thinking content is not captured, and conversation beyond the scan, input, record, or edit limits can be lost.
If the worker, runtime, model, validation, timeout, or concurrency path fails, all otherwise uncaptured judgment can be lost; the deterministic anchor remains available with its top-line failure warning.

The timeout values are grounded in the installed harness and the current [Claude Code hook timeout contract](https://code.claude.com/docs/en/hooks-guide), not an assumed shell lifetime.
The 2026-08-02 real-worker reproduction below completed judgment capture in 7 seconds inside the 120-second inner budget.

`PreCompact` stdout is not the recovery transport.
Manual compaction records successful hook stdout as local-command output, but automatic compaction has no equivalent user command boundary and Claude's documented context-output contract reserves direct stdout injection for events including `SessionStart`.
The compact-sourced `SessionStart` hook is therefore the reliable transport for the anchor and reconciliation digest.

Interactive `stow` remains the operator-owned sweep for explicit reset, handoff, and periodic memory-curation boundaries.
The PreCompact worker reads that skill's tracked contract at runtime rather than creating a second routing policy.

## Empirical validation - 2026-07-22

Event discovery ran in a git-initialized scratch project under `/tmp`, with project-only Claude settings and an isolated event log.
The implementation proof ran in a plain git fixture under the task worktree with an explicit fixture `FM_HOME`, and no tracked hook was registered into the live Firstmate primary settings.

Claude Code version at the final probe was `2.1.217` on Darwin.
The scratch settings registered logging commands for `PreCompact`, `PostCompact`, and `SessionStart` matcher `compact`.

Manual probe command:

```text
claude --setting-sources project --dangerously-skip-permissions --model haiku --no-chrome
/compact empirical manual probe
```

The successful manual event payloads were:

```text
PreCompact:  {"hook_event_name":"PreCompact","trigger":"manual","custom_instructions":"empirical manual probe"}
SessionStart: {"hook_event_name":"SessionStart","source":"compact","model":"claude-haiku-4-5-20251001"}
PostCompact: {"hook_event_name":"PostCompact","trigger":"manual","compact_summary":"TURN_FOUR"}
```

Automatic probe command and setup:

```text
CLAUDE_CODE_AUTO_COMPACT_WINDOW=20000 CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=50 \
  claude --setting-sources project --dangerously-skip-permissions --model haiku --no-chrome
```

The scratch session accumulated bounded repeated Bash results until Claude displayed `Running PreCompact hooks`, compacted in the middle of the autonomous turn, ran the compact-sourced `SessionStart` and `PostCompact` hooks, and then resumed the same turn to its requested terminal response.
The successful automatic event payloads were:

```text
PreCompact:  {"hook_event_name":"PreCompact","trigger":"auto","custom_instructions":null}
SessionStart: {"hook_event_name":"SessionStart","source":"compact","model":"claude-haiku-4-5-20251001"}
PostCompact: {"hook_event_name":"PostCompact","trigger":"auto","compact_summary":"<generated summary>"}
```

The event order for both successful paths was `PreCompact`, compact-sourced `SessionStart`, then `PostCompact`.
The manual probe also showed that `PreCompact` fires before an attempted `/compact` that later reports `Not enough messages to compact`, so capture must be safe and replace the prior anchor idempotently.
The implementation proof then compacted a fixture Firstmate session through the tracked commands, confirmed that the anchor held fixture backlog and PR markers, and asked the resumed model to repeat backlog, status-tail, and PR markers without reading files.
The model returned `RECOVERED:E2E_BACKLOG_ANCHOR_7421:E2E_IN_FLIGHT_ANCHOR_8842:9999`, proving that compact-sourced `SessionStart` stdout carried both the anchor and normal reconciliation into the resumed context.
Automated coverage in `tests/fm-autocompact.test.sh` verifies atomic refresh, complete pickup surfaces, failure blocking, primary scoping, tracked registration, and post-compact anchor plus session-start recovery.

## Judgment validation - 2026-08-02

The judgment implementation was exercised with Claude Code 2.1.220 on Darwin in a throwaway home under the disposable task worktree, never against `/Users/dongkeun/firstmate-home`.
Claude Code first produced a real persisted JSONL transcript in an isolated `CLAUDE_CONFIG_DIR` from this prompt:

```text
Standing preference for all future work: completion summaries must put unresolved risks before accomplishments. Acknowledge briefly.
```

The isolated transcript-generation process lacked its own login and returned `Not logged in`, but Claude Code had already persisted the real user message with `type=user`, `message.role=user`, `promptSource=sdk`, `entrypoint=sdk-cli`, session id, version, timestamp, and working-directory fields.
This made the transcript a real harness artifact while keeping all session files inside the throwaway fixture.
The authenticated judgment worker then consumed that transcript through the same hook command used by tracked `PreCompact`:

```text
printf '%s\n' '<PreCompact JSON naming the real transcript>' |
  FM_ROOT_OVERRIDE="$throwaway_root" FM_HOME="$throwaway_home" \
  bin/fm-autocompact.sh capture
```

The command completed in 7 seconds and the anchor began:

```text
Judgment capture: COMPLETE - the bounded transcript review routed durable knowledge atomically to data/captain.md.

# Autocompact resume anchor
```

Before capture, the only captain memory was `Prefer concise operational reports.`
After capture, `data/captain.md` also contained the memory-hygiene rewrite:

```text
- In completion summaries, list unresolved risks before accomplishments.
```

Running the compact-sourced recovery command against the same throwaway home printed that new preference in the normal session-start context digest.
This proves that conversation-only judgment crossed the hook boundary onto disk and was surfaced after compaction rather than merely looking plausible in code.

The focused behavior suite additionally replaces Claude with controlled subprocesses to prove that a worker error leaves a loud deterministic anchor, a 1-second worker timeout terminates well inside the 180-second outer budget, and a concurrent `captain.md` change is never overwritten.
Multi-file judgment publication records a durable before-image journal before replacing any destination, removes that journal only after every destination and the data directory are durable, and attempts to reconcile an interrupted transaction under the shared writer lock before the hook finalizes its anchor status or any later capture, compact recovery, or ordinary memory writer can proceed.
If reconciliation itself fails, PreCompact still publishes a fresh deterministic anchor and compact-sourced SessionStart still prints that anchor plus normal reconciliation; both return zero while putting the categorical `FAILED - PARTIAL` alarm first instead of suppressing deterministic recovery.
The suite kills the publisher after its first destination replacement and verifies that the same hook restores the complete prior generation and clears the journal before returning.
