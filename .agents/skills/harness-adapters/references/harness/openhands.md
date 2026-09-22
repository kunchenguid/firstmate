# OpenHands SDK

The OpenHands adapter, verified end to end on 2026-09-19 with openhands-sdk 1.34.0 / openhands-tools 1.34.0 on Linux through the tmux backend, running the firstmate-owned driver `../../../../../bin/fm-openhands-worker.py`.
Unlike every other adapter this is not a vendor CLI in the pane: the pane runs firstmate's own Python driver under the resolved OpenHands venv interpreter, so every supervision signal is firstmate-owned code and no hook layer exists anywhere in the adapter.
Verified as a CREWMATE and SCOUT adapter only; `../../../../../bin/fm-spawn.sh` refuses a secondmate launch on it because `../../../../../docs/supervision-protocols/` carries no openhands wake protocol and a headless driver has no primary surface at all.
`../../../../../docs/verification/openhands.md` owns how every fact below was established and what is still unproven.

## Operating facts

| Fact | Value |
|---|---|
| Binary | The resolved venv interpreter (FM_OPENHANDS_PY, then `config/openhands-python`, then `~/.config/openhands/venv/bin/python`), refused when absent or when it cannot import `openhands.sdk` and `openhands.tools`; it runs the firstmate-owned `bin/fm-openhands-worker.py`, never a vendor command. |
| Launch | `<venv-python> bin/fm-openhands-worker.py --llm-env <config>/openhands-llm.env --run-log state/<id>.openhands-run --turn-end state/<id>.turn-ended "<brief>"`, with `FM_OPENHANDS_HARNESS=openhands` and the foreign markers cleared; the pane's cwd is the worktree, which is the driver's workspace. |
| Busy state | The driver's own run log: one `run_started`/`run_terminal` JSONL pair per run, folded by `../../../../../bin/fm-busy-lib.sh` (`openhands-run-log`); an unmatched `run_started` is busy, a trailing `run_terminal` is idle, and a missing, empty, or malformed log is unknown, never idle. |
| Turn end | The driver touches `state/<id>.turn-ended` at every run close, completed or cancelled; no hook exists because the writer is firstmate-owned. |
| Exit | `/exit` typed at the idle stdin loop, aliased `/quit`; an in-flight run finishes its turn first because stdin is read between runs. |
| Interrupt | Single `Ctrl+C` (SIGINT): the in-flight run's pair closes as `terminal=cancelled`, the turn-end marker is touched, and the driver exits 130; worktree state is preserved and the resume path is a deterministic relaunch. |
| Skill | No slash-skill surface; every stdin line is a follow-up message, so use natural language. |
| Autonomy | The SDK agent runs its tools headless with no approval gate; the brief is the only authority carrier, exactly as for every other adapter. |
| Marker | `FM_OPENHANDS_HARNESS=openhands`, a firstmate-owned launch marker in omp's shape: precedence only, trusted solely when a driver process is genuinely in the ancestry. |
| Ancestry | Args-strength only: a `python*` process whose arguments carry the full `fm-openhands-worker.py` filename, never the openhands fragment, because the live process name is the interpreter's. |
| Resume | No native pane resume is verified; the conversation state is the worktree, so use deterministic relaunch. |
| Model | `--model <litellm-string>` (for example `fireworks_ai/accounts/fireworks/models/deepseek-v4p1-flash`); validated syntactically only, because the authoritative listing is the provider's own API and the spawn must not spend the crew's key on a name check; when omitted the driver reads `LLM_MODEL` from the profile. |
| Effort | No effort axis; an effort value stays in task metadata under the record-and-omit contract, and a dispatch profile that names one is refused at validation. |
| Composer | None: the pane renders the driver's own rows, and the working row is the delivery signature below. |
| Steering | stdin lines: every non-empty line is a follow-up message sent through the same conversation, so `fm-send` typing lands as a real user turn. |

## Credential precondition, and where it persists

The profile is the active home's `config/openhands-llm.env`, chmod 600 and never committed, carrying `LLM_API_KEY` and `LLM_MODEL`.
The spawn refuses before endpoint creation when the file is missing, unreadable, or either value is empty, because a headless driver that fails inside the pane reads as a wedged worker rather than a missing credential; the key value is never read into a variable any script could print.
The profile file is the single place a provider change lands: swap `LLM_MODEL` (and the key) and every openhands worker follows on its next spawn, with no harness-side change.

## Detection

Detected by the marker plus args-level ancestry evidence, both owned here: `FM_OPENHANDS_HARNESS=openhands` wins only when `../../../../../bin/fm-harness.sh` finds a driver process in the parent chain, and the ancestry walk's interpreter branch reports `args openhands` on the full driver filename.
An unrelated python process carrying the openhands fragment matches nothing.
Driver ancestry is args-strength only, so a RETAINED foreign `CLAUDECODE` outranks it by the marker-names-its-harness rule; that is the design, and it is exactly why the spawn clears every foreign marker at the launch boundary, where the driver ancestry is then the only evidence and identifies openhands.
openhands is deliberately absent from the session-lock name vocabulary in `../../../../../bin/fm-session-lock-lib.sh`, where muse, gemini, rovo, and agy are also absent: a crewmate-only adapter must never own a home session lock.

## Worker busy state and turn end

The spawn truncates `state/<id>.openhands-run` at launch, so a relaunch never folds a predecessor's open run, and a relaunch away from openhands retires the file through `fm_control_harness_wiring_paths`.
The driver appends the pairs and touches the turn-end marker; nothing is armed as a busy-state record because the fold is the record.
The rendered rows (`[fm-openhands] working`, `idle`, `cancelled`) are delivery guards only, owned by `FM_DELIVERY_OPENHANDS_BUSY_REGEX_DEFAULT` in `../../../../../bin/fm-composer-lib.sh`; recorded worker state comes from the fold, never from a row.

## Primary integration

Unsupported and unverified.
`../../../../../docs/supervision-protocols/` carries no openhands protocol, no turn-end guard adapter exists for it, and this adapter verified only the crewmate-side launch, busy state, interrupt, and exit.
`references/common/primary-hooks.md`'s unsupported-boundary rule applies: never invent a wake protocol from a similar surface.
