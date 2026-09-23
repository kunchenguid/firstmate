# vessel for team work: firstmate brings you everything, you only decide

## Goal

The captain sits back.
Firstmate notices anything that needs the captain's attention and does the read-only preparation itself.
It then brings one recommendation, which the captain either accepts or redirects ("do it like this instead").
This covers all team work, not just implementing tickets:
- Feedback on the captain's own PRs.
- Review requests and re-requests.
- CI failures and merge conflicts.
- Approvals.
- Newly assigned tickets.

## Context

vessel is a fork of firstmate. Firstmate assumes one person merges their own green PRs and starts all work themselves.
The captain's team works differently:
- Colleagues review and merge PRs, and approvals are required.
- Inbound work is at least half the job.
- Everything an agent does outwardly goes out under the captain's name.

Decisions the captain made:
- **No-mistakes is off.** Work projects ship with an ordinary PR, and merge authority stays with the captain and team (yolo off).
- **Preparation is proactive and never changes anything.** Triaging, reviewing, planning and diagnosing start automatically. Changes to code, GitHub or Jira happen only when the captain accepts or commands.
  - This is a deliberate change from firstmate's default, where work is dispatched only on request.
  - It also replaces the earlier "no automations" rule for read-only preparation.
- **Firstmate brings items to the captain in chat.** vessel's display stays as it is.
- **Reviews go to GitHub as a pending review.** Submitting one needs the captain's accept or command.
- **Jira transitions are configured once.** Picking up a ticket moves it to In Progress, and opening its PR moves it to In Review.
- **PR conventions:**
  - Open PRs as drafts, and the captain marks them ready.
  - Use conventional commits.
  - Never force-push a PR under review.

Fork rule: stay additive. Change only `vessel/`, `.agents/skills/vessel-workflows/`, `.github/workflows/vessel-sync.yml`, and gitignored config and data.
Never edit `AGENTS.md`, `bin/`, `docs/`, or upstream skills.

## Facts this plan relies on (verified)

- `bin/fm-teardown.sh` (header) treats work as landed once it is reachable from any remote-tracking branch.
  A pushed PR branch can therefore be cleaned up before merge, with no `--force`.
- Using the direct-PR delivery contract has two consequences:
  - The direct-PR contract (`bin/fm-dod-lib.sh:274-279`) asks for a PR that is not a draft.
    It allows a deliberately held draft if the worker reports `paused:` instead of `done:`, and `fm-pr-check.sh` refuses to arm on a draft.
  - `config/brief-include.md` defers to every other section of the brief.
    So the draft instruction must go in the task's `## Firstmate spec`.
- Registered home checks exist as a pattern (`bin/fm-tool-update-check.sh arm`):
  - Arming writes `state/<name>.check.sh` and runs `bin/fm-check-register.sh <name>`.
  - The watcher runs it every `FM_CHECK_INTERVAL` (300 seconds), and each run must finish within 30 seconds.
  - One printed line becomes a `check:` notification to firstmate.
  - A registered check keeps supervision running (`bin/fm-supervision-lib.sh:64-80`).
- A captain call is an ordinary backlog task held for the captain through `bin/fm-captain-hold.sh hold <id> --title … --reason …`.
  - `answer <id> --decision-file` records the captain's actual words.
  - Open calls reappear in every notification drain's OPEN DECISIONS section and in `/bearings`, so they survive restarts.
- Delivery posture is set per project in `data/projects.md` as `- <name> [direct-PR] - <desc> (added <date>)` (`bin/fm-project-mode.sh`).
  The project name is the basename of the project directory (`bin/fm-spawn.sh:2808`).
- vessel already loads most of what's needed:
  - GitHub (`vessel/src/github/`): my PRs, PRs waiting on my review (including team requests), threads, review decision, check status.
  - Jira through `acli` (`vessel/src/jira.rs`).
- The contract tests live in `vessel/tests/contract.rs` and run on every upstream sync.

## The core loop: detect → prepare → propose → act

1. **Detect.** `vessel radar` runs on firstmate's monitoring cadence and prints one line when something new happens. That becomes a notification to firstmate.
2. **Prepare** (automatic, read-only). Per the event playbook below, firstmate dispatches a scout with the right agent, following `config/vessel/vessel.json` `autoprep`.
   Events with nothing worth preparing skip straight to a proposal.
