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

Git notes do not travel with `refs/pull/*`, so the workflow fetches the ref from the repository the branch was pushed to: the base repository through the job's own token, or a fork anonymously.
A read that fails for any reason other than "the ref is not there" stops the job, so an unreachable head repository is never resolved as either an absent or a present attestation.

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

Each failure reports its own reason: `no-attestation-ref`, `no-attestation-for-head`, `head-commit-unavailable`, `attestation-malformed`, `attestation-not-bound`, or `attestation-missing-gate`.
Keeping them distinct is the point rather than a convenience.
An absent attestation and a rejected one need different repairs, and neither may be reported as a pass.

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

`bin/fm-attest.sh write` reads the pipeline's own run record through `no-mistakes axi status`, refuses unless that run covers this exact `HEAD` on this branch and completed every required step, then records and pushes the note.
It re-verifies its own payload with the same code path the gate uses, so a malformed note cannot reach the forge and be discovered only in CI.

When `no-mistakes` publishes this note itself, the helper becomes redundant and nothing about the check changes: the note format is the contract, and which program writes it is not.

## Landing an already-validated change on a fork

A fork's landing branch carries work that was validated upstream, but its commits are new, so an attestation for the upstream head does not cover them; the check refuses it, correctly.

Because the attestation is bound to a commit rather than written into a pull request body, that branch can be validated in its own right without proposing anything upstream.
Run the pipeline against the landing branch with the pull request and CI steps skipped, then attest the head it validated.
That is what separates the signature from upstream submission: previously the only way to obtain the marker was to open an upstream pull request, so a landing branch could not be signed without duplicating a live contribution.

## Verification

`tests/fm-attest.test.sh` pins every refusal and its matched positive control through the executable interface.
Each negative fixture differs from the passing one by exactly one property, because a verifier that refused everything would satisfy red-only assertions and would be a worse defect than the honour-system check it replaces.
