# Agent OS: the Council — Design Spec

Date: 2026-07-01
Status: approved-pending-review
Scope: the whole operating model (firstmate + claude-pm-system + stone-skills)
Build order: Phase 1 detailed here; Phases 2–5 outlined, each gets its own spec.

## Problem

The operating model already has council-shaped parts — specialist read-only
agents, a sole-writer crewmate, a false-green gate ledger — but verification
between "crewmate says done" and "captain accepts done" is **disciplinary, not
structural**. `done:` in `state/<id>.status` is self-reported; `eng-gate-verifier`
exists but nothing forces it to run. This is loop-engineering's anti-pattern #1
(the maker grading its own homework) and the most common failure mode of agent
pipelines (the verifier gets skipped).

Secondary problems, deferred to later phases: no thinker panel at intake, zero
loop-engineering conformance (no LOOP.md / budget / run-log / constraints /
loop-audit score), and a split-brain skill graph (discipline skills in
stone-skills, council/runtime skills unlinked in ~/.claude/skills).

## Decisions (captured with the design)

- **Council mix:** Claude-first. Claude does thinker + worker. The verifier
  stage adds a *foreign lens* for blind-spot coverage: **Fugu → codex → none**,
  in that order, degrading loudly, never silently.
- **Native primitives:** GA core only for the spine (subagents, hooks, ledger).
  Experimental agent teams reserved for Phase 5 thinker panels, easy to disable.
- **loop-engineering (cobusgreyling) is the bible:** adopt the discipline
  (maker/checker, default-REJECT verifier, attempt caps, L0→L3 ladder, state
  files) in Phase 1, and the actual tools (`loop-audit` as a CI gate,
  `loop-cost`, `loop-sync`) in Phase 3.
- **Role bindings** (TRINITY vocabulary → ours):
  - Coordinator → **firstmate** (routes, never does the work; `decide-or-delegate` is its brain)
  - Thinker → parallel read-only specialist panel (`eng-architecture`, `eng-security`, `eng-researcher`, Explore) — formalized Phase 2
  - Worker → **crewmate** (sole writer, worktree, brief contract) — unchanged
  - Verifier → **`eng-gate-verifier`** fresh-context default-REJECT + foreign lens — Phase 1
- **Stop condition:** verifier APPROVE over an *acceptable* ledger — not a green one.
  A green ledger is unsatisfiable by construction wherever `gates/accepted-red.md`
  declares a baseline, and this repo declares two.
  Acceptable is defined once, in `fm_gates_classify` (`bin/fm-gates-lib.sh`), and
  never restated. Never the worker's claim.

## Phase 1 — the Quarterdeck (structural verifier stage)

`done:` becomes **a claim, not an acceptance**.

### Flow

1. Crewmate appends `done: <line>` to `state/<id>.status` (unchanged).
2. Watcher wakes firstmate (unchanged). Firstmate's first act on a `done:` for a
   **ship** task is now `bin/fm-verify.sh <id>` — never direct acceptance.
3. `fm-verify.sh`:
   a. **Adjudicates the gate ledger structurally, ahead of both models**
      (see *Gate adjudication* below). An unacceptable ledger rejects or
      escalates without spending the lens or the verifier.
   b. Runs the **foreign lens** on the crewmate's diff: Fugu (`fugu` model,
      OpenAI-compatible `https://api.sakana.ai/v1`, key `FUGU_API_KEY`) with
      fallback to `codex exec` (subscription-authed CLI), producing
      `data/<id>/lens-review.md`. If neither is available: log
      `lens: none (degraded)` and continue. Every hop is logged; no silent skip.
   c. Spawns **`eng-gate-verifier`** in a fresh context against the crewmate's
      worktree, with `data/<id>/brief.md` + the lens review as evidence.
      Verifier re-executes the DoD claims itself and never trusts the
      crewmate's report. Default stance: REJECT.
      It does **not** adjudicate the gate ledger and its prompt carries no gate
      rule: that decision was already made in (a), and two authorities over one
      decision is what produced the defect below.
