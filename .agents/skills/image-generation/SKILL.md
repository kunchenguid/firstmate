---
name: image-generation
description: >-
  Agent-only playbook for generating creatives and illustrations through the Gemini image models (Nano Banana family).
  Use when a task explicitly asks for a generated image, creative, poster, illustration, or placeholder art.
  Use before choosing an image model, because the four models differ in price by roughly 4x.
  Do NOT use to decide whether an image is wanted - that is the captain's call, and every call spends real money.
user-invocable: false
metadata:
  internal: true
---

# image-generation

This skill owns how the fleet turns a brief into an image file: which tool to call, how to write the prompt, which model to spend on, and where the result belongs.

## Every call spends the captain's money

There is no free tier for any image model. Nano Banana is billed per image, and the four models differ by roughly 4x:

| Model | Price | Use it for |
|---|---|---|
| `gemini-3.1-flash-lite-image` | ~$0.034 / 1K | throwaway drafts, layout placeholders |
| `gemini-3.1-flash-image` | ~$0.067 / 1K | **the default** - Nano Banana 2, the fleet's balance point |
| `gemini-2.5-flash-image` | ~$0.039 / image | the older flagship; prefer the 3.1 line unless a brief names this one |
| `gemini-3-pro-image` | ~$0.134 / 1K-2K, ~$0.24 / 4K | final creatives, posters, anything carrying rendered text |

**Never generate speculatively.** Do not produce variations "to compare" unless the brief asked for variations, and do not regenerate because the first result was merely not to your taste. An agent's own aesthetic judgement is exactly the thing the `frontend-evaluator` gate exists to distrust; here it also costs money each time it is exercised.

If a task needs more than about five images, that is a spend decision, not a craft decision: report the count and the estimated cost to the captain under `AGENTS.md` section 9 and wait.

## The daily cap is a brake, not a budget to spend down

`config/image-daily-usd-cap` (default **$5 per UTC day**) is enforced **before** the billable call, and exit `7` means the next call would cross it. It exists because Google Cloud has no hard spending stop at all - a billing budget only sends an alert while the charges keep accruing - so this local counter is the only thing that actually halts a loop.

The cap counts **money, not images**, because an image count silently changes meaning when the model does: 200 images is ~$13 on flash and ~$48 on pro at 4K. Prices used for the cap are deliberately conservative, so the cap errs toward underspending. Each call reports `today=$X/$5`, so you always know how much of the day is left before you ask for another image.

Treat it as a circuit breaker that should never trip, not as an allowance to spend down. If you hit `7`, **stop and report**. Do not raise `config/image-daily-usd-cap` yourself: the cap is the captain's spending decision, and an agent that edits its own limit has no limit.

## The tool

`bin/fm-image-gen.sh` owns the call. Never call `curl` against the API directly: the tool holds the credential handling, the timeout, the model check, and the spend log, and a direct call silently loses all four.

```sh
bin/fm-image-gen.sh --prompt-file <path> --out <dir>
```

The prompt is passed **as a file, never as an argument**. That is enforced - argv prompt text is refused with exit 2 - because creative briefs carry quotes, `$`, backticks, and newlines that have no business on a command line.

Write the prompt to the task's own directory first, so the brief that produced an image stays next to it:

```sh
printf '%s' "$brief" > data/<task-id>/creatives/prompt-01.txt
bin/fm-image-gen.sh --prompt-file data/<task-id>/creatives/prompt-01.txt \
                    --out data/<task-id>/creatives/
```

The tool prints each written path on stdout and one `cost=` line on stderr. **Put the cost line in your status report.** Spend that is only visible in next month's bill is spend nobody supervised.

Exit codes are distinct so you can act without guessing: `3` credential missing or rejected, `4` model unavailable, `5` timeout, `6` the response carried no image. On `4` the tool prints the API's real catalogue - use it, do not guess a replacement id.

## The model is pinned, and a wrong one is an error

The model comes from `config/image-model`, defaulting to `gemini-3.1-flash-image`. Override per call with `--model` only when the brief justifies it, and say why in your report.

The tool verifies the model against the API's own live catalogue before spending anything, and **fails loudly** when it is not offered. Do not work around that failure by picking a different model yourself. This rule is paid for: `agy` silently downgraded any unrecognized slug to its cheapest tier and warned only in the TUI, never headless, so a full day of design work ran on the wrong model with no visible sign. A tool that quietly substitutes is worse than one that stops.

## Writing the prompt

Read the project's brand documentation before writing a single prompt. In `parlino` that is `docs/brand.md` and `docs/brand/`, and the image must sit inside the same system the UI already uses rather than beside it - the `frontend-evaluator` gate scores "a new colour, shadow, or style invented where the project already has a token" as a blocking defect, and a generated asset is not exempt.

A usable prompt names, in this order: the subject; the medium and style; the palette in concrete terms from the brand book, not adjectives; the composition and aspect; and what must NOT appear. Prompts that say "modern and clean" produce generic stock art; prompts that say "flat vector illustration, graphite `#2E3138` linework on a warm off-white ground, single lime accent, no gradients, no photorealism, 16:9, generous negative space at the top third for an overlaid headline" produce something usable.

For anything carrying rendered text, use `gemini-3-pro-image`. The flash models still garble typography, and a poster with mangled letterforms is a wasted call rather than a cheap one.

## After generating

Inline SVG remains the project's preference for interface illustration where `parlino`'s documented invariants call for it; a generated raster is for creatives, posters, and hero art, not for replacing an icon that should be vector.

A generated image that lands in the UI is a UI change, so it goes through the same gates as any other: the test gate, then the browser evaluation gate in `frontend-evaluator`. Screenshot it at desktop width and at 375px like everything else.

Commit the image and its prompt file together. The prompt is the reproduction recipe, and an asset whose brief was thrown away cannot be regenerated or adjusted by the next agent.

## Setup, and the one manual check

The credential lives in `$FM_HOME/.env` as `GEMINI_IMAGE_API_KEY`, captain-private and gitignored. If the tool exits `3`, the key is missing or `generativelanguage.googleapis.com` is not enabled on the project - report that to the captain rather than trying to provision it.

`bin/fm-image-gen.sh --check-models` prints the live catalogue and spends nothing. It is the right first move when anything about model availability is in doubt, and the right thing to paste when reporting a `4`.
