# Automatic pull-request review verification

Audience: maintainer verification.

This record holds reusable current evidence for the automatic review and feedback guarantees.
[`docs/configuration.md`](../configuration.md#automatic-pull-request-review-statepr-review) owns setup and limits.
[`docs/architecture.md`](../architecture.md#automatic-pull-request-review-and-feedback) owns stable component and durability boundaries.
[`bin/fm-pr-review.sh`](../../bin/fm-pr-review.sh) help owns commands and opt-out mechanics.
[`pr-review-owner`](../../.agents/skills/pr-review-owner/SKILL.md) owns adjudication and routing.

Verified on 2026-08-04 on macOS with:

```text
Darwin 25.5.0 arm64
GNU bash 3.2.57(1)-release
node v22.23.1
gh-axi 0.1.28
```

## Executable boundary

The controlled GitHub boundary is a fake `gh-axi` executable backed by mutable JSON.
It implements selected authenticated reads, explicit pages, inline replies, conversation comments, and COMMENT reviews while logging every attempted GitHub operation.
The product entry point, Node state owner, private files, exact-head checks, and response replay all remain real.
No live pull request is changed by the suite.
A separate authenticated read-only smoke ran the production poll with real `gh-axi` against the work account, completed inside the default total deadline, and published an inventory result only into a disposable private home.
The disposable home was removed after inspecting only the bounded category and counts; the smoke exposed no GitHub write command.

Run:

```sh
bash tests/fm-pr-review.test.sh
```

Current exact output:

```text
ok - automatic pull-request review owner is installed
ok - discovery covers authored, requested, assigned, and participating PRs with one review per exact head and unchanged silence
ok - feedback includes actionable bodies, inline comments, conversation, and substantive bots without self-reply loops
ok - bounded pagination covers multiple PR, review, inline-thread, and conversation pages
ok - CRLF and leading-whitespace truncated bodies reconstruct and adjudicate at the exact node
ok - a pull request closed between search and detail is omitted after its live closed-state read
ok - one pull request's read failure stays isolated, announced once, durable, and non-destructive
ok - a wide isolated-read diagnostic stays inside the adapter's bounded message window
ok - supported inline feedback is fixed, validated, and replied exactly once
ok - unsupported, duplicate, outdated, and superseded findings receive one evidence reply
ok - scope expansion and stronger boundaries wait for the captain without a premature response
ok - distinct-author foreign PR review is comment-only and submits exactly once
ok - fleet-authored findings route privately, unsupported leads stay private, and neither counts as independent review
ok - live author equality refuses formal and fallback self-review publication across stale state and replay
ok - head movement during verification invalidates evidence and requeues the same finding generation
ok - a closed or merged pull request ends its item without a response and frees the lane at every boundary
ok - reopening restores coverage for closed items only and leaves every other terminal disposition intact
ok - poll crashes before and after snapshot publication replay without lost or duplicate work
ok - duplicate notifications and claim replay preserve one review worker per lane
ok - reply failure after correction retries the same response without duplicating the fix
ok - crash after GitHub acceptance reconciles one original-thread reply instead of duplicating it
ok - captain takeover opt-out is durable and later restoration covers intervening heads and feedback
ok - process-event registration is restart-idempotent and isolated per Firstmate home
ok - locked main-home bootstrap arms one account review source with one auth probe and no secondmate duplicates it
ok - authentication and rate-limit failures stay bounded, deduplicated, and preserve the last good inventory

# all automatic pull-request review tests passed
```

## Independent oracles and mutation witnesses

| Guarantee | Independent oracle | Mutation that the test rejects |
| --- | --- | --- |
| one review per exact head | the fixture explicitly contains four relevant PR identities, then changes only one SHA | keying review work by PR number alone loses the fifth exact-head item |
| unchanged silence | item count, no task metadata, empty stdout, and the source's no-result exit are checked independently | dispatching from every timer tick creates output or task state |
| inventory scopes | four distinct fixtures each carry one independently expected relationship | querying only authored or review-requested PRs loses assigned or participating rows |
| bounded pagination | five records with a page size of two require pages two and three, which the fake call log proves were read | first-page-only collection loses PRs or feedback |
| complete feedback body | a finding extends beyond the queued prefix and the exact-node chunk reader reconstructs its independently asserted suffix | adjudicating only the transport prefix loses the claim's final substantive text |
| truncated CRLF and leading-whitespace bodies | separate fixtures carry CRLF line endings and leading spaces inside the bounded prefix, and the reconstructed record is asserted against the independently known first and last text | normalizing before slicing shifts the prefix window, so the reconstruction never matches and those bodies can never be adjudicated |
| close during search | a candidate is still returned by the lagging search index while its live detail read answers closed | omitting on the index alone drops open work, and failing the whole poll on one stale hit ends account-wide coverage |
| isolated pull read failure | one pull request's paged reads fail while another gains new feedback, and the previous covered cursor, queued items, announced diagnostic, and durable snapshot marker are each checked separately | aborting the poll ends account-wide coverage, and swallowing the failure publishes a partial inventory as if it were complete |
| bot and self classification | the fixture contains one substantive CodeRabbit claim, one transport-only deployment, and one self reply | excluding every Bot drops CodeRabbit; accepting every Bot or self actor creates loops |
| supported correction | validation evidence and one exact original-thread response are independent files and effects | replying before validation or posting twice changes the terminal record or write count |
| dismissed feedback | each unsupported, duplicate, and superseded claim has a required response and durable terminal outcome | silently resolving any non-fixed claim leaves no delivered response |
| crash replay | process exits are injected after item publication, snapshot publication, claim, response staging, GitHub post, and terminal publication | cursor-before-item, duplicate claim, or post-without-reconciliation loses or repeats work |
| head movement | GitHub's current head is changed while the claim generation remains old | trusting only the claimed SHA posts stale evidence instead of incrementing and requeueing |
| closure or merge | the fixture pull request answers closed through the real read at the resolve, complete-review, and deliver boundaries, and the durable outcome, the freed lane, the next claim, and the write log are checked separately | treating closure as an unrecoverable error strands the item and wedges the single lane until a captain opts out; skipping the reconciliation reports an already-accepted reply as withheld or posts it twice |
| reopen coverage | the same pull request leaves and re-enters the inventory, and the closed review, the closed claim, an already-answered claim, a repeated poll, and a pre-cursor crash are each checked separately | recreating by item id alone silently drops the reopened review and its unanswered claim, while reactivating on any terminal outcome answers a settled claim twice |
| lane recovery | the closure crash seam cuts between the terminal write and the lane release, and the poll itself must still announce the queued item | a lane trusted as an owner rather than a pointer keeps naming a terminal item forever, and a poll that reads the lane raw silences the very wake that would repair it |
| bounded diagnostic message | five maximum-length repository identities are announced and the adapter itself classifies the emitted result | an unclamped message exceeds the consumer's window, so the diagnostic silently becomes malformed and unactionable |
| reply failure | the first write fails after correction evidence is already durable | rerunning correction or discarding the staged body changes evidence or response identity |
| captain decision | the fake GitHub log must remain empty while the item reaches captain-decision-pending | treating reviewer wording as authority produces a write |
| private authored findings | an authored fixture has a distinct existing implementation owner and must retain its findings without any GitHub operation or independent-review credit | requiring public review transport leaks the internal findings or loses their correction route |
| live self-review guard | a queued foreign review changes to live author equality before delivery, and a second fixture mutates the staged method to a legacy fallback comment | trusting queued authorship or prompt wording submits the PR 4034-shaped self-review or replacement comment; replaying the refused item writes again |
| foreign PR safety | the live actor and author reads are distinct and the fake log accepts exactly one `pr review --comment` for the terminal review | approval, merge, branch mutation, missing identity reads, or duplicate delivery appears directly in the operation log |
| opt-out restoration | head and feedback both change while the covered cursor is frozen | updating the covered cursor during takeover loses one or both intervening identities |
| home isolation | two homes derive different source ids and retain one idempotent registration each | machine-global or path-independent identity aliases the homes |
| secondmate exclusion | plain, symlinked, and dangling-symlink markers each stand for a secondmate home, and the locked bootstrap probes GitHub authentication exactly once | a marker test that follows or ignores symlinks lets a secondmate start the account-global poller, and a second probe adds a network round trip to every session start |
| bounded failures | failed authentication and low rate headroom publish no snapshot and deduplicate the same diagnostic | partial inventory publication or immediate retry changes state or call cadence |

## Supported harnesses and runtime backends

The source publishes only through the generic process-event `check` path.
It neither reads a worker endpoint nor calls `bin/fm-backend.sh`.
Therefore tmux, Herdr, Zellij, Orca, and cmux do not differ at this integration surface.

The same actionable `check` notification is consumed by Claude, Codex, OpenCode, Pi, pi-signed, Grok, and Kimi through their existing primary supervision protocols.
No harness-rendered output, key binding, process name, or vendor-specific state participates in inventory, queue identity, or response delivery.
The test proves registration-only supervision through `fm_supervision_needed`; the existing supervision suites remain the owner of per-harness notification continuity.
