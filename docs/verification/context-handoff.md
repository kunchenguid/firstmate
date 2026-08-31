# Curated context handoff verification

This record supports the current default-off handoff guarantees in [`context-handoff.md`](../context-handoff.md).
It records active repeatable evidence rather than an activation or a claim about the real Vault.

## Version and source evidence

Verified on 2026-08-31 against Pi 0.84.3 and Claude Code 2.1.251.
`pi --version` returned `0.84.3`.
`claude --version` returned `2.1.251 (Claude Code)`.
The installed Pi README SHA-256 was `80d08cf6a947f288d62da22d02f73b75636082cd733bd797ab89ae052d2582b1`.
The installed Pi compaction documentation SHA-256 was `43166749858e6292c85905df4f0f9f189c487a384ae17ddcbbd99053943d62ef`.
The installed Pi extension documentation SHA-256 was `a174aa5d0ac91520cd5929753ff520f4aefe2cdc3719e91f8b06b5f198a10be6`.
The installed Pi `dist/core/extensions/types.d.ts` declared `session_before_compact`, `session_compact`, and `session_compact_failed` with reasons `manual`, `threshold`, and `overflow`.
The installed Pi `dist/core/agent-session.js` showed that cancellation from `session_before_compact` emits the failed event and prevents both default summarization and the saved compaction entry.
The same source showed that `session_compact` is emitted only after the compaction entry is appended, while the failed event carries abort, error, retry, reason, and extension attribution.
The installed Claude executable SHA-256 was `fd5f10ff0eb58daec04900466b143ea98aab50abf208a422bc008eaec13f61f7`.
The installed Claude executable strings contained `PreCompact`, `PostCompact`, `compact_summary`, `Compaction blocked by PreCompact hook`, and the current `hookSpecificOutput.permissionDecision` fields.

The installed Pi and Claude source evidence was reproduced with these bounded read-only commands and exact paths:

```sh
pi_root=/var/home/sreazy/.local/share/node-v24.19.0/lib/node_modules/@earendil-works/pi-coding-agent
claude_bin=/var/home/sreazy/.var/app/md.obsidian.Obsidian/data/claude/versions/2.1.251
pi --version
claude --version
sha256sum "$pi_root/README.md" "$pi_root/docs/compaction.md" "$pi_root/docs/extensions.md" "$claude_bin"
rg --no-filename -o 'session_before_compact|session_compact_failed|session_compact|manual|threshold|overflow' "$pi_root/dist/core/extensions/types.d.ts" "$pi_root/dist/core/agent-session.js" | sort -u
strings "$claude_bin" | rg -o 'PreCompact|PostCompact|compact_summary|Compaction blocked by PreCompact hook|hookSpecificOutput|permissionDecision' | sort -u
```

The version and hash output was:

```text
0.84.3
2.1.251 (Claude Code)
80d08cf6a947f288d62da22d02f73b75636082cd733bd797ab89ae052d2582b1  /var/home/sreazy/.local/share/node-v24.19.0/lib/node_modules/@earendil-works/pi-coding-agent/README.md
43166749858e6292c85905df4f0f9f189c487a384ae17ddcbbd99053943d62ef  /var/home/sreazy/.local/share/node-v24.19.0/lib/node_modules/@earendil-works/pi-coding-agent/docs/compaction.md
a174aa5d0ac91520cd5929753ff520f4aefe2cdc3719e91f8b06b5f198a10be6  /var/home/sreazy/.local/share/node-v24.19.0/lib/node_modules/@earendil-works/pi-coding-agent/docs/extensions.md
fd5f10ff0eb58daec04900466b143ea98aab50abf208a422bc008eaec13f61f7  /var/home/sreazy/.var/app/md.obsidian.Obsidian/data/claude/versions/2.1.251
```

The normalized Pi source output was:

```text
manual
overflow
session_before_compact
session_compact
session_compact_failed
threshold
```

The installed Pi cancellation path was also executed without a model call. This bounded probe invokes the installed automatic-compaction method with a valid synthetic branch, makes the pre-compaction extension cancel, and installs throwing sentinels on summarization and compaction persistence:

