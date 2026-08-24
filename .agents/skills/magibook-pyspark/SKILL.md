---
name: magibook-pyspark
description: >-
  Agent-only procedure for running data analysis on MagiBook with PySpark through the official magibook CLI.
  Use before creating, reusing, checking, initializing, waiting on, or running a MagiBook PySpark/Spark SQL analysis, and before writing an init or query Cell.
  Owns the inspect-ensure-wait-query lifecycle, the four-state Spark liveness model, single-initialization safety, and copy-ready init and query Cell templates; it does not own region defaults or cluster identifiers, which come from the captain-preference owner.
user-invocable: false
metadata:
  internal: true
---

# MagiBook PySpark analysis

Load this before any MagiBook PySpark work: creating, reusing, checking, initializing, waiting on, or running an analysis, and before writing an init or query Cell.
It exists so a Firstmate run reuses a live Spark session instead of stacking a second one, and refuses to guess when session health is unclear.

Do all MagiBook work through the official `magibook` CLI.
Consult current `magibook --help` and the relevant subcommand help (`magibook book --help`, `magibook cell --help`, `magibook cell create --help`, `magibook cell run --help`, `magibook cell task-status --help`, `magibook cell view --help`) rather than guessing flags; the CLI owns its own mechanics and they can change between versions.

## Region is always explicit

Never rely on the CLI's default region.
Pass `--region <region>` on every `magibook` invocation.
For Firstmate operations the default region and the validated Book, Cell, cluster, queue, and executor values are owned by the captain-preference owner (`data/captain.md`, or `data/captain-shared.md` for a secondmate home), not by this skill.
Read that owner at the start of a run and apply its values.
This skill deliberately carries no Book IDs, Cell IDs, cluster names, queues, dates, or other home-specific identifiers, so it stays a shared template.
If the captain-preference owner has no MagiBook entry, that is a `needs-decision` for the region and target Book, not a value to invent here.

Clear conventional proxy variables only in the child process, never in the ambient shell:

```bash
env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u NO_PROXY \
    -u http_proxy -u https_proxy -u all_proxy -u no_proxy \
    magibook --region <region> cell list <book_uuid>
```

## Lifecycle

Run these phases in order for every new analysis run.

1. Inspect.
   Read the exact Book, Cell, and task state with the CLI before doing anything.
   List cells (`magibook --region <region> cell list <book_uuid>`), view the init and query Cells' current source read-only (`magibook --region <region> cell view <cell_id>`), and check any in-flight task (`magibook --region <region> cell task-status <task_id>`).
   A stored application id or a prior successful Cell output is evidence of history, not proof the session is live now.
2. Ensure.
   Determine the live Spark state and initialize at most once.
   Use the four-state model below; the init template implements it.
   If the instance is live, reuse it with no initialization.
   If no usable instance exists, submit the init Cell exactly once, then move to wait.
3. Wait.
   A slow, pending, or executing initialization is polled, never duplicated.
   Poll the exact init task with `cell task-status` and allow long bounded waits for first YARN scheduling and Spark startup.
   Never submit a second init Cell or a second SparkContext because scheduling is slow; a duplicate submission is the failure this skill exists to prevent.
4. Query.
   Once ensured live, run business logic through `spark.sql("""SELECT ...""")` on the ensured session using the query template.
   Do not use Dorado, TQS, or any direct SQL submission path for query work here.
5. Persist and reuse (optional).
   When multiple actions read the same filtered or joined base, materialize it once with a purposeful `persist(StorageLevel.MEMORY_AND_DISK)`, reuse that cached DataFrame across the rounds, and `unpersist()` it promptly when the analysis no longer needs it.
6. Reconcile terminal output.
   Read each submitted Cell's output (`magibook --region <region> cell view <cell_id> --output`) and reconcile the exact task status.
   Confirm the query Cell's reported application id matches the ensured session's, proving session reuse.

## Four-state Spark model

Liveness is proven by a minimal Spark action, never by the presence of `SparkContext._active_spark_context` alone.
A probe failure is classified, not swallowed: authentication, authorization, scheduler, network, and query failures stay distinguishable from genuine absence.

- Absent/stopped: no active context, or the context object reports stopped. Safe to initialize exactly once.
- Live: a context exists and a minimal Spark action succeeds. Reuse it; never build.
- Initializing: a context exists but its application id is not yet assigned, or the probe shows it is still starting. Poll the init task; never build.
- Ambiguous/unhealthy: a context exists but the probe fails in a way that is not clearly absence or startup (auth, authorization, scheduler, network, or query error), or the active application id does not match the expected one. Stop safely with a concrete diagnostic. Do not stop an unknown application and do not launch another context.

## Templates

The two copy-ready templates are safe to paste into persistent MagiBook Cells: no credentials, user identifiers, Book IDs, task IDs, dates, or table names, only clear placeholders.
Both return and print a bounded machine-readable status carrying the application id so a later Cell can verify session reuse.
Fill every `<...>` placeholder from the captain-preference owner before running, and keep the captain's validated defaults; the init template preserves caller-supplied configuration and never silently rewrites it.

- Init: [`templates/ensure_spark.py`](templates/ensure_spark.py) is the idempotent liveness check plus single initialization.
- Query: [`templates/query_cell.py`](templates/query_cell.py) obtains the ensured session, re-verifies it is live, and runs business logic through `spark.sql`.

## Evidence

The validated CLI/API path is recorded in the private report at `data/validate-magibook-pyspark-sql/report.md` (SG, `magibook` 0.3.22).
Cell `1129483` (the validated SG `Init Pyspark` Cell) is read-only reference evidence for the init configuration shape; view it if needed, but do not modify or run it as part of routine analysis.

## Maintaining this file

Keep region defaults and cluster identifiers in the captain-preference owner, not here.
When the CLI changes, prefer `magibook --help` over pinning flags in this skill.
Change the templates through their files and let the colocated behavior test (`tests/fm-magibook-pyspark.test.sh`) keep the four-state logic honest.
