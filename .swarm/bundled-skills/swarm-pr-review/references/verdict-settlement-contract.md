# Verdict settlement contract

Reviewer and critic settlement composes across batches, item by item. A phase
settles once every review item in the current mechanically assigned inventory
holds a successful verdict, whether that coverage comes from one batch or from
several complementary partial retries. A later degraded, truncated, stale,
wrong-identity, or malformed batch never supplies a verdict for the items it
touches, but it does not discard verdicts other batches already supplied for
different items.

When more than one successful batch covers the same item, the most recent
successful batch wins that item. This conflict rule is one shared computation,
so settlement and every downstream verdict use—candidate inventory, critic
routing, and final synthesis—never disagree about which claim is authoritative
for an item. A batch contributes only the items it was validated for against
the exact candidate inventory current at validation time. Partial batches are
first-class inputs, not an error state. Legacy artifacts that predate exact
item binding remain all-or-nothing and MUST validate against their complete
recorded inventory before they contribute any claim.

Collection validates every dispatched reviewer or critic lane against the exact
assigned verdict rows and records lane-atomic accepted and rejected IDs before
settlement. A malformed, missing, or surplus row never silently upgrades the
lane: the lane accepts every assigned ID only when the complete assigned row set
is valid; otherwise it rejects every assigned ID for precise re-dispatch. The
lane report MUST disclose both sets.

A critic claim binds per item to the exact reviewer row it was validated
against, not to the reviewer batch as a whole. A reviewer retry that reproduces
a byte-identical row for an item retains that item's critic work. A reviewer row
that changes at all—even one field—invalidates only that item's critic claim,
not the whole critic wave. Critic batches recorded before per-item binding
existed keep the legacy behavior: any newer reviewer batch invalidates them
wholesale. Dispatch a fresh critic wave to cover whatever items composition
leaves unclaimed. Critic evidence can never predate the reviewer evidence it
purports to challenge.

Settlement is item completeness, not lane completeness. A declared lane that
never completes produces a diagnostic naming the abandoned lane, not an
automatic block, as long as every item in the inventory already holds a
successful verdict from some lane.
