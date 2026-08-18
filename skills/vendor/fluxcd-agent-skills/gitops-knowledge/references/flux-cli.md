# Flux CLI and Plugins for Agents

The Flux CLI and its plugins turn manifest authoring from an open-loop guess into a
closed loop: discover the repository layout before placing files, render overlays and
templates locally to see exactly what Flux would apply, and validate every document
against OpenAPI schemas before handing the result back to the user. All commands here
run offline against local files — no cluster access is required unless noted.

Use this reference when working inside a GitOps repository, when generated manifests
need schema validation, when a Kustomize overlay or ResourceSet must be rendered and
debugged locally, or when users ask about the `flux schema` plugin, `flux build`,
`flux envsubst`, or `flux-operator build`.

**Contents:** [Plugin Setup](#plugin-setup) | [Repository Discovery](#repository-discovery-with-flux-schema-discover) | [The Authoring Control Loop](#the-authoring-control-loop-with-flux-schema-validate) | [Schemas for Custom CRDs](#schemas-for-custom-crds) | [Rendering Manifests Locally](#rendering-manifests-locally) | [Debugging a Failing Overlay](#debugging-a-failing-overlay) | [When Tools Are Missing](#when-tools-are-missing)

## Plugin Setup

The `flux schema` commands come from the flux-schema plugin, installed via the
Flux CLI plugin catalog:

```bash
flux plugin install schema     # installs flux-schema
flux plugin install operator   # installs flux-operator (for ResourceSet/FluxInstance builds)
flux plugin list               # show installed plugins and versions
flux plugin update             # update all installed plugins
```

Installed plugins are invoked through the Flux CLI (`flux schema ...`,
`flux operator ...`) or directly as `flux-schema` / `flux-operator` binaries —
both forms are equivalent.

## Repository Discovery with `flux schema discover`

Before creating or moving files in a GitOps repository, inventory it. One command
replaces a long series of glob and grep probes, and the classification tells you where
new manifests belong so you follow the repository's existing conventions:

```bash
# Human-readable inventory of the current directory
flux schema discover

# Machine-readable, for picking paths programmatically
flux schema discover -o json

# Scope to a subtree, skip test fixtures
flux schema discover ./clusters/production --skip-file 'tests'
```

The output lists Flux custom resources per file, counts plain Kubernetes resources by
kind, and classifies every directory as `manifests`, `kustomize-overlay`, `helm-chart`,
or `terraform`. Dotfiles and dot-directories (`.git`, `.github`) are skipped by default.

Read the inventory before answering questions like "where should this HelmRelease go?"
— the existing sources, Kustomizations, and overlay structure define the answer far
better than generic conventions do.

## The Authoring Control Loop with `flux schema validate`

Reading the bundled OpenAPI schemas before generating YAML prevents most mistakes, but
not all of them: indentation slips, fields pasted at the wrong nesting level, and
non-Flux resources (Deployments, Services, HPAs) that the bundled schemas don't cover.
Validation catches what reading misses, so treat it as part of authoring, not a
separate QA step:

1. Write or edit the manifests.
2. Run `flux schema validate` on the files (or on the rendered build output).
3. Read the errors — each one names the file, the document, and the JSON path at fault.
4. Fix and re-run until the command exits clean.

```bash
# Plain-manifest directories: validate the files directly
flux schema validate ./clusters/production --verbose

# Kustomize overlays: validate the rendered build output, not the source files
kustomize build ./apps/staging/podinfo | flux schema validate

# Tolerate third-party CRDs that have no schema in the catalog
flux schema validate ./clusters/production --skip-missing-schemas
```

Pick the mode per directory using the `flux schema discover` classification:
directories classified `kubernetes-manifests` contain complete documents and validate
directly; directories classified `kustomize-overlay` contain partial documents —
`kustomization.yaml` build configs (no `metadata.name`) and strategic-merge patches
(e.g. a HelmRelease values fragment with no `spec.interval`) — which fail standalone
validation with false positives. Always validate an overlay through its build output.

The default catalog covers the latest stable Kubernetes and Flux APIs, and validation
also evaluates the CEL rules (`x-kubernetes-validations`) embedded in the Flux CRDs —
it catches cross-field mistakes like mutually exclusive fields both being set, which
plain structural checks miss.

Important flags:

| Flag | Purpose |
|---|---|
| `--verbose` | Print a line per document, including valid and skipped ones — confirms nothing was silently skipped |
| `--skip-missing-schemas` | Skip documents with no schema in the catalog instead of failing (third-party CRDs) |
| `--schema-location` | Add a schema source (repeatable): `default` for the built-in catalog, a local directory written by `flux schema extract`, or a URL such as `https://raw.githubusercontent.com/datreeio/CRDs-catalog/main` |
| `--skip-kind` | Skip documents by `Kind` or `apiVersion/Kind`, e.g. `--skip-kind v1/Secret` |
| `--skip-json-path` | Strip a field before validation, e.g. `--skip-json-path v1/Secret:/sops` for SOPS metadata that Flux removes at apply time |
| `--skip-file` | Glob matched against file and directory basenames, e.g. `--skip-file 'kustomization.yaml'` when validating overlay sources rather than build output |
| `-o json` | Structured results for programmatic triage |

Repositories can pin their validation conventions in a checked-in config so every run
uses the same skips and schema sources — look for `.fluxschema.yml` in the repo root
and pass it with `--config` (CLI flags still override).

Encrypted SOPS Secrets and files containing unresolved substitution variables are the
usual sources of false positives: skip Secrets with `--skip-kind v1/Secret` or strip
metadata with `--skip-json-path`, and resolve variables with `flux envsubst` before
validating (see below).

## Schemas for Custom CRDs

When a repository ships CRDs the catalog doesn't know (internal operators, niche
projects), extract schemas from the CRD manifests themselves and feed them back into
validation:

