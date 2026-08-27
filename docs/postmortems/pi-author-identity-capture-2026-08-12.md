# Pi author identity capture gap, 2026-08-12

## Outcome

The exact intermittent capture cause was not established.
The evidence does not prove host load caused either capture gap.

The original task treated the gap as fatal because Crosscheck rejected modern Pi metadata that recorded `author_identity_snapshot_epoch=launch-bound-v1` without `author_account_identity`.
The captain subsequently removed author identity from merge admissibility.
Reviewer independence is structural through the separate reviewer account pool and different model, so a missing identity record must not block spawn, review, validation, or merge.
The fail-closed spawn refusal built during the first implementation round was deliberately removed before shipping on that direction.

## Direct evidence

The live metadata for `winback-promo-verify-schedule-w3` and `winback-cut-to-three-k4` contained `author_identity_snapshot_epoch=launch-bound-v1` without `author_account_identity`.
The live metadata for `crosscheck-coverage-policy-unsatisfiable` contained the same epoch plus a non-empty identity.
The task-private Pi snapshot currently retained for each of those three tasks had a readable OAuth identity in the provider slot named by its recorded model.
The two tasks with gaps had been relaunched, so those retained successful snapshots do not prove that the original launch capture succeeded.
They do prove that the same task and provider-slot shapes can be captured successfully on a later attempt.

The inspection used the following read-only command against each task's recorded `tasktmp` and model slot.

```sh
python3 - <<'PY'
import json
from pathlib import Path
state = Path('/Users/dongkeun/firstmate-home/state')
for task in (
    'winback-promo-verify-schedule-w3',
    'winback-cut-to-three-k4',
    'crosscheck-coverage-policy-unsatisfiable',
):
    meta = dict(
        line.split('=', 1)
        for line in (state / f'{task}.meta').read_text().splitlines()
        if '=' in line
    )
    slot = meta['model'].partition('/')[0]
    auth = json.loads(
        (Path(meta['tasktmp']) / 'pi-author-agent' / 'auth.json').read_text()
    )
    credential = auth.get(slot)
    print(
        task,
        slot in auth,
        isinstance(credential, dict) and credential.get('type') == 'oauth',
        isinstance(credential, dict)
        and isinstance(credential.get('accountId'), str)
        and bool(credential['accountId'].strip()),
    )
PY
```

It reported `True True True` for all three retained snapshots.
The exact sweep command below reported four current modern Pi metadata gaps, including both named examples.

```sh
FM_HOME=/Users/dongkeun/firstmate-home \
FM_STATE_OVERRIDE=/Users/dongkeun/firstmate-home/state \
bin/fm-author-identity-sweep.sh
```

## Why load is not a finding

`bin/fm-pi-author-snapshot.py` has no timeout.
Host load therefore cannot directly trigger a capture timeout in this implementation.
The snapshot traverses mutable Pi configuration and rejects a source file whose device, inode, or size changes while copied.
High load could widen that race window, but no original launch stderr or structured failure record survived to show that either affected launch took this branch.
The helper can also fail for permanent reasons such as a missing provider slot, unreadable or malformed `auth.json`, an unsafe filesystem entry, a file or tree size bound, or an ordinary filesystem error.
No available artifact distinguishes those branches for the two incidents.

## Remediation

`bin/fm-author-identity-sweep.sh` reports modern Pi ship/scout metadata with the epoch and without exactly one non-empty identity.
`bin/fm-bootstrap.sh` runs the read-only sweep at session start.
The diagnostic is explicitly informational and records capture reliability without stopping healthy work.

The companion task `crosscheck-drop-author-identity-requirement` owns removal of author identity from Crosscheck and the non-fatal spawn warning.
This task intentionally does not edit `bin/fm-crosscheck.py`, `bin/fm-spawn.sh`, or their shared capture regression after the captain's reversal, avoiding a conflicting implementation of the same policy.

No automatic retry was added.
Without the original failure classification, retrying every failure would mask permanent model, credential, and filesystem defects as transient load.
The existing snapshot helper writes its specific failure to stderr, so a future occurrence can identify its actual branch.
A future bounded retry should be limited to a measured transient class, such as a proved source-change race, rather than applied to every identity gap.

## 2026-08-26 package-symlink follow-up

A separate deterministic capture failure was established after this incident.
The local Pi home contains package-manager shims under `npm/node_modules/.bin`, and the snapshot helper rejected every symlink before inspecting whether it was safe.
That refusal removed the task-private snapshot needed by retained local Pi recovery even though the package links were relative and stayed inside the Pi home.

The [snapshot helper header](../../bin/fm-pi-author-snapshot.py) owns the current relative-link acceptance, containment, and budget contract.

`tests/fm-pi-author-snapshot.test.sh` owns the executable filesystem boundary regressions.
The focused Pi spawn and retained-task recovery cases also carry a package-manager shim so those lifecycle paths prove that a usable task-private snapshot survives capture and reuse.
