# Primary-source provenance

Maintainer: update links and verification date when the underlying C4 guidance changes.
Verified 2026-10-07 against Simon Brown's official site.
These instructions paraphrase the guidance; they do not bundle third-party example diagrams.
The official site identifies its text/example license as [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/); retain appropriate attribution if copying those materials into an output.

| Source | Decision it informs |
|---|---|
| [C4 model](https://c4model.com/) | C4 is independent of notation and tool. |
| [Diagrams](https://c4model.com/diagrams) | Choose useful zoom levels; no obligation to draw all four. |
| [System context diagram](https://c4model.com/diagrams/system-context) | One system, its people and neighboring systems. |
| [Container diagram](https://c4model.com/diagrams/container) | Logical applications/stores and communication; deployment separate. |
| [Container abstraction](https://c4model.com/abstractions/container) | Runtime boundaries; SDK/package distinction; owned buckets/databases. |
| [Component diagram](https://c4model.com/diagrams/component) | Decompose one container, retain supporting context. |
| [Component abstraction](https://c4model.com/abstractions/component) | Related functionality behind interfaces, inside a container. |
| [Dynamic diagram](https://c4model.com/diagrams/dynamic) | Ordered runtime collaboration; sequence or communication notation. |
| [Deployment diagram](https://c4model.com/diagrams/deployment) | System/container instances, deployment nodes and infrastructure. |
| [Notation](https://c4model.com/diagrams/notation) | Titles, type/responsibility labels, directional relationships and legends. |
| [Review checklist](https://c4model.com/diagrams/checklist) | Comprehensible elements and relationships for the intended reader. |

Project evidence classification, source-revision pinning, parse receipts and current/target separation are operational practices of this skill, not additional claims about mandatory official C4 notation.

## Validation checklist

- The title and boundary identify one system/container/environment and the state shown.
- The primary elements match that scope; every decomposition has a parent in the model.
- Every architectural element has a stable name, C4 type, responsibility and relevant technology.
- Every relationship has one direction, an action label and an inter-process protocol where relevant.
- The key explains all notation; abbreviations and line meanings are clear without color.
- Logical ownership, deployment and trust boundaries are distinguishable.
- Library, process, database and external-system classifications match source evidence.
- Current, target, fixture and observed-deployment claims are separately qualified.
- Dynamic participants and order agree with static structure and actual transaction/authority boundaries.
- Diagram syntax passed a named parser/render tool; visual readability was inspected if rendered images are delivered.
- User acceptance, deployment and destructive permissions were not inferred from modeling work.
