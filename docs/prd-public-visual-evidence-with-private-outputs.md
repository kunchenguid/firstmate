# PRD: Public Visual Evidence with Private Outputs

## Introduction/Overview

Firstmate needs reusable visual verification without publishing the project or personal data that verification produces.
This product adds a clean-room public **Visual Evidence** skill, folds code-structure guidance into Firstmate's existing conditional **Structural Review**, and adds a narrow producer-neutral **Approved Evidence Import** interface to no-mistakes.
The work is governed by the [authoritative domain contract](../CONTEXT.md) and the [proposed architecture decision](adr/0001-public-visual-evidence-with-private-outputs.md).
Version 1 is macOS-only, browser-first, screenshot-focused, private by default, and incomplete until approved local export and approved GitHub pull request publication both work end to end.

## Goals

- Add conditional **Structural Review** guidance that enforces existing one-owner rules without expanding a task beyond the affected responsibility.
- Add a producer-neutral no-mistakes import path that rejects every unapproved, tampered, replayed, unsupported, or context-drifted evidence batch before pull request mutation.
- Publish one MIT-licensed clean-room **Visual Evidence** skill that supports comparison and behavior evidence through one privacy, storage, review, publication, and cleanup lifecycle.
- Produce versioned **Evidence Bundles** that contain the minimum evidence needed to prove an observable claim and omit private machine details.
- Keep every original artifact private unless the exact batch and destination receive the required authority.
- Make required evidence failures block full validation while reporting supplemental evidence failures without invalidating otherwise successful automated tests.
- Complete version 1 only after the no-mistakes prerequisite and both approved destinations pass their end-to-end validation tests.

## Delivery Sequence and Dependencies

1. Delivery 1 adds scoped **Structural Review** guidance in Firstmate and can ship independently.
2. Delivery 2 adds producer-neutral **Approved Evidence Import** in no-mistakes and must ship before complete **Visual Evidence** version 1.
3. Delivery 3 adds the public **Visual Evidence** skill and Firstmate intake, reclassification, review, local export, cleanup, and no-mistakes integration.
4. Local export may be implemented and tested before Delivery 2 finishes, but that partial capability is not a version 1 release.
5. The final readiness gate runs only after all three deliveries are available together.

## User Stories

### US-001: Add conditional Structural Review guidance

**Description:** As a Firstmate maintainer, I want code-structure principles folded into existing coding guidance so that ownership violations are corrected without creating a broad cleanup mandate.

**Acceptance Criteria:**

- [ ] The guidance triggers **Structural Review** only for duplicated mechanics, competing implementations of one responsibility, or unclear ownership in the requested change.
- [ ] The guidance requires actual violations of Firstmate's one-owner rules to be fixed.
- [ ] The guidance treats ordinary refactoring opportunities as recommendations.
- [ ] The guidance prohibits abstractions created only to satisfy the review routine.
- [ ] The guidance limits deeper review to the responsibility directly affected by the request and reports other duplication separately.
- [ ] Firstmate documentation checks and relevant guidance tests pass.

**Validation Test:**

- **Setup:** Prepare one fixture change with two owners for the same responsibility and one unrelated duplicated helper elsewhere in the repository.
- **Steps:**
  1. Apply the updated coding guidance to the fixture change.
  2. Record the required correction and any optional recommendation.
  3. Run the focused guidance regression and documentation checks.
- **Expected Result:** The competing owner is a required fix, the unrelated helper is reported separately, and no unrelated refactor or speculative abstraction is required.
- **Failure Indicator:** The review misses the ownership violation, expands into unrelated work, or requires an abstraction without a concrete ownership problem.

### US-002: Define the producer-neutral import contract

**Description:** As a no-mistakes maintainer, I want a narrow evidence import contract so that any producer can offer an exact approved batch without importing producer-specific behavior.

**Acceptance Criteria:**

- [ ] The contract accepts an exact manifest hash, artifact paths and hashes, approval identity, run binding, reviewed-head binding, destination, and declared media types.
- [ ] The contract rejects missing required fields, unknown major schema versions, absolute or traversing artifact paths, duplicate paths, and unsupported media types.
- [ ] The contract accepts newer optional fields within a supported major schema version.
- [ ] The contract contains no Firstmate, comparison-mode, behavior-mode, or **Visual Evidence** branching.
- [ ] Contract parsing has positive, malformed, boundary, and producer-neutral regression tests.

**Validation Test:**

- **Setup:** Create two equivalent valid import fixtures from differently named producers and malformed fixtures for each rejected condition.
- **Steps:**
  1. Validate both producer fixtures.
  2. Validate every malformed fixture.
  3. Run the focused import-contract test suite.
- **Expected Result:** Both producers receive the same accepted result, and every malformed or unsupported fixture receives a deterministic refusal without state mutation.
- **Failure Indicator:** Producer identity changes behavior, an unsafe path or media type is accepted, or malformed input creates import state.

### US-003: Stage imported evidence outside the worktree

**Description:** As a no-mistakes operator, I want offered evidence copied into protected run-owned staging so that later review and publication never depend on mutable project files.

**Acceptance Criteria:**

- [ ] Import staging is outside the project worktree and inside no-mistakes-owned local state.
- [ ] The importer accepts only regular files contained by the offered bundle and refuses symlinks, traversal, and path substitution.
- [ ] The importer copies into a unique incomplete location, verifies all hashes from the staged copy, and finalizes atomically.
- [ ] An existing non-identical import destination is never overwritten or merged.
- [ ] A failed import publishes nothing and retains only bounded diagnostic state required for recovery.
- [ ] Focused filesystem, race, and interrupted-import tests pass.

**Validation Test:**

- **Setup:** Prepare a valid bundle, a symlink escape, a file changed during import, and an interruption immediately before finalization.
- **Steps:**
  1. Import each fixture into an isolated no-mistakes home.
  2. Inspect the worktree, staged files, final import state, and publication state.
  3. Restart recovery for the interrupted case.
- **Expected Result:** Only the stable valid bundle finalizes, the worktree stays unchanged, unsafe fixtures fail closed, and recovery never publishes incomplete evidence.
- **Failure Indicator:** Mutable source bytes reach final staging, an unsafe path escapes containment, or any failed fixture becomes publishable.

### US-004: Admit Evidence Import Consent without trusting project data

**Description:** As a no-mistakes operator, I want import consent admitted through protected local control state so that project-controlled manifests or JSON cannot authorize import.

**Acceptance Criteria:**

