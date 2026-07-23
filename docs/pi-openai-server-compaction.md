# Pi OpenAI server compaction package

## Status and owned integration

This page owns firstmate's installation, security audit, data-flow, activation, validation, update, and rollback contract for `algal/pi-openai-server-compaction`.
The review date is 2026-07-22.
The reviewed and configured upstream revision is `c6d593087709e9481223dc6c6c2269b371b5e055`, whose commit date is 2026-07-17.
The upstream package calls itself experimental, and its benchmark supports only the stated fixture and model regime rather than a general claim that remote compaction is always better.
The upstream `LICENSE.md` and `package.json` both identify the package as MIT licensed.

The supported project-local declaration lives in `.pi/settings.json`.
It uses Pi's documented git package object form with an immutable commit ref and `"autoload": false`.
Pi installs missing trusted project packages beneath `.pi/git/`, but autoload false prevents any package resource from executing until it is explicitly enabled.
The generated clone, its `node_modules`, its generated `package-lock.json`, npm caches, and local Pi credential or trust files are ignored and must not be committed.

The inactive declaration is intentional because this machine's Homebrew Pi is 0.80.6, while upstream requires Pi `>=0.80.9 <0.81.0` and Node `>=22`.
No global Pi, Node, credential store, or live primary session was changed during installation or validation.
The captain approved an operator-installed temporary npm Pi 0.80.10 runtime for future firstmate sessions.
This task did not install it, change the running primary session, alter shell configuration, or change the global Pi selected by the current `PATH`.
The tracked `autoload` value remains false until that compatible runtime is installed and deliberately used.

## Conservative trial configuration

The project-local `.pi/openai-server-compaction.json` configures the future trial as follows.

- `enabled: true` enables the extension once the package itself is allowed to load.
- `includeAzure: false` keeps Azure OpenAI outside the trial.
- `thresholdRatio: 0.7` retains upstream's compaction threshold ratio.
- `compactThreshold: 0` leaves threshold calculation on the ratio instead of forcing a token count.
- `usePreviousResponseId: false` disables incremental response-ID continuation and makes direct OpenAI use Pi's HTTP Responses stream instead of the custom WebSocket path.
- `notify: true` makes request-feature activation visible in Pi's UI.

The supported families are direct `openai/*` Responses models and `openai-codex/*` Responses models.
The package does not affect Anthropic, Google, or the other firstmate harnesses, and the tracked `.pi` settings have no meaning to Claude, Codex, Grok, or OpenCode.
The current package config has no model allowlist within those two OpenAI families.

`usePreviousResponseId: false` does not disable `store: true` or `context_management` on direct OpenAI requests.
The reviewed source provides no setting that disables `store: true` while leaving the direct OpenAI integration active.
To avoid that storage behavior, keep the package autoload disabled, set the extension's `enabled` config to false, or use a different provider family.
Setting only `enabled: false` still loads the package and registers an OpenAI provider wrapper that delegates to Pi's built-in HTTP stream, so `autoload: false` is the stronger rollback.

## Data flow and request changes

### Direct `openai/*`

The extension registers an override for Pi's `openai` provider and handles only `openai-responses` models whose provider is `openai` and whose hostname is absent or exactly `api.openai.com`.
Before a supported provider request, it sets `store: true` when the model permits storage and adds `context_management` with the configured compaction threshold.
When `usePreviousResponseId` is true, it may also add `previous_response_id` and use `wss://api.openai.com/v1/responses`, falling back to Pi's HTTP Responses stream if the WebSocket path is unavailable.
The tracked trial keeps that option false, so the WebSocket and incremental continuation paths are inactive.

On compaction, the extension runs a portable Pi summary and a remote Responses compaction request in parallel.
The remote request posts the active conversation, system instructions, active tool schemas, reasoning and text settings, and a trailing `compaction_trigger` to the model's direct OpenAI Responses endpoint.
For the official direct provider that endpoint resolves to `https://api.openai.com/v1/responses`.
The compaction request itself sets `store: false`, but ordinary direct OpenAI turns still receive the separate `store: true` request mutation.

### `openai-codex/*`

