---
name: gitops-knowledge
description: >-
  Agent-only load stub for the adopted official Flux CD gitops-knowledge skill.
  Load before Flux CD concept questions, CRD manifest generation, or GitOps repository structure guidance.
  Read the vendored upstream skill and the flux-classic-gitops amendment when classic controller installs apply.
user-invocable: false
metadata:
  internal: true
---

# gitops-knowledge

This stub loads the adopted official skill from [`skills/vendor/fluxcd-agent-skills/gitops-knowledge/SKILL.md`](../../../skills/vendor/fluxcd-agent-skills/gitops-knowledge/SKILL.md).
Upstream provenance and pinned revision are recorded in [`skills/vendor/fluxcd-agent-skills/MANIFEST`](../../../skills/vendor/fluxcd-agent-skills/MANIFEST).

After this stub loads:

1. Read and follow the vendored `gitops-knowledge` skill completely.
2. When the deployment uses classic Flux controllers (manual gotk install), also load and follow [`flux-classic-gitops`](../flux-classic-gitops/SKILL.md); its install-model rules override upstream Operator and `flux bootstrap` preference in that case.

Never treat this stub as the procedure owner.
`gitops-cluster-debug` from the upstream repository is not adopted or exposed by firstmate.