4. Verdict is appended to **`state/<id>.verdict`** — same append-only grammar
   as `.status`, one line per event:
   - `approve: <one line>`
   - `reject: <reason>` (attempt N of 3)
   - `escalate: <reason>`
   - `lens: fugu|codex|none <one line>`
5. **Hard gates:** `fm-merge-local.sh` and `fm-pr-check.sh` refuse to proceed
   unless the last verdict line for `<id>` is `approve:`. The backlog item may
   not move to `## Done` without it. Structural — scripts enforce it, not prose.
6. **On reject:** findings relayed to the crewmate via `fm-send.sh`; status
   returns to `working:`. **Attempt cap = 3** total verify attempts, then
   `escalate:` to the captain (loop-engineering: hard cap → human gate).

### Gate adjudication (amendment)

`bin/fm-verify.sh` did not know `gates/accepted-red.md` existed. Its verifier
prompt said *"If a gates/ dir exists here, run: bash gates/verify.sh — every
gate must be green; red or unproven gates are an automatic reject."*
That is unsatisfiable in any repo holding a declared red, and this one holds
two (`gate-l2-loop-audit-level`, `m1-hook-registered`).
Acceptance therefore depended on whether the LLM verifier happened to reason
about the baseline on that particular run — correct work was rejected
non-deterministically, after the build, the pipeline, and CI.
CI honoured the baseline; the verifier contradicted it, and the verifier was
the one that was wrong.

**One owner.** `fm_gates_classify` in `bin/fm-gates-lib.sh` is the rule's only
implementation. `tests/run-all.sh` and `bin/fm-verify.sh` are its two callers;
`bin/fm-brief.sh`'s `GATE_CHECK` clause and this spec cite it rather than
restate it. Its prose reasoning lives in `gates/accepted-red.md`.

**Classification is not policy.** The classifier is pure: it reads exactly
`gates/ledger.json` and `gates/accepted-red.md`, takes the root as an argument,
and answers one question per gate — acceptable or not, and why. It never
invokes `gates/verify.sh` or the `ledger` CLI, because `ledger verify` re-runs
every gate, **rewrites the ledger inside the worktree it is pointed at**,
demotes `frozen` gates to `green`, and is absent in CI. What to *do* with the
answer belongs to each caller: `run-all.sh` skips a test, `fm-verify.sh`
rejects or escalates.

**Acceptable** is `green`, `frozen`, or (`red` **and** declared in
`gates/accepted-red.md` with a stated reason).
`frozen` is proven *and* mutation-verified *and* locked — `ledger verify`
demotes it to `green`, so it is strictly stronger than green, and `ledger
verify`'s own definition of done (an empty WIP drain list) excludes it.
Anything else is unrecognised and fails closed.

**Which way each condition fails**, on the `fm-verify.sh` path:

| condition | outcome | why |
| --- | --- | --- |
| no `gates/` dir | proceed | Most projects firstmate ships to have no ledger at all; escalating on a missing file would stop every one of them. Never an escalation. |
| red, declared with a reason | proceed | The baseline is the point. |
| red, undeclared | **reject** | Crewmate-actionable: go green, or get the red declared. |
| `gates/` but no `accepted-red.md` | **reject** any red | No declarations exist, so every red is undeclared by construction. A fully green ledger with no `accepted-red.md` still passes. |
| a gate's `test_ref` names a file not on disk, in a gate **this branch touched** | **reject** | A ledger claiming green for a gate whose test is gone is stale by construction. |
| the same, in a gate this branch did **not** touch | **report** | Neither this nor `unproven` is visible to CI - `run-all.sh` iterates `tests/*.test.sh` on disk, so a ledger citing a deleted test never fails the suite. Rejecting repo-wide therefore rejected *every* ship task dispatched into a repo carrying that debt, three times, then escalated, over work the crewmate did not do and could not undo - the same defect class this stage exists to remove, only deterministic instead of random. So it is named in the stage's output as pre-existing ledger debt and does not reject. See "whose debt is it" below. |
| `gates/` but no `ledger.json`, with `gates/verify.sh`, `gates/accepted-red.md` or `gates/LEDGER.md` present | **escalate** | The repo declares itself gate-governed and the record of what is proven is absent. Infrastructure, not work. `LEDGER.md` belongs in that evidence set because `ledger verify` regenerates it, so it exists in every gate-governed repo, whereas a repo with no declared reds legitimately has no `accepted-red.md` and `gates/verify.sh` is a firstmate convention rather than something the CLI creates - without it, a gate-governed repo holding only `ledger.json` + `LEDGER.md` whose `ledger.json` went missing proceeded *silently*. |
| `gates/` but no `ledger.json`, `verify.sh`, `accepted-red.md` or `LEDGER.md` | proceed | A directory named `gates/` is not a claim of gate governance - it is an ordinary directory name (a Go package, a Python module, a state-machine dir), and `fm-verify` runs against every ship task in every project firstmate manages. Keying the escalation on the NAME conscripted unrelated repos into a captain escalation on every single task, with no crewmate-side remedy and no override short of `FM_VERIFY_OVERRIDE`. What claims governance is the machinery. This is policy, so it lives in `fm-verify.sh`; `fm_gates_classify` still reports `NOLEDGER`, because that header is a shared contract with `run-all.sh`, which has its own answer (skip nothing, out loud). |
| ledger unreadable or wrong shape | **escalate** | A parse failure is not a finding a crewmate can fix by editing code. "Wrong shape" includes a `gates` value that is not a JSON array: `CONTRIBUTING.md` and frozen gate `m0-ledger-shape` both make that fatal, so it is never coerced into a list — an object would otherwise yield zero rows and read as acceptable. An *empty* array is valid and acceptable. It also includes any gate whose id, status, or test path carries a tab or newline: the classifier rows are tab-separated, so a delimiter in a structural field forges an extra row, and one crafted gate id was enough to make `run-all.sh` skip an arbitrary failing test over an all-green ledger that declared nothing. The same refusal covers a field's TYPE: a missing or non-string `id` or `status` used to stringify to the literal `"None"`, collapsing two id-less gates onto one key, and a present-but-non-string `test_ref` yielded no `.test.sh` token and quietly exempted that gate from the freshness cross-check - a fail-open dressed as a no-op. A *missing* or null `test_ref` stays legitimate, because it genuinely means this gate has no freshness check. |
| status `unproven`, in a gate **this branch touched** (untouched: **report**, as above) | **reject** | Recognised, not acceptable, and crewmate-actionable. `CONTRIBUTING.md` ("Born-green gates are refused") records that the harness stamps `unproven` whenever a gate test passes while `first_observed_red` is null, so it is the ordinary transient state of gate-driven development and the commonest non-clean status a crewmate can produce. The fix is work - register the gate while its test genuinely fails and let `ledger verify` stamp `first_observed_red` itself - so it goes back to the crewmate, never to the captain. The classifier reports it under its own verdict, `bad-unproven`, so the two failure directions cannot be collapsed again. |
| unrecognised status | **escalate** | Never a pass; a ledger this repo cannot interpret needs a human. |
| classifier returns a header outside `NOGATES`, `NOLEDGER`, `BADLEDGER`, `NOACCEPTED`, `OK` | **escalate**, naming the header | The header set is a cross-file contract, documented under "Headers:" in `fm-gates-lib.sh`. An unrecognised header carries no rows this stage can read, so every filter came back empty and the stage announced "gates: acceptable" over a ledger it had read not one gate from - the accept path claiming a property it never established, the same fail-open shape already closed twice inside the classifier (the non-array coercion, the all-or-nothing row build). Naming the header lets the captain tell a version skew from a corruption. The gate stage is now entered on a positive test (`OK` or `NOACCEPTED`) rather than by excluding the two known-inapplicable headers, so an unrecognised one cannot reach it at all. |
| a declared red whose declaration this branch added itself | **escalate** | `gates/accepted-red.md` calls itself a deliberate, reviewable statement, so a line a branch writes into its own diff has been reviewed by nobody. A crewmate whose gate will not go green could otherwise excuse it by writing the excuse, and both this stage and `run-all.sh` would honour it. It escalates rather than rejects because adding a baseline is legitimate work that a human still has to approve. Only declarations the ledger actually *relies on* count - declaring a green gate, or one absent from the ledger, excuses nothing. If the base cannot be resolved, or `gates/accepted-red.md` does not exist there, every relied-upon declaration is unverifiable and it escalates: fail closed. |

