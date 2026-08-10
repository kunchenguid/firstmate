# Pi compaction envelope verification

Repeatable evidence for the safety envelope in `.pi/extensions/fm-luna-compaction.ts` and for the compaction reserve in `.pi/settings.json`.
Current behavior is owned by [`../../README.md`](../../README.md) ("Pi uses `openai-codex/gpt-5.6-luna` only for session compaction"); this page records evidence only.

Date: 2026-08-10.
Pi: `@earendil-works/pi-coding-agent` 0.84.1.
Node: v26.5.1 (macOS 26.5.2).
Comparison base: `main` at `f4c3e2a`.

## Measured request cost at deployed scale

Two compaction requests captured from real sessions, both split turns against `openai-codex/gpt-5.6-luna` (272000-token context window, 128000 max output tokens).
`Estimate` is Pi's own chars/4 heuristic over the serialized history, which the extension reuses to size its envelope.

| Session shape | Serialized history | Estimate | Real input tokens | Bytes per real token |
| --- | --- | --- | --- | --- |
| Prose and decision heavy | 944212 bytes | 236053 | 180422 | 5.233 |
| Tool heavy | 233542 bytes | 58386 | 95154 | 2.454 |

The estimate overstates real cost by 1.31x on prose and understates it by 1.63x on tool-heavy content, so no single density constant is both safe and non-vacuous.
That spread is why the returned result is additionally checked against the window ceiling rather than trusting the estimate alone, and why the accepted-input floor stays at half the estimate: prose already sits at 0.764 of it while complete.

## Why the envelope is denominated in tokens

`model.contextWindow` is denominated in tokens, so an envelope built from byte counts rejects any session dense enough for bytes to exceed the window.
Against the prose request above, a byte-denominated bound reads 944212 + 2048 overhead + 13107 output as 959367 against 272000 and refuses both compaction models, cancelling a request whose real cost was 180422 tokens with 79000 tokens to spare.
The tool-heavy request passes the same bound at 248697 only because Pi truncates tool results to 2000 characters, which is what made the defect intermittent rather than constant.

`tests/fm-pi-luna-compaction.test.sh` pins both shapes at their measured sizes.
Reverting only `inputMeasurements()` to the byte-denominated form fails the prose case and leaves every other assertion passing, which isolates the unit confusion as the sole cause.

## Reserve arithmetic

`.pi/settings.json` sets `compaction.reserveTokens` to 32768, twice Pi's 16384 default.
Pi compacts when context exceeds `contextWindow - reserveTokens`, so the trigger moves from 255616 tokens (93.98% of the window) to 239232 tokens (87.95%), at a cost of 16384 tokens of working context.

At that reserve Pi budgets `floor(0.8 * 32768)` = 26214 output tokens for the history summary and `floor(0.5 * 32768)` = 16384 for a split-turn prefix.
The history segment therefore leaves 272000 - 2048 - 26214 = 243738 tokens for prepared input.
At the worst measured density above, a session's serialized history estimates 0.9185 tokens per context token, so a request prepared exactly at the trigger estimates 219735 tokens and fits with 24003 to spare.
Compaction fires after the turn that crosses the trigger, so the tolerated overshoot is 243738 / 0.9185 - 239232 = 26133 context tokens, about 10.9% past the trigger.
The prefix segment is not the binding constraint: the largest prefix measured above estimates 768 tokens, for 768 + 2048 + 16384 = 19200 against the same 272000 window.

The larger reserve buys only about 2100 tokens of extra overshoot tolerance over the default, because the 0.8x output budget grows nearly as fast as the trigger falls.
Its justification is earliness rather than headroom: compaction now runs with roughly 12% of the window free instead of 6%.

Pi resolves project settings as `<cwd>/.pi/settings.json`, so this reserve applies only to Pi sessions launched with a clone of this repo as the working directory, and only once that clone has fast-forwarded past the commit carrying the file.
A session already running when the clone updates keeps the reserve it started with until it is next launched.
The envelope, fallback, and refusal behavior in the extension reach a home on the same terms.

## Commands

```console
$ bash tests/fm-pi-luna-compaction.test.sh
ok - Pi Luna compaction sizes requests in tokens, preserves native results, and falls back to Terra
$ bash tests/fm-pi-primary-types.test.sh
ok - tracked Pi extensions pass strict no-emit typecheck against Pi 0.84.1
```

The regression suite stubs `@earendil-works/pi-coding-agent` and drives the registered `session_before_compact` handler directly, so it makes no live model call.
The typecheck resolves against the installed Pi package and skips when `tsc` or that package is absent.
Confirming that `openai-codex` rejects rather than silently clips an over-window request needs a live provider call and is not covered here; the returned-result ceiling check exists so that behavior is not load-bearing.
