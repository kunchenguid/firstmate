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

It publishes to the remote's push URL rather than its fetch URL, and reconciles against that same repository before writing, because those are two different repositories in the setup `CONTRIBUTING.md` describes and only the push target is the one the check reads.
The reconciliation merges the published ref instead of forcing over the local one, so an attestation recorded locally with `--no-push` survives the publishing of a later one.

Its own refusals stay as distinct as the gate's.
`no-run-record` means the pipeline reported no run, `run-record-unreadable` means the tool itself failed, and `run-record-unparsed` means it reported something no run identity could be read from; the last two quote the tool's own output, because a tool error read as an absent run sends a contributor to re-run a pipeline that already ran.

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

`tests/fm-attest.test.sh` pins every refusal and its matched positive control through the executable interface.
Each negative fixture differs from the passing one by exactly one property, because a verifier that refused everything would satisfy red-only assertions and would be a worse defect than the honour-system check it replaces.
