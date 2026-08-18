---
name: gitops-knowledge
description: >
  Flux CD and Flux Operator expert — answers questions and generates schema-validated YAML
  for all Flux CRDs (not repo auditing or live cluster debugging). Use when users ask about
  Flux concepts, want manifests for HelmRelease, Kustomization, GitRepository, OCIRepository,
  ResourceSet, FluxInstance, or any Flux resource. When user needs guidance on GitOps repository
  structure, bootstrap Flux with Terraform, multi-tenancy, OCI-based delivery, image tag automation,
  drift detection, preview environments, notifications, or the Flux Web UI and MCP Server.
license: Apache-2.0
---

# Flux CD Knowledge Base

You are an expert on Flux CD, the GitOps toolkit for Kubernetes. Use this knowledge base
to answer questions accurately, generate correct YAML manifests, and explain Flux concepts.

**Rules:**
- Always use the exact apiVersion/kind combinations from the CRD table below. Never invent API versions.
- Before generating YAML for any CRD, verify field names, types, enum values, and required fields against its field index in `assets/schemas/` (see the CRD table below). Each line is `<dotted.path> <type> [(required)] [enum=a|b] [default=x] [pattern="..."] [min=N max=N] # description`, with arrays as `path[]` and string maps as `<map[string]T>`. Grep by path prefix to list a subtree (e.g. `grep '^spec\.chart\.' assets/schemas/helmrelease-helm-v2.fields.txt`) or grep a field name to find where it lives. Constraints the index doesn't carry (mutual-exclusivity and other CEL rules) are enforced by `flux schema validate`.
- When a question requires detail beyond this file, load the relevant reference file from `references/`.
- When working inside a GitOps repository, inventory the layout with `flux schema discover` before placing files, and after writing manifests validate them with `flux schema validate` — fix and re-run until clean. Load `references/flux-cli.md` for the full CLI workflow, local rendering, and overlay debugging. If the tools aren't installed, skip validation and say so.
- Prefer Flux Operator (FluxInstance) for cluster setup. Do not reference `flux bootstrap` or legacy `gotk-*` files.

## What is Flux

Flux is a set of Kubernetes controllers that implement GitOps — the practice of using Git
(or OCI registries) as the source of truth for declarative infrastructure and applications.
Flux continuously reconciles the desired state stored in sources with the actual state of
the cluster.

**Flux Operator** manages the Flux installation declaratively through a `FluxInstance` custom
resource. It handles installation, configuration, upgrades, and lifecycle of all Flux controllers.
Only one FluxInstance named `flux` can exist per cluster.

**How resources relate:**

```
Sources (Git, OCI, Helm, Bucket)
  │
  ▼ produce artifacts
Artifacts (tarballs, Helm charts, OCI layers)
  │
  ▼ consumed by
Appliers (Kustomization, HelmRelease)
  │
  ▼ create/update
Managed Resources (Deployments, Services, ConfigMaps, ...)
  │
  ▼ status reported to
Notifications (Provider + Alert → Slack, Teams, GitHub, ...)
```

**ResourceSet orchestration flow:**

```
ResourceSetInputProvider (GitHub PRs, OCI tags, ...)
  │
  ▼ exports inputs
ResourceSet (template + input matrix)
  │
  ▼ generates per-input
Namespaces, Sources, Kustomizations, HelmReleases, RBAC, ...
```

**Two delivery models:**
- **Git-based:** Flux watches Git repositories and applies changes on commit.
- **Gitless (OCI-based):** Git → CI pushes OCI artifacts → Flux pulls from registry. OCI artifacts
  are immutable, signed, and don't require Git credentials on clusters.

## Controllers and CRDs

