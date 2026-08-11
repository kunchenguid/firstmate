# Mission control board evidence

`before-board.png` and `after-board.png` are the rendered mission control board before and after the calm light redesign.

`before-deferred-tabs.png` and `after-deferred-tabs.png` are the same board before and after the deferred shelf and the navigation tabs, at desktop width.
`before-mobile.png` and `after-mobile.png` are that same pair at 390px, the width the captain reads it at.
In the after images three of the six calls have been set aside, so they sit in the shelf, which is shown open; on the board itself the shelf is closed by default.

`before-controls.png` and `after-controls.png` are the same board served through Lavish without and with `--controls`, at desktop width, and `before-controls-mobile.png` and `after-controls-mobile.png` are that pair at 390px with a merge confirmation open.
The after images show each row carrying only the controls it can resolve: the two backlog-held decisions offer an answer and setting aside, the task-level decision offers an answer alone because it has no backlog row to set aside, and the PR offers a merge request and a reply.

`controls-served-statically.png` is the safety property that matters most, so it is captured rather than asserted in prose: it is the very same `--controls` file opened directly with no Lavish server, and it renders as the read-only board with no controls and no dead affordances.

`after-freshness-known-desktop.png` and `after-freshness-known-mobile.png` show the existing generated-timestamp header at desktop width and 390px.
`after-freshness-unknown-desktop.png` and `after-freshness-unknown-mobile.png` show a snapshot without that timestamp reading `live · rendered unavailable` in the header and `rendered unavailable` in the footer without wrapping or colliding with its live indicator.

`before-decision-context-desktop.png` and `after-decision-context-desktop.png` show an ordinary five-item Awaiting Decision list at 1280px with the first Answer form open.
`before-decision-context-mobile.png` and `after-decision-context-mobile.png` show the same state at exactly 390px by 844px.
The after images retain the complete long question, add the explicit private decision-aid link, give Answer and Set aside distinct calm treatments, and put the exact recorded question in the Answer prompt without horizontal overflow.

`before-decision-options-desktop.png` and `after-decision-options-desktop.png` show the same structured binary decision through the direct board-reply service at 1280px before and after explicit quick-answer buttons.
`before-decision-options-mobile.png` and `after-decision-options-mobile.png` show the full same board at exactly 390px by 844px.
The after images keep `Write your own answer` beside the two explicit labels, while the before images retain the legacy Answer control only.

`before-local-report-mobile.png` and `after-local-report-mobile.png` reproduce the reported 390px Qwen bounded-judgment card before and after local report paths stopped being links.
The after image identifies `data/local-lane-bakeoff-v2-powered/report.md` as local report context and removes the navigation chevron; the browser regression additionally performs a real emulated mobile touch on that exact text and confirms the page does not navigate.

`before-token-integration-desktop.png` and `after-token-integration-desktop.png` show the full desktop board System view before and after the local pace-first allowance integration.
`before-token-integration-mobile.png` and `after-token-integration-mobile.png` show the same comparison at the captain's 390px viewport.
The after view keeps fleet health distinct, presents each primary allowance window once, and leaves automatic balancing collapsed.

`before-new-work-intake-desktop.png` and `after-new-work-intake-desktop.png` show the Decisions view before and after the board gained its one-shot Start something new composer at 1280px by 844px.
`before-new-work-intake-mobile.png` and `after-new-work-intake-mobile.png` show the same comparison at exactly 390px by 844px.
The after images keep the new-work intake visually separate from the continuing Ask-firstmate conversation through its labelled slate treatment, larger heading, explanatory copy, and deliberate space between the two cards.

`after-fact-form-desktop.png` and `after-fact-form-mobile.png` show the schema-driven portfolio fact form at 1280px and 390px.
`after-fact-validation-desktop.png` and `after-fact-validation-mobile.png` show every missing required field by its human label beside the still-reachable submit control.
`after-fact-group-partial-desktop.png` and `after-fact-group-partial-mobile.png` show one grouped fact answered and one still open with `1 of 2 facts provided` remaining visible.
`after-fact-legacy-desktop.png` and `after-fact-legacy-mobile.png` show a fact decision with no schema retaining the expected-answer textarea.

`after-answer-choice-desktop.png` and `after-answer-choice-mobile.png` show the direct service's truthful `Answer received` presentation after a choice submission at desktop and mobile widths.
`after-answer-fact-desktop.png` and `after-answer-fact-mobile.png` show the same durable-record acknowledgement after a structured fact submission, with the remaining decision and new-work surfaces still fitting at both widths.
`after-answer-rejected-desktop.png` and `after-answer-rejected-mobile.png` show a refused oversized answer remaining open, editable, and explicitly marked `Not sent` rather than receiving an acknowledgement.

