# The no-mistakes attestation

`.github/workflows/no-mistakes-required.yml` is the `Require no-mistakes` check on pull requests targeting `main`.
This document owns what that check establishes, what it deliberately does not, and the format it verifies.
`bin/fm-attest.sh` owns the exact commands and flags.

## What the check reads

The check verifies a git note on `refs/notes/no-mistakes`, keyed by the pull request's exact head commit.

A note is used rather than a commit trailer or a line of pull request prose for three reasons.
It is keyed by a commit sha, so it can name the commit it covers without changing that commit's sha.
It never rewrites the branch, so producing one cannot disturb the pipeline's custody of it.
It reaches the forge as an ordinary ref, so a `pull_request` workflow can read it with `contents: read` and nothing more.

Git notes do not travel with `refs/pull/*`, so the workflow fetches the ref from the repository the branch was pushed to.
The base repository is read through an explicit token URL and a fork through its plain `https` URL, which still carries the job's token because `actions/checkout` persists it in the workspace's git configuration.
Neither read is anonymous; both are read-only and both go to the host that issued the token.
A read that fails for any reason other than "the ref is not there" stops the job, so an unreachable head repository is never resolved as either an absent or a present attestation.
Both remote calls are made with their output suppressed and are reported by the head repository's name, because when the head repository is the base repository the URL carries the job token and git quotes the whole remote URL back in its own http errors.
Actions redacts that token from logs, which makes the suppression defence in depth rather than the only thing between the token and the log, and is the reason to keep the two calls consistent rather than to let one of them rely on it.

The workflow reads the verifier's exit status rather than only its success, because `bin/fm-attest.sh` separates a refusal from a failure and collapsing the two would have the check report evidence it never examined as absent evidence.
Exit 1 is a verdict and is reported as no attestation for this head.
Any other non-zero exit reached no verdict, and is reported as the check being unable to evaluate this head, naming the status and the causes that reach it: a head that predates this check, or one where `bin/fm-attest.sh` is missing or has lost its executable bit.
Both outcomes fail the check, because a check that could not look must never report a pass; what differs is what the contributor is sent to repair.

## The format

```
no-mistakes-attestation: v1
head: <the 40-character lowercase sha of the commit this attests>
run: <the pipeline run identity that validated it>
gates: <comma-separated pipeline steps that completed for that head>
tool: <the pipeline binary and version that ran them>
```

`bin/fm-attest.sh --print-format` prints this from the implementation, so the two cannot drift.

A `v1` note is accepted only when every field is present and well formed, `head` equals the commit the note is attached to, and `gates` records a completed `review`, `test`, `lint` and `push`.
An unrecognized field is refused rather than ignored, so a later format can never be read as a weaker `v1` one.

Each failure reports its own reason: `no-attestation-ref`, `attestation-ref-unreadable`, `no-attestation-for-head`, `head-commit-unavailable`, `attestation-malformed`, `attestation-not-bound`, or `attestation-missing-gate`.
Keeping them distinct is the point rather than a convenience.
An absent attestation and a rejected one need different repairs, and neither may be reported as a pass.
`attestation-ref-unreadable` is the ref resolving but not readable as notes, such as one pointing at a blob; it is kept apart from `no-attestation-for-head` because publishing another note can never repair a damaged ref.

## The error model

`bin/fm-attest.sh` exits three ways, and the difference between them is the contract rather than an implementation detail.

A **refusal** exits 1 and prints `not attested (<reason>)`.
The evidence was examined and found absent, unbound or invalid, so this is a verdict.
`verify` refuses with the seven reasons above.
`write` refuses with `no-run-record`, `run-record-unreadable`, `run-record-unparsed`, `run-record-no-head`, `run-covers-another-branch`, `run-head-unavailable`, `run-covers-another-head` or `run-incomplete`.

