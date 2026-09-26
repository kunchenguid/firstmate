# UI evidence matrix

## Reproducible row

Use one row per selected route/state/viewport/theme/locale combination, retaining the project's required coverage.
Record contract/template revision, application revision, fictional fixture, browser/OS/version, viewport and device-pixel ratio, fonts, theme, locale, steps, expected result, observed result, verdict and artifact or executable-test pointer.
Separate observed facts from inferred behavior and mark unavailable axes unverified; use not applicable only with a concrete reason.
For a large combination space, explain the risk-based selection and uncovered combinations without dropping explicitly required cases.
Include populated, empty, loading, error, validation and permission-dependent states when applicable, plus the interactions that enter and leave them.

## Comparisons

For template parity compare shell placement, hierarchy, density, fixed and scrolling regions, data/table composition, filters, actions, dialogs, badges and responsive behavior against each corresponding source.
Record a separate visual/structural verdict; passing click tests or matching a bounding box cannot establish parity.
For visual regression stabilize fixtures, fonts, animations, browser, OS and screenshot settings, then use the project's existing baseline and diff tooling.
Compare meaningful regions and explain tolerated changes; do not refresh baselines merely to erase a difference.
Where authorized and useful, perturb a layout in an isolated fixture to demonstrate the check detects a real regression, then restore it.
Use observable readiness assertions rather than assuming network idleness means the UI is ready.

## Interaction and accessibility

Exercise sequential keyboard navigation, activation, escape behavior, dialog focus containment and restoration, and visible unobscured focus through real interactions.
Check accessible roles/names, validation announcements, screen-reader flows where available, contrast, non-hover access and reduced motion against the project's requirements.
Use existing automated accessibility checks as one evidence source and describe the manual coverage separately; a green scan is not full conformance.
Check page and intended region overflow, zoom/reflow, long localized text, text-size changes and clipped controls across the selected matrix.
Record both the reachable content and any deliberately scrolling regions rather than hiding overflow to make a dimensional assertion pass.

## Report limits

Provide reproducible failures and honest coverage limits without converting internal evidence into a new review presentation.
Preserve the project's required live review, its temporary application origin and its approval owner.
Do not claim a browser screenshot proves touch, physical devices or assistive technologies that were never exercised.
