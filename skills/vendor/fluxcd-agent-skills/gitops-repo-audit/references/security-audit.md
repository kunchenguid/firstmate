# Flux GitOps Security Audit

Checklist for auditing GitOps repository security posture. Each item describes what
to look for and why it matters. Not all items apply to every repo — judge based on
the repo's deployment model (single-tenant vs multi-tenant) and infrastructure.

## Secrets Management

- [ ] **Secrets encryption strategy**: Identify which secret management approach the repo uses — SOPS (look for `sops:` metadata block in Secret manifests and `ENC[` prefixed values in data fields, plus `.spec.decryption` on Flux `Kustomization`), External Secrets Operator (look for `ExternalSecret` or `ClusterSecretStore` resources), or Sealed Secrets (look for `SealedSecret` resources).
- [ ] **No plain-text secrets in Git**: Flag any `apiVersion: v1` / `kind: Secret` manifest where values are not SOPS-encrypted (no `sops:` metadata block and no `ENC[` prefixed values) as they indicate unencrypted secrets stored in Git
- [ ] **No plain-text secrets in Kustomize overlays**: Flag any `secretGenerator` in `kustomization.yaml` files that contains `literals`, `envs`, or `files` referencing plaintext files (without `ENC[` SOPS markers). Also check `configMapGenerator` with `literals`, `envs`, or `files` for credential-like values (passwords, keys, tokens, connection strings)

## Hardcoded Credentials

Scan for literal credentials patterns in the following places:

- [ ] **HelmReleases**: Search in `.spec.values:` fields
- [ ] **Kustomizations**: Search in `.spec.postBuild.substitute:` and `.spec.patches:` fields
- [ ] **ConfigMaps**: Search in `data:` fields
- [ ] **Kustomize overlay**: Search in `kustomization.yaml` files for `configMapGenerator` with `literals` or `envs`

## Source Authentication

- [ ] **No insecure sources**: Check for `insecure: true` on any GitRepository, OCIRepository, Bucket, or HelmRepository. All sources should use TLS (the default). Flag any source that disables TLS verification
- [ ] **Read-only Git credentials**: Git deploy keys, PATs, or GitHub App credentials used in `.spec.secretRef` should have read-only access to the repository. The agent cannot verify the actual permissions, but flag repos where the same Secret is used for both source fetching and image automation push (which requires write access)
- [ ] **Workload Identity for cloud registries**: OCIRepositories and ImageRepositories pointing to AWS (ECR), GCP (Artifact Registry/GCR), or Azure (ACR) should set `.spec.provider` to `aws`, `gcp`, or `azure` to use Workload Identity instead of static credentials stored in Secrets
- [ ] **Secret references present**: Sources that require authentication (private Git repos, private registries, private Helm repos) should have `.spec.secretRef` configured, unless using Workload Identity via `.spec.provider`
- [ ] **GitHub App auth for FluxInstance sync**: If a FluxInstance uses `sync.kind: GitRepository` with a GitHub URL, recommend setting `sync.provider: github` with GitHub App authentication. The referenced Secret should contain `githubAppID` and `githubAppPrivateKey` fields — avoid reliance on personal access tokens

## OCI Supply Chain Security

- [ ] **Cosign signature verification**: OCI sources (OCIRepository) should use `.spec.verify.provider: cosign`. Especially important for production clusters
- [ ] **Immutable tags in production**: OCIRepositories for production should reference semver tags or digests, not `latest` or mutable tags. Use `.spec.ref.semver` or `.spec.ref.digest` instead of `.spec.ref.tag: latest`
- [ ] **No HelmRepository with `type: oci`**: `HelmRepository` with `.spec.type: oci` is a legacy pattern. Migrate to OCIRepository with `.spec.chartRef` on HelmRelease

## Multi-Tenancy and RBAC

- [ ] **Service accounts per tenant**: Each tenant's Kustomizations and HelmReleases should use a dedicated `serviceAccountName` with scoped RBAC (RoleBindings, not ClusterRoleBindings). Exception: if FluxInstance has `cluster.multitenant: true`, the operator sets a default service account for all controllers via `tenantDefaultServiceAccount` — individual resources don't need `serviceAccountName` explicitly
- [ ] **No cross-namespace source refs**: In multi-tenant setups, check for `sourceRef.namespace` where a Kustomization or HelmRelease in one namespace references a source in another namespace. This bypasses tenant isolation. Enable `--no-cross-namespace-refs=true` on controllers (via FluxInstance `multitenant: true` or kustomize patches)
- [ ] **Default service account enforcement**: Controllers should have `--default-service-account=default` set to prevent privilege escalation when `serviceAccountName` is omitted. With FluxInstance `multitenant: true` this is automatic
- [ ] **No cluster-admin for apps**: Apps service accounts should be bound to Roles or ClusterRoles with minimal permissions (only the namespaces and resource types the tenant needs), not `cluster-admin`
- [ ] **Admission policies**: Verify that ValidatingAdmissionPolicy, Kyverno ClusterPolicies, or OPA Gatekeeper constraints exist to restrict tenant source URLs and enforce resource quotas. Without admission policies, tenants can reference arbitrary external sources

