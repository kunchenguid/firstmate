---
name: moss-pr
description: >-
  Moss feature and PR quality bar for every usemoss product repo.
  Load before briefing or spawning any Moss feature implementation, before calling a Moss PR ready for human re-review or merge consideration, and when the captain invokes /moss-pr or asks to raise the Moss PR bar.
  Owns the intent contract, surface matrix, deterministic gate, budgeted whole-diff hardening, artifact lockstep, thread ledger, and GO/NO-GO attestation.
  Goal: human reviewers should find no substantive bugs; the PR should be honestly merge-ready.
user-invocable: true
metadata:
  internal: true
---

# moss-pr

Raise every Moss feature PR to a merge-ready bar learned the hard way on moss-sdks-internal PR 329 and related incidents (328, index-manager 44): green checks are not ready, patch-only fix loops thrash, missing specs become "review findings," monorepo surfaces and shipped binaries drift, and unresolved review threads are not optional paperwork.

**Captain goal:** with current agents, a Moss PR offered for human review should have **no substantive bugs left for the reviewer to find** and should be **honestly ready to merge** once the required human approve lands.
That is an operating standard, not a guarantee of perfection - treat misses as skill defects to codify, not as normal.

This skill does **not** replace no-mistakes, merge authority, or captain decisions on product scope.
It shapes **intake briefs**, **implementation done**, and **pre-human closeout**.

## When to load

- Before writing or spawning any **Moss** (usemoss org product) feature ship brief.
- Before telling the captain a Moss PR is ready for teammate re-review or merge.
- When the captain says `/moss-pr`, "Moss PR bar", or "no reviewer bugs".
- When closing out a long Moss PR that already exists (closeout mode only).

Do not load for pure Firstmate/tooling work unless the captain applies the same bar there.

## Non-negotiables

1. **One mutating owner** per branch.
   Reviewers and fanout lenses are read-only.
2. **Intent before code** for every non-trivial feature.
3. **Deterministic gate before AI review** (repo-real tests/lint/contracts, not vibes).
4. **Every new control is proven by failing.**
   Any guard, gate, assertion, or regression the change adds must be shown red on purpose once - state the mutation and the observed failure.
   An always-green control is an uncovered surface, not a covered one.
5. **After fixes, re-validate the whole change**, not only the patched lines.
6. **Budgeted hardening**, not infinite review loops: at most **two** full correction rounds after the first post-implement hardening pass, then freeze and escalate.
7. **Ready means one exact tip SHA** with code + gate + (if applicable) artifacts + thread ledger aligned.
8. **Never request human re-review** on a NO-GO tip.
9. **Do not hand-write team-repo `AGENTS.md` / `CLAUDE.md` structure** unless the captain explicitly owns that repo for agent-memory maintenance.
   Codify recurring human taste in **this skill** (and `data/captain.md` when it is a fleet preference).

## Mode A - Intake (feature implementation)

Firstmate owns this mode when commissioning a ship.
Put the following into the crewmate brief (replace placeholders with concrete facts).

### Intent contract (required in the brief)

- **Problem** - one short paragraph.
- **In scope** - bullets.
- **Out of scope / non-goals** - bullets (stops mid-PR creep).
- **Acceptance criteria** - testable, not vibes.
- **Surface matrix** - mark each row touched, updated, or explicitly N/A with a reason that names what you checked and where.
  "Not touched by this diff" is not a reason: the row asks whether the change *breaks* the surface, not whether the diff *edits* it.
  Good N/A: "no new required module; release job mirrors `Sources/Moss` only - list read at `.github/workflows/ios-sdk-release.yml:312`."
  - Core / service logic
  - Public API or ABI
  - FFI / bindings (C, native, etc.)
  - Each client SDK present in that repo (Python, JS/TS, Swift/iOS, Elixir, others)
  - Lockfiles and published package pins
  - CI workflow path filters and suites
  - Shipped binaries / wheels / XCFramework / LFS artifacts
  - **Publish path for each shipped surface** - release workflow steps, mirrored file lists, and any manifest it rewrites (including manifests that live in another repo)
  - **In-repo first-party consumers** - demo/test apps, benchmarks, examples, README quick starts
  - Docs / samples, **including public ownership, lifecycle, and capability tables** (tables are contracts; a new public symbol always touches this row)
- **Test plan** - happy path, at least one failure path, plus any that apply: concurrency/races, crash/mid-fail, cross-package install without local path hacks, Windows/macOS if those CI jobs exist for the touched area.
- **Critical?** - yes if security, persistence/concurrency, migrations/compat, high blast radius, or major architecture (or captain-marked).
  Critical tasks get Mode B hardening before human review.

### Implementation rules to paste into the brief