- [ ] **Evidence Import Consent** binds one exact batch, manifest hash, artifact hashes, named destination, run, and reviewed head.
- [ ] Project-controlled manifests, JSON, repository configuration, and environment configuration cannot grant consent.
- [ ] `--yes` and generic automatic approval cannot grant consent.
- [ ] An active validation-step descendant cannot use the import-control interface to grant consent.
- [ ] Missing, mismatched, replayed, or already-consumed consent fails before protected staging becomes eligible for publication.
- [ ] Security regressions exercise project-code forgery and nested-gate attempts.

**Validation Test:**

- **Setup:** Create a valid offered batch, a project file that claims approval, a nested test process, and a legitimate consent record for the exact batch.
- **Steps:**
  1. Attempt import with only the project approval file.
  2. Attempt import from the nested test process.
  3. Attempt import with `--yes` and configuration-based approval.
  4. Submit the legitimate exact consent through the protected control path.
- **Expected Result:** The first three attempts are refused without authority state, while the exact legitimate consent permits staging but not publication.
- **Failure Indicator:** Any project-controlled input or automatic path creates import authority or directly publishes evidence.

### US-005: Present the no-mistakes publication preview

**Description:** As an operator, I want no-mistakes to preview its protected staged copy so that publication approval refers to the bytes and destination it will actually publish.

**Acceptance Criteria:**

- [ ] The preview is generated from finalized protected staging rather than the producer's source directory.
- [ ] The preview displays the run, reviewed head, pull request destination, manifest hash, artifact names, artifact hashes, media types, and sizes.
- [ ] Rendering or closing the preview performs no publication.
- [ ] The preview clearly distinguishes prior **Evidence Import Consent** from pending **Publication Approval**.
- [ ] Preview tests cover empty, single-artifact, multiple-artifact, and rejected-media batches.

**Validation Test:**

- **Setup:** Stage a valid multi-artifact batch under a test run and retain its expected digest.
- **Steps:**
  1. Open the no-mistakes publication preview.
  2. Compare every displayed binding with the staged digest.
  3. Close the preview without approval.
- **Expected Result:** The preview matches the protected staged bytes exactly and no evidence branch, pull request body, or publication approval changes.
- **Failure Indicator:** The preview reads mutable producer files, omits a binding, or closing it authorizes publication.

### US-006: Grant no-mistakes-owned Publication Approval

**Description:** As an operator, I want a distinct no-mistakes-owned approval after its exact preview so that pull request mutation has an authority source project code cannot forge.

**Acceptance Criteria:**

- [ ] **Publication Approval** can be granted only for the exact protected staged batch shown in the no-mistakes preview.
- [ ] The approval binds the run, reviewed head, manifest hash, artifact hashes, allowed media types, and named pull request destination.
- [ ] Project data, configuration, generic gate approval, and `--yes` cannot grant or substitute for this approval.
- [ ] Approval is one-time and produces a durable audit record without exposing private artifact contents.
- [ ] Closing or declining the preview leaves publication unauthorized.
- [ ] Focused authorization tests prove that import consent alone cannot publish.

**Validation Test:**

- **Setup:** Prepare one staged import with consent but no publication approval and one identical import that receives explicit approval after preview.
- **Steps:**
  1. Attempt publication for the consent-only import.
  2. Close the preview for that import and retry.
  3. Approve the second import through the protected no-mistakes path.
  4. Attempt publication for the approved import.
- **Expected Result:** Only the second import becomes eligible for one publication attempt, and every refusal is durable and explicit.
- **Failure Indicator:** Consent, preview rendering, closure, `--yes`, or generic approval authorizes pull request mutation.

### US-007: Invalidate drift and replay before publication

**Description:** As a no-mistakes operator, I want every mutable publication assumption rechecked so that stale authority cannot be reused after context changes.

**Acceptance Criteria:**

- [ ] Publication immediately revalidates staged hashes, manifest hash, run, reviewed head, destination, media types, and unconsumed approval.
- [ ] Artifact drift, manifest drift, replay, destination change, run change, or reviewed-head change invalidates the affected authority.
- [ ] An invalidated attempt publishes nothing and requires a new exact preview and approval.
- [ ] An exact replay after successful consumption is a deterministic no-op or refusal and never creates a second publication.
- [ ] Concurrent publication attempts consume at most one approval.
- [ ] Race and replay regressions pass.

**Validation Test:**

- **Setup:** Create approved imports and mutate one bound dimension in each fixture before publication.
- **Steps:**
  1. Attempt publication for every drift fixture.
  2. Race two publication attempts against one unchanged approved fixture.
  3. Replay the successful request.
- **Expected Result:** Every drift fixture fails closed, exactly one racing attempt may publish, and replay cannot publish twice.
- **Failure Indicator:** Stale approval survives drift, concurrent attempts publish twice, or replay changes remote state.

### US-008: Publish approved evidence through the managed PR flow

**Description:** As a pull request reviewer, I want approved evidence linked through no-mistakes so that artifacts are reachable without entering the feature or default branch history.

**Acceptance Criteria:**

- [ ] Only an import with valid consent and unconsumed **Publication Approval** can enter managed publication.
- [ ] Artifacts are published through no-mistakes' evidence branch using immutable evidence-commit addresses.
- [ ] The **Managed PR Description** includes the exact approved evidence batch through the existing generated evidence section.
- [ ] Reruns may regenerate the full description, and no contract promises to preserve manual author text there.
- [ ] Version 1 does not add comment-based evidence publication.
- [ ] The owning project worker drives no-mistakes, and Firstmate does not mutate the project pull request directly.
- [ ] End-to-end no-mistakes evidence publication tests pass against an isolated forge fixture.

**Validation Test:**

- **Setup:** Create a test pull request run with one approved import and one unapproved import.
- **Steps:**
  1. Complete the managed publication step for the approved import.
  2. Inspect evidence branch history and the generated pull request description.
  3. Attempt the same step for the unapproved import.
- **Expected Result:** The approved batch is linked by immutable evidence commit, neither code branch contains artifacts, and the unapproved batch creates no remote mutation.
- **Failure Indicator:** Evidence enters a code branch, a mutable local path is linked, a comment is added, or the unapproved import changes the pull request.

### US-009: Publish the clean-room Visual Evidence skill package

**Description:** As an installer, I want one public Visual Evidence skill so that comparison and behavior evidence share one reusable contract and lifecycle.

**Acceptance Criteria:**

