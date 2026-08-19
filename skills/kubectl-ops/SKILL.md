---
name: kubectl-ops
description: >-
  Safe Kubernetes and K3s operations with kubectl: cluster and namespace verification,
  read-only inspection, mutation and delete boundaries, kubectl cp transfer safety,
  and explicit destructive authorization. Use before any kubectl operation on a cluster.
---

<!-- maintainers: public installer-facing skill. Procedure owner for both firstmate and project workers. Firstmate loads `.agents/skills/kubectl-ops/SKILL.md`, a stub that points here. -->

# kubectl-ops

Use this skill before any `kubectl` operation that reads or changes cluster state.
Project-local facts such as context names, namespace names, and stage procedures belong in the project's own agent instructions, not in this global skill.

## Current-source discovery

Never memorize flags or claim subcommands this install does not support.
Before operations, consult the installed CLI:

```sh
kubectl version --client
kubectl --help
kubectl <subcommand> --help
```

Subcommand help is authoritative for the current version.

## Installation

Copy or link this directory into a project worker's skill discovery path:

- `.agents/skills/kubectl-ops/` (recommended)
- `.claude/skills/kubectl-ops/` (Claude Code)

From the firstmate repository, the source path is `skills/kubectl-ops/`.
Installers such as [skills.sh](https://skills.sh) can add the same directory from the published firstmate repo.

The bundled helper is `scripts/kubectl-safe.sh` relative to this skill directory.

## Project AGENTS.md trigger

Add this exact line to the project's always-loaded agent instructions (for example `AGENTS.md`):

```md
- `kubectl-ops` - load before any `kubectl` operation: applying or deleting resources, `kubectl cp`, exec into pods, scaling, draining, or any operation that reads or changes cluster state.
```

## Bundled helper

Use `scripts/kubectl-safe.sh` for context and namespace verification, Secret output redaction, `kubectl cp` post-transfer checks, and dry-run flag assertions.
It never prints Secret values.

```sh
HELPER="<skill-dir>/scripts/kubectl-safe.sh"
"$HELPER" probe
"$HELPER" verify-context <EXPECTED_CONTEXT>
"$HELPER" verify-namespace <NAMESPACE>
kubectl get secret <NAME> -n <NAMESPACE> -o json | "$HELPER" redact-json
kubectl cp <SRC> <DEST> && "$HELPER" cp-check <LOCAL_SRC> <LOCAL_DEST>
"$HELPER" has-dry-run -- kubectl apply --dry-run=client -f manifest.yaml
```

`probe` prints `status=`, `version=`, and `current_context=` only.
Treat `status=unavailable` as absent or broken kubectl.
Treat `status=no_context` as kubeconfig present but no current context selected.
Only `status=ready` means kubectl is present and a current context is set.

## Context verification

Verify the intended cluster context before any mutating command.

1. Record the expected context from the task authority or project-local instructions.
2. Run `"$HELPER" verify-context <EXPECTED_CONTEXT>` or `kubectl config current-context` and compare manually.
3. Refuse mutating commands when the current context is unexpected, empty, or unverifiable.
4. Never guess context from kubeconfig file names alone.

Cross-context mutations are forbidden without explicit authority naming both the source and destination contexts.

## Namespace verification

Every mutating command must name its target namespace and verify it exists.

1. Record the expected namespace from task authority or project-local instructions.
2. Run `"$HELPER" verify-namespace <NAMESPACE>` before apply, delete, scale, exec-with-write, or copy operations that target a namespace.
3. Refuse mutating commands that omit `-n <namespace>` or `--namespace <namespace>` when the resource is namespaced.
4. Cross-namespace or cluster-wide (`-A`, `--all-namespaces`) mutations are forbidden without explicit authority naming the scope.

## Read-only versus mutating operations

| Class | Examples | Authority |
| --- | --- | --- |
| Read-only | `get`, `describe`, `logs`, `top`, `auth can-i`, `diff`, `apply --dry-run=client` | Allowed for inspection; still verify context for clarity |
| Mutating | `apply`, `patch`, `scale`, `rollout restart`, `exec` with writes, `cp`, `label`, `annotate`, `cordon` | Requires explicit task authority naming the resource and namespace |
| Destructive | `delete`, scale-to-zero, `drain` with eviction, live restore into production data paths | Requires explicit captain or operator authority naming the exact resource |

Prefer `kubectl apply --dry-run=client` or server dry-run when validating manifests before a real apply.
Use `"$HELPER" has-dry-run -- <command...>` to assert a planned command includes a dry-run flag before execution.

Never treat a read-only command as permission to run a follow-on mutation without its own authority.

## Destructive authorization

Stop and escalate when the task lacks explicit authority for:

- Deleting namespaces, PVCs, StatefulSets, or other stateful resources.
- Scaling a workload to zero replicas.
- Draining nodes or evicting pods outside a controlled maintenance window.
- Restoring live data over an active database or application volume.
- Deleting a PVC that holds application data.

PVC deletion that would destroy data always requires captain approval, even when the namespace and resource names are otherwise authorized.
Record the approval in the task before proceeding.

## Secret output redaction

Never print Secret values in chat, logs, command arguments visible to tools, or tracked files.

1. Prefer metadata inspection: `kubectl get secret <NAME> -n <NS> -o jsonpath='{.metadata.name}'`.
2. When structure is required, fetch JSON and pipe through `"$HELPER" redact-json`.
3. Never paste `kubectl get secret -o yaml` output into chat without redaction.
4. Treat `stringData`, `data`, and decoded values as sensitive even when base64-encoded.

If a command might decode Secret material, redirect output to a gitignored temp file, use it only inside a trusted child process, and delete it before exit.

## kubectl cp safety

Use `kubectl cp` only with explicit task authority naming the source pod path and destination.

1. Confirm context and namespace before copy.
2. Copy to a local path outside tracked files, for example under `/tmp` or a gitignored directory.
3. Run `"$HELPER" cp-check <LOCAL_SRC> <LOCAL_DEST>` immediately after copy.
4. `cp-check` refuses empty sources, compares SHA-256 checksums when a destination exists, and prints `checksum=` on success.
5. When copying out of the cluster for backup, retain the checksum in task evidence.
6. Clean up temporary pods or debug copies created only for transfer.
7. Never use host-path mounts or privileged pods to bypass `kubectl cp` unless explicit operator authority covers that alternate path.

## Rollback

Prefer the resource's declared reconciliation model:

- GitOps-managed workloads: suspend/resume or revert the Git source and reconcile, per the project's GitOps procedure.
- Deployments and similar controllers: `kubectl rollout undo` when that matches the resource model.
- One-off objects: re-apply the last known good manifest from version control rather than improvising edits.

Record what was changed and how rollback was verified.

## Failure handling

| Evidence | Meaning |
| --- | --- |
| `probe` reports `unavailable` | kubectl absent or broken |
| `probe` reports `no_context` | kubeconfig present but no current context |
| `verify-context` exit 1 | Current context does not match expected |
| `verify-namespace` exit 1 | Namespace absent |
| `verify-context` or `verify-namespace` exit 3 | kubectl or API error during verification |
| `cp-check` exit 1 | Source empty or checksum mismatch |
| `has-dry-run` exit 1 | Command lacks a `--dry-run` flag |
| Mutating command non-zero | Stop; do not report success without verification |

Never retry destructive commands with broadened scope after a failure.

## Never commit cluster secrets

Never commit kubeconfig credentials, Secret values, captured `kubectl` output that contains Secret data, or backup archives with cleartext credentials.
Redact before saving command transcripts or diagnostics.