The extension does not replace Pi's built-in OpenAI Codex transport.
It posts remote compaction requests to `https://chatgpt.com/backend-api/codex/responses`, adds Codex identity and beta headers, and extracts the ChatGPT account ID claim from the existing Codex token for the request header.
After a successful compaction it replaces the next compatible request history with reconstructed remote compaction history.
It does not use `previous_response_id` or the custom WebSocket transport for OpenAI Codex.

### Persistence and portability

The OpenAI response must contain exactly one opaque `compaction` item.
The extension stores that item, retained recent user messages, the provider and model key, and optional usage and cost metadata under `CompactionEntry.details.remoteCompaction` in Pi's local session JSONL.
The opaque artifact is not human-readable and remains provider-native.
The extension separately writes a readable Pi summary so normal context building, exports, other models, and no-extension recovery continue to work.
Remote replay filters trailing assistant turns by the compacted model key to avoid mixing other-model turns after resume or tree navigation.

The runtime also keeps response IDs, reconstructed remote history, request shape, and WebSocket managers in memory.
It clears or rebuilds that state on session start or reload, session switch, fork, tree navigation, compaction completion, model selection, and shutdown.
Pi's ordinary branch summary behavior remains in place because this package does not implement `session_before_tree`.

## Security audit

The audit read the complete upstream `README.md`, `ARCHITECTURE.md`, `VALIDATION.md`, `TESTPLAN.md`, `LICENSE.md`, `package.json`, every file under `src/`, `scripts/smoke.mjs`, and `tests/live/openai-compaction-rpc-live.ts` at the pinned revision.
It also read Pi's installed `docs/extensions.md`, `docs/packages.md`, and `docs/compaction.md` completely, plus the relevant custom compaction, provider, session, and session-format references.

| Area | Reviewed behavior and evidence | Residual risk |
| --- | --- | --- |
| Arbitrary command execution | No runtime file under `src/` imports `node:child_process`, invokes a shell, or registers a model-callable tool or command. The offline smoke script invokes `npm root -g`, and the live test spawns Pi, but neither file is declared as a runtime extension entrypoint. | Pi extensions execute JavaScript with the user's full permissions, so a future pinned revision must be reviewed before updating. |
| Filesystem access | `src/config.ts` reads the global and project JSON config files. `src/remote-compaction.ts` reads or creates `$CODEX_HOME/installation_id`, falling back to `~/.codex/installation_id`, to supply Codex identity headers. | A first direct OpenAI or Codex request can create that UUID file if it is absent. The extension does not otherwise enumerate or send repository files itself, but conversation tool results can already contain repository content. |
| Credentials | The compaction hook asks Pi's model registry for the selected model's API key and headers. Direct requests send the key as a bearer token; Codex requests also decode the token locally to extract the ChatGPT account ID. The reviewed code does not log credentials. | The extension receives live credentials in memory and forwards configured model headers. Compromise of the extension or its sole runtime dependency would inherit that access. |
| Outbound endpoints | The custom WebSocket endpoint is fixed at `wss://api.openai.com/v1/responses`. Remote compaction is restricted to direct OpenAI at `api.openai.com` or OpenAI Codex at `chatgpt.com`, with the exact path derived from the selected model's matching base URL. | OpenAI receives the system prompt, conversation context, tool schemas, and model settings during remote compaction. Ordinary direct turns also use server storage because of `store: true`. |
| Provider override | The factory calls `registerProvider("openai", { api: "openai-responses", streamSimple: ... })`. When disabled it delegates to Pi's built-in HTTP Responses stream; when enabled with response-ID continuation it can use the custom WebSocket stream. | A streaming compatibility bug can affect every direct official OpenAI Responses model while the package is loaded. The stronger rollback is package autoload false. |
| Request mutation | Direct OpenAI gets `store: true`, `context_management`, and optionally `previous_response_id`. OpenAI Codex gets reconstructed remote history only after compatible compaction. Azure response-ID support exists behind `includeAzure`, but remote compaction itself does not support Azure. | The package does not expose a direct-OpenAI storage opt-out, and the Azure code is explicitly not live-tested upstream. |
| Persistence | Opaque replacement history and usage are stored in session JSONL details. Portable summaries are also stored and sent through Pi's normal context path. | Session copies, backups, exports, or forensic tooling may retain the opaque provider artifacts even after the package is disabled. |
| Cleanup | Response IDs and sockets are released on replacement lifecycle events, model changes, and shutdown, and remote state is reconstructed from the active branch. | Abrupt process termination relies on OS socket cleanup, and an upstream logic defect could still replay stale compatible-model state. |
| Runtime dependencies | `package.json` has one production dependency, `ws` with range `^8.18.0`. The isolated install on 2026-07-22 resolved `ws@8.21.1` with integrity `sha512-+0NTnW77fFN/DjQi6k/Sq/Yvk4Sgajw7urW8V+asjXnRgDs9gyGkdb7EzgfhA4goXsRIZKE28fzIXBHEzhuiWw==`; its native acceleration peers were absent, and `npm audit --omit=dev` reported zero vulnerabilities. | Upstream commits no lockfile, so a pinned git revision does not fully pin the future `ws` resolution. This is the primary reproducibility gap and requires checking the generated lock and npm audit on every reinstall or update. |
| Install scripts | The upstream package declares no `preinstall`, `install`, `postinstall`, or `prepare` script. The installed `ws@8.21.1` package also declares no lifecycle install script. Pi runs `npm install` inside a git package clone and generated a local lockfile during validation. | A later `ws` release allowed by the range could change package contents or lifecycle metadata before installation, so the immutable upstream commit alone does not eliminate registry supply-chain risk. |

