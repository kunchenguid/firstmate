# Bot Claim Verification

## Bot Review Verification Traps

When a bot or pasted review cites a code fact, verify the fact against the
current branch before editing:

- **Import/export claims:** Check the exact import path used by the changed file.
  A symbol may be missing from an internal submodule but correctly exported by the
  public barrel the tests or runtime actually import.
- **Line numbers:** Treat bot line references as approximate after any follow-up
  push or local edit. Re-locate the symbol or block with `rg` before patching.
- **Ordering claims:** If the concern is about rule precedence, add or run a
  direct precedence test that would fail under the wrong ordering; comments alone
  are not enough.
- **Disproved findings:** Do not change unrelated code to satisfy a false claim.
  Keep the finding in the closure ledger with the source or test evidence that
  disproves it.
- **Cache/state claims:** Test both relevant state orders when the behavior
  depends on cache priming, singleton state, or prior calls.

## Automated Security Finding Verification

This is a repository-agnostic verification checklist. Technology names and
paths in the examples below are illustrative only: apply an example only when
the reviewed repository actually uses that API, validator, runtime, or file
layout, and otherwise translate the same origin-to-sink question to the
repository's language and framework. No example creates a dependency on the
opencode-swarm tree.

Automated security bots can produce CRITICAL or HIGH false positives. Before
acting on any bot security finding, perform these source-level checks:

1. **`child_process.exec` vs `RegExp.exec`**: SAST rules pattern-match on
   `.exec(` and cannot distinguish `child_process.exec(userInput)` (real
   injection risk) from `/^pattern$/.exec(str)` (safe regex test). Read the
   actual line to determine which `.exec` is called.

2. **Schema validation already present**: Bots may flag "missing type
   validation" without checking the Zod schema. Search for the field name in
   `src/config/schema.ts` — `z.number().int()`, `z.string().min()`, etc. are
   runtime validators that run before the code path the bot reviewed.

3. **`Object.assign` mutation claims**: Bots may claim `Object.assign` mutates
   the source object. Check whether the call is `Object.assign(target, source)`
   (mutates target) vs `Object.assign({}, source)` or a manual copy loop into a
   new `{}` (creates a new object, source is safe). Read the actual assignment.

4. **Path containment for system-generated paths**: Bots may flag "path
   traversal" on file paths. Check whether the path is user-controlled (real
   risk) or system-generated from `provisionWorktree`, `mkdtempSync`, or
   similar (no user input reaches the path). Trace the variable's origin.

5. **Value validation vs key validation**: Bots may suggest validating env var
   *values* for shell injection characters. Check whether the value is passed
   through a sandbox executor that escapes arguments (e.g., `wrapCommand`
   which returns a shell-quoted / `psStringEscape`-escaped string for the
   `bunSpawn` array-form argv to consume). Value validation would break
   legitimate env vars (PATH with `;`, URLs with `$`); escaping is the
   sandbox's job — see `engineering-conventions` § "Sandbox env overrides"
   for the full escape contract.

6. **Deduplication for independent resources**: Bots may suggest deduplicating
   cache redirects or env var entries. Check whether the entries map to
   independent keys (different env var names) — independent keys cannot
   "collide" and deduplication is nonsensical.

**Rule:** For any bot finding rated CRITICAL or HIGH, read the actual source
line AND its surrounding context (parent function, schema definition, type
annotations) before accepting the finding. If the finding is disproved, record
it in the closure ledger with the specific source evidence that disproves it.
