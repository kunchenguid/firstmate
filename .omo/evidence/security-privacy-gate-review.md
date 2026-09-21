# Security and privacy gate review

- recommendation: REJECT
- originalIntent: Review the branch range `1bb72cc5f88014c86e3d03244efa0bb26c22d001..e9e9ec8e772fcc588d59ca751e9441a49d147d5e` for reachable auth, secret, protected-data, command/path, or disclosure defects in the Jev, Discord relay, wake/state, and external-command boundaries.
- desiredOutcome: Only the operator/captain can supply authority-bearing Discord instructions; Jev and persisted state do not disclose protected data; external command paths cannot be redirected or injected.
- userOutcomeReview: The self-hosted Discord path violates its downstream owner-only trust contract. With no channel allowlist configured, the poller enumerates accessible guild channels and DMs, accepts any non-bot author who mentions or DMs the bot, and emits the same `x-mention` payload consumed by `fmx-respond`. That consumer explicitly treats every direct author as the captain and autonomously performs normal lifecycle work. No author-id or role check exists in the introduced poller.

## Blockers

1. violatedCriterion: SEC-AUTH-1 — identify an exact reachable authorization bypass and consequence
   - severity: HIGH
   - evidencePointer: `bin/fm-discord-poll.js:66-98,116-149,182-192`; `.agents/skills/fmx-respond/SKILL.md:26-44,70-80`; `docs/configuration.md:689-699`
   - observation: Any Discord user able to DM the bot or mention it in an accessible channel is converted into a captain-authorized request. The default configuration scans guild channels and enables DMs, while the poller checks only `author.bot`, mention/DM status, and channel exclusion. The shared response skill then treats the direct author as the captain and may file work, dispatch agents, investigate, or ship gated changes.
   - bypass: Send a DM to the bot, or mention it in any channel visible to the bot, without being the operator/captain.
   - consequence: An untrusted Discord user gains authority to trigger autonomous replies and normal reversible lifecycle actions on the operator's machine; the system may also expose public-safe operational outcomes to that user.

## Notes

- Jev: tracked `.no-mistakes.yaml` sets `jev.review_assist`, but the branch documentation states this key is global-only and ignored from repository config. No reachable new Jev disclosure path was established from this repository change.
- Wake/state and external command paths: no additional source-backed security or privacy finding was established in the reviewed changes.
- remove-ai-slops/programming direct pass: The Discord boundary uses no author authentication and relies on a downstream hosted-Relay invariant that the self-hosted adapter does not establish. Tests cover channel selection, DM defaults, and delivery, but do not prove an owner identity boundary. No slop-only concern is promoted as a blocker.

## Checked artifacts

- Diff and history: `1bb72cc5f88014c86e3d03244efa0bb26c22d001..e9e9ec8e772fcc588d59ca751e9441a49d147d5e`, especially commits `5879ec3` and `6f2a79b`
- Source: `bin/fm-discord-{lib,poll,reply}.{sh,js}`, `bin/fm-{bootstrap,watch,x-reply,x-dismiss,spawn,control,crew-state,wake-lib,session-lock-lib}.sh`, `.pi/extensions/*.ts`
- Policy/call contract: `.agents/skills/fmx-respond/SKILL.md`, `AGENTS.md`, `docs/configuration.md`
- Tests read: `tests/fm-discord-selfhosted.test.sh`, relevant `tests/fm-x-mode.test.sh` request-id and reply cases
- Existing evidence read: `.omo/evidence/*gate-review*.md`

## Exact evidence gaps

- Tests were not run, as explicitly prohibited by the assignment.
- No live Discord API call was made. Reachability is established from the poller's source and the downstream instruction contract.
- No ulw-loop plan exists; `omo ulw-loop status --json` returned `ULW_LOOP_PLAN_MISSING`, so this fallback report path is used.
