# Azure worker crewmate runtime and payload plane (design)

Status: DESIGN. Nothing in this document is implemented; docs/azure-workers.md
remains the authority for everything the worker lane already does. This
document owns the design for the missing pieces between "a worker executes a
digest-bound argv" (proven live 2026-08-17 on vm-fm7c799d-wkr-01) and "a real
pi crewmate does task work in the cloud".

## What is proven and what is missing

Proven live: request -> reconcile -> assignment, pinned supervisor bootstrap,
data-disk preparation (/mnt/account lun0, /mnt/task lun1), bounded execute
with digest-bound fm.worker-execution-result/v1, TTL, Herdr tracking endpoint
with queued-spawn convergence (PR 227).

Missing (verified empty on a live worker):

1. Runtime: pi and node do not exist on the worker. Workers boot the raw
   Canonical Ubuntu 24.04 base; bootstrap installs only the supervisor.
2. Repository materialization: /mnt/task holds nothing; worktree_binding is
   an identity digest, not content.
3. Task files: the entrypoint (CLOUD_WORKER_LAUNCH) references the brief at
   the LOCAL $FM_HOME/data/<id>/brief.md and the pi extension at the LOCAL
   state/<id>.pi-ext.ts; neither exists on the worker, and the launch string
   is never rewritten to worker paths.
4. Account custody: fm-spawn.sh records account_home as "the binding the
   worker lifecycle stages", but no staging exists; /mnt/account is empty.
5. Landing path: mode=direct-PR implies pushing from the worker, which is a
   credential-custody decision that was never made.
6. Release-after-teardown: bin/fm-worker-authority.py needs the task meta and
   worktree that bin/fm-teardown.sh deletes in the same pass that removes the
   endpoint, so an ordinarily torn-down cloud task can never produce its
   release receipts (observed live: cloud-smoke-20260817 rode its TTL out).

## Decisions

### D1. Runtime rides the golden image, not per-boot downloads

Extend `bin/fm-azure-cell-image.sh` to stage, next to the existing pinned
closures, a worker-runtime closure under /opt/fm-tools:

- node 22 (the nodesource tarball the bake already pins for cells), and
- the pi CLI closure: `npm install --prefix /opt/fm-tools/pi-agent
  @earendil-works/pi-coding-agent@<pinned>` performed AT BAKE TIME on the
  builder VM, archived with a recorded sha256 like every other staged tool.

Then parameterize the worker image in docs/azure-pilot/main.json
(`workerImageId`, defaulting to the current Canonical literal so the change
is inert until the parameter is supplied) and point it at the new gallery
version. Rationale: workers are egress-sealed by posture; per-boot registry
downloads are both a provenance hole and a boot-time failure mode, while the
image is a cache of a recorded provenance chain (the bake doc's own model).
The pi extension pack (multi-pass and friends) is NOT staged: those exist to
rotate a human's many local accounts; a worker runs one leased account. The
multi-pass OAuth-refresh patch is therefore also not needed on workers; the
bounded wall (max 6h) sits inside a fresh access token's life.

### D2. One payload archive per assignment, over the private staging lane

At execute time the lifecycle already uploads a canonical request blob
privately. Add one sibling payload archive, assembled by fm-spawn at dispatch
(and persisted for the convergence path exactly like the entrypoint):

- `repo.bundle`: a `git bundle` of the leased treehouse worktree's HEAD (the
  exact repository_generation the bindings already record). A bundle needs no
  credentials on either side and materializes with `git clone repo.bundle`.
- `brief.md`, `pi-ext.ts`: the two task files the entrypoint reads.
- `payload.json`: manifest with per-file sha256 and the archive's own digest
  recorded into the execute request, so the guest verifies before use.

The supervisor gains a staging step before argv execution: fetch the payload
over the private endpoint (the worker identity's container role already
scopes it to its own state container), verify digests, clone the bundle into
/mnt/task/repo, place task files under /mnt/task/.fm-task/.

### D3. The cloud entrypoint is built in worker coordinates

fm-spawn already special-cases the cloud lane (pi-only, dispatch bypassed).
Build CLOUD_WORKER_LAUNCH against a fixed worker layout instead of local
paths: brief at /mnt/task/.fm-task/brief.md, extension at
/mnt/task/.fm-task/pi-ext.ts, cwd /mnt/task/repo (the supervisor's
FM_WORKER_WORKTREE moves to the cloned repo), PI_CODING_AGENT_DIR=
/mnt/account/pi-agent, PATH extended with /opt/fm-tools/node/bin and
/opt/fm-tools/pi-agent/bin. The local lane's launch construction is untouched;
the worker layout is a constant contract, asserted by the guest before exec.

### D4. Account custody copies the crosscheck model-compartment pattern

The pi account material (auth.json plus the minimal agent settings) is
packaged at dispatch into its own private blob, encrypted to the same custody
rules the crosscheck lane already follows for reviewer credentials: never in
ARM parameters, never in controller output or logs, fetched by the guest over
the private endpoint, staged onto the encrypted account disk
(/mnt/account/pi-agent), deleted from staging after the assignment's terminal
state. The account_binding digest the bindings already carry is verified
against the staged material before the entrypoint runs.

### D5. Landing v1: commits ride the task disk; the local side pushes

No provider or GitHub credential enters the worker in v1. The crewmate
commits locally in /mnt/task/repo; after the bounded execute the supervisor
bundles `repo -> outcome.bundle` (new commits only) into the state container.
The tracking monitor, on result landing, fetches the outcome bundle into the
leased LOCAL worktree, where the ordinary landing flow (push, PR, Bugbot,
teardown's landed-work check) proceeds unchanged. This keeps the landing
authority and the release receipts exactly where docs/azure-workers.md
already puts them. Direct push from workers (with a scoped deploy token) is
explicitly deferred; it changes the custody story and should be its own
decision when the soak data says the round-trip is too slow.

### D6. Cloud teardown produces release receipts before destroying evidence

For placement=azure tasks, fm-teardown.sh runs authority-receipt (which needs
the live meta and worktree) BEFORE removing them, stores the
fm.worker-release/v2 bundle under state/, then calls release and a reconcile
so the slot deallocates inside its cooldown instead of riding the TTL.

## Sequencing

1. Bake: extend fm-azure-cell-image.sh with the worker-runtime closure; new
   gallery version. (No behavior change for anything until 3.)
2. Payload: bundle+brief+extension archive at dispatch, supervisor staging
   with digest verification, worker-coordinate entrypoint. Hermetic tests
   drive the REAL supervisor staging against fixture blobs.
3. Flip: workerImageId parameter supplied; one live crewmate smoke on a real
   task; the crosscheck lane reviews the whole stack (it gates its own
   producer now).
4. Landing: outcome bundle + monitor fetch + local push (D5), then D6.
5. Wide soak (8 then 16 lanes) only after 3 and 4 hold.

## Non-goals

- No pi extension pack, fast-mode, or account rotation on workers.
- No public egress from workers; every transfer stays on the private lane.
- No captain-on-cloud changes; that is its own phase with its own custody
  design (setup-token) and is tracked outside this document.
