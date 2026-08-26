# Windows process-probe verification

Audience: maintainer verification.

This record holds the platform evidence behind the no-lsof branch of `bin/fm-lock-lib.sh`'s staleness proof, `bin/fm-teardown.sh`'s leaked-process reaper, and the missing-procfs-entry death verdict in `bin/fm-wake-lib.sh`'s `fm_pid_alive`, which relies on the fact shown below that MSYS registers every Git Bash descendant, native or not, in its process table.
Those files own the decision procedure and the mechanics; this record owns why the Windows answers count as proof, because CI never runs there.
Re-establish it after a Git for Windows or MSYS runtime upgrade.

Verified 2026-08-11 on Windows 11 (10.0.26200) with MSYS runtime 3.6.4, `git version 2.51.0.windows.2`, and Windows PowerShell 5.1.26100.8875.

## The gap this platform starts from

```sh
$ uname -s
MINGW64_NT-10.0-26200
$ command -v lsof; echo "exit=$?"
exit=1
$ ps -o pgid= -p $$
ps: unknown option -- o
Try `ps --help' for more information.
```

There is no lsof to install around, and the `ps` MSYS ships answers no `-o` field at all.
Together those left every holder probe permanently at "maybe held" and left the process-group fallback with no group to signal.

## What the MSYS procfs answers instead

```sh
$ readlink /proc/$$/cwd
/c/Users/amato/AppData/Local/Temp/verify
$ cat /proc/$$/pgid
193309
```

`cwd` is a resolvable symlink and `pgid` is a plain file, which is what the cwd scan and `task_process_pgid` read.
The table is not limited to MSYS binaries: a native process spawned from Git Bash is registered too, with a readable path and cwd.

```sh
$ cat /proc/194430/exename
/c/WINDOWS/System32/WindowsPowerShell/v1.0/powershell
$ readlink /proc/194430/cwd
/tmp/verify
```

That is the population the scan needs, because every crew process, and every `git` firstmate runs, descends from Git Bash.
A process started entirely outside MSYS is absent from this table, which is why the scan answers only the companion-directory half of the proof and never the lock file itself.

## The lingering entry an exiting process leaves, and the kill -0 answer that resolves it

An exiting MSYS process keeps its listed `/proc` entry for a beat after its cwd stops resolving, so the cwd scan on a busy host routinely walks into that state, and counting it as a gap made the leaked-process answer randomly incomplete.
The scan therefore skips a lingering entry only when `kill -0` proves the pid already exited; `fm_lock_windows_pid_liveness` in `bin/fm-lock-lib.sh` treats only the C-locale ESRCH answer as that proof, and any other failure stays a fail-closed gap.
Verified 2026-08-25 on the same host and versions, against a child killed but not yet reaped:

```sh
$ tail -f /dev/null & pid=$!; kill "$pid"
$ [ -d "/proc/$pid" ] && echo listed; cd -P "/proc/$pid/cwd"
listed
bash: cd: /proc/473159/cwd: No such file or directory
$ LC_ALL=C kill -0 "$pid"; echo "exit=$?"
bash: kill: (473159) - No such process
exit=1
$ [ -d "/proc/$pid" ] || echo unlisted   # a beat later, after the reap
unlisted
```

A live pid answers `kill -0` with exit 0 in the same locale.
`tests/fm-lock-cwd-scan.test.sh` pins all four scan verdicts with real pids on every platform; only the lingering-entry shape above is Windows-only evidence.

## Why a FileShare.None open is a holder verdict

Windows refuses an open requesting `FileShare.None` while any other handle to the file is open, so the open succeeding is the proof that nothing holds it.
Against one file across an open and a close, with nothing else changing:

```sh
$ fm_lock_windows_file_holder "$PWD/lock"   # nothing has it open
1
$ exec 9>lock; fm_lock_windows_file_holder "$PWD/lock"
0
$ exec 9>&-; fm_lock_windows_file_holder "$PWD/lock"
1
```

The verdict covers native processes as well, which is what makes it usable against the real subject.
A live `git add` held by a slow clean filter, holding a real `index.lock`:

```sh
$ ls .git/index.lock
.git/index.lock
$ fm_lock_windows_file_holder "$PWD/.git/index.lock"
0
$ ls .git/index.lock   # after the git process exits
ls: cannot access '.git/index.lock': No such file or directory
$ fm_lock_windows_file_holder "$PWD/.git/index.lock"
1
```

`git.exe` is a MinGW binary with no MSYS process entry to read, so this is the half of the proof procfs cannot supply and the reason the two probes are split the way they are.

## What is not proven here

The cwd scan cannot see a process started outside MSYS entirely, for example a git launched by a native IDE.
The lock-file probe still catches such a process for the whole time it holds the lock, so the exposure is confined to the window between that process closing the lock and exiting.
Anything either probe cannot resolve is reported as uncertainty, never as "provably free".
