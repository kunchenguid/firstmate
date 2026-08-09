# Shadow replica

bin/fm-shadow.sh publishes the complete canonical Linux Firstmate tree to a Windows-visible WSL destination in one direction.

The default source is /home/ale/firstmate.

The default destination is /mnt/d/Workspace/shadow, which is the WSL spelling of D:\Workspace\shadow.

The destination is an output surface for Windows inspection and is not part of the agent workflow.

The separate bin/fm-replicante.sh backup keeps historical recovery snapshots on H:\Firstmate-Backup and never changes this visual mirror's contract.

Manual destination edits are preserved on disk but make the next replication stop safely.

## Operation

Run the mirror from WSL with bin/fm-shadow.sh.

Override either path for a controlled fixture or another installation with bin/fm-shadow.sh --source <source> --destination <destination>.

The destination parent must already exist.

The first run accepts a missing destination or an empty directory.

The command creates an atomic lock at the destination parent's .shadow.lock.

The command also creates a source-side lock at the source parent's .shadow-source-lock.<source-name>.

The two locks are atomic run markers that a normal exit releases, and the source-side lock coordinates shadow executions while the source snapshot is the sealed source tree for that run.

An existing lock is treated as active and is never removed automatically.

The source must be the root of a Git worktree on the default branch with a clean tracked and untracked tree.

An existing destination must be the root of a Git worktree on the same default branch with a valid prior manifest and no local changes.

The destination commit must be an ancestor of the source commit in the source repository.

The final destination commit must have exactly the same identity as the source commit.

Git's ownership trust is granted only per invocation for the exact absolute source, stage, or destination path.

The destination status check also disables Git filemode comparison only for that invocation because 9p can normalize modes; the manifest still detects content, type, size, and hash changes.

Each run captures a complete source snapshot, stages the output beside the destination from that snapshot, validates its content, and swaps it into place only after the source is rechecked.

The source is checked again at the transaction boundary, and the installed output is compared with the sealed snapshot before the transaction is cleared.

An interrupted run's source snapshot is removed by the next invocation after both locks are acquired.

The staging copier uses 9p-compatible content and symbolic-link operations and does not request POSIX metadata updates from the destination filesystem.

An unchanged source and unchanged complete tree returns already current without replacing the destination.

## Scheduling

Create one Windows Task Scheduler action for the WSL command, such as wsl.exe -d Ubuntu -- /home/ale/firstmate/bin/fm-shadow.sh.

Run the task in the WSL distribution where /home/ale/firstmate is the canonical source.

Schedule shadow separately from replicante; the commands have different destinations and independent locks.

## Mirrored contents

Every path rooted under /home/ale/firstmate is mirrored, including ignored files, project clones, operational directories, Git metadata, empty directories, regular files, and symbolic links.

The generated manifest and policy live in the destination parent's .shadow-control.<destination-name> sidecar directory.

Keeping controls outside the destination preserves source paths named .shadow-manifest or .shadow-policy exactly.

The manifest records every mirrored path, its type, and the SHA-256 hash of every regular file.

The policy records the one-way output boundary and the source identity.

The copier never follows a symbolic link target, so content outside the source root is not traversed.

An external /mnt/d/RocoData source or destination is protected and is refused.

RocoData under the source root is mirrored because the captain's current scope is the complete source tree.

## Refusal and recovery

The command refuses a dirty source, a dirty destination, a detached or wrong branch, a divergent destination commit, a malformed manifest, an unavailable path, an unsupported special file, or a concurrent lock.

It never uses a forced Git operation, a stash, a hard reset, a partial destination copy, or a deletion of destination changes.

If staging or the final atomic installation fails, an existing validated destination remains the recovery point.

Inspect the owner file in a stale .shadow.lock or .shadow-source-lock.<source-name> only after verifying that no fm-shadow.sh process is running.

Remove only the exact stale .shadow.lock or .shadow-source-lock.<source-name> directory after confirming that its recorded process is no longer active.

## Tests

The fixture suite covers first publication, repeated idempotent publication, complete working-tree content, destination dirtiness, destination divergence, concurrent locking, external symlink-target protection, and recovery from an unsupported source entry.

The fixture suite uses temporary source and destination paths and never accesses the live Firstmate home or Windows destination.

Run the focused suite with bash tests/fm-shadow.test.sh.

Run shell lint with bin/fm-lint.sh.

Run documentation structure checks with bin/fm-doc-audience-check.sh.
