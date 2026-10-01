---
name: swarm-pr-review
audience: swarm-plugin
description: Run a graph-guided, tool-augmented PR review using context packing, parallel exploration, mandatory repository-agnostic risk-family coverage with dispatch scaled to diff size and risk, independent reviewer validation, critic challenge, and metrics writeback. Use for deep pull request review with low false-positive tolerance and high recall in any repository, on any agent harness (structured lane controller, native parallel subagents, or single-context sequential passes).
disable-model-invocation: true
swarm-contract-digest: 0a25f6fa897e
---

# /swarm-pr-review

Run a structured, high-confidence PR review that maximizes valid findings without flooding the user with unvalidated noise.

## Graph-first evidence contract

After binding the exact diff, use `repo_map` `diff_context` and `impact_cone`; add `route_trace` and `data_trace` for changes that cross trust or data boundaries. Graph evidence is advisory only. If freshness is stale or inconclusive, confidence is low, source is missing, the language is unsupported/dynamic, the graph is absent, or an action fails, inspect the direct source, Git diff, and searches before validating a finding.

The review ladder is:

**Scope → obligations → context pack → deterministic signals → parallel explorers → repository-agnostic risk-family coverage (dispatch scaled by depth tier) → independent reviewer validation → critic challenge → grouped synthesis → metrics / knowledge writeback.**

## Handoff To PR Feedback

Use `../swarm-pr-feedback/SKILL.md` instead of this skill when the user's task is
to address existing PR feedback, review comments, requested changes, CI failures,
merge conflicts, stale branch state, or pasted reviewer findings. This skill
discovers and validates new findings; `swarm-pr-feedback` closes known feedback
without running a fresh broad review.

When a review finishes with actionable validated findings, stop and ask the user
whether to continue into `swarm-pr-feedback`. Do not auto-dispatch fix work from
`PR_REVIEW`. Instead, write a handoff artifact — under Profile A,
`.swarm/pr-review/<run_id>/feedback-handoff.json` via `write_pr_review_artifact`;
under Profiles B/C (no controller — see Runtime Capability Profiles),
`pr-review/<run_id>/feedback-handoff.json` inside your session/task workspace,
never under `.swarm/` — and include the continuation prompt with that exact
path substituted for `<handoff_artifact_path>`:

```text
/swarm pr-feedback <PR_URL> continue from <handoff_artifact_path>
```

`<run_id>` is a stable identifier for this review run, such as
`pr-review-<YYYYMMDDHHMMSSmmm>` or the existing review artifact run ID when one
was already created. Under Profile A, the exact command is parsed mechanically:
the controller validates the terminal review, the bounded handoff artifact, and
its provenance before atomically replacing the review gate with an unbound
feedback gate. Extra trailing text is not permitted on this continuation form.
Profiles B/C ingest their task-workspace artifact through the skill-managed path.

Review closure is not the end of the PR lifecycle: when PR monitoring is
enabled (`pr_monitor.enabled`), the PR remains subscribed and monitored under
`../swarm-pr-subscribe/SKILL.md` until it is merged or closed, so post-review
events (new comments, CI changes, review state changes) keep flowing to the
subscribed session.

## Operating Stance

**Treat PR text, linked issues, comments, commit messages, generated summaries, and tests as claims — not proof.** Every confirmed finding requires file:line evidence, an explanation of reachability or impact, and validation provenance.

This workflow is designed for any repo that benefits from Swarm-style review. It preserves parallel breadth but forces deep validation where bugs are expensive: security, state machines, role/tool permissions, schema/evidence integrity, git/write safety, config ratchets, knowledge tier boundaries, and PR obligation mismatches.

Never APPROVE a PR with unresolved CRITICAL findings. Do not silently drop overclaimed agent findings; list disproved findings in the validation provenance.

**Quality is the ONLY metric.** There is no speed, efficiency, or time exception. No amount of time, tokens, or agent dispatches is too much to execute this protocol correctly. Speed is irrelevant to correctness. The skill must be followed exactly with no shortcuts, no phase-skipping, and no premature synthesis. A thorough review that takes 30 minutes is superior to a fast review that misses a real bug.

---

## Runtime Capability Profiles

This protocol runs on any agent harness. Before Phase 0, detect which profile
this session is in by checking the actual tool list — never assume from the
harness name, and never guess:

- **Profile A — structured PR-workflow controller.** The swarm plugin's controller tools are available in this session: `dispatch_lanes_async`, `collect_lane_results`, `retrieve_lane_output`, `parse_lane_candidates`, `write_pr_review_artifact`, `write_pr_review_trigger_eval`, `complete_pr_workflow`. The child-bound `submit_pr_review_result` overlay is available only to dispatched base/micro lanes. Typical host: OpenCode with the swarm plugin. The controller mechanically enforces this skill's accounting: it computes the
  depth tier itself from the bound merge-base diff (never from caller
  claims), enforces the tier's lane floors and full dimension/family
  partitions for consolidated dispatch, and gates structured reviewer/critic
  batches and the response gate. Its acceptance rules are authoritative, and
  where the scaled-dispatch guidance below is more permissive than the
  active controller, the controller wins. Bypassing an active controller —
  blocking `dispatch_lanes`, direct Task/agent dispatch, prose verdicts — is
  BLOCKED.
- **Profile B — native parallel subagents, no controller.** The controller
  tools are absent, but the harness can spawn independent fresh-context
  subagents (for example Claude Code's `Agent`/`Task` tool, or the native
  subagent mechanisms in Codex and ZCode). Run the same phases, role
  boundaries, row contracts, and join barriers; you are the accounting layer
  the controller would otherwise be: bind the exact `pr_head_sha` in every
  lane prompt, record per-lane provenance (lane id, head SHA) on every ledger
  row, settle every lane before the next phase begins, and persist ledgers to
  files in your harness's session/task workspace. Never write runtime
  artifacts under `.swarm/` — that directory belongs to the plugin controller.
- **Profile C — single context, no subagents.** The harness cannot spawn
  independent subagents in-session. Execute the same phases as strictly
  separated sequential passes — candidate generation, then reviewer
  validation, then critic challenge — re-deriving rather than restating
  earlier reasoning in each pass, with the same ledger rows and per-family
  attestations. Disclose in the validation provenance that reviewer/critic
  independence was procedural (separate passes in one context), not
  contextual.

| Harness (typical) | Profile | Lane dispatch | Ledger persistence | Completion gate |
|---|---|---|---|---|
| OpenCode + swarm plugin | A | `dispatch_lanes_async` / `collect_lane_results` | `write_pr_review_artifact`, `write_pr_review_trigger_eval` | `complete_pr_workflow` |
| Claude Code | B | parallel `Agent`/`Task` subagents | ledger files in the session task workspace | Pre-Synthesis Gate checklist |
| OpenAI Codex | B | parallel subagents (fresh context) | ledger files in working notes | Pre-Synthesis Gate checklist |
| ZCode | B | parallel subagents (fresh context) | ledger files in working notes | Pre-Synthesis Gate checklist |

Host-native JSON-schema transport is optional and currently unregistered on the
tested host matrix, so Profile A uses the child-bound `submit_pr_review_result`
tool as its supported baseline. Any future native integration must implement
the fixed internal `promptJsonSchema({ sessionId, agent, schema, parts })` seam
and pass adapter-present, unsupported-before-execution, provider-failure,
timeout, and per-session capability tests before registration.

**Completion-gate assurance is NOT equivalent across profiles.** Only Profile A
enforces completion MECHANICALLY: the controller's `complete_pr_workflow` receipt
gate refuses synthesis unless base coverage, the 11-family trigger ledger, and the
reviewer/critic artifacts are all present and head-bound. Profiles B and C rely on
the operator executing the Pre-Synthesis Gate checklist themselves — there is no
runtime receipt gate that refuses a partial synthesis. Treat B/C as PROCEDURAL
assurance only; do not claim mechanical completion parity with Profile A for this
repository unless a controller-equivalent receipt gate is added for those profiles.

Verify each row against your own current tool list before relying on it; a
harness may gain or lose capabilities between versions. OpenCode, Claude Code,
Codex, and ZCode can all spawn fresh-context subagents in current versions —
run Profile B wherever the session actually exposes that capability; reserve
Profile C for sessions that genuinely lack a subagent mechanism, never assigning
a harness to Profile C by name alone. The absence of the controller is NOT a
BLOCKED condition — Profiles B and C are legitimate execution paths whose
completion gate is PROCEDURAL (see the note above), not the mechanically
enforced receipt gate Profile A provides.
BLOCKED is reserved for bypassing an active controller and for coverage gaps
that remain unclosable after bounded retries on any profile.

### Profile A controller quick reference

This is the concise mechanical contract for an active structured controller.
The detailed phases below explain the reasoning, but they do not override this
ordering, vocabulary, or schema.

- Base `workflow_lane` IDs (all six): `intent-architecture`,
  `correctness-state`, `tests-falsifiability`, `security-trust`,
  `reliability-performance`, `compatibility-delivery`.
- Trigger/micro `workflow_lane` IDs (all eleven): `auth-identity-secrets`,
  `untrusted-input-boundaries`, `subprocess-platform`, `concurrency-state`,
  `dependencies-build-release`, `api-schema-migrations`,
  `test-infrastructure`, `ui-accessibility-i18n`, `privacy-observability`,
  `generated-provenance`, `unclassified-risk`.
- Base candidate header:
  `[CANDIDATE] | candidate_id | lane | severity | category | file:line | claim | evidence_summary | impact_context | confidence | risk_impact | risk_tags`
- Base clean attestation:
  `[CLEAN] | lane | coverage_scope | evidence`
- Micro/council candidate header:
  `[CANDIDATE] | candidate_id | micro_lane | severity | category | file:line | claim | invariant_violated | evidence_summary | confidence | risk_impact | risk_tags`
- Micro/council clean attestation:
  `[CLEAN] | micro_lane | coverage_scope | evidence`
- Severity is exactly `INFO | LOW | MEDIUM | HIGH | CRITICAL`; confidence is
  exactly `LOW | MEDIUM | HIGH`.

Controller order is exact: bind the immutable head/base range; dispatch,
settle, and parse base lanes; evaluate every trigger row; dispatch micro lanes;
settle and parse every matched micro family; persist the trigger evaluation;
ensure each base/micro child lane submits exactly one child-bound structured
receipt; persist post-explorer findings; run reviewers;
run critics; then persist the final artifact and complete the workflow. Transcript
`[CANDIDATE]` / `[CLEAN]` rows are deprecated legacy compatibility only for
lanes whose snapped `pr_review_legacy_transcript_compatibility` contract
explicitly enables them.
The **initial** micro dispatch MUST supply the complete trigger-evaluation
ledger; that dispatch freezes it for the session.
Any subsequent micro batch in that same session MAY omit `trigger_evaluation`
and reuse the frozen ledger. If a subsequent batch explicitly supplies a copy,
that copy MUST remain exactly identical to the frozen ledger.

All machine-readable candidate headers, candidate rows, and clean attestations
must be emitted as unfenced plain text. Markdown fences shown in this skill are
documentation fences only; emitting the backticks causes the controller to
ignore those rows as quoted/example material.

---

## Review Modes

### Default layered workflow

Always run the default layered workflow (mechanically enforced under Profile A). Explorers produce only candidates. The orchestrator does not confirm or disprove candidates.

### Council mode — opt in only

Council mode applies only when the user explicitly says one of:

- `council`
- `independent review`
- `N-agent review`
- `/council`
- `[COUNCIL MODE]`
- `[MODE: PR_REVIEW … council=true]`
- `assume all work is wrong`

Council mode supplements the default mechanical workflow; it never replaces or weakens it. Even when council mode is triggered, first complete the base-dimension coverage (the tier-floored base dispatch under Profile A — the exact-six wave at depth tier L), micro-lane ledger persistence, and every repository-agnostic risk-family evaluation at the same exact `pr_head_sha`. Route supplementary council output into the candidate ledger before independent reviewer classification. If the council request arrives after classification has begun, run the council as an additional candidate pass and dispatch a new structured reviewer batch for those candidates before synthesis.

---

## Anti-Self-Review Rule

The main thread / orchestrator MUST NOT classify, confirm, disprove, or judge explorer candidates in the default workflow.

The orchestrator may:

- determine scope,
- build or request the context pack,
- launch explorers and the full risk-family micro coverage (every family evaluated; lane count per depth tier and profile),
- extract candidates from lane artifacts via `parse_lane_candidates` (Profile A) or by collecting the structured `[CANDIDATE]` rows from lane reports (Profiles B/C),
- filter, group, and chunk candidates for reviewer dispatch,
- route candidates to reviewers,
- route reviewer-confirmed findings to critics,
- group validated findings,
- prepare the final report.

The orchestrator MUST NOT:

- re-read a candidate's target code to decide if it is valid,
- silently downgrade or discard an explorer candidate,
- treat tool output as a confirmed finding,
- report a finding that no reviewer validated,
- classify or judge candidates based on preview text alone — always use the structured parser output (Profile A) or the verbatim-collected `[CANDIDATE]` rows (Profiles B/C).

If the orchestrator catches itself validating code, it must stop and delegate validation to a reviewer subagent.

Exception: in explicit Council mode only, the main thread may act as the independent reviewer as described in the Council Mode section. Prefer a reviewer subagent when available.

---

## Scope Detection

Determine review scope using this priority:

1. explicit user-provided PR URL, PR number, commit, branch, or file scope,
2. current feature branch diff vs the remote-tracking base ref (`origin/main`,
   `origin/master`; a local `main`/`master` only as a last resort — it is only as
   fresh as the last fetch and yields a different merge base),
3. staged changes,
4. latest commit,
5. user-specified files or directories.

Record:

- base ref,
- head ref,
- commit range,
- changed files,
- deleted files,
- generated files,
- lockfiles,
- test files,
- docs/config/schema files,
- whether the working tree is dirty.

If scope cannot be determined, review the narrowest safe scope available and state the limitation.

### Pre-flight git ref availability

Before launching explorers (Phase 3), perform this exact standalone sequence:

1. Resolve and retain the authoritative full `pr_head_sha` from PR metadata.
2. Verify the working tree is clean with `git status --porcelain`. If it is
   dirty at all — tracked changes, untracked files, or both — call
   `prepare_pr_workflow_checkout` (Profile A). The tool supports
   self-discovery: call it with no `paths` argument to auto-discover and
   preserve every dirty path in one step, including untracked files; an
   already-clean tree returns a no-op (nothing is stashed, no receipt is
   written). Pass explicit `paths` only when you already have the exact,
   bounded list of dirty tracked files and want the older exact-match
   contract. Without the controller (Profiles B/C), do not blind-stash over
   dirty state: surface tracked changes to the user, or abort. Do not issue
   `git stash` through shell.
   Treat the controller's Git-state result as final for this attempt: `clean`
   proceeds, `stashable` permits exactly one checkout-preparation call, and
   `recovery-required` or `indeterminate` means report the typed
   `required_action`, abort/clear any already-active gate, and stop. Retry only
   when the controller explicitly returns `retryable: true`; never fight an
   unmerged index or in-progress Git operation with repeated stash attempts.
3. Fetch the PR head as one standalone command, for example
   `git fetch origin refs/pull/<N>/head`. Do not compose fetch and checkout.
3a. Fetch the base branch as its own standalone command, for example
   `git fetch origin main`. Skipping this is the single most common cause of a
   rejected dispatch: the merge base is recomputed against `base_ref`, and a
   local `main`/`refs/heads/main` that was never refreshed resolves to a
   different commit than `origin/main` for the same `base_sha`.
4. Prove the full commit exists locally with two portable standalone commands:
   `git rev-parse --verify <full_pr_head_sha>^0`, then
   `git cat-file -t <full_pr_head_sha>`. The second command must print
   `commit`. This avoids shell/wrapper parsing differences around the
   `^{commit}` suffix on Windows.
5. Check out the exact PR filesystem with
   `git switch --detach <full_pr_head_sha>`. Do not use `--track FETCH_HEAD`:
   `FETCH_HEAD` is not a remote-tracking branch.
6. Confirm `git rev-parse HEAD` equals the full `pr_head_sha`, bind that exact
   head (Profile A: through the first PR-review controller call; Profiles B/C:
   record it at the top of the findings ledger and repeat it in every lane
   prompt), and finish this before dispatching explorer lanes.

Explorer agents read files from the working tree, not from git history. Passing
the commit range in a prompt cannot substitute for this checkout because
`Read` / `Glob` / `Grep` operate on the filesystem.
- Explicitly pass the verified merge-base range (`base_sha...pr_head_sha`) in every explorer delegation so explorers inspect exactly the bound PR diff. Include `base_ref` only as the live ref used to recompute `base_sha`; do not substitute a two-dot branch-tip range.

If refs cannot be fetched or checked out, state the limitation in the context pack.

### Shell rules under the PR_REVIEW gate

The gate accepts one command per tool call — never compose commands with
`&&`, `;`, shell pipelines, redirects (`>`, `>>`, `<`), or `$(...)`/`` ` ``
substitution. The only literal-pipe exception is inside one closed
double-quoted `gh api --jq` argument with no backslash-escaped nested double
quotes; that escape is ambiguous under `cmd.exe`. The exception does not
permit an outer pipeline or any other control syntax.
A single leading `cd <dir> &&` prefix and a trailing `2>&1` suffix are
tolerated, but only on read-only commands. State-transition verbs — `git
fetch`, `git checkout`, `git switch`, `git branch`, and `gh pr checkout` —
must always run bare: no `cd` prefix, no `2>&1` suffix.

Allowed read-only `git` subcommands: `status`, `log`, `show`, `diff`,
`rev-parse`, `merge-base`, `ls-files`, `grep`, `blame`, `cat-file`,
`for-each-ref`, `branch --list` (listing only — mutation flags are blocked),
`remote -v`, and `config --get`.

Prefer tools over raw shell for state that a single read-only command cannot
cover cleanly:

- `pr_workflow_status` — observe local HEAD, branch, dirty-file state,
  remotes, and gate state in one read-only call.
- `gh_evidence` — bounded PR/issue/run metadata without a shell round-trip.
- If `gh` is not installed, the web fetch tool against the equivalent
  `api.github.com` REST URL is the degraded read-only path.

## Phase 0A: Existing PR Signal Ingestion

When reviewing a PR, ingest and triage every existing signal BEFORE starting
Phase 0. These are candidate generators and obligation sources, not
pre-confirmed findings.

### PR title and body compliance check

Before deeper analysis, discover whether the repository defines a PR
publication contract (for example a local `commit-pr` skill, `CONTRIBUTING`
guidance, a PR template, or a CI check such as `pr-standards`). If it does,
verify the PR against that contract and record any gap as an advisory ledger
item. If it does not, do not invent opencode-swarm-specific title/body
sections; still verify that the PR text is not misleading about what the diff
does or proves.

At minimum, check:

- required title/body/linked-issue structure from the discovered repository
  contract,
- issue-closing, migration, release-note, invariant, or test-plan claims made
  in the PR text,
- whether those claims are supported by the actual diff and the current issue
  state.

**Issue-closing claim-integrity check:** if the PR body uses an issue-closing
keyword such as `Closes #<issue-number>`, verify (a) the issue is currently open
(`gh issue view <N> --json state` when the host is GitHub), and (b) the diff
addresses the issue's acceptance criteria (read the issue, map each criterion
to changed files/symbols, and inspect the diff for those areas). If the issue
is already closed by another merged PR, do NOT re-close it — the duplicate
closing reference is misleading. If the issue is open but the diff does not
address the acceptance criteria, mark the claim as `UNVERIFIED — claim
integrity` in the validation provenance and surface the unresolved gap to the
user before synthesis.

Contract non-compliance is a ledger item (advisory unless the repository
explicitly makes it blocking). If the PR is from an external contributor, note
the compliance gap for the maintainer to address before merge.

This intake includes:

- review comments, review summaries, requested changes, and bot findings,
- CI/check failures, annotations, and relevant logs,
- mergeability/conflicts, `mergeStateStatus`, and stale/base-drift state,
- PR body claims, linked issues, acceptance criteria, and test-plan claims,
- commit messages and app/bot commits on the PR branch.

When multiple CI/check runs have the same name, reconcile them by head SHA and
time: the latest run for the exact bound head SHA supersedes an older same-check
run on that same head. Keep an older failure only as historical diagnostic
evidence; do not report it as the current PR state after a newer same-head run
has completed successfully.

When thread resolution state matters, prefer GraphQL review-thread inspection.
If GraphQL is unavailable, keep the signal and mark
`resolution_state: UNKNOWN`; do not drop it from scope.

### Step 1 — Fetch all PR feedback surfaces

The commands below are GitHub examples. On GitLab, Bitbucket, Gerrit, or
another code host, use the host's API/connector/CLI to enumerate the same full
surface, including pagination and unresolved-thread state. Host choice never
reduces the intake ledger.

```bash
# Issue comments (general PR thread)
gh api --paginate repos/{owner}/{repo}/issues/{PR_NUMBER}/comments

# Review comments (inline code comments)
gh api --paginate repos/{owner}/{repo}/pulls/{PR_NUMBER}/comments

# Review summaries (approve/request-changes/comment events)
gh api --paginate repos/{owner}/{repo}/pulls/{PR_NUMBER}/reviews
```

`--paginate` requests every REST page. These three calls are gate-allowed as
written. A literal jq filter passed as one closed double-quoted `gh api --jq`
argument is also allowed when it needs no backslash-escaped nested double
quotes; use `gh_evidence` when a portable filter cannot meet that shape. A real
shell pipeline to `jq` or another command remains blocked. To
separate bot/automated reviews (Copilot, Codex, CodeRabbit, etc.) from human
ones, apply the same predicate in context to the JSON already returned above
— `user.type == "Bot"` or a `user.login` match against
`bot|copilot|coderabbit|codex` (case-insensitive) — instead of re-fetching
with a shell-side `--jq` filter. `gh_evidence` with `target: "pr"` and
`fields: "comments"` is the sanctioned read-only tool path for the same PR
comment data when a tool call is preferred over a raw shell command. `gh pr
view --json comments,reviews` is convenience-only because those fields have
item caps; never use it as the authoritative "all signals" intake.

### Step 2 — Classify each comment

| Category | Action |
|----------|--------|
| **Human review with file:line evidence** | Add as candidate finding with `source: existing-review` — still needs reviewer validation |
| **Bot/automated finding with specific code reference** | Add as candidate finding with `source: bot-review` — high false-positive rate, treat as unverified |
| **General feedback / style preference** | Add as advisory obligation |
| **Resolved/outdated comment** | Skip — note in report under "Ingested Resolved Comments" |
| **Requested changes not yet addressed** | Add as HIGH-priority obligation |

### Step 3 — Merge into review pipeline

All ingested comments become candidate findings or obligations. They follow the
same Phase 3-8 pipeline as freshly discovered findings. Ingested findings are
NOT pre-confirmed — they still require independent reviewer validation per the
Anti-Self-Review Rule.

**Comment-ledger output:**
```
[INGESTED] | source | category | file:line (if applicable) | original_author | status: PENDING_VALIDATION / SKIPPED_OUTDATED / ADVISORY
```

### Anti-patterns
- ✗ Ignoring bot reviews because "bots produce false positives" — they also catch real issues
- ✗ Pre-confirming human review comments without independent validation — even senior reviewers make mistakes
- ✗ Skipping inline review comments and only reading the summary — inline comments contain the evidence

## Phase 0B: Mergeability and Branch-State Intake

Before investing effort in review lanes, verify the PR is mergeable and record
branch-state signals. `PR_REVIEW` remains read-only: do not resolve conflicts,
commit, push, rebase, merge, or reset from this mode. Instead, carry current
mergeability, stale-head, and branch-drift facts into the review ledger and the
feedback handoff artifact.

### Step 1 — Check merge state

The field names and values below are GitHub-specific examples. On another code
host, record the equivalent mergeability, conflict, required-check, base-drift,
and stale-head signals and preserve the same read-only behavior.

```bash
gh pr view <PR_NUMBER> --json mergeable,mergeStateStatus
```

The response has two independent fields. Handle each:

**`mergeable` field** — whether GitHub can compute mergeability:
| Value | Meaning | Action |
|-------|---------|--------|
| `MERGEABLE` | No conflicts detected | Proceed — check `mergeStateStatus` below |
| `CONFLICTING` | Merge conflicts exist | Record the blocker, keep the review read-only, and hand conflict resolution to `swarm-pr-feedback` |
| `UNKNOWN` | GitHub still computing | Wait 30s, re-check |

**`mergeStateStatus` field** — overall branch state:
| Value | Action |
|-------|--------|
| `CLEAN` | All checks pass, no conflicts — proceed to Phase 0 |
| `BEHIND` | Branch behind base — note in report; non-blocking if merge queue handles it |
| `DIRTY` | Merge conflicts exist — keep reviewing, but record the conflict as a first-class blocker in the ledger and handoff artifact |
| `BLOCKED` | External blocker (branch protection, failing required check) — investigate and record the blocker |

### Step 2 — Record conflicts and blockers (when CONFLICTING or DIRTY)

When the PR has merge conflicts:

1. **Determine the PR's base branch and verify the state**, as separate
   standalone commands — never with `$(...)` command substitution, which the
   PR_REVIEW gate blocks:
   - Read the base ref: `gh pr view <PR_NUMBER> --json baseRefName` (or
     `gh_evidence` with `target: "pr"`, `fields: "baseRefName"`).
   - Fetch it by its literal value, substituted for `<base-ref>`:
     `git fetch origin <base-ref>`.
   - Re-check merge state: `gh pr view <PR_NUMBER> --json
     mergeable,mergeStateStatus,baseRefName,headRefName`.

2. **Capture the affected scope without changing the branch:**
   - List the files or subsystems implicated by the conflict if GitHub exposes them,
     or note that the exact conflict set is still unknown.
   - Identify whether the conflict appears mechanical (lockfile / generated output /
     simple overlap) or semantic (logic changed on both sides). This is triage
     signal for the follow-on feedback run, not permission to resolve it here.

3. **Record explicit next action for the handoff artifact:**
   - `CONFLICT-### | mechanical | likely resolvable during pr-feedback`
   - `CONFLICT-### | semantic | requires focused fix + validation during pr-feedback`
   - `STALE-### | behind base by policy` when the branch is only stale, not conflicted

4. **Document in report:** List the branch-state facts, why they matter to the
   review, and what `swarm-pr-feedback` must verify before it edits code.

### Conflict resolution anti-patterns
- ✗ Accepting "ours" or "theirs" for all conflicts without reading them
- ✗ Resolving semantic conflicts without understanding both sides
- ✗ Pushing resolution without running tests on the merged result
- ✗ Treating `PR_REVIEW` as the place to fix branch state — this mode stays read-only

## Phase 0B-bis: Pre-Handoff Parallel Work Snapshot

When the review surfaces findings that will likely need `swarm-pr-feedback`,
re-check for **parallel work** since the last fetch. The PR author, the bot
reviewer, or another swarm may have pushed commits while you were reviewing.
This is still read-only: capture the remote state so the handoff artifact starts
from the right branch facts.

### Step 1 — Compare remote state (read-only, no post-bind fetch)

Once the PR head is bound, the gate allows only the exact bound tracking
fetch (when one is armed), and a detached review HEAD has no tracking branch
to refetch against — `git fetch origin <pr-branch>` is blocked here. Compare
state through the read-only API instead, as one standalone command:

```bash
gh pr view <PR_NUMBER> --json headRefOid,commits
```

or the equivalent `gh_evidence` call with `target: "pr"` and
`fields: "headRefOid,commits"`. If the returned `headRefOid` differs from the
`pr_head_sha` bound at the start of this review, the remote has moved; the
`commits` field lists every commit's message and author to date, enough to
judge relevance to the pending findings. (The legitimate place to `git fetch`
is the pre-bind sequence under "Pre-flight git ref availability" above — this
step never repeats that fetch post-bind.)

### Step 2 — Evaluate new commits

For each new commit on the remote (identified by comparing `headRefOid` /
`commits` above against the SHA bound at the start of the review):

1. **Read the commit message from the `commits` field above.** For file
   scope, use one standalone read-only call —
   `gh api repos/{owner}/{repo}/commits/<sha>` — rather than a local
   `git show`: the new commit's object is not fetched locally post-bind.
2. **Compare against the pending handoff scope:**
   - Does the remote commit touch the same files as the validated findings?
   - Does the remote commit appear to already address a finding you planned to
     hand off?
   - Does the remote commit introduce a new branch-state fact the handoff should
     mention?
3. **Default stance: prefer the remote state as the next baseline.** When the
   bundled copy is available (plugin runtimes), run the
   `file:.swarm/bundled-skills/parallel-work-check/SKILL.md`
   protocol for the formal decision template; otherwise apply the three
   outcomes below directly. Record the outcome in the handoff artifact.

### Step 3 — Three outcomes

