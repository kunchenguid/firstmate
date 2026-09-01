---
name: slack-browser
description: >-
  Agent-only procedure for reading and posting in Slack by driving the captain's
  own logged-in browser session, for workspaces where no bot token is available.
  Use before any Slack read or post, and before promising the captain a Slack action.
  Owns the connection contract, the consent gates that apply because every message
  posts as the captain rather than as a bot, the send-verification rule, and the
  DOM facts that make a read correct.
user-invocable: false
metadata:
  internal: true
---

# Slack over the captain's browser session

Every message sent this way posts **as the captain**, from their own account, with no bot badge and nothing marking it as automated.
That single fact drives every rule below.

## Choose the access route first

Browser control is the last resort, not the default.

- If a **bot token** exists for the workspace, use the Slack Web API instead: it gives real user IDs, pagination, full history, and reaction metadata, and it posts under a separate bot identity.
- If a Slack app **can** be installed, propose that before automating the captain's own account.
- Use the browser route only when the captain lacks workspace-admin approval, which is the normal case at a locked-down employer.

Never scrape, guess, or reuse a credential to obtain a token.
If a token would help, ask the captain to provide one.

## Connect

`chrome-devtools-axi` is the only supported driver; its `--help` owns the exact flags and environment variables.

1. Attach to the captain's already-signed-in Chrome with `CHROME_DEVTOOLS_AXI_AUTO_CONNECT=1`, which requires remote debugging to be approved in that Chrome.
   The approval prompt fires when the tool **connects**, not when the setting page opens, so the first call failing with a setup message is expected; ask the captain to approve, then retry once.
   The grant is per browser instance and does not survive a Chrome restart.
2. **Attaching selects no tab**, so the first page-scoped call fails with `No page is currently selected` even though the connection succeeded.
   Run `chrome-devtools-axi pages`, then `chrome-devtools-axi selectpage <id>`, before any `open`, `eval`, `snapshot`, or `newpage`.
3. Attaching to the captain's Chrome does not imply a Slack session in it.
   A captain who uses the Slack desktop app commonly has no browser session at all, and Slack answers with a workspace-URL sign-in page rather than an error.
   Check for that page before assuming a read failed, and ask the captain to complete the sign-in rather than trying to drive it; the desktop app is a separate Electron session that this route cannot reach.
4. A launched-fresh browser is signed into nothing, so it is only useful once the captain completes an SSO login in it.
   Prefer `CHROME_DEVTOOLS_AXI_USER_DATA_DIR` for a reusable profile over asking them to log in repeatedly.
5. Confirm the workspace before acting.
   `chrome-devtools-axi eval "location.href"` returns `/client/<TEAM_ID>/<CHANNEL_ID>`, and people are frequently signed into several workspaces at once.

Slack boots slowly, so an immediate read after navigation returns an empty shell; wait for a real message row rather than a fixed sleep.

## Consent gates

Escalation wording and captain-facing phrasing stay owned by `AGENTS.md` section 9; this section owns only which Slack actions need a gate.

- **Any message visible to a human needs the captain's approval of the exact text first**, whether a DM or a channel post.
  Show the draft and wait.
- **Reading is not free.** Opening a channel or DM marks it read and clears the unread badge, so say so before opening anything the captain may be using as a queue, and open only what the task needs.
- **Confirm the recipient before typing.** Require exactly one match for a person, open the conversation, and check the header; list candidates for the captain rather than guessing between similar names.
- **Skip any account labelled as not-to-be-messaged** in the mention autocomplete.
- **If anyone asks whether they are talking to a bot or an AI, stop and ask the captain.**
  Do not answer it either way: denying it lies in the captain's name, and confirming it discloses something that may be theirs to disclose.
- **Never self-identify as an agent and never add a disclosure prefix** such as "sent by my assistant" unless the captain asked for one.
  Whether colleagues know is the captain's decision, not a courtesy to extend on their behalf.
- Standing permission to post in one place is not permission for another target, and never covers anything irreversible, financial, personnel-related, or addressed outside the expected circle.

When the captain has granted standing permission, match their register rather than a default assistant voice.
Read their own recent messages in that conversation and copy the observed capitalisation, length, and sign-off habits; most people write far more tersely in chat than an assistant does.

## Find the conversation

Sidebar rows are `[data-qa="channel-sidebar-channel"]`, and their first line of `innerText` is the channel name.
Read that list and match the name exactly rather than typing into the filter, which avoids the filter's append behaviour entirely when the target is already visible.
Clicking the row's own anchor navigates reliably; confirm arrival by re-reading `document.title` and `location.href` rather than assuming the click worked.

