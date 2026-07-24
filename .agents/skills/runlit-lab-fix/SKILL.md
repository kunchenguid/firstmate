---
name: runlit-lab-fix
description: >-
  Repair the non-production RunLit Kubernetes lab when the captain invokes /runlit-lab-fix, asks to fix, restore, or reset the RunLit Kubernetes lab, or asks to return the k8s lab to a healthy baseline.
  The invocation authorizes a bounded read-only health assessment and the one documented recommendationservice rollback when its crash-loop and low-memory signature is present, but no other infrastructure mutation.
user-invocable: true
metadata:
  internal: true
---

# runlit-lab-fix

Restore the non-production RunLit Kubernetes lab to its documented healthy baseline.
This skill is the single owner of the RunLit lab repair procedure and its narrow mutation whitelist.

## Authority and routing

The captain's explicit invocation is approval for all read-only checks in this skill, a local evidence note, and the exact `recommendationservice` rollback described below when its full precondition is proven.
Do not ask again before that whitelisted rollback.
The invocation does not authorize a general reset, arbitrary Kubernetes mutation, or changes outside the RunLit lab.

Follow Firstmate's normal delegation boundary.
If a registered RunLit second mate fits the request, route it there through the normal marked request and reply path.
Within the RunLit home, dispatch one isolated worker to perform this checklist and return the evidence.
The RunLit second mate that receives the routed request owns dispatching the worker and must not route the request back to the primary home.
Keep the task operational and evidence-producing only, with no project-code edits or pull request.

## Read-only assessment

Perform the checks in this order and retain only the minimum output needed for diagnosis.

1. Read the RunLit lab's documented topology and identify the expected non-production kube context, namespaces, monitoring services, storefront route, backend route, and healthy resource baseline.
   Treat the documented context mapping as authority rather than guessing from a context name.
2. Run `kubectl config current-context` without printing kubeconfig contents.
   If the current context is not proven to be the documented RunLit lab context, stop before any cluster request and report the mismatch.
3. Verify read access with non-mutating `kubectl auth can-i` checks for the resources needed below.
   A failed access check is a blocker, not permission to change credentials or kubeconfig.
4. Inspect nodes with `kubectl get nodes -o wide` and summarize Ready state, scheduling state, and pressure conditions.
5. Inspect pods and deployments across the documented lab namespaces with `kubectl get pods -A -o wide` and `kubectl get deployments -A`.
   Record unhealthy, unready, pending, terminating, or restart-heavy workloads without deleting them.
6. Inspect recent warning events with `kubectl get events -A --field-selector type=Warning --sort-by=.lastTimestamp`.
   Separate current repeated warnings from stale events that predate the present workload revision.
7. Inspect `recommendationservice` with `kubectl get deployment recommendationservice -n online-boutique`, `kubectl rollout history deployment/recommendationservice -n online-boutique`, its ReplicaSets, and pods selected by `app=recommendationservice`.
   Capture the deployment revision, desired and available replicas, pod names and UIDs, restart counts, last termination reasons, and container image.
8. Read only the service's memory request and limit with a narrow JSONPath query such as `kubectl get deployment recommendationservice -n online-boutique -o jsonpath='{range .spec.template.spec.containers[*]}{.name}{" request="}{.resources.requests.memory}{" limit="}{.resources.limits.memory}{"\n"}{end}'`.
   Use pod status, termination reasons, warning events, and only a bounded tail of service logs when needed to distinguish an OOM or low-memory crash loop from an unrelated failure.
9. Inspect the documented Prometheus and Alertmanager workloads, readiness, targets, and active alerts through their read-only Kubernetes or HTTP APIs.
   Record alert names, states, and relevant labels without copying secret-bearing configuration or full payloads.
10. Check the documented storefront and backend deployment readiness, Service endpoints, and health URLs with read-only GET requests.
    Record status codes and health conclusions rather than response bodies that may contain customer data or credentials.

Do not proceed from a partial assessment when the evidence cannot distinguish the known artifact from another failure.

## Whitelisted remediation

The only infrastructure-changing command approved by this invocation is:

```sh
kubectl rollout undo deployment/recommendationservice -n online-boutique
```

Run it only when all of these facts are true:

- The active context is proven to be the documented non-production RunLit lab context.
- The current `recommendationservice` revision has a crash-loop or unavailable pod.
- Pod termination state, repeated warning events, or bounded logs identify an OOM or low-memory failure.
- The current deployment memory request or limit matches the known low-memory artifact rather than the documented healthy baseline.
- Rollout history contains the immediately previous healthy revision with the documented memory request and limit.

Capture the current revision and crash-loop pod UIDs before the command.
Run the undo at most once for one observed broken revision.
If another operator has already changed the revision, reassess from the beginning and do not undo blindly.
Do not use this rollback for an image, configuration, dependency, scheduling, storage, network, or unknown failure.

## Verification

After the rollback, complete every verification step before calling the lab healthy.

1. Run `kubectl rollout status deployment/recommendationservice -n online-boutique --timeout=60s` and verify desired, updated, available, and ready replicas converge.
   If it times out while the rollout is still progressing, report progress and repeat the bounded check rather than starting one long blocking wait.
2. Re-read the deployment revision and memory JSONPath and verify both the request and limit equal the documented healthy baseline or the captured previous healthy revision.
3. Verify the pre-rollback crash-loop pod UIDs are gone, the replacement pod is Ready, and the new pod is not accumulating restarts.
4. Recheck warning events and confirm the low-memory or OOM warning has stopped recurring on the new revision.
5. Recheck Prometheus and Alertmanager and confirm the related workload or availability alerts recover.
6. Recheck the storefront and backend readiness, endpoints, and documented health URLs.
7. Observe the repaired state for a bounded period long enough to catch an immediate repeat crash and alert reevaluation.

Do not delete the old pod to manufacture a passing result.
The Deployment controller must replace it as part of the rollback.
If the rollout, memory baseline, pod replacement, health checks, or relevant alerts do not recover, report that the lab is not yet healthy.

## Hard boundaries

- Do not touch production.
- Do not touch Coolify.
- Do not read, print, rotate, or change database secrets.
- Do not touch the private Postgres rollout.
- Do not stop, restart, reconfigure, or profile the Mac mini worker runtime.
- Do not touch Proxmox, the NAS, DNS, network configuration, provider accounts, or project code.
- Do not delete pods as the primary fix for a Deployment-managed fault.
- Do not scale, patch, apply, restart, or roll back any other Kubernetes resource.
- Do not suppress, inhibit, or silence alerts unless the captain separately asks for that action.
- Never print kubeconfig contents, Kubernetes Secret objects, credential environment variables, tokens, passwords, or connection strings.

Any remediation outside the one whitelisted rollback requires a new captain decision.
Stop before running it and provide the exact proposed command, target resources, expected effect, rollback plan, and blast radius.

## Evidence and captain handoff

When the active RunLit home is known and writable, write a concise local note to `$FM_HOME/data/runlit-lab-fix-<UTC timestamp>.md`.
If the request arrived through the primary home, the RunLit second mate or its worker writes the note in the RunLit home rather than the primary home.
Do not guess a home path or write the note into project code.

The note records:

- UTC start and finish times.
- The context name and topology sources used to prove it is the lab.
- Precheck and postcheck summaries for nodes, workloads, warning events, monitoring, storefront, and backend.
- The `recommendationservice` revisions, pod UIDs, restart evidence, and memory request and limit before and after.
- Whether the whitelisted command ran and its result.
- Relevant alert names and recovery state.
- Any unresolved symptom or required captain decision.

Keep raw secrets, kubeconfig content, Secret objects, credentials, full logs, and sensitive response bodies out of the note.

Report the outcome concisely using `AGENTS.md` section 9's captain-facing translation contract.
State whether the lab was already healthy, was restored by the approved rollback, or remains unhealthy.
Name the verified storefront, backend, recommendation service, and alert state, then link the local evidence note when one was written.
If more mutation is needed, end with the exact decision-ready proposal and do not imply that the original invocation approved it.
