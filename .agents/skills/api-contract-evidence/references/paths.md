# API paths and observations

## Scenario matrix

| Path | Evidence to collect |
| --- | --- |
| Allowed | Correct identity and ownership, exact expected status and fields, expected writes and related effects. |
| Denied | Authenticated identity without the required permission, response contract and unchanged protected state. |
| Anonymous | Missing or invalid authentication, response contract and absence of protected data or mutation. |
| Cross-user or cross-tenant | Substitute a known foreign object's identifier or relation with a distinguishable identity and assert the declared boundary. |
| Invalid | Malformed, missing, boundary and conflicting inputs, error shape and contract-defined absence or scope of writes. |
| Replayed | Repeat the same operation/key and compare responses and persisted effects against the project's idempotency, conflict or duplicate semantics. |
| Partial failure | Inject an authorized fixture failure after an intermediate effect and assert the specified rollback, compensation or documented partial outcome. |

Use both user and tenant boundaries if the model has both, including foreign references in nested payloads or associations where relevant.
Add contract-relevant pagination, filtering and response-field selection cases, checking that list totals and metadata do not reveal foreign data.
Do not assume every refusal uses the same status, or that every replay is idempotent; derive expectations from the contract.
Mark a path not applicable with a model-based reason, and unverified when a required fault injection or observation is unavailable.

## Status, payload and persisted effects

Capture a known before-state and query the after-state with the project's authorized test helpers after the request settles.
Observe the protected entity, related rows, audit or outbox records, queued effects and external stubs that the operation can change, as applicable.
After refusal assert no unauthorized creation, update, deletion or queued effect, and compare protected fields rather than relying only on row counts.
Define allowed response fields from the contract and assert forbidden sensitive fields are absent in bodies, errors and relevant metadata, even when the status indicates failure.
Await asynchronous effects with the framework's supported completion condition so a quick before/after read cannot miss a delayed write.
For schema/runtime mismatches record which declaration and actual response disagree rather than changing the expected schema to match a failure.

## Reproducibility and sensitivity

Keep fictional identities distinguishable, isolate fixture state and use the project's cleanup/transaction helpers within the authorized environment.
Record application/schema revision, test command, scenario identity and ownership, request shape, expected and observed status/payload/effects, verdict and limitations without credentials or sensitive payloads.
Where authorized and useful, perturb one authorization check in an isolated fixture to demonstrate that the refusal/effect assertion fails, then restore it.
A simulated endpoint or mutation test can validate an evidence method but does not prove a real project's authorization boundary.
