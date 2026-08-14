# Language and access

This reference owns controlled technical language, progressive disclosure, content-type guidance, accessibility review, editorial review, and bounded lint heuristics for `visual-technical-communication`.
Read it during the language and accessibility passes.
The main skill owns truth inventory, precedence, delivery order, output contracts, and failure behavior.

## Control technical language

Build a small working term map before revising substantial content.
Record each concept, its preferred term, exact project or interface names, terms to avoid for that concept, and whether the audience needs a definition.

Apply these rules:

1. Name the actor and its action unless the actor is unknown, irrelevant, or intentionally de-emphasized.
2. Use one term for one concept and one meaning for each term in the same output.
3. Preserve exact domain, product, interface, protocol, and code names.
4. Define unavoidable unfamiliar jargon by its function when the reader first needs it.
5. Lead each section, paragraph, caption, error, and report with its outcome or required action.
6. Use present tense for normal behavior and future tense only for a genuinely later event.
7. Address the reader as `you` in explanations and use direct imperatives for instructions.
8. Use `must` for requirements, `can` for capability, and `might` for possibility or uncertainty.
9. Replace vague verbs such as `handle`, `support`, `process`, and `manage` with the actual operation.
10. Keep uncertainty as a labeled estimate, range, confidence statement, or unknown.
11. Use direct positive instructions unless a prohibition or hazard requires `Do not`.
12. Separate overlapping conditions and state their precedence.
13. Add a noun after a pronoun when its antecedent could be unclear.
14. Keep units, bounds, currencies, time zones, rate bases, and comparison baselines explicit.
15. Use a respectful professional tone without slang, figurative language, or claims that work is easy or obvious.

Prefer active voice when it makes ownership clear.
Use passive voice when the actor is unknown, irrelevant, or less important than the affected object.
Do not replace a precise technical term with a familiar but less accurate word.

## Shape sentences and paragraphs

Give each sentence one main assertion, except when a tightly coupled cause and result are clearer together.
Target 20 words or fewer for steps, captions, warnings, expanded labels, and recovery instructions.
Target 25 words or fewer for other sentences.
Review every sentence over 25 words and rewrite or justify every sentence over 35 words.
Keep each paragraph focused on one idea and usually one to three sentences.
Review paragraphs over five sentences.
Keep diagram labels to short noun or verb phrases, usually five words or fewer.
Treat these lengths as editorial signals rather than correctness rules.
Preserve exact commands, names, conditions, and technical meaning when a shorter form would distort them.

## Write conditions, procedures, and units

Put a condition before an action when the reader must evaluate it first.
Start each action step with an imperative verb.
Give each numbered step one reader decision or goal.
Keep inseparable actions together when splitting them would hide the task.
State the location before the action when location matters.
State purpose before interface mechanics when purpose helps the reader choose correctly.
Mark optional steps with a consistent text cue.
Put most values and unit symbols together according to the target renderer's typographic rules.
Write ambiguous ranges with `to` and repeat the unit at both endpoints.
Distinguish decimal and binary storage units.

## Use progressive disclosure

Use these layers in order when the content needs them:

| Layer | Job | Keep here | Move out |
|---|---|---|---|
| Visual | Show the relationship | Actors, boundaries, direction, key conditions | Paragraphs and exhaustive edge cases |
| Caption | State the conclusion | One complete takeaway | A generic title or full description |
| Explanation | Explain action and limits | Mechanism, critical conditions, exception, next action | History and exhaustive implementation detail |
| Optional detail | Support deeper inspection | Edge cases, alternatives, evidence, calculations, full text description | Prerequisites and warnings |
| Authoritative reference | Own the complete contract | Full API, standard, runbook, or evidence | The only copy of information needed now |

Keep required safety information, prerequisites, and facts needed for the current action in the immediate output.
Use descriptive links to the most specific authoritative heading for optional depth.
Refer to a visual by its semantic name or caption rather than its position or color.

## Follow the content type

### Technical explanation

Show the primary relationship only when it improves the model.
Follow it with a conclusion caption and a short causal explanation.
Name actors, mechanisms, conditions, and limits.

### Procedure

Put prerequisites and warnings before numbered imperative steps.
Use a flow only when branching or state makes numbered prose insufficient.
State conditions before actions and isolate reader decisions.

### Interface or API

Present caller, input, operation, output, and errors as a compact contract.
Use exact identifiers and distinguish required, optional, and default behavior.
Introduce code with its purpose and use the target project's formatter.
Keep examples minimal but executable or structurally faithful for the reader's task.

### Architecture

Use a layered or before-and-after model when boundaries or change are the reader's question.
Name ownership, dependency direction, external systems, and synchronous or asynchronous behavior.
Keep runtime sequence in a separate flow only when it answers another necessary question.

### State model

