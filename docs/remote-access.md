# Remote Mac control path

Firstmate runs on the server that owns the projects, the worktrees, and the primary session.
A Mac is a control and viewing surface only, reached over one authenticated SSH connection per purpose.
This page owns the Mac-side setup for attaching to a server-resident Firstmate and for viewing a server loopback web tool such as Lavish.
[`configuration.md`](configuration.md) owns the operational-home layout and the configuration files themselves.

## Boundaries

- Every command, file, git worktree, and agent process stays on the server.
- The Mac contributes a terminal and a browser and holds no project state.
- Pi is the only Firstmate primary.
- The authoritative Firstmate runs in the named Herdr session `firstmate`.
- Claude Code, Codex, and every other harness are supervised crewmates only and must not start a competing primary.
- The launcher described under Terminal 1 is expected to attach to that agent's existing named session rather than start a second one.
- That launcher is the operator's own script living outside this repository, so the attach behavior is a property of that launcher pattern rather than a guarantee this repository keeps.
- With such a launcher in place, attaching repeatedly from the Mac joins the one primary, and it does not change which harness the primary runs.
- Nothing here publishes a service to the public internet, and nothing here changes a firewall, a service bind address, an SSH server configuration, or a service's own authentication.
- Browser-facing tools stay bound to server loopback and are reached only through an explicit SSH local forward that exists for as long as you keep its terminal open.

This public guide intentionally redacts private Tailscale hostnames, IP addresses, SSH usernames, launcher paths, and live Lavish URLs.
The exact values belong in private operator documentation, and a current Lavish URL is ephemeral and must come from active session output.
Private operator configuration was verified separately while this guide preserves the safe structure and commands.

## Mac `~/.ssh/config`

Add one block to `~/.ssh/config` on the Mac.
Angle-bracket values are placeholders for your own infrastructure; the table below names each one and where to read its real value.

```text
Host shadowbyte-agent
    HostName <server-host>.<tailnet>.ts.net
    User <server-user>
    ForwardAgent no
    ServerAliveInterval 30
    ServerAliveCountMax 3
    ExitOnForwardFailure yes
```

| Placeholder | What it is | Where to read the real value |
| --- | --- | --- |
| `<server-host>.<tailnet>.ts.net` | The server's Tailscale MagicDNS name. | `tailscale status` on either device, or the machine's row in the tailnet admin console. |
| `<server-user>` | The Linux account on the server that owns the Firstmate operational home. | `whoami` in a shell on the server. |
| `<launcher-dir>` | The directory on the server holding the operator's own Firstmate launcher script used in Terminal 1. | Wherever you keep that script; it is not part of this repository. |
| `<session-id>` | The id inside a Lavish session URL. | The `lavish-axi` session listing on the server. |

`shadowbyte-agent` is not a placeholder; it is a local alias that exists only in the Mac's own `~/.ssh/config`, so any name works as long as the commands below use the same one.

| Directive | Why it is here |
| --- | --- |
| `HostName` | The MagicDNS name resolves from any device on the tailnet without a public DNS record or a static route. |
| `User` | The Linux account that owns the Firstmate home on the server. |
| `ForwardAgent no` | The Mac's SSH agent stays off the server, so a shared or compromised server session cannot borrow the Mac's keys to reach other hosts. |
| `ServerAliveInterval 30` and `ServerAliveCountMax 3` | An idle attach or tunnel that a NAT or a sleeping laptop has already dropped is ended within about 90 seconds instead of hanging silently. |
| `ExitOnForwardFailure yes` | A forward that cannot bind its local port ends the connection with a visible error instead of leaving SSH connected with a dead tunnel. |

No step in this path needs agent forwarding, which is why `ForwardAgent no` costs nothing and removes a real risk.
Check the entry on the Mac without connecting:

```sh
ssh -G shadowbyte-agent
```

That prints the fully expanded settings, so a typo in the host alias or a directive is visible before any connection attempt.

## Which SSH server answers

When Tailscale SSH is enabled on the server, `tailscaled` answers port 22 on the tailnet addresses, so a connection to the MagicDNS name reaches Tailscale SSH rather than the host's own OpenSSH server.
Confirm which one is active by reading `RunSSH` in `tailscale debug prefs` on the server, or by checking that machine's Tailscale SSH setting in the tailnet admin console.