3. **Propose.** When the preparation finishes, firstmate files a **proposal**: a backlog task held for the captain through `fm-captain-hold.sh hold`, holding the recommendation.
   It then sends one self-contained chat message:
   - What happened, with the full URL.
   - What it found, briefly.
   - The recommendation.
   - The alternatives.
   - "Accept?"
4. **Act.** When the captain accepts or redirects, firstmate records the words with `fm-captain-hold.sh answer` and carries out the action.
   Accepting counts as the captain's explicit command for exactly the actions named in the recommendation, nothing broader.
5. **Supersede.** When the target changes before the captain answers, the old proposal is closed as superseded and preparation runs again.
   Examples: a new push to the PR, or a new review arriving.

### Event playbooks

| Event | Automatic preparation | Typical recommendation | On accept |
|---|---|---|---|
| Review or new comments on **my PR** | **Triage** scout: sorts each thread into fix / reply / push back / follow-up ticket, with draft replies | "Fix 3 (plan attached), reply to 1 (draft), push back on 1 (draft), file 1 as a follow-up ticket" | Proposition Joe addresses the accepted items and pushes. Firstmate posts the accepted replies, files the ticket, and re-requests review |
| **Review requested** from me | Snoop review → `findings.json` plus a suggested verdict | "Request changes: 2 blocking, 3 nits (pending review ready)" | Publish the pending review with the accepted findings and submit it with the accepted verdict |
| **Review re-requested** | Incremental Snoop: changes since my last reviewed commit, and whether my earlier threads were addressed | "Approve: all 4 of your threads addressed" | As above, and resolve my addressed threads if accepted |
| **CI failed** on my PR | **Diagnose** scout reads the failing logs | "Flaky test, rerun" / "Real failure, fix (plan)" / "Unrelated failure on main" | Rerun the checks, or dispatch the fix |
| **Conflicts** on my PR | none | "Resolve with Conflict Resolver" | Conflict Resolver run, merging the base in (never a rebase) |
| My PR **approved** and green | none | "Ready to merge" | Merge through firstmate's guarded merge path (see open questions) |
| My **draft PR** handed off | none | "Mark ready and request reviewers X, Y (from CODEOWNERS or recent reviewers)" | `gh pr ready` plus review requests |
| **Ticket assigned** to me | Stringer plan | "Pick up with this plan" / "Unclear, post these questions to the ticket (draft)" | Pickup (assign and transition), then implement with the plan, or post the questions |

## Phase 0: Posture, config only (firstmate does this itself, no code)

1. **Land what's already there.** Uncommitted vessel changes sit in the main copy: context publishing, `session.rs`, skill and README edits.
   - Clean up the finished hamsterdam review first.
   - Then put these changes on a branch and open a PR, so workers start from them.
2. **`data/projects.md`:** register hamsterdam and each work repo as `[direct-PR]` without `+yolo`.
3. **`data/captain.md`:** the team working model.
   - Colleagues review and merge.
   - Register new work projects as direct-PR.
   - Read-only preparation starts automatically; everything outward waits for accept or command.
   - The outward-action policy (below).
4. **`config/brief-include.md`:** standing instructions for workers.
   - Use conventional commits.
   - Never force-push, rebase or amend a branch with an open PR. Merge the base branch instead.
   - Use the repo's PR template.
   - Put the Jira key in the PR title and body.
   - Never comment, transition, review, resolve or reply unless the instructions say so.
5. **This repo itself:** `AGENTS.md` §1 says to ship through no-mistakes.
   Following the captain's instruction, vessel changes also ship as direct-PR with the captain merging.

**Outward-action policy.** Accepting a proposal counts as the command for the actions it names.

| Action | Default |
|---|---|
| Read-only preparation (triage, review, plan, diagnose) | automatic, per `autoprep` |
| Jira assign plus configured transitions on pickup and PR open | allowed once pickup is accepted |
| Other Jira transitions, and Jira comments | on accept or command |
| GitHub pending review | on accept or command |
| Submitting a review, or replying to or resolving threads | on accept or command |
| Push to your own PR branch | on accept or command, never force |
| Push to someone else's PR | only if explicitly told |
| Merge | on accept or command only |

## Phase 1: A PR's life ends at handoff, not merge

