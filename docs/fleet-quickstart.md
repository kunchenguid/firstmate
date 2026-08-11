# Fleet quickstart — pick your use case

The fleet add-on does two separable things. **You do not need both**, and the first
one needs no fleet setup:

1. **Per-surface token visibility** — one table showing how much budget is left in
   every AI subscription you own (Claude, Codex, Copilot, Cursor, Grok, Kimi), plus
   a deterministic picker for the pool that still has headroom.
2. **Federation** — several people, each running their own first mate on one host,
   coordinating through a shared work queue so they never collide.

Start at the tier you actually need. Each is independent and additive.

Not sure which one you need?
Ask, before installing anything:

```bash
bin/fm-fleet.sh preflight     # read-only: what this home is ready for, and what each tier still needs
```

It changes nothing.
Tier C is the only tier that ever needs root, and it stays **opt-in**: a home without the `config/admiral` flag behaves exactly as a single-operator home always has.

| | Use case | Root needed? | Setup |
|---|---|---|---|
| **A** | *"Which of my subscriptions still has budget, and which pool should I use?"* | no | ~2 min |
| **B** | *"I have two Claude accounts / a work and a personal one."* | no | ~5 min |
| **C** | *"Three of us share this box and keep stepping on each other."* | once | ~15 min |

---

## Tier A — token visibility and model→surface picker

No fleet, no root, no shared directory. This works in a plain clone.

