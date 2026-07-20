# firstmate lndev captain broker

This is the firstmate-local `lndev` attach-as-captain broker.
It is outside-only: it shells out to the installed `lndev` binary, parses its current human CLI output, and never reads or changes Lindy source.

The broker listens on one host-local Unix socket under `$FM_HOME/state/lndev-captain.sock`.
Crew lanes call `bin/fm-lndev-captain`, which sends a task id, requested operation, normalized args, and an opaque capability handle to the broker.
The broker derives caller pid, cwd, and sandbox markers from the accepted socket peer on the server side; client-supplied caller metadata is ignored.

For read-only operations, the raw captain credential does not reach the lane because no interactive shell is opened.
For `attach-existing`, the approved lane receives captain-equivalent interactive shell reach for the named session until the capability expires or the attach ends.
That is intentional and requires explicit per-session sign-off, a short session-bound TTL, and hash-chained audit records.
The approved lane controls shell stdin during attach, so the `StreamingRedactor` is only accidental-display and audit defense.
It is not a security boundary against a lane that intentionally drives the shell to transform and emit a secret.

## Supported operations

The v1 broker allows only these operations when the presented capability exactly matches the task, operation, expiry, and session id:

- `status`: lndev version, local auth identity metadata, token id/expiry, and GitHub status.
- `shell-list`: strict parsed `lndev shell ls` metadata.
- `attach-existing --session <id>`: a broker-owned PTY runs `lndev shell attach <id>` only when a capability names exactly that session.

Everything else is denied and audited.

## Safety gates

The broker rejects loop-sandbox callers by asynchronously inspecting the Unix socket peer with `LOCAL_PEERPID` on macOS or `SO_PEERCRED` on Linux, then reading that peer's cwd and environment markers server-side.
If peer env or cwd cannot be read, the request is denied rather than downgraded.

Request lines are capped at 64 KiB, queued attach frames at 256 KiB, and decoded stdin frames at 64 KiB.
Attach stdin honors Node stream backpressure and caps total queued stdin at 256 KiB.
Attach output is passed through a normalized, prefix-aware streaming redactor before forwarding as accidental-display defense.
The scanner normalizes CSI, OSC, DCS, SS2/SS3, carriage-return overwrites, and backspace overwrites before credential-shaped detection.
If the scanner sees credential-shaped material, the attach fails with `secret-output`.
This reduces accidental echo and keeps audit artifacts redaction-treated, but it does not change the captain-equivalent reach granted by an approved attach.

## Version and parser pin

Supported installed `lndev` versions are pinned in `src/common.mjs`.
The initial v1 pin is:

```text
lndev 0.1.0 (f6cc7cfe80561288b2dec737e79c1c12a379bcd8)
```

The broker probes `lndev --version` on start, before minting any capability, and once during identity collection for every request that passes task, allowlist, and capability validation.
An unknown version denies all operations, including `status`.
Each parsed command output must match the exact expected schema.
Changed, missing, duplicated, localized, truncated, error-shaped, or otherwise unrecognized output denies with `parse-mismatch`.

## Capability minting

Minting is explicit and firstmate-owned:

```sh
FM_HOME=/path/to/firstmate bin/fm-lndev-captain-broker.sh mint \
  --task lndev-work-a \
  --operation status \
  --ttl-seconds 3600 \
  --out /path/to/handle

FM_HOME=/path/to/firstmate bin/fm-lndev-captain-broker.sh mint \
  --task lndev-work-a \
  --operation attach-existing \
  --session eng-shell-session-id \
  --ttl-seconds 600 \
  --approval-id captain-approval-id \
  --out /path/to/handle
```

The store records only `sha256(handle)`, task metadata snapshot, operation, optional session id, expiry, and approval metadata.
The raw handle should be passed through a 0600 handle file when practical.
Attach capabilities default to `redacted-pty-jsonl` transcript capture.
Passing `--transcript-policy metadata-only` suppresses transcript-file capture but keeps request and attach lifecycle audit records.

## Use from a lane

```sh
FM_HOME=/path/to/firstmate FM_LNDEV_CAPTAIN_HANDLE_FILE=/path/to/handle \
  bin/fm-lndev-captain status --task lndev-work-a

FM_HOME=/path/to/firstmate FM_LNDEV_CAPTAIN_HANDLE_FILE=/path/to/handle \
  bin/fm-lndev-captain attach --task lndev-work-a --session eng-shell-session-id
```

`FM_HOME` is required so the socket and audit files resolve to the firstmate home, not to an arbitrary project worktree.

## Audit

Every broker start, capability mint, request, attach start, and attach stop appends a hash-chained JSONL audit record under:

```text
$FM_HOME/data/lndev-captain-audit/YYYY-MM-DD.jsonl
$FM_HOME/data/lndev-captain-audit/head.json
```

Files are written mode `0600` with a single-writer directory lock.
Audit records are keyed with an HMAC key stored outside `$FM_HOME`.
By default the key lives at `~/.firstmate/lndev-captain-audit.hmac-key`; set `FM_LNDEV_AUDIT_KEY_FILE` to use a different outside-home key path.
The hash is:

```text
hmac_sha256(key, prev_hash || canonical_json(record_without_record_hash))
```

Request records include broker version, task metadata, caller pid/ppid/exe/cwd/tty/env markers, operation, normalized args, session id, capability id, lndev identity metadata when available, result, reason, and duration.
Attach lifecycle records add the session id, broker attachment id, start and end timestamps, byte counts, detach result, transcript policy, and transcript digest metadata when a transcript file is retained.
The broker does not claim keystroke-level prevention or a tamper-proof boundary against a fully compromised same-UID lane.

With the default `redacted-pty-jsonl` attach transcript policy, the broker writes a redaction-treated PTY transcript under:

```text
$FM_HOME/data/lndev-captain-transcripts/YYYY-MM-DD/<attachment-id>.jsonl
```

That transcript contains the stdin, stdout, and stderr text observed by the broker after broker redaction rules are applied.
The attach stop audit record includes the transcript path, SHA-256 digest, byte count, and hash algorithm.
The transcript is accountability evidence for approved attach use, not a raw credential archive and not a security boundary.

Verify the chain with:

```sh
FM_HOME=/path/to/firstmate bin/fm-lndev-captain-broker.sh verify-audit
```

The HMAC chain is tamper-evident for accidental corruption and for tampering confined to `$FM_HOME`.
It also supports accountability for approved attach use by preserving request and attach lifecycle metadata.
It is not tamper-proof against a fully compromised same-UID lane that can read the outside-home HMAC key; that would require OS-user separation or an external append-only anchor outside v1.
