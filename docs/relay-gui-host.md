# GUI-capable relay task hosts

How firstmate dispatches work that needs a real screen to a machine that has one, and the empirical record behind every choice in it.

This is the reverse of [`docs/relay-host.md`](relay-host.md), which sends work from a laptop to a headless server.
Here a headless server sends work to the laptop, because some work can only be done where there is a display.
That document owns the transport, the verb protocol, the security model, and the measured latency; this one owns only what is different about a host with a screen.

Measured 2026-08-01.
Control machine: Debian 5.15, x86_64, bifrost 0.0.165.
Task host: macOS 26.5.2, arm64, bifrost 0.0.167, tmux 3.5a, Swift 6.x.
Relay: `bifrost.bytedance.net`, an internal address.

## The constraint everything else follows from

**An agent must not be a descendant of a launchd job.**

A `claude -p` started from one wedges permanently in `openat(2)`: ten minutes, 0.26 s of CPU, not one request sent.
The identical binary with the identical prompt works every time when its ancestry runs through a desktop app.
Measured three ways - inside tmux, launched directly, and through a login shell - and all three wedged under launchd, while a desktop-parented host session worked first time.

Excluded as causes: environment variables (restoring `LANG` and `__CF_USER_TEXT_ENCODING` did not help, nor did going through a login shell), tmux itself (a direct launch wedged too), the network (`api.anthropic.com` answered 405 in 0.74 s from under launchd), the keychain (`security` read credentials with exit 0), and binary startup (`claude --version` returned in one second).
What remains is a suspicion about TCC/XPC responsible-process attribution, and it is not pinned down.
The full record is `data/fm-mac-as-worker-demo/report.md` and `demo/evidence/05-tmux-under-launchd-hang.log`.

So this is built as a workaround and is not presented as a fix.
The consequence that shapes the whole design: **bifrost's daemon is itself launchd-managed on macOS, so the verb may not create the session provider a dispatched agent will run in.**
It can only hand work to one that already exists and was started from the desktop, and refuse when that is not there.

## The desktop host session

A tmux server on a socket the host config names, started from a terminal window on the machine's own desktop by `control-root/fmr-host-session.sh start`.

The verb pins `FM_TMUX_SOCKET` to that socket before running the host's own `bin/fm-spawn.sh`.
Without the pin, `bin/fm-tmux-lib.sh` would resolve a socket from an environment the verb does not have, find no server, and create one - as a descendant of the launchd-managed bifrost daemon, which is precisely the wedging ancestry.

### Provenance is captured at start, because it cannot be recovered later

A tmux server daemonises.
Its parent is pid 1 from the moment it exists, so nothing can look at a running server and tell where it came from.
`start` therefore classifies its OWN ancestry and records the verdict in the marker file:

| Class | What it means | What `start` does |
|---|---|---|
| `desktop` | an `.app` bundle executable appears in the chain | starts, no warning |
| `indirect` | no `.app`, but a terminal multiplexer appears, and its own origin is unreadable | starts, warns that desktop ancestry is not proven |
| `adopted` | a tmux server already owned the socket and was taken over as-is | starts, warns that nothing is claimed about its ancestry |
| `launchd-job` | the chain reaches launchd with neither of the above | **refuses**, naming the measured wedge and what to do instead |

Only `launchd-job` is refused, because it is the only class known to break.
Refusing what cannot be disproven would make the tool unusable on a machine whose fleet server is already up, and would not buy a guarantee this script can actually make.

`stop` never kills an `adopted` server.
On the machine this was built for, the adoptable server is the captain's own fleet, and killing it would take every running agent with it; `stop` clears the marker and says so.

### How to start it, and the trade that choice makes

Open a terminal window on the machine's desktop and run `start`.
That is the whole procedure.
It changes no system setting and needs no authorization.

What it costs is durability: the session does not come back by itself after a logout or a reboot, and dispatch refuses until someone starts it again - loudly, naming the command.

The durable alternative is a real **Login Item** (System Settings > General > Login Items, or an app registered through `SMAppService`) running the same `start`.
It survives reboots and keeps desktop ancestry.
It is not done here because adding one changes the machine owner's system settings, which is the owner's decision rather than this code's.

A **LaunchAgent is not an alternative.**
It is the one shape that reintroduces the wedge, which is why `start` refuses launchd-job ancestry outright.

## The three checks, and why they run before the claim

A claim tells the control machine "this work has an owner".
Claiming and then failing is strictly worse than refusing: the control side stops looking for anywhere else to run the work, and the task sits owned by a machine that cannot do it.

