# Firstmate Context

This glossary distinguishes reusable skill implementations from the private data they produce.

## Language

**Public Skill Implementation**:
A reusable skill implementation that may be published for others to install and use.

**Clean-room Skill Implementation**:
An original Firstmate implementation derived from independently stated requirements and observable behavior without copying upstream prose or code.

**Structural Review**:
A conditional review triggered by duplicated mechanics, competing implementations of one responsibility, or unclear ownership in a Firstmate change.

**Visual Evidence**:
The single public **Clean-room Skill Implementation** that produces **Evidence Bundles**.

**Visual Evidence v1 Readiness**:
The condition that approved local export and approved GitHub pull request publication both work end to end under the agreed privacy and approval contract.

**Evidence Intake Classification**:
Firstmate's pre-dispatch decision from the captain's request and documented project acceptance policy about whether **Visual Evidence** is relevant and whether it is **Required Visual Evidence** or **Supplemental Visual Evidence**.

**Evidence Reclassification**:
Firstmate's decision to add or change **Visual Evidence** after a worker reports previously unknown visual or behavioral impact.

**Evidence Scenario**:
The explicit project or task definition of application startup, readiness, **Synthetic Test Fixture** setup, route, **Scenario Viewports**, interactions, assertions, and demonstrated claim for **Visual Evidence**.
For **Comparison Mode**, it also declares independently isolated server-side synthetic fixture namespaces or a **Deterministic Capture Reset**.

**Scenario Viewport**:
A browser viewport explicitly named by an **Evidence Scenario**.

**Scenario Definition**:
The tracked reusable non-secret structure of an **Evidence Scenario**.

**Scenario Values**:
Ignored local credentials, private URLs, and sensitive overrides supplied to an **Evidence Scenario**.

**Comparison Mode**:
The **Visual Evidence** mode for before-and-after screenshot evidence of **Relevant Visual Changes**.

**Explanatory Diff**:
A pixel-difference artifact that helps explain visual changes between a **Verified Baseline** and the candidate version.

**Behavior Mode**:
The **Visual Evidence** mode for **Minimum Sufficient Evidence** of **Relevant Behavioral Changes** using sequenced screenshots, automated assertions, and timing notes.

**Private Output**:
Project or personal data, including evidence, produced by a skill that remains private unless the captain explicitly approves its publication.

**Local Evidence Store**:
The ignored local location where **Private Outputs** are retained and never synchronized automatically.

**Evidence Import Consent**:
The captain's one-time authorization through an **Evidence Review Surface** to offer one exact previewed **Evidence Bundle** or batch, its manifest and artifact hashes, its no-mistakes run and reviewed head, and its named destination to no-mistakes.

**Publication Approval**:
The no-mistakes-owned one-time authorization granted after protected staging, revalidation, and its own exact preview to publish one exact evidence batch to one named pull request destination.

**Approved Evidence Import**:
A narrow producer-neutral no-mistakes interface that accepts a previously previewed exact **Evidence Bundle** after validation and before managed pull request publication.

**Publication Destination**:
The named place receiving an approved copy of an **Evidence Bundle**.

**Managed PR Description**:
The pull request description generated and replaced by no-mistakes, including its evidence section.

**Evidence Cleanup Approval**:
The captain's authorization to remove an exact previewed set of **Private Outputs** after their associated work is finished.

**Evidence Bundle**:
One common package of a manifest, human-readable report, and zero or more visual artifacts produced by **Visual Evidence**.

**Evidence Review Surface**:
A local browser page that presents an exact **Evidence Bundle**, side-by-side comparisons, manifest details, **Privacy Findings**, the **Publication Destination**, and proposed cleanup files with their sizes.

**Review Decision**:
Structured choices submitted from an **Evidence Review Surface** to resolve a **Privacy Finding**, authorize a local export, grant **Evidence Import Consent**, or grant **Evidence Cleanup Approval**.

**Local Evidence Controller**:
The trusted non-browser controller shipped with **Visual Evidence** that owns **Local Evidence Store** access, receives **Review Decisions**, revalidates their exact bindings, applies approved local actions, and routes **Evidence Import Consent** to no-mistakes when Firstmate is not the host.

