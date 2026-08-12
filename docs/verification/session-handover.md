# Verification: session handover and the helm

Active evidence for the guarantees in [`../session-handover.md`](../session-handover.md).
Recorded 2026-08-05 on macOS 26.5.1 (arm64), bash 5.3.0, jq 1.8.2, git 2.55.0, Claude Code 2.1.221.

## The silence proof is positive evidence only

The claim: a takeover is granted only against proof that the holder is working, never against the absence of such proof.

`state/.lock` was measured and rejected as an evidence source.
`bin/fm-lock.sh` writes it once at acquisition and nothing anywhere refreshes it - there is no second writer and no `touch` of it in `bin/` - so its mtime is the session's age.
A live, busy holder read as 7200 seconds silent through it, which is why the lock now proves nothing and `bin/fm-helm-lib.sh` reads only a pid-matched, non-empty `state/.helm-activity` and the transcript that marker names.

The guarantee that replaces it is fail-closed and lives entirely on the read side: with no such marker, or with one that names no transcript or names a transcript that is gone, the silence is unmeasurable, the acquisition refuses and names the holder, and the only way past it is the captain running `bin/fm-lock.sh clear --pid <holder>`.
The marker is written on every turn end regardless, because a stamp that refused to write would leave an earlier, more optimistic marker standing in its place.
The stamp is written to a temp file beside the marker and moved into place, so a concurrent reader never sees the zero-length window a truncating redirect leaves while it forks for the timestamp.

## The unattended proof

The claim: a Firstmate session the captain is using owns a controlling terminal, while a process the session itself spawns owns none, so an absent terminal is a usable proof that nobody is at the keyboard.

Walking the ancestry from inside a tool call of a live attended primary session:

```console
$ p=$$; for i in 1 2 3 4; do ps -o pid=,ppid=,tty=,stat=,comm= -p $p; p=$(ps -o ppid= -p $p | tr -d ' '); done
36719 27294 ??       Ss   /bin/zsh
27294 26259 ttys005  S+   claude
26259 25754 ttys005  S    /bin/zsh
25754 25651 ttys005  S    treehouse
```

The attended harness (pid 27294) reads `ttys005 S+`: a named terminal, and the foreground process group of it.
The shell the session spawned for its own tool call (pid 36719) reads `?? Ss`: no terminal at all.

`bin/fm-helm-lib.sh` gates on the terminal only, not on the `+` foreground flag.
Both signals agree in the measured pair, and the terminal is the conservative half: an attended session under a wrapper that leaves the harness outside the foreground process group would still read as attended and keep the helm.
The cost of that choice is at most one extra refusal, which the printed clearing command resolves; the cost of the opposite choice is two sessions working one fleet.

Consequence for the measurement: the holder pid recorded in `state/.lock` is the harness pid, never the pid of a tool call, so the check reads the terminal of the session itself.

## The context measurement reuses the existing formula

The claim: `bin/fm-context-measure-lib.sh` does not introduce a second measurement.
The formula is the one already written on the unlanded branch `feat/context-budget-guardrail` (inline in `bin/fm-context-budget.sh`), lifted rather than re-derived, so both converge on one owner when that branch resumes.

Both run over the same real transcript:

```console
$ T=~/.claude/projects/-Users-uayyagari-sys-config-dotfiles/c12f48d6-a8f6-4043-b976-9106d2b25327.jsonl
$ bash -c '. bin/fm-context-measure-lib.sh; fm_context_measure_transcript "$1"' _ "$T"
75782
$ git show feat/context-budget-guardrail:bin/fm-context-budget.sh > /tmp/cb.sh
$ bash -c 'TRANSCRIPT="$1"; sed -n "/^measure_context()/,/^}/p" /tmp/cb.sh > /tmp/mc.sh; . /tmp/mc.sh; measure_context' _ "$T"
75782
```

That branch's own verification record holds the cross-check against Claude Code's reported figure; this record establishes only that the lifted formula is the same formula.

The threshold is not hypothetical, and the measurement's cost is real.
The largest transcript on this machine is a genuine working session:

