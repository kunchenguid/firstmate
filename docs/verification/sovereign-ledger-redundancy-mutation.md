# Sovereign ledger redundancy mutation evidence

Audience: maintainer verification.

Verified on 2026-08-15 against the R5 sovereign-ledger redundancy chokepoint.
The owned denominator spans exact real-name enumeration, the st_dev predicate, the four-by-four member-identity cross-product, both member admission calls, carried-identity refresh recheck, exclusive publication, verification, and all three dispatch entries.
Every run copied the implementation under one scoped `mktemp -d`; the live ledger, `data/`, and `state/` were never inputs or targets.

```sh
tests/fm-sovereign-ledger-redundancy.mutation.sh --write-evidence sovereign-ledger-redundancy-mutation.candidate.md
```

Evidence publication rejects existing destinations, so the candidate is reviewed against this record before replacement rather than overwriting it in place.

Observed summary: `killed=36 survived=17 void=0 harness_broken=0 denominator=53`; the intentional no-op control recorded `substitutions=1 status=0 outcome=SURVIVED`.

| Mutant | Stable exact clause anchor | Substitutions | Outcome | Status | Unenforced claim when survived |
| --- | --- | ---: | --- | ---: | --- |
| `M001` | `strict.errexit` | 1 | SURVIVED | 0 | Shell failures cannot fall through. |
| `M002` | `manifest.denominator` | 1 | KILLED | 1 | - |
| `M003` | `canonical.exists` | 1 | KILLED | 1 | - |
| `M004` | `canonical.physical` | 1 | KILLED | 1 | - |
| `M005` | `manifest.tests-member` | 1 | KILLED | 1 | - |
| `M006` | `enumerate.top-level` | 1 | KILLED | 1 | - |
| `M007` | `enumerate.real-names` | 1 | KILLED | 1 | - |
| `M008` | `enumerate.exact-set` | 1 | KILLED | 1 | - |
| `M009` | `require.no-symlink` | 1 | KILLED | 1 | - |
| `M010` | `require.regular` | 1 | KILLED | 1 | - |
| `M011` | `require.executable` | 1 | KILLED | 1 | - |
| `M012` | `bytes.reject` | 1 | KILLED | 1 | - |
| `M013` | `device.bsd-read` | 1 | KILLED | 1 | - |
| `M014` | `device.gnu-read` | 1 | KILLED | 1 | - |
| `M015` | `device.numeric-shape` | 1 | KILLED | 1 | - |
| `M016` | `containment.distinct` | 1 | KILLED | 1 | - |
| `M017` | `containment.primary` | 1 | KILLED | 1 | - |
| `M018` | `containment.replica` | 1 | KILLED | 1 | - |
| `M019` | `device.primary-read` | 1 | KILLED | 1 | - |
| `M020` | `device.replica-read` | 1 | KILLED | 1 | - |
| `M021` | `device.inequality` | 1 | KILLED | 1 | - |
| `M022` | `device.optout-only` | 1 | KILLED | 1 | - |
| `M023` | `verifier.execute` | 1 | KILLED | 1 | - |
| `M024` | `prefix.nonempty` | 1 | KILLED | 1 | - |
| `M025` | `prefix.shorter` | 1 | KILLED | 1 | - |
| `M026` | `prefix.leading` | 1 | KILLED | 1 | - |
| `M027` | `recheck.replica-type` | 1 | SURVIVED | 0 | Admission reclassifies replica entries after verifier execution. |
| `M028` | `directory.canonical-stable` | 1 | SURVIVED | 0 | A directory path cannot change after admission. |
| `M029` | `directory.identity-stable` | 1 | SURVIVED | 0 | A directory object cannot change after admission. |
| `M030` | `publish.exclusive-create` | 1 | SURVIVED | 0 | Bundle members are created exclusively. |
| `M031` | `publish.preserve-mode` | 1 | KILLED | 1 | - |
| `M032` | `publish.parent-no-symlink` | 1 | SURVIVED | 0 | Snapshot parent cannot be a symlink. |
| `M033` | `publish.safe-leaf` | 1 | SURVIVED | 0 | Snapshot leaf is safe. |
| `M034` | `publish.destination-absent` | 1 | SURVIVED | 0 | Snapshot destination is absent and not symlinked. |
| `M035` | `publish.parent-device` | 1 | SURVIVED | 0 | Snapshot checks destination-volume st_dev before creation. |
| `M036` | `publish.mkdir-exclusive` | 1 | SURVIVED | 0 | Snapshot claims its final destination exclusively. |
| `M037` | `publish.copy-bundle` | 1 | KILLED | 1 | - |
| `M038` | `publish.validate-object` | 1 | SURVIVED | 0 | Snapshot validates the object it published. |
| `M039` | `refresh.prefix-admission` | 1 | KILLED | 1 | - |
| `M040` | `refresh.atomic-copy` | 1 | KILLED | 1 | - |
| `M041` | `refresh.post-admission` | 1 | SURVIVED | 0 | Refresh re-admits the published exact pair. |
| `M042` | `verify.inspect-admission` | 1 | KILLED | 1 | - |
| `M043` | `verify.exact-recheck` | 1 | SURVIVED | 0 | Verify re-admits an exact pair before PASS. |
| `M044` | `option.named-flag` | 1 | KILLED | 1 | - |
| `M045` | `dispatch.snapshot` | 1 | KILLED | 1 | - |
| `M046` | `dispatch.refresh` | 1 | KILLED | 1 | - |
| `M047` | `dispatch.verify` | 1 | KILLED | 1 | - |
| `M048` | `identity.member-read` | 1 | KILLED | 1 | - |
| `M049` | `identity.cross-product-disjoint` | 1 | KILLED | 1 | - |
| `M050` | `identity.cross-product-denominator` | 1 | SURVIVED | 0 | The complete four-by-four member cross-product is proved. |
| `M051` | `admission.initial-member-identity` | 1 | SURVIVED | 0 | Initial pair admission proves member independence before verifier execution. |
| `M052` | `admission.final-member-identity` | 1 | SURVIVED | 0 | Final pair admission re-proves member independence after verifier execution. |
| `M053` | `refresh.carried-member-identity` | 1 | SURVIVED | 0 | Refresh rechecks the admitted member identities before publication. |

