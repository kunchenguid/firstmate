# User skill layout verification

[`bin/fm-user-skill-sync.sh`](../../bin/fm-user-skill-sync.sh) owns the operating contract, and [`docs/configuration.md`](../configuration.md#user-skill-layout) owns concise operator usage.
This record owns the current empirical verification boundary.

## Isolated filesystem verification

On 2026-08-20, the focused temporary-home suite exercised canonicalization, relative Claude and Codex links, verified whole-root link conversion, duplicate removal, conflict refusal, `.system` preservation, default dry-run behavior, idempotence, unsafe-entry refusal, and registered-remote command construction.

Command:

```sh
tests/fm-user-skill-sync.test.sh
```

Output:

```text
ok - real user skill migrates to canonical content with relative harness links
ok - verified duplicate removal is idempotent
ok - byte-different skill trees refuse before mutation
ok - dry-run is the mutation-free default
ok - Codex vendor-managed .system is preserved
ok - broken links and unexpected entries refuse conservatively
ok - verified whole-root canonical links converge without touching their target
ok - isolated Codex per-skill link resolves and exposes SKILL.md
ok - remote invocation binds the registered host and forwards explicit apply
```

The Codex probe creates one isolated skill under a temporary `CODEX_HOME`, verifies that its relative link resolves to the canonical tree, and reads `SKILL.md` through that link.
No live Codex process was started because doing so could create account configuration or session state in the captain's environment.
Codex discovery through a live authenticated process therefore remains unverified.
The operator command remains conservative: it defaults to a complete read-only plan, requires explicit `--apply`, refuses links it cannot prove target an existing canonical skill, and never inspects or changes `.system`.
