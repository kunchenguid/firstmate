# Curated context handoff verification

This record supports the current default-off handoff guarantees in [`context-handoff.md`](../context-handoff.md).
It records active repeatable evidence rather than an activation or a claim about the real Vault.

## Version and source evidence

Verified on 2026-08-30 against Pi 0.84.3 and Claude Code 2.1.251.
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

The official Claude Markdown pages were fetched with `Accept: text/markdown` and matched the audit's recorded SHA-256 values exactly:

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
The byte-identified fallback fixture is [`context-handoff-transaction-core.py`](../../tests/fixtures/context-handoff-transaction-core.py) and covers the same public CLI shape when the installed product is unavailable in portable CI.

## Deterministic focused suite

Command:

```sh
tests/fm-context-handoff.test.sh
```

Result:

```text
ok - test_registration_sealing_and_rejections
ok - test_caps_atomicity_and_failure_receipts
ok - test_exact_delivery_and_no_launch
ok - test_claude_hooks_guard_and_compaction
ok - test_transaction_apply_replay_conflict_and_ack
ok - test_payload_mismatch_disable_and_dispositions
ok - test_pi_extension_handlers_and_model_free_discovery
```

The suite uses isolated temporary Firstmate homes, source roots, Vaults, Herdr adapters, Pi extension APIs, Claude hook payloads, MCP requests, and transaction state.
It covers positive and negative registration, raw-content and sensitive rejection, provider refusal, exact source hashes, source path and symlink refusal, state/Vault overlap refusal, item and byte caps, mode 0600, canonical IDs and hashes, empty registers, fsync failure, durable failure receipts, crash after envelope publication, manual and automatic Claude compaction, Pi threshold and overflow outcomes, compaction failure and retry, exact-recipient identity, busy and unavailable delivery, constant-content notification, no launch or restart, replay, payload mismatch quarantine, traversal and symlink refusal, exact guard denial and allow, duplicate disposition, expected-hash conflict, held lock, rolled-back transaction retry, apply-complete-before-ack healing, disable, and re-enable.
No test reads or mutates the real Vault, a live Claude session, a live Herdr process, credentials, auth state, transcripts, or provider data.
No test invokes a model.

## Fresh-process model-free smokes

The Pi discovery command was run with an isolated HOME and FM_HOME, offline mode, no session, no context files, no skills, no prompt templates, no discovered extensions, and only the tracked primary extension passed with `-e`.
The command exited 0, printed three model-catalog header lines, printed no stderr, and made no provider request.

The Claude plugin validation command was:

```sh
HOME=<isolated-home> claude plugin validate integrations/claude-context-handoff
```

It exited 0 with:

```text
Validating plugin manifest: <worktree>/integrations/claude-context-handoff/.claude-plugin/plugin.json

✔ Validation passed
```

The Claude lifecycle discovery command used an isolated HOME, FM_HOME, empty synthetic Vault, empty settings file, disabled nonessential traffic, `--plugin-dir integrations/claude-context-handoff`, and `--init-only`.
It exited 0 with zero stdout bytes and zero stderr bytes.
It loaded the real plugin lifecycle without a prompt, model, provider call, global configuration write, or real Vault access.

## Residual limits

A Claude command hook can be absent, fail to start, or time out, and official Claude behavior then lets most tool calls continue through normal permission flow.
The guard is therefore defense in depth, while the byte-pinned transaction core remains the mutation, confinement, expected-hash, lock, journal, and recovery authority.
Exact recipient notification proves the configured Herdr and Claude session identity at send time but cannot prove future provider availability.
Final duplicate and relevance decisions remain Claude curation judgments after activation and are not replaced by a deterministic classifier.
No real-Vault activation, real record delivery, live process reconciliation, or standing-authority exercise is evidenced here.