```console
$ ls -S ~/.claude/projects/*/*.jsonl | head -1 | xargs ls -lh | awk '{print $5, $9}'
45M $HOME/.claude/projects/<encoded-project-dir>/<session-id>.jsonl
$ time bash -c '. bin/fm-context-measure-lib.sh; fm_context_measure_transcript "$1"' _ "$BIG"
494320
bash -c ...  1.98s user 0.08s system 127% cpu 1.613 total
```

494,320 tokens is nearly twice the threshold, and the measurement costs 1.6 seconds at that size, paid once per primary turn end and never on a crewmate turn end.

## Behaviour tests

```console
$ bin/fm-lint.sh
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)

$ bash tests/fm-helm-takeover.test.sh
ok - fm-lock: refuses an attended holder, naming it, its terminal, and the clearing command
ok - fm-lock: an unattended holder that was recently active keeps the helm
ok - fm-lock: silence alone never takes the helm - the unattended proof is required
ok - fm-lock: the session lock's age is not evidence, so it never takes the helm on its own
ok - fm-lock: an empty or foreign activity marker is not proof of anything
ok - fm-helm-lib: the activity stamp lands whole, never as an empty file
ok - fm-lock: a holder working through a long single turn is not mistaken for an idle one
ok - fm-lock: takes the helm from a provably unattended, measurably silent holder and says so
ok - fm-lock: a dead holder's helm is still claimed immediately, with no takeover ceremony
ok - fm-lock status: reports the holder, its terminal, and whether the helm can be taken
ok - fm-lock release: only the session holding the helm can give it up
ok - fm-lock clear: only clears the recorded holder, and never pretends to have stopped it
```

`tests/fm-session-handover.test.sh` covers the pulse (one report per episode, re-arming, the flat threshold, sidechain exclusion, inertness inside a task worktree, silent degradation, and marker stamping only by the helm holder), the handover refusals, the release that preserves queued events, and the answered-decision search and its cap.
`tests/fm-session-start.test.sh` covers the replacement session end to end: it takes the helm, the awaiting block and the handover record lead the digest, and the event queued during the gap is drained.

The two proofs that matter most, run against a sabotaged fixture rather than asserted:

```console
$ bin/fm-handover.sh check          # after emptying a record the handover points at
handover check: INCOMPLETE - a release is refused until every line below is fixed
MISSING: the record points at data/captain.md, which is empty

$ bin/fm-handover.sh release        # with a live worker that has no durable record
fm-handover: REFUSING to release the helm - the handover is incomplete.
MISSING: live worker beta-task has no note saying what it is mid-way through
MISSING: live worker beta-task has no backlog item, so its thread is not durably recorded
Nothing was released and nothing was discarded. Fix each line above, then run "fm-handover.sh release" again.
```

## Answered decisions are findable in one command

The concrete case this exists for: a decision settled on 2026-07-29 was escalated again nine days later.
Against the live main home's records, one search surfaces it with its source:

```console
$ bin/fm-decided.sh search "duplicate customer"
data/stripe-decision-log.md:165:**D35. Leave the existing duplicate customer records alone.** Stripe cannot merge customers; ... 2026-07-29.
```

No migration was needed: the search covers the decision logs already in `data/`.

## Compatibility axes

- **Harness.** `claude` only, and enforced: `bin/fm-session-pulse.sh` requires `--claude` and is inert otherwise. No other verified adapter's turn-end payload carries a transcript pointer to measure. The handover, helm, and answered-decision commands are harness-independent.
- **Runtime backend.** Not applicable. Nothing here spawns, reads, or reconciles a backend endpoint; `bin/fm-handover.sh` reads `state/*.meta` as files only.
- **Secondmate homes.** In scope. The pulse binds a genuine `.fm-secondmate-home` through the shared primary scope, exactly as the turn-end guard does, and every path resolves `FM_HOME` rather than the repo root.
- **Crewmate and scout worktrees.** Inert, proven by the linked-worktree case in `tests/fm-session-handover.test.sh`.
