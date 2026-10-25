# fleet-stats

The per-model and per-skill fleet statistics — the readers the dashboard's
Models and Skills sections call, their shared library, and the outcome
recorder that spawn and teardown call — moved **verbatim** out of the
supervising fork into this add-on repository. Nothing reads or writes from
here yet: the live flow keeps running the fork's `bin/fm-model-stats.sh`,
`bin/fm-skill-stats.sh` and `bin/fm-task-outcome.sh`, and the fork-side hook
that will exec into this directory lands in a later PR. Until that swap this
directory is dormant, and every moved byte below is identical to the fork
copy the live flow runs today, except the lock-library line of
`bin/fm-task-outcome.sh` (see Layout).

## Layout

- `bin/fm-model-stats.sh` — per-model fleet statistics for the dashboard's
  Models view. Read-only: it writes nothing and never touches an endpoint.
  It reads this home, then every locally registered home, from
  `data/metrics/task-outcomes.tsv` (authoritative), the older sampled
  `data/metrics/lanes.tsv` (only for tasks the outcomes file predates, marked
  sampled), and `data/metrics/prs.tsv` (time-to-merge, first-pass, rework,
  revert and escape counts). It imports `fm_stats_lib` from its own
  directory, so the moved copy only runs with the library beside it (see the
  proof below).
- `bin/fm-skill-stats.sh` — per-skill fleet statistics for the dashboard's
  Skills view. Read-only. It reads `data/metrics/skills.tsv` (absent file
  reports no rows rather than failing) and enumerates each local home's
  skill directories to name skills that were never read. It imports
  `fm_stats_lib` from its own directory like the model reader.
- `bin/fm_stats_lib.py` — the readers' shared library: usage and argument
  parsing, tab-separated file reading, and enumerating this home plus every
  locally registered home. Only the two readers import it; all aggregation
  and output stays in the importing reader.
- `bin/fm-task-outcome.sh` — appends one durable task-outcome line to
  `<home>/data/metrics/task-outcomes.tsv` per task end. Called best-effort
  by `bin/fm-teardown.sh` before the task's status and record are retired; a
  write failure never blocks or fails teardown, and the script itself only
  ever exits non-zero on a usage error, or with exit 2 when it cannot find its
  lock library. It sources `fm-wake-lib.sh` from the Firstmate checkout for the
  file lock: `FM_BIN` when set, else `$FM_HOME/bin`. The library is not copied
  into this add-on; a missing file prints one error naming the path and exits 2.

## Frozen contract (identical to the fork)

- Readers: `FM_HOME=<home> fm-model-stats.sh --json [--now <unix-seconds>]`
  and the same shape for `fm-skill-stats.sh`. Any other flags, a missing
  `--json`, or a non-numeric `--now` exits 2 with usage on stderr.
- Model output schema `fm-model-stats.v1` with keys `at`, `now`,
  `windows [7, 30]`, `models[w]` (one entry per model over the window,
  largest finished first, each with `model`, `name`, `family`, `provider`
  plus `w7`/`w30` stat blocks), `coverage` (`outcome_rows`,
  `sampled_tasks`, `outcome_homes`, `prs_rows`, `lanes_rows`), and
  `limitations`. A task is attributed to the model it ended on; a task whose
  history names more than one model also counts as a switch. Merge rate is
  merged ship tasks over finished ship tasks with a recorded terminal
  outcome; sampled rows never fabricate a verdict.
- Skill output schema `fm-skill-stats.v1` with keys `at`, `now`,
  `windows [7, 30]`, `skills[w]` (read counts per skill, most-read first,
  each with the number of homes it was read in), `by_home[w]`, `zero_read_w7`
  and `zero_read_w30` (only for windows the coverage spans and while no
  remote home is registered), `coverage` (`rows`, `days`, `skills`, `homes`,
  `first_day`, `last_day`), and `limitations`.
- Library location: each reader puts the directory it lives in first on the
  import path and imports `fm_stats_lib` from there; the library must sit
  next to the reader, never elsewhere.
- Outcome record: one tab-separated row per ended task in
  `data/metrics/task-outcomes.tsv` under the header
  `home\ttask\tkind\tproject\tmodels\tstarted\tended\toutcome\tpr`,
  where `models` is every `harness:model:effort` the task ran on in launch
  order joined by `;`, and `outcome` is one of `merged | closed | cancelled |
  scout | failed`. Writes are idempotent per `(home, task, started)` and
  serialized under `<file>.lock`.

## Provenance: byte-identical to the fork

Every moved file was compared byte for byte against its fork source at
`umeranjum17/firstmate@0689b4b9d9ab3594f846cfe07c400edfa58244bf` at move time,
keeping file modes (`100755` for the scripts, `100644` for the library, on
both sides). The one deliberate exception is `fleet-stats/bin/fm-task-outcome.sh`:
its lock-library source now resolves to `FM_BIN` or `$FM_HOME/bin` instead of a
sibling file, so its hash below no longer matches the fork and is the moved
copy's pre-change value:

| moved file | fork source | sha256 |
|---|---|---|
| `fleet-stats/bin/fm-model-stats.sh` | `bin/fm-model-stats.sh` | `630cb8b55546174013197ccb5899dfc31394880a8c05ecf52e3cd6fa3dc17390` |
| `fleet-stats/bin/fm-skill-stats.sh` | `bin/fm-skill-stats.sh` | `11094335fe16c0109bdd4134171e6e5494d35bd85c5c6bda846b9efd26bb5e76` |
| `fleet-stats/bin/fm_stats_lib.py` | `bin/fm_stats_lib.py` | `0526ca27cdc2982ee6149aee24d866c8c3c4786d05eeb80c013895d076eeba8b` |
| `fleet-stats/bin/fm-task-outcome.sh` | `bin/fm-task-outcome.sh` | `73e54f05ae45c46bbf92202716205aee044e04a5601f0528977b9707c4a53b14` |

Treat any future diff against the fork file as a contract change, not a
refactor.

## Side-by-side proof (re-run before the hook swaps the dispatched path)

1. Unpack the fork tree at the commit above into two scratch roots:
   `git -C <fork> archive 0689b4b9d9ab3594f846cfe07c400edfa58244bf | tar -x -C <rootA>`,
   then `cp -a <rootA>/. <rootB>/`.
2. In `rootB` only, overwrite `bin/fm-model-stats.sh`,
   `bin/fm-skill-stats.sh`, `bin/fm_stats_lib.py` and
   `bin/fm-task-outcome.sh` with the moved files; `diff -r <rootA> <rootB>`
   must be empty, and the sha256 and mode of each file must match the table
   above.
3. Run `tests/fm-flow.test.sh` in the fork scratch tree (it covers the stats
   readers and outcome recording; `fm-spawn.sh`, `fm-teardown.sh` and the
   dashboard stay in the fork and are NOT moved); one PASS proves the
   identical bytes.
4. Run the repo CI gate (shellcheck plus syntax check over every add-on
   script) on the PR head. `bin/fm-task-outcome.sh` sources the lock library
   through a variable path with `# shellcheck source=/dev/null`, so it needs no
   `SC1091` exemption; the gate's `fleet-stats/bin/` exemption stays for the
   other moved readers.
