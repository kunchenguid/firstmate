# Beads store topology and sync destination

This document is the reasoning behind how a beads-backed fleet shares one task store, and it ends in the decision the captain made.
[`docs/configuration.md`](configuration.md) "Backlog backend" is the owner of the resulting configuration and mechanics; this file only explains why that shape was chosen and the decision that enabled off-machine durability.

## The state this was written against

Under `config/backlog-backend=beads` the store is reached through the federation's `task` wrapper, which pins `BEADS_DIR` at `~/data/tasks/.beads` before executing `bd`.
Store resolution is therefore the CLI's job, not firstmate's, and a firstmate home with no local `.beads/` directory is not evidence of a missing store.
Every home on one machine shares that single pinned store, so local secondmate homes need no provisioning of their own.

As of 2026-08-12 the main store had no Dolt remote (`task dolt remote list` was empty) and no federation peers (`task federation list-peers` reported none).
`~/data/tasks` is itself a git repository, but it has no git remote, so `bd bootstrap`'s "clone the Dolt data that rides `refs/dolt/data` on the git origin" path has no origin to clone from.
The store runs in Dolt server mode on `127.0.0.1:3307`, which is why there is no `.beads/dolt/` directory on disk to copy.

The practical consequence is that the fleet's task store is single-machine today.
It is durable against a lost home, because every home on the machine points at the same store, and not durable against a lost machine.

## Options considered

| Option | Off-box durability | Write authority | What it costs |
| --- | --- | --- | --- |
| A. Dolt remote on a designated git remote | Yes, once a destination exists | One, the local store | Publishes task data to that destination |
| B. `bd federation` peers over Tailscale | Only while a peer is up | Several, one per peer | Split-brain risk plus SQL credentials and reachable servers |
| C. Remote homes dial the main Dolt server | No, it is the same store | One, the main store | Binding Dolt beyond loopback, and nothing works while the laptop is off |

Option A is the shape beads itself is built around: issues live in a local Dolt database, and sync rides `refs/dolt/data` on an ordinary git remote, with `.beads/issues.jsonl` remaining a passive export rather than a sync mechanism.
It keeps exactly one write authority, which matters because the backlog is the record firstmate dispatches from, and a divergent second authority would silently duplicate or lose work items.

Option B trades that single authority away.
Peers each hold a writable database, so two homes editing the same bead produce a genuine conflict that a background sweep cannot resolve on its own.
It also needs each peer to run a reachable Dolt server with credentials, which is a larger security surface than a fetch and push against a remote the captain already trusts.

Option C is not really sync at all, since the remote homes would share the laptop's store rather than hold their own copy.
It removes divergence entirely, but it requires binding Dolt past loopback and leaves every remote home with no backlog whenever the laptop is asleep, which is exactly when unattended remote work runs.

## Recommendation

Use option A, a Dolt remote on a private git remote that the captain designates, and keep the local store as the single write authority with sync as a durability and availability step.

The destination is the captain's decision: since 2026-09-06 that is mini1, reached over Tailscale at the `mini1` Dolt remote, and the local store remains the single write authority with sync as a durability step.
Adding a Dolt remote publishes the task store to that destination, and the store carries the fleet's own working notes, so firstmate does not choose where that lands.
The routine sync sweep pushes to the approved `mini1` remote through [`bin/fm-beads-remote-backup.sh`](../bin/fm-beads-remote-backup.sh) rather than driving Dolt itself, and names the single-machine posture out loud only when no remote is configured at all.
That delegation is what keeps the destination and the credential path in one place: a client-side `task dolt push` cannot reach the approved copy, both because the store has no Dolt `origin` and because the client holds no mesh credential, while the publisher pushes through the Dolt server's own environment.
The sweep has no client-side pull leg; the publisher's post-push fetch is the verification, and the local store stays the single write authority.

The captain answered the one open question, which git remote should hold the fleet's task data, by designating mini1.
A private repository the captain already owned was the expected hosted answer, and a self-hosted or LAN-only Dolt remote was the equally workable alternative where publishing to a hosted forge was unwanted.
The approved mini1 copy is kept healthy by [`bin/fm-beads-remote-backup.sh`](../bin/fm-beads-remote-backup.sh), which re-verifies and repairs the wiring (remote present, push works, permissions private) and is the publisher the routine sync sweep delegates its remote leg to; that script's header owns its exact contract and its outcome vocabulary.

## Provisioning a machine that has no store

The gap this leaves is per-machine, not per-home.
A remote account that has never run beads has no store and often no `task` wrapper, so every beads read there fails with "no beads database found" even when a store directory exists.
[`bin/fm-remote-doctor.sh`](../bin/fm-remote-doctor.sh) owns that repair as its `beads-store` check, and [`docs/remote-secondmates.md`](remote-secondmates.md) owns the operator sequence.

Provisioning always uses `bd bootstrap`, which is the non-destructive verb; `bd init --force` is never run against a store.
Firstmate additionally refuses to bootstrap whenever the store already answers a read, because bootstrap's own detection inspects the `.beads/` directory and reports a healthy Dolt server-mode store as absent, which would create a fresh empty database beside the live one.

With a destination approved, a machine provisioned this way inherits the fleet's history through that remote rather than starting an island store.
Before that decision, a newly provisioned machine held its own independent store, which is why the sync sweep names the single-machine posture out loud rather than passing silently.
