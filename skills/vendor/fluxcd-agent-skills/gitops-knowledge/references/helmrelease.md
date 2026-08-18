# HelmRelease Reference

`apiVersion: helm.toolkit.fluxcd.io/v2` — managed by helm-controller.

HelmRelease installs, upgrades, tests, and manages Helm releases with drift detection
and automated remediation.

**Contents:** [Canonical YAML — Chart from HTTPS Repo](#canonical-yaml--chart-from-https-repo) | [Canonical YAML — Chart from OCI Registry (Recommended)](#canonical-yaml--chart-from-oci-registry-recommended) | [Chart Source — Mutual Exclusivity](#chart-source--mutual-exclusivity) | [Key Spec Fields](#key-spec-fields) | [Values](#values) | [Install and Upgrade Strategy](#install-and-upgrade-strategy) | [Drift Detection](#drift-detection) | [Post-Renderers](#post-renderers) | [Test Configuration](#test-configuration) | [Dependencies](#dependencies) | [Health Check Expressions](#health-check-expressions) | [Remote Cluster Deployment](#remote-cluster-deployment) | [CRD Lifecycle](#crd-lifecycle) | [Uninstall Configuration](#uninstall-configuration) | [Status](#status)

## Canonical YAML — Chart from HTTPS Repo

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: metrics-server
  namespace: kube-system
spec:
  interval: 30m
  chart:
    spec:
      chart: metrics-server
      version: "3.x"
      sourceRef:
        kind: HelmRepository
        name: metrics-server
      interval: 10m
  values:
    args:
      - --kubelet-insecure-tls
```

## Canonical YAML — Chart from OCI Registry (Recommended)

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata:
  name: cert-manager-chart
  namespace: cert-manager
spec:
  interval: 1h
  url: oci://quay.io/jetstack/charts/cert-manager
  layerSelector:
    mediaType: "application/vnd.cncf.helm.chart.content.v1.tar+gzip"
    operation: copy
  ref:
    semver: "1.x"
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: cert-manager
  namespace: cert-manager
spec:
  interval: 1h
  chartRef:
    kind: OCIRepository
    name: cert-manager-chart
  install:
    strategy:
      name: RetryOnFailure
  upgrade:
    strategy:
      name: RetryOnFailure
  values:
    crds:
      enabled: true
      keep: false
```

## Chart Source — Mutual Exclusivity

**Option A — `spec.chart.spec`** (auto-creates a HelmChart):
```yaml
spec:
  chart:
    spec:
      chart: metrics-server   # chart name
      version: "3.x"         # semver constraint
      sourceRef:
        kind: HelmRepository  # or GitRepository, Bucket
        name: metrics-server
      interval: 10m           # chart fetch interval
```

**Option B — `spec.chartRef`** (references existing OCIRepository or HelmChart):
```yaml
spec:
  chartRef:
    kind: OCIRepository      # or HelmChart
    name: cert-manager-chart
    namespace: cert-manager  # optional, for cross-namespace
```

These are **mutually exclusive** — use one or the other, never both.

**When to use which:**
- `chart.spec` with HelmRepository: Traditional HTTPS Helm repos (e.g., Bitnami)
- `chartRef` with OCIRepository: OCI registries (recommended — supports Cosign verification)
- `chart.spec` with GitRepository: Charts stored alongside application code

## Key Spec Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `interval` | duration | yes | Reconciliation interval |
| `releaseName` | string | no | Helm release name (defaults to `metadata.name`) |
| `targetNamespace` | string | no | Namespace for the Helm release. Prefer deploying into `metadata.namespace` and creating that namespace in the parent Kustomization/ResourceSet (see best-practices.md); if set, also set `storageNamespace` to match so the Helm release storage lives with the workloads |
| `serviceAccountName` | string | no | Service account for impersonation |
| `timeout` | duration | no | Timeout for Helm operations |
| `waitStrategy.name` | string | no | Readiness wait engine: `poller` (default, uses kstatus polling) or `legacy` (Helm v3 waiting logic) |
| `suspend` | bool | no | Pause reconciliation |

## Values

**Inline values:**
```yaml
spec:
  values:
    replicaCount: 3
    image:
      tag: v1.2.3
```

**Values from ConfigMap/Secret:**
```yaml
spec:
  valuesFrom:
    - kind: ConfigMap
      name: app-defaults
      valuesKey: values.yaml   # key in ConfigMap (default: values.yaml)
      targetPath: ""           # optional dot path (e.g., "ingress.hosts")
    - kind: Secret
      name: app-secrets
      valuesKey: db-password
      targetPath: database.password
```

**Literal values (`helm --set-literal`):** set `literal: true` together with `targetPath`
to merge the referenced value verbatim, without interpreting Helm's `--set` syntax (commas,
brackets, dots, equal signs). Use this when a value contains characters Helm would otherwise
split, such as a JSON blob or a comma-separated string:
```yaml
spec:
  valuesFrom:
    - kind: ConfigMap
      name: app-config
      valuesKey: allowed-origins   # e.g. "https://a.com,https://b.com"
      targetPath: cors.origins
      literal: true                # merged as a single literal string
```

Merge order: `valuesFrom` entries are merged in order, then `values` inline is merged on top.

