# Verification: the auggie primary harness adapter

Active empirical facts for firstmate's auggie primary adapter.
The skill tree rooted at [`.agents/skills/harness-adapters/SKILL.md`](../../.agents/skills/harness-adapters/SKILL.md) owns the operating facts through [`references/harness/auggie.md`](../../.agents/skills/harness-adapters/references/harness/auggie.md); this record owns how they were established and what is still unproven.

## Subject

| Field | Value |
|---|---|
| Version | `auggie 1.2.0` (commit `2afeeb74cb9a958e51870161bd3f4c7d8b6efcab`, built 2026-11-09) |
| Verified | 2026-11-11 |
| Binary | `~/.local/bin/auggie`, a symlink to `../lib/node_modules/@augmentcode/auggie/auggie-v2.mjs` |
| Runtime | Node `v26.13.0` |
| Platform | Linux x64 (Arch, kernel 7.2.15) |
| Backend | Herdr for the running session; a private tmux socket for the bare-launch probe |

Every command below ran from a bash tool call of a live auggie session, inside a disposable firstmate task worktree.
No captain fleet state was touched, and the real session lock was neither read for ownership nor written.

## Detection: a node bundle with no marker

The parent of a bash tool command is the auggie process itself:

```
$ auggie --version
1.2.0
commit: 2afeeb74cb9a958e51870161bd3f4c7d8b6efcab
built:  2026-11-09T18:30:16Z
$ readlink ~/.local/bin/auggie
../lib/node_modules/@augmentcode/auggie/auggie-v2.mjs
$ p=$(ps -o ppid= -p $$ | tr -d ' '); ps -o comm= -p "$p"; ps -o args= -p "$p"
node-MainThread
node /home/mike/.local/bin/auggie
$ env | cut -d= -f1 | grep -c '^AUGMENT_'
0
```

No `AUGMENT_*` variable reaches tool commands, so there is no marker to promote.
The same session carried an inherited `PI_CODING_AGENT` from the terminal it was started in, which made `bin/fm-harness.sh` print `pi` before this adapter existed.
With `bin/fm-auggie-lib.sh` in place:

```
$ bin/fm-harness.sh
auggie
$ bin/fm-harness.sh ancestry
comm auggie
$ bash -c '. bin/fm-session-lock-lib.sh; p=$(fm_harness_ancestry_pid); echo "ancestry_pid=$p comm=$(ps -o comm= -p $p) args=$(ps -o args= -p $p)"; fm_harness_pid_alive "$p" && echo alive'
ancestry_pid=540034 comm=node-MainThread args=node /home/mike/.local/bin/auggie
alive
```

Node 24 can report the same process as a bare `MainThread`, which the rule accepts as an interpreter name; that shape is pinned by the portable tests below, not observed live here.

## Bare launch: detection from a pane, with no tokens

`tests/fm-harness-liveness-drift-live-e2e.test.sh` launches auggie bare in a private tmux server.
It parks on auggie's `Workspace Indexing Permission` dialog, which the guard never answers, so the probe spends no tokens and indexes nothing:

```
# auggie 1.2.0: title='node' foreground=[node-MainThread ]
# auggie 1.2.0: primary-only, so pane liveness (ambiguous) is not asserted
# auggie 1.2.0: ancestry verdicts=[comm auggie]
ok - harness detection: auggie 1.2.0 is identified by the ancestry walk at comm strength
```

## Bash tool timeout

A bash tool call given a 3-second timeout ran `sleep 300 & echo $! > /tmp/fm-auggie-bg.pid; echo $$ > /tmp/fm-auggie-sh.pid; sleep 20`.
The call returned `Command timed out after 3 seconds`, and a follow-up call polled both pids once a second:

```
1s sleep=alive shell=alive
2s sleep=alive shell=alive
3s sleep=gone shell=gone
```

Control returns to the model at the bound, and the whole process tree, including the `&` child, is killed within a few seconds after it.
A checkpoint call must therefore carry a timeout above the checkpoint's own bound, which is why the protocol asks for 240 seconds around the 180-second default.
The bash tool schema auggie 1.2.0 presents to the model documents a 600-second default timeout; its maximum is unverified.

## Not verified

- The tracked `.augment/settings.json` `PreToolUse` registration has not been observed blocking a command in a live auggie session.
  `tests/fm-arm-pretool-check.test.sh` drives the registered command with an auggie-shaped payload, and the payload shape, matcher semantics, exit-2 blocking, and `AUGMENT_PROJECT_DIR` come from Augment's hook documentation.
- No prompt-submitting live e2e exists yet for the session-start digest, the foreground checkpoint loop, or the seatbelt; it is pending.
- Away-mode daemon injection into an auggie pane is unverified.
- Worker launch, busy state, interrupt, exit, and resume are unverified, which is why auggie is primary-only.
