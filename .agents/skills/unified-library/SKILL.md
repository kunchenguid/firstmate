---
name: unified-library
description: >-
  Agent-only adapter for OSBAMBAM Unified Library lookups and brain.js memory
  recall. Load before querying OSBAMBAM memory or the Unified Library for
  decisions, preferences, dates, established facts, technical questions, known
  problems, or potential solutions.
user-invocable: false
metadata:
  internal: true
---

# unified-library

Use OSBAMBAM's Unified Library as the shared source-backed research layer.
Do not create another library, memory store, vector database, research index, or physical copy.
`bin/fm-unified-library.sh` is the Firstmate command surface; its header owns the exact flags and paths.
This skill owns when to load that surface and how to treat the results.

## When to query what

For decisions, preferences, dates, or established facts, recall OSBAMBAM memory:

```sh
bin/fm-unified-library.sh recall "<query>"
```

For technical questions, known problems, or potential solutions, search the Unified Library first and retrieve no more than three cards:

```sh
bin/fm-unified-library.sh search "<issue>"
```

Prefer verified cards; the library CLI already orders them first.
If the adapter reports `verified_finding: no verified relevant card`, do not invent a verified card.
Treat draft cards as prior art, not truth or authority.

## How to read a hit

Open only the relevant card and the cited source section:

```sh
bin/fm-unified-library.sh open <CARD-ID>
```

Trace provenance when the recommendation matters:

```sh
bin/fm-unified-library.sh trace <CARD-ID>
```

A card never overrides domain gates or Captain authority.
Never preload the whole library.
Never discard the original source.

## When the library is insufficient

Commission bounded research.
Route the resulting source through the existing OSBAMBAM Librarian research intake so it becomes a source-linked draft card.
Promote a card to verified only after its source locator, applicability, and cheapest rejection test are checked, and only through the library owner.
This adapter refuses those writes.
Print the owner commands with:

```sh
bin/fm-unified-library.sh writes
```

## After applying a card

Record whether it worked, failed, was mixed, or remains unknown:

```sh
bin/fm-unified-library.sh record-outcome <CARD-ID> {worked|failed|mixed|unknown} --evidence "<what happened>"
```

The adapter prints the OSBAMBAM library-owner command for that outcome and does not execute it; run the printed command so the outcome lands in the shared library where `trace` can see it.