## Network Policies

- [ ] **Flux controller network policies**: Both `flux bootstrap` and FluxInstance deploy network policies for controller pods by default. For FluxInstance, `cluster.networkPolicy` defaults to `true` — only flag if explicitly set to `false`. For bootstrap installs, policies are in `gotk-components.yaml`. Do not flag as missing unless intentionally removed
- [ ] **Application network policies**: Check if the repo includes NetworkPolicy resources for application workloads to limit pod-to-pod communication. Especially important in multi-tenant clusters

## Flux Operator Security

- [ ] **Multi-tenant mode enabled**: If the cluster has multiple tenants, check that FluxInstance has `.spec.cluster.multitenant: true`. This enforces service account impersonation, disables cross-namespace refs, and sets a default service account on all controllers
- [ ] **Network policies not disabled**: Check that FluxInstance does not set `.spec.cluster.networkPolicy: false`. Omitting the field is fine (defaults to `true`)
- [ ] **Distribution registry**: If FluxInstance uses a custom `.spec.distribution.registry`, verify it points to an internal/trusted registry, not an unverified third-party source

## Image Automation Security

- [ ] **Push credentials separated from pull**: If image automation is configured (ImageUpdateAutomation), the GitRepository used for pushing commits requires write access. This should be a separate Secret from the read-only credentials used for source fetching
- [ ] **Push branch isolation**: ImageUpdateAutomation should push to a separate branch (`.spec.git.push.branch`) rather than directly to the main branch, allowing PR review before changes are applied
- [ ] **Tag filtering**: ImagePolicies should use `.spec.filterTags.pattern` and semver ranges to restrict which tags can be promoted. Avoid open-ended policies that accept any tag

## Scanning Procedures

Use the following grep patterns to find common security issues. Run ALL of these
scans — do not skip any, even if earlier checklist items found no issues.

**Find unencrypted Secrets (no SOPS encryption):**
Search for files containing `kind: Secret` then check if the same file contains `sops:` metadata block or `ENC[` prefixed values — if neither is present, the Secret is likely unencrypted.

**Find secretGenerator and configMapGenerator with literals or files:**
Search all `kustomization.yaml` files for `secretGenerator` and `configMapGenerator` blocks.
Read each match and check for `literals:`, `envs:`, or `files:` entries. Flag `secretGenerator` with
`literals`, `envs`, or `files` referencing plaintext content (no `ENC[` SOPS markers) as plain-text secrets in Git.
Flag `configMapGenerator` `literals`, `envs`, or `files` that contain credential-like values
(passwords, keys, tokens, connection strings).

**Find hardcoded credentials:**
Search for patterns: `password:`, `token:`, `privateKey:`, `clientSecret:`, `apiKey:`, `secretKey:`, `accessKey:`, `connectionString:` in YAML files.
Cross-reference with Secret resources to distinguish Flux-managed secrets from inline values.
Also search for credential-like patterns inside literal strings: `PASSWORD=`, `_KEY=`,
`_SECRET=`, `_TOKEN=`, `ACCESS_KEY=`, `CONNECTION_STRING=` — these appear in
`secretGenerator`/`configMapGenerator` literals and environment variable definitions.
Skip values containing `ENC[` — these are SOPS-encrypted and not plain-text credentials.

**Find insecure sources:**
Search for `insecure: true` across all YAML files.

**Find cross-namespace refs:**
Search for `sourceRef:` blocks where `namespace:` differs from the resource's own namespace. Look for `.spec.sourceRef.namespace` and `.spec.chartRef.namespace` fields.

**Find missing service accounts in multi-tenant setups:**
Search for Kustomization and HelmRelease resources that lack `serviceAccountName` (unless FluxInstance `multitenant: true` is set).

**Find sources without auth:**
Search for GitRepository, OCIRepository, HelmRepository, and Bucket resources that have no `.spec.secretRef` and no `.spec.provider` set (indicating neither explicit credentials nor Workload Identity).

**Find cloud registries without Workload Identity:**
Search for OCIRepository and ImageRepository resources where `.spec.url` contains `ecr.`, `.gcr.io`, `pkg.dev`, or `.azurecr.io` but `.spec.provider` is not set to `aws`, `gcp`, or `azure`.
