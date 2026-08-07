# Workspace busy check (advisory)

`bin/fm-workspace-busy.sh` is a cheap, read-only probe that tells a reader whether a git work tree looks mid-work right now.
Its job is to help a second mate (or any other agent) stand down instead of reading a half-written corporate record and reporting confident nonsense.

The script header owns exact flags, exit codes, and check order.
This page owns how to use the check and what it is not.

## What it is not

This is **advisory**.
It is not a lock, a mutex, a lease, or exclusive access.

On a typical Mac every agent runs as the same OS user, so nothing in this tool can prevent another process from writing.
A quiet result means "no cheap signal of current activity," not "you alone own this tree."
A busy result means "something looks mid-work; do not trust a full read yet," not "the other writer is malicious or blocked."

Do not build a locking protocol on top of this script.
Do not add a daemon, a marker file, or a charter change that pretends this is exclusion.

## Contract

| Situation | stdout | exit |
| --- | --- | --- |
| Looks quiet | empty | 0 |
| Looks busy | one short reason line | 1 |
| Missing path, not a directory, or not a git work tree | error on stderr | 2 |

Callers branch on exit status.
Print nothing when quiet so the tool is safe in `if bin/fm-workspace-busy.sh "$dir"; then ...`.

A path that starts with a dash is passed after `--`: `bin/fm-workspace-busy.sh --window 60 -- "$dir"`.

One busy reason is not about the other agent at all: `could not read git state (...)` means a check itself could not run (git exited non-zero, the mtime scan failed).
Uncertainty is reported as busy rather than quiet, because a check that could not run is not evidence that nothing is happening.
A caller that retries on busy should therefore cap its retries: a genuinely broken repository stays busy forever, and that reason line is the signal to escalate instead of spinning.

## What it checks

In order, first match wins:

1. **Git operation in progress** - presence of `index.lock`, `MERGE_HEAD`, `REBASE_HEAD`, and related multi-step markers (resolved via `git rev-parse --git-path`, so linked worktrees are correct).
2. **Uncommitted changes** - any `git status --porcelain` line (tracked or untracked).
3. **Recent non-ignored file mtime** - any tracked or non-ignored untracked file whose mtime falls inside `--window` seconds (default 180, overridable with `FM_WORKSPACE_BUSY_WINDOW_SECS`).
4. **Optional live process cwd** - only with `--process`, via one bounded `lsof -a -d cwd` scan (never a recursive tree walk). Off by default so a reader whose own shell sits in the tree is not counted as foreign activity. When `lsof` is missing, the process scan is skipped rather than half-implemented.

Ignored paths never contribute a busy reason: porcelain and `git ls-files --exclude-standard` both skip them, so a cache write under an ignored directory does not look like activity.

Checks 1 to 3 answer for the **whole work tree**, not only for the directory you pass.
`git status` and the git operation markers are repo-wide by nature, and the mtime scan is listed from the work-tree root so it agrees with them.
Passing a subdirectory therefore narrows nothing; it only names which tree to ask about, and the path in `recent write: <path>` is relative to the work-tree root.

The script **writes nothing**, anywhere, ever: no lock file, no state, no marker under the target tree or elsewhere.

## How a second mate should use it

A second mate whose job is to **verify** that a corporate record is true and current, while another agent may **edit** the same repository in a different copy of the tree, should treat this check as a pre-read gate:

```sh
if reason=$(bin/fm-workspace-busy.sh /path/to/record-repo 2>&1); then
  # quiet: safe to read and verify
  verify_record /path/to/record-repo
else
  status=$?
  if [ "$status" -eq 1 ]; then
    case "$reason" in
      'could not read git state'*)
        # a check could not run: not a peaceful wait, escalate
        echo "blocked: workspace-busy check could not answer: $reason" >&2
        exit 1
        ;;
    esac
    # busy: stand down. This is a correct, useful result - not a failure.
    echo "paused: someone is working here ($reason)"
    exit 0
  fi
  # usage error (missing path / not a git repo): real problem
  echo "blocked: workspace-busy check failed: $reason" >&2
  exit 1
fi
```

Standing down with "someone is working here" is a **successful** verification outcome for that turn.
It is better than a false confident verdict on a momentarily inconsistent tree.
Retry later on a normal cadence, or surface the busy reason to the parent as a deliberate wait, depending on the charter.

Recommended habits:

- Call the check **immediately before** the read that would produce a verdict, not once at session start.
- Prefer the default (no `--process`) unless you know writers keep their cwd inside the tree and your own shell does not.
- Keep the window short (a few minutes). After a clean commit, file mtimes can still look "recent" for that window; that bias is intentional and temporary.
- Never invent a side channel (touch a `BUSY` file, take a flock) from this advisory signal.

## Performance

The check is meant to run before every read on trees that may hold hundreds of megabytes.

It does **not** walk the whole filesystem tree for ignored bulk.
Dirty and lock checks use git's index.
The mtime scan iterates only paths from:

```text
git ls-files --cached --others --exclude-standard
```

so cost scales with tracked plus non-ignored untracked files, not with `node_modules` or other ignored caches.

### Measured cost (2026-08-07, macOS)

Commands run from a disposable firstmate worktree on this machine.
Times are wall-clock from `/usr/bin/time -p` (real seconds); each figure is the median of seven runs after a warm cache.
The mtime scan uses one `python3` process over the git path list when available (a per-file `stat` fork is deliberately avoided).

These figures were re-measured after the scan moved to listing from the work-tree root.
Other agents were active on the machine during the run, so read every number as an upper bound rather than a floor.

| Target | Signal | real (s) |
| --- | --- | --- |
| Small quiet fixture (1 tracked file, aged mtime) | quiet | 0.17 |
| Same small tree with a dirty file | busy: uncommitted changes | 0.18 |
| Same small tree with a fresh `touch` on a tracked file (clean porcelain) | busy: recent write | 0.22 |
| This firstmate worktree (~370 tracked files; dirty during measurement) | busy: uncommitted changes | 0.21 |
| Synthetic tree: 5_000 tracked files, quiet, aged mtimes | quiet | 0.43 |
| Synthetic tree: 5_000 tracked files plus ignored `cache/` with 2_000 hot files | quiet (ignored) | 0.28 |
| Synthetic tree: 5_000 tracked files with one dirty file | busy: uncommitted changes | 0.24 |

The quiet 5_000-file case is the worst one, because quiet is the only verdict that has to stat every candidate path.
Both the current and the previous spelling of the scan were measured on the same fixtures in the same run, and neither showed a material cost difference.

Re-measure after material changes to the scan:

```sh
/usr/bin/time -p bin/fm-workspace-busy.sh /path/to/tree --window 180
```

If a future tree is large enough that the mtime scan dominates, keep fixing the scan; do not replace this tool with a daemon or a write-side lock.

## Related

- Script header and `--help`: `bin/fm-workspace-busy.sh`
- Toolbelt index: [scripts.md](scripts.md)
- Behavior tests: `tests/fm-workspace-busy.test.sh`
- Semantic **agent** busy-state (turn lifecycle for crewmates) is a different contract: `bin/fm-busy-lib.sh`. Do not confuse the two.
