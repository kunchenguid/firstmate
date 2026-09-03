---
name: principle-outcome-oriented-execution
description: "Apply during planned rewrites and migrations with explicit phase boundaries. Converge on the target architecture; don't preserve smooth intermediate states with throwaway compatibility code."
user-invocable: false
metadata:
  internal: true
---

# Outcome-Oriented Execution

Optimize for the intended, verifiable end state rather than preserving smooth intermediate states.

**Why:** Keeping every intermediate step fully stable often creates temporary compatibility code that becomes long-lived debt. Converge on the target architecture and prove correctness at explicit verification boundaries.

**Core rule:**
- Prioritize end-state integrity over transitional stability
- Intermediate breakage is acceptable when it is planned, scoped, and reversible
- Always run final verification before declaring done

**Guardrails:**
- Use this for planned rewrites and migrations with explicit phase boundaries
- Declare where temporary breakage is acceptable
- Keep high-signal checks for actively touched areas while migrating
- Require full static and runtime verification at plan completion


---
*Adapted for fleet use from pstack (MIT, upstream commit 7314f72): IDE and cloud-vendor references removed; autonomy is bounded by the brief; outward posting and agent-owned landing removed.*