- `[data-qa="channel_sidebar_name_button"]` does **not** exist in current Slack and matches nothing.
- When the filter is genuinely needed, it is `[data-qa="sidebar-text-filter-input_input"]`, and it **appends** rather than replaces.
  Clear it through the native value setter plus an `input` event, or two searches in a row silently concatenate into zero results.
- A bare name can match a direct message rather than the channel of the same name, so prefer an exact name match or a recorded channel ID.

## Read

Iterate `[data-qa="message_container"]`, taking sender from `[data-qa="message_sender_name"]`, body from `[data-qa="message-text"]`, and timestamp from `a.c-timestamp` whose `aria-label` carries the full date.
Extract with a single `chrome-devtools-axi eval` returning `JSON.stringify(...)` rather than many small calls.

- **Do not count or iterate `[data-qa="virtual-list-item"]`.**
  Slack uses it for the channel sidebar as well as the message list, so it silently conflates the two; one observed channel reported 51 of them for 3 actual messages.
- The list is **virtualised**, so only rendered rows exist in the DOM.
  Never describe a read as the channel's full history; scroll and re-read when older messages matter, and tell the captain what window was actually covered.
- A row with **no sender node is a continuation** of the previous author, not an unknown sender; carry the previous name forward.
- In the thread pane, `aria-label` gains an `. Open in channel` suffix, so strip it before comparing or deduplicating.
- Deduplicate on sender, timestamp and text together, and treat a missing timestamp as not-a-match rather than collapsing two distinct messages into one.

## Post

`[data-qa="message_input"]` is only the wrapper; the contenteditable element is `[data-qa="texty_input"]` inside it, and that inner element is what must hold focus.
Focus it, then `chrome-devtools-axi type "<text>"`, then send.
Element-fill helpers do not work on it because it is contenteditable rather than an input.

- **A missing composer usually means the channel is read-only, not a broken selector.**
  Slack replaces it with `.p-message_input_roadblock`, so check for that before concluding the DOM changed; a default `#general` commonly behaves this way.
- To mention someone, type the `@name`, then press **Tab** to accept the autocomplete.
  **Enter both accepts the suggestion and sends**, which fires a half-written message.
- **Pick the autocomplete row by its highlight class, not `aria-selected`.**
  Slack reports `aria-selected="false"` on every row including the highlighted one, so trusting it would accept whatever row happens to be first.
  Read every offered row before accepting, because near-identical names appear together and some are explicitly labelled not-to-be-messaged.
- A typed `@name` that never became a real mention entity pings nobody.
  Confirm a mention pill exists in the composer with `[data-type="user"], .c-member_slug, [data-member-id]` before sending.
- **Do not assume Enter sends.**
  Slack has a preference where Enter inserts a newline and only Cmd+Enter sends, which turns every send into a silent no-op when it is set.
  Establish which applies for this captain once and record it as a workspace fact rather than rediscovering it per send.

## Verify every send

Pressing the send key is not evidence that anything was delivered.
A message is sent only when **both** hold:

- it appears in the transcript with the captain's name and a current timestamp, and shows no pending or failed indicator, and
- the composer has reset to its placeholder, which means its text equals the `Message <channel>` placeholder rather than being empty; an emptiness test reports a reset composer as unreset.

A cleared composer on its own is also what a failed send looks like, so never accept it alone.
This applies identically to plain messages and to mentions; a mention path that reports success without re-reading the transcript is reporting an assumption.
Capture a screenshot when a DOM read is ambiguous or the captain needs to see what actually landed.

## Bots and agents reachable in Slack

When dispatching an in-Slack bot the captain has authorised, read the channel's recent history first to learn the invocation convention instead of guessing it.

- Most such bots reply **in a thread on the dispatching message**, not in the channel, so watch the reply link rather than the main transcript.
- The first reply is frequently a status acknowledgement rather than the answer, so poll until substantive content arrives and never report the first reply as the result.
- Do not gate on a minimum length or reject text containing a boilerplate disclaimer, because a real answer can be a single token and disclaimers are commonly appended to the answer itself rather than posted separately.

## Workspace-local facts

Team IDs, channel IDs, bot names and invocation conventions, and the Enter-versus-Cmd+Enter setting are specific to one captain's workspace.
Record them in this home's `data/learnings.md` under the routing rules in `AGENTS.md` section 6, never in this skill.
Channel IDs are scoped to a team ID and must not be reused across workspaces.

## First run in a new workspace

Slack ships DOM changes without notice, so confirm the selectors above against a real page with `chrome-devtools-axi snapshot` before trusting a read or a send.
If a selector no longer matches, fix it here rather than working around it at the call site, and say plainly that the read was degraded rather than reporting a partial transcript as complete.
