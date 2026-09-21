# Local Qwen coding workhorse

This is home-local operator reference for the Qwen EXL3 server running on this machine's RTX 3090, not a portable firstmate guarantee.
It records the current launch, the Pi provider entry, how to select reasoning effort, the measured speed and coding-quality evidence, what was tried and rejected, the safe concurrency ceiling, the rollback procedure, and what this model should and should not be trusted with.
The deployment itself was qualified by the earlier EXL3 migration; this page only records what changed afterwards.
Raw per-run evidence, prior-state backups, and the tuning chronology live under `/home/umer/models/qwen/tuning/20260921T132112Z/`, which is outside this repository.

## Current state

| Piece | Value |
| --- | --- |
| Service | `systemctl --user qwen-local.service`, unit at `/home/umer/.config/systemd/user/qwen-local.service` |
| Unit SHA256 | `3da83671a431b6778083e2bcad1773057bf64f3f604638511f5fc5bf0c2db935` (unchanged by this work) |
| Endpoint | `http://127.0.0.1:8080/v1`, loopback only, API key `local` |
| Model id | `qwen3.8-27b` |
| Model | `Qwen3.8-27B-EXL3-4.0bpw`, `turboderp/Qwen3.8-27B-exl3` at `113cf7ab958054860e43fb7f3063b1af19171095` |
| Server script | `/home/umer/models/qwen/exl3-kit/tools/serve_openai.py`, SHA256 `9dcad544265e17cd825a3c647ec2c474f917c5e14488af3c69068c2a570ccba8` |
| Server patch | [`serve_openai.py.effort-and-passthrough.patch`](serve_openai.py.effort-and-passthrough.patch), two hunks, applied on top of kit commit `622c7965ed5e02a13b188c9ef21bb9857fd2ba28` |
| Pi provider entry | `/home/umer/.pi/agent/models.json`, SHA256 `1d894da0bee73dd22b38975f6589ccfcf72839a6d29b5804b9a2d7f3a78a611f`; the `qwen-local` entry alone is copied at [`qwen-local.provider.json`](qwen-local.provider.json) |
| Reasoning levels | `low`, `medium`, `xhigh` (what `/v1/models` advertises and what the chat template accepts), plus thinking off |
| Restart | `systemctl --user restart qwen-local.service` reaches `/health` `ok` in about 10 seconds after a stop |

Launch flags are deliberately unchanged from the qualified migration: loopback host, `--cache_size 262144`, `--grid_size 22.0`, `--cache_quant 4`, `--draft_model mtp`, `--vision auto`, `--ui off`.

## Selecting reasoning effort

Before this work the `qwen-local` provider entry sent `chat_template_kwargs.enable_thinking` and nothing else, so Pi's thinking level had no effect on the model: `--thinking low`, `--thinking medium`, and `--thinking xhigh` all produced a byte-identical request, and the model always ran at the template's default effort, which is `xhigh`.
That was proven with a loopback capture endpoint, not inferred: all three levels sent `{"enable_thinking": true, "preserve_thinking": true}` with no `reasoning_effort`.

The provider now maps Pi levels onto the template's own three effort words and sends the chosen effort inside `chat_template_kwargs`, where a vLLM/SGLang-style client puts template variables.

| Pi thinking level | What the model receives |
| --- | --- |
| `off` | thinking disabled (the template emits an empty `<think></think>` pair) |
| `low` | `enable_thinking` true, `reasoning_effort` `low` |
| `medium` | `enable_thinking` true, `reasoning_effort` `medium` |
| `high` | `enable_thinking` true, `reasoning_effort` `xhigh` |
| `xhigh` | `enable_thinking` true, `reasoning_effort` `xhigh` |

`minimal` and `max` stay hidden because the model's template does not implement them.
`high` maps to `xhigh` because the template's own default and its deepest level is `xhigh`, so the level ordering in Pi's UI keeps matching the level ordering the model implements.

**Pi's session default thinking level on this machine is `high`, which now means `xhigh` - the model's deepest and most expensive setting.**
For everyday and mundane work, select `/thinking medium`.
`reasoning_effort` is guidance in the system prompt, not a hard cap: this engine cannot stop thinking mid-generation, so the word sets the model's intent and the model still decides how long to think.

## Benchmark

[`bench.py`](bench.py) is the reproducible harness, runnable with the system `python3` and standard library only.
It talks to the loopback OpenAI endpoint, drives a small tool loop with `read_file`, `search_text`, `replace_text`, and `write_file`, and scores every task by substring, sentinel, or by running a real test.

```sh
python3 docs/local-qwen-tuning/bench.py --out /tmp/bench.json --thinking on --effort medium
python3 docs/local-qwen-tuning/bench.py --out /tmp/speed.json --tasks speed
python3 docs/local-qwen-tuning/bench.py --out /tmp/prefill.json --tasks speed --long-prompts --speed-max-tokens 8
```

