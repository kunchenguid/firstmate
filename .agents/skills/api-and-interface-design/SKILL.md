---
name: api-and-interface-design
description: Designs stable, validated, backward-compatible application and tool interfaces. Use when defining APIs, module boundaries, schemas, component contracts, or integrations between producers and consumers.
metadata:
  internal: true
  adapted-from: addyosmani/agent-skills@7829ffd90d973b6325f5f12f1b1226dcace74443
---

# API and Interface Design

This is a Firstmate-adapted application-engineering skill inspired by Addy Osmani's agent-skills project.

Firstmate's AGENTS.md owns task authority and delivery mechanics.
This skill supplements product interface design and does not approve breaking changes, new integrations, or security-sensitive scope.

## Contract first

Define inputs, outputs, errors, state transitions, compatibility expectations, and examples before implementation.
Treat every observable behavior as a potential consumer contract.
Keep public and internal interfaces explicit enough that misuse is difficult.
Separate caller-provided input from server-generated output.
Prefer additive optional fields and extensions over removing or changing existing fields.
Use one consistent error shape and status mapping within a service.

## Boundary rules

Validate external input at the system boundary.
Validate third-party responses before using, storing, or rendering them.
Do not repeat defensive validation inside trusted internal calls unless the boundary has changed.
Keep authorization checks at the resource boundary and do not confuse authentication with permission.
Make idempotency, pagination, ordering, retries, timeouts, and rate limits explicit when they are observable.
Document deprecation and migration behavior before changing a public interface.

## Interface review

Use predictable names and consistent representations across related endpoints.
Prefer resource-oriented routes and partial updates where the existing contract supports them.
Use discriminated variants when states have different required fields.
Avoid parallel versions unless compatibility evidence requires them.
Add contract tests for every new or changed boundary.
Check consumers, generated clients, fixtures, documentation, and telemetry before changing an established surface.

## Verification

Every public interface has typed or executable input and output expectations.
Error behavior is consistent and does not leak internal details.
Boundary validation and authorization are covered by tests.
Compatibility and migration behavior are documented with the implementation.
The final review names any unresolved contract decision instead of silently choosing one.
