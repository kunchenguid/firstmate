---
name: diagnostic-reasoning
description: >-
  Agent-only procedure for diagnosing reported bugs.
  Use before scoping a reported bug, before acting on a diagnostic report, and before reporting that something is absent, empty, missing, or not found.
  Owns end-user-aligned reproduction, causal separation, divergent-path and history inspection, counterfactual testing, disconfirming evidence, and when a negative result may be trusted.
user-invocable: false
metadata:
  internal: true
---

# diagnostic-reasoning

Use this procedure before scoping a reported bug, before acting on a diagnostic report, and before reporting that something is absent, empty, missing, or not found.
This skill is the single owner of Firstmate's bug-diagnosis reasoning procedure.
Firstmate applies it when briefing delegated investigation and evaluating the resulting evidence, without taking over project-specific investigation itself.

## Establish the observed behavior

Start from the end user's experience rather than an internal error string or an implementation hypothesis.
Require an end-to-end reproduction aligned with the real user path whenever it is feasible and safe.
If a faithful reproduction is not feasible, record the exact limitation and use the closest representative path without presenting it as equivalent evidence.
Capture the expected behavior, observed behavior, setup, inputs, and repeatability before assigning a cause.

Separate these three facts explicitly:

- The **initiating trigger** is the event, input, or transition that starts the faulty behavior.
- The **masking condition** is the independent state, environment, timing, cache, configuration, or path difference that hides or exposes the fault.
- The **visible symptom** is what the end user or operator can actually observe.

Do not collapse those facts into one label.
A masking condition may explain why a fault appears only sometimes without being the initiating cause, and the visible symptom may be several layers downstream from both.

## Test the causal explanation

Inspect the failing path and a proven path where the intended behavior is known to work.
Compare their inputs, state transitions, dependencies, timing, and control flow to find the earliest meaningful divergence.
Inspect relevant history, including blame, commits, migrations, and prior implementations, when it can explain why the paths diverged or which invariant was intended.
Do not treat the most recent nearby change as causal without evidence.

Identify the smallest counterfactual that should change the outcome if the leading explanation is true.
Change one condition at a time where practical, and record whether the symptom appears, disappears, or remains unchanged.
Seek disconfirming evidence deliberately: name what observation would falsify the leading explanation, run that check when feasible, and retain contradictory results instead of explaining them away.
Compare the final explanation against the proven path and show why the proposed causal boundary accounts for both the failure and the success.

## Trust a negative only after the method has produced a positive

A zero, an empty result, or a "not found" is a claim about the method as much as about the world.
Before reporting absence, run the same method against data known to exist; if it cannot find that, it has established nothing about the target.

Distinguish three outcomes, never two:

- **Found** is a positive the method demonstrably can produce.
- **Confirmed absent** is a negative from a method already shown to find what is there.
- **The query failed** is everything else: a subcommand that does not exist, a malformed request, an endpoint that cannot see what was asked about, a pattern that matches the wrong shape, or a key collision that silently drops rows.

Tooling that renders a failure as an empty result is the trap, so treat an unproven empty as a failure until shown otherwise.
Two agreeing checks are not corroboration when they share a failure mode, because a wrong pattern and a wrong endpoint can agree with each other; independent method, not repeated method.
This binds hardest on captain-facing statements, since "there is nothing there" is a conclusion the captain will act on and carries the same burden as any other load-bearing finding.

## Scope and act on the result

A diagnosis brief should ask for the reproduction, trigger/mask/symptom separation, divergent and proven path comparison, relevant history, smallest counterfactual, and disconfirming evidence in the report.
A diagnostic report should distinguish observed facts from hypotheses and state any unresolved uncertainty that could change the recommended scope.
Before acting on the report, verify that its claimed cause explains the end-user reproduction and the proven path without relying on an untested masking condition.
If a load-bearing element is missing, route a focused follow-up investigation instead of treating confidence or implementation detail as proof.
A diagnosis or implementation-ready recommendation is evidence, not authorization to change code.
Implementation still requires the captain's request or another existing lifecycle authority, and the reproduction should become the regression test when a fix is authorized.
