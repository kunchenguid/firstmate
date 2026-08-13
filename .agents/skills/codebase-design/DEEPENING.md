# Deepening

How to deepen a cluster of shallow modules safely, given its dependencies.
Assumes the vocabulary in [SKILL.md](SKILL.md) - **module**, **interface**, **seam**, **adapter**.

## Dependency categories

When assessing a candidate for deepening, classify its dependencies.
The category determines how the deepened module is tested across its seam.

### 1. In-process

Pure computation, in-memory state, no I/O.
Always deepenable - merge the modules and test through the new interface directly.
No adapter needed.

### 2. Local-substitutable

Dependencies that have local test stand-ins (PGLite for Postgres, in-memory filesystem).
Deepenable if the stand-in exists.
The deepened module is tested with the stand-in running in the test suite.
The seam is internal; no port at the module's external interface.

### 3. Remote but owned (Ports & Adapters)

Your own services across a network boundary (microservices, internal APIs).
Define a **port** (interface) at the seam.
The deep module owns the logic; the transport is injected as an **adapter**.
Tests use an in-memory adapter.
Production uses an HTTP/gRPC/queue adapter.

Recommendation shape: *"Define a port at the seam, implement an HTTP adapter for production and an in-memory adapter for testing, so the logic sits in one deep module even though it's deployed across a network."*

### 4. True external (Mock)

Third-party services (Stripe, Twilio, etc.) you don't control.
The deepened module takes the external dependency as an injected port; tests provide a mock adapter.

## Apply the shared seam and testing rules

Use the seam discipline and test-surface contract owned by [SKILL.md](SKILL.md).
For a deepening change, the dependency category above determines which production and test adapters justify the seam.
Once equivalent coverage exists at the deepened module's interface, delete superseded tests of the old shallow modules instead of layering both suites indefinitely.
