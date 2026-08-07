# Mission control board evidence

`before-board.png` and `after-board.png` are the rendered mission control board before and after the calm light redesign.

`before-deferred-tabs.png` and `after-deferred-tabs.png` are the same board before and after the deferred shelf and the navigation tabs, at desktop width.
`before-mobile.png` and `after-mobile.png` are that same pair at 390px, the width the captain reads it at.
In the after images three of the six calls have been set aside, so they sit in the shelf, which is shown open; on the board itself the shelf is closed by default.

All of these are rendered from a synthetic fixture home, never from a real fleet, so they carry no private project, decision, or PR data.
The fixture pins the render clock so the comparison is not affected by the day it was captured.

That the selected tab survives the board's own reload was checked in Chrome against a board rendered with a three second interval: the System tab was selected, a page-scoped marker was set to prove a real navigation happened, and after two reload cycles the marker was gone, the URL fragment had been dropped by the meta refresh, and the System panel was still the selected one.
That is why the selected tab is remembered in the browser rather than carried in the URL.

See [`docs/mission-control.md`](../../mission-control.md) for what the board shows and where each value comes from.