## Interaction with firstmate's Pi extensions

Firstmate's `.pi/extensions/fm-primary-pi-watch.ts` and `.pi/extensions/fm-primary-turnend-guard.ts` remain top-level project extensions and are independent of package filtering.
Changing this package's autoload state does not enable or disable either firstmate extension.
The package registers no tools or commands, so it does not collide with `fm_watch_arm_pi`, the watcher arm command, or the turn-end guard.
Its lifecycle handlers run alongside firstmate's handlers, while its shutdown cleanup is limited to in-memory continuation state and its own WebSocket sessions.

Pi reload and session replacement create a new extension runtime after `session_shutdown` and `session_start`.
The package follows those hooks by clearing old state and reconstructing only the current active branch's remote compaction details.
Model changes clear live response-ID and WebSocket state.
Fork and tree transitions clear state before navigation, then rebuild it from the resulting branch.

When the package is disabled, Pi's built-in `compact` function and default compaction setting remain available.
Pi's portable summary in any extension-produced compaction entry remains readable without the package, but opaque remote artifacts are ignored until a compatible extension runtime is loaded again.

## Reproducibility and validation evidence

The installed Pi documentation recommends `pi install -l` for project packages and stores a git source in `.pi/settings.json`.
The isolated compatibility probe used Pi 0.80.10 and Node 26.5.0, never the global Pi 0.80.6 runtime.

The exact installation probe was:

```sh
PI_CODING_AGENT_DIR="$isolated_agent" "$isolated_pi" install --approve -l \
  git:github.com/algal/pi-openai-server-compaction@c6d593087709e9481223dc6c6c2269b371b5e055
```

Pi produced a one-element string package list, checked out the exact detached commit, ran a production npm install, and reported one package installed with zero audit vulnerabilities.
That generated form would autoload the extension immediately, so the tracked settings use Pi's documented object form with `autoload: false` until a compatible primary runtime is approved.

The source and dependency audit used these commands on 2026-07-22, with both variables pointing to disposable task-local checkouts:

```sh
gh-axi repo clone algal/pi-openai-server-compaction "$audit_checkout"
git -C "$audit_checkout" checkout --detach c6d593087709e9481223dc6c6c2269b371b5e055
git -C "$audit_checkout" rev-parse HEAD
git -C "$audit_checkout" ls-tree -r --name-only HEAD
installed_package="$isolated_project/.pi/git/github.com/algal/pi-openai-server-compaction"
npm --prefix "$installed_package" ls --omit=dev --json
npm --prefix "$installed_package" audit --omit=dev
```

The tracked test additionally fixes the expected generated `ws@8.21.1` version and registry integrity so dependency drift fails validation and requires a fresh audit instead of passing silently.

The deterministic repository test is:

```sh
bin/fm-test-run.sh tests/fm-pi-openai-server-compaction.test.sh
```

