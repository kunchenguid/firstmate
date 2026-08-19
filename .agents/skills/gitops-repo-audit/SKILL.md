---
name: gitops-repo-audit
description: >-
  Agent-only load stub for the adopted official Flux CD gitops-repo-audit skill.
  Load before auditing or validating a local Flux GitOps repository with read-only schema, migration, and security checks.
  Read the vendored upstream skill and the flux-classic-gitops amendment when classic controller installs apply.
user-invocable: false
metadata:
  internal: true
---

# gitops-repo-audit

This stub loads the adopted official skill from [`skills/vendor/fluxcd-agent-skills/gitops-repo-audit/SKILL.md`](../../../skills/vendor/fluxcd-agent-skills/gitops-repo-audit/SKILL.md).
Upstream provenance and pinned revision are recorded in [`skills/vendor/fluxcd-agent-skills/MANIFEST`](../../../skills/vendor/fluxcd-agent-skills/MANIFEST).

After this stub loads:

1. Read and follow the vendored `gitops-repo-audit` skill completely.
2. When the deployment uses classic Flux controllers (manual gotk install), also load and follow [`flux-classic-gitops`](../flux-classic-gitops/SKILL.md) for install-model and bootstrap boundaries.

Never treat this stub as the procedure owner.
`gitops-cluster-debug` from the upstream repository is not adopted or exposed by firstmate.
