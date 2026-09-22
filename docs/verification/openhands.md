# Verification: the openhands (OpenHands SDK) crewmate/scout adapter

Active empirical facts for firstmate's openhands adapter.
The skill tree rooted at [`.agents/skills/harness-adapters/SKILL.md`](../../.agents/skills/harness-adapters/SKILL.md) owns the operating facts through [`references/harness/openhands.md`](../../.agents/skills/harness-adapters/references/harness/openhands.md); this record owns how they were established and what is still unproven.

## Subject

| Field | Value |
|---|---|
| Driver | `bin/fm-openhands-worker.py`, firstmate-owned; the pane runs it under the resolved OpenHands venv interpreter, never a vendor CLI |
| SDK | `openhands-sdk 1.34.0`, `openhands-tools 1.34.0`, `openhands-agent-server 1.34.0`, `litellm 1.84.1`, `openhands-ai 1.11.0` (the venv at `~/.config/openhands/venv` on the reference host) |
| Verified | 2026-09-19 (portable contract and spawn surface; live guard below the same day) |
| Platform | Linux x64 for the live guard (tmux backend); the portable suite additionally ran on macOS x64 (darwin 24.6.0) with real processes and no SDK |
| Backend | tmux, an isolated non-default socket (`fm-openhands-signals-*`); no fleet state was touched |

Every command below ran inside the firstmate repository checkout or the named isolated lab.
No captain fleet state was touched.

## Detection: marker plus args-strength ancestry, never the fragment

```
$ ./tests/fm-openhands-harness.test.sh
ok - fm-harness.sh: ancestry detects the driver process at args strength
ok - fm-harness.sh: the FM_OPENHANDS_HARNESS marker is precedence only
ok - fm-harness.sh: the args anchor is the full driver filename, never the fragment
ok - fm-harness.sh: the launch boundary's cleared markers are what make driver ancestry decide
```

The pinned cases drive `bin/fm-harness.sh` against a faked `ps` that reports a `python3.12` process whose arguments carry the full `fm-openhands-worker.py` filename.
The marker `FM_OPENHANDS_HARNESS=openhands` identifies openhands only when that ancestry evidence exists, and alone it changes nothing.
An unrelated `python3 -m openhands.server` and an unrelated script path carrying the openhands fragment both fail to match, because the anchor is the firstmate-owned filename.
A retained `CLAUDECODE=1` still outranks the args-only ancestry - the documented marker-names-its-harness rule - which is exactly why the launch clears every foreign marker, and with the cleared boundary the driver ancestry decides.
The shared match helper is owned by `bin/fm-openhands-lib.sh`, and `fm_agent_process_classify` uses the same rule so a liveness probe names the pane through the flattened args (pinned by `tests/fm-tmux-agent-liveness.test.sh` passing unchanged).

## Launch, preflights, and the spawn surface

```
$ ./tests/fm-openhands-harness.test.sh
ok - fm-spawn: openhands launch carries driver, model, wiring, and cleared markers
ok - fm-spawn: an omitted model stays out of the launch and rides the profile
ok - fm-spawn: openhands omits effort from the launch but records it in task metadata
ok - fm-spawn: an invalid model string refuses before pane creation
ok - fm-spawn: a missing venv refuses before pane creation
ok - fm-spawn: an SDK import failure refuses before pane creation
ok - fm-spawn: a missing credential profile refuses before pane creation
ok - fm-spawn: an incomplete credential profile refuses before pane creation
ok - fm-spawn: openhands cannot be launched as a secondmate
ok - fm-spawn: a relaunch never folds a predecessor's open run
```

The spawn cases run the real `bin/fm-spawn.sh` against a stub venv interpreter that answers the SDK import probe and refuses to execute anything else, a real fixture home with `config/openhands-llm.env` (chmod 600), and a fake tmux that records the launch line.
The recorded launch pins the resolved interpreter, the driver, `--llm-env`, `--run-log state/<id>.openhands-run`, `--turn-end`, the requested model, `FM_OPENHANDS_HARNESS=openhands`, and the cleared foreign markers, with no placeholder left unsubstituted.
Every preflight refusal fires before the launch line exists, and the truncation case proves a relaunch starts from an empty run log.

## Busy state: the run-log fold

```
$ ./tests/fm-openhands-harness.test.sh
ok - fm-busy-lib: the run-log fold trusts open and close, and nothing else
ok - fm-busy-lib: openhands classifies through its run log and nothing else
ok - fm-composer-lib: the openhands delivery row is scoped and never borrowed
```

