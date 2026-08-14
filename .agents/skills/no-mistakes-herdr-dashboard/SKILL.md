---
name: no-mistakes-herdr-dashboard
description: >-
  Agent-only procedure for opening one native no-mistakes attach surface beside
  a Herdr crewmate after its headless pipeline driver records a run id and HEAD.
user-invocable: false
metadata:
  internal: true
---

# Native no-mistakes attach surface

Load this immediately after the headless pipeline driver starts one native run and records its exact run id and checked-out HEAD.
The installed no-mistakes skill and live AXI help remain the authority for pipeline custody, gates, fixes, push, PR, and CI.

Read `bin/fm-no-mistakes-attach.sh --help`; its header owns the exact invocation and Herdr mutations.
From the implementation repository, give the helper that exact run id and HEAD.
The operation must run inside the driver's pane so injected Herdr identity places the unfocused sibling split.

- `attached` means the sibling runs the native attach surface for that exact run and HEAD.
- `not-applicable` means the crewmate is not running under Herdr, so existing behavior continues unchanged.
- Any error preserves the branch and stops attach placement without starting a second pipeline operation.

The helper verifies that the checkout still equals the supplied HEAD before placement.
The visible sibling executes only native `no-mistakes attach --run <id>`.
It neither starts nor polls, retries, aborts, or otherwise drives the pipeline run.
The implementation crewmate remains the sole pipeline driver, and the pipeline agent stays headless.
The visible surface is native attach only, never a Codex conversation, transcript, or reconstructed agent UI.

The sibling is an ordinary Herdr split.
Firstmate keeps no attach journal, does not recreate or retire the surface, and does not make teardown depend on it.
Close the pane manually after the native attach command exits.
