# Flux Operator Reference

The Flux Operator manages the Flux installation lifecycle through two CRDs:
- **FluxInstance** (`fluxcd.controlplane.io/v1`) — declarative Flux installation and configuration
- **FluxReport** (`fluxcd.controlplane.io/v1`) — read-only observed state of Flux

**Contents:** [Installation](#installation) | [FluxInstance](#fluxinstance) | [FluxReport](#fluxreport)

## Installation

Install the Flux Operator before creating a FluxInstance.

**Helm:**
```bash
helm install flux-operator oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator \
  --namespace flux-system --create-namespace
```

**Terraform:**
```hcl
module "flux_operator_bootstrap" {
  source  = "controlplaneio-fluxcd/flux-operator-bootstrap/kubernetes"

  gitops_resources = {
    instance_yaml = file("${path.root}/../clusters/${var.cluster_name}/flux-system/flux-instance.yaml")
  }
}
```

For the full Terraform bootstrap workflow — load `references/terraform-bootstrap.md`.

To automatically update the operator when new versions are released:

```yaml
apiVersion: fluxcd.controlplane.io/v1
kind: ResourceSet
metadata:
  name: flux-operator
  namespace: flux-system
spec:
  dependsOn:
    - apiVersion: apiextensions.k8s.io/v1
      kind: CustomResourceDefinition
      name: helmreleases.helm.toolkit.fluxcd.io
  resources:
    - apiVersion: source.toolkit.fluxcd.io/v1
      kind: OCIRepository
      metadata:
        name: flux-operator
        namespace: flux-system
      spec:
        interval: 10m
        url: oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator
        layerSelector:
          mediaType: "application/vnd.cncf.helm.chart.content.v1.tar+gzip"
          operation: copy
        ref:
          semver: '*'
    - apiVersion: helm.toolkit.fluxcd.io/v2
      kind: HelmRelease
      metadata:
        name: flux-operator
        namespace: flux-system
      spec:
        interval: 30m
        releaseName: flux-operator
        serviceAccountName: flux-operator
        chartRef:
          kind: OCIRepository
          name: flux-operator
        install:
          strategy:
            name: RetryOnFailure
        upgrade:
          force: true
          strategy:
            name: RetryOnFailure
        values:
          multitenancy:
            enabled: true
            defaultServiceAccount: flux-operator
```

## FluxInstance

Only one FluxInstance can exist per cluster. It must be named `flux` and live in the
operator's namespace (typically `flux-system`).

### Canonical YAML

```yaml
apiVersion: fluxcd.controlplane.io/v1
kind: FluxInstance
metadata:
  name: flux
  namespace: flux-system
spec:
  distribution:
    version: "2.x"
    registry: "ghcr.io/fluxcd"
  components:
    - source-controller
    - source-watcher
    - kustomize-controller
    - helm-controller
    - notification-controller
  cluster:
    type: kubernetes
    size: medium
    multitenant: true
    tenantDefaultServiceAccount: flux
    networkPolicy: true
    domain: "cluster.local"
  sync:
    kind: OCIRepository
    url: "oci://ghcr.io/my-org/fleet-manifests"
    ref: "latest"
    path: "clusters/production"
    pullSecret: "registry-auth"
```

### Distribution

| Field | Type | Description |
|-------|------|-------------|
| `distribution.version` | string | Semver range (`2.x`, `2.8.x`) or exact version |
| `distribution.registry` | string | Container registry (e.g., `ghcr.io/fluxcd`) |
| `distribution.variant` | string | `upstream-alpine`, `enterprise-alpine`, `enterprise-distroless`, `enterprise-distroless-fips` |
| `distribution.artifact` | string | OCI artifact URL with distribution manifests |
| `distribution.imagePullSecret` | string | Secret name for pulling controller images |

### Components

Default components: `source-controller`, `kustomize-controller`, `helm-controller`, `notification-controller`.

Optional components:
- `image-reflector-controller` and `image-automation-controller` — add only on clusters
  that run image automation (typically a dedicated "update" cluster).
- `source-watcher` — controller for the ArtifactGenerator CRD. Composes and decomposes
  artifacts from multiple Flux sources (GitRepository, OCIRepository, Bucket), producing
  ExternalArtifact resources. Required for monorepo decomposition and multi-source
  composition workflows.

### Cluster Configuration

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `cluster.type` | string | `kubernetes` | `kubernetes`, `openshift`, `aws`, `azure`, `gcp` |
| `cluster.size` | string | `medium` | Affects controller resource limits and concurrency |
| `cluster.multitenant` | bool | false | Enable multi-tenancy lockdown |
| `cluster.tenantDefaultServiceAccount` | string | `default` | Default SA for tenant reconcilers when multitenant lockdown is enabled and the field is omitted |
| `cluster.networkPolicy` | bool | true | Restrict network access to Flux controllers |
| `cluster.domain` | string | `cluster.local` | Kubernetes cluster domain |

### Cluster Sizing

| Size | Concurrency | CPU Limit | Memory Limit | Use Case |
|------|-------------|-----------|--------------|----------|
| `small` | 5 | 1000m | 512Mi | Dev, small clusters (<50 resources) |
| `medium` | 10 | 2000m | 1Gi | Standard production clusters |
| `large` | 20 | 3000m | 3Gi | Large clusters (hundreds of resources) |

### Multi-Tenancy

```yaml
spec:
  cluster:
    multitenant: true
    tenantDefaultServiceAccount: flux
```

When enabled:
- Controllers impersonate the specified service account
- Cross-namespace references are disabled
- Each tenant namespace needs its own ServiceAccount, RoleBinding, and source credentials

### Sync Configuration

Configure FluxInstance to sync manifests from a source repository.

**OCI sync (Gitless GitOps):** see the Canonical YAML above — its `spec.sync` block
(`kind: OCIRepository`, `oci://` url, `ref`, `path`, `pullSecret`) is the complete shape.

**Git sync:**
```yaml
spec:
  sync:
    kind: GitRepository
    url: "https://github.com/my-org/fleet.git"
    ref: "refs/heads/main"
    path: "clusters/production"
    pullSecret: "git-credentials"
```

The sync creates an OCIRepository/GitRepository named `flux-system` and a root
Kustomization named `flux-system` that applies manifests from the specified path.

**OCI sync with Cosign verification** — use `kustomize.patches` to add verification
to the auto-created OCIRepository:

```yaml
spec:
  kustomize:
    patches:
      - target:
          kind: OCIRepository
          name: flux-system
        patch: |
          - op: add
            path: /spec/verify
            value:
              provider: cosign
              matchOIDCIdentity:
              - issuer: ^https://token\.actions\.githubusercontent\.com$
                subject: ^https://github\.com/my-org/fleet/\.github/workflows/release\.yaml@refs/tags/v\d+\.\d+\.\d+$
```

### Runtime Configuration with ConfigMap

Create a ConfigMap with cluster-specific variables. This ConfigMap is referenced by
Kustomizations via `postBuild.substituteFrom` and by ResourceSets via `${VAR}` syntax
in inputs.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: flux-runtime-info
  namespace: flux-system
  labels:
    toolkit.fluxcd.io/runtime: "true"
    reconcile.fluxcd.io/watch: Enabled
  annotations:
    kustomize.toolkit.fluxcd.io/ssa: "Merge"
data:
  ARTIFACT_TAG: latest
  ENVIRONMENT: staging
  CLUSTER_NAME: staging-1
  CLUSTER_DOMAIN: staging.example.com
```

Key annotations and labels:
- `reconcile.fluxcd.io/watch: Enabled` — triggers immediate reconciliation of dependents when data changes
- `kustomize.toolkit.fluxcd.io/ssa: "Merge"` — merge updates instead of replacing (preserves fields from other controllers)

The ConfigMap is distributed to tenant namespaces using ResourceSet's `copyFrom` annotation:
```yaml
metadata:
  annotations:
    fluxcd.controlplane.io/copyFrom: "flux-system/flux-runtime-info"
  labels:
    reconcile.fluxcd.io/watch: Enabled
```

### Controller Sharding

`spec.sharding` horizontally partitions reconciliation across multiple controller replicas.
Each shard runs a dedicated set of controllers that only process resources carrying a matching
shard label, spreading load on clusters with very large numbers of Flux resources.

```yaml
spec:
  sharding:
    key: sharding.fluxcd.io/key   # label key selecting a shard (default)
    shards:
      - shard1
      - shard2
    storage: ephemeral            # ephemeral (default) or persistent
```

Assign a resource to a shard by labelling it, e.g. `sharding.fluxcd.io/key: shard1`.

| Field | Type | Description |
|-------|------|-------------|
| `sharding.key` | string | Label key used to shard resources (default `sharding.fluxcd.io/key`) |
| `sharding.shards` | []string | Shard names (at least one) |
| `sharding.storage` | string | `ephemeral` (emptyDir, default) or `persistent` (PVC). When `persistent`, the top-level `spec.storage` must also be set |

Invalid sharding configurations — such as `storage: persistent` without a `spec.storage`
PVC spec — are rejected by the operator's admission validation.

### Kustomize Patches

Customize Flux controller Deployments, ServiceAccounts, or other resources created by the operator:

```yaml
spec:
  kustomize:
    patches:
      - target:
          kind: Deployment
          name: kustomize-controller
        patch: |
          - op: add
            path: /spec/template/spec/containers/0/args/-
            value: --concurrent=20
```

## FluxReport

Read-only resource reflecting the observed state of the Flux installation. Auto-generated
and updated by the operator at regular intervals (default: every 5 minutes).

All report data is stored under `.spec` (not `.status`). The `.status` subresource holds
only reconciliation conditions (the `Ready` condition). Query report data via `.spec.*`
paths — e.g. `.spec.sync.ready`, **not** `.status.sync.ready`.

```yaml
spec:
  distribution:
    version: "2.5.0"
    status: "Installed"
    managedBy: "flux-operator"
  components:
    - name: source-controller
      ready: true
      image: ghcr.io/fluxcd/source-controller:v1.5.0@sha256:...
    - name: kustomize-controller
      ready: true
  reconcilers:
    - apiVersion: kustomize.toolkit.fluxcd.io/v1
      kind: Kustomization
      stats:
        running: 10
        failing: 0
        suspended: 1
  sync:
    ready: true
    id: flux-system/flux-system
    source: oci://ghcr.io/my-org/fleet
    path: clusters/production
```

Configure FluxReport with annotations on the resource:
- `fluxcd.controlplane.io/reconcile: enabled|disabled` — enable/disable reporting
- `fluxcd.controlplane.io/reconcileEvery: 5m` — reporting interval
