# Prime Agent

This reference covers Prime Agent detection, crewmate/scout launch, semantic busy state, and control mechanics.
The active empirical record is [`docs/verification/prime-agent.md`](../../../../../docs/verification/prime-agent.md).
Secondmate launches remain outside the verified boundary.

## Detection

Prime Agent exports `PI_CODING_AGENT=true`, the same Pi-family marker used by Pi and Pi-signed.
The launch-boundary marker `FM_PI_HARNESS=prime-agent` disambiguates it when paired with the Pi-family marker.
Prime Agent's own `PRIME_AGENT_CODING_AGENT_DIR` and `PRIME_AGENT_INTERNAL_DAEMON_WORKER=1` are inherited session values, not detection evidence.
`../../../bin/fm-harness.sh` checks the Prime Agent marker before `CLAUDECODE` and the unmarked Pi result and after the cursor, gemini, rovo, and omp marker arms.
Those four keep their identity when started by hand inside a Prime Agent session.
With `CLAUDECODE=1`, the marker selects Prime Agent only when a real `prime-agent` process sits within eight parents.
Without `CLAUDECODE`, the marker is sufficient once the Pi-family marker is present.
A marker without `PI_CODING_AGENT=true` is ignored.
The Prime Agent launch clears `CLAUDECODE` and `GROK_AGENT` and uses the shared launch prefix to clear cursor and Gemini markers.
An unmarked Prime Agent session remains Pi-family by design.
Detection and launch markers were verified live against Prime Agent 0.9.4.

## Launch and busy state

`../../../bin/fm-spawn.sh` launches a Prime Agent crewmate or scout with one encoded brief, `--provider`, `--model`, `--thinking`, and `-e state/<task-id>.prime-ext.ts`.
The generated extension writes the semantic busy record on `agent_start`, clears it after a settled `agent_end`, and touches the turn-end notification marker on `turn_end`.
Prime Agent 0.9.4 has no `agent_settled` event, so error stop reasons and pending messages hold the busy record for a short grace window.
`bin/fm-busy-lib.sh` trusts the generated `prime-ext` source only for a recorded Prime Agent task.
The extension is written outside the project and is removed by cleanup and harness relaunch wiring.
Prime Agent primary supervision and secondmate launch remain unproven and are outside this adapter's verified scope.

## Control

Prime Agent uses the Pi-family control table.
A single `Escape` interrupts a running turn and leaves the composer empty without a clear key.
`/quit` exits the Prime Agent process and leaves the detached daemon worker for directory-bound retirement.
Relaunch starts a fresh Prime Agent client in the same pane and directory rather than claiming an unverified pane-resume contract.
Prime Agent 0.9.4 control behavior was verified live in Herdr.
`../../../bin/fm-spawn.sh --help` owns executable preflight and rejects a missing `prime-agent` before task publication.
`../../../bin/fm-prime-agent-lib.sh` owns detached-worker listing and retirement for task cleanup.

## Scope

Prime Agent is verified for crewmate and scout work.
Secondmate launches remain refused because no primary supervision protocol is verified for Prime Agent.
Primary-session supervision is outside this adapter's verified scope.
Prime Agent's native RPC, RLM, and agent-messaging features are not Firstmate control-plane replacements.
Prime Agent itself warns that Anthropic subscription use is billed per token as extra usage.
