# Local dashboard

`bin/fm-dashboard.sh start` starts a read-only dashboard for the effective `FM_HOME` and opens it in the default browser.
The service binds to `127.0.0.1` by default and uses port `8765`, or an available port when `--port 0` is supplied.
The command does not install a system service or change global user configuration.

The default refresh includes the local Bearings projection and read-only GitHub pull-request and CI checks through `gh`.
Use `bin/fm-dashboard.sh start --no-prs` when GitHub access is unavailable or a local-only view is preferred.
The public page shows active work, current phase, last-update age, possible-wedge or stale indicators, open captain decisions, pull-request and CI state, recently landed work, and supervision health.

Supervision is explicit in the page.
`healthy` means the watcher lock, recorded watcher identity, and heartbeat all pass the existing supervision predicate.
`stale-watcher` means a watcher lock remains but the predicate is no longer healthy.
`no-watcher-active` means work needs supervision but no validated watcher is active.
`not_needed` means there is no in-flight task, registered process-event source, or X-mode relay requiring a watcher.
The page also shows the heartbeat age and does not treat an old snapshot as healthy.

The service owns only `state/.dashboard/`.
It atomically writes `snapshot.json`, appends dashboard events to `events.jsonl`, and records status-log cursors in `status-cursors.json`.
It observes append-only `state/<id>.status` files and the existing read-only snapshot readers.
It never consumes or drains `state/.wake-queue`.
The event stream uses reconnecting Server-Sent Events with durable numeric cursors, so a browser reconnect or service restart can replay events after the last received id.

The first slice is intentionally observational.
The page has no fleet-control operations, authenticated remote listener, or secret-bearing payloads.
Stop the service by ending the process recorded in `state/.dashboard/service.pid` when needed.

## Optional user-session startup

Automatic startup is an operator choice and is not installed by `fm-dashboard.sh`.
For a systemd user session, create the unit manually with an absolute path to the checkout:

```ini
[Unit]
Description=Firstmate local dashboard

[Service]
ExecStart=/absolute/path/to/firstmate/bin/fm-dashboard.sh serve --no-prs
Restart=on-failure

[Install]
WantedBy=default.target
```

Then enable it explicitly with `systemctl --user enable --now firstmate-dashboard.service`.
Keep the unit in the operator's user configuration and remove it with `systemctl --user disable --now firstmate-dashboard.service` when it is no longer wanted.
