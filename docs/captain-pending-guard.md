# Captain-pending PreToolUse advisory

This document is the authoritative human-readable contract for the advisory that surfaces a captain-relevant fleet signal written while a primary turn is running.
`bin/fm-captain-pending-pretool-check.sh` is the single owner: pending-signal detection, deduplication, and output rendering all live in that script's header and body.
No harness adapter classifies anything; they only deliver the payload.

It is the fourth member of the family of primary-session PreToolUse guards that share the cross-harness hook machinery: the watcher-arm seatbelt (`docs/arm-pretool-check.md`), the cd-guard seatbelt (`docs/cd-guard.md`), and the delegation-shape guard (`docs/subagent-guard.md`).

## Why this exists

On the Claude primary the wake watcher runs between turns (the Stop auto-arm model, `docs/watcher-continuity.md`), so a status line written while the primary's turn is still running - a captain board answer relayed by a secondmate, a crewmate terminal verb - is not classified, not queued, and not presented until the turn ends.
The measured shape of that gap: median main turn 56 s, p90 243 s, max 770 s, and 38% of slow status lines landed mid-turn, so a captain answer routinely waited ten-plus minutes on the primary's own turn length.

The advisory closes that gap at the cheapest correct surface: the Bash tool boundary.
When a fleet status file has grown past the watcher's own seen marker with bytes the wake scan would treat as a signal, and the unread span holds a line `status_is_captain_relevant` (bin/fm-classify-lib.sh) already classifies as captain-relevant, the guard prints one `additionalContext` advisory naming the signal and asking the primary to finish the step and end the turn.

## What it does and does not decide

The guard decides only whether a captain-relevant signal is pending and unannounced.
It never blocks, denies, or rewrites the tool call, and it never deduplicates or suppresses the underlying wake: the durable wake queue, its presentation at the next turn start, and `bin/fm-guard.sh`'s queued-wakes warning all keep their existing ownership.
A pending wake-queue record without new status bytes is deliberately NOT this guard's signal - those rows persist until generation-bound acknowledgement and would nag while the primary is already handling them.

Pending detection reuses the wake-scan predicates, which is what makes the guard quiet at the right times:

- A line that woke this turn is not pending: the watcher advanced its seen marker before the turn started.
- Bookkeeping this home itself appended is not pending: the owned-append ledger (bin/fm-classify-lib.sh) already covers it.
- Growth the classifier does not call captain-relevant (`working:`, `resolved`, `captain-held:`, `paused:`, milestones, goals) is not pending.
- The parent channel's status file is excluded, as in every status scan.

Deduplication is per pending span: `state/.captain-pending-announced` holds one `<task>:<end-offset>` key per still-pending file, rewritten under a micro-lock at each announcement.
A long turn is announced once per span, and further growth produces a new span key and a fresh announcement.

## Scope and transports

The guard fires only where `fm_primary_root_matches` (bin/fm-primary-scope-lib.sh) confirms a genuine primary home: a plain checkout, or a linked secondmate home with its marker, both carrying `AGENTS.md` and `bin/`.
It is a silent no-op everywhere else, including crewmate and scout task worktrees, which keeps tracked settings inert where they propagate into linked worktrees.

The shipped registration is the tracked `.claude/settings.json` PreToolUse entry with the `Bash` matcher and the standard GROK marker guard, so on the Claude primary it runs at every Bash tool boundary - the boundary observed to dominate long turns - at a steady-state cost of about one stat call.
A foreign-host payload (`cursor_version`, bin/fm-hook-host-lib.sh) stands down because that host's own registration owns the event, and the payload stays Claude-shaped so pi-code reads it as Claude does.
`--check` renders the same advisory as plain text for any adapter that can run a command but not deliver Claude hook JSON; no adapter registration is shipped yet.

`FM_CAPTAIN_PENDING_GUARD=off` disables the advisory, `flag` (default) enables it.

## Fail-open rules

Everything the guard cannot read or parse is allowed silently: empty or malformed stdin, a missing jq, a non-Bash tool, an unknown flag, an unreadable primary, and any scan failure.
A seen marker the fast path cannot recognize always falls through to the owner-verified slow path, never to silence, and the slow path alone decides what is announced.

## Validation

`tests/fm-captain-pending-pretool-check.test.sh` pins the contract end to end: announcement content and Claude transport, one-announcement-per-span deduplication, re-announcement on growth, silence for already-seen content, non-captain growth, own bookkeeping, foreign-host payloads, non-Bash tools, malformed stdin, off mode, primary-scope inertness in linked worktrees, the fast/owner marker agreement, and the tracked registration.
