# Provider reachability probe verification

Audience: maintainer verification.

This record supports the one bounded reachability probe in `bin/fm-provider-reach-probe.sh` and the fleet-operations finding that motivated it: an upstream provider outage was previously visible only by reading worker panes, so "the endpoint is down" was never a machine-readable condition at an intake.
It records only facts that must be re-established when the probed endpoint or the probe's own classification changes.
Incident chronology and quota posture stay in private reports.

The probe collects a fact and renders no verdict. It reads no dispatch configuration, holds no provider table, and decides no eligibility; `.agents/skills/quota-array-dispatch/SKILL.md` owns those judgments.

## What each observed HTTP class does and does not prove

Verified against local stand-ins in `tests/fm-provider-reach-probe.test.sh`, which pins every expected value to a fake resolver and a fake curl rather than to live traffic.
The classes below are the shapes this home has actually recorded from the registered endpoint.

| Observed | `result=` | Exit | Proven | Not proven |
| --- | --- | --- | --- | --- |
| DNS returns no address (NXDOMAIN and friends) | `unreachable` with `dns=nxdomain` | 20 | the name resolves to nothing usable | anything about HTTP, because no request is sent |
| DNS lookup fails without a recognizable answer shape (resolver errored, e.g. no network or a refused query; carries `dns_detail=rc=<code>`) | `unreachable` with `dns=fail` | 20 | the lookup itself did not complete usefully | anything about HTTP, because no request is sent either - `rc=` names the resolver's own status, not an upstream verdict |
| connection fails, times out, or yields no code (`000`) | `unreachable` with `reason=no_connection` | 20 | no request could be completed | whether the service itself is healthy |
| `401` / `403` | `routed-auth` | 10 | a request reached the endpoint and was answered with an authorization refusal | usability - no credential is sent, so this is routing evidence only |
| `2xx` | `reachable` | 0 | the endpoint is routable and answering on the probed path | model availability, credential validity, or that a large or long-output request succeeds |
| other codes including `5xx` | `server-error` | 11 | the endpoint answered but is unhealthy or behaves unexpectedly | the cause |
| resolver tool absent | `dns=skipped`, then the HTTP verdict | per HTTP | nothing about DNS; disclosed as `dns_tool_missing` | - |
| no usable curl executable | `tool-missing` | 64 | this surface could not be probed | any claim about the endpoint |

## Resolver candidates and one recorded misclassification

The default candidate list is `/usr/bin/dig` then `/usr/bin/host`; `FM_PROVIDER_REACH_DNS_TOOL` overrides it with one tool or a preference list, which is also what keeps the suite deterministic on every host.

It previously led with macOS's `/usr/bin/dscacheutil`, called as `-q host -a <name>`.
That is not one of its directory-service categories, so it answered **every** name with its usage block and exit 64, and because those calls come first in the list they set the DNS phase: an NXDOMAIN endpoint was recorded as `dns=fail dns_detail=rc=64` - "the resolver errored" - rather than "the name resolves to nothing".
The exit verdict stayed 20 by fallthrough, so the class was right and the shape was wrong.
Reproduced first-hand on this host: `dscacheutil -q host -a api.xhyapi.com` prints usage and exits 64 while `dig` reports `status: NXDOMAIN` and `host` reports `not found: 3(NXDOMAIN)` for the same name.
A reader must therefore treat `dns=fail rc=<code>` from any build before this correction as an unusable lookup, not as evidence about the endpoint.
`tests/fm-provider-reach-probe.test.sh` now pins the candidate list so a tool the probe cannot call correctly cannot re-enter it.

Two asymmetries are load-bearing and are the reason the verdicts are not collapsed into exit-success:

- A `401`/`403` shares no meaning with a `000`. The first is a live endpoint refusing an unauthenticated request; the second is the signature of an unreachable provider. Recording either as "down", or the first as "up", would misroute the next dispatch decision.
- A `2xx` is deliberately worded `reachable`, never `available`. This home has recorded an outage where small requests returned `200` while long-output requests hung for 60 seconds, so a successful probe is not evidence that a heavy pipeline run will finish.

## Registered target

| Target | Base URL probed | Notes |
| --- | --- | --- |
| `xhy` | `https://api.xhyapi.com/v1/models` | Unauthenticated `GET`. The path answers `401` when the route is live, which is what makes the `routed-auth` class distinguishable from an outage. |

Any added target requires its discriminator behavior to be verified first-hand and recorded here before registration.

## Why the dispatch configuration cannot carry a health predicate

Established by inspecting both consumers of `config/crew-dispatch.json` in this repository:

- The bootstrap validator (`crew_dispatch_validate` in `bin/fm-bootstrap.sh`) and the resolver's stricter preflight (`rules_err` in `bin/fm-dispatch-resolve.sh`) enumerate exactly the consumed keys: rule `when`, `use`, `why`, `approval`, `min_confidence`, `select`, `floor`, and profile `harness`, `model`, `effort`, `provider`, `floor`.
- `bin/fm-dispatch-resolve.sh` renders its answer as `profile: --harness <h> [--model <m>] [--effort <e>]` only, so a profile cannot carry any additional axis forward to a spawn.
- Neither consumer has any code path that runs an external command, reads a health signal, or observes an outage; the only condition inputs available are quota percentages from one `quota-axi` snapshot and the harness catalog.

An outage is therefore invisible to the ladder in principle, not just unconfigured: a provider whose endpoint does not resolve can still report ample remaining quota. Adding a field would require a new config-executes-command surface plus a caching and failure policy across two validators, the resolver, `fm-spawn.sh`, and `docs/configuration.md`'s schema ownership - machinery beyond the scope of a single-point fix.

What the existing schema already expresses is a quota floor (`floor.scope`, `floor.min_percent`, rule-level and profile-level), which falls through or escalates on a *measured* shortfall. That remains the right declaration for capacity, and it is orthogonal to reachability.
