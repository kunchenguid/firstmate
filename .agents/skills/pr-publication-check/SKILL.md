---
name: pr-publication-check
description: >-
  Agent-only lifecycle owner for complete reviewer-facing PR intent, privacy-safe published evidence, exact public body/head attestation, and the pre-monitoring publication gate.
  Load before composing promotion or successor ship instructions, before accepting a PR-ready signal, and before calling fm-pr-check or fm-pr-merge.
user-invocable: false
metadata:
  internal: true
---

# PR publication check

This skill is the lifecycle owner for PR publication readiness.
`bin/fm-pr-publication-check.sh --help` owns exact commands, flags, receipt fields, and forge mechanics.

## Separate the two intents

Operational validation intent tells a worker or validation system how to perform the current task, including recovery state, bounded runs, exclusions, and execution constraints.
Publishable PR intent tells a reviewer the complete base-to-head problem, intended outcome, implementation result, final validation, risks, and remaining limits.
Never publish operational framing as PR intent, including successor or current runs, the latest commit, this round, a recovered branch, or internal authorization.

Initial ship briefs contain this distinction and the publication trigger.
Any promotion or successor instruction must preserve it explicitly because the new instruction may otherwise replace the original publication context with current-run context.
Do not inject a captain preference file, private fleet record, worker transcript, or internal task data into a project prompt or PR body.

## Responsible worker attestation

The task worker that owns the selected delivery path remains the publication and correction owner.
Every PR or MR is created as a draft.
After every draft create or body update, that worker reads the complete public PR or MR body and judges whether its Intent and outcome describe the whole PR rather than an operational slice.
Regex and structural checks reject known hazards but cannot prove semantic completeness, so the worker must explicitly pass `--intent-outcome-complete` against the fresh fetched body and head.

The worker must choose exactly one evidence declaration.

- Use `--evidence none-required` when the accepted project contract does not require published artifacts, including ordinary nonvisual work where tests and documentation are sufficient.
- Use `--evidence nonvisual --evidence-url <url>` for required logs, reports, or other nonvisual artifacts.
- Use `--evidence real-ui --evidence-url <url>` only for evidence showing the real UI behavior, never a custom illustration, concept, or mockup.

Every declared evidence URL must already appear in the fetched public body, resolve through the same repository or forge as an actual file/blob rather than a directory, and bind to the exact PR head.
GitLab reviewer URL paths are percent-decoded exactly once before the actual repository path is encoded exactly once for the repository-file API; malformed paths and decoded paths that still contain an escape are refused.
The worker remains responsible for deciding whether evidence is required and whether the artifact proves the claimed behavior under the accepted project contract.
Do not force screenshots when the accepted contract does not require visual evidence.

Run the attestation from the task environment, where `FM_HOME` identifies the primary or secondmate home that owns the task.

```sh
"$FM_ROOT/bin/fm-pr-publication-check.sh" attest <task-id> <full-pr-url> \
  --intent-outcome-complete \
  --evidence none-required
```

Use one `--evidence-url` flag per required published artifact when the evidence mode is `nonvisual` or `real-ui`.
Attestation accepts only a draft, writes the exact-body/head receipt, and then marks the unchanged PR or MR ready through `gh-axi pr ready` or `glab mr update --ready`.
Only after that transition and its fresh readback succeed may the worker append the mode-specific PR-ready status.

## Correction and monitoring

A failed check never edits or normalizes the PR body, and any failure before the ready transition leaves the draft unchanged.
If fresh readback after the ready transition fails, the gate removes the invalid receipt and attempts draft rollback; a rollback failure reports both errors and explicitly warns that the change may remain reviewable without a valid receipt.
The responsible worker corrects the body through the selected delivery path, reads the complete public result again, and reruns `attest` against fresh bytes.
After a ready PR or MR drifts, that worker first returns it to draft through the forge's supported mechanism, then corrects and re-attests it.
For a no-mistakes task, the worker follows the active no-mistakes help and ownership flow rather than hand-editing around the pipeline; if that flow offers no supported correction, the worker reports the exact blocker.

Firstmate runs `bin/fm-pr-check.sh <task-id> <full-pr-url>` after the worker's ready status.
That command performs a second authenticated full-body/head readback, repeats deterministic privacy and evidence checks, requires the exact private attestation receipt, records canonical PR identity and head, and only then publishes ordinary merge monitoring.
Every ordinary merge poll re-runs that verification first; body, head, receipt, policy, or evidence drift produces a `publication-invalid` wake instead of a merged outcome and returns correction ownership to the same task worker.
Tool absence, forge read failure, malformed forge response, invalid local state, timeout, or an invalid machine result instead produces a bounded `publication-verification-error:<class>:exit-<status>` wake and remains Firstmate operational work rather than being assigned to the delivery worker.
Missing, malformed, or mismatched publication content remains `publication-invalid`, while receipt safety, state-device, and private temporary-file failures remain `state-invalid`.

The private receipt records only the canonical forge identity, exact head, body byte count and SHA-256, privacy/link/attestation verdicts, evidence mode, and the already-public evidence URLs encoded as data.
Never copy that receipt or other private task evidence into the PR.
