# Sovereign ledger redundancy mutation evidence

Audience: maintainer verification.

Verified on 2026-08-15 against the R4 sovereign-ledger redundancy implementation.
The owned denominator is 72 enforcing clauses, ten more than round 3's 62 attempted mutants because R4 added exact enumeration and read denominators, portable BSD/GNU identity selection, containment rejection, and full cross-member inode-set enforcement.
Every run copied the implementation under one scoped `mktemp -d`; the live ledger, `data/`, and `state/` were never inputs or targets.

```sh
tests/fm-sovereign-ledger-redundancy.mutation.sh --write-evidence sovereign-ledger-redundancy-mutation.candidate.md
```

Evidence publication rejects existing destinations, so the candidate is reviewed against this record before replacement rather than overwriting it in place.

Observed summary: `killed=47 survived=25 void=0 denominator=72`; the intentional no-op control recorded `substitutions=1 status=0 outcome=SURVIVED`.

| Mutant | Stable exact clause anchor | Substitutions | Outcome | Status | Unenforced claim when survived |
| --- | --- | ---: | --- | ---: | --- |
| `M001` | `strict-mode.errexit` | 1 | SURVIVED | 0 | Shell failures are not allowed to fall through. |
| `M002` | `manifest.denominator` | 1 | KILLED | 1 | - |
| `M003` | `canonical.directory-exists` | 1 | KILLED | 1 | - |
| `M004` | `canonical.physical-path` | 1 | SURVIVED | 0 | Containment uses physical directory paths. |
| `M005` | `manifest.fourth-member` | 1 | KILLED | 1 | - |
| `M006` | `enumeration.minimum-depth` | 1 | KILLED | 1 | - |
| `M007` | `enumeration.maximum-depth` | 1 | SURVIVED | 0 | Only top-level members are counted. |
| `M008` | `enumeration.record-per-entry` | 1 | KILLED | 1 | - |
| `M009` | `enumeration.line-denominator` | 1 | KILLED | 1 | - |
| `M010` | `enumeration.exact-count` | 1 | KILLED | 1 | - |
| `M011` | `enumeration.known-manifest` | 1 | KILLED | 1 | - |
| `M012` | `require.known-manifest` | 1 | KILLED | 1 | - |
| `M013` | `require.member-exists` | 1 | KILLED | 1 | - |
| `M014` | `require.no-symlink` | 1 | KILLED | 1 | - |
| `M015` | `require.regular-file` | 1 | KILLED | 124 | - |
| `M016` | `require.read-denominator` | 1 | KILLED | 1 | - |
| `M017` | `require.enumerates-directory` | 1 | SURVIVED | 0 | Bundle validation independently enumerates the directory. |
| `M018` | `require.exact-read-count` | 1 | SURVIVED | 0 | The manifest read count must equal four. |
| `M019` | `require.executable-verifier` | 1 | KILLED | 1 | - |
| `M020` | `layout.enumerate-primary` | 1 | SURVIVED | 0 | Layout comparison enumerates the primary independently. |
| `M021` | `layout.capture-primary` | 1 | KILLED | 1 | - |
| `M022` | `layout.enumerate-replica` | 1 | SURVIVED | 0 | Layout comparison enumerates the replica independently. |
| `M023` | `layout.capture-replica` | 1 | KILLED | 1 | - |
| `M024` | `layout.equal-manifests` | 1 | SURVIVED | 0 | Primary and replica layouts must match. |
| `M025` | `bytes.enumerate-primary` | 1 | SURVIVED | 0 | Byte comparison owns a fresh manifest enumeration. |
| `M026` | `bytes.skip-denominator` | 1 | KILLED | 1 | - |
| `M027` | `bytes.skip-only-selected` | 1 | KILLED | 1 | - |
| `M028` | `bytes.quiet-compare` | 1 | SURVIVED | 0 | Member comparison uses cmp status as its verdict. |
| `M029` | `bytes.reject-difference` | 1 | KILLED | 1 | - |
| `M030` | `bytes.read-denominator` | 1 | KILLED | 1 | - |
| `M031` | `bytes.exact-read-count` | 1 | SURVIVED | 0 | The byte-read count must equal its owned denominator. |
| `M032` | `identity.follow-selection` | 1 | KILLED | 1 | - |
| `M033` | `identity.bsd-follow` | 1 | KILLED | 1 | - |
| `M034` | `identity.gnu-follow` | 1 | SURVIVED | 0 | GNU followed identity uses stat -L. |
| `M035` | `identity.bsd-lstat` | 1 | KILLED | 1 | - |
| `M036` | `identity.gnu-lstat` | 1 | SURVIVED | 0 | GNU non-followed identity uses lstat semantics. |
| `M037` | `identity.numeric-shape` | 1 | KILLED | 1 | - |
| `M038` | `identity.lstat-wrapper` | 1 | KILLED | 1 | - |
| `M039` | `identity.stat-wrapper` | 1 | KILLED | 1 | - |
| `M040` | `identity.enumerate-primary` | 1 | SURVIVED | 0 | Identity verification enumerates the owned manifest independently. |
| `M041` | `identity.primary-lstat-read` | 1 | KILLED | 1 | - |
| `M042` | `identity.replica-lstat-read` | 1 | KILLED | 1 | - |
| `M043` | `identity.primary-stat-read` | 1 | KILLED | 1 | - |
| `M044` | `identity.replica-stat-read` | 1 | KILLED | 1 | - |
| `M045` | `identity.read-denominator` | 1 | KILLED | 1 | - |
| `M046` | `identity.exact-read-count` | 1 | SURVIVED | 0 | Identity reads must cover exactly four members. |
| `M047` | `identity.replica-cross-product` | 1 | KILLED | 1 | - |
| `M048` | `identity.primary-cross-product` | 1 | KILLED | 1 | - |
| `M049` | `identity.lstat-disjoint` | 1 | KILLED | 1 | - |
| `M050` | `identity.lstat-member-attribution` | 1 | KILLED | 1 | - |
| `M051` | `identity.stat-disjoint` | 1 | KILLED | 1 | - |
| `M052` | `identity.stat-member-attribution` | 1 | KILLED | 1 | - |
| `M053` | `containment.distinct-paths` | 1 | KILLED | 1 | - |
| `M054` | `containment.primary-outside-replica` | 1 | KILLED | 1 | - |
| `M055` | `containment.replica-outside-primary` | 1 | KILLED | 1 | - |
| `M056` | `verifier.public-verify-command` | 1 | KILLED | 1 | - |
| `M057` | `prefix.primary-line-count` | 1 | KILLED | 1 | - |
| `M058` | `prefix.replica-line-count` | 1 | KILLED | 1 | - |
| `M059` | `prefix.nonempty-replica` | 1 | KILLED | 1 | - |
| `M060` | `prefix.strictly-shorter` | 1 | KILLED | 1 | - |
| `M061` | `prefix.leading-bytes` | 1 | KILLED | 1 | - |
| `M062` | `preflight.require-primary` | 1 | SURVIVED | 0 | Pair preflight validates the primary bundle. |
| `M063` | `preflight.layout` | 1 | SURVIVED | 0 | Pair preflight compares the exact layouts. |
| `M064` | `preflight.nonledger-bytes` | 1 | SURVIVED | 0 | Pair preflight compares replica-controlled code before execution. |
| `M065` | `exact.all-bytes` | 1 | SURVIVED | 0 | Exact verification compares all four members. |
| `M066` | `exact.disjoint-identities` | 1 | KILLED | 1 | - |
| `M067` | `exact.verify-primary` | 1 | SURVIVED | 0 | Exact verification validates the primary ledger. |
| `M068` | `exact.verify-replica` | 1 | SURVIVED | 0 | Exact verification validates replica ledger data. |
| `M069` | `copy.enumerate-primary` | 1 | SURVIVED | 0 | Copying starts from an independently enumerated manifest. |
| `M070` | `copy.preserve-mode` | 1 | SURVIVED | 0 | Bundle copying preserves required executable modes. |
| `M071` | `copy.private-umask` | 1 | SURVIVED | 0 | Bundle staging uses a private creation mask. |
| `M072` | `copy.exact-read-count` | 1 | SURVIVED | 0 | Copying must cover exactly four members. |

