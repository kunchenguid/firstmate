# Provider reachability probe verification

Audience: maintainer verification.

This record documents the behavior contract exercised by the local regression suite for `bin/fm-provider-reach-probe.sh`.
It records no live endpoint result and makes no claim about any provider's current health.

The probe collects a fact and renders no verdict. It reads no dispatch configuration, holds no provider table, and decides no eligibility; `.agents/skills/quota-array-dispatch/SKILL.md` owns those judgments.

## What each HTTP class does and does not prove

This section owns the interpretation of the probe's classes; [`--help`](../../bin/fm-provider-reach-probe.sh) owns exact invocation and exit-status mechanics.
The regression pointer is `tests/fm-provider-reach-probe.test.sh`, whose local stand-ins avoid relying on live provider traffic.
The classes below describe possible probe outcomes, not evidence of a provider's current state.

| Outcome | `result=` | Exit | Proven | Not proven |
| --- | --- | --- | --- | --- |
| DNS successfully reports NXDOMAIN, no answer, or an answer without an address record | `unreachable` with `dns=nxdomain` | 20 | the lookup found no usable address | anything about HTTP, because no request is sent |
| DNS resolution tool errors or reports SERVFAIL, FORMERR, REFUSED, or timeout (carries `dns_detail=rc=<code>` when available) | HTTP result with `dns=unknown` | per HTTP result | the lookup itself did not complete usefully; an HTTP request is still attempted | whether DNS resolved the name - `rc=` names the resolver's own status, not an upstream verdict |
| connection fails, times out, or yields no code (`000`) | `unreachable` with `reason=no_connection` | 20 | no request could be completed | whether the service itself is healthy |
| `401` / `403` | `routed-auth` | 10 | a request reached the endpoint and was answered with an authorization refusal | usability - no credential is sent, so this is routing evidence only |
| `2xx` | `reachable` | 0 | the endpoint is routable and answering on the probed path | model availability, credential validity, or that a large or long-output request succeeds |
| other codes including `5xx` | `server-error` | 11 | the endpoint answered but is unhealthy or behaves unexpectedly | the cause |
| no configured resolver is installed (the whole preference list misses) | `dns=skipped`, then the HTTP verdict | per HTTP | nothing about DNS; disclosed as `dns_tool_missing` | - |
| no usable curl executable | `tool-missing` | 64 | this surface could not be probed | any claim about the endpoint |

## Resolver candidate behavior

The default candidates are `/usr/bin/dig` and `/usr/bin/host`; `FM_PROVIDER_REACH_DNS_TOOL` can override them with one tool or a whitespace-separated preference list.
Candidates that are not installed are skipped, and resolver errors (timeout, non-zero exit, SERVFAIL, FORMERR, or REFUSED) advance to the next installed candidate. If all installed candidates fail uncertainly, the probe reports `dns=unknown` and continues to HTTP; only a valid no-address answer terminates before HTTP.
A valid no-address answer is terminal, so a later candidate cannot turn NXDOMAIN/NODATA into a positive result.
The resolver receives only the host component of `--host`; a port is removed and a bracketed IPv6 literal is unwrapped, while IP literals skip DNS and proceed to HTTP.
The deterministic regression cases for fallback, terminal no-address answers, and resolver output classification are in `tests/fm-provider-reach-probe.test.sh`.

Two asymmetries are load-bearing and are the reason the verdicts are not collapsed into exit-success:

- A `401`/`403` shares no meaning with a `000`. The first is a live endpoint refusing an unauthenticated request; the second is the signature of an unreachable provider. Recording either as "down", or the first as "up", would misroute the next dispatch decision.
- A `2xx` is deliberately worded `reachable`, never `available`. A successful response to this bounded request does not establish that a larger or longer request will finish.

## Dispatch configuration

The authoritative description of dispatch schema limits and quota-floor semantics is [`docs/configuration.md`](../configuration.md).
This probe supplies reachability evidence only; routing that evidence to an eligible candidate remains a separate judgment owned by `.agents/skills/quota-array-dispatch/SKILL.md`.
