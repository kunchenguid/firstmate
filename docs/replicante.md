# Replicante backup

bin/fm-replicante.sh is the incremental recovery backup for the canonical Firstmate tree.

It is separate from bin/fm-shadow.sh: shadow publishes an exact visual mirror to D:\Workspace\shadow, while replicante keeps historical recovery snapshots on H:\Firstmate-Backup.

The only operational source is /home/ale/firstmate.

The only operational destination is /mnt/h/Firstmate-Backup, which is the WSL spelling of H:\Firstmate-Backup.

The worker does not accept normal source or destination overrides.

## Operation

The H: volume must be mounted at /mnt/h before every run.

Run the first complete backup with /home/ale/firstmate/bin/fm-replicante.sh run.

Set retention explicitly when the default of 30 snapshots is not appropriate, for example /home/ale/firstmate/bin/fm-replicante.sh run --retain 60.

Each snapshot has a complete manifest of the source paths and points regular-file content at SHA-256 objects.

Only objects whose content hash is not already present are copied on later runs.

An unchanged source returns already current without creating a snapshot.

Deleted source paths disappear from later manifests but remain available through retained earlier snapshots.

The backup root records its exact source and destination identity and refuses an unrelated nonempty directory.

The backup also refuses an unavailable H: volume, a concurrent lock, a corrupt snapshot or object, and unsupported special files in the source tree.

Special files cannot be represented by this content-addressed 9p-compatible store and are refused rather than excluded; supporting one requires a separate captain decision.

The command never writes D:\Workspace\firstmate, D:\RocoData, or another external source tree.

## Verification and recovery

Verify the latest snapshot and every referenced object with /home/ale/firstmate/bin/fm-replicante.sh verify.

Verify every retained historical snapshot with /home/ale/firstmate/bin/fm-replicante.sh verify --all.

Run a temporary reconstruction check with /home/ale/firstmate/bin/fm-replicante.sh verify --restore-test.

The restore test compares every restored path, regular-file hash, size, and symbolic-link target before removing its temporary output.

Choose a snapshot identifier from the latest marker or a verified manifest, then restore it to a new H: directory outside the backup store.

Use /home/ale/firstmate/bin/fm-replicante.sh restore --snapshot <snapshot-id> --output /mnt/h/Firstmate-Backup-recovery-<date> --apply-modes for a recovery reconstruction.

Restore never overwrites an existing output, the canonical source, the backup store, or a D: tree.

Source modes are recorded in snapshot manifests.

The 9p object store uses content operations, and --apply-modes requests mode restoration only when the recovery filesystem supports it.

Inspect a restored tree before any separate operator-owned replacement or import procedure.

## Scheduling

Create one Windows Task Scheduler action for the WSL command, such as wsl.exe -d Ubuntu -- /home/ale/firstmate/bin/fm-replicante.sh run --retain 30.

Use one scheduled replicante action rather than parallel backup writers.

The destination-parent lock rejects an overlapping run and never clears an existing lock automatically.

Scheduling shadow and replicante separately is safe because they have different destinations and independent locks.

Do not schedule a command that points at /mnt/h generally or at a different backup folder.

## Tests

Run the fixture suite with bash tests/fm-replicante.test.sh.

The suite covers first backup, idempotent repetition, incremental changes, deletion history, retention, destination identity, concurrent locking, unsupported source entries, corruption refusal, verification, and restoration.
