# Verification: Claude Remote Control on crewmate launches

Active empirical evidence for Claude Code's Remote Control on a claude crewmate or scout launch, which firstmate enables by default so the operator can drive any worker from `claude.ai/code` and the phone app, and which `config/crew-remote-control=off` opts a home out of.
[`docs/configuration.md`](../configuration.md#crewmate-remote-control-configcrew-remote-control) owns the operating contract; this record owns how it was established.

The main question this record answers is not whether the flag exists - `claude --help` shows it - but whether it composes with the way `bin/fm-spawn.sh` actually launches a worker: a positional brief prompt, an autonomy flag, optional `--model` and `--effort`, inside tmux, with the worktree-scoped hooks firstmate's supervision reads.
Remote Control that silently broke supervision would be worse than no Remote Control, so each of those is verified separately below.
Whether the option exists is a live question too, though a narrower one: claude refuses an unknown option outright, so `fm-spawn.sh` reads the installed claude's own `--help` before typing the flag, and the guard named under "Refreshing this record" is what keeps that verdict honest across claude upgrades.

## Subjects

Four live runs stand behind this record, and they establish different things.

| Run | Version | Verified | Platform | Backend | What it established |
|---|---|---|---|---|---|
| A | `2.1.235 (Claude Code)` | 2026-08-19 | Linux aarch64 (6.8.0-137-generic) | tmux | the flag composes with how fm-spawn launches a worker: the positional brief is delivered and processed, the pane stays an `fm-send`-steerable TUI, the worktree-scoped hooks supervision reads keep firing, and two concurrent workers get distinct sessions |
| B | `2.1.237 (Claude Code)`, tmux `3.5a` | 2026-08-20 | Linux 6.8.0-137-generic | tmux | claude accepts a composed session name of this character class and length, on the default-on path, for two concurrent workers |
| C | `2.1.260 (Claude Code)` | 2026-09-04 | Linux 6.8.0-137-generic | tmux | the installed claude still advertises the option, and firstmate still types it with a per-launch name, after the launch template gained the feedback-draft controls and the rendered `launch-brief.md` |
| D | `2.1.266 (Claude Code)` | 2026-09-09 | Linux 6.8.0-137-generic | tmux | the user-scope `remoteControlAtStartup` setting does not reach an fm-spawn'd worker, so the explicit flag remains the only mechanism that makes one reachable, and the only one that can name the session |

```
$ claude --version
2.1.260 (Claude Code)

$ claude --help | grep -A2 -- --remote-control
  --remote-control [name]               Start an interactive session with Remote
                                        Control enabled (optionally named)
  --remote-control-session-name-prefix <prefix>
      Prefix for auto-generated Remote Control session names (default: hostname)
```

The wording is unchanged from run A's `2.1.235`, which is what the probe's match pattern is built against.

`--remote-control-session-name-prefix` only names AUTO-generated sessions, so it has no effect once an explicit name is passed and firstmate never sets it.

That was re-examined in run B, because a prefix looks at first like a natural carrier for the home qualifier.
`claude remote-control --help` documents it as "Prefix for auto-generated session names (default: hostname)", and a session launched with a prefix and no explicit name does start normally (`session_0135yzEJfEZjjDhppu5nX8g2`), but the generated name is not observable from the pane or from `--debug-file` on this box.
The prefix and an explicit name are therefore mutually exclusive carriers: using the prefix to carry the home means letting the name auto-generate, which drops the task id, the one handle the operator actually searches for, and makes the visible label a vendor-generated string nobody here can read back.
On that evidence the prefix is a weaker carrier for this purpose rather than a better one, so the naming stands as it is; this paragraph is an observation, not a pending change.

## The launch command

Captured from a real `bin/fm-spawn.sh` ship spawn against the installed claude, through the fake-tmux `send-keys -l` capture that [`tests/fm-crew-remote-control.test.sh`](../../tests/fm-crew-remote-control.test.sh) uses, with the home and repo paths substituted for readability.
These are run C's bytes, so they carry the launch template as it stands: the prompt-suggestion and feedback-draft controls, the permission flag, and the rendered `launch-brief.md` a no-mistakes ship is delivered.
A scout is delivered its `brief.md` instead; nothing else about the line differs.

```
--- config/crew-remote-control absent, or = on ---
env -u CURSOR_AGENT -u CURSOR_INVOKED_AS CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --dangerously-skip-permissions --settings '{"feedbackDrafts":"off"}' --remote-control 'dump-1.home.678d2b' "$('<firstmate>/bin/fm-operational-input.sh' encode launch-brief < '<home>/data/dump-1/launch-brief.md')"

--- config/crew-remote-control = off ---
env -u CURSOR_AGENT -u CURSOR_INVOKED_AS CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --dangerously-skip-permissions --settings '{"feedbackDrafts":"off"}' "$('<firstmate>/bin/fm-operational-input.sh' encode launch-brief < '<home>/data/dump-1/launch-brief.md')"
```

The two lines differ by exactly the flag and its name, and that whole-line equality is what the test suite pins for the opted-out launch, so a home that writes `off` provably types what firstmate types with the feature absent.
The flag sits after every option the template already carried and before the positional brief, which is the position the suite asserts.

`--remote-control` takes an OPTIONAL value, so a bare flag would consume whatever token followed it - including the positional brief prompt.
Passing an explicit name is what removes that hazard, and the ordering assertion in the test suite is what keeps it removed.

## Live behavior

Two concurrent scouts were spawned through the real `bin/fm-spawn.sh` into an isolated firstmate home with `config/crew-remote-control` set to `on`, each into its own treehouse worktree, followed by a third with the knob removed as a control.

### The positional brief is still delivered and processed

Not swallowed by Remote Control's session handling.
Each worker ran its brief's command and answered, and the brief text appears as the session's first user turn:

```
❯ You are a test worker in a firstmate verification. Do exactly this and nothing else:
  1. Run: echo RC-E2E-a-OK > /tmp/claude-1000/rc-e2e-a.txt
  2. Then say READY and stop. Do not do anything else.
  Ran 1 shell command
● READY

$ cat /tmp/claude-1000/rc-e2e-a.txt /tmp/claude-1000/rc-e2e-b.txt
RC-E2E-a-OK
RC-E2E-b-OK
```

### The pane stays an ordinary interactive TUI that fm-send steers

The composer, the bypass-permissions footer, and the `esc to interrupt` delivery signature are all unchanged; Remote Control adds only a `/rc active` marker at the right of the footer, which collides with none of the per-harness delivery-busy signatures in `bin/fm-composer-lib.sh`.

A real `bin/fm-send.sh` steer of a live Remote-Control-enabled worker was delivered and confirmed:

```
$ bin/fm-send.sh rce2e-a "Run: echo FM-SEND-STEER-OK > ... then say STEERED"
$ echo $?
0
$ cat /tmp/claude-1000/rc-e2e-steer.txt
FM-SEND-STEER-OK
```

### Supervision wiring is unaffected

This is the load-bearing one: Remote Control does not change the session identity the worktree hooks bind to.
`bin/fm-spawn.sh` writes those hooks into `<worktree>/.claude/settings.local.json`, so they are project-scoped rather than session-scoped, and they kept firing.

After the steer, the task's busy record had advanced through the hook source, and `bin/fm-crew-state.sh` read the worker correctly:

```
$ cat state/rce2e-a.busy-state
v1 gen=g1787149517.1196999.2661 seq=5 state=idle source=claude-hook event=stop ts=1787149615

$ bin/fm-crew-state.sh rce2e-a
state: working · source: status-log · steered
```

`state/<id>.turn-ended` was touched by the Stop hook for every task, so the watcher's turn-end notification path is intact.
A minimal standalone reproduction confirmed the individual hook events rather than only their end state, with `UserPromptSubmit` and `Stop` both firing per turn under Remote Control:

```
1787147915 user-prompt-submit
1787147922 stop
1787147960 user-prompt-submit
1787147967 stop
```

### Concurrent workers do not collide

Each worker got its own Remote Control session, so the limit that would have scoped this knob to one worker at a time does not exist:

```
rce2e-a  session_01N7BX9Y8wXBeAaFz15pyezR
rce2e-b  session_0144vG9SUdetK16hFFbHw92D
```

The footer confirms each worker is independently reachable:

```
/remote-control is active · Continue here, on your phone, or at https://claude.ai/code/session_01RHnXidVGVPvhPR6X9foDG4
```

### Control: the same spawn with no flag

The third scout, spawned identically with no Remote Control flag on its launch command, rendered no `/rc` marker anywhere in its pane, produced the same busy-state shape from the same `claude-hook` source, and delivered its brief the same way.
That isolates every difference above to the flag.
That control was reached by removing `config/crew-remote-control` under the pre-inversion default; the same launch command is what a home reaches today by writing `off` in it.

## The composed session name, live (run B)

Run A was captured before two later corrections: the default was inverted to on, and the session name stopped being the bare task id.
Run B closes exactly that gap on claude `2.1.237`, with the flag typed by default and composed names.

The name emitted today is `<task-id>.<home-basename>.<launch-token>`, bounded at 52 characters: at most 32 task-id characters (`FM_RC_TASK_ID_MAX`), a dot, at most 12 basename characters (`FM_RC_HOME_BASENAME_MAX`), a dot, and 6 hex, which is 32 + 1 + 12 + 1 + 6.
Run B was captured while the shape still carried a home-path digest and a wider bound, so its worker A name reads `rc-on-spawn.firstmate-28f6a8` rather than `rc-on-spawn.firstmate.4b1c9d`; both are the same length and the same character class, and the current bound is less than half the length this run proved acceptable, so this evidence covers the current shape.

Two concurrent workers were launched:

```
A  rc-on-spawn.firstmate-28f6a8                                   28 chars
   -> accepted; session_01V2wDzr5H6XG6gEpA1xJuWu

B  "worstcase: aaaa...aaaa.firstmate-secondmate-platform-infra-very-long-home-name-28f6a8"
                                                                 138 chars
   -> accepted; session_01D1zvWpRSawJtXxaJhh7vX2
```

Worker B's name was deliberately longer and more hostile than anything `fm-spawn` can emit: at 138 characters it is nearly three times the 52-character bound, and it contained a space and a colon, neither of which can survive the `[A-Za-z0-9._-]` sanitization the name builder applies.
That makes it a strictly stronger result than the emitted worst case rather than a test of the exact emitted shape.

Both delivered the positional brief as the session's first user turn AND executed it, so the flag's optional-argument form did not swallow it even with a name that long:

```
$ cat .../rcv/a-ok.txt .../rcv/b-ok.txt
RCV-A-OK
RCV-B-OK
```

Two distinct concurrent sessions, so composing the name does not collapse two workers into one session.

The pane stayed an ordinary interactive TUI, matching the run A observations:

```
/remote-control is active · Continue here, on your phone, or at https://claude.ai/code/session_...
⏵⏵ bypass permissions on (shift+tab to cycle) · esc to interrupt · ← for agents /rc
```

## Re-established after the launch template moved (run C)

Runs A and B predate 124 commits of upstream change to `bin/fm-spawn.sh`, including two that touch this exact launch: the claude template gained the `/bug` feedback-draft controls, and a no-mistakes ship is now delivered a rendered `launch-brief.md` rather than its `brief.md`.
Run C re-established, on claude `2.1.260`, that the flag still lands correctly inside that changed template.

```
$ FM_CREW_REMOTE_CONTROL_LIVE=1 bash tests/fm-crew-remote-control-live-e2e.test.sh
# subject: claude 2.1.260 (Claude Code) at /home/tavi/.local/bin/claude
# session name: rc-live-guard.home.10da61 (25 characters)
ok - claude 2.1.260 (Claude Code) advertises --remote-control and firstmate types it with a per-launch name
# all fm-crew-remote-control-live-e2e checks passed
```

Two paths around the launch also changed after the flag was designed, and run C establishes that Remote Control leaves both intact rather than assuming it:

- `bin/fm-spawn.sh` now moves this home's backlog item to In flight itself, after the launch has been delivered.
  The probe and the flag resolve before that commit point and cannot fail a spawn, so they cannot leave an item In flight with no worker; a case in `tests/fm-crew-remote-control.test.sh` spawns default-on against a real backlog and asserts both the flag on the launch and the resulting `in_flight` row, and `tests/fm-backlog-atomicity.test.sh` exercises the same transition against the real installed claude.
- An ordinary steer is now a durable inbox record plus one constant doorbell line rather than typed payload.
  A case in the same suite steers a default-on worker through the real `bin/fm-send.sh` and asserts the durable record carries the body, the body never reaches the terminal, and the doorbell does.

## The user-scope settings key does not replace the flag (run D)

Claude Code has its own user-scope setting for this feature, `remoteControlAtStartup`, described by the CLI as "Start Remote Control bridge automatically each session".
Run D, on claude `2.1.266` on 2026-09-09, establishes that setting it does NOT make the launch flag redundant, and records which explanations were ruled out.

The setting was present at user scope while three fm-spawn'd workers were running:

```
$ python3 -c "import json;print(json.load(open('$HOME/.claude/settings.json'))['remoteControlAtStartup'])"
True
$ stat -c '%y' ~/.claude/settings.json
2026-09-09 09:15:00 +0300
```

No spawned worker carried the flag, while the one session that did have Remote Control had it typed by hand:

```
$ ps -eo pid,args | grep -E '^\s*[0-9]+ claude '
1100012 claude --remote-control master --dangerously-skip-permissions
3914528 claude --dangerously-skip-permissions --settings {"feedbackDrafts":"off",...} --model opus --effort xhigh ...
3963363 claude --dangerously-skip-permissions --settings {"feedbackDrafts":"off",...} --model opus --effort high ...
4006318 claude --dangerously-skip-permissions --settings {"feedbackDrafts":"off",...} --model opus --effort high ...
```

Worker `4006318` started at 09:20:40, after the 09:15 settings write, so it is the one uncontaminated case; the other two started at 08:39 and 09:11, before the key existed, and prove nothing either way.
Remote Control was reported absent from that worker's pane while present in a worker that had been given the flag by hand.

Four candidate explanations were tested and ruled out:

- The inline `--settings` JSON displacing the user scope.
  `claude --help` documents `--settings <file-or-json>` as "load ADDITIONAL settings from", and the user scope demonstrably loads in a spawned worker: the `SessionStart` hooks defined only in `~/.claude/settings.json` run in every fm-spawn'd claude worker.
- `--setting-sources` narrowing the loaded scopes.
  `bin/fm-spawn.sh` never passes it, so all of user, project, and local load.
- The `CLAUDE_CODE_REMOTE` kill switch, or the session being classed as a remote workspace.
  Neither holds: `CLAUDE_CODE_REMOTE` is unset in the worker process, and the workspace is local.
- A leaked child-session marker suppressing the bridge.
  The worker process's own environment carries only `CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION` and `CLAUDE_CODE_SEND_FEEDBACK`, read from `/proc/<pid>/environ`; the `CLAUDE_CODE_CHILD_SESSION` value visible inside a Bash tool call is set by that worker for its own subprocesses and is not inherited by the worker itself.

`CLAUDE_CODE_BRIDGE_SESSION_ID` is not a Remote Control indicator and must not be read as one: a worker that started before the setting existed carries one too.

The key is genuinely recognized by this build, so the residue is not a stale or misspelled setting name.
It is resolved through a security-sensitive settings path that accepts the policy, flag, and user scopes and explicitly rejects repo-scoped settings with the message "repo-scoped settings cannot enable Remote Control; set it at user scope (/config)".
Why a correctly-placed user-scope value still did not surface Remote Control on a spawned worker is NOT established by this record.
What is established is the operational fact the feature depends on: on this build, the explicit `--remote-control <name>` flag is the only mechanism observed to make an fm-spawn'd worker reachable.

Run D also re-established the capability verdict itself on `2.1.266`, through the token-free guard:

```
$ FM_CREW_REMOTE_CONTROL_LIVE=1 bash tests/fm-crew-remote-control-live-e2e.test.sh
# subject: claude 2.1.266 (Claude Code) at /home/tavi/.local/bin/claude
# session name: rc-live-guard.home.098e0d (25 characters)
ok - claude 2.1.266 (Claude Code) advertises --remote-control and firstmate types it with a per-launch name
# all fm-crew-remote-control-live-e2e checks passed
```

The flag is also the only mechanism that can name the session.
`--remote-control-session-name-prefix <prefix>` documents its default as `hostname`, so an auto-started bridge would label every worker on this box identically, which is what the composed per-launch name exists to avoid.

## What this record does not cover

The claude.ai and phone-app rendering of the name was not exercised; it is not observable from this box, so the evidence stops at claude reporting the session active with its URL.

The turn-end hook, the `claude-hook` busy source, and `bin/fm-crew-state.sh` reading the worker were NOT re-run in runs B or C.
They remain covered by run A on claude `2.1.235`, and neither the name shape nor the template's added options change the flag's own effect, while those hooks are worktree-scoped through `<worktree>/.claude/settings.local.json` rather than session-scoped, so neither later run had anything to disturb there.
Run C's steer coverage is deterministic rather than live: it proves firstmate's own steering plane is untouched, not that an authenticated claude accepts the steer, which remains run A's evidence.

The capability probe that decides whether the flag is typed at all has no live coverage beyond the guard named under "Refreshing this record" below; no live run has exercised an installed claude that lacks the option, because none is installed on this box.

No live run has exercised the per-launch launch token itself, which arrived after run B: what a relaunch emits, and that it differs from the launch before it, is pinned deterministically by `tests/fm-control-relaunch.test.sh` against the `spawn_gen` value that relaunch records, not by a live claude.
Run B's evidence carries the part a real claude decides - that a name of this character class and length is accepted - because the token only changes which characters sit in a field claude already accepted.

Run D did not determine WHY the user-scope `remoteControlAtStartup` key failed to start a bridge on a spawned worker; it establishes only that it did not, and which explanations are excluded.
A live interactive control launch was deliberately not run, because it would open real Remote Control sessions on the operator's account.

Only the tmux backend was exercised.
Remote Control rides claude's own launch command rather than any backend mechanism, so no backend-specific behavior is expected, but herdr, zellij, orca, and cmux are unverified for this flag.

## Refreshing this record

Re-run the deterministic half with:

```
bash tests/fm-crew-remote-control.test.sh
```

That suite drives the real `bin/fm-spawn.sh` and pins the launch command for the default claude crewmate and scout, an explicit `off`, an explicit `on`, an unrecognized value, the composed session name and its caps, every capability-probe direction including which verdicts are cached, codex, opencode, grok, pi, and cursor, a raw launch command, and a secondmate launch.
kimi and muse are the two verified adapters it does not cover, because both need a real installed binary - and muse a stored credential - to reach their launch step; neither carries the placeholder, which is the structural reason no adapter but claude can receive the flag.
`tests/fm-control-relaunch.test.sh` owns the matching relaunch case, because re-resolving the knob on every relaunch, and starting a new session rather than reusing the previous name, are properties of the relaunch path rather than of the knob.
Neither needs a claude binary or a credential, so CI enforces both everywhere.

Re-run the capability half against the installed claude with:

```
FM_CREW_REMOTE_CONTROL_LIVE=1 bash tests/fm-crew-remote-control-live-e2e.test.sh
```

That guard drives the real `bin/fm-spawn.sh` against the real installed claude, so it fails naming the harness and version if claude stops advertising `--remote-control` or its help wording drifts past the probe, and it reports an absent claude as a failure rather than a silent pass.
It consumes no model tokens: the only real claude invocation is `--help`, and the launch command is captured rather than run.

The rest of the live half above needs an authenticated claude and must be re-run by hand after a claude upgrade that touches Remote Control, the hook surface, or the launch flags.
