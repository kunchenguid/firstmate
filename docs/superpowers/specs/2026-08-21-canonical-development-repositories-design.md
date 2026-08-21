# Canonical Development Repository Access and Agent Registration

**Date:** 2026-08-21
**Status:** Approved design
**Canonical host:** `coding-agents` (`192.168.88.10`)
**Canonical root:** `/home/yaro/work/repos`

## Purpose

Make every development repository on the new coding VM consistently discoverable and usable by Claude Code, Codex, Hermes, and OpenClaw without creating divergent repository copies. Reconcile agent-facing Markdown so each tool receives accurate project context, and organize the loose VoIPThug project material currently stored directly under `/home/yaro/work`.

## Verified current state

- `/home/yaro/work/repos` is an ext4-backed directory on `coding-agents` and contains 48 top-level directories, 42 of which are Git repositories.
- Claude Code 2.1.233 is installed behind `/home/yaro/.local/bin/claude`, which launches `/home/yaro/.local/lib/claude.real`.
- Codex CLI 0.147.0 is installed at `/usr/bin/codex`.
- A non-interactive SSH shell currently omits `/home/yaro/.local/bin` from `PATH`; this caused an initial false negative for Claude discovery.
- The repository fleet currently contains 26 `AGENTS.md` files and 22 `CLAUDE.md` files within the inspected depth. Missing coverage is uneven across projects.
- Twenty-six repositories currently have dirty working trees. These changes predate this work and must be preserved.
- The Hermes VM is `192.168.88.11`. Hermes runs as the `hermes` service account and has default, `dev`, `ops`, and `studio` profile project databases. Repository discovery is enabled, but its discovery roots are empty. The `studio` profile contains a stale manual project path for `/home/yaro/work/repos/voipthug-portal`.
- The OpenClaw VM is `192.168.88.14`. OpenClaw runs as `yaro`, uses `/home/yaro/.openclaw/workspace`, and currently has no project-root registry in `openclaw.json`.
- Neither the Hermes nor OpenClaw VM currently has `/home/yaro/work/repos` mounted.
- NFS server tooling is not currently active on `coding-agents`.
- A separate 48-directory repository copy exists on `ai-agents`; it is not the same filesystem as the canonical root and is outside this migration's authoritative data path.

## Goals

1. Keep one authoritative repository tree on `192.168.88.10`.
2. Give Hermes and OpenClaw persistent read-write access at the identical absolute path.
3. Register all 42 Git repositories through each tool's supported discovery or workspace mechanism.
4. Make Claude and Codex reliably recognize the canonical root on the coding VM.
5. Preserve verified project-specific instructions while repairing missing or stale agent documentation.
6. Consolidate loose VoIPThug project material beneath the canonical VoIPThug repository without moving unrelated runtimes, archives, or Git worktrees.
7. Provide explicit rollback and evidence-based verification.

## Non-goals

- Do not install Hermes or OpenClaw on `coding-agents`.
- Do not deploy, push, merge, rewrite Git history, discard dirty changes, or change product runtime copies.
- Do not copy or continuously synchronize the canonical repositories to the dedicated agent VMs.
- Do not guess project commands, architecture, deployment targets, or ownership from names alone.
- Do not move the Telegram VoIPThug bot, archived tarballs, or registered VoIPThug Git worktrees into the primary repository.

## Architecture

### Canonical filesystem

`coding-agents:/home/yaro/work/repos` remains the sole canonical source tree. Export that exact directory with NFSv4 only to:

- `192.168.88.11` — Hermes
- `192.168.88.14` — OpenClaw

Both clients mount the export at `/home/yaro/work/repos`. Keeping the absolute path identical prevents agent documentation, project records, and scripts from acquiring host-specific path variants.

The NFS export uses `rw`, `sync`, `root_squash`, and `no_subtree_check`, and is restricted to the two client addresses. Client mounts use NFSv4, `_netdev`, `nofail`, `x-systemd.automount`, and `noatime` so boot does not block when the coding VM is temporarily unavailable.

### Identity and permissions