A **failure** exits 2 and prints `cannot attest (<reason>)`.
No verdict was reached, so it says nothing about the evidence either way: `not-a-git-repository`, `pipeline-tool-missing`, `head-unresolvable`, `head-detached`, `scratch-file-unavailable`, `push-target-unreadable`, `push-target-unfetchable`, `attestation-not-reconciled`, `attestation-not-recorded`, `attestation-not-published`, or `commit-unknown` for `show`.

A **usage error** exits 2 and names the argument in plain words, because there is no state to describe.

No condition borrows another's reason or another's words.
That rule is the one this component has had to relearn most often: an unreadable record reported as head divergence, or a missing utility reported as a tool exit, sends a reader to repair something that was never broken and to hit the identical message again.

## What it attests

That some pipeline run completed review, test, lint and push against **this exact commit**, and recorded which run and which tool version did it.

The binding is the property that matters.
An attestation cannot be copied from another pull request, cannot survive a rebase, an amend or a force-push, and cannot be produced before the commit it names exists.
Every new head needs its own.

## What it does not attest

**Who ran the pipeline.**
`no-mistakes` runs on the contributor's machine using the contributor's own credentials, so no artifact it emits can be unforgeable by the person running it: anything the pipeline can write, its operator can write.
Closing that gap needs an issuer the pull request author does not control, such as a check run posted by a GitHub App the base repository installs, and that is a change to the pipeline's architecture rather than to this check.
What this check removes is the far weaker property it replaced, where the evidence was a fixed string in the mutable pull request body that anyone could type once and paste anywhere.

**That the change is good.**
`.github/workflows/ci.yml` owns tests, lint and platform coverage on the same head.
This check is a provenance gate, not a quality one, and a passing attestation on a red pull request is still a red pull request.

**That the workflow itself was not edited.**
On `pull_request`, GitHub runs the workflow and scripts from the pull request's own head, so a pull request may change the gate that examines it.
That was equally true of the body-string check this replaces and is a property of the event, not of this design.
It is why the check's verdict is visible in the diff and why required-check configuration is a repository setting rather than something a workflow can assert about itself.

## Producing one

`bin/fm-attest.sh write` reads the pipeline's own run record through `no-mistakes axi status`, refuses unless that run covers this branch and completed every required step, then records and pushes the note on the head that run validated.
It re-verifies its own payload with the same code path the gate uses, so a malformed note cannot reach the forge and be discovered only in CI.

The head it attests is not always `HEAD`.
The pipeline commits its own fixes and advances the run tip past the local checkout, so a run tip ahead of `HEAD` on the same history is the normal state, it is the head the pull request is opened on, and it is what gets attested.
A run tip behind or beside `HEAD` is refused as `run-covers-another-head`, because this branch then carries work that run never saw or its tip was rewritten.
A run tip that is not a commit in this checkout at all is refused separately as `run-head-unavailable`, because that is a fetch rather than a re-validation.
`bin/fm-nm-run-lib.sh` owns that directional rule for every caller that has to decide whether a run belongs to a worktree, and owns reading this tool's output; both are read from there rather than re-derived here, so a change to the tool's shape moves every reader at once.

It publishes to the remote's push URL rather than its fetch URL, and reconciles against that same repository before writing, because those are two different repositories in the setup `CONTRIBUTING.md` describes and only the push target is the one the check reads.
The reconciliation merges the published ref instead of forcing over the local one, so an attestation recorded locally with `--no-push` survives the publishing of a later one.
It names that repository in what it prints, because "published to origin" does not say which repository was reached and the note is evidence only on the one holding the pull request head.
A push target carrying no `refs/notes/no-mistakes` yet has nothing to reconcile against and is not an error, but a push target that cannot be read at all stops the command before anything is recorded: not reading a repository is not reading an absence, and that is the same line the gate draws when it fetches this ref.

