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

1. Resolve one unambiguous RunLit project checkout first, and read every source below from that same checkout.
   The checkout is the RunLit clone under the active home's `projects/` directory that the home's `data/projects.md` registry names, or the isolated task worktree the worker already runs in when that worktree is a RunLit checkout; when both resolve, they must be the same repository.
   Confirm the resolved path is the expected RunLit repository and that its sources are current.
   A dispatched worker runs on a task branch in an isolated worktree, so require only that the worktree's base is the project's default branch; never require the branch it is on to be the default branch itself.
   Prove currency with a non-mutating `git ls-remote` read of the remote default branch and compare what it reports against what the checkout contains.
   An already-present remote-tracking ref is only as fresh as the last fetch, which this skill never performs, so agreeing with it proves nothing on its own; treat that comparison as corroboration after `git ls-remote` has answered, never as the proof itself.
   Never run `git fetch`, or any other state-changing git command, under `projects/` or in any project worktree; the read-only project boundary in `AGENTS.md` section 1 outranks this check.
   If no checkout resolves, more than one candidate resolves, the checkout is not the expected RunLit repository, `git ls-remote` cannot reach the remote, currency cannot be proven, or any of the four sources below is missing, treat it as a blocker: stop before any cluster access or mutation, never use these sources as mutation guidance, and escalate to the captain.
   Read the RunLit lab's documented topology from `scripts/k3s/CLUSTER-STATE.md` and `scripts/k3s/README.md` in that checkout, and identify the expected non-production kube context, namespaces, monitoring services, storefront route, backend route, and healthy resource baseline.
   Read the documented `recommendationservice` healthy memory request and limit, its expected container image, and its documented restore path from `docs/dogfood/oom-crashloop-validation.md` and `scripts/k3s/demo-chaos.sh` in that same checkout.
   These four files are the authoritative topology and baseline sources for this skill.
   Treat the documented context mapping as authority rather than guessing from a context name.
   `scripts/k3s/CLUSTER-STATE.md` maps the lab cluster to the local kubeconfig `default` context, and the documented lab namespaces are `online-boutique` and `monitoring`.
   If any of those sources is absent, stale, or disagrees with the observed cluster identity, stop before any cluster access or mutation and escalate to the captain.
2. Prove the `default` context is the lab cluster immediately before the first Kubernetes API request, using the API server it points at rather than its name, because `default` is a generic name that any kubeconfig can define.
   Run `kubectl config view --minify --context=default -o jsonpath="{.clusters[0].cluster.server}"` and compare the exact result against the lab API server documented in `scripts/k3s/CLUSTER-STATE.md`.
   That read returns one server URL and no credentials, so it satisfies the boundary against printing kubeconfig contents.
   Also run `kubectl config current-context` to record which context was ambient at the start, and treat that name as evidence for the note rather than as proof of identity.
   Every kubectl command below pins `--context=default` so ambient current-context drift, whether from a later context switch or from another agent, cannot redirect a read or the rollback at another cluster.
   The pin selects a context by name inside whichever kubeconfig is active, so it is no defense against a changed `KUBECONFIG` that defines its own `default` context; only this API server comparison proves cluster identity.
   Because of that, repeat this exact comparison immediately before the rollback, and re-run it before resuming reads whenever the assessment is interrupted, resumed later, or shares the environment with another agent.
   If the `default` context is missing, the server URL is empty, or it differs from the documented lab API server by any character, stop before any cluster request and report the mismatch.
3. Verify read access with non-mutating `kubectl --context=default auth can-i` checks for the resources needed below.
   A failed access check is a blocker, not permission to change credentials or kubeconfig.
4. Inspect nodes with `kubectl --context=default get nodes -o wide` and summarize Ready state, scheduling state, and pressure conditions.
5. Inspect pods and deployments in the documented lab namespaces only, with `kubectl --context=default get pods -n online-boutique -o wide` and `kubectl --context=default get deployments -n online-boutique`, then the same two reads with `-n monitoring`.
   Record unhealthy, unready, pending, terminating, or restart-heavy workloads without deleting them.
6. Inspect recent warning events in the same two namespaces with `kubectl --context=default get events -n online-boutique --field-selector type=Warning --sort-by=.lastTimestamp`, then the same read with `-n monitoring`.
   Separate current repeated warnings from stale events that predate the present workload revision.
