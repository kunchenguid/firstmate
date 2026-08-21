# Canonical Development Repositories Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the 42 Git repositories under `/home/yaro/work/repos` on `192.168.88.10` the single development source visible to Claude, Codex, every Hermes profile, and OpenClaw, while reconciling agent documentation and organizing loose VoIPThug material.

**Architecture:** `coding-agents` exports the canonical root over restricted NFSv4 to the dedicated Hermes and OpenClaw VMs, both mounted at the identical absolute path. Native tool registration points every agent at that root; evidence-backed root/per-repository Markdown supplies instructions; a recorded move manifest consolidates VoIPThug-owned material without touching worktrees, runtimes, archives, or pre-existing dirty work.

**Tech Stack:** Ubuntu 26.04, NFSv4.2, systemd automounts, POSIX ACLs, Git, Claude Code 2.1.233, Codex CLI 0.147.0, Hermes Agent 0.20.4, OpenClaw 2026.7.1-2, Bash, Python 3.11, SQLite read-only verification.

**Approved design:** `docs/superpowers/specs/2026-08-21-canonical-development-repositories-design.md`

## Global Constraints

- Canonical host: `coding-agents` (`192.168.88.10`).
- Canonical root: `/home/yaro/work/repos`.
- NFS clients: Hermes `192.168.88.11`; OpenClaw `192.168.88.14`.
- Use fixed group `devprojects` with GID `2200`, verified unused on all three VMs during planning and rechecked immediately before creation.
- Preserve all pre-existing dirty files, branches, commits, remotes, worktrees, executable bits, ACLs, and ownership unless an exact change is listed below.
- Do not install Hermes or OpenClaw on `coding-agents`.
- Do not push, merge, deploy, reset, stash, clean, checkout, rewrite history, or update product branches.
- Do not expose credentials through command output, backups, NFS, or reports.
- Do not hand-edit Hermes SQLite when the installed CLI/config interface can perform the operation.
- Stop at the current task's rollback checkpoint if any verification gate fails.
- Store private rollout evidence under `/home/yaro/work/migrations/canonical-repos-20260821`; mode `0700` for the directory and `0600` for configuration backups.

## File and State Map

### System configuration

- Create on coding: `/etc/exports.d/development-repos.exports` — restricted repository export.
- Create on coding: `/etc/nfs.conf.d/development-repos.conf` — require NFSv4 and disable v3 for this previously unused server.
- Modify on Hermes/OpenClaw: `/etc/fstab` — persistent automount at `/home/yaro/work/repos`.
- Create on coding: `/usr/local/bin/claude` symlink — make the existing wrapper visible to non-interactive management shells.

### Agent configuration

- Modify on coding: `/home/yaro/.codex/config.toml` — trust the canonical root.
- Modify through Hermes CLI: `/home/hermes/.hermes/config.yaml` and `profiles/{dev,ops,studio}/config.yaml` — repository scan root.
- Modify through Hermes CLI: each profile's `projects.db` — 42 named projects, one folder each; archive stale `voip-thug-portal`.
- Create on OpenClaw: `/home/yaro/.openclaw/workspace/projects` symlink.
- Modify on OpenClaw: `/home/yaro/.openclaw/workspace/AGENTS.md` and `TOOLS.md`.

### Canonical documentation

- Modify: `/home/yaro/work/repos/README.md`.
- Modify: `/home/yaro/work/repos/AGENTS.md`.
- Create: `/home/yaro/work/repos/CLAUDE.md` symlink to `AGENTS.md`.
- Create: `/home/yaro/work/repos/PROJECTS.md`.
- Create or repair within each Git root: `AGENTS.md` and `CLAUDE.md` according to the reconciliation matrix captured in Task 1.

### VoIPThug organization

- Create under `/home/yaro/work/repos/voipthug`: `docs/{briefs,audits,worklogs}`, `project-assets`, `artifacts/final-audit`, and `scripts/audit`.
- Modify `/home/yaro/work/repos/voipthug/.gitignore` only for the large untracked production/artifact directories named in Task 6.
- Record every move in `/home/yaro/work/migrations/canonical-repos-20260821/voipthug-moves.tsv`.

