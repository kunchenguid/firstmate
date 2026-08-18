# Image Automation Reference

Image automation scans container registries, selects tags based on policies, and
updates YAML files in Git repositories with new image references.

**Pipeline:** ImageRepository → ImagePolicy → ImageUpdateAutomation

1. **ImageRepository** scans a container registry and stores available tags
2. **ImagePolicy** selects the latest tag based on a version policy
3. **ImageUpdateAutomation** updates YAML files in Git with the selected image

All three resources use `apiVersion: image.toolkit.fluxcd.io/v1`.

Required controllers: `image-reflector-controller` and `image-automation-controller`
(add to FluxInstance components only on clusters that run automation).

**Contents:** [ImageRepository](#imagerepository) | [ImagePolicy](#imagepolicy) | [ImageUpdateAutomation](#imageupdateautomation) | [Image Policy Markers](#image-policy-markers) | [Complete End-to-End Pipeline](#complete-end-to-end-pipeline)

## ImageRepository

Scans a container image repository at regular intervals and stores discovered tags.

### Canonical YAML

```yaml
apiVersion: image.toolkit.fluxcd.io/v1
kind: ImageRepository
metadata:
  name: my-app
  namespace: flux-system
spec:
  image: ghcr.io/org/my-app
  interval: 5m
  provider: generic
  exclusionList:
    - "^sha-"
    - ".*-rc\\d+$"
```

### Key Spec Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `image` | string | yes | Image name without tag (e.g., `ghcr.io/org/app`) |
| `interval` | duration | yes | Scan interval |
| `provider` | string | no | Registry auth provider: `generic` (default), `aws`, `azure`, `gcp` |
| `secretRef.name` | string | no | Secret of type `kubernetes.io/dockerconfigjson` for auth |
| `exclusionList` | array | no | Regex patterns — matching tags are excluded from results |
| `insecure` | bool | no | Allow HTTP (non-TLS) connections |
| `suspend` | bool | no | Pause scanning |

**Cloud registry providers:**
- `aws` — uses IRSA/pod identity for ECR authentication
- `azure` — uses workload identity for ACR authentication
- `gcp` — uses workload identity for GAR/GCR authentication
- `generic` — uses `secretRef` with dockerconfigjson

## ImagePolicy

Selects the latest image tag from an ImageRepository based on a version policy.

### Canonical YAML

```yaml
apiVersion: image.toolkit.fluxcd.io/v1
kind: ImagePolicy
metadata:
  name: my-app
  namespace: flux-system
spec:
  imageRepositoryRef:
    name: my-app
  policy:
    semver:
      range: ">=1.0.0"
  filterTags:
    pattern: "^v(?P<version>.*)$"
    extract: "$version"
```

### Key Spec Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `imageRepositoryRef.name` | string | yes | ImageRepository to select from |
| `imageRepositoryRef.namespace` | string | no | Cross-namespace reference |
| `policy` | object | yes | Selection policy (one of semver/alphabetical/numerical) |
| `filterTags.pattern` | string | no | Regex to filter tags before policy applies |
| `filterTags.extract` | string | no | Regex group to extract version from tag |
| `digestReflectionPolicy` | string | no | `Never` (default), `IfNotPresent`, or `Always` — when to resolve digest |

### Policy Types

**Semver (most common):**
```yaml
spec:
  policy:
    semver:
      range: ">=1.0.0"              # any version >= 1.0.0
      # range: "1.x"                # any 1.x version
      # range: ">=1.0.0 <2.0.0"     # 1.x range
```

**Alphabetical:**
```yaml
spec:
  policy:
    alphabetical:
      order: asc   # or desc
```

**Numerical:**
```yaml
spec:
  policy:
    numerical:
      order: asc   # or desc
```

### Tag Filtering

Filter tags before the policy is applied. Useful for extracting version numbers
from tags with prefixes:

```yaml
spec:
  filterTags:
    pattern: "^v(?P<version>[0-9]+\\.[0-9]+\\.[0-9]+)$"
    extract: "$version"
```

This extracts `1.2.3` from tag `v1.2.3` before applying semver policy.

For tags with both version and build metadata (e.g., `v1.2.3-abc123`):
```yaml
spec:
  filterTags:
    pattern: "^v(?P<version>[0-9]+\\.[0-9]+\\.[0-9]+)-[a-f0-9]+$"
    extract: "$version"
```

### Status

```yaml
status:
  latestRef:
    image: ghcr.io/org/my-app
    tag: "1.5.0"
    digest: "sha256:abc123..."
```

## ImageUpdateAutomation

Updates YAML files in a Git repository with new image references selected by ImagePolicy.

### Canonical YAML

```yaml
apiVersion: image.toolkit.fluxcd.io/v1
kind: ImageUpdateAutomation
metadata:
  name: my-app
  namespace: flux-system
spec:
  interval: 30m
  sourceRef:
    kind: GitRepository
    name: my-app
  git:
    checkout:
      ref:
        branch: main
    commit:
      author:
        name: flux-bot
        email: flux@example.com
      messageTemplate: |
        Automated image update

        Files:
        {{ range $filename, $_ := .Changed.FileChanges -}}
        - {{ $filename }}
        {{ end -}}

        Objects:
        {{ range $resource, $changes := .Changed.Objects -}}
        - {{ $resource.Kind }} {{ $resource.Name }}
          Changes:
        {{- range $_, $change := $changes }}
            - {{ $change.OldValue }} -> {{ $change.NewValue }}
        {{ end -}}
        {{ end -}}
    push:
      branch: image-updates
  update:
    path: ./deploy
    strategy: Setters
```

### Key Spec Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `sourceRef.kind` | string | yes | `GitRepository` |
| `sourceRef.name` | string | yes | Git source to update |
| `interval` | duration | yes | How often to check for updates |
| `git.checkout.ref.branch` | string | no | Branch to checkout (default: source branch) |
| `git.commit.author.name` | string | no | Commit author name |
| `git.commit.author.email` | string | yes | Commit author email |
| `git.commit.messageTemplate` | string | no | Go template for commit message |
| `git.commit.signingKey.secretRef.name` | string | no | Secret with an OpenPGP or SSH key to sign the commit |
| `git.push.branch` | string | no | Branch to push to (enables PR workflow) |
| `update.path` | string | no | Directory to scan for image markers (default: repository root) |
| `update.strategy` | string | no | `Setters` (default) |
| `suspend` | bool | no | Pause automation |

### Push Branch Isolation

For a PR-based workflow, push to a separate branch:

```yaml
spec:
  git:
    push:
      branch: image-updates
```

This creates/updates a branch with the image changes. Set up a CI workflow or
manual process to create PRs from this branch and merge into main.

### Signed Commits

Sign the automation commits with an OpenPGP or SSH key so the pushed commits carry a
verifiable signature (which a downstream `GitRepository` with `spec.verify` can then enforce):

```yaml
spec:
  git:
    commit:
      author:
        name: flux-bot
        email: flux@example.com
      signingKey:
        secretRef:
          name: git-signing-key
```

The referenced Secret holds either:
- **OpenPGP** — a `git.asc` ASCII-armored key pair (and optional `passphrase`), or
- **SSH** — an `identity` SSH private key.

### Commit Message Template

The commit message template uses Go templates with `{{ }}` delimiters (this is
the one place in Flux where Go templates are used, NOT ResourceSet).

Available template data:
- `.Changed.FileChanges` — map of filename to changes
- `.Changed.Objects` — map of resource to changes
- `.Changed.Objects[].OldValue` — previous image reference
- `.Changed.Objects[].NewValue` — new image reference

## Image Policy Markers

ImageUpdateAutomation finds images to update by scanning YAML files for special
comment markers.

### Marker Format

```yaml
# Update the full image reference (registry/name:tag)
image: ghcr.io/org/my-app:1.2.3  # {"$imagepolicy": "namespace:policy-name"}

# Update only the tag
tag: 1.2.3  # {"$imagepolicy": "namespace:policy-name:tag"}

# Update only the image name (without tag)
image: ghcr.io/org/my-app  # {"$imagepolicy": "namespace:policy-name:name"}
```

**Format:** `# {"$imagepolicy": "<namespace>:<policy-name>[:<field>]"}`

**Fields:**
- No suffix: updates the full `image:tag` reference
- `:tag`: updates only the tag portion
- `:name`: updates only the image name portion
- `:digest`: updates the digest value (requires `digestReflectionPolicy: IfNotPresent` or `Always` on the ImagePolicy)

### Marker Examples

In a Deployment:
```yaml
spec:
  containers:
    - name: app
      image: ghcr.io/org/my-app:1.2.3  # {"$imagepolicy": "flux-system:my-app"}
```

In an OCIRepository (for Helm chart version tracking):
```yaml
spec:
  ref:
    semver: 6.8.0  # {"$imagepolicy": "apps:frontend-podinfo:tag"}
```

In a Kustomization overlay:
```yaml
images:
  - name: ghcr.io/org/my-app
    newTag: 1.2.3  # {"$imagepolicy": "flux-system:my-app:tag"}
```

## Complete End-to-End Pipeline

```yaml
# 1. Scan registry
apiVersion: image.toolkit.fluxcd.io/v1
kind: ImageRepository
metadata:
  name: my-app
  namespace: flux-system
spec:
  image: ghcr.io/org/my-app
  interval: 5m
---
# 2. Select latest semver tag
apiVersion: image.toolkit.fluxcd.io/v1
kind: ImagePolicy
metadata:
  name: my-app
  namespace: flux-system
spec:
  imageRepositoryRef:
    name: my-app
  policy:
    semver:
      range: ">=1.0.0"
---
# 3. Git source for the repository to update
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: my-app
  namespace: flux-system
spec:
  interval: 10m
  url: https://github.com/org/my-app.git
  ref:
    branch: main
  secretRef:
    name: git-credentials
---
# 4. Update YAML files and push to branch
apiVersion: image.toolkit.fluxcd.io/v1
kind: ImageUpdateAutomation
metadata:
  name: my-app
  namespace: flux-system
spec:
  interval: 30m
  sourceRef:
    kind: GitRepository
    name: my-app
  git:
    commit:
      author:
        name: flux-bot
        email: flux@example.com
    push:
      branch: image-updates
  update:
    path: ./deploy
    strategy: Setters
```

Then in `deploy/app.yaml`, mark the image:
```yaml
image: ghcr.io/org/my-app:1.2.3  # {"$imagepolicy": "flux-system:my-app"}
```

When a new version (e.g., `1.3.0`) is pushed to the registry:
1. ImageRepository discovers the new tag
2. ImagePolicy selects `1.3.0` as the latest matching tag
3. ImageUpdateAutomation updates the YAML file and pushes to the `image-updates` branch
4. A PR is created (manually or via CI) and merged into main
5. Flux detects the change in main and deploys the new version
