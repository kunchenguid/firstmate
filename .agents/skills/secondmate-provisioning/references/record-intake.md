# Record intake for an existing or inherited domain

Classify the domain before seeding, because this step applies to only one of the two cases.
A greenfield domain has no delivered domain work yet: nothing already shipped in its projects, no live deployment, and no predecessor records to import.
Seed a greenfield domain normally; there is nothing to reconcile and this section adds no work to it.
An existing or inherited domain is any domain whose product is already in development, and any predecessor's domain a new mate takes over, including a consolidation after a retirement.
Both of those cases require record intake before the new mate acts on any inherited plan.

For an existing or inherited domain, the creating agent must:

1. Reconcile every inherited plan against the domain's authoritative shipped state, which is `origin/main` for each relevant project plus the live deployment.
   A fetched clone of each relevant project is a precondition of that reconciliation, so wire the home to its projects before reconciling rather than on first task.
   The imported backlog, the predecessor's own notes, instruction-surface prose, and an absent or unfetched local view are all inadmissible as shipped-state evidence.
2. Seed the new home with only genuinely open work plus the domain's durable knowledge, meaning the learnings, decisions, and delivery posture that are still live.
3. Never inherit a plan backlog blind.
   A plan row whose work is already shipped is dropped, or recorded as done with the merged evidence that settles it, and is never carried forward as open.

A live backlog keeps only the configured recent Done entries by design, so an inherited queue structurally over-represents plans and under-represents deliveries.
Treat an inherited queue that carries plans with no matching delivery record as unreconciled rather than as open work, and record whatever could not be reconciled as an explicit residual-uncertainty list in the new home rather than leaving that gap silent.
