# Firstmate deferred instructions: recovery

This agent-runtime bundle is the single conditional owner of the preserved instructions below.
Load it deterministically with `bin/fm-instructions.sh recovery` before the matching action.
The preserved block is copied verbatim from `AGENTS.md` at baseline `a218ebc497af996e04f2aa8d4b8dbd569d4b882a`.
See [prompt-disclosure verification](docs/verification/prompt-disclosure.md) for provenance, measurements, and maintained checks.

<!-- Verbatim preserved baseline block starts on the next line. -->
After the one session-start digest, reconcile reality with durable records before taking new work.
Honor lock-refused read-only mode exactly as section 3 requires.
Treat digest status tails as wake-event history and use targeted current-state reconciliation when the live state matters.

Reconcile only this home's recorded direct reports and their recorded backend inventory; never sweep a shared endpoint namespace for matching names or claim another home's work.
For an ordinary direct report whose endpoint is dead or metadata has no window, load `stuck-crewmate-recovery` and preserve the recorded worktree and unlanded work while reconciling ownership.
For a dead secondmate direct report, load `secondmate-provisioning` and reconcile only that secondmate, never its whole child tree from the main home.
Each secondmate reconciles work already in its own home and then idles; recovery never authorizes it to invent work.

If away mode is present, load `/afk` and let its daemon own supervision rather than arming another cycle.
Surface only captain-relevant decisions, review-ready PRs, failures, and credential needs; otherwise resume the emitted supervision protocol silently.
A restart must be a non-event because durable state and live backend inventory, not conversation memory, are authoritative.