**The base comparison lives in the policy layer, not the classifier.**
Whether a declaration was ever reviewed is a question about *git history*, and
the classifier is pure by contract - two files, root as an argument, no other
I/O.
So `bin/fm-verify.sh` answers it, and it answers it by running the same
classifier a second time over the worktree's own ledger paired with the **base**
copy of `gates/accepted-red.md`.
A gate the worktree calls a declared red and the base calls an undeclared one is
a declaration this branch introduced.
The declaration format therefore still has exactly one parser.
The declared-red set reaches that comparison as an `awk` **input file**, never as
`awk -v`: `awk` escape-processes a `-v` assignment, so a gate id holding the two
characters `\n` arrived inside `awk` as a real newline and split into two keys
while the base row still carried the literal backslash — the set never matched,
and a red the branch excused itself walked straight past the guard.
Field values read from input are not escape-processed, so both sides of the
comparison are byte-exact.
The fix belongs at that call site rather than in the classifier: `structural()`
refuses characters that would forge a *row*, and a backslash does not.

**Which base, and why the candidates are not equal.** There are **two bases**,
answering two different questions, and the difference in their policies is
deliberate.
The *authorisation* base is resolved once, in `fm-verify.sh`'s main body
(`FM_AUTH_BASE_*`), and is shared by the self-authorisation check and the
ledger-debt scoping.
Choosing it is a *security* question, because the guard means nothing if the
base is a ref the crewmate controls.
`refs/remotes/origin/<default>` takes a push to a protected default branch,
which prime directive 1 forbids and branch protection normally blocks.
`refs/heads/<default>` takes nothing: firstmate's project clones are **pooled**,
so a crewmate worktree shares that ref with the primary checkout and an ordinary
local commit — not even a deliberate `git update-ref` — is enough to make a
declaration the branch wrote itself read as inherited and reviewed.
So: with an `origin`, the base is the merge base against `origin/<default>` and
nothing else — a failed fetch falls back to an already-present
`origin/<default>`, never to the local branch, and an `origin/<default>` that
cannot be resolved at all leaves the base unset so the stage fails closed.
With no `origin` at all there is no second candidate, so the local default *is*
the base, and `fm-verify` says out loud that it is only as trustworthy as that
branch.
An earlier round took the candidate whose merge base was *furthest forward*, so
that a declaration on an unpushed local default would not read as forged; that
was a usability argument about a guard whose whole purpose is security, and it is
withdrawn — furthest-forward made the bypass the ordinary path rather than an
attack.
The fetch is the only network call on the accept path, so it is guarded against
blocking as well as failure (`GIT_TERMINAL_PROMPT=0`, batch-mode ssh, an
http low-speed cap, and a `timeout(1)` wall clock where one exists).

The *diff payload* base (`FM_DIFF_BASE_*`) is a separate resolver, and none of
that reasoning applies to it.
It decides how much of the branch the foreign lens gets to read, which is review
*coverage*, not authorisation - a patch file authorises nothing - so it keeps the
permissive fallback: `origin/<default>` when it resolved, else the merge base
with `refs/heads/<default>`, else the `HEAD` commit alone.
Sharing the origin-only base with the lens was a regression: an origin that
merely could not be *reached* silently cut the review down to one commit for
every project including the majority that have no `gates/` dir at all - worse
review, identical safety.
Either degradation is announced on stdout, where an operator reads it, rather
than only inside the patch file.

