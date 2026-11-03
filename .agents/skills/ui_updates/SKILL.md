---
name: ui_updates
description: >-
  Enterprise-grade UI creation, modularization, and surgical update skill for Firstmate.
  Load before designing, modularizing, styling, refactoring, or updating UI components across any web project, and before briefing a crewmate on UI work.
  Enforces the 4-phase delivery protocol: (1) Visual Mockup Generation, (2) Captain Approval Gate (Lavish / Baseline-vs-Mockup Split-Slider), (3) Scoped Component Implementation, (4) Automated Verification with 0.000% VRT Blast Radius Tolerance.
user-invocable: true
metadata:
  internal: false
---

# ui_updates

The `ui_updates` skill governs all user interface development, refactoring, styling, and visual updates across all repositories in the fleet.
Its primary directive is **surgical change isolation with zero visual regressions**: modifying or introducing a UI component must never cause unintended CSS leakage, layout shifts, or behavioral regressions in any untouched surface.

---

## 1. Prime Invariants

1. **Zero Codebase Touch Before Approval**: Never edit, commit, or refactor production components or stylesheets until the proposed visual design has passed the Phase 2 Captain Approval Gate.
2. **Zero Global CSS Leakage**: Never write bare HTML element selectors (`button`, `input`, `select`, `label`, `table`) or pollute the global stylesheet (`styles.css`, `index.css`) for component-specific visual adjustments.
3. **Atomic Component Encapsulation**: Every component lives in its own dedicated directory with its co-located styles (`Component.tsx`, `Component.css`, `index.ts`), using strictly scoped BEM class prefixes (e.g., `.fqd-<component>__*`).
4. **Deterministic Visual Regression Testing (VRT)**: Untouched components and views must produce strictly **0 diff pixels (0.000% visual drift)** in automated pixelmatch verification.
5. **Functional Integrity Preserved**: Visual changes must always verify that underlying interaction handlers (clicks, toggles, sliders, form submits) continue to fire properly.

---

## 2. The 4-Phase Delivery Lifecycle

Every UI task—whether creating a brand new widget or tweaking button colors—must proceed through these four sequential phases:

```
+-----------------------------------------------------------------------------------+
|                        The 4-Phase ui_updates Pipeline                            |
+-----------------------------------------------------------------------------------+
|                                                                                   |
|  [PHASE 1] VISUAL MOCKUP GENERATION (Zero Codebase Touch)                         |
|            - Agent builds standalone mockup (.lavish/ or .mockups/)               |
|            - Zero production files modified                                       |
|                                                                                   |
|                                   |                                               |
|                                   v                                               |
|                                                                                   |
|  [PHASE 2] THE APPROVAL GATE (Captain Review & Sign-Off)                          |
|            - Agent presents the proposed design:                                  |
|              * Via Lavish (for live clicking, element inspection, color tweaks)   |
|              * AND/OR via Split-Slider: Current Live Baseline vs. Proposed Mockup |
|            - You slide between Current vs. Proposed to see the exact delta        |
|            - STOP: Agent cannot proceed to code without explicit "Approved"       |
|                                                                                   |
|                                   | (Captain explicit approval required)          |
|                                   v                                               |
|                                                                                   |
|  [PHASE 3] SURGICAL IMPLEMENTATION                                                |
|            - Only now does the crewmate touch the project code                    |
|            - Faithfully ports approved mockup into modular Component.tsx / .css   |
|            - Strict scoped BEM / CSS modules (zero global CSS edits)              |
|                                                                                   |
|                                   |                                               |
|                                   v                                               |
|                                   |                                               |
|  [PHASE 4] AUTOMATED VERIFICATION & BLAST-RADIUS PROOF                            |
|            - Full typecheck (`npm run typecheck:all`)                             |
|            - Functional tests (click handlers, state updates, drawer triggers)    |
|            - VRT 0.000% drift assertion: proves all untouched components had      |
|              strictly 0 diff pixels                                               |
|            - Ready to ship / PR                                                   |
|                                                                                   |
+-----------------------------------------------------------------------------------+
```

---

### Phase 1: Visual Mockup Generation (Sandbox Only)

Before touching a single file in the project's source tree:
1. Create a self-contained, interactive HTML mockup under `.lavish/` or `mockups/` (e.g. `.lavish/headroom-redesign.html`).
2. Include the real component DOM structure, CSS variables, and representative states (default, hover, active, disabled, loading).
3. If the change modifies an existing view, capture a screenshot of the current live baseline first:
   ```bash
   node scripts/verify-ui.mjs --capture-only
   ```
4. Do not touch `src/`, `web/src/`, or git-tracked production files in Phase 1.

---

### Phase 2: The Captain Approval Gate

The agent halts execution and presents the design to the Captain for review and sign-off:

1. **Option A: Lavish Editor Session (`lavish-axi`)**:
   - Serve the artifact: `lavish-axi .lavish/<artifact>.html`
   - The Captain opens the review URL in Chrome, clicks DOM elements directly to inspect styles, annotates modifications, and submits feedback.
   - The agent waits via `lavish-axi poll .lavish/<artifact>.html`.
