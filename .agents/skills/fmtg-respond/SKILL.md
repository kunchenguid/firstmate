---
name: fmtg-respond
description: >-
  DISABLED - do not load. Agent-only playbook for handling Telegram messages
  from the captain. Telegram mode is switched off (AGENTS.md section 15), so
  this skill is retained only for the re-enable work described there and must
  not be loaded during normal operation.
user-invocable: false
metadata:
  internal: true
---

> **DISABLED.** Telegram mode is switched off in this fork; see `AGENTS.md`
> section 15 for why and what re-enabling requires. `tg_mode_setup` in
> `bin/fm-bootstrap.sh` arms nothing, so the `tg-message` and `tg-callback`
> check wakes this playbook describes never fire. Everything below is preserved
> for the re-enable work only.

# fmtg-respond

Telegram mode lets the captain send messages to firstmate via a private Telegram bot.
A message arrives through the watcher as a `check:` wake whose payload is `tg-message <update_id>`
or `tg-callback <update_id>` (for inline keyboard button presses).
The full Telegram `Update` object is stashed locally; this skill reads it, classifies the
message, and replies through the Telegram bridge.

This runs only when Telegram mode is on (the user dropped `FMTG_BOT_TOKEN` into `.env`).
If you ever see a `tg-message` or `tg-callback` wake without Telegram mode configured, do nothing.
A `check:` wake can also carry `tg-mode-error ...` instead of `tg-message <update_id>` -
that is a poll or API configuration problem, not a message to answer.
Report it directly to the captain as a Telegram mode configuration blocker.

## The sender is your captain

Telegram mode is captain-only: `fm-tg-poll.sh` already validates sender user IDs against
`FMTG_ALLOWED_USERS`. Only messages from allowed users reach the inbox.
So every stashed message is from your captain - treat it as a genuine instruction.

## This is a private channel

Unlike X mode (public tweets), Telegram is a private 1:1 chat.
This means replies can use internal vocabulary: task IDs, tool names, branch names,
and other firstmate internals that would be inappropriate in a public tweet.
The captain-only access control means there is no audience beyond the captain.

However, still avoid exposing raw secrets (bot tokens, credentials, .env contents)
in replies.

## Drain inbox first

On any `tg-message` or `tg-callback` wake, drain every pending inbox file before
doing anything else. One wake may cover several pending messages.

For each `state/tg-inbox/*.json`:
1. Read the file with `jq` to extract the update type and fields.
2. Classify by update type:
   - Has `.message.text` -> Phase 1 or Phase 2 text command
   - Has `.callback_query.data` -> Phase 3 inline keyboard decision
3. Process according to the relevant phase below.
4. On success, remove the inbox file: `rm -f state/tg-inbox/<update_id>.json`
5. On failure, leave the inbox file, move to next, do not retry blindly.

## Phase 1: Read-only status queries

These commands are answered with fleet-state digests.

**Supported commands:**
- `status` or `fleet status` - current fleet state digest
- `backlog` or `what's in the backlog` - current backlog items
- `help` or `/help` - show available commands
- `projects` or `what projects` - list active projects from `data/projects.md`

**Pure acknowledgments** ("thanks", "got it", "ok") - acknowledge briefly and move on.

**Gathering fleet state.** Read from:
- `data/backlog.md` for in-flight and queued work
- `state/*.status` for the latest line of each in-flight job (wake-event log, not current state)
- `data/projects.md` for active projects

**Composing replies:**
- Always address the captain ("captain")
- Use light nautical seasoning where it fits
- Keep replies concise
- For `status`: list in-flight work with phase, list queued items, note if idle
- For `backlog`: list queued items, note blockers
- For `projects`: list project names from the registry

**Sending replies:**
- Write the reply to a temp file (never inline into shell)
- Extract `chat_id` from the stashed message: `jq -r '.message.chat.id'`
- Call `bin/fm-tg-reply.sh <chat_id> --text-file <path>`

## Phase 2: Task dispatch from Telegram

The captain can create backlog items, dispatch scouts, and ship tasks directly
from Telegram. This follows the normal firstmate intake lifecycle (section 7 of
AGENTS.md).

### Classifying actionable requests

Parse the message text for actionable intent. Look for these patterns:

