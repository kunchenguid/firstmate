---
name: lavish-repair
description: >-
  Agent-only recovery playbook for diagnosing and repairing served Lavish Editor boards that remain loading, lose live feedback, report that the agent is not listening, or prompt consideration of a Lavish or browser process restart.
  Use before touching Lavish, Chrome, or chrome-devtools-axi processes during a surface incident.
  Do not use it to design or revise a working decision board; use `lavish-decision-boards` for that.
user-invocable: false
metadata:
  internal: true
---

# lavish-repair

Prove the failing layer before changing any process.
Use `lavish-axi --help` and its command help as the authority for current serving and polling mechanics.
Consult the `data/learnings.md` content already included in the session-start digest for relevant prior incidents without violating the digest's read-once rule.

## Fleet-wide process safety gate

From a firstmate session, `pkill -f <pattern>` is a FLEET-WIDE DESTRUCTIVE COMMAND.
The `-f` matcher searches each process's entire command line, and a crewmate launcher carries its full brief in that command line.
An ordinary English phrase or tool name in a pattern can therefore select unrelated crew processes.

Before sending any process signal:

1. List candidates with `pgrep -fl '<candidate-pattern>'` and read every row.
2. Inspect each candidate with `ps -p <pid> -o pid=,ppid=,etime=,command=`.
3. Reject every shell, harness, crewmate launcher, or process whose role is not proven.
4. Signal only one verified explicit PID with `kill <pid>`.
5. Re-list and verify the intended result before considering another signal.

Never pipe unfiltered `pgrep` output into `kill`.
If an external control path leaves no explicit-PID option, constrain its matcher to a runtime-specific shape that ordinary prose cannot contain, such as the full resolved binary path plus exact operational arguments or a freshly generated `user-data-dir=/tmp/<opaque-id>` path.
List and inspect candidates again immediately before acting, and abort if any crew or shell appears.
A full path copied into a brief is no longer a safe matcher.

The concrete counter-example is the 2026-07-28 incident.
Firstmate ran `pkill -f 'chrome-devtools-axi'` after several crewmate briefs had mentioned that tool in ordinary instructions.
Fifteen of sixteen live crewmate panes died, and a Codex account was pushed to a re-authentication prompt.
The browser count was not proof of the failing layer, and the pattern matched the briefs rather than only browser bridges.

## Diagnose in cheapest-first order

Gather the source file and session URL for every affected board before changing anything.
Run every stage below and keep its evidence.

### 1. HTTP serving

Run this against each affected `/session/<id>` URL:

```sh
curl -s -o /dev/null -w '%{http_code} %{time_total}\n' '<session-url>'
```

A fast local `200` proves that the HTTP serving path responds, not that the live channel works.
It moves the fault boundary to the live channel, listener, or browser.
Do not touch Chrome merely because the visible page looks slow.
A refusal, timeout, or non-`200` keeps the server layer in scope.

### 2. Live-channel listener leak

Check the default detached-server log:

```sh
grep -c MaxListenersExceededWarning ~/.lavish-axi/server.log
```

When `LAVISH_AXI_STATE_DIR` is set, use its `server.log` as documented by `lavish-axi server --help`.
A nonzero count while multiple boards are simultaneously wedged is the known highest-probability live-channel failure.
The signature is warnings for 11 `reload`, `agent-reply`, and `agent-presence` listeners against the default EventEmitter limit of 10.
The log appends across restarts, so distinguish historical warnings from the current server before claiming an active leak.
Inspect recent warning lines and compare their `(node:<pid>)` value with the server PID verified under the repair procedure below.

### 3. Listener presence

List poll candidates:

```sh
pgrep -fl 'lavish-axi.*poll'
```

Apply the process safety gate to the output.
For each affected board, verify an actual Node process whose command is `lavish-axi poll <source-file>` for that board's source path.
A shell or crewmate command that merely quotes those words is not a listener.
A board without a live poll is inert by construction because the page has no agent listener.

### 4. Browser boundary

Consider browser-side exhaustion only after HTTP is fast, the current server lacks the listener-leak signature, and the exact board has a live poll.
A large Chrome, headless, or bridge process count is a lead, not proof.
Use `chrome-devtools-axi --help` and the relevant command help to inspect the exact board page and establish the browser failure before changing browser state.

## Repair the proven layer

Use the least-destructive branch that matches the evidence.

### Server absent or not serving

Re-serve each source file without opening another browser window:

```sh
lavish-axi '<source-file>' --no-open
```

The command starts the local server when needed and prints the session URL.
Re-run the HTTP check, then attach a poll for every open board.
If serving still fails, use `lavish-axi server --help` and the server log for the startup diagnosis rather than touching Chrome.

### Poll absent

Start the missing listener and leave it running:

```sh
lavish-axi poll '<source-file>'
```

Long-poll silence is normal.
Confirm the actual poll process for that exact file with the listener-presence check.
Do not restart the server or browser when attaching the missing poll repairs the board.

### Current server has the listener leak

List possible server processes without signaling them:

```sh
pgrep -fl 'lavish-axi/dist/cli.mjs server'
```

This selector can also appear inside a crewmate brief, so its output is discovery evidence only.
Inspect every candidate with the safety-gate `ps` command.
Confirm the intended Node process has the Lavish server entry point and expected `server --port <port>` arguments.
When useful, corroborate the listener PID for the expected port with `lsof -nP -iTCP:<port> -sTCP:LISTEN`.
If the candidates do not resolve to exactly one intended server, stop without signaling anything.

Terminate only the verified numeric server PID:

```sh
kill <server-pid>
```

Re-serve every affected source file with `lavish-axi '<source-file>' --no-open`.
Reattach `lavish-axi poll '<source-file>'` for every board and leave each poll running.
Repeat the HTTP, current-log, and listener checks before reporting recovery.

Session URLs survive a server restart when the same source files are re-served because Lavish derives session identity from each canonical source-file path and retains it in state.
Do not treat the restart as URL loss or replace working links preemptively.

### Proven browser failure

Protect any unsubmitted captain input before reloading or reopening a page.
Use current `chrome-devtools-axi` help to target the exact board page, and prefer repairing or reopening only that page with its existing session URL.
Do not kill `chrome-devtools-axi` processes by name.
If an exact browser process must be terminated, apply the fleet-wide safety gate and act only on a verified explicit PID with a run-specific binary or `user-data-dir` identity.
Recheck the same URL and poll connection after the browser-side repair.

## What survives a crew kill

A process-kill incident is serious but does not erase landed or worktree-backed work.

- Crewmate reports and completion artifacts under `data/<id>/` survive.
- Leased worktrees, their working files, and their commits survive.
- Pushed branches and PRs survive remotely.
- Only the live agent process and its in-memory session are lost.

Recover a dead crewmate by respawning it from its recorded worktree and brief.
Load `stuck-crewmate-recovery` and `harness-adapters` before performing that recovery.