---

### Task 1: Capture an immutable preflight and rollback baseline

**Files:**
- Create: `/home/yaro/work/migrations/canonical-repos-20260821/preflight/`
- Create: `/home/yaro/work/migrations/canonical-repos-20260821/repositories.tsv`
- Create: `/home/yaro/work/migrations/canonical-repos-20260821/files-before.sha256`
- Create: `/home/yaro/work/migrations/canonical-repos-20260821/rollback.md`

**Interfaces:**
- Consumes: the live state of all three VMs and 42 repositories.
- Produces: a read-only baseline used by every later task and the final before/after verifier.

- [ ] **Step 1: Reconfirm host identities, tool versions, free GID, and canonical count**

Run from the operator machine:

```bash
ssh coding 'hostname; id yaro; getent group 2200 || true; /home/yaro/.local/lib/claude.real --version; /usr/bin/codex --version; find /home/yaro/work/repos -mindepth 1 -maxdepth 2 -type d -name .git -printf "%h\n" | sort | wc -l'
ssh hermes 'hostname; id yaro; id hermes; getent group 2200 || true; sudo -n -u hermes /home/hermes/.local/lib/hermes-agent/venv/bin/hermes --version'
ssh openclaw 'hostname; id yaro; getent group 2200 || true; /home/yaro/.npm-global/bin/openclaw --version'
```

Expected: hosts are `coding-agents`, `hermes-orchestrator`, and `openclaw-gateway`; GID 2200 has no record; repository count is exactly 42.

- [ ] **Step 2: Create the private baseline directory**

```bash
ssh coding 'install -d -m 0700 /home/yaro/work/migrations/canonical-repos-20260821/preflight'
```

- [ ] **Step 3: Capture repository state without changing it**

Use a shell loop over sorted `.git` roots to write tab-separated absolute path, basename, HEAD, branch, origin URL, and porcelain status count to `repositories.tsv`. In that loop, bind the basename to `repo_name` and save full porcelain output under `preflight/git-status/$repo_name.txt`. Reject duplicate basenames and stop unless exactly 42 rows were written.

Verification commands:

```bash
ssh coding 'test "$(wc -l < /home/yaro/work/migrations/canonical-repos-20260821/repositories.tsv)" -eq 42'
ssh coding 'cut -f2 /home/yaro/work/migrations/canonical-repos-20260821/repositories.tsv | sort | uniq -d | test "$(wc -l)" -eq 0'
```

- [ ] **Step 4: Capture documentation, ACL, mount, and tool-configuration state**

Hash every existing `AGENTS.md`, `CLAUDE.md`, root `README.md`, root `PROJECTS.md`, and every top-level `voipthug*` item. Save `getfacl -R -p /home/yaro/work/repos`, `findmnt`, `stat`, `/etc/exports*`, and redacted configuration inventories. Copy exact configs to `preflight/private/` with mode `0600`; never print their contents.

- [ ] **Step 5: Write the rollback manifest**

`rollback.md` must name each captured file, its restore destination, the command needed to disable the export/mounts, and the rule that pre-existing Git changes are never restored with Git reset/checkout/clean.

- [ ] **Step 6: Verify baseline completeness**

Run:

```bash
ssh coding 'test -s /home/yaro/work/migrations/canonical-repos-20260821/repositories.tsv && test -s /home/yaro/work/migrations/canonical-repos-20260821/files-before.sha256 && test -s /home/yaro/work/migrations/canonical-repos-20260821/rollback.md'
```

Expected: exit 0. This is checkpoint 1; no operational state has changed.

---

### Task 2: Establish the restricted NFSv4 canonical mount

**Files:**
- Create: coding `/etc/exports.d/development-repos.exports`
- Create: coding `/etc/nfs.conf.d/development-repos.conf`
- Modify: Hermes `/etc/fstab`
- Modify: OpenClaw `/etc/fstab`

