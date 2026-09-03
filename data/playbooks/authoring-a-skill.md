### Authoring or modifying a skill

**You own the skill's voice.** Agent-facing prose has a higher bar than human prose; unhelpful sentences become instructions.

1. Scaffold the skill: a `SKILL.md` with `name` and `description` frontmatter, clear trigger conditions, and concrete steps.
2. Validate the skill: frontmatter has `name` and `description`, referenced files exist, cross-skill links resolve.
3. Test cases if structural; skip if subjective.
4. Run **opening-a-pr**. Hand the skill to the supervisor through the normal delivery path; landing follows merge authority.

When in doubt, delete; prose earns its keep by changing a decision. Tell it to do the thing and skip the reason. Explain only when the rule is confusing without one. Match tone to scope. Point at structural sources (types, READMEs, config); hardcoded details go stale (the **encode-lessons-in-structure** principle skill). Delegate to other skills by path; don't restate. A workflow you keep hitting but isn't captured → propose a new skill.

**Reply:** summary of the skill, key design decisions, validation notes.


---
*Adapted for fleet use from pstack (MIT, upstream commit 7314f72): IDE and cloud-vendor references removed; autonomy is bounded by the brief; outward posting and agent-owned landing removed.*