- Implement only the intent contract.
- If core behavior changes, update every non-N/A surface or stop with `needs-decision` / `blocked` rather than shipping a partial matrix.
- Keep the PR as small as the change allows.
  Prefer stacked atomic PRs over a 329-class monster when the feature can split without lying about compatibility.
- Add regressions that would have failed before the fix for every bug class you touch.
- Align lockfiles and package metadata in the same change set as API/signature changes.
- **Comments:** sparse and high-signal.
  Prefer clear names and regressions over narration.
  Comment only where the code is genuinely hard to understand (concurrency/race invariants, non-obvious safety or publish gates, surprising protocol constraints).
  Strip AI-style essay comments, tutorials, and restatements of the next line before commit.
- If the repo ships binary artifacts tied to source, do not claim done until artifact lockstep (Mode C) is satisfied on the final tip.
- Definition of done for the implementer: intent met, matrix complete, deterministic gate green on the implementation tip, then stop for hardening/closeout rather than pinging humans early.

### Trivial PRs

Typos, comment-only, or single-file pure docs may use a short brief: intent one-liner + gate + push.
Skip fanout unless CI or the captain says otherwise.

## Mode B - Hardening (after implementation, before human)

Use for **critical** work always, and for any PR that already attracted substantive review findings.

1. Seal a candidate tip (clean tree, pushed if the delivery path requires it).
2. Run the **deterministic gate** for that repo/matrix (full relevant suites).
   If red, fix gate issues first - no AI review theater on a red tip.
3. Run a **bounded read-only multi-lens pass** on the **whole diff / whole risk surface**, not the last patch hunk.
   Lenses (drop N/A): correctness, concurrency/state, API/ABI/compat, security/trust/provenance, tests/gaps, bindings/lockfiles/CI filters, artifact/source match, **publish path** (can the release job build a working consumer package from this tip), **regression-of-a-fix** (re-read every previously resolved substantive thread against this tip), **control integrity** (every guard/gate/regression this change adds has been observed failing on purpose; every test double cites the documented contract it models), **claim accuracy** (every SHA, run link, and "verified" statement in the PR body and thread replies still true at this tip).
   Prefer evidence and repro over style nits.
   A single strong reviewer may cover lenses sequentially when parallel fanout is unavailable; parallel read-only fanout is better when cost allows.
4. Judge findings: merge dupes, drop false positives, severity-tag Blocker/High/Medium/Low.
5. **Fix round** (same mutating owner only) for every Blocker/High and every correctness/safety Medium.
   Then full gate again + full hardening pass again on the **new** tip.
   Before closing the round, list every earlier resolved thread whose code the round touched and re-verify each by name.
   A fix that makes an earlier finding true again is a Blocker, not a trade-off.
   Every control the round added - guard, gate, assertion, regression - is shown red on purpose before the round closes: name the mutation and the observed failure.
   Unproven controls do not count toward coverage.
6. At most **two** such correction rounds after the first hardening pass.
   If still dirty: `NO-GO`, list residuals, escalate - do not open round three without captain word.
7. Unrelated nits must not expand frozen intent (captain critical-task preference).

This matches the captain's simplified critical-task sequence: implement and test; bounded read-only multi-agent review on the exact commit; Firstmate dispositions; finish; then unchanged no-mistakes delivery - without inventing a new orchestration product.

## Mode C - Closeout (before human re-review or "merge-ready")

Run on the final tip SHA.

### Checklist

1. **Exact tip** - record full SHA; local and remote match if PR-based.
2. **Intent** - still true; non-goals held.
3. **Surface matrix** - complete; no silent N/A.
4. **Deterministic gate** - green with named commands/suites (not "tests passed" without identity).
5. **CI** - required checks green on that SHA.
6. **Artifact lockstep** - if the repo commits or releases binaries for this change, rebuild/verify from **this** SHA and commit only when mismatch is proven; never call ready when source and shipped binary disagree.
   For every source change the artifact represents, record the base and final-tip artifact hashes, require the final-tip artifact to differ from base, and exercise the changed behavior through the packaged artifact so a build that silently used base-era source cannot pass.
   Compare the final-tip rebuild bytes with the checked-in or released bytes and block GO on any mismatch.
7. **Thread ledger** - every human thread, **resolved or not**, is FIXED (evidence read from the code at *this* tip, not quoted from an earlier reply), OUTDATED, DEFERRED (named external dependency), or STILL_BUG (blocks GO).
   Threads resolved at an earlier head are re-verified, not carried.
   Prefer reply-in-thread + resolve when project norms and captain prefs require it.
8. **Consumer probe** - for each surface this change gates or newly requires something from, name one real consumer (published manifest, checked-in demo/benchmark, example, README quick start, downstream package) and state how you proved it still works at this tip.
   When the change modifies behavior, the probe must exercise that behavior through the packaged surface; a build-only or import-only probe is insufficient.
