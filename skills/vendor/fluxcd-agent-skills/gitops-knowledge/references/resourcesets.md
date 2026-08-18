# ResourceSet Reference

`apiVersion: fluxcd.controlplane.io/v1` — managed by flux-operator.

ResourceSet generates Kubernetes resources from a matrix of input values using a template-based
approach. It is the primary mechanism for multi-tenant orchestration, fleet management, and
self-service platforms.

**Contents:** [Canonical YAML](#canonical-yaml) | [Key Spec Fields](#key-spec-fields) | [Template Syntax](#template-syntax) | [Testing ResourceSets Locally](#testing-resourcesets-locally) | [Input Strategies](#input-strategies) | [Dependencies](#dependencies) | [Step-Based Reconciliation](#step-based-reconciliation) | [Advanced Features](#advanced-features) | [Built-in Input Fields](#built-in-input-fields) | [ResourceSetInputProvider](#resourcesetinputprovider) | [Use Cases](#use-cases)

## Canonical YAML

Based on the Gitless reference architecture fleet pattern — deploys per-tenant namespaces with
OCIRepository sources and Kustomizations:

```yaml
apiVersion: fluxcd.controlplane.io/v1
kind: ResourceSet
metadata:
  name: apps
  namespace: flux-system
  annotations:
    fluxcd.controlplane.io/reconcileEvery: "5m"
spec:
  dependsOn:
    - apiVersion: fluxcd.controlplane.io/v1
      kind: ResourceSet
      name: infra
      ready: true
  inputs:
    - tenant: "frontend"
      tag: "${ARTIFACT_TAG}"
      environment: "${ENVIRONMENT}"
    - tenant: "backend"
      tag: "${ARTIFACT_TAG}"
      environment: "${ENVIRONMENT}"
  resources:
    - apiVersion: v1
      kind: Namespace
      metadata:
        name: << inputs.tenant >>
        labels:
          toolkit.fluxcd.io/role: "tenant"
    - apiVersion: v1
      kind: ConfigMap
      metadata:
        name: flux-runtime-info
        namespace: << inputs.tenant >>
        annotations:
          fluxcd.controlplane.io/copyFrom: "flux-system/flux-runtime-info"
        labels:
          reconcile.fluxcd.io/watch: Enabled
    - apiVersion: v1
      kind: Secret
      metadata:
        name: registry-auth
        namespace: << inputs.tenant >>
        annotations:
          fluxcd.controlplane.io/copyFrom: "flux-system/registry-auth"
      type: kubernetes.io/dockerconfigjson
    - apiVersion: v1
      kind: ServiceAccount
      metadata:
        name: flux
        namespace: << inputs.tenant >>
      imagePullSecrets:
        - name: registry-auth
    - apiVersion: rbac.authorization.k8s.io/v1
      kind: RoleBinding
      metadata:
        name: flux
        namespace: << inputs.tenant >>
      roleRef:
        apiGroup: rbac.authorization.k8s.io
        kind: ClusterRole
        name: admin
      subjects:
        - kind: ServiceAccount
          name: flux
          namespace: << inputs.tenant >>
    - apiVersion: source.toolkit.fluxcd.io/v1
      kind: OCIRepository
      metadata:
        name: apps
        namespace: << inputs.tenant >>
      spec:
        interval: 5m
        serviceAccountName: flux
        url: "oci://ghcr.io/my-org/apps/<< inputs.tenant >>"
        ref:
          tag: << inputs.tag >>
    - apiVersion: kustomize.toolkit.fluxcd.io/v1
      kind: Kustomization
      metadata:
        name: apps
        namespace: << inputs.tenant >>
      spec:
        targetNamespace: << inputs.tenant >>
        serviceAccountName: flux
        interval: 30m
        retryInterval: 5m
        wait: true
        timeout: 5m
        sourceRef:
          kind: OCIRepository
          name: apps
        path: "./<< inputs.environment >>"
        prune: true
        postBuild:
          substituteFrom:
            - kind: ConfigMap
              name: flux-runtime-info
```

## Key Spec Fields

| Field | Type | Description |
|-------|------|-------------|
| `inputs` | array | List of input value maps — each entry generates one set of resources |
| `inputsFrom` | array | References to ResourceSetInputProvider resources |
| `inputStrategy.name` | string | `Flatten` (default) or `Permute` (Cartesian product) |
| `resources` | array | Templated Kubernetes resource definitions |
| `resourcesTemplate` | string | Go-template string rendered as multi-document YAML (alternative to `resources`) |
| `steps` | array | Ordered, named reconciliation steps — each applied and health-checked before the next (mutually exclusive with `resources`/`resourcesTemplate`) |
| `commonMetadata` | object | Labels/annotations applied to all generated resources |
| `dependsOn` | array | Prerequisites with optional readiness checks |

## Template Syntax

**Delimiters:** `<< >>` — NOT `{{ }}`

| Expression | Description |
|-----------|-------------|
| `<< inputs.name >>` | Simple field substitution |
| `<< inputs.name \| quote >>` | Quote the value (wraps in double quotes) |
| `<< inputs.replicas \| int >>` | Convert to integer (for numeric YAML fields) |
| `<< inputs.config \| toYaml \| nindent 4 >>` | Render as YAML with indentation |
| `<< inputs.config \| toJson >>` | Render as JSON string |
| `<< inputs.name \| slugify >>` | Convert to DNS-safe slug |
| `<< inputs.labels \| get "app" >>` | Get value from nested map |
| `<< inputs.tag \| default "latest" >>` | Default value if empty |
| `<< inputs.name \| upper >>` | Convert to uppercase |
| `<< inputs.name \| lower >>` | Convert to lowercase |
| `<< inputs.name \| trimSuffix "-app" >>` | Remove suffix |

Template functions come from slim-sprig (a subset of Go's sprig template functions).

**Important:** Template expressions are evaluated per input entry. For each entry in
`inputs`, the entire `resources` array is rendered once.

## Testing ResourceSets Locally

Render the generated Kubernetes objects without a cluster using the Flux CLI:

```shell
# Inline inputs (spec.inputs) — renders directly
flux operator build resourceset -f resourceset.yaml

# Inputs from a provider (spec.inputsFrom) — supply the exported inputs from a file
flux operator build resourceset -f resourceset.yaml --inputs-from inputs.yaml

# Or supply Static ResourceSetInputProvider manifests
flux operator build resourceset -f resourceset.yaml --inputs-from-provider providers.yaml

# Validate the generated objects against the Flux/Kubernetes schemas
flux operator build resourceset -f resourceset.yaml --inputs-from inputs.yaml | flux schema validate
```

## Input Strategies

### Flatten (Default)

Inputs from `inputs` and `inputsFrom` are concatenated into a flat list.
Each input entry produces one set of resources.

```yaml
spec:
  inputs:
    - tenant: "frontend"
    - tenant: "backend"
  # Produces 2 sets of resources (one per tenant)
```

### Permute (Cartesian Product)

`Permute` computes the Cartesian product of all input sources. In practice, the
**primary reason teams use `Permute` is not the cross-product but the namespaced field
access** it provides: fields from each source are placed under a key named after the
source object, so values from different providers (or from inline `.spec.inputs`)
don't collide. The canonical shape uses `limit: 1` on every
`ResourceSetInputProvider`, yielding exactly one permutation.

**Canonical shape — multiple providers, one permutation.** Combining chart version +
image tag + image tag for a single `HelmRelease` (see
`references/gitless-image-automation.md` for the full image-automation pattern):

```yaml
spec:
  inputStrategy:
    name: Permute
  inputsFrom:
    - kind: ResourceSetInputProvider
      name: chart-version      # limit: 1 → exports one tag
    - kind: ResourceSetInputProvider
      name: image-tag          # limit: 1 → exports one tag+digest
  # 1 × 1 = 1 permutation. Inside templates:
  #   << inputs.chart_version.tag >>
  #   << inputs.image_tag.tag >>@<< inputs.image_tag.digest >>
```

Without `Permute`, both providers' fields would merge into a flat `inputs.tag`, which
would clash. `Permute` keeps them under distinct keys.

**True cross-product — static dimensions × one provider.** When an actual Cartesian
product is wanted, combine an inline `.spec.inputs` list of dimensions with `limit: 1`
providers:

```yaml
spec:
  inputStrategy:
    name: Permute
  inputs:
    - region: us-east
    - region: eu-west
  inputsFrom:
    - kind: ResourceSetInputProvider
      name: image-tag          # limit: 1
  # 2 × 1 = 2 permutations: one HelmRelease per region, both pinned to the current image.
```

**Field access.** Each source's input set is placed under a key derived from the
*normalized name of the object* providing it — **NOT** under its source fields
directly. Normalization: uppercase → lowercase; spaces/punctuation (including `-`) →
underscores; non-alphanumeric removed.

| Object providing inputs | Template key |
|---|---|
| `ResourceSetInputProvider` named `image-tag` | `inputs.image_tag` |
| `ResourceSetInputProvider` named `chart-version` | `inputs.chart_version` |
| Inline `.spec.inputs` on a `ResourceSet` named `my-apps` | `inputs.my_apps` |

Two always-flat accessors exist alongside the namespaced keys:

- `<< inputs.id >>` — auto-generated unique ID per permutation.
- `<< inputs.provider.{apiVersion,kind,name,namespace} >>` — metadata about the source.

**Inline inputs under Permute — common gotcha.** When `.spec.inputs` is set and
`Permute` is on, those inline inputs are keyed under the **ResourceSet's own
normalized name**. So a ResourceSet named `my-apps` with inline input `{region:
us-east}` needs `<< inputs.my_apps.region >>`, not `<< inputs.region >>`. This
differs from `Flatten` (the default), where inline inputs are accessed flat.

**Never omit `limit: 1`.** Exporting multiple tags from a single provider and letting
`Permute` cross them produces N redundant `HelmRelease`s for the same app — not what
you want. The operator stalls the `ResourceSet` at 10,000 permutations as a guard.

## Dependencies

ResourceSets support rich dependency definitions:

```yaml
spec:
  dependsOn:
    # Wait for another ResourceSet to be Ready
    - apiVersion: fluxcd.controlplane.io/v1
      kind: ResourceSet
      name: infra
      namespace: flux-system
      ready: true

    # Wait for a CRD to exist (no readiness check needed)
    - apiVersion: apiextensions.k8s.io/v1
      kind: CustomResourceDefinition
      name: helmreleases.helm.toolkit.fluxcd.io

    # Wait for a Kustomization to be Ready at creation time (no updates needed after that)
    - apiVersion: kustomize.toolkit.fluxcd.io/v1
      kind: Kustomization
      name: infra-configs
      namespace: monitoring
      ready: true
      readyExpr: "status.observedGeneration >= 0"
```

**CEL expressions** in `readyExpr` evaluate against the dependency resource's status.
Common patterns:
- `status.conditions.filter(e, e.type == 'Ready').all(e, e.status == 'True')` — standard Ready check
- `status.observedGeneration >= 0` — resource has been reconciled at least once

## Step-Based Reconciliation

`spec.steps` replaces the flat `resources` list with an **ordered sequence of named steps**.
Each step's resources are applied and health-checked to completion before the next step starts,
giving in-ResourceSet ordering without splitting the work across multiple `dependsOn`-linked
ResourceSets. `steps` is mutually exclusive with `resources` and `resourcesTemplate`, but each
step carries its own `resources` or `resourcesTemplate` (with the same `<< >>` templating and
per-input rendering):

```yaml
apiVersion: fluxcd.controlplane.io/v1
kind: ResourceSet
metadata:
  name: platform
  namespace: flux-system
spec:
  inputs:
    - tenant: team1
  wait: true
  steps:
    - name: tenant             # step 1: create the tenant namespace + RBAC, wait until applied
      timeout: 1m
      resources:
        - apiVersion: v1
          kind: Namespace
          metadata:
            name: << inputs.tenant >>
    - name: sources            # step 2: only after step 1 is healthy
      timeout: 3m
      resources:
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
    - name: apps               # step 3: only after sources are healthy
      timeout: 5m
      resources:
        - apiVersion: kustomize.toolkit.fluxcd.io/v1
          kind: Kustomization
          metadata:
            name: apps
            namespace: << inputs.tenant >>
          spec:
            interval: 30m
            wait: true
            sourceRef:
              kind: OCIRepository
              name: apps
            path: "./"
```

Step names must be unique and DNS-label formatted max 63 chars.
Use `steps` when a single tenant/app's resources have internal ordering requirements;
use `dependsOn` across ResourceSets when whole ResourceSets must be ordered relative to each other.

## Advanced Features

### Conditional Reconciliation

Control which resources are reconciled per input using the `reconcile` annotation
with conditional template expressions:

```yaml
spec:
  resources:
    - apiVersion: v1
      kind: Namespace
      metadata:
        name: << inputs.tenant >>
        annotations:
          fluxcd.controlplane.io/reconcile: << if eq inputs.tenant "team1" >>enabled<< else >>disabled<< end >>
```

When the annotation value is `disabled`, the resource is excluded from reconciliation
for that input entry.

### copyFrom Annotation

Copy ConfigMaps and Secrets from another namespace:

```yaml
metadata:
  annotations:
    fluxcd.controlplane.io/copyFrom: "source-namespace/resource-name"
```

The ResourceSet controller copies the data from the source resource and keeps it in sync.
For Secrets, you must also set the `type` field.

### resourcesTemplate

Alternative to inline `resources`: a Go template string rendered as multi-document YAML
(documents separated by `---`). Like `resources`, it is rendered **once per input**, with the
current input exposed as `inputs`. Its value over the structured `resources` list is the
`<<- range >>` and `<<- if >>` constructs — in particular, ranging over an **array field
within an input** to emit a variable number of objects per input (which the fixed `resources`
list cannot express):

```yaml
spec:
  inputs:
    - tenant: team1
      components: [frontend, backend]
    - tenant: team2
      components: [api]
  resourcesTemplate: |
    <<- range $component := inputs.components >>
    ---
    apiVersion: v1
    kind: Namespace
    metadata:
      name: << inputs.tenant >>-<< $component >>
      labels:
        tenant: << inputs.tenant >>
    <<- end >>
```

Rendered per input: `team1` yields namespaces `team1-frontend` and `team1-backend`, `team2`
yields `team2-api`. Reference input fields as `<< inputs.field >>` and the loop variable as
`<< $field >>` (no leading dot).

When both `resources` and `resourcesTemplate` are set, the generated objects are merged,
with the `resources` entries taking precedence on duplicates.

### Deduplication

When multiple inputs produce resources with the same name/namespace/kind, the last input wins.
Resources are deduplicated by their GVK + namespace + name.

## Built-in Input Fields

Every input entry automatically includes:

| Field | Description |
|-------|-------------|
| `inputs.id` | Unique identifier for the input set amongst all sets generated for the ResourceSet. Value depends on provider type: Adler-32 checksum of the branch/tag name for Git branches, Git tags and OCI tags (checksum of the provider UID for Static), the PR/MR number for pull/merge requests |
| `inputs.provider.apiVersion` | API version of the object providing the inputs |
| `inputs.provider.kind` | Kind of the object providing the inputs (`ResourceSet` for inline, `ResourceSetInputProvider` for external) |
| `inputs.provider.name` | Name of the providing object |
| `inputs.provider.namespace` | Namespace of the providing object |

## ResourceSetInputProvider

Fetches input values from external services for use in ResourceSets.

### Canonical YAML

```yaml
apiVersion: fluxcd.controlplane.io/v1
kind: ResourceSetInputProvider
metadata:
  name: github-prs
  namespace: flux-system
  annotations:
    fluxcd.controlplane.io/reconcileEvery: "5m"
spec:
  type: GitHubPullRequest
  url: https://github.com/my-org/my-app
  secretRef:
    name: github-token
  filter:
    limit: 10
    labels:
      - deploy-preview
  defaultValues:
    cluster: preview
```

### Provider Types and Exported Fields

| Type | Exported Fields | Description |
|------|----------------|-------------|
| `GitHubPullRequest` | `id`, `sha`, `branch`, `author`, `title` | Open pull requests with matching labels |
| `GitHubBranch` | `id`, `branch`, `sha` | Repository branches |
| `GitHubTag` | `id`, `tag`, `sha` | Repository tags |
| `GitLabMergeRequest` | `id`, `sha`, `branch`, `author`, `title` | Open merge requests |
| `GitLabBranch` | `id`, `branch`, `sha` | Repository branches |
| `GitLabTag` | `id`, `tag`, `sha` | Repository tags |
| `GitLabEnvironment` | `id`, `sha`, `branch`, `author`, `title`, `slug` | Deployed GitLab environments |
| `AzureDevOpsPullRequest` | `id`, `sha`, `branch`, `author`, `title` | Open pull requests |
| `AzureDevOpsBranch` | `id`, `branch`, `sha` | Repository branches |
| `AzureDevOpsTag` | `id`, `tag`, `sha` | Repository tags |
| `GiteaPullRequest` | `id`, `sha`, `branch`, `author`, `title` | Open pull requests |
| `GiteaBranch` | `id`, `branch`, `sha` | Repository branches |
| `GiteaTag` | `id`, `tag`, `sha` | Repository tags |
| `OCIArtifactTag` | `id`, `tag`, `digest` | OCI artifact tags (generic registries) |
| `ACRArtifactTag` | `id`, `tag`, `digest` | Azure Container Registry tags (workload identity) |
| `ECRArtifactTag` | `id`, `tag`, `digest` | AWS ECR tags (workload identity) |
| `GARArtifactTag` | `id`, `tag`, `digest` | Google Artifact Registry tags (workload identity) |
| `ExternalService` | (from HTTP response) | Custom HTTP service endpoint |
| `Static` | (from `defaultValues`) | Single input from inline values |

### Key Spec Fields

| Field | Type | Description |
|-------|------|-------------|
| `type` | string | Provider type (required, see table above) |
| `url` | string | Repository or registry URL (required for non-Static types) |
| `secretRef.name` | string | Secret with credentials (`username`/`password` for Git, dockerconfigjson for OCI) |
| `serviceAccountName` | string | SA for workload identity (AzureDevOps*, *ArtifactTag types) |
| `filter.limit` | int | Max number of inputs to return (default: 100) |
| `filter.labels` | array | Label filter for change requests |
| `filter.includeBranch` | string | Regex to include branches |
| `filter.excludeBranch` | string | Regex to exclude branches |
| `filter.includeTag` | string | Regex to include tags |
| `filter.excludeTag` | string | Regex to exclude tags |
| `filter.semver` | string | Semver range to filter and sort tags |
| `skip.labels` | array | Labels to skip input updates (prefix `!` to skip if absent) |
| `defaultValues` | map | Default key-value pairs merged with exported values |
| `schedule` | array | Cron schedules with `cron`, `timeZone`, `window` fields |
| `insecure` | bool | Allow HTTP (ExternalService, OCIArtifactTag only) |
| `certSecretRef.name` | string | Secret with TLS CA cert (`ca.crt`) |

Reconciliation is configured via annotations, not spec fields:
- `fluxcd.controlplane.io/reconcileEvery: "5m"` — poll interval (default: `10m`)
- `fluxcd.controlplane.io/reconcile: "enabled"` — enable/disable reconciliation
- `fluxcd.controlplane.io/reconcileTimeout: "2m"` — timeout for external calls

### Referencing in ResourceSet

```yaml
spec:
  inputsFrom:
    - name: github-prs                    # by name
    - selector:
        matchLabels:
          app: preview                     # by label selector
```

## Use Cases

### Multi-Component Orchestration (Gitless Pattern)

The Gitless reference architecture uses a chain of ResourceSets:
1. **policies** — Creates ValidatingAdmissionPolicies (no inputs needed)
2. **infra** — Creates per-component namespaces + OCIRepository + Kustomization for infrastructure (cert-manager, monitoring)
3. **apps** — Creates per-tenant namespaces + OCIRepository + Kustomization for applications (frontend, backend)

Dependencies: policies → infra → apps. Each ResourceSet waits for the previous one to be Ready.

### Preview Environments from Pull Requests

```yaml
apiVersion: fluxcd.controlplane.io/v1
kind: ResourceSetInputProvider
metadata:
  name: app-previews
  namespace: preview               # the dedicated preview namespace, not flux-system
spec:
  type: GitHubPullRequest
  url: https://github.com/org/app
  secretRef:
    name: github-app-auth
  filter:
    labels: [deploy-preview]
---
apiVersion: fluxcd.controlplane.io/v1
kind: ResourceSet
metadata:
  name: app-previews
  namespace: preview
spec:
  serviceAccountName: flux     # scoped: admin within the preview namespace only
  inputsFrom:
    - name: app-previews
  resources:
    - apiVersion: source.toolkit.fluxcd.io/v1
      kind: GitRepository
      metadata:
        name: "app-<< inputs.id >>"
        namespace: preview
      spec:
        interval: 2m
        url: https://github.com/org/app.git
        ref:
          commit: << inputs.sha >>   # pin to the PR head commit
        provider: github
        secretRef:
          name: github-app-auth
    - apiVersion: kustomize.toolkit.fluxcd.io/v1
      kind: Kustomization
      metadata:
        name: "app-<< inputs.id >>"
        namespace: preview
      spec:
        serviceAccountName: flux
        targetNamespace: preview
        nameSuffix: "-pr<< inputs.id >>"   # isolate this PR's workloads in the shared namespace
        interval: 10m
        prune: true
        wait: true
        timeout: 5m
        retryInterval: 2m
        sourceRef:
          kind: GitRepository
          name: "app-<< inputs.id >>"
        path: ./deploy/preview
        images:
          - name: ghcr.io/org/app
            newTag: preview-<< inputs.sha >>   # the image CI built for this PR commit
```

Provision the `preview` namespace once with the `flux` ServiceAccount and a RoleBinding
to the built-in `admin` — scoping `flux` to `preview` so PR content can't escalate beyond it.

### Gitless Image Automation with ResourceSets

`ResourceSet` + `ResourceSetInputProvider` of `type: OCIArtifactTag` implements image
update automation without committing tag bumps to Git — the provider scans the
registry, the `ResourceSet` re-renders, and the downstream `HelmRelease` or
`Kustomization` upgrades directly. For the full pattern (provider filters, Permute
strategy, `tag@digest` pinning, post-renderers for images not in Helm values) load
`references/gitless-image-automation.md`.
