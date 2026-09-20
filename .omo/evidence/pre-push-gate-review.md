# Gate review: base 1bb72cc5 to target 466e0d661

- recommendation: REJECT
- originalIntent: Ship the complete base-to-target change set, including a usable self-hosted Discord connector and reliable cleanup of inactive terminal crew endpoints, without regressing the existing Firstmate lifecycle.
- desiredOutcome: Configuring the Discord token safely arms polling and accepts only authorized captain input; advertised DM behavior works; replies do not leak resources; inactive terminal endpoints are reaped through the correct backend identity.
- userOutcomeReview: The inactive-reaper path is coherent after the expected-label and Zellij-tab fix rounds. The Discord connector remains unsafe and can falsely report activation.

## Blockers

1. violatedCriterion: C-DISCORD-TRUST (self-hosted connector must preserve the trusted captain/request boundary)
   evidencePointer: `bin/fm-discord-poll.js:103-179`; `docs/configuration.md:674-677`
   observation: Every non-bot author who mentions the bot in a discovered or configured channel is converted directly into an actionable `x-inbox` request. No owner/user allowlist exists.
2. violatedCriterion: C-DISCORD-ACTIVATION (token-enabled bootstrap must actually arm the documented poller/cadence or report failure)
   evidencePointer: `bin/fm-bootstrap.sh:1165-1175`
   observation: Both private artifact publication failures are discarded with `|| true`, then bootstrap unconditionally reports that polling and 30-second cadence are armed.
3. violatedCriterion: C-DISCORD-DM (documented `FM_DISCORD_ALLOW_DMS` behavior must be reachable)
   evidencePointer: `bin/fm-discord-poll.js:66-85,103-108`; `docs/configuration.md:674-677`
   observation: Automatic discovery enumerates only guilds and guild channels. A DM can be processed only when its channel id is already supplied manually, a prerequisite the documented default does not state.

## Notes

- `bin/fm-x-reply.sh:101-113,313-326`: the self-hosted branch uses `exec`, so its EXIT cleanup trap does not remove the generated payload temp file. This is a reachable per-reply temp leak, but not independently tied to a stated success criterion.
- Direct remove-ai-slops/programming pass: tests exercise the production poller rather than a deletion-only/tautological duplicate. Coverage does not exercise author authorization, artifact-publication failure, DM discovery, Zellij fallback, or cmux expected-label dispatch.
- No code-review report, executor evidence directory, manual QA matrix, or notepad path was present in the supplied worktree/request. These are evidence gaps, not blockers because the user explicitly prohibited running validation and did not make those artifacts acceptance criteria.
- Validation/tests were not run, per user instruction.

## Checked artifacts

- Full `1bb72cc5f88014c86e3d03244efa0bb26c22d001..466e0d66175d2c98e1b345e682be8255152a4310` name/status/stat and commit history
- Discord source, bootstrap, routing callers, tests, and configuration docs
- Inactive reconcile source, backend validation/kill dispatch, adapters, tests, and fix-round commits `03bf275`, `e10c85c`, `466e0d6`
- Direct `remove-ai-slops`, `programming`, TypeScript/Python, and git-history review criteria

