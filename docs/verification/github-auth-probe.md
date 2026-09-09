# GitHub authentication probe verification

Audience: maintainer verification.

This record supports the GitHub credential probe in `bin/fm-bootstrap.sh` and the response rules in `.agents/skills/bootstrap-diagnostics/SKILL.md`.
It records only the vendor-behavior facts the probe's classification rests on, so they can be re-established when the `gh` version changes.
Task chronology and incident transcripts stay in private reports or PR evidence.

The probe exists because `gh auth status` cannot answer the operator's question on its own.
It validates the stored credential over the network, and it reports the same "token is invalid" verdict whether GitHub rejected the credential or the call never reached GitHub at all.
Everything below is what makes the follow-up reachability question necessary and sufficient.

## `gh auth status` cannot distinguish a rejected credential from an unreachable API

Verified 2026-09-03 against `gh version 2.96.0 (2026-07-02)` on darwin 27.0.0.
The healthy credential in every case below is a real `keyring`-stored OAuth token that a plain run confirms in under a second.

```
$ gh auth status
github.com
  ✓ Logged in to github.com account <user> (keyring)
  - Active account: true
$ echo $?
0
```

Forcing the API unreachable, with that same healthy credential untouched:

```
$ HTTPS_PROXY=http://192.0.2.1:9 gh auth status
github.com
  X Failed to log in to github.com account <user> (keyring)
  - Active account: true
  - The token in keyring is invalid.
  - To re-authenticate, run: gh auth refresh -h github.com
$ echo $?
1
```

A genuinely rejected credential produces the same exit status and the same "is invalid" verdict:

```
$ GH_TOKEN=<invalid> gh auth status
  X Failed to log in to github.com using token (GH_TOKEN)
  - The token in GH_TOKEN is invalid.
$ echo $?
1
```

So the exit status is not a verdict, and neither is the rendered "invalid" text.

## `gh auth status` fails for any configured host, not only the active credential

Verified 2026-09-09 against `gh version 2.96.0 (2026-07-02)` on darwin 27.0.0.
The github.com credential is the same healthy keyring token as above; `hosts.yml` additionally lists a second host whose token is invalid.

```
$ GH_CONFIG_DIR=<two-host config> gh auth status
github.com
  ✓ Logged in to github.com account <user> (keyring)
  - Active account: true

ghe.invalid
  X Failed to log in to ghe.invalid account someone (<config>/hosts.yml)
  - Active account: true
  - The token in <config>/hosts.yml is invalid.
$ echo $?
1
$ GH_CONFIG_DIR=<two-host config> gh api / -i
HTTP/2.0 200 OK
$ echo $?
0
```

So a stale or unreachable second host makes `gh auth status` exit 1 every session while github.com keeps accepting the active credential.
A probe that treats any completed exchange as a rejection turns that into a `NEEDS_GH_AUTH` for a credential GitHub just answered 200 to, which is the same false alarm by a different route.
This is why the probe discriminates on the status code rather than on the presence of a status line.
`--json hosts` carries the underlying cause but only inside a raw Go error string (`non-200 OK status code: 401 Unauthorized ...` versus `dial tcp ...: connect: connection refused`), and it always exits 0, so it moves the same prose dependency rather than removing it.

## `gh auth status` carries no timeout of its own

Verified 2026-09-03, gh 2.96.0.
Against a socket that completes the TCP handshake and then never answers, `gh auth status` never returned; the bound that stopped it came entirely from the caller.

```
$ HTTPS_PROXY=http://127.0.0.1:<stalling-listener> fm_run_timed 60 gh auth status
$ echo $?
124
```

Elapsed 60281ms, meaning the 60s caller bound fired.
An unroutable address fails faster (~7s on this host, because the connect fails rather than stalling), so a short local experiment does not establish a bound and none should be inferred from one.
This is why `FM_GH_AUTH_TIMEOUT` is applied through `bin/fm-timeout-lib.sh` rather than relying on the enclosing stage budget.

## The HTTP status code is the discriminator, with a second independent signal

Verified 2026-09-03, gh 2.96.0.
`gh api / -i` prints the response status line exactly when an HTTP exchange with GitHub completed, whatever the credential verdict:

```
$ gh api / -i                       -> HTTP/2.0 200 OK
$ GH_TOKEN=<invalid> gh api / -i    -> HTTP/2.0 401 Unauthorized
$ HTTPS_PROXY=http://192.0.2.1:9 gh api / -i
Get "https://api.github.com/": proxyconnect tcp: dial tcp 192.0.2.1:9: connect: connection refused
```

The status line is an RFC 9112 construct rather than a gh string, so it is the primary signal.
Only a 401 or 403 in it means GitHub refused the active credential.
A 2xx after a failed `gh auth status` means GitHub accepted the active credential and the failure belongs to another configured host or account, per the section above, so the probe reports it as `GH_AUTH_UNKNOWN` naming that entry rather than as a rejection.
Any other status is likewise unknown, because it neither confirmed nor refused the credential.
It is not sufficient alone: with no credential configured, gh attempts no request and prints no status line, yet this case does need `gh auth login`.

```
$ GH_CONFIG_DIR=<empty> gh api / -i
To get started with GitHub CLI, please run:  gh auth login
```

That instruction is the second, independent signal, and either one carries the re-authenticate verdict.
The unreachable output above contains neither, which is what keeps the two apart.
The `GH_AUTH_UNKNOWN` detail for a failed-elsewhere credential is the first `X` line of the `gh auth status` output with anything token-shaped redacted; the plain output carries no token without `--show-token`, so the redaction is a guard rather than a dependency.

`gh auth token` is NOT usable as a credential-presence probe: with `GH_CONFIG_DIR` pointing at an empty directory it still exits 0 and prints the keyring token, because the keyring is not scoped by the config directory.

## The resulting classification, against the real binary

Verified 2026-09-03, gh 2.96.0, running the probe exactly as a session start does
(`FM_BOOTSTRAP_NETWORK=only` plus `FM_BOOTSTRAP_DETECT_ONLY=1` is that one step).
The credential was healthy and untouched throughout; only reachability changed.

| Condition | Elapsed | Emitted |
| --- | --- | --- |
| network reachable | 1032ms | nothing - sign-in confirmed |
| API unreachable | 15190ms | `GH_AUTH_UNKNOWN: could not reach GitHub to confirm the credential` |
| second host in `hosts.yml` fails, github.com healthy (2026-09-09) | 1067ms | `GH_AUTH_UNKNOWN: github.com accepted the credential but gh auth status failed for another host or account (X Failed to log in to ghe.invalid account someone (<config>/hosts.yml))` |

Before this probe existed, the second row printed `NEEDS_GH_AUTH`, which is the false alarm that made the check untrustworthy.
The third row printed `NEEDS_GH_AUTH` under the probe's first revision, which keyed on the presence of a status line rather than its code.

## What re-verifies this

`tests/fm-bootstrap.test.sh` pins the classification with fakes reproducing each condition above, and `tests/fm-session-start.test.sh` pins the unreachable case end to end through the deferred startup stage.
Those fakes encode gh 2.96.0's observed behavior, so re-run the commands in this record after a `gh` major upgrade and update the fakes if the observed shapes change.
