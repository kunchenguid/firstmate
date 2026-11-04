# The unattended merge queue

A pull request that is green, QA-passed, and merge-ready still waits for a firstmate turn in most homes: the merge queue is a file, and its batch is run by hand.
`bin/fm-merge-queue.sh` is that batch on a timer.
A systemd user timer runs it every ten minutes, and a queued pull request lands without anyone being woken.

This page owns the operator's view: the queue file, the decision the timer makes, the records it writes, and the one line a day it reports.
The script's own header and `--help` own the exact flags, environment variables, and the conditional detail behind each verdict, and `bin/fm-pr-merge.sh` owns what a merge actually does.

## Enable it in one home

The queue is opt-in per home and off until its file exists.

```sh
# 1. write the queue: one row per pull request
mkdir -p data
cat > data/go-queue.txt <<'EOF'
# owner: <github-login>
widgets 1580 e672a82e encore-t1 squash
EOF

# 2. check the decisions it would make, then install the timer
bin/fm-merge-queue.sh run --dry-run
mkdir -p ~/.config/systemd/user
bin/fm-merge-queue.sh unit service > ~/.config/systemd/user/fm-merge-queue.service
bin/fm-merge-queue.sh unit timer   > ~/.config/systemd/user/fm-merge-queue.timer
systemctl --user daemon-reload
systemctl --user enable --now fm-merge-queue.timer
```

The generated service puts `%h/.local/bin` on the timer's `PATH`, because a systemd user manager's own `PATH` does not include the tools firstmate installs there.
A run refuses at startup, with the tool named and the `PATH` it saw, when `gh` or `gh-axi` is not resolvable rather than reporting every row as an unanswered forge, so a tool installed elsewhere needs its own directory added to the unit's `Environment=PATH`.

`bin/fm-merge-queue.sh status` prints the queue size and the most recent run from the timer's own records, with no network call.
`systemctl --user list-timers fm-merge-queue.timer` says whether the timer is armed.
To stop it, `systemctl --user disable --now fm-merge-queue.timer`; the queue file keeps its rows, so re-enabling resumes the same work.

## The queue file

One row per pull request, whitespace separated:

```
<repo> <number> <expected-head> <task-id> <squash|merge|rebase>
```

- `<repo>` is `owner/repo`, or a bare repository name that uses the owner from a `# owner: <login>` directive in the same file, or `FM_MERGE_QUEUE_OWNER`.
- `<number>` is the pull request number.
- `<expected-head>` is the head commit the row was written against, at least seven hex characters.
- `<task-id>` is the firstmate task the merge is recorded against, which keeps the merge metadata and the landed-work check working.
- `<method>` is the merge method handed to the forge.

A row is identified by its owner, repository, number, and expected head, so `acme/widgets 12` and `beta/widgets 12` are two independent rows and so are two heads of one pull request.
When one pull request appears twice, the newest row supersedes the older-head row: the superseded row is recorded in the ledger and the daily detail file with its own verdict rather than dropped, and the newest row is the one that decides.
A head that has moved retires the row rather than merging a commit nobody queued, so re-queue after a push.
Comments and blank lines are preserved exactly as written, and an exact duplicate of one row is attempted once.
A queue file edited while a tick is running is never overwritten: the run leaves its rewrite for the next tick and says so.

## What merges, and what never does

Every row is read live on every tick; nothing in the queue file is trusted as current.
A row merges only when the pull request proves it is ready: open, not a draft, at the head the row named, every check green, and a `qa-review` check passing on that exact head.
That QA requirement has no configuration switch, so no home can turn it off.
Two `qa-review` checks may exist; a failing instance holds the row.

Four things keep a change away from an unattended timer and with a decider instead: a fence label naming money, credentials, a vendor console, customer copy, or irreversible work; a title or body that mentions production DDL; a draft; and a red head.
None of those rows merges, and a fenced one leaves the queue with its reason.

The one exempted check is `credit-approval-guard`, which is red by design on a credit-impact change because the credit review itself is the gate.
A failing instance of that check is the waiver, and a guard that has not finished holds the row.
A merge that relied on that exemption says `credit-guard waived` on its own line, in the ledger, in the daily detail file, and in the daily count, so the waiver is never silent.

A row leaves the queue only on a terminal verdict: merged, already merged, closed, fenced, a moved head, superseded by a newer row for the same pull request, or `FM_MERGE_QUEUE_MAX_ATTEMPTS` consecutive refused merge attempts (default 6), which retires it as abandoned.
A row that is merely not ready stays queued and is retried on the next tick.
So does a row this home cannot read at all, such as one with no repository owner, an unknown merge method, or a task id that names no task in this home, because a configuration mistake must never delete the queue it was given and must never spend a retry budget.

The merge itself is always `bin/fm-pr-merge.sh`, so that script's refusal rules, merge verification, metadata recording, and durable wake still apply; the timer only decides what to hand it.

## Records and the daily line

Records live under `<FM_HOME>/state/merge-queue/`:

- `ledger.tsv` - one line per verdict: `<epoch> <row> <verdict> <reason> <url>`, where a row is named by its pull request and the head it was queued at, as in `acme/widgets#12@e672a82e`, and a row with no usable head is named by its pull request alone.
- `daily-<YYYY-MM-DD>.txt` - every merged and retired row of the summary window, one per line, with its time, row, verdict, reason, and full pull request URL.
- `last-run` - the verdict counts of the most recent run, which is what `status` prints.
- `.summary` - the day of the last daily line and the epoch it covered from.
- `.lock/` - single-instance lock, so two ticks never merge at once.

The summary window starts strictly after the epoch of the previous summary, so a merge recorded in that same second is reported once rather than twice.

The first run of each UTC day appends one durable check wake giving the counts and the path of that day's detail file, which is how the queue reaches firstmate's chat as one line a day instead of a wake per merge.
No row list is truncated into the line itself, so nothing disappears off the end of a busy day.
That line also says how many rows need the queue file fixed, and how many merges relied on the credit-guard exemption.
No run pages anyone directly; every other verdict is a journal line.

## Limits

- It is a systemd user timer, so it runs inside your user session; on a machine you are not logged into, enable lingering with `loginctl enable-linger <user>` so it keeps running after logout.
- `OnBootSec=2min` restarts it shortly after a reboot.
- It merges only what the forge can already merge: no rebase, no conflict resolution, no re-review.
- A branch that falls behind is retried on each tick until its head moves, a decider intervenes, or the retry budget retires it as abandoned.
- A queued pull request the forge can no longer answer for stays queued and is retried every tick; remove such a row from the file by hand.
- A row whose task id names no task in this home stays queued as unusable, so the fix is to correct the row rather than to wait.
