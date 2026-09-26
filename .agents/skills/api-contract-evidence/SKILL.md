---
name: api-contract-evidence
description: Produce endpoint contract evidence for authorized and refused requests, identity boundaries, invalid input, replay and partial failure, comparing responses with persisted effects; does not define authorization policy or run a general security audit.
metadata:
  internal: true
---

# API contract evidence

Own the endpoint evidence matrix that connects the authoritative contract to responses and persisted effects.
Read the project's schema, role/permission rules, user and tenant ownership model, error contract and transaction or replay semantics first.
Use its existing test framework, isolated fictional fixtures and authorized test environment; do not infer permission to mutate production, add a scanner or change security policy.
Read [paths and observations](references/paths.md) when preparing scenarios.

## Evidence procedure

1. Link the endpoint and each scenario to the authoritative behavior, expected status, allowed response fields and expected persisted effects.
2. Establish distinguishable fictional identities, owned and foreign objects, known preconditions and a before-state through the project's supported test helpers.
3. Exercise allowed, denied, anonymous, cross-user or cross-tenant, invalid, replayed and partial-failure paths where applicable.
4. Assert status, payload and after-state together, including absence of writes and sensitive-field leaks after refusal.
5. Compare declared schema and observed runtime behavior and preserve failures as reproducible tests using the existing framework.
6. Report observed results, fixture identity, commands and limitations in the existing evidence surface; route ambiguous policy through the project's existing decision owner.

A forbidden status alone is insufficient evidence of refusal, and a schema-valid payload alone is insufficient evidence of authorization.
These checks inform the existing review and delivery path and create no independent security authority or gate.
This skill is original repository guidance and vendors no third-party prompt, executable or remote instruction feed.
