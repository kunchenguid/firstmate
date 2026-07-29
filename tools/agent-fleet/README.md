# Agent Fleet

Agent Fleet is a machine-global account routing layer for local Claude Code and Codex CLI agents.
It gives an orchestrator a dynamic pool of named account profiles without making the orchestrator or session backend responsible for credentials.

The profile registry contains policy and opaque labels only. Provider logins
remain in private per-profile homes owned by the provider CLI.

## Source and installation

Agent Fleet ships as a provider-neutral component of the public Firstmate
repository under `tools/agent-fleet`.
Its original standalone history and import boundary are recorded in
[PROVENANCE.md](PROVENANCE.md).

Installing and developing the package requires `uv` and Python 3.11 or newer.
Managed routing also requires configured Claude Code or Codex CLI binaries and a profile-aware `quota-axi` executable.
Default TOON output requires the `toon` executable on `PATH`; pass `--format json` when TOON output is not needed.

Install a tagged release directly from the public repository:

```sh
uv tool install --force \
  "agent-fleet @ git+https://github.com/ruby-dlee/firstmate.git@agent-fleet-v0.2.0#subdirectory=tools/agent-fleet"
agent-fleet --format json version
```

For development from a Firstmate checkout, install the local package instead:

```sh
uv tool install --force ./tools/agent-fleet
```

Reinstalling is idempotent and updates the existing `agent-fleet` tool
environment in place.
It does not modify provider profile homes or Fleet state.

## Boundaries

The launch stack is deliberately split:

1. Firstmate (or another client) chooses the task, provider, and account pool.
2. Agent Fleet atomically selects and leases one concrete profile.
3. The session backend hosts the process.
4. Claude Code or Codex CLI reads credentials from that profile's isolated home.

Herdr native restore must remain disabled for multi-account panes. A bare
`codex resume` or `claude --resume` does not contain enough information to
recover the account home. Agent Fleet records task-to-profile and
task-to-provider-session mappings and resumes through the original profile.

## Initial setup

```sh
agent-fleet init --claude 1 --codex 1
agent-fleet project register --provider claude /absolute/path/to/project
agent-fleet project register --provider codex /absolute/path/to/project
agent-fleet profile provision --all
agent-fleet profile identity adopt claude-1 --allow-keychain-prompt
agent-fleet profile identity adopt codex-1
```

Before `init`, set `AGENT_FLEET_CLAUDE_BIN`, `AGENT_FLEET_CODEX_BIN`, or `AGENT_FLEET_QUOTA_BIN` when the executable defaults in "State" do not match the local installation.
The generated registry pins the resolved executable paths.

