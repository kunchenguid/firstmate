# Captain decision PreToolUse gate

This document is the authoritative human-readable contract for the captain-facing decision gate.
`bin/fm-decision-pretool-check.sh` is the single policy and denial-message owner.
Tracked harness adapters only forward exact native tool identities and map the checker's exit status into their native blocking mechanism.
The durable Lavish request and answer protocol remains owned by `tools/lavish/README.md`.

## Purpose and boundary

Firstmate has no legitimate route through a primary harness's built-in structured-question tool.
A multi-option captain decision goes through `lavish-axi create`, and a yes/no goes through plain chat.
The gate therefore denies a confident exact-name match unconditionally.

It never reads question prose, options, option counts, Bash command text, or any other tool arguments.
Text that merely mentions a protected name is irrelevant.
There is no bypass flag, environment escape, or agent-controlled opt-out.
Plain chat is the intentional escape path because it is not a tool call.

## Exact tool identities

| Harness | Exact structured-question identity | Registration |
| --- | --- | --- |
| Claude | `AskUserQuestion` | `.claude/settings.json` matcher `^AskUserQuestion$` |
| Codex | `request_user_input` | `.codex/hooks.json` matcher `^request_user_input$` |
| Grok | `ask_user_question` | `.grok/hooks/fm-primary-decision-check.json` simple exact matcher |
| OpenCode | `question` | `.opencode/plugins/fm-primary-decision-check.js` exact `input.tool` equality |
| Pi | None in the built-in registry | No gate is registered |

The checker recognizes only those four exact byte strings.
Harness-side matching narrows each invocation to its own native identity before the checker runs.

## Transport and output

Claude and Codex send the complete PreToolUse JSON payload on stdin with the canonical name in `.tool_name`.
Grok sends its payload with the name in `.toolName` and uses `--grok` for its stdout decision shape.
OpenCode passes its already-separated `input.tool` value as one `--tool-name` argument.

An exact protected identity returns exit 2.
Claude and Codex receive a PreToolUse deny JSON object on stderr while stdout remains empty.
Grok receives `{"decision":"deny","reason":"..."}` on stdout.
OpenCode throws only after checker exit 2, using the checker's stderr as the tool error.

Empty stdin, malformed JSON, a non-string or missing tool identity, an unrelated identity, missing `jq`, and malformed CLI transport all return exit 0 with both streams empty.
That is transport fail-open, not a policy exception.
Once an exact identity is positively known, the decision fails closed.

The denial tells the agent both legitimate routes.
It gives the complete `lavish-axi create --id ... --title ... --request ... --questions ... --destination ...` shape, the lowercase-slug question-key and `value`/`label` option schema, the plain-chat yes/no route, and the captain-facing `Run: lavish answer <id>` surface line.

## Harness evidence, 2026-08-01

The local version probes were:

```text
$ claude --version
2.1.220 (Claude Code)

$ codex --version
codex-cli 0.146.0-alpha.9.2

$ command -v grok opencode pi
no installed command for any of the three harnesses
```

Claude's [official complete tools reference](https://code.claude.com/docs/en/tools-reference) names `AskUserQuestion`, and its [hook reference](https://code.claude.com/docs/en/hooks) lists that exact name as a PreToolUse matcher and documents `tool_name` plus `tool_input` on stdin.
A live Claude 2.1.220 interactive session in an isolated scratch directory called the real tool after implementation.
The TUI displayed `PreToolUse:AskUserQuestion hook error`, the stderr deny JSON, and the complete `[lavish-only]` guidance instead of opening the question UI.
Claude's next model-visible response began by explaining that the session uses Lavish instead of inline questions, which proved the teaching message reached the agent.

Codex's [current hook manual](https://developers.openai.com/codex/config-advanced/#hooks) says PreToolUse matches canonical `tool_name`, covers local function tools, and blocks on exit 2 plus stderr.
The installed binary contains `core/src/tools/handlers/request_user_input.rs`, the exact `request_user_input` function name, and the explicit diagnostic `request_user_input is not supported in exec mode`, which bounds the tool to interactive surfaces rather than disproving it with an `exec --help` search.
The current primary session also exposes that exact function-tool identity.

Grok was not installed locally, so its live TUI was not tested.
The official [`xai-org/grok-build` source](https://github.com/xai-org/grok-build/blob/explainx/crates/codegen/xai-grok-tools/src/implementations/grok_build/ask_user_question/mod.rs) contains the built-in `ask_user_question` implementation and describes it as structured questions and option sets both inside and outside plan mode.
The same source defines simple hook matchers as exact tool-name matches and maps Claude aliases onto Grok's native identity.
Grok's [official hook documentation](https://docs.x.ai/build/features/hooks) confirms `toolName` and `toolInput` stdin fields, stdout deny JSON, exit 2 blocking, and fail-open behavior for malformed hook execution.

OpenCode was not installed locally, so its live TUI was not tested.
The [official built-in tools reference](https://opencode.ai/docs/tools/) presents a complete list and includes `question`, whose documented uses include implementation decisions and ordered option choices.
The tracked OpenCode adapter uses the `tool.execute.before` mechanism already live-verified for this repo's watcher-arm seatbelt.

Pi was not installed locally, so its live TUI and user-plugin surfaces were not tested.
The [current upstream built-in registry](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/src/core/tools/index.ts) is an exhaustive `ToolName` union and `allToolNames` set containing only `read`, `bash`, `edit`, `write`, `grep`, `find`, and `ls`.
The tracked project extensions do not register a question tool.
Pi supports extension-defined interactive tools, but those are not built-ins and are outside this gate's declared scope.

The evidence commands were:

```sh
claude --version
codex --version
strings "$(command -v codex)" | grep -E 'request_user_input|requestUserInput'
gh-axi search code 'AskUserQuestionInput' --repo xai-org/grok-build
gh-axi search code 'ask_user_question' --repo xai-org/grok-build
gh-axi api /repos/xai-org/grok-build/contents/crates/codegen/xai-grok-tools/src/implementations/grok_build/ask_user_question/mod.rs --header 'Accept: application/vnd.github.raw+json'
gh-axi api /repos/xai-org/grok-build/contents/crates/codegen/xai-grok-hooks/src/matcher.rs --header 'Accept: application/vnd.github.raw+json'
gh-axi api /repos/earendil-works/pi/contents/packages/coding-agent/src/core/tools/index.ts --header 'Accept: application/vnd.github.raw+json'
```

The official references inspected were Claude's tools and hooks references, Codex's current hooks manual, Grok Build's hooks documentation and source, OpenCode's complete tools reference, and Pi's upstream tool registry and extension documentation.

## Automated validation

`tests/fm-decision-pretool-check.test.sh` is a pure stdin, stdout, stderr, and exit-status suite.
It never launches, signals, or inspects an agent session, tmux server, Herdr session, or worktree pool.

Run:

```sh
bash -n bin/fm-decision-pretool-check.sh
shellcheck bin/fm-decision-pretool-check.sh tests/fm-decision-pretool-check.test.sh
tests/fm-decision-pretool-check.test.sh
bin/fm-lint.sh
```