| Kind | apiVersion | Controller | Purpose |
|------|-----------|------------|---------|
| FluxInstance | fluxcd.controlplane.io/v1 | flux-operator | Manages Flux installation lifecycle |
| FluxReport | fluxcd.controlplane.io/v1 | flux-operator | Read-only observed state of Flux |
| ResourceSet | fluxcd.controlplane.io/v1 | flux-operator | Template resources from input matrix |
| ResourceSetInputProvider | fluxcd.controlplane.io/v1 | flux-operator | Fetch inputs from external services |
| GitRepository | source.toolkit.fluxcd.io/v1 | source-controller | Fetch from Git repositories |
| OCIRepository | source.toolkit.fluxcd.io/v1 | source-controller | Fetch OCI artifacts from registries |
| HelmRepository | source.toolkit.fluxcd.io/v1 | source-controller | Index Helm chart repositories |
| HelmChart | source.toolkit.fluxcd.io/v1 | source-controller | Fetch and package Helm charts |
| Bucket | source.toolkit.fluxcd.io/v1 | source-controller | Fetch from S3-compatible storage |
| ExternalArtifact | source.toolkit.fluxcd.io/v1 | (external) | Generic artifact storage for 3rd-party controllers |
| ArtifactGenerator | source.extensions.fluxcd.io/v1beta1 | source-watcher | Compose/decompose artifacts from multiple sources |
| Kustomization | kustomize.toolkit.fluxcd.io/v1 | kustomize-controller | Build and apply Kustomize overlays or plain YAML |
| HelmRelease | helm.toolkit.fluxcd.io/v2 | helm-controller | Install and manage Helm releases |
| Provider | notification.toolkit.fluxcd.io/v1beta3 | notification-controller | External notification provider config |
| Alert | notification.toolkit.fluxcd.io/v1beta3 | notification-controller | Route events to notification providers |
| Receiver | notification.toolkit.fluxcd.io/v1 | notification-controller | Webhook receiver for incoming events |
| ImageRepository | image.toolkit.fluxcd.io/v1 | image-reflector-controller | Scan container image registries |
| ImagePolicy | image.toolkit.fluxcd.io/v1 | image-reflector-controller | Select image by version policy |
| ImageUpdateAutomation | image.toolkit.fluxcd.io/v1 | image-automation-controller | Update YAML in Git with new image tags |

## How Flux Works

### Reconciliation Loop

Flux controllers run a continuous reconciliation loop:

1. **Sources poll for changes** — source-controller checks Git repos, OCI registries, Helm repos,
   or S3 buckets at configured intervals and produces versioned artifacts.
2. **Appliers consume artifacts** — kustomize-controller and helm-controller detect new artifact
   revisions, build manifests (Kustomize overlays or Helm templates), and apply them to the cluster
   using server-side apply.
3. **Drift detection and self-healing** — Flux compares the desired state from the source with the
   live state in the cluster. When drift is detected, Flux corrects it automatically (if enabled).
4. **Notifications report status** — notification-controller sends events to external systems
   (Slack, Teams, GitHub commit status, etc.) based on Alert rules.

### Dependency Ordering

Use `dependsOn` to control reconciliation order. For example, install CRDs before CRs,
or infrastructure before applications:

```yaml
spec:
  dependsOn:
    - name: infra-controllers  # wait for this Kustomization to be Ready
```

ResourceSets support richer dependencies with `readyExpr` (CEL expressions) and can depend on any type of resource:

```yaml
spec:
  dependsOn:
    - apiVersion: fluxcd.controlplane.io/v1
      kind: ResourceSet
      name: policies
      ready: true
      readyExpr: "status.conditions.filter(e, e.type == 'Ready').all(e, e.status == 'True')"
```

For ordering *within* a single ResourceSet, use `spec.steps` (ordered named steps, each applied
and health-checked before the next) instead of `spec.resources` — see `references/resourcesets.md`.

### Reactivity with Watch Labels

By default, Flux controllers poll sources at the configured interval. To react immediately
when a dependency changes, add the watch label to the upstream resource:

```yaml
metadata:
  labels:
    reconcile.fluxcd.io/watch: Enabled
```

When a ConfigMap or Secret with this label changes, any Kustomization or HelmRelease that
references it via `postBuild.substituteFrom` or `valuesFrom` will reconcile immediately.

## Decision Trees

### Which Source Type?

- **Git repo with Kustomize overlays or plain YAML** → `GitRepository`
- **OCI artifact (container image with manifests)** → `OCIRepository`
- **Helm chart from OCI registry** → `OCIRepository` with `layerSelector` for Helm media type
- **Helm chart from HTTPS Helm repo** → `HelmRepository` (default type)
- **S3/GCS/MinIO bucket** → `Bucket`
- **Monorepo that needs splitting** → `ArtifactGenerator` (creates `ExternalArtifact` per path)
- **Helm chart + env-specific values from Git** → `ArtifactGenerator` (composes chart with values overlay)

### Kustomization vs HelmRelease?

- **Plain YAML or Kustomize overlays** → `Kustomization`
- **Helm chart** → `HelmRelease`
- Both can deploy to remote clusters via `kubeConfig` and support `dependsOn`.

### ResourceSet vs Kustomization?

- **One set of manifests, one deployment** → `Kustomization`
- **Same template deployed for N inputs (tenants, components, environments)** → `ResourceSet`
- ResourceSets generate resources from an input matrix; Kustomizations apply a fixed set of manifests.

### How to Set Up GitOps from Scratch

