# Live fleet dashboard

The dashboard is a long-running, read-only HTTP board the captain opens from a phone or laptop over Tailscale.
It reads firstmate's existing `state/` and `data/` surfaces and never acquires the firstmate session lock.
Firstmate session start or stop does not start or stop the dashboard.

Wave 1 ships the server lifecycle, the snapshot API, and the phone-first UI shell.
Later waves attach side sources (quota, PRs, trains, production) and write-back.
See the design scout report for the full plan; this page owns current operator setup.

## Requirements

- A Rust toolchain with `cargo` on `PATH` (edition 2021).
  The first `start` or `run` builds the release binary when it is absent.
- No Python (or other scripting language) is required for the server or lifecycle script.

## Run

```sh
export FM_HOME=/path/to/your/firstmate-home   # required when not using the repo as home
bin/fm-dashboard.sh start     # daemonize under a portable supervisor loop
bin/fm-dashboard.sh status
bin/fm-dashboard.sh stop
bin/fm-dashboard.sh run       # foreground (debug; no restart loop)
```

`FM_HOME` must be firstmate-shaped: `state/` and `data/` directories plus at least one marker among `data/backlog.md`, `data/projects.md`, `AGENTS.md`, or `.fm-secondmate-home`.
The command refuses to start when the home is missing or not shaped that way.

Default URL shape after start: `http://<bind-ip>:<port>/` (default port `8391`).

### Server binary

The HTTP server is a small Rust crate at `dashboard/` in the tracked repo.
`bin/fm-dashboard.sh` invokes:

```sh
cargo build --release
```

in that crate when `dashboard/target/release/fm-dashboard-server` is missing.
Dependencies are intentionally minimal: `tiny_http` (sync HTTP) and `serde_json` (snapshot JSON).
There is no async runtime and no heavyweight web framework.
Rebuild after source changes by removing the binary or running `cargo build --release` in `dashboard/` yourself.

## Bind selection

The server binds only to a concrete address.

1. If `config/dashboard-bind` exists under `FM_HOME`, its first line is used as `IP` or `IP:PORT`.
2. Otherwise the script runs `tailscale ip -4` and binds that address on port `8391`.

`0.0.0.0`, `::`, and other wildcards are refused at lifecycle resolve time and again inside the Rust server.
That includes the IPv4-mapped spellings (`[::ffff:0.0.0.0]`, `[0:0:0:0:0:ffff:0:0]`), which are an INADDR_ANY bind on a dual-stack host.
For local tests, write `127.0.0.1:8391` (or another free port) into `config/dashboard-bind`.

## Auth

On first start the lifecycle script creates `config/dashboard-token` (mode `0600`) with a random 32-byte hex secret when the file is absent.

Protected routes require either:

- `Authorization: Bearer <token>`, or
- cookie `fm_dash=<token>` (set by the unlock form; `HttpOnly; SameSite=Strict; Max-Age=180d`).

Unauthenticated browser visits to `/` receive the unlock page (HTTP 401 with HTML).
API callers without credentials receive JSON `401`.

`GET /healthz` stays open on the bound interface and returns only process liveness:

```json
{"ok":true,"pid":4123,"uptime_s":12}
```

It never includes fleet data.
`pid` identifies the answering process so `start` can prove that the server it just launched is the one on the bind address, rather than another home's server already holding the port.
HTTP on the tailnet is acceptable for v1; do not expose this service on the public internet or Tailscale Funnel without TLS and stronger auth.

## Snapshot API

`GET /api/v1/snapshot` (auth required) returns JSON with schema `fm-dashboard-snapshot.v1`.

- Primary fleet payload comes from `bin/fm-fleet-snapshot.sh --json` when present and executable.
- Every child process is bounded (60s for the snapshot tool, 20s for `tasks-axi`). On expiry the child's whole process group is killed and its `sources[]` entry is marked `"timed_out": true` with an `error`, so a wedged probe degrades the board instead of hanging it.
- Soft cache is about four seconds so phone multi-fetch stays cheap.
- Each response includes `generated`, nested `fleet` (the snapshot contract), `decisions` (stable keys for captain holds), `sources[]` metadata, and honest null/empty placeholders for wave-2 surfaces.
- The server is strictly read-only over `state/` and `data/`.
  Runtime writes are limited to `state/dashboard/` (and creating `config/dashboard-token` / reading bind config).