| | Tailscale SSH | Host OpenSSH |
| --- | --- | --- |
| Authentication | Reachable tailnet TCP port 22 plus tailnet identity and an effective SSH rule matching source, destination, and user; a `check` action adds a periodic browser approval | A public key installed in the remote user's `~/.ssh/authorized_keys` |
| Local port forwarding | The effective matched SSH action must allow local (`-L`) forwarding with `allowLocalPortForwarding`; authentication alone is insufficient | Permitted only if the server's forwarding policy, such as `AllowTcpForwarding`, allows it |
| Key needed on the Mac | None | Yes |

Both are reached by the same `~/.ssh/config` entry and the same commands below; only the authentication step differs.
For Tailscale SSH, check network reachability to the server's tailnet TCP port 22, SSH authorization by the effective matching rule, and local-forward permission in that rule's action as separate gates.
`tailscale ping` can confirm the tailnet node path, but it does not prove that TCP port 22 is reachable, that the SSH rule authorizes this user, or that the action permits `-L` forwarding.
An authenticated session can therefore still reject a local forward when `allowLocalPortForwarding` is not enabled by the effective action.
Current Tailscale releases support local (`-L`) forwarding when that action permits it; remote (`-R`) forwarding is not part of this path.
These Tailscale statements come from Tailscale's own policy-syntax and SSH action references rather than from this page's verification record, which exercises an OpenSSH server only.
Before relying on the OpenSSH path as a fallback, verify that a usable public key is actually installed for the remote user, because installing one is a separate operator decision rather than part of this setup.

## Terminal 1: attach to Firstmate

```sh
ssh -t shadowbyte-agent /home/<server-user>/<launcher-dir>/launch-firstmate.sh
```

That launcher is the operator's own script on the server and is not tracked in this repository, so the path above is a placeholder for wherever yours lives.
`-t` forces a terminal, which the launcher needs in order to attach you to the existing session rather than run headless.
For the single-primary property under Boundaries to hold, the launcher must attach to the primary's existing named session whenever that agent is already running, rather than start a fresh one.
A launcher that starts a second Firstmate against the same operational home instead of attaching cannot acquire the per-home session lock, so that session stays read-only.
Leave this window open for as long as you want to watch or talk to Firstmate.
Closing it detaches the view; the session and every worker keep running on the server.

## Terminal 2: view a loopback web tool

Lavish serves review artifacts on server loopback `127.0.0.1:4387` and is not reachable from the Mac by any other route.
Open a second Mac terminal and start the forward:

```sh
ssh -N -L 127.0.0.1:4387:127.0.0.1:4387 shadowbyte-agent
```

`-N` runs no remote command, so this connection only carries the forward.
The leading `127.0.0.1` pins the Mac-side listener to loopback explicitly, because a bare `-L 4387:...` follows whatever `GatewayPorts` the Mac's ssh config resolves to and would publish the forwarded tool to the local network if any `Host *` block or included file enabled it.
It prints nothing while healthy.
Leave it running for as long as you are reading artifacts, and end it with Ctrl-C.

Then ask the server for the current session URL.
Run `lavish-axi` with no arguments in the Firstmate terminal; it lists every open session with its URL:

```text
sessions[2]{file,status,url,pending_prompts}:
  /path/to/artifact.html,open,"http://127.0.0.1:4387/session/<session-id>",0
```

Open that exact URL in the Mac browser:

```text
http://127.0.0.1:4387/session/<session-id>
```

Three details make the URL work unchanged on the Mac:

- Keep the local port equal to the remote port, so the address the server prints is the address the Mac browser needs.
- Use `127.0.0.1` throughout rather than mixing in `localhost`, so the address matches what the tool prints.
- Use a full session URL, because `http://127.0.0.1:4387/` has no index page and answers 404 while only `/session/<session-id>` renders an artifact.

Firstmate adds no wrapper for this lookup.
The tool's own CLI already prints the current session URLs, and a wrapper would only duplicate it and drift from it.

## Any other loopback service

The same shape reaches any future server-resident web tool:

```sh
ssh -N -L 127.0.0.1:LOCAL_PORT:127.0.0.1:REMOTE_PORT shadowbyte-agent
```

`REMOTE_PORT` is the port the service listens on inside the server, and `LOCAL_PORT` is the port the Mac browser visits.
Keep them equal whenever the tool prints absolute URLs containing its own port.
Keep the explicit local `127.0.0.1` in every forward you add, for the same reason it is in the Lavish command above.

