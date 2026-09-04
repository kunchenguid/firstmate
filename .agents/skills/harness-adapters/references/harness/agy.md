# Antigravity (agy)

Verified for crew, scout, and secondmate work on 2026-09-01 with Antigravity CLI 1.1.23.
Cross-harness provider and credential identity is owned by `references/common/model-and-effort.md`.

## Operating facts

| Fact | Value |
|---|---|
| Binary | `resolve_agy_binary` in `../../../bin/fm-spawn.sh` resolves `agy` from `PATH`, then `$HOME/.local/bin/agy`; spawning refuses if neither exists. |
| Launch | Positional brief with `--dangerously-skip-permissions`, `--prompt-interactive`, optional `--model <model>`, and optional `--effort <low|medium|high>`. |
| Default model and effort | Economically pinned to `gemini-3.7-flash` and `medium` by default; explicit CLI flags or dispatch profiles override this default. |
| Models | Gemini 3.7 Flash (`gemini-3.7-flash`, `gemini-3.7-flash-high`, `gemini-3.7-flash-medium`, `gemini-3.7-flash-low`), Gemini 3.6 Flash (`gemini-3.6-flash`), Gemini 3.1 Pro (`gemini-3.1-pro`), Claude Sonnet 4.6 (`claude-sonnet-4-6`), Claude Opus 4.6 Thinking (`claude-opus-4-6-thinking`), GPT-OSS 120B (`gpt-oss-120b-medium`); see `agy models`. |
| Busy state | Semantic busy contract armed via `agy-hook`: `PreInvocation` plugin hook marks busy, and `Stop` plugin hook marks idle when `fullyIdle=true`. |
| Exit command | `/exit` (also accepts `/quit`). |
| Interrupt | Single Escape returns to the empty composer with no clear key needed. |
| Skill invocation | Firstmate internal skills discoverable; standard prompt integration. |
| Resume | Native session resumption supported via `agy --conversation=<conversation-id>`; deterministic relaunch also supported. |
| Autonomy | `--dangerously-skip-permissions` runs tool executions autonomously without prompting for approvals. |
| Trust | `--dangerously-skip-permissions` bypasses the workspace trust prompt on fresh worktree paths. |
| Marker | `ANTIGRAVITY_AGENT=1` set on child and tool processes; process comm is `agy`. |
| Effort | `--effort <low|medium|high>` supported and passed to CLI; `references/common/model-and-effort.md` owns unsupported-value handling. |
| Composer | Horizontal rule container (`───────────────────`) containing prompt `>` with footer displaying shortcuts and active model. |

## Detection

`../../../bin/fm-harness.sh` detects `agy` from the `ANTIGRAVITY_AGENT=1` environment marker in Layer 1, and from process comm `agy` in Layer 2.
Foreign markers (`CLAUDECODE`, `PI_CODING_AGENT`, `GROK_AGENT`, `FM_PI_HARNESS`, `CURSOR_AGENT`, `CURSOR_INVOKED_AS`) are cleared before launch in `../../../bin/fm-spawn.sh`.

## Global plugin hooks and turn-end notification

`../../../bin/fm-agy-turnend-hook.sh` manages Firstmate's dedicated plugin at `$HOME/.gemini/config/plugins/firstmate/`.
The plugin registers two hooks:
1. `PreInvocation`: Fired before every agent turn, emitting an `apply busy` event with source `agy-hook`.
2. `Stop`: Fired when an agent invocation finishes.
   When `fullyIdle` is `true`, it touches `state/<id>.turn-ended` and emits an `apply idle` event with source `agy-hook`.
   When `fullyIdle` is `false` (e.g. background subagent work continuing), it leaves `turn-ended` untouched and keeps the busy state active.

Each task receives a worktree pointer `.fm-agy-turnend` and a state token `state/<id>.agy-turnend-token`, authenticated through `$HOME/.gemini/config/plugins/firstmate/fm-turn-end.d/<token>`.
Every hook script invocation outputs valid JSON `{}` on stdout and exits zero.