## UI shell

One static HTML/JS page is served from `bin/fm-dashboard-static/` with no SPA framework and no CDN.
Themes follow `prefers-color-scheme`: chart-room dark (deck `#131A17`, brass `#C9A24B`, teal `#5FB0A5`) and light linen.
Section order matches the captain-approved mock: mast + freshness, since-you-looked, your call, ready for you, fleet now, trains, meters, production.
Sections whose data arrives in later waves render labeled empty states (`wired in wave 2`) rather than invented numbers.
The client polls every five seconds; a failed poll turns the freshness beat red.

### Stable keys (wave 3 annotation anchors)

Wave 3 adds lavish-style two-way feedback (tick-to-done, dismiss/snooze, free-text annotation) on **any** card or section.
Wave 1 therefore stamps a stable `data-key` (and `data-key-kind`) on every section and every card/row in the DOM, and mirrors keys in the snapshot JSON:

| Kind | Key shape | Example |
| --- | --- | --- |
| section | `section:<slug>` | `section:your-call` |
| decision | `decision:<hold-id>` | `decision:demo-decision` |
| task | `task:<id>` | `task:ship-a` |
| event / pr / train / meter | `<kind>:<id>` | `pr:466` |
| empty placeholder | `empty:<section-slug>` | `empty:trains` |

Decision cards also keep `data-decision-key` / `hold_id` as the raw backlog id for write-back routing.
No write path ships in wave 1; the keys only prepare the board for wave 3.

## Lifecycle (no systemd required)

This host class may not have systemd.
`bin/fm-dashboard.sh start` therefore daemonizes a portable supervisor loop:

1. Validate home and resolve bind + token.
2. Background a loop that runs the Rust binary `dashboard/target/release/fm-dashboard-server`.
3. If the server process exits without a stop request, the loop waits one second and starts it again (well under the ten-second restart budget).
4. PID and log files live under `state/dashboard/` (`supervisor.pid`, `server.pid`, `server.log`, `supervisor.log`).
5. `stop` writes a stop flag, signals the server, then stops the supervisor.

Killing only the server process with `SIGKILL` should produce a new server within about one second while the supervisor stays up.

A server that cannot run at all (port already owned by another home, bad config) is not retried forever: consecutive exits inside five seconds back off from one second up to thirty, and after ten of them the supervisor logs the reason and stops instead of respawning once a second and growing `server.log` without bound.

`start` reports success only once the server process it launched answers `/healthz` with its own pid.
If that never happens it tears the supervisor down, prints the tail of `server.log`, and exits non-zero.
`stop` and `status` never build anything, so they still work on a host with no Rust toolchain or a cleaned `target/`.

The dashboard never takes the firstmate session lock.

### Optional systemd unit (other hosts only)

On machines that use systemd user units, an example is:

```ini
# ~/.config/systemd/user/fm-dashboard.service
[Unit]
Description=Firstmate live fleet dashboard
After=network-online.target

[Service]
Type=simple
Environment=FM_HOME=%h/development/firstmate
WorkingDirectory=%h/development/firstmate
ExecStart=%h/development/firstmate/bin/fm-dashboard.sh run
Restart=on-failure
RestartSec=1

[Install]
WantedBy=default.target
```

That unit is optional documentation for other hosts.
The supported default path in this repo is `bin/fm-dashboard.sh start` with the portable supervisor.

## Scripts

| Path | Role |
| --- | --- |
| `bin/fm-dashboard.sh` | Lifecycle: start / stop / status / run; `start` and `run` cargo-build the server when absent |
| `dashboard/` | Rust crate producing `fm-dashboard-server` |
| `bin/fm-dashboard-static/` | Phone-first UI assets |
| `bin/fm-fleet-snapshot.sh` | Canonical fleet read model used by the snapshot API |

## Tests

```sh
bin/fm-test-run.sh tests/fm-dashboard.test.sh
```

Coverage includes lifecycle, FM_HOME refusal, bind safety (including IPv4-mapped wildcards), auth, healthz, malformed unlock bodies, toolchain-free stop/status, and snapshot shape with stable keys.
That script also runs `cargo test --release` in `dashboard/`, which covers the bounded-child paths (deadline kill, process-group reap, pipe drain) that a shell test cannot reach at a sixty-second timeout.