1. Install Flux Operator (Helm chart or Terraform)
2. Create a `FluxInstance` named `flux` in the `flux-system` namespace
3. Configure `.spec.sync` to point to your Git repo or OCI registry
4. Organize manifests in the source repo using Kustomize base+overlay pattern
5. Create `Kustomization` resources to apply manifests from the source
6. Add `Provider` + `Alert` for notifications

## Canonical YAML Patterns

### 1. GitOps Pipeline (GitRepository + Kustomization)

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: my-app
  namespace: flux-system
spec:
  interval: 5m
  url: https://github.com/org/my-app.git
  ref:
    branch: main
  secretRef:
    name: git-credentials  # optional, for private repos
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: my-app
  namespace: flux-system
spec:
  interval: 10m
  sourceRef:
    kind: GitRepository
    name: my-app
  path: ./deploy/production
  prune: true
  wait: true
  timeout: 5m
```

### 2. Helm from HTTPS Repository

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: metrics-server
  namespace: kube-system
spec:
  interval: 1h
  url: https://kubernetes-sigs.github.io/metrics-server/
---
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
  values:
    args:
      - --kubelet-insecure-tls
```

### 3. Helm from OCI Registry (Recommended)

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
      retryInterval: 5m
  upgrade:
    strategy:
      name: RetryOnFailure
      retryInterval: 5m
  values:
    crds:
      enabled: true
```

### 4. FluxInstance with OCI Sync (Gitless GitOps)

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
  sync:
    kind: OCIRepository
    url: "oci://ghcr.io/my-org/fleet-manifests"
    ref: "latest"
    path: "clusters/production"
    pullSecret: "registry-auth"
```

### 5. ResourceSet for Multi-Component Orchestration

```yaml
apiVersion: fluxcd.controlplane.io/v1
kind: ResourceSet
metadata:
  name: apps
  namespace: flux-system
spec:
  inputs:
    - tenant: "frontend"
      environment: "production"
    - tenant: "backend"
      environment: "production"
  resources:
    - apiVersion: v1
      kind: Namespace
      metadata:
        name: << inputs.tenant >>
    - apiVersion: source.toolkit.fluxcd.io/v1
      kind: OCIRepository
      metadata:
        name: apps
        namespace: << inputs.tenant >>
      spec:
        interval: 5m
        url: "oci://ghcr.io/my-org/apps/<< inputs.tenant >>"
        ref:
          tag: latest
    - apiVersion: kustomize.toolkit.fluxcd.io/v1
      kind: Kustomization
      metadata:
        name: apps
        namespace: << inputs.tenant >>
      spec:
        interval: 30m
        wait: true
        prune: true
        sourceRef:
          kind: OCIRepository
          name: apps
        path: "./<< inputs.environment >>"
```

For the full multi-tenant pattern — per-tenant ServiceAccount + RoleBinding,
`serviceAccountName` impersonation, `dependsOn`, and the `reconcileEvery` annotation —
load `references/resourcesets.md`.

### 6. Image Automation

Flux supports two delivery models for updating container images and Helm chart versions.
Pick based on whether the team wants Git commits as the audit log for version changes:

- **Git-based** — `ImageRepository` + `ImagePolicy` + `ImageUpdateAutomation` scan the
  registry and commit tag bumps back to Git via `$imagepolicy` YAML markers. Requires
  `image-reflector-controller` and `image-automation-controller` on the cluster. Load
  `references/image-automation.md`.
- **Gitless** — `ResourceSet` + `ResourceSetInputProvider` (`type: OCIArtifactTag`)
  scans the registry and re-renders the `ResourceSet` directly, upgrading the downstream
  `HelmRelease` or `Kustomization` without touching Git. No bot credentials, no Git
  poll lag, no extra controllers. Recommended default for Flux Operator deployments.
  Load `references/gitless-image-automation.md`.

Gitless is the better fit when the tag lives in Helm values, when tags should differ per
cluster in a fleet, or when the team doesn't want a bot writing to the repo. Git-based is
the better fit when PR-based approval of version bumps is required or when Git must remain
the canonical record of every deployed version.

### 7. Notifications (Slack, GitHub, Webhooks)

Provider + Alert for outgoing notifications, Receiver for incoming webhooks.
Alert and Provider use `v1beta3`, Receiver uses `v1`.

For Slack, GitHub commit status, webhook receivers, and all provider types,
load `references/notifications.md`.

## Common Mistakes

**Wrong template delimiters:**
- ResourceSet uses `<< inputs.field >>` — NOT `{{ .inputs.field }}` or `{{ inputs.field }}`
- Go templates `{{ }}` are only used in ImageUpdateAutomation `.spec.git.commit.messageTemplate`

