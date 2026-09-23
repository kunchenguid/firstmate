---
name: auto-research
description: >-
  Run a long-horizon autonomous research campaign as a team: a lead worker drives the campaign, scouts answer bounded questions, and firstmate orchestrates and pushes.
  Use when firstmate launches, resumes, or supervises an auto-research campaign.
user-invocable: false
metadata:
  internal: true
---

# auto-research

Research is a team sport: one mind serializes what a fleet parallelizes.

## Team

- **Lead** owns hypotheses, the experiment queue, runs, and project knowledge.
- **Scouts** answer bounded single questions and return self-contained reports.
- **Firstmate** dispatches, pushes the lead on idle, routes findings, and escalates real decisions through `captain-hold-lifecycle`.

## Intake

Campaign intake resolves the owning project's launch roster or doctrine and passes the selected campaign brief, authorization gates, and canonical startup pointer to the lead.
Do not require every activating agent to reread the roster, and never hardcode one project's roster path here.
Scouts receive only their bounded question and relevant constraints.

## Loop

1. Push the lead toward the highest-value open question; when it idles, wake and push again through a `when`-watch on its pane (`process-event-sources` owns the contract).
2. Route every scout report back to the lead.
3. Challenge "nothing actionable" with the next-best thread; accept a wait only when all threads are externally blocked.
4. Gate cures behind diagnostics; never burn compute on unconfirmed mechanisms.

## State

- **Science state** - hypotheses, experiment queue, next action, and artifacts - lives in the project's canonical index or startup chain.
- **Fleet handles** - campaign id, lead endpoint, armed sources, remote host, and dispatch queue - live in one firstmate campaign record, plus `state/<id>.meta` for spawned leads.
- Firstmate owns the campaign record keyed by campaign id; the lead reads it, updates the project pointer and science state, and resumes the same campaign rather than creating another.
- The project startup file carries one stable pointer line containing the campaign id and record path; the lead writes it, and it contains no fleet handles beyond the campaign id and record path.

## Boundaries

- Project authorization contracts, launch gates, and budget caps outrank pushes.
- Every finding must be self-contained.

## End

When the question is answered or the captain stops the campaign, retire watches through `process-event-sources`, release the lead, finalize the campaign record and project pointer, and distill durable lessons into this skill's `evolution.md`.
An ended campaign leaves no armed watches, stale pointers, or open loops.

## Evolution

This skill's `evolution.md` holds dated lessons; cross-reference facts owned by another file or skill instead of duplicating them.
