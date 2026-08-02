# Browser capability verification

Audience: maintainer verification.

This record holds the evidence behind the disabled browser custody core's active guarantees.
`docs/browser-capability.md` owns the operator contract, `docs/browser-architecture.md` owns the architecture, `bin/fm-browser.sh`'s header and `--help` own its mechanics, and `.agents/skills/browser-capability/SKILL.md` owns the agent handling procedure.

Verified on 2026-08-02 on macOS 26.5.2 (Darwin 25.5.0) with ShellCheck 0.11.0, against the disabled custody core's first implementation.

## Current support claim

The claim is limited to a disabled-by-default command contract, policy parser, public-origin planner, mocked lifecycle, redacted receipts, inspect-only reconciliation, exact cleanup refusal, and an opt-in real-smoke contract that has never been executed.
No real browser support is claimed by this record.
No browser process was launched to produce any evidence below.

## Suite evidence

Each suite was run individually through the repository runner:

```text
$ bin/fm-test-run.sh tests/fm-browser.test.sh
FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0 duration_ms=3701      # 4 ok assertions
$ bin/fm-test-run.sh tests/fm-browser-cleanup.test.sh
FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0 duration_ms=5233      # 3 ok assertions
$ bin/fm-test-run.sh tests/fm-browser-integration.test.sh
FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0 duration_ms=2307      # 4 ok assertions
$ bin/fm-test-run.sh tests/fm-browser-capacity.test.sh
FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0 duration_ms=3420      # 3 ok assertions
```

All four belong to the `pure-contract-unit` family and passed with zero failures.

The fifth suite is the opt-in real smoke, which gate-skips by construction:

```text
$ bin/fm-test-run.sh tests/fm-browser-real-smoke.test.sh
FM_TEST_BEGIN ... family=live-harness-optin expected_gate_skip=optin-env
skip: set FM_BROWSER_REAL_SMOKE=1 only for the supervised public visible browser smoke
FM_TEST_SUMMARY total=1 failed=0 skipped_gate=1 duration_ms=331
```

That skip is the evidence: without `FM_BROWSER_REAL_SMOKE=1` the suite cannot reach any launch path, and its second guard additionally requires `FM_BROWSER_REAL_ENGINE_VERIFIED=1`, which no verified engine sets today.

The fourteen passing assertions are exactly:

```text
ok - disabled default still permits value-safe planning and refuses open
ok - origin policy refuses private and credential-bearing URLs before engine execution
ok - mock lifecycle records navigation, redaction, denied writes, and cleanup
ok - open refuses plan receipts that are not a bare sha256 digest
ok - clean close removes only the exact owned runtime profile
ok - cleanup refuses path escape and preserves ambiguous profile
ok - a session without a recorded profile path quarantines instead of resolving to the working directory
ok - --browser scaffold adds browser-capability safety contract
ok - browser policy is inherited through the declared config list
ok - bootstrap validates browser policy without launching a browser
ok - teardown helper refuses only unclean browser bindings
ok - capacity refuses a new session instead of closing an existing one
ok - expiry reports eligible sessions without closing them in alert-only core
ok - quarantine records unproven cleanup without consuming engine capacity
```

**What they do not prove:** anything about a real engine, a real profile, real process or window identity, foreground or on-screen behavior, authenticated or durable modes, LinkedIn or any other specific site, or production readiness.
Every lifecycle assertion above is against the mock; none of it substitutes for the real-smoke contract below.

## Window helper evidence

`bin/fm-window-helper.sh` refuses every real action out of the box, and only reports capabilities:

```text
$ bin/fm-window-helper.sh capabilities --json
{"mock": false, "realActivation": false, "schema": "fm-window-helper-capabilities.v1", "usesAccessibility": false, "usesAppleEvents": false, "usesInputInjection": false, "usesScreenRecording": false}   # exit 0

$ bin/fm-window-helper.sh activate-visible --browser-pid 1 --birth-token t --display-id 1 --json
{"code": "helper-disabled", "message": "real macOS window activation is disabled until the signed no-TCC helper is verified", "result": "error", "schema": "fm-window-helper-receipt.v1"}   # exit 1
```

The nonzero exit with `helper-disabled` is the proof that activation refuses before touching the system.
This helper is a shell and Python contract stub, not signed native code; nothing here demonstrates macOS window control.

## Repository checks

```text
$ bin/fm-lint.sh
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)      # exit 0, 223 files

$ bin/fm-doc-audience-check.sh
fm-doc-audience-check: ok surfaces=65 local_links=177      # exit 0
```

The full lint sweep covers `bin/*.sh`, which is why the window helper lives there: `bin/browser-engines/` is outside ShellCheck's roots, so filing the helper beside the source-only engine adapters would have left an executable script unlinted.

## Opt-in real public smoke contract

**None of this section has been exercised.** It is the forward contract a future verified engine stage must satisfy; no pass condition below is claimed as met.

The real smoke is not automatic and must not run in CI by default.
It requires `FM_BROWSER_REAL_SMOKE=1` and a future verified real engine adapter.
The smoke must use only a unique temporary public anonymous profile.
It must not use credentials, cookies, personal Chrome, private/local origins, browser extensions, installs, updates, uploads, downloads, screenshots, HAR, video, network administration, or external writes.

Pass conditions that stage must then demonstrate:

1. The exact owned visible window is foreground and on screen without manual help.
2. The browser navigates from `https://example.com` to the IANA Example Domains page through the `Learn more` link.
3. A private/local URL is refused before engine execution.
4. A forbidden verb is refused before engine execution.
5. The exact endpoint, process tree, window, profile, lease, and session record are cleaned.
6. Repeated cycles show no owned browser, helper, profile, process, or receipt growth outside the expected value-redacted ledger.
7. Unrelated Chrome windows and the live fleet remain untouched.

## Known limitations

The window helper is a disabled contract and mock implementation; real macOS foreground proof is not claimed.
`agent-browser` is not launched by this core.
`chrome-devtools-axi` is not a reliable visible owner.
Authenticated and durable modes remain disabled until separate synthetic and enclave verification records pass.