**Interfaces:**
- Consumes: baseline from Task 1 and unused GID 2200.
- Produces: read-write `/home/yaro/work/repos` on Hermes and OpenClaw backed by coding.

- [ ] **Step 1: Install only the required packages**

```bash
ssh coding 'sudo -n apt-get update && sudo -n apt-get install -y nfs-kernel-server nfs-common acl'
ssh hermes 'sudo -n apt-get update && sudo -n apt-get install -y nfs-common acl'
ssh openclaw 'sudo -n apt-get update && sudo -n apt-get install -y nfs-common acl'
```

Expected: package commands exit 0; no unrelated full-upgrade runs.

- [ ] **Step 2: Create the shared group with fixed GID**

On each VM, recheck `getent group 2200` and `getent group devprojects`. If both are absent, run `sudo groupadd --gid 2200 devprojects`. Add `yaro` on all three VMs and `hermes` on the Hermes VM with `usermod -aG`; do not change any primary group.

Verify:

```bash
ssh coding 'getent group devprojects; id yaro'
ssh hermes 'getent group devprojects; id yaro; id hermes'
ssh openclaw 'getent group devprojects; id yaro'
```

- [ ] **Step 3: Apply group and default ACLs without changing Git modes**

First read every exact repository path from the first column of `repositories.tsv`, run `git -C "$repo_path" ls-files -s`, and record one hash per repository. Then on coding:

```bash
sudo find /home/yaro/work/repos -type d -exec setfacl -m g:devprojects:rwx,d:g:devprojects:rwx,d:m:rwx {} +
sudo find /home/yaro/work/repos -type f -exec setfacl -m g:devprojects:rw {} +
```

Recompute `git ls-files -s` hashes and require them to match the baseline exactly.

- [ ] **Step 4: Install the NFS server configuration**

Create `/etc/nfs.conf.d/development-repos.conf` with:

```ini
[nfsd]
vers3=n
vers4=y
```

Create `/etc/exports.d/development-repos.exports` with exactly:

```text
/home/yaro/work/repos 192.168.88.11(rw,sync,root_squash,no_subtree_check) 192.168.88.14(rw,sync,root_squash,no_subtree_check)
```

Run `sudo exportfs -rav`, `sudo systemctl enable --now nfs-server`, and `sudo exportfs -v`. Expected: one export with only the two approved clients.

- [ ] **Step 5: Create client mountpoints and persistent automounts**

On Hermes and OpenClaw, create `/home/yaro/work/repos` owned by `yaro:devprojects` with mode `2775`. On Hermes, grant the `hermes` account traverse-only ACLs on `/home/yaro` and `/home/yaro/work`.

Append exactly one guarded `/etc/fstab` entry on each client:

```fstab
192.168.88.10:/home/yaro/work/repos /home/yaro/work/repos nfs4 rw,nfsvers=4.2,proto=tcp,noatime,_netdev,nofail,x-systemd.automount,x-systemd.idle-timeout=600 0 0
```

Run `sudo systemctl daemon-reload`, `sudo mount /home/yaro/work/repos`, and `findmnt -T /home/yaro/work/repos` on each client.

- [ ] **Step 6: Prove identity and service-account writes**

Create three unique probe files in `/home/yaro/work/repos/.agent-access-probes/`: one as coding `yaro`, one via `sudo -u hermes` on the Hermes VM, and one as OpenClaw `yaro`. Read and hash all three from every VM, then delete only those three named probes and the empty probe directory.

Expected: identical hashes, group `devprojects`, no world-write bit, and no remaining probe path.

- [ ] **Step 7: Record checkpoint 2 and rollback on failure**

Save `exportfs -v`, `findmnt`, group membership, and ACL samples under `preflight/../checkpoint-2/`. On failure, unmount clients, remove only the added fstab/export lines, restore ACLs from the baseline, and stop.

---

### Task 3: Register the canonical root with Claude and Codex

