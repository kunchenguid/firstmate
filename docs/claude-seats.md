# Claude seats: running workers on a second account

A **seat** is one Claude account that Firstmate's workers can run on.
Switching seats changes which account new workers bill to, without disturbing any worker already running.

Use this when one account's weekly limit is close and a second account is available, or when work should be split across accounts deliberately.
[`docs/configuration.md`](configuration.md) owns the setting schema; `bin/fm-seat.sh --help` owns the exact command surface.

## How it works, in one paragraph

Claude Code reads its profile - settings, session history, and credentials - from the directory named by `CLAUDE_CONFIG_DIR`, defaulting to `~/.claude`.
It derives that profile's macOS Keychain service name from a hash of the directory path, so each profile directory has its own credential store.
A seat is therefore just a directory, and switching seats is just choosing which directory the next worker launches with.
Firstmate never logs in, never copies a credential between profiles, and never touches the Keychain: only the account owner signs a seat in, personally.

**Keep every seat under the seats root, and leave the default profile out of the rotation.**
The default profile (`~/.claude`) is the account owner's own interactive login.
It changes whenever they sign in somewhere else, and nothing here can tell which account it currently holds, so an automatic switch must never land workers on it.
`switch --next` and the threshold watch therefore rotate only among named seats under the seats root; `switch default` remains available as an explicit, manual choice.
Creating one named seat per account, and leaving the default alone, keeps every account Firstmate uses identifiable and stable.

## Adding a second seat

Three steps, and only the second one needs the account owner.

**1. Create the seat.**

```
bin/fm-seat.sh add work
```

This creates an empty profile directory (by default `~/.claude-seats/work`) and prints the login command for step 2.
It writes nothing else and reads no credential.

**2. The account owner logs in.**

This step cannot be automated and cannot be done on the owner's behalf.
In a terminal, the owner runs the command step 1 printed:

```
CLAUDE_CONFIG_DIR=~/.claude-seats/work claude
```

then types `/login` in that session and signs in as the account this seat should bill to.
Claude Code stores the resulting credentials under a Keychain entry belonging to that directory, so they never mix with the default login.
The owner can then exit that session; it was only needed to carry out the sign-in.

**3. Confirm the seat is usable.**

```
bin/fm-seat.sh probe work
```

