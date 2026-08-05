# Apple Notes channel verification

Date: 2026-08-03.
Baseline: official `origin/main` at `cf9511217d885cd2127d50993e672c2dfa0539cf`.
Platform inspected: macOS 26.5.2 build 25F84 on arm64, Notes 4.13, Swift 6.1.2, and Xcode 16.4.

This record covers offline behavior and static bridge build facts only.
It does not establish live Notes, TCC, iCloud, folder-ID, iPhone sync, or login behavior.
No command in this verification sent an Apple Event, launched Notes through the bridge, requested TCC, created a Notes folder, read a live note, wrote a live note, changed iCloud, installed a login item, loaded a LaunchAgent, or activated a runtime pointer.

## Static bridge evidence

Command:

```sh
bin/fm-notes-bridge-build.sh inspect --json
```

Expected current result:

```json
{"apple_events_sent":0,"notes_declared_access_groups":["com.apple.Notes.openlocation"],"notes_launched":false,"release_build_allowed":false,"sandbox_status":"blocked-target-wide-temporary-exception-required","schema":"firstmate.apple-notes.bridge-build-inspection/v1","signing_status":"no-suitable-apple-identity","tcc_requested":false}
```

The installed Notes scripting definition provides one access group for the prohibited open-location command and no access group for account, folder, or note CRUD.
The release builder therefore refuses rather than adding the target-wide temporary Apple Events exception for Notes.
The local code-signing catalog contains one valid but unrecognized identity and no identity classified as Apple Development or Developer ID Application.
No certificate label or private material is recorded here.

Fixture build command:

```sh
app="$(mktemp -d)/FirstmateNotesBridge.app"
bin/fm-notes-bridge-build.sh fixture --output "$app"
printf '%s' '{"schema":"firstmate.apple-notes.bridge/v1","operation":"status"}' \
  | "$app/Contents/MacOS/FirstmateNotesBridge" status
```

The fixture app is ad-hoc signed with hardened runtime and App Sandbox, has stable bundle ID `dev.firstmate.notes-bridge`, carries the explicit Notes Automation usage text, and has no Apple Events entitlement.
Its `status` interface reports zero provider calls and does not request TCC.
It is not eligible for a live pilot.

## Offline behavioral evidence

Commands:

```sh
python3 -m py_compile bin/fm-notes-channel-impl.py
bash tests/fm-notes-channel.test.sh
bash tests/fm-notes-bridge-build.test.sh
bash tests/fm-turnend-guard.test.sh
bash bin/fm-lint.sh
bash bin/fm-doc-audience-check.sh
git diff --check origin/main..HEAD
```

The focused channel suite exercises the owner and deterministic fake provider through public commands.
It covers strict envelopes, Unicode and control rejection, HTML/plaintext comparison, attachment and lock pre-body refusal, size and URL caps, two-observation stability, full-set late-arrival reconciliation, deterministic IDs, UUID aliases and collisions, modified-source conflicts, capture and offer order, atomic repeat claims, low-authority classification, rate limits, outbound intent staging, reconcile-before-create ambiguity, audit-chain detection, private state invariants, poison-note fairness, self-loop separation, authenticated check installation, zero-call disable, and definition-only uninstall.
The call-spy assertions prove that every provider read uses only the bound account and Inbox IDs and every provider write uses only the bound Acknowledgments or Outbox ID.
The build suite exercises static inspection, release refusal, fixture compilation/signing, the typed status operation, and rejection of an unknown bridge verb.
The supervision suite proves that an installed Notes check keeps supervision required without counting as an in-flight task.

Refresh this record when the focused suite, platform, Notes version, bridge identity model, sandbox access-group facts, or signing availability changes.
A future live verification must use only the fresh synthetic tree and must be recorded separately without personal note metadata or content.
