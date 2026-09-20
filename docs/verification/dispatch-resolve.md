# Typed dispatch resolution verification

Audience: maintainer verification.

This record supports the opt-in `bin/fm-dispatch-resolve.sh` contract owned by [`../configuration.md`](../configuration.md) ("Typed dispatch resolution") and the declared rule and profile fields owned there under "Crew dispatch profiles".
It records only facts that must be re-established when the typesafe.ai model, its API, or firstmate's dispatch rules change.
Task chronology, the captain's rules, and the briefs themselves stay in the private scout report.

## The API the tool depends on

Verified 2026-09-16 against `https://api.typesafe.ai`.
`GET /v1/models` listed `jev-latest` and `jev-preview`, both released 2026-09-10; a `jev-latest` request answered as `jev-1.13.0`.
`POST /v1/systemone` takes `{model, state, questions}`; a `choice` question returns `{choice, probabilities, confidence}` with the probabilities summing to 1.
Observed error shapes: 401 `authentication_error` for a bad key, 403 when the header is missing, 422 with a `detail[].loc` naming the offending field, 400 `api_usage_error` for an unknown model, 405 on GET.
No rate-limit headers were present on any response; every response carried `x-typesafe-request-id`.
Observed end-to-end latency from a Mac was 123 to 348 ms per request, with the server's own upstream time at 4 to 60 ms.

## Live rule match against real briefs

Run 2026-09-16 with the key injected for the one command through the vault (`av inject +TYPESAFE_API_KEY -- ...`), model `jev-latest`, confidence floor 0.6, timeout 5 s, one `quota-axi --json` snapshot for the whole run.
Rules: the captain's five-rule file with a captain-authored none option, one `approval: captain` rule, two rule floors on `model:fable`, and declared `provider` on the Pi profiles.
Briefs: 15 real briefs from this home's recent work plus 10 synthetic ones written to hit each rule.

| Measure | Result |
| --- | --- |
| Rule matched the hand label | 20 of 25 |
| Resolved to the hand-labeled profile | 20 of 25 |
| Outcomes: clear / ambiguous / escalate / error | 18 / 1 / 6 / 0 |
| Clear results with a wrong profile | 0 |
| API latency (min / median / max) | 152 / 214 / 348 ms |
| Wall time per call including jq (min / median / max) | 198 / 261 / 396 ms |
| Input tokens per brief (min / median / max) | 1,279 / 3,114 / 4,538 |
| Output tokens | 150 to 152 |
| API errors | 0 |