**Complementary Evidence**:
Visual evidence that supports but does not replace feasible automated assertions.

**Required Visual Evidence**:
Expected visual evidence that must succeed for full validation.

**Supplemental Visual Evidence**:
Expected visual evidence whose unavailability does not fail otherwise successful automated validation.

**Portable Manifest**:
The minimal machine-readable index of an **Evidence Bundle**.

**Evidence Schema Version**:
The compatibility identifier for a **Portable Manifest**, starting at `1.0`.

**Minimum Sufficient Evidence**:
The smallest set of artifacts that convincingly proves the claimed behavior.

**Claim-aware Stabilization**:
Removal or control of nondeterminism only when it is irrelevant to the evidenced claim.

**Relevant Visual Change**:
A material user-visible change for which comparison evidence improves verification.

**Relevant Behavioral Change**:
Motion, timing, interaction order, or transient behavior for which ordinary tests and screenshots do not provide **Minimum Sufficient Evidence**.

**Capture Scope**:
The named browser page, application window, or selected region from which an **Evidence Bundle** may collect visual artifacts.

**Browser Capture Scope**:
A named webpage, viewport, element, or page region supported by **Visual Evidence** version 1.

**Isolated Test Browser**:
A dedicated browser session separated from the captain's ordinary browser profile and personal state.

**Task-scoped Browser Profile**:
An **Isolated Test Browser** profile created for one task and never reused by another.

**Paired Capture Contexts**:
Separate before and after browser contexts created with equivalent safe test-state seeds and the server-side synthetic state isolation declared by their **Evidence Scenario**.

**Deterministic Capture Reset**:
A scenario-declared synthetic-state procedure that serializes paired captures, stops or drains the prior capture's server-side work before resetting, and verifies quiescence before the next capture begins.
It is unavailable when deterministic draining cannot be guaranteed and is never used for asynchronous scenarios, which require independently isolated server-side synthetic fixture namespaces.

**Synthetic Test Fixture**:
Repeatable project-provided non-production data and setup used to seed **Paired Capture Contexts**.

**Baseline Revision**:
The exact base or other explicitly named reference revision selected for comparison, which must be distinct from the candidate head.

**Verified Baseline**:
A **Baseline Revision** run successfully and captured under conditions equivalent to the candidate head.

**After-only Evidence**:
An **Evidence Bundle** that proves only the changed version and makes no comparison claim.

**Privacy Scan Result**:
The immutable portable record of a **Privacy Review** scan outcome and its exact **Privacy Finding** set, excluding acceptance and other approval state.

**Privacy Review**:
Inspection of an exact **Evidence Bundle** for suspected sensitive content before publication.

**Privacy Finding**:
Suspected sensitive content identified during a **Privacy Review**.

## Relationships

