# AIME cloud research worker verification

Repeatable evidence for Firstmate's optional AIME cloud research executor.
Current operator behavior is owned by [`../configuration.md`](../configuration.md#aime-cloud-research-worker-configaime-cloud-worker), stable mechanism boundaries by [`../architecture.md`](../architecture.md#task-executors), conditional procedure by [`../../.agents/skills/cloud-research-worker/SKILL.md`](../../.agents/skills/cloud-research-worker/SKILL.md), and exact commands and schemas by the script headers and `--help` output.
This page records current empirical facts only.

Date: 2026-08-14.
Host: Linux 5.15.152.bsk.4-amd64, x86_64.
Comparison base: `origin/main` at `ec3ee1adfd6f`.

## Installed CLI and read-only live probes

The implementation was verified against installed `bytedcli` 0.124.0 with automatic upgrade disabled.

```console
$ BYTEDCLI_NO_AUTO_UPGRADE=1 bytedcli --json --version | jq -c '{status,data,error}'
{"status":"success","data":{"version":"0.124.0"},"error":null}
```

The selected CN personal space was active and exposed both `space.read` and `session.create`.
The projections below intentionally omit unrelated permissions and personal text.

```console
$ BYTEDCLI_NO_AUTO_UPGRADE=1 bytedcli --json --site cn --as user aime space list --limit 100 | jq -c --arg id '67911b18-7ee7-4fd9-a36a-c2dfd85cf33d' '{status,error,selected:(.data.spaces[] | select(.id == $id) | {id,status,permission_actions})}'
{"status":"success","error":null,"selected":{"id":"67911b18-7ee7-4fd9-a36a-c2dfd85cf33d","status":"active","permission_actions":["session.create","mcp.create","template.create","knowledgebase.create","aeolus.create","aeolus.update","aeolus.delete","aeolus.read","space.read","space.update","space.dev_resource_update"]}}
$ BYTEDCLI_NO_AUTO_UPGRADE=1 bytedcli --json --site cn --as user aime space get --space-id '67911b18-7ee7-4fd9-a36a-c2dfd85cf33d' | jq -c '{status,error,space:{id:.data.id,status:.data.status,type:.data.type}}'
{"status":"success","error":null,"space":{"id":"67911b18-7ee7-4fd9-a36a-c2dfd85cf33d","status":"active","type":"personal"}}
```

The Firstmate-owned wrapper performed the same read-only checks and returned its bounded capability record.

```console
$ FM_CONFIG_OVERRIDE=/tmp/fm-aime-no-config-$$ BYTEDCLI_NO_AUTO_UPGRADE=1 bin/fm-cloud-research-aime.sh probe --site cn --space-id '67911b18-7ee7-4fd9-a36a-c2dfd85cf33d' | jq -c '{schema,outcome,error_class,site,space_id,identity,provider,capabilities,bytedcli_version}'
{"schema":"fm-aime-probe.v1","outcome":"ready","error_class":null,"site":"cn","space_id":"67911b18-7ee7-4fd9-a36a-c2dfd85cf33d","identity":"user","provider":"aime","capabilities":["space.read","session.create","session.get","session.send","session.get-output","session.replay-events"],"bytedcli_version":"0.124.0"}
```

## Published session surface

The installed session command exposes create, get, get-output, list, replay-events, and send.
It exposes no cancellation command, so Firstmate does not claim cloud cancellation or invent a provider call.

```console
$ BYTEDCLI_NO_AUTO_UPGRADE=1 bytedcli aime session --help | sed -n '/Commands:/,/Advanced global/p'
Commands:
  create [options]         Create a new chat session in a space (defaults to
                           personal space)
  get [options]            Get session details
  get-output [options]     Fetch the latest assistant output from a session by
                           replaying event history
  list [options]           List sessions in a space (defaults to personal
                           space)
  replay-events [options]  Replay the complete structured event history for a
                           session
  send [options]           Send a message, optionally upload files, and
                           optionally wait for the final response
```

The same installed build provides the two safety-critical primitives used by the implementation: file-based message content and offset-based terminal replay.

```console
$ BYTEDCLI_NO_AUTO_UPGRADE=1 bytedcli aime session send --help | grep -E -- '--content-file|--wait|--session-id|--execution-mode'
  --session-id <session_id>   Session ID to continue; omitted means create a
  --content-file <path>       Read message content from a local file
  --execution-mode <mode>     Reasoning strength (choices: "fast", "max")
  --wait                      Wait for the final assistant response before
$ BYTEDCLI_NO_AUTO_UPGRADE=1 bytedcli aime session replay-events --help | grep -E -- '--from-offset|--timeout-ms|--max-streams|--until-terminal'
  --from-offset <number>       Start replaying at this event offset (default:
  --timeout-ms <milliseconds>  Per-stream hard limit in milliseconds;
  --max-streams <number>       Maximum event replay streams before failing
  --until-terminal             Keep reconnecting until a terminal event is
```

## Fake-provider behavioral evidence

`tests/fm-aime-cloud-worker.test.sh` puts a fake `bytedcli` first on `PATH` and drives the real Firstmate scripts.
It performs no real AIME or Feishu write.
The suite covers the disabled gate; read-only probe classifications; explicit fake sandbox authorization and disabled config output; durable create and send boundaries; asynchronous process-event completion; duplicate wake replay; restart adoption from submitted and checkpointed-created phases even after config removal; acceptance-unknown states; explicit rate-limited and unavailable rejection; canonical Feishu-host document identity validation with no local Feishu write; malformed, empty, missing, and transient results; cancellation refusal; cloud retirement with report preservation; and unchanged local dispatch, state, and retirement delegation.

```console
$ bin/fm-test-run.sh tests/fm-aime-cloud-worker.test.sh
ok - AIME probe is read-only and production dispatch is disabled by default
ok - AIME probe distinguishes auth, unsupported capability, malformed output, and unavailable CLI
ok - sandbox verification requires explicit authority, reads back one disposable session, and stays disabled
ok - AIME dispatch checkpoints identity, completes asynchronously, wakes once, and replays safely
ok - restart adoption safely resumes not-started and created checkpoints, preserves submissions, and never claims cloud cancellation
ok - AIME writes preserve acceptance-unknown states and distinguish explicit rejection classes
ok - AIME document mode records the provider-created artifact and terminal bad results fail explicitly
ok - transient provider readback is unknown current state, re-arms, and resolves its blocker after recovery
ok - terminal AIME retirement passes the decision gate, removes volatile cloud state, and preserves the report
ok - backend-neutral wrappers preserve local spawn, state, and teardown argument semantics
# fm-aime-cloud-worker.test.sh: all assertions passed
FM_TEST_END 2026-08-13T18:24:55Z tests/fm-aime-cloud-worker.test.sh exit=0 duration_ms=97411 gate_skip=false
```

The complete 136-test repository run also passed the AIME suite and every touched lifecycle family.
It reported three failures unrelated to this branch: the cmux missing-target classification and Herdr presentation-lock ordering tests reproduce from an unmodified `origin/main` archive, while the Calm rendered-export assertion explicitly requires Chrome or Chromium and neither binary was installed on this host.
No cmux, Herdr presentation, or Calm implementation or test file differs from `origin/main`.

## Live-write boundary

No real AIME cloud task or Feishu document was created during ordinary implementation validation.
The only live commands run were `bytedcli --version`, AIME help, `aime space list`, `aime space get`, and the Firstmate read-only `probe`.
The mutating `sandbox-verify --authorize-disposable-session` path was not run live because this task did not carry separate authorization for that smoke.
Its behavior was exercised only against the fake provider, where it created and read back exactly one fake session and wrote `enabled=false`.