Of the five disagreements, one was a wrong hand label (the brief quoted the bug-fix rule's wording verbatim), three were real briefs the model read as the approval-gated design rule at 0.66 to 0.86 confidence and escalated by design, each of which the captain had in fact dispatched at the strongest-reasoning class, and one was a synthetic tweak that came back ambiguous at 0.41 confidence and was handed back to firstmate.
A lean request that asks only the rule Choice matched the full request (rule, profile, and status) on all 25 briefs, which is why the shipped tool asks one question and keeps every gate in code.
That table records the 2026-09-16 run with the captain-authored none option.
A second live run on 2026-09-17 used the same 25 briefs, held one quota snapshot constant through a fake `quota-axi`, and exercised a copy of this branch with the shipped neutral `No listed rule applies to this task.` option and option-free interface.

| Measure | Result |
| --- | --- |
| Rule matched the hand label | 20 of 25 |
| Resolved to the hand-labeled profile | 18 of 25 |
| Outcomes: clear / ambiguous / escalate / error | 17 / 2 / 6 / 0 |
| Clear results with a profile other than the hand label | 1 |
| API latency (min / median / max) | 137 / 220 / 1,795 ms |
| Input tokens per brief (min / median / max) | 754 / 2,589 / 4,013 |
| Output tokens | 60 to 62 |
| API errors | 0 |

The maximum latency was one outlier; the next slowest request was 309 ms.
The differing clear result was a synthetic small tweak that matched the simple-bug-fix rule at 0.90 and selected `cursor-grok-4.6-medium` instead of the hand-labeled `cursor-grok-4.6-high`: the tweak exemption removed from the none-option text belongs in that rule's own `when` text.
Two default-labeled briefs became ambiguous.

## Offline behavior

`tests/fm-dispatch-resolve.test.sh` drives the public interface with a fake `curl` that records argv, the request body, the header read from file descriptor 3, and whether the secret reached its environment, plus a fake `quota-axi` that performs the same environment check.
It proves firstmate can invoke the resolve path without a preflight, rules are snapshotted once from the isolated home's canonical `config/crew-dispatch.json`, and dynamic output fields are flattened to one line.
It proves the absent key (environment and `.env`) prints one stderr line, nothing on stdout, exits 0, and never invokes `curl` or `quota-axi`.
It proves absent, default-only, and empty-rules files return `no rules to match` without a model or quota request, while a broken rules-file symlink exits 2 as unreadable.
It proves the documented starter configuration resolves its Pi default through the declared Claude provider, a `.env` key turns the tool on, and the environment wins over it.
It proves the key is absent from child environments, never appears on `curl` argv, and arrives only as the bearer header on the descriptor.
It proves the request uses the fixed endpoint and model, carries only the project, brief, and rule Choice with one option per rule plus the fixed neutral none option, and never carries `why`, `use`, or quota.
It proves the clear, fixed-floor ambiguous with candidate evidence, escalate (approval with candidate evidence, unverifiable rule floor, tie, nothing rankable), known rule-floor fall-through, known and unverifiable profile-floor evidence, explicit-provider and provider-ID enforcement, authoritative Agy and explicit-provider Gemini routing, partial providers, eligible unranked candidates and their clear-result note, concrete quota vetoes and profile-floor shortfalls taking precedence over uncertainty, account-wide quota veto, limiting-bound ranking, missing-curl and quota-axi failures, HTTP 429 and 500, transport failure, malformed usage, zero-mass or malformed probabilities or confidence, malformed or duplicate profile, invalid selector, removed-option rejection, and out-of-range rule ID paths behave as the contract states, with configuration errors exiting 2 before any network call.
`tests/fm-bootstrap.test.sh` proves bootstrap ignores resolver-only fields without the typed key, validates each malformed shape when the environment or home `.env` activates typed resolution, and prevents an environment-provided key from reaching child processes.

```console
$ bash tests/fm-dispatch-resolve.test.sh | tail -1
# all fm-dispatch-resolve tests passed
```

A live run needs a key and is not part of the suite; rerun the table above by pointing the tool at a brief with the key injected for that one command.

## What the receipt path costs

Measured 2026-09-20 on Linux 6.8 x86_64 with bash 5.2, jq 1.7, and GNU coreutils `sha256sum`, against the fake `curl` and `quota-axi` above, so every figure is the tool's own work rather than the network.
The harness below separates the moment the resolver's first stdout byte is readable from the moment its process exits; everything between the two is the receipt, because each receipt write now follows its own `printf`.

| Measure | Result |
| --- | --- |
| Resolve run, receipts idle: first stdout byte | 173 to 184 ms |
| Resolve run, receipts idle: receipt work after the block | 49 to 50 ms |
| Resolve run, lock held by a live owner: receipt work after the block, then dropped | 132 to 138 ms |
| Brief and rules content hashes, taken before the block | 3 ms |
| A `--record-dispatch` join run, end to end | 88 to 90 ms |

The receipt costs tens of milliseconds of the resolver's own process lifetime, not a few.
Neither figure reaches stdout: the block is complete and readable at the first number in every case, and exit status is 0 throughout.
One `jq -cn` to build the record dominates the idle figure; the retry budget dominates the contended one.

The receipts lock is one per home, `state/.dispatch-receipts.lock`, not one per brief, and AGENTS.md directs firstmate to dispatch isolated work with no concurrency cap, so several independent intakes in one turn contend on it.
The two paths therefore wait on it for different lengths, under separately named budgets.

`RESOLVE_LOCK_ATTEMPTS` is 7, the smallest value that lost no record at three-way contention: 7 records of 300 at 5 attempts, 1 of 300 at 6, and none of 900 at 7.
It is deliberately not raised, because the resolve path may not extend the resolver's process to save a best-effort receipt; a contended resolve receipt is dropped instead, and that drop is silent by design, as the contended row above records.

`DISPATCH_LOCK_ATTEMPTS` is 21, the smallest value that lost no record with twelve simultaneous `--record-dispatch` runs against a 200-record home, which is the parallel intake AGENTS.md permits.
That probe lost 187 records of 360 at 7 attempts, 132 of 360 at 10, 48 of 360 at 14, 10 of 720 at 19, 2 of 720 at 20, and none of 1,440 at 21 across two independent 60-trial runs.
The join runs after the spawn and prints nothing to the resolver's stdout, so the longer wait cannot reach the resolve path's latency.

Contention past either budget drops the record by design rather than waiting.
A `--record-dispatch` run that cannot take the lock appends nothing, names itself on the stderr drop line, and still exits 0, so that loss is observable; the resolve path stays silent because it may not write to either stream after its block.
The suite asserts that shape rather than a fixed append count - each concurrent run either appends its record or reports the drop, with no third outcome, and the file stays valid JSONL with no partial or interleaved line.

The receipts file is append-only and unbounded, so the `jq -s` slurp the join holds the lock across grows with a home's history.
It grows slowly: an end-to-end `--record-dispatch` run cost 81 ms at 100 records (28 KiB), 98 ms at 500 (141 KiB), 106 ms at 1,500 (426 KiB), and 122 ms at 5,000 (1,424 KiB).
Whether a home that old wants pruning or rotation is out of scope for this change and has no owner yet.

```console
$ bash receipt-cost.sh   # the harness below, saved to a scratch file and run from the repository root
idle:      stdout 173 ms, exit 222 ms, receipt 49 ms after the block
locked:    stdout 184 ms, exit 316 ms, receipt 132 ms after the block, then dropped
hashes:    3 ms before the block
join run:  90 ms end to end
```

The harness, run from the repository root:

```sh
H=$(mktemp -d); mkdir -p "$H/state" "$H/config" "$H/fakebin"
printf '# Task\nFix the off-by-one in the pager.\n' > "$H/brief.md"
printf '{"rules":[{"when":"A simple bug fix.","use":{"harness":"cursor","model":"cursor-grok-4.6-medium"}}]}\n' > "$H/config/crew-dispatch.json"
cat > "$H/fakebin/curl" <<'EOF'
#!/usr/bin/env bash
out=''; hdr=''
while [ $# -gt 0 ]; do case "$1" in -o) out=$2; shift 2;; -D) hdr=$2; shift 2;; *) shift;; esac; done
cat > /dev/null
printf 'x-typesafe-request-id: bench\r\n' > "$hdr"
printf '{"model":"jev-1.13.0","answers":{"rule":{"type":"choice","choice":"rule_1","confidence":0.9,"probabilities":{"rule_1":0.97,"default":0.03}}},"usage":{"input_tokens":812,"output_tokens":60}}' > "$out"
printf '200'
EOF
cat > "$H/fakebin/quota-axi" <<'EOF'
#!/usr/bin/env bash
printf '{"schemaVersion":5,"providers":[{"provider":"cursor","quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":80,"runway":{"status":"ok"},"selection":{"spendPriority":10}}]}}]}'
EOF
chmod +x "$H/fakebin/curl" "$H/fakebin/quota-axi"
export PATH="$H/fakebin:$PATH" FM_HOME="$H" TYPESAFE_API_KEY=bench-key
split() { # prints "<ms to the first stdout byte> <ms to exit>"
  local t0 a b pid; : > "$H/out"; t0=$(date +%s%N)
  bin/fm-dispatch-resolve.sh "$H/brief.md" > "$H/out" 2>/dev/null & pid=$!
  a=0; while kill -0 "$pid" 2>/dev/null; do [ -s "$H/out" ] && { a=$(date +%s%N); break; }; done
  [ "$a" -ne 0 ] || a=$(date +%s%N); wait "$pid"; b=$(date +%s%N)
  echo "$(( (a-t0)/1000000 )) $(( (b-t0)/1000000 ))"
}
s=0; e=0; for _ in $(seq 20); do read -r x y < <(split); s=$((s+x)); e=$((e+y)); done
echo "idle:      stdout $((s/20)) ms, exit $((e/20)) ms, receipt $(( (e-s)/20 )) ms after the block"
ln -s $$ "$H/state/.dispatch-receipts.lock"; read -r x y < <(split); rm -f "$H/state/.dispatch-receipts.lock"
echo "locked:    stdout $x ms, exit $y ms, receipt $((y-x)) ms after the block, then dropped"
t0=$(date +%s%N); for _ in $(seq 20); do sha256sum "$H/brief.md" "$H/config/crew-dispatch.json" >/dev/null; done
echo "hashes:    $(( ($(date +%s%N)-t0)/1000000/20 )) ms before the block"
t0=$(date +%s%N); for _ in $(seq 20); do bin/fm-dispatch-resolve.sh --record-dispatch "$H/brief.md" --harness cursor >/dev/null 2>&1; done
echo "join run:  $(( ($(date +%s%N)-t0)/1000000/20 )) ms end to end"
rm -rf "$H"
```