9. **Negative controls** - list every guard, gate, assertion, and regression this change added, and for each give the mutation that made it fail and the failure observed.
   Any control with no recorded red run is reported as an uncovered surface.
10. **Claim audit** - every SHA, run link, benchmark, and "verified" statement in the PR body and in thread replies is re-checked at this tip.
    Stale-SHA or failed runs are removed or re-run before GO.
11. **Hardening budget** - respected; no silent third loop.
12. **Attestation** - produce exactly one verdict:

```text
GO tip=<full_sha> - gate green; CI green; matrix complete; artifacts + publish path OK or N/A; consumers probed; new controls proven red-then-green; claims re-checked; 0 open Blocker/High/correctness-Medium; all threads re-verified at this tip
```

or

```text
NO-GO tip=<full_sha> - <n> residuals: <short list>
```

The verdict line goes **into the closeout artifact**.
A closeout note without one of these two lines is not a closeout, and the tip is not attested.

Only **GO** may be described to the captain as ready for human re-review or merge consideration.
Merge still needs the normal authority (captain or project yolo rules).

## Mode D - Flywheel (after human review)

When a human still finds something substantive:

1. Treat it as a **process defect**, not only a code defect.
2. Fix the code under Mode B budget if the PR is still open.
3. Add a permanent bullet under **Reviewer taste (codified)** below (good vs bad example when helpful).
4. Do not leave the lesson only in chat.

## Reviewer taste (codified)

Seeded from Moss PR 329 / 328 / related review pain.
Extend this list when humans teach us.

- **Lockfiles and pins move with API changes** - pyproject/uv.lock, package.json, published core version pins, and constructor arity must match in one tip.
- **Typed surfaces** - public kwargs and new fields appear in `.pyi` / generated types when the repo ships them.
- **Capability bits tell the truth** - never advertise provenance-safe or V2 APIs when constructors still swallow identity or call legacy unbound paths.
- **Provenance and cache generations** - no trust re-derived only in download loops; fail closed on stale generation; session query/refresh and manager rotation races need tests, not comments.
- **Pair/envelope validation** - complete pairs still validate version and canonical artifact rules.
- **CI path filters** - if a package can break, a workflow must build/install/test that package on the PR, not only cargo-check a neighbor.
- **Cross-package install** - consumer tests without local path overrides that hide publish breakage.
- **Artifacts and the publish path** - committed XCFramework/wheels must match the frozen source SHA, *and* the release job must be able to assemble a working consumer package from that SHA.
  For every module, target, or file the change makes a required import, prove it appears in the release job's mirrored file list and in the manifest that job installs.
  When publication targets another repo, read that repo's live manifest, not the in-repo dev one.
- **Thread resolution is per-tip, not permanent** - fixed findings get a concrete reply and resolve, and a thread you resolved at an earlier head stays in the ledger.
  Before GO, re-derive FIXED for every substantive thread from the code at the final tip, never from your own earlier reply.
  Self-resolved is your claim, not the reviewer's confirmation.
- **Prove the control fails** - every new or edited guard, gate, assertion, or regression test is shown **red on purpose** at least once before it is trusted.
  Record the exact mutation you made - revert the fix, break the manifest, remove the mirrored path, stub the archive, run the racing threads serially - and the failure you observed.
  A control that has only ever been green proves nothing about the code; it proves it agrees with you.
  Report the negative control in the closeout; an unproven control counts as an uncovered surface, not a covered one.
- **A regression must fail against the pre-fix code** - name the parent SHA or the exact revert, and show the test red there.
  If it also passes on the broken parent, it is testing something else.
  Read the assertion message against the original finding: if it asserts the property the reviewer called a defect, the test is pinning the bug.
  *(PR 329: `prune_snapshot_is_atomic_with_concurrent_load` asserted `"unload should hold the index guard while pruning"` - the exact defect of an earlier thread.)*
- **A new guard must state what it does not assert** - when the change adds or edits a CI/contract guard script, list the parts of the contract the guard leaves unchecked and either extend it or say why the gap is safe.
  The half you did not encode is where the defect is.
  *(PR 329: a new iOS release-workflow contract guard asserted only the build-only default and stayed green over a release job that mirrored the wrong file set.)*
- **Test doubles encode the documented contract, not the assumed one** - a hand-written fake, stub, or recorded fixture standing in for an external API must cite the documented behaviour it models, including error and not-found responses.
  Where the real endpoint 404s, refuses, or filters, the double does too.
  A green suite over a fake more permissive than the real service proves nothing.
  *(PR 349: a release-API fake returned drafts from a by-tag endpoint that 404s in reality, so the retry path was broken while tests passed.)*