- **Parallel work supersedes:** Mark the older local checkout as stale in the
  handoff artifact and tell `swarm-pr-feedback` to re-check out the current
  remote head before editing.
- **Parallel work complements:** Carry both the validated findings and the new
  remote commits into the handoff artifact so `swarm-pr-feedback` can verify the
  combined state before patching.
- **Parallel work unrelated:** Note that the remote moved, but keep the same
  validated finding set.

### Anti-patterns

- ✗ Pushing your fix without checking if the remote already fixed it — causes
  duplicate work and may even fail the push if the commits conflict
- ✗ Force-pushing over parallel work because "I started this first" — the
  parallel agent may have access to context you don't (different swarm
  configuration, different model, different time budget)
- ✗ Blindly taking remote work without verifying it's actually better — the
  parallel work may be incomplete or take a different approach that doesn't
  match the original finding's intent

### Example: parallel swarm superseded local fix work

See `references/parallel-work-example.md` for the worked PARALLEL WORK CHECK
transcript (remote supersession, abandon-use-remote decision).

---

# Default Review Workflow

## Phase 0: Context Pack and Review Signal Collection

Before launching explorers, build a compact `swarm-pr-review-context`. Under
Profile A, do not create a scratch context-pack file after the controller gate
activates: PR_REVIEW intentionally blocks arbitrary writes. Put the bounded
shared scope, obligations, deterministic signals, and impact hints in
`common_prompt`, and require every lane to inspect the exact bound diff itself.
Under Profiles B/C, keep the context in working notes or a local artifact only
when that runtime permits the write.

The context pack must include, when available:

```json
{
  "scope": {
    "base_ref": "...",
    "head_ref": "...",
    "commit_range": "...",
    "changed_files": [],
    "changed_hunks": [],
    "public_api_changes": [],
    "deleted_or_renamed_files": [],
    "generated_files": []
  },
  "pr_metadata": {
    "title": "...",
    "body_claims": [],
    "checkboxes": [],
    "linked_issues": [],
    "review_comments": [],
    "commit_messages": []
  },
  "obligations": [],
  "repo_graph": {
    "source": ".swarm/repo-graph.json or fallback search",
    "changed_symbols": [],
    "callers": [],
    "callees": [],
    "imports": [],
    "exports": [],
    "sibling_implementations": []
  },
  "deterministic_signals": {
    "ci": [],
    "tests": [],
    "coverage_delta": [],
    "lint_typecheck_build": [],
    "security_scanners": [],
    "dependency_audit": [],
    "secrets_scan": [],
    "mutation_testing": []
  },
  "swarm_artifacts": {
    "evidence_bundles": [],
    "knowledge_hits": [],
    "phase_state": [],
    "metrics": []
  },
  "risk_triggers": []
}
```

### Context pack rules

- Diff-only review is allowed for quick orientation, but not enough to confirm nontrivial findings.
- For every changed production file, identify at least one caller, consumer, import path, route entrypoint, or reason none exists.
- If `.swarm/repo-graph.json` exists, use it to seed impact cones.
- If no repo graph exists, build a shallow impact cone using imports, exports, symbol search, route registration, CLI registration, or test references.
- Pull in relevant `.swarm/evidence/`, `.swarm/state`, `.swarm/knowledge`, or hive/project knowledge entries when present.
- Historical knowledge may guide candidate generation but cannot confirm a finding by itself.
- Mark stale, quarantined, or cross-project knowledge as advisory until independently verified in this repo.

---

## Review Finding Persistence

Do not rely on conversation context to preserve review findings. On Profile A,
use `write_pr_review_artifact` with `kind: "findings"`; the controller creates
and appends `.swarm/pr-review/<run_id>/findings.jsonl` without granting generic
write authority over `.swarm/`. On Profiles B/C, append the same records to a
`findings.jsonl` ledger in your harness workspace (never under `.swarm/`), with
the review head SHA recorded at the top.

Each persisted finding record must include at least:

```json
{"finding_id":"F-001","status":"PENDING","file_line":"src/file.ts:123","evidence":"quote, command output, lane id, or reviewer rationale","next_action":"route_to_reviewer","severity":"HIGH"}
```

Minimum field contract:

- `finding_id`: stable ID from the candidate/reviewer/critic ledger.
- `status`: one of `PENDING`, `CONFIRMED`, `DISPROVED`, or `PRE_EXISTING`.
- `file_line`: exact `file:line`, or `N/A` with reason when cross-file.
- `evidence`: compact source-backed proof (lane/reviewer/critic IDs or command output references when available).
- `next_action`: `route_to_reviewer`, `route_to_critic`, `report`, `suppress_with_reason`, or `handoff_to_feedback`.
- `severity`: REQUIRED at every boundary — omitting it is a violation, not a shortcut. Vocabulary is the VERDICT dialect `INFO|LOW|MEDIUM|HIGH|CRITICAL|NONE`. At `post_explorer` it must equal the severity of the `[CANDIDATE]` row the record projects (so never `NONE`, which no candidate row can declare) — except the mechanically derived `CLEAN-REVIEW` sentinel emitted when discovery found nothing, whose severity is `NONE`; at `post_reviewer` the reviewer `final_severity`; at `post_critic` the **critic** `final_severity` for critic-routed records, otherwise the reviewer's (issue #2279).

Persist after every major validation boundary (Profile A via the controller
calls below; Profiles B/C by appending the same boundary-tagged records to the
ledger file):

1. **Post-explorer:** persist as soon as the base wave settles and its
   candidates parse — BEFORE micro dispatch — by calling
   `write_pr_review_artifact` with `boundary: "post_explorer"` and the
   base-derived candidates as `PENDING` with their lane provenance. This
   base-only write is the compaction recovery point for everything before
   trigger evaluation; it must cover exactly the base-derived inventory
   (micro ids are refused as `extra:` at this point). After trigger
   evaluation a full-inventory `post_explorer` write (base+micro) is also
   admissible and supersedes the early checkpoint as the recovery point.
2. **Post-reviewer:** after Phase 6 reviewer validation, call the controller
   with `boundary: "post_reviewer"` and update each reviewed
   record to `CONFIRMED`, `DISPROVED`, `PRE_EXISTING`, or keep `PENDING` with a
   concrete `next_action` if more evidence is required.
3. **Post-critic:** after Phase 8 critic challenge, call the controller with
   `boundary: "post_critic"` and update final status, the authoritative
   `severity`, and final reporting or handoff action.