**Files:**
- Create: coding `/usr/local/bin/claude` symlink
- Modify: coding `/home/yaro/.codex/config.toml`
- Create: `/home/yaro/work/repos/CLAUDE.md` symlink

**Interfaces:**
- Consumes: canonical local root and root instructions prepared in Task 5; this task may create the root symlink before its target is updated.
- Produces: deterministic Claude/Codex command discovery and Codex trust.

- [ ] **Step 1: Make Claude available to non-interactive management shells**

Verify `/home/yaro/.local/bin/claude` is the expected account-rotation wrapper and `/home/yaro/.local/lib/claude.real --version` returns 2.1.233. Create `/usr/local/bin/claude` as a symlink to `/home/yaro/.local/bin/claude`; do not replace or bypass the wrapper.

Test:

```bash
ssh coding 'timeout 15 claude --version'
```

Expected: Claude Code 2.1.233 output and exit 0.

- [ ] **Step 2: Add one Codex trust entry**

Add, only if absent:

```toml
[projects."/home/yaro/work/repos"]
trust_level = "trusted"
```

Do not modify model, MCP, sandbox, approval, authentication, or marketplace settings.

- [ ] **Step 3: Validate Codex configuration and root context**

Run:

```bash
ssh coding '/usr/bin/codex --strict-config doctor --summary --no-color --ascii'
ssh coding 'cd /home/yaro/work/repos && test "$(git -C voipthug rev-parse --show-toplevel)" = /home/yaro/work/repos/voipthug'
```

Expected: strict configuration parses and doctor has no new config error.

- [ ] **Step 4: Create the root Claude compatibility link**

If `/home/yaro/work/repos/CLAUDE.md` is absent, create a relative symlink `CLAUDE.md -> AGENTS.md`. If it exists at execution time, stop and reconcile its contents rather than overwrite it.

---

### Task 4: Register all repositories in Hermes and OpenClaw

**Files:**
- Modify through CLI: Hermes profile configuration and project registries
- Create: OpenClaw `/home/yaro/.openclaw/workspace/projects` symlink
- Modify: OpenClaw workspace `AGENTS.md`, `TOOLS.md`

**Interfaces:**
- Consumes: mounted canonical root and `repositories.tsv`.
- Produces: 42 active Hermes projects per profile and deterministic OpenClaw workspace access.

- [ ] **Step 1: Configure Hermes repository scan roots through the CLI**

For homes `/home/hermes/.hermes`, `/home/hermes/.hermes/profiles/dev`, `/home/hermes/.hermes/profiles/ops`, and `/home/hermes/.hermes/profiles/studio`, run as `hermes`:

```bash
env HERMES_HOME="$profile_home" /home/hermes/.local/lib/hermes-agent/venv/bin/hermes config set desktop.repo_scan_enabled true
env HERMES_HOME="$profile_home" /home/hermes/.local/lib/hermes-agent/venv/bin/hermes config set desktop.repo_scan_roots '["/home/yaro/work/repos"]'
```

Read both keys back and require the boolean `true` and one-item absolute path list.

- [ ] **Step 2: Create one native Hermes project per Git repository and profile**

For each of the 42 rows in `repositories.tsv`, use basename as both initial display name and explicit slug, and the absolute path as the sole/primary folder:

```bash
env HERMES_HOME="$profile_home" /home/hermes/.local/lib/hermes-agent/venv/bin/hermes project create "$repo_name" "$repo_path" --slug "$repo_name" --primary "$repo_path"
```

Before creation, parse `hermes project list` and skip an exact slug/path match. Stop on a slug collision with a different path. Do this for default, `dev`, `ops`, and `studio`.

- [ ] **Step 3: Reconcile the stale Studio project**

Inspect `voip-thug-portal` with `hermes project show`. If its only folder is the nonexistent `/home/yaro/work/repos/voipthug-portal`, archive it using:

```bash
env HERMES_HOME=/home/hermes/.hermes/profiles/studio /home/hermes/.local/lib/hermes-agent/venv/bin/hermes project archive voip-thug-portal
```

