# Flux MCP Server Reference

The Flux MCP Server (`flux-operator-mcp`) enables AI assistants to interact with Kubernetes
clusters managed by Flux Operator using the Model Context Protocol (MCP). Use this reference
to guide users through setting up, configuring, and effectively using the MCP Server.

## Installation

**Homebrew (macOS/Linux):**
```shell
brew install controlplaneio-fluxcd/tap/flux-operator-mcp
```

**Binary download:** Get AMD64/ARM64 binaries from the
[GitHub releases page](https://github.com/controlplaneio-fluxcd/flux-operator/releases).

## Configuration

```json
{
  "mcpServers": {
    "flux-operator-mcp": {
      "command": "flux-operator-mcp",
      "args": ["serve"],
      "env": {
        "KUBECONFIG": "/Users/username/.kube/config"
      }
    }
  }
}
```

Replace paths with actual absolute values — `$HOME` and `~` are not expanded in JSON config.
Use `which flux-operator-mcp` and `echo $HOME/.kube/config` to find the correct paths.

For production environments, add `"--read-only"` to the `args` array to disable all tools
that modify cluster state (reconcile, suspend, resume, apply, delete).

## How to Use the MCP Tools

### General Rules

- Never assume the `apiVersion` of a Kubernetes or Flux resource — call
  `get_kubernetes_api_versions` first.
- To determine if a resource is Flux-managed, look for `fluxcd` labels in metadata.
- After switching to a new cluster context, always call `get_flux_instance` to check
  the Flux installation before doing anything else.
- Avoid applying changes to Flux-managed resources unless explicitly requested —
  Flux will revert manual changes on the next reconciliation.
- Secret values are masked by default — the MCP server returns only the `data` keys
  with empty values.

### Cluster Context Switching

When working with a specific cluster:

1. Call `get_kubeconfig_contexts` to list available contexts.
2. Find the context matching the user's cluster name.
3. Call `set_kubeconfig_context` to switch to it.
4. Call `get_flux_instance` to verify the Flux installation.

When running in-cluster, context switching is disabled — only the local cluster is available.
To compare across clusters, deploy the MCP server in each cluster.

### Cluster Inspection

To report on the current state of a cluster:

1. Call `get_flux_instance` to get Flux version, components, health, and sync status.
2. Call `get_kubernetes_resources` with `kind: Kustomization` and `namespace: flux-system`
   to list the top-level Kustomizations and their status.
3. Call `get_kubernetes_resources` with `kind: HelmRelease` across all namespaces to
   find any failing releases.
4. Check for suspended resources — `spec.suspend: true` means intentionally paused.
5. If controllers are unhealthy, get their pod logs with `get_kubernetes_logs`.

### Troubleshooting a HelmRelease

1. Call `get_flux_instance` to check helm-controller status and the HelmRelease `apiVersion`.
2. Call `get_kubernetes_resources` to get the HelmRelease — analyze spec, status, inventory, events.
3. Determine what manages the HelmRelease by looking at annotations — it can be a Kustomization
   or a ResourceSet.
4. If `valuesFrom` is present, get all referenced ConfigMaps and Secrets.
5. Identify the chart source from `chartRef` or `sourceRef` — get the source and analyze
   its status and events.
6. If the HelmRelease is failed or in progress, check managed resources from the inventory.
7. If managed resources are failing, analyze their logs with `get_kubernetes_logs`.
8. Produce a root cause analysis, or if no issues are found, report current status with
   container images.

### Troubleshooting a Kustomization

1. Call `get_flux_instance` to check kustomize-controller status and the Kustomization `apiVersion`.
2. Call `get_kubernetes_resources` to get the Kustomization — analyze spec, status, inventory, events.
3. Determine what manages the Kustomization by looking at annotations — it can be another
   Kustomization or a ResourceSet.
4. If `substituteFrom` is present, get all referenced ConfigMaps and Secrets.
5. Get the source from `sourceRef` and analyze its status and events.
6. If the Kustomization is failed or in progress, check managed resources from the inventory.
7. If managed resources are failing, analyze their logs with `get_kubernetes_logs`.
8. Produce a root cause analysis, or if no issues are found, report current status.

### Troubleshooting a ResourceSet

1. Call `get_flux_instance` to check Flux Operator status and the ResourceSet `apiVersion`.
2. Call `get_kubernetes_resources` to get the ResourceSet — analyze spec, status, events.
3. If `inputsFrom` is used, get each ResourceSetInputProvider and check its status.
   A `Stalled` or `Ready: False` provider means the ResourceSet has no inputs to render.
4. If `dependsOn` is present, get each dependency and verify it is `Ready`.
5. Check the inventory for generated resources — get generated Kustomizations or HelmReleases
   and analyze their status.
6. For failing generated resources, follow the HelmRelease or Kustomization troubleshooting
   workflow above.
7. Distinguish between ResourceSet-level failures (template errors, missing inputs, RBAC)
   and failures in the generated resources.

### Analyzing Kubernetes Logs

1. Get the Deployment managing the pods with `get_kubernetes_resources`.
2. Extract `matchLabels` and the container name from the deployment spec.
3. List pods with `get_kubernetes_resources` using the `matchLabels` as `selector`.
4. Call `get_kubernetes_logs` with the pod name and container name.
5. Analyze for errors, warnings, and patterns indicating root cause.

### Multi-Cluster Comparison

1. Call `get_kubeconfig_contexts` to get all cluster contexts.
2. For each cluster:
   a. Call `set_kubeconfig_context` to switch.
   b. Call `get_flux_instance` to check Flux status.
   c. Call `get_kubernetes_resources` to get the resources to compare.
   d. If the resource has `valuesFrom` or `substituteFrom`, also get referenced ConfigMaps/Secrets.
3. Compare the `spec` (desired state) across clusters — this is the main focus.
4. Note differences in `status` and `events` (current state per cluster).

### Reconciliation Workflows

**Force reconciliation of a pipeline:**
1. Reconcile the source first: `reconcile_flux_source` with the source kind, name, namespace.
2. Then reconcile the applier: `reconcile_flux_kustomization` or `reconcile_flux_helmrelease`.
3. Use `with_source: true` on Kustomization/HelmRelease to do both in one call.

**Reconcile in dependency order:**
1. Get all Kustomizations in `flux-system` namespace.
2. Read their `dependsOn` fields to determine the order.
3. Reconcile from leaf dependencies to root, verifying `Ready` status after each.

**Suspend all failing resources:**
1. Get all Kustomizations or HelmReleases with failing status.
2. Call `suspend_flux_reconciliation` for each, using the correct `apiVersion` and `kind`.
3. After fixing the underlying issue, call `resume_flux_reconciliation` to re-enable them.

### Applying Manifests

When generating and applying YAML:

1. Read the relevant OpenAPI schema from the knowledge base to verify field names and types.
2. Generate the YAML manifest.
3. Call `apply_kubernetes_manifest` with the YAML content.
4. If the resource is Flux-managed, the tool will error unless `overwrite: true` is set.
   Warn the user that Flux will revert changes on next reconciliation.
5. Verify the applied resource with `get_kubernetes_resources`.