So all three are asked BEFORE `verbs/fmr-verb.sh`'s claim `mkdir`, in the same process, which also leaves no window between the answer and the claim.
The standalone `preflight` verb exists only so the control side can get a readable reason without staging a brief; it is a courtesy, never the gate.

| Check | How | Refusal code |
|---|---|---|
| awake | none needed - a sleeping machine does not run the verb at all, so reaching the check IS the answer | (control side; see below) |
| unlocked | `CGSSessionScreenIsLocked` from `ioreg -n Root -d1 -a` | `guilocked`, or `guilockunknown` |
| host session | the marker's server is the live owner of the socket, in this login | `guisession` |

Two details that are easy to get wrong, and are gotten right deliberately:

- **The lock key is absent entirely** on a session that has not been locked since login, so absence means unlocked.
  But an ioreg answer that cannot be read at all is `unknown` and **refuses**: a screen whose state cannot be read is not a screen known to be unlocked.
- **"Never started" and "started and then died" are different answers.**
  No marker is `absent`; a marker whose server is gone is `dead` and names the pid and start time; a different server on the socket is `replaced`; a marker from a previous desktop login is `stale`.
  The operator does different things about each, so the refusal says which one it is and names the exact command that fixes it.

A GUI host declared `GUI=1` whose preflight library is missing refuses with `guilib` rather than skipping the checks.

### What is deliberately not used as a signal

All three were measured and rejected:

- `$SECURITYSESSIONID` - a launchd job never receives it, and it is an ordinary environment variable anything can set.
  The kernel's audit session id (`getaudit_addr(2)`) is the real one, and is what the marker records.
- `launchctl managername` - a process reporting `Background` screenshots and opens a headed browser perfectly well.
  It says which launchd domain manages a job, not whether the WindowServer will talk to it.
- Ancestry at check time - see above; it is gone by then.

## Queued dispatch

A locked screen, a downed host session, and a sleeping machine are all TRANSIENT.
The right answer is to hold the dispatch and try again, not to lose it and not to pretend it started.

`bin/fm-spawn.sh --host` therefore exits **3** for a refusal that passes: the task is not live and not lost.
It writes `state/<id>.relay-pending` with everything needed to dispatch, and arms the task's wake check immediately rather than leaving that to a later step, because retrying is the check's whole job and a queued dispatch with no check would sit forever.
When the dispatch lands, the same check reverts to reporting the task's events.

First attempt and every retry run the identical code path, `bin/fm-relay-host.sh dispatch`, so they cannot drift.

The queue lives on the CONTROL side because a sleeping machine has no queue, and surviving the host being unavailable is the entire point.

What wakes the supervisor, and what does not:

- The dispatch finally landing - always.
- A refusal that is simply still true - never. A locked screen every five minutes is not news.
- A refusal that has persisted past `FM_RELAY_QUEUE_WAKE_AFTER` checks (default 3) - once.
- A refusal whose REASON changed - once more. The screen being unlocked while the host session went down is new information, and hiding it behind the first alert would misreport what the machine is waiting on.
- A failure waiting will not fix - once, and the queued record is kept so a supervisor can see and decide. Queued work is never silently dropped.

The reason is recorded in the queue record by the only side that sees the raw verb protocol.
Nothing downstream re-derives a verdict by parsing a human sentence, which would classify a refused-but-reachable host as an unreachable one.

`ALREADY_CLAIMED` is treated as permanent even though it exits **zero**: it reports a live task on the host, which succeeded as a question and failed as a dispatch.
Classifying on exit status alone would file it as a successful spawn and then write metadata from a claim report.

## Ordered procedure

The host has no inbound SSH, so the control machine cannot push anything to it.
Steps 2 and 4 run on the host, by its own operator.

1. Register the host in the control machine's `config/relay-hosts.json` with `"gui": true` and a `tmux_socket`; [`docs/configuration.md`](configuration.md) owns that schema.
2. On the host: `bin/fm-relay-conn.sh deploy-local <host>`, reading a matching record from its own home. Same files and same config text as the SSH path, only a different transport.
3. On the control machine: `bifrost remote conn up --ssh-key <host key>`.
4. On the host, immediately: `bin/fm-relay-conn.sh tighten-local fm-relay-verbs`, which binds every grant to the verb allowlist and asserts that none binds the built-in full-access policy.
5. On the host, from a desktop terminal window: `<control-root>/fmr-host-session.sh start`.
6. On the control machine: `bin/fm-brief.sh <id> <repo> --scout --host-home <host FM_HOME> --host-root <host checkout> --gui-host`.
7. `bin/fm-spawn.sh --host <host> <id> <project> --scout --harness claude`. Exit 3 means queued, and it will dispatch itself.
8. Supervise exactly as [`docs/relay-host.md`](relay-host.md) describes; nothing downstream of dispatch differs.