Do not archive it if new evidence shows it owns a valid path; stop for review instead.

- [ ] **Step 4: Verify Hermes project counts and folder existence**

For every profile, require 42 active canonical project slugs, every folder beneath `/home/yaro/work/repos`, every folder present, and no active folder ending in `/voipthug-portal`. Use read-only SQLite only as an independent verifier after the CLI operations.

- [ ] **Step 5: Add the OpenClaw workspace project link**

Verify `/home/yaro/.openclaw/workspace/projects` is absent. Create the relative or absolute symlink to `/home/yaro/work/repos`; if any file already occupies the path, stop rather than replace it.

- [ ] **Step 6: Extend OpenClaw instructions without replacing identity content**

Append a clearly delimited `## VTHQ development repositories` section to `AGENTS.md` and `TOOLS.md` only if absent. It must state:

- canonical path `/home/yaro/work/repos` and workspace link `projects/`;
- each child Git root is independent;
- read root and local `AGENTS.md`/`CLAUDE.md` before editing;
- preserve dirty work and avoid broad Git operations;
- source repositories are not runtime paths;
- consult `/home/yaro/work/repos/PROJECTS.md` for the catalog.

- [ ] **Step 7: Validate OpenClaw configuration and access**

Run `openclaw config validate`, `readlink -f workspace/projects`, count 42 Git roots through the link, and compare representative HEADs/hashes with coding. Do not restart the gateway unless the validated configuration itself changed in a way that requires it; the workspace-document and symlink changes do not.

---

### Task 5: Reconcile root and per-repository agent documentation

**Files:**
- Modify/Create: canonical `README.md`, `AGENTS.md`, `CLAUDE.md`, `PROJECTS.md`
- Create/Modify: per-repository `AGENTS.md` and `CLAUDE.md`
- Create: `/home/yaro/work/migrations/canonical-repos-20260821/documentation-review.tsv`

**Interfaces:**
- Consumes: repository baseline, existing documentation, manifests, Git metadata, and verified deployment notes.
- Produces: effective agent instructions for all 42 repositories and a reviewed catalog.

- [ ] **Step 1: Generate the evidence matrix**

For each exact repository row, record: basename, path, origin, default/current branch, README files, `AGENTS.md` type (file/symlink/missing), `CLAUDE.md` type, primary manifests (`package.json`, `pyproject.toml`, `go.mod`, `Cargo.toml`), and verified runtime mapping from existing docs. Store one row per repo in `documentation-review.tsv`; require 42 rows.

- [ ] **Step 2: Rebuild the canonical root documents**

Update `README.md` and `AGENTS.md` to use `/home/yaro/work/repos`, remove the outdated statement that Arynto remains under `/root`, include all verified project families, and retain source-versus-runtime rules. Build `PROJECTS.md` as a 42-row catalog containing repository name, verified description, detected stack, origin host/owner without credentials, documentation coverage, and runtime mapping when verified.

- [ ] **Step 3: Create missing instruction paths conservatively**

Apply this exact decision table per repository:

1. Existing `AGENTS.md` + existing `CLAUDE.md`: preserve both; repair only verified stale paths/contradictions.
2. Existing `AGENTS.md` + missing `CLAUDE.md`: create relative symlink `CLAUDE.md -> AGENTS.md`.
3. Missing `AGENTS.md` + existing `CLAUDE.md`: create `AGENTS.md` containing a short project-scope header, an instruction to read `CLAUDE.md`, independent-repository/dirty-work safety, and a maintaining-this-file section; do not alter `CLAUDE.md` unless evidence is stale.
4. Both missing: create the same minimal `AGENTS.md`, pointing to the repository README and manifest-defined commands, then create `CLAUDE.md -> AGENTS.md`.

The minimal file must not claim a test, build, deployment, owner, host, or architecture that was not verified.

- [ ] **Step 4: Review all existing instruction files for stale paths**

