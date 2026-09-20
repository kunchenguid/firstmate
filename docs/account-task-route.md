# Restricted account-task routes

A restricted account-task route lets one Firstmate account submit a reviewed non-private task to a separately owned execution account through an authenticated SSH forced command.
It is intentionally separate from [remote second mates](remote-secondmates.md), does not inherit a primary home, and exposes no generic command, path, callback, session, repair, merge, or deletion authority.
The implementation is `bin/fm-account-task.py`, whose header is the single owner of the binding, wire, ledger, and result formats.

The repository ships the receiver, sender, destination-side admission checks, replay ledger, bounded result protocol, and deterministic fixtures.
It does not create accounts, homes, SSH keys, credentials, project clones, runtime services, or route bindings.
It does not claim that any live cross-account installation has passed qualification.

## Supported v1 profile

Version 1 supports Pi workers on one already-running dedicated tmux server and one non-shared named session.
The destination binding fixes the account user and UID, account home, Firstmate code root, operational home, workspace root, repository selectors, worker kind, model, effort, runtime identity, executable paths, source and configuration guards, absence checks, denial canaries, qualification receipt digest, route epoch, and expiry.
Each selected repository must also have one owner-only guarded `treehouse.toml` whose sole bytes set `root` to the binding's exact workspace root; an account-level Treehouse configuration is forbidden so it cannot override the route-owned root or add hooks.
A scout uses the ordinary scout delivery contract.
A ship always uses `no-mistakes` with autonomous merge disabled.

The execution account owns the operational home, project clones, task copies, records, inboxes, runtime socket, and session.
The sender can submit, observe status, request a bounded result, steer the exact task, request a preserving checkpoint, stop the exact task, or disable new tasks and steering.
It cannot provision or repair the route, relaunch work, read an arbitrary file, run a shell command, select a backend, stop a server, merge, clean up, delete, or discard work.
A status response acknowledges a committed launch binding but is not a liveness claim.
A complete result is the first valid task-bound `report.md` and `result.json` pair, sealed in the receiver ledger so a later file rewrite cannot replace it.

## Isolation boundary

The receiver must run as the destination account through a dedicated SSH key whose forced command invokes `python3 -I` and the fixed binding path.
Every request rechecks the effective account name and UID, owner-only binding and ledger, disjoint account-local roots, pinned source and mutable executables, exact repository and Treehouse root configuration, absent account-global Treehouse configuration and personal material, existing unreadable denial canaries, the empty worker environment allowlist, and the prequalified tmux socket, server PID, session, and global environment.
The qualified tmux global environment must set `HOME` to the binding's exact account home and must have no active `TREEHOUSE_ROOT` or `XDG_CONFIG_HOME` assignment, in addition to matching its bound digest.
A selected task worktree must resolve strictly beneath the qualified workspace root; the root itself and paths outside it are refused before task metadata is published or a worker launches.
The repository-local Treehouse contract directs acquisition into that root before this independent post-acquisition check; the check remains the final refusal boundary rather than repairing a misconfigured pool.
Any binding, guard, account, canary, runtime, or qualification drift latches the epoch disabled and refuses the current request.
Restoring the old bytes does not re-enable that epoch.

The route never uses secondmate provisioning or inherited-material propagation.
The destination operational home must not contain `.env`, secondmate identity records, captain memory, shared captain memory, secondmate routing, or learnings.
The binding's additional absence list is where an attended qualification pins Signal, Relay, private-home, extension, package, auth, and other installation-specific exclusions that cannot be inferred portably.
The denial list must name existing non-secret canaries that the destination account cannot read, so a missing path cannot pass as a permission denial.

The worker launch uses an empty `config/launch-env-allowlist` and a receiver-constructed environment.
That environment filtering is not an operating-system sandbox.
Workers within this dedicated destination account remain mutually trusted, and the attended receipt must cover account-local imports, shell/history behavior, open descriptors, package custody, auth sources, operating-system permissions, and every shared service the selected delivery path could reach.

## Attended installation

Installation is a security-sensitive account-owner operation and is never performed by the route itself.
A qualifying operator performs these steps without copying a personal Firstmate home or credentials:

