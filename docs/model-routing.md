# Advisory model routing

Phase 1 provides a strict, versioned contract for an advisory model route decision.
The contract is defined by [`schemas/fm-route-decision.v1.json`](../schemas/fm-route-decision.v1.json), and [`bin/fm-route-decision.sh`](../bin/fm-route-decision.sh) is the deterministic executable validator.

## Opt-in behavior

This feature is advisory and opt-in.
It does not classify captain prompts, select a route automatically, launch or replace workers, replan after failures, merge changes, or install or download models.
A caller must explicitly provide a decision to `fm-route-decision.sh validate`.

Firstmate still owns privacy preflight, model catalog and authentication checks, quota checks, effort selection, worker launch, supervision, validation, and merge authority.
A valid route decision is not evidence that a provider is authenticated, a model is available, quota exists, or a route is safe for a particular prompt.

## Route profiles

The allowlisted logical route profiles are:

- `local-qwen-14b` uses provider class `local` and logical model `qwen-14b`.
- `cloud-luna` uses provider class `cloud` and logical model `luna`.
- `cloud-opus-4-8` uses provider class `cloud` and logical model `opus-4-8`.
- `escalate` uses provider and model value `none` and requests human or higher-level handling instead of a model route.

The local Qwen profile is a contract for a logical route only.
It does not assert an Ollama provider or model identifier, and the exact local endpoint and model configuration remain operator configuration.
The cloud profiles likewise do not encode credentials, account identity, catalog support, or quota availability.

Cloud profiles require `privacy: "cloud-allowed"`.
The local profile accepts either privacy classification because a local route does not require cloud transmission.
Escalation is valid for either privacy classification and can carry low confidence.
Non-escalation advisory decisions require confidence from `0.5` through `1`.

## Decision validation

A decision has exactly the fields `schema`, `route`, `provider`, `model`, `confidence`, `privacy`, `source`, `reason`, and `override`.
Unknown fields, routes, provider classes, and logical model values are rejected.
The validator also rejects malformed JSON, profile/provider/model mismatches, cloud privacy conflicts, invalid override relationships, and low-confidence non-escalation advice.

Validate JSON from a file or stdin:

```sh
bin/fm-route-decision.sh validate decision.json
printf '%s\n' '{"schema":"fm-route-decision.v1",...}' | bin/fm-route-decision.sh validate -
```

Inspect one allowlisted profile without resolving any provider endpoint:

```sh
bin/fm-route-decision.sh profile local-qwen-14b
```

An advisory decision uses `source: "advisory"` and `override: null`.
An explicit operator decision uses `source: "explicit"` and an `override` object whose route and reason match the effective route.
The explicit route therefore takes precedence over an advisory recommendation, while the validator still only checks the supplied result and never chooses a route.
