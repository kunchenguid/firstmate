# Mission control board evidence

`before-board.png` and `after-board.png` are the rendered mission control board before and after the calm light redesign.

`before-deferred-tabs.png` and `after-deferred-tabs.png` are the same board before and after the deferred shelf and the navigation tabs, at desktop width.
`before-mobile.png` and `after-mobile.png` are that same pair at 390px, the width the captain reads it at.
In the after images three of the six calls have been set aside, so they sit in the shelf, which is shown open; on the board itself the shelf is closed by default.

`before-controls.png` and `after-controls.png` are the same board served through Lavish without and with `--controls`, at desktop width, and `before-controls-mobile.png` and `after-controls-mobile.png` are that pair at 390px with a merge confirmation open.
The after images show each row carrying only the controls it can resolve: the two backlog-held decisions offer an answer and setting aside, the task-level decision offers an answer alone because it has no backlog row to set aside, and the PR offers a merge request and a reply.

`controls-served-statically.png` is the safety property that matters most, so it is captured rather than asserted in prose: it is the very same `--controls` file opened directly with no Lavish server, and it renders as the read-only board with no controls and no dead affordances.

`before-token-integration-desktop.png` and `after-token-integration-desktop.png` show the full desktop board System view before and after the local pace-first allowance integration.
`before-token-integration-mobile.png` and `after-token-integration-mobile.png` show the same comparison at the captain's 390px viewport.
The after view keeps fleet health distinct, presents each primary allowance window once, and leaves automatic balancing collapsed.

All of these are rendered from a synthetic fixture home, never from a real fleet, so they carry no private project, decision, or PR data.
The fixture pins the render clock so the comparison is not affected by the day it was captured.

That the selected tab survives the board's own reload was checked in Chrome against a board rendered with a three second interval: the System tab was selected, a page-scoped marker was set to prove a real navigation happened, and after two reload cycles the marker was gone, the URL fragment had been dropped by the meta refresh, and the System panel was still the selected one.
That is why the selected tab is remembered in the browser rather than carried in the URL.

The allowance integration was verified on 2026-08-08 with `chrome-devtools-axi 0.1.27`.
The desktop run used `chrome-devtools-axi emulate --viewport '1280x1000x1'`, rendered all three allowance cards at 228.28125px by 254px, and returned `overflow: false` for the 1280px document.
The mobile run used `chrome-devtools-axi emulate --viewport '390x844x3,mobile,touch'`, rendered all three cards at 320px by 261.25px, and returned a 390px document width with `overflow: false`.
At that same 390px viewport, the Decisions rows measured 352px wide, the Projects cards measured 354px wide, and both views returned `overflow: false`, preserving the existing decision and in-progress content around the new System view.
`bin/fm-evidence-check.sh --local docs/evidence/mission-control` returned `fm-evidence-check: ok pairs_checked=7 identical_opted_out=0`.

See [`docs/mission-control.md`](../../mission-control.md) for what the board shows and where each value comes from.