## What to forward, and what not to

A local forward relocates a trust boundary.
It takes a service that only processes on the server could reach and makes it reachable by anything that can open the Mac's loopback port, and it adds no authentication of its own.
Forward a service only after deciding that is acceptable for that specific service.

| Service class | Forward it? | Reason |
| --- | --- | --- |
| Firstmate's review surface on loopback `4387` | Yes | It exists to be read by the operator, it serves the artifacts you asked for, and it has no other Mac-reachable path. |
| A service verified reachable at a Tailscale address or through Tailscale Serve | No forward needed | It already has a verified tailnet path; a second path through a tunnel only creates two ways to reach one service and two ways to get confused about which is live. |
| A service bound to an arbitrary non-loopback address without verified Tailscale or Serve reachability | Review separately | A non-loopback bind alone does not prove a tailnet route, ACL allowance, firewall access, or the intended service identity. |
| Local model or inference servers on loopback | Not without a separate review | They are bound to loopback precisely because they expose an unauthenticated API to anything that can reach the port. |
| Editor, IDE, and agent control ports | No | They carry code execution authority for the server account, and their ports are ephemeral and change on every restart. |
| System daemons such as the DNS resolver stub or the print spooler | No | No operator value and no reason to widen their reach. |

Anything outside this table is a separate decision, not a default.
Adding one to the routine setup means reviewing that service's own authentication first.

## Troubleshooting

### The name does not resolve

`ssh: Could not resolve hostname` means the tailnet name is not resolvable from the Mac.
Confirm the Mac is connected and the server is online with `tailscale status` on the Mac, and confirm MagicDNS is enabled for the tailnet.
`tailscale ping <server-host>` checks the tailnet node path independently of SSH, but it does not check TCP port 22.
Check that the server's tailnet address accepts TCP port 22 before debugging SSH policy, because a reachable node and an unreachable SSH port fail at different layers.
As a temporary check only, substituting the server's Tailscale IPv4 address for `HostName` isolates a DNS problem from a connectivity problem.

### Authentication fails or keeps re-prompting

Under Tailscale SSH, a policy rule in `check` mode prints an approval URL and grants access for a bounded window.
Being asked to re-approve in a browser after that window expires is the configured behavior, not a fault.
Each terminal authenticates on its own, so an expired approval can stop a new tunnel from starting while an already-established attach keeps running.
A permission-denied refusal under Tailscale SSH means no policy rule matched this device and user, which is a tailnet policy question rather than something to fix on the Mac.
Under the host's OpenSSH server, the same refusal means the Mac's public key is not installed for the remote user.
If TCP 22 is reachable and authentication succeeds but the forward itself fails under Tailscale SSH, inspect the effective action for `allowLocalPortForwarding` before treating it as a `tailscaled` behavior or version question.
For host OpenSSH, inspect the server's `AllowTcpForwarding` policy separately from public-key authentication.

### The local port is already in use

With `ExitOnForwardFailure yes` in place, SSH reports the conflict and exits immediately:

```text
bind [127.0.0.1]:4387: Address already in use
channel_setup_fwd_listener_tcpip: cannot listen to port: 4387
Could not request local forwarding.
```

Find the local process holding it with `lsof -nP -iTCP:4387 -sTCP:LISTEN` on the Mac.
Either stop that process, or pick a free local port and visit that port in the browser instead:

```sh
ssh -N -L 127.0.0.1:14387:127.0.0.1:4387 shadowbyte-agent
```

Then the artifact is at `http://127.0.0.1:14387/session/<session-id>`, with the session id unchanged.

### The tunnel stops working

An `-N` tunnel prints nothing while healthy, so silence is normal and a returned shell prompt means it ended.
After a laptop sleep or a network change, the keepalive settings end the dead connection within about 90 seconds; rerun the same command to reconnect.
If the browser fails while the tunnel terminal is still running, confirm the service is still up on the server before suspecting the tunnel.

### The artifact URL is stale

Each artifact has its own session URL, so a URL kept from an earlier artifact will not show the current one.
Re-read the list on the server with `lavish-axi` and use the URL for the artifact you actually want.
A 404 on a session URL means that session id is not open, which is a stale URL rather than a tunnel failure.

## Verification

[`verification/remote-access.md`](verification/remote-access.md) records the reusable evidence for the configuration snippet, the forward, and the forward-failure behavior documented here.
