# Gitless GitOps Reference

Gitless GitOps keeps Git as the developer source of truth, but removes Git from the
runtime dependency chain. CI packages rendered Kubernetes configuration as OCI artifacts,
pushes them to a container registry, and Flux pulls from the registry using
`OCIRepository`.

Use this reference when users ask about Flux OCI artifacts, `flux push artifact`,
GitHub Actions publishing, artifact signing, registry-based promotion, or running Flux in
clusters that should not access Git. For automatically upgrading workloads when new
image tags are published (registry scanning), load
`references/gitless-image-automation.md` instead — this file covers the publish/consume
pipeline for rendered manifests.

**Contents:** [Why Gitless GitOps](#why-gitless-gitops) | [Artifact Types](#artifact-types) | [Validating Manifests with `flux schema`](#validating-manifests-with-flux-schema) | [Publishing Manifests with `flux push artifact`](#publishing-manifests-with-flux-push-artifact) | [GitHub Actions Publisher](#github-actions-publisher) | [Consuming Manifest Artifacts](#consuming-manifest-artifacts) | [FluxInstance OCI Sync](#fluxinstance-oci-sync) | [Authentication](#authentication) | [Signing and Verification](#signing-and-verification) | [Promotion Patterns](#promotion-patterns) | [Observability and Tracing](#observability-and-tracing)

## Why Gitless GitOps

Traditional GitOps requires production clusters to clone Git repositories. Gitless GitOps
changes the delivery path:

```text
Git source -> CI build -> OCI registry -> Flux clusters
```

Motivation:

| Concern | Git-based runtime | Gitless runtime |
|---|---|---|
| Cluster network access | Git server and registry | Registry only |
| Credentials in cluster | Git credentials or SSH keys | Registry pull identity |
| Air-gapped operation | Mirror Git or expose Git | Mirror OCI artifacts |
| Integrity | Git commit history | Immutable digest + signature verification |
| Monorepo scale | Cluster clones large repo | CI publishes per-component artifacts |
| Sync speed | Clone/fetch Git | Pull pre-packaged artifact |

Git still matters: it remains where humans review and merge source changes. The
container registry becomes the deployment source of truth for clusters.

## Artifact Types

Flux supports two common OCI artifact shapes:

| Artifact | Producer | Consumer |
|---|---|---|
| Kubernetes manifests | `flux push artifact` | `OCIRepository` + `Kustomization` |
| Helm charts | Helm chart push or chart CI | `OCIRepository` + `HelmRelease.chartRef` |

For plain Kubernetes YAML, `flux push artifact` creates OCI artifacts with Flux media
types and stores Git source/revision metadata when `--source` and `--revision` are set.

For application container images, publish the image and the config artifact in the same CI
pipeline when possible. The config artifact should reference immutable image tags or
digests. For fully Gitless image and chart updates driven by registry tags, use
`ResourceSetInputProvider` with `type: OCIArtifactTag` (see
`references/gitless-image-automation.md`).

For Helm charts stored in OCI registries, use `OCIRepository` with `layerSelector`:

```yaml
spec:
  layerSelector:
    mediaType: "application/vnd.cncf.helm.chart.content.v1.tar+gzip"
    operation: copy
```

## Validating Manifests with `flux schema`

Validate the rendered manifests before packaging them as an OCI artifact:

```bash
# Install the schema plugin
flux plugin install schema

# Validate a directory of manifests against the default catalog
flux schema validate ./deploy/production --verbose --skip-missing-schemas

# Validate the output of a build step (Kustomize overlay, ResourceSet, etc.)
kustomize build ./deploy/production | flux schema validate
```

Important flags:

| Flag                     | Purpose                                                                                                                                                                            |
|--------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `--schema-location`      | Add a schema source (repeatable); `default` keeps the built-in catalog, then append a URL e.g. `https://raw.githubusercontent.com/datreeio/CRDs-catalog/main` for out-of-tree CRDs |
| `--skip-missing-schemas` | Skip documents whose schema isn't in the catalog instead of failing (tolerates third-party CRDs without wiring up a schema source)                                                 |
| `--skip-json-path`       | Strip a field before validation, e.g. `--skip-json-path v1/Secret:/sops` for SOPS metadata Flux removes at apply time                                                              |

In CI, run the same check as a gate ahead of `flux push artifact`. The GitHub Actions
workflow below does this with the `fluxcd/flux-schema/actions/validate` action so the
artifact is only published when every manifest is schema-valid.

## Publishing Manifests with `flux push artifact`

Push a directory of rendered manifests using the short Git SHA as the OCI tag:

```bash
flux push artifact oci://ghcr.io/org/fleet/apps/podinfo:$(git rev-parse --short HEAD) \
  --path="./deploy/production" \
  --source="$(git config --get remote.origin.url)" \
  --revision="$(git branch --show-current)@sha1:$(git rev-parse HEAD)"
```

Important flags:

| Flag | Purpose |
|---|---|
| `--path` | Directory or single YAML file to package |
| `--source` | Original Git URL, stored as OCI metadata |
| `--revision` | Origin revision in `<branch-or-tag>@sha1:<commit>` format |
| `--output json` | Prints repository/digest for signing or provenance steps |
| `--provider aws/azure/gcp` | Uses cloud registry authentication |
| `--creds user:password` | Passes generic registry credentials directly |
| `--reproducible` | Produces deterministic digests by fixing the created timestamp |

Always set `--source` and `--revision`. Flux exposes this metadata in
`OCIRepository.status.artifact.metadata`, `flux trace`, events, notifications, and commit
status integrations.

### Tagging for Environments

Push immutable tags, then move environment tags deliberately:

```bash
IMAGE=oci://ghcr.io/org/fleet/apps/podinfo
SHA_TAG=$(git rev-parse --short HEAD)

flux push artifact ${IMAGE}:${SHA_TAG} \
  --path="./deploy/staging" \
  --source="$(git config --get remote.origin.url)" \
  --revision="$(git branch --show-current)@sha1:$(git rev-parse HEAD)"

flux tag artifact ${IMAGE}:${SHA_TAG} --tag latest
```

For production releases:

```bash
TAG=$(git tag --points-at HEAD)

flux push artifact oci://ghcr.io/org/fleet/apps/podinfo:${TAG} \
  --path="./deploy/production" \
  --source="$(git config --get remote.origin.url)" \
  --revision="${TAG}@sha1:$(git rev-parse HEAD)"

flux tag artifact oci://ghcr.io/org/fleet/apps/podinfo:${TAG} --tag latest-stable
```

Prefer these conventions:

| Tag | Use |
|---|---|
| Git SHA | Immutable CI build identity |
| Semver tag (`v1.2.3`) | Release identity |
| `latest` | Staging or development channel |
| `latest-stable` | Production channel if promotion is tag-based |
| Semver selector | Production channel if promotion follows version ranges |

## GitHub Actions Publisher

Example workflow that validates the Kubernetes manifests with Flux Schema plugin,
packages and signs the OCI artifact with keyless Cosign.

```yaml
name: publish

on:
  workflow_dispatch:
  push:
    branches:
      - 'main'
    tags:
      - '*'

jobs:
  flux-push:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write # for pushing
      id-token: write # for signing
    steps:
      - name: Checkout
        uses: actions/checkout@v7
      - name: Setup cosign
        uses: sigstore/cosign-installer@main
      - name: Setup Flux CLI with plugins
        uses: fluxcd/flux2/action@main
        with:
          plugins: |
            schema
      - name: Validate manifests
        uses: fluxcd/flux-schema/actions/validate@main
        with:
          path: "."
      - name: Prepare tags
        id: prep
        run: |
          TAG=latest
          VERSION="${{ github.ref_name }}-${GITHUB_SHA::8}"
          if [[ $GITHUB_REF == refs/tags/* ]]; then
            TAG=latest-stable
            VERSION="${{ github.ref_name }}"
          fi
          echo "tag=${TAG}" >> $GITHUB_OUTPUT
          echo "version=${VERSION}" >> $GITHUB_OUTPUT
      - name: Login to GitHub Container Registry
        uses: docker/login-action@v4
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - name: Push artifact
        uses: controlplaneio-fluxcd/distribution/actions/push@main
        id: push
        with:
          repository: ghcr.io/${{ github.repository }}
          path: "./"
          diff-tag: ${{ steps.prep.outputs.tag }}
          tags: ${{ steps.prep.outputs.version }}
      - name: Sign artifact
        if: steps.push.outputs.pushed == 'true'
        run: cosign sign --yes $DIGEST_URL
        env:
          DIGEST_URL: ${{ steps.push.outputs.digest-url }}
```

The artifacts published by this workflow are tagged as:

- `main-<commit-short-sha>` for the main branch commits.
- `latest` points to the latest artifact tagged as `main-<commit-short-sha>`.
- `vX.Y.Z` for the release tags.
- `latest-stable` points to the latest artifact tagged as `vX.Y.Z`.

## Consuming Manifest Artifacts

Use `OCIRepository` as the source and point `Kustomization` at it:

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata:
  name: apps
  namespace: flux-system
spec:
  interval: 5m
  url: oci://ghcr.io/org/k8s-apps
  ref:
    tag: latest
  verify:
    provider: cosign
    matchOIDCIdentity:
      - issuer: ^https://token\.actions\.githubusercontent\.com$
        subject: ^https://github\.com/org/k8s-apps/\.github/workflows/publish\.yaml@refs/heads/main$
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: infra
  namespace: flux-system
spec:
  interval: 10m
  retryInterval: 2m
  sourceRef:
    kind: OCIRepository
    name: apps
  path: ./
  prune: true
  wait: true
  timeout: 5m
  targetNamespace: apps
```

For production releases, use a semver selector or the promoted channel tag:

```yaml
spec:
  ref:
    semver: ">=1.0.0 <2.0.0"
```

```yaml
spec:
  ref:
    tag: latest-stable
```

## FluxInstance OCI Sync

To make the cluster bootstrap itself Gitless, configure `FluxInstance.spec.sync` to use
`OCIRepository`:

```yaml
spec:
  sync:
    kind: OCIRepository
    url: oci://ghcr.io/org/fleet/clusters
    ref: latest-stable
    path: clusters/production
    pullSecret: ghcr-auth
```

The operator creates an `OCIRepository` and a root `Kustomization` named `flux-system`.
For the full FluxInstance spec and the `kustomize.patches` snippet that adds Cosign
signature verification to the generated `OCIRepository`, load `references/flux-operator.md`.

## Authentication

For CI publishing:

- `flux push artifact` reads `~/.docker/config.json`, so Docker login works for GHCR,
  Docker Hub, Harbor, and similar registries.
- Use `--creds user:password` for one-off generic credentials.
- Use `--provider aws`, `--provider azure`, or `--provider gcp` for cloud provider
  registry auth.

For cluster pulls:

```bash
flux create secret oci ghcr-auth \
  --namespace=flux-system \
  --url=ghcr.io \
  --username=flux \
  --password="${GHCR_TOKEN}"
```

```yaml
spec:
  provider: generic
  secretRef:
    name: ghcr-auth
```

On managed Kubernetes, prefer contextual authorization where possible:

```yaml
spec:
  provider: aws # or azure, gcp
  serviceAccountName: flux
```

## Signing and Verification

Keyless Cosign in CI signs with the GitHub Actions OIDC identity. Flux verifies the
signature before storing the artifact:

```yaml
spec:
  verify:
    provider: cosign
    matchOIDCIdentity:
      - issuer: ^https://token\.actions\.githubusercontent\.com$
        subject: ^https://github\.com/org/repo/\.github/workflows/publish\.yaml@refs/heads/main$
```

For release tags, constrain the subject to tag refs:

```yaml
subject: ^https://github\.com/org/repo/\.github/workflows/publish\.yaml@refs/tags/v\d+\.\d+\.\d+$
```

If verification fails, source-controller marks the `OCIRepository` as not Ready and does
not make the artifact available to downstream `Kustomization` or `HelmRelease` resources.

## Promotion Patterns

| Pattern                  | How it works                                                 | Best for                       |
|--------------------------|--------------------------------------------------------------|--------------------------------|
| Moving channel tag       | CI retags immutable build as `latest` or `latest-stable`     | Simple staging/prod channels   |
| Semver selector          | Production `OCIRepository.ref.semver` selects latest release | Release-driven production      |
| Digest pin               | `ref.digest` points to exact digest                          | Maximum reproducibility        |
| ResourceSetInputProvider | Scans registry tags and templates selected tag/digest        | Gitless image/chart automation |

Do not mutate cluster manifests in Git just to promote OCI artifacts unless a Git audit trail of
promotions is a hard requirement. If Git mutation is required, use
`ImageRepository` + `ImagePolicy` + `ImageUpdateAutomation` instead.

## Observability and Tracing

Inspect pulled artifacts:

```bash
flux get sources oci -A
kubectl -n flux-system describe ocirepository podinfo
```

Trace a live workload back to its OCI artifact and Git origin:

```bash
flux -n apps trace deployment podinfo
```

When artifacts are pushed with `--source` and `--revision`, Flux records:

- `org.opencontainers.image.source`
- `org.opencontainers.image.revision`
- artifact digest and revision

Configure `Provider` + `Alert` resources to send notifications for `OCIRepository` and
downstream `Kustomization` or `HelmRelease` events.
