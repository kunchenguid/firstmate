---
name: no-mistakes-herdr-dashboard
description: >-
  Agent-only procedure for preparing the native no-mistakes attach dashboard
  beside a Herdr crewmate immediately before that crewmate starts no-mistakes.
user-invocable: false
metadata:
  internal: true
---

# No-mistakes Herdr dashboard

Load this immediately before the same implementation crewmate invokes the
installed no-mistakes skill. The installed skill and live AXI help remain the
authority for pipeline custody, gates, fixes, push, PR, and CI.

Read `bin/fm-no-mistakes-attach.sh --help`; its header owns the exact invocation,
wait boundary, and Herdr mutations. Have the implementation crewmate run the
helper's prepare operation from its repository before invoking no-mistakes.
The operation must run inside that crewmate's pane: injected Herdr identity is
the placement authority for the sibling split.

- `prepared` means the sibling exists and is waiting; immediately invoke the
  installed no-mistakes skill on that same crewmate.
- `not-applicable` means the crewmate is not running under Herdr; continue with
  the existing no-mistakes behavior unchanged.
- Any error stops launch. Preserve the branch and report the exact failure to
  Firstmate instead of starting AXI without the requested dashboard.

The sibling polls only `no-mistakes axi status` in the same repository. Once it
observes a nonterminal run for the crewmate's exact branch, it executes native
`no-mistakes attach --run <id>`. It never calls `axi run`, `axi respond`, or any
branch-mutating command. The implementation crewmate remains the sole AXI
driver, and the native pipeline agent remains headless rather than becoming a
second Herdr crewmate.

The native dashboard is interactive. Focus the sibling pane and use its own
keyboard navigation (`j`/`k`, `g`/`G`, `Ctrl-d`/`Ctrl-u`, arrows, Home, and End)
instead of Herdr scrollback. Direct actions taken there by the captain are
authoritative. Before the crewmate answers the same gate, it must reconcile the
dashboard action from its one returned AXI call or one `axi status` read and
must not submit a duplicate response.

The sibling is an ordinary Herdr split. Firstmate keeps no dashboard journal,
does not recreate or retire it, and does not make teardown depend on it. Close
the pane manually after the run is terminal. If no nonterminal run appears
within the helper's bounded wait, the pane exits with a visible error.
