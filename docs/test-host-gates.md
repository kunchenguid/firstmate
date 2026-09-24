# Test-host heavy-operation coordination

A test host runs one heavy operation at a time, regardless of the project or task using it.

Heavy operations include full validation gates, k3d resets and baselines, and image builds.

Use `bin/fm-gate-lock.sh run --host <host> --holder <task-id> -- <command...>` for each such operation, and use `status` to inspect the advisory holder record rather than probing processes.

The default resource name is `heavy`, which serializes the whole host; use a distinct name only for a genuinely independent resource.

Devbox is for authoring and fast checks; Omarchy is the host for the heavy validation gate and the shared k3d acceptance cluster, whose only writer is the operation holding the lock.

A kernel-backed `flock` releases the lock when its holder exits, including after a crash or kill.

The helper's header and `--help`-style usage own its exact interface and defaults.
