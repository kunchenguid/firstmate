---
name: performance-optimization
description: Improves application and tool performance through measurement, targeted changes, and repeatable verification. Use when requirements include latency or resource budgets, a regression is suspected, or profiling identifies a bottleneck.
metadata:
  internal: true
  adapted-from: addyosmani/agent-skills@7829ffd90d973b6325f5f12f1b1226dcace74443
---

# Performance Optimization

This is a Firstmate-adapted application-engineering skill inspired by Addy Osmani's agent-skills project.

Firstmate's AGENTS.md owns scope, delivery, and validation authority.
This skill prevents unmeasured optimization and does not authorize speculative complexity.

## Measure before changing

Define the user-visible symptom, affected budget, representative environment, and baseline measurement.
Identify the bottleneck with profiling, traces, query timing, bundle analysis, or runtime metrics rather than assumption.
Choose one change that directly targets the measured bottleneck.
Re-measure with the same command, conditions, sample count, and cache state.
Keep the change only when the improvement exceeds normal run-to-run variance and correctness remains green.
Record a neutral or regressed experiment as reverted evidence instead of keeping complexity that did not pay for itself.

## Common checks

Check list and API pagination, N+1 queries, unbounded payloads, missing indexes, cache behavior, and timeout boundaries.
For browser work, check network waterfalls, long tasks, layout shifts, interaction latency, image dimensions, and bundle size.
For tools, check startup cost, repeated filesystem or process scans, subprocess lifetime, output volume, and failure retries.
Do not add memoization, caching, concurrency, or batching without measuring the invalidation and correctness trade-off.

## Guard the result

Add a focused regression test, performance budget, benchmark, or monitoring signal when the repository supports it.
Keep before-and-after numbers with the task evidence or PR rather than burying them in generic documentation.
Do not bundle unrelated optimizations into one measurement.

## Verification

The bottleneck is identified with evidence.
The change is measured before and after under comparable conditions.
Correctness tests and repository gates remain green.
The observed improvement exceeds noise or the change is reverted.
A durable test, budget, or monitoring guard exists when the regression risk warrants one.