Create a dedicated development-project group with the same numeric GID on the coding, Hermes, and OpenClaw VMs. Add:

- `yaro` on all three systems;
- the `hermes` service account on the Hermes VM.

Keep repository ownership with `yaro`. Apply a group ACL and default group ACL at the canonical root so current and newly created project files are writable by authorized agent accounts. Do not grant world-write access, disable root squashing, or place credentials inside the export.

Before selecting the GID, verify that it is unused on every VM. Before applying recursive ACLs, capture existing ownership, modes, ACLs, and representative Git executable-bit state. ACL changes must not alter Git-tracked mode bits.

## Tool integration

### Claude Code

- Keep the existing Claude installation.
- Make `/home/yaro/.local/bin` available in login and non-interactive management shells without replacing the account-rotation wrapper.
- Treat `/home/yaro/work/repos` as the development root.
- Use root and repository-local `CLAUDE.md`/`AGENTS.md` instructions; repository-local constraints remain authoritative.

### Codex

- Keep the existing Codex installation.
- Register or trust `/home/yaro/work/repos` using the installed Codex version's supported configuration, avoiding 42 redundant entries if root-level trust is inherited.
- Use the root `AGENTS.md` for fleet-wide safety and each repository's local `AGENTS.md` for project-specific guidance.

### Hermes

- Mount the canonical root before project registration.
- Use a supported Hermes CLI or API to configure the repository discovery root; do not hand-edit SQLite when a supported surface exists.
- Reconcile project discovery for the default, `dev`, `ops`, and `studio` profiles so each can resolve the full canonical inventory. Profile-specific project emphasis may remain in profile instructions, but filesystem discovery must not hide repositories.
- Remove or repair the stale `voipthug-portal` record only after confirming the supported reconciliation behavior and the canonical VoIPThug repository identity.
- Verify the `hermes` service account can read and write the mounted tree before refreshing discovery.

### OpenClaw

- Mount the canonical root at the same absolute path.
- Add `/home/yaro/.openclaw/workspace/projects` as a symlink to `/home/yaro/work/repos`.
- Update the workspace `AGENTS.md` and `TOOLS.md` with the canonical host, exact path, source-versus-runtime rule, repository safety rules, and project catalog location.
- Preserve OpenClaw identity, memory, model, gateway, and credential configuration.

## Documentation reconciliation

### Canonical-root documents

Rebuild and cross-check:

- `README.md` — human-readable project families and source-versus-runtime context;
- `AGENTS.md` — fleet-wide agent safety, discovery, Git, worktree, secrets, generated-output, and deployment rules;
- `CLAUDE.md` — Claude entry point that shares the verified common rules and retains Claude-specific guidance where required;
- `PROJECTS.md` — generated inventory of the 42 Git roots, descriptions, detected stacks, remotes, documentation coverage, and known runtime mapping.

The catalog is generated from evidence and then reviewed. It must distinguish Git repositories from non-repository directories and worktree containers.

### Per-repository documents

For each Git repository:

1. Capture existing `AGENTS.md`, `CLAUDE.md`, `README*`, manifests, Git remote, branch, and deployment references.
2. Preserve verified project-specific constraints and intentional tool-specific differences.
3. Repair stale absolute paths and contradictions only when the correct value is independently verified.
4. Create missing `AGENTS.md` and/or `CLAUDE.md` with minimal, evidence-backed content.
5. Prefer pointers to authoritative manifests and documentation over duplicating volatile commands.
6. Never infer production hosts, secrets, test commands, or deployment procedures solely from a project name or framework marker.

Generated files receive a consistency check for valid local links, valid paths, duplicate or conflicting rules, placeholders, and references to nonexistent repositories.

## VoIPThug organization

Consolidate project-owned loose material into:

```text
/home/yaro/work/repos/voipthug/
├── docs/
│   ├── briefs/
│   ├── audits/
│   └── worklogs/
├── project-assets/
│   ├── art-e1/
│   ├── brand-v2/
│   └── logo-production/
├── artifacts/
│   └── final-audit/
└── scripts/
    └── audit/
```

