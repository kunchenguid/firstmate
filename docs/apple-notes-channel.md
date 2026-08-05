# Apple Notes channel

The Apple Notes channel is a disabled-by-default, low-authority mailbox between one exact iCloud folder tree and the primary Firstmate home.
It is not an authenticated replacement for the trusted private phone terminal.
The channel permits only status, summarize, scout, plan, and local draft intents.
Every destructive, irreversible, credential, security, money, external publication, production, merge, permission, account, sharing, installation, login, or scope-expanding action requires a current concrete confirmation through the trusted private phone terminal.

`bin/fm-notes-channel.sh` is the single owner of commands, schemas, state transitions, provider containment, local file safety, emergency disable, and uninstall definitions.
`bin/fm-notes-bridge-build.sh` owns build and release refusal.
The `apple-notes-channel` agent-only skill owns notification handling and low-authority routing.

## Fixed scope

The only supported Notes tree is an unshared tree in the captain's iCloud Notes account:

```text
Firstmate/
  00 Guide/
  10 Inbox/
  20 Acknowledgments/
  30 Outbox/
  90 Archive/
    Inbound/
    Acknowledgments/
    Outbound/
```

Pairing is the sole account/folder metadata discovery operation.
It looks for exactly one `iCloud` account and exactly one tree with these names, verifies that every folder is unshared, verifies exact parents, and verifies that every operational folder is empty.
It never reads a note body during pairing.
Ordinary operation uses the paired account and folder IDs only.
A missing, renamed, moved, duplicated, shared, or reparented object disables the channel rather than searching or repairing.

The dedicated bridge exposes only status, fixed-tree pairing, exact binding probe, bounded Inbox metadata listing, bounded listed-note read, exact owned-note reconciliation, and new ACK/Outbox note creation.
It has no arbitrary script, target, folder, Notes search, attachment, URL-opening, delete, update, move, share, lock, unlock, account mutation, private-store, Accessibility, Full Disk Access, Shortcuts, network, plug-in, or self-update API.

## Local layout

The disabled production config is `config/apple-notes-channel.json` with mode `0600`.
Durable captures, source identities, outbound intents, redacted receipts, and the hash-chained audit live under `data/apple-notes-channel/` with private directory and file modes.
Locks, stability observations, claims, offers, pending writes, health, and the emergency marker live under `state/apple-notes-channel/`.
The authenticated bounded-check definition is `state/notes-watch.check.sh` with its byte-bound `state/notes-watch.check-trust` record.
The definition is absent until the separately approved recurring stage.

Production entrypoints check `state/apple-notes-channel/DISABLED` and the config's `enabled` flag before constructing a provider.
The fake provider is synthetic-only, records a body-free call spy, and never invokes Notes or TCC.

## Current release blocker

On the verified Notes 4.13 installation, the scripting definition declares only the sandbox access group `com.apple.Notes.openlocation`.
That group covers the prohibited open-location command and does not cover account, folder, note, or attachment CRUD.
The required fixed metadata/read/create operations therefore need the target-wide `com.apple.security.temporary-exception.apple-events` sandbox entitlement for `com.apple.Notes`.
That target-wide exception is broader than the reviewed operation-level sandbox design.
`bin/fm-notes-bridge-build.sh release` refuses before compilation or signing rather than adding it.

The installed code-signing catalog also has one valid but unrecognized identity and no identity classified as Apple Development or Developer ID Application.
A live pilot requires an operation-level sandbox route or a new explicit security review of the target-wide Notes exception, plus a suitable Apple signing identity.
Fixture builds are ad-hoc signed with hardened runtime and App Sandbox but no Apple Events entitlement.
They are never live-pilot builds.

Inspect these facts without launching Notes, sending Apple Events, or requesting TCC:

```sh
bin/fm-notes-bridge-build.sh inspect --json
```

Build a non-live fixture app:

```sh
bin/fm-notes-bridge-build.sh fixture --output /private/tmp/FirstmateNotesBridge.app
```

## Offline verification

Initialize an isolated home against a deterministic fake provider fixture:

```sh
FM_NOTES_TEST_NOW=100 \
  bin/fm-notes-channel.sh --home /private/tmp/fm-notes-home \
  init-fake --fixture /private/tmp/fm-notes-fixture.json
```

The first stable read records only a digest.
A second identical observation after at least 15 seconds may commit the immutable capture.
The body-free check output appears only after capture, receipt, checkpoint, and offer publication succeed.

Run the focused behavior and build suites:

```sh
bash tests/fm-notes-channel.test.sh
bash tests/fm-notes-bridge-build.test.sh
```

The fake provider call spy is available through the public owner:

```sh
bin/fm-notes-channel.sh --home /private/tmp/fm-notes-home provider-log
```

## Captain-present outbound test sequence

Do not begin this sequence while the current release blocker remains.
The sequence is ready for a newly reviewed release that passes `release`, signature, entitlement, hash, and independent source verification.
It sends exactly one harmless outbound note and does not install recurring checks or login behavior.

1. Keep the official checkout clean and build the generated runtime candidate from current official `origin/main` with the Calm, prepared persistence, and Notes channel slots.
2. Validate the candidate without changing the active runtime pointer.
3. Verify the exact release app at its fixed path `$HOME/Applications/Firstmate Notes Bridge.app` with `codesign --verify --deep --strict`, its designated requirement, its bundle ID `dev.firstmate.notes-bridge`, its executable SHA-256, hardened runtime, App Sandbox, and the reviewed Notes-only entitlement route.
4. Initialize production while disabled by passing only the pinned app hash and designated requirement to `init-production`.
5. In Notes on the Mac, manually create one fresh empty unshared `Firstmate` tree with the exact folders above in the intended iCloud account.
6. Do not open, count, search, export, or read any existing note body.
7. With the captain present, run `pair-production --request-automation` once and redirect its private JSON to a new mode-`0600` file under `data/apple-notes-channel/`.
8. Accept only the expected Automation prompt for the exact `Firstmate Notes Bridge` app controlling Notes.
9. Deny any Full Disk Access, Accessibility, Files and Folders, Input Monitoring, Screen Recording, App Management, admin, account, or other permission prompt.
10. Review the pairing result's binding hash and empty-tree result, then feed the same private JSON to `record-pairing --binding-hash <exact-hash>`.
11. Enable only `outbound-test` mode.
12. Run `prepare-outbound-test` once and record its deterministic `no1_...` logical ID.
13. Run `publish <logical-id>` once.
14. If the result is `pending-reconcile`, run the same `publish <logical-id>` again so it searches for the exact logical ID and digest before any create retry.
15. Stop on conflict, identity drift, binding drift, TCC error, multiple matches, or any unexpected prompt.
16. Confirm that exactly one note appears in `Firstmate/30 Outbox` with the text `This is a Firstmate Apple Notes channel test. It contains no private data and requests no action.`
17. Do not infer iPhone delivery from local creation.
18. If desired, inspect the one synthetic note on the captain's iPhone and record observed sync behavior.
19. Immediately run `disable --emergency` after the single outbound test unless a separately approved next stage begins.
20. Do not install `notes-watch.check.sh`, register login behavior, or load any LaunchAgent during this test.

## Recurring authenticated check

A later separately approved stage may install the nonresident check:

```sh
FM_HOME=/Users/gustavocarriconde/github/firstmate \
  /path/to/generated-runtime/bin/fm-notes-channel.sh \
  install-definitions --runtime-root /path/to/generated-runtime
```

The generated shim is a mode-`0700` regular file and its trust record binds the exact bytes through the existing custom-check format.
The watcher runs a trusted snapshot under its existing outer timeout.
The Notes scan has its own eight-second deadline and prints at most one body-free line.
The check uses the existing default 300-second slow-check cadence.
There is no daemon, foreground long poll, process-event source, login item, LaunchAgent, or automatic fallback.

## Emergency disable and rollback

Emergency disable is local-first and sends zero provider or Apple Event calls:

```sh
FM_HOME=/Users/gustavocarriconde/github/firstmate \
  /path/to/generated-runtime/bin/fm-notes-channel.sh disable --emergency
```

It commits `DISABLED`, sets config disabled, and removes only exact marker-owned check definitions.
It does not delete captures, intents, receipts, audit records, helper state, or Notes content.

Generated-runtime rollback is pointer-only through the local runtime kit after the channel is disabled.
Rollback must retain the current Calm capability and must not drop the separately prepared persistence slot when that slot is included in the active candidate.
Restart Firstmate from the restored generated runtime root after pointer rollback.

Uninstall definitions removes only exact marker-owned check and trust files:

```sh
bin/fm-notes-channel.sh uninstall-definitions
```

Manual full retirement may additionally remove the fixed app after revoking only that app's Notes Automation permission in System Settings.
Do not reset all TCC permissions.
Do not delete the `Firstmate` Notes tree or any Notes evidence automatically.
Do not clear `DISABLED`, rebind, restore, or begin a new audit epoch without captain-present reconciliation.