Search for `/work/repos`, `/root/`, nonexistent `/home/yaro/work/repos/*` paths, stale `voipthug-portal`, placeholder markers, and broken relative Markdown links. For every replacement, record old text, evidence, and new text in `documentation-review.tsv`. Do not bulk replace `/root/` because some runtime or secrets paths may remain valid.

- [ ] **Step 5: Validate documentation coverage and Git impact**

Require every Git root to resolve readable `AGENTS.md` and `CLAUDE.md`; require zero introduced placeholders and zero broken local links. Compare `git status --porcelain` with Task 1 and produce an explicit per-repo list of only intended documentation additions/modifications. Do not commit product repositories.

---

### Task 6: Organize VoIPThug material under the canonical repository

**Files:**
- Create/Modify: VoIPThug directories named in the file map
- Modify: VoIPThug `.gitignore`
- Create: migration `voipthug-moves.tsv`

**Interfaces:**
- Consumes: exact loose-item inventory and active-reference scan.
- Produces: organized VoIPThug project material plus a reversible move manifest.

- [ ] **Step 1: Recheck protected exclusions and active references**

Confirm these paths remain untouched:

```text
/home/yaro/work/worktrees/voipthug-retail-content
/home/yaro/work/bots/telegram/voipthug-bot
/home/yaro/work/archive/voipthug-*
```

Run `git worktree list --porcelain`, process scans, Firstmate state/brief scans, and script/document searches for every top-level source path. Stop if an active process still depends on a source path and a compatibility link cannot safely preserve it.

- [ ] **Step 2: Create destinations and record collision-free moves**

Create the approved destination directories. Before each move, require source exists and destination does not. Write source, destination, size, type, and pre-move SHA-256 (or deterministic tree hash) to `voipthug-moves.tsv`, then move exactly one item.

- [ ] **Step 3: Move project directories**

Use these mappings:

```text
/home/yaro/work/voipthug-art-e1       -> project-assets/art-e1
/home/yaro/work/voipthug-brand-v2     -> project-assets/brand-v2
/home/yaro/work/voipthug-logo         -> project-assets/logo-production
/home/yaro/work/voipthug-final-audit  -> artifacts/final-audit
```

- [ ] **Step 4: Move reusable audit scripts**

Move `run-voipthug-final-mechanical-audit.sh`, `voipthug-a11y-audit.mjs`, `voipthug-external-link-audit.py`, both `voipthug-runtime-audit.*` files, `voipthug-secret-scan.py`, and `voipthug-static-export-audit.py` into `scripts/audit/`. Update internal absolute paths only after verifying each script's intended working directory.

- [ ] **Step 5: Move Markdown/log material by evidence-backed category**

- `docs/worklogs/`: filenames containing `worklog` plus `voipthug-deployment-worklog-2026-08-15.md`.
- `docs/audits/`: filenames containing `audit`, `remediation`, `blockers`, `edge-inventory`, or `uniqueness-matrix`; keep the associated uniqueness log beside its matrix.
- `docs/briefs/`: remaining VoIPThug Markdown briefs, authorizations, task descriptions, product-truth documents, brand corrections, and rebuild/gate briefs.

Record every exact move; do not use an unresolved wildcard as the move target set.

- [ ] **Step 6: Protect large generated assets from accidental Git addition**

Add exact root-relative ignore entries:

```gitignore
/project-assets/art-e1/
/project-assets/brand-v2/
/project-assets/logo-production/
/artifacts/final-audit/
```

Do not ignore `docs/` or `scripts/audit/`. Do not add Git LFS unless a pre-existing approved LFS policy is found.

- [ ] **Step 7: Update references and validate the move manifest**

Update known active documentation/scripts to new canonical paths. Re-hash every destination and require it to match its recorded source hash. Require all source paths in the manifest to be absent or intentional compatibility links, and all destinations present. Confirm protected exclusions remain unchanged.

- [ ] **Step 8: Compare VoIPThug Git status to baseline**

