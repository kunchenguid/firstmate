---
name: local-browser-verification
description: Load before pushing or opening a PR, or handing a no-mistakes ship to its pipeline, when the change is browser-visible, authentication, checkout, dashboard, or connected-backend work; use its server-only path for backend-only changes.
user-invocable: false
metadata:
  internal: true
---

# Local pre-publication verification

This skill is the single owner of the local verification contract for review-bound web and backend changes.

Classify the changed behavior before publishing it.
Browser-visible, authentication, checkout, dashboard, and connected-backend changes require the actual application to start from the current branch with credentials injected from outside the source tree.
Use Automic Vault when it is available, or another approved external secret manager or environment injection when it is not.
Never print, save, commit, screenshot, or paste credential values, tokens, cookies, or connection strings into task evidence.
Never weaken production authentication, authorization, payment controls, or other security boundaries to make this check pass.

For that browser-relevant class:

1. Start the real application and record the redacted startup command, URL, commit, credential source name, and startup result.
2. Use `chrome-devtools-axi` for the targeted browser flows changed by the task, recording each flow's action and observed result.
3. Exercise authenticated behavior when authentication is relevant, including the protected route and the relevant sign-in or session boundary.
4. Exercise checkout behavior with the approved test or sandbox account when checkout is relevant, without weakening production payment or authentication controls.
5. Exercise the relevant responsive viewport or layout behavior when the change can vary by viewport.
6. Exercise the connected backend through the real application when the change crosses that boundary, rather than replacing it with a mock.

Backend-only changes that have no browser-visible or browser-relevant surface use the local server-only path.
Run the relevant unit, integration, contract, migration, health, and external-service smoke tests for the changed backend surface with externally injected credentials where required.
Do not claim that a server-only check proves a browser flow, and do not add a browser requirement to a genuinely server-only change.

Before pushing or opening a PR, record the evidence in the task's private evidence report named by the brief.
The report records the tested commit, redacted startup or test commands, credential source without values, targeted flows and results, responsive or authenticated results when relevant, and any limitation or unavailable dependency.
A no-mistakes worker records the same evidence before handing the task to `/no-mistakes`; the pipeline does not replace this check.
A missing credential, unavailable local environment, failed startup, or unavailable targeted flow is a blocker.
Stop and report that blocker rather than skipping the check, opening a PR, or pushing an unverified branch.