- A **Public Skill Implementation** may produce one or more **Private Outputs**.
- The upstream `before-and-after`, `code-structure`, and `evidence-driven-testing` capability inspirations are adapted through clean-room implementation.
- These three adaptations are MIT-licensed with Firstmate.
- Upstream code and instructions are not vendored into these adaptations.
- The clean-room `code-structure` principles are folded into Firstmate's existing coding guidance.
- The `code-structure` principles apply to Firstmate's command-script and shared-library ownership model.
- Firstmate does not publish `code-structure` as a separate universal skill.
- A **Structural Review** requires violations of Firstmate's existing one-owner rules to be fixed.
- Ordinary refactoring opportunities found by a **Structural Review** remain recommendations.
- A **Structural Review** never creates an abstraction merely to satisfy a routine.
- A **Structural Review** may deepen only the responsibility directly affected by the requested change.
- Related duplication outside that responsibility is reported separately.
- A **Structural Review** never silently expands the assignment.
- The coordinated scope delivers Firstmate's **Structural Review** guidance, then no-mistakes **Approved Evidence Import**, then the complete **Visual Evidence** version 1 after that prerequisite is available.
- The upstream names `before-and-after` and `evidence-driven-testing` inspire **Comparison Mode** and **Behavior Mode**, not separate Firstmate skills.
- **Visual Evidence** is the single owner of capture, privacy, storage, publication, and cleanup for both modes.
- Firstmate performs **Evidence Intake Classification** before dispatch.
- Workers do not self-activate **Visual Evidence**.
- A worker reports previously unknown visual or behavioral impact without self-activating **Visual Evidence**.
- Firstmate responds to that report through **Evidence Reclassification**.
- **Evidence Reclassification** uses the same captain-request and documented-project-policy authority as **Evidence Intake Classification** to determine whether evidence is required or supplemental.
- Reclassified **Comparison Mode** evidence remains subject to the **Verified Baseline** rules.
- An **Evidence Scenario** combines a **Scenario Definition** with any required **Scenario Values**.
- A **Scenario Definition** is tracked with the project and contains no secrets.
- **Scenario Values** remain ignored local state.
- **Visual Evidence** never invents application startup or fixture commands for an **Evidence Scenario**.
- Task-specific instructions may complete non-secret **Scenario Definition** fields or name required **Scenario Values**.
- Missing required **Scenario Values** are reported by name without exposing their values.
- An **Evidence Scenario** without enough explicit information cannot run, and that outcome is reported.
- An **Evidence Bundle** is a **Private Output**.
- Opening or rendering an **Evidence Review Surface** causes no upload or publication.
- Firstmate presents the **Evidence Review Surface** through its existing visual review capability when that capability is available.
- Standalone use runs the **Local Evidence Controller**, which generates an equivalent local HTML **Evidence Review Surface** and retains its control state outside the project worktree.
- An **Evidence Review Surface** never performs an external action directly.
- In Firstmate-integrated use, Firstmate receives a **Review Decision** and acts as the host controller.
- In standalone use, the **Local Evidence Controller** receives the same **Review Decision** through a local-only control channel.
- The active trusted host controller revalidates every **Review Decision** binding before acting, including the no-mistakes run, reviewed head, exact batch, manifest and artifact hashes, and pull request destination before routing **Evidence Import Consent** for protected staging.
- The **Local Evidence Controller** cannot grant **Publication Approval** or mutate a pull request directly.
- Any change to a binding covered by a **Review Decision** invalidates that decision and requires a new preview.
- Closing an **Evidence Review Surface** without submitting a **Review Decision** authorizes nothing.
- An **Evidence Bundle** is **Complementary Evidence** when the claimed behavior can be asserted automatically.
- Machine-verifiable behavior uses automated assertions.
- **Evidence Bundles** prove appearance and observable interaction.
- Purely visual claims may rely on human-reviewed screenshots.
- Visual artifacts never claim to prove hidden application behavior.
- Unavailable **Required Visual Evidence** prevents full validation from succeeding.
- Unavailable **Supplemental Visual Evidence** does not fail otherwise successful automated validation, but its unavailability reason is reported.
- Expected visual evidence is never silently omitted.
- **Required Visual Evidence** may be established only by the captain's request or a documented project acceptance policy.
- An **Evidence Intake Classification** that finds visual evidence relevant produces **Supplemental Visual Evidence** by default.
- Firstmate may recommend promoting **Supplemental Visual Evidence** to **Required Visual Evidence** but cannot silently reclassify it or add a failure condition.
- Each **Evidence Bundle** contains a **Portable Manifest**.
- A **Portable Manifest** includes the demonstrated claim, relative artifact names, artifact types, capture time, file hashes, **Capture Scope**, **Privacy Scan Result**, and relevant tool versions.
- A **Portable Manifest** excludes usernames, absolute local paths, environment variables, credentials, and unnecessary URL parameters.
- Every **Portable Manifest** declares an **Evidence Schema Version**.
- Unsupported major **Evidence Schema Versions** are rejected.
- Newer optional fields within the same major **Evidence Schema Version** are accepted.
- Missing required fields are not silently reinterpreted.
- A detailed diagnostic appendix, if needed, remains a separate **Private Output** and is not part of the portable **Evidence Bundle** by default.
- **Evidence Intake Classification** selects **Comparison Mode** for a **Relevant Visual Change**.
- **Comparison Mode** does not activate for every code, documentation, or backend change.
- **Comparison Mode** capture remains local and bounded to the **Capture Scope**.
- **Comparison Mode** always presents the baseline and candidate views side by side.
- **Comparison Mode** generates an **Explanatory Diff** only when the **Evidence Scenario** requests it.
- An **Explanatory Diff** is explanatory rather than pass or fail unless documented project policy defines a threshold.
- **Comparison Mode** may apply **Claim-aware Stabilization** by disabling irrelevant animation, awaiting declared readiness, or stabilizing synthetic time and random fixture values when the **Evidence Scenario** requests it.
- **Evidence Intake Classification** selects **Behavior Mode** only for a **Relevant Behavioral Change**.
- **Behavior Mode** first evaluates whether lighter evidence provides **Minimum Sufficient Evidence**.
- **Behavior Mode** records behavior only when lighter evidence does not suffice.
- **Behavior Mode** preserves motion and timing when they are relevant to the evidenced claim.
- Every applied **Claim-aware Stabilization** is listed in the **Portable Manifest**.
- An **Evidence Bundle** follows the **Minimum Sufficient Evidence** rule.
- Screenshots are preferred for stable visual facts.
- **Visual Evidence** version 1 does not produce video recordings.
- **Behavior Mode** uses sequenced screenshots, automated assertions, and timing notes.
- **Behavior Mode** never falls back to operating-system-level screen capture.
- If **Required Visual Evidence** specifically requires video, validation is incomplete.
- If **Supplemental Visual Evidence** calls for video, its unavailability is reported under the requirement-aware evidence policy.
- **Visual Evidence** version 1 uses existing browser tooling and supports only a **Browser Capture Scope**.
- **Visual Evidence** captures only **Scenario Viewports**.
- An **Evidence Scenario** may name several **Scenario Viewports** for a responsive claim.
- No standard device matrix runs automatically.
- Firstmate may recommend an additional **Scenario Viewport** but cannot add it silently.
- **Visual Evidence** version 1 officially supports macOS only.
- **Visual Evidence** version 1 makes no Linux or Windows support claim.
- **Visual Evidence** version 1 uses an **Isolated Test Browser** by default for reproducibility and privacy.
- The **Isolated Test Browser** uses a **Task-scoped Browser Profile**.
- A **Task-scoped Browser Profile** may preserve setup and authentication state within its task.
- A **Task-scoped Browser Profile** is disposable test state rather than an **Evidence Bundle**.
- A **Task-scoped Browser Profile** is discarded when its task finishes.
- **Comparison Mode** uses **Paired Capture Contexts** within the task.
- Each comparison **Evidence Scenario** declares independently isolated server-side synthetic fixture namespaces or a **Deterministic Capture Reset**.
- State changes in one of the **Paired Capture Contexts** never flow into the other.
- The **Paired Capture Contexts** share equivalent viewport, setup, fixture, authentication, and initial synthetic state inputs.
- **Visual Evidence** version 1 seeds **Paired Capture Contexts** only with a **Synthetic Test Fixture** or clean anonymous state.
- Server-side capture isolation and **Deterministic Capture Reset** operate only on synthetic test state.
- **Visual Evidence** never copies a current or production environment automatically.
- If neither a **Synthetic Test Fixture** nor clean anonymous state can demonstrate the required scenario, the **Evidence Bundle** or report states that the scenario could not be evidenced.
- **Comparison Mode** requires a **Verified Baseline** for a before-and-after claim.
- User-provided or historical screenshots cannot be labeled as **Verified Baseline** evidence.
- An unavailable **Verified Baseline** causes failure when the task requires before-and-after proof.
- When before-and-after proof is not required, **Visual Evidence** may produce **After-only Evidence** and must record why the baseline was unavailable.
- **Visual Evidence** version 1 never accesses the captain's ordinary signed-in browser session.
- Authenticated scenarios establish state inside the **Isolated Test Browser** through private test credentials or project-provided setup.
- Native application-window capture and operating-system region capture are deferred beyond version 1.
- Full-desktop capture is deferred and is not available in version 1.
- Visual artifact collection is bounded to the **Capture Scope** by default.
- If full-desktop capture is supported in a future version, it never occurs automatically.
- A future specific full-desktop capture requires case-by-case captain approval after a privacy warning.
- Suspected sensitive content in an **Evidence Bundle** is flagged for captain review through a **Privacy Review**.
- Originals in the **Local Evidence Store** are never silently altered during a **Privacy Review**.
- A **Privacy Review** may identify one or more **Privacy Findings**.
- A finalized **Portable Manifest** records the immutable **Privacy Scan Result**, including the exact **Privacy Finding** set, without recording any later acceptance or approval state.
- Any unresolved **Privacy Finding** prevents publication of the **Evidence Bundle**.
- Each **Privacy Finding** must be resolved individually by the captain through explicit acceptance, cropping or redacting into a derived artifact, or excluding the artifact from the previewed batch.
- Resolution of a **Privacy Finding** is bound to the exact previewed **Evidence Bundle**.
- The active trusted host controller stores explicit acceptance in private decision state bound to the unchanged manifest hash, artifact bytes, exact **Privacy Finding** set, batch, and destination.
- Explicit acceptance changes no **Privacy Scan Result** or bundle byte, so it does not rewrite the **Evidence Bundle** or require a new preview while those bindings remain unchanged.
- Derivation, cropping, redaction, exclusion, byte change, batch change, **Privacy Finding** set change, or destination change invalidates the decision and requires a new exact preview and **Review Decision**.
- A **Private Output** goes to the **Local Evidence Store** by default.
- No **Private Output** expires automatically.
- Evidence cleanup previews the exact files and sizes before requesting **Evidence Cleanup Approval**.
- An approved evidence cleanup moves only the exact previewed files to the operating system's recoverable trash.
- Firstmate never empties the operating system's recoverable trash.
- Permanent deletion is exceptional and requires a separate explicit captain request naming the exact files.
- Publishing a **Public Skill Implementation** does not publish its **Private Outputs** from the **Local Evidence Store**.
- A local export from the **Local Evidence Store** requires a **Review Decision** for the exact previewed batch and destination folder.
- GitHub pull request publication requires both **Evidence Import Consent** and a subsequent no-mistakes-owned **Publication Approval**.
- Version 1 supports a user-chosen local export folder as a **Publication Destination**.
- Version 1 supports an approved GitHub pull request as a **Publication Destination** only through the active trusted host controller and no-mistakes' validated publication flow.
- Firstmate is the active trusted host controller in integrated use, and the **Local Evidence Controller** is the active trusted host controller in standalone use.
- **Approved Evidence Import** validates every **Evidence Import Consent** binding, the approval identity, and allowed media types.
- **Approved Evidence Import** contains no Firstmate-specific or **Visual Evidence**-specific behavior.
- **Evidence Import Consent** authorizes only offering the exact bindings in its definition to **Approved Evidence Import**.
- **Evidence Import Consent** does not authorize pull request mutation.
- No-mistakes protects and revalidates the staged batch, presents its own exact preview, and alone owns the **Publication Approval** that authorizes pull request mutation.
- Project-controlled manifests or JSON, `--yes`, generic automatic approval, and configuration cannot grant **Evidence Import Consent** or **Publication Approval**.
- Any drift, replay, or change to the destination, run, or reviewed head invalidates the affected consent or approval and requires a new exact preview and authorization.
- **Visual Evidence v1 Readiness** requires no-mistakes to provide **Approved Evidence Import**.
- **Visual Evidence** version 1 is not released until **Approved Evidence Import** is available.
- Local export may be implemented and tested before **Visual Evidence v1 Readiness**, but local export alone is not a complete version 1 release.
- Unsafe direct publication or bypass of the validated no-mistakes flow is prohibited.
- The owning project worker and no-mistakes flow perform any project-specific pull request publication rather than Firstmate performing that mutation directly.
- Firstmate may perform an approved cleanup of home-local **Private Outputs**.
- Version 1 GitHub publication places the exact approved **Evidence Bundle** in the **Managed PR Description**.
- A no-mistakes rerun may regenerate the full **Managed PR Description**.
- Manual author text in the **Managed PR Description** is not preserved by contract.
- Version 1 does not add comment-based evidence publication.
- Anonymous upload sites, Gists, arbitrary web endpoints, and other third-party destinations are unsupported.
- A **Publication Approval** applies only to the exact no-mistakes-staged and previewed batch, run, reviewed head, and named pull request destination.
- A **Publication Approval** does not authorize **Private Outputs** produced later.
- A **Publication Approval** does not authorize publication to another destination.

