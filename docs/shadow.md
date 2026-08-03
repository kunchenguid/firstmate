# Shadow replica

bin/fm-shadow.sh publishes the complete canonical Linux Firstmate tree to a Windows-visible WSL destination in one direction.

The default source is /home/ale/firstmate.

The default destination is /mnt/d/Workspace/shadow, which is the WSL spelling of D:\Workspace\shadow.

The destination is an output surface for Windows inspection and is not part of the agent workflow.

Manual destination edits are preserved on disk but make the next replication stop safely.

## Operation

Run the replicator from WSL with bin/fm-shadow.sh.

Override either path for a controlled fixture or another installation with bin/fm-shadow.sh --source <source> --destination <destination>.

The destination parent must already exist.

The first run accepts a missing destination or an empty directory.

The command creates an atomic lock at the destination parent's .shadow.lock.

An existing lock is treated as active and is never removed automatically.

The source must be the root of a Git worktree on the default branch with a clean tracked and untracked tree.

The destination must be the root of a Git worktree on the same default branch with a valid prior manifest and no local changes.

The destination commit must be an ancestor of the source commit in the source repository.

The final destination commit must have exactly the same identity as the source commit.

Git's ownership trust is granted only per invocation for the exact absolute source, stage, or destination path.

Each run stages the complete output beside the destination, validates its content, and swaps it into place only after the source is rechecked.

The staging copier uses 9p-compatible content and symbolic-link operations and does not request POSIX metadata updates from the destination filesystem.

An unchanged source and unchanged complete tree returns already current without replacing the destination.

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

If staging or the final atomic installation fails, the previous validated destination remains the recovery point.

Investigate and clear a stale .shadow.lock only after verifying that no fm-shadow.sh process is running.

Do not repair the destination by hand and retry after an integrity refusal unless the manual change is intentionally removed through the separate operating procedure that owns the Windows output.

## Tests

The fixture suite covers first publication, repeated idempotent publication, complete working-tree content, destination dirtiness, destination divergence, concurrent locking, external-source protection, and recovery from an unsupported source entry.

Run the focused suite with bash tests/fm-shadow.test.sh.

Run shell lint with bin/fm-lint.sh.

Run documentation structure checks with bin/fm-doc-audience-check.sh.