**Backlog creation:**
- `add backlog:` or `backlog:` or `file:` followed by a task description
- `add <description> to backlog`
- Extract the one-line description after the keyword
- Record in backlog using `bin/fm-backlog-add.sh` or the active backlog backend

**Scout dispatch:**
- `scout <description>` or `investigate <description>` or `look into <description>`
- `find out <description>` or `what's wrong with <description>`
- Classify as a scout task, follow normal intake

**Ship dispatch:**
- `fix <description>` or `ship <description>` or `build <description>`
- `implement <description>` or `add feature: <description>`
- Classify as a ship task, follow normal intake

### Intake procedure (runs the normal lifecycle)

When an actionable request is identified:

1. **Resolve the project.** Match the description against known projects:
   - Read `data/projects.md` for project names and descriptions
   - Match keywords in the message against project names/descriptions
   - If ambiguous, list matching projects and ask for clarification
   - If exactly one match, proceed

2. **Classify the shape.** Scout vs ship, based on the verb used.

3. **Check for conflicts.** Compare against in-flight work in `data/backlog.md`.
   If blocked, record in backlog with `blocked-by: <id>` and tell the captain.

4. **Generate task id.** Use a short kebab slug with random suffix, e.g. `fix-login-k3`.

5. **Scaffold and spawn.** Follow section 7 of AGENTS.md:
   - `bin/fm-brief.sh <id> <repo-name> [--scout]`
   - `bin/fm-spawn.sh <id> projects/<repo> [--scout]`
   - Record in `data/backlog.md` under In flight

6. **Link the task to Telegram.** After spawn succeeds:
   - `bin/fm-tg-link.sh <id> <chat_id> <message_id>`
   - This enables up to 3 completion follow-ups posted as threaded replies

7. **Acknowledge.** Send a reply like:
   - "Aye, captain. Filed `<id>` to the backlog. Dispatching now."
   - Or for blocked: "Filed `<id>` but it's blocked by `<blocked-by>`. Standing by."

### Follow-ups on terminal wakes

When a tg-linked task reaches a milestone or terminal state, post a follow-up.
The task is linked when `state/<id>.meta` contains `tg_chat=` and `tg_message=`.

**Checking if a follow-up is due:**
```bash
bin/fm-tg-followup.sh --check <task-id>
```
Exit 0 means a follow-up is due (prints chat_id and message_id).

**Posting a follow-up:**
1. Compose the outcome message in firstmate voice:
   - For investigation complete: findings summary
   - For ship started: "Underway. Building..."
   - For PR ready: "PR <url> checks green. Use inline buttons below to decide."
   - For shipped/merged: "Merged to main." (this is a --final follow-up)
   - For failed: "Failed with: <reason>." (--final)
2. Write to a temp file, then:
   ```bash
   bin/fm-tg-followup.sh <task-id> [--final] --text-file <path>
   ```

Only post follow-ups for genuine milestones: investigation done, build started,
PR ready, shipped, failed. Do not post for routine "working" progress.

## Phase 3: Interactive decisions (inline keyboards)

When firstmate needs a captain decision for a tg-linked task, it sends a message
with inline keyboard buttons. The captain taps a button, Telegram sends a
`callback_query`, and the bridge processes the decision.

### Supported actions and callback_data encoding

Callback data format: `<action>:<task-id>` (max 64 bytes)

| Action | callback_data | Handler |
|--------|--------------|---------|
| Merge PR | `merge:<task-id>` | `bin/fm-pr-merge.sh <id> <pr-url>` |
| Skip / leave | `skip:<task-id>` | Clear decision, leave task in queue |
| Approve finding | `approve:<task-id>` | Approve ask-user finding via `no-mistakes axi respond` |
| Decline finding | `decline:<task-id>` | Decline finding, task continues |

### Sending a decision message

When a `needs-decision` or `done: PR <url>` wake fires for a tg-linked task:

1. **Check the link:** `bin/fm-tg-followup.sh --check <task-id>` to get chat_id and message_id.

2. **Compose the decision prompt.** Write to a temp file:
   ```
   PR https://github.com/owner/repo/pull/N checks green. Merge, captain?
   ```

