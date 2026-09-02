# Prime Agent

Verified crewmate/scout only on 2026-08-23, Prime Agent 0.8.0.
Never a secondmate or primary: Prime 0.8.0 does not emit Pi's `agent_settled` event and its primary watcher extensions have not been verified against Prime's `agent_end` boundary.
`../../../bin/fm-spawn.sh` refuses `--secondmate` rather than assuming Pi's primary supervision contract.

Prime Agent is a Pi-family CLI with its own executable identity and lifecycle surface.

## Operating facts

| Fact | Value |
|---|---|
| Busy state | The Firstmate-owned `prime-ext` extension uses one process-global coordinator keyed by task and busy generation to aggregate root and inline-child lifecycle events across uncached extension instances and serialize every state write; it keeps busy while any session remains active, tracks compaction from `session_before_compact` through the next continuation `agent_start`, and tracks unproven terminality per session so the same session's retry can clear it; Prime exposes no task-wide settled event, so every inactive state reports unknown rather than inventing idle, while `turn_end` remains the watcher notification touch; Prime 0.8.0 loaded the absolute `-e` extension from outside the project without a trust dialog and did not emit `agent_settled`. |
| Exit command | `/quit`; a session-enabled exit prints `Resume this session with: prime-agent --resume <id>`. |
| Interrupt | Single Escape; a live Python tool call stopped and the extension emitted `turn_end` followed by `agent_end`. |
| Skill invocation | `/skill:<name>`, for example `/skill:no-mistakes`. |
| Composer | A bordered shell-glyph composer with `>` and a dark truecolor idle suggestion such as `Try "refactor @<filepath>"` is already covered by the shared bordered-placeholder classifier, while elapsed `Thinking · Ns`, `Waiting · Ns`, and `Executing · Ns` spinners are delivery acknowledgements rather than worker state. |
| Detection | Exact `prime-agent` executable or package ancestry precedes the shared `PI_CODING_AGENT=true` fallback because `AI_AGENT=pi` is not an identity signal. |
| Model flag | `--model <id>`. |
| Effort flag | `--thinking <off\|minimal\|low\|medium\|high\|xhigh\|max>`; `off` and `minimal` stay outside Firstmate's shared vocabulary. |
| Model discovery | Run `prime-agent model list`; `prime-agent --help` owns the accepted `--model <id>` input shape. |

Keep the brief as one positional argument through the canonical `fm-operational-input.sh encode launch-brief` envelope.
The launch clears stale foreign markers (`PI_MODEL`, `PI_CODING_AGENT`, `AI_AGENT`, `FM_PI_HARNESS`) that a Pi-family primary leaks into the spawn environment, because a worker inherited the primary's `PI_MODEL` and self-reported the wrong model (verified live 2026-08-24); Prime sets its own `PI_CODING_AGENT=true` for children, so clearing the inherited value cannot blind ancestry-based detection.
Prime accepts `--model <id>`, repeatable `-e`, and `--thinking off|minimal|low|medium|high|xhigh|max`; Firstmate routes only its shared low-through-max effort axis.
A live `--thinking low` launch rendered `high` in Prime's footer, so treat the 0.8.0 effective-level behavior as unconfirmed even though the CLI accepts and Firstmate preserves the flag.
Firstmate admits raw launches only when the resolved, non-writable executable is `echo`, `sleep`, `true`, `false`, `cat`, `printf`, `test`, or `ls` under `/bin`, `/sbin`, `/usr/bin`, or `/usr/sbin`, rejects every other raw command at the Prime isolation boundary, and gives every canonical Prime launch a stable project-keyed `HOME` and `PRIME_AGENT_CODING_AGENT_DIR` under its own state root.
[`docs/configuration.md`](../../../docs/configuration.md#harness-support) owns the isolated credential setup and the Prime 0.8.1 minimum-version boundary.