2. **Option B: Before-and-After Split-Slider Comparison**:
   - The agent takes a snapshot of the Proposed Mockup and pairs it with the Current Live Baseline.
   - The agent compiles an interactive Split-Slider HTML report where the Captain can drag a divider left and right to inspect the exact visual delta.
3. **Hard Gate Requirement**:
   - **The agent MUST NOT proceed to Phase 3 without explicit approval from the Captain** (e.g., "Approved", "Proceed", "Shipshape").
   - If the Captain requests visual adjustments, make them in the Phase 1 mockup and repeat Phase 2 review.

---

### Phase 3: Surgical Implementation (Scoped CSS Shield)

Once approved, the crewmate ports the design into production code following strict modularization standards:

1. **Atomic Directory Structure**:
   ```
   web/src/components/<ComponentName>/
   ??? <ComponentName>.tsx     # Functional component & state
   ??? <ComponentName>.css     # Scoped BEM styles
   ??? index.ts                # Clean barrel export
   ```
2. **Strict Scoped BEM Conventions**:
   - Every class must be prefixed with the project / component namespace:
     ```css
     /* Good */
     .fqd-fleet-headroom { ... }
     .fqd-fleet-headroom__sim-buttons { ... }
     .fqd-fleet-headroom__sim-btn { ... }
     .fqd-fleet-headroom__sim-btn--active { ... }

     /* Forbidden: Unscoped tags */
     button { ... }
     input { ... }
     .active { ... }
     ```
3. **CSS Variable Localization**:
   - Define or override theme tokens at the component root:
     ```css
     .fqd-fleet-headroom {
       --card-bg: #111827;
       --accent-color: #3b82f6;
     }
     ```
   - Never override `:root` variables to style a single component.
4. **App Root Cleanliness**:
   - `App.tsx` or main page containers must only coordinate routing, global layout, and state. No inline 2,000-line monolithic JSX trees.

---

### Phase 4: Automated Verification & Blast-Radius Proof

Before declaring work ready or opening a PR, the crewmate executes the automated verification pipeline:

1. **Static Typecheck**:
   ```bash
   npm run typecheck:all
   ```
   Zero TypeScript errors permitted across all workspaces.

2. **Automated VRT & Blast-Radius Test**:
   ```bash
   npm run test:ui:vrt
   ```
   The VRT test harness launches headless Playwright against candidate and baseline builds across:
   - Desktop Viewport: `1280x900`
   - Mobile Viewport: `390x844`

3. **The 0.000% Blast Radius Invariant**:
   - **Target Component Scenario**: Visual diff is expected, isolated to the target element's bounding box, and documented.
   - **Untouched Scenarios (All other components)**: Must report **diff px: 0 (0.000% drift)**.
   - If even a single pixel shifts in an untouched component due to CSS cascade bleed or font-size inheritance, the test fails immediately.

4. **Functional Interaction Assertions**:
   - The test script must execute functional checks during the snapshot pass:
     - Click buttons and assert active state / aria attributes change.
     - Toggle column pickers / dropdowns and assert visibility toggles.
     - Move sliders and assert telemetry / calculation numbers update.
     - Verify zero uncaught browser console errors.

5. **Generate Visual Diff Report**:
   - The test runner generates `tests/vrt/report/index.html` with the interactive Split-Slider for easy final review.

---

## 3. Launch Brief Injection Template

When Firstmate briefs a crewmate or ship worker on any UI-related task, Firstmate must inject the following contract into the launch brief:

```markdown
### UI DELIVERY PROTOCOL: ui_updates SKILL ENFORCED
This task involves user interface modifications. You must strictly follow `.agents/skills/ui_updates/SKILL.md`:
1. **Phase 1 Mockup**: Create a standalone HTML prototype in `.lavish/` or `mockups/` first. Do NOT edit production code yet.
2. **Phase 2 Approval Gate**: Request review and wait for the Captain's explicit approval before proceeding to Phase 3.
3. **Phase 3 Scoped CSS**: Implement using atomic component directories and strict BEM class prefixes. Do NOT add bare element selectors to global CSS.
4. **Phase 4 Verification**: Run `npm run test:ui:vrt`. Verify functional interactions and confirm 0.000% visual drift on all untouched components.
```

---

## 4. Rollback and Remediation Protocol

If `npm run test:ui:vrt` detects unexpected drift on untouched components:
1. Inspect `tests/vrt/report/index.html` to identify which untouched component drifted and examine the red pixel diff overlay.
2. Check the candidate CSS for:
   - Bare element selectors (`button`, `input`, `p`, `span`, `div`).
   - Leaking flex/grid sizing rules (`margin`, `padding`, `box-sizing` without containment).
   - Global class name collisions.
   - Unscoped `:root` variable overrides.
3. Re-scope the offending rule to the component BEM container and re-run `npm run test:ui:vrt` until all untouched components report **0 diff px**.