**Whose debt is it.** The freshness and `unproven` checks are scoped to the gates
this branch's own diff touches: a gate is this branch's when its entry in
`gates/ledger.json` changed against the base, or the test file its `test_ref`
names is in the diff (a *deleted* test shows up there, which is the case that
must still reject).
The comparison is per **entry**, not per file: whole-file granularity would put
every gate in scope the moment a branch registered one new gate, which is the
ordinary shape of gate-driven work.
It is also per **field**, over `status` and `test_ref` only - the two fields the
conditions actually turn on.
Comparing whole serialized entries reintroduced the same defect from the other
direction: `ledger verify` re-stamps `last_verified` on every gate it *runs* and
`CONTRIBUTING.md` mandates a re-freeze sweep after any change, so an ordinary
gate-driven branch differs on nearly every entry (commit `5709948` added 39
`last_verified` lines while adding 2 gates) and the whole ledger came back into
scope.
`last_verified`, `mutation_verified` and `first_observed_red` are therefore
excluded by being absent from that field list; a future stamp field is added to
it deliberately or not at all.
The changed-file set is collected with `--no-renames`, so a renamed test file
appears as both its old and its new path: rename detection prints only the
destination, which let a crewmate who renamed a test and forgot to update the
gate's `test_ref` fall out of scope in exactly the case the check exists for.
The ledger's test path is normalized once — a leading `./` stripped, doubled
slashes collapsed — before either the scope comparison or the existence check
reads it, so the two agree on which path they are talking about.
They disagreed: the scope check compares byte for byte while the existence check
hands the path to the filesystem, so a ledger writing `bash ./tests/aa.test.sh`
had its file correctly seen as gone and then excused as inherited debt — the
same fail-open as the rename case, decided by nothing but how the path happened
to be spelled.
It stays fail-closed where it must — if the base, the diff, or the base copy of
the ledger cannot be read, scope is unknown and every offending gate is treated
as this branch's own.
**Fail closed must not mean fail dishonest.** In that state the stage says so out
loud on stdout, exactly as the diff-base degradation does, and the reject text
drops its "gates this branch touched" claim for a plain statement that scope
could not be established and every offending gate is therefore listed
conservatively.
Silently attributing inherited debt to the branch told the crewmate it broke
something it never saw — and because the pre-existing lists are necessarily empty
in that state, the "not your responsibility" qualifier could not appear either.
The path is not exotic: an unresolvable `origin/<default>` in a repo whose ledger
carries no declared reds skips the self-authorisation escalation entirely, so
nothing else stops the run.
Undeclared reds are deliberately *not* scoped: CI does catch those, because
`run-all.sh` runs an undeclared red gate's test and it fails.

**Follow-up (not this phase): one shared base resolver, one policy.**
`bin/fm-review-diff.sh` resolves the authoritative base as `origin/<default>`
unconditionally and carries its own copy of `default_branch()`.
That now agrees with the Quarterdeck for every origin-backed project, but the two
implementations can still drift, and they differ for a project with no remote.
They should collapse into one resolver.

**Freshness is a cross-check, not a re-run.** The `test_ref` existence check
proves only that the ledger is not referencing tests that no longer exist. It
does **not** prove any test passes — that is CI's job, and re-running the suite
inside `fm-verify` would duplicate it at the most expensive possible moment.

### Contract updates

- `fm-brief.sh` DoD gains the verify clause: "`done:` is a claim; an independent
  verifier will re-prove it against your worktree. Expect a reject round-trip
  if any claim doesn't reproduce."
- `AGENTS.md` §7 (lifecycle) + §8 (supervision) document the verify stage and
  the verdict file.

### Seams and scope guards

- `FM_LENS_CMD` (foreign lens) and `FM_VERIFY_CMD` (verifier spawn) are
  injectable env seams — same stub pattern as `JARVIS_WORKER_CMD` — so the
  entire loop is testable offline with echo stubs.
