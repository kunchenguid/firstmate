---
name: pstack-verifier
description: Load only when `bin/fm-quality-profile.sh` prints `pstack` - at ship intake to decide the verifier risk class, and when a ship in that risk class reports a PR or ready branch.
user-invocable: false
metadata:
  internal: true
---

# pstack verifier

This skill applies only under the `pstack` quality profile.
Under the `default` profile, do not load it, and do none of the steps below.
[`docs/configuration.md`](../../../docs/configuration.md) "Quality profile" owns both settings, and `bin/fm-quality-profile.sh` owns their parsing.

The captain authorized one independent verifier scout for each ship in the risk class below.
The verifier runs on a model family other than Claude, so the check does not share the ship worker's blind spots.
It is not a review: it does not judge style, design, or scope, and it does not add a review round.
It can block the merge ask only with a failing run or a doc line the PR made wrong.

## Risk class

This section is the single owner of the risk class.
A ship is in the risk class when its change touches one or more of these areas:

1. Auth, permissions, or security.
2. Database schema or data migration.
3. Money: payments, billing, prices, or balances.
4. Clinical or legal logic.
5. Deletion of user data.

All other ships are outside the risk class and get no verifier.

## At ship intake

Decide membership at intake, from the captain's ask and the code the change will touch.
Record the result in the task's backlog note through `bin/fm-tasks-axi.sh`, as one line: `verifier: <area>` for a ship in the risk class, or `verifier: none`.
When later evidence shows that the change touches a risk-class area, update that line before the PR is ready.

## When a risk-class ship has a PR ready

Do these steps before the merge ask, and after the ship's own delivery path finished.

1. Run `bin/fm-quality-profile.sh verifier` to get the verifier's harness, model, and effort.
   When it refuses, tell the captain the setting error and continue without the verifier.
2. Check that this runtime is usable: the login is present and `quota-axi` shows quota for its provider.
   When it is not usable, tell the captain that the PR has no independent verifier and why, and continue without it.
   Never start the verifier on Claude or on any other runtime than the one the setting names.
3. Scaffold one scout with `bin/fm-brief.sh <ship-id>-verify <repo> --scout`.
   In its captain's intent, put the ship's captain's intent and the PR URL.
   In its Firstmate spec, tell the scout to:
   - check out the PR head commit;
   - load the project's `verify-<app>` skill when the project has one, and drive the app with it; otherwise run the project's own documented live check;
   - run the scenarios that the ship's change affects, and record pass or fail for each, with commands, output, and screenshots;
   - read the docs that describe the changed behavior, and list each doc line that the PR made wrong;
   - report findings only; change no code.
4. Spawn it with `bin/fm-spawn.sh`, passing the harness, model, and effort from step 1 explicitly.
   The verifier setting is the captain's choice for this scout, so do not route it through dispatch profiles.
   When the spawn refuses for a login or account reason, follow step 2's report-and-continue rule; do not retry on another runtime.
5. Supervise it as an ordinary scout, and handle its report through `scout-completion`.

## Using the verifier's result

- A failing run, or a doc line the PR made wrong, blocks the merge ask.
  Send the finding with its evidence to the ship worker as a fix, and let the ship's delivery path validate the fix again.
  When the fixed PR is ready, run one more verifier on the new head.
  When that second run also fails, give the captain the PR URL and both reports, and ask how to continue.
- Every other finding is a note.
  Give it to the captain with the merge ask; it does not hold the merge.
- A pass goes with the merge ask as independent evidence, with the report path.

Standing `yolo` merge authority does not cover a PR whose verifier run failed.
