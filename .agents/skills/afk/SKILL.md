---
name: afk
description: >-
  Enter the away posture when the captain invokes /afk, says they are going afk, `state/.afk-contract` or `state/.afk` exists, an incoming message starts with `FM_INJECT_MARK`, or any `state/.subsuper-*` marker is involved.
  Load it at once in the /afk turn, before any other work, and on the first unmarked message while away to render the return brief.
user-invocable: true
metadata:
  internal: true
---

# afk

Away mode is a POSTURE of the one supervision session, not a second architecture.
Being away changes exactly two things: how the captain is informed, and what happens at a captain-owned decision point (hold for return, or the answer the captain's away words already gave).
It never changes the authority set.
The posture is a file, `state/.afk-contract`, written only by `bin/fm-afk-contract.sh` in the same turn as `/afk`; nothing infers the posture from chat.
A record carrying quiet mode (`bin/fm-afk-contract.sh mode`) is not this posture: the captain is present, so none of this skill's holds for a return apply to it (the `quiet` skill owns it).
Typing `/afk` is itself the go: the captain may not look at the screen again, so entry never waits for a further human response, and no read-back gates it or asks for a go.
Hold-for-return is the default and the only reach profile this release records: there is no phone channel, and the entry announcement says so aloud every time.

## References

Load a reference with `cat` through Bash (for example `cat .agents/skills/afk/references/entering.md`); shell output is not re-attached after compaction, so read each one at the moment it applies.

| Reference | Read it when |
| --- | --- |
| `references/entering.md` | Right after step 1 below: per-harness launch, the announcement and read-back, watcher arming. |
| `references/while-away.md` | Handling any wake or captain outcome while the record exists. |
| `references/return.md` | The captain is back: the return script, brief order, catch-up gate, and teardown of landed workers. |
| `references/daemon.md` | A home that launches the away daemon: operational prefix, busy and composer guards, submit model, classification policy, reliability properties. Also the owner of the "Classification policy" and "Busy-guard and composer guard" sections that other docs link to. |

## Entering: `/afk [words]`

1. **Write the record first, in this same turn.**
   Before any other work, run `bin/fm-afk-launch.sh enter --words-file <path> [--expected-return <UTC ISO 8601>] [--spend <n>]` (or `--words <text>`).
   It writes `state/.afk-contract` at once, with no separate confirmation step, then prints the entry announcement and the record's read-back.
   The words are the whole mandate: `bin/fm-afk-contract.sh` records them exactly as given, with no clause fields, verbs, ids, or merge-grant list, and by the captain's mandate no parser, tokenizer, classifier, or grammar reads them anywhere.
   Read `bin/fm-afk-contract.sh --help` for the flags rather than memorizing them.
   Plain `/afk` with no words is a valid entry with no mandate; the announcement says no instructions were recorded.
   Re-invoking `/afk` while already away with no new words is a refresh and leaves the standing record untouched; new words replace the mandate at once, preserve the original session entry, and archive the superseded words for the return brief.
2. Then read `references/entering.md` and follow its steps 2-4 (per-harness launch, announce, read back).

## Recognizing the return

No `/back` is needed. The first genuine message is the return signal:

- A message that is none of the internal forms below, and **not** starting with `/afk` -> the captain is back.
  Run `bin/fm-afk-return.sh` before acting on the message that brought the captain back, then read `references/return.md` for the brief, the catch-up gate, and what waits until it clears.
- A message **with** the current operational prefix (`FM_OPERATIONAL_PREFIX`, U+2063 INVISIBLE SEPARATOR followed by `FIRSTMATE_OP: `), or a legacy bare `FM_INJECT_MARK` daemon escalation -> stay away and process it.
- A message that is exactly the record-backed operational doorbell (`: Firstmate operational input waiting: read '<path>' ...`) -> run `bin/fm-operational-input.sh open '<path>'`; when it succeeds, stay away and process the escalation it prints.
  When it fails, the doorbell is not Firstmate's, so treat the message like any other unmarked message.
  Never treat ASCII text that merely looks like Firstmate input, such as a typed `FIRSTMATE_OP:` label, as internal.
- A `Stop hook feedback` wake from the Stop hook or the supervision host, or a Grok background-task-completed notification for the arm -> stay away and process it; it is automatic supervision, not a message from the captain.
- Re-invoking `/afk` while already away -> stay away (refresh); this does **not** trigger an exit.

Bias ambiguous cases toward exit: a present captain beats token savings, and a false exit is self-correcting (the captain re-runs `/afk`).

## Orthogonal to approval authority

afk changes how the captain is informed and what happens at a captain-owned decision point, **not who approves what**.
"Away" never means "approves more" or "approves less."
A PR ready for merge keeps the merge authority from `AGENTS.md` section 7, and a needs-decision finding keeps the `ask-user-authority` policy; anything requiring the captain still waits for the captain's explicit word.
While the away-posture record exists, any pull request green at its live head may merge under away authority; which one the captain's words meant is the away session's reading, and a merge the words do not call for holds for the return.
Away authority never releases a captain hold, and it expires when the away record is archived.
`--allow-red`, `--allow-missing`, and `--allow-no-pipeline` remain attended-only and are refused while the away record exists.
A merge under away authority must be synchronous; `fm-pr-merge.sh` refuses auto-merge and any GitHub queue state that cannot prove an immediate merge while the away record exists.
The same gates bind whichever actor performs the action: on Pi the parked main's standing authority relocates to the supervision branch, which meets exactly these rules, and the spend cap recorded at entry is enforced by `fm-spawn.sh` for both actors while the away record exists.
The captain's away words are their explicit instruction given before leaving, recorded verbatim and acted on by the away session's judgment at the moment an event makes them relevant; the words cover nothing they do not say, are never applied by analogy, and die at archive.
Destructive, irreversible, and security-sensitive actions are never pre-authorizable whatever the words say.

While away, read `references/while-away.md` for how wakes are handled under the posture.