- **Ship tasks only.** Scouts (report-only) keep the current path in Phase 1.
- Verify stage is bounded: read-only verifier, one lens call, no writer spawns.

### Error handling

- Lens API failure (401/timeout/no credits) → log, fall through the chain.
- Verifier spawn failure → `escalate:` (never auto-approve on infrastructure
  failure — fail closed).
- Malformed/missing verdict file at merge time → merge scripts refuse (fail
  closed) with a bordered guard banner, matching `fm-guard.sh` conventions.

### Testing / gates (gate-driven, in firstmate's own ledger)

New gates in `~/firstmate/gates/ledger.json`, each observed red before green,
bash tests in `tests/` matching the existing suite style:

1. `gate-q1-verdict-grammar` — verdict file accepts only the four line forms.
2. `gate-q2-merge-refuses-unverified` — `fm-merge-local.sh` exits non-zero
   without a trailing `approve:` line.
3. `gate-q3-prcheck-refuses-unverified` — same for `fm-pr-check.sh`.
4. `gate-q4-reject-roundtrip` — reject relays findings and flips status to
   `working:` (stubbed lens + verifier).
5. `gate-q5-attempt-cap` — third reject produces `escalate:`, not a fourth loop.
6. `gate-q6-lens-degrade` — missing Fugu key + missing codex → `lens: none`
   logged, verify still runs (no silent skip, no crash).
7. `gate-q7-fail-closed` — verifier spawn failure yields `escalate:`, never
   `approve:`.
8. `gate-q8-gate-classifier` — the classifier's double condition, `frozen`,
   all three absence cases, purity (never invokes `gates/verify.sh` or
   `ledger`), and fail-closed on a partial parse or an unknown status.
9. `gate-q9-verify-honours-declared-red` — a declared red proceeds; an
   undeclared red rejects **before either model runs**; no `gates/` dir never
   escalates; a missing ledger escalates; a stale `test_ref` rejects; the
   verifier prompt carries no gate rule of its own.

## Phases 2–5 (outline)

- **P2 — Council at intake:** thinker panel (parallel read-only specialists +
  Fugu-ultra deep roast) reviews brief/plan pre-spawn; grill-me interview
  upstream for new captain-initiated work. Council then runs at both ends.
- **P3 — loop-engineering conformance:** `LOOP.md`, `loop-budget.md`,
  `loop-run-log.md`, `loop-constraints.md` in firstmate;
  `npx @cobusgreyling/loop-audit` wired into `gates/verify.sh`; honest L2 first
  (its `loopActivity` signal demands proven runs — same ethos as
  `first_observed_red`), L3 only with budget + run-log + human gates.
- **P4 — Graph unification + routing manifest:** council/runtime skills become
  stone-skills nodes with `## Related` edges; instantiate `routing.json`
  against claude-pm-system's existing `routing.schema.json` (reconciling its
  `async|sync|batch` vocabulary with `no-mistakes|direct-PR|local-only`);
  agent↔skill manifest gated by `check.mjs` (the tend-the-graph TARGET).
- **P5 — Agent teams for thinker panels:** `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`,
  named parallel reviewers only — **never parallel writers**.

## Credentials (already in place, ~/.env chmod 600)

- `FUGU_API_KEY` — valid; account needs prepaid credits before the Fugu hop
  goes live (chain runs codex-only until then).
- codex CLI v0.142.1 — subscription-authed, works today.
- `OPENAI_API_KEY_LENS` — valid secondary; primary `OPENAI_API_KEY` untouched
  (realtime voice sidecar depends on it).

## Non-goals

- No Anthropic API / Agent SDK for the voice path (jarvis-talk hard constraint
  stands; this spec touches firstmate, not talkd).
- No proxying Claude through another model — the foreign lens *reviews*, it
  never sits between the captain and Claude.
- No new repo; no migration of working spawn/watch/supervise machinery.
