---
name: decision-brief
description: >-
  Produce a reconciled executive brief of every current Captain's Call or other action requiring the captain's input.
  Use when the captain invokes /decision-brief or asks for a breakdown, executive brief, background, or decision analysis of all current Captain's Calls or decisions requiring their input.
user-invocable: true
metadata:
  internal: true
---

# decision-brief

Give the captain a self-contained executive explanation of every current unresolved decision or action that requires their input.
Write for a high-level executive audience that needs business context, realistic choices, consequences, and copyable approval language rather than implementation detail.
This skill is read-only unless the captain explicitly asks for a file or durable report.
It never approves a choice, merges a PR, dispatches or steers work, changes a decision record, resets a credential, performs an interactive login, or otherwise mutates fleet or project state.

## Reconcile the current decision set

Do not draft from conversation memory, a previous brief, report prose alone, or the latest event line.
Build a fresh current inventory before writing.

1. Gather the complete read-only structured fleet snapshot across the main home and every registered secondmate home.
   Inspect every omission, truncation, unavailable home, and inventory contradiction, and use the snapshot helper's current `--help` rather than inventing another state parser.
2. Inventory every structured captain-actionable backlog item, every currently open keyed decision associated with live work, every PR that is currently ready and awaiting the captain's merge approval, every credential or interactive login currently needed, and every destructive, irreversible, security-sensitive, or operational action that current state assigns to the captain.
3. Inspect each candidate's full authoritative backlog record in its owning home and the current task state for any associated live work.
   Follow referenced investigation reports, decision records, review artifacts, and full PR URLs only as needed to explain context, history, options, and consequences.
   Never read a secondmate's chat or treat raw terminal text as authoritative state.
4. Reconcile event history against current structured state.
   Exclude resolved, declined, superseded, historical, not-yet-actionable, and duplicate requests.
   A durable captain decision remains current until its authoritative record is closed, while an event-only request is current only when the associated task's reconciled state still confirms that it needs the captain.
   Treat differently worded records as one duplicate only when they ask for the same answer and resolving either necessarily resolves the other.
5. Group related findings only when one captain answer genuinely resolves every grouped finding.
   Otherwise preserve them as separate decisions, even when they concern the same project or feature.
6. Account for every candidate before drafting so no current decision is omitted.
   If an authoritative home or record remains unavailable, disclose the exact coverage gap near the top and do not claim the brief is complete.
   Do not fill an evidence gap with assumptions.

## Classify the calls

Assign every included item one primary category and add cross-cutting labels only when they materially affect the choice.
Use these categories distinctly:

- **Product or policy choice** - changes customer value, market position, pricing, workflow, product behavior, or a standing business policy.
- **Engineering-risk choice** - accepts or reduces material architecture, reliability, maintainability, migration, or delivery risk without primarily redefining the product.
- **Credential or login action** - requires account access, authorization, a secret, or an authenticated interactive step.
- **Destructive or security-sensitive action** - can irreversibly remove or expose data, weaken safeguards, change trust boundaries, or materially affect privacy, compliance, or security.
- **Operational action** - requires the captain to approve a merge, coordinate timing, contact a party, perform a reversible administrative step, or clear another execution dependency.

When an item fits more than one category, choose the category that explains why the captain must own it and list the other material dimensions as labels.
Never downplay a destructive or security-sensitive aspect by presenting the item only as routine operations.

## Executive brief format

Start with `# Captain's Calls - <YYYY-MM-DD>` and a two- or three-sentence executive summary stating the number of current calls, the projects or suite areas affected, the most consequential choice, and any coverage limitation.
Then provide a compact action index grouped by the five categories above, including every call exactly once with its qualitative risk and recommended answer.
After the index, give every call its own numbered section using the following contract.

### Required content for every call

1. **Title** - a plain-language title that names the outcome at stake rather than the implementation symptom.
2. **Executive decision** - one sentence stating exactly what the captain is being asked to decide or do now.
3. **Business and product context** - explain where the subject fits in the product suite, which business capability or customer promise it supports, and why it matters now.
4. **Relevant history** - summarize how the situation arose, prior accepted goals or decisions that constrain it, and the evidence that brought it to the captain.
5. **Underlying problem** - state the real business, product, user, delivery, or risk problem rather than merely repeating a technical failure or tool message.
6. **Options** - include every realistic option and include defer or decline when either is meaningful.
   For each option, state its advantages, disadvantages, tradeoffs, dependencies, and what it leaves unresolved.
7. **Impact** - assess every relevant business, product, user, delivery, operational, privacy, compliance, security, cost, and schedule dimension.
   State `No material impact identified` for a named dimension only after checking it, rather than silently omitting the dimension.
8. **Risk if approved** - rate the downside of approving as **Low**, **Medium**, **High**, or **Critical**, explain the credible failure modes, and give practical mitigations.
9. **Risk if declined or deferred** - use the same rating scale, explain the opportunity cost or exposure that remains, and give practical mitigations.
10. **Recommendation** - name one specific option and tie it to accepted product goals, delivery priorities, and the captain's established risk posture.
    Separate evidence from judgment and state any assumption that could change the recommendation.
11. **Exact response** - provide concise language the captain can copy verbatim or answer with a short option label.
    Include any required scope, conditions, PR URL, or acknowledgment so the answer is operationally unambiguous.

Use **Low** for limited reversible downside, **Medium** for meaningful but contained downside, **High** for major customer, business, delivery, privacy, compliance, security, cost, or schedule harm, and **Critical** for existential, broadly irreversible, or severe safety or trust harm.
Rate consequence and likelihood together, and do not lower a rating merely because a mitigation exists.

## Language and evidence rules

Define every unavoidable technical term in plain language at first use.
Prefer the captain's product, customer, business, and project nouns over internal fleet terminology.
Translate worker and tool evidence into outcomes and consequences instead of quoting raw output, internal labels, or unexplained implementation jargon.
Preserve every PR as its full `https://...` URL, including inside copyable approval language when the PR is the subject of the action.
Never reveal a secret, token, credential value, or private customer data.
For a credential or login action, distinguish information firstmate can safely use from an authentication step that only the captain can perform.
State clearly when the captain must complete an interactive login, approval screen, multifactor prompt, or account recovery because firstmate cannot handle the credential or impersonate the captain.
Do not imply that preparing the brief performed or authorized any listed action.

## Output mode

Answer in chat by default.
Write a private dated report only when the captain explicitly asks for a file or durable report.
In file mode, write the complete brief to `data/decision-brief-<YYYY-MM-DD>.md`, replace that day's prior brief with the newly reconciled current version, and return a concise chat summary with the path.
The report is the only write this skill permits.
If no current calls remain after reconciliation, say `Captain, no current decision or action requires your input.` and include any coverage limitation that prevents a complete inventory.