1. Create or select a destination login and fresh destination-owned code, operational-home, workspace, and project roots beneath that account's home.
2. Populate only the destination-local Firstmate code and approved project clones, create private `data`, `state`, `config`, and `projects` directories, and create an empty `config/launch-env-allowlist`.
3. In every selected repository, create an owner-only regular `treehouse.toml` containing exactly `root = "<absolute-workspace-root>"` plus one newline, with no other key, comment, or whitespace; require the account-level `$HOME/.config/treehouse/config.toml` path to remain absent.
4. Start a dedicated destination-owned tmux server whose global environment sets `HOME` to the exact bound account home, leaves `TREEHOUSE_ROOT` and `XDG_CONFIG_HOME` unset, and hosts a non-`default`, non-`firstmate`, non-`fm-remote` session without using a personal socket or shared service-repair path.
5. Construct the owner-only destination binding with the exact fields documented in `bin/fm-account-task.py`.
6. Resolve every required mutable executable to one absolute path, pin every required runtime surface and executable with `fm-account-task.py digest`, and bind each exact project `.git/config` and repository-local `treehouse.toml`.
7. Record non-secret absence paths and existing denial canaries, then bind the external attended qualification artifact by its SHA-256 receipt digest and a bounded expiry.
8. Install a dedicated public key with a forced command equivalent to `command="/absolute/python3 -I /absolute/firstmate/bin/fm-account-task.py receive /absolute/binding.json",restrict,no-user-rc` and retain explicit no-PTY, no-forwarding, and no-agent-forwarding restrictions where the installed OpenSSH version requires them separately.
9. Create an owner-only sender record in the controlling account with the fixed route, epoch, SSH alias, and absolute SSH executable.
10. Configure that alias for the dedicated key, strict host-key verification, and no general account login through the restricted credential.

The script never writes these installation files and never repairs a failed step.
Use the executable's header rather than this page as the exact JSON field reference.

## Requests, replay, and crashes

One request is one strict UTF-8 JSON object no larger than 65,536 bytes, with EOF delivered promptly.
Text is bounded to 16,384 UTF-8 bytes.
Unknown and duplicate fields, control characters, stale expiries, reused task names, arbitrary repository paths, and unsupported verbs are refused.

The receiver fsyncs an operation identity and request digest before a side effect.
The same operation identity with the same bytes returns the recorded outcome, while the same identity with different bytes refuses.
A crash while an operation is pending disables the route and returns unknown on replay instead of executing again.
A new exact-task status, result, checkpoint, or stop operation may adopt a launching task only when the receiver can revalidate its complete published launch binding, generation-matched receipt, and final In-flight backlog transition; missing or mismatched evidence remains unknown, and adoption neither replays submit nor claims worker liveness.
A task name is never reused within a route epoch.
The bounded ledger refuses new operations rather than evicting replay evidence, while the idempotent disable latch remains available without further journal growth.

The sender performs no automatic retry.
An uncertain transport result is reconciled by sending the identical request bytes with the identical operation identity.
Responses are accepted only when the route, epoch, operation, task, submit digest, generation, result digest, report bytes, and verb-specific response shape all match.

## Result and lifecycle behavior

The worker writes its bounded report and an exact task receipt in the fixed task data directory.
The receiver never executes result content and never accepts a path supplied by the sender.
A missing, malformed, mismatched, oversized, or rewritten unsealed result remains incomplete.
Once sealed, later result observations return the original committed bytes.

Steer, checkpoint, and stop first revalidate the task's recorded project, isolated copy, runtime session, window, spawn generation, and ownership roots.
Checkpoint sends a fixed preservation instruction.
Stop delegates only to `fm-control.sh <exact-task> exit`, whose existing control transaction verifies the endpoint and never stops the tmux server.
No route lifecycle verb can address a sibling task, shared daemon, personal session, or another account's process.

## Qualification and rollback

Portable tests prove protocol shape, identity mismatch refusal, no ambient personal environment, replay conflicts, crash ambiguity, result sealing, exact-task control, drift disablement, and bounded transport behavior against invented fixtures.
They do not replace an installed cross-account receipt.

Before enabling a route, an attended invented-data qualification must prove all of the following from the actual destination receiver and worker:

- the expected account name and UID, account home, operational home, project, task copy, records, socket, server, session, and tool process all belong to the destination account;
- personal and private denial canaries remain unreadable, every declared absent Signal, Relay, private-home, extension, package, auth, and session path remains absent, and no parent descriptor or forwarded agent enters the launch;
- one disconnect before and after acceptance produces one task generation and one sealed result;
- a sibling destination task, a control endpoint in another account, personal sessions, Signal owners, and shared daemons remain unchanged during steer, checkpoint, stop, drift, and rollback cases;
- source, executable, environment, runtime, account, canary, and result drift refuse safely;
- the selected provider and repository credentials were established under the destination account and were not copied from the controlling account;
- the selected ship path does not grant control over a daemon shared with another account.

Rollback sends the replay-safe `disable` operation, which prevents new tasks and steers while preserving exact-task observation, result retrieval, checkpoint, and stop when the installed identity and guards still match.
It never kills a service, removes authentication, deletes work, or falls back to the controlling account.
A drifted or disabled epoch requires attended reconciliation and a new installed binding before new work resumes.