## Evidence publication containment

The complete fixture results, cell outcomes, alternate defenders, per-mutant totals, and aggregate denominator below come from one canonical generated stream.

# Evidence publication containment matrix

Generated by `tests/fm-sovereign-ledger-evidence-publish.mutation.sh --markdown`.

```text
  PASS  absolute destination aimed at fake data is refused
  PASS  dot-dot traversal aimed at fake data is refused
  PASS  symlinked leaf aimed at fake data is refused
  PASS  symlinked parent directory is refused
  PASS  symlinked parent aimed at fake state is refused
  PASS  destination resolving outside after parent resolution is refused
  PASS  existing hard-linked destination is refused without mutation
  PASS  unresolved destination parent is refused
  PASS  existing destination is refused without mutation
  PASS  symlinked evidence scope is refused
  PASS  unresolved evidence scope is refused
  PASS  unsafe destination leaf is refused
  PASS  legitimate in-scope publication remains exact
CONTAINMENT FIXTURES passed=13 failed=0
PUBLISH CELL mutant=P001 anchor=resolved-path-validator-call substitutions=1 fixture=absolute outcome=KILLED defender=-
PUBLISH CELL mutant=P001 anchor=resolved-path-validator-call substitutions=1 fixture=traversal outcome=KILLED defender=-
PUBLISH CELL mutant=P001 anchor=resolved-path-validator-call substitutions=1 fixture=symlink-leaf-data outcome=SURVIVED defender=exclusive-create-O_EXCL
PUBLISH CELL mutant=P001 anchor=resolved-path-validator-call substitutions=1 fixture=symlink-parent outcome=KILLED defender=-
PUBLISH CELL mutant=P001 anchor=resolved-path-validator-call substitutions=1 fixture=symlink-parent-state outcome=KILLED defender=-
PUBLISH CELL mutant=P001 anchor=resolved-path-validator-call substitutions=1 fixture=resolved-outside outcome=KILLED defender=-
PUBLISH CELL mutant=P001 anchor=resolved-path-validator-call substitutions=1 fixture=hard-link outcome=SURVIVED defender=exclusive-create-O_EXCL
PUBLISH CELL mutant=P001 anchor=resolved-path-validator-call substitutions=1 fixture=unresolved-parent outcome=SURVIVED defender=natural-unresolved-parent
PUBLISH CELL mutant=P001 anchor=resolved-path-validator-call substitutions=1 fixture=existing outcome=SURVIVED defender=exclusive-create-O_EXCL
PUBLISH CELL mutant=P001 anchor=resolved-path-validator-call substitutions=1 fixture=scope-symlink outcome=KILLED defender=-
PUBLISH CELL mutant=P001 anchor=resolved-path-validator-call substitutions=1 fixture=scope-unresolved outcome=SURVIVED defender=natural-unresolved-parent
PUBLISH CELL mutant=P001 anchor=resolved-path-validator-call substitutions=1 fixture=unsafe-leaf outcome=SURVIVED defender=exclusive-create-O_EXCL
PUBLISH MUTANT P001 anchor=resolved-path-validator-call substitutions=1 killed=6 survived=6 void=0
PUBLISH CELL mutant=P002 anchor=exclusive-create-flag substitutions=1 fixture=absolute outcome=SURVIVED defender=resolved-path-validator
PUBLISH CELL mutant=P002 anchor=exclusive-create-flag substitutions=1 fixture=traversal outcome=SURVIVED defender=resolved-path-validator
PUBLISH CELL mutant=P002 anchor=exclusive-create-flag substitutions=1 fixture=symlink-leaf-data outcome=SURVIVED defender=resolved-path-validator
PUBLISH CELL mutant=P002 anchor=exclusive-create-flag substitutions=1 fixture=symlink-parent outcome=SURVIVED defender=resolved-path-validator
PUBLISH CELL mutant=P002 anchor=exclusive-create-flag substitutions=1 fixture=symlink-parent-state outcome=SURVIVED defender=resolved-path-validator
PUBLISH CELL mutant=P002 anchor=exclusive-create-flag substitutions=1 fixture=resolved-outside outcome=SURVIVED defender=resolved-path-validator
PUBLISH CELL mutant=P002 anchor=exclusive-create-flag substitutions=1 fixture=hard-link outcome=SURVIVED defender=resolved-path-validator
PUBLISH CELL mutant=P002 anchor=exclusive-create-flag substitutions=1 fixture=unresolved-parent outcome=SURVIVED defender=resolved-path-validator
PUBLISH CELL mutant=P002 anchor=exclusive-create-flag substitutions=1 fixture=existing outcome=SURVIVED defender=resolved-path-validator
PUBLISH CELL mutant=P002 anchor=exclusive-create-flag substitutions=1 fixture=scope-symlink outcome=SURVIVED defender=resolved-path-validator
PUBLISH CELL mutant=P002 anchor=exclusive-create-flag substitutions=1 fixture=scope-unresolved outcome=SURVIVED defender=resolved-path-validator
PUBLISH CELL mutant=P002 anchor=exclusive-create-flag substitutions=1 fixture=unsafe-leaf outcome=SURVIVED defender=resolved-path-validator
PUBLISH MUTANT P002 anchor=exclusive-create-flag substitutions=1 killed=0 survived=12 void=0
PUBLISH CELL mutant=P003 anchor=symlink-component-precheck substitutions=1 fixture=absolute outcome=SURVIVED defender=absolute-path-guard
PUBLISH CELL mutant=P003 anchor=symlink-component-precheck substitutions=1 fixture=traversal outcome=SURVIVED defender=unsafe-component-guard
PUBLISH CELL mutant=P003 anchor=symlink-component-precheck substitutions=1 fixture=symlink-leaf-data outcome=SURVIVED defender=symlink-leaf-guard
PUBLISH CELL mutant=P003 anchor=symlink-component-precheck substitutions=1 fixture=symlink-parent outcome=KILLED defender=-
PUBLISH CELL mutant=P003 anchor=symlink-component-precheck substitutions=1 fixture=symlink-parent-state outcome=SURVIVED defender=canonical-structural-containment
PUBLISH CELL mutant=P003 anchor=symlink-component-precheck substitutions=1 fixture=resolved-outside outcome=SURVIVED defender=canonical-structural-containment
PUBLISH CELL mutant=P003 anchor=symlink-component-precheck substitutions=1 fixture=hard-link outcome=SURVIVED defender=existing-leaf-guard
PUBLISH CELL mutant=P003 anchor=symlink-component-precheck substitutions=1 fixture=unresolved-parent outcome=SURVIVED defender=canonical-parent-resolution
PUBLISH CELL mutant=P003 anchor=symlink-component-precheck substitutions=1 fixture=existing outcome=SURVIVED defender=existing-leaf-guard
PUBLISH CELL mutant=P003 anchor=symlink-component-precheck substitutions=1 fixture=scope-symlink outcome=SURVIVED defender=scope-symlink-guard
PUBLISH CELL mutant=P003 anchor=symlink-component-precheck substitutions=1 fixture=scope-unresolved outcome=SURVIVED defender=canonical-scope-resolution
PUBLISH CELL mutant=P003 anchor=symlink-component-precheck substitutions=1 fixture=unsafe-leaf outcome=SURVIVED defender=unsafe-leaf-guard
PUBLISH MUTANT P003 anchor=symlink-component-precheck substitutions=1 killed=1 survived=11 void=0
PUBLISH CELL mutant=P004 anchor=canonical-structural-containment substitutions=1 fixture=absolute outcome=SURVIVED defender=absolute-path-guard
PUBLISH CELL mutant=P004 anchor=canonical-structural-containment substitutions=1 fixture=traversal outcome=SURVIVED defender=unsafe-component-guard
PUBLISH CELL mutant=P004 anchor=canonical-structural-containment substitutions=1 fixture=symlink-leaf-data outcome=SURVIVED defender=symlink-leaf-guard
PUBLISH CELL mutant=P004 anchor=canonical-structural-containment substitutions=1 fixture=symlink-parent outcome=SURVIVED defender=symlink-component-precheck
PUBLISH CELL mutant=P004 anchor=canonical-structural-containment substitutions=1 fixture=symlink-parent-state outcome=SURVIVED defender=symlink-component-precheck
PUBLISH CELL mutant=P004 anchor=canonical-structural-containment substitutions=1 fixture=resolved-outside outcome=SURVIVED defender=final-structural-containment
PUBLISH CELL mutant=P004 anchor=canonical-structural-containment substitutions=1 fixture=hard-link outcome=SURVIVED defender=existing-leaf-guard
PUBLISH CELL mutant=P004 anchor=canonical-structural-containment substitutions=1 fixture=unresolved-parent outcome=SURVIVED defender=canonical-parent-resolution
PUBLISH CELL mutant=P004 anchor=canonical-structural-containment substitutions=1 fixture=existing outcome=SURVIVED defender=existing-leaf-guard
PUBLISH CELL mutant=P004 anchor=canonical-structural-containment substitutions=1 fixture=scope-symlink outcome=SURVIVED defender=scope-symlink-guard
PUBLISH CELL mutant=P004 anchor=canonical-structural-containment substitutions=1 fixture=scope-unresolved outcome=SURVIVED defender=canonical-scope-resolution
PUBLISH CELL mutant=P004 anchor=canonical-structural-containment substitutions=1 fixture=unsafe-leaf outcome=SURVIVED defender=unsafe-leaf-guard
PUBLISH MUTANT P004 anchor=canonical-structural-containment substitutions=1 killed=0 survived=12 void=0
PUBLISH CELL mutant=P005 anchor=absolute-path-guard substitutions=1 fixture=absolute outcome=SURVIVED defender=unsafe-component-guard
PUBLISH CELL mutant=P005 anchor=absolute-path-guard substitutions=1 fixture=traversal outcome=SURVIVED defender=unsafe-component-guard
PUBLISH CELL mutant=P005 anchor=absolute-path-guard substitutions=1 fixture=symlink-leaf-data outcome=SURVIVED defender=symlink-leaf-guard
PUBLISH CELL mutant=P005 anchor=absolute-path-guard substitutions=1 fixture=symlink-parent outcome=SURVIVED defender=symlink-component-precheck
PUBLISH CELL mutant=P005 anchor=absolute-path-guard substitutions=1 fixture=symlink-parent-state outcome=SURVIVED defender=symlink-component-precheck
PUBLISH CELL mutant=P005 anchor=absolute-path-guard substitutions=1 fixture=resolved-outside outcome=SURVIVED defender=canonical-structural-containment
PUBLISH CELL mutant=P005 anchor=absolute-path-guard substitutions=1 fixture=hard-link outcome=SURVIVED defender=existing-leaf-guard
PUBLISH CELL mutant=P005 anchor=absolute-path-guard substitutions=1 fixture=unresolved-parent outcome=SURVIVED defender=canonical-parent-resolution
PUBLISH CELL mutant=P005 anchor=absolute-path-guard substitutions=1 fixture=existing outcome=SURVIVED defender=existing-leaf-guard
PUBLISH CELL mutant=P005 anchor=absolute-path-guard substitutions=1 fixture=scope-symlink outcome=SURVIVED defender=scope-symlink-guard
PUBLISH CELL mutant=P005 anchor=absolute-path-guard substitutions=1 fixture=scope-unresolved outcome=SURVIVED defender=canonical-scope-resolution
PUBLISH CELL mutant=P005 anchor=absolute-path-guard substitutions=1 fixture=unsafe-leaf outcome=SURVIVED defender=unsafe-leaf-guard
PUBLISH MUTANT P005 anchor=absolute-path-guard substitutions=1 killed=0 survived=12 void=0
PUBLISH CELL mutant=P006 anchor=unsafe-component-guard substitutions=1 fixture=absolute outcome=SURVIVED defender=absolute-path-guard
PUBLISH CELL mutant=P006 anchor=unsafe-component-guard substitutions=1 fixture=traversal outcome=SURVIVED defender=canonical-structural-containment
PUBLISH CELL mutant=P006 anchor=unsafe-component-guard substitutions=1 fixture=symlink-leaf-data outcome=SURVIVED defender=symlink-leaf-guard
PUBLISH CELL mutant=P006 anchor=unsafe-component-guard substitutions=1 fixture=symlink-parent outcome=SURVIVED defender=symlink-component-precheck
PUBLISH CELL mutant=P006 anchor=unsafe-component-guard substitutions=1 fixture=symlink-parent-state outcome=SURVIVED defender=symlink-component-precheck
PUBLISH CELL mutant=P006 anchor=unsafe-component-guard substitutions=1 fixture=resolved-outside outcome=SURVIVED defender=canonical-structural-containment
PUBLISH CELL mutant=P006 anchor=unsafe-component-guard substitutions=1 fixture=hard-link outcome=SURVIVED defender=existing-leaf-guard
PUBLISH CELL mutant=P006 anchor=unsafe-component-guard substitutions=1 fixture=unresolved-parent outcome=SURVIVED defender=canonical-parent-resolution
PUBLISH CELL mutant=P006 anchor=unsafe-component-guard substitutions=1 fixture=existing outcome=SURVIVED defender=existing-leaf-guard
PUBLISH CELL mutant=P006 anchor=unsafe-component-guard substitutions=1 fixture=scope-symlink outcome=SURVIVED defender=scope-symlink-guard
PUBLISH CELL mutant=P006 anchor=unsafe-component-guard substitutions=1 fixture=scope-unresolved outcome=SURVIVED defender=canonical-scope-resolution
PUBLISH CELL mutant=P006 anchor=unsafe-component-guard substitutions=1 fixture=unsafe-leaf outcome=SURVIVED defender=unsafe-leaf-guard
PUBLISH MUTANT P006 anchor=unsafe-component-guard substitutions=1 killed=0 survived=12 void=0
PUBLISH CELL mutant=P007 anchor=symlink-leaf-guard substitutions=1 fixture=absolute outcome=SURVIVED defender=absolute-path-guard
PUBLISH CELL mutant=P007 anchor=symlink-leaf-guard substitutions=1 fixture=traversal outcome=SURVIVED defender=unsafe-component-guard
PUBLISH CELL mutant=P007 anchor=symlink-leaf-guard substitutions=1 fixture=symlink-leaf-data outcome=SURVIVED defender=exclusive-create-O_EXCL
PUBLISH CELL mutant=P007 anchor=symlink-leaf-guard substitutions=1 fixture=symlink-parent outcome=SURVIVED defender=symlink-component-precheck
PUBLISH CELL mutant=P007 anchor=symlink-leaf-guard substitutions=1 fixture=symlink-parent-state outcome=SURVIVED defender=symlink-component-precheck
PUBLISH CELL mutant=P007 anchor=symlink-leaf-guard substitutions=1 fixture=resolved-outside outcome=SURVIVED defender=canonical-structural-containment
PUBLISH CELL mutant=P007 anchor=symlink-leaf-guard substitutions=1 fixture=hard-link outcome=SURVIVED defender=existing-leaf-guard
PUBLISH CELL mutant=P007 anchor=symlink-leaf-guard substitutions=1 fixture=unresolved-parent outcome=SURVIVED defender=canonical-parent-resolution
PUBLISH CELL mutant=P007 anchor=symlink-leaf-guard substitutions=1 fixture=existing outcome=SURVIVED defender=existing-leaf-guard
PUBLISH CELL mutant=P007 anchor=symlink-leaf-guard substitutions=1 fixture=scope-symlink outcome=SURVIVED defender=scope-symlink-guard
PUBLISH CELL mutant=P007 anchor=symlink-leaf-guard substitutions=1 fixture=scope-unresolved outcome=SURVIVED defender=canonical-scope-resolution
PUBLISH CELL mutant=P007 anchor=symlink-leaf-guard substitutions=1 fixture=unsafe-leaf outcome=SURVIVED defender=unsafe-leaf-guard
PUBLISH MUTANT P007 anchor=symlink-leaf-guard substitutions=1 killed=0 survived=12 void=0
PUBLISH CELL mutant=P008 anchor=existing-leaf-guard substitutions=1 fixture=absolute outcome=SURVIVED defender=absolute-path-guard
PUBLISH CELL mutant=P008 anchor=existing-leaf-guard substitutions=1 fixture=traversal outcome=SURVIVED defender=unsafe-component-guard
PUBLISH CELL mutant=P008 anchor=existing-leaf-guard substitutions=1 fixture=symlink-leaf-data outcome=SURVIVED defender=symlink-leaf-guard
PUBLISH CELL mutant=P008 anchor=existing-leaf-guard substitutions=1 fixture=symlink-parent outcome=SURVIVED defender=symlink-component-precheck
PUBLISH CELL mutant=P008 anchor=existing-leaf-guard substitutions=1 fixture=symlink-parent-state outcome=SURVIVED defender=symlink-component-precheck
PUBLISH CELL mutant=P008 anchor=existing-leaf-guard substitutions=1 fixture=resolved-outside outcome=SURVIVED defender=canonical-structural-containment
PUBLISH CELL mutant=P008 anchor=existing-leaf-guard substitutions=1 fixture=hard-link outcome=SURVIVED defender=exclusive-create-O_EXCL
PUBLISH CELL mutant=P008 anchor=existing-leaf-guard substitutions=1 fixture=unresolved-parent outcome=SURVIVED defender=canonical-parent-resolution
PUBLISH CELL mutant=P008 anchor=existing-leaf-guard substitutions=1 fixture=existing outcome=SURVIVED defender=exclusive-create-O_EXCL
PUBLISH CELL mutant=P008 anchor=existing-leaf-guard substitutions=1 fixture=scope-symlink outcome=SURVIVED defender=scope-symlink-guard
PUBLISH CELL mutant=P008 anchor=existing-leaf-guard substitutions=1 fixture=scope-unresolved outcome=SURVIVED defender=canonical-scope-resolution
PUBLISH CELL mutant=P008 anchor=existing-leaf-guard substitutions=1 fixture=unsafe-leaf outcome=SURVIVED defender=unsafe-leaf-guard
PUBLISH MUTANT P008 anchor=existing-leaf-guard substitutions=1 killed=0 survived=12 void=0
PUBLISH CELL mutant=P009 anchor=canonical-parent-resolution substitutions=1 fixture=absolute outcome=SURVIVED defender=absolute-path-guard
PUBLISH CELL mutant=P009 anchor=canonical-parent-resolution substitutions=1 fixture=traversal outcome=SURVIVED defender=unsafe-component-guard
PUBLISH CELL mutant=P009 anchor=canonical-parent-resolution substitutions=1 fixture=symlink-leaf-data outcome=SURVIVED defender=symlink-leaf-guard
PUBLISH CELL mutant=P009 anchor=canonical-parent-resolution substitutions=1 fixture=symlink-parent outcome=SURVIVED defender=symlink-component-precheck
PUBLISH CELL mutant=P009 anchor=canonical-parent-resolution substitutions=1 fixture=symlink-parent-state outcome=SURVIVED defender=symlink-component-precheck
PUBLISH CELL mutant=P009 anchor=canonical-parent-resolution substitutions=1 fixture=resolved-outside outcome=SURVIVED defender=canonical-structural-containment
PUBLISH CELL mutant=P009 anchor=canonical-parent-resolution substitutions=1 fixture=hard-link outcome=SURVIVED defender=existing-leaf-guard
PUBLISH CELL mutant=P009 anchor=canonical-parent-resolution substitutions=1 fixture=unresolved-parent outcome=SURVIVED defender=natural-unresolved-parent
PUBLISH CELL mutant=P009 anchor=canonical-parent-resolution substitutions=1 fixture=existing outcome=SURVIVED defender=existing-leaf-guard
PUBLISH CELL mutant=P009 anchor=canonical-parent-resolution substitutions=1 fixture=scope-symlink outcome=SURVIVED defender=scope-symlink-guard
PUBLISH CELL mutant=P009 anchor=canonical-parent-resolution substitutions=1 fixture=scope-unresolved outcome=SURVIVED defender=canonical-scope-resolution
PUBLISH CELL mutant=P009 anchor=canonical-parent-resolution substitutions=1 fixture=unsafe-leaf outcome=SURVIVED defender=unsafe-leaf-guard
PUBLISH MUTANT P009 anchor=canonical-parent-resolution substitutions=1 killed=0 survived=12 void=0
PUBLISH CELL mutant=P010 anchor=final-structural-containment substitutions=1 fixture=absolute outcome=SURVIVED defender=absolute-path-guard
PUBLISH CELL mutant=P010 anchor=final-structural-containment substitutions=1 fixture=traversal outcome=SURVIVED defender=unsafe-component-guard
PUBLISH CELL mutant=P010 anchor=final-structural-containment substitutions=1 fixture=symlink-leaf-data outcome=SURVIVED defender=symlink-leaf-guard
PUBLISH CELL mutant=P010 anchor=final-structural-containment substitutions=1 fixture=symlink-parent outcome=SURVIVED defender=symlink-component-precheck
PUBLISH CELL mutant=P010 anchor=final-structural-containment substitutions=1 fixture=symlink-parent-state outcome=SURVIVED defender=symlink-component-precheck
PUBLISH CELL mutant=P010 anchor=final-structural-containment substitutions=1 fixture=resolved-outside outcome=SURVIVED defender=canonical-structural-containment
PUBLISH CELL mutant=P010 anchor=final-structural-containment substitutions=1 fixture=hard-link outcome=SURVIVED defender=existing-leaf-guard
PUBLISH CELL mutant=P010 anchor=final-structural-containment substitutions=1 fixture=unresolved-parent outcome=SURVIVED defender=canonical-parent-resolution
PUBLISH CELL mutant=P010 anchor=final-structural-containment substitutions=1 fixture=existing outcome=SURVIVED defender=existing-leaf-guard
PUBLISH CELL mutant=P010 anchor=final-structural-containment substitutions=1 fixture=scope-symlink outcome=SURVIVED defender=scope-symlink-guard
PUBLISH CELL mutant=P010 anchor=final-structural-containment substitutions=1 fixture=scope-unresolved outcome=SURVIVED defender=canonical-scope-resolution
PUBLISH CELL mutant=P010 anchor=final-structural-containment substitutions=1 fixture=unsafe-leaf outcome=SURVIVED defender=unsafe-leaf-guard
PUBLISH MUTANT P010 anchor=final-structural-containment substitutions=1 killed=0 survived=12 void=0
PUBLISH CELL mutant=P011 anchor=scope-symlink-guard substitutions=1 fixture=absolute outcome=SURVIVED defender=absolute-path-guard
PUBLISH CELL mutant=P011 anchor=scope-symlink-guard substitutions=1 fixture=traversal outcome=SURVIVED defender=unsafe-component-guard
PUBLISH CELL mutant=P011 anchor=scope-symlink-guard substitutions=1 fixture=symlink-leaf-data outcome=SURVIVED defender=symlink-leaf-guard
PUBLISH CELL mutant=P011 anchor=scope-symlink-guard substitutions=1 fixture=symlink-parent outcome=SURVIVED defender=symlink-component-precheck
PUBLISH CELL mutant=P011 anchor=scope-symlink-guard substitutions=1 fixture=symlink-parent-state outcome=SURVIVED defender=symlink-component-precheck
PUBLISH CELL mutant=P011 anchor=scope-symlink-guard substitutions=1 fixture=resolved-outside outcome=SURVIVED defender=canonical-structural-containment
PUBLISH CELL mutant=P011 anchor=scope-symlink-guard substitutions=1 fixture=hard-link outcome=SURVIVED defender=existing-leaf-guard
PUBLISH CELL mutant=P011 anchor=scope-symlink-guard substitutions=1 fixture=unresolved-parent outcome=SURVIVED defender=canonical-parent-resolution
PUBLISH CELL mutant=P011 anchor=scope-symlink-guard substitutions=1 fixture=existing outcome=SURVIVED defender=existing-leaf-guard
PUBLISH CELL mutant=P011 anchor=scope-symlink-guard substitutions=1 fixture=scope-symlink outcome=SURVIVED defender=canonical-scope-resolution
PUBLISH CELL mutant=P011 anchor=scope-symlink-guard substitutions=1 fixture=scope-unresolved outcome=SURVIVED defender=canonical-scope-resolution
PUBLISH CELL mutant=P011 anchor=scope-symlink-guard substitutions=1 fixture=unsafe-leaf outcome=SURVIVED defender=unsafe-leaf-guard
PUBLISH MUTANT P011 anchor=scope-symlink-guard substitutions=1 killed=0 survived=12 void=0
PUBLISH CELL mutant=P012 anchor=canonical-scope-resolution substitutions=1 fixture=absolute outcome=SURVIVED defender=absolute-path-guard
PUBLISH CELL mutant=P012 anchor=canonical-scope-resolution substitutions=1 fixture=traversal outcome=SURVIVED defender=unsafe-component-guard
PUBLISH CELL mutant=P012 anchor=canonical-scope-resolution substitutions=1 fixture=symlink-leaf-data outcome=SURVIVED defender=symlink-leaf-guard
PUBLISH CELL mutant=P012 anchor=canonical-scope-resolution substitutions=1 fixture=symlink-parent outcome=SURVIVED defender=symlink-component-precheck
PUBLISH CELL mutant=P012 anchor=canonical-scope-resolution substitutions=1 fixture=symlink-parent-state outcome=SURVIVED defender=symlink-component-precheck
PUBLISH CELL mutant=P012 anchor=canonical-scope-resolution substitutions=1 fixture=resolved-outside outcome=SURVIVED defender=canonical-structural-containment
PUBLISH CELL mutant=P012 anchor=canonical-scope-resolution substitutions=1 fixture=hard-link outcome=SURVIVED defender=existing-leaf-guard
PUBLISH CELL mutant=P012 anchor=canonical-scope-resolution substitutions=1 fixture=unresolved-parent outcome=SURVIVED defender=canonical-parent-resolution
PUBLISH CELL mutant=P012 anchor=canonical-scope-resolution substitutions=1 fixture=existing outcome=SURVIVED defender=existing-leaf-guard
PUBLISH CELL mutant=P012 anchor=canonical-scope-resolution substitutions=1 fixture=scope-symlink outcome=SURVIVED defender=scope-symlink-guard
PUBLISH CELL mutant=P012 anchor=canonical-scope-resolution substitutions=1 fixture=scope-unresolved outcome=SURVIVED defender=canonical-parent-resolution
PUBLISH CELL mutant=P012 anchor=canonical-scope-resolution substitutions=1 fixture=unsafe-leaf outcome=SURVIVED defender=unsafe-leaf-guard
PUBLISH MUTANT P012 anchor=canonical-scope-resolution substitutions=1 killed=0 survived=12 void=0
PUBLISH CELL mutant=P013 anchor=unsafe-leaf-guard substitutions=1 fixture=absolute outcome=SURVIVED defender=absolute-path-guard
PUBLISH CELL mutant=P013 anchor=unsafe-leaf-guard substitutions=1 fixture=traversal outcome=SURVIVED defender=unsafe-component-guard
PUBLISH CELL mutant=P013 anchor=unsafe-leaf-guard substitutions=1 fixture=symlink-leaf-data outcome=SURVIVED defender=symlink-leaf-guard
PUBLISH CELL mutant=P013 anchor=unsafe-leaf-guard substitutions=1 fixture=symlink-parent outcome=SURVIVED defender=symlink-component-precheck
PUBLISH CELL mutant=P013 anchor=unsafe-leaf-guard substitutions=1 fixture=symlink-parent-state outcome=SURVIVED defender=symlink-component-precheck
PUBLISH CELL mutant=P013 anchor=unsafe-leaf-guard substitutions=1 fixture=resolved-outside outcome=SURVIVED defender=canonical-structural-containment
PUBLISH CELL mutant=P013 anchor=unsafe-leaf-guard substitutions=1 fixture=hard-link outcome=SURVIVED defender=existing-leaf-guard
PUBLISH CELL mutant=P013 anchor=unsafe-leaf-guard substitutions=1 fixture=unresolved-parent outcome=SURVIVED defender=canonical-parent-resolution
PUBLISH CELL mutant=P013 anchor=unsafe-leaf-guard substitutions=1 fixture=existing outcome=SURVIVED defender=existing-leaf-guard
PUBLISH CELL mutant=P013 anchor=unsafe-leaf-guard substitutions=1 fixture=scope-symlink outcome=SURVIVED defender=scope-symlink-guard
PUBLISH CELL mutant=P013 anchor=unsafe-leaf-guard substitutions=1 fixture=scope-unresolved outcome=SURVIVED defender=canonical-scope-resolution
PUBLISH CELL mutant=P013 anchor=unsafe-leaf-guard substitutions=1 fixture=unsafe-leaf outcome=SURVIVED defender=existing-leaf-guard
PUBLISH MUTANT P013 anchor=unsafe-leaf-guard substitutions=1 killed=0 survived=12 void=0
PUBLISH MATRIX SUMMARY mechanisms=14 written_boundaries=13 natural_boundaries=1 mutants=13 fixtures=12 cells=156 killed=7 survived=149 void=0
```
