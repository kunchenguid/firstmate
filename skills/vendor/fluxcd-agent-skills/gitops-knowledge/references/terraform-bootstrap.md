# Terraform Flux Operator Bootstrap Reference

The [`controlplaneio-fluxcd/flux-operator-bootstrap/kubernetes`](https://registry.terraform.io/modules/controlplaneio-fluxcd/flux-operator-bootstrap/kubernetes/latest)
Terraform module bootstraps Flux Operator and a `FluxInstance` into a Kubernetes cluster
using a Kubernetes `Job`. Use this module when the cluster is provisioned with Terraform
and Flux should take over GitOps reconciliation afterwards.

**Contents:** [Ownership Model](#ownership-model) | [Repository Layout](#repository-layout) | [Provider Configuration](#provider-configuration) | [GitOps vs Managed Resources](#gitops-vs-managed-resources) | [Revision and Drift](#revision-and-drift) | [Runtime Info and Variable Substitution](#runtime-info-and-variable-substitution) | [Node Scheduling](#node-scheduling) | [Shared Operator Values File](#shared-operator-values-file) | [Sync Source Authentication](#sync-source-authentication) | [Managed Secrets from External Stores](#managed-secrets-from-external-stores) | [Debugging Failed Bootstraps](#debugging-failed-bootstraps)

## Ownership Model

The module solves the bootstrap ownership problem by splitting responsibilities:

- **Terraform** manages only the ephemeral bootstrap mechanism: a namespace, RBAC,
  mounted manifests, and a bootstrap `Job`.
- **Flux** and **Flux Operator** take over steady-state reconciliation of all GitOps
  resources once the bootstrap `Job` completes.

## Repository Layout

The Terraform root module and the Flux manifests should both live at the repo root,
as siblings. `clusters/` stays at the top level so Flux can reconcile it as the fleet
source of truth, and the Terraform directory stays isolated to the bootstrap concern:

```text
repo/
├── terraform/                             # Terraform root module
│   ├── main.tf
│   ├── providers.tf
│   └── variables.tf
└── clusters/
    └── staging/                           # reconciled by Flux via FluxInstance.spec.sync.path
        └── flux-system/
            ├── flux-instance.yaml         # applied by the bootstrap Job
            ├── flux-operator-values.yaml  # shared between Terraform and the Flux-managed HelmRelease
            ├── flux-operator.yaml         # ResourceSet wrapping the Flux Operator HelmRelease
            ├── runtime-info.yaml          # Git-managed fields of flux-runtime-info (optional)
            └── kustomization.yaml         # configMapGenerator for flux-operator-values
```

Because the Terraform root is a subdirectory, reach up with `${path.root}/..` when
loading manifests, and parameterize the cluster name:

```hcl
module "flux_operator_bootstrap" {
  source = "controlplaneio-fluxcd/flux-operator-bootstrap/kubernetes"

  gitops_resources = {
    instance_yaml = file("${path.root}/../clusters/${var.cluster_name}/flux-system/flux-instance.yaml")
    operator_chart = {
      values_yaml = file("${path.root}/../clusters/${var.cluster_name}/flux-system/flux-operator-values.yaml")
    }
  }
}
```

Set `FluxInstance.spec.sync.path` to `clusters/${var.cluster_name}` so Flux reconciles
the same directory after bootstrap — pulling in `flux-operator.yaml` and the generated
`flux-operator-values` `ConfigMap` via `kustomization.yaml`.

## Provider Configuration

Callers must configure the HashiCorp `helm` and `kubernetes` providers. For local
clusters (KinD, minikube, Docker Desktop) the simplest setup uses `config_path`:

```hcl
provider "kubernetes" {
  config_path = "~/.kube/config"
}

provider "helm" {
  kubernetes = {
    config_path = "~/.kube/config"
  }
}
```

For cloud clusters, derive the connection from the cluster data source or module
outputs. Example for EKS:

```hcl
provider "kubernetes" {
  host                   = data.aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.this.token
}

provider "helm" {
  kubernetes = {
    host                   = data.aws_eks_cluster.this.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}
```

The module does not require cluster connectivity during `terraform plan`, so it can
live in the **same root module** that creates the cluster. Wire the providers to the
cluster module's outputs and add `depends_on`:

```hcl
module "eks" {
  source = "terraform-aws-modules/eks/aws"
  # ...
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  exec = {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
  }
}

module "flux_operator_bootstrap" {
  depends_on = [module.eks]
  source     = "controlplaneio-fluxcd/flux-operator-bootstrap/kubernetes"
  # ...
}
```

## GitOps vs Managed Resources

The module draws a clear line between resources Flux owns and resources Terraform owns.

**`gitops_resources`** — applied once with create-if-missing semantics, then reconciled
by Flux:
- `instance_yaml` (required): the `FluxInstance` manifest.
- `operator_chart`: Flux Operator Helm chart repository, version, and values.
- `prerequisites.yamls`: ordered manifests applied before the `FluxInstance`
  (e.g. Karpenter `NodePool`s, Gateway API CRDs).
- `prerequisites.charts`: Helm charts installed before Flux (e.g. CSI drivers, CNI).

**`managed_resources`** — reconciled on every bootstrap `Job` run with server-side apply,
correcting drift from manual `kubectl` changes:
- `secrets_yaml`: multi-document `Secret` manifest string reconciled into the
  `FluxInstance` target namespace. Namespace must be omitted or match the target.
- `runtime_info`: key-value data published as a `ConfigMap` named `flux-runtime-info`
  in the target namespace.

Managed resources are tracked in an inventory and garbage-collected when removed from
the input.

### Helm Chart Adoption by Flux

Each `gitops_resources.prerequisites.charts[]` entry can set `flux_adoption_check` to
let Flux take over the release after bootstrap:

- **Without `flux_adoption_check`** — the chart is installed create-if-missing.
  Subsequent bootstrap runs skip re-install.
- **With `flux_adoption_check`** — the `Job` checks the referenced resource (e.g. a
  `Deployment`) for Flux ownership labels. If Flux has adopted it, the chart is
  skipped entirely. If not adopted, the full unlock/recover/upgrade flow runs — the
  same flow used for the Flux Operator chart itself.

Use `flux_adoption_check` when the chart will be re-declared as a `HelmRelease` in
the fleet repo and reconciled by Flux post-bootstrap.

## Revision and Drift

The bootstrap `Job` re-runs automatically whenever any input content changes. When all
inputs are unchanged, `terraform plan` shows zero diff. The `revision` input is a number
to bump for forcing a re-run without changing content.

Secret values never appear in the Terraform state — `managed_resources` is marked
`sensitive` and only a SHA-256 hash of the content is persisted.

## Runtime Info and Variable Substitution

When `managed_resources.runtime_info` is set, the bootstrap `Job`:

1. Creates a `ConfigMap` named `flux-runtime-info` in the `FluxInstance` target namespace
   with the provided `data`, `labels`, and `annotations`.
2. Substitutes `${variable}` references in all input manifests (`instance_yaml`,
   `prerequisites.yamls`, `operator_chart.values_yaml`, per-chart `values_yaml`) using
   `flux envsubst --strict` before applying them.

This lets input manifests use `${cluster_name}` style references resolved at bootstrap
time. For steady-state reconciliation of the same variables, patch the generated
`flux-system` `Kustomization` (created from `.spec.sync`) with `postBuild.substituteFrom`
referencing the same `ConfigMap`:

```yaml
apiVersion: fluxcd.controlplane.io/v1
kind: FluxInstance
metadata:
  name: flux
  namespace: flux-system
spec:
  # ...
  kustomize:
    patches:
      - target:
          kind: Kustomization
          name: flux-system
        patch: |
          - op: add
            path: /spec/postBuild
            value:
              substituteFrom:
                - kind: ConfigMap
                  name: flux-runtime-info
```

### Co-Owning `flux-runtime-info` with Git

Terraform-owned runtime info and Git-owned runtime info can coexist in the **same**
`flux-runtime-info` `ConfigMap` using server-side apply field ownership. Terraform
writes only the fields it knows (cloud region, account ID, cluster ID), while a
Git-managed `runtime-info.yaml` writes everything else (artifact tag, environment,
cluster name, domain).

Split by authority:

- **Terraform-owned fields** — values known only to the infra provisioner, e.g.
  `CLUSTER_REGION`, `ACCOUNT_ID`. Set via `managed_resources.runtime_info.data`.
- **Git-owned fields** — values that belong in the fleet repo, e.g. `ARTIFACT_TAG`,
  `ENVIRONMENT`, `CLUSTER_NAME`. Reconciled by Flux from a `ConfigMap` in
  `clusters/<name>/flux-system/runtime-info.yaml`.

The Git-managed `ConfigMap` (the canonical manifest is in `references/flux-operator.md`)
must set `kustomize.toolkit.fluxcd.io/ssa: "Merge"` so kustomize-controller merges its
fields instead of replacing the whole `ConfigMap`, preserving the fields Terraform owns:

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
  # Git-owned keys only — Terraform-owned keys (CLUSTER_REGION, ACCOUNT_ID, ...)
  # are set via managed_resources and never appear here
  ARTIFACT_TAG: latest
  ENVIRONMENT: staging
```

Because Terraform and kustomize-controller act as different SSA field managers, each
owns the keys it sets — neither clobbers the other on reconciliation.

## Node Scheduling

When the cluster uses dedicated nodes with taints, configure affinity and tolerations
at three layers:

**Bootstrap `Job`** — `job.affinity` and `job.tolerations`. Use the taint key/value
that the dedicated node pool carries (e.g. a `dedicated=flux:NoSchedule` taint on a
Karpenter `NodePool`):

```hcl
job = {
  tolerations = [{
    key      = "dedicated"
    operator = "Equal"
    value    = "flux"
    effect   = "NoSchedule"
  }]
}
```

**Flux Operator** — `gitops_resources.operator_chart.values_yaml`:

```hcl
gitops_resources = {
  operator_chart = {
    values_yaml = yamlencode({
      tolerations = [{
        key      = "dedicated"
        operator = "Equal"
        value    = "flux"
        effect   = "NoSchedule"
      }]
    })
  }
}
```

**Flux controllers** (source-controller, etc.) — `.spec.kustomize.patches` in the
`FluxInstance` manifest, targeting `kind: Deployment`.

If node pools are managed by Karpenter or similar, pass the `NodePool` manifests as
`gitops_resources.prerequisites.yamls` so target nodes exist before the bootstrap
`Job` schedules.

When the bootstrap `Job` must install a CNI plugin (e.g. Cilium) before pod networking
is available, set `job.host_network = true` so the `Job` runs on the host network.

## Shared Operator Values File

A single `flux-operator-values.yaml` can be reused by Terraform (bootstrap) and Flux
(steady-state). Place the file in the fleet repo, bundle it into a `ConfigMap` via
`configMapGenerator`, and reference it from a Flux-managed `HelmRelease` using
`valuesFrom`. The `reconcile.fluxcd.io/watch: Enabled` label on the `ConfigMap` triggers
helm-controller to reconcile when values change.

During bootstrap, load the same file with `file(...)`:

```hcl
operator_chart = {
  values_yaml = file("${path.root}/../clusters/${var.cluster_name}/flux-system/flux-operator-values.yaml")
}
```

When certain fields must differ during bootstrap (e.g. disabling the web UI before
Gateway API CRDs exist), merge overrides in. Terraform's `merge()` is **shallow** — it
replaces top-level keys, so override entire top-level keys, not nested fields:

```hcl
operator_chart = {
  values_yaml = yamlencode(merge(
    yamldecode(file("${path.root}/../clusters/${var.cluster_name}/flux-system/flux-operator-values.yaml")),
    { web = { enabled = false } },
  ))
}
```

Wrap the Flux-managed operator `HelmRelease` in a `ResourceSet` that `dependsOn` the
CRDs its values reference (e.g. `httproutes.gateway.networking.k8s.io` when
`web.httpRoute.enabled: true`) so the operator is only upgraded after the CRDs are
installed.

## Sync Source Authentication

When `FluxInstance.spec.sync` points at a private Git repository or OCI registry,
compose the matching `Secret` into `managed_resources.secrets_yaml`. The `Secret`
name must match `spec.sync.pullSecret` (default `flux-system` if omitted).

**Git PAT (GitLab, Bitbucket, classic GitHub):**

```hcl
locals {
  git_auth_secret = yamlencode({
    apiVersion = "v1"
    kind       = "Secret"
    metadata   = { name = "flux-system" }
    type       = "Opaque"
    stringData = {
      username = "git"
      password = var.git_token
    }
  })
}

module "flux_operator_bootstrap" {
  source = "controlplaneio-fluxcd/flux-operator-bootstrap/kubernetes"

  managed_resources = {
    secrets_yaml = local.git_auth_secret
  }
}
```

**GitHub App** (preferred for GitHub — avoids PAT rotation):

```hcl
locals {
  git_auth_secret = yamlencode({
    apiVersion = "v1"
    kind       = "Secret"
    metadata   = { name = "flux-system" }
    type       = "Opaque"
    stringData = {
      githubAppID                = var.github_app_id
      githubAppInstallationOwner = var.github_app_installation_owner
      githubAppPrivateKey        = var.github_app_pem
    }
  })
}
```

Set `FluxInstance.spec.sync.provider: github` and `pullSecret: flux-system` when using
a GitHub App. Mark `git_token` and `github_app_pem` as `sensitive = true` in their
`variable` blocks — the secret content never appears in the Terraform state regardless,
but marking sensitive prevents leaks in plan/apply output.

A single expression can branch between auth modes by merging into `stringData` based on
which variables are set, so one module instance handles public repos, PAT-authenticated
repos, and GitHub App-authenticated repos uniformly.

**OCI pull secret** — for `spec.sync.kind: OCIRepository` pointing at a private
registry (e.g. GHCR), emit a `kubernetes.io/dockerconfigjson` `Secret`. The same
secret can also be used as a Helm chart `pullSecret` on downstream `OCIRepository`
resources. Set `spec.sync.pullSecret` to this `Secret` name.

The dockerconfig JSON is embedded in a YAML heredoc using single-quoted scalar
syntax, so any single quote inside the JSON must be doubled with
`replace(..., "'", "''")` to avoid breaking the YAML:

```hcl
locals {
  ghcr_auth_dockerconfigjson = jsonencode({
    auths = {
      "ghcr.io" = {
        username = "flux"
        password = var.oci_token
        auth     = base64encode("flux:${var.oci_token}")
      }
    }
  })
}

module "flux_operator_bootstrap" {
  source = "controlplaneio-fluxcd/flux-operator-bootstrap/kubernetes"

  managed_resources = {
    secrets_yaml = <<-YAML
      apiVersion: v1
      kind: Secret
      metadata:
        name: ghcr-auth
      type: kubernetes.io/dockerconfigjson
      stringData:
        .dockerconfigjson: '${replace(local.ghcr_auth_dockerconfigjson, "'", "''")}'
    YAML
  }
}
```

## Managed Secrets from External Stores

Pull secret values from AWS Secrets Manager, GCP Secret Manager, Azure Key Vault, or
HashiCorp Vault using Terraform `data` sources and compose them into
`managed_resources.secrets_yaml`:

```hcl
data "aws_secretsmanager_secret_version" "git_credentials" {
  secret_id = "flux/staging/git-credentials"
}

managed_resources = {
  secrets_yaml = <<-YAML
    apiVersion: v1
    kind: Secret
    metadata:
      name: git-credentials
    type: Opaque
    stringData:
      password: '${data.aws_secretsmanager_secret_version.git_credentials.secret_string}'
  YAML
}
```

Drift from manual `kubectl` changes is corrected on every `Job` run.

## Debugging Failed Bootstraps

Set `debug_on_failure = true` to relay the bootstrap `Job` logs to Terraform output
when the `Job` fails or stalls. Requirements on the Terraform execution environment:

- `bash` on `PATH` (Git Bash satisfies this on Windows)
- `kubectl` on `PATH`, configured with credentials for the target cluster
- the `hashicorp/null` provider (~> 3.2) declared in `required_providers`
