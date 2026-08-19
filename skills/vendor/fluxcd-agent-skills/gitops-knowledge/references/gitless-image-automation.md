# Gitless Image Automation Reference

Gitless image automation updates running workloads when new container images or Helm
chart versions are published — **without committing tag bumps back to Git**. It uses
Flux Operator's `ResourceSetInputProvider` to scan OCI registries and re-renders the
owning `ResourceSet` whenever a new tag or digest is detected.

Contrast with the Git-based variant (`ImageRepository` + `ImagePolicy` +
`ImageUpdateAutomation`, see `references/image-automation.md`): that one mutates YAML
in Git and relies on Flux to re-apply on the next reconciliation. Gitless skips Git
entirely and upgrades the `HelmRelease` (or `Kustomization`) directly.

**When to pick which:**

| Concern | Git-based | Gitless |
|---|---|---|
| Audit trail of tag bumps | Git commits | Flux events / notifications |
| PR-based approval workflow for version bumps | Yes (via `push.branch` + PR) | No |
| Requires a bot with write access to the repo | Yes | No |
| Requires `image-automation-controller` + `image-reflector-controller` | Yes | No — only `flux-operator` + helm/kustomize controllers |

This reference assumes familiarity with `ResourceSet` and `ResourceSetInputProvider`
basics — load `references/resourcesets.md` first if those are new.

## How It Works

1. One `ResourceSetInputProvider` per artifact you want to track (Helm chart,
   container image). Each scans its registry on its own schedule and exports the
   latest matching `tag` and `digest`.
2. A `ResourceSet` consumes all providers via `inputsFrom` with
   `inputStrategy: Permute` and templates the tag/digest into a `HelmRelease` or
   `Kustomization`.
3. When a provider detects a new tag or digest, the `ResourceSet` re-renders. The
   rendered `HelmRelease` values (or `Kustomization.spec.images`) change, which
   triggers the downstream controller to upgrade the release.

## Step 1 — Input Providers

One provider per artifact. Each runs independently:

```yaml
apiVersion: fluxcd.controlplane.io/v1
kind: ResourceSetInputProvider
metadata:
  name: podinfo-chart
  namespace: apps
  annotations:
    fluxcd.controlplane.io/reconcileEvery: "15m"
spec:
  type: OCIArtifactTag
  url: oci://ghcr.io/stefanprodan/charts/podinfo
  filter:
    semver: ">=6.0.0"
    limit: 1
---
apiVersion: fluxcd.controlplane.io/v1
kind: ResourceSetInputProvider
metadata:
  name: podinfo-image
  namespace: apps
  annotations:
    fluxcd.controlplane.io/reconcileEvery: "5m"
spec:
  type: OCIArtifactTag
  url: oci://ghcr.io/stefanprodan/podinfo
  filter:
    includeTag: "latest"
    limit: 1
---
apiVersion: fluxcd.controlplane.io/v1
kind: ResourceSetInputProvider
metadata:
  name: redis-image
  namespace: apps
spec:
  type: OCIArtifactTag
  url: oci://docker.io/redis
  filter:
    semver: ">0.0.0-0"
    includeTag: ".*-alpine$"
    limit: 1
```

### Filter Shapes

- `semver: ">=6.0.0"` — highest matching semver tag.
- `includeTag: "latest"` — a specific floating tag. The exported `tag` stays `latest`;
  the `digest` changes on every push, and that's what triggers redeployment.
- `semver` + `includeTag` — semver ordering within a tag variant (e.g. only `*-alpine`
  builds).
- `excludeTag` — regex to drop tags (e.g. `".*-rc.*"` to skip release candidates).

### `limit: 1` Is Required

Without `limit: 1`, the provider emits every matching tag. Combined with
`inputStrategy: Permute` across multiple providers, this produces a combinatorial
explosion of `HelmRelease` instances (one per tag-combination). For image automation
you want exactly one release pinned to the latest tag — always set `limit: 1`.

### Registry Authentication

- **Public registries** — no auth needed.
- **Private registries with a pull secret** — reference a
  `kubernetes.io/dockerconfigjson` `Secret` via `spec.secretRef.name`.