## Install and Upgrade Strategy

Always use `RetryOnFailure` — it retries failed operations without uninstalling or rolling back,
which avoids downtime and data loss:

```yaml
spec:
  install:
    timeout: 10m
    crds: Create             # Create, Skip, CreateReplace
    strategy:
      name: RetryOnFailure
      retryInterval: 5m
  upgrade:
    timeout: 10m
    crds: CreateReplace      # Create, Skip, CreateReplace
    strategy:
      name: RetryOnFailure
      retryInterval: 5m
```

## Drift Detection

Detects and optionally corrects configuration drift between the Helm release and cluster state.

```yaml
spec:
  driftDetection:
    mode: enabled            # disabled (default), warn, or enabled
    ignore:
      - paths:
          - /spec/replicas
        target:
          kind: Deployment
```

**Modes:**
- `disabled` (default) — no drift detection
- `warn` — detect drift and emit events but do NOT correct it
- `enabled` — detect and correct drift on every reconciliation

**Ignore rules** prevent specific fields from being corrected. Useful for fields managed
by HPA or other controllers:
```yaml
spec:
  driftDetection:
    mode: enabled
    ignore:
      - paths: ["/spec/replicas"]
        target:
          kind: Deployment
      - paths: ["/metadata/annotations"]
        target:
          kind: Service
          name: my-service
```

## Post-Renderers

Apply Kustomize patches after Helm template rendering:

```yaml
spec:
  postRenderers:
    - kustomize:
        patches:
          - target:
              kind: Deployment
              name: my-app
            patch: |
              - op: add
                path: /spec/template/metadata/annotations/sidecar.istio.io~1inject
                value: "true"
        images:
          - name: original-image
            newName: my-registry/my-image
            newTag: custom-tag
```

Post-renderers are applied in order. Each renderer's output feeds into the next.

**Hook handling (`postRenderStrategy`):** controls whether Helm hooks are passed through
the post-renderers. This matters for Helm 4, where hooks are rendered alongside templates:

```yaml
spec:
  postRenderStrategy: combined   # nohooks | combined | separate
```

- `combined` (default) — hooks and templates are sent to post-renderers together (Helm CLI default)
- `nohooks` — hooks are NOT sent to post-renderers (Helm 3 behavior; also the default when the
  `UseHelm3Defaults` feature gate is enabled)
- `separate` — hooks and templates are sent in separate streams

## Test Configuration

Run Helm test hooks after install/upgrade:

```yaml
spec:
  test:
    enable: true
    ignoreFailures: false    # treat test failures as release failures
```

## Dependencies

```yaml
spec:
  dependsOn:
    - name: cert-manager
      namespace: cert-manager
    - name: ingress-controller
```

The HelmRelease waits until all dependencies are Ready before proceeding.

## Health Check Expressions

CEL expressions for evaluating health of custom resources deployed by the Helm chart.
Only evaluated when wait is enabled (fields: `current` required, `inProgress` and `failed` optional):

```yaml
spec:
  healthCheckExprs:
    - apiVersion: pkg.crossplane.io/v1
      kind: Provider
      failed: status.conditions.filter(e, e.type == 'Healthy').all(e, e.status == 'False')
      current: status.conditions.filter(e, e.type == 'Healthy').all(e, e.status == 'True')
    - apiVersion: iam.aws.crossplane.io/v1beta1
      kind: Role
      failed: status.conditions.filter(e, e.type == 'Synced').all(e, e.status == 'False' && e.reason == 'ReconcileError')
      current: status.conditions.filter(e, e.type == 'Ready').all(e, e.status == 'True')
    - apiVersion: keda.sh/v1alpha1
      kind: ScaledObject
      failed: status.conditions.filter(e, e.type == 'Ready').all(e, e.status == 'False')
      current: status.conditions.filter(e, e.type == 'Ready').all(e, e.status == 'True')
```

## Remote Cluster Deployment

```yaml
spec:
  kubeConfig:
    secretRef:
      name: remote-cluster
      key: value
```

## CRD Lifecycle

Control how Helm manages CRDs:

| Value | Install | Upgrade | Description |
|-------|---------|---------|-------------|
| `Create` | Install CRDs | Skip CRDs | Default — create on install, leave on upgrade |
| `Skip` | Skip CRDs | Skip CRDs | Never touch CRDs (manage separately) |
| `CreateReplace` | Install CRDs | Replace CRDs | Create and update CRDs (use with caution) |

Set per operation:
```yaml
spec:
  install:
    crds: Create
  upgrade:
    crds: CreateReplace
```

## Uninstall Configuration

```yaml
spec:
  uninstall:
    keepHistory: false       # keep Helm release history after uninstall
    deletionPropagation: background  # background, foreground, orphan
    timeout: 5m
```

## Status

```yaml
status:
  conditions:
    - type: Ready
      status: "True"
      reason: UpgradeSucceeded
  history:
    - chartName: nginx
      chartVersion: 18.1.0
      configDigest: sha256:abc123
      firstDeployed: "2024-01-01T00:00:00Z"
      lastDeployed: "2024-01-15T00:00:00Z"
      status: deployed
  lastAppliedRevision: 18.1.0
  lastAttemptedRevision: 18.1.0
```
