# Notifications Reference

Flux notification-controller handles both outgoing notifications (Provider + Alert) and
incoming webhooks (Receiver). All resources are in the same namespace as the notification
target or source.

**Contents:** [Provider](#provider) | [Alert](#alert) | [Receiver](#receiver) | [Common Patterns](#common-patterns)

## Provider

`apiVersion: notification.toolkit.fluxcd.io/v1beta3`

Defines an external notification service that Alert resources route events to.

### Canonical YAML — Microsoft Teams

```yaml
apiVersion: notification.toolkit.fluxcd.io/v1beta3
kind: Provider
metadata:
  name: msteams
  namespace: flux-system
spec:
  type: msteams
  secretRef:
    name: msteams-webhook
---
apiVersion: v1
kind: Secret
metadata:
  name: msteams-webhook
  namespace: flux-system
stringData:
  address: https://prod-xxx.yyy.logic.azure.com:443/workflows/zzz/triggers/manual/paths/invoke?...
```

### Provider Types

**Messaging platforms:**

| Type | Secret Field | Address | Notes |
|------|-------------|---------|-------|
| `slack` | `token` (bot token) | `https://slack.com/api/chat.postMessage` | Channel set in spec, address in spec |
| `discord` | `address` (webhook URL) | — | |
| `msteams` | `address` (webhook URL) | — | Microsoft Teams |
| `googlechat` | `address` (webhook URL) | — | Google Chat |
| `telegram` | `token` | `https://api.telegram.org` | Channel is chat ID |
| `matrix` | `token` | Matrix homeserver URL | Channel is room ID |
| `rocket` | `address` (webhook URL) | — | Rocket.Chat (type is `rocket`, not `rocketchat`) |
| `lark` | `address` (webhook URL) | — | |
| `webex` | `token` | — | Channel is room ID |

**Alerting and monitoring platforms:**

| Type | Secret Field | Address | Notes |
|------|-------------|---------|-------|
| `alertmanager` | — | Alertmanager URL | |
| `grafana` | `token` | Grafana URL | |
| `sentry` | `address` (DSN) | — | |
| `datadog` | `token` (API key) | DataDog endpoint | |
| `opsgenie` | `token` (API key) | OpsGenie endpoint | |
| `pagerduty` | — (none required) | `https://events.pagerduty.com` | Integration routing key set in `spec.channel`, not a secret |

**Event streaming:**

| Type | Secret Field | Address | Notes |
|------|-------------|---------|-------|
| `googlepubsub` | `token` (JSON key) | — | Channel is topic ID |
| `azureeventhub` | `address` (SAS connection string, SAS auth only) | hub name in `spec.address` | `spec.channel` = Event Hubs namespace; `spec.address` = hub name. Managed identity uses `spec.channel`/`spec.address` directly |
| `nats` | `creds` / `nkey` / `username`+`password` (priority order) | NATS server URL | Channel is subject |

**Git commit status:**

| Type | Secret Field | Address | Notes |
|------|-------------|---------|-------|
| `github` | `token` (PAT or app token) | — | Sets commit status on PRs |
| `gitlab` | `token` (access token) | GitLab URL | Sets pipeline status |
| `gitea` | `token` | Gitea URL | |
| `bitbucket` | `token` | — | Bitbucket Cloud |
| `bitbucketserver` | `token` | Bitbucket Server URL | |
| `azuredevops` | `token` | Azure DevOps URL | |

**Generic webhooks:**

| Type | Secret Field | Notes |
|------|-------------|-------|
| `generic` | `address` (webhook URL) | JSON POST to any URL |
| `generic-hmac` | `token` (HMAC key) + `address` | JSON POST with HMAC signature header |

### Key Spec Fields

| Field | Type | Description |
|-------|------|-------------|
| `type` | string | Provider type (see tables above) |
| `address` | string | API endpoint URL (some providers use secret instead) |
| `channel` | string | Channel, room ID, or topic |
| `username` | string | Bot username for display |
| `secretRef.name` | string | Secret with credentials |
| `certSecretRef.name` | string | Secret with custom TLS CA certificate |
| `suspend` | bool | Pause the provider |

## Alert

`apiVersion: notification.toolkit.fluxcd.io/v1beta3`

Routes Flux events to a Provider based on source, severity, and content filters.

### Canonical YAML

```yaml
apiVersion: notification.toolkit.fluxcd.io/v1beta3
kind: Alert
metadata:
  name: slack-alert
  namespace: flux-system
spec:
  providerRef:
    name: slack
  eventSeverity: error
  eventSources:
    - kind: Kustomization
      name: "*"
    - kind: HelmRelease
      name: "*"
    - kind: GitRepository
      name: "*"
    - kind: OCIRepository
      name: "*"
  exclusionList:
    - "waiting.*socket"
```

### Key Spec Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `providerRef.name` | string | yes | Provider to send events to |
| `eventSources` | array | yes | What to watch — list of kind/name/namespace |
| `eventSeverity` | string | no | Filter: `info` (all events) or `error` (errors only) |
| `eventMetadata` | map | no | Additional key-value pairs added to events |
| `inclusionList` | array | no | Regex patterns — only matching events are sent |
| `exclusionList` | array | no | Regex patterns — matching events are dropped |
| `suspend` | bool | no | Pause alerting |

### Event Sources

```yaml
spec:
  eventSources:
    # All Kustomizations in the Alert's namespace
    - kind: Kustomization
      name: "*"

    # Specific HelmRelease
    - kind: HelmRelease
      name: nginx

    # Resources in another namespace (blocked when multitenant is enabled)
    - kind: Kustomization
      name: "*"
      namespace: apps

    # Resources matching labels
    - kind: HelmRelease
      name: "*"
      matchLabels:
        team: platform
```

Valid source kinds: `GitRepository`, `OCIRepository`, `HelmRepository`, `HelmChart`,
`Bucket`, `Kustomization`, `HelmRelease`, `ImageRepository`, `ImagePolicy`,
`ImageUpdateAutomation`, `ResourceSet`, `FluxInstance`.

### Event Filtering

- `eventSeverity: info` — sends all events (info + error)
- `eventSeverity: error` — sends only error events
- `inclusionList` — regex patterns; event must match at least one to be sent
- `exclusionList` — regex patterns; matching events are dropped
- Exclusion takes precedence over inclusion

### Event Metadata

Add custom metadata to all events from this Alert:

```yaml
spec:
  eventMetadata:
    environment: production
    cluster: prod-eu-1
    team: platform
```

## Receiver

`apiVersion: notification.toolkit.fluxcd.io/v1`

Webhook endpoint that receives events from external systems (GitHub, GitLab, etc.)
and triggers immediate reconciliation of Flux resources.

### Canonical YAML — GitHub Webhook

```yaml
apiVersion: notification.toolkit.fluxcd.io/v1
kind: Receiver
metadata:
  name: github-push
  namespace: flux-system
spec:
  type: github
  events:
    - ping
    - push
  secretRef:
    name: webhook-secret
  resources:
    - apiVersion: source.toolkit.fluxcd.io/v1
      kind: GitRepository
      name: my-app
---
apiVersion: v1
kind: Secret
metadata:
  name: webhook-secret
  namespace: flux-system
stringData:
  token: my-webhook-secret-token
```

### Key Spec Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `type` | string | yes | `generic`, `generic-hmac`, `generic-oidc`, `github`, `gitlab`, `bitbucket`, `harbor`, `dockerhub`, `quay`, `gcr`, `nexus`, `acr`, `cdevents` (no `gitea`/`azuredevops` Receiver type — Gitea uses the `github` type) |
| `events` | array | yes | Event types to accept (e.g., `push`, `ping`, `pull_request`) |
| `secretRef.name` | string | no | Secret with `token` for HMAC webhook verification (required except for `generic-oidc`). The Secret should carry the label `reconcile.fluxcd.io/watch: Enabled` so the controller reconciles the Receiver when it changes |
| `oidcProviders` | array | no | OIDC issuers that authenticate incoming requests when `type: generic-oidc` (secret-less) |
| `resources` | array | yes | Resources to trigger reconciliation on |
| `suspend` | bool | no | Pause the receiver |

### Webhook Path

After creation, the Receiver generates a webhook URL in its status:

```yaml
status:
  webhookPath: /hook/sha256-abc123...
```

The full webhook URL is:
`http://<notification-controller-address>/<webhookPath>`

Expose this endpoint via an Ingress or LoadBalancer and configure the external
service (GitHub, GitLab, etc.) to send webhooks to it.

### Resources to Trigger

```yaml
spec:
  resources:
    - apiVersion: source.toolkit.fluxcd.io/v1
      kind: GitRepository
      name: my-app
    - apiVersion: image.toolkit.fluxcd.io/v1
      kind: ImageRepository
      name: my-app
```

When a valid webhook is received, the Receiver annotates these resources with
`reconcile.fluxcd.io/requestedAt` to trigger immediate reconciliation.

### CEL Resource Filtering

Filter which resources are reconciled using CEL expressions. The `resourceFilter` field
matches the incoming request (`req`) against each resource (`res`):

```yaml
spec:
  type: generic
  events:
    - push
  secretRef:
    name: webhook-secret
  resources:
    - apiVersion: image.toolkit.fluxcd.io/v1
      kind: ImageRepository
      name: "*"
  resourceFilter: 'req.tag.contains(res.metadata.name)'
```

The `req` object exposes the webhook payload fields and `res` provides the resource metadata
(`res.metadata.name`, `res.metadata.labels`, `res.metadata.annotations`).

### Secret-less OIDC-Secured Receiver

`type: generic-oidc` authenticates incoming requests with a signed OIDC/JWT bearer token
instead of a shared HMAC secret — no webhook secret to provision or rotate. The controller
verifies the token's signature, expiry, and audience against the provider whose `issuerURL`
matches the token's `iss` claim, then evaluates optional CEL `validations` against the claims.
Ideal for callers that already have a workload identity token (CI runners, cloud services):

```yaml
apiVersion: notification.toolkit.fluxcd.io/v1
kind: Receiver
metadata:
  name: ci-trigger
  namespace: flux-system
spec:
  type: generic-oidc
  events:
    - push
  oidcProviders:
    - issuerURL: https://token.actions.githubusercontent.com
      audience: flux-notification-controller     # expected 'aud' claim (defaults to 'notification-controller')
      validations:
        # only accept tokens from a specific repo's workflows
        - "claims.repository == 'my-org/my-app'"
  resources:
    - apiVersion: source.toolkit.fluxcd.io/v1
      kind: OCIRepository
      name: my-app
```

`validations` are CEL booleans over `claims` (the token claims); the request is accepted only
if all pass. `variables` can define named CEL expressions exposed as `vars.<name>` for reuse
inside validations. No `secretRef` is needed for `generic-oidc`.

## Common Patterns

### Slack Notifications for All Failures

```yaml
# Provider + Alert for error-only Slack notifications using Slack Bot API
apiVersion: notification.toolkit.fluxcd.io/v1beta3
kind: Provider
metadata:
  name: slack-bot
  namespace: flux-system
spec:
  type: slack
  channel: flux-alerts
  address: https://slack.com/api/chat.postMessage
  secretRef:
    name: slack-bot-token
---
apiVersion: notification.toolkit.fluxcd.io/v1beta3
kind: Alert
metadata:
  name: all-failures
  namespace: flux-system
spec:
  providerRef:
    name: slack-bot
  eventSeverity: error
  eventSources:
    - kind: Kustomization
      name: "*"
    - kind: HelmRelease
      name: "*"
```

### GitHub Commit Status

```yaml
# Show deploy status on GitHub PRs/commits
apiVersion: notification.toolkit.fluxcd.io/v1beta3
kind: Provider
metadata:
  name: github-status
  namespace: flux-system
spec:
  type: github
  address: https://github.com/org/repo
  secretRef:
    name: github-token
---
apiVersion: notification.toolkit.fluxcd.io/v1beta3
kind: Alert
metadata:
  name: github-status
  namespace: flux-system
spec:
  providerRef:
    name: github-status
  eventSources:
    - kind: Kustomization
      name: my-app
```

### GitHub Webhook for Immediate Reconciliation

```yaml
# Trigger Git sync immediately on push instead of waiting for interval
apiVersion: notification.toolkit.fluxcd.io/v1
kind: Receiver
metadata:
  name: github-push
  namespace: flux-system
spec:
  type: github
  events: [push, ping]
  secretRef:
    name: webhook-secret
  resources:
    - apiVersion: source.toolkit.fluxcd.io/v1
      kind: GitRepository
      name: my-app
```