- **Cloud IAM / workload identity** — use `ACRArtifactTag`, `ECRArtifactTag`, or
  `GARArtifactTag` instead of `OCIArtifactTag` and bind a `serviceAccountName`
  annotated for the cloud (IRSA for EKS, Workload Identity for GKE, Workload Identity
  for AKS).

## Step 2 — ResourceSet Consuming the Providers

```yaml
apiVersion: fluxcd.controlplane.io/v1
kind: ResourceSet
metadata:
  name: podinfo
  namespace: apps
spec:
  inputStrategy:
    name: Permute
  inputsFrom:
    - kind: ResourceSetInputProvider
      name: podinfo-chart
    - kind: ResourceSetInputProvider
      name: podinfo-image
    - kind: ResourceSetInputProvider
      name: redis-image
  resources:
    - apiVersion: source.toolkit.fluxcd.io/v1
      kind: OCIRepository
      metadata:
        name: podinfo
        namespace: apps
      spec:
        interval: 12h
        url: oci://ghcr.io/stefanprodan/charts/podinfo
        ref:
          tag: << inputs.podinfo_chart.tag >>
    - apiVersion: helm.toolkit.fluxcd.io/v2
      kind: HelmRelease
      metadata:
        name: podinfo
        namespace: apps
      spec:
        interval: 30m
        releaseName: podinfo
        chartRef:
          kind: OCIRepository
          name: podinfo
        values:
          image:
            tag: "<< inputs.podinfo_image.tag >>@<< inputs.podinfo_image.digest >>"
          redis:
            enabled: true
            tag: "<< inputs.redis_image.tag >>@<< inputs.redis_image.digest >>"
```

### Name-to-Key Transformation

Template keys must be valid identifiers, so hyphens in the provider's `metadata.name`
are converted to underscores in the template:

| `ResourceSetInputProvider` name | Template key |
|---|---|
| `podinfo-chart` | `inputs.podinfo_chart` |
| `podinfo-image` | `inputs.podinfo_image` |
| `redis-image` | `inputs.redis_image` |

A provider named `podinfo-image` exporting `tag: 6.5.4` and `digest: sha256:abc…` is
consumed as `<< inputs.podinfo_image.tag >>` and `<< inputs.podinfo_image.digest >>`.

### Pin Tag + Digest

Always template **both** tag and digest — `tag@digest`. For immutable semver tags this
is belt-and-braces. For mutable floating tags (`latest`, `main`) the tag string never
changes but the digest does on every push, and the digest change is what causes the
rendered `HelmRelease` values to differ, triggering an upgrade.

## Step 3 — Images Not Exposed in Helm Values

Many community charts don't expose every container image in values. Use Kustomize
post-renderers on the `HelmRelease` (or `.spec.images` on a `Kustomization`) to patch
images after rendering:

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
spec:
  postRenderers:
    - kustomize:
        images:
          - name: ghcr.io/stefanprodan/podinfo
            newTag: << inputs.podinfo_image.tag | quote >>
            digest: << inputs.podinfo_image.digest | quote >>
```

For a Flux `Kustomization`:

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
spec:
  images:
    - name: ghcr.io/stefanprodan/podinfo
      newTag: << inputs.podinfo_image.tag | quote >>
      digest: << inputs.podinfo_image.digest | quote >>
```

## Notifications on Update

Wire a `Provider` + `Alert` (see `references/notifications.md`) to emit Slack/Teams
notifications when the `ResourceSet` or resulting `HelmRelease` changes state. Event
sources to watch: `ResourceSet`, `HelmRelease`, `Kustomization`, `OCIRepository`.

## Operations

Suspend a single provider to pause updates for one artifact without freezing the rest
of the app:

```shell
flux operator -n apps suspend rsip redis-image
flux operator -n apps resume rsip redis-image
```

Suspend the `ResourceSet` to freeze the entire deployment workflow:

```shell
flux operator -n apps suspend rset podinfo
```

Force an immediate registry scan:

```shell
flux operator -n apps reconcile rsip podinfo-image
```

Dry-run the `ResourceSet` locally with mock inputs to verify the template renders:

```shell
flux operator build rset -f podinfo-resourceset.yaml \
  --inputs-from-provider static-inputs.yaml
```
