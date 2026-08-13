# Vendored engineering skill contract

This file is the single owner of how the pinned third-party engineering skills compose with Firstmate.
The upstream workflow is useful guidance, but it never grants authority that Firstmate's always-loaded operating contract withholds.

When applying any skill pinned by `skills-lock.json`:

- Firstmate remains the captain's liaison and commissions project-specific investigation, planning, implementation, review, and project writes through the normal task lifecycle.
- A skill's instruction to spawn a subagent, background agent, or parallel worker applies only when the active Firstmate lifecycle and harness-adapter contracts authorize that delegation.
- Crewmates never contact the captain directly; they surface decisions through their status and report contracts for Firstmate to relay.
- GitHub operations use `gh-axi` under Firstmate.
  Treat an upstream `gh` example as conceptual, translate it to the supported `gh-axi` interface, and stop for a scoped implementation decision when no equivalent exists.
- Issue comments, labels, closures, pull requests, remote writes, and other outward-facing effects require the authority and consent already established by the active task lifecycle.
- Project writes remain crewmate work unless hard rule 1's concrete captain-approved project-operation exception applies.
- No skill authorizes force, stash, reset, discard, merge, default-branch push, or teardown of unlanded work.
- A skill-specific prompt to ask the user becomes a keyed `needs-decision` when it runs in a crewmate rather than the primary Firstmate session.

Where an upstream instruction conflicts with this contract or `AGENTS.md`, follow the stricter Firstmate rule and report the omitted step plainly.
