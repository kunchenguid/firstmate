# parked-homes

When you park a secondmate home, nothing may reach it: no message,
steer, answer, nudge or relaunch, and no config push. Before this add-on the
only record of a park was a line in a home data file, which no supervision
producer reads — so a parked home still got config-reread nudges, a pending
reply retry ladder, and quota-failover relaunches onto a new model.

Every supervision producer now gates on **one shared reader**,
`fm_parked_home <id>`, instead of carrying its own copy of the rule.

## The parked-homes file

`<fm-home>/config/parked-homes` — one home id per line; `#` comments and blank
lines are ignored:

```
# Parked homes: no work, nothing merges.
v1design
relayiptv
```

A missing file parks nothing; an unparked home behaves exactly as before.

## Home-id resolution

A task meta belongs to a parked home only when its `kind=secondmate`. A local
secondmate's `home=` path carries `.fm-secondmate-home` with the id; a remote
secondmate's home lives on its host, so the recorded task id stands in.
Crewmate and lead lanes are never parked, whatever their task id spells.

## The gated paths

| Producer | Gate | Skip behavior |
|---|---|---|
| Supervision session (message, steer, answer, nudge — `fm-send.sh`) | after target resolution | one `error:` line, exit 1, nothing delivered or marked |
| Relaunch (`fm-control.sh <id> relaunch`, `fm-remote-secondmate-relaunch.sh`) | before the launch transaction | one `error:` line, exit 1 |
| Restart pass (`fm-secondmate-restart.sh`, used by /updatefirstmate) | argv filter | one `parked: <id>:` line; no persist request, no restart, no nudge |
| Reconcile nudge (`fm-secondmate-reconcile.sh`) | per-target | `skipped: <id> parked`; request preserved |
| Config push (`fm-config-push.sh`) | per-home | `secondmate <id>: skipped - its home is parked` |
| Inherited config push (CONFIG_REREAD, both bootstrap loops) | per-home | one skip line; no push, no reread nudge |
| Pending-reply retries and missed-report escalation (`fm_pending_reply_tick`) | per-record | record kept as-is; no recovery resend, no escalation |
| Model-outage alert (`fm_model_outage_tick`) | per-lane | lane never scanned, never alerts |
| Wake-loop check (`secondmate_wake_stall_tick`) | per-mate | no drain ring, no stalled check; episode markers dropped |
| quota-failover (this repo) | per-task | `note`d once; the stopped parked worker is never moved |

One log line per skip is all a parked home ever produces.

## Layout

- `bin/fm-parked-homes-lib.sh` — the shared reader (source-only, no deps).
- `install.sh` — verifies the wiring: this checkout reachable from the home,
  the fork shim present, the parked file readable. It changes nothing.
- `tests/parked-homes-e2e.sh` — the integration test: a fixture fleet of two
  homes, one parked, driven through every gated path above against a real
  firstmate checkout carrying the fork hooks.

## Wiring (fork hook)

The live producers live in the firstmate fork, so the gates are one source
line plus one predicate call per producer (fork PR carries the full list; see
`FORK-EXIT.md`). The fork's `bin/fm-parked-homes-lib.sh` is a thin shim: it
sources this directory's reader from `FM_ADDONS_DIR` (default
`$FM_HOME/projects/firstmate-addons`). When the add-on checkout is absent the
shim defines no-op predicates — every gate is a no-op and behavior is exactly
as before, so the fork hook is safe to merge before any home installs the
add-on checkout.

`pipeline-quota-failover` is out of scope: it fails over models inside
no-mistakes pipeline calls and never touches a secondmate home. The ff-sweep's
fast-forward of a parked home's checkout is also untouched (a park stops
contact, not the fleet's code convergence); its nudge is gated at
fm-send/bootstrap.