The fold cases write real JSONL sidecars and assert busy on an unmatched `run_started`, settled on a trailing `run_terminal` with `completed` or `cancelled`, unknown on a malformed line, `none` on an empty log, and a hard fail on a missing file.
`fm_busy_classify` reads only the run log for `harness=openhands`, and the delivery row `[fm-openhands] working` is scoped: idle and cancelled rows never acknowledge, echoed output without the bracketed literal never acknowledges, no other harness borrows it, and the harness-less union includes it for submit acknowledgement exactly like agy's footer.

## The driver's own contract, including the interrupt path

```
$ ./tests/fm-openhands-harness.test.sh
ok - fm-openhands-worker.py: run pairs, turn-end, steering, and /exit all hold
ok - fm-openhands-worker.py: SIGINT closes the run pair as cancelled and exits 130
```

The driver cases run the real `bin/fm-openhands-worker.py` under the host's real `python3` in `--selftest` mode: one brief run appends exactly one `run_started`/`run_terminal` pair and touches the turn-end marker, a stdin steer appends its own pair, `/exit` and `/quit` both stop it, and the log folds settled afterwards.
The interrupt case holds a stub run open with `--selftest-hold 30`, waits for the started record, delivers exactly one SIGINT, and asserts exit 130, the `terminal=cancelled` close, the turn-end touch, and a settled fold.
One platform fact is pinned by the same case: a background child without job control inherits SIGINT ignored and Python then leaves it ignored, so the test enables job control for the launch only - the real pane always carries the default disposition.

## Live guard against the real SDK

```
$ FM_OPENHANDS_SIGNALS_LIVE=1 ./tests/fm-openhands-signals-live-e2e.test.sh
ok - the real run log folds busy while the SDK turn is in flight
ok - the real SDK worker answered its launch prompt
ok - the settled pane's last firstmate row is idle, not an acknowledgement
ok - the settled run folds idle, touches turn-end, and stops acknowledging
ok - a single C-c cancels the real run and stops the driver
```

The guard is opt-in (`fm_live_gate opt-in FM_OPENHANDS_SIGNALS_LIVE tmux`) because it submits real prompts through the configured provider.
It launches the real driver under the real venv interpreter in an isolated tmux socket, with the real `config/openhands-llm.env` profile, inside a throwaway git workspace.
It requires the working delivery row to render while the turn runs, the fold to go busy then settled, the computed answer (12345+67890) to land, the turn-end marker to be touched, a steered long run to open its pair, and a single C-c to close it as cancelled and stop the process.

Two live-only platform facts were fixed by this guard on the reference host, and each is pinned in the driver:

- **Quiet pane**: the SDK's `cli_mode=True` rendering floods stdout/stderr with rich panels (system prompt, tool schemas, token counters - hundreds of lines within seconds of a run opening), which buried the firstmate working row far past a read window and broke the settled-pane assertion. The driver now redirects the SDK's fd 1/2 to `<run-log>.sdk.log` (chmod 600, append) and writes its own rows through a saved duplicate of the pane's stdout, so the pane carries firstmate rows alone. The answer is asserted from the sdk log, and the settled pane is judged by its last firstmate literal (idle/cancelled can never acknowledge, and it is written below any historical working row in scrollback).
- **Hard interrupt exit**: a single C-c cancelled the pair and touched turn-end, but the interpreter then blocked forever at teardown joining the SDK's non-daemon stdout/stderr reader threads (`openhands/sdk/utils/command.py`), leaving a live `python` process in the pane. The interrupt path now closes the conversation under a 5s daemon watchdog deadline and exits via `os._exit(130)`, so teardown can never wedge the pane; the guard polls `pane_current_command` because the bounded close briefly keeps the driver alive after the cancelled close.

The guard asserts the firstmate-owned mechanics, so the profile's current `LLM_MODEL` is the right model for the run. It was run twice on the reference host the same day, both passing: first under the profile that carried `anthropic/claude-opus-4-8`, then under `fireworks_ai/accounts/fireworks/models/deepseek-v4p1-flash` with a live Fireworks key (the "DeepSeek 4.1 Flash" from the standing provider directive; the plain `deepseek-v4-flash` id does not exist on the live catalog, confirmed against `/v1/models`). Swapping `LLM_MODEL` and the key in the profile file was the only change between the two runs - no harness-side change was needed, which is the provider-independence claim proven.

## Still unproven

- Herdr, Zellij, cmux, and Orca placements: the launch, fold, and delivery row are backend-neutral, but only tmux is verified for this adapter.
- Native resume: none is claimed; the resume path is a deterministic relaunch, and the conversation's durable state is the worktree.
- Secondmate and primary use: refused by design, not merely unverified; a headless driver has no wake-protocol surface to arm.
