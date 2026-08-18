# Source CRDs Reference

All source CRDs are in `apiVersion: source.toolkit.fluxcd.io/v1` (except ArtifactGenerator
which uses `source.extensions.fluxcd.io/v1beta1`). Source-controller polls for changes at
the configured interval and produces versioned artifacts consumed by Kustomization and HelmRelease.

**Contents:** [GitRepository](#gitrepository) | [OCIRepository](#ocirepository) | [HelmRepository](#helmrepository) | [HelmChart](#helmchart) | [Bucket](#bucket) | [ExternalArtifact](#externalartifact) | [ArtifactGenerator](#artifactgenerator)

## GitRepository

Fetches manifests from a Git repository, producing a tarball artifact.

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
    name: git-credentials
  sparseCheckout:
    - deploy/
    - charts/
```

**Key spec fields:**

| Field | Type | Description |
|-------|------|-------------|
| `url` | string | Git URL — HTTPS (`https://`) or SSH (`ssh://user@host:22/repo.git`). SSH scp-style syntax (`git@host:repo`) is NOT supported. |
| `interval` | duration | How often to poll for changes (e.g., `5m`, `1h`) |
| `ref.branch` | string | Branch name |
| `ref.tag` | string | Tag name |
| `ref.semver` | string | Semver constraint (e.g., `>=1.0.0 <2.0.0`) |
| `ref.commit` | string | Exact commit SHA |
| `ref.name` | string | Arbitrary Git reference (e.g., `refs/pull/420/head`, `refs/heads/main`) |
| `secretRef.name` | string | Secret with credentials |
| `provider` | string | Keyless auth provider: `generic` (default), `aws` (CodeCommit IAM), `azure` (Azure DevOps Workload Identity), `github` (GitHub App) |
| `sparseCheckout` | []string | List of directories to checkout when cloning; only the contents of the listed directories appear in the produced artifact |
| `recurseSubmodules` | bool | Include Git submodules (default: false) |
| `verify.mode` | string | Which Git object(s) to verify: `HEAD` (default), `Tag`, or `TagAndHEAD` |
| `verify.secretRef.name` | string | Secret with public keys of trusted authors — PGP keys under `.asc` keys and/or SSH keys under `.sshpub` keys (Flux verifies both PGP- and SSH-signed commits/tags) |

When no `ref` field is set, source-controller checks out the `master` branch. Ref precedence
when multiple are set: `commit` > `name` > `semver` > `tag` > `branch`. There is no
`spec.insecure` field on GitRepository — TLS/CA trust for HTTPS is controlled via the auth
Secret (`ca.crt` for a custom CA, `tls.crt`/`tls.key` for mTLS).

**Authentication secrets:**

For HTTPS — Secret with `username` and `password` (or token) fields. HTTP bearer-token auth
is also supported via a `bearerToken` data key (instead of `username`/`password`):
```yaml
stringData:
  username: git
  password: ghp_xxxxxxxxxxxx
  # bearerToken: <token>  # Alternative to username/password
  ca.crt: # Optional CA certificate
  tls.crt: # Optional TLS certificate for mTLS
  tls.key: # Optional TLS key for mTLS
```

For SSH — Secret with `identity` (private key) and `known_hosts` fields:
```yaml
stringData:
  identity: |
    -----BEGIN OPENSSH PRIVATE KEY-----
    ...
  known_hosts: github.com ssh-ed25519 AAAA...
```

For GitHub App — Secret with `githubAppID`, `githubAppPrivateKey` and `githubAppInstallationID` or `githubAppInstallationOwner`.

## OCIRepository

Fetches OCI artifacts from container registries. Used for Gitless GitOps patterns and
OCI Helm chart references.

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata:
  name: fleet-manifests
  namespace: flux-system
spec:
  interval: 5m
  url: oci://ghcr.io/my-org/fleet-manifests
  ref:
    tag: latest
  secretRef:
    name: registry-auth
  verify:
    provider: cosign
    matchOIDCIdentity:
      - issuer: ^https://token\.actions\.githubusercontent\.com$
        subject: ^https://github\.com/my-org/fleet/\.github/workflows/push\.yaml@refs/heads/main$
```

**Key spec fields:**

| Field | Type | Description |
|-------|------|-------------|
| `url` | string | OCI URL with `oci://` prefix (e.g., `oci://ghcr.io/org/repo`) |
| `interval` | duration | Poll interval |
| `ref.tag` | string | Image tag |
| `ref.semver` | string | Semver constraint for tag selection |
| `ref.digest` | string | Exact digest (`sha256:...`) |
| `secretRef.name` | string | Secret of type `kubernetes.io/dockerconfigjson` |
| `certSecretRef.name` | string | Secret with TLS CA and client certs for mTLS auth |
| `provider` | string | Cloud OIDC provider for keyless auth: `aws`, `azure`, `gcp` |
| `layerSelector.mediaType` | string | Filter OCI layers by media type |
| `layerSelector.operation` | string | `extract` (default) or `copy` |
| `verify.provider` | string | Signature verification: `cosign` or `notation` |
| `verify.matchOIDCIdentity` | array | OIDC issuer/subject patterns for keyless verification |
| `verify.trustedRootSecretRef.name` | string | Secret with a custom Sigstore `trusted_root.json` — verify against self-hosted Fulcio CA / Rekor (air-gapped keyless) |
| `serviceAccountName` | string | Service account for image pull (uses imagePullSecrets) |
| `insecure` | bool | Allow HTTP (non-TLS) connections |

**Fetching Helm charts from OCI registries:**

When an OCI registry stores Helm charts, use `layerSelector` to extract the chart layer:

```yaml
spec:
  url: oci://quay.io/jetstack/charts/cert-manager
  layerSelector:
    mediaType: "application/vnd.cncf.helm.chart.content.v1.tar+gzip"
    operation: copy
  ref:
    semver: "1.x"
```

Without `layerSelector`, the full OCI manifest is fetched (suitable for plain YAML artifacts).

**Cosign verification with OIDC identity matching:**

```yaml
spec:
  verify:
    provider: cosign
    matchOIDCIdentity:
      - issuer: ^https://token\.actions\.githubusercontent\.com$
        subject: ^https://github\.com/org/repo/\.github/workflows/release\.yaml@refs/tags/v\d+\.\d+\.\d+$
```

## HelmRepository

Defines an HTTPS Helm chart repository. Source-controller downloads and caches the repository index.

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: metrics-server
  namespace: kube-system
spec:
  interval: 1h
  url: https://kubernetes-sigs.github.io/metrics-server/
```

**Key spec fields:**

| Field | Type | Description |
|-------|------|-------------|
| `url` | string | Helm repository HTTPS URL |
| `interval` | duration | How often to fetch the index |
| `secretRef.name` | string | Secret with `username`/`password` for auth |
| `certSecretRef.name` | string | Secret with TLS CA and client certs for mTLS auth |
| `provider` | string | Cloud OIDC provider for keyless auth |
| `passCredentials` | bool | Pass credentials to chart download URLs |
| `type` | string | `default` (HTTPS) or `oci` — but prefer `OCIRepository` for OCI registries |
| `insecure` | bool | Skip TLS verification |

**Important:** For OCI registries, use `OCIRepository` with `layerSelector` instead of
`HelmRepository` with `type: oci`. The OCIRepository approach is more flexible and supports
Cosign verification.

## HelmChart

Fetches and packages a Helm chart from a source. Usually auto-created by HelmRelease when
using `spec.chart.spec` — you rarely create HelmChart resources directly.

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmChart
metadata:
  name: my-chart
  namespace: flux-system
spec:
  interval: 10m
  chart: metrics-server
  version: "3.x"
  sourceRef:
    kind: HelmRepository
    name: metrics-server
  reconcileStrategy: ChartVersion
```

**Key spec fields:**

| Field | Type | Description |
|-------|------|-------------|
| `chart` | string | Chart name (from HelmRepository) or path (from GitRepository/Bucket) |
| `version` | string | Semver constraint (e.g., `18.x`, `>=1.0.0 <2.0.0`) |
| `sourceRef.kind` | string | `HelmRepository`, `GitRepository`, or `Bucket` |
| `sourceRef.name` | string | Source name |
| `reconcileStrategy` | string | `ChartVersion` (default) or `Revision` |
| `valuesFiles` | array | Values files to merge during packaging |

## Bucket

Fetches from S3-compatible object storage (AWS S3, GCS, MinIO, Azure Blob).

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: Bucket
metadata:
  name: manifests
  namespace: flux-system
spec:
  interval: 5m
  provider: generic
  bucketName: my-manifests
  endpoint: s3.amazonaws.com
  region: us-east-1
  secretRef:
    name: s3-credentials
```

**Key spec fields:**

| Field | Type | Description |
|-------|------|-------------|
| `bucketName` | string | Bucket name |
| `endpoint` | string | S3 endpoint (e.g., `s3.amazonaws.com`, `minio.example.com`) |
| `region` | string | Object storage region (optional, no default; some endpoints require it) |
| `provider` | string | `generic` (default), `aws`, `azure`, `gcp` |
| `secretRef.name` | string | Secret with credentials. Keys are provider-dependent: `generic`/`aws` use `accesskey`+`secretkey`; `gcp` uses `serviceaccount` (JSON key); `azure` uses Entra ID / `accountKey` / `sasKey` credentials |
| `serviceAccountName` | string | Workload identity for `aws`/`azure`/`gcp` (keyless). Mutually exclusive with `secretRef` |
| `certSecretRef.name` | string | Secret with TLS CA and client certs for mTLS auth |
| `insecure` | bool | Use HTTP instead of HTTPS |
| `prefix` | string | S3 key prefix filter |
| `ignore` | string | `.gitignore`-style patterns to exclude |

## ExternalArtifact

Generic artifact storage API for third-party controllers. ExternalArtifact resources are
typically created by ArtifactGenerator, not manually.

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: ExternalArtifact
metadata:
  name: my-component
  namespace: flux-system
```

ExternalArtifact has an optional `spec.sourceRef` (with `apiVersion`, `kind`, `name`, and
`namespace` — namespace defaults to the ExternalArtifact's namespace) pointing to the
custom resource the artifact is based on. Its `status.artifact` is populated by an external
controller (like ArtifactGenerator). Kustomization and HelmRelease can reference
ExternalArtifact via `sourceRef`.

## ArtifactGenerator

`apiVersion: source.extensions.fluxcd.io/v1beta1` — managed by `source-watcher` controller.

Composes or decomposes artifacts from multiple sources. Two main use cases:
- **Decomposition** — split a monorepo into multiple ExternalArtifacts, one per component
- **Helm chart composition** — combine an OCI chart with environment-specific values from Git

### Monorepo Decomposition

```yaml
apiVersion: source.extensions.fluxcd.io/v1beta1
kind: ArtifactGenerator
metadata:
  name: monorepo
  namespace: flux-system
spec:
  sources:
    - alias: mono
      kind: GitRepository
      name: monorepo
  artifacts:
    - name: frontend
      revision: "@mono"
      copy:
        - from: "@mono/apps/frontend/**"
          to: "@artifact/"
    - name: backend
      revision: "@mono"
      copy:
        - from: "@mono/apps/backend/**"
          to: "@artifact/"
    - name: infra
      revision: "@mono"
      copy:
        - from: "@mono/infrastructure/**"
          to: "@artifact/"
```

Each ExternalArtifact can be referenced by a separate Kustomization:
```yaml
sourceRef:
  kind: ExternalArtifact
  name: frontend
```

Only the affected artifact gets a new revision when its source path changes,
so unrelated Kustomizations won't reconcile.

### Helm Chart Composition

Merge environment-specific values from Git into a chart from an OCI registry:

```yaml
apiVersion: source.extensions.fluxcd.io/v1beta1
kind: ArtifactGenerator
metadata:
  name: podinfo
  namespace: apps
spec:
  sources:
    - alias: chart
      kind: OCIRepository
      name: podinfo-chart
    - alias: repo
      kind: GitRepository
      name: podinfo-values
  artifacts:
    - name: podinfo-composite
      originRevision: "@chart"
      copy:
        - from: "@chart/"
          to: "@artifact/"
        - from: "@repo/charts/podinfo/values-prod.yaml"
          to: "@artifact/podinfo/values.yaml"
          strategy: Merge
```

The resulting ExternalArtifact can be deployed with a HelmRelease:

```yaml
spec:
  chartRef:
    kind: ExternalArtifact
    name: podinfo-composite
```

### Path Pattern Discovery (Monorepos)

Instead of listing every component by hand, `spec.pathPattern` discovers matching directories
in a source and generates one ExternalArtifact per match. The format is `@<alias>/<pattern>`,
where named captures (e.g. `{app}`) become placeholders usable in the generated artifact fields:

```yaml
apiVersion: source.extensions.fluxcd.io/v1beta1
kind: ArtifactGenerator
metadata:
  name: apps
  namespace: flux-system
spec:
  sources:
    - alias: mono
      kind: GitRepository
      name: monorepo
  pathPattern: "@mono/apps/{app}/kustomize"   # matches apps/frontend/kustomize, apps/backend/kustomize, ...
  artifacts:
    - name: "{app}"                             # one ExternalArtifact per discovered app
      revision: "@mono"
      copy:
        - from: "@mono/apps/{app}/kustomize/**"
          to: "@artifact/"
```

This keeps the ArtifactGenerator stable as teams add or remove components — no edit needed
when a new `apps/<name>/kustomize` directory appears.

**Key spec fields:**

| Field | Type | Description |
|-------|------|-------------|
| `pathPattern` | string | `@<alias>/<pattern>` directory-discovery pattern with named captures (e.g. `{app}`) for monorepos |
| `sources[].alias` | string | Unique alias for referencing in copy operations |
| `sources[].kind` | string | `GitRepository`, `OCIRepository`, `Bucket`, `HelmChart`, or `ExternalArtifact` |
| `sources[].name` | string | Source name |
| `artifacts[].name` | string | Name of the ExternalArtifact to create |
| `artifacts[].revision` | string | Revision tracking (e.g., `@alias`) |
| `artifacts[].copy[].from` | string | Source path (`@alias/pattern`) |
| `artifacts[].copy[].to` | string | Destination path (`@artifact/path`) |
| `artifacts[].copy[].exclude` | array | Glob patterns to exclude |
| `artifacts[].copy[].strategy` | string | `Overwrite` (default), `Merge`, or `Extract` |

**Copy strategies:**
- `Overwrite` (default) — later copies overwrite earlier files at the same path
- `Merge` — for YAML files only; merges arrays entirely (like `helm --values`)
- `Extract` — extracts tarball archives (`.tar.gz`, `.tgz`) preserving internal directory
  structure; useful for charts built with `helm package` or `flux build artifact`

**Copy semantics:**
- `@source/file.yaml` → `@artifact/dest/` copies the file to `dest/file.yaml`
- `@source/dir/` copies the directory as a subdirectory
- `@source/dir/**` copies contents recursively (flattened)
