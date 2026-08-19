# Flux Web UI Reference

The Flux Web UI is built into the Flux Operator and provides a browser-based dashboard
for viewing Flux resources, triggering reconciliations, and managing workloads.
It is served on port `9080` by the `flux-operator` service.

**Contents:** [Enabling the Web UI](#enabling-the-web-ui) | [Accessing the Web UI](#accessing-the-web-ui) | [Authentication](#authentication) | [Role-Based Access Control](#role-based-access-control) | [User Actions](#user-actions) | [Audit](#audit) | [Standalone Deployment](#standalone-deployment)

## Enabling the Web UI

The Web UI is enabled by default in the Flux Operator Helm chart. To explicitly configure it:

```yaml
# Flux Operator Helm values
web:
  enabled: true
```

## Accessing the Web UI

**Port-forward (quick access):**
```bash
kubectl -n flux-system port-forward svc/flux-operator 9080:9080
# Open http://localhost:9080
```

**Ingress with TLS (production):**
```yaml
# Flux Operator Helm values
web:
  ingress:
    enabled: true
    className: nginx
    annotations:
      cert-manager.io/cluster-issuer: letsencrypt-prod
    hosts:
      - host: flux.example.com
        paths:
          - path: /
            pathType: Prefix
    tls:
      - hosts:
          - flux.example.com
        secretName: flux-web-tls
```

**Gateway API:**
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: flux-web
  namespace: flux-system
spec:
  parentRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: internet-gateway
      namespace: gateway-namespace
  hostnames:
    - flux.example.com
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: flux-operator
          namespace: flux-system
          port: 9080
```

## Authentication

### Anonymous Access (Default)

By default, the Web UI runs under the `flux-operator` service account with read-only
access. No login required. To assign a specific identity:

```yaml
web:
  config:
    authentication:
      type: Anonymous
      anonymous:
        username: flux-viewer
        groups:
          - flux-readonly
```

### Single Sign-On (SSO) with OIDC

For production, configure OAuth2/OIDC authentication. The Web UI supports any
OIDC-compliant provider (Dex, Keycloak, Microsoft Entra ID, Okta, Auth0).

```yaml
web:
  config:
    baseURL: https://flux.example.com
    authentication:
      type: OAuth2
      oauth2:
        provider: OIDC
        clientID: flux-web
        clientSecret: flux-web-secret
        issuerURL: https://dex.example.com
```

`baseURL` is required for OAuth2 redirect handling.

Default OIDC scopes requested: `openid`, `offline_access`, `profile`, `email`, `groups`.

### SSO Providers

**Dex** — lightweight OIDC provider supporting static users, GitHub, GitLab, LDAP connectors.
Supply the client credentials inline (as shown above), or keep them out of the manifest using
a Kubernetes Secret with **hyphenated** keys consumed through the HelmRelease `valuesFrom` +
`targetPath`:
```yaml
# Create the Secret with: kubectl -n flux-system create secret generic flux-web-client \
#   --from-literal=client-id=flux-web --from-literal=client-secret=<secret>
# Then map its keys onto the web config in the Flux Operator HelmRelease:
valuesFrom:
  - kind: Secret
    name: flux-web-client
    valuesKey: client-id
    targetPath: web.config.authentication.oauth2.clientID
  - kind: Secret
    name: flux-web-client
    valuesKey: client-secret
    targetPath: web.config.authentication.oauth2.clientSecret
```
Alternatively, reference an existing Secret via `web.configSecretName`, where the Secret holds a
`config.yaml` key containing the full Web Config spec (`apiVersion: web.fluxcd.controlplane.io/v1`,
`kind: Config`). There is no Secret read directly by the UI with camelCase `clientID`/`clientSecret`
keys.

**Keycloak** — create an OpenID Connect client in Keycloak admin console with
Standard flow enabled and redirect URI set to `https://flux.example.com/callback`.

**Microsoft Entra ID** — use tenant-specific issuer URL:
```yaml
issuerURL: https://login.microsoftonline.com/<TENANT-ID>/v2.0
```

With the Flux Operator Helm chart, the authentication config is supplied either inline via the
`web.config` Helm value (the Web Config spec) or via `web.configSecretName`, which references an
existing Secret in the deployment namespace containing a `config.yaml` key. With OLM/OpenShift
installations, set the `WEB_CONFIG_SECRET_NAME` environment variable in the Subscription
`config.env` to point the operator at the same kind of Secret.

### Claims Mapping and CEL Expressions

The OIDC provider maps `email` and `groups` claims to Kubernetes users/groups by default.
Custom mappings use CEL expressions:

```yaml
web:
  config:
    baseURL: https://flux.example.com
    authentication:
      type: OAuth2
      oauth2:
        provider: OIDC
        clientID: flux-web
        clientSecret: flux-web-secret
        issuerURL: https://dex.example.com
        variables:
          - name: domain
            expression: "claims.email.split('@')[1]"
        validations:
          - expression: "variables.domain == 'example.com'"
            message: "Only example.com emails are allowed"
        impersonation:
          username: "claims.email"
          groups: "claims.groups"
```

**CEL expression fields:**
- `variables` — extract and transform claim values for reuse
- `validations` — rules that must return true (login rejected otherwise)
- `profile.name` — display name shown in the UI
- `impersonation.username` / `.groups` — Kubernetes RBAC identity

## Role-Based Access Control

The Web UI impersonates the authenticated user for Kubernetes API requests.
Permissions are controlled via standard Kubernetes RBAC.

### Predefined Roles

| Role | Access | Description |
|------|--------|-------------|
| `flux-web-user` | Read-only | `get`, `list`, `watch` on all resources |
| `flux-web-admin` | Full access | Read + actions (reconcile, suspend, resume, download, restart, delete) |

### Granting Access

**Cluster-wide admin access for a group:**
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: flux-web-platform-team
subjects:
  - kind: Group
    name: platform-team
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: flux-web-admin
  apiGroup: rbac.authorization.k8s.io
```

**Namespace-scoped read-only access for a team:**
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: flux-web-dev-team
  namespace: apps
subjects:
  - kind: Group
    name: dev-team
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: flux-web-user
  apiGroup: rbac.authorization.k8s.io
```

Users without any role binding see only the main dashboard with controller health status.

### RBAC Verbs for Actions

The `flux-web-admin` role uses custom verbs beyond standard Kubernetes RBAC:

| Verb | Resources | Description |
|------|-----------|-------------|
| `reconcile` + `patch` | Flux CRDs | Force immediate reconciliation |
| `suspend` + `patch` | Flux CRDs | Pause reconciliation |
| `resume` + `patch` | Flux CRDs | Re-enable reconciliation |
| `download` | Source CRDs | Download artifact tarballs |
| `restart` + `patch` | Deployments, StatefulSets, DaemonSets | Rollout restart |
| `restart` + `create` | CronJobs, Jobs | Run CronJob immediately |
| `delete` | Pods | Delete individual pods |

## User Actions

Actions require authentication to be configured.

### GitOps Actions

- **Reconcile** — force immediate reconciliation of any Flux resource
- **Pull** — reconcile the upstream source of a Kustomization or HelmRelease
- **Suspend / Resume** — pause and re-enable reconciliation
- **Download Artifact** — download artifact tarballs from source resources

### Workload Actions

- **Rollout Restart** — rolling restart of Deployments, StatefulSets, DaemonSets
- **Run Job** — execute a CronJob immediately (creates a Job)
- **Delete Pod** — remove individual pods (controller recreates them)

## Audit

Audit events track who performed what action and when. Events are recorded as
Kubernetes Events and forwarded to Flux's notification-controller.

### Enabling Audit

```yaml
web:
  config:
    userActions:
      audit:
        - "*"  # audit all actions
    authentication:
      type: OAuth2
      oauth2:
        provider: OIDC
        clientID: flux-web
        clientSecret: flux-web-secret
        issuerURL: https://dex.example.com
```

### Audit Event Annotations

| Annotation | Description |
|------------|-------------|
| `event.toolkit.fluxcd.io/action` | Action performed (reconcile, suspend, etc.) |
| `event.toolkit.fluxcd.io/username` | User who performed the action |
| `event.toolkit.fluxcd.io/groups` | Groups of the user |
| `event.toolkit.fluxcd.io/subject` | Target workload (workload actions only) |

### Audit Notifications to Slack

```yaml
apiVersion: notification.toolkit.fluxcd.io/v1beta3
kind: Alert
metadata:
  name: web-actions-audit
  namespace: flux-system
spec:
  providerRef:
    name: slack
  eventSources:
    - kind: Kustomization
      name: "*"
    - kind: HelmRelease
      name: "*"
    - kind: ResourceSet
      name: "*"
  inclusionList:
    - ".*on the web UI$"
```

The `inclusionList` regex matches the audit event message format, filtering only
Web UI action events from regular Flux events.

## Standalone Deployment

For environments where you want the Web UI separate from the Flux Operator, deploy
it as a standalone application:

```yaml
# Flux Operator Helm values for standalone Web UI
web:
  serverOnly: true
installCRDs: false  # CRDs already installed by the main operator
```

This is useful for:
- Running the Web UI in a management cluster that monitors remote clusters
- Isolating the Web UI from the operator for security
- Deploying on non-Flux-Operator-managed clusters (set `installCRDs: true` in that case)