## Example dialogue

> **Developer:** "Should this **Evidence Bundle** include a recording?"
> **Domain expert:** "No video is produced in version 1, so use sequenced screenshots, automated assertions, and timing notes without falling back to operating-system-level capture."
> **Developer:** "May visual evidence replace a feasible automated assertion?"
> **Domain expert:** "No, it is **Complementary Evidence** for appearance and observable interaction, and it never claims to prove hidden application behavior."
> **Developer:** "What happens when expected visual evidence cannot be captured?"
> **Domain expert:** "Unavailable **Required Visual Evidence** prevents full validation, while unavailable **Supplemental Visual Evidence** preserves automated validation but reports the reason."
> **Developer:** "May Firstmate classify relevant visual evidence as required on its own?"
> **Domain expert:** "No, Firstmate may recommend promotion, but only the captain's request or documented project acceptance policy establishes **Required Visual Evidence**."
> **Developer:** "Should a worker activate Visual Evidence when it thinks a change is relevant?"
> **Domain expert:** "No, Firstmate makes the **Evidence Intake Classification** before dispatch and tells the worker whether evidence is required or supplemental."
> **Developer:** "What if the worker later discovers an unexpected visual impact?"
> **Domain expert:** "The worker reports it, and Firstmate performs **Evidence Reclassification** under the same authority and baseline rules."
> **Developer:** "Should I invoke separate `before-and-after` and `evidence-driven-testing` skills?"
> **Domain expert:** "No, use **Visual Evidence** in **Comparison Mode** for a **Relevant Visual Change** or **Behavior Mode** when a **Relevant Behavioral Change** still lacks **Minimum Sufficient Evidence**."
> **Developer:** "May Visual Evidence guess the startup or fixture commands for this scenario?"
> **Domain expert:** "No, use explicit project or task instructions, and report that the **Evidence Scenario** cannot run when they do not provide enough information."
> **Developer:** "Where should a reusable scenario and its private login values live?"
> **Domain expert:** "Track the non-secret **Scenario Definition**, keep **Scenario Values** in ignored local state, and report a missing private value only by name."
> **Developer:** "May I copy the upstream skill instructions into Firstmate?"
> **Domain expert:** "No, implement the three adaptations as MIT-licensed **Clean-room Skill Implementations** without vendoring upstream prose or code."
> **Developer:** "May a **Structural Review** fix related duplication outside the responsibility I asked to change?"
> **Domain expert:** "No, deepen only the affected responsibility, report outside duplication separately, and never silently expand the assignment."
> **Developer:** "Should the **Portable Manifest** include an absolute path or environment variables for debugging?"
> **Domain expert:** "No, keep those details out of the portable bundle and retain any needed diagnostic appendix as a separate **Private Output**."
> **Developer:** "May a reader reinterpret a version `2.0` manifest or one missing a required field as version `1.0`?"
> **Domain expert:** "No, reject unsupported major versions and missing required fields while accepting newer optional fields within the same major version."
> **Developer:** "May I capture a native application window or the full desktop instead of the named browser region?"
> **Domain expert:** "No, version 1 supports only a **Browser Capture Scope**, while any future full-desktop support would require a privacy warning and case-by-case approval."
> **Developer:** "Should Visual Evidence run a standard desktop and mobile viewport matrix?"
> **Domain expert:** "No, capture only the **Scenario Viewports**, and recommend rather than silently add another viewport."
> **Developer:** "May Comparison Mode disable animation to make the screenshots stable?"
> **Domain expert:** "Only through requested **Claim-aware Stabilization** when the animation is irrelevant to the claim, and list the stabilization in the **Portable Manifest**."
> **Developer:** "Should Comparison Mode produce a pixel diff and fail on any changed pixel?"
> **Domain expert:** "Always show the baseline and candidate side by side, but create an **Explanatory Diff** only when requested and treat it as pass or fail only under a documented project threshold."
> **Developer:** "Which browser session should version 1 use?"
> **Domain expert:** "Use a **Task-scoped Browser Profile** in the **Isolated Test Browser**, never the captain's ordinary signed-in session, and discard the profile when the task finishes."
> **Developer:** "Should the after capture reuse browser state changed during the before capture?"
> **Domain expert:** "No, use separate browser contexts with equivalent safe test-state seeds, require independently isolated server-side synthetic fixture namespaces for asynchronous scenarios or whenever quiescence cannot be guaranteed, and otherwise use a scenario-declared **Deterministic Capture Reset**."
> **Developer:** "May Visual Evidence copy the current production environment to seed those contexts?"
> **Domain expert:** "No, use a **Synthetic Test Fixture** or clean anonymous state, and report when neither can evidence the required scenario."
> **Developer:** "May a historical screenshot serve as the before image?"
> **Domain expert:** "It may provide context, but it cannot be labeled as a **Verified Baseline** because that requires successfully running and equivalently capturing the exact **Baseline Revision**."
> **Developer:** "What happens if the baseline cannot run?"
> **Domain expert:** "Fail when before-and-after proof is required, or otherwise produce **After-only Evidence** that records why the baseline was unavailable and makes no comparison claim."
> **Developer:** "The **Privacy Review** flagged an email address, so may this exact bundle be published?"
> **Domain expert:** "Not until the captain resolves that **Privacy Finding** through explicit acceptance, a cropped or redacted derivative, or exclusion."
> **Developer:** "Does opening the **Evidence Review Surface** publish its bundle?"
> **Domain expert:** "No, it renders the exact bundle locally without uploading or publishing anything."
> **Developer:** "Does submitting a **Review Decision** perform the external action from the browser?"
> **Domain expert:** "No, it may grant **Evidence Import Consent** for the exact reviewed batch, but only no-mistakes may grant the later **Publication Approval** that authorizes pull request mutation."
> **Developer:** "The work is finished, so may its old **Private Outputs** expire automatically?"
> **Domain expert:** "No automatic expiry occurs, and **Evidence Cleanup Approval** moves only the exact previewed files to recoverable trash."
> **Developer:** "May Firstmate permanently delete those files afterward?"
> **Domain expert:** "Only after a separate explicit captain request names the exact files, because Firstmate never empties recoverable trash."
> **Developer:** "May I send this bundle to an anonymous upload site?"
> **Domain expert:** "No, version 1 supports only a user-chosen local export folder or an approved GitHub pull request through the active trusted host controller and no-mistakes' validated publication flow, where only no-mistakes grants **Publication Approval** or mutates the pull request."
> **Developer:** "May I add manual text to the PR description alongside the approved bundle?"
> **Domain expert:** "The **Managed PR Description** may be regenerated in full, so version 1 does not preserve manual author text there or publish evidence through a comment."
> **Developer:** "May this local **Evidence Import Consent** publish the previewed **Evidence Bundle** to PR #42?"
> **Domain expert:** "No, it only permits offering that exact batch and destination to no-mistakes for protected staging, revalidation, its own preview, and a separate **Publication Approval**."
> **Developer:** "May project JSON, configuration, `--yes`, or automatic approval grant either authority?"
> **Domain expert:** "No, none of those sources may grant **Evidence Import Consent** or **Publication Approval**."
> **Developer:** "Should **Approved Evidence Import** understand **Comparison Mode** or other **Visual Evidence** concepts?"
> **Domain expert:** "No, it validates producer-neutral evidence and approval inputs without Firstmate-specific behavior."
> **Developer:** "May version 1 ship after local export works but before approved pull request publication works?"
> **Domain expert:** "No, local export may be implemented and tested earlier, but **Visual Evidence v1 Readiness** requires no-mistakes **Approved Evidence Import** and both approved destinations to work end to end."