7. Inspect `recommendationservice` with `kubectl --context=default get deployment recommendationservice -n online-boutique`, `kubectl --context=default rollout history deployment/recommendationservice -n online-boutique`, and pods selected by `app=recommendationservice`.
   Capture the deployment revision, desired and available replicas, pod names and UIDs, restart counts, last termination reasons, and container image.
   Rollout history prints only revision numbers and change causes, so read each revision's own settings from its ReplicaSet before choosing a rollback target, with one narrow non-secret query that outputs nothing else:
   `kubectl --context=default get replicasets -n online-boutique -l app=recommendationservice -o jsonpath='{range .items[*]}{.metadata.name}{" revision="}{.metadata.annotations.deployment\.kubernetes\.io/revision}{" image="}{.spec.template.spec.containers[?(@.name=="server")].image}{" request="}{.spec.template.spec.containers[?(@.name=="server")].resources.requests.memory}{" limit="}{.spec.template.spec.containers[?(@.name=="server")].resources.limits.memory}{"\n"}{end}'`
   Use the container name the documented baseline records; the documented deployment names it `server`.
   That row gives the ReplicaSet name, its deployment revision annotation, the server image, and the memory request and limit, which is everything the rollback precondition needs.
   Never widen it into a full revision or ReplicaSet template dump, including `rollout history --revision=<n>`, because those echo container environment variables this skill must not print.
8. Read only the service's memory request and limit with a narrow JSONPath query such as `kubectl --context=default get deployment recommendationservice -n online-boutique -o jsonpath='{range .spec.template.spec.containers[*]}{.name}{" request="}{.resources.requests.memory}{" limit="}{.resources.limits.memory}{"\n"}{end}'`.
   Use pod status, termination reasons, warning events, and only a bounded tail of service logs when needed to distinguish an OOM or low-memory crash loop from an unrelated failure.
9. Inspect the documented Prometheus and Alertmanager workload readiness through the Kubernetes API, pinning `--context=default` and `-n monitoring` on every kubectl read.
   Read their targets and active alerts only over the external read-only URLs that `scripts/k3s/CLUSTER-STATE.md` documents for those two services, with plain GET requests.
   Those documented URLs are the single approved path to the monitoring HTTP APIs, and the hard boundaries below forbid tunnelling into the cluster to reach them by any other route.
   Judge the two services separately: whenever `scripts/k3s/CLUSTER-STATE.md` documents no URL for one of them, or the URL it documents cannot be reached, record that one service's target and alert state as unavailable and name the missing URL or access path, rather than improvising a path or letting the other service stand in for it.
   Unavailable is a third outcome, not a health verdict: never report an unavailable check as healthy, and never report it as a failed check either.
   Record alert names, states, and relevant labels without copying secret-bearing configuration or full payloads.
10. Check the documented storefront and backend deployment readiness and Service endpoints through the Kubernetes API, pinning `--context=default` and `-n online-boutique` on every kubectl read, then request the health URLs `scripts/k3s/CLUSTER-STATE.md` documents for them with read-only GETs under the same single-approved-path rule as step 9.
    Record status codes and health conclusions rather than response bodies that may contain customer data or credentials.

Do not proceed from a partial assessment when the evidence cannot distinguish the known artifact from another failure.

## Whitelisted remediation

The only infrastructure-changing command approved by this invocation is:

```sh
kubectl --context=default rollout undo deployment/recommendationservice -n online-boutique --to-revision=<verified revision>
```

`<verified revision>` is the integer revision already read from rollout history and proven by step 7's ReplicaSet query to carry the documented healthy memory request and limit and the expected server image.
Never run an unqualified undo, because an undo without `--to-revision` targets whatever the previous revision happens to be at execution time rather than the revision this assessment proved healthy.

Run it only when all of these facts are true:

- The `default` context's API server exactly matches the lab API server documented in `scripts/k3s/CLUSTER-STATE.md`.
- The current `recommendationservice` revision has a crash-loop or unavailable pod.
- Pod termination state, repeated warning events, or bounded logs identify an OOM or low-memory failure.
- The current deployment memory request or limit matches the known low-memory artifact rather than the documented healthy baseline.
- An earlier revision's own ReplicaSet row, read with step 7's narrow query rather than inferred from a revision number, shows a memory request and limit equal to the documented baseline and a server image equal to the expected image, and that revision's integer number is recorded.

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
A step whose documented access path does not exist or cannot be reached is unavailable, which is neither passed nor failed; carry that distinction from the assessment into the verdict below instead of forcing it into either.