- [ ] The skill is an original clean-room implementation under Firstmate's MIT license.
- [ ] No upstream prose, code, or bundled implementation is vendored.
- [ ] One public skill owns **Comparison Mode**, **Behavior Mode**, capture, privacy, storage, review, publication handoff, and cleanup.
- [ ] The upstream capability names appear only as provenance or inspiration and not as separate installed Firstmate skills.
- [ ] The public package is installer-facing and is not duplicated into Firstmate's internal skill directory.
- [ ] Skill packaging, metadata, documentation, and clean-room provenance checks pass.

**Validation Test:**

- **Setup:** Install the built public skill into a clean supported agent home and inventory installed skill names and packaged files.
- **Steps:**
  1. Inspect the installed metadata and license.
  2. Invoke comparison and behavior help through the single skill.
  3. Search the package for vendored upstream files and duplicate mode skills.
- **Expected Result:** One MIT-licensed Visual Evidence skill exposes both modes without copied upstream implementation or internal-skill duplication.
- **Failure Indicator:** Separate mode skills install, upstream content is vendored, or Firstmate requires a duplicate internal copy.

### US-010: Classify evidence before worker dispatch

**Description:** As the captain's Firstmate, I want evidence relevance and requirement classified before dispatch so that workers receive an explicit contract and never self-activate visual capture.

**Acceptance Criteria:**

- [ ] **Evidence Intake Classification** uses only the captain's request and documented project acceptance policy.
- [ ] Relevant evidence defaults to **Supplemental Visual Evidence** unless the captain's request or project policy establishes it as required.
- [ ] The worker brief names the selected mode, requirement, scenario, capture scope, and canonical public skill path.
- [ ] A task without an evidence contract does not load or activate Visual Evidence.
- [ ] Firstmate may recommend promotion but cannot silently add a required failure condition or viewport.
- [ ] Brief generation and dispatch tests cover irrelevant, supplemental, required, and malformed classifications.

**Validation Test:**

- **Setup:** Prepare four task requests representing irrelevant work, a relevant visual change, an explicitly required visual change, and an incomplete classification.
- **Steps:**
  1. Generate each worker brief.
  2. Inspect its evidence contract and skill pointer.
  3. Attempt dispatch with the malformed classification.
- **Expected Result:** The four cases respectively omit activation, request supplemental comparison evidence, request required comparison evidence, and fail before dispatch.
- **Failure Indicator:** A worker self-activates, relevance silently becomes required, or malformed evidence configuration reaches a worker.

### US-011: Reclassify evidence after unexpected impact

**Description:** As Firstmate, I want to reclassify evidence after a worker reports unexpected visual or behavioral impact so that newly discovered scope follows the same authority rules.

**Acceptance Criteria:**

- [ ] Workers report unexpected visual or behavioral impact without self-activating Visual Evidence.
- [ ] Firstmate performs **Evidence Reclassification** using the same captain-request and project-policy authority as intake.
- [ ] Reclassification sends a complete durable replacement or addition to the worker's evidence contract.
- [ ] Supplemental evidence remains the default unless existing authority establishes required evidence.
- [ ] Reclassified comparison evidence remains subject to **Verified Baseline** rules.
- [ ] Durable inbox and reclassification regressions cover delivery, acknowledgment, replay, and malformed updates.

**Validation Test:**

- **Setup:** Dispatch a backend-labeled task whose worker later reports a newly discovered user-visible change.
- **Steps:**
  1. Record the worker report without starting capture.
  2. Re-evaluate classification.
  3. Deliver and acknowledge the complete revised evidence contract.
  4. Replay the same update.
- **Expected Result:** Capture starts only after Firstmate's explicit reclassification, requirement authority remains unchanged, and replay does not create a second activation.
- **Failure Indicator:** The worker captures before reclassification, silently promotes evidence, or loses the baseline requirement.

### US-012: Load explicit Evidence Scenarios and private values

**Description:** As a project developer, I want reusable non-secret scenarios separated from private values so that capture is repeatable without committing credentials or private URLs.

**Acceptance Criteria:**

- [ ] A **Scenario Definition** explicitly names startup, readiness, fixture setup, route, viewports, interactions, assertions, captures, and demonstrated claim, plus the independently isolated server-side synthetic fixture namespaces or deterministic reset before each capture when Comparison Mode applies.
- [ ] Scenario commands and fixture commands are never invented by the skill.
- [ ] Tracked scenario definitions contain no secrets and refer to private values only by declared name.
- [ ] **Scenario Values** remain ignored local state and never appear in manifests, reports, logs, or error text.
- [ ] Missing required private values are reported by name only.
- [ ] A scenario with insufficient explicit information does not run and reports why.
- [ ] Schema, secret-leak, and missing-value tests pass.

**Validation Test:**

- **Setup:** Prepare a complete anonymous scenario, an authenticated scenario with local values, a definition containing a secret, and a scenario missing one required value.
- **Steps:**
  1. Load each scenario.
  2. Inspect validation output and all generated diagnostics.
  3. Search portable outputs for supplied private values.
- **Expected Result:** The valid scenarios load, the committed secret is rejected, the missing value is named without disclosure, and no private value reaches portable output.
- **Failure Indicator:** The skill guesses setup, accepts a secret-bearing definition, or exposes a private value.

### US-013: Create an isolated task-scoped browser

**Description:** As a privacy-conscious developer, I want capture isolated from my ordinary browser so that personal state cannot leak into evidence.

**Acceptance Criteria:**

- [ ] Version 1 refuses unsupported operating systems and makes no Linux or Windows support claim.
- [ ] Version 1 uses existing supported browser tooling with a new **Task-scoped Browser Profile**.
- [ ] The skill never attaches to or reads the captain's ordinary signed-in browser session.
- [ ] Authenticated scenarios establish state only inside the isolated browser through private test credentials or project-provided setup.
- [ ] The profile is never reused across tasks and is discarded when the task finishes.
- [ ] Dependency and capability failures are reported without installing tools automatically.
- [ ] Isolation is verified in browser using `chrome-devtools-axi`.

**Validation Test:**

- **Setup:** Keep an ordinary browser signed in with a recognizable private marker and prepare an isolated scenario with synthetic authentication.
- **Steps:**
  1. Start the Visual Evidence task browser.
  2. Inspect pages, storage, cookies, and profile identity using `chrome-devtools-axi`.
  3. Complete the task and inspect profile cleanup.