It covers multi-file comprehension, a patch scored by the real script's own committed test in an isolated copy, typed tool-call accuracy across a two-step tool loop, strict output-format adherence, long-file handling over a 2108-line library, refusal-to-hallucinate on a variable that does not exist, and a streaming speed probe.
The repositories it reads are read-only; the only writes go into the run's own temporary sandbox.
Numbers for every cited run are in [`results.json`](results.json).

## Measured speed

| Measurement | Value |
| --- | --- |
| Decode rate, final config | `121.9` tokens/s median over 5 samples (`112.8` to `129.8`) |
| Decode rate, unchanged baseline, 4 replicates | `126.0`, `123.1`, `124.1`, `127.1` tokens/s |
| Run-to-run spread | medians of five samples sit within about 3 percent, single samples within a run spread from `97.6` to `132.4` |
| Decode rate, speculative drafting disabled | `43.8` tokens/s, so the MTP head is worth `2.8x` |
| Time to first token, short prompt | `0.20` to `0.27` s |
| Prefill, final config | `688` tokens/s over `105,036`-token prompts |
| Prefill, unchanged baseline | `686` tokens/s over the same prompt shape |
| Prefix-cache reuse | a `31,536`-token prompt took `32.8` s cold, `0.21` and `0.61` s on identical repeats, and `0.67` s when only the trailing 8 tokens changed |

Two conclusions matter more than the numbers.
First, decode throughput did not move: the whole draft-settings sweep stayed inside the unchanged baseline's own noise band, so no engine-level speed was gained.
Second, both rates are already near this hardware's ceiling - `688` tokens/s over `105,036` tokens is about `37` TFLOP/s, which is the 3090's dense fp16 tensor-core rate, and decode rounds have to read the 13.5 GB of weights every round, which puts `122` tokens/s at roughly half to two-thirds of the card's `936` GB/s memory bandwidth for any plausible draft acceptance.
Pre-fill and decode are therefore reported as unimproved rather than tuned.

The practical speed win is elsewhere: because the engine now honours a requested effort level, the same measured coding score is reachable in about half the wall clock.
Wall-clock speed in real use comes almost entirely from how many reasoning tokens the model writes, not from tokens per second.

For an honest end-to-end datapoint, one cold `pi -p` round trip against this provider (thinking `medium`, no session reuse, no project context files) that read a single 180-line file and returned its first heading took `69.6` seconds.
The equivalent probes run before this work ranged from `32.2` to `69.7` seconds, so single ad-hoc numbers like these vary too much to compare configurations; the suite above is what compares them.
What they do show is that a cold first turn is dominated by ingesting the agent's system prompt, tool schemas, and file contents, which is the one-time cost the prefix cache then removes.

## Measured coding quality

Seven-task suite, same harness and same server for every row; only the thinking setting differs.

| Setting | Score | Sum of task seconds | Sum of output tokens |
| --- | --- | --- | --- |
| thinking on, effort `xhigh`, run 1 (the state before this work) | 7/7 | 86.3 | 5390 |
| thinking on, effort `xhigh`, run 2 | 7/7 | 47.4 | 2336 |
| thinking on, effort `medium`, run 1 | 7/7 | 33.8 | 1374 |
| thinking on, effort `medium`, run 2 | 7/7 | 25.9 | 1637 |
| thinking on, effort `medium`, run 3 | 7/7 | 38.2 | 1805 |
| thinking on, effort `low` | 7/7 | 38.2 | 1928 |
| thinking off, provider sampling (temperature 1.0, top_p 0.95) | 7/7 | 44.9 | 1242 |
| thinking off, the model card's instruct sampling (temperature 0.7, top_p 0.8) | 6/7 | 70.2 | 1170 |

`medium` and `xhigh` both score 7/7, while `medium`'s median is 33.8 seconds and 1637 output tokens against `xhigh`'s 66.9 seconds and 3863.
The cost difference is concentrated in the two reasoning-heavy tasks: the long-file task took 2207 output tokens at `xhigh` against 242 at `medium`, and the patch task 2006 against 534.

This suite saturates: it is strong enough to separate "deepest reasoning" from "reasonable reasoning" on cost, but it does not prove `medium` matches `xhigh` on genuinely hard work.
Treat `medium` as the everyday default and keep `xhigh` for work where a wrong answer is expensive, and read the equal score as "no measured quality loss on these tasks", not as a general equivalence.

The final row is a rejected result rather than a supported one: the model card's instruct-mode recipe asks for `presence_penalty 1.5`, which this server does not implement, and the score dropped.
The same thinking-off mode at the provider's own declared sampling params scored 7/7, so thinking off is left available as a fast path.

## What changed

Two small hunks in `tools/serve_openai.py`, both in [`serve_openai.py.effort-and-passthrough.patch`](serve_openai.py.effort-and-passthrough.patch):

1. `parse_request` now reads `reasoning_effort` from `chat_template_kwargs` as well as from the top level.
   It already read `enable_thinking` from `chat_template_kwargs`, so a client that supplies template variables in the standard place could not previously select an effort; verified by four requests whose rendered prompt lengths differ (`low` 41 tokens, `medium` 11, `xhigh` 53, thinking off 13).