```sh
pi_root=/var/home/sreazy/.local/share/node-v24.19.0/lib/node_modules/@earendil-works/pi-coding-agent
PI_ROOT="$pi_root" node --input-type=module <<'EOF'
import { pathToFileURL } from "node:url";
const { AgentSession } = await import(pathToFileURL(`${process.env.PI_ROOT}/dist/core/agent-session.js`));
const events = [];
const entry = (id, parentId, text) => ({
  type: "message",
  id,
  parentId,
  timestamp: "2026-08-30T20:00:00.000Z",
  message: { role: "user", content: text, timestamp: 1788120000000 },
});
const branch = [entry("old", null, "old ".repeat(5000)), entry("recent", "old", "recent")];
const runner = {
  hasHandlers: () => true,
  async emit(event) {
    events.push(`extension:${event.type}:${event.reason}`);
    return event.type === "session_before_compact" ? { cancel: true } : undefined;
  },
};
const probe = {
  model: { provider: "synthetic" },
  settingsManager: { getCompactionSettings: () => ({ keepRecentTokens: 1 }) },
  sessionManager: {
    getBranch: () => branch,
    appendCompaction: () => { throw new Error("cancelled compaction persisted"); },
  },
  _extensionRunner: runner,
  _getSummarizationRequestAuth: async () => ({ model: {}, apiKey: undefined, headers: undefined, env: undefined }),
  _runDefaultCompaction: async () => { throw new Error("cancelled compaction summarized"); },
  _emit: event => events.push(`public:${event.type}:${event.reason}:aborted=${event.aborted ?? "unset"}`),
  _emitSessionCompactFailed: AgentSession.prototype._emitSessionCompactFailed,
};
const continued = await AgentSession.prototype._runAutoCompaction.call(probe, "threshold", false);
console.log([...events, `continued=${continued}`].join("\n"));
EOF
```

Its exact output was:

```text
public:compaction_start:threshold:aborted=unset
extension:session_before_compact:threshold
public:compaction_end:threshold:aborted=true
extension:session_compact_failed:threshold
continued=false
```

The installed Pi success path was then executed with an extension-supplied synthetic compaction, so no summarizer or model was reachable. The probe records the persistence call and observes that state from the public success event:

```sh
FM_CONTEXT_HANDOFF_PI_SUCCESS_PROBE_ONLY=1 tests/fm-context-handoff.test.sh
```

Its exact output was:

```text
public:compaction_start:threshold:aborted=unset
extension:session_before_compact:threshold
persistence:appendCompaction
extension:session_compact:persisted=true
public:compaction_end:threshold:aborted=false
continued=false
ok - installed Pi persistence-before-success order
```

The normalized Claude strings output was:

```text
Compaction blocked by PreCompact hook
PostCompact
PreCompact
compact_summary
hookSpecificOutput
permissionDecision
```

The official Claude Markdown pages were fetched with `Accept: text/markdown` and matched the audit's recorded SHA-256 values exactly:

```sh
evidence_root=$(mktemp -d)
for page in hooks hooks-guide context-window how-claude-code-works memory interactive-mode commands sessions plugins-reference plugin-marketplaces; do
  curl --fail --silent --show-error --location --max-time 30 -H 'Accept: text/markdown' "https://code.claude.com/docs/en/$page" -o "$evidence_root/$page.md"
  sha256sum "$evidence_root/$page.md"
done
```

The exact normalized command output is the page-to-hash table below.

| Page | SHA-256 |
| --- | --- |
| `hooks` | `70e0b0e2e1cb2b2866580e8417467cc74c732dd3b21f1a519464ba190489578e` |
| `hooks-guide` | `2c17b318c624031fdeea7ad0cfbd882f7cdbfe7385e9c445802573703ca9411e` |
| `context-window` | `923207d0127294f1123edc3953bd908dfe0276b42820ccda37ada61fd3728018` |
| `how-claude-code-works` | `30758f2ce7d306277e3587329033d17656993b4643ae83f69308d02ace197dde` |
| `memory` | `8499a90d02435f460c729f3dc789072dc9224d3efac7cffdd507dafe76f20303` |
| `interactive-mode` | `3fd6c73e07c4a639e1383021f741a4d33b7f2d5a915f489d49d9f64799ddfb3e` |
| `commands` | `6bbc0ba8e5183e113a018fa896b182fcdb04f96dce8d3d792439821a43b1c6e9` |
| `sessions` | `ced11b40a9dc6f77f207d66f93ee13f2066c8f689a318813d97968228436a607` |
| `plugins-reference` | `a0bc8cc75ce7b6a02446f7c1abb805a63fb72b0386471a44c476957bebdb5253` |
| `plugin-marketplaces` | `ed1d6ff6bd440957c09f3a2ba937ff6901b83e9cdfee9cfc8b73e5573ad2665e` |

