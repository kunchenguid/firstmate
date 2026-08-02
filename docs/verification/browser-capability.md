# Browser capability verification

Date: 2026-08-02.
Firstmate commit under implementation: feature branch `fm/firstmate-browser-capability-synthesis`.

## Current support claim

The current support claim is limited to a disabled-by-default command contract, policy parser, public-origin planner, mocked lifecycle, redacted receipts, inspect-only reconciliation, exact cleanup refusal, and opt-in real-smoke contract.
No real browser support is claimed by this verification record.

## Commands run during implementation

The implementation stage must record final commands here before merge.
At minimum run:

```sh
bin/fm-test-run.sh tests/fm-browser.test.sh
bin/fm-test-run.sh tests/fm-browser-cleanup.test.sh
bin/fm-test-run.sh tests/fm-browser-integration.test.sh
bin/fm-test-run.sh tests/fm-browser-capacity.test.sh
bin/fm-lint.sh
bin/fm-doc-audience-check.sh
bin/fm-test-run.sh --changed
```

## Opt-in real public smoke contract

The real smoke is not automatic and must not run in CI by default.
It requires `FM_BROWSER_REAL_SMOKE=1` and a future verified real engine adapter.
The smoke must use only a unique temporary public anonymous profile.
It must not use credentials, cookies, personal Chrome, private/local origins, browser extensions, installs, updates, uploads, downloads, screenshots, HAR, video, network administration, or external writes.

Pass conditions:

1. The exact owned visible window is foreground and on screen without manual help.
2. The browser navigates from `https://example.com` to the IANA Example Domains page through the `Learn more` link.
3. A private/local URL is refused before engine execution.
4. A forbidden verb is refused before engine execution.
5. The exact endpoint, process tree, window, profile, lease, and session record are cleaned.
6. Repeated cycles show no owned browser, helper, profile, process, or receipt growth outside the expected value-redacted ledger.
7. Unrelated Chrome windows and the live fleet remain untouched.

## Known limitations

The window helper is currently a disabled contract and mock implementation.
Real macOS foreground proof is not claimed.
`agent-browser` is not launched by this core.
`chrome-devtools-axi` is not a reliable visible owner.
Authenticated and durable modes remain disabled until separate synthetic and enclave verification records pass.
