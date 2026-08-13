# Vendored engineering skills verification

## Current guarantee

Firstmate ships 21 engineering and productivity skills as an adapted, pinned snapshot under `.agents/skills/`.
They are available to every supported harness from a fresh Firstmate clone without a separate plugin or installer step.
`skills-lock.json` records the exact upstream revision, the upstream directory hash for every selected skill, the adapted Firstmate directory hash, and the shared adaptation-contract hash.
`bin/fm-skills-lock.sh` is the executable owner of the network-free integrity and discovery check and the optional upstream-checkout verification.
The upstream MIT notice is retained at `.agents/skills/VENDORED-ENGINEERING-LICENSE.md` and is integrity-bound by the same lock validator.
Lock version 3 uses a canonical length-delimited tree encoding that binds each relative filename to its exact content bytes.

The source snapshot is `mattpocock/skills@84fdeffd12f2ee307994d1eb6feb48173b6e0502`, captured from `refs/heads/main` on 2026-08-07.
The selected snapshot intentionally excludes four upstream entries after a file-level adaptation review:

- `grill-me` is a one-line alias for the retained `grilling` skill, so bundling both creates duplicate discovery names for one workflow.
- `teach` owns a broad, stateful curriculum workspace (`MISSION.md`, lessons, assets, learning records, and browser presentation) rather than an engineering workflow, and its direct workspace writes do not fit Firstmate's project-task lifecycle.
- `to-questionnaire` creates an outward-facing handoff document after an interactive recipient interview; Firstmate has no standing authority or lifecycle owner for that communication workflow.
- `wait-what` is a terse re-prompt that assumes `CONTEXT.md` exists, not a durable skill workflow, and overlaps Firstmate's ordinary clarification and domain-language rules.

Their deletion is therefore a deliberate adaptation choice, not fallout from the Agent Plugins directory flattening.
Every selected `SKILL.md` points to `.agents/skills/VENDORED-ENGINEERING-CONTRACT.md` before its upstream procedure.

## Agent Plugins reconciliation

The upstream Agent Plugins 1.0 refactor at `a16a2674bc76900417227f1cd2add74a0fb9dddf` moves promoted skills from category subdirectories to immediate children of `skills/` and adds `plugin.json`.
The refactor does not change the bytes of any of Firstmate's 21 selected source directories.
The optional source check proves that by hashing the old paths at the pinned revision and the flattened paths at the Agent Plugins revision.

The upstream plugin is not a superior replacement for Firstmate's bundle.
At the verified revision, upstream installation remains an explicit managed Claude plugin or an explicit `npx skills` copy for Codex and other agents.
The upstream README warns users to choose one distribution because installing both creates duplicate skills.
Neither path makes the skills available automatically to all harnesses in a fresh Firstmate clone, and neither carries Firstmate's delegation, consent, forge-tool, or merge-authority adaptation.
Firstmate therefore retains the pinned adapted snapshot and documents the upstream plugin as optional rather than deleting the bundle.

## Evidence refreshed 2026-08-08

Versions used were `gh-axi 0.1.30`, `git 2.55.0`, and `node 26.3.0`.

Remote heads were checked with:

```sh
git ls-remote https://github.com/mattpocock/skills.git \
  refs/heads/main refs/heads/flatten-skills-tree
```

The exact output was:

```text
a16a2674bc76900417227f1cd2add74a0fb9dddf refs/heads/flatten-skills-tree
84fdeffd12f2ee307994d1eb6feb48173b6e0502 refs/heads/main
```

The reproducible source and Agent Plugins compatibility check is:

```sh
verification_root=$(mktemp -d)
(cd "$verification_root" && gh-axi repo clone mattpocock/skills)
git -C "$verification_root/skills" switch --detach \
  84fdeffd12f2ee307994d1eb6feb48173b6e0502
bin/fm-skills-lock.sh --source-root "$verification_root/skills"
```

The exact result was:

```text
ok - skills lock: 21 adapted skills and Firstmate discovery paths match; upstream mattpocock/skills@84fdeffd12f2 verified; Agent Plugins a16a2674bc76 content-compatible
```

The portable behavior test is:

```sh
tests/fm-skills-lock.test.sh
```

The exact result was:

```text
ok - checked-in vendored snapshot and discovery paths validate through the public checker
ok - public checker rejects a changed vendored skill without trusting its lock
ok - public checker rejects a filename/content-boundary collision
ok - public checker integrity-binds the upstream redistribution notice
ok - public checker documents optional pinned-upstream verification
# all fm-skills-lock tests passed
```