- **Expected Result:** The task browser contains only scenario-created state, never exposes the private marker, and its profile is not reused after completion.
- **Failure Indicator:** The skill attaches to the ordinary profile, imports personal state, reuses the profile, or installs a missing dependency without approval.

### US-014: Capture a verified comparison

**Description:** As a reviewer, I want equivalent before-and-after evidence so that a visual-change claim is based on a runnable baseline rather than unrelated screenshots.

**Acceptance Criteria:**

- [ ] **Comparison Mode** runs the exact **Baseline Revision** and candidate head under equivalent viewport, setup, fixture, authentication, and initial synthetic state inputs.
- [ ] Separate browser contexts plus independently isolated server-side synthetic fixture namespaces or deterministic reset before each capture prevent state changes in one capture from reaching the other.
- [ ] A **Verified Baseline** is labeled only after the exact **Baseline Revision**, distinct from the candidate head, runs successfully under equivalent conditions.
- [ ] User-provided and historical screenshots are never labeled as Verified Baseline evidence.
- [ ] The review presents baseline and candidate views side by side.
- [ ] An **Explanatory Diff** is produced only when requested by the scenario and becomes pass or fail only under documented project policy.
- [ ] Comparison output is verified in browser using `chrome-devtools-axi`.

**Validation Test:**

- **Setup:** Prepare a synthetic fixture with independently isolated server-side namespaces or a deterministic reset, one runnable **Baseline Revision**, one candidate-head visual change, and a historical screenshot unrelated to the run.
- **Steps:**
  1. Run baseline and candidate captures in their paired contexts.
  2. Inspect viewport, setup, authentication, fixture equivalence, and the declared server-side state isolation or reset.
  3. Open the side-by-side review with `chrome-devtools-axi`.
  4. Request a diff once with and once without a documented threshold.
- **Expected Result:** The exact runnable **Baseline Revision** and candidate head appear side by side, browser and server state do not cross contexts, the historical image is contextual only, and diff verdicts follow policy.
- **Failure Indicator:** Captures share mutated browser or server state, an unrun image becomes a baseline, or an explanatory diff silently fails validation.

### US-015: Handle an unavailable baseline honestly

**Description:** As a reviewer, I want baseline failure handled according to evidence requirement so that an after-only result never implies a comparison it did not prove.

**Acceptance Criteria:**

- [ ] An unavailable baseline fails full validation when before-and-after proof is required.
- [ ] A supplemental comparison may produce **After-only Evidence** when the candidate can still be evidenced.
- [ ] After-only output records the baseline-unavailable reason and makes no comparison claim.
- [ ] Expected evidence is never silently omitted.
- [ ] Required and supplemental baseline-failure regressions pass.

**Validation Test:**

- **Setup:** Prepare one required and one supplemental comparison scenario whose **Baseline Revision**, distinct from the candidate head, cannot start while the candidate head can start.
- **Steps:**
  1. Run the required scenario.
  2. Run the supplemental scenario.
  3. Inspect both reports and manifests.
- **Expected Result:** Required validation is incomplete, supplemental validation reports the gap and produces clearly labeled after-only evidence, and neither output claims a before-and-after result.
- **Failure Indicator:** Required validation passes, supplemental evidence disappears silently, or either report implies a verified baseline.

### US-016: Capture minimum sufficient behavioral evidence

**Description:** As a reviewer, I want behavior evidence limited to what still images and assertions can prove so that version 1 stays useful without unsafe recording.

**Acceptance Criteria:**

- [ ] **Behavior Mode** activates only for motion, timing, interaction order, or transient behavior that ordinary tests and stable screenshots cannot adequately demonstrate.
- [ ] Behavior Mode first evaluates whether lighter automated or screenshot evidence is sufficient.
- [ ] When needed, output uses sequenced screenshots, automated assertions, and timing notes.
- [ ] Version 1 produces no video and never falls back to operating-system screen capture.
- [ ] A required request for video makes validation incomplete, while a supplemental request reports video unavailability without failing otherwise successful automated validation.
- [ ] Visual evidence never claims to prove hidden application behavior.
- [ ] Behavioral output is verified in browser using `chrome-devtools-axi`.

**Validation Test:**

- **Setup:** Prepare a stable-state scenario, a transient interaction scenario, and required and supplemental scenarios that explicitly request video.
- **Steps:**
  1. Run all four scenarios.
  2. Inspect capture selection and the behavioral sequence with `chrome-devtools-axi`.
  3. Compare evidence results with automated assertions.
- **Expected Result:** The stable case uses lighter evidence, the transient case uses the minimum screenshot sequence and timing notes, required video remains incomplete, and supplemental video unavailability is reported.
- **Failure Indicator:** Video or desktop capture occurs, unnecessary recording-like output is produced, or visual artifacts claim hidden-state proof.

### US-017: Build a versioned private Evidence Bundle

**Description:** As a developer, I want a portable evidence package with immutable artifact identities so that reviewers can verify exactly what was captured without learning private machine details.

**Acceptance Criteria:**

- [ ] Each **Evidence Bundle** contains a human-readable report, a **Portable Manifest**, and zero or more visual artifacts.
- [ ] Every manifest declares **Evidence Schema Version** `1.0` and includes the claim, relative artifact names, types, capture times, hashes, capture scope, privacy result, and relevant tool versions.
- [ ] Comparison manifests identify the exact baseline and candidate revisions used for capture.
- [ ] Portable output excludes usernames, absolute paths, environment variables, credentials, unnecessary URL parameters, and private values.
- [ ] Detailed diagnostics remain separate **Private Outputs** and are excluded from the portable bundle by default.
- [ ] Bundle finalization is atomic, finalized bytes are immutable, and no existing non-identical bundle is overwritten.
- [ ] Bundle schema, hashing, redaction, tamper, and compatibility tests pass.

**Validation Test:**

- **Setup:** Produce comparison, behavior, after-only, empty-artifact, and tampered bundle fixtures with private machine details present in the runtime environment.
- **Steps:**
  1. Validate and finalize each legitimate fixture.
  2. Inspect required fields and revision identities.
  3. Search portable files for private machine details.
  4. Validate the tampered fixture and attempt a destination collision.
- **Expected Result:** Legitimate bundles validate without private details, tampering is detected, and a non-identical collision is refused without overwrite.
- **Failure Indicator:** A required identity is missing, private data is portable, tampering passes, or finalization replaces an existing bundle.

### US-018: Review privacy findings without altering originals

