# Antigravity CLI (AGY)

AGY is Google's `agy` CLI, distinct from the `gemini` CLI adapter.
Verified for ordinary ship and scout workers on tmux and Herdr only.
Primary and secondmate supervision are unsupported and refused; zellij, Orca, and cmux placement is also refused because their AGY composer/lifecycle evidence is unverified.
`../../../bin/fm-spawn.sh` owns launch mechanics, `../../../bin/fm-agy-lib.sh` owns catalog preflight, and `../../../docs/verification/runtime-backends.md` ("Antigravity CLI (AGY) workers") records the actual live checks.

## Launch, isolation, and trust

The interactive launch uses `--prompt-interactive` with one quoted, routing-marked instruction argument and `--dangerously-skip-permissions` for unattended tools.
`--new-project` plus `--add-dir` binds AGY's tool workspace to the task's isolated copy.
Do not omit this binding: launching AGY from a directory alone can leave its command tool in AGY's shared scratch directory even while the TUI displays the intended path.
An added task-private customization directory carries Firstmate's hooks without replacing the project's `.agents/hooks.json` or modifying the operator's global settings.
AGY persists its own project/conversation history; Firstmate does not delete that vendor-owned history on cleanup.
`AGY_CLI_DISABLE_AUTO_UPDATE=true` prevents worker sessions from replacing the executable mid-task.

A fresh directory can still show `Do you trust the contents of this project?` despite the permissions flag.
The documented default is `Yes, I trust this folder`; one Enter accepts that exact folder.
Only answer this identified folder-trust dialog, then prove instructions are processing; never type into an account-verification or login prompt.
The launch flag auto-approves tool use, not every first-run dialog or custom hook policy.

## Authentication and models

Use AGY's [installation/authentication documentation](https://antigravity.google/docs/cli/install) and [CLI reference](https://antigravity.google/docs/cli/reference).
The operator must complete AGY's own sign-in and any Google account-eligibility verification before dispatch.
A successful `agy models` listing is not proof that the account can execute prompts; the live guard submits a trivial prompt and requires a successful result.
Never change account/provider settings or copy secrets into launch commands to work around a refusal.

Discover exact IDs with `agy models` in the active environment.
The adapter requires an explicitly listed Gemini ID rather than relying on vendor defaults, display names, or inferred aliases.
The live catalog included `gemini-3.8-flash-low`, `gemini-3.8-flash-medium`, and `gemini-3.8-flash-high`; availability is not a permanent promise.
AGY also lists non-Gemini models, but they are outside this adapter's verified scope.
`--effort` accepts `low`, `medium`, and `high` and can replace the effort suffix of a model selection.
Firstmate refuses a conflict between an explicit suffixed model and native effort instead of silently changing the selected variant.
Unsupported efforts follow the common record-and-omit policy; choose matching native values in dispatch profiles.

Use Flash-class profiles for bounded, well-specified changes with concrete acceptance tests, not as a quota-driven downgrade for ambiguous or high-impact work.
`../../../docs/configuration.md` ("Bounded Gemini Flash work through AGY") owns the profile example; no live dispatch configuration is changed by adding this adapter.

## Identity, state, and control

| Fact | Verified behavior |
| --- | --- |
| Detection | Exact `agy` process ancestry. Firstmate's `FM_AGY_HARNESS=agy` precedence marker requires that ancestry and is not proof by itself; the launch clears foreign markers. |
| Busy | Native `PreInvocation` feeds `agy-hook` through the generation-bound busy writer. Repeated model invocations stay busy. |
| Completion | Native `Stop` closes only when `fullyIdle` is boolean true and the workspace, conversation, and generation match. A subagent's Stop cannot settle the parent. |
| Composer | Horizontal separators enclosing `>`; only live AGY identity authorizes interpreting this shell-like glyph as an agent composer. |
| Steering | Ordinary literal text plus Enter, with a resulting tool artifact proving actual processing. External task-report writes were verified. |
| Interrupt | One Escape, no composer repollution. AGY emits no Stop for the observed cancellation; the control plane reports delivery, not semantic cancellation proof. Busy state conservatively remains busy until another turn completes or the process exits. |
| Exit | `/exit` plus Enter; preserves the endpoint and work. |
| Recovery | Deterministic relaunch from the durable instructions, with a fresh generation and conversation binding. Profile preflight occurs before stopping the old agent; native `--conversation <id>` is documented but not the managed recovery path. |
| Skills | Workspace `.agents/skills` is documented by AGY; use explicit natural-language file instructions when slash discovery has not been verified. No assumption that Gemini CLI's global skills paths apply. |

`../../../bin/fm-control-lib.sh` owns executable control capabilities and `../../../bin/fm-composer-lib.sh` owns the shared composer rules.
The rendered `esc to cancel` footer is delivery evidence only, not the task-state source.
Custom keybindings, plan-mode policies, permission hooks, and non-default composer placeholders can require operator intervention; rerun the live guard after changing them or upgrading AGY.
Built-in browser tooling is outside the verified contract; use the task's prescribed browser tool rather than assuming AGY's bundled browser dependencies work.
