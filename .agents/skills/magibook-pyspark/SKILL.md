---
name: magibook-pyspark
description: >-
  Agent-only procedure for running data analysis on MagiBook with PySpark through the official magibook CLI.
  Use before creating, reusing, checking, initializing, waiting on, or running a MagiBook PySpark/Spark SQL analysis, and before writing an init Cell or orchestrating query Cells.
  Owns the inspect-ensure-wait-query lifecycle, the four-state Spark liveness model, single-initialization safety, the copy-ready init Cell template, and bounded query fan-out; it does not own region defaults or cluster identifiers, which come from the captain-preference owner.
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
   Once ensured live, run business logic from ordinary Python Cells through `spark.sql("""SELECT ...""")` on the ensured session.
   Hive queries do not need a separate query template.
   Do not use Dorado, TQS, or any direct SQL submission path for query work here.
5. Persist and reuse (optional).
   When multiple actions read the same filtered or joined base, materialize it once with a purposeful `persist(StorageLevel.MEMORY_AND_DISK)`, reuse that cached DataFrame across the rounds, and `unpersist()` it promptly when the analysis no longer needs it.
6. Reconcile terminal output.
   Read each submitted Cell's output (`magibook --region <region> cell view <cell_id> --output`) and reconcile the exact task status.
   Confirm the query Cell's reported application id matches the ensured session's, proving session reuse.

## Bounded parallel query execution

Reduce the number of separate queries before adding concurrency.
Combine compatible metrics over the same scan with shared CTEs, conditional aggregation, or one persisted base DataFrame when doing so preserves semantics.
Parallelism is optional and is only safe for genuinely independent reads or aggregations.
Keep queries sequential when they depend on ordering, shared mutable temp views, cache creation or eviction, or conflicting writes.
Concurrent jobs share the same Spark and YARN resources, may contend with each other, and are not automatically faster.
Do not claim a speedup without comparative timing evidence.

Keep Spark initialization single-flight and terminally reconciled before calling the parallel helper.
The helper never initializes Spark, creates a SparkContext, or cancels remote work.
Give every query a stable distinct key and a distinct pre-existing persistent Python Cell.
Keep the protected registry path across retries because it binds each query key and content digest to its exact Cell and returned task id.
The helper holds a non-blocking process lock beside that registry so two local orchestrators cannot submit from the same ownership record at once.
If a prior submission is still pending or running, the helper polls that exact task instead of submitting another copy.
If a submission may have reached MagiBook but returned no task id, ownership is ambiguous and the helper refuses to retry it automatically.

Set `max_parallel` to the highest concurrency authorized for the queue.
For each parallel batch, the helper starts one distinct `magibook cell run` child process per Cell up to `max_parallel` before it waits for any submission child to finish.
The helper uses argv arrays with `shell=False`, records each returned task id against its exact query and Cell, and polls every task independently.
It falls back to sequential submission for remaining Cells only after observed task states show that the shared Book, kernel, or queue is serializing work.
An overlap rejection or ambiguous task state stops further submission and returns a clear capability result.
The aggregate always retains individual success, failure, cancellation, timeout, and interruption outcomes, and any partial failure makes the overall result non-success.
On failure or interruption the helper does not kill unrelated Spark work, and `remoteWorkRemaining` identifies every exact task that was not proven terminal.

The CLI adapter launches argv arrays with `shell=False`, clears conventional proxy variables only in each child, and caps stdout and stderr retained from every process.
Query source reaches `cell edit` only through mode-`0600` temporary files in a mode-`0700` temporary directory, and that directory is removed on every exit path.
Pass known secrets through `sensitive_values` so CLI diagnostics are redacted, while query results remain in the persistent Cell output rather than entering the aggregate summary.
The rendered Python Cell uses `spark.sql("""...""")`, bounds displayed rows, and prints the application id used for terminal reuse verification.

Copy [`templates/parallel_queries.py`](templates/parallel_queries.py) beside the run driver and use its public interface with values from the captain-preference owner:

```python
import json
from pathlib import Path

from parallel_queries import MagiBookCLI, QuerySpec, run_parallel_queries


queries = [
    QuerySpec(
        key="<STABLE_QUERY_KEY_1>",
        cell_id="<PERSISTENT_QUERY_CELL_ID_1>",
        sql="SELECT 1 AS metric",
    ),
    QuerySpec(
        key="<STABLE_QUERY_KEY_2>",
        cell_id="<PERSISTENT_QUERY_CELL_ID_2>",
        sql="SELECT 2 AS metric",
    ),
]
max_parallel = 2

aggregate = run_parallel_queries(
    queries,
    initialization=<TERMINAL_LIVE_INIT_RESULT>,
    cli=MagiBookCLI(
        "<EXPLICIT_REGION>",
        sensitive_values=("<SENSITIVE_VALUE_IF_ANY>",),
    ),
    book_uuid="<BOOK_UUID>",
    state_path=Path("<PRIVATE_PERSISTENT_QUERY_STATE_FILE>"),
    # One distinct cell-run child starts per query up to this explicit bound.
    max_parallel=max_parallel,
    query_timeout=float("<QUERY_TIMEOUT_SECONDS>"),
    overall_timeout=float("<OVERALL_TIMEOUT_SECONDS>"),
)

print(json.dumps(aggregate, ensure_ascii=False, sort_keys=True))
```

Use a new stable query key when the intended SQL changes or when an explicitly authorized rerun should create a new remote task.
Keep the same key and registry for process retries and observation retries.

## Four-state Spark model

Liveness is proven by a minimal Spark action, never by the presence of `SparkContext._active_spark_context` alone.
A probe failure is classified, not swallowed: authentication, authorization, scheduler, network, and query failures stay distinguishable from genuine absence.

- Absent/stopped: no active context, or the context object reports stopped. Safe to initialize exactly once.
- Live: a context exists and a minimal Spark action succeeds. Reuse it; never build.
- Initializing: a context exists but its application id is not yet assigned, or the probe shows it is still starting. Poll the init task; never build.
- Ambiguous/unhealthy: a context exists but the probe fails in a way that is not clearly absence or startup (auth, authorization, scheduler, network, or query error), or the active application id does not match the expected one. Stop safely with a concrete diagnostic. Do not stop an unknown application and do not launch another context.

## Templates

The copy-ready init template is safe to paste into a persistent MagiBook Cell: no credentials, user identifiers, Book IDs, task IDs, dates, or table names, only clear placeholders.
It returns and prints a bounded machine-readable status carrying the application id so later Cells can verify session reuse.
Fill every `<...>` placeholder from the captain-preference owner before running, and keep the captain's validated defaults; the init template preserves caller-supplied configuration and never silently rewrites it.

- Init: [`templates/ensure_spark.py`](templates/ensure_spark.py) is the idempotent liveness check plus single initialization.
- Parallel queries: [`templates/parallel_queries.py`](templates/parallel_queries.py) is the bounded subprocess runner plus persistent exact-task reconciliation.

## Evidence

The validated CLI/API path and the validated init Cell (read-only reference for the init configuration shape) are recorded by the captain-preference owner (`data/captain.md`, or `data/captain-shared.md` for a secondmate home), not in this shared skill.
View the recorded init Cell read-only if needed, but do not modify or run it as part of routine analysis.

## Maintaining this file

Keep region defaults and cluster identifiers in the captain-preference owner, not here.
When the CLI changes, prefer `magibook --help` over pinning flags in this skill.
Change the templates through their files and let the colocated behavior test (`tests/fm-magibook-pyspark.test.sh`) keep the four-state and parallel orchestration logic honest.
