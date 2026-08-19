# Flux API Migration Guide

Reference for migrating from deprecated Flux API versions to current stable versions.
Source: https://github.com/fluxcd/flux2/discussions/5572

## Deprecated API Removals

**Removed in Flux v2.7:**
- `source.toolkit.fluxcd.io/v1beta1`
- `kustomize.toolkit.fluxcd.io/v1beta1`
- `helm.toolkit.fluxcd.io/v2beta1`
- `image.toolkit.fluxcd.io/v1beta1`
- `notification.toolkit.fluxcd.io/v1beta1`

**Removed in Flux v2.8:**
- `source.toolkit.fluxcd.io/v1beta2`
- `kustomize.toolkit.fluxcd.io/v1beta2`
- `helm.toolkit.fluxcd.io/v2beta2`
- `notification.toolkit.fluxcd.io/v1beta2`

## CLI-Based Upgrade

### Step 1: Migrate Git resources

Update all manifests in the Git repository to use stable API versions:

```bash
git clone <your-git-repo>
cd <your-git-repo>
flux migrate -f .
git commit -am "Migrate to Flux stable APIs"
git push
```

Then reconcile: `flux reconcile ks flux-system --with-source`

### Step 2: Migrate cluster resources

Update the resources stored in Kubernetes etcd:

```bash
flux migrate
```

This is idempotent and safe to run multiple times. Supports `--context` and `--kubeconfig` flags.

### Step 3: Upgrade Flux components

```bash
flux bootstrap [same parameters as initial installation]
flux check  # Verify upgrade success
```

## Operator-Based Upgrade

### Step 1: Update Flux Operator to v0.43.0+

Update the operator via OperatorHub, Terraform/OpenTofu, or HelmRelease.

### Step 2: Migrate Git resources

Same as CLI Step 1 — update manifests in Git with `flux migrate -f .`

### Step 3: Update FluxInstance manifest

Set the distribution version to `2.8.x` or later:

```yaml
apiVersion: fluxcd.controlplane.io/v1
kind: FluxInstance
metadata:
  name: flux
  namespace: flux-system
spec:
  distribution:
    version: "2.8.x"
    registry: "ghcr.io/fluxcd"
```

The operator automatically handles in-cluster API migrations.

## Key Notes

- `flux migrate` is idempotent — safe to run multiple times
- `flux migrate -f .` updates files in-place; use `--dry-run` to preview changes
- Clear `.kube/cache` locally if old API versions persist after migration
- Use `scripts/validate.sh` to verify manifests after migration