**Description:** As the captain, I want suspected sensitive content flagged before export or import so that I can resolve each finding without losing the original evidence.

**Acceptance Criteria:**

- [ ] **Privacy Review** inspects the exact bundle that will be offered or exported.
- [ ] Every suspected sensitive item becomes an individually identified **Privacy Finding**.
- [ ] Any unresolved finding blocks local export and **Evidence Import Consent**.
- [ ] Each finding can be explicitly accepted, cropped, redacted into a derived artifact, or resolved by excluding its artifact.
- [ ] Originals in the **Local Evidence Store** are never silently altered.
- [ ] Explicit acceptance alone does not require a new preview when artifact bytes, batch, finding set, and destination remain unchanged.
- [ ] A derivation, crop, redaction, exclusion, file change, batch change, finding-set change, or destination change produces a new exact preview before authority can be granted.
- [ ] Privacy review and derived output are verified in browser using `chrome-devtools-axi`.

**Validation Test:**

- **Setup:** Create a bundle containing one benign screenshot, two screenshots with suspected sensitive content, and their original hashes.
- **Steps:**
  1. Open the privacy review using `chrome-devtools-axi`.
  2. Attempt export and import consent with the finding unresolved.
  3. Explicitly accept one finding without changing its artifact bytes, the batch, the finding set, or the destination, and confirm the current exact preview remains valid.
  4. Resolve the other finding through a redacted derivative.
  5. Compare original and derived hashes and open the new preview.
- **Expected Result:** Unresolved publication is blocked, unchanged explicit acceptance preserves the current preview, the original remains byte-identical, the derivative has a new identity, and only the newly previewed changed batch can receive authority.
- **Failure Indicator:** Original bytes change, unresolved evidence proceeds, unchanged acceptance invalidates the preview, or an old decision applies to the derived batch.

### US-019: Operate the local Evidence Review Surface

**Description:** As the captain, I want one local review page for evidence, privacy, destination, and cleanup decisions so that inspection itself never uploads or mutates anything.

**Acceptance Criteria:**

- [ ] The **Evidence Review Surface** presents the exact bundle, side-by-side comparisons where applicable, manifest details, privacy findings, destination, and proposed cleanup files with sizes.
- [ ] Firstmate uses its existing visual review capability when available, and the standalone **Local Evidence Controller** generates equivalent local HTML.
- [ ] Opening, rendering, or closing the page causes no upload, publication, export, or cleanup.
- [ ] A **Review Decision** may resolve findings, authorize an exact local export, grant **Evidence Import Consent**, or grant **Evidence Cleanup Approval**.
- [ ] The page never performs the external action directly.
- [ ] Firstmate acts as the host controller in integrated use, while the public skill's trusted non-browser **Local Evidence Controller** owns private storage and decision intake in standalone use.
- [ ] The active host controller revalidates exact hashes, batch, and destination before performing an approved local action and also revalidates the no-mistakes run and reviewed head before routing import consent.
- [ ] The standalone controller retains control state outside the project worktree and cannot grant **Publication Approval** or mutate a pull request directly.
- [ ] The surface and no-side-effect behavior are verified in browser using `chrome-devtools-axi`.

**Validation Test:**

- **Setup:** Prepare an exact bundle with comparison images, one privacy finding, a local destination, a pull request destination, and proposed cleanup files.
- **Steps:**
  1. Open the Firstmate review and standalone HTML versions using `chrome-devtools-axi`.
  2. Compare their displayed identities, decisions, and controller bindings.
  3. Submit an exact local-only decision through each host controller and verify its bindings are revalidated.
  4. Reopen both surfaces and close them without submitting another decision.
  5. Inspect local export, import, cleanup, and remote publication state.
- **Expected Result:** Both surfaces show equivalent exact information, each decision is handled only by its trusted host controller, and closure leaves every further action unauthorized and unchanged.
- **Failure Indicator:** A surface omits a binding, loads remote content, acts directly, routes standalone decisions to Firstmate, or inspection alone changes local or remote state.

### US-020: Export an exact reviewed batch locally

**Description:** As the captain, I want local export bound to one reviewed batch and folder so that exporting evidence never overwrites unrelated files or expands an approval.

**Acceptance Criteria:**

- [ ] Local export copies only the exact reviewed batch to the chosen local folder after its **Review Decision**.
- [ ] The exporter revalidates batch hashes and destination immediately before copying.
- [ ] An identical existing export is idempotent.
- [ ] A differing destination collision is refused without overwrite or merge.
- [ ] A file or destination change requires a new preview and Review Decision.
- [ ] Focused export, collision, drift, and replay tests pass.

**Validation Test:**

- **Setup:** Prepare two different bundles with the same proposed export name and approve the first bundle for that exact local folder.
- **Steps:**
  1. Export the first bundle twice.
  2. Attempt to export the second bundle to the occupied destination.
  3. Change one approved artifact and retry the first export.
- **Expected Result:** The identical replay is harmless, the differing collision is refused, and the changed batch requires a new preview and decision.
- **Failure Indicator:** Export overwrites or merges different content, stale authority survives drift, or identical replay creates a second copy.

### US-021: Hand consented evidence to no-mistakes

**Description:** As the captain, I want the active trusted host controller to route one exact consented batch to the owning worker so that no-mistakes can stage it without treating consent as publication authority.

**Acceptance Criteria:**

- [ ] **Evidence Import Consent** identifies the exact reviewed batch, manifest and artifact hashes, pull request destination, no-mistakes run, and reviewed head offered to no-mistakes.
- [ ] Firstmate performs the host-controller handoff in integrated use, and the **Local Evidence Controller** performs it in standalone use.
- [ ] The active trusted host controller revalidates every consent binding before routing it to the owning project worker.
- [ ] The owning worker drives **Approved Evidence Import** through the no-mistakes flow.
- [ ] The handoff does not authorize or perform pull request mutation.
- [ ] Changed batch, manifest or artifact hash, destination, run, or head bindings refuse the handoff and require a new local preview.
- [ ] Focused integrated-host, standalone-host, worker-ownership, drift, and no-publication tests pass.

**Validation Test:**

- **Setup:** Prepare one consented bundle and pull request destination plus variants with changed batch, manifest hash, artifact hash, destination, no-mistakes run, and reviewed-head bindings.
- **Steps:**
  1. Route the unchanged consent through Firstmate in integrated use and through the Local Evidence Controller in standalone use.
  2. Inspect no-mistakes staging and pull request state for each route.
  3. Attempt every changed variant through both host controllers.
