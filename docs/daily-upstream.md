# Guarded daily upstream maintenance

`bin/fm-daily-upstream.sh` is the public owner for deterministic daily upstream assessment, pinned safe fast-forwards, public Kun Chen channel metadata, morning reports, and the per-user LaunchAgent definitions.
The script's `--help` output owns exact commands, flags, private formats, and mutation mechanics.
This capability is not deployed merely because its tracked files are present.
Writing or removing the per-user LaunchAgent definitions remains a separate captain-authorized operation on the target Mac.

## Schedule and local time

The two generated definitions use launchd `StartCalendarInterval` triggers at 04:00 and 08:00 in the Mac's local timezone.
Installation and scheduled execution refuse unless the local timezone resolves exactly to `America/Sao_Paulo`.
The definitions do not use `RunAtLoad`, so a login or script installation does not create an unscheduled update.
Launchd coalesces a calendar event missed while the Mac sleeps and runs it after wake rather than requiring a resident process.
If the delayed 04:00 and 08:00 phases overlap after wake, the report phase waits for the bounded collection lock before reading only a completely published receipt.
The scheduled report extends that wait to a bounded ceiling only while a live collection still owns the lock, and it records an explicit `report=deferred` outcome instead of ending without an explanation when the lock never frees.
A powered-off Mac may miss a calendar event, and the next report explicitly avoids claiming a collection that does not exist.
A report rendered from an earlier receipt names that receipt's own local date and mode, so a stale or report-only assessment is never presented as that morning's collection.
Daily collection is date-idempotent, so duplicate launch delivery cannot apply a second update.

## Collection policy

The 04:00 phase fetches and assesses one exact candidate SHA before any application.
It records changed surfaces, commit-to-merged-PR provenance, completed checks, dependency or migration indicators, instruction and runtime changes, security-sensitive paths, deployment or restart implications, local divergence, and forward-fix-only rollback feasibility.
Unknown, missing, red, ambiguous, or contradictory provenance and check evidence leaves the repository untouched.
A later origin movement causes the authoritative updater to refuse rather than silently broaden the reviewed range.
Risk remains visible even when all mechanical application conditions pass.

Firstmate self-update accepts only the official `kunchenguid/firstmate` origin and extends `bin/fm-update.sh` through its public `--expected-sha` contract.
The same exact candidate is offered to validated registered second-mate homes through that owner.
Dirty, diverged, off-default, unavailable, or unofficial homes remain untouched and are reported.

A registered project is eligible only when its bracketed registry posture explicitly includes `+daily-sync`.
Adding `+daily-sync` is a per-project captain decision owned by the project-management procedure rather than a consequence of installing this schedule.
A `+production` posture makes the copy report-only and overrides `+daily-sync`.
Local-only, production-bearing, absent, unregistered, ambiguously registered, dirty, diverged, off-default, missing-check, and red-check copies remain untouched.
Eligible copies apply through `bin/fm-fleet-sync.sh --expected-target`, with branch pruning disabled for the scheduled call so only the assessed default-branch fast-forward is in scope.
The collector enumerates only registry entries and immediate directories under this home's `projects/` root, and it never scans arbitrary repositories elsewhere in the home directory.

macOS, Homebrew, global-package, application, browser-extension, dependency, credential, backup, and production-service opportunities are report-only.
The scheduled owner never installs a package, updates an application or extension, changes a dependency or credential, alters backup state, deploys, restarts, reloads, changes a firewall, or merges a PR.

## Public channel metadata

The collector reads only public upload metadata for `https://www.youtube.com/@kunchenguid` over bounded HTTPS requests.
It never starts a browser, reads a profile or cookie, authenticates, or downloads media.
A validated last-seen public video identity makes normal uploads appear in one collection receipt.
An initialization records the newest identity without replaying history, while a feed history gap preserves the prior identity instead of guessing.
A history gap surfaces no upload metadata at all, because a gap cannot prove which bounded entries are genuinely new.
Each report says so explicitly, because the preserved identity keeps the monitor gapped until the captain resolves the last-seen identity.
A surfaced upload remains evidence for Firstmate to decide whether later analysis is relevant.
Any later acquisition or analysis remains owned by the accepted `/watch` capability and its 4 GiB default, explicitly authorized 16 GiB ceiling, adaptive full-versus-section choice, and exact cleanup contract.

## Private evidence and delivery

Receipts and reports live only under `data/daily-upstream/`, while locks, report offers, and the authenticated custom check live under `state/daily-upstream/` and the existing state-check surface.
The owner uses restrictive permissions, same-directory atomic publication, regular-file and single-link checks, path containment, bounded external commands, and one home-local run lock.
It emits only controlled status values and suppresses credential, authentication, private URL, host, network, device, account, environment, process-command-line, and unrelated repository content.
A report is indexed before its authenticated check is registered, so an absent live Firstmate session leaves the report available for the next session rather than launching another primary or losing the result.
Pending reports form a durable oldest-first queue, and the report-handling skill acknowledges only the exact report it synthesized.
An unacknowledged report is re-offered to the watcher on a bounded half-hour cadence rather than on every sweep, while a new report identity is offered immediately.
A session that starts after the report was written is therefore still woken on the same morning.
A best-effort macOS Notification Center message never controls report durability.
An absent or failed notifier leaves the private report and authenticated check in place.

Retention is explicit rather than automatic.
`cleanup --keep-days` reads the bounded owner index, validates every exact path, preserves pending or uncertain evidence, and never uses a destructive glob.
A dead run lock is never silently deleted, while `recover-lock --older-than-seconds` can preserve and move aside one exact lock after a minimum one-hour age and a dead-owner check.

## Deployment

Inspect prerequisites without changing state:

```sh
bin/fm-daily-upstream.sh detect
```

Collect a full report-only assessment without repository fast-forwards:

```sh
bin/fm-daily-upstream.sh assess
```

After this feature has landed and the captain separately authorizes deployment on the target Mac, write both definitions without `sudo`:

```sh
bin/fm-daily-upstream.sh install
bin/fm-daily-upstream.sh verify-install
```

The install command writes byte-exact definitions but deliberately does not call `launchctl`, so it cannot reload unrelated user jobs during setup.
The definitions become eligible through the normal per-user LaunchAgent lifecycle, such as the next login or a separate explicitly approved load operation.
Verification checks file type, ownership, link count, mode, exact bytes, schedule, and plist syntax without loading or executing either job.

Exact rollback removes only matching owned definitions and refuses any modified or unsafe existing file before deleting either one:

```sh
bin/fm-daily-upstream.sh uninstall
```

Uninstall deliberately does not unload a live job, so any separately approved live load must be separately unloaded before exact definition removal when immediate deactivation is required.
This preserves unrelated launchd state and keeps loading, unloading, installation, and removal visible as distinct operator actions.

Maintainer evidence and deterministic test entry points are recorded in [`verification/daily-upstream.md`](verification/daily-upstream.md).
