---
name: evidence-consumption
description: >-
  Agent-only procedure for bounded evidence reads.
  Use before consuming a long report, broad GitHub response, process listing, validation log, or repeated unchanged live evidence.
user-invocable: false
metadata:
  internal: true
---

# Evidence consumption

Use the narrowest evidence that can answer the current question while preserving exact authority, decision, head, and validation facts.
This skill is the single owner of Firstmate's targeted report, GitHub, process, validation-log, and changed-fingerprint read procedure.

## Reports

Read the title, `Executive summary`, `Decision inventory`, and `Current next actions` first by locating their heading ranges.
Read only the cited finding or evidence range needed for the current question after that stable front.
Read the whole report only to audit the investigation, inventory every decision for the `decision-hold-lifecycle` completion owner, or resolve a contradiction that targeted ranges cannot answer.
For a report already represented by a durable task record, compare its stable-front or content fingerprint before rereading detailed evidence.
A compact or portability summary is navigation evidence, not a durable knowledge destination or proof of provider-input savings.

## GitHub

Use `gh-axi api` with explicit `--jq` fields rather than fetching a complete pull request, review, check, or comment response.
Use these narrow read-only shapes when they answer the question:

```sh
gh-axi api /repos/{owner}/{repo}/pulls/{number} \
  --jq '{url:.html_url,state,merged_at,draft,head_sha:.head.sha,base_sha:.base.sha,updated_at}'

gh-axi api /repos/{owner}/{repo}/pulls/{number}/reviews \
  --jq '[.[] | {id,state,commit_id,submitted_at,user:.user.login}]'

gh-axi api /repos/{owner}/{repo}/commits/{sha}/check-runs \
  --jq '{total_count,check_runs:[.check_runs[] | {name,status,conclusion,completed_at}]}'
```

Fetch comment bodies only when their text is the evidence being decided.
Predicate approvals and checks on the exact current head rather than the pull request number alone.

## Processes and worker output

Start a named process inspection with:

```sh
ps -o pid=,ppid=,state=,etime=,pcpu=,comm= -p "$pid"
```

Do not use broad `ps -ef`, complete command lines, or environment output unless arguments, ancestry, or environment are the specific question.
Start worker output inspection with `bin/fm-peek.sh <target> 20`.
Expand once to 40 lines only when the first range cannot answer the named question.
Do not perform repeated wider reads against an unchanged fingerprint.

## Changed-fingerprint rereads

Before repeating a deep live inspection, compare this tuple:

- newest durable event identity or content hash;
- validation run identity and current step;
- exact code or pull request head;
- review fingerprint from review id, state, commit id, and submitted time;
- check-run fingerprint from name, status, conclusion, and completion time;
- worker semantic activity generation or source;
- report stable-front fingerprint when a report is involved.

If the tuple and current classification are unchanged, reuse the existing evidence instead of rereading full GitHub, process, terminal, validation-log, or report output.
Use the existing bounded long recheck for a declared external wait rather than manufacturing progress reads.
When a field changes, inspect only its source first and widen only if that changed source cannot answer the question.

## Token-saving claims

Never infer token savings from a short summary, small artifact, encrypted byte count, cache assumption, or context setting alone.
A token-efficiency claim requires the next provider-reported input and current context usage, with provider-reported cache fields when cache behavior matters.
Keep recall and authority evidence separate from token-efficiency evidence, and preserve recall and authority when they conflict with savings.