`logged-in` means the seat is ready.
`not-logged-in` means the profile was read and holds no login, so step 2 has not completed.
`unknown` means the probe could not decide; on macOS that is how a seat reads both before step 2 and after it until the one-time Keychain approval described under [Limits worth knowing](#limits-worth-knowing).

## Switching now

```
bin/fm-seat.sh switch work
```

That is the whole manual switch, and it takes effect immediately for the next worker launched.
`bin/fm-seat.sh switch default` returns to the ambient login.

A switch is refused when the target seat is not confirmed logged in, because every worker sent there would fail on its first message; `--force` crosses only an `unknown` verdict.

## What a switch does and does not touch

A switch rewrites one setting that only a fresh spawn reads.

- **New workers** launch on the new seat.
- **Running workers** keep the seat they started on. Their seat is recorded in their own task record at launch, and nothing rewrites it.
- **Relaunches** of an existing task reuse that recorded seat, never the current setting. Relaunch is the one path that starts a replacement agent for a task that already exists, so it is the one place this could have gone wrong. This matters beyond billing: a task's session history lives under its profile directory, so moving a task between seats would strand it.
- **Harness-changing relaunches** follow the harness. A task relaunched from another harness onto Claude has no Claude history yet, so it counts as a new worker and gets the active seat, never the default login. A task relaunched from Claude onto another harness records no seat any more.

`bin/fm-seat.sh status` shows the active seat alongside every task's own recorded seat, which is how to confirm a switch left running work alone.

## Switching automatically at a threshold

The automatic path is the same switch, fired by a condition instead of by hand.
It is off until configured; there is no default that moves accounts on its own.

```
bin/fm-seat.sh threshold 15     # switch when the active seat drops to 15% remaining
bin/fm-seat.sh arm
```

`arm` registers one condition-to-action watch: the condition reads the same quota surface the rest of the fleet reads, and the action is `switch --next`, which rotates to the next logged-in seat under the seats root.
The seat set is read fresh at each step, so nothing assumes which seats exist.
It runs on the supervision cycle that already exists rather than a daemon of its own, and it fires **at most once**, which is what makes it edge-triggered.
Re-arm after it fires to watch the next crossing.

Only the account-level windows (`all_models` and `all_products`) count toward the threshold, the same scopes the dispatch chooser applies to a worker with no specific model; a model- or product-only window such as an Opus weekly limit does not trip a switch on its own.
For the `default` seat the condition reads the same profile a new worker on it gets, which is firstmate's own `CLAUDE_CONFIG_DIR` when that is set.
An unreadable quota, or one that reports no account-level window, is treated as an error, never as a threshold crossing, so a failed read never switches accounts.
A rotation with no other logged-in seat under the seats root refuses rather than pretending to switch, and never falls back to the default profile.

`bin/fm-seat.sh threshold off` clears the threshold, and `bin/fm-seat.sh retire` stops the watch.

## Secondmate homes

All three seat settings are inherited into this machine's local secondmate homes through the primary-authoritative configuration contract, so a secondmate's own Claude crewmates launch on the same seat as the primary's.
Every switch, manual or automatic, runs `bin/fm-config-push.sh --local-only` right after it changes the primary's seat, so running local secondmates pick up the new seat without being stopped, and the switch prints which homes were updated and which were not.
A failed push never undoes the primary's switch: it is reported, those homes keep spawning on their previous seat, and re-running `bin/fm-config-push.sh --local-only` retries them.
The push skips remote routes entirely, so a switch never opens SSH, never waits on another machine, and reports only this machine's homes.
Remote secondmate homes on other machines never receive seat settings, because a seat is a Keychain-backed profile logged in on this machine only; a remote home keeps its own login exactly as before seats existed.
The seats themselves live outside any firstmate home - by default under `~/.claude-seats` - so the owner logs into a seat once and every home on the machine reaches the same profile.
A home that needs its own set of seats overrides `config/claude-seats-root`.

## Limits worth knowing

The login probe runs `quota-axi` against the seat's profile and treats an `oauth` source as logged in.
Note that `quota-axi --profile-only` is **not** a usable probe here: that flag reads only a credential file and never the Keychain, so on macOS it reports "credentials missing" for a perfectly good seat.

A newly logged-in seat gets its own Keychain entry, and reading it from a different tool can require a one-time macOS approval.
Until that approval is given, the Keychain read is refused, and that refusal looks the same whether the seat was never logged into or is signed in but not yet approved.
The probe cannot tell those two apart, so it reports `unknown` for both, and a plain `switch` refuses.
To settle it, the owner runs `quota-axi --allow-keychain-prompt` once with that seat's `CLAUDE_CONFIG_DIR` set and answers the prompt with "Always Allow"; after that a signed-in seat probes as `logged-in`.
In the meantime `switch --force` accepts the uncertainty: if the seat turns out to be empty, the next worker stops on its first message with `Not logged in` rather than spending another account.
`--force` never overrides `not-logged-in`, which the probe reports only when the evidence positively shows no login.
On macOS that means `not-logged-in` is rarely seen, because an absent Keychain entry reads as unreadable rather than as read-and-empty; on a file-backed credential store, where an empty profile really can be read and found empty, it is reported normally.
`--force` also never switches to a seat with no profile directory under the seats root; create it with `fm-seat.sh add <name>` first.

Two things in the setup flow above are **written from Claude Code's documented behaviour and the isolation this change verified, not from an observed sign-in**, because verifying them would mean logging in, which this work deliberately does not do:

- the exact prompts `/login` shows in a brand-new empty profile, and
- whether signing into a second account affects an already running session on the default profile.

Treat step 2 as the shape of the flow rather than a transcript, and expect the sign-in screens to be whatever the installed Claude Code shows.
What *was* verified directly is the part the mechanism depends on: a profile directory that was never logged into does not fall back to the default account, it stops with `Not logged in`, and each profile gets its own Keychain entry derived from its directory path.

Seat switching covers Claude workers only.
Other harnesses have their own credential stores and are unaffected by these settings.