2. The wrapper forwards unknown engine flags from `EXL3_EXTRA_ARGS`.
   Nothing else reads that variable, so with it unset the launch is byte-identical to before; it exists so a draft-depth or cache experiment did not require forking the kit.

One provider-entry change in `/home/umer/.pi/agent/models.json`, described under "Selecting reasoning effort".
The mapping was proved with a loopback capture endpoint that logged the exact request bodies Pi produced, and then confirmed end to end: four `pi -p` runs against the real provider at thinking off, `low`, `medium`, and `high` each returned the correct answer through a real tool call.

Nothing else changed: the systemd unit is byte-identical to its previous state, no model or quantization file was touched, and the launch flags are the qualified ones.

## What was tried and rejected

| Change | Speed delta | Quality delta | Verdict |
| --- | --- | --- | --- |
| MTP with dynamic draft length (`-dds`) | `126.2` against a `123.1` to `127.1` baseline band | not measured | rejected, inside noise |
| MTP draft depth 6 (`-ndt 6`) | `123.7` | not measured | rejected, inside noise |
| MTP draft depth 2 (`-ndt 2`) | `119.7` | not measured | rejected, inside noise |
| dynamic draft with depth ceiling 8 | `125.7` | not measured | rejected, inside noise |
| drafting disabled | `43.8` | not measured | rejected, MTP is worth `2.8x` and stays on |
| thinking off with the card's instruct sampling | `70.2` s against `44.9` s for thinking off at provider sampling | `6/7` | rejected, see above |
| larger prefill chunks | not run | not run | rejected on analysis: prefill already runs at the fp16 tensor-core roofline |
| temperature or top_p changes for thinking mode | none | none | rejected, the provider already matches the model card's thinking-mode values |

The unchanged baseline was re-measured four times (`123.1` to `127.1` tokens/s) and every sweep median fell inside or bracketed that band, so no draft-settings difference was resolvable at this precision.

## Safe concurrency ceiling

The configured ceiling is unchanged at three concurrent workers.
Three simultaneous requests with distinct `52,536`-token prompts each completed exactly once, with a minimum free VRAM of `752` MiB and GPU memory utilisation peaking at `100` percent.
A four-worker run completed 4/4 but reused pages already resident from the three-worker run, so it is not independent evidence and four workers remain unproven.
Adding a `CPU_CACHE_GB` second-tier cache, raising the KV cache precision above `cache_quant 4`, or loading a second model beside this one all still require a fresh measured VRAM window first.

## Rollback

Every prior artifact is preserved under `/home/umer/models/qwen/tuning/20260921T132112Z/`.

```sh
EVID=/home/umer/models/qwen/tuning/20260921T132112Z
git -C /home/umer/models/qwen/exl3-kit checkout -- tools/serve_openai.py
install -m 600 "$EVID/pi-models.json.baseline" /home/umer/.pi/agent/models.json
install -m 600 "$EVID/qwen-local.service.baseline" /home/umer/.config/systemd/user/qwen-local.service
systemctl --user daemon-reload
systemctl --user reset-failed qwen-local.service
systemctl --user restart qwen-local.service
```

The systemd unit is unchanged by this work, so restoring it is a safety step rather than a required one.
After any rollback, confirm `/health`, `/v1/models`, and the loopback-only listener before allowing local model work to resume.
To revert only the provider entry, restore `pi-models.json.pre-reasoning-fix` instead; note that the live `models.json` before this work already differed from the hash the migration report recorded, so these snapshots, not that report, are the rollback source.

## What to trust it with

Verified by the benchmark and the Pi end-to-end probes, so these are the intended uses:

- Navigating and reading a repository with tools, including locating a fact that only exists by joining several files.
- Small mechanical edits, patch work in a single file, config and documentation edits, and focused tests, where the score is the project's own test passing.
- Typed tool calls with exact argument fidelity, including integers, numbers, booleans, arrays, nested objects, and zero-padded strings, across a two-step tool loop.
- Refusing to invent a value: asked for a variable that does not exist, it answered with the requested sentinel instead of a plausible number.
- Long single files: it read a 2108-line shell library and returned the exact requested subset.

Not verified, so treat these as unproven:

- Long-horizon autonomous work; the longest task in this suite is a single file fix, and nothing here tested a multi-hour agentic run.
- That `medium` effort is as capable as `xhigh` on hard problems.
  It is as capable on this suite at roughly half the cost, and nothing more.
- Thinking-off quality in general.
  It scored 7/7 at the provider's sampling params and 6/7 at the card's, and the card's instruct recipe cannot be fully applied because this server does not implement `presence_penalty`.
- Long-context semantic quality under `cache_quant 4`.
  The migration's own 244,530-token needle retrieval passed, and this task added no new long-context quality measurement.
- Anything beyond three concurrent workers, any non-loopback access, and any vision or multimodal change; those are unchanged from the migration report and were not re-measured here.