`profile provision --all` provisions only profiles whose safety policy is `worker`; the sealed Bridge topology and its exact worker/reserve split are owned by the [cutover guide](../../docs/bridge-cutover-sealed-runtimes.md#exact-worker-topology).

Register every Git project that may host a managed worker before enrollment and launch.
Registration stores the canonical worktree root, while launch authorization compares Git common directories so linked Treehouse worktrees remain eligible.
Broad, symlinked, unrelated, and unregistered working directories fail closed before a provider process or lease starts.
Provider-owned project control files (`.mcp.json` for Claude and
`.codex/config.toml` for Codex) are rejected during preparation and rechecked
immediately before the final enter/exec boundary. A same-uid process can still
create one after that last portable filesystem check and before the provider
opens the project. Managed Claude closes that residual with the provider-native
`--setting-sources user` launch option, retaining the isolated profile's hooks
while excluding project and local settings. The sealed Codex launch contract
exposes no equivalent source-exclusion option; its project-control-file race remains an
explicit same-uid residual, bounded by the immediate final preflight plus
managed plugin disablement and active-root-only trust.

The sealed cutover release never starts provider login or a browser. Credentials
must already exist in each isolated worker home. `profile identity adopt` is a
browser-free, provider-batch operation: every same-provider worker must be
disabled, drained, provisioned, freshly source-attested, remotely verified, and
identity-distinct before one atomic provider bundle is written. Enable remains
a separate phase:

```sh
agent-fleet profile verify claude-1 --allow-keychain-prompt
agent-fleet profile verify codex-1
agent-fleet profile enable claude-1
agent-fleet profile enable codex-1
```

`profile enroll` and its `profile login` alias have a deliberately narrow
three-state contract:

- An already pinned credential with the exact same live identity and source is
  a verified no-op; no provider login is invoked.
- A fresh existing credential that is not yet durably pinned directs the
  operator to the provider-batch `profile identity adopt` command.
- Missing, remotely unverifiable, or identity-replacing credentials are refused
  before any provider/browser login. Use the explicit disabled-provider
  recovery workflow below; ordinary enroll/login remains browser-free.

### First-bundle credential initialization

`profile initialize-login` is the only provider-login workflow allowed when a provider has no identity bundle.
It is a separate trust-on-first-use ceremony, not a fallback hidden inside recovery.
It refuses if a bundle already exists and directs the operator to `recover-login` instead.
The same provider-wide maintenance conditions apply: every worker disabled, every worker lease drained, every continuable provider session mapping removed, exact registry and sealed binaries unchanged, and only an explicitly selected `safety_policy=worker` target.
A dormant mapped session is still resumable and therefore blocks rotation even when its process lease has ended.
Desktop-shared reserves are excluded before any home, credential, journal, or Keychain path is derived.

Initialize each isolated worker explicitly.
Codex uses its isolated device flow; Claude requires the explicit browser and exact-account Keychain gates:

```sh
agent-fleet profile initialize-login codex-1
agent-fleet profile initialize-login claude-1 \
  --browser --allow-keychain-prompt
```

After a successful partial ceremony, Fleet commits a provider-scoped provisional manifest instead of pretending the provider is ready.
That closed manifest pins the exact expected worker set, topology and binary contract, and each completed worker's fresh identity fingerprint, normalized credential source, source stat, and transaction generation.
Every later invocation reproves every recorded peer before another provider login and again before commit.
Drift, tamper, an ejected recorded peer, duplicate worker identities, or a base/Desktop identity collision fails closed.
A recorded worker cannot be silently initialized again; select one of the named pending workers.

The provisional generation also has a non-secret locator in the deterministic first worker home.
Its contract binds the registry path and content digest, state and share roots, Agent Fleet/runtime contract version, complete relevant settings, topology, provider binary markers, and sealed Quota runtime.
Thus a changed state root or config cannot make an unfinished batch disappear and silently begin a second trust ceremony.

Only the exact complete, freshly proved, identity-distinct worker set is adopted as the provider identity bundle.
Bundle adoption and provisional manifest removal share the crash-recoverable transaction: a crash between them restores the preceding provisional generation.
Initialization never uses the default/Desktop identity as a login target, never writes, copies, or logs it out, never includes reserves in the worker set, and never auto-enables routing.
Its only external-identity access is the existing read-only fingerprint anchor comparison required to reject account collisions.

### Explicit credential recovery

`profile recover-login` is an exceptional maintenance command for restoring the already pinned identity of one worker.
It is not initial enrollment and it cannot replace a worker with a different account.
Before any provider action it requires an existing identity binding, every same-provider worker disabled, zero same-provider worker leases, zero continuable same-provider session mappings, the exact registry unchanged, and the target provisioned against its sealed provider binary.
The provider maintenance lock stays held through staged login, local promotion, whole-provider verification, commit, and cleanup.
The provider login itself is launched in a detached session and process group; its PID, process-start token, and PGID are journaled before exec is released.
Restart recovery refuses while either that exact authority process or any member of its process group remains live or indeterminate.

Codex defaults to its device flow and never uses the base/Desktop home:

```sh
agent-fleet profile recover-login codex-1
```

Claude's current login is browser-capable, so both browser and scoped-Keychain interaction must be explicit.
Use a private browser context and do not change Claude Desktop's login:

```sh
agent-fleet profile recover-login claude-1 \
  --browser --allow-keychain-prompt
```

The provider runs only in a private transaction-owned staged home.
Codex promotes a staged `auth.json` generation.
On macOS, Claude promotes only the staged home's uniquely suffixed `Claude Code-credentials-<hash>` Keychain item to the stable worker's uniquely suffixed service, using the verified passwd username as the exact Keychain account, and that account is part of the normalized source contract.
The unsuffixed/default Claude service, base homes, Desktop homes, browser sessions, and logout commands are never staging or promotion targets and are never changed or invoked by recovery.
They are observed only through the existing read-only identity-anchor path needed for collision rejection.
Keychain secret bytes travel only over an OS pipe and never enter argv, environment, journals, audit output, or command results.
Every macOS Keychain operation uses the verified root-owned, executable, non-group/world-writable `/usr/bin/security` binary under a passwd-derived home and username plus a fixed system path and locale.
During a transaction, each operation runs behind a detached gated helper whose PID, process-start token, and process group are durable before the helper is released; restart recovery refuses while that helper or group remains live or indeterminate.

After local promotion, recovery freshly proves every same-provider worker in the same maintenance attempt.
If all workers are valid and identity-distinct, the existing provider identity bundle is rebuilt under the same adoption semantics and the result points to the normal explicit enable gate.
If a peer worker is ejected or indeterminate, the repaired target remains disabled and the result names only the blocked worker labels; recover or verify the whole worker set before enabling anything.
Recovery never auto-enables routing.

The transaction can restore the previous local file or exact scoped-Keychain generation after an error or process crash.
Rollback generations, Keychain cleanup, metadata restoration, and staged-home quarantine are separately journaled so another process crash during recovery resumes the same exact generation without discarding the rollback source or orphaning credential-bearing state.
Bundle, provisional-manifest, locator, and credential rollback accept only the exact digest-bound snapshotted generation or the exact transaction-planned generation; unknown drift is preserved and refused.
File cleanup never pathname-unlinks after a generation check: each attributed artifact is moved without replacement into a deterministic per-transaction retirement directory, scrubbed to zero bytes through its still-open descriptor, fsynced, and retained as a private zero-byte marker.
This intentionally leaves a bounded set of non-secret markers for each explicit recovery transaction (one normal marker and at most eight interrupted-copy markers per artifact) so a same-UID pathname substitution can be preserved and refused instead of being accidentally deleted.
It cannot undo provider-side token family rotation or revocation caused by the provider login itself.
On any such failure, keep the provider disabled, preserve unaffected worker credentials, and complete worker-set recovery before the enable gate.
Never use provider logout as cleanup.

Pending credential journals are discovered directly from the private transaction root rather than from the current worker list.
They fence routing selection (including dry-run choice), enablement, policy changes, cooldown changes, enrollment, and provider maintenance even if registry policy drift would otherwise hide the worker.
If a process died after the transaction was durably committed, repeating the explicit command performs fresh whole-provider verification and returns the committed result without invoking provider login or rotating another token.

Fresh quota proofs are cached only after the credential and identity-binding transaction is durably committed.
Any pre-commit error or crash restores the previous credential generation without changing quota cache bytes; blocked or unproved workers are never written as successful cache entries.

The [Bridge cutover guide](../../docs/bridge-cutover-sealed-runtimes.md#exact-worker-topology) owns its fixed worker/reserve topology and exclusions.

Do not run raw provider login/logout, relogin the Desktop apps, or treat login as
idempotent. Those actions can rotate or revoke sessions shared by other
processes.

Add or remove profiles at any time; the registry has no fixed account count:

```sh
agent-fleet profile add claude-4 --provider claude
agent-fleet profile add codex-3 --provider codex --max-concurrent 3
agent-fleet profile disable codex-3
agent-fleet profile remove codex-3
```

Profile ids are operational labels such as `claude-1`; emails are rejected.
Registry mutations share the provider maintenance lock with enrollment and
selection, so a concurrent `profile add`, verify, login, quota refresh, or worker
start either completes under the lock or fails closed.

Worker profiles must use an identity distinct from the provider's base CLI and
Desktop identities. Use `manual_only` or `desktop_shared` for a human reserve;
those policies cannot join a worker pool or be enabled for worker routing. Claude
worker launches also set `DISABLE_LOGIN_COMMAND=1` and
`DISABLE_LOGOUT_COMMAND=1`, preventing an in-flight session from replacing its
managed login. Agent Fleet re-reads Claude Desktop's identity immediately before
each selection rather than trusting a TTL cache.

## Routing contract

Shell integrations should request compact JSON explicitly:

```sh
agent-fleet --format json lease choose \
  --task fm:crew:example --pool codex-crew --provider codex \
  --workspace /absolute/path/to/task-worktree

agent-fleet exec \
  --task fm:crew:example --pool codex-crew --provider codex \
  --workspace /absolute/path/to/task-worktree -- \
  --dangerously-bypass-approvals-and-sandbox "$(cat brief.md)"

agent-fleet resume --task fm:crew:example \
  --workspace /absolute/path/to/task-worktree -- \
  --dangerously-bypass-approvals-and-sandbox
agent-fleet --format json session status --task fm:crew:example
agent-fleet --format json lease recover --task fm:crew:example \
  --workspace /absolute/path/to/task-worktree
agent-fleet --format json lease release --task fm:crew:example
agent-fleet --format json session remove --task fm:crew:example
```

`exec` binds the lease to its own PID and then replaces itself with the provider
CLI, preserving a verifiable owner identity. A standalone `lease choose`
creates a short reservation that must be followed by `exec`; expired or dead
owners are reclaimed under the same portable directory lock used for
selection. A reservation may be released normally when pane creation fails,
while a live worker lease requires an explicit forced release after the worker
has stopped. Worker `exec` and `resume` require a managed task id, and every live
lease and lock requires a verified process-start token; missing tokens fail
closed. Selection, execution, and recovery require the intended task worktree
explicitly and never infer the orchestrator's working directory. A live task
can never be rebound to a different process.
Provider arguments use a strict operation-aware positive grammar matching FirstMate's Claude and Codex launch templates.
`exec` requires the provider autonomy flag, accepts only FirstMate's optional model, effort, and Codex turn-end notification fields, and requires exactly one prompt.
Agent Fleet reconstructs the provider argv from the parsed fields and inserts a provider-level `--` before that prompt, so prompt text that resembles a command remains prompt text.
`resume` accepts the same safe option family but no caller prompt, session id, alternate command, attached flag form, or arbitrary provider config.
Every reconstructed Claude exec and resume also adds `--setting-sources user`;
callers cannot widen or replace that provider-native setting-source policy.

Claude provisioning writes a closed `settings.json` and a closed `.claude.json` containing only onboarding plus registered-project trust state; it strips opaque oauth, refresh, MCP, plugin, and unrelated project keys rather than preserving unknown state.
Credential identity remains solely in the source-attested `.credentials.json` or exact path-scoped Keychain service, never in `.claude.json`.
Static fixtures prove this closed rewrite and idempotence.
The first real Claude canary is still a mandatory rollback boundary: an auth/onboarding prompt or any mutation of the closed state aborts activation, disables routing, and must not be "fixed" by widening the schema ad hoc.
Readiness derives the command and source hash independently, so stale, duplicate, spoofed, co-tampered, unsafe, or source-drifted hook files fail closed.
Provisioning also sets completed onboarding and project trust for every canonical registered project; a linked worktree receives its matching active-root trust only immediately before execution.
Codex launches require an exact current-version profile hook set derived from the declared hook source plus Agent Fleet SessionStart, disable `plugins` and `plugin_sharing`, and apply trust only to the validated active root.
Every provisioned profile requires a directly configured non-symlink provider executable and records its opened regular-file identity, size, mode, modification time, and SHA-256 digest.
Selection, doctor, and the final managed/login/resume argv build recompute that authoritative opened-object identity and refuse path replacement or in-place binary drift until locked reprovisioning updates the marker.
Provider-reported version text is diagnostic only and is deliberately not an integrity authority.
The only pre-provision provider execution is the declared base-home identity anchor probe, which reopens and verifies the exact configured non-symlink regular executable immediately before Quota AXI or auth uses it.
Managed launches refuse active-root provider control files, including Claude project settings, Codex project config or hooks, and `.mcp.json`, while continuing to allow instruction files such as `CLAUDE.md` and `AGENTS.md`.

Task resume is fail-closed: it requires the recorded provider session and
reuses that session's exact profile. The new-task quota reserve does not block
recovery of an existing conversation, but disabled, unprovisioned, cooled-down,
or capacity-exhausted profiles still do.
Each accepted same-binding SessionStart advances the mapping's schema-2
`session_event_seq` under the state lock. Resume freshness compares only that
monotonic sequence, never `updated_at`. Legacy schema-1 mappings remain readable
with virtual sequence zero and migrate atomically on their next same-binding
SessionStart; a changed binding fails before any migration write.

Orchestrators that create a terminal endpoint before launching its command use
`lease recover` for an atomic, below-reserve-safe recovery reservation, then
launch `resume --task` inside the endpoint. Recovery refuses when the task still
has a live worker lease.

TOON is the default structured output for agent-facing inspection. Use
`--format json` for shell parsing and `--format human` for a simple terminal
view.

## Selection policy

`quota refresh` invokes `quota-axi` inside each profile environment and stores
only normalized status, an opaque provider-identity fingerprint when available,
and percentage windows. Every real selection obtains a same-attempt
source-before/quota/source-after proof for every enabled worker of each scoped
provider, including workers outside the requested pool. Cached quota is never
identity authority. `auth_required`, `rate_limited`, provider errors, duplicate
identities, missing remote verification, and expired verification are hard
blocks. A cached response whose live probe says sign-in is required is also a
hard block; cached percentages can never hide revoked credentials.

When fresh quota exists, Agent Fleet selects the highest safe headroom after reserve and active-lease penalties.
A fresh profile at or below its reserve is never selected for new work.
Stale or unavailable quota remains visible for diagnosis but is never routeable.

`choose --dry-run`, `profile status`, and `pool status` obtain a read-only same-attempt remote proof bracketed by live credential-source attestations.
That successful remote proof is the routeability authentication result; these hot paths do not launch a second provider `auth status` subprocess against the same isolated credentials.
`doctor` retains its direct provider-auth diagnostic as a separate explicit health check.
FirstMate gives each live-proof `pool status` call the selection-class timeout (120 seconds by default), rather than the five-second ordinary control-plane budget.
They advertise a profile as eligible, or a provider pool as available, only when that fresh proof matches the profile's durable provider identity bundle.
Missing bundles, changed sources, remote-identity mismatches, and incomplete same-provider proof sets surface as explicit non-routeable diagnostics.
FirstMate accepts only non-degraded `selection_mode=quota` pool summaries.
Advisory fallback still carries the ordered pool into enforced spawn, where a real fresh lease is mandatory before any provider process can launch.

```sh
agent-fleet quota refresh --all
agent-fleet quota show --all
agent-fleet profile verify --all --allow-keychain-prompt
agent-fleet doctor
agent-fleet doctor --workspace ~/firstmate --project /absolute/path/to/task-worktree
```

`profile verify --all` remotely rechecks every worker profile while all worker profiles remain disabled.
Enable each verified worker explicitly afterward; each enable again requires fresh same-attempt proof for the target and every already-enabled same-provider worker before its single registry mutation.
Verification and routing activation are deliberately separate phases.
On macOS, `--allow-keychain-prompt` is the explicit one-time Claude Keychain grant; choose **Always Allow** so later automatic checks stay non-interactive.
Bare `enable` never requests Keychain access and fails closed when verification is unavailable.
The grant is bound to the canonical unsuffixed `Claude Code-credentials`
service, the passwd-derived Keychain account, bounded non-secret live item
metadata, and the exact hash-pinned Quota wrapper, Node runtime, and release
tree. Ordinary selection invokes `/usr/bin/security` with the exact service and
account, closed stdin, a closed environment, and no `-g`/`-w`; only an unchanged
`0600` single-link `granted\n` marker plus a matching Fleet contract is copied
into the disposable identity shadow. The normalized Quota release then uses
that same exact service/account for its value read. A missing, linked, malformed,
replaced, or stale marker/item/runtime blocks before Quota or a browser can run.
Because Keychain ACL approval is enforced by macOS, unattended reads still rely
on the operator's prior **Always Allow** choice; timeouts, denial, or the
unavoidable same-uid replacement race fail closed and never authorize routing.

`doctor` verifies private profile homes, fresh remote identity proof for enabled workers, the Agent Fleet SessionStart hook, current Herdr session-identity hooks, inherited workflow hooks/assets, provider auth state, trusted-project configuration, and pinned binaries.
Non-worker reserve profiles are never provisioned, remotely probed, or routed; their status is the zero-touch `external-reserve` classification with no quota payload.
`--workspace` checks Firstmate's Claude and Codex supervision hooks, while `--project` independently checks provider onboarding, registered-project, profile-hook, plugin, and project-hook readiness without changing either location.

## Isolation and shared workflow assets

Claude profiles set `CLAUDE_CONFIG_DIR`; Codex profiles set `CODEX_HOME` and
`CODEX_SQLITE_HOME` and force file-backed credentials inside that home. Homes
and state are mode 0700; registry, lease, quota, and session files are mode
0600. Before every provider subprocess, Agent Fleet scrubs ambient
`ANTHROPIC_*`, `CLAUDE_*`, `OPENAI_*`, and `CODEX_*` variables, then sets only
the managed profile-home and task/workspace variables it owns. Every provider
control and worker environment also pins `USER` and `LOGNAME` to the current
passwd identity; Claude's profile-scoped Keychain account therefore cannot be
redirected by an ambient shell or Desktop-app login identity.

The provider registry can declare a base home, hook source, trusted Git projects, and allowlisted shared entries.
Initial profiles may share only explicitly allowlisted account-neutral workflow
assets. Managed plugin directories are forbidden:

- Claude: declared instruction/skill assets and closed hook definitions.
- Codex: declared instruction/skill/rule assets and closed hook definitions.

Auth files, sessions, histories, logs, caches, databases, and provider state are
never shared.

File-backed worker credentials are snapshot-attested before and after each live
identity proof, including owner, mode, link count, inode metadata, ctime/mtime,
size, and content digest.  The default/Desktop identity proof never runs a
provider against the real default home: Agent Fleet copies one verified
credential snapshot into a private, crash-recoverable shadow and proves it
there.  Owner journals are durably published before credential bytes; startup
recovers only dead, inode-pinned shadows and preserves live, foreign, linked,
or otherwise ambiguous entries for inspection.

The remaining boundary is the Unix same-uid threat model.  A hostile process
already running as the Fleet owner can still race a user-owned credential path
after its final attestation and before the provider opens it; portable process
launch has no `fexecve` equivalent for an arbitrary provider data file.  Normal
Desktop activity is outside each worker's private `0700` home and cannot cause
that race.  Any observed replacement, ambiguous source set, duplicate identity,
or failed post-proof attestation is fail-closed, and the cutover audit requires
the identity-shadow directory to be empty after verification.

## State

Defaults:

- Registry: `~/.config/agent-fleet/accounts.toml`
- Profile homes: paths recorded in the registry, under `~/.local/share/agent-fleet/accounts/<provider>/` by default
- Leases, normalized quota, and session mappings:
  `~/.local/state/agent-fleet`
- Neutral provider runtimes: `~/.local/libexec/agent-fleet/runtime`
- Hash-pinned profile-aware quota reader: the exact regular `node_modules/quota-axi/dist/bin/quota-axi.js` file inside one immutable release.
- Hash-pinned Quota interpreter: an exact regular standalone Node executable stored inside that same immutable release and invoked directly before the verified JavaScript path.

The current release layout stores those files at `~/.local/libexec/agent-fleet/quota-axi/releases/0.1.7-9f2dde87-sealed/node_modules/quota-axi/dist/bin/quota-axi.js` and `~/.local/libexec/agent-fleet/quota-axi/releases/0.1.7-9f2dde87-sealed/runtime/node`.

`agent-fleet init` may resolve a caller-supplied convenience symlink once, but the generated registry stores only the two resolved non-symlink release paths and their SHA-256 digests.

Registries missing any hash-pinned Quota wrapper, Node runtime, or release-tree provenance are rejected; runtime loading performs no legacy migration.

Moving `current`, npm `.bin`, and shebang/PATH execution are rejected.

Runtime drift blocks selection and quota refresh, and Doctor reports the failed pin; inventory and worker-disable operations remain available so an operator can fail safe without executing Quota.
Registry loading, doctor, and every quota probe refuse a moved symlink, replaced release, or digest drift.

`AGENT_FLEET_CONFIG`, `AGENT_FLEET_STATE_DIR`, and `AGENT_FLEET_SHARE_DIR` redirect the registry, state, and share/profile-home defaults.
The init-time executable overrides documented under "Initial setup" set the three generated binary paths; afterward, the registry owns those values.

## Development and releases

The locked test, lint, build, versioning, tagging, and installation verification
procedure lives in [RELEASING.md](RELEASING.md).