- **Expected Result:** Each unchanged route reaches protected staging without publication, while every changed variant fails before handoff or staging.
- **Failure Indicator:** Either host controller mutates the pull request, consent becomes publication authority, a route omits the owning worker, or a changed binding is accepted.

### US-022: Clean up only exact approved private outputs

**Description:** As the captain, I want cleanup bound to exact previewed files so that retained evidence never expires automatically and removal remains recoverable.

**Acceptance Criteria:**

- [ ] No **Private Output** expires or is removed automatically.
- [ ] Cleanup previews each proposed file and its size before requesting **Evidence Cleanup Approval**.
- [ ] Approved cleanup moves only the exact previewed files to recoverable operating-system trash.
- [ ] Firstmate never empties recoverable trash.
- [ ] Permanent deletion requires a separate explicit captain request naming exact files.
- [ ] Focused cleanup, changed-file, partial-approval, and refusal tests pass.

**Validation Test:**

- **Setup:** Prepare three private outputs and preview only two for cleanup, then change one previewed file before approval is applied.
- **Steps:**
  1. Attempt cleanup without approval.
  2. Grant approval for the original two-file preview and apply it after one file changes.
  3. Generate a new preview, approve the unchanged exact set, and inspect the Local Evidence Store and trash.
- **Expected Result:** The first two attempts remove nothing, and the fresh approval moves only the exact approved files while leaving the third file and trash contents recoverable.
- **Failure Indicator:** Any file expires, changed or unpreviewed content is removed, trash is emptied, or permanent deletion occurs without a separate request.

### US-023: Enforce Visual Evidence v1 readiness

**Description:** As a release owner, I want a single readiness gate across all coordinated deliveries so that a partial local-only implementation is never presented as complete version 1.

**Acceptance Criteria:**

- [ ] The readiness gate requires shipped **Structural Review** guidance, available producer-neutral **Approved Evidence Import**, and the complete public Visual Evidence integration.
- [ ] Approved local export passes end to end under the privacy and review contract.
- [ ] Approved GitHub pull request publication passes end to end through consent, protected import, no-mistakes preview, publication approval, evidence publication, and managed PR description.
- [ ] Every negative authority, privacy, drift, replay, and bypass test passes.
- [ ] The release process refuses to label or announce version 1 while any prerequisite is missing.
- [ ] Public and maintainer documentation describe the shipped scope and supported limits without claiming Linux, Windows, native capture, or video support.

**Validation Test:**

- **Setup:** Assemble one environment with only local export and another with all three coordinated deliveries and isolated forge fixtures.
- **Steps:**
  1. Run the readiness gate in the local-only environment.
  2. Run every story validation and the readiness gate in the complete environment.
  3. Inspect release metadata and documentation in both environments.
- **Expected Result:** The local-only environment is explicitly incomplete, while the complete environment passes every contract and is eligible for version 1 release.
- **Failure Indicator:** Local export alone qualifies as version 1, a prerequisite is skipped, or published scope exceeds the resolved contract.

## Functional Requirements