## Evidence publication containment

The publication chokepoint was verified with scoped temporary fixtures on 2026-08-15.

```sh
tests/fm-sovereign-ledger-evidence-publish.mutation.sh
```

Observed bounded summary:

```text
CONTAINMENT FIXTURES passed=10 failed=0
PUBLISH MUTANT P001 anchor=resolved-path-validator-call substitutions=1 killed=5 survived=4 void=0
PUBLISH MUTANT P002 anchor=exclusive-create-flag substitutions=1 killed=0 survived=9 void=0
PUBLISH MATRIX SUMMARY mechanisms=3 written_boundaries=2 natural_boundaries=1 mutants=2 fixtures=9 cells=18 killed=5 survived=13 void=0
```

The three independent mechanisms are the resolved-path validator, exclusive `O_EXCL` creation, and the natural unresolved-parent failure from `sysopen`.
The natural boundary has no written clause to substitute, so the written-mutant denominator is two while the enforcing-mechanism denominator is three.
A survived cell means the named different boundary still refused that fixture; zero substitutions make every cell for that mutant void.
The symlinked leaf, hard-link, and existing-leaf fixtures are defended only by `O_EXCL` when the validator call is neutralized.

| Mutant | Stable exact boundary anchor | Substitutions | Fixture | Outcome | Different surviving boundary |
| --- | --- | ---: | --- | --- | --- |
| `P001` | `resolved-path-validator-call` | 1 | `absolute` | KILLED | - |
| `P001` | `resolved-path-validator-call` | 1 | `traversal` | KILLED | - |
| `P001` | `resolved-path-validator-call` | 1 | `symlink-leaf-data` | SURVIVED | `exclusive-create-O_EXCL` |
| `P001` | `resolved-path-validator-call` | 1 | `symlink-parent` | KILLED | - |
| `P001` | `resolved-path-validator-call` | 1 | `symlink-parent-state` | KILLED | - |
| `P001` | `resolved-path-validator-call` | 1 | `resolved-outside` | KILLED | - |
| `P001` | `resolved-path-validator-call` | 1 | `hard-link` | SURVIVED | `exclusive-create-O_EXCL` |
| `P001` | `resolved-path-validator-call` | 1 | `unresolved-parent` | SURVIVED | `natural-unresolved-parent` |
| `P001` | `resolved-path-validator-call` | 1 | `existing` | SURVIVED | `exclusive-create-O_EXCL` |
| `P002` | `exclusive-create-flag` | 1 | `absolute` | SURVIVED | `resolved-path-validator` |
| `P002` | `exclusive-create-flag` | 1 | `traversal` | SURVIVED | `resolved-path-validator` |
| `P002` | `exclusive-create-flag` | 1 | `symlink-leaf-data` | SURVIVED | `resolved-path-validator` |
| `P002` | `exclusive-create-flag` | 1 | `symlink-parent` | SURVIVED | `resolved-path-validator` |
| `P002` | `exclusive-create-flag` | 1 | `symlink-parent-state` | SURVIVED | `resolved-path-validator` |
| `P002` | `exclusive-create-flag` | 1 | `resolved-outside` | SURVIVED | `resolved-path-validator` |
| `P002` | `exclusive-create-flag` | 1 | `hard-link` | SURVIVED | `resolved-path-validator` |
| `P002` | `exclusive-create-flag` | 1 | `unresolved-parent` | SURVIVED | `resolved-path-validator` |
| `P002` | `exclusive-create-flag` | 1 | `existing` | SURVIVED | `resolved-path-validator` |
