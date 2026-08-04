# Verification: dispatched-model evidence

Active empirical facts behind [`../model-verification.md`](../model-verification.md).
Each entry records what was run, on what, and the exact output the current guarantee rests on.

Host: Linux 6.14.11-4-pve.
Harness version throughout:

```text
2.1.220 (Claude Code)
```

## 2026-08-01: `PostToolUse` sees `resolvedModel` for a delegation call

The investigation that opened this work verified that `resolvedModel` is present in `toolUseResult` for a delegation call, and separately that a `PostToolUse` hook's `tool_response` equals `toolUseResult` for a `Read`.
It did not trigger a hook on a delegation call itself, and flagged the composition as unverified.
That composition is settled here directly, because an unverified assumption is not a foundation for a guard.

A throwaway project carried one hook, matcher `.*`, appending the raw payload to a log.
A single delegation call was then made with the model deliberately omitted:

```sh
claude -p "Call the Agent tool exactly once with subagent_type 'Explore', prompt 'Reply with the single word OK, do nothing else', and do NOT pass a model parameter. Then reply DONE." \
  --dangerously-skip-permissions --output-format text
```

Payload captured for that call:

```text
tool_name= Agent
top keys= ['cwd','duration_ms','effort','hook_event_name','permission_mode','prompt_id',
           'session_id','tool_input','tool_name','tool_response','tool_use_id','transcript_path']
tool_response keys= ['agentId','agentType','content','prompt','resolvedModel','status',
                     'totalDurationMs','totalTokens','totalToolUseCount','usage']
resolvedModel= claude-opus-5[1m]  agentType= Explore
```

The composition holds: a `PostToolUse` hook on a delegation call receives the structured result object, and that object carries `resolvedModel`.

Two facts worth keeping from this run.
The parent was `claude-opus-5` and the omitted-model dispatch resolved to `claude-opus-5[1m]`, so the context-window suffix reaches `resolvedModel` and any comparison must tolerate it.
The hook payload carries no model for the *running* session, only for the delegated one, so a session cannot use this surface to learn its own model.

This lever is not what the shipped verifier uses, because it never observes a `bin/fm-spawn.sh` dispatch; the placement reasoning is in [`../model-verification.md`](../model-verification.md).
It is recorded because it is the verified mechanism available if the delegation surface itself ever needs a check.

## 2026-08-01: a session transcript records the model that served each turn

This is the evidence the shipped verifier reads.

```sh
jq -r 'select(.type=="assistant") | .message.model // empty' \
  ~/.claude/projects/<encoded-cwd>/<session>.jsonl | sort -u
```

Over an 18 MB transcript:

```text
claude-opus-4-8
claude-opus-5
<synthetic>
```

Two facts this pins.
A single transcript can name more than one model, so a scan must compare every value rather than sampling one.
`<synthetic>` appears as a `model` value and names no model, so it must be dropped rather than compared.

Cost, same file:

```text
jq -r 'select(.type=="assistant") | .message.model // empty' "$BIG"  0.09s user 0.00s system
```

0.09 s over 18 MB is cheap enough to run per task per heartbeat, which is why the verifier scans transcripts directly instead of maintaining a cache.

## 2026-08-01: transcript directory path encoding

Claude Code stores transcripts under `<config>/projects/<encoded-cwd>/`.
The encoding was established empirically rather than assumed, using a working directory containing `/`, `.`, `_`, and a space:

```sh
mkdir -p 'data/probe_enc.dir/a b' && cd 'data/probe_enc.dir/a b'
claude -p "Reply with the single word OK" --dangerously-skip-permissions --output-format text
ls ~/.claude/projects/ | grep -i probe
```

```text
-home-sungin--treehouse-firstmate-8bf1b0-9-firstmate-data-probe-enc-dir-a-b
```

Every character outside `[A-Za-z0-9]` becomes `-`, including `_` and a space.
Both probe directories were removed after the run.

## 2026-08-01: the gap this closes, observed live

Run read-only against the development fleet before `spawned_at=` existed, over thirteen dispatched workers:

```text
fm-afk-injection-wedge · verdict: match · recorded: opus · actual: claude-opus-5 · source: claude-transcript · ran on claude-opus-5, as dispatched (evidence not time-bounded: record predates dispatch timestamps)
firstmate-watcher-lock-flake · verdict: unverifiable · recorded: opus · actual: claude-opus-4-8,claude-opus-5 · source: claude-transcript · record carries no dispatch timestamp and the evidence names 2 models, which cannot be attributed to this task
```

The `unverifiable` rows are the reusable-worktree case, not a fleet fault: those pool slots still carry a previous occupant's `claude-opus-4-8` transcripts, and without a dispatch binding the two occupants cannot be told apart.
This is the observation that motivated recording a pre-dispatch transcript-identity watermark at spawn, with `spawned_at=` retained only for compatibility with earlier records.
It is also the shape of the intended behavior: the verifier reports what it cannot attribute rather than picking whichever model would have looked right.

## 2026-08-04: dispatch identity remains stable through restart and teardown

The focused regression matrix uses temporary Firstmate homes and temporary Claude stores only.
It binds a mismatched worker to store A, invokes verification under store B containing an older matching transcript, and requires the mismatch from store A.
It also requires missing `model=`, malformed `spawned_at=`, and watermark enumeration failure to remain loud, while a genuinely old record without binding fields retains its disclosed weaker attribution.

The lifecycle cases require base endpoint metadata to exist when watermark capture fails, require forced teardown to print a mismatch without losing discard authority, and require recursive secondmate cleanup to print each child's verdict before removing its record.

Focused command:

```sh
tests/fm-model-verify.test.sh && tests/fm-spawn-dispatch-profile.test.sh && tests/fm-fleet-snapshot-view.test.sh && tests/fm-teardown.test.sh
```

Observed success markers:

```text
all fm-model-verify tests passed
# all fm-spawn-dispatch-profile tests passed
ok - bounded secondmate home summary skips model enrichment
ok - forced teardown surfaces a mismatch before retaining its discard authority
ok - forced secondmate teardown retains Herdr child identity until exact pane disappearance
```
