# Role-aware instruction-context verification

Audience: maintainer verification.

This record supports the active guarantee that a primary, second mate, and ordinary Firstmate-repository worker receive coherent role-specific instructions without paying for unrelated primary procedure in every system prompt.
Root [`AGENTS.md`](../../AGENTS.md) is the universal gateway, [`primary-runtime`](../../.agents/skills/primary-runtime/SKILL.md) is the primary and second-mate owner, and generated briefs own ordinary worker delivery.

## Measured generated contexts

The before measurement used commit `cf9511217d885cd2127d50993e672c2dfa0539cf`, which was equal to `origin/main` on 2026-08-03.
The after measurement used the role-aware implementation and Pi 0.83.0's real `DefaultResourceLoader`, `formatSkillsForPrompt`, and `buildSystemPrompt` with the seven built-in Firstmate tools.
Both trees were exported to equal-length checkout paths and loaded with an empty user-scope Pi agent directory, so the graded surface is exactly the repository's own `AGENTS.md` and `.agents/skills/` rather than any operator's ancestor context files or personal skills.
Both measurements generated ship, scout, and project-less second-mate instructions through `bin/fm-brief.sh` and used the executable output of `bin/fm-sessionstart-nudge.sh`.
Character counts measure generated model instructions rather than only tracked file bytes.

| Generated surface | Before | After | Saving |
| --- | ---: | ---: | ---: |
| Root repository instruction context | 62,128 | 8,416 | 53,712 (86.5%) |
| Skill index | 11,395 | 9,048 | 2,347 (20.6%) |
| Universal Pi system prompt | 75,418 | 19,359 | 56,059 (74.3%) |
| Primary after startup instruction and primary-runtime load | 75,540 | 46,153 | 29,387 (38.9%) |
| Ship worker system prompt plus generated brief | 81,656 | 26,073 | 55,583 (68.1%) |
| Scout worker system prompt plus generated brief | 78,948 | 23,354 | 55,594 (70.4%) |
| Second mate after generated charter and primary-runtime load | 80,912 | 51,984 | 28,928 (35.8%) |

The after skill index contains 21 repository-owned skills, including `primary-runtime` and `validation-supervision`, against 19 before.
The two runtime-load rows include the 1,672 characters a review round added to `primary-runtime` for the absent-file semantics and the coordination-internals never-edit boundary; the universal, ship, and scout surfaces are unaffected because none of them loads the runtime.
The generated root context remains below its 12,000-character regression budget, and the universal Pi system prompt remains below its 40,000-character regression budget.

Current deterministic command:

```sh
tests/fm-role-context.test.sh
```

Observed output on Pi 0.83.0:

```text
ok - role-aware startup wrapper orders the runtime owner before primary mutation
ok - generated role contexts: root=8416 system=20532 skills=21 ship=6863 scout=4140 second=6165
```

The startup-ordering assertion runs first because it needs no harness, so a runner without Pi's loader still proves it and skips only the generated-context half.

Pi embeds the absolute path of the repository context file, of every discovered skill, and of the working directory in each generated prompt.
`root=` and `skills=` are therefore checkout-independent, while `system=`, `ship=`, `scout=`, and `second=` shift by the length of the checkout path in which the test runs.
The test asserts the required content and the two regression budgets rather than those totals, so it reproduces on any checkout without byte-equality.

## Actual harness context checks

Codex 0.144.4 was measured with its native model-input renderer rather than a source assertion:

```sh
codex debug prompt-input '<generated brief>'
```

At the role-aware implementation, the primary prompt contained neither the old primary identity sentence nor an ordinary-worker delegation conflict.
Generated ship and scout inputs each contained one ordinary-worker role declaration, the direct-work rule, and no primary identity sentence.
The same renderer exposed `primary-runtime`, `validation-supervision`, project-management, recovery, AFK, X-mode, and quota-array skill metadata.

Claude Code 2.1.220 loaded the project skill directory and reported this startup fact in its native debug log:

```text
Loaded 23 unique skills (23 unconditional, 0 conditional, managed: 0, user: 2, project: 21, additional: 0, legacy commands: 0)
```

`/primary-runtime` and `/validation-supervision` were both recognized as commands, while a nonsense-name control returned `Unknown command`.
Two no-tool print-mode probes using the generated ship and scout briefs each returned `WORKER_ROLE_OK`, proving the model received direct-worker instructions without adopting the primary obligation to delegate the task.

OpenCode 1.1.50's native `debug skill` output contained both new owners among 25 discovered skills:

```sh
node /opt/homebrew/bin/opencode debug skill
```

Pi, Claude, Codex, and OpenCode therefore have current executable discovery evidence.
The existing verified Grok and Kimi adapter evidence remains applicable because both consume the same standard skill frontmatter and project skill directory without a changed transport.
Grok was previously live-verified invoking a discovered skill with `/<skill>`, and Kimi 0.29.1 was previously verified discovering Firstmate skills.
Neither standalone Grok nor Kimi was installed in the 2026-08-03 measurement environment, so no new version claim is made for those binaries.

## Startup and role delivery matrix

| Role or harness | Deterministic delivery |
| --- | --- |
| Ordinary ship or scout on every worker harness | The generated launch brief explicitly selects ordinary-worker precedence, requires direct work, and excludes adopting the primary runtime contract or operating the fleet, while still allowing an authorized edit to an instruction file the task assigns. |
| Persistent second mate | The generated charter loads `primary-runtime` before session start and preserves charter scope, persistence, idle behavior, and marked return channel. |
| Second-mate restart | The root marker selects the second-mate role, the native wrapper recognizes marked linked homes, and tracked update nudges require rereading both the root gateway and `primary-runtime`. |
| Claude primary | Root fallback is always present, and native SessionStart delivery covers startup, resume, and clear. |
| Codex primary | Root fallback is always present, and native SessionStart stdout delivery covers session startup. |
| OpenCode primary | Root fallback is always present, and `session.created` delivers the runtime-first instruction once per session id. |
| Pi and pi-signed primary | Root fallback is always present, and `session_start` delivery covers startup, new session, and resume. |
| Grok primary | Root fallback is authoritative because the current project SessionStart hook runs but discards stdout. |
| Kimi primary | Root fallback is authoritative because no native project session-start hook is installed. |

The compact fallback forbids project writes, unauthorized or red merges, discard of unlanded work, destructive or security-sensitive action, pre-drain notification handling, history-as-current-state reasoning, and blind turn completion before the primary owner is loaded.
This fallback lets a missing or silent hook stop safely without making worker sessions inherit the full primary contract.
