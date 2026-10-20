# Artifact lineage

A worker's result is its artifacts, not its chat. This note owns the contract behind the
`artifacts=` field a secondmate home publishes on the parent channel, and the manifest that
field points at.

## Why

The parent channel already carried two pointers: `report=data/<child>/report.md` for a scout's
finding and `pr=<url>` for a ship's delivery, plus `mode=` and `yolo=`. Those say *where* an
outcome lives, not *which bytes* were verified. A conversational summary cannot be re-checked
after the worker's disposable worktree is torn down, and forwarding a worker transcript as the
result makes the parent consume raw model text instead of a status. The contract therefore
returns artifact references plus hashes.

## The manifest

`data/<task>/artifacts.json` is the one machine-readable result:

```json
{
  "schema": "fm-artifact-manifest.v1",
  "task": "<task>",
  "artifacts": [
    {"kind": "patch", "path": "data/<task>/worker.patch", "sha256": "<64 hex>", "bytes": 1234},
    {"kind": "test-log", "path": "data/<task>/test.log", "sha256": "<64 hex>", "bytes": 5678},
    {"kind": "report", "path": "data/<task>/report.md", "sha256": "<64 hex>", "bytes": 901}
  ]
}
```

Rules:

- **Kinds are a closed allowlist:** `patch`, `test-log`, `review-report`, `report`, `trace`,
  `manifest`. `transcript`, `chat`, `session`, and `conversation` are refused, so a transcript
  cannot be forwarded as a WorkerResult.
- **Paths are home-relative `data/<task>/...`** and must resolve to regular, non-symlinked files
  under the data directory. A parent-traversal component, an empty component, a symlinked file,
  or a symlinked directory component is refused.
- **Every entry is pinned by the full SHA-256 of the file's bytes** and its byte count. There is
  no truncated hash and no digest of a digest.
- The writer sorts entries, writes atomically, and never mutates an artifact.
- An empty manifest is not a result: `write` requires at least one `--artifact`, and `verify`
  refuses an entry-less manifest.

## Writing and verifying

`bin/fm-artifact-manifest.sh` is the worker-facing entry point:

```bash
bin/fm-artifact-manifest.sh write --task <id> \
  --artifact patch=data/<id>/worker.patch \
  --artifact test-log=data/<id>/test.log \
  --artifact report=data/<id>/report.md
bin/fm-artifact-manifest.sh verify --task <id>
bin/fm-artifact-manifest.sh ref --task <id>
```

`write` prints the manifest path. `verify` recomputes every hash and byte count, and prints the
first failing entry. `ref` prints the parent-channel suffix only while the manifest verifies:

```
artifacts=data/<id>/artifacts.json artifacts_sha256=<64 hex>
```

Exit codes are owned by the script header. `bin/fm-artifact-lib.sh` owns the contract itself and
is sourced by both the entry point and the parent-channel publisher.

The generated ship Definition of done (`bin/fm-dod-lib.sh`) and the scout Definition of done
(`bin/fm-brief.sh`) both instruct the worker to write the manifest before its `done:` line.

## Publishing

`bin/fm-inactive-reconcile.sh` appends the `artifacts=` and `artifacts_sha256=` pair to the
parent-channel line for a child whose manifest verifies. The parent reads the pointer and the
digest; it never receives the artifact bodies through the channel. The digest identifies the
exact manifest bytes, so a parent that later reads a changed manifest can tell it changed.

The field is appended only on the **local** route. The remote secondmate adapter transfers
`report=data/....md` pointers today and does not yet transfer a JSON manifest, so a remote line
carries no pointer it cannot honour. Extending that transport is separate work; until then the
remote route publishes the existing report and PR pointers without an artifact pair.

## What this does not do

- It does not mirror a worker's chat. A transcript is the thing the contract exists to exclude.
- It does not verify that an artifact is *correct*, only that it is the bytes the manifest names.
  Correctness is the reviewer's and the acceptance command's job.
- It does not replace the report. A scout still writes `data/<id>/report.md`; the manifest adds
  the hash of that report and of the evidence beside it.
