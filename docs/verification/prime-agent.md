# Verification: the Prime Agent crewmate/scout adapter

This record stores active empirical evidence for the Prime Agent adapter.
The adapter reference owns the stable operating contract.

## Subject

| Field | Value |
|---|---|
| Version | `prime-agent 0.9.4` |
| Evidence date | 2026-09-15 |
| Branch | `fm/fm-upstream-prime-one-pr`, rebuilt from upstream `main` |
| Platform | Linux x86_64 |
| Backend | Herdr in a named non-`default` lab session created by `bin/fm-herdr-lab.sh` |
| Provider | `openai-codex` |

The live guard is opt-in because it submits real prompts.
It uses the Herdr lab helper for every lifecycle and pane operation and never changes the shared `default` session.
No primary-session or secondmate behavior is claimed.

## Deterministic evidence

The targeted adapter suites cover detection, launch rendering, control tables, Herdr classification, quota mapping, semantic busy state, and the refusal of Prime Agent secondmates.
The live test is classified in the `live-harness-optin` family.

## Live evidence

The live guard was run locally on this branch with Prime Agent 0.9.4 and the `openai-codex` provider.
It confirmed the generated task extension, the Prime Agent process and composer, semantic busy and idle transitions, Escape, `/quit`, relaunch, and detached-worker retirement in the named Herdr lab.
The live guard did not drive an end-to-end `fm-spawn.sh`, `fm-send.sh`, or `fm-control.sh` run.
It used `fm-spawn.sh` to render the launch with a fake backend and then drove the generated command directly in Herdr.

## Scope and limits

Prime Agent is verified here for crewmate and scout launches only.
Secondmate launches remain refused because no primary supervision protocol is verified.
Primary-session supervision, pane resume, fork, RPC, RLM, and agent-messaging control-plane replacement are outside this record.

## Reproduction

Run the targeted suites, then the opt-in live guard after a Prime Agent or Herdr upgrade:

```
bin/fm-test-run.sh --jobs 1 tests/fm-prime-agent-harness.test.sh tests/fm-busy-adapter-wiring.test.sh tests/fm-quota-choose.test.sh tests/fm-spawn-dispatch-profile.test.sh tests/fm-backend-herdr.test.sh
HERDR_LAB_HELPER="$PWD/bin/fm-herdr-lab.sh" FM_PRIME_AGENT_LIVE_E2E=1 bin/fm-test-run.sh --jobs 1 tests/fm-prime-agent-signals-live-e2e.test.sh
```

The dated local result for this branch was `FM_TEST_SUMMARY total=5 failed=0 skipped_gate=0` for the deterministic command and `FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0` for the live command.