Expected additions are only organized docs/scripts, `.gitignore`, and the two pre-existing untracked asset directories remain preserved. The branch remains `master`, HEAD remains `32ec2b9e6903bd961f0ffc9d12ede00b25075342`, and no pull/update occurs.

---

### Task 7: Run the cross-system verification and rollback drill

**Files:**
- Create: `/home/yaro/work/migrations/canonical-repos-20260821/verification.md`
- Create: `/home/yaro/work/migrations/canonical-repos-20260821/files-after.sha256`

**Interfaces:**
- Consumes: all previous task outputs.
- Produces: fresh completion evidence and tested rollback instructions.

- [ ] **Step 1: Verify mounts, identities, and repository parity**

From coding, Hermes, and OpenClaw, record `findmnt`, count 42 Git roots, read all 42 HEADs, and hash root `AGENTS.md`, `CLAUDE.md`, `PROJECTS.md`, plus representative repository files. Require all values to match.

- [ ] **Step 2: Verify Claude and Codex behavior**

Run Claude's explicit version through the non-interactive path. Run Codex strict-config doctor. Use non-mutating prompt/context inspection or a read-only invocation from the canonical root to prove both tools receive root instructions and a representative repository's local instructions; do not let this verification edit repositories.

- [ ] **Step 3: Verify Hermes profiles**

For default, `dev`, `ops`, and `studio`, require 42 active canonical project rows, 42 existing primary folders, and scan-root configuration equal to the one-item canonical list. Confirm the archived stale project is not active. Verify the running `hermes` account can stat and read each root.

- [ ] **Step 4: Verify OpenClaw**

Run `openclaw config validate`; resolve `workspace/projects`; count 42 repos; and use a read-only OpenClaw agent/tool invocation to read the catalog and one repository's instructions without modifying files.

- [ ] **Step 5: Test automount recovery without rebooting**

On each client, unmount the idle NFS mount through systemd, access the path, and confirm automount restores it. Stop the NFS server only if no active agent process has the mount open; otherwise validate the configured `nofail`/automount units without disruption. Never reboot as part of this task.

- [ ] **Step 6: Dry-run the rollback manifest**

Check every backup and target named by `rollback.md`, verify commands reference exact paths and the two client IPs, and prove the VoIPThug reverse-move list has no destination collisions. Do not execute rollback when verification is green.

- [ ] **Step 7: Verify Git preservation**

Compare all 42 before/after HEADs, branches, remotes, and porcelain output. Require unchanged HEAD/branch/remote everywhere and explain every added/modified documentation path. Fail if any pre-existing dirty path disappeared or changed unexpectedly.

- [ ] **Step 8: Write the final evidence report**

`verification.md` must include command timestamps, exit codes, counts, any intentionally deferred compatibility links, the exact list of changed configs/docs, and rollback locations. It must not contain credentials or raw auth configuration.

---

### Task 8: Review and handoff

**Files:**
- Modify: implementation plan checkboxes only if the execution workflow tracks completion in place.
- Review: design spec, migration evidence, and every changed path.

**Interfaces:**
- Consumes: completed verification report.
- Produces: user-facing completion summary with evidence and any remaining review choices.

- [ ] **Step 1: Run verification-before-completion**

Load the `verification-before-completion` skill and rerun the commands that prove the final claims. Do not rely on earlier checkpoint output.

- [ ] **Step 2: Present repository documentation changes for review**

List all changed project repositories, distinguish newly created instruction files from repaired ones, and explicitly state that no product repository was committed or pushed.

- [ ] **Step 3: Present VoIPThug organization results**

Report item counts and sizes by destination, protected exclusions, compatibility links, and the move-manifest location.

- [ ] **Step 4: Present infrastructure and tool-registration results**

Report export clients, mount path, service-account access, Claude/Codex checks, Hermes per-profile counts, and OpenClaw checks without exposing secrets.

- [ ] **Step 5: Offer the safe next action**

Ask whether the reviewed documentation changes should be committed per repository. Do not create those commits or push anything without that follow-up authorization.