### The pairing window this cannot close

`bin/fm-relay-conn.sh up` refuses a host it cannot reach by SSH, rather than reporting a pairing it could not secure, and that refusal is kept.
Steps 3 and 4 are therefore two operators, and between them the host carries a full-access grant.

That window is not introduced here.
`bifrost remote conn up` ADDS a grant bound to the built-in `ssh-key-full-access` policy and cannot be told to create a narrow one - `ssh-key create` still has no `--roots`, `--ops`, or `--shell-policy` on 0.0.167 - so the window exists on the SSH path too and is merely closed faster there.
The verb table exposes no grant management at all, in either direction, so a paired caller can never widen its own authorization through the channel it was granted.

Anyone evaluating a standing pairing should evaluate it as "that machine holds a key equivalent to this user's shell on the peer", because that is what it is.

## The GUI brief

`bin/fm-brief.sh --gui-host` adds the graphical contract to a remote-host brief:

- Run a private browser instance with its own profile directory, and leave every already-running browser alone. The machine owner's browser is not to be attached to, closed, or changed.
- Prove a window exists rather than asserting it. `CGWindowListCopyWindowInfo` with `optionOnScreenOnly` lists a real window at layer 0; a headless browser never appears in that list at all, which is exactly what makes it proof.
- A locked screen is not a broken screen: windows still exist and can still be driven, but a full-screen capture returns the lock screen and a per-window capture is refused outright. Say which shot could not be taken rather than shipping the lock screen as if it were the page.
- A dark display is not a failure either: a capture taken with the display asleep is a valid, entirely black image with exit status 0. Judge it by size, not status.

## What was measured on 2026-08-01

Control machine 151, task host this Mac, over the real relay.

**Reverse channel.** `fm-relay-host.sh ping macgui` from 151 returned `OK pong host=MJFWWTL4N2 proto=fmr-v1 home=/Users/bytedance/.fm-relay/host-home gui=1`.
This is the first task dispatched host-to-control in either project phase; [`docs/relay-host.md`](relay-host.md) previously listed the reverse direction as unverified.

**Locked-screen refusal, at the claim stage.**
With `CGSSessionScreenIsLocked` genuinely `<true/>`, `fmr-verb.sh spawn acc-locked scout firstmate brief.md` answered:

```
ERR guilocked the screen is locked, so a dispatched agent would start work nobody can see or unblock
```

The claim directory and the host's `state/` were both still empty afterwards, which is the property that matters: nothing was claimed.

From 151, the same refusal came back through `bin/fm-spawn.sh --host`, which exited 3 and queued it:

```
held: acc-gui1 is queued for macgui - guilocked the screen is locked, ...
queued on macgui: acc-gui1 will dispatch by itself once that machine can take it
```

with the wake check armed at mode 0700, its bytes registered, and no task metadata written.

**Host session provenance.**
Started from an Orca desktop terminal, the marker recorded a chain ending in the app bundle, and the classifier called it `desktop`:

```
provenance=desktop
starter_chain=33994 33084 bash
starter_chain=33084 33070 /bin/zsh
starter_chain=33070 31106 /usr/bin/login
starter_chain=31106 30788 /Applications/Orca.app/Contents/Frameworks/Orca Helper.app/Contents/MacOS/Orca Helper
starter_chain=30788 1 /Applications/Orca.app/Contents/MacOS/Orca
```

**Never-started versus died.**
`status` on the live session reported `ok desktop host session pid 34040, started 2026-08-01T10:56:21Z, provenance desktop`.
The tmux server was then killed behind its back, and the same command reported:

```
dead the desktop host session started at 2026-08-01T10:56:21Z (server pid 34040) is no longer running
```

**A host that cannot answer at all.**
Pointed at an unreachable client id - the protocol shape a sleeping machine produces - the dispatch queued with `reason=host unreachable - asleep, powered off, or the link is down`, and the armed check printed nothing on the first two runs, reported once on the third, and went quiet again on the fourth.
When the host answered again, the check noticed the answer had CHANGED and reported the new reason rather than staying silent behind the first alert.

