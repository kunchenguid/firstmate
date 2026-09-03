---
name: research-first-decisions
description: >-
  Agent-only procedure for selecting a tool, library, framework, service, vendor, or approach from candidates.
  Use before commissioning or consuming research that will pick one option over others, and before recording such a selection as decided.
  Owns the predeclared frozen query plan, the search and challenge workflow, the primary-source hierarchy, the decision-packet form, the external-query privacy rule, and the boundary between research that selects and local proof that only verifies.
user-invocable: false
metadata:
  internal: true
---

# research-first-decisions

Load this before any selection among candidates: a tool, library, framework, service, vendor, protocol, data source, or approach.
It is the single owner of that selection procedure.
Selection happens once and is expensive to reverse, so the evidence that drives it is gathered against a plan written before the searching starts, not assembled afterwards to fit a preference.

The order is fixed: freeze the plan, search, challenge and expand, verify against primary sources, then write the decision packet.
Skipping to a candidate and researching to confirm it is the failure this procedure exists to prevent.

## 1. Predeclared frozen query plan

Write the plan before running a single query, and freeze it.
It records:

- **Question** - the decision in one sentence, stated so a wrong answer is recognisable.
- **Decision criteria, in priority order** - what actually decides this, ranked before any candidate is known.
  Unranked criteria let the winner pick its own rubric.
- **Candidate set** - the options entering the comparison, including the incumbent and the do-nothing option where either is real.
- **Exclusions** - what is deliberately out and why, so a silent omission cannot pass as an absence of options.
- **Planned queries** - the searches to run, including the ones expected to be unflattering.
- **Negative-search populations** - where disconfirming evidence would live if it existed: deprecation notices, migration guides, abandonment and maintenance signals, incident and outage records, security advisories, and the accounts of people who moved off the candidate.
- **Stop rules** - what makes the research finished, and what makes it abort early.

Amend the frozen plan only by recording the amendment and its reason in the packet.
An unrecorded mid-research change of criteria is how a predetermined answer gets laundered into a finding.

## 2. Search, then challenge and expand

Run the planned queries with web search first, then use Exa to do the work a plain search will not.
Both passes are required; the second is where the plan earns its value.

- **Challenge** - search for the case against each candidate, using the negative-search populations named above.
  A candidate with no located criticism has not been challenged, it has been under-searched.
- **Expand** - search for candidates the plan missed.
  Selection quality is bounded by the candidate set, and the frozen set is a starting point, not a closed one.
  Record every late candidate and either admit it to the comparison or record its exclusion reason.

Stop when the stop rules are met, and record which rule fired.
Diminishing returns is a valid stop; running out of patience is not, and neither is finding an answer you like.
Where English sources are thin on a candidate, promote - but do not require - searches in other languages, including Chinese, Russian, German, French, Spanish, Korean, Japanese, and others; write every finding entering the packet in English, cite its original language and title, and save nothing in another language.

## 3. Source hierarchy

Primary sources are the only authority.
Official documentation, the source repository, release notes, changelogs, specifications, issue and advisory trackers, licences, and the vendor's own current terms decide a claim.

Secondary sources are leads, never authority.
Blog posts, comparison articles, benchmarks by third parties, forum answers, aggregator summaries, and model recollection point at a claim worth checking; they never settle it.
Trace every load-bearing claim to a primary source before it enters the packet, and mark any claim that could not be traced as unverified rather than promoting it.
Prefer the current version of a primary source over a dated one, and record the version or date a claim was read at, because a true-in-2023 fact presented undated is a future wrong answer.
Among primary sources, modern academic papers, current standards, and current methods outrank older ones on the same claim.

## 4. Decision packet

The deliverable is a packet, not a recommendation sentence.
It carries the frozen plan and its amendments, the evidence per candidate with primary-source citations, and:

- **A disposition for every candidate**, one of:
  - **ADOPT** - selected, with the criteria it won on and what it costs.
  - **BENCHMARK FURTHER** - not selected; a named decision criterion remains unresolved after primary-source research, with the missing evidence or public measurement stated.
    Continue research or route the ambiguity to the captain; bounded local proof never clears this disposition into ADOPT.
  - **REJECT** - out, with the specific disqualifying evidence.
  - **DEFER** - not now, with what would reopen it.
  No candidate may be left without a disposition; an unaccounted candidate reads as an unexamined one.
- **Invalidation triggers** - the concrete events that would void this selection: a version bump past a named release, a licence change, a maintenance or ownership change, a named benchmark landing differently, a requirement changing.
  Without these the packet silently expires into a false claim.
- **Consumption records** - which task consumed this packet, named explicitly.
  A selection nobody records consuming gets re-researched or, worse, quietly re-decided.
  The research that produced a finding updates the project's research log with its dated section, lookup heading, and last-reviewed line as part of the packet, never as a later task.

Keep the packet's reasoning summary concise and material.
Record what decided it, not a transcript of the search.

## 5. Privacy of external queries

An external query is a disclosure.
Never put private code, private data, internal paths, host names, credentials, customer or captain identifiers, unreleased product facts, or repository-specific identifiers into a web or Exa search.
Ask the question in generic, public terms: the shape of the problem, not the instance of it.
If a question cannot be asked without disclosing private material, it is not a research question; answer it locally instead.

## 6. Selection versus proof

Research selects.
Only an ADOPT option is selected.
Bounded local proof may run only after selection and only for an ADOPT option, to verify an integration-specific feasibility or budget claim such as whether it builds here or speaks the protocol this system speaks.
Local proof never ranks candidates, clears a BENCHMARK FURTHER disposition into ADOPT, changes a disposition, or overturns the research conclusion.

A local contest, bake-off, or prototype shoot-out is never a selection gate.
Building each candidate locally and picking the one that felt best substitutes an afternoon of local effort for the whole public record of how these options behave over time, and it systematically favours whatever is quickest to stand up rather than whatever is right to live with.
Where a comparison genuinely cannot be settled from primary sources, continue the research or route the ambiguity to the captain, recording BENCHMARK FURTHER or DEFER rather than settling it with a local measurement.
Keep proof of an ADOPT option bounded to its named integration claim, and record its result back into the packet.
If that proof fails, record the failed integration claim and return the decision to research or the captain; the proof does not select a replacement or change a disposition itself.

Open-source libraries, and the ways other good applications solve the same problem, are legitimate candidates and sources; referencing or copying their code is allowed when its licence permits and its origin is cited, and copied code is localized to the project's conventions, contracts, and tests rather than pasted.

## Boundaries

This skill owns the selection procedure only.
Whether to commission a scout at all, and the ship-versus-scout classification, stay with `AGENTS.md` section 7.
Diagnosing a reported bug is `diagnostic-reasoning`, not a candidate selection.
Choosing a harness, model, or dispatch profile for a task is owned by `AGENTS.md` section 4, `harness-adapters`, and `quota-array-dispatch`; runtime quota and catalog evidence decide that at intake, and this procedure does not overrule them.
Do not build a research tracker, registry, scoring engine, or template checker for any of the above; the packet is a document.
