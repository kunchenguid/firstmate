---
status: proposed
---

# Public Visual Evidence with Private Outputs

Firstmate will adapt the useful upstream capabilities through original MIT-licensed clean-room implementations while keeping produced evidence private by default.
The authoritative domain language and approval contract remain in [Firstmate Context](../../CONTEXT.md).

## Decision

- The upstream prose and code are not vendored because Firstmate needs an independently maintainable implementation under its own MIT license.
- The code-structure principles are folded into Firstmate's conditional **Structural Review**, which deepens only the responsibility affected by the requested change rather than becoming a separate universal skill.
- One public **Visual Evidence** skill owns both comparison and behavior evidence so capture, privacy, storage, publication, and cleanup do not acquire competing implementations.
- Version 1 supports macOS browser capture with screenshot-focused comparison and behavior evidence rather than native desktop capture or video.
- Evidence is packaged in versioned **Evidence Bundles**, while originals and other **Private Outputs** remain in the ignored **Local Evidence Store** unless an exact authorized copy is exported or published.
- Portable manifests record immutable **Privacy Scan Result** data rather than later controller-owned acceptance state, under the exact contract in [Firstmate Context](../../CONTEXT.md).
- The public skill includes a trusted non-browser **Local Evidence Controller** so standalone installations own private storage, decision intake, revalidation, export, cleanup, and no-mistakes consent routing without depending on Firstmate.
- A local review may grant **Evidence Import Consent** under the exact bindings defined in [Firstmate Context](../../CONTEXT.md), but only no-mistakes may grant **Publication Approval** after protected staging, revalidation, and its own exact preview.
- **Approved Evidence Import** is a narrow producer-neutral no-mistakes interface with no Firstmate-specific or **Visual Evidence**-specific behavior.
- **Visual Evidence** version 1 is held until **Approved Evidence Import** supports approved GitHub pull request publication end to end, even if local export is implemented and tested earlier.
- Delivery is coordinated as Firstmate **Structural Review** guidance first, no-mistakes **Approved Evidence Import** second, and complete Firstmate **Visual Evidence** version 1 after that prerequisite is available.
- The active trusted host controller routes exact consent to the owning worker and no-mistakes flow, while Firstmate does not mutate project pull requests itself.

## Considered Options

- Vendoring the upstream skills was rejected because copied prose and code would blur provenance, licensing, and long-term ownership.
- Separate comparison and behavior skills were rejected because their shared safety lifecycle needs one owner.
- A standalone HTML-only review surface was rejected because it would expose decisions without a trusted actor that can revalidate or apply them.
- Releasing version 1 with local export alone was rejected because it would not satisfy the promised approved pull request workflow and could encourage bypassing the validated publication path.
- A cryptographically trusted external receipt providing one publication approval was deferred because signer enrollment, protected keys, revocation, replay handling, and trust portability add substantial security and maintenance scope.

## Consequences

- The reusable implementation can be public without making any evidence public by default.
- Standalone use has the same private-by-default lifecycle and exact-decision checks as Firstmate-integrated use rather than an HTML-only subset.
- Pull request publication requires two explicit authority steps and no project-controlled manifest, JSON, configuration, automatic approval, or `--yes` path can replace them.
- No-mistakes remains the producer-neutral owner of protected evidence staging and pull request publication.
- Version 1 release timing depends on the coordinated no-mistakes delivery rather than only on Firstmate implementation progress.
- Broader operating-system support, native capture, video, or external-signer trust require later decisions rather than accidental expansion of version 1.