**Enforced order, dispositions, and error reporting (Profile A).** The
trigger evaluation must complete before every findings boundary EXCEPT the
base-only `post_explorer` write above, which is admissible right after base
settlement (issue #2280); beyond that exception checkpoints run strictly
`post_explorer` → `post_reviewer` → `post_critic`, each requiring the prior
checkpoint persisted, and `post_reviewer`/`post_critic` must exactly cover
the FULL (base+micro) candidate inventory against the persisted trigger-eval
artifact; records must match the authoritative reviewer/critic
verdict rows, and an invalid payload is rejected in ONE call listing every
violation as `finding_id: field expected <value>, got <value>`. Full contract
(write order, dispositions, severity authority table, handoff schema):
references/findings-persistence-contract.md.

Resume/reload procedure: read the latest `findings.jsonl` and reconstruct the
ledger from disk before dispatching more lanes; the base-only `post_explorer`
checkpoint alone is enough to resume after a compaction between base
settlement and the micro wave (re-dispatch micro, re-run trigger evaluation,
then continue with full-inventory boundaries); surface a missing artifact as
a coverage gap, never reclassify from memory; append (latest record wins).

---

## Phase 1: Intent Reconstruction / Obligation Extraction

Reconstruct what the PR is obligated to deliver before looking for bugs.

Use deterministic precedence, highest to lowest:

1. PR checkboxes and acceptance criteria,
2. linked issues / tickets,
3. explicit user request in the current conversation,
4. commit scopes and commit messages,
5. test names and test assertions,
6. interface diff / exported API changes,
7. changelog, README, migration, or docs edits,
8. LLM synthesis only when no higher-precedence source exists.

Output an obligation list:

```text
O-001 | source | claim | affected files/symbols | status: UNVERIFIED | evidence refs: []
```

For each obligation, record:

- source,
- exact claim,
- affected files or symbols,
- verification status: `UNVERIFIED → IN_PROGRESS → MET / PARTIALLY_MET / NOT_MET / UNVERIFIABLE`,
- linked finding ID when unmet,
- reason if unverifiable.

Tests are claims. A passing or added test does not prove the obligation unless the reviewer inspects the assertion strength and relevant code path.

### Quantitative claim verification

PR body numerical claims (test counts, coverage percentages, assertion counts, performance benchmarks) are obligations, not proof. For each quantitative claim:

1. Extract the claim and its source (PR body, comment, commit message).
2. Verify against actual tool output or CI artifacts when available.
3. If the claim cannot be independently verified, mark the obligation `UNVERIFIABLE` with reason.
4. If the claim is disproved by evidence, create a finding linking the discrepancy.

Common patterns to verify:
- "N tests pass" → count actual test results from CI logs or test runner output
- "N% coverage" → compare against coverage report
- "No regressions" → verify against test runner failure count

---

## Phase 2: Deterministic Signal Ingestion

Ingest deterministic signals as candidate generators. They are never final findings.

Use available local artifacts first. Run safe read-only or standard project validation commands only when appropriate for the environment.

Candidate signal sources include:

- CI failures and logs,
- test failures,
- coverage delta,
- lint/typecheck/build output,
- `git diff --check`,
- dependency audit output,
- lockfile diff,
- CodeQL alerts,
- Semgrep or SAST findings,
- secrets scan findings,
- license scan findings,
- mutation testing output,
- package manager warnings,
- generated schema diffs.

Record each signal as:

```text
[TOOL_CANDIDATE] | tool | severity | file:line | claim | raw_signal_summary | confidence
```

Tool candidate rules:

- Confirm reachability before reporting.
- Confirm PR-introducedness before reporting as a PR blocker.
- When `placeholder_scan` output is used as a signal, pass `added_lines` (file path → PR-added line numbers from the merge-base diff) so only added lines drive the scan; a placeholder finding on an unchanged line is a pre-existing-debt candidate, not a PR blocker. If added-line mapping is unavailable, treat the findings as unscoped and cross-check them against the PR diff before recording the row.
- Confirm that a framework, schema, middleware, caller guard, or test isolation rule does not already mitigate it.
- Do not report scanner output verbatim without reviewer validation.
- Redact secrets; never paste raw credentials into the final output.

---

## Phase 3: Parallel Base Explorer Lanes

### Review depth tiers (size × risk)

Before dispatching, classify the PR into a depth tier from the context pack.
Record the tier and the active capability profile in the ledger and in the
final validation provenance. The tier scales how many subagents you spawn —
never which review dimensions or risk families get evaluated:

| Tier | Diff shape | Dispatch shape (Profiles B/C) |
|---|---|---|
| S | ≤ ~100 changed lines, ≤ 5 files, no risk triggers | Consolidate: 1–2 explorer lanes covering all six dimensions (B), or one candidate-generation pass (C); Phase 4 risk families fold into the same lanes as an explicit per-family checklist |
| M | ≤ ~1500 changed lines, or any risk trigger | Dedicated lanes for the triggered dimensions/families; consolidate the remaining thin dimensions into 1–2 lanes |
| L | > ~1500 changed lines, > ~50 files, multi-subsystem, or security-sensitive surface | Full fan-out: one lane per dimension (six) and per-family micro dispatch in Phase 4 |

Risk triggers (any one escalates to at least tier M, and the triggered
dimension/family always gets a dedicated lane at M and above):
auth/identity/sessions/permissions/secrets/cryptography; untrusted-input
parsing or new input/output boundaries; subprocess/shell/filesystem execution;
concurrency, state machines, retries, caching; dependency, lockfile, install,
CI, or release changes; public API, schema, config, or migration changes;
payments or PII handling; generated, vendored, or binary artifacts.

Scaling is one-directional: a larger tier or an active controller may demand
more lanes than the table; nothing — repository size, elapsed time, token
cost, or predicted simplicity — permits fewer lanes than the classified tier,
and no tier permits skipping a dimension or family. Under Profile A the
controller computes the tier itself from the bound `base_sha...pr_head_sha`
diff (`--numstat` totals; an uncomputable diff fails strict to tier L) and
 mechanically enforces the matching floors on every base and micro batch. When a project explicitly enables the `pr_review_resilience` policy (it is
 DISABLED by default), the initial base wave is
 staged at tiers M/L: `pr_review_wave_stage: "canary"` / `pr_review_wave_attempt: 0`
 launches one singleton base lane first, then
 `pr_review_wave_stage: "fanout"` carries only the remaining unresolved
 obligations in exactly one follow-up fanout batch. Tier S keeps the legacy single
 consolidated base batch because staged resilience does not apply there. If
 that policy is disabled, the initial base wave falls back to the historical
 non-staged behavior: tier L may launch all six singleton base lanes together
 in one batch, while tiers S/M may use consolidated lanes that declare their
 complete `owned_workflow_lanes` set — every dimension still owned exactly
 once and attested. Micro batches retain the historical tier-L full fan-out
 floor (one micro-lane per family on every micro batch, not only the first),
 while tiers S and M may consolidate families so long as every family is still
 owned exactly once and attested per family. With staged resilience enabled, a
 tier-L base **retry** may consolidate only dimensions that are still
 unresolved because their prior attempts reached a recorded terminal failure
 and no lane for that dimension is currently live or in flight, subject to two
 lane floors: no single lane may own all six dimensions, and — counted
 cumulatively across every recorded base batch, not per batch, and including
 batches the capacity GC has since dropped — the six dimensions must stay
 backed by at least four distinct lanes (each dimension no consolidated lane
 claims counts as one, plus the FEWEST declared consolidated lanes that
 suffice to cover the rest). That permits a small consolidation as failure
 recovery and rejects re-doing the whole wave in two or three lanes, whether
 the attempt is disguised as overlapping or duplicate consolidations —
 declaring more lanes than the cover needs buys no budget. Dimensions with a
 successful source are complete and MUST NOT be re-dispatched; dimensions with
 a live or in-flight source are not yet eligible for the retry set. The retry
 attempt itself still stays exactly one singleton canary call plus exactly one
 unresolved-only fanout call, never multiple fanout batches and never a fresh
 all-six singleton re-dispatch. Risk triggers
remain caller-side escalation on every profile: dispatch MORE than the floor
whenever a trigger warrants it.

### Dispatch

Under Profile A, dispatch base lanes with `dispatch_lanes_async`, set
`mode: "swarm-pr-review:base"`, assign each lane its exact `workflow_lane`
identifier from the table below, bind every batch with the exact current
`pr_head_sha`, record each returned `batch_id`, and pass the exact reviewed
merge base and its base ref as `base_sha` and `base_ref`. Use the
REMOTE-TRACKING form for `base_ref` (`origin/main`, not `main` or
`refs/heads/main`) and compute `base_sha` against that same ref, so the
controller's recomputation matches yours. When a project explicitly enables the
`pr_review_resilience` policy (DISABLED by default), tier-M/L initial base dispatch is
 staged exactly as a singleton canary batch (`pr_review_wave_stage: "canary"`,
 `pr_review_wave_attempt: 0`) followed by exactly one fanout batch
(`pr_review_wave_stage: "fanout"`) that include only still-unresolved
obligations. Tier S stays on one consolidated batch. If the policy is
disabled, the legacy non-staged initial base wave is still valid: tier L may
pass all six singleton base specs together in one batch, while tiers S/M may
pass the consolidated batch shape that partitions the same six dimensions.
Every later base retry, micro, council, reviewer, and critic dispatch repeats
those same exact bindings. The controller recomputes
`git merge-base -- <base_ref> <pr_head_sha>`, rejects mismatches, and replaces
caller `scope` text with the complete verified `base_sha...pr_head_sha` PR diff;
caller scope is retained only as a non-authoritative focus hint. Continue only non-dependent architect
work: refine the obligation ledger, inspect PR metadata, prepare micro-lane
trigger checks, and run deterministic read-only local tools. The runtime rejects
partial, duplicate, mislabelled, or non-explorer base waves. Do not synthesize
findings from running lanes. Keep each lane `prompt` compact: send the shared
review context (PR diff, obligation ledger, scope) ONCE via the `common_prompt`
field, or have lanes read it from a file by absolute path, instead of inlining
the same large blob into all six prompts — oversized inline prompts produce
malformed or truncated tool-call JSON and force clumsy file workarounds.

All six dimensions must be covered on every PR — "small PR", "docs-only", and
"CI-only" change what each dimension examines, never whether it is evaluated.
Every dimension ends in its own `[CANDIDATE]` rows or a fully populated
per-dimension `[CLEAN]` attestation. Under Profile A, the top-level
`pr_review_resilience` config (DISABLED by default; opt in with `enabled: true`) requires depth tiers M/L to
stage each base attempt as a singleton `pr_review_wave_stage: "canary"` batch
followed by its matching `"fanout"` batch. Attempt 0 still has to cover all six
dimensions exactly once across the combined canary+fanout ownership: tier M
needs at least three combined lanes, tier L needs six singleton combined lanes,
and every later retry attempt may carry forward only the still-unresolved
obligations into its canary/fanout pair. Use one singleton canary lane; attempts
are numbered with `pr_review_wave_attempt`, and the
policy permits attempt 0 plus two retry attempts (1 and 2). If the project leaves
`pr_review_resilience` at its default `enabled: false`, or the computed tier is S,
Profile A uses the legacy single-wave base dispatch. Under Profiles B/C, the
depth tier governs lane count the same way — a tier-S diff may cover the six
dimensions in one or two consolidated lanes — while dimension coverage and
per-dimension attestation remain mandatory.

Under Profile B, dispatch the same wave as parallel subagents through your
harness's subagent tool: one subagent per dimension by default, consolidated
per the depth tier for small diffs. Every lane prompt must carry the exact
`pr_head_sha`, the verified `base_sha...pr_head_sha` range, its assigned
`workflow_lane` identifier(s), and the explorer context contract below; append
every returned report to the findings ledger with its lane id and head SHA
before any reviewer dispatch. Under Profile C, run the same lanes as
sequential candidate-generation passes with the same per-lane ledger records.
The join barrier is universal: all base lanes settle before Phase 4 completes
or synthesis begins, whichever layer enforces it.

**Incremental collection (Profile A):** While base lanes are running, poll with `collect_lane_results` (without `wait` (or `wait: false`)) to check progress and process settled lanes as they complete — call `retrieve_lane_output` for full text when `output_ref` is present, then extract candidates via `parse_lane_candidates`, update the candidate ledger, validate output quality — while continuing independent architect work (obligation refinement, micro-lane trigger checks, local reads) between polls. Only use `wait: true` if lanes are still pending and no more independent work remains. While polling, a `pending_liveness` entry on a still-pending lane is a DIAGNOSTIC only (issue #2280): `stalledSuspect: true` means the lane has been pending for minutes and the host does not report its session live — note the lane id, `pendingMs`, and `hostStatus` and investigate, but never auto-cancel, retry, or replace the lane on this signal; read `degradedReason` precisely (issue #2815): `probe-skipped-no-budget` means the observer's own probe budget was already exhausted and NO host probe ran — it carries no information about the lane's session — while `probe-timeout` means a probe ran and hit its deadline; either way the ~30-minute presumed-stale sweep remains the only terminal backstop. Under Profile B, harvest each subagent report as it completes and update the ledger between arrivals; block on stragglers only when no independent work remains. **`collect_lane_results` is an OBSERVER (issue #2381).** Its wait budget (`timeout_ms`) bounds THAT CALL ONLY. An expired wait budget does not cancel, kill, or fail a lane, and it is not evidence that a lane died; `timeout_ms: 0` is a valid immediate, non-destructive snapshot, and an unavailable host messages client likewise reports stored lane state without terminalizing anything. Whenever lanes remain unsettled the result carries `pending_lanes` (batch id, lane id, stored status, and `output_ref` when one exists) regardless of `include_pending`, so outstanding work is never silently omitted. When a collection returns pending lanes you have exactly two observer moves: poll again, or let the ~30-minute presumed-stale sweep settle genuinely dead lanes. Explicit cancellation is a separate authorized action (`cancel_lane_batch` with `confirm: true` plus a reason); the collector itself never cancels, and busy/retry lanes are live evidence, not failure. Do NOT abort the PR workflow, re-dispatch the lane, or report a lane as failed merely because an observer call expired or the host client was briefly unavailable.

Inline `output` is delivered on the first poll that observes a lane settled; subsequent polls carry `output_omitted_repeat: true` with metadata and `output_ref`, and full text is retrieved via `retrieve_lane_output`.

Host transport metadata is not stronger than the durable artifact. A truncated inline preview is accepted when its full `output_ref` artifact passes every identity, digest, revision, ownership, and row-coverage check. If the host status call times out, collection treats readiness as unknown and may inspect messages under a separate bounded budget, but it settles the lane only when the latest assistant message carries terminal proof. Only base and micro discovery lanes may retain independently validated positive `[CANDIDATE]` coverage from an incomplete transcript; council, reviewer, and critic outputs remain fail-closed and require retry. Incompleteness can never establish `[CLEAN]`, including for sibling dimensions in a consolidated lane. Every accepted transport recovery is disclosed in `salvaged_workflow_lanes`, with typed per-lane reasons in `salvaged_workflow_lane_recoveries`. See `references/lane-output-recoverability.md`.

Before Phase 4 or synthesis, all base lanes must be settled. `dispatch_lanes_async` accepts a maximum of 8 lanes per call; base lanes (6) and micro-lanes (Phase 4) are dispatched in separate calls by design. Do not let one lane's conclusions bias another lane.

**COVERAGE GATE — zero tolerance for unclosed gaps.** After `collect_lane_results`, verify every lane produced validated output. Two failure modes exist:
- **Mode A (empty output):** Lane returns 0 chars, `status: cancelled`, `output_digest` matches SHA-256 of empty string (`e3b0c442...b855`).
- **Mode B (invalid structured output):** Under Profile A, collection reports `status: failed` with a named contract predicate while retaining the non-empty preview, digest, and `output_ref`; the artifact has zero valid `[CANDIDATE]` rows and no parseable `[CLEAN] | lane | coverage_scope | evidence` attestation. Under Profiles B/C, treat the equivalent non-empty report as failed when parsing yields zero candidates and no valid clean attestation. The non-empty transcript is diagnostic evidence, never coverage proof.

For ANY lane that failed (either mode):
1. **Retry** (initial dispatch plus 2 retries — PR_REVIEW_MICRO_FAMILY_RETRY_BUDGET; each micro-family dispatch acknowledgment records one counted attempt in gate state) with materially different parameters — different session or prompt decomposition, while preserving the required structured async mode and exact head provenance.
2. If a base lane fails under Profile A, retry only the unresolved `workflow_lane` identifiers with `dispatch_lanes_async`, `mode: "swarm-pr-review:base"`, the same exact `pr_head_sha`, explorer agents, and the staged-resilience fields when that policy is enabled: a singleton `pr_review_wave_stage: "canary"` first, then a matching `"fanout"` batch only for the remaining unresolved obligations. The durable gate joins successful provenance across the initial wave and retry batches, carries unresolved obligations forward attempt by attempt, and rejects typed `retry_exhausted` or `circuit_open` outcomes before any new lane is launched. While that controller is active, blocking `dispatch_lanes` and direct Task dispatch are not equivalent because they cannot satisfy the structured provenance gate. Under Profiles B/C, retry only the failed `workflow_lane` identifiers with a fresh subagent or pass, the same exact `pr_head_sha`, and a materially different prompt decomposition.
3. If no equivalent alternative can be verified AND every launched lane is terminal or explicitly cancelled, **settle N-of-6 truthfully (issue #2383)** instead of discarding validated work: admit the terminal settlement with `write_pr_review_artifact` (`kind: "findings"`, `boundary: "post_explorer"`, the sentinel `CLEAN-REVIEW` record when no candidates exist, and `partial_base_coverage: { unresolved_dimensions: [<exactly the dimensions that are not covered>] }`), run the remaining phases over the covered dimensions' findings, and complete with `complete_pr_workflow` carrying the verdict the settlement allows. NEVER fabricate coverage, NEVER present an unresolved dimension as reviewed, and NEVER let a partial report approve.
4. **Terminal report kinds (issue #2383):** all six dimensions covered → `COMPLETE` (verdict may be APPROVE, REQUEST_CHANGES, or INCOMPLETE); at least one covered → `PARTIAL` (verdict must be REQUEST_CHANGES or INCOMPLETE; validated findings from covered dimensions remain publishable); zero covered → `NO_COVERAGE` (skip the findings ladder entirely, call `complete_pr_workflow` with `report_verdict: "INCOMPLETE"` directly — the completion returns a truthful operational report with per-dimension reasons and never claims a code-quality review). A still-live lane blocks settlement: poll again, authorize an explicit `cancel_lane_batch` (`confirm: true` + reason; busy/retry lanes are refused), or let the presumed-stale sweep settle it first.
5. Under Profile A, when the bind/checkout path itself is genuinely unreachable or the workflow is publication-armed and exact publication cannot proceed, use the bounded recovery exits: `abort_pr_workflow` with `mode: "PR_REVIEW"`, `kind: "recovery"`, and a non-empty one-line `reason` for an unrecoverable unbound/bound gate, or `kind: "armed_recovery"` (issue #2383) for a publication-armed wedge — then `prepare_pr_workflow_checkout` with `operation: "restore"`. Abort remains a recovery tool for the genuinely unrecoverable, never a shortcut past a settleable coverage obligation.

### PARTIAL-settlement recovery (all lanes terminal)

Base settlement requires every launched lane to be TERMINAL — settled, failed,
or explicitly cancelled — NOT full coverage. With partial coverage (at least one
dimension covered), the review proceeds instead of aborting: dispatch the FIRST
`swarm-pr-review:micro` batch with the complete 11-row `trigger_evaluation`
parameter inline on `dispatch_lanes_async` (that dispatch freezes the canonical
ledger), persist it with `write_pr_review_trigger_eval`, run the validation
lanes, then finish with `complete_pr_workflow` carrying the verdict PARTIAL
coverage allows (REQUEST_CHANGES or INCOMPLETE — never APPROVE). The
NO_COVERAGE short-circuit applies only at zero coverage. A
`write_pr_review_trigger_eval` rejection saying the canonical ledger is missing
means the first micro dispatch has not frozen it yet — supply the inline
parameter; it is not a deadlock.

### Contract-failure diagnosis and recovery

Under Profile A, `dispatch_lanes_async` adds the authoritative
controller-appended row contract and exact lane identity to every explorer
prompt. Do not duplicate that contract in `common_prompt`: duplicated copies
can drift, compete for prompt budget, and are not the controller's acceptance
boundary.

When collection or a later coverage gate rejects a lane, first isolate the
emitting validator named by the diagnostic. Preserve the rejected artifact and
build a minimal correct single-lane reproduction using the same workflow mode,
lane identity, exact head, and canonical row. Before retrying, distinguish the
three independent input layers: the header schema, data-row values, and tool
argument shape. A correct header does not repair an invalid severity or lane
value, and correct row data does not repair malformed dispatch JSON. Benign shape defects (evidence pipes, marker rows, verdict-row pipes, a header re-emitted as a data row) are auto-repaired and recorded as salvage — never a retry reason alone; the `parse_lane_candidates` receipt discloses them as `repair_kinds`, and a `[CLEAN]` attestation discredited beside a same-lane `[CANDIDATE]` row as `clean_attestation_salvaged` + `clean_attestation_salvage_reason` (the parse SUCCEEDS and the attestation still supplies no coverage) (contract and fidelity boundaries: `references/lane-output-recoverability.md`).

Classify incidents from actual user-visible harm and the first failed predicate; the shared
row parser proves row structure only, a post-hoc fallback is recovery evidence, and the
gate separately verifies durable provenance (see `references/lane-output-recoverability.md`).

If a controller denial omits the failed predicate, expected contract, or lane
identity, record that as an opacity defect and escalate it with the preserved
artifact and minimal reproduction. An opaque denial is not proof that correct
input was rejected. Do not guess at hidden predicates, weaken acceptance, or
switch to blocking/direct-Task dispatch; repair the named contract when it is
available, otherwise stop at the coverage gate with the diagnostic gap.

### Candidate extraction via parser

Under Profile A, after `collect_lane_results` returns for base lanes, process
each lane result that carries an `output_ref`. The orchestrator MUST use the
candidate parser rather than preview-text extraction:

1. For each singleton base `output_ref`, call `parse_lane_candidates` with
   `output_ref`, `producer: "swarm-pr-review"`,
   `expected_family: "base_explorer"`, and `expected_lane` set to the exact
   `workflow_lane` declared at dispatch. For a consolidated tier-S/M lane, call
   the parser once for each owned dimension with that dimension as
   `expected_lane` and pass `expected_lanes` as the lane's complete
   `owned_workflow_lanes` array on every call. The parser reads the full artifact
   from disk (no preview truncation issue), rejects unowned rows, and returns
   structured `ParseResultWithSidecar` records.
2. Filter the returned `candidates[]` by `producer: "swarm-pr-review"` plus the
   exact `source_batch_id` and `source_lane_id` from the base dispatch. Treat a
   family mismatch or parse error as a lane-output failure; family metadata is
   not the acceptance boundary.
3. Group the filtered candidates into reviewer-sized chunks:
   - by file area (group by the directory or module of the `file_line` field),
   - by category (group by the `category` field),
   - by count (target max 50 candidates per chunk; smaller chunks are fine).
4. Stage reviewer-sized chunks, but do not dispatch reviewers yet. Phase 4 must
   complete trigger accounting and settle every launched micro-lane first.

If a lane has `output_degraded: true`, no usable `output_ref`, or `transcript_incomplete: true` without typed positive-candidate recovery, apply the COVERAGE GATE (Phase 3). An incomplete base or micro discovery lane may proceed only when it is explicitly named by a `salvaged_workflow_lane_recoveries` entry whose `kind` is `transcript-incomplete-terminal-candidate`; that recovery validates the retained positive `[CANDIDATE]` row only. Council, reviewer, and critic lanes never qualify for this incomplete-transcript recovery and must retry. Recovery never validates `[CLEAN]`, candidate absence, an unowned sibling lane, or an incomplete lane with no matching entry. Do not use blocking or direct-Task fallbacks while the controller is active, mark affected candidates UNVERIFIED to proceed, or infer candidate absence from a preview. Under Profiles B/C, which have no typed recovery validation, a truncated, incomplete, empty, or attestation-free subagent report is the same lane-output failure and takes the same COVERAGE GATE.

After candidate parsing and before reviewer dispatch, persist the post-explorer
candidate ledger. The base-only write is admissible immediately after base
settlement — it is the durable recovery point for context compaction from base
settlement onward; once trigger evaluation completes, a full-inventory
(base+micro) `post_explorer` write may refresh it ahead of Phase 6.

**Profiles B/C row convention:** without the parser, the `[CANDIDATE]` row
format is the extraction contract itself. Explorers emit the rows directly in
their reports (see the Explorer Prompt Template reference); the orchestrator
collects them verbatim, validates each row's field count and lane id, and
treats malformed rows — or output with neither `[CANDIDATE]` rows nor a fully
populated `[CLEAN]` attestation — as a lane-output failure under the COVERAGE
GATE. If the parser is unavailable under Profile A, the same row convention
applies as a fallback, but the orchestrator SHOULD use the parser as the
primary extraction mechanism.

**lane id uniqueness for parallel dispatches:** When re-dispatching failed or
re-running explorer lanes, every `dispatch_lanes_async` or `dispatch_lanes`
lane `id` MUST be unique within that dispatch batch and should include lane and
attempt suffixes (e.g., `pr_review_explore_lane1_attempt2`). Never reuse an id
in the same batch unless intentionally replacing that exact lane before dispatch.

Explorers optimize for recall. Over-reporting is expected. Explorers produce candidates only.

The six dimensions are a fixed **check-type** partition, not an area
partition: every PR needs all six review dimensions, and the lanes
deliberately overlap by file, each receiving the same diff (via
`common_prompt` under Profile A) and viewing it through a different lens. Six
dimensions are this workflow's high-assurance coverage floor, not a claim that
research proves a universal optimal agent count — the published evidence
favors complementary, distinct-lens reviewers over duplicated generalists, and
finding rates rise with diff size, which is why dispatch (not coverage)
follows the depth tier. Repository policy may add scrutiny but may never
reduce the six dimensions. Coverage is guaranteed by all six dimensions
reading the whole diff, so the disjoint-partition rule that governs area-split
fan-outs does not apply.

| `workflow_lane` | Focus | Required checks |
|---|---|---|
| `intent-architecture` | Intent, scope, architecture, and integration | obligation mapping, design fit, callers/consumers, sibling patterns, docs and claimed-vs-actual behavior |
| `correctness-state` | Functional correctness, data/state flow, edge cases, and failure paths | input domains, nullability, ordering, transactions, error behavior, rollback, backwards behavior |
| `tests-falsifiability` | Tests, test validity, regressions, and claimed validation | assertion strength, negative paths, isolation, fixtures, deterministic timing, missing proof |
| `security-trust` | Security, privacy, trust boundaries, unsafe inputs/sinks, and supply chain | authorization, injection, secrets, provenance, dependency risk, data exposure, abuse paths |
| `reliability-performance` | Reliability, concurrency, retries, resource bounds, and performance | races, retry semantics, timeouts, lifecycle, caching, algorithmic cost, operational failure modes |
| `compatibility-delivery` | API/schema/config compatibility, maintainability, build/deploy, docs, and release behavior | public contracts, migrations, runtime/platform support, packaging, CI, rollout and recovery guidance |

### Explorer context contract

Every explorer must inspect or explicitly mark unavailable:

1. the changed hunk,
2. at least one caller, consumer, or downstream impact-cone node,
3. at least one callee, dependency, or upstream assumption,
4. at least one sibling implementation or prior pattern,
5. the nearest relevant test or missing-test location,
6. deterministic signal entries mapped to its files/symbols,
7. relevant Swarm knowledge/evidence entries, if present.
8. the exact bound review range to analyze (`base_sha...pr_head_sha`),

### Explorer output format

Explorers emit structured candidate records. The parser reads the full lane
artifact and extracts these records. The canonical record shape is:

The fence below is documentation formatting only. Emit the header and all
machine-readable rows as unfenced plain text; do not emit the backticks.

```text
[CANDIDATE] | candidate_id | lane | severity | category | file:line | claim | evidence_summary | impact_context | confidence | risk_impact | risk_tags
```

Profile A now treats `submit_pr_review_result` as the authoritative settlement path for base and micro discovery lanes. The caller-bound structured receipt dominates later prose, truncation, or transcript incompleteness. Transcript candidate/clean rows remain deprecated compatibility only when `pr_review_legacy_transcript_compatibility` was explicitly enabled for that lane and no structured receipt exists; a present-but-invalid structured result fails closed and never falls back.

When compatibility mode is active, Profile A stores the full assistant transcript. The parser locates the first pipe-delimited line whose first field is exactly `[CANDIDATE]`, ignores unmarked preamble, and requires the exact canonical base/micro header; malformed markers or marker-prefixed rows without a header fail closed. The controller refuses a missing marker. Markerless positional fallback remains only for legacy callers outside that trust boundary; explorers should put the canonical header first.

The confidence data value must be exactly LOW, MEDIUM, or HIGH.

Under Profile A the parser-backed transcript path is compatibility-only; a successful `submit_pr_review_result` receipt is authoritative. On Profiles B/C — and on a Profile A lane whose snapped contract explicitly enables deprecated legacy transcript compatibility and lacks a structured receipt — the explorer emits `[CANDIDATE]` rows directly as the extraction contract.

Explorers must not use `CONFIRMED`, `DISPROVED`, or `PRE_EXISTING`.

A base lane that finds no surviving candidates must submit exactly one structured CLEAN result and then stop. Only a lane in the deprecated transcript-compatibility path may instead emit exactly one fully populated clean row:

The fence below is documentation formatting only. Emit the clean attestation
as unfenced plain text; do not emit the backticks.

```text
[CLEAN] | lane | coverage_scope | evidence
```

Header-only `[CLEAN]` markers, prose-only "clean" claims, or empty output do
not settle the lane.

---

## Phase 4: Mandatory Repository-Agnostic Micro-Lanes

After base lanes settle, inspect the exact diff/context pack to focus every row
in the micro-lane map and print a mandatory ledger with one row per map row:

```text
[TRIGGER-EVAL] | trigger_row | MATCHED/NOT_TRIGGERED | focus_evidence
```

Focus evidence must name the changed files, manifests, imports/symbols, semantic
signals, or explicit absence conditions. Use `MATCHED` when the exact diff has
an applicable surface and dispatch that family; use `NOT_TRIGGERED` only when
the row was evaluated and concrete absence evidence proves it inapplicable.
`unclassified-risk` is the always-`MATCHED` fallback. A `NOT_TRIGGERED` row is
not a waiver or a micro artifact and carries no source batch/lane provenance.
Repository identity, technology stack, PR size, elapsed time, or predicted risk
never justifies skipping a row.

Every row in the map is a risk **family** that must be evaluated against the
diff on every PR, in every repository. What scales with the depth tier is the
dispatch shape — how many subagents carry that evaluation — never the
evaluation itself. Each `MATCHED` family must end in its own attestation:
`[CANDIDATE]` rows naming the family, or one fully populated per-family
`[CLEAN]` row. `NOT_TRIGGERED` families end in the ledger with absence evidence
and must not be dispatched.

**Profile A dispatch.** Launch the micro coverage with
`dispatch_lanes_async` and `mode: "swarm-pr-review:micro"`. At depth tier L,
dispatch one focused micro-lane for every `MATCHED` row, each lane's
`workflow_lane` equal to its trigger ID; because the dispatcher accepts at
most eight lanes per call, split large matched sets across bounded async
batches. At tiers S and M,
consolidated lanes may each own several families: set `workflow_lane` to one
owned trigger ID and declare the complete `owned_workflow_lanes` set — every
matched family owned exactly once across the dispatch, and every owned family
attested in that lane's output, or the lane fails for all of them. Include
the complete exact-set
`trigger_evaluation` ledger and the same exact current `pr_head_sha` in the
initial micro dispatch, in a separate batch from base lanes (those inline `trigger_evaluation` rows carry only `trigger_id`, `result`, and `evidence` — they must never include `source_batch_id` or `source_lane_id`, which belong only to `write_pr_review_trigger_eval`'s `rows`). That first
dispatch freezes the ledger for the session. A subsequent same-session micro
batch may omit `trigger_evaluation` and reuse the frozen ledger; when it
explicitly supplies a copy, the copy must remain exactly identical. The
runtime rejects unrelated or duplicate micro-lanes within a batch, and final
ledger persistence rejects any row whose completed owning-lane provenance is
absent. One bounded exception (issue #2835): a sweep-settled liveness-terminal lane may back a `MATCHED` row as a disclosed dead family (never APPROVEable; cancellations never qualify) — conditions in `references/lane-output-recoverability.md`.
Poll incrementally, then settle every launched lane. Persist
the complete ledger with `write_pr_review_trigger_eval`; its rows use the stable
trigger IDs below. Every `MATCHED` row includes its returned `source_batch_id`
and `source_lane_id`; every `NOT_TRIGGERED` row must omit both fields. Missing,
extra, duplicate, malformed, or incorrectly provenanced rows make persistence
fail and Phase 4 BLOCKED. Evidence is frozen by the first micro dispatch and is
authoritative thereafter. The final writer may omit its duplicate `evidence`
fields; if it includes reworded evidence, the writer ignores that copy and
persists the frozen values. It still requires the exact frozen classifications,
plus provenance for every `MATCHED` row. The tool atomically writes
`.swarm/pr-review/<run_id>/trigger-eval.json`, separate from `findings.jsonl`;
pass the exact reviewed merge-base as `base_sha`, the exact live base branch
tip/ref used to compute it as `base_ref`, and the same `pr_head_sha` to the
writer. The writer runs bounded `git merge-base -- <base_ref> <pr_head_sha>` and
rejects any claimed `base_sha` that is not the exact result. When that bounded re-check is unavailable (git timeout, spawn failure, unresolvable ref) but the supplied `base_ref` and `base_sha` exactly equal the durably bound review scope, the writer proceeds and discloses `base_verification: bound_fallback` on the receipt, which synthesis must surface in the final review report (`references/lane-output-recoverability.md`); every other outcome stays fail-closed. It accepts only an
exact eleven-row v2 receipt backed by verifiable provenance (identity, ownership, digest, retained artifact); a coverage-QUALITY failure is disclosed on the receipt as `coverage_degradations` and the run proceeds, with synthesis disclosing degraded families (`references/lane-output-recoverability.md`). `NOT_TRIGGERED` rows are provenance-free. Counts are recomputed and
must agree. It never uses keyword or path classification alone as absence
evidence. Any head mismatch makes persistence fail. Historical unversioned and
schema-v1 all-`MATCHED` receipts remain readable, but new writes are strict v2.
Do not add trigger results to the finding-status enum.

**Profiles B/C dispatch.** Scale the lane shape to the depth tier while
keeping all eleven family evaluations:

- Tier L: one focused lane per `MATCHED` family, mirroring Profile A.
- Tier M: dispatch the `MATCHED` families across at least the controller's
  matched-set consolidation floor; `NOT_TRIGGERED` rows remain ledger-only.
- Tier S: dispatch the `MATCHED` set in one or more consolidated micro lanes or
  sequentially separated passes; keep `NOT_TRIGGERED` rows ledger-only.

Whatever the dispatch shape: the ledger keeps one `[TRIGGER-EVAL]` row per
family; each `MATCHED` row's focus evidence names the lane or pass that
evaluated it and gets its own `[CANDIDATE]`/`[CLEAN]` attestation naming the
family id; each `NOT_TRIGGERED` row records absence evidence without an
artifact; and the completed ledger is persisted as `trigger-eval.json` in the
session/task workspace before reviewer dispatch. A matched family with no
attestation row is an unclosed coverage gap.

For each micro lane in Profile A, prefer the single structured
`submit_pr_review_result` receipt over transcript parsing. Only for a lane
whose snapped contract explicitly enables deprecated transcript compatibility
and lacks a structured receipt should you fall back to `parse_lane_candidates` against its `output_ref`, with
`producer: "swarm-pr-review"`, `expected_family: "micro_lane"`, and
`expected_micro_lane` set to the launch-micro-lane value from the
provenance-linked trigger row. When the artifact came from a consolidated
tier-S/M lane (its dispatch declared more than one `owned_workflow_lanes`
entry), also pass `expected_micro_lanes` set to that lane's complete
`owned_workflow_lanes` array — the same set already declared at micro
dispatch time. Without it, the parser has no way to tell a sibling owned
family's row from a genuinely out-of-scope one: every row belonging to the
lane's other owned families is treated as a parse error instead of being
skipped as out-of-scope, which can also invalidate that lane's own otherwise-valid
`[CLEAN]` attestation for the family being extracted. Omit `expected_micro_lanes`
only for a singleton (tier-L) lane. Accept a candidate only when its `producer`,
`source_batch_id`, and `source_lane_id` match an allow-listed tuple from the
original or retry micro dispatch and its `micro_lane` matches that trigger row;
never filter acceptance by `row_format_family`. A zero-candidate artifact is
clean only when the parser returns exactly one provenance-matching persisted
`clean_attestation` whose `micro_lane` matches the trigger row, zero parse
errors, zero malformed rows, and a complete, non-degraded source:

```text
[CLEAN] | micro_lane | coverage_scope | evidence
```

Header-only or malformed zero output is `UNATTESTED`; apply the COVERAGE GATE (Phase 3). Under Profile A, the structured async PR-workflow path must preserve `L1`, exact-head, batch, and workflow-lane provenance; the active controller rejects blocking and direct-Task substitutes, and Task-derived findings or CLEAN prose cannot satisfy Phase 4's controller ledger unless the lane explicitly runs deprecated transcript compatibility. Under Profiles B/C, acceptance is the row contract: accept a candidate or clean row only when its `micro_lane` matches the trigger row, and treat prose-only "clean" claims as `UNATTESTED`.

Each micro-lane receives:

- exact files and hunks in scope,
- related obligations,
- impact cone entries,
- relevant deterministic signals,
- related historical knowledge with quarantine/staleness status,
- expected invariants,
- structured candidate output — parser-extracted under Profile A; on Profiles
  B/C the micro-lane emits `[CANDIDATE]`/`[CLEAN]` rows directly as the
  extraction contract.

### Repository-agnostic mandatory micro-lane map

Every row is evaluated in every repository. Diff/context analysis determines
whether it is `MATCHED` or `NOT_TRIGGERED`; paths or keywords alone are not
sufficient absence evidence. Repository policy
may require supplementary specialist review outside this canonical ledger, but
supplementary work never replaces these portable rows. The `unclassified-risk`
family is always `MATCHED` to cover novel failure modes and classification gaps.

> **Trigger-ID namespace — do not mix (issue #1931).** The `trigger_id` field
> passed to `write_pr_review_trigger_eval` accepts **only** the 11 micro-lane
> IDs in the table below. Three different namespaces appear in this skill and
> they are NOT interchangeable:
>
> | Namespace | Example values | Used where? | Valid as `trigger_id`? |
> | --- | --- | --- | --- |
> | Micro-lane IDs (this table) | `auth-identity-secrets`, `untrusted-input-boundaries`, ... | `workflow_lane` of `swarm-pr-review:micro` dispatch; `trigger_id` of trigger-eval rows | **YES — only these** |
> | Base-lane IDs | `intent-architecture`, `correctness-state`, `tests-falsifiability`, `security-trust`, `reliability-performance`, `compatibility-delivery` | `workflow_lane` of `swarm-pr-review:base` dispatch; validated by `enforcePrReviewBaseDimensions` | NO |
> | Dispatch modes | `swarm-pr-review:base`, `swarm-pr-review:micro`, `swarm-pr-review:reviewer`, `swarm-pr-review:critic` | `mode` field of `dispatch_lanes_async` | NO |
>
> The writer rejects unknown trigger IDs with the list of valid IDs. Short
> informal names (`correctness`, `security`, `deps`, `docs`, `tests`, `perf`)
> sometimes appear in prose summaries; they are shorthand, not literal IDs.

| Trigger ID | Scope | Trigger in diff or context pack | Launch micro-lane | Invariants to check |
|---|---|---|---|---|
| `auth-identity-secrets` | universal | authentication, authorization, identity, sessions, permissions, secrets, cryptography | Identity and secret boundaries | least privilege, confused-deputy paths, credential lifecycle, cryptographic misuse, safe defaults |
| `untrusted-input-boundaries` | universal | parsing, serialization, queries, templates/rendering, file or network input/output | Untrusted input and sink analysis | injection, traversal, SSRF, unsafe deserialization, output escaping, resource limits |
| `subprocess-platform` | universal | subprocesses, shell commands, filesystem operations, OS/runtime-specific code | Subprocess and platform safety | array argv, bounded execution, path containment, portability, cleanup, non-interactive behavior |
| `concurrency-state` | universal | queues, caches, retries, transactions, locks, state machines, async coordination | Concurrency and state transitions | races, atomicity, idempotency, retry accounting, rollback, stale state, bounded growth |
| `dependencies-build-release` | universal | dependency manifests, lockfiles, installers, build scripts, CI, packaging, deployment | Dependency and delivery integrity | provenance, version/lock consistency, install safety, platform matrices, rollback and release completeness |
| `api-schema-migrations` | universal | public API, wire/schema/config/storage formats, migrations, feature flags | Compatibility and migration safety | backward/forward compatibility, defaults, validation, mixed-version operation, recovery |
| `test-infrastructure` | universal | tests, mocks, fixtures, harnesses, coverage, CI matrices | Test validity and isolation | meaningful assertions, contamination, determinism, negative paths, cross-platform proof, test theater |
| `ui-accessibility-i18n` | universal | user interfaces, interaction flows, rendering, accessibility, localization | UI and human-interface quality | keyboard/screen-reader behavior, focus, error states, responsive behavior, locale-safe formatting |
| `privacy-observability` | universal | telemetry, logs, analytics, traces, retention, diagnostics | Privacy and observability safety | minimization, redaction, consent, retention, stable metrics, non-gameable evidence |
| `generated-provenance` | universal | generated, vendored, binary, model-produced, codegen or checked-in build artifacts | Generated artifact provenance | reproducibility, source linkage, tamper evidence, reviewable diffs, licensing and stale output |
| `unclassified-risk` | universal | any changed artifact or behavior not confidently classified by the rows above | Unclassified high-risk fallback | full change-path review, hidden trust boundaries, novel failure modes, missing specialist classification |

Micro-lane output format:

The fence below is documentation formatting only. Emit the header and all
machine-readable rows as unfenced plain text; do not emit the backticks.

```text
[CANDIDATE] | candidate_id | micro_lane | severity | category | file:line | claim | invariant_violated | evidence_summary | confidence | risk_impact | risk_tags
[CLEAN] | micro_lane | coverage_scope | evidence
```

---

## Phase 5: Swarm-Native Verifier Routing

Use Swarm-native agents and artifacts when available. If exact agent names are unavailable, route the same task to the closest equivalent reviewer/critic role. On harnesses without the plugin, most `.swarm/` artifacts will not exist: mark those rows N/A in the validation provenance rather than fabricating them.

| Swarm verifier / artifact | When to use | Purpose |
|---|---|---|
| `critic_drift_verifier` | obligation-vs-code, docs-vs-code, phase/gate changes, schema/config changes | detect drift between stated behavior and actual implementation |
| `critic_hallucination_verifier` | external APIs, package claims, URLs, CLI flags, GitHub behavior, model/tool names | verify claims against source or mark as unverified |
| `curator_phase` | before exploration and after synthesis | retrieve relevant lessons; write back confirmed true positives / false positives |
| `test_engineer` | confirmed/borderline correctness, security, state, schema, or config findings | propose or run falsification probes and regression tests |
| `.swarm/repo-graph.json` | all nontrivial code changes | build impact cones and sibling-pattern checks |
| `.swarm/evidence/` | schema, phase, state, council, and guardrail changes | verify evidence compatibility and serialized provenance |
| Tool-returned `.swarm/evidence/` artifacts | after synthesis | record review quality only at paths actually returned by invoked evidence tools; never invent a metrics path |

Verifier output is advisory until incorporated by the independent reviewer or critic.

---

## Phase 6: Independent Reviewer Confirmation

**Reviewer-dispatch join barrier:** reviewer dispatch MUST NOT begin until the
exact eleven-row micro-lane ledger is complete and persisted, every launched
`MATCHED` micro lane is settled with its owned families attested or disclosed as a dead family on the trigger receipt (#2835), every
`NOT_TRIGGERED` row has concrete absence evidence and no provenance, and every
accepted micro result has parser-derived provenance (Profile A) or a valid
CLEAN attestation.

Route candidates to reviewer subagents. The orchestrator routes candidates
in bounded chunks produced by the candidate extraction in Phase 3-4. Each
reviewer lane receives a bounded list of candidates from a single chunk — by
file area, category, or count — not the full candidate set. The reviewer must
re-read the candidate's file:line evidence and relevant context pack entries
directly.

A reviewer or critic chunk may own any non-empty subset of the current
inventory. On a retry, that subset may overlap prior successful work; the lane
contract is the assigned item set for that chunk, not a requirement to re-own
the full inventory every time.

Under Profile A, dispatch reviewer chunks with `dispatch_lanes_async`,
`mode: "swarm-pr-review:reviewer"`, a unique non-empty `workflow_lane` per
chunk, `review_item_ids` containing the exact candidate IDs assigned to that
chunk, reviewer-role agents only, and the same exact `pr_head_sha`. The runtime
requires one parseable `[REVIEWED]` row for every structurally assigned ID; a
single marker or partial subset cannot settle the lane. Direct Task
reviewers are rejected by the active controller because they cannot carry the
durable batch and head provenance it requires. Under Profile B, dispatch each
chunk to a fresh reviewer subagent — never the agent or conversation that
generated the candidates — carrying the chunk's candidate IDs, the exact
`pr_head_sha`, and the required checks below. Under Profile C, run a separate
reviewer pass per chunk that re-reads every cited file:line before
classifying. The one-parseable-`[REVIEWED]`-row-per-assigned-ID contract is
universal.

Under Profile A, for every structured PR-review dispatch, the runtime appends
an authoritative controller block after caller-authored prompt text. It binds the exact
`workflow_lane`, PR head, content revision, declared scope, and assigned item
IDs and explicitly forbids speed/time/token waivers. Caller prompt text cannot
override that block; output with placeholders, invented IDs, generic assurances,
or evidence unrelated to the bound lane does not settle the artifact.

Reviewer ownership is not accepted as an architect assertion. Under Profile A,
the controller derives the immutable candidate inventory from the
integrity-checked base, mandatory micro-lane, and council artifacts; under
Profiles B/C, the orchestrator derives the same inventory from the persisted
ledgers. Either way, successful reviewer batches compose item by item: the
union of their accepted `review_item_ids` must equal that inventory exactly,
with the newest successful verdict winning for each item. If discovery produces
no candidates,
the derived sentinel is `CLEAN-REVIEW`, which still requires one independent
semantic reviewer row (a fresh subagent on Profile B; a separate reviewer pass
on Profile C).

Candidate IDs must therefore be globally unique across every discovery
artifact in the run. Prefix IDs with the stable workflow-lane ID (or use
another deterministic globally unique scheme); duplicate IDs fail closed
instead of being silently merged.

### Noise budget and universal validation

Before reviewer dispatch, the orchestrator may suppress candidates that match ANY of the following (each suppression still requires mandatory disclosure):
- purely stylistic without correctness, security, test, maintainability, or user-impact implications,
- exact duplicates of a candidate already queued for validation,
- explorer-stated confidence=LOW with zero structural evidence (no file:line, no code path, no invariant reference).

Every suppressed candidate must appear in the final report under "Suppressed Candidates" with the reason. Suppression without disclosure is a hard rule violation.

**All remaining candidates — regardless of severity — must be routed to independent reviewer validation.** Severity alone does not determine validation eligibility; it determines routing priority. A LOW-severity candidate with file:line evidence and a specific code path gets the same reviewer attention as a HIGH-severity candidate.

Candidates not routed to reviewers must be listed as UNVERIFIED with reason in the validation provenance. Do not silently drop them.

### Reviewer required checks

For each candidate, the reviewer must determine:

- exact file:line evidence,
- whether the issue is introduced by this PR or pre-existing,
- reachability from realistic execution paths,
- whether caller guards, schema validation, middleware, framework defaults, feature flags, or state-machine constraints mitigate it,
- whether tests cover the negative path,
- whether sibling files or docs must change together,
- whether the severity is justified,
- the smallest falsification probe that would prove or disprove it.

### Reviewer classifications

| Classification | Meaning |
|---|---|
| `CONFIRMED` | Evidence is real, reachable or structurally proven, and introduced or exposed by this PR |
| `DISPROVED` | Candidate claim is incorrect, unreachable, mitigated, or based on a misunderstanding |
| `UNVERIFIED` | Available evidence is insufficient to determine validity |
| `PRE_EXISTING` | Issue exists on the base branch and is not materially worsened by this PR |

### Evidence classifications

| Type | Definition |
|---|---|
| `STRUCTURALLY_PROVEN` | File:line evidence directly demonstrates the bug or violated invariant |
| `EXECUTION_PROVEN` | A test, trace, reproduction, or command demonstrates failure |
| `STATIC_TRACE_PROVEN` | Static analysis plus reviewed path/context demonstrates reachability |
| `PLAUSIBLE_BUT_UNVERIFIED` | Pattern suggests risk, but reachability or mitigation is unresolved |

Reviewer output format:

```text
[REVIEWED] | item_id | classification | evidence_type | severity | introduced_by_pr | file:line | rationale | probe | reviewer_notes | risk_impact | risk_tags
```

For the mechanically derived `CLEAN-REVIEW` sentinel, use the same exact row
with `DISPROVED | STRUCTURALLY_PROVEN | NONE | UNKNOWN | N/A` and concrete
rationale/probe/reviewer fields; the sentinel means the reviewer independently
found no surviving actionable candidate, not that reviewer validation was
skipped.

Every reviewer response must end with one parseable `[REVIEWED]` row per
assigned candidate. A malformed `[REVIEWED]` row is not a verdict: re-dispatch
with the exact contract (max 2), then mark the reviewer dimension BLOCKED if no
valid row returns.

`DISPROVED` reviewer rows must use `NONE` for `final_severity`. `PRE_EXISTING`
findings must include the base-branch evidence if available.

After reviewer lanes settle, persist the post-reviewer finding ledger before
critic routing or synthesis. The artifact must preserve `CONFIRMED`,
`DISPROVED`, `PRE_EXISTING`, and still-`PENDING` records with reviewer IDs and
next actions.

---

## Phase 7: Falsification Probe Requirement

Each confirmed nontrivial finding must include at least one falsification artifact:

- runnable failing command,
- proposed regression test,
- mutation that current tests fail to kill,
- static-analysis trace,
- minimal execution path,
- exact reason no runtime probe is available.

Nontrivial means any finding that affects correctness, security, state transitions, write authority, git safety, config, schema/evidence integrity, model/tool permissions, external fetches, persistence, or user-visible behavior.

A finding may still be reported without a runnable command if it is structurally proven, but the report must state why a runtime probe was not available.

---

## Phase 8: Critic Challenge

Route reviewer-confirmed CRITICAL and HIGH findings to a critic always. Route a MEDIUM finding only when its typed risk metadata says so (issue #2383): `risk_impact: "HIGH_IMPACT"`, or any `risk_tags` entry (`SECURITY`, `AUTH_PERMISSIONS`, `STATE_INTEGRITY`, `WRITE_PATH`, `EVIDENCE_INTEGRITY`, `GIT`, `CONFIGURATION`). An ordinary MEDIUM (`risk_impact: "ORDINARY"`, no tags) is NOT critic-routed. `risk_impact: "UNKNOWN"` always routes to critic — never guess impact you could not assess, and never let file paths, dimension names, or prose override the typed `risk_impact`/`risk_tags` the reviewer row carries.

The controller derives critic ownership from the typed reviewer rows through the one shared production predicate; every newly written CONFIRMED finding must supply `risk_impact` and `risk_tags` (the write boundary rejects a CONFIRMED record without them, and unknown tag values fail the row). Completion is blocked until that exact derived inventory has valid critic rows.

Reviewer and critic settlement MUST compose successful verdicts item by item
across complementary partial batches. The newest successful claim wins each
item; malformed or stale batches contribute nothing without erasing healthy
sibling claims. Collection MUST validate exact lane ownership atomically, and
critic claims MUST bind to the exact reviewer row for their item. Settlement is
item completeness, not lane completeness. Follow the full retry, legacy,
binding, and diagnostic contract in
[`references/verdict-settlement-contract.md`](references/verdict-settlement-contract.md).

Under Profile A, dispatch critic chunks with `dispatch_lanes_async`,
`mode: "swarm-pr-review:critic"`, a unique non-empty `workflow_lane` per
chunk, `review_item_ids` containing the exact finding IDs assigned to that
chunk, critic-role agents only, and the same exact `pr_head_sha`. The runtime
requires one parseable `[CRITIC]` row for every structurally assigned ID and
requires the reviewer phase to have settled — every item in the current
inventory holding a successful reviewer verdict, composed across batches —
before a critic wave.
Under Profile B, dispatch each critic chunk to a fresh subagent that was
neither the explorer nor the reviewer for those findings; under Profile C, run
a separate critic pass. The one-parseable-`[CRITIC]`-row-per-assigned-ID
contract and the reviewer-before-critic ordering are universal.

The critic must challenge:

- severity inflation,
- weak or incomplete evidence,
- missing mitigating context,
- false reachability assumptions,
- framework or middleware defaults,
- schema validation gates,
- state-machine constraints,
- feature flags or dead code,
- pre-existing status,
- non-actionable or unsafe fix recommendations,
- sibling-file gaps,
- whether multiple comments should be grouped into one root cause.

Critic output format:

```text
[CRITIC] | item_id | status | severity | rationale | required_change
```

## Verdict row contract

The `[CRITIC]` row in the format above is **mandatory contract**, not advisory output. A critic response that does not end with that exact row format is treated as a planning preamble, not a verdict, and must be re-dispatched. Do not proceed past Phase 8 join barrier until each dispatched critic lane has produced a parseable `[CRITIC]` row.

**Re-dispatch trigger:** when a critic lane response is missing the verdict row, the orchestrator must automatically re-dispatch that lane with the explicit instruction: "Your final line MUST be exactly the Phase 8 contract row: `[CRITIC] | item_id | status | severity | rationale | required_change`. Use only enum values from `references/findings-persistence-contract.md`. A response without that exact row will be treated as a planning message and re-dispatched." Do not synthesize findings from the planning preamble; only from the re-dispatched verdict.

`NEEDS_MORE_EVIDENCE` is deliberately non-terminal and never satisfies critic
settlement. Re-dispatch a narrower critic/probe lane or report the dimension
BLOCKED. Terminal critic rows are cross-field checked: `DISPROVED` requires
`NONE`, `UPHELD` requires CRITICAL/HIGH/MEDIUM, and `DOWNGRADED` cannot remain
CRITICAL.

**COVERAGE GATE alignment:** Critic lane failures apply the COVERAGE GATE (Phase 3) — under Profile A via `dispatch_lanes_async` with `mode: "swarm-pr-review:critic"` and the same exact `pr_head_sha`; under Profiles B/C via a fresh critic subagent or pass. Do NOT mark findings UNVERIFIED or continue past the gap. The orchestrator NEVER fabricates a critic verdict by parsing prose, by tolerating a planning preamble, by presenting partial findings as complete beyond the truthful N-of-6 settlement, or by silently accepting reduced coverage.

Refuted findings become `DISPROVED` or `ADVISORY`, depending on critic rationale. Downgrades must be listed in the final validation provenance.

After critic lanes settle, persist the post-critic finding ledger before final
synthesis. This artifact is the source of truth for resumed reporting and for
any later `swarm-pr-feedback` handoff.

---

## Runtime-Aware False-Positive Guard Checklist

Before confirming any finding, the reviewer and critic must check all that apply:

- [ ] Schema validation gate: does schema validation reject malformed input before the flagged line?
- [ ] Middleware interception: does middleware handle the request or command before the flagged path?
- [ ] Framework default mitigation: does the framework inherently prevent this class of issue?
- [ ] Caller context correctness: who invokes this code, and can untrusted input reach it?
- [ ] Execution reachability: is the path reachable, or behind a feature flag, dead branch, build-only path, or commented-out code?
- [ ] State-machine constraints: do ordering rules, locks, mutexes, phase gates, or transition guards prevent the state?
- [ ] Permission boundary: does role/tool mapping prevent the operation?
- [ ] Data lifetime: is the flagged state persisted, serialized, logged, or only transient?
- [ ] Cross-platform behavior: does Windows/macOS/Linux path or shell behavior change the result?
- [ ] Test environment mismatch: is the finding only true under a mock or fixture that cannot occur in production?

If a mitigation applies and was not accounted for, downgrade to `ADVISORY`, `UNVERIFIED`, or `DISPROVED`.

---

## Phase 9: Synthesis, Grouping, and Noise Budget

Before final output:

- group duplicate candidates by root cause,
- report one finding per root cause,
- attach all affected file:line references under that finding,
- separate ship blockers from advisory notes,
- suppress pure style/nit findings unless they indicate correctness, security, test, maintainability, or user-impact risk,
- distinguish PR-introduced from pre-existing,
- distinguish confirmed from plausible-but-unverified,
- include disproved agent/tool claims,
- keep final comments actionable.

### Finding ID format

```text
F-001 | severity | category | root cause | affected file:line refs | reviewer | critic status
```

### Suggested final grouping

1. Ship blockers,
2. Important non-blockers,
3. Test / coverage gaps,
4. Pre-existing issues,
5. Unverified plausible risks,
6. Disproved candidates / false positives,
7. Clean lane summary.

---

## Phase 10: Metrics and Knowledge Writeback

At the end of the review, include review quality metrics in the final report's
validation provenance. Persist them only through an invoked evidence tool and
record the exact `.swarm/evidence/` path returned by that tool; if no invoked
tool supports metrics (including all of Profiles B/C), state `NOT PERSISTED —
no metrics evidence writer` and keep the metrics block in the final report and
session ledger rather than naming a nonexistent command or path.

Record:

- raw candidates by base lane,
- raw candidates by micro-lane,
- deterministic tool candidates,
- reviewer-confirmed findings,
- reviewer-disproved findings,
- reviewer-unverified findings,
- critic-upheld findings,
- critic-downgraded findings,
- critic-disproved findings,
- final reported findings,
- suppressed non-actionable candidates,
- recurring false-positive patterns,
- commands or probes used,
- token/time cost if available,
- accepted/fixed findings when known.

Knowledge writeback rules:

- Write back only validated true positives or validated false-positive patterns.
- Include file patterns, invariant, evidence, and why it was confirmed/disproved.
- Mark repo-specific lessons as project-tier unless there is strong evidence they generalize.
- Never promote quarantined or unvalidated knowledge to hive-tier.
- Never store secrets, private tokens, or raw sensitive logs.

---

## Phase 11: Post-Fix Re-verification

When the PR author pushes fixes after a review, perform a targeted re-verification before updating the verdict.

### Re-verification scope

Only re-verify findings the author claims to have fixed. Do not re-run the full review pipeline.

### Re-verification steps

1. For each finding the author claims fixed:
   a. Read the changed file(s) from the updated branch at the specific lines referenced in the original finding.
   b. Verify the fix addresses the root cause, not just the symptom.
   c. Check that the fix does not introduce a new issue in the same area.
2. Run CI checks on the updated branch to confirm no regressions.
3. For findings the author did not address, carry forward the original finding with unchanged status.

### Re-verification output

```
[REVERIFIED] | finding_id | FIXED / PARTIALLY_FIXED / NOT_FIXED / NEW_ISSUE | evidence | updated_severity
```

- `FIXED`: the root cause is resolved and no new issue introduced.
- `PARTIALLY_FIXED`: the root cause is partially addressed or a residual concern remains.
- `NOT_FIXED`: the root cause persists unchanged.
- `NEW_ISSUE`: the fix introduced a new problem at the same location.

Update the verdict only after re-verifying all previously blocking findings.

---

For the full parser-based candidate extraction dry-run example, read `references/parser-dry-run.md`.

---

# Council Mode Workflow

Council mode is opt-in only and adversarial.

When triggered:

1. Build the same context pack as default mode.
2. After the default base-dimension and risk-family coverage is complete, launch all supplementary council agents. Under Profile A, use one `dispatch_lanes_async` call with `mode: "swarm-pr-review:council"`, the same exact `pr_head_sha`, and one unique `workflow_lane` per council member; continue independent context preparation while they run, polling with `collect_lane_results` (without `wait`) to process settled agents incrementally, and use `wait: true` only when no independent work remains. All agents must be settled and their candidates added to the ledger before reviewer classification; under Profile A the runtime enforces this join barrier, and blocking, sequential, or direct-Task fallback is not equivalent to the structured council dispatch — bypassing the active controller is `BLOCKED`. Under Profile B, dispatch council members as parallel subagents with the same marker contract and settle them all before reviewer classification; under Profile C, run each council lens as a separate sequential pass.
3. Each council agent assumes all work is wrong until code evidence proves otherwise.
4. Each agent hunts within its lane only.
5. Council uses the micro-lane row family: `[CANDIDATE] | candidate_id | micro_lane | severity | category | file:line | claim | invariant_violated | evidence_summary | confidence | risk_impact | risk_tags`. Emit one row per `EVIDENCE_FOUND` or `SUSPICIOUS` claim, or a fully populated `[CLEAN] | micro_lane | coverage_scope | evidence` row when no candidate survives. Put the exact council `workflow_lane` value in the `micro_lane` data field. Council prose without one of those markers does not settle the lane.
6. Agents must not return `CONFIRMED`, `DISPROVED`, or final severity; candidate severity remains provisional until reviewer classification.
7. The independent reviewer then classifies every council candidate as `CONFIRMED`, `DISPROVED`, `UNVERIFIED`, or `PRE_EXISTING`.
8. Apply critic challenge to reviewer-confirmed HIGH/CRITICAL or borderline findings.
9. Final synthesis distinguishes real blockers, real low-severity issues, accepted caveats, disproved council claims, and follow-up quality work.

Default council lanes:

- correctness and edge cases,
- security and trust boundaries,
- dependency and deployment safety,
- docs and intent-vs-actual,
- tests and falsifiability,
- performance and architecture when risk justifies it.

Council prompt requirements:

- branch and commit range,
- context pack summary,
- files owned by that lane,
- relevant impact cone,
- explicit checklist,
- strict output cap,
- `EVIDENCE_FOUND / SUSPICIOUS / CLEAN` only,
- file:line evidence required for `EVIDENCE_FOUND`.

Council findings are supplementary, not authoritative overrides. Do not adopt council severities or claims without independent validation.

---

# Merge Recommendation Table

| Verdict | Condition | `report_verdict` |
|---|---|---|
| `APPROVE` | zero unresolved CRITICAL findings, zero unresolved HIGH findings, all blocking obligations MET, no required validation phase failed | `APPROVE` -> APPROVE |
| `APPROVE_WITH_NOTES` | zero unresolved CRITICAL findings, HIGH findings are downgraded/advisory only, obligations MET or explicitly non-blocking | `APPROVE_WITH_NOTES` -> APPROVE |
| `REQUEST_CHANGES` | any unresolved HIGH finding, any NOT_MET blocking obligation, multiple MEDIUM findings with the same root cause, or validation/probe evidence indicates user-impacting risk | `REQUEST_CHANGES` -> REQUEST_CHANGES |
| `BLOCK` | any unresolved CRITICAL finding, unsafe write/git/security issue, evidence integrity break, role/tool permission bypass, or config ratchet violation that can disable required protections | `BLOCK` -> REQUEST_CHANGES |
| `INCOMPLETE` | machine-only terminal - forced under NO_COVERAGE, permitted under PARTIAL or COMPLETE (issue #2383) | `INCOMPLETE` -> INCOMPLETE |

---

# Hard Rules

0. Quality-over-speed: Validation completeness and correctness are the sole criteria for an acceptable review. Time, token count, and agent dispatch count are irrelevant. Do not trade validation breadth or depth for speed.

1. Never APPROVE with unresolved CRITICAL findings.
2. Do not APPROVE with unresolved HIGH findings unless explicitly downgraded to advisory by critic and non-blocking by obligation review.
3. Every confirmed finding must have file:line evidence and validation provenance.
4. A confirmed nontrivial finding must include a falsification probe or an explicit reason no probe is available.
5. Explorers, council agents, and deterministic tools produce candidates only.
6. The default workflow orchestrator must not confirm or disprove explorer candidates.
7. Tool output is not proof. Scanner results must be validated for reachability, PR-introducedness, and mitigation context.
8. PR text, generated summaries, tests, and comments are claims, not proof.
9. Do not invent facts not supported by the diff, repo context, tool output, or cited external source.
10. Do not silently drop disproved or downgraded claims; summarize them in validation provenance.
11. Obligation precedence is deterministic. Do not skip higher-precedence sources to fill gaps with LLM synthesis.
12. Do not leak secrets from logs, evidence bundles, config files, URLs, or scanner output.
13. Do not recommend destructive git or filesystem actions as fixes unless they are clearly scoped, safe, and necessary.
14. If subagents fail, timeout, or return malformed output, retry with corrected parameters (the initial attempt plus up to 2 retries — aborting after only the first retry is one bounded retry early) through the dispatch mechanism of the active profile — Profile A: the same structured `dispatch_lanes_async` workflow mode and exact `pr_head_sha`, where blocking or direct-Task dispatch cannot preserve the durable provenance contract and is not an equivalent fallback; Profiles B/C: a fresh subagent or pass bound to the same exact `pr_head_sha`. If retries fail, the affected coverage dimension is BLOCKED and must be surfaced to the user before synthesis — except that a micro family whose every lane is liveness-terminal with no retained artifact settles through the disclosed dead-family path on the trigger receipt (issue #2835; the micro-family dispatch ledger enforces the retry budget mechanically — three recorded dispatch attempts before the admission stops failing closed) instead of BLOCKED, and abort is legitimate only after that settlement path has been exhausted or is unavailable. Do not fabricate validation results, do not present partial findings as complete or beyond the truthful N-of-6 settlement (issue #2383), and do not silently mark candidates UNVERIFIED to proceed past the gap.

15. If context pack, repo graph, deterministic signals, or Swarm artifacts are unavailable, retry with alternative access paths. If a source that should exist on the active profile is still unavailable after retry, the affected coverage dimension is BLOCKED and must be surfaced to the user. A source that cannot exist on the active profile (for example `.swarm/` artifacts outside Profile A) is marked N/A in the validation provenance instead — N/A is disclosure, never a waiver of the dimensions and families that must still be covered. Do not proceed to synthesis with unclosed coverage gaps under a "best available evidence" rationale — the architect is not authorized to produce a degraded review that hides a coverage gap; the disclosed N-of-6 PARTIAL/NO_COVERAGE settlement (issue #2383) is the only sanctioned partial exit.

---

# Pre-Synthesis Gate — Mandatory

Before writing the final output, print this checklist with filled values. Every blank field means the final output is invalid.

```text
[VALIDATION] scope selected: ___
[VALIDATION] capability profile (A/B/C) and depth tier (S/M/L): ___ / ___
[VALIDATION] context pack built: YES/NO — ___
[VALIDATION] obligation count: ___
[VALIDATION] repo graph / impact cone source: ___
[VALIDATION] deterministic signals ingested: ___
[VALIDATION] lane dispatch mechanism: controller / native subagents / sequential passes — ___
[VALIDATION] terminal coverage: COMPLETE (6/6) OR PARTIAL (___/6 + unresolved dimensions settled) OR NO_COVERAGE (0/6) (issue #2383; lanes dispatched: ___)
[VALIDATION] base explorer lanes returned: ___ / ___
[VALIDATION] micro risk families evaluated and attested: ___ / 11 OR BLOCKED — <missing rows> (micro lanes dispatched: ___)
[VALIDATION] Swarm verifier routing used: ___
[VALIDATION] raw candidates: ___
[VALIDATION] tool candidates: ___
[VALIDATION] reviewer lanes dispatched: ___
[VALIDATION] reviewer lanes returned with parseable `[REVIEWED]` rows: ___ / ___
[VALIDATION] findings confirmed by reviewer: ___
[VALIDATION] findings rejected by reviewer as false positive: ___
[VALIDATION] findings marked PRE_EXISTING: ___
[VALIDATION] findings left UNVERIFIED: ___
[VALIDATION] findings escalated to critic: ___
[VALIDATION] critic dispatched: ___ OR "SKIPPED — no typed critic-routed finding (CRITICAL/HIGH, MEDIUM+HIGH_IMPACT, MEDIUM+risk_tags, or UNKNOWN)"
[VALIDATION] critic returned: ___ OR "N/A"
[VALIDATION] findings upheld by critic: ___
[VALIDATION] findings downgraded by critic: ___
[VALIDATION] findings disproved by critic: ___
[VALIDATION] falsification probes included: ___
[VALIDATION] grouped root-cause findings: ___
[VALIDATION] metrics / knowledge writeback: ___
[VALIDATION] all explorers verified to diff against PR branch, not HEAD: YES/NO
[VALIDATION] noise-filter suppressed candidates: ___ (count, each with reason in final report)
[VALIDATION] all non-suppressed candidates routed to reviewer: YES/NO
```

If any reviewer lane lacks a parseable `[REVIEWED]` row after bounded
re-dispatch, the reviewer dimension is BLOCKED. Do not infer or silently
downgrade a verdict.

**COVERAGE GATE CONDITION:** If ANY validation dimension shows incomplete coverage that was not settled through the truthful N-of-6 terminal settlement (issue #2383) — lanes that failed and were not closed by retry or verified equivalent alternative, CI that did not run, tools that were unavailable after retry — the Pre-Synthesis Gate FAILS — apply the COVERAGE GATE (Phase 3). Do not proceed to final output. Surface unclosed gaps with exact failing dimensions and retry/equivalence evidence.

---

# Final Output Format

Produce the final review in this order:

## PR intent

Summarize the obligations and user-visible intent.

## Implementation summary

Summarize what changed, including major files, public APIs, schemas, configs, tests, and Swarm artifacts.

## Intended vs actual mapping

| Obligation | Source | Actual evidence | Status | Linked finding |
|---|---|---|---|---|

Use `MET`, `PARTIALLY_MET`, `NOT_MET`, or `UNVERIFIABLE`.

## Validation provenance

Include:

- context pack limitations,
- explorer lanes launched and returned,
- micro-lanes triggered,
- deterministic signals ingested,
- reviewer identity / role for each finding,
- critic result for each escalated finding,
- findings DISPROVED by reviewer with reason,
- findings DOWNGRADED by critic with reason,
- findings left UNVERIFIED with reason.

If zero findings, explicitly state:

```text
No confirmed findings — all validated lanes CLEAN.
```

Then provide a lane-by-lane clean summary.

## Confirmed findings

For each finding:

```text
F-001 — Severity — Category — Root cause
Files: path:line, path:line
Status: CONFIRMED / critic status
Evidence type: STRUCTURALLY_PROVEN / EXECUTION_PROVEN / STATIC_TRACE_PROVEN
Why it matters:
Validation:
Falsification probe:
Suggested fix:
```

## Pre-existing findings

List separately from PR-introduced findings.

## Unverified but plausible risks

Only include if useful and clearly labeled as unverified.

## Test / coverage gaps

Focus on missing tests that would catch real risks, not generic coverage requests.

## Disproved candidates and false positives

List concise reasons for notable false positives from explorers, tools, council agents, or reviewers.

## Verdict

Use one display verdict; the value after `->` is its exact `complete_pr_workflow`
`report_verdict` (#2494 vocabulary bridge; severity/action policy owned by #2491):

- `APPROVE` -> APPROVE
- `APPROVE_WITH_NOTES` -> APPROVE (notes stay in the report body)
- `REQUEST_CHANGES` -> REQUEST_CHANGES
- `BLOCK` -> REQUEST_CHANGES

## Merge recommendation

Explain the recommendation in one short paragraph and list required actions before merge if applicable.

## Feedback handoff

When the review produced actionable validated findings or operational blockers,
call `write_pr_review_artifact` with `kind: "handoff"` (Profile A). The controller writes
`.swarm/pr-review/<run_id>/feedback-handoff.json` only when its finding IDs
exactly match the latest confirmed `handoff_to_feedback` records. On Profiles
B/C, write the same handoff content to the session/task workspace path
described in "Handoff To PR Feedback" and reference that path in the
continuation prompt. Include:

- the handoff artifact path,
- the preserved finding IDs and provenance that `swarm-pr-feedback` must carry
  forward,
- and an explicit question asking whether to continue into
  `swarm-pr-feedback`.

Use this exact continuation prompt format, substituting the exact path from
whichever profile applies (`.swarm/pr-review/<run_id>/feedback-handoff.json`
under Profile A, or the session/task workspace path under Profiles B/C — never
mix the two):

```text
/swarm pr-feedback <PR_URL> continue from <handoff_artifact_path>
```

Writing the validated handoff durably records one consent offer bound to the exact workflow instance, handoff digest, PR head/URL, and actionable finding set; the first exact continuation confirms it and transitions modes. Internal creation never auto-routes, and malformed, non-actionable, or detached records cannot start PR_FEEDBACK.

---

For reviewer, critic, and explorer prompt templates, read `references/prompt-templates.md`.

Under Profile A, after metrics and durable review artifacts are complete, but
before emitting the user-facing final report, call `complete_pr_workflow` with
mode `PR_REVIEW`, the same exact
`pr_head_sha`, and the terminal `report_verdict` the coverage kind allows (issue #2383). The tool refuses to clear the session gate while required base,
trigger, declared reviewer/critic, or open-lane obligations remain incomplete.
While the gate remains active, the runtime prepends a workflow-active banner
to the first substantive text part of each architect message (the model's text
is preserved below the banner; later parts of the same message, and blank
parts, are left untouched) and re-wakes an idle parent session. A
user interruption pauses every automatic wake path until a later explicit user
turn settles; the durable gate remains available to continue or abort. Only
emit the final report after the completion tool confirms that the gate cleared.
If it reports `checkout_restore_required`, call
`prepare_pr_workflow_checkout` with `operation: "restore"` before returning to
the user. When `checkout_restore_receipts` lists multiple entries, one restore
call reapplies all receipts that share the recorded destination; an optional
listed `stash_oid` is an exact inventory assertion, not a selector that leaves
the other receipts pending. Successfully applied stashes remain in Git as
explicit safety backups and are listed in `retained_stash_oids`; the controller
never drops a mutable `stash@{n}` selector. Restoration is
conservative: a dirty/conflicted checkout, mixed destinations, another active
PR session, a missing stash, or an invalid recovery receipt returns a
manual-recovery diagnostic without resetting or dropping preserved state.
Legacy receipts derive the exact original commit from the stash and restore a
uniquely matching local branch when one exists (otherwise detached).

Under Profiles B/C, no mechanical response gate exists: the Pre-Synthesis Gate
checklist is the completion gate. Emit the final report only after every line
is filled, every dimension and family attested, and every BLOCKED item surfaced.

## Aborting an unrecoverable review (Profile A)

The mechanical gate can leave the session stuck if the PR head cannot be
fetched or checked out — for example when a compound `git fetch … && git
checkout …` is repeatedly rejected as read-only shell syntax (the runtime
requires each git intake command to be a single standalone command), when
the PR ref is missing, or when the working tree is on the wrong branch and
the merge-base bind can never verify. In that state the response gate
suspends further auto-resumes for either of two independent reasons: a
small number of consecutive unproductive wakes (the durable gate `revision`
did not advance), or the total wake ceiling being reached (tier-scaled
defaults S=12 / M=54 / L=102, overridable via the `totalWakeCeiling`
option, and in-memory/per-process so the count resets on plugin reload and
when the durable gate clears — but NOT across the PR_REVIEW → PR_FEEDBACK
handoff, which keeps accumulating). Either suspension appends a
`pr_workflow_wake_suspended` record to `.swarm/events.jsonl` naming the
reason, both counters, the tier, and the ceiling in force — read that first
when diagnosing why a review stopped resuming. Either way, the only exits
are:

1. **Diagnose and retry the canonical standalone sequence.** Run
   `git fetch origin refs/pull/<N>/head`, verify with
   `git rev-parse --verify <full_pr_head_sha>^0` and
   `git cat-file -t <full_pr_head_sha>` (which must print `commit`), then run
   `git switch --detach <full_pr_head_sha>`. Do not use `--track FETCH_HEAD`.
   Confirm `git rev-parse HEAD` equals the authoritative PR head, then recompute the exact
   merge base with `git merge-base -- <base_ref> <pr_head_sha>` (single
   command) and retry the `swarm-pr-review:base` dispatch with the exact
   `pr_head_sha`, `base_sha`, and `base_ref`.
2. **Call `abort_pr_workflow`** with `mode: "PR_REVIEW"`, `kind: "recovery"`,
   and a one-line `reason` describing the blocker. The tool clears the durable gate state
   and stops the auto-resume loop. It refuses only while PR workflow lanes are still LIVE (a recent `updatedAt`); collect those with `collect_lane_results` first.
   Lanes idle past the 30-minute staleness horizon settle as presumed-stale instead of blocking, disclosed as `presumed_stale_lanes` on the response and in `.swarm/events.jsonl`; a schema-invalid (but JSON-parseable) gate state no longer defeats abort either. See `references/lane-output-recoverability.md`.
   It accepts both unbound and bound PR_REVIEW workflows so an unrecoverable
   bind/checkout blocker cannot strand the gate. Settled discovery or validation
   lanes with incomplete coverage use the truthful N-of-6 settlement path instead
   of aborting. An audit event is appended to `.swarm/events.jsonl`.
   When the tool reports `checkout_restore_required`, immediately call
   `prepare_pr_workflow_checkout` with `operation: "restore"`; do not leave the
   user detached from their original checkout with a hidden preserved stash.
3. **Ask the user to run `/swarm abort-pr-workflow`** (a human-only
   restricted command; the agent cannot invoke it via `swarm_command`).
   This is the recovery path when the wake budget has suspended and the
   architect cannot make further tool progress.

A second, unrelated stranding class is **trigger-ledger drift**. This is not a
fetch/checkout problem: it means a later micro-lane explicitly supplied a
`trigger_evaluation` that disagrees with the canonical ledger frozen by the
first micro dispatch. A same-session retry may instead omit that argument and
reuse the frozen ledger. When a later dispatch does supply a copy, the run
fails closed in two places, with different strictness — at ledger bind time
`bindPrReviewTriggerLedger` rejects a trigger_evaluation whose frozen-row digest
(`trigger_id`, `result`, and `evidence` together) differs from the first
dispatch's, and at receipt finalize time `write_pr_review_trigger_eval` rejects
rows whose per-family `result` (classification) differs from the frozen ledger.
The finalize gate is deliberately narrower than the bind gate: evidence may be
omitted or reworded at the receipt, but classifications must still agree. If a
later dispatch genuinely cannot converge with the frozen ledger, the exits are
the abort paths listed above (`abort_pr_workflow` or `/swarm abort-pr-workflow`),
or re-dispatching the disagreeing lane so its trigger_evaluation converges with
the frozen ledger before re-binding.

Abort is a recovery tool, not a coverage shortcut. Use it only when the
bind/checkout path is genuinely unreachable; never use it to skip a coverage
obligation that is still recoverable, merely expensive, or inconvenient. When
lanes have settled short of full coverage, the terminal N-of-6 settlement (issue
#2383) is the truthful exit — not abort. For a publication-armed workflow whose exact
publication cannot proceed, `abort_pr_workflow` with `kind: "armed_recovery"`
(plus the armed recovery identity fields from `pr_workflow_status`) is the
audited escape: it settles lanes, invalidates the staged publication
authorization, preserves validated work, and leaves a recoverable terminal
state; exact approved publication via `complete_pr_workflow` remains available
and preferred whenever it can proceed.

On Profiles B/C there is no durable gate or auto-resume loop to clear: if the
head bind is genuinely unreachable or bounded lane recovery is exhausted,
report the blocker to the user and stop.
