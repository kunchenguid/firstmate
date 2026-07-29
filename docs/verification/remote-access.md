# Remote access verification

Audience: maintainer verification.

This record contains reusable evidence for the client-side guarantees in [`../remote-access.md`](../remote-access.md).
That page owns the current setup, the forwarding-safety classification, and troubleshooting.
Task chronology, host service inventories, temporary directories, and delivery transcripts remain in private reports or PR evidence.

The forwarding checks below run entirely against an ephemeral loopback SSH server created for the run.
None of them changes a system SSH configuration, a user's `authorized_keys`, a firewall, or a Tailscale setting.

## Client version

Rechecked on 2026-07-29 with the OpenSSH client on Ubuntu 25.04.

```sh
ssh -V
```

```text
OpenSSH_9.9p1 Ubuntu-3ubuntu3.2, OpenSSL 3.4.1 11 Feb 2025
```

## Config entry expands as documented

The documented `~/.ssh/config` block was written to a standalone file and expanded with the OpenSSH parser.
`ssh -G` resolves the entry without connecting and without needing any private key.

```sh
ssh -F <config-file> -G shadowbyte-agent |
  grep -iE '^(host|hostname|user|forwardagent|serveralive|exitonforwardfailure|clearallforwardings|controlmaster|controlpath|port) '
```

Observed output, with the real host and account rendered as the same placeholders [`../remote-access.md`](../remote-access.md) uses:

```text
host shadowbyte-agent
user <server-user>
hostname <server-host>.<tailnet>.ts.net
port 22
exitonforwardfailure yes
clearallforwardings yes
controlmaster false
serveralivecountmax 3
serveraliveinterval 30
forwardagent no
```

The check ran with concrete values in those two fields; only their spelling is substituted here, and every other line is as observed.
Every documented directive survives expansion, and the alias resolves to the intended host and user.
OpenSSH's `ssh -G` omits `controlpath` when `ControlPath none` resolves to no control socket.
The reader-facing page uses this alias for attach only because `ClearAllForwardings yes` also clears command-line forwards.
Its Lavish tunnel uses a dedicated `-F` file so the explicit local forward cannot inherit unrelated user or system forwarding entries.

## Forwarding harness

The forwarding checks use a throwaway server bound to loopback with its own host key, its own authorized key, and its own configuration file.

```sh
ssh-keygen -q -t ed25519 -N '' -f "$D/hostkey"
ssh-keygen -q -t ed25519 -N '' -f "$D/clientkey"
cp "$D/clientkey.pub" "$D/authorized_keys"
/usr/sbin/sshd -f "$D/sshd_config" -E "$D/sshd.log"
```

`$D/sshd_config` sets `Port 2222`, `ListenAddress 127.0.0.1`, `HostKey $D/hostkey`, `AuthorizedKeysFile $D/authorized_keys`, `PasswordAuthentication no`, `UsePAM no`, and `AllowTcpForwarding yes`.
The generated keys exist only for the run and are deleted with the directory afterward.

## A local forward reaches a loopback-only service

The forward targeted a service bound to `127.0.0.1:4387` on the server side, which is the shape [`../remote-access.md`](../remote-access.md) documents.

```sh
ssh -F "$D/test_ssh_config" -N -L 14387:127.0.0.1:4387 fm-forward-test &
curl -sS -o /dev/null -w 'http_code=%{http_code} size=%{size_download}\n' \
  --max-time 8 http://127.0.0.1:14387/session/<session-id>
```

Observed output:

```text
http_code=200 size=9810
```

The same request sent directly to the server's non-loopback address before the forward existed failed to connect, confirming the service is loopback-only and the forward is what makes it reachable.
These checks ran with the local bind address left implicit, which OpenSSH resolves to loopback under the default `GatewayPorts no`; the reader-facing page writes that bind address out as `127.0.0.1:LOCAL_PORT` so the result does not depend on a client setting this harness controlled and a Mac may not.

## `ExitOnForwardFailure yes` reports a busy local port and exits

A dual-stack listener occupied local port 14388 before SSH was started, reproducing the case where something on the Mac already holds the intended port.

```sh
ssh -F "$D/test_ssh_config" -N -L 14388:127.0.0.1:4387 fm-forward-test
echo "exit=$?"
```

Observed output:

```text
bind [127.0.0.1]:14388: Address already in use
channel_setup_fwd_listener_tcpip: cannot listen to port: 14388
Could not request local forwarding.
exit=255
```

The troubleshooting section reproduces these three message lines with the port substituted for the one it documents, and the immediate non-zero exit is what makes the failure visible.

## Without the directive, the same conflict is silent

The identical conflict was rerun with the directive overridden.

```sh
timeout 6 ssh -F "$D/test_ssh_config" -o ExitOnForwardFailure=no \
  -N -L 14388:127.0.0.1:4387 fm-forward-test
echo "exit=$?"
```

Observed output:

```text
Terminated
exit=124
```

SSH printed no diagnostic and stayed connected until the external timeout killed it, leaving a live session with a dead tunnel.
This is the failure mode the directive prevents, and it is why the setting is part of the documented config rather than an optional extra.

## No listener survives the checks

After each forward ended and the harness was stopped, the ports were rechecked.

```sh
ss -ltn | grep -E ':(1438[78]|2222)' || echo 'no listeners'
```

```text
no listeners
```

The forwarded ports and the throwaway server all released cleanly, so a failed or cancelled tunnel leaves nothing behind to conflict with the next attempt.