```bash
# Extract JSON Schemas from CRD YAML files (or stdin) into a local directory
flux schema extract crd ./crds/my-operator-crds.yaml -d ./my-schemas
kustomize build ./config/crd | flux schema extract crd -d ./my-schemas

# Validate with the default catalog plus the extracted schemas
flux schema validate ./apps --schema-location default --schema-location ./my-schemas
```

`flux schema extract k8s --version 1.35.0 -d ./my-schemas` does the same from a
Kubernetes OpenAPI v2 swagger document, which is how you validate against a specific
Kubernetes minor version instead of the catalog default.

## Rendering Manifests Locally

Flux applies *rendered* output — Kustomize overlays after patching, ResourceSet
templates after input expansion, variables after substitution. Rendering locally shows
that exact output without a cluster, and piping it into `flux schema validate` closes
the loop on the real thing rather than the source files:

```bash
# Does the overlay even build? (kubectl kustomize works too)
kustomize build ./apps/staging

# Render exactly what kustomize-controller would apply for a Flux Kustomization,
# including postBuild substitutions — offline with --dry-run
flux build kustomization my-app \
  --path ./apps/staging \
  --kustomization-file ./clusters/staging/my-app.yaml \
  --dry-run | flux schema validate

# Replicate postBuild.substitute locally with environment variables;
# --strict fails on variables without a default that are missing from the env
export cluster_region=eu-central-1
kustomize build ./clusters/staging | flux envsubst --strict

# Expand a ResourceSet template into the objects it would generate
flux operator build resourceset -f my-resourceset.yaml \
  --inputs-from my-inputs.yaml | flux schema validate

# Render the full Flux installation a FluxInstance would produce
flux operator build instance -f flux.yaml
```

Notes:

- `flux build kustomization --dry-run` needs no cluster, but skips substitutions that
  come from in-cluster Secrets and ConfigMaps — use `flux envsubst` with exported
  variables to fill those in locally. Without `--dry-run` it fetches the Kustomization
  from the cluster instead of `--kustomization-file`.
- `--recursive` with `--local-sources GitRepository/flux-system/my-repo=./` builds a
  whole Kustomization tree from a local checkout — useful for validating an entire
  cluster directory in one pass.
- `flux operator build resourceset` accepts inputs from the ResourceSet itself
  (`spec.inputs`), a separate inputs file (`--inputs-from`), or static
  ResourceSetInputProvider manifests (`--inputs-from-provider`).
- `flux operator build instance` pulls the distribution artifact from
  `ghcr.io/controlplaneio-fluxcd` — it needs registry network access, unlike the
  other commands here.

## Debugging a Failing Overlay

When a user reports that a Kustomization fails to build or apply, reproduce it locally
instead of reasoning about the YAML in the abstract:

1. `flux schema discover` — locate the Flux Kustomization definition and the overlay
   path it points at.
2. `kustomize build <path>` — surfaces broken patches, missing resources, and bad
   `kustomization.yaml` references with exact error messages.
3. `flux build kustomization <name> --path <path> --kustomization-file <file> --dry-run`
   — adds the Flux layer: postBuild substitutions, name/namespace overrides.
4. Pipe the successful build into `flux schema validate` — catches documents that
   build fine but would be rejected by the API server or a Flux controller.
5. Fix the source files and re-run from the failing step until the whole chain is clean.

Each step isolates one layer (Kustomize syntax → Flux transformations → schema
correctness), so the first failing step tells you which layer holds the bug.

## When Tools Are Missing

These commands are force multipliers, not hard requirements. If `flux`, a plugin, or
`kustomize` isn't installed, don't fail the task and don't install tools unprompted:
fall back to reading the bundled schemas in `assets/schemas/`, complete the work, and
tell the user which verification was skipped and how to enable it
(`flux plugin install schema`). A correct answer with a noted verification gap beats
a stalled task.
