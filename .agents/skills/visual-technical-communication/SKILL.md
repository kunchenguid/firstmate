---
name: visual-technical-communication
description: >-
  Create visual-first technical explanations and decision material, transform dense technical prose into a faithful diagram-led or prose-only form, and review technical content for model fidelity, controlled language, and visual accessibility.
  Use for architecture, interfaces, states, workflows, timelines, comparisons, procedures, reports, errors, and decision prompts when relationships or technical wording affect understanding.
user-invocable: false
metadata:
  internal: true
---

# Visual technical communication

Use this workflow to make a technical relationship easier to understand without weakening its truth.
A visual is primary only when it helps the reader understand a relationship.
Keep a short factual answer short when prose already answers the reader's question.

## Resolve the inputs

Resolve these inputs from the request, source material, and current project before drafting:

- the reader, their task, and the decision or action the output must support;
- authoritative source truth, including code, specifications, data, and supplied facts;
- the relationship type, or a prose-only conclusion;
- the target medium and its supported rendering formats;
- project terminology and exact interface names;
- safety, legal, localization, and accessibility constraints;
- requested depth and the reader's decision authority.

Inspect available sources before asking for information that the environment can provide.
Ask one focused question when a missing input would materially change the model.
Otherwise, state a bounded assumption and identify what could invalidate it.

## Apply precedence

Resolve conflicts in this order:

1. Preserve truth, safety, security, accessibility, and technical meaning.
2. Follow explicit project and domain requirements, including exact code and interface contracts.
3. When formal ASD-STE100 compliance is required, use the current official standard and qualified human review.
4. Prefer a useful visual for a relationship that benefits from one.
5. Apply the target project's documentation conventions.
6. Apply this skill's defaults.

This skill is STE-informed and cannot claim or certify ASD-STE100 compliance.
Describe unqualified output as STE-informed draft material at most.

## Run the workflow

1. **Anchor truth.**
   Inventory every actor, state, event, operation, condition, invariant, exception, unit, and uncertainty in the source.
   Map every supplied fact to that inventory or mark it irrelevant with a reason.
2. **Name the reader question.**
   Write the one question that the primary presentation must answer.
   Confirm that answering it supports the reader's stated task.
3. **Choose the format.**
   Read [visual patterns](references/visual-patterns.md) and apply its selection procedure.
   Complete this step when the selected format answers the named reader question and the procedure's prose-only branch has been considered.
4. **Draft the model.**
   Use the target medium's supported format.
   When support is unknown or unsuitable, use a text diagram or semantic table.
   Give the visual one reading order and apply the pattern reference's symbol and arrow contract.
5. **Layer the communication.**
   Read [language and access](references/language-and-access.md) for the language, content-type, disclosure, and accessibility passes.
   Keep facts required for understanding or safe action in the immediate output.
   Link only optional depth to its most specific authoritative source.
6. **Check fidelity.**
   Compare the draft with the truth inventory item by item.
   Restore any actor, condition, invariant, exception, unit, or uncertainty that changed, disappeared, or became falsely certain.
7. **Check accessibility.**
   Apply every relevant check in the language and access reference.
   Read the result without color, the visual, directional language, hover, sound, motion, or unlabeled icons.
   The check is complete only when the linear text preserves the same conclusion, conditions, and available actions.
8. **Deliver or review.**
   Put urgent safety information before the visual.
   Otherwise, follow the applicable output contract below.
   Identify unresolved assumptions and source conflicts at the point where they affect the result.

## Produce the requested output

### Explanation or decision material

Return only the layers the reader needs, in this order:

1. An optional one-line orientation when the visual needs context.
2. The primary visual when a relationship benefits from one.
3. A complete-sentence caption that states the conclusion.
4. A short explanation of the mechanism, critical conditions, and exceptions.
5. Optional detail or a descriptive link to an authoritative source.
6. A next action or exact reply choices when the reader must respond.

### Procedure

Put prerequisites and warnings before numbered imperative steps.
Use a visual only for branching, navigation, state, or verification that prose cannot show as clearly.
State the expected result when it helps the reader verify completion.

### Short factual answer

Answer in one or two direct sentences when no relationship needs a visual.
Do not announce the omission of a diagram unless the request explicitly asks for one.

### Review

Group findings under `Model fidelity`, `Visual choice`, `Controlled language`, and `Accessibility`.
State the affected fact and consequence for each finding.
Include a corrected example for each high-impact finding.
Do not silently rewrite source facts or treat a stylistic preference as a factual correction.

## Handle failure

- If source facts conflict or remain incomplete, show the conflict and its affected model element, then ask one focused question or state a bounded assumption.
- If a diagram becomes dense, split it by reader question or disclose optional detail rather than shrinking labels or adding encodings.
- If prose is clearer, use prose.
- If simplification changes technical meaning, restore the precise fact and simplify the surrounding language.
- If an exact interface term conflicts with preferred vocabulary, keep the exact term and define it when needed.
- If concise alt text cannot preserve the visual's meaning, add a structured text description.
- If automated lint conflicts with meaning, preserve meaning and record a justified exception.
- If safety conflicts with visual-first ordering, put the warning first.
- If the request asks for ASD-STE100 certification, apply the compliance boundary in `Apply precedence` and offer a clearly labeled STE-informed draft or review.

Complete the task only after format selection, fidelity, accessibility, and the applicable output contract all pass.