git's own text is made safe to print rather than withheld wholesale when a remote call fails.
git quotes the push URL back in its messages and a credential in a log is a leak wherever that log ends up, but suppressing the text throws away the server's rejection reason with it, and a contributor blocked by a ruleset on `refs/notes/*`, a required-signature policy or a quota then has nothing to act on.
Making it safe is default deny, and that inversion is the safety property rather than a detail of it: a word that could carry a credential is emitted only when it positively matches a shape with no place for one, and a line holding anything withheld is withheld entire rather than shown in part.
Redacting what a reader recognises instead emits intact every shape it failed to model, which reads absence of detection as absence of a credential, and that is how credentials reached a log before the inversion.
This covers everything the command prints, git's output and the pipeline tool's two streams alike, so a refusal added later is safe because printing is what makes it safe.
`bin/fm-attest.sh`'s header comment is the single owner of the mechanism: the shapes that are modelled, why each guard is a rule rather than an implication of its pattern, the cost of withholding by line, and why one function is the only path text leaves the command by.

Its own refusals stay as distinct as the gate's.
`no-run-record` means the pipeline reported no run, `run-record-unreadable` means the tool itself failed, `run-record-unparsed` means it reported something no run identity could be read from, and `run-record-no-head` means it reported a run naming no usable head commit; all four quote the tool's own output, because a tool error read as an absent run sends a contributor to re-run a pipeline that already ran.
That output is quoted through the same scrubbing as git's, because `no-mistakes` manages pushes and its error output can therefore carry a remote URL with a credential in it.
Only what the tool writes to stdout decides which of them it is, because unrelated notices such as its version-upgrade banner go to stderr and must never stand in for a run record; stderr is quoted alongside stdout purely as diagnostic detail.
Every call to the tool is time-bounded, so one blocked on a lock or a network read refuses as `run-record-unreadable` rather than hanging at a contributor's terminal.
`bin/fm-timeout-lib.sh` owns imposing that bound, and `bin/fm-nm-run-lib.sh` delegates to it rather than carrying a second copy of the mechanism.
`docs/configuration.md` owns the `FM_ATTEST_NM_TIMEOUT` knob, including why a non-positive value falls back to the default rather than shortening the bound.

When `no-mistakes` publishes this note itself, the helper becomes redundant and nothing about the check changes: the note format is the contract, and which program writes it is not.

## Re-evaluating a head after the note is published

The note can only exist after the push it attests, and that push is what started the check, so the first evaluation of a genuinely pipeline-raised head runs before its evidence exists and correctly refuses.

Publishing the note does not by itself repair that verdict.
`refs/notes/no-mistakes` is not a pull request head, so pushing it fires no `pull_request` event and nothing re-reads the head.
Close and reopen the pull request, or edit its title or body: `reopened` and `edited` are both subscribed for exactly this, and because the verdict is bound to the head commit, re-running against an unchanged head simply re-derives it from the evidence now present.

This is why `edited` is subscribed even though the verdict no longer depends on any pull request text.
It is also the only event GitHub fires when a pull request's base branch changes, so without it a pull request retargeted onto `main` would never run this check at all.

## Landing an already-validated change on a fork

A fork's landing branch carries work that was validated upstream, but its commits are new, so an attestation for the upstream head does not cover them; the check refuses it, correctly.

Because the attestation is bound to a commit rather than written into a pull request body, that branch can be validated in its own right without proposing anything upstream.
Run the pipeline against the landing branch with the pull request and CI steps skipped, then attest the head it validated.
That is what separates the signature from upstream submission: previously the only way to obtain the marker was to open an upstream pull request, so a landing branch could not be signed without duplicating a live contribution.

## Verification

`tests/fm-attest.test.sh` pins every refusal and its matched positive control through the executable interface, for `bin/fm-attest.sh` and for the workflow's own step scripts, which it lifts out of the workflow by step name and runs as the workflow runs them.
The two live in one suite because what the check tells a contributor is decided jointly by the verifier's exit status and the step's reading of it, and splitting them lets the two drift apart.
Each negative fixture differs from the passing one by exactly one property, because a verifier that refused everything would satisfy red-only assertions and would be a worse defect than the honour-system check it replaces.
