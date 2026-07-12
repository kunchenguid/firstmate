# Shadow pre-live 30-day runbook (no-send)

**Purpose.** Run the Socrata shadow pipeline for 30 consecutive calendar days
without sending, publishing, or acting for a user. This is evidence for a
later authorization request, never authorization itself.

## Guardrails, identity, and access

- Deny outbound email, SMS, webhook, CRM write, proposal submission, and form
  submit by policy and ACL. A failed deny check is a FAIL, not a send incident.
- Each run has `RUN_ID` matching `^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`.
  Propagate it through headers, logs, metrics, and artifacts.
- Set only fixture `MOCK_TOKEN`, matching `^MOCK_[A-Za-z0-9_-]{16,}$`; reject
  unset, production-looking prefixes, JWTs, or tokens found by the secret scan.
- ACL permits Socrata read and evidence write only. Deny all outbound routes
  and send/write APIs. Record the canonical sorted policy and `sha256sum`
  before and after each run; attach the hash and redacted command output.

## Time, DATE, and freshness

- Persist timestamps in UTC ISO-8601 with `Z`. Display UTC and
  `America/Bogota` (UTC−05:00, no DST); require NTP offset ≤2 seconds.
- The Socrata `publication DATE` has no time zone or time of day. Parse it as a
  Bogota calendar date and use it for day buckets, regardless of arrival time.
  If an `update_timestamp` exists, use it for freshness; otherwise use the
  latest source `Last-Modified`/ETag observation. If all are absent, freshness
  is `UNKNOWN` and the run cannot PASS.
- Freshness is `now_utc - chosen source timestamp`; internal latency is
  receipt → normalize → score → artifact. Report both; never use one as the
  other. Late rows retain their publication DATE and are labelled late.

## SLOs, windows, exceptions, and alerts

For each UTC 24-hour window, sign a record with denominators and numerators:
availability ≥99% (scheduled minutes), successful runs ≥95% (scheduled runs),
p95 internal latency ≤5 minutes (completed runs), zero real send attempts,
and 100% fixture/ACL checks (checks performed). Freshness warning is >24 h and
critical >48 h; internal-latency warning is p95 >5 min and critical >15 min.
Alert on missing `RUN_ID`, unknown freshness, ACL/hash drift, schema drift,
failed cleanup, or a real send attempt. A synthetic expected-deny probe is
recorded as a normal PASS and must not page; only an unexpected allow or real
side effect is an incident. Exceptions require owner, reason, scope, expiry,
and reviewer signature; expired or unsigned exceptions count as FAIL.

## Fixtures and daily procedure

Use an immutable, hashed fixture set with boundary dates, a known duplicate row,
and a known late publication. The 30-day window starts at Day 1 and must contain
30 consecutive UTC calendar dates; a missed day pauses the gate and requires a
signed reason, rerun, and a new consecutive window (no backfill credit).

1. Verify clock/NTP, prior evidence, alerts, fixture hash, ACL hash, and a
   clean workspace. Record operator and reviewer.
2. Run the read-only job with pinned schema/query versions, `RUN_ID`, and
   `MOCK_TOKEN`. Record source metadata, DATE values, row counts, and both
   freshness and latency.
3. Reconcile DATE buckets in UTC/Bogota. Distinguish duplicate rows or
   revisions (same entity/version conflict) from a repeated DATE, which is
   normal and is not an alert by itself. Verify deterministic scoring and
   canonical deduplication.
4. Execute the synthetic send-path probe with a fixture payload. Expected
   short-circuit/deny, zero outbound requests, and zero mutations is a normal
   control result. A real intent, allow, or mutation aborts and pages.
5. Run that day's fault from the matrix below. Verify bounded recovery.
6. Revoke the mock token, delete temporary files, clear queues, and verify no
   orphan process/session. Repeat secret, ACL, and deny scans.
7. Write a redacted `RUN_ID` evidence bundle: manifest, canonical hashes,
   logs, metrics, alerts, fixture/ACL snapshots, and attestations.

## Day-to-fault matrix and recovery

| Days | Fault | Required bounded behavior |
|---|---|---|
| 1–4 | timeout, DNS failure | ≤3 retries, exponential backoff 1/2/4 s plus jitter, then quarantine and alert |
| 5–8 | HTTP 429/rate limit | honor `Retry-After`, ≤3 attempts, quarantine after deadline |
| 9–12 | malformed row/missing field | reject row, preserve reason, continue safe batch, alert schema owner |
| 13–16 | duplicate page/row revision | canonical dedup, stable hash, no duplicate side effect |
| 17–20 | source stale or clock skew | mark freshness UNKNOWN/critical, halt scoring, page on-call |
| 21–24 | partial artifact write | atomic temp-to-final write; quarantine incomplete artifact and recover |
| 25–27 | ACL/token drift | fail closed, revoke token, preserve evidence, escalate |
| 28–30 | combined replay and recovery | execute one isolated fault at a time, then prove clean recovery |

No retry may exceed the run deadline or five total attempts. Quarantine is a
separate immutable namespace; recovery must be evidenced before PASS.

## Replay, abort, cleanup, and rollback

Replay the same fixture, query/schema version, configuration hash, and frozen
UTC clock. PASS requires identical canonical normalized-row, score, and
artifact hashes. Replay `RUN_ID`s only in a quarantined namespace and never
overwrite evidence.

Abort immediately on an unexpected allow, real side effect, token/ACL anomaly,
data loss, unbounded retry, or evidence gap. If the worker does not stop within
60 seconds, escalate to the service owner at 60/120 seconds, revoke the token,
disable scheduling, and isolate the namespace. Preserve immutable logs before
cleanup. Roll back only to a signed last-known-good config/schema/query hash;
record old/new hashes, operator, time, reason, and verification. Never delete
failed evidence. Redact secrets and personal data; retain signed daily bundles
and weekly summaries for 90 days.

## Reviews and authorization gate

Daily, the operator checks SLO denominators, DATE/freshness versus latency,
expected-deny proof, fault result, cleanup, and evidence; the reviewer signs or
records FAIL/RCA. Weekly, the owner reviews seven-day trends, alert quality,
schema/query changes, fixture coverage, ACL diffs, and exceptions.

PASS at Day 30 requires 30 consecutive complete bundles, zero real send
attempts/mutations, critical SLOs met or valid unexpired exceptions,
deterministic replay, all scheduled faults recovered, cleanups, and signatures.
Any missing proof is FAIL; rollback, quarantine, RCA, and restart the 30-day
window. PASS never authorizes production. A separate written authorization must
name scope, identity, destinations, rate limits, monitoring, abort owner,
start/end, and expiry. Recheck ACL, secret scan, hashes, and a canary approval
before any capability change.
