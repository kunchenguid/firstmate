# Kimi Code CLI 2.3.0 folder-prompt captures

These files are the visible pane of the real Kimi Code CLI 2.3.0 folder prompt, one per wording the `test_kimi_230_*` cases in `../../fm-kimi-harness.test.sh` replay through the fake pane.
They were recorded on 2026-10-23 on Linux with tmux 3.6, from `kimi --auto` launched bare with a fresh, isolated `HOME` and `KIMI_CODE_HOME` and the updater off (`KIMI_CODE_NO_AUTO_UPDATE=1`), with no login.
Kimi Code CLI 2.3.1, released the same day, rendered every capture byte for byte the same apart from the directory line.

## Capture provenance

Each capture is unchanged `tmux capture-pane -p` output of the pane after the prompt painted, with trailing blank rows dropped and the launch directory replaced by `{WORKDIR}`.
The replay substitutes only that token with the fake pane's path.
The directories lived under a temporary root outside any git checkout, because Kimi resolves a root `.mcp.json` at the git worktree root when the launch directory is inside one.

| File | Pane | Directory | What the prompt shows |
| --- | --- | --- | --- |
| `plain.pane` | 120x40 | Empty | `No project integrations or instructions to activate.` |
| `root-mcp-json.pane` | 120x40 | One stdio server in a root `.mcp.json` | `Start 1 MCP server automatically` over `Config: .mcp.json` |
| `kimi-code-mcp-json.pane` | 120x40 | The same server in `.kimi-code/mcp.json` | `Start 1 MCP server automatically` over `Config: .kimi-code/mcp.json` |
| `small-terminal.pane` | 100x7 | The root `.mcp.json` directory | The title over `Enlarge terminal to review sources. Esc exit.`, and Kimi ignores Enter |
| `paged.pane` | 100x12 | The root `.mcp.json` directory | The complete dialog with `←→ page · 1 / 5` in place of the announcement |

The declared server's command appends a line to a marker log.
Pressing Enter on the `root-mcp-json.pane` prompt in the same lab started that command before any login, which is what the fake pane reproduces when a key reaches an announcing or paged prompt.

## Replay limits

The replays prove how `bin/fm-spawn.sh` answers these exact panes.
Whether the installed Kimi still renders them is the live guard's question: `tests/fm-kimi-trust-prompt-live-e2e.test.sh`.