This phase changes `.agents/skills/vessel-workflows/SKILL.md` §5-§7.

- **implement:** `## Firstmate spec` tells the worker to open the PR as a draft and keep it a draft, then append `paused [at=…]: draft PR <url> held for the captain`.
- **address / conflicts:** push to the existing PR, then report `done`. Nothing is merged, and there is no merge poll.
- **New "Handoff" section:** when a ship reports its PR, firstmate does the following.
  - Do not run `fm-pr-check.sh`.
  - Record the handoff in the run history.
  - Clean up with `bin/fm-teardown.sh`.
  - Run the configured `pr_open` transition.
  - File the "mark ready and request reviewers" proposal.
- **`vessel/bin/vessel-record-run.sh`:**
  - Add `--update <task> --state handed-off --pr-url --pr-head`.
  - `vessel/src/firstmate/runs.rs` merges the update records into the run.
  - The TUI shows the run as "in review" until GitHub reports the PR merged or closed.

## Phase 2: Detect (`vessel radar`)

- **New Rust subcommand `vessel radar check|arm|disarm|ack <ids…>`** in `vessel/src/radar.rs`, dispatched from `main.rs`.
  It reuses `github::load_pull_requests`, `load_review_pull_requests` and `jira::load_jira_tickets`.
  - **`arm`** writes a `state/vessel-radar.check.sh` stub that runs `vessel radar check --home <home>`, then calls `bin/fm-check-register.sh vessel-radar`.
    This mirrors `fm-tool-update-check.sh`.
  - **`disarm`** calls `bin/fm-check-unregister.sh vessel-radar`.
  - **`check`** compares the current state with `data/vessel/radar.json`.
    - The first run records everything as already seen.
    - When there are new events it prints one line, e.g. `vessel-radar: 3 new (…)`. Otherwise it prints nothing.
    - It stays within 30 seconds and prints nothing if GitHub or Jira errors on a single run.
  - Events and their dedupe key (target, kind, anchor id) cover every row of the playbook table.
    The anchor ids are review id, comment or thread id, head commit, and ticket key.
  - The GitHub search query gains `statusCheckRollup`, unresolved thread and comment ids, `isDraft` and the review-request list.
    The data is shared with the TUI.
  - **`ack`** marks events as handled, once a proposal is filed or the event needs nothing.
- **README:** tell the captain to run `vessel radar arm` once. This keeps firstmate monitoring all day.

## Phase 3: Prepare and propose (the skill's new core)

- **New skill section "Radar loop"**, triggered on a `check:` notification whose line starts with `vessel-radar`:
  1. Read the pending events.
  2. Pick the playbook row.
  3. Dispatch the preparation scout within `autoprep` limits, recording it with `vessel-record-run.sh --radar-event <id>`.
  4. `ack` the event.
- **When a preparation scout finishes:**
  - Read the report.
  - File the proposal with `fm-captain-hold.sh hold proposal-<event-slug> --title … --reason "<recommendation>"`.
  - Send the chat message.
  - Events with no preparation go straight to a proposal.
- **Captain's answer:**
  - Record it with `fm-captain-hold.sh answer`.
  - Carry out exactly what was accepted, or follow the redirect.
  - Release the hold when the action is done.
- **Supersede:** a newer event on the same target closes the open proposal (answered as "superseded by …") and restarts preparation.
- **New workflow modes, agents and instructions** in `vessel/defaults/agents.json` and `vessel/defaults/agents/`. The names are suggestions.
  - **Triage** ("Bunk"): classify each review thread on my PR, draft replies, and sketch fixes. Output: `report.md` plus `triage.json`.
  - **Diagnose** ("Freamon"): read the failing CI logs (`gh run view --log-failed`) and classify the failure as flaky, real or unrelated, with evidence.
  - Snoop's review contract gains `findings.json` and a suggested verdict.
    In incremental mode it also takes the previous `pr_head` and the previous report, and checks whether my earlier threads were addressed.
- **`config/vessel/vessel.json` `autoprep`:** turn each event type on or off, and set `max_concurrent`, default 3.
  While away mode (`/afk`) is on, preparation still runs. The proposals wait for the captain's return summary, which upstream's away mode already produces.

## Phase 4: Outward mechanics (run only after accept or command)

