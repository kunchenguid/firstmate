# Firstmate Grill Me verification

Audience: maintainer verification.

The normative interview contract is owned by [`firstmate-grill-me`](../../.agents/skills/firstmate-grill-me/SKILL.md).

This record keeps the public source identity, local owner reconciliation, active Pi behavior, and repeatable verification entry points.

## Public source identity

The behavior adapted here was read from Matt Pocock's public repository `mattpocock/skills`.

The pinned audit snapshot is `main` commit `6654f6b60cd9d5be8b54c6fafe44346dabeb3b76`.

The relevant current blobs were `grill-me/SKILL.md` `3947ff9c4ad980d14fc07fccbf659d47c114e81d` and `grilling/SKILL.md` `8ca78c6d8f901aab0c5a1f896034b70e666ff2a3`.

The source repository is `https://github.com/mattpocock/skills`.

The source package metadata identifies Matt Pocock as author and reports the MIT license.

The repository license begins `Copyright (c) 2026 Matt Pocock`.

The public `grill-me` front door is user-invoked and delegates to `grilling`.

The `grilling` procedure models a design tree, asks the settled independent frontier in rounds, gives visible recommendations, separates facts from decisions, waits for captain answers, and requires explicit shared understanding before handoff.

Firstmate adds project intake, privacy, owner routing, plan-only output, bounded continuation, and the local `note-to-node` handoff boundary.

Firstmate does not vendor the public skill, install it, invoke a public `Skill` tool, or create a same-name `grill-me` alias.

## Local `note-to-node` reconciliation

Retained home-local captain provenance identifies `note-to-node` as a method written by the captain and Firstmate together.

The canonical spelling is `note-to-node`, and the method is local rather than an online command or third-party package.

The skill linked above owns the retained-evidence preflight and normative handoff boundary.

Grill Me runs before the existing local method and adds no command, skill, package, timer, daemon, or replacement implementation for it.

The focused Pi test below verifies the public ordering and absence boundary.

## Pi behavior verified

Pi version at the audit baseline was `0.84.3`.

The required skill path is `.agents/skills/firstmate-grill-me/SKILL.md`.

Pi's ordinary project discovery requires the trusted project resource surface.

The explicit command is `/skill:firstmate-grill-me`.

The command name is intentionally unique so a separately loaded public `grill-me` skill cannot shadow it.

Pi's `enableSkillCommands` setting controls interactive command presentation but is not an authorization boundary for explicit expansion or RPC command enumeration.

This integration adds no Pi-only input router.

## Verification commands

Run the focused public-interface test from the repository root:

```sh
bin/fm-test-run.sh tests/fm-grill-me.test.sh
```

Run the documentation inventory check:

```sh
bin/fm-doc-audience-check.sh
```

Run the full pinned shell and workflow lint:

```sh
bin/fm-lint.sh
```

The test uses a temporary trusted project, an isolated Pi configuration directory, Pi RPC `get_commands`, explicit `--skill` loading, a same-name collision fixture, and a local deterministic provider fixture.

The test never sends a provider request to an external service and never uses a credential.

The test exercises discovery, the explicit command, unique-name collision safety, exact-trigger description boundaries, public command expansion, safe retained-evidence disclosure and redaction, existing credential-owner routing, bounded improvement residuals, the plan-only boundary, the local handoff boundary, and the absence of a `skill:note-to-node` command.

Observed on 2026-08-29 with Pi `0.84.3`:

```text
$ pi --version
0.84.3
$ bin/fm-test-run.sh tests/fm-grill-me.test.sh
ok - trusted project discovery exposes the unique command and exact trigger without near-miss aliases
ok - project trust is required for discovery while explicit skill loading remains available
ok - public Grill Me coexistence and same-name collision behavior preserve the local owner
ok - explicit command expansion reaches the public Pi lifecycle with arguments and handoff boundaries intact
FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0
$ bin/fm-doc-audience-check.sh
fm-doc-audience-check: ok surfaces=76 local_links=293
$ bin/fm-lint.sh
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)
fm-lint.sh: full ShellCheck extended analysis enabled
fm-lint-workflows.sh: actionlint 1.7.12 (pinned 1.7.12)
fm-lint-workflows.sh: 3 workflow files valid
```

## Update rule

Do not track the moving public `main` branch as an unpinned dependency.

When the adapted behavior changes, re-read the first-party source with `gh-axi`, compare the pinned commit and blobs, and review the MIT license before changing the Firstmate skill.

If the public author, license, delegation, frontier, or confirmation behavior changes, stop and perform a new source audit.

If substantial public text is copied in a future change, preserve the MIT copyright and permission notice and record the derived portions here.

Keep task chronology, temporary paths, branch names, and delivery evidence in the private task report or PR evidence rather than this reusable record.
