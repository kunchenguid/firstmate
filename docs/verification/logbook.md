# Logbook verification

This page records repeatable maintainer evidence for the active `/logbook` guarantees.
The authoritative product, schema, transition, safety, and polling contract remains [the internal logbook skill](../../.agents/skills/logbook/SKILL.md).

## Current evidence

Verified on 2026-08-27 on macOS with Node.js 26.5.0, Luxe Editor 0.3.5, `chrome-devtools-axi` 0.1.26, and Chrome 151.0.0.0.

The focused maintained suite was run through the repository test owner:

```sh
bin/fm-test-run.sh tests/fm-logbook.test.sh tests/fm-logbook-render.test.sh
```

The result was:

```text
FM_TEST_SUMMARY total=2 failed=0 skipped_gate=0
ok - start creates one private page and update atomically changes only its delimited payload
ok - malformed JSON and fake progress claims refuse without touching the page
ok - meaningful updates retain all embedded milestone history newest first
ok - retained history larger than two MiB remains readable and mutable
ok - mission text cannot escape the private logbook path
ok - intermediate symlinks cannot escape the logbook root
ok - one live writer owns each mutation
ok - a vanished writer lock retries the atomic claim
ok - duplicate qualifying updates are refused before publication
ok - retained milestone fingerprints refuse non-immediate duplicates
ok - malformed milestone ordering is refused before publication
ok - close records the final outcome, preserves the page, and retires active registration
ok - close retries retire a stale registration after page publication
ok - Luxe-like opaque rendering succeeds without any sibling-resource request
ok - missing and malformed embedded data leave a usable shell with a visible stale warning
ok - manual refresh reloads the existing page and shows the atomically embedded update
ok - embedded captain values render as text rather than browser markup
ok - retained milestone history is not capped by boundary item limits
```

The renderer regression deliberately gives the page an opaque Luxe-like origin and a `fetch` implementation that always throws.
A valid page still renders and reports zero fetch calls, pinning the no-subresource boundary that replaced the rejected sibling-JSON design.

## Real Luxe and browser proof

A generated mission page was opened through Luxe without arming a poll:

```sh
lavish-axi "$page"
```

Luxe returned one session URL and rendered the embedded page in its sandboxed artifact frame.
A real Chrome accessibility snapshot showed the mission title, active state, update time and age, all three `Done / Now / Next` cards, `1 of 3 gates complete`, the blocker empty state, and the timestamped first milestone.

The page was then updated through the public helper while that Luxe session remained open:

```sh
FM_HOME="$verification_home" node .agents/skills/logbook/logbook.mjs update \
  --mission 'Browser refresh proof' --input "$verification_update"
```

The Refresh progress button was clicked through `chrome-devtools-axi` in the existing Luxe page.
The next real-browser snapshot, without opening a new Luxe session, contained:

```text
The cache-busted browser refresh passed.
Cache-busted browser refresh passed
```

This proves the current Luxe session reloads the same self-contained HTML artifact through a fresh query and reads the newly embedded validated payload.
It also proves routine payload changes need neither a sibling request nor an active feedback poll.

## Refresh procedure

Re-run the focused suite after any change under `.agents/skills/logbook/`, then repeat the real Luxe proof with a fresh private `FM_HOME` inside a disposable directory.
Keep polling off.
Open the generated page once, capture the initial browser snapshot, update it through `logbook.mjs`, click Refresh progress in the existing Luxe page, and capture the changed snapshot.
A passing refresh must preserve the same Luxe session URL, show the new milestone and snapshot, and make no local subresource request.
