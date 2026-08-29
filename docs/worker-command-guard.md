# Worker command guard

A crewmate or scout runs unattended, in a disposable worktree, with its harness's approval prompts disabled.
Nothing stands between the model and the host, so a command that reaches past the task - host privileges, a remote host, the captain's global git config, a rewritten history, a push onto `master`/`main`, or a live `.env` - executes with no one in front of it.
This guard refuses that class of tool call before it runs, on the worker harnesses it is wired into: `claude`, `pi`, and `pi-signed`.
A crewmate or scout on any other harness has no command perimeter, so `fm-spawn.sh` says so loudly at launch rather than letting the gap pass for protection.

## One perimeter, two application points

[`bin/fm-worker-command-policy.mjs`](../bin/fm-worker-command-policy.mjs) is the single owner of the perimeter and of every deny/allow decision.
[`bin/fm-worker-pretool-check.sh`](../bin/fm-worker-pretool-check.sh) is the only way to reach it: a stable transport that acquires the harness's tool-call payload, calls the policy, and renders each harness's own deny response.

Both application points are written per task by [`bin/fm-spawn.sh`](../bin/fm-spawn.sh), and neither restates a rule:

| Harness | Application point | Mechanism |
| --- | --- | --- |
| Pi, pi-signed | the per-task extension at `state/<id>.pi-ext.ts`, already loaded with `-e` | `pi.on("tool_call", ...)` returning `{block: true, reason}` |
| Claude | the per-task `.claude/settings.local.json` in the task worktree | a `PreToolUse` hook running the transport with `--claude` |

That is what keeps the two from drifting: extending the perimeter means editing the rule tables in the policy owner and nothing else, and removing the policy owner changes both verdicts at once.
`tests/fm-worker-command-guard.test.sh` pins that property as behavior rather than as a comment - it drives both live application points and asserts they follow the same owner.

The transport also speaks the Codex, Grok, Cursor, and OpenCode payload and response shapes, so wiring one of those harnesses in needs a line in `fm-spawn.sh`, not a second copy of the rules.
Until that line exists, the harness is unwired and `fm-spawn.sh` warns on every spawn onto it.

## The perimeter

Stated here for readers; the policy owner's rule tables are authoritative.
Each rule below states what the guard refuses, not a complete guarantee that the action cannot happen: read it with the deliberate boundaries further down.

- `sudo` - privilege escalation.
- `ssh`, `scp`, `rsync` - reaching or moving data to another host.
- `chmod` - host file modes.
- `git config --global` - the captain's host-wide git configuration.
- `git rebase`, and a `git pull` carrying the isolated short option `-r`, the long option `--rebase`, or `--rebase=<value>` for any value other than `false`, which replays the same way - history the delivery path depends on.
- `git push` whose destination ref resolves to `master` or `main`, plus `git push --all` and `git push --mirror`, which carry those branches along without ever naming them.
  Pushing the task branch, including `git push origin HEAD`, is deliberately untouched: work lands through a PR, so the ordinary push must keep working.
- Reading a file whose basename is exactly `.env`, or carrying one elsewhere as the source of a copy or a move, through a shell command or through a harness file tool.

`.env` is matched on the exact basename rather than on "contains env", because firstmate itself tracks ordinary files such as `config/x-mode.env` that a worker legitimately reads.
The rule covers exposing a secret, not creating a file, so a `.env` DESTINATION is untouched: `cp .env.example .env` and a write or edit tool creating one are ordinary bootstrap work, while `cp .env /tmp/x` and `mv .env /tmp/x` carry the secret out and are refused.

## Threat model

This guard protects against a worker that WANDERS.
It does not protect against a worker that is deliberately trying to get past it.
Anyone who mistakes it for a fence will take risks it does not cover, so the gaps below are listed as plainly as the guarantees.
A worker that genuinely needs one of these actions asks firstmate; a worker set on routing around the refusal has ways to do it, and closing those would take a sandbox rather than a classifier.

## What the guard holds

Within the perimeter above, a command is classified wherever the shared lexer can see it:

- a direct command, and each stage of a pipeline or a list;
- the body of a subshell or a brace group;
- a command substitution, a backtick, or a process substitution;
- the body of a compound statement - a `for`, `while`, `until` or `if` body;
- a command behind `time`, bare or behind that keyword's boolean and attached-value options, and behind one option whose value sits in a separate token, as in `time -o log cat .env`;
- a payload carried in another tool's arguments - `find -exec`, `-execdir`, `-ok`, `-okdir`, and `xargs`;
- an inline shell payload (`sh -c`), an `eval` payload, and a wrapper payload such as `env -S`;
- a file loaded through the sourcing builtins.

## Deliberate boundaries

**The classes below are the ones known and verified to date, and this list is NOT exhaustive by nature.**
A guard built by enumerating shell forms cannot know the complete list of its own gaps, and successive reviews of this very file have each found a class the previous wording had frozen as complete.
Read the list as evidence that gaps exist and are named as they are found, never as a boundary around them.
Each entry is a real gap, verified against the policy owner, not a theoretical one.

**Command runners the shared classifier does not model.**
The perimeter applies to the command [`bin/fm-arm-command-policy.mjs`](../bin/fm-arm-command-policy.mjs) resolves, and its wrapper set is closed: `exec`, `command`, `sudo`, `nohup`, `env`, `timeout`, `gtimeout`.
Any other launcher swallows the command behind it, so `nice chmod +x a`, `nice -n 10 chmod +x a`, `stdbuf -o0 chmod +x a` and `setsid chmod +x a` are allowed today, while `nohup chmod +x a` and `timeout 5 chmod +x a` are refused.
The same holds for a builtin that carries a command to run later: `trap "cat .env" EXIT` is allowed, while the payload of `find -exec` or `xargs` is classified.
Extending that set is deliberately not done here: it is shared with the arm guard and the cd guard, whose behaviour is outside this change's scope.

**A timing-keyword option whose value is followed by another option.**
The operand right after the resolved command word is classified as a command too, because a dropped option's value can stand there.
Only that one operand is, so when `time`'s option takes its value in a separate token AND another option follows that value, the real command is never resolved: `time -o log -a cat .env` and `time -o log -p chmod +x a` are allowed today, while `time -o log cat .env` and `time -a -o log cat .env` are refused.
Widening the scan back would re-refuse an ordinary search whose pattern names a perimeter command, such as `time -p grep -rn ssh src/`, and nothing in the shape tells `log` from `grep` without a per-tool option table this guard deliberately does not keep.
The daily cost of refusing ordinary searches outweighs a form a wandering worker does not spontaneously write, so the residue is accepted and named here rather than closed.

**A rebasing pull written as a combined short-option cluster.**
The pull rule reads `-r` only as its own token, so the same option written inside a cluster is not classified as history-rewriting even though the branch is replayed.
`git pull -qr origin main` and `git pull -rq origin main` are allowed today, while `git pull -q -r origin main` is refused; a disposable repository confirmed the cluster form really rebases, producing no merge commit and a rewritten local sha.
This is the same combined-cluster shape the policy does close elsewhere, for a copy's target-directory option and for an inline shell's `-c`, so the asymmetry is known rather than an oversight: the pull branch was frozen with the rest of the classifier before it got the same treatment.

**Paths and payloads produced at runtime.**
The policy reads literal operands, so a path or a program the command only receives while running is invisible to it.
`find . -name .env -exec cat {} \;` and `find . -name .env | xargs cat` are allowed, because `.env` is a filter pattern there and `{}` is a placeholder - no operand names the file - while `cat .env` is refused.
Refusing on the mere presence of the text would be worse: it would refuse `find . -name .env`, an ordinary search, and contradict the principle stated below that the guard never blocks work it has no opinion about.
The same limit covers a filename or a command held in a variable, such as `sh -c "$CMD"`, which no static classifier can close.
An inline payload - an `eval` payload or an inline-shell `-c` payload, in any option spelling - is extracted by its carrier and then classified by ONE shared path, so both carriers always reach the same verdict for the same payload text.
That path classifies the text as written and expands nothing, so `bash -c "git -C $DIR log -1"` and `eval "git -C $DIR log -1"` are both ordinary work and both allowed.
When a command word is itself an expansion, the operand immediately after it is classified as a command too, because that is what runs if the expansion is empty: `sh -c "$PREFIX chmod +x a"` and `eval "$PREFIX chmod +x a"` are both refused.
A carrier that asked for an inline payload but whose own option grammar yielded none falls back on the ambiguity rule and refuses when the node mentions a perimeter command.
The residue is a payload that names no command literally at all, such as `sh -c "$CMD"`, which is the same runtime limit as above.

