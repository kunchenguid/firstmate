# Crewmate memory bound verification

Audience: maintainer verification.

This record supports the active guarantees for `config/crew-memory-bound`: that the bound covers a crewmate's whole pane process tree, that the kernel enforces the configured limits, and that exceeding the bound kills the offending build rather than the host.
[`docs/configuration.md`](../configuration.md) owns the current operator-facing setting.
`bin/fm-crew-memory-bound.sh`'s header owns the exit-code contract and scope mechanics.

Measured 2026-07-31 on Linux 6.18.33.2-microsoft-standard-WSL2, systemd 249 (249.11-0ubuntu3.12), cgroup v2 unified hierarchy, `memory` delegated to `user@1000.service`.

## Why a per-command wrapper is insufficient

A crewmate pane is a plain shell that the harness launch line is typed into, and the crewmate composes its own build commands inside that harness.
Any bound attached to one named command is escaped by the next command the crewmate types, so the bound has to attach to the launched harness and be inherited by every descendant.
This is not hypothetical: an unbounded crew pane reports the root cgroup for itself, and so does every compiler it starts.

```
$ cat /proc/self/cgroup          # inside an unbounded crew pane
0::/
```

A cgroup that exists but holds the wrong processes reads as protection while providing none, which is why the checks below assert on the cgroup a live descendant reports for itself rather than on the cgroup having been created.

## Whole-tree membership

The launch line produced by `bin/fm-crew-memory-bound.sh wrap`, typed into a crew pane, places the launched process and its descendants in the crew scope:

```
$ cat /proc/self/cgroup          # launched process
0::/user.slice/user-1000.slice/user@1000.service/app.slice/fm-crew-fm-evidence-1785522204.scope
$ cat /proc/self/cgroup          # its child
0::/user.slice/user-1000.slice/user@1000.service/app.slice/fm-crew-fm-evidence-1785522204.scope
```

`tests/fm-crew-memory-bound.test.sh` asserts the same property to grandchild depth and fails on any descendant reporting `0::/`.
Removing the wrapping from `cmd_wrap` makes that test fail with three `0::/` reports, so the regression detects the exact defect it exists for.

## Kernel-reported limits

Read back from the live cgroup of a scope configured as `512M 384M`, rather than from the flags passed in:

```
$ cat /sys/fs/cgroup$p/memory.max /sys/fs/cgroup$p/memory.high /sys/fs/cgroup$p/memory.swap.max
536870912
402653184
0
```

`memory.swap.max` is `0` by construction: `MemoryMax` alone bounds resident memory, so a runaway build left with swap would page the host into thrashing instead of dying.
The spawn-time preflight reads back these same three files rather than `memory.max` alone, because systemd starts a scope even when one of its property writes does not reach the kernel: a host with the memory controller delegated but swap accounting unavailable would otherwise come up with `memory.max` enforced, swap unbounded, and the mechanism reporting `enforced=proven`.

## Exceeding the bound

A process allocating past a `128M` bound is killed, and the kill is attributed to the crew cgroup rather than to a global out-of-memory condition:

```
$ free -m                        # before
Mem:           15989        5516        2466           1        8006       10227
$ <bounded launch line running an allocator>
Killed
exit=137
$ free -m                        # after
Mem:           15989        5574        2407           1        8007       10169
$ dmesg | tail
oom-kill:constraint=CONSTRAINT_MEMCG,...,oom_memcg=/user.slice/user-1000.slice/user@1000.service/app.slice/fm-crew-fm-kill-1785522215.scope,task_memcg=/.../fm-crew-fm-kill-1785522215.scope,task=bash,pid=24595,uid=1000
Memory cgroup out of memory: Killed process 24595 (bash) total-vm:135860kB, anon-rss:130720kB, file-rss:3012kB, shmem-rss:0kB, UID:1000
```

`constraint=CONSTRAINT_MEMCG` with `oom_memcg` naming the crew scope is the load-bearing line: the kill came from the bound, not from host exhaustion.
Host free memory is unchanged across the kill, and `memory.oom.group` is left at its default so the kernel kills the single largest member - the runaway build - and leaves the harness alive to report it.

## Interactive behavior inside the bound

The bound must not change how a harness runs.
Under the wrapped launch line in a real pane, the shell keeps its controlling terminal and job control while reporting the crew scope:

```
$ echo TTY=$(tty) INTERACTIVE=$-; cat /proc/self/cgroup
TTY=/dev/pts/11 INTERACTIVE=himBHs
0::/user.slice/user-1000.slice/user@1000.service/app.slice/fm-crew-fm-tty-1785522856.scope
$ sleep 100 &
$ jobs
[1]+  Running                 sleep 100 &
```

## Boundary

The pane's own login shell is deliberately left outside the scope: replacing it would make the window die with the harness and destroy the distinction recovery depends on between a dead pane and a live pane whose agent exited.
The harness and every process it forks are inside, so every command a crewmate composes during its work is bounded.
A command typed directly into the pane shell after the harness has exited is not, and relaunching a harness there goes back through `bin/fm-spawn.sh` and is bounded again.

The bounded launch line ends in `<shell> -c <launch>`, and that shell replaces itself with the harness only for a single simple command; for a pipeline, list, redirection, or subshell it forks and stays the pane's foreground process-group leader, which `fm_backend_tmux_agent_state` reads as `dead` while the crewmate is still working.
A leading shell keyword does the same while carrying none of those characters, measured under the bound: `sleep 90` reports `sleep` as the pane command, while `time sleep 90` and `! sleep 90` both report `bash` and `coproc sleep 90` detaches the process outright.
Every built-in launch template is a simple command, so the constraint binds only the raw-launch escape hatch, and a raw launch that would land in that state is refused before any window, worktree, or metadata exists rather than spawned.

The bound applies to crewmates only, never to a secondmate agent itself: a secondmate is a persistent idle-by-default supervisor that compiles nothing, and killing its harness at a ceiling sized for build lanes would take down a whole home rather than one task.
`config/crew-memory-bound` is inherited into secondmate homes, so that home's own crewmates are bound when they spawn.

## Lifetime

The scope is transient and `--collect`ed, so it disappears with the harness and cleanup needs no teardown step:

```
$ systemctl --user is-active fm-crew-fm-gc2-1785523051.scope   # harness running
active
$ systemctl --user is-active fm-crew-fm-gc2-1785523051.scope   # after its processes are killed
inactive
```

The cgroup directory is removed with the unit, so repeated spawns do not accumulate scopes.

## Fail-closed behavior

`bin/fm-spawn.sh` proves enforcement before any window, worktree, or task metadata exists, and refuses the spawn when a configured bound cannot be established.
`tests/fm-crew-memory-bound.test.sh` covers five distinct ways the mechanism can be unavailable - no `systemd-run` on `PATH`, a `systemd-run` that cannot create the scope, one that reports success while leaving processes in the root cgroup, and one whose swap denial or configured `MemoryHigh` never reached the kernel - and requires a refusal in each.
It also requires a refusal for a raw launch command whose shape would leave the pane reporting a shell instead of the harness.
An absent `config/crew-memory-bound` leaves spawning unchanged, so a host with no systemd user manager is unaffected until it opts in.
