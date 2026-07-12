# Shadow pre-live 30-day runbook (no-send)

**Purpose.** Operate the Socrata-backed shadow pipeline for 30 consecutive calendar days without sending, publishing, or taking action on behalf of a user. Every run is read-only, synthetic-safe, and reversible. This runbook is the gate for any later authorization request; it is not authorization to send.

## Guardrails and ownership

- **No-send invariant:** outbound email, SMS, webhook, CRM write, proposal submission, and browser form submit are disabled by policy and by ACL. A run that cannot prove the deny path is a FAIL.
- The on-call operator owns the run; a reviewer signs daily evidence; the service owner approves any rollback or authorization request. No individual may self-approve an exception.
- Production credentials, real personal data, and unapproved tokens are prohibited. Use fixtures and `MOCK_TOKEN` only.

## Time, freshness, and publication dates

- Store event timestamps in UTC (`YYYY-MM-DDTHH:mm:ssZ`). Display/reporting may use `America/Bogota` (UTC−05:00, no DST), with both zones shown at day boundaries.
- Define a reporting day by the **publication date** supplied by Socrata, not ingestion time. `publication DATE` is parsed as a calendar date in `America/Bogota`; late arrivals remain attributed to their publication day and are labelled late.
- Track two independent clocks: **Socrata freshness** (`now_utc - max(publication/update timestamp)`) and **internal latency** (source receipt → normalize → score → artifact). Never substitute internal latency for source freshness.
- Default warning/critical thresholds: freshness warning >24 h, critical >48 h; internal p95 warning >5 min, critical >15 min. Thresholds are configuration, versioned, and reviewed weekly.

## SLOs and alerts

For each UTC day, publish a signed SLO record: availability ≥99%, successful scheduled runs ≥95%, p95 internal latency ≤5 min, zero send attempts, and 100% fixture/ACL checks. Alert immediately on any send-path invocation, ACL drift, missing RUN_ID, stale source >48 h, duplicate publication dates, data/schema drift, or failed cleanup. Page on-call for critical; ticket warnings for next review. Alerts include RUN_ID, UTC timestamp, Bogota date, metric, threshold, and evidence URI.

## Synthetic fixtures, identity, and access

Every run starts with an immutable fixture set (small, boundary-heavy, and containing a known duplicate plus a known late publication). Generate a unique `RUN_ID` (UUID) and propagate it through request headers, logs, metrics, and artifacts. Set `MOCK_TOKEN` in the isolated test context; reject unset, production-looking, or leaked tokens. ACL must allow Socrata read and artifact write only; explicitly deny all outbound network destinations and send/write APIs. Capture an ACL snapshot and hash before execution.

## Daily procedure (30 days)

1. Check previous-day evidence, open alerts, clock synchronization, fixture hash, ACL hash, and clean workspace. Record operator/reviewer in the run ledger.
2. Execute the scheduled shadow job with `RUN_ID`, `MOCK_TOKEN`, pinned schema/query version, and a read-only Socrata response (or a recorded fixture when offline). Record source ETag/Last-Modified, publication dates, row counts, and freshness/latency metrics.
3. Reconcile publication-date buckets in UTC and `America/Bogota`; verify late-arrival labeling, deduplication, deterministic scoring, and idempotent replay. Confirm no side effect beyond the run artifact.
4. Run the synthetic send-path probe: assert deny/short-circuit, zero outbound requests, and zero mutations. Store the negative result, not credentials or payloads.
5. Run fault probes scheduled for the day (timeout, 429, malformed row, schema field removal, duplicate page, clock skew, partial write). Verify bounded retry/backoff, quarantine, alerting, and safe halt.
6. Execute cleanup: revoke the run token, remove temporary files, clear queues, and verify no orphan process/session/container. Re-run secret scan and ACL check.
7. Write an evidence bundle named `RUN_ID` containing manifest, hashes, logs, metrics, alert outcomes, fixture/ACL snapshots, and operator/reviewer attestations. Mark PASS or FAIL before the next run.

## Replay and fault matrix

A replay of the same fixture and query version must produce the same normalized rows, scores, and hashes. Replaying a RUN_ID is allowed only in a quarantined namespace and must never overwrite evidence. Inject one fault at a time; abort on unexpected side effects, unbounded retries, non-determinism, or inability to prove recovery. Keep fault injection and observed outcome in the ledger.

## Abort, cleanup, and evidence retention

Abort immediately on any send attempt, ACL/token anomaly, source poisoning, uncontrolled retry, clock ambiguity, data loss, or evidence gap. Disable the worker, isolate the run namespace, preserve volatile logs, and notify the service owner. Cleanup is complete only when deny checks pass, temporary credentials are revoked, queues are empty, and a post-cleanup filesystem/network/process scan is attached. Retain signed daily bundles and weekly summaries for at least 90 days; redact secrets and personal data.

## Reviews and decision gates

**Daily:** operator checks SLOs, freshness versus latency, no-send proof, faults, cleanup, and evidence completeness; reviewer countersigns or records FAIL/RCA. **Weekly:** service owner reviews seven-day trends, alert quality, schema/query changes, fixture coverage, ACL diffs, and open risks; approve threshold/config changes explicitly.

At day 30, produce a PASS/FAIL report. PASS requires 30 complete daily bundles, zero send attempts/mutations, all critical SLOs met or documented exceptions, deterministic replay, successful fault/cleanup checks, and reviewer signatures. Any missing proof is FAIL. On FAIL, rollback to the last known-good query/schema/config, disable scheduling if required, quarantine affected artifacts, open an RCA, and repeat the failed window; do not delete evidence.

## Authorization and rollback

No production authorization is implied by PASS. A separate, written authorization must name scope, sender identity, destinations, rate limits, monitoring, abort owner, and start/end times. Before enabling any send capability, rerun ACL and secret checks, stage a canary with an explicit approval, and record the authorization ID. At any anomaly, invoke the abort owner, disable send ACL, revoke tokens, and restore the last known-good configuration; attach rollback evidence to the ledger.