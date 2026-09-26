---
name: mobile-tablet-ui
description: Adapt responsive web interfaces for phones and tablets when implementing mobile layout or input behavior; use UI quality evidence for general visual verification and platform guidance for native apps.
metadata:
  internal: true
---

# Mobile and tablet UI

Own the adaptation decision for responsive web content and input behavior on phones and tablets.
Read the project's authoritative templates, design tokens, supported browser/device contract and essential user journeys before changing layout.
Preserve those contracts and use the existing stack; this skill grants no product, approval, security or delivery authority.
For a native application, establish its platform and use the project's native guidance rather than treating CSS responsiveness as sufficient.

## Adaptation procedure

1. Identify the actual content pressure with long localized labels, dense data, media, error messages and user text in the smallest available container.
2. Start with a usable narrow layout, then add space-dependent enhancements where content needs them; verification widths are samples, never mandatory CSS breakpoints.
3. Use the existing tokens, fluid sizing, logical properties and container queries where supported; check grid minima and flex shrinkability before hiding overflow.
4. Preserve essential actions and relationships when changing navigation, toolbars or dense tables; use deliberate scrolling inside a named data region when that fits the authoritative design.
5. Read [device checks](references/device-checks.md) to select the phone/tablet/input matrix and validate the resulting adaptation.
6. Record the content pressure, adaptation, contract source, observed result and any unverified device behavior in the project's existing evidence surface.

When the task also requires general UI acceptance evidence, use [ui-quality-evidence](../ui-quality-evidence/SKILL.md) for the shared evidence matrix and attach these device checks to its rows rather than building another report.
[Provenance](references/provenance.md) identifies the reviewed base and retained notice.
