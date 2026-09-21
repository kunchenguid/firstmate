# Pre-publication voice check verification

Audience: maintainer verification.

This record supports the opt-in `bin/fm-voice-check.sh` contract owned by [`../configuration.md`](../configuration.md) ("Pre-publication voice check").
It records only facts that must be re-established when the typesafe.ai model, its API, or the check's four questions change.
The API shape the shared client depends on is recorded in [`dispatch-resolve.md`](dispatch-resolve.md).

## Live evaluation against past fleet descriptions

Run 2026-09-18 with the key in the home's `.env`, model `jev-latest` (answering as `jev-1.13.0`), confidence floor 0.6, and `--kind intent`.
Corpus: the Intent section, or the whole body when a description has none, of all 38 pull requests on `kunchenguid/firstmate` authored by this fleet's account, fetched with `gh pr list --author <account> --state all --json number,body`.
Each text was hand-labeled before the run as leaking internal voice or clean.
25 were labeled leaking and 13 clean, and six labels were marked borderline where supervisor instructions read close to behavioural requirements.
The same corpus was run twice against the shipped tool, which retries an uncertain answer once before stopping, to observe stability.

| Measure | Run 1 | Run 2 |
| --- | --- | --- |
| Leaking texts flagged | 22 of 25 | 22 of 25 |
| Leaking texts stopped as unverified | 2 of 25 | 2 of 25 |
| Leaking texts cleared (would publish) | 1 of 25 | 1 of 25 |
| Clean texts cleared | 10 of 13 | 10 of 13 |
| Clean texts stopped as unverified | 3 of 13 | 3 of 13 |
| Clean texts flagged | 0 of 13 | 0 of 13 |

A single call measured 685 / 875 / 1,877 ms (min / median / max) wall time including jq on an earlier run of the same corpus; an uncertain answer costs a second call.
Both motivating leaks were flagged in both runs: the Intent that quoted the operator's short answer verbatim alongside relayed orders (quoted answer, relayed orders, other language, and direct address), and the Intent written partly in French around a quoted operator answer (quoted answer, other language, relayed orders).
Two wholly French Intents inside English descriptions were flagged for language, one of them also for relayed orders.
The one leaking text that cleared narrates the operator's choice of work and their circumstances in the third person without quoting them or giving orders; the four questions do not ask about narration of the operator.
The two unverified leaking texts were borderline supervisor instructions leaning clean below the floor.
The three unverified clean texts were a delivery note, a defect description that mentions the operator as a product role, and a rendering-defect description that names a French-language setting; each stops publication and needs the explicit override.
The retry turned no uncertain answer into a verdict on this corpus, and every text had the same outcome in both runs.

To refresh this record, run `bin/fm-voice-check.sh --kind intent <file>` over the same kind of corpus with the key set and compare against fresh hand labels.
