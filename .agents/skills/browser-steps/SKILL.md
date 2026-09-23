---
name: browser-steps
description: Agent-only guidance for compact, act-and-verify browser steps. Load before driving a multi-step browser flow with chrome-devtools-axi.
user-invocable: false
metadata:
  internal: true
---

# browser-steps

Use `bin/fm-browser.sh step` to combine one browser action with a bounded expectation check.
For a known repeated flow, use `bin/fm-browser.sh route run <host>/<route>` to run its saved steps in one browser call; read `bin/fm-browser.sh --help` for recording, variable, confirmation, handoff, and resume options.
Route variables are refused when their names or values appear secret-like, and the route only changes after a healed target action and its expectation both verify.
A `confirm` step pauses before its action and never grants authority to perform it; handoff steps wait for their declared browser condition while the captain handles the browser-only moment.
Include an expectation whenever the action's effect must be confirmed; without one, the result is explicitly unverified. Expectations are postconditions: `verified` is true when the explicit condition holds after the action, whether or not it held beforehand.
Read `bin/fm-browser.sh --help` for the current command grammar and output contract.
Choose a task-unique named session and never use the default session, auto-connect, a remote browser URL, or a persistent profile with this wrapper.
The wrapper returns only compact, redacted interactive labels and never returns a snapshot or field value.
Prefer the step result for verification and take a screenshot only when an expectation fails and visual evidence is needed.