Those pages establish that Claude `PreCompact` receives `trigger` and optional manual instructions, can block with exit 2 or `decision: block`, and must not rely on hook timeout as enforcement.
They establish that `PostCompact` receives the generated `compact_summary` only after success and has no decision control.
They establish that `SessionStart source=compact` runs after compaction and may add bounded context, while `PreToolUse` denial remains effective even under bypass permission mode when the hook itself runs successfully.
They also establish `${CLAUDE_PLUGIN_ROOT}` expansion for plugin hooks and bundled MCP servers.

The installed clean `claude-obsidian` transaction entrypoint SHA-256 was `34f3030da4a0ebc223a5dfba7f7180638d08dffa3d044be33fa72234866900c2`.
The installed clean transaction module SHA-256 was `e007e3b7d08f72eabc4a95c7031fb596c201562432cf37cc649136b02b223de2`.
The cache and clean checkout had the same two hashes.
The exact module was used against synthetic Vaults for inspect, apply, conflict, result, journal, hash, mode, lock-removal, idempotent replay, and apply-complete-before-ack evidence.
The byte-identified fallback fixture is [`context-handoff-transaction-core.sh`](../../tests/fixtures/context-handoff-transaction-core.sh) and covers the same public CLI shape when the installed product is unavailable in portable CI.

The installed transaction source identity was reproduced with:

```sh
transaction_root=/var/home/sreazy/claude-obsidian
sha256sum "$transaction_root/scripts/claude-obsidian.py" "$transaction_root/claude_obsidian/transaction.py"
```

It produced:

```text
34f3030da4a0ebc223a5dfba7f7180638d08dffa3d044be33fa72234866900c2  /var/home/sreazy/claude-obsidian/scripts/claude-obsidian.py
e007e3b7d08f72eabc4a95c7031fb596c201562432cf37cc649136b02b223de2  /var/home/sreazy/claude-obsidian/claude_obsidian/transaction.py
```

## Deterministic focused suite

Command:

```sh
tests/fm-context-handoff.test.sh
```

Result:

```text
ok - required evidence prerequisite exit status
ok - sensitive candidate and Save content rejection
ok - foreign candidate ownership isolation
ok - candidate identity binds its exact source session
ok - durable receipt for unhealthy seal-time bindings
ok - durable compaction attempt result replay
ok - fail-closed Claude generation and probe budget margin
ok - SessionStart announces only consumable records
ok - empty register stays a no-op under an unhealthy binding
ok - missing durable records fail with bounded classification
ok - invalid compaction attempt journals are retired
ok - single-note automatic Save boundary
ok - queue-first orphan recovery
ok - invalid candidate failures are durably receipted
ok - locked registration capability snapshot
ok - bounded compaction backpressure and drain
ok - deterministic byte-bounded envelope draining
ok - replacement-monotonic Claude session binding
ok - fail-closed Claude PreCompact endpoint binding
ok - immutable lifecycle and serialized authority snapshots
ok - exit-75 Save authority revocation
ok - exact bundled MCP tool allowlist
ok - bounded transports and fail-closed delivery
ok - durable private state directory creation
ok - serialized durable state initialization
ok - model-free Pi lifecycle and fail-closed adapter validation
public:compaction_start:threshold:aborted=unset
extension:session_before_compact:threshold
persistence:appendCompaction
extension:session_compact:persisted=true
public:compaction_end:threshold:aborted=false
continued=false
ok - installed Pi persistence-before-success order
ok - completed Save recovery before source validation
ok - registration lifecycle and multi-record retry recovery
ok - quarantine, disable, and disposition recovery
ok - transaction apply replay and rollback recovery
ok - orphan apply remains behind durable execution authority
ok - Claude lifecycle and model-free plugin discovery
```

