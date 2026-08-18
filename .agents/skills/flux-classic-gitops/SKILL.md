---
name: flux-classic-gitops
description: >-
  Firstmate amendment for classic Flux CD controller installs.
  Load with the adopted official gitops-knowledge or gitops-repo-audit skills when the target cluster uses manually applied gotk controller manifests instead of Flux Operator.
  Overrides Flux Operator and flux bootstrap guidance from those skills without replacing their CRD, CLI, or audit procedures.
user-invocable: false
metadata:
  internal: true
---

# flux-classic-gitops

This skill is a narrow Firstmate-owned amendment.
It does not replace the vendored official Flux CD skills under `skills/vendor/fluxcd-agent-skills/`.
When this amendment conflicts with those skills on install model or bootstrap method, this amendment wins.

## When to apply

Load this skill together with `gitops-knowledge` or `gitops-repo-audit` when any of these are true:

- Flux controllers were installed from tracked `gotk-components` manifests with `kubectl apply`, not through Flux Operator or `flux bootstrap`.
- The task forbids `flux bootstrap` with a long-lived Git write token.
- Project policy names a classic Flux controller bundle rather than a `FluxInstance`.

When the deployment genuinely uses Flux Operator (`FluxInstance`), follow the official skill's Operator guidance and do not apply this amendment.

## Classic install model

- Install and upgrade controllers from version-pinned manifests committed in Git.
- Apply controller manifests with `kubectl apply` (or the project's documented equivalent), not `flux bootstrap`.
- Pin every controller image by digest in those manifests; do not rely on floating tags for production reconciliation paths.
- Keep Git credentials read-only for routine reconciliation; separate any push credentials used only for image automation or promotion flows.
- Project-specific manifest paths, namespaces, repository URLs, controller versions, and stage names belong in the project repo, not here.

## Operations that stay authoritative in the official skills

- CRD shapes, `flux` CLI reconciliation commands, schema validation, Kustomization and HelmRelease semantics, and local repo audit scripts remain governed by the adopted official skill you loaded.
- This amendment only overrides install/bootstrap/Operator preference and records the classic safety boundaries below.

## Emergency suspend and resume

- Use `flux suspend kustomization` (or the matching suspend target for the reconciler in scope) before deliberate out-of-band cluster edits that would fight GitOps.
- Resume with `flux resume kustomization` after the emergency change is committed or abandoned.
- Prefer returning desired state through Git rather than leaving reconcilers suspended.

## Rollback

- Roll back by reverting the Git commit that introduced the bad desired state and letting Flux reconcile forward.
- Do not treat manual cluster edits as the primary rollback path when Git history can express the fix.

## Credential and image rules

- Read-only Git deploy keys or tokens belong in Kubernetes Secrets referenced by `GitRepository` or `OCIRepository`; never commit credential material.
- Digest-pinned images are mandatory for controllers and for workloads where the project policy requires immutability; the official skills remain authoritative for CRD fields once this amendment has selected the classic install model.