**Requires:** [`quota-axi`](https://www.npmjs.com/package/quota-axi) on `PATH`, plus
`jq`, `curl`, `python3`. Whichever agent CLIs you use should already be signed in.

```bash
bin/fm-fleet.sh quota     # headroom + spend pace per surface
bin/fm-fleet.sh models    # which surfaces can serve each model family
bin/fm-fleet.sh pick gpt  # -> the best surface to serve that family right now
```

```
SURFACE  HEADROOM  PACE    RESERVE  STATUS         SOURCE       NOTE
claude   50%       ahead   -18      fresh          oauth        observable
codex    100%      behind  +42      fresh          cli-rpc      observable
copilot  71%       —       —        logged_in      custom       live headroom via authed usage reader
cursor   69%       —       —        logged_in      custom       live headroom via authed usage reader
grok     —         —       —        auth_required  unavailable  Grok sign-in required
```

`HEADROOM` is how much of the pool is left; `PACE` and `RESERVE` are how fast you
are spending it. `ahead` with a negative reserve means you have burned that many
percentage points *more* than the window's elapsed share — 50% left but `ahead -18`
is a pool you will run dry on before it refills. `—` means the surface reports no
pace at all (an older `quota-axi`, or a custom reader that only returns a number);
a literal `unknown` means the provider itself said so. Full column semantics:
[fleet-addon.md](fleet-addon.md#per-surface-pace-quota-axi--0115-schemaversion-3).

**Why this exists.** The same model often reaches you through several paid pools —
Claude via an Anthropic subscription *and* via Copilot *and* via Cursor. When one
pool is drained the picker should point at another usable pool instead of leaving
you to guess. The shipped map
`docs/examples/model-surfaces.json` (override: copy it to the gitignored
`config/model-surfaces.json` and edit) maps
each model family to an ordered list of surfaces:

```json
{ "claude": ["claude", "copilot", "cursor"],
  "gpt":    ["codex",  "copilot", "cursor"] }
```

`pick` first drops every surface below `FM_FLEET_QUOTA_MIN` (default 5%), then
prefers the sustainable ones: a surface with headroom to spare beats one already
running ahead of its window, however much raw headroom the latter shows. Among
surfaces of equal standing it walks the list left to right, so the order you write
is still the preference you get.

A surface whose usage cannot be observed is treated **fail-open** (a valid target),
so an unreadable provider never blocks the picker.

### Surfaces whose usage is not locally readable

Some vendors keep usage behind a browser session. For those, supply your own
reader — a command printing a single integer `0-100` (percent headroom):

```bash
cp docs/examples/quota-overrides.json config/quota-overrides.json   # gitignored
```

```json
{ "copilot": "/abs/path/to/firstmate/bin/quota-copilot-usage.sh",
  "cursor": "/abs/path/to/firstmate/bin/quota-cursor-usage.sh" }
```

Two readers ship working, both using the CLI's *own* stored token — no browser
cookie, no second login:

- `bin/quota-copilot-usage.sh` — GitHub Copilot. Reads `~/.copilot/config.json`,
  calls `copilot_internal/user`, and takes the **minimum** `percent_remaining`
  across *metered* quota buckets, so a plan that meters several is bounded by its
  tightest limit.
- `bin/quota-cursor-usage.sh` — Cursor. Uses the CLI access token against Cursor's
  own usage RPC.

Your command owns all secret handling: read the token from a `0600` file and never
put it on `argv`. A reader that fails prints nothing and the surface goes blind —
never an error, never a wrong number.

---

## Tier B — several accounts for one person

Same machine, same user, more than one subscription. Isolation is **per CLI** and
there are three different mechanisms, so the registry records which one applies:

```bash
cp docs/examples/accounts.json config/accounts.json   # gitignored
$EDITOR config/accounts.json                           # replace /home/YOUR-USER
bin/fm-spawn-acct.sh --account claude-work  <normal fm-spawn args...>
```

| Harness | Mechanism | Key |
|---|---|---|
| `claude` | config-dir env | `CLAUDE_CONFIG_DIR` |
| `codex` | config-dir env | `CODEX_HOME` |
| `pi` | config-dir env | `PI_CODING_AGENT_DIR` |
| `cline` | argv flag | `--config` |
| `grok`, `cursor-agent` | api key env | `GROK_API_KEY` / `CURSOR_API_KEY` |

Paths in `accounts.json` are used **literally** — `~` and `$HOME` are not expanded.
Secrets never go in the file: api-key accounts name a `key_file` (a `0600` file in
your own home) that is read at launch into the child's environment, never onto
`argv`. `config_dir` and `key_file` must live under your own home; a path resolving
into another user's `/home/<other>` or `/Users/<other>` is refused.

> **Known limit:** `quota-axi` reports per *provider*, not per *account*, so two
> Claude accounts show one shared number. Per-account discrimination works where
> the CLI keys off its config dir (e.g. `CODEX_HOME`).

---

## Tier C — several people on one host

Each operator runs their **own** first mate as themselves. Nobody reads anyone
else's home. The only shared surface is the fleet directory.

**One-time, root, once per host** — review the script first, it is short and additive.
See exactly what it would change before approving it, with no root and no mutation:

```bash
bash scripts/fleet-root-prereq.sh --check      # reports the delta, exits 1 iff action is needed
sudo FM_FLEET_OPERATORS="alice bob carol" bash scripts/fleet-root-prereq.sh
```

It creates group `agents`, adds those OS users to it, and creates the fleet dir
`2775` (setgid, so new files inherit the group). Nothing else. With no
`FM_FLEET_OPERATORS` it enrols only whoever ran `sudo`. Override the location with
`FM_FLEET_ROOT_DIR=/srv/agents/fleet`.

**Then each operator, as themselves, with no root:**

```bash
# group membership only applies to a NEW login — see Troubleshooting
echo 'umask 002' >> ~/.bashrc
bin/fm-fleet.sh init                                    # first operator only
bin/fm-fleet-join.sh alice web,frontend                 # everyone
```

Day to day:

```bash
bin/fm-fleet.sh queue  TASK-12 backend "fix the migration"
bin/fm-fleet.sh route  backend            # -> which operator owns this scope
bin/fm-fleet.sh claim  TASK-12 alice      # atomic; exactly one winner under a race
bin/fm-fleet.sh status
bin/fm-fleet.sh view --follow             # live event stream
```

Routing is **scope-primary, quota-secondary**: a task goes to the operator owning
that scope, unless they are stale or below `FM_FLEET_QUOTA_MIN` (default 5%), in
which case it overflows to someone with headroom.

### Heartbeats are mandatory

An operator that stops heartbeating is treated as offline after
`FM_FLEET_HEARTBEAT_TTL` (default **90s**) and routing skips them. Registration is
**not** enough — without a heartbeat every operator goes stale ~90s after joining
and routing silently returns nothing. Run it on a timer:

```ini
# ~/.config/systemd/user/fm-heartbeat.service
[Service]
Type=oneshot
ExecStart=/usr/bin/sg agents -c "umask 002; /path/to/firstmate/bin/fm-fleet.sh heartbeat alice"
```

```ini
# ~/.config/systemd/user/fm-heartbeat.timer
[Timer]
OnBootSec=30s
OnUnitActiveSec=45s
[Install]
WantedBy=timers.target
```

```bash
systemctl --user enable --now fm-heartbeat.timer
loginctl enable-linger "$USER"      # survive logout/reboot
```

The `sg agents -c` wrapper is not cosmetic — see Troubleshooting.

### Idle at zero tokens

`bin/fm-fleet-wait.sh` blocks in **bash** until work is claimed for you, heartbeating
while it waits. The agent burns no tokens idling and wakes only on real work. See
[fleet-token-economy.md](fleet-token-economy.md).

---

## Handoff documents

A finished session usually leaves a narrative — what landed, what is still open, which branch carries it.
`bin/fm-handoff-doc.sh` gives that document a home and a way to be found.

This is a third, distinct object.
`fm-fleet.sh handoff` reassigns a queued *task*; `fm-backlog-handoff.sh` moves *backlog items*; this hands off the *write-up plus the refs*.

It works **solo**, with no fleet, no group, and no root:

```bash
bin/fm-handoff-doc.sh publish HANDOFF.md --bundle my/branch   # store it, with the work attached
bin/fm-handoff-doc.sh check                                   # is anything waiting for me?
bin/fm-handoff-doc.sh show <id>                               # read it
bin/fm-handoff-doc.sh fetch <id>                              # refs -> refs/remotes/handoff/*
bin/fm-handoff-doc.sh where                                   # which store, and why
```

`check` prints one line and exits non-zero when nothing is waiting, so a session-start hook can call it unconditionally and stay silent.

**Why the store matters.**
A handoff written into your own home is unreachable to anyone else: home directories are commonly mode `0750`, so another operator on the same host cannot even traverse the path.
With Tier C opted in, the store moves to the shared fleet directory and every operator in the group can find it.
Without the opt-in it stays in your own home, which is the right default for one person.

**Reader state is yours.**
Whether you have read a document is recorded in *your* home, never in the publisher's entry.
The shared store can therefore stay strictly read-only for consumers, and no reader can alter another operator's handoff.

**Fetch is deliberately inert.**
It verifies the bundle first, then writes only `refs/remotes/handoff/*`.
It never checks out, never merges, and never moves one of your branches — what to do with the work stays your decision.

Publishing into a shared store is a disclosure, not a copy.
`publish` refuses a `.env` outright, and refuses a mode-`0600` source unless you pass `--share-anyway`.

## How the fleet directory is chosen

```
FM_FLEET_DIR  →  $FM_HOME/config/fleet-dir  →  built-in default (/opt/agents/fleet)
```

The built-in default is a **convention, not a guarantee** — on a shared host it may
already belong to someone else. Any verb that reads a fleet fails loudly if the
resolved directory is not an initialized fleet, and tells you which directory it
picked and how. Set `FM_FLEET_DIR`, or write the path into
`$FM_HOME/config/fleet-dir`, to be explicit.

---

## Troubleshooting

**`no initialized fleet at …`** — expected on a fresh clone. The message names the
directory and how it was chosen; follow the option it prints.

**`quota-axi is not on PATH`** — Tier A only. Queue, claim, route and handoff all
work without it; you lose quota-aware routing.

**A surface shows `auth_required` although the CLI is signed in** — `quota-axi auth`
prints where it looked. Some CLIs moved their credential store; that is exactly why
`bin/quota-sources/<surface>.sh` exists to supersede a stale native probe.

**`Permission denied` on the fleet dir although `id` shows the group** — `id` reads
`/etc/group`; a *running process* carries the group set from when it started. Check
the truth with `grep Groups /proc/$$/status`. A long-lived `tmux`/`screen` server
and the `systemd --user` **manager** both keep their original credentials, and a new
shell does not refresh the manager. Either reconnect properly, or wrap the command
in `sg agents -c "…"`, which re-reads group membership at exec and is immune to
process age and reboots.

**`systemctl --user` says `Failed to connect to bus`** — non-login/background
session. `export XDG_RUNTIME_DIR=/run/user/$(id -u)`.

**Operators registered but `route` returns nothing** — nobody is heartbeating; see
*Heartbeats are mandatory*.

---

## Requirements summary

| | Tier A | Tier B | Tier C |
|---|---|---|---|
| `bash`, `git`, `awk`, `flock`, `realpath` | ✓ | ✓ | ✓ |
| `jq`, `curl`, `python3` | ✓ | ✓ | ✓ |
| `quota-axi` | ✓ | optional | optional |
| root, once per host | — | — | ✓ |
| shared POSIX group | — | — | ✓ |

No daemon, no database, no network service — coordination is `flock` plus a
group-writable data directory on a shared filesystem.

Linux is the tested platform. `flock(1)` and GNU `realpath -m` must be present (the
cross-uid path guard needs `-m` to normalize a directory that does not exist yet),
and the Tier C root prereq uses `groupadd`/`usermod`. Timestamp handling itself is
portable: staleness aging accepts BSD and GNU `date`.