**No desktop host session, screen unlocked.**
With the session stopped, `spawn` answered, and again the claim directory and the host's `state/` were both empty afterwards:

```
ERR guisession no desktop host session has been started on this machine; start it on this machine
with /Users/bytedance/.fm-relay/control-root/fmr-host-session.sh start
```

**A GUI task, dispatched from 151, run on the Mac's real screen.**
After the machine's owner unlocked it, `fm-spawn.sh --host macgui acc-gui3 gui-probe --scout --harness claude` returned `OK spawned=acc-gui3 trust=working`, having first passed `preflight=ok gui=1 awake=yes locked=no session=ok`.

The agent wrote a page carrying the token 151 had issued, opened it in a headed Chrome with its own `--user-data-dir`, and this crewmate - not the agent - independently listed the on-screen windows at 12:14:27Z:

```
windowid=57780 pid=40037 layer=0 owner="Google Chrome" title="FMP2-20260801T121210Z-5ba4…@ 2026-08-01T12:13:32.168Z" bounds=22,54,1200x1041
```

The agent's own `windows.txt` records the identical window id, pid, layer, and title.
A headless browser never appears in that list at all, which is what makes it proof.
The screenshot is 1306536 bytes at 3456x2234 - the physical Retina panel, not the ~144 KB all-black a dark display produces - and shows the page rendered on the unlocked desktop.

The agent's recorded process chain ends in the desktop host session, which is the whole architecture in one place:

```
43534 35691 /bin/zsh
35691 34688 /Users/bytedance/.local/bin/claude
34688 34627 /bin/zsh
34627 34460 treehouse
34460 97811 -zsh
97811     1 tmux          <- the desktop host session, marker server_pid=97811, provenance=desktop
    1     0 /sbin/launchd
```

The machine owner's own browsers were untouched throughout, verified before and after by the agent and independently here.

**Artifact round trip.**
`bin/fm-relay-host.sh report-pull acc-gui3` fetched the 10244-byte report, and both machines independently computed `0917c80331bba188ba8de5abfd06f4c3eb868d88833c3eb232b99c22d11ae959`.
Teardown then succeeded, killed the window, returned the worktree to its pool, cleaned the control-side records, and retained the report.

**A GUI host must not share a treehouse pool with the machine's own firstmate.**
The first attempt used a clone of firstmate as the host's project, and `treehouse get` handed out a worktree from the pool keyed to the CONTROL machine's own firstmate checkout, because the two clones share an origin.
`bin/fm-spawn.sh`'s isolation assertion caught it and refused to adopt that path, which is exactly its job.
A GUI host running on a machine that also runs its own firstmate therefore needs projects that do not collide with that machine's own repositories.

**Phase 1 is unaffected, verified live rather than assumed.**
With the Phase 2 client and a Phase 1 host record carrying no `gui` field, `ping box151` answered normally against the OLD deployed verb, and `spawn` never calls `preflight` for a non-GUI host.
After redeploying over SSH, that host answers `gui=0` and its control root contains the verb and config only - neither GUI file.

**A Phase 1 bug this surfaced.**
`verbs/fmr-verb.sh` removed the claim directory before reading the spawn log, and the log lives inside that directory, so every spawn failure reported an empty reason: the control side was told "it failed" and never told why.
It reads the log first now.

## Not verified

- **A real sleep and wake cycle.**
  What was exercised is the protocol-equivalent - the host cannot be reached, the dispatch is held, and it lands once the host answers again.
  That is NOT the same event: a real sleep turns every established TCP connection into a dead one on wake.
  The design opens a fresh connection per attempt and retries silently on failure, so it should absorb that, but it has not been run.
  Scheduling a wake needs `sudo` and `pmset sleepnow` would cut the session doing the measuring.
- **The queued-to-live transition driven by a real watcher.**
  The queue, the silence, the threshold, the changed-reason wake, and the retry were each exercised, and the armed check was run exactly as the watcher runs it - but by hand, because the control machine had no watcher armed.
- **A real engineering task with a graphical session.**
  What ran was a probe page. A browser task carrying an SSO login state touches more surface.
- **Whether an `indirect` or `adopted` host session actually avoids the wedge.**
  Only `desktop` was exercised. The other two are reported rather than blocked precisely because nothing here can prove them either way.
- **Whether the wedge still reproduces at all.**
  The workaround was built from the earlier measurement and never re-tested against a launchd-parented agent, because doing so means deliberately hanging one for ten minutes.
