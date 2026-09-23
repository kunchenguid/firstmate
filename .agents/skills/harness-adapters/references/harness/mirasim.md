# Mirasim Claude wrapper

Mirasim `0.0.303` is verified as a crewmate and scout route that wraps Claude Code `2.1.278` through the existing authenticated Mirasim relay.
It is not a separate agent engine.
`../../../../../bin/fm-spawn.sh` therefore records `harness=mirasim` for routing and recovery while reusing Claude's trust, task-control, busy-hook, composer, interrupt, exit, and cleanup owners.

## Operating facts

| Fact | Value |
|---|---|
| Binary | `fm-spawn.sh` resolves `mirasim` to an absolute executable from Firstmate's `PATH` during preflight, then invokes that path as `<resolved-mirasim> claude`. |
| Launch | The Claude launch template with `mirasim claude` replacing the bare `claude` executable. |
| Busy | Claude `UserPromptSubmit`, `Stop`, `StopFailure`, and `SessionEnd` hooks write the existing `claude-hook` state. |
| Exit | `/exit`. |
| Interrupt | Single `Escape`; the control plane records the same explicit interrupt close as Claude because Claude emits no closing hook for this path. |
| Skill | Claude's `/<skill>` form. |
| Trust | `../../../../../bin/fm-claude-trust.sh` pre-registers the worktree before launch. |
| Permissions | The home-local Claude permission mode applies unchanged. |
| Model | `--model <id>` passes through the wrapper. Quote ids containing brackets, such as `claude-fable-5-1[1m]`; `fm-spawn.sh` shell-quotes every concrete model value. |
| Effort | `--effort low\|medium\|high\|xhigh\|max` passes through the wrapped Claude CLI. |
| Resume | No native pane-resume contract is added; deterministic relaunch reuses the brief and recorded Mirasim profile. |

## Model and provider boundary

Run `mirasim ui-cli catalog --agent claude` against the current authenticated environment before selecting a model.
The catalog proves which ids Mirasim currently advertises and which effort values its UI accepts.
A successful prompt proves that the requested id completed through the Mirasim route, but it does not prove which upstream model served the request.
Do not infer provider identity or quota coverage from the catalog label, response text, or requested id.

## Supported scope

Crewmate and scout launch, steering, busy/completion hooks, interrupt, exit, and deterministic relaunch are supported through Claude's existing owners.
Primary and secondmate use are unsupported.
No Mirasim-specific primary marker, session-start delivery, turn-end guard, or watcher protocol has been verified, so `fm-spawn.sh` refuses a Mirasim secondmate.

## Verification

[`../../../../../docs/verification/mirasim.md`](../../../../../docs/verification/mirasim.md) records the current portable and credentialed live evidence.
The live guard sends only a fixed synthetic prompt from a temporary empty directory and reports requested model identity separately from served identity.
