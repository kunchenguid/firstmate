---
name: afk-jira-research
description: >-
  Review the captain's own Jira and Confluence work read-only over a frozen scope, when they invoke /afk-jira-research or ask firstmate to analyse their company work patterns.
  Strictly read-only and company-lane only: it produces work-pattern metrics with denominators and non-clinical hypotheses about the captain alone, never an HR judgement, a coworker profile, or any change to a company system.
user-invocable: true
metadata:
  internal: true
---

# afk-jira-research

**Load `autonomous-run-engine` first.**
It owns the shared intake-to-report procedure.
This file owns only what is specific to company work review.

```text
/afk-jira-research --site <id> --projects <ids> --spaces <ids>
                   --authorship authored|assigned|both --status <set>
                   --window <from..to> [--budget <wall>]
```

## This mode currently stops at preflight

The read-only claim here means every Atlassian write tool is **absent** from the worker's surface, not that the worker was asked not to use one.
Firstmate has no verified prover for that absence yet, so preflight refuses the run and names `tools.surfaceProof` as the exact missing requirement.

Tell the captain that plainly if they invoke it.
Do not route around it by running the review from a surface that still carries write tools, and do not treat "I will not call those tools" as equivalent.

Everything below is the contract the mode runs under once a proof exists.

## Boundaries that do not move

- Read-only. No issue or page creation or edit, no transition, assignment, mention, reaction, notification, worklog, attachment upload, or external message.
- Attachment **downloads** count as write-adjacent, because they pull company bytes onto local disk. They are excluded from the allowlist and reach the evidence directory only under an explicit per-run grant for a named attachment.
- No browser lease at all. A browser could mutate through the UI, so this mode does not get one.
- Company lane only. Raw company content never reaches a personal account or a public service, and the run reads no personal source.
- Atlassian stays disabled outside an explicit captain invocation or an approved run manifest.

Freeze the site, projects, spaces, authorship filter, statuses, date range, and allowed fields before anything is read.
Freeze every local root the run may read into `source.readRoots` as well: at least one is required, and preflight refuses a read-only run that froze none, because the read gate bounds reads to the roots the manifest names.
A scope that turns out to be wrong is a new run.

## Schema-drift tripwire

At preflight, snapshot the schema of every allowlisted tool.
If a tool that was a read now advertises a mutation parameter, or a tool appears that was not in the snapshot, **stop before access** and report the drift.
A connector that changed under the run is exactly the case where continuing on last night's assumption is the mistake.

## Metrics

Every metric states its definition, unit, denominator, time window, exclusions, and what data was missing.
Missing or partially permitted history is reported as missing; it is never inferred, interpolated, or quietly dropped from a denominator.

Cover workload and throughput, lead and cycle time with median and p85, aging, reopen rate, blocker frequency and duration, estimation accuracy where estimates exist, and comment, context-switching, handoff, and follow-through counts.
Keep **authored** text separate from text merely assigned to or mentioning the captain throughout: they answer different questions.

## The psychological boundary

The default layer describes observable work patterns only: context switching, avoidance signals, overload, interruption sensitivity, preference for visual structure, follow-up friction.
Each hypothesis is labeled non-clinical, evidence-limited, and falsifiable, carries alternative explanations and a confidence, and asks the captain before it becomes a durable preference or rule.

This layer never diagnoses mental health, personality, cognitive conditions, motivation, intent, or private traits.
Deeper interpretation of the captain is a separate opt-in personal-lane capability, and a company run never enables it.

For everyone who is not the captain there is no ranking, surveillance, HR judgement, psychological profiling, or diagnosis, ever.
Company performance data is not used for employment judgements, coworker profiling, or comparative scoring.

## Stop conditions specific to this mode

Stop on authentication or permission uncertainty, company-policy ambiguity, unexpectedly broad access, sensitive HR, legal, or security content, an insufficient sample, unverifiable authorship, schema drift, or any requested mutation.

## Deliverable

A concise written report plus a source-linked metrics artifact, kept in a company-approved destination.
A redacted personal summary reaches personal Obsidian only on the captain's explicit authorization, and only if it survives the reconstruction test with coworker and client detail removed.

Add a visual only where it materially improves understanding, never decoratively, and hold it to the same confidentiality: no raw confidential text and no identifiable coworker detail in a personal gallery.
