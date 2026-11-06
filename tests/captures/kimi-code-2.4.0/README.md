# Kimi Code CLI 2.4.0 folder-prompt capture

This file is the visible pane of the real Kimi Code CLI 2.4.0 folder prompt in a git checkout whose project instructions are `AGENTS.md`.
It was recorded on 2026-10-29 on Linux from `herdr pane read --source visible` after `kimi --auto` had painted the prompt, with the shell scrollback above the prompt dropped and the launch directory replaced by `{WORKDIR}`.
The horizontal rules are as wide as that pane.
Kimi 2.4.0 keeps the 2.3.0 option pair, `❯ Trust and continue` and `Exit`, and the same title and navigation hint.
When the directory has project instructions, the disclosure between the directory and the footer reads `Load project instructions` over `Check: <path>` instead of `No project integrations or instructions to activate.`
That disclosure is not a project MCP announcement.
`bin/fm-kimi-trust-lib.sh` still treats the pane as the complete dialog, and `bin/fm-spawn.sh` answers it with Enter.
The portable replay is `test_kimi_240_prompt_that_loads_project_instructions_is_answered_and_verified` in `tests/fm-kimi-harness.test.sh`.
Whether the installed Kimi still renders a prompt the predicates accept is the live guard's question: `tests/fm-kimi-trust-prompt-live-e2e.test.sh`.
