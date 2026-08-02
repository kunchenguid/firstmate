---
name: security-and-hardening
description: Applies threat modeling and secure boundary practices to application and tool changes. Use when handling untrusted input, credentials, authorization, external integrations, files, webhooks, or model output.
metadata:
  internal: true
  adapted-from: addyosmani/agent-skills@7829ffd90d973b6325f5f12f1b1226dcace74443
---

# Security and Hardening

This is a Firstmate-adapted application-engineering skill inspired by Addy Osmani's agent-skills project.

Firstmate's AGENTS.md owns captain authority for destructive, irreversible, and security-sensitive choices.
This skill identifies and tests security controls but never answers a required captain decision on its own.

## Threat model first

Map every trust boundary where user input, files, webhooks, third-party data, or model output enters the system.
Name the assets, actors, permissions, and failure consequences before choosing controls.
Use STRIDE or an equivalent short abuse-case pass over each boundary.
Turn the highest-value abuse cases into tests before implementation where feasible.

## Always protect

Validate external input at the boundary and constrain size, shape, encoding, and allowed values.
Parameterize database queries and encode output through the framework's safe path.
Enforce authorization for every protected resource, not only authentication.
Keep secrets out of source, logs, browser storage, prompts, and durable reports.
Use secure session settings, transport security, security headers, and restrictive CORS where applicable.
Treat third-party responses and model output as untrusted data and validate before executing, rendering, or storing them.
Use allowlists, timeouts, rate limits, and redirect controls for external requests.

## Ask before changing

Escalate new authentication or authorization behavior, sensitive data storage, external services, file uploads, CORS, rate limits, elevated permissions, or security boundary changes through Firstmate's ask-user authority.
Never use a security finding as permission to expand the product contract without that authority.

## Never

Never commit credentials, tokens, private keys, or sensitive personal data.
Never log passwords, session tokens, full payment data, or secrets.
Never pass untrusted data to a shell, eval, SQL string, raw HTML sink, or file path without a validated boundary.
Never disable a security control merely to make a test or tool run.
Never accept an audit result as proof that a dependency or input is safe without reachability and provenance review.

## Verification

Security-relevant boundaries have a threat model and focused abuse-case tests.
Secrets and sensitive data are absent from the change and its logs.
Input, output, authorization, dependency, and external-request controls are verified for the affected path.
Native dependency audits and installation-script policy are checked when dependencies change.
Any unresolved security decision is escalated rather than silently accepted.