- FR-1: Firstmate must trigger **Structural Review** only for duplicated mechanics, competing implementations of one responsibility, or unclear ownership in the requested change.
- FR-2: Structural Review must require existing one-owner violations to be fixed and keep ordinary refactoring opportunities advisory.
- FR-3: Structural Review must not create abstractions merely to satisfy a routine.
- FR-4: Structural Review must deepen only the affected responsibility and report unrelated duplication separately.
- FR-5: The three adaptations must be original MIT-licensed clean-room implementations without vendored upstream prose or code.
- FR-6: No-mistakes must expose **Approved Evidence Import** as a narrow producer-neutral interface.
- FR-7: The import contract must bind the exact manifest hash, artifact paths and hashes, approval identity, run, reviewed head, destination, and declared media types.
- FR-8: The importer must reject malformed schema, unsupported major versions, missing required fields, duplicate paths, unsafe paths, and unsupported media types.
- FR-9: The importer must accept compatible optional fields within a supported major schema version.
- FR-10: Imported evidence must be staged outside the project worktree under no-mistakes-owned run state.
- FR-11: Protected staging must refuse symlinks, path traversal, mutable substitutions, and non-regular artifacts.
- FR-12: Staging must verify hashes from its protected copy and finalize atomically without overwriting non-identical state.
- FR-13: **Evidence Import Consent** must bind one exact reviewed batch, manifest and artifact hashes, no-mistakes run, reviewed head, and pull request destination before protected staging.
- FR-14: Evidence Import Consent must authorize only an offer to no-mistakes and must not authorize pull request mutation.
- FR-15: No-mistakes must render its own exact preview from protected staging.
- FR-16: Only a no-mistakes-owned **Publication Approval** after that preview may authorize pull request mutation.
- FR-17: Project manifests, project JSON, repository configuration, environment configuration, `--yes`, and generic automatic approval must not grant consent or publication approval.
- FR-18: Publication must revalidate every hash, media type, run, reviewed head, destination, and approval immediately before remote mutation.
- FR-19: Drift, replay, changed destination, changed run, changed reviewed head, or consumed authority must require a new preview and authorization.
- FR-20: Concurrent publication attempts must consume at most one approval.
- FR-21: Approved evidence must publish through no-mistakes' evidence branch without entering feature or default branch history.
- FR-22: The **Managed PR Description** must link the exact approved batch through immutable evidence-commit addresses.
- FR-23: Version 1 must not add comment-based evidence publication or promise preservation of manual text in the managed description.
- FR-24: Firstmate must route project publication to the owning worker and no-mistakes instead of mutating project pull requests directly.
- FR-25: Firstmate must publish one public **Visual Evidence** skill containing Comparison Mode and Behavior Mode under one lifecycle owner.
- FR-26: Firstmate must not publish separate `before-and-after`, `evidence-driven-testing`, or universal `code-structure` skills for this adaptation.
- FR-27: **Evidence Intake Classification** must occur before dispatch, and workers must not self-activate Visual Evidence.
- FR-28: Relevant evidence must default to supplemental unless the captain's request or documented project policy establishes it as required.
- FR-29: Worker briefs must carry an explicit evidence contract and canonical public skill path when Visual Evidence is active.
- FR-30: Workers must report unexpected impact, and Firstmate alone must perform **Evidence Reclassification** under the same authority rules.
- FR-31: **Scenario Definitions** must explicitly provide non-secret startup, readiness, fixture, route, viewport, interaction, assertion, capture, and claim information and, for Comparison Mode, independently isolated server-side synthetic fixture namespaces or deterministic reset before each capture.
- FR-32: **Scenario Values** must remain ignored local state and must never enter portable output or diagnostics.
- FR-33: Visual Evidence must never invent startup or fixture commands and must report scenarios that lack required explicit inputs.
- FR-34: Version 1 must support macOS browser capture only and must make no Linux or Windows support claim.
- FR-35: Version 1 must use an **Isolated Test Browser** with a **Task-scoped Browser Profile** and must never access the captain's ordinary signed-in browser session.
- FR-36: A task-scoped profile may preserve state only within its task and must not be reused by another task.
- FR-37: Visual Evidence must seed captures only from **Synthetic Test Fixtures** or clean anonymous state and must never copy a current or production environment automatically.
- FR-38: Visual Evidence must capture only scenario-named viewports and must not run an automatic device matrix.
- FR-39: Comparison Mode must use separate browser contexts with equivalent viewport, setup, fixture, authentication, and initial synthetic state inputs plus independently isolated server-side synthetic fixture namespaces or deterministic reset before each capture.
- FR-40: A before-and-after claim must require a successfully run and equivalently captured exact **Baseline Revision**, distinct from the candidate head, as its **Verified Baseline**.
- FR-41: Historical or user-provided screenshots must not be labeled as Verified Baseline evidence.
- FR-42: Required comparison evidence must fail when the baseline is unavailable, while supplemental evidence may produce reasoned **After-only Evidence** without a comparison claim.
- FR-43: Comparison Mode must always present baseline and candidate side by side.
- FR-44: An **Explanatory Diff** must be optional and must become pass or fail only under documented project policy.
- FR-45: **Claim-aware Stabilization** must control only nondeterminism irrelevant to the claim and must be listed in the manifest.
- FR-46: Behavior Mode must first evaluate whether lighter automated or screenshot evidence is sufficient.
- FR-47: Behavior Mode must use sequenced screenshots, automated assertions, and timing notes only when needed for minimum sufficient evidence.
- FR-48: Version 1 must not produce video or use operating-system-level screen capture.
- FR-49: Visual evidence must complement feasible automated assertions and must not claim to prove hidden application behavior.
- FR-50: Every **Evidence Bundle** must contain a versioned Portable Manifest and human-readable report with zero or more visual artifacts.
- FR-51: Portable manifests must include claim, relative artifact identity, type, capture time, hash, capture scope, privacy result, tool versions, and applicable revision identities.
- FR-52: Portable bundles must exclude usernames, absolute paths, environment variables, credentials, private values, and unnecessary URL parameters.
- FR-53: Original bundles and diagnostic appendices must remain private in the ignored **Local Evidence Store** unless exact authority permits an export or publication copy.
- FR-54: **Privacy Review** must flag suspected sensitive content and block export or import consent while any finding remains unresolved.
- FR-55: Privacy resolution must preserve originals; explicit acceptance alone must preserve the current exact preview when bytes, batch, finding set, and destination are unchanged, while derivation, crop, redaction, exclusion, file change, batch change, finding-set change, or destination change must require a new exact preview.
- FR-56: The **Evidence Review Surface** must render locally, cause no upload or mutation, and provide exact review choices without performing external actions directly.
- FR-57: The active trusted host controller must revalidate hashes, batch, and destination after a Review Decision and before performing an approved local action, and must also revalidate the no-mistakes run and reviewed head before routing consent for protected staging.
- FR-57a: Firstmate must be the host controller in integrated use, while the public skill's trusted non-browser Local Evidence Controller must own private storage, decision intake, approved local actions, and no-mistakes consent routing in standalone use.
- FR-57b: The Local Evidence Controller must retain control state outside the project worktree and must not grant Publication Approval or mutate a pull request directly.
- FR-58: Local export must be exact and non-overwriting, with identical replay treated idempotently and differing collisions refused.
- FR-59: No Private Output may expire or be removed automatically.
- FR-60: Cleanup must preview exact files and sizes and move only approved files to recoverable trash.
- FR-61: Firstmate must never empty recoverable trash, and permanent deletion must require a separate exact captain request.
- FR-62: Unavailable required visual evidence must prevent full validation, while unavailable supplemental evidence must be reported without failing otherwise successful automated validation.
- FR-63: Expected visual evidence must never be silently omitted.
- FR-64: Anonymous upload sites, Gists, arbitrary web endpoints, and unsupported third-party destinations must not be used.
- FR-65: Version 1 must remain unreleased until approved local export and approved GitHub pull request publication both pass end to end with all three coordinated deliveries.

## Non-Goals

- No vendoring of upstream skill prose, code, scripts, or assets.
- No separate public before-and-after, evidence-driven-testing, or universal code-structure skill.
- No unconditional structural review or broad cleanup outside the responsibility affected by the requested change.
- No Linux or Windows support claim in version 1.
- No native application-window, operating-system region, or full-desktop capture in version 1.
- No video recording or operating-system-level recording fallback in version 1.
- No access to the captain's ordinary signed-in browser profile.
- No automatic copying of production or current environments into capture state.
- No automatic standard device or viewport matrix.
- No visual claim that hidden application behavior was proved.
- No silent replacement of feasible machine-verifiable assertions with screenshots.
- No automatic upload, anonymous host, Gist, arbitrary endpoint, or unsupported third-party publication.
- No comment-based pull request evidence publication in version 1.
- No direct project pull request mutation by Firstmate.
- No authority derived from project-controlled files, configuration, `--yes`, or generic automatic approval.
- No automatic evidence expiry, silent original alteration, unapproved overwrite, or unapproved cleanup.
- No local-export-only version 1 release.
- No cryptographically trusted external single-approval receipt in version 1.

## Design Considerations

- The local **Evidence Review Surface** should foreground the demonstrated claim, requirement level, destination, and unresolved privacy findings before any decision control.
- Comparison reviews should place baseline and candidate at equal visual weight and preserve their scenario viewport labels.
- Behavior reviews should present sequence order, timing notes, and associated automated assertions without implying video playback.
- Explanatory diffs should be visually subordinate to baseline and candidate because they are not verdicts unless project policy supplies a threshold.
- Privacy findings should identify the affected artifact and suspected region without automatically altering original pixels.
- Derived crops and redactions should appear as new artifacts with new hashes rather than replacements hidden behind the original name.
- No-mistakes' protected preview must clearly state that import consent has already occurred but publication approval remains pending.
- Closing either review surface must have the same effect as submitting no decision.
- The standalone local HTML review must provide equivalent information to Firstmate's preferred visual review surface and must not depend on an upload.