- **`vessel/bin/vessel-publish-review.sh --task <id> [--findings ids] [--submit COMMENT|REQUEST_CHANGES|APPROVE] [--resolve-threads ids]`:**
  - Calls `gh api POST …/pulls/{n}/reviews` with `commit_id` set to the run's `pr_head`.
  - Applies any finding edits made in vessel (`data/vessel/review-edits/<task>.json`).
  - Reports clearly when the head has moved since the review, or when a pending review of yours already exists.
- **`vessel/bin/vessel-reply.sh`:** post accepted draft replies to threads on my PR, and re-request review.
- **`vessel/bin/vessel-jira.sh pickup|transition|comment|create`:** wraps `acli jira workitem`.
  - Transitions use the configured `jira_transitions` status names, e.g. `{"pickup": "In Progress", "pr_open": "In Review"}`.
  - `create` files follow-up tickets that came out of triage.
- **TUI:** a review run's page lists the findings. Space selects and `e` edits, reusing `ui/form.rs`.
  This is optional: accepting the recommendation publishes the selection firstmate suggested.

## Phase 5: Standup digest (small)

- **`vessel standup [--since <date>]`** prints markdown covering:
  - What I did yesterday.
  - Open proposals.
  - Runs under way.
  - My PRs waiting on others.
- **Skill trigger:** "standup", "what did I do yesterday".

## Open questions to settle during implementation

- **Merging after cleanup:** `bin/fm-pr-merge.sh` is the required merge path, but the job's record is gone after cleanup.
  Check whether it can merge a PR without a job record. If not, keep the record alive until merge or close for PRs the captain merges himself.
  Never fall back to calling `gh pr merge` around it.
- **Scope of acceptance:** does accepting a Triage proposal also authorize the follow-up "re-request review"? The proposal text should name it explicitly, so it does.

## Fork hygiene (every phase)

- **`vessel/tests/contract.rs` gains one contract test for each new upstream dependency:**
  - `fm-check-register.sh` and `fm-check-unregister.sh`, and that a registered check keeps supervision running.
  - `fm-captain-hold.sh hold|answer`.
  - The direct-PR paused-draft allowance.
  - Teardown's landed-by-remote rule.
  - The `paused:` status prefix.
- **Upstream proposals filed as backlog follow-ups, not in this scope:**
  - A home-wide default delivery mode.
  - A "handed to external review" end state.
  - A brief option for draft PRs.
  - A generic "external event → prepared proposal" hook.

## Execution

- **Phase 0:** firstmate does it directly.
- **Phases 1-5:** one ship task each on this repo.
  - Delivered as direct-PR, with yolo off; the captain merges.
  - Each brief requires `firstmate-coding-guidelines`.
  - Each has a backlog item filed first.
- **Order:**
  - Phases 1 and 2 run in parallel.
  - Phase 3 needs 2.
  - Phase 4 can run alongside 3.
  - Phase 5 comes last.

## Verification

- For every phase: `cargo test --manifest-path vessel/Cargo.toml`, `cargo fmt --check`, and `shellcheck vessel/bin/*.sh`.
  The contract tests must pass against the current upstream.
- **Phase 0:** `bin/fm-project-mode.sh hamsterdam` prints `direct-PR off`, and a test brief ends with the brief-include text.
- **Phase 1, on hamsterdam:**
  - A small implement job ends with a draft PR, a paused report and cleanup without force.
  - vessel shows the run as "in review".
  - A "mark ready and request reviewers" proposal arrives.
- **Phase 2:**
  - `vessel radar check` seeds silently and then prints nothing.
  - A comment from a second account produces one line.
  - `ack` clears it.
- **Phase 3, end to end:**
  - A review on my test PR produces a Triage proposal in chat. Accepting it produces the pushed fixes, the posted replies and the re-requested review.
  - A review request on a colleague's test PR produces a Snoop proposal. Accepting it produces the pending-then-submitted review with the accepted verdict.
  - A new push while a proposal is open supersedes it.
  - Restarting the session shows open proposals in OPEN DECISIONS.
- **Phase 4:**
  - Pickup on a sandbox ticket assigns it and moves it to In Progress, and it moves to In Review when the PR opens.
  - No comment is posted without accept.
- **Phase 5:** `vessel standup --since yesterday` lists the test activity and open proposals.
