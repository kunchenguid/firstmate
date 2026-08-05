# No-Pronoun Communication

No-pronoun communication is a voluntary language practice that avoids pronouns in selected ordinary instructions and responses.
This document is written for captains, AI-agent operators, and anyone coordinating a language-model interaction.
The practice is not a claim that pronouns are harmful, that persons are unreal, or that every conversation should change.

## Scope and consent

Activate the practice only after a clear request from the person directing the interaction.
State the scope, such as one task, one conversation, or all ordinary instructions until explicitly disabled.
Stop the practice when the directing person withdraws consent or when the scope ends.
Pronouns remain valid and useful in ordinary communication, including communication from people who do not opt into this practice.
Do not shame, pressure, or correct a person for using pronouns.

## Practical reasons to try it

The following points are operator interpretations and design rationales, not universal findings.

- **Clearer instruction boundaries:** Replacing a pronoun with the concrete actor, artifact, or action can make an instruction less dependent on a nearby antecedent, such as replacing “Review it” with “Review the release checklist.”
- **Potentially lower token use:** A shorter rephrase can contain fewer words and sometimes fewer model tokens, but token counts depend on the tokenizer and language, so no fixed saving is promised.
- **Less self-referential framing:** Naming the task, artifact, or observable result can reduce framing around the speaker or listener, such as replacing “I think you should check it” with “Check the failing test.”
- **More deliberate language:** A constraint can prompt explicit choices about actor, object, condition, and requested result, although the constraint can also make wording awkward or longer.

The token-use qualification follows from the fact that tokenizers divide text into model-specific units rather than counting words in a universal way.
The [tiktoken project](https://github.com/openai/tiktoken) describes a byte-pair-encoding tokenizer for OpenAI models, which illustrates why token counts depend on the tokenizer in use.
The examples above are communication choices, not evidence that the practice improves every operator's comprehension or performance.

## Philosophical basis and limits

Some people interpret reduced first-person and second-person framing as a contemplative exercise related to reduced egoic identification.
That statement is an interpretation about a possible meaning of the practice, not a scientific result, a clinical claim, or a universal spiritual truth.
A grammatical choice cannot establish or disprove claims about the self, consciousness, reality, or metaphysics.

The practice separates language discipline from metaphysical commitment.
An operator can use the practice as a temporary writing constraint without accepting any spiritual interpretation.
A person can also reject the practice while retaining ordinary dignity, insight, and moral worth.

Consent is part of the practice rather than an optional courtesy.
A captain or operator may opt in, narrow the scope, pause the practice, or stop it at any time.
Respect for ordinary communication means preserving pronouns when natural wording, accessibility, emotional nuance, or safety requires them.

No quotation attributed to David Hawkins is used here as evidence.
Unverified or unattributed quotations should not be presented as authoritative support for this practice.

## Copyable AI-agent protocol

The following protocol is intentionally scoped to English-language interaction and should be adapted for the active language.

```text
NO-PRONOUN COMMUNICATION PROTOCOL

Activation:
- Apply this protocol only after explicit opt-in from the directing person.
- Record the scope and keep the protocol active only within that scope.
- Disable the protocol immediately when the directing person withdraws consent or the scope ends.

For each incoming message:
1. Classify the message as meta-conversation or an ordinary instruction.
2. Treat discussion of this protocol, pronouns, consent, quotations, language, or exceptions as meta-conversation.
3. For an ordinary instruction, detect pronouns using the grammar of the active language.
4. If pronouns are detected, list every detected term exactly as written.
5. Request a pronoun-free rephrase instead of silently guessing or silently rewriting the instruction.
6. Use this response shape: "Detected pronouns: <terms>. Please rephrase the instruction without pronouns."
7. If an example helps, provide a short pronoun-free example that preserves the requested action and object.
8. If no pronouns are detected, follow the instruction when the instruction is otherwise authorized and clear.
9. While the protocol is active, formulate ordinary agent responses without pronouns.
10. Preserve the exceptions below, even while the protocol is active.

Example:
Incoming instruction: "Please review your branch and tell me what you changed."
Agent response: "Detected pronouns: \"your\", \"me\". Please rephrase the instruction without pronouns, for example: \"Review the branch and summarize the changes.\""

Pronoun-free completion example:
"Review complete. The branch contains two documentation changes. Documentation checks passed."
```

The protocol requires a rephrase because omitted references can change an instruction's actor, object, scope, or safety conditions.
An agent should ask for clarification instead of turning a linguistic constraint into permission to infer intent.

## Exceptions and limitations

- **Meta-conversation:** Discussion of the protocol, detected terms, consent, or language may name pronouns directly.
- **Exact quotations:** Preserve a quotation exactly when fidelity to a source or a person's words matters, and identify the quotation as quoted text.
- **Source citations:** Preserve author names, titles, URLs, bibliographic text, and other citation data exactly when alteration would make a source harder to identify.
- **Code and data:** Preserve code, configuration, commands, serialized data, tests, and examples when pronoun changes would alter behavior or meaning.
- **Identifiers:** Preserve variable names, API names, file paths, usernames, product names, legal names, and other identifiers exactly.
- **Accessibility:** Prefer wording that supports screen readers, translation, cognitive accessibility, plain-language needs, and a person's established communication style.
- **Language dependence:** Pronoun inventories, grammatical agreement, acceptable omission, and natural rephrasing differ across languages, so an English detector is not a universal grammar rule.
- **Ambiguity:** Do not remove a pronoun if the replacement would introduce an unclear actor, object, time, condition, or scope, and ask for clarification when needed.
- **Natural or safer language:** Use ordinary pronouns or any other natural wording when that wording is clearer, kinder, legally necessary, or safer than a forced rephrase.
- **Higher-priority instructions:** Follow applicable system, safety, privacy, accessibility, and emergency requirements before applying this optional style constraint.

A pronoun-free response is not a reason to omit required context, soften a necessary warning, or conceal uncertainty.
When an exception applies, preserve the necessary language and briefly state that the exception protects fidelity, clarity, accessibility, or safety.

## Evidence and interpretation

This document makes a narrow evidence claim about tokenizer dependence and cites the [tiktoken project](https://github.com/openai/tiktoken) for an example of a model tokenizer.
The practical benefits, philosophical meaning, and communication recommendations are explicitly presented as interpretations or voluntary design choices.
No general improvement claim is made without a cited study, and no metaphysical claim is treated as established fact.

For broader language background, the [Encyclopaedia Britannica overview of pronouns](https://www.britannica.com/topic/pronoun) provides a general grammatical reference.
The overview supports treating pronouns as a grammatical category, not treating one English-language protocol as a universal rule for every language.