Keep states, events, guards, transition actions, and results distinct.
List invariants beside the model rather than hiding them in transition labels.

### Report

Lead with the outcome.
Separate observations, inferences, risks, and recommendations.
Use a matrix or scale only for shared criteria or comparable measurements.

### Caption and label

Write a caption as a complete sentence that states the visual's conclusion.
Use a stable noun phrase for a thing and a verb phrase for an action label.
Do not invent an abbreviation only to shorten a label.

### Error message

State what failed, the consequence when material, and the recovery action.
Name the failed object and known cause without blaming the reader or inventing certainty.

### Decision prompt

State why the decision is needed now.
Compare options on shared criteria, separate evidence from recommendation, and give exact reply choices.

### Warning

Choose the least severe accurate label:

- `NOTE` marks useful context that does not control success.
- `CAUTION` marks a recoverable problem that proceeding can cause.
- `WARNING` marks possible loss, security exposure, or irreversible harm.

Place the warning before the hazardous action.
Name the hazard, consequence, and safe action.
Pair severity text with any icon, border, or color cue.

## Check accessibility and non-color meaning

An informative visual passes only when every relevant item below passes:

- A nearby caption states the visual's contextual conclusion.
- Concise alt text states the visual's purpose and takeaway.
- A structured text description carries details that concise alt text cannot preserve.
- The caption and text equivalent preserve the same conditions and actions as the visual.
- Color has a text, shape, pattern, enclosure, or line-style partner.
- Every icon, symbol, and non-obvious arrow has a text label or legend.
- The content has a coherent linear reading order.
- The result remains usable under zoom and narrow width.
- References do not depend on `above`, `below`, `left`, `right`, or a color name.
- Meaning does not depend on hover, sound, motion, emoji, punctuation, or spatial placement alone.
- Links describe their destination or answer.
- Warnings use severity text and precede the hazard.

Test the text equivalent independently rather than treating its presence as proof of equivalence.
Use concise alt text plus a structured description when the visual contains more information than alt text can carry.

## Run the editorial review

### Model and presentation

- Confirm the opening names the reader's goal or the conclusion.
- Confirm visual selection passes the visual patterns reference.
- Confirm the visual has one reading order and a legend for non-obvious notation.
- Confirm labels use the term map and exact interface names.
- Confirm the caption states a conclusion rather than repeating a title.
- Remove decorative detail.

### Language

- Confirm one term names each concept and each term keeps one meaning.
- Confirm actors are explicit unless an exception is justified.
- Confirm instructions use imperatives and place evaluated conditions first.
- Confirm modal words distinguish requirements, capabilities, recommendations, and possibilities.
- Confirm negation is direct and unambiguous.
- Review long sentences and paragraphs without changing precise meaning.

### Supporting material

- Confirm explanations add mechanism, conditions, or action instead of narrating the visual.
- Confirm code has a stated purpose and enough context for its intended use.
- Confirm warnings state hazard, consequence, and safe action before the hazard.
- Confirm links are descriptive and optional to immediate understanding or action.
- Complete every applicable accessibility check in this reference.

## Use lint as a bounded review queue

Automation can identify candidates for human or model review, but it cannot decide factual precision, semantic equivalence, or formal language compliance.
Apply these heuristics only to authored prose, excluding code, exact interface strings, generated output, and quotations where appropriate.

| Heuristic | Candidate signal | Required review |
|---|---|---|
| Sentence length | More than 25 words, with stronger attention over 35 | Check nested syntax and necessary conditions |
| Paragraph length | More than five sentences | Check for more than one idea |
| Passive voice | A form of `be` plus a likely participle | Identify the actor or justify emphasis |
| Vague language | `handle`, `support`, `manage`, `simply`, `just`, `easy`, or `obvious` | Replace with the exact operation or remove |
| Ambiguous pronoun | Initial `This`, `That`, `It`, or `They` without a clear noun | Name the referent |
| Modal drift | `should`, `may`, or `might` in normative text | Classify requirement, recommendation, permission, or uncertainty |
| Abbreviation | Repeated capitals without an earlier definition | Define it or confirm audience-standard usage |
| Late condition | An imperative followed by `if`, `unless`, or `when` | Move an evaluated condition before the action |
| Visual access | Color or directional words, missing alt text, or multiple edge styles without a legend | Verify equivalent non-color and text cues |
| Terminology drift | Candidate synonyms for one mapped concept | Restore the preferred term or confirm distinct concepts |
| Units | Missing spacing, ambiguous ranges, or mixed decimal and binary units | Restore the intended quantity and basis |
| Procedure form | A numbered action without an imperative opening | Rewrite or classify it as a result check |

Treat every signal as a prompt to inspect context rather than an automatic defect.
Record a brief justification when retaining a flagged construction that preserves meaning better than the suggested form.