It validates JSON syntax, the exact source pin, the disabled activation gate, the conservative provider config, ignored generated paths, and the absence of tracked package material or credentials.
It installs Pi 0.80.10 and the pinned package only in test temp directories, asserts the checked-out commit and production dependency shape, runs upstream's smoke suite with no provider call, loads the package and both existing firstmate Pi extensions under `--offline`, and proves Pi's normal compaction export and default setting remain available with package autoload disabled.
CI selects Node 22.19.0 for the portable serial lane so this test never depends on a runner's or captain's global Pi version.

No live OpenAI call was made for this integration.
A live test was not necessary for the minimum integration proof and would require using an existing credential against a mutable provider service.
If a future live check is approved, it must use a temporary workspace and session, a bounded synthetic conversation, and no firstmate history, repository content, tool output, credentials, or captain-private data.
Upstream's retained live and benchmark reports remain upstream evidence limited to their documented models, fixtures, and dates.

## Activation, verification, rollback, and update

Do not change the captain's global Pi installation without explicit approval.
The captain has approved the following operator path for a temporary Pi 0.80.10 runtime, but the task worker must not run it:

```sh
npm install -g --ignore-scripts @earendil-works/pi-coding-agent@0.80.10
~/.npm-global/bin/pi --version
cd /Users/cory/firstmate && ~/.npm-global/bin/pi
```

Invoke `~/.npm-global/bin/pi` explicitly for future firstmate sessions because the older Homebrew binary remains earlier on the current `PATH`.
Do not rewrite shell configuration, replace `/opt/homebrew/bin/pi`, mutate a running session, or auto-upgrade the npm runtime to Pi 0.81.x while the audited package declares `>=0.80.9 <0.81.0`.
Before changing either runtime, compare the candidate Pi version with the package requirement recorded in the pinned checkout:

```sh
brew info pi-coding-agent
jq -r '.engines.node, .peerDependencies["@earendil-works/pi-coding-agent"]' \
  .pi/git/github.com/algal/pi-openai-server-compaction/package.json
```

Once the approved Pi 0.80.10 runtime and Node `>=22` are available, change only the package object's `autoload` field in `.pi/settings.json` from false to true.
Restart Pi in the firstmate checkout or run `/reload` after the current live primary turn is safely complete.
The `notify: true` setting should show OpenAI compaction activation on the first affected request, including the exact active feature list.

Verification after activation should use a new temporary Pi session and a non-sensitive synthetic conversation.
For direct OpenAI, verify the activation notice and, only with explicit provider inspection, the `store: true` and `context_management` request fields.
For OpenAI Codex, verify the built-in transport still works and that remote history appears only after a successful compaction.
In either family, a successful remote compaction entry contains `details.remoteCompaction.implementation` equal to `responses_compaction_v2` and ends its replacement history with one opaque `compaction` item.

Rollback is one tracked change: set `autoload` back to false and restart or reload Pi.
This leaves firstmate's watcher and turn-end extensions loaded and returns supported models to Pi's normal transport and local compaction behavior.
Setting `enabled` to false is a softer diagnostic disable, while `--no-extensions` is an emergency process-level bypass that also removes firstmate's watcher and turn-end protection and should not be the routine rollback.
Removing the package declaration entirely is a separate uninstall choice and is not needed for rollback.

Homebrew should own Pi again only when `brew info pi-coding-agent` offers a version within the audited extension revision's declared Pi range and that extension revision supports the offered Homebrew version.
At that point, stop invoking the npm path, verify `/opt/homebrew/bin/pi` directly, and then remove the temporary npm installation:

```sh
/opt/homebrew/bin/pi --version
npm uninstall -g @earendil-works/pi-coding-agent
hash -r
command -v pi
pi --version
```

If the Homebrew version falls outside the pinned extension's declared range, leave package autoload false and do not remove the known-compatible npm runtime merely because a newer Homebrew release exists.

To update, first select a new immutable upstream commit and repeat the complete source, documentation, dependency, and license audit described above.
Run the isolated project install and repository test, record the newly generated `ws` version and integrity, and update this dated evidence.
Only then change the source SHA in `.pi/settings.json`.
Never run `pi update`, `pi install`, `/reload`, compaction, or the package's live test in the captain's active primary session or primary checkout as part of the update procedure.
