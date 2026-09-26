# Device and input checks

## Matrix selection

Use the project's required devices and widths first, adding samples that expose the actual content pressure.
When no samples are specified, propose 320/375/390 CSS-pixel phones, 768/820 tablet portrait, 1024/1180 tablet landscape, a narrow tablet split-view and a desktop regression sample as starting coverage, not acceptance thresholds.
Check portrait and landscape, resize while content or a dialog is open, and split-view where the supported platform provides it.
Combine touch, hardware keyboard and software keyboard coverage with the relevant route and state rather than assuming a viewport dimension proves an input mode.
Include supported iOS Safari and Android Chrome, identifying physical phone and tablet sessions separately from browser emulation.

## Layout and input observations

- Verify the viewport configuration allows zoom and the content reflows at the project's zoom/text-size requirements; inspect long localized content and enlarged text rather than scaling only an empty shell.
- Check content-based breakpoints, bounded media, grid track minima, flex shrinkability and meaningful table relationships at each available container width.
- Distinguish intentional region scrolling from accidental page overflow; exercise the scrolling region by touch and keyboard and confirm its name and essential actions remain reachable.
- Verify dynamic viewport height as browser chrome expands or collapses, using supported dynamic units with an appropriate fallback rather than assuming fixed `100vh` equals usable height.
- Check safe-area insets around fixed controls and content, including landscape and edge-to-edge screens where supported.
- Open the software keyboard on the lowest input, validate focus remains visible and the primary action remains reachable, then close it and confirm the layout recovers.
- Exercise hardware keyboard navigation, visible and unobscured focus, dialogs and return focus, accessible names, screen-reader behavior and reduced motion where relevant.
- Provide an operable alternative to hover for every action, tooltip or essential information; verify touch target size and spacing against project accessibility requirements.

A 44 by 44 CSS-pixel touch design target is a useful starting point, not a claim about formal accessibility conformance or an override of the project's standard.
Use standards and project exceptions as their own authority, and distinguish measured targets from usability observations.

## Evidence limits

For every observation record browser/version, OS, route/state, CSS viewport, orientation, input mode, physical-device model or emulation configuration, steps and result.
Emulation can demonstrate layout and simulated input but does not establish physical-device keyboard, safe-area, browser-chrome, performance or assistive-technology behavior.
Mark unavailable physical-device or assistive-technology axes unverified and state what was actually observed.
Do not turn a proposed matrix into a claim that testing occurred.
