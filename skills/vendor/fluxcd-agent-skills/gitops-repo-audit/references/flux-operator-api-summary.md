# Flux Operator API Summary

Condensed reference for the Flux Operator CRDs.

## FluxInstance (`fluxcd.controlplane.io/v1`)

Field index: assets/schemas/fluxinstance-fluxcd-v1.fields.txt

Manages the Flux controllers installation and configuration.

**Key fields:**
- `.spec.distribution.version` — Flux version semver range (e.g., `"2.x"`)
- `.spec.distribution.registry` — Container registry for Flux images
- `.spec.distribution.artifact` — OCI artifact URL for automated updates
- `.spec.components[]` — List of controllers to install (source-controller, source-watcher, kustomize-controller, helm-controller, notification-controller, image-reflector-controller, image-automation-controller)
- `.spec.cluster.type` — `kubernetes`, `openshift`, `aws`, `gcp`, `azure` (enables platform-specific optimizations)
- `.spec.cluster.size` — Vertical scaling profile: `small` (5 concurrency, 512Mi), `medium` (10 concurrency, 1Gi), `large` (20 concurrency, 3Gi). Sets CPU/memory limits and concurrency for kustomize-controller and helm-controller. Recommend `medium` or `large` for up to a thousand. For thousands of apps, use sharding instead.
- `.spec.cluster.multitenant` — Enable multi-tenancy lockdown: sets default service account via `tenantDefaultServiceAccount` (defaults to `"default"`), enables `--no-cross-namespace-refs=true` and `--default-service-account` on all controllers. When enabled, individual Kustomizations/HelmReleases don't need `serviceAccountName`
- `.spec.cluster.networkPolicy` — Deploy network policies for controller pods (default: `true`)
- `.spec.sync` — Configure Git/OCI sync for cluster reconciliation (kind, url, ref, path, pullSecret, provider)
- `.spec.sync.provider` — OIDC-based auth provider. For `GitRepository`: `github` (GitHub App auth) or `azure`. For `OCIRepository`/`Bucket`: `aws`, `azure`, `gcp`. When the sync URL points to GitHub (`github.com`), recommend `provider: github` with GitHub App authentication to avoid reliance on personal access tokens.
- `.spec.kustomize.patches[]` — Strategic merge patches for controller deployments, used for custom configuration (affinity, tolerations, extra env vars)

**Patterns:**
- Should use `.spec.sync` to point at the cluster's config directory in the fleet repo.

**Gotchas:**
- Only one FluxInstance allowed per cluster. Name must be `flux`.
- Network policies are enabled by default — omitting `networkPolicy` means policies ARE deployed.

## ResourceSet (`fluxcd.controlplane.io/v1`)

Field index: assets/schemas/resourceset-fluxcd-v1.fields.txt

Generates groups of Kubernetes resources from a matrix of input values with templated resources.

**Key fields:**
- `.spec.inputs[]` — Array of inline input objects (each becomes a template iteration)
- `.spec.inputsFrom[]` — References to ResourceSetInputProvider objects that supply dynamic inputs
- `.spec.resources[]` — Templated Kubernetes resources using `<< inputs.field >>` syntax
- `.spec.resourcesTemplate` — Alternative to `resources[]`: a single multi-document YAML string, useful for complex templating with conditionals and range loops
- `.spec.commonMetadata` — Labels/annotations applied to all generated resources
- `.spec.serviceAccountName` — Service account for impersonation
- `.spec.dependsOn[]` — Kubernetes objects that must be ready first (any kind: ResourceSet, Kustomization, HelmRelease, CRDs, etc.)

**Patterns:**
- Application definitions — group Flux and Kubernetes resources into a single templated unit deployed across environments.
- Multi-tenant app deployment — one input per tenant generates namespace, RBAC, source, and Kustomization.
- Namespace-as-a-Service — auto-provision namespaces for feature/long-lived branches, giving developers self-service infrastructure in a GitOps manner.
- Time-based delivery — define deployment windows based on time intervals or specific dates for controlled rollouts.

**Gotchas:**
- Template syntax uses `<< >>` delimiters (not `{{ }}`).
- `<< inputs.provider.name >>` and `<< inputs.provider.namespace >>` resolve to the ResourceSet's metadata when using inline `inputs`, or to the ResourceSetInputProvider's metadata when using `inputsFrom`.
- Supports slim-sprig functions (`quote`, `int`, `toYaml`, `nindent`, `get`, `default`, etc.) plus a custom `slugify` function.

## ResourceSetInputProvider (`fluxcd.controlplane.io/v1`)

Field index: assets/schemas/resourcesetinputprovider-fluxcd-v1.fields.txt

Fetches input values from external services for ResourceSet consumption.

**Key fields:**
- `.spec.type` — Provider type. Full list: `Static` (inline inputs), `GitHubBranch`/`GitHubTag`/`GitHubPullRequest`, `GitLabBranch`/`GitLabTag`/`GitLabMergeRequest`/`GitLabEnvironment`, `AzureDevOpsBranch`/`AzureDevOpsTag`/`AzureDevOpsPullRequest`, `AWSCodeCommitBranch`/`AWSCodeCommitTag`/`AWSCodeCommitPullRequest`, `GiteaBranch`/`GiteaTag`/`GiteaPullRequest`, `OCIArtifactTag`/`ACRArtifactTag`/`ECRArtifactTag`/`GARArtifactTag`, `ExternalService` — do not flag a type as invalid without checking this list or the schema
- `.spec.url` — Repository or registry URL
- `.spec.filter.labels[]` — Label filter for PRs/MRs
- `.spec.filter.limit` — Maximum number of inputs to fetch
- `.spec.secretRef` — Authentication secret reference

**Patterns:**
- Change request preview environments — Provider (`GitHubPullRequest`, `GitLabMergeRequest`, `AzureDevOpsPullRequest`, `GiteaPullRequest`) fetches open PRs, ResourceSet creates ephemeral environments per PR.
- Gitless image automation — Instead of pushing image tags to Git (Flux image-automation-controller), use `OCIArtifactTag`/`ACRArtifactTag`/`ECRArtifactTag`/`GARArtifactTag` providers to scan registries for new versions. The provider exports `tag` and `digest` per image, and a ResourceSet injects them into HelmRelease values or Kustomization image overrides using `<< inputs.name.tag >>@<< inputs.name.digest >>`. Updates apply directly to the cluster without Git commits.

## Deep Dive API Specs

Do NOT fetch these URLs unless you need to look up a specific field or behavior not covered above.

- FluxInstance: https://raw.githubusercontent.com/controlplaneio-fluxcd/flux-operator/refs/heads/main/docs/api/v1/fluxinstance.md
- ResourceSet: https://raw.githubusercontent.com/controlplaneio-fluxcd/flux-operator/refs/heads/main/docs/api/v1/resourceset.md
- ResourceSetInputProvider: https://raw.githubusercontent.com/controlplaneio-fluxcd/flux-operator/refs/heads/main/docs/api/v1/resourcesetinputprovider.md