**Commands outside the reading and copying sets.**
Those two sets are closed, so any command able to expose a file's contents that is absent from them passes.
`gzip -c .env`, `tar cf - .env`, `dd if=.env`, `wc -l .env` and `jq . .env` are each allowed today, while `cat .env`, `diff .env x`, `hexdump -C .env` and `source .env` are refused.
Adding these one by one is deliberately not done: it would restart the form-by-form enumeration this guard's design decided against, and the sets would stay closed all the same.

**The bodies of scripts a submitted command would run.**
The policy classifies the command a worker submits.
It does not open and re-classify the body of a script that command would run: doing so blocks this repo's own test suite, which legitimately changes fixture modes, and every project's build scripts.

**Fail closed, unlike its siblings.**
[`bin/fm-arm-pretool-check.sh`](../bin/fm-arm-pretool-check.sh) and [`bin/fm-cd-pretool-check.sh`](../bin/fm-cd-pretool-check.sh) guard a supervised primary against agent mistakes and fail open, because a false block there costs more than a missed one.
This guard is a perimeter around an unattended worker, so the trade runs the other way:

- An unusable classifier - missing `node`, missing `jq`, an absent policy owner, an unreadable payload, an invalid policy response - denies with a `worker-guard-unavailable` or `worker-guard-unreadable` reason.
- Unparseable shell syntax that mentions a perimeter command denies as `unclassifiable-perimeter-command`. Unparseable syntax that mentions none of them still allows, so the guard never blocks work it has no opinion about.
- `bin/fm-spawn.sh` refuses to launch a Pi or Claude worker whose guard runtime is missing, so an unguarded worker is never started in the first place.
- An application point whose transport has disappeared since launch refuses every tool call carrying a command or a path, naming the missing transport in the reason. Both points do this: the Pi extension checks at load, and the Claude hook command tests the transport before running it, because a bare exec of a missing transport would exit 127 and Claude would let the tool call through.

**Workers, not secondmates.**
A secondmate is a firstmate instance with its own supervised posture, not an unattended worker, so `fm-spawn.sh` does not wire the guard for a `--secondmate` spawn.

**Not the primary's own session.**
The guard is wired per task.
Firstmate's own primary session is the captain's supervised session and keeps whatever perimeter the captain configures for it.

## Verification

`tests/fm-worker-command-guard.test.sh` is the regression owner:

- the full deny/allow matrix across the Claude, Codex, Grok, Pi, and OpenCode entry forms, covering every form listed under What the guard holds, and including the `git push origin HEAD` case the delivery path needs;
- the file-tool path perimeter in both payload shapes, read and write alike;
- every fail-closed path, including each application point losing its transport after launch;
- a real `fm-spawn.sh` run driving the generated Pi extension in a plain Node host, and the recorded Claude hook command fed a real payload;
- the spawn refusal when the guard runtime is missing, and the spawn warning when the harness has no application point.

Run it with `bin/fm-test-run.sh tests/fm-worker-command-guard.test.sh`.
No harness is spawned; the Pi blocking mechanism itself (`tool_call` returning `{block: true}`) is the one recorded in [`docs/cd-guard.md`](cd-guard.md), verified live against Pi.

## Maintaining this file

Keep this file to the guard's contract, its boundaries, and where its verification lives.
Exact rules, flags, and reason codes belong in the policy owner and the transport's own header, not restated here.