All image evidence here is rendered from synthetic fixture homes rather than a live fleet.
The local-report pair reproduces only the reported card label and local path, never the report contents; the other fixtures carry no private project, decision, or PR data.
The fixtures pin the render clock so the comparisons are not affected by the day they were captured.

The separate privacy-safe live-fleet check is `FM_MISSION_CONTROL_LIVE_HOME=<active-home> FM_MISSION_CONTROL_REQUIRE_LIVE=1 tests/fm-mission-control.test.sh`.
It generates the board directly from the active fleet, uses real Chrome at 390 by 844, regenerates the file at a nonzero reading position, performs a full reload, and reports only pass/fail geometry rather than fleet identities or records.
The required acceptance run passed on 2026-08-08 with `ok - a privacy-safe live fleet stays anchored across regeneration and full reload`; no fleet text, identity, screenshot, or record was written into this evidence directory.

That the selected tab survives the board's managed reload was checked in Chrome after selecting the Projects tab and reloading the document without a fragment; the Projects panel remained selected.
The same browser regression replaced the served HTML with fixtures that inserted rows above the current decision or temporarily omitted that decision, then verified the exact reading offset and identity-bound draft survived when the row returned.

The freshness header was verified on 2026-08-11 with `chrome-devtools-axi 0.1.27` at 1280px by 844px and 390px by 844px.
Both timestamp states kept the header inside the viewport, and the unavailable label remained on one line at 390px.

The allowance integration was verified on 2026-08-08 with `chrome-devtools-axi 0.1.27`.
The desktop run used `chrome-devtools-axi emulate --viewport '1280x1000x1'`, rendered all three allowance cards at 228.28125px by 254px, and returned `overflow: false` for the 1280px document.
The mobile run used `chrome-devtools-axi emulate --viewport '390x844x3,mobile,touch'`, rendered all three cards at 320px by 261.25px, and returned a 390px document width with `overflow: false`.
At that same 390px viewport, the Decisions rows measured 352px wide, the Projects cards measured 354px wide, and both views returned `overflow: false`, preserving the existing decision and in-progress content around the new System view.

The decision-context evidence was verified on 2026-08-08 with `chrome-devtools-axi 0.1.27` and the same isolated browser session used for the functional inspection.
The desktop and mobile checks returned document widths of 1280px and 390px respectively, reported no horizontal overflow, and confirmed that the Answer form was open in all four images.
The after checks additionally confirmed that the explicit decision-aid link was present.

The decision-options evidence was verified on 2026-08-09 with `chrome-devtools-axi 0.1.27` at 1280px by 900px and 390px by 844px.
The mobile after render returned a 390px document width, two 44px-high option buttons inside the viewport, and the unchanged free-text affordance.
The real-browser regression submits one option and one typed answer through the same `answer` request path.

The local-report evidence was verified on 2026-08-08 with `chrome-devtools-axi 0.1.27` at exactly 390px by 844px.
Chrome's accessibility snapshot exposed the before card as a link to the nonexistent local file route, while the after card exposed the same path only as static text.

The new-work intake evidence was verified on 2026-08-09 with Chrome and `chrome-devtools-axi 0.1.27` against the same synthetic fixture before and after the change.
The browser inspection used `chrome-devtools-axi emulate --viewport '1280x844x1'` and `chrome-devtools-axi emulate --viewport '390x844x3,mobile,touch'`.
The 390px inspection returned `{"w":390,"h":844,"overflow":false}`, and the real-browser regressions in `tests/fm-mission-control.test.sh` and `tests/fm-board-reply.test.sh` confirmed that both composers fit without horizontal overflow, remain visually distinct, and submit through separate intents.

The fact-intake evidence was verified on 2026-08-10 with Chrome and `chrome-devtools-axi 0.1.27` against a synthetic grouped portfolio reconciliation.
The browser inspection used `chrome-devtools-axi emulate --viewport '1280x900x1'` and `chrome-devtools-axi emulate --viewport '390x844x3,mobile,touch'`.
The 390px inspection returned five aligned field controls from 47px to 343px, a full-width 320px by 44px submit control, the grouped progress label, and `overflow: false`.
Submitting the blank form returned a required-facts refusal from the direct reply service and displayed `answer needs required facts: Account name, Statement date, Market value` immediately above that submit control; stable field keys remain internal.

`bin/fm-evidence-check.sh --local docs/evidence/mission-control` returned `fm-evidence-check: ok pairs_checked=14 identical_opted_out=0`.

See [`docs/mission-control.md`](../../mission-control.md) for what the board shows and where each value comes from.