## Flagged ambiguities

- "private Firstmate workflow" was used to mean either a private skill implementation or private outputs - resolved: it means **Private Outputs**, while reusable skill implementations may be public.
- Whether `before-and-after` and `evidence-driven-testing` should be separate Firstmate skills was unresolved - resolved: they are capability inspirations for two modes owned by the single public **Visual Evidence** skill.
- Whether version 1 should capture browsers or native desktop surfaces was unresolved - resolved: version 1 is browser-first and supports only a **Browser Capture Scope**.
- Which operating systems version 1 supports was unresolved - resolved: version 1 officially supports only macOS and makes no Linux or Windows support claim.
- Whether version 1 should produce video or use operating-system-level recording was unresolved - resolved: version 1 produces no video and **Behavior Mode** uses sequenced screenshots, automated assertions, and timing notes within the browser-only boundary.
- Whether an existing signed-in browser session is prohibited or allowed as an exceptional fallback was unresolved - resolved: version 1 never accesses the captain's ordinary signed-in browser session.
- Whether the **Isolated Test Browser** profile is ephemeral per task or persistent was unresolved - resolved: each task uses a disposable **Task-scoped Browser Profile**.
- How baseline and changed-state captures isolate browser and server state within a **Task-scoped Browser Profile** was unresolved - resolved: **Comparison Mode** uses separate browser contexts with equivalent safe test-state seeds plus independently isolated server-side synthetic fixture namespaces or a **Deterministic Capture Reset**, with namespaces required for asynchronous or non-quiesceable scenarios.
- The source of the safe test-state seed for **Paired Capture Contexts** was unresolved - resolved: version 1 uses only a **Synthetic Test Fixture** or clean anonymous state.
- The outcome when a **Verified Baseline** cannot run was unresolved - resolved: required comparisons fail, while other tasks may produce reasoned **After-only Evidence**.
- The task outcome when expected visual evidence cannot be captured was unresolved - resolved: **Required Visual Evidence** blocks full validation, while unavailable **Supplemental Visual Evidence** is reported without failing automated validation.
- Who or what may classify expected visual evidence as **Required Visual Evidence** was unresolved - resolved: only the captain's request or documented project acceptance policy may establish that classification.
- Whether reusable **Evidence Scenarios** are tracked in project repositories or retained as private-only instructions was unresolved - resolved: projects track **Scenario Definitions**, while **Scenario Values** remain ignored local state.
- What happens when a worker discovers an unexpected visual impact after dispatch was unresolved - resolved: the worker reports it and Firstmate performs **Evidence Reclassification**.
- Whether approval, privacy-resolution, publication, and cleanup actions occur inside the **Evidence Review Surface** or in a trusted controller was unresolved - resolved: the surface submits a **Review Decision** to the active host controller, which is Firstmate in integrated use and the public skill's **Local Evidence Controller** in standalone use.
- The active host controller revalidates the decision, routes **Evidence Import Consent** to no-mistakes, and may perform approved local export or cleanup, while only no-mistakes may grant **Publication Approval** or mutate a pull request.
- Whether approved local export alone permits a version 1 release was unresolved - resolved: **Visual Evidence v1 Readiness** requires both approved destinations and **Approved Evidence Import**, and this coordinated dependency is central to the eventual architecture ADR.
- Whether **Approved Evidence Import** is generic or specific to **Visual Evidence** was unresolved - resolved: it is a narrow producer-neutral no-mistakes interface with no Firstmate-specific or **Visual Evidence**-specific behavior.
- Whether the local **Evidence Review Surface** directly authorizes pull request mutation was unresolved - resolved: it may grant only **Evidence Import Consent**, while no-mistakes owns the separate **Publication Approval** after protected staging, revalidation, and its own exact preview.