- **A verifier hashes exactly what it approves, including complete stitched output, and a race test proves it raced** - an inventory, manifest, identity, provenance, or interrupted-response check hashes the exact final bytes consumed as one complete value, including every fragment of a stitched response in order; a concurrency regression asserts the operations actually overlapped, not merely that the run finished.
  Prove artifact binding by substituting a stub artifact, prove stitching by dropping, duplicating, reordering, or truncating a fragment, and prove concurrency by serializing the operations; each negative control must make the check go red.
  *(PR 348: the identity manifest never checksums the archive it approves.)*
  *(PR 351: inventory guards accept real drift, and the Windows close-race test passes when nothing overlaps `close()`.)*
  *(PR 353: interrupted-response verification did not bind approval to the complete stitched response.)*
- **Fixes must not invert an earlier fix** - when a fix round edits a function an earlier resolved finding also edited, name both findings and state the invariant that satisfies each.
  If a new regression test asserts the exact property an earlier reviewer called a defect, that is the defect, not the proof.
- **Checked-in callers are consumers** - demo apps, test apps, benchmarks, examples, and README quick starts are consumers of the API you changed.
  When the change adds a capability gate, a required argument, or a fail-closed path, prove every checked-in caller still runs or gate it behind the same capability probe.
  Editing the file for API migration is not proof it still works.
- **Ownership and lifecycle tables are API, not prose** - a new public symbol that allocates or returns an owned resource appears in its header doc comment *and* in the ownership/lifecycle table the package publishes.
  If it breaks that table's stated naming convention, the convention line changes with it.
- **Persist before you clear** - when a change replaces one durable record with another, write the new record first and clear the old one only after that write returns success.
  Prove the ENOSPC / read-only interleaving with a test that injects the write failure.
  "Best-effort, never fails the load" is where this bug hides, not a reason to skip the function.
- **Claims in the PR body name the SHA they were produced at** - every rehearsal run, CI link, benchmark, or "verified" claim in the body or in a thread reply carries the exact SHA and the run conclusion.
  Re-check each one against the final tip before GO; a run at an older SHA, or one that failed, is not evidence.
  *(PR 349: four rehearsal runs cited in the body had run at older SHAs and one had failed.)*
- **Whole-diff re-check after fixes** - patch-only re-review is how regressions return in round 2.

## Repo modules (apply only what exists)

- **Multi-binding SDK monorepo** (e.g. moss-sdks-internal) - full matrix + artifact lockstep + package-consumer gates.
  Surfaces with no PR CI at all (today: everything under `bindings/ios/` - the only iOS workflow is `workflow_dispatch`) get a manual consumer probe named in the closeout, not an N/A.
  For iOS, that probe must link the checked-in XCFramework, exercise the source change's behavior, and record the base and final-tip framework hashes required by Mode C so a byte-identical base-era package cannot pass as current.
- **Services** (identity, index-manager, event-ingestor, dashboard) - API/authz, migrations, contract tests, deploy boundary honesty.
- **Infra** (infra-moss-tf) - plan identity, no apply-as-ready, blast-radius checklist.
- **Docs/samples** - thinner path; still intent + link/build check when samples compile.

## Anti-patterns (329 class)

- Monster PR + endless fix→review→fix with no round cap.
- Declaring ready from check count alone.
- Fixing Rust and leaving JS/Python/iOS/locks inconsistent.
- Reviewing only the latest commit hunk after a fix.
- Parallel agents pushing the same branch.
- Requesting teammate review to "find whatever is left" instead of GO attestation.
- Expanding scope when a deferred external MOS/ticket owns the real fix - label DEFERRED, do not invent.
- Walls of AI-generated comments that restate obvious code or tutorialize simple control flow.
- Resolving your own thread and then treating the finding as permanently closed.
- Verifying the in-repo manifest and calling the published package verified.
- Attesting a tip by re-using the previous tip's evidence because "the delta is small."
- Writing a contract guard that only encodes the half of the contract you were already thinking about.
- Forecasting reviewer nits and reading an empty nit list as merge-ready.
- Counting a guard, gate, or regression as coverage when it has only ever been observed green.
- Writing the test double from the API you assumed instead of the API's documented error and not-found behaviour.
- Citing a rehearsal or CI run in the PR body without re-checking its SHA and conclusion at the final tip.

## Firstmate operating notes

- Load this skill at Moss ship intake and paste Mode A into the brief via `bin/fm-brief.sh` task text.
- For critical Moss ships, require Mode B before Mode C.
- Captain-facing language stays in outcomes (PR, review, blocker), not internal machinery.
- This skill's durable home is Firstmate; do not dump a second full copy into every Moss repo.