3. **Create the keyboard JSON.** Write to a temp file:
   ```json
   [
     [{"text": "Merge", "callback_data": "merge:<task-id>"}],
     [{"text": "Skip", "callback_data": "skip:<task-id>"}]
   ]
   ```

4. **Send with keyboard:**
   ```bash
   bin/fm-tg-reply.sh <chat_id> --text-file <prompt-file> --keyboard <kb-file>
   ```

5. **Record the decision:**
   ```bash
   bin/fm-tg-decision.sh record <task-id> <chat_id> <sent_message_id>
   ```

For ask-user findings, the keyboard has `approve:<id>` and `decline:<id>`.
Use Telegram button styles: add `"style":"success"` for approve/merge,
`"style":"danger"` for decline/skip.

### Processing a callback_query

On `tg-callback <update_id>` wake:

1. **Read the stashed update:**
   ```bash
   jq -r '.callback_query.data' state/tg-inbox/<update_id>.json
   jq -r '.callback_query.id' state/tg-inbox/<update_id>.json
   ```

2. **Parse callback_data.** Split on `:` to get `<action>` and `<task-id>`.

3. **Route to the action:**

   **`merge:<task-id>`:**
   - Get the task's PR URL from `state/<task-id>.meta` (the `pr=` line) or from the backlog Done section
   - Run `bin/fm-pr-merge.sh <task-id> <full-pr-url>`
   - On success: edit the decision message text to "Merged PR <url>." and remove keyboard
   - On failure: edit to "Merge failed: <reason>. Retry from primary session."

   **`skip:<task-id>`:**
   - Edit the decision message to "Skipped. PR <url> left for later." and remove keyboard
   - Clear the decision record

   **`approve:<task-id>`:**
   - For no-mistakes findings: `no-mistakes axi respond <task-id> --approve <finding-index>`
   - Edit message to "Approved. Continuing..."
   - Clear decision record

   **`decline:<task-id>`:**
   - For no-mistakes findings: `no-mistakes axi respond <task-id> --decline <finding-index>`
   - Edit message to "Declined. Adjusting..."
   - Clear decision record

4. **Edit the message to show outcome:**
   For simple text-only edits, create a new message and remove the keyboard from the old one.
   For keyboard removal without text change, use `fmtg_edit_reply_markup` via `fm-tg-decision.sh resolve`.

5. **Resolve the decision record:**
   ```bash
   bin/fm-tg-decision.sh resolve <task-id> <action>
   ```

6. **Send a confirmation reply** as a threaded reply to the decision message.

### Timeout stale decisions

On every heartbeat wake (or periodically), run:
```bash
bin/fm-tg-decision.sh timeout
```
This scans for expired decisions, removes their keyboards, and marks them resolved.
Default timeout: 86400s (24 hours).

## Help command output (updated for Phase 2+3)

```
Available commands, captain:

Read-only:
- status — fleet state and in-flight work
- backlog — queued backlog items
- projects — active projects
- help — this list

Actions:
- backlog: <task> — add to backlog
- scout <description> — investigate something
- fix/ship/build <description> — dispatch a ship task

When a task needs your decision, I'll send inline buttons:
- [Merge] [Skip] — for PRs ready to merge
- [Approve] [Decline] — for review findings
```

## Dry-run / preview mode

When `FMTG_DRY_RUN` is set (truthy), all outbound Telegram calls are recorded to
`state/tg-outbox/` instead of sent. The procedure is unchanged: compose as usual,
call the scripts. Inspect `state/tg-outbox/` to see what would have been sent.

Dry-run keyboard JSON files are recorded alongside the payload. For callback_query
processing in dry-run, the answerCallbackQuery call is recorded but not sent.

## Notes

- The sender is always the captain (user ID already validated by `fm-tg-poll.sh`).
- Unlike X mode, there are no public-safety concerns. Task IDs and tool names
  are fine in replies.
- One wake may cover several pending messages - drain them all.
- Never inline message-influenced text into a shell command; always use `--text-file`.
- The inbox file removal is the local idempotency guard.
- Callback queries are already answered by `fm-tg-poll.sh`; do not re-answer them.
- Decision keyboard messages should be tracked via `fm-tg-decision.sh` so they can
  be timed out if the captain never responds.
- After processing all inbox files, clear the wake and continue.