The following remain outside the primary repository:

- `/home/yaro/work/worktrees/voipthug-retail-content` — registered Git worktree;
- `/home/yaro/work/bots/telegram/voipthug-bot` — separate bot/runtime project;
- `/home/yaro/work/archive/voipthug-*` — historical archives.

Markdown briefs, reusable scripts, and worklogs may be tracked after review. The large logo/art production corpus and generated audit artifacts remain ignored unless the repository already has an approved Git LFS policy. Before moving any path, scan active processes, Firstmate records, scripts, and documents for absolute references. Update references transactionally. Use temporary compatibility links only when an active workflow still depends on an old path, and record their planned removal.

The primary VoIPThug checkout is currently 78 commits behind `origin/master` and has two pre-existing untracked asset directories. Organization must not update the branch, overwrite these directories, or combine unrelated changes with this migration.

## Execution order

1. Capture complete preflight inventory and backups.
2. Install and configure NFS server/client prerequisites.
3. Create the shared group and align its GID.
4. Configure the restricted export and persistent client automounts.
5. Apply and validate ACLs.
6. Verify cross-VM read/write behavior with disposable probes.
7. Configure Claude and Codex root recognition on `coding-agents`.
8. Configure Hermes discovery through supported interfaces and reconcile profile records.
9. Configure the OpenClaw workspace link and instructions.
10. Generate the canonical project catalog and reconcile root/per-repository Markdown.
11. Organize VoIPThug material after reference and activity checks.
12. Run the full verification matrix and produce a change/rollback report.

## Safety and rollback

Before mutation, capture:

- branch, HEAD, remote, worktree status, dirty paths, and documentation hashes for every repository;
- current modes and ACLs for the canonical root and representative files;
- `/etc/exports`, relevant firewall policy, client mount configuration, Claude/Codex configuration, Hermes project records, and OpenClaw configuration/workspace documents;
- active processes and absolute references involving paths scheduled for movement.

Backups must be timestamped, owner-readable only where credentials or private configuration could be present, and stored outside the exported repository tree.

Rollback restores only material changed by this operation:

- disable and remove the two client mounts and the restricted export;
- restore group/ACL/configuration state from the captured baseline;
- restore Hermes/OpenClaw project settings through supported interfaces where available;
- move VoIPThug items back using the recorded move manifest;
- restore only documentation files changed by this operation.

Rollback must never reset, stash, clean, checkout, or otherwise discard pre-existing repository changes.

## Verification matrix

Completion requires fresh evidence for all of the following:

1. All three VMs resolve `/home/yaro/work/repos` to the intended canonical export or local filesystem.
2. Representative file hashes and all 42 repository HEADs match from coding, Hermes, and OpenClaw.
3. Disposable write probes succeed as `yaro`, `hermes`, and the OpenClaw service account and are then removed.
4. No unauthorized host can mount the export in the tested network scope.
5. Claude and Codex launch successfully from the canonical root and resolve the root plus repository-local instructions.
6. Hermes's supported API/CLI lists the 42 repositories for every configured profile without stale nonexistent paths.
7. OpenClaw resolves `workspace/projects`, reads `PROJECTS.md`, and can inspect a representative repository.
8. Every Git repository has an effective `AGENTS.md` and `CLAUDE.md` instruction path.
9. Documentation contains no unresolved placeholders, invalid local links, stale `/work/repos` paths, or unverified commands introduced by this work.
10. The before/after Git-status comparison shows only explicitly intended documentation and VoIPThug organization changes.
11. The VoIPThug move manifest accounts for every original loose item, and excluded worktrees, bot files, and archives remain in place.
12. Automounts recover after service restart and do not block client boot when the NFS server is unavailable.

## Acceptance criteria

The design is satisfied when the canonical tree remains authoritative on `192.168.88.10`; Claude, Codex, Hermes, and OpenClaw can discover and access all 42 repositories through supported mechanisms; agent documentation is complete and evidence-backed; VoIPThug material is organized without breaking active work; and the verification and rollback records are complete.