The suite uses isolated temporary Firstmate homes, source roots, Vaults, Herdr adapters, Pi extension APIs, Claude hook payloads, MCP requests, and transaction state.
The self-contained Bash suite executes the public CLI, Claude hook, MCP server, Pi extension, and transaction fixture against isolated synthetic homes and Vaults.
It covers required-gate prerequisite exit status, non-cancelling empty registers under an unhealthy binding, bounded classification of missing durable records, retirement of invalid compaction attempt journals, case-exact bundled MCP allowlisting, category-sensitive rejection after eligibility authorization, session-bound candidate identity, durable receipts for unhealthy seal-time bindings, crash-durable compaction attempt replay, exact live-generation revalidation at the sealing boundary with a probe budget materially shorter than the PreCompact hook timeout, consumable-only SessionStart announcements, exact one-create-plus-coupled Save authority, queue-before-claim crash recovery, corrupt-candidate receipts, locked and generation-monotonic process capability, deterministic byte-bounded subsets, retry backpressure and draining, fail-closed Claude endpoint binding, atomic terminal compaction recovery, exit-75 approval revocation and fresh inspect, exact MCP and shell guard confinement, bounded MCP and subprocess transport, fail-closed delivery, serialized durable state initialization, complete Pi lifecycle failure handling, completed-Save recovery before mutable-source validation, registration retry recovery, quarantine, disable and re-enable, disposition crash recovery, complete reviewed transaction-path verification, durable orphan-apply execution claims, transaction replay and rollback, and model-free Claude plugin discovery.
No test reads or mutates the real Vault, a live Claude session, a live Herdr process, credentials, auth state, transcripts, or provider data.
No test invokes a model.

The exact installed transaction-core gate was run separately so a portable fallback cannot satisfy the installed-byte claim:

```sh
FM_CONTEXT_HANDOFF_REQUIRE_INSTALLED_CORE=1 tests/fm-context-handoff.test.sh
```

Its distinguishing final line was:

```text
ok - exact-installed-transaction-core core=34f3030da4a0ebc223a5dfba7f7180638d08dffa3d044be33fa72234866900c2 module=e007e3b7d08f72eabc4a95c7031fb596c201562432cf37cc649136b02b223de2
```

## Fresh-process model-free smokes

The Pi discovery command was:

```sh
evidence_root=$(mktemp -d)
mkdir -p "$evidence_root/home" "$evidence_root/fm-home" "$evidence_root/pi"
set +e
HOME="$evidence_root/home" FM_HOME="$evidence_root/fm-home" PI_CODING_AGENT_DIR="$evidence_root/pi" PI_OFFLINE=1 pi --offline --no-session --no-context-files --no-skills --no-prompt-templates --no-extensions -e "$PWD/.pi/extensions/fm-primary-turnend-guard.ts" --list-models >"$evidence_root/pi.stdout" 2>"$evidence_root/pi.stderr"
status=$?
set -e
printf 'exit=%s\nstdout-lines=%s\nstdout-sha256=%s\nstderr-bytes=%s\n' "$status" "$(wc -l <"$evidence_root/pi.stdout" | tr -d ' ')" "$(sha256sum "$evidence_root/pi.stdout" | cut -d' ' -f1)" "$(wc -c <"$evidence_root/pi.stderr" | tr -d ' ')"
```

It produced this bounded exact result:

```text
exit=0
stdout-lines=3
stdout-sha256=8cda3d37a2a0d31ff1755f3ee4361ed9ea808cc7193ec88c89d170dd2339225f
stderr-bytes=0
```

The Claude plugin validation command was:

```sh
evidence_root=$(mktemp -d)
mkdir -p "$evidence_root/home"
set +e
HOME="$evidence_root/home" claude plugin validate --strict "$PWD/integrations/claude-context-handoff" >"$evidence_root/claude-plugin.out" 2>&1
status=$?
set -e
sed "s|$PWD|<worktree>|g" "$evidence_root/claude-plugin.out"
printf 'exit=%s\n' "$status"
```

It exited 0 with:

```text
Validating plugin manifest: <worktree>/integrations/claude-context-handoff/.claude-plugin/plugin.json

✔ Validation passed
exit=0
```

## Residual limits

A Claude command hook can be absent, fail to start, or time out, and official Claude behavior then lets most tool calls continue through normal permission flow.
The guard is therefore defense in depth, while the byte-pinned transaction core remains the mutation, confinement, expected-hash, lock, journal, and recovery authority.
Exact recipient notification proves the configured Herdr and Claude session identity at send time but cannot prove future provider availability.
Final duplicate and relevance decisions remain Claude curation judgments after activation and are not replaced by a deterministic classifier.
No real-Vault activation, real record delivery, live process reconciliation, or standing-authority exercise is evidenced here.
