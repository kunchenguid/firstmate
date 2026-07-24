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

1. Read the RunLit lab's documented topology from `scripts/k3s/CLUSTER-STATE.md` and `scripts/k3s/README.md` in the RunLit project, and identify the expected non-production kube context, namespaces, monitoring services, storefront route, backend route, and healthy resource baseline.
   Read the documented `recommendationservice` healthy memory request and limit and its documented restore path from `docs/dogfood/oom-crashloop-validation.md` and `scripts/k3s/demo-chaos.sh` in the same project.
   These four files are the authoritative topology and baseline sources for this skill.
   Treat the documented context mapping as authority rather than guessing from a context name.
   `scripts/k3s/CLUSTER-STATE.md` maps the lab cluster to the local kubeconfig `default` context, and the documented lab namespaces are `online-boutique` and `monitoring`.
   If any of those sources is absent, stale, or disagrees with the observed cluster identity, stop before any cluster access or mutation and escalate to the captain.
2. Prove the `default` context is the lab cluster before any cluster request, using the API server it points at rather than its name, because `default` is a generic name that any kubeconfig can define.
   Run `kubectl config view --minify --context=default -o jsonpath="{.clusters[0].cluster.server}"` and compare the exact result against the lab API server documented in `scripts/k3s/CLUSTER-STATE.md`.
   That read returns one server URL and no credentials, so it satisfies the boundary against printing kubeconfig contents.
   Also run `kubectl config current-context` to record which context was ambient at the start, and treat that name as evidence for the note rather than as proof of identity.
   Every kubectl command below pins `--context=default` so a later context switch, another agent, a different shell environment, or a changed `KUBECONFIG` cannot redirect a read or the rollback at another cluster.
   If the `default` context is missing, the server URL is empty, or it differs from the documented lab API server by any character, stop before any cluster request and report the mismatch.
3. Verify read access with non-mutating `kubectl --context=default auth can-i` checks for the resources needed below.
   A failed access check is a blocker, not permission to change credentials or kubeconfig.
4. Inspect nodes with `kubectl --context=default get nodes -o wide` and summarize Ready state, scheduling state, and pressure conditions.
5. Inspect pods and deployments in the documented lab namespaces only, with `kubectl --context=default get pods -n online-boutique -o wide` and `kubectl --context=default get deployments -n online-boutique`, then the same two reads with `-n monitoring`.
   Record unhealthy, unready, pending, terminating, or restart-heavy workloads without deleting them.
6. Inspect recent warning events in the same two namespaces with `kubectl --context=default get events -n online-boutique --field-selector type=Warning --sort-by=.lastTimestamp`, then the same read with `-n monitoring`.
   Separate current repeated warnings from stale events that predate the present workload revision.
7. Inspect `recommendationservice` with `kubectl --context=default get deployment recommendationservice -n online-boutique`, `kubectl --context=default rollout history deployment/recommendationservice -n online-boutique`, its ReplicaSets, and pods selected by `app=recommendationservice`.
   Capture the deployment revision, desired and available replicas, pod names and UIDs, restart counts, last termination reasons, and container image.
8. Read only the service's memory request and limit with a narrow JSONPath query such as `kubectl --context=default get deployment recommendationservice -n online-boutique -o jsonpath='{range .spec.template.spec.containers[*]}{.name}{" request="}{.resources.requests.memory}{" limit="}{.resources.limits.memory}{"\n"}{end}'`.
   Use pod status, termination reasons, warning events, and only a bounded tail of service logs when needed to distinguish an OOM or low-memory crash loop from an unrelated failure.
9. Inspect the documented Prometheus and Alertmanager workloads, readiness, targets, and active alerts through their read-only Kubernetes or HTTP APIs, pinning `--context=default` and `-n monitoring` on every kubectl read.
   Record alert names, states, and relevant labels without copying secret-bearing configuration or full payloads.
10. Check the documented storefront and backend deployment readiness, Service endpoints, and health URLs with read-only GET requests, pinning `--context=default` and `-n online-boutique` on every kubectl read.
    Record status codes and health conclusions rather than response bodies that may contain customer data or credentials.

Do not proceed from a partial assessment when the evidence cannot distinguish the known artifact from another failure.

## Whitelisted remediation

The only infrastructure-changing command approved by this invocation is:

```sh
kubectl --context=default rollout undo deployment/recommendationservice -n online-boutique --to-revision=<verified revision>
```

`<verified revision>` is the integer revision already read from rollout history and proven to carry the documented healthy memory request and limit.
Never run an unqualified undo, because an undo without `--to-revision` targets whatever the previous revision happens to be at execution time rather than the revision this assessment proved healthy.

Run it only when all of these facts are true:

- The `default` context's API server exactly matches the lab API server documented in `scripts/k3s/CLUSTER-STATE.md`.
- The current `recommendationservice` revision has a crash-loop or unavailable pod.
- Pod termination state, repeated warning events, or bounded logs identify an OOM or low-memory failure.
- The current deployment memory request or limit matches the known low-memory artifact rather than the documented healthy baseline.
- Rollout history contains an earlier healthy revision whose memory request and limit equal the documented baseline, and that revision's integer number is recorded.

Capture the current revision and crash-loop pod UIDs before the command.
Immediately before running it, re-prove both facts that the command depends on.
Re-run `kubectl config view --minify --context=default -o jsonpath="{.clusters[0].cluster.server}"` and confirm it still equals the documented lab API server exactly, because a kubeconfig edit between assessment and mutation can repoint `default` at another cluster.
Re-read `kubectl --context=default rollout history deployment/recommendationservice -n online-boutique` and confirm the current revision is still the broken one and `<verified revision>` still names the inspected healthy revision.
If either recheck disagrees with the assessment, stop and reassess from the beginning rather than running the command.
Run the undo at most once for one observed broken revision.
If another operator has already changed the revision, reassess from the beginning and do not undo blindly.
Do not use this rollback for an image, configuration, dependency, scheduling, storage, network, or unknown failure.

## Verification

After the rollback, complete every verification step before calling the lab healthy.

1. Run `kubectl --context=default rollout status deployment/recommendationservice -n online-boutique --timeout=60s` and verify desired, updated, available, and ready replicas converge.
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
- Do not send any cluster request, read or mutation, without an explicit `--context=default`, and never let the ambient current context decide which cluster a command reaches; the local `kubectl config current-context` read is the only command exempt from the flag.
- Do not accept a context name as proof of cluster identity; only the documented API server URL comparison proves it.
- Do not run a cluster-wide `-A` read; scope every namespaced read to the documented `online-boutique` or `monitoring` namespace.
- Do not delete pods as the primary fix for a Deployment-managed fault.
- Do not scale, patch, apply, restart, or roll back any other Kubernetes resource.
- Do not suppress, inhibit, or silence alerts unless the captain separately asks for that action.
- Never print kubeconfig contents, Kubernetes Secret objects, credential environment variables, tokens, passwords, or connection strings.

Any remediation outside the one whitelisted rollback requires a new captain decision.
Stop before running it and provide the exact proposed command, target resources, expected effect, rollback plan, and blast radius.

## Evidence and captain handoff

When the active RunLit home is known and writable, resolve the effective home the way `docs/configuration.md` describes and write a concise local note to `data/runlit-lab-fix-<UTC timestamp>.md` under it.
If the request arrived through the primary home, the RunLit second mate or its worker writes the note in the RunLit home rather than the primary home.
Do not guess a home path or write the note into project code.

The note records:

- UTC start and finish times.
- The context name, the API server URL comparison result, and the topology sources used to prove it is the lab, recorded as matched or mismatched rather than by pasting the URL.
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
