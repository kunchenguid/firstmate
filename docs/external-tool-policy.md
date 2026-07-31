# Ship external-tool policy

This document owns the machine-readable authorization contract for controlled external tools used by ship workers.
`bin/fm-external-tool-command-policy.mjs` is the single semantic owner.
`bin/fm-external-tool-pretool-check.sh` only translates harness payloads and deny responses.
`bin/fm-spawn.sh` installs thin harness adapters and refuses a ship when reliable before-tool interception is unavailable.

## Purpose

A natural-language brief can tell a worker which external tools to use, but it cannot prevent a mistaken command.
Every generated ship brief therefore carries an executable authorization policy that the selected harness checks before each tool call.
Generated scout briefs carry the same policy so a protected scout can later become a ship without restarting its live worker.
The checker reads the policy directly from the brief on every decision.
No copied allowlist in task state, metadata, adapter code, or configuration can become a second authorization source.

## Brief format

A generated ship or scout brief contains exactly one `firstmate-external-tools` fenced JSON block.
The JSON schema identifier is `firstmate.external-tools.v1`.
The object has exactly three keys: `schema`, `shell`, and `native`.
The `shell` and `native` objects each contain exactly one `allow` array of literal tool names.
Duplicate names, unknown keys, missing keys, malformed JSON, a missing fence, or a second fence invalidate the policy.

The standard generated policy authorizes `gh-axi` and `chrome-devtools-axi` through shell execution.
It authorizes the native `agent_browser` tool as the browser fallback.
It does not authorize the shell command `agent-browser`.
A task that deliberately needs another controlled tool must add that tool to the correct allow array in its brief before spawn.

## Controlled tools and ordinary development

The policy controls external GitHub clients, browser automation systems, browser binaries, browser drivers, and browser installation packages.
It recognizes browser families such as Playwright, Puppeteer, Selenium, WebdriverIO, Cypress, TestCafe, Nightwatch, browser-use, browser drivers, Chromium, Chrome, and Firefox.
It recognizes direct executables, package runner forms, targeted dependency installation, Python modules, Node CLI paths, and targeted system-package installation.

The policy does not turn package managers into a blanket deny list.
Tests, lint, builds, local servers, ordinary package installation, and other project development commands remain allowed unless they execute a controlled tool.
A data mention in `printf`, search text, a comment, or another non-executed argument is not a tool request.

## Shell classification

`bin/fm-arm-command-policy.mjs` remains the sole shell lexer and command-position owner.
The external-tool policy imports its execution-tree walker instead of implementing another shell parser.
The walker covers direct commands, wrappers, pipelines, redirections, command and process substitutions, parenthesized groups, literal `eval`, literal `sh`, `bash`, or `zsh` command payloads, heredocs, and here strings.
A pipeline or redirection does not hide the controlled executable because each executed command position is classified before the outer shell starts.
Malformed or opaque shell input that visibly names controlled browser automation is denied rather than guessed safe.

The policy addresses mistaken tool selection, not hostile code already hidden inside a project script.
The worker still follows the brief boundary against editing operational files outside its isolated copy.

## Denial contract

An unauthorized request exits with status 2 before the harness executes the requested tool call.
The stable reason code is `external-tool-denied`.
The message names the requested canonical tool, its shell or native channel, the `firstmate.external-tools.v1` policy and brief path, and the authorized alternatives for that category.

An unavailable checker, malformed hook payload, missing Node.js or `jq`, missing brief, or invalid policy exits with status 2 and the stable reason code `external-tool-policy-error`.
Spawn validates the checker and brief before endpoint launch, while runtime failures remain closed if that validated dependency later disappears.
A legacy or adapter-verification scout without the policy fence may run only as a scout and records no enforcement receipt.

## Harness adapters

| Harness | Before-tool connection | Ship behavior |
| --- | --- | --- |
| Claude | Generated `.claude/settings.local.json` `PreToolUse` matcher for every tool | Checker exit 2 returns Claude's stderr-only native deny object. |
| Codex | Generated `.codex/hooks.json` `PreToolUse` matcher for every tool | Spawn refuses an existing project hook file, then launches with hook trust bypassed only for the generated task hook. |
| OpenCode | Generated `.opencode/plugins/fm-external-tool-policy.js` | `tool.execute.before` throws on every nonzero checker result. |
| Pi | Generated state extension loaded with `-e` | `tool_call` returns `{block: true}` on every nonzero checker result. |
| pi-signed | Same generated Pi extension and `tool_call` contract | The signed executable identity remains distinct while policy behavior matches Pi. |
| Grok | Guarded global `PreToolUse` hook plus a private per-task registration token in the launch environment | The global hook is inert outside a registered ship and returns Grok's native deny object for that ship. |
| Kimi | No reliable before-tool interception has been verified | Ship spawn is refused before harness installation or endpoint creation. |
| Cursor | Cursor is not a verified Firstmate harness, and its installed CLI exposes no verified before-tool adapter | Named and raw Cursor ship launches are refused before endpoint creation. |

Claude and Codex refuse to replace a pre-existing project hook path because silently merging or overwriting another owner's hook would make enforcement ambiguous.
OpenCode uses a Firstmate-specific plugin path.
Pi keeps its explicit extension outside the project to preserve its existing trust behavior.
Grok uses its already verified always-trusted global hook surface because project hooks require folder trust before launch.

## Runtime backends

The runtime backend does not classify tools.
The five spawn-capable backends `tmux`, `herdr`, `zellij`, `orca`, and `cmux` all converge in `bin/fm-spawn.sh` after the isolated worktree is resolved.
Spawn installs the selected harness adapter at that common point and only then submits the harness launch command.
This keeps one semantic policy across backends and preserves each backend's existing endpoint, supervision, and cleanup behavior.

Teardown removes only Firstmate-owned generated project artifacts and private Grok registration tokens.
It does not remove a project-owned Codex or OpenCode file that lacked the Firstmate ownership marker.

## Scout promotion

Spawn records `external_tool_policy=enforced` only after the declared brief policy validates and its harness adapter is installed.
`bin/fm-promote.sh` requires that receipt and revalidates the same brief before changing `kind=scout` to `kind=ship`.
A legacy scout, raw-adapter scout, Kimi scout, or other worker without reliable interception cannot become a live unprotected ship.
The promotion command refuses that case and requires a new generated ship brief.

## Verification

[`verification/external-tool-policy.md`](verification/external-tool-policy.md) records the current harness and backend review evidence.
`tests/fm-external-tool-policy.test.sh` owns the executable incident, bypass, allowed-command, adapter, and refusal matrix.
`tests/fm-brief.test.sh` owns generated brief integrity.