1. Run `kubectl --context=default rollout status deployment/recommendationservice -n online-boutique --timeout=60s` and verify desired, updated, available, and ready replicas converge.
   If it times out while the rollout is still progressing, report progress and repeat the bounded check rather than starting one long blocking wait.
2. Re-read the deployment revision and memory JSONPath and verify both the request and limit equal the documented healthy baseline or the captured previous healthy revision.
3. Verify the pre-rollback crash-loop pod UIDs are gone, the replacement pod is Ready, and the new pod is not accumulating restarts.
4. Recheck warning events and confirm the low-memory or OOM warning has stopped recurring on the new revision.
5. Recheck Prometheus and Alertmanager over the external URLs `scripts/k3s/CLUSTER-STATE.md` documents and confirm the related workload or availability alerts recover.
   Judge the two services separately as step 9 does, and when one service's documented URL is missing or unreachable, record its alert recovery as unavailable and do not call monitoring or alerting healthy on that evidence.
6. Recheck the storefront and backend readiness, endpoints, and documented health URLs, recording any missing or unreachable documented URL as unavailable rather than as a passed or failed check.
7. Observe the repaired state for a bounded period long enough to catch an immediate repeat crash and alert reevaluation.

Do not delete the old pod to manufacture a passing result.
The Deployment controller must replace it as part of the rollback.
If the rollout, memory baseline, pod replacement, health checks, or relevant alerts do not recover, report that the lab is not yet healthy.
When every check that could run passed but a monitoring or health check was unavailable, report only the narrower conclusion the evidence supports: the application-level repair is verified, monitoring or alerting verification was unavailable, and the missing URL or access path is named.
Never widen that into a claim that the lab, its monitoring, or its alerting is healthy, and never downgrade it into a claim that a check failed.

## Hard boundaries

- Do not touch production.
- Do not touch Coolify.
- Do not read, print, rotate, or change database secrets.
- Do not touch the private Postgres rollout.
- Do not stop, restart, reconfigure, or profile the Mac mini worker runtime.
- Do not touch Proxmox, the NAS, DNS, network configuration, provider accounts, or project code.
- Do not send any cluster request, read or mutation, without an explicit `--context=default`, and never let the ambient current context decide which cluster a command reaches; the local `kubectl config current-context` read is the only command exempt from the flag.
- Do not accept a context name as proof of cluster identity, and do not treat the `--context=default` pin as protection against a changed `KUBECONFIG`; only the documented API server URL comparison proves it.
- Do not dump a full revision or ReplicaSet template, or any container environment, when choosing the rollback revision; read only the narrow fields step 7 names.
- Do not run a cluster-wide `-A` read; scope every namespaced read to the documented `online-boutique` or `monitoring` namespace.
- Do not open a `kubectl port-forward` or `kubectl proxy` tunnel, exec or attach into a pod, or copy files out of one; reach an in-cluster HTTP API only over the read-only URLs `scripts/k3s/CLUSTER-STATE.md` documents, and report that service's check as unavailable when no documented URL is reachable.
- Do not call monitoring or alerting healthy on an unavailable check, and do not report an unavailable check as a failure; name the missing URL or access path instead.
- Do not run `git fetch` or any other state-changing command in the RunLit checkout; prove source currency with a non-mutating `git ls-remote` read, never with a remote-tracking ref alone.
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
- Relevant alert names and recovery state, each recorded as recovered, not recovered, or unavailable with its missing URL or access path named.
- The source currency proof, recorded as the `git ls-remote` comparison result rather than as a bare assertion that the checkout was current.
- Any unresolved symptom or required captain decision.

Keep raw secrets, kubeconfig content, Secret objects, credentials, full logs, and sensitive response bodies out of the note.

Report the outcome concisely using `AGENTS.md` section 9's captain-facing translation contract.
State whether the lab was already healthy, was restored by the approved rollback, or remains unhealthy.
Name the verified storefront, backend, recommendation service, and alert state, then link the local evidence note when one was written.
When a monitoring or health check was unavailable, say so in that same summary, name the missing URL or access path, and scope the claim to the application-level repair instead of to the lab as a whole.
If more mutation is needed, end with the exact decision-ready proposal and do not imply that the original invocation approved it.