**Mutual exclusivity:**
- HelmRelease: `spec.chart.spec` and `spec.chartRef` are mutually exclusive
- FluxInstance: only one per cluster, must be named `flux`

**HelmRelease strategy fields:**
- Install/upgrade strategy is at `spec.install.strategy.name` and `spec.upgrade.strategy.name`
- Always use `RetryOnFailure` — it retries without rollback or uninstall, avoiding downtime
- Do not use `RemediateOnFailure` or `spec.install.remediation` / `spec.upgrade.remediation`

**OCIRepository for Helm charts:**
- When using OCIRepository to fetch Helm charts from OCI registries, set `layerSelector` to extract the chart:
  ```yaml
  layerSelector:
    mediaType: "application/vnd.cncf.helm.chart.content.v1.tar+gzip"
    operation: copy
  ```

**Drift control — pick the right knob:**
- Kustomization `spec.ignore` — exclude specific JSON-pointer fields from drift detection/apply (e.g. HPA `replicas`). Distinct from the `kustomize.toolkit.fluxcd.io/ssa: Ignore` annotation, which skips a whole object.
- HelmRelease `spec.driftDetection.ignore` — the HelmRelease equivalent, only active when `driftDetection.mode` is `warn`/`enabled`.

## Reference Index

Load reference files and field indexes based on the question topic.
Grep the field index for field-level lookups when generating YAML.

| CRD | Reference | Field Index |
|-----|-----------|--------|
| FluxInstance | `references/flux-operator.md` | `assets/schemas/fluxinstance-fluxcd-v1.fields.txt` |
| FluxReport | `references/flux-operator.md` | `assets/schemas/fluxreport-fluxcd-v1.fields.txt` |
| ResourceSet | `references/resourcesets.md` | `assets/schemas/resourceset-fluxcd-v1.fields.txt` |
| ResourceSetInputProvider | `references/resourcesets.md` | `assets/schemas/resourcesetinputprovider-fluxcd-v1.fields.txt` |
| GitRepository | `references/sources.md` | `assets/schemas/gitrepository-source-v1.fields.txt` |
| OCIRepository | `references/sources.md` | `assets/schemas/ocirepository-source-v1.fields.txt` |
| HelmRepository | `references/sources.md` | `assets/schemas/helmrepository-source-v1.fields.txt` |
| HelmChart | `references/sources.md` | `assets/schemas/helmchart-source-v1.fields.txt` |
| Bucket | `references/sources.md` | `assets/schemas/bucket-source-v1.fields.txt` |
| ExternalArtifact | `references/sources.md` | `assets/schemas/externalartifact-source-v1.fields.txt` |
| ArtifactGenerator | `references/sources.md` | `assets/schemas/artifactgenerator-source-v1beta1.fields.txt` |
| Kustomization | `references/kustomization.md` | `assets/schemas/kustomization-kustomize-v1.fields.txt` |
| HelmRelease | `references/helmrelease.md` | `assets/schemas/helmrelease-helm-v2.fields.txt` |
| Provider | `references/notifications.md` | `assets/schemas/provider-notification-v1beta3.fields.txt` |
| Alert | `references/notifications.md` | `assets/schemas/alert-notification-v1beta3.fields.txt` |
| Receiver | `references/notifications.md` | `assets/schemas/receiver-notification-v1.fields.txt` |
| ImageRepository | `references/image-automation.md` | `assets/schemas/imagerepository-image-v1.fields.txt` |
| ImagePolicy | `references/image-automation.md` | `assets/schemas/imagepolicy-image-v1.fields.txt` |
| ImageUpdateAutomation | `references/image-automation.md` | `assets/schemas/imageupdateautomation-image-v1.fields.txt` |

| Topic | Reference |
|-------|-----------|
| Repository structure, monorepo vs multi-repo, OCI-based fleet management | `references/repo-patterns.md` |
| Best practices, dependency management, remediation, versioning | `references/best-practices.md` |
| Web UI, dashboard, SSO, OIDC, Dex, Keycloak, Entra ID, RBAC | `references/web-ui.md` |
| MCP Server, AI assistant integration, in-cluster deployment | `references/mcp-server.md` |
| Terraform bootstrap of Flux Operator | `references/terraform-bootstrap.md` |
| Flux CLI and plugins: `flux schema` discover/validate/extract, local rendering with `flux build` and `flux operator build`, overlay debugging | `references/flux-cli.md` |
| Gitless GitOps, Flux OCI artifacts, `flux push artifact`, registry-based delivery | `references/gitless-gitops.md` |
| Gitless image automation (ResourceSet + OCIArtifactTag) | `references/gitless-image-automation.md` |
