# Provider reachability probe verification

Audience: maintainer verification.

This record documents the behavior contract exercised by the local regression suite for `bin/fm-provider-reach-probe.sh`.
It records no live endpoint result and makes no claim about any provider's current health.

The probe collects a fact and renders no verdict. It reads no dispatch configuration, holds no provider table, and decides no eligibility; `.agents/skills/quota-array-dispatch/SKILL.md` owns those judgments.

## Why there is no built-in endpoint

The only input is `--host`: the probe ships no provider table, alias, or registered target, so no name it accepts makes it call a host the caller did not name.
That is an authorization boundary rather than a convenience trade.
A built-in vendor target would have the tool decide by itself to send an unauthenticated request to one particular third party; with an explicit host the destination, and the responsibility for it, stay with the caller.
The cost is that a local use must spell the host out.

That cost is worth recording with the mistake it prevents.
The host in local use is `xhyapi.com`, with no `api.` prefix, while `api.xhyapi.com` answers NXDOMAIN permanently.
The built-in target this probe no longer carries pointed at `api.xhyapi.com`, so asking for it produced a no-address answer that looked exactly like an upstream outage for several days.
With the endpoint named explicitly, the same slip shows up as an explicit configuration error instead of a silent default.

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
A `--host` that carries userinfo is refused before anything is resolved or requested, so a credential can never be composed into a request URL.
A bare IPv6 literal is accepted and bracketed for the request URL, while a port on an IPv6 literal requires the bracketed `[address]:port` form.
The probe is a parse error, never a probe finding, when `--host` is missing, malformed, a full URL, a query string, or credential-bearing: it exits 2 with a diagnostic on stderr and prints no probe line.
A name the resolver answers with no address is the opposite case: it is a real finding, reported as `dns=nxdomain` with exit 20 on one probe line, so a mistyped input can never be read as an outage.
A failed A lookup without explicit NXDOMAIN/no-record evidence triggers an AAAA lookup where supported; an inconclusive resolver outcome is `dns=unknown` and does not suppress the HTTP request.
For HTTPS requests, ambient HTTPS and all-proxy settings remain usable when credential-free; proxy URLs carrying userinfo are refused before HTTP unless `NO_PROXY` bypasses the proxy. `NO_PROXY` host and domain-suffix comparisons are case-insensitive, port-qualified entries do not bypass, wildcard characters are literal, and only a standalone `*` bypasses every host.
The deterministic regression cases for fallback, terminal no-address answers, resolver output classification, and proxy routing are in `tests/fm-provider-reach-probe.test.sh`.

Two asymmetries are load-bearing and are the reason the verdicts are not collapsed into exit-success:

- A `401`/`403` shares no meaning with a `000`. The first is a live endpoint refusing an unauthenticated request; the second is the signature of an unreachable provider. Recording either as "down", or the first as "up", would misroute the next dispatch decision.
- A `2xx` is deliberately worded `reachable`, never `available`. A successful response to this bounded request does not establish that a larger or longer request will finish.

## Dispatch configuration

The authoritative description of dispatch schema limits and quota-floor semantics is [`docs/configuration.md`](../configuration.md).
This probe supplies reachability evidence only; routing that evidence to an eligible candidate remains a separate judgment owned by `.agents/skills/quota-array-dispatch/SKILL.md`.