## Technical Considerations

- The PRD template requires an unavailable `dev-browser` skill for UI validation, so this PRD substitutes Firstmate's supported `chrome-devtools-axi` wording for every browser acceptance criterion.
- The domain terms and relationships in [CONTEXT.md](../CONTEXT.md) remain authoritative if shorthand in this PRD appears ambiguous.
- The architectural rationale and rejected alternatives remain owned by [ADR 0001](adr/0001-public-visual-evidence-with-private-outputs.md).
- Firstmate and no-mistakes are separate delivery surfaces, so each repository must ship and validate its own part before the combined readiness gate runs.
- Firstmate's hard project-write boundary remains in force, so project-specific capture derivatives and no-mistakes pipeline calls belong to the owning worker.
- The public skill must remain installer-facing rather than being duplicated into Firstmate's internal loaded skill set.
- The public skill must ship its **Local Evidence Controller** so standalone installations do not depend on Firstmate for private storage, decision intake, revalidation, export, cleanup, or no-mistakes consent routing.
- Firstmate integration and standalone use must share the same controller contract, while only no-mistakes owns protected publication approval and pull request mutation.
- Worker dispatch and reclassification need deterministic contracts that do not rely on workers inferring relevance from skill descriptions.
- Import parsing, protected staging, approval state, and publication consumption need one semantic owner inside no-mistakes.
- Authorization state must live outside project control and must be durable across process restarts without turning a receipt file into authority.
- Hashes must be computed from the exact protected or finalized copy used by the next authority step.
- File operations must fail closed on symlinks, containment ambiguity, cross-device finalization, race detection, and non-identical destination collisions.
- Browser startup must detect supported tool capabilities and versions without attaching to ambient browser sessions or installing dependencies automatically.
- Capture must use separate safe browser contexts for the **Baseline Revision** and candidate head while preserving equivalent scenario inputs and isolating server-side synthetic state through independent fixture namespaces or deterministic reset before each capture.
- The selected diff implementation must be deterministic for a declared metric, but a project threshold remains the only source of a pass-or-fail diff verdict.
- Portable schema parsers must reject unsupported major versions and missing required fields while tolerating newer optional fields within the same major version.
- Security tests must include hostile project content, nested validation processes, malformed manifests, path escapes, content drift, replay, concurrent consumption, and stale run or head bindings.
- Documentation verification must include `bin/fm-doc-audience-check.sh`, and implementation branches must use each repository's ordinary lint, focused test, and no-mistakes delivery path.

## Risks and Mitigations

- **Risk:** Two authority steps may be mistaken for duplicate UI noise.
- **Mitigation:** Each preview must clearly explain that local consent offers evidence while the no-mistakes approval authorizes remote mutation.
- **Risk:** A project may forge a plausible approval JSON.
- **Mitigation:** Project data is never authority, and no-mistakes accepts publication approval only through protected local control state bound to its staged copy.
- **Risk:** Evidence may change between preview and publication.
- **Mitigation:** Every transition binds hashes and context, and publication revalidates immediately before mutation.
- **Risk:** Browser capture may expose personal or production data.
- **Mitigation:** Version 1 uses isolated task profiles with synthetic fixtures or clean anonymous state, isolates server-side synthetic state through independent fixture namespaces or deterministic reset before each capture, and never attaches to the ordinary signed-in browser.
- **Risk:** Visual evidence may be treated as proof of hidden behavior.
- **Mitigation:** Automated assertions remain required where feasible, and reports limit claims to appearance and observable interaction.
- **Risk:** Evidence storage may grow indefinitely because automatic expiry is prohibited.
- **Mitigation:** The review surface presents exact cleanup candidates and sizes, while removal remains recoverable and approval-bound.
- **Risk:** A partial local-export implementation may be announced as complete.
- **Mitigation:** The readiness gate fails until the producer-neutral no-mistakes prerequisite and approved pull request publication are available end to end.

## Success Metrics

- All 23 story Validation Tests pass on the supported macOS environment.
- One hundred percent of tampered, replayed, drifted, unsupported-media, unsafe-path, nested-gate, and project-forged authority fixtures fail before publication.
- One hundred percent of finalized bundle artifacts match their Portable Manifest hashes.
- Zero tests place evidence artifacts into a feature branch or default branch.
- Zero privacy test values appear in portable manifests, reports, logs, or review pages.
- Required-evidence failure tests always prevent full validation, while supplemental-evidence failure tests preserve otherwise successful automated validation and report the reason.
- Comparison tests always show a **Baseline Revision** distinct from the candidate head, equivalent inputs, and no browser or server state flow between captures, or explicitly refuse the comparison claim.
- Browser isolation tests show zero access to the ordinary signed-in profile and zero cross-task profile reuse.
- Local export tests show zero non-identical overwrites and exact idempotence for identical replay.
- Publication tests show at most one evidence publication and one matching Managed PR Description update per consumed approval, with immutable evidence links and no duplicate of either action on replay.
- Documentation and packaging checks pass with one public Visual Evidence skill and no vendored upstream implementation.
- Version 1 release metadata is produced only after all three coordinated deliveries and both approved destinations pass end to end.

## Open Questions

No product questions remain unresolved.
The following engineering follow-ups must be settled during implementation without changing product scope:

- Choose the concrete ignored Local Evidence Store path and namespace within Firstmate's private home layout and the equivalent host-private application-data path for standalone use.
- Finalize the exact Portable Manifest version 1.0 field names and JSON Schema while preserving every required and excluded datum.
- Finalize Scenario Definition and Scenario Values discovery paths and machine schemas within the tracked-versus-private boundary.
- Choose no-mistakes command names, durable state tables, protected preview transport, and single-consumption transaction boundaries.
- Define the exact version 1 allowed-media list from the already resolved screenshot-focused scope.
- Select deterministic pixel-diff tooling and a declared metric without inventing a default pass threshold.
- Set supported browser-tool version and capability checks for macOS.
- Specify atomic staging markers, interrupted-capture recovery records, and task-profile cleanup mechanics.
- Define the exact Firstmate brief and durable reclassification message fields for the evidence contract.
- Define the shared local review decision transport and replay record used by Firstmate and the standalone Local Evidence Controller while preserving the browser surface's non-authoritative boundary.
