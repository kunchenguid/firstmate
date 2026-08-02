# Browser capability architecture

Firstmate's browser capability is a deterministic custody layer, not a raw browser automation shortcut.

`bin/fm-browser.sh` is the sole public lifecycle, state, cleanup, and receipt owner.
Its header and help own command syntax, state fields, receipt schema, cleanup postconditions, and disabled-mode boundaries.
The agent-only `browser-capability` skill owns intake, mode classification, authority, and escalation.

## Placement

Browser custody sits beside the runtime backend rather than inside it.
Runtime backends own worker terminals and task endpoints.
The browser owner separately binds browser sessions to the existing task, project, and worktree records.
A browser session never grants project-write authority.

## Current implementation boundary

The initial implementation is disabled by default.
It supports public-ephemeral planning and mocked lifecycle tests.
Real browser launch is refused until a separate verified engine stage lands.
Authenticated, durable, personal-profile, private/local/admin, upload/download/capture, extension, and write-capable modes are disabled.

## Engine split

Pinned `agent-browser` is the intended primary visible-owned engine after verification.
The current adapter refuses real launch and exposes only source-only capability facts.
`chrome-devtools-axi` remains public-light and non-owning until its wrapper and transport are pinned and pass the same custody suite.
There is no silent fallback between engines, headless and visible mode, owned and attached mode, or ephemeral and persistent state.

## Identity model

PID alone is not identity.
A live browser record must bind home, task, project, worktree, engine version, session, namespace, profile identity, origin policy, auth class, action tier, process identity, window identity, TTL, lifecycle state, and cleanup postconditions.
The mocked core records these fields without launching a browser.
A future real engine must replace mocked identities with verified process, profile, endpoint, and window evidence before support can be claimed.

## Lifecycle

The normal lifecycle is `absent -> creating -> visible-ready -> active -> closing -> closed -> cleaning -> cleaned`.
Failures move to `incident` or `quarantined` when ownership or cleanup cannot be proved.
Restart reconciliation is inspect-only by default.
It must not attach, navigate, relaunch, kill, or delete merely because a record exists.

## Receipts

Every mutating session operation appends a value-redacted receipt.
Receipts are hash chained inside the session record and copied to `data/browser/v1/receipts/<year-month>.jsonl`.
They may name opaque handles, task ids, result codes, origin aliases, and cleanup postcondition labels.
They must not contain cookies, storage, full private URLs, DOM text, screenshots, headers, profile contents, or bearer endpoints.

## Cleanup

Task cleanup refuses while a task has an unclean browser binding.
Cleaned means the browser owner has proved the session inactive, endpoint gone, exact process identity gone, profile removed or deliberately quarantined, lease removed, and a durable receipt written.
The initial mocked lifecycle proves the refusal and receipt paths without touching Chrome.
A future real engine must prove exact endpoint, process, window, profile, and lease cleanup.

## Visibility helper

`native/fm-window-helper/fm-window-helper.sh` is a disabled helper contract and mock surface.
It intentionally does not call AppKit, CoreGraphics, Apple Events, Accessibility, Screen Recording, keyboard, mouse, screenshots, or browser APIs.
A later signed macOS helper may implement the same narrow value-safe receipt after no-TCC verification.
Until then, real foreground support is not claimed.

## Security boundary

The wrapper is a deterministic custody layer, not a same-UID sandbox.
Real authenticated mode remains disabled until enclave or equivalent OS-isolation tests prove that sibling workers cannot read profile state, control artifacts, or browser session capability.
The captain may authorize browser-held personal-session use later, but raw cookie values must never enter model, tool, report, log, environment, command line, project, or Firstmate state.
